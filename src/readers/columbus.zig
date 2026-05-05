const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;
const max_scan_depth = 4;
const index_name = "MeasurementIndex.ColumbusIDX.xml";
const magic = "ColumbusMeasurementIndex";

pub fn matches(data: []const u8) bool {
    return isColumbusIndex(data);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "xml") or hasExtension(path, "tif") or hasExtension(path, "tiff");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!isColumbusIndex(data)) return error.InvalidFormat;
    return error.UnsupportedVariant;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const xml_path = try findIndexPath(allocator, io, path);
    defer allocator.free(xml_path);
    const xml = try readFile(allocator, io, xml_path);
    defer allocator.free(xml);
    if (!isColumbusIndex(xml)) return error.InvalidFormat;

    var tiffs: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &tiffs);
    try collectDatasetTiffs(allocator, io, xml_path, &tiffs);
    if (tiffs.items.len == 0) return error.FileNotFound;

    const first = try readFile(allocator, io, tiffs.items[0]);
    defer allocator.free(first);
    var metadata = try bio.tiff.readMetadata(first);
    metadata.format = "columbus";
    metadata.image_description = null;
    metadata.plane_count = try totalPlaneCount(allocator, io, tiffs.items);
    metadata.size_z = 1;
    metadata.size_c = 1;
    metadata.size_t = @intCast(@max(@as(u32, 1), metadata.plane_count));
    metadata.dimension_order = "XYZCT";
    return metadata;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const xml_path = try findIndexPath(allocator, io, path);
    defer allocator.free(xml_path);
    const xml = try readFile(allocator, io, xml_path);
    defer allocator.free(xml);
    if (!isColumbusIndex(xml)) return error.InvalidFormat;

    var tiffs: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &tiffs);
    try collectDatasetTiffs(allocator, io, xml_path, &tiffs);

    var remaining = plane_index;
    for (tiffs.items) |tiff_path| {
        const tiff = try readFile(allocator, io, tiff_path);
        defer allocator.free(tiff);
        const count = bio.tiff.ifdCount(tiff) orelse 1;
        if (remaining < count) {
            var plane = try bio.tiff.readRegionIndex(allocator, tiff, remaining, region);
            plane.metadata.format = "columbus";
            plane.metadata.image_description = null;
            plane.metadata.plane_count = try totalPlaneCount(allocator, io, tiffs.items);
            plane.metadata.size_z = 1;
            plane.metadata.size_c = 1;
            plane.metadata.size_t = @intCast(@max(@as(u32, 1), plane.metadata.plane_count));
            plane.metadata.dimension_order = "XYZCT";
            return plane;
        }
        remaining -= count;
    }
    return error.InvalidPlaneIndex;
}

fn findIndexPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.ascii.eqlIgnoreCase(baseName(path), index_name)) return allocator.dupe(u8, path);

    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    if (try siblingIndexPath(allocator, io, parent)) |candidate| return candidate;

    const grandparent = try parentPath(allocator, parent);
    defer allocator.free(grandparent);
    if (!std.mem.eql(u8, grandparent, parent)) {
        if (try siblingIndexPath(allocator, io, grandparent)) |candidate| return candidate;
    }
    return error.FileNotFound;
}

fn siblingIndexPath(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !?[]u8 {
    const canonical = try joinPath(allocator, dir_path, index_name);
    errdefer allocator.free(canonical);
    if (existsFile(io, canonical)) return canonical;
    allocator.free(canonical);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, "columbusidx.xml")) continue;
        return try joinPath(allocator, dir_path, entry.name);
    }
    return null;
}

fn collectDatasetTiffs(allocator: std.mem.Allocator, io: std.Io, xml_path: []const u8, out: *std.ArrayList([]u8)) !void {
    const root = try parentPath(allocator, xml_path);
    defer allocator.free(root);
    try collectTiffsRecursive(allocator, io, root, 0, out);
    sortPaths(out.items);
}

fn collectTiffsRecursive(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, depth: u8, out: *std.ArrayList([]u8)) !void {
    if (depth > max_scan_depth) return;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) {
            const child = try joinPath(allocator, dir_path, entry.name);
            defer allocator.free(child);
            try collectTiffsRecursive(allocator, io, child, depth + 1, out);
        } else if (entry.kind == .file and isTiffName(entry.name)) {
            const path = try joinPath(allocator, dir_path, entry.name);
            errdefer allocator.free(path);
            try appendUniquePath(allocator, out, path);
            allocator.free(path);
        }
    }
}

fn appendUniquePath(allocator: std.mem.Allocator, out: *std.ArrayList([]u8), path: []const u8) !void {
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    try out.append(allocator, try allocator.dupe(u8, path));
}

fn totalPlaneCount(allocator: std.mem.Allocator, io: std.Io, paths: []const []u8) !u32 {
    var count: u32 = 0;
    for (paths) |path| {
        const bytes = try readFile(allocator, io, path);
        defer allocator.free(bytes);
        count += bio.tiff.ifdCount(bytes) orelse 1;
    }
    return count;
}

fn isColumbusIndex(data: []const u8) bool {
    return std.mem.indexOf(u8, data, magic) != null;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn existsFile(io: std.Io, path: []const u8) bool {
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
    if (hasDirectory(name) or isAbsolutePath(name)) return allocator.dupe(u8, name);
    const sep: u8 = if (std.mem.indexOfScalar(u8, base, '\\') != null) '\\' else '/';
    const needs_sep = base.len != 0 and base[base.len - 1] != '/' and base[base.len - 1] != '\\';
    const extra: usize = if (needs_sep) 1 else 0;
    const out = try allocator.alloc(u8, base.len + extra + name.len);
    @memcpy(out[0..base.len], base);
    if (needs_sep) out[base.len] = sep;
    @memcpy(out[base.len + extra ..], name);
    return out;
}

fn baseName(path: []const u8) []const u8 {
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

fn hasDirectory(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '/') != null or std.mem.indexOfScalar(u8, path, '\\') != null;
}

fn isAbsolutePath(path: []const u8) bool {
    if (path.len >= 1 and (path[0] == '/' or path[0] == '\\')) return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
}

fn isTiffName(path: []const u8) bool {
    return hasExtension(path, "tif") or hasExtension(path, "tiff");
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn sortPaths(paths: [][]u8) void {
    var i: usize = 1;
    while (i < paths.len) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, paths[j], paths[j - 1])) : (j -= 1) {
            const tmp = paths[j - 1];
            paths[j - 1] = paths[j];
            paths[j] = tmp;
        }
    }
}

fn freePaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

const tiny_tiff = [_]u8{
    'I', 'I', 42, 0, 8, 0, 0,  0, 9, 0, 0,  1, 4, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 1,  1, 4, 0, 1,  0, 0, 0, 1,   0,
    0,   0,   2,  1, 3, 0, 1,  0, 0, 0, 8,  0, 0, 0, 3,   1,
    3,   0,   1,  0, 0, 0, 1,  0, 0, 0, 6,  1, 3, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 17, 1, 4, 0, 1,  0, 0, 0, 122, 0,
    0,   0,   21, 1, 3, 0, 1,  0, 0, 0, 1,  0, 0, 0, 22,  1,
    4,   0,   1,  0, 0, 0, 1,  0, 0, 0, 23, 1, 4, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 0,  0, 0, 0, 77,
};

const xml_fixture =
    "<?xml version=\"1.0\"?><ColumbusMeasurementIndex>" ++
    "<Plates><Plate><Rows>1</Rows><Columns>1</Columns></Plate></Plates>" ++
    "</ColumbusMeasurementIndex>";

test "detects columbus measurement index" {
    try std.testing.expect(matches(xml_fixture));
    try std.testing.expect(!matches("<xml/>"));
}

test "reads columbus metadata through recursive tiff scan" {
    const root = "columbus-test";
    const subdir = "columbus-test/TimePoint_1";
    const xml_path = "columbus-test/MeasurementIndex.ColumbusIDX.xml";
    const tiff_path = "columbus-test/TimePoint_1/r01c01f01p01-ch1sk1fk1fl1.tiff";
    cleanupFixture(root, subdir, xml_path, tiff_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, subdir, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, subdir) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = xml_path, .data = xml_fixture });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, xml_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tiff_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, xml_path);
    try std.testing.expectEqualStrings("columbus", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
}

test "reads columbus delegated pixels from selected tiff" {
    const root = "columbus-plane-test";
    const subdir = "columbus-plane-test/TimePoint_1";
    const xml_path = "columbus-plane-test/MeasurementIndex.ColumbusIDX.xml";
    const tiff_path = "columbus-plane-test/TimePoint_1/r01c01f01p01-ch1sk1fk1fl1.tiff";
    cleanupFixture(root, subdir, xml_path, tiff_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, subdir, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, subdir) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = xml_path, .data = xml_fixture });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, xml_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tiff_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, tiff_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("columbus", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}

fn cleanupFixture(root: []const u8, subdir: []const u8, xml_path: []const u8, tiff_path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, xml_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, subdir) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
}
