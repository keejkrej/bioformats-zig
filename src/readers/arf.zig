const std = @import("std");
const bio = @import("../root.zig");

const pixel_offset = 524;
const signature = "AR";

const Offset = struct {
    const endian = 0;
    const signature = 2;
    const version = 4;
    const width = 6;
    const height = 8;
    const bits_per_pixel = 10;
    const image_count = 12;
};

const Header = struct {
    width: u32,
    height: u32,
    image_count: u32,
    pixel_type: bio.PixelType,
    little_endian: bool,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "arf",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
    }) catch return false;
    const pixels_len = std.math.mul(usize, plane_len, header.image_count) catch return false;
    return data.len >= pixel_offset and data.len - pixel_offset >= pixels_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "arf",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_t = @intCast(header.image_count),
        .pixel_type = header.pixel_type,
        .little_endian = header.little_endian,
        .plane_count = header.image_count,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const plane_offset = pixel_offset + (std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant);
    if (data.len < plane_offset or data.len - plane_offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[plane_offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < pixel_offset) return error.TruncatedData;
    const little_endian = if (data[Offset.endian] == 1 and data[Offset.endian + 1] == 0)
        true
    else if (data[Offset.endian] == 0 and data[Offset.endian + 1] == 1)
        false
    else
        return error.InvalidFormat;
    if (!std.mem.eql(u8, data[Offset.signature..][0..signature.len], signature)) return error.InvalidFormat;

    const endian: std.builtin.Endian = if (little_endian) .little else .big;
    const version = readU16(data[Offset.version..][0..2], endian);
    const width = readU16(data[Offset.width..][0..2], endian);
    const height = readU16(data[Offset.height..][0..2], endian);
    const bits_per_pixel = readU16(data[Offset.bits_per_pixel..][0..2], endian);
    const image_count = if (version == 2) readU16(data[Offset.image_count..][0..2], endian) else 1;
    if (width == 0 or height == 0 or bits_per_pixel == 0 or image_count == 0) return error.InvalidFormat;

    const bytes_per_pixel = (bits_per_pixel + 7) / 8;
    return .{
        .width = width,
        .height = height,
        .image_count = image_count,
        .pixel_type = switch (bytes_per_pixel) {
            1 => .uint8,
            2 => .uint16,
            4 => .uint32,
            else => return error.UnsupportedVariant,
        },
        .little_endian = little_endian,
    };
}

fn readU16(bytes: []const u8, endian: std.builtin.Endian) u16 {
    return std.mem.readInt(u16, bytes[0..2], endian);
}

fn writeU16(bytes: []u8, offset: usize, value: u16, endian: std.builtin.Endian) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, endian);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(list: *std.ArrayList(u8), endian: std.builtin.Endian, version: u16, width: u16, height: u16, bits_per_pixel: u16, image_count: u16) !void {
    try list.appendNTimes(std.testing.allocator, 0, pixel_offset);
    if (endian == .little) {
        list.items[0] = 1;
        list.items[1] = 0;
    } else {
        list.items[0] = 0;
        list.items[1] = 1;
    }
    @memcpy(list.items[Offset.signature..][0..signature.len], signature);
    writeU16(list.items, Offset.version, version, endian);
    writeU16(list.items, Offset.width, width, endian);
    writeU16(list.items, Offset.height, height, endian);
    writeU16(list.items, Offset.bits_per_pixel, bits_per_pixel, endian);
    writeU16(list.items, Offset.image_count, image_count, endian);
}

test "reads arf little-endian uint16 planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, .little, 2, 2, 1, 16, 2);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0 });
    try data.appendSlice(std.testing.allocator, &.{ 3, 0, 4, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 4, 0 }, plane.data);
}

test "reads arf big-endian uint8 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, .big, 1, 2, 1, 8, 0);
    try data.appendSlice(std.testing.allocator, &.{ 5, 6 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6 }, plane.data);
}

test "rejects truncated arf pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, .little, 2, 2, 1, 16, 2);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0 });

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
    try std.testing.expectError(error.TruncatedData, readPlaneIndex(std.testing.allocator, data.items, 1));
}
