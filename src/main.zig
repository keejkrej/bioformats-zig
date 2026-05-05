const std = @import("std");
const protocol = @import("protocol.zig");

const max_request_line_bytes = 768 * 1024 * 1024;
const max_request_body_bytes = max_request_line_bytes;

const Framing = enum {
    line,
    content_length,
};

const Message = struct {
    data: []u8,
    framing: Framing,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const io = init.io;

    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .initStreaming(.stdin(), io, &stdin_buffer);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);

    var server = protocol.Server.init(allocator, io);
    defer server.deinit();

    while (true) {
        const message = readMessageAlloc(allocator, &stdin_reader.interface) catch |err| switch (err) {
            error.StreamTooLong => {
                try stdout_writer.interface.writeAll("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Request too large\"}}\n");
                try stdout_writer.interface.flush();
                continue;
            },
            error.InvalidMessageFraming => {
                try stdout_writer.interface.writeAll("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Invalid message framing\"}}\n");
                try stdout_writer.interface.flush();
                continue;
            },
            else => |e| return e,
        };
        const owned_message = message orelse break;
        defer allocator.free(owned_message.data);
        const request = switch (owned_message.framing) {
            .line => std.mem.trimEnd(u8, owned_message.data, "\r"),
            .content_length => owned_message.data,
        };
        if (request.len == 0) continue;

        const should_shutdown = switch (owned_message.framing) {
            .line => try server.handleLine(request, &stdout_writer.interface),
            .content_length => should_shutdown: {
                var response: std.Io.Writer.Allocating = .init(allocator);
                defer response.deinit();
                const shutdown = try server.handleLine(request, &response.writer);
                if (response.written().len != 0) {
                    try writeContentLengthResponse(&stdout_writer.interface, response.written());
                }
                break :should_shutdown shutdown;
            },
        };
        try stdout_writer.interface.flush();
        if (should_shutdown) break;
    }
}

fn readMessageAlloc(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?Message {
    const first_line_with_cr = try readLineAlloc(allocator, reader);
    const first_line_owned = first_line_with_cr orelse return null;
    var free_first_line = true;
    errdefer if (free_first_line) allocator.free(first_line_owned);

    const first_line = std.mem.trimEnd(u8, first_line_owned, "\r");
    const first_content_length = try contentLengthHeader(first_line) orelse {
        free_first_line = false;
        return .{ .data = first_line_owned, .framing = .line };
    };
    allocator.free(first_line_owned);
    free_first_line = false;

    var content_length = first_content_length;
    while (true) {
        const header_with_cr = try readLineAlloc(allocator, reader) orelse return error.InvalidMessageFraming;
        defer allocator.free(header_with_cr);
        const header = std.mem.trimEnd(u8, header_with_cr, "\r");
        if (header.len == 0) break;
        if (try contentLengthHeader(header)) |value| content_length = value;
    }

    if (content_length > max_request_body_bytes) {
        try discardExact(reader, content_length);
        return error.StreamTooLong;
    }
    return .{
        .data = try reader.readAlloc(allocator, content_length),
        .framing = .content_length,
    };
}

fn readLineAlloc(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    return readLineAllocLimit(allocator, reader, .limited(max_request_line_bytes));
}

fn readLineAllocLimit(allocator: std.mem.Allocator, reader: *std.Io.Reader, limit: std.Io.Limit) !?[]u8 {
    var line: std.Io.Writer.Allocating = .init(allocator);
    errdefer line.deinit();

    _ = try reader.streamDelimiterLimit(&line.writer, '\n', limit);
    _ = reader.discardDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => {
            if (line.written().len == 0) return null;
        },
        else => |e| return e,
    };
    return @as(?[]u8, try line.toOwnedSlice());
}

fn contentLengthHeader(line: []const u8) !?usize {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const name = std.mem.trim(u8, line[0..colon], " \t");
    if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) return null;
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    if (value.len == 0) return error.InvalidMessageFraming;
    return std.fmt.parseUnsigned(usize, value, 10) catch error.InvalidMessageFraming;
}

fn discardExact(reader: *std.Io.Reader, len: usize) !void {
    var remaining = len;
    while (remaining != 0) {
        const discarded = try reader.discard(.limited(remaining));
        if (discarded == 0) return error.EndOfStream;
        remaining -= discarded;
    }
}

fn writeContentLengthResponse(writer: *std.Io.Writer, response_with_newline: []const u8) !void {
    const response = std.mem.trimEnd(u8, response_with_newline, "\n");
    try writer.print("Content-Length: {}\r\n\r\n", .{response.len});
    try writer.writeAll(response);
}

test {
    _ = protocol;
}

test "readLineAlloc handles a request line larger than the reader buffer" {
    const len = 70 * 1024;
    const input = try std.testing.allocator.alloc(u8, len + 1);
    defer std.testing.allocator.free(input);
    @memset(input[0..len], 'a');
    input[len] = '\n';

    var reader: std.Io.Reader = .fixed(input);
    const line = try readLineAlloc(std.testing.allocator, &reader);
    defer std.testing.allocator.free(line.?);

    try std.testing.expectEqual(len, line.?.len);
    try std.testing.expectEqual(@as(?[]u8, null), try readLineAlloc(std.testing.allocator, &reader));
}

test "readLineAlloc reports request lines over the configured limit" {
    var reader: std.Io.Reader = .fixed("abcdef\n");
    try std.testing.expectError(error.StreamTooLong, readLineAllocLimit(std.testing.allocator, &reader, .limited(3)));
}

test "readMessageAlloc keeps newline-delimited json messages" {
    var reader: std.Io.Reader = .fixed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n");
    const message = (try readMessageAlloc(std.testing.allocator, &reader)).?;
    defer std.testing.allocator.free(message.data);

    try std.testing.expectEqual(Framing.line, message.framing);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", message.data);
}

test "readMessageAlloc reads content-length framed json messages" {
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}";
    const input = "Content-Length: 46\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n" ++ body;
    var reader: std.Io.Reader = .fixed(input);
    const message = (try readMessageAlloc(std.testing.allocator, &reader)).?;
    defer std.testing.allocator.free(message.data);

    try std.testing.expectEqual(Framing.content_length, message.framing);
    try std.testing.expectEqualStrings(body, message.data);
}

test "writeContentLengthResponse frames json response body" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeContentLengthResponse(&out.writer, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n");

    try std.testing.expectEqualStrings("Content-Length: 36\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", out.written());
}
