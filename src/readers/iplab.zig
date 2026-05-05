const std = @import("std");
const bio = @import("../root.zig");

const pixel_offset = 44;

const Header = struct {
    little_endian: bool,
    width: u32,
    height: u32,
    channels: u16,
    size_z: u16,
    size_t: u16,
    pixel_type: bio.PixelType,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "iplab",
        .width = header.width,
        .height = header.height,
        .size_c = header.channels,
        .samples_per_pixel = header.channels,
        .pixel_type = header.pixel_type,
    }) catch return false;
    const pixel_bytes = std.math.mul(usize, plane_len, @as(usize, header.size_z) * @as(usize, header.size_t)) catch return false;
    return data.len >= pixel_offset and data.len - pixel_offset >= pixel_bytes;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "iplab",
        .width = header.width,
        .height = header.height,
        .size_c = header.channels,
        .samples_per_pixel = header.channels,
        .size_z = header.size_z,
        .size_t = header.size_t,
        .pixel_type = header.pixel_type,
        .little_endian = header.little_endian,
        .plane_count = @as(u32, header.size_z) * @as(u32, header.size_t),
        .dimension_order = if (header.channels > 1) "XYCZT" else "XYZTC",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const offset = std.math.add(usize, pixel_offset, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < pixel_offset) return error.TruncatedData;
    const little = if (std.mem.eql(u8, data[0..4], "iiii"))
        true
    else if (std.mem.eql(u8, data[0..4], "mmmm"))
        false
    else
        return error.InvalidFormat;
    const endian: std.builtin.Endian = if (little) .little else .big;
    const first_block_size = readU32(data[4..8], endian);
    const version = readU32(data[8..12], endian);
    if (first_block_size != 4 or version < 0x100e) return error.InvalidFormat;

    const data_block_size = readU32(data[16..20], endian);
    if (data_block_size < 28) return error.InvalidFormat;
    const width = readU32(data[20..24], endian);
    const height = readU32(data[24..28], endian);
    const channels = readU32(data[28..32], endian);
    const size_z = readU32(data[32..36], endian);
    const size_t = readU32(data[36..40], endian);
    const file_pixel_type = readU32(data[40..44], endian);
    if (width == 0 or height == 0 or channels == 0 or size_z == 0 or size_t == 0) return error.InvalidFormat;
    if (channels > std.math.maxInt(u16) or size_z > std.math.maxInt(u16) or size_t > std.math.maxInt(u16)) return error.UnsupportedVariant;
    return .{
        .little_endian = little,
        .width = width,
        .height = height,
        .channels = @intCast(channels),
        .size_z = @intCast(size_z),
        .size_t = @intCast(size_t),
        .pixel_type = switch (file_pixel_type) {
            0 => .uint8,
            1 => .int16,
            2 => .uint16,
            3 => .int32,
            4 => .float32,
            10 => .float64,
            else => return error.UnsupportedVariant,
        },
    };
}

fn readU32(bytes: []const u8, endian: std.builtin.Endian) u32 {
    return std.mem.readInt(u32, bytes[0..4], endian);
}

fn writeU32(bytes: []u8, offset: usize, value: u32, endian: std.builtin.Endian) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, endian);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    const samples = std.math.mul(usize, pixels, metadata.samples_per_pixel) catch return error.UnsupportedVariant;
    return std.math.mul(usize, samples, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(
    list: *std.ArrayList(u8),
    endian: std.builtin.Endian,
    width: u32,
    height: u32,
    channels: u32,
    size_z: u32,
    size_t: u32,
    file_pixel_type: u32,
) !void {
    try list.appendNTimes(std.testing.allocator, 0, pixel_offset);
    @memcpy(list.items[0..4], if (endian == .little) "iiii" else "mmmm");
    writeU32(list.items, 4, 4, endian);
    writeU32(list.items, 8, 0x100e, endian);
    writeU32(list.items, 16, 28, endian);
    writeU32(list.items, 20, width, endian);
    writeU32(list.items, 24, height, endian);
    writeU32(list.items, 28, channels, endian);
    writeU32(list.items, 32, size_z, endian);
    writeU32(list.items, 36, size_t, endian);
    writeU32(list.items, 40, file_pixel_type, endian);
}

test "reads iplab uint8 z planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, .little, 2, 1, 1, 2, 1, 0);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const second = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, second.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads iplab big-endian multichannel uint16 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, .big, 1, 1, 2, 1, 1, 2);
    try data.appendSlice(std.testing.allocator, &.{ 0x12, 0x34, 0xab, 0xcd });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 2), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0xab, 0xcd }, plane.data);
}

test "rejects unsupported iplab pixel type" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, .little, 1, 1, 1, 1, 1, 5);
    try data.appendNTimes(std.testing.allocator, 0, 4);

    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}

