const std = @import("std");
const bio = @import("../root.zig");

const max_image_bytes = 512 * 1024 * 1024;
const header_len = 1024;
const ext_header_size_offset = 92;
const endian_marker_offset = 96;
const time_count_offset = 180;
const sequence_offset = 182;
const channel_count_offset = 196;

pub fn matches(data: []const u8) bool {
    _ = data;
    return false;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "rcpnl");
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

    var metadata = try bio.deltavision.readMetadata(bytes);
    metadata.format = "rcpnl";
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

    var plane = try bio.readPlaneRegionIndex(allocator, bytes, plane_index, region);
    plane.metadata.format = "rcpnl";
    return plane;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_image_bytes));
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn appendHeader(list: *std.ArrayList(u8), width: i32, height: i32, planes: i32, pixel_type: i32, ext_header_size: i32, size_t: u16, size_c: u16, sequence: u16) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_len);
    std.mem.writeInt(i32, list.items[0..4], width, .little);
    std.mem.writeInt(i32, list.items[4..8], height, .little);
    std.mem.writeInt(i32, list.items[8..12], planes, .little);
    std.mem.writeInt(i32, list.items[12..16], pixel_type, .little);
    std.mem.writeInt(i32, list.items[ext_header_size_offset..][0..4], ext_header_size, .little);
    std.mem.writeInt(i16, list.items[endian_marker_offset..][0..2], -16224, .little);
    std.mem.writeInt(u16, list.items[time_count_offset..][0..2], size_t, .little);
    std.mem.writeInt(u16, list.items[sequence_offset..][0..2], sequence, .little);
    std.mem.writeInt(u16, list.items[channel_count_offset..][0..2], size_c, .little);
}

test "reads rcpnl path metadata through deltavision delegate" {
    const path = "rcpnl-test.rcpnl";
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 2, 1, 6, 0, 1, 1, 0);
    try data.appendSlice(std.testing.allocator, &.{
        1, 0, 2, 0, 3, 0, 4, 0,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = data.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, path);
    try std.testing.expectEqualStrings("rcpnl", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
}

test "reads rcpnl path pixels with deltavision row flip" {
    const path = "rcpnl-plane-test.rcpnl";
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 2, 1, 6, 0, 1, 1, 0);
    try data.appendSlice(std.testing.allocator, &.{
        1, 0, 2, 0, 3, 0, 4, 0,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = data.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, path, 0, .{
        .x = 1,
        .y = 0,
        .width = 1,
        .height = 2,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("rcpnl", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 4, 0, 2, 0 }, plane.data);
}
