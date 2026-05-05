const std = @import("std");
const bio = @import("../root.zig");

const magic = "IMODV1.2";
const min_header_len = 8 + 128 + 12;

const Header = struct {
    width: u32,
    height: u32,
    size_z: u16,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "imod",
        .width = header.width,
        .height = header.height,
        .size_c = 3,
        .samples_per_pixel = 3,
        .size_z = header.size_z,
        .size_t = 1,
        .pixel_type = .rgb8,
        .little_endian = false,
        .plane_count = header.size_z,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, plane_len);
    @memset(out, 0);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < min_header_len) return error.TruncatedData;
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return error.InvalidFormat;
    const width = try positiveI32AsU32(readI32(data, 8 + 128));
    const height = try positiveI32AsU32(readI32(data, 8 + 128 + 4));
    const z = try positiveI32AsU32(readI32(data, 8 + 128 + 8));
    if (z > std.math.maxInt(u16)) return error.UnsupportedVariant;
    return .{ .width = width, .height = height, .size_z = @intCast(z) };
}

fn positiveI32AsU32(value: i32) bio.ReaderError!u32 {
    if (value <= 0) return error.InvalidFormat;
    return @intCast(value);
}

fn readI32(data: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, data[offset..][0..4], .big);
}

fn writeI32(data: []u8, offset: usize, value: i32) void {
    std.mem.writeInt(i32, data[offset..][0..4], value, .big);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

test "reads imod metadata and blank rgb plane" {
    var data: [min_header_len]u8 = @splat(0);
    @memcpy(data[0..magic.len], magic);
    writeI32(&data, 8 + 128, 2);
    writeI32(&data, 8 + 128 + 4, 1);
    writeI32(&data, 8 + 128 + 8, 3);

    try std.testing.expect(matches(&data));
    const metadata = try readMetadata(&data);
    try std.testing.expectEqualStrings("imod", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 3), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, &data, 2);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(usize, 6), plane.data.len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0 }, plane.data);
}

test "rejects invalid imod dimensions" {
    var data: [min_header_len]u8 = @splat(0);
    @memcpy(data[0..magic.len], magic);
    writeI32(&data, 8 + 128, 0);
    writeI32(&data, 8 + 128 + 4, 1);
    writeI32(&data, 8 + 128 + 8, 1);

    try std.testing.expect(!matches(&data));
    try std.testing.expectError(error.InvalidFormat, readMetadata(&data));
}
