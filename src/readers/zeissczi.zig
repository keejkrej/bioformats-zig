const std = @import("std");
const bio = @import("../root.zig");

const alignment = 32;
const segment_header_size = 32;
const czi_magic = "ZISRAWFILE";
const subblock_id = "ZISRAWSUBBLOCK";

const gray8 = 0;
const gray16 = 1;
const gray_float = 2;
const bgr_24 = 3;
const bgr_48 = 4;
const bgr_float = 8;
const bgra_8 = 9;
const gray32 = 12;
const gray_double = 13;
const uncompressed = 0;

const Scan = struct {
    width: u32 = 0,
    height: u32 = 0,
    size_c: u16 = 1,
    size_z: u16 = 1,
    size_t: u16 = 1,
    pixel_type: bio.PixelType = .uint8,
    samples: u16 = 1,
    plane_count: u32 = 0,
};

pub fn matches(data: []const u8) bool {
    return data.len >= czi_magic.len and std.mem.eql(u8, data[0..czi_magic.len], czi_magic);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!matches(data)) return error.InvalidFormat;
    const scan = try scanSegments(data);
    if (scan.width == 0 or scan.height == 0 or scan.plane_count == 0) return error.InvalidFormat;
    return .{
        .format = "zeissczi",
        .width = scan.width,
        .height = scan.height,
        .size_c = scan.size_c,
        .samples_per_pixel = scan.samples,
        .size_z = scan.size_z,
        .size_t = scan.size_t,
        .pixel_type = scan.pixel_type,
        .little_endian = true,
        .plane_count = scan.plane_count,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const block = try findSubBlock(data, plane_index);
    if (block.compression != uncompressed) return error.UnsupportedVariant;
    if (block.width != metadata.width or block.height != metadata.height) return error.UnsupportedVariant;
    if (metadata.samples_per_pixel != 1) return error.UnsupportedVariant;

    const plane_len = try planeByteCount(metadata);
    if (block.data_size < plane_len) return error.TruncatedData;
    if (block.data_size != plane_len) return error.UnsupportedVariant;
    if (block.data_offset > data.len or data.len - block.data_offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    @memcpy(out, data[block.data_offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

const SubBlockRef = struct {
    data_offset: usize,
    data_size: usize,
    compression: u32,
    width: u32,
    height: u32,
};

fn scanSegments(data: []const u8) bio.ReaderError!Scan {
    var scan = Scan{};
    var pos: usize = 0;
    while (pos + segment_header_size <= data.len) {
        pos = alignForward(pos);
        if (pos + segment_header_size > data.len) break;
        const id = trimSegmentId(data[pos..][0..16]);
        const allocated = try checkedUsize(leU64(data[pos + 16 ..][0..8]));
        const used = try checkedUsize(leU64(data[pos + 24 ..][0..8]));
        const payload_len = if (used == 0) allocated else used;
        const payload_start = pos + segment_header_size;
        const payload_end = std.math.add(usize, payload_start, payload_len) catch return error.UnsupportedVariant;
        if (payload_end > data.len) return error.TruncatedData;

        if (std.mem.eql(u8, id, subblock_id)) {
            try parseSubBlock(data[payload_start..payload_end], &scan);
        }

        const next = std.math.add(usize, payload_start, allocated) catch return error.UnsupportedVariant;
        if (next <= pos) return error.InvalidFormat;
        pos = next;
    }
    return scan;
}

fn parseSubBlock(payload: []const u8, scan: *Scan) bio.ReaderError!void {
    if (payload.len < 256) return error.TruncatedData;
    const data_size = leU64(payload[8..16]);
    _ = data_size;
    const entry = try parseDirectoryEntry(payload[16..]);
    const pixel = pixelType(entry.pixel_type);
    scan.pixel_type = pixel.pixel_type;
    scan.samples = pixel.samples;
    if (pixel.samples > 1) scan.size_c = @max(scan.size_c, pixel.samples);

    for (entry.dimensions.items()) |dimension| {
        switch (dimension.name) {
            'X' => scan.width = @max(scan.width, dimension.size),
            'Y' => scan.height = @max(scan.height, dimension.size),
            'C' => scan.size_c = @max(scan.size_c, boundedDimension(dimension.start + dimension.size)),
            'Z' => scan.size_z = @max(scan.size_z, boundedDimension(dimension.start + dimension.size)),
            'T' => scan.size_t = @max(scan.size_t, boundedDimension(dimension.start + dimension.size)),
            else => {},
        }
    }
    scan.plane_count += 1;
}

fn findSubBlock(data: []const u8, plane_index: u32) bio.ReaderError!SubBlockRef {
    var pos: usize = 0;
    var count: u32 = 0;
    while (pos + segment_header_size <= data.len) {
        pos = alignForward(pos);
        if (pos + segment_header_size > data.len) break;
        const id = trimSegmentId(data[pos..][0..16]);
        const allocated = try checkedUsize(leU64(data[pos + 16 ..][0..8]));
        const used = try checkedUsize(leU64(data[pos + 24 ..][0..8]));
        const payload_len = if (used == 0) allocated else used;
        const payload_start = pos + segment_header_size;
        const payload_end = std.math.add(usize, payload_start, payload_len) catch return error.UnsupportedVariant;
        if (payload_end > data.len) return error.TruncatedData;

        if (std.mem.eql(u8, id, subblock_id)) {
            if (count == plane_index) return try parseSubBlockRef(data[payload_start..payload_end], payload_start);
            count += 1;
        }

        const next = std.math.add(usize, payload_start, allocated) catch return error.UnsupportedVariant;
        if (next <= pos) return error.InvalidFormat;
        pos = next;
    }
    return error.InvalidPlaneIndex;
}

fn parseSubBlockRef(payload: []const u8, payload_start: usize) bio.ReaderError!SubBlockRef {
    if (payload.len < 256) return error.TruncatedData;
    const metadata_size = try checkedUsize(leU32(payload[0..4]));
    const data_size = try checkedUsize(leU64(payload[8..16]));
    const entry = try parseDirectoryEntry(payload[16..]);
    var width: u32 = 0;
    var height: u32 = 0;
    for (entry.dimensions.items()) |dimension| {
        switch (dimension.name) {
            'X' => width = dimension.size,
            'Y' => height = dimension.size,
            else => {},
        }
    }
    if (width == 0 or height == 0) return error.InvalidFormat;
    const data_base = std.math.add(usize, payload_start, 256) catch return error.UnsupportedVariant;
    const data_offset = std.math.add(usize, data_base, metadata_size) catch return error.UnsupportedVariant;
    const payload_end = std.math.add(usize, payload_start, payload.len) catch return error.UnsupportedVariant;
    if (data_offset > payload_end or payload_end - data_offset < data_size) return error.TruncatedData;
    return .{
        .data_offset = data_offset,
        .data_size = data_size,
        .compression = entry.compression,
        .width = width,
        .height = height,
    };
}

const DirectoryEntry = struct {
    pixel_type: u32,
    compression: u32,
    dimensions: DimensionList,
};

const DimensionList = struct {
    values: [16]Dimension = undefined,
    len: usize = 0,

    fn append(self: *DimensionList, value: Dimension) bio.ReaderError!void {
        if (self.len >= self.values.len) return error.UnsupportedVariant;
        self.values[self.len] = value;
        self.len += 1;
    }

    fn items(self: *const DimensionList) []const Dimension {
        return self.values[0..self.len];
    }
};

const Dimension = struct {
    name: u8,
    start: u32,
    size: u32,
};

fn parseDirectoryEntry(data: []const u8) bio.ReaderError!DirectoryEntry {
    if (data.len < 32) return error.TruncatedData;
    const pixel_type = leU32(data[2..6]);
    const compression = leU32(data[18..22]);
    const dimension_count = leU32(data[28..32]);
    if (dimension_count == 0 or dimension_count > 16) return error.UnsupportedVariant;
    if (data.len < 32 + @as(usize, dimension_count) * 20) return error.TruncatedData;
    var dimensions = DimensionList{};
    var pos: usize = 32;
    var i: u32 = 0;
    while (i < dimension_count) : (i += 1) {
        const raw_name = std.mem.trim(u8, data[pos..][0..4], " \x00");
        if (raw_name.len == 1) {
            const start = leI32(data[pos + 4 ..][0..4]);
            try dimensions.append(.{
                .name = raw_name[0],
                .start = if (start < 0) 0 else @intCast(start),
                .size = leU32(data[pos + 8 ..][0..4]),
            });
        }
        pos += 20;
    }
    return .{ .pixel_type = pixel_type, .compression = compression, .dimensions = dimensions };
}

const Pixel = struct {
    pixel_type: bio.PixelType,
    samples: u16,
};

fn pixelType(value: u32) Pixel {
    return switch (value) {
        gray16 => .{ .pixel_type = .uint16, .samples = 1 },
        gray32 => .{ .pixel_type = .uint32, .samples = 1 },
        gray_float => .{ .pixel_type = .float32, .samples = 1 },
        gray_double => .{ .pixel_type = .float64, .samples = 1 },
        bgr_24 => .{ .pixel_type = .rgb8, .samples = 3 },
        bgr_48 => .{ .pixel_type = .rgb16, .samples = 3 },
        bgr_float => .{ .pixel_type = .rgb16, .samples = 3 },
        bgra_8 => .{ .pixel_type = .rgba8, .samples = 4 },
        else => .{ .pixel_type = .uint8, .samples = 1 },
    };
}

fn boundedDimension(value: u32) u16 {
    return @intCast(@min(@max(value, 1), std.math.maxInt(u16)));
}

fn trimSegmentId(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \x00");
}

fn alignForward(pos: usize) usize {
    return pos + ((alignment - (pos % alignment)) % alignment);
}

fn leU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn leI32(bytes: []const u8) i32 {
    return std.mem.readInt(i32, bytes[0..4], .little);
}

fn leU64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}

fn checkedUsize(value: anytype) bio.ReaderError!usize {
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn appendSegment(allocator: std.mem.Allocator, out: *std.ArrayList(u8), id: []const u8, payload: []const u8) !void {
    while (out.items.len % alignment != 0) try out.append(allocator, 0);
    var id_bytes: [16]u8 = @splat(0);
    @memcpy(id_bytes[0..id.len], id);
    try out.appendSlice(allocator, &id_bytes);
    try appendU64Le(allocator, out, @intCast(payload.len));
    try appendU64Le(allocator, out, @intCast(payload.len));
    try out.appendSlice(allocator, payload);
}

fn appendDimension(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, start: u32, size: u32) !void {
    var dim: [4]u8 = @splat(0);
    @memcpy(dim[0..name.len], name);
    try out.appendSlice(allocator, &dim);
    try appendU32Le(allocator, out, start);
    try appendU32Le(allocator, out, size);
    try appendU32Le(allocator, out, 0);
    try appendU32Le(allocator, out, size);
}

fn appendU32Le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn appendU64Le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn appendZeros(allocator: std.mem.Allocator, out: *std.ArrayList(u8), count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try out.append(allocator, 0);
}

fn minimalCzi(allocator: std.mem.Allocator, pixel_type: u32) ![]u8 {
    return minimalCziWithPixelsAndDims(allocator, pixel_type, &.{}, 2, 3, 4);
}

fn minimalCziWithPixels(allocator: std.mem.Allocator, pixel_type: u32, pixels: []const u8) ![]u8 {
    return minimalCziWithPixelsAndDims(allocator, pixel_type, pixels, 1, 1, 1);
}

fn minimalCziWithPixelsAndDims(allocator: std.mem.Allocator, pixel_type: u32, pixels: []const u8, size_c: u32, size_z: u32, size_t: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});

    var sub: std.ArrayList(u8) = .empty;
    defer sub.deinit(allocator);
    try appendU32Le(allocator, &sub, 0);
    try appendU32Le(allocator, &sub, 0);
    try appendU64Le(allocator, &sub, @intCast(pixels.len));
    try sub.appendSlice(allocator, "DV");
    try appendU32Le(allocator, &sub, pixel_type);
    try appendU64Le(allocator, &sub, 0);
    try appendU32Le(allocator, &sub, 0);
    try appendU32Le(allocator, &sub, 0);
    try sub.append(allocator, 0);
    try sub.append(allocator, 0);
    try appendU32Le(allocator, &sub, 0);
    try appendU32Le(allocator, &sub, 5);
    try appendDimension(allocator, &sub, "X", 0, 11);
    try appendDimension(allocator, &sub, "Y", 0, 7);
    try appendDimension(allocator, &sub, "C", 0, size_c);
    try appendDimension(allocator, &sub, "Z", 0, size_z);
    try appendDimension(allocator, &sub, "T", 0, size_t);
    if (sub.items.len < 256) try appendZeros(allocator, &sub, 256 - sub.items.len);
    try sub.appendSlice(allocator, pixels);
    try appendSegment(allocator, &out, subblock_id, sub.items);
    return out.toOwnedSlice(allocator);
}

test "reads zeiss czi subblock metadata" {
    const data = try minimalCzi(std.testing.allocator, gray16);
    defer std.testing.allocator.free(data);

    try std.testing.expect(matches(data));
    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("zeissczi", metadata.format);
    try std.testing.expectEqual(@as(u32, 11), metadata.width);
    try std.testing.expectEqual(@as(u32, 7), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 4), metadata.size_t);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
}

test "reports bgr czi as rgb metadata" {
    const data = try minimalCzi(std.testing.allocator, bgr_24);
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
}

test "reads uncompressed zeiss czi subblock plane" {
    const pixels = [_]u8{ 1, 0 } ** (11 * 7);
    const data = try minimalCziWithPixels(std.testing.allocator, gray16, &pixels);
    defer std.testing.allocator.free(data);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zeissczi", plane.metadata.format);
    try std.testing.expectEqual(bio.PixelType.uint16, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &pixels, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data, 1));
}
