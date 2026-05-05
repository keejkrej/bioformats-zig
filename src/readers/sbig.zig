const std = @import("std");
const bio = @import("../root.zig");

const header_len = 2048;
const magic = "ST-7 Compressed Image";

const Header = struct {
    width: u32,
    height: u32,
    compressed: bool,
    note: ?[]const u8 = null,
};

pub fn matches(data: []const u8) bool {
    if (data.len < header_len) return false;
    if (std.mem.indexOf(u8, data[0..@min(32, data.len)], magic) == null) return false;
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "sbig",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint16,
        .little_endian = true,
        .image_description = header.note,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    const out = try allocator.alloc(u8, try planeByteCount(metadata));
    errdefer allocator.free(out);

    if (header.compressed) {
        try readCompressed(data, header, out);
    } else {
        if (data.len < header_len or data.len - header_len < out.len) return error.TruncatedData;
        @memcpy(out, data[header_len..][0..out.len]);
    }

    return .{ .metadata = metadata, .data = out };
}

fn readCompressed(data: []const u8, header: Header, out: []u8) bio.ReaderError!void {
    var source: usize = header_len;
    const row_bytes = std.math.mul(usize, header.width, 2) catch return error.UnsupportedVariant;
    for (0..header.height) |row| {
        if (source > data.len or data.len - source < 2) return error.TruncatedData;
        const row_len = readU16(data[source..][0..2]);
        source += 2;
        const row_start = row * row_bytes;
        if (row_len == row_bytes) {
            if (source > data.len or data.len - source < row_bytes) return error.TruncatedData;
            @memcpy(out[row_start..][0..row_bytes], data[source..][0..row_bytes]);
            source += row_bytes;
            continue;
        }

        if (source > data.len or data.len - source < 2) return error.TruncatedData;
        @memcpy(out[row_start..][0..2], data[source..][0..2]);
        source += 2;
        var written: usize = 2;
        while (written < row_bytes) {
            if (source >= data.len) return error.TruncatedData;
            const check = data[source];
            source += 1;
            if (check == 0x80) {
                if (source > data.len or data.len - source < 2) return error.TruncatedData;
                @memcpy(out[row_start + written ..][0..2], data[source..][0..2]);
                source += 2;
            } else {
                const prev = readI16(out[row_start + written - 2 ..][0..2]);
                const delta: i32 = @as(i8, @bitCast(check));
                const next: i16 = @truncate(@as(i32, prev) + delta);
                writeI16(out[row_start + written ..][0..2], next);
            }
            written += 2;
        }
    }
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_len) return error.TruncatedData;
    var width: u32 = 0;
    var height: u32 = 0;
    var compressed = false;
    var note: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, data[0..header_len], '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\x00");
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "Compressed") != null) compressed = true;
        if (std.mem.eql(u8, line, "End")) break;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Width")) {
            width = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, key, "Height")) {
            height = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, key, "Note")) {
            note = value;
        }
    }
    if (width == 0 or height == 0) return error.InvalidFormat;
    return .{ .width = width, .height = height, .compressed = compressed, .note = note };
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readI16(bytes: []const u8) i16 {
    return std.mem.readInt(i16, bytes[0..2], .little);
}

fn writeI16(bytes: []u8, value: i16) void {
    std.mem.writeInt(i16, bytes[0..2], value, .little);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(list: *std.ArrayList(u8), width: u32, height: u32, note: ?[]const u8) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_len);
    var writer: std.Io.Writer = .fixed(list.items);
    try writer.print("{s}\nWidth = {d}\nHeight = {d}\n", .{ magic, width, height });
    if (note) |text| try writer.print("Note = {s}\n", .{text});
    try writer.writeAll("End\n");
}

test "reads sbig raw compressed rows" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, "raw row");
    writeU16(try data.addManyAsSlice(std.testing.allocator, 2), 0, 4);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("raw row", metadata.image_description.?);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, plane.data);
}

test "reads sbig delta compressed rows" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 4, 1, null);
    writeU16(try data.addManyAsSlice(std.testing.allocator, 2), 0, 0);
    try data.appendSlice(std.testing.allocator, &.{ 10, 0, 2, 0xfe, 0x80, 50, 0 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 12, 0, 10, 0, 50, 0 }, plane.data);
}

test "rejects truncated sbig compressed rows" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, null);
    writeU16(try data.addManyAsSlice(std.testing.allocator, 2), 0, 0);
    try data.append(std.testing.allocator, 1);

    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}

