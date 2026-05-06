const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const header_len = 1024;
const ext_header_size_offset = 92;
const endian_marker_offset = 96;
const time_count_offset = 180;
const sequence_offset = 182;
const channel_count_offset = 196;

const ByteOrder = enum {
    little,
    big,

    fn endian(self: ByteOrder) std.builtin.Endian {
        return switch (self) {
            .little => .little,
            .big => .big,
        };
    }
};

const Header = struct {
    order: ByteOrder,
    width: u32,
    height: u32,
    image_count: u32,
    file_pixel_type: i32,
    ext_header_size: usize,
    size_z: u32,
    size_c: u32,
    size_t: u32,
    image_sequence: []const u8,
    dimension_order: []const u8,

    fn pixelType(self: Header) bio.ReaderError!bio.PixelType {
        return switch (self.file_pixel_type) {
            0 => .uint8,
            1, 3 => .int16,
            2, 4 => .float32,
            6 => .uint16,
            7 => .int32,
            8 => .float64,
            else => error.UnsupportedVariant,
        };
    }
};

const Zct = struct {
    z: u32,
    c: u32,
    t: u32,
};

pub fn matches(data: []const u8) bool {
    if (tiff.matches(data) or data.len < header_len) return false;
    const marker = readU16(.little, data[endian_marker_offset..][0..2]);
    if (marker != 0xa0c0 and marker != 0xc0a0) return false;
    const header = parseHeader(data) catch return false;
    const pixel_type = header.pixelType() catch return false;
    const plane_len = planeByteCount(header.width, header.height, pixel_type) catch return false;
    return data.len >= header_len + header.ext_header_size + plane_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "deltavision",
        .width = header.width,
        .height = header.height,
        .size_c = @intCast(@min(header.size_c, std.math.maxInt(u16))),
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(header.size_z, std.math.maxInt(u16))),
        .size_t = @intCast(@min(header.size_t, std.math.maxInt(u16))),
        .pixel_type = try header.pixelType(),
        .little_endian = header.order == .little,
        .plane_count = header.image_count,
        .dimension_order = header.dimension_order,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const coords = try zctFromPlaneIndex(header, plane_index);
    const file_plane = try filePlaneIndex(header, coords);
    const plane_len = try planeByteCount(header.width, header.height, metadata.pixel_type);
    const plane_offset = std.math.mul(usize, plane_len, file_plane) catch return error.UnsupportedVariant;
    const offset = std.math.add(usize, header_len + header.ext_header_size, plane_offset) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;

    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    copyFlippedRows(data[offset..][0..plane_len], @as(usize, header.width) * metadata.bytesPerPixel(), header.height, out);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_len) return error.InvalidFormat;
    const marker = readU16(.little, data[endian_marker_offset..][0..2]);
    if (marker != 0xa0c0 and marker != 0xc0a0) return error.InvalidFormat;
    const order: ByteOrder = if (std.mem.readInt(i16, data[endian_marker_offset..][0..2], .little) == -16224) .little else .big;
    const width_i = readI32(order, data[0..4]);
    const height_i = readI32(order, data[4..8]);
    const image_count_i = readI32(order, data[8..12]);
    const file_pixel_type = readI32(order, data[12..16]);
    const ext_header_size_i = readI32(order, data[ext_header_size_offset..][0..4]);
    if (width_i <= 0 or height_i <= 0 or image_count_i <= 0 or ext_header_size_i < 0) return error.InvalidFormat;
    const width: u32 = @intCast(width_i);
    const height: u32 = @intCast(height_i);
    const image_count: u32 = @intCast(image_count_i);
    const ext_header_size: usize = @intCast(ext_header_size_i);
    if (header_len + ext_header_size > data.len) return error.TruncatedData;

    const raw_t = readU16(order, data[time_count_offset..][0..2]);
    const raw_c = readU16(order, data[channel_count_offset..][0..2]);
    const size_t: u32 = if (raw_t == 0) 1 else raw_t;
    const size_c: u32 = if (raw_c == 0) 1 else raw_c;
    if (image_count % (size_c * size_t) != 0) return error.InvalidFormat;
    const size_z = image_count / (size_c * size_t);
    if (size_z == 0) return error.InvalidFormat;

    const sequence_code = readU16(order, data[sequence_offset..][0..2]);
    const sequence = imageSequence(sequence_code);
    return .{
        .order = order,
        .width = width,
        .height = height,
        .image_count = image_count,
        .file_pixel_type = file_pixel_type,
        .ext_header_size = ext_header_size,
        .size_z = size_z,
        .size_c = size_c,
        .size_t = size_t,
        .image_sequence = sequence,
        .dimension_order = dimensionOrder(sequence),
    };
}

fn zctFromPlaneIndex(header: Header, plane_index: u32) bio.ReaderError!Zct {
    var remaining = plane_index;
    var z: u32 = 0;
    var c: u32 = 0;
    var t: u32 = 0;
    for (header.dimension_order[2..]) |axis| {
        switch (axis) {
            'Z' => {
                z = remaining % header.size_z;
                remaining /= header.size_z;
            },
            'C' => {
                c = remaining % header.size_c;
                remaining /= header.size_c;
            },
            'T' => {
                t = remaining % header.size_t;
                remaining /= header.size_t;
            },
            else => {},
        }
    }
    if (remaining != 0) return error.InvalidPlaneIndex;
    return .{ .z = z, .c = c, .t = t };
}

fn filePlaneIndex(header: Header, coords: Zct) bio.ReaderError!usize {
    var index: usize = 0;
    var stride: usize = 1;
    for (header.image_sequence) |axis| {
        const value: u32 = switch (axis) {
            'Z' => coords.z,
            'W' => coords.c,
            'T' => coords.t,
            'P' => 0,
            else => 0,
        };
        const len: u32 = switch (axis) {
            'Z' => header.size_z,
            'W' => header.size_c,
            'T' => header.size_t,
            'P' => 1,
            else => 1,
        };
        if (value >= len) return error.InvalidPlaneIndex;
        index += @as(usize, value) * stride;
        stride = std.math.mul(usize, stride, len) catch return error.UnsupportedVariant;
    }
    return index;
}

fn dimensionOrder(sequence: []const u8) []const u8 {
    if (std.mem.eql(u8, sequence, "WZTP")) return "XYCZT";
    if (std.mem.eql(u8, sequence, "ZWTP")) return "XYZCT";
    if (std.mem.eql(u8, sequence, "ZPWT")) return "XYZCT";
    if (std.mem.eql(u8, sequence, "ZWPT")) return "XYZCT";
    if (std.mem.eql(u8, sequence, "WZPT")) return "XYCZT";
    if (std.mem.eql(u8, sequence, "WPTZ")) return "XYCTZ";
    if (std.mem.eql(u8, sequence, "PWTZ")) return "XYCTZ";
    if (std.mem.eql(u8, sequence, "PTWZ")) return "XYTCZ";
    if (std.mem.eql(u8, sequence, "PZWT")) return "XYZCT";
    if (std.mem.eql(u8, sequence, "PWZT")) return "XYCZT";
    if (std.mem.eql(u8, sequence, "WPZT")) return "XYCZT";
    if (std.mem.eql(u8, sequence, "WTPZ")) return "XYCTZ";
    if (std.mem.eql(u8, sequence, "TWPZ")) return "XYTCZ";
    if (std.mem.eql(u8, sequence, "TPWZ")) return "XYTCZ";
    return "XYZTC";
}

fn imageSequence(code: u16) []const u8 {
    return switch (code) {
        1 => "WZTP",
        2 => "ZWTP",
        3 => "ZPWT",
        4 => "ZWPT",
        5 => "WZPT",
        6 => "WPTZ",
        7 => "PWTZ",
        8 => "PTWZ",
        9 => "PZWT",
        10 => "PWZT",
        11 => "WPZT",
        12 => "WTPZ",
        13 => "TWPZ",
        14 => "TPWZ",
        else => "ZTWP",
    };
}

fn planeByteCount(width: u32, height: u32, pixel_type: bio.PixelType) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, width, height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn copyFlippedRows(src: []const u8, row_bytes: usize, height: u32, out: []u8) void {
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src_row = (@as(usize, height) - 1 - y) * row_bytes;
        const dst_row = y * row_bytes;
        @memcpy(out[dst_row..][0..row_bytes], src[src_row..][0..row_bytes]);
    }
}

fn readU16(order: ByteOrder, bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], order.endian());
}

fn readI32(order: ByteOrder, bytes: []const u8) i32 {
    return std.mem.readInt(i32, bytes[0..4], order.endian());
}

fn setU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn setI16(bytes: []u8, offset: usize, value: i16) void {
    std.mem.writeInt(i16, bytes[offset..][0..2], value, .little);
}

fn setI32(bytes: []u8, offset: usize, value: i32) void {
    std.mem.writeInt(i32, bytes[offset..][0..4], value, .little);
}

fn appendHeader(list: *std.ArrayList(u8), width: i32, height: i32, planes: i32, pixel_type: i32, ext_header_size: i32, size_t: u16, size_c: u16, sequence: u16) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_len);
    setI32(list.items, 0, width);
    setI32(list.items, 4, height);
    setI32(list.items, 8, planes);
    setI32(list.items, 12, pixel_type);
    setI32(list.items, ext_header_size_offset, ext_header_size);
    setI16(list.items, endian_marker_offset, -16224);
    setU16(list.items, time_count_offset, size_t);
    setU16(list.items, sequence_offset, sequence);
    setU16(list.items, channel_count_offset, size_c);
}

test "reads deltavision uint16 z plane with flipped rows" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 2, 2, 2, 6, 4, 1, 1, 0);
    try data.appendSlice(std.testing.allocator, &.{ 9, 9, 9, 9 });
    try data.appendSlice(std.testing.allocator, &.{
        1, 0, 2, 0, 3, 0, 4, 0,
        5, 0, 6, 0, 7, 0, 8, 0,
    });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("deltavision", metadata.format);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 0, 8, 0, 5, 0, 6, 0 }, plane.data);
}

test "maps deltavision channel-first sequence" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, 1, 1, 2, 0, 0, 1, 2, 1);
    try data.appendSlice(std.testing.allocator, &.{ 10, 20 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{20}, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "rejects tiff as deltavision" {
    try std.testing.expect(!matches("II*\x00"));
}

test "matches Bio-Formats metadata and plane hashes for cached DeltaVision fixture" {
    const file_path = "fixtures/cache/deltavision/U2OS_AurB_AurA_001_R3D.dv";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("deltavision", metadata.format);
    try std.testing.expectEqual(@as(u32, 512), metadata.width);
    try std.testing.expectEqual(@as(u32, 512), metadata.height);
    try std.testing.expectEqual(@as(u16, 4), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 20), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 80), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 1), metadata.series_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYZCT", metadata.dimension_order.?);

    const expected = [_]struct { plane: u32, sha256: [32]u8 }{
        .{ .plane = 0, .sha256 = .{ 0x54, 0x59, 0xf7, 0x7c, 0x6f, 0xf9, 0xfe, 0x4f, 0xbb, 0x68, 0x2a, 0xe8, 0x90, 0x8d, 0x1e, 0xe7, 0x6c, 0x0b, 0x58, 0x10, 0xa2, 0x47, 0x41, 0xce, 0x13, 0xd4, 0x4e, 0x7a, 0xf6, 0x07, 0x6e, 0x04 } },
        .{ .plane = 40, .sha256 = .{ 0xc0, 0x6f, 0x15, 0xb5, 0x48, 0x9a, 0xe8, 0x06, 0x03, 0x55, 0xe0, 0x8d, 0x02, 0x38, 0x53, 0xc9, 0xa1, 0xb7, 0x70, 0x56, 0xd4, 0xe7, 0x93, 0x74, 0xb0, 0xd5, 0x26, 0x17, 0x44, 0x88, 0x78, 0xe8 } },
        .{ .plane = 79, .sha256 = .{ 0x7d, 0x0b, 0x23, 0x74, 0x9d, 0x39, 0x3d, 0x47, 0x91, 0xc0, 0x8d, 0xa5, 0x35, 0x53, 0xbc, 0x44, 0xe7, 0xf0, 0xcc, 0xbf, 0x8a, 0xa6, 0x73, 0xb3, 0xdb, 0x74, 0xb5, 0xa8, 0x5d, 0x83, 0xd7, 0x67 } },
    };
    for (expected) |sample| {
        const plane = try readPlaneIndex(std.testing.allocator, data, sample.plane);
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqual(@as(usize, 524288), plane.data.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
        try std.testing.expectEqualSlices(u8, &sample.sha256, &digest);
    }
}
