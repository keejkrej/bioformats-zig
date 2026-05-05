const std = @import("std");
const bio = @import("../root.zig");

const magic: u16 = 0xab01;
const base_offset = 1024;

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
    plane_count: u32,
    channels: u16,
    pixel_type: bio.PixelType,
    indexed: bool,
    lut_channels: u32,
    lut_entries: u32,
    data_offset: usize,
};

pub fn matches(data: []const u8) bool {
    return data.len >= 2 and std.mem.readInt(u16, data[0..2], .big) == magic;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "khoros",
        .width = header.width,
        .height = header.height,
        .size_c = header.channels,
        .samples_per_pixel = header.channels,
        .size_z = @intCast(@min(header.plane_count, std.math.maxInt(u16))),
        .pixel_type = header.pixel_type,
        .little_endian = header.order == .little,
        .plane_count = header.plane_count,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const src_plane_len = try sourcePlaneByteCount(header);
    const src_offset = std.math.add(usize, header.data_offset, std.math.mul(usize, src_plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (src_offset > data.len or data.len - src_offset < src_plane_len) return error.TruncatedData;
    const out_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    if (header.indexed) {
        expandIndexed(data, header, data[src_offset..][0..src_plane_len], out);
    } else {
        @memcpy(out, data[src_offset..][0..src_plane_len]);
    }
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < base_offset) return error.InvalidFormat;
    if (!matches(data)) return error.InvalidFormat;
    const dependency = std.mem.readInt(u32, data[4..8], .little);
    const order: ByteOrder = if (dependency == 4 or dependency == 8) .little else .big;
    const width = try positiveU32(readI32(order, data[520..524]));
    const height = try positiveU32(readI32(order, data[524..528]));
    var plane_count = try nonnegativeU32(readI32(order, data[556..560]));
    if (plane_count == 0) plane_count = 1;
    const stored_channels = try positiveU32(readI32(order, data[560..564]));
    const type_code = readI32(order, data[564..568]);
    const lut_channels = try nonnegativeU32(readI32(order, data[580..584]));
    const indexed = lut_channels > 1;
    const lut_entries = if (indexed) try positiveU32(readI32(order, data[584..588])) else 0;
    const lut_bytes = if (indexed) std.math.mul(usize, lut_channels, lut_entries) catch return error.UnsupportedVariant else 0;
    const data_offset = std.math.add(usize, base_offset, lut_bytes) catch return error.UnsupportedVariant;
    if (data_offset > data.len) return error.TruncatedData;
    const channels: u16 = if (indexed) 3 else @intCast(stored_channels);
    if (!indexed and channels != 1 and channels != 3) return error.UnsupportedVariant;
    if (indexed and (type_code != 1 or lut_channels < 3 or lut_entries > 256)) return error.UnsupportedVariant;
    const pixel_type = try pixelType(type_code, indexed, channels);
    return .{
        .order = order,
        .width = width,
        .height = height,
        .plane_count = plane_count,
        .channels = channels,
        .pixel_type = pixel_type,
        .indexed = indexed,
        .lut_channels = lut_channels,
        .lut_entries = lut_entries,
        .data_offset = data_offset,
    };
}

fn pixelType(type_code: i32, indexed: bool, channels: u16) bio.ReaderError!bio.PixelType {
    if (indexed) return .rgb8;
    if (channels == 3) {
        return switch (type_code) {
            1 => .rgb8,
            2 => .rgb16,
            else => error.UnsupportedVariant,
        };
    }
    return switch (type_code) {
        0 => .int8,
        1 => .uint8,
        2 => .uint16,
        4 => .int32,
        5 => .float32,
        9 => .float64,
        else => error.UnsupportedVariant,
    };
}

fn sourcePlaneByteCount(header: Header) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    if (header.indexed) return pixels;
    return std.math.mul(usize, pixels, @as(usize, header.channels) * header.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn expandIndexed(data: []const u8, header: Header, indices: []const u8, out: []u8) void {
    const lut = data[base_offset..][0 .. header.lut_channels * header.lut_entries];
    const entries: usize = header.lut_entries;
    for (indices, 0..) |index, i| {
        const idx: usize = @min(index, entries - 1);
        const dst = i * 3;
        out[dst + 0] = lut[idx];
        out[dst + 1] = lut[entries + idx];
        out[dst + 2] = lut[entries * 2 + idx];
    }
}

fn positiveU32(value: i32) bio.ReaderError!u32 {
    if (value <= 0) return error.InvalidFormat;
    return @intCast(value);
}

fn nonnegativeU32(value: i32) bio.ReaderError!u32 {
    if (value < 0) return error.InvalidFormat;
    return @intCast(value);
}

fn readI32(order: ByteOrder, bytes: []const u8) i32 {
    return std.mem.readInt(i32, bytes[0..4], order.endian());
}

fn writeI32(bytes: []u8, offset: usize, value: i32) void {
    std.mem.writeInt(i32, bytes[offset..][0..4], value, .little);
}

fn appendHeader(list: *std.ArrayList(u8), width: i32, height: i32, planes: i32, channels: i32, type_code: i32) !void {
    try list.appendNTimes(std.testing.allocator, 0, base_offset);
    std.mem.writeInt(u16, list.items[0..2], magic, .big);
    writeI32(list.items, 4, 4);
    writeI32(list.items, 520, width);
    writeI32(list.items, 524, height);
    writeI32(list.items, 556, planes);
    writeI32(list.items, 560, channels);
    writeI32(list.items, 564, type_code);
}

fn appendLutHeader(list: *std.ArrayList(u8), width: i32, height: i32, entries: i32) !void {
    try appendHeader(list, width, height, 1, 1, 1);
    writeI32(list.items, 580, 3);
    writeI32(list.items, 584, entries);
}

test "reads khoros grayscale plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 1, 1, 1);
    try data.appendSlice(std.testing.allocator, &.{ 7, 9 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "reads second khoros rgb plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 2, 3, 1);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4, 5, 6 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "expands khoros palette image" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendLutHeader(&data, 2, 1, 3);
    try data.appendSlice(std.testing.allocator, &.{ 0, 10, 40, 20, 50, 30, 60, 99, 99 });
    try data.appendSlice(std.testing.allocator, &.{ 1, 2 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgb8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 50, 60 }, plane.data);
}
