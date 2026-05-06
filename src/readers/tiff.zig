const std = @import("std");
const bio = @import("../root.zig");
const jpeg = @import("jpeg.zig");

const max_strips = 1024;
const max_tiles = 16384;
const max_color_map_values = 768;

const ByteOrder = enum {
    little,
    big,

    fn endian(self: ByteOrder) std.builtin.Endian {
        return switch (self) {
            .little => .little,
            .big => .big,
        };
    }
};

const TiffInfo = struct {
    order: ByteOrder,
    big: bool,
};

const Header = struct {
    order: ByteOrder,
    next_ifd_offset: u64,
    width: u32,
    height: u32,
    samples_per_pixel: u16,
    bits_per_sample: [4]u16,
    bits_count: usize,
    sample_format: [4]u16,
    sample_format_count: usize,
    extra_samples: [4]u16,
    extra_samples_count: usize,
    color_map: [max_color_map_values]u16,
    color_map_count: usize,
    compression: u32,
    fill_order: u16,
    predictor: u16,
    photometric: u32,
    planar_configuration: u16,
    rows_per_strip: u32,
    strip_offsets: [max_strips]u64,
    strip_byte_counts: [max_strips]u64,
    strip_count: usize,
    tile_width: u32,
    tile_length: u32,
    tile_offsets: [max_tiles]u64,
    tile_byte_counts: [max_tiles]u64,
    tile_count: usize,
    jpeg_tables: ?[]const u8,
    image_description: ?[]const u8,
};

const Entry = struct {
    offset: usize,
    tag: u16,
    field_type: u16,
    count: u64,
    value_offset: u64,
    value_field_offset: usize,
    inline_capacity: usize,
};

const TagScan = struct {
    found: bool,
    next_ifd_offset: u64,
};

pub const IfdTagInfo = struct {
    field_type: u16,
    count: u64,
};

const OmePixels = struct {
    size_z: ?u16 = null,
    size_c: ?u16 = null,
    size_t: ?u16 = null,
    dimension_order: ?[]const u8 = null,
};

const ImageJComment = struct {
    size_z: u16 = 1,
    size_c: u16 = 1,
    size_t: u16 = 1,
    image_count: u32 = 1,
};

pub fn matches(data: []const u8) bool {
    if (data.len < 4) return false;
    const little = data[0] == 'I' and data[1] == 'I';
    const big = data[0] == 'M' and data[1] == 'M';
    if (!little and !big) return false;
    const order: std.builtin.Endian = if (little) .little else .big;
    const magic = std.mem.readInt(u16, data[2..4], order);
    return magic == 42 or magic == 43;
}

pub fn containsTag(data: []const u8, tag: u16) bool {
    const info = readTiffInfo(data) catch return false;
    var ifd_offset = firstIfdOffset(data, info) catch return false;
    var seen: usize = 0;
    while (ifd_offset != 0 and seen < 1024) : (seen += 1) {
        const scan = scanIfdForTag(data, info, ifd_offset, tag) catch return false;
        if (scan.found) return true;
        ifd_offset = scan.next_ifd_offset;
    }
    return false;
}

pub fn firstIfdContainsTag(data: []const u8, tag: u16) bool {
    const info = readTiffInfo(data) catch return false;
    const ifd_offset = firstIfdOffset(data, info) catch return false;
    const scan = scanIfdForTag(data, info, ifd_offset, tag) catch return false;
    return scan.found;
}

pub fn firstIfdTagInfo(data: []const u8, tag: u16) ?IfdTagInfo {
    const info = readTiffInfo(data) catch return null;
    const ifd_offset = firstIfdOffset(data, info) catch return null;
    return readIfdTagInfo(data, info, ifd_offset, tag) catch null;
}

pub fn firstIfdUnsignedTag(data: []const u8, tag: u16) ?u64 {
    const info = readTiffInfo(data) catch return null;
    const ifd_offset = firstIfdOffset(data, info) catch return null;
    return readIfdUnsignedTag(data, info, ifd_offset, tag) catch null;
}

pub fn firstIfdAsciiTag(data: []const u8, tag: u16) ?[]const u8 {
    const info = readTiffInfo(data) catch return null;
    const ifd_offset = firstIfdOffset(data, info) catch return null;
    return readIfdAsciiTag(data, info, ifd_offset, tag) catch null;
}

pub fn firstIfdByteTag(data: []const u8, tag: u16) ?[]const u8 {
    const info = readTiffInfo(data) catch return null;
    const ifd_offset = firstIfdOffset(data, info) catch return null;
    return readIfdByteTag(data, info, ifd_offset, tag) catch null;
}

pub fn ifdCount(data: []const u8) ?u32 {
    const info = readTiffInfo(data) catch return null;
    return countIfds(data, info) catch null;
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const info = try readTiffInfo(data);
    const header = try parseHeaderAtIndex(data, info, 0);
    try validateReadable(header);
    var metadata = bio.Metadata{
        .format = "tiff",
        .width = header.width,
        .height = header.height,
        .size_c = if (header.photometric == 3) 3 else header.samples_per_pixel,
        .samples_per_pixel = if (header.photometric == 3) 3 else header.samples_per_pixel,
        .pixel_type = pixelType(header),
        .little_endian = header.order == .little,
        .plane_count = try countIfds(data, info),
        .image_description = header.image_description,
    };
    if (header.image_description) |description| {
        if (parseOmePixels(description)) |ome| {
            metadata.size_z = ome.size_z orelse metadata.size_z;
            metadata.size_c = ome.size_c orelse metadata.size_c;
            metadata.size_t = ome.size_t orelse metadata.size_t;
            metadata.dimension_order = ome.dimension_order;
        } else if (parseImageJComment(description)) |imagej| {
            metadata.dimension_order = "XYCZT";
            const zct = std.math.mul(u32, imagej.size_z, imagej.size_c) catch return error.UnsupportedVariant;
            const planes = std.math.mul(u32, zct, imagej.size_t) catch return error.UnsupportedVariant;
            if (planes == metadata.plane_count or imagej.image_count == metadata.plane_count) {
                metadata.size_z = imagej.size_z;
                metadata.size_c = imagej.size_c;
                metadata.size_t = imagej.size_t;
            }
        }
    }
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const info = try readTiffInfo(data);
    const header = try parseHeaderAtIndex(data, info, plane_index);
    try validateReadable(header);
    const metadata = try readMetadata(data);
    if (header.compression == 7) {
        if (header.tile_count != 0) {
            const bytes_per_pixel = metadata.bytesPerPixel();
            const row_bytes = std.math.mul(usize, metadata.width, bytes_per_pixel) catch return error.UnsupportedVariant;
            const out_len = std.math.mul(usize, row_bytes, metadata.height) catch return error.UnsupportedVariant;
            const out = try allocator.alloc(u8, out_len);
            errdefer allocator.free(out);
            try readJpegTiledRegion(allocator, data, header, metadata, bio.Region.full(metadata), row_bytes, out);
            return .{ .metadata = metadata, .data = out };
        }
        return readJpegCompressedPlane(allocator, data, header, metadata);
    }
    const row_bytes = std.math.mul(usize, header.width, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, row_bytes, header.height) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    if (header.photometric == 3) {
        try readPalettePlane(allocator, data, header, row_bytes, out);
        return .{ .metadata = metadata, .data = out };
    }

    if (header.bits_per_sample[0] < 8) {
        try readPackedGrayscalePlane(data, header, row_bytes, out);
        return .{ .metadata = metadata, .data = out };
    }

    if (header.planar_configuration == 2 and header.samples_per_pixel > 1 and header.tile_count != 0) {
        try readSeparatedTiledPlane(allocator, data, header, row_bytes, out);
        return .{ .metadata = metadata, .data = out };
    }

    if (header.planar_configuration == 2 and header.samples_per_pixel > 1) {
        try readSeparatedStripPlane(allocator, data, header, row_bytes, out);
        return .{ .metadata = metadata, .data = out };
    }

    if (header.tile_count != 0) {
        try readTiledPlane(allocator, data, header, row_bytes, out);
        return .{ .metadata = metadata, .data = out };
    }

    var dest_row: usize = 0;
    var strip_index: usize = 0;
    while (strip_index < header.strip_count and dest_row < header.height) : (strip_index += 1) {
        const remaining_rows = header.height - dest_row;
        const rows_this_strip = @min(@as(usize, header.rows_per_strip), remaining_rows);
        const bytes_this_strip = std.math.mul(usize, rows_this_strip, row_bytes) catch return error.UnsupportedVariant;
        const src_offset = try checkedUsize(header.strip_offsets[strip_index]);
        const compressed_bytes = try checkedUsize(header.strip_byte_counts[strip_index]);
        if (src_offset > data.len or data.len - src_offset < compressed_bytes) return error.TruncatedData;
        const dst_offset = dest_row * row_bytes;
        try copyDecodedBlock(
            allocator,
            header,
            data[src_offset..][0..compressed_bytes],
            out[dst_offset..][0..bytes_this_strip],
            .{
                .width = header.width,
                .rows = rows_this_strip,
                .samples_per_pixel = header.samples_per_pixel,
                .row_bytes = row_bytes,
            },
        );
        dest_row += rows_this_strip;
    }
    if (dest_row != header.height) return error.TruncatedData;

    return .{ .metadata = metadata, .data = out };
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    const info = try readTiffInfo(data);
    const header = try parseHeaderAtIndex(data, info, plane_index);
    try validateReadable(header);
    const metadata = try readMetadata(data);
    try region.validate(metadata);
    if (region.isFull(metadata) and !(header.compression == 7 and header.tile_count != 0)) return readPlaneIndex(allocator, data, plane_index);
    if (header.compression == 7) {
        if (header.tile_count != 0) {
            const bytes_per_pixel = metadata.bytesPerPixel();
            const row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
            const out_len = std.math.mul(usize, row_bytes, region.height) catch return error.UnsupportedVariant;
            const out = try allocator.alloc(u8, out_len);
            errdefer allocator.free(out);
            try readJpegTiledRegion(allocator, data, header, metadata, region, row_bytes, out);
            return .{ .metadata = metadata, .data = out };
        }
        const plane = try readPlaneIndex(allocator, data, plane_index);
        defer allocator.free(plane.data);
        return .{ .metadata = metadata, .data = try bio.cropPlane(allocator, plane, region) };
    }

    if (header.bits_per_sample[0] < 8 and header.photometric != 3) {
        const plane = try readPlaneIndex(allocator, data, plane_index);
        defer allocator.free(plane.data);
        return .{ .metadata = metadata, .data = try bio.cropPlane(allocator, plane, region) };
    }

    if (header.photometric == 3) {
        const plane = try readPlaneIndex(allocator, data, plane_index);
        defer allocator.free(plane.data);
        return .{ .metadata = metadata, .data = try bio.cropPlane(allocator, plane, region) };
    }

    if (header.tile_count == 0 and header.planar_configuration == 1) {
        const bytes_per_pixel = metadata.bytesPerPixel();
        const row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
        const out_len = std.math.mul(usize, row_bytes, region.height) catch return error.UnsupportedVariant;
        const out = try allocator.alloc(u8, out_len);
        errdefer allocator.free(out);
        try readStrippedRegion(allocator, data, header, metadata, region, row_bytes, out);
        return .{ .metadata = metadata, .data = out };
    }

    if (header.tile_count == 0 and header.planar_configuration == 2) {
        const bytes_per_pixel = metadata.bytesPerPixel();
        const row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
        const out_len = std.math.mul(usize, row_bytes, region.height) catch return error.UnsupportedVariant;
        const out = try allocator.alloc(u8, out_len);
        errdefer allocator.free(out);
        try readSeparatedStrippedRegion(allocator, data, header, region, row_bytes, out);
        return .{ .metadata = metadata, .data = out };
    }

    if (header.tile_count == 0) {
        const plane = try readPlaneIndex(allocator, data, plane_index);
        defer allocator.free(plane.data);
        return .{ .metadata = metadata, .data = try bio.cropPlane(allocator, plane, region) };
    }

    if (header.planar_configuration == 2) {
        const bytes_per_pixel = metadata.bytesPerPixel();
        const row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
        const out_len = std.math.mul(usize, row_bytes, region.height) catch return error.UnsupportedVariant;
        const out = try allocator.alloc(u8, out_len);
        errdefer allocator.free(out);
        try readSeparatedTiledRegion(allocator, data, header, region, row_bytes, out);
        return .{ .metadata = metadata, .data = out };
    }

    const bytes_per_pixel = metadata.bytesPerPixel();
    const row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, row_bytes, region.height) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    try readTiledRegion(allocator, data, header, metadata, region, row_bytes, out);
    return .{ .metadata = metadata, .data = out };
}

fn readTiffInfo(data: []const u8) bio.ReaderError!TiffInfo {
    if (data.len < 8) return error.InvalidFormat;
    const order: ByteOrder = if (data[0] == 'I' and data[1] == 'I') .little else if (data[0] == 'M' and data[1] == 'M') .big else return error.InvalidFormat;
    const magic = readU16(order, data[2..4]);
    if (magic == 42) return .{ .order = order, .big = false };
    if (magic == 43) {
        if (data.len < 16) return error.InvalidFormat;
        if (readU16(order, data[4..6]) != 8 or readU16(order, data[6..8]) != 0) return error.UnsupportedVariant;
        return .{ .order = order, .big = true };
    }
    return error.InvalidFormat;
}

fn firstIfdOffset(data: []const u8, info: TiffInfo) bio.ReaderError!u64 {
    if (info.big) {
        if (data.len < 16) return error.InvalidFormat;
        return readU64(info.order, data[8..16]);
    }
    if (data.len < 8) return error.InvalidFormat;
    return readU32(info.order, data[4..8]);
}

fn parseHeaderAtIndex(data: []const u8, info: TiffInfo, plane_index: u32) bio.ReaderError!Header {
    var ifd_offset = try firstIfdOffset(data, info);
    var i: u32 = 0;
    while (i < plane_index) : (i += 1) {
        if (ifd_offset == 0) return error.InvalidPlaneIndex;
        const header = try parseHeaderAtOffset(data, info, ifd_offset);
        ifd_offset = header.next_ifd_offset;
    }
    if (ifd_offset == 0) return error.InvalidPlaneIndex;
    return parseHeaderAtOffset(data, info, ifd_offset);
}

fn countIfds(data: []const u8, info: TiffInfo) bio.ReaderError!u32 {
    var ifd_offset = try firstIfdOffset(data, info);
    var count: u32 = 0;
    while (ifd_offset != 0) {
        const header = try parseHeaderAtOffset(data, info, ifd_offset);
        count += 1;
        ifd_offset = header.next_ifd_offset;
    }
    return count;
}

fn scanIfdForTag(data: []const u8, info: TiffInfo, ifd_offset_u64: u64, tag: u16) bio.ReaderError!TagScan {
    const ifd_offset = try checkedUsize(ifd_offset_u64);
    const count_size: usize = if (info.big) 8 else 2;
    const entry_size: usize = if (info.big) 20 else 12;
    const next_size: usize = if (info.big) 8 else 4;
    if (ifd_offset > data.len or data.len - ifd_offset < count_size) return error.TruncatedData;

    const entry_count_u64 = if (info.big) readU64(info.order, data[ifd_offset..][0..8]) else readU16(info.order, data[ifd_offset..][0..2]);
    const entry_count = try checkedUsize(entry_count_u64);
    const entries_start = ifd_offset + count_size;
    const entries_bytes = std.math.mul(usize, entry_count, entry_size) catch return error.UnsupportedVariant;
    if (entries_start > data.len or data.len - entries_start < entries_bytes) return error.TruncatedData;
    const next_ifd_pos = entries_start + entries_bytes;
    if (next_ifd_pos > data.len or data.len - next_ifd_pos < next_size) return error.TruncatedData;

    const next_ifd_offset = if (info.big) readU64(info.order, data[next_ifd_pos..][0..8]) else readU32(info.order, data[next_ifd_pos..][0..4]);
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const entry = parseEntry(info, data, entries_start + i * entry_size);
        if (entry.tag == tag) return .{ .found = true, .next_ifd_offset = next_ifd_offset };
    }
    return .{ .found = false, .next_ifd_offset = next_ifd_offset };
}

fn readIfdAsciiTag(data: []const u8, info: TiffInfo, ifd_offset_u64: u64, tag: u16) bio.ReaderError!?[]const u8 {
    const ifd_offset = try checkedUsize(ifd_offset_u64);
    const count_size: usize = if (info.big) 8 else 2;
    const entry_size: usize = if (info.big) 20 else 12;
    if (ifd_offset > data.len or data.len - ifd_offset < count_size) return error.TruncatedData;

    const entry_count_u64 = if (info.big) readU64(info.order, data[ifd_offset..][0..8]) else readU16(info.order, data[ifd_offset..][0..2]);
    const entry_count = try checkedUsize(entry_count_u64);
    const entries_start = ifd_offset + count_size;
    const entries_bytes = std.math.mul(usize, entry_count, entry_size) catch return error.UnsupportedVariant;
    if (entries_start > data.len or data.len - entries_start < entries_bytes) return error.TruncatedData;

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const entry = parseEntry(info, data, entries_start + i * entry_size);
        if (entry.tag == tag) return try entryAscii(data, entry);
    }
    return null;
}

fn readIfdByteTag(data: []const u8, info: TiffInfo, ifd_offset_u64: u64, tag: u16) bio.ReaderError!?[]const u8 {
    const ifd_offset = try checkedUsize(ifd_offset_u64);
    const count_size: usize = if (info.big) 8 else 2;
    const entry_size: usize = if (info.big) 20 else 12;
    if (ifd_offset > data.len or data.len - ifd_offset < count_size) return error.TruncatedData;

    const entry_count_u64 = if (info.big) readU64(info.order, data[ifd_offset..][0..8]) else readU16(info.order, data[ifd_offset..][0..2]);
    const entry_count = try checkedUsize(entry_count_u64);
    const entries_start = ifd_offset + count_size;
    const entries_bytes = std.math.mul(usize, entry_count, entry_size) catch return error.UnsupportedVariant;
    if (entries_start > data.len or data.len - entries_start < entries_bytes) return error.TruncatedData;

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const entry = parseEntry(info, data, entries_start + i * entry_size);
        if (entry.tag == tag) return try entryBytes(data, entry);
    }
    return null;
}

fn readIfdTagInfo(data: []const u8, info: TiffInfo, ifd_offset_u64: u64, tag: u16) bio.ReaderError!?IfdTagInfo {
    const ifd_offset = try checkedUsize(ifd_offset_u64);
    const count_size: usize = if (info.big) 8 else 2;
    const entry_size: usize = if (info.big) 20 else 12;
    if (ifd_offset > data.len or data.len - ifd_offset < count_size) return error.TruncatedData;

    const entry_count_u64 = if (info.big) readU64(info.order, data[ifd_offset..][0..8]) else readU16(info.order, data[ifd_offset..][0..2]);
    const entry_count = try checkedUsize(entry_count_u64);
    const entries_start = ifd_offset + count_size;
    const entries_bytes = std.math.mul(usize, entry_count, entry_size) catch return error.UnsupportedVariant;
    if (entries_start > data.len or data.len - entries_start < entries_bytes) return error.TruncatedData;

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const entry = parseEntry(info, data, entries_start + i * entry_size);
        if (entry.tag == tag) return .{ .field_type = entry.field_type, .count = entry.count };
    }
    return null;
}

fn readIfdUnsignedTag(data: []const u8, info: TiffInfo, ifd_offset_u64: u64, tag: u16) bio.ReaderError!?u64 {
    const ifd_offset = try checkedUsize(ifd_offset_u64);
    const count_size: usize = if (info.big) 8 else 2;
    const entry_size: usize = if (info.big) 20 else 12;
    if (ifd_offset > data.len or data.len - ifd_offset < count_size) return error.TruncatedData;

    const entry_count_u64 = if (info.big) readU64(info.order, data[ifd_offset..][0..8]) else readU16(info.order, data[ifd_offset..][0..2]);
    const entry_count = try checkedUsize(entry_count_u64);
    const entries_start = ifd_offset + count_size;
    const entries_bytes = std.math.mul(usize, entry_count, entry_size) catch return error.UnsupportedVariant;
    if (entries_start > data.len or data.len - entries_start < entries_bytes) return error.TruncatedData;

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const entry = parseEntry(info, data, entries_start + i * entry_size);
        if (entry.tag == tag) return try entryValueU64(info.order, data, entry, 0);
    }
    return null;
}

fn parseHeaderAtOffset(data: []const u8, info: TiffInfo, ifd_offset_u64: u64) bio.ReaderError!Header {
    const ifd_offset = try checkedUsize(ifd_offset_u64);
    const count_size: usize = if (info.big) 8 else 2;
    const entry_size: usize = if (info.big) 20 else 12;
    const next_size: usize = if (info.big) 8 else 4;
    if (ifd_offset > data.len or data.len - ifd_offset < count_size) return error.TruncatedData;

    const entry_count_u64 = if (info.big) readU64(info.order, data[ifd_offset..][0..8]) else readU16(info.order, data[ifd_offset..][0..2]);
    const entry_count = try checkedUsize(entry_count_u64);
    const entries_start = ifd_offset + count_size;
    const entries_bytes = std.math.mul(usize, entry_count, entry_size) catch return error.UnsupportedVariant;
    if (entries_start > data.len or data.len - entries_start < entries_bytes) return error.TruncatedData;
    const next_ifd_pos = entries_start + entries_bytes;
    if (next_ifd_pos > data.len or data.len - next_ifd_pos < next_size) return error.TruncatedData;

    var header: Header = .{
        .order = info.order,
        .next_ifd_offset = if (info.big) readU64(info.order, data[next_ifd_pos..][0..8]) else readU32(info.order, data[next_ifd_pos..][0..4]),
        .width = 0,
        .height = 0,
        .samples_per_pixel = 1,
        .bits_per_sample = .{ 1, 0, 0, 0 },
        .bits_count = 1,
        .sample_format = .{ 1, 0, 0, 0 },
        .sample_format_count = 1,
        .extra_samples = .{ 0, 0, 0, 0 },
        .extra_samples_count = 0,
        .color_map = [_]u16{0} ** max_color_map_values,
        .color_map_count = 0,
        .compression = 1,
        .fill_order = 1,
        .predictor = 1,
        .photometric = 1,
        .planar_configuration = 1,
        .rows_per_strip = 0,
        .strip_offsets = [_]u64{0} ** max_strips,
        .strip_byte_counts = [_]u64{0} ** max_strips,
        .strip_count = 0,
        .tile_width = 0,
        .tile_length = 0,
        .tile_offsets = [_]u64{0} ** max_tiles,
        .tile_byte_counts = [_]u64{0} ** max_tiles,
        .tile_count = 0,
        .jpeg_tables = null,
        .image_description = null,
    };

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const entry = parseEntry(info, data, entries_start + i * entry_size);
        switch (entry.tag) {
            270 => header.image_description = try entryAscii(data, entry),
            256 => header.width = try entryValueU32(info.order, data, entry, 0),
            257 => header.height = try entryValueU32(info.order, data, entry, 0),
            258 => {
                header.bits_count = @min(try checkedUsize(entry.count), header.bits_per_sample.len);
                var b: usize = 0;
                while (b < header.bits_count) : (b += 1) {
                    header.bits_per_sample[b] = @intCast(try entryValueU32(info.order, data, entry, b));
                }
            },
            266 => header.fill_order = @intCast(try entryValueU32(info.order, data, entry, 0)),
            259 => header.compression = try entryValueU32(info.order, data, entry, 0),
            262 => header.photometric = try entryValueU32(info.order, data, entry, 0),
            273 => {
                header.strip_count = try copyEntryValues(info.order, data, entry, &header.strip_offsets);
            },
            277 => header.samples_per_pixel = @intCast(try entryValueU32(info.order, data, entry, 0)),
            278 => header.rows_per_strip = try entryValueU32(info.order, data, entry, 0),
            279 => {
                const count = try copyEntryValues(info.order, data, entry, &header.strip_byte_counts);
                if (header.strip_count == 0) header.strip_count = count;
            },
            284 => header.planar_configuration = @intCast(try entryValueU32(info.order, data, entry, 0)),
            317 => header.predictor = @intCast(try entryValueU32(info.order, data, entry, 0)),
            320 => {
                header.color_map_count = @min(try checkedUsize(entry.count), header.color_map.len);
                var c: usize = 0;
                while (c < header.color_map_count) : (c += 1) {
                    header.color_map[c] = @intCast(try entryValueU32(info.order, data, entry, c));
                }
            },
            338 => {
                header.extra_samples_count = @min(try checkedUsize(entry.count), header.extra_samples.len);
                var e: usize = 0;
                while (e < header.extra_samples_count) : (e += 1) {
                    header.extra_samples[e] = @intCast(try entryValueU32(info.order, data, entry, e));
                }
            },
            339 => {
                header.sample_format_count = @min(try checkedUsize(entry.count), header.sample_format.len);
                var s: usize = 0;
                while (s < header.sample_format_count) : (s += 1) {
                    header.sample_format[s] = @intCast(try entryValueU32(info.order, data, entry, s));
                }
            },
            322 => header.tile_width = try entryValueU32(info.order, data, entry, 0),
            323 => header.tile_length = try entryValueU32(info.order, data, entry, 0),
            324 => {
                header.tile_count = try copyEntryValues(info.order, data, entry, &header.tile_offsets);
            },
            325 => {
                const count = try copyEntryValues(info.order, data, entry, &header.tile_byte_counts);
                if (header.tile_count == 0) header.tile_count = count;
            },
            347 => header.jpeg_tables = try entryBytes(data, entry),
            else => {},
        }
    }

    if (header.rows_per_strip == 0) header.rows_per_strip = header.height;
    if (header.width == 0 or header.height == 0) return error.InvalidFormat;
    if (header.strip_count == 0 and header.tile_count == 0) return error.InvalidFormat;
    return header;
}

fn validateReadable(header: Header) bio.ReaderError!void {
    if (header.compression != 1 and header.compression != 5 and header.compression != 7 and header.compression != 8 and header.compression != 32773 and header.compression != 32946) return error.UnsupportedVariant;
    if (header.predictor != 1 and header.predictor != 2) return error.UnsupportedVariant;
    if (header.fill_order != 1 and header.fill_order != 2) return error.UnsupportedVariant;
    if (header.samples_per_pixel != 1 and header.samples_per_pixel != 3 and header.samples_per_pixel != 4) return error.UnsupportedVariant;
    if (header.planar_configuration != 1 and header.planar_configuration != 2) return error.UnsupportedVariant;
    if (header.photometric != 0 and header.photometric != 1 and header.photometric != 2 and header.photometric != 3 and header.photometric != 6) return error.UnsupportedVariant;
    if (header.photometric == 6 and header.compression != 7) return error.UnsupportedVariant;
    if (header.bits_count < header.samples_per_pixel) return error.UnsupportedVariant;
    if (header.sample_format_count < header.samples_per_pixel and header.sample_format_count != 1) return error.UnsupportedVariant;
    const first_bits = header.bits_per_sample[0];
    const first_sample_format = header.sample_format[0];
    if (header.compression == 7) {
        if (header.photometric != 6 and header.photometric != 2) return error.UnsupportedVariant;
        if (header.samples_per_pixel != 3 or first_bits != 8 or first_sample_format != 1) return error.UnsupportedVariant;
        if (header.predictor != 1 or header.fill_order != 1 or header.planar_configuration != 1) return error.UnsupportedVariant;
        if (!((header.strip_count == 1 and header.tile_count == 0) or (header.strip_count == 0 and header.tile_count != 0))) return error.UnsupportedVariant;
    }
    if (first_sample_format != 1 and first_sample_format != 2 and first_sample_format != 3) return error.UnsupportedVariant;
    var i: usize = 0;
    while (i < header.samples_per_pixel) : (i += 1) {
        if (header.bits_per_sample[i] != first_bits) return error.UnsupportedVariant;
        const sample_format = if (header.sample_format_count == 1) header.sample_format[0] else header.sample_format[i];
        if (sample_format != first_sample_format) return error.UnsupportedVariant;
    }
    if (first_sample_format == 1) {
        if (first_bits != 1 and first_bits != 2 and first_bits != 4 and first_bits != 8 and first_bits != 16 and first_bits != 32) return error.UnsupportedVariant;
        if (first_bits < 8 and (header.samples_per_pixel != 1 or header.predictor != 1 or header.compression != 1 or header.tile_count != 0)) return error.UnsupportedVariant;
        if (first_bits == 32 and (header.samples_per_pixel != 1 or header.predictor != 1)) return error.UnsupportedVariant;
    } else if (first_sample_format == 2) {
        if ((first_bits != 8 and first_bits != 16 and first_bits != 32) or header.samples_per_pixel != 1) return error.UnsupportedVariant;
        if (first_bits == 32 and header.predictor != 1) return error.UnsupportedVariant;
    } else {
        if ((first_bits != 32 and first_bits != 64) or header.samples_per_pixel != 1 or header.predictor != 1) return error.UnsupportedVariant;
    }
    if (header.tile_count != 0) {
        if (header.tile_width == 0 or header.tile_length == 0) return error.InvalidFormat;
    }
    if (header.photometric == 0 and (first_sample_format != 1 or header.samples_per_pixel != 1)) return error.UnsupportedVariant;
    if ((header.photometric == 2 or header.photometric == 6) and header.samples_per_pixel != 3 and header.samples_per_pixel != 4) return error.UnsupportedVariant;
    if (header.photometric != 2 and header.samples_per_pixel == 4) return error.UnsupportedVariant;
    if (header.photometric == 3) {
        if (first_bits != 1 and first_bits != 2 and first_bits != 4 and first_bits != 8) return error.UnsupportedVariant;
        const color_count = std.math.mul(usize, 3, @as(usize, 1) << @intCast(first_bits)) catch return error.UnsupportedVariant;
        if (first_sample_format != 1 or header.samples_per_pixel != 1 or header.color_map_count != color_count) return error.UnsupportedVariant;
    }
}

fn pixelType(header: Header) bio.PixelType {
    if (header.photometric == 3) return .rgb8;
    if (header.photometric == 6) return .rgb8;
    if (header.sample_format[0] == 2) {
        return switch (header.bits_per_sample[0]) {
            8 => .int8,
            16 => .int16,
            else => .int32,
        };
    }
    if (header.sample_format[0] == 3) return if (header.bits_per_sample[0] == 64) .float64 else .float32;
    return switch (header.bits_per_sample[0]) {
        32 => .uint32,
        16 => if (header.samples_per_pixel == 4) .rgba16 else if (header.samples_per_pixel == 3) .rgb16 else .uint16,
        else => if (header.samples_per_pixel == 4) .rgba8 else if (header.samples_per_pixel == 3) .rgb8 else .uint8,
    };
}

fn readJpegCompressedPlane(
    allocator: std.mem.Allocator,
    data: []const u8,
    header: Header,
    metadata: bio.Metadata,
) bio.ReaderError!bio.Plane {
    if (header.strip_count != 1) return error.UnsupportedVariant;
    const src_offset = try checkedUsize(header.strip_offsets[0]);
    const compressed_bytes = try checkedUsize(header.strip_byte_counts[0]);
    if (src_offset > data.len or data.len - src_offset < compressed_bytes) return error.TruncatedData;
    const jpeg_src = try jpegWithTables(allocator, data[src_offset..][0..compressed_bytes], header.jpeg_tables);
    defer if (jpeg_src.owned) allocator.free(jpeg_src.bytes);
    const decoded = try jpeg.readPlaneIndexAs(allocator, jpeg_src.bytes, 0, metadata.format);
    errdefer allocator.free(decoded.data);
    if (decoded.metadata.width != metadata.width or decoded.metadata.height != metadata.height) return error.UnsupportedVariant;
    if (decoded.metadata.pixel_type != metadata.pixel_type) return error.UnsupportedVariant;
    return .{ .metadata = metadata, .data = decoded.data };
}

fn readJpegTiledRegion(
    allocator: std.mem.Allocator,
    data: []const u8,
    header: Header,
    metadata: bio.Metadata,
    region: bio.Region,
    region_row_bytes: usize,
    out: []u8,
) bio.ReaderError!void {
    const bytes_per_pixel = metadata.bytesPerPixel();
    const tile_width: usize = header.tile_width;
    const tile_length: usize = header.tile_length;
    const tiles_across = ceilDiv(header.width, header.tile_width);
    const tiles_down = ceilDiv(header.height, header.tile_length);
    const expected_tiles = std.math.mul(usize, tiles_across, tiles_down) catch return error.UnsupportedVariant;
    if (header.tile_count < expected_tiles) return error.TruncatedData;

    const region_x0: usize = region.x;
    const region_y0: usize = region.y;
    const region_x1: usize = @as(usize, region.x) + region.width;
    const region_y1: usize = @as(usize, region.y) + region.height;
    const start_tile_x = region_x0 / tile_width;
    const end_tile_x = (region_x1 - 1) / tile_width;
    const start_tile_y = region_y0 / tile_length;
    const end_tile_y = (region_y1 - 1) / tile_length;

    var tile_y = start_tile_y;
    while (tile_y <= end_tile_y) : (tile_y += 1) {
        var tile_x = start_tile_x;
        while (tile_x <= end_tile_x) : (tile_x += 1) {
            const tile_index = tile_y * tiles_across + tile_x;
            const src_offset = try checkedUsize(header.tile_offsets[tile_index]);
            const compressed_bytes = try checkedUsize(header.tile_byte_counts[tile_index]);
            if (src_offset > data.len or data.len - src_offset < compressed_bytes) return error.TruncatedData;

            const tile_x0 = tile_x * tile_width;
            const tile_y0 = tile_y * tile_length;
            const copy_x0 = @max(region_x0, tile_x0);
            const copy_y0 = @max(region_y0, tile_y0);
            const copy_x1 = @min(region_x1, tile_x0 + tile_width);
            const copy_y1 = @min(region_y1, tile_y0 + tile_length);
            const local_region: bio.Region = .{
                .x = @intCast(copy_x0 - tile_x0),
                .y = @intCast(copy_y0 - tile_y0),
                .width = @intCast(copy_x1 - copy_x0),
                .height = @intCast(copy_y1 - copy_y0),
            };

            const jpeg_src = try jpegWithTables(allocator, data[src_offset..][0..compressed_bytes], header.jpeg_tables);
            defer if (jpeg_src.owned) allocator.free(jpeg_src.bytes);
            const decoded = try jpeg.readRegionIndexAs(allocator, jpeg_src.bytes, 0, metadata.format, local_region);
            defer allocator.free(decoded.data);
            if (decoded.metadata.pixel_type != metadata.pixel_type) return error.UnsupportedVariant;

            const dst_x = copy_x0 - region_x0;
            const dst_y = copy_y0 - region_y0;
            const copy_width = copy_x1 - copy_x0;
            const copy_bytes = std.math.mul(usize, copy_width, bytes_per_pixel) catch return error.UnsupportedVariant;

            var row: usize = 0;
            while (row < local_region.height) : (row += 1) {
                const dst_row = (dst_y + row) * region_row_bytes + dst_x * bytes_per_pixel;
                const src_row = row * copy_bytes;
                @memcpy(out[dst_row..][0..copy_bytes], decoded.data[src_row..][0..copy_bytes]);
            }
        }
    }
}

const JpegSource = struct {
    bytes: []const u8,
    owned: bool,
};

fn jpegWithTables(allocator: std.mem.Allocator, src: []const u8, maybe_tables: ?[]const u8) bio.ReaderError!JpegSource {
    const tables = maybe_tables orelse return .{ .bytes = src, .owned = false };
    if (src.len < 2 or src[0] != 0xff or src[1] != 0xd8) return error.InvalidFormat;
    var table_start: usize = 0;
    var table_end: usize = tables.len;
    if (table_end >= 2 and tables[0] == 0xff and tables[1] == 0xd8) table_start = 2;
    if (table_end >= table_start + 2 and tables[table_end - 2] == 0xff and tables[table_end - 1] == 0xd9) table_end -= 2;
    if (table_end <= table_start) return .{ .bytes = src, .owned = false };

    const table_len = table_end - table_start;
    const out_len = std.math.add(usize, 2 + table_len, src.len - 2) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    @memcpy(out[0..2], src[0..2]);
    @memcpy(out[2..][0..table_len], tables[table_start..table_end]);
    @memcpy(out[2 + table_len ..], src[2..]);
    return .{ .bytes = out, .owned = true };
}

fn readSeparatedStripPlane(
    allocator: std.mem.Allocator,
    data: []const u8,
    header: Header,
    row_bytes: usize,
    out: []u8,
) bio.ReaderError!void {
    const bytes_per_sample: usize = header.bits_per_sample[0] / 8;
    const samples: usize = header.samples_per_pixel;
    const sample_row_bytes = std.math.mul(usize, header.width, bytes_per_sample) catch return error.UnsupportedVariant;
    const strips_per_sample = ceilDiv(header.height, header.rows_per_strip);
    const expected_strips = std.math.mul(usize, strips_per_sample, samples) catch return error.UnsupportedVariant;
    if (header.strip_count < expected_strips) return error.TruncatedData;

    var sample: usize = 0;
    while (sample < samples) : (sample += 1) {
        var dest_row: usize = 0;
        var strip_index: usize = 0;
        while (strip_index < strips_per_sample and dest_row < header.height) : (strip_index += 1) {
            const rows_this_strip = @min(@as(usize, header.rows_per_strip), @as(usize, header.height) - dest_row);
            const expected_bytes = std.math.mul(usize, rows_this_strip, sample_row_bytes) catch return error.UnsupportedVariant;
            const global_strip = sample * strips_per_sample + strip_index;
            const src_offset = try checkedUsize(header.strip_offsets[global_strip]);
            const compressed_bytes = try checkedUsize(header.strip_byte_counts[global_strip]);
            if (src_offset > data.len or data.len - src_offset < compressed_bytes) return error.TruncatedData;
            const decoded = try decodeBlock(
                allocator,
                header,
                data[src_offset..][0..compressed_bytes],
                expected_bytes,
                .{
                    .width = header.width,
                    .rows = rows_this_strip,
                    .samples_per_pixel = 1,
                    .row_bytes = sample_row_bytes,
                },
            );
            defer if (decoded.owned) allocator.free(decoded.bytes);

            var row: usize = 0;
            while (row < rows_this_strip) : (row += 1) {
                var x: usize = 0;
                while (x < header.width) : (x += 1) {
                    const src = row * sample_row_bytes + x * bytes_per_sample;
                    const dst = (dest_row + row) * row_bytes + x * samples * bytes_per_sample + sample * bytes_per_sample;
                    @memcpy(out[dst..][0..bytes_per_sample], decoded.bytes[src..][0..bytes_per_sample]);
                }
            }
            dest_row += rows_this_strip;
        }
    }
}

fn readSeparatedTiledPlane(
    allocator: std.mem.Allocator,
    data: []const u8,
    header: Header,
    row_bytes: usize,
    out: []u8,
) bio.ReaderError!void {
    const bytes_per_sample: usize = header.bits_per_sample[0] / 8;
    const samples: usize = header.samples_per_pixel;
    const tile_width: usize = header.tile_width;
    const tile_length: usize = header.tile_length;
    const sample_tile_row_bytes = std.math.mul(usize, tile_width, bytes_per_sample) catch return error.UnsupportedVariant;
    const sample_tile_bytes = std.math.mul(usize, sample_tile_row_bytes, tile_length) catch return error.UnsupportedVariant;
    const tiles_across = ceilDiv(header.width, header.tile_width);
    const tiles_down = ceilDiv(header.height, header.tile_length);
    const tiles_per_sample = std.math.mul(usize, tiles_across, tiles_down) catch return error.UnsupportedVariant;
    const expected_tiles = std.math.mul(usize, tiles_per_sample, samples) catch return error.UnsupportedVariant;
    if (header.tile_count < expected_tiles) return error.TruncatedData;

    var sample: usize = 0;
    while (sample < samples) : (sample += 1) {
        var tile_y: usize = 0;
        while (tile_y < tiles_down) : (tile_y += 1) {
            var tile_x: usize = 0;
            while (tile_x < tiles_across) : (tile_x += 1) {
                const tile_index = sample * tiles_per_sample + tile_y * tiles_across + tile_x;
                const src_offset = try checkedUsize(header.tile_offsets[tile_index]);
                const compressed_bytes = try checkedUsize(header.tile_byte_counts[tile_index]);
                if (src_offset > data.len or data.len - src_offset < compressed_bytes) return error.TruncatedData;
                const decoded = try decodeBlock(
                    allocator,
                    header,
                    data[src_offset..][0..compressed_bytes],
                    sample_tile_bytes,
                    .{
                        .width = tile_width,
                        .rows = tile_length,
                        .samples_per_pixel = 1,
                        .row_bytes = sample_tile_row_bytes,
                    },
                );
                defer if (decoded.owned) allocator.free(decoded.bytes);

                const image_x = tile_x * tile_width;
                const image_y = tile_y * tile_length;
                const copy_width = @min(tile_width, @as(usize, header.width) - image_x);
                const copy_height = @min(tile_length, @as(usize, header.height) - image_y);

                var row: usize = 0;
                while (row < copy_height) : (row += 1) {
                    var x: usize = 0;
                    while (x < copy_width) : (x += 1) {
                        const src = row * sample_tile_row_bytes + x * bytes_per_sample;
                        const dst = (image_y + row) * row_bytes + (image_x + x) * samples * bytes_per_sample + sample * bytes_per_sample;
                        @memcpy(out[dst..][0..bytes_per_sample], decoded.bytes[src..][0..bytes_per_sample]);
                    }
                }
            }
        }
    }
}

fn readPalettePlane(
    allocator: std.mem.Allocator,
    data: []const u8,
    header: Header,
    row_bytes: usize,
    out: []u8,
) bio.ReaderError!void {
    const index_row_bytes: usize = header.width;
    const index_len = std.math.mul(usize, index_row_bytes, header.height) catch return error.UnsupportedVariant;
    const indices = try allocator.alloc(u8, index_len);
    defer allocator.free(indices);

    if (header.tile_count != 0) {
        try readPaletteTiledIndices(allocator, data, header, index_row_bytes, indices);
    } else {
        try readPaletteStripIndices(allocator, data, header, index_row_bytes, indices);
    }

    var y: usize = 0;
    while (y < header.height) : (y += 1) {
        var x: usize = 0;
        while (x < header.width) : (x += 1) {
            const index = indices[y * index_row_bytes + x];
            const dst = y * row_bytes + x * 3;
            out[dst + 0] = paletteComponent(header, 0, index);
            out[dst + 1] = paletteComponent(header, 1, index);
            out[dst + 2] = paletteComponent(header, 2, index);
        }
    }
}

fn readPaletteStripIndices(
    allocator: std.mem.Allocator,
    data: []const u8,
    header: Header,
    row_bytes: usize,
    out: []u8,
) bio.ReaderError!void {
    if (header.bits_per_sample[0] < 8) {
        try readPackedPaletteStripIndices(data, header, row_bytes, out);
        return;
    }

    var dest_row: usize = 0;
    var strip_index: usize = 0;
    while (strip_index < header.strip_count and dest_row < header.height) : (strip_index += 1) {
        const remaining_rows = header.height - dest_row;
        const rows_this_strip = @min(@as(usize, header.rows_per_strip), remaining_rows);
        const bytes_this_strip = std.math.mul(usize, rows_this_strip, row_bytes) catch return error.UnsupportedVariant;
        const src_offset = try checkedUsize(header.strip_offsets[strip_index]);
        const compressed_bytes = try checkedUsize(header.strip_byte_counts[strip_index]);
        if (src_offset > data.len or data.len - src_offset < compressed_bytes) return error.TruncatedData;
        const dst_offset = dest_row * row_bytes;
        try copyDecodedBlock(
            allocator,
            header,
            data[src_offset..][0..compressed_bytes],
            out[dst_offset..][0..bytes_this_strip],
            .{
                .width = header.width,
                .rows = rows_this_strip,
                .samples_per_pixel = 1,
                .row_bytes = row_bytes,
            },
        );
        dest_row += rows_this_strip;
    }
    if (dest_row != header.height) return error.TruncatedData;
}

fn readPackedPaletteStripIndices(data: []const u8, header: Header, row_bytes: usize, out: []u8) bio.ReaderError!void {
    const bits_per_sample: usize = header.bits_per_sample[0];
    const packed_row_bits = std.math.mul(usize, header.width, bits_per_sample) catch return error.UnsupportedVariant;
    const packed_row_bytes = (packed_row_bits + 7) / 8;
    const max_value = (@as(u16, 1) << @intCast(bits_per_sample)) - 1;
    var dest_row: usize = 0;
    var strip_index: usize = 0;
    while (strip_index < header.strip_count and dest_row < header.height) : (strip_index += 1) {
        const remaining_rows = header.height - dest_row;
        const rows_this_strip = @min(@as(usize, header.rows_per_strip), remaining_rows);
        const bytes_this_strip = std.math.mul(usize, rows_this_strip, packed_row_bytes) catch return error.UnsupportedVariant;
        const src_offset = try checkedUsize(header.strip_offsets[strip_index]);
        const byte_count = try checkedUsize(header.strip_byte_counts[strip_index]);
        if (src_offset > data.len or data.len - src_offset < byte_count or byte_count < bytes_this_strip) return error.TruncatedData;
        const src = data[src_offset..][0..bytes_this_strip];

        var row: usize = 0;
        while (row < rows_this_strip) : (row += 1) {
            var x: usize = 0;
            while (x < header.width) : (x += 1) {
                out[(dest_row + row) * row_bytes + x] = packedSample(src[row * packed_row_bytes ..], x, bits_per_sample, header.fill_order, max_value);
            }
        }
        dest_row += rows_this_strip;
    }
    if (dest_row != header.height) return error.TruncatedData;
}

fn readPaletteTiledIndices(
    allocator: std.mem.Allocator,
    data: []const u8,
    header: Header,
    row_bytes: usize,
    out: []u8,
) bio.ReaderError!void {
    const tile_width: usize = header.tile_width;
    const tile_length: usize = header.tile_length;
    const tile_row_bytes = tile_width;
    const min_tile_bytes = std.math.mul(usize, tile_row_bytes, tile_length) catch return error.UnsupportedVariant;
    const tiles_across = ceilDiv(header.width, header.tile_width);
    const tiles_down = ceilDiv(header.height, header.tile_length);
    const expected_tiles = std.math.mul(usize, tiles_across, tiles_down) catch return error.UnsupportedVariant;
    if (header.tile_count < expected_tiles) return error.TruncatedData;

    var tile_y: usize = 0;
    while (tile_y < tiles_down) : (tile_y += 1) {
        var tile_x: usize = 0;
        while (tile_x < tiles_across) : (tile_x += 1) {
            const tile_index = tile_y * tiles_across + tile_x;
            const src_offset = try checkedUsize(header.tile_offsets[tile_index]);
            const compressed_bytes = try checkedUsize(header.tile_byte_counts[tile_index]);
            if (src_offset > data.len or data.len - src_offset < compressed_bytes) return error.TruncatedData;
            const tile_block = try decodeBlock(
                allocator,
                header,
                data[src_offset..][0..compressed_bytes],
                min_tile_bytes,
                .{
                    .width = tile_width,
                    .rows = tile_length,
                    .samples_per_pixel = 1,
                    .row_bytes = tile_row_bytes,
                },
            );
            defer if (tile_block.owned) allocator.free(tile_block.bytes);

            const image_x = tile_x * tile_width;
            const image_y = tile_y * tile_length;
            const copy_width = @min(tile_width, @as(usize, header.width) - image_x);
            const copy_height = @min(tile_length, @as(usize, header.height) - image_y);

            var row: usize = 0;
            while (row < copy_height) : (row += 1) {
                const src_row = row * tile_row_bytes;
                const dst_row = (image_y + row) * row_bytes + image_x;
                @memcpy(out[dst_row..][0..copy_width], tile_block.bytes[src_row..][0..copy_width]);
            }
        }
    }
}

fn paletteComponent(header: Header, component: usize, index: u8) u8 {
    const entries = header.color_map_count / 3;
    return @intCast(header.color_map[component * entries + @as(usize, index)] >> 8);
}

fn readPackedGrayscalePlane(data: []const u8, header: Header, row_bytes: usize, out: []u8) bio.ReaderError!void {
    const bits_per_sample: usize = header.bits_per_sample[0];
    const packed_row_bits = std.math.mul(usize, header.width, bits_per_sample) catch return error.UnsupportedVariant;
    const packed_row_bytes = (packed_row_bits + 7) / 8;
    const max_value = (@as(u16, 1) << @intCast(bits_per_sample)) - 1;
    var dest_row: usize = 0;
    var strip_index: usize = 0;
    while (strip_index < header.strip_count and dest_row < header.height) : (strip_index += 1) {
        const remaining_rows = header.height - dest_row;
        const rows_this_strip = @min(@as(usize, header.rows_per_strip), remaining_rows);
        const bytes_this_strip = std.math.mul(usize, rows_this_strip, packed_row_bytes) catch return error.UnsupportedVariant;
        const src_offset = try checkedUsize(header.strip_offsets[strip_index]);
        const byte_count = try checkedUsize(header.strip_byte_counts[strip_index]);
        if (src_offset > data.len or data.len - src_offset < byte_count or byte_count < bytes_this_strip) return error.TruncatedData;
        const src = data[src_offset..][0..bytes_this_strip];

        var row: usize = 0;
        while (row < rows_this_strip) : (row += 1) {
            var x: usize = 0;
            while (x < header.width) : (x += 1) {
                const value = @as(u16, packedSample(src[row * packed_row_bytes ..], x, bits_per_sample, header.fill_order, max_value));
                const black_is_zero: u8 = @intCast((value * 255) / max_value);
                out[(dest_row + row) * row_bytes + x] = if (header.photometric == 0) 255 - black_is_zero else black_is_zero;
            }
        }
        dest_row += rows_this_strip;
    }
    if (dest_row != header.height) return error.TruncatedData;
}

fn packedSample(row: []const u8, x: usize, bits_per_sample: usize, fill_order: u16, max_value: u16) u8 {
    const bit_offset = x * bits_per_sample;
    const byte = row[bit_offset / 8];
    const shift: u3 = if (fill_order == 2)
        @intCast(bit_offset % 8)
    else
        @intCast(8 - bits_per_sample - (bit_offset % 8));
    return @intCast((byte >> shift) & @as(u8, @intCast(max_value)));
}

fn readTiledPlane(allocator: std.mem.Allocator, data: []const u8, header: Header, row_bytes: usize, out: []u8) bio.ReaderError!void {
    const bytes_per_sample: usize = header.bits_per_sample[0] / 8;
    const bytes_per_pixel: usize = @as(usize, header.samples_per_pixel) * bytes_per_sample;
    const tile_width: usize = header.tile_width;
    const tile_length: usize = header.tile_length;
    const tile_row_bytes = std.math.mul(usize, tile_width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const min_tile_bytes = std.math.mul(usize, tile_row_bytes, tile_length) catch return error.UnsupportedVariant;
    const tiles_across = ceilDiv(header.width, header.tile_width);
    const tiles_down = ceilDiv(header.height, header.tile_length);
    const expected_tiles = std.math.mul(usize, tiles_across, tiles_down) catch return error.UnsupportedVariant;
    if (header.tile_count < expected_tiles) return error.TruncatedData;

    var tile_y: usize = 0;
    while (tile_y < tiles_down) : (tile_y += 1) {
        var tile_x: usize = 0;
        while (tile_x < tiles_across) : (tile_x += 1) {
            const tile_index = tile_y * tiles_across + tile_x;
            const src_offset = try checkedUsize(header.tile_offsets[tile_index]);
            const compressed_bytes = try checkedUsize(header.tile_byte_counts[tile_index]);
            if (src_offset > data.len or data.len - src_offset < compressed_bytes) return error.TruncatedData;
            const tile_block = try decodeBlock(
                allocator,
                header,
                data[src_offset..][0..compressed_bytes],
                min_tile_bytes,
                .{
                    .width = tile_width,
                    .rows = tile_length,
                    .samples_per_pixel = header.samples_per_pixel,
                    .row_bytes = tile_row_bytes,
                },
            );
            defer if (tile_block.owned) allocator.free(tile_block.bytes);

            const image_x = tile_x * tile_width;
            const image_y = tile_y * tile_length;
            const copy_width = @min(tile_width, @as(usize, header.width) - image_x);
            const copy_height = @min(tile_length, @as(usize, header.height) - image_y);
            const copy_bytes = std.math.mul(usize, copy_width, bytes_per_pixel) catch return error.UnsupportedVariant;

            var row: usize = 0;
            while (row < copy_height) : (row += 1) {
                const src_row = row * tile_row_bytes;
                const dst_row = (image_y + row) * row_bytes + image_x * bytes_per_pixel;
                @memcpy(out[dst_row..][0..copy_bytes], tile_block.bytes[src_row..][0..copy_bytes]);
            }
        }
    }
}

fn readStrippedRegion(
    allocator: std.mem.Allocator,
    data: []const u8,
    header: Header,
    metadata: bio.Metadata,
    region: bio.Region,
    region_row_bytes: usize,
    out: []u8,
) bio.ReaderError!void {
    const bytes_per_pixel = metadata.bytesPerPixel();
    const full_row_bytes = std.math.mul(usize, header.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const region_x0: usize = region.x;
    const region_y0: usize = region.y;
    const region_x1: usize = @as(usize, region.x) + region.width;
    const region_y1: usize = @as(usize, region.y) + region.height;
    const first_strip = region_y0 / header.rows_per_strip;
    const last_strip = (region_y1 - 1) / header.rows_per_strip;
    if (header.strip_count <= last_strip) return error.TruncatedData;

    var strip_index = first_strip;
    while (strip_index <= last_strip) : (strip_index += 1) {
        const strip_y0 = strip_index * @as(usize, header.rows_per_strip);
        const rows_this_strip = @min(@as(usize, header.rows_per_strip), @as(usize, header.height) - strip_y0);
        const strip_y1 = strip_y0 + rows_this_strip;
        const copy_y0 = @max(region_y0, strip_y0);
        const copy_y1 = @min(region_y1, strip_y1);
        const expected_bytes = std.math.mul(usize, rows_this_strip, full_row_bytes) catch return error.UnsupportedVariant;
        const src_offset = try checkedUsize(header.strip_offsets[strip_index]);
        const compressed_bytes = try checkedUsize(header.strip_byte_counts[strip_index]);
        if (src_offset > data.len or data.len - src_offset < compressed_bytes) return error.TruncatedData;

        const decoded = try decodeBlock(
            allocator,
            header,
            data[src_offset..][0..compressed_bytes],
            expected_bytes,
            .{
                .width = header.width,
                .rows = rows_this_strip,
                .samples_per_pixel = header.samples_per_pixel,
                .row_bytes = full_row_bytes,
            },
        );
        defer if (decoded.owned) allocator.free(decoded.bytes);

        const copy_bytes = std.math.mul(usize, region_x1 - region_x0, bytes_per_pixel) catch return error.UnsupportedVariant;
        var image_y = copy_y0;
        while (image_y < copy_y1) : (image_y += 1) {
            const src_row = (image_y - strip_y0) * full_row_bytes + region_x0 * bytes_per_pixel;
            const dst_row = (image_y - region_y0) * region_row_bytes;
            @memcpy(out[dst_row..][0..copy_bytes], decoded.bytes[src_row..][0..copy_bytes]);
        }
    }
}

fn readSeparatedStrippedRegion(
    allocator: std.mem.Allocator,
    data: []const u8,
    header: Header,
    region: bio.Region,
    region_row_bytes: usize,
    out: []u8,
) bio.ReaderError!void {
    const bytes_per_sample: usize = header.bits_per_sample[0] / 8;
    const samples: usize = header.samples_per_pixel;
    const sample_row_bytes = std.math.mul(usize, header.width, bytes_per_sample) catch return error.UnsupportedVariant;
    const strips_per_sample = ceilDiv(header.height, header.rows_per_strip);
    const expected_strips = std.math.mul(usize, strips_per_sample, samples) catch return error.UnsupportedVariant;
    if (header.strip_count < expected_strips) return error.TruncatedData;

    const region_x0: usize = region.x;
    const region_y0: usize = region.y;
    const region_x1: usize = @as(usize, region.x) + region.width;
    const region_y1: usize = @as(usize, region.y) + region.height;
    const first_strip = region_y0 / header.rows_per_strip;
    const last_strip = (region_y1 - 1) / header.rows_per_strip;

    var sample: usize = 0;
    while (sample < samples) : (sample += 1) {
        var strip_index = first_strip;
        while (strip_index <= last_strip) : (strip_index += 1) {
            const strip_y0 = strip_index * @as(usize, header.rows_per_strip);
            const rows_this_strip = @min(@as(usize, header.rows_per_strip), @as(usize, header.height) - strip_y0);
            const strip_y1 = strip_y0 + rows_this_strip;
            const copy_y0 = @max(region_y0, strip_y0);
            const copy_y1 = @min(region_y1, strip_y1);
            const expected_bytes = std.math.mul(usize, rows_this_strip, sample_row_bytes) catch return error.UnsupportedVariant;
            const global_strip = sample * strips_per_sample + strip_index;
            const src_offset = try checkedUsize(header.strip_offsets[global_strip]);
            const compressed_bytes = try checkedUsize(header.strip_byte_counts[global_strip]);
            if (src_offset > data.len or data.len - src_offset < compressed_bytes) return error.TruncatedData;

            const decoded = try decodeBlock(
                allocator,
                header,
                data[src_offset..][0..compressed_bytes],
                expected_bytes,
                .{
                    .width = header.width,
                    .rows = rows_this_strip,
                    .samples_per_pixel = 1,
                    .row_bytes = sample_row_bytes,
                },
            );
            defer if (decoded.owned) allocator.free(decoded.bytes);

            var image_y = copy_y0;
            while (image_y < copy_y1) : (image_y += 1) {
                var image_x = region_x0;
                while (image_x < region_x1) : (image_x += 1) {
                    const src = (image_y - strip_y0) * sample_row_bytes + image_x * bytes_per_sample;
                    const dst = (image_y - region_y0) * region_row_bytes + (image_x - region_x0) * samples * bytes_per_sample + sample * bytes_per_sample;
                    @memcpy(out[dst..][0..bytes_per_sample], decoded.bytes[src..][0..bytes_per_sample]);
                }
            }
        }
    }
}

fn readSeparatedTiledRegion(
    allocator: std.mem.Allocator,
    data: []const u8,
    header: Header,
    region: bio.Region,
    region_row_bytes: usize,
    out: []u8,
) bio.ReaderError!void {
    const bytes_per_sample: usize = header.bits_per_sample[0] / 8;
    const samples: usize = header.samples_per_pixel;
    const tile_width: usize = header.tile_width;
    const tile_length: usize = header.tile_length;
    const sample_tile_row_bytes = std.math.mul(usize, tile_width, bytes_per_sample) catch return error.UnsupportedVariant;
    const sample_tile_bytes = std.math.mul(usize, sample_tile_row_bytes, tile_length) catch return error.UnsupportedVariant;
    const tiles_across = ceilDiv(header.width, header.tile_width);
    const tiles_down = ceilDiv(header.height, header.tile_length);
    const tiles_per_sample = std.math.mul(usize, tiles_across, tiles_down) catch return error.UnsupportedVariant;
    const expected_tiles = std.math.mul(usize, tiles_per_sample, samples) catch return error.UnsupportedVariant;
    if (header.tile_count < expected_tiles) return error.TruncatedData;

    const region_x0: usize = region.x;
    const region_y0: usize = region.y;
    const region_x1: usize = @as(usize, region.x) + region.width;
    const region_y1: usize = @as(usize, region.y) + region.height;
    const start_tile_x = region_x0 / tile_width;
    const end_tile_x = (region_x1 - 1) / tile_width;
    const start_tile_y = region_y0 / tile_length;
    const end_tile_y = (region_y1 - 1) / tile_length;

    var sample: usize = 0;
    while (sample < samples) : (sample += 1) {
        var tile_y = start_tile_y;
        while (tile_y <= end_tile_y) : (tile_y += 1) {
            var tile_x = start_tile_x;
            while (tile_x <= end_tile_x) : (tile_x += 1) {
                const tile_index = sample * tiles_per_sample + tile_y * tiles_across + tile_x;
                const src_offset = try checkedUsize(header.tile_offsets[tile_index]);
                const compressed_bytes = try checkedUsize(header.tile_byte_counts[tile_index]);
                if (src_offset > data.len or data.len - src_offset < compressed_bytes) return error.TruncatedData;
                const tile_block = try decodeBlock(
                    allocator,
                    header,
                    data[src_offset..][0..compressed_bytes],
                    sample_tile_bytes,
                    .{
                        .width = tile_width,
                        .rows = tile_length,
                        .samples_per_pixel = 1,
                        .row_bytes = sample_tile_row_bytes,
                    },
                );
                defer if (tile_block.owned) allocator.free(tile_block.bytes);

                const tile_x0 = tile_x * tile_width;
                const tile_y0 = tile_y * tile_length;
                const copy_x0 = @max(region_x0, tile_x0);
                const copy_y0 = @max(region_y0, tile_y0);
                const copy_x1 = @min(region_x1, tile_x0 + tile_width);
                const copy_y1 = @min(region_y1, tile_y0 + tile_length);

                var image_y = copy_y0;
                while (image_y < copy_y1) : (image_y += 1) {
                    var image_x = copy_x0;
                    while (image_x < copy_x1) : (image_x += 1) {
                        const src = (image_y - tile_y0) * sample_tile_row_bytes + (image_x - tile_x0) * bytes_per_sample;
                        const dst = (image_y - region_y0) * region_row_bytes + (image_x - region_x0) * samples * bytes_per_sample + sample * bytes_per_sample;
                        @memcpy(out[dst..][0..bytes_per_sample], tile_block.bytes[src..][0..bytes_per_sample]);
                    }
                }
            }
        }
    }
}

fn readTiledRegion(
    allocator: std.mem.Allocator,
    data: []const u8,
    header: Header,
    metadata: bio.Metadata,
    region: bio.Region,
    region_row_bytes: usize,
    out: []u8,
) bio.ReaderError!void {
    const bytes_per_pixel = metadata.bytesPerPixel();
    const tile_width: usize = header.tile_width;
    const tile_length: usize = header.tile_length;
    const tile_row_bytes = std.math.mul(usize, tile_width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const min_tile_bytes = std.math.mul(usize, tile_row_bytes, tile_length) catch return error.UnsupportedVariant;
    const tiles_across = ceilDiv(header.width, header.tile_width);
    const tiles_down = ceilDiv(header.height, header.tile_length);
    const expected_tiles = std.math.mul(usize, tiles_across, tiles_down) catch return error.UnsupportedVariant;
    if (header.tile_count < expected_tiles) return error.TruncatedData;

    const region_x0: usize = region.x;
    const region_y0: usize = region.y;
    const region_x1: usize = @as(usize, region.x) + region.width;
    const region_y1: usize = @as(usize, region.y) + region.height;
    const start_tile_x = region_x0 / tile_width;
    const end_tile_x = (region_x1 - 1) / tile_width;
    const start_tile_y = region_y0 / tile_length;
    const end_tile_y = (region_y1 - 1) / tile_length;

    var tile_y = start_tile_y;
    while (tile_y <= end_tile_y) : (tile_y += 1) {
        var tile_x = start_tile_x;
        while (tile_x <= end_tile_x) : (tile_x += 1) {
            const tile_index = tile_y * tiles_across + tile_x;
            const src_offset = try checkedUsize(header.tile_offsets[tile_index]);
            const compressed_bytes = try checkedUsize(header.tile_byte_counts[tile_index]);
            if (src_offset > data.len or data.len - src_offset < compressed_bytes) return error.TruncatedData;
            const tile_block = try decodeBlock(
                allocator,
                header,
                data[src_offset..][0..compressed_bytes],
                min_tile_bytes,
                .{
                    .width = tile_width,
                    .rows = tile_length,
                    .samples_per_pixel = header.samples_per_pixel,
                    .row_bytes = tile_row_bytes,
                },
            );
            defer if (tile_block.owned) allocator.free(tile_block.bytes);

            const tile_x0 = tile_x * tile_width;
            const tile_y0 = tile_y * tile_length;
            const copy_x0 = @max(region_x0, tile_x0);
            const copy_y0 = @max(region_y0, tile_y0);
            const copy_x1 = @min(region_x1, tile_x0 + tile_width);
            const copy_y1 = @min(region_y1, tile_y0 + tile_length);
            const copy_bytes = std.math.mul(usize, copy_x1 - copy_x0, bytes_per_pixel) catch return error.UnsupportedVariant;

            var image_y = copy_y0;
            while (image_y < copy_y1) : (image_y += 1) {
                const src_row = (image_y - tile_y0) * tile_row_bytes + (copy_x0 - tile_x0) * bytes_per_pixel;
                const dst_row = (image_y - region_y0) * region_row_bytes + (copy_x0 - region_x0) * bytes_per_pixel;
                @memcpy(out[dst_row..][0..copy_bytes], tile_block.bytes[src_row..][0..copy_bytes]);
            }
        }
    }
}

const DecodedBlock = struct {
    bytes: []const u8,
    owned: bool,
};

const PredictorBlock = struct {
    width: usize,
    rows: usize,
    samples_per_pixel: usize,
    row_bytes: usize,
};

fn copyDecodedBlock(
    allocator: std.mem.Allocator,
    header: Header,
    src: []const u8,
    dst: []u8,
    block: PredictorBlock,
) bio.ReaderError!void {
    const decoded = try decodeBlock(allocator, header, src, dst.len, block);
    defer if (decoded.owned) allocator.free(decoded.bytes);
    @memcpy(dst, decoded.bytes);
}

fn decodeBlock(
    allocator: std.mem.Allocator,
    header: Header,
    src: []const u8,
    expected_len: usize,
    block: PredictorBlock,
) bio.ReaderError!DecodedBlock {
    const bytes_per_sample: usize = header.bits_per_sample[0] / 8;

    return switch (header.compression) {
        1 => {
            if (src.len < expected_len) return error.TruncatedData;
            if (needsDecodedBlockCopy(header)) {
                const out = try allocator.alloc(u8, expected_len);
                errdefer allocator.free(out);
                @memcpy(out, src[0..expected_len]);
                try postProcessDecodedBlock(header, bytes_per_sample, out, block);
                return .{ .bytes = out, .owned = true };
            }
            return .{ .bytes = src[0..expected_len], .owned = false };
        },
        32773 => {
            const out = try allocator.alloc(u8, expected_len);
            errdefer allocator.free(out);
            try decodePackBits(src, out);
            try postProcessDecodedBlock(header, bytes_per_sample, out, block);
            return .{ .bytes = out, .owned = true };
        },
        5 => {
            const out = try allocator.alloc(u8, expected_len);
            errdefer allocator.free(out);
            try decodeLzw(src, out);
            try postProcessDecodedBlock(header, bytes_per_sample, out, block);
            return .{ .bytes = out, .owned = true };
        },
        8, 32946 => {
            const out = try allocator.alloc(u8, expected_len);
            errdefer allocator.free(out);
            try decodeDeflate(src, out, if (header.compression == 8) .zlib else .raw);
            try postProcessDecodedBlock(header, bytes_per_sample, out, block);
            return .{ .bytes = out, .owned = true };
        },
        else => error.UnsupportedVariant,
    };
}

fn needsDecodedBlockCopy(header: Header) bool {
    return header.predictor == 2 or header.photometric == 0;
}

fn postProcessDecodedBlock(
    header: Header,
    bytes_per_sample: usize,
    bytes: []u8,
    block: PredictorBlock,
) bio.ReaderError!void {
    if (header.predictor == 2) try applyHorizontalPredictor(header.order, bytes_per_sample, bytes, block);
    if (header.photometric == 0) try applyWhiteIsZero(header.order, bytes_per_sample, bytes, block);
}

fn applyHorizontalPredictor(
    order: ByteOrder,
    bytes_per_sample: usize,
    bytes: []u8,
    block: PredictorBlock,
) bio.ReaderError!void {
    if (block.samples_per_pixel == 0 or bytes_per_sample == 0) return error.UnsupportedVariant;
    const pixel_bytes = std.math.mul(usize, block.samples_per_pixel, bytes_per_sample) catch return error.UnsupportedVariant;
    const used_row_bytes = std.math.mul(usize, block.width, pixel_bytes) catch return error.UnsupportedVariant;
    if (block.row_bytes < used_row_bytes) return error.InvalidFormat;
    const required = std.math.mul(usize, block.rows, block.row_bytes) catch return error.UnsupportedVariant;
    if (bytes.len < required) return error.TruncatedData;

    var row: usize = 0;
    while (row < block.rows) : (row += 1) {
        const row_base = row * block.row_bytes;
        if (bytes_per_sample == 1) {
            var i = row_base + pixel_bytes;
            const row_end = row_base + used_row_bytes;
            while (i < row_end) : (i += 1) {
                bytes[i] +%= bytes[i - pixel_bytes];
            }
        } else if (bytes_per_sample == 2) {
            var x: usize = 1;
            while (x < block.width) : (x += 1) {
                var sample: usize = 0;
                while (sample < block.samples_per_pixel) : (sample += 1) {
                    const pos = row_base + x * pixel_bytes + sample * bytes_per_sample;
                    const previous = readU16(order, bytes[pos - pixel_bytes ..][0..2]);
                    const encoded = readU16(order, bytes[pos..][0..2]);
                    std.mem.writeInt(u16, bytes[pos..][0..2], encoded +% previous, order.endian());
                }
            }
        } else {
            return error.UnsupportedVariant;
        }
    }
}

fn applyWhiteIsZero(
    order: ByteOrder,
    bytes_per_sample: usize,
    bytes: []u8,
    block: PredictorBlock,
) bio.ReaderError!void {
    if (block.samples_per_pixel != 1) return error.UnsupportedVariant;
    const used_row_bytes = std.math.mul(usize, block.width, bytes_per_sample) catch return error.UnsupportedVariant;
    if (block.row_bytes < used_row_bytes) return error.InvalidFormat;
    const required = std.math.mul(usize, block.rows, block.row_bytes) catch return error.UnsupportedVariant;
    if (bytes.len < required) return error.TruncatedData;

    var row: usize = 0;
    while (row < block.rows) : (row += 1) {
        const row_base = row * block.row_bytes;
        if (bytes_per_sample == 1) {
            var i = row_base;
            const row_end = row_base + used_row_bytes;
            while (i < row_end) : (i += 1) {
                bytes[i] = 255 - bytes[i];
            }
        } else if (bytes_per_sample == 2) {
            var x: usize = 0;
            while (x < block.width) : (x += 1) {
                const pos = row_base + x * bytes_per_sample;
                const value = readU16(order, bytes[pos..][0..2]);
                std.mem.writeInt(u16, bytes[pos..][0..2], 0xffff - value, order.endian());
            }
        } else {
            return error.UnsupportedVariant;
        }
    }
}

fn decodeDeflate(src: []const u8, dst: []u8, container: std.compress.flate.Container) bio.ReaderError!void {
    var input: std.Io.Reader = .fixed(src);
    var output: std.Io.Writer = .fixed(dst);
    var decompress: std.compress.flate.Decompress = .init(&input, container, &.{});
    const written = decompress.reader.streamRemaining(&output) catch return error.TruncatedData;
    if (written != dst.len) return error.TruncatedData;
}

pub fn decodeLzw(src: []const u8, dst: []u8) bio.ReaderError!void {
    const clear_code: u16 = 256;
    const end_code: u16 = 257;
    const first_code: u16 = 258;
    const max_codes: usize = 4096;

    var prefixes: [max_codes]u16 = undefined;
    var suffixes: [max_codes]u8 = undefined;
    var reader = MsbBitReader{ .bytes = src };
    var next_code: u16 = first_code;
    var code_size: u4 = 9;
    var previous_code: ?u16 = null;
    var previous_first: u8 = 0;
    var dst_i: usize = 0;

    while (true) {
        const code = reader.read(code_size) orelse return error.TruncatedData;
        if (code == clear_code) {
            next_code = first_code;
            code_size = 9;
            previous_code = null;
            continue;
        }
        if (code == end_code) break;

        if (previous_code == null) {
            if (code >= clear_code) return error.InvalidFormat;
            const value: u8 = @intCast(code);
            if (dst_i >= dst.len) return error.TruncatedData;
            dst[dst_i] = value;
            dst_i += 1;
            previous_code = code;
            previous_first = value;
            continue;
        }

        const first = if (code < next_code) blk: {
            break :blk try writeLzwString(code, &prefixes, &suffixes, dst, &dst_i);
        } else if (code == next_code) blk: {
            const old_code = previous_code.?;
            const old_first = previous_first;
            _ = try writeLzwString(old_code, &prefixes, &suffixes, dst, &dst_i);
            if (dst_i >= dst.len) return error.TruncatedData;
            dst[dst_i] = old_first;
            dst_i += 1;
            break :blk old_first;
        } else return error.InvalidFormat;

        if (next_code < max_codes) {
            prefixes[next_code] = previous_code.?;
            suffixes[next_code] = first;
            next_code += 1;
            if (next_code == ((@as(u16, 1) << code_size) - 1) and code_size < 12) code_size += 1;
        }
        previous_code = code;
        previous_first = first;
    }

    if (dst_i != dst.len) return error.TruncatedData;
}

fn writeLzwString(
    code: u16,
    prefixes: *const [4096]u16,
    suffixes: *const [4096]u8,
    dst: []u8,
    dst_i: *usize,
) bio.ReaderError!u8 {
    var stack: [4096]u8 = undefined;
    var stack_len: usize = 0;
    var current = code;
    while (current >= 258) {
        if (current >= 4096 or stack_len == stack.len) return error.InvalidFormat;
        stack[stack_len] = suffixes[current];
        stack_len += 1;
        current = prefixes[current];
    }
    if (current >= 256 or stack_len == stack.len) return error.InvalidFormat;
    stack[stack_len] = @intCast(current);
    stack_len += 1;

    const first = stack[stack_len - 1];
    while (stack_len > 0) {
        stack_len -= 1;
        if (dst_i.* >= dst.len) return error.TruncatedData;
        dst[dst_i.*] = stack[stack_len];
        dst_i.* += 1;
    }
    return first;
}

const MsbBitReader = struct {
    bytes: []const u8,
    bit_index: usize = 0,

    fn read(self: *MsbBitReader, width: u4) ?u16 {
        const end = self.bit_index + width;
        if (end > self.bytes.len * 8) return null;
        var value: u16 = 0;
        while (self.bit_index < end) : (self.bit_index += 1) {
            const byte = self.bytes[self.bit_index / 8];
            const shift: u3 = @intCast(7 - (self.bit_index % 8));
            value = (value << 1) | @as(u16, @intCast((byte >> shift) & 1));
        }
        return value;
    }
};

fn decodePackBits(src: []const u8, dst: []u8) bio.ReaderError!void {
    var src_i: usize = 0;
    var dst_i: usize = 0;
    while (src_i < src.len and dst_i < dst.len) {
        const header: i8 = @bitCast(src[src_i]);
        src_i += 1;
        if (header >= 0) {
            const count: usize = @as(usize, @intCast(header)) + 1;
            if (src.len - src_i < count or dst.len - dst_i < count) return error.TruncatedData;
            @memcpy(dst[dst_i..][0..count], src[src_i..][0..count]);
            src_i += count;
            dst_i += count;
        } else if (header != -128) {
            const count: usize = @as(usize, @intCast(-header)) + 1;
            if (src_i >= src.len or dst.len - dst_i < count) return error.TruncatedData;
            @memset(dst[dst_i..][0..count], src[src_i]);
            src_i += 1;
            dst_i += count;
        }
    }
    if (dst_i != dst.len) return error.TruncatedData;
}

fn ceilDiv(numerator: u32, denominator: u32) usize {
    return (@as(usize, numerator) + denominator - 1) / denominator;
}

fn parseEntry(info: TiffInfo, data: []const u8, offset: usize) Entry {
    if (info.big) {
        return .{
            .offset = offset,
            .tag = readU16(info.order, data[offset..][0..2]),
            .field_type = readU16(info.order, data[offset + 2 ..][0..2]),
            .count = readU64(info.order, data[offset + 4 ..][0..8]),
            .value_offset = readU64(info.order, data[offset + 12 ..][0..8]),
            .value_field_offset = offset + 12,
            .inline_capacity = 8,
        };
    }
    return .{
        .offset = offset,
        .tag = readU16(info.order, data[offset..][0..2]),
        .field_type = readU16(info.order, data[offset + 2 ..][0..2]),
        .count = readU32(info.order, data[offset + 4 ..][0..4]),
        .value_offset = readU32(info.order, data[offset + 8 ..][0..4]),
        .value_field_offset = offset + 8,
        .inline_capacity = 4,
    };
}

fn copyEntryValues(order: ByteOrder, data: []const u8, entry: Entry, dest: []u64) bio.ReaderError!usize {
    if (entry.count > dest.len) return error.UnsupportedVariant;
    var i: usize = 0;
    while (i < entry.count) : (i += 1) {
        dest[i] = try entryValueU64(order, data, entry, i);
    }
    return try checkedUsize(entry.count);
}

fn entryValueU32(order: ByteOrder, data: []const u8, entry: Entry, index: usize) bio.ReaderError!u32 {
    const value = try entryValueU64(order, data, entry, index);
    return checkedU32(value);
}

fn entryValueU64(order: ByteOrder, data: []const u8, entry: Entry, index: usize) bio.ReaderError!u64 {
    if (index >= entry.count) return error.InvalidFormat;
    const type_size = tiffTypeSize(entry.field_type) orelse return error.UnsupportedVariant;
    const total_size = std.math.mul(usize, type_size, entry.count) catch return error.UnsupportedVariant;
    const value_base = if (total_size <= entry.inline_capacity) entry.value_field_offset else try checkedUsize(entry.value_offset);
    const index_offset = std.math.mul(usize, type_size, index) catch return error.UnsupportedVariant;
    const value_offset = std.math.add(usize, value_base, index_offset) catch return error.UnsupportedVariant;
    if (value_offset > data.len or data.len - value_offset < type_size) return error.TruncatedData;
    return switch (entry.field_type) {
        1 => data[value_offset],
        3 => readU16(order, data[value_offset..][0..2]),
        4 => readU32(order, data[value_offset..][0..4]),
        16 => readU64(order, data[value_offset..][0..8]),
        else => error.UnsupportedVariant,
    };
}

fn entryAscii(data: []const u8, entry: Entry) bio.ReaderError![]const u8 {
    if (entry.field_type != 2) return error.UnsupportedVariant;
    const len = try checkedUsize(entry.count);
    const total_size = len;
    const value_base = if (total_size <= entry.inline_capacity) entry.value_field_offset else try checkedUsize(entry.value_offset);
    if (value_base > data.len or data.len - value_base < len) return error.TruncatedData;
    var text = data[value_base..][0..len];
    while (text.len > 0 and text[text.len - 1] == 0) text = text[0 .. text.len - 1];
    return text;
}

fn entryBytes(data: []const u8, entry: Entry) bio.ReaderError![]const u8 {
    if (entry.field_type != 1 and entry.field_type != 7) return error.UnsupportedVariant;
    const len = try checkedUsize(entry.count);
    const value_base = if (len <= entry.inline_capacity) entry.value_field_offset else try checkedUsize(entry.value_offset);
    if (value_base > data.len or data.len - value_base < len) return error.TruncatedData;
    return data[value_base..][0..len];
}

fn parseOmePixels(xml: []const u8) ?OmePixels {
    const pixels_start = std.mem.indexOf(u8, xml, "<Pixels") orelse return null;
    const rest = xml[pixels_start..];
    const pixels_end = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
    const tag = rest[0..pixels_end];
    return .{
        .size_z = parseU16Attr(tag, "SizeZ"),
        .size_c = parseU16Attr(tag, "SizeC"),
        .size_t = parseU16Attr(tag, "SizeT"),
        .dimension_order = parseStringAttr(tag, "DimensionOrder"),
    };
}

fn parseImageJComment(description: []const u8) ?ImageJComment {
    if (!std.mem.startsWith(u8, description, "ImageJ=")) return null;
    var parsed = ImageJComment{};
    var saw_dimension = false;
    var pos: usize = 0;
    while (pos <= description.len) {
        const line_end = std.mem.indexOfScalarPos(u8, description, pos, '\n') orelse description.len;
        const line = std.mem.trim(u8, description[pos..line_end], " \t\r\n");
        if (std.mem.startsWith(u8, line, "channels=")) {
            if (parseImageJU16(line["channels=".len..])) |value| {
                parsed.size_c = value;
                saw_dimension = true;
            }
        } else if (std.mem.startsWith(u8, line, "slices=")) {
            if (parseImageJU16(line["slices=".len..])) |value| {
                parsed.size_z = value;
                saw_dimension = true;
            }
        } else if (std.mem.startsWith(u8, line, "frames=")) {
            if (parseImageJU16(line["frames=".len..])) |value| {
                parsed.size_t = value;
                saw_dimension = true;
            }
        } else if (std.mem.startsWith(u8, line, "images=")) {
            if (parseImageJU32(line["images=".len..])) |value| {
                parsed.image_count = value;
                saw_dimension = true;
            }
        }
        if (line_end == description.len) break;
        pos = line_end + 1;
    }
    return if (saw_dimension) parsed else null;
}

fn parseImageJU16(value: []const u8) ?u16 {
    const parsed = parseImageJU32(value) orelse return null;
    if (parsed == 0 or parsed > std.math.maxInt(u16)) return null;
    return @intCast(parsed);
}

fn parseImageJU32(value: []const u8) ?u32 {
    return std.fmt.parseUnsigned(u32, std.mem.trim(u8, value, " \t\r\n"), 10) catch null;
}

fn parseU16Attr(tag: []const u8, name: []const u8) ?u16 {
    const value = parseStringAttr(tag, name) orelse return null;
    const parsed = std.fmt.parseInt(u16, value, 10) catch return null;
    if (parsed == 0) return null;
    return parsed;
}

fn parseStringAttr(tag: []const u8, name: []const u8) ?[]const u8 {
    const attr_start = std.mem.indexOf(u8, tag, name) orelse return null;
    var i = attr_start + name.len;
    while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
    if (i >= tag.len or tag[i] != '=') return null;
    i += 1;
    while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
    if (i >= tag.len or (tag[i] != '"' and tag[i] != '\'')) return null;
    const quote = tag[i];
    i += 1;
    const value_start = i;
    while (i < tag.len and tag[i] != quote) : (i += 1) {}
    if (i >= tag.len) return null;
    return tag[value_start..i];
}

fn tiffTypeSize(field_type: u16) ?usize {
    return switch (field_type) {
        1, 2, 7 => 1,
        3 => 2,
        4 => 4,
        16 => 8,
        else => null,
    };
}

fn readU16(order: ByteOrder, bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], order.endian());
}

fn readU32(order: ByteOrder, bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], order.endian());
}

fn readU64(order: ByteOrder, bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], order.endian());
}

fn checkedU32(value: u64) bio.ReaderError!u32 {
    if (value > std.math.maxInt(u32)) return error.UnsupportedVariant;
    return @intCast(value);
}

fn checkedUsize(value: u64) bio.ReaderError!usize {
    if (value > std.math.maxInt(usize)) return error.UnsupportedVariant;
    return @intCast(value);
}

test "reads baseline little-endian grayscale tiff" {
    const data = [_]u8{
        'I', 'I', 42, 0, 8, 0, 0,   0,
        9,   0,   0,  1, 4, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 1,   1,
        4,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   2,  1, 3, 0, 1,   0,
        0,   0,   8,  0, 0, 0, 3,   1,
        3,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   6,  1, 3, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 17,  1,
        4,   0,   1,  0, 0, 0, 122, 0,
        0,   0,   21, 1, 3, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 22,  1,
        4,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   23, 1, 4, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 0,   0,
        0,   0,   77,
    };
    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(u32, 1), plane.metadata.width);
    try std.testing.expectEqual(@as(u16, 1), plane.metadata.size_c);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}

test "reads grayscale tiff with default rows per strip" {
    const data = [_]u8{
        'I', 'I', 42, 0, 8, 0, 0,   0,
        8,   0,   0,  1, 4, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 1,   1,
        4,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   2,  1, 3, 0, 1,   0,
        0,   0,   8,  0, 0, 0, 3,   1,
        3,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   6,  1, 3, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 17,  1,
        4,   0,   1,  0, 0, 0, 110, 0,
        0,   0,   21, 1, 3, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 23,  1,
        4,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   0,  0, 0, 0, 88,
    };
    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{88}, plane.data);
}

test "reads grayscale tiff with default compression" {
    const data = [_]u8{
        'I', 'I', 42,  0, 8, 0, 0,  0,
        8,   0,   0,   1, 4, 0, 1,  0,
        0,   0,   1,   0, 0, 0, 1,  1,
        4,   0,   1,   0, 0, 0, 1,  0,
        0,   0,   2,   1, 3, 0, 1,  0,
        0,   0,   8,   0, 0, 0, 6,  1,
        3,   0,   1,   0, 0, 0, 1,  0,
        0,   0,   17,  1, 4, 0, 1,  0,
        0,   0,   110, 0, 0, 0, 21, 1,
        3,   0,   1,   0, 0, 0, 1,  0,
        0,   0,   22,  1, 4, 0, 1,  0,
        0,   0,   1,   0, 0, 0, 23, 1,
        4,   0,   1,   0, 0, 0, 1,  0,
        0,   0,   0,   0, 0, 0, 99,
    };
    const plane = try readPlane(std.testing.allocator, &data);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{99}, plane.data);
}

test "reads second plane from multi-ifd grayscale tiff" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const second_ifd_offset = 8 + ifd_size;
    const first_pixel_offset = second_ifd_offset + ifd_size;
    const second_pixel_offset = first_pixel_offset + 1;

    try appendTestIfd(&data, first_pixel_offset, second_ifd_offset);
    try appendTestIfd(&data, second_pixel_offset, 0);
    try appendU8s(&data, &.{ 11, 22 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const first = try readPlaneIndex(std.testing.allocator, data.items, 0);
    defer std.testing.allocator.free(first.data);
    try std.testing.expectEqualSlices(u8, &.{11}, first.data);

    const second = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqualSlices(u8, &.{22}, second.data);

    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads uncompressed tiled grayscale tiff" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const tile_offsets_array = 8 + ifd_size;
    const tile_counts_array = tile_offsets_array + 4 * 4;
    const tile_pixels = tile_counts_array + 4 * 4;

    try appendTiledTestIfd(&data, tile_offsets_array, tile_counts_array);
    try appendU32Le(&data, tile_pixels + 0);
    try appendU32Le(&data, tile_pixels + 2);
    try appendU32Le(&data, tile_pixels + 4);
    try appendU32Le(&data, tile_pixels + 6);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 2);
    try appendU8s(&data, &.{ 1, 2, 3, 99, 4, 5, 6, 99 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, plane.data);
}

test "reads region from uncompressed tiled grayscale tiff" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const tile_offsets_array = 8 + ifd_size;
    const tile_counts_array = tile_offsets_array + 4 * 4;
    const tile_pixels = tile_counts_array + 4 * 4;

    try appendTiledTestIfd(&data, tile_offsets_array, tile_counts_array);
    try appendU32Le(&data, tile_pixels + 0);
    try appendU32Le(&data, tile_pixels + 2);
    try appendU32Le(&data, tile_pixels + 4);
    try appendU32Le(&data, tile_pixels + 6);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 2);
    try appendU8s(&data, &.{ 1, 2, 3, 99, 4, 5, 6, 99 });

    const plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{ .x = 1, .y = 0, .width = 2, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 5, 6 }, plane.data);
}

test "reads region from stripped grayscale tiff without decoding non-intersecting strips" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const strip_offsets_array = 8 + ifd_size;
    const strip_counts_array = strip_offsets_array + 3 * 4;
    const pixel_offset = strip_counts_array + 3 * 4;

    try appendMultiStripGrayIfd(&data, strip_offsets_array, strip_counts_array);
    try appendU32Le(&data, 9999);
    try appendU32Le(&data, pixel_offset + 0);
    try appendU32Le(&data, pixel_offset + 4);
    try appendU32Le(&data, 4);
    try appendU32Le(&data, 4);
    try appendU32Le(&data, 4);
    try appendU8s(&data, &.{ 5, 6, 7, 8, 9, 10, 11, 12 });

    const plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{ .x = 1, .y = 1, .width = 2, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 6, 7 }, plane.data);
}

test "decodes packbits literal repeat and noop" {
    var out = [_]u8{0} ** 6;
    try decodePackBits(&.{ 1, 10, 11, 254, 7, 128, 0, 12 }, &out);
    try std.testing.expectEqualSlices(u8, &.{ 10, 11, 7, 7, 7, 12 }, &out);
}

test "decodes raw and zlib deflate blocks" {
    var raw_out = [_]u8{0} ** 3;
    try decodeDeflate(&.{ 0x01, 0x03, 0x00, 0xfc, 0xff, 1, 2, 3 }, &raw_out, .raw);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &raw_out);

    var zlib_out = [_]u8{0} ** 3;
    try decodeDeflate(&.{ 0x78, 0x9c, 0x01, 0x03, 0x00, 0xfc, 0xff, 1, 2, 3, 0x00, 0x0d, 0x00, 0x07 }, &zlib_out, .zlib);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &zlib_out);
}

test "reverses horizontal predictor for rgb and 16-bit rows" {
    var rgb = [_]u8{ 10, 20, 30, 1, 2, 3, 4, 5, 6 };
    try applyHorizontalPredictor(.little, 1, &rgb, .{
        .width = 3,
        .rows = 1,
        .samples_per_pixel = 3,
        .row_bytes = rgb.len,
    });
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 11, 22, 33, 15, 27, 39 }, &rgb);

    var uint16 = [_]u8{ 0x34, 0x12, 0x02, 0x00 };
    try applyHorizontalPredictor(.little, 2, &uint16, .{
        .width = 2,
        .rows = 1,
        .samples_per_pixel = 1,
        .row_bytes = uint16.len,
    });
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0x36, 0x12 }, &uint16);
}

test "applies white-is-zero inversion for 8 and 16-bit grayscale rows" {
    var uint8 = [_]u8{ 0, 127, 255 };
    try applyWhiteIsZero(.little, 1, &uint8, .{
        .width = 3,
        .rows = 1,
        .samples_per_pixel = 1,
        .row_bytes = uint8.len,
    });
    try std.testing.expectEqualSlices(u8, &.{ 255, 128, 0 }, &uint8);

    var uint16 = [_]u8{ 0x00, 0x00, 0x34, 0x12 };
    try applyWhiteIsZero(.little, 2, &uint16, .{
        .width = 2,
        .rows = 1,
        .samples_per_pixel = 1,
        .row_bytes = uint16.len,
    });
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xcb, 0xed }, &uint16);
}

test "decodes lzw literal and dictionary codes" {
    var literal_out = [_]u8{0} ** 3;
    try decodeLzw(&.{ 128, 0, 64, 64, 56, 8 }, &literal_out);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &literal_out);

    var dictionary_out = [_]u8{0} ** 5;
    try decodeLzw(&.{ 128, 16, 72, 80, 34, 12, 4 }, &dictionary_out);
    try std.testing.expectEqualSlices(u8, "ABABA", &dictionary_out);
}

test "decodes lzw kwkwk special case" {
    var out = [_]u8{0} ** 3;
    try decodeLzw(&.{ 128, 16, 96, 80, 16 }, &out);
    try std.testing.expectEqualSlices(u8, "AAA", &out);
}

test "reads packbits compressed grayscale tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const pixel_offset = 8 + ifd_size;
    const compressed = [_]u8{ 1, 1, 2, 254, 3 };

    try appendTestIfdWithCompression(&data, pixel_offset, 0, 32773, compressed.len);
    try appendU8s(&data, &compressed);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 3, 3 }, plane.data);
}

test "reads deflate compressed grayscale tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const pixel_offset = 8 + ifd_size;
    const compressed = [_]u8{ 0x01, 0x03, 0x00, 0xfc, 0xff, 1, 2, 3 };

    try appendDeflateStripIfd(&data, pixel_offset, 32946, compressed.len);
    try appendU8s(&data, &compressed);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, plane.data);
}

test "reads deflate compressed grayscale tiff strip with horizontal predictor" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const pixel_offset = 8 + ifd_size;
    const compressed = [_]u8{ 0x01, 0x03, 0x00, 0xfc, 0xff, 10, 5, 7 };

    try appendDeflatePredictorStripIfd(&data, pixel_offset, compressed.len);
    try appendU8s(&data, &compressed);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 10, 15, 22 }, plane.data);
}

test "reads lzw compressed grayscale tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const pixel_offset = 8 + ifd_size;
    const compressed = [_]u8{ 128, 0, 64, 64, 56, 8 };

    try appendDeflateStripIfd(&data, pixel_offset, 5, compressed.len);
    try appendU8s(&data, &compressed);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, plane.data);
}

test "reads zlib deflate compressed grayscale tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const pixel_offset = 8 + ifd_size;
    const compressed = [_]u8{ 0x78, 0x9c, 0x01, 0x03, 0x00, 0xfc, 0xff, 1, 2, 3, 0x00, 0x0d, 0x00, 0x07 };

    try appendDeflateStripIfd(&data, pixel_offset, 8, compressed.len);
    try appendU8s(&data, &compressed);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, plane.data);
}

test "reads jpeg compressed rgb tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const bits_offset = ifd_end;
    const pixel_offset = bits_offset + 6;

    try appendU16Le(&data, entry_count);
    try appendEntry(&data, 256, 4, 1, 1);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 3, bits_offset);
    try appendEntry(&data, 259, 3, 1, 7);
    try appendEntry(&data, 262, 3, 1, 6);
    try appendEntry(&data, 273, 4, 1, pixel_offset);
    try appendEntry(&data, 277, 3, 1, 3);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 1, jpeg.baseline_red_jpeg.len);
    try appendEntry(&data, 284, 3, 1, 1);
    try appendU32Le(&data, 0);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try data.appendSlice(std.testing.allocator, &jpeg.baseline_red_jpeg);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(usize, 3), plane.data.len);
    try std.testing.expect(plane.data[0] > 200);
}

test "reads jpeg compressed rgb tiff tiles region" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const entry_count = 11;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const bits_offset = ifd_end;
    const tile_offsets_array = bits_offset + 6;
    const tile_counts_array = tile_offsets_array + 2 * 4;
    const first_tile_offset = tile_counts_array + 2 * 4;
    const second_tile_offset = first_tile_offset + jpeg.baseline_red_jpeg.len;

    try appendU16Le(&data, entry_count);
    try appendEntry(&data, 256, 4, 1, 2);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 3, bits_offset);
    try appendEntry(&data, 259, 3, 1, 7);
    try appendEntry(&data, 262, 3, 1, 2);
    try appendEntry(&data, 277, 3, 1, 3);
    try appendEntry(&data, 284, 3, 1, 1);
    try appendEntry(&data, 322, 4, 1, 1);
    try appendEntry(&data, 323, 4, 1, 1);
    try appendEntry(&data, 324, 4, 2, tile_offsets_array);
    try appendEntry(&data, 325, 4, 2, tile_counts_array);
    try appendU32Le(&data, 0);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU32Le(&data, first_tile_offset);
    try appendU32Le(&data, second_tile_offset);
    try appendU32Le(&data, jpeg.baseline_red_jpeg.len);
    try appendU32Le(&data, jpeg.baseline_red_jpeg.len);
    try data.appendSlice(std.testing.allocator, &jpeg.baseline_red_jpeg);
    try data.appendSlice(std.testing.allocator, &jpeg.baseline_red_jpeg);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const region = try readRegionIndex(std.testing.allocator, data.items, 0, .{ .x = 1, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(region.data);
    try std.testing.expectEqual(@as(usize, 3), region.data.len);
    try std.testing.expect(region.data[0] > 200);
}

test "reads packbits compressed grayscale tiff tiles" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const tile_offsets_array = 8 + ifd_size;
    const tile_counts_array = tile_offsets_array + 4 * 4;
    const tile_pixels = tile_counts_array + 4 * 4;

    try appendTiledTestIfdWithCompression(&data, tile_offsets_array, tile_counts_array, 32773);
    try appendU32Le(&data, tile_pixels + 0);
    try appendU32Le(&data, tile_pixels + 3);
    try appendU32Le(&data, tile_pixels + 6);
    try appendU32Le(&data, tile_pixels + 9);
    try appendU32Le(&data, 3);
    try appendU32Le(&data, 3);
    try appendU32Le(&data, 3);
    try appendU32Le(&data, 3);
    try appendU8s(&data, &.{ 1, 1, 2, 1, 3, 99, 1, 4, 5, 1, 6, 99 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, plane.data);
}

test "reads white-is-zero grayscale tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const pixel_offset = 8 + ifd_size;

    try appendWhiteIsZero8StripIfd(&data, pixel_offset);
    try appendU8s(&data, &.{ 0, 127, 255 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.uint8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 255, 128, 0 }, plane.data);
}

test "reads 1-bit black-is-zero grayscale tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const pixel_offset = 8 + ifd_size;

    try appendBilevelStripIfd(&data, pixel_offset, 1);
    try appendU8s(&data, &.{0xb0});

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expectEqual(@as(usize, 1), metadata.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 255, 255, 0 }, plane.data);
}

test "reads bilevel tiff with default bits per sample" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 8 * 12 + 4;
    const pixel_offset = 8 + ifd_size;

    try appendU16Le(&data, 8);
    try appendEntry(&data, 256, 4, 1, 5);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 259, 3, 1, 1);
    try appendEntry(&data, 262, 3, 1, 1);
    try appendEntry(&data, 273, 4, 1, pixel_offset);
    try appendEntry(&data, 277, 3, 1, 1);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 1, 1);
    try appendU32Le(&data, 0);
    try appendU8s(&data, &.{0xb0});

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 255, 255, 0 }, plane.data);
}

test "reads 1-bit white-is-zero grayscale tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const pixel_offset = 8 + ifd_size;

    try appendBilevelStripIfd(&data, pixel_offset, 0);
    try appendU8s(&data, &.{0xb0});

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 0, 255 }, plane.data);
}

test "reads 1-bit grayscale tiff strip with lsb fill order" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const pixel_offset = 8 + ifd_size;

    try appendPackedGrayFillOrderStripIfd(&data, pixel_offset, 1, 1, 5, 1, 2);
    try appendU8s(&data, &.{0x15});

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 255, 0, 255 }, plane.data);
}

test "reads 2-bit grayscale tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const pixel_offset = 8 + ifd_size;

    try appendPackedGrayStripIfd(&data, pixel_offset, 2, 1, 4, 1);
    try appendU8s(&data, &.{0x1b});

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 85, 170, 255 }, plane.data);
}

test "reads 4-bit white-is-zero grayscale tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const pixel_offset = 8 + ifd_size;

    try appendPackedGrayStripIfd(&data, pixel_offset, 4, 0, 3, 2);
    try appendU8s(&data, &.{ 0x0f, 0x70 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 136 }, plane.data);
}

test "reads palette color tiff strip as rgb" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const color_map_offset = 8 + ifd_size;
    const pixel_offset = color_map_offset + 768 * 2;

    try appendPalette8Ifd(&data, color_map_offset, pixel_offset);
    var i: usize = 0;
    while (i < 768) : (i += 1) {
        const value: u16 = switch (i) {
            1 => 0xffff,
            256 => 0x8000,
            512 => 0xffff,
            513 => 0x3300,
            else => 0,
        };
        try appendU16Le(&data, value);
    }
    try appendU8s(&data, &.{ 0, 1 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(usize, 3), metadata.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 128, 255, 255, 0, 51 }, plane.data);
}

test "reads 4-bit palette color tiff strip as rgb" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const color_map_count = 48;
    const color_map_offset = 8 + ifd_size;
    const pixel_offset = color_map_offset + color_map_count * 2;

    try appendPaletteStripIfd(&data, color_map_offset, pixel_offset, 4, 2, 1, color_map_count);
    var i: usize = 0;
    while (i < color_map_count) : (i += 1) {
        const value: u16 = switch (i) {
            1 => 0xffff,
            16 + 15 => 0x8000,
            32 + 15 => 0xffff,
            else => 0,
        };
        try appendU16Le(&data, value);
    }
    try appendU8s(&data, &.{0x1f});

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(usize, 3), metadata.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 128, 255 }, plane.data);
}

test "reads 4-bit palette color tiff strip with lsb fill order" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 11 * 12 + 4;
    const color_map_count = 48;
    const color_map_offset = 8 + ifd_size;
    const pixel_offset = color_map_offset + color_map_count * 2;

    try appendPaletteFillOrderStripIfd(&data, color_map_offset, pixel_offset, 4, 2, 1, color_map_count, 2);
    var i: usize = 0;
    while (i < color_map_count) : (i += 1) {
        const value: u16 = switch (i) {
            1 => 0xffff,
            16 + 15 => 0x8000,
            32 + 15 => 0xffff,
            else => 0,
        };
        try appendU16Le(&data, value);
    }
    try appendU8s(&data, &.{0xf1});

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 128, 255 }, plane.data);
}

test "reads uncompressed 16-bit grayscale tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const pixel_offset = 8 + ifd_size;

    try append16BitStripIfd(&data, pixel_offset);
    try appendU8s(&data, &.{ 0x34, 0x12, 0xcd, 0xab });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expectEqual(@as(usize, 2), metadata.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
}

test "reads uncompressed 32-bit grayscale tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const pixel_offset = 8 + ifd_size;

    try append32BitStripIfd(&data, pixel_offset);
    try appendU8s(&data, &.{ 0x78, 0x56, 0x34, 0x12, 0xef, 0xcd, 0xab, 0x90 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.uint32, metadata.pixel_type);
    try std.testing.expectEqual(@as(usize, 4), metadata.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12, 0xef, 0xcd, 0xab, 0x90 }, plane.data);
}

test "reads uncompressed float32 grayscale tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const pixel_offset = 8 + ifd_size;

    try appendFloat32StripIfd(&data, pixel_offset);
    try appendU8s(&data, &.{ 0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x20, 0xc0 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
    try std.testing.expectEqual(@as(usize, 4), metadata.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x20, 0xc0 }, plane.data);
}

test "reads uncompressed float64 grayscale tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const pixel_offset = 8 + ifd_size;

    try appendFloat64StripIfd(&data, pixel_offset);
    try appendU8s(&data, &.{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0xc0,
    });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.float64, metadata.pixel_type);
    try std.testing.expectEqual(@as(usize, 8), metadata.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0xc0,
    }, plane.data);
}

test "reads uncompressed signed 16-bit grayscale tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const pixel_offset = 8 + ifd_size;

    try appendSigned16StripIfd(&data, pixel_offset);
    try appendU8s(&data, &.{ 0xff, 0xff, 0x00, 0x80 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(bio.PixelType.int16, metadata.pixel_type);
    try std.testing.expectEqual(@as(usize, 2), metadata.bytesPerPixel());

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0x00, 0x80 }, plane.data);
}

test "reads planar rgb tiff strips as interleaved rgb" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const bits_offset = 8 + ifd_size;
    const strip_offsets_array = bits_offset + 6;
    const strip_counts_array = strip_offsets_array + 3 * 4;
    const pixel_offset = strip_counts_array + 3 * 4;

    try appendPlanarRgbIfd(&data, bits_offset, strip_offsets_array, strip_counts_array);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU32Le(&data, pixel_offset + 0);
    try appendU32Le(&data, pixel_offset + 2);
    try appendU32Le(&data, pixel_offset + 4);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 2);
    try appendU8s(&data, &.{ 10, 11, 20, 21, 30, 31 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgb8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 11, 21, 31 }, plane.data);
}

test "reads 16-bit planar rgb tiff strips as interleaved rgb" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const bits_offset = 8 + ifd_size;
    const strip_offsets_array = bits_offset + 6;
    const strip_counts_array = strip_offsets_array + 3 * 4;
    const pixel_offset = strip_counts_array + 3 * 4;

    try appendPlanarRgbIfd(&data, bits_offset, strip_offsets_array, strip_counts_array);
    try appendU16Le(&data, 16);
    try appendU16Le(&data, 16);
    try appendU16Le(&data, 16);
    try appendU32Le(&data, pixel_offset + 0);
    try appendU32Le(&data, pixel_offset + 4);
    try appendU32Le(&data, pixel_offset + 8);
    try appendU32Le(&data, 4);
    try appendU32Le(&data, 4);
    try appendU32Le(&data, 4);
    try appendU8s(&data, &.{
        0x01, 0x00, 0x02, 0x00,
        0x03, 0x00, 0x04, 0x00,
        0x05, 0x00, 0x06, 0x00,
    });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgb16, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{
        0x01, 0x00, 0x03, 0x00, 0x05, 0x00,
        0x02, 0x00, 0x04, 0x00, 0x06, 0x00,
    }, plane.data);
}

test "reads planar rgba tiff strips as interleaved rgba" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 11 * 12 + 4;
    const bits_offset = 8 + ifd_size;
    const strip_offsets_array = bits_offset + 8;
    const strip_counts_array = strip_offsets_array + 4 * 4;
    const pixel_offset = strip_counts_array + 4 * 4;

    try appendPlanarRgbaIfd(&data, bits_offset, strip_offsets_array, strip_counts_array);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU32Le(&data, pixel_offset + 0);
    try appendU32Le(&data, pixel_offset + 2);
    try appendU32Le(&data, pixel_offset + 4);
    try appendU32Le(&data, pixel_offset + 6);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 2);
    try appendU8s(&data, &.{ 10, 11, 20, 21, 30, 31, 255, 128 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgba8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255, 11, 21, 31, 128 }, plane.data);
}

test "reads region from separated planar rgb strips without decoding non-intersecting strips" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const bits_offset = 8 + ifd_size;
    const strip_offsets_array = bits_offset + 6;
    const strip_counts_array = strip_offsets_array + 9 * 4;
    const pixel_offset = strip_counts_array + 9 * 4;

    try appendPlanarRgbMultiStripIfd(&data, bits_offset, strip_offsets_array, strip_counts_array);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU32Le(&data, 9999);
    try appendU32Le(&data, pixel_offset + 0);
    try appendU32Le(&data, pixel_offset + 4);
    try appendU32Le(&data, 9999);
    try appendU32Le(&data, pixel_offset + 8);
    try appendU32Le(&data, pixel_offset + 12);
    try appendU32Le(&data, 9999);
    try appendU32Le(&data, pixel_offset + 16);
    try appendU32Le(&data, pixel_offset + 20);
    var i: usize = 0;
    while (i < 9) : (i += 1) try appendU32Le(&data, 4);
    try appendU8s(&data, &.{
        10, 11, 12, 13, 14, 15, 16, 17,
        20, 21, 22, 23, 24, 25, 26, 27,
        30, 31, 32, 33, 34, 35, 36, 37,
    });

    const plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{ .x = 1, .y = 1, .width = 2, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 11, 21, 31, 12, 22, 32 }, plane.data);
}

test "reads chunky rgb tiff strip with default planar configuration" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const bits_offset = 8 + ifd_size;
    const pixel_offset = bits_offset + 6;

    try appendU16Le(&data, 9);
    try appendEntry(&data, 256, 4, 1, 2);
    try appendEntry(&data, 257, 4, 1, 1);
    try appendEntry(&data, 258, 3, 3, bits_offset);
    try appendEntry(&data, 259, 3, 1, 1);
    try appendEntry(&data, 262, 3, 1, 2);
    try appendEntry(&data, 273, 4, 1, pixel_offset);
    try appendEntry(&data, 277, 3, 1, 3);
    try appendEntry(&data, 278, 4, 1, 1);
    try appendEntry(&data, 279, 4, 1, 6);
    try appendU32Le(&data, 0);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU8s(&data, &.{ 10, 20, 30, 11, 21, 31 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgb8, plane.metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), plane.metadata.samples_per_pixel);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 11, 21, 31 }, plane.data);
}

test "reads chunky 16-bit rgb tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const bits_offset = 8 + ifd_size;
    const pixel_offset = bits_offset + 6;

    try appendChunkyRgb16Ifd(&data, bits_offset, pixel_offset);
    try appendU16Le(&data, 16);
    try appendU16Le(&data, 16);
    try appendU16Le(&data, 16);
    try appendU8s(&data, &.{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgb16, plane.metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), plane.metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(usize, 6), plane.metadata.bytesPerPixel());
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a }, plane.data);
}

test "reads separated planar rgb tiff tiles as interleaved rgb" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 11 * 12 + 4;
    const bits_offset = 8 + ifd_size;
    const tile_offsets_array = bits_offset + 6;
    const tile_counts_array = tile_offsets_array + 12 * 4;
    const pixel_offset = tile_counts_array + 12 * 4;

    try appendPlanarTiledRgbIfd(&data, bits_offset, tile_offsets_array, tile_counts_array);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    var tile: usize = 0;
    while (tile < 12) : (tile += 1) try appendU32Le(&data, @intCast(pixel_offset + tile * 2));
    tile = 0;
    while (tile < 12) : (tile += 1) try appendU32Le(&data, 2);
    try appendU8s(&data, &.{
        10, 11, 12, 99, 13, 14, 15, 99,
        20, 21, 22, 99, 23, 24, 25, 99,
        30, 31, 32, 99, 33, 34, 35, 99,
    });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgb8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{
        10, 20, 30, 11, 21, 31, 12, 22, 32,
        13, 23, 33, 14, 24, 34, 15, 25, 35,
    }, plane.data);
}

test "reads region from separated planar rgb tiff tiles" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 11 * 12 + 4;
    const bits_offset = 8 + ifd_size;
    const tile_offsets_array = bits_offset + 6;
    const tile_counts_array = tile_offsets_array + 12 * 4;
    const pixel_offset = tile_counts_array + 12 * 4;

    try appendPlanarTiledRgbIfd(&data, bits_offset, tile_offsets_array, tile_counts_array);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    var tile: usize = 0;
    while (tile < 12) : (tile += 1) try appendU32Le(&data, @intCast(pixel_offset + tile * 2));
    tile = 0;
    while (tile < 12) : (tile += 1) try appendU32Le(&data, 2);
    try appendU8s(&data, &.{
        10, 11, 12, 99, 13, 14, 15, 99,
        20, 21, 22, 99, 23, 24, 25, 99,
        30, 31, 32, 99, 33, 34, 35, 99,
    });

    const plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{ .x = 1, .y = 0, .width = 2, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{
        11, 21, 31, 12, 22, 32,
        14, 24, 34, 15, 25, 35,
    }, plane.data);
}

test "reads separated planar rgba tiff tiles as interleaved rgba" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 12 * 12 + 4;
    const bits_offset = 8 + ifd_size;
    const tile_offsets_array = bits_offset + 8;
    const tile_counts_array = tile_offsets_array + 16 * 4;
    const pixel_offset = tile_counts_array + 16 * 4;

    try appendPlanarTiledRgbaIfd(&data, bits_offset, tile_offsets_array, tile_counts_array);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    var tile: usize = 0;
    while (tile < 16) : (tile += 1) try appendU32Le(&data, @intCast(pixel_offset + tile * 2));
    tile = 0;
    while (tile < 16) : (tile += 1) try appendU32Le(&data, 2);
    try appendU8s(&data, &.{
        10, 11, 12, 99, 13, 14, 15, 99,
        20, 21, 22, 99, 23, 24, 25, 99,
        30, 31, 32, 99, 33, 34, 35, 99,
        40, 41, 42, 99, 43, 44, 45, 99,
    });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgba8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{
        10, 20, 30, 40, 11, 21, 31, 41, 12, 22, 32, 42,
        13, 23, 33, 43, 14, 24, 34, 44, 15, 25, 35, 45,
    }, plane.data);
}

test "reads region from separated planar rgba tiff tiles" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 12 * 12 + 4;
    const bits_offset = 8 + ifd_size;
    const tile_offsets_array = bits_offset + 8;
    const tile_counts_array = tile_offsets_array + 16 * 4;
    const pixel_offset = tile_counts_array + 16 * 4;

    try appendPlanarTiledRgbaIfd(&data, bits_offset, tile_offsets_array, tile_counts_array);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    var tile: usize = 0;
    while (tile < 16) : (tile += 1) try appendU32Le(&data, @intCast(pixel_offset + tile * 2));
    tile = 0;
    while (tile < 16) : (tile += 1) try appendU32Le(&data, 2);
    try appendU8s(&data, &.{
        10, 11, 12, 99, 13, 14, 15, 99,
        20, 21, 22, 99, 23, 24, 25, 99,
        30, 31, 32, 99, 33, 34, 35, 99,
        40, 41, 42, 99, 43, 44, 45, 99,
    });

    const plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{ .x = 1, .y = 0, .width = 2, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{
        11, 21, 31, 41, 12, 22, 32, 42,
        14, 24, 34, 44, 15, 25, 35, 45,
    }, plane.data);
}

test "reads chunky rgba tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const bits_offset = 8 + ifd_size;
    const pixel_offset = bits_offset + 8;

    try appendChunkyRgbaIfd(&data, bits_offset, pixel_offset);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU8s(&data, &.{ 10, 20, 30, 255, 11, 21, 31, 128 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgba8, plane.metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), plane.metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(usize, 4), plane.metadata.bytesPerPixel());
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255, 11, 21, 31, 128 }, plane.data);
}

test "reads chunky 16-bit rgba tiff strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const bits_offset = 8 + ifd_size;
    const pixel_offset = bits_offset + 8;

    try appendChunkyRgba16Ifd(&data, bits_offset, pixel_offset);
    try appendU16Le(&data, 16);
    try appendU16Le(&data, 16);
    try appendU16Le(&data, 16);
    try appendU16Le(&data, 16);
    try appendU8s(&data, &.{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a, 0xff, 0xff });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgba16, plane.metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), plane.metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(usize, 8), plane.metadata.bytesPerPixel());
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a, 0xff, 0xff }, plane.data);
}

test "reads four-sample rgb tiff without alpha extra sample as rgba" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const bits_offset = 8 + ifd_size;
    const pixel_offset = bits_offset + 8;

    try appendChunkyFourSampleNoExtraIfd(&data, bits_offset, pixel_offset);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU8s(&data, &.{ 10, 20, 30, 40, 11, 21, 31, 41 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgba8, plane.metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), plane.metadata.samples_per_pixel);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 11, 21, 31, 41 }, plane.data);
}

test "reads planar four-sample rgb tiff without alpha extra sample as rgba" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const bits_offset = 8 + ifd_size;
    const strip_offsets_array = bits_offset + 8;
    const strip_counts_array = strip_offsets_array + 4 * 4;
    const pixel_offset = strip_counts_array + 4 * 4;

    try appendPlanarRgbaNoExtraIfd(&data, bits_offset, strip_offsets_array, strip_counts_array);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 8);
    try appendU32Le(&data, pixel_offset + 0);
    try appendU32Le(&data, pixel_offset + 2);
    try appendU32Le(&data, pixel_offset + 4);
    try appendU32Le(&data, pixel_offset + 6);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 2);
    try appendU32Le(&data, 2);
    try appendU8s(&data, &.{ 10, 11, 20, 21, 30, 31, 255, 128 });

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgba8, plane.metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), plane.metadata.samples_per_pixel);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255, 11, 21, 31, 128 }, plane.data);
}

test "reads baseline little-endian bigtiff grayscale strip" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    try appendU8s(&data, "II");
    try appendU16Le(&data, 43);
    try appendU16Le(&data, 8);
    try appendU16Le(&data, 0);
    try appendU64Le(&data, 16);

    const ifd_size = 8 + 9 * 20 + 8;
    const pixel_offset = 16 + ifd_size;
    try appendBigTiffStripIfd(&data, pixel_offset);
    try appendU8s(&data, &.{ 31, 32 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 31, 32 }, plane.data);
}

test "reads tiff image description metadata" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    const description = "<OME><Image ID=\"Image:0\"/></OME>";
    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const description_offset = 8 + ifd_size;
    const pixel_offset = description_offset + description.len + 1;
    try appendDescriptionIfd(&data, description_offset, pixel_offset, description.len + 1);
    try appendU8s(&data, description);
    try appendU8s(&data, &.{ 0, 45 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings(description, metadata.image_description.?);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{45}, plane.data);
}

test "reads ome pixels dimensions from image description" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);

    const description =
        \\<OME><Image ID="Image:0"><Pixels DimensionOrder="XYZCT" SizeX="1" SizeY="1" SizeZ="4" SizeC="2" SizeT="3" Type="uint8"/></Image></OME>
    ;
    try appendU8s(&data, "II");
    try appendU16Le(&data, 42);
    try appendU32Le(&data, 8);

    const ifd_size = 2 + 10 * 12 + 4;
    const description_offset = 8 + ifd_size;
    const pixel_offset = description_offset + description.len + 1;
    try appendDescriptionIfd(&data, description_offset, pixel_offset, description.len + 1);
    try appendU8s(&data, description);
    try appendU8s(&data, &.{ 0, 45 });

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqual(@as(u16, 4), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_t);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(usize, 1), metadata.bytesPerPixel());
    try std.testing.expectEqualStrings("XYZCT", metadata.dimension_order.?);
}

test "parses ImageJ hyperstack dimensions from image description" {
    const parsed = parseImageJComment(
        "ImageJ=1.51r\n" ++
            "images=46\n" ++
            "channels=2\n" ++
            "frames=23\n" ++
            "hyperstack=true\n",
    ).?;

    try std.testing.expectEqual(@as(u16, 1), parsed.size_z);
    try std.testing.expectEqual(@as(u16, 2), parsed.size_c);
    try std.testing.expectEqual(@as(u16, 23), parsed.size_t);
    try std.testing.expectEqual(@as(u32, 46), parsed.image_count);
}

test "matches Bio-Formats core metadata for cached ImageJ TIFF fixture" {
    const file_path = "fixtures/cache/tiff/A1.pattern1.tif";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("tiff", metadata.format);
    try std.testing.expectEqual(@as(u32, 305), metadata.width);
    try std.testing.expectEqual(@as(u32, 240), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 23), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 46), metadata.plane_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
}

test "matches Bio-Formats plane hashes for cached ImageJ TIFF fixture" {
    const file_path = "fixtures/cache/tiff/A1.pattern1.tif";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(data);

    const expected = [_]struct { plane: u32, sha256: [32]u8 }{
        .{ .plane = 0, .sha256 = .{ 0x20, 0x2e, 0xfd, 0x81, 0x69, 0x08, 0x74, 0x43, 0xba, 0xfe, 0x96, 0xa4, 0xa8, 0xc3, 0xb0, 0xa6, 0xe4, 0xa7, 0x0b, 0x00, 0x10, 0xfb, 0x50, 0xb5, 0x65, 0x99, 0x3e, 0xf6, 0xb0, 0x1c, 0x07, 0xf2 } },
        .{ .plane = 23, .sha256 = .{ 0x46, 0xb7, 0x73, 0x13, 0xa8, 0xc0, 0xa6, 0x21, 0x1e, 0xab, 0x8c, 0xfa, 0x55, 0x0e, 0x51, 0x3e, 0xe4, 0x7c, 0x99, 0x13, 0x32, 0x67, 0x40, 0x6d, 0xda, 0x82, 0x8d, 0x05, 0xb2, 0xa2, 0x8d, 0x33 } },
        .{ .plane = 45, .sha256 = .{ 0x5d, 0xec, 0x8e, 0x6b, 0x83, 0x26, 0x0f, 0xf3, 0xe5, 0x37, 0x91, 0x9c, 0x30, 0xab, 0x78, 0x50, 0x27, 0xd0, 0x7e, 0xbc, 0x36, 0x01, 0xa5, 0xa1, 0xb4, 0xb4, 0x49, 0x55, 0xdb, 0x64, 0x88, 0x8a } },
    };
    for (expected) |sample| {
        const plane = try readPlaneIndex(std.testing.allocator, data, sample.plane);
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqual(@as(usize, 146400), plane.data.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
        try std.testing.expectEqualSlices(u8, &sample.sha256, &digest);
    }
}

fn appendTestIfd(list: *std.ArrayList(u8), strip_offset: u32, next_ifd_offset: u32) !void {
    try appendTestIfdWithCompression(list, strip_offset, next_ifd_offset, 1, 1);
}

fn appendTestIfdWithCompression(
    list: *std.ArrayList(u8),
    strip_offset: u32,
    next_ifd_offset: u32,
    compression: u32,
    byte_count: u32,
) !void {
    try appendU16Le(list, 9);
    try appendEntry(list, 256, 4, 1, if (compression == 32773) 5 else 1);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, 8);
    try appendEntry(list, 259, 3, 1, compression);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 273, 4, 1, strip_offset);
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, byte_count);
    try appendU32Le(list, next_ifd_offset);
}

fn append16BitStripIfd(list: *std.ArrayList(u8), strip_offset: u32) !void {
    try appendU16Le(list, 9);
    try appendEntry(list, 256, 4, 1, 2);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, 16);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 273, 4, 1, strip_offset);
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 4);
    try appendU32Le(list, 0);
}

fn append32BitStripIfd(list: *std.ArrayList(u8), strip_offset: u32) !void {
    try appendU16Le(list, 9);
    try appendEntry(list, 256, 4, 1, 2);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, 32);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 273, 4, 1, strip_offset);
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 8);
    try appendU32Le(list, 0);
}

fn appendMultiStripGrayIfd(list: *std.ArrayList(u8), strip_offsets_array: usize, strip_counts_array: usize) !void {
    try appendU16Le(list, 9);
    try appendEntry(list, 256, 4, 1, 4);
    try appendEntry(list, 257, 4, 1, 3);
    try appendEntry(list, 258, 3, 1, 8);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 273, 4, 3, @intCast(strip_offsets_array));
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 3, @intCast(strip_counts_array));
    try appendU32Le(list, 0);
}

fn appendWhiteIsZero8StripIfd(list: *std.ArrayList(u8), strip_offset: u32) !void {
    try appendU16Le(list, 9);
    try appendEntry(list, 256, 4, 1, 3);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, 8);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 0);
    try appendEntry(list, 273, 4, 1, strip_offset);
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 3);
    try appendU32Le(list, 0);
}

fn appendBilevelStripIfd(list: *std.ArrayList(u8), strip_offset: u32, photometric: u32) !void {
    try appendPackedGrayStripIfd(list, strip_offset, 1, photometric, 5, 1);
}

fn appendPackedGrayStripIfd(
    list: *std.ArrayList(u8),
    strip_offset: u32,
    bits_per_sample: u32,
    photometric: u32,
    width: u32,
    byte_count: u32,
) !void {
    try appendU16Le(list, 9);
    try appendEntry(list, 256, 4, 1, width);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, bits_per_sample);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, photometric);
    try appendEntry(list, 273, 4, 1, strip_offset);
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, byte_count);
    try appendU32Le(list, 0);
}

fn appendPackedGrayFillOrderStripIfd(
    list: *std.ArrayList(u8),
    strip_offset: u32,
    bits_per_sample: u32,
    photometric: u32,
    width: u32,
    byte_count: u32,
    fill_order: u32,
) !void {
    try appendU16Le(list, 10);
    try appendEntry(list, 256, 4, 1, width);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, bits_per_sample);
    try appendEntry(list, 266, 3, 1, fill_order);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, photometric);
    try appendEntry(list, 273, 4, 1, strip_offset);
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, byte_count);
    try appendU32Le(list, 0);
}

fn appendPalette8Ifd(list: *std.ArrayList(u8), color_map_offset: usize, strip_offset: usize) !void {
    try appendPaletteStripIfd(list, color_map_offset, strip_offset, 8, 2, 2, 768);
}

fn appendPaletteStripIfd(
    list: *std.ArrayList(u8),
    color_map_offset: usize,
    strip_offset: usize,
    bits_per_sample: u32,
    width: u32,
    byte_count: u32,
    color_map_count: u32,
) !void {
    try appendU16Le(list, 10);
    try appendEntry(list, 256, 4, 1, width);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, bits_per_sample);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 3);
    try appendEntry(list, 273, 4, 1, @intCast(strip_offset));
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, byte_count);
    try appendEntry(list, 320, 3, color_map_count, @intCast(color_map_offset));
    try appendU32Le(list, 0);
}

fn appendPaletteFillOrderStripIfd(
    list: *std.ArrayList(u8),
    color_map_offset: usize,
    strip_offset: usize,
    bits_per_sample: u32,
    width: u32,
    byte_count: u32,
    color_map_count: u32,
    fill_order: u32,
) !void {
    try appendU16Le(list, 11);
    try appendEntry(list, 256, 4, 1, width);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, bits_per_sample);
    try appendEntry(list, 266, 3, 1, fill_order);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 3);
    try appendEntry(list, 273, 4, 1, @intCast(strip_offset));
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, byte_count);
    try appendEntry(list, 320, 3, color_map_count, @intCast(color_map_offset));
    try appendU32Le(list, 0);
}

fn appendFloat32StripIfd(list: *std.ArrayList(u8), strip_offset: u32) !void {
    try appendU16Le(list, 10);
    try appendEntry(list, 256, 4, 1, 2);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, 32);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 273, 4, 1, strip_offset);
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 8);
    try appendEntry(list, 339, 3, 1, 3);
    try appendU32Le(list, 0);
}

fn appendFloat64StripIfd(list: *std.ArrayList(u8), strip_offset: u32) !void {
    try appendU16Le(list, 10);
    try appendEntry(list, 256, 4, 1, 2);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, 64);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 273, 4, 1, strip_offset);
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 16);
    try appendEntry(list, 339, 3, 1, 3);
    try appendU32Le(list, 0);
}

fn appendSigned16StripIfd(list: *std.ArrayList(u8), strip_offset: u32) !void {
    try appendU16Le(list, 10);
    try appendEntry(list, 256, 4, 1, 2);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, 16);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 273, 4, 1, strip_offset);
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 4);
    try appendEntry(list, 339, 3, 1, 2);
    try appendU32Le(list, 0);
}

fn appendPlanarRgbIfd(
    list: *std.ArrayList(u8),
    bits_offset: usize,
    strip_offsets_array: usize,
    strip_counts_array: usize,
) !void {
    try appendU16Le(list, 10);
    try appendEntry(list, 256, 4, 1, 2);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 3, @intCast(bits_offset));
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 2);
    try appendEntry(list, 273, 4, 3, @intCast(strip_offsets_array));
    try appendEntry(list, 277, 3, 1, 3);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 3, @intCast(strip_counts_array));
    try appendEntry(list, 284, 3, 1, 2);
    try appendU32Le(list, 0);
}

fn appendPlanarRgbaIfd(
    list: *std.ArrayList(u8),
    bits_offset: usize,
    strip_offsets_array: usize,
    strip_counts_array: usize,
) !void {
    try appendU16Le(list, 11);
    try appendEntry(list, 256, 4, 1, 2);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 4, @intCast(bits_offset));
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 2);
    try appendEntry(list, 273, 4, 4, @intCast(strip_offsets_array));
    try appendEntry(list, 277, 3, 1, 4);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 4, @intCast(strip_counts_array));
    try appendEntry(list, 284, 3, 1, 2);
    try appendEntry(list, 338, 3, 1, 2);
    try appendU32Le(list, 0);
}

fn appendPlanarRgbaNoExtraIfd(
    list: *std.ArrayList(u8),
    bits_offset: usize,
    strip_offsets_array: usize,
    strip_counts_array: usize,
) !void {
    try appendU16Le(list, 10);
    try appendEntry(list, 256, 4, 1, 2);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 4, @intCast(bits_offset));
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 2);
    try appendEntry(list, 273, 4, 4, @intCast(strip_offsets_array));
    try appendEntry(list, 277, 3, 1, 4);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 4, @intCast(strip_counts_array));
    try appendEntry(list, 284, 3, 1, 2);
    try appendU32Le(list, 0);
}

fn appendPlanarRgbMultiStripIfd(
    list: *std.ArrayList(u8),
    bits_offset: usize,
    strip_offsets_array: usize,
    strip_counts_array: usize,
) !void {
    try appendU16Le(list, 10);
    try appendEntry(list, 256, 4, 1, 4);
    try appendEntry(list, 257, 4, 1, 3);
    try appendEntry(list, 258, 3, 3, @intCast(bits_offset));
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 2);
    try appendEntry(list, 273, 4, 9, @intCast(strip_offsets_array));
    try appendEntry(list, 277, 3, 1, 3);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 9, @intCast(strip_counts_array));
    try appendEntry(list, 284, 3, 1, 2);
    try appendU32Le(list, 0);
}

fn appendChunkyRgb16Ifd(list: *std.ArrayList(u8), bits_offset: usize, strip_offset: usize) !void {
    try appendU16Le(list, 10);
    try appendEntry(list, 256, 4, 1, 1);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 3, @intCast(bits_offset));
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 2);
    try appendEntry(list, 273, 4, 1, @intCast(strip_offset));
    try appendEntry(list, 277, 3, 1, 3);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 6);
    try appendEntry(list, 284, 3, 1, 1);
    try appendU32Le(list, 0);
}

fn appendPlanarTiledRgbIfd(
    list: *std.ArrayList(u8),
    bits_offset: usize,
    tile_offsets_array: usize,
    tile_counts_array: usize,
) !void {
    try appendU16Le(list, 11);
    try appendEntry(list, 256, 4, 1, 3);
    try appendEntry(list, 257, 4, 1, 2);
    try appendEntry(list, 258, 3, 3, @intCast(bits_offset));
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 2);
    try appendEntry(list, 277, 3, 1, 3);
    try appendEntry(list, 284, 3, 1, 2);
    try appendEntry(list, 322, 4, 1, 2);
    try appendEntry(list, 323, 4, 1, 1);
    try appendEntry(list, 324, 4, 12, @intCast(tile_offsets_array));
    try appendEntry(list, 325, 4, 12, @intCast(tile_counts_array));
    try appendU32Le(list, 0);
}

fn appendPlanarTiledRgbaIfd(
    list: *std.ArrayList(u8),
    bits_offset: usize,
    tile_offsets_array: usize,
    tile_counts_array: usize,
) !void {
    try appendU16Le(list, 12);
    try appendEntry(list, 256, 4, 1, 3);
    try appendEntry(list, 257, 4, 1, 2);
    try appendEntry(list, 258, 3, 4, @intCast(bits_offset));
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 2);
    try appendEntry(list, 277, 3, 1, 4);
    try appendEntry(list, 284, 3, 1, 2);
    try appendEntry(list, 322, 4, 1, 2);
    try appendEntry(list, 323, 4, 1, 1);
    try appendEntry(list, 324, 4, 16, @intCast(tile_offsets_array));
    try appendEntry(list, 325, 4, 16, @intCast(tile_counts_array));
    try appendEntry(list, 338, 3, 1, 2);
    try appendU32Le(list, 0);
}

fn appendChunkyRgbaIfd(list: *std.ArrayList(u8), bits_offset: usize, strip_offset: usize) !void {
    try appendU16Le(list, 10);
    try appendEntry(list, 256, 4, 1, 2);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 4, @intCast(bits_offset));
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 2);
    try appendEntry(list, 273, 4, 1, @intCast(strip_offset));
    try appendEntry(list, 277, 3, 1, 4);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 8);
    try appendEntry(list, 338, 3, 1, 2);
    try appendU32Le(list, 0);
}

fn appendChunkyRgba16Ifd(list: *std.ArrayList(u8), bits_offset: usize, strip_offset: usize) !void {
    try appendU16Le(list, 10);
    try appendEntry(list, 256, 4, 1, 1);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 4, @intCast(bits_offset));
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 2);
    try appendEntry(list, 273, 4, 1, @intCast(strip_offset));
    try appendEntry(list, 277, 3, 1, 4);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 8);
    try appendEntry(list, 338, 3, 1, 2);
    try appendU32Le(list, 0);
}

fn appendChunkyFourSampleNoExtraIfd(list: *std.ArrayList(u8), bits_offset: usize, strip_offset: usize) !void {
    try appendU16Le(list, 9);
    try appendEntry(list, 256, 4, 1, 2);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 4, @intCast(bits_offset));
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 2);
    try appendEntry(list, 273, 4, 1, @intCast(strip_offset));
    try appendEntry(list, 277, 3, 1, 4);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 8);
    try appendU32Le(list, 0);
}

fn appendDeflateStripIfd(list: *std.ArrayList(u8), strip_offset: u32, compression: u32, byte_count: u32) !void {
    try appendU16Le(list, 9);
    try appendEntry(list, 256, 4, 1, 3);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, 8);
    try appendEntry(list, 259, 3, 1, compression);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 273, 4, 1, strip_offset);
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, byte_count);
    try appendU32Le(list, 0);
}

fn appendDeflatePredictorStripIfd(list: *std.ArrayList(u8), strip_offset: u32, byte_count: u32) !void {
    try appendU16Le(list, 10);
    try appendEntry(list, 256, 4, 1, 3);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, 8);
    try appendEntry(list, 259, 3, 1, 32946);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 273, 4, 1, strip_offset);
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, byte_count);
    try appendEntry(list, 317, 3, 1, 2);
    try appendU32Le(list, 0);
}

fn appendDescriptionIfd(
    list: *std.ArrayList(u8),
    description_offset: usize,
    strip_offset: usize,
    description_count: usize,
) !void {
    try appendU16Le(list, 10);
    try appendEntry(list, 256, 4, 1, 1);
    try appendEntry(list, 257, 4, 1, 1);
    try appendEntry(list, 258, 3, 1, 8);
    try appendEntry(list, 259, 3, 1, 1);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 270, 2, @intCast(description_count), @intCast(description_offset));
    try appendEntry(list, 273, 4, 1, @intCast(strip_offset));
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 278, 4, 1, 1);
    try appendEntry(list, 279, 4, 1, 1);
    try appendU32Le(list, 0);
}

fn appendBigTiffStripIfd(list: *std.ArrayList(u8), strip_offset: u64) !void {
    try appendU64Le(list, 9);
    try appendBigEntry(list, 256, 4, 1, 2);
    try appendBigEntry(list, 257, 4, 1, 1);
    try appendBigEntry(list, 258, 3, 1, 8);
    try appendBigEntry(list, 259, 3, 1, 1);
    try appendBigEntry(list, 262, 3, 1, 1);
    try appendBigEntry(list, 273, 16, 1, strip_offset);
    try appendBigEntry(list, 277, 3, 1, 1);
    try appendBigEntry(list, 278, 4, 1, 1);
    try appendBigEntry(list, 279, 16, 1, 2);
    try appendU64Le(list, 0);
}

fn appendTiledTestIfd(list: *std.ArrayList(u8), tile_offsets_array: u32, tile_counts_array: u32) !void {
    try appendTiledTestIfdWithCompression(list, tile_offsets_array, tile_counts_array, 1);
}

fn appendTiledTestIfdWithCompression(
    list: *std.ArrayList(u8),
    tile_offsets_array: u32,
    tile_counts_array: u32,
    compression: u32,
) !void {
    try appendU16Le(list, 10);
    try appendEntry(list, 256, 4, 1, 3);
    try appendEntry(list, 257, 4, 1, 2);
    try appendEntry(list, 258, 3, 1, 8);
    try appendEntry(list, 259, 3, 1, compression);
    try appendEntry(list, 262, 3, 1, 1);
    try appendEntry(list, 277, 3, 1, 1);
    try appendEntry(list, 322, 4, 1, 2);
    try appendEntry(list, 323, 4, 1, 1);
    try appendEntry(list, 324, 4, 4, tile_offsets_array);
    try appendEntry(list, 325, 4, 4, tile_counts_array);
    try appendU32Le(list, 0);
}

fn appendEntry(list: *std.ArrayList(u8), tag: u16, field_type: u16, count: u32, value: u32) !void {
    try appendU16Le(list, tag);
    try appendU16Le(list, field_type);
    try appendU32Le(list, count);
    try appendU32Le(list, value);
}

fn appendBigEntry(list: *std.ArrayList(u8), tag: u16, field_type: u16, count: u64, value: u64) !void {
    try appendU16Le(list, tag);
    try appendU16Le(list, field_type);
    try appendU64Le(list, count);
    try appendU64Le(list, value);
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

fn appendU64Le(list: *std.ArrayList(u8), value: u64) !void {
    try list.append(std.testing.allocator, @intCast(value & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 32) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 40) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 48) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 56) & 0xff));
}

fn appendU8s(list: *std.ArrayList(u8), bytes: []const u8) !void {
    try list.appendSlice(std.testing.allocator, bytes);
}
