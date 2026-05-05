const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const make_tag = 271;
const software_tag = 305;
const sis_tag = 33560;
const sis_tag_2 = 34853;

pub fn matches(data: []const u8) bool {
    const software = tiff.firstIfdAsciiTag(data, software_tag);
    const make = tiff.firstIfdAsciiTag(data, make_tag);
    return (tiff.containsTag(data, sis_tag) and (software == null or startsWithTrimmed(software.?, "analySIS"))) or
        (tiff.containsTag(data, sis_tag_2) and make != null and startsWithTrimmed(make.?, "Olympus"));
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    var metadata = try tiff.readMetadata(data);
    metadata.format = "sis";
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "sis";
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    var plane = try tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "sis";
    return plane;
}

fn startsWithTrimmed(text: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trim(u8, text, " \t\r\n\x00"), prefix);
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

test "reads sis tagged tiff plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 11;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const software = "analySIS 5\x00";
    const pixel_offset = ifd_end + software.len;

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
    try appendEntry(&data, software_tag, 2, software.len, @intCast(ifd_end));
    try appendEntry(&data, sis_tag, 1, 4, 0);
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, software);
    try data.append(std.testing.allocator, 77);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("sis", metadata.format);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("sis", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}

test "matches olympus sis secondary tag" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 11;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const make = "Olympus Soft Imaging\x00";
    const pixel_offset = ifd_end + make.len;

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
    try appendEntry(&data, make_tag, 2, make.len, @intCast(ifd_end));
    try appendEntry(&data, sis_tag_2, 4, 1, 0);
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, make);
    try data.append(std.testing.allocator, 1);

    try std.testing.expect(matches(data.items));
}
