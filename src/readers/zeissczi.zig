const std = @import("std");
const bio = @import("../root.zig");
const jpeg = @import("jpeg.zig");
const tiff = @import("tiff.zig");

const alignment = 32;
const segment_header_size = 32;
const czi_magic = "ZISRAWFILE";
const subblock_id = "ZISRAWSUBBLOCK";
const metadata_id = "ZISRAWMETADATA";

const gray8 = 0;
const gray16 = 1;
const gray_float = 2;
const bgr_24 = 3;
const bgr_48 = 4;
const bgr_float = 8;
const bgra_8 = 9;
const gray32 = 12;
const gray_double = 13;
const uncompressed = 0;
const jpeg_compression = 1;
const lzw_compression = 2;
const zstd_0_compression = 5;
const zstd_1_compression = 6;
const camera_packed_reversed_compression = 104;
const camera_packed_compression = 504;

const Scan = struct {
    width: u32 = 0,
    height: u32 = 0,
    size_c: u16 = 1,
    size_z: u16 = 1,
    size_t: u16 = 1,
    series_count: u32 = 1,
    pixel_type: bio.PixelType = .uint8,
    samples: u16 = 1,
    plane_count: u32 = 0,
    series_plane_counts: [256]u32 = @splat(0),
    seen_plane_series: [4096]u32 = @splat(0),
    image_description: ?[]const u8 = null,
};

pub fn matches(data: []const u8) bool {
    return data.len >= czi_magic.len and std.mem.eql(u8, data[0..czi_magic.len], czi_magic);
}

pub fn isPath(path: []const u8) bool {
    return hasExtension(path, "czi");
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    if (!matches(data)) return error.InvalidFormat;
    const scan = try scanSegments(data);
    if (scan.width == 0 or scan.height == 0 or scan.plane_count == 0) return error.InvalidFormat;
    return metadataFromScan(scan);
}

pub fn readMetadataPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const scan = try scanSegmentsPath(allocator, io, path, true);
    if (scan.width == 0 or scan.height == 0 or scan.plane_count == 0) return error.InvalidFormat;
    return metadataFromScan(scan);
}

fn readMetadataPathCore(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bio.Metadata {
    const scan = try scanSegmentsPath(allocator, io, path, false);
    if (scan.width == 0 or scan.height == 0 or scan.plane_count == 0) return error.InvalidFormat;
    return metadataFromScan(scan);
}

fn metadataFromScan(scan: Scan) bio.Metadata {
    return .{
        .format = "zeissczi",
        .width = scan.width,
        .height = scan.height,
        .size_c = scan.size_c,
        .samples_per_pixel = scan.samples,
        .size_z = scan.size_z,
        .size_t = scan.size_t,
        .pixel_type = scan.pixel_type,
        .little_endian = true,
        .plane_count = scan.plane_count,
        .series_count = scan.series_count,
        .image_description = scan.image_description,
        .dimension_order = "XYCZT",
    };
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const metadata = try readMetadata(data);
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    const block = try findSubBlock(data, metadata, plane_index);
    if (block.width != metadata.width or block.height != metadata.height) return error.UnsupportedVariant;

    if (block.compression == jpeg_compression) {
        if (block.data_offset > data.len or data.len - block.data_offset < block.data_size) return error.TruncatedData;
        const out = try readJpegCompressedPlane(allocator, data[block.data_offset..][0..block.data_size], metadata, null);
        errdefer allocator.free(out);
        if (metadata.samples_per_pixel >= 3) reverseBgr(out, metadata);
        return .{ .metadata = metadata, .data = out };
    }
    if (block.compression == lzw_compression) {
        if (block.data_offset > data.len or data.len - block.data_offset < block.data_size) return error.TruncatedData;
        const out = try readLzwCompressedPlane(allocator, data[block.data_offset..][0..block.data_size], metadata, null);
        errdefer allocator.free(out);
        if (metadata.samples_per_pixel >= 3) reverseBgr(out, metadata);
        return .{ .metadata = metadata, .data = out };
    }
    if (block.compression == zstd_0_compression) {
        if (block.data_offset > data.len or data.len - block.data_offset < block.data_size) return error.TruncatedData;
        const out = try readZstdCompressedPlane(allocator, data[block.data_offset..][0..block.data_size], metadata, null);
        errdefer allocator.free(out);
        if (metadata.samples_per_pixel >= 3) reverseBgr(out, metadata);
        return .{ .metadata = metadata, .data = out };
    }
    if (block.compression == zstd_1_compression) {
        if (block.data_offset > data.len or data.len - block.data_offset < block.data_size) return error.TruncatedData;
        const out = try readZstd1CompressedPlane(allocator, data[block.data_offset..][0..block.data_size], metadata, null);
        errdefer allocator.free(out);
        if (metadata.samples_per_pixel >= 3) reverseBgr(out, metadata);
        return .{ .metadata = metadata, .data = out };
    }
    if (block.compression == camera_packed_reversed_compression or block.compression == camera_packed_compression) {
        if (block.data_offset > data.len or data.len - block.data_offset < block.data_size) return error.TruncatedData;
        var plane_metadata = metadata;
        plane_metadata.little_endian = false;
        const out = try readCameraPackedPlane(allocator, data[block.data_offset..][0..block.data_size], plane_metadata, null, block.compression == camera_packed_reversed_compression);
        errdefer allocator.free(out);
        return .{ .metadata = plane_metadata, .data = out };
    }
    if (block.compression != uncompressed) return error.UnsupportedVariant;

    const plane_len = try planeByteCount(metadata);
    if (block.data_size < plane_len) return error.TruncatedData;
    if (block.data_size != plane_len) return error.UnsupportedVariant;
    if (block.data_offset > data.len or data.len - block.data_offset < plane_len) return error.TruncatedData;
    const out = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(out);
    @memcpy(out, data[block.data_offset..][0..plane_len]);
    if (metadata.samples_per_pixel >= 3) reverseBgr(out, metadata);
    return .{ .metadata = metadata, .data = out };
}

pub fn readPlanePathRegionIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    return readPlanePathRegionSeriesIndex(allocator, io, path, 0, plane_index, region);
}

pub fn readPlanePathRegionSeriesIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    series_index: u32,
    plane_index: u32,
    region: bio.Region,
) !bio.Plane {
    const metadata = try readMetadataPathCore(allocator, io, path);
    if (series_index >= metadata.series_count) return error.InvalidPlaneIndex;
    if (plane_index >= metadata.plane_count) return error.InvalidPlaneIndex;
    try region.validate(metadata);

    const block = try findSubBlockPath(io, path, metadata, series_index, plane_index);
    if (block.x != 0 or block.y != 0 or block.width != metadata.width or block.height != metadata.height) {
        if (block.compression != uncompressed and block.compression != jpeg_compression and block.compression != lzw_compression and block.compression != zstd_0_compression and block.compression != zstd_1_compression and block.compression != camera_packed_reversed_compression and block.compression != camera_packed_compression) return error.UnsupportedVariant;
        const plane_data = try readTiledPlaneRegionAlloc(allocator, io, path, metadata, series_index, plane_index, region);
        errdefer allocator.free(plane_data);
        var plane_metadata = metadata;
        if (block.compression == camera_packed_reversed_compression or block.compression == camera_packed_compression) {
            plane_metadata.little_endian = false;
        } else if (metadata.samples_per_pixel >= 3) reverseBgr(plane_data, metadata);
        return .{ .metadata = plane_metadata, .data = plane_data };
    }

    if (block.compression == jpeg_compression) {
        const compressed = try readFileRangeAlloc(allocator, io, path, @intCast(block.data_offset), block.data_size);
        defer allocator.free(compressed);
        const plane_data = try readJpegCompressedPlane(allocator, compressed, metadata, region);
        errdefer allocator.free(plane_data);
        if (metadata.samples_per_pixel >= 3) reverseBgr(plane_data, metadata);
        return .{ .metadata = metadata, .data = plane_data };
    }
    if (block.compression == lzw_compression) {
        const compressed = try readFileRangeAlloc(allocator, io, path, @intCast(block.data_offset), block.data_size);
        defer allocator.free(compressed);
        const plane_data = try readLzwCompressedPlane(allocator, compressed, metadata, region);
        errdefer allocator.free(plane_data);
        if (metadata.samples_per_pixel >= 3) reverseBgr(plane_data, metadata);
        return .{ .metadata = metadata, .data = plane_data };
    }
    if (block.compression == zstd_0_compression) {
        const compressed = try readFileRangeAlloc(allocator, io, path, @intCast(block.data_offset), block.data_size);
        defer allocator.free(compressed);
        const plane_data = try readZstdCompressedPlane(allocator, compressed, metadata, region);
        errdefer allocator.free(plane_data);
        if (metadata.samples_per_pixel >= 3) reverseBgr(plane_data, metadata);
        return .{ .metadata = metadata, .data = plane_data };
    }
    if (block.compression == zstd_1_compression) {
        const compressed = try readFileRangeAlloc(allocator, io, path, @intCast(block.data_offset), block.data_size);
        defer allocator.free(compressed);
        const plane_data = try readZstd1CompressedPlane(allocator, compressed, metadata, region);
        errdefer allocator.free(plane_data);
        if (metadata.samples_per_pixel >= 3) reverseBgr(plane_data, metadata);
        return .{ .metadata = metadata, .data = plane_data };
    }
    if (block.compression == camera_packed_reversed_compression or block.compression == camera_packed_compression) {
        const compressed = try readFileRangeAlloc(allocator, io, path, @intCast(block.data_offset), block.data_size);
        defer allocator.free(compressed);
        var plane_metadata = metadata;
        plane_metadata.little_endian = false;
        const plane_data = try readCameraPackedPlane(allocator, compressed, plane_metadata, region, block.compression == camera_packed_reversed_compression);
        errdefer allocator.free(plane_data);
        return .{ .metadata = plane_metadata, .data = plane_data };
    }
    if (block.compression != uncompressed) return error.UnsupportedVariant;

    const plane_len = try planeByteCount(metadata);
    if (block.data_size < plane_len) return error.TruncatedData;
    if (block.data_size != plane_len) return error.UnsupportedVariant;

    if (region.isFull(metadata)) {
        const plane_data = try readFileRangeAlloc(allocator, io, path, @intCast(block.data_offset), plane_len);
        errdefer allocator.free(plane_data);
        if (metadata.samples_per_pixel >= 3) reverseBgr(plane_data, metadata);
        return .{ .metadata = metadata, .data = plane_data };
    }
    const plane_data = try readPlaneRegionRangeAlloc(allocator, io, path, metadata, block, region);
    errdefer allocator.free(plane_data);
    if (metadata.samples_per_pixel >= 3) reverseBgr(plane_data, metadata);
    return .{
        .metadata = metadata,
        .data = plane_data,
    };
}

fn readJpegCompressedPlane(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    metadata: bio.Metadata,
    region: ?bio.Region,
) bio.ReaderError![]u8 {
    const decoded = try jpeg.readPlaneIndexAs(allocator, compressed, 0, metadata.format);
    errdefer allocator.free(decoded.data);
    if (decoded.metadata.width != metadata.width or decoded.metadata.height != metadata.height) return error.UnsupportedVariant;
    if (decoded.metadata.pixel_type != metadata.pixel_type) return error.UnsupportedVariant;
    if (decoded.metadata.samples_per_pixel != metadata.samples_per_pixel) return error.UnsupportedVariant;
    if (region) |r| {
        if (r.isFull(metadata)) return decoded.data;
        defer allocator.free(decoded.data);
        return try bio.cropPlane(allocator, .{ .metadata = metadata, .data = decoded.data }, r);
    }
    return decoded.data;
}

fn readLzwCompressedPlane(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    metadata: bio.Metadata,
    region: ?bio.Region,
) bio.ReaderError![]u8 {
    const plane_len = try planeByteCount(metadata);
    const decoded = try allocator.alloc(u8, plane_len);
    errdefer allocator.free(decoded);
    try tiff.decodeLzw(compressed, decoded);
    if (region) |r| {
        if (r.isFull(metadata)) return decoded;
        defer allocator.free(decoded);
        return try bio.cropPlane(allocator, .{ .metadata = metadata, .data = decoded }, r);
    }
    return decoded;
}

fn readZstdCompressedPlane(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    metadata: bio.Metadata,
    region: ?bio.Region,
) bio.ReaderError![]u8 {
    const plane_len = try planeByteCount(metadata);
    const decoded = try decodeZstdAlloc(allocator, compressed, plane_len);
    errdefer allocator.free(decoded);
    if (region) |r| {
        if (r.isFull(metadata)) return decoded;
        defer allocator.free(decoded);
        return try bio.cropPlane(allocator, .{ .metadata = metadata, .data = decoded }, r);
    }
    return decoded;
}

fn readZstd1CompressedPlane(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    metadata: bio.Metadata,
    region: ?bio.Region,
) bio.ReaderError![]u8 {
    const plane_len = try planeByteCount(metadata);
    const parsed = try parseZstd1Header(compressed);
    var decoded = try decodeZstdAlloc(allocator, compressed[parsed.payload_offset..], plane_len);
    errdefer allocator.free(decoded);
    if (parsed.high_low_unpacking) {
        const unpacked = try allocator.alloc(u8, decoded.len);
        errdefer allocator.free(unpacked);
        const second_half = decoded.len / 2;
        var i: usize = 0;
        while (i < decoded.len) : (i += 1) {
            const offset = i / 2;
            unpacked[i] = if (i % 2 == 0) decoded[offset] else decoded[second_half + offset];
        }
        allocator.free(decoded);
        decoded = unpacked;
    }

    if (region) |r| {
        if (r.isFull(metadata)) return decoded;
        defer allocator.free(decoded);
        return try bio.cropPlane(allocator, .{ .metadata = metadata, .data = decoded }, r);
    }
    return decoded;
}

fn decodeZstdAlloc(allocator: std.mem.Allocator, compressed: []const u8, expected_len: usize) bio.ReaderError![]u8 {
    const decoded = try allocator.alloc(u8, expected_len);
    errdefer allocator.free(decoded);

    var input: std.Io.Reader = .fixed(compressed);
    var output: std.Io.Writer = .fixed(decoded);
    var decompress: std.compress.zstd.Decompress = .init(&input, &.{}, .{});
    const written = decompress.reader.streamRemaining(&output) catch return error.TruncatedData;
    if (written != decoded.len) return error.TruncatedData;
    return decoded;
}

const Zstd1Header = struct {
    payload_offset: usize,
    high_low_unpacking: bool,
};

fn parseZstd1Header(data: []const u8) bio.ReaderError!Zstd1Header {
    var pos: usize = 0;
    const header_size = try readZstd1Varint(data, &pos);
    if (header_size > data.len or pos > header_size) return error.TruncatedData;
    var high_low_unpacking = false;
    while (pos < header_size) {
        const chunk_id = try readZstd1Varint(data, &pos);
        switch (chunk_id) {
            1 => {
                if (pos >= header_size) return error.TruncatedData;
                const payload = data[pos];
                pos += 1;
                high_low_unpacking = (payload & 1) == 1;
            },
            else => return error.UnsupportedVariant,
        }
    }
    return .{ .payload_offset = pos, .high_low_unpacking = high_low_unpacking };
}

fn readZstd1Varint(data: []const u8, pos: *usize) bio.ReaderError!usize {
    if (pos.* >= data.len) return error.TruncatedData;
    const a = data[pos.*];
    pos.* += 1;
    if ((a & 0x80) == 0) return a;
    if (pos.* >= data.len) return error.TruncatedData;
    const b = data[pos.*];
    pos.* += 1;
    if ((b & 0x80) == 0) return (@as(usize, b) << 7) | @as(usize, a & 0x7f);
    if (pos.* >= data.len) return error.TruncatedData;
    const c = data[pos.*];
    pos.* += 1;
    return (@as(usize, c) << 14) | (@as(usize, b & 0x7f) << 7) | @as(usize, a & 0x7f);
}

fn readCameraPackedPlane(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    metadata: bio.Metadata,
    region: ?bio.Region,
    reverse_columns: bool,
) bio.ReaderError![]u8 {
    const plane_len = try planeByteCount(metadata);
    const decoded = try decode12BitCamera(allocator, compressed, plane_len);
    errdefer allocator.free(decoded);
    if (reverse_columns) try reverseCameraColumns(decoded, metadata);
    if (region) |r| {
        if (r.isFull(metadata)) return decoded;
        defer allocator.free(decoded);
        return try bio.cropPlane(allocator, .{ .metadata = metadata, .data = decoded }, r);
    }
    return decoded;
}

fn decode12BitCamera(allocator: std.mem.Allocator, compressed: []const u8, decoded_len: usize) bio.ReaderError![]u8 {
    const nibble_count = std.math.mul(usize, decoded_len / 2, 3) catch return error.UnsupportedVariant;
    if (compressed.len < (nibble_count + 1) / 2) return error.TruncatedData;
    var nibbles = try allocator.alloc(u8, nibble_count);
    defer allocator.free(nibbles);
    for (nibbles, 0..) |*value, i| {
        const byte = compressed[i / 2];
        value.* = if (i % 2 == 0) byte >> 4 else byte & 0x0f;
    }

    var index: usize = 0;
    while (index + 1 < nibbles.len) : (index += 1) {
        if (index >= 3 and (index - 3) % 6 == 0) {
            const middle = nibbles[index];
            const last = nibbles[index + 1];
            const first = nibbles[index - 1];
            nibbles[index + 1] = middle;
            nibbles[index] = first;
            nibbles[index - 1] = last;
        }
    }

    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    var nibble_index: usize = 0;
    var out_index: usize = 0;
    while (nibble_index < nibbles.len and out_index < decoded.len) {
        if (nibble_index % 3 == 0) {
            decoded[out_index] = nibbles[nibble_index];
            nibble_index += 1;
        } else {
            if (nibble_index + 1 >= nibbles.len) return error.TruncatedData;
            decoded[out_index] = (nibbles[nibble_index] << 4) | nibbles[nibble_index + 1];
            nibble_index += 2;
        }
        out_index += 1;
    }
    if (out_index != decoded.len) return error.TruncatedData;
    return decoded;
}

fn reverseCameraColumns(data: []u8, metadata: bio.Metadata) bio.ReaderError!void {
    if (metadata.bytesPerPixel() != 2) return error.UnsupportedVariant;
    const row_bytes = std.math.mul(usize, metadata.width, 2) catch return error.UnsupportedVariant;
    if (data.len < row_bytes * metadata.height) return error.TruncatedData;
    var row: u32 = 0;
    while (row < metadata.height) : (row += 1) {
        const row_offset = @as(usize, row) * row_bytes;
        var col: u32 = 0;
        while (col < metadata.width / 2) : (col += 1) {
            const left = row_offset + @as(usize, col) * 2;
            const right = row_offset + @as(usize, metadata.width - col - 1) * 2;
            std.mem.swap(u8, &data[left], &data[right]);
            std.mem.swap(u8, &data[left + 1], &data[right + 1]);
        }
    }
}

const SubBlockRef = struct {
    data_offset: usize,
    data_size: usize,
    compression: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

fn scanSegments(data: []const u8) bio.ReaderError!Scan {
    var scan = Scan{};
    var pos: usize = 0;
    while (pos + segment_header_size <= data.len) {
        pos = alignForward(pos);
        if (pos + segment_header_size > data.len) break;
        const id = trimSegmentId(data[pos..][0..16]);
        const allocated = try checkedUsize(leU64(data[pos + 16 ..][0..8]));
        const used = try checkedUsize(leU64(data[pos + 24 ..][0..8]));
        const payload_len = if (used == 0) allocated else used;
        const payload_start = pos + segment_header_size;
        const payload_end = std.math.add(usize, payload_start, payload_len) catch return error.UnsupportedVariant;
        if (payload_end > data.len) return error.TruncatedData;

        if (std.mem.eql(u8, id, subblock_id)) {
            try parseSubBlock(data[payload_start..payload_end], &scan);
        } else if (std.mem.eql(u8, id, metadata_id) and scan.image_description == null) {
            scan.image_description = try parseMetadataXml(data[payload_start..payload_end]);
        }

        const next = std.math.add(usize, payload_start, allocated) catch return error.UnsupportedVariant;
        if (next <= pos) return error.InvalidFormat;
        pos = next;
    }
    return scan;
}

fn scanSegmentsPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8, include_xml: bool) !Scan {
    var file = try openFile(io, path);
    defer file.close(io);
    const file_len_u64 = (try file.stat(io)).size;
    const file_len = try checkedUsize(file_len_u64);
    var scan = Scan{};
    var pos: usize = 0;
    while (pos + segment_header_size <= file_len) {
        pos = alignForward(pos);
        if (pos + segment_header_size > file_len) break;
        var header: [segment_header_size]u8 = undefined;
        if (try file.readPositionalAll(io, &header, pos) != header.len) return error.TruncatedData;
        const id = trimSegmentId(header[0..16]);
        if (pos == 0 and !std.mem.eql(u8, id, czi_magic)) return error.InvalidFormat;
        const allocated = try checkedUsize(leU64(header[16..24]));
        const used = try checkedUsize(leU64(header[24..32]));
        const payload_len = if (used == 0) allocated else used;
        const payload_start = pos + segment_header_size;
        const payload_end = std.math.add(usize, payload_start, payload_len) catch return error.UnsupportedVariant;
        if (payload_end > file_len) return error.TruncatedData;

        if (std.mem.eql(u8, id, subblock_id)) {
            var prefix: [256]u8 = undefined;
            if (payload_len < prefix.len) return error.TruncatedData;
            if (try file.readPositionalAll(io, &prefix, payload_start) != prefix.len) return error.TruncatedData;
            try parseSubBlock(&prefix, &scan);
        } else if (include_xml and std.mem.eql(u8, id, metadata_id) and scan.image_description == null) {
            var metadata_header: [256]u8 = undefined;
            if (payload_len < metadata_header.len) return error.TruncatedData;
            if (try file.readPositionalAll(io, &metadata_header, payload_start) != metadata_header.len) return error.TruncatedData;
            scan.image_description = try readMetadataXmlPath(allocator, io, path, &metadata_header, payload_start, payload_len);
        }

        const next = std.math.add(usize, payload_start, allocated) catch return error.UnsupportedVariant;
        if (next <= pos) return error.InvalidFormat;
        pos = next;
    }
    return scan;
}

fn parseSubBlock(payload: []const u8, scan: *Scan) bio.ReaderError!void {
    if (payload.len < 256) return error.TruncatedData;
    const data_size = leU64(payload[8..16]);
    _ = data_size;
    const entry = try parseDirectoryEntry(payload[16..]);
    if (entry.pyramid_type != 0) return;
    const pixel = pixelType(entry.pixel_type);
    scan.pixel_type = pixel.pixel_type;
    scan.samples = pixel.samples;
    if (pixel.samples > 1) scan.size_c = @max(scan.size_c, pixel.samples);

    const series_index = try subBlockSeriesIndex(entry);
    if (series_index >= scan.series_plane_counts.len) return error.UnsupportedVariant;
    scan.series_count = @max(scan.series_count, series_index + 1);
    for (entry.dimensions.items()) |dimension| {
        switch (dimension.name) {
            'X' => scan.width = @max(scan.width, dimension.start + dimension.size),
            'Y' => scan.height = @max(scan.height, dimension.start + dimension.size),
            'C' => scan.size_c = @max(scan.size_c, boundedDimension(dimension.start + dimension.size)),
            'Z' => scan.size_z = @max(scan.size_z, boundedDimension(dimension.start + dimension.size)),
            'T' => scan.size_t = @max(scan.size_t, boundedDimension(dimension.start + dimension.size)),
            else => {},
        }
    }
    const plane_index = subBlockPlaneIndexFromScan(scan.*, entry) orelse return;
    if (plane_index >= scan.seen_plane_series.len or series_index >= 32) return error.UnsupportedVariant;
    const series_bit = @as(u32, 1) << @as(u5, @intCast(series_index));
    if ((scan.seen_plane_series[plane_index] & series_bit) == 0) {
        scan.seen_plane_series[plane_index] |= series_bit;
        scan.series_plane_counts[series_index] += 1;
    }
    scan.plane_count = @max(scan.plane_count, scan.series_plane_counts[series_index]);
    scan.plane_count = @max(scan.plane_count, scanPlaneProduct(scan.*));
}

fn findSubBlockPath(io: std.Io, path: []const u8, metadata: bio.Metadata, series_index: u32, plane_index: u32) !SubBlockRef {
    var file = try openFile(io, path);
    defer file.close(io);
    const file_len_u64 = (try file.stat(io)).size;
    const file_len = try checkedUsize(file_len_u64);
    var pos: usize = 0;
    while (pos + segment_header_size <= file_len) {
        pos = alignForward(pos);
        if (pos + segment_header_size > file_len) break;
        var header: [segment_header_size]u8 = undefined;
        if (try file.readPositionalAll(io, &header, pos) != header.len) return error.TruncatedData;
        const id = trimSegmentId(header[0..16]);
        if (pos == 0 and !std.mem.eql(u8, id, czi_magic)) return error.InvalidFormat;
        const allocated = try checkedUsize(leU64(header[16..24]));
        const used = try checkedUsize(leU64(header[24..32]));
        const payload_len = if (used == 0) allocated else used;
        const payload_start = pos + segment_header_size;
        const payload_end = std.math.add(usize, payload_start, payload_len) catch return error.UnsupportedVariant;
        if (payload_end > file_len) return error.TruncatedData;

        if (std.mem.eql(u8, id, subblock_id)) {
            var prefix: [256]u8 = undefined;
            if (payload_len < prefix.len) return error.TruncatedData;
            if (try file.readPositionalAll(io, &prefix, payload_start) != prefix.len) return error.TruncatedData;
            const entry = try parseDirectoryEntry(prefix[16..]);
            if (entry.pyramid_type == 0 and (try subBlockSeriesIndex(entry)) == series_index and subBlockPlaneIndex(metadata, entry) == plane_index) {
                return parseSubBlockRefPath(&prefix, payload_start, payload_len);
            }
        }

        const next = std.math.add(usize, payload_start, allocated) catch return error.UnsupportedVariant;
        if (next <= pos) return error.InvalidFormat;
        pos = next;
    }
    return error.InvalidPlaneIndex;
}

fn findSubBlock(data: []const u8, metadata: bio.Metadata, plane_index: u32) bio.ReaderError!SubBlockRef {
    var pos: usize = 0;
    while (pos + segment_header_size <= data.len) {
        pos = alignForward(pos);
        if (pos + segment_header_size > data.len) break;
        const id = trimSegmentId(data[pos..][0..16]);
        const allocated = try checkedUsize(leU64(data[pos + 16 ..][0..8]));
        const used = try checkedUsize(leU64(data[pos + 24 ..][0..8]));
        const payload_len = if (used == 0) allocated else used;
        const payload_start = pos + segment_header_size;
        const payload_end = std.math.add(usize, payload_start, payload_len) catch return error.UnsupportedVariant;
        if (payload_end > data.len) return error.TruncatedData;

        if (std.mem.eql(u8, id, subblock_id)) {
            const entry = try parseDirectoryEntry(data[payload_start + 16 .. payload_end]);
            if (entry.pyramid_type == 0 and (try subBlockSeriesIndex(entry)) == 0 and subBlockPlaneIndex(metadata, entry) == plane_index) return try parseSubBlockRef(data[payload_start..payload_end], payload_start);
        }

        const next = std.math.add(usize, payload_start, allocated) catch return error.UnsupportedVariant;
        if (next <= pos) return error.InvalidFormat;
        pos = next;
    }
    return error.InvalidPlaneIndex;
}

fn subBlockSeriesIndex(entry: DirectoryEntry) bio.ReaderError!u32 {
    for (entry.dimensions.items()) |dimension| {
        if (dimension.name == 'S') return dimension.start;
    }
    return 0;
}

fn subBlockPlaneIndex(metadata: bio.Metadata, entry: DirectoryEntry) ?u32 {
    var z: u32 = 0;
    var c: u32 = 0;
    var t: u32 = 0;
    for (entry.dimensions.items()) |dimension| {
        switch (dimension.name) {
            'Z' => z = dimension.start,
            'C' => c = dimension.start,
            'T' => t = dimension.start,
            else => {},
        }
    }
    return metadata.planeIndex(z, c, t) catch null;
}

fn subBlockPlaneIndexFromScan(scan: Scan, entry: DirectoryEntry) ?u32 {
    const metadata = bio.Metadata{
        .format = "zeissczi",
        .width = @max(scan.width, 1),
        .height = @max(scan.height, 1),
        .size_c = scan.size_c,
        .samples_per_pixel = scan.samples,
        .size_z = scan.size_z,
        .size_t = scan.size_t,
        .pixel_type = scan.pixel_type,
        .little_endian = true,
        .plane_count = std.math.maxInt(u32),
        .series_count = scan.series_count,
        .dimension_order = "XYCZT",
    };
    return subBlockPlaneIndex(metadata, entry);
}

fn scanPlaneProduct(scan: Scan) u32 {
    const zc = std.math.mul(u32, scan.size_z, scan.size_c) catch return scan.plane_count;
    return std.math.mul(u32, zc, scan.size_t) catch return scan.plane_count;
}

fn parseMetadataXml(payload: []const u8) bio.ReaderError!?[]const u8 {
    if (payload.len < 256) return error.TruncatedData;
    const xml_size = try checkedUsize(leU32(payload[0..4]));
    const attachment_size = try checkedUsize(leU32(payload[4..8]));
    const xml_offset: usize = 256;
    const after_xml = std.math.add(usize, xml_offset, xml_size) catch return error.UnsupportedVariant;
    const after_attachment = std.math.add(usize, after_xml, attachment_size) catch return error.UnsupportedVariant;
    if (after_attachment > payload.len) return error.TruncatedData;
    if (xml_size == 0) return null;
    return payload[xml_offset..after_xml];
}

fn readMetadataXmlPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    metadata_header: *const [256]u8,
    payload_start: usize,
    payload_len: usize,
) !?[]const u8 {
    const xml_size = try checkedUsize(leU32(metadata_header[0..4]));
    const attachment_size = try checkedUsize(leU32(metadata_header[4..8]));
    const xml_offset = std.math.add(usize, payload_start, 256) catch return error.UnsupportedVariant;
    const after_xml = std.math.add(usize, xml_offset, xml_size) catch return error.UnsupportedVariant;
    const payload_end = std.math.add(usize, payload_start, payload_len) catch return error.UnsupportedVariant;
    const after_attachment = std.math.add(usize, after_xml, attachment_size) catch return error.UnsupportedVariant;
    if (after_attachment > payload_end) return error.TruncatedData;
    if (xml_size == 0) return null;
    return try readFileRangeAlloc(allocator, io, path, @intCast(xml_offset), xml_size);
}

fn parseSubBlockRefPath(payload: []const u8, payload_start: usize, payload_len: usize) bio.ReaderError!SubBlockRef {
    if (payload.len < 256) return error.TruncatedData;
    const metadata_size = try checkedUsize(leU32(payload[0..4]));
    const data_size = try checkedUsize(leU64(payload[8..16]));
    const entry = try parseDirectoryEntry(payload[16..]);
    var width: u32 = 0;
    var height: u32 = 0;
    var x: u32 = 0;
    var y: u32 = 0;
    for (entry.dimensions.items()) |dimension| {
        switch (dimension.name) {
            'X' => {
                x = dimension.start;
                width = dimension.size;
            },
            'Y' => {
                y = dimension.start;
                height = dimension.size;
            },
            else => {},
        }
    }
    if (width == 0 or height == 0) return error.InvalidFormat;
    const data_base = std.math.add(usize, payload_start, 256) catch return error.UnsupportedVariant;
    const data_offset = std.math.add(usize, data_base, metadata_size) catch return error.UnsupportedVariant;
    const payload_end = std.math.add(usize, payload_start, payload_len) catch return error.UnsupportedVariant;
    if (data_offset > payload_end or payload_end - data_offset < data_size) return error.TruncatedData;
    return .{
        .data_offset = data_offset,
        .data_size = data_size,
        .compression = entry.compression,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
    };
}

fn parseSubBlockRef(payload: []const u8, payload_start: usize) bio.ReaderError!SubBlockRef {
    if (payload.len < 256) return error.TruncatedData;
    const metadata_size = try checkedUsize(leU32(payload[0..4]));
    const data_size = try checkedUsize(leU64(payload[8..16]));
    const entry = try parseDirectoryEntry(payload[16..]);
    var width: u32 = 0;
    var height: u32 = 0;
    var x: u32 = 0;
    var y: u32 = 0;
    for (entry.dimensions.items()) |dimension| {
        switch (dimension.name) {
            'X' => {
                x = dimension.start;
                width = dimension.size;
            },
            'Y' => {
                y = dimension.start;
                height = dimension.size;
            },
            else => {},
        }
    }
    if (width == 0 or height == 0) return error.InvalidFormat;
    const data_base = std.math.add(usize, payload_start, 256) catch return error.UnsupportedVariant;
    const data_offset = std.math.add(usize, data_base, metadata_size) catch return error.UnsupportedVariant;
    const payload_end = std.math.add(usize, payload_start, payload.len) catch return error.UnsupportedVariant;
    if (data_offset > payload_end or payload_end - data_offset < data_size) return error.TruncatedData;
    return .{
        .data_offset = data_offset,
        .data_size = data_size,
        .compression = entry.compression,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
    };
}

const DirectoryEntry = struct {
    pixel_type: u32,
    compression: u32,
    pyramid_type: u8,
    dimensions: DimensionList,
};

const DimensionList = struct {
    values: [16]Dimension = undefined,
    len: usize = 0,

    fn append(self: *DimensionList, value: Dimension) bio.ReaderError!void {
        if (self.len >= self.values.len) return error.UnsupportedVariant;
        self.values[self.len] = value;
        self.len += 1;
    }

    fn items(self: *const DimensionList) []const Dimension {
        return self.values[0..self.len];
    }
};

const Dimension = struct {
    name: u8,
    start: u32,
    size: u32,
};

fn parseDirectoryEntry(data: []const u8) bio.ReaderError!DirectoryEntry {
    if (data.len < 32) return error.TruncatedData;
    const pixel_type = leU32(data[2..6]);
    const compression = leU32(data[18..22]);
    const pyramid_type = data[22];
    const dimension_count = leU32(data[28..32]);
    if (dimension_count == 0 or dimension_count > 16) return error.UnsupportedVariant;
    if (data.len < 32 + @as(usize, dimension_count) * 20) return error.TruncatedData;
    var dimensions = DimensionList{};
    var pos: usize = 32;
    var i: u32 = 0;
    while (i < dimension_count) : (i += 1) {
        const raw_name = std.mem.trim(u8, data[pos..][0..4], " \x00");
        if (raw_name.len == 1) {
            const start = leI32(data[pos + 4 ..][0..4]);
            try dimensions.append(.{
                .name = raw_name[0],
                .start = if (start < 0) 0 else @intCast(start),
                .size = leU32(data[pos + 8 ..][0..4]),
            });
        }
        pos += 20;
    }
    return .{ .pixel_type = pixel_type, .compression = compression, .pyramid_type = pyramid_type, .dimensions = dimensions };
}

const Pixel = struct {
    pixel_type: bio.PixelType,
    samples: u16,
};

fn pixelType(value: u32) Pixel {
    return switch (value) {
        gray16 => .{ .pixel_type = .uint16, .samples = 1 },
        gray32 => .{ .pixel_type = .uint32, .samples = 1 },
        gray_float => .{ .pixel_type = .float32, .samples = 1 },
        gray_double => .{ .pixel_type = .float64, .samples = 1 },
        bgr_24 => .{ .pixel_type = .rgb8, .samples = 3 },
        bgr_48 => .{ .pixel_type = .rgb16, .samples = 3 },
        bgr_float => .{ .pixel_type = .float32, .samples = 3 },
        bgra_8 => .{ .pixel_type = .rgba8, .samples = 4 },
        else => .{ .pixel_type = .uint8, .samples = 1 },
    };
}

fn reverseBgr(data: []u8, metadata: bio.Metadata) void {
    const bytes_per_sample = metadata.pixel_type.bytesPerSample();
    const pixel_bytes = metadata.bytesPerPixel();
    if (bytes_per_sample == 0 or pixel_bytes < bytes_per_sample * 3) return;
    var i: usize = 0;
    while (i + pixel_bytes <= data.len) : (i += pixel_bytes) {
        var j: usize = 0;
        while (j < bytes_per_sample) : (j += 1) {
            std.mem.swap(u8, &data[i + j], &data[i + 2 * bytes_per_sample + j]);
        }
    }
}

fn boundedDimension(value: u32) u16 {
    return @intCast(@min(@max(value, 1), std.math.maxInt(u16)));
}

fn trimSegmentId(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \x00");
}

fn alignForward(pos: usize) usize {
    return pos + ((alignment - (pos % alignment)) % alignment);
}

fn leU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn leI32(bytes: []const u8) i32 {
    return std.mem.readInt(i32, bytes[0..4], .little);
}

fn leU64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}

fn checkedUsize(value: anytype) bio.ReaderError!usize {
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
}

fn planeByteCount(metadata: bio.Metadata) bio.ReaderError!usize {
    const pixels = std.math.mul(usize, metadata.width, metadata.height) catch return error.UnsupportedVariant;
    return std.math.mul(usize, pixels, metadata.bytesPerPixel()) catch return error.UnsupportedVariant;
}

fn readFileRangeAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8, offset: u64, len: usize) ![]u8 {
    var file = try openFile(io, path);
    defer file.close(io);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    const read_len = try file.readPositionalAll(io, out, offset);
    if (read_len != len) return error.TruncatedData;
    return out;
}

fn readPlaneRegionRangeAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    metadata: bio.Metadata,
    block: SubBlockRef,
    region: bio.Region,
) ![]u8 {
    const bytes_per_pixel = metadata.bytesPerPixel();
    const src_row_bytes = std.math.mul(usize, metadata.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const dst_row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, dst_row_bytes, region.height) catch return error.UnsupportedVariant;
    const x_offset = std.math.mul(usize, region.x, bytes_per_pixel) catch return error.UnsupportedVariant;

    var file = try openFile(io, path);
    defer file.close(io);

    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    var row: usize = 0;
    while (row < region.height) : (row += 1) {
        const src_y = @as(usize, region.y) + row;
        const row_offset = std.math.mul(usize, src_y, src_row_bytes) catch return error.UnsupportedVariant;
        const plane_offset = std.math.add(usize, row_offset, x_offset) catch return error.UnsupportedVariant;
        const file_offset = std.math.add(usize, block.data_offset, plane_offset) catch return error.UnsupportedVariant;
        const dst_offset = std.math.mul(usize, row, dst_row_bytes) catch return error.UnsupportedVariant;
        const read_len = try file.readPositionalAll(io, out[dst_offset..][0..dst_row_bytes], @intCast(file_offset));
        if (read_len != dst_row_bytes) return error.TruncatedData;
    }

    return out;
}

fn readTiledPlaneRegionAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    metadata: bio.Metadata,
    series_index: u32,
    plane_index: u32,
    region: bio.Region,
) ![]u8 {
    const bytes_per_pixel = metadata.bytesPerPixel();
    const dst_row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, dst_row_bytes, region.height) catch return error.UnsupportedVariant;
    const covered_len = std.math.mul(usize, region.width, region.height) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    @memset(out, 0);
    const covered = try allocator.alloc(bool, covered_len);
    defer allocator.free(covered);
    @memset(covered, false);

    var file = try openFile(io, path);
    defer file.close(io);
    const file_len_u64 = (try file.stat(io)).size;
    const file_len = try checkedUsize(file_len_u64);
    var pos: usize = 0;
    while (pos + segment_header_size <= file_len) {
        pos = alignForward(pos);
        if (pos + segment_header_size > file_len) break;
        var header: [segment_header_size]u8 = undefined;
        if (try file.readPositionalAll(io, &header, pos) != header.len) return error.TruncatedData;
        const id = trimSegmentId(header[0..16]);
        if (pos == 0 and !std.mem.eql(u8, id, czi_magic)) return error.InvalidFormat;
        const allocated = try checkedUsize(leU64(header[16..24]));
        const used = try checkedUsize(leU64(header[24..32]));
        const payload_len = if (used == 0) allocated else used;
        const payload_start = pos + segment_header_size;
        const payload_end = std.math.add(usize, payload_start, payload_len) catch return error.UnsupportedVariant;
        if (payload_end > file_len) return error.TruncatedData;

        if (std.mem.eql(u8, id, subblock_id)) {
            var prefix: [256]u8 = undefined;
            if (payload_len < prefix.len) return error.TruncatedData;
            if (try file.readPositionalAll(io, &prefix, payload_start) != prefix.len) return error.TruncatedData;
            const entry = try parseDirectoryEntry(prefix[16..]);
            if (entry.pyramid_type == 0 and (try subBlockSeriesIndex(entry)) == series_index and subBlockPlaneIndex(metadata, entry) == plane_index) {
                const block = try parseSubBlockRefPath(&prefix, payload_start, payload_len);
                switch (block.compression) {
                    uncompressed => try copyTileOverlap(io, &file, out, covered, metadata, block, region),
                    jpeg_compression => try copyJpegTileOverlap(allocator, io, &file, out, covered, metadata, block, region),
                    lzw_compression => try copyLzwTileOverlap(allocator, io, &file, out, covered, metadata, block, region),
                    zstd_0_compression => try copyZstdTileOverlap(allocator, io, &file, out, covered, metadata, block, region),
                    zstd_1_compression => try copyZstd1TileOverlap(allocator, io, &file, out, covered, metadata, block, region),
                    camera_packed_reversed_compression => try copyCameraPackedTileOverlap(allocator, io, &file, out, covered, metadata, block, region, true),
                    camera_packed_compression => try copyCameraPackedTileOverlap(allocator, io, &file, out, covered, metadata, block, region, false),
                    else => return error.UnsupportedVariant,
                }
            }
        }

        const next = std.math.add(usize, payload_start, allocated) catch return error.UnsupportedVariant;
        if (next <= pos) return error.InvalidFormat;
        pos = next;
    }

    for (covered) |pixel| {
        if (!pixel) return error.UnsupportedVariant;
    }
    return out;
}

fn copyTileOverlap(
    io: std.Io,
    file: *std.Io.File,
    out: []u8,
    covered: []bool,
    metadata: bio.Metadata,
    block: SubBlockRef,
    region: bio.Region,
) !void {
    const bytes_per_pixel = metadata.bytesPerPixel();
    const tile_len = std.math.mul(usize, std.math.mul(usize, block.width, block.height) catch return error.UnsupportedVariant, bytes_per_pixel) catch return error.UnsupportedVariant;
    if (block.data_size < tile_len) return error.TruncatedData;
    if (block.data_size != tile_len) return error.UnsupportedVariant;

    const x0 = @max(block.x, region.x);
    const y0 = @max(block.y, region.y);
    const x1 = @min(block.x + block.width, region.x + region.width);
    const y1 = @min(block.y + block.height, region.y + region.height);
    if (x0 >= x1 or y0 >= y1) return;

    const src_row_bytes = std.math.mul(usize, block.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const dst_row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const copy_pixels = x1 - x0;
    const copy_bytes = std.math.mul(usize, copy_pixels, bytes_per_pixel) catch return error.UnsupportedVariant;
    var row: u32 = 0;
    while (row < y1 - y0) : (row += 1) {
        const src_y = @as(usize, y0 - block.y + row);
        const src_x = std.math.mul(usize, x0 - block.x, bytes_per_pixel) catch return error.UnsupportedVariant;
        const src_offset = std.math.add(usize, std.math.mul(usize, src_y, src_row_bytes) catch return error.UnsupportedVariant, src_x) catch return error.UnsupportedVariant;
        const file_offset = std.math.add(usize, block.data_offset, src_offset) catch return error.UnsupportedVariant;
        const dst_y = @as(usize, y0 - region.y + row);
        const dst_x = std.math.mul(usize, x0 - region.x, bytes_per_pixel) catch return error.UnsupportedVariant;
        const dst_offset = std.math.add(usize, std.math.mul(usize, dst_y, dst_row_bytes) catch return error.UnsupportedVariant, dst_x) catch return error.UnsupportedVariant;
        const read_len = try file.readPositionalAll(io, out[dst_offset..][0..copy_bytes], @intCast(file_offset));
        if (read_len != copy_bytes) return error.TruncatedData;

        const covered_offset = std.math.add(usize, std.math.mul(usize, dst_y, region.width) catch return error.UnsupportedVariant, x0 - region.x) catch return error.UnsupportedVariant;
        @memset(covered[covered_offset..][0..copy_pixels], true);
    }
}

fn copyJpegTileOverlap(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: *std.Io.File,
    out: []u8,
    covered: []bool,
    metadata: bio.Metadata,
    block: SubBlockRef,
    region: bio.Region,
) !void {
    const compressed = try allocator.alloc(u8, block.data_size);
    defer allocator.free(compressed);
    if (try file.readPositionalAll(io, compressed, @intCast(block.data_offset)) != compressed.len) return error.TruncatedData;

    var tile_metadata = metadata;
    tile_metadata.width = block.width;
    tile_metadata.height = block.height;
    const tile = try readJpegCompressedPlane(allocator, compressed, tile_metadata, null);
    defer allocator.free(tile);
    try copyDecodedTileOverlap(out, covered, metadata, block, region, tile);
}

fn copyLzwTileOverlap(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: *std.Io.File,
    out: []u8,
    covered: []bool,
    metadata: bio.Metadata,
    block: SubBlockRef,
    region: bio.Region,
) !void {
    const compressed = try allocator.alloc(u8, block.data_size);
    defer allocator.free(compressed);
    if (try file.readPositionalAll(io, compressed, @intCast(block.data_offset)) != compressed.len) return error.TruncatedData;

    var tile_metadata = metadata;
    tile_metadata.width = block.width;
    tile_metadata.height = block.height;
    const tile = try readLzwCompressedPlane(allocator, compressed, tile_metadata, null);
    defer allocator.free(tile);
    try copyDecodedTileOverlap(out, covered, metadata, block, region, tile);
}

fn copyZstdTileOverlap(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: *std.Io.File,
    out: []u8,
    covered: []bool,
    metadata: bio.Metadata,
    block: SubBlockRef,
    region: bio.Region,
) !void {
    const compressed = try allocator.alloc(u8, block.data_size);
    defer allocator.free(compressed);
    if (try file.readPositionalAll(io, compressed, @intCast(block.data_offset)) != compressed.len) return error.TruncatedData;

    var tile_metadata = metadata;
    tile_metadata.width = block.width;
    tile_metadata.height = block.height;
    const tile = try readZstdCompressedPlane(allocator, compressed, tile_metadata, null);
    defer allocator.free(tile);
    try copyDecodedTileOverlap(out, covered, metadata, block, region, tile);
}

fn copyZstd1TileOverlap(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: *std.Io.File,
    out: []u8,
    covered: []bool,
    metadata: bio.Metadata,
    block: SubBlockRef,
    region: bio.Region,
) !void {
    const compressed = try allocator.alloc(u8, block.data_size);
    defer allocator.free(compressed);
    if (try file.readPositionalAll(io, compressed, @intCast(block.data_offset)) != compressed.len) return error.TruncatedData;

    var tile_metadata = metadata;
    tile_metadata.width = block.width;
    tile_metadata.height = block.height;
    const tile = try readZstd1CompressedPlane(allocator, compressed, tile_metadata, null);
    defer allocator.free(tile);
    try copyDecodedTileOverlap(out, covered, metadata, block, region, tile);
}

fn copyCameraPackedTileOverlap(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: *std.Io.File,
    out: []u8,
    covered: []bool,
    metadata: bio.Metadata,
    block: SubBlockRef,
    region: bio.Region,
    reverse_columns: bool,
) !void {
    const compressed = try allocator.alloc(u8, block.data_size);
    defer allocator.free(compressed);
    if (try file.readPositionalAll(io, compressed, @intCast(block.data_offset)) != compressed.len) return error.TruncatedData;

    var tile_metadata = metadata;
    tile_metadata.width = block.width;
    tile_metadata.height = block.height;
    tile_metadata.little_endian = false;
    const tile = try readCameraPackedPlane(allocator, compressed, tile_metadata, null, reverse_columns);
    defer allocator.free(tile);
    try copyDecodedTileOverlap(out, covered, metadata, block, region, tile);
}

fn copyDecodedTileOverlap(
    out: []u8,
    covered: []bool,
    metadata: bio.Metadata,
    block: SubBlockRef,
    region: bio.Region,
    tile: []const u8,
) !void {
    const bytes_per_pixel = metadata.bytesPerPixel();
    const x0 = @max(block.x, region.x);
    const y0 = @max(block.y, region.y);
    const x1 = @min(block.x + block.width, region.x + region.width);
    const y1 = @min(block.y + block.height, region.y + region.height);
    if (x0 >= x1 or y0 >= y1) return;

    const src_row_bytes = std.math.mul(usize, block.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const dst_row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const copy_pixels = x1 - x0;
    const copy_bytes = std.math.mul(usize, copy_pixels, bytes_per_pixel) catch return error.UnsupportedVariant;
    var row: u32 = 0;
    while (row < y1 - y0) : (row += 1) {
        const src_y = @as(usize, y0 - block.y + row);
        const src_x = std.math.mul(usize, x0 - block.x, bytes_per_pixel) catch return error.UnsupportedVariant;
        const src_offset = std.math.add(usize, std.math.mul(usize, src_y, src_row_bytes) catch return error.UnsupportedVariant, src_x) catch return error.UnsupportedVariant;
        const dst_y = @as(usize, y0 - region.y + row);
        const dst_x = std.math.mul(usize, x0 - region.x, bytes_per_pixel) catch return error.UnsupportedVariant;
        const dst_offset = std.math.add(usize, std.math.mul(usize, dst_y, dst_row_bytes) catch return error.UnsupportedVariant, dst_x) catch return error.UnsupportedVariant;
        @memcpy(out[dst_offset..][0..copy_bytes], tile[src_offset..][0..copy_bytes]);

        const covered_offset = std.math.add(usize, std.math.mul(usize, dst_y, region.width) catch return error.UnsupportedVariant, x0 - region.x) catch return error.UnsupportedVariant;
        @memset(covered[covered_offset..][0..copy_pixels], true);
    }
}

fn openFile(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().openFile(io, path, .{});
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], extension);
}

fn appendSegment(allocator: std.mem.Allocator, out: *std.ArrayList(u8), id: []const u8, payload: []const u8) !void {
    while (out.items.len % alignment != 0) try out.append(allocator, 0);
    var id_bytes: [16]u8 = @splat(0);
    @memcpy(id_bytes[0..id.len], id);
    try out.appendSlice(allocator, &id_bytes);
    try appendU64Le(allocator, out, @intCast(payload.len));
    try appendU64Le(allocator, out, @intCast(payload.len));
    try out.appendSlice(allocator, payload);
}

fn appendDimension(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, start: u32, size: u32) !void {
    var dim: [4]u8 = @splat(0);
    @memcpy(dim[0..name.len], name);
    try out.appendSlice(allocator, &dim);
    try appendU32Le(allocator, out, start);
    try appendU32Le(allocator, out, size);
    try appendU32Le(allocator, out, 0);
    try appendU32Le(allocator, out, size);
}

fn appendU32Le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn appendU64Le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn appendZeros(allocator: std.mem.Allocator, out: *std.ArrayList(u8), count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try out.append(allocator, 0);
}

fn minimalCzi(allocator: std.mem.Allocator, pixel_type: u32) ![]u8 {
    return minimalCziWithPixelsAndDims(allocator, pixel_type, &.{}, 2, 3, 4);
}

fn minimalCziWithPixels(allocator: std.mem.Allocator, pixel_type: u32, pixels: []const u8) ![]u8 {
    return minimalCziWithPixelsAndDims(allocator, pixel_type, pixels, 1, 1, 1);
}

fn minimalCziWithPixelsAndDims(allocator: std.mem.Allocator, pixel_type: u32, pixels: []const u8, size_c: u32, size_z: u32, size_t: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});
    try appendMinimalSubBlock(allocator, &out, pixel_type, pixels, size_c, size_z, size_t, null);
    return out.toOwnedSlice(allocator);
}

fn minimalCziWithScenePixels(allocator: std.mem.Allocator, pixel_type: u32, scene0: []const u8, scene1: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});
    try appendMinimalSubBlock(allocator, &out, pixel_type, scene0, 1, 1, 1, 0);
    try appendMinimalSubBlock(allocator, &out, pixel_type, scene1, 1, 1, 1, 1);
    return out.toOwnedSlice(allocator);
}

fn minimalTiledCzi(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});
    try appendMinimalSubBlockAt(allocator, &out, gray8, &.{ 1, 2, 5, 6 }, 1, 1, 1, null, 0, 0, 2, 2);
    try appendMinimalSubBlockAt(allocator, &out, gray8, &.{ 3, 4, 7, 8 }, 1, 1, 1, null, 2, 0, 2, 2);
    try appendMinimalSubBlockAt(allocator, &out, gray8, &.{ 9, 10, 13, 14 }, 1, 1, 1, null, 0, 2, 2, 2);
    try appendMinimalSubBlockAt(allocator, &out, gray8, &.{ 11, 12, 15, 16 }, 1, 1, 1, null, 2, 2, 2, 2);
    return out.toOwnedSlice(allocator);
}

fn minimalCziWithPyramidSubBlock(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});
    try appendMinimalSubBlockAt(allocator, &out, gray8, &.{ 1, 2, 3, 4 }, 1, 1, 1, null, 0, 0, 2, 2);
    try appendMinimalSubBlockAtPyramid(allocator, &out, gray8, &.{9}, 1, 1, 1, null, 0, 0, 1, 1, 1, uncompressed);
    return out.toOwnedSlice(allocator);
}

fn minimalCziWithJpegCompressedBlock(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});
    try appendMinimalSubBlockAtPyramid(allocator, &out, bgr_24, &jpeg.baseline_red_jpeg, 3, 1, 1, null, 0, 0, 1, 1, 0, jpeg_compression);
    return out.toOwnedSlice(allocator);
}

fn minimalCziWithJpegCompressedTile(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});
    try appendMinimalSubBlockAtPyramid(allocator, &out, bgr_24, &jpeg.baseline_red_jpeg, 3, 1, 1, null, 1, 0, 1, 1, 0, jpeg_compression);
    return out.toOwnedSlice(allocator);
}

fn minimalCziWithLzwCompressedBlock(allocator: std.mem.Allocator) ![]u8 {
    const compressed = [_]u8{ 128, 0, 64, 64, 56, 8 };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});
    try appendMinimalSubBlockAtPyramid(allocator, &out, gray8, &compressed, 1, 1, 1, null, 0, 0, 3, 1, 0, lzw_compression);
    return out.toOwnedSlice(allocator);
}

fn minimalCziWithLzwCompressedTile(allocator: std.mem.Allocator) ![]u8 {
    const compressed = [_]u8{ 128, 0, 64, 64, 56, 8 };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});
    try appendMinimalSubBlockAtPyramid(allocator, &out, gray8, &compressed, 1, 1, 1, null, 1, 0, 3, 1, 0, lzw_compression);
    return out.toOwnedSlice(allocator);
}

fn minimalCziWithZstdCompressedBlock(allocator: std.mem.Allocator) ![]u8 {
    const compressed = zstdRawBlock123();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});
    try appendMinimalSubBlockAtPyramid(allocator, &out, gray8, &compressed, 1, 1, 1, null, 0, 0, 3, 1, 0, zstd_0_compression);
    return out.toOwnedSlice(allocator);
}

fn minimalCziWithZstdCompressedTile(allocator: std.mem.Allocator) ![]u8 {
    const compressed = zstdRawBlock123();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});
    try appendMinimalSubBlockAtPyramid(allocator, &out, gray8, &compressed, 1, 1, 1, null, 1, 0, 3, 1, 0, zstd_0_compression);
    return out.toOwnedSlice(allocator);
}

fn minimalCziWithZstd1CompressedBlock(allocator: std.mem.Allocator) ![]u8 {
    const compressed = zstd1HighLowBlock();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});
    try appendMinimalSubBlockAtPyramid(allocator, &out, gray16, &compressed, 1, 1, 1, null, 0, 0, 2, 1, 0, zstd_1_compression);
    return out.toOwnedSlice(allocator);
}

fn minimalCziWithZstd1CompressedTile(allocator: std.mem.Allocator) ![]u8 {
    const compressed = zstd1HighLowBlock();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});
    try appendMinimalSubBlockAtPyramid(allocator, &out, gray16, &compressed, 1, 1, 1, null, 1, 0, 2, 1, 0, zstd_1_compression);
    return out.toOwnedSlice(allocator);
}

fn minimalCziWithCameraPackedBlock(allocator: std.mem.Allocator, compression: u32) ![]u8 {
    const compressed = cameraPackedNibbles123456();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});
    try appendMinimalSubBlockAtPyramid(allocator, &out, gray16, &compressed, 1, 1, 1, null, 0, 0, 2, 1, 0, compression);
    return out.toOwnedSlice(allocator);
}

fn minimalCziWithCameraPackedTile(allocator: std.mem.Allocator, compression: u32) ![]u8 {
    const compressed = cameraPackedNibbles123456();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});
    try appendMinimalSubBlockAtPyramid(allocator, &out, gray16, &compressed, 1, 1, 1, null, 1, 0, 2, 1, 0, compression);
    return out.toOwnedSlice(allocator);
}

fn zstdRawBlock123() [12]u8 {
    return .{
        0x28, 0xb5, 0x2f, 0xfd,
        0x20, 0x03, 0x19, 0x00,
        0x00, 1,    2,    3,
    };
}

fn zstd1HighLowBlock() [16]u8 {
    return .{
        3,    1,    1,    0x28,
        0xb5, 0x2f, 0xfd, 0x20,
        0x04, 0x21, 0x00, 0x00,
        0x34, 0x78, 0x12, 0x56,
    };
}

fn cameraPackedNibbles123456() [3]u8 {
    return .{ 0x12, 0x34, 0x56 };
}

fn minimalCziWithMetadataXml(allocator: std.mem.Allocator, xml: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSegment(allocator, &out, czi_magic, &.{});
    try appendMetadataSegment(allocator, &out, xml);
    try appendMinimalSubBlockAt(allocator, &out, gray8, &.{ 1, 2, 3, 4 }, 1, 1, 1, null, 0, 0, 2, 2);
    return out.toOwnedSlice(allocator);
}

fn appendMetadataSegment(allocator: std.mem.Allocator, out: *std.ArrayList(u8), xml: []const u8) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try appendU32Le(allocator, &payload, @intCast(xml.len));
    try appendU32Le(allocator, &payload, 0);
    try appendZeros(allocator, &payload, 248);
    try payload.appendSlice(allocator, xml);
    try appendSegment(allocator, out, metadata_id, payload.items);
}

fn appendMinimalSubBlock(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    pixel_type: u32,
    pixels: []const u8,
    size_c: u32,
    size_z: u32,
    size_t: u32,
    scene: ?u32,
) !void {
    try appendMinimalSubBlockAtPyramid(allocator, out, pixel_type, pixels, size_c, size_z, size_t, scene, 0, 0, 11, 7, 0, uncompressed);
}

fn appendMinimalSubBlockAt(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    pixel_type: u32,
    pixels: []const u8,
    size_c: u32,
    size_z: u32,
    size_t: u32,
    scene: ?u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) !void {
    try appendMinimalSubBlockAtPyramid(allocator, out, pixel_type, pixels, size_c, size_z, size_t, scene, x, y, width, height, 0, uncompressed);
}

fn appendMinimalSubBlockAtPyramid(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    pixel_type: u32,
    pixels: []const u8,
    size_c: u32,
    size_z: u32,
    size_t: u32,
    scene: ?u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    pyramid_type: u8,
    compression: u32,
) !void {
    var sub: std.ArrayList(u8) = .empty;
    defer sub.deinit(allocator);
    try appendU32Le(allocator, &sub, 0);
    try appendU32Le(allocator, &sub, 0);
    try appendU64Le(allocator, &sub, @intCast(pixels.len));
    try sub.appendSlice(allocator, "DV");
    try appendU32Le(allocator, &sub, pixel_type);
    try appendU64Le(allocator, &sub, 0);
    try appendU32Le(allocator, &sub, 0);
    try appendU32Le(allocator, &sub, compression);
    try sub.append(allocator, pyramid_type);
    try sub.append(allocator, 0);
    try appendU32Le(allocator, &sub, 0);
    try appendU32Le(allocator, &sub, if (scene == null) 5 else 6);
    try appendDimension(allocator, &sub, "X", x, width);
    try appendDimension(allocator, &sub, "Y", y, height);
    try appendDimension(allocator, &sub, "C", 0, size_c);
    try appendDimension(allocator, &sub, "Z", 0, size_z);
    try appendDimension(allocator, &sub, "T", 0, size_t);
    if (scene) |index| try appendDimension(allocator, &sub, "S", index, 1);
    if (sub.items.len < 256) try appendZeros(allocator, &sub, 256 - sub.items.len);
    try sub.appendSlice(allocator, pixels);
    try appendSegment(allocator, out, subblock_id, sub.items);
}

test "reads zeiss czi subblock metadata" {
    const data = try minimalCzi(std.testing.allocator, gray16);
    defer std.testing.allocator.free(data);

    try std.testing.expect(matches(data));
    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings("zeissczi", metadata.format);
    try std.testing.expectEqual(@as(u32, 11), metadata.width);
    try std.testing.expectEqual(@as(u32, 7), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 4), metadata.size_t);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
}

test "reads zeiss czi metadata XML segment" {
    const xml = "<Metadata><Information ID=\"test\"/></Metadata>";
    const data = try minimalCziWithMetadataXml(std.testing.allocator, xml);
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqualStrings(xml, metadata.image_description.?);

    const file_path = "zeiss-czi-metadata-xml-test.czi";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });

    const path_metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    defer if (path_metadata.image_description) |description| std.testing.allocator.free(description);
    try std.testing.expectEqualStrings(xml, path_metadata.image_description.?);
}

test "reports bgr czi as rgb metadata" {
    const data = try minimalCzi(std.testing.allocator, bgr_24);
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
}

test "reads uncompressed bgr czi plane as rgb" {
    var pixels: [11 * 7 * 3]u8 = @splat(0);
    const stored = [_]u8{ 3, 2, 1, 6, 5, 4 };
    @memcpy(pixels[0..6], &stored);
    const data = try minimalCziWithPixels(std.testing.allocator, bgr_24, &pixels);
    defer std.testing.allocator.free(data);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgb8, plane.metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), plane.metadata.samples_per_pixel);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, plane.data[0..6]);

    const file_path = "zeiss-czi-bgr24-path-test.czi";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });

    const cropped = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 1, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(cropped.data);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, cropped.data);
}

test "reads uncompressed bgr48 czi plane as rgb16" {
    var pixels: [11 * 7 * 6]u8 = @splat(0);
    const stored = [_]u8{ 0x30, 0x31, 0x20, 0x21, 0x10, 0x11 };
    @memcpy(pixels[0..6], &stored);
    const data = try minimalCziWithPixels(std.testing.allocator, bgr_48, &pixels);
    defer std.testing.allocator.free(data);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgb16, plane.metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), plane.metadata.samples_per_pixel);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x11, 0x20, 0x21, 0x30, 0x31 }, plane.data[0..6]);
}

test "reads uncompressed bgra czi plane as rgba" {
    var pixels: [11 * 7 * 4]u8 = @splat(0);
    const stored = [_]u8{ 3, 2, 1, 4 };
    @memcpy(pixels[0..4], &stored);
    const data = try minimalCziWithPixels(std.testing.allocator, bgra_8, &pixels);
    defer std.testing.allocator.free(data);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgba8, plane.metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 4), plane.metadata.samples_per_pixel);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, plane.data[0..4]);
}

test "reads jpeg compressed full-size bgr czi subblock" {
    const data = try minimalCziWithJpegCompressedBlock(std.testing.allocator);
    defer std.testing.allocator.free(data);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.rgb8, plane.metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), plane.metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(usize, 3), plane.data.len);
    try std.testing.expect(plane.data[0] < 80);
    try std.testing.expect(plane.data[1] < 80);
    try std.testing.expect(plane.data[2] > 200);

    const file_path = "zeiss-czi-jpeg-compressed-test.czi";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });

    const path_plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(path_plane.data);
    try std.testing.expectEqualSlices(u8, plane.data, path_plane.data);
}

test "reads jpeg compressed czi tile by range" {
    const file_path = "zeiss-czi-jpeg-tile-test.czi";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    const data = try minimalCziWithJpegCompressedTile(std.testing.allocator);
    defer std.testing.allocator.free(data);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    defer if (metadata.image_description) |description| std.testing.allocator.free(description);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 1, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(@as(usize, 3), plane.data.len);
    try std.testing.expect(plane.data[0] < 80);
    try std.testing.expect(plane.data[1] < 80);
    try std.testing.expect(plane.data[2] > 200);
}

test "reads lzw compressed full-size czi subblock" {
    const data = try minimalCziWithLzwCompressedBlock(std.testing.allocator);
    defer std.testing.allocator.free(data);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.uint8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, plane.data);

    const file_path = "zeiss-czi-lzw-compressed-test.czi";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });

    const path_plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 1, .y = 0, .width = 2, .height = 1 });
    defer std.testing.allocator.free(path_plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3 }, path_plane.data);
}

test "reads lzw compressed czi tile by range" {
    const file_path = "zeiss-czi-lzw-tile-test.czi";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    const data = try minimalCziWithLzwCompressedTile(std.testing.allocator);
    defer std.testing.allocator.free(data);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    defer if (metadata.image_description) |description| std.testing.allocator.free(description);
    try std.testing.expectEqual(@as(u32, 4), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 2, .y = 0, .width = 2, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3 }, plane.data);
}

test "reads zstd-0 compressed full-size czi subblock" {
    const data = try minimalCziWithZstdCompressedBlock(std.testing.allocator);
    defer std.testing.allocator.free(data);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.uint8, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, plane.data);

    const file_path = "zeiss-czi-zstd-compressed-test.czi";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });

    const path_plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 1, .y = 0, .width = 2, .height = 1 });
    defer std.testing.allocator.free(path_plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3 }, path_plane.data);
}

test "reads zstd-0 compressed czi tile by range" {
    const file_path = "zeiss-czi-zstd-tile-test.czi";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    const data = try minimalCziWithZstdCompressedTile(std.testing.allocator);
    defer std.testing.allocator.free(data);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    defer if (metadata.image_description) |description| std.testing.allocator.free(description);
    try std.testing.expectEqual(@as(u32, 4), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 2, .y = 0, .width = 2, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3 }, plane.data);
}

test "reads zstd-1 high-low compressed full-size czi subblock" {
    const data = try minimalCziWithZstd1CompressedBlock(std.testing.allocator);
    defer std.testing.allocator.free(data);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.uint16, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0x78, 0x56 }, plane.data);

    const file_path = "zeiss-czi-zstd1-compressed-test.czi";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });

    const path_plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 1, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(path_plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56 }, path_plane.data);
}

test "reads zstd-1 high-low compressed czi tile by range" {
    const file_path = "zeiss-czi-zstd1-tile-test.czi";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    const data = try minimalCziWithZstd1CompressedTile(std.testing.allocator);
    defer std.testing.allocator.free(data);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    defer if (metadata.image_description) |description| std.testing.allocator.free(description);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 2, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56 }, plane.data);
}

test "reads camera-packed czi subblock compression 504" {
    const data = try minimalCziWithCameraPackedBlock(std.testing.allocator, camera_packed_compression);
    defer std.testing.allocator.free(data);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqual(bio.PixelType.uint16, plane.metadata.pixel_type);
    try std.testing.expect(!plane.metadata.little_endian);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x25, 0x03, 0x46 }, plane.data);

    const file_path = "zeiss-czi-camera-packed-504-test.czi";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });

    const path_plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 1, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(path_plane.data);
    try std.testing.expect(!path_plane.metadata.little_endian);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x46 }, path_plane.data);
}

test "reads camera-packed czi subblock compression 104 with reversed columns" {
    const data = try minimalCziWithCameraPackedBlock(std.testing.allocator, camera_packed_reversed_compression);
    defer std.testing.allocator.free(data);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expect(!plane.metadata.little_endian);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x46, 0x01, 0x25 }, plane.data);
}

test "reads camera-packed czi tile by range" {
    const file_path = "zeiss-czi-camera-packed-tile-test.czi";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    const data = try minimalCziWithCameraPackedTile(std.testing.allocator, camera_packed_compression);
    defer std.testing.allocator.free(data);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    defer if (metadata.image_description) |description| std.testing.allocator.free(description);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 2, .y = 0, .width = 1, .height = 1 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expect(!plane.metadata.little_endian);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x46 }, plane.data);
}

test "reads uncompressed zeiss czi subblock plane" {
    const pixels = [_]u8{ 1, 0 } ** (11 * 7);
    const data = try minimalCziWithPixels(std.testing.allocator, gray16, &pixels);
    defer std.testing.allocator.free(data);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zeissczi", plane.metadata.format);
    try std.testing.expectEqual(bio.PixelType.uint16, plane.metadata.pixel_type);
    try std.testing.expectEqualSlices(u8, &pixels, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data, 1));
}

test "maps zeiss czi scene dimension to series" {
    const scene0 = [_]u8{ 1, 0 } ** (11 * 7);
    const scene1 = [_]u8{ 2, 0 } ** (11 * 7);
    const data = try minimalCziWithScenePixels(std.testing.allocator, gray16, &scene0, &scene1);
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u32, 2), metadata.series_count);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane0 = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane0.data);
    try std.testing.expectEqualSlices(u8, &scene0, plane0.data);

    const file_path = "zeiss-czi-scene-series-test.czi";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });

    const path_metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    defer if (path_metadata.image_description) |description| std.testing.allocator.free(description);
    try std.testing.expectEqual(@as(u32, 2), path_metadata.series_count);
    try std.testing.expectEqual(@as(u32, 1), path_metadata.plane_count);

    const plane1 = try readPlanePathRegionSeriesIndex(std.testing.allocator, std.testing.io, file_path, 1, 0, .{ .x = 0, .y = 0, .width = 11, .height = 7 });
    defer std.testing.allocator.free(plane1.data);
    try std.testing.expectEqualSlices(u8, &scene1, plane1.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlanePathRegionSeriesIndex(std.testing.allocator, std.testing.io, file_path, 2, 0, .{ .x = 0, .y = 0, .width = 11, .height = 7 }));
}

test "reads zeiss czi path metadata and cropped plane by range" {
    const file_path = "zeiss-czi-path-range-test.czi";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var pixels: [11 * 7 * 2]u8 = undefined;
    for (0..11 * 7) |i| {
        std.mem.writeInt(u16, pixels[i * 2 ..][0..2], @intCast(i), .little);
    }
    const data = try minimalCziWithPixels(std.testing.allocator, gray16, &pixels);
    defer std.testing.allocator.free(data);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    defer if (metadata.image_description) |description| std.testing.allocator.free(description);
    try std.testing.expectEqual(@as(u32, 11), metadata.width);
    try std.testing.expectEqual(@as(u32, 7), metadata.height);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 1, .y = 1, .width = 3, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 12, 0, 13, 0, 14, 0, 23, 0, 24, 0, 25, 0 }, plane.data);
}

test "reads uncompressed tiled czi region by range" {
    const file_path = "zeiss-czi-tiled-region-test.czi";
    std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    const data = try minimalTiledCzi(std.testing.allocator);
    defer std.testing.allocator.free(data);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    defer if (metadata.image_description) |description| std.testing.allocator.free(description);
    try std.testing.expectEqual(@as(u32, 4), metadata.width);
    try std.testing.expectEqual(@as(u32, 4), metadata.height);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 0, .{ .x = 1, .y = 1, .width = 2, .height = 2 });
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 6, 7, 10, 11 }, plane.data);
}

test "ignores czi pyramid subblocks for base metadata and reads" {
    const data = try minimalCziWithPyramidSubBlock(std.testing.allocator);
    defer std.testing.allocator.free(data);

    const metadata = try readMetadata(data);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, plane.data);
}

test "matches Bio-Formats core metadata for cached CZI fixture" {
    const file_path = "fixtures/cache/zeissczi/Plate1-Blue-A-02-Scene-1-P2-E1-01.czi";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const metadata = try readMetadataPath(std.testing.allocator, std.testing.io, file_path);
    defer if (metadata.image_description) |description| std.testing.allocator.free(description);
    try std.testing.expectEqualStrings("zeissczi", metadata.format);
    try std.testing.expectEqual(@as(u32, 672), metadata.width);
    try std.testing.expectEqual(@as(u32, 512), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.size_c);
    try std.testing.expectEqual(@as(u16, 21), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 1), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 63), metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 1), metadata.series_count);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);
    try std.testing.expectEqualStrings("XYCZT", metadata.dimension_order.?);
}

test "matches Bio-Formats full-plane hashes for cached CZI fixture" {
    const file_path = "fixtures/cache/zeissczi/Plate1-Blue-A-02-Scene-1-P2-E1-01.czi";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const expected = [_]struct { plane: u32, sha256: [32]u8 }{
        .{ .plane = 0, .sha256 = .{ 0x6b, 0x77, 0xf8, 0x19, 0xb0, 0x45, 0xb3, 0xec, 0x64, 0xad, 0xa1, 0x2c, 0x0c, 0x47, 0xbe, 0xa7, 0x4e, 0xbd, 0xef, 0x8c, 0x86, 0x7c, 0x15, 0xac, 0xf6, 0x78, 0xf2, 0xc5, 0x2c, 0xcb, 0x6f, 0x1e } },
        .{ .plane = 31, .sha256 = .{ 0x12, 0x3d, 0x60, 0x5f, 0x92, 0xfb, 0xdd, 0x7c, 0xc3, 0x4b, 0x62, 0x33, 0xf2, 0x0f, 0x7a, 0x5c, 0xcb, 0x03, 0x90, 0x9f, 0x11, 0x00, 0x49, 0x6c, 0x2f, 0xef, 0x91, 0xfd, 0xb3, 0x05, 0x07, 0xb4 } },
        .{ .plane = 62, .sha256 = .{ 0xb7, 0xd9, 0x9f, 0x88, 0x3d, 0x03, 0x0e, 0xca, 0xf1, 0x3e, 0x6d, 0x60, 0x1a, 0x39, 0x59, 0xf5, 0x3c, 0x2c, 0xda, 0xae, 0x61, 0xcd, 0x36, 0x9c, 0x02, 0x21, 0xa5, 0xc2, 0x90, 0xf6, 0x3c, 0xbf } },
    };
    for (expected) |sample| {
        const plane = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, sample.plane, .{ .x = 0, .y = 0, .width = 672, .height = 512 });
        defer std.testing.allocator.free(plane.data);
        try std.testing.expectEqual(@as(usize, 688128), plane.data.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plane.data, &digest, .{});
        try std.testing.expectEqualSlices(u8, &sample.sha256, &digest);
    }
}

test "cached CZI path region read matches full-plane crop" {
    const file_path = "fixtures/cache/zeissczi/Plate1-Blue-A-02-Scene-1-P2-E1-01.czi";
    std.Io.Dir.cwd().access(std.testing.io, file_path, .{}) catch return;

    const region: bio.Region = .{ .x = 2, .y = 3, .width = 4, .height = 2 };
    const full = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 31, .{ .x = 0, .y = 0, .width = 672, .height = 512 });
    defer std.testing.allocator.free(full.data);
    const expected = try bio.cropPlane(std.testing.allocator, full, region);
    defer std.testing.allocator.free(expected);

    const cropped = try readPlanePathRegionIndex(std.testing.allocator, std.testing.io, file_path, 31, region);
    defer std.testing.allocator.free(cropped.data);
    try std.testing.expectEqualSlices(u8, expected, cropped.data);
}
