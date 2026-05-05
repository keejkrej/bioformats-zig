const std = @import("std");
const bio = @import("../root.zig");

const dm3_magic: u32 = 3;
const dm4_magic: u32 = 4;
const tag_group: u8 = 20;
const tag_value: u8 = 21;

const data_group: u32 = 20;
const data_array: u32 = 15;
const data_short: u32 = 2;
const data_ushort: u32 = 4;
const data_int: u32 = 3;
const data_uint: u32 = 5;
const data_float: u32 = 6;
const data_double: u32 = 7;
const data_byte: u32 = 8;
const data_ubyte: u32 = 9;
const data_char: u32 = 10;
const data_unknown: u32 = 11;
const data_unknown2: u32 = 12;
const string_type: u32 = 18;
const signature: u32 = 0x25252525;

const Parsed = struct {
    version: u32,
    width: u32 = 0,
    height: u32 = 0,
    size_z: u32 = 1,
    pixel_offset: usize = 0,
    pixel_bytes: usize = 0,
    pixel_type: ?bio.PixelType = null,
    signed: bool = false,
};

const Parser = struct {
    data: []const u8,
    pos: usize = 0,
    version: u32 = 0,
    endian: std.builtin.Endian = .big,
    adjust_endianness: bool = true,
    parsed: Parsed = .{ .version = 0 },

    fn init(data: []const u8) bio.ReaderError!Parser {
        if (data.len < 18) return error.TruncatedData;
        const version = std.mem.readInt(u32, data[0..4], .big);
        if (version != dm3_magic and version != dm4_magic) return error.InvalidFormat;

        var p = Parser{
            .data = data,
            .pos = 4,
            .version = version,
            .parsed = .{ .version = version },
        };
        try p.skip(4);
        try p.skipPadding();
        const byte_order = try p.readU32(.big);
        p.endian = if (byte_order == 1) .big else .little;
        return p;
    }

    fn parse(self: *Parser) bio.ReaderError!Parsed {
        try self.skip(2);
        try self.skipPadding();
        var num_tags = try self.readU32(self.endian);
        if (num_tags > self.data.len) {
            self.endian = if (self.endian == .little) .big else .little;
            self.adjust_endianness = false;
            self.pos -= 4;
            num_tags = try self.readU32(self.endian);
        }
        try self.parseTags(num_tags, null);
        if (self.parsed.width == 0 or self.parsed.height == 0 or self.parsed.pixel_bytes == 0) return error.InvalidFormat;
        return self.parsed;
    }

    fn parseTags(self: *Parser, num_tags: u32, parent: ?[]const u8) bio.ReaderError!void {
        var i: u32 = 0;
        while (i < num_tags) : (i += 1) {
            if (self.pos + 3 >= self.data.len) break;
            const kind = try self.readU8();
            const label_len = try self.readU16(self.endian);
            switch (kind) {
                tag_value => try self.parseValue(label_len, parent, i),
                tag_group => try self.parseGroup(label_len, parent),
                23 => {
                    try self.skip(5);
                    if (i > 0) i -= 1;
                },
                else => return error.UnsupportedVariant,
            }
        }
    }

    fn parseGroup(self: *Parser, label_len: u16, parent: ?[]const u8) bio.ReaderError!void {
        const label = try self.readBytes(label_len);
        try self.skip(2);
        try self.skipPadding();
        try self.skipPadding();
        try self.skipPadding();
        const num = try self.readU32(self.endian);
        const child_parent = if (label.len == 0) parent else label;
        try self.parseTags(num, child_parent);
    }

    fn parseValue(self: *Parser, label_len: u16, parent: ?[]const u8, index: u32) bio.ReaderError!void {
        const label = try self.readBytes(label_len);
        try self.skipPadding();
        try self.skipPadding();
        _ = try self.readU32(self.endian);
        try self.skipPadding();
        const n = try self.readU32(self.endian);
        try self.skipPadding();
        const data_type = try self.readU32(self.endian);

        if (n == 1) {
            const number = try self.readNumber(data_type);
            if (parent) |p| {
                if (std.mem.eql(u8, p, "Dimensions") and label.len == 0) {
                    const value: u32 = @intFromFloat(@max(number, 0));
                    if (index == 0) self.parsed.width = value else if (index == 1) self.parsed.height = value else if (index == 2) self.parsed.size_z = @max(value, 1);
                    return;
                }
            }
            if (std.mem.eql(u8, label, "DataType")) {
                self.parsed.pixel_type = gatanPixelType(@intFromFloat(number));
            } else if (std.mem.eql(u8, label, "LowLimit")) {
                self.parsed.signed = number < 0;
            }
        } else if (n == 2) {
            if (data_type != string_type) return error.UnsupportedVariant;
            const len = try self.readU32(self.endian);
            _ = try self.readBytes(@intCast(len));
        } else if (n == 3) {
            if (data_type != data_group) return error.UnsupportedVariant;
            try self.skipPadding();
            const element_type = try self.readU32(self.endian);
            const count = if (self.version == dm4_magic) try self.readU64(self.endian) else try self.readU32(self.endian);
            const byte_count = std.math.mul(usize, @intCast(count), typeByteCount(element_type) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
            if (std.mem.eql(u8, label, "Data")) {
                self.parsed.pixel_offset = self.pos;
                self.parsed.pixel_bytes = byte_count;
                try self.skip(byte_count);
            } else {
                try self.skip(byte_count);
            }
        } else if (data_type == data_array) {
            try self.skipArrayStruct();
        } else if (data_type == data_group) {
            try self.skipArrayOfStructs();
        } else {
            return error.UnsupportedVariant;
        }
    }

    fn skipArrayStruct(self: *Parser) bio.ReaderError!void {
        try self.skip(4);
        try self.skipPadding();
        try self.skipPadding();
        const fields = try self.readU32(self.endian);
        const start = self.pos;
        try self.skip(4);
        try self.skipPadding();
        var base = self.pos;
        if (self.version == dm4_magic) base += 4;
        const width: usize = if (self.version == dm4_magic) 16 else 8;
        var payload: usize = 0;
        var j: u32 = 0;
        while (j < fields) : (j += 1) {
            self.pos = base + @as(usize, j) * width;
            const data_type = try self.readU32(self.endian);
            payload += typeByteCount(data_type) catch return error.UnsupportedVariant;
        }
        self.pos = start + @as(usize, fields) * width + payload;
        if (self.pos > self.data.len) return error.TruncatedData;
    }

    fn skipArrayOfStructs(self: *Parser) bio.ReaderError!void {
        try self.skipPadding();
        const data_type = try self.readU32(self.endian);
        if (data_type != data_array) return error.UnsupportedVariant;
        try self.skip(4);
        try self.skipPadding();
        try self.skipPadding();
        const fields = try self.readU32(self.endian);
        var field_bytes: usize = 0;
        const base = self.pos + 12;
        var j: u32 = 0;
        while (j < fields) : (j += 1) {
            try self.skip(4);
            if (self.version == dm4_magic) self.pos = base + @as(usize, j) * 16;
            field_bytes += typeByteCount(try self.readU32(self.endian)) catch return error.UnsupportedVariant;
        }
        try self.skipPadding();
        const len = try self.readU32(self.endian);
        try self.skip(std.math.mul(usize, field_bytes, len) catch return error.UnsupportedVariant);
    }

    fn valueEndian(self: Parser, data_type: u32) std.builtin.Endian {
        if (!self.adjust_endianness) return self.endian;
        return switch (data_type) {
            data_int, data_uint, data_float, data_double, data_unknown, data_unknown2 => if (self.endian == .little) .big else .little,
            else => self.endian,
        };
    }

    fn readNumber(self: *Parser, data_type: u32) bio.ReaderError!f64 {
        const endian = self.valueEndian(data_type);
        return switch (data_type) {
            data_short => @floatFromInt(@as(i16, @bitCast(try self.readU16(endian)))),
            data_ushort => @floatFromInt(try self.readU16(endian)),
            data_int => @floatFromInt(@as(i32, @bitCast(try self.readU32(endian)))),
            data_uint => @floatFromInt(try self.readU32(endian)),
            data_float => @floatCast(@as(f32, @bitCast(try self.readU32(endian)))),
            data_double => @as(f64, @bitCast(try self.readU64(endian))),
            data_byte, data_ubyte, data_char => @floatFromInt(try self.readU8()),
            data_unknown, data_unknown2 => @floatFromInt(try self.readU64(endian)),
            else => error.UnsupportedVariant,
        };
    }

    fn skipPadding(self: *Parser) bio.ReaderError!void {
        if (self.version == dm4_magic) try self.skip(4);
    }

    fn skip(self: *Parser, count: usize) bio.ReaderError!void {
        if (self.pos > self.data.len or self.data.len - self.pos < count) return error.TruncatedData;
        self.pos += count;
    }

    fn readBytes(self: *Parser, count: usize) bio.ReaderError![]const u8 {
        if (self.pos > self.data.len or self.data.len - self.pos < count) return error.TruncatedData;
        const out = self.data[self.pos..][0..count];
        self.pos += count;
        return out;
    }

    fn readU8(self: *Parser) bio.ReaderError!u8 {
        if (self.pos >= self.data.len) return error.TruncatedData;
        const value = self.data[self.pos];
        self.pos += 1;
        return value;
    }

    fn readU16(self: *Parser, endian: std.builtin.Endian) bio.ReaderError!u16 {
        const bytes = try self.readBytes(2);
        return std.mem.readInt(u16, bytes[0..2], endian);
    }

    fn readU32(self: *Parser, endian: std.builtin.Endian) bio.ReaderError!u32 {
        const bytes = try self.readBytes(4);
        return std.mem.readInt(u32, bytes[0..4], endian);
    }

    fn readU64(self: *Parser, endian: std.builtin.Endian) bio.ReaderError!u64 {
        const bytes = try self.readBytes(8);
        return std.mem.readInt(u64, bytes[0..8], endian);
    }
};

pub fn matches(data: []const u8) bool {
    const parsed = parse(data) catch return false;
    const metadata = metadataFromParsed(parsed) catch return false;
    const plane_len = planeByteCount(metadata) catch return false;
    return parsed.pixel_offset <= data.len and data.len - parsed.pixel_offset >= plane_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    return metadataFromParsed(try parse(data));
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const parsed = try parse(data);
    const metadata = try metadataFromParsed(parsed);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const plane_offset = std.math.add(usize, parsed.pixel_offset, std.math.mul(usize, plane_len, plane_index) catch return error.InvalidPlaneIndex) catch return error.InvalidPlaneIndex;
    if (plane_offset > data.len or data.len - plane_offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, data[plane_offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parse(data: []const u8) bio.ReaderError!Parsed {
    var parser = try Parser.init(data);
    return parser.parse();
}

fn metadataFromParsed(parsed: Parsed) bio.ReaderError!bio.Metadata {
    const size_z = @max(parsed.size_z, 1);
    const inferred_type = try inferPixelType(parsed);
    return .{
        .format = "gatan",
        .width = parsed.width,
        .height = parsed.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(size_z, std.math.maxInt(u16))),
        .pixel_type = inferred_type,
        .little_endian = true,
        .plane_count = size_z,
        .dimension_order = "XYZTC",
    };
}

fn inferPixelType(parsed: Parsed) bio.ReaderError!bio.PixelType {
    const pixels = std.math.mul(usize, parsed.width, parsed.height) catch return error.UnsupportedVariant;
    const total_pixels = std.math.mul(usize, pixels, @max(parsed.size_z, 1)) catch return error.UnsupportedVariant;
    if (total_pixels == 0 or parsed.pixel_bytes % total_pixels != 0) return error.InvalidFormat;
    const bytes = parsed.pixel_bytes / total_pixels;
    if (parsed.pixel_type) |pixel_type| {
        if (pixel_type.bytesPerSample() == bytes) return pixel_type;
    }
    return pixelTypeFromBytes(bytes, parsed.signed);
}

fn gatanPixelType(value: u32) ?bio.PixelType {
    return switch (value) {
        1 => .int16,
        10 => .uint16,
        2 => .float32,
        12 => .float64,
        9 => .int8,
        6 => .uint8,
        7 => .int32,
        11 => .uint32,
        else => null,
    };
}

fn pixelTypeFromBytes(bytes: usize, signed: bool) bio.ReaderError!bio.PixelType {
    return switch (bytes) {
        1 => if (signed) .int8 else .uint8,
        2 => if (signed) .int16 else .uint16,
        4 => if (signed) .int32 else .uint32,
        8 => .float64,
        else => error.UnsupportedVariant,
    };
}

fn typeByteCount(data_type: u32) bio.ReaderError!usize {
    return switch (data_type) {
        data_short, data_ushort => 2,
        data_int, data_uint, data_float => 4,
        data_double => 8,
        data_byte, data_ubyte, data_char => 1,
        data_unknown, data_unknown2 => 8,
        else => error.UnsupportedVariant,
    };
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn appendU16(list: *std.ArrayList(u8), value: u16, endian: std.builtin.Endian) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, endian);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendU32(list: *std.ArrayList(u8), value: u32, endian: std.builtin.Endian) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, endian);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendHeader(list: *std.ArrayList(u8), num_tags: u32) !void {
    try appendU32(list, dm3_magic, .big);
    try appendU32(list, 0, .big);
    try appendU32(list, 1, .big);
    try list.appendSlice(std.testing.allocator, &.{ 0, 0 });
    try appendU32(list, num_tags, .big);
}

fn appendGroupHeader(list: *std.ArrayList(u8), label: []const u8, num_tags: u32) !void {
    try list.append(std.testing.allocator, tag_group);
    try appendU16(list, @intCast(label.len), .big);
    try list.appendSlice(std.testing.allocator, label);
    try list.appendSlice(std.testing.allocator, &.{ 0, 0 });
    try appendU32(list, num_tags, .big);
}

fn appendNumericTag(list: *std.ArrayList(u8), label: []const u8, value: u32) !void {
    try list.append(std.testing.allocator, tag_value);
    try appendU16(list, @intCast(label.len), .big);
    try list.appendSlice(std.testing.allocator, label);
    try appendU32(list, signature, .big);
    try appendU32(list, 1, .big);
    try appendU32(list, data_int, .big);
    try appendU32(list, value, .little);
}

fn appendDataTag(list: *std.ArrayList(u8), pixels: []const u8, element_type: u32) !void {
    try list.append(std.testing.allocator, tag_value);
    try appendU16(list, 4, .big);
    try list.appendSlice(std.testing.allocator, "Data");
    try appendU32(list, signature, .big);
    try appendU32(list, 3, .big);
    try appendU32(list, data_group, .big);
    try appendU32(list, element_type, .big);
    try appendU32(list, @intCast(pixels.len / (typeByteCount(element_type) catch unreachable)), .big);
    try list.appendSlice(std.testing.allocator, pixels);
}

test "reads gatan dm3 uint8 pixels" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 3);
    try appendGroupHeader(&data, "Dimensions", 2);
    try appendNumericTag(&data, "", 2);
    try appendNumericTag(&data, "", 1);
    try appendNumericTag(&data, "DataType", 6);
    try appendDataTag(&data, &.{ 11, 12 }, data_ubyte);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("gatan", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 11, 12 }, plane.data);
}

test "reads second gatan dm3 z plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 3);
    try appendGroupHeader(&data, "Dimensions", 3);
    try appendNumericTag(&data, "", 1);
    try appendNumericTag(&data, "", 1);
    try appendNumericTag(&data, "", 2);
    try appendNumericTag(&data, "DataType", 10);
    try appendDataTag(&data, &.{ 0x01, 0x00, 0x02, 0x00 }, data_ushort);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x00 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}
