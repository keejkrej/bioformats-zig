const std = @import("std");
const bio = @import("../root.zig");

const magic = "DTag";
const pixels_marker = "BSfD";
const dimensions_marker = "GBiH";
const marker_payload_skip = 20;

const Header = struct {
    width: u32,
    height: u32,
    pixel_offset: usize,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "kodak",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .float32,
    }) catch return false;
    return data.len >= header.pixel_offset and data.len - header.pixel_offset >= plane_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "kodak",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .dimension_order = "XYCZT",
        .pixel_type = .float32,
        .little_endian = false,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    const plane_len = try planeByteCount(metadata);
    if (data.len < header.pixel_offset or data.len - header.pixel_offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[header.pixel_offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < 16) return error.TruncatedData;
    if (std.mem.indexOf(u8, data[0..16], magic) == null) return error.InvalidFormat;

    const dim_pos = std.mem.indexOf(u8, data, dimensions_marker) orelse return error.InvalidFormat;
    const dim_data = dim_pos + dimensions_marker.len + marker_payload_skip;
    if (data.len - dim_data < 8) return error.TruncatedData;
    const width = readU32(data[dim_data..][0..4]);
    const height = readU32(data[dim_data + 4 ..][0..4]);
    if (width == 0 or height == 0) return error.InvalidFormat;

    const pixel_pos = std.mem.indexOf(u8, data, pixels_marker) orelse return error.InvalidFormat;
    const pixel_offset = pixel_pos + pixels_marker.len + marker_payload_skip;
    return .{ .width = width, .height = height, .pixel_offset = pixel_offset };
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .big);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendMarker(list: *std.ArrayList(u8), marker: []const u8) !usize {
    const pos = list.items.len;
    try list.appendSlice(std.testing.allocator, marker);
    try list.appendNTimes(std.testing.allocator, 0, marker_payload_skip);
    return pos;
}

test "reads kodak bip float32 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, "xxDTagxx");
    _ = try appendMarker(&data, dimensions_marker);
    const dims = try data.addManyAsSlice(std.testing.allocator, 8);
    writeU32(dims, 0, 2);
    writeU32(dims, 4, 1);
    _ = try appendMarker(&data, pixels_marker);
    try data.appendSlice(std.testing.allocator, &.{ 0x3f, 0x80, 0, 0, 0x40, 0, 0, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x3f, 0x80, 0, 0, 0x40, 0, 0, 0 }, plane.data);
}

test "rejects truncated kodak pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, "xxDTagxx");
    _ = try appendMarker(&data, dimensions_marker);
    const dims = try data.addManyAsSlice(std.testing.allocator, 8);
    writeU32(dims, 0, 1);
    writeU32(dims, 4, 1);
    _ = try appendMarker(&data, pixels_marker);
    try data.append(std.testing.allocator, 0);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}
