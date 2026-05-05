const std = @import("std");
const bio = @import("../root.zig");

const identifier = "OLYMPUSRAWFORMAT";

const Scan = struct {
    width: u32 = 0,
    height: u32 = 0,
    size_c: u16 = 1,
    samples: u16 = 1,
    size_z: u16 = 1,
    size_t: u16 = 1,
    pixel_type: bio.PixelType = .uint8,
};

pub fn matches(data: []const u8) bool {
    _ = readMetadata(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (data.len < identifier.len) return error.TruncatedData;
    if (!std.mem.eql(u8, data[0..identifier.len], identifier)) return error.InvalidFormat;
    var scan = Scan{};
    var found_xml = false;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, data, pos, "<?xml")) |xml_start| {
        const xml_end = findXmlEnd(data, xml_start);
        if (xml_end <= xml_start) break;
        try parseXml(data[xml_start..xml_end], &scan);
        found_xml = true;
        pos = xml_end;
    }
    if (!found_xml or scan.width == 0 or scan.height == 0) return error.InvalidFormat;
    const plane_count = std.math.mul(u32, scan.size_c, scan.size_z) catch return error.UnsupportedVariant;
    return .{
        .format = "oir",
        .width = scan.width,
        .height = scan.height,
        .size_c = scan.size_c,
        .samples_per_pixel = scan.samples,
        .size_z = scan.size_z,
        .size_t = scan.size_t,
        .pixel_type = scan.pixel_type,
        .little_endian = true,
        .plane_count = std.math.mul(u32, plane_count, scan.size_t) catch return error.UnsupportedVariant,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

fn parseXml(xml: []const u8, scan: *Scan) bio.ReaderError!void {
    if (firstUnsigned(xml, &.{ "base:width", "commonimage:width" })) |width| scan.width = @max(scan.width, width);
    if (firstUnsigned(xml, &.{ "base:height", "commonimage:height" })) |height| scan.height = @max(scan.height, height);
    const rgb = tagTextEquals(xml, "base:colorType", "RGB") or tagTextEquals(xml, "commonphase:colorType", "RGB");
    if (firstUnsigned(xml, &.{ "base:depth", "commonphase:depth" })) |depth| {
        const bytes = if (rgb and depth >= 3) depth / 3 else depth;
        scan.pixel_type = try pixelTypeFromBytes(bytes);
        if (rgb) {
            scan.samples = 3;
            scan.size_c = @max(scan.size_c, 3);
        }
    }
    const channel_count = countTagStarts(xml, "commonphase:channel");
    const element_channel_count = countTagStarts(xml, "commonphase:elementChannel");
    const logical_channels = if (element_channel_count > 0) element_channel_count else channel_count;
    if (logical_channels > 0) scan.size_c = @max(scan.size_c, boundedDimension(logical_channels));
    if (axisSize(xml, "ZSTACK")) |size| scan.size_z = @max(scan.size_z, boundedDimension(size));
    if (axisSize(xml, "TIMELAPSE")) |size| scan.size_t = @max(scan.size_t, boundedDimension(size));
    if (axisSize(xml, "LAMBDA")) |size| scan.size_c = @max(scan.size_c, boundedDimension(size));
}

fn findXmlEnd(data: []const u8, start: usize) usize {
    const next_xml = std.mem.indexOfPos(u8, data, start + 5, "<?xml");
    const nul = std.mem.indexOfScalarPos(u8, data, start, 0);
    if (next_xml) |next| {
        if (nul) |z| return @min(next, z);
        return next;
    }
    return nul orelse data.len;
}

fn firstUnsigned(xml: []const u8, comptime names: []const []const u8) ?u32 {
    inline for (names) |name| {
        if (tagText(xml, name)) |value| {
            return std.fmt.parseUnsigned(u32, std.mem.trim(u8, value, " \t\r\n"), 10) catch null;
        }
    }
    return null;
}

fn axisSize(xml: []const u8, axis_name: []const u8) ?u32 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<commonparam:axis")) |axis_start| {
        const axis_close = std.mem.indexOfPos(u8, xml, axis_start, "</commonparam:axis>") orelse return null;
        const axis_value_start = std.mem.indexOfScalarPos(u8, xml, axis_start, '>') orelse return null;
        const value = std.mem.trim(u8, xml[axis_value_start + 1 .. axis_close], " \t\r\n");
        const search_end = std.mem.indexOfPos(u8, xml, axis_close, "<commonparam:axis") orelse xml.len;
        if (std.mem.eql(u8, value, axis_name)) {
            if (tagText(xml[axis_close..search_end], "commonparam:maxSize")) |size| {
                return std.fmt.parseUnsigned(u32, std.mem.trim(u8, size, " \t\r\n"), 10) catch null;
            }
        }
        pos = axis_close + "</commonparam:axis>".len;
    }
    return null;
}

fn tagTextEquals(xml: []const u8, tag: []const u8, expected: []const u8) bool {
    const value = tagText(xml, tag) orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), expected);
}

fn tagText(xml: []const u8, tag: []const u8) ?[]const u8 {
    var open_buf: [96]u8 = undefined;
    var close_buf: [96]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}", .{tag}) catch return null;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
    const open_start = std.mem.indexOf(u8, xml, open) orelse return null;
    const open_end = std.mem.indexOfScalarPos(u8, xml, open_start, '>') orelse return null;
    const close_start = std.mem.indexOfPos(u8, xml, open_end + 1, close) orelse return null;
    return xml[open_end + 1 .. close_start];
}

fn countTagStarts(xml: []const u8, tag: []const u8) u32 {
    var pattern_buf: [96]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "<{s}", .{tag}) catch return 0;
    var count: u32 = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, pattern)) |found| {
        count += 1;
        pos = found + pattern.len;
    }
    return count;
}

fn pixelTypeFromBytes(bytes: u32) bio.ReaderError!bio.PixelType {
    return switch (bytes) {
        1 => .uint8,
        2 => .uint16,
        4 => .uint32,
        else => error.UnsupportedVariant,
    };
}

fn boundedDimension(value: u32) u16 {
    return @intCast(@min(@max(value, 1), std.math.maxInt(u16)));
}

test "reads olympus oir image metadata from xml blocks" {
    const data =
        identifier ++
        "header<?xml version=\"1.0\"?><commonimage:imageProperties><commonimage:imageInfo>" ++
        "<commonimage:width>11</commonimage:width><commonimage:height>7</commonimage:height>" ++
        "<commonimage:axis><commonparam:axis>ZSTACK</commonparam:axis><commonparam:maxSize>3</commonparam:maxSize></commonimage:axis>" ++
        "<commonimage:axis><commonparam:axis>TIMELAPSE</commonparam:axis><commonparam:maxSize>4</commonparam:maxSize></commonimage:axis>" ++
        "<commonphase:channel id=\"c1\" order=\"1\"><commonphase:imageDefinition><commonphase:depth>2</commonphase:depth></commonphase:imageDefinition></commonphase:channel>" ++
        "<commonphase:channel id=\"c2\" order=\"2\" />" ++
        "</commonimage:imageInfo></commonimage:imageProperties>";

    try std.testing.expect(matches(data));
    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("oir", metadata.format);
    try std.testing.expectEqual(@as(u32, 11), metadata.width);
    try std.testing.expectEqual(@as(u32, 7), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 4), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 24), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
}

test "reports rgb oir frame metadata" {
    const data =
        identifier ++
        "padding<?xml version=\"1.0\"?><commonframe:frameProperties><commonframe:imageDefinition>" ++
        "<base:width>5</base:width><base:height>6</base:height><base:depth>3</base:depth><base:colorType>RGB</base:colorType>" ++
        "</commonframe:imageDefinition></commonframe:frameProperties>";

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, data, 0));
}
