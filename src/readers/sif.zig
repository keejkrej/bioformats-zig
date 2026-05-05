const std = @import("std");
const bio = @import("../root.zig");

const magic = "Andor Technology";
const footer_len = 8;

const Header = struct {
    width: u32,
    height: u32,
    size_c: u32,
    size_z: u32,
    size_t: u32,
    pixel_offset: usize,

    fn planeCount(self: Header) bio.ReaderError!u32 {
        return std.math.mul(u32, self.size_c, std.math.mul(u32, self.size_z, self.size_t) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    }
};

pub fn matches(data: []const u8) bool {
    return data.len >= magic.len and std.mem.eql(u8, data[0..magic.len], magic);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "sif",
        .width = header.width,
        .height = header.height,
        .size_c = @intCast(@min(header.size_c, std.math.maxInt(u16))),
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.size_z, std.math.maxInt(u16))),
        .size_t = @intCast(@min(header.size_t, std.math.maxInt(u16))),
        .pixel_type = .float32,
        .little_endian = true,
        .plane_count = try header.planeCount(),
        .dimension_order = "XYCZT",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const offset = std.math.add(usize, header.pixel_offset, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    var pos: usize = 0;
    var size_c: u32 = 0;
    var size_x: u32 = 0;
    var size_y: u32 = 0;
    var size_z: u32 = 0;
    var size_t: u32 = 0;
    var roi_line: ?[]const u8 = null;
    while (readLine(data, &pos)) |raw_line| {
        const line = std.mem.trim(u8, raw_line.text, " \t\r");
        if (std.mem.startsWith(u8, line, "Pixel number")) {
            var tokens = std.mem.tokenizeAny(u8, line, " \t");
            var index: usize = 0;
            while (tokens.next()) |token| : (index += 1) {
                switch (index) {
                    2 => size_c = try parsePositiveU32(token),
                    3 => size_x = try parsePositiveU32(token),
                    4 => size_y = try parsePositiveU32(token),
                    5 => size_z = try parsePositiveU32(token),
                    6 => size_t = try parsePositiveU32(token),
                    else => {},
                }
            }
            if (readLine(data, &pos)) |roi| {
                roi_line = roi.text;
            }
            break;
        }
    }
    if (size_c == 0 or size_x == 0 or size_y == 0 or size_z == 0 or size_t == 0) return error.InvalidFormat;
    if (roi_line) |line| {
        if (parseRoiDimensions(std.mem.trim(u8, line, " \t\r"))) |roi| {
            size_x = roi.width;
            size_y = roi.height;
        } else |_| {}
    }
    const plane_count = std.math.mul(u32, size_c, std.math.mul(u32, size_z, size_t) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    const plane_len = std.math.mul(usize, size_x, std.math.mul(usize, size_y, 4) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    const pixel_bytes = std.math.mul(usize, plane_len, plane_count) catch return error.UnsupportedVariant;
    const needed = std.math.add(usize, pixel_bytes, footer_len) catch return error.UnsupportedVariant;
    if (needed > data.len) return error.TruncatedData;
    const pixel_start = data.len - needed;
    return .{
        .width = size_x,
        .height = size_y,
        .size_c = size_c,
        .size_z = size_z,
        .size_t = size_t,
        .pixel_offset = pixel_start,
    };
}

const Line = struct {
    text: []const u8,
    next_offset: usize,
};

fn readLine(data: []const u8, pos: *usize) ?Line {
    if (pos.* >= data.len) return null;
    const start = pos.*;
    while (pos.* < data.len and data[pos.*] != '\n' and data[pos.*] != '\r') : (pos.* += 1) {}
    const text = data[start..pos.*];
    if (pos.* < data.len and data[pos.*] == '\r') pos.* += 1;
    if (pos.* < data.len and data[pos.*] == '\n') pos.* += 1;
    return .{ .text = text, .next_offset = pos.* };
}

const Roi = struct {
    width: u32,
    height: u32,
};

fn parseRoiDimensions(line: []const u8) bio.ReaderError!Roi {
    var values: [7]i64 = undefined;
    var count: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    while (tokens.next()) |token| {
        if (count >= values.len) break;
        values[count] = std.fmt.parseInt(i64, token, 10) catch continue;
        count += 1;
    }
    if (count < values.len) return error.InvalidFormat;
    if (values[5] <= 0 or values[6] <= 0) return error.InvalidFormat;
    const width = @abs(values[1] - values[3]) + @as(u64, @intCast(values[5]));
    const height = @abs(values[2] - values[4]) + @as(u64, @intCast(values[6]));
    if (width == 0 or height == 0 or width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) return error.InvalidFormat;
    return .{ .width = @intCast(width), .height = @intCast(height) };
}

fn parsePositiveU32(token: []const u8) bio.ReaderError!u32 {
    const value = std.fmt.parseInt(u32, token, 10) catch return error.InvalidFormat;
    if (value == 0) return error.InvalidFormat;
    return value;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

test "reads sif float plane" {
    const data =
        "Andor Technology\n" ++
        "Pixel number 1 2 1 1 1\n" ++
        "0 0 0 1 0 1 1\n" ++
        [_]u8{ 0, 0, 0x80, 0x3f, 0, 0, 0, 0x40 } ++
        [_]u8{0} ** footer_len;

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0x80, 0x3f, 0, 0, 0, 0x40 }, plane.data);
}

test "reads second sif channel plane" {
    const data =
        "Andor Technology\n" ++
        "Pixel number 2 1 1 1 1\n" ++
        "0 0 0 0 0 1 1\n" ++
        [_]u8{ 0, 0, 0x80, 0x3f, 0, 0, 0, 0x40 } ++
        [_]u8{0} ** footer_len;

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);

    const plane = try readPlaneIndex(std.testing.allocator, data, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0x40 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data, 2));
}

test "reads sif pixels anchored before footer" {
    const data =
        "Andor Technology\n" ++
        "Pixel number 1 1 1 1 1\n" ++
        "0 0 0 0 0 1 1\n" ++
        "timestamp or metadata line before pixels\n" ++
        [_]u8{ 0, 0, 0x80, 0x3f } ++
        [_]u8{0} ** footer_len;

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0x80, 0x3f }, plane.data);
}

test "rejects truncated sif pixels" {
    const data =
        "Andor Technology\n" ++
        "Pixel number 1 1000 1000 1 1\n" ++
        "0 0 0 999 999 1 1\n" ++
        [_]u8{0} ** footer_len;

    try std.testing.expectError(error.TruncatedData, readMetadata(data));
}
