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
    series_count: u32 = 1,
    pixel_type: bio.PixelType = .uint8,
    row_stride: u32 = 0,
    dimension_order: ?[]const u8 = null,
};

const Sections = struct {
    xml: []u8,
    memory_offset: usize = 0,
    memory_size: usize = 0,
};

pub fn matches(data: []const u8) bool {
    _ = readMetadata(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const allocator = std.heap.page_allocator;
    const sections = try readSections(allocator, data);
    defer allocator.free(sections.xml);

    const description = std.mem.trim(u8, sections.xml, "\x00 \t\r\n");
    if (std.mem.eql(u8, description, lof_description)) return error.InvalidFormat;
    if (std.mem.indexOf(u8, sections.xml, "<DimensionDescription") == null) return error.InvalidFormat;

    var scan = Scan{};
    try parseXml(sections.xml, &scan);
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
        .series_count = scan.series_count,
        .dimension_order = scan.dimension_order orelse "XYZCT",
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
    if (metadata.samples_per_pixel == 3) reverseBgr(out, metadata.pixel_type.bytesPerSample());
    return .{ .metadata = metadata, .data = out };
}

fn readSections(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!Sections {
    if (data.len < 13) return error.TruncatedData;
    if (data[0] != lif_magic or data[8] != memory_magic) return error.InvalidFormat;

    const char_count = std.mem.readInt(u32, data[9..13], .little);
    const byte_count = std.math.mul(usize, char_count, 2) catch return error.UnsupportedVariant;
    const end = std.math.add(usize, 13, byte_count) catch return error.UnsupportedVariant;
    if (end > data.len) return error.TruncatedData;

    const out = try allocator.alloc(u8, char_count);
    errdefer allocator.free(out);
    var index: usize = 0;
    while (index < char_count) : (index += 1) {
        const source = 13 + index * 2;
        const low = data[source];
        const high = data[source + 1];
        out[index] = if (high == 0 and low != 0) low else if (low < 0x80) low else '?';
    }

    var pos = end;
    var memory_offset: usize = 0;
    var memory_size: usize = 0;
    while (pos + 13 <= data.len) {
        if (readU32At(data, pos) == 0 and memory_size > 0) break;
        if (readU32At(data, pos) != lif_magic) break;
        pos += 8;
        if (pos >= data.len or data[pos] != memory_magic) return error.InvalidFormat;
        pos += 1;
        var block_length = try checkedUsize(readU32At(data, pos));
        pos += 4;
        if (pos < data.len and data[pos] != memory_magic) {
            pos -= 4;
            block_length = try checkedUsize(readU64At(data, pos));
            pos += 8;
        }
        if (pos >= data.len or data[pos] != memory_magic) return error.InvalidFormat;
        pos += 1;
        if (pos + 4 > data.len) return error.TruncatedData;
        const desc_chars = readU32At(data, pos);
        pos += 4;
        const desc_bytes = std.math.mul(usize, desc_chars, 2) catch return error.UnsupportedVariant;
        pos = std.math.add(usize, pos, desc_bytes) catch return error.UnsupportedVariant;
        if (pos > data.len) return error.TruncatedData;
        if (block_length > 0 and memory_size == 0) {
            memory_offset = pos;
            memory_size = block_length;
        }
        pos = std.math.add(usize, pos, block_length) catch return error.UnsupportedVariant;
        if (pos > data.len) return error.TruncatedData;
    }

    return .{ .xml = out, .memory_offset = memory_offset, .memory_size = memory_size };
}

fn parseXml(xml: []const u8, scan: *Scan) bio.ReaderError!void {
    const image_count = countElementStarts(xml, "Image");
    if (image_count > 0) scan.series_count = image_count;
    const first_image = firstElementSlice(xml, "Image") orelse xml;

    var found_dimensions = false;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, first_image, pos, "<DimensionDescription")) |start| {
        const end = std.mem.indexOfScalarPos(u8, first_image, start, '>') orelse return error.InvalidFormat;
        try parseDimension(first_image[start .. end + 1], scan);
        found_dimensions = true;
        pos = end + 1;
    }
    if (!found_dimensions) return error.InvalidFormat;

    const channels = countTagStarts(first_image, "ChannelDescription");
    if (channels > 0 and scan.samples == 1) scan.size_c = @max(scan.size_c, boundedDimension(channels));
    if (scan.size_c > 1 or scan.size_t > 1) scan.dimension_order = "XYCZT";
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

fn countElementStarts(xml: []const u8, tag: []const u8) u32 {
    var count: u32 = 0;
    var pos: usize = 0;
    while (findElementStart(xml, tag, pos)) |found| {
        count += 1;
        pos = found + tag.len + 1;
    }
    return count;
}

fn firstElementSlice(xml: []const u8, tag: []const u8) ?[]const u8 {
    const start = findElementStart(xml, tag, 0) orelse return null;
    var close_buf: [96]u8 = undefined;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
    const end = std.mem.indexOfPos(u8, xml, start, close) orelse return xml[start..];
    return xml[start .. end + close.len];
}

fn findElementStart(xml: []const u8, tag: []const u8, start_pos: usize) ?usize {
    var pattern_buf: [96]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "<{s}", .{tag}) catch return null;
    var pos = start_pos;
    while (std.mem.indexOfPos(u8, xml, pos, pattern)) |found| {
        const next = found + pattern.len;
        if (next >= xml.len or xml[next] == '>' or xml[next] == '/' or std.ascii.isWhitespace(xml[next])) return found;
        pos = next;
    }
    return null;
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

fn readU32At(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn readU64At(data: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, data[offset..][0..8], .little);
}

fn checkedUsize(value: anytype) bio.ReaderError!usize {
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
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

fn reverseBgr(data: []u8, bytes_per_sample: usize) void {
    const stride = bytes_per_sample * 3;
    var i: usize = 0;
    while (i + stride <= data.len) : (i += stride) {
        var j: usize = 0;
        while (j < bytes_per_sample) : (j += 1) {
            std.mem.swap(u8, &data[i + j], &data[i + 2 * bytes_per_sample + j]);
        }
    }
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

fn appendU32Le(list: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendUtf16Le(list: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |byte| {
        try list.append(std.testing.allocator, byte);
        try list.append(std.testing.allocator, 0);
    }
}

fn appendMemoryBlock(list: *std.ArrayList(u8), id: []const u8, pixels: []const u8) !void {
    try appendU32Le(list, lif_magic);
    try appendU32Le(list, 0);
    try list.append(std.testing.allocator, memory_magic);
    try appendU32Le(list, @intCast(pixels.len));
    try list.append(std.testing.allocator, memory_magic);
    try appendU32Le(list, @intCast(id.len));
    try appendUtf16Le(list, id);
    try list.appendSlice(std.testing.allocator, pixels);
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
    try std.testing.expectEqual(@as(u32, 1), metadata.series_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, data.items, 0));
}

test "matches Bio-Formats default core metadata for cached LIF fixture" {
    const file_path = "fixtures/cache/lif/20191025 Test FRET 585. 423, 426.lif";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("lif", metadata.format);
    try std.testing.expectEqual(@as(u32, 1024), metadata.width);
    try std.testing.expectEqual(@as(u32, 1024), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 8), metadata.series_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
}

test "rejects leica lof header" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendLifHeader(&data, lof_description);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
}

test "reads leica lif raw uint16 planes from memory block" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendLifHeader(&data,
        \\<LMSDataContainer><Element><Data><Image>
        \\<Dimensions>
        \\<DimensionDescription DimID="1" NumberOfElements="2" BytesInc="2"/>
        \\<DimensionDescription DimID="2" NumberOfElements="1" BytesInc="4"/>
        \\<DimensionDescription DimID="3" NumberOfElements="2" BytesInc="4"/>
        \\</Dimensions>
        \\</Image></Data></Element></LMSDataContainer>
    );
    try appendMemoryBlock(&data, "MemBlock_0", &.{ 1, 0, 2, 0, 3, 0, 4, 0 });

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("lif", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 4, 0 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads leica lif rgb memory and swaps bgr" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendLifHeader(&data,
        \\<LMSDataContainer><Element><Data><Image>
        \\<Dimensions>
        \\<DimensionDescription DimID="1" NumberOfElements="1" BytesInc="3"/>
        \\<DimensionDescription DimID="2" NumberOfElements="1" BytesInc="3"/>
        \\</Dimensions>
        \\</Image></Data></Element></LMSDataContainer>
    );
    try appendMemoryBlock(&data, "MemBlock_0", &.{ 10, 20, 30 });

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.uint8, plane.metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), plane.metadata.samples_per_pixel);
    try std.testing.expectEqualSlices(u8, &.{ 30, 20, 10 }, plane.data);
}

test "reads leica lif rows with padding bytes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendLifHeader(&data,
        \\<LMSDataContainer><Element><Data><Image>
        \\<Dimensions>
        \\<DimensionDescription DimID="1" NumberOfElements="3" BytesInc="1"/>
        \\<DimensionDescription DimID="2" NumberOfElements="2" BytesInc="5"/>
        \\</Dimensions>
        \\</Image></Data></Element></LMSDataContainer>
    );
    try appendMemoryBlock(&data, "MemBlock_0", &.{ 1, 2, 3, 99, 100, 4, 5, 6, 101, 102 });

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, plane.data);
}
