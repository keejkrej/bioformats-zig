const std = @import("std");
const bio = @import("../root.zig");

const max_yaml_bytes = 64 * 1024 * 1024;
const max_npy_bytes = 512 * 1024 * 1024;
const npy_magic = "\x93NUMPY";

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

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const metadata = try readMetadataPath(allocator, io, path);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    try region.validate(metadata);

    const zct = try planeToZct(metadata, plane_index);
    const root = try rootDirectoryPath(allocator, path);
    defer allocator.free(root);
    const image_dir = try findFirstImageDirectory(allocator, io, root);
    defer allocator.free(image_dir);
    const image_data_name = try std.fmt.allocPrint(allocator, "ImageData_Ch{d}_TP{d:0>7}.npy", .{ zct.c, zct.t });
    defer allocator.free(image_data_name);
    const image_data_path = try joinPath(allocator, image_dir, image_data_name);
    defer allocator.free(image_data_path);

    const npy = try std.Io.Dir.cwd().readFileAlloc(io, image_data_path, allocator, .limited(max_npy_bytes));
    defer allocator.free(npy);
    const header = try parseNpyHeader(npy);
    if (header.pixel_type != metadata.pixel_type or header.little_endian != metadata.little_endian) return error.UnsupportedVariant;

    const plane_len = try planeByteCount(metadata);
    const offset = try std.math.add(usize, header.data_offset, try std.math.mul(usize, plane_len, zct.z));
    if (offset > npy.len or npy.len - offset < plane_len) return error.TruncatedData;

    const full = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(full);
    @memcpy(full, npy[offset..][0..plane_len]);
    if (region.isFull(metadata)) return .{ .metadata = metadata, .data = full };
    defer allocator.free(full);
    return .{
        .metadata = metadata,
        .data = try bio.cropPlane(allocator, .{ .metadata = metadata, .data = full }, region),
    };
}

const Scan = struct {
    width: u32,
    height: u32,
    size_z: u16,
    size_c: u16,
    size_t: u16,
};

const Zct = struct {
    z: u32,
    c: u32,
    t: u32,
};

const NpyHeader = struct {
    data_offset: usize,
    pixel_type: bio.PixelType,
    little_endian: bool,
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
    const image_dir = try findFirstImageDirectory(allocator, io, root);
    defer allocator.free(image_dir);
    return joinPath(allocator, image_dir, "ImageRecord.yaml");
}

fn findFirstImageDirectory(allocator: std.mem.Allocator, io: std.Io, root: []const u8) ![]u8 {
    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer root_dir.close(io);

    var iter = root_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory or !std.ascii.endsWithIgnoreCase(entry.name, ".imgdir")) continue;
        const image_dir = try joinPath(allocator, root, entry.name);
        const image_record = try joinPath(allocator, image_dir, "ImageRecord.yaml");
        defer allocator.free(image_record);
        if (fileExists(io, image_record)) return image_dir;
        allocator.free(image_dir);
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

fn planeToZct(metadata: bio.Metadata, plane_index: u32) bio.ReaderError!Zct {
    const size_z: u32 = metadata.size_z;
    const size_c: u32 = metadata.size_c;
    const zc = std.math.mul(u32, size_z, size_c) catch return error.InvalidPlaneIndex;
    return .{
        .z = plane_index % size_z,
        .c = (plane_index / size_z) % size_c,
        .t = plane_index / zc,
    };
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn parseNpyHeader(data: []const u8) bio.ReaderError!NpyHeader {
    if (data.len < 10 or !std.mem.eql(u8, data[0..npy_magic.len], npy_magic)) return error.InvalidFormat;
    const major = data[6];
    const minor = data[7];
    if (minor != 0) return error.UnsupportedVariant;
    var header_len: usize = 0;
    var header_start: usize = 0;
    if (major == 1) {
        header_len = std.mem.readInt(u16, data[8..10], .little);
        header_start = 10;
    } else if (major == 2 or major == 3) {
        if (data.len < 12) return error.TruncatedData;
        header_len = std.mem.readInt(u32, data[8..12], .little);
        header_start = 12;
    } else {
        return error.UnsupportedVariant;
    }
    const data_offset = std.math.add(usize, header_start, header_len) catch return error.UnsupportedVariant;
    if (data_offset > data.len) return error.TruncatedData;
    const header = data[header_start..data_offset];
    if (std.mem.indexOf(u8, header, "'fortran_order': False") == null and
        std.mem.indexOf(u8, header, "\"fortran_order\": False") == null)
    {
        return error.UnsupportedVariant;
    }
    const descr = parseDescr(header) orelse return error.UnsupportedVariant;
    return .{
        .data_offset = data_offset,
        .pixel_type = descr.pixel_type,
        .little_endian = descr.little_endian,
    };
}

fn parseDescr(header: []const u8) ?struct { pixel_type: bio.PixelType, little_endian: bool } {
    const key = std.mem.indexOf(u8, header, "descr") orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, header, key, ':') orelse return null;
    var pos = colon + 1;
    while (pos < header.len and (std.ascii.isWhitespace(header[pos]) or header[pos] == '\'' or header[pos] == '"')) : (pos += 1) {}
    if (pos + 3 > header.len) return null;
    const endian = header[pos];
    const dtype = header[pos + 1 .. pos + 3];
    const little = switch (endian) {
        '<' => true,
        '>' => false,
        '|' => true,
        else => return null,
    };
    if (std.mem.eql(u8, dtype, "u2")) return .{ .pixel_type = .uint16, .little_endian = little };
    if (std.mem.eql(u8, dtype, "i2")) return .{ .pixel_type = .int16, .little_endian = little };
    if (std.mem.eql(u8, dtype, "u4")) return .{ .pixel_type = .uint32, .little_endian = little };
    if (std.mem.eql(u8, dtype, "i4")) return .{ .pixel_type = .int32, .little_endian = little };
    if (std.mem.eql(u8, dtype, "u1")) return .{ .pixel_type = .uint8, .little_endian = true };
    if (std.mem.eql(u8, dtype, "i1")) return .{ .pixel_type = .int8, .little_endian = true };
    return null;
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

fn makeNpy(allocator: std.mem.Allocator, pixels: []const u8) ![]u8 {
    const header_text = "{'descr': '<u2', 'fortran_order': False, 'shape': (2, 2, 3), }";
    var header_len = header_text.len + 1;
    while ((10 + header_len) % 16 != 0) header_len += 1;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, npy_magic);
    try out.append(allocator, 1);
    try out.append(allocator, 0);
    var header_len_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &header_len_bytes, @intCast(header_len), .little);
    try out.appendSlice(allocator, &header_len_bytes);
    try out.appendSlice(allocator, header_text);
    try out.appendNTimes(allocator, ' ', header_len - header_text.len - 1);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, pixels);
    return out.toOwnedSlice(allocator);
}

test "reads slidebook7 uncompressed npy plane from sldy root directory" {
    const root_dir = "slidebook7-plane-test.dir";
    const image_dir = "slidebook7-plane-test.dir/Capture.imgdir";
    const slide_path = "slidebook7-plane-test.sldy";
    const record_path = "slidebook7-plane-test.dir/Capture.imgdir/ImageRecord.yaml";
    const npy_path = "slidebook7-plane-test.dir/Capture.imgdir/ImageData_Ch0_TP0000000.npy";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, slide_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root_dir) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, slide_path) catch {};

    try std.Io.Dir.cwd().createDir(std.testing.io, root_dir, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, image_dir, .default_dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = slide_path, .data = "" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = record_path,
        .data =
        \\StartClass:
        \\  ClassName: CImageRecord70
        \\  mWidth: 3
        \\  mHeight: 2
        \\  mNumPlanes: 2
        \\  mNumChannels: 1
        \\  mNumTimepoints: 1
        \\EndClass:
        ,
    });

    const pixels = [_]u8{
        1,  0, 2,  0, 3,  0,
        4,  0, 5,  0, 6,  0,
        7,  0, 8,  0, 9,  0,
        10, 0, 11, 0, 12, 0,
    };
    const npy = try makeNpy(std.testing.allocator, &pixels);
    defer std.testing.allocator.free(npy);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = npy_path, .data = npy });

    const plane = try readPlanePathRegionIndex(
        std.testing.allocator,
        std.testing.io,
        slide_path,
        1,
        .{ .x = 1, .y = 0, .width = 2, .height = 2 },
    );
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("slidebook7", plane.metadata.format);
    try std.testing.expectEqual(bio.PixelType.uint16, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 8, 0, 9, 0, 11, 0, 12, 0 }, plane.data);
}

test "rejects slidebook7 image record without dimensions" {
    try std.testing.expect(!matches("not slidebook"));
    try std.testing.expectError(error.InvalidFormat, readMetadata("mWidth: 1\n"));
}
