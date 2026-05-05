const std = @import("std");
const bio = @import("../root.zig");

const max_library_bytes = 64 * 1024 * 1024;
const max_stack_bytes = 512 * 1024 * 1024;

pub fn matches(data: []const u8) bool {
    return data.len >= 2 and ((data[0] == 'J' and data[1] == 'L') or (data[0] == 'L' and data[1] == 'J'));
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "mvd2") or hasExtension(path, "aisf");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!matches(data)) return error.InvalidFormat;
    return error.UnsupportedVariant;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const stack_path = try selectedStackPath(allocator, io, path);
    defer allocator.free(stack_path);
    const data = try readFile(allocator, io, stack_path);
    defer allocator.free(data);
    var metadata = try bio.volocityclipping.readMetadata(data);
    metadata.format = "volocity";
    return metadata;
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const stack_path = try selectedStackPath(allocator, io, path);
    defer allocator.free(stack_path);
    const data = try readFile(allocator, io, stack_path);
    defer allocator.free(data);
    var plane = try bio.volocityclipping.readPlaneIndex(allocator, data, plane_index);
    defer allocator.free(plane.data);
    plane.metadata.format = "volocity";
    return .{
        .metadata = plane.metadata,
        .data = try bio.cropPlane(allocator, plane, region),
    };
}

fn selectedStackPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (hasExtension(path, "aisf")) return allocator.dupe(u8, path);
    if (!hasExtension(path, "mvd2")) return error.InvalidFormat;

    const data = try readMetakitHeader(allocator, io, path);
    defer allocator.free(data);
    if (!matches(data)) return error.InvalidFormat;

    const parent = try parentPath(allocator, path);
    defer allocator.free(parent);
    const data_dir = try joinPath(allocator, parent, "Data");
    defer allocator.free(data_dir);
    return findFirstAisfRecursive(allocator, io, data_dir, 0);
}

fn findFirstAisfRecursive(allocator: std.mem.Allocator, io: std.Io, root: []const u8, depth: usize) ![]u8 {
    if (depth > 4) return error.FileNotFound;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    var dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (dirs.items) |dir_name| allocator.free(dir_name);
        dirs.deinit(allocator);
    }

    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and hasExtension(entry.name, "aisf")) return joinPath(allocator, root, entry.name);
        if (entry.kind == .directory) try dirs.append(allocator, try allocator.dupe(u8, entry.name));
    }
    for (dirs.items) |dir_name| {
        const child = try joinPath(allocator, root, dir_name);
        defer allocator.free(child);
        if (findFirstAisfRecursive(allocator, io, child, depth + 1)) |found| return found else |_| {}
    }
    return error.FileNotFound;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_stack_bytes));
}

fn readMetakitHeader(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_library_bytes));
}

fn parentPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const sep = lastSeparator(path) orelse return allocator.dupe(u8, ".");
    if (sep == 0) return allocator.dupe(u8, path[0..1]);
    return allocator.dupe(u8, path[0..sep]);
}

fn joinPath(allocator: std.mem.Allocator, left: []const u8, right: []const u8) ![]u8 {
    if (left.len == 0 or std.mem.eql(u8, left, ".")) return allocator.dupe(u8, right);
    const sep: []const u8 = if (std.mem.endsWith(u8, left, "/") or std.mem.endsWith(u8, left, "\\")) "" else std.fs.path.sep_str;
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ left, sep, right });
}

fn hasExtension(path: []const u8, ext: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], ext);
}

fn lastSeparator(path: []const u8) ?usize {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    if (slash == null) return backslash;
    if (backslash == null) return slash;
    return @max(slash.?, backslash.?);
}

fn writeU32(list: *std.ArrayList(u8), value: u32, little_endian: bool) !void {
    if (little_endian) {
        try list.append(std.testing.allocator, @intCast(value & 0xff));
        try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
        try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
        try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
    } else {
        try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
        try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
        try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
        try list.append(std.testing.allocator, @intCast(value & 0xff));
    }
}

fn appendRegularStack(list: *std.ArrayList(u8), width: u32, height: u32, planes: u32) !void {
    try list.append(std.testing.allocator, 'I');
    try list.appendNTimes(std.testing.allocator, 0, 4);
    try list.appendSlice(std.testing.allocator, "FFCA");
    try writeU32(list, 0x208, true);
    try writeU32(list, width, true);
    try writeU32(list, height, true);
    try writeU32(list, planes, true);
    try list.appendNTimes(std.testing.allocator, 0, 65);
}

test "reads volocity library metadata and pixels from data aisf" {
    const root = "volocity-test";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/Data");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const mvd2_path = root ++ "/sample.mvd2";
    const stack_path = root ++ "/Data/1.aisf";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = mvd2_path, .data = "JL" });

    var stack: std.ArrayList(u8) = .empty;
    defer stack.deinit(std.testing.allocator);
    try appendRegularStack(&stack, 2, 1, 2);
    try stack.appendSlice(std.testing.allocator, &.{ 3, 4, 5, 6 });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = stack_path, .data = stack.items });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, mvd2_path);
    try std.testing.expectEqualStrings("volocity", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, mvd2_path, 1, .{ .x = 0, .y = 0, .width = 2, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("volocity", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6 }, plane.data);
}
