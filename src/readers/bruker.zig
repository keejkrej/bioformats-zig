const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;

const Header = struct {
    width: u32,
    height: u32,
    size_z: u16,
    size_t: u16,
    pixel_type: bio.PixelType,
    little_endian: bool,
};

const ParseState = struct {
    sizes: [3]u32 = .{ 0, 0, 0 },
    size_count: u8 = 0,
    ni: u32 = 1,
    nr: u32 = 1,
    ns: u32 = 1,
    bits: u32 = 0,
    signed: bool = false,
    is_float: bool = false,
    little_endian: bool = true,
    im_size_x: u32 = 0,
    im_size_y: u32 = 0,
    im_size_z: u32 = 0,
    im_size_t: u32 = 0,
};

const DatasetPaths = struct {
    acquisition_dir: []u8,
    acqp: []u8,
    reco: []u8,
    pixels: []u8,

    fn deinit(self: DatasetPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.acquisition_dir);
        allocator.free(self.acqp);
        allocator.free(self.reco);
        allocator.free(self.pixels);
    }
};

pub fn matches(data: []const u8) bool {
    _ = data;
    return false;
}

pub fn isPath(path: []const u8) bool {
    const name = basename(path);
    return std.mem.eql(u8, name, "acqp") or
        std.mem.eql(u8, name, "fid") or
        std.mem.eql(u8, name, "reco") or
        std.mem.eql(u8, name, "2dseq");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    _ = data;
    return error.UnsupportedFormat;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedFormat;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const paths = try datasetPaths(allocator, path);
    defer paths.deinit(allocator);
    const header = try readHeader(allocator, io, paths.acqp, paths.reco);
    return metadataFromHeader(header);
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const paths = try datasetPaths(allocator, path);
    defer paths.deinit(allocator);
    const header = try readHeader(allocator, io, paths.acqp, paths.reco);
    const metadata = metadataFromHeader(header);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    try region.validate(metadata);

    const pixels = try readFile(allocator, io, paths.pixels);
    defer allocator.free(pixels);
    const plane_len = try planeByteCount(metadata);
    const offset = std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant;
    if (offset > pixels.len or pixels.len - offset < plane_len) return error.TruncatedData;

    if (region.isFull(metadata)) {
        const out = try allocator.alloc(u8, plane_len);
        @memcpy(out, pixels[offset..][0..plane_len]);
        return .{ .metadata = metadata, .data = out };
    }

    const bytes_per_pixel = metadata.bytesPerPixel();
    const src_row_bytes = std.math.mul(usize, metadata.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const dst_row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, dst_row_bytes, region.height) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    var row: usize = 0;
    while (row < region.height) : (row += 1) {
        const src_y = @as(usize, region.y) + row;
        const src_x = @as(usize, region.x) * bytes_per_pixel;
        const src_offset = offset + src_y * src_row_bytes + src_x;
        const dst_offset = row * dst_row_bytes;
        @memcpy(out[dst_offset..][0..dst_row_bytes], pixels[src_offset..][0..dst_row_bytes]);
    }
    return .{ .metadata = metadata, .data = out };
}

fn metadataFromHeader(header: Header) bio.Metadata {
    return .{
        .format = "bruker",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .size_z = header.size_z,
        .size_t = header.size_t,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
        .little_endian = header.little_endian,
        .plane_count = @as(u32, header.size_z) * @as(u32, header.size_t),
        .dimension_order = "XYCTZ",
    };
}

fn readHeader(allocator: std.mem.Allocator, io: std.Io, acqp_path: []const u8, reco_path: []const u8) !Header {
    const acqp = try readFile(allocator, io, acqp_path);
    defer allocator.free(acqp);
    const reco = try readFile(allocator, io, reco_path);
    defer allocator.free(reco);

    var state: ParseState = .{};
    try parseLines(acqp, &state);
    try parseLines(reco, &state);
    if (state.bits == 0) return error.InvalidFormat;
    if (state.size_count == 0 and state.im_size_x == 0) return error.InvalidFormat;

    var width = state.im_size_x;
    var height = state.im_size_y;
    var size_z = state.im_size_z;
    var size_t = state.im_size_t;

    const td = if (state.size_count >= 1) state.sizes[0] else width;
    const ys = if (state.size_count >= 2) state.sizes[1] else height;
    const zs = if (state.size_count >= 3) state.sizes[2] else @as(u32, 1);

    if (height == 0 or size_z == 0) {
        if (state.size_count == 2) {
            height = ys;
            size_z = if (state.ni == 1) state.nr else state.ni;
        } else if (state.size_count >= 3) {
            height = state.ni * ys;
            size_z = state.nr * zs;
        }
    }
    if (width == 0) width = td;
    if (size_z == 0) size_z = 1;
    if (size_t == 0) {
        if (state.ns == 0) state.ns = 1;
        if (state.nr == 0) state.nr = 1;
        size_z /= state.ns;
        if (size_z == 0) size_z = 1;
        size_t = state.ns * state.nr;
    }
    if (width == 0 or height == 0 or size_z == 0 or size_t == 0) return error.InvalidFormat;
    if (size_z > std.math.maxInt(u16) or size_t > std.math.maxInt(u16)) return error.UnsupportedVariant;

    return .{
        .width = width,
        .height = height,
        .size_z = @intCast(size_z),
        .size_t = @intCast(size_t),
        .pixel_type = try pixelTypeFromInfo(state.bits, state.signed, state.is_float),
        .little_endian = state.little_endian,
    };
}

fn parseLines(data: []const u8, state: *ParseState) bio.ReaderError!void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    var pending_key: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (pending_key) |key| {
            try parseKeyValue(key, stripAngle(line), state);
            pending_key = null;
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..equals];
        var value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (value.len > 0 and value[0] == '(') {
            pending_key = key;
            continue;
        }
        value = stripAngle(value);
        try parseKeyValue(key, value, state);
    }
}

fn parseKeyValue(key: []const u8, value: []const u8, state: *ParseState) bio.ReaderError!void {
    if (std.mem.eql(u8, key, "##$NI")) {
        state.ni = try parsePositiveU32(value);
    } else if (std.mem.eql(u8, key, "##$NR")) {
        state.nr = try parsePositiveU32(value);
    } else if (std.mem.eql(u8, key, "##$ACQ_word_size")) {
        state.bits = try parseAcqWordBits(value);
        state.signed = false;
        state.is_float = false;
    } else if (std.mem.eql(u8, key, "##$BYTORDA")) {
        state.little_endian = std.ascii.eqlIgnoreCase(value, "little");
    } else if (std.mem.eql(u8, key, "##$ACQ_size") or std.mem.eql(u8, key, "##$RECO_size")) {
        state.size_count = try parseSizes(value, &state.sizes);
    } else if (std.mem.eql(u8, key, "##$ACQ_ns_list_size")) {
        state.ns = try parsePositiveU32(value);
    } else if (std.mem.eql(u8, key, "##$RECO_wordtype")) {
        state.bits = try parseRecoWordBits(value);
        state.signed = std.mem.indexOf(u8, value, "_SGN_") != null;
        state.is_float = !std.mem.endsWith(u8, value, "_INT");
    } else if (std.mem.eql(u8, key, "##$IM_SIX")) {
        state.im_size_x = try parsePositiveU32(value);
    } else if (std.mem.eql(u8, key, "##$IM_SIY")) {
        state.im_size_y = try parsePositiveU32(value);
    } else if (std.mem.eql(u8, key, "##$IM_SIZ")) {
        state.im_size_z = try parsePositiveU32(value);
    } else if (std.mem.eql(u8, key, "##$IM_SIT")) {
        state.im_size_t = try parsePositiveU32(value);
    }
}

fn pixelTypeFromInfo(bits: u32, signed: bool, is_float: bool) bio.ReaderError!bio.PixelType {
    return switch (bits) {
        8 => if (signed) .int8 else .uint8,
        16 => if (signed) .int16 else .uint16,
        32 => if (is_float) .float32 else if (signed) .int32 else .uint32,
        64 => if (is_float) .float64 else error.UnsupportedVariant,
        else => error.UnsupportedVariant,
    };
}

fn parseAcqWordBits(value: []const u8) bio.ReaderError!u32 {
    var digits: [16]u8 = undefined;
    var len: usize = 0;
    for (value) |c| {
        if (std.ascii.isDigit(c)) {
            if (len == digits.len) return error.InvalidFormat;
            digits[len] = c;
            len += 1;
        } else if (len > 0) break;
    }
    if (len == 0) return error.InvalidFormat;
    return try parsePositiveU32(digits[0..len]);
}

fn parseRecoWordBits(value: []const u8) bio.ReaderError!u32 {
    return parseAcqWordBits(value);
}

fn parseSizes(value: []const u8, out: *[3]u32) bio.ReaderError!u8 {
    var tokens = std.mem.tokenizeAny(u8, value, " \t");
    var count: u8 = 0;
    while (tokens.next()) |token| {
        if (count == out.len) return error.UnsupportedVariant;
        out[count] = try parsePositiveU32(token);
        count += 1;
    }
    if (count == 0) return error.InvalidFormat;
    return count;
}

fn datasetPaths(allocator: std.mem.Allocator, path: []const u8) !DatasetPaths {
    if (!isPath(path)) return error.InvalidFormat;
    const name = basename(path);
    const acquisition_dir = if (std.mem.eql(u8, name, "reco") or std.mem.eql(u8, name, "2dseq"))
        try ancestorPath(allocator, path, 3)
    else
        try parentPath(allocator, path);
    errdefer allocator.free(acquisition_dir);

    const acqp = try joinPath(allocator, acquisition_dir, "acqp");
    errdefer allocator.free(acqp);
    const pdata = try joinPath(allocator, acquisition_dir, "pdata/1/reco");
    errdefer allocator.free(pdata);
    const pixels = try joinPath(allocator, acquisition_dir, "pdata/1/2dseq");
    errdefer allocator.free(pixels);
    return .{ .acquisition_dir = acquisition_dir, .acqp = acqp, .reco = pdata, .pixels = pixels };
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn parentPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const sep = lastSeparator(path) orelse return allocator.dupe(u8, ".");
    if (sep == 0) return allocator.dupe(u8, path[0..1]);
    return allocator.dupe(u8, path[0..sep]);
}

fn ancestorPath(allocator: std.mem.Allocator, path: []const u8, levels: u8) ![]u8 {
    var end = path.len;
    var level: u8 = 0;
    while (level < levels) : (level += 1) {
        const sep = lastSeparator(path[0..end]) orelse return allocator.dupe(u8, ".");
        end = sep;
        if (end == 0) break;
    }
    if (end == 0) return allocator.dupe(u8, path[0..1]);
    return allocator.dupe(u8, path[0..end]);
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, relative: []const u8) ![]u8 {
    const sep: u8 = if (std.mem.indexOfScalar(u8, base, '\\') != null) '\\' else '/';
    const normalized = try allocator.dupe(u8, relative);
    defer allocator.free(normalized);
    if (sep == '\\') {
        for (normalized) |*c| {
            if (c.* == '/') c.* = '\\';
        }
    }
    const needs_sep = base.len != 0 and base[base.len - 1] != '/' and base[base.len - 1] != '\\';
    const extra: usize = if (needs_sep) 1 else 0;
    const out = try allocator.alloc(u8, base.len + extra + normalized.len);
    @memcpy(out[0..base.len], base);
    if (needs_sep) out[base.len] = sep;
    @memcpy(out[base.len + extra ..], normalized);
    return out;
}

fn basename(path: []const u8) []const u8 {
    const slash = lastSeparator(path) orelse return path;
    return path[slash + 1 ..];
}

fn lastSeparator(path: []const u8) ?usize {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    if (slash == null) return backslash;
    if (backslash == null) return slash;
    return @max(slash.?, backslash.?);
}

fn stripAngle(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '<' and value[value.len - 1] == '>') return value[1 .. value.len - 1];
    return value;
}

fn parsePositiveU32(value: []const u8) bio.ReaderError!u32 {
    const parsed = std.fmt.parseInt(u32, std.mem.trim(u8, value, " \t\r\n"), 10) catch return error.InvalidFormat;
    if (parsed == 0) return error.InvalidFormat;
    return parsed;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

test "reads bruker acqp reco metadata" {
    const acqp =
        "##$NI=1\n" ++
        "##$NR=2\n" ++
        "##$BYTORDA=little\n" ++
        "##$ACQ_size=( 2 )\n" ++
        "2 2\n";
    const reco =
        "##$RECO_size=( 2 )\n" ++
        "2 2\n" ++
        "##$RECO_wordtype=_16BIT_SGN_INT\n";
    var state: ParseState = .{};
    try parseLines(acqp, &state);
    try parseLines(reco, &state);
    try std.testing.expectEqual(@as(u8, 2), state.size_count);
    try std.testing.expectEqual(@as(u32, 16), state.bits);
    try std.testing.expect(state.signed);
    const header = try readHeaderFromStateForTest(state);
    const metadata = metadataFromHeader(header);
    try std.testing.expectEqualStrings("bruker", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(bio.PixelType.int16, metadata.pixel_type);
}

fn readHeaderFromStateForTest(state: ParseState) bio.ReaderError!Header {
    const copy = state;
    var width = copy.im_size_x;
    var height = copy.im_size_y;
    var size_z = copy.im_size_z;
    var size_t = copy.im_size_t;
    const td = if (copy.size_count >= 1) copy.sizes[0] else width;
    const ys = if (copy.size_count >= 2) copy.sizes[1] else height;
    const zs = if (copy.size_count >= 3) copy.sizes[2] else @as(u32, 1);
    if (height == 0 or size_z == 0) {
        if (copy.size_count == 2) {
            height = ys;
            size_z = if (copy.ni == 1) copy.nr else copy.ni;
        } else if (copy.size_count >= 3) {
            height = copy.ni * ys;
            size_z = copy.nr * zs;
        }
    }
    if (width == 0) width = td;
    if (size_t == 0) {
        size_z /= copy.ns;
        size_t = copy.ns * copy.nr;
    }
    return .{
        .width = width,
        .height = height,
        .size_z = @intCast(size_z),
        .size_t = @intCast(size_t),
        .pixel_type = try pixelTypeFromInfo(copy.bits, copy.signed, copy.is_float),
        .little_endian = copy.little_endian,
    };
}

test "reads bruker path companion pixels with crop" {
    const root = "bruker-test";
    const acq = "bruker-test/1";
    const pdata = "bruker-test/1/pdata";
    const pdata_one = "bruker-test/1/pdata/1";
    const acqp_path = "bruker-test/1/acqp";
    const reco_path = "bruker-test/1/pdata/1/reco";
    const pixels_path = "bruker-test/1/pdata/1/2dseq";
    std.Io.Dir.cwd().deleteFile(std.testing.io, pixels_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, reco_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, acqp_path) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, pdata_one) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, pdata) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, acq) catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, acq, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, acq) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, pdata, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, pdata) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, pdata_one, .default_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, pdata_one) catch {};

    const acqp = "##$NI=1\n##$NR=1\n##$BYTORDA=little\n##$ACQ_size=( 2 )\n2 2\n";
    const reco = "##$RECO_size=( 2 )\n2 2\n##$RECO_wordtype=_16BIT_UNSGN_INT\n";
    const pixels = [_]u8{ 1, 0, 2, 0, 3, 0, 4, 0 };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = acqp_path, .data = acqp });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, acqp_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = reco_path, .data = reco });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, reco_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = pixels_path, .data = &pixels });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, pixels_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, acqp_path, 0, .{ .x = 1, .y = 0, .width = 1, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("bruker", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 4, 0 }, plane.data);
}
