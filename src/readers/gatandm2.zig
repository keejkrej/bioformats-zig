const std = @import("std");
const bio = @import("../root.zig");

const header_size = 24;
const magic: u32 = 0x003d0000;

const Header = struct {
    width: u32,
    height: u32,
    pixel_type: bio.PixelType,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const metadata = metadataFromHeader(header);
    const plane_len = planeByteCount(metadata) catch return false;
    return data.len >= header_size and data.len - header_size >= plane_len;
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
    const plane_len = try planeByteCount(metadata);
    if (data.len - header_size < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[header_size..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_size) return error.TruncatedData;
    if (std.mem.readInt(u32, data[0..4], .big) != magic) return error.InvalidFormat;
    const width = std.mem.readInt(u16, data[16..18], .big);
    const height = std.mem.readInt(u16, data[18..20], .big);
    const bytes_per_pixel = std.mem.readInt(u16, data[20..22], .big);
    const signed = std.mem.readInt(u16, data[22..24], .big) == 1;
    if (width == 0 or height == 0) return error.InvalidFormat;
    const pixel_type: bio.PixelType = switch (bytes_per_pixel) {
        1 => if (signed) .int8 else .uint8,
        2 => if (signed) .int16 else .uint16,
        4 => if (signed) .int32 else .uint32,
        else => return error.UnsupportedVariant,
    };
    return .{
        .width = width,
        .height = height,
        .pixel_type = pixel_type,
    };
}

fn metadataFromHeader(header: Header) bio.Metadata {
    return .{
        .format = "gatandm2",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
        .little_endian = false,
    };
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const row = std.math.mul(usize, metadata.width, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
    return std.math.mul(usize, row, metadata.height) catch return error.UnsupportedVariant;
}

fn appendU16Be(list: *std.ArrayList(u8), value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .big);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendU32Be(list: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try list.appendSlice(std.testing.allocator, &bytes);
}

test "reads gatan dm2 pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU32Be(&data, magic);
    try appendU32Be(&data, 0);
    try appendU32Be(&data, 0);
    try appendU32Be(&data, 0);
    try appendU16Be(&data, 2);
    try appendU16Be(&data, 1);
    try appendU16Be(&data, 1);
    try appendU16Be(&data, 0);
    try data.appendSlice(std.testing.allocator, &.{ 8, 9 });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("gatandm2", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 8, 9 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}
