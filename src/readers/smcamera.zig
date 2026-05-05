const std = @import("std");
const bio = @import("../root.zig");

const header_len = 548;
const signature = [_]u8{ 0, 0, 0, 0, 2, 0, 0, 5, 0xc9, 0x88, 0, 5, 0xcb, 0x88, 0, 0 };

const Header = struct {
    width: u32,
    height: u32,
};

pub fn matches(data: []const u8) bool {
    return data.len >= signature.len and std.mem.eql(u8, data[0..signature.len], &signature);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "smcamera",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint8,
        .little_endian = false,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const plane_len = try planeByteCount(metadata);
    if (data.len < header_len or data.len - header_len < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[header_len..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    if (data.len < header_len) return error.TruncatedData;
    const height = readU16(data[524..526]);
    const width = readU16(data[532..534]);
    if (width == 0 or height == 0) return error.InvalidFormat;
    return .{ .width = width, .height = height };
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .big);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(list: *std.ArrayList(u8), width: u16, height: u16) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_len);
    @memcpy(list.items[0..signature.len], &signature);
    writeU16(list.items, 524, height);
    writeU16(list.items, 532, width);
}

test "reads sm camera uint8 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1);
    try data.appendSlice(std.testing.allocator, &.{ 7, 9 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "rejects truncated sm camera pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1);
    try data.append(std.testing.allocator, 7);

    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}
