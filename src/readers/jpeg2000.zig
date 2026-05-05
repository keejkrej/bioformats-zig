const std = @import("std");
const bio = @import("../root.zig");
const build_options = @import("build_options");

const soc = 0xff4f;
const siz = 0xff51;
const eoc = 0xffd9;
const signature_box = 0x6a502020; // "jP  "
const jp2h_box = 0x6a703268; // "jp2h"
const ihdr_box = 0x69686472; // "ihdr"
const jp2c_box = 0x6a703263; // "jp2c"

pub fn matches(data: []const u8) bool {
    _ = imageInfo(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    return readMetadataAs(data, "jpeg2000");
}

pub fn readMetadataAs(data: []const u8, format: []const u8) bio.ReaderError!bio.Metadata {
    const info = imageInfo(data) catch return error.InvalidFormat;
    const pixel_type = pixelType(info.bits_per_sample, info.signed);
    return .{
        .format = format,
        .width = info.width,
        .height = info.height,
        .size_c = info.components,
        .samples_per_pixel = info.components,
        .pixel_type = if (info.components == 3 and pixel_type == .uint8)
            .rgb8
        else if (info.components == 3 and pixel_type == .uint16)
            .rgb16
        else
            pixel_type,
        .little_endian = false,
        .plane_count = 1,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    return readPlaneIndexAs(allocator, data, plane_index, "jpeg2000");
}

pub fn readPlaneIndexAs(allocator: std.mem.Allocator, data: []const u8, plane_index: u32, format: []const u8) bio.ReaderError!bio.Plane {
    if (plane_index != 0) return error.InvalidPlaneIndex;
    if (!build_options.has_openjpeg) return error.UnsupportedVariant;
    var decoded: DecodedImage = undefined;
    const rc = bio_j2k_decode(data.ptr, data.len, &decoded);
    if (rc != 0) return error.UnsupportedVariant;
    defer bio_j2k_free(decoded.data);
    const source = decoded.data orelse return error.UnsupportedVariant;
    const out = try allocator.dupe(u8, source[0..decoded.data_len]);
    errdefer allocator.free(out);
    return .{
        .metadata = metadataFromDecoded(decoded, format),
        .data = out,
    };
}

const DecodedImage = extern struct {
    width: u32,
    height: u32,
    components: u32,
    bits_per_sample: u8,
    is_signed: u8,
    data: ?[*]u8,
    data_len: usize,
};

extern fn bio_j2k_decode(data: [*]const u8, len: usize, out: *DecodedImage) c_int;
extern fn bio_j2k_free(ptr: ?[*]u8) void;

fn metadataFromDecoded(decoded: DecodedImage, format: []const u8) bio.Metadata {
    const samples: u16 = @intCast(decoded.components);
    const scalar = pixelType(decoded.bits_per_sample, decoded.is_signed != 0);
    return .{
        .format = format,
        .width = decoded.width,
        .height = decoded.height,
        .size_c = samples,
        .samples_per_pixel = samples,
        .pixel_type = if (samples == 3 and scalar == .uint8)
            .rgb8
        else if (samples == 3 and scalar == .uint16)
            .rgb16
        else
            scalar,
        .little_endian = false,
        .plane_count = 1,
        .dimension_order = "XYCZT",
    };
}

const ImageInfo = struct {
    width: u32,
    height: u32,
    components: u16,
    bits_per_sample: u8,
    signed: bool = false,
};

fn imageInfo(data: []const u8) !ImageInfo {
    if (data.len >= 2 and readU16BE(data[0..2]) == soc) return rawCodestreamInfo(data);
    return boxedInfo(data);
}

fn rawCodestreamInfo(data: []const u8) !ImageInfo {
    if (data.len < 4 or readU16BE(data[0..2]) != soc) return error.InvalidFormat;
    var pos: usize = 2;
    while (pos + 4 <= data.len) {
        const marker = readU16BE(data[pos..][0..2]);
        pos += 2;
        if (marker == eoc) break;
        if (marker == siz) {
            if (pos + 2 > data.len) return error.TruncatedData;
            const segment_len: usize = readU16BE(data[pos..][0..2]);
            if (segment_len < 38 or pos + segment_len > data.len) return error.TruncatedData;
            const segment = data[pos..][0..segment_len];
            const width = checkedSubtract(readU32BE(segment[4..8]), readU32BE(segment[12..16])) catch return error.InvalidFormat;
            const height = checkedSubtract(readU32BE(segment[8..12]), readU32BE(segment[16..20])) catch return error.InvalidFormat;
            const components = readU16BE(segment[36..38]);
            if (width == 0 or height == 0 or components == 0) return error.InvalidFormat;
            if (segment_len < 38 + @as(usize, components) * 3) return error.TruncatedData;
            const ssiz = segment[38];
            return .{
                .width = width,
                .height = height,
                .components = components,
                .bits_per_sample = (ssiz & 0x7f) + 1,
                .signed = (ssiz & 0x80) != 0,
            };
        }
        if (isStandaloneMarker(marker)) continue;
        if (pos + 2 > data.len) return error.TruncatedData;
        const segment_len: usize = readU16BE(data[pos..][0..2]);
        if (segment_len < 2 or pos + segment_len > data.len) return error.TruncatedData;
        pos += segment_len;
    }
    return error.InvalidFormat;
}

fn boxedInfo(data: []const u8) !ImageInfo {
    var pos: usize = 0;
    var saw_signature = false;
    while (pos + 8 <= data.len) {
        const box_start = pos;
        const box_len32 = readU32BE(data[pos..][0..4]);
        const box_type = readU32BE(data[pos + 4 ..][0..4]);
        pos += 8;
        var box_len: usize = box_len32;
        if (box_len32 == 1) {
            if (pos + 8 > data.len) return error.TruncatedData;
            const large_len = readU64BE(data[pos..][0..8]);
            if (large_len > std.math.maxInt(usize)) return error.UnsupportedVariant;
            box_len = @intCast(large_len);
            pos += 8;
        } else if (box_len32 == 0) {
            box_len = data.len - box_start;
        }
        if (box_len < pos - box_start or box_start + box_len > data.len) return error.TruncatedData;
        const payload = data[pos .. box_start + box_len];
        if (box_type == signature_box) {
            if (payload.len < 4 or !std.mem.eql(u8, payload[0..4], "\r\n\x87\n")) return error.InvalidFormat;
            saw_signature = true;
        } else if (box_type == jp2h_box) {
            if (!saw_signature) return error.InvalidFormat;
            return ihdrInfo(payload);
        } else if (box_type == jp2c_box and saw_signature) {
            return rawCodestreamInfo(payload);
        }
        pos = box_start + box_len;
    }
    return error.InvalidFormat;
}

fn ihdrInfo(data: []const u8) !ImageInfo {
    var pos: usize = 0;
    while (pos + 8 <= data.len) {
        const box_start = pos;
        const box_len: usize = readU32BE(data[pos..][0..4]);
        const box_type = readU32BE(data[pos + 4 ..][0..4]);
        pos += 8;
        if (box_len < 8 or box_start + box_len > data.len) return error.TruncatedData;
        const payload = data[pos .. box_start + box_len];
        if (box_type == ihdr_box) {
            if (payload.len < 14) return error.InvalidFormat;
            const height = readU32BE(payload[0..4]);
            const width = readU32BE(payload[4..8]);
            const components = readU16BE(payload[8..10]);
            const bpc = payload[10];
            if (width == 0 or height == 0 or components == 0 or bpc == 255) return error.UnsupportedVariant;
            return .{
                .width = width,
                .height = height,
                .components = components,
                .bits_per_sample = (bpc & 0x7f) + 1,
                .signed = (bpc & 0x80) != 0,
            };
        }
        pos = box_start + box_len;
    }
    return error.InvalidFormat;
}

fn pixelType(bits: u8, signed: bool) bio.PixelType {
    if (bits <= 8) return if (signed) .int8 else .uint8;
    if (bits <= 16) return if (signed) .int16 else .uint16;
    return if (signed) .int32 else .uint32;
}

fn isStandaloneMarker(marker: u16) bool {
    return marker == soc or marker == 0xff01 or (marker >= 0xffd0 and marker <= 0xffd9);
}

fn checkedSubtract(a: u32, b: u32) !u32 {
    if (a <= b) return error.InvalidFormat;
    return a - b;
}

fn readU16BE(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

fn readU32BE(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        bytes[3];
}

fn readU64BE(bytes: []const u8) u64 {
    return (@as(u64, bytes[0]) << 56) |
        (@as(u64, bytes[1]) << 48) |
        (@as(u64, bytes[2]) << 40) |
        (@as(u64, bytes[3]) << 32) |
        (@as(u64, bytes[4]) << 24) |
        (@as(u64, bytes[5]) << 16) |
        (@as(u64, bytes[6]) << 8) |
        bytes[7];
}

const raw_codestream = [_]u8{
    0xff, 0x4f,
    0xff, 0x51,
    0x00, 0x29, // Lsiz
    0x00, 0x00, // Rsiz
    0x00, 0x00, 0x00, 0x07, // Xsiz
    0x00, 0x00, 0x00, 0x05, // Ysiz
    0x00, 0x00, 0x00, 0x00, // XOsiz
    0x00, 0x00, 0x00, 0x00, // YOsiz
    0x00, 0x00, 0x00, 0x07, // XTsiz
    0x00, 0x00, 0x00, 0x05, // YTsiz
    0x00, 0x00, 0x00, 0x00, // XTOsiz
    0x00, 0x00, 0x00, 0x00, // YTOsiz
    0x00, 0x01, // Csiz
    0x07, 0x01, 0x01, // Ssiz, XRsiz, YRsiz
    0xff, 0xd9,
};

const boxed_jp2 = [_]u8{
    0x00, 0x00, 0x00, 0x0c, 'j',  'P',  ' ',  ' ',
    0x0d, 0x0a, 0x87, 0x0a, 0x00, 0x00, 0x00, 0x14,
    'f',  't',  'y',  'p',  'j',  'p',  '2',  ' ',
    0x00, 0x00, 0x00, 0x00, 'j',  'p',  '2',  ' ',
    0x00, 0x00, 0x00, 0x1e, 'j',  'p',  '2',  'h',
    0x00, 0x00, 0x00, 0x16, 'i',  'h',  'd',  'r',
    0x00, 0x00, 0x00, 0x06, // height
    0x00, 0x00, 0x00, 0x04, // width
    0x00, 0x03, // components
    0x07, // bpc
    0x07, 0x00, 0x00, // compression, unknown colorspace, ipr
};

test "reads raw jpeg2000 codestream dimensions" {
    const metadata = try readMetadata(&raw_codestream);
    try std.testing.expectEqualStrings("jpeg2000", metadata.format);
    try std.testing.expectEqual(@as(u32, 7), metadata.width);
    try std.testing.expectEqual(@as(u32, 5), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
}

test "reads boxed jp2 header dimensions" {
    const metadata = try readMetadata(&boxed_jp2);
    try std.testing.expectEqual(@as(u32, 4), metadata.width);
    try std.testing.expectEqual(@as(u32, 6), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
}

pub const tiny_j2k_codestream = [_]u8{
    0xff, 0x4f, 0xff, 0x51, 0x00, 0x29, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x05,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x05,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x01, 0xff, 0x52, 0x00,
    0x0c, 0x02, 0x00, 0x00, 0x01, 0x00, 0x03, 0x03, 0x03, 0x04, 0x01, 0xff, 0x5c, 0x00, 0x0d, 0x60,
    0x40, 0x48, 0x48, 0x50, 0x48, 0x48, 0x50, 0x48, 0x48, 0x50, 0xff, 0x64, 0x00, 0x2d, 0x00, 0x01,
    0x43, 0x72, 0x65, 0x61, 0x74, 0x6f, 0x72, 0x3a, 0x20, 0x41, 0x56, 0x2d, 0x4a, 0x32, 0x4b, 0x20,
    0x28, 0x63, 0x29, 0x20, 0x32, 0x30, 0x30, 0x30, 0x2c, 0x32, 0x30, 0x30, 0x31, 0x20, 0x41, 0x6c,
    0x67, 0x6f, 0x20, 0x56, 0x69, 0x73, 0x69, 0x6f, 0x6e, 0xff, 0x90, 0x00, 0x0a, 0x00, 0x00, 0x00,
    0x00, 0x00, 0xa2, 0x00, 0x01, 0xff, 0x93, 0xff, 0x91, 0x00, 0x04, 0x00, 0x00, 0xc3, 0xea, 0x10,
    0x40, 0x20, 0x10, 0x08, 0x04, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x91, 0x00, 0x04,
    0x00, 0x01, 0xc0, 0xf9, 0xc4, 0x10, 0x08, 0x04, 0x02, 0x00, 0x00, 0xac, 0x00, 0x68, 0x30, 0xff,
    0x91, 0x00, 0x04, 0x00, 0x02, 0xc3, 0xed, 0x10, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x20, 0xfa,
    0x84, 0x10, 0x08, 0x04, 0x02, 0x01, 0x10, 0x3e, 0xa1, 0x04, 0x02, 0x01, 0x00, 0x80, 0x40, 0x00,
    0x00, 0xac, 0xac, 0xd3, 0x51, 0x38, 0x05, 0x00, 0x00, 0x00, 0x00, 0xa8, 0x05, 0x00, 0x00, 0x68,
    0x00, 0x00, 0xff, 0x91, 0x00, 0x04, 0x00, 0x03, 0xc1, 0xf5, 0x11, 0x20, 0x90, 0x08, 0x04, 0x02,
    0x20, 0xfa, 0x84, 0x90, 0x48, 0x24, 0x02, 0x01, 0x10, 0x3e, 0xa1, 0x24, 0x12, 0x01, 0x00, 0x80,
    0x40, 0x0a, 0x42, 0x00, 0xc6, 0x34, 0x34, 0x60, 0x00, 0xc1, 0x0a, 0x34, 0x00, 0x35, 0x34, 0xac,
    0x00, 0xf7, 0x54, 0x0b, 0x00, 0x00, 0x2b, 0xac, 0x00, 0x00, 0xd7, 0xff, 0xd9,
};

test "decodes jpeg2000 pixels through openjpeg" {
    if (!build_options.has_openjpeg) return error.SkipZigTest;
    const plane = try readPlaneIndex(std.testing.allocator, &tiny_j2k_codestream, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("jpeg2000", plane.metadata.format);
    try std.testing.expectEqual(@as(u32, 3), plane.metadata.width);
    try std.testing.expectEqual(@as(u32, 5), plane.metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 55, 98, 159, 50, 89, 95, 45, 109, 46, 160, 81, 50, 157, 111, 125 }, plane.data);
}
