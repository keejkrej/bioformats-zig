const std = @import("std");
const bio = @import("../root.zig");

const max_image_bytes = 512 * 1024 * 1024;
const hdf5_signature = "\x89HDF\r\n\x1a\n";

const Dataset = struct {
    size_z: u16,
    height: u32,
    width: u32,
    element_size: u8,
    data_offset: usize,
    data_size: usize,
};

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
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const zct = try planeToZct(metadata, plane_index);
    const dataset_index = std.math.add(usize, std.math.mul(usize, zct.t, metadata.size_c) catch return error.UnsupportedVariant, zct.c) catch return error.UnsupportedVariant;
    const dataset = findDataset(data, metadata, dataset_index) orelse return error.UnsupportedVariant;
    if (dataset.element_size != metadata.bytesPerPixel()) return error.UnsupportedVariant;
    const plane_len = try planeByteCount(metadata);
    const z_offset = std.math.mul(usize, zct.z, plane_len) catch return error.UnsupportedVariant;
    if (z_offset + plane_len > dataset.data_size) return error.TruncatedData;
    const offset = dataset.data_offset + z_offset;
    if (offset + plane_len > data.len) return error.TruncatedData;
    const out = try allocator.dupe(u8, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    if (!isPath(path)) return error.InvalidFormat;
    const data = try readFile(allocator, io, path);
    defer allocator.free(data);
    const plane = try readPlaneIndex(allocator, data, plane_index);
    errdefer allocator.free(plane.data);
    try region.validate(plane.metadata);
    if (region.isFull(plane.metadata)) return plane;
    defer allocator.free(plane.data);
    return .{
        .metadata = plane.metadata,
        .data = try bio.cropPlane(allocator, plane, region),
    };
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

const Zct = struct {
    z: usize,
    c: usize,
    t: usize,
};

fn planeToZct(metadata: bio.Metadata, plane_index: u32) bio.ReaderError!Zct {
    const zc = std.math.mul(u32, metadata.size_z, metadata.size_c) catch return error.InvalidPlaneIndex;
    return .{
        .z = plane_index % metadata.size_z,
        .c = (plane_index / metadata.size_z) % metadata.size_c,
        .t = plane_index / zc,
    };
}

fn findDataset(data: []const u8, metadata: bio.Metadata, target_index: usize) ?Dataset {
    var seen: usize = 0;
    var offset: usize = 0;
    while (offset + 64 <= data.len) : (offset += 1) {
        const dataset = parseObjectHeaderForZyx(data, offset) orelse continue;
        if (dataset.width != metadata.width or dataset.height != metadata.height or dataset.size_z != metadata.size_z) continue;
        const expected_size = planeByteCount(metadata) catch return null;
        const expected_stack = std.math.mul(usize, expected_size, metadata.size_z) catch return null;
        if (dataset.data_size < expected_stack) continue;
        if (seen == target_index) return dataset;
        seen += 1;
    }
    return null;
}

fn parseObjectHeaderForZyx(data: []const u8, offset: usize) ?Dataset {
    if (data[offset] != 1 or data[offset + 1] != 0) return null;
    const message_count = readU16(data, offset + 2);
    if (message_count == 0 or message_count > 32) return null;
    const ref_count = readU32(data, offset + 4);
    const header_size = readU32(data, offset + 8);
    if (ref_count == 0 or header_size == 0 or header_size > 4096) return null;

    var dims: ?[3]u64 = null;
    var element_size: ?u8 = null;
    var data_offset: ?usize = null;
    var data_size: ?usize = null;
    var has_filter_pipeline = false;
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
            dims = parseDataspaceMessage(data[payload..end]);
        } else if (message_type == 3 and message_size >= 4) {
            const size = data[payload + 3];
            if (size == 1 or size == 2 or size == 4) element_size = size;
        } else if (message_type == 8) {
            if (parseContiguousLayoutMessage(data[payload..end])) |layout| {
                data_offset = layout.offset;
                data_size = layout.size;
            }
        } else if (message_type == 11) {
            has_filter_pipeline = true;
        }

        pos = end;
        const relative = pos - offset;
        if (relative % 8 != 0) pos += 8 - (relative % 8);
    }
    if (has_filter_pipeline) return null;
    const shape = dims orelse return null;
    if (shape[0] > std.math.maxInt(u16) or shape[1] > std.math.maxInt(u32) or shape[2] > std.math.maxInt(u32)) return null;
    return .{
        .size_z = @intCast(shape[0]),
        .height = @intCast(shape[1]),
        .width = @intCast(shape[2]),
        .element_size = element_size orelse 1,
        .data_offset = data_offset orelse return null,
        .data_size = data_size orelse return null,
    };
}

fn parseDataspaceMessage(payload: []const u8) ?[3]u64 {
    if (payload.len < 8) return null;
    const version = payload[0];
    const rank = payload[1];
    if ((version != 1 and version != 2) or rank != 3) return null;
    var dims: [3]u64 = undefined;
    var pos: usize = 8;
    for (&dims) |*dim| {
        if (pos + 8 > payload.len) return null;
        dim.* = std.mem.readInt(u64, payload[pos..][0..8], .little);
        if (dim.* == 0 or dim.* > 1_000_000) return null;
        pos += 8;
    }
    return dims;
}

const Layout = struct {
    offset: usize,
    size: usize,
};

fn parseContiguousLayoutMessage(payload: []const u8) ?Layout {
    if (payload.len < 18 or payload[0] != 3 or payload[1] != 1) return null;
    const offset = std.mem.readInt(u64, payload[2..][0..8], .little);
    const size = std.mem.readInt(u64, payload[10..][0..8], .little);
    if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize) or size == 0) return null;
    return .{ .offset = @intCast(offset), .size = @intCast(size) };
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
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

fn appendObjectHeaderWithLayout(list: *std.ArrayList(u8), allocator: std.mem.Allocator, data_offset: usize, data_size: usize) !void {
    try list.appendSlice(allocator, &.{
        1,   0, 3,  0,
        1,   0, 0,  0,
        128, 0, 0,  0,
        0,   0, 0,  0,
        1,   0, 56, 0,
        0,   0, 0,  0,
        1,   3, 1,  0,
        0,   0, 0,  0,
    });
    for ([_]u64{ 2, 2, 3 }) |value| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try list.appendSlice(allocator, &bytes);
    }
    for ([_]u64{ 2, 2, 3 }) |value| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try list.appendSlice(allocator, &bytes);
    }
    try list.appendSlice(allocator, &.{
        3, 0, 8,  0,
        0, 0, 0,  0,
        1, 3, 0,  1,
        0, 0, 0,  0,
        8, 0, 24, 0,
        0, 0, 0,  0,
        3, 1,
    });
    var offset_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &offset_bytes, @intCast(data_offset), .little);
    try list.appendSlice(allocator, &offset_bytes);
    var size_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &size_bytes, @intCast(data_size), .little);
    try list.appendSlice(allocator, &size_bytes);
    try list.appendNTimes(allocator, 0, 6);
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

test "reads imaris hdf contiguous uncompressed zyx plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, hdf5_signature ++
        "Imaris\x00DataSetInfo\x00Channel 0\x00Channel 1\x00" ++
        "ImageSizeX\x00\x13\x00\x00\x003" ++
        "ImageSizeY\x00\x13\x00\x00\x002" ++
        "ImageSizeZ\x00\x13\x00\x00\x002" ++
        "NumberOfChannels\x00\x13\x00\x00\x002" ++
        "FileTimePoints\x00\x13\x00\x00\x001");
    try data.appendNTimes(std.testing.allocator, 0, 32);
    const first_header_offset = data.items.len;
    const first_raw_offset = first_header_offset + 128;
    try appendObjectHeaderWithLayout(&data, std.testing.allocator, first_raw_offset, 12);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 });
    const second_header_offset = data.items.len;
    const second_raw_offset = second_header_offset + 128;
    try appendObjectHeaderWithLayout(&data, std.testing.allocator, second_raw_offset, 12);
    try data.appendSlice(std.testing.allocator, &.{ 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32 });

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 2);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("imarishdf", plane.metadata.format);
    try std.testing.expectEqual(@as(u32, 3), plane.metadata.width);
    try std.testing.expectEqual(@as(u32, 2), plane.metadata.height);
    try std.testing.expectEqual(@as(u16, 2), plane.metadata.size_z);
    try std.testing.expectEqual(@as(u16, 2), plane.metadata.size_c);
    try std.testing.expectEqualSlices(u8, &.{ 21, 22, 23, 24, 25, 26 }, plane.data);
}

test "rejects non-hdf imaris metadata" {
    try std.testing.expect(!matches("Imaris ImageSizeX 1 ImageSizeY 1"));
    try std.testing.expectError(error.InvalidFormat, readMetadata("not hdf"));
}
