const std = @import("std");
const bio = @import("../root.zig");

const max_header_len = 1024;

const Header = struct {
    width: u32,
    height: u32,
    pixel_offset: usize,
    description: ?[]const u8,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "quesant",
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
        .format = "quesant",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint16,
        .little_endian = true,
        .image_description = header.description,
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
    if (data.len < 10) return error.TruncatedData;
    var image_offset: ?usize = null;
    var description: ?[]const u8 = null;
    const table_len = @min(data.len, max_header_len);
    var pos: usize = 0;
    while (pos + 8 <= table_len) : (pos += 8) {
        const code = data[pos..][0..4];
        const offset = readU32(data[pos + 4 ..][0..4]);
        if (offset == 0 or offset >= data.len) continue;
        if (std.mem.eql(u8, code, "IMAG")) {
            image_offset = offset;
        } else if (std.mem.eql(u8, code, "SDES")) {
            description = cString(data[offset..]);
        } else if (std.mem.eql(u8, code, "DESC")) {
            if (data.len - offset < 2) return error.TruncatedData;
            const length = readU16(data[offset..][0..2]);
            if (data.len - offset - 2 < length) return error.TruncatedData;
            description = trimmed(data[offset + 2 ..][0..length]);
        }
    }

    const image_start = image_offset orelse return error.InvalidFormat;
    if (data.len - image_start < 2) return error.TruncatedData;
    const width = readU16(data[image_start..][0..2]);
    if (width == 0) return error.InvalidFormat;
    return .{
        .width = width,
        .height = width,
        .pixel_offset = image_start + 2,
        .description = description,
    };
}

fn cString(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return trimmed(bytes[0..end]);
}

fn trimmed(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n\x00");
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
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn writeEntry(bytes: []u8, pos: usize, code: []const u8, offset: u32) void {
    @memcpy(bytes[pos..][0..4], code);
    writeU32(bytes, pos + 4, offset);
}

fn appendBase(list: *std.ArrayList(u8), image_offset: u32) !void {
    try list.appendNTimes(std.testing.allocator, 0, image_offset);
    writeEntry(list.items, 0, "IMAG", image_offset);
}

test "reads quesant afm uint16 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendBase(&data, 64);
    writeU16(try data.addManyAsSlice(std.testing.allocator, 2), 0, 2);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0, 3, 0, 4, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0, 3, 0, 4, 0 }, plane.data);
}

test "reads quesant description variable" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendBase(&data, 96);
    writeEntry(data.items, 8, "DESC", 64);
    writeU16(data.items, 64, 11);
    @memcpy(data.items[66..][0..11], "AFM comment");
    writeU16(try data.addManyAsSlice(std.testing.allocator, 2), 0, 1);
    try data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("AFM comment", metadata.image_description.?);
}

test "rejects truncated quesant pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendBase(&data, 64);
    writeU16(try data.addManyAsSlice(std.testing.allocator, 2), 0, 2);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0 });

    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}

