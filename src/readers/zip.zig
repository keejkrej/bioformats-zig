const std = @import("std");
const bio = @import("../root.zig");
const aim = @import("aim.zig");
const alicona = @import("alicona.zig");
const amira = @import("amira.zig");
const apng = @import("apng.zig");
const arf = @import("arf.zig");
const avi = @import("avi.zig");
const bdpathway = @import("bdpathway.zig");
const biorad = @import("biorad.zig");
const bioradgel = @import("bioradgel.zig");
const bioradscn = @import("bioradscn.zig");
const bmp = @import("bmp.zig");
const burleigh = @import("burleigh.zig");
const cellomics = @import("cellomics.zig");
const dcimg = @import("dcimg.zig");
const deltavision = @import("deltavision.zig");
const dicom = @import("dicom.zig");
const ecat7 = @import("ecat7.zig");
const eps = @import("eps.zig");
const fei = @import("fei.zig");
const feitiff = @import("feitiff.zig");
const fits = @import("fits.zig");
const fluoview = @import("fluoview.zig");
const gatandm2 = @import("gatandm2.zig");
const gif = @import("gif.zig");
const his = @import("his.zig");
const hrdgdf = @import("hrdgdf.zig");
const i2i = @import("i2i.zig");
const imacon = @import("imacon.zig");
const imaris = @import("imaris.zig");
const imod = @import("imod.zig");
const improvisiontiff = @import("improvisiontiff.zig");
const inr = @import("inr.zig");
const ionpathmibi = @import("ionpathmibi.zig");
const iplab = @import("iplab.zig");
const ivision = @import("ivision.zig");
const jeol = @import("jeol.zig");
const khoros = @import("khoros.zig");
const klb = @import("klb.zig");
const kodak = @import("kodak.zig");
const leo = @import("leo.zig");
const liflim = @import("liflim.zig");
const lim = @import("lim.zig");
const metamorph = @import("metamorph.zig");
const mng = @import("mng.zig");
const microct = @import("microct.zig");
const mikroscan = @import("mikroscan.zig");
const mias = @import("mias.zig");
const molecularimaging = @import("molecularimaging.zig");
const mrc = @import("mrc.zig");
const mrw = @import("mrw.zig");
const netpbm = @import("netpbm.zig");
const nifti = @import("nifti.zig");
const nikonelements = @import("nikonelements.zig");
const nikontiff = @import("nikontiff.zig");
const nrrd = @import("nrrd.zig");
const omexml = @import("omexml.zig");
const openlabraw = @import("openlabraw.zig");
const ometiff = @import("ometiff.zig");
const oxfordinstruments = @import("oxfordinstruments.zig");
const pcx = @import("pcx.zig");
const photoshoptiff = @import("photoshoptiff.zig");
const png = @import("png.zig");
const povray = @import("povray.zig");
const pqbin = @import("pqbin.zig");
const psd = @import("psd.zig");
const quesant = @import("quesant.zig");
const rhk = @import("rhk.zig");
const sbig = @import("sbig.zig");
const seiko = @import("seiko.zig");
const seq = @import("seq.zig");
const sif = @import("sif.zig");
const simplepci = @import("simplepci.zig");
const sis = @import("sis.zig");
const slidebooktiff = @import("slidebooktiff.zig");
const smcamera = @import("smcamera.zig");
const spe = @import("spe.zig");
const spider = @import("spider.zig");
const svs = @import("svs.zig");
const tcs = @import("tcs.zig");
const tga = @import("tga.zig");
const text = @import("text.zig");
const tiff = @import("tiff.zig");
const topometrix = @import("topometrix.zig");
const trestle = @import("trestle.zig");
const ubm = @import("ubm.zig");
const varianfdf = @import("varianfdf.zig");
const vectra = @import("vectra.zig");
const ventana = @import("ventana.zig");
const vgsam = @import("vgsam.zig");
const watop = @import("watop.zig");
const zeisslms = @import("zeisslms.zig");
const zeisslsm = @import("zeisslsm.zig");

const local_sig = [_]u8{ 'P', 'K', 3, 4 };
const method_store: u16 = 0;
const method_deflate: u16 = 8;
const flag_encrypted: u16 = 1 << 0;
const flag_data_descriptor: u16 = 1 << 3;

const Entry = struct {
    data: []const u8,
    kind: Kind,
    owned: bool = false,

    const Kind = enum { aim, alicona, amira, apng, arf, avi, bdpathway, biorad, bioradgel, bioradscn, bmp, burleigh, cellomics, dcimg, deltavision, dicom, ecat7, eps, fei, feitiff, fits, fluoview, gatandm2, gif, his, hrdgdf, i2i, imacon, imaris, imod, improvisiontiff, inr, ionpathmibi, iplab, ivision, jeol, khoros, klb, kodak, leo, liflim, lim, metamorph, mias, microct, mikroscan, mng, molecularimaging, mrc, mrw, netpbm, nifti, nikonelements, nikontiff, nrrd, omexml, openlabraw, ometiff, oxfordinstruments, pcx, photoshoptiff, png, povray, pqbin, psd, quesant, rhk, sbig, seiko, seq, sif, simplepci, sis, slidebooktiff, smcamera, spe, spider, svs, tcs, text, tga, tiff, topometrix, trestle, ubm, varianfdf, vectra, ventana, vgsam, watop, zeisslms, zeisslsm };

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.data);
    }
};

pub fn matches(data: []const u8) bool {
    return data.len >= local_sig.len and std.mem.eql(u8, data[0..local_sig.len], &local_sig);
}

pub fn readMetadata(data: []const u8) bio.ReaderError!bio.Metadata {
    const entry = try firstSupportedEntry(std.heap.page_allocator, data);
    defer entry.deinit(std.heap.page_allocator);
    var metadata = try readInnerMetadata(entry);
    metadata.format = "zip";
    return metadata;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!bio.Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) bio.ReaderError!bio.Plane {
    const entry = try firstSupportedEntry(allocator, data);
    defer entry.deinit(allocator);
    var plane = try readInnerPlaneIndex(allocator, entry, plane_index);
    plane.metadata.format = "zip";
    return plane;
}

pub fn readRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    const entry = try firstSupportedEntry(allocator, data);
    defer entry.deinit(allocator);
    var plane = try readInnerRegionIndex(allocator, entry, plane_index, region);
    plane.metadata.format = "zip";
    return plane;
}

fn readInnerMetadata(entry: Entry) bio.ReaderError!bio.Metadata {
    return switch (entry.kind) {
        .aim => aim.readMetadata(entry.data),
        .alicona => alicona.readMetadata(entry.data),
        .amira => amira.readMetadata(entry.data),
        .apng => apng.readMetadata(entry.data),
        .arf => arf.readMetadata(entry.data),
        .avi => avi.readMetadata(entry.data),
        .bdpathway => bdpathway.readMetadata(entry.data),
        .biorad => biorad.readMetadata(entry.data),
        .bioradgel => bioradgel.readMetadata(entry.data),
        .bioradscn => bioradscn.readMetadata(entry.data),
        .bmp => bmp.readMetadata(entry.data),
        .burleigh => burleigh.readMetadata(entry.data),
        .cellomics => cellomics.readMetadata(entry.data),
        .dcimg => dcimg.readMetadata(entry.data),
        .deltavision => deltavision.readMetadata(entry.data),
        .dicom => dicom.readMetadata(entry.data),
        .ecat7 => ecat7.readMetadata(entry.data),
        .eps => eps.readMetadata(entry.data),
        .fei => fei.readMetadata(entry.data),
        .feitiff => feitiff.readMetadata(entry.data),
        .fits => fits.readMetadata(entry.data),
        .fluoview => fluoview.readMetadata(entry.data),
        .gatandm2 => gatandm2.readMetadata(entry.data),
        .gif => gif.readMetadata(entry.data),
        .his => his.readMetadata(entry.data),
        .hrdgdf => hrdgdf.readMetadata(entry.data),
        .i2i => i2i.readMetadata(entry.data),
        .imacon => imacon.readMetadata(entry.data),
        .imaris => imaris.readMetadata(entry.data),
        .imod => imod.readMetadata(entry.data),
        .improvisiontiff => improvisiontiff.readMetadata(entry.data),
        .inr => inr.readMetadata(entry.data),
        .ionpathmibi => ionpathmibi.readMetadata(entry.data),
        .iplab => iplab.readMetadata(entry.data),
        .ivision => ivision.readMetadata(entry.data),
        .jeol => jeol.readMetadata(entry.data),
        .khoros => khoros.readMetadata(entry.data),
        .klb => klb.readMetadata(entry.data),
        .kodak => kodak.readMetadata(entry.data),
        .leo => leo.readMetadata(entry.data),
        .liflim => liflim.readMetadata(entry.data),
        .lim => lim.readMetadata(entry.data),
        .metamorph => metamorph.readMetadata(entry.data),
        .mias => mias.readMetadata(entry.data),
        .microct => microct.readMetadata(entry.data),
        .mikroscan => mikroscan.readMetadata(entry.data),
        .mng => mng.readMetadata(entry.data),
        .molecularimaging => molecularimaging.readMetadata(entry.data),
        .mrc => mrc.readMetadata(entry.data),
        .mrw => mrw.readMetadata(entry.data),
        .netpbm => netpbm.readMetadata(entry.data),
        .nifti => nifti.readMetadata(entry.data),
        .nikonelements => nikonelements.readMetadata(entry.data),
        .nikontiff => nikontiff.readMetadata(entry.data),
        .nrrd => nrrd.readMetadata(entry.data),
        .omexml => omexml.readMetadata(entry.data),
        .openlabraw => openlabraw.readMetadata(entry.data),
        .ometiff => ometiff.readMetadata(entry.data),
        .oxfordinstruments => oxfordinstruments.readMetadata(entry.data),
        .pcx => pcx.readMetadata(entry.data),
        .photoshoptiff => photoshoptiff.readMetadata(entry.data),
        .png => png.readMetadata(entry.data),
        .povray => povray.readMetadata(entry.data),
        .pqbin => pqbin.readMetadata(entry.data),
        .psd => psd.readMetadata(entry.data),
        .quesant => quesant.readMetadata(entry.data),
        .rhk => rhk.readMetadata(entry.data),
        .sbig => sbig.readMetadata(entry.data),
        .seiko => seiko.readMetadata(entry.data),
        .seq => seq.readMetadata(entry.data),
        .sif => sif.readMetadata(entry.data),
        .simplepci => simplepci.readMetadata(entry.data),
        .sis => sis.readMetadata(entry.data),
        .slidebooktiff => slidebooktiff.readMetadata(entry.data),
        .smcamera => smcamera.readMetadata(entry.data),
        .spe => spe.readMetadata(entry.data),
        .spider => spider.readMetadata(entry.data),
        .svs => svs.readMetadata(entry.data),
        .tcs => tcs.readMetadata(entry.data),
        .text => text.readMetadata(entry.data),
        .tga => tga.readMetadata(entry.data),
        .tiff => tiff.readMetadata(entry.data),
        .topometrix => topometrix.readMetadata(entry.data),
        .trestle => trestle.readMetadata(entry.data),
        .ubm => ubm.readMetadata(entry.data),
        .varianfdf => varianfdf.readMetadata(entry.data),
        .vectra => vectra.readMetadata(entry.data),
        .ventana => ventana.readMetadata(entry.data),
        .vgsam => vgsam.readMetadata(entry.data),
        .watop => watop.readMetadata(entry.data),
        .zeisslms => zeisslms.readMetadata(entry.data),
        .zeisslsm => zeisslsm.readMetadata(entry.data),
    };
}

fn readInnerPlaneIndex(allocator: std.mem.Allocator, entry: Entry, plane_index: u32) bio.ReaderError!bio.Plane {
    return switch (entry.kind) {
        .aim => aim.readPlaneIndex(allocator, entry.data, plane_index),
        .alicona => alicona.readPlaneIndex(allocator, entry.data, plane_index),
        .amira => amira.readPlaneIndex(allocator, entry.data, plane_index),
        .apng => apng.readPlaneIndex(allocator, entry.data, plane_index),
        .arf => arf.readPlaneIndex(allocator, entry.data, plane_index),
        .avi => avi.readPlaneIndex(allocator, entry.data, plane_index),
        .bdpathway => bdpathway.readPlaneIndex(allocator, entry.data, plane_index),
        .biorad => biorad.readPlaneIndex(allocator, entry.data, plane_index),
        .bioradgel => bioradgel.readPlaneIndex(allocator, entry.data, plane_index),
        .bioradscn => bioradscn.readPlaneIndex(allocator, entry.data, plane_index),
        .bmp => if (plane_index == 0) bmp.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .burleigh => if (plane_index == 0) burleigh.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .cellomics => cellomics.readPlaneIndex(allocator, entry.data, plane_index),
        .dcimg => dcimg.readPlaneIndex(allocator, entry.data, plane_index),
        .deltavision => deltavision.readPlaneIndex(allocator, entry.data, plane_index),
        .dicom => dicom.readPlaneIndex(allocator, entry.data, plane_index),
        .ecat7 => ecat7.readPlaneIndex(allocator, entry.data, plane_index),
        .eps => if (plane_index == 0) eps.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .fei => if (plane_index == 0) fei.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .feitiff => feitiff.readPlaneIndex(allocator, entry.data, plane_index),
        .fits => fits.readPlaneIndex(allocator, entry.data, plane_index),
        .fluoview => fluoview.readPlaneIndex(allocator, entry.data, plane_index),
        .gatandm2 => gatandm2.readPlaneIndex(allocator, entry.data, plane_index),
        .gif => gif.readPlaneIndex(allocator, entry.data, plane_index),
        .his => if (plane_index == 0) his.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .hrdgdf => hrdgdf.readPlaneIndex(allocator, entry.data, plane_index),
        .i2i => i2i.readPlaneIndex(allocator, entry.data, plane_index),
        .imacon => imacon.readPlaneIndex(allocator, entry.data, plane_index),
        .imaris => imaris.readPlaneIndex(allocator, entry.data, plane_index),
        .imod => imod.readPlaneIndex(allocator, entry.data, plane_index),
        .improvisiontiff => improvisiontiff.readPlaneIndex(allocator, entry.data, plane_index),
        .inr => inr.readPlaneIndex(allocator, entry.data, plane_index),
        .ionpathmibi => ionpathmibi.readPlaneIndex(allocator, entry.data, plane_index),
        .iplab => iplab.readPlaneIndex(allocator, entry.data, plane_index),
        .ivision => ivision.readPlaneIndex(allocator, entry.data, plane_index),
        .jeol => if (plane_index == 0) jeol.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .khoros => khoros.readPlaneIndex(allocator, entry.data, plane_index),
        .klb => klb.readPlaneIndex(allocator, entry.data, plane_index),
        .kodak => if (plane_index == 0) kodak.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .leo => leo.readPlaneIndex(allocator, entry.data, plane_index),
        .liflim => liflim.readPlaneIndex(allocator, entry.data, plane_index),
        .lim => if (plane_index == 0) lim.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .metamorph => metamorph.readPlaneIndex(allocator, entry.data, plane_index),
        .mias => mias.readPlaneIndex(allocator, entry.data, plane_index),
        .microct => microct.readPlaneIndex(allocator, entry.data, plane_index),
        .mikroscan => mikroscan.readPlaneIndex(allocator, entry.data, plane_index),
        .mng => mng.readPlaneIndex(allocator, entry.data, plane_index),
        .molecularimaging => molecularimaging.readPlaneIndex(allocator, entry.data, plane_index),
        .mrc => mrc.readPlaneIndex(allocator, entry.data, plane_index),
        .mrw => mrw.readPlaneIndex(allocator, entry.data, plane_index),
        .netpbm => if (plane_index == 0) netpbm.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .nifti => nifti.readPlaneIndex(allocator, entry.data, plane_index),
        .nikonelements => nikonelements.readPlaneIndex(allocator, entry.data, plane_index),
        .nikontiff => nikontiff.readPlaneIndex(allocator, entry.data, plane_index),
        .nrrd => nrrd.readPlaneIndex(allocator, entry.data, plane_index),
        .omexml => omexml.readPlaneIndex(allocator, entry.data, plane_index),
        .openlabraw => openlabraw.readPlaneIndex(allocator, entry.data, plane_index),
        .ometiff => ometiff.readPlaneIndex(allocator, entry.data, plane_index),
        .oxfordinstruments => oxfordinstruments.readPlaneIndex(allocator, entry.data, plane_index),
        .pcx => if (plane_index == 0) pcx.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .photoshoptiff => photoshoptiff.readPlaneIndex(allocator, entry.data, plane_index),
        .png => if (plane_index == 0) png.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .povray => povray.readPlaneIndex(allocator, entry.data, plane_index),
        .pqbin => pqbin.readPlaneIndex(allocator, entry.data, plane_index),
        .psd => if (plane_index == 0) psd.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .quesant => if (plane_index == 0) quesant.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .rhk => if (plane_index == 0) rhk.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .sbig => if (plane_index == 0) sbig.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .seiko => if (plane_index == 0) seiko.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .seq => seq.readPlaneIndex(allocator, entry.data, plane_index),
        .sif => sif.readPlaneIndex(allocator, entry.data, plane_index),
        .simplepci => simplepci.readPlaneIndex(allocator, entry.data, plane_index),
        .sis => sis.readPlaneIndex(allocator, entry.data, plane_index),
        .slidebooktiff => slidebooktiff.readPlaneIndex(allocator, entry.data, plane_index),
        .smcamera => if (plane_index == 0) smcamera.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .spe => spe.readPlaneIndex(allocator, entry.data, plane_index),
        .spider => spider.readPlaneIndex(allocator, entry.data, plane_index),
        .svs => svs.readPlaneIndex(allocator, entry.data, plane_index),
        .tcs => tcs.readPlaneIndex(allocator, entry.data, plane_index),
        .text => text.readPlaneIndex(allocator, entry.data, plane_index),
        .tga => if (plane_index == 0) tga.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .tiff => tiff.readPlaneIndex(allocator, entry.data, plane_index),
        .topometrix => if (plane_index == 0) topometrix.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .trestle => trestle.readPlaneIndex(allocator, entry.data, plane_index),
        .ubm => if (plane_index == 0) ubm.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .varianfdf => varianfdf.readPlaneIndex(allocator, entry.data, plane_index),
        .vectra => vectra.readPlaneIndex(allocator, entry.data, plane_index),
        .ventana => ventana.readPlaneIndex(allocator, entry.data, plane_index),
        .vgsam => if (plane_index == 0) vgsam.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .watop => if (plane_index == 0) watop.readPlane(allocator, entry.data) else error.InvalidPlaneIndex,
        .zeisslms => zeisslms.readPlaneIndex(allocator, entry.data, plane_index),
        .zeisslsm => zeisslsm.readPlaneIndex(allocator, entry.data, plane_index),
    };
}

fn readInnerRegionIndex(
    allocator: std.mem.Allocator,
    entry: Entry,
    plane_index: u32,
    region: bio.Region,
) bio.ReaderError!bio.Plane {
    if (entry.kind == .ometiff) return ometiff.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .bdpathway) return bdpathway.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .feitiff) return feitiff.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .fluoview) return fluoview.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .imacon) return imacon.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .improvisiontiff) return improvisiontiff.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .ionpathmibi) return ionpathmibi.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .leo) return leo.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .metamorph) return metamorph.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .mias) return mias.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .mikroscan) return mikroscan.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .nikonelements) return nikonelements.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .nikontiff) return nikontiff.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .trestle) return trestle.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .photoshoptiff) return photoshoptiff.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .seq) return seq.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .simplepci) return simplepci.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .sis) return sis.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .slidebooktiff) return slidebooktiff.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .svs) return svs.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .tcs) return tcs.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .vectra) return vectra.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .ventana) return ventana.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .zeisslsm) return zeisslsm.readRegionIndex(allocator, entry.data, plane_index, region);
    if (entry.kind == .tiff) return tiff.readRegionIndex(allocator, entry.data, plane_index, region);

    const plane = try readInnerPlaneIndex(allocator, entry, plane_index);
    errdefer allocator.free(plane.data);
    try region.validate(plane.metadata);
    if (region.isFull(plane.metadata)) return plane;
    defer allocator.free(plane.data);
    return .{
        .metadata = plane.metadata,
        .data = try cropPlane(allocator, plane, region),
    };
}

fn firstSupportedEntry(allocator: std.mem.Allocator, data: []const u8) bio.ReaderError!Entry {
    if (!matches(data)) return error.InvalidFormat;
    var offset: usize = 0;
    while (offset + 30 <= data.len) {
        if (!std.mem.eql(u8, data[offset..][0..4], &local_sig)) break;
        const flags = readU16(data, offset + 6);
        const method = readU16(data, offset + 8);
        const compressed_size = try checkedUsize(readU32(data, offset + 18));
        const uncompressed_size = try checkedUsize(readU32(data, offset + 22));
        const name_len = try checkedUsize(readU16(data, offset + 26));
        const extra_len = try checkedUsize(readU16(data, offset + 28));
        const data_offset = std.math.add(usize, offset + 30, std.math.add(usize, name_len, extra_len) catch return error.UnsupportedVariant) catch return error.UnsupportedVariant;
        if (data_offset > data.len) return error.TruncatedData;
        if (data.len - data_offset < compressed_size) return error.TruncatedData;
        const payload = data[data_offset..][0..compressed_size];
        const filename = data[offset + 30 ..][0..name_len];

        if (filename.len == 0 or filename[filename.len - 1] == '/') {
            // Directory entry.
        } else if ((flags & flag_encrypted) != 0 or (flags & flag_data_descriptor) != 0) {
            return error.UnsupportedVariant;
        } else if (method == method_store) {
            if (compressed_size != uncompressed_size) return error.InvalidFormat;
            if (detectInner(filename, payload)) |kind| return .{ .data = payload, .kind = kind };
        } else if (method == method_deflate) {
            const inflated = try inflateRaw(allocator, payload, uncompressed_size);
            if (detectInner(filename, inflated)) |kind| return .{ .data = inflated, .kind = kind, .owned = true };
            allocator.free(inflated);
        }

        offset = data_offset + compressed_size;
    }
    return error.UnsupportedFormat;
}

fn detectInner(filename: []const u8, data: []const u8) ?Entry.Kind {
    if (aim.matches(data)) return .aim;
    if (alicona.matches(data)) return .alicona;
    if (amira.matches(data)) return .amira;
    if (apng.matches(data)) return .apng;
    if (arf.matches(data)) return .arf;
    if (avi.matches(data)) return .avi;
    if (bdpathway.matches(data)) return .bdpathway;
    if (biorad.matches(data)) return .biorad;
    if (bioradgel.matches(data)) return .bioradgel;
    if (bioradscn.matches(data)) return .bioradscn;
    if (bmp.matches(data)) return .bmp;
    if (hasExtension(filename, ".img") and burleigh.matches(data)) return .burleigh;
    if (hasCellomicsExtension(filename) and cellomics.matches(data)) return .cellomics;
    if (dcimg.matches(data)) return .dcimg;
    if (hasDeltavisionExtension(filename) and deltavision.matches(data)) return .deltavision;
    if (dicom.matches(data)) return .dicom;
    if (ecat7.matches(data)) return .ecat7;
    if (eps.matches(data)) return .eps;
    if (hasExtension(filename, ".img") and fei.matches(data)) return .fei;
    if (feitiff.matches(data)) return .feitiff;
    if (fits.matches(data)) return .fits;
    if (fluoview.matches(data)) return .fluoview;
    if (gatandm2.matches(data)) return .gatandm2;
    if (gif.matches(data)) return .gif;
    if (his.matches(data)) return .his;
    if (hrdgdf.matches(data)) return .hrdgdf;
    if (hasExtension(filename, ".i2i") and i2i.matches(data)) return .i2i;
    if (imacon.matches(data)) return .imacon;
    if (imaris.matches(data)) return .imaris;
    if (imod.matches(data)) return .imod;
    if (improvisiontiff.matches(data)) return .improvisiontiff;
    if (inr.matches(data)) return .inr;
    if (ionpathmibi.matches(data)) return .ionpathmibi;
    if (hasExtension(filename, ".ipl") and iplab.matches(data)) return .iplab;
    if (hasExtension(filename, ".ipm") and ivision.matches(data)) return .ivision;
    if (jeol.matches(data)) return .jeol;
    if (hasExtension(filename, ".xv") and khoros.matches(data)) return .khoros;
    if (klb.matches(data)) return .klb;
    if (kodak.matches(data)) return .kodak;
    if (leo.matches(data)) return .leo;
    if (hasExtension(filename, ".fli") and liflim.matches(data)) return .liflim;
    if (hasExtension(filename, ".lim") and lim.matches(data)) return .lim;
    if (microct.matches(data)) return .microct;
    if (mikroscan.matches(data)) return .mikroscan;
    if (mng.matches(data)) return .mng;
    if (molecularimaging.matches(data)) return .molecularimaging;
    if (hasMrcExtension(filename) and mrc.matches(data)) return .mrc;
    if (mrw.matches(data)) return .mrw;
    if (netpbm.matches(data)) return .netpbm;
    if (nifti.matches(data)) return .nifti;
    if (nikonelements.matches(data)) return .nikonelements;
    if (nikontiff.matches(data)) return .nikontiff;
    if (nrrd.matches(data)) return .nrrd;
    if (omexml.matches(data)) return .omexml;
    if (openlabraw.matches(data)) return .openlabraw;
    if (ometiff.matches(data)) return .ometiff;
    if (oxfordinstruments.matches(data)) return .oxfordinstruments;
    if (pcx.matches(data)) return .pcx;
    if (png.matches(data)) return .png;
    if (photoshoptiff.matches(data)) return .photoshoptiff;
    if (hasExtension(filename, ".df3") and povray.matches(data)) return .povray;
    if (hasExtension(filename, ".bin") and pqbin.matches(data)) return .pqbin;
    if (psd.matches(data)) return .psd;
    if (quesant.matches(data)) return .quesant;
    if (rhk.matches(data)) return .rhk;
    if (sbig.matches(data)) return .sbig;
    if (seiko.matches(data)) return .seiko;
    if (seq.matches(data)) return .seq;
    if (sif.matches(data)) return .sif;
    if (simplepci.matches(data)) return .simplepci;
    if (sis.matches(data)) return .sis;
    if (slidebooktiff.matches(data)) return .slidebooktiff;
    if (smcamera.matches(data)) return .smcamera;
    if (hasExtension(filename, ".spe") and spe.matches(data)) return .spe;
    if (hasExtension(filename, ".spi") and spider.matches(data)) return .spider;
    if (svs.matches(data)) return .svs;
    if (tcs.matches(data)) return .tcs;
    if (text.matches(data)) return .text;
    if (hasExtension(filename, ".tga") and tga.matches(data)) return .tga;
    if (metamorph.matches(data)) return .metamorph;
    if (mias.matches(data)) return .mias;
    if (trestle.matches(data)) return .trestle;
    if (vectra.matches(data)) return .vectra;
    if (ventana.matches(data)) return .ventana;
    if (zeisslsm.matches(data)) return .zeisslsm;
    if (tiff.matches(data)) return .tiff;
    if (topometrix.matches(data)) return .topometrix;
    if (hasExtension(filename, ".pr3") and ubm.matches(data)) return .ubm;
    if (varianfdf.matches(data)) return .varianfdf;
    if (vgsam.matches(data)) return .vgsam;
    if (watop.matches(data)) return .watop;
    if (zeisslms.matches(data)) return .zeisslms;
    return null;
}

fn hasExtension(filename: []const u8, extension: []const u8) bool {
    if (filename.len < extension.len) return false;
    const suffix = filename[filename.len - extension.len ..];
    return std.ascii.eqlIgnoreCase(suffix, extension);
}

fn hasMrcExtension(filename: []const u8) bool {
    return hasExtension(filename, ".mrc") or
        hasExtension(filename, ".mrcs") or
        hasExtension(filename, ".st") or
        hasExtension(filename, ".ali") or
        hasExtension(filename, ".map") or
        hasExtension(filename, ".rec");
}

fn hasCellomicsExtension(filename: []const u8) bool {
    return hasExtension(filename, ".c01") or hasExtension(filename, ".dib");
}

fn hasDeltavisionExtension(filename: []const u8) bool {
    return hasExtension(filename, ".dv") or
        hasExtension(filename, ".r3d") or
        hasExtension(filename, ".r3d_d3d");
}

fn inflateRaw(allocator: std.mem.Allocator, payload: []const u8, uncompressed_size: usize) bio.ReaderError![]u8 {
    var input = std.Io.Reader.fixed(payload);
    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&input, .raw, &buffer);
    const out = try allocator.alloc(u8, uncompressed_size);
    errdefer allocator.free(out);
    decompressor.reader.readSliceAll(out) catch return error.InvalidFormat;
    return out;
}

fn checkedUsize(value: u32) bio.ReaderError!usize {
    return std.math.cast(usize, value) orelse error.UnsupportedVariant;
}

fn cropPlane(allocator: std.mem.Allocator, plane: bio.Plane, region: bio.Region) bio.ReaderError![]u8 {
    try region.validate(plane.metadata);
    const bytes_per_pixel = plane.metadata.bytesPerPixel();
    const src_row_bytes = std.math.mul(usize, plane.metadata.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const dst_row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.UnsupportedVariant;
    const out_len = std.math.mul(usize, dst_row_bytes, region.height) catch return error.UnsupportedVariant;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    var row: usize = 0;
    while (row < region.height) : (row += 1) {
        const src_y = @as(usize, region.y) + row;
        const src_x = @as(usize, region.x) * bytes_per_pixel;
        const src_offset = src_y * src_row_bytes + src_x;
        const dst_offset = row * dst_row_bytes;
        @memcpy(out[dst_offset..][0..dst_row_bytes], plane.data[src_offset..][0..dst_row_bytes]);
    }

    return out;
}

fn readU16(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn writeU16(data: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, data[offset..][0..2], value, .little);
}

fn writeU32(data: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, data[offset..][0..4], value, .little);
}

fn writeI16Be(data: []u8, offset: usize, value: i16) void {
    std.mem.writeInt(i16, data[offset..][0..2], value, .big);
}

fn writeI32Be(data: []u8, offset: usize, value: i32) void {
    std.mem.writeInt(i32, data[offset..][0..4], value, .big);
}

fn appendU32Be(list: *std.ArrayList(u8), value: u32) !void {
    try list.append(std.testing.allocator, @intCast((value >> 24) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 16) & 0xff));
    try list.append(std.testing.allocator, @intCast((value >> 8) & 0xff));
    try list.append(std.testing.allocator, @intCast(value & 0xff));
}

fn appendU16Be(list: *std.ArrayList(u8), value: u16) !void {
    try list.append(std.testing.allocator, @intCast(value >> 8));
    try list.append(std.testing.allocator, @intCast(value & 0xff));
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

fn appendTiffEntry(list: *std.ArrayList(u8), tag: u16, field_type: u16, count: u32, value: u32) !void {
    try appendU16Le(list, tag);
    try appendU16Le(list, field_type);
    try appendU32Le(list, count);
    try appendU32Le(list, value);
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

fn appendPngChunk(list: *std.ArrayList(u8), kind: []const u8, bytes: []const u8) !void {
    try appendU32Be(list, @intCast(bytes.len));
    try list.appendSlice(std.testing.allocator, kind);
    try list.appendSlice(std.testing.allocator, bytes);
    var crc = std.hash.crc.Crc32.init();
    crc.update(kind);
    crc.update(bytes);
    try appendU32Be(list, crc.final());
}

fn appendZlibStored(list: *std.ArrayList(u8), bytes: []const u8) !void {
    try list.append(std.testing.allocator, 0x78);
    try list.append(std.testing.allocator, 0x01);
    try list.append(std.testing.allocator, 0x01);
    try list.append(std.testing.allocator, @intCast(bytes.len & 0xff));
    try list.append(std.testing.allocator, @intCast((bytes.len >> 8) & 0xff));
    const nlen: u16 = ~@as(u16, @intCast(bytes.len));
    try list.append(std.testing.allocator, @intCast(nlen & 0xff));
    try list.append(std.testing.allocator, @intCast((nlen >> 8) & 0xff));
    try list.appendSlice(std.testing.allocator, bytes);
    try appendU32Be(list, adler32(bytes));
}

fn adler32(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn appendStoredEntry(list: *std.ArrayList(u8), name: []const u8, payload: []const u8) !void {
    const offset = list.items.len;
    try list.appendNTimes(std.testing.allocator, 0, 30);
    @memcpy(list.items[offset..][0..4], &local_sig);
    writeU16(list.items, offset + 4, 20);
    writeU16(list.items, offset + 8, method_store);
    writeU32(list.items, offset + 18, @intCast(payload.len));
    writeU32(list.items, offset + 22, @intCast(payload.len));
    writeU16(list.items, offset + 26, @intCast(name.len));
    try list.appendSlice(std.testing.allocator, name);
    try list.appendSlice(std.testing.allocator, payload);
}

fn appendEntryWithMethod(list: *std.ArrayList(u8), method: u16, name: []const u8, payload: []const u8) !void {
    try appendEntryWithSizes(list, method, name, payload, payload.len);
}

fn appendEntryWithSizes(list: *std.ArrayList(u8), method: u16, name: []const u8, payload: []const u8, uncompressed_size: usize) !void {
    const offset = list.items.len;
    try list.appendNTimes(std.testing.allocator, 0, 30);
    @memcpy(list.items[offset..][0..4], &local_sig);
    writeU16(list.items, offset + 4, 20);
    writeU16(list.items, offset + 8, method);
    writeU32(list.items, offset + 18, @intCast(payload.len));
    writeU32(list.items, offset + 22, @intCast(uncompressed_size));
    writeU16(list.items, offset + 26, @intCast(name.len));
    try list.appendSlice(std.testing.allocator, name);
    try list.appendSlice(std.testing.allocator, payload);
}

fn appendFitsCard(list: *std.ArrayList(u8), key: []const u8, value: ?[]const u8) !void {
    const start = list.items.len;
    try list.appendNTimes(std.testing.allocator, ' ', 80);
    @memcpy(list.items[start..][0..key.len], key);
    if (value) |v| {
        list.items[start + 8] = '=';
        list.items[start + 9] = ' ';
        @memcpy(list.items[start + 10 ..][0..v.len], v);
    }
}

fn appendFitsHeader(list: *std.ArrayList(u8), bitpix: []const u8, width: []const u8, height: []const u8, planes: ?[]const u8) !void {
    try appendFitsCard(list, "SIMPLE", "T");
    try appendFitsCard(list, "BITPIX", bitpix);
    try appendFitsCard(list, "NAXIS", if (planes == null) "2" else "3");
    try appendFitsCard(list, "NAXIS1", width);
    try appendFitsCard(list, "NAXIS2", height);
    if (planes) |z| try appendFitsCard(list, "NAXIS3", z);
    try appendFitsCard(list, "END", null);
    const block_len = 2880;
    const padding = ((list.items.len + block_len - 1) / block_len) * block_len - list.items.len;
    try list.appendNTimes(std.testing.allocator, ' ', padding);
}

fn appendAliconaRecord(list: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    const record = try list.addManyAsSlice(std.testing.allocator, 52);
    @memset(record, ' ');
    @memcpy(record[0..@min(key.len, 20)], key[0..@min(key.len, 20)]);
    @memcpy(record[20..][0..@min(value.len, 30)], value[0..@min(value.len, 30)]);
    record[50] = '\r';
    record[51] = '\n';
}

fn appendAviChunk(list: *std.ArrayList(u8), fourcc: []const u8) !usize {
    try list.appendSlice(std.testing.allocator, fourcc);
    const size_pos = list.items.len;
    try appendU32Le(list, 0);
    return size_pos;
}

fn finishAviChunk(list: *std.ArrayList(u8), size_pos: usize) !void {
    const size = list.items.len - size_pos - 4;
    std.mem.writeInt(u32, list.items[size_pos..][0..4], @intCast(size), .little);
    if ((size & 1) != 0) try list.append(std.testing.allocator, 0);
}

fn appendTinyAvi(list: *std.ArrayList(u8)) !void {
    const riff = try appendAviChunk(list, "RIFF");
    try list.appendSlice(std.testing.allocator, "AVI ");
    const hdrl = try appendAviChunk(list, "LIST");
    try list.appendSlice(std.testing.allocator, "hdrl");
    const avih = try appendAviChunk(list, "avih");
    try appendU32Le(list, 33333);
    try appendU32Le(list, 0);
    try appendU32Le(list, 0);
    try appendU32Le(list, 0);
    try appendU32Le(list, 1);
    try appendU32Le(list, 0);
    try appendU32Le(list, 1);
    try appendU32Le(list, 8);
    try appendU32Le(list, 2);
    try appendU32Le(list, 2);
    while (list.items.len - avih - 4 < 56) try appendU32Le(list, 0);
    try finishAviChunk(list, avih);
    const strl = try appendAviChunk(list, "LIST");
    try list.appendSlice(std.testing.allocator, "strl");
    const strf = try appendAviChunk(list, "strf");
    try appendU32Le(list, 40);
    try appendU32Le(list, 2);
    try appendU32Le(list, 2);
    try appendU16Le(list, 1);
    try appendU16Le(list, 8);
    try appendU32Le(list, 0);
    try appendU32Le(list, 8);
    try appendU32Le(list, 0);
    try appendU32Le(list, 0);
    try appendU32Le(list, 0);
    try appendU32Le(list, 0);
    try finishAviChunk(list, strf);
    try finishAviChunk(list, strl);
    try finishAviChunk(list, hdrl);
    const movi = try appendAviChunk(list, "LIST");
    try list.appendSlice(std.testing.allocator, "movi");
    const frame = try appendAviChunk(list, "00db");
    try list.appendSlice(std.testing.allocator, &.{ 3, 4, 0, 0, 1, 2, 0, 0 });
    try finishAviChunk(list, frame);
    try finishAviChunk(list, movi);
    try finishAviChunk(list, riff);
}

fn appendDicomElement(list: *std.ArrayList(u8), group: u16, element: u16, vr: []const u8, payload: []const u8) !void {
    try appendU16Le(list, group);
    try appendU16Le(list, element);
    try list.appendSlice(std.testing.allocator, vr);
    if (std.mem.eql(u8, vr, "OB") or std.mem.eql(u8, vr, "OW") or std.mem.eql(u8, vr, "SQ") or std.mem.eql(u8, vr, "UN") or std.mem.eql(u8, vr, "UT")) {
        try appendU16Le(list, 0);
        try appendU32Le(list, @intCast(payload.len));
    } else {
        try appendU16Le(list, @intCast(payload.len));
    }
    try list.appendSlice(std.testing.allocator, payload);
    if ((payload.len & 1) != 0) try list.append(std.testing.allocator, 0);
}

fn appendDicomUs(list: *std.ArrayList(u8), group: u16, element: u16, value: u16) !void {
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, value, .little);
    try appendDicomElement(list, group, element, "US", &payload);
}

fn appendTinyDicom(list: *std.ArrayList(u8)) !void {
    try list.appendNTimes(std.testing.allocator, 0, 128);
    try list.appendSlice(std.testing.allocator, "DICM");
    try appendDicomElement(list, 0x0002, 0x0010, "UI", "1.2.840.10008.1.2.1");
    try appendDicomUs(list, 0x0028, 0x0002, 1);
    try appendDicomElement(list, 0x0028, 0x0004, "CS", "MONOCHROME2");
    try appendDicomUs(list, 0x0028, 0x0010, 1);
    try appendDicomUs(list, 0x0028, 0x0011, 2);
    try appendDicomUs(list, 0x0028, 0x0100, 16);
    try appendDicomUs(list, 0x0028, 0x0103, 0);
    try appendDicomElement(list, 0x7fe0, 0x0010, "OW", &.{ 0x34, 0x12, 0xcd, 0xab });
}

test "reads stored zip entry through inner reader" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.pgm", "P5\n2 1\n255\n\x01\x02");

    try std.testing.expect(matches(data.items));
    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, plane.data);
}

test "skips unsupported stored entries" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "notes.txt", "not an image");
    try appendStoredEntry(&data, "image.pgm", "P5\n1 1\n255\n\x05");

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{5}, plane.data);
}

test "reads deflated zip entry through inner reader" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    const compressed = [_]u8{ 0x0b, 0x30, 0xe5, 0x32, 0x54, 0x30, 0xe4, 0x32, 0x32, 0x35, 0xe5, 0x62, 0x05, 0x00 };
    try appendEntryWithSizes(&data, method_deflate, "image.pgm", &compressed, 12);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{5}, plane.data);
}

test "reads stored png zip entry through inner reader" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    const tiny_png = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x08, 0x00, 0x00, 0x00, 0x00, 0xd1, 0x49, 0x20, 0x56, 0x00, 0x00, 0x00, 0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x60, 0xe7, 0x04, 0x00, 0x00, 0x1a, 0x00, 0x11, 0x60, 0xcd, 0x24, 0x92, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
    try appendStoredEntry(&data, "image.png", &tiny_png);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "reads stored bmp zip entry through inner reader" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    const tiny_bmp = [_]u8{
        'B', 'M', 58, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0,
        40,  0,   0,  0, 1, 0, 0, 0, 1, 0, 0,  0, 1, 0,
        24,  0,   0,  0, 0, 0, 4, 0, 0, 0, 0,  0, 0, 0,
        0,   0,   0,  0, 0, 0, 0, 0, 0, 0, 0,  0, 3, 2,
        1,   0,
    };
    try appendStoredEntry(&data, "image.bmp", &tiny_bmp);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, plane.data);
}

test "reads stored burleigh zip entry through extension-gated inner reader" {
    var burleigh_data: std.ArrayList(u8) = .empty;
    defer burleigh_data.deinit(std.testing.allocator);
    try burleigh_data.appendNTimes(std.testing.allocator, 0, 8);
    writeU32(burleigh_data.items, 0, @bitCast(@as(f32, 2.1)));
    writeU16(burleigh_data.items, 4, 2);
    writeU16(burleigh_data.items, 6, 1);
    try burleigh_data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12, 0xcd, 0xab });

    try std.testing.expectEqual(Entry.Kind.burleigh, detectInner("scan.IMG", burleigh_data.items).?);
    try std.testing.expectEqual(null, detectInner("scan.dat", burleigh_data.items));

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "scan.img", burleigh_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored cellomics zip entry through extension-gated inner reader" {
    var cellomics_data: std.ArrayList(u8) = .empty;
    defer cellomics_data.deinit(std.testing.allocator);
    try cellomics_data.appendNTimes(std.testing.allocator, 0, 52);
    writeU32(cellomics_data.items, 0, 16);
    writeU32(cellomics_data.items, 4, 2);
    writeU32(cellomics_data.items, 8, 1);
    writeU16(cellomics_data.items, 12, 2);
    writeU16(cellomics_data.items, 14, 8);
    writeU32(cellomics_data.items, 16, 0);
    try cellomics_data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4 });

    try std.testing.expectEqual(Entry.Kind.cellomics, detectInner("well.C01", cellomics_data.items).?);
    try std.testing.expectEqual(Entry.Kind.cellomics, detectInner("well.dib", cellomics_data.items).?);
    try std.testing.expectEqual(null, detectInner("well.dat", cellomics_data.items));

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "well.c01", cellomics_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads stored avi zip entry through inner reader" {
    var avi_data: std.ArrayList(u8) = .empty;
    defer avi_data.deinit(std.testing.allocator);
    try appendTinyAvi(&avi_data);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "movie.avi", avi_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, plane.data);
}

test "reads stored bd pathway zip entry before baseline tiff" {
    var bd_data: std.ArrayList(u8) = .empty;
    defer bd_data.deinit(std.testing.allocator);

    try bd_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&bd_data, 42);
    try appendU32Le(&bd_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const software = "  MATROX Imaging Library 8.0\x00";
    const software_offset = ifd_end;
    const pixel_offset = software_offset + software.len;

    try appendU16Le(&bd_data, entry_count);
    try appendTiffEntry(&bd_data, 256, 4, 1, 1);
    try appendTiffEntry(&bd_data, 257, 4, 1, 1);
    try appendTiffEntry(&bd_data, 258, 3, 1, 8);
    try appendTiffEntry(&bd_data, 259, 3, 1, 1);
    try appendTiffEntry(&bd_data, 262, 3, 1, 1);
    try appendTiffEntry(&bd_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&bd_data, 277, 3, 1, 1);
    try appendTiffEntry(&bd_data, 278, 4, 1, 1);
    try appendTiffEntry(&bd_data, 279, 4, 1, 1);
    try appendTiffEntry(&bd_data, 305, 2, software.len, @intCast(software_offset));
    try appendU32Le(&bd_data, 0);
    try bd_data.appendSlice(std.testing.allocator, software);
    try bd_data.append(std.testing.allocator, 99);

    try std.testing.expectEqual(Entry.Kind.bdpathway, detectInner("image.tif", bd_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", bd_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{99}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{99}, region_plane.data);
}

test "reads stored dicom zip entry through inner reader" {
    var dicom_data: std.ArrayList(u8) = .empty;
    defer dicom_data.deinit(std.testing.allocator);
    try appendTinyDicom(&dicom_data);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.dcm", dicom_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
}

test "reads stored fei tiff zip entry before baseline tiff" {
    var fei_data: std.ArrayList(u8) = .empty;
    defer fei_data.deinit(std.testing.allocator);

    try fei_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&fei_data, 42);
    try appendU32Le(&fei_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const description = "fei\x00";
    const description_offset = ifd_end;
    const pixel_offset = description_offset + description.len;

    try appendU16Le(&fei_data, entry_count);
    try appendTiffEntry(&fei_data, 256, 4, 1, 1);
    try appendTiffEntry(&fei_data, 257, 4, 1, 1);
    try appendTiffEntry(&fei_data, 258, 3, 1, 8);
    try appendTiffEntry(&fei_data, 259, 3, 1, 1);
    try appendTiffEntry(&fei_data, 262, 3, 1, 1);
    try appendTiffEntry(&fei_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&fei_data, 277, 3, 1, 1);
    try appendTiffEntry(&fei_data, 278, 4, 1, 1);
    try appendTiffEntry(&fei_data, 279, 4, 1, 1);
    try appendTiffEntry(&fei_data, 34680, 2, description.len, @intCast(description_offset));
    try appendU32Le(&fei_data, 0);
    try fei_data.appendSlice(std.testing.allocator, description);
    try fei_data.append(std.testing.allocator, 77);

    try std.testing.expectEqual(Entry.Kind.feitiff, detectInner("image.tif", fei_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", fei_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, region_plane.data);
}

test "reads stored fluoview zip entry before baseline tiff" {
    var fluoview_data: std.ArrayList(u8) = .empty;
    defer fluoview_data.deinit(std.testing.allocator);

    try fluoview_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&fluoview_data, 42);
    try appendU32Le(&fluoview_data, 8);

    const entry_count = 11;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const comment = "FLUOVIEW Version 5.0\x00";
    const comment_offset = ifd_end;
    const pixel_offset = comment_offset + comment.len;

    try appendU16Le(&fluoview_data, entry_count);
    try appendTiffEntry(&fluoview_data, 256, 4, 1, 1);
    try appendTiffEntry(&fluoview_data, 257, 4, 1, 1);
    try appendTiffEntry(&fluoview_data, 258, 3, 1, 8);
    try appendTiffEntry(&fluoview_data, 259, 3, 1, 1);
    try appendTiffEntry(&fluoview_data, 262, 3, 1, 1);
    try appendTiffEntry(&fluoview_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&fluoview_data, 277, 3, 1, 1);
    try appendTiffEntry(&fluoview_data, 278, 4, 1, 1);
    try appendTiffEntry(&fluoview_data, 279, 4, 1, 1);
    try appendTiffEntry(&fluoview_data, 270, 2, comment.len, @intCast(comment_offset));
    try appendTiffEntry(&fluoview_data, 34361, 4, 1, 1);
    try appendU32Le(&fluoview_data, 0);
    try fluoview_data.appendSlice(std.testing.allocator, comment);
    try fluoview_data.append(std.testing.allocator, 73);

    try std.testing.expectEqual(Entry.Kind.fluoview, detectInner("image.tif", fluoview_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", fluoview_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{73}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{73}, region_plane.data);
}

test "reads stored leo zip entry before baseline tiff" {
    var leo_data: std.ArrayList(u8) = .empty;
    defer leo_data.deinit(std.testing.allocator);

    try leo_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&leo_data, 42);
    try appendU32Le(&leo_data, 8);

    const entry_count = 10;
    const pixel_offset = 8 + 2 + entry_count * 12 + 4;

    try appendU16Le(&leo_data, entry_count);
    try appendTiffEntry(&leo_data, 256, 4, 1, 1);
    try appendTiffEntry(&leo_data, 257, 4, 1, 1);
    try appendTiffEntry(&leo_data, 258, 3, 1, 8);
    try appendTiffEntry(&leo_data, 259, 3, 1, 1);
    try appendTiffEntry(&leo_data, 262, 3, 1, 1);
    try appendTiffEntry(&leo_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&leo_data, 277, 3, 1, 1);
    try appendTiffEntry(&leo_data, 278, 4, 1, 1);
    try appendTiffEntry(&leo_data, 279, 4, 1, 1);
    try appendTiffEntry(&leo_data, 34118, 2, 2, 'x');
    try appendU32Le(&leo_data, 0);
    try leo_data.append(std.testing.allocator, 91);

    try std.testing.expectEqual(Entry.Kind.leo, detectInner("image.tif", leo_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", leo_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{91}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{91}, region_plane.data);
}

test "reads stored gif zip entry through inner reader" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    const tiny_gif = [_]u8{
        'G',  'I',  'F',  '8',  '9',  'a',
        2,    0,    1,    0,    0x80, 0,
        0,    0,    0,    0,    255,  0,
        0,    0x21, 0xf9, 4,    0,    0,
        0,    0,    0,    0x2c, 0,    0,
        0,    0,    2,    0,    1,    0,
        0,    2,    2,    0x44, 0x0a, 0,
        0x3b,
    };
    try appendStoredEntry(&data, "image.gif", &tiny_gif);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 0, 0 }, plane.data);
}

test "reads stored his zip entry through inner reader" {
    var his_data = [_]u8{0} ** (64 + 4);
    @memcpy(his_data[0..2], "IM");
    writeU16(&his_data, 2, 0);
    writeU16(&his_data, 4, 2);
    writeU16(&his_data, 6, 1);
    writeU16(&his_data, 12, 2);
    writeU16(&his_data, 14, 1);
    @memcpy(his_data[64..], &[_]u8{ 0x34, 0x12, 0xcd, 0xab });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.his", &his_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored hrd gdf zip entry through inner reader" {
    const gdf_data =
        \\HURRICANE TEST
        \\DX 1 KM
        \\SURFACE WIND COMPONENTS
        \\2 2
        \\(1.5, 2.5) (3.5, 4.5)
        \\(5.5, 6.5) (7.5, 8.5)
    ;

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "wind.gdf", gdf_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.float64, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 2.5))), std.mem.readInt(u64, plane.data[0..8], .big));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 8.5))), std.mem.readInt(u64, plane.data[24..32], .big));
}

test "reads stored i2i zip entry through extension-gated inner reader" {
    var i2i_data: std.ArrayList(u8) = .empty;
    defer i2i_data.deinit(std.testing.allocator);
    try i2i_data.appendNTimes(std.testing.allocator, ' ', 1024);
    i2i_data.items[0] = 'R';
    i2i_data.items[1] = ' ';
    i2i_data.items[2] = '1';
    i2i_data.items[8] = '1';
    i2i_data.items[14] = '4';
    i2i_data.items[20] = 'B';
    std.mem.writeInt(u16, i2i_data.items[29..31], 2, .big);
    try i2i_data.appendSlice(std.testing.allocator, &.{ 0x3f, 0x80, 0, 0, 0x40, 0, 0, 0, 0x40, 0x40, 0, 0, 0x40, 0x80, 0, 0 });

    try std.testing.expectEqual(Entry.Kind.i2i, detectInner("stack.I2I", i2i_data.items).?);
    try std.testing.expectEqual(null, detectInner("stack.dat", i2i_data.items));

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "stack.i2i", i2i_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 4), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0x40, 0, 0, 0 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 4));
}

test "reads stored tiff zip entry through inner reader" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    const tiny_tiff = [_]u8{
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
    try appendStoredEntry(&data, "image.tif", &tiny_tiff);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);
}

test "detects stored ome-tiff zip entry before baseline tiff" {
    var ome_tiff_data: std.ArrayList(u8) = .empty;
    defer ome_tiff_data.deinit(std.testing.allocator);
    try ome_tiff_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&ome_tiff_data, 42);
    try appendU32Le(&ome_tiff_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const description =
        \\<OME><Image ID="Image:0"><Pixels DimensionOrder="XYZCT" Type="uint8" SizeX="1" SizeY="1" SizeZ="1" SizeC="1" SizeT="1"/></Image></OME>
    ++ "\x00";
    const description_offset = ifd_end;
    const pixel_offset = description_offset + description.len;

    try appendU16Le(&ome_tiff_data, entry_count);
    try appendTiffEntry(&ome_tiff_data, 256, 4, 1, 1);
    try appendTiffEntry(&ome_tiff_data, 257, 4, 1, 1);
    try appendTiffEntry(&ome_tiff_data, 258, 3, 1, 8);
    try appendTiffEntry(&ome_tiff_data, 259, 3, 1, 1);
    try appendTiffEntry(&ome_tiff_data, 262, 3, 1, 1);
    try appendTiffEntry(&ome_tiff_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&ome_tiff_data, 277, 3, 1, 1);
    try appendTiffEntry(&ome_tiff_data, 278, 4, 1, 1);
    try appendTiffEntry(&ome_tiff_data, 279, 4, 1, 1);
    try appendTiffEntry(&ome_tiff_data, 270, 2, description.len, @intCast(description_offset));
    try appendU32Le(&ome_tiff_data, 0);
    try ome_tiff_data.appendSlice(std.testing.allocator, description);
    try ome_tiff_data.append(std.testing.allocator, 17);

    try std.testing.expectEqual(Entry.Kind.ometiff, detectInner("image.ome.tif", ome_tiff_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.ome.tif", ome_tiff_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqualStrings(description[0 .. description.len - 1], metadata.image_description.?);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{17}, plane.data);
}

test "reads stored ome-xml zip entry through inner reader" {
    const ome_xml_data =
        \\<?xml version="1.0"?>
        \\<OME><Image ID="Image:0"><Pixels DimensionOrder="XYZCT" Type="uint8" SizeX="2" SizeY="1" SizeZ="1" SizeC="1" SizeT="1"><BinData Compression="none">ESI=</BinData></Pixels></Image></OME>
    ;

    try std.testing.expectEqual(Entry.Kind.omexml, detectInner("metadata.ome.xml", ome_xml_data).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "metadata.ome.xml", ome_xml_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 17, 34 }, plane.data);
}

test "reads region from stored tiff zip entry through inner region reader" {
    var tiff_data: std.ArrayList(u8) = .empty;
    defer tiff_data.deinit(std.testing.allocator);
    try tiff_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&tiff_data, 42);
    try appendU32Le(&tiff_data, 8);

    const ifd_size = 2 + 9 * 12 + 4;
    const strip_offsets_array = 8 + ifd_size;
    const strip_counts_array = strip_offsets_array + 3 * 4;
    const pixel_offset = strip_counts_array + 3 * 4;

    try appendU16Le(&tiff_data, 9);
    try appendTiffEntry(&tiff_data, 256, 4, 1, 4);
    try appendTiffEntry(&tiff_data, 257, 4, 1, 3);
    try appendTiffEntry(&tiff_data, 258, 3, 1, 8);
    try appendTiffEntry(&tiff_data, 259, 3, 1, 1);
    try appendTiffEntry(&tiff_data, 262, 3, 1, 1);
    try appendTiffEntry(&tiff_data, 273, 4, 3, @intCast(strip_offsets_array));
    try appendTiffEntry(&tiff_data, 277, 3, 1, 1);
    try appendTiffEntry(&tiff_data, 278, 4, 1, 1);
    try appendTiffEntry(&tiff_data, 279, 4, 3, @intCast(strip_counts_array));
    try appendU32Le(&tiff_data, 0);
    try appendU32Le(&tiff_data, 9999);
    try appendU32Le(&tiff_data, @intCast(pixel_offset));
    try appendU32Le(&tiff_data, @intCast(pixel_offset + 4));
    try appendU32Le(&tiff_data, 4);
    try appendU32Le(&tiff_data, 4);
    try appendU32Le(&tiff_data, 4);
    try tiff_data.appendSlice(std.testing.allocator, &.{ 5, 6, 7, 8, 9, 10, 11, 12 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", tiff_data.items);

    const plane = try readRegionIndex(
        std.testing.allocator,
        data.items,
        0,
        .{ .x = 1, .y = 1, .width = 2, .height = 1 },
    );
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 6, 7 }, plane.data);
}

test "reads stored pcx zip entry through inner reader" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    var tiny_pcx = [_]u8{0} ** 134;
    tiny_pcx[0] = 10;
    tiny_pcx[1] = 5;
    tiny_pcx[2] = 1;
    tiny_pcx[3] = 8;
    writeU16(&tiny_pcx, 8, 1);
    tiny_pcx[65] = 3;
    writeU16(&tiny_pcx, 66, 2);
    @memcpy(tiny_pcx[128..134], &[_]u8{ 10, 40, 20, 50, 30, 60 });
    try appendStoredEntry(&data, "image.pcx", &tiny_pcx);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 50, 60 }, plane.data);
}

test "reads stored photoshop tiff zip entry before baseline tiff" {
    var photoshop_data: std.ArrayList(u8) = .empty;
    defer photoshop_data.deinit(std.testing.allocator);

    try photoshop_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&photoshop_data, 42);
    try appendU32Le(&photoshop_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const image_source_data = "8BIM\x00";
    const source_offset = ifd_end;
    const pixel_offset = source_offset + image_source_data.len;

    try appendU16Le(&photoshop_data, entry_count);
    try appendTiffEntry(&photoshop_data, 256, 4, 1, 1);
    try appendTiffEntry(&photoshop_data, 257, 4, 1, 1);
    try appendTiffEntry(&photoshop_data, 258, 3, 1, 8);
    try appendTiffEntry(&photoshop_data, 259, 3, 1, 1);
    try appendTiffEntry(&photoshop_data, 262, 3, 1, 1);
    try appendTiffEntry(&photoshop_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&photoshop_data, 277, 3, 1, 1);
    try appendTiffEntry(&photoshop_data, 278, 4, 1, 1);
    try appendTiffEntry(&photoshop_data, 279, 4, 1, 1);
    try appendTiffEntry(&photoshop_data, 37724, 1, image_source_data.len, @intCast(source_offset));
    try appendU32Le(&photoshop_data, 0);
    try photoshop_data.appendSlice(std.testing.allocator, image_source_data);
    try photoshop_data.append(std.testing.allocator, 128);

    try std.testing.expectEqual(Entry.Kind.photoshoptiff, detectInner("image.tif", photoshop_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", photoshop_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{128}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{128}, region_plane.data);
}

test "reads stored povray zip entry through extension-gated inner reader" {
    var df3_data: std.ArrayList(u8) = .empty;
    defer df3_data.deinit(std.testing.allocator);
    try appendU16Be(&df3_data, 2);
    try appendU16Be(&df3_data, 1);
    try appendU16Be(&df3_data, 2);
    try df3_data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "volume.DF3", df3_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads stored picoquant bin zip entry through extension-gated inner reader" {
    var pqbin_data: std.ArrayList(u8) = .empty;
    defer pqbin_data.deinit(std.testing.allocator);
    try pqbin_data.appendNTimes(std.testing.allocator, 0, 20);
    writeU32(pqbin_data.items, 0, 2);
    writeU32(pqbin_data.items, 4, 1);
    writeU32(pqbin_data.items, 12, 2);
    try appendU32Le(&pqbin_data, 1);
    try appendU32Le(&pqbin_data, 2);
    try appendU32Le(&pqbin_data, 3);
    try appendU32Le(&pqbin_data, 4);

    try std.testing.expectEqual(Entry.Kind.pqbin, detectInner("lifetime.bin", pqbin_data.items).?);
    try std.testing.expectEqual(null, detectInner("lifetime.dat", pqbin_data.items));

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "lifetime.bin", pqbin_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint32, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 4, 0, 0, 0 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads stored psd zip entry through inner reader" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    const tiny_psd = [_]u8{
        '8', 'B', 'P', 'S',
        0,   1,   0,   0,
        0,   0,   0,   0,
        0,   1,   0,   0,
        0,   1,   0,   0,
        0,   2,   0,   8,
        0,   1,   0,   0,
        0,   0,   0,   0,
        0,   0,   0,   0,
        0,   0,   0,   0,
        7,   9,
    };
    try appendStoredEntry(&data, "image.psd", &tiny_psd);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "reads stored quesant zip entry through inner reader" {
    var quesant_data: std.ArrayList(u8) = .empty;
    defer quesant_data.deinit(std.testing.allocator);
    try quesant_data.appendNTimes(std.testing.allocator, 0, 64);
    @memcpy(quesant_data.items[0..4], "IMAG");
    writeU32(quesant_data.items, 4, 64);
    try appendU16Le(&quesant_data, 2);
    try quesant_data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0, 3, 0, 4, 0 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.afm", quesant_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0, 3, 0, 4, 0 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored rhk zip entry through inner reader" {
    var rhk_data: std.ArrayList(u8) = .empty;
    defer rhk_data.deinit(std.testing.allocator);
    try rhk_data.appendNTimes(std.testing.allocator, 0, 512);
    writeU16(rhk_data.items, 0, 0xaa);
    writeU32(rhk_data.items, 48, 3);
    writeU32(rhk_data.items, 64, 2);
    writeU32(rhk_data.items, 68, 1);
    writeU32(rhk_data.items, 88, 512);
    @memcpy(rhk_data.items[352..364], "RHK zip test");
    try rhk_data.appendSlice(std.testing.allocator, &.{ 8, 9 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.spm", rhk_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expectEqualStrings("RHK zip test", metadata.image_description.?);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 8, 9 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored sbig zip entry through inner reader" {
    var sbig_data: std.ArrayList(u8) = .empty;
    defer sbig_data.deinit(std.testing.allocator);
    try sbig_data.appendNTimes(std.testing.allocator, 0, 2048);
    const header =
        "ST-7 Compressed Image\n" ++
        "Width = 2\n" ++
        "Height = 1\n" ++
        "Note = raw row\n" ++
        "End\n";
    @memcpy(sbig_data.items[0..header.len], header);
    try appendU16Le(&sbig_data, 4);
    try sbig_data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.sbig", sbig_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expectEqualStrings("raw row", metadata.image_description.?);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored seiko zip entry through inner reader" {
    var seiko_data: std.ArrayList(u8) = .empty;
    defer seiko_data.deinit(std.testing.allocator);
    try seiko_data.appendNTimes(std.testing.allocator, 0, 2944);
    @memcpy(seiko_data.items[40..54], "Seiko zip note");
    writeU16(seiko_data.items, 1402, 2);
    writeU16(seiko_data.items, 1404, 1);
    try seiko_data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12, 0xcd, 0xab });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.xqd", seiko_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expectEqualStrings("Seiko zip note", metadata.image_description.?);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored image-pro seq zip entry before baseline tiff" {
    var seq_data: std.ArrayList(u8) = .empty;
    defer seq_data.deinit(std.testing.allocator);

    try seq_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&seq_data, 42);
    try appendU32Le(&seq_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const tag_values_offset = ifd_end;
    const pixel_offset = tag_values_offset + 24;

    try appendU16Le(&seq_data, entry_count);
    try appendTiffEntry(&seq_data, 256, 4, 1, 1);
    try appendTiffEntry(&seq_data, 257, 4, 1, 1);
    try appendTiffEntry(&seq_data, 258, 3, 1, 8);
    try appendTiffEntry(&seq_data, 259, 3, 1, 1);
    try appendTiffEntry(&seq_data, 262, 3, 1, 1);
    try appendTiffEntry(&seq_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&seq_data, 277, 3, 1, 1);
    try appendTiffEntry(&seq_data, 278, 4, 1, 1);
    try appendTiffEntry(&seq_data, 279, 4, 1, 1);
    try appendTiffEntry(&seq_data, 50288, 3, 12, @intCast(tag_values_offset));
    try appendU32Le(&seq_data, 0);
    var i: usize = 0;
    while (i < 12) : (i += 1) try appendU16Le(&seq_data, 7);
    try seq_data.append(std.testing.allocator, 122);

    try std.testing.expectEqual(Entry.Kind.seq, detectInner("image.seq", seq_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.seq", seq_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{122}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{122}, region_plane.data);
}

test "reads stored sif zip entry through inner reader" {
    const sif_data =
        "Andor Technology\n" ++
        "Pixel number 2 1 1 1 1\n" ++
        "0 0 0 0 0 1 1\n" ++
        [_]u8{ 0, 0, 0x80, 0x3f, 0, 0, 0, 0x40 } ++
        [_]u8{0} ** 8;

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.sif", sif_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0x40 }, plane.data);
}

test "reads stored simplepci zip entry before baseline tiff" {
    var simplepci_data: std.ArrayList(u8) = .empty;
    defer simplepci_data.deinit(std.testing.allocator);

    try simplepci_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&simplepci_data, 42);
    try appendU32Le(&simplepci_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const description = "Created by Hamamatsu Inc.\n[ CAPTURE ]\x00";
    const pixel_offset = ifd_end + description.len;

    try appendU16Le(&simplepci_data, entry_count);
    try appendTiffEntry(&simplepci_data, 256, 4, 1, 1);
    try appendTiffEntry(&simplepci_data, 257, 4, 1, 1);
    try appendTiffEntry(&simplepci_data, 258, 3, 1, 8);
    try appendTiffEntry(&simplepci_data, 259, 3, 1, 1);
    try appendTiffEntry(&simplepci_data, 262, 3, 1, 1);
    try appendTiffEntry(&simplepci_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&simplepci_data, 277, 3, 1, 1);
    try appendTiffEntry(&simplepci_data, 278, 4, 1, 1);
    try appendTiffEntry(&simplepci_data, 279, 4, 1, 1);
    try appendTiffEntry(&simplepci_data, 270, 2, description.len, @intCast(ifd_end));
    try appendU32Le(&simplepci_data, 0);
    try simplepci_data.appendSlice(std.testing.allocator, description);
    try simplepci_data.append(std.testing.allocator, 55);

    try std.testing.expectEqual(Entry.Kind.simplepci, detectInner("image.tif", simplepci_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", simplepci_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{55}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{55}, region_plane.data);
}

test "reads stored sis zip entry before baseline tiff" {
    var sis_data: std.ArrayList(u8) = .empty;
    defer sis_data.deinit(std.testing.allocator);

    try sis_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&sis_data, 42);
    try appendU32Le(&sis_data, 8);

    const entry_count = 11;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const software = "analySIS 5\x00";
    const pixel_offset = ifd_end + software.len;

    try appendU16Le(&sis_data, entry_count);
    try appendTiffEntry(&sis_data, 256, 4, 1, 1);
    try appendTiffEntry(&sis_data, 257, 4, 1, 1);
    try appendTiffEntry(&sis_data, 258, 3, 1, 8);
    try appendTiffEntry(&sis_data, 259, 3, 1, 1);
    try appendTiffEntry(&sis_data, 262, 3, 1, 1);
    try appendTiffEntry(&sis_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&sis_data, 277, 3, 1, 1);
    try appendTiffEntry(&sis_data, 278, 4, 1, 1);
    try appendTiffEntry(&sis_data, 279, 4, 1, 1);
    try appendTiffEntry(&sis_data, 305, 2, software.len, @intCast(ifd_end));
    try appendTiffEntry(&sis_data, 33560, 1, 4, 0);
    try appendU32Le(&sis_data, 0);
    try sis_data.appendSlice(std.testing.allocator, software);
    try sis_data.append(std.testing.allocator, 77);

    try std.testing.expectEqual(Entry.Kind.sis, detectInner("image.tif", sis_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", sis_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{77}, region_plane.data);
}

test "reads stored slidebook tiff zip entry before baseline tiff" {
    var slidebook_data: std.ArrayList(u8) = .empty;
    defer slidebook_data.deinit(std.testing.allocator);

    try slidebook_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&slidebook_data, 42);
    try appendU32Le(&slidebook_data, 8);

    const entry_count = 11;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const software = "SlideBook\x00";
    const software_offset = ifd_end;
    const pixel_offset = software_offset + software.len;

    try appendU16Le(&slidebook_data, entry_count);
    try appendTiffEntry(&slidebook_data, 256, 4, 1, 1);
    try appendTiffEntry(&slidebook_data, 257, 4, 1, 1);
    try appendTiffEntry(&slidebook_data, 258, 3, 1, 8);
    try appendTiffEntry(&slidebook_data, 259, 3, 1, 1);
    try appendTiffEntry(&slidebook_data, 262, 3, 1, 1);
    try appendTiffEntry(&slidebook_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&slidebook_data, 277, 3, 1, 1);
    try appendTiffEntry(&slidebook_data, 278, 4, 1, 1);
    try appendTiffEntry(&slidebook_data, 279, 4, 1, 1);
    try appendTiffEntry(&slidebook_data, 305, 2, software.len, @intCast(software_offset));
    try appendTiffEntry(&slidebook_data, 65004, 2, 2, 0);
    try appendU32Le(&slidebook_data, 0);
    try slidebook_data.appendSlice(std.testing.allocator, software);
    try slidebook_data.append(std.testing.allocator, 91);

    try std.testing.expectEqual(Entry.Kind.slidebooktiff, detectInner("image.tif", slidebook_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", slidebook_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{91}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{91}, region_plane.data);
}

test "reads stored svs zip entry before baseline tiff" {
    var svs_data: std.ArrayList(u8) = .empty;
    defer svs_data.deinit(std.testing.allocator);

    try svs_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&svs_data, 42);
    try appendU32Le(&svs_data, 8);

    const first_entry_count = 10;
    const first_ifd_size = 2 + first_entry_count * 12 + 4;
    const second_entry_count = 9;
    const second_ifd_offset = 8 + first_ifd_size;
    const second_ifd_size = 2 + second_entry_count * 12 + 4;
    const description = "Aperio Image|MPP = 0.25\x00";
    const description_offset = second_ifd_offset + second_ifd_size;
    const first_pixel_offset = description_offset + description.len;
    const second_pixel_offset = first_pixel_offset + 1;

    try appendU16Le(&svs_data, first_entry_count);
    try appendTiffEntry(&svs_data, 256, 4, 1, 1);
    try appendTiffEntry(&svs_data, 257, 4, 1, 1);
    try appendTiffEntry(&svs_data, 258, 3, 1, 8);
    try appendTiffEntry(&svs_data, 259, 3, 1, 1);
    try appendTiffEntry(&svs_data, 262, 3, 1, 1);
    try appendTiffEntry(&svs_data, 273, 4, 1, @intCast(first_pixel_offset));
    try appendTiffEntry(&svs_data, 277, 3, 1, 1);
    try appendTiffEntry(&svs_data, 278, 4, 1, 1);
    try appendTiffEntry(&svs_data, 279, 4, 1, 1);
    try appendTiffEntry(&svs_data, 270, 2, description.len, @intCast(description_offset));
    try appendU32Le(&svs_data, @intCast(second_ifd_offset));

    try appendU16Le(&svs_data, second_entry_count);
    try appendTiffEntry(&svs_data, 256, 4, 1, 1);
    try appendTiffEntry(&svs_data, 257, 4, 1, 1);
    try appendTiffEntry(&svs_data, 258, 3, 1, 8);
    try appendTiffEntry(&svs_data, 259, 3, 1, 1);
    try appendTiffEntry(&svs_data, 262, 3, 1, 1);
    try appendTiffEntry(&svs_data, 273, 4, 1, @intCast(second_pixel_offset));
    try appendTiffEntry(&svs_data, 277, 3, 1, 1);
    try appendTiffEntry(&svs_data, 278, 4, 1, 1);
    try appendTiffEntry(&svs_data, 279, 4, 1, 1);
    try appendU32Le(&svs_data, 0);
    try svs_data.appendSlice(std.testing.allocator, description);
    try svs_data.append(std.testing.allocator, 22);
    try svs_data.append(std.testing.allocator, 33);

    try std.testing.expectEqual(Entry.Kind.svs, detectInner("image.svs", svs_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.svs", svs_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{22}, plane.data);

    const second_plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(second_plane.data);
    try std.testing.expectEqualStrings("zip", second_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{33}, second_plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{22}, region_plane.data);
}

test "reads stored tcs zip entry before baseline tiff" {
    var tcs_data: std.ArrayList(u8) = .empty;
    defer tcs_data.deinit(std.testing.allocator);

    try tcs_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&tcs_data, 42);
    try appendU32Le(&tcs_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const software = "TCS SP2\x00";
    const software_offset = ifd_end;
    const pixel_offset = software_offset + software.len;

    try appendU16Le(&tcs_data, entry_count);
    try appendTiffEntry(&tcs_data, 256, 4, 1, 1);
    try appendTiffEntry(&tcs_data, 257, 4, 1, 1);
    try appendTiffEntry(&tcs_data, 258, 3, 1, 8);
    try appendTiffEntry(&tcs_data, 259, 3, 1, 1);
    try appendTiffEntry(&tcs_data, 262, 3, 1, 1);
    try appendTiffEntry(&tcs_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&tcs_data, 277, 3, 1, 1);
    try appendTiffEntry(&tcs_data, 278, 4, 1, 1);
    try appendTiffEntry(&tcs_data, 279, 4, 1, 1);
    try appendTiffEntry(&tcs_data, 305, 2, software.len, @intCast(software_offset));
    try appendU32Le(&tcs_data, 0);
    try tcs_data.appendSlice(std.testing.allocator, software);
    try tcs_data.append(std.testing.allocator, 88);

    try std.testing.expectEqual(Entry.Kind.tcs, detectInner("image.tif", tcs_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", tcs_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{88}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{88}, region_plane.data);
}

test "reads stored spe zip entry through extension-gated inner reader" {
    var spe_data: std.ArrayList(u8) = .empty;
    defer spe_data.deinit(std.testing.allocator);
    try spe_data.appendNTimes(std.testing.allocator, 0, 4100);
    writeU16(spe_data.items, 42, 1);
    writeU16(spe_data.items, 656, 1);
    writeU32(spe_data.items, 1446, 2);
    writeU16(spe_data.items, 108, 0);
    try spe_data.appendSlice(std.testing.allocator, &.{ 0, 0, 0x80, 0x3f, 0, 0, 0, 0x40 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "nested/IMAGE.SPE", spe_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0x40 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads stored spider zip entry through extension-gated inner reader" {
    var spider_data: std.ArrayList(u8) = .empty;
    defer spider_data.deinit(std.testing.allocator);
    try spider_data.appendNTimes(std.testing.allocator, 0, 104);
    std.mem.writeInt(u32, spider_data.items[0..4], @bitCast(@as(f32, 2.0)), .little);
    std.mem.writeInt(u32, spider_data.items[4..8], @bitCast(@as(f32, 1.0)), .little);
    std.mem.writeInt(u32, spider_data.items[8..12], @bitCast(@as(f32, 1.0)), .little);
    std.mem.writeInt(u32, spider_data.items[44..48], @bitCast(@as(f32, 2.0)), .little);
    std.mem.writeInt(u32, spider_data.items[48..52], @bitCast(@as(f32, 13.0)), .little);
    try spider_data.appendSlice(std.testing.allocator, &.{
        0, 0, 0x80, 0x3f,
        0, 0, 0,    0x40,
        0, 0, 0x40, 0x40,
        0, 0, 0x80, 0x40,
    });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "stack.SPI", spider_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{
        0, 0, 0x40, 0x40,
        0, 0, 0x80, 0x40,
    }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads stored tga zip entry through extension-gated inner reader" {
    const tga_data = [_]u8{
        0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 24, 0x20,
        3, 2, 1, 6, 5, 4,
    };

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.TGA", &tga_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored text zip entry through inner reader" {
    const text_data =
        \\x,y,a,b
        \\0,0,1.5,2.5
        \\1,0,3.5,4.5
    ;

    try std.testing.expectEqual(Entry.Kind.text, detectInner("table.csv", text_data).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "table.csv", text_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_c);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 2.5))), std.mem.readInt(u32, plane.data[0..4], .big));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 4.5))), std.mem.readInt(u32, plane.data[4..8], .big));
}

test "reads stored sm camera zip entry through inner reader" {
    var sm_data = [_]u8{0} ** (548 + 2);
    const signature = [_]u8{ 0, 0, 0, 0, 2, 0, 0, 5, 0xc9, 0x88, 0, 5, 0xcb, 0x88, 0, 0 };
    @memcpy(sm_data[0..signature.len], &signature);
    std.mem.writeInt(u16, sm_data[524..526], 1, .big);
    std.mem.writeInt(u16, sm_data[532..534], 2, .big);
    @memcpy(sm_data[548..], &[_]u8{ 7, 9 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.sm", &sm_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored nrrd zip entry through inner reader" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    const tiny_nrrd =
        "NRRD0005\n" ++
        "type: ushort\n" ++
        "dimension: 3\n" ++
        "sizes: 1 1 2\n" ++
        "endian: little\n" ++
        "encoding: raw\n" ++
        "\n" ++
        [_]u8{ 0x34, 0x12, 0xcd, 0xab };
    try appendStoredEntry(&data, "image.nrrd", tiny_nrrd);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0xcd, 0xab }, plane.data);
}

test "reads stored openlab raw zip entry through inner reader" {
    var raw_data: std.ArrayList(u8) = .empty;
    defer raw_data.deinit(std.testing.allocator);
    try raw_data.appendSlice(std.testing.allocator, "OLRW");
    try raw_data.appendNTimes(std.testing.allocator, 0, 4);
    try appendU32Be(&raw_data, 2);
    try raw_data.appendNTimes(std.testing.allocator, 0, 288);
    std.mem.writeInt(u32, raw_data.items[12 + 16 ..][0..4], 1, .big);
    std.mem.writeInt(u32, raw_data.items[12 + 20 ..][0..4], 1, .big);
    raw_data.items[12 + 25] = 1;
    raw_data.items[12 + 26] = 2;
    try raw_data.appendSlice(std.testing.allocator, &.{ 0x12, 0x34 });
    try raw_data.appendNTimes(std.testing.allocator, 0, 288);
    const second_block = raw_data.items.len - 288;
    std.mem.writeInt(u32, raw_data.items[second_block + 16 ..][0..4], 1, .big);
    std.mem.writeInt(u32, raw_data.items[second_block + 20 ..][0..4], 1, .big);
    raw_data.items[second_block + 25] = 1;
    raw_data.items[second_block + 26] = 2;
    try raw_data.appendSlice(std.testing.allocator, &.{ 0xab, 0xcd });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.olraw", raw_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, plane.data);
}

test "reads stored oxford instruments zip entry through inner reader" {
    var oxford_data: std.ArrayList(u8) = .empty;
    defer oxford_data.deinit(std.testing.allocator);
    try oxford_data.appendSlice(std.testing.allocator, "Oxford Instruments");
    try oxford_data.appendNTimes(std.testing.allocator, 0, 1048 - oxford_data.items.len);
    try appendU32Le(&oxford_data, 2);
    try appendU32Le(&oxford_data, 1);
    try oxford_data.appendNTimes(std.testing.allocator, 0, 1288 - oxford_data.items.len);
    try appendU32Le(&oxford_data, 0);
    try oxford_data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.top", oxford_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored fits zip entry through inner reader" {
    var fits_data: std.ArrayList(u8) = .empty;
    defer fits_data.deinit(std.testing.allocator);
    try appendFitsHeader(&fits_data, "16", "1", "1", "2");
    try fits_data.appendSlice(std.testing.allocator, &.{ 0x12, 0x34, 0xab, 0xcd });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.fits", fits_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, plane.data);
}

test "reads stored eps zip entry through inner reader" {
    const eps_data =
        \\%!PS-Adobe-3.0 EPSF-3.0
        \\2 1 8 image
        \\0a ff
    ;

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.eps", eps_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0x0a, 0xff }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored fei zip entry through extension-gated inner reader" {
    var fei_data: std.ArrayList(u8) = .empty;
    defer fei_data.deinit(std.testing.allocator);
    try fei_data.appendNTimes(std.testing.allocator, 0, 524);
    @memcpy(fei_data.items[0..2], "XL");
    writeU16(fei_data.items, 514, 116);
    writeU16(fei_data.items, 516, 1);
    writeU16(fei_data.items, 522, 524);
    try fei_data.appendSlice(std.testing.allocator, &.{ 1, 3 });
    try fei_data.appendNTimes(std.testing.allocator, 0, 56);
    try fei_data.appendSlice(std.testing.allocator, &.{ 2, 4 });
    try fei_data.appendNTimes(std.testing.allocator, 0, 56);

    try std.testing.expectEqual(Entry.Kind.fei, detectInner("sem.IMG", fei_data.items).?);
    try std.testing.expectEqual(null, detectInner("sem.dat", fei_data.items));

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "sem.img", fei_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 4), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored dcimg zip entry through inner reader" {
    var dcimg_data: std.ArrayList(u8) = .empty;
    defer dcimg_data.deinit(std.testing.allocator);
    try dcimg_data.appendNTimes(std.testing.allocator, 0, 256);
    @memcpy(dcimg_data.items[0..5], "DCIMG");
    writeU32(dcimg_data.items, 8, 0x01000000);
    writeU32(dcimg_data.items, 40, 128);
    writeU32(dcimg_data.items, 52, 256);
    writeU32(dcimg_data.items, 68, 256);
    writeU32(dcimg_data.items, 188, 2);
    writeU32(dcimg_data.items, 192, 1);
    writeU32(dcimg_data.items, 200, 2);
    writeU32(dcimg_data.items, 204, 2);
    writeU32(dcimg_data.items, 212, 4);
    std.mem.writeInt(u64, dcimg_data.items[224..232], 128, .little);
    writeU32(dcimg_data.items, 252, 0);
    try dcimg_data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.dcimg", dcimg_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 5, 6 }, plane.data);
}

test "reads stored deltavision zip entry through extension-gated inner reader" {
    var dv_data: std.ArrayList(u8) = .empty;
    defer dv_data.deinit(std.testing.allocator);
    try dv_data.appendNTimes(std.testing.allocator, 0, 1024);
    writeU32(dv_data.items, 0, 2);
    writeU32(dv_data.items, 4, 2);
    writeU32(dv_data.items, 8, 2);
    writeU32(dv_data.items, 12, 6);
    writeU32(dv_data.items, 92, 4);
    writeU16(dv_data.items, 96, 0xc0a0);
    writeU16(dv_data.items, 180, 1);
    writeU16(dv_data.items, 182, 0);
    writeU16(dv_data.items, 196, 1);
    try dv_data.appendSlice(std.testing.allocator, &.{ 9, 9, 9, 9 });
    try dv_data.appendSlice(std.testing.allocator, &.{
        1, 0, 2, 0, 3, 0, 4, 0,
        5, 0, 6, 0, 7, 0, 8, 0,
    });

    try std.testing.expectEqual(Entry.Kind.deltavision, detectInner("stack.DV", dv_data.items).?);
    try std.testing.expectEqual(Entry.Kind.deltavision, detectInner("stack.r3d_d3d", dv_data.items).?);
    try std.testing.expectEqual(null, detectInner("stack.dat", dv_data.items));

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "stack.dv", dv_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 7, 0, 8, 0, 5, 0, 6, 0 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads stored ecat7 zip entry through inner reader" {
    var ecat_data: std.ArrayList(u8) = .empty;
    defer ecat_data.deinit(std.testing.allocator);
    try ecat_data.appendNTimes(std.testing.allocator, 0, 1536 + 512 + 4);
    @memcpy(ecat_data.items[0..9], "MATRIX72v");
    std.mem.writeInt(u16, ecat_data.items[352..354], 1, .big);
    std.mem.writeInt(u16, ecat_data.items[354..356], 2, .big);
    std.mem.writeInt(u16, ecat_data.items[1024..1026], 6, .big);
    std.mem.writeInt(u16, ecat_data.items[1026..1028], 3, .big);
    std.mem.writeInt(u16, ecat_data.items[1028..1030], 1, .big);
    std.mem.writeInt(u16, ecat_data.items[1030..1032], 1, .big);
    ecat_data.items[1536] = 0x12;
    ecat_data.items[1537] = 0x34;
    ecat_data.items[1536 + 512 + 2] = 0xab;
    ecat_data.items[1536 + 512 + 3] = 0xcd;

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.v", ecat_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, plane.data);
}

test "reads stored gatan dm2 zip entry through inner reader" {
    var dm2_data: std.ArrayList(u8) = .empty;
    defer dm2_data.deinit(std.testing.allocator);
    try appendU32Be(&dm2_data, 0x003d0000);
    try appendU32Be(&dm2_data, 0);
    try appendU32Be(&dm2_data, 0);
    try appendU32Be(&dm2_data, 0);
    try appendU16Be(&dm2_data, 2);
    try appendU16Be(&dm2_data, 1);
    try appendU16Be(&dm2_data, 1);
    try appendU16Be(&dm2_data, 0);
    try dm2_data.appendSlice(std.testing.allocator, &.{ 8, 9 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.dm2", dm2_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 8, 9 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored nifti zip entry through inner reader" {
    var tiny_nifti = [_]u8{0} ** 360;
    writeU32(&tiny_nifti, 0, 348);
    writeU16(&tiny_nifti, 40, 3);
    writeU16(&tiny_nifti, 42, 2);
    writeU16(&tiny_nifti, 44, 1);
    writeU16(&tiny_nifti, 46, 2);
    writeU16(&tiny_nifti, 48, 1);
    writeU16(&tiny_nifti, 70, 512);
    std.mem.writeInt(u32, tiny_nifti[108..112], @bitCast(@as(f32, 352.0)), .little);
    @memcpy(tiny_nifti[344..348], "n+1\x00");
    @memcpy(tiny_nifti[352..360], &[_]u8{ 1, 0, 2, 0, 3, 0, 4, 0 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.nii", &tiny_nifti);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 4, 0 }, plane.data);
}

test "reads stored nikon tiff zip entry before baseline tiff" {
    var nikon_data: std.ArrayList(u8) = .empty;
    defer nikon_data.deinit(std.testing.allocator);

    try nikon_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&nikon_data, 42);
    try appendU32Le(&nikon_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const software = "Nikon EZ-C1\x00";
    const software_offset = ifd_end;
    const pixel_offset = software_offset + software.len;

    try appendU16Le(&nikon_data, entry_count);
    try appendTiffEntry(&nikon_data, 256, 4, 1, 1);
    try appendTiffEntry(&nikon_data, 257, 4, 1, 1);
    try appendTiffEntry(&nikon_data, 258, 3, 1, 8);
    try appendTiffEntry(&nikon_data, 259, 3, 1, 1);
    try appendTiffEntry(&nikon_data, 262, 3, 1, 1);
    try appendTiffEntry(&nikon_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&nikon_data, 277, 3, 1, 1);
    try appendTiffEntry(&nikon_data, 278, 4, 1, 1);
    try appendTiffEntry(&nikon_data, 279, 4, 1, 1);
    try appendTiffEntry(&nikon_data, 305, 2, software.len, @intCast(software_offset));
    try appendU32Le(&nikon_data, 0);
    try nikon_data.appendSlice(std.testing.allocator, software);
    try nikon_data.append(std.testing.allocator, 36);

    try std.testing.expectEqual(Entry.Kind.nikontiff, detectInner("image.tif", nikon_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", nikon_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{36}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{36}, region_plane.data);
}

test "reads stored nikon elements zip entry before baseline tiff" {
    var nikon_data: std.ArrayList(u8) = .empty;
    defer nikon_data.deinit(std.testing.allocator);

    try nikon_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&nikon_data, 42);
    try appendU32Le(&nikon_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const xml = "<x>\x00";
    const xml_offset = ifd_end;
    const pixel_offset = xml_offset + xml.len;

    try appendU16Le(&nikon_data, entry_count);
    try appendTiffEntry(&nikon_data, 256, 4, 1, 1);
    try appendTiffEntry(&nikon_data, 257, 4, 1, 1);
    try appendTiffEntry(&nikon_data, 258, 3, 1, 8);
    try appendTiffEntry(&nikon_data, 259, 3, 1, 1);
    try appendTiffEntry(&nikon_data, 262, 3, 1, 1);
    try appendTiffEntry(&nikon_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&nikon_data, 277, 3, 1, 1);
    try appendTiffEntry(&nikon_data, 278, 4, 1, 1);
    try appendTiffEntry(&nikon_data, 279, 4, 1, 1);
    try appendTiffEntry(&nikon_data, 65332, 4, xml.len, @intCast(xml_offset));
    try appendU32Le(&nikon_data, 0);
    try nikon_data.appendSlice(std.testing.allocator, xml);
    try nikon_data.append(std.testing.allocator, 42);

    try std.testing.expectEqual(Entry.Kind.nikonelements, detectInner("image.tif", nikon_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", nikon_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{42}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{42}, region_plane.data);
}

test "reads stored amira zip entry through inner reader" {
    const header =
        \\# AmiraMesh BINARY-LITTLE-ENDIAN 2.1
        \\define Lattice 2 1 2
        \\Lattice { ushort Data } @1
        \\@1
        \\
    ;
    var amira_data: std.ArrayList(u8) = .empty;
    defer amira_data.deinit(std.testing.allocator);
    try amira_data.appendSlice(std.testing.allocator, header);
    try amira_data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0, 3, 0, 4, 0 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.am", amira_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 4, 0 }, plane.data);
}

test "reads stored arf zip entry through inner reader" {
    var arf_data = [_]u8{0} ** (524 + 8);
    arf_data[0] = 1;
    arf_data[1] = 0;
    @memcpy(arf_data[2..4], "AR");
    writeU16(&arf_data, 4, 2);
    writeU16(&arf_data, 6, 2);
    writeU16(&arf_data, 8, 1);
    writeU16(&arf_data, 10, 16);
    writeU16(&arf_data, 12, 2);
    @memcpy(arf_data[524..], &[_]u8{ 1, 0, 2, 0, 3, 0, 4, 0 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.arf", &arf_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 4, 0 }, plane.data);
}

test "reads stored biorad zip entry through inner reader" {
    var biorad_data = [_]u8{0} ** (76 + 8);
    writeU16(&biorad_data, 0, 2);
    writeU16(&biorad_data, 2, 1);
    writeU16(&biorad_data, 4, 2);
    writeU16(&biorad_data, 14, 0);
    @memcpy(biorad_data[18..26], "PIC test");
    writeU16(&biorad_data, 54, 12345);
    @memcpy(biorad_data[76..], &[_]u8{ 1, 0, 2, 0, 3, 0, 4, 0 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.pic", &biorad_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqualStrings("PIC test", metadata.image_description.?);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 4, 0 }, plane.data);
}

test "reads stored biorad gel zip entry through inner reader" {
    var gel_data: std.ArrayList(u8) = .empty;
    defer gel_data.deinit(std.testing.allocator);
    try appendU16Be(&gel_data, 0xafaf);
    try gel_data.appendNTimes(std.testing.allocator, 0, 158);
    try appendU16Be(&gel_data, 0x81);
    try appendU16Be(&gel_data, 2);
    try gel_data.appendNTimes(std.testing.allocator, 0, 4);
    try appendU32Be(&gel_data, 32);
    try appendU16Be(&gel_data, 2);
    try appendU16Be(&gel_data, 2);
    try appendU16Be(&gel_data, 0);
    try appendU16Be(&gel_data, 1);
    try gel_data.appendSlice(std.testing.allocator, &.{ 3, 4, 1, 2 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.1sc", gel_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored biorad scn zip entry through inner reader" {
    const xml =
        "<root><size_pix width=\"2\" height=\"1\"/><scanner max_value=\"255\"/><channel_count>1</channel_count><endian>little</endian></root>";
    try std.testing.expectEqual(@as(usize, 126), xml.len);
    const scn_data = "Generated by Image Lab\r\n" ++
        "Content-Type: text/xml\r\n" ++
        "Content-Length: 126\r\n\r\n" ++
        xml ++
        "\r\nContent-Type: application/octet-stream\r\n" ++
        "Content-Length: 2\r\n\r\n" ++
        [_]u8{ 5, 6 };

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.scn", scn_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored imaris zip entry through inner reader" {
    var imaris_data = [_]u8{0} ** (336 + 164 + 8);
    writeI32Be(&imaris_data, 0, 5021964);
    writeI32Be(&imaris_data, 4, 1);
    writeI16Be(&imaris_data, 140, 2);
    writeI16Be(&imaris_data, 142, 2);
    writeI16Be(&imaris_data, 144, 2);
    writeI32Be(&imaris_data, 148, 1);
    @memcpy(imaris_data[500..508], &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.ims", &imaris_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 5, 6 }, plane.data);
}

test "reads stored imod zip entry through inner reader" {
    var imod_data = [_]u8{0} ** (8 + 128 + 12);
    @memcpy(imod_data[0..8], "IMODV1.2");
    writeI32Be(&imod_data, 8 + 128, 2);
    writeI32Be(&imod_data, 8 + 128 + 4, 1);
    writeI32Be(&imod_data, 8 + 128 + 8, 3);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "model.mod", &imod_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 3), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 2);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0 }, plane.data);
}

test "reads stored imacon zip entry before baseline tiff" {
    var imacon_data: std.ArrayList(u8) = .empty;
    defer imacon_data.deinit(std.testing.allocator);

    try imacon_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&imacon_data, 42);
    try appendU32Le(&imacon_data, 8);

    const entry_count = 10;
    const pixel_offset = 8 + 2 + entry_count * 12 + 4;

    try appendU16Le(&imacon_data, entry_count);
    try appendTiffEntry(&imacon_data, 256, 4, 1, 1);
    try appendTiffEntry(&imacon_data, 257, 4, 1, 1);
    try appendTiffEntry(&imacon_data, 258, 3, 1, 8);
    try appendTiffEntry(&imacon_data, 259, 3, 1, 1);
    try appendTiffEntry(&imacon_data, 262, 3, 1, 1);
    try appendTiffEntry(&imacon_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&imacon_data, 277, 3, 1, 1);
    try appendTiffEntry(&imacon_data, 278, 4, 1, 1);
    try appendTiffEntry(&imacon_data, 279, 4, 1, 1);
    try appendTiffEntry(&imacon_data, 50457, 2, 4, 0x003e693c);
    try appendU32Le(&imacon_data, 0);
    try imacon_data.append(std.testing.allocator, 33);

    try std.testing.expectEqual(Entry.Kind.imacon, detectInner("image.fff", imacon_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.fff", imacon_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{33}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{33}, region_plane.data);
}

test "reads stored improvision tiff zip entry before baseline tiff" {
    var improvision_data: std.ArrayList(u8) = .empty;
    defer improvision_data.deinit(std.testing.allocator);

    try improvision_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&improvision_data, 42);
    try appendU32Le(&improvision_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const description = "Improvision\nTotalChannels=1\x00";
    const pixel_offset = ifd_end + description.len;

    try appendU16Le(&improvision_data, entry_count);
    try appendTiffEntry(&improvision_data, 256, 4, 1, 1);
    try appendTiffEntry(&improvision_data, 257, 4, 1, 1);
    try appendTiffEntry(&improvision_data, 258, 3, 1, 8);
    try appendTiffEntry(&improvision_data, 259, 3, 1, 1);
    try appendTiffEntry(&improvision_data, 262, 3, 1, 1);
    try appendTiffEntry(&improvision_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&improvision_data, 277, 3, 1, 1);
    try appendTiffEntry(&improvision_data, 278, 4, 1, 1);
    try appendTiffEntry(&improvision_data, 279, 4, 1, 1);
    try appendTiffEntry(&improvision_data, 270, 2, description.len, @intCast(ifd_end));
    try appendU32Le(&improvision_data, 0);
    try improvision_data.appendSlice(std.testing.allocator, description);
    try improvision_data.append(std.testing.allocator, 88);

    try std.testing.expectEqual(Entry.Kind.improvisiontiff, detectInner("image.tif", improvision_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", improvision_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{88}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{88}, region_plane.data);
}

test "reads stored inr zip entry through inner reader" {
    var inr_data: std.ArrayList(u8) = .empty;
    defer inr_data.deinit(std.testing.allocator);
    const header =
        "#INRIMAGE-4#{\n" ++
        "XDIM=1\n" ++
        "YDIM=1\n" ++
        "ZDIM=2\n" ++
        "VDIM=2\n" ++
        "TYPE=signed fixed\n" ++
        "PIXSIZE=16 bits\n" ++
        "##}\n";
    try inr_data.appendSlice(std.testing.allocator, header);
    try inr_data.appendNTimes(std.testing.allocator, 0, 256 - inr_data.items.len);
    try inr_data.appendSlice(std.testing.allocator, &.{ 0, 1, 0, 2, 0, 3, 0, 4 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.inr", inr_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 4), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.int16, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 2);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0, 3 }, plane.data);
}

test "reads stored ionpath mibi zip entry before baseline tiff" {
    var ionpath_data: std.ArrayList(u8) = .empty;
    defer ionpath_data.deinit(std.testing.allocator);

    try ionpath_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&ionpath_data, 42);
    try appendU32Le(&ionpath_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const software = "IonpathMIBI 1.0\x00";
    const pixel_offset = ifd_end + software.len;

    try appendU16Le(&ionpath_data, entry_count);
    try appendTiffEntry(&ionpath_data, 256, 4, 1, 1);
    try appendTiffEntry(&ionpath_data, 257, 4, 1, 1);
    try appendTiffEntry(&ionpath_data, 258, 3, 1, 8);
    try appendTiffEntry(&ionpath_data, 259, 3, 1, 1);
    try appendTiffEntry(&ionpath_data, 262, 3, 1, 1);
    try appendTiffEntry(&ionpath_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&ionpath_data, 277, 3, 1, 1);
    try appendTiffEntry(&ionpath_data, 278, 4, 1, 1);
    try appendTiffEntry(&ionpath_data, 279, 4, 1, 1);
    try appendTiffEntry(&ionpath_data, 305, 2, software.len, @intCast(ifd_end));
    try appendU32Le(&ionpath_data, 0);
    try ionpath_data.appendSlice(std.testing.allocator, software);
    try ionpath_data.append(std.testing.allocator, 67);

    try std.testing.expectEqual(Entry.Kind.ionpathmibi, detectInner("image.tif", ionpath_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", ionpath_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{67}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{67}, region_plane.data);
}

test "reads stored iplab zip entry through extension-gated inner reader" {
    var iplab_data: std.ArrayList(u8) = .empty;
    defer iplab_data.deinit(std.testing.allocator);
    try iplab_data.appendNTimes(std.testing.allocator, 0, 44);
    @memcpy(iplab_data.items[0..4], "iiii");
    writeU32(iplab_data.items, 4, 4);
    writeU32(iplab_data.items, 8, 0x100e);
    writeU32(iplab_data.items, 16, 28);
    writeU32(iplab_data.items, 20, 2);
    writeU32(iplab_data.items, 24, 1);
    writeU32(iplab_data.items, 28, 1);
    writeU32(iplab_data.items, 32, 2);
    writeU32(iplab_data.items, 36, 1);
    writeU32(iplab_data.items, 40, 0);
    try iplab_data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4 });

    try std.testing.expectEqual(Entry.Kind.iplab, detectInner("stack.IPL", iplab_data.items).?);
    try std.testing.expectEqual(null, detectInner("stack.dat", iplab_data.items));

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "stack.ipl", iplab_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads stored ivision zip entry through extension-gated inner reader" {
    var ivision_data: std.ArrayList(u8) = .empty;
    defer ivision_data.deinit(std.testing.allocator);
    try ivision_data.appendNTimes(std.testing.allocator, 0, 72);
    @memcpy(ivision_data.items[0..4], "1.0a");
    ivision_data.items[5] = 6;
    writeI32Be(ivision_data.items, 6, 1);
    writeI32Be(ivision_data.items, 10, 2);
    writeI16Be(ivision_data.items, 20, 2);
    try ivision_data.appendSlice(std.testing.allocator, &.{ 0, 1, 0, 2, 0, 3, 0, 4 });

    try std.testing.expectEqual(Entry.Kind.ivision, detectInner("stack.IPM", ivision_data.items).?);
    try std.testing.expectEqual(null, detectInner("stack.dat", ivision_data.items));

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "stack.ipm", ivision_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0, 3, 0, 4 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads stored jeol mg zip entry through inner reader" {
    const dimension_offset = 0x63c;
    const pixel_offset = dimension_offset + 8 + 540;
    var jeol_data = [_]u8{0} ** (pixel_offset + 2);
    @memcpy(jeol_data[0..2], "MG");
    writeU32(&jeol_data, dimension_offset, 2);
    writeU32(&jeol_data, dimension_offset + 4, 1);
    @memcpy(jeol_data[pixel_offset..], &[_]u8{ 7, 9 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.mg", &jeol_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored khoros zip entry through extension-gated inner reader" {
    var khoros_data: std.ArrayList(u8) = .empty;
    defer khoros_data.deinit(std.testing.allocator);
    try khoros_data.appendNTimes(std.testing.allocator, 0, 1024);
    khoros_data.items[0] = 0xab;
    khoros_data.items[1] = 0x01;
    writeU32(khoros_data.items, 4, 4);
    writeU32(khoros_data.items, 520, 1);
    writeU32(khoros_data.items, 524, 1);
    writeU32(khoros_data.items, 556, 2);
    writeU32(khoros_data.items, 560, 3);
    writeU32(khoros_data.items, 564, 1);
    try khoros_data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 4, 5, 6 });

    try std.testing.expectEqual(Entry.Kind.khoros, detectInner("image.XV", khoros_data.items).?);
    try std.testing.expectEqual(null, detectInner("image.dat", khoros_data.items));

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.xv", khoros_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 3), metadata.samples_per_pixel);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.rgb8, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads stored lim zip entry through extension-gated inner reader" {
    var lim_data: std.ArrayList(u8) = .empty;
    defer lim_data.deinit(std.testing.allocator);
    try lim_data.appendNTimes(std.testing.allocator, 0, 0x94b);
    writeU16(lim_data.items, 0, 2);
    writeU16(lim_data.items, 2, 1);
    writeU16(lim_data.items, 4, 16);
    writeU16(lim_data.items, 6, 0);
    try lim_data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12, 0xcd, 0xab });

    try std.testing.expectEqual(Entry.Kind.lim, detectInner("image.LIM", lim_data.items).?);
    try std.testing.expectEqual(null, detectInner("image.dat", lim_data.items));

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.lim", lim_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 1), metadata.samples_per_pixel);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored mias zip entry before baseline tiff" {
    var mias_data: std.ArrayList(u8) = .empty;
    defer mias_data.deinit(std.testing.allocator);

    try mias_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&mias_data, 42);
    try appendU32Le(&mias_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const software = "SCIL_Image 1.0\x00";
    const software_offset = ifd_end;
    const pixel_offset = software_offset + software.len;

    try appendU16Le(&mias_data, entry_count);
    try appendTiffEntry(&mias_data, 256, 4, 1, 1);
    try appendTiffEntry(&mias_data, 257, 4, 1, 1);
    try appendTiffEntry(&mias_data, 258, 3, 1, 8);
    try appendTiffEntry(&mias_data, 259, 3, 1, 1);
    try appendTiffEntry(&mias_data, 262, 3, 1, 1);
    try appendTiffEntry(&mias_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&mias_data, 277, 3, 1, 1);
    try appendTiffEntry(&mias_data, 278, 4, 1, 1);
    try appendTiffEntry(&mias_data, 279, 4, 1, 1);
    try appendTiffEntry(&mias_data, 305, 2, software.len, @intCast(software_offset));
    try appendU32Le(&mias_data, 0);
    try mias_data.appendSlice(std.testing.allocator, software);
    try mias_data.append(std.testing.allocator, 67);

    try std.testing.expectEqual(Entry.Kind.mias, detectInner("image.tif", mias_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", mias_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{67}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{67}, region_plane.data);
}

test "reads stored metamorph zip entry before baseline tiff" {
    var metamorph_data: std.ArrayList(u8) = .empty;
    defer metamorph_data.deinit(std.testing.allocator);

    try metamorph_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&metamorph_data, 42);
    try appendU32Le(&metamorph_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const software = "MetaMorph 7\x00";
    const pixel_offset = ifd_end + software.len;

    try appendU16Le(&metamorph_data, entry_count);
    try appendTiffEntry(&metamorph_data, 256, 4, 1, 1);
    try appendTiffEntry(&metamorph_data, 257, 4, 1, 1);
    try appendTiffEntry(&metamorph_data, 258, 3, 1, 8);
    try appendTiffEntry(&metamorph_data, 259, 3, 1, 1);
    try appendTiffEntry(&metamorph_data, 262, 3, 1, 1);
    try appendTiffEntry(&metamorph_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&metamorph_data, 277, 3, 1, 1);
    try appendTiffEntry(&metamorph_data, 278, 4, 1, 1);
    try appendTiffEntry(&metamorph_data, 279, 4, 1, 1);
    try appendTiffEntry(&metamorph_data, 305, 2, software.len, @intCast(ifd_end));
    try appendU32Le(&metamorph_data, 0);
    try metamorph_data.appendSlice(std.testing.allocator, software);
    try metamorph_data.append(std.testing.allocator, 99);

    try std.testing.expectEqual(Entry.Kind.metamorph, detectInner("image.tif", metamorph_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", metamorph_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{99}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{99}, region_plane.data);
}

test "reads stored liflim zip entry through extension-gated inner reader" {
    const liflim_data =
        \\version=2.0
        \\pixelFormat=REAL32
        \\x=1
        \\y=1
        \\z=1
        \\numberOfFrames=2
        \\{END}
    ++ [_]u8{ 0, 0, 0, 0, 0, 0, 0x80, 0x3f };

    try std.testing.expectEqual(Entry.Kind.liflim, detectInner("lifetime.FLI", liflim_data).?);
    try std.testing.expectEqual(null, detectInner("lifetime.dat", liflim_data));

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "lifetime.fli", liflim_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_t);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0x80, 0x3f }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads stored aim zip entry through inner reader" {
    var aim_data: std.ArrayList(u8) = .empty;
    defer aim_data.deinit(std.testing.allocator);
    try aim_data.appendNTimes(std.testing.allocator, 0, 160);
    @memcpy(aim_data.items[0..11], "AIMDATA_V02");
    writeU32(aim_data.items, 56, 1);
    writeU32(aim_data.items, 60, 1);
    writeU32(aim_data.items, 64, 2);
    try aim_data.append(std.testing.allocator, 0);
    try aim_data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.aim", aim_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0 }, plane.data);
}

test "reads stored alicona zip entry through inner reader" {
    var alicona_data: std.ArrayList(u8) = .empty;
    defer alicona_data.deinit(std.testing.allocator);
    try alicona_data.appendNTimes(std.testing.allocator, 0, 17);
    @memcpy(alicona_data.items[0..14], "AliconaImaging");
    try appendAliconaRecord(&alicona_data, "TagCount", "4");
    try appendAliconaRecord(&alicona_data, "Rows", "2");
    try appendAliconaRecord(&alicona_data, "Cols", "3");
    try appendAliconaRecord(&alicona_data, "NumberOfPlanes", "1");
    try appendAliconaRecord(&alicona_data, "TextureImageOffset", "329");
    try appendAliconaRecord(&alicona_data, "TexturePtr", "7");
    try std.testing.expectEqual(@as(usize, 329), alicona_data.items.len);
    try alicona_data.appendSlice(std.testing.allocator, &.{ 1, 2, 3, 0, 0, 0, 0, 0 });
    try alicona_data.appendSlice(std.testing.allocator, &.{ 4, 5, 6, 0, 0, 0, 0, 0 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.al3d", alicona_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 3), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, plane.data);
}

test "reads stored apng zip entry through animation reader" {
    var apng_data: std.ArrayList(u8) = .empty;
    defer apng_data.deinit(std.testing.allocator);
    try apng_data.appendSlice(std.testing.allocator, "\x89PNG\r\n\x1a\n");

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 2);
    try appendU32Be(&ihdr, 1);
    try ihdr.appendSlice(std.testing.allocator, &.{ 8, 0, 0, 0, 0 });
    try appendPngChunk(&apng_data, "IHDR", ihdr.items);

    var actl: std.ArrayList(u8) = .empty;
    defer actl.deinit(std.testing.allocator);
    try appendU32Be(&actl, 2);
    try appendU32Be(&actl, 0);
    try appendPngChunk(&apng_data, "acTL", actl.items);

    var fctl: std.ArrayList(u8) = .empty;
    defer fctl.deinit(std.testing.allocator);
    try appendU32Be(&fctl, 0);
    try appendU32Be(&fctl, 2);
    try appendU32Be(&fctl, 1);
    try appendU32Be(&fctl, 0);
    try appendU32Be(&fctl, 0);
    try fctl.appendSlice(std.testing.allocator, &.{ 1, 30, 0, 0, 0, 0 });
    try appendPngChunk(&apng_data, "fcTL", fctl.items);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, &.{ 0, 7, 9 });
    try appendPngChunk(&apng_data, "IDAT", zlib.items);
    try appendPngChunk(&apng_data, "IEND", &.{});

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.png", apng_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "reads stored mng zip entry through mng reader" {
    var mng_data: std.ArrayList(u8) = .empty;
    defer mng_data.deinit(std.testing.allocator);
    try mng_data.appendSlice(std.testing.allocator, "\x8aMNG\r\n\x1a\n");

    var mhdr: std.ArrayList(u8) = .empty;
    defer mhdr.deinit(std.testing.allocator);
    try appendU32Be(&mhdr, 2);
    try appendU32Be(&mhdr, 1);
    try appendU32Be(&mhdr, 1000);
    try appendU32Be(&mhdr, 1);
    try appendU32Be(&mhdr, 1);
    try appendU32Be(&mhdr, 0);
    try appendU32Be(&mhdr, 0);
    try appendPngChunk(&mng_data, "MHDR", mhdr.items);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(std.testing.allocator);
    try appendU32Be(&ihdr, 2);
    try appendU32Be(&ihdr, 1);
    try ihdr.appendSlice(std.testing.allocator, &.{ 8, 0, 0, 0, 0 });
    try appendPngChunk(&mng_data, "IHDR", ihdr.items);

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(std.testing.allocator);
    try appendZlibStored(&zlib, &.{ 0, 7, 9 });
    try appendPngChunk(&mng_data, "IDAT", zlib.items);
    try appendPngChunk(&mng_data, "IEND", &.{});
    try appendPngChunk(&mng_data, "MEND", &.{});

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.mng", mng_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, plane.data);
}

test "reads stored klb zip entry through inner reader" {
    var klb_data: std.ArrayList(u8) = .empty;
    defer klb_data.deinit(std.testing.allocator);
    try klb_data.append(std.testing.allocator, 2);
    for ([_]u32{ 2, 1, 2, 1, 1 }) |dim| try appendU32Le(&klb_data, dim);
    for (0..5) |_| try appendU32Le(&klb_data, 0x3f800000);
    try klb_data.append(std.testing.allocator, 1);
    try klb_data.append(std.testing.allocator, 0);
    try klb_data.appendNTimes(std.testing.allocator, 0, 256);
    for ([_]u32{ 2, 1, 2, 1, 1 }) |dim| try appendU32Le(&klb_data, dim);
    try appendU64Le(&klb_data, 8);
    try klb_data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12, 0xcd, 0xab, 0x78, 0x56, 0xef, 0xbe });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.klb", klb_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0xef, 0xbe }, plane.data);
}

test "reads stored microct zip entry through inner reader" {
    const microct_data =
        "ncaa\n" ++
        "rank=3;\n" ++
        "size=1 1 2;\n" ++
        "bits=16;\n" ++
        "\n" ++
        [_]u8{ 0, 1, 0, 2 };

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.vff", microct_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.int16, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0, 2 }, plane.data);
}

test "reads stored mikroscan zip entry before baseline tiff" {
    var mikroscan_data: std.ArrayList(u8) = .empty;
    defer mikroscan_data.deinit(std.testing.allocator);

    try mikroscan_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&mikroscan_data, 42);
    try appendU32Le(&mikroscan_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const description = "Mikroscan Image|Aperio compatible\x00";
    const description_offset = ifd_end;
    const pixel_offset = description_offset + description.len;

    try appendU16Le(&mikroscan_data, entry_count);
    try appendTiffEntry(&mikroscan_data, 256, 4, 1, 1);
    try appendTiffEntry(&mikroscan_data, 257, 4, 1, 1);
    try appendTiffEntry(&mikroscan_data, 258, 3, 1, 8);
    try appendTiffEntry(&mikroscan_data, 259, 3, 1, 1);
    try appendTiffEntry(&mikroscan_data, 262, 3, 1, 1);
    try appendTiffEntry(&mikroscan_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&mikroscan_data, 277, 3, 1, 1);
    try appendTiffEntry(&mikroscan_data, 278, 4, 1, 1);
    try appendTiffEntry(&mikroscan_data, 279, 4, 1, 1);
    try appendTiffEntry(&mikroscan_data, 270, 2, description.len, @intCast(description_offset));
    try appendU32Le(&mikroscan_data, 0);
    try mikroscan_data.appendSlice(std.testing.allocator, description);
    try mikroscan_data.append(std.testing.allocator, 123);

    try std.testing.expectEqual(Entry.Kind.mikroscan, detectInner("image.tif", mikroscan_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", mikroscan_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{123}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{123}, region_plane.data);
}

test "reads stored molecular imaging zip entry through inner reader" {
    var mi_data: std.ArrayList(u8) = .empty;
    defer mi_data.deinit(std.testing.allocator);
    try mi_data.appendSlice(std.testing.allocator,
        \\00 UK SOFT
        \\samples_x 2
        \\samples_y 1
        \\
    );
    try mi_data.appendSlice(std.testing.allocator, "buffer_id 0\r\n");
    try mi_data.appendSlice(std.testing.allocator, "buffer_id 1\r\n");
    try mi_data.appendSlice(std.testing.allocator, "Data_section  \r\n");
    try mi_data.appendSlice(std.testing.allocator, &.{ 1, 0, 2, 0, 3, 0, 4, 0 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.stp", mi_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 4, 0 }, plane.data);
}

test "reads stored mrc zip entry through extension-gated inner reader" {
    var mrc_data = [_]u8{0} ** (1024 + 4);
    writeU32(&mrc_data, 0, 2);
    writeU32(&mrc_data, 4, 2);
    writeU32(&mrc_data, 8, 1);
    writeU32(&mrc_data, 12, 0);
    mrc_data[212] = 68;
    @memcpy(mrc_data[1024..], &[_]u8{ 1, 2, 3, 4 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "stack.MRC", &mrc_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4, 1, 2 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored mrw zip entry through inner reader" {
    var mrw_data = [_]u8{0} ** (8 + 52 + 6);
    @memcpy(mrw_data[0..4], "\x00MRM");
    std.mem.writeInt(u32, mrw_data[4..8], 52, .big);

    @memcpy(mrw_data[8..12], "\x00PRD");
    std.mem.writeInt(u32, mrw_data[12..16], 24, .big);
    std.mem.writeInt(u16, mrw_data[24..26], 2, .big);
    std.mem.writeInt(u16, mrw_data[26..28], 2, .big);
    std.mem.writeInt(u16, mrw_data[28..30], 2, .big);
    std.mem.writeInt(u16, mrw_data[30..32], 2, .big);
    mrw_data[32] = 12;
    mrw_data[34] = 0;
    mrw_data[39] = 1;

    @memcpy(mrw_data[40..44], "\x00WBG");
    std.mem.writeInt(u32, mrw_data[44..48], 12, .big);
    std.mem.writeInt(u16, mrw_data[52..54], 64, .big);
    std.mem.writeInt(u16, mrw_data[54..56], 64, .big);
    std.mem.writeInt(u16, mrw_data[56..58], 64, .big);
    std.mem.writeInt(u16, mrw_data[58..60], 64, .big);
    @memcpy(mrw_data[60..], &[_]u8{ 0x00, 0xa0, 0x14, 0x02, 0x80, 0x1e });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.mrw", &mrw_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(bio.PixelType.rgb16, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0, 10, 0, 30, 0, 30 }, plane.data[0..6]);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored kodak zip entry through inner reader" {
    var kodak_data: std.ArrayList(u8) = .empty;
    defer kodak_data.deinit(std.testing.allocator);
    try kodak_data.appendSlice(std.testing.allocator, "xxDTagxx");
    try kodak_data.appendSlice(std.testing.allocator, "GBiH");
    try kodak_data.appendNTimes(std.testing.allocator, 0, 20);
    try appendU32Be(&kodak_data, 2);
    try appendU32Be(&kodak_data, 1);
    try kodak_data.appendSlice(std.testing.allocator, "BSfD");
    try kodak_data.appendNTimes(std.testing.allocator, 0, 20);
    try kodak_data.appendSlice(std.testing.allocator, &.{ 0x3f, 0x80, 0, 0, 0x40, 0, 0, 0 });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.bip", kodak_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.float32, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0x3f, 0x80, 0, 0, 0x40, 0, 0, 0 }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored topometrix zip entry through inner reader" {
    var topometrix_data: std.ArrayList(u8) = .empty;
    defer topometrix_data.deinit(std.testing.allocator);
    try topometrix_data.appendNTimes(std.testing.allocator, 0, 900);
    @memcpy(topometrix_data.items[0..2], "#R");
    @memcpy(topometrix_data.items[2..6], "4.00");
    @memcpy(topometrix_data.items[8..12], "0900");
    writeU16(topometrix_data.items, 406, 2);
    writeU16(topometrix_data.items, 410, 1);
    try topometrix_data.appendSlice(std.testing.allocator, &.{ 0x34, 0x12, 0xcd, 0xab });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tfr", topometrix_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored trestle zip entry before baseline tiff" {
    var trestle_data: std.ArrayList(u8) = .empty;
    defer trestle_data.deinit(std.testing.allocator);

    try trestle_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&trestle_data, 42);
    try appendU32Le(&trestle_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const copyright = "Copyright Trestle Corp.\x00";
    const copyright_offset = ifd_end;
    const pixel_offset = copyright_offset + copyright.len;

    try appendU16Le(&trestle_data, entry_count);
    try appendTiffEntry(&trestle_data, 256, 4, 1, 1);
    try appendTiffEntry(&trestle_data, 257, 4, 1, 1);
    try appendTiffEntry(&trestle_data, 258, 3, 1, 8);
    try appendTiffEntry(&trestle_data, 259, 3, 1, 1);
    try appendTiffEntry(&trestle_data, 262, 3, 1, 1);
    try appendTiffEntry(&trestle_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&trestle_data, 277, 3, 1, 1);
    try appendTiffEntry(&trestle_data, 278, 4, 1, 1);
    try appendTiffEntry(&trestle_data, 279, 4, 1, 1);
    try appendTiffEntry(&trestle_data, 33432, 2, copyright.len, @intCast(copyright_offset));
    try appendU32Le(&trestle_data, 0);
    try trestle_data.appendSlice(std.testing.allocator, copyright);
    try trestle_data.append(std.testing.allocator, 18);

    try std.testing.expectEqual(Entry.Kind.trestle, detectInner("image.tif", trestle_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.tif", trestle_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{18}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{18}, region_plane.data);
}

test "reads stored ubm zip entry through extension-gated inner reader" {
    var ubm_data: std.ArrayList(u8) = .empty;
    defer ubm_data.deinit(std.testing.allocator);
    try ubm_data.appendNTimes(std.testing.allocator, 0, 128);
    writeU32(ubm_data.items, 44, 2);
    writeU32(ubm_data.items, 48, 2);
    try ubm_data.appendSlice(std.testing.allocator, &.{ 1, 0, 0, 0, 2, 0, 0, 0, 0xaa, 0xaa, 0xaa, 0xaa });
    try ubm_data.appendSlice(std.testing.allocator, &.{ 3, 0, 0, 0, 4, 0, 0, 0, 0xbb, 0xbb, 0xbb, 0xbb });

    try std.testing.expectEqual(Entry.Kind.ubm, detectInner("surface.PR3", ubm_data.items).?);
    try std.testing.expectEqual(null, detectInner("surface.dat", ubm_data.items));

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "surface.pr3", ubm_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint32, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{
        1, 0, 0, 0,
        2, 0, 0, 0,
        3, 0, 0, 0,
        4, 0, 0, 0,
    }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored vectra zip entry before baseline tiff" {
    var vectra_data: std.ArrayList(u8) = .empty;
    defer vectra_data.deinit(std.testing.allocator);

    try vectra_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&vectra_data, 42);
    try appendU32Le(&vectra_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const software = "PerkinElmer-QPI 1.0\x00";
    const software_offset = ifd_end;
    const pixel_offset = software_offset + software.len;

    try appendU16Le(&vectra_data, entry_count);
    try appendTiffEntry(&vectra_data, 256, 4, 1, 1);
    try appendTiffEntry(&vectra_data, 257, 4, 1, 1);
    try appendTiffEntry(&vectra_data, 258, 3, 1, 8);
    try appendTiffEntry(&vectra_data, 259, 3, 1, 1);
    try appendTiffEntry(&vectra_data, 262, 3, 1, 1);
    try appendTiffEntry(&vectra_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&vectra_data, 277, 3, 1, 1);
    try appendTiffEntry(&vectra_data, 278, 4, 1, 1);
    try appendTiffEntry(&vectra_data, 279, 4, 1, 1);
    try appendTiffEntry(&vectra_data, 305, 2, software.len, @intCast(software_offset));
    try appendU32Le(&vectra_data, 0);
    try vectra_data.appendSlice(std.testing.allocator, software);
    try vectra_data.append(std.testing.allocator, 223);

    try std.testing.expectEqual(Entry.Kind.vectra, detectInner("image.qptiff", vectra_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.qptiff", vectra_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{223}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{223}, region_plane.data);
}

test "reads stored ventana zip entry before baseline tiff" {
    var ventana_data: std.ArrayList(u8) = .empty;
    defer ventana_data.deinit(std.testing.allocator);

    try ventana_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&ventana_data, 42);
    try appendU32Le(&ventana_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const xml = "<iScan ScanRes=\"0.25\" />\x00";
    const pixel_offset = ifd_end + xml.len;

    try appendU16Le(&ventana_data, entry_count);
    try appendTiffEntry(&ventana_data, 256, 4, 1, 1);
    try appendTiffEntry(&ventana_data, 257, 4, 1, 1);
    try appendTiffEntry(&ventana_data, 258, 3, 1, 8);
    try appendTiffEntry(&ventana_data, 259, 3, 1, 1);
    try appendTiffEntry(&ventana_data, 262, 3, 1, 1);
    try appendTiffEntry(&ventana_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&ventana_data, 277, 3, 1, 1);
    try appendTiffEntry(&ventana_data, 278, 4, 1, 1);
    try appendTiffEntry(&ventana_data, 279, 4, 1, 1);
    try appendTiffEntry(&ventana_data, 700, 2, xml.len, @intCast(ifd_end));
    try appendU32Le(&ventana_data, 0);
    try ventana_data.appendSlice(std.testing.allocator, xml);
    try ventana_data.append(std.testing.allocator, 144);

    try std.testing.expectEqual(Entry.Kind.ventana, detectInner("image.bif", ventana_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.bif", ventana_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{144}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{144}, region_plane.data);
}

test "reads stored watop zip entry through inner reader" {
    var watop_data = [_]u8{0} ** (4864 + 4);
    @memcpy(watop_data[0..25], "0TOPSystem W.A.Technology");
    @memcpy(watop_data[49..57], "WAT note");
    writeU32(&watop_data, 251, 2);
    writeU32(&watop_data, 255, 1);
    @memcpy(watop_data[4864..], &[_]u8{ 0x34, 0x12, 0xcd, 0xab });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.wat", &watop_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.int16, metadata.pixel_type);
    try std.testing.expectEqualStrings("WAT note", metadata.image_description.?);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xcd, 0xab }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored vg sam zip entry through inner reader" {
    var vgsam_data = [_]u8{0} ** (368 + 4);
    @memcpy(vgsam_data[0..3], "VGS");
    std.mem.writeInt(u32, vgsam_data[348..352], 2, .big);
    std.mem.writeInt(u32, vgsam_data[352..356], 1, .big);
    std.mem.writeInt(u32, vgsam_data[360..364], 2, .big);
    @memcpy(vgsam_data[368..], &[_]u8{ 0x12, 0x34, 0xab, 0xcd });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.dti", &vgsam_data);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(!metadata.little_endian);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0xab, 0xcd }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored varian fdf zip entry through inner reader" {
    var fdf_data: std.ArrayList(u8) = .empty;
    defer fdf_data.deinit(std.testing.allocator);
    try fdf_data.appendSlice(std.testing.allocator,
        \\float  matrix[] = {2, 2, 2};
        \\char  *storage = "integer";
        \\int  bits = 16;
        \\int  bigendian = 0;
        \\
    );
    try fdf_data.append(std.testing.allocator, 0x0c);
    try fdf_data.appendSlice(std.testing.allocator, &.{
        1, 0, 2, 0,
        3, 0, 4, 0,
        5, 0, 6, 0,
        7, 0, 8, 0,
    });

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.fdf", fdf_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 2), metadata.width);
    try std.testing.expectEqual(@as(u32, 2), metadata.height);
    try std.testing.expectEqual(@as(u16, 2), metadata.size_z);
    try std.testing.expectEqual(@as(u32, 2), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);
    try std.testing.expect(metadata.little_endian);

    const plane = try readPlaneIndex(std.testing.allocator, data.items, 1);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{
        7, 0, 8, 0,
        5, 0, 6, 0,
    }, plane.data);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 2));
}

test "reads stored zeiss lms zip entry through inner reader" {
    const lms_width = 1280;
    const lms_height = 1024;
    const thumbnail_bytes = lms_width * lms_height * 3;
    const lut_bytes = 256 * 4;
    const plane_len = lms_width * lms_height * 2;

    var lms_data: std.ArrayList(u8) = .empty;
    defer lms_data.deinit(std.testing.allocator);
    try lms_data.appendNTimes(std.testing.allocator, 0, 22);
    @memcpy(lms_data.items[0.."LMSFLE".len], "LMSFLE");
    try lms_data.appendSlice(std.testing.allocator, "BM6!");
    try lms_data.appendNTimes(std.testing.allocator, 0, 50);
    try lms_data.appendNTimes(std.testing.allocator, 0, thumbnail_bytes);
    try lms_data.appendSlice(std.testing.allocator, "BM6!");
    try lms_data.appendNTimes(std.testing.allocator, 0, 50);
    try lms_data.appendNTimes(std.testing.allocator, 0, lut_bytes);
    const pixel_offset = lms_data.items.len;
    try lms_data.appendNTimes(std.testing.allocator, 0, plane_len);
    lms_data.items[pixel_offset] = 0x34;
    lms_data.items[pixel_offset + 1] = 0x12;

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.lms", lms_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, lms_width), metadata.width);
    try std.testing.expectEqual(@as(u32, lms_height), metadata.height);
    try std.testing.expectEqual(@as(u32, 1), metadata.plane_count);
    try std.testing.expectEqual(bio.PixelType.uint16, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqual(@as(usize, plane_len), plane.data.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, plane.data[0..2]);
    try std.testing.expectError(error.InvalidPlaneIndex, readPlaneIndex(std.testing.allocator, data.items, 1));
}

test "reads stored zeiss lsm zip entry before baseline tiff" {
    var lsm_data: std.ArrayList(u8) = .empty;
    defer lsm_data.deinit(std.testing.allocator);

    try lsm_data.appendSlice(std.testing.allocator, "II");
    try appendU16Le(&lsm_data, 42);
    try appendU32Le(&lsm_data, 8);

    const entry_count = 10;
    const ifd_end = 8 + 2 + entry_count * 12 + 4;
    const lsm_offset = ifd_end;
    const lsm_bytes = 32;
    const pixel_offset = lsm_offset + lsm_bytes;

    try appendU16Le(&lsm_data, entry_count);
    try appendTiffEntry(&lsm_data, 256, 4, 1, 1);
    try appendTiffEntry(&lsm_data, 257, 4, 1, 1);
    try appendTiffEntry(&lsm_data, 258, 3, 1, 8);
    try appendTiffEntry(&lsm_data, 259, 3, 1, 1);
    try appendTiffEntry(&lsm_data, 262, 3, 1, 1);
    try appendTiffEntry(&lsm_data, 273, 4, 1, @intCast(pixel_offset));
    try appendTiffEntry(&lsm_data, 277, 3, 1, 1);
    try appendTiffEntry(&lsm_data, 278, 4, 1, 1);
    try appendTiffEntry(&lsm_data, 279, 4, 1, 1);
    try appendTiffEntry(&lsm_data, 34412, 1, lsm_bytes, @intCast(lsm_offset));
    try appendU32Le(&lsm_data, 0);
    try lsm_data.appendNTimes(std.testing.allocator, 0, lsm_bytes);
    try lsm_data.append(std.testing.allocator, 0x5a);

    try std.testing.expectEqual(Entry.Kind.zeisslsm, detectInner("image.lsm", lsm_data.items).?);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendStoredEntry(&data, "image.lsm", lsm_data.items);

    const metadata = try readMetadata(data.items);
    try std.testing.expectEqualStrings("zip", metadata.format);
    try std.testing.expectEqual(@as(u32, 1), metadata.width);
    try std.testing.expectEqual(@as(u32, 1), metadata.height);
    try std.testing.expectEqual(bio.PixelType.uint8, metadata.pixel_type);

    const plane = try readPlane(std.testing.allocator, data.items);
    defer std.testing.allocator.free(plane.data);
    try std.testing.expectEqualStrings("zip", plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{0x5a}, plane.data);

    const region_plane = try readRegionIndex(std.testing.allocator, data.items, 0, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    defer std.testing.allocator.free(region_plane.data);
    try std.testing.expectEqualStrings("zip", region_plane.metadata.format);
    try std.testing.expectEqualSlices(u8, &.{0x5a}, region_plane.data);
}

test "rejects unsupported zip compression methods" {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try appendEntryWithMethod(&data, 12, "image.pgm", "compressed bytes");

    try std.testing.expectError(error.UnsupportedFormat, readMetadata(data.items));
}
