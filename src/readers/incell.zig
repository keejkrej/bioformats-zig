const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

const PlaneRef = struct {
    row: u32,
    col: u32,
    field: u32,
    z: u32,
    c: u32,
    t: u32,
    path: []u8,
};

const Channel = struct {
    excitation: []u8,
    emission: []u8,

    fn deinit(self: Channel, allocator: std.mem.Allocator) void {
        allocator.free(self.excitation);
        allocator.free(self.emission);
    }
};

const DatasetInfo = struct {
    companion_path: []u8,
    planes: std.ArrayList(PlaneRef),
    size_z: u16 = 1,
    size_c: u16 = 1,
    size_t: u16 = 1,

    fn deinit(self: *DatasetInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.companion_path);
        for (self.planes.items) |plane| allocator.free(plane.path);
        self.planes.deinit(allocator);
    }
};

pub fn matches(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "IN Cell Analyzer") != null or
        std.mem.indexOf(u8, data, "Cytell") != null or
        (std.mem.indexOf(u8, data, "<ImageStack") != null and std.mem.indexOf(u8, data, "<Images ") != null);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "xdce") or
        hasExtension(path, "xml") or
        hasExtension(path, "tif") or
        hasExtension(path, "tiff") or
        hasExtension(path, "xlog");
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
    metadata.format = "incell";
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
    plane.metadata.format = "incell";
    plane.metadata.image_description = null;
    plane.metadata.size_z = info.size_z;
    plane.metadata.size_c = info.size_c;
    plane.metadata.size_t = info.size_t;
    plane.metadata.plane_count = @intCast(info.planes.items.len);
    plane.metadata.dimension_order = "XYCZT";
    return plane;
}

fn readDatasetInfo(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !DatasetInfo {
    const companion_path = try findCompanionPath(allocator, io, path);
    errdefer allocator.free(companion_path);
    const bytes = try readFile(allocator, io, companion_path);
    defer allocator.free(bytes);
    if (!matches(bytes)) return error.InvalidFormat;

    var info = DatasetInfo{ .companion_path = companion_path, .planes = .empty };
    errdefer info.deinit(allocator);
    const parent = try parentPath(allocator, companion_path);
    defer allocator.free(parent);
    try collectExplicitPlanes(allocator, io, parent, bytes, &info);
    if (info.planes.items.len == 0) try collectSyntheticPlanes(allocator, io, parent, bytes, &info);
    if (info.planes.items.len == 0) return error.FileNotFound;
    return info;
}

fn findCompanionPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "xdce") or hasExtension(path, "xml")) {
        const bytes = try readFile(allocator, io, path);
        defer allocator.free(bytes);
        if (matches(bytes)) return allocator.dupe(u8, path);
    }

    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    if (try firstMatchingCompanion(allocator, io, parent)) |candidate| return candidate;
    return error.FileNotFound;
}

fn firstMatchingCompanion(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or (!hasExtension(entry.name, "xdce") and !hasExtension(entry.name, "xml"))) continue;
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

fn collectExplicitPlanes(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: []const u8,
    bytes: []const u8,
    info: *DatasetInfo,
) !void {
    var pos: usize = 0;
    var max_z: u32 = 0;
    var max_c: u32 = 0;
    var max_t: u32 = 0;
    while (nextTag(bytes, "Image", &pos)) |image_tag| {
        const filename = attrValue(image_tag, "filename") orelse attrValue(image_tag, "Filename") orelse continue;
        if (isTruthy(attrValue(image_tag, "thumbnail") orelse attrValue(image_tag, "Thumbnail") orelse "false")) continue;
        if (!isTiffPath(filename)) continue;
        const image_path = try resolveImagePath(allocator, io, parent, filename);
        errdefer allocator.free(image_path);
        if (!existsFile(io, image_path)) {
            allocator.free(image_path);
            continue;
        }
        const row = parseAttrZeroBased(image_tag, "row", "Row") orelse 0;
        const col = parseAttrZeroBased(image_tag, "column", "Column") orelse 0;
        const field = parseAttrZeroBased(image_tag, "field_index", "Field") orelse 0;
        const z = parseAttrZeroBased(image_tag, "z_index", "ZIndex") orelse 0;
        const c = parseAttrZeroBased(image_tag, "wave_index", "WaveIndex") orelse parseAttrZeroBased(image_tag, "wavelength", "Wavelength") orelse 0;
        const t = parseAttrZeroBased(image_tag, "time_index", "TimeIndex") orelse 0;
        try info.planes.append(allocator, .{
            .row = row,
            .col = col,
            .field = field,
            .z = z,
            .c = c,
            .t = t,
            .path = image_path,
        });
        max_z = @max(max_z, z);
        max_c = @max(max_c, c);
        max_t = @max(max_t, t);
    }
    if (info.planes.items.len > 0) {
        info.size_z = boundedDimension(max_z + 1);
        info.size_c = boundedDimension(max_c + 1);
        info.size_t = boundedDimension(max_t + 1);
    }
}

fn collectSyntheticPlanes(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: []const u8,
    bytes: []const u8,
    info: *DatasetInfo,
) !void {
    var channels: std.ArrayList(Channel) = .empty;
    defer {
        for (channels.items) |channel| channel.deinit(allocator);
        channels.deinit(allocator);
    }
    try readChannels(allocator, bytes, &channels);
    if (channels.items.len == 0) return;

    const rows = firstAttrU32(bytes, "Plate", "rows") orelse 1;
    const cols = firstAttrU32(bytes, "Plate", "columns") orelse 1;
    const fields = firstAttrU32(bytes, "FieldOffsets", "number_of_fields") orelse 1;
    const z_count = firstAttrU32(bytes, "ZDimensionParameters", "number_of_slices") orelse 1;
    const t_count = firstAttrU32(bytes, "TimeSchedule", "number_of_time_points") orelse 1;
    info.size_z = boundedDimension(z_count);
    info.size_c = boundedDimension(@intCast(channels.items.len));
    info.size_t = boundedDimension(t_count);

    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var col: u32 = 1;
        while (col <= cols) : (col += 1) {
            var field: u32 = 1;
            while (field <= fields) : (field += 1) {
                for (channels.items, 0..) |channel, c| {
                    const filename = try std.fmt.allocPrint(
                        allocator,
                        "{s} - {d}(fld {d} wv {s} - {s}).tif",
                        .{ rowName(row), col, field, channel.excitation, channel.emission },
                    );
                    defer allocator.free(filename);
                    const image_path = try joinPath(allocator, parent, filename);
                    errdefer allocator.free(image_path);
                    if (!existsFile(io, image_path)) {
                        allocator.free(image_path);
                        continue;
                    }
                    try info.planes.append(allocator, .{
                        .row = row,
                        .col = col - 1,
                        .field = field - 1,
                        .z = 0,
                        .c = @intCast(c),
                        .t = 0,
                        .path = image_path,
                    });
                }
            }
        }
    }
}

fn readChannels(allocator: std.mem.Allocator, bytes: []const u8, channels: *std.ArrayList(Channel)) !void {
    var pos: usize = 0;
    while (nextTag(bytes, "Wavelength", &pos)) |tag| {
        if (std.mem.indexOf(u8, tag, "<Wavelengths") != null) continue;
        const tag_end = pos;
        const close_start = std.mem.indexOfPos(u8, bytes, tag_end, "</Wavelength>") orelse tag_end;
        const body = bytes[tag_end..close_start];
        const excitation = firstAttrInSlice(body, "ExcitationFilter", "name") orelse attrValue(tag, "name") orelse continue;
        const emission = firstAttrInSlice(body, "EmissionFilter", "name") orelse excitation;
        try channels.append(allocator, .{
            .excitation = try allocator.dupe(u8, excitation),
            .emission = try allocator.dupe(u8, emission),
        });
    }
}

fn nextTag(xml: []const u8, element: []const u8, pos: *usize) ?[]const u8 {
    var tag_buf: [64]u8 = undefined;
    if (element.len + 1 > tag_buf.len) return null;
    tag_buf[0] = '<';
    @memcpy(tag_buf[1..][0..element.len], element);
    const tag_prefix = tag_buf[0 .. element.len + 1];
    while (pos.* < xml.len) {
        const rel = std.mem.indexOf(u8, xml[pos.*..], tag_prefix) orelse return null;
        const tag_start = pos.* + rel;
        const tag_end = std.mem.indexOfScalarPos(u8, xml, tag_start, '>') orelse return null;
        pos.* = tag_end + 1;
        return xml[tag_start .. tag_end + 1];
    }
    return null;
}

fn firstAttrInSlice(xml: []const u8, element: []const u8, attr: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (nextTag(xml, element, &pos)) |tag| {
        if (attrValue(tag, attr)) |value| return value;
    }
    return null;
}

fn firstAttrU32(xml: []const u8, element: []const u8, attr: []const u8) ?u32 {
    const value = firstAttrInSlice(xml, element, attr) orelse return null;
    return std.fmt.parseUnsigned(u32, value, 10) catch null;
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
        if (cursor >= tag.len or tag[cursor] != '"') {
            pos = cursor;
            continue;
        }
        const value_start = cursor + 1;
        const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, '"') orelse return null;
        return tag[value_start..value_end];
    }
    return null;
}

fn parseAttrZeroBased(tag: []const u8, primary: []const u8, fallback: []const u8) ?u32 {
    const raw = attrValue(tag, primary) orelse attrValue(tag, fallback) orelse return null;
    const value = std.fmt.parseUnsigned(u32, raw, 10) catch return null;
    return value -| 1;
}

fn isTruthy(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1");
}

fn boundedDimension(value: u32) u16 {
    return @intCast(@min(@max(value, 1), std.math.maxInt(u16)));
}

fn rowName(row: u32) []const u8 {
    const names = [_][]const u8{
        "A", "B", "C", "D", "E", "F", "G", "H",
        "I", "J", "K", "L", "M", "N", "O", "P",
        "Q", "R", "S", "T", "U", "V", "W", "X",
        "Y", "Z",
    };
    if (row < names.len) return names[row];
    return "Z";
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

fn resolveImagePath(allocator: std.mem.Allocator, io: std.Io, parent: []const u8, raw: []const u8) ![]u8 {
    const decoded = try decodePathValue(allocator, raw);
    defer allocator.free(decoded);
    if (isAbsolutePath(decoded)) {
        if (existsFile(io, decoded)) return allocator.dupe(u8, decoded);
        return joinPath(allocator, parent, basename(decoded));
    }
    return joinPath(allocator, parent, decoded);
}

fn decodePathValue(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const hi = std.fmt.charToDigit(encoded[i + 1], 16) catch null;
            const lo = std.fmt.charToDigit(encoded[i + 2], 16) catch null;
            if (hi) |h| {
                if (lo) |l| {
                    try out.append(allocator, @intCast(h * 16 + l));
                    i += 3;
                    continue;
                }
            }
        }
        try out.append(allocator, if (encoded[i] == '\\') '/' else encoded[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
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

fn basename(path: []const u8) []const u8 {
    const sep = lastSeparator(path) orelse return path;
    return path[sep + 1 ..];
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

fn isTiffPath(path: []const u8) bool {
    return hasExtension(path, "tif") or hasExtension(path, "tiff");
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

const tiny_tiff = [_]u8{
    'I', 'I', 42, 0, 8, 0, 0,   0,
    9,   0,   0,  1, 4, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 1,   1,
    4,   0,   1,  0, 0, 0, 1,   0,
    0,   0,   2,  1, 3, 0, 1,   0,
    0,   0,   8,  0, 0, 0, 3,   1,
    3,   0,   1,  0, 0, 0, 1,   0,
    0,   0,   6,  1, 3, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 17,  1,
    4,   0,   1,  0, 0, 0, 122, 0,
    0,   0,   21, 1, 3, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 22,  1,
    4,   0,   1,  0, 0, 0, 1,   0,
    0,   0,   23, 1, 4, 0, 1,   0,
    0,   0,   1,  0, 0, 0, 0,   0,
    0,   0,   73,
};

test "reads incell synthetic tiff plane names" {
    const root = "incell-test";
    const xdce_path = "incell-test/plate.xdce";
    const image_path = "incell-test/A - 1(fld 1 wv DAPI - DAPI).tif";
    cleanupFixture(root, xdce_path, image_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = xdce_path,
        .data = "<ImageStack><Application name=\"IN Cell Analyzer 2000\"/><AutoLeadAcquisitionProtocol><Camera><Size width=\"1\" height=\"1\"/></Camera><Wavelengths><Wavelength index=\"0\"><ExcitationFilter name=\"DAPI\"/><EmissionFilter name=\"DAPI\"/></Wavelength></Wavelengths><Plate rows=\"1\" columns=\"1\"/><FieldOffsets number_of_fields=\"1\"/></AutoLeadAcquisitionProtocol><Images image_format=\"TIFF\" number=\"0\"/></ImageStack>",
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, xdce_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, xdce_path);
    try std.testing.expectEqualStrings("incell", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, image_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("incell", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{73}, plane.data);
}

test "reads incell explicit image filename" {
    const root = "incell-explicit-test";
    const xdce_path = "incell-explicit-test/plate.xdce";
    const image_path = "incell-explicit-test/field.tif";
    cleanupFixture(root, xdce_path, image_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = xdce_path,
        .data = "<ImageStack><Application name=\"IN Cell Analyzer 1000\"/><Images image_format=\"TIFF\"><Image filename=\"field.tif\" field_index=\"1\" wave_index=\"1\" z_index=\"1\" time_index=\"1\"/></Images></ImageStack>",
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, xdce_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, xdce_path);
    try std.testing.expectEqualStrings("incell", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
}

fn cleanupFixture(root: []const u8, xdce_path: []const u8, image_path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, xdce_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
}
