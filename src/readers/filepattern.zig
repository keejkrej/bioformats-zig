const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

pub fn matches(data: []const u8) bool {
    _ = data;
    return false;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "pattern");
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
    const target = try targetPath(allocator, io, path);
    defer allocator.free(target);
    const bytes = try readFile(allocator, io, target);
    defer allocator.free(bytes);
    var metadata = try bio.readMetadata(bytes);
    metadata.format = "filepattern";
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
    const target = try targetPath(allocator, io, path);
    defer allocator.free(target);
    const bytes = try readFile(allocator, io, target);
    defer allocator.free(bytes);
    var plane = try bio.readPlaneRegionIndex(allocator, bytes, plane_index, region);
    plane.metadata.format = "filepattern";
    plane.metadata.image_description = null;
    return plane;
}

fn targetPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (!isPath(path)) return error.InvalidFormat;
    const data = try readFile(allocator, io, path);
    defer allocator.free(data);
    const pattern = firstLine(data);
    if (pattern.len == 0) return error.InvalidFormat;
    if (hasPatternSyntax(pattern)) return error.UnsupportedVariant;
    if (hasDirectory(pattern) or isAbsolutePath(pattern)) return allocator.dupe(u8, pattern);
    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    return joinPath(allocator, parent, pattern);
}

fn firstLine(data: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, data, "\r\n") orelse data.len;
    return std.mem.trim(u8, data[0..end], " \t");
}

fn hasPatternSyntax(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "<>[]?*") != null;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
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

fn lastSeparator(path: []const u8) ?usize {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    if (slash == null) return backslash;
    if (backslash == null) return slash;
    return @max(slash.?, backslash.?);
}

fn hasDirectory(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '/') != null or std.mem.indexOfScalar(u8, path, '\\') != null;
}

fn isAbsolutePath(path: []const u8) bool {
    if (path.len >= 1 and (path[0] == '/' or path[0] == '\\')) return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

test "reads literal file pattern through target image" {
    const pattern_path = "filepattern-test.pattern";
    const image_path = "filepattern-test.pgm";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = pattern_path, .data = "filepattern-test.pgm\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, pattern_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = "P5\n2 2\n255\n\x01\x02\x03\x04" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, pattern_path);
    try std.testing.expectEqualStrings("filepattern", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, pattern_path, 0, .{ .x = 1, .y = 0, .width = 1, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("filepattern", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 2, 4 }, plane.data);
}

test "rejects unsupported file pattern syntax" {
    const pattern_path = "filepattern-unsupported.pattern";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = pattern_path, .data = "image_<1-3>.tif\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, pattern_path) catch {};
    try std.testing.expectError(error.UnsupportedVariant, readMetadataPath(std.testing.allocator, std.testing.io, pattern_path));
}
