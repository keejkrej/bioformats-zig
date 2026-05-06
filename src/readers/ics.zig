const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;
const max_axes = 16;

const Header = struct {
    version_two: bool,
    width: u32,
    height: u32,
    size_z: u16,
    size_t: u16,
    size_c: u16,
    pixel_type: bio.PixelType,
    little_endian: bool,
    data_offset: usize,
    plane_count: u32,
    invert_y: bool = false,
    image_name: ?[]const u8 = null,
    compression: ?[]const u8 = null,
};

pub fn matches(data: []const u8) bool {
    const line = firstMeaningfulLine(data) orelse return false;
    const tokens = tokenize(line);
    return tokens.len >= 2 and eqlIgnoreCase(tokens.items[0], "ics_version");
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "ics") or hasExtension(path, "ids");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    return metadataFromHeader(try parseHeader(data));
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    if (!header.version_two) {
        if (plane_index >= header.plane_count) return error.InvalidPlaneIndex;
        return error.UnsupportedVariant;
    }
    if (header.compression) |compression| {
        if (!eqlIgnoreCase(compression, "uncompressed")) return error.UnsupportedVariant;
    }
    const metadata = metadataFromHeader(header);
    return readPlaneFromBytes(allocator, metadata, data, header.data_offset, plane_index, bio.Region.full(metadata), header.invert_y);
}

pub fn readMetadataPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !bio.Metadata {
    const ics = try readIcsFile(allocator, io, path);
    defer allocator.free(ics);
    return readMetadata(ics);
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const ics = try readIcsFile(allocator, io, path);
    defer allocator.free(ics);
    const header = try parseHeader(ics);
    const metadata = metadataFromHeader(header);
    try region.validate(metadata);

    if (header.compression) |compression| {
        if (!eqlIgnoreCase(compression, "uncompressed")) return error.UnsupportedVariant;
    }

    if (header.version_two) {
        return readPlaneFromBytes(allocator, metadata, ics, header.data_offset, plane_index, region, header.invert_y);
    }

    const ids = try readIdsFile(allocator, io, path);
    defer allocator.free(ids);
    return readPlaneFromBytes(allocator, metadata, ids, 0, plane_index, region, header.invert_y);
}

fn metadataFromHeader(header: Header) bio.Metadata {
    return .{
        .format = "ics",
        .width = header.width,
        .height = header.height,
        .size_c = header.size_c,
        .samples_per_pixel = 1,
        .size_z = header.size_z,
        .size_t = header.size_t,
        .pixel_type = header.pixel_type,
        .little_endian = header.little_endian,
        .plane_count = header.plane_count,
        .dimension_order = "XYZCT",
        .image_description = header.image_name,
    };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    var cursor: usize = 0;
    const version_line = try nextMeaningfulLine(data, &cursor);
    const version_tokens = tokenize(version_line);
    if (version_tokens.len < 2 or !eqlIgnoreCase(version_tokens.items[0], "ics_version")) return error.InvalidFormat;
    const version_two = std.mem.eql(u8, version_tokens.items[1], "2.0");

    var axes = AxisList{};
    var sizes = SizeList{};
    var significant_bits: ?u32 = null;
    var r_format: []const u8 = "integer";
    var signed = false;
    var little_endian = true;
    var compression: ?[]const u8 = null;
    var image_name: ?[]const u8 = null;
    var data_offset: ?usize = null;
    var invert_y = false;

    while (cursor < data.len) {
        const line = try nextLine(data, &cursor);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (eqlIgnoreCase(trimmed, "end")) {
            data_offset = cursor;
            break;
        }

        var tokens = tokenize(trimmed);
        if (tokens.len == 0) continue;
        if (eqlIgnoreCase(tokens.items[0], "filename")) {
            image_name = trailingValue(trimmed, tokens.items[0].len);
        } else if (eqlIgnoreCase(tokens.items[0], "layout") and tokens.len >= 3) {
            if (eqlIgnoreCase(tokens.items[1], "order")) {
                axes = parseAxes(tokens.items[2..tokens.len]) catch return error.UnsupportedVariant;
            } else if (eqlIgnoreCase(tokens.items[1], "sizes")) {
                sizes = parseSizes(tokens.items[2..tokens.len]) catch return error.InvalidFormat;
            } else if (eqlIgnoreCase(tokens.items[1], "significant_bits")) {
                significant_bits = try parsePositiveU32(tokens.items[2]);
            }
        } else if (eqlIgnoreCase(tokens.items[0], "representation") and tokens.len >= 3) {
            if (eqlIgnoreCase(tokens.items[1], "format")) {
                r_format = tokens.items[2];
            } else if (eqlIgnoreCase(tokens.items[1], "sign")) {
                signed = eqlIgnoreCase(tokens.items[2], "signed");
            } else if (eqlIgnoreCase(tokens.items[1], "byte_order")) {
                const first = std.fmt.parseInt(u32, tokens.items[2], 10) catch return error.InvalidFormat;
                little_endian = first == 1;
            } else if (eqlIgnoreCase(tokens.items[1], "compression")) {
                compression = tokens.items[2];
            }
        } else if (eqlIgnoreCase(tokens.items[0], "history") and tokens.len >= 3) {
            if (eqlIgnoreCase(tokens.items[1], "software") and std.mem.indexOf(u8, trimmed, "SVI") != null) {
                invert_y = true;
            }
        }
    }

    if (data_offset == null and !version_two) data_offset = cursor;
    if (data_offset == null) return error.InvalidFormat;
    if (axes.len == 0 or sizes.len == 0 or axes.len != sizes.len) return error.InvalidFormat;

    var width: u32 = 0;
    var height: u32 = 0;
    var size_z: u32 = 1;
    var size_t: u32 = 1;
    var size_c: u32 = 1;
    var bits: u32 = significant_bits orelse 0;

    for (axes.items[0..axes.len], sizes.items[0..sizes.len]) |axis, size| {
        if (eqlIgnoreCase(axis, "bits")) {
            bits = normalizedBits(size);
        } else if (eqlIgnoreCase(axis, "x")) {
            width = size;
        } else if (eqlIgnoreCase(axis, "y")) {
            height = size;
        } else if (eqlIgnoreCase(axis, "z")) {
            size_z = size;
        } else if (eqlIgnoreCase(axis, "t")) {
            size_t = std.math.mul(u32, size_t, size) catch return error.UnsupportedVariant;
        } else {
            size_c = std.math.mul(u32, size_c, size) catch return error.UnsupportedVariant;
        }
    }
    if (width == 0 or height == 0 or bits == 0) return error.InvalidFormat;
    if (bits == 24 or bits == 48) return error.UnsupportedVariant;
    if (size_z > std.math.maxInt(u16) or size_t > std.math.maxInt(u16) or size_c > std.math.maxInt(u16)) return error.UnsupportedVariant;
    const zt = std.math.mul(u32, size_z, size_t) catch return error.UnsupportedVariant;
    const plane_count = std.math.mul(u32, zt, size_c) catch return error.UnsupportedVariant;

    return .{
        .version_two = version_two,
        .width = width,
        .height = height,
        .size_z = @intCast(size_z),
        .size_t = @intCast(size_t),
        .size_c = @intCast(size_c),
        .pixel_type = try pixelType(bits, signed, eqlIgnoreCase(r_format, "real")),
        .little_endian = little_endian,
        .data_offset = data_offset.?,
        .plane_count = plane_count,
        .invert_y = invert_y,
        .image_name = image_name,
        .compression = compression,
    };
}

fn readPlaneFromBytes(
    allocator: std.mem.Allocator,
    metadata: bio.Metadata,
    data: []const u8,
    data_offset: usize,
    plane_index: u32,
    region: bio.Region,
    invert_y: bool,
) bio.ReaderError!bio.Plane {
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    try region.validate(metadata);

    const plane_len = try planeByteCount(metadata);
    const plane_offset = std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant;
    const offset = std.math.add(usize, data_offset, plane_offset) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;

    if (region.isFull(metadata) and !invert_y) {
        const out = try allocator.alloc(u8, plane_len);
        @memcpy(out, data[offset..][0..plane_len]);
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
        const logical_y = @as(usize, region.y) + row;
        const src_y = if (invert_y) @as(usize, metadata.height) - 1 - logical_y else logical_y;
        const src_x = @as(usize, region.x) * bytes_per_pixel;
        const src_offset = offset + src_y * src_row_bytes + src_x;
        const dst_offset = row * dst_row_bytes;
        @memcpy(out[dst_offset..][0..dst_row_bytes], data[src_offset..][0..dst_row_bytes]);
    }
    return .{ .metadata = metadata, .data = out };
}

const AxisList = struct {
    items: [max_axes][]const u8 = undefined,
    len: usize = 0,
};

const SizeList = struct {
    items: [max_axes]u32 = undefined,
    len: usize = 0,
};

fn parseAxes(tokens: []const []const u8) !AxisList {
    var axes = AxisList{};
    for (tokens) |token| {
        if (axes.len == max_axes) return error.UnsupportedVariant;
        axes.items[axes.len] = token;
        axes.len += 1;
    }
    return axes;
}

fn parseSizes(tokens: []const []const u8) !SizeList {
    var sizes = SizeList{};
    for (tokens) |token| {
        if (sizes.len == max_axes) return error.UnsupportedVariant;
        sizes.items[sizes.len] = try parsePositiveU32(token);
        sizes.len += 1;
    }
    return sizes;
}

fn normalizedBits(value: u32) u32 {
    var bits = value;
    while (bits % 8 != 0) bits += 1;
    if (bits == 24 or bits == 48) return bits;
    return bits;
}

fn pixelType(bits: u32, signed: bool, floating: bool) bio.ReaderError!bio.PixelType {
    if (floating) {
        return switch (bits) {
            32 => .float32,
            64 => .float64,
            else => error.UnsupportedVariant,
        };
    }
    return switch (bits) {
        8 => if (signed) .int8 else .uint8,
        16 => if (signed) .int16 else .uint16,
        32 => if (signed) .int32 else .uint32,
        else => error.UnsupportedVariant,
    };
}

fn readIcsFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "ics")) return readFile(allocator, io, path);
    const lower = try replaceExtension(allocator, path, ".ics");
    defer allocator.free(lower);
    return readFile(allocator, io, lower) catch |lower_err| {
        const upper = try replaceExtension(allocator, path, ".ICS");
        defer allocator.free(upper);
        return readFile(allocator, io, upper) catch lower_err;
    };
}

fn readIdsFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "ids")) return readFile(allocator, io, path);
    const lower = try replaceExtension(allocator, path, ".ids");
    defer allocator.free(lower);
    return readFile(allocator, io, lower) catch |lower_err| {
        const upper = try replaceExtension(allocator, path, ".IDS");
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

fn firstMeaningfulLine(data: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < data.len) {
        const line = nextLine(data, &cursor) catch return null;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0) return trimmed;
    }
    return null;
}

fn nextMeaningfulLine(data: []const u8, cursor: *usize) bio.ReaderError![]const u8 {
    while (cursor.* < data.len) {
        const line = try nextLine(data, cursor);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0) return trimmed;
    }
    return error.TruncatedData;
}

fn nextLine(data: []const u8, cursor: *usize) bio.ReaderError![]const u8 {
    if (cursor.* >= data.len) return error.TruncatedData;
    const start = cursor.*;
    while (cursor.* < data.len and data[cursor.*] != '\n' and data[cursor.*] != '\r') cursor.* += 1;
    const end = cursor.*;
    while (cursor.* < data.len and (data[cursor.*] == '\n' or data[cursor.*] == '\r')) cursor.* += 1;
    return data[start..end];
}

const max_tokens = 64;

const TokenList = struct {
    items: [max_tokens][]const u8 = undefined,
    len: usize = 0,
};

fn tokenize(line: []const u8) TokenList {
    var tokens = TokenList{};
    var pos: usize = 0;
    while (pos < line.len) {
        while (pos < line.len and isDelimiter(line[pos])) : (pos += 1) {}
        if (pos >= line.len) break;
        const start = pos;
        while (pos < line.len and !isDelimiter(line[pos])) : (pos += 1) {}
        if (tokens.len == max_tokens) return .{};
        tokens.items[tokens.len] = line[start..pos];
        tokens.len += 1;
    }
    return tokens;
}

fn trailingValue(line: []const u8, prefix_len: usize) ?[]const u8 {
    if (prefix_len >= line.len) return null;
    const value = std.mem.trim(u8, line[prefix_len..], " \t\r");
    return if (value.len == 0) null else value;
}

fn isDelimiter(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
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

test "reads inline ics v2 uint8 plane" {
    const data =
        "ics_version\t2.0\n" ++
        "filename\tinline.ids\n" ++
        "layout\tparameters\t4\n" ++
        "layout\torder\tbits\tx\ty\tz\n" ++
        "layout\tsizes\t8\t2\t1\t2\n" ++
        "representation\tformat\tinteger\n" ++
        "representation\tsign\tunsigned\n" ++
        "representation\tbyte_order\t1\t2\n" ++
        "end\n" ++
        [_]u8{ 7, 9, 11, 13 };

    try std.testing.expect(matches(data));
    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("ics", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("inline.ids", metadata.image_description.?);

    const plane = try readPlaneIndex(std.testing.allocator, data, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 11, 13 }, plane.data);
}

test "reads ics ids companion pixels with crop" {
    const ics_path = "ics-test.ics";
    const ids_path = "ics-test.ids";
    const header =
        "ics_version\t1.0\n" ++
        "layout\tparameters\t4\n" ++
        "layout\torder\tbits\tx\ty\tch\n" ++
        "layout\tsizes\t16\t2\t2\t2\n" ++
        "representation\tformat\tinteger\n" ++
        "representation\tsign\tunsigned\n" ++
        "representation\tbyte_order\t1\t2\n" ++
        "end\n";
    const pixels = [_]u8{
        1, 0, 2, 0,
        3, 0, 4, 0,
        5, 0, 6, 0,
        7, 0, 8, 0,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = ics_path, .data = header });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ics_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = ids_path, .data = &pixels });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ids_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, ids_path);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, ics_path, 1, .{ .x = 1, .y = 0, .width = 1, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 6, 0, 8, 0 }, plane.data);
}

test "reads eof-terminated ics v1 metadata" {
    const data =
        "ics_version\t1.0\n" ++
        "layout\torder\tbits\tx\ty\tz\n" ++
        "layout\tsizes\t32\t2\t1\t2\n" ++
        "representation\tformat\treal\n" ++
        "representation\tsign\tsigned\n" ++
        "representation\tbyte_order\t1\t2\t3\t4\n";

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
}

test "reads ics with leading blank line" {
    const data =
        "\t\n" ++
        "ics_version\t2.0\n" ++
        "layout\torder\tbits\tx\ty\n" ++
        "layout\tsizes\t8\t1\t1\n" ++
        "representation\tformat\tinteger\n" ++
        "representation\tsign\tunsigned\n" ++
        "representation\tbyte_order\t1\t2\n" ++
        "end\n" ++
        [_]u8{42};

    try std.testing.expect(matches(data));
    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{42}, plane.data);
}

test "rejects compressed ics pixels" {
    const data =
        "ics_version\t2.0\n" ++
        "layout\torder\tbits\tx\ty\n" ++
        "layout\tsizes\t8\t1\t1\n" ++
        "representation\tformat\tinteger\n" ++
        "representation\tcompression\tgzip\n" ++
        "end\n" ++
        [_]u8{7};

    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, data, 0));
}

test "matches Bio-Formats metadata and pixel hashes for cached ICS fixture" {
    const file_path = "fixtures/cache/ics/benchmark_v1_2018_x64y64z5c2s1t11_w1Laser4054BD4BP_5c8bc101d6559_hrm.ics";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    try std.testing.expectEqualStrings("ics", metadata.format);
    try std.testing.expectEqual(@as(u32, 64), metadata.width);
    try std.testing.expectEqual(@as(u32, 64), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 5), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 5), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 1), metadata.series_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYZCT", metadata.dimension_order.?);

    const expected = [_]struct { plane: u32, sha256: [32]u8 }{
        .{ .plane = 0, .sha256 = .{ 0xb8, 0xae, 0xc8, 0x86, 0x86, 0x52, 0x7b, 0x5a, 0x18, 0x58, 0x6b, 0x75, 0x32, 0xbe, 0x64, 0xed, 0x38, 0x75, 0x8a, 0x32, 0xc6, 0x75, 0x3a, 0x79, 0x47, 0x1f, 0x0b, 0xe4, 0xec, 0xb0, 0xd9, 0xb8 } },
        .{ .plane = 2, .sha256 = .{ 0xd1, 0x3f, 0xdd, 0x92, 0xde, 0x34, 0x7f, 0x9f, 0x09, 0x09, 0x12, 0xee, 0x12, 0xc2, 0x15, 0x44, 0x34, 0x68, 0x76, 0x9f, 0x3a, 0x61, 0xec, 0x42, 0x1a, 0x4e, 0x6a, 0xba, 0xef, 0xc9, 0x09, 0xdd } },
        .{ .plane = 4, .sha256 = .{ 0x60, 0x53, 0x81, 0xd1, 0x28, 0x52, 0x30, 0x84, 0x79, 0x94, 0xfb, 0x6a, 0x0d, 0x34, 0xad, 0x4b, 0x30, 0x21, 0xe6, 0xee, 0xfc, 0x93, 0x9a, 0x7a, 0xf1, 0x79, 0x3f, 0x86, 0xb0, 0xee, 0xe2, 0x61 } },
    };
    for (expected) |sample| {
        const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, sample.plane, .{
            .x = 0,
            .y = 0,
            .width = 64,
            .height = 64,
        });
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqual(@as(usize, 16384), plane.data.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
        try std.testing.expectEqualSlices(u8, &sample.sha256, &digest);
    }

    const region = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{
        .x = 17,
        .y = 19,
        .width = 16,
        .height = 12,
    });
    defer std.testing.allocator.free(region.data);
    try std.testing.expectEqual(@as(usize, 768), region.data.len);
    const expected_region: [32]u8 = .{ 0xef, 0x11, 0x5a, 0x0e, 0x0c, 0x15, 0xcd, 0xc4, 0x19, 0x58, 0xca, 0x46, 0xb5, 0xb1, 0x4b, 0x45, 0x61, 0x15, 0xf4, 0xba, 0xec, 0x5e, 0x3c, 0xa6, 0x85, 0x99, 0xd2, 0xa8, 0xf4, 0x35, 0xe3, 0xb8 };
    var region_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(region.data, &region_digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_region, &region_digest);
}
