const std = @import("std");
const bio = @import("../root.zig");

const header_len = 4864;
const magic = "0TOPSystem W.A.Technology";

const Offset = struct {
    const comment = 49;
    const size_x = 251;
    const size_y = 255;
};

const Header = struct {
    width: u32,
    height: u32,
    comment: ?[]const u8,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "watop",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .int16,
    }) catch return false;
    return data.len >= header_len and data.len - header_len >= plane_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "watop",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .int16,
        .little_endian = true,
        .image_description = header.comment,
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
    if (data.len < header_len) return error.TruncatedData;
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return error.InvalidFormat;
    const width = readU32(data[Offset.size_x..][0..4]);
    const height = readU32(data[Offset.size_y..][0..4]);
    if (width == 0 or height == 0) return error.InvalidFormat;
    return .{
        .width = width,
        .height = height,
        .comment = optionalString(data[Offset.comment..][0..33]),
    };
}

fn optionalString(bytes: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    const value = std.mem.trim(u8, bytes[0..end], " \t\r\n");
    return if (value.len == 0) null else value;
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

fn appendHeader(list: *std.ArrayList(u8), width: u32, height: u32, comment: ?[]const u8) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_len);
    @memcpy(list.items[0..magic.len], magic);
    if (comment) |text| @memcpy(list.items[Offset.comment..][0..@min(text.len, 33)], text[0..@min(text.len, 33)]);
    writeU32(list.items, Offset.size_x, width);
    writeU32(list.items, Offset.size_y, height);
}

test "reads watop int16 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, "WAT note");
    try data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12, 0xcd, 0xab });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.int16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("WAT note", metadata.image_description.?);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
}

test "rejects truncated watop pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, null);
    try data.append(std.testing.allocator, 0);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}

