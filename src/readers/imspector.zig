const std = @import("std");
const bio = @import("../root.zig");

const magic = "CDataStack";

const Header = struct {
    width: u32,
    height: u32,
    size_z: u16,
    size_t: u16,
    pixel_offset: usize,
    plane_count: u32,
};

pub fn matches(data: []const u8) bool {
    return data.len >= 32 and std.mem.indexOf(u8, data[0..32], magic) != null;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "imspector",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .size_z = header.size_z,
        .size_t = header.size_t,
        .pixel_type = .uint16,
        .little_endian = true,
        .plane_count = header.plane_count,
        .dimension_order = "XYZCT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    if (plane_index >= header.plane_count) return error.InvalidPlaneIndex;

    const plane_bytes = try planeByteCount(header.width, header.height);
    const offset = header.pixel_offset + @as(usize, plane_index) * plane_bytes;
    if (offset > data.len or data.len - offset < plane_bytes) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_bytes);
    @memcpy(out, data[offset..][0..plane_bytes]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.UnsupportedFormat;
    var cursor: usize = 20;

    const tag_len = try readU16(data, &cursor);
    try skip(data, &cursor, tag_len);
    const tag_count = try readU32(data, &cursor);
    try skipTags(data, &cursor, tag_count);

    if ((cursor % 2) == 1) {
        try skip(data, &cursor, 1);
    } else if (cursor < data.len) {
        const check = data[cursor];
        cursor += 1;
        if (check != 0xff) cursor -= 1;
    }

    const metadata_len = try readU16(data, &cursor);
    try skip(data, &cursor, metadata_len);
    if ((metadata_len % 2) == 0 and cursor < data.len and data[cursor] == 13) cursor += 1;

    var check = try readU16(data, &cursor);
    var attempts: usize = 0;
    while (check != 3 and check != 2) : (attempts += 1) {
        if (attempts > 512 or cursor == 0) return error.InvalidFormat;
        cursor -= 1;
        check = try readU16(data, &cursor);
    }

    try skip(data, &cursor, 26);
    const pmt_len = try readU8(data, &cursor);
    try skip(data, &cursor, pmt_len);
    try skip(data, &cursor, 6);
    const width = try readU32(data, &cursor);
    const height = try readU32(data, &cursor);
    const size_z_raw = try readU32(data, &cursor);
    const size_t_raw = try readU32(data, &cursor);
    try skip(data, &cursor, 16);
    var setting: usize = 0;
    while (setting < 4) : (setting += 1) {
        const len = try readU8(data, &cursor);
        try skip(data, &cursor, len);
    }

    if (width == 0 or height == 0) return error.InvalidFormat;
    const size_z = boundedDimension(size_z_raw);
    const size_t = boundedDimension(size_t_raw);
    const plane_count = @as(u32, size_z) * @as(u32, size_t);
    const plane_bytes = try planeByteCount(width, height);
    const expected = std.math.mul(usize, plane_bytes, plane_count) catch return error.UnsupportedVariant;
    if (cursor > data.len or data.len - cursor < expected) return error.TruncatedData;
    return .{
        .width = width,
        .height = height,
        .size_z = size_z,
        .size_t = size_t,
        .pixel_offset = cursor,
        .plane_count = plane_count,
    };
}

fn skipTags(data: []const u8, cursor: *usize, count: u32) bio.ReaderError!void {
    var skipped: u32 = 0;
    var guard: u32 = 0;
    while (skipped < count) : (guard += 1) {
        if (guard > count + 1024) return error.InvalidFormat;
        const len = try readU8(data, cursor);
        if (len == 0) continue;
        try skip(data, cursor, len);
        skipped += 1;
    }
}

fn readU8(data: []const u8, cursor: *usize) bio.ReaderError!u8 {
    if (cursor.* >= data.len) return error.TruncatedData;
    const value = data[cursor.*];
    cursor.* += 1;
    return value;
}

fn readU16(data: []const u8, cursor: *usize) bio.ReaderError!u16 {
    if (data.len - cursor.* < 2) return error.TruncatedData;
    const value = std.mem.readInt(u16, data[cursor.*..][0..2], .little);
    cursor.* += 2;
    return value;
}

fn readU32(data: []const u8, cursor: *usize) bio.ReaderError!u32 {
    if (data.len - cursor.* < 4) return error.TruncatedData;
    const value = std.mem.readInt(u32, data[cursor.*..][0..4], .little);
    cursor.* += 4;
    return value;
}

fn skip(data: []const u8, cursor: *usize, count: usize) bio.ReaderError!void {
    if (cursor.* > data.len or data.len - cursor.* < count) return error.TruncatedData;
    cursor.* += count;
}

fn boundedDimension(value: u32) u16 {
    return @intCast(@min(@max(value, 1), std.math.maxInt(u16)));
}

fn planeByteCount(width: u32, height: u32) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, width, height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, 2) catch return error.UnsupportedVariant;
}

fn appendU16(list: *std.ArrayList(u8), value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendU32(list: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendFixture(list: *std.ArrayList(u8)) !void {
    try list.appendSlice(std.testing.allocator, magic);
    try list.appendNTimes(std.testing.allocator, 0, 20 - magic.len);
    try appendU16(list, 1);
    try list.append(std.testing.allocator, 'A');
    try appendU32(list, 0);
    try list.append(std.testing.allocator, 0);
    try appendU16(list, 1);
    try list.append(std.testing.allocator, 'x');
    try appendU16(list, 3);
    try list.appendNTimes(std.testing.allocator, 0, 26);
    try list.append(std.testing.allocator, 3);
    try list.appendSlice(std.testing.allocator, "PMT");
    try list.appendNTimes(std.testing.allocator, 0, 6);
    try appendU32(list, 2);
    try appendU32(list, 1);
    try appendU32(list, 2);
    try appendU32(list, 1);
    try list.appendNTimes(std.testing.allocator, 0, 16);
    try list.appendNTimes(std.testing.allocator, 0, 4);
    try appendU16(list, 1);
    try appendU16(list, 2);
    try appendU16(list, 3);
    try appendU16(list, 4);
}

test "reads imspector first raw uint16 block" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendFixture(&data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("imspector", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 4, 0 }, plane.data);
}
