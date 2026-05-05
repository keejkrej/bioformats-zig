const std = @import("std");
const bio = @import("../root.zig");

const header_len = 1024;
const endian_stamp_offset = 212;
const ext_header_size_offset = 92;

const ByteOrder = enum {
    little,
    big,

    fn endian(self: ByteOrder) std.builtin.Endian {
        return switch (self) {
            .little => .little,
            .big => .big,
        };
    }
};

const Header = struct {
    order: ByteOrder,
    width: u32,
    height: u32,
    planes: u32,
    mode: i32,
    pixel_offset: usize,

    fn pixelType(self: Header) bio.ReaderError!bio.PixelType {
        return switch (self.mode) {
            0 => .uint8,
            1 => .int16,
            2 => .float32,
            6 => .uint16,
            16 => .rgb8,
            else => error.UnsupportedVariant,
        };
    }
};

pub fn matches(data: []const u8) bool {
    if (data.len < header_len) return false;
    const stamp = data[endian_stamp_offset];
    if (stamp == 68) return candidateValid(data, .little);
    if (stamp == 17) return candidateValid(data, .big);
    return candidateValid(data, .little) or candidateValid(data, .big);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    const pixel_type = try header.pixelType();
    const samples: u16 = if (header.mode == 16) 3 else 1;
    return .{
        .format = "mrc",
        .width = header.width,
        .height = header.height,
        .size_c = samples,
        .samples_per_pixel = samples,
        .size_z = @intCast(@min(header.planes, std.math.maxInt(u16))),
        .pixel_type = pixel_type,
        .little_endian = header.order == .little,
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
    const row_bytes = std.math.mul(usize, metadata.width, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
    const plane_len = std.math.mul(usize, row_bytes, metadata.height) catch return error.UnsupportedVariant;
    const plane_offset = std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant;
    const offset = std.math.add(usize, header.pixel_offset, plane_offset) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    copyFlippedRows(data[offset..][0..plane_len], row_bytes, metadata.height, out);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_len) return error.InvalidFormat;
    const stamp = data[endian_stamp_offset];
    const order: ByteOrder = if (stamp == 68)
        .little
    else if (stamp == 17)
        .big
    else if (candidateValid(data, .little))
        .little
    else if (candidateValid(data, .big))
        .big
    else
        return error.InvalidFormat;
    if (!candidateValid(data, order)) return error.InvalidFormat;
    const ext_header_size_i32 = readI32(order, data[ext_header_size_offset..][0..4]);
    if (ext_header_size_i32 < 0) return error.InvalidFormat;
    const pixel_offset = std.math.add(usize, header_len, @as(usize, @intCast(ext_header_size_i32))) catch return error.UnsupportedVariant;
    if (pixel_offset > data.len) return error.TruncatedData;
    return .{
        .order = order,
        .width = @intCast(readI32(order, data[0..4])),
        .height = @intCast(readI32(order, data[4..8])),
        .planes = @intCast(readI32(order, data[8..12])),
        .mode = readI32(order, data[12..16]),
        .pixel_offset = pixel_offset,
    };
}

fn candidateValid(data: []const u8, order: ByteOrder) bool {
    const width = readI32(order, data[0..4]);
    const height = readI32(order, data[4..8]);
    const planes = readI32(order, data[8..12]);
    const mode = readI32(order, data[12..16]);
    const ext_header_size = readI32(order, data[ext_header_size_offset..][0..4]);
    if (width <= 0 or height <= 0 or planes <= 0 or ext_header_size < 0) return false;
    if (mode != 0 and mode != 1 and mode != 2 and mode != 6 and mode != 16) return false;
    const offset = std.math.add(usize, header_len, @as(usize, @intCast(ext_header_size))) catch return false;
    return offset <= data.len;
}

fn copyFlippedRows(src: []const u8, row_bytes: usize, height: u32, out: []u8) void {
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src_row = (@as(usize, height) - 1 - y) * row_bytes;
        const dst_row = y * row_bytes;
        @memcpy(out[dst_row..][0..row_bytes], src[src_row..][0..row_bytes]);
    }
}

fn readI32(order: ByteOrder, bytes: []const u8) i32 {
    return std.mem.readInt(i32, bytes[0..4], order.endian());
}

fn setI32(bytes: []u8, offset: usize, value: i32) void {
    std.mem.writeInt(i32, bytes[offset..][0..4], value, .little);
}

fn appendHeader(list: *std.ArrayList(u8), width: i32, height: i32, planes: i32, mode: i32, ext_header_size: i32) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_len);
    setI32(list.items, 0, width);
    setI32(list.items, 4, height);
    setI32(list.items, 8, planes);
    setI32(list.items, 12, mode);
    setI32(list.items, ext_header_size_offset, ext_header_size);
    list.items[endian_stamp_offset] = 68;
}

test "reads 8-bit mrc plane with flipped rows" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 2, 1, 0, 0);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4, 1, 2 }, plane.data);
}

test "reads second mrc z plane after extended header" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 2, 6, 4);
    try data.appendSlice(std.testing.allocator, &.{ 9, 9, 9, 9 });
    try data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12, 0xcd, 0xab });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0xcd, 0xab }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads rgb mrc metadata and pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 1, 16, 0);
    try data.appendSlice(std.testing.allocator, &.{ 10, 20, 30 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgb8, plane.metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), plane.metadata.samples_per_pixel);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30 }, plane.data);
}
