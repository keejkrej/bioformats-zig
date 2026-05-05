const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

const IndexedName = struct {
    index: u32,
    name: []u8,
};

const Dataset = struct {
    oif_path: []u8,
    planes: std.ArrayList([]u8),
    size_z: u16 = 1,
    size_c: u16 = 1,
    size_t: u16 = 1,

    fn deinit(self: *Dataset, allocator: std.mem.Allocator) void {
        allocator.free(self.oif_path);
        for (self.planes.items) |path| allocator.free(path);
        self.planes.deinit(allocator);
    }
};

pub fn matches(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "FileInformation") != null or
        std.mem.indexOf(u8, data, "Acquisition Parameters") != null or
        (std.mem.indexOf(u8, data, "[ProfileSaveInfo]") != null and std.mem.indexOf(u8, data, "IniFileName") != null);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "oif") or
        hasExtension(path, "oib") or
        hasExtension(path, "pty") or
        hasExtension(path, "lut") or
        hasExtension(path, "tif") or
        hasExtension(path, "tiff");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!matches(data)) return error.InvalidFormat;
    return error.UnsupportedVariant;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    var dataset = try readDataset(allocator, io, path);
    defer dataset.deinit(allocator);
    if (dataset.planes.items.len == 0) return error.FileNotFound;

    const first = try readFile(allocator, io, dataset.planes.items[0]);
    defer allocator.free(first);
    var metadata = try bio.tiff.readMetadata(first);
    metadata.format = "fv1000";
    metadata.image_description = null;
    metadata.size_z = dataset.size_z;
    metadata.size_c = dataset.size_c;
    metadata.size_t = dataset.size_t;
    metadata.plane_count = @intCast(dataset.planes.items.len);
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
    var dataset = try readDataset(allocator, io, path);
    defer dataset.deinit(allocator);
    if (plane_index >= dataset.planes.items.len) return error.InvalidPlaneIndex;

    const image = try readFile(allocator, io, dataset.planes.items[plane_index]);
    defer allocator.free(image);
    var plane = try bio.tiff.readRegionIndex(allocator, image, 0, region);
    plane.metadata.format = "fv1000";
    plane.metadata.image_description = null;
    plane.metadata.size_z = dataset.size_z;
    plane.metadata.size_c = dataset.size_c;
    plane.metadata.size_t = dataset.size_t;
    plane.metadata.plane_count = @intCast(dataset.planes.items.len);
    plane.metadata.dimension_order = "XYCZT";
    return plane;
}

fn readDataset(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Dataset {
    const oif_path = try findOifPath(allocator, io, path);
    errdefer allocator.free(oif_path);
    const oif = try readFile(allocator, io, oif_path);
    defer allocator.free(oif);
    if (!matches(oif)) return error.InvalidFormat;

    var dataset = Dataset{ .oif_path = oif_path, .planes = .empty };
    errdefer dataset.deinit(allocator);

    const parent = try parentPath(allocator, oif_path);
    defer allocator.free(parent);

    var pty_names: std.ArrayList(IndexedName) = .empty;
    defer freeIndexedNames(allocator, &pty_names);
    try collectPtyNames(allocator, oif, &pty_names);
    std.mem.sort(IndexedName, pty_names.items, {}, lessIndexedName);
    if (pty_names.items.len == 0) return error.UnsupportedVariant;

    for (pty_names.items) |entry| {
        const pty_path = try joinPath(allocator, parent, entry.name);
        defer allocator.free(pty_path);
        const image_path = try imagePathForPty(allocator, io, pty_path);
        errdefer allocator.free(image_path);
        if (!isTiffPath(image_path) or !existsFile(io, image_path)) {
            allocator.free(image_path);
            continue;
        }
        try dataset.planes.append(allocator, image_path);
        try updateDimensionsFromPty(allocator, io, pty_path, &dataset);
    }

    if (dataset.planes.items.len == 0) return error.FileNotFound;
    if (dataset.size_z == 1 and dataset.size_c == 1 and dataset.size_t == 1 and dataset.planes.items.len > 1) {
        dataset.size_t = @intCast(@min(dataset.planes.items.len, std.math.maxInt(u16)));
    }
    return dataset;
}

fn findOifPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "oib")) return error.UnsupportedVariant;
    if (hasExtension(path, "oif")) return allocator.dupe(u8, path);

    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    if (try firstSiblingOif(allocator, io, parent)) |candidate| return candidate;

    const grandparent = try parentPath(allocator, parent);
    defer allocator.free(grandparent);
    if (!std.mem.eql(u8, parent, grandparent)) {
        if (try firstSiblingOif(allocator, io, grandparent)) |candidate| return candidate;
    }
    return error.FileNotFound;
}

fn firstSiblingOif(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !hasExtension(entry.name, "oif")) continue;
        const candidate = try joinPath(allocator, dir_path, entry.name);
        errdefer allocator.free(candidate);
        const bytes = readFile(allocator, io, candidate) catch {
            allocator.free(candidate);
            continue;
        };
        defer allocator.free(bytes);
        if (matches(bytes)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn collectPtyNames(allocator: std.mem.Allocator, data: []const u8, out: *std.ArrayList(IndexedName)) !void {
    var section: []const u8 = "";
    var lines = std.mem.splitAny(u8, data, "\r\n");
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            continue;
        }
        if (!std.ascii.eqlIgnoreCase(section, "ProfileSaveInfo")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.startsWith(u8, key, "IniFileName") or std.mem.indexOf(u8, key, "Thumb") != null) continue;
        const value = sanitizeValue(line[eq + 1 ..]);
        if (isPreviewName(value)) continue;
        const index_text = key["IniFileName".len..];
        const index = std.fmt.parseUnsigned(u32, index_text, 10) catch @as(u32, @intCast(out.items.len));
        try out.append(allocator, .{ .index = index, .name = try allocator.dupe(u8, value) });
    }
}

fn imagePathForPty(allocator: std.mem.Allocator, io: std.Io, pty_path: []const u8) ![]u8 {
    if (isTiffPath(pty_path)) return allocator.dupe(u8, pty_path);
    const pty_parent = try parentPath(allocator, pty_path);
    defer allocator.free(pty_parent);

    if (readFile(allocator, io, pty_path)) |pty| {
        defer allocator.free(pty);
        if (valueForSectionKey(pty, "File Info", "DataName")) |data_name| {
            const clean = sanitizeValue(data_name);
            const image_name = try replaceExtension(allocator, clean, "tif");
            defer allocator.free(image_name);
            return try joinPath(allocator, pty_parent, image_name);
        }
    } else |_| {}

    return replaceExtension(allocator, pty_path, "tif");
}

fn updateDimensionsFromPty(allocator: std.mem.Allocator, io: std.Io, pty_path: []const u8, dataset: *Dataset) !void {
    const pty = readFile(allocator, io, pty_path) catch return;
    defer allocator.free(pty);
    if (axisNumber(pty, 2)) |count| dataset.size_c = @max(dataset.size_c, count);
    if (axisNumber(pty, 3)) |count| dataset.size_z = @max(dataset.size_z, count);
    if (axisNumber(pty, 4)) |count| dataset.size_t = @max(dataset.size_t, count);
}

fn axisNumber(data: []const u8, axis: u8) ?u16 {
    var section_buf: [32]u8 = undefined;
    const section = std.fmt.bufPrint(&section_buf, "Axis {d} Parameters", .{axis}) catch return null;
    const value = valueForSectionKey(data, section, "Number") orelse return null;
    const parsed = std.fmt.parseUnsigned(u16, sanitizeValue(value), 10) catch return null;
    return if (parsed == 0) null else parsed;
}

fn valueForSectionKey(data: []const u8, wanted_section: []const u8, wanted_key: []const u8) ?[]const u8 {
    var section: []const u8 = "";
    var lines = std.mem.splitAny(u8, data, "\r\n");
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            continue;
        }
        if (!std.ascii.eqlIgnoreCase(section, wanted_section)) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (std.ascii.eqlIgnoreCase(key, wanted_key)) return line[eq + 1 ..];
    }
    return null;
}

fn sanitizeValue(value: []const u8) []const u8 {
    var out = std.mem.trim(u8, value, " \t\r\n");
    if (out.len >= 2 and ((out[0] == '"' and out[out.len - 1] == '"') or (out[0] == '\'' and out[out.len - 1] == '\''))) {
        out = out[1 .. out.len - 1];
    }
    return std.mem.trim(u8, out, " \t\r\n");
}

fn isPreviewName(value: []const u8) bool {
    return std.mem.indexOf(u8, value, "Thumb") != null or
        hasExtension(value, "bmp") or
        hasExtension(value, "lut") or
        hasExtension(value, "roi");
}

fn lessIndexedName(_: void, a: IndexedName, b: IndexedName) bool {
    return a.index < b.index;
}

fn freeIndexedNames(allocator: std.mem.Allocator, names: *std.ArrayList(IndexedName)) void {
    for (names.items) |entry| allocator.free(entry.name);
    names.deinit(allocator);
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn existsFile(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn parentPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const sep = lastSeparator(path) orelse return allocator.dupe(u8, ".");
    if (sep == 0) return allocator.dupe(u8, path[0..1]);
    return allocator.dupe(u8, path[0..sep]);
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    if (isAbsolutePath(name)) return allocator.dupe(u8, name);
    const sep: u8 = if (std.mem.indexOfScalar(u8, base, '\\') != null) '\\' else '/';
    const needs_sep = base.len != 0 and base[base.len - 1] != '/' and base[base.len - 1] != '\\';
    const extra: usize = if (needs_sep) 1 else 0;
    const out = try allocator.alloc(u8, base.len + extra + name.len);
    @memcpy(out[0..base.len], base);
    if (needs_sep) out[base.len] = sep;
    @memcpy(out[base.len + extra ..], name);
    return out;
}

fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ path[0..dot], extension });
}

fn isTiffPath(path: []const u8) bool {
    return hasExtension(path, "tif") or hasExtension(path, "tiff");
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn isAbsolutePath(path: []const u8) bool {
    if (path.len >= 1 and (path[0] == '/' or path[0] == '\\')) return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
}

fn lastSeparator(path: []const u8) ?usize {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    if (slash == null) return backslash;
    if (backslash == null) return slash;
    return @max(slash.?, backslash.?);
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

fn appendEntry(list: *std.ArrayList(u8), tag: u16, field_type: u16, count: u32, value: u32) !void {
    try appendU16Le(list, tag);
    try appendU16Le(list, field_type);
    try appendU32Le(list, count);
    try appendU32Le(list, value);
}

fn tinyTiff(value: u8) ![]u8 {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 9;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;

    try appendU16Le(&data, entry_count);
    try appendEntry(&data, 256, 4, 1, 1);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 1, 8);
    try appendEntry(&data, 259, 3, 1, 1);
    try appendEntry(&data, 262, 3, 1, 1);
    try appendEntry(&data, 273, 4, 1, ifd_end);
    try appendEntry(&data, 277, 3, 1, 1);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 1, 1);
    try appendU32Le(&data, 0);
    try data.append(std.testing.allocator, value);
    return data.toOwnedSlice(std.testing.allocator);
}

test "reads fv1000 oif metadata and delegated tiff planes" {
    const root = "fv1000-test";
    cleanupFixture();
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer cleanupFixture();
    try std.Io.Dir.cwd().createDir(std.testing.io, root ++ "/sample.files", .default_dir);

    const first_tiff = try tinyTiff(5);
    defer std.testing.allocator.free(first_tiff);
    const second_tiff = try tinyTiff(9);
    defer std.testing.allocator.free(second_tiff);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/sample.files/s_C001T001.tif", .data = first_tiff });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/sample.files/s_C001T002.tif", .data = second_tiff });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root ++ "/sample.files/s_C001T001.pty",
        .data =
        \\[File Info]
        \\DataName=s_C001T001.tif
        \\[Axis 4 Parameters]
        \\Number=2
        \\
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root ++ "/sample.files/s_C001T002.pty",
        .data =
        \\[File Info]
        \\DataName=s_C001T002.tif
        \\[Axis 4 Parameters]
        \\Number=2
        \\
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root ++ "/sample.oif",
        .data =
        \\[FileInformation]
        \\Version=FV1000
        \\[ProfileSaveInfo]
        \\IniFileName0=sample.files/s_C001T001.pty
        \\IniFileName1=sample.files/s_C001T002.pty
        \\
        ,
    });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, root ++ "/sample.oif");
    try std.testing.expectEqualStrings("fv1000", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const region = bio.Region{ .x = 0, .y = 0, .width = 1, .height = 1 };
    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, root ++ "/sample.oif", 1, region);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("fv1000", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{9}, plane.data);
}

fn cleanupFixture() void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, "fv1000-test/sample.files/s_C001T001.tif") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, "fv1000-test/sample.files/s_C001T002.tif") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, "fv1000-test/sample.files/s_C001T001.pty") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, "fv1000-test/sample.files/s_C001T002.pty") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, "fv1000-test/sample.oif") catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, "fv1000-test/sample.files") catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, "fv1000-test") catch {};
}
