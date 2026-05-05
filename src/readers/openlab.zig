const std = @import("std");
const bio = @import("../root.zig");

const magic = [_]u8{ 0x00, 0x00, 0xff, 0xff, 'i', 'm', 'p', 'r' };
const image_type_1: u16 = 67;
const image_type_2: u16 = 68;

const mac_1_bit = 1;
const mac_4_greys = 2;
const mac_16_greys = 3;
const mac_16_colors = 4;
const mac_256_greys = 5;
const mac_256_colors = 6;
const mac_16_bit_color = 7;
const mac_24_bit_color = 8;
const deep_grey_9 = 9;
const deep_grey_16 = 16;

const Header = struct {
    version: u32,
    plane_count: u32,
    first_offset: usize,
};

const ImageInfo = struct {
    width: u32,
    height: u32,
    volume_type: u16,
    pixel_offset: usize,
    pict: bool,
    compressed: bool,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    var first: ?ImageInfo = null;
    var image_count: u32 = 0;

    var pos = header.first_offset;
    while (pos + tagHeaderLen(header.version) <= data.len and image_count < header.plane_count) {
        const tag_start = findNextImageTag(data, header.version, pos) orelse break;
        const tag = try readTagHeader(data, header.version, tag_start);
        if (tag.next <= tag_start or tag.next > data.len) return error.InvalidFormat;
        const info = try parseImage(data, header.version, tag);
        if (first == null) first = info;
        image_count += 1;
        pos = tag.next;
    }

    const image = first orelse return error.InvalidFormat;
    const samples = samplesPerPixel(image.volume_type);
    return .{
        .format = "openlab",
        .width = image.width,
        .height = image.height,
        .size_c = samples,
        .samples_per_pixel = samples,
        .size_z = @intCast(@min(@max(image_count, 1), std.math.maxInt(u16))),
        .size_t = 1,
        .pixel_type = pixelType(image.volume_type),
        .little_endian = false,
        .plane_count = @max(image_count, 1),
        .dimension_order = "XYCZT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;

    const image = try findImage(data, header, plane_index);
    if (header.version != 2 or image.pict or image.compressed) return error.UnsupportedVariant;
    if (!isSupportedRawVolume(image.volume_type)) return error.UnsupportedVariant;

    const plane_len = try planeByteCount(metadata);
    if (image.pixel_offset > data.len or data.len - image.pixel_offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    @memcpy(out, data[image.pixel_offset..][0..plane_len]);
    if (image.volume_type == mac_256_greys or image.volume_type == mac_256_colors) {
        for (out) |*byte| byte.* = ~byte.*;
    }
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < 20 or !std.mem.eql(u8, data[0..magic.len], &magic)) return error.InvalidFormat;
    const version = beU32(data[8..12]);
    if (version != 2 and version != 5) return error.InvalidFormat;
    const plane_count = beU16(data[12..14]);
    if (plane_count == 0) return error.InvalidFormat;
    const first_offset = try checkedUsize(beU32(data[16..20]));
    if (first_offset >= data.len) return error.TruncatedData;
    return .{ .version = version, .plane_count = plane_count, .first_offset = first_offset };
}

const Tag = struct {
    payload_start: usize,
    next: usize,
    subtag: u16,
    fmt: [4]u8,
};

fn readTagHeader(data: []const u8, version: u32, pos: usize) bio.ReaderError!Tag {
    const len = tagHeaderLen(version);
    if (pos + len > data.len) return error.TruncatedData;
    const tag = beU16(data[pos..][0..2]);
    if (tag != image_type_1 and tag != image_type_2) return error.InvalidFormat;
    const fmt_offset: usize = if (version == 2) 8 else 12;
    const next = if (version == 2)
        try checkedUsize(beU32(data[pos + 4 ..][0..4]))
    else
        try checkedUsize(beU64(data[pos + 4 ..][0..8]));
    return .{
        .payload_start = pos + len,
        .next = next,
        .subtag = beU16(data[pos + 2 ..][0..2]),
        .fmt = data[pos + fmt_offset ..][0..4].*,
    };
}

fn findNextImageTag(data: []const u8, version: u32, start: usize) ?usize {
    const len = tagHeaderLen(version);
    var pos = start;
    while (pos + len <= data.len) : (pos += 1) {
        const tag = beU16(data[pos..][0..2]);
        if (tag != image_type_1 and tag != image_type_2) continue;
        const next = if (version == 2) beU32(data[pos + 4 ..][0..4]) else beU64(data[pos + 4 ..][0..8]);
        if (next > pos and next <= data.len) return pos;
    }
    return null;
}

fn parseImage(data: []const u8, version: u32, tag: Tag) bio.ReaderError!ImageInfo {
    const payload_start = tag.payload_start;
    const volume_offset = payload_start + 24;
    if (volume_offset + 2 > data.len) return error.TruncatedData;
    const volume_type = beU16(data[volume_offset..][0..2]);
    const plane_offset = payload_start + 42 + 256;
    if (plane_offset >= data.len) return error.TruncatedData;

    if (version == 2) {
        if (plane_offset + 10 > data.len) return error.TruncatedData;
        const top = beI16(data[plane_offset + 2 ..][0..2]);
        const left = beI16(data[plane_offset + 4 ..][0..2]);
        const bottom = beI16(data[plane_offset + 6 ..][0..2]);
        const right = beI16(data[plane_offset + 8 ..][0..2]);
        if (bottom <= top or right <= left) return error.InvalidFormat;
        return .{
            .width = @intCast(right - left),
            .height = @intCast(bottom - top),
            .volume_type = volume_type,
            .pixel_offset = plane_offset + 10,
            .pict = std.ascii.eqlIgnoreCase(tag.fmt[0..], "PICT"),
            .compressed = tag.subtag == 0,
        };
    }

    if (plane_offset + 8 > data.len) return error.TruncatedData;
    const width = beU32(data[plane_offset..][0..4]);
    const height = beU32(data[plane_offset + 4 ..][0..4]);
    if (width == 0 or height == 0) return error.InvalidFormat;
    return .{
        .width = width,
        .height = height,
        .volume_type = volume_type,
        .pixel_offset = plane_offset + 8,
        .pict = std.ascii.eqlIgnoreCase(tag.fmt[0..], "PICT"),
        .compressed = tag.subtag == 0,
    };
}

fn findImage(data: []const u8, header: Header, plane_index: u32) bio.ReaderError!ImageInfo {
    var image_count: u32 = 0;
    var pos = header.first_offset;
    while (pos + tagHeaderLen(header.version) <= data.len and image_count < header.plane_count) {
        const tag_start = findNextImageTag(data, header.version, pos) orelse break;
        const tag = try readTagHeader(data, header.version, tag_start);
        if (tag.next <= tag_start or tag.next > data.len) return error.InvalidFormat;
        const info = try parseImage(data, header.version, tag);
        if (image_count == plane_index) return info;
        image_count += 1;
        pos = tag.next;
    }
    return error.InvalidPlaneIndex;
}

fn tagHeaderLen(version: u32) usize {
    return if (version == 2) 16 else 24;
}

fn samplesPerPixel(volume_type: u16) u16 {
    return switch (volume_type) {
        mac_16_colors, mac_16_bit_color, mac_24_bit_color => 3,
        else => 1,
    };
}

fn pixelType(volume_type: u16) bio.PixelType {
    return switch (volume_type) {
        mac_16_colors, mac_16_bit_color, mac_24_bit_color => .rgb8,
        mac_16_greys, deep_grey_9...deep_grey_16 => .uint16,
        mac_1_bit, mac_4_greys, mac_256_greys, mac_256_colors => .uint8,
        else => .uint8,
    };
}

fn isSupportedRawVolume(volume_type: u16) bool {
    return switch (volume_type) {
        mac_256_greys, mac_16_greys, mac_24_bit_color, deep_grey_9...deep_grey_16 => true,
        else => false,
    };
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn beU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

fn beI16(bytes: []const u8) i16 {
    return std.mem.readInt(i16, bytes[0..2], .big);
}

fn beU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

fn beU64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .big);
}

fn checkedUsize(value: anytype) bio.ReaderError!usize {
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
}

fn writeU16Be(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .big);
}

fn writeU32Be(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .big);
}

fn makeLiffV2(width: u16, height: u16, volume_type: u16, fmt: *const [4]u8, pixels: []const u8) !std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    try out.appendNTimes(std.testing.allocator, 0, 20 + 16 + 42 + 256 + 10);
    @memcpy(out.items[0..magic.len], &magic);
    writeU32Be(out.items, 8, 2);
    writeU16Be(out.items, 12, 1);
    writeU32Be(out.items, 16, 20);
    writeU16Be(out.items, 20, image_type_1);
    writeU16Be(out.items, 22, 1);
    @memcpy(out.items[28..32], fmt);
    const payload = 20 + 16;
    writeU16Be(out.items, payload + 24, volume_type);
    @memcpy(out.items[payload + 42 ..][0.."Plane 1".len], "Plane 1");
    const plane = payload + 42 + 256;
    writeU16Be(out.items, plane + 2, 0);
    writeU16Be(out.items, plane + 4, 0);
    writeU16Be(out.items, plane + 6, height);
    writeU16Be(out.items, plane + 8, width);
    try out.appendSlice(std.testing.allocator, pixels);
    writeU32Be(out.items, 24, @intCast(out.items.len));
    return out;
}

test "reads openlab liff v2 metadata" {
    var data = try makeLiffV2(7, 5, mac_256_greys, "RAW ", &.{});
    defer data.deinit(std.testing.allocator);
    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("openlab", metadata.format);
    try std.testing.expectEqual(@as(u32, 7), metadata.width);
    try std.testing.expectEqual(@as(u32, 5), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
}

test "reports openlab color images as rgb metadata" {
    var data = try makeLiffV2(3, 2, mac_24_bit_color, "RAW ", &.{});
    defer data.deinit(std.testing.allocator);
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
}

test "reads inverted openlab liff v2 grayscale raw plane" {
    var data = try makeLiffV2(2, 1, mac_256_greys, "RAW ", &.{ 0, 255 });
    defer data.deinit(std.testing.allocator);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.uint8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads openlab liff v2 uint16 raw plane" {
    var data = try makeLiffV2(1, 2, mac_16_greys, "RAW ", &.{ 0x12, 0x34, 0xab, 0xcd });
    defer data.deinit(std.testing.allocator);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.uint16, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0xab, 0xcd }, plane.data);
}

test "reads openlab liff v2 rgb raw plane" {
    var data = try makeLiffV2(1, 1, mac_24_bit_color, "RAW ", &.{ 9, 8, 7 });
    defer data.deinit(std.testing.allocator);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgb8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7 }, plane.data);
}

test "rejects openlab liff pict planes for raw read path" {
    var data = try makeLiffV2(1, 1, mac_256_greys, "PICT", &.{0});
    defer data.deinit(std.testing.allocator);

    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, data.items, 0));
}
