const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const image_description_tag = 270;
const aperio_prefix = "Aperio Image";

pub fn matches(data: []const u8) bool {
    const description = tiff.firstIfdAsciiTag(data, image_description_tag) orelse return false;
    const count = tiff.ifdCount(data) orelse return false;
    return count > 1 and std.mem.startsWith(u8, description, aperio_prefix);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    var metadata = try tiff.readMetadata(data);
    metadata.format = "svs";
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "svs";
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    var plane = try tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "svs";
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

fn appendOnePixelIfd(list: *std.ArrayList(u8), pixel_offset: u32, description_offset: ?u32, description_len: u32, next_ifd_offset: u32) !void {
    const entry_count: u16 = if (description_offset == null) 9 else 10;
    try appendU16Le(list, entry_count);
    try appendEntry(list, 256, 4, 1, 1);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, 8);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 273, 4, 1, pixel_offset);
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 1);
    if (description_offset) |offset| try appendEntry(list, image_description_tag, 2, description_len, offset);
    try appendU32Le(list, next_ifd_offset);
}

test "reads svs tagged tiff plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const first_ifd_size = 2 + 10 * 12 + 4;
    const second_ifd_offset = 8 + first_ifd_size;
    const second_ifd_size = 2 + 9 * 12 + 4;
    const description = aperio_prefix ++ "|MPP = 0.25\x00";
    const description_offset = second_ifd_offset + second_ifd_size;
    const first_pixel_offset = description_offset + description.len;
    const second_pixel_offset = first_pixel_offset + 1;

    try appendOnePixelIfd(&data, @intCast(first_pixel_offset), @intCast(description_offset), description.len, @intCast(second_ifd_offset));
    try appendOnePixelIfd(&data, @intCast(second_pixel_offset), null, 0, 0);
    try data.appendSlice(std.testing.allocator, description);
    try data.append(std.testing.allocator, 22);
    try data.append(std.testing.allocator, 33);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("svs", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("svs", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{22}, plane.data);
}

test "rejects single ifd aperio tiff" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const description = aperio_prefix ++ "\x00";
    const description_offset = 8 + ifd_size;
    const pixel_offset = description_offset + description.len;

    try appendOnePixelIfd(&data, @intCast(pixel_offset), @intCast(description_offset), description.len, 0);
    try data.appendSlice(std.testing.allocator, description);
    try data.append(std.testing.allocator, 1);

    try std.testing.expect(!matches(data.items));
}
