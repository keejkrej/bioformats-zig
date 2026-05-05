const std = @import("std");
const bio = @import("../root.zig");

const header_len = 64;
const magic = "IM";

const Offset = struct {
    const comment_len = 2;
    const width = 4;
    const height = 6;
    const data_type = 12;
    const series_count = 14;
};

const Header = struct {
    width: u32,
    height: u32,
    samples: u16,
    pixel_type: bio.PixelType,
    pixel_offset: usize,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "his",
        .width = header.width,
        .height = header.height,
        .size_c = header.samples,
        .samples_per_pixel = header.samples,
        .pixel_type = header.pixel_type,
    }) catch return false;
    return data.len >= header.pixel_offset and data.len - header.pixel_offset >= plane_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "his",
        .width = header.width,
        .height = header.height,
        .size_c = header.samples,
        .samples_per_pixel = header.samples,
        .pixel_type = header.pixel_type,
        .little_endian = true,
        .dimension_order = "XYCZT",
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
    if (data.len < header_len) return error.TruncatedData;
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return error.InvalidFormat;
    const comment_len = readU16(data[Offset.comment_len..][0..2]);
    const width = readU16(data[Offset.width..][0..2]);
    const height = readU16(data[Offset.height..][0..2]);
    const data_type = readU16(data[Offset.data_type..][0..2]);
    const series_count = readU16(data[Offset.series_count..][0..2]);
    if (width == 0 or height == 0) return error.InvalidFormat;
    if (series_count != 1) return error.UnsupportedVariant;

    const pixel_offset = std.math.add(usize, header_len, comment_len) catch return error.UnsupportedVariant;
    return .{
        .width = width,
        .height = height,
        .samples = samplesForType(data_type) catch return error.UnsupportedVariant,
        .pixel_type = pixelType(data_type) catch return error.UnsupportedVariant,
        .pixel_offset = pixel_offset,
    };
}

fn samplesForType(data_type: u16) bio.ReaderError!u16 {
    return switch (data_type) {
        1, 2 => 1,
        11, 12 => 3,
        6, 14 => error.UnsupportedVariant,
        else => error.UnsupportedVariant,
    };
}

fn pixelType(data_type: u16) bio.ReaderError!bio.PixelType {
    return switch (data_type) {
        1 => .uint8,
        2 => .uint16,
        11 => .rgb8,
        12 => .rgb16,
        6, 14 => error.UnsupportedVariant,
        else => error.UnsupportedVariant,
    };
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    const samples = std.math.mul(usize, pixels, metadata.samples_per_pixel) catch return error.UnsupportedVariant;
    return std.math.mul(usize, samples, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(list: *std.ArrayList(u8), width: u16, height: u16, data_type: u16, comment: []const u8) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_len);
    @memcpy(list.items[0..magic.len], magic);
    writeU16(list.items, Offset.comment_len, @intCast(comment.len));
    writeU16(list.items, Offset.width, width);
    writeU16(list.items, Offset.height, height);
    writeU16(list.items, Offset.data_type, data_type);
    writeU16(list.items, Offset.series_count, 1);
    try list.appendSlice(std.testing.allocator, comment);
}

test "reads his uint16 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 2, "note");
    try data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12, 0xcd, 0xab });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
}

test "reads his rgb8 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 11, "");
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, plane.data);
}

test "rejects unsupported his packed 12-bit pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 6, "");
    try data.appendSlice(std.testing.allocator, &.{ 0, 0, 0 });

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}

test "rejects truncated his pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 2, "");
    try data.append(std.testing.allocator, 0);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}
