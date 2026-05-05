# bioformats-zig

Experimental Zig reimplementation slice of Bio-Formats focused on embedding through
a small stdio JSON-RPC process.

The current binary is line-delimited JSON-RPC 2.0 over stdin/stdout. Each request
is one JSON object or JSON-RPC batch array followed by `\n`; each response is one
JSON object or batch response array followed by `\n`. Requests must include
`"jsonrpc":"2.0"`. Request IDs may be strings, numbers, or `null`.
Request lines may be up to 768 MiB, which allows large inline base64 image
inputs without being constrained by the process' stdin buffer size.

Valid JSON-RPC notifications, requests without `id`, are accepted and do not
produce a response. In batch responses, notifications are omitted from the
response array. Invalid request objects still produce JSON-RPC errors.

## Build

```sh
zig build
```

The executable is written to `zig-out/bin/bioformats-zig`.

## Protocol

Supported methods:

- `initialize`
- `formats`
- `probe` with `{"path":"image.ext"}` or `{"data":"base64..."}`
- `open` with `{"path":"image.ext"}` or `{"data":"base64..."}` to create a process-local reader handle
- `close` with `{"handle":1}` to release a reader handle
- `metadata` with `{"path":"image.ext"}`, `{"data":"base64..."}`, or `{"handle":1}`
- `readPlane` with `{"path":"image.ext"}`, `{"data":"base64..."}`, or `{"handle":1}`
- `shutdown`

Example:

```json
{"jsonrpc":"2.0","id":1,"method":"metadata","params":{"path":"sample.ppm"}}
```

Batch requests are supported on a single line:

```json
[{"jsonrpc":"2.0","id":1,"method":"initialize"},{"jsonrpc":"2.0","id":2,"method":"formats"}]
```

`readPlane` returns raw plane bytes as base64:

```json
{"metadata":{"format":"netpbm","width":1,"height":1,"sizeC":3,"sizeZ":1,"sizeT":1,"pixelType":"rgb8","littleEndian":false,"planeCount":1},"encoding":"base64","data":"ChQe"}
```

For hosts that already have image bytes in memory, `probe`, `open`, `metadata`,
and `readPlane` accept standard base64 image data in `params.data`. `path`,
`handle`, and `data` are mutually exclusive input sources:

```json
{"jsonrpc":"2.0","id":1,"method":"metadata","params":{"data":"UDYKMSAxCjI1NQoBAgM="}}
```

For repeated reads, use the handle form:

```json
{"jsonrpc":"2.0","id":1,"method":"open","params":{"path":"sample.ppm"}}
{"jsonrpc":"2.0","id":2,"method":"metadata","params":{"handle":1}}
{"jsonrpc":"2.0","id":3,"method":"readPlane","params":{"handle":1,"planeIndex":0}}
{"jsonrpc":"2.0","id":4,"method":"close","params":{"handle":1}}
```

`planeIndex` is zero-based. Multi-IFD TIFF files expose additional planes via
`metadata.planeCount`. `readPlane` also accepts an optional pixel region.
Chunky stripped, separated planar stripped, and tiled TIFF regions are decoded
selectively instead of materializing the whole plane first, including baseline
TIFF entries reached through supported ZIP archives:

```json
{"jsonrpc":"2.0","id":3,"method":"readPlane","params":{"handle":1,"planeIndex":0,"x":128,"y":128,"width":512,"height":512}}
```

When OME dimensions are available, `readPlane` can use zero-based `z`, `c`,
and `t` coordinates instead of `planeIndex`:

```json
{"jsonrpc":"2.0","id":3,"method":"readPlane","params":{"handle":1,"z":1,"c":0,"t":0}}
```

These inline data, region, and `z`/`c`/`t` addressing capabilities are
advertised by the `initialize` response.

TIFF `ImageDescription` is exposed as `metadata.imageDescription`; OME-TIFF
files commonly store OME-XML in that field. When an OME `Pixels` element is
present, `SizeZ`, `SizeC`, `SizeT`, and `DimensionOrder` are reflected in the
JSON metadata. `samplesPerPixel` remains the physical samples stored in each
plane, which can differ from logical OME `sizeC`.

## Implemented Readers

- AIM int16 volumes with legacy and V030 dimension headers; Z slices are exposed as planes.
- Alicona AL3D files with single-channel 8/16-bit texture planes or 32-bit floating-point depth planes; color texture variants are not yet supported.
- AmiraMesh/Avizo raw binary single-stream lattice files with 8/16/32-bit integer and 32-bit floating-point scalar planes; ASCII, compressed, and multi-stream variants are not yet supported.
- Animated PNG files identified by the `acTL` chunk, with the default PNG image decoded through the PNG reader; subsequent animation frames, frame coordinates, blending/disposal, and loop metadata are not yet handled.
- ARF files with little/big-endian unsigned 8/16/32-bit raw planes; version 2 image stacks are exposed as time planes.
- AVI files with uncompressed DIB `00db`/`00dc` frames for 8-bit grayscale, 24-bit RGB, and 32-bit RGBA planes; compressed AVI codecs, palettes, audio streams, and metadata beyond core dimensions are not yet handled.
- Bio-Rad PIC single-file images with 8/16-bit grayscale planes; companion XML/raw grouping and note metadata are not yet handled.
- BD Pathway TIFF files identified by MATROX Imaging Library software tags, decoded through the TIFF pixel path; `.exp` experiment metadata, HCS well/field grouping, channel names, ROIs, and acquisition metadata are not yet handled.
- Bio-Rad GEL `.1sc` files with fixed magic and metadata block dimensions, decoded from uncompressed tail pixels with row-order normalization; Bio-Formats' cropped-image offset heuristics and acquisition metadata are not yet handled.
- Netpbm plain and binary PBM/PGM/PPM (`P1`-`P6`) plus simple PAM (`P7`) black-and-white, grayscale/grayscale-alpha/RGB/RGBA with 1-bit bitmap and 8/16-bit samples; omitted PAM tuple types are inferred for grayscale, grayscale-alpha, RGB, and RGBA depths when unambiguous.
- BMP BI_RGB 1/4/8-bit indexed, 16-bit RGB555, 24-bit, and 32-bit files, including extended-header RGB/RGBA masks; indexed and 24-bit OS/2 core-header BMP; BI_RLE4/BI_RLE8 indexed files; plus 16/32-bit BI_BITFIELDS/BI_ALPHABITFIELDS RGB/RGBA masks, returned as RGB/RGBA.
- Burleigh SPM `.img` files with little-endian 16-bit grayscale planes for version 2.1 and 3.1 headers.
- Canon RAW fixed-length Bayer dumps matching Bio-Formats' legacy 18,653,760-byte reader, unpacked from 12-bit samples into interpolated little-endian RGB16 planes.
- Canon DNG/RAW TIFF-like files identified by Canon TIFF-EP/private tags, decoded through the TIFF pixel path when the stored image is directly TIFF-readable; non-TIFF Canon CRW variants beyond the fixed-length legacy RAW reader and white-balance metadata expansion are not yet handled.
- Bio-Rad SCN multipart files identified by Image Lab headers, with dimensions and pixel type parsed from XML and one raw octet-stream image block decoded; acquisition metadata, detector metadata, and physical pixel sizes are not yet surfaced.
- Cellomics C01/DIB files with uncompressed little-endian raw planes at the standard offset; compressed `.c01` streams, multi-file plate/channel grouping, MDB metadata, and missing-channel fill behavior are not yet handled.
- Hamamatsu DCIMG version 1 files with little-endian mono8/mono16 frames exposed as time planes, including row-order normalization; grouped `.dcimg` Z stacks, version 0 footers, frame footer four-pixel correction, timestamps, and acquisition metadata are not yet handled.
- Deltavision DV/R3D files with fixed headers and uncompressed 8/16/32-bit integer or 32/64-bit floating-point raw planes, including stored Z/W/T sequence mapping and row-order normalization; extended-header metadata, log files, panel/position series splitting, tiling/stage metadata, and objective/channel metadata are not yet handled.
- DICOM files with a `DICM` preamble and native explicit VR little-endian, implicit VR little-endian, or explicit VR big-endian pixel data for 8/16-bit grayscale, RGB, and RGBA planes, including planar RGB/RGBA normalization to interleaved output and MONOCHROME1 grayscale inversion; compressed transfer syntaxes, encapsulated fragments, palettes, WSI tiling, and multi-file series grouping are not yet handled.
- ECAT7 files with `MATRIX72v` headers and big-endian unsigned 16-bit planes, including Bio-Formats' per-frame padding rule; other ECAT7 matrix data types and medical metadata fields are not yet surfaced.
- EPS/PostScript files with declared 8-bit grayscale or RGB raster image data stored as ASCII hex or raw bytes; TIFF previews and vector-only EPS are not yet supported.
- FEI/Philips SEM IMG files with interlaced 8-bit grayscale pixels.
- FEI TIFF files identified by S-FEG, Helios, or Titan private metadata tags, decoded through the TIFF pixel path.
- FITS primary image HDUs with 8-bit unsigned, 16/32-bit signed integer, and 32/64-bit floating-point pixels, with `NAXIS3` exposed as planes.
- Olympus Fluoview/ABD TIFF files identified by Fluoview or Andor comments and private metadata tags, decoded through the TIFF pixel path; montage/field grouping, timestamps, physical sizes, and hardware metadata parsing are not yet handled.
- Gatan DM2 files with fixed headers and contiguous big-endian integer pixels; footer tag metadata, physical sizes, timestamps, and newer DM3/DM4 tag-tree formats are not yet handled.
- Amersham Biosciences GEL TIFF files identified by Molecular Dynamics private tags, decoded through the TIFF pixel path for single-IFD linear files; square-root scaled GEL images and two-IFD merge variants are rejected as unsupported.
- GIF87a/GIF89a indexed color images exposed as planes, with global or local palettes, image descriptor offsets on the logical canvas, interlaced row reordering, Graphic Control transparency, and LZW image data, returned as RGB/RGBA.
- Hamamatsu HIS single-series files with little-endian 8/16-bit grayscale or RGB planes; packed 12-bit and multi-series HIS files are not yet supported.
- NOAA-HRD Gridded Data Format surface wind component tables exposed as two big-endian 64-bit floating-point channel planes.
- I2I int16 and 32-bit floating-point volumes with little/big endian data and optional extra time-like dimension exposed as planes.
- Imacon `.fff` TIFF files identified by Imacon XML private metadata tags, decoded through the TIFF pixel path.
- Bitplane Imaris raw `.ims` files with big-endian fixed headers and uncompressed 8-bit grayscale Z/C planes; metadata, physical sizes, timestamps, detector/channel settings, and newer HDF/Imaris TIFF variants are not yet handled.
- IMOD `.mod` model files identified by `IMODV1.2`, exposing blank RGB planes with parsed model dimensions to match Bio-Formats' disabled point-rendering path; ROI/model object metadata and contour drawing are not yet surfaced.
- Improvision TIFF files identified by Improvision image descriptions, decoded through the TIFF pixel path; multi-file grouping and Improvision axis metadata interpretation are not yet handled.
- INR raw fixed-size images with 8/16/32-bit signed or unsigned integer samples; `ZDIM` and `VDIM` are exposed as plane axes.
- Ionpath MIBI TIFF files identified by IonpathMIBI software tags, decoded through the TIFF pixel path; SIMS series grouping and channel metadata parsing are not yet handled.
- IPLab files with 8/16/32-bit integer and 32/64-bit floating-point raw planes; Z/T images are exposed as planes.
- IVision `.ipm` files with big-endian inline 8/16/32-bit scalar pixels plus padded RGB8 and RGB16 planes; 16-bit color compaction, square-root encoding, XML metadata, LUT extraction, and acquisition metadata are not yet handled.
- JEOL `MG`/`IM` single-file images with little-endian metadata and 8-bit grayscale pixels; companion `.par` metadata grouping is not yet handled.
- Khoros XV raw rasters with 8/16-bit grayscale or RGB samples and 8-bit indexed LUT images expanded to RGB.
- KLB single-file volumes with uncompressed single-block 8/16/32-bit integer or 32/64-bit floating-point scalar pixels, exposing Z slices as planes; block tiling, bzip2/zlib compression, grouped time/channel folders, projections, and physical-size metadata are not yet handled.
- Kodak Molecular Imaging BIP files with big-endian 32-bit floating-point grayscale planes.
- LEO TIFF files with private LEO metadata tags, decoded through the TIFF pixel path.
- LI-FLIM `.fli` files with embedded version 1/2 headers and uncompressed 8/16/32-bit integer or 32/64-bit floating-point little-endian planes; gzip compression, packed 12-bit data, background/dark image series, ROI overlays, timestamps, and exposure metadata are not yet handled.
- Laboratory Imaging LIM uncompressed files with 8/16/32-bit grayscale or BGR/RGB planes; compressed LIM is not yet supported.
- Metamorph STK/TIFF files identified by Metamorph software strings or UIC private tags, decoded through the TIFF pixel path; `.nd/.scan` grouping and UIC metadata interpretation are not yet handled.
- MIAS TIFF files identified by eaZYX, SCIL_Image, or IDL software tags, decoded through the TIFF pixel path; plate/well grouping, tile stitching, masks, overlays, and analysis-result metadata are not yet handled.
- MicroCT VFF files with inline `ncaa` headers and signed 8/16/32-bit raw planes, including row-order normalization; directory file-pattern grouping, XML side metadata, dates, exposure time, and physical size metadata are not yet surfaced.
- Mikroscan TIFF files identified by Mikroscan image descriptions, decoded through the TIFF pixel path; SVS-style subresolution/label/macro series mapping and Mikroscan-specific metadata parsing are not yet handled.
- Molecular Imaging STP files with inline metadata and little-endian 16-bit grayscale planes.
- Minolta MRW files with PRD/WBG metadata blocks, 12/16-bit Bayer pixels, white-balance scaling, and linear interpolation into RGB16 planes; embedded TIFF/EXIF metadata blocks are not yet surfaced.
- MNG files identified by the MNG signature and `MHDR` chunk, with the first embedded PNG image decoded through the PNG reader; JNG chunks, multiple frames/series, loops, and animation timing are not yet handled.
- PNG 1/2/4/8-bit grayscale/indexed color, 8/16-bit grayscale and grayscale-alpha/RGB/RGBA, optional tRNS transparency, standard scanline filters, and Adam7 interlace.
- MRC microscopy volumes with 8-bit unsigned, 16-bit signed/unsigned, 32-bit floating-point, and RGB byte modes; Z slices are exposed as planes and row order is normalized to top-down output.
- NIfTI single-file `.nii` images with inline 8/16/32-bit integer and 32/64-bit floating-point planes, plus RGB/RGBA byte samples; `.hdr/.img` pairs and `.nii.gz` are not yet handled.
- Nikon Elements TIFF files identified by Nikon XML private metadata tags, decoded through the TIFF pixel path.
- Nikon EZ-C1 TIFF files identified by Nikon software tags, decoded through the TIFF pixel path; Nikon microscope metadata parsing for objectives, lasers, filters, wavelengths, and physical sizes is not yet handled.
- NRRD single-file attached raw 2D/3D raster data with 8/16/32-bit integer and 32/64-bit floating-point samples; `sizes` third axis is exposed as planes.
- OME-XML files with inline uncompressed or zlib-compressed base64 `BinData` for integer and floating-point pixel types, plus blank planes when no `BinData` is stored; bzip2/JPEG/JPEG-2000 BinData, multi-image documents, OME-TIFF companion files, and full OME metadata mapping are not yet handled.
- OME-TIFF files identified by OME-XML in the first IFD image description, decoded through the TIFF pixel path; OME plane-to-IFD mapping, multi-file OME-TIFF datasets, companion-only metadata files, and full OME metadata mapping are not yet handled.
- Openlab RAW files with fixed per-image records, 8/16-bit grayscale, and RGB byte planes.
- Oxford Instruments TOP files identified by fixed headers, with little-endian 16-bit pixels read after the LUT block; descriptive metadata strings, acquisition timestamps, and physical calibration are not yet surfaced.
- PCX 8-bit grayscale, 256-color palette, and three-plane RGB files with PCX RLE compression, returned as grayscale or RGB.
- Photoshop TIFF files identified by image source data private tags, with the merged TIFF image decoded; Photoshop layer extraction is not yet handled.
- PicoQuant BIN FLIM files with little-endian 32-bit unsigned lifetime bins exposed as time planes.
- Photoshop PSD files with uncompressed merged 8/16-bit grayscale, 8/16-bit RGB, and 8-bit indexed-color pixels; PackBits-compressed PSD pixels, layer extraction, CMYK/Lab/multichannel modes, and vector data are not yet handled.
- POV-Ray DF3 volumes with 8/16/32-bit big-endian unsigned samples; Z slices are exposed as planes.
- Pyramid TIFF files identified by Faas software tags, decoded through the TIFF pixel path; pyramid resolution metadata is not yet modeled as series.
- Quesant AFM files with square little-endian 16-bit grayscale planes.
- RHK Technologies SPM files with 8-bit unsigned, 16/32-bit signed integer, and 32-bit floating-point scalar planes, including text-header axis flips.
- SBIG astronomy images with little-endian 16-bit grayscale pixels and SBIG row compression.
- Seiko `.xqd/.xqf` files with fixed-header little-endian 16-bit grayscale planes.
- Image-Pro Sequence TIFF files identified by Image-Pro private array tags, decoded through the TIFF pixel path; `.ips` grouping files, channel names, and multi-file Z/T/position expansion are not yet handled.
- Andor SIF files with little-endian 32-bit floating-point image planes.
- SimplePCI TIFF files identified by Hamamatsu SimplePCI image descriptions, decoded through the TIFF pixel path; channel splitting from SimplePCI metadata is not yet handled.
- Olympus SIS TIFF files identified by SIS private tags with analySIS/Olympus metadata, decoded through the TIFF pixel path; SIS-specific physical size and channel metadata parsing are not yet handled.
- Slidebook TIFF files identified by SlideBook software and private stage/channel metadata tags, decoded through the TIFF pixel path; multi-file grouping, channel naming, stage positions, and physical size metadata parsing are not yet handled.
- SPIDER EM images/stacks with 32-bit floating-point planes and little/big endian header detection.
- Princeton Instruments SPE files with 16/32-bit integer and 32-bit floating-point raw frames exposed as time planes.
- SM Camera fixed-header 8-bit grayscale images.
- Aperio SVS TIFF files identified by Aperio image descriptions and multiple IFDs, decoded through the TIFF pixel path; SVS label/macro/subresolution series mapping and metadata extraction are not yet handled.
- Leica TCS TIFF files identified by `CHANNEL` document names or `TCS` software tags, decoded through the TIFF pixel path; companion XML, multi-file grouping, timestamps, physical sizes, exposure times, and Leica XML metadata are not yet handled.
- TGA uncompressed and RLE 8/16-bit color-mapped with 15/16/24/32-bit palettes, 8-bit grayscale, 16-bit grayscale/alpha, 15/16/24-bit truecolor, and 16/32-bit truecolor/alpha files, including truecolor/grayscale files with unused color maps.
- Text/CSV tables with `x` and `y` coordinate columns plus one or more numeric value columns exposed as big-endian 32-bit floating-point channel planes.
- TIFF/BigTIFF baseline 1/2/4-bit packed and 8/16/32-bit grayscale, RGB (`rgb8`/`rgb16`), RGBA (`rgba8`/`rgba16`), 1/2/4/8-bit palette color, signed integer grayscale, and 32/64-bit float grayscale strips and tiles with uncompressed, PackBits, LZW, and Deflate compression, including horizontal differencing Predictor=2 for 8/16-bit integer samples. BlackIsZero and WhiteIsZero grayscale, FillOrder 1/2 for packed low-bit samples, chunky RGB/RGBA, color-map expansion to RGB, and separated planar RGB/RGBA strips and tiles are supported.
- TopoMetrix `.tfr/.ffr/.zfr/.zfp/.2fl` files with little-endian 16-bit grayscale planes.
- Trestle TIFF files identified by Trestle copyright tags, decoded through the TIFF pixel path; companion `.sld/.slx/.ROI` grouping, overlap handling, and ROI metadata are not yet handled.
- UBM `.pr3` files with little-endian 32-bit unsigned grayscale planes and per-row padding.
- Varian FDF single-file images with 8/16/32-bit unsigned and 32-bit floating-point raw planes; rows are normalized to top-down output. Directory-based multifile FDF grouping is not yet handled.
- PerkinElmer Vectra/QPTIFF files identified by QPI software tags, decoded through the TIFF pixel path; profile XML, annotation companion files, subresolution modeling, and Vectra channel metadata parsing are not yet handled.
- Ventana BIF TIFF files identified by iScan XML private metadata, decoded through the TIFF pixel path; tile stitching, split-tile mode, subresolution mapping, and Ventana XML metadata extraction are not yet handled.
- VG SAM DTI files with big-endian 8/16-bit unsigned or 32-bit floating-point grayscale planes.
- WA Technology TOP `.wat` files with fixed-header little-endian signed 16-bit grayscale planes.
- Zeiss LMS files identified by the LMSFLE marker, with CSM 700 fixed-size little-endian 16-bit Z planes read after the thumbnail and LUT blocks; the thumbnail series, palette LUT, objective magnification, and other instrument metadata are not yet surfaced.
- Zeiss LSM TIFF files identified by the private `TIF_CZ_LSMINFO` tag, decoded through the TIFF pixel path; LSM dimension metadata, channel names/colors, LUTs, timestamps, ROIs, and MDB multi-file grouping are not yet parsed.
- ZIP archives are delegated to the first stored or deflated local-file AIM, Alicona, Amira/Avizo, APNG, ARF, AVI, BD Pathway TIFF, Bio-Rad GEL, Bio-Rad PIC, Bio-Rad SCN, BMP, Burleigh SPM, Cellomics C01/DIB, DCIMG, Deltavision DV/R3D, DICOM, ECAT7, EPS/PostScript, FEI TIFF, FEI/Philips SEM IMG, FITS, Fluoview TIFF, Gatan DM2, GIF, Hamamatsu HIS, HRD GDF, I2I, Imacon TIFF, Image-Pro SEQ, Imaris raw, IMOD, Improvision TIFF, INR, Ionpath MIBI TIFF, IPLab, IVision, JEOL MG/IM, Khoros XV, KLB, Kodak BIP, Laboratory Imaging LIM, Leica TCS TIFF, LEO TIFF, LI-FLIM, MetaMorph TIFF, MIAS TIFF, MicroCT VFF, Mikroscan TIFF, Minolta MRW, MNG, Molecular Imaging, MRC, Netpbm, NIfTI, Nikon Elements TIFF, Nikon TIFF, NRRD, OME-XML, OME-TIFF, Openlab RAW, Oxford Instruments TOP, PCX, Photoshop TIFF, PicoQuant BIN, PNG, POV-Ray DF3, PSD, Quesant AFM, RHK SPM, SBIG, Seiko, SIF, SimplePCI TIFF, SIS TIFF, SlideBook TIFF, SM Camera, SPE, SPIDER, SVS TIFF, Text/CSV, TGA, TopoMetrix, Trestle, UBM, Varian FDF, Vectra/QPTIFF, Ventana BIF, VG SAM, WA Technology TOP, Zeiss LMS, Zeiss LSM, or baseline TIFF entry; encrypted/data-descriptor ZIP entries, central-directory-only archives, other inner formats, and multi-file dataset grouping inside ZIPs are not yet handled.

This is not a complete Bio-Formats replacement yet. The repository now has the
embedding boundary and reader shape needed to port additional `FormatReader`
implementations from `../bioformats`.
