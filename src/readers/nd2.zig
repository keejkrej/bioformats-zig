const std = @import("std");
const bio = @import("../root.zig");

const magic1: u32 = 0xdacebe0a;
const magic1_alt: u32 = 0x0abeceda;
const magic2: u32 = 0x6a502020;

const Scan = struct {
    width: u32 = 0,
    height: u32 = 0,
    size_c: u16 = 1,
    size_z: u16 = 1,
    size_t: u16 = 1,
    pixel_type: bio.PixelType = .uint8,
};

pub fn matches(data: []const u8) bool {
    _ = readMetadata(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (data.len < 8) return error.TruncatedData;
    if (!hasMagic(data)) return error.InvalidFormat;
    var scan = Scan{};
    parseAscii(data, &scan);
    parseUtf16Le(data, &scan);
    if (scan.width == 0 or scan.height == 0) return error.InvalidFormat;
    const zc = std.math.mul(u32, scan.size_z, scan.size_c) catch return error.UnsupportedVariant;
    return .{
        .format = "nd2",
        .width = scan.width,
        .height = scan.height,
        .size_c = scan.size_c,
        .samples_per_pixel = 1,
        .size_z = scan.size_z,
        .size_t = scan.size_t,
        .pixel_type = scan.pixel_type,
        .little_endian = true,
        .plane_count = std.math.mul(u32, zc, scan.size_t) catch return error.UnsupportedVariant,
        .dimension_order = "XYZCT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    if (metadata.samples_per_pixel != 1) return error.UnsupportedVariant;
    const plane_len = try planeByteCount(metadata);
    const payload = findImageDataPayload(data, plane_index, plane_len) orelse return error.UnsupportedVariant;
    const out = try allocator.dupe(u8, payload[0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn hasMagic(data: []const u8) bool {
    const first = std.mem.readInt(u32, data[0..4], .little);
    const second = std.mem.readInt(u32, data[4..8], .little);
    return first == magic1 or first == magic1_alt or second == magic2;
}

fn parseAscii(data: []const u8, scan: *Scan) void {
    setScanValue(scan, .width, findNumberAfterAny(data, &.{ "uiWidth=\"", "<uiWidth>", "uiWidth=", "Width=", "SizeX=" }) orelse findXmlValueAfter(data, "<uiWidth"));
    setScanValue(scan, .height, findNumberAfterAny(data, &.{ "uiHeight=\"", "<uiHeight>", "uiHeight=", "Height=", "SizeY=" }) orelse findXmlValueAfter(data, "<uiHeight"));
    setScanValue(scan, .size_c, findNumberAfterAny(data, &.{ "SizeC=", "uiCompCount=\"", "<uiCompCount>", "ChannelCount=", "Channels=" }) orelse findXmlValueAfter(data, "<uiComp"));
    setScanValue(scan, .size_z, findNumberAfterAny(data, &.{ "SizeZ=", "Z Stack Loop", "Z-Stack Loop", "ZCount=", "Slices=" }));
    setScanValue(scan, .size_t, findNumberAfterAny(data, &.{ "SizeT=", "Time Loop", "TimeLoop", "TCount=", "Frames=", "Dimensions: T(" }));
    const bits_value = findNumberAfterAny(data, &.{ "uiBpcInMemory=\"", "<uiBpcInMemory>", "uiBpcSignificant=\"", "<uiBpcSignificant>", "BitsPerPixel=", "bitDepth=" }) orelse
        findXmlValueAfter(data, "<uiBpcInMemory") orelse
        findXmlValueAfter(data, "<uiBpcSignificant");
    if (bits_value) |bits| {
        scan.pixel_type = pixelTypeFromBits(bits) catch scan.pixel_type;
    }
}

fn parseUtf16Le(data: []const u8, scan: *Scan) void {
    const allocator = std.heap.page_allocator;
    var ascii = allocator.alloc(u8, data.len) catch return;
    defer allocator.free(ascii);
    var count: usize = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        if (data[i + 1] == 0 and data[i] >= 0x20 and data[i] < 0x7f) {
            ascii[count] = data[i];
            count += 1;
        } else if (count > 0 and ascii[count - 1] != ' ') {
            ascii[count] = ' ';
            count += 1;
        }
    }
    parseAscii(ascii[0..count], scan);
}

const Field = enum { width, height, size_c, size_z, size_t };

fn setScanValue(scan: *Scan, field: Field, value: ?u32) void {
    const v = value orelse return;
    if (v == 0) return;
    switch (field) {
        .width => scan.width = @max(scan.width, v),
        .height => scan.height = @max(scan.height, v),
        .size_c => scan.size_c = @max(scan.size_c, boundedDimension(v)),
        .size_z => scan.size_z = @max(scan.size_z, boundedDimension(v)),
        .size_t => scan.size_t = @max(scan.size_t, boundedDimension(v)),
    }
}

fn findNumberAfterAny(data: []const u8, comptime needles: []const []const u8) ?u32 {
    inline for (needles) |needle| {
        if (findNumberAfter(data, needle)) |value| return value;
    }
    return null;
}

fn findNumberAfter(data: []const u8, needle: []const u8) ?u32 {
    const pos = std.mem.indexOf(u8, data, needle) orelse return null;
    var start = pos + needle.len;
    while (start < data.len and !std.ascii.isDigit(data[start])) : (start += 1) {}
    if (start >= data.len) return null;
    var end = start;
    while (end < data.len and std.ascii.isDigit(data[end])) : (end += 1) {}
    return std.fmt.parseUnsigned(u32, data[start..end], 10) catch null;
}

fn findXmlValueAfter(data: []const u8, element_start: []const u8) ?u32 {
    const pos = std.mem.indexOf(u8, data, element_start) orelse return null;
    const value_pos = std.mem.indexOfPos(u8, data, pos + element_start.len, "value=\"") orelse return null;
    const start = value_pos + "value=\"".len;
    if (start >= data.len or !std.ascii.isDigit(data[start])) return null;
    var end = start;
    while (end < data.len and std.ascii.isDigit(data[end])) : (end += 1) {}
    return std.fmt.parseUnsigned(u32, data[start..end], 10) catch null;
}

fn pixelTypeFromBits(bits: u32) bio.ReaderError!bio.PixelType {
    if (bits <= 8) return .uint8;
    if (bits <= 16) return .uint16;
    if (bits <= 32) return .uint32;
    return error.UnsupportedVariant;
}

fn boundedDimension(value: u32) u16 {
    return @intCast(@min(@max(value, 1), std.math.maxInt(u16)));
}

fn findImageDataPayload(data: []const u8, plane_index: u32, plane_len: usize) ?[]const u8 {
    const marker = "ImageDataSeq|";
    var pos: usize = 0;
    var index: u32 = 0;
    while (std.mem.indexOfPos(u8, data, pos, marker)) |found| {
        const bang = std.mem.indexOfScalarPos(u8, data, found + marker.len, '!') orelse return null;
        const payload_start = bang + 1;
        const next = std.mem.indexOfPos(u8, data, payload_start, marker) orelse data.len;
        if (next >= payload_start and next - payload_start >= plane_len) {
            if (index == plane_index) return data[payload_start..next];
            index += 1;
        }
        pos = payload_start;
    }
    return null;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn appendUtf16Le(list: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |byte| {
        try list.append(std.testing.allocator, byte);
        try list.append(std.testing.allocator, 0);
    }
}

test "reads nd2 metadata from ascii text" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, &.{ 0x0a, 0xbe, 0xce, 0xda, 0, 0, 0, 0 });
    try data.appendSlice(std.testing.allocator,
        \\<uiWidth>11</uiWidth><uiHeight>7</uiHeight><uiBpcInMemory>16</uiBpcInMemory>
        \\SizeC=2
        \\SizeZ=3
        \\SizeT=4
    );

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("nd2", metadata.format);
    try std.testing.expectEqual(@as(u32, 11), metadata.width);
    try std.testing.expectEqual(@as(u32, 7), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 4), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 24), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
}

test "reads nd2 metadata from utf16 text and rejects missing pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, &.{ 0, 0, 0, 0, 0x20, 0x20, 0x50, 0x6a });
    try appendUtf16Le(&data, "<uiWidth>5</uiWidth><uiHeight>6</uiHeight><uiBpcSignificant>8</uiBpcSignificant>SizeC=3");

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 5), metadata.width);
    try std.testing.expectEqual(@as(u32, 6), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, data.items, 0));
}

test "reads nd2 metadata from alternate file magic byte order" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, &.{ 0xda, 0xce, 0xbe, 0x0a, 0, 0, 0, 0 });
    try data.appendSlice(std.testing.allocator,
        \\<uiWidth>3</uiWidth><uiHeight>2</uiHeight><uiBpcInMemory>16</uiBpcInMemory>
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("nd2", metadata.format);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
}

test "reads nd2 metadata from xml value attributes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, &.{ 0xda, 0xce, 0xbe, 0x0a, 0, 0, 0, 0 });
    try data.appendSlice(std.testing.allocator,
        \\<uiWidth runtype="lx_uint32" value="800"/>
        \\<uiHeight runtype="lx_uint32" value="600"/>
        \\<uiComp runtype="lx_uint32" value="1"/>
        \\<uiBpcInMemory runtype="lx_uint32" value="16"/>
        \\Dimensions: T(13) x   (1)
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 800), metadata.width);
    try std.testing.expectEqual(@as(u32, 600), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 13), metadata.size_t);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
}

test "reads nd2 raw image data sequence payload" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, &.{ 0x0a, 0xbe, 0xce, 0xda, 0, 0, 0, 0 });
    try data.appendSlice(std.testing.allocator,
        \\<uiWidth>3</uiWidth><uiHeight>2</uiHeight><uiBpcInMemory>16</uiBpcInMemory>
        \\SizeC=1
        \\SizeZ=2
        \\SizeT=1
    );
    try data.appendSlice(std.testing.allocator, "ImageDataSeq|0!");
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0 });
    try data.appendSlice(std.testing.allocator, "ImageDataSeq|1!");
    try data.appendSlice(std.testing.allocator, &.{ 11, 0, 12, 0, 13, 0, 14, 0, 15, 0, 16, 0 });

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("nd2", plane.metadata.format);
    try std.testing.expectEqual(@as(u32, 3), plane.metadata.width);
    try std.testing.expectEqual(@as(u32, 2), plane.metadata.height);
    try std.testing.expectEqual(@as(u16, 2), plane.metadata.size_z);
    try std.testing.expectEqual(bio.PixelType.uint16, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 11, 0, 12, 0, 13, 0, 14, 0, 15, 0, 16, 0 }, plane.data);
}
