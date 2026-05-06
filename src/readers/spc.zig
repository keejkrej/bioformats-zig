const std = @import("std");
const bio = @import("../root.zig");

const max_companion_bytes = 512 * 1024 * 1024;
const adc_res_shift = 6;
const n_timebins = (0xfff >> adc_res_shift) + 1;

const Dataset = struct {
    set_path: []u8,
    spc_path: []u8,
    set_data: []u8,
    spc_data: []u8,

    fn deinit(self: Dataset, allocator: std.mem.Allocator) void {
        allocator.free(self.set_path);
        allocator.free(self.spc_path);
        allocator.free(self.set_data);
        allocator.free(self.spc_data);
    }
};

const ScanInfo = struct {
    n_pixels: u32,
    n_lines: u32,
    n_frames: u32,
    n_channels: u16,
    line_mode: bool,
    frame_clocks: []usize,
    end_frames: []usize,

    fn deinit(self: ScanInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.frame_clocks);
        allocator.free(self.end_frames);
    }
};

const State = struct {
    current_pixel: u32 = 0,
    current_line: i32 = -1,
    current_frame: i32 = -1,
    end_of_frame: bool = false,
    n_pixels: u32 = 0,
    n_lines: u32 = 0,
};

pub fn matches(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "module SPC-") != null and
        std.mem.indexOf(u8, data, "SP_TAC_R") != null and
        std.mem.indexOf(u8, data, "SP_TAC_G") != null;
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "spc") or hasExtension(path, "set");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    _ = data;
    return error.UnsupportedVariant;
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    _ = allocator;
    _ = data;
    _ = plane_index;
    return error.UnsupportedVariant;
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    var dataset = try openDataset(allocator, io, path);
    defer dataset.deinit(allocator);
    var scan = try scanSpc(allocator, dataset.spc_data);
    defer scan.deinit(allocator);
    _ = try parseSetup(dataset.set_data);
    return metadataFromScan(scan);
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    var dataset = try openDataset(allocator, io, path);
    defer dataset.deinit(allocator);
    var scan = try scanSpc(allocator, dataset.spc_data);
    defer scan.deinit(allocator);
    _ = try parseSetup(dataset.set_data);
    const metadata = metadataFromScan(scan);
    try region.validate(metadata);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;

    const size_t = @as(u32, n_timebins) * scan.n_frames;
    const channel = plane_index / size_t;
    var remaining = plane_index - channel * size_t;
    const frame = remaining / n_timebins;
    remaining -= frame * n_timebins;
    const timebin = remaining;

    const expanded = try expandFrame(allocator, dataset.spc_data, scan, @intCast(frame), @intCast(channel));
    defer allocator.free(expanded);

    const out = try cropTimebin(allocator, metadata, scan, expanded, @intCast(timebin), region);
    return .{ .metadata = metadata, .data = out };
}

fn metadataFromScan(scan: ScanInfo) bio.Metadata {
    return .{
        .format = "spc",
        .width = scan.n_pixels,
        .height = if (scan.line_mode) 1 else scan.n_lines,
        .size_c = scan.n_channels,
        .samples_per_pixel = 1,
        .size_z = 1,
        .size_t = @intCast(@min(@as(u32, n_timebins) * scan.n_frames, std.math.maxInt(u16))),
        .pixel_type = .uint16,
        .little_endian = true,
        .plane_count = @as(u32, scan.n_channels) * @as(u32, n_timebins) * scan.n_frames,
        .dimension_order = "XYZTC",
    };
}

fn openDataset(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Dataset {
    const set_path = try replaceExtension(allocator, path, ".set");
    errdefer allocator.free(set_path);
    const spc_path = try replaceExtension(allocator, path, ".spc");
    errdefer allocator.free(spc_path);
    const set_data = try readFile(allocator, io, set_path);
    errdefer allocator.free(set_data);
    const spc_data = try readFile(allocator, io, spc_path);
    errdefer allocator.free(spc_data);
    if (!matches(set_data)) return error.InvalidFormat;
    return .{ .set_path = set_path, .spc_path = spc_path, .set_data = set_data, .spc_data = spc_data };
}

fn parseSetup(data: []const u8) bio.ReaderError!f64 {
    if (data.len < 14) return error.TruncatedData;
    const setup_pos = std.mem.readInt(u32, data[8..12], .little);
    const setup_count = std.mem.readInt(u16, data[12..14], .little);
    if (setup_pos > data.len or data.len - setup_pos < setup_count) return error.TruncatedData;
    const setup = data[setup_pos..][0..setup_count];
    const tac_range = try parseSetupValue("SP_TAC_R", setup);
    const tac_gain = try parseSetupValue("SP_TAC_G", setup);
    if (tac_range == 0 or tac_gain == 0) return error.InvalidFormat;
    return 4095.0 * tac_range / (tac_gain * 4096.0) * 1.0e12;
}

fn parseSetupValue(tag: []const u8, setup: []const u8) bio.ReaderError!f64 {
    const tag_offset = std.mem.indexOf(u8, setup, tag) orelse return error.InvalidFormat;
    const tail = setup[tag_offset..@min(setup.len, tag_offset + 64)];
    const comma = std.mem.indexOfScalar(u8, tail, ',') orelse return error.InvalidFormat;
    if (comma + 3 >= tail.len) return error.InvalidFormat;
    const tag_type = tail[comma + 1];
    const value_start = comma + 3;
    const value_end = std.mem.indexOfScalarPos(u8, tail, value_start, ']') orelse return error.InvalidFormat;
    const value = std.mem.trim(u8, tail[value_start..value_end], " \t\r\n");
    return switch (tag_type) {
        'I' => @floatFromInt(std.fmt.parseInt(i64, value, 10) catch return error.InvalidFormat),
        'F' => std.fmt.parseFloat(f64, value) catch return error.InvalidFormat,
        else => error.InvalidFormat,
    };
}

fn scanSpc(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!ScanInfo {
    if (data.len < 4) return error.TruncatedData;
    const routing = data[3];
    const channels: u16 = @max(@as(u16, (routing & 0x78) >> 3), 1);
    var frame_clocks: std.ArrayList(usize) = .empty;
    errdefer frame_clocks.deinit(allocator);
    var end_frames: std.ArrayList(usize) = .empty;
    errdefer end_frames.deinit(allocator);
    var state: State = .{};

    var block: usize = 3;
    while (block < data.len) : (block += 4) {
        const adc_lm = data[block] & 0xf0;
        if (adc_lm == 0x90 or adc_lm == 0xd0) {
            try invalidAndMarkInit(allocator, data, block, &state, &frame_clocks, &end_frames);
        }
    }

    if (state.current_frame <= 1 or state.n_pixels == 0 or state.n_lines == 0) return error.InvalidFormat;
    const n_frames: u32 = @intCast(state.current_frame - 1);
    if (frame_clocks.items.len < n_frames or end_frames.items.len < n_frames + 1) return error.InvalidFormat;
    return .{
        .n_pixels = state.n_pixels,
        .n_lines = state.n_lines,
        .n_frames = n_frames,
        .n_channels = channels,
        .line_mode = state.n_lines >= 530,
        .frame_clocks = try frame_clocks.toOwnedSlice(allocator),
        .end_frames = try end_frames.toOwnedSlice(allocator),
    };
}

fn invalidAndMarkInit(
    allocator: std.mem.Allocator,
    data: []const u8,
    block: usize,
    state: *State,
    frame_clocks: *std.ArrayList(usize),
    end_frames: *std.ArrayList(usize),
) bio.ReaderError!void {
    if (block < 2) return error.InvalidFormat;
    const rout_m = data[block - 2] & 0xf0;
    switch (rout_m) {
        0x10 => state.current_pixel += 1,
        0x20 => {
            if (state.current_frame == 0 and state.current_line == 1) state.n_pixels = state.current_pixel;
            if (state.end_of_frame) {
                state.current_line = -1;
                state.end_of_frame = false;
                state.current_frame += 1;
                try end_frames.append(allocator, block - 3);
            }
            state.current_line += 1;
            state.current_pixel = 0;
        },
        0x40 => {
            if (state.current_frame == 0) state.n_lines = @intCast(state.current_line + 1);
            try frame_clocks.append(allocator, block - 3);
            state.end_of_frame = true;
        },
        else => {},
    }
}

fn expandFrame(allocator: std.mem.Allocator, data: []const u8, scan: ScanInfo, frame: usize, channel: usize) bio.ReaderError![]u8 {
    if (frame + 1 >= scan.end_frames.len or frame >= scan.frame_clocks.len) return error.InvalidPlaneIndex;
    const bin_size = std.math.mul(usize, std.math.mul(usize, scan.n_pixels, scan.n_lines) catch return error.UnsupportedVariant, 2) catch return error.UnsupportedVariant;
    const total_len = std.math.mul(usize, bin_size, n_timebins) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, total_len);
    @memset(out, 0);

    var state: State = .{};
    var block = scan.frame_clocks[frame] + 3;
    const end = scan.end_frames[frame + 1];
    while (block < data.len and block < end) : (block += 4) {
        const adc_lm = data[block] & 0xf0;
        switch (adc_lm) {
            0x00, 0x40 => try photon(data, block, scan, channel, bin_size, out, state),
            0x90, 0xd0 => invalidAndMark(data, block, &state),
            else => {},
        }
    }
    return out;
}

fn invalidAndMark(data: []const u8, block: usize, state: *State) void {
    if (block < 2) return;
    const rout_m = data[block - 2] & 0xf0;
    switch (rout_m) {
        0x10 => state.current_pixel += 1,
        0x20 => {
            if (state.end_of_frame) {
                state.current_line = -1;
                state.end_of_frame = false;
                state.current_frame += 1;
            }
            state.current_line += 1;
            state.current_pixel = 0;
        },
        0x40 => state.end_of_frame = true,
        else => {},
    }
}

fn photon(data: []const u8, block: usize, scan: ScanInfo, channel: usize, bin_size: usize, out: []u8, state: State) bio.ReaderError!void {
    if (block < 2) return;
    const current_channel: usize = (data[block - 2] & 0xf0) >> 4;
    if (current_channel != channel and scan.n_channels != 1) return;
    if (state.current_pixel >= scan.n_pixels or state.current_line < 0 or state.current_line >= scan.n_lines + 1) return;
    const adc_m = (@as(u32, data[block] & 0x0f) << 8) | data[block - 1];
    const current_bin: usize = (4095 - adc_m) >> adc_res_shift;
    if (current_bin >= n_timebins) return;
    const pixel_index = @as(usize, @intCast(state.current_line)) * scan.n_pixels + state.current_pixel;
    const offset = current_bin * bin_size + pixel_index * 2;
    if (offset + 2 > out.len) return error.InvalidFormat;
    const value = std.mem.readInt(u16, out[offset..][0..2], .little);
    std.mem.writeInt(u16, out[offset..][0..2], value +% 1, .little);
}

fn cropTimebin(allocator: std.mem.Allocator, metadata: bio.Metadata, scan: ScanInfo, expanded: []const u8, timebin: usize, region: bio.Region) bio.ReaderError![]u8 {
    const bytes_per_pixel = metadata.bytesPerPixel();
    const source_width = @as(usize, scan.n_pixels);
    const bin_size = std.math.mul(usize, std.math.mul(usize, scan.n_pixels, scan.n_lines) catch return error.UnsupportedVariant, bytes_per_pixel) catch return error.UnsupportedVariant;
    const bin_offset = std.math.mul(usize, timebin, bin_size) catch return error.UnsupportedVariant;
    const dst_row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, std.math.mul(usize, dst_row_bytes, region.height) catch return error.UnsupportedVariant);
    errdefer allocator.free(out);

    if (!scan.line_mode) {
        var row: usize = 0;
        while (row < region.height) : (row += 1) {
            const src_y = @as(usize, region.y) + row;
            const src_offset = bin_offset + (src_y * source_width + region.x) * bytes_per_pixel;
            @memcpy(out[row * dst_row_bytes ..][0..dst_row_bytes], expanded[src_offset..][0..dst_row_bytes]);
        }
    } else {
        @memset(out, 0);
        var line: usize = 0;
        while (line < scan.n_lines) : (line += 1) {
            var x: usize = 0;
            while (x < region.width) : (x += 1) {
                const src_offset = bin_offset + (line * source_width + region.x + x) * bytes_per_pixel;
                const dst_offset = x * bytes_per_pixel;
                const sum = std.mem.readInt(u16, out[dst_offset..][0..2], .little) +% std.mem.readInt(u16, expanded[src_offset..][0..2], .little);
                std.mem.writeInt(u16, out[dst_offset..][0..2], sum, .little);
            }
        }
    }
    return out;
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

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn appendU16Le(list: *std.ArrayList(u8), value: u16) !void {
    try list.append(std.testing.allocator, @intCast(value & 0xff));
    try list.append(std.testing.allocator, @intCast(value >> 8));
}

fn appendU32Le(list: *std.ArrayList(u8), value: u32) !void {
    try list.append(std.testing.allocator, @intCast(value & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
}

fn appendEvent(list: *std.ArrayList(u8), rout_high: u8, adc_high: u8, adc_low: u8) !void {
    try list.appendSlice(std.testing.allocator, &.{ 0, rout_high, adc_low, adc_high });
}

fn appendSet(list: *std.ArrayList(u8)) !void {
    const setup = "#SP [SP_TAC_R,F,1.0] #SP [SP_TAC_G,I,1]";
    try list.appendNTimes(std.testing.allocator, 0, 8);
    try appendU32Le(list, 128);
    try appendU16Le(list, setup.len);
    try list.appendSlice(std.testing.allocator, "FIFO_IMAGE measurement with module SPC-830");
    try list.appendNTimes(std.testing.allocator, 0, 128 - list.items.len);
    try list.appendSlice(std.testing.allocator, setup);
}

fn appendSyntheticSpc(list: *std.ArrayList(u8)) !void {
    try list.appendSlice(std.testing.allocator, &.{ 0, 0, 0, 8 });
    try appendEvent(list, 0x40, 0x90, 0); // frame clock
    try appendEvent(list, 0x20, 0x90, 0); // line 0
    try appendEvent(list, 0x00, 0x0f, 0xff); // photon in bin 0 at x 0
    try appendEvent(list, 0x10, 0x90, 0); // pixel clock
    try appendEvent(list, 0x10, 0x90, 0); // pixel clock
    try appendEvent(list, 0x20, 0x90, 0); // line 1
    try appendEvent(list, 0x00, 0x0f, 0xff); // photon in bin 0 at x 0, y 1
    try appendEvent(list, 0x10, 0x90, 0);
    try appendEvent(list, 0x10, 0x90, 0);
    try appendEvent(list, 0x40, 0x90, 0); // frame clock
    try appendEvent(list, 0x20, 0x90, 0); // close first frame
    try appendEvent(list, 0x40, 0x90, 0); // frame clock
    try appendEvent(list, 0x20, 0x90, 0); // close second frame
}

test "reads spc fifo metadata and first lifetime plane" {
    const set_path = "spc-test.set";
    const spc_path = "spc-test.spc";
    var set_data: std.ArrayList(u8) = .empty;
    defer set_data.deinit(std.testing.allocator);
    var spc_data: std.ArrayList(u8) = .empty;
    defer spc_data.deinit(std.testing.allocator);
    try appendSet(&set_data);
    try appendSyntheticSpc(&spc_data);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = set_path, .data = set_data.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, set_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = spc_path, .data = spc_data.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, spc_path) catch {};

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, set_path);
    try std.testing.expectEqualStrings("spc", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(@as(u32, n_timebins), metadata.plane_count);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, spc_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 1, 0 }, plane.data);
}

test "matches Bio-Formats default metadata for cached SPC fixture" {
    const file_path = "fixtures/cache/spc/conv-256x256.set";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    try std.testing.expectEqualStrings("spc", metadata.format);
    try std.testing.expectEqual(@as(u32, 266), metadata.width);
    try std.testing.expectEqual(@as(u32, 256), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 5056), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 5056), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 1), metadata.series_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYZTC", metadata.dimension_order.?);
}

test "matches Bio-Formats default plane and region hashes for cached SPC fixture" {
    const file_path = "fixtures/cache/spc/conv-256x256.set";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const expected = [_]struct { plane: u32, sha256: [32]u8 }{
        .{ .plane = 0, .sha256 = .{ 0x54, 0xf1, 0x55, 0x4c, 0x48, 0xce, 0xc6, 0x5c, 0x49, 0x03, 0x90, 0xa5, 0xd3, 0xb4, 0xc6, 0xdd, 0xdc, 0x7f, 0x7f, 0xfe, 0x54, 0x14, 0x88, 0xe8, 0xca, 0x0a, 0xbd, 0x8a, 0x18, 0xea, 0xbb, 0xcd } },
        .{ .plane = 2528, .sha256 = .{ 0x45, 0xc1, 0x8e, 0x09, 0xdb, 0x49, 0x02, 0xcb, 0xdd, 0x3c, 0xd5, 0x89, 0xbc, 0x10, 0x1b, 0x8f, 0xaa, 0x5a, 0x41, 0x41, 0xb2, 0xc0, 0x4e, 0x66, 0xa1, 0x68, 0x65, 0xca, 0x97, 0x0f, 0xd8, 0x1d } },
        .{ .plane = 5055, .sha256 = .{ 0x40, 0x32, 0x8d, 0x08, 0x5a, 0xde, 0x75, 0xb7, 0x51, 0x74, 0x80, 0xca, 0x45, 0xcf, 0x2e, 0x37, 0x2a, 0x9c, 0x61, 0xf9, 0xea, 0x29, 0xca, 0xde, 0x10, 0x31, 0x18, 0x67, 0xe6, 0x6a, 0xe0, 0x50 } },
    };
    for (expected) |sample| {
        const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, sample.plane, .{ .x = 0, .y = 0, .width = 266, .height = 256 });
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqual(@as(usize, 136192), plane.data.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
        try std.testing.expectEqualSlices(u8, &sample.sha256, &digest);
    }

    const region = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 17, .y = 19, .width = 16, .height = 12 });
    defer std.testing.allocator.free(region.data);
    try std.testing.expectEqual(@as(usize, 384), region.data.len);
    const expected_region: [32]u8 = .{ 0xa1, 0xa4, 0xf5, 0x72, 0x1c, 0x1c, 0x46, 0x10, 0xaf, 0x7f, 0x71, 0x07, 0x8f, 0x3a, 0x68, 0xc3, 0x30, 0x53, 0x6d, 0x67, 0x98, 0x03, 0xb0, 0xe0, 0x50, 0x7e, 0xe8, 0xdc, 0x10, 0xc5, 0xdf, 0xca };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(region.data, &digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_region, &digest);
}
