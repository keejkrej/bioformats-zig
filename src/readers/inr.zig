const std = @import("std");
const bio = @import("../root.zig");

const magic = "#INRIMAGE";
const header_len = 256;

const Header = struct {
    width: u32,
    height: u32,
    size_z: u32,
    size_t: u32,
    pixel_type: bio.PixelType,
};

pub fn matches(data: []const u8) bool {
    return data.len >= magic.len and std.mem.startsWith(u8, data, magic);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "inr",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.size_z, std.math.maxInt(u16))),
        .size_t = @intCast(@min(header.size_t, std.math.maxInt(u16))),
        .pixel_type = header.pixel_type,
        .little_endian = false,
        .plane_count = std.math.mul(u32, header.size_z, header.size_t) catch return error.UnsupportedVariant,
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
    if (data.len < header_len) return error.InvalidFormat;
    if (!matches(data)) return error.InvalidFormat;
    const bytes = data[0..header_len];
    var width: u32 = 0;
    var height: u32 = 0;
    var size_z: u32 = 1;
    var size_t: u32 = 1;
    var signed = false;
    var bits: u32 = 0;

    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\x00");
        if (line.len == 0 or std.mem.startsWith(u8, line, magic) or std.mem.eql(u8, line, "##}")) continue;
        const sep = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..sep], " \t");
        const value = std.mem.trim(u8, line[sep + 1 ..], " \t");
        if (std.mem.eql(u8, key, "XDIM")) {
            width = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "YDIM")) {
            height = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "ZDIM")) {
            size_z = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "VDIM")) {
            size_t = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "TYPE")) {
            signed = startsWithIgnoreCase(value, "signed");
        } else if (std.mem.eql(u8, key, "PIXSIZE")) {
            bits = try parseLeadingU32(value);
        }
    }
    if (width == 0 or height == 0 or bits == 0) return error.InvalidFormat;
    return .{
        .width = width,
        .height = height,
        .size_z = size_z,
        .size_t = size_t,
        .pixel_type = try pixelType(bits, signed),
    };
}

fn pixelType(bits: u32, signed: bool) bio.ReaderError!bio.PixelType {
    return switch (bits) {
        8 => if (signed) .int8 else .uint8,
        16 => if (signed) .int16 else .uint16,
        32 => if (signed) .int32 else .uint32,
        else => error.UnsupportedVariant,
    };
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn parseLeadingU32(value: []const u8) bio.ReaderError!u32 {
    var end: usize = 0;
    while (end < value.len and std.ascii.isDigit(value[end])) end += 1;
    if (end == 0) return error.InvalidFormat;
    return parsePositiveU32(value[0..end]);
}

fn parsePositiveU32(value: []const u8) bio.ReaderError!u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidFormat;
    if (parsed == 0) return error.InvalidFormat;
    return parsed;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(list: *std.ArrayList(u8), header: []const u8) !void {
    try list.appendSlice(std.testing.allocator, header);
    if (list.items.len > header_len) return error.InvalidFormat;
    try list.appendNTimes(std.testing.allocator, 0, header_len - list.items.len);
}

test "reads 8-bit inr image" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data,
        "#INRIMAGE-4#{\n" ++
            "XDIM=2\n" ++
            "YDIM=1\n" ++
            "ZDIM=1\n" ++
            "VDIM=1\n" ++
            "TYPE=unsigned fixed\n" ++
            "PIXSIZE=8 bits\n" ++
            "##}\n");
    try data.appendSlice(std.testing.allocator, &.{ 7, 9 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "reads signed 16-bit inr z/t plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data,
        "#INRIMAGE-4#{\n" ++
            "XDIM=1\n" ++
            "YDIM=1\n" ++
            "ZDIM=2\n" ++
            "VDIM=2\n" ++
            "TYPE=signed fixed\n" ++
            "PIXSIZE=16 bits\n" ++
            "##}\n");
    try data.appendSlice(std.testing.allocator, &.{ 0, 1, 0, 2, 0, 3, 0, 4 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 4), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(bio.PixelType.int16, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 2);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 3 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 4));
}

test "rejects unsupported inr pixel size" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data,
        "#INRIMAGE-4#{\n" ++
            "XDIM=1\n" ++
            "YDIM=1\n" ++
            "TYPE=unsigned fixed\n" ++
            "PIXSIZE=12 bits\n" ++
            "##}\n");

    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}
