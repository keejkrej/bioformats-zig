const std = @import("std");
const bio = @import("../root.zig");
const cfb = @import("cfb.zig");
const tiff = @import("tiff.zig");

const field_count_name = "Field Count";
const file_has_image_name = "File Has Image";

const Parsed = struct {
    image_name: []u8,
    width: u32,
    height: u32,
    size_c: u16,
    pixel_type: bio.PixelType,
    plane_count: u32,
    tiff_backed: bool,

    fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.image_name);
    }
};

pub fn matches(data: []const u8) bool {
    const parsed = parse(std.heap.page_allocator, data) catch return false;
    defer parsed.deinit(std.heap.page_allocator);
    return parsed.width > 0 and parsed.height > 0 and parsed.plane_count > 0;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const parsed = try parse(std.heap.page_allocator, data);
    defer parsed.deinit(std.heap.page_allocator);
    return metadataFromParsed(parsed);
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const parsed = try parse(allocator, data);
    defer parsed.deinit(allocator);
    const metadata = metadataFromParsed(parsed);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;

    const image = try cfb.readStream(allocator, data, parsed.image_name);
    defer allocator.free(image);

    if (parsed.tiff_backed) {
        var plane = try tiff.readPlaneIndex(allocator, image, plane_index);
        plane.metadata.format = "pci";
        return plane;
    }

    const plane_len = try planeByteCount(metadata);
    const offset = std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant;
    if (offset > image.len or image.len - offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    @memcpy(out, image[offset..][0..plane_len]);
    return .{ .metadata = metadata, .data = out };
}

fn parse(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!Parsed {
    if (!cfb.matches(data)) return error.InvalidFormat;
    if (cfb.hasStream(allocator, data, file_has_image_name)) {
        const has_image = try readU16Stream(allocator, data, file_has_image_name);
        if (has_image == 0) return error.InvalidFormat;
    }

    const streams = try cfb.listStreams(allocator, data);
    defer cfb.freeStreamList(allocator, streams);
    const image_name = try findImageStreamName(allocator, data, streams);
    errdefer allocator.free(image_name);

    const image = try cfb.readStream(allocator, data, image_name);
    defer allocator.free(image);
    if (tiff.matches(image)) {
        const metadata = try tiff.readMetadata(image);
        return .{
            .image_name = image_name,
            .width = metadata.width,
            .height = metadata.height,
            .size_c = metadata.size_c,
            .pixel_type = metadata.pixel_type,
            .plane_count = metadata.plane_count,
            .tiff_backed = true,
        };
    }

    const width = try findDoubleU32(allocator, data, streams, "Image_Width");
    const height = try findDoubleU32(allocator, data, streams, "Image_Height");
    const depth = try findDoubleU32(allocator, data, streams, "Image_Depth");
    var size_c: u16 = 1;
    const pixel_type = try pixelTypeFromDepth(depth, &size_c);
    var plane_count = readU32Stream(allocator, data, field_count_name) catch 1;
    if (plane_count == 0) plane_count = 1;
    if (width == 0 or height == 0) return error.InvalidFormat;
    return .{
        .image_name = image_name,
        .width = width,
        .height = height,
        .size_c = size_c,
        .pixel_type = pixel_type,
        .plane_count = plane_count,
        .tiff_backed = false,
    };
}

fn metadataFromParsed(parsed: Parsed) bio.Metadata {
    return .{
        .format = "pci",
        .width = parsed.width,
        .height = parsed.height,
        .size_c = parsed.size_c,
        .samples_per_pixel = parsed.size_c,
        .size_z = 1,
        .size_t = @intCast(@min(parsed.plane_count, std.math.maxInt(u16))),
        .pixel_type = parsed.pixel_type,
        .little_endian = true,
        .plane_count = parsed.plane_count,
        .dimension_order = "XYCTZ",
    };
}

fn findImageStreamName(allocator: std.mem.Allocator, data: []const u8, streams: []const cfb.StreamInfo) bio.ReaderError![]u8 {
    for (streams) |stream| {
        if (std.mem.startsWith(u8, stream.name, "Bitmap") or std.mem.eql(u8, stream.name, "Data")) {
            const bytes = cfb.readStream(allocator, data, stream.name) catch continue;
            defer allocator.free(bytes);
            if (bytes.len > 0) return allocator.dupe(u8, stream.name);
        }
    }
    return error.UnsupportedFormat;
}

fn findDoubleU32(allocator: std.mem.Allocator, data: []const u8, streams: []const cfb.StreamInfo, needle: []const u8) bio.ReaderError!u32 {
    for (streams) |stream| {
        if (std.mem.indexOf(u8, stream.name, needle) != null and stream.size >= 8) {
            const value = try readF64Stream(allocator, data, stream.name);
            if (value < 0 or value > std.math.maxInt(u32)) return error.UnsupportedVariant;
            return @intFromFloat(value);
        }
    }
    return error.InvalidFormat;
}

fn pixelTypeFromDepth(depth: u32, size_c: *u16) bio.ReaderError!bio.PixelType {
    if (depth == 24) {
        size_c.* = 3;
        return .uint8;
    }
    return switch (depth) {
        8 => .uint8,
        16 => .uint16,
        32 => .uint32,
        else => error.UnsupportedVariant,
    };
}

fn readU16Stream(allocator: std.mem.Allocator, data: []const u8, name: []const u8) bio.ReaderError!u16 {
    const stream = try cfb.readStream(allocator, data, name);
    defer allocator.free(stream);
    if (stream.len < 2) return error.TruncatedData;
    return std.mem.readInt(u16, stream[0..2], .little);
}

fn readU32Stream(allocator: std.mem.Allocator, data: []const u8, name: []const u8) bio.ReaderError!u32 {
    const stream = try cfb.readStream(allocator, data, name);
    defer allocator.free(stream);
    if (stream.len < 4) return error.TruncatedData;
    return std.mem.readInt(u32, stream[0..4], .little);
}

fn readF64Stream(allocator: std.mem.Allocator, data: []const u8, name: []const u8) bio.ReaderError!f64 {
    const stream = try cfb.readStream(allocator, data, name);
    defer allocator.free(stream);
    if (stream.len < 8) return error.TruncatedData;
    return @bitCast(std.mem.readInt(u64, stream[0..8], .little));
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
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

fn appendF64Le(list: *std.ArrayList(u8), value: f64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @bitCast(value), .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

const TestStream = struct {
    name: []const u8,
    data: []const u8,
};

fn minimalCxdRaw() ![]u8 {
    var has_image: std.ArrayList(u8) = .empty;
    defer has_image.deinit(std.testing.allocator);
    var fields: std.ArrayList(u8) = .empty;
    defer fields.deinit(std.testing.allocator);
    var width: std.ArrayList(u8) = .empty;
    defer width.deinit(std.testing.allocator);
    var height: std.ArrayList(u8) = .empty;
    defer height.deinit(std.testing.allocator);
    var depth: std.ArrayList(u8) = .empty;
    defer depth.deinit(std.testing.allocator);
    try appendU16Le(&has_image, 1);
    try appendU32Le(&fields, 2);
    try appendF64Le(&width, 2);
    try appendF64Le(&height, 1);
    try appendF64Le(&depth, 8);
    const pixels = [_]u8{ 1, 2, 3, 4 };
    const streams = [_]TestStream{
        .{ .name = file_has_image_name, .data = has_image.items },
        .{ .name = field_count_name, .data = fields.items },
        .{ .name = "Image_Width", .data = width.items },
        .{ .name = "Image_Height", .data = height.items },
        .{ .name = "Image_Depth", .data = depth.items },
        .{ .name = "Data", .data = &pixels },
    };
    return buildMiniCfb(&streams);
}

fn buildMiniCfb(streams: []const TestStream) ![]u8 {
    const sector_size = 512;
    const mini_sector_size = 64;
    const mini_cutoff = 4096;
    const fat_sector: u32 = 0;
    const first_dir_sector: u32 = 1;
    const dir_entries = streams.len + 1;
    const dir_sectors = (dir_entries * 128 + sector_size - 1) / sector_size;
    const first_minifat_sector: u32 = first_dir_sector + @as(u32, @intCast(dir_sectors));

    var mini_stream: std.ArrayList(u8) = .empty;
    defer mini_stream.deinit(std.testing.allocator);
    const starts = try std.testing.allocator.alloc(u32, streams.len);
    defer std.testing.allocator.free(starts);
    const mini_lengths = try std.testing.allocator.alloc(u32, streams.len);
    defer std.testing.allocator.free(mini_lengths);
    for (streams, 0..) |stream, i| {
        while (mini_stream.items.len % mini_sector_size != 0) try mini_stream.append(std.testing.allocator, 0);
        starts[i] = @intCast(mini_stream.items.len / mini_sector_size);
        mini_lengths[i] = @intCast((stream.data.len + mini_sector_size - 1) / mini_sector_size);
        try mini_stream.appendSlice(std.testing.allocator, stream.data);
    }
    while (mini_stream.items.len % sector_size != 0) try mini_stream.append(std.testing.allocator, 0);

    const mini_entries = mini_stream.items.len / mini_sector_size;
    const minifat_sectors = @max(@as(usize, 1), (mini_entries * 4 + sector_size - 1) / sector_size);
    const first_mini_stream_sector: u32 = first_minifat_sector + @as(u32, @intCast(minifat_sectors));
    const mini_stream_sectors = mini_stream.items.len / sector_size;
    const total_sectors = 1 + dir_sectors + minifat_sectors + mini_stream_sectors;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(std.testing.allocator);
    try out.appendNTimes(std.testing.allocator, 0, 512 + total_sectors * sector_size);
    @memcpy(out.items[0..cfb.magic.len], &cfb.magic);
    writeU16(out.items, 0x1a, 0x003e);
    writeU16(out.items, 0x1c, 0xfffe);
    writeU16(out.items, 0x1e, 9);
    writeU16(out.items, 0x20, 6);
    writeU32(out.items, 0x2c, 1);
    writeU32(out.items, 0x30, first_dir_sector);
    writeU32(out.items, 0x38, mini_cutoff);
    writeU32(out.items, 0x3c, first_minifat_sector);
    writeU32(out.items, 0x40, @intCast(minifat_sectors));
    writeU32(out.items, 0x44, 0xfffffffe);
    writeU32(out.items, 0x4c, fat_sector);
    var header_difat: usize = 0x50;
    while (header_difat < 512) : (header_difat += 4) writeU32(out.items, header_difat, 0xffffffff);

    const fat_start = 512;
    var fat_off: usize = 0;
    while (fat_off < sector_size) : (fat_off += 4) writeU32(out.items[fat_start..][0..sector_size], fat_off, 0xffffffff);
    writeU32(out.items[fat_start..][0..sector_size], 4 * fat_sector, 0xfffffffd);
    for (0..dir_sectors) |i| {
        const sector: u32 = first_dir_sector + @as(u32, @intCast(i));
        writeU32(out.items[fat_start..][0..sector_size], 4 * @as(usize, sector), if (i + 1 == dir_sectors) 0xfffffffe else sector + 1);
    }
    for (0..minifat_sectors) |i| {
        const sector: u32 = first_minifat_sector + @as(u32, @intCast(i));
        writeU32(out.items[fat_start..][0..sector_size], 4 * @as(usize, sector), if (i + 1 == minifat_sectors) 0xfffffffe else sector + 1);
    }
    for (0..mini_stream_sectors) |i| {
        const sector: u32 = first_mini_stream_sector + @as(u32, @intCast(i));
        writeU32(out.items[fat_start..][0..sector_size], 4 * @as(usize, sector), if (i + 1 == mini_stream_sectors) 0xfffffffe else sector + 1);
    }

    const dir_start = 512 + @as(usize, first_dir_sector) * sector_size;
    writeDirEntry(out.items[dir_start..][0..128], "Root Entry", 5, first_mini_stream_sector, mini_stream.items.len);
    for (streams, 0..) |stream, i| writeDirEntry(out.items[dir_start + (i + 1) * 128 ..][0..128], stream.name, 2, starts[i], stream.data.len);

    const minifat_start = 512 + @as(usize, first_minifat_sector) * sector_size;
    var mini_fat_off: usize = 0;
    while (mini_fat_off < minifat_sectors * sector_size) : (mini_fat_off += 4) writeU32(out.items[minifat_start..][0 .. minifat_sectors * sector_size], mini_fat_off, 0xffffffff);
    for (streams, 0..) |_, i| {
        var j: u32 = 0;
        while (j < mini_lengths[i]) : (j += 1) {
            const entry = starts[i] + j;
            writeU32(out.items[minifat_start..][0 .. minifat_sectors * sector_size], @as(usize, entry) * 4, if (j + 1 == mini_lengths[i]) 0xfffffffe else entry + 1);
        }
    }
    const mini_stream_start = 512 + @as(usize, first_mini_stream_sector) * sector_size;
    @memcpy(out.items[mini_stream_start..][0..mini_stream.items.len], mini_stream.items);
    return out.toOwnedSlice(std.testing.allocator);
}

fn writeDirEntry(entry: []u8, name: []const u8, object_type: u8, start_sector: u32, stream_size: usize) void {
    @memset(entry, 0);
    for (name, 0..) |byte, i| writeU16(entry, i * 2, byte);
    writeU16(entry, 64, @intCast((name.len + 1) * 2));
    entry[66] = object_type;
    writeU32(entry, 68, 0xffffffff);
    writeU32(entry, 72, 0xffffffff);
    writeU32(entry, 76, 0xffffffff);
    writeU32(entry, 116, start_sector);
    writeU64(entry, 120, stream_size);
}

fn writeU16(data: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, data[offset..][0..2], value, .little);
}

fn writeU32(data: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, data[offset..][0..4], value, .little);
}

fn writeU64(data: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, data[offset..][0..8], value, .little);
}

test "reads simple pci raw cxd planes" {
    const data = try minimalCxdRaw();
    defer std.testing.allocator.free(data);

    try std.testing.expect(matches(data));
    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("pci", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const second = try readPlaneIndex(std.testing.allocator, data, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, second.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data, 2));
}

test "maps simple pci image depth" {
    var channels: u16 = 1;
    try std.testing.expectEqual(bio.PixelType.uint8, try pixelTypeFromDepth(8, &channels));
    try std.testing.expectEqual(@as(u16, 1), channels);
    try std.testing.expectEqual(bio.PixelType.uint16, try pixelTypeFromDepth(16, &channels));
    try std.testing.expectEqual(bio.PixelType.uint8, try pixelTypeFromDepth(24, &channels));
    try std.testing.expectEqual(@as(u16, 3), channels);
    try std.testing.expectError(error.UnsupportedVariant, pixelTypeFromDepth(12, &channels));
}
