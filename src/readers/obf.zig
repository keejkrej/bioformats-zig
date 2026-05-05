const std = @import("std");
const bio = @import("../root.zig");

const file_magic = "OMAS_BF\n";
const stack_magic = "OMAS_BF_STACK\n";
const magic_number: u16 = 0xffff;
const max_dimensions = 15;

const Stack = struct {
    width: u32,
    height: u32,
    size_z: u16,
    size_c: u16,
    size_t: u16,
    plane_count: u32,
    pixel_type: bio.PixelType,
    data_offset: usize,
    data_len: usize,
};

pub fn matches(data: []const u8) bool {
    if (data.len < file_magic.len + 2 + 4) return false;
    if (!std.mem.eql(u8, data[0..file_magic.len], file_magic)) return false;
    if (readU16(data[file_magic.len..][0..2]) != magic_number) return false;
    return readI32(data[file_magic.len + 2 ..][0..4]) >= 0;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const stack = try parseHeader(data);
    return .{
        .format = "obf",
        .width = stack.width,
        .height = stack.height,
        .size_c = stack.size_c,
        .samples_per_pixel = 1,
        .size_z = stack.size_z,
        .size_t = stack.size_t,
        .pixel_type = stack.pixel_type,
        .little_endian = true,
        .plane_count = stack.plane_count,
        .dimension_order = "XYZCT",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const stack = try parseHeader(data);
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const offset = std.math.add(usize, stack.data_offset, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Stack {
    if (data.len < file_magic.len + 2 + 4 + 8 + 4) return error.TruncatedData;
    if (!std.mem.eql(u8, data[0..file_magic.len], file_magic)) return error.InvalidFormat;
    if (readU16(data[file_magic.len..][0..2]) != magic_number) return error.InvalidFormat;
    const version = readI32(data[file_magic.len + 2 ..][0..4]);
    if (version < 0) return error.InvalidFormat;
    const stack_pos = try usizeFromU64(readU64(data[file_magic.len + 2 + 4 ..][0..8]));
    if (stack_pos == 0) return error.InvalidFormat;
    var cursor: usize = file_magic.len + 2 + 4 + 8;
    const description_len = try usizeFromI32(readI32(data[cursor..][0..4]));
    cursor += 4;
    cursor = std.math.add(usize, cursor, description_len) catch return error.UnsupportedVariant;
    if (cursor > data.len) return error.TruncatedData;

    if (version >= 2) {
        if (cursor > data.len or data.len - cursor < 8) return error.TruncatedData;
    }

    return parseStack(data, stack_pos);
}

fn parseStack(data: []const u8, stack_pos: usize) bio.ReaderError!Stack {
    const fixed_len = stack_magic.len + 2 + 4 + 4 + max_dimensions * 4 + max_dimensions * 8 + max_dimensions * 8 + 4 + 4 + 4 + 4 + 4 + 8 + 8 + 8;
    if (stack_pos > data.len or data.len - stack_pos < fixed_len) return error.TruncatedData;
    var cursor = stack_pos;
    if (!std.mem.eql(u8, data[cursor..][0..stack_magic.len], stack_magic)) return error.InvalidFormat;
    cursor += stack_magic.len;
    if (readU16(data[cursor..][0..2]) != magic_number) return error.InvalidFormat;
    cursor += 2;
    const stack_version = readI32(data[cursor..][0..4]);
    cursor += 4;
    if (stack_version < 0) return error.InvalidFormat;

    const dimensions = try usizeFromI32(readI32(data[cursor..][0..4]));
    cursor += 4;
    if (dimensions == 0 or dimensions > 5) return error.UnsupportedVariant;

    var sizes = [_]u32{1} ** max_dimensions;
    var samples_written: u64 = 1;
    for (0..max_dimensions) |dimension| {
        const stored_size = readI32(data[cursor..][0..4]);
        cursor += 4;
        if (dimension < dimensions) {
            const size = try positiveU32FromI32(stored_size);
            sizes[dimension] = size;
            samples_written = std.math.mul(u64, samples_written, size) catch return error.UnsupportedVariant;
        }
    }

    cursor += max_dimensions * 8;
    cursor += max_dimensions * 8;
    const pixel_type = try pixelType(readI32(data[cursor..][0..4]));
    cursor += 4;
    const compression = readI32(data[cursor..][0..4]);
    cursor += 4;
    if (compression != 0) return error.UnsupportedVariant;
    cursor += 4;
    const name_len = try usizeFromI32(readI32(data[cursor..][0..4]));
    cursor += 4;
    const description_len = try usizeFromI32(readI32(data[cursor..][0..4]));
    cursor += 4;
    cursor += 8;
    const data_len = try usizeFromI64(readI64(data[cursor..][0..8]));
    cursor += 8;
    _ = readI64(data[cursor..][0..8]);
    cursor += 8;
    cursor = std.math.add(usize, cursor, name_len) catch return error.UnsupportedVariant;
    cursor = std.math.add(usize, cursor, description_len) catch return error.UnsupportedVariant;
    if (cursor > data.len) return error.TruncatedData;
    if (cursor > data.len or data.len - cursor < data_len) return error.TruncatedData;
    try validateFooterNoChunks(data, cursor, data_len, stack_version);

    const size_z = try u16FromU32(sizes[2]);
    const size_c = try u16FromU32(sizes[3]);
    const size_t = try u16FromU32(sizes[4]);
    const plane_count = std.math.mul(u32, sizes[2], std.math.mul(u32, sizes[3], sizes[4]) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    const expected_data_len = std.math.mul(usize, try usizeFromU64(samples_written), pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
    if (data_len < expected_data_len) return error.TruncatedData;

    return .{
        .width = sizes[0],
        .height = sizes[1],
        .size_z = size_z,
        .size_c = size_c,
        .size_t = size_t,
        .plane_count = plane_count,
        .pixel_type = pixel_type,
        .data_offset = cursor,
        .data_len = data_len,
    };
}

fn validateFooterNoChunks(data: []const u8, data_offset: usize, data_len: usize, stack_version: i32) bio.ReaderError!void {
    if (stack_version < 1) return;
    var cursor = std.math.add(usize, data_offset, data_len) catch return error.UnsupportedVariant;
    if (cursor > data.len or data.len - cursor < 4 + max_dimensions * 4 + max_dimensions * 4) return error.TruncatedData;
    _ = readI32(data[cursor..][0..4]);
    cursor += 4;
    cursor += max_dimensions * 4;
    cursor += max_dimensions * 4;

    if (stack_version >= 3) {
        const si_unit_size = 80;
        if (cursor > data.len or data.len - cursor < 4 + si_unit_size * (max_dimensions + 1) + 8 + 8) return error.TruncatedData;
        cursor += 4;
        cursor += si_unit_size * (max_dimensions + 1);
        _ = readI64(data[cursor..][0..8]);
        cursor += 8;
        _ = readI64(data[cursor..][0..8]);
        cursor += 8;
    }

    if (stack_version >= 4) {
        if (cursor > data.len or data.len - cursor < 8 + 8 + 4) return error.TruncatedData;
        cursor += 8;
        cursor += 8;
        cursor += 4;
    }

    if (stack_version >= 6) {
        if (cursor > data.len or data.len - cursor < 8 + 8 + 8) return error.TruncatedData;
        cursor += 8;
        _ = readI64(data[cursor..][0..8]);
        cursor += 8;
        const num_chunk_positions = readI64(data[cursor..][0..8]);
        if (num_chunk_positions < 0) return error.InvalidFormat;
        if (num_chunk_positions != 0) return error.UnsupportedVariant;
    }
}

fn pixelType(value: i32) bio.ReaderError!bio.PixelType {
    return switch (value) {
        0x01 => .uint8,
        0x02 => .int8,
        0x04 => .uint16,
        0x08 => .int16,
        0x10 => .uint32,
        0x20 => .int32,
        0x40 => .float32,
        0x80 => .float64,
        else => error.UnsupportedVariant,
    };
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn positiveU32FromI32(value: i32) bio.ReaderError!u32 {
    if (value <= 0) return error.InvalidFormat;
    return @intCast(value);
}

fn usizeFromI32(value: i32) bio.ReaderError!usize {
    if (value < 0) return error.InvalidFormat;
    return @intCast(value);
}

fn usizeFromI64(value: i64) bio.ReaderError!usize {
    if (value < 0) return error.InvalidFormat;
    if (@as(u64, @intCast(value)) > std.math.maxInt(usize)) return error.UnsupportedVariant;
    return @intCast(value);
}

fn usizeFromU64(value: u64) bio.ReaderError!usize {
    if (value > std.math.maxInt(usize)) return error.UnsupportedVariant;
    return @intCast(value);
}

fn u16FromU32(value: u32) bio.ReaderError!u16 {
    if (value == 0 or value > std.math.maxInt(u16)) return error.UnsupportedVariant;
    return @intCast(value);
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readI32(bytes: []const u8) i32 {
    return std.mem.readInt(i32, bytes[0..4], .little);
}

fn readI64(bytes: []const u8) i64 {
    return std.mem.readInt(i64, bytes[0..8], .little);
}

fn readU64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}

fn appendI32(list: *std.ArrayList(u8), value: i32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendU16(list: *std.ArrayList(u8), value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendI64(list: *std.ArrayList(u8), value: i64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendDouble(list: *std.ArrayList(u8), value: f64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @bitCast(value), .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendFileHeader(list: *std.ArrayList(u8), stack_pos: usize) !void {
    try list.appendSlice(std.testing.allocator, file_magic);
    try appendU16(list, magic_number);
    try appendI32(list, 0);
    try appendI64(list, @intCast(stack_pos));
    try appendI32(list, 0);
}

fn appendStackHeader(list: *std.ArrayList(u8), width: u32, height: u32, z: u32, c: u32, t: u32, pixel_type: i32, data_len: usize) !void {
    try appendStackHeaderVersion(list, 0, width, height, z, c, t, pixel_type, data_len);
}

fn appendStackHeaderVersion(list: *std.ArrayList(u8), stack_version: i32, width: u32, height: u32, z: u32, c: u32, t: u32, pixel_type: i32, data_len: usize) !void {
    try list.appendSlice(std.testing.allocator, stack_magic);
    try appendU16(list, magic_number);
    try appendI32(list, stack_version);
    try appendI32(list, 5);
    const sizes = [_]u32{ width, height, z, c, t };
    for (0..max_dimensions) |dimension| {
        const size = if (dimension < sizes.len) sizes[dimension] else 1;
        try appendI32(list, @intCast(size));
    }
    for (0..max_dimensions) |_| try appendDouble(list, 0);
    for (0..max_dimensions) |_| try appendDouble(list, 0);
    try appendI32(list, pixel_type);
    try appendI32(list, 0);
    try appendI32(list, 0);
    try appendI32(list, 0);
    try appendI32(list, 0);
    try appendI64(list, 0);
    try appendI64(list, @intCast(data_len));
    try appendI64(list, 0);
}

fn appendVersion1Footer(list: *std.ArrayList(u8)) !void {
    try appendI32(list, 0);
    for (0..max_dimensions) |_| try appendI32(list, 0);
    for (0..max_dimensions) |_| try appendI32(list, 0);
}

fn appendObf(list: *std.ArrayList(u8), width: u32, height: u32, z: u32, c: u32, t: u32, pixel_type: i32, pixels: []const u8) !void {
    try appendFileHeader(list, file_magic.len + 2 + 4 + 8 + 4);
    try appendStackHeader(list, width, height, z, c, t, pixel_type, pixels.len);
    try list.appendSlice(std.testing.allocator, pixels);
}

test "reads uncompressed obf uint8 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendObf(&data, 2, 1, 1, 1, 1, 0x01, &.{ 7, 8 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8 }, plane.data);
}

test "reads second uncompressed obf z plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendObf(&data, 1, 1, 2, 1, 1, 0x04, &.{ 1, 0, 2, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads newer uncompressed obf stack without chunks" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendFileHeader(&data, file_magic.len + 2 + 4 + 8 + 4);
    try appendStackHeaderVersion(&data, 1, 1, 1, 1, 1, 1, 0x01, 1);
    try data.append(std.testing.allocator, 9);
    try appendVersion1Footer(&data);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{9}, plane.data);
}

test "accepts zero unused obf dimension slots" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendFileHeader(&data, file_magic.len + 2 + 4 + 8 + 4);
    try data.appendSlice(std.testing.allocator, stack_magic);
    try appendU16(&data, magic_number);
    try appendI32(&data, 0);
    try appendI32(&data, 4);
    for ([_]i32{ 2, 1, 1, 1 }) |size| try appendI32(&data, size);
    for (4..max_dimensions) |_| try appendI32(&data, 0);
    for (0..max_dimensions) |_| try appendDouble(&data, 0);
    for (0..max_dimensions) |_| try appendDouble(&data, 0);
    try appendI32(&data, 0x01);
    try appendI32(&data, 0);
    try appendI32(&data, 0);
    try appendI32(&data, 0);
    try appendI32(&data, 0);
    try appendI64(&data, 0);
    try appendI64(&data, 2);
    try appendI64(&data, 0);
    try data.appendSlice(std.testing.allocator, &.{ 4, 5 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5 }, plane.data);
}

test "rejects compressed obf stack" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendFileHeader(&data, file_magic.len + 2 + 4 + 8 + 4);
    try data.appendSlice(std.testing.allocator, stack_magic);
    try appendU16(&data, magic_number);
    try appendI32(&data, 0);
    try appendI32(&data, 2);
    for (0..max_dimensions) |dimension| try appendI32(&data, if (dimension < 2) 1 else 1);
    for (0..max_dimensions) |_| try appendDouble(&data, 0);
    for (0..max_dimensions) |_| try appendDouble(&data, 0);
    try appendI32(&data, 0x01);
    try appendI32(&data, 1);
    try appendI32(&data, 0);
    try appendI32(&data, 0);
    try appendI32(&data, 0);
    try appendI64(&data, 0);
    try appendI64(&data, 1);
    try appendI64(&data, 0);
    try data.append(std.testing.allocator, 0);

    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}
