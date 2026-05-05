const std = @import("std");
const bio = @import("../root.zig");

const magic = "Header file for data file";
const max_companion_bytes = 512 * 1024 * 1024;

const Header = struct {
    data_file: ?[]const u8,
    width: u32,
    height: u32,
    size_z: u16,
    size_t: u16,
    pixel_type: bio.PixelType,
    little_endian: bool,
    data_offset: usize,
    description: ?[]const u8 = null,
};

pub fn matches(data: []const u8) bool {
    return data.len >= magic.len and std.mem.indexOf(u8, data[0..@min(data.len, 128)], magic) != null;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "hdr") or hasExtension(path, "dat") or hasExtension(path, "img");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    return metadataFromHeader(try parseHeader(data));
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    if (plane_index >= (readMetadata(data) catch return error.InvalidFormat).plane_count) return error.InvalidPlaneIndex;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const hdr = try readHdrFile(allocator, io, path);
    defer allocator.free(hdr);
    return readMetadata(hdr);
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const hdr = try readHdrFile(allocator, io, path);
    defer allocator.free(hdr);
    const header = try parseHeader(hdr);
    const metadata = metadataFromHeader(header);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    try region.validate(metadata);

    const dat = try readDatFile(allocator, io, path, header);
    defer allocator.free(dat);

    const plane_len = try planeByteCount(metadata);
    const plane_offset = std.math.mul(usize, plane_len, plane_index) catch return error.UnsupportedVariant;
    const offset = std.math.add(usize, header.data_offset, plane_offset) catch return error.UnsupportedVariant;
    if (offset > dat.len or dat.len - offset < plane_len) return error.TruncatedData;

    if (region.isFull(metadata)) {
        const out = try allocator.alloc(u8, plane_len);
        @memcpy(out, dat[offset..][0..plane_len]);
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
        @memcpy(out[dst_offset..][0..dst_row_bytes], dat[src_offset..][0..dst_row_bytes]);
    }
    return .{ .metadata = metadata, .data = out };
}

fn metadataFromHeader(header: Header) bio.Metadata {
    return .{
        .format = "inveon",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .size_z = header.size_z,
        .size_t = header.size_t,
        .pixel_type = header.pixel_type,
        .little_endian = header.little_endian,
        .plane_count = @as(u32, header.size_z) * @as(u32, header.size_t),
        .dimension_order = "XYZCT",
        .image_description = header.description,
    };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (!matches(data)) return error.InvalidFormat;
    var data_file: ?[]const u8 = null;
    var width: u32 = 0;
    var height: u32 = 0;
    var size_z: u32 = 1;
    var size_t: u32 = 1;
    var pixel_type: ?bio.PixelType = null;
    var little_endian = true;
    var data_offset: usize = 0;
    var description: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const space = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const key = line[0..space];
        const value = std.mem.trim(u8, line[space + 1 ..], " \t");
        if (std.mem.eql(u8, key, "file_name")) {
            data_file = basename(value);
        } else if (std.mem.eql(u8, key, "study")) {
            description = value;
        } else if (std.mem.eql(u8, key, "time_frames")) {
            size_t = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "data_type")) {
            const info = try pixelInfo(try parsePositiveU32(value));
            pixel_type = info.pixel_type;
            little_endian = info.little_endian;
        } else if (std.mem.eql(u8, key, "x_dimension")) {
            width = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "y_dimension")) {
            height = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "z_dimension")) {
            size_z = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "data_file_pointer")) {
            data_offset = try parseDataPointer(value);
        }
    }

    if (width == 0 or height == 0 or size_z == 0 or size_t == 0) return error.InvalidFormat;
    if (size_z > std.math.maxInt(u16) or size_t > std.math.maxInt(u16)) return error.UnsupportedVariant;
    return .{
        .data_file = data_file,
        .width = width,
        .height = height,
        .size_z = @intCast(size_z),
        .size_t = @intCast(size_t),
        .pixel_type = pixel_type orelse return error.InvalidFormat,
        .little_endian = little_endian,
        .data_offset = data_offset,
        .description = description,
    };
}

const PixelInfo = struct {
    pixel_type: bio.PixelType,
    little_endian: bool,
};

fn pixelInfo(data_type: u32) bio.ReaderError!PixelInfo {
    return switch (data_type) {
        1 => .{ .pixel_type = .int8, .little_endian = true },
        2 => .{ .pixel_type = .int16, .little_endian = true },
        3 => .{ .pixel_type = .int32, .little_endian = true },
        4 => .{ .pixel_type = .float32, .little_endian = true },
        5 => .{ .pixel_type = .float32, .little_endian = false },
        6 => .{ .pixel_type = .int16, .little_endian = false },
        7 => .{ .pixel_type = .int32, .little_endian = false },
        else => error.UnsupportedVariant,
    };
}

fn parseDataPointer(value: []const u8) bio.ReaderError!usize {
    var tokens = std.mem.tokenizeAny(u8, value, " \t");
    var parsed: [2]u32 = .{ 0, 0 };
    var count: usize = 0;
    while (tokens.next()) |token| {
        if (count == parsed.len) return error.UnsupportedVariant;
        parsed[count] = std.fmt.parseInt(u32, token, 10) catch return error.InvalidFormat;
        count += 1;
    }
    if (count == 0) return error.InvalidFormat;
    const offset: u64 = if (count == 1) parsed[0] else (@as(u64, parsed[0]) << 32) | parsed[1];
    if (offset > std.math.maxInt(usize)) return error.UnsupportedVariant;
    return @intCast(offset);
}

fn readHdrFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "hdr")) return readFile(allocator, io, path);
    const replaced = try replaceExtension(allocator, path, ".hdr");
    defer allocator.free(replaced);
    return readFile(allocator, io, replaced) catch |replace_err| {
        const appended = try appendExtension(allocator, path, ".hdr");
        defer allocator.free(appended);
        return readFile(allocator, io, appended) catch replace_err;
    };
}

fn readDatFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, header: Header) ![]u8 {
    if (!hasExtension(path, "hdr")) return readFile(allocator, io, path);
    if (header.data_file) |file_name| {
        const sibling = try siblingPath(allocator, path, file_name);
        defer allocator.free(sibling);
        return readFile(allocator, io, sibling);
    }
    const raw = try replaceExtension(allocator, path, ".img");
    defer allocator.free(raw);
    return readFile(allocator, io, raw);
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes));
}

fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    const out = try allocator.alloc(u8, dot + extension.len);
    @memcpy(out[0..dot], path[0..dot]);
    @memcpy(out[dot..], extension);
    return out;
}

fn appendExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, path.len + extension.len);
    @memcpy(out[0..path.len], path);
    @memcpy(out[path.len..], extension);
    return out;
}

fn siblingPath(allocator: std.mem.Allocator, path: []const u8, file_name: []const u8) ![]u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return allocator.dupe(u8, file_name);
    const prefix = path[0 .. slash + 1];
    const out = try allocator.alloc(u8, prefix.len + file_name.len);
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..], file_name);
    return out;
}

fn basename(value: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, value, "/\\") orelse return value;
    return value[slash + 1 ..];
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn parsePositiveU32(value: []const u8) bio.ReaderError!u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidFormat;
    if (parsed == 0) return error.InvalidFormat;
    return parsed;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

test "reads inveon header metadata" {
    const header =
        "# Header file for data file\n" ++
        "file_name scan.dat\n" ++
        "study mouse\n" ++
        "data_type 2\n" ++
        "x_dimension 2\n" ++
        "y_dimension 3\n" ++
        "z_dimension 4\n" ++
        "time_frames 2\n" ++
        "data_file_pointer 16\n";

    try std.testing.expect(matches(header));
    const metadata = try readMetadata(header);
    try std.testing.expectEqualStrings("inveon", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 3), metadata.height);
    try std.testing.expectEqual(@as(u16, 4), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 8), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.int16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("mouse", metadata.image_description.?);
}

test "reads inveon companion pixels with crop" {
    const hdr_path = "inveon-test.hdr";
    const dat_path = "scan.dat";
    const header =
        "# Header file for data file\n" ++
        "file_name scan.dat\n" ++
        "data_type 2\n" ++
        "x_dimension 2\n" ++
        "y_dimension 2\n" ++
        "z_dimension 2\n" ++
        "data_file_pointer 4\n";
    const pixels = [_]u8{
        0xff, 0xff, 0xff, 0xff,
        1,    0,    2,    0,
        3,    0,    4,    0,
        5,    0,    6,    0,
        7,    0,    8,    0,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = hdr_path, .data = header });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hdr_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dat_path, .data = &pixels });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, dat_path) catch {};

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, hdr_path, 1, .{
        .x = 1,
        .y = 0,
        .width = 1,
        .height = 2,
    });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 6, 0, 8, 0 }, plane.data);
}

test "rejects unsupported inveon datatype" {
    const header =
        "# Header file for data file\n" ++
        "data_type 99\n" ++
        "x_dimension 1\n" ++
        "y_dimension 1\n";

    try std.testing.expectError(error.UnsupportedVariant, readMetadata(header));
}
