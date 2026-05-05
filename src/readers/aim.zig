const std = @import("std");
const bio = @import("../root.zig");

const old_dims_offset = 56;
const old_log_offset = 160;
const v030_dims_offset = 96;
const v030_log_offset = 280;

const Header = struct {
    width: u32,
    height: u32,
    planes: u32,
    pixel_offset: usize,
};

pub fn matches(data: []const u8) bool {
    return data.len >= 16 and std.mem.startsWith(u8, data, "AIMDATA");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "aim",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.planes, std.math.maxInt(u16))),
        .pixel_type = .int16,
        .little_endian = true,
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
    const plane_len = try planeByteCount(metadata);
    const offset = std.math.add(usize, header.pixel_offset, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    const wider = std.mem.startsWith(u8, data[0..16], "AIMDATA_V030");
    const dims_offset: usize = if (wider) v030_dims_offset else old_dims_offset;
    const log_offset: usize = if (wider) v030_log_offset else old_log_offset;
    const dims_len: usize = if (wider) 24 else 12;
    if (data.len < dims_offset + dims_len or data.len < log_offset) return error.TruncatedData;
    const width = if (wider) try positiveU32FromU64(readU64(data[dims_offset..][0..8])) else try positiveU32FromU32(readU32(data[dims_offset..][0..4]));
    const height = if (wider) try positiveU32FromU64(readU64(data[dims_offset + 8 ..][0..8])) else try positiveU32FromU32(readU32(data[dims_offset + 4 ..][0..4]));
    const planes = if (wider) try positiveU32FromU64(readU64(data[dims_offset + 16 ..][0..8])) else try positiveU32FromU32(readU32(data[dims_offset + 8 ..][0..4]));
    const nul = std.mem.indexOfScalarPos(u8, data, log_offset, 0) orelse return error.TruncatedData;
    const pixel_offset = nul + 1;
    if (pixel_offset > data.len) return error.TruncatedData;
    return .{
        .width = width,
        .height = height,
        .planes = planes,
        .pixel_offset = pixel_offset,
    };
}

fn positiveU32FromU32(value: u32) bio.ReaderError!u32 {
    if (value == 0) return error.InvalidFormat;
    return value;
}

fn positiveU32FromU64(value: u64) bio.ReaderError!u32 {
    if (value == 0 or value > std.math.maxInt(u32)) return error.InvalidFormat;
    return @intCast(value);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn readU64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn writeU64(bytes: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset..][0..8], value, .little);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendOldHeader(list: *std.ArrayList(u8), width: u32, height: u32, planes: u32) !void {
    try list.appendNTimes(std.testing.allocator, 0, old_log_offset);
    @memcpy(list.items[0..11], "AIMDATA_V02");
    writeU32(list.items, old_dims_offset, width);
    writeU32(list.items, old_dims_offset + 4, height);
    writeU32(list.items, old_dims_offset + 8, planes);
    try list.append(std.testing.allocator, 0);
}

fn appendV030Header(list: *std.ArrayList(u8), width: u64, height: u64, planes: u64) !void {
    try list.appendNTimes(std.testing.allocator, 0, v030_log_offset);
    @memcpy(list.items[0..12], "AIMDATA_V030");
    writeU64(list.items, v030_dims_offset, width);
    writeU64(list.items, v030_dims_offset + 8, height);
    writeU64(list.items, v030_dims_offset + 16, planes);
    try list.append(std.testing.allocator, 0);
}

test "reads old aim int16 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendOldHeader(&data, 2, 1, 1);
    try data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12, 0xcd, 0xab });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.int16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
}

test "reads second aim z plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendOldHeader(&data, 1, 1, 2);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads v030 aim dimensions" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendV030Header(&data, 1, 1, 1);
    try data.appendSlice(std.testing.allocator, &.{ 7, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 0 }, plane.data);
}
