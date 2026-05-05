const std = @import("std");

pub const afi = @import("readers/afi.zig");
pub const aim = @import("readers/aim.zig");
pub const alicona = @import("readers/alicona.zig");
pub const amira = @import("readers/amira.zig");
pub const analyze = @import("readers/analyze.zig");
pub const apl = @import("readers/apl.zig");
pub const apng = @import("readers/apng.zig");
pub const arf = @import("readers/arf.zig");
pub const avi = @import("readers/avi.zig");
pub const bdpathway = @import("readers/bdpathway.zig");
pub const biorad = @import("readers/biorad.zig");
pub const bioradgel = @import("readers/bioradgel.zig");
pub const bioradscn = @import("readers/bioradscn.zig");
pub const bmp = @import("readers/bmp.zig");
pub const bruker = @import("readers/bruker.zig");
pub const burleigh = @import("readers/burleigh.zig");
pub const canonraw = @import("readers/canonraw.zig");
pub const cellomics = @import("readers/cellomics.zig");
pub const cellsens = @import("readers/cellsens.zig");
pub const cellvoyager = @import("readers/cellvoyager.zig");
pub const cellworx = @import("readers/cellworx.zig");
pub const columbus = @import("readers/columbus.zig");
pub const cv7000 = @import("readers/cv7000.zig");
pub const dcimg = @import("readers/dcimg.zig");
pub const deltavision = @import("readers/deltavision.zig");
pub const dicom = @import("readers/dicom.zig");
pub const dng = @import("readers/dng.zig");
pub const ecat7 = @import("readers/ecat7.zig");
pub const eps = @import("readers/eps.zig");
pub const fake = @import("readers/fake.zig");
pub const fei = @import("readers/fei.zig");
pub const feitiff = @import("readers/feitiff.zig");
pub const filepattern = @import("readers/filepattern.zig");
pub const fits = @import("readers/fits.zig");
pub const flex = @import("readers/flex.zig");
pub const flowsight = @import("readers/flowsight.zig");
pub const fluoview = @import("readers/fluoview.zig");
pub const fv1000 = @import("readers/fv1000.zig");
pub const fuji = @import("readers/fuji.zig");
pub const gatan = @import("readers/gatan.zig");
pub const gatandm2 = @import("readers/gatandm2.zig");
pub const gel = @import("readers/gel.zig");
pub const gif = @import("readers/gif.zig");
pub const hamamatsuvms = @import("readers/hamamatsuvms.zig");
pub const his = @import("readers/his.zig");
pub const hitachi = @import("readers/hitachi.zig");
pub const hrdgdf = @import("readers/hrdgdf.zig");
pub const i2i = @import("readers/i2i.zig");
pub const imacon = @import("readers/imacon.zig");
pub const im3 = @import("readers/im3.zig");
pub const imagic = @import("readers/imagic.zig");
pub const ics = @import("readers/ics.zig");
pub const incell = @import("readers/incell.zig");
pub const incell3000 = @import("readers/incell3000.zig");
pub const imaris = @import("readers/imaris.zig");
pub const imaristiff = @import("readers/imaristiff.zig");
pub const imod = @import("readers/imod.zig");
pub const improvisiontiff = @import("readers/improvisiontiff.zig");
pub const imspector = @import("readers/imspector.zig");
pub const inr = @import("readers/inr.zig");
pub const inveon = @import("readers/inveon.zig");
pub const ionpathmibi = @import("readers/ionpathmibi.zig");
pub const iplab = @import("readers/iplab.zig");
pub const ipw = @import("readers/ipw.zig");
pub const ivision = @import("readers/ivision.zig");
pub const jdce = @import("readers/jdce.zig");
pub const jeol = @import("readers/jeol.zig");
pub const jpeg = @import("readers/jpeg.zig");
pub const jpeg2000 = @import("readers/jpeg2000.zig");
pub const jpk = @import("readers/jpk.zig");
pub const jpx = @import("readers/jpx.zig");
pub const khoros = @import("readers/khoros.zig");
pub const klb = @import("readers/klb.zig");
pub const kodak = @import("readers/kodak.zig");
pub const l2d = @import("readers/l2d.zig");
pub const leo = @import("readers/leo.zig");
pub const leicascn = @import("readers/leicascn.zig");
pub const lif = @import("readers/lif.zig");
pub const liflim = @import("readers/liflim.zig");
pub const lim = @import("readers/lim.zig");
pub const lof = @import("readers/lof.zig");
pub const metamorph = @import("readers/metamorph.zig");
pub const metaxpress = @import("readers/metaxpress.zig");
pub const mias = @import("readers/mias.zig");
pub const micromanager = @import("readers/micromanager.zig");
pub const microct = @import("readers/microct.zig");
pub const mikroscan = @import("readers/mikroscan.zig");
pub const minc = @import("readers/minc.zig");
pub const molecularimaging = @import("readers/molecularimaging.zig");
pub const mng = @import("readers/mng.zig");
pub const netpbm = @import("readers/netpbm.zig");
pub const mrw = @import("readers/mrw.zig");
pub const mrc = @import("readers/mrc.zig");
pub const naf = @import("readers/naf.zig");
pub const nd2 = @import("readers/nd2.zig");
pub const ndpi = @import("readers/ndpi.zig");
pub const ndpis = @import("readers/ndpis.zig");
pub const nifti = @import("readers/nifti.zig");
pub const nikon = @import("readers/nikon.zig");
pub const nikonelements = @import("readers/nikonelements.zig");
pub const nikontiff = @import("readers/nikontiff.zig");
pub const nrrd = @import("readers/nrrd.zig");
pub const obf = @import("readers/obf.zig");
pub const oir = @import("readers/oir.zig");
pub const omexml = @import("readers/omexml.zig");
pub const ometiff = @import("readers/ometiff.zig");
pub const operetta = @import("readers/operetta.zig");
pub const openlab = @import("readers/openlab.zig");
pub const openlabraw = @import("readers/openlabraw.zig");
pub const oxfordinstruments = @import("readers/oxfordinstruments.zig");
pub const pcx = @import("readers/pcx.zig");
pub const pci = @import("readers/pci.zig");
pub const pcoraw = @import("readers/pcoraw.zig");
pub const pds = @import("readers/pds.zig");
pub const perkinelmer = @import("readers/perkinelmer.zig");
pub const pict = @import("readers/pict.zig");
pub const photoshoptiff = @import("readers/photoshoptiff.zig");
pub const png = @import("readers/png.zig");
pub const povray = @import("readers/povray.zig");
pub const prairie = @import("readers/prairie.zig");
pub const pqbin = @import("readers/pqbin.zig");
pub const psd = @import("readers/psd.zig");
pub const pyramidtiff = @import("readers/pyramidtiff.zig");
pub const qt = @import("readers/qt.zig");
pub const quesant = @import("readers/quesant.zig");
pub const rcpnl = @import("readers/rcpnl.zig");
pub const rhk = @import("readers/rhk.zig");
pub const sbig = @import("readers/sbig.zig");
pub const scanr = @import("readers/scanr.zig");
pub const sdt = @import("readers/sdt.zig");
pub const seiko = @import("readers/seiko.zig");
pub const seq = @import("readers/seq.zig");
pub const sif = @import("readers/sif.zig");
pub const simplepci = @import("readers/simplepci.zig");
pub const sis = @import("readers/sis.zig");
pub const slidebooktiff = @import("readers/slidebooktiff.zig");
pub const spider = @import("readers/spider.zig");
pub const spe = @import("readers/spe.zig");
pub const spc = @import("readers/spc.zig");
pub const smcamera = @import("readers/smcamera.zig");
pub const svs = @import("readers/svs.zig");
pub const tcs = @import("readers/tcs.zig");
pub const tecan = @import("readers/tecan.zig");
pub const tga = @import("readers/tga.zig");
pub const text = @import("readers/text.zig");
pub const tiff = @import("readers/tiff.zig");
pub const tillvision = @import("readers/tillvision.zig");
pub const topometrix = @import("readers/topometrix.zig");
pub const trestle = @import("readers/trestle.zig");
pub const ubm = @import("readers/ubm.zig");
pub const unisoku = @import("readers/unisoku.zig");
pub const varianfdf = @import("readers/varianfdf.zig");
pub const vectra = @import("readers/vectra.zig");
pub const veeco = @import("readers/veeco.zig");
pub const ventana = @import("readers/ventana.zig");
pub const visitech = @import("readers/visitech.zig");
pub const vgsam = @import("readers/vgsam.zig");
pub const volocityclipping = @import("readers/volocityclipping.zig");
pub const watop = @import("readers/watop.zig");
pub const xlef = @import("readers/xlef.zig");
pub const zeissczi = @import("readers/zeissczi.zig");
pub const zeisslms = @import("readers/zeisslms.zig");
pub const zeisslsm = @import("readers/zeisslsm.zig");
pub const zeisstiff = @import("readers/zeisstiff.zig");
pub const zeissxrm = @import("readers/zeissxrm.zig");
pub const zip = @import("readers/zip.zig");

pub const ReaderError = error{
    UnsupportedFormat,
    InvalidFormat,
    InvalidPlaneIndex,
    InvalidRegion,
    UnsupportedVariant,
    TruncatedData,
    OutOfMemory,
};

pub const PixelType = enum {
    uint8,
    uint16,
    uint32,
    int8,
    int16,
    int32,
    float32,
    float64,
    rgb8,
    rgb16,
    rgba8,
    rgba16,

    pub fn name(self: PixelType) []const u8 {
        return switch (self) {
            .uint8 => "uint8",
            .uint16 => "uint16",
            .uint32 => "uint32",
            .int8 => "int8",
            .int16 => "int16",
            .int32 => "int32",
            .float32 => "float32",
            .float64 => "float64",
            .rgb8 => "rgb8",
            .rgb16 => "rgb16",
            .rgba8 => "rgba8",
            .rgba16 => "rgba16",
        };
    }

    pub fn bytesPerSample(self: PixelType) usize {
        return switch (self) {
            .uint8, .int8, .rgb8, .rgba8 => 1,
            .uint16, .int16, .rgb16, .rgba16 => 2,
            .uint32, .int32, .float32 => 4,
            .float64 => 8,
        };
    }
};

pub const Metadata = struct {
    format: []const u8,
    width: u32,
    height: u32,
    size_c: u16,
    samples_per_pixel: u16 = 0,
    size_z: u16 = 1,
    size_t: u16 = 1,
    pixel_type: PixelType,
    little_endian: bool = false,
    plane_count: u32 = 1,
    image_description: ?[]const u8 = null,
    dimension_order: ?[]const u8 = null,

    pub fn bytesPerPixel(self: Metadata) usize {
        const samples = if (self.samples_per_pixel == 0) self.size_c else self.samples_per_pixel;
        return @as(usize, samples) * self.pixel_type.bytesPerSample();
    }

    pub fn planeIndex(self: Metadata, z: u32, c: u32, t: u32) ReaderError!u32 {
        if (z >= self.size_z or c >= self.size_c or t >= self.size_t) return error.InvalidPlaneIndex;
        const order = self.dimension_order orelse "XYZCT";
        const z_stride = try self.axisStride(order, 'Z');
        const c_stride = try self.axisStride(order, 'C');
        const t_stride = try self.axisStride(order, 'T');
        const z_part = std.math.mul(u32, z, z_stride) catch return error.InvalidPlaneIndex;
        const c_part = std.math.mul(u32, c, c_stride) catch return error.InvalidPlaneIndex;
        const t_part = std.math.mul(u32, t, t_stride) catch return error.InvalidPlaneIndex;
        const index = std.math.add(u32, std.math.add(u32, z_part, c_part) catch return error.InvalidPlaneIndex, t_part) catch return error.InvalidPlaneIndex;
        if (index >= self.plane_count) return error.InvalidPlaneIndex;
        return index;
    }

    fn axisStride(self: Metadata, order: []const u8, axis: u8) ReaderError!u32 {
        const axis_pos = std.mem.indexOfScalar(u8, order, axis) orelse return defaultAxisStride(self, axis);
        if (axis_pos < 2) return error.InvalidFormat;
        var stride: u32 = 1;
        for (order[2..axis_pos]) |prior_axis| {
            stride = std.math.mul(u32, stride, self.axisSize(prior_axis)) catch return error.InvalidPlaneIndex;
        }
        return stride;
    }

    fn axisSize(self: Metadata, axis: u8) u32 {
        return switch (axis) {
            'Z' => self.size_z,
            'C' => self.size_c,
            'T' => self.size_t,
            else => 1,
        };
    }

    fn defaultAxisStride(self: Metadata, axis: u8) u32 {
        return switch (axis) {
            'Z' => 1,
            'C' => self.size_z,
            'T' => @as(u32, self.size_z) * @as(u32, self.size_c),
            else => 1,
        };
    }
};

pub const Plane = struct {
    metadata: Metadata,
    data: []u8,
};

pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub fn full(metadata: Metadata) Region {
        return .{ .x = 0, .y = 0, .width = metadata.width, .height = metadata.height };
    }

    pub fn isFull(self: Region, metadata: Metadata) bool {
        return self.x == 0 and self.y == 0 and self.width == metadata.width and self.height == metadata.height;
    }

    pub fn validate(self: Region, metadata: Metadata) ReaderError!void {
        if (self.width == 0 or self.height == 0) return error.InvalidRegion;
        if (self.x > metadata.width or self.y > metadata.height) return error.InvalidRegion;
        if (self.width > metadata.width - self.x or self.height > metadata.height - self.y) return error.InvalidRegion;
    }
};

pub const FormatDescriptor = struct {
    id: []const u8,
    name: []const u8,
    extensions: []const []const u8,
    can_read_pixels: bool,
};

pub const formats = [_]FormatDescriptor{
    .{
        .id = "afi",
        .name = "Aperio AFI",
        .extensions = &.{"afi"},
        .can_read_pixels = true,
    },
    .{
        .id = "aim",
        .name = "AIM int16 volume",
        .extensions = &.{"aim"},
        .can_read_pixels = true,
    },
    .{
        .id = "alicona",
        .name = "Alicona AL3D",
        .extensions = &.{"al3d"},
        .can_read_pixels = true,
    },
    .{
        .id = "amira",
        .name = "AmiraMesh raw binary lattice",
        .extensions = &.{ "am", "amiramesh", "grey", "hx", "labels" },
        .can_read_pixels = true,
    },
    .{
        .id = "analyze",
        .name = "Analyze 7.5",
        .extensions = &.{ "hdr", "img" },
        .can_read_pixels = true,
    },
    .{
        .id = "apl",
        .name = "Olympus APL TIFF dataset",
        .extensions = &.{ "apl", "tnb", "mtb", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "arf",
        .name = "Axon Raw Format",
        .extensions = &.{"arf"},
        .can_read_pixels = true,
    },
    .{
        .id = "avi",
        .name = "Audio Video Interleave uncompressed DIB",
        .extensions = &.{"avi"},
        .can_read_pixels = true,
    },
    .{
        .id = "apng",
        .name = "Animated PNG default image",
        .extensions = &.{"png"},
        .can_read_pixels = true,
    },
    .{
        .id = "biorad",
        .name = "Bio-Rad PIC",
        .extensions = &.{"pic"},
        .can_read_pixels = true,
    },
    .{
        .id = "bdpathway",
        .name = "BD Pathway TIFF",
        .extensions = &.{ "exp", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "bd",
        .name = "BD Pathway",
        .extensions = &.{ "exp", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "bioradgel",
        .name = "Bio-Rad GEL",
        .extensions = &.{"1sc"},
        .can_read_pixels = true,
    },
    .{
        .id = "bioradscn",
        .name = "Bio-Rad SCN",
        .extensions = &.{"scn"},
        .can_read_pixels = true,
    },
    .{
        .id = "netpbm",
        .name = "Netpbm PBM/PGM/PPM/PAM",
        .extensions = &.{ "pbm", "pgm", "ppm", "pnm", "pam" },
        .can_read_pixels = true,
    },
    .{
        .id = "pgm",
        .name = "Portable Any Map",
        .extensions = &.{ "pbm", "pgm", "ppm" },
        .can_read_pixels = true,
    },
    .{
        .id = "bmp",
        .name = "Windows BMP 1/4/8/16/24/32-bit",
        .extensions = &.{"bmp"},
        .can_read_pixels = true,
    },
    .{
        .id = "bruker",
        .name = "Bruker MRI",
        .extensions = &.{ "acqp", "fid", "reco", "2dseq" },
        .can_read_pixels = true,
    },
    .{
        .id = "burleigh",
        .name = "Burleigh SPM",
        .extensions = &.{"img"},
        .can_read_pixels = true,
    },
    .{
        .id = "canonraw",
        .name = "Canon RAW fixed-length Bayer",
        .extensions = &.{ "crw", "raw" },
        .can_read_pixels = true,
    },
    .{
        .id = "cellomics",
        .name = "Cellomics C01/DIB",
        .extensions = &.{ "c01", "dib" },
        .can_read_pixels = true,
    },
    .{
        .id = "cellsens",
        .name = "Olympus cellSens VSI",
        .extensions = &.{ "vsi", "ets" },
        .can_read_pixels = true,
    },
    .{
        .id = "cellvoyager",
        .name = "Yokogawa CellVoyager TIFF dataset",
        .extensions = &.{ "xml", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "cellworx",
        .name = "CellWorx HTD/PNL dataset",
        .extensions = &.{ "htd", "pnl", "log" },
        .can_read_pixels = true,
    },
    .{
        .id = "columbus",
        .name = "PerkinElmer Columbus TIFF dataset",
        .extensions = &.{ "xml", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "cv7000",
        .name = "Yokogawa CV7000 TIFF dataset",
        .extensions = &.{ "wpi", "mlf", "mrf", "ppf", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "dcimg",
        .name = "Hamamatsu DCIMG version 1",
        .extensions = &.{"dcimg"},
        .can_read_pixels = true,
    },
    .{
        .id = "deltavision",
        .name = "Deltavision DV/R3D raw stack",
        .extensions = &.{ "dv", "r3d", "r3d_d3d" },
        .can_read_pixels = true,
    },
    .{
        .id = "dicom",
        .name = "DICOM native endian pixels",
        .extensions = &.{ "dic", "dcm", "dicom", "ima" },
        .can_read_pixels = true,
    },
    .{
        .id = "dng",
        .name = "Canon DNG TIFF",
        .extensions = &.{ "cr2", "crw", "dng", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "ecat7",
        .name = "ECAT7",
        .extensions = &.{"v"},
        .can_read_pixels = true,
    },
    .{
        .id = "eps",
        .name = "Encapsulated PostScript raster",
        .extensions = &.{ "eps", "epsi", "ps" },
        .can_read_pixels = true,
    },
    .{
        .id = "fake",
        .name = "Bio-Formats simulated data",
        .extensions = &.{ "fake", "fake.ini" },
        .can_read_pixels = true,
    },
    .{
        .id = "fei",
        .name = "FEI/Philips SEM",
        .extensions = &.{"img"},
        .can_read_pixels = true,
    },
    .{
        .id = "feitiff",
        .name = "FEI TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "filepattern",
        .name = "File pattern",
        .extensions = &.{"pattern"},
        .can_read_pixels = true,
    },
    .{
        .id = "fits",
        .name = "FITS primary image",
        .extensions = &.{ "fits", "fts" },
        .can_read_pixels = true,
    },
    .{
        .id = "flex",
        .name = "Evotec Flex TIFF",
        .extensions = &.{ "flex", "mea", "res" },
        .can_read_pixels = true,
    },
    .{
        .id = "flowsight",
        .name = "FlowSight CIF",
        .extensions = &.{"cif"},
        .can_read_pixels = true,
    },
    .{
        .id = "fluoview",
        .name = "Olympus Fluoview/ABD TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "fv1000",
        .name = "Olympus FV1000 OIF TIFF dataset",
        .extensions = &.{ "oif", "oib", "pty", "lut", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "fuji",
        .name = "Fuji LAS 3000",
        .extensions = &.{ "inf", "img" },
        .can_read_pixels = true,
    },
    .{
        .id = "gatan",
        .name = "Gatan Digital Micrograph DM3/DM4",
        .extensions = &.{ "dm3", "dm4" },
        .can_read_pixels = true,
    },
    .{
        .id = "gatandm2",
        .name = "Gatan DM2",
        .extensions = &.{"dm2"},
        .can_read_pixels = true,
    },
    .{
        .id = "gel",
        .name = "Amersham Biosciences GEL TIFF",
        .extensions = &.{"gel"},
        .can_read_pixels = true,
    },
    .{
        .id = "gif",
        .name = "GIF87a/GIF89a palette RGB/RGBA planes",
        .extensions = &.{"gif"},
        .can_read_pixels = true,
    },
    .{
        .id = "hamamatsuvms",
        .name = "Hamamatsu VMS metadata",
        .extensions = &.{"vms"},
        .can_read_pixels = false,
    },
    .{
        .id = "his",
        .name = "Hamamatsu HIS single-series image",
        .extensions = &.{"his"},
        .can_read_pixels = true,
    },
    .{
        .id = "hitachi",
        .name = "Hitachi S-4800",
        .extensions = &.{"txt"},
        .can_read_pixels = true,
    },
    .{
        .id = "hrdgdf",
        .name = "NOAA-HRD Gridded Data Format",
        .extensions = &.{},
        .can_read_pixels = true,
    },
    .{
        .id = "i2i",
        .name = "I2I int16/float32 volume",
        .extensions = &.{"i2i"},
        .can_read_pixels = true,
    },
    .{
        .id = "imacon",
        .name = "Imacon TIFF",
        .extensions = &.{"fff"},
        .can_read_pixels = true,
    },
    .{
        .id = "im3",
        .name = "PerkinElmer Nuance IM3",
        .extensions = &.{"im3"},
        .can_read_pixels = true,
    },
    .{
        .id = "imagic",
        .name = "IMAGIC",
        .extensions = &.{ "hed", "img" },
        .can_read_pixels = true,
    },
    .{
        .id = "ics",
        .name = "Image Cytometry Standard",
        .extensions = &.{ "ics", "ids" },
        .can_read_pixels = true,
    },
    .{
        .id = "incell",
        .name = "InCell 1000/2000 TIFF dataset",
        .extensions = &.{ "xdce", "xml", "tif", "tiff", "xlog" },
        .can_read_pixels = true,
    },
    .{
        .id = "incell3000",
        .name = "InCell 3000",
        .extensions = &.{"frm"},
        .can_read_pixels = true,
    },
    .{
        .id = "imaris",
        .name = "Bitplane Imaris raw",
        .extensions = &.{"ims"},
        .can_read_pixels = true,
    },
    .{
        .id = "imaristiff",
        .name = "Bitplane Imaris 3 TIFF",
        .extensions = &.{"ims"},
        .can_read_pixels = true,
    },
    .{
        .id = "imod",
        .name = "IMOD model",
        .extensions = &.{"mod"},
        .can_read_pixels = true,
    },
    .{
        .id = "improvisiontiff",
        .name = "Improvision TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "imspector",
        .name = "LaVision Imspector MSR",
        .extensions = &.{"msr"},
        .can_read_pixels = true,
    },
    .{
        .id = "inr",
        .name = "INR raw fixed-size raster/volume",
        .extensions = &.{"inr"},
        .can_read_pixels = true,
    },
    .{
        .id = "inveon",
        .name = "Inveon",
        .extensions = &.{"hdr"},
        .can_read_pixels = true,
    },
    .{
        .id = "ionpathmibi",
        .name = "Ionpath MIBI TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "ionpathmibitiff",
        .name = "Ionpath MIBI TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "iplab",
        .name = "IPLab",
        .extensions = &.{"ipl"},
        .can_read_pixels = true,
    },
    .{
        .id = "ipw",
        .name = "Image-Pro Workspace",
        .extensions = &.{"ipw"},
        .can_read_pixels = true,
    },
    .{
        .id = "ivision",
        .name = "IVision",
        .extensions = &.{"ipm"},
        .can_read_pixels = true,
    },
    .{
        .id = "jdce",
        .name = "Molecular Devices JDCE TIFF dataset",
        .extensions = &.{ "jdce", "csv", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "jeol",
        .name = "JEOL single-file image",
        .extensions = &.{ "dat", "img" },
        .can_read_pixels = true,
    },
    .{
        .id = "jpeg",
        .name = "JPEG metadata",
        .extensions = &.{ "jpg", "jpeg", "jpe" },
        .can_read_pixels = false,
    },
    .{
        .id = "jpeg2000",
        .name = "JPEG-2000 metadata",
        .extensions = &.{ "jp2", "j2k", "jpf" },
        .can_read_pixels = false,
    },
    .{
        .id = "jpk",
        .name = "JPK Instruments TIFF",
        .extensions = &.{"jpk"},
        .can_read_pixels = true,
    },
    .{
        .id = "jpx",
        .name = "JPX metadata",
        .extensions = &.{"jpx"},
        .can_read_pixels = false,
    },
    .{
        .id = "khoros",
        .name = "Khoros XV raw raster",
        .extensions = &.{"xv"},
        .can_read_pixels = true,
    },
    .{
        .id = "klb",
        .name = "Keller Lab Block single-block volume",
        .extensions = &.{"klb"},
        .can_read_pixels = true,
    },
    .{
        .id = "kodak",
        .name = "Kodak Molecular Imaging BIP",
        .extensions = &.{"bip"},
        .can_read_pixels = true,
    },
    .{
        .id = "l2d",
        .name = "Li-Cor L2D",
        .extensions = &.{ "l2d", "scn" },
        .can_read_pixels = true,
    },
    .{
        .id = "leo",
        .name = "LEO TIFF",
        .extensions = &.{ "sxm", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "leicascn",
        .name = "Leica SCN TIFF",
        .extensions = &.{"scn"},
        .can_read_pixels = true,
    },
    .{
        .id = "lif",
        .name = "Leica LIF metadata",
        .extensions = &.{"lif"},
        .can_read_pixels = false,
    },
    .{
        .id = "liflim",
        .name = "LI-FLIM",
        .extensions = &.{"fli"},
        .can_read_pixels = true,
    },
    .{
        .id = "lim",
        .name = "Laboratory Imaging LIM",
        .extensions = &.{"lim"},
        .can_read_pixels = true,
    },
    .{
        .id = "lof",
        .name = "Leica LOF metadata",
        .extensions = &.{"lof"},
        .can_read_pixels = false,
    },
    .{
        .id = "metamorph",
        .name = "Metamorph STK/TIFF",
        .extensions = &.{ "stk", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "metamorphtiff",
        .name = "Metamorph TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "metaxpress",
        .name = "MetaXpress TIFF",
        .extensions = &.{ "htd", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "metaxpresstiff",
        .name = "MetaXpress TIFF",
        .extensions = &.{ "htd", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "mias",
        .name = "MIAS TIFF",
        .extensions = &.{ "tif", "tiff", "txt" },
        .can_read_pixels = true,
    },
    .{
        .id = "micromanager",
        .name = "Micro-Manager TIFF dataset",
        .extensions = &.{ "txt", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "microct",
        .name = "MicroCT VFF",
        .extensions = &.{"vff"},
        .can_read_pixels = true,
    },
    .{
        .id = "mikroscan",
        .name = "Mikroscan TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "mikroscantiff",
        .name = "Mikroscan TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "minc",
        .name = "MINC MRI NetCDF classic",
        .extensions = &.{"mnc"},
        .can_read_pixels = true,
    },
    .{
        .id = "molecularimaging",
        .name = "Molecular Imaging STP",
        .extensions = &.{"stp"},
        .can_read_pixels = true,
    },
    .{
        .id = "mrw",
        .name = "Minolta MRW",
        .extensions = &.{"mrw"},
        .can_read_pixels = true,
    },
    .{
        .id = "mng",
        .name = "Multiple-image Network Graphics first PNG",
        .extensions = &.{"mng"},
        .can_read_pixels = true,
    },
    .{
        .id = "png",
        .name = "PNG 1/2/4/8 indexed/grayscale and 8/16 GA/RGB/RGBA with Adam7",
        .extensions = &.{"png"},
        .can_read_pixels = true,
    },
    .{
        .id = "pqbin",
        .name = "PicoQuant BIN FLIM",
        .extensions = &.{"bin"},
        .can_read_pixels = true,
    },
    .{
        .id = "psd",
        .name = "Adobe Photoshop PSD merged image",
        .extensions = &.{"psd"},
        .can_read_pixels = true,
    },
    .{
        .id = "pyramidtiff",
        .name = "Pyramid TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "qt",
        .name = "QuickTime metadata",
        .extensions = &.{ "mov", "qt" },
        .can_read_pixels = false,
    },
    .{
        .id = "povray",
        .name = "POV-Ray DF3 volume",
        .extensions = &.{"df3"},
        .can_read_pixels = true,
    },
    .{
        .id = "prairie",
        .name = "Prairie TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "sbig",
        .name = "SBIG astronomy image",
        .extensions = &.{},
        .can_read_pixels = true,
    },
    .{
        .id = "scanr",
        .name = "Olympus ScanR TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "sdt",
        .name = "Becker & Hickl SPCImage SDT",
        .extensions = &.{"sdt"},
        .can_read_pixels = true,
    },
    .{
        .id = "seiko",
        .name = "Seiko XQD/XQF",
        .extensions = &.{ "xqd", "xqf" },
        .can_read_pixels = true,
    },
    .{
        .id = "rhk",
        .name = "RHK Technologies SPM",
        .extensions = &.{ "sm2", "sm3" },
        .can_read_pixels = true,
    },
    .{
        .id = "quesant",
        .name = "Quesant AFM",
        .extensions = &.{"afm"},
        .can_read_pixels = true,
    },
    .{
        .id = "rcpnl",
        .name = "RCPNL DeltaVision",
        .extensions = &.{"rcpnl"},
        .can_read_pixels = true,
    },
    .{
        .id = "mrc",
        .name = "MRC microscopy volume",
        .extensions = &.{ "mrc", "mrcs", "st", "ali", "map", "rec" },
        .can_read_pixels = true,
    },
    .{
        .id = "naf",
        .name = "Hamamatsu Aquacosmos",
        .extensions = &.{"naf"},
        .can_read_pixels = true,
    },
    .{
        .id = "nd2",
        .name = "Nikon ND2 metadata",
        .extensions = &.{ "nd2", "jp2" },
        .can_read_pixels = false,
    },
    .{
        .id = "ndpi",
        .name = "Hamamatsu NDPI TIFF",
        .extensions = &.{"ndpi"},
        .can_read_pixels = true,
    },
    .{
        .id = "ndpis",
        .name = "Hamamatsu NDPIS",
        .extensions = &.{"ndpis"},
        .can_read_pixels = true,
    },
    .{
        .id = "nifti",
        .name = "NIfTI single-file image",
        .extensions = &.{"nii"},
        .can_read_pixels = true,
    },
    .{
        .id = "nikon",
        .name = "Nikon NEF TIFF",
        .extensions = &.{ "nef", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "nikonelements",
        .name = "Nikon Elements TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "nikonelementstiff",
        .name = "Nikon Elements TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "nikontiff",
        .name = "Nikon EZ-C1 TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "nrrd",
        .name = "NRRD attached raw raster/volume",
        .extensions = &.{ "nrrd", "nhdr" },
        .can_read_pixels = true,
    },
    .{
        .id = "obf",
        .name = "Imspector OBF uncompressed stack",
        .extensions = &.{ "obf", "msr" },
        .can_read_pixels = true,
    },
    .{
        .id = "oir",
        .name = "Olympus OIR metadata",
        .extensions = &.{"oir"},
        .can_read_pixels = false,
    },
    .{
        .id = "omexml",
        .name = "OME-XML inline BinData",
        .extensions = &.{ "ome", "ome.xml" },
        .can_read_pixels = true,
    },
    .{
        .id = "ometiff",
        .name = "OME-TIFF",
        .extensions = &.{ "ome.tif", "ome.tiff", "ome.tf2", "ome.tf8", "ome.btf", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "operetta",
        .name = "PerkinElmer Operetta TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "openlab",
        .name = "Openlab LIFF metadata",
        .extensions = &.{"liff"},
        .can_read_pixels = false,
    },
    .{
        .id = "openlabraw",
        .name = "Openlab RAW",
        .extensions = &.{"raw"},
        .can_read_pixels = true,
    },
    .{
        .id = "oxfordinstruments",
        .name = "Oxford Instruments TOP",
        .extensions = &.{"top"},
        .can_read_pixels = true,
    },
    .{
        .id = "pcx",
        .name = "PCX 8-bit grayscale/palette and planar RGB",
        .extensions = &.{"pcx"},
        .can_read_pixels = true,
    },
    .{
        .id = "pci",
        .name = "Compix Simple-PCI",
        .extensions = &.{"cxd"},
        .can_read_pixels = true,
    },
    .{
        .id = "pcoraw",
        .name = "PCO-RAW",
        .extensions = &.{ "pcoraw", "rec" },
        .can_read_pixels = true,
    },
    .{
        .id = "pds",
        .name = "Perkin Elmer Densitometer",
        .extensions = &.{ "hdr", "img" },
        .can_read_pixels = true,
    },
    .{
        .id = "perkinelmer",
        .name = "PerkinElmer TIFF dataset",
        .extensions = &.{ "ano", "cfg", "csv", "htm", "rec", "tim", "zpo", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "pict",
        .name = "Apple PICT metadata",
        .extensions = &.{ "pict", "pct" },
        .can_read_pixels = false,
    },
    .{
        .id = "photoshoptiff",
        .name = "Adobe Photoshop TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "seq",
        .name = "Image-Pro Sequence TIFF",
        .extensions = &.{ "seq", "ips" },
        .can_read_pixels = true,
    },
    .{
        .id = "sif",
        .name = "Andor SIF float32 images",
        .extensions = &.{"sif"},
        .can_read_pixels = true,
    },
    .{
        .id = "simplepci",
        .name = "SimplePCI TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "simplepcitiff",
        .name = "SimplePCI TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "sis",
        .name = "Olympus SIS TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "slidebooktiff",
        .name = "Slidebook TIFF",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "spider",
        .name = "SPIDER float32 EM images",
        .extensions = &.{"spi"},
        .can_read_pixels = true,
    },
    .{
        .id = "spc",
        .name = "Becker & Hickl SPC FIFO",
        .extensions = &.{ "spc", "set" },
        .can_read_pixels = true,
    },
    .{
        .id = "spe",
        .name = "Princeton Instruments SPE",
        .extensions = &.{"spe"},
        .can_read_pixels = true,
    },
    .{
        .id = "svs",
        .name = "Aperio SVS TIFF",
        .extensions = &.{"svs"},
        .can_read_pixels = true,
    },
    .{
        .id = "tcs",
        .name = "Leica TCS TIFF",
        .extensions = &.{ "tif", "tiff", "xml" },
        .can_read_pixels = true,
    },
    .{
        .id = "tecan",
        .name = "Tecan Spark Cyto TIFF dataset",
        .extensions = &.{ "db", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "smcamera",
        .name = "SM Camera uint8 image",
        .extensions = &.{},
        .can_read_pixels = true,
    },
    .{
        .id = "tga",
        .name = "TGA color-mapped/grayscale/RGB/RGBA",
        .extensions = &.{"tga"},
        .can_read_pixels = true,
    },
    .{
        .id = "targa",
        .name = "Truevision Targa",
        .extensions = &.{"tga"},
        .can_read_pixels = true,
    },
    .{
        .id = "tillvision",
        .name = "TillVision raw PST/INF",
        .extensions = &.{ "vws", "pst", "inf" },
        .can_read_pixels = true,
    },
    .{
        .id = "text",
        .name = "Text table float planes",
        .extensions = &.{ "txt", "csv" },
        .can_read_pixels = true,
    },
    .{
        .id = "tiff",
        .name = "TIFF baseline 8/16/signed/float-bit",
        .extensions = &.{ "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "topometrix",
        .name = "TopoMetrix",
        .extensions = &.{ "tfr", "ffr", "zfr", "zfp", "2fl" },
        .can_read_pixels = true,
    },
    .{
        .id = "trestle",
        .name = "Trestle TIFF",
        .extensions = &.{"tif"},
        .can_read_pixels = true,
    },
    .{
        .id = "ubm",
        .name = "UBM uint32 image",
        .extensions = &.{"pr3"},
        .can_read_pixels = true,
    },
    .{
        .id = "unisoku",
        .name = "Unisoku STM",
        .extensions = &.{ "hdr", "dat" },
        .can_read_pixels = true,
    },
    .{
        .id = "varianfdf",
        .name = "Varian FDF",
        .extensions = &.{"fdf"},
        .can_read_pixels = true,
    },
    .{
        .id = "vectra",
        .name = "PerkinElmer Vectra/QPTIFF",
        .extensions = &.{ "qptiff", "tif", "tiff" },
        .can_read_pixels = true,
    },
    .{
        .id = "veeco",
        .name = "Veeco AFM NetCDF",
        .extensions = &.{"hdf"},
        .can_read_pixels = true,
    },
    .{
        .id = "ventana",
        .name = "Ventana BIF TIFF",
        .extensions = &.{"bif"},
        .can_read_pixels = true,
    },
    .{
        .id = "visitech",
        .name = "Visitech XYS",
        .extensions = &.{ "html", "xys" },
        .can_read_pixels = true,
    },
    .{
        .id = "vgsam",
        .name = "VG SAM",
        .extensions = &.{"dti"},
        .can_read_pixels = true,
    },
    .{
        .id = "volocityclipping",
        .name = "Volocity Library Clipping",
        .extensions = &.{"acff"},
        .can_read_pixels = true,
    },
    .{
        .id = "watop",
        .name = "WA Technology TOP",
        .extensions = &.{"wat"},
        .can_read_pixels = true,
    },
    .{
        .id = "xlef",
        .name = "Leica XLEF TIFF project",
        .extensions = &.{ "xlef", "xlif" },
        .can_read_pixels = true,
    },
    .{
        .id = "zeissczi",
        .name = "Zeiss CZI metadata",
        .extensions = &.{"czi"},
        .can_read_pixels = false,
    },
    .{
        .id = "zeisslms",
        .name = "Zeiss LMS",
        .extensions = &.{"lms"},
        .can_read_pixels = true,
    },
    .{
        .id = "zeisslsm",
        .name = "Zeiss LSM TIFF",
        .extensions = &.{"lsm"},
        .can_read_pixels = true,
    },
    .{
        .id = "zeisstiff",
        .name = "Zeiss AxioVision TIFF",
        .extensions = &.{ "tif", "tiff", "xml" },
        .can_read_pixels = true,
    },
    .{
        .id = "zeissxrm",
        .name = "Zeiss XRM",
        .extensions = &.{ "txm", "txrm" },
        .can_read_pixels = true,
    },
    .{
        .id = "zip",
        .name = "ZIP archive first stored image entry",
        .extensions = &.{"zip"},
        .can_read_pixels = true,
    },
};

pub fn detect(data: []const u8) ?[]const u8 {
    if (afi.matches(data)) return "afi";
    if (aim.matches(data)) return "aim";
    if (zip.matches(data)) return "zip";
    if (alicona.matches(data)) return "alicona";
    if (amira.matches(data)) return "amira";
    if (analyze.matches(data)) return "analyze";
    if (arf.matches(data)) return "arf";
    if (avi.matches(data)) return "avi";
    if (bdpathway.matches(data)) return "bdpathway";
    if (biorad.matches(data)) return "biorad";
    if (bioradgel.matches(data)) return "bioradgel";
    if (bioradscn.matches(data)) return "bioradscn";
    if (netpbm.matches(data)) return "netpbm";
    if (bmp.matches(data)) return "bmp";
    if (burleigh.matches(data)) return "burleigh";
    if (cellomics.matches(data)) return "cellomics";
    if (cellsens.matches(data)) return "cellsens";
    if (cellvoyager.matches(data)) return "cellvoyager";
    if (cellworx.matches(data)) return "cellworx";
    if (columbus.matches(data)) return "columbus";
    if (cv7000.matches(data)) return "cv7000";
    if (dcimg.matches(data)) return "dcimg";
    if (deltavision.matches(data)) return "deltavision";
    if (dicom.matches(data)) return "dicom";
    if (ecat7.matches(data)) return "ecat7";
    if (eps.matches(data)) return "eps";
    if (fei.matches(data)) return "fei";
    if (fits.matches(data)) return "fits";
    if (flex.matches(data)) return "flex";
    if (fuji.matches(data)) return "fuji";
    if (gif.matches(data)) return "gif";
    if (his.matches(data)) return "his";
    if (hitachi.matches(data)) return "hitachi";
    if (i2i.matches(data)) return "i2i";
    if (ics.matches(data)) return "ics";
    if (imspector.matches(data)) return "imspector";
    if (inr.matches(data)) return "inr";
    if (inveon.matches(data)) return "inveon";
    if (iplab.matches(data)) return "iplab";
    if (ipw.matches(data)) return "ipw";
    if (ivision.matches(data)) return "ivision";
    if (jdce.matches(data)) return "jdce";
    if (jeol.matches(data)) return "jeol";
    if (jpeg.matches(data)) return "jpeg";
    if (jpeg2000.matches(data)) return "jpeg2000";
    if (jpx.matches(data)) return "jpx";
    if (khoros.matches(data)) return "khoros";
    if (klb.matches(data)) return "klb";
    if (kodak.matches(data)) return "kodak";
    if (l2d.matches(data)) return "l2d";
    if (apng.matches(data)) return "apng";
    if (png.matches(data)) return "png";
    if (pqbin.matches(data)) return "pqbin";
    if (psd.matches(data)) return "psd";
    if (mrc.matches(data)) return "mrc";
    if (naf.matches(data)) return "naf";
    if (nd2.matches(data)) return "nd2";
    if (ndpi.matches(data)) return "ndpi";
    if (nifti.matches(data)) return "nifti";
    if (nrrd.matches(data)) return "nrrd";
    if (obf.matches(data)) return "obf";
    if (oir.matches(data)) return "oir";
    if (omexml.matches(data)) return "omexml";
    if (operetta.matches(data)) return "operetta";
    if (openlab.matches(data)) return "openlab";
    if (openlabraw.matches(data)) return "openlabraw";
    if (oxfordinstruments.matches(data)) return "oxfordinstruments";
    if (pds.matches(data)) return "pds";
    if (pcx.matches(data)) return "pcx";
    if (pci.matches(data)) return "pci";
    if (sif.matches(data)) return "sif";
    if (spider.matches(data)) return "spider";
    if (spc.matches(data)) return "spc";
    if (spe.matches(data)) return "spe";
    if (quesant.matches(data)) return "quesant";
    if (rhk.matches(data)) return "rhk";
    if (sbig.matches(data)) return "sbig";
    if (scanr.matches(data)) return "scanr";
    if (sdt.matches(data)) return "sdt";
    if (smcamera.matches(data)) return "smcamera";
    if (lim.matches(data)) return "lim";
    if (molecularimaging.matches(data)) return "molecularimaging";
    if (mng.matches(data)) return "mng";
    if (varianfdf.matches(data)) return "varianfdf";
    if (vgsam.matches(data)) return "vgsam";
    if (volocityclipping.matches(data)) return "volocityclipping";
    if (watop.matches(data)) return "watop";
    if (xlef.matches(data)) return "xlef";
    if (zeissczi.matches(data)) return "zeissczi";
    if (zeisslms.matches(data)) return "zeisslms";
    if (zeissxrm.matches(data)) return "zeissxrm";
    if (povray.matches(data)) return "povray";
    if (prairie.matches(data)) return "prairie";
    if (incell.matches(data)) return "incell";
    if (incell3000.matches(data)) return "incell3000";
    if (imagic.matches(data)) return "imagic";
    if (tga.matches(data)) return "tga";
    if (tillvision.matches(data)) return "tillvision";
    if (dng.matches(data)) return "dng";
    if (canonraw.matches(data)) return "canonraw";
    if (feitiff.matches(data)) return "feitiff";
    if (fluoview.matches(data)) return "fluoview";
    if (fv1000.matches(data)) return "fv1000";
    if (gatan.matches(data)) return "gatan";
    if (gatandm2.matches(data)) return "gatandm2";
    if (gel.matches(data)) return "gel";
    if (hamamatsuvms.matches(data)) return "hamamatsuvms";
    if (imacon.matches(data)) return "imacon";
    if (im3.matches(data)) return "im3";
    if (imaris.matches(data)) return "imaris";
    if (imod.matches(data)) return "imod";
    if (improvisiontiff.matches(data)) return "improvisiontiff";
    if (leo.matches(data)) return "leo";
    if (leicascn.matches(data)) return "leicascn";
    if (lif.matches(data)) return "lif";
    if (liflim.matches(data)) return "liflim";
    if (lof.matches(data)) return "lof";
    if (metamorph.matches(data)) return "metamorph";
    if (mias.matches(data)) return "mias";
    if (micromanager.matches(data)) return "micromanager";
    if (microct.matches(data)) return "microct";
    if (mikroscan.matches(data)) return "mikroscan";
    if (minc.matches(data)) return "minc";
    if (mrw.matches(data)) return "mrw";
    if (nikonelements.matches(data)) return "nikonelements";
    if (nikontiff.matches(data)) return "nikontiff";
    if (nikon.matches(data)) return "nikon";
    if (perkinelmer.matches(data)) return "perkinelmer";
    if (pict.matches(data)) return "pict";
    if (photoshoptiff.matches(data)) return "photoshoptiff";
    if (ionpathmibi.matches(data)) return "ionpathmibi";
    if (pyramidtiff.matches(data)) return "pyramidtiff";
    if (qt.matches(data)) return "qt";
    if (seq.matches(data)) return "seq";
    if (simplepci.matches(data)) return "simplepci";
    if (sis.matches(data)) return "sis";
    if (slidebooktiff.matches(data)) return "slidebooktiff";
    if (svs.matches(data)) return "svs";
    if (tcs.matches(data)) return "tcs";
    if (tecan.matches(data)) return "tecan";
    if (trestle.matches(data)) return "trestle";
    if (vectra.matches(data)) return "vectra";
    if (veeco.matches(data)) return "veeco";
    if (ventana.matches(data)) return "ventana";
    if (ometiff.matches(data)) return "ometiff";
    if (zeisslsm.matches(data)) return "zeisslsm";
    if (tiff.matches(data)) return "tiff";
    if (text.matches(data)) return "text";
    if (hrdgdf.matches(data)) return "hrdgdf";
    if (topometrix.matches(data)) return "topometrix";
    if (seiko.matches(data)) return "seiko";
    if (ubm.matches(data)) return "ubm";
    if (unisoku.matches(data)) return "unisoku";
    return null;
}

pub fn readMetadata(data: []const u8) ReaderError!Metadata {
    if (afi.matches(data)) return afi.readMetadata(data);
    if (aim.matches(data)) return aim.readMetadata(data);
    if (zip.matches(data)) return zip.readMetadata(data);
    if (alicona.matches(data)) return alicona.readMetadata(data);
    if (amira.matches(data)) return amira.readMetadata(data);
    if (analyze.matches(data)) return analyze.readMetadata(data);
    if (arf.matches(data)) return arf.readMetadata(data);
    if (avi.matches(data)) return avi.readMetadata(data);
    if (bdpathway.matches(data)) return bdpathway.readMetadata(data);
    if (biorad.matches(data)) return biorad.readMetadata(data);
    if (bioradgel.matches(data)) return bioradgel.readMetadata(data);
    if (bioradscn.matches(data)) return bioradscn.readMetadata(data);
    if (netpbm.matches(data)) return netpbm.readMetadata(data);
    if (bmp.matches(data)) return bmp.readMetadata(data);
    if (burleigh.matches(data)) return burleigh.readMetadata(data);
    if (cellomics.matches(data)) return cellomics.readMetadata(data);
    if (cellsens.matches(data)) return cellsens.readMetadata(data);
    if (cellvoyager.matches(data)) return cellvoyager.readMetadata(data);
    if (cellworx.matches(data)) return cellworx.readMetadata(data);
    if (columbus.matches(data)) return columbus.readMetadata(data);
    if (cv7000.matches(data)) return cv7000.readMetadata(data);
    if (dcimg.matches(data)) return dcimg.readMetadata(data);
    if (deltavision.matches(data)) return deltavision.readMetadata(data);
    if (dicom.matches(data)) return dicom.readMetadata(data);
    if (ecat7.matches(data)) return ecat7.readMetadata(data);
    if (eps.matches(data)) return eps.readMetadata(data);
    if (fei.matches(data)) return fei.readMetadata(data);
    if (fits.matches(data)) return fits.readMetadata(data);
    if (flex.matches(data)) return flex.readMetadata(data);
    if (flowsight.matches(data)) return flowsight.readMetadata(data);
    if (fuji.matches(data)) return fuji.readMetadata(data);
    if (gif.matches(data)) return gif.readMetadata(data);
    if (his.matches(data)) return his.readMetadata(data);
    if (hitachi.matches(data)) return hitachi.readMetadata(data);
    if (i2i.matches(data)) return i2i.readMetadata(data);
    if (ics.matches(data)) return ics.readMetadata(data);
    if (imspector.matches(data)) return imspector.readMetadata(data);
    if (inr.matches(data)) return inr.readMetadata(data);
    if (inveon.matches(data)) return inveon.readMetadata(data);
    if (iplab.matches(data)) return iplab.readMetadata(data);
    if (ipw.matches(data)) return ipw.readMetadata(data);
    if (ivision.matches(data)) return ivision.readMetadata(data);
    if (jdce.matches(data)) return jdce.readMetadata(data);
    if (jeol.matches(data)) return jeol.readMetadata(data);
    if (jpeg.matches(data)) return jpeg.readMetadata(data);
    if (jpeg2000.matches(data)) return jpeg2000.readMetadata(data);
    if (jpx.matches(data)) return jpx.readMetadata(data);
    if (khoros.matches(data)) return khoros.readMetadata(data);
    if (klb.matches(data)) return klb.readMetadata(data);
    if (kodak.matches(data)) return kodak.readMetadata(data);
    if (l2d.matches(data)) return l2d.readMetadata(data);
    if (apng.matches(data)) return apng.readMetadata(data);
    if (png.matches(data)) return png.readMetadata(data);
    if (pqbin.matches(data)) return pqbin.readMetadata(data);
    if (psd.matches(data)) return psd.readMetadata(data);
    if (mrc.matches(data)) return mrc.readMetadata(data);
    if (naf.matches(data)) return naf.readMetadata(data);
    if (nd2.matches(data)) return nd2.readMetadata(data);
    if (ndpi.matches(data)) return ndpi.readMetadata(data);
    if (nifti.matches(data)) return nifti.readMetadata(data);
    if (nrrd.matches(data)) return nrrd.readMetadata(data);
    if (obf.matches(data)) return obf.readMetadata(data);
    if (oir.matches(data)) return oir.readMetadata(data);
    if (omexml.matches(data)) return omexml.readMetadata(data);
    if (operetta.matches(data)) return operetta.readMetadata(data);
    if (openlab.matches(data)) return openlab.readMetadata(data);
    if (openlabraw.matches(data)) return openlabraw.readMetadata(data);
    if (oxfordinstruments.matches(data)) return oxfordinstruments.readMetadata(data);
    if (pds.matches(data)) return pds.readMetadata(data);
    if (pcx.matches(data)) return pcx.readMetadata(data);
    if (pci.matches(data)) return pci.readMetadata(data);
    if (sif.matches(data)) return sif.readMetadata(data);
    if (spider.matches(data)) return spider.readMetadata(data);
    if (spc.matches(data)) return spc.readMetadata(data);
    if (spe.matches(data)) return spe.readMetadata(data);
    if (quesant.matches(data)) return quesant.readMetadata(data);
    if (rhk.matches(data)) return rhk.readMetadata(data);
    if (sbig.matches(data)) return sbig.readMetadata(data);
    if (scanr.matches(data)) return scanr.readMetadata(data);
    if (sdt.matches(data)) return sdt.readMetadata(data);
    if (smcamera.matches(data)) return smcamera.readMetadata(data);
    if (lim.matches(data)) return lim.readMetadata(data);
    if (molecularimaging.matches(data)) return molecularimaging.readMetadata(data);
    if (mng.matches(data)) return mng.readMetadata(data);
    if (varianfdf.matches(data)) return varianfdf.readMetadata(data);
    if (vgsam.matches(data)) return vgsam.readMetadata(data);
    if (volocityclipping.matches(data)) return volocityclipping.readMetadata(data);
    if (watop.matches(data)) return watop.readMetadata(data);
    if (xlef.matches(data)) return xlef.readMetadata(data);
    if (zeissczi.matches(data)) return zeissczi.readMetadata(data);
    if (zeisslms.matches(data)) return zeisslms.readMetadata(data);
    if (zeissxrm.matches(data)) return zeissxrm.readMetadata(data);
    if (povray.matches(data)) return povray.readMetadata(data);
    if (prairie.matches(data)) return prairie.readMetadata(data);
    if (incell.matches(data)) return incell.readMetadata(data);
    if (incell3000.matches(data)) return incell3000.readMetadata(data);
    if (imagic.matches(data)) return imagic.readMetadata(data);
    if (tga.matches(data)) return tga.readMetadata(data);
    if (tillvision.matches(data)) return tillvision.readMetadata(data);
    if (dng.matches(data)) return dng.readMetadata(data);
    if (canonraw.matches(data)) return canonraw.readMetadata(data);
    if (feitiff.matches(data)) return feitiff.readMetadata(data);
    if (fluoview.matches(data)) return fluoview.readMetadata(data);
    if (fv1000.matches(data)) return fv1000.readMetadata(data);
    if (gatan.matches(data)) return gatan.readMetadata(data);
    if (gatandm2.matches(data)) return gatandm2.readMetadata(data);
    if (gel.matches(data)) return gel.readMetadata(data);
    if (hamamatsuvms.matches(data)) return hamamatsuvms.readMetadata(data);
    if (imacon.matches(data)) return imacon.readMetadata(data);
    if (im3.matches(data)) return im3.readMetadata(data);
    if (imaris.matches(data)) return imaris.readMetadata(data);
    if (imod.matches(data)) return imod.readMetadata(data);
    if (improvisiontiff.matches(data)) return improvisiontiff.readMetadata(data);
    if (leo.matches(data)) return leo.readMetadata(data);
    if (leicascn.matches(data)) return leicascn.readMetadata(data);
    if (lif.matches(data)) return lif.readMetadata(data);
    if (liflim.matches(data)) return liflim.readMetadata(data);
    if (lof.matches(data)) return lof.readMetadata(data);
    if (metamorph.matches(data)) return metamorph.readMetadata(data);
    if (mias.matches(data)) return mias.readMetadata(data);
    if (micromanager.matches(data)) return micromanager.readMetadata(data);
    if (microct.matches(data)) return microct.readMetadata(data);
    if (mikroscan.matches(data)) return mikroscan.readMetadata(data);
    if (minc.matches(data)) return minc.readMetadata(data);
    if (mrw.matches(data)) return mrw.readMetadata(data);
    if (nikonelements.matches(data)) return nikonelements.readMetadata(data);
    if (nikontiff.matches(data)) return nikontiff.readMetadata(data);
    if (nikon.matches(data)) return nikon.readMetadata(data);
    if (perkinelmer.matches(data)) return perkinelmer.readMetadata(data);
    if (pict.matches(data)) return pict.readMetadata(data);
    if (photoshoptiff.matches(data)) return photoshoptiff.readMetadata(data);
    if (ionpathmibi.matches(data)) return ionpathmibi.readMetadata(data);
    if (pyramidtiff.matches(data)) return pyramidtiff.readMetadata(data);
    if (qt.matches(data)) return qt.readMetadata(data);
    if (seq.matches(data)) return seq.readMetadata(data);
    if (simplepci.matches(data)) return simplepci.readMetadata(data);
    if (sis.matches(data)) return sis.readMetadata(data);
    if (slidebooktiff.matches(data)) return slidebooktiff.readMetadata(data);
    if (svs.matches(data)) return svs.readMetadata(data);
    if (tcs.matches(data)) return tcs.readMetadata(data);
    if (tecan.matches(data)) return tecan.readMetadata(data);
    if (trestle.matches(data)) return trestle.readMetadata(data);
    if (vectra.matches(data)) return vectra.readMetadata(data);
    if (veeco.matches(data)) return veeco.readMetadata(data);
    if (ventana.matches(data)) return ventana.readMetadata(data);
    if (ometiff.matches(data)) return ometiff.readMetadata(data);
    if (zeisslsm.matches(data)) return zeisslsm.readMetadata(data);
    if (tiff.matches(data)) return tiff.readMetadata(data);
    if (text.matches(data)) return text.readMetadata(data);
    if (hrdgdf.matches(data)) return hrdgdf.readMetadata(data);
    if (topometrix.matches(data)) return topometrix.readMetadata(data);
    if (seiko.matches(data)) return seiko.readMetadata(data);
    if (ubm.matches(data)) return ubm.readMetadata(data);
    if (unisoku.matches(data)) return unisoku.readMetadata(data);
    return error.UnsupportedFormat;
}

pub fn readPlane(allocator: std.mem.Allocator, data: []const u8) ReaderError!Plane {
    return readPlaneIndex(allocator, data, 0);
}

pub fn readPlaneIndex(allocator: std.mem.Allocator, data: []const u8, plane_index: u32) ReaderError!Plane {
    if (afi.matches(data)) return afi.readPlaneIndex(allocator, data, plane_index);
    if (aim.matches(data)) return aim.readPlaneIndex(allocator, data, plane_index);
    if (zip.matches(data)) return zip.readPlaneIndex(allocator, data, plane_index);
    if (alicona.matches(data)) return alicona.readPlaneIndex(allocator, data, plane_index);
    if (amira.matches(data)) return amira.readPlaneIndex(allocator, data, plane_index);
    if (analyze.matches(data)) return analyze.readPlaneIndex(allocator, data, plane_index);
    if (arf.matches(data)) return arf.readPlaneIndex(allocator, data, plane_index);
    if (avi.matches(data)) return avi.readPlaneIndex(allocator, data, plane_index);
    if (bdpathway.matches(data)) return bdpathway.readPlaneIndex(allocator, data, plane_index);
    if (biorad.matches(data)) return biorad.readPlaneIndex(allocator, data, plane_index);
    if (bioradgel.matches(data)) return bioradgel.readPlaneIndex(allocator, data, plane_index);
    if (bioradscn.matches(data)) return bioradscn.readPlaneIndex(allocator, data, plane_index);
    if (netpbm.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return netpbm.readPlane(allocator, data);
    }
    if (bmp.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return bmp.readPlane(allocator, data);
    }
    if (burleigh.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return burleigh.readPlane(allocator, data);
    }
    if (cellomics.matches(data)) return cellomics.readPlaneIndex(allocator, data, plane_index);
    if (cellsens.matches(data)) return cellsens.readPlaneIndex(allocator, data, plane_index);
    if (cellvoyager.matches(data)) return cellvoyager.readPlaneIndex(allocator, data, plane_index);
    if (cellworx.matches(data)) return cellworx.readPlaneIndex(allocator, data, plane_index);
    if (columbus.matches(data)) return columbus.readPlaneIndex(allocator, data, plane_index);
    if (cv7000.matches(data)) return cv7000.readPlaneIndex(allocator, data, plane_index);
    if (dcimg.matches(data)) return dcimg.readPlaneIndex(allocator, data, plane_index);
    if (deltavision.matches(data)) return deltavision.readPlaneIndex(allocator, data, plane_index);
    if (dicom.matches(data)) return dicom.readPlaneIndex(allocator, data, plane_index);
    if (ecat7.matches(data)) return ecat7.readPlaneIndex(allocator, data, plane_index);
    if (eps.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return eps.readPlane(allocator, data);
    }
    if (fei.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return fei.readPlane(allocator, data);
    }
    if (fits.matches(data)) return fits.readPlaneIndex(allocator, data, plane_index);
    if (flex.matches(data)) return flex.readPlaneIndex(allocator, data, plane_index);
    if (flowsight.matches(data)) return flowsight.readPlaneIndex(allocator, data, plane_index);
    if (fuji.matches(data)) return fuji.readPlaneIndex(allocator, data, plane_index);
    if (gif.matches(data)) {
        return gif.readPlaneIndex(allocator, data, plane_index);
    }
    if (his.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return his.readPlane(allocator, data);
    }
    if (hitachi.matches(data)) return hitachi.readPlaneIndex(allocator, data, plane_index);
    if (i2i.matches(data)) return i2i.readPlaneIndex(allocator, data, plane_index);
    if (ics.matches(data)) return ics.readPlaneIndex(allocator, data, plane_index);
    if (imspector.matches(data)) return imspector.readPlaneIndex(allocator, data, plane_index);
    if (inr.matches(data)) return inr.readPlaneIndex(allocator, data, plane_index);
    if (inveon.matches(data)) return inveon.readPlaneIndex(allocator, data, plane_index);
    if (iplab.matches(data)) return iplab.readPlaneIndex(allocator, data, plane_index);
    if (ipw.matches(data)) return ipw.readPlaneIndex(allocator, data, plane_index);
    if (ivision.matches(data)) return ivision.readPlaneIndex(allocator, data, plane_index);
    if (jdce.matches(data)) return jdce.readPlaneIndex(allocator, data, plane_index);
    if (jeol.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return jeol.readPlane(allocator, data);
    }
    if (jpeg.matches(data)) return jpeg.readPlaneIndex(allocator, data, plane_index);
    if (jpeg2000.matches(data)) return jpeg2000.readPlaneIndex(allocator, data, plane_index);
    if (jpx.matches(data)) return jpx.readPlaneIndex(allocator, data, plane_index);
    if (khoros.matches(data)) return khoros.readPlaneIndex(allocator, data, plane_index);
    if (klb.matches(data)) return klb.readPlaneIndex(allocator, data, plane_index);
    if (kodak.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return kodak.readPlane(allocator, data);
    }
    if (l2d.matches(data)) return l2d.readPlaneIndex(allocator, data, plane_index);
    if (apng.matches(data)) return apng.readPlaneIndex(allocator, data, plane_index);
    if (png.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return png.readPlane(allocator, data);
    }
    if (pqbin.matches(data)) return pqbin.readPlaneIndex(allocator, data, plane_index);
    if (psd.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return psd.readPlane(allocator, data);
    }
    if (mrc.matches(data)) return mrc.readPlaneIndex(allocator, data, plane_index);
    if (naf.matches(data)) return naf.readPlaneIndex(allocator, data, plane_index);
    if (nd2.matches(data)) return nd2.readPlaneIndex(allocator, data, plane_index);
    if (ndpi.matches(data)) return ndpi.readPlaneIndex(allocator, data, plane_index);
    if (nifti.matches(data)) return nifti.readPlaneIndex(allocator, data, plane_index);
    if (nrrd.matches(data)) return nrrd.readPlaneIndex(allocator, data, plane_index);
    if (obf.matches(data)) return obf.readPlaneIndex(allocator, data, plane_index);
    if (oir.matches(data)) return oir.readPlaneIndex(allocator, data, plane_index);
    if (omexml.matches(data)) return omexml.readPlaneIndex(allocator, data, plane_index);
    if (operetta.matches(data)) return operetta.readPlaneIndex(allocator, data, plane_index);
    if (openlab.matches(data)) return openlab.readPlaneIndex(allocator, data, plane_index);
    if (openlabraw.matches(data)) return openlabraw.readPlaneIndex(allocator, data, plane_index);
    if (oxfordinstruments.matches(data)) return oxfordinstruments.readPlaneIndex(allocator, data, plane_index);
    if (pds.matches(data)) return pds.readPlaneIndex(allocator, data, plane_index);
    if (pcx.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return pcx.readPlane(allocator, data);
    }
    if (sif.matches(data)) return sif.readPlaneIndex(allocator, data, plane_index);
    if (spider.matches(data)) return spider.readPlaneIndex(allocator, data, plane_index);
    if (spc.matches(data)) return spc.readPlaneIndex(allocator, data, plane_index);
    if (spe.matches(data)) return spe.readPlaneIndex(allocator, data, plane_index);
    if (quesant.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return quesant.readPlane(allocator, data);
    }
    if (rhk.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return rhk.readPlane(allocator, data);
    }
    if (sbig.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return sbig.readPlane(allocator, data);
    }
    if (scanr.matches(data)) return scanr.readPlaneIndex(allocator, data, plane_index);
    if (sdt.matches(data)) return sdt.readPlaneIndex(allocator, data, plane_index);
    if (smcamera.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return smcamera.readPlane(allocator, data);
    }
    if (lim.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return lim.readPlane(allocator, data);
    }
    if (pci.matches(data)) return pci.readPlaneIndex(allocator, data, plane_index);
    if (molecularimaging.matches(data)) return molecularimaging.readPlaneIndex(allocator, data, plane_index);
    if (mng.matches(data)) return mng.readPlaneIndex(allocator, data, plane_index);
    if (varianfdf.matches(data)) return varianfdf.readPlaneIndex(allocator, data, plane_index);
    if (vgsam.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return vgsam.readPlane(allocator, data);
    }
    if (volocityclipping.matches(data)) return volocityclipping.readPlaneIndex(allocator, data, plane_index);
    if (watop.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return watop.readPlane(allocator, data);
    }
    if (xlef.matches(data)) return xlef.readPlaneIndex(allocator, data, plane_index);
    if (zeissczi.matches(data)) return zeissczi.readPlaneIndex(allocator, data, plane_index);
    if (zeisslms.matches(data)) return zeisslms.readPlaneIndex(allocator, data, plane_index);
    if (zeissxrm.matches(data)) return zeissxrm.readPlaneIndex(allocator, data, plane_index);
    if (povray.matches(data)) return povray.readPlaneIndex(allocator, data, plane_index);
    if (prairie.matches(data)) return prairie.readPlaneIndex(allocator, data, plane_index);
    if (incell.matches(data)) return incell.readPlaneIndex(allocator, data, plane_index);
    if (incell3000.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return incell3000.readPlane(allocator, data);
    }
    if (imagic.matches(data)) return imagic.readPlaneIndex(allocator, data, plane_index);
    if (tga.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return tga.readPlane(allocator, data);
    }
    if (tillvision.matches(data)) return tillvision.readPlaneIndex(allocator, data, plane_index);
    if (dng.matches(data)) return dng.readPlaneIndex(allocator, data, plane_index);
    if (canonraw.matches(data)) return canonraw.readPlaneIndex(allocator, data, plane_index);
    if (feitiff.matches(data)) return feitiff.readPlaneIndex(allocator, data, plane_index);
    if (fluoview.matches(data)) return fluoview.readPlaneIndex(allocator, data, plane_index);
    if (fv1000.matches(data)) return fv1000.readPlaneIndex(allocator, data, plane_index);
    if (gatan.matches(data)) return gatan.readPlaneIndex(allocator, data, plane_index);
    if (gatandm2.matches(data)) return gatandm2.readPlaneIndex(allocator, data, plane_index);
    if (gel.matches(data)) return gel.readPlaneIndex(allocator, data, plane_index);
    if (hamamatsuvms.matches(data)) return hamamatsuvms.readPlaneIndex(allocator, data, plane_index);
    if (imacon.matches(data)) return imacon.readPlaneIndex(allocator, data, plane_index);
    if (im3.matches(data)) return im3.readPlaneIndex(allocator, data, plane_index);
    if (imaris.matches(data)) return imaris.readPlaneIndex(allocator, data, plane_index);
    if (imod.matches(data)) return imod.readPlaneIndex(allocator, data, plane_index);
    if (improvisiontiff.matches(data)) return improvisiontiff.readPlaneIndex(allocator, data, plane_index);
    if (leo.matches(data)) return leo.readPlaneIndex(allocator, data, plane_index);
    if (leicascn.matches(data)) return leicascn.readPlaneIndex(allocator, data, plane_index);
    if (lif.matches(data)) return lif.readPlaneIndex(allocator, data, plane_index);
    if (liflim.matches(data)) return liflim.readPlaneIndex(allocator, data, plane_index);
    if (lof.matches(data)) return lof.readPlaneIndex(allocator, data, plane_index);
    if (metamorph.matches(data)) return metamorph.readPlaneIndex(allocator, data, plane_index);
    if (mias.matches(data)) return mias.readPlaneIndex(allocator, data, plane_index);
    if (micromanager.matches(data)) return micromanager.readPlaneIndex(allocator, data, plane_index);
    if (microct.matches(data)) return microct.readPlaneIndex(allocator, data, plane_index);
    if (mikroscan.matches(data)) return mikroscan.readPlaneIndex(allocator, data, plane_index);
    if (minc.matches(data)) return minc.readPlaneIndex(allocator, data, plane_index);
    if (mrw.matches(data)) return mrw.readPlaneIndex(allocator, data, plane_index);
    if (nikonelements.matches(data)) return nikonelements.readPlaneIndex(allocator, data, plane_index);
    if (nikontiff.matches(data)) return nikontiff.readPlaneIndex(allocator, data, plane_index);
    if (nikon.matches(data)) return nikon.readPlaneIndex(allocator, data, plane_index);
    if (perkinelmer.matches(data)) return perkinelmer.readPlaneIndex(allocator, data, plane_index);
    if (pict.matches(data)) return pict.readPlaneIndex(allocator, data, plane_index);
    if (photoshoptiff.matches(data)) return photoshoptiff.readPlaneIndex(allocator, data, plane_index);
    if (ionpathmibi.matches(data)) return ionpathmibi.readPlaneIndex(allocator, data, plane_index);
    if (pyramidtiff.matches(data)) return pyramidtiff.readPlaneIndex(allocator, data, plane_index);
    if (qt.matches(data)) return qt.readPlaneIndex(allocator, data, plane_index);
    if (seq.matches(data)) return seq.readPlaneIndex(allocator, data, plane_index);
    if (simplepci.matches(data)) return simplepci.readPlaneIndex(allocator, data, plane_index);
    if (sis.matches(data)) return sis.readPlaneIndex(allocator, data, plane_index);
    if (slidebooktiff.matches(data)) return slidebooktiff.readPlaneIndex(allocator, data, plane_index);
    if (svs.matches(data)) return svs.readPlaneIndex(allocator, data, plane_index);
    if (tcs.matches(data)) return tcs.readPlaneIndex(allocator, data, plane_index);
    if (tecan.matches(data)) return tecan.readPlaneIndex(allocator, data, plane_index);
    if (trestle.matches(data)) return trestle.readPlaneIndex(allocator, data, plane_index);
    if (vectra.matches(data)) return vectra.readPlaneIndex(allocator, data, plane_index);
    if (veeco.matches(data)) return veeco.readPlaneIndex(allocator, data, plane_index);
    if (ventana.matches(data)) return ventana.readPlaneIndex(allocator, data, plane_index);
    if (ometiff.matches(data)) return ometiff.readPlaneIndex(allocator, data, plane_index);
    if (zeisslsm.matches(data)) return zeisslsm.readPlaneIndex(allocator, data, plane_index);
    if (tiff.matches(data)) return tiff.readPlaneIndex(allocator, data, plane_index);
    if (text.matches(data)) return text.readPlaneIndex(allocator, data, plane_index);
    if (hrdgdf.matches(data)) return hrdgdf.readPlaneIndex(allocator, data, plane_index);
    if (topometrix.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return topometrix.readPlane(allocator, data);
    }
    if (seiko.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return seiko.readPlane(allocator, data);
    }
    if (ubm.matches(data)) {
        if (plane_index != 0) return error.InvalidPlaneIndex;
        return ubm.readPlane(allocator, data);
    }
    if (unisoku.matches(data)) return unisoku.readPlaneIndex(allocator, data, plane_index);
    return error.UnsupportedFormat;
}

pub fn readPlaneRegionIndex(
    allocator: std.mem.Allocator,
    data: []const u8,
    plane_index: u32,
    region: Region,
) ReaderError!Plane {
    if (bdpathway.matches(data)) return bdpathway.readRegionIndex(allocator, data, plane_index, region);
    if (dng.matches(data)) return dng.readRegionIndex(allocator, data, plane_index, region);
    if (feitiff.matches(data)) return feitiff.readRegionIndex(allocator, data, plane_index, region);
    if (fluoview.matches(data)) return fluoview.readRegionIndex(allocator, data, plane_index, region);
    if (gel.matches(data)) return gel.readRegionIndex(allocator, data, plane_index, region);
    if (imacon.matches(data)) return imacon.readRegionIndex(allocator, data, plane_index, region);
    if (im3.matches(data)) return im3.readRegionIndex(allocator, data, plane_index, region);
    if (improvisiontiff.matches(data)) return improvisiontiff.readRegionIndex(allocator, data, plane_index, region);
    if (leo.matches(data)) return leo.readRegionIndex(allocator, data, plane_index, region);
    if (leicascn.matches(data)) return leicascn.readRegionIndex(allocator, data, plane_index, region);
    if (prairie.matches(data)) return prairie.readRegionIndex(allocator, data, plane_index, region);
    if (flowsight.matches(data)) return flowsight.readRegionIndex(allocator, data, plane_index, region);
    if (metamorph.matches(data)) return metamorph.readRegionIndex(allocator, data, plane_index, region);
    if (mias.matches(data)) return mias.readRegionIndex(allocator, data, plane_index, region);
    if (mikroscan.matches(data)) return mikroscan.readRegionIndex(allocator, data, plane_index, region);
    if (ndpi.matches(data)) return ndpi.readRegionIndex(allocator, data, plane_index, region);
    if (nikonelements.matches(data)) return nikonelements.readRegionIndex(allocator, data, plane_index, region);
    if (nikontiff.matches(data)) return nikontiff.readRegionIndex(allocator, data, plane_index, region);
    if (nikon.matches(data)) return nikon.readRegionIndex(allocator, data, plane_index, region);
    if (photoshoptiff.matches(data)) return photoshoptiff.readRegionIndex(allocator, data, plane_index, region);
    if (ionpathmibi.matches(data)) return ionpathmibi.readRegionIndex(allocator, data, plane_index, region);
    if (pyramidtiff.matches(data)) return pyramidtiff.readRegionIndex(allocator, data, plane_index, region);
    if (scanr.matches(data)) return scanr.readRegionIndex(allocator, data, plane_index, region);
    if (seq.matches(data)) return seq.readRegionIndex(allocator, data, plane_index, region);
    if (simplepci.matches(data)) return simplepci.readRegionIndex(allocator, data, plane_index, region);
    if (sis.matches(data)) return sis.readRegionIndex(allocator, data, plane_index, region);
    if (slidebooktiff.matches(data)) return slidebooktiff.readRegionIndex(allocator, data, plane_index, region);
    if (svs.matches(data)) return svs.readRegionIndex(allocator, data, plane_index, region);
    if (tcs.matches(data)) return tcs.readRegionIndex(allocator, data, plane_index, region);
    if (trestle.matches(data)) return trestle.readRegionIndex(allocator, data, plane_index, region);
    if (vectra.matches(data)) return vectra.readRegionIndex(allocator, data, plane_index, region);
    if (ventana.matches(data)) return ventana.readRegionIndex(allocator, data, plane_index, region);
    if (operetta.matches(data)) return operetta.readRegionIndex(allocator, data, plane_index, region);
    if (ometiff.matches(data)) return ometiff.readRegionIndex(allocator, data, plane_index, region);
    if (zeisslsm.matches(data)) return zeisslsm.readRegionIndex(allocator, data, plane_index, region);
    if (tiff.matches(data)) return tiff.readRegionIndex(allocator, data, plane_index, region);
    if (zip.matches(data)) return zip.readRegionIndex(allocator, data, plane_index, region);
    const plane = try readPlaneIndex(allocator, data, plane_index);
    errdefer allocator.free(plane.data);
    try region.validate(plane.metadata);
    if (region.isFull(plane.metadata)) return plane;
    defer allocator.free(plane.data);
    return .{
        .metadata = plane.metadata,
        .data = try cropPlane(allocator, plane, region),
    };
}

pub fn cropPlane(allocator: std.mem.Allocator, plane: Plane, region: Region) ReaderError![]u8 {
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

test {
    _ = afi;
    _ = analyze;
    _ = apl;
    _ = bdpathway;
    _ = apng;
    _ = avi;
    _ = bmp;
    _ = bioradgel;
    _ = bioradscn;
    _ = bruker;
    _ = canonraw;
    _ = cellomics;
    _ = cellsens;
    _ = cellvoyager;
    _ = cellworx;
    _ = columbus;
    _ = cv7000;
    _ = dcimg;
    _ = deltavision;
    _ = dicom;
    _ = dng;
    _ = ecat7;
    _ = fake;
    _ = feitiff;
    _ = filepattern;
    _ = flex;
    _ = flowsight;
    _ = fluoview;
    _ = fv1000;
    _ = fuji;
    _ = gatan;
    _ = gatandm2;
    _ = gel;
    _ = gif;
    _ = hamamatsuvms;
    _ = imacon;
    _ = im3;
    _ = imagic;
    _ = ics;
    _ = incell;
    _ = incell3000;
    _ = imaris;
    _ = imod;
    _ = improvisiontiff;
    _ = imspector;
    _ = inveon;
    _ = ionpathmibi;
    _ = ivision;
    _ = ipw;
    _ = jdce;
    _ = jpeg;
    _ = jpeg2000;
    _ = jpx;
    _ = leo;
    _ = lif;
    _ = liflim;
    _ = lof;
    _ = metamorph;
    _ = metaxpress;
    _ = mias;
    _ = micromanager;
    _ = microct;
    _ = mikroscan;
    _ = minc;
    _ = mng;
    _ = netpbm;
    _ = klb;
    _ = l2d;
    _ = mrw;
    _ = naf;
    _ = nd2;
    _ = ndpi;
    _ = leicascn;
    _ = nikon;
    _ = nikonelements;
    _ = nikontiff;
    _ = obf;
    _ = oir;
    _ = omexml;
    _ = ometiff;
    _ = operetta;
    _ = openlab;
    _ = oxfordinstruments;
    _ = pcx;
    _ = pci;
    _ = pcoraw;
    _ = pds;
    _ = perkinelmer;
    _ = pict;
    _ = photoshoptiff;
    _ = png;
    _ = prairie;
    _ = psd;
    _ = pyramidtiff;
    _ = qt;
    _ = scanr;
    _ = sdt;
    _ = seq;
    _ = seiko;
    _ = simplepci;
    _ = sis;
    _ = slidebooktiff;
    _ = spc;
    _ = svs;
    _ = tcs;
    _ = tecan;
    _ = tga;
    _ = tillvision;
    _ = tiff;
    _ = trestle;
    _ = unisoku;
    _ = vectra;
    _ = veeco;
    _ = ventana;
    _ = visitech;
    _ = volocityclipping;
    _ = xlef;
    _ = zeissczi;
    _ = zeisslms;
    _ = zeisslsm;
    _ = zeisstiff;
    _ = zeissxrm;
    _ = zip;
}

test "metadata maps z c t coordinates using dimension order" {
    const metadata = Metadata{
        .format = "test",
        .width = 1,
        .height = 1,
        .size_z = 2,
        .size_t = 2,
        .size_c = 3,
        .samples_per_pixel = 1,
        .pixel_type = .uint8,
        .plane_count = 12,
        .dimension_order = "XYZCT",
    };
    try std.testing.expectEqual(@as(u32, 0), try metadata.planeIndex(0, 0, 0));
    try std.testing.expectEqual(@as(u32, 1), try metadata.planeIndex(1, 0, 0));
    try std.testing.expectEqual(@as(u32, 2), try metadata.planeIndex(0, 1, 0));
    try std.testing.expectEqual(@as(u32, 6), try metadata.planeIndex(0, 0, 1));
    try std.testing.expectError(error.InvalidPlaneIndex, metadata.planeIndex(2, 0, 0));
}

test "metadata maps alternate dimension order" {
    const metadata = Metadata{
        .format = "test",
        .width = 1,
        .height = 1,
        .size_z = 2,
        .size_t = 2,
        .size_c = 3,
        .samples_per_pixel = 1,
        .pixel_type = .uint8,
        .plane_count = 12,
        .dimension_order = "XYCZT",
    };
    try std.testing.expectEqual(@as(u32, 1), try metadata.planeIndex(0, 1, 0));
    try std.testing.expectEqual(@as(u32, 3), try metadata.planeIndex(1, 0, 0));
    try std.testing.expectEqual(@as(u32, 6), try metadata.planeIndex(0, 0, 1));
}

test "crops plane through shared region helper" {
    var plane_data = [_]u8{ 1, 2, 3, 4 };
    const plane = Plane{
        .metadata = .{
            .format = "test",
            .width = 2,
            .height = 2,
            .size_c = 1,
            .samples_per_pixel = 1,
            .pixel_type = .uint8,
        },
        .data = &plane_data,
    };
    const cropped = try cropPlane(std.testing.allocator, plane, .{ .x = 1, .y = 0, .width = 1, .height = 2 });
    defer std.testing.allocator.free(cropped);
    try std.testing.expectEqualSlices(u8, &.{ 2, 4 }, cropped);
}
