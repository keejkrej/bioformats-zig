const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const max_companion_bytes = 512 * 1024 * 1024;
const software_tag = 305;
const software_prefix = "MATROX Imaging Library";

pub fn matches(data: []const u8) bool {
    const software = tiff.firstIfdAsciiTag(data, software_tag) orelse return false;
    return std.mem.startsWith(u8, std.mem.trim(u8, software, " \t\r\n"), software_prefix);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "exp");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    var metadata = try tiff.readMetadata(data);
    metadata.format = "bdpathway";
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "bdpathway";
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    var plane = try tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "bdpathway";
    return plane;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const image = try readFirstImage(allocator, io, path);
    defer allocator.free(image);
    var metadata = try tiff.readMetadata(image);
    metadata.format = "bdpathway";
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
    var plane = try tiff.readRegionIndex(allocator, image, plane_index, region);
    plane.metadata.format = "bdpathway";
    plane.metadata.image_description = null;
    return plane;
}

fn readFirstImage(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (!isPath(path)) return error.InvalidFormat;
    const root = try parentPath(allocator, path);
    defer allocator.free(root);
    const image_path = try findFirstTiff(allocator, io, root);
    defer allocator.free(image_path);
    return readFile(allocator, io, image_path);
}

fn findFirstTiff(allocator: std.mem.Allocator, io: std.Io, root: []const u8) ![]u8 {
    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer root_dir.close(io);

    var iter = root_dir.iterate();
    var first_dir: ?[]u8 = null;
    defer if (first_dir) |dir| allocator.free(dir);

    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and isTiffName(entry.name)) {
            return joinPath(allocator, root, entry.name);
        }
        if (entry.kind == .directory and first_dir == null and std.mem.startsWith(u8, entry.name, "Well ")) {
            first_dir = try allocator.dupe(u8, entry.name);
        }
    }

    const well = first_dir orelse return error.FileNotFound;
    const well_path = try joinPath(allocator, root, well);
    defer allocator.free(well_path);
    var well_dir = try std.Io.Dir.cwd().openDir(io, well_path, .{ .iterate = true });
    defer well_dir.close(io);

    var well_iter = well_dir.iterate();
    while (try well_iter.next(io)) |entry| {
        if (entry.kind == .file and isTiffName(entry.name)) {
            return joinPath(allocator, well_path, entry.name);
        }
    }
    return error.FileNotFound;
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

test "reads bd pathway tagged tiff plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const software = "  MATROX Imaging Library 8.0\x00";
    const software_offset = ifd_end;
    const pixel_offset = software_offset + software.len;

    try appendU16Le(&data, entry_count);
    try appendEntry(&data, 256, 4, 1, 1);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 1, 8);
    try appendEntry(&data, 259, 3, 1, 1);
    try appendEntry(&data, 262, 3, 1, 1);
    try appendEntry(&data, 273, 4, 1, @intCast(pixel_offset));
    try appendEntry(&data, 277, 3, 1, 1);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 1, 1);
    try appendEntry(&data, software_tag, 2, software.len, @intCast(software_offset));
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, software);
    try data.append(std.testing.allocator, 99);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("bdpathway", metadata.format);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("bdpathway", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{99}, plane.data);
}

test "reads bd pathway experiment through well tiff" {
    const root_dir = "bdpathway-exp-test";
    const well_dir = "bdpathway-exp-test/Well A1";
    const exp_path = "bdpathway-exp-test/Experiment.exp";
    const image_path = "bdpathway-exp-test/Well A1/DAPI - n000000.tif";
    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(std.testing.allocator);
    try appendTinyTiff(&image, 77);

    std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, exp_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, well_dir) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root_dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root_dir, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root_dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, well_dir, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, well_dir) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = exp_path, .data = "[Image]\nMontaged=0\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exp_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = image.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, exp_path);
    try std.testing.expectEqualStrings("bdpathway", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, exp_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("bdpathway", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}
