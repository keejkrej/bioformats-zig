const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const image_description_tag = 270;

pub fn matches(data: []const u8) bool {
    const description = tiff.firstIfdAsciiTag(data, image_description_tag) orelse return false;
    const trimmed = std.mem.trim(u8, description, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '<' or trimmed[trimmed.len - 1] != '>') return false;
    return std.mem.indexOf(u8, trimmed, "<OME") != null;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    var metadata = try tiff.readMetadata(data);
    metadata.format = "ometiff";
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "ometiff";
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    var plane = try tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "ometiff";
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

test "reads ome-tiff tagged plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const description =
        \\<OME><Image ID="Image:0"><Pixels DimensionOrder="XYZCT" Type="uint8" SizeX="1" SizeY="1" SizeZ="1" SizeC="1" SizeT="1"/></Image></OME>
    ++ "\x00";
    const description_offset = ifd_end;
    const pixel_offset = description_offset + description.len;

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
    try appendEntry(&data, image_description_tag, 2, description.len, @intCast(description_offset));
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, description);
    try data.append(std.testing.allocator, 17);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("ometiff", metadata.format);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("ometiff", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{17}, plane.data);
}

test "rejects non-xml tiff description" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);
    const entry_count = 1;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const description = "not xml OME\x00";
    try appendU16Le(&data, entry_count);
    try appendEntry(&data, image_description_tag, 2, description.len, @intCast(ifd_end));
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, description);

    try std.testing.expect(!matches(data.items));
}
