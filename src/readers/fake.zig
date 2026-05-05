const std = @import("std");
const bio = @import("../root.zig");

const default_size_x = 512;
const default_size_y = 512;
const default_size_z = 1;
const default_size_c = 1;
const default_size_t = 1;
const box_size = 10;

const Options = struct {
    name: ?[]const u8 = null,
    width: u32 = default_size_x,
    height: u32 = default_size_y,
    size_z: u16 = default_size_z,
    size_c: u16 = default_size_c,
    size_t: u16 = default_size_t,
    pixel_type: bio.PixelType = .uint8,
    little_endian: bool = true,
    dimension_order: []const u8 = "XYZCT",
    scale_factor: f64 = 1.0,
};

const Coordinates = struct {
    z: u32 = 0,
    c: u32 = 0,
    t: u32 = 0,
};

pub fn matches(data: []const u8) bool {
    _ = data;
    return false;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "fake") or endsWithIgnoreCase(path, ".fake.ini");
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
    _ = allocator;
    _ = io;
    return metadataFromOptions(try parsePath(path));
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    _ = io;
    const options = try parsePath(path);
    const metadata = metadataFromOptions(options);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    try region.validate(metadata);

    const bytes_per_pixel = metadata.bytesPerPixel();
    const row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, row_bytes, region.height) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    const coords = try planeCoordinates(metadata, plane_index);
    var row: u32 = 0;
    while (row < region.height) : (row += 1) {
        const y = region.y + row;
        var col: u32 = 0;
        while (col < region.width) : (col += 1) {
            const x = region.x + col;
            const offset = (@as(usize, row) * row_bytes) + (@as(usize, col) * bytes_per_pixel);
            const value = fakePixelValue(options, plane_index, coords, x, y);
            writePixel(out[offset..][0..bytes_per_pixel], options.pixel_type, options.little_endian, value);
        }
    }

    return .{ .metadata = metadata, .data = out };
}

fn metadataFromOptions(options: Options) bio.Metadata {
    return .{
        .format = "fake",
        .width = options.width,
        .height = options.height,
        .size_c = options.size_c,
        .size_z = options.size_z,
        .size_t = options.size_t,
        .samples_per_pixel = 1,
        .pixel_type = options.pixel_type,
        .little_endian = options.little_endian,
        .plane_count = @as(u32, options.size_z) * @as(u32, options.size_c) * @as(u32, options.size_t),
        .dimension_order = options.dimension_order,
        .image_description = null,
    };
}

fn parsePath(path: []const u8) bio.ReaderError!Options {
    if (!isPath(path)) return error.InvalidFormat;
    var name = basename(path);
    if (endsWithIgnoreCase(name, ".ini")) {
        name = name[0 .. name.len - 4];
    }
    if (hasExtension(name, "fake")) {
        name = name[0 .. name.len - 5];
    }

    var options: Options = .{};
    var tokens = std.mem.splitScalar(u8, name, '&');
    var first = true;
    while (tokens.next()) |token| {
        if (first) {
            first = false;
            options.name = if (token.len == 0) null else token;
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        const key = token[0..equals];
        const value = token[equals + 1 ..];
        if (std.mem.eql(u8, key, "sizeX")) {
            options.width = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "sizeY")) {
            options.height = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, key, "sizeZ")) {
            options.size_z = try parsePositiveU16(value);
        } else if (std.mem.eql(u8, key, "sizeC")) {
            options.size_c = try parsePositiveU16(value);
        } else if (std.mem.eql(u8, key, "sizeT")) {
            options.size_t = try parsePositiveU16(value);
        } else if (std.mem.eql(u8, key, "pixelType")) {
            options.pixel_type = try parsePixelType(value);
        } else if (std.mem.eql(u8, key, "little")) {
            options.little_endian = try parseBool(value);
        } else if (std.mem.eql(u8, key, "dimOrder")) {
            options.dimension_order = try parseDimensionOrder(value);
        } else if (std.mem.eql(u8, key, "scaleFactor")) {
            options.scale_factor = std.fmt.parseFloat(f64, value) catch return error.InvalidFormat;
        } else if (std.mem.eql(u8, key, "rgb")) {
            if ((std.fmt.parseInt(u16, value, 10) catch return error.InvalidFormat) != 1) return error.UnsupportedVariant;
        } else if (std.mem.eql(u8, key, "indexed") or std.mem.eql(u8, key, "falseColor")) {
            if (try parseBool(value)) return error.UnsupportedVariant;
        }
    }
    if (options.width == 0 or options.height == 0 or options.size_z == 0 or options.size_c == 0 or options.size_t == 0) {
        return error.InvalidFormat;
    }
    _ = std.math.mul(u32, @as(u32, options.size_z), @as(u32, options.size_c)) catch return error.UnsupportedVariant;
    _ = std.math.mul(u32, @as(u32, options.size_z) * @as(u32, options.size_c), @as(u32, options.size_t)) catch return error.UnsupportedVariant;
    return options;
}

fn planeCoordinates(metadata: bio.Metadata, plane_index: u32) bio.ReaderError!Coordinates {
    var coords: Coordinates = .{};
    var remaining = plane_index;
    const order = metadata.dimension_order orelse "XYZCT";
    if (order.len != 5 or order[0] != 'X' or order[1] != 'Y') return error.InvalidFormat;
    for (order[2..]) |axis| {
        const size = axisSize(metadata, axis);
        if (size == 0) return error.InvalidFormat;
        const value = remaining % size;
        remaining /= size;
        switch (axis) {
            'Z' => coords.z = value,
            'C' => coords.c = value,
            'T' => coords.t = value,
            else => return error.InvalidFormat,
        }
    }
    if (remaining != 0) return error.InvalidPlaneIndex;
    return coords;
}

fn axisSize(metadata: bio.Metadata, axis: u8) u32 {
    return switch (axis) {
        'Z' => metadata.size_z,
        'C' => metadata.size_c,
        'T' => metadata.size_t,
        else => 0,
    };
}

fn fakePixelValue(options: Options, plane_index: u32, coords: Coordinates, x: u32, y: u32) PixelValue {
    if (y < box_size) {
        return switch (x / box_size) {
            0 => .{ .integer = 0 },
            1 => .{ .integer = plane_index },
            2 => .{ .integer = coords.z },
            3 => .{ .integer = coords.c },
            4 => .{ .integer = coords.t },
            else => normalPixelValue(options, x),
        };
    }
    return normalPixelValue(options, x);
}

const PixelValue = union(enum) {
    integer: i64,
    float: f64,
};

fn normalPixelValue(options: Options, x: u32) PixelValue {
    const base: f64 = switch (options.pixel_type) {
        .int8 => @as(f64, -128) + @as(f64, @floatFromInt(x)),
        .int16 => @as(f64, -32768) + @as(f64, @floatFromInt(x)),
        .int32 => @as(f64, -2147483648) + @as(f64, @floatFromInt(x)),
        .float32, .float64 => @floatFromInt(x),
        else => @floatFromInt(x),
    };
    const scaled = options.scale_factor * base;
    return switch (options.pixel_type) {
        .float32, .float64 => .{ .float = scaled },
        else => .{ .integer = @intFromFloat(scaled) },
    };
}

fn writePixel(out: []u8, pixel_type: bio.PixelType, little_endian: bool, value: PixelValue) void {
    const endian: std.builtin.Endian = if (little_endian) .little else .big;
    const integer = switch (value) {
        .integer => |v| v,
        .float => |v| @as(i64, @intFromFloat(v)),
    };
    switch (pixel_type) {
        .uint8, .int8 => out[0] = @truncate(@as(u64, @bitCast(integer))),
        .uint16, .int16 => std.mem.writeInt(u16, out[0..2], @truncate(@as(u64, @bitCast(integer))), endian),
        .uint32, .int32 => std.mem.writeInt(u32, out[0..4], @truncate(@as(u64, @bitCast(integer))), endian),
        .float32 => {
            const float_value: f32 = switch (value) {
                .integer => |v| @floatFromInt(v),
                .float => |v| @floatCast(v),
            };
            std.mem.writeInt(u32, out[0..4], @bitCast(float_value), endian);
        },
        .float64 => {
            const float_value: f64 = switch (value) {
                .integer => |v| @floatFromInt(v),
                .float => |v| v,
            };
            std.mem.writeInt(u64, out[0..8], @bitCast(float_value), endian);
        },
        else => unreachable,
    }
}

fn parsePixelType(value: []const u8) bio.ReaderError!bio.PixelType {
    if (std.ascii.eqlIgnoreCase(value, "uint8")) return .uint8;
    if (std.ascii.eqlIgnoreCase(value, "int8")) return .int8;
    if (std.ascii.eqlIgnoreCase(value, "uint16")) return .uint16;
    if (std.ascii.eqlIgnoreCase(value, "int16")) return .int16;
    if (std.ascii.eqlIgnoreCase(value, "uint32")) return .uint32;
    if (std.ascii.eqlIgnoreCase(value, "int32")) return .int32;
    if (std.ascii.eqlIgnoreCase(value, "float") or std.ascii.eqlIgnoreCase(value, "float32")) return .float32;
    if (std.ascii.eqlIgnoreCase(value, "double") or std.ascii.eqlIgnoreCase(value, "float64")) return .float64;
    return error.UnsupportedVariant;
}

fn parseDimensionOrder(value: []const u8) bio.ReaderError![]const u8 {
    if (value.len != 5) return error.InvalidFormat;
    if (value[0] != 'X' and value[0] != 'x') return error.InvalidFormat;
    if (value[1] != 'Y' and value[1] != 'y') return error.InvalidFormat;
    var seen_z = false;
    var seen_c = false;
    var seen_t = false;
    for (value[2..]) |raw_axis| {
        const axis = std.ascii.toUpper(raw_axis);
        switch (axis) {
            'Z' => {
                if (seen_z) return error.InvalidFormat;
                seen_z = true;
            },
            'C' => {
                if (seen_c) return error.InvalidFormat;
                seen_c = true;
            },
            'T' => {
                if (seen_t) return error.InvalidFormat;
                seen_t = true;
            },
            else => return error.InvalidFormat,
        }
    }
    if (!seen_z or !seen_c or !seen_t) return error.InvalidFormat;
    if (std.ascii.eqlIgnoreCase(value, "XYZCT")) return "XYZCT";
    if (std.ascii.eqlIgnoreCase(value, "XYCZT")) return "XYCZT";
    if (std.ascii.eqlIgnoreCase(value, "XYTCZ")) return "XYTCZ";
    if (std.ascii.eqlIgnoreCase(value, "XYTZC")) return "XYTZC";
    if (std.ascii.eqlIgnoreCase(value, "XYZTC")) return "XYZTC";
    if (std.ascii.eqlIgnoreCase(value, "XYCTZ")) return "XYCTZ";
    return error.UnsupportedVariant;
}

fn parseBool(value: []const u8) bio.ReaderError!bool {
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    return error.InvalidFormat;
}

fn parsePositiveU32(value: []const u8) bio.ReaderError!u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidFormat;
    if (parsed == 0) return error.InvalidFormat;
    return parsed;
}

fn parsePositiveU16(value: []const u8) bio.ReaderError!u16 {
    const parsed = std.fmt.parseInt(u16, value, 10) catch return error.InvalidFormat;
    if (parsed == 0) return error.InvalidFormat;
    return parsed;
}

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[slash + 1 ..];
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    return value.len >= suffix.len and std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

test "reads fake filename metadata" {
    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, "sample&sizeX=3&sizeY=2&sizeZ=2&sizeC=3&sizeT=4&pixelType=uint16.fake");
    try std.testing.expectEqualStrings("fake", metadata.format);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 4), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 24), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
}

test "generates fake special pixels and crop" {
    const plane = try readPlanePathRegionIndex(
        std.testing.allocator,
        std.testing.io,
        "fake&sizeX=60&sizeY=12&sizeZ=2&sizeC=3&sizeT=4.fake",
        17,
        .{ .x = 10, .y = 0, .width = 41, .height = 1 },
    );
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("fake", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 17, 1, 2, 2, 50 }, &.{ plane.data[0], plane.data[10], plane.data[20], plane.data[30], plane.data[40] });
}

test "generates fake signed and floating pixels" {
    const signed = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, "signed&sizeX=2&sizeY=11&pixelType=int8.fake", 0, .{ .x = 0, .y = 10, .width = 2, .height = 1 });
    defer std.testing.allocator.free(signed.data);
    try std.testing.expectEqualSlices(u8, &.{ 128, 129 }, signed.data);

    const floating = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, "float&sizeX=2&sizeY=11&pixelType=float&scaleFactor=2.fake", 0, .{ .x = 1, .y = 10, .width = 1, .height = 1 });
    defer std.testing.allocator.free(floating.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 64 }, floating.data);
}
