const std = @import("std");
const bio = @import("../root.zig");
const png = @import("png.zig");

const signature = "\x89PNG\r\n\x1a\n";

pub fn matches(data: []const u8) bool {
    if (!png.matches(data)) return false;
    var pos: usize = signature.len;
    while (pos < data.len) {
        const chunk = nextChunk(data, &pos) catch return false;
        if (std.mem.eql(u8, chunk.kind, "acTL")) return true;
        if (std.mem.eql(u8, chunk.kind, "IEND")) return false;
    }
    return false;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    _ = try animationFrameCount(data);
    var metadata = try png.readMetadata(data);
    metadata.format = "apng";
    metadata.size_z = 1;
    metadata.size_t = 1;
    metadata.plane_count = 1;
    metadata.dimension_order = "XYCTZ";
    return metadata;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    if (plane_index != 0) return error.InvalidPlaneIndex;
    _ = try animationFrameCount(data);
    var plane = try png.readPlane(allocator, data);
    plane.metadata.format = "apng";
    plane.metadata.size_z = 1;
    plane.metadata.size_t = 1;
    plane.metadata.plane_count = 1;
    plane.metadata.dimension_order = "XYCTZ";
    return plane;
}

fn animationFrameCount(data: []const u8) bio.ReaderError!u32 {
    if (!png.matches(data)) return error.InvalidFormat;
    var pos: usize = signature.len;
    var frame_count: ?u32 = null;
    var saw_iend = false;
    while (pos < data.len) {
        const chunk = try nextChunk(data, &pos);
        if (std.mem.eql(u8, chunk.kind, "acTL")) {
            if (frame_count != null) return error.InvalidFormat;
            if (chunk.bytes.len != 8) return error.InvalidFormat;
            const frames = beU32(chunk.bytes[0..4]);
            if (frames == 0) return error.InvalidFormat;
            frame_count = frames;
        } else if (std.mem.eql(u8, chunk.kind, "IEND")) {
            saw_iend = true;
            break;
        }
    }
    if (!saw_iend or pos != data.len) return error.InvalidFormat;
    return frame_count orelse error.InvalidFormat;
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

fn appendApng(list: *std.ArrayList(u8), frames: u32, scanlines: []const u8) !void {
    try list.appendSlice(std.testing.allocator, signature);

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

    var actl: std.ArrayList(u8) = .empty;
    defer actl.deinit(std.testing.allocator);
    try appendU32Be(&actl, frames);
    try appendU32Be(&actl, 0);
    try appendChunk(list, "acTL", actl.items);

    var fctl: std.ArrayList(u8) = .empty;
    defer fctl.deinit(std.testing.allocator);
    try appendU32Be(&fctl, 0);
    try appendU32Be(&fctl, 2);
    try appendU32Be(&fctl, 1);
    try appendU32Be(&fctl, 0);
    try appendU32Be(&fctl, 0);
    try fctl.appendSlice(std.testing.allocator, &.{ 1, 30, 0, 0, 0, 0 });
    try appendChunk(list, "fcTL", fctl.items);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, scanlines);
    try appendChunk(list, "IDAT", zlib.items);
    try appendChunk(list, "IEND", &.{});
}

test "detects animated png by acTL and exposes default image" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendApng(&data, 2, &.{ 0, 7, 9 });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("apng", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("apng", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "plain png without animation control is not apng" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, signature);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 1);
    try appendU32Be(&ihdr, 1);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(&data, "IHDR", ihdr.items);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, &.{ 0, 5 });
    try appendChunk(&data, "IDAT", zlib.items);
    try appendChunk(&data, "IEND", &.{});

    try std.testing.expect(!matches(data.items));
}

test "rejects malformed animation control chunk" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendApng(&data, 0, &.{ 0, 7, 9 });

    try std.testing.expect(matches(data.items));
    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlaneIndex(std.testing.allocator, data.items, 0));
}
