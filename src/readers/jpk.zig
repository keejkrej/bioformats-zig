const std = @import("std");
const bio = @import("../root.zig");

const max_image_bytes = 512 * 1024 * 1024;

pub fn matches(data: []const u8) bool {
    _ = data;
    return false;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "jpk");
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
    const bytes = try readFile(allocator, io, path);
    defer allocator.free(bytes);

    var metadata = try bio.tiff.readMetadata(bytes);
    metadata.format = "jpk";
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
    const bytes = try readFile(allocator, io, path);
    defer allocator.free(bytes);

    var plane = try bio.tiff.readRegionIndex(allocator, bytes, plane_index, region);
    plane.metadata.format = "jpk";
    plane.metadata.image_description = null;
    return plane;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_image_bytes));
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

test "reads jpk path metadata through tiff delegate" {
    const path = "jpk-test.jpk";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, path);
    try std.testing.expectEqualStrings("jpk", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
}

test "reads jpk path pixels through tiff delegate" {
    const path = "jpk-plane-test.jpk";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, path, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("jpk", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}
