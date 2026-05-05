const std = @import("std");
const bio = @import("../root.zig");

const mg_dimension_offset = 0x63c;
const mg_pixel_offset_extra = 540;
const im_width = 1024;
const im_header_extra = 56;

const Header = struct {
    width: u32,
    height: u32,
    pixel_offset: usize,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "jeol",
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
        .format = "jeol",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint8,
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
    if (data.len < 2) return error.TruncatedData;
    if (std.mem.eql(u8, data[0..2], "MG")) {
        if (data.len < mg_dimension_offset + 8) return error.TruncatedData;
        const width = readU32(data[mg_dimension_offset..][0..4]);
        const height = readU32(data[mg_dimension_offset + 4 ..][0..4]);
        const pixel_offset = mg_dimension_offset + 8 + mg_pixel_offset_extra;
        if (width == 0 or height == 0) return error.InvalidFormat;
        return .{ .width = width, .height = height, .pixel_offset = pixel_offset };
    }
    if (std.mem.eql(u8, data[0..2], "IM")) {
        if (data.len < 4) return error.TruncatedData;
        const comment_len = readU16(data[2..4]);
        const pixel_offset = @as(usize, 4) + comment_len + im_header_extra;
        if (data.len <= pixel_offset) return error.TruncatedData;
        const pixels_len = data.len - pixel_offset;
        if (pixels_len < im_width or pixels_len % im_width != 0) return error.InvalidFormat;
        const height = pixels_len / im_width;
        return .{ .width = im_width, .height = @intCast(height), .pixel_offset = pixel_offset };
    }
    return error.InvalidFormat;
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    return std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
}

fn appendMgHeader(list: *std.ArrayList(u8), width: u32, height: u32) !void {
    try list.appendNTimes(std.testing.allocator, 0, mg_dimension_offset + 8 + mg_pixel_offset_extra);
    @memcpy(list.items[0..2], "MG");
    writeU32(list.items, mg_dimension_offset, width);
    writeU32(list.items, mg_dimension_offset + 4, height);
}

fn appendImHeader(list: *std.ArrayList(u8), comment_len: u16) !void {
    try list.appendNTimes(std.testing.allocator, 0, 4 + comment_len + im_header_extra);
    @memcpy(list.items[0..2], "IM");
    writeU16(list.items, 2, comment_len);
}

test "reads jeol mg uint8 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendMgHeader(&data, 2, 1);
    try data.appendSlice(std.testing.allocator, &.{ 7, 9 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "reads jeol im uint8 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendImHeader(&data, 3);
    try data.appendNTimes(std.testing.allocator, 0x55, im_width);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, im_width), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(usize, im_width), plane.data.len);
    try std.testing.expectEqual(@as(u8, 0x55), plane.data[0]);
    try std.testing.expectEqual(@as(u8, 0x55), plane.data[im_width - 1]);
}

test "rejects truncated jeol mg pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendMgHeader(&data, 2, 1);
    try data.append(std.testing.allocator, 7);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}
