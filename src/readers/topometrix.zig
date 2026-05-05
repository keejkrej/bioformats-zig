const std = @import("std");
const bio = @import("../root.zig");

const magic = "#R";
const version5_metadata_offset = 452;
const standard_metadata_offset = 254;
const dimension_skip = 152;

const Header = struct {
    width: u32,
    height: u32,
    pixel_offset: usize,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "topometrix",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint16,
    }) catch return false;
    return data.len >= header.pixel_offset and data.len - header.pixel_offset >= plane_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "topometrix",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint16,
        .little_endian = true,
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
    if (data.len < 14) return error.TruncatedData;
    if (!std.mem.startsWith(u8, data, magic)) return error.InvalidFormat;
    const version = parseVersion(data[2..6]) catch return error.InvalidFormat;
    const pixel_offset = parseOffset(data[8..12]) catch return error.InvalidFormat;
    const metadata_offset: usize = if (version == 5) version5_metadata_offset else standard_metadata_offset;
    const width_offset = metadata_offset + dimension_skip;
    const height_offset = width_offset + 4;
    if (data.len < height_offset + 2) return error.TruncatedData;
    const width = readU16(data[width_offset..][0..2]);
    const height = readU16(data[height_offset..][0..2]);
    if (width == 0 or height == 0 or pixel_offset == 0) return error.InvalidFormat;
    return .{ .width = width, .height = height, .pixel_offset = pixel_offset };
}

fn parseVersion(bytes: []const u8) !u32 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n\x00");
    const value = try std.fmt.parseFloat(f64, trimmed);
    if (!std.math.isFinite(value) or value < 0) return error.InvalidFormat;
    return @intFromFloat(@floor(value));
}

fn parseOffset(bytes: []const u8) !usize {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n\x00");
    return try std.fmt.parseInt(usize, trimmed, 10);
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(list: *std.ArrayList(u8), version_text: []const u8, pixel_offset: usize, width: u16, height: u16) !void {
    const version = parseVersion(version_text) catch return error.InvalidFormat;
    const metadata_offset: usize = if (version == 5) version5_metadata_offset else standard_metadata_offset;
    const width_offset = metadata_offset + dimension_skip;
    const height_offset = width_offset + 4;
    try list.appendNTimes(std.testing.allocator, 0, pixel_offset);
    @memcpy(list.items[0..2], magic);
    @memcpy(list.items[2..6], version_text[0..4]);
    const offset_text = try std.fmt.allocPrint(std.testing.allocator, "{d:0>4}", .{pixel_offset});
    defer std.testing.allocator.free(offset_text);
    @memcpy(list.items[8..12], offset_text[0..4]);
    writeU16(list.items, width_offset, width);
    writeU16(list.items, height_offset, height);
}

test "reads topometrix uint16 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, "4.00", 900, 2, 1);
    try data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12, 0xcd, 0xab });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
}

test "reads topometrix version 5 dimensions" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, "5.00", 900, 1, 1);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
}

test "rejects truncated topometrix pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, "4.00", 900, 2, 1);
    try data.append(std.testing.allocator, 0);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}
