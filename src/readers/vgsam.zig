const std = @import("std");
const bio = @import("../root.zig");

const pixel_offset = 368;
const magic = "VGS";

const Offset = struct {
    const width = 348;
    const height = 352;
    const bytes_per_pixel = 360;
};

const Header = struct {
    width: u32,
    height: u32,
    pixel_type: bio.PixelType,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "vgsam",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
    }) catch return false;
    return data.len >= pixel_offset and data.len - pixel_offset >= plane_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "vgsam",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
        .little_endian = false,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const plane_len = try planeByteCount(metadata);
    if (data.len < pixel_offset or data.len - pixel_offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[pixel_offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < pixel_offset) return error.TruncatedData;
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return error.InvalidFormat;
    const width = readU32(data[Offset.width..][0..4]);
    const height = readU32(data[Offset.height..][0..4]);
    const bytes_per_pixel = readU32(data[Offset.bytes_per_pixel..][0..4]);
    if (width == 0 or height == 0) return error.InvalidFormat;
    return .{
        .width = width,
        .height = height,
        .pixel_type = switch (bytes_per_pixel) {
            1 => .uint8,
            2 => .uint16,
            4 => .float32,
            else => return error.UnsupportedVariant,
        },
    };
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

fn appendHeader(list: *std.ArrayList(u8), width: u32, height: u32, bytes_per_pixel: u32) !void {
    try list.appendNTimes(std.testing.allocator, 0, pixel_offset);
    @memcpy(list.items[0..magic.len], magic);
    writeU32(list.items, Offset.width, width);
    writeU32(list.items, Offset.height, height);
    writeU32(list.items, Offset.bytes_per_pixel, bytes_per_pixel);
}

test "reads vg sam uint16 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 2);
    try data.appendSlice(std.testing.allocator, &.{ 0x12, 0x34, 0xab, 0xcd });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0xab, 0xcd }, plane.data);
}

test "reads vg sam float32 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 4);
    try data.appendSlice(std.testing.allocator, &.{ 0x3f, 0x80, 0, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x3f, 0x80, 0, 0 }, plane.data);
}

test "rejects truncated vg sam pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 2);
    try data.append(std.testing.allocator, 0);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}
