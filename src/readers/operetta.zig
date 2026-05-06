const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const xml_tag = 65500;
const harmony_magic = "Harmony";
const operetta_magic = "Operett";

pub fn matches(data: []const u8) bool {
    if (containsOperettaMarker(tiff.firstIfdAsciiTag(data, xml_tag))) return true;
    if (containsOperettaMarker(tiff.firstIfdByteTag(data, xml_tag))) return true;
    return containsOperettaMarker(tiff.firstIfdAsciiTag(data, 270));
}

fn containsOperettaMarker(xml: ?[]const u8) bool {
    const value = xml orelse return false;
    const prefix = value[0..@min(value.len, 2048)];
    return std.mem.indexOf(u8, prefix, harmony_magic) != null or
        std.mem.indexOf(u8, prefix, operetta_magic) != null;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    var metadata = try tiff.readMetadata(data);
    metadata.format = "operetta";
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "operetta";
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    var plane = try tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "operetta";
    return plane;
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

test "reads operetta xml tagged tiff plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const xml = "<Root><Name>Harmony Operetta</Name></Root>\x00";
    const xml_offset = ifd_end;
    const pixel_offset = xml_offset + xml.len;

    try appendU16Le(&data, entry_count);
    try appendEntry(&data, 256, 4, 1, 2);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 1, 8);
    try appendEntry(&data, 259, 3, 1, 1);
    try appendEntry(&data, 262, 3, 1, 1);
    try appendEntry(&data, 273, 4, 1, @intCast(pixel_offset));
    try appendEntry(&data, 277, 3, 1, 1);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 1, 2);
    try appendEntry(&data, xml_tag, 2, xml.len, @intCast(xml_offset));
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, xml);
    try data.appendSlice(std.testing.allocator, &.{ 81, 82 });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("operetta", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("operetta", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 81, 82 }, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 1,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("operetta", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{82}, region_plane.data);
}

test "rejects unrelated xml tag" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const xml = "<Root><Name>Other instrument</Name></Root>\x00";
    const xml_offset = ifd_end;
    const pixel_offset = xml_offset + xml.len;

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
    try appendEntry(&data, xml_tag, 2, xml.len, @intCast(xml_offset));
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, xml);
    try data.append(std.testing.allocator, 1);

    try std.testing.expect(!matches(data.items));
}

test "matches operetta image description" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const xml = "<TiffImageDescription xmlns=\"http://www.perkinelmer.com/PEHH/HarmonyV5\"><MeasurementLayout><Type>Operette</Type></MeasurementLayout></TiffImageDescription>\x00";
    const xml_offset = ifd_end;
    const pixel_offset = xml_offset + xml.len;

    try appendU16Le(&data, entry_count);
    try appendEntry(&data, 256, 4, 1, 1);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 1, 8);
    try appendEntry(&data, 259, 3, 1, 1);
    try appendEntry(&data, 262, 3, 1, 1);
    try appendEntry(&data, 270, 2, xml.len, @intCast(xml_offset));
    try appendEntry(&data, 273, 4, 1, @intCast(pixel_offset));
    try appendEntry(&data, 277, 3, 1, 1);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 1, 1);
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, xml);
    try data.append(std.testing.allocator, 9);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("operetta", metadata.format);
    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{9}, plane.data);
}
