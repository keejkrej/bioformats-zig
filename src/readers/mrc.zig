const std = @import("std");
const bio = @import("../root.zig");

const header_len = 1024;
const endian_stamp_offset = 212;
const ext_header_size_offset = 92;
const czi_magic = "ZISRAWFILE";
const nd2_magic1: u32 = 0xdacebe0a;
const nd2_magic1_alt: u32 = 0x0abeceda;
const nd2_magic2: u32 = 0x6a502020;

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
    if (std.mem.startsWith(u8, data, czi_magic)) return false;
    if (looksLikeNd2(data)) return false;
    if (looksLikeEcat7(data)) return false;
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
        .dimension_order = "XYZTC",
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
    if (std.mem.startsWith(u8, data, czi_magic)) return error.InvalidFormat;
    if (looksLikeNd2(data)) return error.InvalidFormat;
    if (looksLikeEcat7(data)) return error.InvalidFormat;
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

fn looksLikeEcat7(data: []const u8) bool {
    return std.mem.startsWith(u8, data, "MATRIX70v") or
        std.mem.startsWith(u8, data, "MATRIX72v");
}

fn looksLikeNd2(data: []const u8) bool {
    if (data.len < 8) return false;
    const first = std.mem.readInt(u32, data[0..4], .little);
    const second = std.mem.readInt(u32, data[4..8], .little);
    return first == nd2_magic1 or first == nd2_magic1_alt or second == nd2_magic2;
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

test "rejects ecat7 matrix headers as mrc candidates" {
    var data = [_]u8{0} ** header_len;
    @memcpy(data[0.."MATRIX70v".len], "MATRIX70v");

    try std.testing.expect(!matches(&data));
    try std.testing.expectError(error.InvalidFormat, readMetadata(&data));
}

test "rejects zeiss czi headers as mrc candidates" {
    var data = [_]u8{0} ** header_len;
    @memcpy(data[0..czi_magic.len], czi_magic);

    try std.testing.expect(!matches(&data));
    try std.testing.expectError(error.InvalidFormat, readMetadata(&data));
}

test "rejects nikon nd2 headers as mrc candidates" {
    var data = [_]u8{0} ** header_len;
    std.mem.writeInt(u32, data[0..4], nd2_magic1_alt, .little);

    try std.testing.expect(!matches(&data));
    try std.testing.expectError(error.InvalidFormat, readMetadata(&data));
}

test "matches Bio-Formats default metadata for cached MRC fixture" {
    const file_path = "fixtures/cache/mrc/EMD-2225.map";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("mrc", metadata.format);
    try std.testing.expectEqual(@as(u32, 128), metadata.width);
    try std.testing.expectEqual(@as(u32, 128), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 128), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 128), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 1), metadata.series_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYZTC", metadata.dimension_order.?);
}

test "matches Bio-Formats default plane and region hashes for cached MRC fixture" {
    const file_path = "fixtures/cache/mrc/EMD-2225.map";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const expected = [_]struct { plane: u32, sha256: [32]u8 }{
        .{ .plane = 0, .sha256 = .{ 0xa4, 0x5e, 0x67, 0x24, 0x9f, 0xe3, 0xdf, 0x7f, 0x86, 0xd5, 0x5a, 0x46, 0x2e, 0x9d, 0xef, 0x2d, 0xb3, 0x63, 0x5d, 0xf1, 0x87, 0xc8, 0x1a, 0xc2, 0xf3, 0x44, 0xa9, 0x03, 0x38, 0x67, 0x18, 0x74 } },
        .{ .plane = 64, .sha256 = .{ 0xba, 0xaa, 0x5f, 0xe2, 0x25, 0x9d, 0x08, 0xea, 0xcc, 0x10, 0x34, 0x69, 0x11, 0x5c, 0x0b, 0x0b, 0x56, 0x10, 0x7c, 0x02, 0xe6, 0xe5, 0x08, 0xef, 0x4b, 0x99, 0xb0, 0x41, 0x22, 0xc7, 0x65, 0xc0 } },
        .{ .plane = 127, .sha256 = .{ 0x2d, 0x7e, 0x45, 0x8d, 0x64, 0x7c, 0x75, 0x87, 0xe7, 0x7f, 0xe7, 0xc1, 0x0f, 0xda, 0x45, 0x94, 0x1c, 0x1c, 0x4f, 0xe0, 0x84, 0xe4, 0x02, 0xa9, 0x8a, 0x98, 0x7d, 0x4c, 0xd2, 0xa6, 0x46, 0xb3 } },
    };
    for (expected) |sample| {
        const plane = try readPlaneIndex(std.testing.allocator, data, sample.plane);
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqual(@as(usize, 65536), plane.data.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
        try std.testing.expectEqualSlices(u8, &sample.sha256, &digest);
    }

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    const region_data = try bio.cropPlane(std.testing.allocator, plane, .{
        .x = 17,
        .y = 19,
        .width = 16,
        .height = 12,
    });
    defer std.testing.allocator.free(region_data);
    try std.testing.expectEqual(@as(usize, 768), region_data.len);
    const expected_region: [32]u8 = .{ 0x88, 0x83, 0x1e, 0xca, 0x7f, 0x59, 0x14, 0x79, 0x30, 0x09, 0x9a, 0xef, 0xad, 0xab, 0x40, 0x47, 0x34, 0x39, 0x8e, 0x38, 0xce, 0x01, 0x19, 0x23, 0x66, 0x67, 0x35, 0x9e, 0x38, 0xde, 0x62, 0xc6 };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(region_data, &digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_region, &digest);
}
