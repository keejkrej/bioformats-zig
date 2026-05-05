const std = @import("std");
const bio = @import("../root.zig");

const magic = "SpimData";
const max_metadata_bytes = 64 * 1024 * 1024;

const Dimensions = struct {
    width: u32,
    height: u32,
    size_z: u16,
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

fn siblingXmlPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return error.InvalidFormat;
    const out = try allocator.alloc(u8, dot + 4);
    @memcpy(out[0..dot], path[0..dot]);
    @memcpy(out[dot..], ".xml");
    return out;
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn boundedU16(value: u32) u16 {
    return @intCast(@min(@max(value, 1), std.math.maxInt(u16)));
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

test "rejects non-bdv xml" {
    try std.testing.expect(!matches("<OME></OME>"));
    try std.testing.expectError(error.InvalidFormat, readMetadata("<OME></OME>"));
}
