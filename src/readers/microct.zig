const std = @import("std");
const bio = @import("../root.zig");

const magic = "ncaa";

const Header = struct {
    width: u32,
    height: u32,
    size_z: u16,
    pixel_type: bio.PixelType,
    pixel_offset: usize,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "microct",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = header.size_z,
        .size_t = 1,
        .pixel_type = header.pixel_type,
        .little_endian = false,
        .plane_count = header.size_z,
        .dimension_order = "XYZCT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const header = try parseHeader(data);
    const plane_len = try planeByteCount(metadata);
    const plane_offset = std.math.add(usize, header.pixel_offset, std.math.mul(usize, plane_index, plane_len) catch return error.InvalidPlaneIndex) catch return error.InvalidPlaneIndex;
    if (plane_offset > data.len or data.len - plane_offset < plane_len) return error.TruncatedData;

    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    const row_bytes = std.math.mul(usize, metadata.width, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
    var row: usize = 0;
    while (row < metadata.height) : (row += 1) {
        const src_row = metadata.height - 1 - row;
        const src = plane_offset + src_row * row_bytes;
        const dst = row * row_bytes;
        @memcpy(out[dst..][0..row_bytes], data[src..][0..row_bytes]);
    }
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < magic.len) return error.TruncatedData;
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return error.InvalidFormat;
    var iter = lineIterator(data);
    var rank: u32 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    var size_z: u16 = 1;
    var pixel_type: ?bio.PixelType = null;
    var pixel_offset: ?usize = null;

    while (iter.next()) |line| {
        if (line.trimmed.len == 0) {
            pixel_offset = line.next_offset;
            break;
        }
        const eq = std.mem.indexOfScalar(u8, line.trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, line.trimmed[0..eq], " \t");
        const value = stripSemicolon(std.mem.trim(u8, line.trimmed[eq + 1 ..], " \t"));
        if (std.mem.eql(u8, key, "rank")) {
            rank = try parseU32(value);
        } else if (std.mem.eql(u8, key, "size")) {
            var dims = std.mem.tokenizeAny(u8, value, " \t");
            if (rank > 0) width = try parseU32(dims.next() orelse return error.InvalidFormat);
            if (rank > 1) height = try parseU32(dims.next() orelse return error.InvalidFormat);
            if (rank > 2) {
                const z = try parseU32(dims.next() orelse return error.InvalidFormat);
                if (z == 0 or z > std.math.maxInt(u16)) return error.UnsupportedVariant;
                size_z = @intCast(z);
            }
        } else if (std.mem.eql(u8, key, "bits")) {
            const bits = try parseU32(value);
            pixel_type = switch (bits) {
                8 => .int8,
                16 => .int16,
                32 => .int32,
                else => return error.UnsupportedVariant,
            };
        }
    }
    if (pixel_offset == null) return error.InvalidFormat;
    if (width == 0 or height == 0 or size_z == 0 or pixel_type == null) return error.InvalidFormat;
    const header = Header{ .width = width, .height = height, .size_z = size_z, .pixel_type = pixel_type.?, .pixel_offset = pixel_offset.? };
    const metadata = bio.Metadata{
        .format = "microct",
        .width = width,
        .height = height,
        .size_z = size_z,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = pixel_type.?,
        .plane_count = size_z,
    };
    const total = std.math.mul(usize, try planeByteCount(metadata), size_z) catch return error.UnsupportedVariant;
    if (header.pixel_offset > data.len or data.len - header.pixel_offset < total) return error.TruncatedData;
    return header;
}

const Line = struct {
    trimmed: []const u8,
    next_offset: usize,
};

const LineIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *LineIterator) ?Line {
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '\n' and self.data[self.pos] != '\r') : (self.pos += 1) {}
        const raw = self.data[start..self.pos];
        if (self.pos < self.data.len and self.data[self.pos] == '\r') self.pos += 1;
        if (self.pos < self.data.len and self.data[self.pos] == '\n') self.pos += 1;
        return .{ .trimmed = std.mem.trim(u8, raw, " \t\x0c"), .next_offset = self.pos };
    }
};

fn lineIterator(data: []const u8) LineIterator {
    return .{ .data = data };
}

fn stripSemicolon(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and (value[end - 1] == ';' or std.ascii.isWhitespace(value[end - 1]))) : (end -= 1) {}
    return value[0..end];
}

fn parseU32(value: []const u8) bio.ReaderError!u32 {
    return std.fmt.parseInt(u32, value, 10) catch return error.InvalidFormat;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

test "reads microct vff plane and flips rows" {
    const data =
        "ncaa\n" ++
        "rank=2;\n" ++
        "size=2 2;\n" ++
        "bits=8;\n" ++
        "\x0c\n" ++
        [_]u8{ 1, 2, 3, 4 };

    try std.testing.expect(matches(data));
    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("microct", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(bio.PixelType.int8, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4, 1, 2 }, plane.data);
}

test "reads microct internal z plane" {
    const data =
        "ncaa\n" ++
        "rank=3;\n" ++
        "size=1 1 2;\n" ++
        "bits=16;\n" ++
        "\n" ++
        [_]u8{ 0, 1, 0, 2 };

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.int16, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 2 }, plane.data);
}
