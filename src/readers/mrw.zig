const std = @import("std");
const bio = @import("../root.zig");

const magic = "MRM";
const color_map_1 = [_]u8{ 0, 1, 1, 2 };
const color_map_2 = [_]u8{ 1, 2, 0, 1 };

const Header = struct {
    pixel_offset: usize,
    sensor_width: u32,
    width: u32,
    height: u32,
    data_size: u8,
    bayer_pattern: u8,
    wbg: [4]f32,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "mrw",
        .width = header.width,
        .height = header.height,
        .size_c = 3,
        .samples_per_pixel = 3,
        .size_z = 1,
        .size_t = 1,
        .pixel_type = .rgb16,
        .little_endian = false,
        .plane_count = 1,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    if (plane_index != 0) return error.InvalidPlaneIndex;
    const metadata = try readMetadata(data);
    const pixels = try pixelCount(metadata.width, metadata.height);
    const samples = std.math.mul(usize, pixels, 3) catch return error.UnsupportedVariant;

    const bayer = try allocator.alloc(u16, samples);
    defer allocator.free(bayer);
    @memset(bayer, 0);
    try unpackBayer(data, header, bayer);

    const out_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    interpolate(bayer, metadata.width, metadata.height, metadata.little_endian, colorMap(header), out);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < 8 or !std.mem.endsWith(u8, data[0..4], magic)) return error.InvalidFormat;
    const pixel_offset = try checkedUsize(readU32(data, 4) + 8);
    if (pixel_offset > data.len) return error.TruncatedData;

    var offset: usize = 8;
    var maybe_header: ?Header = null;
    var wbg: ?[4]f32 = null;
    while (offset < pixel_offset) {
        if (pixel_offset - offset < 8) return error.TruncatedData;
        const block_name = data[offset..][0..4];
        const block_len = try checkedUsize(readU32(data, offset + 4));
        const block_start = offset + 8;
        if (block_start > pixel_offset or pixel_offset - block_start < block_len) return error.TruncatedData;
        const block = data[block_start..][0..block_len];

        if (std.mem.endsWith(u8, block_name, "PRD")) {
            if (block.len < 24) return error.TruncatedData;
            const sensor_height = readU16(block, 8);
            const sensor_width = readU16(block, 10);
            const height = readU16(block, 12);
            const width = readU16(block, 14);
            const data_size = block[16];
            const bayer_pattern = block[23];
            if (sensor_height == 0 or sensor_width == 0 or width == 0 or height == 0) return error.InvalidFormat;
            if (width > sensor_width or height > sensor_height) return error.InvalidFormat;
            if (data_size != 12 and data_size != 16) return error.UnsupportedVariant;
            maybe_header = .{
                .pixel_offset = pixel_offset,
                .sensor_width = sensor_width,
                .width = width,
                .height = height,
                .data_size = data_size,
                .bayer_pattern = bayer_pattern,
                .wbg = undefined,
            };
        } else if (std.mem.endsWith(u8, block_name, "WBG")) {
            if (block.len < 12) return error.TruncatedData;
            var values: [4]f32 = undefined;
            var i: usize = 0;
            while (i < values.len) : (i += 1) {
                const scale_shift: u5 = @intCast(@min(block[i], 23));
                const divisor: f32 = @floatFromInt(@as(u32, 64) << scale_shift);
                values[i] = @as(f32, @floatFromInt(readU16(block, 4 + i * 2))) / divisor;
            }
            wbg = values;
        }
        offset = block_start + block_len;
    }

    var header = maybe_header orelse return error.InvalidFormat;
    header.wbg = wbg orelse return error.InvalidFormat;
    const row_bits = std.math.mul(usize, header.sensor_width, header.data_size) catch return error.UnsupportedVariant;
    const total_bits = std.math.mul(usize, row_bits, header.height) catch return error.UnsupportedVariant;
    const total_bytes = (total_bits + 7) / 8;
    if (header.pixel_offset > data.len or data.len - header.pixel_offset < total_bytes) return error.TruncatedData;
    return header;
}

fn unpackBayer(data: []const u8, header: Header, out: []u16) bio.ReaderError!void {
    const pixels = try pixelCount(header.width, header.height);
    if (out.len < pixels * 3) return error.InvalidFormat;
    var reader = BitReader{ .data = data[header.pixel_offset..] };
    var row: u32 = 0;
    while (row < header.height) : (row += 1) {
        var col: u32 = 0;
        while (col < header.width) : (col += 1) {
            const raw = try reader.readBits(header.data_size);
            const weighted = applyWhiteBalance(raw, whiteBalanceIndex(row, col), header.wbg);
            const pixel = @as(usize, row) * header.width + col;
            const channel = bayerChannel(row, col, header.bayer_pattern);
            out[@as(usize, channel) * pixels + pixel] = weighted;
        }
        try reader.skipBits(@as(usize, header.data_size) * (header.sensor_width - header.width));
    }
}

const BitReader = struct {
    data: []const u8,
    bit_pos: usize = 0,

    fn readBits(self: *BitReader, bits: u8) bio.ReaderError!u16 {
        var value: u16 = 0;
        var read: u8 = 0;
        while (read < bits) : (read += 1) {
            const byte_index = self.bit_pos / 8;
            if (byte_index >= self.data.len) return error.TruncatedData;
            const bit_index: u3 = @intCast(7 - (self.bit_pos % 8));
            value = (value << 1) | @as(u16, @intCast((self.data[byte_index] >> bit_index) & 1));
            self.bit_pos += 1;
        }
        return value;
    }

    fn skipBits(self: *BitReader, bits: usize) bio.ReaderError!void {
        self.bit_pos = std.math.add(usize, self.bit_pos, bits) catch return error.UnsupportedVariant;
        if ((self.bit_pos + 7) / 8 > self.data.len) return error.TruncatedData;
    }
};

fn applyWhiteBalance(raw: u16, index: usize, wbg: [4]f32) u16 {
    const scaled = @as(f32, @floatFromInt(raw)) * wbg[index];
    if (scaled <= 0) return 0;
    if (scaled >= std.math.maxInt(u16)) return std.math.maxInt(u16);
    return @intFromFloat(scaled);
}

fn whiteBalanceIndex(row: u32, col: u32) usize {
    return @as(usize, (row % 2) * 2 + (col % 2));
}

fn bayerChannel(row: u32, col: u32, pattern: u8) u8 {
    const even_row = (row % 2) == 0;
    const even_col = (col % 2) == 0;
    if (even_row) {
        if (even_col) return if (pattern == 1) 0 else 1;
        return if (pattern == 1) 1 else 2;
    }
    if (even_col) return if (pattern == 1) 1 else 0;
    return if (pattern == 1) 2 else 1;
}

fn colorMap(header: Header) []const u8 {
    return if (header.bayer_pattern == 1) &color_map_1 else &color_map_2;
}

fn interpolate(samples: []const u16, image_width: u32, image_height: u32, little_endian: bool, map: []const u8, out: []u8) void {
    if (image_width == 1 and image_height == 1) {
        @memset(out, @truncate(samples[0]));
        return;
    }

    var row: u32 = 0;
    while (row < image_height) : (row += 1) {
        var col: u32 = 0;
        while (col < image_width) : (col += 1) {
            const index = (row % 2) * 2 + (col % 2);
            const need_green = map[index] != 1;
            const need_red = map[index] != 0;
            const need_blue = map[index] != 2;
            const even_col = (col % 2) == 0;
            const base = (@as(usize, row) * image_width + col) * 6;

            const green = if (need_green) averageGreen(samples, image_width, image_height, row, col) else sampleAt(samples, image_width, image_height, 1, row, col);
            writeU16(out, base + 2, green, little_endian);

            const red = if (need_red) averageColor(samples, image_width, image_height, 0, row, col, need_blue, even_col, index, map) else sampleAt(samples, image_width, image_height, 0, row, col);
            writeU16(out, base, red, little_endian);

            const blue = if (need_blue) averageColor(samples, image_width, image_height, 2, row, col, need_red, even_col, index, map) else sampleAt(samples, image_width, image_height, 2, row, col);
            writeU16(out, base + 4, blue, little_endian);
        }
    }
}

fn averageGreen(samples: []const u16, image_width: u32, image_height: u32, row: u32, col: u32) u16 {
    var sum: u32 = 0;
    var count: u32 = 0;
    if (row > 0) addSample(samples, image_width, image_height, 1, row - 1, col, &sum, &count);
    if (row + 1 < image_height) addSample(samples, image_width, image_height, 1, row + 1, col, &sum, &count);
    if (col > 0) addSample(samples, image_width, image_height, 1, row, col - 1, &sum, &count);
    if (col + 1 < image_width) addSample(samples, image_width, image_height, 1, row, col + 1, &sum, &count);
    return @intCast(sum / count);
}

fn averageColor(
    samples: []const u16,
    image_width: u32,
    image_height: u32,
    channel: u8,
    row: u32,
    col: u32,
    opposite_missing: bool,
    even_col: bool,
    pattern_index: u32,
    map: []const u8,
) u16 {
    var sum: u32 = 0;
    var count: u32 = 0;
    if (!opposite_missing) {
        if (row > 0 and col > 0) addSample(samples, image_width, image_height, channel, row - 1, col - 1, &sum, &count);
        if (row > 0 and col + 1 < image_width) addSample(samples, image_width, image_height, channel, row - 1, col + 1, &sum, &count);
        if (row + 1 < image_height and col > 0) addSample(samples, image_width, image_height, channel, row + 1, col - 1, &sum, &count);
        if (row + 1 < image_height and col + 1 < image_width) addSample(samples, image_width, image_height, channel, row + 1, col + 1, &sum, &count);
    } else if ((even_col and map[pattern_index + 1] == channel) or (!even_col and map[pattern_index - 1] == channel)) {
        if (col > 0) addSample(samples, image_width, image_height, channel, row, col - 1, &sum, &count);
        if (col + 1 < image_width) addSample(samples, image_width, image_height, channel, row, col + 1, &sum, &count);
    } else {
        if (row > 0) addSample(samples, image_width, image_height, channel, row - 1, col, &sum, &count);
        if (row + 1 < image_height) addSample(samples, image_width, image_height, channel, row + 1, col, &sum, &count);
    }
    return @intCast(sum / count);
}

fn addSample(samples: []const u16, image_width: u32, image_height: u32, channel: u8, row: u32, col: u32, sum: *u32, count: *u32) void {
    sum.* += sampleAt(samples, image_width, image_height, channel, row, col);
    count.* += 1;
}

fn sampleAt(samples: []const u16, image_width: u32, image_height: u32, channel: u8, row: u32, col: u32) u16 {
    const pixels = @as(usize, image_width) * image_height;
    return samples[@as(usize, channel) * pixels + @as(usize, row) * image_width + col];
}

fn writeU16(out: []u8, offset: usize, value: u16, little_endian: bool) void {
    std.mem.writeInt(u16, out[offset..][0..2], value, if (little_endian) .little else .big);
}

fn pixelCount(image_width: u32, image_height: u32) bio.ReaderError!usize {
    return std.math.mul(usize, image_width, image_height) catch return error.UnsupportedVariant;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = try pixelCount(metadata.width, metadata.height);
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn checkedUsize(value: u32) bio.ReaderError!usize {
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
}

fn readU16(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .big);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

fn writeU16BE(data: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, data[offset..][0..2], value, .big);
}

fn writeU32BE(data: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, data[offset..][0..4], value, .big);
}

fn appendHeader(list: *std.ArrayList(u8), data_size: u8, bayer_pattern: u8, pixel_bytes: []const u8) !void {
    const blocks_len: usize = 52;
    try list.appendNTimes(std.testing.allocator, 0, 8 + blocks_len);
    @memcpy(list.items[0..4], "\x00MRM");
    writeU32BE(list.items, 4, blocks_len);

    @memcpy(list.items[8..12], "\x00PRD");
    writeU32BE(list.items, 12, 24);
    writeU16BE(list.items, 24, 2);
    writeU16BE(list.items, 26, 2);
    writeU16BE(list.items, 28, 2);
    writeU16BE(list.items, 30, 2);
    list.items[32] = data_size;
    list.items[34] = 0;
    list.items[39] = bayer_pattern;

    @memcpy(list.items[40..44], "\x00WBG");
    writeU32BE(list.items, 44, 12);
    writeU16BE(list.items, 52, 64);
    writeU16BE(list.items, 54, 64);
    writeU16BE(list.items, 56, 64);
    writeU16BE(list.items, 58, 64);
    try list.appendSlice(std.testing.allocator, pixel_bytes);
}

test "reads mrw metadata" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 12, 1, &.{ 0x00, 0xa0, 0x14, 0x02, 0x80, 0x1e });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("mrw", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.rgb16, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);
}

test "reads mrw 12-bit bayer plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 12, 1, &.{ 0x00, 0xa0, 0x14, 0x02, 0x80, 0x1e });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 10, 0, 30, 0, 30 }, plane.data[0..6]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 10, 0, 20, 0, 30 }, plane.data[6..12]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 10, 0, 40, 0, 30 }, plane.data[12..18]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 10, 0, 30, 0, 30 }, plane.data[18..24]);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "rejects unsupported mrw bit depth" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 10, 1, &.{ 0, 0, 0, 0, 0 });

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}
