const std = @import("std");
const bio = @import("../root.zig");

const identifier = "OLYMPUSRAWFORMAT";

const Scan = struct {
    width: u32 = 0,
    height: u32 = 0,
    size_c: u16 = 1,
    samples: u16 = 1,
    size_z: u16 = 1,
    size_t: u16 = 1,
    lambda_size: u16 = 1,
    pixel_type: bio.PixelType = .uint8,
};

pub fn matches(data: []const u8) bool {
    _ = readMetadata(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (data.len < identifier.len) return error.TruncatedData;
    if (!std.mem.eql(u8, data[0..identifier.len], identifier)) return error.InvalidFormat;
    var scan = Scan{};
    var found_xml = false;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, data, pos, "<?xml")) |xml_start| {
        const xml_end = findXmlEnd(data, xml_start);
        if (xml_end <= xml_start) break;
        try parseXml(data[xml_start..xml_end], &scan);
        found_xml = true;
        pos = xml_end;
    }
    applyPixelBlockChannels(data, &scan);
    if (!found_xml or scan.width == 0 or scan.height == 0) return error.InvalidFormat;
    const plane_count = std.math.mul(u32, scan.size_c, scan.size_z) catch return error.UnsupportedVariant;
    return .{
        .format = "oir",
        .width = scan.width,
        .height = scan.height,
        .size_c = scan.size_c,
        .samples_per_pixel = scan.samples,
        .size_z = scan.size_z,
        .size_t = scan.size_t,
        .pixel_type = scan.pixel_type,
        .little_endian = true,
        .plane_count = std.math.mul(u32, plane_count, scan.size_t) catch return error.UnsupportedVariant,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const plane_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    try copyPlaneBlocks(data, plane_index, plane_len, out);
    return .{ .metadata = metadata, .data = out };
}

const PixelBlock = struct {
    data_offset: usize,
    data_len: usize,
};

fn copyPlaneBlocks(data: []const u8, plane_index: u32, plane_len: usize, out: []u8) bio.ReaderError!void {
    var pos: usize = identifier.len;
    var current_plane: u32 = 0;
    var plane_offset: usize = 0;
    while (pos + 28 <= data.len) : (pos += 1) {
        const block = parsePixelBlockAt(data, pos) catch continue;
        const uid_start = pixelBlockUidStart(data, pos) orelse {
            pos = block.data_offset + block.data_len - 1;
            continue;
        };
        if (isReferencePixelBlock(data[uid_start .. block.data_offset - 8])) {
            pos = block.data_offset + block.data_len - 1;
            continue;
        }
        if (block.data_len > plane_len or plane_offset > plane_len - block.data_len) {
            return error.UnsupportedVariant;
        }
        if (current_plane == plane_index) {
            @memcpy(out[plane_offset..][0..block.data_len], data[block.data_offset..][0..block.data_len]);
        }
        plane_offset += block.data_len;
        pos = block.data_offset + block.data_len - 1;
        if (plane_offset == plane_len) {
            if (current_plane == plane_index) return;
            current_plane += 1;
            plane_offset = 0;
        }
    }
    return error.UnsupportedVariant;
}

fn parsePixelBlockAt(data: []const u8, pos: usize) bio.ReaderError!PixelBlock {
    if (pos + 28 > data.len) return error.TruncatedData;
    const check_len = leU32(data[pos..][0..4]);
    const check = leU32(data[pos + 4 ..][0..4]);
    if (check != 3) return error.InvalidFormat;
    const uid_len = leU32(data[pos + 16 ..][0..4]);
    if (uid_len == 0 or uid_len > 4096) return error.InvalidFormat;
    if (uid_len > std.math.maxInt(u32) - 12 or check_len != uid_len + 12) return error.InvalidFormat;
    const uid_start = pos + 20;
    const uid_len_usize = try checkedUsize(uid_len);
    const uid_end = std.math.add(usize, uid_start, uid_len_usize) catch return error.UnsupportedVariant;
    if (uid_end > data.len or data.len - uid_end < 8) return error.TruncatedData;
    const uid = data[uid_start..uid_end];
    if (std.mem.indexOfScalar(u8, uid, '_') == null) return error.InvalidFormat;
    const pixel_bytes = leU32(data[uid_end..][0..4]);
    if (pixel_bytes == 0) return error.InvalidFormat;
    const pixel_len = try checkedUsize(pixel_bytes);
    const pixel_offset = std.math.add(usize, uid_end, 8) catch return error.UnsupportedVariant;
    if (pixel_offset > data.len or data.len - pixel_offset < pixel_len) return error.TruncatedData;
    return .{ .data_offset = pixel_offset, .data_len = pixel_len };
}

fn parseXml(xml: []const u8, scan: *Scan) bio.ReaderError!void {
    if (firstUnsigned(xml, &.{ "base:width", "commonimage:width" })) |width| scan.width = @max(scan.width, width);
    if (firstUnsigned(xml, &.{ "base:height", "commonimage:height" })) |height| scan.height = @max(scan.height, height);
    const rgb = tagTextEquals(xml, "base:colorType", "RGB") or tagTextEquals(xml, "commonphase:colorType", "RGB");
    if (firstUnsigned(xml, &.{ "base:depth", "commonphase:depth" })) |depth| {
        const bytes = if (rgb and depth >= 3) depth / 3 else depth;
        scan.pixel_type = try pixelTypeFromBytes(bytes);
        if (rgb) {
            scan.samples = 3;
            scan.size_c = @max(scan.size_c, 3);
        }
    }
    const channel_count = countTagStarts(xml, "commonphase:channel");
    const element_channel_count = countTagStarts(xml, "commonphase:elementChannel");
    const logical_channels = if (element_channel_count > 0) element_channel_count else channel_count;
    if (logical_channels > 0) scan.size_c = @max(scan.size_c, boundedDimension(logical_channels));
    if (axisSize(xml, "ZSTACK")) |size| scan.size_z = @max(scan.size_z, boundedDimension(size));
    if (axisSize(xml, "TIMELAPSE")) |size| scan.size_t = @max(scan.size_t, boundedDimension(size));
    if (axisSize(xml, "LAMBDA")) |size| {
        scan.lambda_size = @max(scan.lambda_size, boundedDimension(size));
        scan.size_c = @max(scan.size_c, scan.lambda_size);
    }
}

fn findXmlEnd(data: []const u8, start: usize) usize {
    const next_xml = std.mem.indexOfPos(u8, data, start + 5, "<?xml");
    const nul = std.mem.indexOfScalarPos(u8, data, start, 0);
    if (next_xml) |next| {
        if (nul) |z| return @min(next, z);
        return next;
    }
    return nul orelse data.len;
}

fn firstUnsigned(xml: []const u8, comptime names: []const []const u8) ?u32 {
    inline for (names) |name| {
        if (tagText(xml, name)) |value| {
            return std.fmt.parseUnsigned(u32, std.mem.trim(u8, value, " \t\r\n"), 10) catch null;
        }
    }
    return null;
}

fn axisSize(xml: []const u8, axis_name: []const u8) ?u32 {
    var target_buf: [96]u8 = undefined;
    const target = std.fmt.bufPrint(&target_buf, "<commonparam:axis>{s}</commonparam:axis>", .{axis_name}) catch return null;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, target)) |axis_value_start| {
        const parent_start = axisParentStart(xml, axis_value_start) orelse {
            pos = axis_value_start + target.len;
            continue;
        };
        if (axisDisabled(xml[parent_start..axis_value_start])) {
            pos = axis_value_start + target.len;
            continue;
        }
        const search_end = @min(xml.len, axis_value_start + 2048);
        if (tagText(xml[axis_value_start..search_end], "commonparam:maxSize")) |size| {
            return std.fmt.parseUnsigned(u32, std.mem.trim(u8, size, " \t\r\n"), 10) catch null;
        }
        pos = axis_value_start + target.len;
    }
    return null;
}

fn axisParentStart(xml: []const u8, axis_value_start: usize) ?usize {
    const common_image = std.mem.lastIndexOf(u8, xml[0..axis_value_start], "<commonimage:axis");
    const common_param = std.mem.lastIndexOf(u8, xml[0..axis_value_start], "<commonparam:axis ");
    if (common_image == null) return common_param;
    if (common_param == null) return common_image;
    return @max(common_image.?, common_param.?);
}

fn axisDisabled(opening: []const u8) bool {
    return std.mem.indexOf(u8, opening, "enable=\"false\"") != null or
        std.mem.indexOf(u8, opening, "paramEnable=\"false\"") != null;
}

fn applyPixelBlockChannels(data: []const u8, scan: *Scan) void {
    var channels: [128][]const u8 = undefined;
    var channel_count: usize = 0;
    var pos: usize = identifier.len;
    while (pos + 28 <= data.len) : (pos += 1) {
        const block = parsePixelBlockAt(data, pos) catch continue;
        const uid_start = pixelBlockUidStart(data, pos) orelse {
            pos = block.data_offset + block.data_len - 1;
            continue;
        };
        const uid = data[uid_start .. block.data_offset - 8];
        if (pixelBlockChannelSignature(uid)) |signature| {
            if (!hasChannelSignature(channels[0..channel_count], signature)) {
                if (channel_count >= channels.len) return;
                channels[channel_count] = signature;
                channel_count += 1;
            }
        }
        pos = block.data_offset + block.data_len - 1;
    }
    if (channel_count > 0) {
        const total = std.math.mul(u32, @intCast(channel_count), scan.lambda_size) catch std.math.maxInt(u32);
        scan.size_c = boundedDimension(total);
    }
}

fn pixelBlockUidStart(data: []const u8, pos: usize) ?usize {
    if (pos + 20 > data.len) return null;
    const uid_len = leU32(data[pos + 16 ..][0..4]);
    if (uid_len == 0 or uid_len > 4096) return null;
    const uid_start = pos + 20;
    const uid_len_usize = checkedUsize(uid_len) catch return null;
    const uid_end = uid_start + uid_len_usize;
    if (uid_end > data.len) return null;
    return uid_start;
}

fn pixelBlockChannelSignature(uid: []const u8) ?[]const u8 {
    const last = std.mem.lastIndexOfScalar(u8, uid, '_') orelse return null;
    const previous = std.mem.lastIndexOfScalar(u8, uid[0..last], '_') orelse return null;
    if (previous + 1 >= last) return null;
    return uid[previous + 1 .. last];
}

fn isReferencePixelBlock(uid: []const u8) bool {
    return std.mem.startsWith(u8, uid, "REF_");
}

fn hasChannelSignature(channels: []const []const u8, signature: []const u8) bool {
    for (channels) |channel| {
        if (std.mem.eql(u8, channel, signature)) return true;
    }
    return false;
}

fn tagTextEquals(xml: []const u8, tag: []const u8, expected: []const u8) bool {
    const value = tagText(xml, tag) orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), expected);
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

fn countTagStarts(xml: []const u8, tag: []const u8) u32 {
    var pattern_buf: [96]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "<{s}", .{tag}) catch return 0;
    var count: u32 = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, pattern)) |found| {
        count += 1;
        pos = found + pattern.len;
    }
    return count;
}

fn pixelTypeFromBytes(bytes: u32) bio.ReaderError!bio.PixelType {
    return switch (bytes) {
        1 => .uint8,
        2 => .uint16,
        4 => .uint32,
        else => error.UnsupportedVariant,
    };
}

fn boundedDimension(value: u32) u16 {
    return @intCast(@min(@max(value, 1), std.math.maxInt(u16)));
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn leU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn checkedUsize(value: anytype) bio.ReaderError!usize {
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
}

test "reads olympus oir image metadata from xml blocks" {
    const data =
        identifier ++
        "header<?xml version=\"1.0\"?><commonimage:imageProperties><commonimage:imageInfo>" ++
        "<commonimage:width>11</commonimage:width><commonimage:height>7</commonimage:height>" ++
        "<commonimage:axis><commonparam:axis>ZSTACK</commonparam:axis><commonparam:maxSize>3</commonparam:maxSize></commonimage:axis>" ++
        "<commonimage:axis><commonparam:axis>TIMELAPSE</commonparam:axis><commonparam:maxSize>4</commonparam:maxSize></commonimage:axis>" ++
        "<commonphase:channel id=\"c1\" order=\"1\"><commonphase:imageDefinition><commonphase:depth>2</commonphase:depth></commonphase:imageDefinition></commonphase:channel>" ++
        "<commonphase:channel id=\"c2\" order=\"2\" />" ++
        "</commonimage:imageInfo></commonimage:imageProperties>";

    try std.testing.expect(matches(data));
    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("oir", metadata.format);
    try std.testing.expectEqual(@as(u32, 11), metadata.width);
    try std.testing.expectEqual(@as(u32, 7), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 4), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 24), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
}

test "reports rgb oir frame metadata" {
    const data =
        identifier ++
        "padding<?xml version=\"1.0\"?><commonframe:frameProperties><commonframe:imageDefinition>" ++
        "<base:width>5</base:width><base:height>6</base:height><base:depth>3</base:depth><base:colorType>RGB</base:colorType>" ++
        "</commonframe:imageDefinition></commonframe:frameProperties>";

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, data, 0));
}

fn appendU32Le(out: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(std.testing.allocator, &bytes);
}

fn appendPixelBlock(out: *std.ArrayList(u8), uid: []const u8, pixels: []const u8) !void {
    try appendU32Le(out, @intCast(uid.len + 12));
    try appendU32Le(out, 3);
    try appendU32Le(out, 0);
    try appendU32Le(out, 0);
    try appendU32Le(out, @intCast(uid.len));
    try out.appendSlice(std.testing.allocator, uid);
    try appendU32Le(out, @intCast(pixels.len));
    try appendU32Le(out, 0);
    try out.appendSlice(std.testing.allocator, pixels);
}

test "uses oir pixel block channel IDs instead of disabled lambda metadata" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, identifier ++ "<?xml version=\"1.0\"?><commonimage:imageProperties><commonimage:imageInfo>");
    try data.appendSlice(std.testing.allocator, "<commonimage:width>2</commonimage:width><commonimage:height>1</commonimage:height>");
    try data.appendSlice(std.testing.allocator, "<commonparam:axis enable=\"true\"><commonparam:axis>TIMELAPSE</commonparam:axis><commonparam:maxSize>8</commonparam:maxSize></commonparam:axis>");
    try data.appendSlice(std.testing.allocator, "<commonparam:axis enable=\"false\"><commonparam:axis>LAMBDA</commonparam:axis><commonparam:maxSize>7</commonparam:maxSize></commonparam:axis>");
    try data.appendSlice(std.testing.allocator, "<commonphase:channel id=\"ch-a\" order=\"1\" /><commonphase:channel id=\"ch-b\" order=\"2\" /><commonphase:channel id=\"unused\" order=\"7\" />");
    try data.appendSlice(std.testing.allocator, "</commonimage:imageInfo></commonimage:imageProperties>");
    try appendPixelBlock(&data, "t001_0_1_ch-a_0", &.{ 1, 0, 2, 0 });
    try appendPixelBlock(&data, "t001_0_1_ch-b_0", &.{ 3, 0, 4, 0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 8), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 16), metadata.plane_count);
}

test "reads olympus oir full-plane raw pixel blocks" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, identifier ++ "<?xml version=\"1.0\"?><commonframe:frameProperties><commonframe:imageDefinition>");
    try data.appendSlice(std.testing.allocator, "<base:width>3</base:width><base:height>2</base:height><base:depth>2</base:depth>");
    try data.appendSlice(std.testing.allocator, "<commonimage:axis><commonparam:axis>ZSTACK</commonparam:axis><commonparam:maxSize>2</commonparam:maxSize></commonimage:axis>");
    try data.appendSlice(std.testing.allocator, "</commonframe:imageDefinition></commonframe:frameProperties>");
    const first = [_]u8{ 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0 };
    const second = [_]u8{ 7, 0, 8, 0, 9, 0, 10, 0, 11, 0, 12, 0 };
    try appendPixelBlock(&data, "z001t001_ch0_0", &first);
    try appendPixelBlock(&data, "z002t001_ch0_0", &second);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("oir", plane.metadata.format);
    try std.testing.expectEqual(bio.PixelType.uint16, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &second, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "assembles olympus oir plane from raw pixel block chunks" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, identifier ++ "<?xml version=\"1.0\"?><commonframe:frameProperties><commonframe:imageDefinition>");
    try data.appendSlice(std.testing.allocator, "<base:width>3</base:width><base:height>1</base:height><base:depth>2</base:depth>");
    try data.appendSlice(std.testing.allocator, "<commonimage:axis><commonparam:axis>ZSTACK</commonparam:axis><commonparam:maxSize>2</commonparam:maxSize></commonimage:axis>");
    try data.appendSlice(std.testing.allocator, "</commonframe:imageDefinition></commonframe:frameProperties>");
    try appendPixelBlock(&data, "z001t001_ch0_0", &.{ 1, 0, 2, 0 });
    try appendPixelBlock(&data, "z001t001_ch0_1", &.{ 3, 0 });
    try appendPixelBlock(&data, "z002t001_ch0_0", &.{ 4, 0 });
    try appendPixelBlock(&data, "z002t001_ch0_1", &.{ 5, 0, 6, 0 });

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 4, 0, 5, 0, 6, 0 }, plane.data);
}

test "rejects oversized oir candidate block length without overflow" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, identifier ++ "<?xml version=\"1.0\"?><commonframe:frameProperties><commonframe:imageDefinition>");
    try data.appendSlice(std.testing.allocator, "<base:width>1</base:width><base:height>1</base:height><base:depth>1</base:depth>");
    try data.appendSlice(std.testing.allocator, "</commonframe:imageDefinition></commonframe:frameProperties>");
    try appendU32Le(&data, 11);
    try appendU32Le(&data, 3);
    try appendU32Le(&data, 0);
    try appendU32Le(&data, 0);
    try appendU32Le(&data, std.math.maxInt(u32));
    try data.appendNTimes(std.testing.allocator, 0, 16);

    try std.testing.expectError(error.UnsupportedVariant, readPlaneIndex(std.testing.allocator, data.items, 0));
}

test "matches Bio-Formats core metadata for cached OIR fixture" {
    const file_path = "fixtures/cache/oir/1202-interval_10sec_sequence_frame.oir";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(32 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("oir", metadata.format);
    try std.testing.expectEqual(@as(u32, 512), metadata.width);
    try std.testing.expectEqual(@as(u32, 512), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 8), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 16), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
}

test "matches Bio-Formats plane hashes for cached OIR fixture" {
    const file_path = "fixtures/cache/oir/1202-interval_10sec_sequence_frame.oir";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(32 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const expected = [_]struct { plane: u32, sha256: [32]u8 }{
        .{ .plane = 0, .sha256 = .{ 0xe5, 0xf2, 0x8f, 0xd8, 0x81, 0x41, 0x4d, 0xc0, 0x25, 0xe8, 0xa3, 0x9b, 0x32, 0x39, 0xa8, 0x33, 0xd6, 0xde, 0x34, 0xe4, 0xc1, 0xf4, 0x3b, 0x46, 0xa1, 0x9b, 0xfb, 0x50, 0x26, 0x06, 0x10, 0x98 } },
        .{ .plane = 8, .sha256 = .{ 0x2a, 0x15, 0x39, 0x34, 0x40, 0x44, 0x29, 0x78, 0x28, 0xe0, 0xb7, 0xd6, 0xe0, 0xc5, 0x79, 0xb7, 0x6a, 0x97, 0x53, 0x5c, 0x48, 0x61, 0x14, 0x6b, 0xca, 0x69, 0x1c, 0x35, 0x2f, 0xdd, 0x96, 0xc2 } },
        .{ .plane = 15, .sha256 = .{ 0x3b, 0x91, 0x70, 0xc1, 0x36, 0x0c, 0xb7, 0x9b, 0x4b, 0x19, 0xa7, 0xf6, 0x12, 0xb2, 0x1c, 0xbb, 0x68, 0x53, 0xf0, 0x75, 0x8a, 0x73, 0xce, 0xa2, 0xe4, 0xd4, 0x2b, 0x41, 0x0d, 0xab, 0xd8, 0x9a } },
    };
    for (expected) |sample| {
        const plane = try readPlaneIndex(std.testing.allocator, data, sample.plane);
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqual(@as(usize, 524288), plane.data.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
        try std.testing.expectEqualSlices(u8, &sample.sha256, &digest);
    }

    const plane = try readPlaneIndex(std.testing.allocator, data, 8);
    defer std.testing.allocator.free(plane.data);
    const region_data = try bio.cropPlane(std.testing.allocator, plane, .{ .x = 17, .y = 19, .width = 16, .height = 12 });
    defer std.testing.allocator.free(region_data);
    const expected_region: [32]u8 = .{ 0xb9, 0x4c, 0xf7, 0x29, 0x2a, 0x3d, 0x82, 0x8f, 0xe4, 0x39, 0xee, 0x53, 0x1c, 0xf4, 0x89, 0x98, 0xe0, 0x71, 0x87, 0x5b, 0xf1, 0x89, 0xad, 0xa8, 0x66, 0xe5, 0x7b, 0x49, 0x81, 0xc2, 0xa0, 0x58 };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(region_data, &digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_region, &digest);
}
