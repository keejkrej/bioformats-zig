const std = @import("std");
const bio = @import("../root.zig");
const cfb = @import("cfb.zig");

const contents = "CONTENTS";
const min_image_stream_size = 1024;

const Scan = struct {
    width: u32 = 0,
    height: u32 = 0,
    bpp: u32 = 0,
    jpeg: bool = false,
    zlib: bool = false,
    images: u32 = 0,
    z_values: UniqueValues = .{},
    c_values: UniqueValues = .{},
    t_values: UniqueValues = .{},
};

const UniqueValues = struct {
    values: [256]u32 = undefined,
    len: usize = 0,

    fn add(self: *UniqueValues, value: u32) void {
        for (self.values[0..self.len]) |existing| {
            if (existing == value) return;
        }
        if (self.len < self.values.len) {
            self.values[self.len] = value;
            self.len += 1;
        }
    }

    fn count(self: UniqueValues) u32 {
        return @intCast(@max(self.len, 1));
    }
};

pub fn matches(data: []const u8) bool {
    if (!cfb.matches(data)) return false;
    const streams = cfb.listStreams(std.heap.page_allocator, data) catch return false;
    defer cfb.freeStreamList(std.heap.page_allocator, streams);
    for (streams) |stream| {
        if (isImageContentsStream(stream.name) and stream.size > min_image_stream_size) return true;
    }
    return false;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!cfb.matches(data)) return error.InvalidFormat;
    const allocator = std.heap.page_allocator;
    const streams = try cfb.listStreams(allocator, data);
    defer cfb.freeStreamList(allocator, streams);

    var scan = Scan{};
    for (streams) |stream| {
        if (!isImageContentsStream(stream.name) or stream.size <= min_image_stream_size) continue;
        const bytes = cfb.readStream(allocator, data, stream.name) catch continue;
        defer allocator.free(bytes);
        parseImageStream(bytes, &scan) catch continue;
    }

    if (scan.images == 0 or scan.width == 0 or scan.height == 0) return error.InvalidFormat;
    const pixel = pixelType(scan.bpp, scan.jpeg);
    const size_z = boundedDimension(scan.z_values.count());
    const base_c = scan.c_values.count();
    const size_t = boundedDimension(scan.t_values.count());
    const size_c = boundedDimension(base_c * pixel.samples);

    return .{
        .format = "zeisszvi",
        .width = scan.width,
        .height = scan.height,
        .size_c = size_c,
        .samples_per_pixel = pixel.samples,
        .size_z = size_z,
        .size_t = size_t,
        .pixel_type = pixel.pixel_type,
        .little_endian = true,
        .plane_count = scan.images,
        .dimension_order = "XYZCT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

fn isImageContentsStream(name: []const u8) bool {
    if (!std.ascii.endsWithIgnoreCase(name, contents)) return false;
    return startsWithIgnoreCase(name, "Image") or std.ascii.indexOfIgnoreCase(name, "Item") != null;
}

fn parseImageStream(data: []const u8, scan: *Scan) bio.ReaderError!void {
    if (data.len <= min_image_stream_size) return error.InvalidFormat;
    var reader = Reader{ .data = data };

    var skipped: usize = 0;
    while (skipped < 11) : (skipped += 1) _ = try getNextTag(&reader);

    try reader.skip(2);
    const len_raw = try reader.readU32();
    if (len_raw < 28) return error.InvalidFormat;
    const payload_len = len_raw - 20;
    try reader.skip(8);

    const z = try reader.readU32();
    const c = try reader.readU32();
    const t = try reader.readU32();
    try reader.skip(4);
    _ = try reader.readU32();

    if (payload_len < 8) return error.InvalidFormat;
    try reader.skip(payload_len - 8);

    skipped = 0;
    while (skipped < 5) : (skipped += 1) _ = try getNextTag(&reader);

    try reader.skip(4);
    const width = try reader.readU32();
    const height = try reader.readU32();
    try reader.skip(4);
    const bpp = try reader.readU32();
    try reader.skip(4);
    const valid = try reader.readU32();
    const check = std.mem.trim(u8, try reader.readBytes(4), " \x00\t\r\n");

    if (width == 0 or height == 0) return error.InvalidFormat;
    scan.width = if (scan.width == 0) width else @min(scan.width, width);
    scan.height = @max(scan.height, height);
    if (scan.bpp == 0) scan.bpp = bpp;
    scan.z_values.add(z);
    scan.c_values.add(c);
    scan.t_values.add(t);
    scan.images += 1;
    if ((valid == 0 or valid == 1) and std.mem.eql(u8, check, "WZL")) scan.zlib = true;
    if ((valid == 0 or valid == 1) and !scan.zlib) scan.jpeg = true;
}

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn skip(self: *Reader, amount: u32) bio.ReaderError!void {
        const end = std.math.add(usize, self.pos, amount) catch return error.UnsupportedVariant;
        if (end > self.data.len) return error.TruncatedData;
        self.pos = end;
    }

    fn readU16(self: *Reader) bio.ReaderError!u16 {
        const bytes = try self.readBytes(2);
        return std.mem.readInt(u16, bytes[0..2], .little);
    }

    fn readU32(self: *Reader) bio.ReaderError!u32 {
        const bytes = try self.readBytes(4);
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    fn readU64(self: *Reader) bio.ReaderError!u64 {
        const bytes = try self.readBytes(8);
        return std.mem.readInt(u64, bytes[0..8], .little);
    }

    fn readBytes(self: *Reader, len: usize) bio.ReaderError![]const u8 {
        const end = std.math.add(usize, self.pos, len) catch return error.UnsupportedVariant;
        if (end > self.data.len) return error.TruncatedData;
        const out = self.data[self.pos..end];
        self.pos = end;
        return out;
    }
};

fn getNextTag(reader: *Reader) bio.ReaderError![]const u8 {
    const tag_type = try reader.readU16();
    switch (tag_type) {
        0, 1 => return "",
        2, 3, 4, 5, 7, 19, 20, 21, 22, 23 => {
            const bytes: u32 = switch (tag_type) {
                2 => 2,
                3, 4, 19, 22, 23 => 4,
                else => 8,
            };
            try reader.skip(bytes);
            return "";
        },
        8, 69 => {
            const len = try reader.readU32();
            return reader.readBytes(len);
        },
        9, 13 => {
            try reader.skip(16);
            return "";
        },
        11 => {
            try reader.skip(2);
            return "";
        },
        63, 65 => {
            const len = try reader.readU32();
            try reader.skip(len);
            return "";
        },
        66 => {
            const len = try reader.readU16();
            return reader.readBytes(len);
        },
        else => return error.UnsupportedVariant,
    }
}

const Pixel = struct {
    pixel_type: bio.PixelType,
    samples: u16,
};

fn pixelType(bpp: u32, jpeg: bool) Pixel {
    if (jpeg) return .{ .pixel_type = .uint8, .samples = 1 };
    return switch (bpp) {
        1 => .{ .pixel_type = .uint8, .samples = 1 },
        2 => .{ .pixel_type = .uint16, .samples = 1 },
        3 => .{ .pixel_type = .rgb8, .samples = 3 },
        6 => .{ .pixel_type = .rgb16, .samples = 3 },
        else => .{ .pixel_type = .uint8, .samples = 1 },
    };
}

fn boundedDimension(value: u32) u16 {
    return @intCast(@min(@max(value, 1), std.math.maxInt(u16)));
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn appendU16Le(out: *std.ArrayList(u8), value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try out.appendSlice(std.testing.allocator, &bytes);
}

fn appendU32Le(out: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(std.testing.allocator, &bytes);
}

fn appendSyntheticImageStream(out: *std.ArrayList(u8), width: u32, height: u32, z: u32, c: u32, t: u32, bpp: u32) !void {
    try out.appendNTimes(std.testing.allocator, 0, 11 * 2);
    try appendU16Le(out, 0);
    try appendU32Le(out, 28);
    try out.appendNTimes(std.testing.allocator, 0, 8);
    try appendU32Le(out, z);
    try appendU32Le(out, c);
    try appendU32Le(out, t);
    try appendU32Le(out, 0);
    try appendU32Le(out, 0);
    try out.appendNTimes(std.testing.allocator, 0, 5 * 2);
    try appendU32Le(out, 0);
    try appendU32Le(out, width);
    try appendU32Le(out, height);
    try appendU32Le(out, 0);
    try appendU32Le(out, bpp);
    try appendU32Le(out, 0);
    try appendU32Le(out, 2);
    try out.appendSlice(std.testing.allocator, "RAW ");
    try out.appendNTimes(std.testing.allocator, 0, 4096 - out.items.len);
}

fn appendDirEntry(out: *std.ArrayList(u8), name: []const u8, object_type: u8, start_sector: u32, stream_size: u64) !void {
    const start = out.items.len;
    try out.appendNTimes(std.testing.allocator, 0, 128);
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        std.mem.writeInt(u16, out.items[start + i * 2 ..][0..2], name[i], .little);
    }
    std.mem.writeInt(u16, out.items[start + name.len * 2 ..][0..2], 0, .little);
    std.mem.writeInt(u16, out.items[start + 64 ..][0..2], @intCast((name.len + 1) * 2), .little);
    out.items[start + 66] = object_type;
    std.mem.writeInt(u32, out.items[start + 116 ..][0..4], start_sector, .little);
    std.mem.writeInt(u64, out.items[start + 120 ..][0..8], stream_size, .little);
}

fn appendSyntheticCfb(out: *std.ArrayList(u8), stream_name: []const u8, stream: []const u8) !void {
    const sector_size = 512;
    const stream_sectors = (stream.len + sector_size - 1) / sector_size;
    const total_sectors = 2 + stream_sectors;

    try out.appendNTimes(std.testing.allocator, 0, 512 + total_sectors * sector_size);
    @memcpy(out.items[0..cfb.magic.len], &cfb.magic);
    std.mem.writeInt(u16, out.items[0x1c..][0..2], 0xfffe, .little);
    std.mem.writeInt(u16, out.items[0x1e..][0..2], 9, .little);
    std.mem.writeInt(u16, out.items[0x20..][0..2], 6, .little);
    std.mem.writeInt(u32, out.items[0x2c..][0..4], 1, .little);
    std.mem.writeInt(u32, out.items[0x30..][0..4], 1, .little);
    std.mem.writeInt(u32, out.items[0x38..][0..4], 4096, .little);
    std.mem.writeInt(u32, out.items[0x3c..][0..4], 0xfffffffe, .little);
    std.mem.writeInt(u32, out.items[0x44..][0..4], 0xfffffffe, .little);
    std.mem.writeInt(u32, out.items[0x4c..][0..4], 0, .little);
    var difat: usize = 0x50;
    while (difat < 512) : (difat += 4) std.mem.writeInt(u32, out.items[difat..][0..4], 0xffffffff, .little);

    const fat_start = 512;
    var entry: usize = 0;
    while (entry < sector_size / 4) : (entry += 1) {
        std.mem.writeInt(u32, out.items[fat_start + entry * 4 ..][0..4], 0xffffffff, .little);
    }
    std.mem.writeInt(u32, out.items[fat_start..][0..4], 0xfffffffd, .little);
    std.mem.writeInt(u32, out.items[fat_start + 4 ..][0..4], 0xfffffffe, .little);
    var sector: usize = 0;
    while (sector < stream_sectors) : (sector += 1) {
        const value: u32 = if (sector + 1 == stream_sectors) 0xfffffffe else @intCast(3 + sector);
        std.mem.writeInt(u32, out.items[fat_start + (2 + sector) * 4 ..][0..4], value, .little);
    }

    var directory: std.ArrayList(u8) = .empty;
    defer directory.deinit(std.testing.allocator);
    try appendDirEntry(&directory, "Root Entry", 5, 0xfffffffe, 0);
    try appendDirEntry(&directory, stream_name, 2, 2, stream.len);
    try directory.appendNTimes(std.testing.allocator, 0, sector_size - directory.items.len);
    @memcpy(out.items[512 + sector_size ..][0..sector_size], directory.items);
    @memcpy(out.items[512 + sector_size * 2 ..][0..stream.len], stream);
}

test "reads zeiss zvi metadata from cfb image stream" {
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(std.testing.allocator);
    try appendSyntheticImageStream(&stream, 13, 9, 0, 0, 0, 2);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendSyntheticCfb(&data, "Image/Item(0)/CONTENTS", stream.items);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zeisszvi", metadata.format);
    try std.testing.expectEqual(@as(u32, 13), metadata.width);
    try std.testing.expectEqual(@as(u32, 9), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, data.items, 0));
}

test "rejects plain cfb without zvi image stream" {
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(std.testing.allocator);
    try stream.appendNTimes(std.testing.allocator, 0, 4096);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendSyntheticCfb(&data, "Workbook", stream.items);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
}
