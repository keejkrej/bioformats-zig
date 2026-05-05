const std = @import("std");
const bio = @import("../root.zig");

const Header = struct {
    width: u32,
    height: u32,
    bits_per_pixel: u8,
    encoding: u8,
    color_planes: u8,
    bytes_per_line: u16,
    palette_offset: ?usize,
};

pub fn matches(data: []const u8) bool {
    if (data.len < 128 or data[0] != 10) return false;
    if (data[1] != 0 and data[1] != 2 and data[1] != 3 and data[1] != 4 and data[1] != 5) return false;
    if (data[2] != 0 and data[2] != 1) return false;
    if (data[3] != 1 and data[3] != 2 and data[3] != 4 and data[3] != 8) return false;
    if (data[65] == 0 or readU16(data[66..68]) == 0) return false;
    return readU16(data[8..10]) >= readU16(data[4..6]) and readU16(data[10..12]) >= readU16(data[6..8]);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    try validateReadable(header);
    return .{
        .format = "pcx",
        .width = header.width,
        .height = header.height,
        .size_c = if (header.color_planes == 1 and header.palette_offset != null) 3 else header.color_planes,
        .samples_per_pixel = if (header.color_planes == 1 and header.palette_offset != null) 3 else header.color_planes,
        .pixel_type = if (header.color_planes == 1 and header.palette_offset != null) .rgb8 else if (header.color_planes == 3) .rgb8 else .uint8,
        .little_endian = true,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    try validateReadable(header);
    const metadata = try readMetadata(data);
    const decoded_len = std.math.mul(usize, @as(usize, header.bytes_per_line), @as(usize, header.height) * @as(usize, header.color_planes)) catch return error.UnsupportedVariant;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try decodeRle(data[128..pixelDataEnd(data, header)], decoded);

    const out_len = std.math.mul(usize, @as(usize, metadata.width) * @as(usize, metadata.height), metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    if (header.color_planes == 1 and header.palette_offset != null) {
        expandPalette(data, header, decoded, out);
    } else if (header.color_planes == 3) {
        copyPlanarRgb(header, decoded, out);
    } else {
        copyGrayscale(header, decoded, out);
    }
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < 128) return error.InvalidFormat;
    if (data[0] != 10) return error.InvalidFormat;
    const x_min = readU16(data[4..6]);
    const y_min = readU16(data[6..8]);
    const x_max = readU16(data[8..10]);
    const y_max = readU16(data[10..12]);
    if (x_max < x_min or y_max < y_min) return error.InvalidFormat;
    const width = @as(u32, x_max) - @as(u32, x_min) + 1;
    const height = @as(u32, y_max) - @as(u32, y_min) + 1;
    const palette_offset: ?usize = if (data[1] == 5 and data[65] == 1 and data.len >= 769 and data[data.len - 769] == 12) data.len - 768 else null;
    return .{
        .width = width,
        .height = height,
        .bits_per_pixel = data[3],
        .encoding = data[2],
        .color_planes = data[65],
        .bytes_per_line = readU16(data[66..68]),
        .palette_offset = palette_offset,
    };
}

fn validateReadable(header: Header) bio.ReaderError!void {
    if (header.width == 0 or header.height == 0) return error.InvalidFormat;
    if (header.encoding != 1) return error.UnsupportedVariant;
    if (header.bits_per_pixel != 8) return error.UnsupportedVariant;
    if (header.color_planes != 1 and header.color_planes != 3) return error.UnsupportedVariant;
    if (header.bytes_per_line < header.width) return error.InvalidFormat;
}

fn pixelDataEnd(data: []const u8, header: Header) usize {
    return header.palette_offset orelse data.len;
}

fn decodeRle(src: []const u8, out: []u8) bio.ReaderError!void {
    var pos: usize = 0;
    var dst: usize = 0;
    while (dst < out.len) {
        if (pos >= src.len) return error.TruncatedData;
        const first = src[pos];
        pos += 1;
        const count: usize = if ((first & 0xc0) == 0xc0) first & 0x3f else 1;
        const value = if (count == 1) first else blk: {
            if (pos >= src.len) return error.TruncatedData;
            const byte = src[pos];
            pos += 1;
            break :blk byte;
        };
        if (count > out.len - dst) return error.InvalidFormat;
        @memset(out[dst..][0..count], value);
        dst += count;
    }
}

fn copyGrayscale(header: Header, decoded: []const u8, out: []u8) void {
    var y: usize = 0;
    while (y < header.height) : (y += 1) {
        const src = y * header.bytes_per_line;
        const dst = y * header.width;
        @memcpy(out[dst..][0..header.width], decoded[src..][0..header.width]);
    }
}

fn copyPlanarRgb(header: Header, decoded: []const u8, out: []u8) void {
    const plane_stride: usize = header.bytes_per_line;
    const row_stride = plane_stride * header.color_planes;
    var y: usize = 0;
    while (y < header.height) : (y += 1) {
        const row = y * row_stride;
        var x: usize = 0;
        while (x < header.width) : (x += 1) {
            const dst = (y * header.width + x) * 3;
            out[dst + 0] = decoded[row + x];
            out[dst + 1] = decoded[row + plane_stride + x];
            out[dst + 2] = decoded[row + plane_stride * 2 + x];
        }
    }
}

fn expandPalette(data: []const u8, header: Header, decoded: []const u8, out: []u8) void {
    const palette = data[header.palette_offset.?..][0..768];
    var y: usize = 0;
    while (y < header.height) : (y += 1) {
        const src_row = y * header.bytes_per_line;
        var x: usize = 0;
        while (x < header.width) : (x += 1) {
            const index = @as(usize, decoded[src_row + x]);
            const src = index * 3;
            const dst = (y * header.width + x) * 3;
            out[dst + 0] = palette[src + 0];
            out[dst + 1] = palette[src + 1];
            out[dst + 2] = palette[src + 2];
        }
    }
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn appendHeader(list: *std.ArrayList(u8), width: u16, height: u16, planes: u8) !void {
    try list.appendNTimes(std.testing.allocator, 0, 128);
    list.items[0] = 10;
    list.items[1] = 5;
    list.items[2] = 1;
    list.items[3] = 8;
    std.mem.writeInt(u16, list.items[8..10], width - 1, .little);
    std.mem.writeInt(u16, list.items[10..12], height - 1, .little);
    list.items[65] = planes;
    std.mem.writeInt(u16, list.items[66..68], width, .little);
}

test "reads planar rgb pcx" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 3);
    try data.appendSlice(std.testing.allocator, &.{ 10, 40, 20, 50, 30, 60 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 50, 60 }, plane.data);
}

test "reads palette pcx as rgb" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 1);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2 });
    try data.append(std.testing.allocator, 12);
    var palette = [_]u8{0} ** 768;
    palette[3] = 10;
    palette[4] = 20;
    palette[5] = 30;
    palette[6] = 40;
    palette[7] = 50;
    palette[8] = 60;
    try data.appendSlice(std.testing.allocator, &palette);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgb8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 50, 60 }, plane.data);
}

test "decodes pcx rle packets" {
    var out = [_]u8{0} ** 5;
    try decodeRle(&.{ 0xc3, 7, 8, 9 }, &out);
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 7, 8, 9 }, &out);
}
