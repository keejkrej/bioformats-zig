const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const max_image_bytes = 512 * 1024 * 1024;
const image_description_tag = 270;
const software_tag = 305;

pub fn matches(data: []const u8) bool {
    return containsCellSensMarker(data);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "vsi");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!matches(data)) return error.InvalidFormat;
    return metadataFromTiff(data);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    if (!matches(data)) return error.InvalidFormat;
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "cellsens";
    plane.metadata.image_description = null;
    return plane;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    if (!isPath(path)) return error.InvalidFormat;
    const bytes = try readFile(allocator, io, path);
    defer allocator.free(bytes);
    return metadataFromTiff(bytes);
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    if (!isPath(path)) return error.InvalidFormat;
    const bytes = try readFile(allocator, io, path);
    defer allocator.free(bytes);

    var plane = try tiff.readRegionIndex(allocator, bytes, plane_index, region);
    plane.metadata.format = "cellsens";
    plane.metadata.image_description = null;
    return plane;
}

fn metadataFromTiff(data: []const u8) bio.ReaderError!bio.Metadata {
    var metadata = try tiff.readMetadata(data);
    metadata.format = "cellsens";
    metadata.image_description = null;
    return metadata;
}

fn containsCellSensMarker(data: []const u8) bool {
    const description = tiff.firstIfdAsciiTag(data, image_description_tag) orelse "";
    const software = tiff.firstIfdAsciiTag(data, software_tag) orelse "";
    return containsIgnoreCase(description, "cellsens") or containsIgnoreCase(software, "cellsens");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var pos: usize = 0;
    while (pos + needle.len <= haystack.len) : (pos += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[pos..][0..needle.len], needle)) return true;
    }
    return false;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_image_bytes));
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
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

fn appendTinyVsi(list: *std.ArrayList(u8), pixel: u8) !void {
    try list.appendSlice(std.testing.allocator, "II");
    try appendU16Le(list, 42);
    try appendU32Le(list, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const software = "cellSens Dimension\x00";
    const pixel_offset = ifd_end + software.len;

    try appendU16Le(list, entry_count);
    try appendEntry(list, 256, 4, 1, 1);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, 8);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 273, 4, 1, @intCast(pixel_offset));
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 1);
    try appendEntry(list, software_tag, 2, software.len, @intCast(ifd_end));
    try appendU32Le(list, 0);
    try list.appendSlice(std.testing.allocator, software);
    try list.append(std.testing.allocator, pixel);
}

test "detects cellSens tagged tiff bytes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendTinyVsi(&data, 91);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("cellsens", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("cellsens", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{91}, plane.data);
}

test "reads cellSens vsi path through tiff delegate" {
    const path = "cellsens-test.vsi";
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendTinyVsi(&data, 17);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = data.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, path);
    try std.testing.expectEqualStrings("cellsens", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, path, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("cellsens", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{17}, plane.data);
}
