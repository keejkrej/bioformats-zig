const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const max_companion_bytes = 512 * 1024 * 1024;
const xml_suffix = "_meta.xml";

pub fn matches(data: []const u8) bool {
    _ = data;
    return false;
}

pub fn isPath(path: []const u8) bool {
    return isTiffName(path) or endsWithIgnoreCase(path, xml_suffix);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    _ = data;
    return error.UnsupportedFormat;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedFormat;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const image_path = try imagePath(allocator, io, path);
    defer allocator.free(image_path);
    const image = try readFile(allocator, io, image_path);
    defer allocator.free(image);
    var metadata = try tiff.readMetadata(image);
    metadata.format = "zeisstiff";
    metadata.image_description = null;
    return metadata;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const image_path = try imagePath(allocator, io, path);
    defer allocator.free(image_path);
    const image = try readFile(allocator, io, image_path);
    defer allocator.free(image);
    var plane = try tiff.readRegionIndex(allocator, image, plane_index, region);
    plane.metadata.format = "zeisstiff";
    plane.metadata.image_description = null;
    return plane;
}

fn imagePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (isTiffName(path)) {
        const sibling_xml = try appendSuffix(allocator, path, xml_suffix);
        defer allocator.free(sibling_xml);
        if (!exists(io, path)) return error.FileNotFound;
        if (!exists(io, sibling_xml)) return error.InvalidFormat;
        return allocator.dupe(u8, path);
    }

    if (!endsWithIgnoreCase(path, xml_suffix)) return error.InvalidFormat;
    if (!exists(io, path)) return error.FileNotFound;
    const basename_xml = basename(path);
    if (!std.ascii.eqlIgnoreCase(basename_xml, xml_suffix)) {
        const trimmed = path[0 .. path.len - xml_suffix.len];
        if (isTiffName(trimmed) and exists(io, trimmed)) return allocator.dupe(u8, trimmed);
    }
    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    return firstTiffInDirectory(allocator, io, parent);
}

fn firstTiffInDirectory(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and isTiffName(entry.name)) {
            return joinPath(allocator, dir_path, entry.name);
        }
    }
    return error.FileNotFound;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn exists(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn parentPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const sep = lastSeparator(path) orelse return allocator.dupe(u8, ".");
    if (sep == 0) return allocator.dupe(u8, path[0..1]);
    return allocator.dupe(u8, path[0..sep]);
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    const sep: u8 = if (std.mem.indexOfScalar(u8, base, '\\') != null) '\\' else '/';
    const needs_sep = base.len != 0 and base[base.len - 1] != '/' and base[base.len - 1] != '\\';
    const extra: usize = if (needs_sep) 1 else 0;
    const out = try allocator.alloc(u8, base.len + extra + name.len);
    @memcpy(out[0..base.len], base);
    if (needs_sep) out[base.len] = sep;
    @memcpy(out[base.len + extra ..], name);
    return out;
}

fn appendSuffix(allocator: std.mem.Allocator, path: []const u8, suffix: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, path.len + suffix.len);
    @memcpy(out[0..path.len], path);
    @memcpy(out[path.len..], suffix);
    return out;
}

fn basename(path: []const u8) []const u8 {
    const sep = lastSeparator(path) orelse return path;
    return path[sep + 1 ..];
}

fn lastSeparator(path: []const u8) ?usize {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    if (slash == null) return backslash;
    if (backslash == null) return slash;
    return @max(slash.?, backslash.?);
}

fn isTiffName(path: []const u8) bool {
    return hasExtension(path, "tif") or hasExtension(path, "tiff");
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    return value.len >= suffix.len and std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn appendTinyTiff(list: *std.ArrayList(u8), pixel: u8) !void {
    try list.appendSlice(std.testing.allocator, &.{
        'I', 'I', 42, 0, 8, 0, 0,  0, 9, 0, 0,  1, 4, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 1,  1, 4, 0, 1,  0, 0, 0, 1,   0,
        0,   0,   2,  1, 3, 0, 1,  0, 0, 0, 8,  0, 0, 0, 3,   1,
        3,   0,   1,  0, 0, 0, 1,  0, 0, 0, 6,  1, 3, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 17, 1, 4, 0, 1,  0, 0, 0, 122, 0,
        0,   0,   21, 1, 3, 0, 1,  0, 0, 0, 1,  0, 0, 0, 22,  1,
        4,   0,   1,  0, 0, 0, 1,  0, 0, 0, 23, 1, 4, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 0,  0, 0, 0,
    });
    try list.append(std.testing.allocator, pixel);
}

test "reads zeiss tiff with sibling xml" {
    const image_path = "zeisstiff-test.tif";
    const xml_path = "zeisstiff-test.tif_meta.xml";
    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(std.testing.allocator);
    try appendTinyTiff(&image, 88);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = image.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = xml_path, .data = "<ROOT />" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, xml_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, xml_path);
    try std.testing.expectEqualStrings("zeisstiff", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, image_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zeisstiff", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{88}, plane.data);
}

test "rejects standalone tiff without zeiss companion xml" {
    const image_path = "zeisstiff-standalone-test.tif";
    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(std.testing.allocator);
    try appendTinyTiff(&image, 88);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = image.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};
    try std.testing.expectError(error.InvalidFormat, readMetadataPath(std.testing.allocator, std.testing.io, image_path));
}
