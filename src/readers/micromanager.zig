const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;
const metadata_name = "metadata.txt";

const MicroMetadata = struct {
    size_z: ?u16 = null,
    size_c: ?u16 = null,
    size_t: ?u16 = null,
    dimension_order: ?[]const u8 = null,
};

pub fn matches(data: []const u8) bool {
    return isMicroManagerMetadata(data);
}

pub fn isPath(path: []const u8) bool {
    return isMetadataName(baseName(path)) or isTiffName(path);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!isMicroManagerMetadata(data)) return error.InvalidFormat;
    return error.UnsupportedVariant;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const meta_path = try findMetadataPath(allocator, io, path);
    defer allocator.free(meta_path);
    const meta_bytes = try readFile(allocator, io, meta_path);
    defer allocator.free(meta_bytes);
    if (!isMicroManagerMetadata(meta_bytes)) return error.InvalidFormat;

    var tiffs: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &tiffs);
    try collectTiffs(allocator, io, meta_path, meta_bytes, &tiffs);
    if (tiffs.items.len == 0) return error.FileNotFound;

    const first = try readFile(allocator, io, tiffs.items[0]);
    defer allocator.free(first);
    var metadata = try bio.tiff.readMetadata(first);
    metadata.format = "micromanager";
    metadata.image_description = null;

    var plane_count: u32 = 0;
    for (tiffs.items) |tiff_path| {
        const tiff_bytes = try readFile(allocator, io, tiff_path);
        defer allocator.free(tiff_bytes);
        plane_count += bio.tiff.ifdCount(tiff_bytes) orelse 1;
    }
    metadata.plane_count = plane_count;

    const parsed = parseMicroMetadata(meta_bytes);
    metadata.size_z = parsed.size_z orelse metadata.size_z;
    metadata.size_c = parsed.size_c orelse metadata.size_c;
    metadata.size_t = parsed.size_t orelse metadata.size_t;
    metadata.dimension_order = parsed.dimension_order orelse metadata.dimension_order orelse "XYZCT";
    return metadata;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const meta_path = try findMetadataPath(allocator, io, path);
    defer allocator.free(meta_path);
    const meta_bytes = try readFile(allocator, io, meta_path);
    defer allocator.free(meta_bytes);
    if (!isMicroManagerMetadata(meta_bytes)) return error.InvalidFormat;

    var tiffs: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &tiffs);
    try collectTiffs(allocator, io, meta_path, meta_bytes, &tiffs);

    var remaining = plane_index;
    for (tiffs.items) |tiff_path| {
        const tiff_bytes = try readFile(allocator, io, tiff_path);
        defer allocator.free(tiff_bytes);
        const count = bio.tiff.ifdCount(tiff_bytes) orelse 1;
        if (remaining < count) {
            var plane = try bio.tiff.readRegionIndex(allocator, tiff_bytes, remaining, region);
            plane.metadata.format = "micromanager";
            plane.metadata.image_description = null;
            const parsed = parseMicroMetadata(meta_bytes);
            plane.metadata.size_z = parsed.size_z orelse plane.metadata.size_z;
            plane.metadata.size_c = parsed.size_c orelse plane.metadata.size_c;
            plane.metadata.size_t = parsed.size_t orelse plane.metadata.size_t;
            plane.metadata.dimension_order = parsed.dimension_order orelse plane.metadata.dimension_order orelse "XYZCT";
            plane.metadata.plane_count = try totalPlaneCount(allocator, io, tiffs.items);
            return plane;
        }
        remaining -= count;
    }
    return error.InvalidPlaneIndex;
}

fn findMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const name = baseName(path);
    if (isMetadataName(name)) return allocator.dupe(u8, path);

    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    const sibling = try joinPath(allocator, parent, metadata_name);
    errdefer allocator.free(sibling);
    if (existsFile(io, sibling)) return sibling;
    allocator.free(sibling);

    const prefixed = try prefixedMetadataPath(allocator, path);
    errdefer allocator.free(prefixed);
    if (existsFile(io, prefixed)) return prefixed;
    allocator.free(prefixed);
    return error.FileNotFound;
}

fn collectTiffs(allocator: std.mem.Allocator, io: std.Io, meta_path: []const u8, meta_bytes: []const u8, out: *std.ArrayList([]u8)) !void {
    const parent = try parentPath(allocator, meta_path);
    defer allocator.free(parent);
    try collectMetadataFileNames(allocator, io, parent, meta_bytes, out);
    try collectSiblingTiffs(allocator, io, parent, out);
    sortPaths(out.items);
}

fn collectMetadataFileNames(allocator: std.mem.Allocator, io: std.Io, parent: []const u8, meta_bytes: []const u8, out: *std.ArrayList([]u8)) !void {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, meta_bytes, start, "\"FileName\"")) |idx| {
        start = idx + "\"FileName\"".len;
        const colon = std.mem.indexOfScalarPos(u8, meta_bytes, start, ':') orelse break;
        var pos = colon + 1;
        while (pos < meta_bytes.len and (std.ascii.isWhitespace(meta_bytes[pos]) or meta_bytes[pos] == '[')) : (pos += 1) {}
        if (pos >= meta_bytes.len or meta_bytes[pos] != '"') continue;
        pos += 1;
        const end = std.mem.indexOfScalarPos(u8, meta_bytes, pos, '"') orelse break;
        const file_name = meta_bytes[pos..end];
        if (isTiffName(file_name)) {
            const resolved = try joinPath(allocator, parent, file_name);
            errdefer allocator.free(resolved);
            if (existsFile(io, resolved)) try appendUniquePath(allocator, out, resolved);
            allocator.free(resolved);
        }
        start = end + 1;
    }
}

fn collectSiblingTiffs(allocator: std.mem.Allocator, io: std.Io, parent: []const u8, out: *std.ArrayList([]u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !isTiffName(entry.name)) continue;
        const path = try joinPath(allocator, parent, entry.name);
        errdefer allocator.free(path);
        try appendUniquePath(allocator, out, path);
        allocator.free(path);
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

fn parseMicroMetadata(data: []const u8) MicroMetadata {
    return .{
        .size_z = findJsonU16(data, "Slices"),
        .size_c = findJsonU16(data, "Channels"),
        .size_t = findJsonU16(data, "Frames"),
        .dimension_order = if (findJsonBool(data, "SlicesFirst")) |slices_first| if (slices_first) "XYZCT" else "XYCZT" else null,
    };
}

fn findJsonU16(data: []const u8, key: []const u8) ?u16 {
    const idx = findKey(data, key) orelse return null;
    var pos = valueStart(data, idx) orelse return null;
    if (pos < data.len and data[pos] == '[') pos += 1;
    while (pos < data.len and (std.ascii.isWhitespace(data[pos]) or data[pos] == '"')) : (pos += 1) {}
    const start = pos;
    while (pos < data.len and std.ascii.isDigit(data[pos])) : (pos += 1) {}
    if (pos == start) return null;
    return std.fmt.parseUnsigned(u16, data[start..pos], 10) catch null;
}

fn findJsonBool(data: []const u8, key: []const u8) ?bool {
    const idx = findKey(data, key) orelse return null;
    var pos = valueStart(data, idx) orelse return null;
    if (pos < data.len and data[pos] == '[') pos += 1;
    while (pos < data.len and (std.ascii.isWhitespace(data[pos]) or data[pos] == '"')) : (pos += 1) {}
    if (pos <= data.len - 4 and std.ascii.eqlIgnoreCase(data[pos .. pos + 4], "true")) return true;
    if (pos <= data.len - 5 and std.ascii.eqlIgnoreCase(data[pos .. pos + 5], "false")) return false;
    return null;
}

fn findKey(data: []const u8, key: []const u8) ?usize {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, data, start, key)) |idx| {
        start = idx + key.len;
        if (idx > 0 and start < data.len and data[idx - 1] == '"' and data[start] == '"') return idx - 1;
    }
    return null;
}

fn valueStart(data: []const u8, key_index: usize) ?usize {
    const colon = std.mem.indexOfScalarPos(u8, data, key_index, ':') orelse return null;
    var pos = colon + 1;
    while (pos < data.len and std.ascii.isWhitespace(data[pos])) : (pos += 1) {}
    return pos;
}

fn isMicroManagerMetadata(data: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(data, "micro-manager") != null or std.ascii.indexOfIgnoreCase(data, "micromanager") != null;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn existsFile(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn prefixedMetadataPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    const name = baseName(path);
    const underscore = std.mem.indexOfScalar(u8, name, '_') orelse return error.FileNotFound;
    const prefixed = try std.fmt.allocPrint(allocator, "{s}_metadata.txt", .{name[0..underscore]});
    defer allocator.free(prefixed);
    return joinPath(allocator, parent, prefixed);
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

fn isMetadataName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, metadata_name) or std.ascii.endsWithIgnoreCase(name, "_metadata.txt");
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

const micro_metadata =
    "{\n" ++
    "\"Summary\": {\n" ++
    "\"MicroManagerVersion\": \"1.4.22\",\n" ++
    "\"Channels\": 1,\n" ++
    "\"Slices\": 1,\n" ++
    "\"Frames\": 1,\n" ++
    "\"SlicesFirst\": true\n" ++
    "},\n" ++
    "\"FrameKey-0-0-0\": {\n" ++
    "\"FileName\": \"img_000000000_Default_000.tif\"\n" ++
    "}\n" ++
    "}\n";

test "detects micromanager metadata" {
    try std.testing.expect(matches(micro_metadata));
    try std.testing.expect(!matches("plain metadata"));
}

test "reads micromanager metadata through tiff companion" {
    const root = "micromanager-test";
    const metadata_path = "micromanager-test/metadata.txt";
    const tiff_path = "micromanager-test/img_000000000_Default_000.tif";
    std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, metadata_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = metadata_path, .data = micro_metadata });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, metadata_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tiff_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, metadata_path);
    try std.testing.expectEqualStrings("micromanager", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqualStrings("XYZCT", metadata.dimension_order.?);
}

test "reads micromanager tiff pixels from selected metadata file" {
    const root = "micromanager-plane-test";
    const metadata_path = "micromanager-plane-test/metadata.txt";
    const tiff_path = "micromanager-plane-test/img_000000000_Default_000.tif";
    std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, metadata_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = metadata_path, .data = micro_metadata });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, metadata_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tiff_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, metadata_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("micromanager", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}

test "finds micromanager metadata from selected tiff sibling" {
    const root = "micromanager-tiff-select-test";
    const metadata_path = "micromanager-tiff-select-test/metadata.txt";
    const tiff_path = "micromanager-tiff-select-test/img_000000000_Default_000.tif";
    std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, metadata_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = metadata_path, .data = micro_metadata });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, metadata_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tiff_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, tiff_path);
    try std.testing.expectEqualStrings("micromanager", metadata.format);
}
