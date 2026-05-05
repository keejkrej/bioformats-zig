const std = @import("std");
const bio = @import("../root.zig");

const Header = struct {
    width: u32,
    height: u32,
    top_down: bool,
    bits_per_pixel: u16,
    compression: u32,
    pixel_offset: usize,
    palette_offset: usize,
    palette_entries: usize,
    palette_entry_bytes: usize,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
    alpha_mask: u32,
    row_stride: usize,
};

pub fn matches(data: []const u8) bool {
    return data.len >= 2 and data[0] == 'B' and data[1] == 'M';
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "bmp",
        .width = header.width,
        .height = header.height,
        .size_c = outputChannels(header),
        .samples_per_pixel = outputChannels(header),
        .pixel_type = if (outputChannels(header) == 4) .rgba8 else .rgb8,
        .little_endian = true,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    const metadata = try readMetadata(data);
    const channels: usize = outputChannels(header);
    const pixels = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, pixels, channels) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    const row_bits = std.math.mul(usize, header.width, header.bits_per_pixel) catch return error.UnsupportedVariant;
    const row_bytes = (row_bits + 7) / 8;
    const palette_bytes = std.math.mul(usize, header.palette_entries, header.palette_entry_bytes) catch return error.UnsupportedVariant;
    const palette_needed = std.math.add(usize, header.palette_offset, palette_bytes) catch return error.UnsupportedVariant;
    if (data.len < palette_needed) return error.TruncatedData;
    if (header.palette_entries != 0 and header.pixel_offset < palette_needed) return error.InvalidFormat;
    var rle_indices: ?[]u8 = null;
    defer if (rle_indices) |indices| allocator.free(indices);
    if (header.compression == 1 or header.compression == 2) {
        const index_len = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
        const indices = try allocator.alloc(u8, index_len);
        @memset(indices, 0);
        errdefer allocator.free(indices);
        if (header.compression == 1) {
            try decodeRle8(data, header, indices);
        } else {
            try decodeRle4(data, header, indices);
        }
        rle_indices = indices;
    } else {
        const pixel_bytes = std.math.mul(usize, header.row_stride, header.height) catch return error.UnsupportedVariant;
        const needed = std.math.add(usize, header.pixel_offset, pixel_bytes) catch return error.UnsupportedVariant;
        if (data.len < needed) return error.TruncatedData;
    }

    var y: usize = 0;
    while (y < header.height) : (y += 1) {
        const src_y = if (header.top_down) y else header.height - 1 - y;
        const row = if (rle_indices) |indices| indices[src_y * header.width ..][0..header.width] else data[header.pixel_offset + src_y * header.row_stride ..][0..row_bytes];
        var x: usize = 0;
        while (x < header.width) : (x += 1) {
            const dst = (y * header.width + x) * channels;
            if (header.palette_entries != 0) {
                const index = if (rle_indices != null) row[x] else paletteIndex(row, x, header.bits_per_pixel);
                if (index >= header.palette_entries) return error.InvalidFormat;
                const src = header.palette_offset + @as(usize, index) * header.palette_entry_bytes;
                out[dst + 0] = data[src + 2];
                out[dst + 1] = data[src + 1];
                out[dst + 2] = data[src + 0];
            } else if (header.bits_per_pixel == 16) {
                const src = x * 2;
                const pixel = @as(u32, leU16(row[src..][0..2]));
                out[dst + 0] = expandMask(pixel, header.red_mask);
                out[dst + 1] = expandMask(pixel, header.green_mask);
                out[dst + 2] = expandMask(pixel, header.blue_mask);
                if (channels == 4) out[dst + 3] = expandMask(pixel, header.alpha_mask);
            } else if (header.bits_per_pixel == 32 and header.red_mask != 0) {
                const src = x * 4;
                const pixel = leU32(row[src..][0..4]);
                out[dst + 0] = expandMask(pixel, header.red_mask);
                out[dst + 1] = expandMask(pixel, header.green_mask);
                out[dst + 2] = expandMask(pixel, header.blue_mask);
                out[dst + 3] = if (header.alpha_mask == 0) 255 else expandMask(pixel, header.alpha_mask);
            } else {
                const src = x * channels;
                out[dst + 0] = row[src + 2];
                out[dst + 1] = row[src + 1];
                out[dst + 2] = row[src + 0];
                if (channels == 4) out[dst + 3] = row[src + 3];
            }
        }
    }

    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data) or data.len < 26) return error.InvalidFormat;
    const pixel_offset = leU32(data[10..14]);
    const dib_size = leU32(data[14..18]);
    if (dib_size == 12) return parseCoreHeader(data, pixel_offset);
    if (dib_size < 40) return error.UnsupportedVariant;
    if (data.len < 54) return error.InvalidFormat;

    const width_signed = leI32(data[18..22]);
    const height_signed = leI32(data[22..26]);
    if (width_signed <= 0 or height_signed == 0) return error.UnsupportedVariant;

    const planes = leU16(data[26..28]);
    const bits_per_pixel = leU16(data[28..30]);
    const compression = leU32(data[30..34]);
    if (planes != 1) return error.UnsupportedVariant;
    if (compression != 0 and compression != 1 and compression != 2 and compression != 3 and compression != 6) return error.UnsupportedVariant;
    if (bits_per_pixel != 1 and bits_per_pixel != 4 and bits_per_pixel != 8 and bits_per_pixel != 16 and bits_per_pixel != 24 and bits_per_pixel != 32) return error.UnsupportedVariant;
    if (compression == 1 and bits_per_pixel != 8) return error.UnsupportedVariant;
    if (compression == 2 and bits_per_pixel != 4) return error.UnsupportedVariant;
    if (compression == 3 and bits_per_pixel != 16 and bits_per_pixel != 32) return error.UnsupportedVariant;
    if (compression == 6 and bits_per_pixel != 16 and bits_per_pixel != 32) return error.UnsupportedVariant;

    const width: u32 = @intCast(width_signed);
    const abs_height_i32 = if (height_signed < 0) -height_signed else height_signed;
    const height: u32 = @intCast(abs_height_i32);
    if (height_signed < 0 and compression != 0 and compression != 3 and compression != 6) return error.UnsupportedVariant;
    const bits_per_row = std.math.mul(usize, width, bits_per_pixel) catch return error.UnsupportedVariant;
    const row_stride = ((bits_per_row + 31) / 32) * 4;
    if (pixel_offset > data.len) return error.TruncatedData;
    const colors_used = leU32(data[46..50]);
    const palette_entries: usize = if (bits_per_pixel <= 8) @intCast(if (colors_used == 0) @as(u32, 1) << @intCast(bits_per_pixel) else colors_used) else 0;
    const palette_offset = 14 + try checkedUsize(dib_size);
    if (palette_entries > 256) return error.InvalidFormat;
    if (bits_per_pixel <= 8 and pixel_offset < palette_offset) return error.InvalidFormat;
    const masks = try readMasks(data, dib_size, compression, bits_per_pixel);

    return .{
        .width = width,
        .height = height,
        .top_down = height_signed < 0,
        .bits_per_pixel = bits_per_pixel,
        .compression = compression,
        .pixel_offset = pixel_offset,
        .palette_offset = palette_offset,
        .palette_entries = palette_entries,
        .palette_entry_bytes = 4,
        .red_mask = masks[0],
        .green_mask = masks[1],
        .blue_mask = masks[2],
        .alpha_mask = masks[3],
        .row_stride = row_stride,
    };
}

fn parseCoreHeader(data: []const u8, pixel_offset: u32) bio.ReaderError!Header {
    const width = leU16(data[18..20]);
    const height = leU16(data[20..22]);
    if (width == 0 or height == 0) return error.InvalidFormat;
    const planes = leU16(data[22..24]);
    const bits_per_pixel = leU16(data[24..26]);
    if (planes != 1) return error.UnsupportedVariant;
    if (bits_per_pixel != 1 and bits_per_pixel != 4 and bits_per_pixel != 8 and bits_per_pixel != 24) return error.UnsupportedVariant;
    const bits_per_row = std.math.mul(usize, width, bits_per_pixel) catch return error.UnsupportedVariant;
    const row_stride = ((bits_per_row + 31) / 32) * 4;
    if (pixel_offset > data.len) return error.TruncatedData;
    const palette_offset: usize = 26;
    const palette_entries: usize = if (bits_per_pixel <= 8) blk: {
        if (pixel_offset < palette_offset) return error.InvalidFormat;
        const palette_bytes = @as(usize, pixel_offset) - palette_offset;
        if (palette_bytes == 0 or palette_bytes % 3 != 0) return error.InvalidFormat;
        const entries = palette_bytes / 3;
        const max_entries = @as(usize, 1) << @intCast(bits_per_pixel);
        if (entries > max_entries) return error.InvalidFormat;
        break :blk entries;
    } else 0;
    return .{
        .width = width,
        .height = height,
        .top_down = false,
        .bits_per_pixel = bits_per_pixel,
        .compression = 0,
        .pixel_offset = pixel_offset,
        .palette_offset = palette_offset,
        .palette_entries = palette_entries,
        .palette_entry_bytes = 3,
        .red_mask = 0,
        .green_mask = 0,
        .blue_mask = 0,
        .alpha_mask = 0,
        .row_stride = row_stride,
    };
}

fn readMasks(data: []const u8, dib_size: u32, compression: u32, bits_per_pixel: u16) bio.ReaderError![4]u32 {
    if (bits_per_pixel != 16 and bits_per_pixel != 32) return .{ 0, 0, 0, 0 };
    if (compression == 0 and dib_size >= 52) return readHeaderMasks(data, dib_size, compression);
    if (bits_per_pixel == 32 and compression == 0) return .{ 0, 0, 0, 0 };
    if (compression == 0) return .{ 0x7c00, 0x03e0, 0x001f, 0 };

    return readHeaderMasks(data, dib_size, compression);
}

fn readHeaderMasks(data: []const u8, dib_size: u32, compression: u32) bio.ReaderError![4]u32 {
    const mask_offset: usize = 14 + @min(try checkedUsize(dib_size), @as(usize, 40));
    if (mask_offset > data.len or data.len - mask_offset < 12) return error.TruncatedData;
    const alpha_mask = if (dib_size >= 56 or compression == 6) blk: {
        if (mask_offset > data.len or data.len - mask_offset < 16) return error.TruncatedData;
        const alpha_offset: usize = mask_offset + 12;
        break :blk leU32(data[alpha_offset..][0..4]);
    } else 0;
    return .{
        leU32(data[mask_offset..][0..4]),
        leU32(data[mask_offset + 4 ..][0..4]),
        leU32(data[mask_offset + 8 ..][0..4]),
        alpha_mask,
    };
}

fn outputChannels(header: Header) u16 {
    if (header.bits_per_pixel == 32) return 4;
    if (header.bits_per_pixel == 16 and header.alpha_mask != 0) return 4;
    return 3;
}

fn checkedUsize(value: u32) bio.ReaderError!usize {
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
}

fn decodeRle8(data: []const u8, header: Header, indices: []u8) bio.ReaderError!void {
    var src = header.pixel_offset;
    var x: usize = 0;
    var y: usize = 0;
    while (src < data.len and y < header.height) {
        const count = data[src];
        src += 1;
        if (src >= data.len) return error.TruncatedData;
        const value = data[src];
        src += 1;
        if (count != 0) {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (x >= header.width or y >= header.height) return error.InvalidFormat;
                indices[y * header.width + x] = value;
                x += 1;
            }
            continue;
        }

        switch (value) {
            0 => {
                x = 0;
                y += 1;
            },
            1 => return,
            2 => {
                if (src > data.len or data.len - src < 2) return error.TruncatedData;
                x += data[src];
                y += data[src + 1];
                src += 2;
                if (x > header.width or y > header.height) return error.InvalidFormat;
            },
            else => {
                const literal_count: usize = value;
                if (src > data.len or data.len - src < literal_count) return error.TruncatedData;
                var i: usize = 0;
                while (i < literal_count) : (i += 1) {
                    if (x >= header.width or y >= header.height) return error.InvalidFormat;
                    indices[y * header.width + x] = data[src + i];
                    x += 1;
                }
                src += literal_count;
                if ((literal_count & 1) != 0) {
                    if (src >= data.len) return error.TruncatedData;
                    src += 1;
                }
            },
        }
    }
}

fn decodeRle4(data: []const u8, header: Header, indices: []u8) bio.ReaderError!void {
    var src = header.pixel_offset;
    var x: usize = 0;
    var y: usize = 0;
    while (src < data.len and y < header.height) {
        const count = data[src];
        src += 1;
        if (src >= data.len) return error.TruncatedData;
        const value = data[src];
        src += 1;
        if (count != 0) {
            const pair = [_]u8{ value >> 4, value & 0x0f };
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (x >= header.width or y >= header.height) return error.InvalidFormat;
                indices[y * header.width + x] = pair[i & 1];
                x += 1;
            }
            continue;
        }

        switch (value) {
            0 => {
                x = 0;
                y += 1;
            },
            1 => return,
            2 => {
                if (src > data.len or data.len - src < 2) return error.TruncatedData;
                x += data[src];
                y += data[src + 1];
                src += 2;
                if (x > header.width or y > header.height) return error.InvalidFormat;
            },
            else => {
                const literal_count: usize = value;
                const literal_bytes = (literal_count + 1) / 2;
                if (src > data.len or data.len - src < literal_bytes) return error.TruncatedData;
                var i: usize = 0;
                while (i < literal_count) : (i += 1) {
                    if (x >= header.width or y >= header.height) return error.InvalidFormat;
                    const packed_byte = data[src + i / 2];
                    indices[y * header.width + x] = if ((i & 1) == 0) packed_byte >> 4 else packed_byte & 0x0f;
                    x += 1;
                }
                src += literal_bytes;
                if ((literal_bytes & 1) != 0) {
                    if (src >= data.len) return error.TruncatedData;
                    src += 1;
                }
            },
        }
    }
}

fn paletteIndex(row: []const u8, x: usize, bits_per_pixel: u16) u8 {
    if (bits_per_pixel == 8) return row[x];
    if (bits_per_pixel == 4) {
        const byte = row[x / 2];
        return if (x % 2 == 0) byte >> 4 else byte & 0x0f;
    }
    const byte = row[x / 8];
    const shift: u3 = @intCast(7 - (x % 8));
    return (byte >> shift) & 0x01;
}

fn expandMask(pixel: u32, mask: u32) u8 {
    const shift = trailingZeroes(mask);
    const max_value = mask >> @intCast(shift);
    if (max_value == 0) return 0;
    const value = (pixel & mask) >> @intCast(shift);
    return @intCast((value * 255) / max_value);
}

fn trailingZeroes(value: u32) u5 {
    var shift: u5 = 0;
    var remaining = value;
    while (shift < 31 and (remaining & 1) == 0) : (shift += 1) {
        remaining >>= 1;
    }
    return shift;
}

fn leU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn leU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn leI32(bytes: []const u8) i32 {
    return std.mem.readInt(i32, bytes[0..4], .little);
}

test "reads 24-bit bmp metadata and pixels" {
    const data = [_]u8{
        'B', 'M', 58, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0,
        40, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 24, 0,
        0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        3, 2, 1, 0,
    };
    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(u32, 1), plane.metadata.width);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, plane.data);
}

test "reads top-down 24-bit bmp row order" {
    const data = [_]u8{
        'B', 'M', 62, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0,
        40, 0, 0, 0, 1, 0, 0, 0, 0xfe, 0xff, 0xff, 0xff, 1, 0, 24, 0,
        0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        3, 2, 1, 0,
        6, 5, 4, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, plane.data);
}

test "reads 24-bit bmp core header" {
    const data = [_]u8{
        'B', 'M', 30, 0, 0, 0, 0, 0, 0, 0, 26, 0, 0, 0,
        12, 0, 0, 0, 1, 0, 1, 0, 1, 0, 24, 0,
        3, 2, 1, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, plane.data);
}

test "reads 8-bit indexed bmp core header palette as rgb" {
    const data = [_]u8{
        'B', 'M', 0x1e, 0x03, 0, 0, 0, 0, 0, 0, 0x1a, 0x03, 0, 0,
        12, 0, 0, 0, 2, 0, 1, 0, 1, 0, 8, 0,
    } ++ [_]u8{0, 0, 0} ** 254 ++ [_]u8{
        0, 0, 255,
        0, 128, 0,
        254, 255, 0, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 128, 0 }, plane.data);
}

test "reads 8-bit indexed bmp core header compact palette as rgb" {
    const data = [_]u8{
        'B', 'M', 36, 0, 0, 0, 0, 0, 0, 0, 32, 0, 0, 0,
        12, 0, 0, 0, 2, 0, 1, 0, 1, 0, 8, 0,
        0, 0, 255,
        0, 128, 0,
        0, 1, 0, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 128, 0 }, plane.data);
}

test "reads 1-bit indexed bmp core header palette as rgb" {
    const data = [_]u8{
        'B', 'M', 36, 0, 0, 0, 0, 0, 0, 0, 32, 0, 0, 0,
        12, 0, 0, 0, 5, 0, 1, 0, 1, 0, 1, 0,
        0, 0, 0,
        255, 255, 255,
        0xa8, 0, 0, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 5), metadata.width);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 0, 0, 0, 255, 255, 255, 0, 0, 0, 255, 255, 255 }, plane.data);
}

test "reads 4-bit indexed bmp core header palette as rgb" {
    const data = [_]u8{
        'B', 'M', 78, 0, 0, 0, 0, 0, 0, 0, 74, 0, 0, 0,
        12, 0, 0, 0, 3, 0, 1, 0, 1, 0, 4, 0,
        0, 0, 0,
        0, 0, 255,
        0, 128, 0,
    } ++ [_]u8{0, 0, 0} ** 13 ++ [_]u8{
        0x12, 0, 0, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 128, 0, 0, 0, 0 }, plane.data);
}

test "reads 1-bit indexed bmp palette as rgb" {
    const data = [_]u8{
        'B', 'M', 66, 0, 0, 0, 0, 0, 0, 0, 62, 0, 0, 0,
        40, 0, 0, 0, 5, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0,
        0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        2, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        255, 255, 255, 0,
        0xa8, 0, 0, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 5), metadata.width);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 0, 0, 0, 255, 255, 255, 0, 0, 0, 255, 255, 255 }, plane.data);
}

test "reads 4-bit indexed bmp palette as rgb" {
    const data = [_]u8{
        'B', 'M', 70, 0, 0, 0, 0, 0, 0, 0, 66, 0, 0, 0,
        40, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 1, 0, 4, 0,
        0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        3, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 255, 0,
        0, 128, 0, 0,
        0x12, 0, 0, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 128, 0, 0, 0, 0 }, plane.data);
}

test "reads 8-bit indexed bmp palette as rgb" {
    const data = [_]u8{
        'B', 'M', 70, 0, 0, 0, 0, 0, 0, 0, 66, 0, 0, 0,
        40, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 8, 0,
        0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        3, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 255, 0,
        0, 128, 0, 0,
        1, 2, 0, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 128, 0 }, plane.data);
}

test "reads top-down 8-bit indexed bmp row order" {
    const data = [_]u8{
        'B', 'M', 74, 0, 0, 0, 0, 0, 0, 0, 66, 0, 0, 0,
        40, 0, 0, 0, 2, 0, 0, 0, 0xfe, 0xff, 0xff, 0xff, 1, 0, 8, 0,
        0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        3, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 255, 0,
        0, 128, 0, 0,
        1, 2, 0, 0,
        2, 1, 0, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 128, 0, 0, 128, 0, 255, 0, 0 }, plane.data);
}

test "reads rle8 indexed bmp palette as rgb" {
    const data = [_]u8{
        'B', 'M', 72, 0, 0, 0, 0, 0, 0, 0, 66, 0, 0, 0,
        40, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 1, 0, 8, 0,
        1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        3, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 255, 0,
        0, 128, 0, 0,
        2, 1, 1, 2, 0, 1,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 0, 128, 0 }, plane.data);
}

test "reads rle4 encoded indexed bmp palette as rgb" {
    const data = [_]u8{
        'B', 'M', 70, 0, 0, 0, 0, 0, 0, 0, 66, 0, 0, 0,
        40, 0, 0, 0, 5, 0, 0, 0, 1, 0, 0, 0, 1, 0, 4, 0,
        2, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        3, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 255, 0,
        0, 128, 0, 0,
        5, 0x12, 0, 1,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 5), metadata.width);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 128, 0, 255, 0, 0, 0, 128, 0, 255, 0, 0 }, plane.data);
}

test "reads rle4 absolute indexed bmp palette as rgb" {
    const data = [_]u8{
        'B', 'M', 78, 0, 0, 0, 0, 0, 0, 0, 70, 0, 0, 0,
        40, 0, 0, 0, 5, 0, 0, 0, 1, 0, 0, 0, 1, 0, 4, 0,
        2, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        4, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 255, 0,
        0, 128, 0, 0,
        255, 0, 0, 0,
        0, 5, 0x12, 0x32, 0x10, 0, 0, 1,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 5), metadata.width);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 128, 0, 0, 0, 255, 0, 128, 0, 255, 0, 0 }, plane.data);
}

test "rejects top-down rle8 bmp" {
    const data = [_]u8{
        'B', 'M', 72, 0, 0, 0, 0, 0, 0, 0, 66, 0, 0, 0,
        40, 0, 0, 0, 3, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 1, 0, 8, 0,
        1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        3, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 255, 0,
        0, 128, 0, 0,
        2, 1, 1, 2, 0, 1,
    };
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(&data));
}

test "reads 16-bit bmp rgb555 as rgb" {
    const data = [_]u8{
        'B', 'M', 58, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0,
        40, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 16, 0,
        0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0x7c, 0xe0, 0x03,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 255, 0 }, plane.data);
}

test "reads 16-bit bmp extended header masks with rgb compression" {
    const data = [_]u8{
        'B', 'M', 126, 0, 0, 0, 0, 0, 0, 0, 122, 0, 0, 0,
        108, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 16, 0,
        0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0xf8, 0, 0,
        0xe0, 0x07, 0, 0,
        0x1f, 0, 0, 0,
        0, 0, 0, 0,
    } ++ [_]u8{0} ** 52 ++ [_]u8{
        0, 0xf8, 0xe0, 0x07,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 255, 0 }, plane.data);
}

test "reads 16-bit bmp v2 header masks with rgb compression" {
    const data = [_]u8{
        'B', 'M', 70, 0, 0, 0, 0, 0, 0, 0, 66, 0, 0, 0,
        52, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 16, 0,
        0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0xf8, 0, 0,
        0xe0, 0x07, 0, 0,
        0x1f, 0, 0, 0,
        0, 0xf8, 0xe0, 0x07,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 255, 0 }, plane.data);
}

test "reads 32-bit bmp v2 header masks with rgb compression" {
    const data = [_]u8{
        'B', 'M', 74, 0, 0, 0, 0, 0, 0, 0, 66, 0, 0, 0,
        52, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 32, 0,
        0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0xff, 0,
        0, 0xff, 0, 0,
        0xff, 0, 0, 0,
        0, 0, 0xff, 0,
        0, 0xff, 0, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, plane.data);
}

test "reads 16-bit bmp bitfields rgb565 as rgb" {
    const data = [_]u8{
        'B', 'M', 70, 0, 0, 0, 0, 0, 0, 0, 66, 0, 0, 0,
        40, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 16, 0,
        3, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0xf8, 0, 0,
        0xe0, 0x07, 0, 0,
        0x1f, 0, 0, 0,
        0, 0xf8, 0xe0, 0x07,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 255, 0 }, plane.data);
}

test "reads 16-bit bmp bitfields alpha mask as rgba" {
    const data = [_]u8{
        'B', 'M', 78, 0, 0, 0, 0, 0, 0, 0, 70, 0, 0, 0,
        56, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 16, 0,
        3, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0x7c, 0, 0,
        0xe0, 0x03, 0, 0,
        0x1f, 0, 0, 0,
        0, 0x80, 0, 0,
        0, 0xfc, 0xe0, 0x03,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 0 }, plane.data);
}

test "reads 16-bit bmp alphabitfields compression as rgba" {
    const data = [_]u8{
        'B', 'M', 74, 0, 0, 0, 0, 0, 0, 0, 70, 0, 0, 0,
        40, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 16, 0,
        6, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0x7c, 0, 0,
        0xe0, 0x03, 0, 0,
        0x1f, 0, 0, 0,
        0, 0x80, 0, 0,
        0, 0xfc, 0xe0, 0x03,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 0 }, plane.data);
}

test "reads 32-bit bmp bitfields as opaque rgba" {
    const data = [_]u8{
        'B', 'M', 74, 0, 0, 0, 0, 0, 0, 0, 66, 0, 0, 0,
        40, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 32, 0,
        3, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0xff, 0,
        0, 0xff, 0, 0,
        0xff, 0, 0, 0,
        0, 0, 0xff, 0,
        0, 0xff, 0, 0,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, plane.data);
}

test "reads 32-bit bmp extended header alpha mask with rgb compression" {
    const data = [_]u8{
        'B', 'M', 126, 0, 0, 0, 0, 0, 0, 0, 122, 0, 0, 0,
        108, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 32, 0,
        0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0xff, 0,
        0, 0xff, 0, 0,
        0xff, 0, 0, 0,
        0, 0, 0, 0xff,
    } ++ [_]u8{0} ** 52 ++ [_]u8{
        0xff, 0, 0, 0x80,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 128 }, plane.data);
}

test "reads 32-bit bmp v3 header alpha mask with rgb compression" {
    const data = [_]u8{
        'B', 'M', 74, 0, 0, 0, 0, 0, 0, 0, 70, 0, 0, 0,
        56, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 32, 0,
        0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0xff, 0,
        0, 0xff, 0, 0,
        0xff, 0, 0, 0,
        0, 0, 0, 0xff,
        0xff, 0, 0, 0x80,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 128 }, plane.data);
}

test "reads 32-bit bmp bitfields alpha mask as rgba" {
    const data = [_]u8{
        'B', 'M', 74, 0, 0, 0, 0, 0, 0, 0, 70, 0, 0, 0,
        56, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 32, 0,
        3, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0xff, 0,
        0, 0xff, 0, 0,
        0xff, 0, 0, 0,
        0, 0, 0, 0xff,
        0xff, 0, 0, 0x80,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 128 }, plane.data);
}
