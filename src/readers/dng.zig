const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const make_tag = 271;
const model_tag = 272;
const software_tag = 305;
const canon_tag = 34665;
const tiff_ep_standard_tag = 37398;

pub fn matches(data: []const u8) bool {
    const make = tiff.firstIfdAsciiTag(data, make_tag) orelse return false;
    if (std.mem.indexOf(u8, make, "Canon") == null) return false;
    if (!tiff.containsTag(data, tiff_ep_standard_tag) and !tiff.containsTag(data, canon_tag)) return false;
    if (tiff.firstIfdAsciiTag(data, model_tag)) |model| {
        if (std.mem.endsWith(u8, std.mem.trim(u8, model, " \t\r\n\x00"), "S1 IS")) return false;
    }
    if (tiff.firstIfdAsciiTag(data, software_tag)) |software| {
        if (std.mem.indexOf(u8, software, "Canon") == null) return false;
    }
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    var metadata = try tiff.readMetadata(data);
    metadata.format = "dng";
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "dng";
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    var plane = try tiff.readRegionIndex(allocator, data, plane_index, region);
    plane.metadata.format = "dng";
    return plane;
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

test "reads canon dng tagged tiff plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 11;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const make = "Canon\x00";
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
    try appendEntry(&data, tiff_ep_standard_tag, 4, 1, 1);
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, make);
    try data.append(std.testing.allocator, 210);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("dng", metadata.format);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("dng", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{210}, plane.data);
}

test "rejects excluded canon s1 is model" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 12;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const make = "Canon\x00";
    const model = "PowerShot S1 IS\x00";
    const make_offset = ifd_end;
    const model_offset = make_offset + make.len;
    const pixel_offset = model_offset + model.len;

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
    try appendEntry(&data, make_tag, 2, make.len, @intCast(make_offset));
    try appendEntry(&data, model_tag, 2, model.len, @intCast(model_offset));
    try appendEntry(&data, tiff_ep_standard_tag, 4, 1, 1);
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, make);
    try data.appendSlice(std.testing.allocator, model);
    try data.append(std.testing.allocator, 1);

    try std.testing.expect(!matches(data.items));
}
