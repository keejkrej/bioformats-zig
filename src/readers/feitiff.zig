const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const sfeg_tag = 34680;
const helios_tag = 34682;
const titan_tag = 34683;

pub fn matches(data: []const u8) bool {
    return tiff.containsTag(data, sfeg_tag) or
        tiff.containsTag(data, helios_tag) or
        tiff.containsTag(data, titan_tag);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    var metadata = try tiff.readMetadata(data);
    metadata.format = "feitiff";
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "feitiff";
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    var plane = try tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "feitiff";
    return plane;
}

test "reads fei-tagged tiff plane" {
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
        0,   0,   1,  0, 0, 0, 120, 135,
        2,   0,   4,  0, 0, 0, 'f', 'e',
        'i', 0,   0,  0, 0, 0, 77,
    };

    try std.testing.expect(matches(&data));
    const metadata = try readMetadata(&data);
    try std.testing.expectEqualStrings("feitiff", metadata.format);

    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("feitiff", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}
