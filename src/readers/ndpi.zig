const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const marker_tag = 65426;
const metadata_tag = 65449;

pub fn matches(data: []const u8) bool {
    return tiff.firstIfdContainsTag(data, marker_tag) or
        tiff.firstIfdContainsTag(data, metadata_tag);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    var metadata = try tiff.readMetadata(data);
    metadata.format = "ndpi";
    normalizeMetadata(data, &metadata);
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    if (plane_index != 0) return error.InvalidPlaneIndex;
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "ndpi";
    normalizeMetadata(data, &plane.metadata);
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    if (plane_index != 0) return error.InvalidPlaneIndex;
    var plane = try tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "ndpi";
    normalizeMetadata(data, &plane.metadata);
    return plane;
}

fn normalizeMetadata(data: []const u8, metadata: *bio.Metadata) void {
    metadata.series_count = tiff.ifdCount(data) orelse metadata.series_count;
    metadata.plane_count = 1;
    metadata.dimension_order = "XYCZT";
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

test "reads ndpi-tagged tiff plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const marker = "NDPI_MARKER\x00";
    const marker_offset = ifd_end;
    const pixel_offset = marker_offset + marker.len;

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
    try appendEntry(&data, marker_tag, 2, marker.len, @intCast(marker_offset));
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, marker);
    try data.append(std.testing.allocator, 42);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("ndpi", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 1), metadata.series_count);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("ndpi", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{42}, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("ndpi", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{42}, region_plane.data);
}

test "matches Bio-Formats default metadata for cached NDPI fixture" {
    const file_path = "fixtures/cache/ndpi/test3-DAPI 2 (387) .ndpi";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("ndpi", metadata.format);
    try std.testing.expectEqual(@as(u32, 3968), metadata.width);
    try std.testing.expectEqual(@as(u32, 4864), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 6), metadata.series_count);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data, 1));
}
