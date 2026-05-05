const std = @import("std");
const bio = @import("../root.zig");

const magic = "AliconaImaging";
const magic_field_len = 17;
const tag_key_len = 20;
const tag_value_len = 30;
const tag_record_len = 52;

const Header = struct {
    width: u32,
    height: u32,
    plane_count: u32,
    pixel_type: bio.PixelType,
    pixel_offset: usize,
    texture: bool,
    bytes_per_pixel: usize,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "alicona",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
    }) catch return false;
    const pixels_len = std.math.mul(usize, sourcePlaneByteCount(header), header.plane_count) catch return false;
    return plane_len > 0 and data.len >= header.pixel_offset and data.len - header.pixel_offset >= pixels_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "alicona",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_t = @intCast(@min(header.plane_count, std.math.maxInt(u16))),
        .pixel_type = header.pixel_type,
        .little_endian = true,
        .plane_count = header.plane_count,
        .dimension_order = "XYCTZ",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const out_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    if (header.texture) {
        try readTexturePlane(data, header, plane_index, out);
    } else {
        const src_len = sourcePlaneByteCount(header);
        const offset = header.pixel_offset + (std.math.mul(usize, src_len, plane_index) catch return error.UnsupportedVariant);
        if (data.len < offset or data.len - offset < src_len) return error.TruncatedData;
        @memcpy(out, data[offset..][0..out_len]);
    }

    return .{ .metadata = metadata, .data = out };
}

fn readTexturePlane(data: []const u8, header: Header, plane_index: u32, out: []u8) bio.ReaderError!void {
    const padded_width = paddedWidth(header.width);
    const padded_plane_len = std.math.mul(usize, padded_width, header.height) catch return error.UnsupportedVariant;
    const plane_offset = header.pixel_offset + (std.math.mul(usize, padded_plane_len * header.bytes_per_pixel, plane_index) catch return error.UnsupportedVariant);
    const needed = std.math.mul(usize, padded_plane_len, header.bytes_per_pixel) catch return error.UnsupportedVariant;
    if (data.len < plane_offset or data.len - plane_offset < needed) return error.TruncatedData;

    var dst_sample: usize = 0;
    for (0..header.height) |row| {
        const row_base = row * padded_width;
        for (0..header.width) |col| {
            const src_sample = row_base + col;
            for (0..header.bytes_per_pixel) |byte_index| {
                out[dst_sample * header.bytes_per_pixel + byte_index] = data[plane_offset + byte_index * padded_plane_len + src_sample];
            }
            dst_sample += 1;
        }
    }
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < magic_field_len) return error.TruncatedData;
    const magic_text = std.mem.trim(u8, data[0..magic_field_len], " \t\r\n\x00");
    if (!std.mem.eql(u8, magic_text, magic)) return error.InvalidFormat;

    var tag_count: usize = 2;
    var pos: usize = magic_field_len;
    var width: u32 = 0;
    var height: u32 = 0;
    var plane_count: u32 = 1;
    var texture_offset: usize = 0;
    var depth_offset: usize = 0;
    var has_color_texture = false;

    var index: usize = 0;
    while (index < tag_count) : (index += 1) {
        if (data.len - pos < tag_record_len) return error.TruncatedData;
        const key = trimmed(data[pos..][0..tag_key_len]);
        const value = trimmed(data[pos + tag_key_len ..][0..tag_value_len]);
        pos += tag_record_len;

        if (std.mem.eql(u8, key, "TagCount")) {
            tag_count += parseUnsigned(usize, value) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, key, "Rows")) {
            height = parseUnsigned(u32, value) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, key, "Cols")) {
            width = parseUnsigned(u32, value) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, key, "NumberOfPlanes")) {
            plane_count = parseUnsigned(u32, value) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, key, "TextureImageOffset")) {
            texture_offset = parseUnsigned(usize, value) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, key, "TexturePtr")) {
            has_color_texture = !std.mem.eql(u8, value, "7");
        } else if (std.mem.eql(u8, key, "DepthImageOffset")) {
            depth_offset = parseUnsigned(usize, value) catch return error.InvalidFormat;
        }
    }

    if (width == 0 or height == 0 or plane_count == 0) return error.InvalidFormat;
    if (has_color_texture) return error.UnsupportedVariant;
    if (texture_offset != 0) {
        if (texture_offset >= data.len) return error.TruncatedData;
        const padded_plane_len = std.math.mul(usize, paddedWidth(width), height) catch return error.UnsupportedVariant;
        const total_samples = std.math.mul(usize, padded_plane_len, plane_count) catch return error.UnsupportedVariant;
        const available = data.len - texture_offset;
        if (total_samples == 0 or available < total_samples or available % total_samples != 0) return error.InvalidFormat;
        const bytes_per_pixel = available / total_samples;
        return .{
            .width = width,
            .height = height,
            .plane_count = plane_count,
            .pixel_type = switch (bytes_per_pixel) {
                1 => .uint8,
                2 => .uint16,
                else => return error.UnsupportedVariant,
            },
            .pixel_offset = texture_offset,
            .texture = true,
            .bytes_per_pixel = bytes_per_pixel,
        };
    }

    if (depth_offset == 0 or depth_offset >= data.len) return error.InvalidFormat;
    return .{
        .width = width,
        .height = height,
        .plane_count = 1,
        .pixel_type = .float32,
        .pixel_offset = depth_offset,
        .texture = false,
        .bytes_per_pixel = 4,
    };
}

fn trimmed(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n\x00");
}

fn parseUnsigned(comptime T: type, text: []const u8) !T {
    return std.fmt.parseInt(T, text, 10);
}

fn paddedWidth(width: u32) usize {
    const w: usize = width;
    return w + ((8 - (w % 8)) % 8);
}

fn sourcePlaneByteCount(header: Header) usize {
    if (header.texture) {
        return paddedWidth(header.width) * @as(usize, header.height) * header.bytes_per_pixel;
    }
    return @as(usize, header.width) * @as(usize, header.height) * header.bytes_per_pixel;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendMagicAndTags(list: *std.ArrayList(u8), tags: []const struct { []const u8, []const u8 }) !void {
    try list.appendNTimes(std.testing.allocator, 0, magic_field_len);
    @memcpy(list.items[0..magic.len], magic);
    for (tags) |tag| {
        const record = try list.addManyAsSlice(std.testing.allocator, tag_record_len);
        @memset(record, ' ');
        @memcpy(record[0..@min(tag[0].len, tag_key_len)], tag[0][0..@min(tag[0].len, tag_key_len)]);
        @memcpy(record[tag_key_len..][0..@min(tag[1].len, tag_value_len)], tag[1][0..@min(tag[1].len, tag_value_len)]);
        record[tag_key_len + tag_value_len] = '\r';
        record[tag_key_len + tag_value_len + 1] = '\n';
    }
}

test "reads alicona uint8 texture plane with row padding" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    const texture_offset = magic_field_len + 6 * tag_record_len;
    const tags = [_]struct { []const u8, []const u8 }{
        .{ "TagCount", "4" },
        .{ "Rows", "2" },
        .{ "Cols", "3" },
        .{ "NumberOfPlanes", "1" },
        .{ "TextureImageOffset", "329" },
        .{ "TexturePtr", "7" },
    };
    try appendMagicAndTags(&data, &tags);
    try std.testing.expectEqual(@as(usize, texture_offset), data.items.len);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 0, 0, 0, 0, 0 });
    try data.appendSlice(std.testing.allocator, &.{ 4, 5, 6, 0, 0, 0, 0, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, plane.data);
}

test "reads alicona uint16 separated byte texture" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    const tags = [_]struct { []const u8, []const u8 }{
        .{ "TagCount", "4" },
        .{ "Rows", "1" },
        .{ "Cols", "2" },
        .{ "NumberOfPlanes", "1" },
        .{ "TextureImageOffset", "329" },
        .{ "TexturePtr", "7" },
    };
    try appendMagicAndTags(&data, &tags);
    try data.appendSlice(std.testing.allocator, &.{ 0x34, 0xcd, 0, 0, 0, 0, 0, 0 });
    try data.appendSlice(std.testing.allocator, &.{ 0x12, 0xab, 0, 0, 0, 0, 0, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
}

test "reads alicona float depth plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    const tags = [_]struct { []const u8, []const u8 }{
        .{ "TagCount", "3" },
        .{ "Rows", "1" },
        .{ "Cols", "1" },
        .{ "NumberOfPlanes", "1" },
        .{ "DepthImageOffset", "277" },
    };
    try appendMagicAndTags(&data, &tags);
    try data.appendSlice(std.testing.allocator, &.{ 0, 0, 0x80, 0x3f });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0x80, 0x3f }, plane.data);
}

test "rejects alicona color texture variant" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    const tags = [_]struct { []const u8, []const u8 }{
        .{ "TagCount", "4" },
        .{ "Rows", "1" },
        .{ "Cols", "1" },
        .{ "NumberOfPlanes", "1" },
        .{ "TextureImageOffset", "329" },
        .{ "TexturePtr", "8" },
    };
    try appendMagicAndTags(&data, &tags);
    try data.append(std.testing.allocator, 0);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}
