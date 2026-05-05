const std = @import("std");
const bio = @import("../root.zig");

const Header = struct {
    magic: []const u8,
    width: u32,
    height: u32,
    max_value: u32,
    data_offset: usize,
    tuple_type: []const u8 = "",

    fn channels(self: Header) u16 {
        if (std.mem.eql(u8, self.magic, "P7")) {
            if (std.mem.eql(u8, self.tuple_type, "RGB_ALPHA") or std.mem.eql(u8, self.tuple_type, "GRAYSCALE_ALPHA") or std.mem.eql(u8, self.tuple_type, "BLACKANDWHITE_ALPHA")) return 4;
            if (std.mem.eql(u8, self.tuple_type, "RGB")) return 3;
            return 1;
        }
        return if (std.mem.eql(u8, self.magic, "P3") or std.mem.eql(u8, self.magic, "P6")) 3 else 1;
    }

    fn rawChannels(self: Header) u16 {
        if (std.mem.eql(u8, self.magic, "P7") and std.mem.eql(u8, self.tuple_type, "GRAYSCALE_ALPHA")) return 2;
        if (std.mem.eql(u8, self.magic, "P7") and std.mem.eql(u8, self.tuple_type, "BLACKANDWHITE_ALPHA")) return 2;
        return self.channels();
    }
};

pub fn matches(data: []const u8) bool {
    return data.len >= 2 and data[0] == 'P' and data[1] >= '1' and data[1] <= '7';
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    if (!std.mem.eql(u8, header.magic, "P4") and header.max_value > 65535) return error.UnsupportedVariant;
    return .{
        .format = "netpbm",
        .width = header.width,
        .height = header.height,
        .size_c = header.channels(),
        .samples_per_pixel = header.channels(),
        .pixel_type = if (header.max_value > 255)
            if (header.channels() == 4) .rgba16 else if (header.channels() == 3) .rgb16 else .uint16
        else if (header.channels() == 4) .rgba8 else if (header.channels() == 3) .rgb8 else .uint8,
        .little_endian = false,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    const expected = try planeByteCount(metadata.width, metadata.height, metadata.size_c, metadata.pixel_type.bytesPerSample());
    const out = try allocator.alloc(u8, expected);
    errdefer allocator.free(out);
    if (isPlain(header.magic)) {
        try readPlain(data, header, metadata.pixel_type.bytesPerSample(), out);
    } else if (std.mem.eql(u8, header.magic, "P4")) {
        try readPackedBitmap(data, header, out);
    } else if (std.mem.eql(u8, header.magic, "P7") and std.mem.eql(u8, header.tuple_type, "GRAYSCALE_ALPHA")) {
        try readPamGrayscaleAlpha(data, header, metadata.pixel_type.bytesPerSample(), out);
    } else if (std.mem.eql(u8, header.magic, "P7") and std.mem.eql(u8, header.tuple_type, "BLACKANDWHITE")) {
        try readPamBlackWhite(data, header, out);
    } else if (std.mem.eql(u8, header.magic, "P7") and std.mem.eql(u8, header.tuple_type, "BLACKANDWHITE_ALPHA")) {
        try readPamBlackWhiteAlpha(data, header, out);
    } else {
        if (data.len - header.data_offset < expected) return error.TruncatedData;
        @memcpy(out, data[header.data_offset..][0..expected]);
    }
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    var cursor: usize = 0;
    const magic = try nextToken(data, &cursor);
    if (!isSupportedMagic(magic)) return error.UnsupportedFormat;
    if (std.mem.eql(u8, magic, "P7")) return parsePamHeader(data, cursor, magic);
    const width = try parsePositiveU32(try nextToken(data, &cursor));
    const height = try parsePositiveU32(try nextToken(data, &cursor));
    const max_value = if (isBitmap(magic)) 1 else try parsePositiveU32(try nextToken(data, &cursor));

    if (isPlain(magic)) {
        if (cursor > data.len) return error.TruncatedData;
    } else {
        if (cursor >= data.len or !isWhitespace(data[cursor])) return error.InvalidFormat;
        cursor += 1;
    }

    return .{
        .magic = magic,
        .width = width,
        .height = height,
        .max_value = max_value,
        .data_offset = cursor,
    };
}

fn parsePamHeader(data: []const u8, cursor_start: usize, magic: []const u8) bio.ReaderError!Header {
    var cursor = cursor_start;
    var width: u32 = 0;
    var height: u32 = 0;
    var depth: u32 = 0;
    var max_value: u32 = 0;
    var tuple_type: []const u8 = "";

    while (true) {
        const key = try nextToken(data, &cursor);
        if (std.mem.eql(u8, key, "ENDHDR")) break;
        const value = try nextToken(data, &cursor);
        if (std.mem.eql(u8, key, "WIDTH")) {
            width = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "HEIGHT")) {
            height = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "DEPTH")) {
            depth = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "MAXVAL")) {
            max_value = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "TUPLTYPE")) {
            tuple_type = value;
        }
    }
    if (width == 0 or height == 0 or max_value == 0) return error.InvalidFormat;
    if (max_value > 65535) return error.UnsupportedVariant;
    if (tuple_type.len == 0) {
        tuple_type = switch (depth) {
            1 => if (max_value > 1) "GRAYSCALE" else return error.UnsupportedVariant,
            2 => if (max_value > 1) "GRAYSCALE_ALPHA" else return error.UnsupportedVariant,
            3 => "RGB",
            4 => "RGB_ALPHA",
            else => return error.UnsupportedVariant,
        };
    }
    if (std.mem.eql(u8, tuple_type, "GRAYSCALE")) {
        if (depth != 1) return error.UnsupportedVariant;
    } else if (std.mem.eql(u8, tuple_type, "BLACKANDWHITE")) {
        if (depth != 1 or max_value != 1) return error.UnsupportedVariant;
    } else if (std.mem.eql(u8, tuple_type, "RGB")) {
        if (depth != 3) return error.UnsupportedVariant;
    } else if (std.mem.eql(u8, tuple_type, "RGB_ALPHA")) {
        if (depth != 4) return error.UnsupportedVariant;
    } else if (std.mem.eql(u8, tuple_type, "GRAYSCALE_ALPHA")) {
        if (depth != 2) return error.UnsupportedVariant;
    } else if (std.mem.eql(u8, tuple_type, "BLACKANDWHITE_ALPHA")) {
        if (depth != 2 or max_value != 1) return error.UnsupportedVariant;
    } else {
        return error.UnsupportedVariant;
    }
    if (cursor >= data.len or !isWhitespace(data[cursor])) return error.InvalidFormat;
    cursor += 1;
    return .{
        .magic = magic,
        .width = width,
        .height = height,
        .max_value = max_value,
        .data_offset = cursor,
        .tuple_type = tuple_type,
    };
}

fn isSupportedMagic(magic: []const u8) bool {
    return std.mem.eql(u8, magic, "P1") or
        std.mem.eql(u8, magic, "P2") or
        std.mem.eql(u8, magic, "P3") or
        std.mem.eql(u8, magic, "P4") or
        std.mem.eql(u8, magic, "P5") or
        std.mem.eql(u8, magic, "P6") or
        std.mem.eql(u8, magic, "P7");
}

fn isPlain(magic: []const u8) bool {
    return std.mem.eql(u8, magic, "P1") or std.mem.eql(u8, magic, "P2") or std.mem.eql(u8, magic, "P3");
}

fn isBitmap(magic: []const u8) bool {
    return std.mem.eql(u8, magic, "P1") or std.mem.eql(u8, magic, "P4");
}

fn nextToken(data: []const u8, cursor: *usize) bio.ReaderError![]const u8 {
    while (cursor.* < data.len) {
        if (isWhitespace(data[cursor.*])) {
            cursor.* += 1;
            continue;
        }
        if (data[cursor.*] == '#') {
            while (cursor.* < data.len and data[cursor.*] != '\n') cursor.* += 1;
            continue;
        }
        break;
    }
    if (cursor.* >= data.len) return error.TruncatedData;
    const start = cursor.*;
    while (cursor.* < data.len and !isWhitespace(data[cursor.*])) cursor.* += 1;
    return data[start..cursor.*];
}

fn parsePositiveU32(token: []const u8) bio.ReaderError!u32 {
    const value = std.fmt.parseInt(u32, token, 10) catch return error.InvalidFormat;
    if (value == 0) return error.InvalidFormat;
    return value;
}

fn readPackedBitmap(data: []const u8, header: Header, out: []u8) bio.ReaderError!void {
    const row_bytes = (@as(usize, header.width) + 7) / 8;
    const expected = std.math.mul(usize, row_bytes, header.height) catch return error.UnsupportedVariant;
    if (data.len - header.data_offset < expected) return error.TruncatedData;
    var y: usize = 0;
    while (y < header.height) : (y += 1) {
        const row = data[header.data_offset + y * row_bytes ..][0..row_bytes];
        var x: usize = 0;
        while (x < header.width) : (x += 1) {
            const byte = row[x / 8];
            const shift: u3 = @intCast(7 - (x % 8));
            const black = ((byte >> shift) & 1) != 0;
            out[y * header.width + x] = if (black) 0 else 255;
        }
    }
}

fn readPlain(data: []const u8, header: Header, bytes_per_sample: usize, out: []u8) bio.ReaderError!void {
    var cursor = header.data_offset;
    const samples = std.math.mul(usize, std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant, header.channels()) catch return error.UnsupportedVariant;
    var i: usize = 0;
    while (i < samples) : (i += 1) {
        const value = parseAsciiSample(try nextToken(data, &cursor), header) catch |err| return err;
        if (isBitmap(header.magic)) {
            out[i] = if (value == 1) 0 else 255;
        } else if (bytes_per_sample == 1) {
            out[i] = @intCast(value);
        } else {
            const dst = i * 2;
            std.mem.writeInt(u16, out[dst..][0..2], @intCast(value), .big);
        }
    }
}

fn readPamGrayscaleAlpha(data: []const u8, header: Header, bytes_per_sample: usize, out: []u8) bio.ReaderError!void {
    const pixels = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    const raw_sample_count = std.math.mul(usize, pixels, header.rawChannels()) catch return error.UnsupportedVariant;
    const raw_len = std.math.mul(usize, raw_sample_count, bytes_per_sample) catch return error.UnsupportedVariant;
    if (data.len - header.data_offset < raw_len) return error.TruncatedData;
    const raw = data[header.data_offset..][0..raw_len];
    var pixel: usize = 0;
    while (pixel < pixels) : (pixel += 1) {
        const src = pixel * 2 * bytes_per_sample;
        const dst = pixel * 4 * bytes_per_sample;
        const gray = raw[src..][0..bytes_per_sample];
        const alpha = raw[src + bytes_per_sample ..][0..bytes_per_sample];
        @memcpy(out[dst..][0..bytes_per_sample], gray);
        @memcpy(out[dst + bytes_per_sample ..][0..bytes_per_sample], gray);
        @memcpy(out[dst + bytes_per_sample * 2 ..][0..bytes_per_sample], gray);
        @memcpy(out[dst + bytes_per_sample * 3 ..][0..bytes_per_sample], alpha);
    }
}

fn readPamBlackWhite(data: []const u8, header: Header, out: []u8) bio.ReaderError!void {
    const pixels = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    if (data.len - header.data_offset < pixels) return error.TruncatedData;
    const raw = data[header.data_offset..][0..pixels];
    for (raw, 0..) |sample, i| {
        if (sample > 1) return error.InvalidFormat;
        out[i] = if (sample == 1) 0 else 255;
    }
}

fn readPamBlackWhiteAlpha(data: []const u8, header: Header, out: []u8) bio.ReaderError!void {
    const pixels = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    const raw_len = std.math.mul(usize, pixels, header.rawChannels()) catch return error.UnsupportedVariant;
    if (data.len - header.data_offset < raw_len) return error.TruncatedData;
    const raw = data[header.data_offset..][0..raw_len];
    var pixel: usize = 0;
    while (pixel < pixels) : (pixel += 1) {
        const bw = raw[pixel * 2];
        const alpha = raw[pixel * 2 + 1];
        if (bw > 1 or alpha > 1) return error.InvalidFormat;
        const value: u8 = if (bw == 1) 0 else 255;
        const dst = pixel * 4;
        out[dst] = value;
        out[dst + 1] = value;
        out[dst + 2] = value;
        out[dst + 3] = if (alpha == 1) 255 else 0;
    }
}

fn parseAsciiSample(token: []const u8, header: Header) bio.ReaderError!u32 {
    const value = std.fmt.parseInt(u32, token, 10) catch return error.InvalidFormat;
    if (isBitmap(header.magic)) {
        if (value > 1) return error.InvalidFormat;
    } else if (value > header.max_value) {
        return error.InvalidFormat;
    }
    return value;
}

fn planeByteCount(width: u32, height: u32, channels: u16, bytes_per_sample: usize) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, width, height) catch return error.UnsupportedVariant;
    const samples = std.math.mul(usize, pixels, channels) catch return error.UnsupportedVariant;
    return std.math.mul(usize, samples, bytes_per_sample) catch return error.UnsupportedVariant;
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\n' or byte == '\r' or byte == '\t';
}

test "reads binary pgm metadata and pixels" {
    const data = "P5\n# comment\n2 2\n255\n" ++ [_]u8{ 0, 1, 2, 3 };
    const meta = try readMetadata(data);
    try std.testing.expectEqual(@as(u32, 2), meta.width);
    try std.testing.expectEqual(@as(u32, 2), meta.height);
    try std.testing.expectEqual(@as(u16, 1), meta.size_c);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, plane.data);
}

test "reads binary pbm metadata and pixels" {
    const data = "P4\n5 1\n" ++ [_]u8{0xa8};
    const meta = try readMetadata(data);
    try std.testing.expectEqual(@as(u32, 5), meta.width);
    try std.testing.expectEqual(@as(u16, 1), meta.size_c);
    try std.testing.expectEqual(bio.PixelType.uint8, meta.pixel_type);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255, 0 }, plane.data);
}

test "reads plain pbm metadata and pixels" {
    const data = "P1\n5 1\n1 0 1 0 1\n";
    const meta = try readMetadata(data);
    try std.testing.expectEqual(@as(u32, 5), meta.width);
    try std.testing.expectEqual(bio.PixelType.uint8, meta.pixel_type);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255, 0 }, plane.data);
}

test "reads binary ppm metadata and pixels" {
    const data = "P6\n1 1\n255\n" ++ [_]u8{ 10, 20, 30 };
    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(u16, 3), plane.metadata.size_c);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30 }, plane.data);
}

test "reads plain pgm metadata and pixels" {
    const data = "P2\n# comment\n2 1\n255\n7 9\n";
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.uint8, meta.pixel_type);
    try std.testing.expectEqual(@as(u16, 1), meta.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "reads plain ppm metadata and pixels" {
    const data = "P3\n1 1\n255\n10 20 30\n";
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.rgb8, meta.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), meta.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30 }, plane.data);
}

test "reads 16-bit binary pgm metadata and pixels" {
    const data = "P5\n2 1\n65535\n" ++ [_]u8{ 0x12, 0x34, 0xab, 0xcd };
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.uint16, meta.pixel_type);
    try std.testing.expectEqual(@as(usize, 2), meta.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0xab, 0xcd }, plane.data);
}

test "reads 16-bit binary ppm metadata and pixels" {
    const data = "P6\n1 1\n65535\n" ++ [_]u8{ 0, 1, 0, 2, 0, 3 };
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.rgb16, meta.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), meta.samples_per_pixel);
    try std.testing.expectEqual(@as(usize, 6), meta.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 2, 0, 3 }, plane.data);
}

test "reads 16-bit plain ppm metadata and pixels" {
    const data = "P3\n1 1\n65535\n1 2 3\n";
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.rgb16, meta.pixel_type);
    try std.testing.expectEqual(@as(usize, 6), meta.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 2, 0, 3 }, plane.data);
}

test "reads pam grayscale metadata and pixels" {
    const data = "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 1\nMAXVAL 255\nTUPLTYPE GRAYSCALE\nENDHDR\n" ++ [_]u8{ 7, 9 };
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.uint8, meta.pixel_type);
    try std.testing.expectEqual(@as(u16, 1), meta.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "reads pam grayscale without tuple type" {
    const data = "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 1\nMAXVAL 255\nENDHDR\n" ++ [_]u8{ 7, 9 };
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.uint8, meta.pixel_type);
    try std.testing.expectEqual(@as(u16, 1), meta.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "reads pam black and white bitmap semantics" {
    const data = "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 1\nMAXVAL 1\nTUPLTYPE BLACKANDWHITE\nENDHDR\n" ++ [_]u8{ 0, 1 };
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.uint8, meta.pixel_type);
    try std.testing.expectEqual(@as(u16, 1), meta.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0 }, plane.data);
}

test "rejects ambiguous pam binary sample without tuple type" {
    const data = "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 1\nMAXVAL 1\nENDHDR\n" ++ [_]u8{0};
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data));
}

test "reads pam rgb metadata and pixels" {
    const data = "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 3\nMAXVAL 255\nTUPLTYPE RGB\nENDHDR\n" ++ [_]u8{ 10, 20, 30 };
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.rgb8, meta.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), meta.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30 }, plane.data);
}

test "reads pam rgb without tuple type" {
    const data = "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 3\nMAXVAL 255\nENDHDR\n" ++ [_]u8{ 10, 20, 30 };
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.rgb8, meta.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), meta.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30 }, plane.data);
}

test "reads pam rgba metadata and pixels" {
    const data = "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n" ++ [_]u8{ 10, 20, 30, 40 };
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.rgba8, meta.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), meta.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40 }, plane.data);
}

test "reads pam rgba without tuple type" {
    const data = "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 4\nMAXVAL 255\nENDHDR\n" ++ [_]u8{ 10, 20, 30, 40 };
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.rgba8, meta.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), meta.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40 }, plane.data);
}

test "reads pam grayscale alpha as rgba" {
    const data = "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 2\nMAXVAL 255\nTUPLTYPE GRAYSCALE_ALPHA\nENDHDR\n" ++ [_]u8{ 7, 0, 9, 255 };
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.rgba8, meta.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), meta.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 7, 0, 9, 9, 9, 255 }, plane.data);
}

test "reads pam grayscale alpha without tuple type" {
    const data = "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 2\nMAXVAL 255\nENDHDR\n" ++ [_]u8{ 7, 0, 9, 255 };
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.rgba8, meta.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), meta.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 7, 0, 9, 9, 9, 255 }, plane.data);
}

test "reads pam black and white alpha as rgba" {
    const data = "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 2\nMAXVAL 1\nTUPLTYPE BLACKANDWHITE_ALPHA\nENDHDR\n" ++ [_]u8{ 0, 1, 1, 0 };
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.rgba8, meta.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), meta.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255, 0, 0, 0, 0 }, plane.data);
}

test "reads 16-bit pam rgb metadata and pixels" {
    const data = "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 3\nMAXVAL 65535\nTUPLTYPE RGB\nENDHDR\n" ++ [_]u8{ 0, 1, 0, 2, 0, 3 };
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.rgb16, meta.pixel_type);
    try std.testing.expectEqual(@as(usize, 6), meta.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 2, 0, 3 }, plane.data);
}

test "reads 16-bit pam grayscale alpha as rgba" {
    const data = "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 2\nMAXVAL 65535\nTUPLTYPE GRAYSCALE_ALPHA\nENDHDR\n" ++ [_]u8{ 0x12, 0x34, 0xab, 0xcd };
    const meta = try readMetadata(data);
    try std.testing.expectEqual(bio.PixelType.rgba16, meta.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), meta.samples_per_pixel);
    try std.testing.expectEqual(@as(usize, 8), meta.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x12, 0x34, 0x12, 0x34, 0xab, 0xcd }, plane.data);
}
