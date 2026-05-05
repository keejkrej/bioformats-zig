const std = @import("std");
const bio = @import("../root.zig");

const ByteOrder = enum {
    little,
    big,

    fn endian(self: ByteOrder) std.builtin.Endian {
        return switch (self) {
            .little => .little,
            .big => .big,
        };
    }
};

const Header = struct {
    order: ByteOrder,
    width: u32,
    height: u32,
    planes: u32,
    header_size: usize,
    one_header_per_slice: bool,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "spider",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.planes, std.math.maxInt(u16))),
        .pixel_type = .float32,
        .little_endian = header.order == .little,
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
    var offset = header.header_size;
    if (header.one_header_per_slice) {
        offset = std.math.add(usize, offset, std.math.mul(usize, header.header_size, plane_index + 1) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    }
    offset = std.math.add(usize, offset, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < 108) return error.InvalidFormat;
    if (parseHeaderOrder(data, .little)) |header| return header else |little_err| {
        if (little_err != error.InvalidFormat) return little_err;
    }
    return parseHeaderOrder(data, .big);
}

fn parseHeaderOrder(data: []const u8, order: ByteOrder) bio.ReaderError!Header {
    const n_slice = try positiveFloatInt(readF32(order, data[0..4]));
    const n_row = try positiveFloatInt(readF32(order, data[4..8]));
    const irec = try positiveFloatInt(readF32(order, data[8..12]));
    const nsam = try positiveFloatInt(readF32(order, data[44..48]));
    const labrec = try positiveFloatInt(readF32(order, data[48..52]));
    const maxim = optionalFloatInt(readF32(order, data[104..108])) catch 0;

    const header_size = std.math.mul(usize, @as(usize, labrec), std.math.mul(usize, @as(usize, nsam), 4) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    const plane_len = std.math.mul(usize, @as(usize, n_row), std.math.mul(usize, @as(usize, nsam), 4) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    const base_planes = @max(n_slice, 1);
    const planes = if (maxim > 0) std.math.mul(u32, base_planes, maxim) catch return error.UnsupportedVariant else base_planes;
    const one_header_per_slice = (std.math.mul(usize, @as(usize, irec), @as(usize, nsam) * 4) catch return error.UnsupportedVariant) != plane_len and
        (std.math.mul(usize, @as(usize, irec - 1), 4) catch return error.UnsupportedVariant) != plane_len;
    const required = if (one_header_per_slice)
        std.math.add(usize, std.math.mul(usize, header_size, @as(usize, planes) + 1) catch return error.UnsupportedVariant, std.math.mul(usize, plane_len, planes) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant
    else
        std.math.add(usize, header_size, std.math.mul(usize, plane_len, planes) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (required > data.len) return error.InvalidFormat;
    return .{
        .order = order,
        .width = nsam,
        .height = n_row,
        .planes = planes,
        .header_size = header_size,
        .one_header_per_slice = one_header_per_slice,
    };
}

fn positiveFloatInt(value: f32) bio.ReaderError!u32 {
    if (!std.math.isFinite(value) or value <= 0) return error.InvalidFormat;
    const rounded = @round(value);
    if (rounded != value or rounded > @as(f32, @floatFromInt(std.math.maxInt(u32)))) return error.InvalidFormat;
    return @intFromFloat(value);
}

fn optionalFloatInt(value: f32) bio.ReaderError!u32 {
    if (!std.math.isFinite(value) or value < 0) return error.InvalidFormat;
    const rounded = @round(value);
    if (rounded != value or rounded > @as(f32, @floatFromInt(std.math.maxInt(u32)))) return error.InvalidFormat;
    return @intFromFloat(value);
}

fn readF32(order: ByteOrder, bytes: []const u8) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[0..4], order.endian()));
}

fn writeF32(bytes: []u8, index: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[index * 4 ..][0..4], @bitCast(value), .little);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendHeader(list: *std.ArrayList(u8), width: u32, height: u32, planes: u32, labrec: u32, irec: u32) !void {
    const header_size = @as(usize, width) * @as(usize, labrec) * 4;
    try list.appendNTimes(std.testing.allocator, 0, header_size);
    writeF32(list.items, 0, @floatFromInt(planes));
    writeF32(list.items, 1, @floatFromInt(height));
    writeF32(list.items, 2, @floatFromInt(irec));
    writeF32(list.items, 11, @floatFromInt(width));
    writeF32(list.items, 12, @floatFromInt(labrec));
}

test "reads spider float plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 1, 1, 13, 1);
    try data.appendSlice(std.testing.allocator, &.{ 0, 0, 0x80, 0x3f, 0, 0, 0, 0x40 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0x80, 0x3f, 0, 0, 0, 0x40 }, plane.data);
}

test "reads second spider plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 2, 27, 1);
    try data.appendSlice(std.testing.allocator, &.{ 0, 0, 0x80, 0x3f, 0, 0, 0, 0x40 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0x40 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "rejects truncated spider data" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 1, 13, 1);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
}
