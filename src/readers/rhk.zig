const std = @import("std");
const bio = @import("../root.zig");

const header_len = 512;

const Header = struct {
    width: u32,
    height: u32,
    pixel_offset: usize,
    pixel_type: bio.PixelType,
    invert_x: bool,
    invert_y: bool,
    description: ?[]const u8,
};

pub fn matches(data: []const u8) bool {
    const header = parseHeader(data) catch return false;
    const plane_len = planeByteCount(.{
        .format = "rhk",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
    }) catch return false;
    return data.len >= header.pixel_offset and data.len - header.pixel_offset >= plane_len;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const header = try parseHeader(data);
    return .{
        .format = "rhk",
        .width = header.width,
        .height = header.height,
        .size_c = 1,
        .samples_per_pixel = 1,
        .pixel_type = header.pixel_type,
        .little_endian = true,
        .image_description = header.description,
    };
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    const header = try parseHeader(data);
    const plane_len = try planeByteCount(metadata);
    if (data.len < header.pixel_offset or data.len - header.pixel_offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);

    const pixels = data[header.pixel_offset..][0..plane_len];
    if (!header.invert_x and !header.invert_y) {
        @memcpy(out, pixels);
    } else {
        const bpp = metadata.pixel_type.bytesPerSample();
        const row_stride = std.math.mul(usize, header.width, bpp) catch return error.UnsupportedVariant;
        for (0..header.height) |dest_row| {
            const src_row = if (header.invert_y) header.height - dest_row - 1 else dest_row;
            for (0..header.width) |dest_col| {
                const src_col = if (header.invert_x) header.width - dest_col - 1 else dest_col;
                const src = src_row * row_stride + src_col * bpp;
                const dest = dest_row * row_stride + dest_col * bpp;
                @memcpy(out[dest..][0..bpp], pixels[src..][0..bpp]);
            }
        }
    }

    return .{ .metadata = metadata, .data = out };
}

fn parseHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < 2) return error.TruncatedData;
    if (readU16(data[0..2]) == 0xaa) return parseXpmHeader(data);
    return parseTextHeader(data);
}

fn parseXpmHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < 92) return error.TruncatedData;
    const data_type = readU32(data[48..52]);
    const width = readU32(data[64..68]);
    const height = readU32(data[68..72]);
    const pixel_offset = readU32(data[88..92]);
    return makeHeader(data, width, height, pixel_offset, data_type, false, false);
}

fn parseTextHeader(data: []const u8) bio.ReaderError!Header {
    if (data.len < header_len) return error.TruncatedData;
    var type_tokens = std.mem.tokenizeAny(u8, trimmed(data[32..64]), " \t");
    _ = parseNextInt(&type_tokens) catch return error.InvalidFormat;
    const data_type = parseNextInt(&type_tokens) catch return error.InvalidFormat;
    _ = parseNextInt(&type_tokens) catch return error.InvalidFormat;
    const width = parseNextInt(&type_tokens) catch return error.InvalidFormat;
    const height = parseNextInt(&type_tokens) catch return error.InvalidFormat;

    const x_scale = parseAxisScale(data[64..96]) catch return error.InvalidFormat;
    const y_scale = parseAxisScale(data[96..128]) catch return error.InvalidFormat;
    return makeHeader(data, width, height, header_len, data_type, x_scale < 0, y_scale > 0);
}

fn makeHeader(
    data: []const u8,
    width: u32,
    height: u32,
    pixel_offset: u32,
    data_type: u32,
    invert_x: bool,
    invert_y: bool,
) bio.ReaderError!Header {
    if (width == 0 or height == 0 or pixel_offset == 0) return error.InvalidFormat;
    return .{
        .width = width,
        .height = height,
        .pixel_offset = pixel_offset,
        .pixel_type = switch (data_type) {
            0 => .float32,
            1 => .int16,
            2 => .int32,
            3 => .uint8,
            else => return error.UnsupportedVariant,
        },
        .invert_x = invert_x,
        .invert_y = invert_y,
        .description = if (data.len >= 384) optionalTrim(data[352..384]) else null,
    };
}

fn parseAxisScale(bytes: []const u8) !f64 {
    var tokens = std.mem.tokenizeAny(u8, trimmed(bytes), " \t");
    _ = tokens.next() orelse return error.InvalidFormat;
    return std.fmt.parseFloat(f64, tokens.next() orelse return error.InvalidFormat);
}

fn parseNextInt(tokens: *std.mem.TokenIterator(u8, .any)) !u32 {
    return std.fmt.parseUnsigned(u32, tokens.next() orelse return error.InvalidFormat, 10);
}

fn optionalTrim(bytes: []const u8) ?[]const u8 {
    const value = trimmed(bytes);
    return if (value.len == 0) null else value;
}

fn trimmed(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n\x00");
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.pixel_type.bytesPerSample()) catch return error.UnsupportedVariant;
}

fn writeBytes(bytes: []u8, offset: usize, value: []const u8) void {
    @memcpy(bytes[offset..][0..value.len], value);
}

fn appendTextHeader(list: *std.ArrayList(u8), width: u32, height: u32, data_type: u32, x_scale: []const u8, y_scale: []const u8) !void {
    try list.appendNTimes(std.testing.allocator, 0, header_len);
    var header: [32]u8 = @splat(' ');
    const type_line = try std.fmt.bufPrint(&header, "0 {d} 0 {d} {d} 0 0", .{ data_type, width, height });
    writeBytes(list.items, 32, type_line);
    var x_axis: [32]u8 = @splat(' ');
    var y_axis: [32]u8 = @splat(' ');
    writeBytes(list.items, 64, try std.fmt.bufPrint(&x_axis, "X {s}", .{x_scale}));
    writeBytes(list.items, 96, try std.fmt.bufPrint(&y_axis, "Y {s}", .{y_scale}));
    writeBytes(list.items, 352, "RHK text test");
}

fn appendXpmHeader(list: *std.ArrayList(u8), width: u32, height: u32, data_type: u32, pixel_offset: u32) !void {
    try list.appendNTimes(std.testing.allocator, 0, pixel_offset);
    writeU16(list.items, 0, 0xaa);
    writeU32(list.items, 48, data_type);
    writeU32(list.items, 64, width);
    writeU32(list.items, 68, height);
    writeU32(list.items, 88, pixel_offset);
    writeBytes(list.items, 352, "RHK xpm test");
}

test "reads rhk xpm uint8 plane" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendXpmHeader(&data, 2, 2, 3, header_len);
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("RHK xpm test", metadata.image_description.?);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, plane.data);
}

test "reads rhk text header and flips axes" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendTextHeader(&data, 2, 2, 3, "-1.0", "1.0");
    try data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1 }, plane.data);
}

test "rejects unsupported rhk pixel type" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendTextHeader(&data, 1, 1, 9, "1.0", "-1.0");
    try data.append(std.testing.allocator, 0);

    try std.testing.expectError(error.UnsupportedVariant, readMetadata(data.items));
}

