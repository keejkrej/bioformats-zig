const std = @import("std");
const bio = @import("../root.zig");

const magic = ":STM data";
const max_companion_bytes = 512 * 1024 * 1024;

const Header = struct {
    width: u32,
    height: u32,
    pixel_type: bio.PixelType,
    image_name: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub fn matches(data: []const u8) bool {
    if (data.len < magic.len) return false;
    const check = data[0..@min(data.len, 9)];
    return std.mem.indexOf(u8, check, magic) != null;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "hdr") or hasExtension(path, "dat");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return metadataFromHeader(header);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    if (plane_index != 0) return error.InvalidPlaneIndex;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !bio.Metadata {
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
    const metadata = try readMetadataPath(allocator, io, path);
    try region.validate(metadata);

    const dat = try readDatFile(allocator, io, path);
    defer allocator.free(dat);

    const bytes_per_pixel = metadata.bytesPerPixel();
    const src_row_bytes = try mul(usize, metadata.width, bytes_per_pixel);
    const plane_len = try mul(usize, src_row_bytes, metadata.height);
    if (dat.len < plane_len) return error.TruncatedData;

    if (region.isFull(metadata)) {
        const out = try allocator.alloc(u8, plane_len);
        @memcpy(out, dat[0..plane_len]);
        return .{ .metadata = metadata, .data = out };
    }

    const dst_row_bytes = try mul(usize, region.width, bytes_per_pixel);
    const out_len = try mul(usize, dst_row_bytes, region.height);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    var row: usize = 0;
    while (row < region.height) : (row += 1) {
        const src_y = @as(usize, region.y) + row;
        const src_x = @as(usize, region.x) * bytes_per_pixel;
        const src_offset = src_y * src_row_bytes + src_x;
        const dst_offset = row * dst_row_bytes;
        @memcpy(out[dst_offset..][0..dst_row_bytes], dat[src_offset..][0..dst_row_bytes]);
    }
    return .{ .metadata = metadata, .data = out };
}

fn metadataFromHeader(header: Header) bio.Metadata {
    return .{
        .format = "unisoku",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
        .little_endian = true,
        .dimension_order = "XYZCT",
        .image_description = header.description orelse header.image_name,
    };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    const dimensions = valueAfterKey(data, ":data volume(x*y)") orelse return error.InvalidFormat;
    const data_type_text = valueAfterKey(data, ":ascii flag; data type") orelse return error.InvalidFormat;

    var tokens = std.mem.tokenizeAny(u8, dimensions, " \t,\r\n");
    const width_text = tokens.next() orelse return error.InvalidFormat;
    const height_text = tokens.next() orelse return error.InvalidFormat;
    const width = std.fmt.parseInt(u32, width_text, 10) catch return error.InvalidFormat;
    const height = std.fmt.parseInt(u32, height_text, 10) catch return error.InvalidFormat;
    if (width == 0 or height == 0) return error.InvalidFormat;

    const data_type = parseLastInt(u32, data_type_text) catch return error.InvalidFormat;
    return .{
        .width = width,
        .height = height,
        .pixel_type = pixelTypeFromUnisoku(data_type) catch return error.UnsupportedVariant,
        .image_name = valueAfterKey(data, ":sample name"),
        .description = valueAfterKey(data, ":remark"),
    };
}

fn valueAfterKey(data: []const u8, key_prefix: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < data.len) {
        const line_start = pos;
        const line_end = findLineEnd(data, line_start);
        const line = std.mem.trim(u8, data[line_start..line_end], " \t");
        pos = skipLineBreak(data, line_end);
        if (!std.mem.startsWith(u8, line, key_prefix)) continue;

        const inline_value = std.mem.trim(u8, line[key_prefix.len..], " \t");
        if (inline_value.len > 0) return inline_value;

        const value_start = pos;
        var value_end = pos;
        while (pos < data.len) {
            const next_line_start = pos;
            const next_line_end = findLineEnd(data, next_line_start);
            const next_line = std.mem.trim(u8, data[next_line_start..next_line_end], " \t");
            if (std.mem.startsWith(u8, next_line, ":")) break;
            value_end = next_line_end;
            pos = skipLineBreak(data, next_line_end);
        }
        const value = std.mem.trim(u8, data[value_start..value_end], " \t\r\n");
        return if (value.len == 0) null else value;
    }
    return null;
}

fn findLineEnd(data: []const u8, start: usize) usize {
    var i = start;
    while (i < data.len and data[i] != '\r' and data[i] != '\n') : (i += 1) {}
    return i;
}

fn skipLineBreak(data: []const u8, index: usize) usize {
    var i = index;
    if (i < data.len and data[i] == '\r') i += 1;
    if (i < data.len and data[i] == '\n') i += 1;
    return i;
}

fn parseLastInt(comptime T: type, text: []const u8) !T {
    var tokens = std.mem.tokenizeAny(u8, text, " \t,\r\n");
    var last: ?[]const u8 = null;
    while (tokens.next()) |token| last = token;
    return std.fmt.parseInt(T, last orelse return error.InvalidFormat, 10);
}

fn pixelTypeFromUnisoku(data_type: u32) bio.ReaderError!bio.PixelType {
    const bytes = data_type / 2;
    const signed = data_type % 2 == 1;
    return switch (bytes) {
        1 => if (signed) .int8 else .uint8,
        2 => if (signed) .int16 else .uint16,
        4 => .float32,
        8 => .float64,
        else => error.UnsupportedVariant,
    };
}

fn readHdrFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "hdr")) return readFile(allocator, io, path);
    const upper = try replaceExtension(allocator, path, ".HDR");
    defer allocator.free(upper);
    return readFile(allocator, io, upper) catch |upper_err| {
        const lower = try replaceExtension(allocator, path, ".hdr");
        defer allocator.free(lower);
        return readFile(allocator, io, lower) catch upper_err;
    };
}

fn readDatFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "dat")) return readFile(allocator, io, path);
    const upper = try replaceExtension(allocator, path, ".DAT");
    defer allocator.free(upper);
    return readFile(allocator, io, upper) catch |upper_err| {
        const lower = try replaceExtension(allocator, path, ".dat");
        defer allocator.free(lower);
        return readFile(allocator, io, lower) catch upper_err;
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

fn mul(comptime T: type, a: anytype, b: anytype) bio.ReaderError!T {
    return std.math.mul(T, @intCast(a), @intCast(b)) catch error.UnsupportedVariant;
}

test "reads unisoku header metadata" {
    const header =
        ":STM data\r" ++
        ":sample name\r" ++
        "Test sample\r" ++
        ":data volume(x*y)\r" ++
        "2 3\r" ++
        ":ascii flag; data type\r" ++
        "0 4\r" ++
        ":remark\r" ++
        "Test remark\r";

    const metadata = try readMetadata(header);
    try std.testing.expectEqualStrings("unisoku", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 3), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("Test remark", metadata.image_description.?);
}

test "reads unisoku companion dat pixels with region crop" {
    const hdr_path = "unisoku-test.HDR";
    const dat_path = "unisoku-test.DAT";
    const header =
        ":STM data\r" ++
        ":data volume(x*y)\r" ++
        "2 2\r" ++
        ":ascii flag; data type\r" ++
        "0 4\r";
    const pixels = [_]u8{
        1, 0, 2, 0,
        3, 0, 4, 0,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = hdr_path, .data = header });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hdr_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dat_path, .data = &pixels });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, dat_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, hdr_path, 0, .{
        .x = 1,
        .y = 0,
        .width = 1,
        .height = 2,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 4, 0 }, plane.data);
}
