const std = @import("std");
const bio = @import("../root.zig");

const header_len = 20;

const Header = struct {
    width: u32,
    height: u32,
    time_bins: u32,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const pixel_bytes = pixelByteCount(header) catch return false;
    return data.len == header_len + pixel_bytes;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "pqbin",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_t = @intCast(@min(header.time_bins, std.math.maxInt(u16))),
        .pixel_type = .uint32,
        .little_endian = true,
        .plane_count = header.time_bins,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const header = try parseHeader(data);
    const out_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    const bpp = metadata.pixel_type.bytesPerSample();
    const row_stride = std.math.mul(usize, std.math.mul(usize, header.width, header.time_bins) catch return error.UnsupportedVariant, bpp) catch return error.UnsupportedVariant;
    const plane_row_stride = std.math.mul(usize, header.width, bpp) catch return error.UnsupportedVariant;
    const time_offset = std.math.mul(usize, plane_index, bpp) catch return error.UnsupportedVariant;
    for (0..header.height) |row| {
        for (0..header.width) |col| {
            const src = header_len + row * row_stride + col * header.time_bins * bpp + time_offset;
            const dst = row * plane_row_stride + col * bpp;
            if (src > data.len or data.len - src < bpp) return error.TruncatedData;
            @memcpy(out[dst..][0..bpp], data[src..][0..bpp]);
        }
    }

    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_len) return error.TruncatedData;
    const width = readU32(data[0..4]);
    const height = readU32(data[4..8]);
    const time_bins = readU32(data[12..16]);
    if (width == 0 or height == 0 or time_bins == 0) return error.InvalidFormat;
    return .{ .width = width, .height = height, .time_bins = time_bins };
}

fn pixelByteCount(header: Header) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    const samples = std.math.mul(usize, pixels, header.time_bins) catch return error.UnsupportedVariant;
    return std.math.mul(usize, samples, bio.PixelType.uint32.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn appendHeader(list: *std.ArrayList(u8), width: u32, height: u32, time_bins: u32) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_len);
    writeU32(list.items, 0, width);
    writeU32(list.items, 4, height);
    writeU32(list.items, 12, time_bins);
}

fn appendU32(list: *std.ArrayList(u8), value: u32) !void {
    const start = list.items.len;
    try list.appendNTimes(std.testing.allocator, 0, 4);
    writeU32(list.items, start, value);
}

test "reads pqbin time-bin planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 2, 3);
    for ([_]u32{
        1,  2,  3,
        4,  5,  6,
        7,  8,  9,
        10, 11, 12,
    }) |value| {
        try appendU32(&data, value);
    }

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 3), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_t);
    try std.testing.expectEqual(bio.PixelType.uint32, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const second = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{
        2,  0, 0, 0,
        5,  0, 0, 0,
        8,  0, 0, 0,
        11, 0, 0, 0,
    }, second.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 3));
}

test "rejects pqbin size mismatch" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 1);

    try std.testing.expect(!matches(data.items));
}

