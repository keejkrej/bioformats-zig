const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const zeiss_lsm_info_tag = 34412;
const lsm_min_dimension_bytes = 90;

pub fn matches(data: []const u8) bool {
    return tiff.firstIfdContainsTag(data, zeiss_lsm_info_tag);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    var metadata = try tiff.readMetadata(data);
    metadata.format = "zeisslsm";
    normalizeMetadata(data, &metadata);
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const layout = try planeLayout(data, plane_index);
    const physical_index = std.math.mul(u32, layout.ifd_index, 2) catch return error.InvalidPlaneIndex;
    var plane = try tiff.readPlaneIndex(allocator, data, physical_index);
    plane.metadata.format = "zeisslsm";
    normalizeMetadata(data, &plane.metadata);
    if (layout.samples_per_pixel <= 1) return plane;
    return splitChannelPlane(allocator, plane, layout.channel, layout.samples_per_pixel);
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    const layout = try planeLayout(data, plane_index);
    const physical_index = std.math.mul(u32, layout.ifd_index, 2) catch return error.InvalidPlaneIndex;
    var plane = try tiff.readRegionIndex(allocator, data, physical_index, region);
    plane.metadata.format = "zeisslsm";
    normalizeMetadata(data, &plane.metadata);
    if (layout.samples_per_pixel <= 1) return plane;
    return splitChannelPlane(allocator, plane, layout.channel, layout.samples_per_pixel);
}

const PlaneLayout = struct {
    ifd_index: u32,
    channel: u16,
    samples_per_pixel: u16,
};

fn planeLayout(data: []const u8, plane_index: u32) bio.ReaderError!PlaneLayout {
    var metadata = try tiff.readMetadata(data);
    applyLsmInfo(data, &metadata);
    const samples = metadata.samples_per_pixel;
    const channel_count = if (samples > 1) samples else @as(u16, 1);
    const logical_ifds = logicalIfdCount(data);
    const plane_count = std.math.mul(u32, logical_ifds, channel_count) catch return error.InvalidPlaneIndex;
    if (plane_index >= plane_count) return error.InvalidPlaneIndex;
    return .{
        .ifd_index = plane_index / channel_count,
        .channel = @intCast(plane_index % channel_count),
        .samples_per_pixel = samples,
    };
}

fn logicalIfdCount(data: []const u8) u32 {
    const count = tiff.ifdCount(data) orelse return 1;
    return @max(@as(u32, 1), count / 2);
}

fn normalizeMetadata(data: []const u8, metadata: *bio.Metadata) void {
    applyLsmInfo(data, metadata);
    const samples = metadata.samples_per_pixel;
    const logical_ifds = logicalIfdCount(data);
    if (samples > 1) {
        metadata.size_c = samples;
        metadata.samples_per_pixel = 1;
        metadata.pixel_type = scalarPixelType(metadata.pixel_type);
        metadata.dimension_order = moveChannelAfterXY(metadata.dimension_order orelse "XYZCT");
        metadata.plane_count = std.math.mul(u32, logical_ifds, samples) catch logical_ifds;
    } else {
        metadata.plane_count = logical_ifds;
    }
}

fn moveChannelAfterXY(order: []const u8) []const u8 {
    if (std.mem.eql(u8, order, "XYZTC") or std.mem.eql(u8, order, "XYZCT")) return "XYCZT";
    if (std.mem.eql(u8, order, "XYTCZ")) return "XYCTZ";
    return order;
}

fn scalarPixelType(pixel_type: bio.PixelType) bio.PixelType {
    return switch (pixel_type) {
        .rgb16, .rgba16 => .uint16,
        .rgb8, .rgba8 => .uint8,
        else => pixel_type,
    };
}

fn splitChannelPlane(
    allocator: std.mem.Allocator,
    plane: bio.Plane,
    channel: u16,
    samples_per_pixel: u16,
) bio.ReaderError!bio.Plane {
    defer allocator.free(plane.data);
    const bytes_per_sample = plane.metadata.pixel_type.bytesPerSample();
    const sample_stride = std.math.mul(usize, bytes_per_sample, samples_per_pixel) catch return error.UnsupportedVariant;
    const channel_offset = std.math.mul(usize, @as(usize, channel), bytes_per_sample) catch return error.UnsupportedVariant;
    if (sample_stride == 0 or channel_offset + bytes_per_sample > sample_stride) return error.UnsupportedVariant;
    const pixels = plane.data.len / sample_stride;
    const out_len = std.math.mul(usize, pixels, bytes_per_sample) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    var pixel: usize = 0;
    while (pixel < pixels) : (pixel += 1) {
        const src = pixel * sample_stride + channel_offset;
        const dst = pixel * bytes_per_sample;
        @memcpy(out[dst..][0..bytes_per_sample], plane.data[src..][0..bytes_per_sample]);
    }
    return .{ .metadata = plane.metadata, .data = out };
}

fn applyLsmInfo(data: []const u8, metadata: *bio.Metadata) void {
    const info = tiff.firstIfdByteTag(data, zeiss_lsm_info_tag) orelse return;
    if (info.len < lsm_min_dimension_bytes) return;
    const endian: std.builtin.Endian = if (metadata.little_endian) .little else .big;
    const size_z = readNonZeroU16(info, 16, endian);
    const size_c = readNonZeroU16(info, 20, endian);
    const size_t = readNonZeroU16(info, 24, endian);
    if (size_z) |value| metadata.size_z = value;
    if (size_c) |value| metadata.size_c = value;
    if (size_t) |value| metadata.size_t = value;
    metadata.dimension_order = dimensionOrderFromScanType(std.mem.readInt(u16, info[88..90], endian));
}

fn readNonZeroU16(bytes: []const u8, offset: usize, endian: std.builtin.Endian) ?u16 {
    if (offset > bytes.len or bytes.len - offset < 4) return null;
    const value = std.mem.readInt(u32, bytes[offset..][0..4], endian);
    if (value == 0 or value > std.math.maxInt(u16)) return null;
    return @intCast(value);
}

fn dimensionOrderFromScanType(scan_type: u16) []const u8 {
    return switch (scan_type) {
        3, 5, 9 => "XYTCZ",
        4, 6 => "XYZTC",
        7 => "XYCTZ",
        8 => "XYCZT",
        else => "XYZCT",
    };
}

fn appendU16Le(list: *std.ArrayList(u8), value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendU32Le(list: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendEntry(list: *std.ArrayList(u8), tag: u16, field_type: u16, count: u32, value: u32) !void {
    try appendU16Le(list, tag);
    try appendU16Le(list, field_type);
    try appendU32Le(list, count);
    try appendU32Le(list, value);
}

test "reads zeiss lsm tagged tiff plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const lsm_offset = ifd_end;
    const lsm_bytes = 92;
    const pixel_offset = lsm_offset + lsm_bytes;

    try appendU16Le(&data, entry_count);
    try appendEntry(&data, 256, 4, 1, 1);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 1, 8);
    try appendEntry(&data, 259, 3, 1, 1);
    try appendEntry(&data, 262, 3, 1, 1);
    try appendEntry(&data, 273, 4, 1, @intCast(pixel_offset));
    try appendEntry(&data, 277, 3, 1, 1);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 1, 1);
    try appendEntry(&data, zeiss_lsm_info_tag, 1, lsm_bytes, @intCast(lsm_offset));
    try appendU32Le(&data, 0);
    try data.appendNTimes(std.testing.allocator, 0, lsm_bytes);
    std.mem.writeInt(u32, data.items[lsm_offset + 16 ..][0..4], 3, .little);
    std.mem.writeInt(u32, data.items[lsm_offset + 20 ..][0..4], 2, .little);
    std.mem.writeInt(u32, data.items[lsm_offset + 24 ..][0..4], 4, .little);
    std.mem.writeInt(u16, data.items[lsm_offset + 88 ..][0..2], 6, .little);
    try data.append(std.testing.allocator, 0x5a);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zeisslsm", metadata.format);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 4), metadata.size_t);
    try std.testing.expectEqualStrings("XYZTC", metadata.dimension_order.?);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zeisslsm", plane.metadata.format);
    try std.testing.expectEqualStrings("XYZTC", plane.metadata.dimension_order.?);
    try std.testing.expectEqualSlices(u8, &.{0x5a}, plane.data);
}

test "skips paired zeiss lsm thumbnail ifds" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const main_entry_count = 10;
    const main_ifd_end = 8 + 2 + main_entry_count * 12 + 4;
    const lsm_offset = main_ifd_end;
    const lsm_bytes = 92;
    const main_pixel_offset = lsm_offset + lsm_bytes;
    const thumbnail_ifd_offset = main_pixel_offset + 1;
    const thumbnail_entry_count = 9;
    const thumbnail_pixel_offset = thumbnail_ifd_offset + 2 + thumbnail_entry_count * 12 + 4;

    try appendU16Le(&data, main_entry_count);
    try appendEntry(&data, 256, 4, 1, 1);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 1, 8);
    try appendEntry(&data, 259, 3, 1, 1);
    try appendEntry(&data, 262, 3, 1, 1);
    try appendEntry(&data, 273, 4, 1, @intCast(main_pixel_offset));
    try appendEntry(&data, 277, 3, 1, 1);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 1, 1);
    try appendEntry(&data, zeiss_lsm_info_tag, 1, lsm_bytes, @intCast(lsm_offset));
    try appendU32Le(&data, @intCast(thumbnail_ifd_offset));
    try data.appendNTimes(std.testing.allocator, 0, lsm_bytes);
    try data.append(std.testing.allocator, 0x5a);

    try appendU16Le(&data, thumbnail_entry_count);
    try appendEntry(&data, 256, 4, 1, 1);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 1, 8);
    try appendEntry(&data, 259, 3, 1, 1);
    try appendEntry(&data, 262, 3, 1, 1);
    try appendEntry(&data, 273, 4, 1, @intCast(thumbnail_pixel_offset));
    try appendEntry(&data, 277, 3, 1, 1);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 1, 1);
    try appendU32Le(&data, 0);
    try data.append(std.testing.allocator, 0x33);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(u32, 1), plane.metadata.plane_count);
    try std.testing.expectEqualSlices(u8, &.{0x5a}, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "splits zeiss lsm planar samples into channel planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 11;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const lsm_offset = ifd_end;
    const lsm_bytes = 92;
    const bits_offset = lsm_offset + lsm_bytes;
    const strip_offsets_array = bits_offset + 8;
    const strip_counts_array = strip_offsets_array + 4 * 4;
    const pixel_offset = strip_counts_array + 4 * 4;

    try appendU16Le(&data, entry_count);
    try appendEntry(&data, 256, 4, 1, 1);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 4, @intCast(bits_offset));
    try appendEntry(&data, 259, 3, 1, 1);
    try appendEntry(&data, 262, 3, 1, 2);
    try appendEntry(&data, 273, 4, 4, @intCast(strip_offsets_array));
    try appendEntry(&data, 277, 3, 1, 4);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 4, @intCast(strip_counts_array));
    try appendEntry(&data, 284, 3, 1, 2);
    try appendEntry(&data, zeiss_lsm_info_tag, 1, lsm_bytes, @intCast(lsm_offset));
    try appendU32Le(&data, 0);
    try data.appendNTimes(std.testing.allocator, 0, lsm_bytes);
    std.mem.writeInt(u32, data.items[lsm_offset + 20 ..][0..4], 4, .little);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU32Le(&data, pixel_offset + 0);
    try appendU32Le(&data, pixel_offset + 1);
    try appendU32Le(&data, pixel_offset + 2);
    try appendU32Le(&data, pixel_offset + 3);
    try appendU32Le(&data, 1);
    try appendU32Le(&data, 1);
    try appendU32Le(&data, 1);
    try appendU32Le(&data, 1);
    try data.appendSlice(std.testing.allocator, &.{ 10, 20, 30, 40 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u16, 4), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(u32, 4), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 2);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(u16, 1), plane.metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{30}, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 4));
}

test "matches Bio-Formats core metadata for cached Zeiss LSM fixture" {
    const file_path = "fixtures/cache/zeisslsm/10-01.lsm";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("zeisslsm", metadata.format);
    try std.testing.expectEqual(@as(u32, 1024), metadata.width);
    try std.testing.expectEqual(@as(u32, 1024), metadata.height);
    try std.testing.expectEqual(@as(u16, 4), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 4), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
}

test "matches Bio-Formats plane hashes for cached Zeiss LSM fixture" {
    const file_path = "fixtures/cache/zeisslsm/10-01.lsm";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const expected = [_]struct { plane: u32, sha256: [32]u8 }{
        .{ .plane = 0, .sha256 = .{ 0x0a, 0xff, 0x9f, 0x49, 0x9e, 0xe4, 0xe8, 0x91, 0x6e, 0x29, 0x26, 0xa8, 0x40, 0xe0, 0x3f, 0xc2, 0xb0, 0x8c, 0x4f, 0xe2, 0xff, 0x54, 0x86, 0x65, 0x7d, 0xbc, 0xdc, 0x6b, 0x25, 0x7b, 0xf9, 0x9b } },
        .{ .plane = 2, .sha256 = .{ 0x1c, 0x1a, 0x9a, 0x91, 0xa9, 0xf0, 0xc3, 0xcd, 0xe0, 0xc7, 0x00, 0x1d, 0xb5, 0x3e, 0x25, 0x62, 0xfe, 0x71, 0x9b, 0x67, 0xf7, 0x4d, 0x8d, 0x25, 0x6c, 0x11, 0xcc, 0xb5, 0xf6, 0xab, 0xc4, 0x87 } },
        .{ .plane = 3, .sha256 = .{ 0x4c, 0xa8, 0x2e, 0x29, 0x89, 0xe0, 0x1c, 0xde, 0xe6, 0x0b, 0xc3, 0x0a, 0x30, 0xf8, 0x6c, 0xac, 0x3b, 0xd5, 0xe3, 0x7e, 0x05, 0x09, 0x01, 0x26, 0xb1, 0xc4, 0x52, 0xb5, 0x55, 0x9a, 0xa5, 0xb1 } },
    };
    for (expected) |sample| {
        const plane = try readPlaneIndex(std.testing.allocator, data, sample.plane);
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqual(@as(usize, 2097152), plane.data.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
        try std.testing.expectEqualSlices(u8, &sample.sha256, &digest);
    }
}

test "matches Bio-Formats region hash for cached Zeiss LSM fixture" {
    const file_path = "fixtures/cache/zeisslsm/10-01.lsm";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const region = try readRegionIndex(std.testing.allocator, data, 2, .{ .x = 17, .y = 19, .width = 16, .height = 12 });
    defer std.testing.allocator.free(region.data);
    try std.testing.expectEqual(@as(usize, 384), region.data.len);

    const expected: [32]u8 = .{ 0xa5, 0x21, 0x1d, 0x09, 0xb5, 0x08, 0xc4, 0x76, 0x4f, 0x05, 0x82, 0xc6, 0x34, 0x4e, 0xdc, 0xdd, 0x52, 0x2c, 0x31, 0x16, 0xf5, 0x5a, 0x42, 0xc9, 0xc9, 0xa0, 0xea, 0xfb, 0xb0, 0x57, 0x54, 0x01 };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(region.data, &digest, .{});
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}
