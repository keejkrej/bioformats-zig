const std = @import("std");
const bio = @import("../root.zig");

const header_len = 348;
const magic_offset = 344;

const Header = struct {
    little_endian: bool,
    width: u32,
    height: u32,
    size_z: u16,
    size_t: u16,
    size_c: u16,
    samples_per_pixel: u16,
    pixel_type: bio.PixelType,
    pixel_offset: usize,
    plane_count: u32,
    description: ?[]const u8,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "nifti",
        .width = header.width,
        .height = header.height,
        .size_c = header.size_c,
        .samples_per_pixel = header.samples_per_pixel,
        .pixel_type = header.pixel_type,
    }) catch return false;
    const pixel_bytes = std.math.mul(usize, plane_len, header.plane_count) catch return false;
    return data.len >= header.pixel_offset and data.len - header.pixel_offset >= pixel_bytes;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "nifti",
        .width = header.width,
        .height = header.height,
        .size_c = header.size_c,
        .samples_per_pixel = header.samples_per_pixel,
        .size_z = header.size_z,
        .size_t = header.size_t,
        .pixel_type = header.pixel_type,
        .little_endian = header.little_endian,
        .plane_count = header.plane_count,
        .image_description = header.description,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const offset = std.math.add(usize, header.pixel_offset, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_len) return error.TruncatedData;
    if (!std.mem.eql(u8, data[magic_offset..][0..3], "n+1")) return error.InvalidFormat;

    const little_size = std.mem.readInt(i32, data[0..4], .little);
    const big_size = std.mem.readInt(i32, data[0..4], .big);
    const little = if (little_size == header_len)
        true
    else if (big_size == header_len)
        false
    else
        return error.InvalidFormat;
    const endian: std.builtin.Endian = if (little) .little else .big;

    const n_dimensions = readU16(data[40..42], endian);
    if (n_dimensions == 0 or n_dimensions > 7) return error.InvalidFormat;
    const width = readU16(data[42..44], endian);
    const height = readU16(data[44..46], endian);
    var size_z = readU16(data[46..48], endian);
    var size_t = readU16(data[48..50], endian);
    if (width == 0 or height == 0) return error.InvalidFormat;
    if (size_z == 0) size_z = 1;
    if (size_t == 0) size_t = 1;

    var extra_c: u32 = 1;
    if (n_dimensions > 4) {
        var i: usize = 0;
        while (i < n_dimensions - 4) : (i += 1) {
            const extra = readU16(data[50 + i * 2 ..][0..2], endian);
            if (extra != 0) extra_c = std.math.mul(u32, extra_c, extra) catch return error.UnsupportedVariant;
        }
    }

    const datatype = readU16(data[70..72], endian);
    const pixel_info = try pixelInfo(datatype, extra_c);
    const offset_float = readF32(data[108..112], endian);
    if (offset_float < header_len) return error.InvalidFormat;
    const pixel_offset: usize = @intFromFloat(offset_float);
    if (pixel_offset < header_len) return error.InvalidFormat;
    if (pixel_info.size_c > std.math.maxInt(u16)) return error.UnsupportedVariant;

    const plane_count = std.math.mul(u32, @as(u32, size_z), @as(u32, size_t)) catch return error.UnsupportedVariant;
    return .{
        .little_endian = little,
        .width = width,
        .height = height,
        .size_z = size_z,
        .size_t = size_t,
        .size_c = @intCast(pixel_info.size_c),
        .samples_per_pixel = pixel_info.samples_per_pixel,
        .pixel_type = pixel_info.pixel_type,
        .pixel_offset = pixel_offset,
        .plane_count = std.math.mul(u32, plane_count, pixel_info.plane_multiplier) catch return error.UnsupportedVariant,
        .description = optionalTrim(data[148..][0..80]),
    };
}

const PixelInfo = struct {
    pixel_type: bio.PixelType,
    size_c: u32,
    samples_per_pixel: u16,
    plane_multiplier: u32,
};

fn pixelInfo(datatype: u16, extra_c: u32) bio.ReaderError!PixelInfo {
    return switch (datatype) {
        1, 2 => scalar(.uint8, extra_c),
        4 => scalar(.int16, extra_c),
        8 => scalar(.int32, extra_c),
        16 => scalar(.float32, extra_c),
        64 => scalar(.float64, extra_c),
        256 => scalar(.int8, extra_c),
        512 => scalar(.uint16, extra_c),
        768 => scalar(.uint32, extra_c),
        128 => .{ .pixel_type = .uint8, .size_c = 3, .samples_per_pixel = 3, .plane_multiplier = 1 },
        2304 => .{ .pixel_type = .uint8, .size_c = 4, .samples_per_pixel = 4, .plane_multiplier = 1 },
        else => error.UnsupportedVariant,
    };
}

fn scalar(pixel_type: bio.PixelType, channels: u32) PixelInfo {
    return .{
        .pixel_type = pixel_type,
        .size_c = channels,
        .samples_per_pixel = 1,
        .plane_multiplier = channels,
    };
}

fn optionalTrim(bytes: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, bytes, " \t\r\n\x00");
    return if (value.len == 0) null else value;
}

fn readU16(bytes: []const u8, endian: std.builtin.Endian) u16 {
    return std.mem.readInt(u16, bytes[0..2], endian);
}

fn readF32(bytes: []const u8, endian: std.builtin.Endian) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[0..4], endian));
}

fn writeU16(bytes: []u8, offset: usize, value: u16, endian: std.builtin.Endian) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, endian);
}

fn writeI32(bytes: []u8, offset: usize, value: i32, endian: std.builtin.Endian) void {
    std.mem.writeInt(i32, bytes[offset..][0..4], value, endian);
}

fn writeF32(bytes: []u8, offset: usize, value: f32, endian: std.builtin.Endian) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], @bitCast(value), endian);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    const samples = std.math.mul(usize, pixels, metadata.samples_per_pixel) catch return error.UnsupportedVariant;
    return std.math.mul(usize, samples, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(
    list: *std.ArrayList(u8),
    endian: std.builtin.Endian,
    width: u16,
    height: u16,
    size_z: u16,
    size_t: u16,
    extra_c: u16,
    datatype: u16,
    pixel_start: usize,
) !void {
    try list.appendNTimes(std.testing.allocator, 0, pixel_start);
    writeI32(list.items, 0, header_len, endian);
    writeU16(list.items, 40, if (extra_c > 1) 5 else if (size_t > 1) 4 else if (size_z > 1) 3 else 2, endian);
    writeU16(list.items, 42, width, endian);
    writeU16(list.items, 44, height, endian);
    writeU16(list.items, 46, size_z, endian);
    writeU16(list.items, 48, size_t, endian);
    writeU16(list.items, 50, extra_c, endian);
    writeU16(list.items, 70, datatype, endian);
    writeF32(list.items, 108, @floatFromInt(pixel_start), endian);
    @memcpy(list.items[148..][0..10], "nifti note");
    @memcpy(list.items[magic_offset..][0..4], "n+1\x00");
}

test "reads nifti single-file uint16 z planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, .little, 2, 1, 2, 1, 1, 512, 352);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0, 3, 0, 4, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("nifti note", metadata.image_description.?);

    const second = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 4, 0 }, second.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads nifti big-endian rgb plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, .big, 1, 1, 1, 1, 1, 128, 352);
    try data.appendSlice(std.testing.allocator, &.{ 7, 8, 9 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 9 }, plane.data);
}

test "rejects nifti pair header without inline pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, .little, 1, 1, 1, 1, 1, 2, 352);
    @memcpy(data.items[magic_offset..][0..4], "ni1\x00");

    try std.testing.expect(!matches(data.items));
}

test "matches Bio-Formats default metadata for cached NIfTI fixture" {
    const file_path = "fixtures/cache/nifti/avg152T1_LR_nifti.nii";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("nifti", metadata.format);
    try std.testing.expectEqual(@as(u32, 91), metadata.width);
    try std.testing.expectEqual(@as(u32, 109), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 91), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 91), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 1), metadata.series_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
}

test "matches Bio-Formats default plane and region hashes for cached NIfTI fixture" {
    const file_path = "fixtures/cache/nifti/avg152T1_LR_nifti.nii";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const expected = [_]struct { plane: u32, sha256: [32]u8 }{
        .{ .plane = 0, .sha256 = .{ 0x5e, 0xf6, 0x0c, 0xfd, 0x10, 0xb2, 0x2a, 0xc9, 0x4e, 0x6b, 0xb3, 0x4d, 0x5d, 0xbc, 0xd8, 0x2f, 0xc9, 0xe5, 0xac, 0x71, 0x74, 0xa0, 0x44, 0x12, 0x52, 0x2d, 0x13, 0xf0, 0x50, 0x1b, 0xfd, 0x2a } },
        .{ .plane = 45, .sha256 = .{ 0xc5, 0xfd, 0x56, 0x21, 0xf0, 0x5c, 0xc7, 0x63, 0x5d, 0xb7, 0x66, 0x4f, 0xfd, 0xe9, 0x1e, 0x47, 0x13, 0xc3, 0x2a, 0xb8, 0x4a, 0xb2, 0x75, 0x61, 0xf0, 0xd0, 0xae, 0x30, 0xa5, 0x01, 0x4b, 0x1c } },
        .{ .plane = 90, .sha256 = .{ 0x07, 0xc1, 0x44, 0x3a, 0x8b, 0x58, 0x57, 0x8d, 0xe9, 0x02, 0xe7, 0xb1, 0xea, 0x31, 0x73, 0xf0, 0xbe, 0xe0, 0x4d, 0x97, 0x06, 0x80, 0xd0, 0x65, 0xc8, 0x71, 0xb7, 0x3d, 0xe0, 0x71, 0x29, 0x74 } },
    };
    for (expected) |sample| {
        const plane = try readPlaneIndex(std.testing.allocator, data, sample.plane);
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqual(@as(usize, 9919), plane.data.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
        try std.testing.expectEqualSlices(u8, &sample.sha256, &digest);
    }

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    const region_data = try bio.cropPlane(std.testing.allocator, plane, .{
        .x = 17,
        .y = 19,
        .width = 16,
        .height = 12,
    });
    defer std.testing.allocator.free(region_data);
    try std.testing.expectEqual(@as(usize, 192), region_data.len);
    const expected_region: [32]u8 = .{ 0xc3, 0x3a, 0x77, 0x0e, 0xc0, 0x97, 0x31, 0x54, 0xfd, 0xde, 0xbd, 0x6d, 0xcb, 0x33, 0x3b, 0xfd, 0xd4, 0x88, 0xfb, 0xd5, 0x89, 0xf3, 0xb3, 0xa7, 0xa1, 0xdb, 0x6e, 0x9a, 0x55, 0xa6, 0xeb, 0x5d };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(region_data, &digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_region, &digest);
}
