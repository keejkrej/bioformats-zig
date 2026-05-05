const std = @import("std");
const bio = @import("../root.zig");

const max_metadata_bytes = 64 * 1024 * 1024;
const hdf5_signature = "\x89HDF\r\n\x1a\n";

const Shape = struct {
    size_c: u16,
    size_t: u16,
    size_z: u16,
    height: u32,
    width: u32,
    pixel_type: bio.PixelType,
};

pub fn matches(data: []const u8) bool {
    return hasHdf5Signature(data) and hasCellH5Markers(data);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "ch5");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!matches(data)) return error.InvalidFormat;
    const shape = scanFirstCtzyxShape(data) orelse return error.InvalidFormat;
    const zc = std.math.mul(u32, shape.size_z, shape.size_c) catch return error.UnsupportedVariant;
    const plane_count = std.math.mul(u32, zc, shape.size_t) catch return error.UnsupportedVariant;
    return .{
        .format = "cellh5",
        .width = shape.width,
        .height = shape.height,
        .size_c = shape.size_c,
        .samples_per_pixel = 1,
        .size_z = shape.size_z,
        .size_t = shape.size_t,
        .pixel_type = shape.pixel_type,
        .little_endian = true,
        .plane_count = plane_count,
        .dimension_order = "XYZTC",
    };
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    if (!isPath(path)) return error.InvalidFormat;
    const data = try readFileHeader(allocator, io, path);
    defer allocator.free(data);
    return readMetadata(data);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    _ = allocator;
    _ = io;
    _ = path;
    _ = plane_index;
    _ = region;
    return error.UnsupportedVariant;
}

fn hasHdf5Signature(data: []const u8) bool {
    return data.len >= hdf5_signature.len and std.mem.eql(u8, data[0..hdf5_signature.len], hdf5_signature);
}

fn hasCellH5Markers(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "sample") != null and
        std.mem.indexOf(u8, data, "plate") != null and
        std.mem.indexOf(u8, data, "experiment") != null and
        std.mem.indexOf(u8, data, "position") != null and
        std.mem.indexOf(u8, data, "image") != null and
        std.mem.indexOf(u8, data, "channel") != null;
}

fn scanFirstCtzyxShape(data: []const u8) ?Shape {
    var offset: usize = 0;
    while (offset + 64 <= data.len) : (offset += 1) {
        const candidate = parseObjectHeaderForCtzyx(data, offset) orelse continue;
        return candidate;
    }
    return null;
}

fn parseObjectHeaderForCtzyx(data: []const u8, offset: usize) ?Shape {
    if (data[offset] != 1 or data[offset + 1] != 0) return null;
    const message_count = readU16(data, offset + 2);
    if (message_count == 0 or message_count > 32) return null;
    const ref_count = readU32(data, offset + 4);
    const header_size = readU32(data, offset + 8);
    if (ref_count == 0 or header_size == 0 or header_size > 4096) return null;

    var shape: ?Shape = null;
    var element_size: ?u8 = null;
    var pos = offset + 16;
    var i: u16 = 0;
    while (i < message_count) : (i += 1) {
        if (pos + 8 > data.len) return null;
        const message_type = readU16(data, pos);
        const message_size = readU16(data, pos + 2);
        const payload = pos + 8;
        const end = payload + @as(usize, message_size);
        if (end > data.len) return null;

        if (message_type == 1) {
            if (parseDataspaceMessage(data[payload..end])) |dims| {
                shape = shapeFromDims(dims, element_size orelse 1);
            }
        } else if (message_type == 3 and message_size >= 4) {
            const size = data[payload + 3];
            if (size == 1 or size == 2 or size == 4) {
                element_size = size;
                if (shape) |*existing| existing.pixel_type = pixelTypeForElementSize(size);
            }
        }

        pos = end;
        if (pos % 8 != 0) pos += 8 - (pos % 8);
    }
    return shape;
}

fn readFileHeader(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const capacity: usize = @intCast(@min(stat.size, max_metadata_bytes));
    const buffer = try allocator.alloc(u8, capacity);
    errdefer allocator.free(buffer);

    const read = try file.readPositionalAll(io, buffer, 0);
    return allocator.realloc(buffer, read);
}

fn parseDataspaceMessage(payload: []const u8) ?[5]u64 {
    if (payload.len < 8) return null;
    const version = payload[0];
    const rank = payload[1];
    if ((version != 1 and version != 2) or rank != 5) return null;
    var dims: [5]u64 = undefined;
    var pos: usize = 8;
    for (&dims) |*dim| {
        if (pos + 8 > payload.len) return null;
        dim.* = std.mem.readInt(u64, payload[pos..][0..8], .little);
        if (dim.* == 0 or dim.* > 1_000_000) return null;
        pos += 8;
    }
    return dims;
}

fn shapeFromDims(dims: [5]u64, element_size: u8) ?Shape {
    if (dims[0] > std.math.maxInt(u16) or dims[1] > std.math.maxInt(u16) or dims[2] > std.math.maxInt(u16)) return null;
    if (dims[3] > std.math.maxInt(u32) or dims[4] > std.math.maxInt(u32)) return null;
    return .{
        .size_c = @intCast(dims[0]),
        .size_t = @intCast(dims[1]),
        .size_z = @intCast(dims[2]),
        .height = @intCast(dims[3]),
        .width = @intCast(dims[4]),
        .pixel_type = pixelTypeForElementSize(element_size),
    };
}

fn pixelTypeForElementSize(element_size: u8) bio.PixelType {
    return switch (element_size) {
        1 => .uint8,
        2 => .uint16,
        4 => .int32,
        else => .uint8,
    };
}

fn readU16(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn appendObjectHeader(list: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try list.appendSlice(allocator, &.{
        1,   0, 2,  0,
        1,   0, 0,  0,
        128, 0, 0,  0,
        0,   0, 0,  0,
        1,   0, 88, 0,
        0,   0, 0,  0,
        1,   5, 1,  0,
        0,   0, 0,  0,
    });
    for ([_]u64{ 2, 206, 1, 1040, 1392 }) |value| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try list.appendSlice(allocator, &bytes);
    }
    for ([_]u64{ 2, 206, 1, 1040, 1392 }) |value| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try list.appendSlice(allocator, &bytes);
    }
    try list.appendSlice(allocator, &.{
        3, 0, 8, 0,
        0, 0, 0, 0,
        2, 3, 0, 1,
        0, 0, 0, 0,
    });
}

test "reads cellh5 metadata from hdf5 ctzyx dataspace" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, hdf5_signature);
    try data.appendSlice(std.testing.allocator, "sample\x00plate\x00experiment\x00position\x00image\x00channel\x00");
    try data.appendNTimes(std.testing.allocator, 0, 64);
    try appendObjectHeader(&data, std.testing.allocator);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("cellh5", metadata.format);
    try std.testing.expectEqual(@as(u32, 1392), metadata.width);
    try std.testing.expectEqual(@as(u32, 1040), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 206), metadata.size_t);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 412), metadata.plane_count);
}

test "rejects non-cellh5 hdf data" {
    try std.testing.expectError(error.InvalidFormat, readMetadata(hdf5_signature ++ "not a cellh5 file"));
}
