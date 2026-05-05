const std = @import("std");
const bio = @import("../root.zig");

const magic = "SURFACE WIND COMPONENTS";

const Header = struct {
    width: u32,
    height: u32,
    data_start: usize,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    return countPairs(data[header.data_start..]) >= @as(usize, header.width) * header.height;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "hrdgdf",
        .width = header.width,
        .height = header.height,
        .size_c = 2,
        .samples_per_pixel = 1,
        .pixel_type = .float64,
        .little_endian = false,
        .plane_count = 2,
        .dimension_order = "XYCTZ",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    if (plane_index >= 2) return error.InvalidPlaneIndex;
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    const out = try allocator.alloc(u8, try planeByteCount(metadata));
    errdefer allocator.free(out);
    try populatePlane(data[header.data_start..], metadata, plane_index, out);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    var rows = rowIterator(data);
    var offset: usize = 0;
    while (rows.next()) |row_info| {
        defer offset = row_info.next_offset;
        if (std.mem.startsWith(u8, row_info.line, magic)) {
            const dims_info = rows.next() orelse return error.TruncatedData;
            const dims = try parseDimensions(dims_info.line);
            return .{ .width = dims.width, .height = dims.height, .data_start = dims_info.next_offset };
        }
    }
    return error.InvalidFormat;
}

const Dimensions = struct {
    width: u32,
    height: u32,
};

fn parseDimensions(line: []const u8) bio.ReaderError!Dimensions {
    var it = std.mem.tokenizeAny(u8, line, " \t,");
    const width_text = it.next() orelse return error.InvalidFormat;
    const height_text = it.next() orelse return error.InvalidFormat;
    const width = std.fmt.parseInt(u32, width_text, 10) catch return error.InvalidFormat;
    const height = std.fmt.parseInt(u32, height_text, 10) catch return error.InvalidFormat;
    if (width == 0 or height == 0) return error.InvalidFormat;
    return .{ .width = width, .height = height };
}

fn populatePlane(text: []const u8, metadata: bio.Metadata, plane_index: u32, out: []u8) bio.ReaderError!void {
    var pair_it = pairIterator(text);
    var index: usize = 0;
    const pixels = @as(usize, metadata.width) * metadata.height;
    while (index < pixels) : (index += 1) {
        const pair = pair_it.next() orelse return error.TruncatedData;
        const value = if (plane_index == 0) pair.east_west else pair.north_south;
        std.mem.writeInt(u64, out[index * 8 ..][0..8], @bitCast(value), .big);
    }
}

fn countPairs(text: []const u8) usize {
    var it = pairIterator(text);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    return count;
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

const Pair = struct {
    east_west: f64,
    north_south: f64,
};

const PairIterator = struct {
    text: []const u8,
    pos: usize = 0,

    fn next(self: *PairIterator) ?Pair {
        while (self.pos < self.text.len) {
            const open_rel = std.mem.indexOfScalar(u8, self.text[self.pos..], '(') orelse return null;
            const open = self.pos + open_rel;
            const close_rel = std.mem.indexOfScalar(u8, self.text[open + 1 ..], ')') orelse return null;
            const close = open + 1 + close_rel;
            self.pos = close + 1;
            const pair_text = self.text[open + 1 .. close];
            const comma = std.mem.indexOfScalar(u8, pair_text, ',') orelse continue;
            const left = std.mem.trim(u8, pair_text[0..comma], " \t");
            const right = std.mem.trim(u8, pair_text[comma + 1 ..], " \t");
            const ew = std.fmt.parseFloat(f64, left) catch continue;
            const ns = std.fmt.parseFloat(f64, right) catch continue;
            return .{ .east_west = ew, .north_south = ns };
        }
        return null;
    }
};

fn pairIterator(text: []const u8) PairIterator {
    return .{ .text = text };
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

test "reads hrd gdf paired wind component planes" {
    const data =
        \\HURRICANE TEST
        \\DX 1 KM
        \\STORM CENTER LOCALE IS -80.0 X X X X 25.0
        \\SURFACE WIND COMPONENTS
        \\2 2
        \\(1.5, 2.5) (3.5, 4.5)
        \\(5.5, 6.5) (7.5, 8.5)
    ;

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.float64, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 2.5))), std.mem.readInt(u64, plane.data[0..8], .big));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 8.5))), std.mem.readInt(u64, plane.data[24..32], .big));
}

test "rejects hrd gdf missing pairs" {
    const data =
        \\SURFACE WIND COMPONENTS
        \\2 1
        \\(1, 2)
    ;

    try std.testing.expect(!matches(data));
    try std.testing.expectError(error.TruncatedData, readPlaneIndex(std.testing.allocator, data, 0));
}

test "rejects hrd gdf without marker" {
    const data =
        \\2 1
        \\(1, 2) (3, 4)
    ;

    try std.testing.expect(!matches(data));
    try std.testing.expectError(error.InvalidFormat, readMetadata(data));
}
