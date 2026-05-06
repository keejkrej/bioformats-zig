const std = @import("std");
const bio = @import("../root.zig");
const jpeg = @import("jpeg.zig");
const tiff = @import("tiff.zig");

const max_image_bytes = 512 * 1024 * 1024;
const image_description_tag = 270;
const software_tag = 305;
const max_ets_dimensions = 8;
const ets_raw_compression = 0;
const ets_jpeg_compression = 2;
const image_boundary_tag = 2053;
const int_rect_type = 259;

pub fn matches(data: []const u8) bool {
    return containsCellSensMarker(data);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "vsi");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!matches(data)) return error.InvalidFormat;
    return metadataFromTiff(data);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    if (!matches(data)) return error.InvalidFormat;
    var plane = try tiff.readPlaneIndex(allocator, data, plane_index);
    plane.metadata.format = "cellsens";
    plane.metadata.image_description = null;
    return plane;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    if (!isPath(path)) return error.InvalidFormat;
    const bytes = try readFile(allocator, io, path);
    defer allocator.free(bytes);
    var metadata = try metadataFromTiff(bytes);
    const ets_path = findCompanionEtsPath(allocator, io, path) catch null;
    if (ets_path) |companion| {
        defer allocator.free(companion);
        const ets = try readFile(allocator, io, companion);
        defer allocator.free(ets);
        const header = try parseEtsHeader(ets);
        metadata = mergeEtsMetadata(metadata, header, maxImageBoundary(bytes, header));
    }
    return metadata;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    if (!isPath(path)) return error.InvalidFormat;
    const ets_path = findCompanionEtsPath(allocator, io, path) catch null;
    if (ets_path) |companion| {
        defer allocator.free(companion);
        const ets = try readFile(allocator, io, companion);
        defer allocator.free(ets);
        return readRawEtsRegion(allocator, io, ets, path, plane_index, region);
    }

    const bytes = try readFile(allocator, io, path);
    defer allocator.free(bytes);

    var plane = try tiff.readRegionIndex(allocator, bytes, plane_index, region);
    plane.metadata.format = "cellsens";
    plane.metadata.image_description = null;
    return plane;
}

fn metadataFromTiff(data: []const u8) bio.ReaderError!bio.Metadata {
    var metadata = try tiff.readMetadata(data);
    metadata.format = "cellsens";
    metadata.image_description = null;
    return metadata;
}

const EtsHeader = struct {
    n_dimensions: u32,
    used_chunk_offset: usize,
    n_used_chunks: u32,
    pixel_type: bio.PixelType,
    size_c: u16,
    samples_per_pixel: u16,
    compression: u32,
    tile_width: u32,
    tile_height: u32,
    use_pyramid: bool,
    resolution_count: u32,
    padded_width: u32,
    padded_height: u32,

    fn bytesPerPixel(self: EtsHeader) usize {
        return @as(usize, self.samples_per_pixel) * self.pixel_type.bytesPerSample();
    }
};

const EtsChunk = struct {
    coords: [max_ets_dimensions]u32,
    offset: usize,
    byte_count: usize,
};

const ImageBoundary = struct {
    width: u32,
    height: u32,
};

fn mergeEtsMetadata(metadata: bio.Metadata, header: EtsHeader, boundary: ?ImageBoundary) bio.Metadata {
    var merged = metadata;
    if (boundary) |bounds| {
        merged.width = bounds.width;
        merged.height = bounds.height;
    }
    merged.pixel_type = header.pixel_type;
    merged.size_c = header.size_c;
    merged.samples_per_pixel = header.samples_per_pixel;
    merged.little_endian = header.compression == ets_raw_compression;
    merged.plane_count = 1;
    if (header.use_pyramid and header.resolution_count > 1) {
        merged.series_count = header.resolution_count + 1;
    }
    merged.format = "cellsens";
    merged.image_description = null;
    return merged;
}

fn maxImageBoundary(data: []const u8, header: EtsHeader) ?ImageBoundary {
    var best: ?ImageBoundary = null;
    var best_area: u64 = 0;
    var pos: usize = 0;
    while (pos + 32 <= data.len) : (pos += 1) {
        if (readU32Le(data[pos..][0..4]) != int_rect_type) continue;
        if (readU32Le(data[pos + 4 ..][0..4]) != image_boundary_tag) continue;
        if (readU32Le(data[pos + 12 ..][0..4]) != 16) continue;
        const width = readU32Le(data[pos + 24 ..][0..4]);
        const height = readU32Le(data[pos + 28 ..][0..4]);
        if (width == 0 or height == 0) continue;
        if (header.padded_width > 0 and width > header.padded_width) continue;
        if (header.padded_height > 0 and height > header.padded_height) continue;
        const area = @as(u64, width) * height;
        if (area > best_area) {
            best_area = area;
            best = .{ .width = width, .height = height };
        }
    }
    return best;
}

fn readRawEtsRegion(
    allocator: std.mem.Allocator,
    io: std.Io,
    ets: []const u8,
    vsi_path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    if (plane_index != 0) return error.InvalidPlaneIndex;
    const header = try parseEtsHeader(ets);

    const vsi_bytes = try readFile(allocator, io, vsi_path);
    defer allocator.free(vsi_bytes);
    const tiff_metadata = try metadataFromTiff(vsi_bytes);
    const metadata = mergeEtsMetadata(tiff_metadata, header, maxImageBoundary(vsi_bytes, header));

    const bytes_per_pixel = header.bytesPerPixel();
    const out_len = std.math.mul(usize, std.math.mul(usize, region.width, region.height) catch return error.UnsupportedVariant, bytes_per_pixel) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    @memset(out, 0);

    var pos = header.used_chunk_offset;
    var chunk_index: u32 = 0;
    while (chunk_index < header.n_used_chunks) : (chunk_index += 1) {
        const chunk = try parseEtsChunk(ets, header, &pos);
        if (!isFirstPlaneChunk(chunk, header)) continue;

        const tile_x = std.math.mul(u32, chunk.coords[0], header.tile_width) catch return error.UnsupportedVariant;
        const tile_y = std.math.mul(u32, chunk.coords[1], header.tile_height) catch return error.UnsupportedVariant;
        copyChunkIntersection(allocator, ets, chunk, header, region, tile_x, tile_y, out) catch |err| {
            allocator.free(out);
            return err;
        };
    }

    return .{ .metadata = metadata, .data = out };
}

fn parseEtsHeader(data: []const u8) bio.ReaderError!EtsHeader {
    if (data.len < 64 or !std.mem.eql(u8, data[0..4], "SIS\x00")) return error.InvalidFormat;
    const n_dimensions = readU32Le(data[12..16]);
    if (n_dimensions < 2 or n_dimensions > max_ets_dimensions) return error.UnsupportedVariant;
    const additional_header_offset_u64 = readU64Le(data[16..24]);
    const used_chunk_offset_u64 = readU64Le(data[32..40]);
    const n_used_chunks = readU32Le(data[40..44]);
    if (additional_header_offset_u64 > std.math.maxInt(usize) or used_chunk_offset_u64 > std.math.maxInt(usize)) return error.UnsupportedVariant;
    const additional_header_offset: usize = @intCast(additional_header_offset_u64);
    const used_chunk_offset: usize = @intCast(used_chunk_offset_u64);
    if (additional_header_offset > data.len or data.len - additional_header_offset < 156) return error.TruncatedData;
    if (!std.mem.eql(u8, data[additional_header_offset..][0..4], "ETS\x00")) return error.InvalidFormat;

    const fields = data[additional_header_offset + 8 ..];
    var pixel_type = try pixelTypeFromEts(readU32Le(fields[0..4]));
    const size_c_u32 = readU32Le(fields[4..8]);
    if (size_c_u32 == 0 or size_c_u32 > std.math.maxInt(u16)) return error.UnsupportedVariant;
    const size_c: u16 = @intCast(size_c_u32);
    if (size_c == 3 and pixel_type == .uint8) pixel_type = .rgb8;
    if (size_c == 3 and pixel_type == .uint16) pixel_type = .rgb16;
    const compression = readU32Le(fields[12..16]);
    const tile_width = readU32Le(fields[20..24]);
    const tile_height = readU32Le(fields[24..28]);
    if (tile_width == 0 or tile_height == 0) return error.InvalidFormat;

    const component_order_offset = additional_header_offset + 8 + 32 + 68 + 40;
    if (component_order_offset > data.len or data.len - component_order_offset < 8) return error.TruncatedData;
    const use_pyramid = readU32Le(data[component_order_offset + 4 ..][0..4]) != 0;

    var header: EtsHeader = .{
        .n_dimensions = n_dimensions,
        .used_chunk_offset = used_chunk_offset,
        .n_used_chunks = n_used_chunks,
        .pixel_type = pixel_type,
        .size_c = size_c,
        .samples_per_pixel = if (size_c > 1) size_c else 1,
        .compression = compression,
        .tile_width = tile_width,
        .tile_height = tile_height,
        .use_pyramid = use_pyramid,
        .resolution_count = 1,
        .padded_width = 0,
        .padded_height = 0,
    };
    if (use_pyramid and n_dimensions > 0) {
        var pos = used_chunk_offset;
        var chunk_index: u32 = 0;
        var max_resolution: u32 = 0;
        var max_base_x: u32 = 0;
        var max_base_y: u32 = 0;
        while (chunk_index < n_used_chunks) : (chunk_index += 1) {
            const chunk = parseEtsChunk(data, header, &pos) catch break;
            max_resolution = @max(max_resolution, chunk.coords[n_dimensions - 1]);
            if (chunk.coords[n_dimensions - 1] == 0) {
                max_base_x = @max(max_base_x, chunk.coords[0]);
                max_base_y = @max(max_base_y, chunk.coords[1]);
            }
        }
        header.resolution_count = max_resolution + 1;
        header.padded_width = std.math.mul(u32, max_base_x + 1, tile_width) catch 0;
        header.padded_height = std.math.mul(u32, max_base_y + 1, tile_height) catch 0;
    }
    return header;
}

fn parseEtsChunk(data: []const u8, header: EtsHeader, pos: *usize) bio.ReaderError!EtsChunk {
    const coord_bytes = std.math.mul(usize, header.n_dimensions, 4) catch return error.UnsupportedVariant;
    const entry_len = std.math.add(usize, 4 + 8 + 4 + 4, coord_bytes) catch return error.UnsupportedVariant;
    if (pos.* > data.len or data.len - pos.* < entry_len) return error.TruncatedData;
    var chunk: EtsChunk = .{
        .coords = [_]u32{0} ** max_ets_dimensions,
        .offset = 0,
        .byte_count = 0,
    };
    var cursor = pos.* + 4;
    var i: usize = 0;
    while (i < header.n_dimensions) : (i += 1) {
        chunk.coords[i] = readU32Le(data[cursor..][0..4]);
        cursor += 4;
    }
    const offset_u64 = readU64Le(data[cursor..][0..8]);
    cursor += 8;
    const byte_count_u32 = readU32Le(data[cursor..][0..4]);
    cursor += 8;
    if (offset_u64 > std.math.maxInt(usize)) return error.UnsupportedVariant;
    chunk.offset = @intCast(offset_u64);
    chunk.byte_count = @intCast(byte_count_u32);
    pos.* += entry_len;
    return chunk;
}

fn isFirstPlaneChunk(chunk: EtsChunk, header: EtsHeader) bool {
    const limit = if (header.use_pyramid) header.n_dimensions - 1 else header.n_dimensions;
    var i: usize = 2;
    while (i < limit) : (i += 1) {
        if (chunk.coords[i] != 0) return false;
    }
    if (header.use_pyramid and chunk.coords[header.n_dimensions - 1] != 0) return false;
    return true;
}

fn copyChunkIntersection(
    allocator: std.mem.Allocator,
    ets: []const u8,
    chunk: EtsChunk,
    header: EtsHeader,
    region: bio.Region,
    tile_x: u32,
    tile_y: u32,
    out: []u8,
) bio.ReaderError!void {
    const bpp = header.bytesPerPixel();
    const x0 = @max(region.x, tile_x);
    const y0 = @max(region.y, tile_y);
    const x1 = @min(region.x + region.width, tile_x + header.tile_width);
    const y1 = @min(region.y + region.height, tile_y + header.tile_height);
    if (x1 <= x0 or y1 <= y0) return;

    const tile_bytes = std.math.mul(usize, std.math.mul(usize, header.tile_width, header.tile_height) catch return error.UnsupportedVariant, bpp) catch return error.UnsupportedVariant;
    if (chunk.offset > ets.len or ets.len - chunk.offset < chunk.byte_count) return error.TruncatedData;

    var decoded_tile: ?[]u8 = null;
    defer if (decoded_tile) |tile| allocator.free(tile);
    const tile_data = switch (header.compression) {
        ets_raw_compression => raw: {
            if (chunk.byte_count < tile_bytes) return error.TruncatedData;
            break :raw ets[chunk.offset..][0..tile_bytes];
        },
        ets_jpeg_compression => jpeg_tile: {
            const plane = try jpeg.readPlaneIndex(allocator, ets[chunk.offset..][0..chunk.byte_count], 0);
            decoded_tile = plane.data;
            break :jpeg_tile plane.data;
        },
        else => return error.UnsupportedVariant,
    };
    if (tile_data.len < tile_bytes) return error.TruncatedData;

    const copy_width = x1 - x0;
    const row_bytes = std.math.mul(usize, copy_width, bpp) catch return error.UnsupportedVariant;
    var row = y0;
    while (row < y1) : (row += 1) {
        const src_pixel = std.math.add(usize, std.math.mul(usize, row - tile_y, header.tile_width) catch return error.UnsupportedVariant, x0 - tile_x) catch return error.UnsupportedVariant;
        const dst_pixel = std.math.add(usize, std.math.mul(usize, row - region.y, region.width) catch return error.UnsupportedVariant, x0 - region.x) catch return error.UnsupportedVariant;
        const src = src_pixel * bpp;
        const dst = dst_pixel * bpp;
        @memcpy(out[dst..][0..row_bytes], tile_data[src..][0..row_bytes]);
    }
}

fn pixelTypeFromEts(value: u32) bio.ReaderError!bio.PixelType {
    return switch (value) {
        1 => .int8,
        2 => .uint8,
        3 => .int16,
        4 => .uint16,
        5 => .int32,
        6 => .uint32,
        9 => .float32,
        10 => .float64,
        else => error.UnsupportedVariant,
    };
}

fn findCompanionEtsPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);

    const stem = fileStem(path);
    const pixels_dir_name = try std.fmt.allocPrint(allocator, "_{s}_", .{stem});
    defer allocator.free(pixels_dir_name);
    const pixels_dir = try joinPath(allocator, parent, pixels_dir_name);
    defer allocator.free(pixels_dir);
    if (try firstFrameEtsRecursive(allocator, io, pixels_dir, 0)) |candidate| return candidate;
    if (try firstFrameEtsInDir(allocator, io, parent)) |candidate| return candidate;
    return error.FileNotFound;
}

fn firstFrameEtsRecursive(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, depth: usize) !?[]u8 {
    if (depth > 2) return null;
    if (try firstFrameEtsInDir(allocator, io, dir_path)) |candidate| return candidate;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const child = try joinPath(allocator, dir_path, entry.name);
        defer allocator.free(child);
        if (try firstFrameEtsRecursive(allocator, io, child, depth + 1)) |candidate| return candidate;
    }
    return null;
}

fn firstFrameEtsInDir(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and hasExtension(entry.name, "ets") and startsWithIgnoreCase(entry.name, "frame_")) {
            return try joinPath(allocator, dir_path, entry.name);
        }
    }
    return null;
}

fn readU32Le(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .little);
}

fn readU64Le(bytes: *const [8]u8) u64 {
    return std.mem.readInt(u64, bytes, .little);
}

fn parentPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const sep = lastSeparator(path) orelse return allocator.dupe(u8, ".");
    if (sep == 0) return allocator.dupe(u8, path[0..1]);
    return allocator.dupe(u8, path[0..sep]);
}

fn fileStem(path: []const u8) []const u8 {
    const start = if (lastSeparator(path)) |sep| sep + 1 else 0;
    const name = path[start..];
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot];
}

fn joinPath(allocator: std.mem.Allocator, left: []const u8, right: []const u8) ![]u8 {
    if (left.len == 0 or std.mem.eql(u8, left, ".")) return allocator.dupe(u8, right);
    if (std.mem.endsWith(u8, left, "/") or std.mem.endsWith(u8, left, "\\")) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ left, right });
    }
    return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ left, std.fs.path.sep, right });
}

fn lastSeparator(path: []const u8) ?usize {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    if (slash == null) return backslash;
    if (backslash == null) return slash;
    return @max(slash.?, backslash.?);
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return haystack.len >= needle.len and std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn containsCellSensMarker(data: []const u8) bool {
    const description = tiff.firstIfdAsciiTag(data, image_description_tag) orelse "";
    const software = tiff.firstIfdAsciiTag(data, software_tag) orelse "";
    return containsIgnoreCase(description, "cellsens") or containsIgnoreCase(software, "cellsens");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var pos: usize = 0;
    while (pos + needle.len <= haystack.len) : (pos += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[pos..][0..needle.len], needle)) return true;
    }
    return false;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_image_bytes));
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

fn appendU64Le(list: *std.ArrayList(u8), value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendEntry(list: *std.ArrayList(u8), tag: u16, field_type: u16, count: u32, value: u32) !void {
    try appendU16Le(list, tag);
    try appendU16Le(list, field_type);
    try appendU32Le(list, count);
    try appendU32Le(list, value);
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
    try appendEntry(list, software_tag, 2, software.len, @intCast(ifd_end));
    try appendU32Le(list, 0);
    try list.appendSlice(std.testing.allocator, software);
    try list.append(std.testing.allocator, pixel);
}

fn appendTinyEts(list: *std.ArrayList(u8), pixel: u16) !void {
    const additional_offset = 64;
    const additional_size = 228;
    const tile_offset = additional_offset + additional_size;
    const used_chunk_offset = tile_offset + 2;

    try list.appendSlice(std.testing.allocator, "SIS\x00");
    try appendU32Le(list, 64);
    try appendU32Le(list, 3);
    try appendU32Le(list, 2);
    try appendU64Le(list, additional_offset);
    try appendU32Le(list, additional_size);
    try appendU32Le(list, 0);
    try appendU64Le(list, used_chunk_offset);
    try appendU32Le(list, 1);
    try appendU32Le(list, 0);
    while (list.items.len < additional_offset) try list.append(std.testing.allocator, 0);

    try list.appendSlice(std.testing.allocator, "ETS\x00");
    try appendU32Le(list, 0x00030006);
    try appendU32Le(list, 4);
    try appendU32Le(list, 1);
    try appendU32Le(list, 1);
    try appendU32Le(list, ets_raw_compression);
    try appendU32Le(list, 100);
    try appendU32Le(list, 1);
    try appendU32Le(list, 1);
    try appendU32Le(list, 1);
    var hints: usize = 0;
    while (hints < 17) : (hints += 1) try appendU32Le(list, 0);
    try appendU16Le(list, 0);
    while (list.items.len < additional_offset + 8 + 32 + 68 + 40) try list.append(std.testing.allocator, 0);
    try appendU32Le(list, 0);
    try appendU32Le(list, 0);
    while (list.items.len < tile_offset) try list.append(std.testing.allocator, 0);
    try appendU16Le(list, pixel);

    try appendU32Le(list, 0);
    try appendU32Le(list, 0);
    try appendU32Le(list, 0);
    try appendU64Le(list, tile_offset);
    try appendU32Le(list, 2);
    try appendU32Le(list, 0);
}

test "detects cellSens tagged tiff bytes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendTinyVsi(&data, 91);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("cellsens", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("cellsens", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{91}, plane.data);
}

test "reads cellSens vsi path through tiff delegate" {
    const path = "cellsens-test.vsi";
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendTinyVsi(&data, 17);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = data.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, path);
    try std.testing.expectEqualStrings("cellsens", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, path, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("cellsens", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{17}, plane.data);
}

test "reads cellSens raw ets companion through vsi path" {
    const root = "cellsens-ets-fixture";
    const vsi_path = "cellsens-ets-fixture/cellsens-ets-test.vsi";
    const ets_path = "cellsens-ets-fixture/frame_t_0.ets";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);

    var vsi: std.ArrayList(u8) = .empty;
    defer vsi.deinit(std.testing.allocator);
    try appendTinyVsi(&vsi, 17);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = vsi_path, .data = vsi.items });

    var ets: std.ArrayList(u8) = .empty;
    defer ets.deinit(std.testing.allocator);
    try appendTinyEts(&ets, 0x1234);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = ets_path, .data = ets.items });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, vsi_path);
    try std.testing.expectEqualStrings("cellsens", metadata.format);
    try std.testing.expectEqual(.uint16, metadata.pixel_type);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, vsi_path, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, plane.data);
}

test "matches Bio-Formats core metadata for cached CellSens fixture" {
    const file_path = "fixtures/cache/cellsens/Image_V4.1_BF.vsi";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    try std.testing.expectEqualStrings("cellsens", metadata.format);
    try std.testing.expectEqual(@as(u32, 8042), metadata.width);
    try std.testing.expectEqual(@as(u32, 9403), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 7), metadata.series_count);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{
        .x = 0,
        .y = 0,
        .width = 16,
        .height = 16,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(usize, 16 * 16 * 3), plane.data.len);
}
