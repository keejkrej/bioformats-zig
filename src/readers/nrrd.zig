const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

const Header = struct {
    width: u32,
    height: u32,
    planes: u32,
    size_c: u16,
    samples_per_pixel: u16,
    pixel_type: bio.PixelType,
    little_endian: bool,
    data_offset: usize,
    data_file: ?[]const u8,
};

pub fn matches(data: []const u8) bool {
    return std.mem.startsWith(u8, data, "NRRD");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "nrrd",
        .width = header.width,
        .height = header.height,
        .size_c = header.size_c,
        .samples_per_pixel = header.samples_per_pixel,
        .size_z = @intCast(@min(header.planes, std.math.maxInt(u16))),
        .pixel_type = header.pixel_type,
        .little_endian = header.little_endian,
        .plane_count = header.planes,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    if (header.data_file != null) return error.UnsupportedVariant;
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    return readPlaneFromBytes(allocator, data, header, metadata, plane_index, .{
        .x = 0,
        .y = 0,
        .width = metadata.width,
        .height = metadata.height,
    });
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "nrrd") or hasExtension(path, "nhdr");
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const header_bytes = try readFile(allocator, io, path);
    defer allocator.free(header_bytes);
    return readMetadata(header_bytes);
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const header_bytes = try readFile(allocator, io, path);
    defer allocator.free(header_bytes);
    const metadata = try readMetadata(header_bytes);
    const header = try parseHeader(header_bytes);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    try region.validate(metadata);

    if (header.data_file) |data_file| {
        const raw_path = try joinSibling(allocator, path, data_file);
        defer allocator.free(raw_path);
        const raw = try readFile(allocator, io, raw_path);
        defer allocator.free(raw);
        return readPlaneFromBytes(allocator, raw, header, metadata, plane_index, region);
    }
    return readPlaneFromBytes(allocator, header_bytes, header, metadata, plane_index, region);
}

fn readPlaneFromBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    header: Header,
    metadata: bio.Metadata,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    const plane_len = try planeByteCount(metadata);
    const plane_offset = std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant;
    const offset = std.math.add(usize, header.data_offset, plane_offset) catch return error.UnsupportedVariant;
    if (offset > bytes.len or bytes.len - offset < plane_len) return error.TruncatedData;
    if (region.isFull(metadata)) {
        const out = try allocator.alloc(u8, plane_len);
        @memcpy(out, bytes[offset..][0..plane_len]);
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
        const src_offset = offset + src_y * src_row_bytes + src_x;
        const dst_offset = row * dst_row_bytes;
        @memcpy(out[dst_offset..][0..dst_row_bytes], bytes[src_offset..][0..dst_row_bytes]);
    }
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    var cursor: usize = 0;
    const magic = try nextLine(data, &cursor);
    if (magic.len < 8 or !std.mem.startsWith(u8, magic, "NRRD")) return error.InvalidFormat;

    var pixel_type: ?bio.PixelType = null;
    var dimension: ?u32 = null;
    var sizes: [4]u32 = .{ 0, 0, 1, 1 };
    var encoding: ?[]const u8 = null;
    var endian: ?[]const u8 = null;
    var byte_skip: usize = 0;
    var data_file: ?[]const u8 = null;

    while (true) {
        if (cursor >= data.len) {
            if (data_file != null) break;
            return error.TruncatedData;
        }
        const line = try nextLine(data, &cursor);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) break;
        if (trimmed[0] == '#') continue;
        const sep = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidFormat;
        const key = std.mem.trim(u8, trimmed[0..sep], " \t");
        const value = std.mem.trim(u8, trimmed[sep + 1 ..], " \t");
        if (std.mem.eql(u8, key, "type")) {
            pixel_type = try parsePixelType(value);
        } else if (std.mem.eql(u8, key, "dimension")) {
            dimension = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "sizes")) {
            sizes = try parseSizes(value);
        } else if (std.mem.eql(u8, key, "encoding")) {
            encoding = value;
        } else if (std.mem.eql(u8, key, "endian")) {
            endian = value;
        } else if (std.mem.eql(u8, key, "data file") or std.mem.eql(u8, key, "datafile")) {
            if (std.mem.indexOfAny(u8, value, " \t") != null) return error.UnsupportedVariant;
            data_file = value;
        } else if (std.mem.eql(u8, key, "byte skip") or std.mem.eql(u8, key, "byteskip")) {
            byte_skip = std.fmt.parseInt(usize, value, 10) catch return error.UnsupportedVariant;
        }
    }

    const dims = dimension orelse return error.InvalidFormat;
    if (dims < 2 or dims > 4) return error.UnsupportedVariant;
    const kind = pixel_type orelse return error.InvalidFormat;
    const enc = encoding orelse return error.InvalidFormat;
    if (!std.mem.eql(u8, enc, "raw")) return error.UnsupportedVariant;

    const size_c: u32 = if (dims == 4) sizes[0] else 1;
    if (size_c == 0 or size_c > std.math.maxInt(u16)) return error.UnsupportedVariant;
    const width = if (dims == 4) sizes[1] else sizes[0];
    const height = if (dims == 4) sizes[2] else sizes[1];
    const planes = if (dims == 4) sizes[3] else if (dims == 3) sizes[2] else 1;

    const bytes_per_sample = kind.bytesPerSample();
    const little = if (bytes_per_sample == 1) false else blk: {
        const order = endian orelse return error.InvalidFormat;
        if (std.mem.eql(u8, order, "little")) break :blk true;
        if (std.mem.eql(u8, order, "big")) break :blk false;
        return error.InvalidFormat;
    };
    const data_offset = std.math.add(usize, cursor, byte_skip) catch return error.UnsupportedVariant;
    if (data_file == null and data_offset > data.len) return error.TruncatedData;
    return .{
        .width = width,
        .height = height,
        .planes = planes,
        .size_c = @intCast(size_c),
        .samples_per_pixel = @intCast(size_c),
        .pixel_type = kind,
        .little_endian = little,
        .data_offset = if (data_file == null) data_offset else byte_skip,
        .data_file = data_file,
    };
}

fn nextLine(data: []const u8, cursor: *usize) bio.ReaderError![]const u8 {
    if (cursor.* >= data.len) return error.TruncatedData;
    const start = cursor.*;
    while (cursor.* < data.len and data[cursor.*] != '\n') cursor.* += 1;
    var end = cursor.*;
    if (cursor.* < data.len) cursor.* += 1;
    if (end > start and data[end - 1] == '\r') end -= 1;
    return data[start..end];
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn joinSibling(allocator: std.mem.Allocator, path: []const u8, name: []const u8) ![]u8 {
    if (isAbsolutePath(name)) return allocator.dupe(u8, name);
    const sep_index = lastSeparator(path) orelse return allocator.dupe(u8, name);
    const sep = path[sep_index];
    const dir = path[0..sep_index];
    const out = try allocator.alloc(u8, dir.len + 1 + name.len);
    @memcpy(out[0..dir.len], dir);
    out[dir.len] = sep;
    @memcpy(out[dir.len + 1 ..], name);
    return out;
}

fn isAbsolutePath(path: []const u8) bool {
    return path.len >= 1 and (path[0] == '/' or path[0] == '\\' or (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/')));
}

fn lastSeparator(path: []const u8) ?usize {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    if (slash == null) return backslash;
    if (backslash == null) return slash;
    return @max(slash.?, backslash.?);
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn parsePixelType(value: []const u8) bio.ReaderError!bio.PixelType {
    if (std.mem.eql(u8, value, "uchar") or std.mem.eql(u8, value, "unsigned char") or std.mem.eql(u8, value, "uint8") or std.mem.eql(u8, value, "uint8_t")) return .uint8;
    if (std.mem.eql(u8, value, "char") or std.mem.eql(u8, value, "signed char") or std.mem.eql(u8, value, "int8") or std.mem.eql(u8, value, "int8_t")) return .int8;
    if (std.mem.eql(u8, value, "ushort") or std.mem.eql(u8, value, "unsigned short") or std.mem.eql(u8, value, "uint16") or std.mem.eql(u8, value, "uint16_t")) return .uint16;
    if (std.mem.eql(u8, value, "short") or std.mem.eql(u8, value, "signed short") or std.mem.eql(u8, value, "int16") or std.mem.eql(u8, value, "int16_t")) return .int16;
    if (std.mem.eql(u8, value, "uint") or std.mem.eql(u8, value, "unsigned int") or std.mem.eql(u8, value, "uint32") or std.mem.eql(u8, value, "uint32_t")) return .uint32;
    if (std.mem.eql(u8, value, "int") or std.mem.eql(u8, value, "signed int") or std.mem.eql(u8, value, "int32") or std.mem.eql(u8, value, "int32_t")) return .int32;
    if (std.mem.eql(u8, value, "float")) return .float32;
    if (std.mem.eql(u8, value, "double")) return .float64;
    return error.UnsupportedVariant;
}

fn parseSizes(value: []const u8) bio.ReaderError![4]u32 {
    var sizes: [4]u32 = .{ 0, 0, 1, 1 };
    var iter = std.mem.tokenizeScalar(u8, value, ' ');
    var i: usize = 0;
    while (iter.next()) |token| {
        if (i >= sizes.len) return error.UnsupportedVariant;
        sizes[i] = try parsePositiveU32(token);
        i += 1;
    }
    if (i < 2) return error.InvalidFormat;
    return sizes;
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

test "reads raw 8-bit nrrd image" {
    const data =
        "NRRD0005\n" ++
        "type: uint8\n" ++
        "dimension: 2\n" ++
        "sizes: 2 1\n" ++
        "encoding: raw\n" ++
        "\n" ++
        [_]u8{ 7, 9 };

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "reads raw 16-bit nrrd z plane" {
    const data =
        "NRRD0005\n" ++
        "type: ushort\n" ++
        "dimension: 3\n" ++
        "sizes: 1 1 2\n" ++
        "endian: little\n" ++
        "encoding: raw\n" ++
        "\n" ++
        [_]u8{ 0x34, 0x12, 0xcd, 0xab };

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0xcd, 0xab }, plane.data);
}

test "reads raw vector-axis nrrd z plane" {
    const data =
        "NRRD0005\n" ++
        "type: float\n" ++
        "dimension: 4\n" ++
        "sizes: 2 1 1 2\n" ++
        "endian: little\n" ++
        "encoding: raw\n" ++
        "\n" ++
        [_]u8{
            1, 0, 0, 0,
            2, 0, 0, 0,
            3, 0, 0, 0,
            4, 0, 0, 0,
        };

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 2), metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0, 4, 0, 0, 0 }, plane.data);
}

test "reads detached nhdr raw companion pixels" {
    const nhdr_path = "nrrd-detached-test.nhdr";
    const raw_path = "nrrd-detached-test.raw";
    const header =
        "NRRD0005\n" ++
        "type: uint8\n" ++
        "dimension: 2\n" ++
        "sizes: 3 2\n" ++
        "encoding: raw\n" ++
        "data file: nrrd-detached-test.raw\n" ++
        "\n";
    const raw = [_]u8{
        1, 2, 3,
        4, 5, 6,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = nhdr_path, .data = header });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, nhdr_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = raw_path, .data = &raw });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, raw_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, nhdr_path);
    try std.testing.expectEqualStrings("nrrd", metadata.format);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, nhdr_path, 0, .{
        .x = 1,
        .y = 0,
        .width = 2,
        .height = 2,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 5, 6 }, plane.data);
}

test "matches Bio-Formats metadata and pixel hashes for cached NRRD fixture" {
    const path = "fixtures/cache/nrrd/dt-helix.nhdr";
    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, path);
    try std.testing.expectEqualStrings("nrrd", metadata.format);
    try std.testing.expectEqual(@as(u32, 38), metadata.width);
    try std.testing.expectEqual(@as(u32, 39), metadata.height);
    try std.testing.expectEqual(@as(u16, 40), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 7), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 40), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 7), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);

    const expected = [_]struct { plane: u32, sha256: [32]u8 }{
        .{ .plane = 0, .sha256 = .{ 0x0c, 0xe4, 0x59, 0xcb, 0xfc, 0x80, 0x5d, 0xef, 0xc2, 0x8f, 0x5b, 0xc8, 0x67, 0xbb, 0x51, 0x29, 0xdf, 0xed, 0x28, 0x41, 0xe7, 0x85, 0x89, 0xe3, 0xf1, 0x9c, 0x34, 0xc2, 0x3b, 0xe2, 0xb0, 0x5c } },
        .{ .plane = 20, .sha256 = .{ 0x42, 0x85, 0xee, 0xeb, 0xc7, 0x32, 0xad, 0x58, 0x4b, 0x48, 0x0c, 0xbd, 0x85, 0xd2, 0x24, 0x18, 0xb5, 0x52, 0x28, 0xa0, 0xfc, 0x76, 0x42, 0x03, 0x20, 0xec, 0x41, 0x09, 0xc7, 0xed, 0xb7, 0x30 } },
        .{ .plane = 39, .sha256 = .{ 0x07, 0x33, 0x3d, 0xa0, 0x22, 0x7c, 0x6d, 0x5b, 0xdb, 0xe7, 0xfc, 0x27, 0x38, 0x57, 0xd7, 0x8b, 0x9d, 0xaf, 0x36, 0x75, 0x27, 0x06, 0x56, 0x5d, 0x4b, 0xa5, 0x46, 0x03, 0x5b, 0xf8, 0xde, 0x14 } },
    };
    for (expected) |sample| {
        const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, path, sample.plane, .{
            .x = 0,
            .y = 0,
            .width = metadata.width,
            .height = metadata.height,
        });
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqual(@as(usize, 41496), plane.data.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
        try std.testing.expectEqualSlices(u8, &sample.sha256, &digest);
    }

    const region = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, path, 0, .{
        .x = 17,
        .y = 19,
        .width = 16,
        .height = 12,
    });
    defer std.testing.allocator.free(region.data);
    try std.testing.expectEqual(@as(usize, 5376), region.data.len);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(region.data, &digest, .{});
    const expected_region_hash: [32]u8 = .{ 0x95, 0x11, 0xe4, 0x47, 0x05, 0x87, 0x7a, 0x47, 0xe9, 0x17, 0x0b, 0xbe, 0x0e, 0x4d, 0x1a, 0xa4, 0x44, 0x1d, 0x1d, 0x87, 0x0d, 0x1a, 0x36, 0x0b, 0x64, 0x8c, 0xeb, 0x35, 0x27, 0x4c, 0x06, 0x95 };
    try std.testing.expectEqualSlices(u8, &expected_region_hash, &digest);
}

test "rejects gzip nrrd encoding" {
    const data =
        "NRRD0005\n" ++
        "type: uint8\n" ++
        "dimension: 2\n" ++
        "sizes: 1 1\n" ++
        "encoding: gzip\n" ++
        "\n" ++
        [_]u8{7};

    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data));
}
