const std = @import("std");
const bio = @import("../root.zig");

const end_marker = "{END}";

const Header = struct {
    width: u32,
    height: u32,
    size_z: u16,
    size_c: u16,
    size_t: u16,
    pixel_type: bio.PixelType,
    data_offset: usize,
    gzip: bool,
    packed_12: bool,
    msb_packing: bool,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    const plane_count = std.math.mul(u32, header.size_z, header.size_t) catch return error.UnsupportedVariant;
    return .{
        .format = "liflim",
        .width = header.width,
        .height = header.height,
        .size_c = header.size_c,
        .samples_per_pixel = header.size_c,
        .size_z = header.size_z,
        .size_t = header.size_t,
        .pixel_type = header.pixel_type,
        .little_endian = true,
        .plane_count = plane_count,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const header = try parseHeader(data);
    const plane_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    if (header.gzip) {
        const total = std.math.mul(usize, plane_len, metadata.plane_count) catch return error.UnsupportedVariant;
        const decoded = try allocator.alloc(u8, total);
        defer allocator.free(decoded);
        try decodeGzip(data[header.data_offset..], decoded);
        const offset = std.math.mul(usize, plane_index, plane_len) catch return error.InvalidPlaneIndex;
        @memcpy(out, decoded[offset..][0..plane_len]);
    } else if (header.packed_12) {
        const source_len = try packed12ByteCount(plane_len);
        const offset = std.math.add(usize, header.data_offset, std.math.mul(usize, plane_index, source_len) catch return error.InvalidPlaneIndex) catch return error.InvalidPlaneIndex;
        if (offset > data.len or data.len - offset < source_len) return error.TruncatedData;
        unpack12(data[offset..][0..source_len], out, header.msb_packing) catch return error.UnsupportedVariant;
    } else {
        const offset = std.math.add(usize, header.data_offset, std.math.mul(usize, plane_index, plane_len) catch return error.InvalidPlaneIndex) catch return error.InvalidPlaneIndex;
        if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
        @memcpy(out, data[offset..][0..plane_len]);
    }
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    const marker = std.mem.indexOf(u8, data, end_marker) orelse return error.InvalidFormat;
    const header_data = data[0..marker];
    var offset = marker + end_marker.len;
    while (offset < data.len and (data[offset] == '\r' or data[offset] == '\n')) : (offset += 1) {}

    const version = value(header_data, "FLIMIMAGE: INFO", "version") orelse value(header_data, "", "version") orelse "1.0";
    const is_v2 = std.mem.eql(u8, version, "2.0");
    const compression = if (is_v2) "0" else value(header_data, "FLIMIMAGE: INFO", "compression") orelse "0";
    const gzip = std.mem.eql(u8, compression, "1");
    if (!std.mem.eql(u8, compression, "0") and !gzip) return error.UnsupportedVariant;

    const datatype = if (is_v2)
        value(header_data, "", "pixelFormat") orelse return error.InvalidFormat
    else
        value(header_data, "FLIMIMAGE: LAYOUT", "datatype") orelse return error.InvalidFormat;
    const packing = if (is_v2) pixelFormatPacking(datatype) else value(header_data, "FLIMIMAGE: LAYOUT", "packing") orelse "lsb";
    const packed_12 = std.mem.eql(u8, datatype, "UINT12") or (pixelFormatBitSize(datatype) == 12 and packing.len != 0);
    if (gzip and packed_12) return error.UnsupportedVariant;
    const width = try parseU32(value(header_data, if (is_v2) "" else "FLIMIMAGE: LAYOUT", "x") orelse return error.InvalidFormat);
    const height = try parseU32(value(header_data, if (is_v2) "" else "FLIMIMAGE: LAYOUT", "y") orelse return error.InvalidFormat);
    const z = try parseU32(value(header_data, if (is_v2) "" else "FLIMIMAGE: LAYOUT", "z") orelse "1");
    const channels = if (is_v2) 1 else try parseU32(value(header_data, "FLIMIMAGE: LAYOUT", "channels") orelse "1");
    const phases = if (is_v2) 1 else try parseU32(value(header_data, "FLIMIMAGE: LAYOUT", "phases") orelse "1");
    const frequencies = if (is_v2) 1 else try parseU32(value(header_data, "FLIMIMAGE: LAYOUT", "frequencies") orelse "1");
    const timestamps = if (is_v2)
        try parseU32(value(header_data, "", "numberOfFrames") orelse "1")
    else
        try parseU32(value(header_data, "FLIMIMAGE: LAYOUT", "timestamps") orelse "1");
    if (width == 0 or height == 0 or z == 0 or channels == 0 or phases == 0 or frequencies == 0 or timestamps == 0) return error.InvalidFormat;
    const size_z = std.math.mul(u32, z, frequencies) catch return error.UnsupportedVariant;
    const size_t = std.math.mul(u32, timestamps, phases) catch return error.UnsupportedVariant;
    if (size_z > std.math.maxInt(u16) or size_t > std.math.maxInt(u16) or channels > std.math.maxInt(u16)) return error.UnsupportedVariant;
    const header = Header{
        .width = width,
        .height = height,
        .size_z = @intCast(size_z),
        .size_c = @intCast(channels),
        .size_t = @intCast(size_t),
        .pixel_type = if (packed_12) .uint16 else try pixelType(datatype),
        .data_offset = offset,
        .gzip = gzip,
        .packed_12 = packed_12,
        .msb_packing = std.mem.eql(u8, packing, "msb"),
    };
    const metadata = bio.Metadata{
        .format = "liflim",
        .width = header.width,
        .height = header.height,
        .size_z = header.size_z,
        .size_c = header.size_c,
        .size_t = header.size_t,
        .samples_per_pixel = header.size_c,
        .pixel_type = header.pixel_type,
        .plane_count = std.math.mul(u32, header.size_z, header.size_t) catch return error.UnsupportedVariant,
    };
    if (!gzip) {
        const plane_len = try planeByteCount(metadata);
        const source_len = if (packed_12) try packed12ByteCount(plane_len) else plane_len;
        const total = std.math.mul(usize, source_len, metadata.plane_count) catch return error.UnsupportedVariant;
        if (offset > data.len or data.len - offset < total) return error.TruncatedData;
    }
    return header;
}

fn value(data: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    var rows = lineIterator(data);
    var in_section = section.len == 0;
    while (rows.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            in_section = section.len != 0 and std.mem.eql(u8, name, section);
            continue;
        }
        if (!in_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, k, key)) continue;
        return stripQuotes(std.mem.trim(u8, line[eq + 1 ..], " \t"));
    }
    return null;
}

const LineIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *LineIterator) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '\n' and self.data[self.pos] != '\r') : (self.pos += 1) {}
        const raw = self.data[start..self.pos];
        while (self.pos < self.data.len and (self.data[self.pos] == '\n' or self.data[self.pos] == '\r')) : (self.pos += 1) {}
        return std.mem.trim(u8, raw, " \t");
    }
};

fn lineIterator(data: []const u8) LineIterator {
    return .{ .data = data };
}

fn stripQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and ((text[0] == '"' and text[text.len - 1] == '"') or (text[0] == '\'' and text[text.len - 1] == '\''))) {
        return text[1 .. text.len - 1];
    }
    return text;
}

fn parseU32(text: []const u8) bio.ReaderError!u32 {
    return std.fmt.parseInt(u32, text, 10) catch return error.InvalidFormat;
}

fn pixelType(name: []const u8) bio.ReaderError!bio.PixelType {
    if (std.mem.eql(u8, name, "UINT8")) return .uint8;
    if (std.mem.eql(u8, name, "INT8")) return .int8;
    if (std.mem.eql(u8, name, "UINT16")) return .uint16;
    if (std.mem.eql(u8, name, "INT16")) return .int16;
    if (std.mem.eql(u8, name, "UINT32")) return .uint32;
    if (std.mem.eql(u8, name, "INT32")) return .int32;
    if (std.mem.eql(u8, name, "REAL32")) return .float32;
    if (std.mem.eql(u8, name, "REAL64")) return .float64;
    return switch (pixelFormatBitSize(name)) {
        8 => .uint8,
        10, 12, 14, 16 => .uint16,
        else => error.UnsupportedVariant,
    };
}

fn pixelFormatPacking(name: []const u8) []const u8 {
    if (isOneOf(name, &.{ "BayerBG12p", "BayerGB12p", "BayerGR12p", "BayerRG12P", "Mono10P", "Mono12p", "Mono14p" })) return "lsb";
    if (isOneOf(name, &.{ "Mono12Packed", "BayerRG12Packed", "Mono10pmsb", "BayerGB12pmsb", "BayerGR12psmb", "BayerRG12", "BayerBG12pmsb" })) return "msb";
    return "";
}

fn pixelFormatBitSize(name: []const u8) u8 {
    if (isOneOf(name, &.{ "Mono8", "BGR8", "BGR8Packed", "RGB8", "RGB8Packed", "BayerBG8", "BayerGB8", "BayerGR8", "BayerRG8" })) return 8;
    if (isOneOf(name, &.{ "Mono10", "Mono10P", "Mono10pmsb", "BayerGR10", "BayerRG10" })) return 10;
    if (isOneOf(name, &.{ "Mono12", "Mono12p", "Mono12pmsb", "Mono12Packed", "BayerBG12", "BayerBG12p", "BayerBG12pmsb", "BayerGB12", "BayerGB12p", "BayerGB12pmsb", "BayerGR12", "BayerGR12p", "BayerGR12psmb", "BayerRG12", "BayerRG12P", "BayerRG12Packed" })) return 12;
    if (isOneOf(name, &.{ "Mono14", "Mono14p" })) return 14;
    if (isOneOf(name, &.{ "Mono16", "BayerBG16", "BayerGB16", "BayerGR16", "BayerRG16" })) return 16;
    return 0;
}

fn isOneOf(name: []const u8, values: []const []const u8) bool {
    for (values) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn packed12ByteCount(output_len: usize) bio.ReaderError!usize {
    if (output_len % 4 != 0) return error.UnsupportedVariant;
    return output_len / 4 * 3;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    const samples = std.math.mul(usize, pixels, metadata.samples_per_pixel) catch return error.UnsupportedVariant;
    return std.math.mul(usize, samples, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn decodeGzip(src: []const u8, dst: []u8) bio.ReaderError!void {
    var input: std.Io.Reader = .fixed(src);
    var output: std.Io.Writer = .fixed(dst);
    var decompress: std.compress.flate.Decompress = .init(&input, .gzip, &.{});
    const written = decompress.reader.streamRemaining(&output) catch return error.TruncatedData;
    if (written != dst.len) return error.TruncatedData;
}

fn unpack12(src: []const u8, dst: []u8, msb: bool) bio.ReaderError!void {
    if (dst.len / 4 != src.len / 3) return error.UnsupportedVariant;
    var i: usize = 0;
    var o: usize = 0;
    while (i + 2 < src.len and o + 3 < dst.len) : ({
        i += 3;
        o += 4;
    }) {
        if (msb) {
            dst[o] = ((src[i] & 0x0f) << 4) | ((src[i + 1] & 0xf0) >> 4);
            dst[o + 1] = (src[i] & 0xf0) >> 4;
            dst[o + 2] = src[i + 2];
            dst[o + 3] = src[i + 1] & 0x0f;
        } else {
            dst[o] = src[i];
            dst[o + 1] = src[i + 1] & 0x0f;
            dst[o + 2] = ((src[i + 1] & 0xf0) >> 4) | ((src[i + 2] & 0x0f) << 4);
            dst[o + 3] = (src[i + 2] & 0xf0) >> 4;
        }
    }
}

test "reads liflim v1 uncompressed plane" {
    const data =
        \\[FLIMIMAGE: INFO]
        \\version=1.0
        \\compression=0
        \\[FLIMIMAGE: LAYOUT]
        \\datatype=UINT16
        \\channels=1
        \\x=2
        \\y=1
        \\z=1
        \\phases=1
        \\frequencies=1
        \\timestamps=1
        \\{END}
    ++ [_]u8{ 1, 0, 2, 0 };

    try std.testing.expect(matches(data));
    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("liflim", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, plane.data);
}

test "reads liflim v2 float32 second frame" {
    const data =
        \\version=2.0
        \\pixelFormat=REAL32
        \\x=1
        \\y=1
        \\z=1
        \\numberOfFrames=2
        \\{END}
    ++ [_]u8{ 0, 0, 0, 0, 0, 0, 0x80, 0x3f };

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0x80, 0x3f }, plane.data);
}

test "reads gzip-compressed liflim plane" {
    const data =
        \\[FLIMIMAGE: INFO]
        \\compression=1
        \\[FLIMIMAGE: LAYOUT]
        \\datatype=UINT8
        \\x=2
        \\y=1
        \\{END}
    ++ [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x63, 0x64, 0x02, 0x00, 0x92, 0x42, 0xcc, 0xb6, 0x02, 0x00, 0x00, 0x00 };

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, plane.data);
}

test "unpacks lsb liflim uint12 plane" {
    const data =
        \\[FLIMIMAGE: INFO]
        \\compression=0
        \\[FLIMIMAGE: LAYOUT]
        \\datatype=UINT12
        \\packing=lsb
        \\x=2
        \\y=1
        \\{END}
    ++ [_]u8{ 0x23, 0xc1, 0xab };

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.uint16, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 0x23, 0x01, 0xbc, 0x0a }, plane.data);
}

test "unpacks msb liflim uint12 plane" {
    const data =
        \\[FLIMIMAGE: INFO]
        \\compression=0
        \\[FLIMIMAGE: LAYOUT]
        \\datatype=UINT12
        \\packing=msb
        \\x=2
        \\y=1
        \\{END}
    ++ [_]u8{ 0x12, 0x3a, 0xbc };

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x23, 0x01, 0xbc, 0x0a }, plane.data);
}

test "unpacks v2 mono12p liflim plane" {
    const data =
        \\version=2.0
        \\pixelFormat=Mono12p
        \\x=2
        \\y=1
        \\numberOfFrames=1
        \\{END}
    ++ [_]u8{ 0x23, 0xc1, 0xab };

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.uint16, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 0x23, 0x01, 0xbc, 0x0a }, plane.data);
}

test "reads v2 mono10 liflim as uint16" {
    const data =
        \\version=2.0
        \\pixelFormat=Mono10
        \\x=1
        \\y=1
        \\numberOfFrames=1
        \\{END}
    ++ [_]u8{ 0x34, 0x02 };

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.uint16, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x02 }, plane.data);
}
