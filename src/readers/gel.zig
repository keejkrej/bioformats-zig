const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const md_file_tag = 33445;
const square_root = 2;
const linear = 128;

pub fn matches(data: []const u8) bool {
    const count = tiff.ifdCount(data) orelse return false;
    if (count == 0 or count > 2) return false;
    return tiff.firstIfdContainsTag(data, md_file_tag);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    try ensureSupportedVariant(data);
    var metadata = try tiff.readMetadata(data);
    metadata.format = "gel";
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    try ensureSupportedVariant(data);
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "gel";
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    try ensureSupportedVariant(data);
    var plane = try tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "gel";
    return plane;
}

fn ensureSupportedVariant(data: []const u8) bio.ReaderError!void {
    if (!matches(data)) return error.InvalidFormat;
    if ((tiff.ifdCount(data) orelse return error.InvalidFormat) != 1) return error.UnsupportedVariant;
    const fmt = tiff.firstIfdUnsignedTag(data, md_file_tag) orelse linear;
    if (fmt == square_root) return error.UnsupportedVariant;
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

test "reads linear gel tagged tiff plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const pixel_offset = ifd_end;

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
    try appendEntry(&data, md_file_tag, 4, 1, linear);
    try appendU32Le(&data, 0);
    try data.append(std.testing.allocator, 45);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("gel", metadata.format);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("gel", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{45}, plane.data);
}

test "rejects square-root gel variant" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;

    try appendU16Le(&data, entry_count);
    try appendEntry(&data, 256, 4, 1, 1);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 1, 8);
    try appendEntry(&data, 259, 3, 1, 1);
    try appendEntry(&data, 262, 3, 1, 1);
    try appendEntry(&data, 273, 4, 1, @intCast(ifd_end));
    try appendEntry(&data, 277, 3, 1, 1);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 1, 1);
    try appendEntry(&data, md_file_tag, 4, 1, square_root);
    try appendU32Le(&data, 0);
    try data.append(std.testing.allocator, 1);

    try std.testing.expect(matches(data.items));
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}
