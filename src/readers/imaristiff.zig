const std = @import("std");
const bio = @import("../root.zig");

const max_image_bytes = 512 * 1024 * 1024;

pub fn matches(data: []const u8) bool {
    _ = data;
    return false;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "ims");
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

    return readMetadataFromBytes(bytes);
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

    const layout = try readLayout(bytes);
    if (plane_index >= layout.metadata.plane_count) return error.InvalidPlaneIndex;
    if (layout.metadata.size_z != 1) return error.UnsupportedVariant;

    const ifd_index = layout.first_stack_ifd + plane_index;
    var plane = try bio.tiff.readRegionAtIndexAs(allocator, bytes, ifd_index, layout.metadata, region);
    plane.metadata.format = "imaristiff";
    plane.metadata.image_description = null;
    return plane;
}

const Layout = struct {
    first_stack_ifd: u32,
    metadata: bio.Metadata,
};

fn readMetadataFromBytes(data: []const u8) !bio.Metadata {
    const layout = try readLayout(data);
    return layout.metadata;
}

fn readLayout(data: []const u8) !Layout {
    const ifd_count = bio.tiff.ifdCount(data) orelse return error.InvalidFormat;
    if (ifd_count == 0) return error.InvalidFormat;

    const first_stack_ifd: u32 = if (ifd_count > 1) 1 else 0;
    const stack_ifds = ifd_count - first_stack_ifd;
    if (stack_ifds == 0 or stack_ifds > std.math.maxInt(u16)) return error.UnsupportedVariant;

    var total_blocks: u32 = 0;
    var i: u32 = 0;
    while (i < stack_ifds) : (i += 1) {
        total_blocks = std.math.add(u32, total_blocks, try bio.tiff.blockCountAtIndex(data, first_stack_ifd + i)) catch return error.UnsupportedVariant;
    }
    if (total_blocks == 0 or total_blocks % stack_ifds != 0) return error.UnsupportedVariant;

    var metadata = try bio.tiff.readMetadataAtIndex(data, first_stack_ifd, total_blocks);
    metadata.format = "imaristiff";
    metadata.image_description = null;
    metadata.dimension_order = "XYZCT";
    metadata.size_c = @intCast(stack_ifds);
    metadata.size_z = @intCast(total_blocks / stack_ifds);
    metadata.size_t = 1;
    metadata.plane_count = total_blocks;
    return .{ .first_stack_ifd = first_stack_ifd, .metadata = metadata };
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

test "reads imaris tiff path metadata through tiff delegate" {
    const path = "imaristiff-test.ims";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, path);
    try std.testing.expectEqualStrings("imaristiff", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
}

test "reads imaris tiff path pixels through tiff delegate" {
    const path = "imaristiff-plane-test.ims";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, path, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("imaristiff", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}

test "matches Bio-Formats default metadata for cached Imaris TIFF fixture" {
    const file_path = "fixtures/cache/imaristiff/Convallaria_3C_10T_confocal_IMS3.ims";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    try std.testing.expectEqualStrings("imaristiff", metadata.format);
    try std.testing.expectEqual(@as(u32, 1024), metadata.width);
    try std.testing.expectEqual(@as(u32, 1024), metadata.height);
    try std.testing.expectEqual(@as(u16, 30), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 30), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 1), metadata.series_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYZCT", metadata.dimension_order.?);
}

test "matches Bio-Formats default plane and region hashes for cached Imaris TIFF fixture" {
    const file_path = "fixtures/cache/imaristiff/Convallaria_3C_10T_confocal_IMS3.ims";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const expected = [_]struct { plane: u32, sha256: [32]u8 }{
        .{ .plane = 0, .sha256 = .{ 0x60, 0x23, 0xa7, 0xef, 0xcf, 0xc7, 0x49, 0x87, 0x58, 0x23, 0x2b, 0x7d, 0x67, 0xb9, 0x4d, 0xd3, 0x66, 0x7f, 0x31, 0xed, 0x31, 0x37, 0xb4, 0x9d, 0x26, 0xf3, 0xe2, 0x71, 0x6a, 0x80, 0xf4, 0xf6 } },
        .{ .plane = 15, .sha256 = .{ 0x82, 0x7c, 0x1c, 0x7e, 0x9e, 0x68, 0x4f, 0xb2, 0x2d, 0x75, 0x24, 0x0a, 0xe3, 0x2b, 0xee, 0x65, 0x27, 0x7a, 0x0c, 0x16, 0x6e, 0xc0, 0x2e, 0x11, 0x6f, 0xd5, 0x76, 0xf7, 0xd5, 0xc4, 0x58, 0x85 } },
        .{ .plane = 29, .sha256 = .{ 0x10, 0xfa, 0xba, 0x0e, 0x1a, 0x27, 0x78, 0x93, 0xbe, 0x6c, 0x33, 0xa1, 0xc7, 0x9c, 0x4a, 0x86, 0xbd, 0xd2, 0xe6, 0x05, 0xf6, 0xae, 0xe6, 0x36, 0x98, 0x63, 0xca, 0x11, 0x06, 0xf3, 0x3a, 0xa2 } },
    };
    for (expected) |sample| {
        const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, sample.plane, .{
            .x = 0,
            .y = 0,
            .width = 1024,
            .height = 1024,
        });
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqual(@as(usize, 2097152), plane.data.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
        try std.testing.expectEqualSlices(u8, &sample.sha256, &digest);
    }

    const region = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{
        .x = 17,
        .y = 19,
        .width = 16,
        .height = 12,
    });
    defer std.testing.allocator.free(region.data);
    try std.testing.expectEqual(@as(usize, 384), region.data.len);
    const expected_region: [32]u8 = .{ 0x22, 0x59, 0xf5, 0xe4, 0x9b, 0x63, 0x8e, 0x35, 0x7a, 0x5f, 0xa8, 0x5f, 0xdd, 0xf5, 0xfa, 0x13, 0x42, 0x6d, 0x9b, 0x91, 0x40, 0x3e, 0x2f, 0x80, 0x71, 0xe9, 0xa9, 0x65, 0x41, 0xc7, 0x67, 0x95 };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(region.data, &digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_region, &digest);
}
