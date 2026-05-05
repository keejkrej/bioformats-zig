const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

const Sidecar = struct {
    first_image: ?[]const u8 = null,
};

pub fn matches(data: []const u8) bool {
    _ = parseSidecar(data) catch return false;
    return true;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "ndpis");
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

    const image = try readFirstImage(allocator, io, path, sidecar);
    defer allocator.free(image);

    var metadata = try bio.ndpi.readMetadata(image);
    metadata.format = "ndpis";
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

    const image = try readFirstImage(allocator, io, path, sidecar);
    defer allocator.free(image);

    var plane = try bio.ndpi.readRegionIndex(allocator, image, plane_index, region);
    plane.metadata.format = "ndpis";
    plane.metadata.image_description = null;
    return plane;
}

fn parseSidecar(data: []const u8) bio.ReaderError!Sidecar {
    var sidecar = Sidecar{};
    var saw_ndpis_key = false;

    var rows = rowIterator(data);
    while (rows.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..equals], " \t");
        const value = std.mem.trim(u8, trimmed[equals + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "NoImages")) {
            saw_ndpis_key = true;
        } else if (startsWithImageKey(key)) {
            saw_ndpis_key = true;
            if (sidecar.first_image == null and value.len != 0) sidecar.first_image = value;
        }
    }

    if (!saw_ndpis_key or sidecar.first_image == null) return error.InvalidFormat;
    return sidecar;
}

fn readFirstImage(allocator: std.mem.Allocator, io: std.Io, path: []const u8, sidecar: Sidecar) ![]u8 {
    const image_name = sidecar.first_image orelse return error.InvalidFormat;
    const image_path = try siblingPath(allocator, path, image_name);
    defer allocator.free(image_path);
    return readFile(allocator, io, image_path);
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

fn startsWithImageKey(key: []const u8) bool {
    if (key.len <= "Image".len) return false;
    if (!std.ascii.eqlIgnoreCase(key[0.."Image".len], "Image")) return false;
    for (key["Image".len..]) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }
    return true;
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

fn appendTinyNdpi(list: *std.ArrayList(u8), pixel: u8) !void {
    try list.appendSlice(std.testing.allocator, "II");
    try appendU16Le(list, 42);
    try appendU32Le(list, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const marker = "NDPI_MARKER\x00";
    const marker_offset = ifd_end;
    const pixel_offset = marker_offset + marker.len;

    try appendU16Le(list, entry_count);
    try appendEntry(list, 256, 4, 1, 1);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, 8);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 273, 4, 1, @intCast(pixel_offset));
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 1);
    try appendEntry(list, 65426, 2, marker.len, @intCast(marker_offset));
    try appendU32Le(list, 0);
    try list.appendSlice(std.testing.allocator, marker);
    try list.append(std.testing.allocator, pixel);
}

test "reads ndpis sidecar metadata through first ndpi image" {
    const sidecar_path = "ndpis-test.ndpis";
    const image_path = "ndpis-test-0.ndpi";
    const sidecar = "NoImages=1\r\nImage0=ndpis-test-0.ndpi\r\n";
    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(std.testing.allocator);
    try appendTinyNdpi(&image, 42);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = sidecar_path, .data = sidecar });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, sidecar_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = image.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, sidecar_path);
    try std.testing.expectEqualStrings("ndpis", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
}

test "reads ndpis sidecar pixels through first ndpi image" {
    const sidecar_path = "ndpis-plane-test.ndpis";
    const image_path = "ndpis-plane-test-0.ndpi";
    const sidecar = "NoImages=1\nImage0=ndpis-plane-test-0.ndpi\n";
    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(std.testing.allocator);
    try appendTinyNdpi(&image, 77);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = sidecar_path, .data = sidecar });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, sidecar_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = image.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, sidecar_path, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("ndpis", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}
