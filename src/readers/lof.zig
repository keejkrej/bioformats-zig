const std = @import("std");
const bio = @import("../root.zig");

const lof_magic: u32 = 0x70;
const memory_magic: u8 = 0x2a;
const type_name = "LMS_Object_File";

const Scan = struct {
    width: u32 = 0,
    height: u32 = 0,
    size_c: u16 = 1,
    samples: u16 = 1,
    size_z: u16 = 1,
    size_t: u16 = 1,
    pixel_type: bio.PixelType = .uint8,
    row_stride: u32 = 0,
};

const Sections = struct {
    memory_offset: usize,
    memory_size: usize,
    xml: []u8,
};

pub fn matches(data: []const u8) bool {
    _ = readMetadata(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const allocator = std.heap.page_allocator;
    const xml = try readXmlSection(allocator, data);
    defer allocator.free(xml);

    if (std.mem.indexOf(u8, xml, "<Image") == null or
        std.mem.indexOf(u8, xml, "<DimensionDescription") == null)
    {
        return error.InvalidFormat;
    }

    var scan = Scan{};
    try parseXml(xml, &scan);
    if (scan.width == 0 or scan.height == 0) return error.InvalidFormat;

    const zc = std.math.mul(u32, scan.size_z, scan.size_c) catch return error.UnsupportedVariant;
    return .{
        .format = "lof",
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
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;

    const sections = try readSections(allocator, data);
    defer allocator.free(sections.xml);
    if (sections.memory_size == 0) return error.UnsupportedVariant;
    var scan = Scan{};
    try parseXml(sections.xml, &scan);

    const plane_len = try planeByteCount(metadata);
    const row_padding = try rowPaddingBytes(scan, metadata);
    const source_plane_len = std.math.add(usize, plane_len, std.math.mul(usize, row_padding, metadata.height) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    const source_offset = std.math.add(usize, sections.memory_offset, std.math.mul(usize, source_plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    const memory_end = std.math.add(usize, sections.memory_offset, sections.memory_size) catch return error.UnsupportedVariant;
    if (source_offset > memory_end or memory_end - source_offset < source_plane_len) return error.TruncatedData;

    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    if (row_padding == 0) {
        @memcpy(out, data[source_offset..][0..plane_len]);
    } else {
        const row_len = try rowByteCount(metadata);
        var row: usize = 0;
        while (row < metadata.height) : (row += 1) {
            const src = source_offset + row * (row_len + row_padding);
            const dst = row * row_len;
            @memcpy(out[dst..][0..row_len], data[src..][0..row_len]);
        }
    }
    return .{ .metadata = metadata, .data = out };
}

fn readXmlSection(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError![]u8 {
    const sections = try readSections(allocator, data);
    return sections.xml;
}

fn readSections(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!Sections {
    var pos: usize = 0;
    try expectU32(data, &pos, lof_magic);
    _ = try readU32(data, &pos);
    try expectByte(data, &pos, memory_magic);
    const name_chars = try readU32(data, &pos);
    const name = try readUtf16Le(allocator, data, &pos, name_chars);
    defer allocator.free(name);
    if (!std.mem.eql(u8, name, type_name)) return error.InvalidFormat;

    try expectByte(data, &pos, memory_magic);
    _ = try readU32(data, &pos);
    try expectByte(data, &pos, memory_magic);
    _ = try readU32(data, &pos);
    try expectByte(data, &pos, memory_magic);
    const memory_size = try readU64(data, &pos);
    const memory_offset = pos;
    pos = std.math.add(usize, pos, memory_size) catch return error.UnsupportedVariant;
    if (pos > data.len) return error.TruncatedData;

    try expectU32(data, &pos, lof_magic);
    _ = try readU32(data, &pos);
    try expectByte(data, &pos, memory_magic);
    const xml_chars = try readU32(data, &pos);
    return .{
        .memory_offset = memory_offset,
        .memory_size = memory_size,
        .xml = try readUtf16Le(allocator, data, &pos, xml_chars),
    };
}

fn readUtf16Le(allocator: std.mem.Allocator, data: []const u8, pos: *usize, char_count: u32) bio.ReaderError![]u8 {
    const byte_count = std.math.mul(usize, char_count, 2) catch return error.UnsupportedVariant;
    const end = std.math.add(usize, pos.*, byte_count) catch return error.UnsupportedVariant;
    if (end > data.len) return error.TruncatedData;

    const out = try allocator.alloc(u8, char_count);
    var index: usize = 0;
    while (index < char_count) : (index += 1) {
        const source = pos.* + index * 2;
        const low = data[source];
        const high = data[source + 1];
        out[index] = if (high == 0 and low != 0) low else if (low < 0x80) low else '?';
    }
    pos.* = end;
    return out;
}

fn readU32(data: []const u8, pos: *usize) bio.ReaderError!u32 {
    const end = std.math.add(usize, pos.*, 4) catch return error.UnsupportedVariant;
    if (end > data.len) return error.TruncatedData;
    const value = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* = end;
    return value;
}

fn readU64(data: []const u8, pos: *usize) bio.ReaderError!usize {
    const end = std.math.add(usize, pos.*, 8) catch return error.UnsupportedVariant;
    if (end > data.len) return error.TruncatedData;
    const value = std.mem.readInt(u64, data[pos.*..][0..8], .little);
    pos.* = end;
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
}

fn expectU32(data: []const u8, pos: *usize, expected: u32) bio.ReaderError!void {
    if (try readU32(data, pos) != expected) return error.InvalidFormat;
}

fn expectByte(data: []const u8, pos: *usize, expected: u8) bio.ReaderError!void {
    if (pos.* >= data.len) return error.TruncatedData;
    if (data[pos.*] != expected) return error.InvalidFormat;
    pos.* += 1;
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
            if (bytes_inc) |bytes| scan.row_stride = @max(scan.row_stride, bytes);
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

fn rowByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    return std.math.mul(usize, metadata.width, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    return std.math.mul(usize, try rowByteCount(metadata), metadata.height) catch return error.UnsupportedVariant;
}

fn rowPaddingBytes(scan: Scan, metadata: bio.Metadata) bio.ReaderError!usize {
    if (metadata.width % 4 == 0 or scan.row_stride == 0) return 0;
    const row_len = try rowByteCount(metadata);
    if (scan.row_stride <= row_len) return 0;
    return scan.row_stride - row_len;
}

fn appendU32Le(list: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendU64Le(list: *std.ArrayList(u8), value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendUtf16Le(list: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |byte| {
        try list.append(std.testing.allocator, byte);
        try list.append(std.testing.allocator, 0);
    }
}

fn appendTaggedUtf16(list: *std.ArrayList(u8), text: []const u8) !void {
    try list.append(std.testing.allocator, memory_magic);
    try appendU32Le(list, @intCast(text.len));
    try appendUtf16Le(list, text);
}

fn appendLofHeader(list: *std.ArrayList(u8), xml: []const u8, memory: []const u8) !void {
    try appendU32Le(list, lof_magic);
    try appendU32Le(list, @intCast(1 + 4 + type_name.len * 2));
    try appendTaggedUtf16(list, type_name);
    try list.append(std.testing.allocator, memory_magic);
    try appendU32Le(list, 1);
    try list.append(std.testing.allocator, memory_magic);
    try appendU32Le(list, 0);
    try list.append(std.testing.allocator, memory_magic);
    try appendU64Le(list, memory.len);
    try list.appendSlice(std.testing.allocator, memory);
    try appendU32Le(list, lof_magic);
    try appendU32Le(list, @intCast(1 + 4 + xml.len * 2));
    try appendTaggedUtf16(list, xml);
}

test "reads leica lof metadata from xml section" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendLofHeader(&data,
        \\<LMSDataContainer><Element><Data><Image>
        \\<Dimensions>
        \\<DimensionDescription DimID="1" NumberOfElements="13" BytesInc="2"/>
        \\<DimensionDescription DimID="2" NumberOfElements="9" BytesInc="26"/>
        \\<DimensionDescription DimID="3" NumberOfElements="2" BytesInc="234"/>
        \\<DimensionDescription DimID="4" NumberOfElements="5" BytesInc="468"/>
        \\</Dimensions>
        \\<Channels><ChannelDescription BytesInc="234"/><ChannelDescription BytesInc="234"/></Channels>
        \\</Image></Data></Element></LMSDataContainer>
    , &.{ 0x12, 0x34 });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("lof", metadata.format);
    try std.testing.expectEqual(@as(u32, 13), metadata.width);
    try std.testing.expectEqual(@as(u32, 9), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 5), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 20), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expectError(error.TruncatedData, readPlaneIndex(std.testing.allocator, data.items, 0));
}

test "rejects lof file without image xml" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendLofHeader(&data, "<LMSDataContainer><Element /></LMSDataContainer>", &.{});

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
}

test "reads lof raw uint16 planes from memory block" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendLofHeader(&data,
        \\<LMSDataContainer><Element><Data><Image>
        \\<Dimensions>
        \\<DimensionDescription DimID="1" NumberOfElements="2" BytesInc="2"/>
        \\<DimensionDescription DimID="2" NumberOfElements="1" BytesInc="4"/>
        \\<DimensionDescription DimID="3" NumberOfElements="2" BytesInc="4"/>
        \\</Dimensions>
        \\</Image></Data></Element></LMSDataContainer>
    , &.{ 1, 0, 2, 0, 3, 0, 4, 0 });

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("lof", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 4, 0 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads lof rows with padding bytes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendLofHeader(&data,
        \\<LMSDataContainer><Element><Data><Image>
        \\<Dimensions>
        \\<DimensionDescription DimID="1" NumberOfElements="3" BytesInc="1"/>
        \\<DimensionDescription DimID="2" NumberOfElements="2" BytesInc="5"/>
        \\</Dimensions>
        \\</Image></Data></Element></LMSDataContainer>
    , &.{ 1, 2, 3, 99, 100, 4, 5, 6, 101, 102 });

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.uint8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, plane.data);
}
