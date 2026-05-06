const std = @import("std");
const bio = @import("../root.zig");

const c01_header_size: u32 = 16;
const dib_header_size: u32 = 40;
const pixel_offset = 52;

const Header = struct {
    width: u32,
    height: u32,
    plane_count: u32,
    pixel_type: bio.PixelType,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const metadata = metadataFromHeader(header);
    const plane_len = planeByteCount(metadata) catch return false;
    const total = std.math.mul(usize, plane_len, header.plane_count) catch return false;
    return data.len >= pixel_offset and data.len - pixel_offset >= total;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    return metadataFromHeader(try parseHeader(data));
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const offset = std.math.add(usize, pixel_offset, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < pixel_offset) return error.TruncatedData;
    const header_size = std.mem.readInt(u32, data[0..4], .little);
    if (header_size != c01_header_size and header_size != dib_header_size) return error.InvalidFormat;
    const width = std.mem.readInt(u32, data[4..8], .little);
    const height = std.mem.readInt(u32, data[8..12], .little);
    const planes = std.mem.readInt(u16, data[12..14], .little);
    const bits = std.mem.readInt(u16, data[14..16], .little);
    if (width == 0 or height == 0 or planes == 0) return error.InvalidFormat;
    const compression = std.mem.readInt(u32, data[16..20], .little);
    if (compression != 0) return error.UnsupportedVariant;
    const pixel_type: bio.PixelType = switch (bits) {
        8 => .uint8,
        16 => .uint16,
        32 => .uint32,
        else => return error.UnsupportedVariant,
    };
    return .{
        .width = width,
        .height = height,
        .plane_count = planes,
        .pixel_type = pixel_type,
    };
}

fn metadataFromHeader(header: Header) bio.Metadata {
    return .{
        .format = "cellomics",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.plane_count, std.math.maxInt(u16))),
        .pixel_type = header.pixel_type,
        .little_endian = true,
        .plane_count = header.plane_count,
        .dimension_order = "XYCZT",
    };
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const row = std.math.mul(usize, metadata.width, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
    return std.math.mul(usize, row, metadata.height) catch return error.UnsupportedVariant;
}

fn appendU16Le(list: *std.ArrayList(u8), value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendU32Le(list: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

test "reads uncompressed cellomics planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU32Le(&data, c01_header_size);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 1);
    try appendU16Le(&data, 2);
    try appendU16Le(&data, 8);
    try appendU32Le(&data, 0);
    while (data.items.len < pixel_offset) try data.append(std.testing.allocator, 0);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4 });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("cellomics", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const second = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, second.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "rejects compressed cellomics stream" {
    var data: [pixel_offset + 1]u8 = [_]u8{0} ** (pixel_offset + 1);
    std.mem.writeInt(u32, data[0..4], c01_header_size, .little);
    std.mem.writeInt(u32, data[4..8], 1, .little);
    std.mem.writeInt(u32, data[8..12], 1, .little);
    std.mem.writeInt(u16, data[12..14], 1, .little);
    std.mem.writeInt(u16, data[14..16], 8, .little);
    std.mem.writeInt(u32, data[16..20], 1, .little);

    try std.testing.expect(!matches(&data));
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(&data));
}

test "reads cellomics dib header variant" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU32Le(&data, dib_header_size);
    try appendU32Le(&data, 1);
    try appendU32Le(&data, 1);
    try appendU16Le(&data, 1);
    try appendU16Le(&data, 16);
    try appendU32Le(&data, 0);
    while (data.items.len < pixel_offset) try data.append(std.testing.allocator, 0);
    try data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12 });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("cellomics", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, plane.data);
}

test "matches Bio-Formats default metadata and plane hash for cached Cellomics fixture" {
    const file_path = "fixtures/cache/cellomics/AS_09125_050118150001_A03f00d0.DIB";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(2 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("cellomics", metadata.format);
    try std.testing.expectEqual(@as(u32, 512), metadata.width);
    try std.testing.expectEqual(@as(u32, 512), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(usize, 524288), plane.data.len);
    const expected_plane: [32]u8 = .{ 0xa9, 0xd4, 0xa1, 0x7e, 0xa5, 0x62, 0x40, 0xd8, 0xe3, 0xf9, 0x00, 0x00, 0xfc, 0xff, 0xd6, 0x42, 0x3f, 0x86, 0xd8, 0x7e, 0x3a, 0x54, 0xe7, 0x5f, 0x01, 0x34, 0x60, 0x6d, 0xf3, 0xc6, 0x20, 0xa3 };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_plane, &digest);
}
