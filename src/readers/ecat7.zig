const std = @import("std");
const bio = @import("../root.zig");

const magic = "MATRIX72v";
const header_size = 1536;

const Offset = struct {
    const size_z = 352;
    const size_t = 354;
    const data_type = 1024;
    const dimensions = 1026;
    const size_x = 1028;
    const size_y = 1030;
};

const Header = struct {
    width: u32,
    height: u32,
    size_z: u16,
    size_t: u16,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    const plane_count = std.math.mul(u32, header.size_z, header.size_t) catch return error.UnsupportedVariant;
    return .{
        .format = "ecat7",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = header.size_z,
        .size_t = header.size_t,
        .pixel_type = .uint16,
        .little_endian = false,
        .plane_count = plane_count,
        .dimension_order = "XYZTC",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const offset = try planeOffset(metadata, plane_index, plane_len);
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_size) return error.TruncatedData;
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return error.InvalidFormat;
    const data_type = readU16(data, Offset.data_type);
    if (data_type != 6) return error.UnsupportedVariant;
    const width = readU16(data, Offset.size_x);
    const height = readU16(data, Offset.size_y);
    const size_z = readU16(data, Offset.size_z);
    const size_t = readU16(data, Offset.size_t);
    if (width == 0 or height == 0 or size_z == 0 or size_t == 0) return error.InvalidFormat;
    _ = readU16(data, Offset.dimensions);
    const header: Header = .{
        .width = width,
        .height = height,
        .size_z = size_z,
        .size_t = size_t,
    };
    const metadata = bio.Metadata{
        .format = "ecat7",
        .width = header.width,
        .height = header.height,
        .size_z = header.size_z,
        .size_t = header.size_t,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint16,
        .plane_count = std.math.mul(u32, header.size_z, header.size_t) catch return error.UnsupportedVariant,
    };
    const plane_len = try planeByteCount(metadata);
    const last_offset = try planeOffset(metadata, metadata.plane_count - 1, plane_len);
    if (last_offset > data.len or data.len - last_offset < plane_len) return error.TruncatedData;
    return header;
}

fn planeOffset(metadata: bio.Metadata, plane_index: u32, plane_len: usize) bio.ReaderError!usize {
    const t = plane_index / metadata.size_z;
    var t_skip: usize = 0;
    var i: u32 = 0;
    while (i < t) : (i += 1) {
        t_skip = std.math.add(usize, t_skip, 512) catch return error.UnsupportedVariant;
        if (i > 0 and (i % 30) == 0) {
            t_skip = std.math.add(usize, t_skip, 512) catch return error.UnsupportedVariant;
        }
    }
    const plane_skip = std.math.mul(usize, plane_index, plane_len) catch return error.UnsupportedVariant;
    return std.math.add(usize, header_size, std.math.add(usize, plane_skip, t_skip) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn readU16(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .big);
}

fn writeU16(data: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, data[offset..][0..2], value, .big);
}

test "reads ecat7 uint16 planes with frame padding" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendNTimes(std.testing.allocator, 0, header_size + 512 + 4);
    @memcpy(data.items[0..magic.len], magic);
    writeU16(data.items, Offset.size_z, 1);
    writeU16(data.items, Offset.size_t, 2);
    writeU16(data.items, Offset.data_type, 6);
    writeU16(data.items, Offset.dimensions, 3);
    writeU16(data.items, Offset.size_x, 1);
    writeU16(data.items, Offset.size_y, 1);
    data.items[header_size] = 0x12;
    data.items[header_size + 1] = 0x34;
    data.items[header_size + 512 + 2] = 0xab;
    data.items[header_size + 512 + 3] = 0xcd;

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("ecat7", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, plane.data);
}

test "rejects unsupported ecat7 datatype" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendNTimes(std.testing.allocator, 0, header_size + 2);
    @memcpy(data.items[0..magic.len], magic);
    writeU16(data.items, Offset.size_z, 1);
    writeU16(data.items, Offset.size_t, 1);
    writeU16(data.items, Offset.data_type, 7);
    writeU16(data.items, Offset.size_x, 1);
    writeU16(data.items, Offset.size_y, 1);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}
