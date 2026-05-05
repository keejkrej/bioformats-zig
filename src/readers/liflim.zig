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
    const offset = std.math.add(usize, header.data_offset, std.math.mul(usize, plane_index, plane_len) catch return error.InvalidPlaneIndex) catch return error.InvalidPlaneIndex;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
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
    if (!std.mem.eql(u8, compression, "0")) return error.UnsupportedVariant;

    const datatype = if (is_v2)
        value(header_data, "", "pixelFormat") orelse return error.InvalidFormat
    else
        value(header_data, "FLIMIMAGE: LAYOUT", "datatype") orelse return error.InvalidFormat;
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
        .pixel_type = try pixelType(datatype),
        .data_offset = offset,
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
    const total = std.math.mul(usize, try planeByteCount(metadata), metadata.plane_count) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < total) return error.TruncatedData;
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
    return error.UnsupportedVariant;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    const samples = std.math.mul(usize, pixels, metadata.samples_per_pixel) catch return error.UnsupportedVariant;
    return std.math.mul(usize, samples, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
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

test "rejects compressed liflim" {
    const data =
        \\[FLIMIMAGE: INFO]
        \\compression=1
        \\[FLIMIMAGE: LAYOUT]
        \\datatype=UINT8
        \\x=1
        \\y=1
        \\{END}
    ++ [_]u8{0};

    try std.testing.expect(!matches(data));
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data));
}
