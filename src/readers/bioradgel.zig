const std = @import("std");
const bio = @import("../root.zig");

const magic: u16 = 0xafaf;
const start_offset = 160;

const Header = struct {
    width: u32,
    height: u32,
    pixel_type: bio.PixelType,
    little_endian: bool,
    pixel_offset: usize,
};

pub fn matches(data: []const u8) bool {
    if (data.len < 2) return false;
    return std.mem.readInt(u16, data[0..2], .big) == magic;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "bioradgel",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
        .little_endian = header.little_endian,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    if (plane_index != 0) return error.InvalidPlaneIndex;
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    const plane_len = try planeByteCount(metadata);
    if (header.pixel_offset > data.len or data.len - header.pixel_offset < plane_len) return error.TruncatedData;

    const row_bytes = std.math.mul(usize, metadata.width, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, plane_len);
    var row: usize = 0;
    while (row < metadata.height) : (row += 1) {
        const src_row = @as(usize, metadata.height - 1) - row;
        @memcpy(out[row * row_bytes ..][0..row_bytes], data[header.pixel_offset + src_row * row_bytes ..][0..row_bytes]);
    }
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    const little = std.mem.indexOf(u8, data[0..@min(data.len, 48)], "Intel Format") != null;
    var endian: std.builtin.Endian = if (little) .little else .big;
    var meta = try metadataOffset(data, endian);
    var width = readU16(data, meta, endian);
    var height = readU16(data, meta + 2, endian);
    if (@as(usize, width) * @as(usize, height) > data.len) {
        endian = .little;
        meta = try metadataOffset(data, endian);
        width = readU16(data, meta, endian);
        height = readU16(data, meta + 2, endian);
    }
    if (width == 0 or height == 0) return error.InvalidFormat;
    const bpp = readU16(data, meta + 6, endian);
    const pixel_type: bio.PixelType = switch (bpp) {
        1 => .uint8,
        2 => .uint16,
        4 => .uint32,
        else => return error.UnsupportedVariant,
    };
    const plane_len = try planeByteCount(.{
        .format = "bioradgel",
        .width = width,
        .height = height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = pixel_type,
    });
    if (data.len < plane_len) return error.TruncatedData;
    return .{
        .width = width,
        .height = height,
        .pixel_type = pixel_type,
        .little_endian = endian == .little,
        .pixel_offset = data.len - plane_len,
    };
}

fn metadataOffset(data: []const u8, endian: std.builtin.Endian) bio.ReaderError!usize {
    var pos: usize = start_offset;
    while (pos + 4 <= data.len) {
        const code = readU16(data, pos, endian);
        const length = readU16(data, pos + 2, endian);
        const skip = std.math.add(usize, 2, std.math.mul(usize, 2, length) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
        pos += 4;
        if (pos > data.len or data.len - pos < skip) return error.TruncatedData;
        pos += skip;
        if (code == 0x81) {
            const base = std.math.add(usize, pos, 2) catch return error.UnsupportedVariant;
            var skip_value: i64 = 0;
            if (length > 1) {
                if (pos < 2 or pos > data.len) return error.TruncatedData;
                const value_pos = pos - 2;
                if (data.len - value_pos < 4) return error.TruncatedData;
                skip_value = @as(i64, readU32(data, value_pos, endian)) - 32;
            }
            if (skip_value < 0) return error.UnsupportedVariant;
            const meta = std.math.add(usize, base, @intCast(skip_value)) catch return error.UnsupportedVariant;
            if (meta > data.len or data.len - meta < 8) return error.TruncatedData;
            return meta;
        }
        if (length == 1) {
            if (data.len - pos < 12) return error.TruncatedData;
            pos += 12;
        } else if (length == 2) {
            if (data.len - pos < 10) return error.TruncatedData;
            pos += 10;
        }
    }
    return error.InvalidFormat;
}

fn readU16(data: []const u8, offset: usize, endian: std.builtin.Endian) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], endian);
}

fn readU32(data: []const u8, offset: usize, endian: std.builtin.Endian) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], endian);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const row = std.math.mul(usize, metadata.width, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
    return std.math.mul(usize, row, metadata.height) catch return error.UnsupportedVariant;
}

fn appendU16Be(list: *std.ArrayList(u8), value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .big);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendU32Be(list: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try list.appendSlice(std.testing.allocator, &bytes);
}

test "reads biorad gel tail pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU16Be(&data, magic);
    while (data.items.len < start_offset) try data.append(std.testing.allocator, 0);
    try appendU16Be(&data, 0x81);
    try appendU16Be(&data, 2);
    try data.appendNTimes(std.testing.allocator, 0, 4);
    try appendU32Be(&data, 32);
    try appendU16Be(&data, 2);
    try appendU16Be(&data, 2);
    try appendU16Be(&data, 0);
    try appendU16Be(&data, 1);
    try data.appendSlice(std.testing.allocator, &.{ 3, 4, 1, 2 });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("bioradgel", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, plane.data);
}
