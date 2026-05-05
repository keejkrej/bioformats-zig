const std = @import("std");
const bio = @import("../root.zig");

const Header = struct {
    width: u32,
    height: u32,
    depth: u32,
    pixel_type: bio.PixelType,
    little_endian: bool,
    data_offset: usize,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "amira",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
    }) catch return false;
    const pixels_len = std.math.mul(usize, plane_len, header.depth) catch return false;
    return data.len >= header.data_offset and data.len - header.data_offset >= pixels_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "amira",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.depth, std.math.maxInt(u16))),
        .pixel_type = header.pixel_type,
        .little_endian = header.little_endian,
        .plane_count = header.depth,
        .dimension_order = "XYZCT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const offset = header.data_offset + plane_len * @as(usize, plane_index);
    if (data.len < offset or data.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    var rows = rowIterator(data);
    const first = rows.next() orelse return error.TruncatedData;
    if (!(std.mem.startsWith(u8, first.line, "# AmiraMesh") or std.mem.startsWith(u8, first.line, "# Avizo"))) return error.InvalidFormat;
    if (std.mem.indexOf(u8, first.line, "BINARY") == null) return error.UnsupportedVariant;
    if (std.mem.indexOf(u8, first.line, "ASCII") != null) return error.UnsupportedVariant;
    const little_endian = std.mem.indexOf(u8, first.line, "BINARY-LITTLE-ENDIAN") != null;

    var width: u32 = 0;
    var height: u32 = 0;
    var depth: u32 = 1;
    var pixel_type: ?bio.PixelType = null;
    var stream_count: u32 = 0;

    while (rows.next()) |row| {
        const line = row.line;
        if (std.mem.startsWith(u8, line, "#")) continue;
        if (std.mem.startsWith(u8, line, "@")) {
            const stream_id = parseStreamMarker(line) catch return error.InvalidFormat;
            if (stream_id != 1) return error.UnsupportedVariant;
            if (width == 0 or height == 0 or pixel_type == null) return error.InvalidFormat;
            if (stream_count != 1) return error.UnsupportedVariant;
            return .{
                .width = width,
                .height = height,
                .depth = depth,
                .pixel_type = pixel_type.?,
                .little_endian = little_endian,
                .data_offset = row.next_offset,
            };
        }
        if (std.mem.startsWith(u8, line, "define Lattice")) {
            const dims = try parseLatticeDimensions(line);
            width = dims.width;
            height = dims.height;
            depth = dims.depth;
        } else if (std.mem.startsWith(u8, line, "Lattice")) {
            stream_count += 1;
            if (std.mem.indexOf(u8, line, "HxZip") != null or std.mem.indexOf(u8, line, "HxByteRLE") != null) return error.UnsupportedVariant;
            pixel_type = try parseStreamType(line);
        }
    }
    return error.InvalidFormat;
}

const Dimensions = struct {
    width: u32,
    height: u32,
    depth: u32,
};

fn parseLatticeDimensions(line: []const u8) bio.ReaderError!Dimensions {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    _ = it.next() orelse return error.InvalidFormat;
    _ = it.next() orelse return error.InvalidFormat;
    const width = parsePositive(it.next() orelse return error.InvalidFormat);
    const height = parsePositive(it.next() orelse return error.InvalidFormat);
    const depth = if (it.next()) |value| parsePositive(value) else 1;
    return .{ .width = try width, .height = try height, .depth = try depth };
}

fn parseStreamType(line: []const u8) bio.ReaderError!bio.PixelType {
    const open = std.mem.indexOfScalar(u8, line, '{') orelse return error.InvalidFormat;
    const close = std.mem.indexOfScalarPos(u8, line, open + 1, '}') orelse return error.InvalidFormat;
    var it = std.mem.tokenizeAny(u8, line[open + 1 .. close], " \t");
    const type_name = it.next() orelse return error.InvalidFormat;
    if (std.mem.eql(u8, type_name, "byte")) return .uint8;
    if (std.mem.eql(u8, type_name, "short")) return .int16;
    if (std.mem.eql(u8, type_name, "ushort")) return .uint16;
    if (std.mem.eql(u8, type_name, "int")) return .int32;
    if (std.mem.eql(u8, type_name, "float")) return .float32;
    return error.UnsupportedVariant;
}

fn parseStreamMarker(line: []const u8) bio.ReaderError!u32 {
    if (line.len < 2 or line[0] != '@') return error.InvalidFormat;
    var end: usize = 1;
    while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {}
    if (end == 1) return error.InvalidFormat;
    if (std.mem.trim(u8, line[end..], " \t").len != 0) return error.InvalidFormat;
    return parsePositive(line[1..end]);
}

fn parsePositive(text: []const u8) bio.ReaderError!u32 {
    const value = std.fmt.parseInt(u32, text, 10) catch return error.InvalidFormat;
    if (value == 0) return error.InvalidFormat;
    return value;
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

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

test "reads amira little-endian ushort z planes" {
    const header =
        \\# AmiraMesh BINARY-LITTLE-ENDIAN 2.1
        \\define Lattice 2 1 2
        \\Lattice { ushort Data } @1
        \\@1
        \\
    ;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, header);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0 });
    try data.appendSlice(std.testing.allocator, &.{ 3, 0, 4, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 4, 0 }, plane.data);
}

test "reads amira big-endian float plane" {
    const header =
        \\# Avizo BINARY 2.1
        \\define Lattice 1 1 1
        \\Lattice { float Data } @1
        \\@1
        \\
    ;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, header);
    try data.appendSlice(std.testing.allocator, &.{ 0x3f, 0x80, 0, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x3f, 0x80, 0, 0 }, plane.data);
}

test "rejects amira ascii variant" {
    const data =
        \\# AmiraMesh ASCII 2.1
        \\define Lattice 1 1 1
        \\Lattice { byte Data } @1
        \\@1
        \\7
    ;
    try std.testing.expect(!matches(data));
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data));
}

test "rejects truncated amira pixels" {
    const header =
        \\# AmiraMesh BINARY 2.1
        \\define Lattice 2 1 1
        \\Lattice { byte Data } @1
        \\@1
        \\
    ;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, header);
    try data.append(std.testing.allocator, 1);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlaneIndex(std.testing.allocator, data.items, 0));
}
