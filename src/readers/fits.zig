const std = @import("std");
const bio = @import("../root.zig");

const card_len = 80;
const block_len = 2880;

const Header = struct {
    width: u32,
    height: u32,
    planes: u32,
    bitpix: i32,
    pixel_offset: usize,

    fn pixelType(self: Header) bio.ReaderError!bio.PixelType {
        return switch (self.bitpix) {
            8 => .uint8,
            16 => .int16,
            32 => .int32,
            -32 => .float32,
            -64 => .float64,
            else => error.UnsupportedVariant,
        };
    }
};

pub fn matches(data: []const u8) bool {
    return data.len >= card_len and std.mem.startsWith(u8, data[0..card_len], "SIMPLE");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    const pixel_type = try header.pixelType();
    return .{
        .format = "fits",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.planes, std.math.maxInt(u16))),
        .pixel_type = pixel_type,
        .little_endian = false,
        .plane_count = header.planes,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const offset = std.math.add(usize, header.pixel_offset, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    var bitpix: ?i32 = null;
    var naxis: ?u32 = null;
    var width: ?u32 = null;
    var height: ?u32 = null;
    var planes: u32 = 1;
    var pos: usize = 0;
    while (pos + card_len <= data.len) : (pos += card_len) {
        const card = data[pos..][0..card_len];
        const key = std.mem.trim(u8, card[0..8], " ");
        if (std.mem.eql(u8, key, "END")) {
            const end = pos + card_len;
            const pixel_offset = roundUpBlock(end);
            if (pixel_offset > data.len) return error.TruncatedData;
            const axes = naxis orelse return error.InvalidFormat;
            if (axes < 2 or axes > 3) return error.UnsupportedVariant;
            return .{
                .width = width orelse return error.InvalidFormat,
                .height = height orelse return error.InvalidFormat,
                .planes = if (axes == 3) planes else 1,
                .bitpix = bitpix orelse return error.InvalidFormat,
                .pixel_offset = pixel_offset,
            };
        }
        if (card[8] != '=') continue;
        const value = valueField(card);
        if (std.mem.eql(u8, key, "BITPIX")) {
            bitpix = std.fmt.parseInt(i32, value, 10) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, key, "NAXIS")) {
            naxis = std.fmt.parseInt(u32, value, 10) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, key, "NAXIS1")) {
            width = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "NAXIS2")) {
            height = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "NAXIS3")) {
            planes = try parsePositiveU32(value);
        }
    }
    return error.TruncatedData;
}

fn valueField(card: []const u8) []const u8 {
    const raw = card[10..];
    const comment = std.mem.indexOfScalar(u8, raw, '/') orelse raw.len;
    return std.mem.trim(u8, raw[0..comment], " ");
}

fn parsePositiveU32(value: []const u8) bio.ReaderError!u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidFormat;
    if (parsed == 0) return error.InvalidFormat;
    return parsed;
}

fn roundUpBlock(pos: usize) usize {
    return ((pos + block_len - 1) / block_len) * block_len;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendCard(list: *std.ArrayList(u8), key: []const u8, value: ?[]const u8) !void {
    const start = list.items.len;
    try list.appendNTimes(std.testing.allocator, ' ', card_len);
    @memcpy(list.items[start..][0..key.len], key);
    if (value) |v| {
        list.items[start + 8] = '=';
        list.items[start + 9] = ' ';
        @memcpy(list.items[start + 10 ..][0..v.len], v);
    }
}

fn appendFitsHeader(list: *std.ArrayList(u8), bitpix: []const u8, width: []const u8, height: []const u8, planes: ?[]const u8) !void {
    try appendCard(list, "SIMPLE", "T");
    try appendCard(list, "BITPIX", bitpix);
    try appendCard(list, "NAXIS", if (planes == null) "2" else "3");
    try appendCard(list, "NAXIS1", width);
    try appendCard(list, "NAXIS2", height);
    if (planes) |z| try appendCard(list, "NAXIS3", z);
    try appendCard(list, "END", null);
    try list.appendNTimes(std.testing.allocator, ' ', roundUpBlock(list.items.len) - list.items.len);
}

test "reads 8-bit fits primary image" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendFitsHeader(&data, "8", "2", "1", null);
    try data.appendSlice(std.testing.allocator, &.{ 7, 9 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "reads second fits z plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendFitsHeader(&data, "16", "1", "1", "2");
    try data.appendSlice(std.testing.allocator, &.{ 0x12, 0x34, 0xab, 0xcd });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(bio.PixelType.int16, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads floating point fits metadata" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendFitsHeader(&data, "-32", "1", "1", null);
    try data.appendSlice(std.testing.allocator, &.{ 0x3f, 0x80, 0, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
}
