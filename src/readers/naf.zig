const std = @import("std");
const bio = @import("../root.zig");

const lut_size = 263168;
const entry_size = 256;
const first_series_count_offset = 98;
const description_offset = 192;

const Header = struct {
    endian: std.builtin.Endian,
    width: u32,
    height: u32,
    size_c: u16,
    size_z: u16,
    size_t: u16,
    plane_count: u32,
    pixel_type: bio.PixelType,
    pixel_offset: usize,
    description: ?[]const u8,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const bytes = totalByteCount(header) catch return false;
    return header.pixel_offset <= data.len and data.len - header.pixel_offset >= bytes;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "naf",
        .width = header.width,
        .height = header.height,
        .size_c = header.size_c,
        .samples_per_pixel = 1,
        .size_z = header.size_z,
        .size_t = header.size_t,
        .pixel_type = header.pixel_type,
        .little_endian = header.endian == .little,
        .plane_count = header.plane_count,
        .image_description = header.description,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    if (plane_index >= header.plane_count) return error.InvalidPlaneIndex;
    const metadata = try readMetadata(data);
    const plane_len = try planeByteCount(metadata);
    const plane_offset = std.math.add(usize, header.pixel_offset, std.math.mul(usize, plane_index, plane_len) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (plane_offset > data.len or data.len - plane_offset < plane_len) return error.TruncatedData;

    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[plane_offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < description_offset + 1) return error.TruncatedData;
    const endian = parseEndian(data[0..2]) orelse return error.InvalidFormat;
    const series_count = readU32(data[first_series_count_offset..][0..4], endian);
    if (series_count == 0 or series_count > 4096) return error.InvalidFormat;

    const description = parseDescription(data);
    const entry_offset = try findSeriesTableOffset(data, endian);
    if (entry_offset > data.len or data.len - entry_offset < entry_size) return error.TruncatedData;
    const entry = data[entry_offset..][0..entry_size];

    const width = try readPositiveU32(entry[0..4], endian);
    const height = try readPositiveU32(entry[4..8], endian);
    const num_bits = try readPositiveU32(entry[8..12], endian);
    const size_c = try readPositiveU16(entry[12..16], endian);
    const size_z = try readPositiveU16(entry[16..20], endian);
    const size_t = try readPositiveU16(entry[20..24], endian);
    const plane_count = std.math.mul(u32, @as(u32, size_z), std.math.mul(u32, @as(u32, size_c), @as(u32, size_t)) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    const pixel_type = pixelTypeFromBits(num_bits) orelse return error.UnsupportedVariant;
    const pixel_offset = try findPixelOffset(data, endian, entry_offset, width, height, plane_count, pixel_type);

    return .{
        .endian = endian,
        .width = width,
        .height = height,
        .size_c = size_c,
        .size_z = size_z,
        .size_t = size_t,
        .plane_count = plane_count,
        .pixel_type = pixel_type,
        .pixel_offset = pixel_offset,
        .description = description,
    };
}

fn parseEndian(bytes: []const u8) ?std.builtin.Endian {
    if (std.mem.eql(u8, bytes, "II")) return .little;
    if (std.mem.eql(u8, bytes, "MM")) return .big;
    return null;
}

fn parseDescription(data: []const u8) ?[]const u8 {
    var pos: usize = description_offset;
    while (pos < data.len and data[pos] == 0) : (pos += 1) {}
    if (pos >= data.len) return null;
    const end = std.mem.indexOfScalarPos(u8, data, pos, 0) orelse return null;
    const value = std.mem.trim(u8, data[pos..end], " \t\r\n");
    return if (value.len == 0) null else value;
}

fn findSeriesTableOffset(data: []const u8, endian: std.builtin.Endian) bio.ReaderError!usize {
    var pos: usize = description_offset;
    while (pos < data.len and data[pos] == 0) : (pos += 1) {}
    if (pos >= data.len) return error.InvalidFormat;
    pos = (std.mem.indexOfScalarPos(u8, data, pos, 0) orelse return error.InvalidFormat) + 1;
    while (pos + 4 <= data.len) {
        const value = readI32(data[pos..][0..4], endian);
        pos += 4;
        if (value != 0) {
            var fp = pos;
            if ((fp & 1) == 0) {
                fp -= 4;
            } else {
                fp -= 1;
            }
            return fp;
        }
    }
    return error.InvalidFormat;
}

fn findPixelOffset(
    data: []const u8,
    endian: std.builtin.Endian,
    entry_offset: usize,
    width: u32,
    height: u32,
    plane_count: u32,
    pixel_type: bio.PixelType,
) bio.ReaderError!usize {
    const needed = try totalBytes(width, height, plane_count, pixel_type);

    if (findJavaPixelOffset(data, endian, entry_offset, needed)) |offset| return offset;

    const after_entry = entry_offset + entry_size;
    if (after_entry <= data.len and data.len - after_entry >= needed) return after_entry;

    if (data.len >= needed) return data.len - needed;
    return error.TruncatedData;
}

fn findJavaPixelOffset(data: []const u8, endian: std.builtin.Endian, entry_offset: usize, needed: usize) ?usize {
    const pointer = entry_offset + 28;
    const scan_start = pointer + 92;
    if (scan_start < pointer or scan_start >= data.len) return null;

    var pos = scan_start;
    while (pos + 4 <= data.len and pos < entry_offset + entry_size) : (pos += 96) {
        const check = readI32(data[pos..][0..4], endian);
        const file_pointer = pos + 4;
        if (check > 0 and @as(usize, @intCast(check)) > file_pointer) {
            const candidate = std.math.add(usize, @as(usize, @intCast(check)), lut_size + 352) catch return null;
            if (candidate <= data.len and data.len - candidate >= needed) return candidate;
        }
    }
    return null;
}

fn pixelTypeFromBits(bits: u32) ?bio.PixelType {
    return switch (bits) {
        8 => .uint8,
        16 => .uint16,
        32 => .uint32,
        64 => .float64,
        else => null,
    };
}

fn readPositiveU32(bytes: []const u8, endian: std.builtin.Endian) bio.ReaderError!u32 {
    const value = readI32(bytes, endian);
    if (value <= 0) return error.InvalidFormat;
    return @intCast(value);
}

fn readPositiveU16(bytes: []const u8, endian: std.builtin.Endian) bio.ReaderError!u16 {
    const value = readI32(bytes, endian);
    if (value <= 0 or value > std.math.maxInt(u16)) return error.InvalidFormat;
    return @intCast(value);
}

fn readU32(bytes: []const u8, endian: std.builtin.Endian) u32 {
    return std.mem.readInt(u32, bytes[0..4], endian);
}

fn readI32(bytes: []const u8, endian: std.builtin.Endian) i32 {
    return std.mem.readInt(i32, bytes[0..4], endian);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn totalByteCount(header: Header) bio.ReaderError!usize {
    return totalBytes(header.width, header.height, header.plane_count, header.pixel_type);
}

fn totalBytes(width: u32, height: u32, plane_count: u32, pixel_type: bio.PixelType) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, width, height) catch return error.UnsupportedVariant;
    const plane = std.math.mul(usize, pixels, pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
    return std.math.mul(usize, plane, plane_count) catch return error.UnsupportedVariant;
}

fn writeI32(bytes: []u8, offset: usize, value: i32, endian: std.builtin.Endian) void {
    std.mem.writeInt(i32, bytes[offset..][0..4], value, endian);
}

fn appendSyntheticNaf(list: *std.ArrayList(u8), endian: std.builtin.Endian) !void {
    try list.appendNTimes(std.testing.allocator, 0, 464);
    @memcpy(list.items[0..2], if (endian == .little) "II" else "MM");
    writeI32(list.items, first_series_count_offset, 1, endian);
    @memcpy(list.items[description_offset..][0..3], "NAF");
    const entry_offset = 208;
    writeI32(list.items, entry_offset + 0, 2, endian);
    writeI32(list.items, entry_offset + 4, 1, endian);
    writeI32(list.items, entry_offset + 8, 16, endian);
    writeI32(list.items, entry_offset + 12, 1, endian);
    writeI32(list.items, entry_offset + 16, 1, endian);
    writeI32(list.items, entry_offset + 20, 2, endian);
    try list.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0, 3, 0, 4, 0 });
}

test "reads naf metadata from first series" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendSyntheticNaf(&data, .little);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("naf", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("NAF", metadata.image_description.?);
}

test "reads naf indexed planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendSyntheticNaf(&data, .little);

    const first = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(first.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, first.data);

    const second = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 4, 0 }, second.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads big-endian naf header and pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendSyntheticNaf(&data, .big);

    const metadata = try readMetadata(data.items);
    try std.testing.expect(!metadata.little_endian);
    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, plane.data);
}
