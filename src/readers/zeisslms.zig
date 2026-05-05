const std = @import("std");
const bio = @import("../root.zig");

const check = "LMSFLE";
const marker = "BM6";

const header_marker_search_offset = 22;
const marker_payload_skip = 50;
const width = 1280;
const height = 1024;
const thumbnail_bytes = width * height * 3;
const lut_bytes = 256 * 4;

const Header = struct {
    pixel_offset: usize,
    plane_count: u32,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "zeisslms",
        .width = width,
        .height = height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = try u16PlaneCount(header.plane_count),
        .size_t = 1,
        .pixel_type = .uint16,
        .little_endian = true,
        .plane_count = header.plane_count,
        .dimension_order = "XYZCT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const header = try parseHeader(data);
    const plane_len = try planeByteCount();
    const offset = std.math.add(usize, header.pixel_offset, std.math.mul(usize, plane_index, plane_len) catch return error.InvalidPlaneIndex) catch return error.InvalidPlaneIndex;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < check.len) return error.TruncatedData;
    const check_end = @min(@as(usize, 16), data.len);
    if (std.mem.indexOf(u8, data[0..check_end], check) == null) return error.InvalidFormat;

    const first_after_marker = try findNextMarker(data, header_marker_search_offset);
    const after_thumbnail_header = std.math.add(usize, first_after_marker, marker_payload_skip) catch return error.UnsupportedVariant;
    const second_search_offset = std.math.add(usize, after_thumbnail_header, thumbnail_bytes) catch return error.UnsupportedVariant;
    const second_after_marker = try findNextMarker(data, second_search_offset);
    const after_main_header = std.math.add(usize, second_after_marker, marker_payload_skip) catch return error.UnsupportedVariant;
    const pixel_offset = std.math.add(usize, after_main_header, lut_bytes) catch return error.UnsupportedVariant;
    if (pixel_offset > data.len) return error.TruncatedData;

    const plane_len = try planeByteCount();
    const planes = (data.len - pixel_offset) / plane_len;
    if (planes == 0) return error.TruncatedData;
    if (planes > std.math.maxInt(u32)) return error.UnsupportedVariant;
    return .{ .pixel_offset = pixel_offset, .plane_count = @intCast(planes) };
}

fn findNextMarker(data: []const u8, start: usize) bio.ReaderError!usize {
    if (start >= data.len) return error.TruncatedData;
    var pos = start;
    while (pos + marker.len <= data.len) : (pos += 1) {
        if (std.mem.eql(u8, data[pos..][0..marker.len], marker)) {
            const after_marker = std.math.add(usize, pos, marker.len + 1) catch return error.UnsupportedVariant;
            if (after_marker > data.len) return error.TruncatedData;
            return after_marker;
        }
    }
    return error.InvalidFormat;
}

fn u16PlaneCount(plane_count: u32) bio.ReaderError!u16 {
    if (plane_count > std.math.maxInt(u16)) return error.UnsupportedVariant;
    return @intCast(plane_count);
}

fn planeByteCount() bio.ReaderError!usize {
    const pixels = std.math.mul(usize, width, height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, 2) catch return error.UnsupportedVariant;
}

fn appendSyntheticFile(list: *std.ArrayList(u8), planes: u32) !usize {
    try list.appendNTimes(std.testing.allocator, 0, header_marker_search_offset);
    @memcpy(list.items[0..check.len], check);

    try list.appendSlice(std.testing.allocator, "BM6!");
    try list.appendNTimes(std.testing.allocator, 0, marker_payload_skip);
    try list.appendNTimes(std.testing.allocator, 0, thumbnail_bytes);

    try list.appendSlice(std.testing.allocator, "BM6!");
    try list.appendNTimes(std.testing.allocator, 0, marker_payload_skip);
    try list.appendNTimes(std.testing.allocator, 0, lut_bytes);

    const pixel_offset = list.items.len;
    try list.appendNTimes(std.testing.allocator, 0, try std.math.mul(usize, planes, try planeByteCount()));
    return pixel_offset;
}

test "reads zeiss lms uint16 z planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    const pixel_offset = try appendSyntheticFile(&data, 2);
    const plane_len = try planeByteCount();
    data.items[pixel_offset] = 0x34;
    data.items[pixel_offset + 1] = 0x12;
    data.items[pixel_offset + plane_len] = 0xcd;
    data.items[pixel_offset + plane_len + 1] = 0xab;

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, width), metadata.width);
    try std.testing.expectEqual(@as(u32, height), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(usize, plane_len), plane.data.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xcd, 0xab }, plane.data[0..2]);
}

test "rejects zeiss lms without complete first plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    _ = try appendSyntheticFile(&data, 1);
    _ = data.pop();

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readMetadata(data.items));
}
