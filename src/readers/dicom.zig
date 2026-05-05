const std = @import("std");
const bio = @import("../root.zig");

const preamble_len = 128;
const magic = "DICM";
const pixel_data_group: u16 = 0x7fe0;
const pixel_data_element: u16 = 0x0010;

const TransferSyntax = enum {
    explicit_little,
    implicit_little,
    explicit_big,

    fn littleEndian(self: TransferSyntax) bool {
        return self != .explicit_big;
    }
};

const Header = struct {
    width: u32 = 0,
    height: u32 = 0,
    samples_per_pixel: u16 = 1,
    bits_allocated: u16 = 0,
    pixel_representation: u16 = 0,
    planar_configuration: u16 = 0,
    inverted_grayscale: bool = false,
    frames: u32 = 1,
    transfer_syntax: TransferSyntax = .explicit_little,
    pixel_offset: usize = 0,
    pixel_len: usize = 0,
};

const Element = struct {
    group: u16,
    element: u16,
    vr: ?[2]u8,
    value_offset: usize,
    value_len: usize,
    little_endian: bool,
};

pub fn matches(data: []const u8) bool {
    return hasDicomPreamble(data) or looksLikeDicomDataset(data);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "dicom",
        .width = header.width,
        .height = header.height,
        .size_c = header.samples_per_pixel,
        .samples_per_pixel = header.samples_per_pixel,
        .size_z = 1,
        .size_t = @intCast(@min(header.frames, std.math.maxInt(u16))),
        .pixel_type = try pixelType(header),
        .little_endian = header.transfer_syntax.littleEndian(),
        .plane_count = header.frames,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const header = try parseHeader(data);
    const plane_len = try planeByteCount(metadata);
    const offset = std.math.add(usize, header.pixel_offset, std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (offset > data.len or data.len - offset < plane_len) return error.TruncatedData;
    if (header.pixel_len < std.math.mul(usize, plane_len, plane_index + 1) catch return error.UnsupportedVariant) return error.TruncatedData;

    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    const src = data[offset..][0..plane_len];
    if (header.planar_configuration == 1 and header.samples_per_pixel > 1) {
        try interleavePlanarSamples(src, out, header);
    } else if (header.planar_configuration == 0) {
        @memcpy(out, src);
    } else {
        return error.UnsupportedVariant;
    }
    if (header.inverted_grayscale) try invertGrayscale(out, header);
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    var header = Header{};
    const has_preamble = hasDicomPreamble(data);
    var offset: usize = if (has_preamble) preamble_len + magic.len else 0;
    var syntax: TransferSyntax = if (has_preamble) .explicit_little else .implicit_little;
    var in_meta = has_preamble;

    while (offset + 8 <= data.len) {
        const group = leU16(data[offset..][0..2]);
        if (in_meta and group != 0x0002) {
            in_meta = false;
            syntax = header.transfer_syntax;
        }

        const element = try readElement(data, offset, if (in_meta) .explicit_little else syntax);
        offset = element.value_offset + element.value_len + (element.value_len & 1);
        if (offset > data.len) return error.TruncatedData;

        switch (element.group) {
            0x0002 => if (element.element == 0x0010) {
                header.transfer_syntax = try parseTransferSyntax(elementValue(data, element));
            },
            0x0028 => switch (element.element) {
                0x0002 => header.samples_per_pixel = try readU16Value(data, element),
                0x0004 => header.inverted_grayscale = isMonochrome1(elementValue(data, element)),
                0x0006 => header.planar_configuration = try readU16Value(data, element),
                0x0008 => header.frames = try parseFrameCount(elementValue(data, element)),
                0x0010 => header.height = try readU16Value(data, element),
                0x0011 => header.width = try readU16Value(data, element),
                0x0100 => header.bits_allocated = try readU16Value(data, element),
                0x0103 => header.pixel_representation = try readU16Value(data, element),
                else => {},
            },
            pixel_data_group => if (element.element == pixel_data_element) {
                header.pixel_offset = element.value_offset;
                header.pixel_len = element.value_len;
                break;
            },
            else => {},
        }
    }

    if (header.width == 0 or header.height == 0 or header.bits_allocated == 0 or header.pixel_offset == 0) return error.InvalidFormat;
    if (header.frames == 0) return error.InvalidFormat;
    _ = try pixelType(header);
    const metadata = bio.Metadata{
        .format = "dicom",
        .width = header.width,
        .height = header.height,
        .size_c = header.samples_per_pixel,
        .samples_per_pixel = header.samples_per_pixel,
        .pixel_type = try pixelType(header),
        .little_endian = header.transfer_syntax.littleEndian(),
        .plane_count = header.frames,
    };
    const plane_len = try planeByteCount(metadata);
    const needed = std.math.mul(usize, plane_len, header.frames) catch return error.UnsupportedVariant;
    if (header.pixel_len < needed) return error.TruncatedData;
    return header;
}

fn hasDicomPreamble(data: []const u8) bool {
    return data.len >= preamble_len + magic.len and std.mem.eql(u8, data[preamble_len..][0..magic.len], magic);
}

fn looksLikeDicomDataset(data: []const u8) bool {
    if (data.len < 16) return false;
    const group = leU16(data[0..2]);
    const element = leU16(data[2..4]);
    if (group != 0x0008) return false;
    switch (element) {
        0x0000, 0x0005, 0x0008, 0x0016, 0x0018, 0x0020, 0x0030, 0x0060 => {},
        else => return false,
    }
    const value_len = leU32(data[4..8]);
    return value_len <= data.len - 8;
}

fn readElement(data: []const u8, offset: usize, syntax: TransferSyntax) bio.ReaderError!Element {
    if (offset + 8 > data.len) return error.TruncatedData;
    const little_endian = syntax.littleEndian();
    const group = readU16(data[offset..][0..2], little_endian);
    const element = readU16(data[offset + 2 ..][0..2], little_endian);
    switch (syntax) {
        .explicit_little, .explicit_big => {
            const vr = [2]u8{ data[offset + 4], data[offset + 5] };
            const long_len = isLongExplicitVr(vr);
            const value_offset = offset + if (long_len) @as(usize, 12) else 8;
            if (value_offset > data.len) return error.TruncatedData;
            const raw_len = if (long_len) readU32(data[offset + 8 ..][0..4], little_endian) else readU16(data[offset + 6 ..][0..2], little_endian);
            if (raw_len == 0xffffffff) return error.UnsupportedVariant;
            const value_len = try checkedUsize(raw_len);
            if (value_offset > data.len or data.len - value_offset < value_len) return error.TruncatedData;
            return .{ .group = group, .element = element, .vr = vr, .value_offset = value_offset, .value_len = value_len, .little_endian = little_endian };
        },
        .implicit_little => {
            const raw_len = leU32(data[offset + 4 ..][0..4]);
            if (raw_len == 0xffffffff) return error.UnsupportedVariant;
            const value_len = try checkedUsize(raw_len);
            const value_offset = offset + 8;
            if (data.len - value_offset < value_len) return error.TruncatedData;
            return .{ .group = group, .element = element, .vr = null, .value_offset = value_offset, .value_len = value_len, .little_endian = little_endian };
        },
    }
}

fn isLongExplicitVr(vr: [2]u8) bool {
    return std.mem.eql(u8, &vr, "OB") or
        std.mem.eql(u8, &vr, "OD") or
        std.mem.eql(u8, &vr, "OF") or
        std.mem.eql(u8, &vr, "OL") or
        std.mem.eql(u8, &vr, "OW") or
        std.mem.eql(u8, &vr, "SQ") or
        std.mem.eql(u8, &vr, "UC") or
        std.mem.eql(u8, &vr, "UN") or
        std.mem.eql(u8, &vr, "UR") or
        std.mem.eql(u8, &vr, "UT");
}

fn parseTransferSyntax(text: []const u8) bio.ReaderError!TransferSyntax {
    const trimmed = trimText(text);
    if (std.mem.eql(u8, trimmed, "1.2.840.10008.1.2.1")) return .explicit_little;
    if (std.mem.eql(u8, trimmed, "1.2.840.10008.1.2")) return .implicit_little;
    if (std.mem.eql(u8, trimmed, "1.2.840.10008.1.2.2")) return .explicit_big;
    return error.UnsupportedVariant;
}

fn parseFrameCount(text: []const u8) bio.ReaderError!u32 {
    const trimmed = trimText(text);
    if (trimmed.len == 0) return 1;
    return std.fmt.parseInt(u32, trimmed, 10) catch return error.InvalidFormat;
}

fn readU16Value(data: []const u8, element: Element) bio.ReaderError!u16 {
    const bytes = elementValue(data, element);
    if (bytes.len < 2) return error.TruncatedData;
    return readU16(bytes[0..2], element.little_endian);
}

fn elementValue(data: []const u8, element: Element) []const u8 {
    return data[element.value_offset..][0..element.value_len];
}

fn trimText(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n\x00");
}

fn isMonochrome1(text: []const u8) bool {
    return std.mem.eql(u8, trimText(text), "MONOCHROME1");
}

fn pixelType(header: Header) bio.ReaderError!bio.PixelType {
    return switch (header.bits_allocated) {
        8 => if (header.samples_per_pixel == 1)
            if (header.pixel_representation == 0) .uint8 else .int8
        else if (header.samples_per_pixel == 3)
            .rgb8
        else if (header.samples_per_pixel == 4)
            .rgba8
        else
            error.UnsupportedVariant,
        16 => if (header.samples_per_pixel == 1)
            if (header.pixel_representation == 0) .uint16 else .int16
        else if (header.samples_per_pixel == 3)
            .rgb16
        else if (header.samples_per_pixel == 4)
            .rgba16
        else
            error.UnsupportedVariant,
        else => error.UnsupportedVariant,
    };
}

fn invertGrayscale(bytes: []u8, header: Header) bio.ReaderError!void {
    if (header.samples_per_pixel != 1) return error.UnsupportedVariant;
    switch (header.bits_allocated) {
        8 => for (bytes) |*byte| {
            byte.* = 255 - byte.*;
        },
        16 => {
            if ((bytes.len & 1) != 0) return error.TruncatedData;
            var offset: usize = 0;
            while (offset < bytes.len) : (offset += 2) {
                const value = readU16(bytes[offset..][0..2], header.transfer_syntax.littleEndian());
                const inverted = std.math.maxInt(u16) - value;
                std.mem.writeInt(u16, bytes[offset..][0..2], inverted, if (header.transfer_syntax.littleEndian()) .little else .big);
            }
        },
        else => return error.UnsupportedVariant,
    }
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn interleavePlanarSamples(src: []const u8, dst: []u8, header: Header) bio.ReaderError!void {
    const sample_bytes: usize = switch (header.bits_allocated) {
        8 => 1,
        16 => 2,
        else => return error.UnsupportedVariant,
    };
    const pixels = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    const sample_plane_len = std.math.mul(usize, pixels, sample_bytes) catch return error.UnsupportedVariant;
    const samples: usize = header.samples_per_pixel;
    if (src.len < sample_plane_len * samples or dst.len < sample_plane_len * samples) return error.TruncatedData;

    var pixel: usize = 0;
    while (pixel < pixels) : (pixel += 1) {
        var sample: usize = 0;
        while (sample < samples) : (sample += 1) {
            const src_offset = sample * sample_plane_len + pixel * sample_bytes;
            const dst_offset = (pixel * samples + sample) * sample_bytes;
            @memcpy(dst[dst_offset..][0..sample_bytes], src[src_offset..][0..sample_bytes]);
        }
    }
}

fn leU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn leU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn readU16(bytes: []const u8, little_endian: bool) u16 {
    return std.mem.readInt(u16, bytes[0..2], if (little_endian) .little else .big);
}

fn readU32(bytes: []const u8, little_endian: bool) u32 {
    return std.mem.readInt(u32, bytes[0..4], if (little_endian) .little else .big);
}

fn checkedUsize(value: anytype) bio.ReaderError!usize {
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
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

fn appendU16Be(list: *std.ArrayList(u8), value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .big);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendU32Be(list: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendExplicitElement(list: *std.ArrayList(u8), group: u16, element: u16, vr: []const u8, payload: []const u8) !void {
    try appendU16Le(list, group);
    try appendU16Le(list, element);
    try list.appendSlice(std.testing.allocator, vr);
    if (isLongExplicitVr(.{ vr[0], vr[1] })) {
        try appendU16Le(list, 0);
        try appendU32Le(list, @intCast(payload.len));
    } else {
        try appendU16Le(list, @intCast(payload.len));
    }
    try list.appendSlice(std.testing.allocator, payload);
    if ((payload.len & 1) != 0) try list.append(std.testing.allocator, 0);
}

fn appendExplicitElementBig(list: *std.ArrayList(u8), group: u16, element: u16, vr: []const u8, payload: []const u8) !void {
    try appendU16Be(list, group);
    try appendU16Be(list, element);
    try list.appendSlice(std.testing.allocator, vr);
    if (isLongExplicitVr(.{ vr[0], vr[1] })) {
        try appendU16Be(list, 0);
        try appendU32Be(list, @intCast(payload.len));
    } else {
        try appendU16Be(list, @intCast(payload.len));
    }
    try list.appendSlice(std.testing.allocator, payload);
    if ((payload.len & 1) != 0) try list.append(std.testing.allocator, 0);
}

fn appendImplicitElement(list: *std.ArrayList(u8), group: u16, element: u16, payload: []const u8) !void {
    try appendU16Le(list, group);
    try appendU16Le(list, element);
    try appendU32Le(list, @intCast(payload.len));
    try list.appendSlice(std.testing.allocator, payload);
    if ((payload.len & 1) != 0) try list.append(std.testing.allocator, 0);
}

fn appendUsExplicit(list: *std.ArrayList(u8), group: u16, element: u16, value_u16: u16) !void {
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, value_u16, .little);
    try appendExplicitElement(list, group, element, "US", &payload);
}

fn appendUsExplicitBig(list: *std.ArrayList(u8), group: u16, element: u16, value_u16: u16) !void {
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, value_u16, .big);
    try appendExplicitElementBig(list, group, element, "US", &payload);
}

fn appendDicomPreamble(list: *std.ArrayList(u8), transfer_syntax: []const u8) !void {
    try list.appendNTimes(std.testing.allocator, 0, preamble_len);
    try list.appendSlice(std.testing.allocator, magic);
    try appendExplicitElement(list, 0x0002, 0x0010, "UI", transfer_syntax);
}

fn appendExplicitCore(list: *std.ArrayList(u8), width: u16, height: u16, samples: u16, bits: u16, frames: ?[]const u8) !void {
    try appendExplicitCorePhotometric(list, width, height, samples, bits, frames, if (samples == 1) "MONOCHROME2" else "RGB");
}

fn appendExplicitCorePhotometric(list: *std.ArrayList(u8), width: u16, height: u16, samples: u16, bits: u16, frames: ?[]const u8, photometric: []const u8) !void {
    try appendUsExplicit(list, 0x0028, 0x0002, samples);
    try appendExplicitElement(list, 0x0028, 0x0004, "CS", photometric);
    if (frames) |frame_text| try appendExplicitElement(list, 0x0028, 0x0008, "IS", frame_text);
    try appendUsExplicit(list, 0x0028, 0x0010, height);
    try appendUsExplicit(list, 0x0028, 0x0011, width);
    try appendUsExplicit(list, 0x0028, 0x0100, bits);
    try appendUsExplicit(list, 0x0028, 0x0103, 0);
}

fn appendExplicitCoreBig(list: *std.ArrayList(u8), width: u16, height: u16, samples: u16, bits: u16) !void {
    try appendUsExplicitBig(list, 0x0028, 0x0002, samples);
    try appendExplicitElementBig(list, 0x0028, 0x0004, "CS", if (samples == 1) "MONOCHROME2" else "RGB");
    try appendUsExplicitBig(list, 0x0028, 0x0010, height);
    try appendUsExplicitBig(list, 0x0028, 0x0011, width);
    try appendUsExplicitBig(list, 0x0028, 0x0100, bits);
    try appendUsExplicitBig(list, 0x0028, 0x0103, 0);
}

test "reads explicit little endian uint16 dicom plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendDicomPreamble(&data, "1.2.840.10008.1.2.1");
    try appendExplicitCore(&data, 2, 1, 1, 16, null);
    try appendExplicitElement(&data, pixel_data_group, pixel_data_element, "OW", &.{ 0x34, 0x12, 0xcd, 0xab });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("dicom", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
}

test "reads explicit big endian uint16 dicom plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendDicomPreamble(&data, "1.2.840.10008.1.2.2");
    try appendExplicitCoreBig(&data, 2, 1, 1, 16);
    try appendExplicitElementBig(&data, pixel_data_group, pixel_data_element, "OW", &.{ 0x12, 0x34, 0xab, 0xcd });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("dicom", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0xab, 0xcd }, plane.data);
}

test "interleaves planar rgb dicom samples" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendDicomPreamble(&data, "1.2.840.10008.1.2.1");
    try appendExplicitCore(&data, 2, 1, 3, 8, null);
    try appendUsExplicit(&data, 0x0028, 0x0006, 1);
    try appendExplicitElement(&data, pixel_data_group, pixel_data_element, "OB", &.{ 1, 4, 2, 5, 3, 6 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, plane.data);
}

test "inverts monochrome1 uint8 dicom plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendDicomPreamble(&data, "1.2.840.10008.1.2.1");
    try appendExplicitCorePhotometric(&data, 3, 1, 1, 8, null, "MONOCHROME1");
    try appendExplicitElement(&data, pixel_data_group, pixel_data_element, "OB", &.{ 0, 17, 255 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 238, 0 }, plane.data);
}

test "inverts monochrome1 uint16 dicom plane with transfer endian" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendDicomPreamble(&data, "1.2.840.10008.1.2.2");
    try appendUsExplicitBig(&data, 0x0028, 0x0002, 1);
    try appendExplicitElementBig(&data, 0x0028, 0x0004, "CS", "MONOCHROME1");
    try appendUsExplicitBig(&data, 0x0028, 0x0010, 1);
    try appendUsExplicitBig(&data, 0x0028, 0x0011, 2);
    try appendUsExplicitBig(&data, 0x0028, 0x0100, 16);
    try appendUsExplicitBig(&data, 0x0028, 0x0103, 0);
    try appendExplicitElementBig(&data, pixel_data_group, pixel_data_element, "OW", &.{ 0x00, 0x00, 0x12, 0x34 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xed, 0xcb }, plane.data);
}

test "reads second explicit little endian dicom frame" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendDicomPreamble(&data, "1.2.840.10008.1.2.1");
    try appendExplicitCore(&data, 2, 1, 1, 8, "2");
    try appendExplicitElement(&data, pixel_data_group, pixel_data_element, "OB", &.{ 1, 2, 3, 4 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, plane.data);
}

test "reads implicit little endian dicom plane after meta header" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendDicomPreamble(&data, "1.2.840.10008.1.2");
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, 1, .little);
    try appendImplicitElement(&data, 0x0028, 0x0002, &payload);
    try appendImplicitElement(&data, 0x0028, 0x0010, &payload);
    try appendImplicitElement(&data, 0x0028, 0x0011, &payload);
    try appendImplicitElement(&data, 0x0028, 0x0100, &.{ 8, 0 });
    try appendImplicitElement(&data, 0x0028, 0x0103, &.{ 0, 0 });
    try appendImplicitElement(&data, pixel_data_group, pixel_data_element, &.{42});

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{42}, plane.data);
}

test "reads no-preamble implicit little endian dicom plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendImplicitElement(&data, 0x0008, 0x0000, &.{ 4, 0, 0, 0 });
    var samples: [2]u8 = undefined;
    std.mem.writeInt(u16, &samples, 1, .little);
    try appendImplicitElement(&data, 0x0028, 0x0002, &samples);
    try appendImplicitElement(&data, 0x0028, 0x0004, "MONOCHROME2");
    try appendImplicitElement(&data, 0x0028, 0x0010, &samples);
    try appendImplicitElement(&data, 0x0028, 0x0011, &samples);
    try appendImplicitElement(&data, 0x0028, 0x0100, &.{ 8, 0 });
    try appendImplicitElement(&data, 0x0028, 0x0103, &.{ 0, 0 });
    try appendImplicitElement(&data, pixel_data_group, pixel_data_element, &.{99});

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("dicom", metadata.format);
    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{99}, plane.data);
}

test "rejects compressed dicom transfer syntax" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendDicomPreamble(&data, "1.2.840.10008.1.2.4.50");
    try appendExplicitCore(&data, 1, 1, 1, 8, null);
    try appendExplicitElement(&data, pixel_data_group, pixel_data_element, "OB", &.{1});

    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}
