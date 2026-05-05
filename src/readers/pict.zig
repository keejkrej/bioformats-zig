const std = @import("std");
const bio = @import("../root.zig");

const header_offset = 512;
const rect_offset = header_offset + 2;
const version_offset = header_offset + 10;
const jpeg_opcode: u16 = 0x0018;
const clip_region_opcode: u16 = 0x0001;
const bits_rect_opcode: u16 = 0x0090;
const packbits_rect_opcode: u16 = 0x0098;
const end_opcode: u16 = 0x00ff;

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
    if (plane_index != 0) return error.InvalidPlaneIndex;
    const metadata = try readMetadata(data);
    if (metadata.samples_per_pixel != 1 or metadata.pixel_type != .uint8) return error.UnsupportedVariant;
    const bitmap = try findOneBitBitmap(data);
    const plane_len = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    expandOneBitRows(data, bitmap, out) catch return error.UnsupportedVariant;
    return .{ .metadata = metadata, .data = out };
}

const Header = struct {
    width: u32,
    height: u32,
    version_one: bool,
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
        return .{ .width = @intCast(right - left), .height = @intCast(bottom - top), .version_one = true };
    }
    if (version_a == 0x00 and version_b == 0x11) {
        if (data.len < version_offset + 4) return error.TruncatedData;
        if (readU16BE(data[version_offset + 2 ..][0..2]) != 0x02ff) return error.InvalidFormat;
        return .{ .width = @intCast(right - left), .height = @intCast(bottom - top), .version_one = false };
    }
    return error.InvalidFormat;
}

const OneBitBitmap = struct {
    offset: usize,
    row_bytes: usize,
    width: u32,
    height: u32,
};

fn findOneBitBitmap(data: []const u8) bio.ReaderError!OneBitBitmap {
    const header = readHeader(data) catch return error.InvalidFormat;
    if (!header.version_one) return error.UnsupportedVariant;
    var pos: usize = version_offset + 2;
    while (pos < data.len) {
        const opcode = data[pos];
        pos += 1;
        switch (@as(u16, opcode)) {
            clip_region_opcode => {
                if (pos + 2 > data.len) return error.TruncatedData;
                const len = readU16BE(data[pos..][0..2]);
                if (len < 2) return error.InvalidFormat;
                if (len > data.len - pos) return error.TruncatedData;
                pos += len;
            },
            bits_rect_opcode, packbits_rect_opcode => return parseOneBitBitmap(data, pos),
            end_opcode => return error.UnsupportedVariant,
            else => return error.UnsupportedVariant,
        }
    }
    return error.TruncatedData;
}

fn parseOneBitBitmap(data: []const u8, pos: usize) bio.ReaderError!OneBitBitmap {
    if (pos + 28 > data.len) return error.TruncatedData;
    const row_bytes = readU16BE(data[pos..][0..2]) & 0x3fff;
    if (row_bytes == 0 or row_bytes >= 8) return error.UnsupportedVariant;
    const source_top = readI16BE(data[pos + 2 ..][0..2]);
    const source_left = readI16BE(data[pos + 4 ..][0..2]);
    const source_bottom = readI16BE(data[pos + 6 ..][0..2]);
    const source_right = readI16BE(data[pos + 8 ..][0..2]);
    if (source_top != 0 or source_left != 0 or source_bottom <= source_top or source_right <= source_left) return error.UnsupportedVariant;
    const width: u32 = @intCast(source_right - source_left);
    const height: u32 = @intCast(source_bottom - source_top);
    if (row_bytes * 8 < width) return error.InvalidFormat;
    const pixel_offset = pos + 28;
    const byte_count = std.math.mul(usize, row_bytes, height) catch return error.UnsupportedVariant;
    if (pixel_offset > data.len or data.len - pixel_offset < byte_count) return error.TruncatedData;
    return .{ .offset = pixel_offset, .row_bytes = row_bytes, .width = width, .height = height };
}

fn expandOneBitRows(data: []const u8, bitmap: OneBitBitmap, out: []u8) !void {
    const pixels = std.math.mul(usize, bitmap.width, bitmap.height) catch return error.UnsupportedVariant;
    if (out.len != pixels) return error.UnsupportedVariant;
    var y: usize = 0;
    while (y < bitmap.height) : (y += 1) {
        const row = data[bitmap.offset + y * bitmap.row_bytes ..][0..bitmap.row_bytes];
        var x: usize = 0;
        while (x < bitmap.width) : (x += 1) {
            const byte = row[x / 8];
            out[y * bitmap.width + x] = (byte >> @intCast(7 - (x % 8))) & 1;
        }
    }
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
const pict_v1_bitsrect = makePict(&.{ 0x11, 0x01 }, &.{
    0x90, // BitsRect
    0x00, 0x01, // rowBytes
    0x00, 0x00, 0x00, 0x00, // bitmap bounds top/left
    0x00, 0x05, 0x00, 0x07, // bitmap bounds bottom/right
    0x00, 0x00, 0x00, 0x00, // source top/left
    0x00, 0x05, 0x00, 0x07, // source bottom/right
    0x00, 0x00, 0x00, 0x00, // destination top/left
    0x00, 0x05, 0x00, 0x07, // destination bottom/right
    0x00, 0x00, // mode
    0xaa, 0x55, 0xf0, 0x0f, 0x80, // 5 one-byte rows, 7 active pixels each
    0xff, // end
});

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

test "reads uncompressed pict one bit bitsrect plane" {
    const plane = try readPlaneIndex(std.testing.allocator, &pict_v1_bitsrect, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("pict", plane.metadata.format);
    try std.testing.expectEqual(bio.PixelType.uint8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{
        1, 0, 1, 0, 1, 0, 1,
        0, 1, 0, 1, 0, 1, 0,
        1, 1, 1, 1, 0, 0, 0,
        0, 0, 0, 0, 1, 1, 1,
        1, 0, 0, 0, 0, 0, 0,
    }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, &pict_v1_bitsrect, 1));
}
