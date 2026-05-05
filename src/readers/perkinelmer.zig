const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

const ParsedHtml = struct {
    size_z: ?u16 = null,
    size_c: ?u16 = null,
    size_t: ?u16 = null,
};

pub fn matches(data: []const u8) bool {
    return isPerkinElmerHtml(data);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "htm") or
        hasExtension(path, "html") or
        hasExtension(path, "tif") or
        hasExtension(path, "tiff") or
        hasExtension(path, "tim") or
        hasExtension(path, "ano") or
        hasExtension(path, "cfg") or
        hasExtension(path, "csv") or
        hasExtension(path, "rec") or
        hasExtension(path, "zpo") or
        hasNumericExtension(path);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!isPerkinElmerHtml(data)) return error.InvalidFormat;
    return error.UnsupportedVariant;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const html_path = try findHtmlPath(allocator, io, path);
    defer allocator.free(html_path);
    const html = try readFile(allocator, io, html_path);
    defer allocator.free(html);
    if (!isPerkinElmerHtml(html)) return error.InvalidFormat;

    var tiffs: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &tiffs);
    try collectTiffs(allocator, io, html_path, &tiffs);
    if (tiffs.items.len == 0) return error.FileNotFound;

    const first = try readFile(allocator, io, tiffs.items[0]);
    defer allocator.free(first);
    var metadata = try bio.tiff.readMetadata(first);
    metadata.format = "perkinelmer";
    metadata.image_description = null;
    metadata.plane_count = try totalPlaneCount(allocator, io, tiffs.items);

    const parsed = parseHtml(html);
    metadata.size_z = parsed.size_z orelse metadata.size_z;
    metadata.size_c = parsed.size_c orelse metadata.size_c;
    metadata.size_t = parsed.size_t orelse metadata.size_t;
    if (metadata.size_z == 0) metadata.size_z = 1;
    if (metadata.size_c == 0) metadata.size_c = 1;
    if (metadata.size_t == 0) {
        const zc = @as(u32, metadata.size_z) * @as(u32, metadata.size_c);
        metadata.size_t = if (zc == 0) 1 else @intCast(@max(@as(u32, 1), metadata.plane_count / zc));
    }
    metadata.dimension_order = "XYCTZ";
    return metadata;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const html_path = try findHtmlPath(allocator, io, path);
    defer allocator.free(html_path);
    const html = try readFile(allocator, io, html_path);
    defer allocator.free(html);
    if (!isPerkinElmerHtml(html)) return error.InvalidFormat;

    var tiffs: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &tiffs);
    try collectTiffs(allocator, io, html_path, &tiffs);

    var remaining = plane_index;
    for (tiffs.items) |tiff_path| {
        const tiff = try readFile(allocator, io, tiff_path);
        defer allocator.free(tiff);
        const count = bio.tiff.ifdCount(tiff) orelse 1;
        if (remaining < count) {
            var plane = try bio.tiff.readRegionIndex(allocator, tiff, remaining, region);
            plane.metadata.format = "perkinelmer";
            plane.metadata.image_description = null;
            const parsed = parseHtml(html);
            plane.metadata.size_z = parsed.size_z orelse plane.metadata.size_z;
            plane.metadata.size_c = parsed.size_c orelse plane.metadata.size_c;
            plane.metadata.size_t = parsed.size_t orelse plane.metadata.size_t;
            plane.metadata.plane_count = try totalPlaneCount(allocator, io, tiffs.items);
            plane.metadata.dimension_order = "XYCTZ";
            return plane;
        }
        remaining -= count;
    }
    return error.InvalidPlaneIndex;
}

fn findHtmlPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "htm") or hasExtension(path, "html")) return allocator.dupe(u8, path);
    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    const selected_stem = stem(baseName(path));

    var first_html: ?[]u8 = null;
    errdefer if (first_html) |owned| allocator.free(owned);
    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !(hasExtension(entry.name, "htm") or hasExtension(entry.name, "html"))) continue;
        const candidate = try joinPath(allocator, parent, entry.name);
        errdefer allocator.free(candidate);
        if (first_html == null) first_html = try allocator.dupe(u8, candidate);
        const html_stem = stem(entry.name);
        if (std.mem.startsWith(u8, selected_stem, html_stem) or std.mem.startsWith(u8, html_stem, selected_stem)) {
            if (first_html) |owned| allocator.free(owned);
            return candidate;
        }
        allocator.free(candidate);
    }
    if (first_html) |owned| return owned;
    return error.FileNotFound;
}

fn collectTiffs(allocator: std.mem.Allocator, io: std.Io, html_path: []const u8, out: *std.ArrayList([]u8)) !void {
    const parent = try parentPath(allocator, html_path);
    defer allocator.free(parent);
    const html_stem = stem(baseName(html_path));
    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !isTiffName(entry.name)) continue;
        const entry_stem = stem(entry.name);
        if (!std.mem.startsWith(u8, entry_stem, html_stem) and !std.mem.startsWith(u8, html_stem, entry_stem)) continue;
        const path = try joinPath(allocator, parent, entry.name);
        errdefer allocator.free(path);
        try appendUniquePath(allocator, out, path);
        allocator.free(path);
    }
    sortPaths(out.items);
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

fn parseHtml(data: []const u8) ParsedHtml {
    var parsed = ParsedHtml{};
    if (std.ascii.indexOfIgnoreCase(data, "Experiment details")) |idx| {
        const end = @min(data.len, idx + 512);
        parseDetails(data[idx..end], &parsed);
    }
    parsed.size_z = parsed.size_z orelse findNumberBeforeWord(data, "Slices");
    parsed.size_c = parsed.size_c orelse findNumberBeforeWord(data, "Wavelengths");
    parsed.size_t = parsed.size_t orelse findNumberBeforeWord(data, "Frames");
    return parsed;
}

fn parseDetails(text: []const u8, parsed: *ParsedHtml) void {
    parsed.size_c = parsed.size_c orelse findNumberBeforeWord(text, "Wavelengths");
    parsed.size_t = parsed.size_t orelse findNumberBeforeWord(text, "Frames");
    parsed.size_z = parsed.size_z orelse findNumberBeforeWord(text, "Slices");
}

fn findNumberBeforeWord(data: []const u8, word: []const u8) ?u16 {
    const word_index = std.ascii.indexOfIgnoreCase(data, word) orelse return null;
    var end = word_index;
    while (end > 0 and !std.ascii.isDigit(data[end - 1])) : (end -= 1) {}
    var start = end;
    while (start > 0 and std.ascii.isDigit(data[start - 1])) : (start -= 1) {}
    if (start == end) return null;
    return std.fmt.parseUnsigned(u16, data[start..end], 10) catch null;
}

fn isPerkinElmerHtml(data: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(data, "PerkinElmer") != null or
        std.ascii.indexOfIgnoreCase(data, "Perkin Elmer") != null or
        std.ascii.indexOfIgnoreCase(data, "Ultraview") != null or
        (std.ascii.indexOfIgnoreCase(data, "Experiment details") != null and
            (std.ascii.indexOfIgnoreCase(data, "Wavelengths") != null or std.ascii.indexOfIgnoreCase(data, "Frames") != null));
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

fn stem(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot];
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

fn hasNumericExtension(path: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const ext = path[dot + 1 ..];
    if (ext.len == 0 or ext.len > 8) return false;
    _ = std.fmt.parseUnsigned(u32, ext, 16) catch return false;
    return true;
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

const html_fixture =
    "<HTML><body><p>PerkinElmer Ultraview</p>" ++
    "<p>Experiment details:</p><p>1 Wavelengths 1 Frames 1 Slices</p>" ++
    "</body></HTML>";

test "detects perkinelmer html metadata" {
    try std.testing.expect(matches(html_fixture));
    try std.testing.expect(!matches("<html>plain</html>"));
}

test "reads perkinelmer tiff-backed metadata" {
    const root = "perkinelmer-test";
    const html_path = "perkinelmer-test/sample.htm";
    const tiff_path = "perkinelmer-test/sample_00000000_001.tif";
    std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, html_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = html_path, .data = html_fixture });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, html_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tiff_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, html_path);
    try std.testing.expectEqualStrings("perkinelmer", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqualStrings("XYCTZ", metadata.dimension_order.?);
}

test "reads perkinelmer delegated tiff pixels from selected tiff" {
    const root = "perkinelmer-plane-test";
    const html_path = "perkinelmer-plane-test/sample.htm";
    const tiff_path = "perkinelmer-plane-test/sample_00000000_001.tif";
    std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, html_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = html_path, .data = html_fixture });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, html_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tiff_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, tiff_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("perkinelmer", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}
