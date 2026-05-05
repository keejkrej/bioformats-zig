const std = @import("std");
const bio = @import("../root.zig");

const header_min_len = 524;
const invalid_pixels = 112;

const Offset = struct {
    const stored_width = 514;
    const height = 516;
    const header_size = 522;
};

const Header = struct {
    width: u32,
    height: u32,
    stored_width: u32,
    pixel_offset: usize,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const pixel_bytes = std.math.mul(usize, header.stored_width, header.height) catch return false;
    return data.len >= header.pixel_offset and data.len - header.pixel_offset >= pixel_bytes;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "fei",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint8,
        .little_endian = true,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    const out = try allocator.alloc(u8, try planeByteCount(metadata));
    errdefer allocator.free(out);

    var source = header.pixel_offset;
    const segment_len: usize = @intCast(header.width / 2);
    const pad_len = invalid_pixels / 2;
    for (0..4) |q| {
        var row: usize = q;
        while (row < header.height) : (row += 4) {
            for (0..2) |s| {
                if (source > data.len or data.len - source < segment_len + pad_len) return error.TruncatedData;
                const segment = data[source..][0..segment_len];
                source += segment_len + pad_len;
                for (segment, 0..) |value, x| {
                    const col = s + x * 2;
                    out[row * header.width + col] = value;
                }
            }
        }
    }

    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_min_len) return error.TruncatedData;
    if (!std.mem.eql(u8, data[0..2], "XL")) return error.InvalidFormat;
    const stored_width = readU16(data[Offset.stored_width..][0..2]);
    const height = readU16(data[Offset.height..][0..2]);
    const header_size = readU16(data[Offset.header_size..][0..2]);
    if (stored_width <= invalid_pixels or height == 0 or header_size < header_min_len) return error.InvalidFormat;

    const width = stored_width - invalid_pixels;
    if (width == 0 or width % 2 != 0) return error.UnsupportedVariant;
    return .{
        .width = width,
        .height = height,
        .stored_width = stored_width,
        .pixel_offset = header_size,
    };
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(list: *std.ArrayList(u8), width: u16, height: u16) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_min_len);
    @memcpy(list.items[0..2], "XL");
    writeU16(list.items, Offset.stored_width, width + invalid_pixels);
    writeU16(list.items, Offset.height, height);
    writeU16(list.items, Offset.header_size, header_min_len);
}

fn appendEncodedPlane(list: *std.ArrayList(u8), width: u16, height: u16, plane: []const u8) !void {
    const segment_len = width / 2;
    for (0..4) |q| {
        var row: usize = q;
        while (row < height) : (row += 4) {
            for (0..2) |s| {
                var x: usize = 0;
                while (x < segment_len) : (x += 1) {
                    try list.append(std.testing.allocator, plane[row * width + s + x * 2]);
                }
                try list.appendNTimes(std.testing.allocator, 0, invalid_pixels / 2);
            }
        }
    }
}

test "reads fei interlaced uint8 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    const expected = [_]u8{
        1,  2,  3,  4,
        5,  6,  7,  8,
        9,  10, 11, 12,
        13, 14, 15, 16,
    };
    try appendHeader(&data, 4, 4);
    try appendEncodedPlane(&data, 4, 4, &expected);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 4), metadata.width);
    try std.testing.expectEqual(@as(u32, 4), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &expected, plane.data);
}

test "rejects truncated fei pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 4, 1);
    try data.appendNTimes(std.testing.allocator, 0, 10);

    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}

