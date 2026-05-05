const std = @import("std");
const bio = @import("../root.zig");

const file_len = 18_653_760;
const width = 4080;
const height = 3048;
const color_map = [_]u8{ 1, 0, 2, 1 };

pub fn matches(data: []const u8) bool {
    return data.len == file_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!matches(data)) return error.InvalidFormat;
    return .{
        .format = "canonraw",
        .width = width,
        .height = height,
        .size_c = 3,
        .samples_per_pixel = 3,
        .size_z = 1,
        .size_t = 1,
        .pixel_type = .rgb16,
        .little_endian = true,
        .plane_count = 1,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index != 0) return error.InvalidPlaneIndex;
    const pixels = try pixelCount(metadata.width, metadata.height);
    const samples = std.math.mul(usize, pixels, 3) catch return error.UnsupportedVariant;

    const bayer = try allocator.alloc(u16, samples);
    defer allocator.free(bayer);
    @memset(bayer, 0);
    try unpackBayer12(data, metadata.width, metadata.height, bayer);

    const out_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    interpolate(bayer, metadata.width, metadata.height, metadata.little_endian, out);
    return .{ .metadata = metadata, .data = out };
}

fn unpackBayer12(data: []const u8, image_width: u32, image_height: u32, out: []u16) bio.ReaderError!void {
    const pixels = try pixelCount(image_width, image_height);
    if (out.len < pixels * 3) return error.InvalidFormat;
    if (data.len * 8 < pixels * 12) return error.TruncatedData;

    var reader = BitReader{ .data = data };
    var row: u32 = 0;
    while (row < image_height) : (row += 1) {
        var col: u32 = 0;
        while (col < image_width) : (col += 1) {
            const value = try reader.readBits(12);
            const pixel = @as(usize, row) * image_width + col;
            const map_index = (row % 2) * 2 + (col % 2);
            const channel = color_map[map_index];
            out[@as(usize, channel) * pixels + pixel] = value;
        }
    }
}

const BitReader = struct {
    data: []const u8,
    bit_pos: usize = 0,

    fn readBits(self: *BitReader, comptime bits: u5) bio.ReaderError!u16 {
        var value: u16 = 0;
        var read: u5 = 0;
        while (read < bits) : (read += 1) {
            const byte_index = self.bit_pos / 8;
            if (byte_index >= self.data.len) return error.TruncatedData;
            const byte = swappedPairByte(self.data, byte_index);
            const bit_index: u3 = @intCast(7 - (self.bit_pos % 8));
            value = (value << 1) | @as(u16, @intCast((byte >> bit_index) & 1));
            self.bit_pos += 1;
        }
        return value;
    }
};

fn swappedPairByte(data: []const u8, index: usize) u8 {
    if ((index % 2) == 0 and index + 1 < data.len) return data[index + 1];
    return data[index - 1];
}

fn interpolate(samples: []const u16, image_width: u32, image_height: u32, little_endian: bool, out: []u8) void {
    if (image_width == 1 and image_height == 1) {
        @memset(out, @truncate(samples[0]));
        return;
    }

    var row: u32 = 0;
    while (row < image_height) : (row += 1) {
        var col: u32 = 0;
        while (col < image_width) : (col += 1) {
            const index = (row % 2) * 2 + (col % 2);
            const need_green = color_map[index] != 1;
            const need_red = color_map[index] != 0;
            const need_blue = color_map[index] != 2;
            const even_col = (col % 2) == 0;
            const base = (@as(usize, row) * image_width + col) * 6;

            const green = if (need_green) averageGreen(samples, image_width, image_height, row, col) else sampleAt(samples, image_width, image_height, 1, row, col);
            writeU16(out, base + 2, green, little_endian);

            const red = if (need_red) averageColor(samples, image_width, image_height, 0, row, col, need_blue, even_col, index) else sampleAt(samples, image_width, image_height, 0, row, col);
            writeU16(out, base, red, little_endian);

            const blue = if (need_blue) averageColor(samples, image_width, image_height, 2, row, col, need_red, even_col, index) else sampleAt(samples, image_width, image_height, 2, row, col);
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
) u16 {
    var sum: u32 = 0;
    var count: u32 = 0;
    if (!opposite_missing) {
        if (row > 0 and col > 0) addSample(samples, image_width, image_height, channel, row - 1, col - 1, &sum, &count);
        if (row > 0 and col + 1 < image_width) addSample(samples, image_width, image_height, channel, row - 1, col + 1, &sum, &count);
        if (row + 1 < image_height and col > 0) addSample(samples, image_width, image_height, channel, row + 1, col - 1, &sum, &count);
        if (row + 1 < image_height and col + 1 < image_width) addSample(samples, image_width, image_height, channel, row + 1, col + 1, &sum, &count);
    } else if ((even_col and color_map[pattern_index + 1] == channel) or (!even_col and color_map[pattern_index - 1] == channel)) {
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

test "reads canon raw fixed metadata" {
    const data = try std.testing.allocator.alloc(u8, file_len);
    defer std.testing.allocator.free(data);
    @memset(data, 0);

    try std.testing.expect(matches(data));
    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("canonraw", metadata.format);
    try std.testing.expectEqual(@as(u32, width), metadata.width);
    try std.testing.expectEqual(@as(u32, height), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.rgb16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data, 1));
}

test "unpacks canon raw 12-bit bayer samples" {
    const data = [_]u8{ 0x34, 0x12, 0xab, 0x56, 0xef, 0xcd };
    var samples: [12]u16 = @splat(0);

    try unpackBayer12(&data, 2, 2, &samples);
    try std.testing.expectEqual(@as(u16, 0x123), samples[4]);
    try std.testing.expectEqual(@as(u16, 0x456), samples[1]);
    try std.testing.expectEqual(@as(u16, 0xabc), samples[10]);
    try std.testing.expectEqual(@as(u16, 0xdef), samples[7]);
}

test "interpolates canon raw bayer pattern" {
    var samples: [12]u16 = @splat(0);
    samples[4] = 10;
    samples[1] = 20;
    samples[10] = 30;
    samples[7] = 40;
    var out: [24]u8 = @splat(0);

    interpolate(&samples, 2, 2, true, &out);
    try std.testing.expectEqualSlices(u8, &.{ 20, 0, 10, 0, 30, 0 }, out[0..6]);
    try std.testing.expectEqualSlices(u8, &.{ 20, 0, 25, 0, 30, 0 }, out[6..12]);
    try std.testing.expectEqualSlices(u8, &.{ 20, 0, 25, 0, 30, 0 }, out[12..18]);
    try std.testing.expectEqualSlices(u8, &.{ 20, 0, 40, 0, 30, 0 }, out[18..24]);
}
