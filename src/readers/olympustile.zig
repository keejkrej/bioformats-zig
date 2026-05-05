const std = @import("std");
const bio = @import("../root.zig");

const max_metadata_bytes = 64 * 1024 * 1024;
const max_image_bytes = 512 * 1024 * 1024;

const Tile = struct {
    path: []u8,
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    fn deinit(self: Tile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

const Parsed = struct {
    tiles: []Tile,
    metadata: bio.Metadata,

    fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        for (self.tiles) |tile| tile.deinit(allocator);
        allocator.free(self.tiles);
    }
};

pub fn matches(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "<matl:") != null and
        std.mem.indexOf(u8, data, "marker:regionInfo") != null and
        std.mem.indexOf(u8, data, "matl:image") != null;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "omp2info");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    _ = data;
    return error.UnsupportedFormat;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedFormat;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const parsed = try parsePath(allocator, io, path);
    defer parsed.deinit(allocator);
    return parsed.metadata;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const parsed = try parsePath(allocator, io, path);
    defer parsed.deinit(allocator);
    try region.validate(parsed.metadata);

    const bytes_per_pixel = parsed.metadata.bytesPerPixel();
    const dst_row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, dst_row_bytes, region.height) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    @memset(out, 0);
    errdefer allocator.free(out);

    for (parsed.tiles) |tile| {
        const intersection = intersect(tile, region) orelse continue;
        const tile_region = bio.Region{
            .x = intersection.x - tile.x,
            .y = intersection.y - tile.y,
            .width = intersection.width,
            .height = intersection.height,
        };
        const tile_plane = try readTilePlane(allocator, io, tile.path, plane_index, tile_region);
        defer allocator.free(tile_plane.data);

        const src_row_bytes = std.math.mul(usize, intersection.width, bytes_per_pixel) catch return error.UnsupportedVariant;
        var row: u32 = 0;
        while (row < intersection.height) : (row += 1) {
            const src_offset = @as(usize, row) * src_row_bytes;
            const dst_y = intersection.y - region.y + row;
            const dst_x = intersection.x - region.x;
            const dst_offset = @as(usize, dst_y) * dst_row_bytes + @as(usize, dst_x) * bytes_per_pixel;
            @memcpy(out[dst_offset..][0..src_row_bytes], tile_plane.data[src_offset..][0..src_row_bytes]);
        }
    }

    return .{
        .metadata = parsed.metadata,
        .data = out,
    };
}

fn parsePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Parsed {
    if (!isPath(path)) return error.InvalidFormat;
    const xml = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_metadata_bytes));
    defer allocator.free(xml);
    if (!matches(xml)) return error.InvalidFormat;

    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    const rows = tagUnsigned(xml, "matl:numOfYAreas") orelse 1;
    const cols = tagUnsigned(xml, "matl:numOfXAreas") orelse 1;

    var tiles: std.ArrayList(Tile) = .empty;
    errdefer {
        for (tiles.items) |tile| tile.deinit(allocator);
        tiles.deinit(allocator);
    }

    var base_metadata: ?bio.Metadata = null;
    var tile_width: u32 = 0;
    var tile_height: u32 = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<matl:area")) |area_start| {
        const area_end = std.mem.indexOfPos(u8, xml, area_start, "</matl:area>") orelse return error.InvalidFormat;
        const area = xml[area_start..area_end];
        const image = tagText(area, "matl:image") orelse return error.InvalidFormat;
        const x_index = tagUnsigned(area, "matl:xIndex") orelse 0;
        const y_index = tagUnsigned(area, "matl:yIndex") orelse 0;
        const tile_path = try joinPath(allocator, parent, std.mem.trim(u8, image, " \t\r\n"));
        errdefer allocator.free(tile_path);

        var metadata = try readTileMetadata(allocator, io, tile_path);
        metadata.image_description = null;
        if (base_metadata == null) {
            tile_width = metadata.width;
            tile_height = metadata.height;
            base_metadata = metadata;
        }

        try tiles.append(allocator, .{
            .path = tile_path,
            .x = x_index * tile_width,
            .y = y_index * tile_height,
            .width = metadata.width,
            .height = metadata.height,
        });
        pos = area_end + "</matl:area>".len;
    }
    if (tiles.items.len == 0 or base_metadata == null) return error.InvalidFormat;

    var metadata = base_metadata.?;
    metadata.format = "olympustile";
    metadata.width = 0;
    metadata.height = 0;
    for (tiles.items) |tile| {
        metadata.width = @max(metadata.width, tile.x + tile.width);
        metadata.height = @max(metadata.height, tile.y + tile.height);
    }
    if (metadata.width == 0) metadata.width = tile_width * cols;
    if (metadata.height == 0) metadata.height = tile_height * rows;
    metadata.image_description = null;

    return .{
        .tiles = try tiles.toOwnedSlice(allocator),
        .metadata = metadata,
    };
}

fn readTileMetadata(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_image_bytes));
    defer allocator.free(bytes);
    if (bio.cellsens.isPath(path)) return bio.cellsens.readMetadataPath(allocator, io, path);
    if (bio.oir.matches(bytes)) return bio.oir.readMetadata(bytes);
    return error.UnsupportedFormat;
}

fn readTilePlane(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    if (bio.cellsens.isPath(path)) {
        return bio.cellsens.readPlanePathRegionIndex(allocator, io, path, plane_index, region);
    }
    return error.UnsupportedVariant;
}

fn intersect(tile: Tile, region: bio.Region) ?bio.Region {
    const ax0 = tile.x;
    const ay0 = tile.y;
    const ax1 = tile.x + tile.width;
    const ay1 = tile.y + tile.height;
    const bx0 = region.x;
    const by0 = region.y;
    const bx1 = region.x + region.width;
    const by1 = region.y + region.height;
    const x0 = @max(ax0, bx0);
    const y0 = @max(ay0, by0);
    const x1 = @min(ax1, bx1);
    const y1 = @min(ay1, by1);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}

fn tagUnsigned(xml: []const u8, tag: []const u8) ?u32 {
    const text = tagText(xml, tag) orelse return null;
    return std.fmt.parseUnsigned(u32, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

fn tagText(xml: []const u8, tag: []const u8) ?[]const u8 {
    var open_buf: [96]u8 = undefined;
    var close_buf: [96]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}", .{tag}) catch return null;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
    const open_start = std.mem.indexOf(u8, xml, open) orelse return null;
    const open_end = std.mem.indexOfScalarPos(u8, xml, open_start, '>') orelse return null;
    const close_start = std.mem.indexOfPos(u8, xml, open_end + 1, close) orelse return null;
    return xml[open_end + 1 .. close_start];
}

fn parentPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const sep = lastSeparator(path) orelse return allocator.dupe(u8, ".");
    if (sep == 0) return allocator.dupe(u8, path[0..1]);
    return allocator.dupe(u8, path[0..sep]);
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
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

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn appendTinyVsi(list: *std.ArrayList(u8), pixel: u8) !void {
    try list.appendSlice(std.testing.allocator, "II");
    try appendU16Le(list, 42);
    try appendU32Le(list, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const software = "cellSens Dimension\x00";
    const pixel_offset = ifd_end + software.len;

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
    try appendEntry(list, 305, 2, software.len, @intCast(ifd_end));
    try appendU32Le(list, 0);
    try list.appendSlice(std.testing.allocator, software);
    try list.append(std.testing.allocator, pixel);
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

test "reads olympus tile metadata from cellsens tiles" {
    const root = "olympustile-test";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const tile_a = "olympustile-test/a.vsi";
    const tile_b = "olympustile-test/b.vsi";
    const info = "olympustile-test/scan.omp2info";
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(std.testing.allocator);
    try appendTinyVsi(&a, 11);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    try appendTinyVsi(&b, 22);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tile_a, .data = a.items });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tile_b, .data = b.items });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = info, .data =
        \\<matl:properties><matl:group>
        \\<marker:regionInfo><marker:coordinates width="2000" height="1000"/></marker:regionInfo>
        \\<matl:areaInfo><matl:numOfYAreas>1</matl:numOfYAreas><matl:numOfXAreas>2</matl:numOfXAreas></matl:areaInfo>
        \\<matl:area><matl:image>a.vsi</matl:image><matl:xIndex>0</matl:xIndex><matl:yIndex>0</matl:yIndex></matl:area>
        \\<matl:area><matl:image>b.vsi</matl:image><matl:xIndex>1</matl:xIndex><matl:yIndex>0</matl:yIndex></matl:area>
        \\</matl:group></matl:properties>
    });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, info);
    try std.testing.expectEqualStrings("olympustile", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
}

test "stitches olympus tile plane from cellsens tiles" {
    const root = "olympustile-plane-test";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const tile_a = "olympustile-plane-test/a.vsi";
    const tile_b = "olympustile-plane-test/b.vsi";
    const info = "olympustile-plane-test/scan.omp2info";
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(std.testing.allocator);
    try appendTinyVsi(&a, 11);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    try appendTinyVsi(&b, 22);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tile_a, .data = a.items });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tile_b, .data = b.items });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = info, .data =
        \\<matl:properties><matl:group>
        \\<marker:regionInfo><marker:coordinates width="2000" height="1000"/></marker:regionInfo>
        \\<matl:areaInfo><matl:numOfYAreas>1</matl:numOfYAreas><matl:numOfXAreas>2</matl:numOfXAreas></matl:areaInfo>
        \\<matl:area><matl:image>a.vsi</matl:image><matl:xIndex>0</matl:xIndex><matl:yIndex>0</matl:yIndex></matl:area>
        \\<matl:area><matl:image>b.vsi</matl:image><matl:xIndex>1</matl:xIndex><matl:yIndex>0</matl:yIndex></matl:area>
        \\</matl:group></matl:properties>
    });

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, info, 0, .{
        .x = 0,
        .y = 0,
        .width = 2,
        .height = 1,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("olympustile", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 11, 22 }, plane.data);
}
