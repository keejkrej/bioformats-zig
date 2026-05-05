const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

const Sidecar = struct {
    first_image: []const u8,
};

pub fn matches(data: []const u8) bool {
    _ = parseSidecar(data) catch return false;
    return true;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "afi");
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

    var metadata = try bio.svs.readMetadata(image);
    metadata.format = "afi";
    metadata.image_description = null;
    metadata.size_c = 1;
    metadata.samples_per_pixel = 1;
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

    var plane = try bio.svs.readRegionIndex(allocator, image, plane_index, region);
    plane.metadata.format = "afi";
    plane.metadata.image_description = null;
    plane.metadata.size_c = 1;
    plane.metadata.samples_per_pixel = 1;
    return plane;
}

fn parseSidecar(data: []const u8) bio.ReaderError!Sidecar {
    if (std.mem.indexOf(u8, data, "<AFI") == null and std.mem.indexOf(u8, data, "<afi") == null) return error.InvalidFormat;
    const start_tag = "<Path>";
    const end_tag = "</Path>";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, data, pos, start_tag)) |start| {
        const value_start = start + start_tag.len;
        const end = std.mem.indexOfPos(u8, data, value_start, end_tag) orelse return error.InvalidFormat;
        const value = std.mem.trim(u8, data[value_start..end], " \t\r\n");
        if (value.len > 0) return .{ .first_image = value };
        pos = end + end_tag.len;
    }
    return error.InvalidFormat;
}

fn readFirstImage(allocator: std.mem.Allocator, io: std.Io, path: []const u8, sidecar: Sidecar) ![]u8 {
    const image_path = try siblingPath(allocator, path, sidecar.first_image);
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

fn appendOnePixelIfd(list: *std.ArrayList(u8), pixel_offset: u32, description_offset: ?u32, description_len: u32, next_ifd_offset: u32) !void {
    const entry_count: u16 = if (description_offset == null) 9 else 10;
    try appendU16Le(list, entry_count);
    try appendEntry(list, 256, 4, 1, 1);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, 8);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 273, 4, 1, pixel_offset);
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 1);
    if (description_offset) |offset| try appendEntry(list, 270, 2, description_len, offset);
    try appendU32Le(list, next_ifd_offset);
}

fn appendTinySvs(list: *std.ArrayList(u8), pixel: u8) !void {
    try list.appendSlice(std.testing.allocator, "II");
    try appendU16Le(list, 42);
    try appendU32Le(list, 8);

    const first_ifd_size = 2 + 10 * 12 + 4;
    const second_ifd_offset = 8 + first_ifd_size;
    const second_ifd_size = 2 + 9 * 12 + 4;
    const description = "Aperio Image|MPP = 0.25\x00";
    const description_offset = second_ifd_offset + second_ifd_size;
    const first_pixel_offset = description_offset + description.len;
    const second_pixel_offset = first_pixel_offset + 1;

    try appendOnePixelIfd(list, @intCast(first_pixel_offset), @intCast(description_offset), description.len, @intCast(second_ifd_offset));
    try appendOnePixelIfd(list, @intCast(second_pixel_offset), null, 0, 0);
    try list.appendSlice(std.testing.allocator, description);
    try list.append(std.testing.allocator, pixel);
    try list.append(std.testing.allocator, pixel +% 1);
}

test "parses first afi path" {
    const sidecar = "<AFI><Image><Path> channel_0.svs </Path></Image></AFI>";
    const parsed = try parseSidecar(sidecar);
    try std.testing.expectEqualStrings("channel_0.svs", parsed.first_image);
    try std.testing.expect(matches(sidecar));
}

test "reads afi metadata through first svs image" {
    const sidecar_path = "afi-test.afi";
    const image_path = "afi-channel_0.svs";
    const sidecar = "<AFI><Image><Path>afi-channel_0.svs</Path></Image></AFI>";
    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(std.testing.allocator);
    try appendTinySvs(&image, 42);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = sidecar_path, .data = sidecar });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, sidecar_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = image.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, sidecar_path);
    try std.testing.expectEqualStrings("afi", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
}

test "reads afi pixels through first svs image" {
    const sidecar_path = "afi-plane-test.afi";
    const image_path = "afi-plane-channel_0.svs";
    const sidecar = "<AFI><Path>afi-plane-channel_0.svs</Path></AFI>";
    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(std.testing.allocator);
    try appendTinySvs(&image, 77);

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
    try std.testing.expectEqualStrings("afi", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}
