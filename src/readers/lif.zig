const std = @import("std");
const bio = @import("../root.zig");

const lif_magic: u8 = 0x70;
const memory_magic: u8 = 0x2a;
const lof_description = "LMS_Object_File";

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
    const allocator = std.heap.page_allocator;
    const xml = try readInitialString(allocator, data);
    defer allocator.free(xml);

    const description = std.mem.trim(u8, xml, "\x00 \t\r\n");
    if (std.mem.eql(u8, description, lof_description)) return error.InvalidFormat;
    if (std.mem.indexOf(u8, xml, "<DimensionDescription") == null) return error.InvalidFormat;

    var scan = Scan{};
    try parseXml(xml, &scan);
    if (scan.width == 0 or scan.height == 0) return error.InvalidFormat;

    const zc = std.math.mul(u32, scan.size_z, scan.size_c) catch return error.UnsupportedVariant;
    return .{
        .format = "lif",
        .width = scan.width,
        .height = scan.height,
        .size_c = scan.size_c,
        .samples_per_pixel = scan.samples,
        .size_z = scan.size_z,
        .size_t = scan.size_t,
        .pixel_type = scan.pixel_type,
        .little_endian = true,
        .plane_count = std.math.mul(u32, zc, scan.size_t) catch return error.UnsupportedVariant,
        .dimension_order = "XYZCT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

fn readInitialString(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError![]u8 {
    if (data.len < 13) return error.TruncatedData;
    if (data[0] != lif_magic or data[8] != memory_magic) return error.InvalidFormat;

    const char_count = std.mem.readInt(u32, data[9..13], .little);
    const byte_count = std.math.mul(usize, char_count, 2) catch return error.UnsupportedVariant;
    const end = std.math.add(usize, 13, byte_count) catch return error.UnsupportedVariant;
    if (end > data.len) return error.TruncatedData;

    const out = try allocator.alloc(u8, char_count);
    var index: usize = 0;
    while (index < char_count) : (index += 1) {
        const source = 13 + index * 2;
        const low = data[source];
        const high = data[source + 1];
        out[index] = if (high == 0 and low != 0) low else if (low < 0x80) low else '?';
    }
    return out;
}

fn parseXml(xml: []const u8, scan: *Scan) bio.ReaderError!void {
    var found_dimensions = false;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<DimensionDescription")) |start| {
        const end = std.mem.indexOfScalarPos(u8, xml, start, '>') orelse return error.InvalidFormat;
        try parseDimension(xml[start .. end + 1], scan);
        found_dimensions = true;
        pos = end + 1;
    }
    if (!found_dimensions) return error.InvalidFormat;

    const channels = countTagStarts(xml, "ChannelDescription");
    if (channels > 0 and scan.samples == 1) scan.size_c = @max(scan.size_c, boundedDimension(channels));
}

fn parseDimension(tag: []const u8, scan: *Scan) bio.ReaderError!void {
    const dim_id = attrUnsigned(tag, "DimID") orelse return;
    const elements = attrUnsigned(tag, "NumberOfElements") orelse return;
    const bytes_inc = attrUnsigned(tag, "BytesInc");

    switch (dim_id) {
        1 => {
            scan.width = @max(scan.width, elements);
            if (bytes_inc) |bytes| {
                if (bytes > 0 and bytes % 3 == 0) {
                    scan.samples = 3;
                    scan.size_c = @max(scan.size_c, 3);
                    scan.pixel_type = try pixelTypeFromBytes(bytes / 3);
                } else if (bytes > 0) {
                    scan.pixel_type = try pixelTypeFromBytes(bytes);
                }
            }
        },
        2 => {
            if (scan.height == 0) {
                scan.height = elements;
            } else if (scan.size_z == 1) {
                scan.size_z = boundedDimension(elements);
            } else {
                scan.size_t = boundedDimension(elements);
            }
        },
        3 => scan.size_z = boundedDimension(elements),
        4 => scan.size_t = boundedDimension(elements),
        else => {},
    }
}

fn attrUnsigned(tag: []const u8, name: []const u8) ?u32 {
    const value = attrValue(tag, name) orelse return null;
    return std.fmt.parseUnsigned(u32, value, 10) catch null;
}

fn attrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, tag, pos, name)) |name_pos| {
        if (name_pos > 0 and !std.ascii.isWhitespace(tag[name_pos - 1]) and tag[name_pos - 1] != '<') {
            pos = name_pos + name.len;
            continue;
        }
        var cursor = name_pos + name.len;
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len or tag[cursor] != '=') {
            pos = cursor;
            continue;
        }
        cursor += 1;
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) : (cursor += 1) {}
        if (cursor >= tag.len or (tag[cursor] != '"' and tag[cursor] != '\'')) return null;
        const quote = tag[cursor];
        const start = cursor + 1;
        const end = std.mem.indexOfScalarPos(u8, tag, start, quote) orelse return null;
        return tag[start..end];
    }
    return null;
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
        4 => .float32,
        8 => .float64,
        else => error.UnsupportedVariant,
    };
}

fn boundedDimension(value: u32) u16 {
    return @intCast(@min(@max(value, 1), std.math.maxInt(u16)));
}

fn appendLifHeader(list: *std.ArrayList(u8), text: []const u8) !void {
    try list.appendSlice(std.testing.allocator, &.{ lif_magic, 0, 0, 0, 0, 0, 0, 0, memory_magic });
    var count_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_bytes, @intCast(text.len), .little);
    try list.appendSlice(std.testing.allocator, &count_bytes);
    for (text) |byte| {
        try list.append(std.testing.allocator, byte);
        try list.append(std.testing.allocator, 0);
    }
}

test "reads leica lif metadata from initial xml block" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendLifHeader(&data,
        \\<LMSDataContainer><Element><Data><Image>
        \\<Dimensions>
        \\<DimensionDescription DimID="1" NumberOfElements="11" BytesInc="2"/>
        \\<DimensionDescription DimID="2" NumberOfElements="7" BytesInc="22"/>
        \\<DimensionDescription DimID="3" NumberOfElements="3" BytesInc="154"/>
        \\<DimensionDescription DimID="4" NumberOfElements="4" BytesInc="462"/>
        \\</Dimensions>
        \\<Channels><ChannelDescription BytesInc="154"/><ChannelDescription BytesInc="154"/></Channels>
        \\</Image></Data></Element></LMSDataContainer>
    );

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("lif", metadata.format);
    try std.testing.expectEqual(@as(u32, 11), metadata.width);
    try std.testing.expectEqual(@as(u32, 7), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 4), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 24), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, data.items, 0));
}

test "rejects leica lof header" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendLifHeader(&data, lof_description);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
}
