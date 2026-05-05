const std = @import("std");
const bio = @import("../root.zig");

const max_probe_bytes = 1024 * 1024;

pub fn matches(data: []const u8) bool {
    if (data.len < 8) return false;
    return scanForQuickTime(data, 0, @min(data.len, max_probe_bytes), 0) catch false;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!matches(data)) return error.InvalidFormat;

    var state = ScanState{};
    try scanAtoms(data, 0, data.len, 0, &state);
    if (state.width == 0 or state.height == 0) return error.InvalidFormat;

    const bits = if (state.bits_per_pixel == 0) 24 else state.bits_per_pixel;
    const samples: u16 = if (bits < 40) 3 else 1;
    const frames = if (state.frame_count > 0) state.frame_count else if (state.chunk_count > 0) state.chunk_count else 1;
    return .{
        .format = "qt",
        .width = state.width,
        .height = state.height,
        .size_c = samples,
        .samples_per_pixel = samples,
        .size_z = 1,
        .size_t = @intCast(@min(frames, std.math.maxInt(u16))),
        .pixel_type = pixelType(bits, samples),
        .little_endian = false,
        .plane_count = frames,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;

    var state = ScanState{ .target_index = plane_index };
    try scanAtoms(data, 0, data.len, 0, &state);
    if (!std.mem.eql(u8, state.codec[0..], "raw ")) return error.UnsupportedVariant;
    if (state.bits_per_pixel != 24 and state.bits_per_pixel != 32) return error.UnsupportedVariant;

    const target_size = state.target_size orelse try rawFrameSize(state.width, state.height, state.bits_per_pixel);
    const target_offset = resolveFrameOffset(state, target_size, plane_index) orelse return error.UnsupportedVariant;
    if (target_offset + target_size > data.len) return error.TruncatedData;
    const frame = data[target_offset .. target_offset + target_size];

    const out_len = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, std.math.mul(usize, out_len, 3) catch return error.UnsupportedVariant);
    errdefer allocator.free(out);

    if (state.bits_per_pixel == 32) {
        const needed = std.math.mul(usize, out_len, 4) catch return error.UnsupportedVariant;
        if (frame.len < needed) return error.TruncatedData;
        var pixel: usize = 0;
        while (pixel < out_len) : (pixel += 1) {
            const src = pixel * 4 + 1;
            const dst = pixel * 3;
            @memcpy(out[dst .. dst + 3], frame[src .. src + 3]);
        }
    } else {
        const row_bytes = std.math.mul(usize, metadata.width, 3) catch return error.UnsupportedVariant;
        const expected = std.math.mul(usize, row_bytes, metadata.height) catch return error.UnsupportedVariant;
        if (frame.len == expected) {
            @memcpy(out, frame[0..expected]);
        } else {
            const padded_row = row_bytes + ((4 - (metadata.width % 4)) % 4);
            const needed = std.math.mul(usize, padded_row, metadata.height) catch return error.UnsupportedVariant;
            if (frame.len < needed) return error.TruncatedData;
            var row: usize = 0;
            while (row < metadata.height) : (row += 1) {
                @memcpy(out[row * row_bytes ..][0..row_bytes], frame[row * padded_row ..][0..row_bytes]);
            }
        }
    }

    return .{ .metadata = metadata, .data = out };
}

const ScanState = struct {
    width: u32 = 0,
    height: u32 = 0,
    bits_per_pixel: u16 = 0,
    frame_count: u32 = 0,
    chunk_count: u32 = 0,
    codec: [4]u8 = .{ 0, 0, 0, 0 },
    mdat_start: usize = 0,
    mdat_end: usize = 0,
    target_index: ?u32 = null,
    first_offset: ?usize = null,
    target_offset: ?usize = null,
    target_size: ?usize = null,
};

const Atom = struct {
    kind: []const u8,
    payload_start: usize,
    payload_end: usize,
    next: usize,
};

fn scanForQuickTime(data: []const u8, start: usize, end: usize, depth: u8) bio.ReaderError!bool {
    if (depth > 8) return false;
    var pos = start;
    while (pos + 8 <= end and pos + 8 <= data.len) {
        const atom = nextAtom(data, pos, end) catch return false;
        if (std.mem.eql(u8, atom.kind, "ftyp")) {
            const payload = data[atom.payload_start..atom.payload_end];
            if (payload.len >= 4 and std.mem.eql(u8, payload[0..4], "qt  ")) return true;
            var brand_pos: usize = 8;
            while (brand_pos + 4 <= payload.len) : (brand_pos += 4) {
                if (std.mem.eql(u8, payload[brand_pos..][0..4], "qt  ")) return true;
            }
        }
        if (std.mem.eql(u8, atom.kind, "moov") or std.mem.eql(u8, atom.kind, "mdat") or std.mem.eql(u8, atom.kind, "wide")) return true;
        if (isContainer(atom.kind) and try scanForQuickTime(data, atom.payload_start, atom.payload_end, depth + 1)) return true;
        if (atom.next <= pos) return false;
        pos = atom.next;
    }
    return false;
}

fn scanAtoms(data: []const u8, start: usize, end: usize, depth: u8, state: *ScanState) bio.ReaderError!void {
    if (depth > 16) return error.UnsupportedVariant;
    var pos = start;
    while (pos + 8 <= end and pos + 8 <= data.len) {
        const atom = try nextAtom(data, pos, end);
        const payload = data[atom.payload_start..atom.payload_end];

        if (isContainer(atom.kind)) {
            try scanAtoms(data, atom.payload_start, atom.payload_end, depth + 1, state);
        } else if (std.mem.eql(u8, atom.kind, "tkhd")) {
            parseTkhd(payload, state) catch {};
        } else if (std.mem.eql(u8, atom.kind, "stsd")) {
            try parseStsd(payload, state);
        } else if (std.mem.eql(u8, atom.kind, "stsz")) {
            parseStsz(payload, state) catch {};
        } else if (std.mem.eql(u8, atom.kind, "stco")) {
            parseStco(payload, state) catch {};
        } else if (std.mem.eql(u8, atom.kind, "mdat")) {
            state.mdat_start = atom.payload_start;
            state.mdat_end = atom.payload_end;
        }

        if (atom.next <= pos) return error.InvalidFormat;
        pos = atom.next;
    }
}

fn nextAtom(data: []const u8, pos: usize, end: usize) bio.ReaderError!Atom {
    if (pos + 8 > data.len or pos + 8 > end) return error.TruncatedData;
    var atom_size: u64 = beU32(data[pos..][0..4]);
    const kind_start = pos + 4;
    var payload_start = pos + 8;
    if (atom_size == 1) {
        if (pos + 16 > data.len or pos + 16 > end) return error.TruncatedData;
        atom_size = beU64(data[pos + 8 ..][0..8]);
        payload_start = pos + 16;
    } else if (atom_size == 0) {
        atom_size = end - pos;
    }
    const header_len = payload_start - pos;
    if (atom_size < header_len) return error.InvalidFormat;
    const atom_len = std.math.cast(usize, atom_size) orelse return error.UnsupportedVariant;
    const next = std.math.add(usize, pos, atom_len) catch return error.UnsupportedVariant;
    if (next > data.len or next > end) return error.TruncatedData;
    return .{
        .kind = data[kind_start..][0..4],
        .payload_start = payload_start,
        .payload_end = next,
        .next = next,
    };
}

fn isContainer(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "moov") or
        std.mem.eql(u8, kind, "trak") or
        std.mem.eql(u8, kind, "udta") or
        std.mem.eql(u8, kind, "tref") or
        std.mem.eql(u8, kind, "imap") or
        std.mem.eql(u8, kind, "mdia") or
        std.mem.eql(u8, kind, "minf") or
        std.mem.eql(u8, kind, "stbl") or
        std.mem.eql(u8, kind, "edts") or
        std.mem.eql(u8, kind, "mdra") or
        std.mem.eql(u8, kind, "rmra") or
        std.mem.eql(u8, kind, "imag") or
        std.mem.eql(u8, kind, "vnrp") or
        std.mem.eql(u8, kind, "dinf");
}

fn parseTkhd(payload: []const u8, state: *ScanState) !void {
    if (payload.len < 4) return error.TruncatedData;
    const matrix_start: usize = switch (payload[0]) {
        0 => 40,
        1 => 52,
        else => return error.UnsupportedVariant,
    };
    if (payload.len < matrix_start + 44) return error.TruncatedData;
    const width = fixed16_16(payload[matrix_start + 36 ..][0..4]);
    const height = fixed16_16(payload[matrix_start + 40 ..][0..4]);
    if (width > 0 and state.width == 0) state.width = width;
    if (height > 0 and state.height == 0) state.height = height;
}

fn parseStsd(payload: []const u8, state: *ScanState) bio.ReaderError!void {
    if (payload.len < 16) return error.TruncatedData;
    const entry_count = beU32(payload[4..8]);
    var pos: usize = 8;
    var i: u32 = 0;
    while (i < entry_count and pos + 8 <= payload.len) : (i += 1) {
        const entry_size = try checkedUsize(beU32(payload[pos..][0..4]));
        if (entry_size < 8 or pos + entry_size > payload.len) return error.TruncatedData;
        const codec = payload[pos + 4 ..][0..4];
        if (i == 0 and !isSupportedCodec(codec)) return error.UnsupportedVariant;
        if (i == 0) @memcpy(&state.codec, codec);
        if (entry_size >= 86) {
            const width = beU16(payload[pos + 32 ..][0..2]);
            const height = beU16(payload[pos + 34 ..][0..2]);
            if (state.width == 0 and width > 0) state.width = width;
            if (state.height == 0 and height > 0) state.height = height;
            if (i == 0) state.bits_per_pixel = beU16(payload[pos + 82 ..][0..2]);
        }
        pos += entry_size;
    }
}

fn parseStsz(payload: []const u8, state: *ScanState) !void {
    if (payload.len < 12) return error.TruncatedData;
    const sample_size = beU32(payload[4..8]);
    const count = beU32(payload[8..12]);
    if (count > 0) state.frame_count = count;
    if (state.target_index) |target| {
        if (target >= count) return;
        state.target_size = if (sample_size != 0) try checkedUsize(sample_size) else size: {
            const offset = 12 + @as(usize, target) * 4;
            if (offset + 4 > payload.len) return error.TruncatedData;
            break :size try checkedUsize(beU32(payload[offset..][0..4]));
        };
    }
}

fn parseStco(payload: []const u8, state: *ScanState) !void {
    if (payload.len < 8) return error.TruncatedData;
    const count = beU32(payload[4..8]);
    if (count > 0) state.chunk_count = count;
    if (state.target_index) |target| {
        if (target >= count) return;
        const offset = 8 + @as(usize, target) * 4;
        if (offset + 4 > payload.len) return error.TruncatedData;
        state.target_offset = try checkedUsize(beU32(payload[offset..][0..4]));
    }
    if (count > 0 and payload.len >= 12) state.first_offset = try checkedUsize(beU32(payload[8..12]));
}

fn isSupportedCodec(codec: []const u8) bool {
    return std.mem.eql(u8, codec, "raw ") or
        std.mem.eql(u8, codec, "rle ") or
        std.mem.eql(u8, codec, "rpza") or
        std.mem.eql(u8, codec, "mjpb") or
        std.mem.eql(u8, codec, "jpeg");
}

fn pixelType(bits: u16, samples: u16) bio.PixelType {
    if (samples > 1) return if (bits > 32) .rgb16 else .rgb8;
    return if ((bits / 8) == 2) .uint16 else .uint8;
}

fn rawFrameSize(width: u32, height: u32, bits_per_pixel: u16) bio.ReaderError!usize {
    const bytes_per_pixel: usize = switch (bits_per_pixel) {
        24 => 3,
        32 => 4,
        else => return error.UnsupportedVariant,
    };
    const pixels = std.math.mul(usize, width, height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, bytes_per_pixel) catch return error.UnsupportedVariant;
}

fn resolveFrameOffset(state: ScanState, target_size: usize, plane_index: u32) ?usize {
    if (state.target_offset) |offset| {
        if (state.first_offset) |first| {
            if (offset >= first) {
                const relative = offset - first;
                const from_mdat = std.math.add(usize, state.mdat_start, relative) catch return null;
                if (from_mdat < state.mdat_end) return from_mdat;
            }
        }
        if (offset >= state.mdat_start and offset < state.mdat_end) return offset;
    }
    if (state.mdat_start == 0) return null;
    const relative = std.math.mul(usize, target_size, plane_index) catch return null;
    return std.math.add(usize, state.mdat_start, relative) catch null;
}

fn fixed16_16(bytes: []const u8) u32 {
    const raw = beU32(bytes);
    const whole = raw >> 16;
    return if (whole > 0) whole else raw;
}

fn beU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

fn beU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

fn beU64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .big);
}

fn checkedUsize(value: anytype) bio.ReaderError!usize {
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
}

fn appendAtom(allocator: std.mem.Allocator, list: *std.ArrayList(u8), kind: []const u8, payload: []const u8) !void {
    try appendU32Be(allocator, list, @intCast(8 + payload.len));
    try list.appendSlice(allocator, kind);
    try list.appendSlice(allocator, payload);
}

fn appendContainer(allocator: std.mem.Allocator, list: *std.ArrayList(u8), kind: []const u8, children: []const u8) !void {
    try appendAtom(allocator, list, kind, children);
}

fn appendU16Be(allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: u16) !void {
    try list.append(allocator, @intCast((value >> 8) & 0xff));
    try list.append(allocator, @intCast(value & 0xff));
}

fn appendU32Be(allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: u32) !void {
    try list.append(allocator, @intCast((value >> 24) & 0xff));
    try list.append(allocator, @intCast((value >> 16) & 0xff));
    try list.append(allocator, @intCast((value >> 8) & 0xff));
    try list.append(allocator, @intCast(value & 0xff));
}

fn appendZeros(allocator: std.mem.Allocator, list: *std.ArrayList(u8), count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try list.append(allocator, 0);
}

fn appendTkhd(allocator: std.mem.Allocator, list: *std.ArrayList(u8), width: u16, height: u16) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try appendU32Be(allocator, &payload, 0x00000007);
    try appendZeros(allocator, &payload, 36);
    try appendU32Be(allocator, &payload, 0x00010000);
    try appendU32Be(allocator, &payload, 0);
    try appendU32Be(allocator, &payload, 0);
    try appendU32Be(allocator, &payload, 0);
    try appendU32Be(allocator, &payload, 0x00010000);
    try appendU32Be(allocator, &payload, 0);
    try appendU32Be(allocator, &payload, 0);
    try appendU32Be(allocator, &payload, 0);
    try appendU32Be(allocator, &payload, 0x40000000);
    try appendU32Be(allocator, &payload, @as(u32, width) << 16);
    try appendU32Be(allocator, &payload, @as(u32, height) << 16);
    try appendAtom(allocator, list, "tkhd", payload.items);
}

fn appendStsd(allocator: std.mem.Allocator, list: *std.ArrayList(u8), width: u16, height: u16, depth: u16) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try appendU32Be(allocator, &payload, 0);
    try appendU32Be(allocator, &payload, 1);
    try appendU32Be(allocator, &payload, 86);
    try payload.appendSlice(allocator, "raw ");
    try appendZeros(allocator, &payload, 6);
    try appendU16Be(allocator, &payload, 1);
    try appendZeros(allocator, &payload, 16);
    try appendU16Be(allocator, &payload, width);
    try appendU16Be(allocator, &payload, height);
    try appendU32Be(allocator, &payload, 0x00480000);
    try appendU32Be(allocator, &payload, 0x00480000);
    try appendU32Be(allocator, &payload, 0);
    try appendU16Be(allocator, &payload, 1);
    try appendZeros(allocator, &payload, 32);
    try appendU16Be(allocator, &payload, depth);
    try appendU16Be(allocator, &payload, 0xffff);
    try appendAtom(allocator, list, "stsd", payload.items);
}

fn appendStsz(allocator: std.mem.Allocator, list: *std.ArrayList(u8), frames: u32, frame_size: u32) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try appendU32Be(allocator, &payload, 0);
    try appendU32Be(allocator, &payload, 0);
    try appendU32Be(allocator, &payload, frames);
    var i: u32 = 0;
    while (i < frames) : (i += 1) try appendU32Be(allocator, &payload, frame_size);
    try appendAtom(allocator, list, "stsz", payload.items);
}

fn appendStco(allocator: std.mem.Allocator, list: *std.ArrayList(u8), frames: u32, frame_size: u32) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try appendU32Be(allocator, &payload, 0);
    try appendU32Be(allocator, &payload, frames);
    var i: u32 = 0;
    while (i < frames) : (i += 1) try appendU32Be(allocator, &payload, 128 + i * frame_size);
    try appendAtom(allocator, list, "stco", payload.items);
}

fn minimalMov(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var ftyp: std.ArrayList(u8) = .empty;
    defer ftyp.deinit(allocator);
    try ftyp.appendSlice(allocator, "qt  ");
    try appendU32Be(allocator, &ftyp, 0);
    try ftyp.appendSlice(allocator, "qt  ");
    try appendAtom(allocator, &out, "ftyp", ftyp.items);

    var stbl: std.ArrayList(u8) = .empty;
    defer stbl.deinit(allocator);
    try appendStsd(allocator, &stbl, 12, 9, 24);
    try appendStsz(allocator, &stbl, 2, 12 * 9 * 3);
    try appendStco(allocator, &stbl, 2, 12 * 9 * 3);

    var minf: std.ArrayList(u8) = .empty;
    defer minf.deinit(allocator);
    try appendContainer(allocator, &minf, "stbl", stbl.items);

    var mdia: std.ArrayList(u8) = .empty;
    defer mdia.deinit(allocator);
    try appendContainer(allocator, &mdia, "minf", minf.items);

    var trak: std.ArrayList(u8) = .empty;
    defer trak.deinit(allocator);
    try appendTkhd(allocator, &trak, 12, 9);
    try appendContainer(allocator, &trak, "mdia", mdia.items);

    var moov: std.ArrayList(u8) = .empty;
    defer moov.deinit(allocator);
    try appendContainer(allocator, &moov, "trak", trak.items);
    try appendContainer(allocator, &out, "moov", moov.items);

    var mdat: std.ArrayList(u8) = .empty;
    defer mdat.deinit(allocator);
    var i: u16 = 0;
    while (i < 12 * 9 * 3 * 2) : (i += 1) {
        try mdat.append(allocator, @intCast(i % 251));
    }
    try appendAtom(allocator, &out, "mdat", mdat.items);

    return out.toOwnedSlice(allocator);
}

test "reads quicktime movie metadata" {
    const data = try minimalMov(std.testing.allocator);
    defer std.testing.allocator.free(data);

    try std.testing.expect(matches(data));
    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("qt", metadata.format);
    try std.testing.expectEqual(@as(u32, 12), metadata.width);
    try std.testing.expectEqual(@as(u32, 9), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
}

test "reads quicktime raw rgb plane" {
    const data = try minimalMov(std.testing.allocator);
    defer std.testing.allocator.free(data);

    const plane = try readPlaneIndex(std.testing.allocator, data, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("qt", plane.metadata.format);
    try std.testing.expectEqual(@as(usize, 12 * 9 * 3), plane.data.len);
    try std.testing.expectEqual(@as(u8, @intCast((12 * 9 * 3) % 251)), plane.data[0]);
}
