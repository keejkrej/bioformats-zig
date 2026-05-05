const std = @import("std");
const bio = @import("../root.zig");

pub fn matches(data: []const u8) bool {
    _ = jpegInfo(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const info = jpegInfo(data) catch return error.InvalidFormat;
    const samples = @as(u16, info.components);
    const pixel_type: bio.PixelType = if (info.precision <= 8)
        if (samples == 1) .uint8 else .rgb8
    else if (samples == 1) .uint16 else .rgb16;
    return .{
        .format = "jpeg",
        .width = info.width,
        .height = info.height,
        .size_c = samples,
        .samples_per_pixel = samples,
        .pixel_type = pixel_type,
        .plane_count = 1,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

const JpegInfo = struct {
    width: u32,
    height: u32,
    components: u8,
    precision: u8,
};

fn jpegInfo(data: []const u8) !JpegInfo {
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
            const components = data[i + 7];
            if (components == 0) return error.InvalidFormat;
            return .{
                .precision = data[i + 2],
                .height = readU16BE(data[i + 3 ..][0..2]),
                .width = readU16BE(data[i + 5 ..][0..2]),
                .components = components,
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

fn readU16BE(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

const tiny_rgb_jpeg = [_]u8{
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

const tiny_gray_jpeg = [_]u8{
    0xff, 0xd8,
    0xff, 0xc0,
    0x00, 0x0b,
    0x08, 0x00,
    0x05, 0x00,
    0x07, 0x01,
    0x01, 0x11,
    0x00, 0xff,
    0xd9,
};

test "reads rgb jpeg metadata from SOF segment" {
    const metadata = try readMetadata(&tiny_rgb_jpeg);
    try std.testing.expectEqualStrings("jpeg", metadata.format);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
}

test "reads grayscale jpeg metadata from SOF segment" {
    const metadata = try readMetadata(&tiny_gray_jpeg);
    try std.testing.expectEqual(@as(u32, 7), metadata.width);
    try std.testing.expectEqual(@as(u32, 5), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
}
