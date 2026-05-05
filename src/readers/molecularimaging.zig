const std = @import("std");
const bio = @import("../root.zig");

const magic = "UK SOFT";
const data_marker = "Data_section  \r\n";

const Header = struct {
    width: u32,
    height: u32,
    planes: u32,
    pixel_offset: usize,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "molecularimaging",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint16,
    }) catch return false;
    const pixel_bytes = std.math.mul(usize, plane_len, header.planes) catch return false;
    return data.len >= header.pixel_offset and data.len - header.pixel_offset >= pixel_bytes;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "molecularimaging",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.planes, std.math.maxInt(u16))),
        .pixel_type = .uint16,
        .little_endian = true,
        .plane_count = header.planes,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const offset = std.math.add(usize, header.pixel_offset, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < 16) return error.TruncatedData;
    if (std.mem.indexOf(u8, data[0..16], magic) == null) return error.InvalidFormat;
    const marker_pos = std.mem.indexOf(u8, data, data_marker) orelse return error.InvalidFormat;
    const text = data[0..marker_pos];
    var width: u32 = 0;
    var height: u32 = 0;
    var planes: u32 = 0;

    var lines = std.mem.splitAny(u8, text, "\r\n");
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t");
        const space = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const key = std.mem.trim(u8, line[0..space], " \t");
        const value = std.mem.trim(u8, line[space + 1 ..], " \t");
        if (std.mem.eql(u8, key, "samples_x")) {
            width = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, key, "samples_y")) {
            height = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, key, "buffer_id")) {
            planes += 1;
        }
    }

    if (width == 0 or height == 0) return error.InvalidFormat;
    if (planes == 0) planes = 1;
    return .{
        .width = width,
        .height = height,
        .planes = planes,
        .pixel_offset = marker_pos + data_marker.len,
    };
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(list: *std.ArrayList(u8), width: u32, height: u32, planes: u32) !void {
    const header = try std.fmt.allocPrint(std.testing.allocator,
        \\00 UK SOFT
        \\samples_x {d}
        \\samples_y {d}
        \\
    , .{ width, height });
    defer std.testing.allocator.free(header);
    try list.appendSlice(std.testing.allocator, header);
    for (0..planes) |plane| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "buffer_id {d}\r\n", .{plane});
        defer std.testing.allocator.free(line);
        try list.appendSlice(std.testing.allocator, line);
    }
    try list.appendSlice(std.testing.allocator, data_marker);
}

test "reads molecular imaging uint16 planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 2);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0, 3, 0, 4, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const second = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 4, 0 }, second.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "defaults molecular imaging missing buffer count to one plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 0);
    try data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, plane.data);
}

test "rejects truncated molecular imaging pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 1);
    try data.append(std.testing.allocator, 0);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}
