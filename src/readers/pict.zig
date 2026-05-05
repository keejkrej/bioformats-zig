const std = @import("std");
const bio = @import("../root.zig");

const header_offset = 512;
const rect_offset = header_offset + 2;
const version_offset = header_offset + 10;
const jpeg_opcode: u16 = 0x0018;

pub fn matches(data: []const u8) bool {
    _ = readHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = readHeader(data) catch return error.InvalidFormat;
    const is_rgb = hasJpegOpcode(data);
    return .{
        .format = "pict",
        .width = header.width,
        .height = header.height,
        .size_c = if (is_rgb) 3 else 1,
        .samples_per_pixel = if (is_rgb) 3 else 1,
        .pixel_type = if (is_rgb) .rgb8 else .uint8,
        .little_endian = false,
        .plane_count = 1,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

const Header = struct {
    width: u32,
    height: u32,
};

fn readHeader(data: []const u8) !Header {
    if (data.len < version_offset + 2) return error.TruncatedData;
    const top = readI16BE(data[rect_offset..][0..2]);
    const left = readI16BE(data[rect_offset + 2 ..][0..2]);
    const bottom = readI16BE(data[rect_offset + 4 ..][0..2]);
    const right = readI16BE(data[rect_offset + 6 ..][0..2]);
    if (bottom <= top or right <= left) return error.InvalidFormat;

    const version_a = data[version_offset];
    const version_b = data[version_offset + 1];
    if (version_a == 0x11 and version_b == 0x01) {
        return .{ .width = @intCast(right - left), .height = @intCast(bottom - top) };
    }
    if (version_a == 0x00 and version_b == 0x11) {
        if (data.len < version_offset + 4) return error.TruncatedData;
        if (readU16BE(data[version_offset + 2 ..][0..2]) != 0x02ff) return error.InvalidFormat;
        return .{ .width = @intCast(right - left), .height = @intCast(bottom - top) };
    }
    return error.InvalidFormat;
}

fn hasJpegOpcode(data: []const u8) bool {
    if (data.len <= version_offset + 4) return false;
    var pos: usize = version_offset + 4;
    while (pos + 2 <= data.len) : (pos += 2) {
        if (readU16BE(data[pos..][0..2]) == jpeg_opcode) return true;
    }
    return false;
}

fn readU16BE(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

fn readI16BE(bytes: []const u8) i16 {
    return @bitCast(readU16BE(bytes));
}

fn makePict(comptime version_bytes: []const u8, comptime extra: []const u8) [version_offset + version_bytes.len + extra.len]u8 {
    var out = [_]u8{0} ** (version_offset + version_bytes.len + extra.len);
    out[rect_offset + 4] = 0x00;
    out[rect_offset + 5] = 0x05;
    out[rect_offset + 6] = 0x00;
    out[rect_offset + 7] = 0x07;
    @memcpy(out[version_offset..][0..version_bytes.len], version_bytes);
    @memcpy(out[version_offset + version_bytes.len ..], extra);
    return out;
}

const pict_v1 = makePict(&.{ 0x11, 0x01 }, &.{});
const pict_v2_jpeg = makePict(&.{ 0x00, 0x11, 0x02, 0xff }, &.{ 0x00, 0x18 });

test "reads pict v1 frame metadata" {
    const metadata = try readMetadata(&pict_v1);
    try std.testing.expectEqualStrings("pict", metadata.format);
    try std.testing.expectEqual(@as(u32, 7), metadata.width);
    try std.testing.expectEqual(@as(u32, 5), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
}

test "marks embedded jpeg pict as rgb metadata" {
    const metadata = try readMetadata(&pict_v2_jpeg);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
}
