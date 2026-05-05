const std = @import("std");
const bio = @import("../root.zig");

const max_image_bytes = 512 * 1024 * 1024;

pub fn matches(data: []const u8) bool {
    _ = data;
    return false;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "jpx");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    return bio.jpeg2000.readMetadataAs(data, "jpx");
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const data = try readFile(allocator, io, path);
    defer allocator.free(data);
    return readMetadata(data);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    _ = allocator;
    _ = io;
    _ = path;
    _ = plane_index;
    _ = region;
    return error.UnsupportedVariant;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_image_bytes));
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

test "reports jpeg2000 metadata as jpx" {
    const raw = [_]u8{
        0xff, 0x4f,
        0xff, 0x51,
        0x00, 0x29,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x09,
        0x00, 0x00,
        0x00, 0x08,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x09,
        0x00, 0x00,
        0x00, 0x08,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x01,
        0x07, 0x01,
        0x01, 0xff,
        0xd9,
    };
    const metadata = try readMetadata(&raw);
    try std.testing.expectEqualStrings("jpx", metadata.format);
    try std.testing.expectEqual(@as(u32, 9), metadata.width);
    try std.testing.expectEqual(@as(u32, 8), metadata.height);
}
