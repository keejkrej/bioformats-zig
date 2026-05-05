const std = @import("std");
const bio = @import("../root.zig");

const header_len = 2944;

const Offset = struct {
    const comment = 40;
    const width = 1402;
    const height = 1404;
};

const Header = struct {
    width: u32,
    height: u32,
    comment: ?[]const u8,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "seiko",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint16,
    }) catch return false;
    return data.len == header_len + plane_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "seiko",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint16,
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
    const width = readU16(data[Offset.width..][0..2]);
    const height = readU16(data[Offset.height..][0..2]);
    if (width == 0 or height == 0) return error.InvalidFormat;
    return .{
        .width = width,
        .height = height,
        .comment = optionalString(data[Offset.comment..][0..256]),
    };
}

fn optionalString(bytes: []const u8) ?[]const u8 {
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

fn appendHeader(list: *std.ArrayList(u8), width: u16, height: u16, comment: ?[]const u8) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_len);
    if (comment) |text| @memcpy(list.items[Offset.comment..][0..@min(text.len, 256)], text[0..@min(text.len, 256)]);
    writeU16(list.items, Offset.width, width);
    writeU16(list.items, Offset.height, height);
}

test "reads seiko uint16 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, "Seiko note");
    try data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12, 0xcd, 0xab });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("Seiko note", metadata.image_description.?);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
}

test "rejects truncated seiko pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, null);
    try data.append(std.testing.allocator, 0);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}

test "rejects seiko trailing data in detector" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, null);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 0 });

    try std.testing.expect(!matches(data.items));
}
