const std = @import("std");
const bio = @import("../root.zig");

const max_database_bytes = 256 * 1024 * 1024;
const sqlite_signature = "SQLite format 3\x00";

const Table = struct {
    name: []const u8,
    root_page: u32,
    sql: []const u8,
};

const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

const Row = struct {
    values: []Value,
    owned_payload: ?[]u8 = null,

    fn deinit(self: Row, allocator: std.mem.Allocator) void {
        if (self.owned_payload) |payload| allocator.free(payload);
        allocator.free(self.values);
    }
};

const Rows = struct {
    items: []Row,

    fn deinit(self: Rows, allocator: std.mem.Allocator) void {
        for (self.items) |row| row.deinit(allocator);
        allocator.free(self.items);
    }
};

const RegionInfo = struct {
    id: i64,
    tile_size_x: u32,
    tile_size_y: u32,
    overlap_x: u32,
    overlap_y: u32,
    min_col: i64 = std.math.maxInt(i64),
    max_col: i64 = std.math.minInt(i64),
    min_row: i64 = std.math.maxInt(i64),
    max_row: i64 = std.math.minInt(i64),
    size_z: u16 = 1,
    size_t: u16 = 1,
};

const SqliteDb = struct {
    data: []const u8,
    page_size: usize,

    fn init(data: []const u8) bio.ReaderError!SqliteDb {
        if (!matches(data)) return error.InvalidFormat;
        const raw_page_size = std.mem.readInt(u16, data[16..18], .big);
        const page_size: usize = if (raw_page_size == 1) 65536 else raw_page_size;
        if (page_size < 512 or page_size > 65536 or data.len < page_size) return error.InvalidFormat;
        return .{ .data = data, .page_size = page_size };
    }

    fn page(self: SqliteDb, page_number: u32) bio.ReaderError![]const u8 {
        if (page_number == 0) return error.InvalidFormat;
        const start = std.math.mul(usize, page_number - 1, self.page_size) catch return error.InvalidFormat;
        const end = start + self.page_size;
        if (end > self.data.len) return error.TruncatedData;
        return self.data[start..end];
    }
};

pub fn matches(data: []const u8) bool {
    return data.len >= 100 and
        std.mem.eql(u8, data[0..sqlite_signature.len], sqlite_signature) and
        containsAsciiIgnoreCase(data, "CREATE TABLE region") and
        containsAsciiIgnoreCase(data, "CREATE TABLE fovs") and
        containsAsciiIgnoreCase(data, "CREATE TABLE images") and
        containsAsciiIgnoreCase(data, "CREATE TABLE channels");
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "tfcyto") or hasExtension(path, "aqproj");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    return readDatabaseMetadata(std.heap.smp_allocator, data);
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    if (!isPath(path)) return error.InvalidFormat;
    const db_path = if (hasExtension(path, "aqproj"))
        try findProjectDatabase(allocator, io, path)
    else
        try allocator.dupe(u8, path);
    defer allocator.free(db_path);

    const data = try std.Io.Dir.cwd().readFileAlloc(io, db_path, allocator, .limited(max_database_bytes));
    defer allocator.free(data);
    return readDatabaseMetadata(allocator, data);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const full = bio.Region.full(metadata);
    return readDatabasePlane(allocator, data, plane_index, full);
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const db_path = if (hasExtension(path, "aqproj"))
        try findProjectDatabase(allocator, io, path)
    else
        try allocator.dupe(u8, path);
    defer allocator.free(db_path);

    const data = try std.Io.Dir.cwd().readFileAlloc(io, db_path, allocator, .limited(max_database_bytes));
    defer allocator.free(data);
    return readDatabasePlane(allocator, data, plane_index, region);
}

fn readDatabaseMetadata(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Metadata {
    const db = try SqliteDb.init(data);
    const tables = try readTables(allocator, db);
    defer allocator.free(tables);

    const region_table = findTable(tables, "region") orelse return error.InvalidFormat;
    const fovs_table = findTable(tables, "fovs") orelse return error.InvalidFormat;
    const images_table = findTable(tables, "images") orelse return error.InvalidFormat;
    const channels_table = findTable(tables, "channels") orelse return error.InvalidFormat;

    var region = try readFirstRegion(allocator, db, region_table);
    try applyFovBounds(allocator, db, fovs_table, region_table, &region);
    try applyImageDimensions(allocator, db, images_table, region.id, &region);
    const channel_info = try readChannelInfo(allocator, db, channels_table);

    const tile_step_x = if (region.tile_size_x > region.overlap_x) region.tile_size_x - region.overlap_x else region.tile_size_x;
    const tile_step_y = if (region.tile_size_y > region.overlap_y) region.tile_size_y - region.overlap_y else region.tile_size_y;
    const x_tiles = if (region.min_col <= region.max_col) @as(u32, @intCast(region.max_col - region.min_col + 1)) else 1;
    const y_tiles = if (region.min_row <= region.max_row) @as(u32, @intCast(region.max_row - region.min_row + 1)) else 1;
    const width = std.math.mul(u32, x_tiles, tile_step_x) catch return error.UnsupportedVariant;
    const height = std.math.mul(u32, y_tiles, tile_step_y) catch return error.UnsupportedVariant;

    var size_c = channel_info.size_c;
    var samples_per_pixel: u16 = 1;
    var pixel_type: bio.PixelType = if (channel_info.save_16bit) .uint16 else .uint8;
    var plane_count_c = size_c;
    if (size_c == 1 and pixel_type == .uint8) {
        size_c = 3;
        samples_per_pixel = 3;
        pixel_type = .rgb8;
        plane_count_c = 1;
    }

    const zc = std.math.mul(u32, region.size_z, plane_count_c) catch return error.UnsupportedVariant;
    const plane_count = std.math.mul(u32, zc, region.size_t) catch return error.UnsupportedVariant;
    return .{
        .format = "tissuefaxs",
        .width = width,
        .height = height,
        .size_c = size_c,
        .samples_per_pixel = samples_per_pixel,
        .size_z = region.size_z,
        .size_t = region.size_t,
        .pixel_type = pixel_type,
        .little_endian = true,
        .plane_count = plane_count,
        .dimension_order = "XYCZT",
    };
}

fn readDatabasePlane(allocator: std.mem.Allocator, data: []const u8, plane_index: u32, region: bio.Region) bio.ReaderError!bio.Plane {
    const metadata = try readDatabaseMetadata(allocator, data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    try region.validate(metadata);
    if (metadata.samples_per_pixel != 1) return error.UnsupportedVariant;

    const db = try SqliteDb.init(data);
    const tables = try readTables(allocator, db);
    defer allocator.free(tables);

    const region_table = findTable(tables, "region") orelse return error.InvalidFormat;
    const fovs_table = findTable(tables, "fovs") orelse return error.InvalidFormat;
    const images_table = findTable(tables, "images") orelse return error.InvalidFormat;

    var region_info = try readFirstRegion(allocator, db, region_table);
    try applyFovBounds(allocator, db, fovs_table, region_table, &region_info);
    if (region_info.overlap_x != 0 or region_info.overlap_y != 0) return error.UnsupportedVariant;

    const zct = try planeToZct(metadata, plane_index);
    const full_len = try planeByteCount(metadata);
    const full = try allocator.alloc(u8, full_len);
    errdefer allocator.free(full);
    @memset(full, 0);
    try copyRawTiles(allocator, db, images_table, region_info, metadata, zct, full);
    if (region.isFull(metadata)) return .{ .metadata = metadata, .data = full };
    defer allocator.free(full);
    return .{
        .metadata = metadata,
        .data = try bio.cropPlane(allocator, .{ .metadata = metadata, .data = full }, region),
    };
}

fn readTables(allocator: std.mem.Allocator, db: SqliteDb) bio.ReaderError![]Table {
    const rows = try readTableRows(allocator, db, 1);
    defer rows.deinit(allocator);

    var tables: std.ArrayList(Table) = .empty;
    errdefer tables.deinit(allocator);
    for (rows.items) |row| {
        if (row.values.len < 5) continue;
        const table_type = valueText(row.values[0]) orelse continue;
        if (!std.ascii.eqlIgnoreCase(table_type, "table")) continue;
        const name = valueText(row.values[1]) orelse continue;
        const root_page_raw = valueInt(row.values[3]) orelse continue;
        const sql = valueText(row.values[4]) orelse continue;
        if (root_page_raw <= 0 or root_page_raw > std.math.maxInt(u32)) continue;
        try tables.append(allocator, .{
            .name = name,
            .root_page = @intCast(root_page_raw),
            .sql = sql,
        });
    }
    return tables.toOwnedSlice(allocator);
}

fn readFirstRegion(allocator: std.mem.Allocator, db: SqliteDb, table: Table) bio.ReaderError!RegionInfo {
    const rows = try readTableRows(allocator, db, table.root_page);
    defer rows.deinit(allocator);

    const id_index = columnIndex(table.sql, "id") orelse return error.InvalidFormat;
    const data_index = columnIndex(table.sql, "data") orelse return error.InvalidFormat;
    const timelapse_index = columnIndex(table.sql, "is_timelapse") orelse null;
    var timepoints: u16 = 0;
    var first: ?RegionInfo = null;

    for (rows.items) |row| {
        if (id_index >= row.values.len or data_index >= row.values.len) continue;
        const id = valueInt(row.values[id_index]) orelse continue;
        const json = valueText(row.values[data_index]) orelse continue;
        const tile_size_x = jsonInt(json, "ImageWidth") orelse continue;
        const tile_size_y = jsonInt(json, "ImageHeight") orelse continue;
        const overlap_x = jsonInt(json, "OverlapWidth") orelse 0;
        const overlap_y = jsonInt(json, "OverlapHeight") orelse 0;

        const is_timelapse = if (timelapse_index) |index|
            index < row.values.len and (valueInt(row.values[index]) orelse 0) != 0
        else
            false;
        if (is_timelapse or first == null) timepoints += 1;
        if (first == null) {
            first = .{
                .id = id,
                .tile_size_x = tile_size_x,
                .tile_size_y = tile_size_y,
                .overlap_x = overlap_x,
                .overlap_y = overlap_y,
                .size_t = 1,
            };
        }
    }

    var region = first orelse return error.InvalidFormat;
    region.size_t = @max(1, timepoints);
    return region;
}

fn applyFovBounds(
    allocator: std.mem.Allocator,
    db: SqliteDb,
    table: Table,
    region_table: Table,
    region: *RegionInfo,
) bio.ReaderError!void {
    _ = region_table;
    const rows = try readTableRows(allocator, db, table.root_page);
    defer rows.deinit(allocator);

    const region_index = columnIndex(table.sql, "region_id") orelse return;
    const row_index = columnIndex(table.sql, "row") orelse return error.InvalidFormat;
    const column_index = columnIndex(table.sql, "column") orelse return error.InvalidFormat;
    for (rows.items) |row| {
        if (region_index >= row.values.len or row_index >= row.values.len or column_index >= row.values.len) continue;
        if ((valueInt(row.values[region_index]) orelse -1) != region.id) continue;
        const fov_row = valueInt(row.values[row_index]) orelse continue;
        const fov_col = valueInt(row.values[column_index]) orelse continue;
        region.min_row = @min(region.min_row, fov_row);
        region.max_row = @max(region.max_row, fov_row);
        region.min_col = @min(region.min_col, fov_col);
        region.max_col = @max(region.max_col, fov_col);
    }
}

fn applyImageDimensions(allocator: std.mem.Allocator, db: SqliteDb, table: Table, region_id: i64, region: *RegionInfo) bio.ReaderError!void {
    const rows = try readTableRows(allocator, db, table.root_page);
    defer rows.deinit(allocator);

    const region_index = columnIndex(table.sql, "region") orelse return error.InvalidFormat;
    const z_index = columnIndex(table.sql, "z_position") orelse return error.InvalidFormat;
    var z_values: std.ArrayList(i64) = .empty;
    defer z_values.deinit(allocator);

    for (rows.items) |row| {
        if (region_index >= row.values.len or z_index >= row.values.len) continue;
        if ((valueInt(row.values[region_index]) orelse -1) != region_id) continue;
        const z = valueInt(row.values[z_index]) orelse continue;
        if (!containsInt(z_values.items, z)) try z_values.append(allocator, z);
    }
    if (z_values.items.len > std.math.maxInt(u16)) return error.UnsupportedVariant;
    region.size_z = @max(1, @as(u16, @intCast(z_values.items.len)));
}

fn readChannelInfo(allocator: std.mem.Allocator, db: SqliteDb, table: Table) bio.ReaderError!struct { size_c: u16, save_16bit: bool } {
    const rows = try readTableRows(allocator, db, table.root_page);
    defer rows.deinit(allocator);

    const id_index = columnIndex(table.sql, "id") orelse return error.InvalidFormat;
    const save_index = columnIndex(table.sql, "save_16bit") orelse null;
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(allocator);
    var save_16bit = false;

    for (rows.items) |row| {
        if (id_index >= row.values.len) continue;
        const id = valueInt(row.values[id_index]) orelse continue;
        if (!containsInt(ids.items, id)) try ids.append(allocator, id);
        if (save_index) |index| {
            if (index < row.values.len and (valueInt(row.values[index]) orelse 0) != 0) save_16bit = true;
        }
    }

    if (ids.items.len > std.math.maxInt(u16)) return error.UnsupportedVariant;
    return .{ .size_c = @max(1, @as(u16, @intCast(ids.items.len))), .save_16bit = save_16bit };
}

const Zct = struct {
    z: u32,
    c: u32,
    t: u32,
};

fn planeToZct(metadata: bio.Metadata, plane_index: u32) bio.ReaderError!Zct {
    const size_z: u32 = metadata.size_z;
    const size_c: u32 = metadata.size_c;
    const zc = std.math.mul(u32, size_z, size_c) catch return error.InvalidPlaneIndex;
    return .{
        .z = plane_index % size_z,
        .c = (plane_index / size_z) % size_c,
        .t = plane_index / zc,
    };
}

fn copyRawTiles(
    allocator: std.mem.Allocator,
    db: SqliteDb,
    table: Table,
    region: RegionInfo,
    metadata: bio.Metadata,
    zct: Zct,
    out: []u8,
) bio.ReaderError!void {
    const rows = try readTableRows(allocator, db, table.root_page);
    defer rows.deinit(allocator);

    const region_index = columnIndex(table.sql, "region") orelse return error.InvalidFormat;
    const level_index = columnIndex(table.sql, "level") orelse return error.InvalidFormat;
    const channel_index = columnIndex(table.sql, "channel") orelse return error.InvalidFormat;
    const is_zstack_index = columnIndex(table.sql, "is_zstack") orelse return error.InvalidFormat;
    const z_position_index = columnIndex(table.sql, "z_position") orelse return error.InvalidFormat;
    const row_index = columnIndex(table.sql, "row") orelse return error.InvalidFormat;
    const column_index = columnIndex(table.sql, "column") orelse return error.InvalidFormat;
    const data_index = columnIndex(table.sql, "data") orelse return error.InvalidFormat;
    const compression_index = columnIndex(table.sql, "compression") orelse return error.InvalidFormat;

    const bpp = metadata.bytesPerPixel();
    const tile_len = std.math.mul(usize, std.math.mul(usize, region.tile_size_x, region.tile_size_y) catch return error.UnsupportedVariant, bpp) catch return error.UnsupportedVariant;
    const dst_row_bytes = std.math.mul(usize, metadata.width, bpp) catch return error.UnsupportedVariant;
    const src_row_bytes = std.math.mul(usize, region.tile_size_x, bpp) catch return error.UnsupportedVariant;

    for (rows.items) |row| {
        if (maxIndex(&.{ region_index, level_index, channel_index, is_zstack_index, z_position_index, row_index, column_index, data_index, compression_index }) >= row.values.len) continue;
        if ((valueInt(row.values[region_index]) orelse -1) != region.id) continue;
        if ((valueInt(row.values[level_index]) orelse -1) != 0) continue;
        if ((valueInt(row.values[channel_index]) orelse -1) != @as(i64, zct.c) + 1) continue;
        const expected_zstack: i64 = if (zct.z > 0) 1 else 0;
        if ((valueInt(row.values[is_zstack_index]) orelse -1) != expected_zstack) continue;
        if ((valueInt(row.values[z_position_index]) orelse -1) != @as(i64, @intCast(zct.z))) continue;
        const compression = valueInt(row.values[compression_index]) orelse return error.InvalidFormat;
        if (compression != 0 and compression != 1) return error.UnsupportedVariant;
        const tile = valueBlob(row.values[data_index]) orelse return error.InvalidFormat;
        if (tile.len != tile_len) return error.UnsupportedVariant;
        const tile_row = valueInt(row.values[row_index]) orelse return error.InvalidFormat;
        const tile_col = valueInt(row.values[column_index]) orelse return error.InvalidFormat;
        if (tile_row < region.min_row or tile_col < region.min_col) return error.InvalidFormat;
        const dst_x_tiles: usize = @intCast(tile_col - region.min_col);
        const dst_y_tiles: usize = @intCast(tile_row - region.min_row);
        const dst_x = std.math.mul(usize, dst_x_tiles, region.tile_size_x) catch return error.UnsupportedVariant;
        const dst_y = std.math.mul(usize, dst_y_tiles, region.tile_size_y) catch return error.UnsupportedVariant;
        if (dst_x + region.tile_size_x > metadata.width or dst_y + region.tile_size_y > metadata.height) return error.UnsupportedVariant;

        var y: usize = 0;
        while (y < region.tile_size_y) : (y += 1) {
            const src_offset = y * src_row_bytes;
            const dst_offset = (dst_y + y) * dst_row_bytes + dst_x * bpp;
            @memcpy(out[dst_offset..][0..src_row_bytes], tile[src_offset..][0..src_row_bytes]);
        }
    }
}

fn readTableRows(allocator: std.mem.Allocator, db: SqliteDb, root_page: u32) bio.ReaderError!Rows {
    var list: std.ArrayList(Row) = .empty;
    errdefer {
        for (list.items) |row| row.deinit(allocator);
        list.deinit(allocator);
    }
    try collectRows(allocator, db, root_page, &list, 0);
    return .{ .items = try list.toOwnedSlice(allocator) };
}

fn collectRows(allocator: std.mem.Allocator, db: SqliteDb, page_number: u32, rows: *std.ArrayList(Row), depth: u8) bio.ReaderError!void {
    if (depth > 16) return error.UnsupportedVariant;
    const page = try db.page(page_number);
    const header_offset: usize = if (page_number == 1) 100 else 0;
    if (header_offset + 8 > page.len) return error.TruncatedData;
    const page_type = page[header_offset];
    const cell_count = readBeU16(page, header_offset + 3);
    const pointer_start = header_offset + 8 + if (page_type == 0x05) @as(usize, 4) else 0;
    if (pointer_start + @as(usize, cell_count) * 2 > page.len) return error.TruncatedData;

    switch (page_type) {
        0x0d => {
            var i: u16 = 0;
            while (i < cell_count) : (i += 1) {
                const cell_offset = readBeU16(page, pointer_start + @as(usize, i) * 2);
                const row = try parseTableLeafCell(allocator, db, page_number, cell_offset);
                try rows.append(allocator, row);
            }
        },
        0x05 => {
            var i: u16 = 0;
            while (i < cell_count) : (i += 1) {
                const cell_offset = readBeU16(page, pointer_start + @as(usize, i) * 2);
                if (cell_offset + 4 > page.len) return error.TruncatedData;
                const child = readBeU32(page, cell_offset);
                try collectRows(allocator, db, child, rows, depth + 1);
            }
            const right_child = readBeU32(page, header_offset + 8);
            try collectRows(allocator, db, right_child, rows, depth + 1);
        },
        else => return error.InvalidFormat,
    }
}

fn parseTableLeafCell(allocator: std.mem.Allocator, db: SqliteDb, page_number: u32, cell_offset: usize) bio.ReaderError!Row {
    const page = try db.page(page_number);
    var pos = cell_offset;
    const payload_len = try readVarint(page, &pos);
    _ = try readVarint(page, &pos);
    if (payload_len > std.math.maxInt(usize)) return error.UnsupportedVariant;
    const payload_size: usize = @intCast(payload_len);
    const local_size = localPayloadSize(db.page_size, payload_size);
    if (pos + local_size > page.len) return error.TruncatedData;

    if (local_size == payload_size) {
        return parseRecord(allocator, page[pos .. pos + local_size], null);
    }

    if (pos + local_size + 4 > page.len) return error.TruncatedData;
    const payload = try allocator.alloc(u8, payload_size);
    errdefer allocator.free(payload);
    @memcpy(payload[0..local_size], page[pos .. pos + local_size]);
    var written = local_size;
    var overflow_page = readBeU32(page, pos + local_size);
    while (written < payload.len and overflow_page != 0) {
        const overflow = try db.page(overflow_page);
        const next = readBeU32(overflow, 0);
        const chunk = @min(payload.len - written, db.page_size - 4);
        @memcpy(payload[written .. written + chunk], overflow[4 .. 4 + chunk]);
        written += chunk;
        overflow_page = next;
    }
    if (written != payload.len) return error.TruncatedData;
    return parseRecord(allocator, payload, payload);
}

fn parseRecord(allocator: std.mem.Allocator, payload: []const u8, owned_payload: ?[]u8) bio.ReaderError!Row {
    var header_pos: usize = 0;
    const header_size_raw = try readVarint(payload, &header_pos);
    if (header_size_raw > payload.len) return error.InvalidFormat;
    const header_size: usize = @intCast(header_size_raw);

    var serials: std.ArrayList(u64) = .empty;
    defer serials.deinit(allocator);
    while (header_pos < header_size) {
        try serials.append(allocator, try readVarint(payload, &header_pos));
    }

    const values = try allocator.alloc(Value, serials.items.len);
    errdefer allocator.free(values);
    var data_pos = header_size;
    for (serials.items, 0..) |serial, i| {
        values[i] = try parseValue(payload, &data_pos, serial);
    }
    return .{ .values = values, .owned_payload = owned_payload };
}

fn parseValue(payload: []const u8, pos: *usize, serial: u64) bio.ReaderError!Value {
    switch (serial) {
        0 => return .null,
        1 => return .{ .integer = try readSigned(payload, pos, 1) },
        2 => return .{ .integer = try readSigned(payload, pos, 2) },
        3 => return .{ .integer = try readSigned(payload, pos, 3) },
        4 => return .{ .integer = try readSigned(payload, pos, 4) },
        5 => return .{ .integer = try readSigned(payload, pos, 6) },
        6 => return .{ .integer = try readSigned(payload, pos, 8) },
        7 => {
            if (pos.* + 8 > payload.len) return error.TruncatedData;
            const bits = std.mem.readInt(u64, payload[pos.*..][0..8], .big);
            pos.* += 8;
            return .{ .real = @bitCast(bits) };
        },
        8 => return .{ .integer = 0 },
        9 => return .{ .integer = 1 },
        else => {
            if (serial < 12) return error.UnsupportedVariant;
            const len: usize = @intCast((serial - 12) / 2);
            if (pos.* + len > payload.len) return error.TruncatedData;
            const bytes = payload[pos.* .. pos.* + len];
            pos.* += len;
            return if (serial % 2 == 0) .{ .blob = bytes } else .{ .text = bytes };
        },
    }
}

fn localPayloadSize(page_size: usize, payload_size: usize) usize {
    const max_local = page_size - 35;
    if (payload_size <= max_local) return payload_size;
    const min_local = ((page_size - 12) * 32 / 255) - 23;
    var local = min_local + ((payload_size - min_local) % (page_size - 4));
    if (local > max_local) local = min_local;
    return local;
}

fn readVarint(data: []const u8, pos: *usize) bio.ReaderError!u64 {
    var value: u64 = 0;
    var i: u8 = 0;
    while (i < 9) : (i += 1) {
        if (pos.* >= data.len) return error.TruncatedData;
        const byte = data[pos.*];
        pos.* += 1;
        if (i == 8) return (value << 8) | byte;
        value = (value << 7) | (byte & 0x7f);
        if ((byte & 0x80) == 0) return value;
    }
    return error.InvalidFormat;
}

fn readSigned(data: []const u8, pos: *usize, len: usize) bio.ReaderError!i64 {
    if (pos.* + len > data.len) return error.TruncatedData;
    var value: i64 = 0;
    for (data[pos.* .. pos.* + len]) |byte| value = (value << 8) | byte;
    pos.* += len;
    const shift: u6 = @intCast(64 - len * 8);
    return (value << shift) >> shift;
}

fn readBeU16(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .big);
}

fn readBeU32(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

fn findTable(tables: []const Table, name: []const u8) ?Table {
    for (tables) |table| {
        if (std.ascii.eqlIgnoreCase(table.name, name)) return table;
    }
    return null;
}

fn columnIndex(sql: []const u8, column: []const u8) ?usize {
    const open = std.mem.indexOfScalar(u8, sql, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, sql, ')') orelse sql.len;
    var index: usize = 0;
    var parts = std.mem.splitScalar(u8, sql[open + 1 .. close], ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        const token = firstSqlToken(part) orelse continue;
        if (isTableConstraint(token)) continue;
        if (std.ascii.eqlIgnoreCase(stripSqlQuotes(token), column)) return index;
        index += 1;
    }
    return null;
}

fn firstSqlToken(part: []const u8) ?[]const u8 {
    if (part.len == 0) return null;
    if (part[0] == '"' or part[0] == '`' or part[0] == '[') {
        const closing: u8 = if (part[0] == '[') ']' else part[0];
        const end = std.mem.indexOfScalarPos(u8, part, 1, closing) orelse return part;
        return part[0 .. end + 1];
    }
    var end: usize = 0;
    while (end < part.len and !std.ascii.isWhitespace(part[end])) : (end += 1) {}
    return part[0..end];
}

fn stripSqlQuotes(token: []const u8) []const u8 {
    if (token.len >= 2 and ((token[0] == '"' and token[token.len - 1] == '"') or
        (token[0] == '`' and token[token.len - 1] == '`') or
        (token[0] == '[' and token[token.len - 1] == ']')))
    {
        return token[1 .. token.len - 1];
    }
    return token;
}

fn isTableConstraint(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "PRIMARY") or
        std.ascii.eqlIgnoreCase(token, "CONSTRAINT") or
        std.ascii.eqlIgnoreCase(token, "UNIQUE") or
        std.ascii.eqlIgnoreCase(token, "CHECK") or
        std.ascii.eqlIgnoreCase(token, "FOREIGN");
}

fn jsonInt(json: []const u8, key: []const u8) ?u32 {
    var key_buf: [128]u8 = undefined;
    if (key.len + 2 > key_buf.len) return null;
    key_buf[0] = '"';
    @memcpy(key_buf[1 .. 1 + key.len], key);
    key_buf[1 + key.len] = '"';
    const pattern = key_buf[0 .. key.len + 2];
    const key_pos = std.mem.indexOf(u8, json, pattern) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, json, key_pos + pattern.len, ':') orelse return null;
    var pos = colon + 1;
    while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
    return firstUnsigned(json[pos..]);
}

fn firstUnsigned(bytes: []const u8) ?u32 {
    var pos: usize = 0;
    while (pos < bytes.len and !std.ascii.isDigit(bytes[pos])) : (pos += 1) {}
    var value: u32 = 0;
    var saw = false;
    while (pos < bytes.len and std.ascii.isDigit(bytes[pos])) : (pos += 1) {
        saw = true;
        value = std.math.mul(u32, value, 10) catch return null;
        value = std.math.add(u32, value, bytes[pos] - '0') catch return null;
    }
    return if (saw) value else null;
}

fn valueInt(value: Value) ?i64 {
    return switch (value) {
        .integer => |v| v,
        .real => |v| @intFromFloat(v),
        else => null,
    };
}

fn valueText(value: Value) ?[]const u8 {
    return switch (value) {
        .text => |v| v,
        else => null,
    };
}

fn valueBlob(value: Value) ?[]const u8 {
    return switch (value) {
        .blob => |v| v,
        else => null,
    };
}

fn maxIndex(indexes: []const usize) usize {
    var out: usize = 0;
    for (indexes) |index| out = @max(out, index);
    return out;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn containsInt(values: []const i64, needle: i64) bool {
    for (values) |value| {
        if (value == needle) return true;
    }
    return false;
}

fn findProjectDatabase(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, "Slide ")) continue;
        const slide = try joinPath(allocator, parent, entry.name);
        defer allocator.free(slide);
        var slide_dir = std.Io.Dir.cwd().openDir(io, slide, .{ .iterate = true }) catch continue;
        defer slide_dir.close(io);
        var slide_iter = slide_dir.iterate();
        while (try slide_iter.next(io)) |slide_entry| {
            if (slide_entry.kind == .file and hasExtension(slide_entry.name, "tfcyto")) {
                return joinPath(allocator, slide, slide_entry.name);
            }
        }
    }
    return error.FileNotFound;
}

fn parentPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const sep = lastSeparator(path) orelse return allocator.dupe(u8, ".");
    if (sep == 0) return allocator.dupe(u8, path[0..1]);
    return allocator.dupe(u8, path[0..sep]);
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    const sep: u8 = if (std.mem.indexOfScalar(u8, base, '\\') != null) '\\' else '/';
    const needs_sep = base.len != 0 and base[base.len - 1] != '/' and base[base.len - 1] != '\\';
    const extra: usize = if (needs_sep) 1 else 0;
    const out = try allocator.alloc(u8, base.len + extra + name.len);
    @memcpy(out[0..base.len], base);
    if (needs_sep) out[base.len] = sep;
    @memcpy(out[base.len + extra ..], name);
    return out;
}

fn lastSeparator(path: []const u8) ?usize {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    if (slash == null) return backslash;
    if (backslash == null) return slash;
    return @max(slash.?, backslash.?);
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var pos: usize = 0;
    while (pos + needle.len <= haystack.len) : (pos += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[pos .. pos + needle.len], needle)) return true;
    }
    return false;
}

const TestValue = union(enum) {
    integer: i64,
    text: []const u8,
    blob: []const u8,
};

fn appendVarint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    if (value <= 0x7f) {
        try list.append(allocator, @intCast(value));
        return;
    }
    var bytes: [9]u8 = undefined;
    var len: usize = 0;
    var remaining = value;
    while (remaining != 0 and len < 9) : (len += 1) {
        bytes[bytes.len - 1 - len] = @intCast(remaining & 0x7f);
        remaining >>= 7;
    }
    const start = bytes.len - len;
    for (bytes[start..], 0..) |byte, i| {
        try list.append(allocator, if (i + 1 == len) byte else byte | 0x80);
    }
}

fn testRecord(allocator: std.mem.Allocator, values: []const TestValue) ![]u8 {
    var serials: std.ArrayList(u8) = .empty;
    defer serials.deinit(allocator);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    for (values) |value| {
        switch (value) {
            .integer => |v| {
                if (v == 0) {
                    try appendVarint(&serials, allocator, 8);
                } else if (v == 1) {
                    try appendVarint(&serials, allocator, 9);
                } else {
                    try appendVarint(&serials, allocator, 1);
                    try body.append(allocator, @bitCast(@as(i8, @intCast(v))));
                }
            },
            .text => |text| {
                try appendVarint(&serials, allocator, 13 + text.len * 2);
                try body.appendSlice(allocator, text);
            },
            .blob => |blob| {
                try appendVarint(&serials, allocator, 12 + blob.len * 2);
                try body.appendSlice(allocator, blob);
            },
        }
    }

    var record: std.ArrayList(u8) = .empty;
    errdefer record.deinit(allocator);
    try appendVarint(&record, allocator, serials.items.len + 1);
    try record.appendSlice(allocator, serials.items);
    try record.appendSlice(allocator, body.items);
    return record.toOwnedSlice(allocator);
}

fn writeLeafPage(data: []u8, page_size: usize, page_number: u32, records: []const []const u8) void {
    const page_start = (page_number - 1) * page_size;
    const header = page_start + if (page_number == 1) @as(usize, 100) else 0;
    data[header] = 0x0d;
    std.mem.writeInt(u16, data[header + 3 ..][0..2], @intCast(records.len), .big);
    var cell_end = page_start + page_size;
    for (records, 0..) |record, i| {
        var cell: [512]u8 = undefined;
        var list: std.ArrayList(u8) = .initBuffer(&cell);
        appendVarint(&list, std.testing.allocator, record.len) catch unreachable;
        appendVarint(&list, std.testing.allocator, i + 1) catch unreachable;
        list.appendSliceBounded(record) catch unreachable;
        cell_end -= list.items.len;
        @memcpy(data[cell_end .. cell_end + list.items.len], list.items);
        std.mem.writeInt(u16, data[header + 8 + i * 2 ..][0..2], @intCast(cell_end - page_start), .big);
    }
    std.mem.writeInt(u16, data[header + 5 ..][0..2], @intCast(cell_end - page_start), .big);
}

fn makeTestDatabase(allocator: std.mem.Allocator) ![]u8 {
    const page_size = 1024;
    const data = try allocator.alloc(u8, page_size * 5);
    @memset(data, 0);
    @memcpy(data[0..sqlite_signature.len], sqlite_signature);
    std.mem.writeInt(u16, data[16..18], page_size, .big);

    const schema = [_][]const u8{
        try testRecord(allocator, &.{ .{ .text = "table" }, .{ .text = "region" }, .{ .text = "region" }, .{ .integer = 2 }, .{ .text = "CREATE TABLE region (id INTEGER, data TEXT, is_timelapse INTEGER)" } }),
        try testRecord(allocator, &.{ .{ .text = "table" }, .{ .text = "fovs" }, .{ .text = "fovs" }, .{ .integer = 3 }, .{ .text = "CREATE TABLE fovs (region_id INTEGER, row INTEGER, column INTEGER)" } }),
        try testRecord(allocator, &.{ .{ .text = "table" }, .{ .text = "images" }, .{ .text = "images" }, .{ .integer = 4 }, .{ .text = "CREATE TABLE images (region INTEGER, level INTEGER, channel INTEGER, is_zstack INTEGER, z_position INTEGER, row INTEGER, column INTEGER, data BLOB, compression INTEGER)" } }),
        try testRecord(allocator, &.{ .{ .text = "table" }, .{ .text = "channels" }, .{ .text = "channels" }, .{ .integer = 5 }, .{ .text = "CREATE TABLE channels (id INTEGER, name TEXT, save_16bit INTEGER)" } }),
    };
    defer for (schema) |record| allocator.free(record);
    writeLeafPage(data, page_size, 1, &schema);

    const region_rows = [_][]const u8{
        try testRecord(allocator, &.{ .{ .integer = 1 }, .{ .text = "{\"ImageWidth\":4,\"ImageHeight\":3,\"OverlapWidth\":0,\"OverlapHeight\":0,\"CacheStep\":2}" }, .{ .integer = 0 } }),
    };
    defer for (region_rows) |record| allocator.free(record);
    writeLeafPage(data, page_size, 2, &region_rows);

    const fov_rows = [_][]const u8{
        try testRecord(allocator, &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }),
        try testRecord(allocator, &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 1 } }),
    };
    defer for (fov_rows) |record| allocator.free(record);
    writeLeafPage(data, page_size, 3, &fov_rows);

    const image_rows = [_][]const u8{
        try testRecord(allocator, &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .blob = &.{ 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8, 0, 9, 0, 10, 0, 11, 0, 12, 0 } }, .{ .integer = 0 } }),
        try testRecord(allocator, &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 2 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .blob = &.{ 21, 0, 22, 0, 23, 0, 24, 0, 25, 0, 26, 0, 27, 0, 28, 0, 29, 0, 30, 0, 31, 0, 32, 0 } }, .{ .integer = 1 } }),
        try testRecord(allocator, &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 1 }, .{ .integer = 1 }, .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .blob = &.{ 41, 0, 42, 0, 43, 0, 44, 0, 45, 0, 46, 0, 47, 0, 48, 0, 49, 0, 50, 0, 51, 0, 52, 0 } }, .{ .integer = 0 } }),
    };
    defer for (image_rows) |record| allocator.free(record);
    writeLeafPage(data, page_size, 4, &image_rows);

    const channel_rows = [_][]const u8{
        try testRecord(allocator, &.{ .{ .integer = 1 }, .{ .text = "DAPI" }, .{ .integer = 1 } }),
        try testRecord(allocator, &.{ .{ .integer = 2 }, .{ .text = "FITC" }, .{ .integer = 1 } }),
    };
    defer for (channel_rows) |record| allocator.free(record);
    writeLeafPage(data, page_size, 5, &channel_rows);

    return data;
}

test "reads tissuefaxs metadata from sqlite tables" {
    const data = try makeTestDatabase(std.testing.allocator);
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("tissuefaxs", metadata.format);
    try std.testing.expectEqual(@as(u32, 8), metadata.width);
    try std.testing.expectEqual(@as(u32, 3), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 4), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
}

test "reads tissuefaxs metadata through aqproj slide lookup" {
    const root = "tissuefaxs-test";
    const slide = "tissuefaxs-test/Slide 1";
    const project = "tissuefaxs-test/sample.aqproj";
    const db_path = "tissuefaxs-test/Slide 1/sample.tfcyto";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, slide);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = project, .data = "" });
    const data = try makeTestDatabase(std.testing.allocator);
    defer std.testing.allocator.free(data);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = db_path, .data = data });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, project);
    try std.testing.expectEqualStrings("tissuefaxs", metadata.format);
    try std.testing.expectEqual(@as(u32, 8), metadata.width);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
}

test "reads tissuefaxs raw passthrough tile plane" {
    const data = try makeTestDatabase(std.testing.allocator);
    defer std.testing.allocator.free(data);

    const plane = try readPlaneIndex(std.testing.allocator, data, 2);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("tissuefaxs", plane.metadata.format);
    try std.testing.expectEqual(bio.PixelType.uint16, plane.metadata.pixel_type);
    try std.testing.expectEqual(@as(usize, 48), plane.data.len);
    try std.testing.expectEqualSlices(u8, &.{ 21, 0, 22, 0, 23, 0, 24, 0 }, plane.data[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, plane.data[8..16]);
}

test "rejects non-sqlite tissuefaxs data" {
    try std.testing.expectError(error.InvalidFormat, readMetadata("not sqlite"));
}
