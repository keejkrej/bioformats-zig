const std = @import("std");
const protocol = @import("protocol.zig");

const max_request_line_bytes = 768 * 1024 * 1024;

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
        const line_with_cr = readLineAlloc(allocator, &stdin_reader.interface) catch |err| switch (err) {
            error.StreamTooLong => {
                _ = stdin_reader.interface.discardDelimiterInclusive('\n') catch {};
                try stdout_writer.interface.writeAll("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Request too large\"}}\n");
                try stdout_writer.interface.flush();
                continue;
            },
            else => |e| return e,
        };
        const owned_line = line_with_cr orelse break;
        defer allocator.free(owned_line);
        const line = std.mem.trimEnd(u8, owned_line, "\r");
        if (line.len == 0) continue;
        const should_shutdown = try server.handleLine(line, &stdout_writer.interface);
        try stdout_writer.interface.flush();
        if (should_shutdown) break;
    }
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
