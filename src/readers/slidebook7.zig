const std = @import("std");
const bio = @import("../root.zig");

const max_yaml_bytes = 64 * 1024 * 1024;

pub fn matches(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "ImageRecord.yaml") != null or
        (std.mem.indexOf(u8, data, "mWidth") != null and std.mem.indexOf(u8, data, "mNumChannels") != null);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "sldy") or hasExtension(path, "sldyz");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const scan = try parseImageRecord(data);
    return metadataFromScan(scan);
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    if (!isPath(path)) return error.InvalidFormat;
    const root = try rootDirectoryPath(allocator, path);
    defer allocator.free(root);
    const image_record = try findFirstImageRecord(allocator, io, root);
    defer allocator.free(image_record);
    const yaml = try std.Io.Dir.cwd().readFileAlloc(io, image_record, allocator, .limited(max_yaml_bytes));
    defer allocator.free(yaml);
    const scan = try parseImageRecord(yaml);
    return metadataFromScan(scan);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

const Scan = struct {
    width: u32,
    height: u32,
    size_z: u16,
    size_c: u16,
    size_t: u16,
};

fn metadataFromScan(scan: Scan) bio.ReaderError!bio.Metadata {
    const zc = std.math.mul(u32, scan.size_z, scan.size_c) catch return error.UnsupportedVariant;
    return .{
        .format = "slidebook7",
        .width = scan.width,
        .height = scan.height,
        .size_c = scan.size_c,
        .samples_per_pixel = 1,
        .size_z = scan.size_z,
        .size_t = scan.size_t,
        .pixel_type = .uint16,
        .little_endian = true,
        .plane_count = std.math.mul(u32, zc, scan.size_t) catch return error.UnsupportedVariant,
        .dimension_order = "XYCZT",
    };
}

fn parseImageRecord(yaml: []const u8) bio.ReaderError!Scan {
    const width = parseUnsignedField(yaml, "mWidth") orelse return error.InvalidFormat;
    const height = parseUnsignedField(yaml, "mHeight") orelse return error.InvalidFormat;
    const planes = parseUnsignedField(yaml, "mNumPlanes") orelse return error.InvalidFormat;
    const channels = parseUnsignedField(yaml, "mNumChannels") orelse return error.InvalidFormat;
    const timepoints = parseUnsignedField(yaml, "mNumTimepoints") orelse 1;
    if (width == 0 or height == 0 or planes == 0 or channels == 0 or timepoints == 0) return error.InvalidFormat;
    return .{
        .width = width,
        .height = height,
        .size_z = boundedDimension(planes),
        .size_c = boundedDimension(channels),
        .size_t = boundedDimension(timepoints),
    };
}

fn parseUnsignedField(text: []const u8, name: []const u8) ?u32 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, name)) |found| {
        if (found > 0 and isIdentifier(text[found - 1])) {
            pos = found + name.len;
            continue;
        }
        var cursor = found + name.len;
        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor >= text.len or text[cursor] != ':') {
            pos = cursor;
            continue;
        }
        cursor += 1;
        while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        const start = cursor;
        while (cursor < text.len and std.ascii.isDigit(text[cursor])) : (cursor += 1) {}
        if (cursor == start) return null;
        return std.fmt.parseUnsigned(u32, text[start..cursor], 10) catch null;
    }
    return null;
}

fn isIdentifier(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn findFirstImageRecord(allocator: std.mem.Allocator, io: std.Io, root: []const u8) ![]u8 {
    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer root_dir.close(io);

    var iter = root_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory or !std.ascii.endsWithIgnoreCase(entry.name, ".imgdir")) continue;
        const image_dir = try joinPath(allocator, root, entry.name);
        defer allocator.free(image_dir);
        const image_record = try joinPath(allocator, image_dir, "ImageRecord.yaml");
        if (fileExists(io, image_record)) return image_record;
        allocator.free(image_record);
    }
    return error.FileNotFound;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn rootDirectoryPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return error.InvalidFormat;
    const out = try allocator.alloc(u8, dot + 4);
    @memcpy(out[0..dot], path[0..dot]);
    @memcpy(out[dot..], ".dir");
    return out;
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    const sep: u8 = if (std.mem.indexOfScalar(u8, base, '\\') != null) '\\' else '/';
    const needs_sep = base.len != 0 and base[base.len - 1] != '/' and base[base.len - 1] != '\\';
    const extra: usize = if (needs_sep) 1 else 0;
    const out = try allocator.alloc(u8, base.len + extra + name.len);
    @memcpy(out[0..base.len], base);
    if (needs_sep) out[base.len] = sep;
    @memcpy(out[base.len + extra ..], name);
    return out;
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn boundedDimension(value: u32) u16 {
    return @intCast(@min(@max(value, 1), std.math.maxInt(u16)));
}

const sample_image_record =
    \\StartClass:
    \\  ClassName: CImageRecord70
    \\  mWidth: 13
    \\  mHeight: 9
    \\  mNumPlanes: 3
    \\  mNumChannels: 2
    \\  mNumTimepoints: 5
    \\EndClass:
;

test "reads slidebook7 image record metadata" {
    try std.testing.expect(matches(sample_image_record));
    const metadata = try readMetadata(sample_image_record);
    try std.testing.expectEqualStrings("slidebook7", metadata.format);
    try std.testing.expectEqual(@as(u32, 13), metadata.width);
    try std.testing.expectEqual(@as(u32, 9), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 5), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 30), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, sample_image_record, 0));
}

test "reads slidebook7 metadata from sldy root directory" {
    const root_dir = "slidebook7-test.dir";
    const image_dir = "slidebook7-test.dir/Capture.imgdir";
    const slide_path = "slidebook7-test.sldy";
    const record_path = "slidebook7-test.dir/Capture.imgdir/ImageRecord.yaml";
    std.Io.Dir.cwd().deleteFile(std.testing.io, record_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, slide_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, image_dir) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root_dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root_dir, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root_dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, image_dir, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, image_dir) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = slide_path, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, slide_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = record_path, .data = sample_image_record });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, record_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, slide_path);
    try std.testing.expectEqualStrings("slidebook7", metadata.format);
    try std.testing.expectEqual(@as(u32, 13), metadata.width);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
}

test "rejects slidebook7 image record without dimensions" {
    try std.testing.expect(!matches("not slidebook"));
    try std.testing.expectError(error.InvalidFormat, readMetadata("mWidth: 1\n"));
}
