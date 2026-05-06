const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const max_companion_bytes = 512 * 1024 * 1024;
const flex_tag = 65200;

pub fn matches(data: []const u8) bool {
    return tiff.firstIfdContainsTag(data, flex_tag);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "flex") or hasExtension(path, "mea") or hasExtension(path, "res");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!matches(data)) return error.InvalidFormat;
    var metadata = try tiff.readMetadata(data);
    metadata.format = "flex";
    metadata.image_description = null;
    normalizeMetadata(data, &metadata);
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    if (!matches(data)) return error.InvalidFormat;
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "flex";
    plane.metadata.image_description = null;
    normalizeMetadata(data, &plane.metadata);
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    if (!matches(data)) return error.InvalidFormat;
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    var plane = try tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "flex";
    plane.metadata.image_description = null;
    normalizeMetadata(data, &plane.metadata);
    return plane;
}

fn normalizeMetadata(data: []const u8, metadata: *bio.Metadata) void {
    const xml = tiff.firstIfdAsciiTag(data, flex_tag) orelse return;
    const grouping = imageArrayGrouping(xml) orelse return;
    metadata.size_c = grouping.channels;
    metadata.plane_count = grouping.channels;
    metadata.series_count = grouping.series;
    metadata.dimension_order = "XYCZT";
}

const ImageArrayGrouping = struct {
    channels: u16,
    series: u32,
};

fn imageArrayGrouping(xml: []const u8) ?ImageArrayGrouping {
    var names: [16][]const u8 = undefined;
    var count: usize = 0;
    var pos: usize = 0;
    while (count < names.len) {
        const rel = std.mem.indexOf(u8, xml[pos..], "<Array") orelse break;
        const start = pos + rel;
        const close_rel = std.mem.indexOfScalar(u8, xml[start..], '>') orelse break;
        const tag = xml[start .. start + close_rel];
        pos = start + close_rel + 1;
        if (std.mem.indexOf(u8, tag, "Type=\"Image\"") == null) continue;
        const name_key = "Name=\"";
        const name_rel = std.mem.indexOf(u8, tag, name_key) orelse continue;
        const name_start = name_rel + name_key.len;
        const name_end_rel = std.mem.indexOfScalar(u8, tag[name_start..], '"') orelse continue;
        names[count] = tag[name_start .. name_start + name_end_rel];
        count += 1;
    }
    if (count == 0) return null;

    var period: usize = 1;
    while (period <= count) : (period += 1) {
        if (count % period != 0) continue;
        var i: usize = period;
        var repeats = true;
        while (i < count) : (i += 1) {
            if (!std.mem.eql(u8, names[i], names[i % period])) {
                repeats = false;
                break;
            }
        }
        if (repeats) {
            if (period > std.math.maxInt(u16)) return null;
            return .{ .channels = @intCast(period), .series = @intCast(count / period) };
        }
    }
    return null;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const flex_path = try flexPath(allocator, io, path);
    defer allocator.free(flex_path);
    const data = try readFile(allocator, io, flex_path);
    defer allocator.free(data);
    return readMetadata(data);
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const flex_path = try flexPath(allocator, io, path);
    defer allocator.free(flex_path);
    const data = try readFile(allocator, io, flex_path);
    defer allocator.free(data);
    return readRegionIndex(allocator, data, plane_index, region);
}

fn flexPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "flex")) return allocator.dupe(u8, path);
    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    return firstSiblingFlex(allocator, io, parent);
}

fn firstSiblingFlex(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and hasExtension(entry.name, "flex")) {
            return joinPath(allocator, dir_path, entry.name);
        }
    }
    return error.FileNotFound;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
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

fn appendTinyFlex(list: *std.ArrayList(u8), pixel: u8) !void {
    try list.appendSlice(std.testing.allocator, "II");
    try appendU16Le(list, 42);
    try appendU32Le(list, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const xml = "<Flex><Plate/></Flex>\x00";
    const xml_offset = ifd_end;
    const pixel_offset = xml_offset + xml.len;

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
    try appendEntry(list, flex_tag, 2, xml.len, @intCast(xml_offset));
    try appendU32Le(list, 0);
    try list.appendSlice(std.testing.allocator, xml);
    try list.append(std.testing.allocator, pixel);
}

test "reads flex tagged tiff plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendTinyFlex(&data, 91);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("flex", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("flex", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{91}, plane.data);
}

test "reads flex path from measurement sibling" {
    const root = "flex-path-test";
    const flex = "flex-path-test/000000001.flex";
    const mea = "flex-path-test/measurement.mea";
    std.Io.Dir.cwd().deleteFile(std.testing.io, flex) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, mea) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendTinyFlex(&data, 92);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = flex, .data = data.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, flex) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = mea, .data = "<Measurement/>" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, mea) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, mea);
    try std.testing.expectEqualStrings("flex", metadata.format);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, mea, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{92}, plane.data);
}

test "matches Bio-Formats default metadata for cached FLEX fixture" {
    const file_path = "fixtures/cache/flex/001001000.flex";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(32 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("flex", metadata.format);
    try std.testing.expectEqual(@as(u32, 1346), metadata.width);
    try std.testing.expectEqual(@as(u32, 1001), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 3), metadata.series_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data, 2));
}

test "matches Bio-Formats default plane and region hashes for cached FLEX fixture" {
    const file_path = "fixtures/cache/flex/001001000.flex";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(32 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const expected = [_]struct { plane: u32, sha256: [32]u8 }{
        .{ .plane = 0, .sha256 = .{ 0xd2, 0x11, 0x0a, 0xb0, 0x75, 0xcc, 0x31, 0x4e, 0x7d, 0x08, 0x4c, 0x77, 0xdc, 0xf5, 0xb9, 0xfd, 0x45, 0xda, 0x6a, 0x95, 0x22, 0xb3, 0x1e, 0x0f, 0x06, 0x57, 0x4f, 0xe3, 0x02, 0x6b, 0xed, 0x09 } },
        .{ .plane = 1, .sha256 = .{ 0xbb, 0x66, 0x8c, 0x6e, 0x0a, 0x04, 0xde, 0x59, 0x5d, 0xdd, 0xc6, 0xb4, 0x57, 0x63, 0xaf, 0x65, 0xf4, 0xe8, 0xdf, 0xb6, 0x00, 0x07, 0x32, 0x3b, 0xb1, 0x76, 0x31, 0xa9, 0xe9, 0xae, 0x99, 0xe8 } },
    };
    for (expected) |sample| {
        const plane = try readPlaneIndex(std.testing.allocator, data, sample.plane);
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqual(@as(usize, 2694692), plane.data.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
        try std.testing.expectEqualSlices(u8, &sample.sha256, &digest);
    }

    const region = try readRegionIndex(std.testing.allocator, data, 0, .{ .x = 17, .y = 19, .width = 16, .height = 12 });
    defer std.testing.allocator.free(region.data);
    try std.testing.expectEqual(@as(usize, 384), region.data.len);
    const expected_region: [32]u8 = .{ 0xb9, 0xd6, 0x81, 0x17, 0x47, 0xbc, 0x31, 0xc3, 0x3e, 0x4a, 0x84, 0x70, 0x9b, 0x92, 0x96, 0x74, 0x06, 0x7a, 0x01, 0xa7, 0x61, 0x05, 0xd8, 0x53, 0xa0, 0x1c, 0x4b, 0x1d, 0xb6, 0x0d, 0x6a, 0xc3 };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(region.data, &digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_region, &digest);
}
