const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const make_tag = 271;
const software_tag = 305;
const sis_tag = 33560;
const sis_ini_tag = 33471;
const sis_tag_2 = 34853;

pub fn matches(data: []const u8) bool {
    const software = tiff.firstIfdAsciiTag(data, software_tag);
    const make = tiff.firstIfdAsciiTag(data, make_tag);
    return (tiff.containsTag(data, sis_tag) and (software == null or startsWithTrimmed(software.?, "analySIS"))) or
        (tiff.containsTag(data, sis_tag_2) and make != null and startsWithTrimmed(make.?, "Olympus"));
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    var metadata = try tiff.readMetadata(data);
    metadata.format = "sis";
    if (tiff.firstIfdAsciiTag(data, sis_ini_tag)) |ini| {
        try applyIniDimensions(ini, &metadata);
    }
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "sis";
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    var plane = try tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "sis";
    return plane;
}

fn startsWithTrimmed(text: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trim(u8, text, " \t\r\n\x00"), prefix);
}

fn applyIniDimensions(ini: []const u8, metadata: *bio.Metadata) bio.ReaderError!void {
    const z = dimensionValue(ini, "Z") orelse return;
    const c = dimensionValue(ini, "Band") orelse return;
    const t = dimensionValue(ini, "Time") orelse return;
    const zc = std.math.mul(u32, z, c) catch return error.UnsupportedVariant;
    const planes = std.math.mul(u32, zc, t) catch return error.UnsupportedVariant;
    if (planes != metadata.plane_count) return;
    if (z > std.math.maxInt(u16) or t > std.math.maxInt(u16)) return error.UnsupportedVariant;
    const size_c = std.math.mul(u32, metadata.size_c, c) catch return error.UnsupportedVariant;
    if (size_c > std.math.maxInt(u16)) return error.UnsupportedVariant;
    metadata.size_z = @intCast(z);
    metadata.size_c = @intCast(size_c);
    metadata.size_t = @intCast(t);
    metadata.dimension_order = "XYZCT";
}

fn dimensionValue(ini: []const u8, key: []const u8) ?u32 {
    var lines = lineIterator(ini);
    var in_dimension = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            in_dimension = std.mem.eql(u8, std.mem.trim(u8, line[1 .. line.len - 1], " \t"), "Dimension");
            continue;
        }
        if (!in_dimension) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, name, key)) continue;
        const raw = std.mem.trim(u8, line[eq + 1 ..], " \t");
        return std.fmt.parseInt(u32, raw, 10) catch null;
    }
    return null;
}

const LineIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *LineIterator) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '\n' and self.data[self.pos] != '\r') : (self.pos += 1) {}
        const raw = self.data[start..self.pos];
        while (self.pos < self.data.len and (self.data[self.pos] == '\n' or self.data[self.pos] == '\r')) : (self.pos += 1) {}
        return std.mem.trim(u8, raw, " \t");
    }
};

fn lineIterator(data: []const u8) LineIterator {
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

test "reads sis tagged tiff plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 11;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const software = "analySIS 5\x00";
    const pixel_offset = ifd_end + software.len;

    try appendU16Le(&data, entry_count);
    try appendEntry(&data, 256, 4, 1, 1);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 1, 8);
    try appendEntry(&data, 259, 3, 1, 1);
    try appendEntry(&data, 262, 3, 1, 1);
    try appendEntry(&data, 273, 4, 1, @intCast(pixel_offset));
    try appendEntry(&data, 277, 3, 1, 1);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 1, 1);
    try appendEntry(&data, software_tag, 2, software.len, @intCast(ifd_end));
    try appendEntry(&data, sis_tag, 1, 4, 0);
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, software);
    try data.append(std.testing.allocator, 77);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("sis", metadata.format);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("sis", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}

test "matches olympus sis secondary tag" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 11;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const make = "Olympus Soft Imaging\x00";
    const pixel_offset = ifd_end + make.len;

    try appendU16Le(&data, entry_count);
    try appendEntry(&data, 256, 4, 1, 1);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 1, 8);
    try appendEntry(&data, 259, 3, 1, 1);
    try appendEntry(&data, 262, 3, 1, 1);
    try appendEntry(&data, 273, 4, 1, @intCast(pixel_offset));
    try appendEntry(&data, 277, 3, 1, 1);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 1, 1);
    try appendEntry(&data, make_tag, 2, make.len, @intCast(ifd_end));
    try appendEntry(&data, sis_tag_2, 4, 1, 0);
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, make);
    try data.append(std.testing.allocator, 1);

    try std.testing.expect(matches(data.items));
}

test "applies sis ini dimensions" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ini = "[Dimension]\nZ=1\nBand=2\nTime=1\n\x00";
    const entry_count = 11;
    const ifd_size = 2 + entry_count * 12 + 4;
    const second_entry_count = 9;
    const second_ifd_size = 2 + second_entry_count * 12 + 4;
    const second_ifd_offset = 8 + ifd_size;
    const ini_offset = second_ifd_offset + second_ifd_size;
    const first_pixel_offset = ini_offset + ini.len;
    const second_pixel_offset = first_pixel_offset + 1;

    try appendU16Le(&data, entry_count);
    try appendEntry(&data, 256, 4, 1, 1);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 1, 8);
    try appendEntry(&data, 259, 3, 1, 1);
    try appendEntry(&data, 262, 3, 1, 1);
    try appendEntry(&data, 273, 4, 1, @intCast(first_pixel_offset));
    try appendEntry(&data, 277, 3, 1, 1);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 1, 1);
    try appendEntry(&data, sis_ini_tag, 2, ini.len, @intCast(ini_offset));
    try appendEntry(&data, sis_tag, 1, 4, 0);
    try appendU32Le(&data, @intCast(second_ifd_offset));

    try appendU16Le(&data, second_entry_count);
    try appendEntry(&data, 256, 4, 1, 1);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 1, 8);
    try appendEntry(&data, 259, 3, 1, 1);
    try appendEntry(&data, 262, 3, 1, 1);
    try appendEntry(&data, 273, 4, 1, @intCast(second_pixel_offset));
    try appendEntry(&data, 277, 3, 1, 1);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 1, 1);
    try appendU32Le(&data, 0);

    try data.appendSlice(std.testing.allocator, ini);
    try data.appendSlice(std.testing.allocator, &.{ 7, 9 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqualStrings("XYZCT", metadata.dimension_order.?);
}
