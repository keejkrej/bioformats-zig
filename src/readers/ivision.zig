const std = @import("std");
const bio = @import("../root.zig");

const base_image_offset: usize = 72;
const lut_len: usize = 2048;

const Header = struct {
    width: u32,
    height: u32,
    size_z: u16,
    size_c: u16,
    samples_per_pixel: u16,
    pixel_type: bio.PixelType,
    image_offset: usize,
    stored_plane_len: usize,
    has_padding_byte: bool,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "ivision",
        .width = header.width,
        .height = header.height,
        .size_c = header.size_c,
        .samples_per_pixel = header.samples_per_pixel,
        .size_z = header.size_z,
        .size_t = 1,
        .pixel_type = header.pixel_type,
        .little_endian = false,
        .plane_count = header.size_z,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    if (plane_index >= header.size_z) return error.InvalidPlaneIndex;
    const metadata = try readMetadata(data);
    const out_len = try planeByteCount(metadata);
    const relative_offset = std.math.mul(usize, header.stored_plane_len, plane_index) catch return error.UnsupportedVariant;
    const offset = std.math.add(usize, header.image_offset, relative_offset) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < header.stored_plane_len) return error.TruncatedData;

    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    const src = data[offset..][0..header.stored_plane_len];
    if (header.has_padding_byte) {
        copyPaddedRgb(src, out, metadata.width, metadata.height);
    } else {
        @memcpy(out, src[0..out_len]);
    }
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < base_image_offset) return error.TruncatedData;
    if (!looksLikeVersion(data)) return error.InvalidFormat;

    const data_type = data[5];
    const width = try positiveI32AsU32(readI32(data, 6));
    const height = try positiveI32AsU32(readI32(data, 10));
    const size_z_raw = try positiveI16AsU32(readI16(data, 20));
    if (size_z_raw > std.math.maxInt(u16)) return error.UnsupportedVariant;

    const image_offset = if (width > 1 and height > 1) base_image_offset + lut_len else base_image_offset;
    const pixels = std.math.mul(usize, width, height) catch return error.UnsupportedVariant;
    const layout = try pixelLayout(data_type, pixels);
    const all_pixels = std.math.mul(usize, layout.stored_plane_len, size_z_raw) catch return error.UnsupportedVariant;
    if (image_offset > data.len or data.len - image_offset < all_pixels) return error.TruncatedData;

    return .{
        .width = width,
        .height = height,
        .size_z = @intCast(size_z_raw),
        .size_c = layout.size_c,
        .samples_per_pixel = layout.samples_per_pixel,
        .pixel_type = layout.pixel_type,
        .image_offset = image_offset,
        .stored_plane_len = layout.stored_plane_len,
        .has_padding_byte = layout.has_padding_byte,
    };
}

const PixelLayout = struct {
    size_c: u16,
    samples_per_pixel: u16,
    pixel_type: bio.PixelType,
    stored_plane_len: usize,
    has_padding_byte: bool = false,
};

fn pixelLayout(data_type: u8, pixels: usize) bio.ReaderError!PixelLayout {
    return switch (data_type) {
        0 => scalarLayout(.uint8, pixels, 1),
        1 => scalarLayout(.int16, pixels, 2),
        2 => scalarLayout(.int32, pixels, 4),
        3 => scalarLayout(.float32, pixels, 4),
        5 => .{
            .size_c = 3,
            .samples_per_pixel = 3,
            .pixel_type = .rgb8,
            .stored_plane_len = std.math.mul(usize, pixels, 4) catch return error.UnsupportedVariant,
            .has_padding_byte = true,
        },
        6 => scalarLayout(.uint16, pixels, 2),
        8 => rgbLayout(.rgb16, pixels, 2),
        4, 7 => error.UnsupportedVariant,
        else => error.InvalidFormat,
    };
}

fn scalarLayout(pixel_type: bio.PixelType, pixels: usize, bytes_per_sample: usize) bio.ReaderError!PixelLayout {
    return .{
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = pixel_type,
        .stored_plane_len = std.math.mul(usize, pixels, bytes_per_sample) catch return error.UnsupportedVariant,
    };
}

fn rgbLayout(pixel_type: bio.PixelType, pixels: usize, bytes_per_sample: usize) bio.ReaderError!PixelLayout {
    const samples = std.math.mul(usize, pixels, 3) catch return error.UnsupportedVariant;
    return .{
        .size_c = 3,
        .samples_per_pixel = 3,
        .pixel_type = pixel_type,
        .stored_plane_len = std.math.mul(usize, samples, bytes_per_sample) catch return error.UnsupportedVariant,
    };
}

fn copyPaddedRgb(src: []const u8, out: []u8, width: u32, height: u32) void {
    const pixels = @as(usize, width) * @as(usize, height);
    var pixel: usize = 0;
    while (pixel < pixels) : (pixel += 1) {
        @memcpy(out[pixel * 3 ..][0..3], src[pixel * 4 + 1 ..][0..3]);
    }
}

fn looksLikeVersion(data: []const u8) bool {
    return isVersionByte(data[0]) and isVersionByte(data[1]) and isVersionByte(data[2]) and
        std.mem.indexOfScalar(u8, data[0..3], '.') != null and data[0] != '-' and data[1] != '-' and
        data[2] != '-' and isAlphabetic(data[3]) and data[5] <= 8;
}

fn isVersionByte(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or byte == '.';
}

fn isAlphabetic(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z');
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
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
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

fn appendHeader(list: *std.ArrayList(u8), data_type: u8, width: i32, height: i32, size_z: i16) !void {
    const image_offset = if (width > 1 and height > 1) base_image_offset + lut_len else base_image_offset;
    try list.appendNTimes(std.testing.allocator, 0, @intCast(image_offset));
    @memcpy(list.items[0..4], "1.0a");
    list.items[4] = 0;
    list.items[5] = data_type;
    writeI32(list.items, 6, width);
    writeI32(list.items, 10, height);
    writeI16(list.items, 20, size_z);
}

test "reads ivision uint16 z planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 6, 1, 2, 2);
    try data.appendSlice(std.testing.allocator, &.{ 0, 1, 0, 2, 0, 3, 0, 4 });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("ivision", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 3, 0, 4 }, plane.data);
}

test "reads ivision padded rgb8" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 5, 2, 1, 1);
    try data.appendSlice(std.testing.allocator, &.{ 0, 10, 11, 12, 0, 20, 21, 22 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 10, 11, 12, 20, 21, 22 }, plane.data);
}

test "rejects unsupported ivision square-root data" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 7, 1, 1, 1);
    try data.appendSlice(std.testing.allocator, &.{ 0, 0 });

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}
