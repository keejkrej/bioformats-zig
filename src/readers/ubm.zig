const std = @import("std");
const bio = @import("../root.zig");

const header_len = 128;
const bytes_per_pixel = 4;

const Offset = struct {
    const width = 44;
    const height = 48;
};

const Header = struct {
    width: u32,
    height: u32,
    row_padding_pixels: usize,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "ubm",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint32,
        .little_endian = true,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    const plane_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);

    const row_len = @as(usize, metadata.width) * bytes_per_pixel;
    const row_stride = (@as(usize, metadata.width) + header.row_padding_pixels) * bytes_per_pixel;
    var src: usize = header_len;
    var dst: usize = 0;
    for (0..metadata.height) |_| {
        if (data.len - src < row_len) return error.TruncatedData;
        @memcpy(out[dst..][0..row_len], data[src..][0..row_len]);
        src += row_stride;
        dst += row_len;
    }

    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_len) return error.TruncatedData;
    const width = readU32(data[Offset.width..][0..4]);
    const height = readU32(data[Offset.height..][0..4]);
    if (width == 0 or height == 0) return error.InvalidFormat;

    const plane_len = planeByteCount(.{
        .format = "ubm",
        .width = width,
        .height = height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint32,
    }) catch return error.UnsupportedVariant;
    if (data.len - header_len < plane_len) return error.TruncatedData;

    const extra = data.len - header_len - plane_len;
    const padding_divisor = std.math.mul(usize, height, bytes_per_pixel) catch return error.UnsupportedVariant;
    if (extra % padding_divisor != 0) return error.InvalidFormat;
    return .{
        .width = width,
        .height = height,
        .row_padding_pixels = extra / padding_divisor,
    };
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(list: *std.ArrayList(u8), width: u32, height: u32) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_len);
    writeU32(list.items, Offset.width, width);
    writeU32(list.items, Offset.height, height);
}

test "reads ubm uint32 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 0, 0, 2, 0, 0, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint32, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 2, 0, 0, 0 }, plane.data);
}

test "strips ubm row padding" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 2);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 0, 0, 2, 0, 0, 0, 0xaa, 0xaa, 0xaa, 0xaa });
    try data.appendSlice(std.testing.allocator, &.{ 3, 0, 0, 0, 4, 0, 0, 0, 0xbb, 0xbb, 0xbb, 0xbb });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0 }, plane.data);
}

test "rejects truncated ubm pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 0, 0 });

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}
