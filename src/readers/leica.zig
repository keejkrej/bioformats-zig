const std = @import("std");
const bio = @import("../root.zig");

const leica_magic_tag: u16 = 33923;

pub fn matches(data: []const u8) bool {
    return bio.tiff.containsTag(data, leica_magic_tag);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "lei") or hasExtension(path, "tif") or hasExtension(path, "tiff");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!matches(data)) return error.InvalidFormat;
    var metadata = try bio.tiff.readMetadata(data);
    metadata.format = "leica";
    return metadata;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    if (!matches(data)) return error.InvalidFormat;
    var plane = try bio.tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "leica";
    return plane;
}

pub fn readRegionIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32, region: bio.Region) bio.ReaderError!bio.Plane {
    if (!matches(data)) return error.InvalidFormat;
    var plane = try bio.tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "leica";
    return plane;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    if (!hasExtension(path, "tif") and !hasExtension(path, "tiff")) return error.UnsupportedVariant;
    const data = try readFile(allocator, io, path);
    defer allocator.free(data);
    return readMetadata(data);
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024 * 1024));
}

fn hasExtension(path: []const u8, ext: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], ext);
}

fn appendU16Le(list: *std.ArrayList(u8), value: u16) !void {
    try list.append(std.testing.allocator, @intCast(value & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
}

fn appendU32Le(list: *std.ArrayList(u8), value: u32) !void {
    try list.append(std.testing.allocator, @intCast(value & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
}

fn appendEntry(list: *std.ArrayList(u8), tag: u16, field_type: u16, count: u32, value: u32) !void {
    try appendU16Le(list, tag);
    try appendU16Le(list, field_type);
    try appendU32Le(list, count);
    try appendU32Le(list, value);
}

fn appendTinyTiff(list: *std.ArrayList(u8), pixel: u8, include_leica_tag: bool) !void {
    const ifd_offset: u32 = 8;
    const entry_count: u16 = if (include_leica_tag) 10 else 9;
    const pixel_offset: u32 = ifd_offset + 2 + entry_count * 12 + 4;

    try list.appendSlice(std.testing.allocator, "II");
    try appendU16Le(list, 42);
    try appendU32Le(list, ifd_offset);
    try appendU16Le(list, entry_count);
    try appendEntry(list, 256, 4, 1, 1);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, 8);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 273, 4, 1, pixel_offset);
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 1);
    if (include_leica_tag) try appendEntry(list, leica_magic_tag, 4, 1, 1);
    try appendU32Le(list, 0);
    try list.append(std.testing.allocator, pixel);
}

test "delegates leica tagged tiff metadata and pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendTinyTiff(&data, 73, true);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("leica", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("leica", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{73}, plane.data);
}

test "rejects ordinary tiff without leica tag" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendTinyTiff(&data, 11, false);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
}
