const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

pub fn matches(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "LMSDataContainerHeader") != null and
        (hasElement(data, "Reference") or hasElement(data, "Frame"));
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "xlef") or hasExtension(path, "xlif");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    _ = data;
    return error.InvalidFormat;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.InvalidFormat;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const image_path = try firstImagePath(allocator, io, path);
    defer allocator.free(image_path);
    const image = try readFile(allocator, io, image_path);
    defer allocator.free(image);
    var metadata = try bio.readMetadata(image);
    metadata.format = "xlef";
    metadata.image_description = null;
    if (metadata.dimension_order == null) metadata.dimension_order = "XYCZT";
    return metadata;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const image_path = try firstImagePath(allocator, io, path);
    defer allocator.free(image_path);
    const image = try readFile(allocator, io, image_path);
    defer allocator.free(image);
    var plane = try bio.readPlaneRegionIndex(allocator, image, plane_index, region);
    if (plane.metadata.samples_per_pixel > 1) {
        plane.data = try interleavedToPlanar(allocator, plane.data, plane.metadata);
    }
    plane.metadata.format = "xlef";
    plane.metadata.image_description = null;
    if (plane.metadata.dimension_order == null) plane.metadata.dimension_order = "XYCZT";
    return plane;
}

fn firstImagePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const xml = try readFile(allocator, io, path);
    defer allocator.free(xml);
    if (!matches(xml)) return error.InvalidFormat;
    if (hasExtension(path, "xlif")) {
        return framePathFromXlif(allocator, path, xml);
    }

    var pos: usize = 0;
    while (nextAttrValue(xml, "Reference", "File", &pos)) |ref_value| {
        const xlif_path = try resolveReference(allocator, path, ref_value);
        defer allocator.free(xlif_path);
        if (!hasExtension(xlif_path, "xlif")) continue;
        const xlif = readFile(allocator, io, xlif_path) catch continue;
        defer allocator.free(xlif);
        const image_path = framePathFromXlif(allocator, xlif_path, xlif) catch continue;
        const image = readFile(allocator, io, image_path) catch {
            allocator.free(image_path);
            continue;
        };
        allocator.free(image);
        return image_path;
    }
    return error.InvalidFormat;
}

fn framePathFromXlif(allocator: std.mem.Allocator, xlif_path: []const u8, xlif: []const u8) ![]u8 {
    var pos: usize = 0;
    while (nextAttrValue(xlif, "Frame", "File", &pos)) |frame_value| {
        const image_path = try resolveReference(allocator, xlif_path, frame_value);
        if (hasReadableFrameExtension(image_path)) return image_path;
        allocator.free(image_path);
    }
    return error.InvalidFormat;
}

fn nextAttrValue(xml: []const u8, element: []const u8, attr: []const u8, pos: *usize) ?[]const u8 {
    while (pos.* < xml.len) {
        const tag_start = std.mem.indexOfScalarPos(u8, xml, pos.*, '<') orelse return null;
        const name_start = tag_start + 1;
        pos.* = name_start;
        if (name_start >= xml.len or xml[name_start] == '/' or xml[name_start] == '!' or xml[name_start] == '?') continue;
        const tag_name = tagName(xml, name_start) orelse continue;
        const tag_end = std.mem.indexOfScalarPos(u8, xml, name_start + tag_name.len, '>') orelse return null;
        pos.* = tag_end + 1;
        if (!std.mem.eql(u8, localName(tag_name), element)) continue;
        const tag = xml[tag_start..tag_end];
        if (attributeValue(tag, attr)) |value| return value;
    }
    return null;
}

fn hasElement(xml: []const u8, element: []const u8) bool {
    var pos: usize = 0;
    while (pos < xml.len) {
        const tag_start = std.mem.indexOfScalarPos(u8, xml, pos, '<') orelse return false;
        const name_start = tag_start + 1;
        pos = name_start;
        if (name_start >= xml.len or xml[name_start] == '/' or xml[name_start] == '!' or xml[name_start] == '?') continue;
        const tag_name = tagName(xml, name_start) orelse continue;
        if (std.mem.eql(u8, localName(tag_name), element)) return true;
        pos = name_start + tag_name.len;
    }
    return false;
}

fn tagName(data: []const u8, start: usize) ?[]const u8 {
    var end = start;
    while (end < data.len and !std.ascii.isWhitespace(data[end]) and data[end] != '>' and data[end] != '/') : (end += 1) {}
    if (end == start) return null;
    return data[start..end];
}

fn localName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, ':')) |colon| {
        return name[colon + 1 ..];
    }
    return name;
}

fn attributeValue(tag: []const u8, attr: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < tag.len) {
        const found = std.mem.indexOfPos(u8, tag, pos, attr) orelse return null;
        const after_name = found + attr.len;
        if (found > 0 and (std.ascii.isAlphanumeric(tag[found - 1]) or tag[found - 1] == '_' or tag[found - 1] == ':')) {
            pos = after_name;
            continue;
        }
        var eq = after_name;
        while (eq < tag.len and std.ascii.isWhitespace(tag[eq])) : (eq += 1) {}
        if (eq >= tag.len or tag[eq] != '=') {
            pos = after_name;
            continue;
        }
        eq += 1;
        while (eq < tag.len and std.ascii.isWhitespace(tag[eq])) : (eq += 1) {}
        if (eq >= tag.len or (tag[eq] != '"' and tag[eq] != '\'')) return null;
        const quote = tag[eq];
        const value_start = eq + 1;
        const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, quote) orelse return null;
        return tag[value_start..value_end];
    }
    return null;
}

fn resolveReference(allocator: std.mem.Allocator, base_path: []const u8, encoded_ref: []const u8) ![]u8 {
    const decoded = try decodePathValue(allocator, encoded_ref);
    defer allocator.free(decoded);
    const dir = dirname(base_path);
    const joined = if (dir.len == 0)
        try allocator.dupe(u8, decoded)
    else blk: {
        const out = try allocator.alloc(u8, dir.len + 1 + decoded.len);
        @memcpy(out[0..dir.len], dir);
        out[dir.len] = '/';
        @memcpy(out[dir.len + 1 ..], decoded);
        break :blk out;
    };
    defer allocator.free(joined);
    return normalizePath(allocator, joined);
}

fn decodePathValue(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '&') {
            if (std.mem.startsWith(u8, encoded[i..], "&amp;")) {
                try out.append(allocator, '&');
                i += "&amp;".len;
                continue;
            }
            if (std.mem.startsWith(u8, encoded[i..], "&quot;")) {
                try out.append(allocator, '"');
                i += "&quot;".len;
                continue;
            }
            if (std.mem.startsWith(u8, encoded[i..], "&apos;")) {
                try out.append(allocator, '\'');
                i += "&apos;".len;
                continue;
            }
            if (std.mem.startsWith(u8, encoded[i..], "&lt;")) {
                try out.append(allocator, '<');
                i += "&lt;".len;
                continue;
            }
            if (std.mem.startsWith(u8, encoded[i..], "&gt;")) {
                try out.append(allocator, '>');
                i += "&gt;".len;
                continue;
            }
        }
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

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var absolute_prefix: []const u8 = "";
    var rest = path;
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\')) {
        absolute_prefix = path[0..3];
        rest = path[3..];
    } else if (path.len > 0 and (path[0] == '/' or path[0] == '\\')) {
        absolute_prefix = path[0..1];
        rest = path[1..];
    }

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var iter = std.mem.splitScalar(u8, rest, '/');
    while (iter.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
            } else if (absolute_prefix.len == 0) {
                try parts.append(allocator, part);
            }
        } else {
            try parts.append(allocator, part);
        }
    }

    var len = absolute_prefix.len;
    for (parts.items, 0..) |part, i| {
        if (i > 0 or (absolute_prefix.len > 0 and absolute_prefix[absolute_prefix.len - 1] != '/')) len += 1;
        len += part.len;
    }
    if (len == 0) return allocator.dupe(u8, ".");
    const out = try allocator.alloc(u8, len);
    var pos: usize = 0;
    @memcpy(out[0..absolute_prefix.len], absolute_prefix);
    pos += absolute_prefix.len;
    for (parts.items, 0..) |part, i| {
        if (i > 0 or (absolute_prefix.len > 0 and absolute_prefix[absolute_prefix.len - 1] != '/')) {
            out[pos] = '/';
            pos += 1;
        }
        @memcpy(out[pos..][0..part.len], part);
        pos += part.len;
    }
    return out;
}

fn dirname(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return "";
    return path[0..slash];
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn hasReadableFrameExtension(path: []const u8) bool {
    return hasExtension(path, "tif") or hasExtension(path, "tiff") or
        hasExtension(path, "jpg") or hasExtension(path, "jpeg") or
        hasExtension(path, "png") or hasExtension(path, "bmp");
}

fn interleavedToPlanar(allocator: std.mem.Allocator, data: []u8, metadata: bio.Metadata) ![]u8 {
    const samples: usize = metadata.samples_per_pixel;
    const bytes_per_sample = metadata.pixel_type.bytesPerSample();
    if (samples <= 1 or bytes_per_sample == 0) return data;
    const pixel_bytes = samples * bytes_per_sample;
    if (data.len % pixel_bytes != 0) return data;
    const pixels = data.len / pixel_bytes;
    const planar = try allocator.alloc(u8, data.len);
    errdefer allocator.free(planar);
    var pixel: usize = 0;
    while (pixel < pixels) : (pixel += 1) {
        var sample: usize = 0;
        while (sample < samples) : (sample += 1) {
            const src = pixel * pixel_bytes + sample * bytes_per_sample;
            const dst = sample * pixels * bytes_per_sample + pixel * bytes_per_sample;
            @memcpy(planar[dst..][0..bytes_per_sample], data[src..][0..bytes_per_sample]);
        }
    }
    allocator.free(data);
    return planar;
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
    0,   0,   82,
};

const tiny_bmp = [_]u8{
    'B',  'M',
    58,   0,   0, 0,
    0,    0,   0, 0,
    54,   0,   0, 0,
    40,   0,   0, 0,
    1,    0,   0, 0,
    1,    0,   0, 0,
    1,    0,
    24,   0,
    0,    0,   0, 0,
    4,    0,   0, 0,
    0,    0,   0, 0,
    0,    0,   0, 0,
    0,    0,   0, 0,
    0,    0,   0, 0,
    0,    0, 255, 0,
};

test "reads xlef metadata through first xlif tiff frame" {
    const root = "xlef-test";
    const metadata_dir = "xlef-test/metadata";
    const xlef_path = "xlef-test/project.xlef";
    const xlif_path = "xlef-test/metadata/first.xlif";
    const image_path = "xlef-test/image.tif";
    std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, xlif_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, xlef_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, metadata_dir) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, metadata_dir, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, metadata_dir) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = &tiny_tiff });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = xlif_path, .data = "<LMS:LMSDataContainerHeader xmlns:LMS=\"urn:test\"><LMS:Element><LMS:Memory><LMS:Frame File = '..%5Cimage.tif' /></LMS:Memory></LMS:Element></LMS:LMSDataContainerHeader>" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, xlif_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = xlef_path, .data = "<LMS:LMSDataContainerHeader xmlns:LMS=\"urn:test\"><LMS:Element><LMS:Children><LMS:Reference File = '.%5Cmetadata%5Cfirst.xlif' /></LMS:Children></LMS:Element></LMS:LMSDataContainerHeader>" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, xlef_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, xlef_path);
    try std.testing.expectEqualStrings("xlef", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, xlef_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("xlef", plane.metadata.format);
    try std.testing.expectEqualStrings("XYCZT", plane.metadata.dimension_order.?);
    try std.testing.expectEqualSlices(u8, &.{82}, plane.data);
}

test "reads xlef metadata through xlif jpeg frame" {
    const root = "xlef-jpeg-test";
    const metadata_dir = "xlef-jpeg-test/metadata";
    const xlif_path = "xlef-jpeg-test/metadata/first.xlif";
    const image_path = "xlef-jpeg-test/image.jpg";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, metadata_dir, .default_dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = &bio.jpeg.baseline_red_jpeg });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = xlif_path, .data = "<LMSDataContainerHeader><Element><Memory><Frame File=\"..%5Cimage.jpg\" /></Memory></Element></LMSDataContainerHeader>" });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, xlif_path);
    try std.testing.expectEqualStrings("xlef", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, xlif_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("xlef", plane.metadata.format);
    try std.testing.expect(plane.data[0] > 200);
    try std.testing.expect(plane.data[1] < 80);
    try std.testing.expect(plane.data[2] < 80);
}

test "reads xlef metadata through xlif bmp frame" {
    const root = "xlef-bmp-test";
    const metadata_dir = "xlef-bmp-test/metadata";
    const xlif_path = "xlef-bmp-test/metadata/first.xlif";
    const image_path = "xlef-bmp-test/image.bmp";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, metadata_dir, .default_dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = &tiny_bmp });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = xlif_path, .data = "<LMSDataContainerHeader><Element><Memory><Frame File=\"..%5Cimage.bmp\" /></Memory></Element></LMSDataContainerHeader>" });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, xlif_path);
    try std.testing.expectEqualStrings("xlef", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, xlif_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("xlef", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0 }, plane.data);
}

test "reads xlef frame path with xml entity escaping" {
    const root = "xlef-entity-test";
    const xlif_path = "xlef-entity-test/first.xlif";
    const image_path = "xlef-entity-test/a&b.tif";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = &tiny_tiff });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = xlif_path, .data = "<LMSDataContainerHeader><Element><Memory><Frame File=\"a&amp;b.tif\" /></Memory></Element></LMSDataContainerHeader>" });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, xlif_path);
    try std.testing.expectEqualStrings("xlef", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
}

test "matches Bio-Formats core metadata for cached XLEF fixture" {
    const file_path = "fixtures/cache/xlef/format-test tif.xlef";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    try std.testing.expectEqualStrings("xlef", metadata.format);
    try std.testing.expectEqual(@as(u32, 1600), metadata.width);
    try std.testing.expectEqual(@as(u32, 1200), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
}

test "matches Bio-Formats plane and region hashes for cached XLEF fixture" {
    const file_path = "fixtures/cache/xlef/format-test tif.xlef";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{
        .x = 0,
        .y = 0,
        .width = 1600,
        .height = 1200,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(usize, 5_760_000), plane.data.len);
    const expected_plane: [32]u8 = .{ 0x82, 0xad, 0x2b, 0x89, 0x00, 0x30, 0x2b, 0x52, 0xd3, 0x4a, 0x8e, 0x16, 0x14, 0xd6, 0x51, 0x17, 0x05, 0x71, 0xdb, 0x2f, 0x57, 0xbb, 0xb5, 0x84, 0xf7, 0x4a, 0xb3, 0x29, 0xd4, 0xea, 0x37, 0x45 };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_plane, &digest);

    const region = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{
        .x = 17,
        .y = 19,
        .width = 16,
        .height = 12,
    });
    defer std.testing.allocator.free(region.data);
    try std.testing.expectEqual(@as(usize, 576), region.data.len);
    const expected_region: [32]u8 = .{ 0xe7, 0xd4, 0x0c, 0x85, 0x9a, 0x5f, 0x44, 0xe5, 0x3f, 0xca, 0xd4, 0x5c, 0x2a, 0xfa, 0x75, 0xdd, 0xd8, 0x3a, 0x11, 0x3d, 0x4c, 0xbd, 0x1b, 0x32, 0x5d, 0xc9, 0xa2, 0x13, 0xf1, 0xb6, 0x56, 0x23 };
    std.crypto.hash.sha2.Sha256.hash(region.data, &digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_region, &digest);
}
