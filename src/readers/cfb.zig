const std = @import("std");
const bio = @import("../root.zig");

pub const magic = [_]u8{ 0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1 };

const header_len = 512;
const free_sector: u32 = 0xffffffff;
const end_of_chain: u32 = 0xfffffffe;
const fat_sector_marker: u32 = 0xfffffffd;
const difat_sector_marker: u32 = 0xfffffffc;
const max_header_difat_entries = 109;

const Header = struct {
    sector_size: usize,
    mini_sector_size: usize,
    num_fat_sectors: u32,
    first_dir_sector: u32,
    mini_stream_cutoff: u32,
    first_minifat_sector: u32,
    num_minifat_sectors: u32,
    first_difat_sector: u32,
    num_difat_sectors: u32,
};

const DirEntry = struct {
    object_type: u8,
    start_sector: u32,
    stream_size: u64,
};

pub const StreamInfo = struct {
    name: []u8,
    size: u64,
};

pub fn freeStreamList(allocator: std.mem.Allocator, streams: []StreamInfo) void {
    for (streams) |stream| allocator.free(stream.name);
    allocator.free(streams);
}

pub fn matches(data: []const u8) bool {
    return data.len >= magic.len and std.mem.eql(u8, data[0..magic.len], &magic);
}

pub fn listStreams(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError![]StreamInfo {
    const header = try parseHeader(data);
    const fat = try readFat(allocator, data, header);
    defer allocator.free(fat);

    const dir_stream = try readSectorChain(allocator, data, fat, header.sector_size, header.first_dir_sector, null);
    defer allocator.free(dir_stream);

    var out: std.ArrayList(StreamInfo) = .empty;
    errdefer {
        for (out.items) |stream| allocator.free(stream.name);
        out.deinit(allocator);
    }

    var offset: usize = 0;
    while (offset + 128 <= dir_stream.len) : (offset += 128) {
        const entry_data = dir_stream[offset..][0..128];
        const entry = parseDirEntry(entry_data);
        if (entry.object_type != 2) continue;
        const name = try entryNameAlloc(allocator, entry_data);
        try out.append(allocator, .{ .name = name, .size = entry.stream_size });
    }
    return out.toOwnedSlice(allocator);
}

pub fn hasStream(allocator: std.mem.Allocator, data: []const u8, name: []const u8) bool {
    const stream = readStream(allocator, data, name) catch return false;
    allocator.free(stream);
    return true;
}

pub fn readStream(allocator: std.mem.Allocator, data: []const u8, name: []const u8) bio.ReaderError![]u8 {
    const header = try parseHeader(data);
    const fat = try readFat(allocator, data, header);
    defer allocator.free(fat);

    const dir_stream = try readSectorChain(allocator, data, fat, header.sector_size, header.first_dir_sector, null);
    defer allocator.free(dir_stream);

    var root: ?DirEntry = null;
    var target: ?DirEntry = null;
    var offset: usize = 0;
    while (offset + 128 <= dir_stream.len) : (offset += 128) {
        const entry_data = dir_stream[offset..][0..128];
        const entry = parseDirEntry(entry_data);
        if (entry.object_type == 5) root = entry;
        if (entry.object_type == 2 and entryNameEquals(entry_data, name)) target = entry;
    }

    const entry = target orelse return error.UnsupportedFormat;
    if (entry.stream_size >= header.mini_stream_cutoff) {
        return readSectorChain(allocator, data, fat, header.sector_size, entry.start_sector, entry.stream_size);
    }

    const root_entry = root orelse return error.UnsupportedVariant;
    if (root_entry.start_sector == end_of_chain or header.num_minifat_sectors == 0) return error.UnsupportedVariant;
    const mini_stream = try readSectorChain(allocator, data, fat, header.sector_size, root_entry.start_sector, root_entry.stream_size);
    defer allocator.free(mini_stream);
    const minifat_bytes = try readSectorChain(
        allocator,
        data,
        fat,
        header.sector_size,
        header.first_minifat_sector,
        @as(u64, header.num_minifat_sectors) * header.sector_size,
    );
    defer allocator.free(minifat_bytes);

    return readMiniSectorChain(allocator, mini_stream, minifat_bytes, header.mini_sector_size, entry.start_sector, entry.stream_size);
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_len) return error.TruncatedData;
    if (!matches(data)) return error.InvalidFormat;
    if (readU16(data, 0x1c) != 0xfffe) return error.UnsupportedVariant;
    const sector_shift = readU16(data, 0x1e);
    const mini_sector_shift = readU16(data, 0x20);
    if (sector_shift != 9 and sector_shift != 12) return error.UnsupportedVariant;
    if (mini_sector_shift != 6) return error.UnsupportedVariant;
    return .{
        .sector_size = @as(usize, 1) << @intCast(sector_shift),
        .mini_sector_size = @as(usize, 1) << @intCast(mini_sector_shift),
        .num_fat_sectors = readU32(data, 0x2c),
        .first_dir_sector = readU32(data, 0x30),
        .mini_stream_cutoff = readU32(data, 0x38),
        .first_minifat_sector = readU32(data, 0x3c),
        .num_minifat_sectors = readU32(data, 0x40),
        .first_difat_sector = readU32(data, 0x44),
        .num_difat_sectors = readU32(data, 0x48),
    };
}

fn readFat(allocator: std.mem.Allocator, data: []const u8, header: Header) bio.ReaderError![]u32 {
    const fat_sectors = try collectFatSectorIds(allocator, data, header);
    defer allocator.free(fat_sectors);

    const entries_per_sector = header.sector_size / 4;
    const total_entries = std.math.mul(usize, entries_per_sector, fat_sectors.len) catch return error.UnsupportedVariant;
    const fat = try allocator.alloc(u32, total_entries);
    errdefer allocator.free(fat);

    var fat_index: usize = 0;
    for (fat_sectors) |sector_id| {
        const sector = try sectorSlice(data, header.sector_size, sector_id);
        var entry_offset: usize = 0;
        while (entry_offset < header.sector_size) : (entry_offset += 4) {
            fat[fat_index] = readU32(sector, entry_offset);
            fat_index += 1;
        }
    }
    return fat;
}

fn collectFatSectorIds(allocator: std.mem.Allocator, data: []const u8, header: Header) bio.ReaderError![]u32 {
    if (header.num_fat_sectors == 0) return error.InvalidFormat;
    var ids: std.ArrayList(u32) = .empty;
    errdefer ids.deinit(allocator);

    var difat_offset: usize = 0x4c;
    var i: usize = 0;
    while (i < max_header_difat_entries and ids.items.len < header.num_fat_sectors) : (i += 1) {
        const sector_id = readU32(data, difat_offset);
        difat_offset += 4;
        if (sector_id != free_sector and sector_id != end_of_chain) try ids.append(allocator, sector_id);
    }

    var difat_sector = header.first_difat_sector;
    var difat_seen: u32 = 0;
    while (ids.items.len < header.num_fat_sectors) {
        if (difat_sector == end_of_chain or difat_sector == free_sector) return error.TruncatedData;
        if (difat_seen >= header.num_difat_sectors) return error.TruncatedData;
        const sector = try sectorSlice(data, header.sector_size, difat_sector);
        const entries = header.sector_size / 4 - 1;
        var entry: usize = 0;
        while (entry < entries and ids.items.len < header.num_fat_sectors) : (entry += 1) {
            const sector_id = readU32(sector, entry * 4);
            if (sector_id != free_sector and sector_id != end_of_chain) try ids.append(allocator, sector_id);
        }
        difat_sector = readU32(sector, header.sector_size - 4);
        difat_seen += 1;
    }

    return ids.toOwnedSlice(allocator);
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
        if (current == free_sector or current == fat_sector_marker or current == difat_sector_marker) return error.InvalidFormat;
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

fn readMiniSectorChain(
    allocator: std.mem.Allocator,
    mini_stream: []const u8,
    minifat_bytes: []const u8,
    mini_sector_size: usize,
    start_sector: u32,
    expected_size: u64,
) bio.ReaderError![]u8 {
    if (start_sector == free_sector or start_sector == end_of_chain) return error.InvalidFormat;
    const wanted_size = std.math.cast(usize, expected_size) orelse return error.UnsupportedVariant;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var current = start_sector;
    var sectors_seen: usize = 0;
    const entry_count = minifat_bytes.len / 4;
    while (current != end_of_chain) {
        if (current == free_sector or current >= entry_count) return error.TruncatedData;
        if (sectors_seen > entry_count) return error.InvalidFormat;
        sectors_seen += 1;

        const start = std.math.mul(usize, @as(usize, current), mini_sector_size) catch return error.UnsupportedVariant;
        const end = std.math.add(usize, start, mini_sector_size) catch return error.UnsupportedVariant;
        if (end > mini_stream.len) return error.TruncatedData;
        const remaining = wanted_size - out.items.len;
        const to_copy = @min(remaining, mini_sector_size);
        if (to_copy > 0) try out.appendSlice(allocator, mini_stream[start..][0..to_copy]);
        if (out.items.len >= wanted_size) break;
        current = readU32(minifat_bytes, @as(usize, current) * 4);
    }

    if (out.items.len != wanted_size) return error.TruncatedData;
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

fn entryNameAlloc(allocator: std.mem.Allocator, entry: []const u8) bio.ReaderError![]u8 {
    const name_bytes = readU16(entry, 64);
    if (name_bytes < 2 or (name_bytes % 2) != 0) return error.InvalidFormat;
    const chars = name_bytes / 2 - 1;
    const name = try allocator.alloc(u8, chars);
    errdefer allocator.free(name);
    var i: usize = 0;
    while (i < chars) : (i += 1) {
        const ch = readU16(entry, i * 2);
        name[i] = if (ch <= std.math.maxInt(u8)) @intCast(ch) else '?';
    }
    return name;
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
