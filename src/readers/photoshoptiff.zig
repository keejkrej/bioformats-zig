const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const image_source_data_tag = 37724;

pub fn matches(data: []const u8) bool {
    return tiff.containsTag(data, image_source_data_tag);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    var metadata = try tiff.readMetadata(data);
    metadata.format = "photoshoptiff";
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "photoshoptiff";
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    var plane = try tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "photoshoptiff";
    return plane;
}

test "reads photoshop tagged tiff plane" {
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
        0,   0,   1,  0, 0, 0, 92,  147,
        1,   0,   4,  0, 0, 0, '8', 'B',
        'I', 'M', 0,  0, 0, 0, 128,
    };

    try std.testing.expect(matches(&data));
    const metadata = try readMetadata(&data);
    try std.testing.expectEqualStrings("photoshoptiff", metadata.format);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("photoshoptiff", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{128}, plane.data);
}
