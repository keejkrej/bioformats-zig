const std = @import("std");
const bio = @import("../root.zig");
const cfb = @import("cfb.zig");

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

const OibDataset = struct {
    info: []u8,
    oif: []u8,
    planes: std.ArrayList([]u8),
    size_z: u16 = 1,
    size_c: u16 = 1,
    size_t: u16 = 1,

    fn deinit(self: *OibDataset, allocator: std.mem.Allocator) void {
        allocator.free(self.info);
        allocator.free(self.oif);
        for (self.planes.items) |name| allocator.free(name);
        self.planes.deinit(allocator);
    }
};

pub fn matches(data: []const u8) bool {
    if (cfb.matches(data)) return cfb.hasStream(std.heap.page_allocator, data, "OibInfo.txt");
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
    if (cfb.matches(data)) return readOibMetadata(std.heap.page_allocator, data);
    if (!matches(data)) return error.InvalidFormat;
    return error.UnsupportedVariant;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    if (cfb.matches(data)) {
        const metadata = try readOibMetadata(allocator, data);
        return readOibPlaneIndex(allocator, data, plane_index, .{ .x = 0, .y = 0, .width = metadata.width, .height = metadata.height });
    }
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    if (hasExtension(path, "oib")) {
        const data = try readFile(allocator, io, path);
        defer allocator.free(data);
        return readOibMetadata(allocator, data);
    }
    var dataset = try readDataset(allocator, io, path);
    defer dataset.deinit(allocator);
    if (dataset.planes.items.len == 0) return error.UnsupportedVariant;

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
    if (hasExtension(path, "oib")) {
        const data = try readFile(allocator, io, path);
        defer allocator.free(data);
        return readOibPlaneIndex(allocator, data, plane_index, region);
    }
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

fn readOibMetadata(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Metadata {
    var dataset = try readOibDataset(allocator, data);
    defer dataset.deinit(allocator);
    if (dataset.planes.items.len == 0) return error.UnsupportedVariant;

    const first = try cfb.readStream(allocator, data, dataset.planes.items[0]);
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

fn readOibPlaneIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    var dataset = try readOibDataset(allocator, data);
    defer dataset.deinit(allocator);
    if (plane_index >= dataset.planes.items.len) return error.InvalidPlaneIndex;

    const image = try cfb.readStream(allocator, data, dataset.planes.items[plane_index]);
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

fn readOibDataset(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!OibDataset {
    if (!cfb.matches(data)) return error.InvalidFormat;
    const info_raw = try cfb.readStream(allocator, data, "OibInfo.txt");
    defer allocator.free(info_raw);
    var info: ?[]u8 = try decodeTextAlloc(allocator, info_raw);
    errdefer if (info) |bytes| allocator.free(bytes);

    const main_stream = valueForSectionKey(info.?, "OibSaveInfo", "MainFileName") orelse return error.InvalidFormat;
    const oif_raw = try cfb.readStream(allocator, data, sanitizeValue(main_stream));
    defer allocator.free(oif_raw);
    var oif: ?[]u8 = try decodeTextAlloc(allocator, oif_raw);
    errdefer if (oif) |bytes| allocator.free(bytes);
    if (!matches(oif.?)) return error.InvalidFormat;

    var dataset = OibDataset{ .info = info.?, .oif = oif.?, .planes = .empty };
    info = null;
    oif = null;
    errdefer dataset.deinit(allocator);

    var pty_names: std.ArrayList(IndexedName) = .empty;
    defer freeIndexedNames(allocator, &pty_names);
    try collectPtyNames(allocator, dataset.oif, &pty_names);
    if (pty_names.items.len == 0) try collectOibPtyNames(allocator, dataset.info, &pty_names);
    std.mem.sort(IndexedName, pty_names.items, {}, lessIndexedName);
    if (pty_names.items.len == 0) return error.UnsupportedVariant;

    for (pty_names.items) |entry| {
        const pty_stream = streamForVirtualPath(dataset.info, entry.name) orelse continue;
        const pty_raw = cfb.readStream(allocator, data, pty_stream) catch continue;
        defer allocator.free(pty_raw);
        const pty = decodeTextAlloc(allocator, pty_raw) catch continue;
        defer allocator.free(pty);

        const image_virtual = try oibImageVirtualPath(allocator, entry.name, pty);
        defer allocator.free(image_virtual);
        const image_stream = streamForVirtualPath(dataset.info, image_virtual) orelse continue;
        const image_name = try allocator.dupe(u8, image_stream);
        errdefer allocator.free(image_name);
        try dataset.planes.append(allocator, image_name);
        updateDimensionsFromPtyText(pty, &dataset);
    }

    if (dataset.planes.items.len == 0) return error.UnsupportedVariant;
    if (dataset.size_z == 1 and dataset.size_c == 1 and dataset.size_t == 1 and dataset.planes.items.len > 1) {
        dataset.size_t = @intCast(@min(dataset.planes.items.len, std.math.maxInt(u16)));
    }
    return dataset;
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

fn updateDimensionsFromPtyText(pty: []const u8, dataset: *OibDataset) void {
    if (axisNumber(pty, 2)) |count| dataset.size_c = @max(dataset.size_c, count);
    if (axisNumber(pty, 3)) |count| dataset.size_z = @max(dataset.size_z, count);
    if (axisNumber(pty, 4)) |count| dataset.size_t = @max(dataset.size_t, count);
}

fn oibImageVirtualPath(allocator: std.mem.Allocator, pty_virtual_path: []const u8, pty: []const u8) ![]u8 {
    if (valueForSectionKey(pty, "File Info", "DataName")) |data_name| {
        const clean = sanitizeValue(data_name);
        const image_name = try replaceExtension(allocator, clean, "tif");
        defer allocator.free(image_name);
        if (parentVirtualPath(pty_virtual_path)) |parent| {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, image_name });
        }
        return allocator.dupe(u8, image_name);
    }
    return replaceExtension(allocator, pty_virtual_path, "tif");
}

fn parentVirtualPath(path: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    const sep = if (slash == null) backslash else if (backslash == null) slash else @max(slash.?, backslash.?);
    return if (sep) |index| path[0..index] else null;
}

fn streamForVirtualPath(info: []const u8, virtual_path: []const u8) ?[]const u8 {
    var section: []const u8 = "";
    var lines = std.mem.splitAny(u8, info, "\r\n");
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            continue;
        }
        if (!std.ascii.eqlIgnoreCase(section, "OibSaveInfo")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.startsWith(u8, key, "Stream")) continue;
        const value = sanitizeValue(line[eq + 1 ..]);
        if (sameVirtualPath(value, virtual_path)) return key;
    }
    return null;
}

fn collectOibPtyNames(allocator: std.mem.Allocator, info: []const u8, out: *std.ArrayList(IndexedName)) !void {
    var section: []const u8 = "";
    var lines = std.mem.splitAny(u8, info, "\r\n");
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            continue;
        }
        if (!std.ascii.eqlIgnoreCase(section, "OibSaveInfo")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.startsWith(u8, key, "Stream")) continue;
        const value = sanitizeValue(line[eq + 1 ..]);
        if (!hasExtension(value, "pty") or isPreviewName(value)) continue;
        const index = std.fmt.parseUnsigned(u32, key["Stream".len..], 10) catch @as(u32, @intCast(out.items.len));
        try out.append(allocator, .{ .index = index, .name = try allocator.dupe(u8, value) });
    }
}

fn sameVirtualPath(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (ai < a.len and bi < b.len) : ({
        ai += 1;
        bi += 1;
    }) {
        const ac = if (a[ai] == '\\') '/' else a[ai];
        const bc = if (b[bi] == '\\') '/' else b[bi];
        if (ac != bc) return false;
    }
    return ai == a.len and bi == b.len;
}

fn decodeTextAlloc(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len >= 2 and (data[0] == 0xff and data[1] == 0xfe or data[1] == 0)) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i + 1 < data.len) : (i += 2) {
            const code = std.mem.readInt(u16, data[i..][0..2], .little);
            if (code == 0xfeff or code == 0) continue;
            try out.append(allocator, if (code <= 0x7f) @intCast(code) else '?');
        }
        return out.toOwnedSlice(allocator);
    }
    return allocator.dupe(u8, data);
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

test "matches Bio-Formats core metadata for cached FV1000 OIB fixture" {
    const file_path = "fixtures/cache/fv1000/20220824_4492_cord_dapi__iba568_60x.oib";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    try std.testing.expectEqualStrings("fv1000", metadata.format);
    try std.testing.expectEqual(@as(u32, 1024), metadata.width);
    try std.testing.expectEqual(@as(u32, 1024), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 6), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 12), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 1), metadata.series_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
}

test "matches Bio-Formats plane hashes for cached FV1000 OIB fixture" {
    const file_path = "fixtures/cache/fv1000/20220824_4492_cord_dapi__iba568_60x.oib";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const expected = [_]struct { plane: u32, sha256: [32]u8 }{
        .{ .plane = 0, .sha256 = .{ 0xda, 0x89, 0x6c, 0x9c, 0xac, 0xa6, 0x6d, 0xe0, 0x35, 0xef, 0x6e, 0x1a, 0xf0, 0xeb, 0x1a, 0x9f, 0x95, 0xa6, 0xa0, 0x7d, 0x3a, 0x27, 0x3f, 0xeb, 0x3e, 0x7d, 0x5b, 0x9e, 0x05, 0x7d, 0xfa, 0x00 } },
        .{ .plane = 6, .sha256 = .{ 0xba, 0xd9, 0x57, 0x6e, 0xe5, 0x0f, 0x0c, 0xa6, 0xb9, 0x7a, 0xac, 0x84, 0x6e, 0x5e, 0xc9, 0x39, 0xbd, 0xbd, 0x65, 0xf8, 0xb2, 0x10, 0x0e, 0x72, 0x05, 0x46, 0x9d, 0xb8, 0x65, 0x36, 0x5d, 0x6d } },
        .{ .plane = 11, .sha256 = .{ 0x61, 0x71, 0xde, 0x0b, 0x37, 0x3b, 0xbc, 0x87, 0x93, 0x7f, 0x97, 0xdd, 0x46, 0x19, 0xf1, 0xcc, 0xe4, 0x36, 0x32, 0x5e, 0xaf, 0x5c, 0x9a, 0xe0, 0x20, 0x35, 0x7f, 0x1e, 0x0d, 0x0c, 0xf8, 0xa9 } },
    };
    for (expected) |sample| {
        const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, sample.plane, .{
            .x = 0,
            .y = 0,
            .width = 1024,
            .height = 1024,
        });
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqual(@as(usize, 2097152), plane.data.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
        try std.testing.expectEqualSlices(u8, &sample.sha256, &digest);
    }

    const region = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 6, .{
        .x = 17,
        .y = 19,
        .width = 16,
        .height = 12,
    });
    defer std.testing.allocator.free(region.data);
    try std.testing.expectEqual(@as(usize, 384), region.data.len);
    const expected_region: [32]u8 = .{ 0x4d, 0x12, 0xe3, 0xbd, 0xf1, 0xa5, 0x94, 0xce, 0xb1, 0xe0, 0x21, 0x24, 0x7e, 0x00, 0xe9, 0x62, 0x7a, 0x64, 0x7f, 0xbc, 0xb3, 0x35, 0x42, 0xf8, 0x7b, 0x66, 0x3b, 0x8c, 0x8f, 0x80, 0x5b, 0x31 };
    var region_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(region.data, &region_digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_region, &region_digest);
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
