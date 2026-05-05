const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const xml_tag = 50457;

pub fn matches(data: []const u8) bool {
    return tiff.containsTag(data, xml_tag);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    var metadata = try tiff.readMetadata(data);
    metadata.format = "imacon";
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "imacon";
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    var plane = try tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "imacon";
    return plane;
}

test "reads imacon tagged tiff plane" {
    const data = [_]u8{
        'I', 'I', 42, 0, 8, 0, 0,   0,
        10,  0,   0,  1, 4, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 1,   1,
        4,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   2,  1, 3, 0, 1,   0,
        0,   0,   8,  0, 0, 0, 3,   1,
        3,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   6,  1, 3, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 17,  1,
        4,   0,   1,  0, 0, 0, 134, 0,
        0,   0,   21, 1, 3, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 22,  1,
        4,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   23, 1, 4, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 25,  197,
        2,   0,   4,  0, 0, 0, '<', 'i',
        '>', 0,   0,  0, 0, 0, 33,
    };

    try std.testing.expect(matches(&data));
    const metadata = try readMetadata(&data);
    try std.testing.expectEqualStrings("imacon", metadata.format);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("imacon", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{33}, plane.data);
}
