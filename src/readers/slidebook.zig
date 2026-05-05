const std = @import("std");
const bio = @import("../root.zig");

const magic_1_0: u16 = 0x006c;
const magic_2_0: u16 = 0x01f5;
const metadata_block_size = 128;

const Scan = struct {
    width: u32 = 0,
    height: u32 = 0,
    size_c: u16 = 1,
    size_z: u16 = 1,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const little = try parseHeader(data);
    const scan = try scanMetadataBlocks(data, little);
    const zc = std.math.mul(u32, scan.size_z, scan.size_c) catch return error.UnsupportedVariant;
    return .{
        .format = "slidebook",
        .width = scan.width,
        .height = scan.height,
        .size_c = scan.size_c,
        .samples_per_pixel = 1,
        .size_z = scan.size_z,
        .size_t = 1,
        .pixel_type = .uint16,
        .little_endian = little,
        .plane_count = zc,
        .dimension_order = "XYZTC",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const little = try parseHeader(data);
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const total_len = std.math.mul(usize, plane_len, metadata.plane_count) catch return error.UnsupportedVariant;
    const raw_offset = try findRawPixelBlock(data, if (little) .little else .big, total_len);
    const offset = std.math.add(usize, raw_offset, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (offset + plane_len > data.len) return error.TruncatedData;
    const out = try allocator.dupe(u8, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!bool {
    if (data.len < 10) return error.TruncatedData;
    const little = if (std.mem.eql(u8, data[4..6], "II"))
        true
    else if (std.mem.eql(u8, data[4..6], "MM"))
        false
    else
        return error.InvalidFormat;
    const endian: std.builtin.Endian = if (little) .little else .big;
    const magic1 = std.mem.readInt(u16, data[6..8], endian);
    const magic2 = std.mem.readInt(u16, data[8..10], endian);
    if ((magic2 & 0xff00) != 0x0100 and (magic2 & 0xff00) != 0x0200) return error.InvalidFormat;
    if (magic1 != magic_1_0 and magic1 != magic_2_0) return error.InvalidFormat;
    return little;
}

fn scanMetadataBlocks(data: []const u8, little: bool) bio.ReaderError!Scan {
    const endian: std.builtin.Endian = if (little) .little else .big;
    var scan = Scan{};
    var i_blocks: u32 = 0;
    var u_blocks: u32 = 0;
    var pos: usize = 0;
    while (pos + metadata_block_size <= data.len) : (pos += 1) {
        if (!isEndianMarker(data[pos + 4 ..][0..2])) continue;
        const block = data[pos..][0..metadata_block_size];
        var n = std.mem.readInt(u16, block[0..2], endian);
        if (n == 0) n = std.mem.readInt(u16, block[2..4], endian);
        switch (n) {
            'i' => {
                i_blocks += 1;
                const dims = parseIBlockDimensions(block, endian);
                if (dims.width != 0 and dims.height != 0 and scan.width == 0) {
                    scan.width = dims.width;
                    scan.height = dims.height;
                }
            },
            'u' => u_blocks += 1,
            else => {},
        }
    }
    if (scan.width == 0 or scan.height == 0) return error.InvalidFormat;
    scan.size_c = boundedDimension(i_blocks);
    scan.size_z = boundedDimension(if (u_blocks == 0) 1 else u_blocks);
    return scan;
}

const Dimensions = struct {
    width: u32,
    height: u32,
};

fn parseIBlockDimensions(block: []const u8, endian: std.builtin.Endian) Dimensions {
    const x = std.mem.readInt(u16, block[80..82], endian);
    const y = std.mem.readInt(u16, block[82..84], endian);
    if (x == 0 or y == 0) return .{ .width = 0, .height = 0 };
    var width: u32 = x;
    var height: u32 = y;
    const check_x = std.mem.readInt(u16, block[84..86], endian);
    const check_y = std.mem.readInt(u16, block[86..88], endian);
    if (check_x == check_y) {
        const div_x = std.mem.readInt(u16, block[88..90], endian);
        const div_y = std.mem.readInt(u16, block[90..92], endian);
        width /= if (div_x == 0) 1 else div_x;
        height /= if (div_y == 0) 1 else div_y;
    }
    return .{ .width = width, .height = height };
}

fn isEndianMarker(bytes: []const u8) bool {
    return std.mem.eql(u8, bytes, "II") or std.mem.eql(u8, bytes, "MM");
}

fn boundedDimension(value: u32) u16 {
    return @intCast(@min(@max(value, 1), std.math.maxInt(u16)));
}

fn findRawPixelBlock(data: []const u8, endian: std.builtin.Endian, total_len: usize) bio.ReaderError!usize {
    if (total_len == 0 or data.len < 10 + metadata_block_size) return error.UnsupportedVariant;
    var previous_end: usize = 10;
    var pos: usize = 0;
    while (pos + metadata_block_size <= data.len) : (pos += 1) {
        if (!isFixedMetadataBlock(data[pos..][0..metadata_block_size], endian)) continue;
        if (pos >= previous_end and pos - previous_end >= total_len) {
            return pos - total_len;
        }
        previous_end = pos + metadata_block_size;
        pos += metadata_block_size - 1;
    }
    return error.UnsupportedVariant;
}

fn isFixedMetadataBlock(block: []const u8, endian: std.builtin.Endian) bool {
    if (!isEndianMarker(block[4..6])) return false;
    var n = std.mem.readInt(u16, block[0..2], endian);
    if (n == 0) n = std.mem.readInt(u16, block[2..4], endian);
    return n == 'h' or n == 'i' or n == 'j' or n == 'k' or n == 'm' or n == 'n' or n == 'u';
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn appendU16(out: *std.ArrayList(u8), value: u16, endian: std.builtin.Endian) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, endian);
    try out.appendSlice(std.testing.allocator, &bytes);
}

fn appendSyntheticHeader(out: *std.ArrayList(u8), endian: std.builtin.Endian) !void {
    try out.appendNTimes(std.testing.allocator, 0, 4);
    try out.appendSlice(std.testing.allocator, if (endian == .little) "II" else "MM");
    try appendU16(out, magic_1_0, endian);
    try appendU16(out, 0x0100, endian);
}

fn appendIBlock(out: *std.ArrayList(u8), endian: std.builtin.Endian, width: u16, height: u16) !void {
    const start = out.items.len;
    try out.appendNTimes(std.testing.allocator, 0, metadata_block_size);
    std.mem.writeInt(u16, out.items[start..][0..2], 'i', endian);
    @memcpy(out.items[start + 4 ..][0..2], if (endian == .little) "II" else "MM");
    std.mem.writeInt(u16, out.items[start + 80 ..][0..2], width, endian);
    std.mem.writeInt(u16, out.items[start + 82 ..][0..2], height, endian);
}

fn appendUBlock(out: *std.ArrayList(u8), endian: std.builtin.Endian) !void {
    const start = out.items.len;
    try out.appendNTimes(std.testing.allocator, 0, metadata_block_size);
    std.mem.writeInt(u16, out.items[start..][0..2], 'u', endian);
    @memcpy(out.items[start + 4 ..][0..2], if (endian == .little) "II" else "MM");
}

test "reads legacy slidebook metadata blocks" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendSyntheticHeader(&data, .little);
    try data.appendNTimes(std.testing.allocator, 0, 12);
    try appendIBlock(&data, .little, 13, 9);
    try appendIBlock(&data, .little, 13, 9);
    try appendUBlock(&data, .little);
    try appendUBlock(&data, .little);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("slidebook", metadata.format);
    try std.testing.expectEqual(@as(u32, 13), metadata.width);
    try std.testing.expectEqual(@as(u32, 9), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 4), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, data.items, 0));
}

test "reads legacy slidebook contiguous raw uint16 planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendSyntheticHeader(&data, .little);
    try data.appendSlice(std.testing.allocator, &.{
        1,  0, 2,  0, 3,  0, 4,  0,
        11, 0, 12, 0, 13, 0, 14, 0,
    });
    try appendIBlock(&data, .little, 2, 2);
    try appendIBlock(&data, .little, 2, 2);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("slidebook", plane.metadata.format);
    try std.testing.expectEqual(@as(u32, 2), plane.metadata.width);
    try std.testing.expectEqual(@as(u32, 2), plane.metadata.height);
    try std.testing.expectEqual(@as(u16, 2), plane.metadata.size_c);
    try std.testing.expectEqual(@as(usize, 8), plane.data.len);
    try std.testing.expectEqualSlices(u8, &.{ 11, 0, 12, 0, 13, 0, 14, 0 }, plane.data);
}

test "reads big endian legacy slidebook metadata blocks" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendSyntheticHeader(&data, .big);
    try appendIBlock(&data, .big, 5, 4);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 5), metadata.width);
    try std.testing.expectEqual(@as(u32, 4), metadata.height);
    try std.testing.expect(!metadata.little_endian);
}

test "rejects non-slidebook header" {
    try std.testing.expect(!matches("not slidebook"));
    try std.testing.expectError(error.TruncatedData, readMetadata("bad"));
}
