const std = @import("std");
const bio = @import("../root.zig");

const min_header_len = 29;

const Header = struct {
    pixels_offset: usize,
    width: u32,
    height: u32,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    return compressedStreamHasPlane(data, header) catch false;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "incell3000",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint16,
        .little_endian = true,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    const out_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    try decompressPixels(data, header, out);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < min_header_len) return error.TruncatedData;
    const pixels_offset = readU16(data, 0);
    const width = readU16(data, 2);
    const n_lines = readU16(data, 4);
    const component_bytes = readU32(data, 24);
    const trailing_zero = data[28];

    if (pixels_offset < min_header_len or pixels_offset >= data.len) return error.InvalidFormat;
    if (width == 0 or n_lines == 0) return error.InvalidFormat;
    if (component_bytes != 2 or trailing_zero != 0) return error.InvalidFormat;

    const num_planes = n_lines % 32;
    if (num_planes == 0) return error.InvalidFormat;
    const height = (n_lines - num_planes) / num_planes;
    if (height == 0) return error.InvalidFormat;

    return .{
        .pixels_offset = pixels_offset,
        .width = width,
        .height = height,
    };
}

fn compressedStreamHasPlane(data: []const u8, header: Header) bio.ReaderError!bool {
    const metadata = bio.Metadata{
        .format = "incell3000",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint16,
        .little_endian = true,
    };
    const out_len = try planeByteCount(metadata);
    var src = header.pixels_offset;
    var produced: usize = 0;
    while (produced < out_len) {
        if (src > data.len or data.len - src < 2) return error.TruncatedData;
        const pixel = readU16(data, src);
        src += 2;
        if (pixel > 32768) {
            const count: usize = pixel - 32768;
            if (src > data.len or data.len - src < 2) return error.TruncatedData;
            src += 2;
            const offsets_len = try packedOffsetByteCount(count);
            if (src > data.len or data.len - src < offsets_len) return error.TruncatedData;
            produced = std.math.add(usize, produced, std.math.mul(usize, count, 2) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
            src += offsets_len;
        } else {
            produced += 2;
        }
    }
    return produced == out_len;
}

fn decompressPixels(data: []const u8, header: Header, out: []u8) bio.ReaderError!void {
    var src = header.pixels_offset;
    var dst: usize = 0;
    while (dst < out.len) {
        if (src > data.len or data.len - src < 2) return error.TruncatedData;
        const pixel = readU16(data, src);
        src += 2;
        if (pixel > 32768) {
            const count: usize = pixel - 32768;
            if (src > data.len or data.len - src < 2) return error.TruncatedData;
            const start_value = readU16(data, src);
            src += 2;
            const offsets_start = src;
            const offsets_len = try packedOffsetByteCount(count);
            if (offsets_start > data.len or data.len - offsets_start < offsets_len) return error.TruncatedData;
            if (dst > out.len or out.len - dst < count * 2) return error.InvalidFormat;

            var i: usize = 0;
            while (i < count) : (i += 1) {
                const packed_word = readU16(data, offsets_start + 2 * (i / 3));
                const shifted = if ((i % 3) == 0) packed_word else packed_word >> 5;
                const value: u16 = @truncate(@as(u32, start_value) + @as(u32, shifted & 31));
                writeU16(out, dst, value);
                dst += 2;
            }
            src = offsets_start + offsets_len;
        } else {
            if (dst > out.len or out.len - dst < 2) return error.InvalidFormat;
            writeU16(out, dst, pixel);
            dst += 2;
        }
    }
}

fn packedOffsetByteCount(count: usize) bio.ReaderError!usize {
    return std.math.mul(usize, (count + 2) / 3, 2) catch return error.UnsupportedVariant;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn readU16(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn writeU16(data: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, data[offset..][0..2], value, .little);
}

fn appendU16Le(list: *std.ArrayList(u8), value: u16) !void {
    try list.append(std.testing.allocator, @intCast(value & 0xff));
    try list.append(std.testing.allocator, @intCast(value >> 8));
}

fn appendU32Le(list: *std.ArrayList(u8), value: u32) !void {
    try list.append(std.testing.allocator, @intCast(value & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
}

fn appendHeader(list: *std.ArrayList(u8), pixels_offset: u16, width: u16, height: u16) !void {
    var num_planes: u16 = 1;
    while (num_planes < 32 and (@as(u32, height) * num_planes) % 32 != 0) : (num_planes += 1) {}
    try std.testing.expect(num_planes < 32);
    try appendU16Le(list, pixels_offset);
    try appendU16Le(list, width);
    try appendU16Le(list, (height + 1) * num_planes);
    try list.appendNTimes(std.testing.allocator, 0, 18);
    try appendU32Le(list, 2);
    try list.append(std.testing.allocator, 0);
    try list.appendNTimes(std.testing.allocator, 0, pixels_offset - min_header_len);
}

test "reads uncompressed incell 3000 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 32, 2, 2);
    try appendU16Le(&data, 11);
    try appendU16Le(&data, 22);
    try appendU16Le(&data, 33);
    try appendU16Le(&data, 44);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("incell3000", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 11, 0, 22, 0, 33, 0, 44, 0 }, plane.data);
}

test "expands incell 3000 packed run" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 32, 4, 2);
    try appendU16Le(&data, 32772);
    try appendU16Le(&data, 100);
    try appendU16Le(&data, (2 << 5) | 1);
    try appendU16Le(&data, 3);
    try appendU16Le(&data, 200);
    try appendU16Le(&data, 201);
    try appendU16Le(&data, 202);
    try appendU16Le(&data, 203);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 101, 0, 102, 0, 102, 0, 103, 0, 200, 0, 201, 0, 202, 0, 203, 0 }, plane.data);
}

test "rejects truncated incell 3000 packed run" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 32, 2, 2);
    try appendU16Le(&data, 32770);
    try appendU16Le(&data, 50);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}
