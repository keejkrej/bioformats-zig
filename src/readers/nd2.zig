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
    series_count: u32 = 1,
    timestamp_count: u32 = 0,
    position_x_count: u32 = 0,
    position_y_count: u32 = 0,
    position_z_count: u32 = 0,
    position_z1_count: u32 = 0,
    timestamp_first_seconds: ?f64 = null,
    timestamp_last_seconds: ?f64 = null,
    pixel_type: bio.PixelType = .uint8,
    dimension_order: ?[]const u8 = null,
    loop_order: [3]u8 = .{ 0, 0, 0 },
    loop_order_len: u8 = 0,
    lossless_compression: bool = false,
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
    var scan = try scanFromBytes(tail, false);
    parseCustomDataFileMapEntries(tail, &scan);
    try parseCustomDataFileMapPayloads(allocator, io, path, tail, &scan);
    return metadataFromScan(scan);
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    return readPlanePathRegionSeriesIndex(allocator, io, path, 0, plane_index, region);
}

pub fn readPlanePathRegionSeriesIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    series_index: u32,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const tail = try readValidatedTail(allocator, io, path);
    defer allocator.free(tail);
    var scan = try scanFromBytes(tail, false);
    parseCustomDataFileMapEntries(tail, &scan);
    try parseCustomDataFileMapPayloads(allocator, io, path, tail, &scan);
    const metadata = try metadataFromScan(scan);
    if (series_index >= metadata.series_count) return error.InvalidPlaneIndex;
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    try region.validate(metadata);

    const image_index = seriesPlaneToImageIndex(scan, metadata, series_index, plane_index) orelse return error.InvalidPlaneIndex;
    const entry = try chunkMapEntry(allocator, io, path, tail, image_index);
    if (scan.lossless_compression) {
        const compressed_len = try checkedUsize(entry.payload_len);
        const compressed = try readFileRangeAlloc(allocator, io, path, entry.payload_offset, compressed_len);
        defer allocator.free(compressed);
        const plane_data = try readZlibCompressedPlane(allocator, compressed, metadata, region);
        errdefer allocator.free(plane_data);
        return .{ .metadata = metadata, .data = plane_data };
    }
    const read_len = try storedPlaneByteCount(metadata, entry.payload_len);
    if (entry.payload_len < read_len) return error.UnsupportedVariant;

    const stored_data = try readFileRangeAlloc(allocator, io, path, entry.payload_offset, read_len);
    defer allocator.free(stored_data);
    const plane_data = try compactStoredPlane(allocator, stored_data, metadata, region);
    errdefer allocator.free(plane_data);
    return .{
        .metadata = metadata,
        .data = plane_data,
    };
}

fn metadataFromBytes(data: []const u8, require_magic: bool) bio.ReaderError!bio.Metadata {
    return metadataFromScan(try scanFromBytes(data, require_magic));
}

fn scanFromBytes(data: []const u8, require_magic: bool) bio.ReaderError!Scan {
    if (require_magic and !hasMagic(data)) return error.InvalidFormat;
    var scan = Scan{};
    parseAscii(data, &scan);
    parseUtf16Le(data, &scan);
    parseAttributes(data, &scan);
    parseImageMetadataLvLoops(data, &scan);
    parseCustomDataArrays(data, &scan);
    finalizeDimensionOrder(&scan);
    if (scan.width == 0 or scan.height == 0) return error.InvalidFormat;
    return scan;
}

fn metadataFromScan(scan: Scan) bio.ReaderError!bio.Metadata {
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
        .series_count = scan.series_count,
        .timestamp_count = scan.timestamp_count,
        .position_x_count = scan.position_x_count,
        .position_y_count = scan.position_y_count,
        .position_z_count = scan.position_z_count,
        .position_z1_count = scan.position_z1_count,
        .timestamp_first_seconds = scan.timestamp_first_seconds,
        .timestamp_last_seconds = scan.timestamp_last_seconds,
        .dimension_order = scan.dimension_order orelse "XYZCT",
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
    parseExperimentLoops(data, scan);
    const bits_value = findNumberAfterAny(data, &.{ "uiBpcInMemory=\"", "<uiBpcInMemory>", "uiBpcSignificant=\"", "<uiBpcSignificant>", "BitsPerPixel=", "bitDepth=" }) orelse
        findXmlValueAfter(data, "<uiBpcInMemory") orelse
        findXmlValueAfter(data, "<uiBpcSignificant");
    if (bits_value) |bits| {
        scan.pixel_type = pixelTypeFromBits(bits) catch scan.pixel_type;
    }
}

fn parseExperimentLoops(data: []const u8, scan: *Scan) void {
    const prefix = "runtype=\"RLxExperiment.RLxExp";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, data, pos, prefix)) |found| {
        const name_start = found + prefix.len;
        const name_end = std.mem.indexOfScalarPos(u8, data, name_start, '"') orelse break;
        const loop_name = data[name_start..name_end];
        const next_loop = std.mem.indexOfPos(u8, data, name_end, prefix) orelse data.len;
        const loop_body = data[found..next_loop];
        const count = findXmlValueAfter(loop_body, "<uiCount") orelse findNumberAfter(loop_body, "<uiCount");

        if (std.mem.endsWith(u8, loop_name, "TimeLoop")) {
            if (count) |value| scan.size_t = boundedDimension(value);
            scan.dimension_order = "XYCZT";
            prependLoopAxis(scan, 'T');
        } else if (std.mem.endsWith(u8, loop_name, "ZStackLoop")) {
            if (count) |value| scan.size_z = boundedDimension(value);
            scan.dimension_order = "XYZCT";
            prependLoopAxis(scan, 'Z');
        } else if (std.mem.endsWith(u8, loop_name, "XYPosLoop")) {
            if (count) |value| scan.series_count = @max(scan.series_count, value);
            prependLoopAxis(scan, 'M');
        }

        pos = name_end;
    }
}

fn prependLoopAxis(scan: *Scan, axis: u8) void {
    if (std.mem.indexOfScalar(u8, scan.loop_order[0..scan.loop_order_len], axis) != null) return;
    var i: usize = @min(scan.loop_order_len, scan.loop_order.len - 1);
    while (i > 0) : (i -= 1) {
        scan.loop_order[i] = scan.loop_order[i - 1];
    }
    scan.loop_order[0] = axis;
    if (scan.loop_order_len < scan.loop_order.len) scan.loop_order_len += 1;
}

fn parseImageMetadataLvLoops(data: []const u8, scan: *Scan) void {
    var pos: usize = 0;
    var e_type: ?u32 = null;
    var current_count_set = false;
    var in_experiment = false;

    while (pos + 8 < data.len) : (pos += 1) {
        if (utf16FieldValueAt(data, pos, "SLxExperiment")) |_| {
            in_experiment = true;
            e_type = null;
            current_count_set = false;
            continue;
        }
        if (in_experiment) {
            if (utf16FieldValueAt(data, pos, "eType")) |value| {
                e_type = value;
                continue;
            }
            if (utf16FieldValueAt(data, pos, "uiCount")) |value| {
                if (!current_count_set) {
                    if (e_type) |loop_type| {
                        switch (loop_type) {
                            2 => {
                                scan.series_count = @max(scan.series_count, value);
                                prependLoopAxis(scan, 'M');
                            },
                            1 => {
                                scan.size_t = boundedDimension(value);
                                scan.dimension_order = "XYCZT";
                                prependLoopAxis(scan, 'T');
                            },
                            4 => {
                                scan.size_z = boundedDimension(value);
                                if (scan.dimension_order == null) scan.dimension_order = "XYZCT";
                                prependLoopAxis(scan, 'Z');
                            },
                            else => {},
                        }
                        current_count_set = true;
                    }
                }
                continue;
            }
            if (utf16FieldValueAt(data, pos, "uiNextLevelCount")) |value| {
                current_count_set = false;
                if (value != 0) e_type = null else in_experiment = false;
            }
        }
    }
}

fn parseCustomDataArrays(data: []const u8, scan: *Scan) void {
    var pos: usize = 0;
    while (pos + 16 <= data.len) {
        if (!hasMagic(data[pos..][0..16])) {
            pos += 1;
            continue;
        }

        const header_extra = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        const payload_len = std.mem.readInt(u64, data[pos + 8 ..][0..8], .little);
        if (header_extra == 0 or header_extra > data.len) {
            pos += 1;
            continue;
        }
        if (payload_len > data.len) {
            pos += 1;
            continue;
        }

        const name_start = pos + 16;
        const payload_start = name_start + @as(usize, @intCast(header_extra));
        const payload_end = payload_start + @as(usize, @intCast(payload_len));
        if (payload_start > data.len or payload_end > data.len) {
            pos += 1;
            continue;
        }

        if (chunkHeaderName(data[name_start..payload_start])) |name| applyCustomDataPayload(scan, name, data[payload_start..payload_end]);

        pos = payload_end;
    }
}

fn parseCustomDataFileMapEntries(tail: []const u8, scan: *Scan) void {
    const signature = "ND2 FILEMAP SIGNATURE NAME 0001!";
    var cursor = (std.mem.lastIndexOf(u8, tail, signature) orelse return) + signature.len;
    while (cursor + 17 <= tail.len) {
        const bang = findEntryBang(tail, cursor) orelse return;
        const name = tail[cursor..bang];
        if (std.mem.eql(u8, name, "ND2 CHUNK MAP SIGNATURE 0000001")) return;
        const value_start = bang + 1;
        if (tail.len - value_start < 16) return;
        const payload_len = std.mem.readInt(u64, tail[value_start + 8 ..][0..8], .little);
        applyCustomDataCount(scan, name, payload_len);
        cursor = value_start + 16;
    }
}

fn parseCustomDataFileMapPayloads(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    tail: []const u8,
    scan: *Scan,
) !void {
    const signature = "ND2 FILEMAP SIGNATURE NAME 0001!";
    var cursor = (std.mem.lastIndexOf(u8, tail, signature) orelse return) + signature.len;
    while (cursor + 17 <= tail.len) {
        const bang = findEntryBang(tail, cursor) orelse return;
        const name = tail[cursor..bang];
        if (std.mem.eql(u8, name, "ND2 CHUNK MAP SIGNATURE 0000001")) return;
        const value_start = bang + 1;
        if (tail.len - value_start < 16) return;
        const chunk_offset = std.mem.readInt(u64, tail[value_start..][0..8], .little);
        const payload_len = std.mem.readInt(u64, tail[value_start + 8 ..][0..8], .little);
        if (std.mem.startsWith(u8, name, "CustomData|") and payload_len <= max_tail_bytes) {
            const payload = readMetadataChunkPayload(allocator, io, path, chunk_offset, payload_len) catch {
                cursor = value_start + 16;
                continue;
            };
            defer allocator.free(payload);
            applyCustomDataPayload(scan, name, payload);
        }
        cursor = value_start + 16;
    }
}

fn readMetadataChunkPayload(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    chunk_offset: u64,
    payload_len: u64,
) ![]u8 {
    const header = try readFileRangeAlloc(allocator, io, path, chunk_offset, 16);
    defer allocator.free(header);
    if (header.len != 16 or !hasMagic(header)) return error.InvalidFormat;
    const header_extra = std.mem.readInt(u32, header[4..8], .little);
    const payload_offset = std.math.add(u64, chunk_offset + 16, header_extra) catch return error.UnsupportedVariant;
    return readFileRangeAlloc(allocator, io, path, payload_offset, try checkedUsize(payload_len));
}

fn applyCustomDataCount(scan: *Scan, name: []const u8, payload_len: u64) void {
    if (payload_len % 8 != 0) return;
    const value_count: u32 = @intCast(@min(payload_len / 8, std.math.maxInt(u32)));
    if (std.mem.startsWith(u8, name, "CustomData|AcqTimesCache")) {
        scan.timestamp_count = @max(scan.timestamp_count, value_count);
        if (value_count > 1 and scan.size_t == 1 and scan.size_z == 1 and scan.size_c == 1) {
            scan.size_t = boundedDimension(value_count);
            if (scan.dimension_order == null) scan.dimension_order = "XYCZT";
        }
    } else if (std.mem.startsWith(u8, name, "CustomData|Z1")) {
        scan.position_z1_count = @max(scan.position_z1_count, value_count);
    } else if (std.mem.startsWith(u8, name, "CustomData|X")) {
        scan.position_x_count = @max(scan.position_x_count, value_count);
    } else if (std.mem.startsWith(u8, name, "CustomData|Y")) {
        scan.position_y_count = @max(scan.position_y_count, value_count);
    } else if (std.mem.startsWith(u8, name, "CustomData|Z")) {
        scan.position_z_count = @max(scan.position_z_count, value_count);
    }
}

fn applyCustomDataPayload(scan: *Scan, name: []const u8, payload: []const u8) void {
    applyCustomDataCount(scan, name, payload.len);
    const range = firstLastF64Le(payload) orelse return;
    if (std.mem.startsWith(u8, name, "CustomData|AcqTimesCache")) {
        scan.timestamp_first_seconds = range.first / 1000.0;
        scan.timestamp_last_seconds = range.last / 1000.0;
    }
}

const F64Range = struct {
    first: f64,
    last: f64,
};

fn firstLastF64Le(payload: []const u8) ?F64Range {
    if (payload.len < 8 or payload.len % 8 != 0) return null;
    return .{
        .first = @bitCast(std.mem.readInt(u64, payload[0..8], .little)),
        .last = @bitCast(std.mem.readInt(u64, payload[payload.len - 8 ..][0..8], .little)),
    };
}

fn chunkHeaderName(header: []const u8) ?[]const u8 {
    const bang = std.mem.indexOfScalar(u8, header, '!') orelse return null;
    const name = header[0..bang];
    for (name) |byte| {
        if (byte < 0x20 or byte > 0x7e) return null;
    }
    return name;
}

fn finalizeDimensionOrder(scan: *Scan) void {
    if (scan.dimension_order != null) return;
    if (scan.size_t > 1 and scan.size_z <= 1) {
        scan.dimension_order = "XYCZT";
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
    const d_compression = findUtf16FieldU32Max(data, "dCompressionParam");
    const e_compression = findUtf16FieldU32Max(data, "eCompression");
    if (d_compression != null and (e_compression orelse 0) == 0) {
        scan.lossless_compression = true;
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

fn utf16FieldValueAt(data: []const u8, pos: usize, comptime name: []const u8) ?u32 {
    if (pos + name.len * 2 + 6 > data.len) return null;
    inline for (name, 0..) |c, i| {
        if (data[pos + i * 2] != c or data[pos + i * 2 + 1] != 0) return null;
    }
    const after_name = pos + name.len * 2;
    if (data[after_name] != 0 or data[after_name + 1] != 0) return null;
    return std.mem.readInt(u32, data[after_name + 2 ..][0..4], .little);
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

const ChunkMapRawEntry = struct {
    chunk_offset: u64,
    payload_len: u64,
};

fn chunkMapEntry(allocator: std.mem.Allocator, io: std.Io, path: []const u8, tail: []const u8, plane_index: u32) !ChunkMapEntry {
    if (chunkMapEntryFromFileMap(tail, plane_index)) |entry| {
        return chunkMapEntryFromOffset(allocator, io, path, entry.chunk_offset, entry.payload_len);
    }
    return chunkMapEntryFromTailMarker(allocator, io, path, tail, plane_index);
}

fn chunkMapEntryFromFileMap(tail: []const u8, plane_index: u32) ?ChunkMapRawEntry {
    const signature = "ND2 FILEMAP SIGNATURE NAME 0001!";
    var cursor = (std.mem.lastIndexOf(u8, tail, signature) orelse return null) + signature.len;
    const one_indexed = fileMapImageDataOneIndexed(tail);
    const target_index = if (one_indexed) std.math.add(u32, plane_index, 1) catch return null else plane_index;
    while (cursor + 17 <= tail.len) {
        const bang = findEntryBang(tail, cursor) orelse return null;
        const name = tail[cursor..bang];
        if (std.mem.eql(u8, name, "ND2 CHUNK MAP SIGNATURE 0000001")) return null;
        const value_start = bang + 1;
        if (tail.len - value_start < 16) return null;
        if (imageDataSeqNameMatches(name, target_index)) {
            return .{
                .chunk_offset = std.mem.readInt(u64, tail[value_start..][0..8], .little),
                .payload_len = std.mem.readInt(u64, tail[value_start + 8 ..][0..8], .little),
            };
        }
        cursor = value_start + 16;
    }
    return null;
}

fn chunkMapEntryFromTailMarker(allocator: std.mem.Allocator, io: std.Io, path: []const u8, tail: []const u8, plane_index: u32) !ChunkMapEntry {
    const one_indexed = tailImageDataOneIndexed(tail);
    const target_index = if (one_indexed) std.math.add(u32, plane_index, 1) catch return error.UnsupportedVariant else plane_index;
    const marker = try std.fmt.allocPrint(allocator, "ImageDataSeq|{}!", .{target_index});
    defer allocator.free(marker);
    const pos = std.mem.lastIndexOf(u8, tail, marker) orelse return error.UnsupportedVariant;
    const value_start = pos + marker.len;
    if (tail.len - value_start < 16) return error.TruncatedData;
    const chunk_offset = std.mem.readInt(u64, tail[value_start..][0..8], .little);
    const payload_len = std.mem.readInt(u64, tail[value_start + 8 ..][0..8], .little);
    return chunkMapEntryFromOffset(allocator, io, path, chunk_offset, payload_len);
}

fn chunkMapEntryFromOffset(allocator: std.mem.Allocator, io: std.Io, path: []const u8, chunk_offset: u64, payload_len: u64) !ChunkMapEntry {
    if (chunk_offset > std.math.maxInt(u64) - 16) return error.UnsupportedVariant;
    const header = try readFileRangeAlloc(allocator, io, path, chunk_offset, 16);
    defer allocator.free(header);
    if (header.len != 16 or !hasMagic(header)) return error.InvalidFormat;
    const header_extra = std.mem.readInt(u32, header[4..8], .little);
    const payload_offset = std.math.add(u64, chunk_offset + 24, header_extra) catch return error.UnsupportedVariant;
    return .{ .payload_offset = payload_offset, .payload_len = payload_len };
}

fn findEntryBang(data: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos < data.len and pos - start <= 256) : (pos += 1) {
        const byte = data[pos];
        if (byte == '!') return pos;
        if (byte < 0x20 or byte > 0x7e) return null;
    }
    return null;
}

fn fileMapImageDataOneIndexed(tail: []const u8) bool {
    const signature = "ND2 FILEMAP SIGNATURE NAME 0001!";
    var cursor = (std.mem.lastIndexOf(u8, tail, signature) orelse return false) + signature.len;
    while (cursor + 17 <= tail.len) {
        const bang = findEntryBang(tail, cursor) orelse return false;
        const name = tail[cursor..bang];
        if (std.mem.eql(u8, name, "ND2 CHUNK MAP SIGNATURE 0000001")) return false;
        if (imageDataSeqIndex(name)) |index| return index == 1;
        cursor = bang + 1 + 16;
    }
    return false;
}

fn tailImageDataOneIndexed(tail: []const u8) bool {
    const zero = "ImageDataSeq|0!";
    if (std.mem.indexOf(u8, tail, zero) != null) return false;
    const marker = "ImageDataSeq|";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, tail, pos, marker)) |found| {
        const bang = std.mem.indexOfScalarPos(u8, tail, found + marker.len, '!') orelse return false;
        if (std.fmt.parseUnsigned(u32, tail[found + marker.len .. bang], 10) catch null) |index| return index == 1;
        pos = bang + 1;
    }
    return false;
}

fn imageDataSeqNameMatches(name: []const u8, plane_index: u32) bool {
    const value = imageDataSeqIndex(name) orelse return false;
    return value == plane_index;
}

fn imageDataSeqIndex(name: []const u8) ?u32 {
    const prefix = "ImageDataSeq|";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const digits = name[prefix.len..];
    if (digits.len == 0) return null;
    return std.fmt.parseUnsigned(u32, digits, 10) catch null;
}

fn seriesPlaneToImageIndex(scan: Scan, metadata: bio.Metadata, series_index: u32, plane_index: u32) ?u32 {
    if (series_index >= metadata.series_count or plane_index >= metadata.plane_count) return null;
    if (scan.loop_order_len == 0) {
        return std.math.add(u32, std.math.mul(u32, series_index, metadata.plane_count) catch return null, plane_index) catch null;
    }

    const total = std.math.mul(u32, metadata.series_count, metadata.plane_count) catch return null;
    var image_index: u32 = 0;
    while (image_index < total) : (image_index += 1) {
        const mapped = imageIndexToSeriesPlane(scan, metadata, image_index) orelse continue;
        if (mapped.series_index == series_index and mapped.plane_index == plane_index) return image_index;
    }
    return null;
}

const SeriesPlane = struct {
    series_index: u32,
    plane_index: u32,
};

fn imageIndexToSeriesPlane(scan: Scan, metadata: bio.Metadata, image_index: u32) ?SeriesPlane {
    var lengths = [_]u32{ 1, 1, 1, 1 };
    var field_index: usize = 3;
    var pos_i: usize = 1;
    for (scan.loop_order[0..scan.loop_order_len]) |axis| {
        switch (axis) {
            'Z' => lengths[pos_i] = metadata.size_z,
            'T' => lengths[pos_i] = metadata.size_t,
            'M' => {
                field_index = pos_i;
                lengths[pos_i] = metadata.series_count;
            },
            else => {},
        }
        pos_i += 1;
        if (pos_i >= lengths.len) break;
    }

    var pos = rasterToPosition(lengths, image_index);
    if (pos[field_index] >= metadata.series_count) return null;
    const series_index = pos[field_index];
    pos[field_index] = 0;
    lengths[field_index] = 1;
    const plane_index = positionToRaster(lengths, pos) orelse return null;
    if (plane_index >= metadata.plane_count) return null;
    return .{ .series_index = series_index, .plane_index = plane_index };
}

fn rasterToPosition(lengths: [4]u32, raster_value: u32) [4]u32 {
    var raster = raster_value;
    var offset: u32 = 1;
    var pos = [_]u32{ 0, 0, 0, 0 };
    for (&pos, 0..) |*value, i| {
        const offset1 = std.math.mul(u32, offset, lengths[i]) catch std.math.maxInt(u32);
        const q = if (i < pos.len - 1 and offset1 != 0) raster % offset1 else raster;
        value.* = if (offset != 0) q / offset else 0;
        raster -|= q;
        offset = offset1;
    }
    return pos;
}

fn positionToRaster(lengths: [4]u32, pos: [4]u32) ?u32 {
    var offset: u32 = 1;
    var raster: u32 = 0;
    for (pos, 0..) |value, i| {
        if (value >= lengths[i]) return null;
        raster = std.math.add(u32, raster, std.math.mul(u32, offset, value) catch return null) catch return null;
        offset = std.math.mul(u32, offset, lengths[i]) catch return null;
    }
    return raster;
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

fn checkedUsize(value: u64) bio.ReaderError!usize {
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
}

fn readZlibCompressedPlane(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    metadata: bio.Metadata,
    region: bio.Region,
) bio.ReaderError![]u8 {
    const decoded_len = try storedPlaneByteCount(metadata, std.math.maxInt(u64));
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    var input: std.Io.Reader = .fixed(compressed);
    var output: std.Io.Writer = .fixed(decoded);
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    const written = decompress.reader.streamRemaining(&output) catch return error.TruncatedData;
    const stored = decoded[0..written];
    const plane_data = try compactStoredPlane(allocator, stored, metadata, region);
    allocator.free(decoded);
    return plane_data;
}

fn compactStoredPlane(
    allocator: std.mem.Allocator,
    stored: []const u8,
    metadata: bio.Metadata,
    region: bio.Region,
) bio.ReaderError![]u8 {
    const plane_len = try planeByteCount(metadata);
    const layout = try planeStorageLayout(metadata);
    if (stored.len < plane_len) return error.TruncatedData;
    if (layout.padded_len <= stored.len and layout.padded_row_bytes != layout.row_bytes) {
        const compact = try allocator.alloc(u8, plane_len);
        errdefer allocator.free(compact);
        var row: usize = 0;
        while (row < metadata.height) : (row += 1) {
            @memcpy(compact[row * layout.row_bytes ..][0..layout.row_bytes], stored[row * layout.padded_row_bytes ..][0..layout.row_bytes]);
        }
        if (region.isFull(metadata)) return compact;
        defer allocator.free(compact);
        return try bio.cropPlane(allocator, .{ .metadata = metadata, .data = compact }, region);
    }
    if (region.isFull(metadata)) return try allocator.dupe(u8, stored[0..plane_len]);
    const compact = try allocator.dupe(u8, stored[0..plane_len]);
    defer allocator.free(compact);
    return try bio.cropPlane(allocator, .{ .metadata = metadata, .data = compact }, region);
}

const PlaneStorageLayout = struct {
    row_bytes: usize,
    padded_row_bytes: usize,
    padded_len: usize,
};

fn planeStorageLayout(metadata: bio.Metadata) bio.ReaderError!PlaneStorageLayout {
    const row_bytes = std.math.mul(usize, metadata.width, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
    const padded_row_bytes = std.mem.alignForward(usize, row_bytes, 4);
    const padded_len = std.math.mul(usize, padded_row_bytes, metadata.height) catch return error.UnsupportedVariant;
    return .{ .row_bytes = row_bytes, .padded_row_bytes = padded_row_bytes, .padded_len = padded_len };
}

fn storedPlaneByteCount(metadata: bio.Metadata, available: u64) bio.ReaderError!usize {
    const plane_len = try planeByteCount(metadata);
    const layout = try planeStorageLayout(metadata);
    if (layout.padded_row_bytes != layout.row_bytes and available >= layout.padded_len) return layout.padded_len;
    return plane_len;
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

fn appendF64Le(list: *std.ArrayList(u8), value: f64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @bitCast(value), .little);
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
    try appendU64Le(list, 0);
    try list.appendSlice(std.testing.allocator, payload);
    return offset;
}

fn appendMetadataChunk(list: *std.ArrayList(u8), name: []const u8, payload: []const u8) !u64 {
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

fn appendFileMapEntry(list: *std.ArrayList(u8), name: []const u8, chunk_offset: u64, payload_len: u64) !void {
    try list.appendSlice(std.testing.allocator, name);
    try list.append(std.testing.allocator, '!');
    try appendU64Le(list, chunk_offset);
    try appendU64Le(list, payload_len);
}

fn expectApprox(actual: f64, expected: f64) !void {
    try std.testing.expect(@abs(actual - expected) <= 0.0000001);
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

test "rejects non-nd2 magic" {
    try std.testing.expect(!matches("not nd2"));
    try std.testing.expect(!matches(&.{ 0, 1, 2, 3, 4, 5, 6, 7 }));
    try std.testing.expectError(error.InvalidFormat, readMetadata(&.{ 0, 1, 2, 3, 4, 5, 6, 7 }));
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
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
}

test "reads nd2 TimeLoop order from experiment xml" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, &.{ 0xda, 0xce, 0xbe, 0x0a, 0, 0, 0, 0 });
    try data.appendSlice(std.testing.allocator,
        \\<uiWidth runtype="lx_uint32" value="800"/>
        \\<uiHeight runtype="lx_uint32" value="600"/>
        \\<uiComp runtype="lx_uint32" value="1"/>
        \\<uiBpcInMemory runtype="lx_uint32" value="16"/>
        \\<no_name runtype="RLxExperiment.RLxExpTimeLoop">
        \\  <uiCount runtype="lx_uint32" value="13"/>
        \\</no_name>
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u16, 13), metadata.size_t);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 13), metadata.plane_count);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
}

test "reads nd2 XY position series count from experiment xml" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, &.{ 0xda, 0xce, 0xbe, 0x0a, 0, 0, 0, 0 });
    try data.appendSlice(std.testing.allocator,
        \\<uiWidth runtype="lx_uint32" value="800"/>
        \\<uiHeight runtype="lx_uint32" value="600"/>
        \\<uiComp runtype="lx_uint32" value="1"/>
        \\<uiBpcInMemory runtype="lx_uint32" value="16"/>
        \\<no_name runtype="RLxExperiment.RLxExpXYPosLoop">
        \\  <uiCount runtype="lx_uint32" value="3"/>
        \\</no_name>
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 3), metadata.series_count);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
}

test "reads nd2 SLxExperiment loop count from light-variant fields" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, &.{ 0xda, 0xce, 0xbe, 0x0a, 0, 0, 0, 0 });
    try appendAttributeField(&data, "uiWidth", 4);
    try appendAttributeField(&data, "uiHeight", 3);
    try appendAttributeField(&data, "uiComp", 1);
    try appendAttributeField(&data, "uiBpcInMemory", 16);
    try appendAttributeField(&data, "SLxExperiment", 0);
    try appendAttributeField(&data, "eType", 1);
    try appendAttributeField(&data, "uiCount", 7);
    try appendAttributeField(&data, "uiNextLevelCount", 0);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u16, 7), metadata.size_t);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 7), metadata.plane_count);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
}

test "reads nd2 SLxExperiment XY position series count" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, &.{ 0xda, 0xce, 0xbe, 0x0a, 0, 0, 0, 0 });
    try appendAttributeField(&data, "uiWidth", 4);
    try appendAttributeField(&data, "uiHeight", 3);
    try appendAttributeField(&data, "uiComp", 1);
    try appendAttributeField(&data, "uiBpcInMemory", 16);
    try appendAttributeField(&data, "SLxExperiment", 0);
    try appendAttributeField(&data, "eType", 2);
    try appendAttributeField(&data, "uiCount", 4);
    try appendAttributeField(&data, "uiNextLevelCount", 0);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 4), metadata.series_count);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
}

test "uses AcqTimesCache count as nd2 time fallback" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    var attributes: std.ArrayList(u8) = .empty;
    defer attributes.deinit(std.testing.allocator);

    try appendAttributeField(&attributes, "uiWidth", 4);
    try appendAttributeField(&attributes, "uiHeight", 3);
    try appendAttributeField(&attributes, "uiComp", 1);
    try appendAttributeField(&attributes, "uiBpcInMemory", 16);

    _ = try appendChunk(&data, "ND2 FILE SIGNATURE CHUNK NAME01!", "Ver3.0");
    _ = try appendChunk(&data, "ImageAttributesLV!", attributes.items);
    var acq_times: std.ArrayList(u8) = .empty;
    defer acq_times.deinit(std.testing.allocator);
    inline for (.{ 1000.0, 2000.0, 3000.0, 4000.0, 5000.0 }) |value| {
        try appendF64Le(&acq_times, value);
    }
    _ = try appendMetadataChunk(&data, "CustomData|AcqTimesCache!", acq_times.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u16, 5), metadata.size_t);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 5), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 5), metadata.timestamp_count);
    try expectApprox(metadata.timestamp_first_seconds.?, 1.0);
    try expectApprox(metadata.timestamp_last_seconds.?, 5.0);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
}

test "counts nd2 CustomData position arrays" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    var attributes: std.ArrayList(u8) = .empty;
    defer attributes.deinit(std.testing.allocator);

    try appendAttributeField(&attributes, "uiWidth", 4);
    try appendAttributeField(&attributes, "uiHeight", 3);
    try appendAttributeField(&attributes, "uiComp", 1);
    try appendAttributeField(&attributes, "uiBpcInMemory", 16);

    _ = try appendChunk(&data, "ND2 FILE SIGNATURE CHUNK NAME01!", "Ver3.0");
    _ = try appendChunk(&data, "ImageAttributesLV!", attributes.items);
    var x_payload: std.ArrayList(u8) = .empty;
    defer x_payload.deinit(std.testing.allocator);
    inline for (.{ 1.0, 2.0, 3.0 }) |value| try appendF64Le(&x_payload, value);
    var y_payload: std.ArrayList(u8) = .empty;
    defer y_payload.deinit(std.testing.allocator);
    inline for (.{ 4.0, 5.0, 6.0, 7.0 }) |value| try appendF64Le(&y_payload, value);
    var z_payload: std.ArrayList(u8) = .empty;
    defer z_payload.deinit(std.testing.allocator);
    inline for (.{ 8.0, 9.0, 10.0, 11.0, 12.0 }) |value| try appendF64Le(&z_payload, value);
    var z1_payload: std.ArrayList(u8) = .empty;
    defer z1_payload.deinit(std.testing.allocator);
    inline for (.{ 13.0, 14.0, 15.0, 16.0, 17.0, 18.0 }) |value| try appendF64Le(&z1_payload, value);

    _ = try appendMetadataChunk(&data, "CustomData|X!", x_payload.items);
    _ = try appendMetadataChunk(&data, "CustomData|Y!", y_payload.items);
    _ = try appendMetadataChunk(&data, "CustomData|Z!", z_payload.items);
    _ = try appendMetadataChunk(&data, "CustomData|Z1!", z1_payload.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 3), metadata.position_x_count);
    try std.testing.expectEqual(@as(u32, 4), metadata.position_y_count);
    try std.testing.expectEqual(@as(u32, 5), metadata.position_z_count);
    try std.testing.expectEqual(@as(u32, 6), metadata.position_z1_count);
}

test "counts nd2 CustomData arrays from path file map when chunk is outside tail" {
    const file_path = "nd2-custom-data-file-map-test.nd2";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var file_bytes: std.ArrayList(u8) = .empty;
    defer file_bytes.deinit(std.testing.allocator);
    var attributes: std.ArrayList(u8) = .empty;
    defer attributes.deinit(std.testing.allocator);

    const x_payload = [_]u8{0} ** (3 * 8);
    const x_offset = try appendMetadataChunk(&file_bytes, "CustomData|X!", &x_payload);
    try file_bytes.appendNTimes(std.testing.allocator, 0, max_tail_bytes + 1024);

    try appendAttributeField(&attributes, "uiWidth", 4);
    try appendAttributeField(&attributes, "uiHeight", 3);
    try appendAttributeField(&attributes, "uiComp", 1);
    try appendAttributeField(&attributes, "uiBpcInMemory", 16);
    _ = try appendChunk(&file_bytes, "ImageAttributesLV!", attributes.items);

    try file_bytes.appendSlice(std.testing.allocator, "ND2 FILEMAP SIGNATURE NAME 0001!");
    try appendFileMapEntry(&file_bytes, "CustomData|X", x_offset, x_payload.len);
    try appendFileMapEntry(&file_bytes, "ND2 CHUNK MAP SIGNATURE 0000001", 0, 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = file_bytes.items });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    try std.testing.expectEqual(@as(u32, 3), metadata.position_x_count);
}

test "reads nd2 plane count derived from path file map CustomData" {
    const file_path = "nd2-file-map-custom-data-plane-count-test.nd2";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var file_bytes: std.ArrayList(u8) = .empty;
    defer file_bytes.deinit(std.testing.allocator);
    var attributes: std.ArrayList(u8) = .empty;
    defer attributes.deinit(std.testing.allocator);
    var times: std.ArrayList(u8) = .empty;
    defer times.deinit(std.testing.allocator);

    try appendF64Le(&times, 1000.0);
    try appendF64Le(&times, 2000.0);
    try appendF64Le(&times, 3000.0);
    const times_offset = try appendMetadataChunk(&file_bytes, "CustomData|AcqTimesCache!", times.items);
    try file_bytes.appendNTimes(std.testing.allocator, 0, max_tail_bytes + 1024);

    try appendAttributeField(&attributes, "uiWidth", 1);
    try appendAttributeField(&attributes, "uiHeight", 1);
    try appendAttributeField(&attributes, "uiComp", 1);
    try appendAttributeField(&attributes, "uiBpcInMemory", 16);
    _ = try appendChunk(&file_bytes, "ImageAttributesLV!", attributes.items);

    const pixels0 = [_]u8{ 1, 0 };
    const pixels1 = [_]u8{ 2, 0 };
    const pixels2 = [_]u8{ 3, 0 };
    const image0_offset = try appendChunk(&file_bytes, "ImageDataSeq|0!", &pixels0);
    const image1_offset = try appendChunk(&file_bytes, "ImageDataSeq|1!", &pixels1);
    const image2_offset = try appendChunk(&file_bytes, "ImageDataSeq|2!", &pixels2);

    try file_bytes.appendSlice(std.testing.allocator, "ND2 FILEMAP SIGNATURE NAME 0001!");
    try appendFileMapEntry(&file_bytes, "CustomData|AcqTimesCache", times_offset, times.items.len);
    try appendFileMapEntry(&file_bytes, "ImageDataSeq|0", image0_offset, pixels0.len);
    try appendFileMapEntry(&file_bytes, "ImageDataSeq|1", image1_offset, pixels1.len);
    try appendFileMapEntry(&file_bytes, "ImageDataSeq|2", image2_offset, pixels2.len);
    try appendFileMapEntry(&file_bytes, "ND2 CHUNK MAP SIGNATURE 0000001", 0, 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = file_bytes.items });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 3), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 3), metadata.timestamp_count);
    try expectApprox(metadata.timestamp_first_seconds.?, 1.0);
    try expectApprox(metadata.timestamp_last_seconds.?, 3.0);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 2, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &pixels2, plane.data);
}

test "matches Bio-Formats core metadata for cached ND2 fixture" {
    const file_path = "fixtures/cache/nd2/MeOh_high_fluo_003.nd2";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    try std.testing.expectEqualStrings("nd2", metadata.format);
    try std.testing.expectEqual(@as(u32, 800), metadata.width);
    try std.testing.expectEqual(@as(u32, 600), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 13), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 13), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 1), metadata.series_count);
    try std.testing.expectEqual(@as(u32, 13), metadata.timestamp_count);
    try std.testing.expectEqual(@as(u32, 13), metadata.position_z_count);
    try expectApprox(metadata.timestamp_first_seconds.?, 3.6640321512930094);
    try expectApprox(metadata.timestamp_last_seconds.?, 120.2203556247633);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
}

test "matches Bio-Formats pixel samples for cached ND2 fixture" {
    const file_path = "fixtures/cache/nd2/MeOh_high_fluo_003.nd2";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const expected = [_]struct { plane: u32, bytes: []const u8 }{
        .{ .plane = 0, .bytes = &.{ 0x23, 0x00 } },
        .{ .plane = 6, .bytes = &.{ 0x00, 0x00 } },
        .{ .plane = 12, .bytes = &.{ 0x14, 0x00 } },
    };
    for (expected) |sample| {
        const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, sample.plane, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqualSlices(u8, sample.bytes, plane.data);
    }
}

test "matches Bio-Formats full-plane hashes for cached ND2 fixture" {
    const file_path = "fixtures/cache/nd2/MeOh_high_fluo_003.nd2";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const expected = [_]struct { plane: u32, sha256: [32]u8 }{
        .{ .plane = 0, .sha256 = .{ 0x76, 0xa8, 0xc9, 0xd0, 0x91, 0x90, 0xf4, 0xbb, 0xd0, 0xf0, 0x1a, 0xc6, 0xd5, 0x21, 0x0b, 0xe9, 0x19, 0xc5, 0x1c, 0x31, 0x49, 0x0b, 0x5e, 0x36, 0x5f, 0x63, 0xf1, 0x3b, 0x21, 0x72, 0xad, 0xa8 } },
        .{ .plane = 6, .sha256 = .{ 0x4e, 0x7d, 0x8e, 0xa7, 0x33, 0x5a, 0xa7, 0x9c, 0x5a, 0x02, 0x43, 0xd4, 0x80, 0xa1, 0x50, 0xae, 0x21, 0xf1, 0x67, 0x9a, 0xe5, 0xe3, 0x5d, 0x3b, 0xc7, 0x8e, 0x6c, 0x1c, 0x76, 0x3b, 0xa1, 0xa7 } },
        .{ .plane = 12, .sha256 = .{ 0x4b, 0x0d, 0x51, 0xfb, 0x61, 0x32, 0x2e, 0x25, 0x1f, 0xd3, 0xf7, 0xd9, 0x84, 0xb3, 0x76, 0xff, 0x25, 0xe5, 0x26, 0x93, 0x46, 0xd1, 0x06, 0x6b, 0xc8, 0x98, 0xb0, 0x56, 0x39, 0x40, 0x8b, 0x38 } },
    };
    for (expected) |sample| {
        const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, sample.plane, .{ .x = 0, .y = 0, .width = 800, .height = 600 });
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqual(@as(usize, 960000), plane.data.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
        try std.testing.expectEqualSlices(u8, &sample.sha256, &digest);
    }
}

test "nd2 fixture region read matches full-plane crop" {
    const file_path = "fixtures/cache/nd2/MeOh_high_fluo_003.nd2";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const region = bio.Region{ .x = 3, .y = 2, .width = 4, .height = 3 };
    const full = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 6, .{ .x = 0, .y = 0, .width = 800, .height = 600 });
    defer std.testing.allocator.free(full.data);
    const cropped = try bio.cropPlane(std.testing.allocator, full, region);
    defer std.testing.allocator.free(cropped);

    const direct = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 6, region);
    defer std.testing.allocator.free(direct.data);
    try std.testing.expectEqualSlices(u8, cropped, direct.data);
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
        1,  0, 2,  0, 3,  0,
        4,  0, 5,  0, 6,  0,
        7,  0, 8,  0, 9,  0,
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
    try std.testing.expectEqual(@as(u32, 1), metadata.series_count);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 1, .y = 0, .width = 1, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 4, 0, 5, 0, 6, 0, 10, 0, 11, 0, 12, 0 }, plane.data);
}

test "reads zlib lossless nd2 pixels from chunk map" {
    const file_path = "nd2-zlib-lossless-chunk-map-test.nd2";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var file_bytes: std.ArrayList(u8) = .empty;
    defer file_bytes.deinit(std.testing.allocator);
    var attributes: std.ArrayList(u8) = .empty;
    defer attributes.deinit(std.testing.allocator);

    try appendAttributeField(&attributes, "uiWidth", 2);
    try appendAttributeField(&attributes, "uiHeight", 2);
    try appendAttributeField(&attributes, "uiComp", 1);
    try appendAttributeField(&attributes, "uiBpcInMemory", 8);
    try appendAttributeField(&attributes, "dCompressionParam", 0);
    try appendAttributeField(&attributes, "eCompression", 0);

    _ = try appendChunk(&file_bytes, "ND2 FILE SIGNATURE CHUNK NAME01!", "Ver3.0");
    _ = try appendChunk(&file_bytes, "ImageAttributesLV!", attributes.items);
    const compressed = [_]u8{ 0x78, 0x9c, 0x01, 0x04, 0x00, 0xfb, 0xff, 1, 2, 3, 4, 0x00, 0x18, 0x00, 0x0b };
    const image_offset = try appendChunk(&file_bytes, "ImageDataSeq|0!", &compressed);
    try file_bytes.appendSlice(std.testing.allocator, "ND2 FILEMAP SIGNATURE NAME 0001!");
    try appendFileMapEntry(&file_bytes, "ImageDataSeq|0", image_offset, compressed.len);
    try appendFileMapEntry(&file_bytes, "ND2 CHUNK MAP SIGNATURE 0000001", 0, 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = file_bytes.items });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 1, .y = 0, .width = 1, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 2, 4 }, plane.data);
}

test "reads nd2 raw chunk with padded scanlines" {
    const file_path = "nd2-raw-padded-scanlines-test.nd2";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var file_bytes: std.ArrayList(u8) = .empty;
    defer file_bytes.deinit(std.testing.allocator);
    var attributes: std.ArrayList(u8) = .empty;
    defer attributes.deinit(std.testing.allocator);

    try appendAttributeField(&attributes, "uiWidth", 3);
    try appendAttributeField(&attributes, "uiHeight", 2);
    try appendAttributeField(&attributes, "uiComp", 1);
    try appendAttributeField(&attributes, "uiBpcInMemory", 8);

    _ = try appendChunk(&file_bytes, "ND2 FILE SIGNATURE CHUNK NAME01!", "Ver3.0");
    _ = try appendChunk(&file_bytes, "ImageAttributesLV!", attributes.items);
    const stored = [_]u8{ 1, 2, 3, 0, 4, 5, 6, 0 };
    const image_offset = try appendChunk(&file_bytes, "ImageDataSeq|0!", &stored);
    try file_bytes.appendSlice(std.testing.allocator, "ND2 FILEMAP SIGNATURE NAME 0001!");
    try appendFileMapEntry(&file_bytes, "ImageDataSeq|0", image_offset, stored.len);
    try appendFileMapEntry(&file_bytes, "ND2 CHUNK MAP SIGNATURE 0000001", 0, 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = file_bytes.items });

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 2, .y = 0, .width = 1, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 6 }, plane.data);
}

test "reads zlib lossless nd2 chunk with padded scanlines" {
    const file_path = "nd2-zlib-padded-scanlines-test.nd2";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var file_bytes: std.ArrayList(u8) = .empty;
    defer file_bytes.deinit(std.testing.allocator);
    var attributes: std.ArrayList(u8) = .empty;
    defer attributes.deinit(std.testing.allocator);

    try appendAttributeField(&attributes, "uiWidth", 3);
    try appendAttributeField(&attributes, "uiHeight", 2);
    try appendAttributeField(&attributes, "uiComp", 1);
    try appendAttributeField(&attributes, "uiBpcInMemory", 8);
    try appendAttributeField(&attributes, "dCompressionParam", 0);
    try appendAttributeField(&attributes, "eCompression", 0);

    _ = try appendChunk(&file_bytes, "ND2 FILE SIGNATURE CHUNK NAME01!", "Ver3.0");
    _ = try appendChunk(&file_bytes, "ImageAttributesLV!", attributes.items);
    const compressed = [_]u8{ 0x78, 0x9c, 0x01, 0x08, 0x00, 0xf7, 0xff, 1, 2, 3, 0, 4, 5, 6, 0, 0x00, 0x5b, 0x00, 0x16 };
    const image_offset = try appendChunk(&file_bytes, "ImageDataSeq|0!", &compressed);
    try file_bytes.appendSlice(std.testing.allocator, "ND2 FILEMAP SIGNATURE NAME 0001!");
    try appendFileMapEntry(&file_bytes, "ImageDataSeq|0", image_offset, compressed.len);
    try appendFileMapEntry(&file_bytes, "ND2 CHUNK MAP SIGNATURE 0000001", 0, 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = file_bytes.items });

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 2, .y = 0, .width = 1, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 6 }, plane.data);
}

test "reads nd2 pixels from typed file map before later decoy markers" {
    const file_path = "nd2-typed-file-map-test.nd2";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var file_bytes: std.ArrayList(u8) = .empty;
    defer file_bytes.deinit(std.testing.allocator);
    var attributes: std.ArrayList(u8) = .empty;
    defer attributes.deinit(std.testing.allocator);

    try appendAttributeField(&attributes, "uiWidth", 1);
    try appendAttributeField(&attributes, "uiHeight", 1);
    try appendAttributeField(&attributes, "uiComp", 1);
    try appendAttributeField(&attributes, "uiBpcInMemory", 16);

    _ = try appendChunk(&file_bytes, "ND2 FILE SIGNATURE CHUNK NAME01!", "Ver3.0");
    _ = try appendChunk(&file_bytes, "ImageAttributesLV!", attributes.items);
    try file_bytes.appendSlice(std.testing.allocator, "SizeZ=2");

    const pixels0 = [_]u8{ 1, 0 };
    const pixels1 = [_]u8{ 9, 0 };
    const image0_offset = try appendChunk(&file_bytes, "ImageDataSeq|0!", &pixels0);
    const image1_offset = try appendChunk(&file_bytes, "ImageDataSeq|1!", &pixels1);

    try file_bytes.appendSlice(std.testing.allocator, "ND2 FILEMAP SIGNATURE NAME 0001!");
    try appendFileMapEntry(&file_bytes, "ImageDataSeq|0", image0_offset, pixels0.len);
    try appendFileMapEntry(&file_bytes, "ImageDataSeq|1", image1_offset, pixels1.len);
    try appendFileMapEntry(&file_bytes, "ND2 CHUNK MAP SIGNATURE 0000001", 0, 0);
    try file_bytes.appendSlice(std.testing.allocator, "ImageDataSeq|1!");
    try appendU64Le(&file_bytes, 0xffff_ffff_ffff_fff0);
    try appendU64Le(&file_bytes, 2);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = file_bytes.items });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 1, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &pixels1, plane.data);
}

test "reads one-indexed nd2 ImageDataSeq file map like Bio-Formats" {
    const file_path = "nd2-one-indexed-file-map-test.nd2";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var file_bytes: std.ArrayList(u8) = .empty;
    defer file_bytes.deinit(std.testing.allocator);
    var attributes: std.ArrayList(u8) = .empty;
    defer attributes.deinit(std.testing.allocator);

    try appendAttributeField(&attributes, "uiWidth", 1);
    try appendAttributeField(&attributes, "uiHeight", 1);
    try appendAttributeField(&attributes, "uiComp", 1);
    try appendAttributeField(&attributes, "uiBpcInMemory", 16);

    _ = try appendChunk(&file_bytes, "ND2 FILE SIGNATURE CHUNK NAME01!", "Ver3.0");
    _ = try appendChunk(&file_bytes, "ImageAttributesLV!", attributes.items);
    try file_bytes.appendSlice(std.testing.allocator, "SizeZ=2");

    const pixels0 = [_]u8{ 3, 0 };
    const pixels1 = [_]u8{ 7, 0 };
    const image0_offset = try appendChunk(&file_bytes, "ImageDataSeq|1!", &pixels0);
    const image1_offset = try appendChunk(&file_bytes, "ImageDataSeq|2!", &pixels1);

    try file_bytes.appendSlice(std.testing.allocator, "ND2 FILEMAP SIGNATURE NAME 0001!");
    try appendFileMapEntry(&file_bytes, "ImageDataSeq|1", image0_offset, pixels0.len);
    try appendFileMapEntry(&file_bytes, "ImageDataSeq|2", image1_offset, pixels1.len);
    try appendFileMapEntry(&file_bytes, "ND2 CHUNK MAP SIGNATURE 0000001", 0, 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = file_bytes.items });

    const plane0 = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane0.data);
    try std.testing.expectEqualSlices(u8, &pixels0, plane0.data);

    const plane1 = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 1, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane1.data);
    try std.testing.expectEqualSlices(u8, &pixels1, plane1.data);
}

test "reads nd2 series plane using SLxExperiment raster mapping" {
    const file_path = "nd2-series-raster-map-test.nd2";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var file_bytes: std.ArrayList(u8) = .empty;
    defer file_bytes.deinit(std.testing.allocator);
    var attributes: std.ArrayList(u8) = .empty;
    defer attributes.deinit(std.testing.allocator);

    try appendAttributeField(&attributes, "uiWidth", 1);
    try appendAttributeField(&attributes, "uiHeight", 1);
    try appendAttributeField(&attributes, "uiComp", 1);
    try appendAttributeField(&attributes, "uiBpcInMemory", 16);
    try appendAttributeField(&attributes, "SLxExperiment", 0);
    try appendAttributeField(&attributes, "eType", 1);
    try appendAttributeField(&attributes, "uiCount", 3);
    try appendAttributeField(&attributes, "uiNextLevelCount", 1);
    try appendAttributeField(&attributes, "eType", 2);
    try appendAttributeField(&attributes, "uiCount", 2);
    try appendAttributeField(&attributes, "uiNextLevelCount", 0);

    _ = try appendChunk(&file_bytes, "ND2 FILE SIGNATURE CHUNK NAME01!", "Ver3.0");
    _ = try appendChunk(&file_bytes, "ImageAttributesLV!", attributes.items);

    var offsets: [6]u64 = undefined;
    var pixels: [6][2]u8 = undefined;
    for (&pixels, 0..) |*pixel, i| {
        pixel.* = .{ @intCast(i + 1), 0 };
        const name = try std.fmt.allocPrint(std.testing.allocator, "ImageDataSeq|{}!", .{i});
        defer std.testing.allocator.free(name);
        offsets[i] = try appendChunk(&file_bytes, name, pixel);
    }

    try file_bytes.appendSlice(std.testing.allocator, "ND2 FILEMAP SIGNATURE NAME 0001!");
    for (offsets, pixels, 0..) |offset, pixel, i| {
        const name = try std.fmt.allocPrint(std.testing.allocator, "ImageDataSeq|{}", .{i});
        defer std.testing.allocator.free(name);
        try appendFileMapEntry(&file_bytes, name, offset, pixel.len);
    }
    try appendFileMapEntry(&file_bytes, "ND2 CHUNK MAP SIGNATURE 0000001", 0, 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = file_bytes.items });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 2), metadata.series_count);
    try std.testing.expectEqual(@as(u32, 3), metadata.plane_count);

    const plane = try readPlanePathRegionSeriesIndex(std.testing.allocator, std.testing.io, file_path, 1, 2, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &pixels[5], plane.data);
}

test "reads nd2 Z/T/position planes using ImageMetadataLV raster mapping" {
    const file_path = "nd2-z-t-position-raster-map-test.nd2";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var file_bytes: std.ArrayList(u8) = .empty;
    defer file_bytes.deinit(std.testing.allocator);
    var attributes: std.ArrayList(u8) = .empty;
    defer attributes.deinit(std.testing.allocator);

    try appendAttributeField(&attributes, "uiWidth", 1);
    try appendAttributeField(&attributes, "uiHeight", 1);
    try appendAttributeField(&attributes, "uiComp", 1);
    try appendAttributeField(&attributes, "uiBpcInMemory", 16);
    try appendAttributeField(&attributes, "SLxExperiment", 0);
    try appendAttributeField(&attributes, "eType", 4);
    try appendAttributeField(&attributes, "uiCount", 2);
    try appendAttributeField(&attributes, "uiNextLevelCount", 1);
    try appendAttributeField(&attributes, "eType", 1);
    try appendAttributeField(&attributes, "uiCount", 3);
    try appendAttributeField(&attributes, "uiNextLevelCount", 1);
    try appendAttributeField(&attributes, "eType", 2);
    try appendAttributeField(&attributes, "uiCount", 2);
    try appendAttributeField(&attributes, "uiNextLevelCount", 0);

    _ = try appendChunk(&file_bytes, "ND2 FILE SIGNATURE CHUNK NAME01!", "Ver3.0");
    _ = try appendChunk(&file_bytes, "ImageMetadataLV!", attributes.items);

    var offsets: [12]u64 = undefined;
    var pixels: [12][2]u8 = undefined;
    for (&pixels, 0..) |*pixel, i| {
        pixel.* = .{ @intCast(i + 1), 0 };
        const name = try std.fmt.allocPrint(std.testing.allocator, "ImageDataSeq|{}!", .{i});
        defer std.testing.allocator.free(name);
        offsets[i] = try appendChunk(&file_bytes, name, pixel);
    }

    try file_bytes.appendSlice(std.testing.allocator, "ND2 FILEMAP SIGNATURE NAME 0001!");
    for (offsets, pixels, 0..) |offset, pixel, i| {
        const name = try std.fmt.allocPrint(std.testing.allocator, "ImageDataSeq|{}", .{i});
        defer std.testing.allocator.free(name);
        try appendFileMapEntry(&file_bytes, name, offset, pixel.len);
    }
    try appendFileMapEntry(&file_bytes, "ND2 CHUNK MAP SIGNATURE 0000001", 0, 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = file_bytes.items });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 2), metadata.series_count);
    try std.testing.expectEqual(@as(u32, 6), metadata.plane_count);

    const plane = try readPlanePathRegionSeriesIndex(std.testing.allocator, std.testing.io, file_path, 1, 5, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &pixels[11], plane.data);
}
