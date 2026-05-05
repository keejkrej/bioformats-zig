const std = @import("std");
const bio = @import("../root.zig");

const Header = struct {
    header_row: usize,
    row_len: usize,
    x_index: usize,
    y_index: usize,
    channels: u16,
    width: u32,
    height: u32,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "text",
        .width = header.width,
        .height = header.height,
        .size_c = header.channels,
        .samples_per_pixel = 1,
        .pixel_type = .float32,
        .little_endian = false,
        .plane_count = header.channels,
        .dimension_order = "XYZCT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    if (plane_index >= header.channels) return error.InvalidPlaneIndex;
    const metadata = try readMetadata(data);
    const plane_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    fillNaN(out);
    try populatePlane(data, header, @intCast(plane_index), out);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    var rows = rowIterator(data);
    var last_tokens: ?TokenList = null;
    var row_number: usize = 0;
    while (rows.next()) |line| {
        defer row_number += 1;
        const tokens = tokenize(line);
        if (tokens.len < 3) continue;
        if (last_tokens) |previous| {
            if (previous.len == tokens.len and rowIsNumeric(tokens)) {
                const columns = parseColumns(previous) catch {
                    last_tokens = tokens;
                    continue;
                };
                var header = Header{
                    .header_row = row_number - 1,
                    .row_len = tokens.len,
                    .x_index = columns.x_index,
                    .y_index = columns.y_index,
                    .channels = columns.channels,
                    .width = 0,
                    .height = 0,
                };
                try scanExtents(data, &header);
                if (header.width == 0 or header.height == 0) return error.InvalidFormat;
                return header;
            }
        }
        last_tokens = tokens;
    }
    return error.InvalidFormat;
}

const Columns = struct {
    x_index: usize,
    y_index: usize,
    channels: u16,
};

fn parseColumns(tokens: TokenList) bio.ReaderError!Columns {
    var x_index: ?usize = null;
    var y_index: ?usize = null;
    var channels: u16 = 0;
    for (tokens.items[0..tokens.len], 0..) |token, i| {
        if (std.mem.eql(u8, token, "x")) {
            x_index = i;
        } else if (std.mem.eql(u8, token, "y")) {
            y_index = i;
        } else {
            channels += 1;
        }
    }
    if (x_index == null or y_index == null or channels == 0) return error.InvalidFormat;
    return .{ .x_index = x_index.?, .y_index = y_index.?, .channels = channels };
}

fn scanExtents(data: []const u8, header: *Header) bio.ReaderError!void {
    var rows = rowIterator(data);
    var row_number: usize = 0;
    while (rows.next()) |line| : (row_number += 1) {
        if (row_number <= header.header_row) continue;
        const tokens = tokenize(line);
        if (tokens.len != header.row_len or !rowIsNumeric(tokens)) continue;
        const x = try coordinate(tokens.items[header.x_index]);
        const y = try coordinate(tokens.items[header.y_index]);
        header.width = @max(header.width, x + 1);
        header.height = @max(header.height, y + 1);
    }
}

fn populatePlane(data: []const u8, header: Header, requested_channel: usize, out: []u8) bio.ReaderError!void {
    var rows = rowIterator(data);
    var row_number: usize = 0;
    while (rows.next()) |line| : (row_number += 1) {
        if (row_number <= header.header_row) continue;
        const tokens = tokenize(line);
        if (tokens.len != header.row_len or !rowIsNumeric(tokens)) continue;
        const x = try coordinate(tokens.items[header.x_index]);
        const y = try coordinate(tokens.items[header.y_index]);
        if (x >= header.width or y >= header.height) return error.InvalidFormat;

        var channel: usize = 0;
        for (tokens.items[0..tokens.len], 0..) |token, i| {
            if (i == header.x_index or i == header.y_index) continue;
            if (channel == requested_channel) {
                const value = std.fmt.parseFloat(f32, token) catch return error.InvalidFormat;
                const offset = (@as(usize, y) * header.width + x) * 4;
                std.mem.writeInt(u32, out[offset..][0..4], @bitCast(value), .big);
                break;
            }
            channel += 1;
        }
    }
}

fn coordinate(token: []const u8) bio.ReaderError!u32 {
    const value = std.fmt.parseFloat(f64, token) catch return error.InvalidFormat;
    if (!std.math.isFinite(value) or value < 0 or @floor(value) != value) return error.InvalidFormat;
    if (value > std.math.maxInt(u32)) return error.UnsupportedVariant;
    return @intFromFloat(value);
}

fn rowIsNumeric(tokens: TokenList) bool {
    for (tokens.items[0..tokens.len]) |token| {
        _ = std.fmt.parseFloat(f64, token) catch return false;
    }
    return true;
}

fn fillNaN(bytes: []u8) void {
    var offset: usize = 0;
    while (offset + 4 <= bytes.len) : (offset += 4) {
        std.mem.writeInt(u32, bytes[offset..][0..4], @bitCast(std.math.nan(f32)), .big);
    }
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

const RowIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *RowIterator) ?[]const u8 {
        while (self.pos < self.data.len) {
            const start = self.pos;
            while (self.pos < self.data.len and self.data[self.pos] != '\n' and self.data[self.pos] != '\r') : (self.pos += 1) {}
            const raw = self.data[start..self.pos];
            while (self.pos < self.data.len and (self.data[self.pos] == '\n' or self.data[self.pos] == '\r')) : (self.pos += 1) {}
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len != 0) return trimmed;
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
    return byte == ',' or byte == ' ' or byte == '\t';
}

test "reads text table float channel planes" {
    const data =
        \\x,y,a,b
        \\0,0,1.5,2.5
        \\1,0,3.5,4.5
        \\0,1,5.5,6.5
    ;

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 2.5))), std.mem.readInt(u32, plane.data[0..4], .big));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 4.5))), std.mem.readInt(u32, plane.data[4..8], .big));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 6.5))), std.mem.readInt(u32, plane.data[8..12], .big));
}

test "text table fills missing samples with nan" {
    const data =
        \\x y value
        \\1 0 7
    ;

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    const missing: f32 = @bitCast(std.mem.readInt(u32, plane.data[0..4], .big));
    try std.testing.expect(std.math.isNan(missing));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 7))), std.mem.readInt(u32, plane.data[4..8], .big));
}

test "rejects text table without x y header" {
    const data =
        \\row,value
        \\0,1
    ;

    try std.testing.expect(!matches(data));
    try std.testing.expectError(error.InvalidFormat, readMetadata(data));
}
