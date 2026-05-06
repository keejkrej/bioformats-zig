const std = @import("std");
const bio = @import("../root.zig");

const magic1: u32 = 0xdacebe0a;
const magic1_alt: u32 = 0x0abeceda;
const magic2: u32 = 0x6a502020;
const max_tail_bytes = 8 * 1024 * 1024;

const Scan = struct {
    width: u32 = 0,
    height: u32 = 0,
    size_c: u16 = 1,
    samples_per_pixel: u16 = 1,
    size_z: u16 = 1,
    size_t: u16 = 1,
    pixel_type: bio.PixelType = .uint8,
};

pub fn matches(data: []const u8) bool {
    _ = readMetadata(data) catch return false;
    return true;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "nd2");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (data.len < 8) return error.TruncatedData;
    if (!hasMagic(data)) return error.InvalidFormat;
    return metadataFromBytes(data, true);
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const tail = try readValidatedTail(allocator, io, path);
    defer allocator.free(tail);
    return metadataFromBytes(tail, false);
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const tail = try readValidatedTail(allocator, io, path);
    defer allocator.free(tail);
    const metadata = try metadataFromBytes(tail, false);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    try region.validate(metadata);

    const entry = try chunkMapEntry(allocator, io, path, tail, plane_index);
    const plane_len = try planeByteCount(metadata);
    if (entry.payload_len < plane_len) return error.UnsupportedVariant;

    const plane_data = try readFileRangeAlloc(allocator, io, path, entry.payload_offset, plane_len);
    errdefer allocator.free(plane_data);
    if (region.isFull(metadata)) return .{ .metadata = metadata, .data = plane_data };
    defer allocator.free(plane_data);
    return .{
        .metadata = metadata,
        .data = try bio.cropPlane(allocator, .{ .metadata = metadata, .data = plane_data }, region),
    };
}

fn metadataFromBytes(data: []const u8, require_magic: bool) bio.ReaderError!bio.Metadata {
    if (require_magic and !hasMagic(data)) return error.InvalidFormat;
    var scan = Scan{};
    parseAscii(data, &scan);
    parseUtf16Le(data, &scan);
    parseAttributes(data, &scan);
    if (scan.width == 0 or scan.height == 0) return error.InvalidFormat;
    const zc = std.math.mul(u32, scan.size_z, scan.size_c) catch return error.UnsupportedVariant;
    return .{
        .format = "nd2",
        .width = scan.width,
        .height = scan.height,
        .size_c = scan.size_c,
        .samples_per_pixel = scan.samples_per_pixel,
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

fn parseAttributes(data: []const u8, scan: *Scan) void {
    setScanValue(scan, .width, findUtf16FieldU32Max(data, "uiWidth"));
    setScanValue(scan, .height, findUtf16FieldU32Max(data, "uiHeight"));
    if (findUtf16FieldU32Max(data, "uiSequenceCount")) |sequence_count| {
        setScanValue(scan, .size_t, sequence_count);
    }
    if (findUtf16FieldU32Max(data, "uiBpcInMemory") orelse findUtf16FieldU32Max(data, "uiBpcSignificant")) |bits| {
        scan.pixel_type = pixelTypeFromBits(bits) catch scan.pixel_type;
    }
    if (findUtf16FieldU32Max(data, "uiComp")) |components| {
        const bounded = boundedDimension(components);
        if (bounded > 1) {
            scan.size_c = 1;
            scan.samples_per_pixel = bounded;
            scan.pixel_type = componentPixelType(scan.pixel_type, bounded);
        }
    }
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

fn componentPixelType(pixel_type: bio.PixelType, samples: u16) bio.PixelType {
    return switch (samples) {
        3 => if (pixel_type.bytesPerSample() == 2) .rgb16 else .rgb8,
        4 => if (pixel_type.bytesPerSample() == 2) .rgba16 else .rgba8,
        else => pixel_type,
    };
}

fn findUtf16FieldU32(data: []const u8, comptime name: []const u8) ?u32 {
    var pos: usize = 0;
    while (pos + name.len * 2 + 6 <= data.len) : (pos += 1) {
        var matched = true;
        inline for (name, 0..) |c, i| {
            if (data[pos + i * 2] != c or data[pos + i * 2 + 1] != 0) {
                matched = false;
                break;
            }
        }
        if (!matched) continue;
        const after_name = pos + name.len * 2;
        if (data[after_name] != 0 or data[after_name + 1] != 0) continue;
        return std.mem.readInt(u32, data[after_name + 2 ..][0..4], .little);
    }
    return null;
}

fn findUtf16FieldU32Max(data: []const u8, comptime name: []const u8) ?u32 {
    var pos: usize = 0;
    var max_value: ?u32 = null;
    while (pos + name.len * 2 + 6 <= data.len) : (pos += 1) {
        var matched = true;
        inline for (name, 0..) |c, i| {
            if (data[pos + i * 2] != c or data[pos + i * 2 + 1] != 0) {
                matched = false;
                break;
            }
        }
        if (!matched) continue;
        const after_name = pos + name.len * 2;
        if (data[after_name] != 0 or data[after_name + 1] != 0) continue;
        const value = std.mem.readInt(u32, data[after_name + 2 ..][0..4], .little);
        max_value = if (max_value) |old| @max(old, value) else value;
    }
    return max_value;
}

const ChunkMapEntry = struct {
    payload_offset: u64,
    payload_len: u64,
};

fn chunkMapEntry(allocator: std.mem.Allocator, io: std.Io, path: []const u8, tail: []const u8, plane_index: u32) !ChunkMapEntry {
    const marker = try std.fmt.allocPrint(allocator, "ImageDataSeq|{}!", .{plane_index});
    defer allocator.free(marker);
    const pos = std.mem.lastIndexOf(u8, tail, marker) orelse return error.UnsupportedVariant;
    const value_start = pos + marker.len;
    if (tail.len - value_start < 16) return error.TruncatedData;
    const chunk_offset = std.mem.readInt(u64, tail[value_start..][0..8], .little);
    const payload_len = std.mem.readInt(u64, tail[value_start + 8 ..][0..8], .little);
    if (chunk_offset > std.math.maxInt(u64) - 16) return error.UnsupportedVariant;
    const header = try readFileRangeAlloc(allocator, io, path, chunk_offset, 16);
    defer allocator.free(header);
    if (header.len != 16 or !hasMagic(header)) return error.InvalidFormat;
    const header_extra = std.mem.readInt(u32, header[4..8], .little);
    const payload_offset = std.math.add(u64, chunk_offset + 16, header_extra) catch return error.UnsupportedVariant;
    return .{ .payload_offset = payload_offset, .payload_len = payload_len };
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

fn readValidatedTail(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try openFile(io, path);
    defer file.close(io);
    const file_len = (try file.stat(io)).size;
    var head: [16]u8 = undefined;
    const head_len = try file.readPositionalAll(io, &head, 0);
    if (head_len < 8 or !hasMagic(head[0..head_len])) return error.InvalidFormat;
    const tail_len_u64 = @min(file_len, max_tail_bytes);
    const tail_len: usize = @intCast(tail_len_u64);
    const tail = try allocator.alloc(u8, tail_len);
    errdefer allocator.free(tail);
    const read_len = try file.readPositionalAll(io, tail, file_len - tail_len_u64);
    if (read_len != tail.len) return error.TruncatedData;
    return tail;
}

fn readFileRangeAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8, offset: u64, len: usize) ![]u8 {
    var file = try openFile(io, path);
    defer file.close(io);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    const read_len = try file.readPositionalAll(io, out, offset);
    if (read_len != len) return error.TruncatedData;
    return out;
}

fn openFile(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().openFile(io, path, .{});
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn appendUtf16Le(list: *std.ArrayList(u8), text: []const u8) !void {
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

fn appendU64Le(list: *std.ArrayList(u8), value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendAttributeField(list: *std.ArrayList(u8), name: []const u8, value: u32) !void {
    try appendUtf16Le(list, name);
    try list.appendSlice(std.testing.allocator, &.{ 0, 0 });
    try appendU32Le(list, value);
}

fn appendChunk(list: *std.ArrayList(u8), name: []const u8, payload: []const u8) !u64 {
    const offset: u64 = list.items.len;
    const header_extra = 64;
    try appendU32Le(list, magic1_alt);
    try appendU32Le(list, header_extra);
    try appendU64Le(list, payload.len);
    try list.appendSlice(std.testing.allocator, name);
    try list.appendNTimes(std.testing.allocator, 0, header_extra - name.len);
    try list.appendSlice(std.testing.allocator, payload);
    return offset;
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

test "reads nd2 path metadata and pixels from v3 chunk map" {
    const file_path = "nd2-path-chunk-map-test.nd2";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var file_bytes: std.ArrayList(u8) = .empty;
    defer file_bytes.deinit(std.testing.allocator);
    var attributes: std.ArrayList(u8) = .empty;
    defer attributes.deinit(std.testing.allocator);

    try appendAttributeField(&attributes, "uiWidth", 2);
    try appendAttributeField(&attributes, "uiHeight", 2);
    try appendAttributeField(&attributes, "uiComp", 3);
    try appendAttributeField(&attributes, "uiBpcInMemory", 16);
    try appendAttributeField(&attributes, "uiSequenceCount", 1);

    _ = try appendChunk(&file_bytes, "ND2 FILE SIGNATURE CHUNK NAME01!", "Ver3.0");
    _ = try appendChunk(&file_bytes, "ImageAttributesLV!", attributes.items);
    const pixels = [_]u8{
        1, 0, 2, 0, 3, 0,
        4, 0, 5, 0, 6, 0,
        7, 0, 8, 0, 9, 0,
        10, 0, 11, 0, 12, 0,
    };
    const image_offset = try appendChunk(&file_bytes, "ImageDataSeq|0!", &pixels);
    try file_bytes.appendSlice(std.testing.allocator, "ImageDataSeq|0!");
    try appendU64Le(&file_bytes, image_offset);
    try appendU64Le(&file_bytes, pixels.len);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = file_bytes.items });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.rgb16, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 1, .y = 0, .width = 1, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 4, 0, 5, 0, 6, 0, 10, 0, 11, 0, 12, 0 }, plane.data);
}
