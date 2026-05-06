const std = @import("std");
const bio = @import("../root.zig");

const signature = "DCIMG";
const version_1: u32 = 0x01000000;
const pixel_mono8: u32 = 1;
const pixel_mono16: u32 = 2;

const Header = struct {
    version: u32,
    header_size: usize,
    data_offset: usize,
    width: u32,
    height: u32,
    size_t: u32,
    pixel_type_code: u32,
    bytes_per_image: usize,
    frame_footer_size: usize,

    fn pixelType(self: Header) bio.ReaderError!bio.PixelType {
        return switch (self.pixel_type_code) {
            pixel_mono8 => .uint8,
            pixel_mono16 => .uint16,
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
    return .{
        .format = "dcimg",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = 1,
        .size_t = @intCast(@min(header.size_t, std.math.maxInt(u16))),
        .pixel_type = try header.pixelType(),
        .little_endian = true,
        .plane_count = header.size_t,
        .dimension_order = "XYZCT",
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
    if (header.bytes_per_image < plane_len) return error.InvalidFormat;

    const base = std.math.add(usize, header.header_size, header.data_offset) catch return error.UnsupportedVariant;
    const stride = std.math.add(usize, header.bytes_per_image, header.frame_footer_size) catch return error.UnsupportedVariant;
    const plane_offset = std.math.mul(usize, stride, plane_index) catch return error.UnsupportedVariant;
    const offset = std.math.add(usize, base, plane_offset) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < header.bytes_per_image) return error.TruncatedData;

    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    copyFlippedRows(data[offset..][0..plane_len], @as(usize, header.width) * metadata.bytesPerPixel(), header.height, out);
    return .{ .metadata = metadata, .data = out };
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    try region.validate(metadata);
    if (region.isFull(metadata)) return readPlaneIndex(allocator, data, plane_index);

    const bytes_per_pixel = metadata.bytesPerPixel();
    const full_row_bytes = std.math.mul(usize, metadata.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const region_row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, region_row_bytes, region.height) catch return error.UnsupportedVariant;

    const base = std.math.add(usize, header.header_size, header.data_offset) catch return error.UnsupportedVariant;
    const stride = std.math.add(usize, header.bytes_per_image, header.frame_footer_size) catch return error.UnsupportedVariant;
    const plane_offset = std.math.mul(usize, stride, plane_index) catch return error.UnsupportedVariant;
    const start_row = std.math.mul(usize, region.y, full_row_bytes) catch return error.UnsupportedVariant;
    const offset = std.math.add(usize, std.math.add(usize, base, plane_offset) catch return error.UnsupportedVariant, start_row) catch return error.UnsupportedVariant;
    const source_rows_len = std.math.mul(usize, region.height, full_row_bytes) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < source_rows_len) return error.TruncatedData;

    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    copyFlippedRegionRows(data[offset..][0..source_rows_len], full_row_bytes, region.x * bytes_per_pixel, region_row_bytes, region.height, out);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < 160 or !std.mem.eql(u8, data[0..signature.len], signature)) return error.InvalidFormat;
    const version = readU32(data[8..12]);
    if (version != version_1) return error.UnsupportedVariant;

    const header_size = try checkedUsize(readU32(data[40..44]));
    const file_size = readU32(data[52..56]);
    const file_size2 = readU32(data[68..72]);
    if (file_size != file_size2) return error.InvalidFormat;
    if (header_size > data.len or header_size + 128 > data.len) return error.TruncatedData;

    const size_t = readU32(data[header_size + 60 ..][0..4]);
    const pixel_type_code = readU32(data[header_size + 64 ..][0..4]);
    const width = readU32(data[header_size + 72 ..][0..4]);
    const height = readU32(data[header_size + 76 ..][0..4]);
    const bytes_per_image = try checkedUsize(readU32(data[header_size + 84 ..][0..4]));
    const data_offset = try checkedUsize(readU64(data[header_size + 96 ..][0..8]));
    const frame_footer_size = try checkedUsize(readU32(data[header_size + 124 ..][0..4]));
    if (width == 0 or height == 0 or size_t == 0) return error.InvalidFormat;

    const header = Header{
        .version = version,
        .header_size = header_size,
        .data_offset = data_offset,
        .width = width,
        .height = height,
        .size_t = size_t,
        .pixel_type_code = pixel_type_code,
        .bytes_per_image = bytes_per_image,
        .frame_footer_size = frame_footer_size,
    };
    const pixel_type = try header.pixelType();
    const expected_plane = try planeByteCount(.{
        .format = "dcimg",
        .width = width,
        .height = height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = pixel_type,
    });
    if (bytes_per_image < expected_plane) return error.InvalidFormat;
    const base = std.math.add(usize, header_size, data_offset) catch return error.UnsupportedVariant;
    const stride = std.math.add(usize, bytes_per_image, frame_footer_size) catch return error.UnsupportedVariant;
    const all_frames = std.math.mul(usize, stride, size_t) catch return error.UnsupportedVariant;
    if (base > data.len or data.len - base < all_frames) return error.TruncatedData;
    return header;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn copyFlippedRows(src: []const u8, row_bytes: usize, height: u32, out: []u8) void {
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src_row = (@as(usize, height) - 1 - y) * row_bytes;
        const dst_row = y * row_bytes;
        @memcpy(out[dst_row..][0..row_bytes], src[src_row..][0..row_bytes]);
    }
}

fn copyFlippedRegionRows(src: []const u8, src_row_bytes: usize, src_x: usize, dst_row_bytes: usize, height: u32, out: []u8) void {
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src_row = (@as(usize, height) - 1 - y) * src_row_bytes + src_x;
        const dst_row = y * dst_row_bytes;
        @memcpy(out[dst_row..][0..dst_row_bytes], src[src_row..][0..dst_row_bytes]);
    }
}

fn checkedUsize(value: u64) bio.ReaderError!usize {
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
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

fn appendHeader(list: *std.ArrayList(u8), width: u32, height: u32, frames: u32, pixel_type: u32, footer_size: u32) !void {
    const header_size: usize = 128;
    try list.appendNTimes(std.testing.allocator, 0, header_size + 128);
    @memcpy(list.items[0..signature.len], signature);
    writeU32(list.items, 8, version_1);
    writeU32(list.items, 40, header_size);
    writeU32(list.items, 52, @intCast(list.items.len));
    writeU32(list.items, 68, @intCast(list.items.len));
    writeU32(list.items, header_size + 60, frames);
    writeU32(list.items, header_size + 64, pixel_type);
    writeU32(list.items, header_size + 72, width);
    writeU32(list.items, header_size + 76, height);
    const bpp: u32 = if (pixel_type == pixel_mono16) 2 else 1;
    writeU32(list.items, header_size + 84, width * height * bpp);
    writeU64(list.items, header_size + 96, 128);
    writeU32(list.items, header_size + 124, footer_size);
}

test "reads dcimg version 1 mono8 time frame with flipped rows" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 2, 2, pixel_mono8, 0);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("dcimg", metadata.format);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 5, 6 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads dcimg version 1 mono16 metadata" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 1, pixel_mono16, 0);
    try data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expectEqual(@as(usize, 2), metadata.bytesPerPixel());
}

test "reads dcimg with frame footers" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 2, pixel_mono8, 16);
    try data.appendSlice(std.testing.allocator, &.{9});
    try data.appendNTimes(std.testing.allocator, 0xaa, 16);
    try data.appendSlice(std.testing.allocator, &.{7});
    try data.appendNTimes(std.testing.allocator, 0xbb, 16);

    try std.testing.expect(matches(data.items));
    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{7}, plane.data);
}

test "reads dcimg region with Bio-Formats row-window flip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 3, 3, 1, pixel_mono8, 0);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 });

    const region = try readRegionIndex(std.testing.allocator, data.items, 0, .{ .x = 1, .y = 0, .width = 2, .height = 2 });
    defer std.testing.allocator.free(region.data);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 2, 3 }, region.data);
}

test "matches Bio-Formats default metadata for cached DCIMG fixture" {
    const file_path = "fixtures/cache/dcimg/bead_bot4__560_00000_00000.dcimg";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("dcimg", metadata.format);
    try std.testing.expectEqual(@as(u32, 2048), metadata.width);
    try std.testing.expectEqual(@as(u32, 200), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 1), metadata.series_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYZCT", metadata.dimension_order.?);
}

test "matches Bio-Formats default plane and region hashes for cached DCIMG fixture" {
    const file_path = "fixtures/cache/dcimg/bead_bot4__560_00000_00000.dcimg";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(usize, 819200), plane.data.len);
    const expected_plane: [32]u8 = .{ 0x74, 0x7c, 0xef, 0x1b, 0xe1, 0x8a, 0xec, 0xb9, 0xd2, 0x1e, 0x74, 0xe1, 0x6a, 0x17, 0x7c, 0x09, 0x88, 0xce, 0x4f, 0xfe, 0x5d, 0xf3, 0x55, 0x7e, 0x7d, 0x52, 0x98, 0x2a, 0x82, 0xe0, 0x0d, 0xa5 };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_plane, &digest);

    const region = try readRegionIndex(std.testing.allocator, data, 0, .{ .x = 17, .y = 19, .width = 16, .height = 12 });
    defer std.testing.allocator.free(region.data);
    try std.testing.expectEqual(@as(usize, 384), region.data.len);
    const expected_region: [32]u8 = .{ 0xef, 0x3d, 0x0a, 0x0d, 0x83, 0xb3, 0xbc, 0xbd, 0x51, 0xb1, 0x83, 0x78, 0xe3, 0x6c, 0xa8, 0x31, 0x6f, 0x33, 0xfd, 0x33, 0x1a, 0x85, 0x5c, 0xad, 0x66, 0xa8, 0x0e, 0x78, 0x9d, 0x86, 0x63, 0x92 };
    std.crypto.hash.sha2.Sha256.hash(region.data, &digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_region, &digest);
}
