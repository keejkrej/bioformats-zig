const std = @import("std");
const bio = @import("../root.zig");

pub fn matches(data: []const u8) bool {
    _ = jpegInfo(data) catch return false;
    return true;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    return readMetadataAs(data, "jpeg");
}

pub fn readMetadataAs(data: []const u8, format: []const u8) bio.ReaderError!bio.Metadata {
    const info = jpegInfo(data) catch return error.InvalidFormat;
    const samples = @as(u16, info.components);
    const pixel_type: bio.PixelType = if (info.precision <= 8)
        if (samples == 1) .uint8 else .rgb8
    else if (samples == 1) .uint16 else .rgb16;
    return .{
        .format = format,
        .width = info.width,
        .height = info.height,
        .size_c = samples,
        .samples_per_pixel = samples,
        .pixel_type = pixel_type,
        .plane_count = 1,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    return readPlaneIndexAs(allocator, data, plane_index, "jpeg");
}

pub fn readPlaneIndexAs(allocator: std.mem.Allocator, data: []const u8, plane_index: u32, format: []const u8) bio.ReaderError!bio.Plane {
    if (plane_index != 0) return error.InvalidPlaneIndex;
    var decoder = try Decoder.parse(data);
    return .{
        .metadata = try decoder.metadata(format),
        .data = try decoder.decode(allocator),
    };
}

const JpegInfo = struct {
    width: u32,
    height: u32,
    components: u8,
    precision: u8,
};

fn jpegInfo(data: []const u8) !JpegInfo {
    if (data.len < 4 or data[0] != 0xff or data[1] != 0xd8) return error.InvalidFormat;
    var i: usize = 2;
    while (i + 3 < data.len) {
        while (i < data.len and data[i] != 0xff) : (i += 1) {}
        while (i < data.len and data[i] == 0xff) : (i += 1) {}
        if (i >= data.len) break;
        const marker = data[i];
        i += 1;
        if (marker == 0xd9 or marker == 0xda) break;
        if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
        if (i + 2 > data.len) return error.TruncatedData;
        const segment_len = readU16BE(data[i..][0..2]);
        if (segment_len < 2 or i + segment_len > data.len) return error.TruncatedData;
        if (isSofMarker(marker)) {
            if (segment_len < 8) return error.InvalidFormat;
            const components = data[i + 7];
            if (components == 0) return error.InvalidFormat;
            return .{
                .precision = data[i + 2],
                .height = readU16BE(data[i + 3 ..][0..2]),
                .width = readU16BE(data[i + 5 ..][0..2]),
                .components = components,
            };
        }
        i += segment_len;
    }
    return error.InvalidFormat;
}

fn isSofMarker(marker: u8) bool {
    return marker == 0xc0 or marker == 0xc1 or marker == 0xc2 or marker == 0xc3 or
        marker == 0xc5 or marker == 0xc6 or marker == 0xc7 or marker == 0xc9 or
        marker == 0xca or marker == 0xcb or marker == 0xcd or marker == 0xce or marker == 0xcf;
}

fn readU16BE(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

const zigzag = [_]usize{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

const HuffmanEntry = struct {
    code: u16,
    len: u8,
    symbol: u8,
};

const HuffmanTable = struct {
    entries: [256]HuffmanEntry = undefined,
    count: usize = 0,

    fn decode(self: *const HuffmanTable, bits: *BitReader) !u8 {
        var code: u16 = 0;
        var len: u8 = 1;
        while (len <= 16) : (len += 1) {
            code = (code << 1) | try bits.readBit();
            var i: usize = 0;
            while (i < self.count) : (i += 1) {
                const entry = self.entries[i];
                if (entry.len == len and entry.code == code) return entry.symbol;
            }
        }
        return error.InvalidFormat;
    }
};

const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    quant_table: u8,
    dc_table: u8 = 0,
    ac_table: u8 = 0,
    previous_dc: i32 = 0,
};

const Decoder = struct {
    data: []const u8,
    width: u32 = 0,
    height: u32 = 0,
    components: [4]Component = undefined,
    component_count: u8 = 0,
    quant_tables: [4]?[64]i32 = .{ null, null, null, null },
    huffman_dc: [4]?HuffmanTable = .{ null, null, null, null },
    huffman_ac: [4]?HuffmanTable = .{ null, null, null, null },
    scan_offset: usize = 0,

    fn parse(data: []const u8) bio.ReaderError!Decoder {
        if (data.len < 4 or data[0] != 0xff or data[1] != 0xd8) return error.InvalidFormat;
        var self = Decoder{ .data = data };
        var pos: usize = 2;
        while (pos + 3 < data.len) {
            while (pos < data.len and data[pos] != 0xff) : (pos += 1) {}
            while (pos < data.len and data[pos] == 0xff) : (pos += 1) {}
            if (pos >= data.len) break;
            const marker = data[pos];
            pos += 1;
            if (marker == 0xd9) break;
            if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
            if (pos + 2 > data.len) return error.TruncatedData;
            const segment_len: usize = readU16BE(data[pos..][0..2]);
            if (segment_len < 2 or pos + segment_len > data.len) return error.TruncatedData;
            const segment = data[pos + 2 .. pos + segment_len];
            switch (marker) {
                0xc0 => try self.parseSof0(segment),
                0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf => return error.UnsupportedVariant,
                0xc4 => try self.parseDht(segment),
                0xdb => try self.parseDqt(segment),
                0xda => {
                    try self.parseSos(segment);
                    self.scan_offset = pos + segment_len;
                    return self;
                },
                else => {},
            }
            pos += segment_len;
        }
        return error.InvalidFormat;
    }

    fn metadata(self: Decoder, format: []const u8) bio.ReaderError!bio.Metadata {
        const samples: u16 = self.component_count;
        return .{
            .format = format,
            .width = self.width,
            .height = self.height,
            .size_c = samples,
            .samples_per_pixel = samples,
            .pixel_type = if (samples == 1) .uint8 else .rgb8,
            .plane_count = 1,
            .dimension_order = "XYCZT",
        };
    }

    fn parseSof0(self: *Decoder, segment: []const u8) bio.ReaderError!void {
        if (segment.len < 6 or segment[0] != 8) return error.UnsupportedVariant;
        self.height = readU16BE(segment[1..][0..2]);
        self.width = readU16BE(segment[3..][0..2]);
        self.component_count = segment[5];
        if (self.width == 0 or self.height == 0 or self.component_count == 0 or self.component_count > 3) return error.InvalidFormat;
        if (segment.len < 6 + @as(usize, self.component_count) * 3) return error.TruncatedData;
        var pos: usize = 6;
        var i: usize = 0;
        while (i < self.component_count) : (i += 1) {
            const factors = segment[pos + 1];
            const h = factors >> 4;
            const v = factors & 0x0f;
            if (h == 0 or v == 0 or h > 4 or v > 4 or @as(u16, h) * @as(u16, v) > 16) return error.UnsupportedVariant;
            self.components[i] = .{
                .id = segment[pos],
                .h = h,
                .v = v,
                .quant_table = segment[pos + 2],
            };
            if (self.components[i].quant_table >= 4) return error.InvalidFormat;
            pos += 3;
        }
    }

    fn parseDqt(self: *Decoder, segment: []const u8) bio.ReaderError!void {
        var pos: usize = 0;
        while (pos < segment.len) {
            const info = segment[pos];
            pos += 1;
            const precision = info >> 4;
            const table_id = info & 0x0f;
            if (precision != 0 or table_id >= 4) return error.UnsupportedVariant;
            if (pos + 64 > segment.len) return error.TruncatedData;
            var table: [64]i32 = undefined;
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                table[zigzag[i]] = segment[pos + i];
            }
            self.quant_tables[table_id] = table;
            pos += 64;
        }
    }

    fn parseDht(self: *Decoder, segment: []const u8) bio.ReaderError!void {
        var pos: usize = 0;
        while (pos < segment.len) {
            if (pos + 17 > segment.len) return error.TruncatedData;
            const info = segment[pos];
            pos += 1;
            const class = info >> 4;
            const table_id = info & 0x0f;
            if (class > 1 or table_id >= 4) return error.InvalidFormat;
            var total: usize = 0;
            var counts: [16]u8 = undefined;
            var i: usize = 0;
            while (i < 16) : (i += 1) {
                counts[i] = segment[pos + i];
                total += counts[i];
            }
            pos += 16;
            if (pos + total > segment.len or total > 256) return error.TruncatedData;
            var table: HuffmanTable = .{};
            var code: u16 = 0;
            var symbol_index: usize = 0;
            var len: u8 = 1;
            while (len <= 16) : (len += 1) {
                var j: usize = 0;
                while (j < counts[len - 1]) : (j += 1) {
                    table.entries[table.count] = .{
                        .code = code,
                        .len = len,
                        .symbol = segment[pos + symbol_index],
                    };
                    table.count += 1;
                    code += 1;
                    symbol_index += 1;
                }
                code <<= 1;
            }
            if (class == 0) {
                self.huffman_dc[table_id] = table;
            } else {
                self.huffman_ac[table_id] = table;
            }
            pos += total;
        }
    }

    fn parseSos(self: *Decoder, segment: []const u8) bio.ReaderError!void {
        if (segment.len < 4) return error.TruncatedData;
        const count = segment[0];
        if (count != self.component_count) return error.UnsupportedVariant;
        if (segment.len < 1 + @as(usize, count) * 2 + 3) return error.TruncatedData;
        var pos: usize = 1;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const comp_id = segment[pos];
            const table_ids = segment[pos + 1];
            const comp_index = self.componentIndex(comp_id) orelse return error.InvalidFormat;
            self.components[comp_index].dc_table = table_ids >> 4;
            self.components[comp_index].ac_table = table_ids & 0x0f;
            if (self.components[comp_index].dc_table >= 4 or self.components[comp_index].ac_table >= 4) return error.InvalidFormat;
            pos += 2;
        }
        if (segment[pos] != 0 or segment[pos + 1] != 63 or segment[pos + 2] != 0) return error.UnsupportedVariant;
    }

    fn componentIndex(self: Decoder, id: u8) ?usize {
        var i: usize = 0;
        while (i < self.component_count) : (i += 1) {
            if (self.components[i].id == id) return i;
        }
        return null;
    }

    fn decode(self: *Decoder, allocator: std.mem.Allocator) bio.ReaderError![]u8 {
        if (self.scan_offset == 0) return error.InvalidFormat;
        const samples: usize = if (self.component_count == 1) 1 else 3;
        const pixel_count = std.math.mul(usize, self.width, self.height) catch return error.UnsupportedVariant;
        const out = try allocator.alloc(u8, std.math.mul(usize, pixel_count, samples) catch return error.UnsupportedVariant);
        errdefer allocator.free(out);

        var hmax: u8 = 1;
        var vmax: u8 = 1;
        var ci: usize = 0;
        while (ci < self.component_count) : (ci += 1) {
            hmax = @max(hmax, self.components[ci].h);
            vmax = @max(vmax, self.components[ci].v);
            if (self.quant_tables[self.components[ci].quant_table] == null or
                self.huffman_dc[self.components[ci].dc_table] == null or
                self.huffman_ac[self.components[ci].ac_table] == null) return error.InvalidFormat;
        }

        const mcu_w = @as(u32, hmax) * 8;
        const mcu_h = @as(u32, vmax) * 8;
        const mcu_cols = (self.width + mcu_w - 1) / mcu_w;
        const mcu_rows = (self.height + mcu_h - 1) / mcu_h;
        var bits = BitReader{ .data = self.data[self.scan_offset..] };
        var blocks: [4][16][64]u8 = undefined;
        var row: u32 = 0;
        while (row < mcu_rows) : (row += 1) {
            var col: u32 = 0;
            while (col < mcu_cols) : (col += 1) {
                ci = 0;
                while (ci < self.component_count) : (ci += 1) {
                    const comp = &self.components[ci];
                    var by: usize = 0;
                    while (by < comp.v) : (by += 1) {
                        var bx: usize = 0;
                        while (bx < comp.h) : (bx += 1) {
                            const block_index = by * comp.h + bx;
                            try self.decodeBlock(&bits, comp, &blocks[ci][block_index]);
                        }
                    }
                }
                try self.writeMcu(out, &blocks, col * mcu_w, row * mcu_h, hmax, vmax);
            }
        }
        return out;
    }

    fn decodeBlock(self: *Decoder, bits: *BitReader, comp: *Component, out: *[64]u8) bio.ReaderError!void {
        const dc_table = &(self.huffman_dc[comp.dc_table] orelse return error.InvalidFormat);
        const ac_table = &(self.huffman_ac[comp.ac_table] orelse return error.InvalidFormat);
        const quant = self.quant_tables[comp.quant_table] orelse return error.InvalidFormat;
        var coeffs = [_]i32{0} ** 64;
        const dc_len = dc_table.decode(bits) catch return error.TruncatedData;
        if (dc_len > 11) return error.InvalidFormat;
        const dc_delta = receiveExtend(bits, dc_len) catch return error.TruncatedData;
        comp.previous_dc += dc_delta;
        coeffs[0] = comp.previous_dc * quant[0];
        var k: usize = 1;
        while (k < 64) {
            const symbol = ac_table.decode(bits) catch return error.TruncatedData;
            const run = symbol >> 4;
            const size = symbol & 0x0f;
            if (size == 0) {
                if (run == 0) break;
                if (run == 15) {
                    k += 16;
                    continue;
                }
                return error.InvalidFormat;
            }
            k += run;
            if (k >= 64 or size > 10) return error.InvalidFormat;
            coeffs[zigzag[k]] = (receiveExtend(bits, size) catch return error.TruncatedData) * quant[zigzag[k]];
            k += 1;
        }
        inverseDct(coeffs, out);
    }

    fn writeMcu(self: Decoder, out: []u8, blocks: *[4][16][64]u8, origin_x: u32, origin_y: u32, hmax: u8, vmax: u8) bio.ReaderError!void {
        var y: u32 = 0;
        while (y < @as(u32, vmax) * 8 and origin_y + y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < @as(u32, hmax) * 8 and origin_x + x < self.width) : (x += 1) {
                const dst_pixel = (@as(usize, origin_y + y) * self.width + origin_x + x) * if (self.component_count == 1) @as(usize, 1) else 3;
                if (self.component_count == 1) {
                    out[dst_pixel] = sampleComponent(blocks, self.components[0], 0, x, y, hmax, vmax);
                } else {
                    const yy = sampleComponent(blocks, self.components[0], 0, x, y, hmax, vmax);
                    const cb = sampleComponent(blocks, self.components[1], 1, x, y, hmax, vmax);
                    const cr = sampleComponent(blocks, self.components[2], 2, x, y, hmax, vmax);
                    writeYCbCr(out[dst_pixel..][0..3], yy, cb, cr);
                }
            }
        }
    }
};

const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    bits: u8 = 0,
    buffer: u32 = 0,

    fn readBit(self: *BitReader) !u16 {
        if (self.bits == 0) try self.fillByte();
        self.bits -= 1;
        return @intCast((self.buffer >> @as(u5, @intCast(self.bits))) & 1);
    }

    fn readBits(self: *BitReader, count: u8) !u32 {
        var value: u32 = 0;
        var i: u8 = 0;
        while (i < count) : (i += 1) {
            value = (value << 1) | try self.readBit();
        }
        return value;
    }

    fn fillByte(self: *BitReader) !void {
        if (self.pos >= self.data.len) return error.TruncatedData;
        var byte = self.data[self.pos];
        self.pos += 1;
        if (byte == 0xff) {
            while (self.pos < self.data.len and self.data[self.pos] == 0xff) : (self.pos += 1) {}
            if (self.pos >= self.data.len) return error.TruncatedData;
            const marker = self.data[self.pos];
            self.pos += 1;
            if (marker != 0x00) return error.TruncatedData;
            byte = 0xff;
        }
        self.buffer = byte;
        self.bits = 8;
    }
};

fn sampleComponent(blocks: *[4][16][64]u8, comp: Component, comp_index: usize, x: u32, y: u32, hmax: u8, vmax: u8) u8 {
    const sx = x * comp.h / hmax;
    const sy = y * comp.v / vmax;
    const bx = sx / 8;
    const by = sy / 8;
    const lx = sx % 8;
    const ly = sy % 8;
    return blocks[comp_index][by * comp.h + bx][ly * 8 + lx];
}

fn receiveExtend(bits: *BitReader, count: u8) !i32 {
    if (count == 0) return 0;
    const value = try bits.readBits(count);
    const threshold = @as(u32, 1) << @as(u5, @intCast(count - 1));
    if (value >= threshold) return @intCast(value);
    return @as(i32, @intCast(value)) + 1 - (@as(i32, 1) << @as(u5, @intCast(count)));
}

fn inverseDct(coeffs: [64]i32, out: *[64]u8) void {
    var y: usize = 0;
    while (y < 8) : (y += 1) {
        var x: usize = 0;
        while (x < 8) : (x += 1) {
            var sum: f64 = 0;
            var v: usize = 0;
            while (v < 8) : (v += 1) {
                var u: usize = 0;
                while (u < 8) : (u += 1) {
                    const cu: f64 = if (u == 0) 0.7071067811865476 else 1.0;
                    const cv: f64 = if (v == 0) 0.7071067811865476 else 1.0;
                    const a = (@as(f64, @floatFromInt((2 * x + 1) * u)) * std.math.pi) / 16.0;
                    const b = (@as(f64, @floatFromInt((2 * y + 1) * v)) * std.math.pi) / 16.0;
                    sum += cu * cv * @as(f64, @floatFromInt(coeffs[v * 8 + u])) * @cos(a) * @cos(b);
                }
            }
            out[y * 8 + x] = clampToByte(@round(sum / 4.0 + 128.0));
        }
    }
}

fn writeYCbCr(out: *[3]u8, y: u8, cb: u8, cr: u8) void {
    const yy: f64 = @floatFromInt(y);
    const cbb = @as(f64, @floatFromInt(cb)) - 128.0;
    const crr = @as(f64, @floatFromInt(cr)) - 128.0;
    out[0] = clampToByte(@round(yy + 1.402 * crr));
    out[1] = clampToByte(@round(yy - 0.344136 * cbb - 0.714136 * crr));
    out[2] = clampToByte(@round(yy + 1.772 * cbb));
}

fn clampToByte(value: f64) u8 {
    if (value <= 0) return 0;
    if (value >= 255) return 255;
    return @intFromFloat(value);
}

const tiny_rgb_jpeg = [_]u8{
    0xff, 0xd8,
    0xff, 0xe0,
    0x00, 0x04,
    0x00, 0x00,
    0xff, 0xc0,
    0x00, 0x11,
    0x08, 0x00,
    0x02, 0x00,
    0x03, 0x03,
    0x01, 0x11,
    0x00, 0x02,
    0x11, 0x00,
    0x03, 0x11,
    0x00, 0xff,
    0xd9,
};

const tiny_gray_jpeg = [_]u8{
    0xff, 0xd8,
    0xff, 0xc0,
    0x00, 0x0b,
    0x08, 0x00,
    0x05, 0x00,
    0x07, 0x01,
    0x01, 0x11,
    0x00, 0xff,
    0xd9,
};

const one_pixel_red_jpeg = [_]u8{
    0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01, 0x00, 0x60,
    0x00, 0x60, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x43, 0x00, 0x03, 0x02, 0x02, 0x03, 0x02, 0x02, 0x03,
    0x03, 0x03, 0x03, 0x04, 0x03, 0x03, 0x04, 0x05, 0x08, 0x05, 0x05, 0x04, 0x04, 0x05, 0x0a, 0x07,
    0x07, 0x06, 0x08, 0x0c, 0x0a, 0x0c, 0x0c, 0x0b, 0x0a, 0x0b, 0x0b, 0x0d, 0x0e, 0x12, 0x10, 0x0d,
    0x0e, 0x11, 0x0e, 0x0b, 0x0b, 0x10, 0x16, 0x10, 0x11, 0x13, 0x14, 0x15, 0x15, 0x15, 0x0c, 0x0f,
    0x17, 0x18, 0x16, 0x14, 0x18, 0x12, 0x14, 0x15, 0x14, 0xff, 0xdb, 0x00, 0x43, 0x01, 0x03, 0x04,
    0x04, 0x05, 0x04, 0x05, 0x09, 0x05, 0x05, 0x09, 0x14, 0x0d, 0x0b, 0x0d, 0x14, 0x14, 0x14, 0x14,
    0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14,
    0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14,
    0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0x14, 0xff, 0xc0, 0x00,
    0x11, 0x08, 0x00, 0x01, 0x00, 0x01, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
    0xff, 0xc4, 0x00, 0x1f, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
    0x0b, 0xff, 0xc4, 0x00, 0xb5, 0x10, 0x00, 0x02, 0x01, 0x03, 0x03, 0x02, 0x04, 0x03, 0x05, 0x05,
    0x04, 0x04, 0x00, 0x00, 0x01, 0x7d, 0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31,
    0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42,
    0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18,
    0x19, 0x1a, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43,
    0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63,
    0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83,
    0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a,
    0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8,
    0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6,
    0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2,
    0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0xff, 0xc4, 0x00, 0x1f, 0x01, 0x00, 0x03, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02,
    0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0xff, 0xc4, 0x00, 0xb5, 0x11, 0x00, 0x02,
    0x01, 0x02, 0x04, 0x04, 0x03, 0x04, 0x07, 0x05, 0x04, 0x04, 0x00, 0x01, 0x02, 0x77, 0x00, 0x01,
    0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22,
    0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62,
    0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a,
    0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a,
    0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe2, 0xe3,
    0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
    0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3f, 0x00, 0xf9, 0xd2,
    0x8a, 0x28, 0xaf, 0xc3, 0x0f, 0xf5, 0x4c, 0xff, 0xd9,
};

test "reads rgb jpeg metadata from SOF segment" {
    const metadata = try readMetadata(&tiny_rgb_jpeg);
    try std.testing.expectEqualStrings("jpeg", metadata.format);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
}

test "reads grayscale jpeg metadata from SOF segment" {
    const metadata = try readMetadata(&tiny_gray_jpeg);
    try std.testing.expectEqual(@as(u32, 7), metadata.width);
    try std.testing.expectEqual(@as(u32, 5), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
}

test "decodes baseline rgb jpeg pixels" {
    const plane = try readPlaneIndex(std.testing.allocator, &one_pixel_red_jpeg, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("jpeg", plane.metadata.format);
    try std.testing.expectEqual(@as(u32, 1), plane.metadata.width);
    try std.testing.expectEqual(@as(u32, 1), plane.metadata.height);
    try std.testing.expectEqual(bio.PixelType.rgb8, plane.metadata.pixel_type);
    try std.testing.expectEqual(@as(usize, 3), plane.data.len);
    try std.testing.expect(plane.data[0] > 200);
    try std.testing.expect(plane.data[1] < 80);
    try std.testing.expect(plane.data[2] < 80);
}
