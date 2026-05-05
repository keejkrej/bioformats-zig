const std = @import("std");
const bio = @import("../root.zig");

const magic = "%!PS";

const Header = struct {
    width: u32,
    height: u32,
    samples: u16,
    data_offset: usize,
    binary: bool,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "eps",
        .width = header.width,
        .height = header.height,
        .size_c = header.samples,
        .samples_per_pixel = header.samples,
        .pixel_type = .uint8,
    }) catch return false;
    if (header.binary) return data.len >= header.data_offset and data.len - header.data_offset >= plane_len;
    return countHexBytes(data[header.data_offset..]) >= plane_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "eps",
        .width = header.width,
        .height = header.height,
        .size_c = header.samples,
        .samples_per_pixel = header.samples,
        .pixel_type = .uint8,
        .little_endian = true,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    const plane_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    if (header.binary) {
        if (data.len < header.data_offset or data.len - header.data_offset < plane_len) return error.TruncatedData;
        @memcpy(out, data[header.data_offset..][0..plane_len]);
    } else {
        try decodeHexBytes(data[header.data_offset..], out);
    }
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    var rows = rowIterator(data);
    const first = rows.next() orelse return error.TruncatedData;
    if (!std.mem.startsWith(u8, first.line, magic)) return error.InvalidFormat;

    var width: u32 = 0;
    var height: u32 = 0;
    var samples: u16 = 1;
    var image_marker: []const u8 = "image";
    var binary = false;

    while (rows.next()) |row| {
        const line = row.line;
        if (std.mem.startsWith(u8, line, "%%BeginBinary")) {
            binary = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "%ImageData:")) {
            const declaration = std.mem.trim(u8, line["%ImageData:".len..], " \t");
            var tokens = tokenize(declaration);
            if (tokens.len < 4) return error.InvalidFormat;
            width = try parsePositive(tokens.items[0]);
            height = try parsePositive(tokens.items[1]);
            const bits = try parsePositive(tokens.items[2]);
            if (bits != 8) return error.UnsupportedVariant;
            samples = @intCast(try parsePositive(tokens.items[3]));
            if (samples != 1 and samples != 3) return error.UnsupportedVariant;
            for (tokens.items[4..tokens.len]) |token| {
                image_marker = stripQuotes(token);
            }
            continue;
        }

        if (std.mem.endsWith(u8, line, image_marker)) {
            if (!std.mem.startsWith(u8, line, image_marker)) {
                if (std.mem.indexOf(u8, line, "colorimage") != null) samples = 3;
                const tokens = tokenize(line);
                if (tokens.len >= 3 and startsWithDigit(tokens.items[0])) {
                    width = try parsePositive(tokens.items[0]);
                    height = try parsePositive(tokens.items[1]);
                    const bits = try parsePositive(tokens.items[2]);
                    if (bits != 8) return error.UnsupportedVariant;
                } else if (width == 0 or height == 0) {
                    return error.InvalidFormat;
                }
            } else if (width == 0 or height == 0) {
                return error.InvalidFormat;
            }
            if (samples != 1 and samples != 3) return error.UnsupportedVariant;
            return .{ .width = width, .height = height, .samples = samples, .data_offset = row.next_offset, .binary = binary };
        }
    }

    return error.InvalidFormat;
}

fn stripQuotes(token: []const u8) []const u8 {
    if (token.len >= 2 and ((token[0] == '"' and token[token.len - 1] == '"') or (token[0] == '\'' and token[token.len - 1] == '\''))) {
        return token[1 .. token.len - 1];
    }
    return token;
}

fn startsWithDigit(text: []const u8) bool {
    return text.len > 0 and text[0] >= '0' and text[0] <= '9';
}

fn parsePositive(text: []const u8) bio.ReaderError!u32 {
    const value = std.fmt.parseInt(u32, text, 10) catch return error.InvalidFormat;
    if (value == 0) return error.InvalidFormat;
    return value;
}

fn countHexBytes(bytes: []const u8) usize {
    var nibbles: usize = 0;
    for (bytes) |byte| {
        if (hexValue(byte) != null) nibbles += 1;
    }
    return nibbles / 2;
}

fn decodeHexBytes(bytes: []const u8, out: []u8) bio.ReaderError!void {
    var high: ?u8 = null;
    var out_pos: usize = 0;
    for (bytes) |byte| {
        const value = hexValue(byte) orelse continue;
        if (high) |h| {
            if (out_pos == out.len) return;
            out[out_pos] = (h << 4) | value;
            out_pos += 1;
            high = null;
        } else {
            high = value;
        }
    }
    if (out_pos != out.len) return error.TruncatedData;
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

const RowInfo = struct {
    line: []const u8,
    next_offset: usize,
};

const RowIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *RowIterator) ?RowInfo {
        while (self.pos < self.data.len) {
            const start = self.pos;
            while (self.pos < self.data.len and self.data[self.pos] != '\n' and self.data[self.pos] != '\r') : (self.pos += 1) {}
            const raw = self.data[start..self.pos];
            while (self.pos < self.data.len and (self.data[self.pos] == '\n' or self.data[self.pos] == '\r')) : (self.pos += 1) {}
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len != 0) return .{ .line = trimmed, .next_offset = self.pos };
        }
        return null;
    }
};

fn rowIterator(data: []const u8) RowIterator {
    return .{ .data = data };
}

const max_tokens = 64;

const TokenList = struct {
    items: [max_tokens][]const u8 = undefined,
    len: usize = 0,
};

fn tokenize(line: []const u8) TokenList {
    var tokens = TokenList{};
    var pos: usize = 0;
    while (pos < line.len) {
        while (pos < line.len and isDelimiter(line[pos])) : (pos += 1) {}
        if (pos >= line.len) break;
        const start = pos;
        while (pos < line.len and !isDelimiter(line[pos])) : (pos += 1) {}
        if (tokens.len == max_tokens) return .{};
        tokens.items[tokens.len] = line[start..pos];
        tokens.len += 1;
    }
    return tokens;
}

fn isDelimiter(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    const samples = std.math.mul(usize, pixels, metadata.samples_per_pixel) catch return error.UnsupportedVariant;
    return std.math.mul(usize, samples, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

test "reads eps grayscale hex pixels" {
    const data =
        \\%!PS-Adobe-3.0 EPSF-3.0
        \\2 1 8 image
        \\0a ff
    ;

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x0a, 0xff }, plane.data);
}

test "reads eps rgb hex pixels from image data declaration" {
    const data =
        \\%!PS-Adobe-3.0 EPSF-3.0
        \\%ImageData: 1 1 8 3 0 1 1 "colorimage"
        \\false 3 colorimage
        \\010203
    ;

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, plane.data);
}

test "reads eps binary pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator,
        \\%!PS-Adobe-3.0 EPSF-3.0
        \\%%BeginBinary
        \\2 1 8 image
        \\
    );
    try data.appendSlice(std.testing.allocator, &.{ 7, 9 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "rejects eps vector-only file" {
    const data =
        \\%!PS-Adobe-3.0 EPSF-3.0
        \\%%BoundingBox: 0 0 10 10
        \\%%EOF
    ;

    try std.testing.expect(!matches(data));
    try std.testing.expectError(error.InvalidFormat, readMetadata(data));
}
