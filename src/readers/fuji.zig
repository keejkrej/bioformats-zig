const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

const Header = struct {
    width: u32,
    height: u32,
    pixel_type: bio.PixelType,
    image_name: ?[]const u8 = null,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "inf") or hasExtension(path, "img");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    return metadataFromHeader(try parseHeader(data));
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    if (plane_index != 0) return error.InvalidPlaneIndex;
    if (!matches(data)) return error.InvalidFormat;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const inf = try readInfFile(allocator, io, path);
    defer allocator.free(inf);
    var metadata = try readMetadata(inf);
    metadata.image_description = null;
    return metadata;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    if (plane_index != 0) return error.InvalidPlaneIndex;
    const inf = try readInfFile(allocator, io, path);
    defer allocator.free(inf);
    var metadata = try readMetadata(inf);
    metadata.image_description = null;
    try region.validate(metadata);

    const img = try readImgFile(allocator, io, path);
    defer allocator.free(img);

    const plane_len = try planeByteCount(metadata);
    if (img.len < plane_len) return error.TruncatedData;

    if (region.isFull(metadata)) {
        const out = try allocator.alloc(u8, plane_len);
        @memcpy(out, img[0..plane_len]);
        return .{ .metadata = metadata, .data = out };
    }

    const bytes_per_pixel = metadata.bytesPerPixel();
    const src_row_bytes = std.math.mul(usize, metadata.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const dst_row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, dst_row_bytes, region.height) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    var row: usize = 0;
    while (row < region.height) : (row += 1) {
        const src_y = @as(usize, region.y) + row;
        const src_x = @as(usize, region.x) * bytes_per_pixel;
        const src_offset = src_y * src_row_bytes + src_x;
        const dst_offset = row * dst_row_bytes;
        @memcpy(out[dst_offset..][0..dst_row_bytes], img[src_offset..][0..dst_row_bytes]);
    }
    return .{ .metadata = metadata, .data = out };
}

fn metadataFromHeader(header: Header) bio.Metadata {
    return .{
        .format = "fuji",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
        .little_endian = false,
        .plane_count = 1,
        .dimension_order = "XYCZT",
        .image_description = header.image_name,
    };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    var line_number: usize = 0;
    var bits: u32 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    var image_name: ?[]const u8 = null;

    var rows = rowIterator(data);
    while (rows.next()) |line| : (line_number += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        switch (line_number) {
            1 => image_name = if (trimmed.len == 0) null else trimmed,
            5 => bits = try parsePositiveU32(trimmed),
            6 => width = try parsePositiveU32(trimmed),
            7 => height = try parsePositiveU32(trimmed),
            else => {},
        }
    }
    if (line_number < 8 or width == 0 or height == 0 or bits == 0) return error.InvalidFormat;
    return .{
        .width = width,
        .height = height,
        .pixel_type = switch (bits) {
            8 => .uint8,
            16 => .uint16,
            32 => .uint32,
            else => return error.UnsupportedVariant,
        },
        .image_name = image_name,
    };
}

fn readInfFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "inf")) return readFile(allocator, io, path);
    const lower = try replaceExtension(allocator, path, ".inf");
    defer allocator.free(lower);
    return readFile(allocator, io, lower) catch |lower_err| {
        const upper = try replaceExtension(allocator, path, ".INF");
        defer allocator.free(upper);
        return readFile(allocator, io, upper) catch lower_err;
    };
}

fn readImgFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "img")) return readFile(allocator, io, path);
    const lower = try replaceExtension(allocator, path, ".img");
    defer allocator.free(lower);
    return readFile(allocator, io, lower) catch |lower_err| {
        const upper = try replaceExtension(allocator, path, ".IMG");
        defer allocator.free(upper);
        return readFile(allocator, io, upper) catch lower_err;
    };
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    const out = try allocator.alloc(u8, dot + extension.len);
    @memcpy(out[0..dot], path[0..dot]);
    @memcpy(out[dot..], extension);
    return out;
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

const RowIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *RowIterator) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '\n' and self.data[self.pos] != '\r') : (self.pos += 1) {}
        const end = self.pos;
        while (self.pos < self.data.len and (self.data[self.pos] == '\n' or self.data[self.pos] == '\r')) : (self.pos += 1) {}
        return self.data[start..end];
    }
};

fn rowIterator(data: []const u8) RowIterator {
    return .{ .data = data };
}

fn parsePositiveU32(value: []const u8) bio.ReaderError!u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidFormat;
    if (parsed == 0) return error.InvalidFormat;
    return parsed;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

test "reads fuji inf metadata" {
    const inf =
        "unused\n" ++
        "Sample\n" ++
        "unused\n" ++
        "12.5\n" ++
        "8.5\n" ++
        "16\n" ++
        "2\n" ++
        "3\n" ++
        "unused\n" ++
        "unused\n" ++
        "Mon Jan 01 12:00:00 2024\n";

    const metadata = try readMetadata(inf);
    try std.testing.expectEqualStrings("fuji", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 3), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expectEqualStrings("Sample", metadata.image_description.?);
}

test "reads fuji companion img pixels with crop" {
    const inf_path = "fuji-test.inf";
    const img_path = "fuji-test.img";
    const inf =
        "unused\n" ++
        "Sample\n" ++
        "unused\n" ++
        "0\n" ++
        "0\n" ++
        "16\n" ++
        "2\n" ++
        "2\n";
    const pixels = [_]u8{
        1, 0, 2, 0,
        3, 0, 4, 0,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = inf_path, .data = inf });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, inf_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = img_path, .data = &pixels });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, img_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, img_path, 0, .{
        .x = 1,
        .y = 0,
        .width = 1,
        .height = 2,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 4, 0 }, plane.data);
}

test "rejects unsupported fuji bit depth" {
    const inf =
        "unused\n" ++
        "Sample\n" ++
        "unused\n" ++
        "0\n" ++
        "0\n" ++
        "12\n" ++
        "1\n" ++
        "1\n";

    try std.testing.expectError(error.UnsupportedVariant, readMetadata(inf));
}
