const std = @import("std");
const bio = @import("../root.zig");

const max_image_bytes = 512 * 1024 * 1024;

pub fn matches(data: []const u8) bool {
    _ = data;
    return false;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "jpg") or hasExtension(path, "jpeg");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    return bio.jpeg.readMetadataAs(data, "tilejpeg");
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const data = try readFile(allocator, io, path);
    defer allocator.free(data);
    return readMetadata(data);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    return bio.jpeg.readPlaneIndexAs(allocator, data, plane_index, "tilejpeg");
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const data = try readFile(allocator, io, path);
    defer allocator.free(data);
    const plane = try readPlaneIndex(allocator, data, plane_index);
    errdefer allocator.free(plane.data);
    try region.validate(plane.metadata);
    if (region.isFull(plane.metadata)) return plane;
    defer allocator.free(plane.data);
    return .{
        .metadata = plane.metadata,
        .data = try bio.cropPlane(allocator, plane, region),
    };
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_image_bytes));
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

const tiny_rgb_jpeg = [_]u8{
    0xff, 0xd8,
    0xff, 0xc0,
    0x00, 0x11,
    0x08, 0x00,
    0x02, 0x00,
    0x03, 0x03,
    0x01, 0x11,
    0x00, 0x02,
    0x11, 0x00,
    0x03, 0x11,
    0x00, 0xff,
    0xd9,
};

test "reports jpeg metadata as tilejpeg for path-backed reader" {
    const metadata = try readMetadata(&tiny_rgb_jpeg);
    try std.testing.expectEqualStrings("tilejpeg", metadata.format);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
}

test "rejects non-jpeg data" {
    try std.testing.expectError(error.InvalidFormat, readMetadata("not jpeg"));
}
