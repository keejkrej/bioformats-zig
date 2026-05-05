const std = @import("std");
const bio = @import("../root.zig");

const Header = struct {
    width: u32,
    height: u32,
    size_z: u16,
    size_t: u16,
    pixel_type: bio.PixelType,
    little_endian: bool,
    pixel_data_min: usize,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "varianfdf",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
    }) catch return false;
    const pixel_bytes = std.math.mul(usize, plane_len, @as(usize, header.size_z) * @as(usize, header.size_t)) catch return false;
    return data.len >= header.pixel_data_min and data.len - header.pixel_data_min >= pixel_bytes;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "varianfdf",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = header.size_z,
        .size_t = header.size_t,
        .pixel_type = header.pixel_type,
        .little_endian = header.little_endian,
        .plane_count = @as(u32, header.size_z) * @as(u32, header.size_t),
        .dimension_order = "XYTZC",
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
    const pixel_bytes = std.math.mul(usize, plane_len, metadata.plane_count) catch return error.UnsupportedVariant;
    if (data.len < header.pixel_data_min or data.len - header.pixel_data_min < pixel_bytes) return error.TruncatedData;
    const pixel_start = data.len - pixel_bytes;
    const src_offset = std.math.add(usize, pixel_start, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    flipRows(out, data[src_offset..][0..plane_len], metadata);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    const header_end = std.mem.indexOfScalar(u8, data, 0x0c) orelse return error.InvalidFormat;
    const text = data[0..header_end];
    var width: u32 = 0;
    var height: u32 = 0;
    var size_z: u32 = 1;
    var size_t: u32 = 1;
    var bits: u32 = 0;
    var stored_float = false;
    var little_endian = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const semi = std.mem.indexOfScalar(u8, line[eq + 1 ..], ';') orelse continue;
        const value = std.mem.trim(u8, line[eq + 1 .. eq + 1 + semi], " \t");
        const before = std.mem.trim(u8, line[0..eq], " \t");
        const space = std.mem.lastIndexOfAny(u8, before, " \t") orelse continue;
        const var_name = std.mem.trim(u8, before[space + 1 ..], " \t");

        if (std.mem.eql(u8, var_name, "*storage")) {
            stored_float = std.mem.eql(u8, std.mem.trim(u8, value, "\" "), "float");
        } else if (std.mem.eql(u8, var_name, "bits")) {
            bits = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, var_name, "matrix[]")) {
            const dims = try parseArrayInts(value);
            if (dims.len < 2) return error.InvalidFormat;
            width = dims.values[0];
            height = dims.values[1];
            if (dims.len > 2) size_z = dims.values[2];
        } else if (std.mem.eql(u8, var_name, "slices")) {
            size_z = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, var_name, "echoes")) {
            size_t = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, var_name, "bigendian")) {
            little_endian = std.mem.eql(u8, value, "0");
        }
    }

    if (width == 0 or height == 0 or size_z == 0 or size_t == 0 or bits == 0) return error.InvalidFormat;
    if (size_z > std.math.maxInt(u16) or size_t > std.math.maxInt(u16)) return error.UnsupportedVariant;
    return .{
        .width = width,
        .height = height,
        .size_z = @intCast(size_z),
        .size_t = @intCast(size_t),
        .pixel_type = switch (bits) {
            8 => .uint8,
            16 => .uint16,
            32 => if (stored_float) .float32 else .uint32,
            else => return error.UnsupportedVariant,
        },
        .little_endian = little_endian,
        .pixel_data_min = header_end + 1,
    };
}

const ArrayInts = struct {
    values: [3]u32,
    len: usize,
};

fn parseArrayInts(value: []const u8) bio.ReaderError!ArrayInts {
    const inner = std.mem.trim(u8, value, "{} ");
    var out = ArrayInts{ .values = .{ 0, 0, 0 }, .len = 0 };
    var parts = std.mem.splitScalar(u8, inner, ',');
    while (parts.next()) |part| {
        if (out.len == out.values.len) break;
        const item = std.mem.trim(u8, part, " \t\"");
        const parsed = std.fmt.parseFloat(f64, item) catch return error.InvalidFormat;
        if (parsed <= 0) return error.InvalidFormat;
        out.values[out.len] = @intFromFloat(parsed);
        out.len += 1;
    }
    return out;
}

fn flipRows(out: []u8, src: []const u8, metadata: bio.Metadata) void {
    const row_len = @as(usize, metadata.width) * metadata.bytesPerPixel();
    var row: usize = 0;
    while (row < metadata.height) : (row += 1) {
        const src_row = metadata.height - row - 1;
        @memcpy(out[row * row_len ..][0..row_len], src[src_row * row_len ..][0..row_len]);
    }
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn appendHeader(list: *std.ArrayList(u8), width: u32, height: u32, size_z: u32, bits: u32, storage: []const u8, little: bool) !void {
    const bigendian: u32 = if (little) 0 else 1;
    const header = try std.fmt.allocPrint(std.testing.allocator,
        \\float  matrix[] = {{{d}, {d}, {d}}};
        \\char  *storage = "{s}";
        \\int  bits = {d};
        \\int  bigendian = {d};
        \\
    , .{ width, height, size_z, storage, bits, bigendian });
    defer std.testing.allocator.free(header);
    try list.appendSlice(std.testing.allocator, header);
    try list.append(std.testing.allocator, 0x0c);
}

test "reads varian fdf uint16 planes and flips rows" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 2, 2, 16, "integer", true);
    try data.appendSlice(std.testing.allocator, &.{
        1, 0, 2, 0,
        3, 0, 4, 0,
        5, 0, 6, 0,
        7, 0, 8, 0,
    });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const second = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{
        7, 0, 8, 0,
        5, 0, 6, 0,
    }, second.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads varian fdf float32 metadata" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 1, 32, "float", false);
    try data.appendSlice(std.testing.allocator, &.{ 0x3f, 0x80, 0, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x3f, 0x80, 0, 0 }, plane.data);
}

test "rejects truncated varian fdf pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 2, 1, 8, "integer", true);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2 });

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}
