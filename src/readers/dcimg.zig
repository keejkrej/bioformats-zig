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
