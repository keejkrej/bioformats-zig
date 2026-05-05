const std = @import("std");
const bio = @import("../root.zig");

const header_len = 6;

const Header = struct {
    width: u32,
    height: u32,
    depth: u32,
    pixel_type: bio.PixelType,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "povray",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.depth, std.math.maxInt(u16))),
        .pixel_type = header.pixel_type,
        .little_endian = false,
        .plane_count = header.depth,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const offset = std.math.add(usize, header_len, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_len) return error.TruncatedData;
    const width = readU16(data[0..2]);
    const height = readU16(data[2..4]);
    const depth = readU16(data[4..6]);
    if (width == 0 or height == 0 or depth == 0) return error.InvalidFormat;
    const voxels = std.math.mul(usize, std.math.mul(usize, width, height) catch return error.UnsupportedVariant, depth) catch return error.UnsupportedVariant;
    if (voxels == 0) return error.InvalidFormat;
    const payload_len = data.len - header_len;
    if (payload_len % voxels != 0) return error.InvalidFormat;
    const bytes_per_sample = payload_len / voxels;
    return .{
        .width = width,
        .height = height,
        .depth = depth,
        .pixel_type = switch (bytes_per_sample) {
            1 => .uint8,
            2 => .uint16,
            4 => .uint32,
            else => return error.UnsupportedVariant,
        },
    };
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .big);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(list: *std.ArrayList(u8), width: u16, height: u16, depth: u16) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_len);
    writeU16(list.items, 0, width);
    writeU16(list.items, 2, height);
    writeU16(list.items, 4, depth);
}

test "reads povray df3 z planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 2);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const second = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, second.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads povray df3 uint16 samples" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 2, 1);
    try data.appendSlice(std.testing.allocator, &.{ 0x12, 0x34, 0xab, 0xcd });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0xab, 0xcd }, plane.data);
}

test "rejects povray df3 size mismatch" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 2, 1);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3 });

    try std.testing.expect(!matches(data.items));
}

