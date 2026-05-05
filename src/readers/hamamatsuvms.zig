const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;
const max_tile_span = 61440;

pub fn matches(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "[Virtual Microscope Specimen]") != null and
        (std.mem.indexOf(u8, data, "NoJpegRows") != null or std.mem.indexOf(u8, data, "ImageFile") != null);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "vms");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!matches(data)) return error.InvalidFormat;
    return error.UnsupportedVariant;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const bytes = try readFile(allocator, io, path);
    defer allocator.free(bytes);
    if (!matches(bytes)) return error.InvalidFormat;

    const rows = parseU32(valueForKey(bytes, "NoJpegRows") orelse return error.InvalidFormat) orelse return error.InvalidFormat;
    const cols = parseU32(valueForKey(bytes, "NoJpegColumns") orelse return error.InvalidFormat) orelse return error.InvalidFormat;
    if (rows == 0 or cols == 0) return error.InvalidFormat;

    const last_tile_key = try std.fmt.allocPrint(allocator, "ImageFile({d},{d})", .{ cols - 1, rows - 1 });
    defer allocator.free(last_tile_key);
    const tile_name = valueForKey(bytes, last_tile_key) orelse valueForKey(bytes, "ImageFile") orelse return error.InvalidFormat;
    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    const tile_path = try joinPath(allocator, parent, tile_name);
    defer allocator.free(tile_path);
    const tile = try readFile(allocator, io, tile_path);
    defer allocator.free(tile);
    const dims = try jpegDimensions(tile);

    return .{
        .format = "hamamatsuvms",
        .width = (cols - 1) * max_tile_span + dims.width,
        .height = (rows - 1) * max_tile_span + dims.height,
        .size_c = 3,
        .samples_per_pixel = 3,
        .pixel_type = .rgb8,
        .plane_count = 1,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    _ = allocator;
    _ = io;
    _ = path;
    _ = plane_index;
    _ = region;
    return error.UnsupportedVariant;
}

const JpegDims = struct {
    width: u32,
    height: u32,
};

fn jpegDimensions(data: []const u8) !JpegDims {
    if (data.len < 4 or data[0] != 0xff or data[1] != 0xd8) return error.InvalidFormat;
    var i: usize = 2;
    while (i + 3 < data.len) {
        while (i < data.len and data[i] != 0xff) : (i += 1) {}
        while (i < data.len and data[i] == 0xff) : (i += 1) {}
        if (i >= data.len) break;
        const marker = data[i];
        i += 1;
        if (marker == 0xd9 or marker == 0xda) break;
        if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
        if (i + 2 > data.len) return error.TruncatedData;
        const segment_len = readU16BE(data[i..][0..2]);
        if (segment_len < 2 or i + segment_len > data.len) return error.TruncatedData;
        if (isSofMarker(marker)) {
            if (segment_len < 8) return error.InvalidFormat;
            return .{
                .height = readU16BE(data[i + 3 ..][0..2]),
                .width = readU16BE(data[i + 5 ..][0..2]),
            };
        }
        i += segment_len;
    }
    return error.InvalidFormat;
}

fn isSofMarker(marker: u8) bool {
    return marker == 0xc0 or marker == 0xc1 or marker == 0xc2 or marker == 0xc3 or
        marker == 0xc5 or marker == 0xc6 or marker == 0xc7 or marker == 0xc9 or
        marker == 0xca or marker == 0xcb or marker == 0xcd or marker == 0xce or marker == 0xcf;
}

fn valueForKey(data: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or line[0] == '[' or line[0] == ';' or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const candidate = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(candidate, key)) continue;
        return std.mem.trim(u8, line[eq + 1 ..], " \t");
    }
    return null;
}

fn parseU32(value: []const u8) ?u32 {
    return std.fmt.parseUnsigned(u32, std.mem.trim(u8, value, " \t\r\n"), 10) catch null;
}

fn readU16BE(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn parentPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const sep = lastSeparator(path) orelse return allocator.dupe(u8, ".");
    if (sep == 0) return allocator.dupe(u8, path[0..1]);
    return allocator.dupe(u8, path[0..sep]);
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    if (isAbsolutePath(name)) return allocator.dupe(u8, name);
    const sep: u8 = if (std.mem.indexOfScalar(u8, base, '\\') != null) '\\' else '/';
    const needs_sep = base.len != 0 and base[base.len - 1] != '/' and base[base.len - 1] != '\\';
    const extra: usize = if (needs_sep) 1 else 0;
    const out = try allocator.alloc(u8, base.len + extra + name.len);
    @memcpy(out[0..base.len], base);
    if (needs_sep) out[base.len] = sep;
    @memcpy(out[base.len + extra ..], name);
    return out;
}

fn lastSeparator(path: []const u8) ?usize {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    if (slash == null) return backslash;
    if (backslash == null) return slash;
    return @max(slash.?, backslash.?);
}

fn isAbsolutePath(path: []const u8) bool {
    if (path.len >= 1 and (path[0] == '/' or path[0] == '\\')) return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

const tiny_jpeg = [_]u8{
    0xff, 0xd8,
    0xff, 0xe0,
    0x00, 0x04,
    0x00, 0x00,
    0xff, 0xc0,
    0x00, 0x11,
    0x08, 0x00,
    0x02, 0x00,
    0x03, 0x03,
    0x01, 0x11,
    0x00, 0x02,
    0x11, 0x00,
    0x03, 0x11,
    0x00, 0xff,
    0xd9,
};

test "reads hamamatsu vms metadata from jpeg tile dimensions" {
    const root = "hamamatsu-vms-test";
    const vms_path = "hamamatsu-vms-test/slide.vms";
    const tile_path = "hamamatsu-vms-test/tile.jpg";
    cleanupFixture(root, vms_path, tile_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tile_path, .data = &tiny_jpeg });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tile_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = vms_path,
        .data = "[Virtual Microscope Specimen]\nNoLayers=1\nNoJpegRows=2\nNoJpegColumns=2\nImageFile=tile.jpg\nImageFile(1,1)=tile.jpg\n",
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, vms_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, vms_path);
    try std.testing.expectEqualStrings("hamamatsuvms", metadata.format);
    try std.testing.expectEqual(@as(u32, 61443), metadata.width);
    try std.testing.expectEqual(@as(u32, 61442), metadata.height);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
}

fn cleanupFixture(root: []const u8, vms_path: []const u8, tile_path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, tile_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, vms_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
}
