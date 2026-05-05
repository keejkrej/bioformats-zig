const std = @import("std");
const bio = @import("../root.zig");

const header_len = 76;
const pic_file_id = 12345;

const Header = struct {
    width: u32,
    height: u32,
    planes: u32,
    pixel_type: bio.PixelType,
    name: ?[]const u8,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "biorad",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
    }) catch return false;
    const pixel_bytes = std.math.mul(usize, plane_len, header.planes) catch return false;
    return data.len >= header_len and data.len - header_len >= pixel_bytes;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "biorad",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.planes, std.math.maxInt(u16))),
        .pixel_type = header.pixel_type,
        .little_endian = true,
        .plane_count = header.planes,
        .image_description = header.name,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const offset = std.math.add(usize, header_len, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_len) return error.TruncatedData;
    const width = readU16(data[0..2]);
    const height = readU16(data[2..4]);
    const planes = readU16(data[4..6]);
    const byte_flag = readU16(data[14..16]);
    const file_id = readU16(data[54..56]);
    if (file_id != pic_file_id) return error.InvalidFormat;
    if (width == 0 or height == 0 or planes == 0) return error.InvalidFormat;
    return .{
        .width = width,
        .height = height,
        .planes = planes,
        .pixel_type = if (byte_flag == 0) .uint16 else .uint8,
        .name = optionalCString(data[18..50]),
    };
}

fn optionalCString(bytes: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    const value = std.mem.trim(u8, bytes[0..end], " \t\r\n");
    return if (value.len == 0) null else value;
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

fn appendHeader(list: *std.ArrayList(u8), width: u16, height: u16, planes: u16, byte_pixels: bool, name: ?[]const u8) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_len);
    writeU16(list.items, 0, width);
    writeU16(list.items, 2, height);
    writeU16(list.items, 4, planes);
    writeU16(list.items, 14, if (byte_pixels) 1 else 0);
    if (name) |text| @memcpy(list.items[18..][0..@min(text.len, 32)], text[0..@min(text.len, 32)]);
    writeU16(list.items, 54, pic_file_id);
}

test "reads biorad uint16 planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 2, false, "PIC test");
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0, 3, 0, 4, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("PIC test", metadata.image_description.?);

    const second = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 4, 0 }, second.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads biorad uint8 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 1, true, null);
    try data.appendSlice(std.testing.allocator, &.{ 7, 9 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "rejects truncated biorad pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 1, false, null);
    try data.append(std.testing.allocator, 0);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}

