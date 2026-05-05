const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;
const measurement_file = "MeasurementResult.xml";
const image_dir_name = "Image";

const PlaneRef = struct {
    well: u32,
    field: u32,
    t: u32,
    z: u32,
    c: u32,
    path: []u8,
};

pub fn matches(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "MeasurementResult") != null or
        std.mem.indexOf(u8, data, "CellVoyager") != null or
        std.mem.indexOf(u8, data, "Yokogawa") != null;
}

pub fn isPath(path: []const u8) bool {
    if (hasExtension(path, "xml")) return true;
    if (hasExtension(path, "tif") or hasExtension(path, "tiff")) return pathHasComponent(path, image_dir_name);
    return false;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!matches(data)) return error.InvalidFormat;
    return error.UnsupportedVariant;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const root = try datasetRoot(allocator, io, path);
    defer allocator.free(root);
    var planes: std.ArrayList(PlaneRef) = .empty;
    defer freePlanes(allocator, &planes);
    try collectPlanes(allocator, io, root, &planes);
    if (planes.items.len == 0) return error.FileNotFound;
    sortPlanes(planes.items);

    const first = try readFile(allocator, io, planes.items[0].path);
    defer allocator.free(first);
    var metadata = try bio.tiff.readMetadata(first);
    metadata.format = "cellvoyager";
    metadata.image_description = null;
    metadata.size_z = maxDimension(planes.items, .z);
    metadata.size_c = maxDimension(planes.items, .c);
    metadata.size_t = maxDimension(planes.items, .t);
    metadata.plane_count = @intCast(planes.items.len);
    metadata.dimension_order = "XYCZT";
    return metadata;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const root = try datasetRoot(allocator, io, path);
    defer allocator.free(root);
    var planes: std.ArrayList(PlaneRef) = .empty;
    defer freePlanes(allocator, &planes);
    try collectPlanes(allocator, io, root, &planes);
    sortPlanes(planes.items);
    if (plane_index >= planes.items.len) return error.InvalidPlaneIndex;

    const data = try readFile(allocator, io, planes.items[plane_index].path);
    defer allocator.free(data);
    var plane = try bio.tiff.readRegionIndex(allocator, data, 0, region);
    plane.metadata.format = "cellvoyager";
    plane.metadata.image_description = null;
    plane.metadata.size_z = maxDimension(planes.items, .z);
    plane.metadata.size_c = maxDimension(planes.items, .c);
    plane.metadata.size_t = maxDimension(planes.items, .t);
    plane.metadata.plane_count = @intCast(planes.items.len);
    plane.metadata.dimension_order = "XYCZT";
    return plane;
}

const Axis = enum { z, c, t };

fn maxDimension(planes: []const PlaneRef, axis: Axis) u16 {
    var max_value: u32 = 0;
    for (planes) |plane| {
        const value = switch (axis) {
            .z => plane.z,
            .c => plane.c,
            .t => plane.t,
        };
        max_value = @max(max_value, value);
    }
    return @intCast(@min(max_value + 1, std.math.maxInt(u16)));
}

fn datasetRoot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var current = if (hasExtension(path, "xml") or hasExtension(path, "tif") or hasExtension(path, "tiff"))
        try parentPath(allocator, path)
    else
        try allocator.dupe(u8, path);
    errdefer allocator.free(current);

    if (std.ascii.eqlIgnoreCase(basename(current), image_dir_name)) {
        const parent = try parentPath(allocator, current);
        allocator.free(current);
        current = parent;
    }

    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        const measurement = try joinPath(allocator, current, measurement_file);
        defer allocator.free(measurement);
        const image_dir = try joinPath(allocator, current, image_dir_name);
        defer allocator.free(image_dir);
        if (existsFile(io, measurement) and isDirectory(io, image_dir)) return current;

        const next = try parentPath(allocator, current);
        if (std.mem.eql(u8, next, current)) {
            allocator.free(next);
            break;
        }
        allocator.free(current);
        current = next;
    }
    allocator.free(current);
    return error.FileNotFound;
}

fn collectPlanes(allocator: std.mem.Allocator, io: std.Io, root: []const u8, planes: *std.ArrayList(PlaneRef)) !void {
    const image_dir = try joinPath(allocator, root, image_dir_name);
    defer allocator.free(image_dir);
    try collectPlanesRecursive(allocator, io, image_dir, planes, 0);
}

fn collectPlanesRecursive(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, planes: *std.ArrayList(PlaneRef), depth: usize) !void {
    if (depth > 8) return;
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    var dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (dirs.items) |dir_name| allocator.free(dir_name);
        dirs.deinit(allocator);
    }

    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and isTiffPath(entry.name)) {
            const parsed = parsePlaneName(entry.name) orelse continue;
            const image_path = try joinPath(allocator, dir_path, entry.name);
            errdefer allocator.free(image_path);
            try planes.append(allocator, .{
                .well = parsed.well,
                .field = parsed.field,
                .t = parsed.t,
                .z = parsed.z,
                .c = parsed.c,
                .path = image_path,
            });
        } else if (entry.kind == .directory) {
            try dirs.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    for (dirs.items) |dir_name| {
        const child = try joinPath(allocator, dir_path, dir_name);
        defer allocator.free(child);
        try collectPlanesRecursive(allocator, io, child, planes, depth + 1);
    }
}

const ParsedName = struct {
    well: u32,
    field: u32,
    t: u32,
    z: u32,
    c: u32,
};

fn parsePlaneName(name: []const u8) ?ParsedName {
    const stem_end = std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len;
    const stem = name[0..stem_end];
    if (stem.len == 0 or stem[0] != 'W') return null;
    var cursor: usize = 1;
    const well = parseNumberUntil(stem, &cursor, 'F') orelse return null;
    const field = parseNumberUntil(stem, &cursor, 'T') orelse return null;
    const t = parseNumberUntil(stem, &cursor, 'Z') orelse return null;
    const z = parseNumberUntil(stem, &cursor, 'C') orelse return null;
    if (cursor >= stem.len) return null;
    const c = std.fmt.parseUnsigned(u32, stem[cursor..], 10) catch return null;
    return .{
        .well = well -| 1,
        .field = field -| 1,
        .t = t -| 1,
        .z = z -| 1,
        .c = c -| 1,
    };
}

fn parseNumberUntil(text: []const u8, cursor: *usize, delimiter: u8) ?u32 {
    const start = cursor.*;
    while (cursor.* < text.len and text[cursor.*] != delimiter) : (cursor.* += 1) {}
    if (cursor.* == start or cursor.* >= text.len) return null;
    const value = std.fmt.parseUnsigned(u32, text[start..cursor.*], 10) catch return null;
    cursor.* += 1;
    return value;
}

fn sortPlanes(planes: []PlaneRef) void {
    var i: usize = 1;
    while (i < planes.len) : (i += 1) {
        var j = i;
        while (j > 0 and lessPlane(planes[j], planes[j - 1])) : (j -= 1) {
            const tmp = planes[j - 1];
            planes[j - 1] = planes[j];
            planes[j] = tmp;
        }
    }
}

fn lessPlane(a: PlaneRef, b: PlaneRef) bool {
    if (a.well != b.well) return a.well < b.well;
    if (a.field != b.field) return a.field < b.field;
    if (a.t != b.t) return a.t < b.t;
    if (a.z != b.z) return a.z < b.z;
    return a.c < b.c;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn existsFile(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn isDirectory(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn parentPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const sep = lastSeparator(path) orelse return allocator.dupe(u8, ".");
    if (sep == 0) return allocator.dupe(u8, path[0..1]);
    const out = try allocator.alloc(u8, sep);
    std.mem.copyForwards(u8, out, path[0..sep]);
    return out;
}

fn basename(path: []const u8) []const u8 {
    const sep = lastSeparator(path) orelse return path;
    return path[sep + 1 ..];
}

fn pathHasComponent(path: []const u8, component: []const u8) bool {
    var start: usize = 0;
    while (start <= path.len) {
        var end = start;
        while (end < path.len and path[end] != '/' and path[end] != '\\') : (end += 1) {}
        if (end > start and std.ascii.eqlIgnoreCase(path[start..end], component)) return true;
        if (end == path.len) break;
        start = end + 1;
    }
    return false;
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    if (isAbsolutePath(name)) return allocator.dupe(u8, name);
    const sep: u8 = if (std.mem.indexOfScalar(u8, base, '\\') != null) '\\' else '/';
    const needs_sep = base.len != 0 and base[base.len - 1] != '/' and base[base.len - 1] != '\\';
    const extra: usize = if (needs_sep) 1 else 0;
    const out = try allocator.alloc(u8, base.len + extra + name.len);
    std.mem.copyForwards(u8, out[0..base.len], base);
    if (needs_sep) out[base.len] = sep;
    std.mem.copyForwards(u8, out[base.len + extra ..], name);
    return out;
}

fn lastSeparator(path: []const u8) ?usize {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    if (slash == null) return backslash;
    if (backslash == null) return slash;
    return @max(slash.?, backslash.?);
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

fn freePlanes(allocator: std.mem.Allocator, planes: *std.ArrayList(PlaneRef)) void {
    for (planes.items) |plane| allocator.free(plane.path);
    planes.deinit(allocator);
}

const tiny_tiff = [_]u8{
    'I', 'I', 42, 0, 8, 0, 0,  0, 9, 0, 0,  1, 4, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 1,  1, 4, 0, 1,  0, 0, 0, 1,   0,
    0,   0,   2,  1, 3, 0, 1,  0, 0, 0, 8,  0, 0, 0, 3,   1,
    3,   0,   1,  0, 0, 0, 1,  0, 0, 0, 6,  1, 3, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 17, 1, 4, 0, 1,  0, 0, 0, 122, 0,
    0,   0,   21, 1, 3, 0, 1,  0, 0, 0, 1,  0, 0, 0, 22,  1,
    4,   0,   1,  0, 0, 0, 1,  0, 0, 0, 23, 1, 4, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 0,  0, 0, 0, 91,
};

test "parses cellvoyager image names" {
    const parsed = parsePlaneName("W1F003T0002Z04C2.tif").?;
    try std.testing.expectEqual(@as(u32, 0), parsed.well);
    try std.testing.expectEqual(@as(u32, 2), parsed.field);
    try std.testing.expectEqual(@as(u32, 1), parsed.t);
    try std.testing.expectEqual(@as(u32, 3), parsed.z);
    try std.testing.expectEqual(@as(u32, 1), parsed.c);
}

test "does not claim unrelated tiff paths" {
    try std.testing.expect(!isPath("sample.tif"));
    try std.testing.expect(!isPath("C:\\data\\sample.tif"));
    try std.testing.expect(isPath("dataset/Image/sample.tif"));
}

test "reads cellvoyager measurement directory through image tiff" {
    const root = "cellvoyager-test";
    const images = "cellvoyager-test/Image";
    const xml_path = "cellvoyager-test/MeasurementResult.xml";
    const ome_path = "cellvoyager-test/MeasurementResult.ome.xml";
    const tiff_path = "cellvoyager-test/Image/W1F001T0001Z01C1.tif";
    cleanupFixture(root, images, xml_path, ome_path, tiff_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, images, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, images) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = xml_path, .data = "<MeasurementResult><CellVoyager/></MeasurementResult>" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, xml_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = ome_path, .data = "<OME/>" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ome_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tiff_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, xml_path);
    try std.testing.expectEqualStrings("cellvoyager", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, tiff_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("cellvoyager", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{91}, plane.data);
}

fn cleanupFixture(root: []const u8, images: []const u8, xml_path: []const u8, ome_path: []const u8, tiff_path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, ome_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, xml_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, images) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
}
