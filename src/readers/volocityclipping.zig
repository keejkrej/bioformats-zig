const std = @import("std");
const bio = @import("../root.zig");

const magic = "FFCA";
const aisf_marker: u32 = 0x46534941;
const regular_marker: u32 = 0x208;
const dims_tail_skip = 65;

const Header = struct {
    width: u32,
    height: u32,
    planes: u32,
    pixel_offset: usize,
    little_endian: bool,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "volocityclipping",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint8,
    }) catch return false;
    return data.len >= header.pixel_offset and data.len - header.pixel_offset >= plane_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "volocityclipping",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.planes, std.math.maxInt(u16))),
        .pixel_type = .uint8,
        .little_endian = header.little_endian,
        .plane_count = header.planes,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const header = try parseHeader(data);
    const offset = std.math.add(usize, header.pixel_offset, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < 25) return error.TruncatedData;
    var little_endian = data[0] == 'I';
    if (!std.mem.eql(u8, data[5..9], magic)) return error.InvalidFormat;

    var marker_offset: usize = 9;
    var marker: u32 = 0;
    while (marker_offset + 4 <= data.len) : (marker_offset += 1) {
        marker = readU32(data[marker_offset..][0..4], little_endian);
        if (marker == regular_marker or marker == aisf_marker) break;
    } else return error.InvalidFormat;

    var dims_offset = marker_offset + 4;
    if (marker == aisf_marker) {
        little_endian = false;
        dims_offset = std.math.add(usize, dims_offset, 28) catch return error.UnsupportedVariant;
    }
    if (dims_offset > data.len or data.len - dims_offset < 12) return error.TruncatedData;

    const width = readU32(data[dims_offset..][0..4], little_endian);
    const height = readU32(data[dims_offset + 4 ..][0..4], little_endian);
    const planes = readU32(data[dims_offset + 8 ..][0..4], little_endian);
    if (width == 0 or height == 0 or planes == 0) return error.InvalidFormat;
    const pixel_offset = std.math.add(usize, dims_offset + 12, dims_tail_skip) catch return error.UnsupportedVariant;
    if (pixel_offset > data.len) return error.TruncatedData;

    return .{
        .width = width,
        .height = height,
        .planes = planes,
        .pixel_offset = pixel_offset,
        .little_endian = little_endian,
    };
}

fn readU32(bytes: []const u8, little_endian: bool) u32 {
    return std.mem.readInt(u32, bytes[0..4], if (little_endian) .little else .big);
}

fn writeU32(list: *std.ArrayList(u8), value: u32, little_endian: bool) !void {
    if (little_endian) {
        try list.append(std.testing.allocator, @intCast(value & 0xff));
        try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
        try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
        try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
    } else {
        try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
        try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
        try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
        try list.append(std.testing.allocator, @intCast(value & 0xff));
    }
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendRegularHeader(list: *std.ArrayList(u8), width: u32, height: u32, planes: u32) !void {
    try list.append(std.testing.allocator, 'I');
    try list.appendNTimes(std.testing.allocator, 0, 4);
    try list.appendSlice(std.testing.allocator, magic);
    try writeU32(list, regular_marker, true);
    try writeU32(list, width, true);
    try writeU32(list, height, true);
    try writeU32(list, planes, true);
    try list.appendNTimes(std.testing.allocator, 0, dims_tail_skip);
}

fn appendAisfHeader(list: *std.ArrayList(u8), width: u32, height: u32, planes: u32) !void {
    try list.append(std.testing.allocator, 'I');
    try list.appendNTimes(std.testing.allocator, 0, 4);
    try list.appendSlice(std.testing.allocator, magic);
    try list.appendSlice(std.testing.allocator, "AISF");
    try list.appendNTimes(std.testing.allocator, 0, 28);
    try writeU32(list, width, false);
    try writeU32(list, height, false);
    try writeU32(list, planes, false);
    try list.appendNTimes(std.testing.allocator, 0, dims_tail_skip);
}

test "reads volocity clipping uint8 planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendRegularHeader(&data, 2, 1, 2);
    try data.appendSlice(std.testing.allocator, &.{ 3, 4, 5, 6 });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("volocityclipping", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "parses volocity clipping AISF dimensions as big endian" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendAisfHeader(&data, 1, 2, 1);
    try data.appendSlice(std.testing.allocator, &.{ 7, 8 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expect(!metadata.little_endian);
}

test "rejects truncated volocity clipping pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendRegularHeader(&data, 2, 1, 1);
    try data.append(std.testing.allocator, 9);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}
