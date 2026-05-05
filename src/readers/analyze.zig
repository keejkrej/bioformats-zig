const std = @import("std");
const bio = @import("../root.zig");

const header_len = 348;
const magic = 0x15c;
const max_companion_bytes = 512 * 1024 * 1024;

const Header = struct {
    little_endian: bool,
    width: u32,
    height: u32,
    size_z: u16,
    size_t: u16,
    size_c: u16,
    samples_per_pixel: u16,
    pixel_type: bio.PixelType,
    pixel_offset: usize,
    plane_count: u32,
    image_name: ?[]const u8,
    description: ?[]const u8,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "hdr") or hasExtension(path, "img");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    return metadataFromHeader(try parseHeader(data));
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    if (plane_index >= (readMetadata(data) catch return error.InvalidFormat).plane_count) return error.InvalidPlaneIndex;
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
    const hdr = try readHdrFile(allocator, io, path);
    defer allocator.free(hdr);
    const metadata = try readMetadata(hdr);
    const header = try parseHeader(hdr);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    try region.validate(metadata);

    const img = try readImgFile(allocator, io, path);
    defer allocator.free(img);

    const plane_len = try planeByteCount(metadata);
    const plane_offset = try mul(usize, plane_len, plane_index);
    const offset = std.math.add(usize, header.pixel_offset, plane_offset) catch return error.UnsupportedVariant;
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
        .format = "analyze",
        .width = header.width,
        .height = header.height,
        .size_c = header.size_c,
        .samples_per_pixel = header.samples_per_pixel,
        .size_z = header.size_z,
        .size_t = header.size_t,
        .pixel_type = header.pixel_type,
        .little_endian = header.little_endian,
        .plane_count = header.plane_count,
        .image_description = header.description orelse header.image_name,
        .dimension_order = if (header.samples_per_pixel > 1) "XYCZT" else "XYZTC",
    };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_len) return error.TruncatedData;
    if (isNiftiHeader(data)) return error.InvalidFormat;
    const little_size = std.mem.readInt(i32, data[0..4], .little);
    const big_size = std.mem.readInt(i32, data[0..4], .big);
    const little = if (little_size == magic)
        true
    else if (big_size == magic)
        false
    else
        return error.InvalidFormat;
    const endian: std.builtin.Endian = if (little) .little else .big;

    const width = readU16(data[42..44], endian);
    const height = readU16(data[44..46], endian);
    var size_z = readU16(data[46..48], endian);
    var size_t = readU16(data[48..50], endian);
    if (width == 0 or height == 0) return error.InvalidFormat;
    if (size_z == 0) size_z = 1;
    if (size_t == 0) size_t = 1;

    const data_type = readU16(data[70..72], endian);
    const pixel_info = try pixelInfo(data_type);
    const offset_float = readF32(data[108..112], endian);
    if (!std.math.isFinite(offset_float) or offset_float < 0) return error.InvalidFormat;
    const pixel_offset: usize = @intFromFloat(offset_float);
    const zt_planes = std.math.mul(u32, @as(u32, size_z), @as(u32, size_t)) catch return error.UnsupportedVariant;

    return .{
        .little_endian = little,
        .width = width,
        .height = height,
        .size_z = size_z,
        .size_t = size_t,
        .size_c = pixel_info.size_c,
        .samples_per_pixel = pixel_info.samples_per_pixel,
        .pixel_type = pixel_info.pixel_type,
        .pixel_offset = pixel_offset,
        .plane_count = zt_planes,
        .image_name = optionalTrim(data[14..][0..18]),
        .description = optionalTrim(data[148..][0..80]),
    };
}

fn isNiftiHeader(data: []const u8) bool {
    return data.len >= 348 and
        (std.mem.eql(u8, data[344..][0..3], "n+1") or std.mem.eql(u8, data[344..][0..3], "ni1"));
}

const PixelInfo = struct {
    pixel_type: bio.PixelType,
    size_c: u16 = 1,
    samples_per_pixel: u16 = 1,
};

fn pixelInfo(data_type: u16) bio.ReaderError!PixelInfo {
    return switch (data_type) {
        1, 2 => .{ .pixel_type = .uint8 },
        4 => .{ .pixel_type = .int16 },
        8 => .{ .pixel_type = .int32 },
        16 => .{ .pixel_type = .float32 },
        64 => .{ .pixel_type = .float64 },
        128 => .{ .pixel_type = .rgb8, .size_c = 3, .samples_per_pixel = 3 },
        else => error.UnsupportedVariant,
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

fn readU16(bytes: []const u8, endian: std.builtin.Endian) u16 {
    return std.mem.readInt(u16, bytes[0..2], endian);
}

fn readF32(bytes: []const u8, endian: std.builtin.Endian) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[0..4], endian));
}

fn writeU16(bytes: []u8, offset: usize, value: u16, endian: std.builtin.Endian) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, endian);
}

fn writeI32(bytes: []u8, offset: usize, value: i32, endian: std.builtin.Endian) void {
    std.mem.writeInt(i32, bytes[offset..][0..4], value, endian);
}

fn writeF32(bytes: []u8, offset: usize, value: f32, endian: std.builtin.Endian) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], @bitCast(value), endian);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = try mul(usize, metadata.width, metadata.height);
    return try mul(usize, pixels, metadata.bytesPerPixel());
}

fn mul(comptime T: type, a: anytype, b: anytype) bio.ReaderError!T {
    return std.math.mul(T, @intCast(a), @intCast(b)) catch error.UnsupportedVariant;
}

fn makeHeader(endian: std.builtin.Endian, width: u16, height: u16, z: u16, t: u16, data_type: u16, pixel_offset: f32) [header_len]u8 {
    var header = [_]u8{0} ** header_len;
    writeI32(&header, 0, magic, endian);
    @memcpy(header[14..][0..11], "analyze img");
    writeU16(&header, 40, 4, endian);
    writeU16(&header, 42, width, endian);
    writeU16(&header, 44, height, endian);
    writeU16(&header, 46, z, endian);
    writeU16(&header, 48, t, endian);
    writeU16(&header, 70, data_type, endian);
    writeU16(&header, 72, 16, endian);
    writeF32(&header, 108, pixel_offset, endian);
    @memcpy(header[148..][0..12], "analyze note");
    return header;
}

test "reads analyze header metadata" {
    const header = makeHeader(.little, 2, 3, 2, 1, 4, 0);

    const metadata = try readMetadata(&header);
    try std.testing.expectEqualStrings("analyze", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 3), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.int16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("analyze note", metadata.image_description.?);
}

test "reads analyze companion img pixels with region crop" {
    const hdr_path = "analyze-test.hdr";
    const img_path = "analyze-test.img";
    const header = makeHeader(.little, 2, 2, 1, 1, 4, 0);
    const pixels = [_]u8{
        1, 0, 2, 0,
        3, 0, 4, 0,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = hdr_path, .data = &header });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hdr_path) catch {};
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

test "reads analyze big-endian rgb metadata" {
    const header = makeHeader(.big, 1, 1, 1, 1, 128, 0);
    const metadata = try readMetadata(&header);
    try std.testing.expect(!metadata.little_endian);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
}

test "rejects nifti magic header" {
    var header = makeHeader(.little, 1, 1, 1, 1, 2, 352);
    @memcpy(header[344..][0..4], "n+1\x00");

    try std.testing.expect(!matches(&header));
    try std.testing.expectError(error.InvalidFormat, readMetadata(&header));
}
