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
    applyLsmInfo(data, &metadata);
    metadata.plane_count = logicalPlaneCount(data);
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const physical_index = try physicalPlaneIndex(data, plane_index);
    var plane = try tiff.readPlaneIndex(allocator, data, physical_index);
    plane.metadata.format = "zeisslsm";
    applyLsmInfo(data, &plane.metadata);
    plane.metadata.plane_count = logicalPlaneCount(data);
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    const physical_index = try physicalPlaneIndex(data, plane_index);
    var plane = try tiff.readRegionIndex(allocator, data, physical_index, region);
    plane.metadata.format = "zeisslsm";
    applyLsmInfo(data, &plane.metadata);
    plane.metadata.plane_count = logicalPlaneCount(data);
    return plane;
}

fn physicalPlaneIndex(data: []const u8, plane_index: u32) bio.ReaderError!u32 {
    const planes = logicalPlaneCount(data);
    if (plane_index >= planes) return error.InvalidPlaneIndex;
    return std.math.mul(u32, plane_index, 2) catch return error.InvalidPlaneIndex;
}

fn logicalPlaneCount(data: []const u8) u32 {
    const count = tiff.ifdCount(data) orelse return 1;
    return @max(@as(u32, 1), count / 2);
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
