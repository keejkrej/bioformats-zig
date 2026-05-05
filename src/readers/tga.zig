const std = @import("std");
const bio = @import("../root.zig");

const Header = struct {
    image_type: u8,
    width: u32,
    height: u32,
    bits_per_pixel: u8,
    image_descriptor: u8,
    color_map_offset: usize,
    color_map_first: u16,
    color_map_entries: usize,
    color_map_entry_bits: u8,
    pixel_offset: usize,
};

pub fn matches(data: []const u8) bool {
    if (data.len < 18) return false;
    const image_type = data[2];
    return image_type == 1 or image_type == 2 or image_type == 3 or image_type == 9 or image_type == 10 or image_type == 11;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "tga",
        .width = header.width,
        .height = header.height,
        .size_c = samplesPerPixel(header),
        .samples_per_pixel = samplesPerPixel(header),
        .pixel_type = pixelType(header),
        .little_endian = true,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    const metadata = try readMetadata(data);
    const channels: usize = metadata.samples_per_pixel;
    const pixels = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, pixels, channels) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    const src_channels = sourceBytesPerPixel(header.bits_per_pixel);
    const pixel_bytes = std.math.mul(usize, pixels, src_channels) catch return error.UnsupportedVariant;
    const decoded = try allocator.alloc(u8, pixel_bytes);
    defer allocator.free(decoded);
    try decodePixels(data, header, src_channels, decoded);
    const top_origin = (header.image_descriptor & 0x20) != 0;
    const right_origin = (header.image_descriptor & 0x10) != 0;

    var y: usize = 0;
    while (y < header.height) : (y += 1) {
        const src_y = if (top_origin) y else header.height - 1 - y;
        var x: usize = 0;
        while (x < header.width) : (x += 1) {
            const src_x = if (right_origin) header.width - 1 - x else x;
            const src = (src_y * header.width + src_x) * src_channels;
            const dst = (y * header.width + x) * channels;
            if (isColorMapped(header.image_type)) {
                const index = if (header.bits_per_pixel == 16) leU16(decoded[src..][0..2]) else decoded[src];
                try writeColorMapPixel(data, header, index, out[dst..][0..channels]);
            } else if (isGrayscale(header.image_type)) {
                if (header.bits_per_pixel == 16) {
                    const gray = decoded[src];
                    out[dst + 0] = gray;
                    out[dst + 1] = gray;
                    out[dst + 2] = gray;
                    out[dst + 3] = decoded[src + 1];
                } else {
                    out[dst] = decoded[src];
                }
            } else if (header.bits_per_pixel == 15 or header.bits_per_pixel == 16) {
                const pixel = leU16(decoded[src..][0..2]);
                out[dst + 0] = expand5(@intCast((pixel >> 10) & 0x1f));
                out[dst + 1] = expand5(@intCast((pixel >> 5) & 0x1f));
                out[dst + 2] = expand5(@intCast(pixel & 0x1f));
                if (channels == 4) out[dst + 3] = if (header.bits_per_pixel == 16 and (pixel & 0x8000) != 0) 255 else 0;
            } else if (channels == 3) {
                out[dst + 0] = decoded[src + 2];
                out[dst + 1] = decoded[src + 1];
                out[dst + 2] = decoded[src + 0];
            } else {
                out[dst + 0] = decoded[src + 2];
                out[dst + 1] = decoded[src + 1];
                out[dst + 2] = decoded[src + 0];
                out[dst + 3] = decoded[src + 3];
            }
        }
    }

    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < 18) return error.InvalidFormat;
    const color_map_type = data[1];
    const image_type = data[2];
    if (image_type != 1 and image_type != 2 and image_type != 3 and image_type != 9 and image_type != 10 and image_type != 11) return error.UnsupportedVariant;
    if (color_map_type != 0 and color_map_type != 1) return error.UnsupportedVariant;
    if (isColorMapped(image_type)) {
        if (color_map_type != 1) return error.UnsupportedVariant;
    }
    const color_map_first = leU16(data[3..5]);
    const color_map_length = leU16(data[5..7]);
    const color_map_entry_bits = data[7];
    const width = leU16(data[12..14]);
    const height = leU16(data[14..16]);
    if (width == 0 or height == 0) return error.InvalidFormat;
    const bits_per_pixel = data[16];
    if (isColorMapped(image_type) and bits_per_pixel != 8 and bits_per_pixel != 16) return error.UnsupportedVariant;
    if (isTruecolor(image_type) and bits_per_pixel != 15 and bits_per_pixel != 16 and bits_per_pixel != 24 and bits_per_pixel != 32) return error.UnsupportedVariant;
    if (isGrayscale(image_type) and bits_per_pixel != 8 and bits_per_pixel != 16) return error.UnsupportedVariant;
    if (color_map_type == 1 and color_map_length != 0 and color_map_entry_bits != 15 and color_map_entry_bits != 16 and color_map_entry_bits != 24 and color_map_entry_bits != 32) return error.UnsupportedVariant;
    const color_map_offset = 18 + try checkedUsize(data[0]);
    const color_map_bytes = if (color_map_type == 1)
        std.math.mul(usize, @as(usize, color_map_length), colorMapEntryBytes(color_map_entry_bits)) catch return error.UnsupportedVariant
    else
        0;
    const pixel_offset = std.math.add(usize, color_map_offset, color_map_bytes) catch return error.UnsupportedVariant;
    if (pixel_offset > data.len) return error.TruncatedData;
    return .{
        .image_type = image_type,
        .width = width,
        .height = height,
        .bits_per_pixel = bits_per_pixel,
        .image_descriptor = data[17],
        .color_map_offset = color_map_offset,
        .color_map_first = color_map_first,
        .color_map_entries = color_map_length,
        .color_map_entry_bits = color_map_entry_bits,
        .pixel_offset = pixel_offset,
    };
}

fn samplesPerPixel(header: Header) u16 {
    if (isColorMapped(header.image_type)) return if (header.color_map_entry_bits == 32 or header.color_map_entry_bits == 16) 4 else 3;
    if (isGrayscale(header.image_type)) return if (header.bits_per_pixel == 16) 4 else 1;
    if (header.bits_per_pixel == 16 and (header.image_descriptor & 0x0f) != 0) return 4;
    return if (header.bits_per_pixel == 32) 4 else 3;
}

fn pixelType(header: Header) bio.PixelType {
    if (isColorMapped(header.image_type)) return if (header.color_map_entry_bits == 32 or header.color_map_entry_bits == 16) .rgba8 else .rgb8;
    if (isGrayscale(header.image_type)) return if (header.bits_per_pixel == 16) .rgba8 else .uint8;
    if (header.bits_per_pixel == 16 and (header.image_descriptor & 0x0f) != 0) return .rgba8;
    return if (header.bits_per_pixel == 32) .rgba8 else .rgb8;
}

fn decodePixels(data: []const u8, header: Header, src_channels: usize, out: []u8) bio.ReaderError!void {
    if (!isRle(header.image_type)) {
        const needed = std.math.add(usize, header.pixel_offset, out.len) catch return error.UnsupportedVariant;
        if (data.len < needed) return error.TruncatedData;
        @memcpy(out, data[header.pixel_offset..][0..out.len]);
        return;
    }

    var src = header.pixel_offset;
    var dst: usize = 0;
    while (dst < out.len) {
        if (src >= data.len) return error.TruncatedData;
        const packet = data[src];
        src += 1;
        const count = @as(usize, packet & 0x7f) + 1;
        const bytes = std.math.mul(usize, count, src_channels) catch return error.UnsupportedVariant;
        if ((packet & 0x80) != 0) {
            if (src > data.len or data.len - src < src_channels) return error.TruncatedData;
            if (out.len - dst < bytes) return error.TruncatedData;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                @memcpy(out[dst..][0..src_channels], data[src..][0..src_channels]);
                dst += src_channels;
            }
            src += src_channels;
        } else {
            if (src > data.len or data.len - src < bytes) return error.TruncatedData;
            if (out.len - dst < bytes) return error.TruncatedData;
            @memcpy(out[dst..][0..bytes], data[src..][0..bytes]);
            src += bytes;
            dst += bytes;
        }
    }
}

fn isTruecolor(image_type: u8) bool {
    return image_type == 2 or image_type == 10;
}

fn isColorMapped(image_type: u8) bool {
    return image_type == 1 or image_type == 9;
}

fn isGrayscale(image_type: u8) bool {
    return image_type == 3 or image_type == 11;
}

fn isRle(image_type: u8) bool {
    return image_type == 9 or image_type == 10 or image_type == 11;
}

fn sourceBytesPerPixel(bits_per_pixel: u8) usize {
    return (@as(usize, bits_per_pixel) + 7) / 8;
}

fn expand5(value: u5) u8 {
    return (@as(u8, value) << 3) | (@as(u8, value) >> 2);
}

fn writeColorMapPixel(data: []const u8, header: Header, index: u16, out: []u8) bio.ReaderError!void {
    if (index < header.color_map_first) return error.InvalidFormat;
    const relative_index: usize = @intCast(index - header.color_map_first);
    if (relative_index >= header.color_map_entries) return error.InvalidFormat;
    const entry_bytes = colorMapEntryBytes(header.color_map_entry_bits);
    const src = header.color_map_offset + relative_index * entry_bytes;
    if (src > data.len or data.len - src < entry_bytes) return error.TruncatedData;
    if (entry_bytes == 2) {
        const pixel = leU16(data[src..][0..2]);
        out[0] = expand5(@intCast((pixel >> 10) & 0x1f));
        out[1] = expand5(@intCast((pixel >> 5) & 0x1f));
        out[2] = expand5(@intCast(pixel & 0x1f));
        if (header.color_map_entry_bits == 16) out[3] = if ((pixel & 0x8000) != 0) 255 else 0;
    } else {
        out[0] = data[src + 2];
        out[1] = data[src + 1];
        out[2] = data[src + 0];
        if (entry_bytes == 4) out[3] = data[src + 3];
    }
}

fn colorMapEntryBytes(bits: u8) usize {
    return if (bits == 15) 2 else bits / 8;
}

fn checkedUsize(value: u8) bio.ReaderError!usize {
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
}

fn leU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

test "reads top-origin 24-bit tga as rgb" {
    const data = [_]u8{
        0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 24, 0x20,
        3, 2, 1, 6, 5, 4,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, plane.data);
}

test "reads top-right-origin 24-bit tga as rgb" {
    const data = [_]u8{
        0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 24, 0x30,
        3, 2, 1, 6, 5, 4,
    };
    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6, 1, 2, 3 }, plane.data);
}

test "reads truecolor tga with unused color map" {
    const data = [_]u8{
        0, 1, 2, 0, 0, 1, 0, 24, 0, 0, 0, 0, 2, 0, 1, 0, 24, 0x20,
        10, 20, 30,
        0, 0, 255, 0, 255, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 255, 0 }, plane.data);
}

test "reads bottom-origin 32-bit tga as rgba" {
    const data = [_]u8{
        0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2, 0, 32, 0,
        3, 2, 1, 4,
        7, 6, 5, 8,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8, 1, 2, 3, 4 }, plane.data);
}

test "reads 16-bit tga as rgb" {
    const data = [_]u8{
        0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 16, 0x20,
        0, 0x7c, 0xe0, 0x03,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 255, 0 }, plane.data);
}

test "reads 15-bit tga as rgb" {
    const data = [_]u8{
        0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 15, 0x20,
        0, 0x7c, 0xe0, 0x03,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 255, 0 }, plane.data);
}

test "reads 16-bit tga attribute bit as alpha" {
    const data = [_]u8{
        0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 16, 0x21,
        0, 0xfc, 0xe0, 0x03,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 0 }, plane.data);
}

test "reads grayscale tga" {
    const data = [_]u8{
        0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 8, 0x20,
        9, 11,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 9, 11 }, plane.data);
}

test "reads grayscale tga with unused color map" {
    const data = [_]u8{
        0, 1, 3, 0, 0, 1, 0, 24, 0, 0, 0, 0, 2, 0, 1, 0, 8, 0x20,
        10, 20, 30,
        9, 11,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 9, 11 }, plane.data);
}

test "reads 16-bit grayscale tga as rgba" {
    const data = [_]u8{
        0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 16, 0x20,
        9, 255, 11, 128,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 255, 11, 11, 11, 128 }, plane.data);
}

test "reads color-mapped tga as rgb" {
    const data = [_]u8{
        0, 1, 1, 0, 0, 3, 0, 24, 0, 0, 0, 0, 3, 0, 1, 0, 8, 0x20,
        0, 0, 0,
        0, 0, 255,
        0, 128, 0,
        1, 2, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 128, 0, 0, 0, 0 }, plane.data);
}

test "reads color-mapped tga with nonzero first palette index" {
    const data = [_]u8{
        0, 1, 1, 5, 0, 2, 0, 24, 0, 0, 0, 0, 2, 0, 1, 0, 8, 0x20,
        0, 0, 255,
        0, 128, 0,
        5, 6,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 128, 0 }, plane.data);
}

test "reads color-mapped tga with 16-bit palette indices" {
    const data = [_]u8{
        0, 1, 1, 0x2c, 0x01, 2, 0, 24, 0, 0, 0, 0, 2, 0, 1, 0, 16, 0x20,
        0, 0, 255,
        0, 128, 0,
        0x2c, 0x01, 0x2d, 0x01,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 128, 0 }, plane.data);
}

test "reads rle color-mapped tga as rgb" {
    const data = [_]u8{
        0, 1, 9, 0, 0, 3, 0, 24, 0, 0, 0, 0, 3, 0, 1, 0, 8, 0x20,
        0, 0, 0,
        0, 0, 255,
        0, 128, 0,
        0x81, 1,
        0x00, 2,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 0, 128, 0 }, plane.data);
}

test "reads rle color-mapped tga with 16-bit palette indices" {
    const data = [_]u8{
        0, 1, 9, 0x2c, 0x01, 2, 0, 24, 0, 0, 0, 0, 3, 0, 1, 0, 16, 0x20,
        0, 0, 255,
        0, 128, 0,
        0x81, 0x2c, 0x01,
        0x00, 0x2d, 0x01,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 0, 128, 0 }, plane.data);
}

test "reads 15-bit color-mapped tga as rgb" {
    const data = [_]u8{
        0, 1, 1, 0, 0, 3, 0, 15, 0, 0, 0, 0, 3, 0, 1, 0, 8, 0x20,
        0, 0,
        0, 0x7c,
        0xe0, 0x03,
        1, 2, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 255, 0, 0, 0, 0 }, plane.data);
}

test "reads 16-bit color-mapped tga attribute bit as alpha" {
    const data = [_]u8{
        0, 1, 1, 0, 0, 3, 0, 16, 0, 0, 0, 0, 3, 0, 1, 0, 8, 0x20,
        0, 0,
        0, 0xfc,
        0xe0, 0x03,
        1, 2, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 0, 0, 0, 0, 0 }, plane.data);
}

test "reads rle 24-bit tga as rgb" {
    const data = [_]u8{
        0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 1, 0, 24, 0x20,
        0x81, 3, 2, 1,
        0x00, 6, 5, 4,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 1, 2, 3, 4, 5, 6 }, plane.data);
}

test "reads rle 16-bit tga as rgb" {
    const data = [_]u8{
        0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 1, 0, 16, 0x20,
        0x81, 0, 0x7c,
        0x00, 0xe0, 0x03,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 0, 255, 0 }, plane.data);
}

test "reads rle 15-bit tga as rgb" {
    const data = [_]u8{
        0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 1, 0, 15, 0x20,
        0x81, 0, 0x7c,
        0x00, 0xe0, 0x03,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 0, 255, 0 }, plane.data);
}

test "reads rle grayscale tga" {
    const data = [_]u8{
        0, 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 1, 0, 8, 0x20,
        0x81, 7,
        0x00, 9,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 9 }, plane.data);
}

test "reads rle 16-bit grayscale tga as rgba" {
    const data = [_]u8{
        0, 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 1, 0, 16, 0x20,
        0x81, 7, 255,
        0x00, 9, 128,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 7, 255, 7, 7, 7, 255, 9, 9, 9, 128 }, plane.data);
}
