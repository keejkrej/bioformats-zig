const std = @import("std");
const bio = @import("../root.zig");

const signature = "\x89PNG\r\n\x1a\n";

const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    compression: u8,
    filter: u8,
    interlace: u8,
};

pub fn matches(data: []const u8) bool {
    return data.len >= signature.len and std.mem.eql(u8, data[0..signature.len], signature);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    try validateHeader(header);
    const transparency = try hasTransparency(data, header.color_type);
    return .{
        .format = "png",
        .width = header.width,
        .height = header.height,
        .size_c = outputSamplesPerPixel(header.color_type, transparency),
        .samples_per_pixel = outputSamplesPerPixel(header.color_type, transparency),
        .pixel_type = switch (header.color_type) {
            0 => if (transparency) if (header.bit_depth == 16) .rgba16 else .rgba8 else if (header.bit_depth == 16) .uint16 else .uint8,
            2 => if (transparency) if (header.bit_depth == 16) .rgba16 else .rgba8 else if (header.bit_depth == 16) .rgb16 else .rgb8,
            3 => if (transparency) .rgba8 else .rgb8,
            4 => if (header.bit_depth == 16) .rgba16 else .rgba8,
            6 => if (header.bit_depth == 16) .rgba16 else .rgba8,
            else => return error.UnsupportedVariant,
        },
        .little_endian = false,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const header = try parseHeader(data);
    try validateHeader(header);
    const metadata = try readMetadata(data);
    const raw_channels = rawSamplesPerPixel(header.color_type);
    const channels = metadata.samples_per_pixel;
    const raw_bytes_per_pixel = filterBytesPerPixel(header, raw_channels);
    const bytes_per_pixel = @as(usize, channels) * bytesPerSample(header);
    const raw_row_bytes = try rawRowBytes(header, raw_channels);
    const row_bytes = std.math.mul(usize, header.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const decoded_len = if (header.interlace == 0)
        std.math.mul(usize, std.math.add(usize, raw_row_bytes, 1) catch return error.UnsupportedVariant, header.height) catch return error.UnsupportedVariant
    else
        try adam7DecodedLen(header, raw_channels);

    const payloads = try collectPayloads(allocator, data, header.color_type);
    defer allocator.free(payloads.idat);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try decodeZlib(payloads.idat, decoded);

    const out_len = std.math.mul(usize, row_bytes, header.height) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    if (header.color_type == 3) {
        const packed_len = std.math.mul(usize, raw_row_bytes, header.height) catch return error.UnsupportedVariant;
        const packed_indices = try allocator.alloc(u8, packed_len);
        defer allocator.free(packed_indices);
        try decodeRawRows(allocator, decoded, header, raw_channels, raw_row_bytes, raw_bytes_per_pixel, packed_indices);
        const index_len = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
        const indices = try allocator.alloc(u8, index_len);
        defer allocator.free(indices);
        try unpackIndexed(packed_indices, header, raw_row_bytes, indices);
        try expandPalette(indices, payloads.palette, payloads.transparency, out);
    } else if (header.color_type == 0 and header.bit_depth < 8) {
        const packed_len = std.math.mul(usize, raw_row_bytes, header.height) catch return error.UnsupportedVariant;
        const packed_gray = try allocator.alloc(u8, packed_len);
        defer allocator.free(packed_gray);
        try decodeRawRows(allocator, decoded, header, raw_channels, raw_row_bytes, raw_bytes_per_pixel, packed_gray);
        try expandLowBitGrayscale(packed_gray, header, raw_row_bytes, out);
    } else if (header.color_type == 4) {
        const raw_len = std.math.mul(usize, raw_row_bytes, header.height) catch return error.UnsupportedVariant;
        const raw = try allocator.alloc(u8, raw_len);
        defer allocator.free(raw);
        try decodeRawRows(allocator, decoded, header, raw_channels, raw_row_bytes, raw_bytes_per_pixel, raw);
        try expandGrayscaleAlpha(raw, header, out);
    } else if (payloads.transparency.len != 0) {
        const raw_len = std.math.mul(usize, raw_row_bytes, header.height) catch return error.UnsupportedVariant;
        const raw = try allocator.alloc(u8, raw_len);
        defer allocator.free(raw);
        try decodeRawRows(allocator, decoded, header, raw_channels, raw_row_bytes, raw_bytes_per_pixel, raw);
        try expandDirectTransparency(raw, header, payloads.transparency, out);
    } else {
        try decodeRawRows(allocator, decoded, header, raw_channels, row_bytes, bytes_per_pixel, out);
    }
    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    var pos: usize = signature.len;
    if (pos == data.len) return error.InvalidFormat;
    const chunk = try nextChunk(data, &pos);
    if (!std.mem.eql(u8, chunk.kind, "IHDR")) return error.InvalidFormat;
    if (chunk.bytes.len != 13) return error.InvalidFormat;
    return .{
        .width = beU32(chunk.bytes[0..4]),
        .height = beU32(chunk.bytes[4..8]),
        .bit_depth = chunk.bytes[8],
        .color_type = chunk.bytes[9],
        .compression = chunk.bytes[10],
        .filter = chunk.bytes[11],
        .interlace = chunk.bytes[12],
    };
}

fn validateHeader(header: Header) bio.ReaderError!void {
    if (header.width == 0 or header.height == 0) return error.InvalidFormat;
    if (header.color_type != 0 and header.color_type != 2 and header.color_type != 3 and header.color_type != 4 and header.color_type != 6) return error.UnsupportedVariant;
    if (header.color_type == 3) {
        if (header.bit_depth != 1 and header.bit_depth != 2 and header.bit_depth != 4 and header.bit_depth != 8) return error.UnsupportedVariant;
    } else if (header.color_type == 0) {
        if (header.bit_depth != 1 and header.bit_depth != 2 and header.bit_depth != 4 and header.bit_depth != 8 and header.bit_depth != 16) return error.UnsupportedVariant;
    } else if (header.bit_depth != 8 and header.bit_depth != 16) {
        return error.UnsupportedVariant;
    }
    if (header.compression != 0 or header.filter != 0 or (header.interlace != 0 and header.interlace != 1)) return error.UnsupportedVariant;
}

const Payloads = struct {
    idat: []u8,
    palette: []const u8,
    transparency: []const u8,
};

fn collectPayloads(allocator: std.mem.Allocator, data: []const u8, color_type: u8) bio.ReaderError!Payloads {
    var idat: std.ArrayList(u8) = .empty;
    errdefer idat.deinit(allocator);

    var saw_ihdr = false;
    var saw_idat = false;
    var saw_iend = false;
    var idat_closed = false;
    var saw_palette = false;
    var saw_transparency = false;
    var palette: []const u8 = &.{};
    var transparency: []const u8 = &.{};
    var pos: usize = signature.len;
    while (pos < data.len) {
        const chunk = try nextChunk(data, &pos);
        if (std.mem.eql(u8, chunk.kind, "IHDR")) {
            if (saw_ihdr) return error.InvalidFormat;
            saw_ihdr = true;
        } else if (std.mem.eql(u8, chunk.kind, "IDAT")) {
            if (idat_closed) return error.InvalidFormat;
            saw_idat = true;
            try idat.appendSlice(allocator, chunk.bytes);
        } else if (std.mem.eql(u8, chunk.kind, "PLTE")) {
            if (saw_idat) return error.InvalidFormat;
            if (saw_palette) return error.InvalidFormat;
            if (color_type == 0 or color_type == 4) return error.InvalidFormat;
            saw_palette = true;
            if (chunk.bytes.len == 0 or chunk.bytes.len % 3 != 0 or chunk.bytes.len > 256 * 3) return error.InvalidFormat;
            palette = chunk.bytes;
        } else if (std.mem.eql(u8, chunk.kind, "tRNS")) {
            if (saw_idat) return error.InvalidFormat;
            if (saw_transparency) return error.InvalidFormat;
            if (color_type == 3 and !saw_palette) return error.InvalidFormat;
            saw_transparency = true;
            try validateTransparency(color_type, chunk.bytes);
            transparency = chunk.bytes;
        } else if (std.mem.eql(u8, chunk.kind, "IEND")) {
            saw_iend = true;
            break;
        } else {
            if (isCriticalChunk(chunk.kind)) return error.InvalidFormat;
            if (saw_idat) idat_closed = true;
        }
    }
    if (!saw_iend) return error.InvalidFormat;
    if (pos != data.len) return error.InvalidFormat;
    if (!saw_idat) return error.InvalidFormat;
    if (color_type == 3 and palette.len == 0) return error.InvalidFormat;
    if (color_type == 3 and transparency.len > palette.len / 3) return error.InvalidFormat;
    return .{ .idat = try idat.toOwnedSlice(allocator), .palette = palette, .transparency = transparency };
}

const Chunk = struct {
    kind: []const u8,
    bytes: []const u8,
};

fn nextChunk(data: []const u8, pos: *usize) bio.ReaderError!Chunk {
    if (pos.* > data.len or data.len - pos.* < 12) return error.TruncatedData;
    const len = try checkedUsize(beU32(data[pos.*..][0..4]));
    const kind_start = pos.* + 4;
    const data_start = kind_start + 4;
    const crc_start = std.math.add(usize, data_start, len) catch return error.UnsupportedVariant;
    const next = std.math.add(usize, crc_start, 4) catch return error.UnsupportedVariant;
    if (next > data.len) return error.TruncatedData;
    const expected_crc = beU32(data[crc_start..][0..4]);
    const actual_crc = std.hash.crc.Crc32.hash(data[kind_start..crc_start]);
    if (actual_crc != expected_crc) return error.InvalidFormat;
    pos.* = next;
    return .{
        .kind = data[kind_start..][0..4],
        .bytes = data[data_start..crc_start],
    };
}

fn decodeZlib(src: []const u8, dst: []u8) bio.ReaderError!void {
    var input: std.Io.Reader = .fixed(src);
    var output: std.Io.Writer = .fixed(dst);
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    const written = decompress.reader.streamRemaining(&output) catch return error.TruncatedData;
    if (written != dst.len) return error.TruncatedData;
}

fn unfilter(decoded: []const u8, height: u32, row_bytes: usize, bytes_per_pixel: usize, out: []u8) bio.ReaderError!void {
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src = y * (row_bytes + 1);
        const filter = decoded[src];
        const raw = decoded[src + 1 ..][0..row_bytes];
        const dst = out[y * row_bytes ..][0..row_bytes];
        const prev = if (y == 0) null else out[(y - 1) * row_bytes ..][0..row_bytes];

        var x: usize = 0;
        while (x < row_bytes) : (x += 1) {
            const left = if (x >= bytes_per_pixel) dst[x - bytes_per_pixel] else 0;
            const up = if (prev) |p| p[x] else 0;
            const up_left = if (x >= bytes_per_pixel) if (prev) |p| p[x - bytes_per_pixel] else 0 else 0;
            dst[x] = switch (filter) {
                0 => raw[x],
                1 => raw[x] +% left,
                2 => raw[x] +% up,
                3 => raw[x] +% @as(u8, @intCast((@as(u16, left) + @as(u16, up)) / 2)),
                4 => raw[x] +% paeth(left, up, up_left),
                else => return error.UnsupportedVariant,
            };
        }
    }
}

fn decodeRawRows(
    allocator: std.mem.Allocator,
    decoded: []const u8,
    header: Header,
    raw_channels: u16,
    row_bytes: usize,
    bytes_per_pixel: usize,
    out: []u8,
) bio.ReaderError!void {
    if (header.interlace == 0) {
        try unfilter(decoded, header.height, row_bytes, bytes_per_pixel, out);
        return;
    }
    try reconstructAdam7(allocator, decoded, header, raw_channels, row_bytes, bytes_per_pixel, out);
}

const Adam7Pass = struct {
    x_start: usize,
    y_start: usize,
    x_step: usize,
    y_step: usize,
};

const adam7_passes = [_]Adam7Pass{
    .{ .x_start = 0, .y_start = 0, .x_step = 8, .y_step = 8 },
    .{ .x_start = 4, .y_start = 0, .x_step = 8, .y_step = 8 },
    .{ .x_start = 0, .y_start = 4, .x_step = 4, .y_step = 8 },
    .{ .x_start = 2, .y_start = 0, .x_step = 4, .y_step = 4 },
    .{ .x_start = 0, .y_start = 2, .x_step = 2, .y_step = 4 },
    .{ .x_start = 1, .y_start = 0, .x_step = 2, .y_step = 2 },
    .{ .x_start = 0, .y_start = 1, .x_step = 1, .y_step = 2 },
};

fn reconstructAdam7(
    allocator: std.mem.Allocator,
    decoded: []const u8,
    header: Header,
    raw_channels: u16,
    row_bytes: usize,
    bytes_per_pixel: usize,
    out: []u8,
) bio.ReaderError!void {
    @memset(out, 0);
    var pos: usize = 0;
    for (adam7_passes) |pass| {
        const pass_width = adam7PassSize(header.width, pass.x_start, pass.x_step);
        const pass_height = adam7PassSize(header.height, pass.y_start, pass.y_step);
        if (pass_width == 0 or pass_height == 0) continue;

        const pass_row_bytes = try rowBytesForWidth(@intCast(pass_width), raw_channels, header.bit_depth);
        const pass_decoded_len = std.math.mul(usize, pass_row_bytes + 1, pass_height) catch return error.UnsupportedVariant;
        if (pos > decoded.len or decoded.len - pos < pass_decoded_len) return error.TruncatedData;
        const pass_raw_len = std.math.mul(usize, pass_row_bytes, pass_height) catch return error.UnsupportedVariant;
        const pass_raw = try allocator.alloc(u8, pass_raw_len);
        defer allocator.free(pass_raw);
        try unfilter(decoded[pos..][0..pass_decoded_len], @intCast(pass_height), pass_row_bytes, bytes_per_pixel, pass_raw);
        pos += pass_decoded_len;

        var py: usize = 0;
        while (py < pass_height) : (py += 1) {
            var px: usize = 0;
            while (px < pass_width) : (px += 1) {
                const dst_x = pass.x_start + px * pass.x_step;
                const dst_y = pass.y_start + py * pass.y_step;
                if (header.bit_depth < 8) {
                    const src_row = pass_raw[py * pass_row_bytes ..][0..pass_row_bytes];
                    const dst_row = out[dst_y * row_bytes ..][0..row_bytes];
                    setPackedSample(dst_row, dst_x, header.bit_depth, packedSample(src_row, px, header.bit_depth));
                } else {
                    const src = py * pass_row_bytes + px * bytes_per_pixel;
                    const dst = dst_y * row_bytes + dst_x * bytes_per_pixel;
                    @memcpy(out[dst..][0..bytes_per_pixel], pass_raw[src..][0..bytes_per_pixel]);
                }
            }
        }
    }
    if (pos != decoded.len) return error.InvalidFormat;
}

fn adam7DecodedLen(header: Header, raw_channels: u16) bio.ReaderError!usize {
    var total: usize = 0;
    for (adam7_passes) |pass| {
        const pass_width = adam7PassSize(header.width, pass.x_start, pass.x_step);
        const pass_height = adam7PassSize(header.height, pass.y_start, pass.y_step);
        if (pass_width == 0 or pass_height == 0) continue;
        const pass_row_bytes = try rowBytesForWidth(@intCast(pass_width), raw_channels, header.bit_depth);
        const pass_scanline_bytes = std.math.add(usize, pass_row_bytes, 1) catch return error.UnsupportedVariant;
        const pass_bytes = std.math.mul(usize, pass_scanline_bytes, pass_height) catch return error.UnsupportedVariant;
        total = std.math.add(usize, total, pass_bytes) catch return error.UnsupportedVariant;
    }
    return total;
}

fn adam7PassSize(full_size: u32, start: usize, step: usize) usize {
    const full: usize = @intCast(full_size);
    if (full <= start) return 0;
    return (full - start + step - 1) / step;
}

fn packedSample(row: []const u8, x: usize, bit_depth: u8) u8 {
    const max_value = (@as(u16, 1) << @intCast(bit_depth)) - 1;
    const bit_offset = x * @as(usize, bit_depth);
    const byte = row[bit_offset / 8];
    const shift: u3 = @intCast(8 - @as(usize, bit_depth) - (bit_offset % 8));
    return @intCast((byte >> shift) & @as(u8, @intCast(max_value)));
}

fn setPackedSample(row: []u8, x: usize, bit_depth: u8, value: u8) void {
    const max_value = (@as(u16, 1) << @intCast(bit_depth)) - 1;
    const bit_offset = x * @as(usize, bit_depth);
    const byte_index = bit_offset / 8;
    const shift: u3 = @intCast(8 - @as(usize, bit_depth) - (bit_offset % 8));
    const mask: u8 = @as(u8, @intCast(max_value)) << shift;
    row[byte_index] = (row[byte_index] & ~mask) | ((value & @as(u8, @intCast(max_value))) << shift);
}

fn expandPalette(indices: []const u8, palette: []const u8, transparency: []const u8, out: []u8) bio.ReaderError!void {
    const channels: usize = if (transparency.len == 0) 3 else 4;
    for (indices, 0..) |index, i| {
        const src = @as(usize, index) * 3;
        if (src + 3 > palette.len) return error.InvalidFormat;
        const dst = i * channels;
        out[dst + 0] = palette[src + 0];
        out[dst + 1] = palette[src + 1];
        out[dst + 2] = palette[src + 2];
        if (channels == 4) out[dst + 3] = if (index < transparency.len) transparency[@as(usize, index)] else 255;
    }
}

fn unpackIndexed(packed_indices: []const u8, header: Header, row_bytes: usize, indices: []u8) bio.ReaderError!void {
    if (header.bit_depth == 8) {
        if (packed_indices.len != indices.len) return error.InvalidFormat;
        @memcpy(indices, packed_indices);
        return;
    }

    var y: usize = 0;
    while (y < header.height) : (y += 1) {
        const row = packed_indices[y * row_bytes ..][0..row_bytes];
        var x: usize = 0;
        while (x < header.width) : (x += 1) {
            indices[y * header.width + x] = packedSample(row, x, header.bit_depth);
        }
    }
}

fn expandLowBitGrayscale(packed_gray: []const u8, header: Header, row_bytes: usize, out: []u8) bio.ReaderError!void {
    const max_value = (@as(u16, 1) << @intCast(header.bit_depth)) - 1;
    var y: usize = 0;
    while (y < header.height) : (y += 1) {
        const row = packed_gray[y * row_bytes ..][0..row_bytes];
        var x: usize = 0;
        while (x < header.width) : (x += 1) {
            const value = @as(u16, packedSample(row, x, header.bit_depth));
            out[y * header.width + x] = @intCast((value * 255) / max_value);
        }
    }
}

fn expandDirectTransparency(raw: []const u8, header: Header, transparency: []const u8, out: []u8) bio.ReaderError!void {
    const sample_bytes = bytesPerSample(header);
    const max_alpha = if (header.bit_depth == 16) [_]u8{ 0xff, 0xff } else [_]u8{ 0xff, 0 };
    const zero_alpha = [_]u8{ 0, 0 };
    var pixel: usize = 0;
    const pixel_count = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    while (pixel < pixel_count) : (pixel += 1) {
        if (header.color_type == 0) {
            const src = pixel * sample_bytes;
            const dst = pixel * 4 * sample_bytes;
            const alpha = if (sampleMatches(raw[src..][0..sample_bytes], transparency[0..2], header.bit_depth)) zero_alpha[0..sample_bytes] else max_alpha[0..sample_bytes];
            @memcpy(out[dst..][0..sample_bytes], raw[src..][0..sample_bytes]);
            @memcpy(out[dst + sample_bytes ..][0..sample_bytes], raw[src..][0..sample_bytes]);
            @memcpy(out[dst + sample_bytes * 2 ..][0..sample_bytes], raw[src..][0..sample_bytes]);
            @memcpy(out[dst + sample_bytes * 3 ..][0..sample_bytes], alpha);
        } else if (header.color_type == 2) {
            const src = pixel * 3 * sample_bytes;
            const dst = pixel * 4 * sample_bytes;
            const transparent =
                sampleMatches(raw[src..][0..sample_bytes], transparency[0..2], header.bit_depth) and
                sampleMatches(raw[src + sample_bytes ..][0..sample_bytes], transparency[2..4], header.bit_depth) and
                sampleMatches(raw[src + sample_bytes * 2 ..][0..sample_bytes], transparency[4..6], header.bit_depth);
            const alpha = if (transparent) zero_alpha[0..sample_bytes] else max_alpha[0..sample_bytes];
            @memcpy(out[dst..][0 .. 3 * sample_bytes], raw[src..][0 .. 3 * sample_bytes]);
            @memcpy(out[dst + sample_bytes * 3 ..][0..sample_bytes], alpha);
        } else {
            return error.UnsupportedVariant;
        }
    }
}

fn expandGrayscaleAlpha(raw: []const u8, header: Header, out: []u8) bio.ReaderError!void {
    const sample_bytes = bytesPerSample(header);
    const pixel_count = std.math.mul(usize, header.width, header.height) catch return error.UnsupportedVariant;
    var pixel: usize = 0;
    while (pixel < pixel_count) : (pixel += 1) {
        const src = pixel * 2 * sample_bytes;
        const dst = pixel * 4 * sample_bytes;
        const gray = raw[src..][0..sample_bytes];
        const alpha = raw[src + sample_bytes ..][0..sample_bytes];
        @memcpy(out[dst..][0..sample_bytes], gray);
        @memcpy(out[dst + sample_bytes ..][0..sample_bytes], gray);
        @memcpy(out[dst + sample_bytes * 2 ..][0..sample_bytes], gray);
        @memcpy(out[dst + sample_bytes * 3 ..][0..sample_bytes], alpha);
    }
}

fn sampleMatches(sample: []const u8, transparent: []const u8, bit_depth: u8) bool {
    if (bit_depth == 16) return std.mem.eql(u8, sample, transparent);
    return sample[0] == transparent[1];
}

fn hasTransparency(data: []const u8, color_type: u8) bio.ReaderError!bool {
    var pos: usize = signature.len;
    var palette_entries: ?usize = null;
    var transparency_len: ?usize = null;
    var saw_ihdr = false;
    var saw_idat = false;
    var saw_iend = false;
    var idat_closed = false;
    var saw_palette = false;
    var saw_transparency = false;
    while (pos < data.len) {
        const chunk = try nextChunk(data, &pos);
        if (std.mem.eql(u8, chunk.kind, "IHDR")) {
            if (saw_ihdr) return error.InvalidFormat;
            saw_ihdr = true;
        }
        if (std.mem.eql(u8, chunk.kind, "IDAT")) {
            if (idat_closed) return error.InvalidFormat;
            saw_idat = true;
        } else if (saw_idat and !std.mem.eql(u8, chunk.kind, "IEND")) {
            idat_closed = true;
        }
        if (std.mem.eql(u8, chunk.kind, "PLTE")) {
            if (saw_idat) return error.InvalidFormat;
            if (saw_palette) return error.InvalidFormat;
            if (color_type == 0 or color_type == 4) return error.InvalidFormat;
            saw_palette = true;
            if (chunk.bytes.len == 0 or chunk.bytes.len % 3 != 0 or chunk.bytes.len > 256 * 3) return error.InvalidFormat;
            palette_entries = chunk.bytes.len / 3;
        }
        if (std.mem.eql(u8, chunk.kind, "tRNS")) {
            if (saw_idat) return error.InvalidFormat;
            if (saw_transparency) return error.InvalidFormat;
            if (color_type == 3 and !saw_palette) return error.InvalidFormat;
            saw_transparency = true;
            try validateTransparency(color_type, chunk.bytes);
            transparency_len = chunk.bytes.len;
        }
        if (!isKnownChunk(chunk.kind) and isCriticalChunk(chunk.kind)) return error.InvalidFormat;
        if (std.mem.eql(u8, chunk.kind, "IEND")) {
            saw_iend = true;
            break;
        }
    }
    if (!saw_iend) return error.InvalidFormat;
    if (pos != data.len) return error.InvalidFormat;
    if (!saw_idat) return error.InvalidFormat;
    if (color_type == 3) {
        const entries = palette_entries orelse return error.InvalidFormat;
        const len = transparency_len orelse return false;
        if (len > entries) return error.InvalidFormat;
        return true;
    }
    return transparency_len != null;
}

fn isKnownChunk(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "IHDR") or
        std.mem.eql(u8, kind, "PLTE") or
        std.mem.eql(u8, kind, "IDAT") or
        std.mem.eql(u8, kind, "IEND") or
        std.mem.eql(u8, kind, "tRNS");
}

fn isCriticalChunk(kind: []const u8) bool {
    return (kind[0] & 0x20) == 0;
}

fn validateTransparency(color_type: u8, bytes: []const u8) bio.ReaderError!void {
    switch (color_type) {
        0 => if (bytes.len != 2) return error.InvalidFormat,
        2 => if (bytes.len != 6) return error.InvalidFormat,
        3 => if (bytes.len == 0 or bytes.len > 256) return error.InvalidFormat,
        else => return error.InvalidFormat,
    }
}

fn paeth(left: u8, up: u8, up_left: u8) u8 {
    const a: i32 = left;
    const b: i32 = up;
    const c: i32 = up_left;
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return left;
    if (pb <= pc) return up;
    return up_left;
}

fn samplesPerPixel(color_type: u8) u16 {
    return switch (color_type) {
        0 => 1,
        2 => 3,
        3 => 3,
        4 => 4,
        6 => 4,
        else => 0,
    };
}

fn outputSamplesPerPixel(color_type: u8, indexed_alpha: bool) u16 {
    if (color_type == 4) return 4;
    if ((color_type == 0 or color_type == 2 or color_type == 3) and indexed_alpha) return 4;
    return samplesPerPixel(color_type);
}

fn rawSamplesPerPixel(color_type: u8) u16 {
    return switch (color_type) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => 0,
    };
}

fn bytesPerSample(header: Header) usize {
    return if (header.bit_depth == 16) 2 else 1;
}

fn filterBytesPerPixel(header: Header, raw_channels: u16) usize {
    if (header.bit_depth < 8) return 1;
    return @as(usize, raw_channels) * bytesPerSample(header);
}

fn rawRowBytes(header: Header, raw_channels: u16) bio.ReaderError!usize {
    return rowBytesForWidth(header.width, raw_channels, header.bit_depth);
}

fn rowBytesForWidth(width: u32, raw_channels: u16, bit_depth: u8) bio.ReaderError!usize {
    const bits_per_row = std.math.mul(usize, width, @as(usize, raw_channels) * @as(usize, bit_depth)) catch return error.UnsupportedVariant;
    return (bits_per_row + 7) / 8;
}

fn checkedUsize(value: u32) bio.ReaderError!usize {
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
}

fn beU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

fn appendChunk(list: *std.ArrayList(u8), kind: []const u8, bytes: []const u8) !void {
    try appendU32Be(list, @intCast(bytes.len));
    try list.appendSlice(std.testing.allocator, kind);
    try list.appendSlice(std.testing.allocator, bytes);
    var crc = std.hash.crc.Crc32.init();
    crc.update(kind);
    crc.update(bytes);
    try appendU32Be(list, crc.final());
}

fn appendU32Be(list: *std.ArrayList(u8), value: u32) !void {
    try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
    try list.append(std.testing.allocator, @intCast(value & 0xff));
}

fn appendZlibStored(list: *std.ArrayList(u8), bytes: []const u8) !void {
    try list.append(std.testing.allocator, 0x78);
    try list.append(std.testing.allocator, 0x01);
    try list.append(std.testing.allocator, 0x01);
    try list.append(std.testing.allocator, @intCast(bytes.len & 0xff));
    try list.append(std.testing.allocator, @intCast((bytes.len >> 8) & 0xff));
    const nlen: u16 = ~@as(u16, @intCast(bytes.len));
    try list.append(std.testing.allocator, @intCast(nlen & 0xff));
    try list.append(std.testing.allocator, @intCast((nlen >> 8) & 0xff));
    try list.appendSlice(std.testing.allocator, bytes);
    try appendU32Be(list, adler32(bytes));
}

fn adler32(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn appendPng(list: *std.ArrayList(u8), width: u32, height: u32, color_type: u8, scanlines: []const u8) !void {
    try appendPngWithPalette(list, width, height, color_type, &.{}, scanlines);
}

fn appendPngWithPalette(
    list: *std.ArrayList(u8),
    width: u32,
    height: u32,
    color_type: u8,
    palette: []const u8,
    scanlines: []const u8,
) !void {
    try appendPngWithDepth(list, width, height, color_type, 8, palette, scanlines);
}

fn appendPngWithDepth(
    list: *std.ArrayList(u8),
    width: u32,
    height: u32,
    color_type: u8,
    bit_depth: u8,
    palette: []const u8,
    scanlines: []const u8,
) !void {
    try list.appendSlice(std.testing.allocator, signature);
    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, width);
    try appendU32Be(&ihdr, height);
    try ihdr.append(std.testing.allocator, bit_depth);
    try ihdr.append(std.testing.allocator, color_type);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(list, "IHDR", ihdr.items);
    if (palette.len != 0) try appendChunk(list, "PLTE", palette);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, scanlines);
    try appendChunk(list, "IDAT", zlib.items);
    try appendChunk(list, "IEND", &.{});
}

fn appendIndexedPngWithTransparency(
    list: *std.ArrayList(u8),
    width: u32,
    height: u32,
    palette: []const u8,
    transparency: []const u8,
    scanlines: []const u8,
) !void {
    try list.appendSlice(std.testing.allocator, signature);
    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, width);
    try appendU32Be(&ihdr, height);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, 3);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(list, "IHDR", ihdr.items);
    try appendChunk(list, "PLTE", palette);
    try appendChunk(list, "tRNS", transparency);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, scanlines);
    try appendChunk(list, "IDAT", zlib.items);
    try appendChunk(list, "IEND", &.{});
}

fn appendPngWithTransparency(
    list: *std.ArrayList(u8),
    width: u32,
    height: u32,
    color_type: u8,
    bit_depth: u8,
    transparency: []const u8,
    scanlines: []const u8,
) !void {
    try list.appendSlice(std.testing.allocator, signature);
    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, width);
    try appendU32Be(&ihdr, height);
    try ihdr.append(std.testing.allocator, bit_depth);
    try ihdr.append(std.testing.allocator, color_type);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(list, "IHDR", ihdr.items);
    try appendChunk(list, "tRNS", transparency);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, scanlines);
    try appendChunk(list, "IDAT", zlib.items);
    try appendChunk(list, "IEND", &.{});
}

fn appendPngWithSplitIdat(list: *std.ArrayList(u8), width: u32, height: u32, color_type: u8, scanlines: []const u8, split_at: usize) !void {
    try list.appendSlice(std.testing.allocator, signature);
    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, width);
    try appendU32Be(&ihdr, height);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, color_type);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(list, "IHDR", ihdr.items);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, scanlines);
    try appendChunk(list, "IDAT", zlib.items[0..split_at]);
    try appendChunk(list, "IDAT", zlib.items[split_at..]);
    try appendChunk(list, "IEND", &.{});
}

fn appendInterlacedPngWithDepth(
    list: *std.ArrayList(u8),
    width: u32,
    height: u32,
    color_type: u8,
    bit_depth: u8,
    palette: []const u8,
    scanlines: []const u8,
) !void {
    try list.appendSlice(std.testing.allocator, signature);
    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, width);
    try appendU32Be(&ihdr, height);
    try ihdr.append(std.testing.allocator, bit_depth);
    try ihdr.append(std.testing.allocator, color_type);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 1);
    try appendChunk(list, "IHDR", ihdr.items);
    if (palette.len != 0) try appendChunk(list, "PLTE", palette);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, scanlines);
    try appendChunk(list, "IDAT", zlib.items);
    try appendChunk(list, "IEND", &.{});
}

test "reads 8-bit grayscale png" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPng(&data, 2, 1, 0, &.{ 0, 7, 9 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "rejects png chunk crc mismatch" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPng(&data, 1, 1, 0, &.{ 0, 7 });
    data.items[data.items.len - 1] ^= 1;

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "ignores unknown ancillary png chunk" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, signature);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 1);
    try appendU32Be(&ihdr, 1);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(&data, "IHDR", ihdr.items);
    try appendChunk(&data, "vpAg", "note");

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, &.{ 0, 7 });
    try appendChunk(&data, "IDAT", zlib.items);
    try appendChunk(&data, "IEND", &.{});

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{7}, plane.data);
}

test "rejects unknown critical png chunk" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, signature);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 1);
    try appendU32Be(&ihdr, 1);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(&data, "IHDR", ihdr.items);
    try appendChunk(&data, "VpAg", &.{});

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, &.{ 0, 7 });
    try appendChunk(&data, "IDAT", zlib.items);
    try appendChunk(&data, "IEND", &.{});

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "rejects grayscale png palette chunk" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPngWithPalette(
        &data,
        1,
        1,
        0,
        &.{ 255, 0, 0 },
        &.{ 0, 7 },
    );

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "rejects png chunk before ihdr" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, signature);
    try appendChunk(&data, "PLTE", &.{ 255, 0, 0 });

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 1);
    try appendU32Be(&ihdr, 1);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(&data, "IHDR", ihdr.items);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, &.{ 0, 7 });
    try appendChunk(&data, "IDAT", zlib.items);
    try appendChunk(&data, "IEND", &.{});

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "rejects duplicate png ihdr chunk" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, signature);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 1);
    try appendU32Be(&ihdr, 1);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(&data, "IHDR", ihdr.items);
    try appendChunk(&data, "IHDR", ihdr.items);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, &.{ 0, 7 });
    try appendChunk(&data, "IDAT", zlib.items);
    try appendChunk(&data, "IEND", &.{});

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "rejects png without iend chunk" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, signature);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 1);
    try appendU32Be(&ihdr, 1);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(&data, "IHDR", ihdr.items);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, &.{ 0, 7 });
    try appendChunk(&data, "IDAT", zlib.items);

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "rejects png without idat chunk in metadata" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, signature);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 1);
    try appendU32Be(&ihdr, 1);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(&data, "IHDR", ihdr.items);
    try appendChunk(&data, "IEND", &.{});

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "rejects png trailing bytes after iend" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPng(&data, 1, 1, 0, &.{ 0, 7 });
    try data.append(std.testing.allocator, 0);

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "rejects indexed png palette after idat" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, signature);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 1);
    try appendU32Be(&ihdr, 1);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, 3);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(&data, "IHDR", ihdr.items);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, &.{ 0, 0 });
    try appendChunk(&data, "IDAT", zlib.items);
    try appendChunk(&data, "PLTE", &.{ 255, 0, 0 });
    try appendChunk(&data, "IEND", &.{});

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "rejects png transparency after idat" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, signature);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 1);
    try appendU32Be(&ihdr, 1);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(&data, "IHDR", ihdr.items);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, &.{ 0, 7 });
    try appendChunk(&data, "IDAT", zlib.items);
    try appendChunk(&data, "tRNS", &.{ 0, 7 });
    try appendChunk(&data, "IEND", &.{});

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "rejects duplicate png palette chunk" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, signature);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 1);
    try appendU32Be(&ihdr, 1);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, 3);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(&data, "IHDR", ihdr.items);
    try appendChunk(&data, "PLTE", &.{ 255, 0, 0 });
    try appendChunk(&data, "PLTE", &.{ 0, 255, 0 });

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, &.{ 0, 0 });
    try appendChunk(&data, "IDAT", zlib.items);
    try appendChunk(&data, "IEND", &.{});

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "rejects duplicate png transparency chunk" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, signature);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 1);
    try appendU32Be(&ihdr, 1);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(&data, "IHDR", ihdr.items);
    try appendChunk(&data, "tRNS", &.{ 0, 7 });
    try appendChunk(&data, "tRNS", &.{ 0, 9 });

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, &.{ 0, 7 });
    try appendChunk(&data, "IDAT", zlib.items);
    try appendChunk(&data, "IEND", &.{});

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "rejects indexed png transparency before palette" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, signature);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 1);
    try appendU32Be(&ihdr, 1);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, 3);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(&data, "IHDR", ihdr.items);
    try appendChunk(&data, "tRNS", &.{255});
    try appendChunk(&data, "PLTE", &.{ 255, 0, 0 });

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, &.{ 0, 0 });
    try appendChunk(&data, "IDAT", zlib.items);
    try appendChunk(&data, "IEND", &.{});

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "reads 2-bit grayscale png" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPngWithDepth(&data, 4, 1, 0, 2, &.{}, &.{ 0, 0x1b });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 85, 170, 255 }, plane.data);
}

test "reads png with split idat chunks" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPngWithSplitIdat(&data, 2, 1, 0, &.{ 0, 7, 9 }, 5);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "rejects non-consecutive png idat chunks" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendSlice(std.testing.allocator, signature);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 2);
    try appendU32Be(&ihdr, 1);
    try ihdr.append(std.testing.allocator, 8);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try ihdr.append(std.testing.allocator, 0);
    try appendChunk(&data, "IHDR", ihdr.items);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, &.{ 0, 7, 9 });
    try appendChunk(&data, "IDAT", zlib.items[0..5]);
    try appendChunk(&data, "tEXt", "note");
    try appendChunk(&data, "IDAT", zlib.items[5..]);
    try appendChunk(&data, "IEND", &.{});

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "reads 8-bit interlaced grayscale png" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendInterlacedPngWithDepth(
        &data,
        3,
        3,
        0,
        8,
        &.{},
        &.{
            0, 1,
            0, 3,
            0, 7, 9,
            0, 2,
            0, 8,
            0, 4, 5, 6,
        },
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, plane.data);
}

test "reads 2-bit interlaced grayscale png" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendInterlacedPngWithDepth(
        &data,
        3,
        3,
        0,
        2,
        &.{},
        &.{
            0, 0x00,
            0, 0x80,
            0, 0x20,
            0, 0x40,
            0, 0xc0,
            0, 0xe4,
        },
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 85, 170, 255, 170, 85, 0, 255, 170 }, plane.data);
}

test "reads 8-bit interlaced rgb png" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendInterlacedPngWithDepth(
        &data,
        3,
        3,
        2,
        8,
        &.{},
        &.{
            0, 1, 2, 3,
            0, 7, 8, 9,
            0, 19, 20, 21, 25, 26, 27,
            0, 4, 5, 6,
            0, 22, 23, 24,
            0, 10, 11, 12, 13, 14, 15, 16, 17, 18,
        },
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{
        1,  2,  3,  4,  5,  6,  7,  8,  9,
        10, 11, 12, 13, 14, 15, 16, 17, 18,
        19, 20, 21, 22, 23, 24, 25, 26, 27,
    }, plane.data);
}

test "reads 4-bit interlaced indexed png palette as rgb" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendInterlacedPngWithDepth(
        &data,
        3,
        3,
        3,
        4,
        &.{ 0, 0, 0, 255, 0, 0, 0, 128, 0, 0, 0, 255 },
        &.{
            0, 0x10,
            0, 0x30,
            0, 0x13,
            0, 0x20,
            0, 0x00,
            0, 0x03, 0x20,
        },
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{
        255, 0,   0, 0, 128, 0, 0,   0, 255,
        0,   0,   0, 0, 0,   255, 0, 128, 0,
        255, 0,   0, 0, 0,   0,   0, 0,   255,
    }, plane.data);
}

test "reads 8-bit rgb png with sub filter" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPng(&data, 2, 1, 2, &.{ 1, 10, 20, 30, 5, 5, 5 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 15, 25, 35 }, plane.data);
}

test "reads 8-bit indexed png palette as rgb" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPngWithPalette(
        &data,
        3,
        1,
        3,
        &.{ 0, 0, 0, 255, 0, 0, 0, 128, 255 },
        &.{ 0, 1, 2, 0 },
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 128, 255, 0, 0, 0 }, plane.data);
}

test "rejects indexed png image index outside palette" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPngWithPalette(
        &data,
        1,
        1,
        3,
        &.{ 255, 0, 0 },
        &.{ 0, 1 },
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "rejects indexed png without palette in metadata" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPngWithPalette(
        &data,
        1,
        1,
        3,
        &.{},
        &.{ 0, 0 },
    );

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "reads 4-bit indexed png palette as rgb" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPngWithDepth(
        &data,
        3,
        1,
        3,
        4,
        &.{ 0, 0, 0, 255, 0, 0, 0, 0, 255 },
        &.{ 0, 0x12, 0 },
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 0, 255, 0, 0, 0 }, plane.data);
}

test "reads 8-bit indexed png palette transparency as rgba" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendIndexedPngWithTransparency(
        &data,
        3,
        1,
        &.{ 0, 0, 0, 255, 0, 0, 0, 128, 255 },
        &.{ 255, 0 },
        &.{ 0, 1, 2, 0 },
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 0, 128, 255, 255, 0, 0, 0, 255 }, plane.data);
}

test "rejects indexed png transparency outside palette in metadata" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendIndexedPngWithTransparency(
        &data,
        1,
        1,
        &.{ 255, 0, 0 },
        &.{ 255, 0 },
        &.{ 0, 0 },
    );

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "reads 8-bit grayscale png transparency as rgba" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPngWithTransparency(&data, 2, 1, 0, 8, &.{ 0, 7 }, &.{ 0, 7, 9 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 7, 0, 9, 9, 9, 255 }, plane.data);
}

test "reads 8-bit rgb png transparency as rgba" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPngWithTransparency(
        &data,
        2,
        1,
        2,
        8,
        &.{ 0, 255, 0, 0, 0, 0 },
        &.{ 0, 255, 0, 0, 0, 255, 0 },
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 0, 255, 0, 255 }, plane.data);
}

test "rejects grayscale alpha png transparency chunk" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPngWithTransparency(&data, 1, 1, 4, 8, &.{ 0, 7 }, &.{ 0, 7, 255 });

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "rejects rgba png transparency chunk" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPngWithTransparency(
        &data,
        1,
        1,
        6,
        8,
        &.{ 0, 255, 0, 0, 0, 0 },
        &.{ 0, 255, 0, 0, 0, 255 },
    );

    try std.testing.expectError(error.InvalidFormat, readMetadata(data.items));
    try std.testing.expectError(error.InvalidFormat, readPlane(std.testing.allocator, data.items));
}

test "reads 16-bit grayscale png" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPngWithDepth(&data, 2, 1, 0, 16, &.{}, &.{ 0, 0x12, 0x34, 0xab, 0xcd });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(usize, 2), metadata.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0xab, 0xcd }, plane.data);
}

test "reads 8-bit grayscale alpha png as rgba" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPng(&data, 2, 1, 4, &.{ 0, 7, 0, 9, 255 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 7, 0, 9, 9, 9, 255 }, plane.data);
}

test "reads 16-bit grayscale alpha png as rgba" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPngWithDepth(&data, 1, 1, 4, 16, &.{}, &.{ 0, 0x12, 0x34, 0xab, 0xcd });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgba16, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(usize, 8), metadata.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x12, 0x34, 0x12, 0x34, 0xab, 0xcd }, plane.data);
}

test "reads 16-bit rgb png" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPngWithDepth(
        &data,
        1,
        1,
        2,
        16,
        &.{},
        &.{ 0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc },
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgb16, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(usize, 6), metadata.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc }, plane.data);
}

test "reads 16-bit rgba png" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPngWithDepth(
        &data,
        1,
        1,
        6,
        16,
        &.{},
        &.{ 0, 0, 1, 0, 2, 0, 3, 0, 4 },
    );

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgba16, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(usize, 8), metadata.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 2, 0, 3, 0, 4 }, plane.data);
}

test "reads 8-bit rgba png with up filter" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendPng(&data, 1, 2, 6, &.{ 0, 1, 2, 3, 4, 2, 5, 5, 5, 5 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgba8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 6, 7, 8, 9 }, plane.data);
}
