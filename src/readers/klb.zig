const std = @import("std");
const bio = @import("../root.zig");

const dims_count = 5;
const metadata_size = 256;
const offsets_pos = 1 + dims_count * 4 + dims_count * 4 + 1 + 1 + metadata_size + dims_count * 4;

const Header = struct {
    version: u8,
    dims: [dims_count]u32,
    block_size: [dims_count]u32,
    data_type: u8,
    compression: u8,
    block_count: usize,
    header_size: usize,

    fn pixelType(self: Header) bio.ReaderError!bio.PixelType {
        return switch (self.data_type) {
            0 => .uint8,
            1 => .uint16,
            2 => .uint32,
            4 => .int8,
            5 => .int16,
            6 => .int32,
            8 => .float32,
            9 => .float64,
            else => error.UnsupportedVariant,
        };
    }
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    const pixel_type = try header.pixelType();
    return .{
        .format = "klb",
        .width = header.dims[0],
        .height = header.dims[1],
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.dims[2], std.math.maxInt(u16))),
        .size_t = 1,
        .pixel_type = pixel_type,
        .little_endian = true,
        .plane_count = header.dims[2],
        .dimension_order = "XYZCT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    if (header.compression != 0) return error.UnsupportedVariant;
    if (header.block_count != 1 or !std.mem.eql(u32, &header.dims, &header.block_size)) return error.UnsupportedVariant;
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;

    const plane_len = try planeByteCount(metadata);
    const plane_offset = std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant;
    const offset = std.math.add(usize, header.header_size, plane_offset) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;

    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < offsets_pos + 8) return error.InvalidFormat;
    const version = data[0];
    if (version != 1 and version != 2) return error.InvalidFormat;

    var pos: usize = 1;
    var dims: [dims_count]u32 = undefined;
    for (&dims) |*dim| {
        dim.* = readU32(data[pos..][0..4]);
        pos += 4;
    }
    for (dims) |dim| {
        if (dim == 0) return error.InvalidFormat;
    }

    pos += dims_count * 4;
    const data_type = data[pos];
    pos += 1;
    const compression = data[pos];
    pos += 1;
    if (!isKnownDataType(data_type) or compression > 2) return error.InvalidFormat;
    pos += metadata_size;

    var block_size: [dims_count]u32 = undefined;
    for (&block_size) |*dim| {
        dim.* = readU32(data[pos..][0..4]);
        pos += 4;
        if (dim.* == 0) return error.InvalidFormat;
    }

    var block_count: usize = 1;
    for (dims, block_size) |dim, block| {
        const blocks_for_dim = ceilDiv(dim, block);
        block_count = std.math.mul(usize, block_count, blocks_for_dim) catch return error.UnsupportedVariant;
    }
    const offsets_len = std.math.mul(usize, block_count, 8) catch return error.UnsupportedVariant;
    const header_size = std.math.add(usize, offsets_pos, offsets_len) catch return error.UnsupportedVariant;
    if (header_size > data.len) return error.TruncatedData;

    var previous_end: u64 = 0;
    var offset_pos: usize = offsets_pos;
    var i: usize = 0;
    while (i < block_count) : (i += 1) {
        const block_end = readU64(data[offset_pos..][0..8]);
        offset_pos += 8;
        if (block_end < previous_end) return error.InvalidFormat;
        previous_end = block_end;
    }
    if (previous_end == 0) return error.InvalidFormat;
    if (previous_end > std.math.maxInt(usize)) return error.UnsupportedVariant;
    if (data.len - header_size < @as(usize, @intCast(previous_end))) return error.TruncatedData;

    return .{
        .version = version,
        .dims = dims,
        .block_size = block_size,
        .data_type = data_type,
        .compression = compression,
        .block_count = block_count,
        .header_size = header_size,
    };
}

fn isKnownDataType(data_type: u8) bool {
    return data_type <= 9;
}

fn ceilDiv(numerator: u32, denominator: u32) usize {
    return (@as(usize, numerator) + @as(usize, denominator) - 1) / @as(usize, denominator);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn readU64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}

fn appendU32(list: *std.ArrayList(u8), value: u32) !void {
    try list.append(std.testing.allocator, @intCast(value & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
}

fn appendU64(list: *std.ArrayList(u8), value: u64) !void {
    try list.append(std.testing.allocator, @intCast(value & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 32) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 40) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 48) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 56) & 0xff));
}

fn appendHeader(list: *std.ArrayList(u8), dims: [dims_count]u32, block_size: [dims_count]u32, data_type: u8, compression: u8, block_end: u64) !void {
    try list.append(std.testing.allocator, 2);
    for (dims) |dim| try appendU32(list, dim);
    for (0..dims_count) |_| try appendU32(list, 0x3f800000);
    try list.append(std.testing.allocator, data_type);
    try list.append(std.testing.allocator, compression);
    try list.appendNTimes(std.testing.allocator, 0, metadata_size);
    for (block_size) |dim| try appendU32(list, dim);
    try appendU64(list, block_end);
}

test "reads uncompressed single-block klb z planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, .{ 2, 1, 2, 1, 1 }, .{ 2, 1, 2, 1, 1 }, 1, 0, 8);
    try data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12, 0xcd, 0xab, 0x78, 0x56, 0xef, 0xbe });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("klb", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0xef, 0xbe }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "rejects compressed klb pixels for now" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, .{ 1, 1, 1, 1, 1 }, .{ 1, 1, 1, 1, 1 }, 0, 2, 1);
    try data.append(std.testing.allocator, 7);

    try std.testing.expect(matches(data.items));
    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, data.items, 0));
}

test "rejects tiled klb pixels for now" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, .{ 2, 1, 1, 1, 1 }, .{ 1, 1, 1, 1, 1 }, 0, 0, 1);
    try appendU64(&data, 2);
    try data.appendSlice(std.testing.allocator, &.{ 7, 9 });

    try std.testing.expect(matches(data.items));
    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, data.items, 0));
}
