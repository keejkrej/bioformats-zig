const std = @import("std");
const bio = @import("../root.zig");

const header_len = 1024;

const Header = struct {
    width: u32,
    height: u32,
    size_z: u32,
    size_t: u32,
    pixel_type: bio.PixelType,
    little_endian: bool,
};

pub fn matches(data: []const u8) bool {
    if (data.len < header_len or data[1] != ' ') return false;
    if (data[0] != 'I' and data[0] != 'R' and data[0] != 'C') return false;
    _ = parseDimension(data[2..8]) catch return false;
    _ = parseDimension(data[8..14]) catch return false;
    _ = parseDimension(data[14..20]) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "i2i",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.size_z, std.math.maxInt(u16))),
        .size_t = @intCast(@min(header.size_t, std.math.maxInt(u16))),
        .pixel_type = header.pixel_type,
        .little_endian = header.little_endian,
        .plane_count = std.math.mul(u32, header.size_z, header.size_t) catch return error.UnsupportedVariant,
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
    if (!matches(data)) return error.InvalidFormat;
    const stored_z = try parseDimension(data[14..20]);
    const n_raw = readU16(data[29..31], data[20] != 'B');
    const size_t: u32 = if (n_raw == 0) 1 else n_raw;
    const size_z = if (n_raw > 0) stored_z / n_raw else stored_z;
    if (size_z == 0 or stored_z % size_t != 0) return error.InvalidFormat;
    return .{
        .width = try parseDimension(data[2..8]),
        .height = try parseDimension(data[8..14]),
        .size_z = size_z,
        .size_t = size_t,
        .pixel_type = try pixelType(data[0]),
        .little_endian = data[20] != 'B',
    };
}

fn pixelType(byte: u8) bio.ReaderError!bio.PixelType {
    return switch (byte) {
        'I' => .int16,
        'R' => .float32,
        'C' => error.UnsupportedVariant,
        else => error.InvalidFormat,
    };
}

fn parseDimension(bytes: []const u8) bio.ReaderError!u32 {
    const trimmed = std.mem.trim(u8, bytes, " ");
    if (trimmed.len == 0) return error.InvalidFormat;
    const value = std.fmt.parseInt(u32, trimmed, 10) catch return error.InvalidFormat;
    if (value == 0) return error.InvalidFormat;
    return value;
}

fn readU16(bytes: []const u8, little: bool) u16 {
    return std.mem.readInt(u16, bytes[0..2], if (little) .little else .big);
}

fn writeU16(bytes: []u8, offset: usize, value: u16, little: bool) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, if (little) .little else .big);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(list: *std.ArrayList(u8), kind: u8, width: []const u8, height: []const u8, stored_z: []const u8, little: bool, n: u16) !void {
    try list.appendNTimes(std.testing.allocator, ' ', header_len);
    list.items[0] = kind;
    list.items[1] = ' ';
    @memcpy(list.items[2 .. 2 + width.len], width);
    @memcpy(list.items[8 .. 8 + height.len], height);
    @memcpy(list.items[14 .. 14 + stored_z.len], stored_z);
    list.items[20] = if (little) 'L' else 'B';
    writeU16(list.items, 29, n, little);
}

test "reads int16 i2i plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 'I', "2", "1", "1", true, 0);
    try data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12, 0xcd, 0xab });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.int16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
}

test "reads second i2i time plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 'R', "1", "1", "4", false, 2);
    try data.appendSlice(std.testing.allocator, &.{ 0x3f, 0x80, 0, 0, 0x40, 0, 0, 0, 0x40, 0x40, 0, 0, 0x40, 0x80, 0, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 4), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x40, 0, 0, 0 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 4));
}

test "rejects complex i2i pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 'C', "1", "1", "1", true, 0);
    try data.appendSlice(std.testing.allocator, &.{ 0, 0 });

    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}
