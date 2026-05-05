const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;
const pixel_marker = [_]u8{ 0, 0, 0, 0, 0, 0, 0xf0, 0x3f, 0, 0, 0, 0, 0, 0, 0xf0, 0x3f };

const Header = struct {
    width: u32,
    height: u32,
    size_z: u16,
    size_c: u16,
    size_t: u16,
    pixel_type: bio.PixelType,
};

pub fn matches(data: []const u8) bool {
    _ = data;
    return false;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "html") or hasExtension(path, "xys");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    _ = data;
    return error.UnsupportedFormat;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedFormat;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const html_path = try htmlPath(allocator, io, path);
    defer allocator.free(html_path);
    const html = try readFile(allocator, io, html_path);
    defer allocator.free(html);
    return metadataFromHeader(try parseHtml(html));
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const html_path = try htmlPath(allocator, io, path);
    defer allocator.free(html_path);
    const html = try readFile(allocator, io, html_path);
    defer allocator.free(html);
    const header = try parseHtml(html);
    const metadata = metadataFromHeader(header);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    try region.validate(metadata);

    const div = @as(u32, header.size_z) * @as(u32, header.size_t);
    const channel = if (div == 0) 0 else plane_index / div;
    const plane_in_channel = if (div == 0) 0 else plane_index % div;
    const xys_path = try xysPath(allocator, io, html_path, channel);
    defer allocator.free(xys_path);
    const xys = try readFile(allocator, io, xys_path);
    defer allocator.free(xys);

    const pixel_offset = try findPixelOffset(xys);
    const plane_len = try planeByteCount(metadata);
    const plane_offset = std.math.mul(usize, plane_len, plane_in_channel) catch return error.UnsupportedVariant;
    const offset = std.math.add(usize, pixel_offset, plane_offset) catch return error.UnsupportedVariant;
    if (offset > xys.len or xys.len - offset < plane_len) return error.TruncatedData;

    if (region.isFull(metadata)) {
        const out = try allocator.alloc(u8, plane_len);
        @memcpy(out, xys[offset..][0..plane_len]);
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
        @memcpy(out[dst_offset..][0..dst_row_bytes], xys[src_offset..][0..dst_row_bytes]);
    }
    return .{ .metadata = metadata, .data = out };
}

fn metadataFromHeader(header: Header) bio.Metadata {
    return .{
        .format = "visitech",
        .width = header.width,
        .height = header.height,
        .size_c = header.size_c,
        .size_z = header.size_z,
        .size_t = header.size_t,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
        .little_endian = true,
        .plane_count = @as(u32, header.size_z) * @as(u32, header.size_c) * @as(u32, header.size_t),
        .dimension_order = "XYZTC",
    };
}

fn parseHtml(data: []const u8) bio.ReaderError!Header {
    var header: Header = .{
        .width = 0,
        .height = 0,
        .size_z = 1,
        .size_c = 0,
        .size_t = 1,
        .pixel_type = .uint16,
    };
    var image_count: u32 = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = stripTags(std.mem.trim(u8, raw_line, " \t\r"));
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':');
        if (colon) |idx| {
            const key = std.mem.trim(u8, line[0..idx], " \t");
            const value = std.mem.trim(u8, line[idx + 1 ..], " \t");
            if (std.mem.eql(u8, key, "Number of steps")) {
                header.size_z = try parsePositiveU16(value);
            } else if (std.mem.eql(u8, key, "Image bit depth")) {
                header.pixel_type = try pixelTypeFromBits(value);
            } else if (std.mem.eql(u8, key, "Image dimensions")) {
                try parseDimensions(value, &header.width, &header.height);
            } else if (std.mem.startsWith(u8, key, "Channel Selection")) {
                header.size_c += 1;
            }
        }
        if (std.mem.indexOf(u8, line, "pixels")) |pixels_pos| {
            const count_text = std.mem.trim(u8, line[0..pixels_pos], " \t");
            const count = std.fmt.parseInt(u32, count_text, 10) catch 0;
            if (count > 0) {
                header.size_c += 1;
                image_count += count;
            }
        } else if (std.mem.startsWith(u8, line, "Time Series")) {
            if (std.mem.indexOfScalar(u8, line, ';')) |semi| {
                var tokens = std.mem.tokenizeAny(u8, line[semi + 1 ..], " \t");
                if (tokens.next()) |token| header.size_t = try parsePositiveU16(token);
            }
        }
    }

    if (header.width == 0 or header.height == 0) return error.InvalidFormat;
    if (header.size_c == 0) header.size_c = 1;
    if (image_count > 0) {
        const zc = @as(u32, header.size_z) * @as(u32, header.size_c);
        if (zc != 0 and image_count % zc == 0) {
            const parsed_t = image_count / zc;
            if (parsed_t > 0 and parsed_t <= std.math.maxInt(u16)) header.size_t = @intCast(parsed_t);
        }
    }
    return header;
}

fn stripTags(line: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = line.len;
    while (start < end and line[start] == '<') {
        const close = std.mem.indexOfScalarPos(u8, line, start, '>') orelse break;
        start = close + 1;
    }
    while (end > start and line[end - 1] == '>') {
        const open = std.mem.lastIndexOfScalar(u8, line[start .. end - 1], '<') orelse break;
        end = start + open;
    }
    return std.mem.trim(u8, line[start..end], " \t");
}

fn parseDimensions(value: []const u8, width: *u32, height: *u32) bio.ReaderError!void {
    const open = std.mem.indexOfScalar(u8, value, '(');
    const close = std.mem.lastIndexOfScalar(u8, value, ')') orelse value.len;
    const body_start: usize = if (open) |idx| idx + 1 else 0;
    if (body_start > close) return error.InvalidFormat;
    const body = value[body_start..close];
    const comma = std.mem.indexOfScalar(u8, body, ',') orelse return error.InvalidFormat;
    width.* = try parsePositiveU32(std.mem.trim(u8, body[0..comma], " \t"));
    height.* = try parsePositiveU32(std.mem.trim(u8, body[comma + 1 ..], " \t"));
}

fn pixelTypeFromBits(value: []const u8) bio.ReaderError!bio.PixelType {
    var bits = try parsePositiveU32(value);
    while (bits % 8 != 0) bits += 1;
    return switch (bits / 8) {
        1 => .uint8,
        2 => .uint16,
        4 => .uint32,
        else => error.UnsupportedVariant,
    };
}

fn htmlPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "html")) return allocator.dupe(u8, path);
    const base = baseBeforeLastSpace(path) orelse return error.InvalidFormat;
    const report = try appendSuffix(allocator, base, " Report.html");
    errdefer allocator.free(report);
    if (exists(io, report)) return report;
    allocator.free(report);
    return appendSuffix(allocator, base, ".html");
}

fn xysPath(allocator: std.mem.Allocator, io: std.Io, html_path: []const u8, channel: u32) ![]u8 {
    const base = baseBeforeLastSpace(html_path) orelse stripExtension(html_path);
    const index = try std.fmt.allocPrint(allocator, " {d}.xys", .{channel + 1});
    defer allocator.free(index);
    const candidate = try appendSuffix(allocator, base, index);
    errdefer allocator.free(candidate);
    if (exists(io, candidate)) return candidate;
    return candidate;
}

fn findPixelOffset(data: []const u8) bio.ReaderError!usize {
    const marker = std.mem.indexOf(u8, data, &pixel_marker) orelse return error.InvalidFormat;
    return marker + pixel_marker.len;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn exists(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn baseBeforeLastSpace(path: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    const space = std.mem.lastIndexOfScalar(u8, path[0..dot], ' ') orelse return null;
    return path[0..space];
}

fn stripExtension(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return path;
    return path[0..dot];
}

fn appendSuffix(allocator: std.mem.Allocator, base: []const u8, suffix: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, base.len + suffix.len);
    @memcpy(out[0..base.len], base);
    @memcpy(out[base.len..], suffix);
    return out;
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn parsePositiveU32(value: []const u8) bio.ReaderError!u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidFormat;
    if (parsed == 0) return error.InvalidFormat;
    return parsed;
}

fn parsePositiveU16(value: []const u8) bio.ReaderError!u16 {
    const parsed = std.fmt.parseInt(u16, value, 10) catch return error.InvalidFormat;
    if (parsed == 0) return error.InvalidFormat;
    return parsed;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

test "reads visitech html metadata" {
    const html =
        "<b>Number of steps: 2</b>\n" ++
        "<b>Image bit depth: 16</b>\n" ++
        "<b>Image dimensions: (3, 2)</b>\n" ++
        "<b>Channel Selection 1: Green</b>\n" ++
        "<b>Channel Selection 2: Red</b>\n" ++
        "<b>Time Series; 4 frames</b>\n";
    const metadata = metadataFromHeader(try parseHtml(html));
    try std.testing.expectEqualStrings("visitech", metadata.format);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 4), metadata.size_t);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 16), metadata.plane_count);
}

test "reads visitech companion xys crop" {
    const html_path = "visitech-test Report.html";
    const xys_path = "visitech-test 1.xys";
    const html =
        "Number of steps: 1\n" ++
        "Image bit depth: 8\n" ++
        "Image dimensions: (3, 2)\n" ++
        "Channel Selection 1: Green\n";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = html_path, .data = html });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, html_path) catch {};
    var xys: std.ArrayList(u8) = .empty;
    defer xys.deinit(std.testing.allocator);
    try xys.appendSlice(std.testing.allocator, "header");
    try xys.appendSlice(std.testing.allocator, &pixel_marker);
    try xys.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4, 5, 6 });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = xys_path, .data = xys.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, xys_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, html_path, 0, .{ .x = 1, .y = 0, .width = 2, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("visitech", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 5, 6 }, plane.data);
}
