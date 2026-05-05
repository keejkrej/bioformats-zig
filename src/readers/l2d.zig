const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;
const magic = "LI-COR LI2D";

const Sidecar = struct {
    first_image: []const u8,
    scan_name: ?[]const u8 = null,
};

pub fn matches(data: []const u8) bool {
    return std.mem.indexOf(u8, data[0..@min(data.len, 512)], magic) != null;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "l2d") or hasExtension(path, "scn");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!matches(data)) return error.InvalidFormat;
    return error.UnsupportedVariant;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    if (!matches(data)) return error.InvalidFormat;
    if (plane_index != 0) return error.InvalidPlaneIndex;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const image = try readFirstImage(allocator, io, path);
    defer allocator.free(image);
    var metadata = try bio.tiff.readMetadata(image);
    metadata.format = "l2d";
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
    const image = try readFirstImage(allocator, io, path);
    defer allocator.free(image);
    var plane = try bio.tiff.readRegionIndex(allocator, image, plane_index, region);
    plane.metadata.format = "l2d";
    plane.metadata.image_description = null;
    return plane;
}

fn readFirstImage(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const bytes = try readFile(allocator, io, path);
    defer allocator.free(bytes);
    if (hasExtension(path, "l2d")) {
        const sidecar = try parseL2d(allocator, io, path, bytes);
        defer allocator.free(sidecar.first_image);
        const image_path = try resolveImagePath(allocator, path, sidecar);
        defer allocator.free(image_path);
        return readFile(allocator, io, image_path);
    }
    const sidecar = try parseScn(bytes);
    const image_path = try resolveImagePath(allocator, path, sidecar);
    defer allocator.free(image_path);
    return readFile(allocator, io, image_path);
}

fn parseL2d(allocator: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) !Sidecar {
    if (!matches(data)) return error.InvalidFormat;
    const scan_name = parseFirstListValue(data, "ScanNames") orelse return error.InvalidFormat;
    const scn_name = try std.fmt.allocPrint(allocator, "{s}.scn", .{scan_name});
    defer allocator.free(scn_name);
    const scan_dir = try siblingPath(allocator, path, scan_name);
    defer allocator.free(scan_dir);
    const scn_path = try joinPath(allocator, scan_dir, scn_name);
    defer allocator.free(scn_path);
    const scn_bytes = try readFile(allocator, io, scn_path);
    defer allocator.free(scn_bytes);
    var sidecar = try parseScn(scn_bytes);
    sidecar.first_image = try allocator.dupe(u8, sidecar.first_image);
    sidecar.scan_name = scan_name;
    return sidecar;
}

fn parseScn(data: []const u8) bio.ReaderError!Sidecar {
    const first_image = parseFirstListValue(data, "ImageNames") orelse return error.InvalidFormat;
    return .{ .first_image = first_image };
}

fn parseFirstListValue(data: []const u8, wanted_key: []const u8) ?[]const u8 {
    var rows = rowIterator(data);
    while (rows.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..equals], " \t");
        if (!std.ascii.eqlIgnoreCase(key, wanted_key)) continue;
        var value = std.mem.trim(u8, trimmed[equals + 1 ..], " \t");
        if (std.mem.indexOfScalar(u8, value, ',')) |comma| value = value[0..comma];
        value = std.mem.trim(u8, value, " \t");
        if (value.len != 0) return value;
    }
    return null;
}

fn resolveImagePath(allocator: std.mem.Allocator, path: []const u8, sidecar: Sidecar) ![]u8 {
    if (hasDirectory(sidecar.first_image) or isAbsolutePath(sidecar.first_image)) return allocator.dupe(u8, sidecar.first_image);
    if (sidecar.scan_name) |scan_name| {
        const scan_dir = try siblingPath(allocator, path, scan_name);
        defer allocator.free(scan_dir);
        return joinPath(allocator, scan_dir, sidecar.first_image);
    }
    return siblingPath(allocator, path, sidecar.first_image);
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn siblingPath(allocator: std.mem.Allocator, path: []const u8, name: []const u8) ![]u8 {
    if (hasDirectory(name) or isAbsolutePath(name)) return allocator.dupe(u8, name);
    const sep = lastSeparator(path) orelse return allocator.dupe(u8, name);
    const out = try allocator.alloc(u8, sep + 1 + name.len);
    @memcpy(out[0 .. sep + 1], path[0 .. sep + 1]);
    @memcpy(out[sep + 1 ..], name);
    return out;
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

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

const RowIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *RowIterator) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '\n' and self.data[self.pos] != '\r') : (self.pos += 1) {}
        const end = self.pos;
        while (self.pos < self.data.len and (self.data[self.pos] == '\n' or self.data[self.pos] == '\r')) : (self.pos += 1) {}
        return self.data[start..end];
    }
};

fn rowIterator(data: []const u8) RowIterator {
    return .{ .data = data };
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

test "parses first l2d scan and image names" {
    const root = "LI-COR LI2D\nScanNames=scanA, scanB\n";
    try std.testing.expect(matches(root));
    const name = parseFirstListValue(root, "ScanNames") orelse return error.InvalidFormat;
    try std.testing.expectEqualStrings("scanA", name);
    const scn = "ImageNames=ch1.tif, ch2.tif\n";
    const parsed = try parseScn(scn);
    try std.testing.expectEqualStrings("ch1.tif", parsed.first_image);
}

test "reads l2d scn metadata through first tiff" {
    const scn_path = "l2d-scan-test.scn";
    const image_path = "l2d-scan-test.tif";
    const scn = "ImageNames=l2d-scan-test.tif\n";
    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(std.testing.allocator);
    try appendTinyTiff(&image, 42);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = scn_path, .data = scn });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, scn_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = image.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, scn_path);
    try std.testing.expectEqualStrings("l2d", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
}

test "reads l2d root pixels through scan directory" {
    const root_path = "l2d-root-test.l2d";
    const scan_dir = "l2d-root-scan";
    const scn_path = "l2d-root-scan/l2d-root-scan.scn";
    const image_path = "l2d-root-scan/ch1.tif";
    const root = "LI-COR LI2D\nScanNames=l2d-root-scan\n";
    const scn = "ImageNames=ch1.tif\n";
    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(std.testing.allocator);
    try appendTinyTiff(&image, 77);

    std.Io.Dir.cwd().deleteFile(std.testing.io, root_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, scn_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, scan_dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, scan_dir, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, scan_dir) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_path, .data = root });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, root_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = scn_path, .data = scn });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, scn_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = image.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, root_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("l2d", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}
