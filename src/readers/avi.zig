const std = @import("std");
const bio = @import("../root.zig");

const bi_rgb = 0;

const Header = struct {
    width: u32,
    height: u32,
    bits_per_pixel: u16,
    compression: u32,
    row_stride: usize,
    frame_count: u32,
    frame_offset: usize = 0,
    frame_len: usize = 0,
};

const ScanState = struct {
    width: u32 = 0,
    height: u32 = 0,
    bits_per_pixel: u16 = 0,
    compression: u32 = bi_rgb,
    frame_count: u32 = 0,
    target_index: ?u32 = null,
    target_offset: usize = 0,
    target_len: usize = 0,
};

pub fn matches(data: []const u8) bool {
    return data.len >= 12 and
        std.mem.eql(u8, data[0..4], "RIFF") and
        std.mem.eql(u8, data[8..12], "AVI ");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data, null);
    return .{
        .format = "avi",
        .width = header.width,
        .height = header.height,
        .size_c = samplesPerPixel(header.bits_per_pixel),
        .samples_per_pixel = samplesPerPixel(header.bits_per_pixel),
        .size_z = 1,
        .size_t = @intCast(@min(header.frame_count, std.math.maxInt(u16))),
        .pixel_type = pixelType(header.bits_per_pixel),
        .little_endian = true,
        .plane_count = header.frame_count,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data, plane_index);
    if (plane_index >= header.frame_count) return error.InvalidPlaneIndex;
    if (header.compression != bi_rgb) return error.UnsupportedVariant;

    const metadata = try readMetadata(data);
    const channels: usize = samplesPerPixel(header.bits_per_pixel);
    const pixels = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, pixels, channels) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    const needed = std.math.mul(usize, header.row_stride, header.height) catch return error.UnsupportedVariant;
    if (header.frame_len < needed) return error.TruncatedData;
    const frame_end = std.math.add(usize, header.frame_offset, needed) catch return error.TruncatedData;
    if (frame_end > data.len) return error.TruncatedData;
    const frame = data[header.frame_offset..frame_end];
    const src_bytes = header.bits_per_pixel / 8;

    var y: usize = 0;
    while (y < header.height) : (y += 1) {
        const src_y = header.height - 1 - y;
        const row = frame[src_y * header.row_stride ..][0..header.row_stride];
        var x: usize = 0;
        while (x < header.width) : (x += 1) {
            const src = x * src_bytes;
            const dst = (y * header.width + x) * channels;
            if (header.bits_per_pixel == 8) {
                out[dst] = row[src];
            } else if (header.bits_per_pixel == 24) {
                out[dst + 0] = row[src + 2];
                out[dst + 1] = row[src + 1];
                out[dst + 2] = row[src + 0];
            } else if (header.bits_per_pixel == 32) {
                out[dst + 0] = row[src + 2];
                out[dst + 1] = row[src + 1];
                out[dst + 2] = row[src + 0];
                out[dst + 3] = row[src + 3];
            } else {
                return error.UnsupportedVariant;
            }
        }
    }

    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8, target_index: ?u32) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    const riff_size = leU32(data[4..8]);
    const riff_end = @min(data.len, 8 + try checkedUsize(riff_size));
    var state = ScanState{ .target_index = target_index };
    try scanChunks(data, 12, riff_end, false, &state);
    if (state.width == 0 or state.height == 0 or state.frame_count == 0) return error.InvalidFormat;
    if (state.compression != bi_rgb) return error.UnsupportedVariant;
    if (state.bits_per_pixel != 8 and state.bits_per_pixel != 24 and state.bits_per_pixel != 32) return error.UnsupportedVariant;
    const row_bits = std.math.mul(usize, state.width, state.bits_per_pixel) catch return error.UnsupportedVariant;
    return .{
        .width = state.width,
        .height = state.height,
        .bits_per_pixel = state.bits_per_pixel,
        .compression = state.compression,
        .row_stride = ((row_bits + 31) / 32) * 4,
        .frame_count = state.frame_count,
        .frame_offset = state.target_offset,
        .frame_len = state.target_len,
    };
}

fn scanChunks(data: []const u8, start: usize, end: usize, inside_movi: bool, state: *ScanState) bio.ReaderError!void {
    var offset = start;
    while (offset + 8 <= end and offset + 8 <= data.len) {
        const chunk_type = data[offset..][0..4];
        const size = try checkedUsize(leU32(data[offset + 4 .. offset + 8]));
        const payload_start = offset + 8;
        const payload_end = std.math.add(usize, payload_start, size) catch return error.TruncatedData;
        if (payload_end > data.len or payload_end > end) return error.TruncatedData;

        if (std.mem.eql(u8, chunk_type, "LIST")) {
            if (size < 4) return error.InvalidFormat;
            const list_type = data[payload_start..][0..4];
            const child_inside_movi = inside_movi or std.mem.eql(u8, list_type, "movi");
            try scanChunks(data, payload_start + 4, payload_end, child_inside_movi, state);
        } else if (std.mem.eql(u8, chunk_type, "avih")) {
            if (size >= 40) {
                state.width = leU32(data[payload_start + 32 .. payload_start + 36]);
                state.height = leU32(data[payload_start + 36 .. payload_start + 40]);
            }
        } else if (std.mem.eql(u8, chunk_type, "strf")) {
            if (size >= 40) {
                const dib_size = leU32(data[payload_start..][0..4]);
                if (dib_size >= 40) {
                    const width = leI32(data[payload_start + 4 .. payload_start + 8]);
                    const height = leI32(data[payload_start + 8 .. payload_start + 12]);
                    if (width > 0) state.width = @intCast(width);
                    if (height != 0) state.height = @intCast(if (height < 0) -height else height);
                    const planes = leU16(data[payload_start + 12 .. payload_start + 14]);
                    if (planes != 1) return error.UnsupportedVariant;
                    state.bits_per_pixel = leU16(data[payload_start + 14 .. payload_start + 16]);
                    state.compression = leU32(data[payload_start + 16 .. payload_start + 20]);
                }
            }
        } else if (inside_movi and isFrameChunk(chunk_type)) {
            if (state.target_index == null or state.target_index.? == state.frame_count) {
                state.target_offset = payload_start;
                state.target_len = size;
            }
            state.frame_count += 1;
        }

        offset = payload_end + (size & 1);
    }
}

fn isFrameChunk(chunk_type: []const u8) bool {
    return chunk_type.len == 4 and
        std.ascii.isDigit(chunk_type[0]) and
        std.ascii.isDigit(chunk_type[1]) and
        chunk_type[2] == 'd' and
        (chunk_type[3] == 'b' or chunk_type[3] == 'c');
}

fn samplesPerPixel(bits_per_pixel: u16) u16 {
    return switch (bits_per_pixel) {
        8 => 1,
        24 => 3,
        32 => 4,
        else => 1,
    };
}

fn pixelType(bits_per_pixel: u16) bio.PixelType {
    return switch (bits_per_pixel) {
        24 => .rgb8,
        32 => .rgba8,
        else => .uint8,
    };
}

fn leU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn leU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn leI32(bytes: []const u8) i32 {
    return std.mem.readInt(i32, bytes[0..4], .little);
}

fn checkedUsize(value: anytype) bio.ReaderError!usize {
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
}

fn appendU16Le(list: *std.ArrayList(u8), value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendU32Le(list: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn startChunk(list: *std.ArrayList(u8), fourcc: []const u8) !usize {
    try list.appendSlice(std.testing.allocator, fourcc);
    const size_pos = list.items.len;
    try appendU32Le(list, 0);
    return size_pos;
}

fn finishChunk(list: *std.ArrayList(u8), size_pos: usize) !void {
    const size = list.items.len - size_pos - 4;
    std.mem.writeInt(u32, list.items[size_pos..][0..4], @intCast(size), .little);
    if ((size & 1) != 0) try list.append(std.testing.allocator, 0);
}

fn appendAviFixture(list: *std.ArrayList(u8), bits_per_pixel: u16, frame1: []const u8, frame2: []const u8) !void {
    const riff = try startChunk(list, "RIFF");
    try list.appendSlice(std.testing.allocator, "AVI ");

    const hdrl = try startChunk(list, "LIST");
    try list.appendSlice(std.testing.allocator, "hdrl");
    const avih = try startChunk(list, "avih");
    try appendU32Le(list, 33333);
    try appendU32Le(list, 0);
    try appendU32Le(list, 0);
    try appendU32Le(list, 0);
    try appendU32Le(list, 2);
    try appendU32Le(list, 0);
    try appendU32Le(list, 1);
    try appendU32Le(list, @intCast(frame1.len));
    try appendU32Le(list, 2);
    try appendU32Le(list, 2);
    while (list.items.len - avih - 4 < 56) try appendU32Le(list, 0);
    try finishChunk(list, avih);

    const strl = try startChunk(list, "LIST");
    try list.appendSlice(std.testing.allocator, "strl");
    const strf = try startChunk(list, "strf");
    try appendU32Le(list, 40);
    try appendU32Le(list, 2);
    try appendU32Le(list, 2);
    try appendU16Le(list, 1);
    try appendU16Le(list, bits_per_pixel);
    try appendU32Le(list, bi_rgb);
    try appendU32Le(list, @intCast(frame1.len));
    try appendU32Le(list, 0);
    try appendU32Le(list, 0);
    try appendU32Le(list, 0);
    try appendU32Le(list, 0);
    try finishChunk(list, strf);
    try finishChunk(list, strl);
    try finishChunk(list, hdrl);

    const movi = try startChunk(list, "LIST");
    try list.appendSlice(std.testing.allocator, "movi");
    const chunk1 = try startChunk(list, "00db");
    try list.appendSlice(std.testing.allocator, frame1);
    try finishChunk(list, chunk1);
    const chunk2 = try startChunk(list, "00db");
    try list.appendSlice(std.testing.allocator, frame2);
    try finishChunk(list, chunk2);
    try finishChunk(list, movi);
    try finishChunk(list, riff);
}

test "reads uncompressed 8-bit avi frames" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendAviFixture(&data, 8, &.{ 3, 4, 0, 0, 1, 2, 0, 0 }, &.{ 7, 8, 0, 0, 5, 6, 0, 0 });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("avi", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const first = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(first.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, first.data);

    const second = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8 }, second.data);
}

test "reads uncompressed 24-bit avi frame as rgb" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendAviFixture(
        &data,
        24,
        &.{ 30, 20, 10, 60, 50, 40, 0, 0, 90, 80, 70, 120, 110, 100, 0, 0 },
        &.{ 3, 2, 1, 6, 5, 4, 0, 0, 9, 8, 7, 12, 11, 10, 0, 0 },
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 70, 80, 90, 100, 110, 120, 10, 20, 30, 40, 50, 60 }, plane.data);
}

test "rejects compressed avi variant" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendAviFixture(&data, 8, &.{ 1, 2, 0, 0, 3, 4, 0, 0 }, &.{ 5, 6, 0, 0, 7, 8, 0, 0 });
    const strf_compression_offset = std.mem.indexOf(u8, data.items, "strf").? + 8 + 16;
    std.mem.writeInt(u32, data.items[strf_compression_offset..][0..4], 1, .little);

    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}
