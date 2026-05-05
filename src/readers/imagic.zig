const std = @import("std");
const bio = @import("../root.zig");

const header_len = 1024;
const max_companion_bytes = 512 * 1024 * 1024;

const Header = struct {
    width: u32,
    height: u32,
    plane_count: u32,
    pixel_type: bio.PixelType,
    image_name: ?[]const u8,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "hed") or hasExtension(path, "img");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return metadataFromHeader(header);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    if (plane_index >= (readMetadata(data) catch return error.InvalidFormat).plane_count) return error.InvalidPlaneIndex;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const hed = try readHedFile(allocator, io, path);
    defer allocator.free(hed);
    return readMetadata(hed);
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const hed = try readHedFile(allocator, io, path);
    defer allocator.free(hed);
    const metadata = try readMetadata(hed);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    try region.validate(metadata);

    const img = try readImgFile(allocator, io, path);
    defer allocator.free(img);

    const plane_len = try planeByteCount(metadata);
    const offset = try mul(usize, plane_len, plane_index);
    if (offset > img.len or img.len - offset < plane_len) return error.TruncatedData;

    if (region.isFull(metadata)) {
        const out = try allocator.alloc(u8, plane_len);
        @memcpy(out, img[offset..][0..plane_len]);
        return .{ .metadata = metadata, .data = out };
    }

    const bytes_per_pixel = metadata.bytesPerPixel();
    const src_row_bytes = try mul(usize, metadata.width, bytes_per_pixel);
    const dst_row_bytes = try mul(usize, region.width, bytes_per_pixel);
    const out_len = try mul(usize, dst_row_bytes, region.height);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    var row: usize = 0;
    while (row < region.height) : (row += 1) {
        const src_y = @as(usize, region.y) + row;
        const src_x = @as(usize, region.x) * bytes_per_pixel;
        const src_offset = offset + src_y * src_row_bytes + src_x;
        const dst_offset = row * dst_row_bytes;
        @memcpy(out[dst_offset..][0..dst_row_bytes], img[src_offset..][0..dst_row_bytes]);
    }
    return .{ .metadata = metadata, .data = out };
}

fn metadataFromHeader(header: Header) bio.Metadata {
    return .{
        .format = "imagic",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.plane_count, std.math.maxInt(u16))),
        .pixel_type = header.pixel_type,
        .little_endian = true,
        .plane_count = header.plane_count,
        .image_description = header.image_name,
        .dimension_order = "XYZCT",
    };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_len) return error.TruncatedData;
    const plane_count: u32 = @intCast(data.len / header_len);
    if (plane_count == 0) return error.InvalidFormat;

    const height = readU32(data[48..52]);
    const width = readU32(data[52..56]);
    if (width == 0 or height == 0) return error.InvalidFormat;

    const type_text = data[56..60];
    const pixel_type: bio.PixelType = if (std.mem.eql(u8, type_text, "REAL"))
        .float32
    else if (std.mem.eql(u8, type_text, "INTG"))
        .uint16
    else if (std.mem.eql(u8, type_text, "PACK"))
        .uint8
    else if (std.mem.eql(u8, type_text, "COMP") or std.mem.eql(u8, type_text, "RECO"))
        return error.UnsupportedVariant
    else
        return error.InvalidFormat;

    return .{
        .width = width,
        .height = height,
        .plane_count = plane_count,
        .pixel_type = pixel_type,
        .image_name = optionalTrim(data[152..][0..80]),
    };
}

fn readHedFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "hed")) return readFile(allocator, io, path);
    const lower = try replaceExtension(allocator, path, ".hed");
    defer allocator.free(lower);
    return readFile(allocator, io, lower) catch |lower_err| {
        const upper = try replaceExtension(allocator, path, ".HED");
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

fn optionalTrim(bytes: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, bytes, " \t\r\n\x00");
    return if (value.len == 0) null else value;
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = try mul(usize, metadata.width, metadata.height);
    return try mul(usize, pixels, metadata.bytesPerPixel());
}

fn mul(comptime T: type, a: anytype, b: anytype) bio.ReaderError!T {
    return std.math.mul(T, @intCast(a), @intCast(b)) catch error.UnsupportedVariant;
}

fn makeHeader(width: u32, height: u32, pixel_type: []const u8, image_name: []const u8) [header_len]u8 {
    var header = [_]u8{0} ** header_len;
    writeU32(&header, 48, height);
    writeU32(&header, 52, width);
    @memcpy(header[56..60], pixel_type[0..4]);
    @memcpy(header[152..][0..@min(image_name.len, 80)], image_name[0..@min(image_name.len, 80)]);
    return header;
}

test "reads imagic header metadata" {
    const header = makeHeader(2, 3, "REAL", "imagic note");

    const metadata = try readMetadata(&header);
    try std.testing.expectEqualStrings("imagic", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 3), metadata.height);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("imagic note", metadata.image_description.?);
}

test "reads imagic companion img pixels with region crop" {
    const hed_path = "imagic-test.hed";
    const img_path = "imagic-test.img";
    const header = makeHeader(2, 2, "INTG", "stack");
    const pixels = [_]u8{
        1, 0, 2, 0,
        3, 0, 4, 0,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = hed_path, .data = &header });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hed_path) catch {};
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

test "rejects unsupported imagic compressed type" {
    const header = makeHeader(1, 1, "COMP", "");
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(&header));
    try std.testing.expect(!matches(&header));
}
