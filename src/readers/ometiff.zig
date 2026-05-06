const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const image_description_tag = 270;

pub fn matches(data: []const u8) bool {
    const description = tiff.firstIfdAsciiTag(data, image_description_tag) orelse return false;
    const trimmed = std.mem.trim(u8, description, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '<' or trimmed[trimmed.len - 1] != '>') return false;
    return std.mem.indexOf(u8, trimmed, "<OME") != null;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    var metadata = try tiff.readMetadata(data);
    metadata.format = "ometiff";
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "ometiff";
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    var plane = try tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "ometiff";
    return plane;
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

test "reads ome-tiff tagged plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const description =
        \\<OME><Image ID="Image:0"><Pixels DimensionOrder="XYZCT" Type="uint8" SizeX="1" SizeY="1" SizeZ="1" SizeC="1" SizeT="1"/></Image></OME>
    ++ "\x00";
    const description_offset = ifd_end;
    const pixel_offset = description_offset + description.len;

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
    try appendEntry(&data, image_description_tag, 2, description.len, @intCast(description_offset));
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, description);
    try data.append(std.testing.allocator, 17);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("ometiff", metadata.format);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("ometiff", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{17}, plane.data);
}

test "rejects non-xml tiff description" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);
    const entry_count = 1;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const description = "not xml OME\x00";
    try appendU16Le(&data, entry_count);
    try appendEntry(&data, image_description_tag, 2, description.len, @intCast(ifd_end));
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, description);

    try std.testing.expect(!matches(data.items));
}

test "matches Bio-Formats core metadata for cached OME-TIFF fixture" {
    const file_path = "fixtures/cache/ometiff/Iron-Plate.ome.tiff";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("ometiff", metadata.format);
    try std.testing.expectEqual(@as(u32, 576), metadata.width);
    try std.testing.expectEqual(@as(u32, 472), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 3), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 1), metadata.series_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);
    try std.testing.expectEqualStrings("XYCTZ", metadata.dimension_order.?);
}

test "matches Bio-Formats plane hashes for cached OME-TIFF fixture" {
    const file_path = "fixtures/cache/ometiff/Iron-Plate.ome.tiff";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const expected = [_]struct { plane: u32, sha256: [32]u8 }{
        .{ .plane = 0, .sha256 = .{ 0x50, 0x4e, 0xd6, 0xe2, 0xf7, 0xf1, 0x0c, 0x2c, 0x06, 0x4d, 0xc4, 0x5c, 0xcf, 0x09, 0x05, 0xa8, 0x3c, 0x1c, 0x36, 0x4b, 0x81, 0x60, 0x57, 0x40, 0xd8, 0x25, 0xc8, 0xe5, 0xe5, 0x7c, 0x34, 0xc0 } },
        .{ .plane = 1, .sha256 = .{ 0x1e, 0x86, 0x28, 0xd0, 0x52, 0x17, 0xf8, 0x9c, 0xe8, 0x4a, 0x21, 0x89, 0x96, 0x01, 0x55, 0x56, 0x67, 0x7b, 0x30, 0x00, 0x5b, 0xa8, 0x65, 0x36, 0x58, 0x09, 0x15, 0x06, 0x9e, 0x3b, 0x54, 0x85 } },
        .{ .plane = 2, .sha256 = .{ 0xb9, 0xa7, 0x65, 0x33, 0x1b, 0x5f, 0x73, 0xd7, 0xae, 0xae, 0xce, 0xc4, 0x6d, 0xdf, 0x3f, 0x4c, 0x20, 0xaa, 0xf8, 0x52, 0xa0, 0xe0, 0x23, 0xff, 0xd3, 0xc5, 0xf5, 0xcd, 0x79, 0x1a, 0xd6, 0x44 } },
    };
    for (expected) |sample| {
        const plane = try readPlaneIndex(std.testing.allocator, data, sample.plane);
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqual(@as(usize, 271872), plane.data.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
        try std.testing.expectEqualSlices(u8, &sample.sha256, &digest);
    }
}
