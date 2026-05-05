const std = @import("std");
const bio = @import("../root.zig");

const magic = " IDENTIFICATION";
const max_companion_bytes = 512 * 1024 * 1024;

const Header = struct {
    width: u32,
    height: u32,
    record_width: u32,
    reverse_x: bool,
    reverse_y: bool,
};

pub fn matches(data: []const u8) bool {
    return data.len >= magic.len and std.mem.eql(u8, data[0..magic.len], magic);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "hdr") or hasExtension(path, "img");
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
    const hdr = try readHdrFile(allocator, io, path);
    defer allocator.free(hdr);
    return readMetadata(hdr);
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    if (plane_index != 0) return error.InvalidPlaneIndex;
    const hdr = try readHdrFile(allocator, io, path);
    defer allocator.free(hdr);
    const header = try parseHeader(hdr);
    const metadata = metadataFromHeader(header);
    try region.validate(metadata);

    const img = try readImgFile(allocator, io, path);
    defer allocator.free(img);

    const out_len = try planeByteCount(region.width, region.height);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    const row_stride = try rowStrideBytes(header);
    var dst_y: usize = 0;
    while (dst_y < region.height) : (dst_y += 1) {
        var dst_x: usize = 0;
        while (dst_x < region.width) : (dst_x += 1) {
            const display_x = @as(usize, region.x) + dst_x;
            const display_y = @as(usize, region.y) + dst_y;
            const src_x = if (header.reverse_x) @as(usize, header.width) - 1 - display_x else display_x;
            const src_y = if (header.reverse_y) @as(usize, header.height) - 1 - display_y else display_y;
            const src_offset = src_y * row_stride + src_x * 2;
            if (src_offset > img.len or img.len - src_offset < 2) return error.TruncatedData;
            const dst_offset = (dst_y * region.width + dst_x) * 2;
            @memcpy(out[dst_offset..][0..2], img[src_offset..][0..2]);
        }
    }

    return .{ .metadata = metadata, .data = out };
}

fn metadataFromHeader(header: Header) bio.Metadata {
    return .{
        .format = "pds",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = .uint16,
        .little_endian = true,
        .plane_count = 1,
        .dimension_order = "XYCZT",
    };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    var width: u32 = 0;
    var height: u32 = 0;
    var record_width: u32 = 0;
    var reverse_x = false;
    var reverse_y = false;

    var rows = rowIterator(data);
    while (rows.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const comment = std.mem.indexOfScalarPos(u8, line, eq + 1, '/') orelse line.len;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = cleanValue(line[eq + 1 .. comment]);
        if (std.mem.eql(u8, key, "NXP")) {
            width = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "NYP")) {
            height = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "SIGNX")) {
            reverse_x = value.len > 0 and value[0] == '-';
        } else if (std.mem.eql(u8, key, "SIGNY")) {
            reverse_y = value.len > 0 and value[0] == '-';
        } else if (std.mem.eql(u8, key, "COLOR")) {
            const color = try parsePositiveU32(value);
            if (color == 4) return error.UnsupportedVariant;
        } else if (std.mem.eql(u8, key, "FILE REC LEN")) {
            record_width = try parsePositiveU32(value) / 2;
        }
    }
    if (width == 0 or height == 0) return error.InvalidFormat;
    return .{
        .width = width,
        .height = height,
        .record_width = record_width,
        .reverse_x = reverse_x,
        .reverse_y = reverse_y,
    };
}

fn readHdrFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "hdr")) return readFile(allocator, io, path);
    const lower = try replaceExtension(allocator, path, ".hdr");
    defer allocator.free(lower);
    return readFile(allocator, io, lower) catch |lower_err| {
        const upper = try replaceExtension(allocator, path, ".HDR");
        defer allocator.free(upper);
        return readFile(allocator, io, upper) catch lower_err;
    };
}

fn readImgFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "img")) return readFile(allocator, io, path);
    const upper = try replaceExtension(allocator, path, ".IMG");
    defer allocator.free(upper);
    return readFile(allocator, io, upper) catch |upper_err| {
        const lower = try replaceExtension(allocator, path, ".img");
        defer allocator.free(lower);
        return readFile(allocator, io, lower) catch upper_err;
    };
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn rowStrideBytes(header: Header) bio.ReaderError!usize {
    var row_pixels = header.width;
    if (header.record_width > 0) {
        const remainder = header.width % header.record_width;
        const pad = header.record_width - remainder;
        row_pixels = std.math.add(u32, header.width, pad) catch return error.UnsupportedVariant;
    }
    return std.math.mul(usize, row_pixels, 2) catch return error.UnsupportedVariant;
}

fn planeByteCount(width: u32, height: u32) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, width, height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, 2) catch return error.UnsupportedVariant;
}

fn cleanValue(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n'");
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

test "reads pds header metadata" {
    const header =
        " IDENTIFICATION\r\n" ++
        "NXP = 2\r\n" ++
        "NYP = 3\r\n" ++
        "COLOR = 1\r\n" ++
        "FILE REC LEN = 8\r\n";

    try std.testing.expect(matches(header));
    const metadata = try readMetadata(header);
    try std.testing.expectEqualStrings("pds", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 3), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
}

test "reads pds companion pixels with padding and reverse crop" {
    const hdr_path = "pds-test.hdr";
    const img_path = "pds-test.IMG";
    const header =
        " IDENTIFICATION\r\n" ++
        "NXP=3\r\n" ++
        "NYP=2\r\n" ++
        "SIGNX='-'\r\n" ++
        "SIGNY='-'\r\n" ++
        "COLOR=1\r\n" ++
        "FILE REC LEN=8\r\n";
    const pixels = [_]u8{
        1, 0, 2, 0, 3, 0, 0xff, 0xff,
        4, 0, 5, 0, 6, 0, 0xff, 0xff,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = hdr_path, .data = header });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hdr_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = img_path, .data = &pixels });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, img_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, hdr_path, 0, .{
        .x = 1,
        .y = 0,
        .width = 2,
        .height = 1,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 5, 0, 4, 0 }, plane.data);
}

test "rejects pds rgb color variant" {
    const header =
        " IDENTIFICATION\r\n" ++
        "NXP=1\r\n" ++
        "NYP=1\r\n" ++
        "COLOR=4\r\n";
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(header));
}
