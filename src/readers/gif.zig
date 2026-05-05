const std = @import("std");
const bio = @import("../root.zig");

const Header = struct {
    width: u32,
    height: u32,
    global_table_offset: usize,
    global_table_entries: usize,
    background_index: u8,
};

const Image = struct {
    left: u32,
    top: u32,
    width: u32,
    height: u32,
    interlaced: bool,
    color_table_offset: usize,
    color_table_entries: usize,
    lzw_min_code_size: u8,
    data_offset: usize,
    data_end: usize,
    transparent_index: ?u8 = null,
};

const ImageSummary = struct {
    count: u32,
    has_alpha: bool,
};

pub fn matches(data: []const u8) bool {
    return data.len >= 6 and (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a"));
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    const summary = try scanImages(data, header);
    if (summary.count == 0) return error.InvalidFormat;
    return .{
        .format = "gif",
        .width = header.width,
        .height = header.height,
        .size_c = if (summary.has_alpha) 4 else 3,
        .samples_per_pixel = if (summary.has_alpha) 4 else 3,
        .pixel_type = if (summary.has_alpha) .rgba8 else .rgb8,
        .little_endian = false,
        .plane_count = summary.count,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const image = try imageAt(data, header, plane_index);
    if (image.left > header.width or image.top > header.height) return error.InvalidFormat;
    if (image.width > header.width - image.left or image.height > header.height - image.top) return error.InvalidFormat;

    const image_pixel_count = std.math.mul(usize, image.width, image.height) catch return error.UnsupportedVariant;
    const indices = try allocator.alloc(u8, image_pixel_count);
    defer allocator.free(indices);
    try decodeImageData(allocator, data, image, indices);

    const channels: usize = metadata.samples_per_pixel;
    const screen_pixel_count = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, screen_pixel_count, channels) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    try fillCanvas(data, header, image, channels, out);
    try drawImage(data, header, image, indices, channels, out);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data) or data.len < 13) return error.InvalidFormat;
    const width = leU16(data[6..8]);
    const height = leU16(data[8..10]);
    if (width == 0 or height == 0) return error.InvalidFormat;
    const packed_byte = data[10];
    const has_global_table = (packed_byte & 0x80) != 0;
    const entries: usize = if (has_global_table) @as(usize, 1) << @intCast((packed_byte & 0x07) + 1) else 0;
    const table_bytes = std.math.mul(usize, entries, 3) catch return error.UnsupportedVariant;
    const needed = std.math.add(usize, @as(usize, 13), table_bytes) catch return error.UnsupportedVariant;
    if (needed > data.len) return error.TruncatedData;
    return .{
        .width = width,
        .height = height,
        .global_table_offset = 13,
        .global_table_entries = entries,
        .background_index = data[11],
    };
}

fn imageAt(data: []const u8, header: Header, target_index: u32) bio.ReaderError!Image {
    var pos = header.global_table_offset + header.global_table_entries * 3;
    var transparent_index: ?u8 = null;
    var image_index: u32 = 0;
    while (pos < data.len) {
        const introducer = data[pos];
        pos += 1;
        switch (introducer) {
            0x2c => {
                if (pos > data.len or data.len - pos < 9) return error.TruncatedData;
                const left = leU16(data[pos..][0..2]);
                const top = leU16(data[pos + 2 ..][0..2]);
                const width = leU16(data[pos + 4 ..][0..2]);
                const height = leU16(data[pos + 6 ..][0..2]);
                if (width == 0 or height == 0) return error.InvalidFormat;
                const packed_byte = data[pos + 8];
                pos += 9;
                const has_local_table = (packed_byte & 0x80) != 0;
                const interlaced = (packed_byte & 0x40) != 0;
                const local_entries: usize = if (has_local_table) @as(usize, 1) << @intCast((packed_byte & 0x07) + 1) else 0;
                const local_table_offset = pos;
                const local_table_bytes = std.math.mul(usize, local_entries, 3) catch return error.UnsupportedVariant;
                pos = std.math.add(usize, pos, local_table_bytes) catch return error.UnsupportedVariant;
                if (pos >= data.len) return error.TruncatedData;
                const lzw_min_code_size = data[pos];
                pos += 1;
                const data_offset = pos;
                const data_end = try skipSubBlocks(data, &pos);
                const color_table_entries = if (has_local_table) local_entries else header.global_table_entries;
                if (color_table_entries == 0) return error.InvalidFormat;
                if (transparent_index) |index| {
                    if (index >= color_table_entries) return error.InvalidFormat;
                }
                if (image_index == target_index) {
                    return .{
                        .left = left,
                        .top = top,
                        .width = width,
                        .height = height,
                        .interlaced = interlaced,
                        .color_table_offset = if (has_local_table) local_table_offset else header.global_table_offset,
                        .color_table_entries = color_table_entries,
                        .lzw_min_code_size = lzw_min_code_size,
                        .data_offset = data_offset,
                        .data_end = data_end,
                        .transparent_index = transparent_index,
                    };
                }
                image_index += 1;
                transparent_index = null;
            },
            0x21 => {
                if (pos >= data.len) return error.TruncatedData;
                const label = data[pos];
                pos += 1;
                if (label == 0xf9) {
                    transparent_index = try readGraphicControlTransparency(data, &pos);
                } else {
                    _ = try skipSubBlocks(data, &pos);
                }
            },
            0x3b => return error.InvalidFormat,
            else => return error.InvalidFormat,
        }
    }
    return error.TruncatedData;
}

fn scanImages(data: []const u8, header: Header) bio.ReaderError!ImageSummary {
    var pos = header.global_table_offset + header.global_table_entries * 3;
    var transparent_index: ?u8 = null;
    var count: u32 = 0;
    var has_alpha = false;
    while (pos < data.len) {
        const introducer = data[pos];
        pos += 1;
        switch (introducer) {
            0x2c => {
                if (pos > data.len or data.len - pos < 9) return error.TruncatedData;
                const width = leU16(data[pos + 4 ..][0..2]);
                const height = leU16(data[pos + 6 ..][0..2]);
                if (width == 0 or height == 0) return error.InvalidFormat;
                const packed_byte = data[pos + 8];
                pos += 9;
                const has_local_table = (packed_byte & 0x80) != 0;
                const local_entries: usize = if (has_local_table) @as(usize, 1) << @intCast((packed_byte & 0x07) + 1) else 0;
                const local_table_bytes = std.math.mul(usize, local_entries, 3) catch return error.UnsupportedVariant;
                pos = std.math.add(usize, pos, local_table_bytes) catch return error.UnsupportedVariant;
                if (pos >= data.len) return error.TruncatedData;
                pos += 1;
                _ = try skipSubBlocks(data, &pos);
                count += 1;
                const color_table_entries = if (has_local_table) local_entries else header.global_table_entries;
                if (color_table_entries == 0) return error.InvalidFormat;
                if (transparent_index) |index| {
                    if (index >= color_table_entries) return error.InvalidFormat;
                }
                has_alpha = has_alpha or transparent_index != null;
                transparent_index = null;
            },
            0x21 => {
                if (pos >= data.len) return error.TruncatedData;
                const label = data[pos];
                pos += 1;
                if (label == 0xf9) {
                    transparent_index = try readGraphicControlTransparency(data, &pos);
                } else {
                    _ = try skipSubBlocks(data, &pos);
                }
            },
            0x3b => return .{ .count = count, .has_alpha = has_alpha },
            else => return error.InvalidFormat,
        }
    }
    return error.TruncatedData;
}

fn readGraphicControlTransparency(data: []const u8, pos: *usize) bio.ReaderError!?u8 {
    if (pos.* >= data.len) return error.TruncatedData;
    const block_size = data[pos.*];
    pos.* += 1;
    if (block_size != 4) return error.InvalidFormat;
    if (pos.* > data.len or data.len - pos.* < 5) return error.TruncatedData;
    const packed_byte = data[pos.*];
    const transparent_index = data[pos.* + 3];
    pos.* += 4;
    if (data[pos.*] != 0) return error.InvalidFormat;
    pos.* += 1;
    return if ((packed_byte & 0x01) != 0) transparent_index else null;
}

fn skipSubBlocks(data: []const u8, pos: *usize) bio.ReaderError!usize {
    while (pos.* < data.len) {
        const len = data[pos.*];
        pos.* += 1;
        if (len == 0) return pos.* - 1;
        if (pos.* > data.len or data.len - pos.* < len) return error.TruncatedData;
        pos.* += len;
    }
    return error.TruncatedData;
}

fn decodeImageData(allocator: std.mem.Allocator, data: []const u8, image: Image, out: []u8) bio.ReaderError!void {
    if (image.lzw_min_code_size < 2 or image.lzw_min_code_size > 8) return error.UnsupportedVariant;
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);
    var pos = image.data_offset;
    while (pos < image.data_end) {
        const len = data[pos];
        pos += 1;
        if (pos > data.len or data.len - pos < len) return error.TruncatedData;
        try compressed.appendSlice(allocator, data[pos..][0..len]);
        pos += len;
    }
    try decodeLzw(compressed.items, image.lzw_min_code_size, out);
    if (image.interlaced) try deinterlace(allocator, out, image.width, image.height);
}

fn decodeLzw(data: []const u8, min_code_size: u8, out: []u8) bio.ReaderError!void {
    const clear_code: u16 = @as(u16, 1) << @intCast(min_code_size);
    const end_code = clear_code + 1;
    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var stack: [4096]u8 = undefined;
    resetSuffix(&suffix, clear_code);

    var reader = BitReader{ .data = data };
    var code_size: u8 = min_code_size + 1;
    var next_code: u16 = end_code + 1;
    var previous: ?u16 = null;
    var out_pos: usize = 0;
    while (true) {
        const raw_code = reader.read(code_size) orelse return error.TruncatedData;
        if (raw_code == clear_code) {
            code_size = min_code_size + 1;
            next_code = end_code + 1;
            previous = null;
            continue;
        }
        if (raw_code == end_code) break;
        if (raw_code > next_code) return error.InvalidFormat;

        var code = raw_code;
        var stack_len: usize = 0;
        if (code == next_code) {
            const prev = previous orelse return error.InvalidFormat;
            const first = firstChar(prev, clear_code, prefix, suffix);
            stack[stack_len] = first;
            stack_len += 1;
            code = prev;
        }

        while (code >= clear_code) {
            if (stack_len >= stack.len) return error.InvalidFormat;
            stack[stack_len] = suffix[code];
            stack_len += 1;
            code = prefix[code];
        }
        if (code >= clear_code) return error.InvalidFormat;
        const first = suffix[code];
        if (stack_len >= stack.len) return error.InvalidFormat;
        stack[stack_len] = first;
        stack_len += 1;

        var i = stack_len;
        while (i > 0) {
            i -= 1;
            if (out_pos >= out.len) return error.InvalidFormat;
            out[out_pos] = stack[i];
            out_pos += 1;
        }

        if (previous) |prev| {
            if (next_code < 4096) {
                prefix[next_code] = prev;
                suffix[next_code] = first;
                next_code += 1;
                if (next_code == (@as(u16, 1) << @intCast(code_size)) and code_size < 12) code_size += 1;
            }
        }
        previous = raw_code;
    }
    if (out_pos != out.len) return error.TruncatedData;
}

const BitReader = struct {
    data: []const u8,
    bit_pos: usize = 0,

    fn read(self: *BitReader, bits: u8) ?u16 {
        if (bits == 0 or bits > 12) return null;
        var value: u16 = 0;
        var i: u8 = 0;
        while (i < bits) : (i += 1) {
            if (self.bit_pos / 8 >= self.data.len) return null;
            const bit = (self.data[self.bit_pos / 8] >> @intCast(self.bit_pos % 8)) & 1;
            value |= @as(u16, bit) << @intCast(i);
            self.bit_pos += 1;
        }
        return value;
    }
};

fn resetSuffix(suffix: *[4096]u8, clear_code: u16) void {
    var i: u16 = 0;
    while (i < clear_code) : (i += 1) suffix[i] = @intCast(i);
}

fn firstChar(code: u16, clear_code: u16, prefix: [4096]u16, suffix: [4096]u8) u8 {
    var current = code;
    while (current >= clear_code) current = prefix[current];
    return suffix[current];
}

fn deinterlace(allocator: std.mem.Allocator, indices: []u8, width: u32, height: u32) bio.ReaderError!void {
    const copy = try allocator.dupe(u8, indices);
    defer allocator.free(copy);
    const passes = [_]struct { start: usize, step: usize }{
        .{ .start = 0, .step = 8 },
        .{ .start = 4, .step = 8 },
        .{ .start = 2, .step = 4 },
        .{ .start = 1, .step = 2 },
    };
    var src_row: usize = 0;
    const row_width: usize = width;
    for (passes) |pass| {
        var y = pass.start;
        while (y < height) : (y += pass.step) {
            const src = src_row * row_width;
            const dst = y * row_width;
            @memcpy(indices[dst..][0..row_width], copy[src..][0..row_width]);
            src_row += 1;
        }
    }
}

fn fillCanvas(data: []const u8, header: Header, image: Image, channels: usize, out: []u8) bio.ReaderError!void {
    if (channels == 4 and image.transparent_index != null) {
        @memset(out, 0);
        return;
    }
    if (header.background_index >= header.global_table_entries) {
        @memset(out, 0);
        return;
    }
    const src = header.global_table_offset + @as(usize, header.background_index) * 3;
    if (src > data.len or data.len - src < 3) return error.TruncatedData;
    var pixel: usize = 0;
    while (pixel * channels < out.len) : (pixel += 1) {
        const dst = pixel * channels;
        out[dst + 0] = data[src + 0];
        out[dst + 1] = data[src + 1];
        out[dst + 2] = data[src + 2];
        if (channels == 4) out[dst + 3] = 255;
    }
}

fn drawImage(data: []const u8, header: Header, image: Image, indices: []const u8, channels: usize, out: []u8) bio.ReaderError!void {
    const table_bytes = std.math.mul(usize, image.color_table_entries, 3) catch return error.UnsupportedVariant;
    const table_end = std.math.add(usize, image.color_table_offset, table_bytes) catch return error.UnsupportedVariant;
    if (table_end > data.len) return error.TruncatedData;
    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        var x: usize = 0;
        while (x < image.width) : (x += 1) {
            const index = indices[y * image.width + x];
            if (index >= image.color_table_entries) return error.InvalidFormat;
            const src = image.color_table_offset + @as(usize, index) * 3;
            const dst_x = @as(usize, image.left) + x;
            const dst_y = @as(usize, image.top) + y;
            const dst = (dst_y * header.width + dst_x) * channels;
            out[dst + 0] = data[src + 0];
            out[dst + 1] = data[src + 1];
            out[dst + 2] = data[src + 2];
            if (channels == 4) {
                out[dst + 3] = if (image.transparent_index) |transparent_index|
                    if (index == transparent_index) 0 else 255
                else
                    255;
            }
        }
    }
}

fn leU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

test "reads gif global palette as rgb" {
    const data = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        2, 0, 1, 0, 0x80, 0, 0,
        0, 0, 0, 255, 0, 0,
        0x21, 0xf9, 4, 0, 0, 0, 0, 0,
        0x2c, 0, 0, 0, 0, 2, 0, 1, 0, 0,
        2, 2, 0x44, 0x0a, 0,
        0x3b,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 0, 0 }, plane.data);
}

test "skips gif comment and application extensions" {
    const data = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        2, 0, 1, 0, 0x80, 0, 0,
        0, 0, 0, 255, 0, 0,
        0x21, 0xfe, 3, 'a', 'b', 'c', 0,
        0x21, 0xff, 11, 'N', 'E', 'T', 'S', 'C', 'A', 'P', 'E', '2', '.', '0', 3, 1, 0, 0, 0,
        0x2c, 0, 0, 0, 0, 2, 0, 1, 0, 0,
        2, 2, 0x44, 0x0a, 0,
        0x3b,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 0, 0 }, plane.data);
}

test "reads gif image data split across sub-blocks" {
    const data = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        2, 0, 1, 0, 0x80, 0, 0,
        0, 0, 0, 255, 0, 0,
        0x2c, 0, 0, 0, 0, 2, 0, 1, 0, 0,
        2, 1, 0x44, 1, 0x0a, 0,
        0x3b,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 0, 0 }, plane.data);
}

test "reads gif local palette over global palette" {
    const data = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        2, 0, 1, 0, 0x80, 0, 0,
        0, 0, 0, 255, 0, 0,
        0x2c, 0, 0, 0, 0, 2, 0, 1, 0, 0x80,
        0, 0, 255, 0, 255, 0,
        2, 2, 0x44, 0x0a, 0,
        0x3b,
    };
    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 0, 255, 0 }, plane.data);
}

test "reads gif with local palette and no global palette" {
    const data = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        2, 0, 1, 0, 0x00, 0, 0,
        0x2c, 0, 0, 0, 0, 2, 0, 1, 0, 0x80,
        0, 0, 255, 0, 255, 0,
        2, 2, 0x44, 0x0a, 0,
        0x3b,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 0, 255, 0 }, plane.data);
}

test "reads gif local palette transparency as rgba" {
    const data = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        2, 0, 1, 0, 0x00, 0, 0,
        0x21, 0xf9, 4, 1, 0, 0, 1, 0,
        0x2c, 0, 0, 0, 0, 2, 0, 1, 0, 0x80,
        0, 0, 255, 0, 255, 0,
        2, 2, 0x44, 0x0a, 0,
        0x3b,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 0, 255, 0, 0 }, plane.data);
}

test "rejects gif transparency index outside color table" {
    const data = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        2, 0, 1, 0, 0x80, 0, 0,
        0, 0, 0, 255, 0, 0,
        0x21, 0xf9, 4, 1, 0, 0, 7, 0,
        0x2c, 0, 0, 0, 0, 2, 0, 1, 0, 0,
        2, 2, 0x44, 0x0a, 0,
        0x3b,
    };
    try std.testing.expectError(error.InvalidFormat, readMetadata(&data));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, &data));
}

test "rejects gif image index outside color table" {
    const data = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        2, 0, 1, 0, 0x80, 0, 0,
        0, 0, 0, 255, 0, 0,
        0x2c, 0, 0, 0, 0, 2, 0, 1, 0, 0,
        2, 2, 0x84, 0x0a, 0,
        0x3b,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, &data));
}

test "reads interlaced gif image rows" {
    const data = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        1, 0, 5, 0, 0x80, 0, 0,
        0, 0, 0, 255, 0, 0,
        0x2c, 0, 0, 0, 0, 1, 0, 5, 0, 0x40,
        2, 5, 0x04, 0x41, 0x30, 0x4c, 0x01, 0,
        0x3b,
    };
    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{
        0,   0, 0,
        255, 0, 0,
        0,   0, 0,
        255, 0, 0,
        0,   0, 0,
    }, plane.data);
}

test "reads multiple gif images as planes" {
    const data = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        2, 0, 1, 0, 0x80, 0, 0,
        0, 0, 0, 255, 0, 0,
        0x2c, 0, 0, 0, 0, 2, 0, 1, 0, 0,
        2, 2, 0x44, 0x0a, 0,
        0x2c, 0, 0, 0, 0, 2, 0, 1, 0, 0,
        2, 2, 0x0c, 0x0a, 0,
        0x3b,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const first = try readPlaneIndex(std.testing.allocator, &data, 0);
    defer std.testing.allocator.free(first.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 0, 0 }, first.data);

    const second = try readPlaneIndex(std.testing.allocator, &data, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 0, 0 }, second.data);

    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, &data, 2));
}

test "reads non-transparent gif plane as opaque rgba when another plane has transparency" {
    const data = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        2, 0, 1, 0, 0x80, 0, 0,
        0, 0, 0, 255, 0, 0,
        0x2c, 0, 0, 0, 0, 2, 0, 1, 0, 0,
        2, 2, 0x44, 0x0a, 0,
        0x21, 0xf9, 4, 1, 0, 0, 1, 0,
        0x2c, 0, 0, 0, 0, 2, 0, 1, 0, 0,
        2, 2, 0x0c, 0x0a, 0,
        0x3b,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);

    const first = try readPlaneIndex(std.testing.allocator, &data, 0);
    defer std.testing.allocator.free(first.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 255, 0, 0, 255 }, first.data);

    const second = try readPlaneIndex(std.testing.allocator, &data, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 0, 0, 0, 255 }, second.data);
}

test "draws gif image descriptor at logical screen offset" {
    const data = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        3, 0, 1, 0, 0x80, 0, 0,
        0, 0, 0, 255, 0, 0,
        0x2c, 1, 0, 0, 0, 2, 0, 1, 0, 0,
        2, 2, 0x44, 0x0a, 0,
        0x3b,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 255, 0, 0 }, plane.data);
}

test "reads gif graphic control transparency as rgba" {
    const data = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        2, 0, 1, 0, 0x80, 0, 0,
        0, 0, 0, 255, 0, 0,
        0x21, 0xf9, 4, 1, 0, 0, 1, 0,
        0x2c, 0, 0, 0, 0, 2, 0, 1, 0, 0,
        2, 2, 0x44, 0x0a, 0,
        0x3b,
    };
    const metadata = try readMetadata(&data);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 255, 0, 0, 0 }, plane.data);
}

test "matches gif signatures" {
    try std.testing.expect(matches("GIF87a------"));
    try std.testing.expect(matches("GIF89a------"));
    try std.testing.expect(!matches("GIF88a------"));
}
