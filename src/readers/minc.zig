const std = @import("std");
const bio = @import("../root.zig");

const magic_cdf1 = "CDF\x01";
const magic_cdf2 = "CDF\x02";
const nc_dimension: u32 = 10;
const nc_variable: u32 = 11;
const nc_attribute: u32 = 12;

const NcType = enum(u32) {
    byte = 1,
    char = 2,
    short = 3,
    int = 4,
    float = 5,
    double = 6,
};

const Dim = struct {
    name: []const u8,
    len: u32,
};

const Header = struct {
    width: u32,
    height: u32,
    size_z: u16,
    size_t: u16,
    pixel_type: bio.PixelType,
    pixel_offset: usize,
    plane_count: u32,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "minc",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
    }) catch return false;
    const pixel_bytes = std.math.mul(usize, plane_len, header.plane_count) catch return false;
    return data.len >= header.pixel_offset and data.len - header.pixel_offset >= pixel_bytes;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "minc",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = header.size_z,
        .size_t = header.size_t,
        .pixel_type = header.pixel_type,
        .little_endian = false,
        .plane_count = header.plane_count,
        .dimension_order = "XYZCT",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const offset = std.math.add(usize, header.pixel_offset, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;

    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    const row_bytes = std.math.mul(usize, metadata.width, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
    var row: usize = 0;
    while (row < metadata.height) : (row += 1) {
        const src_row = @as(usize, metadata.height) - row - 1;
        const src_offset = offset + src_row * row_bytes;
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

    var image: ?Header = null;
    var i: u32 = 0;
    while (i < var_count) : (i += 1) {
        const var_name = try cursor.readName();
        const rank = try cursor.readU32();
        if (rank == 0 or rank > 8) return error.UnsupportedVariant;
        var dim_ids: [8]u32 = undefined;
        var dim_i: u32 = 0;
        while (dim_i < rank) : (dim_i += 1) {
            dim_ids[dim_i] = try cursor.readU32();
            if (dim_ids[dim_i] >= dim_count) return error.InvalidFormat;
        }

        const signed = try cursor.readVarAttrs();
        const raw_type = try cursor.readU32();
        const nc_type = parseNcType(raw_type) catch return error.UnsupportedVariant;
        _ = try cursor.readU32();
        const begin = try cursor.readBegin();

        if (std.mem.eql(u8, var_name, "image")) {
            image = try headerFromVariable(dims[0..dim_count], dim_ids[0..rank], nc_type, signed, begin);
        }
    }

    return image orelse error.InvalidFormat;
}

fn headerFromVariable(dims: []const Dim, dim_ids: []const u32, nc_type: NcType, signed: bool, begin: usize) bio.ReaderError!Header {
    if (dim_ids.len < 2) return error.InvalidFormat;
    const width_dim = dims[dim_ids[dim_ids.len - 1]];
    const height_dim = dims[dim_ids[dim_ids.len - 2]];
    if (width_dim.len == 0 or height_dim.len == 0) return error.InvalidFormat;

    var plane_count: u32 = 1;
    var i: usize = 0;
    while (i + 2 < dim_ids.len) : (i += 1) {
        plane_count = std.math.mul(u32, plane_count, dims[dim_ids[i]].len) catch return error.UnsupportedVariant;
    }
    if (plane_count == 0) return error.InvalidFormat;

    const size_z: u16 = @intCast(@min(plane_count, std.math.maxInt(u16)));
    return .{
        .width = width_dim.len,
        .height = height_dim.len,
        .size_z = size_z,
        .size_t = 1,
        .pixel_type = try pixelType(nc_type, signed),
        .pixel_offset = begin,
        .plane_count = plane_count,
    };
}

fn pixelType(nc_type: NcType, signed: bool) bio.ReaderError!bio.PixelType {
    return switch (nc_type) {
        .byte => if (signed) .int8 else .uint8,
        .short => if (signed) .int16 else .uint16,
        .int => if (signed) .int32 else .uint32,
        .float => .float32,
        .double => .float64,
        .char => error.UnsupportedVariant,
    };
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
        if (len > std.math.maxInt(usize)) return error.UnsupportedVariant;
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
        _ = try self.readAttrs(false);
    }

    fn readVarAttrs(self: *Cursor) bio.ReaderError!bool {
        return self.readAttrs(true);
    }

    fn readAttrs(self: *Cursor, capture_signtype: bool) bio.ReaderError!bool {
        const tag = try self.readU32();
        const count = try self.readU32();
        if (tag == 0 and count == 0) return false;
        if (tag != nc_attribute) return error.InvalidFormat;

        var signed = false;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const name = try self.readName();
            const raw_type = try self.readU32();
            const nc_type = parseNcType(raw_type) catch return error.UnsupportedVariant;
            const len = try self.readU32();
            const byte_len = attrByteLen(nc_type, len) catch return error.UnsupportedVariant;
            if (self.pos > self.data.len or self.data.len - self.pos < byte_len) return error.TruncatedData;
            if (capture_signtype and nc_type == .char and std.mem.eql(u8, name, "signtype")) {
                const value = std.mem.trim(u8, self.data[self.pos..][0..byte_len], " \t\r\n\x00");
                signed = std.mem.startsWith(u8, value, "signed");
            }
            self.pos += align4(byte_len);
            if (self.pos > self.data.len) return error.TruncatedData;
        }
        return signed;
    }
};

fn attrByteLen(nc_type: NcType, count: u32) bio.ReaderError!usize {
    const sample_bytes: usize = switch (nc_type) {
        .byte, .char => 1,
        .short => 2,
        .int, .float => 4,
        .double => 8,
    };
    return std.math.mul(usize, @intCast(count), sample_bytes) catch return error.UnsupportedVariant;
}

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

fn appendAttrString(list: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    try appendName(list, name);
    try appendU32(list, @intFromEnum(NcType.char));
    try appendU32(list, @intCast(value.len));
    try list.appendSlice(std.testing.allocator, value);
    try list.appendNTimes(std.testing.allocator, 0, align4(value.len) - value.len);
}

fn appendClassicMinc(list: *std.ArrayList(u8), pixel_type: NcType, signtype: []const u8, width: u32, height: u32, planes: u32) !usize {
    try list.appendSlice(std.testing.allocator, magic_cdf1);
    try appendU32(list, 0);
    try appendU32(list, nc_dimension);
    try appendU32(list, 3);
    try appendName(list, "zspace");
    try appendU32(list, planes);
    try appendName(list, "yspace");
    try appendU32(list, height);
    try appendName(list, "xspace");
    try appendU32(list, width);
    try appendU32(list, 0);
    try appendU32(list, 0);
    try appendU32(list, nc_variable);
    try appendU32(list, 1);
    try appendName(list, "image");
    try appendU32(list, 3);
    try appendU32(list, 0);
    try appendU32(list, 1);
    try appendU32(list, 2);
    try appendU32(list, nc_attribute);
    try appendU32(list, 1);
    try appendAttrString(list, "signtype", signtype);
    try appendU32(list, @intFromEnum(pixel_type));
    const plane_bytes = width * height * try attrByteLen(pixel_type, 1);
    try appendU32(list, @intCast(plane_bytes * planes));
    const begin_pos = list.items.len;
    try appendU32(list, 0);
    const pixel_offset = align4(list.items.len);
    try list.appendNTimes(std.testing.allocator, 0, pixel_offset - list.items.len);
    std.mem.writeInt(u32, list.items[begin_pos..][0..4], @intCast(pixel_offset), .big);
    return pixel_offset;
}

test "reads minc v1 uint16 z planes with row normalization" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    _ = try appendClassicMinc(&data, .short, "unsigned", 2, 2, 2);
    try data.appendSlice(std.testing.allocator, &.{
        0, 1, 0, 2, 0, 3, 0, 4,
        0, 5, 0, 6, 0, 7, 0, 8,
    });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 3, 0, 4, 0, 1, 0, 2 }, plane.data);

    const second = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 7, 0, 8, 0, 5, 0, 6 }, second.data);
}

test "reads minc signed byte pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    _ = try appendClassicMinc(&data, .byte, "signed__", 2, 1, 1);
    try data.appendSlice(std.testing.allocator, &.{ 0xff, 0x7f });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.int8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x7f }, plane.data);
}

test "rejects truncated minc pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    _ = try appendClassicMinc(&data, .short, "unsigned", 2, 1, 1);
    try data.append(std.testing.allocator, 0);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.TruncatedData, readPlane(std.testing.allocator, data.items));
}
