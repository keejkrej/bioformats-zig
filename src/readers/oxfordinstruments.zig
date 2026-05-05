const std = @import("std");
const bio = @import("../root.zig");

const magic = "Oxford Instruments";
const normal_dims_offset = 1048;
const alternate_dims_offset = 1084;
const lut_size_offset = 1288;

const Header = struct {
    width: u32,
    height: u32,
    pixel_offset: usize,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const metadata = metadataFromHeader(header);
    const plane_len = planeByteCount(metadata) catch return false;
    return data.len >= header.pixel_offset and data.len - header.pixel_offset >= plane_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    return metadataFromHeader(try parseHeader(data));
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    if (plane_index != 0) return error.InvalidPlaneIndex;
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    const plane_len = try planeByteCount(metadata);
    if (header.pixel_offset > data.len or data.len - header.pixel_offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[header.pixel_offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < lut_size_offset + 4) return error.TruncatedData;
    if (!std.mem.startsWith(u8, data, magic)) return error.InvalidFormat;
    var width = readU32(data, normal_dims_offset);
    var height = readU32(data, normal_dims_offset + 4);
    if (width == 0 and height == 0) {
        width = readU32(data, alternate_dims_offset);
        height = readU32(data, alternate_dims_offset + 4);
    }
    if (width == 0 or height == 0) return error.InvalidFormat;
    const lut_size = readU32(data, lut_size_offset);
    const pixel_offset = std.math.add(usize, lut_size_offset + 4, lut_size) catch return error.UnsupportedVariant;
    var header = Header{ .width = width, .height = height, .pixel_offset = pixel_offset };
    const metadata = metadataFromHeader(header);
    const plane_len = try planeByteCount(metadata);
    if (pixel_offset <= data.len and data.len - pixel_offset < plane_len) header.height = 1;
    return header;
}

fn metadataFromHeader(header: Header) bio.Metadata {
    return .{
        .format = "oxfordinstruments",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint16,
        .little_endian = true,
    };
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const row = std.math.mul(usize, metadata.width, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
    return std.math.mul(usize, row, metadata.height) catch return error.UnsupportedVariant;
}

fn appendU32Le(list: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

test "reads oxford instruments top pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, magic);
    while (data.items.len < normal_dims_offset) try data.append(std.testing.allocator, 0);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 1);
    while (data.items.len < lut_size_offset) try data.append(std.testing.allocator, 0);
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0 });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("oxfordinstruments", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, plane.data);
}
