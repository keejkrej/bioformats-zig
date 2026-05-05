const std = @import("std");
const bio = @import("../root.zig");

const max_image_bytes = 512 * 1024 * 1024;
const hdf5_signature = "\x89HDF\r\n\x1a\n";

pub fn matches(data: []const u8) bool {
    if (!hasHdf5Signature(data)) return false;
    return std.mem.indexOf(u8, data, "Imaris") != null or
        std.mem.indexOf(u8, data, "DataSetInfo") != null or
        std.mem.indexOf(u8, data, "ResolutionLevel") != null;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "ims");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!matches(data)) return error.InvalidFormat;

    const width = positiveValueAfter(data, "ImageSizeX") orelse positiveValueAfter(data, "X") orelse return error.InvalidFormat;
    const height = positiveValueAfter(data, "ImageSizeY") orelse positiveValueAfter(data, "Y") orelse return error.InvalidFormat;
    const size_z_raw = positiveValueAfter(data, "ImageSizeZ") orelse positiveValueAfter(data, "Z") orelse 1;
    const size_t_raw = positiveValueAfter(data, "FileTimePoints") orelse positiveValueAfter(data, "DatasetTimePoints") orelse 1;
    const size_c_raw = positiveValueAfter(data, "NumberOfChannels") orelse countChannels(data) orelse 1;

    if (size_z_raw > std.math.maxInt(u16) or size_t_raw > std.math.maxInt(u16) or size_c_raw > std.math.maxInt(u16)) return error.UnsupportedVariant;
    const size_z: u16 = @intCast(size_z_raw);
    const size_t: u16 = @intCast(size_t_raw);
    const size_c: u16 = @intCast(size_c_raw);
    const zc = std.math.mul(u32, size_z, size_c) catch return error.UnsupportedVariant;
    const plane_count = std.math.mul(u32, zc, size_t) catch return error.UnsupportedVariant;

    return .{
        .format = "imarishdf",
        .width = width,
        .height = height,
        .size_c = size_c,
        .samples_per_pixel = 1,
        .size_z = size_z,
        .size_t = size_t,
        .pixel_type = .uint8,
        .little_endian = true,
        .plane_count = plane_count,
        .dimension_order = "XYZCT",
    };
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const data = try readFile(allocator, io, path);
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

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_image_bytes));
}

fn hasHdf5Signature(data: []const u8) bool {
    return data.len >= hdf5_signature.len and std.mem.eql(u8, data[0..hdf5_signature.len], hdf5_signature);
}

fn positiveValueAfter(data: []const u8, key: []const u8) ?u32 {
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, data, search_start, key)) |key_pos| {
        const start = key_pos + key.len;
        const end = @min(data.len, start + 128);
        if (firstPositiveAsciiInteger(data[start..end])) |value| return value;
        search_start = start;
    }
    return null;
}

fn firstPositiveAsciiInteger(bytes: []const u8) ?u32 {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (!std.ascii.isDigit(bytes[i])) continue;
        var value: u32 = 0;
        var j = i;
        while (j < bytes.len and std.ascii.isDigit(bytes[j])) : (j += 1) {
            value = std.math.mul(u32, value, 10) catch return null;
            value = std.math.add(u32, value, bytes[j] - '0') catch return null;
        }
        if (value > 0) return value;
        i = j;
    }
    return null;
}

fn countChannels(data: []const u8) ?u32 {
    var max_index: ?u32 = null;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, data, pos, "Channel ")) |channel_pos| {
        const digit_pos = channel_pos + "Channel ".len;
        if (digit_pos < data.len and std.ascii.isDigit(data[digit_pos])) {
            var value: u32 = 0;
            var i = digit_pos;
            while (i < data.len and std.ascii.isDigit(data[i])) : (i += 1) {
                value = std.math.mul(u32, value, 10) catch return null;
                value = std.math.add(u32, value, data[i] - '0') catch return null;
            }
            if (value < 1024) max_index = if (max_index) |current| @max(current, value) else value;
        }
        pos = digit_pos;
    }
    return if (max_index) |index| index + 1 else null;
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

const synthetic_ims = hdf5_signature ++
    "Imaris\x00DataSetInfo\x00Channel 0\x00Channel 1\x00" ++
    "ImageSizeX\x00\x13\x00\x00\x00143" ++
    "ImageSizeY\x00\x13\x00\x00\x00109" ++
    "ImageSizeZ\x00\x13\x00\x00\x0064" ++
    "FileTimePoints\x00\x13\x00\x00\x001";

test "reads imaris hdf metadata from compact attributes" {
    const metadata = try readMetadata(synthetic_ims);
    try std.testing.expectEqualStrings("imarishdf", metadata.format);
    try std.testing.expectEqual(@as(u32, 143), metadata.width);
    try std.testing.expectEqual(@as(u32, 109), metadata.height);
    try std.testing.expectEqual(@as(u16, 64), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u32, 128), metadata.plane_count);
}

test "rejects non-hdf imaris metadata" {
    try std.testing.expect(!matches("Imaris ImageSizeX 1 ImageSizeY 1"));
    try std.testing.expectError(error.InvalidFormat, readMetadata("not hdf"));
}
