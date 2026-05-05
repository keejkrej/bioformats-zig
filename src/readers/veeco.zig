const std = @import("std");
const bio = @import("../root.zig");

const magic_cdf1 = "CDF\x01";
const magic_cdf2 = "CDF\x02";
const nc_dimension: u32 = 10;
const nc_variable: u32 = 11;
const nc_attribute: u32 = 12;

const NcType = enum {
    byte,
    char,
    short,
    int,
    float,
    double,
};

const Dim = struct {
    name: []const u8,
    len: u32,
};

const Header = struct {
    width: u32,
    height: u32,
    pixel_type: bio.PixelType,
    pixel_offset: usize,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "veeco",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
    }) catch return false;
    return data.len >= header.pixel_offset and data.len - header.pixel_offset >= plane_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "veeco",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
        .little_endian = false,
        .plane_count = 1,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    if (plane_index != 0) return error.InvalidPlaneIndex;
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    const plane_len = try planeByteCount(metadata);
    if (data.len < header.pixel_offset or data.len - header.pixel_offset < plane_len) return error.TruncatedData;

    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    const row_bytes = std.math.mul(usize, metadata.width, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
    var row: usize = 0;
    while (row < metadata.height) : (row += 1) {
        const src_row = @as(usize, metadata.height) - row - 1;
        const src_offset = header.pixel_offset + src_row * row_bytes;
        const dst_offset = row * row_bytes;
        @memcpy(out[dst_offset..][0..row_bytes], data[src_offset..][0..row_bytes]);
    }
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < 4) return error.TruncatedData;
    const cdf2 = if (std.mem.eql(u8, data[0..4], magic_cdf1))
        false
    else if (std.mem.eql(u8, data[0..4], magic_cdf2))
        true
    else
        return error.InvalidFormat;

    var cursor = Cursor{ .data = data, .pos = 4, .cdf2 = cdf2 };
    _ = try cursor.readU32();

    var dims: [16]Dim = undefined;
    const dim_count = try cursor.readDims(&dims);
    try cursor.skipAttrs();

    const var_tag = try cursor.readU32();
    const var_count = try cursor.readU32();
    if (var_tag == 0 and var_count == 0) return error.InvalidFormat;
    if (var_tag != nc_variable) return error.InvalidFormat;

    var i: u32 = 0;
    while (i < var_count) : (i += 1) {
        _ = try cursor.readName();
        const rank = try cursor.readU32();
        if (rank > 8) return error.UnsupportedVariant;
        var dim_ids: [8]u32 = undefined;
        var dim_i: u32 = 0;
        while (dim_i < rank) : (dim_i += 1) {
            dim_ids[dim_i] = try cursor.readU32();
            if (dim_ids[dim_i] >= dim_count) return error.InvalidFormat;
        }
        try cursor.skipAttrs();
        const nc_type = try parseNcType(try cursor.readU32());
        _ = try cursor.readU32();
        const begin = try cursor.readBegin();

        if (rank == 2 and (nc_type == .byte or nc_type == .short)) {
            const height = dims[dim_ids[0]].len;
            const width = dims[dim_ids[1]].len;
            if (width == 0 or height == 0) return error.InvalidFormat;
            return .{
                .width = width,
                .height = height,
                .pixel_type = switch (nc_type) {
                    .byte => .int8,
                    .short => .int16,
                    else => unreachable,
                },
                .pixel_offset = begin,
            };
        }
    }
    return error.UnsupportedVariant;
}

const Cursor = struct {
    data: []const u8,
    pos: usize,
    cdf2: bool,

    fn readU32(self: *Cursor) bio.ReaderError!u32 {
        if (self.pos > self.data.len or self.data.len - self.pos < 4) return error.TruncatedData;
        const value = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
        self.pos += 4;
        return value;
    }

    fn readBegin(self: *Cursor) bio.ReaderError!usize {
        if (!self.cdf2) return @intCast(try self.readU32());
        if (self.pos > self.data.len or self.data.len - self.pos < 8) return error.TruncatedData;
        const value = std.mem.readInt(u64, self.data[self.pos..][0..8], .big);
        self.pos += 8;
        if (value > std.math.maxInt(usize)) return error.UnsupportedVariant;
        return @intCast(value);
    }

    fn readName(self: *Cursor) bio.ReaderError![]const u8 {
        const len = try self.readU32();
        const name_len: usize = @intCast(len);
        if (self.pos > self.data.len or self.data.len - self.pos < name_len) return error.TruncatedData;
        const name = self.data[self.pos..][0..name_len];
        self.pos += align4(name_len);
        if (self.pos > self.data.len) return error.TruncatedData;
        return name;
    }

    fn readDims(self: *Cursor, dims: *[16]Dim) bio.ReaderError!usize {
        const tag = try self.readU32();
        const count = try self.readU32();
        if (tag == 0 and count == 0) return 0;
        if (tag != nc_dimension or count > dims.len) return error.UnsupportedVariant;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            dims[i] = .{
                .name = try self.readName(),
                .len = try self.readU32(),
            };
        }
        return @intCast(count);
    }

    fn skipAttrs(self: *Cursor) bio.ReaderError!void {
        const tag = try self.readU32();
        const count = try self.readU32();
        if (tag == 0 and count == 0) return;
        if (tag != nc_attribute) return error.InvalidFormat;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            _ = try self.readName();
            const nc_type = try parseNcType(try self.readU32());
            const len = try self.readU32();
            const byte_len = try attrByteLen(nc_type, len);
            if (self.pos > self.data.len or self.data.len - self.pos < byte_len) return error.TruncatedData;
            self.pos += align4(byte_len);
            if (self.pos > self.data.len) return error.TruncatedData;
        }
    }
};

fn parseNcType(raw_type: u32) bio.ReaderError!NcType {
    return switch (raw_type) {
        1 => .byte,
        2 => .char,
        3 => .short,
        4 => .int,
        5 => .float,
        6 => .double,
        else => error.UnsupportedVariant,
    };
}

fn attrByteLen(nc_type: NcType, count: u32) bio.ReaderError!usize {
    const sample_bytes: usize = switch (nc_type) {
        .byte, .char => 1,
        .short => 2,
        .int, .float => 4,
        .double => 8,
    };
    return std.math.mul(usize, @intCast(count), sample_bytes) catch return error.UnsupportedVariant;
}

fn align4(value: usize) usize {
    return (value + 3) & ~@as(usize, 3);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn appendU32(list: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendName(list: *std.ArrayList(u8), name: []const u8) !void {
    try appendU32(list, @intCast(name.len));
    try list.appendSlice(std.testing.allocator, name);
    try list.appendNTimes(std.testing.allocator, 0, align4(name.len) - name.len);
}

fn appendClassicNetcdf(list: *std.ArrayList(u8), nc_type: NcType, width: u32, height: u32) !usize {
    try list.appendSlice(std.testing.allocator, magic_cdf1);
    try appendU32(list, 0);
    try appendU32(list, nc_dimension);
    try appendU32(list, 2);
    try appendName(list, "y");
    try appendU32(list, height);
    try appendName(list, "x");
    try appendU32(list, width);
    try appendU32(list, 0);
    try appendU32(list, 0);
    try appendU32(list, nc_variable);
    try appendU32(list, 1);
    try appendName(list, "image");
    try appendU32(list, 2);
    try appendU32(list, 0);
    try appendU32(list, 1);
    try appendU32(list, 0);
    try appendU32(list, 0);
    try appendU32(list, switch (nc_type) {
        .byte => 1,
        .char => 2,
        .short => 3,
        .int => 4,
        .float => 5,
        .double => 6,
    });
    const plane_bytes = try attrByteLen(nc_type, width * height);
    try appendU32(list, @intCast(plane_bytes));
    const begin_pos = list.items.len;
    try appendU32(list, 0);
    const pixel_offset = align4(list.items.len);
    try list.appendNTimes(std.testing.allocator, 0, pixel_offset - list.items.len);
    std.mem.writeInt(u32, list.items[begin_pos..][0..4], @intCast(pixel_offset), .big);
    return pixel_offset;
}

test "reads veeco byte netcdf image with row normalization" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    _ = try appendClassicNetcdf(&data, .byte, 2, 2);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("veeco", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(bio.PixelType.int8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4, 1, 2 }, plane.data);
}

test "reads veeco short netcdf image" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    _ = try appendClassicNetcdf(&data, .short, 2, 1);
    try data.appendSlice(std.testing.allocator, &.{ 0, 1, 0, 2 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.int16, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 2 }, plane.data);
}

test "rejects truncated veeco pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    _ = try appendClassicNetcdf(&data, .byte, 2, 1);
    try data.append(std.testing.allocator, 1);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}
