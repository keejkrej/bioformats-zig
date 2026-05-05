const std = @import("std");
const bio = @import("../root.zig");
const png = @import("png.zig");

const mng_signature = "\x8aMNG\r\n\x1a\n";
const png_signature = "\x89PNG\r\n\x1a\n";

pub fn matches(data: []const u8) bool {
    if (data.len < mng_signature.len or !std.mem.eql(u8, data[0..mng_signature.len], mng_signature)) return false;
    var pos: usize = mng_signature.len;
    const first = nextChunk(data, &pos) catch return false;
    return std.mem.eql(u8, first.kind, "MHDR");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const allocator = std.heap.page_allocator;
    const png_data = try firstPngImage(allocator, data);
    defer allocator.free(png_data);

    var metadata = try png.readMetadata(png_data);
    metadata.format = "mng";
    metadata.size_z = 1;
    metadata.size_t = 1;
    metadata.plane_count = 1;
    metadata.dimension_order = "XYCTZ";
    return metadata;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    if (plane_index != 0) return error.InvalidPlaneIndex;
    const png_data = try firstPngImage(allocator, data);
    defer allocator.free(png_data);

    var plane = try png.readPlane(allocator, png_data);
    plane.metadata.format = "mng";
    plane.metadata.size_z = 1;
    plane.metadata.size_t = 1;
    plane.metadata.plane_count = 1;
    plane.metadata.dimension_order = "XYCTZ";
    return plane;
}

fn firstPngImage(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError![]u8 {
    if (!matches(data)) return error.InvalidFormat;
    var pos: usize = mng_signature.len;
    _ = try nextChunk(data, &pos);

    var image_start: ?usize = null;
    var image_end: ?usize = null;
    while (pos < data.len) {
        const chunk_start = pos;
        const chunk = try nextChunk(data, &pos);
        if (std.mem.eql(u8, chunk.kind, "JHDR") or std.mem.eql(u8, chunk.kind, "JDAT")) return error.UnsupportedVariant;
        if (std.mem.eql(u8, chunk.kind, "IHDR") and image_start == null) {
            image_start = chunk_start;
        } else if (std.mem.eql(u8, chunk.kind, "IEND") and image_start != null) {
            image_end = pos;
            break;
        }
    }

    const start = image_start orelse return error.InvalidFormat;
    const end = image_end orelse return error.InvalidFormat;
    const chunk_bytes = data[start..end];
    const out = try allocator.alloc(u8, png_signature.len + chunk_bytes.len);
    errdefer allocator.free(out);
    @memcpy(out[0..png_signature.len], png_signature);
    @memcpy(out[png_signature.len..], chunk_bytes);
    return out;
}

const Chunk = struct {
    kind: []const u8,
    bytes: []const u8,
};

fn nextChunk(data: []const u8, pos: *usize) bio.ReaderError!Chunk {
    if (pos.* > data.len or data.len - pos.* < 12) return error.TruncatedData;
    const len = std.math.cast(usize, beU32(data[pos.*..][0..4])) orelse return error.UnsupportedVariant;
    const kind_start = pos.* + 4;
    const data_start = kind_start + 4;
    const crc_start = std.math.add(usize, data_start, len) catch return error.UnsupportedVariant;
    const next = std.math.add(usize, crc_start, 4) catch return error.UnsupportedVariant;
    if (next > data.len) return error.TruncatedData;
    const expected_crc = beU32(data[crc_start..][0..4]);
    const actual_crc = std.hash.crc.Crc32.hash(data[kind_start..crc_start]);
    if (actual_crc != expected_crc) return error.InvalidFormat;
    pos.* = next;
    return .{
        .kind = data[kind_start..][0..4],
        .bytes = data[data_start..crc_start],
    };
}

fn beU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

fn appendChunk(list: *std.ArrayList(u8), kind: []const u8, bytes: []const u8) !void {
    try appendU32Be(list, @intCast(bytes.len));
    try list.appendSlice(std.testing.allocator, kind);
    try list.appendSlice(std.testing.allocator, bytes);
    var crc = std.hash.crc.Crc32.init();
    crc.update(kind);
    crc.update(bytes);
    try appendU32Be(list, crc.final());
}

fn appendU32Be(list: *std.ArrayList(u8), value: u32) !void {
    try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
    try list.append(std.testing.allocator, @intCast(value & 0xff));
}

fn appendZlibStored(list: *std.ArrayList(u8), bytes: []const u8) !void {
    try list.append(std.testing.allocator, 0x78);
    try list.append(std.testing.allocator, 0x01);
    try list.append(std.testing.allocator, 0x01);
    try list.append(std.testing.allocator, @intCast(bytes.len & 0xff));
    try list.append(std.testing.allocator, @intCast((bytes.len >> 8) & 0xff));
    const nlen: u16 = ~@as(u16, @intCast(bytes.len));
    try list.append(std.testing.allocator, @intCast(nlen & 0xff));
    try list.append(std.testing.allocator, @intCast((nlen >> 8) & 0xff));
    try list.appendSlice(std.testing.allocator, bytes);
    try appendU32Be(list, adler32(bytes));
}

fn adler32(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn appendMinimalMng(list: *std.ArrayList(u8), scanlines: []const u8) !void {
    try list.appendSlice(std.testing.allocator, mng_signature);

    var mhdr: std.ArrayList(u8) = .empty;
    defer mhdr.deinit(std.testing.allocator);
    try appendU32Be(&mhdr, 2);
    try appendU32Be(&mhdr, 1);
    try appendU32Be(&mhdr, 1000);
    try appendU32Be(&mhdr, 1);
    try appendU32Be(&mhdr, 1);
    try appendU32Be(&mhdr, 0);
    try appendU32Be(&mhdr, 0);
    try appendChunk(list, "MHDR", mhdr.items);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 2);
    try appendU32Be(&ihdr, 1);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(list, "IHDR", ihdr.items);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, scanlines);
    try appendChunk(list, "IDAT", zlib.items);
    try appendChunk(list, "IEND", &.{});
    try appendChunk(list, "MEND", &.{});
}

test "reads first png image from mng" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendMinimalMng(&data, &.{ 0, 7, 9 });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("mng", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("mng", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "rejects jng chunks in mng" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, mng_signature);

    var mhdr: std.ArrayList(u8) = .empty;
    defer mhdr.deinit(std.testing.allocator);
    try appendU32Be(&mhdr, 1);
    try appendU32Be(&mhdr, 1);
    try appendU32Be(&mhdr, 1000);
    try appendU32Be(&mhdr, 1);
    try appendU32Be(&mhdr, 1);
    try appendU32Be(&mhdr, 0);
    try appendU32Be(&mhdr, 0);
    try appendChunk(&data, "MHDR", mhdr.items);
    try appendChunk(&data, "JHDR", &.{});
    try appendChunk(&data, "MEND", &.{});

    try std.testing.expect(matches(data.items));
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, data.items, 0));
}
