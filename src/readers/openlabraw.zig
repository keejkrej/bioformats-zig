const std = @import("std");
const bio = @import("../root.zig");

const block_header_len = 288;
const first_block_offset = 12;
const magic = "OLRW";

const Header = struct {
    width: u32,
    height: u32,
    planes: u32,
    channels: u16,
    pixel_type: bio.PixelType,
    source_bytes_per_pixel: u8,
};

pub fn matches(data: []const u8) bool {
    return data.len >= magic.len and std.mem.eql(u8, data[0..magic.len], magic);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "openlabraw",
        .width = header.width,
        .height = header.height,
        .size_c = header.channels,
        .samples_per_pixel = header.channels,
        .size_z = @intCast(@min(header.planes, std.math.maxInt(u16))),
        .pixel_type = header.pixel_type,
        .little_endian = false,
        .plane_count = header.planes,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const source_plane_len = try sourcePlaneByteCount(header);
    const block_stride = std.math.add(usize, block_header_len, source_plane_len) catch return error.UnsupportedVariant;
    const block_offset = std.math.add(usize, first_block_offset, std.math.mul(usize, block_stride, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    const pixel_offset = std.math.add(usize, block_offset, block_header_len) catch return error.UnsupportedVariant;
    if (pixel_offset > data.len or data.len - pixel_offset < source_plane_len) return error.TruncatedData;
    const out_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    @memcpy(out, data[pixel_offset..][0..source_plane_len]);
    if (metadata.pixel_type.bytesPerSample() == 1) {
        for (out) |*byte| byte.* = 255 - byte.*;
    }
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    if (data.len < first_block_offset + block_header_len) return error.TruncatedData;
    const planes = readU32(data[8..12]);
    if (planes == 0) return error.InvalidFormat;
    const block = data[first_block_offset..][0..block_header_len];
    const width = readU32(block[8..12]);
    const height = readU32(block[12..16]);
    if (width == 0 or height == 0) return error.InvalidFormat;
    const channel_marker = block[17];
    const source_bytes_per_pixel = block[18];
    if (source_bytes_per_pixel == 0) return error.InvalidFormat;
    const channels: u16 = if (channel_marker <= 1) 1 else 3;
    return .{
        .width = width,
        .height = height,
        .planes = planes,
        .channels = channels,
        .pixel_type = try pixelType(source_bytes_per_pixel, channels),
        .source_bytes_per_pixel = source_bytes_per_pixel,
    };
}

fn pixelType(bytes_per_pixel: u8, channels: u16) bio.ReaderError!bio.PixelType {
    if (channels == 3) {
        return switch (bytes_per_pixel) {
            3 => .rgb8,
            6 => .rgb16,
            else => error.UnsupportedVariant,
        };
    }
    return switch (bytes_per_pixel) {
        1 => .uint8,
        2 => .uint16,
        4 => .float32,
        else => error.UnsupportedVariant,
    };
}

fn sourcePlaneByteCount(header: Header) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, header.source_bytes_per_pixel) catch return error.UnsupportedVariant;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .big);
}

fn appendFileHeader(list: *std.ArrayList(u8), planes: u32) !void {
    try list.appendSlice(std.testing.allocator, magic);
    try list.appendNTimes(std.testing.allocator, 0, 4);
    try appendU32Be(list, planes);
}

fn appendBlockHeader(list: *std.ArrayList(u8), width: u32, height: u32, channel_marker: u8, bytes_per_pixel: u8) !void {
    const start = list.items.len;
    try list.appendNTimes(std.testing.allocator, 0, block_header_len);
    writeU32(list.items[start..][0..block_header_len], 8, width);
    writeU32(list.items[start..][0..block_header_len], 12, height);
    list.items[start + 17] = channel_marker;
    list.items[start + 18] = bytes_per_pixel;
}

fn appendU32Be(list: *std.ArrayList(u8), value: u32) !void {
    try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
    try list.append(std.testing.allocator, @intCast(value & 0xff));
}

test "reads inverted 8-bit openlab raw plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendFileHeader(&data, 1);
    try appendBlockHeader(&data, 2, 1, 1, 1);
    try data.appendSlice(std.testing.allocator, &.{ 0, 255 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0 }, plane.data);
}

test "reads second openlab raw uint16 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendFileHeader(&data, 2);
    try appendBlockHeader(&data, 1, 1, 1, 2);
    try data.appendSlice(std.testing.allocator, &.{ 0x12, 0x34 });
    try appendBlockHeader(&data, 1, 1, 1, 2);
    try data.appendSlice(std.testing.allocator, &.{ 0xab, 0xcd });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads openlab raw rgb plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendFileHeader(&data, 1);
    try appendBlockHeader(&data, 1, 1, 3, 3);
    try data.appendSlice(std.testing.allocator, &.{ 10, 20, 30 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgb8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 245, 235, 225 }, plane.data);
}
