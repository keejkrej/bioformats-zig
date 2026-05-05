const std = @import("std");
const bio = @import("../root.zig");
const cfb = @import("cfb.zig");

const width_stream = "ImageWidth";
const height_stream = "ImageHeight";
const data_type_stream = "DataType";
const image_prefix = "Image";

const Parsed = struct {
    width: u32,
    height: u32,
    pixel_type: bio.PixelType,
    planes: u32,
};

pub fn matches(data: []const u8) bool {
    const parsed = parse(data) catch return false;
    return parsed.width > 0 and parsed.height > 0 and parsed.planes > 0;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const parsed = try parse(data);
    return .{
        .format = "zeissxrm",
        .width = parsed.width,
        .height = parsed.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = @intCast(@min(parsed.planes, std.math.maxInt(u16))),
        .size_t = 1,
        .pixel_type = parsed.pixel_type,
        .little_endian = true,
        .plane_count = parsed.planes,
        .dimension_order = "XYZTC",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;

    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, image_prefix ++ "{d}", .{plane_index + 1}) catch return error.UnsupportedVariant;
    const stream = try cfb.readStream(allocator, data, name);
    defer allocator.free(stream);

    const row = std.math.mul(usize, metadata.width, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
    const plane_len = std.math.mul(usize, row, metadata.height) catch return error.UnsupportedVariant;
    if (stream.len < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    var y: usize = 0;
    while (y < metadata.height) : (y += 1) {
        const src = y * row;
        const dst = (@as(usize, metadata.height) - 1 - y) * row;
        @memcpy(out[dst..][0..row], stream[src..][0..row]);
    }
    return .{ .metadata = metadata, .data = out };
}

fn parse(data: []const u8) bio.ReaderError!Parsed {
    if (!cfb.matches(data)) return error.InvalidFormat;
    const allocator = std.heap.page_allocator;
    const width = try readU32Stream(allocator, data, width_stream);
    const height = try readU32Stream(allocator, data, height_stream);
    const data_type = try readU32Stream(allocator, data, data_type_stream);
    const pixel_type = try pixelType(data_type);
    if (width == 0 or height == 0) return error.InvalidFormat;

    var planes: u32 = 0;
    while (planes < std.math.maxInt(u16)) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, image_prefix ++ "{d}", .{planes + 1}) catch return error.UnsupportedVariant;
        if (!cfb.hasStream(allocator, data, name)) break;
        planes += 1;
    }
    if (planes == 0) return error.InvalidFormat;

    return .{ .width = width, .height = height, .pixel_type = pixel_type, .planes = planes };
}

fn readU32Stream(allocator: std.mem.Allocator, data: []const u8, name: []const u8) bio.ReaderError!u32 {
    const stream = try cfb.readStream(allocator, data, name);
    defer allocator.free(stream);
    if (stream.len < 4) return error.TruncatedData;
    return std.mem.readInt(u32, stream[0..4], .little);
}

fn pixelType(value: u32) bio.ReaderError!bio.PixelType {
    return switch (value) {
        2 => .int8,
        3 => .uint8,
        4 => .int16,
        5 => .uint16,
        6 => .int32,
        7 => .uint32,
        10 => .float32,
        11 => .float64,
        else => error.UnsupportedVariant,
    };
}

fn appendU32Le(list: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

const TestStream = struct {
    name: []const u8,
    data: []const u8,
};

fn minimalXrm() ![]u8 {
    var width: std.ArrayList(u8) = .empty;
    defer width.deinit(std.testing.allocator);
    var height: std.ArrayList(u8) = .empty;
    defer height.deinit(std.testing.allocator);
    var data_type: std.ArrayList(u8) = .empty;
    defer data_type.deinit(std.testing.allocator);
    try appendU32Le(&width, 2);
    try appendU32Le(&height, 2);
    try appendU32Le(&data_type, 3);
    const image = [_]u8{ 1, 2, 3, 4 };
    const streams = [_]TestStream{
        .{ .name = width_stream, .data = width.items },
        .{ .name = height_stream, .data = height.items },
        .{ .name = data_type_stream, .data = data_type.items },
        .{ .name = "Image1", .data = &image },
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
    var starts = try std.testing.allocator.alloc(u32, streams.len);
    defer std.testing.allocator.free(starts);
    var mini_lengths = try std.testing.allocator.alloc(u32, streams.len);
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
    writeU32(out.items, 0x48, 0);
    writeU32(out.items, 0x4c, fat_sector);
    var header_difat: usize = 0x50;
    while (header_difat < 512) : (header_difat += 4) writeU32(out.items, header_difat, 0xffffffff);

    const fat_start = 512;
    var fat_off: usize = 0;
    while (fat_off < sector_size) : (fat_off += 4) writeU32(out.items[fat_start..][0..sector_size], fat_off, 0xffffffff);
    writeU32(out.items[fat_start..][0..sector_size], 4 * fat_sector, 0xfffffffd);
    for (0..dir_sectors) |i| {
        const sector: u32 = first_dir_sector + @as(u32, @intCast(i));
        const next: u32 = if (i + 1 == dir_sectors) 0xfffffffe else sector + 1;
        writeU32(out.items[fat_start..][0..sector_size], 4 * @as(usize, sector), next);
    }
    for (0..minifat_sectors) |i| {
        const sector: u32 = first_minifat_sector + @as(u32, @intCast(i));
        const next: u32 = if (i + 1 == minifat_sectors) 0xfffffffe else sector + 1;
        writeU32(out.items[fat_start..][0..sector_size], 4 * @as(usize, sector), next);
    }
    for (0..mini_stream_sectors) |i| {
        const sector: u32 = first_mini_stream_sector + @as(u32, @intCast(i));
        const next: u32 = if (i + 1 == mini_stream_sectors) 0xfffffffe else sector + 1;
        writeU32(out.items[fat_start..][0..sector_size], 4 * @as(usize, sector), next);
    }

    const dir_start = 512 + @as(usize, first_dir_sector) * sector_size;
    writeDirEntry(out.items[dir_start..][0..128], "Root Entry", 5, first_mini_stream_sector, mini_stream.items.len);
    for (streams, 0..) |stream, i| {
        writeDirEntry(out.items[dir_start + (i + 1) * 128 ..][0..128], stream.name, 2, starts[i], stream.data.len);
    }

    const minifat_start = 512 + @as(usize, first_minifat_sector) * sector_size;
    var mini_fat_off: usize = 0;
    while (mini_fat_off < minifat_sectors * sector_size) : (mini_fat_off += 4) writeU32(out.items[minifat_start..][0 .. minifat_sectors * sector_size], mini_fat_off, 0xffffffff);
    for (streams, 0..) |_, i| {
        var j: u32 = 0;
        while (j < mini_lengths[i]) : (j += 1) {
            const entry = starts[i] + j;
            const next = if (j + 1 == mini_lengths[i]) 0xfffffffe else entry + 1;
            writeU32(out.items[minifat_start..][0 .. minifat_sectors * sector_size], @as(usize, entry) * 4, next);
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

test "reads zeiss xrm mini-stream metadata and flipped pixels" {
    const data = try minimalXrm();
    defer std.testing.allocator.free(data);

    try std.testing.expect(matches(data));
    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("zeissxrm", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4, 1, 2 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data, 1));
}

test "maps zeiss xrm numeric pixel types" {
    try std.testing.expectEqual(bio.PixelType.int8, try pixelType(2));
    try std.testing.expectEqual(bio.PixelType.uint16, try pixelType(5));
    try std.testing.expectEqual(bio.PixelType.float64, try pixelType(11));
    try std.testing.expectError(error.UnsupportedVariant, pixelType(12));
}
