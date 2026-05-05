const std = @import("std");
const bio = @import("../root.zig");

const Header = struct {
    width: u32,
    height: u32,
    size_z: u16,
    size_c: u16,
    size_t: u16,
    pixel_type: bio.PixelType,
    little_endian: bool,
    dimension_order: []const u8,
};

const BinData = struct {
    content: []const u8,
    compression: ?[]const u8,
    big_endian: ?bool,
};

pub fn matches(data: []const u8) bool {
    if (data.len < 5 or !std.mem.startsWith(u8, data, "<?xml")) return false;
    const end = @min(@as(usize, 64), data.len);
    return std.mem.indexOf(u8, data[0..end], "<OME") != null;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    const plane_count = std.math.mul(u32, std.math.mul(u32, header.size_z, header.size_c) catch return error.UnsupportedVariant, header.size_t) catch return error.UnsupportedVariant;
    return .{
        .format = "omexml",
        .width = header.width,
        .height = header.height,
        .size_c = header.size_c,
        .samples_per_pixel = 1,
        .size_z = header.size_z,
        .size_t = header.size_t,
        .pixel_type = header.pixel_type,
        .little_endian = header.little_endian,
        .plane_count = plane_count,
        .dimension_order = header.dimension_order,
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    var metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    @memset(out, 0);

    if (findBinData(data, plane_index)) |bin| {
        if (bin.big_endian) |big_endian| {
            metadata.little_endian = !big_endian;
        }
        if (bin.compression) |compression| {
            if (compression.len != 0 and !std.ascii.eqlIgnoreCase(compression, "none") and !std.ascii.eqlIgnoreCase(compression, "zlib")) return error.UnsupportedVariant;
        }
        const decoded = try decodeBase64(allocator, bin.content);
        defer allocator.free(decoded);
        if (decoded.len == 0) {
            return .{ .metadata = metadata, .data = out };
        }
        if (bin.compression != null and std.ascii.eqlIgnoreCase(bin.compression.?, "zlib")) {
            try decodeZlib(decoded, out);
        } else {
            if (decoded.len < plane_len) return error.TruncatedData;
            @memcpy(out, decoded[0..plane_len]);
        }
    }
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    const pixels = findTag(data, "Pixels") orelse return error.InvalidFormat;
    const type_name = attr(pixels, "Type") orelse return error.InvalidFormat;
    const size_x = try parseU32(attr(pixels, "SizeX") orelse return error.InvalidFormat);
    const size_y = try parseU32(attr(pixels, "SizeY") orelse return error.InvalidFormat);
    const size_z = try parseU16(attr(pixels, "SizeZ") orelse "1");
    const size_c = try parseU16(attr(pixels, "SizeC") orelse "1");
    const size_t = try parseU16(attr(pixels, "SizeT") orelse "1");
    if (size_x == 0 or size_y == 0 or size_z == 0 or size_c == 0 or size_t == 0) return error.InvalidFormat;
    const big_endian = parseBool(attr(pixels, "BigEndian") orelse "false");
    return .{
        .width = size_x,
        .height = size_y,
        .size_z = size_z,
        .size_c = size_c,
        .size_t = size_t,
        .pixel_type = try parsePixelType(type_name),
        .little_endian = !big_endian,
        .dimension_order = attr(pixels, "DimensionOrder") orelse "XYZCT",
    };
}

fn findTag(data: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < data.len) {
        const tag_start = std.mem.indexOfScalarPos(u8, data, pos, '<') orelse return null;
        const name_start = tag_start + 1;
        pos = name_start;
        if (name_start >= data.len or data[name_start] == '/' or data[name_start] == '!' or data[name_start] == '?') continue;
        const tag_name = tagName(data, name_start) orelse continue;
        if (std.mem.eql(u8, localName(tag_name), name)) {
            const end = std.mem.indexOfScalarPos(u8, data, name_start + tag_name.len, '>') orelse return null;
            return data[tag_start .. end + 1];
        }
        pos = name_start + tag_name.len;
    }
    return null;
}

fn findBinData(data: []const u8, plane_index: u32) ?BinData {
    var pos: usize = 0;
    var seen: u32 = 0;
    var last: ?BinData = null;
    while (pos < data.len) {
        const tag_start = std.mem.indexOfScalarPos(u8, data, pos, '<') orelse break;
        const name_start = tag_start + 1;
        pos = name_start;
        if (name_start >= data.len or data[name_start] == '/' or data[name_start] == '!' or data[name_start] == '?') continue;
        const tag_name = tagName(data, name_start) orelse continue;
        if (!std.mem.eql(u8, localName(tag_name), "BinData")) {
            pos = name_start + tag_name.len;
            continue;
        }

        const tag_end = std.mem.indexOfScalarPos(u8, data, name_start + tag_name.len, '>') orelse break;
        const tag = data[tag_start .. tag_end + 1];
        const content_start = tag_end + 1;
        const close = if (isSelfClosingTag(tag)) null else findClosingTag(data, content_start, "BinData") orelse break;
        const content_end = if (close) |closing| closing.start else content_start;
        const bin = BinData{
            .content = std.mem.trim(u8, data[content_start..content_end], " \t\r\n"),
            .compression = attr(tag, "Compression"),
            .big_endian = if (attr(tag, "BigEndian")) |value| parseBool(value) else null,
        };
        last = bin;
        if (seen == plane_index) return bin;
        seen += 1;
        pos = if (close) |closing| closing.end else tag_end + 1;
    }
    return last;
}

const CloseTag = struct {
    start: usize,
    end: usize,
};

fn findClosingTag(data: []const u8, pos: usize, name: []const u8) ?CloseTag {
    var search = pos;
    while (search < data.len) {
        const tag_start = std.mem.indexOfScalarPos(u8, data, search, '<') orelse return null;
        const name_start = tag_start + 2;
        search = tag_start + 1;
        if (tag_start + 1 >= data.len or data[tag_start + 1] != '/') continue;
        const tag_name = tagName(data, name_start) orelse continue;
        if (std.mem.eql(u8, localName(tag_name), name)) {
            const tag_end = std.mem.indexOfScalarPos(u8, data, name_start + tag_name.len, '>') orelse return null;
            return .{ .start = tag_start, .end = tag_end + 1 };
        }
        search = name_start + tag_name.len;
    }
    return null;
}

fn tagName(data: []const u8, start: usize) ?[]const u8 {
    var end = start;
    while (end < data.len and !std.ascii.isWhitespace(data[end]) and data[end] != '>' and data[end] != '/') : (end += 1) {}
    if (end == start) return null;
    return data[start..end];
}

fn localName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, ':')) |colon| {
        return name[colon + 1 ..];
    }
    return name;
}

fn isSelfClosingTag(tag: []const u8) bool {
    if (tag.len < 2 or tag[tag.len - 1] != '>') return false;
    var i = tag.len - 1;
    while (i > 0) {
        i -= 1;
        if (std.ascii.isWhitespace(tag[i])) continue;
        return tag[i] == '/';
    }
    return false;
}

fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < tag.len) {
        const found = std.mem.indexOfPos(u8, tag, pos, name) orelse return null;
        const after_name = found + name.len;
        if (found > 0 and (std.ascii.isAlphanumeric(tag[found - 1]) or tag[found - 1] == '_' or tag[found - 1] == ':')) {
            pos = after_name;
            continue;
        }
        var eq = after_name;
        while (eq < tag.len and std.ascii.isWhitespace(tag[eq])) : (eq += 1) {}
        if (eq >= tag.len or tag[eq] != '=') {
            pos = after_name;
            continue;
        }
        eq += 1;
        while (eq < tag.len and std.ascii.isWhitespace(tag[eq])) : (eq += 1) {}
        if (eq >= tag.len or (tag[eq] != '"' and tag[eq] != '\'')) return null;
        const quote = tag[eq];
        const value_start = eq + 1;
        const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, quote) orelse return null;
        return tag[value_start..value_end];
    }
    return null;
}

fn parsePixelType(name: []const u8) bio.ReaderError!bio.PixelType {
    if (std.mem.eql(u8, name, "uint8")) return .uint8;
    if (std.mem.eql(u8, name, "uint16")) return .uint16;
    if (std.mem.eql(u8, name, "uint32")) return .uint32;
    if (std.mem.eql(u8, name, "int8")) return .int8;
    if (std.mem.eql(u8, name, "int16")) return .int16;
    if (std.mem.eql(u8, name, "int32")) return .int32;
    if (std.mem.eql(u8, name, "float")) return .float32;
    if (std.mem.eql(u8, name, "double")) return .float64;
    return error.UnsupportedVariant;
}

fn parseU32(text: []const u8) bio.ReaderError!u32 {
    return std.fmt.parseInt(u32, text, 10) catch return error.InvalidFormat;
}

fn parseU16(text: []const u8) bio.ReaderError!u16 {
    return std.fmt.parseInt(u16, text, 10) catch return error.InvalidFormat;
}

fn parseBool(text: []const u8) bool {
    const value = std.mem.trim(u8, text, " \t\r\n");
    return std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1") or std.ascii.startsWithIgnoreCase(value, "t");
}

fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) bio.ReaderError![]u8 {
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const max_len = decoder.calcSizeUpperBound(encoded.len);
    const scratch = try allocator.alloc(u8, max_len);
    defer allocator.free(scratch);
    const len = decoder.decode(scratch, encoded) catch return error.InvalidFormat;
    const out = try allocator.alloc(u8, len);
    @memcpy(out, scratch[0..len]);
    return out;
}

fn decodeZlib(src: []const u8, dst: []u8) bio.ReaderError!void {
    var input: std.Io.Reader = .fixed(src);
    var output: std.Io.Writer = .fixed(dst);
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    const written = decompress.reader.streamRemaining(&output) catch return error.TruncatedData;
    if (written != dst.len) return error.TruncatedData;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

test "reads uncompressed ome xml bindata plane" {
    const data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<OME>
        \\  <Image ID="Image:0">
        \\    <Pixels DimensionOrder="XYZCT" Type="uint8" SizeX="2" SizeY="1" SizeZ="1" SizeC="1" SizeT="1" BigEndian="false">
        \\      <BinData Compression="none">AQI=</BinData>
        \\    </Pixels>
        \\  </Image>
        \\</OME>
    ;

    try std.testing.expect(matches(data));
    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("omexml", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, plane.data);
}

test "reads namespaced ome xml bindata plane" {
    const data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<OME:OME xmlns:OME="http://www.openmicroscopy.org/Schemas/OME/2011-06" xmlns:Bin="http://www.openmicroscopy.org/Schemas/BinaryFile/2011-06">
        \\  <OME:Image ID="Image:0">
        \\    <OME:Pixels DimensionOrder="XYZCT" Type="uint8" SizeX="2" SizeY="1" SizeZ="1" SizeC="1" SizeT="1" BigEndian="false">
        \\      <Bin:BinData Compression="none" Length="2">AQI=</Bin:BinData>
        \\    </OME:Pixels>
        \\  </OME:Image>
        \\</OME:OME>
    ;

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, plane.data);
}

test "ome xml without bindata returns blank plane" {
    const data =
        \\<?xml version="1.0"?>
        \\<OME><Image ID="Image:0"><Pixels DimensionOrder="XYZCT" Type="uint16" SizeX="1" SizeY="1" SizeZ="1" SizeC="1" SizeT="1"/></Image></OME>
    ;

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, plane.data);
}

test "ome xml empty bindata returns blank plane" {
    const data =
        \\<?xml version="1.0"?>
        \\<OME><Image ID="Image:0"><Pixels DimensionOrder="XYZCT" Type="uint16" SizeX="1" SizeY="1" SizeZ="1" SizeC="1" SizeT="1"><Bin:BinData xmlns:Bin="http://www.openmicroscopy.org/Schemas/BinaryFile/2011-06" Length="0"/></Pixels></Image></OME>
    ;

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, plane.data);
}

test "reads zlib-compressed ome xml bindata plane" {
    const data =
        \\<?xml version="1.0"?>
        \\<OME><Image ID="Image:0"><Pixels DimensionOrder="XYZCT" Type="uint8" SizeX="2" SizeY="1" SizeZ="1" SizeC="1" SizeT="1"><BinData Compression="zlib">eAEBAgD9/wECAAYABA==</BinData></Pixels></Image></OME>
    ;

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, plane.data);
}

test "ome xml bindata big endian overrides pixels endian" {
    const data =
        \\<?xml version="1.0"?>
        \\<OME><Image ID="Image:0"><Pixels DimensionOrder="XYZCT" Type="uint16" SizeX="1" SizeY="1" SizeZ="1" SizeC="1" SizeT="1" BigEndian="false"><BinData Compression="none" BigEndian="true">AQI=</BinData></Pixels></Image></OME>
    ;

    const metadata = try readMetadata(data);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expect(!plane.metadata.little_endian);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, plane.data);
}

test "ome xml accepts t f big endian values" {
    const data =
        \\<?xml version="1.0"?>
        \\<OME><Image ID="Image:0"><Pixels DimensionOrder="XYZCT" Type="uint16" SizeX="1" SizeY="1" SizeZ="1" SizeC="1" SizeT="1" BigEndian="t"><BinData Compression="none" BigEndian="f">AQI=</BinData></Pixels></Image></OME>
    ;

    const metadata = try readMetadata(data);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expect(plane.metadata.little_endian);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, plane.data);
}

test "ome xml rejects unsupported compressed bindata" {
    const data =
        \\<?xml version="1.0"?>
        \\<OME><Image ID="Image:0"><Pixels DimensionOrder="XYZCT" Type="uint8" SizeX="1" SizeY="1" SizeZ="1" SizeC="1" SizeT="1"><BinData Compression="bzip2">AA==</BinData></Pixels></Image></OME>
    ;

    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, data, 0));
}
