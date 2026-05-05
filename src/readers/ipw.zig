const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const header_len = 512;
const cfb_magic = [_]u8{ 0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1 };
const free_sector: u32 = 0xffffffff;
const end_of_chain: u32 = 0xfffffffe;
const fat_sector_marker: u32 = 0xfffffffd;
const max_header_difat_entries = 109;
const image_tiff_name = "ImageTIFF";

const Header = struct {
    sector_size: usize,
    num_fat_sectors: u32,
    first_dir_sector: u32,
    mini_stream_cutoff: u32,
    first_difat_sector: u32,
    num_difat_sectors: u32,
};

const DirEntry = struct {
    object_type: u8,
    start_sector: u32,
    stream_size: u64,
};

pub fn matches(data: []const u8) bool {
    const embedded = extractImageTiff(std.heap.page_allocator, data) catch return false;
    defer std.heap.page_allocator.free(embedded);
    return tiff.matches(embedded);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const embedded = try extractImageTiff(std.heap.page_allocator, data);
    defer std.heap.page_allocator.free(embedded);
    var metadata = try tiff.readMetadata(embedded);
    metadata.format = "ipw";
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const embedded = try extractImageTiff(allocator, data);
    defer allocator.free(embedded);
    var plane = try tiff.readPlaneIndex(allocator, embedded, plane_index);
    plane.metadata.format = "ipw";
    return plane;
}

fn extractImageTiff(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError![]u8 {
    const header = try parseHeader(data);
    const fat = try readFat(allocator, data, header);
    defer allocator.free(fat);

    const dir_stream = try readSectorChain(allocator, data, fat, header.sector_size, header.first_dir_sector, null);
    defer allocator.free(dir_stream);

    var offset: usize = 0;
    while (offset + 128 <= dir_stream.len) : (offset += 128) {
        const entry_data = dir_stream[offset..][0..128];
        if (!entryNameEquals(entry_data, image_tiff_name)) continue;
        const entry = parseDirEntry(entry_data);
        if (entry.object_type != 2) continue;
        if (entry.stream_size < header.mini_stream_cutoff) return error.UnsupportedVariant;
        return readSectorChain(allocator, data, fat, header.sector_size, entry.start_sector, entry.stream_size);
    }

    return error.UnsupportedFormat;
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_len) return error.TruncatedData;
    if (!std.mem.eql(u8, data[0..cfb_magic.len], &cfb_magic)) return error.InvalidFormat;
    if (readU16(data, 0x1c) != 0xfffe) return error.UnsupportedVariant;
    const sector_shift = readU16(data, 0x1e);
    if (sector_shift != 9 and sector_shift != 12) return error.UnsupportedVariant;
    const sector_size = @as(usize, 1) << @intCast(sector_shift);
    if (sector_size < 512 or sector_size > 4096) return error.UnsupportedVariant;

    const num_fat_sectors = readU32(data, 0x2c);
    if (num_fat_sectors == 0 or num_fat_sectors > max_header_difat_entries) return error.UnsupportedVariant;

    const first_difat_sector = readU32(data, 0x44);
    const num_difat_sectors = readU32(data, 0x48);
    if (num_difat_sectors != 0 or first_difat_sector != end_of_chain) return error.UnsupportedVariant;

    return .{
        .sector_size = sector_size,
        .num_fat_sectors = num_fat_sectors,
        .first_dir_sector = readU32(data, 0x30),
        .mini_stream_cutoff = readU32(data, 0x38),
        .first_difat_sector = first_difat_sector,
        .num_difat_sectors = num_difat_sectors,
    };
}

fn readFat(allocator: std.mem.Allocator, data: []const u8, header: Header) bio.ReaderError![]u32 {
    const entries_per_sector = header.sector_size / 4;
    const total_entries = std.math.mul(usize, entries_per_sector, header.num_fat_sectors) catch return error.UnsupportedVariant;
    const fat = try allocator.alloc(u32, total_entries);
    errdefer allocator.free(fat);

    var fat_index: usize = 0;
    var difat_offset: usize = 0x4c;
    var i: u32 = 0;
    while (i < header.num_fat_sectors) : (i += 1) {
        const sector_id = readU32(data, difat_offset);
        difat_offset += 4;
        if (sector_id == free_sector or sector_id == end_of_chain) return error.InvalidFormat;
        const sector = try sectorSlice(data, header.sector_size, sector_id);
        var entry_offset: usize = 0;
        while (entry_offset < header.sector_size) : (entry_offset += 4) {
            fat[fat_index] = readU32(sector, entry_offset);
            fat_index += 1;
        }
    }
    return fat;
}

fn readSectorChain(
    allocator: std.mem.Allocator,
    data: []const u8,
    fat: []const u32,
    sector_size: usize,
    start_sector: u32,
    expected_size: ?u64,
) bio.ReaderError![]u8 {
    if (start_sector == free_sector or start_sector == end_of_chain) return error.InvalidFormat;
    const wanted_size: ?usize = if (expected_size) |size| std.math.cast(usize, size) orelse return error.UnsupportedVariant else null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var current = start_sector;
    var sectors_seen: usize = 0;
    while (current != end_of_chain) {
        if (current == free_sector or current == fat_sector_marker) return error.InvalidFormat;
        if (current >= fat.len) return error.TruncatedData;
        if (sectors_seen > fat.len) return error.InvalidFormat;
        sectors_seen += 1;

        const sector = try sectorSlice(data, sector_size, current);
        const remaining = if (wanted_size) |size| size - out.items.len else sector_size;
        const to_copy = @min(remaining, sector_size);
        if (to_copy > 0) try out.appendSlice(allocator, sector[0..to_copy]);
        if (wanted_size != null and out.items.len >= wanted_size.?) break;
        current = fat[@intCast(current)];
    }

    if (wanted_size) |size| {
        if (out.items.len != size) return error.TruncatedData;
    }
    return out.toOwnedSlice(allocator);
}

fn sectorSlice(data: []const u8, sector_size: usize, sector_id: u32) bio.ReaderError![]const u8 {
    const start = std.math.mul(usize, @as(usize, sector_id) + 1, sector_size) catch return error.UnsupportedVariant;
    const end = std.math.add(usize, start, sector_size) catch return error.UnsupportedVariant;
    if (end > data.len) return error.TruncatedData;
    return data[start..end];
}

fn parseDirEntry(entry: []const u8) DirEntry {
    return .{
        .object_type = entry[66],
        .start_sector = readU32(entry, 116),
        .stream_size = readU64(entry, 120),
    };
}

fn entryNameEquals(entry: []const u8, expected: []const u8) bool {
    const name_bytes = readU16(entry, 64);
    if (name_bytes < 2 or (name_bytes % 2) != 0) return false;
    const chars = name_bytes / 2 - 1;
    if (chars != expected.len) return false;
    var i: usize = 0;
    while (i < chars) : (i += 1) {
        if (readU16(entry, i * 2) != expected[i]) return false;
    }
    return true;
}

fn readU16(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn readU64(data: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, data[offset..][0..8], .little);
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

fn appendTinyTiff(list: *std.ArrayList(u8), pixel: u8) !void {
    try list.appendSlice(std.testing.allocator, "II");
    try appendU16Le(list, 42);
    try appendU32Le(list, 8);
    try appendU16Le(list, 9);
    try appendTiffEntry(list, 256, 4, 1, 1);
    try appendTiffEntry(list, 257, 4, 1, 1);
    try appendTiffEntry(list, 258, 3, 1, 8);
    try appendTiffEntry(list, 259, 3, 1, 1);
    try appendTiffEntry(list, 262, 3, 1, 1);
    try appendTiffEntry(list, 273, 4, 1, 122);
    try appendTiffEntry(list, 277, 3, 1, 1);
    try appendTiffEntry(list, 278, 4, 1, 1);
    try appendTiffEntry(list, 279, 4, 1, 1);
    try appendU32Le(list, 0);
    try list.append(std.testing.allocator, pixel);
    try list.appendNTimes(std.testing.allocator, 0, 4096 - list.items.len);
}

fn appendOleWithImageTiff(list: *std.ArrayList(u8), tiff_data: []const u8) !void {
    const sector_size = 512;
    const stream_sectors = (tiff_data.len + sector_size - 1) / sector_size;
    const dir_sector: u32 = 1;
    const stream_first_sector: u32 = 2;

    try list.appendNTimes(std.testing.allocator, 0, header_len);
    @memcpy(list.items[0..cfb_magic.len], &cfb_magic);
    writeU16(list.items, 0x1a, 0x003e);
    writeU16(list.items, 0x1c, 0xfffe);
    writeU16(list.items, 0x1e, 9);
    writeU16(list.items, 0x20, 6);
    writeU32(list.items, 0x2c, 1);
    writeU32(list.items, 0x30, dir_sector);
    writeU32(list.items, 0x38, 4096);
    writeU32(list.items, 0x3c, end_of_chain);
    writeU32(list.items, 0x44, end_of_chain);
    writeU32(list.items, 0x4c, 0);
    var header_difat: usize = 0x50;
    while (header_difat < header_len) : (header_difat += 4) writeU32(list.items, header_difat, free_sector);

    const fat_start = list.items.len;
    try list.appendNTimes(std.testing.allocator, 0xff, sector_size);
    writeU32(list.items[fat_start..][0..sector_size], 0, fat_sector_marker);
    writeU32(list.items[fat_start..][0..sector_size], 4, end_of_chain);
    var i: usize = 0;
    while (i < stream_sectors) : (i += 1) {
        const value: u32 = if (i + 1 == stream_sectors) end_of_chain else @intCast(stream_first_sector + i + 1);
        writeU32(list.items[fat_start..][0..sector_size], 4 * (@as(usize, stream_first_sector) + i), value);
    }

    const dir_start = list.items.len;
    try list.appendNTimes(std.testing.allocator, 0, sector_size);
    writeDirName(list.items[dir_start..][0..128], "Root Entry");
    list.items[dir_start + 66] = 5;
    writeU32(list.items, dir_start + 116, end_of_chain);
    writeDirName(list.items[dir_start + 128 ..][0..128], image_tiff_name);
    list.items[dir_start + 128 + 66] = 2;
    writeU32(list.items, dir_start + 128 + 116, stream_first_sector);
    writeU64(list.items, dir_start + 128 + 120, tiff_data.len);

    try list.appendSlice(std.testing.allocator, tiff_data);
    const padded_len = stream_sectors * sector_size;
    if (tiff_data.len < padded_len) try list.appendNTimes(std.testing.allocator, 0, padded_len - tiff_data.len);
}

fn writeDirName(entry: []u8, name: []const u8) void {
    for (name, 0..) |byte, i| writeU16(entry, i * 2, byte);
    writeU16(entry, name.len * 2, 0);
    writeU16(entry, 64, @intCast((name.len + 1) * 2));
}

fn appendU16Le(list: *std.ArrayList(u8), value: u16) !void {
    try list.append(std.testing.allocator, @intCast(value & 0xff));
    try list.append(std.testing.allocator, @intCast(value >> 8));
}

fn appendU32Le(list: *std.ArrayList(u8), value: u32) !void {
    try list.append(std.testing.allocator, @intCast(value & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
}

fn appendTiffEntry(list: *std.ArrayList(u8), tag: u16, field_type: u16, count: u32, value: u32) !void {
    try appendU16Le(list, tag);
    try appendU16Le(list, field_type);
    try appendU32Le(list, count);
    try appendU32Le(list, value);
}

test "reads image tiff stream from ipw ole container" {
    var tiff_data: std.ArrayList(u8) = .empty;
    defer tiff_data.deinit(std.testing.allocator);
    try appendTinyTiff(&tiff_data, 77);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendOleWithImageTiff(&data, tiff_data.items);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("ipw", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("ipw", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}

test "rejects mini-stream image tiff entry" {
    var tiff_data: std.ArrayList(u8) = .empty;
    defer tiff_data.deinit(std.testing.allocator);
    try appendTinyTiff(&tiff_data, 1);
    try tiff_data.resize(std.testing.allocator, 128);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendOleWithImageTiff(&data, tiff_data.items);

    try std.testing.expect(!matches(data.items));
    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}
