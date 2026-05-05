const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

const CellWorxInfo = struct {
    first_row: u32 = 0,
    first_col: u32 = 0,
    well_count: u32 = 0,
    field_count: u32 = 1,
    size_z: u16 = 1,
    size_c: u16 = 1,
    size_t: u16 = 1,
};

pub fn matches(data: []const u8) bool {
    return looksLikeHtd(data);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "htd") or hasExtension(path, "pnl") or hasExtension(path, "log");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!looksLikeHtd(data)) return error.InvalidFormat;
    return error.UnsupportedVariant;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const htd_path = try findHtdPath(allocator, io, path);
    defer allocator.free(htd_path);
    const htd = try readFile(allocator, io, htd_path);
    defer allocator.free(htd);
    const info = try parseHtd(htd);
    const pnl_path = try selectedPnlPath(allocator, htd_path, path, info);
    defer allocator.free(pnl_path);
    const pnl = try readFile(allocator, io, pnl_path);
    defer allocator.free(pnl);

    var metadata = try bio.deltavision.readMetadata(pnl);
    metadata.format = "cellworx";
    metadata.image_description = null;
    metadata.size_z = info.size_z;
    metadata.size_c = info.size_c;
    metadata.size_t = info.size_t;
    metadata.plane_count = @as(u32, info.size_z) * @as(u32, info.size_c) * @as(u32, info.size_t);
    metadata.dimension_order = "XYCZT";
    return metadata;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const htd_path = try findHtdPath(allocator, io, path);
    defer allocator.free(htd_path);
    const htd = try readFile(allocator, io, htd_path);
    defer allocator.free(htd);
    const info = try parseHtd(htd);
    const pnl_path = try selectedPnlPath(allocator, htd_path, path, info);
    defer allocator.free(pnl_path);
    const pnl = try readFile(allocator, io, pnl_path);
    defer allocator.free(pnl);

    var metadata = try bio.deltavision.readMetadata(pnl);
    metadata.format = "cellworx";
    metadata.image_description = null;
    metadata.size_z = info.size_z;
    metadata.size_c = info.size_c;
    metadata.size_t = info.size_t;
    metadata.plane_count = @as(u32, info.size_z) * @as(u32, info.size_c) * @as(u32, info.size_t);
    metadata.dimension_order = "XYCZT";
    try region.validate(metadata);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;

    var plane = try bio.deltavision.readPlaneIndex(allocator, pnl, plane_index);
    errdefer allocator.free(plane.data);
    plane.metadata = metadata;
    if (region.isFull(metadata)) return plane;

    const cropped = try cropPlane(allocator, plane.data, metadata, region);
    allocator.free(plane.data);
    return .{ .metadata = metadata, .data = cropped };
}

fn selectedPnlPath(allocator: std.mem.Allocator, htd_path: []const u8, selected_path: []const u8, info: CellWorxInfo) ![]u8 {
    if (hasExtension(selected_path, "pnl")) return allocator.dupe(u8, selected_path);
    const prefix = try platePrefix(allocator, htd_path);
    defer allocator.free(prefix);
    const well = try wellName(allocator, info.first_row, info.first_col);
    defer allocator.free(well);
    const stem = try concat(allocator, prefix, well);
    defer allocator.free(stem);
    return concat(allocator, stem, ".pnl");
}

fn parseHtd(data: []const u8) bio.ReaderError!CellWorxInfo {
    if (!looksLikeHtd(data)) return error.InvalidFormat;
    var info = CellWorxInfo{};
    var x_fields: u32 = 0;
    var y_fields: u32 = 0;
    var selected_fields: u32 = 0;
    var sites_disabled = false;

    var rows = rowIterator(data);
    while (rows.next()) |line| {
        const pair = parseQuotedPair(line) orelse continue;
        if (std.ascii.eqlIgnoreCase(pair.key, "ZSteps")) {
            info.size_z = parseU16Default(pair.value, 1);
        } else if (std.ascii.eqlIgnoreCase(pair.key, "TimePoints")) {
            info.size_t = parseU16Default(pair.value, 1);
        } else if (std.ascii.eqlIgnoreCase(pair.key, "NWavelengths")) {
            info.size_c = parseU16Default(pair.value, 1);
        } else if (std.ascii.eqlIgnoreCase(pair.key, "XSites")) {
            x_fields = parseU32(pair.value) orelse x_fields;
        } else if (std.ascii.eqlIgnoreCase(pair.key, "YSites")) {
            y_fields = parseU32(pair.value) orelse y_fields;
        } else if (std.ascii.eqlIgnoreCase(pair.key, "Sites")) {
            sites_disabled = std.ascii.eqlIgnoreCase(std.mem.trim(u8, pair.value, " \t\r\n\""), "false");
        } else if (std.mem.startsWith(u8, pair.key, "SiteSelection")) {
            selected_fields += countTrue(pair.value);
        } else if (std.mem.startsWith(u8, pair.key, "WellsSelection")) {
            const row = (parseU32(pair.key["WellsSelection".len..]) orelse 1) -| 1;
            var col: u32 = 0;
            var tokens = std.mem.splitScalar(u8, pair.value, ',');
            while (tokens.next()) |token| : (col += 1) {
                if (parseBool(token)) {
                    if (info.well_count == 0) {
                        info.first_row = row;
                        info.first_col = col;
                    }
                    info.well_count += 1;
                }
            }
        }
    }

    if (info.well_count == 0) return error.InvalidFormat;
    if (sites_disabled) {
        info.field_count = 1;
    } else if (selected_fields > 0) {
        info.field_count = selected_fields;
    } else if (x_fields == 1 and y_fields == 1) {
        info.field_count = 1;
    } else if (x_fields > 0 and y_fields > 0) {
        info.field_count = x_fields * y_fields;
    }
    if (info.size_z == 0) info.size_z = 1;
    if (info.size_c == 0) info.size_c = 1;
    if (info.size_t == 0) info.size_t = 1;
    return info;
}

const Pair = struct {
    key: []const u8,
    value: []const u8,
};

fn parseQuotedPair(line: []const u8) ?Pair {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len < 4 or trimmed[0] != '"') return null;
    const end_key = std.mem.indexOfScalarPos(u8, trimmed, 1, '"') orelse return null;
    var pos = end_key + 1;
    while (pos < trimmed.len and (trimmed[pos] == ' ' or trimmed[pos] == '\t')) : (pos += 1) {}
    if (pos >= trimmed.len or trimmed[pos] != ',') return null;
    return .{
        .key = std.mem.trim(u8, trimmed[1..end_key], " \t\r\n"),
        .value = std.mem.trim(u8, trimmed[pos + 1 ..], " \t\r\n"),
    };
}

fn findHtdPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "htd")) return allocator.dupe(u8, path);
    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    const stem = try fileStem(allocator, path);
    defer allocator.free(stem);

    var base_len = stem.len;
    while (base_len > 0) {
        if (std.mem.lastIndexOfScalar(u8, stem[0..base_len], '_')) |underscore| {
            base_len = underscore;
            const lower_name = try concat(allocator, stem[0..base_len], ".htd");
            defer allocator.free(lower_name);
            const lower = try joinPath(allocator, parent, lower_name);
            defer allocator.free(lower);
            if (existsFile(io, lower)) return allocator.dupe(u8, lower);

            const upper_name = try concat(allocator, stem[0..base_len], ".HTD");
            defer allocator.free(upper_name);
            const upper = try joinPath(allocator, parent, upper_name);
            defer allocator.free(upper);
            if (existsFile(io, upper)) return allocator.dupe(u8, upper);
        } else break;
    }
    return firstSiblingHtd(allocator, io, parent);
}

fn firstSiblingHtd(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and hasExtension(entry.name, "htd")) {
            return joinPath(allocator, dir_path, entry.name);
        }
    }
    return error.FileNotFound;
}

fn cropPlane(allocator: std.mem.Allocator, data: []const u8, metadata: bio.Metadata, region: bio.Region) ![]u8 {
    const bytes_per_pixel = metadata.bytesPerPixel();
    const src_row_bytes = std.math.mul(usize, metadata.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const dst_row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, dst_row_bytes, region.height) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    var row: usize = 0;
    while (row < region.height) : (row += 1) {
        const src_y = @as(usize, region.y) + row;
        const src_x = @as(usize, region.x) * bytes_per_pixel;
        const src_offset = src_y * src_row_bytes + src_x;
        const dst_offset = row * dst_row_bytes;
        @memcpy(out[dst_offset..][0..dst_row_bytes], data[src_offset..][0..dst_row_bytes]);
    }
    return out;
}

fn looksLikeHtd(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "\"XWells\"") != null and
        std.mem.indexOf(u8, data, "\"YWells\"") != null and
        std.mem.indexOf(u8, data, "\"WellsSelection") != null;
}

fn platePrefix(allocator: std.mem.Allocator, htd_path: []const u8) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, htd_path, '.') orelse htd_path.len;
    const out = try allocator.alloc(u8, dot + 1);
    @memcpy(out[0..dot], htd_path[0..dot]);
    out[dot] = '_';
    return out;
}

fn wellName(allocator: std.mem.Allocator, row: u32, col: u32) ![]u8 {
    var letters: [8]u8 = undefined;
    var n = row;
    var len: usize = 0;
    while (true) {
        letters[len] = @as(u8, 'A') + @as(u8, @intCast(n % 26));
        len += 1;
        if (n < 26) break;
        n = n / 26 - 1;
    }
    var i: usize = 0;
    while (i < len / 2) : (i += 1) {
        const tmp = letters[i];
        letters[i] = letters[len - 1 - i];
        letters[len - 1 - i] = tmp;
    }
    return std.fmt.allocPrint(allocator, "{s}{d:0>2}", .{ letters[0..len], col + 1 });
}

fn countTrue(value: []const u8) u32 {
    var count: u32 = 0;
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| {
        if (parseBool(token)) count += 1;
    }
    return count;
}

fn parseBool(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n\""), "true");
}

fn parseU16Default(value: []const u8, default: u16) u16 {
    const parsed = std.fmt.parseUnsigned(u16, std.mem.trim(u8, value, " \t\r\n\""), 10) catch return default;
    return if (parsed == 0) default else parsed;
}

fn parseU32(value: []const u8) ?u32 {
    return std.fmt.parseUnsigned(u32, std.mem.trim(u8, value, " \t\r\n\""), 10) catch null;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn existsFile(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn fileStem(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const sep = if (lastSeparator(path)) |s| s + 1 else 0;
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    return allocator.dupe(u8, path[sep..dot]);
}

fn parentPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const sep = lastSeparator(path) orelse return allocator.dupe(u8, ".");
    if (sep == 0) return allocator.dupe(u8, path[0..1]);
    return allocator.dupe(u8, path[0..sep]);
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    if (hasDirectory(name) or isAbsolutePath(name)) return allocator.dupe(u8, name);
    const sep: u8 = if (std.mem.indexOfScalar(u8, base, '\\') != null) '\\' else '/';
    const needs_sep = base.len != 0 and base[base.len - 1] != '/' and base[base.len - 1] != '\\';
    const extra: usize = if (needs_sep) 1 else 0;
    const out = try allocator.alloc(u8, base.len + extra + name.len);
    @memcpy(out[0..base.len], base);
    if (needs_sep) out[base.len] = sep;
    @memcpy(out[base.len + extra ..], name);
    return out;
}

fn concat(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

fn lastSeparator(path: []const u8) ?usize {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    if (slash == null) return backslash;
    if (backslash == null) return slash;
    return @max(slash.?, backslash.?);
}

fn hasDirectory(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '/') != null or std.mem.indexOfScalar(u8, path, '\\') != null;
}

fn isAbsolutePath(path: []const u8) bool {
    if (path.len >= 1 and (path[0] == '/' or path[0] == '\\')) return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

const RowIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *RowIterator) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '\n' and self.data[self.pos] != '\r') : (self.pos += 1) {}
        const end = self.pos;
        while (self.pos < self.data.len and (self.data[self.pos] == '\n' or self.data[self.pos] == '\r')) : (self.pos += 1) {}
        return self.data[start..end];
    }
};

fn rowIterator(data: []const u8) RowIterator {
    return .{ .data = data };
}

fn setU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn setI16(bytes: []u8, offset: usize, value: i16) void {
    std.mem.writeInt(i16, bytes[offset..][0..2], value, .little);
}

fn setI32(bytes: []u8, offset: usize, value: i32) void {
    std.mem.writeInt(i32, bytes[offset..][0..4], value, .little);
}

fn appendTinyDeltavision(list: *std.ArrayList(u8), pixel: u8) !void {
    try list.appendNTimes(std.testing.allocator, 0, 1024);
    setI32(list.items, 0, 1);
    setI32(list.items, 4, 1);
    setI32(list.items, 8, 1);
    setI32(list.items, 12, 0);
    setI32(list.items, 92, 0);
    setI16(list.items, 96, -16224);
    setU16(list.items, 180, 1);
    setU16(list.items, 182, 0);
    setU16(list.items, 196, 1);
    try list.append(std.testing.allocator, pixel);
}

const htd_fixture =
    "\"XWells\",1\n" ++
    "\"YWells\",1\n" ++
    "\"WellsSelection1\",true\n" ++
    "\"XSites\",1\n" ++
    "\"YSites\",1\n" ++
    "\"SiteSelection1\",true\n" ++
    "\"TimePoints\",1\n" ++
    "\"ZSteps\",1\n" ++
    "\"NWavelengths\",1\n";

test "detects cellworx htd metadata" {
    try std.testing.expect(matches(htd_fixture));
    try std.testing.expect(!matches("\"XWells\",1\n"));
}

test "reads cellworx htd through selected pnl" {
    const root = "cellworx-test";
    const htd_path = "cellworx-test/Plate.HTD";
    const pnl_path = "cellworx-test/Plate_A01.pnl";
    std.Io.Dir.cwd().deleteFile(std.testing.io, pnl_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, htd_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = htd_path, .data = htd_fixture });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, htd_path) catch {};
    var pnl: std.ArrayList(u8) = .empty;
    defer pnl.deinit(std.testing.allocator);
    try appendTinyDeltavision(&pnl, 88);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = pnl_path, .data = pnl.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, pnl_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, htd_path);
    try std.testing.expectEqualStrings("cellworx", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, pnl_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("cellworx", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{88}, plane.data);
}
