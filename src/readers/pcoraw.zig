const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

pub fn matches(data: []const u8) bool {
    _ = data;
    return false;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "pcoraw") or hasExtension(path, "rec");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    _ = data;
    return error.InvalidFormat;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.InvalidFormat;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const image = try readImageFile(allocator, io, path);
    defer allocator.free(image);

    var metadata = try bio.tiff.readMetadata(image);
    metadata.format = "pcoraw";
    metadata.image_description = null;
    metadata.dimension_order = null;
    return metadata;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const image = try readImageFile(allocator, io, path);
    defer allocator.free(image);

    var plane = try bio.tiff.readRegionIndex(allocator, image, plane_index, region);
    plane.metadata.format = "pcoraw";
    plane.metadata.image_description = null;
    plane.metadata.dimension_order = null;
    return plane;
}

fn readImageFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "pcoraw")) return readFile(allocator, io, path);

    const lower = try replaceExtension(allocator, path, ".pcoraw");
    defer allocator.free(lower);
    return readFile(allocator, io, lower) catch |lower_err| {
        const upper = try replaceExtension(allocator, path, ".PCORAW");
        defer allocator.free(upper);
        return readFile(allocator, io, upper) catch lower_err;
    };
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    const out = try allocator.alloc(u8, dot + extension.len);
    @memcpy(out[0..dot], path[0..dot]);
    @memcpy(out[dot..], extension);
    return out;
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

const tiny_tiff = [_]u8{
    'I', 'I', 42, 0, 8, 0, 0,   0,
    9,   0,   0,  1, 4, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 1,   1,
    4,   0,   1,  0, 0, 0, 1,   0,
    0,   0,   2,  1, 3, 0, 1,   0,
    0,   0,   8,  0, 0, 0, 3,   1,
    3,   0,   1,  0, 0, 0, 1,   0,
    0,   0,   6,  1, 3, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 17,  1,
    4,   0,   1,  0, 0, 0, 122, 0,
    0,   0,   21, 1, 3, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 22,  1,
    4,   0,   1,  0, 0, 0, 1,   0,
    0,   0,   23, 1, 4, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 0,   0,
    0,   0,   77,
};

test "reads pcoraw metadata through tiff delegate" {
    const image_path = "pcoraw-test.pcoraw";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, image_path);
    try std.testing.expectEqualStrings("pcoraw", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
}

test "opens pcoraw from rec sidecar and reads pixels" {
    const rec_path = "pcoraw-sidecar-test.rec";
    const image_path = "pcoraw-sidecar-test.pcoraw";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rec_path, .data = "Exposure / Delay: 10 ms\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, rec_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, rec_path, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("pcoraw", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}
