const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

const Htd = struct {
    x_wells: u32 = 0,
    y_wells: u32 = 0,
    first_well_row: u32 = 0,
    first_well_col: u32 = 0,
    has_well: bool = false,
    x_sites: u32 = 1,
    y_sites: u32 = 1,
    sites_enabled: bool = true,
    selected_fields: u32 = 0,
    size_c: u16 = 1,
    size_z: u16 = 1,
    size_t: u16 = 1,
    do_channels: bool = false,
};

pub fn matches(data: []const u8) bool {
    _ = data;
    return false;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "htd");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    _ = data;
    return error.InvalidFormat;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.InvalidFormat;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const image_path = try findImagePath(allocator, io, path, 0);
    defer allocator.free(image_path);
    const image = try readFile(allocator, io, image_path);
    defer allocator.free(image);
    var metadata = bio.metamorph.readMetadata(image) catch try bio.tiff.readMetadata(image);
    const htd = try readHtd(allocator, io, path);
    metadata.format = "metaxpress";
    metadata.image_description = null;
    metadata.size_c = htd.size_c;
    metadata.size_z = htd.size_z;
    metadata.size_t = htd.size_t;
    metadata.plane_count = @as(u32, htd.size_c) * @as(u32, htd.size_z) * @as(u32, htd.size_t);
    metadata.samples_per_pixel = 1;
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
    const htd = try readHtd(allocator, io, path);
    const plane_count = @as(u32, htd.size_c) * @as(u32, htd.size_z) * @as(u32, htd.size_t);
    if (plane_index >= plane_count) return error.InvalidPlaneIndex;

    const image_path = try findImagePath(allocator, io, path, plane_index);
    defer allocator.free(image_path);
    const image = try readFile(allocator, io, image_path);
    defer allocator.free(image);

    var plane = bio.metamorph.readRegionIndex(allocator, image, 0, region) catch try bio.tiff.readRegionIndex(allocator, image, 0, region);
    plane.metadata.format = "metaxpress";
    plane.metadata.image_description = null;
    plane.metadata.size_c = htd.size_c;
    plane.metadata.size_z = htd.size_z;
    plane.metadata.size_t = htd.size_t;
    plane.metadata.plane_count = plane_count;
    plane.metadata.samples_per_pixel = 1;
    plane.metadata.dimension_order = "XYCZT";
    return plane;
}

fn findImagePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8, plane_index: u32) ![]u8 {
    if (!isPath(path)) return error.InvalidFormat;
    const htd = try readHtd(allocator, io, path);
    const root = try parentPath(allocator, path);
    defer allocator.free(root);
    const plate = try platePrefix(allocator, path);
    defer allocator.free(plate);
    const well = try wellName(allocator, htd.first_well_row, htd.first_well_col);
    defer allocator.free(well);

    const c = if (htd.size_c == 0) 0 else plane_index % htd.size_c;
    const t = if (htd.size_t == 0) 0 else (plane_index / htd.size_c) % htd.size_t;
    if (try expectedImagePath(allocator, io, plate, well, htd, c, t)) |candidate| return candidate;
    if (try firstRootTiff(allocator, io, root, plate, well)) |candidate| return candidate;
    if (try firstSubdirTiff(allocator, io, root, plate, well, t, 0)) |candidate| return candidate;
    return error.FileNotFound;
}

fn readHtd(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Htd {
    const bytes = try readFile(allocator, io, path);
    defer allocator.free(bytes);
    const htd = try parseHtd(bytes);
    if (!htd.has_well) return error.InvalidFormat;
    return htd;
}

fn parseHtd(data: []const u8) bio.ReaderError!Htd {
    var htd = Htd{};
    var site_map: [256]bool = [_]bool{false} ** 256;
    var saw_site_selection = false;

    var lines = std.mem.splitAny(u8, data, "\r\n");
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t");
        const split = std.mem.indexOf(u8, line, "\",") orelse continue;
        if (line.len == 0 or line[0] != '"') continue;
        const key = std.mem.trim(u8, line[1..split], " \t\"");
        const value = std.mem.trim(u8, line[split + 2 ..], " \t\"");
        if (std.mem.eql(u8, key, "XWells")) {
            htd.x_wells = parseU32(value) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, key, "YWells")) {
            htd.y_wells = parseU32(value) catch return error.InvalidFormat;
        } else if (std.mem.startsWith(u8, key, "WellsSelection")) {
            const row = parseU32(key["WellsSelection".len..]) catch return error.InvalidFormat;
            if (!htd.has_well) {
                var cols = std.mem.splitScalar(u8, value, ',');
                var col: u32 = 0;
                while (cols.next()) |raw_token| : (col += 1) {
                    if (parseBool(std.mem.trim(u8, raw_token, " \t\""))) {
                        htd.first_well_row = row - 1;
                        htd.first_well_col = col;
                        htd.has_well = true;
                        break;
                    }
                }
            }
        } else if (std.mem.eql(u8, key, "XSites")) {
            htd.x_sites = parseU32(value) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, key, "YSites")) {
            htd.y_sites = parseU32(value) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, key, "Sites")) {
            htd.sites_enabled = parseBool(value);
        } else if (std.mem.eql(u8, key, "TimePoints")) {
            htd.size_t = parseU16(value) catch return error.InvalidFormat;
            if (htd.size_t == 0) htd.size_t = 1;
        } else if (std.mem.eql(u8, key, "ZSteps")) {
            htd.size_z = parseU16(value) catch return error.InvalidFormat;
            if (htd.size_z == 0) htd.size_z = 1;
        } else if (std.mem.startsWith(u8, key, "SiteSelection")) {
            const row = parseU32(key["SiteSelection".len..]) catch return error.InvalidFormat;
            var cols = std.mem.splitScalar(u8, value, ',');
            var col: u32 = 0;
            while (cols.next()) |raw_token| : (col += 1) {
                const index = (row - 1) * htd.x_sites + col;
                if (index < site_map.len and parseBool(std.mem.trim(u8, raw_token, " \t\""))) {
                    site_map[@intCast(index)] = true;
                    saw_site_selection = true;
                }
            }
        } else if (std.mem.eql(u8, key, "Waves")) {
            htd.do_channels = parseBool(value);
        } else if (std.mem.eql(u8, key, "NWavelengths")) {
            htd.size_c = parseU16(value) catch return error.InvalidFormat;
            if (htd.size_c == 0) htd.size_c = 1;
        }
    }

    if (!htd.sites_enabled) {
        htd.selected_fields = 1;
    } else if (saw_site_selection) {
        var count: u32 = 0;
        for (site_map) |selected| {
            if (selected) count += 1;
        }
        htd.selected_fields = count;
    } else if (htd.x_sites == 1 and htd.y_sites == 1) {
        htd.selected_fields = 1;
    } else {
        htd.selected_fields = htd.x_sites * htd.y_sites;
    }
    if (htd.selected_fields == 0) htd.selected_fields = 1;
    return htd;
}

fn expectedImagePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    plate: []const u8,
    well: []const u8,
    htd: Htd,
    c: u32,
    t: u32,
) !?[]u8 {
    var name: std.ArrayList(u8) = .empty;
    defer name.deinit(allocator);
    try name.appendSlice(allocator, plate);
    try name.appendSlice(allocator, well);
    if (htd.selected_fields > 1) try appendFmt(&name, allocator, "_s{d}", .{1});
    if (htd.do_channels or htd.size_c > 1) try appendFmt(&name, allocator, "_w{d}", .{c + 1});
    if (htd.size_t > 1) try appendFmt(&name, allocator, "_t{d}", .{t + 1});

    const lower = try std.fmt.allocPrint(allocator, "{s}.tif", .{name.items});
    errdefer allocator.free(lower);
    if (existsFile(io, lower)) return lower;
    allocator.free(lower);

    const upper = try std.fmt.allocPrint(allocator, "{s}.TIF", .{name.items});
    errdefer allocator.free(upper);
    if (existsFile(io, upper)) return upper;
    allocator.free(upper);
    return null;
}

fn appendFmt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try list.appendSlice(allocator, text);
}

fn firstRootTiff(allocator: std.mem.Allocator, io: std.Io, root: []const u8, plate: []const u8, well: []const u8) !?[]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    const base = baseName(plate);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !isTiffName(entry.name)) continue;
        if (std.ascii.indexOfIgnoreCase(entry.name, "_thumb") != null) continue;
        if (!std.mem.startsWith(u8, entry.name, base) or std.mem.indexOf(u8, entry.name, well) == null) continue;
        return try joinPath(allocator, root, entry.name);
    }
    return null;
}

fn firstSubdirTiff(allocator: std.mem.Allocator, io: std.Io, root: []const u8, plate: []const u8, well: []const u8, t: u32, z: u32) !?[]u8 {
    const time_dir_name = try std.fmt.allocPrint(allocator, "TimePoint_{d}", .{t + 1});
    defer allocator.free(time_dir_name);
    const time_dir = try joinPath(allocator, root, time_dir_name);
    defer allocator.free(time_dir);
    const z_dir_name = try std.fmt.allocPrint(allocator, "ZStep_{d}", .{z + 1});
    defer allocator.free(z_dir_name);
    const preferred_dir = try joinPath(allocator, time_dir, z_dir_name);
    defer allocator.free(preferred_dir);
    const search_dir = if (existsDir(io, preferred_dir)) preferred_dir else time_dir;
    if (!existsDir(io, search_dir)) return null;

    var dir = try std.Io.Dir.cwd().openDir(io, search_dir, .{ .iterate = true });
    defer dir.close(io);
    const base = baseName(plate);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !isTiffName(entry.name)) continue;
        if (std.ascii.indexOfIgnoreCase(entry.name, "_thumb") != null) continue;
        if (!std.mem.startsWith(u8, entry.name, base) or std.mem.indexOf(u8, entry.name, well) == null) continue;
        return try joinPath(allocator, search_dir, entry.name);
    }
    return null;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn existsFile(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn existsDir(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn parentPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const sep = lastSeparator(path) orelse return allocator.dupe(u8, ".");
    if (sep == 0) return allocator.dupe(u8, path[0..1]);
    return allocator.dupe(u8, path[0..sep]);
}

fn platePrefix(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    return std.fmt.allocPrint(allocator, "{s}_", .{path[0..dot]});
}

fn wellName(allocator: std.mem.Allocator, row: u32, col: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "{c}{d:0>2}", .{ @as(u8, @intCast('A' + row)), col + 1 });
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

fn baseName(path: []const u8) []const u8 {
    const sep = lastSeparator(path) orelse return path;
    return path[sep + 1 ..];
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

fn isTiffName(path: []const u8) bool {
    return hasExtension(path, "tif") or hasExtension(path, "tiff");
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn parseU32(value: []const u8) !u32 {
    return std.fmt.parseUnsigned(u32, std.mem.trim(u8, value, " \t\""), 10);
}

fn parseU16(value: []const u8) !u16 {
    return std.fmt.parseUnsigned(u16, std.mem.trim(u8, value, " \t\""), 10);
}

fn parseBool(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\""), "true");
}

const tiny_tiff = [_]u8{
    'I', 'I', 42, 0, 8, 0, 0,  0, 9, 0, 0,  1, 4, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 1,  1, 4, 0, 1,  0, 0, 0, 1,   0,
    0,   0,   2,  1, 3, 0, 1,  0, 0, 0, 8,  0, 0, 0, 3,   1,
    3,   0,   1,  0, 0, 0, 1,  0, 0, 0, 6,  1, 3, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 17, 1, 4, 0, 1,  0, 0, 0, 122, 0,
    0,   0,   21, 1, 3, 0, 1,  0, 0, 0, 1,  0, 0, 0, 22,  1,
    4,   0,   1,  0, 0, 0, 1,  0, 0, 0, 23, 1, 4, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 0,  0, 0, 0, 77,
};

test "parses metaxpress htd dimensions" {
    const htd =
        \\"XWells", 2
        \\"YWells", 1
        \\"WellsSelection1", true,false
        \\"XSites", 1
        \\"YSites", 1
        \\"TimePoints", 2
        \\"ZSteps", 1
        \\"NWavelengths", 2
    ;
    const parsed = try parseHtd(htd);
    try std.testing.expect(parsed.has_well);
    try std.testing.expectEqual(@as(u32, 0), parsed.first_well_row);
    try std.testing.expectEqual(@as(u32, 0), parsed.first_well_col);
    try std.testing.expectEqual(@as(u16, 2), parsed.size_c);
    try std.testing.expectEqual(@as(u16, 2), parsed.size_t);
}

test "reads metaxpress htd metadata through expected tiff" {
    const root = "metaxpress-test";
    const htd_path = "metaxpress-test/Plate.htd";
    const image_path = "metaxpress-test/Plate_A01.tif";
    const htd =
        \\"XWells", 1
        \\"YWells", 1
        \\"WellsSelection1", true
        \\"XSites", 1
        \\"YSites", 1
        \\"NWavelengths", 1
    ;
    std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, htd_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = htd_path, .data = htd });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, htd_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, htd_path);
    try std.testing.expectEqualStrings("metaxpress", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
}

test "reads metaxpress htd plane through expected tiff" {
    const root = "metaxpress-plane-test";
    const htd_path = "metaxpress-plane-test/Plate.htd";
    const image_path = "metaxpress-plane-test/Plate_A01.tif";
    const htd =
        \\"XWells", 1
        \\"YWells", 1
        \\"WellsSelection1", true
        \\"XSites", 1
        \\"YSites", 1
        \\"NWavelengths", 1
    ;
    std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, htd_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = htd_path, .data = htd });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, htd_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, htd_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("metaxpress", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}
