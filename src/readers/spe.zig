const std = @import("std");
const bio = @import("../root.zig");

const header_len = 4100;

const Offset = struct {
    const width = 42;
    const data_type = 108;
    const height = 656;
    const frames = 1446;
};

const Header = struct {
    width: u32,
    height: u32,
    frames: u32,
    pixel_type: bio.PixelType,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "spe",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
        .plane_count = header.frames,
    }) catch return false;
    const pixel_bytes = std.math.mul(usize, plane_len, header.frames) catch return false;
    return data.len >= header_len + pixel_bytes;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "spe",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_t = @intCast(@min(header.frames, std.math.maxInt(u16))),
        .pixel_type = header.pixel_type,
        .little_endian = true,
        .plane_count = header.frames,
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
    if (data.len < header_len) return error.InvalidFormat;
    const width = try positiveU32(readU16(data[Offset.width..][0..2]));
    const height = try positiveU32(readU16(data[Offset.height..][0..2]));
    const frames = readU32(data[Offset.frames..][0..4]);
    if (frames == 0) return error.InvalidFormat;
    return .{
        .width = width,
        .height = height,
        .frames = frames,
        .pixel_type = try pixelType(readU16(data[Offset.data_type..][0..2])),
    };
}

fn pixelType(data_type: u16) bio.ReaderError!bio.PixelType {
    return switch (data_type) {
        0 => .float32,
        1 => .int32,
        2 => .int16,
        3 => .uint16,
        4 => .uint32,
        else => error.UnsupportedVariant,
    };
}

fn positiveU32(value: u16) bio.ReaderError!u32 {
    if (value == 0) return error.InvalidFormat;
    return value;
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(list: *std.ArrayList(u8), width: u16, height: u16, frames: u32, data_type: u16) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_len);
    writeU16(list.items, Offset.width, width);
    writeU16(list.items, Offset.height, height);
    writeU32(list.items, Offset.frames, frames);
    writeU16(list.items, Offset.data_type, data_type);
}

test "reads 16-bit spe frame" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 1, 3);
    try data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12, 0xcd, 0xab });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
}

test "reads second spe time frame" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 2, 0);
    try data.appendSlice(std.testing.allocator, &.{ 0, 0, 0x80, 0x3f, 0, 0, 0, 0x40 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0x40 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "rejects unsupported spe pixel type" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 1, 9);
    try data.append(std.testing.allocator, 0);

    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}
