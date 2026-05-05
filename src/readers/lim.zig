const std = @import("std");
const bio = @import("../root.zig");

const pixel_offset = 0x94b;

const Header = struct {
    width: u32,
    height: u32,
    samples: u16,
    pixel_type: bio.PixelType,
    compressed: bool,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    if (header.compressed) return false;
    const plane_len = planeByteCount(.{
        .format = "lim",
        .width = header.width,
        .height = header.height,
        .size_c = header.samples,
        .samples_per_pixel = header.samples,
        .pixel_type = header.pixel_type,
    }) catch return false;
    return data.len >= pixel_offset and data.len - pixel_offset >= plane_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    if (header.compressed) return error.UnsupportedVariant;
    return .{
        .format = "lim",
        .width = header.width,
        .height = header.height,
        .size_c = header.samples,
        .samples_per_pixel = header.samples,
        .pixel_type = header.pixel_type,
        .little_endian = true,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const plane_len = try planeByteCount(metadata);
    if (data.len < pixel_offset or data.len - pixel_offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    @memcpy(out, data[pixel_offset..][0..plane_len]);
    if (metadata.samples_per_pixel == 3) swapRedBlue(out, metadata.pixel_type.bytesPerSample());
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < 8) return error.TruncatedData;
    const width = readU16(data[0..2]) & 0x7fff;
    const height = readU16(data[2..4]);
    var bits = readU16(data[4..6]);
    const compressed = readU16(data[6..8]) != 0;
    if (width == 0 or height == 0 or bits == 0) return error.InvalidFormat;
    if (bits > 96) return error.UnsupportedVariant;
    while (bits % 8 != 0) bits = std.math.add(u16, bits, 1) catch return error.UnsupportedVariant;
    var samples: u16 = 1;
    if (bits % 3 == 0) {
        samples = 3;
        bits /= 3;
    }
    const bytes_per_sample = bits / 8;
    return .{
        .width = width,
        .height = height,
        .samples = samples,
        .pixel_type = switch (bytes_per_sample) {
            1 => .uint8,
            2 => .uint16,
            4 => .uint32,
            else => return error.UnsupportedVariant,
        },
        .compressed = compressed,
    };
}

fn swapRedBlue(data: []u8, bytes_per_sample: usize) void {
    const pixel_stride = bytes_per_sample * 3;
    var offset: usize = 0;
    while (offset + pixel_stride <= data.len) : (offset += pixel_stride) {
        for (0..bytes_per_sample) |i| {
            const tmp = data[offset + i];
            data[offset + i] = data[offset + 2 * bytes_per_sample + i];
            data[offset + 2 * bytes_per_sample + i] = tmp;
        }
    }
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    const samples = std.math.mul(usize, pixels, metadata.samples_per_pixel) catch return error.UnsupportedVariant;
    return std.math.mul(usize, samples, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(list: *std.ArrayList(u8), width: u16, height: u16, bits: u16, compressed: bool) !void {
    try list.appendNTimes(std.testing.allocator, 0, pixel_offset);
    writeU16(list.items, 0, width);
    writeU16(list.items, 2, height);
    writeU16(list.items, 4, bits);
    writeU16(list.items, 6, if (compressed) 1 else 0);
}

test "reads lim uint16 grayscale plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 16, false);
    try data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12, 0xcd, 0xab });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
}

test "reads lim rgb plane and swaps red blue" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 24, false);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1 }, plane.data);
}

test "rejects compressed lim pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 8, true);
    try data.append(std.testing.allocator, 0);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}

test "lim detector rejects overflowing bit depth" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 65535, false);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}
