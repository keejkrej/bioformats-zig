const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

const Info = struct {
    width: u32,
    height: u32,
    size_c: u16,
    size_z: u16,
    size_t: u16,
    pixel_type: bio.PixelType,
};

pub fn matches(data: []const u8) bool {
    return looksLikeInfo(data);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "vws") or hasExtension(path, "pst") or hasExtension(path, "inf");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    return metadataFromInfo(try parseInfo(data));
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const inf_path = try infPath(allocator, io, path);
    defer allocator.free(inf_path);
    const inf = try readFile(allocator, io, inf_path);
    defer allocator.free(inf);
    return metadataFromInfo(try parseInfo(inf));
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const inf_path = try infPath(allocator, io, path);
    defer allocator.free(inf_path);
    const inf = try readFile(allocator, io, inf_path);
    defer allocator.free(inf);
    const metadata = metadataFromInfo(try parseInfo(inf));
    try region.validate(metadata);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;

    const pst_path = try pstPathFromInf(allocator, io, inf_path);
    defer allocator.free(pst_path);
    const pixels = try readFile(allocator, io, pst_path);
    defer allocator.free(pixels);

    const plane_len = try planeByteCount(metadata);
    const offset = std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant;
    if (offset > pixels.len or pixels.len - offset < plane_len) return error.TruncatedData;
    const plane_data = pixels[offset..][0..plane_len];

    if (region.isFull(metadata)) {
        const out = try allocator.dupe(u8, plane_data);
        return .{ .metadata = metadata, .data = out };
    }
    const out = try cropPlane(allocator, plane_data, metadata, region);
    return .{ .metadata = metadata, .data = out };
}

fn metadataFromInfo(info: Info) bio.Metadata {
    return .{
        .format = "tillvision",
        .width = info.width,
        .height = info.height,
        .size_c = info.size_c,
        .samples_per_pixel = 1,
        .size_z = info.size_z,
        .size_t = info.size_t,
        .pixel_type = info.pixel_type,
        .little_endian = true,
        .plane_count = @as(u32, info.size_z) * @as(u32, info.size_c) * @as(u32, info.size_t),
        .dimension_order = "XYCZT",
    };
}

fn parseInfo(data: []const u8) bio.ReaderError!Info {
    var in_info = false;
    var width: ?u32 = null;
    var height: ?u32 = null;
    var bands: ?u16 = null;
    var slices: ?u16 = null;
    var frames: ?u16 = null;
    var datatype: ?u32 = null;

    var rows = rowIterator(data);
    while (rows.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == ';' or trimmed[0] == '#') continue;
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            in_info = std.ascii.eqlIgnoreCase(std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n"), "Info");
            continue;
        }
        if (!in_info) continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t\r\n");
        const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t\r\n");
        if (std.ascii.eqlIgnoreCase(key, "Width")) width = parsePositiveU32(value) catch return error.InvalidFormat;
        if (std.ascii.eqlIgnoreCase(key, "Height")) height = parsePositiveU32(value) catch return error.InvalidFormat;
        if (std.ascii.eqlIgnoreCase(key, "Bands")) bands = parsePositiveU16(value) catch return error.InvalidFormat;
        if (std.ascii.eqlIgnoreCase(key, "Slices")) slices = parsePositiveU16(value) catch return error.InvalidFormat;
        if (std.ascii.eqlIgnoreCase(key, "Frames")) frames = parsePositiveU16(value) catch return error.InvalidFormat;
        if (std.ascii.eqlIgnoreCase(key, "Datatype")) datatype = parsePositiveU32(value) catch return error.InvalidFormat;
    }

    return .{
        .width = width orelse return error.InvalidFormat,
        .height = height orelse return error.InvalidFormat,
        .size_c = bands orelse return error.InvalidFormat,
        .size_z = slices orelse return error.InvalidFormat,
        .size_t = frames orelse return error.InvalidFormat,
        .pixel_type = try pixelType(datatype orelse return error.InvalidFormat),
    };
}

fn pixelType(datatype: u32) bio.ReaderError!bio.PixelType {
    const signed = datatype % 2 == 1;
    const bytes = datatype / 2 + @intFromBool(signed);
    return switch (bytes) {
        1 => if (signed) .int8 else .uint8,
        2 => if (signed) .int16 else .uint16,
        4 => if (signed) .int32 else .uint32,
        8 => if (signed) error.UnsupportedVariant else .float64,
        else => error.UnsupportedVariant,
    };
}

fn infPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "inf")) return allocator.dupe(u8, path);
    if (hasExtension(path, "pst")) return replaceExtension(allocator, path, ".inf");
    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    const pst = try findFirstPst(allocator, io, parent, 0);
    defer allocator.free(pst);
    return replaceExtension(allocator, pst, ".inf");
}

fn pstPathFromInf(allocator: std.mem.Allocator, io: std.Io, inf_path: []const u8) ![]u8 {
    const lower = try replaceExtension(allocator, inf_path, ".pst");
    if (existsFile(io, lower)) return lower;
    allocator.free(lower);
    const upper = try replaceExtension(allocator, inf_path, ".PST");
    if (existsFile(io, upper)) return upper;
    allocator.free(upper);
    return error.FileNotFound;
}

fn findFirstPst(allocator: std.mem.Allocator, io: std.Io, root: []const u8, depth: usize) ![]u8 {
    if (depth > 4) return error.FileNotFound;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    var first_dir: ?[]u8 = null;
    defer if (first_dir) |dir_name| allocator.free(dir_name);
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and hasExtension(entry.name, "pst")) return joinPath(allocator, root, entry.name);
        if (entry.kind == .directory and first_dir == null) first_dir = try allocator.dupe(u8, entry.name);
    }
    if (first_dir) |dir_name| {
        const child = try joinPath(allocator, root, dir_name);
        defer allocator.free(child);
        return findFirstPst(allocator, io, child, depth + 1);
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

fn looksLikeInfo(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "[Info]") != null and
        std.mem.indexOf(u8, data, "Width") != null and
        std.mem.indexOf(u8, data, "Height") != null and
        std.mem.indexOf(u8, data, "Datatype") != null;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn existsFile(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]u8 {
    const sep = lastSeparator(path);
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    const cut = if (sep != null and dot < sep.?) path.len else dot;
    const out = try allocator.alloc(u8, cut + extension.len);
    @memcpy(out[0..cut], path[0..cut]);
    @memcpy(out[cut..], extension);
    return out;
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

fn parsePositiveU32(value: []const u8) bio.ReaderError!u32 {
    const parsed = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidFormat;
    if (parsed == 0) return error.InvalidFormat;
    return parsed;
}

fn parsePositiveU16(value: []const u8) bio.ReaderError!u16 {
    const parsed = std.fmt.parseUnsigned(u16, value, 10) catch return error.InvalidFormat;
    if (parsed == 0) return error.InvalidFormat;
    return parsed;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
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

const info_fixture =
    "[Info]\n" ++
    "Width=2\n" ++
    "Height=2\n" ++
    "Bands=1\n" ++
    "Slices=1\n" ++
    "Frames=1\n" ++
    "Datatype=2\n";

test "reads tillvision inf metadata" {
    const metadata = try readMetadata(info_fixture);
    try std.testing.expectEqualStrings("tillvision", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
}

test "reads tillvision raw pst pixels with crop" {
    const inf_path = "tillvision-test.inf";
    const pst_path = "tillvision-test.pst";
    const pixels = [_]u8{ 10, 20, 30, 40 };
    std.Io.Dir.cwd().deleteFile(std.testing.io, inf_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, pst_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = inf_path, .data = info_fixture });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, inf_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = pst_path, .data = &pixels });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, pst_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, inf_path, 0, .{ .x = 1, .y = 0, .width = 1, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("tillvision", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 20, 40 }, plane.data);
}
