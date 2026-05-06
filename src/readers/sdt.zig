const std = @import("std");
const bio = @import("../root.zig");

const header_len = 42;
const block_header_len = 22;
const header_valid: u16 = 0x5555;
const header_not_valid: u16 = 0x1111;
const binary_setup = "BIN_PARA_BEGIN:\x00";

const Header = struct {
    info_offset: usize,
    info_len: usize,
    setup_offset: usize,
    setup_len: usize,
    data_block_offset: usize,
    block_count: u32,
    measure_offset: usize,
    measure_count: u16,
    measure_len: usize,
};

const Block = struct {
    data_offset: usize,
    next_offset: usize,
    length: usize,
};

const ZipEntry = struct {
    method: u16,
    payload: []const u8,
};

const Parsed = struct {
    width: u32,
    height: u32,
    time_bins: u16,
    channels: u16,
    timepoints: u16,
    increment: u16,
    data_block_offset: usize,
    separate_channel_blocks: bool,
    block: Block,
};

pub fn matches(data: []const u8) bool {
    _ = parseHeader(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const parsed = try parse(data);
    const plane_count = std.math.mul(u32, parsed.channels, std.math.mul(u32, parsed.time_bins, parsed.timepoints) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    return .{
        .format = "sdt",
        .width = parsed.width,
        .height = parsed.height,
        .size_c = parsed.channels,
        .samples_per_pixel = 1,
        .size_z = 1,
        .size_t = @intCast(std.math.mul(u32, parsed.time_bins, parsed.timepoints) catch return error.UnsupportedVariant),
        .pixel_type = .uint16,
        .little_endian = true,
        .plane_count = plane_count,
        .dimension_order = "XYZTC",
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const parsed = try parse(data);
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const times = parsed.time_bins;
    const slab = plane_index / times;
    const time_bin = plane_index % times;
    if (slab >= @as(u32, parsed.channels) * @as(u32, parsed.timepoints)) return error.InvalidPlaneIndex;
    const block = if (parsed.separate_channel_blocks)
        try parseBlockAt(data, parsed.data_block_offset, slab)
    else
        parsed.block;
    if (block.data_offset > data.len or data.len - block.data_offset < block.length) return error.TruncatedData;
    const block_data = data[block.data_offset..][0..block.length];

    const bytes_per_sample = 2;
    var padded_width = paddedWidth(parsed.width);
    var plane_stride = std.math.mul(usize, padded_width, parsed.height) catch return error.UnsupportedVariant;
    plane_stride = std.math.mul(usize, plane_stride, times) catch return error.UnsupportedVariant;
    plane_stride = std.math.mul(usize, plane_stride, bytes_per_sample) catch return error.UnsupportedVariant;
    const padded_all_channels = std.math.mul(usize, plane_stride, parsed.channels) catch return error.UnsupportedVariant;
    if (padded_width > parsed.width and padded_all_channels > parsed.block.length) {
        const unpadded_stride = std.math.mul(usize, parsed.width, parsed.height) catch return error.UnsupportedVariant;
        const unpadded_time_stride = std.math.mul(usize, unpadded_stride, times) catch return error.UnsupportedVariant;
        const unpadded_plane_stride = std.math.mul(usize, unpadded_time_stride, bytes_per_sample) catch return error.UnsupportedVariant;
        const unpadded_all_channels = std.math.mul(usize, unpadded_plane_stride, parsed.channels) catch return error.UnsupportedVariant;
        if (unpadded_all_channels <= parsed.block.length) {
            padded_width = parsed.width;
            plane_stride = unpadded_plane_stride;
        }
    }
    const channel_offset = if (parsed.separate_channel_blocks) 0 else std.math.mul(usize, slab, plane_stride) catch return error.UnsupportedVariant;
    if (channel_offset > block_data.len or block_data.len - channel_offset < plane_stride) return error.TruncatedData;

    const out_len = try planeByteCount(metadata);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    if (parseZipEntry(block_data)) |zip| {
        try copyZippedPlane(allocator, zip, parsed, channel_offset, time_bin, out);
        return .{ .metadata = metadata, .data = out };
    } else |_| {}

    var row: usize = 0;
    while (row < parsed.height) : (row += 1) {
        var col: usize = 0;
        while (col < parsed.width) : (col += 1) {
            const src_sample = std.math.add(usize, channel_offset, (((row * padded_width + col) * times + time_bin) * bytes_per_sample)) catch return error.UnsupportedVariant;
            const dst_sample = (row * parsed.width + col) * bytes_per_sample;
            if (src_sample > block_data.len or block_data.len - src_sample < bytes_per_sample) return error.TruncatedData;
            var value = readU16(block_data[src_sample..][0..2]);
            if (parsed.increment > 1) value /= parsed.increment;
            std.mem.writeInt(u16, out[dst_sample..][0..2], value, .little);
        }
    }
    return .{ .metadata = metadata, .data = out };
}

fn parse(data: []const u8) bio.ReaderError!Parsed {
    const header = try parseHeader(data);
    const setup = try setupSlice(data, header);
    var dims = parseSetupDimensions(setup);
    const measure = parseMeasure(data, header);
    if (measure.width > 0) dims.width = measure.width;
    if (measure.height > 0) dims.height = measure.height;
    if (measure.time_bins > 0) dims.time_bins = measure.time_bins;
    if (measure.channels > 0) dims.channels = measure.channels;
    var timepoints = measure.timepoints;
    if (timepoints == 0) timepoints = 1;
    var increment = measure.increment;
    if (increment == 0) increment = 1;
    if (dims.width == 0 or dims.height == 0 or dims.time_bins == 0) return error.InvalidFormat;
    if (dims.channels == 0) dims.channels = 1;
    const block = try parseFirstBlock(data, header.data_block_offset);
    const bytes_per_sample = 2;
    const pixels = std.math.mul(usize, dims.width, dims.height) catch return error.UnsupportedVariant;
    const bin_bytes = std.math.mul(usize, pixels, bytes_per_sample) catch return error.UnsupportedVariant;
    if (bin_bytes == 0) return error.InvalidFormat;
    const bins_in_first_block = block.length / bin_bytes;
    if (bins_in_first_block > 0 and bins_in_first_block < dims.time_bins) dims.time_bins = @intCast(bins_in_first_block);
    return .{
        .width = dims.width,
        .height = dims.height,
        .time_bins = try u16FromU32(dims.time_bins),
        .channels = try u16FromU32(dims.channels),
        .timepoints = try u16FromU32(timepoints),
        .increment = try u16FromU32(increment),
        .data_block_offset = header.data_block_offset,
        .separate_channel_blocks = measure.separate_channel_blocks,
        .block = block,
    };
}

fn copyZippedPlane(
    allocator: std.mem.Allocator,
    zip: ZipEntry,
    parsed: Parsed,
    channel_offset: usize,
    time_bin: u32,
    out: []u8,
) bio.ReaderError!void {
    const bytes_per_sample = 2;
    const padded_width = paddedWidth(parsed.width);
    const row_bytes = std.math.mul(usize, padded_width, parsed.time_bins) catch return error.UnsupportedVariant;
    const zipped_row_bytes = std.math.mul(usize, row_bytes, bytes_per_sample) catch return error.UnsupportedVariant;
    const row_buf = try allocator.alloc(u8, zipped_row_bytes);
    defer allocator.free(row_buf);

    if (zip.method == 0) {
        if (channel_offset > zip.payload.len) return error.TruncatedData;
        var offset = channel_offset;
        var row: usize = 0;
        while (row < parsed.height) : (row += 1) {
            if (offset > zip.payload.len or zip.payload.len - offset < zipped_row_bytes) return error.TruncatedData;
            copySdtRow(zip.payload[offset..][0..zipped_row_bytes], parsed, time_bin, out, row);
            offset += zipped_row_bytes;
        }
        return;
    }

    if (zip.method != 8) return error.UnsupportedVariant;
    var input = std.Io.Reader.fixed(zip.payload);
    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&input, .raw, &buffer);
    try discardReader(&decompressor.reader, channel_offset);
    var row: usize = 0;
    while (row < parsed.height) : (row += 1) {
        decompressor.reader.readSliceAll(row_buf) catch return error.TruncatedData;
        copySdtRow(row_buf, parsed, time_bin, out, row);
    }
}

fn copySdtRow(row_buf: []const u8, parsed: Parsed, time_bin: u32, out: []u8, row: usize) void {
    const bytes_per_sample = 2;
    var col: usize = 0;
    while (col < parsed.width) : (col += 1) {
        const src_sample = ((col * parsed.time_bins + time_bin) * bytes_per_sample);
        const dst_sample = (row * parsed.width + col) * bytes_per_sample;
        @memcpy(out[dst_sample..][0..bytes_per_sample], row_buf[src_sample..][0..bytes_per_sample]);
    }
}

fn discardReader(reader: *std.Io.Reader, amount: usize) bio.ReaderError!void {
    var scratch: [4096]u8 = undefined;
    var remaining = amount;
    while (remaining != 0) {
        const chunk = @min(remaining, scratch.len);
        reader.readSliceAll(scratch[0..chunk]) catch return error.TruncatedData;
        remaining -= chunk;
    }
}

fn parseZipEntry(data: []const u8) bio.ReaderError!ZipEntry {
    if (data.len < 30 or !std.mem.eql(u8, data[0..4], "PK\x03\x04")) return error.InvalidFormat;
    const method = readU16(data[8..10]);
    const compressed_size = try usizeFromU32(readU32(data[18..22]));
    const name_len: usize = readU16(data[26..28]);
    const extra_len: usize = readU16(data[28..30]);
    const payload_offset = std.math.add(usize, 30, std.math.add(usize, name_len, extra_len) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
    if (payload_offset > data.len) return error.TruncatedData;
    const available = data.len - payload_offset;
    const payload_len = if (compressed_size != 0 and compressed_size <= available) compressed_size else available;
    return .{ .method = method, .payload = data[payload_offset..][0..payload_len] };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_len) return error.TruncatedData;
    const info_offset = try usizeFromI32(readI32(data[2..6]));
    const info_len = readU16(data[6..8]);
    const setup_offset = try usizeFromI32(readI32(data[8..12]));
    const setup_len = readU16(data[12..14]);
    const data_block_offset = try usizeFromI32(readI32(data[14..18]));
    const no_of_data_blocks = readU16(data[18..20]);
    const measure_offset = try usizeFromI32(readI32(data[24..28]));
    const measure_count = readU16(data[28..30]);
    const measure_len = readU16(data[30..32]);
    const valid = readU16(data[32..34]);
    const reserved1 = readU32(data[34..38]);
    const block_count: u32 = if (no_of_data_blocks == 0x7fff) reserved1 else no_of_data_blocks;
    if (valid != header_valid and valid != header_not_valid) return error.InvalidFormat;
    if (block_count == 0) return error.InvalidFormat;
    if (!validRange(data.len, info_offset, info_len)) return error.TruncatedData;
    if (!validRange(data.len, setup_offset, setup_len)) return error.TruncatedData;
    if (data_block_offset > data.len or data.len - data_block_offset < block_header_len) return error.TruncatedData;
    if (measure_count > 0 and !validRange(data.len, measure_offset, measure_len)) return error.TruncatedData;
    return .{
        .info_offset = info_offset,
        .info_len = info_len,
        .setup_offset = setup_offset,
        .setup_len = setup_len,
        .data_block_offset = data_block_offset,
        .block_count = block_count,
        .measure_offset = measure_offset,
        .measure_count = measure_count,
        .measure_len = measure_len,
    };
}

fn setupSlice(data: []const u8, header: Header) bio.ReaderError![]const u8 {
    const setup = data[header.setup_offset..][0..header.setup_len];
    if (std.mem.indexOf(u8, setup, binary_setup)) |index| {
        return setup[0..index];
    }
    return setup;
}

const SetupDimensions = struct {
    width: u32 = 0,
    height: u32 = 0,
    time_bins: u32 = 0,
    channels: u32 = 0,
};

fn parseSetupDimensions(setup: []const u8) SetupDimensions {
    return .{
        .width = parseTaggedU32(setup, "#SP [SP_SCAN_X,I,") orelse parseTaggedU32(setup, "#SP [SP_IMG_X,I,") orelse 0,
        .height = parseTaggedU32(setup, "#SP [SP_SCAN_Y,I,") orelse parseTaggedU32(setup, "#SP [SP_IMG_Y,I,") orelse 0,
        .time_bins = parseTaggedU32(setup, "#SP [SP_ADC_RE,I,") orelse 0,
        .channels = parseTaggedU32(setup, "#SP [SP_SCAN_RX,I,") orelse 1,
    };
}

fn parseTaggedU32(text: []const u8, prefix: []const u8) ?u32 {
    const start = std.mem.indexOf(u8, text, prefix) orelse return null;
    const digits_start = start + prefix.len;
    const end = std.mem.indexOfScalarPos(u8, text, digits_start, ']') orelse return null;
    return std.fmt.parseUnsigned(u32, std.mem.trim(u8, text[digits_start..end], " \t\r\n"), 10) catch null;
}

const Measure = struct {
    width: u32 = 0,
    height: u32 = 0,
    time_bins: u32 = 0,
    channels: u32 = 0,
    timepoints: u32 = 0,
    increment: u32 = 1,
    separate_channel_blocks: bool = false,
};

fn parseMeasure(data: []const u8, header: Header) Measure {
    if (header.measure_count == 0 or header.measure_len < 211) return .{};
    const measure = data[header.measure_offset..][0..header.measure_len];
    const meas_mode = readI16(measure[36..38]);
    const adc_re = readI16(measure[82..84]);
    const stop_t = readI16(measure[100..102]);
    const incr = readI16(measure[113..115]);
    const scan_x = readI32(measure[173..177]);
    const scan_y = readI32(measure[177..181]);
    const scan_rx = readI32(measure[181..185]);
    var parsed = Measure{
        .width = positiveI32(scan_x),
        .height = positiveI32(scan_y),
        .time_bins = positiveI32(adc_re),
        .channels = positiveI32(scan_rx),
        .timepoints = positiveI32(stop_t),
        .increment = positiveI32(incr),
    };
    if (meas_mode == 0 or meas_mode == 1) {
        parsed.width = 1;
        parsed.height = 1;
    } else if (meas_mode == 13) {
        parsed.channels = header.measure_count;
        parsed.separate_channel_blocks = true;
    }
    return parsed;
}

fn parseFirstBlock(data: []const u8, offset: usize) bio.ReaderError!Block {
    return parseBlockAt(data, offset, 0);
}

fn parseBlockAt(data: []const u8, offset: usize, index: u32) bio.ReaderError!Block {
    var block_offset = offset;
    var i: u32 = 0;
    while (i < index) : (i += 1) {
        if (block_offset > data.len or data.len - block_offset < block_header_len) return error.TruncatedData;
        block_offset = try usizeFromI32(readI32(data[block_offset + 6 .. block_offset + 10]));
    }
    return parseBlockAtOffset(data, block_offset);
}

fn parseBlockAtOffset(data: []const u8, offset: usize) bio.ReaderError!Block {
    if (offset > data.len or data.len - offset < block_header_len) return error.TruncatedData;
    const data_offset = offset + block_header_len;
    const next_offset = try usizeFromI32(readI32(data[offset + 6 .. offset + 10]));
    var length = try usizeFromU32(readU32(data[offset + 18 .. offset + 22]));
    if (data_offset <= next_offset and next_offset <= data.len and length > next_offset - data_offset) {
        length = next_offset - data_offset;
    }
    if (data_offset > data.len or data.len - data_offset < length) return error.TruncatedData;
    return .{ .data_offset = data_offset, .next_offset = next_offset, .length = length };
}

fn validRange(total: usize, offset: usize, len: usize) bool {
    return offset <= total and len <= total - offset;
}

fn paddedWidth(width: u32) u32 {
    return width + ((4 - (width % 4)) % 4);
}

fn positiveI32(value: i32) u32 {
    if (value <= 0) return 0;
    return @intCast(value);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn usizeFromI32(value: i32) bio.ReaderError!usize {
    if (value < 0) return error.InvalidFormat;
    return @intCast(value);
}

fn usizeFromU32(value: u32) bio.ReaderError!usize {
    if (value > std.math.maxInt(usize)) return error.UnsupportedVariant;
    return @intCast(value);
}

fn u16FromU32(value: u32) bio.ReaderError!u16 {
    if (value == 0 or value > std.math.maxInt(u16)) return error.UnsupportedVariant;
    return @intCast(value);
}

fn readI16(bytes: []const u8) i16 {
    return std.mem.readInt(i16, bytes[0..2], .little);
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readI32(bytes: []const u8) i32 {
    return std.mem.readInt(i32, bytes[0..4], .little);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn appendU16(list: *std.ArrayList(u8), value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendI16(list: *std.ArrayList(u8), value: i16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(i16, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendU32(list: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn appendI32(list: *std.ArrayList(u8), value: i32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &bytes, value, .little);
    try list.appendSlice(std.testing.allocator, &bytes);
}

fn patchU16(data: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, data[offset..][0..2], value, .little);
}

fn patchI32(data: []u8, offset: usize, value: i32) void {
    std.mem.writeInt(i32, data[offset..][0..4], value, .little);
}

fn appendHeader(list: *std.ArrayList(u8), setup: []const u8, measure_len: usize, block_len: usize) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_len);
    const info_offset = header_len;
    try list.appendSlice(std.testing.allocator, "SDT fixture\n");
    const setup_offset = list.items.len;
    try list.appendSlice(std.testing.allocator, setup);
    const measure_offset = list.items.len;
    if (measure_len > 0) try list.appendNTimes(std.testing.allocator, 0, measure_len);
    const block_offset = list.items.len;
    try list.appendNTimes(std.testing.allocator, 0, block_header_len);

    patchU16(list.items, 0, 0x10);
    patchI32(list.items, 2, @intCast(info_offset));
    patchU16(list.items, 6, 12);
    patchI32(list.items, 8, @intCast(setup_offset));
    patchU16(list.items, 12, @intCast(setup.len));
    patchI32(list.items, 14, @intCast(block_offset));
    patchU16(list.items, 18, 1);
    patchI32(list.items, 20, @intCast(block_len));
    patchI32(list.items, 24, @intCast(measure_offset));
    patchU16(list.items, 28, if (measure_len > 0) 1 else 0);
    patchU16(list.items, 30, @intCast(measure_len));
    patchU16(list.items, 32, header_valid);

    patchI32(list.items, block_offset + 2, 0);
    patchI32(list.items, block_offset + 6, @intCast(block_offset + block_header_len + block_len));
    patchU16(list.items, block_offset + 10, 0);
    patchI32(list.items, block_offset + 14, 0);
    patchI32(list.items, block_offset + 18, @intCast(block_len));
}

fn appendSdt(list: *std.ArrayList(u8), width: u32, height: u32, time_bins: u32, channels: u32, pixels: []const u8) !void {
    const setup = try std.fmt.allocPrint(
        std.testing.allocator,
        "#SP [SP_SCAN_X,I,{d}]\n#SP [SP_SCAN_Y,I,{d}]\n#SP [SP_ADC_RE,I,{d}]\n#SP [SP_SCAN_RX,I,{d}]\n",
        .{ width, height, time_bins, channels },
    );
    defer std.testing.allocator.free(setup);
    try appendHeader(list, setup, 0, pixels.len);
    try list.appendSlice(std.testing.allocator, pixels);
}

test "reads sdt lifetime bins as planes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendSdt(&data, 2, 1, 2, 1, &.{
        1, 0, 10, 0,
        2, 0, 20, 0,
    });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 20, 0 }, plane.data);
}

test "reads sdt second channel" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendSdt(&data, 1, 1, 1, 2, &.{
        5, 0,
        9, 0,
    });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 9, 0 }, plane.data);
}

test "reads sdt dimensions from measure block" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendHeader(&data, "", 211, 2);
    const measure_offset = std.mem.readInt(i32, data.items[24..28], .little);
    patchI32(data.items, @intCast(measure_offset + 173), 1);
    patchI32(data.items, @intCast(measure_offset + 177), 1);
    patchI32(data.items, @intCast(measure_offset + 181), 1);
    std.mem.writeInt(i16, data.items[@intCast(measure_offset + 82)..][0..2], 1, .little);
    std.mem.writeInt(i16, data.items[@intCast(measure_offset + 113)..][0..2], 2, .little);
    try data.appendSlice(std.testing.allocator, &.{ 8, 0 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 4, 0 }, plane.data);
}

fn appendStoredZip(list: *std.ArrayList(u8), name: []const u8, payload: []const u8) !void {
    try list.appendSlice(std.testing.allocator, "PK\x03\x04");
    try appendU16(list, 20);
    try appendU16(list, 0);
    try appendU16(list, 0);
    try appendU16(list, 0);
    try appendU16(list, 0);
    try appendU32(list, 0);
    try appendU32(list, @intCast(payload.len));
    try appendU32(list, @intCast(payload.len));
    try appendU16(list, @intCast(name.len));
    try appendU16(list, 0);
    try list.appendSlice(std.testing.allocator, name);
    try list.appendSlice(std.testing.allocator, payload);
}

test "reads stored zipped sdt block" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    var zip: std.ArrayList(u8) = .empty;
    defer zip.deinit(std.testing.allocator);
    try appendStoredZip(&zip, "data_block", &.{ 8, 0, 0, 0, 0, 0, 0, 0 });
    try appendSdt(&data, 1, 1, 1, 1, zip.items);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 8, 0 }, plane.data);
}
