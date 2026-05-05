const std = @import("std");
const bio = @import("../root.zig");

const magic: i32 = 5021964;
const fixed_header_len = 336;
const channel_header_len = 164;

const Header = struct {
    width: u32,
    height: u32,
    size_z: u16,
    size_c: u16,
    pixel_offset: usize,

    fn planeCount(self: Header) u32 {
        return @as(u32, self.size_z) * @as(u32, self.size_c);
    }
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "imaris",
        .width = header.width,
        .height = header.height,
        .size_c = header.size_c,
        .samples_per_pixel = 1,
        .size_z = header.size_z,
        .size_t = 1,
        .pixel_type = .uint8,
        .little_endian = false,
        .plane_count = header.planeCount(),
        .dimension_order = "XYZCT",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    if (plane_index >= header.planeCount()) return error.InvalidPlaneIndex;
    const metadata = try readMetadata(data);
    const plane_len = try planeByteCount(metadata);
    const relative_offset = std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant;
    const offset = std.math.add(usize, header.pixel_offset, relative_offset) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;

    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    copyFlippedRows(data[offset..][0..plane_len], metadata.width, metadata.height, out);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < fixed_header_len) return error.TruncatedData;
    if (readI32(data, 0) != magic) return error.InvalidFormat;

    const width = try positiveI16AsU32(readI16(data, 140));
    const height = try positiveI16AsU32(readI16(data, 142));
    const size_z_raw = try positiveI16AsU32(readI16(data, 144));
    const size_c_raw = try positiveI32AsU32(readI32(data, 148));
    if (size_z_raw > std.math.maxInt(u16) or size_c_raw > std.math.maxInt(u16)) return error.UnsupportedVariant;

    const pixel_offset = std.math.add(usize, fixed_header_len, std.math.mul(usize, channel_header_len, size_c_raw) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    const plane_len = std.math.mul(usize, width, height) catch return error.UnsupportedVariant;
    const plane_count = std.math.mul(usize, size_z_raw, size_c_raw) catch return error.UnsupportedVariant;
    const pixel_len = std.math.mul(usize, plane_len, plane_count) catch return error.UnsupportedVariant;
    if (pixel_offset > data.len or data.len - pixel_offset < pixel_len) return error.TruncatedData;

    return .{
        .width = width,
        .height = height,
        .size_z = @intCast(size_z_raw),
        .size_c = @intCast(size_c_raw),
        .pixel_offset = pixel_offset,
    };
}

fn positiveI16AsU32(value: i16) bio.ReaderError!u32 {
    if (value <= 0) return error.InvalidFormat;
    return @intCast(value);
}

fn positiveI32AsU32(value: i32) bio.ReaderError!u32 {
    if (value <= 0) return error.InvalidFormat;
    return @intCast(value);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    return std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
}

fn copyFlippedRows(src: []const u8, width: u32, height: u32, out: []u8) void {
    const row_bytes: usize = width;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src_row = (@as(usize, height) - 1 - y) * row_bytes;
        const dst_row = y * row_bytes;
        @memcpy(out[dst_row..][0..row_bytes], src[src_row..][0..row_bytes]);
    }
}

fn readI16(data: []const u8, offset: usize) i16 {
    return std.mem.readInt(i16, data[offset..][0..2], .big);
}

fn readI32(data: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, data[offset..][0..4], .big);
}

fn writeI16(data: []u8, offset: usize, value: i16) void {
    std.mem.writeInt(i16, data[offset..][0..2], value, .big);
}

fn writeI32(data: []u8, offset: usize, value: i32) void {
    std.mem.writeInt(i32, data[offset..][0..4], value, .big);
}

fn appendHeader(list: *std.ArrayList(u8), width: i16, height: i16, size_z: i16, size_c: i32) !void {
    const channel_count = try positiveI32AsU32(size_c);
    const total_header = fixed_header_len + channel_header_len * @as(usize, channel_count);
    try list.appendNTimes(std.testing.allocator, 0, total_header);
    writeI32(list.items, 0, magic);
    writeI32(list.items, 4, 1);
    writeI16(list.items, 140, width);
    writeI16(list.items, 142, height);
    writeI16(list.items, 144, size_z);
    writeI32(list.items, 148, size_c);
}

test "reads imaris metadata and flips rows" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 2, 2, 1);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("imaris", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 5, 6 }, plane.data);
}

test "maps imaris z fastest then channel" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 2, 2);
    try data.appendSlice(std.testing.allocator, &.{ 10, 11, 20, 21 });

    const metadata = try readMetadata(data.items);
    const c1z0 = try metadata.planeIndex(0, 1, 0);
    try std.testing.expectEqual(@as(u32, 2), c1z0);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, c1z0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{20}, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 4));
}

test "rejects truncated imaris pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 2, 1, 1);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3 });

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readMetadata(data.items));
}
