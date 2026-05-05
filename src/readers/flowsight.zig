const std = @import("std");
const bio = @import("../root.zig");
const tiff = @import("tiff.zig");

const channel_count_tag = 33000;
const metadata_xml_tag = 33027;
const greyscale_compression = 30817;
const bitmask_compression = 30818;
const max_strips = 1024;

const ByteOrder = enum {
    little,
    big,
};

const ImageIfd = struct {
    order: ByteOrder,
    width: u32,
    height: u32,
    channel_count: u16,
    bits_per_sample: u16,
    compression: u16,
    strip_offsets: [max_strips]u32,
    strip_byte_counts: [max_strips]u32,
    strip_count: usize,
};

pub fn matches(data: []const u8) bool {
    return tiff.firstIfdAsciiTag(data, metadata_xml_tag) != null;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const ifd = try parseFirstImageIfd(data);
    return .{
        .format = "flowsight",
        .width = ifd.width / ifd.channel_count,
        .height = ifd.height,
        .size_c = ifd.channel_count,
        .samples_per_pixel = 1,
        .pixel_type = pixelType(ifd.bits_per_sample),
        .little_endian = ifd.order == .little,
        .plane_count = ifd.channel_count,
        .image_description = tiff.firstIfdAsciiTag(data, metadata_xml_tag),
        .dimension_order = "XYCZT",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const ifd = try parseFirstImageIfd(data);
    if (plane_index >= ifd.channel_count) return error.InvalidPlaneIndex;
    if (ifd.width % ifd.channel_count != 0) return error.InvalidFormat;

    const metadata = try readMetadata(data);
    const bytes_per_sample = ifd.bits_per_sample / 8;
    const full_row_bytes = std.math.mul(usize, ifd.width, bytes_per_sample) catch return error.UnsupportedVariant;
    const full_len = std.math.mul(usize, full_row_bytes, ifd.height) catch return error.UnsupportedVariant;
    const full = try allocator.alloc(u8, full_len);
    defer allocator.free(full);

    switch (ifd.compression) {
        greyscale_compression => try decodeGreyscale(allocator, data, ifd, full),
        bitmask_compression => try decodeBitmask(data, ifd, full),
        else => return error.UnsupportedVariant,
    }

    const channel_width = ifd.width / ifd.channel_count;
    const channel_row_bytes = std.math.mul(usize, channel_width, bytes_per_sample) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, channel_row_bytes, ifd.height) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    const channel_x = @as(usize, plane_index) * channel_row_bytes;
    var y: usize = 0;
    while (y < ifd.height) : (y += 1) {
        const src = y * full_row_bytes + channel_x;
        const dst = y * channel_row_bytes;
        @memcpy(out[dst..][0..channel_row_bytes], full[src..][0..channel_row_bytes]);
    }

    return .{ .metadata = metadata, .data = out };
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    const plane = try readPlaneIndex(allocator, data, plane_index);
    errdefer allocator.free(plane.data);
    try region.validate(plane.metadata);
    if (region.isFull(plane.metadata)) return plane;
    defer allocator.free(plane.data);
    return .{ .metadata = plane.metadata, .data = try bio.cropPlane(allocator, plane, region) };
}

fn parseFirstImageIfd(data: []const u8) bio.ReaderError!ImageIfd {
    if (!matches(data)) return error.InvalidFormat;
    const order = try byteOrder(data);
    if (readU16(order, data[2..4]) != 42) return error.UnsupportedVariant;
    const first_ifd = readU32(order, data[4..8]);
    const image_ifd = try nextIfdOffset(data, order, first_ifd);
    if (image_ifd == 0) return error.InvalidFormat;
    return parseImageIfd(data, order, image_ifd);
}

fn parseImageIfd(data: []const u8, order: ByteOrder, ifd_offset_u32: u32) bio.ReaderError!ImageIfd {
    const ifd_offset = try checkedUsize(ifd_offset_u32);
    if (ifd_offset > data.len or data.len - ifd_offset < 2) return error.TruncatedData;
    const entry_count = readU16(order, data[ifd_offset..][0..2]);
    const entries_start = ifd_offset + 2;
    const entries_bytes = std.math.mul(usize, entry_count, 12) catch return error.UnsupportedVariant;
    if (entries_start > data.len or data.len - entries_start < entries_bytes + 4) return error.TruncatedData;

    var ifd: ImageIfd = .{
        .order = order,
        .width = 0,
        .height = 0,
        .channel_count = 1,
        .bits_per_sample = 8,
        .compression = 0,
        .strip_offsets = [_]u32{0} ** max_strips,
        .strip_byte_counts = [_]u32{0} ** max_strips,
        .strip_count = 0,
    };

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const entry = parseEntry(order, data, entries_start + i * 12);
        switch (entry.tag) {
            256 => ifd.width = try entryValueU32(order, data, entry, 0),
            257 => ifd.height = try entryValueU32(order, data, entry, 0),
            258 => ifd.bits_per_sample = @intCast(try entryValueU32(order, data, entry, 0)),
            259 => ifd.compression = @intCast(try entryValueU32(order, data, entry, 0)),
            273 => ifd.strip_count = try copyEntryValues(order, data, entry, &ifd.strip_offsets),
            279 => {
                const count = try copyEntryValues(order, data, entry, &ifd.strip_byte_counts);
                if (ifd.strip_count == 0) ifd.strip_count = count;
            },
            channel_count_tag => ifd.channel_count = @intCast(try entryValueU32(order, data, entry, 0)),
            else => {},
        }
    }

    if (ifd.width == 0 or ifd.height == 0 or ifd.channel_count == 0) return error.InvalidFormat;
    if (ifd.strip_count == 0) return error.InvalidFormat;
    if (ifd.bits_per_sample != 8 and ifd.bits_per_sample != 16) return error.UnsupportedVariant;
    if (ifd.compression == bitmask_compression and ifd.bits_per_sample != 8) return error.UnsupportedVariant;
    if (ifd.compression == greyscale_compression and ifd.bits_per_sample != 16) return error.UnsupportedVariant;
    return ifd;
}

fn decodeBitmask(data: []const u8, ifd: ImageIfd, out: []u8) bio.ReaderError!void {
    var dst: usize = 0;
    var strip: usize = 0;
    while (strip < ifd.strip_count) : (strip += 1) {
        const offset = try checkedUsize(ifd.strip_offsets[strip]);
        const count = try checkedUsize(ifd.strip_byte_counts[strip]);
        if (offset > data.len or data.len - offset < count) return error.TruncatedData;
        const src = data[offset..][0..count];
        var i: usize = 0;
        while (i + 1 < src.len) : (i += 2) {
            const run_len = @as(usize, src[i + 1]) + 1;
            if (dst > out.len or out.len - dst < run_len) return error.TruncatedData;
            @memset(out[dst..][0..run_len], src[i]);
            dst += run_len;
        }
        if (i != src.len) return error.InvalidFormat;
    }
    if (dst != out.len) return error.TruncatedData;
}

fn decodeGreyscale(allocator: std.mem.Allocator, data: []const u8, ifd: ImageIfd, out: []u8) bio.ReaderError!void {
    const width = try checkedUsize(ifd.width);
    const height = try checkedUsize(ifd.height);
    const last_row = try allocator.alloc(i32, width);
    defer allocator.free(last_row);
    const this_row = try allocator.alloc(i32, width);
    defer allocator.free(this_row);
    @memset(last_row, 0);
    @memset(this_row, 0);

    var reader = NibbleReader{ .data = data, .ifd = ifd };
    var out_i: usize = 0;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const diff = try reader.nextSignedDiff();
            const left = if (x == 0) 0 else this_row[x - 1];
            const upper_left = if (x == 0) 0 else last_row[x - 1];
            const value = diff + last_row[x] + left - upper_left;
            this_row[x] = value;
            const signed: i16 = @intCast(value);
            std.mem.writeInt(u16, out[out_i..][0..2], @bitCast(signed), if (ifd.order == .little) .little else .big);
            out_i += 2;
        }
        @memcpy(last_row, this_row);
    }
    if (out_i != out.len) return error.TruncatedData;
}

const NibbleReader = struct {
    data: []const u8,
    ifd: ImageIfd,
    strip_index: usize = 0,
    strip_pos: usize = 0,
    current_byte: u8 = 0,
    nibble_index: u2 = 2,

    fn nextSignedDiff(self: *NibbleReader) bio.ReaderError!i32 {
        var value: i32 = 0;
        var shift: u5 = 0;
        while (true) {
            if (shift > 15) return error.InvalidFormat;
            const nibble = try self.nextNibble();
            value += @as(i32, nibble & 0x7) << shift;
            shift += 3;
            if ((nibble & 0x8) == 0) {
                if ((nibble & 0x4) != 0) value |= -(@as(i32, 1) << shift);
                return value;
            }
        }
    }

    fn nextNibble(self: *NibbleReader) bio.ReaderError!u8 {
        if (self.nibble_index >= 2) {
            self.current_byte = try self.nextByte();
            self.nibble_index = 0;
        }
        defer self.nibble_index += 1;
        return if (self.nibble_index == 0) self.current_byte & 0x0f else self.current_byte >> 4;
    }

    fn nextByte(self: *NibbleReader) bio.ReaderError!u8 {
        while (self.strip_index < self.ifd.strip_count) {
            const count = try checkedUsize(self.ifd.strip_byte_counts[self.strip_index]);
            if (self.strip_pos < count) {
                const offset = try checkedUsize(self.ifd.strip_offsets[self.strip_index]);
                if (offset > self.data.len or self.data.len - offset <= self.strip_pos) return error.TruncatedData;
                const byte = self.data[offset + self.strip_pos];
                self.strip_pos += 1;
                return byte;
            }
            self.strip_index += 1;
            self.strip_pos = 0;
        }
        return error.TruncatedData;
    }
};

const Entry = struct {
    tag: u16,
    field_type: u16,
    count: u32,
    value_offset: u32,
    value_field_offset: usize,
};

fn parseEntry(order: ByteOrder, data: []const u8, offset: usize) Entry {
    return .{
        .tag = readU16(order, data[offset..][0..2]),
        .field_type = readU16(order, data[offset + 2 ..][0..2]),
        .count = readU32(order, data[offset + 4 ..][0..4]),
        .value_offset = readU32(order, data[offset + 8 ..][0..4]),
        .value_field_offset = offset + 8,
    };
}

fn copyEntryValues(order: ByteOrder, data: []const u8, entry: Entry, dest: []u32) bio.ReaderError!usize {
    if (entry.count > dest.len) return error.UnsupportedVariant;
    var i: usize = 0;
    while (i < entry.count) : (i += 1) {
        dest[i] = try entryValueU32(order, data, entry, i);
    }
    return try checkedUsize(entry.count);
}

fn entryValueU32(order: ByteOrder, data: []const u8, entry: Entry, index: usize) bio.ReaderError!u32 {
    if (index >= entry.count) return error.InvalidFormat;
    const type_size: usize = switch (entry.field_type) {
        1, 2 => 1,
        3 => 2,
        4 => 4,
        else => return error.UnsupportedVariant,
    };
    const total_size = std.math.mul(usize, type_size, entry.count) catch return error.UnsupportedVariant;
    const value_base = if (total_size <= 4) entry.value_field_offset else try checkedUsize(entry.value_offset);
    const value_offset = std.math.add(usize, value_base, std.math.mul(usize, type_size, index) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (value_offset > data.len or data.len - value_offset < type_size) return error.TruncatedData;
    return switch (entry.field_type) {
        1, 2 => data[value_offset],
        3 => readU16(order, data[value_offset..][0..2]),
        4 => readU32(order, data[value_offset..][0..4]),
        else => unreachable,
    };
}

fn nextIfdOffset(data: []const u8, order: ByteOrder, ifd_offset_u32: u32) bio.ReaderError!u32 {
    const ifd_offset = try checkedUsize(ifd_offset_u32);
    if (ifd_offset > data.len or data.len - ifd_offset < 2) return error.TruncatedData;
    const entry_count = readU16(order, data[ifd_offset..][0..2]);
    const next_pos = ifd_offset + 2 + @as(usize, entry_count) * 12;
    if (next_pos > data.len or data.len - next_pos < 4) return error.TruncatedData;
    return readU32(order, data[next_pos..][0..4]);
}

fn pixelType(bits_per_sample: u16) bio.PixelType {
    return if (bits_per_sample == 8) .uint8 else .uint16;
}

fn byteOrder(data: []const u8) bio.ReaderError!ByteOrder {
    if (data.len < 8) return error.InvalidFormat;
    if (data[0] == 'I' and data[1] == 'I') return .little;
    if (data[0] == 'M' and data[1] == 'M') return .big;
    return error.InvalidFormat;
}

fn readU16(order: ByteOrder, bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], if (order == .little) .little else .big);
}

fn readU32(order: ByteOrder, bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], if (order == .little) .little else .big);
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

fn appendEntry(list: *std.ArrayList(u8), tag: u16, field_type: u16, count: u32, value: u32) !void {
    try appendU16Le(list, tag);
    try appendU16Le(list, field_type);
    try appendU32Le(list, count);
    try appendU32Le(list, value);
}

fn appendMetadataIfd(list: *std.ArrayList(u8), next_ifd_offset: u32) !void {
    const xml = "<Assay><Imaging /></Assay>\x00";
    const entry_count = 2;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    try appendU16Le(list, entry_count);
    try appendEntry(list, channel_count_tag, 4, 1, 2);
    try appendEntry(list, metadata_xml_tag, 2, xml.len, ifd_end);
    try appendU32Le(list, next_ifd_offset);
    try list.appendSlice(std.testing.allocator, xml);
}

test "reads flowsight bitmask channels from first image ifd" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const first_entry_count = 2;
    const first_ifd_end = 8 + 2 + first_entry_count * 12 + 4;
    const xml = "<Assay><Imaging /></Assay>\x00";
    const second_ifd_offset = first_ifd_end + xml.len;
    try appendMetadataIfd(&data, @intCast(second_ifd_offset));

    const entry_count = 8;
    const ifd_end = second_ifd_offset + 2 + entry_count * 12 + 4;
    const pixel_offset = ifd_end;
    try appendU16Le(&data, entry_count);
    try appendEntry(&data, 256, 4, 1, 4);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 1, 8);
    try appendEntry(&data, 259, 3, 1, bitmask_compression);
    try appendEntry(&data, 273, 4, 1, @intCast(pixel_offset));
    try appendEntry(&data, 279, 4, 1, 8);
    try appendEntry(&data, channel_count_tag, 4, 1, 2);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendU32Le(&data, 0);
    try data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0, 3, 0, 4, 0 });

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("flowsight", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, plane.data);

    const region = try readRegionIndex(std.testing.allocator, data.items, 0, .{ .x = 1, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(region.data);
    try std.testing.expectEqualSlices(u8, &.{2}, region.data);
}

test "reads flowsight greyscale plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const first_entry_count = 2;
    const first_ifd_end = 8 + 2 + first_entry_count * 12 + 4;
    const xml = "<Assay><Imaging /></Assay>\x00";
    const second_ifd_offset = first_ifd_end + xml.len;
    try appendMetadataIfd(&data, @intCast(second_ifd_offset));

    const entry_count = 8;
    const ifd_end = second_ifd_offset + 2 + entry_count * 12 + 4;
    const pixel_offset = ifd_end;
    try appendU16Le(&data, entry_count);
    try appendEntry(&data, 256, 4, 1, 2);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 1, 16);
    try appendEntry(&data, 259, 3, 1, greyscale_compression);
    try appendEntry(&data, 273, 4, 1, @intCast(pixel_offset));
    try appendEntry(&data, 279, 4, 1, 1);
    try appendEntry(&data, channel_count_tag, 4, 1, 1);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendU32Le(&data, 0);
    try data.append(std.testing.allocator, 0);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.uint16, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, plane.data);
}
