const std = @import("std");
const bio = @import("../root.zig");

const signature = "8BPS";

const Header = struct {
    channels: u16,
    height: u32,
    width: u32,
    bits_per_channel: u16,
    color_mode: u16,
    color_data: []const u8,
    pixel_offset: usize,
};

pub fn matches(data: []const u8) bool {
    return data.len >= signature.len and std.mem.eql(u8, data[0..signature.len], signature);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    try validateReadable(header);
    const samples = outputSamples(header);
    return .{
        .format = "psd",
        .width = header.width,
        .height = header.height,
        .size_c = samples,
        .samples_per_pixel = samples,
        .pixel_type = pixelType(header),
        .little_endian = false,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    try validateReadable(header);
    const metadata = try readMetadata(data);
    const raw = try rawPixelData(data, header);
    const out_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    if (header.color_mode == 2) {
        try expandPalette(header, raw, out);
    } else if (header.color_mode == 3) {
        try copyPlanarRgb(header, raw, out);
    } else {
        @memcpy(out, raw[0..out_len]);
    }

    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    if (data.len < 26) return error.TruncatedData;
    const version = readU16(data[4..6]);
    if (version != 1) return error.UnsupportedVariant;
    if (!std.mem.allEqual(u8, data[6..12], 0)) return error.InvalidFormat;

    const channels = readU16(data[12..14]);
    const height = readU32(data[14..18]);
    const width = readU32(data[18..22]);
    const bits_per_channel = readU16(data[22..24]);
    const color_mode = readU16(data[24..26]);
    if (channels == 0 or height == 0 or width == 0) return error.InvalidFormat;

    var pos: usize = 26;
    const color_len = try sectionLength(data, pos);
    pos += 4;
    if (data.len - pos < color_len) return error.TruncatedData;
    const color_data = data[pos..][0..color_len];
    pos += color_len;

    const resource_len = try sectionLength(data, pos);
    pos += 4;
    if (data.len - pos < resource_len) return error.TruncatedData;
    pos += resource_len;

    const layer_mask_len = try sectionLength(data, pos);
    pos += 4;
    if (data.len - pos < layer_mask_len) return error.TruncatedData;
    if (layer_mask_len != 0) return error.UnsupportedVariant;
    pos += layer_mask_len;

    return .{
        .channels = channels,
        .height = height,
        .width = width,
        .bits_per_channel = bits_per_channel,
        .color_mode = color_mode,
        .color_data = color_data,
        .pixel_offset = pos,
    };
}

fn validateReadable(header: Header) bio.ReaderError!void {
    if (header.bits_per_channel != 8 and header.bits_per_channel != 16) return error.UnsupportedVariant;
    switch (header.color_mode) {
        1 => if (header.channels != 1) return error.UnsupportedVariant,
        2 => {
            if (header.channels != 1) return error.UnsupportedVariant;
            if (header.bits_per_channel != 8) return error.UnsupportedVariant;
            if (header.color_data.len < 768) return error.InvalidFormat;
        },
        3 => if (header.channels != 3) return error.UnsupportedVariant,
        else => return error.UnsupportedVariant,
    }
}

fn rawPixelData(data: []const u8, header: Header) bio.ReaderError![]const u8 {
    if (data.len - header.pixel_offset < 2) return error.TruncatedData;
    const compression = readU16(data[header.pixel_offset..][0..2]);
    if (compression != 0) return error.UnsupportedVariant;
    const raw_offset = header.pixel_offset + 2;
    const raw_len = try rawByteCount(header);
    if (data.len - raw_offset < raw_len) return error.TruncatedData;
    return data[raw_offset..][0..raw_len];
}

fn pixelType(header: Header) bio.PixelType {
    return switch (header.color_mode) {
        3 => if (header.bits_per_channel == 16) .rgb16 else .rgb8,
        2 => .rgb8,
        else => if (header.bits_per_channel == 16) .uint16 else .uint8,
    };
}

fn outputSamples(header: Header) u16 {
    return if (header.color_mode == 2 or header.color_mode == 3) 3 else 1;
}

fn rawByteCount(header: Header) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    const samples = std.math.mul(usize, pixels, header.channels) catch return error.UnsupportedVariant;
    return std.math.mul(usize, samples, bytesPerSample(header)) catch return error.UnsupportedVariant;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn copyPlanarRgb(header: Header, raw: []const u8, out: []u8) bio.ReaderError!void {
    const sample_bytes = bytesPerSample(header);
    const pixels = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    const plane_stride = std.math.mul(usize, pixels, sample_bytes) catch return error.UnsupportedVariant;
    var pixel: usize = 0;
    while (pixel < pixels) : (pixel += 1) {
        const dst = pixel * 3 * sample_bytes;
        const src_pixel = pixel * sample_bytes;
        @memcpy(out[dst..][0..sample_bytes], raw[src_pixel..][0..sample_bytes]);
        @memcpy(out[dst + sample_bytes ..][0..sample_bytes], raw[plane_stride + src_pixel ..][0..sample_bytes]);
        @memcpy(out[dst + 2 * sample_bytes ..][0..sample_bytes], raw[2 * plane_stride + src_pixel ..][0..sample_bytes]);
    }
}

fn expandPalette(header: Header, raw: []const u8, out: []u8) bio.ReaderError!void {
    const pixels = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    const red = header.color_data[0..256];
    const green = header.color_data[256..512];
    const blue = header.color_data[512..768];
    var pixel: usize = 0;
    while (pixel < pixels) : (pixel += 1) {
        const index = @as(usize, raw[pixel]);
        const dst = pixel * 3;
        out[dst + 0] = red[index];
        out[dst + 1] = green[index];
        out[dst + 2] = blue[index];
    }
}

fn bytesPerSample(header: Header) usize {
    return header.bits_per_channel / 8;
}

fn sectionLength(data: []const u8, pos: usize) bio.ReaderError!usize {
    if (pos > data.len or data.len - pos < 4) return error.TruncatedData;
    return std.math.cast(usize, readU32(data[pos..][0..4])) orelse error.UnsupportedVariant;
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

fn appendU16Be(list: *std.ArrayList(u8), value: u16) !void {
    try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
    try list.append(std.testing.allocator, @intCast(value & 0xff));
}

fn appendU32Be(list: *std.ArrayList(u8), value: u32) !void {
    try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
    try list.append(std.testing.allocator, @intCast(value & 0xff));
}

fn appendHeader(list: *std.ArrayList(u8), channels: u16, width: u32, height: u32, bits: u16, color_mode: u16, color_data: []const u8) !void {
    try list.appendSlice(std.testing.allocator, signature);
    try appendU16Be(list, 1);
    try list.appendNTimes(std.testing.allocator, 0, 6);
    try appendU16Be(list, channels);
    try appendU32Be(list, height);
    try appendU32Be(list, width);
    try appendU16Be(list, bits);
    try appendU16Be(list, color_mode);
    try appendU32Be(list, @intCast(color_data.len));
    try list.appendSlice(std.testing.allocator, color_data);
    try appendU32Be(list, 0);
    try appendU32Be(list, 0);
}

test "reads uncompressed grayscale psd" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 2, 1, 8, 1, &.{});
    try appendU16Be(&data, 0);
    try data.appendSlice(std.testing.allocator, &.{ 7, 9 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("psd", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "reads uncompressed planar rgb psd as interleaved rgb" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 3, 2, 1, 8, 3, &.{});
    try appendU16Be(&data, 0);
    try data.appendSlice(std.testing.allocator, &.{ 10, 40, 20, 50, 30, 60 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 50, 60 }, plane.data);
}

test "reads palette psd as rgb" {
    var palette = [_]u8{0} ** 768;
    palette[1] = 10;
    palette[257] = 20;
    palette[513] = 30;
    palette[2] = 40;
    palette[258] = 50;
    palette[514] = 60;

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 2, 1, 8, 2, &palette);
    try appendU16Be(&data, 0);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgb8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 50, 60 }, plane.data);
}

test "rejects compressed psd pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 1, 8, 1, &.{});
    try appendU16Be(&data, 1);
    try appendU16Be(&data, 1);
    try data.append(std.testing.allocator, 7);

    try std.testing.expect(matches(data.items));
    try std.testing.expectError(error.UnsupportedVariant, readPlane(std.testing.allocator, data.items));
}
