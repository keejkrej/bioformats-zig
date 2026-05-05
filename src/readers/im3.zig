const std = @import("std");
const bio = @import("../root.zig");

const cookie: u32 = 1985;
const rec_container: u32 = 0;
const rec_image: u32 = 1;
const rec_int: u32 = 6;

const field_data_set = "DataSet";
const field_shape = "Shape";
const field_data = "Data";

const Record = struct {
    name: []const u8,
    rec_type: u32,
    offset: usize,
    length: usize,
    next: usize,
};

const Layout = struct {
    width: u32,
    height: u32,
    channels: u16,
    data_offset: usize,
};

pub fn matches(data: []const u8) bool {
    return findLayout(data) != null;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const layout = findLayout(data) orelse return error.InvalidFormat;
    return .{
        .format = "im3",
        .width = layout.width,
        .height = layout.height,
        .size_c = layout.channels,
        .samples_per_pixel = 1,
        .pixel_type = .uint16,
        .little_endian = true,
        .plane_count = layout.channels,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const layout = findLayout(data) orelse return error.InvalidFormat;
    const pixel_count = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, pixel_count, 2) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    copyChannel(data, layout, @intCast(plane_index), .{ .x = 0, .y = 0, .width = metadata.width, .height = metadata.height }, out);
    return .{ .metadata = metadata, .data = out };
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    try region.validate(metadata);
    const layout = findLayout(data) orelse return error.InvalidFormat;
    const pixel_count = std.math.mul(usize, region.width, region.height) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, pixel_count, 2) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    copyChannel(data, layout, @intCast(plane_index), region, out);
    return .{ .metadata = metadata, .data = out };
}

fn findLayout(data: []const u8) ?Layout {
    if (data.len < 4) return null;
    const file_cookie = readU32(data, 0) catch return null;
    if (file_cookie != cookie) return null;
    var position: usize = 4;
    var seen: usize = 0;
    while (position < data.len and seen < 256) : (seen += 1) {
        const record = parseRecord(data, position) catch return null;
        if (record.rec_type == rec_container) {
            if (findLayoutInContainer(data, record)) |layout| return layout;
        }
        if (record.next <= position) return null;
        position = record.next;
    }
    return null;
}

fn findLayoutInContainer(data: []const u8, container: Record) ?Layout {
    if (container.rec_type != rec_container or container.length < 8) return null;
    var position = container.offset + 8;
    const end = checkedAdd(container.offset, container.length) catch return null;
    var seen: usize = 0;
    while (position < end and seen < 256) : (seen += 1) {
        const record = parseRecordIn(data, position, end) catch return null;
        if (record.rec_type == rec_container) {
            if (std.mem.eql(u8, record.name, field_data_set)) {
                if (findDatasetChild(data, record)) |layout| return layout;
            }
            if (findLayoutInContainer(data, record)) |layout| return layout;
        }
        if (record.next <= position) return null;
        position = record.next;
    }
    return null;
}

fn findDatasetChild(data: []const u8, data_set: Record) ?Layout {
    if (data_set.length < 8) return null;
    var position = data_set.offset + 8;
    const end = checkedAdd(data_set.offset, data_set.length) catch return null;
    var seen: usize = 0;
    while (position < end and seen < 256) : (seen += 1) {
        const record = parseRecordIn(data, position, end) catch return null;
        if (record.rec_type == rec_container) {
            if (parseDataset(data, record)) |layout| return layout;
        }
        if (record.next <= position) return null;
        position = record.next;
    }
    return null;
}

fn parseDataset(data: []const u8, dataset: Record) ?Layout {
    if (dataset.length < 8) return null;
    var width: ?u32 = null;
    var height: ?u32 = null;
    var channels: ?u16 = null;
    var data_offset: ?usize = null;

    var position = dataset.offset + 8;
    const end = checkedAdd(dataset.offset, dataset.length) catch return null;
    var seen: usize = 0;
    while (position < end and seen < 256) : (seen += 1) {
        const record = parseRecordIn(data, position, end) catch return null;
        if (record.rec_type == rec_int and std.mem.eql(u8, record.name, field_shape)) {
            width = intEntry(data, record, 0) catch return null;
            height = intEntry(data, record, 1) catch return null;
            const c = intEntry(data, record, 2) catch return null;
            if (c == 0 or c > std.math.maxInt(u16)) return null;
            channels = @intCast(c);
        } else if (record.rec_type == rec_image and std.mem.eql(u8, record.name, field_data)) {
            if (record.length < 16) return null;
            const image_width = readU32(data, record.offset + 4) catch return null;
            const image_height = readU32(data, record.offset + 8) catch return null;
            const image_channels = readU32(data, record.offset + 12) catch return null;
            if (image_width == 0 or image_height == 0 or image_channels == 0 or image_channels > std.math.maxInt(u16)) return null;
            width = width orelse image_width;
            height = height orelse image_height;
            channels = channels orelse @as(u16, @intCast(image_channels));
            data_offset = record.offset + 16;
        }
        if (record.next <= position) return null;
        position = record.next;
    }

    const w = width orelse return null;
    const h = height orelse return null;
    const c = channels orelse return null;
    const offset = data_offset orelse return null;
    const values = std.math.mul(usize, w, h) catch return null;
    const samples = std.math.mul(usize, values, c) catch return null;
    const bytes = std.math.mul(usize, samples, 2) catch return null;
    if (offset > data.len or data.len - offset < bytes) return null;
    return .{ .width = w, .height = h, .channels = c, .data_offset = offset };
}

fn parseRecord(data: []const u8, offset: usize) bio.ReaderError!Record {
    return parseRecordIn(data, offset, data.len);
}

fn parseRecordIn(data: []const u8, offset: usize, limit: usize) bio.ReaderError!Record {
    if (offset > limit or limit > data.len or limit - offset < 12) return error.TruncatedData;
    const name_len = try checkedUsize(try readU32(data, offset));
    var position = offset + 4;
    if (name_len > limit - position) return error.TruncatedData;
    const name = data[position..][0..name_len];
    position += name_len;
    if (limit - position < 8) return error.TruncatedData;
    const record_len = try checkedUsize(try readU32(data, position));
    position += 4;
    if (record_len < 8) return error.InvalidFormat;
    const rec_type = try readU32(data, position);
    position += 4;
    const content_len = record_len - 8;
    if (content_len > limit - position) return error.TruncatedData;
    return .{
        .name = name,
        .rec_type = rec_type,
        .offset = position,
        .length = content_len,
        .next = position + content_len,
    };
}

fn intEntry(data: []const u8, record: Record, index: usize) bio.ReaderError!u32 {
    if (record.length < 8) return error.TruncatedData;
    const code = try readU32(data, record.offset);
    if (code == 0) {
        if (index != 0) return error.InvalidFormat;
        return readU32(data, record.offset + 4);
    }
    const count = try readU32(data, record.offset + 4);
    if (index >= count) return error.InvalidFormat;
    const value_offset = record.offset + 8 + index * 4;
    const end = try checkedAdd(record.offset, record.length);
    if (value_offset > end or end - value_offset < 4) return error.TruncatedData;
    return readU32(data, value_offset);
}

fn copyChannel(data: []const u8, layout: Layout, channel: usize, region: bio.Region, out: []u8) void {
    const channels = @as(usize, layout.channels);
    var dest: usize = 0;
    var row: u32 = 0;
    while (row < region.height) : (row += 1) {
        var col: u32 = 0;
        while (col < region.width) : (col += 1) {
            const x = region.x + col;
            const y = region.y + row;
            const sample_index = (@as(usize, y) * layout.width + x) * channels + channel;
            const src = layout.data_offset + sample_index * 2;
            out[dest] = data[src];
            out[dest + 1] = data[src + 1];
            dest += 2;
        }
    }
}

fn readU32(data: []const u8, offset: usize) bio.ReaderError!u32 {
    if (offset > data.len or data.len - offset < 4) return error.TruncatedData;
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn checkedUsize(value: u32) bio.ReaderError!usize {
    return @intCast(value);
}

fn checkedAdd(a: usize, b: usize) bio.ReaderError!usize {
    return std.math.add(usize, a, b) catch error.UnsupportedVariant;
}

fn appendU32Le(list: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn beginRecord(list: *std.ArrayList(u8), name: []const u8, rec_type: u32, content_len: usize) !void {
    try appendU32Le(list, @intCast(name.len));
    try list.appendSlice(std.testing.allocator, name);
    try appendU32Le(list, @intCast(content_len + 8));
    try appendU32Le(list, rec_type);
}

fn appendIntArrayRecord(list: *std.ArrayList(u8), name: []const u8, values: []const u32) !void {
    try beginRecord(list, name, rec_int, 8 + values.len * 4);
    try appendU32Le(list, 1);
    try appendU32Le(list, @intCast(values.len));
    for (values) |value| try appendU32Le(list, value);
}

fn appendImageRecord(list: *std.ArrayList(u8), name: []const u8, width: u32, height: u32, channels: u32, pixels: []const u8) !void {
    try beginRecord(list, name, rec_image, 16 + pixels.len);
    try appendU32Le(list, 0);
    try appendU32Le(list, width);
    try appendU32Le(list, height);
    try appendU32Le(list, channels);
    try list.appendSlice(std.testing.allocator, pixels);
}

fn appendContainerRecord(list: *std.ArrayList(u8), name: []const u8, payload: []const u8) !void {
    try beginRecord(list, name, rec_container, 8 + payload.len);
    try list.appendNTimes(std.testing.allocator, 0, 8);
    try list.appendSlice(std.testing.allocator, payload);
}

fn appendTinyIm3(list: *std.ArrayList(u8)) !void {
    try appendU32Le(list, cookie);

    var dataset_payload: std.ArrayList(u8) = .empty;
    defer dataset_payload.deinit(std.testing.allocator);
    try appendIntArrayRecord(&dataset_payload, field_shape, &.{ 2, 1, 2 });
    try appendImageRecord(&dataset_payload, field_data, 2, 1, 2, &.{
        1, 0, 10, 0,
        2, 0, 20, 0,
    });

    var unnamed_dataset: std.ArrayList(u8) = .empty;
    defer unnamed_dataset.deinit(std.testing.allocator);
    try appendContainerRecord(&unnamed_dataset, "", dataset_payload.items);

    var data_set_payload: std.ArrayList(u8) = .empty;
    defer data_set_payload.deinit(std.testing.allocator);
    try data_set_payload.appendSlice(std.testing.allocator, unnamed_dataset.items);

    var top_payload: std.ArrayList(u8) = .empty;
    defer top_payload.deinit(std.testing.allocator);
    try appendContainerRecord(&top_payload, field_data_set, data_set_payload.items);

    try appendContainerRecord(list, "", top_payload.items);
}

test "reads im3 channel planes from data set records" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendTinyIm3(&data);

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("im3", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const first = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(first.data);
    try std.testing.expectEqualStrings("im3", first.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, first.data);

    const second = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 20, 0 }, second.data);

    const region = try readRegionIndex(std.testing.allocator, data.items, 1, .{
        .x = 1,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region.data);
    try std.testing.expectEqualSlices(u8, &.{ 20, 0 }, region.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "rejects cookie without dataset records" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendU32Le(&data, cookie);
    try std.testing.expect(!matches(data.items));
}
