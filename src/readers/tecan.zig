const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

pub fn matches(data: []const u8) bool {
    _ = data;
    return false;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "db") or hasExtension(path, "tif") or hasExtension(path, "tiff");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    _ = data;
    return error.UnsupportedVariant;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const image_path = try selectedTiffPath(allocator, io, path);
    defer allocator.free(image_path);
    const data = try readFile(allocator, io, image_path);
    defer allocator.free(data);
    var metadata = try bio.tiff.readMetadata(data);
    metadata.format = "tecan";
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
    const image_path = try selectedTiffPath(allocator, io, path);
    defer allocator.free(image_path);
    const data = try readFile(allocator, io, image_path);
    defer allocator.free(data);
    var plane = try bio.tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "tecan";
    plane.metadata.image_description = null;
    return plane;
}

fn selectedTiffPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (isTiffPath(path)) {
        const root = try tecanRootFromImage(allocator, io, path);
        allocator.free(root);
        return allocator.dupe(u8, path);
    }
    if (!hasExtension(path, "db")) return error.InvalidFormat;
    const root = try tecanRootFromDb(allocator, io, path);
    defer allocator.free(root);
    const images = try joinPath(allocator, root, "Images");
    defer allocator.free(images);
    return findFirstTiffRecursive(allocator, io, images, 0);
}

fn tecanRootFromDb(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) ![]u8 {
    const parent = try parentPath(allocator, db_path);
    defer allocator.free(parent);
    const grandparent = try parentPath(allocator, parent);
    defer allocator.free(grandparent);

    const java_layout_images = try joinPath(allocator, grandparent, "Images");
    defer allocator.free(java_layout_images);
    if (isDirectory(io, java_layout_images)) return allocator.dupe(u8, grandparent);

    const flat_images = try joinPath(allocator, parent, "Images");
    defer allocator.free(flat_images);
    if (isDirectory(io, flat_images)) return allocator.dupe(u8, parent);

    return error.FileNotFound;
}

fn tecanRootFromImage(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) ![]u8 {
    var current = try parentPath(allocator, image_path);
    defer allocator.free(current);
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        const name = basename(current);
        if (std.ascii.eqlIgnoreCase(name, "Images")) {
            const root = try parentPath(allocator, current);
            errdefer allocator.free(root);
            const db = try findFirstDbRecursive(allocator, io, root, 0);
            allocator.free(db);
            return root;
        }
        const next = try parentPath(allocator, current);
        if (std.mem.eql(u8, next, current)) {
            allocator.free(next);
            break;
        }
        allocator.free(current);
        current = next;
    }
    return error.FileNotFound;
}

fn findFirstDbRecursive(allocator: std.mem.Allocator, io: std.Io, root: []const u8, depth: usize) ![]u8 {
    if (depth > 3) return error.FileNotFound;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    var dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (dirs.items) |dir_name| allocator.free(dir_name);
        dirs.deinit(allocator);
    }

    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and hasExtension(entry.name, "db")) return joinPath(allocator, root, entry.name);
        if (entry.kind == .directory) try dirs.append(allocator, try allocator.dupe(u8, entry.name));
    }
    for (dirs.items) |dir_name| {
        if (std.ascii.eqlIgnoreCase(dir_name, "Images") or std.ascii.eqlIgnoreCase(dir_name, "Export")) continue;
        const child = try joinPath(allocator, root, dir_name);
        defer allocator.free(child);
        if (findFirstDbRecursive(allocator, io, child, depth + 1)) |db| return db else |_| {}
    }
    return error.FileNotFound;
}

fn findFirstTiffRecursive(allocator: std.mem.Allocator, io: std.Io, root: []const u8, depth: usize) ![]u8 {
    if (depth > 8) return error.FileNotFound;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    var first_dir: ?[]u8 = null;
    defer if (first_dir) |dir_name| allocator.free(dir_name);

    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and isTiffPath(entry.name)) return joinPath(allocator, root, entry.name);
        if (entry.kind == .directory and first_dir == null) first_dir = try allocator.dupe(u8, entry.name);
    }
    if (first_dir) |dir_name| {
        const child = try joinPath(allocator, root, dir_name);
        defer allocator.free(child);
        return findFirstTiffRecursive(allocator, io, child, depth + 1);
    }
    return error.FileNotFound;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn isDirectory(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn parentPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const sep = lastSeparator(path) orelse return allocator.dupe(u8, ".");
    if (sep == 0) return allocator.dupe(u8, path[0..1]);
    return allocator.dupe(u8, path[0..sep]);
}

fn basename(path: []const u8) []const u8 {
    const sep = lastSeparator(path) orelse return path;
    return path[sep + 1 ..];
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

fn isTiffPath(path: []const u8) bool {
    return hasExtension(path, "tif") or hasExtension(path, "tiff");
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
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

test "reads tecan db through images directory" {
    const root = "tecan-test";
    const run = "tecan-test/Workspace";
    const images = "tecan-test/Images/WellA1";
    const db_path = "tecan-test/Workspace/workspace.db";
    const tiff_path = "tecan-test/Images/WellA1/img.tif";
    std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, db_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, images) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, "tecan-test/Images") catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, run) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, run, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, run) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, "tecan-test/Images", .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, "tecan-test/Images") catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, images, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, images) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = db_path, .data = "SQLite format 3\x00" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, db_path) catch {};
    var tiff_data: std.ArrayList(u8) = .empty;
    defer tiff_data.deinit(std.testing.allocator);
    try appendTinyTiff(&tiff_data, 68);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tiff_path, .data = tiff_data.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, db_path);
    try std.testing.expectEqualStrings("tecan", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, tiff_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("tecan", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{68}, plane.data);
}
