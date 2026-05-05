const std = @import("std");
const bio = @import("../root.zig");

const magic = "SpimData";
const max_metadata_bytes = 64 * 1024 * 1024;
const max_image_bytes = 512 * 1024 * 1024;
const hdf5_signature = "\x89HDF\r\n\x1a\n";

const Dimensions = struct {
    width: u32,
    height: u32,
    size_z: u16,
};

const Dataset = struct {
    size_z: u16,
    height: u32,
    width: u32,
    data_offset: usize,
    data_size: usize,
};

pub fn matches(data: []const u8) bool {
    const probe = data[0..@min(data.len, 100)];
    return std.mem.indexOf(u8, probe, magic) != null;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "xml") or hasExtension(path, "h5");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    return metadataFromXml(data);
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    if (!isPath(path)) return error.InvalidFormat;
    const xml_path = if (hasExtension(path, "h5")) try siblingXmlPath(allocator, path) else try allocator.dupe(u8, path);
    defer allocator.free(xml_path);

    const xml = try std.Io.Dir.cwd().readFileAlloc(io, xml_path, allocator, .limited(max_metadata_bytes));
    defer allocator.free(xml);
    return metadataFromXml(xml);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    if (!isPath(path)) return error.InvalidFormat;
    const xml_path = if (hasExtension(path, "h5")) try siblingXmlPath(allocator, path) else try allocator.dupe(u8, path);
    defer allocator.free(xml_path);

    const xml = try std.Io.Dir.cwd().readFileAlloc(io, xml_path, allocator, .limited(max_metadata_bytes));
    defer allocator.free(xml);
    const metadata = try metadataFromXml(xml);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;

    const h5_name = tagText(xml, "hdf5") orelse return error.InvalidFormat;
    const parent = try parentPath(allocator, xml_path);
    defer allocator.free(parent);
    const h5_path = try joinPath(allocator, parent, std.mem.trim(u8, h5_name, " \t\r\n"));
    defer allocator.free(h5_path);
    const h5 = try std.Io.Dir.cwd().readFileAlloc(io, h5_path, allocator, .limited(max_image_bytes));
    defer allocator.free(h5);

    const zct = try planeToZct(metadata, plane_index);
    const dataset_index = std.math.add(usize, std.math.mul(usize, zct.t, metadata.size_c) catch return error.UnsupportedVariant, zct.c) catch return error.UnsupportedVariant;
    const dataset = findDataset(h5, metadata, dataset_index) orelse return error.UnsupportedVariant;
    const plane_len = try planeByteCount(metadata);
    const z_offset = std.math.mul(usize, zct.z, plane_len) catch return error.UnsupportedVariant;
    if (z_offset + plane_len > dataset.data_size) return error.TruncatedData;
    const offset = dataset.data_offset + z_offset;
    if (offset + plane_len > h5.len) return error.TruncatedData;
    const full = try allocator.dupe(u8, h5[offset..][0..plane_len]);
    errdefer allocator.free(full);
    const plane: bio.Plane = .{ .metadata = metadata, .data = full };
    try region.validate(metadata);
    if (region.isFull(metadata)) return plane;
    defer allocator.free(full);
    return .{ .metadata = metadata, .data = try bio.cropPlane(allocator, plane, region) };
}

fn metadataFromXml(xml: []const u8) bio.ReaderError!bio.Metadata {
    if (std.mem.indexOf(u8, xml, magic) == null) return error.InvalidFormat;
    if (std.mem.indexOf(u8, xml, "<ViewSetup") == null) return error.InvalidFormat;

    const dims = try firstViewSetupDimensions(xml);
    const size_c = boundedU16(@max(countUniqueChannels(xml), 1));
    const size_t = try parseTimepoints(xml);
    const zc = std.math.mul(u32, dims.size_z, size_c) catch return error.UnsupportedVariant;

    return .{
        .format = "bdv",
        .width = dims.width,
        .height = dims.height,
        .size_c = size_c,
        .samples_per_pixel = 1,
        .size_z = dims.size_z,
        .size_t = size_t,
        .pixel_type = .uint16,
        .little_endian = true,
        .plane_count = std.math.mul(u32, zc, size_t) catch return error.UnsupportedVariant,
        .dimension_order = "XYZCT",
    };
}

fn firstViewSetupDimensions(xml: []const u8) bio.ReaderError!Dimensions {
    const section = firstSection(xml, "ViewSetup") orelse return error.InvalidFormat;
    const size_text = tagText(section, "size") orelse return error.InvalidFormat;
    const values = try parseSizeTriple(size_text);
    if (values[0] == 0 or values[1] == 0 or values[2] == 0) return error.InvalidFormat;
    return .{ .width = values[0], .height = values[1], .size_z = boundedU16(values[2]) };
}

fn parseTimepoints(xml: []const u8) bio.ReaderError!u16 {
    if (tagText(xml, "integerpattern")) |pattern_text| {
        return parseIntegerPattern(pattern_text);
    }

    const first = parseTagUnsigned(xml, "first") orelse return 1;
    var last = parseTagUnsigned(xml, "last") orelse first;
    if (last == 0) last = first;
    if (last < first) return error.InvalidFormat;
    return boundedU16(last - first + 1);
}

fn parseIntegerPattern(text: []const u8) bio.ReaderError!u16 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const dash = std.mem.indexOfScalar(u8, trimmed, '-') orelse {
        const single = std.fmt.parseUnsigned(u32, trimmed, 10) catch return error.InvalidFormat;
        _ = single;
        return 1;
    };
    const tail = trimmed[dash + 1 ..];
    const colon = std.mem.indexOfScalar(u8, tail, ':');
    const first = std.fmt.parseUnsigned(u32, std.mem.trim(u8, trimmed[0..dash], " \t\r\n"), 10) catch return error.InvalidFormat;
    const last_text = if (colon) |index| tail[0..index] else tail;
    const last = std.fmt.parseUnsigned(u32, std.mem.trim(u8, last_text, " \t\r\n"), 10) catch return error.InvalidFormat;
    if (last < first) return error.InvalidFormat;

    var count = last - first + 1;
    if (colon) |index| {
        const increment = std.fmt.parseUnsigned(u32, std.mem.trim(u8, tail[index + 1 ..], " \t\r\n"), 10) catch return error.InvalidFormat;
        if (increment > 0) count /= increment;
    }
    return boundedU16(@max(count, 1));
}

fn countUniqueChannels(xml: []const u8) u32 {
    var channels: [64]u32 = undefined;
    var channel_count: u32 = 0;
    var view_setup_count: u32 = 0;
    var pos: usize = 0;

    while (nextSection(xml, "ViewSetup", pos)) |section_info| {
        view_setup_count += 1;
        const section = xml[section_info.start..section_info.end];
        if (tagText(section, "attributes")) |attributes| {
            if (parseTagUnsigned(attributes, "channel")) |channel| {
                var seen = false;
                for (channels[0..channel_count]) |existing| {
                    if (existing == channel) {
                        seen = true;
                        break;
                    }
                }
                if (!seen and channel_count < channels.len) {
                    channels[channel_count] = channel;
                    channel_count += 1;
                }
            }
        }
        pos = section_info.end;
    }

    if (channel_count > 0) return channel_count;
    return view_setup_count;
}

const Section = struct {
    start: usize,
    end: usize,
};

fn firstSection(xml: []const u8, tag: []const u8) ?[]const u8 {
    const section = nextSection(xml, tag, 0) orelse return null;
    return xml[section.start..section.end];
}

fn nextSection(xml: []const u8, tag: []const u8, start_pos: usize) ?Section {
    var open_buf: [64]u8 = undefined;
    var close_buf: [68]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}", .{tag}) catch return null;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
    const start = findOpenTag(xml, open, start_pos) orelse return null;
    const open_end = std.mem.indexOfScalarPos(u8, xml, start, '>') orelse return null;
    const close_start = std.mem.indexOfPos(u8, xml, open_end + 1, close) orelse return null;
    return .{ .start = open_end + 1, .end = close_start };
}

fn findOpenTag(xml: []const u8, open: []const u8, start_pos: usize) ?usize {
    var pos = start_pos;
    while (std.mem.indexOfPos(u8, xml, pos, open)) |found| {
        const after = found + open.len;
        if (after >= xml.len or xml[after] == '>' or xml[after] == '/' or std.ascii.isWhitespace(xml[after])) return found;
        pos = after;
    }
    return null;
}

fn tagText(xml: []const u8, tag: []const u8) ?[]const u8 {
    return firstSection(xml, tag);
}

fn parseTagUnsigned(xml: []const u8, tag: []const u8) ?u32 {
    const text = tagText(xml, tag) orelse return null;
    return std.fmt.parseUnsigned(u32, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

fn parseSizeTriple(text: []const u8) bio.ReaderError![3]u32 {
    var values: [3]u32 = .{ 0, 0, 0 };
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        while (pos < text.len and std.ascii.isWhitespace(text[pos])) : (pos += 1) {}
        if (pos >= text.len) break;
        const start = pos;
        while (pos < text.len and !std.ascii.isWhitespace(text[pos])) : (pos += 1) {}
        if (count >= values.len) break;
        values[count] = std.fmt.parseUnsigned(u32, text[start..pos], 10) catch return error.InvalidFormat;
        count += 1;
    }
    if (count != values.len) return error.InvalidFormat;
    return values;
}

const Zct = struct {
    z: usize,
    c: usize,
    t: usize,
};

fn planeToZct(metadata: bio.Metadata, plane_index: u32) bio.ReaderError!Zct {
    const zc = std.math.mul(u32, metadata.size_z, metadata.size_c) catch return error.InvalidPlaneIndex;
    return .{
        .z = plane_index % metadata.size_z,
        .c = (plane_index / metadata.size_z) % metadata.size_c,
        .t = plane_index / zc,
    };
}

fn findDataset(data: []const u8, metadata: bio.Metadata, target_index: usize) ?Dataset {
    if (data.len < hdf5_signature.len or !std.mem.eql(u8, data[0..hdf5_signature.len], hdf5_signature)) return null;
    var seen: usize = 0;
    var offset: usize = 0;
    while (offset + 64 <= data.len) : (offset += 1) {
        const dataset = parseObjectHeaderForZyx(data, offset) orelse continue;
        if (dataset.width != metadata.width or dataset.height != metadata.height or dataset.size_z != metadata.size_z) continue;
        const expected_stack = std.math.mul(usize, planeByteCount(metadata) catch return null, metadata.size_z) catch return null;
        if (dataset.data_size < expected_stack) continue;
        if (seen == target_index) return dataset;
        seen += 1;
    }
    return null;
}

fn parseObjectHeaderForZyx(data: []const u8, offset: usize) ?Dataset {
    if (data[offset] != 1 or data[offset + 1] != 0) return null;
    const message_count = readU16(data, offset + 2);
    if (message_count == 0 or message_count > 32) return null;
    const ref_count = readU32(data, offset + 4);
    const header_size = readU32(data, offset + 8);
    if (ref_count == 0 or header_size == 0 or header_size > 4096) return null;

    var dims: ?[3]u64 = null;
    var element_size: ?u8 = null;
    var data_offset: ?usize = null;
    var data_size: ?usize = null;
    var has_filter_pipeline = false;
    var pos = offset + 16;
    var i: u16 = 0;
    while (i < message_count) : (i += 1) {
        if (pos + 8 > data.len) return null;
        const message_type = readU16(data, pos);
        const message_size = readU16(data, pos + 2);
        const payload = pos + 8;
        const end = payload + @as(usize, message_size);
        if (end > data.len) return null;
        if (message_type == 1) {
            dims = parseDataspaceMessage(data[payload..end]);
        } else if (message_type == 3 and message_size >= 4) {
            const size = data[payload + 3];
            if (size == 1 or size == 2 or size == 4) element_size = size;
        } else if (message_type == 8) {
            if (parseContiguousLayoutMessage(data[payload..end])) |layout| {
                data_offset = layout.offset;
                data_size = layout.size;
            }
        } else if (message_type == 11) {
            has_filter_pipeline = true;
        }
        pos = end;
        const relative = pos - offset;
        if (relative % 8 != 0) pos += 8 - (relative % 8);
    }
    if (has_filter_pipeline or (element_size orelse 2) != 2) return null;
    const shape = dims orelse return null;
    if (shape[0] > std.math.maxInt(u16) or shape[1] > std.math.maxInt(u32) or shape[2] > std.math.maxInt(u32)) return null;
    return .{
        .size_z = @intCast(shape[0]),
        .height = @intCast(shape[1]),
        .width = @intCast(shape[2]),
        .data_offset = data_offset orelse return null,
        .data_size = data_size orelse return null,
    };
}

fn parseDataspaceMessage(payload: []const u8) ?[3]u64 {
    if (payload.len < 8) return null;
    const version = payload[0];
    const rank = payload[1];
    if ((version != 1 and version != 2) or rank != 3) return null;
    var dims: [3]u64 = undefined;
    var pos: usize = 8;
    for (&dims) |*dim| {
        if (pos + 8 > payload.len) return null;
        dim.* = std.mem.readInt(u64, payload[pos..][0..8], .little);
        if (dim.* == 0 or dim.* > 1_000_000) return null;
        pos += 8;
    }
    return dims;
}

const Layout = struct {
    offset: usize,
    size: usize,
};

fn parseContiguousLayoutMessage(payload: []const u8) ?Layout {
    if (payload.len < 18 or payload[0] != 3 or payload[1] != 1) return null;
    const offset = std.mem.readInt(u64, payload[2..][0..8], .little);
    const size = std.mem.readInt(u64, payload[10..][0..8], .little);
    if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize) or size == 0) return null;
    return .{ .offset = @intCast(offset), .size = @intCast(size) };
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn readU16(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn siblingXmlPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return error.InvalidFormat;
    const out = try allocator.alloc(u8, dot + 4);
    @memcpy(out[0..dot], path[0..dot]);
    @memcpy(out[dot..], ".xml");
    return out;
}

fn parentPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const sep = lastSeparator(path) orelse return allocator.dupe(u8, ".");
    if (sep == 0) return allocator.dupe(u8, path[0..1]);
    return allocator.dupe(u8, path[0..sep]);
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    if (isAbsolutePath(name)) return allocator.dupe(u8, name);
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

fn isAbsolutePath(path: []const u8) bool {
    if (path.len >= 1 and (path[0] == '/' or path[0] == '\\')) return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn boundedU16(value: u32) u16 {
    return @intCast(@min(@max(value, 1), std.math.maxInt(u16)));
}

fn appendObjectHeaderWithLayout(list: *std.ArrayList(u8), allocator: std.mem.Allocator, data_offset: usize, data_size: usize) !void {
    try list.appendSlice(allocator, &.{
        1,   0, 3,  0,
        1,   0, 0,  0,
        128, 0, 0,  0,
        0,   0, 0,  0,
        1,   0, 56, 0,
        0,   0, 0,  0,
        1,   3, 1,  0,
        0,   0, 0,  0,
    });
    for ([_]u64{ 2, 2, 3 }) |value| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try list.appendSlice(allocator, &bytes);
    }
    for ([_]u64{ 2, 2, 3 }) |value| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try list.appendSlice(allocator, &bytes);
    }
    try list.appendSlice(allocator, &.{
        3, 0, 8,  0,
        0, 0, 0,  0,
        1, 3, 0,  2,
        0, 0, 0,  0,
        8, 0, 24, 0,
        0, 0, 0,  0,
        3, 1,
    });
    var offset_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &offset_bytes, @intCast(data_offset), .little);
    try list.appendSlice(allocator, &offset_bytes);
    var size_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &size_bytes, @intCast(data_size), .little);
    try list.appendSlice(allocator, &size_bytes);
    try list.appendNTimes(allocator, 0, 6);
}

const sample_xml =
    \\<SpimData version="0.2">
    \\  <SequenceDescription>
    \\    <ImageLoader format="bdv.hdf5"><hdf5 type="relative">sample.h5</hdf5></ImageLoader>
    \\    <ViewSetups>
    \\      <ViewSetup>
    \\        <id>0</id><name>channel 0</name><size>11 7 3</size>
    \\        <voxelSize><unit>micrometer</unit><size>1 1 2</size></voxelSize>
    \\        <attributes><channel>0</channel></attributes>
    \\      </ViewSetup>
    \\      <ViewSetup>
    \\        <id>1</id><name>channel 1</name><size>11 7 3</size>
    \\        <attributes><channel>1</channel></attributes>
    \\      </ViewSetup>
    \\    </ViewSetups>
    \\    <Timepoints type="range"><first>0</first><last>4</last></Timepoints>
    \\  </SequenceDescription>
    \\</SpimData>
;

test "reads bdv xml metadata" {
    try std.testing.expect(matches(sample_xml));
    const metadata = try readMetadata(sample_xml);
    try std.testing.expectEqualStrings("bdv", metadata.format);
    try std.testing.expectEqual(@as(u32, 11), metadata.width);
    try std.testing.expectEqual(@as(u32, 7), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 5), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 30), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, sample_xml, 0));
}

test "reads bdv integer pattern timepoints" {
    const xml =
        \\<SpimData>
        \\  <SequenceDescription>
        \\    <ViewSetups><ViewSetup><size>5 4 2</size></ViewSetup></ViewSetups>
        \\    <Timepoints type="pattern"><integerpattern>0-5:2</integerpattern></Timepoints>
        \\  </SequenceDescription>
        \\</SpimData>
    ;
    const metadata = try readMetadata(xml);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_t);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(@as(u32, 6), metadata.plane_count);
}

test "reads h5 path through sibling bdv xml" {
    const dir_path = "bdv-path-test";
    const xml_path = "bdv-path-test/sample.xml";
    const h5_path = "bdv-path-test/sample.h5";
    std.Io.Dir.cwd().deleteFile(std.testing.io, xml_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, h5_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, dir_path) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir_path, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, dir_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = xml_path, .data = sample_xml });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, xml_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = h5_path, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, h5_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, h5_path);
    try std.testing.expectEqualStrings("bdv", metadata.format);
    try std.testing.expectEqual(@as(u32, 11), metadata.width);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
}

test "reads bdv contiguous hdf5 plane through xml path" {
    const dir_path = "bdv-plane-test";
    const xml_path = "bdv-plane-test/sample.xml";
    const h5_path = "bdv-plane-test/sample.h5";
    std.Io.Dir.cwd().deleteFile(std.testing.io, xml_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, h5_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, dir_path) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir_path, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, dir_path) catch {};

    const xml =
        \\<SpimData>
        \\  <SequenceDescription>
        \\    <ImageLoader format="bdv.hdf5"><hdf5 type="relative">sample.h5</hdf5></ImageLoader>
        \\    <ViewSetups><ViewSetup><size>3 2 2</size></ViewSetup></ViewSetups>
        \\    <Timepoints type="range"><first>0</first><last>0</last></Timepoints>
        \\  </SequenceDescription>
        \\</SpimData>
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = xml_path, .data = xml });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, xml_path) catch {};

    var h5: std.ArrayList(u8) = .empty;
    defer h5.deinit(std.testing.allocator);
    try h5.appendSlice(std.testing.allocator, hdf5_signature);
    try h5.appendNTimes(std.testing.allocator, 0, 32);
    const raw_offset = h5.items.len + 128;
    try appendObjectHeaderWithLayout(&h5, std.testing.allocator, raw_offset, 24);
    try h5.appendSlice(std.testing.allocator, &.{
        1,  0, 2,  0, 3,  0,
        4,  0, 5,  0, 6,  0,
        11, 0, 12, 0, 13, 0,
        14, 0, 15, 0, 16, 0,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = h5_path, .data = h5.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, h5_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, xml_path, 1, .{ .x = 1, .y = 0, .width = 2, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("bdv", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 12, 0, 13, 0 }, plane.data);
}

test "rejects non-bdv xml" {
    try std.testing.expect(!matches("<OME></OME>"));
    try std.testing.expectError(error.InvalidFormat, readMetadata("<OME></OME>"));
}
