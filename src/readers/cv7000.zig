const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

const measurement_file = "MeasurementData.mlf";

const PlaneRef = struct {
    row: u32,
    col: u32,
    field: u32,
    z: u32,
    c: u32,
    t: u32,
    path: []u8,
};

const DatasetInfo = struct {
    root: []u8,
    planes: std.ArrayList(PlaneRef),
    size_z: u16 = 1,
    size_c: u16 = 1,
    size_t: u16 = 1,

    fn deinit(self: *DatasetInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        for (self.planes.items) |plane| allocator.free(plane.path);
        self.planes.deinit(allocator);
    }
};

pub fn matches(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "MeasurementRecord") != null or
        std.mem.indexOf(u8, data, "WellPlate") != null;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "wpi") or
        hasExtension(path, "mlf") or
        hasExtension(path, "mrf") or
        hasExtension(path, "ppf") or
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
    var info = try readDatasetInfo(allocator, io, path);
    defer info.deinit(allocator);
    if (info.planes.items.len == 0) return error.FileNotFound;
    sortPlanes(info.planes.items);

    const first = try readFile(allocator, io, info.planes.items[0].path);
    defer allocator.free(first);
    var metadata = try bio.tiff.readMetadata(first);
    metadata.format = "cv7000";
    metadata.image_description = null;
    metadata.size_z = info.size_z;
    metadata.size_c = info.size_c;
    metadata.size_t = info.size_t;
    metadata.plane_count = @intCast(info.planes.items.len);
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
    var info = try readDatasetInfo(allocator, io, path);
    defer info.deinit(allocator);
    sortPlanes(info.planes.items);
    if (plane_index >= info.planes.items.len) return error.InvalidPlaneIndex;

    const data = try readFile(allocator, io, info.planes.items[plane_index].path);
    defer allocator.free(data);
    var plane = try bio.tiff.readRegionIndex(allocator, data, 0, region);
    plane.metadata.format = "cv7000";
    plane.metadata.image_description = null;
    plane.metadata.size_z = info.size_z;
    plane.metadata.size_c = info.size_c;
    plane.metadata.size_t = info.size_t;
    plane.metadata.plane_count = @intCast(info.planes.items.len);
    plane.metadata.dimension_order = "XYCZT";
    return plane;
}

fn readDatasetInfo(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !DatasetInfo {
    const root = try datasetRoot(allocator, io, path);
    errdefer allocator.free(root);
    const mlf_path = try joinPath(allocator, root, measurement_file);
    defer allocator.free(mlf_path);
    const mlf = try readFile(allocator, io, mlf_path);
    defer allocator.free(mlf);

    var info = DatasetInfo{ .root = root, .planes = .empty };
    errdefer info.deinit(allocator);
    try readMeasurementPlanes(allocator, io, root, mlf, &info);
    return info;
}

fn datasetRoot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var current = parentSlice(path);
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        const mlf = try joinPath(allocator, current, measurement_file);
        defer allocator.free(mlf);
        if (existsFile(io, mlf)) return dupeBytes(allocator, current);

        const next = parentSlice(current);
        if (std.mem.eql(u8, next, current)) {
            break;
        }
        current = next;
    }
    return error.FileNotFound;
}

fn readMeasurementPlanes(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    bytes: []const u8,
    info: *DatasetInfo,
) !void {
    var max_z: u32 = 0;
    var max_c: u32 = 0;
    var max_t: u32 = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, pos, "MeasurementRecord")) |record_name| {
        const tag_start = findTagStart(bytes, record_name) orelse {
            pos = record_name + "MeasurementRecord".len;
            continue;
        };
        const tag_end = std.mem.indexOfScalarPos(u8, bytes, record_name, '>') orelse return error.InvalidFormat;
        const tag = bytes[tag_start .. tag_end + 1];
        pos = tag_end + 1;

        const record_type = attrValue(tag, "bts:Type") orelse attrValue(tag, "Type") orelse "";
        if (!std.ascii.eqlIgnoreCase(record_type, "IMG")) continue;

        const close_start = std.mem.indexOfPos(u8, bytes, tag_end + 1, "</") orelse return error.InvalidFormat;
        const file_text = std.mem.trim(u8, bytes[tag_end + 1 .. close_start], " \t\r\n");
        if (file_text.len == 0) continue;

        const image_path = try joinPath(allocator, root, file_text);
        errdefer allocator.free(image_path);
        if (!existsFile(io, image_path)) {
            allocator.free(image_path);
            continue;
        }

        const z = parseAttrZeroBased(tag, "bts:ZIndex", "ZIndex") orelse 0;
        const c = parseAttrZeroBased(tag, "bts:Ch", "Ch") orelse 0;
        const t = parseAttrZeroBased(tag, "bts:TimePoint", "TimePoint") orelse 0;
        try info.planes.append(allocator, .{
            .row = parseAttrZeroBased(tag, "bts:Row", "Row") orelse 0,
            .col = parseAttrZeroBased(tag, "bts:Column", "Column") orelse 0,
            .field = parseAttrZeroBased(tag, "bts:FieldIndex", "FieldIndex") orelse 0,
            .z = z,
            .c = c,
            .t = t,
            .path = image_path,
        });
        max_z = @max(max_z, z);
        max_c = @max(max_c, c);
        max_t = @max(max_t, t);
    }
    if (info.planes.items.len == 0) return error.FileNotFound;
    info.size_z = boundedDimension(max_z + 1);
    info.size_c = boundedDimension(max_c + 1);
    info.size_t = boundedDimension(max_t + 1);
}

fn findTagStart(bytes: []const u8, index: usize) ?usize {
    var i = index;
    while (i > 0) {
        i -= 1;
        if (bytes[i] == '<') return i;
        if (bytes[i] == '>') return null;
    }
    return null;
}

fn attrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, tag, pos, name)) |idx| {
        const after_name = idx + name.len;
        var cursor = after_name;
        while (cursor < tag.len and (tag[cursor] == ' ' or tag[cursor] == '\t')) : (cursor += 1) {}
        if (cursor >= tag.len or tag[cursor] != '=') {
            pos = after_name;
            continue;
        }
        cursor += 1;
        while (cursor < tag.len and (tag[cursor] == ' ' or tag[cursor] == '\t')) : (cursor += 1) {}
        if (cursor >= tag.len or (tag[cursor] != '"' and tag[cursor] != '\'')) return null;
        const quote = tag[cursor];
        cursor += 1;
        const end = std.mem.indexOfScalarPos(u8, tag, cursor, quote) orelse return null;
        return tag[cursor..end];
    }
    return null;
}

fn parseAttrZeroBased(tag: []const u8, prefixed: []const u8, plain: []const u8) ?u32 {
    const text = attrValue(tag, prefixed) orelse attrValue(tag, plain) orelse return null;
    const value = std.fmt.parseUnsigned(u32, text, 10) catch return null;
    return value -| 1;
}

fn boundedDimension(value: u32) u16 {
    return @intCast(@min(@max(value, 1), std.math.maxInt(u16)));
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
    if (a.row != b.row) return a.row < b.row;
    if (a.col != b.col) return a.col < b.col;
    if (a.field != b.field) return a.field < b.field;
    if (a.t != b.t) return a.t < b.t;
    if (a.z != b.z) return a.z < b.z;
    return a.c < b.c;
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
    return dupeBytes(allocator, parentSlice(path));
}

fn parentSlice(path: []const u8) []const u8 {
    const sep = lastSeparator(path) orelse return ".";
    if (sep == 0) return path[0..1];
    return path[0..sep];
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    if (isAbsolutePath(name)) return dupeBytes(allocator, name);
    const sep: u8 = if (std.mem.indexOfScalar(u8, base, '\\') != null) '\\' else '/';
    const needs_sep = base.len != 0 and base[base.len - 1] != '/' and base[base.len - 1] != '\\';
    const extra: usize = if (needs_sep) 1 else 0;
    const out = try allocator.alloc(u8, base.len + extra + name.len);
    @memcpy(out[0..base.len], base);
    if (needs_sep) out[base.len] = sep;
    @memcpy(out[base.len + extra ..], name);
    return out;
}

fn dupeBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len);
    std.mem.copyForwards(u8, out, bytes);
    return out;
}

fn lastSeparator(path: []const u8) ?usize {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    if (slash == null) return backslash;
    if (backslash == null) return slash;
    return @max(slash.?, backslash.?);
}

fn isAbsolutePath(path: []const u8) bool {
    if (path.len >= 1 and (path[0] == '/' or path[0] == '\\')) return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

const tiny_tiff = [_]u8{
    'I', 'I', 42, 0, 8, 0, 0,  0, 9, 0, 0,  1, 4, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 1,  1, 4, 0, 1,  0, 0, 0, 1,   0,
    0,   0,   2,  1, 3, 0, 1,  0, 0, 0, 8,  0, 0, 0, 3,   1,
    3,   0,   1,  0, 0, 0, 1,  0, 0, 0, 6,  1, 3, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 17, 1, 4, 0, 1,  0, 0, 0, 122, 0,
    0,   0,   21, 1, 3, 0, 1,  0, 0, 0, 1,  0, 0, 0, 22,  1,
    4,   0,   1,  0, 0, 0, 1,  0, 0, 0, 23, 1, 4, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 0,  0, 0, 0, 89,
};

const mlf_fixture =
    "<bts:Root>\n" ++
    "<bts:MeasurementRecord bts:Type=\"IMG\" bts:Row=\"1\" bts:Column=\"1\" bts:FieldIndex=\"1\" bts:TimePoint=\"1\" bts:ZIndex=\"1\" bts:Ch=\"1\">Images/img.tif</bts:MeasurementRecord>\n" ++
    "</bts:Root>\n";

test "detects cv7000 measurement xml" {
    try std.testing.expect(matches(mlf_fixture));
    try std.testing.expect(!matches("<xml/>"));
}

test "cv7000 path probe rejects unrelated tiff without panicking" {
    try std.testing.expectError(error.FileNotFound, readMetadataPath(std.testing.allocator, std.testing.io, "unrelated/path/sample.tif"));
}

test "reads cv7000 mlf delegated tiff plane" {
    const root = "cv7000-test";
    const images = "cv7000-test/Images";
    const wpi_path = "cv7000-test/plate.wpi";
    const mlf_path = "cv7000-test/MeasurementData.mlf";
    const tiff_path = "cv7000-test/Images/img.tif";
    cleanupFixture(root, images, wpi_path, mlf_path, tiff_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, images, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, images) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = wpi_path, .data = "<bts:WellPlate/>" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, wpi_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = mlf_path, .data = mlf_fixture });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, mlf_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tiff_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, wpi_path);
    try std.testing.expectEqualStrings("cv7000", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, tiff_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("cv7000", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{89}, plane.data);
}

fn cleanupFixture(root: []const u8, images: []const u8, wpi_path: []const u8, mlf_path: []const u8, tiff_path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, tiff_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, mlf_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, wpi_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, images) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
}
