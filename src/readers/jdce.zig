const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

const JdceInfo = struct {
    csv_path: []u8,
    size_z: u16 = 1,
    size_c: u16 = 1,
    size_t: u16 = 1,

    fn deinit(self: JdceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.csv_path);
    }
};

const PlaneRef = struct {
    field: u32,
    z: u32,
    c: u32,
    t: u32,
    path: []u8,
};

pub fn matches(data: []const u8) bool {
    return looksLikeJdce(data);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "jdce") or hasExtension(path, "csv") or hasExtension(path, "tif") or hasExtension(path, "tiff");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!looksLikeJdce(data)) return error.InvalidFormat;
    return error.UnsupportedVariant;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const jdce_path = try findJdcePath(allocator, io, path);
    defer allocator.free(jdce_path);
    const jdce = try readFile(allocator, io, jdce_path);
    defer allocator.free(jdce);
    const parent = try parentPath(allocator, jdce_path);
    defer allocator.free(parent);
    const info = try parseJdce(allocator, parent, jdce);
    defer info.deinit(allocator);

    var planes: std.ArrayList(PlaneRef) = .empty;
    defer freePlanes(allocator, &planes);
    try readCsvPlanes(allocator, io, info.csv_path, &planes);
    if (planes.items.len == 0) return error.FileNotFound;

    sortPlanes(planes.items);
    const first = try readFile(allocator, io, planes.items[0].path);
    defer allocator.free(first);
    var metadata = try bio.tiff.readMetadata(first);
    metadata.format = "jdce";
    metadata.image_description = null;
    metadata.size_z = info.size_z;
    metadata.size_c = info.size_c;
    metadata.size_t = info.size_t;
    metadata.plane_count = @max(@as(u32, 1), @as(u32, info.size_z) * @as(u32, info.size_c) * @as(u32, info.size_t));
    if (metadata.plane_count < planes.items.len) metadata.plane_count = @intCast(planes.items.len);
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
    const jdce_path = try findJdcePath(allocator, io, path);
    defer allocator.free(jdce_path);
    const jdce = try readFile(allocator, io, jdce_path);
    defer allocator.free(jdce);
    const parent = try parentPath(allocator, jdce_path);
    defer allocator.free(parent);
    const info = try parseJdce(allocator, parent, jdce);
    defer info.deinit(allocator);

    var planes: std.ArrayList(PlaneRef) = .empty;
    defer freePlanes(allocator, &planes);
    try readCsvPlanes(allocator, io, info.csv_path, &planes);
    sortPlanes(planes.items);
    if (plane_index >= planes.items.len) return error.InvalidPlaneIndex;

    var plane = try readDelegatedPlane(allocator, io, planes.items[plane_index].path, region);
    plane.metadata.format = "jdce";
    plane.metadata.image_description = null;
    plane.metadata.size_z = info.size_z;
    plane.metadata.size_c = info.size_c;
    plane.metadata.size_t = info.size_t;
    plane.metadata.plane_count = @max(@as(u32, 1), @as(u32, info.size_z) * @as(u32, info.size_c) * @as(u32, info.size_t));
    if (plane.metadata.plane_count < planes.items.len) plane.metadata.plane_count = @intCast(planes.items.len);
    plane.metadata.dimension_order = "XYCZT";
    return plane;
}

fn readDelegatedPlane(allocator: std.mem.Allocator, io: std.Io, path: []const u8, region: bio.Region) !bio.Plane {
    const bytes = try readFile(allocator, io, path);
    defer allocator.free(bytes);
    return bio.tiff.readRegionIndex(allocator, bytes, 0, region);
}

fn findJdcePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "jdce")) return allocator.dupe(u8, path);
    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    if (try firstSiblingJdce(allocator, io, parent)) |candidate| return candidate;
    const grandparent = try parentPath(allocator, parent);
    defer allocator.free(grandparent);
    if (!std.mem.eql(u8, parent, grandparent)) {
        if (try firstSiblingJdce(allocator, io, grandparent)) |candidate| return candidate;
    }
    return error.FileNotFound;
}

fn firstSiblingJdce(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and hasExtension(entry.name, "jdce")) {
            return try joinPath(allocator, dir_path, entry.name);
        }
    }
    return null;
}

fn parseJdce(allocator: std.mem.Allocator, parent: []const u8, bytes: []const u8) !JdceInfo {
    const start = std.mem.indexOfScalar(u8, bytes, '{') orelse return error.InvalidFormat;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes[start..], .{}) catch return error.InvalidFormat;
    defer parsed.deinit();

    const root = if (parsed.value == .object) parsed.value.object.get("ImageStack") orelse return error.InvalidFormat else return error.InvalidFormat;
    if (root != .object) return error.InvalidFormat;
    const image_format = jsonString(root.object.get("ImageFormat")) orelse return error.InvalidFormat;
    if (!std.ascii.eqlIgnoreCase(image_format, "TIFF")) return error.UnsupportedVariant;

    const csv_name = blk: {
        const files = root.object.get("ImageMetadataFiles") orelse return error.InvalidFormat;
        if (files != .array or files.array.items.len == 0) return error.InvalidFormat;
        break :blk jsonString(files.array.items[0]) orelse return error.InvalidFormat;
    };
    var info = JdceInfo{ .csv_path = try joinPath(allocator, parent, csv_name) };
    errdefer info.deinit(allocator);

    if (root.object.get("AutoLeadAcquisitionProtocol")) |acq| {
        if (acq == .object) {
            if (acq.object.get("Wavelengths")) |wavelengths| {
                if (wavelengths == .array and wavelengths.array.items.len > 0) info.size_c = @intCast(@min(wavelengths.array.items.len, std.math.maxInt(u16)));
            }
            if (acq.object.get("PlateMap")) |plate_map| {
                if (plate_map == .object) {
                    if (plate_map.object.get("TimeSchedule")) |time_schedule| {
                        if (time_schedule == .object) {
                            if (time_schedule.object.get("Times")) |times| {
                                if (times == .array and times.array.items.len > 0) info.size_t = @intCast(@min(times.array.items.len, std.math.maxInt(u16)));
                            } else if (jsonU16(time_schedule.object.get("NumberOfTimepoints"))) |count| {
                                info.size_t = @max(@as(u16, 1), count);
                            }
                        }
                    }
                    if (plate_map.object.get("ZDimensionParameters")) |z| {
                        if (z == .object) {
                            info.size_z = jsonU16(z.object.get("NumberOfSlices")) orelse info.size_z;
                            if (info.size_z == 0) info.size_z = 1;
                        }
                    }
                }
            }
        }
    }
    return info;
}

fn readCsvPlanes(allocator: std.mem.Allocator, io: std.Io, csv_path: []const u8, planes: *std.ArrayList(PlaneRef)) !void {
    const bytes = try readFile(allocator, io, csv_path);
    defer allocator.free(bytes);
    const parent = try parentPath(allocator, csv_path);
    defer allocator.free(parent);

    var rows = rowIterator(bytes);
    const header = rows.next() orelse return error.InvalidFormat;
    const columns = try splitCsvRow(allocator, header);
    defer freeCells(allocator, columns);
    const indexes = CsvIndexes{
        .field = findColumn(columns, "Field") orelse return error.InvalidFormat,
        .z = findColumn(columns, "ZIndex") orelse return error.InvalidFormat,
        .c = findColumn(columns, "Wavelength") orelse return error.InvalidFormat,
        .t = findColumn(columns, "Timepoint") orelse return error.InvalidFormat,
        .folder = findColumn(columns, "ImageSubFolderPath") orelse return error.InvalidFormat,
        .file = findColumn(columns, "ImageFileName") orelse return error.InvalidFormat,
    };

    while (rows.next()) |row| {
        if (std.mem.trim(u8, row, " \t\r\n").len == 0) continue;
        const cells = try splitCsvRow(allocator, row);
        defer freeCells(allocator, cells);
        const max_index = @max(@max(@max(indexes.field, indexes.z), @max(indexes.c, indexes.t)), @max(indexes.folder, indexes.file));
        if (cells.len <= max_index) continue;

        const folder = cells[indexes.folder];
        const filename = cells[indexes.file];
        const folder_path = try joinPath(allocator, parent, folder);
        defer allocator.free(folder_path);
        const image_path = try joinPath(allocator, folder_path, filename);
        errdefer allocator.free(image_path);
        if (!existsFile(io, image_path)) {
            allocator.free(image_path);
            continue;
        }
        try planes.append(allocator, .{
            .field = parseU32(cells[indexes.field]) orelse 0,
            .z = parseU32(cells[indexes.z]) orelse 0,
            .c = parseU32(cells[indexes.c]) orelse 0,
            .t = parseU32(cells[indexes.t]) orelse 0,
            .path = image_path,
        });
    }
}

const CsvIndexes = struct {
    field: usize,
    z: usize,
    c: usize,
    t: usize,
    folder: usize,
    file: usize,
};

fn splitCsvRow(allocator: std.mem.Allocator, row: []const u8) ![][]u8 {
    var cells: std.ArrayList([]u8) = .empty;
    errdefer {
        for (cells.items) |cell| allocator.free(cell);
        cells.deinit(allocator);
    }
    var start: usize = 0;
    var i: usize = 0;
    while (i <= row.len) : (i += 1) {
        if (i == row.len or row[i] == ',') {
            const cell = trimCsvCell(row[start..i]);
            try cells.append(allocator, try allocator.dupe(u8, cell));
            start = i + 1;
        }
    }
    return try cells.toOwnedSlice(allocator);
}

fn trimCsvCell(cell: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, cell, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') return trimmed[1 .. trimmed.len - 1];
    return trimmed;
}

fn findColumn(cells: []const []u8, name: []const u8) ?usize {
    for (cells, 0..) |cell, i| {
        if (std.ascii.eqlIgnoreCase(cell, name)) return i;
    }
    return null;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

fn jsonU16(value: ?std.json.Value) ?u16 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u16)) @intCast(i) else null,
        .float => |f| if (f >= 0 and f <= std.math.maxInt(u16)) @intFromFloat(f) else null,
        .string => |s| std.fmt.parseUnsigned(u16, s, 10) catch null,
        else => null,
    };
}

fn parseU32(value: []const u8) ?u32 {
    return std.fmt.parseUnsigned(u32, std.mem.trim(u8, value, " \t\r\n"), 10) catch null;
}

fn looksLikeJdce(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "\"ImageStack\"") != null and
        std.mem.indexOf(u8, data, "\"ImageMetadataFiles\"") != null and
        std.ascii.indexOfIgnoreCase(data, "TIFF") != null;
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
    if (name.len == 0) return allocator.dupe(u8, base);
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

fn sortPlanes(planes: []PlaneRef) void {
    var i: usize = 1;
    while (i < planes.len) : (i += 1) {
        var j = i;
        while (j > 0 and lessPlane(planes[j], planes[j - 1])) : (j -= 1) {
            const tmp = planes[j - 1];
            planes[j - 1] = planes[j];
            planes[j] = tmp;
        }
    }
}

fn lessPlane(a: PlaneRef, b: PlaneRef) bool {
    if (a.field != b.field) return a.field < b.field;
    if (a.t != b.t) return a.t < b.t;
    if (a.c != b.c) return a.c < b.c;
    return a.z < b.z;
}

fn freeCells(allocator: std.mem.Allocator, cells: []const []u8) void {
    for (cells) |cell| allocator.free(cell);
    allocator.free(cells);
}

fn freePlanes(allocator: std.mem.Allocator, planes: *std.ArrayList(PlaneRef)) void {
    for (planes.items) |plane| allocator.free(plane.path);
    planes.deinit(allocator);
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

const jdce_fixture =
    "{\n" ++
    "\"ImageStack\": {\n" ++
    "\"ImageFormat\": \"TIFF\",\n" ++
    "\"ImageMetadataFiles\": [\"images.csv\"],\n" ++
    "\"AutoLeadAcquisitionProtocol\": {\n" ++
    "\"PlateMap\": {\"TimeSchedule\": {\"Times\": [0]}, \"ZDimensionParameters\": {\"NumberOfSlices\": 1}},\n" ++
    "\"Wavelengths\": [{\"Index\": 0}]\n" ++
    "}\n" ++
    "}\n" ++
    "}\n";

const csv_fixture =
    "Row,Column,Field,Wavelength,Timepoint,ZIndex,ImageSubFolderPath,ImageFileName,ImageSizeXPx,ImageSizeYPx\n" ++
    "1,1,0,0,0,0,Images,img.tif,1,1\n";

test "detects jdce metadata" {
    try std.testing.expect(matches(jdce_fixture));
    try std.testing.expect(!matches("{}"));
}

test "reads jdce metadata through csv tiff list" {
    const root = "jdce-test";
    const images = "jdce-test/Images";
    const jdce_path = "jdce-test/plate.jdce";
    const csv_path = "jdce-test/images.csv";
    const tiff_path = "jdce-test/Images/img.tif";
    cleanupFixture(root, images, jdce_path, csv_path, tiff_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, images, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, images) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = jdce_path, .data = jdce_fixture });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, jdce_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = csv_path, .data = csv_fixture });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, csv_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tiff_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, jdce_path);
    try std.testing.expectEqualStrings("jdce", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
}

test "reads jdce delegated pixels from selected tiff" {
    const root = "jdce-plane-test";
    const images = "jdce-plane-test/Images";
    const jdce_path = "jdce-plane-test/plate.jdce";
    const csv_path = "jdce-plane-test/images.csv";
    const tiff_path = "jdce-plane-test/Images/img.tif";
    cleanupFixture(root, images, jdce_path, csv_path, tiff_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, images, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, images) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = jdce_path, .data = jdce_fixture });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, jdce_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = csv_path, .data = csv_fixture });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, csv_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tiff_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, tiff_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("jdce", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}

fn cleanupFixture(root: []const u8, images: []const u8, jdce_path: []const u8, csv_path: []const u8, tiff_path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, csv_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, jdce_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, images) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
}
