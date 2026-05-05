const std = @import("std");
const bio = @import("../root.zig");

const Header = struct {
    width: u32,
    height: u32,
    planes: u32,
    pixel_type: bio.PixelType,
    little_endian: bool,
    data_offset: usize,
};

pub fn matches(data: []const u8) bool {
    return std.mem.startsWith(u8, data, "NRRD");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "nrrd",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.planes, std.math.maxInt(u16))),
        .pixel_type = header.pixel_type,
        .little_endian = header.little_endian,
        .plane_count = header.planes,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const plane_offset = std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant;
    const offset = std.math.add(usize, header.data_offset, plane_offset) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    var cursor: usize = 0;
    const magic = try nextLine(data, &cursor);
    if (magic.len < 8 or !std.mem.startsWith(u8, magic, "NRRD")) return error.InvalidFormat;

    var pixel_type: ?bio.PixelType = null;
    var dimension: ?u32 = null;
    var sizes: [3]u32 = .{ 0, 0, 1 };
    var encoding: ?[]const u8 = null;
    var endian: ?[]const u8 = null;
    var byte_skip: usize = 0;

    while (true) {
        const line = try nextLine(data, &cursor);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) break;
        if (trimmed[0] == '#') continue;
        const sep = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidFormat;
        const key = std.mem.trim(u8, trimmed[0..sep], " \t");
        const value = std.mem.trim(u8, trimmed[sep + 1 ..], " \t");
        if (std.mem.eql(u8, key, "type")) {
            pixel_type = try parsePixelType(value);
        } else if (std.mem.eql(u8, key, "dimension")) {
            dimension = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "sizes")) {
            sizes = try parseSizes(value);
        } else if (std.mem.eql(u8, key, "encoding")) {
            encoding = value;
        } else if (std.mem.eql(u8, key, "endian")) {
            endian = value;
        } else if (std.mem.eql(u8, key, "data file") or std.mem.eql(u8, key, "datafile")) {
            return error.UnsupportedVariant;
        } else if (std.mem.eql(u8, key, "byte skip") or std.mem.eql(u8, key, "byteskip")) {
            byte_skip = std.fmt.parseInt(usize, value, 10) catch return error.UnsupportedVariant;
        }
    }

    const dims = dimension orelse return error.InvalidFormat;
    if (dims < 2 or dims > 3) return error.UnsupportedVariant;
    const kind = pixel_type orelse return error.InvalidFormat;
    const enc = encoding orelse return error.InvalidFormat;
    if (!std.mem.eql(u8, enc, "raw")) return error.UnsupportedVariant;

    const bytes_per_sample = kind.bytesPerSample();
    const little = if (bytes_per_sample == 1) false else blk: {
        const order = endian orelse return error.InvalidFormat;
        if (std.mem.eql(u8, order, "little")) break :blk true;
        if (std.mem.eql(u8, order, "big")) break :blk false;
        return error.InvalidFormat;
    };
    const data_offset = std.math.add(usize, cursor, byte_skip) catch return error.UnsupportedVariant;
    if (data_offset > data.len) return error.TruncatedData;
    return .{
        .width = sizes[0],
        .height = sizes[1],
        .planes = if (dims == 3) sizes[2] else 1,
        .pixel_type = kind,
        .little_endian = little,
        .data_offset = data_offset,
    };
}

fn nextLine(data: []const u8, cursor: *usize) bio.ReaderError![]const u8 {
    if (cursor.* >= data.len) return error.TruncatedData;
    const start = cursor.*;
    while (cursor.* < data.len and data[cursor.*] != '\n') cursor.* += 1;
    var end = cursor.*;
    if (cursor.* < data.len) cursor.* += 1;
    if (end > start and data[end - 1] == '\r') end -= 1;
    return data[start..end];
}

fn parsePixelType(value: []const u8) bio.ReaderError!bio.PixelType {
    if (std.mem.eql(u8, value, "uchar") or std.mem.eql(u8, value, "unsigned char") or std.mem.eql(u8, value, "uint8") or std.mem.eql(u8, value, "uint8_t")) return .uint8;
    if (std.mem.eql(u8, value, "char") or std.mem.eql(u8, value, "signed char") or std.mem.eql(u8, value, "int8") or std.mem.eql(u8, value, "int8_t")) return .int8;
    if (std.mem.eql(u8, value, "ushort") or std.mem.eql(u8, value, "unsigned short") or std.mem.eql(u8, value, "uint16") or std.mem.eql(u8, value, "uint16_t")) return .uint16;
    if (std.mem.eql(u8, value, "short") or std.mem.eql(u8, value, "signed short") or std.mem.eql(u8, value, "int16") or std.mem.eql(u8, value, "int16_t")) return .int16;
    if (std.mem.eql(u8, value, "uint") or std.mem.eql(u8, value, "unsigned int") or std.mem.eql(u8, value, "uint32") or std.mem.eql(u8, value, "uint32_t")) return .uint32;
    if (std.mem.eql(u8, value, "int") or std.mem.eql(u8, value, "signed int") or std.mem.eql(u8, value, "int32") or std.mem.eql(u8, value, "int32_t")) return .int32;
    if (std.mem.eql(u8, value, "float")) return .float32;
    if (std.mem.eql(u8, value, "double")) return .float64;
    return error.UnsupportedVariant;
}

fn parseSizes(value: []const u8) bio.ReaderError![3]u32 {
    var sizes: [3]u32 = .{ 0, 0, 1 };
    var iter = std.mem.tokenizeScalar(u8, value, ' ');
    var i: usize = 0;
    while (iter.next()) |token| {
        if (i >= sizes.len) return error.UnsupportedVariant;
        sizes[i] = try parsePositiveU32(token);
        i += 1;
    }
    if (i < 2) return error.InvalidFormat;
    return sizes;
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

test "reads raw 8-bit nrrd image" {
    const data =
        "NRRD0005\n" ++
        "type: uint8\n" ++
        "dimension: 2\n" ++
        "sizes: 2 1\n" ++
        "encoding: raw\n" ++
        "\n" ++
        [_]u8{ 7, 9 };

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "reads raw 16-bit nrrd z plane" {
    const data =
        "NRRD0005\n" ++
        "type: ushort\n" ++
        "dimension: 3\n" ++
        "sizes: 1 1 2\n" ++
        "endian: little\n" ++
        "encoding: raw\n" ++
        "\n" ++
        [_]u8{ 0x34, 0x12, 0xcd, 0xab };

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0xcd, 0xab }, plane.data);
}

test "rejects gzip nrrd encoding" {
    const data =
        "NRRD0005\n" ++
        "type: uint8\n" ++
        "dimension: 2\n" ++
        "sizes: 1 1\n" ++
        "encoding: gzip\n" ++
        "\n" ++
        [_]u8{7};

    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data));
}
