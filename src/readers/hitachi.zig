const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;
const magic = "[SemImageFile]";

const Sidecar = struct {
    image_name: ?[]const u8 = null,
    sample_name: ?[]const u8 = null,
};

pub fn matches(data: []const u8) bool {
    _ = parseSidecar(data) catch return false;
    return true;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "txt");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    _ = try parseSidecar(data);
    return error.UnsupportedVariant;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = try parseSidecar(data);
    if (plane_index != 0) return error.InvalidPlaneIndex;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const sidecar_bytes = try readFile(allocator, io, path);
    defer allocator.free(sidecar_bytes);
    const sidecar = try parseSidecar(sidecar_bytes);

    const companion = try readCompanionFile(allocator, io, path, sidecar);
    defer allocator.free(companion);

    var metadata = try bio.readMetadata(companion);
    metadata.format = "hitachi";
    metadata.image_description = null;
    return metadata;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const sidecar_bytes = try readFile(allocator, io, path);
    defer allocator.free(sidecar_bytes);
    const sidecar = try parseSidecar(sidecar_bytes);

    const companion = try readCompanionFile(allocator, io, path, sidecar);
    defer allocator.free(companion);

    var plane = try bio.readPlaneRegionIndex(allocator, companion, plane_index, region);
    plane.metadata.format = "hitachi";
    plane.metadata.image_description = null;
    return plane;
}

fn parseSidecar(data: []const u8) bio.ReaderError!Sidecar {
    var in_sem_image_file = false;
    var sidecar = Sidecar{};
    var saw_section = false;

    var rows = rowIterator(data);
    while (rows.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == ';' or trimmed[0] == '#') continue;
        if (trimmed[0] == '[') {
            if (in_sem_image_file) break;
            in_sem_image_file = std.ascii.eqlIgnoreCase(trimmed, magic);
            saw_section = saw_section or in_sem_image_file;
            continue;
        }
        if (!in_sem_image_file) continue;

        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..equals], " \t");
        const value = trimValue(trimmed[equals + 1 ..]);
        if (std.ascii.eqlIgnoreCase(key, "ImageName")) {
            sidecar.image_name = value;
        } else if (std.ascii.eqlIgnoreCase(key, "SampleName")) {
            sidecar.sample_name = value;
        }
    }

    if (!saw_section) return error.InvalidFormat;
    return sidecar;
}

fn readCompanionFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, sidecar: Sidecar) ![]u8 {
    var last_error: anyerror = error.FileNotFound;
    if (sidecar.image_name) |image_name| {
        if (image_name.len != 0) {
            const companion_path = try siblingPath(allocator, path, image_name);
            defer allocator.free(companion_path);
            if (readFile(allocator, io, companion_path)) |bytes| {
                return bytes;
            } else |err| {
                last_error = err;
            }
        }
    }

    const extensions = [_][]const u8{ ".tif", ".tiff", ".bmp", ".jpg", ".jpeg" };
    for (extensions) |extension| {
        const candidate = try replaceExtension(allocator, path, extension);
        defer allocator.free(candidate);
        if (readFile(allocator, io, candidate)) |bytes| {
            return bytes;
        } else |err| {
            last_error = err;
        }
    }
    return last_error;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn siblingPath(allocator: std.mem.Allocator, path: []const u8, name: []const u8) ![]u8 {
    if (hasDirectory(name) or isAbsolutePath(name)) return allocator.dupe(u8, name);
    const sep = lastSeparator(path) orelse return allocator.dupe(u8, name);
    const out = try allocator.alloc(u8, sep + 1 + name.len);
    @memcpy(out[0 .. sep + 1], path[0 .. sep + 1]);
    @memcpy(out[sep + 1 ..], name);
    return out;
}

fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    const out = try allocator.alloc(u8, dot + extension.len);
    @memcpy(out[0..dot], path[0..dot]);
    @memcpy(out[dot..], extension);
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

fn trimValue(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len >= 2 and ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))) {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
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

const tiny_bmp = [_]u8{
    'B', 'M', 70, 0,  0, 0, 0,  0,  0,  0,   54,  0,   0,  0,
    40,  0,   0,  0,  2, 0, 0,  0,  2,  0,   0,   0,   1,  0,
    24,  0,   0,  0,  0, 0, 16, 0,  0,  0,   0,   0,   0,  0,
    0,   0,   0,  0,  0, 0, 0,  0,  0,  0,   0,   0,   30, 20,
    10,  60,  50, 40, 0, 0, 90, 80, 70, 120, 110, 100, 0,  0,
};

test "reads hitachi sidecar metadata through bmp companion" {
    const txt_path = "hitachi-test.txt";
    const bmp_path = "hitachi-test.bmp";
    const sidecar =
        "[SemImageFile]\n" ++
        "SampleName=Hitachi sample\n" ++
        "ImageName=hitachi-test.bmp\n";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = txt_path, .data = sidecar });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, txt_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = bmp_path, .data = &tiny_bmp });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, bmp_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, txt_path);
    try std.testing.expectEqualStrings("hitachi", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
}

test "reads hitachi delegated bmp pixels with crop" {
    const txt_path = "hitachi-crop-test.txt";
    const bmp_path = "hitachi-crop-test.bmp";
    const sidecar =
        "[SemImageFile]\n" ++
        "ImageName=hitachi-crop-test.bmp\n";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = txt_path, .data = sidecar });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, txt_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = bmp_path, .data = &tiny_bmp });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, bmp_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, txt_path, 0, .{
        .x = 1,
        .y = 0,
        .width = 1,
        .height = 2,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 100, 110, 120, 40, 50, 60 }, plane.data);
}

test "reads hitachi delegated jpeg pixels" {
    const txt_path = "hitachi-jpeg-test.txt";
    const jpg_path = "hitachi-jpeg-test.jpg";
    const sidecar =
        "[SemImageFile]\n" ++
        "ImageName=hitachi-jpeg-test.jpg\n";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = txt_path, .data = sidecar });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, txt_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = jpg_path, .data = &bio.jpeg.baseline_red_jpeg });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, jpg_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, txt_path);
    try std.testing.expectEqualStrings("hitachi", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, txt_path, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("hitachi", plane.metadata.format);
    try std.testing.expect(plane.data[0] > 200);
    try std.testing.expect(plane.data[1] < 80);
    try std.testing.expect(plane.data[2] < 80);
}

test "rejects missing hitachi companion image" {
    const txt_path = "hitachi-missing-test.txt";
    const sidecar =
        "[SemImageFile]\n" ++
        "ImageName=hitachi-missing-test.bmp\n";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = txt_path, .data = sidecar });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, txt_path) catch {};

    try std.testing.expectError(error.FileNotFound, readMetadataPath(std.testing.allocator, std.testing.io, txt_path));
}
