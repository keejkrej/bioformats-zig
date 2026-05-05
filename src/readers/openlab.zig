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
        const info = try parseImage(data, header.version, tag.payload_start);
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
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
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
};

fn readTagHeader(data: []const u8, version: u32, pos: usize) bio.ReaderError!Tag {
    const len = tagHeaderLen(version);
    if (pos + len > data.len) return error.TruncatedData;
    const tag = beU16(data[pos..][0..2]);
    if (tag != image_type_1 and tag != image_type_2) return error.InvalidFormat;
    const next = if (version == 2)
        try checkedUsize(beU32(data[pos + 4 ..][0..4]))
    else
        try checkedUsize(beU64(data[pos + 4 ..][0..8]));
    return .{ .payload_start = pos + len, .next = next };
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

fn parseImage(data: []const u8, version: u32, payload_start: usize) bio.ReaderError!ImageInfo {
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
        };
    }

    if (plane_offset + 8 > data.len) return error.TruncatedData;
    const width = beU32(data[plane_offset..][0..4]);
    const height = beU32(data[plane_offset + 4 ..][0..4]);
    if (width == 0 or height == 0) return error.InvalidFormat;
    return .{ .width = width, .height = height, .volume_type = volume_type };
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

fn makeLiffV2(width: u16, height: u16, volume_type: u16) [20 + 16 + 42 + 256 + 10]u8 {
    var out = [_]u8{0} ** (20 + 16 + 42 + 256 + 10);
    @memcpy(out[0..magic.len], &magic);
    writeU32Be(&out, 8, 2);
    writeU16Be(&out, 12, 1);
    writeU32Be(&out, 16, 20);
    writeU16Be(&out, 20, image_type_1);
    writeU16Be(&out, 22, 1);
    writeU32Be(&out, 24, out.len);
    @memcpy(out[28..32], "RAW ");
    const payload = 20 + 16;
    writeU16Be(&out, payload + 24, volume_type);
    @memcpy(out[payload + 42 ..][0.."Plane 1".len], "Plane 1");
    const plane = payload + 42 + 256;
    writeU16Be(&out, plane + 2, 0);
    writeU16Be(&out, plane + 4, 0);
    writeU16Be(&out, plane + 6, height);
    writeU16Be(&out, plane + 8, width);
    return out;
}

test "reads openlab liff v2 metadata" {
    const data = makeLiffV2(7, 5, mac_256_greys);
    try std.testing.expect(matches(&data));
    const metadata = try readMetadata(&data);
    try std.testing.expectEqualStrings("openlab", metadata.format);
    try std.testing.expectEqual(@as(u32, 7), metadata.width);
    try std.testing.expectEqual(@as(u32, 5), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
}

test "reports openlab color images as rgb metadata" {
    const data = makeLiffV2(3, 2, mac_24_bit_color);
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
}
