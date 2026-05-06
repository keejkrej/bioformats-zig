# bioformats-zig

Experimental Zig reimplementation slice of Bio-Formats focused on embedding through
a small stdio JSON-RPC process.

The current binary is JSON-RPC 2.0 over stdin/stdout. It accepts either
line-delimited messages, where each request is one JSON object or JSON-RPC batch
array followed by `\n`, or `Content-Length: N\r\n\r\n...` framed messages.
Responses use the same framing style as the request. Requests must include
`"jsonrpc":"2.0"`. Request IDs may be strings, numbers, or `null`. Request
lines or framed bodies may be up to 768 MiB, which allows large inline base64
image inputs without being constrained by the process' stdin buffer size.

Some `formats` entries are Bio-Formats Java reader-name aliases for canonical
Zig readers. For example, `targa` is advertised as an alias of `tga`, and
`metamorphtiff` is advertised as an alias of `metamorph`; probe and metadata
responses keep returning the canonical Zig format ID.

Valid JSON-RPC notifications, requests without `id`, are accepted and do not
produce a response. In batch responses, notifications are omitted from the
response array. Invalid request objects still produce JSON-RPC errors.

## Build

```sh
zig build
```

The executable is written to `zig-out/bin/bioformats-zig`.

JPEG-2000 and JPX pixel reads use OpenJPEG when it is found at build time. The
build checks `-Dopenjpeg-root=...`, then `VCPKG_ROOT`, then the local Windows
vcpkg locations used during development. Pass `-Dopenjpeg=false` to force a
dependency-free build without JPEG-2000 pixels. The root must contain
`include/openjpeg-2.5/openjpeg.h` and an `openjp2` library under `lib/`.

```sh
zig build -Dopenjpeg-root=/path/to/openjpeg-or-vcpkg-installed-triplet
zig build -Dopenjpeg=false
```

On Windows, `zig build` also copies `openjp2.dll` beside the executable when
OpenJPEG is built from a vcpkg-style root. Use `formats` or
`tools/audit-readers.ps1 -Strict` against the built binary to verify whether
`jpeg2000` and `jpx` are advertised with `canReadPixels:true`.

## Reader Audit

When the sibling `../bioformats` checkout is available, compare concrete Java
reader classes against the Zig format catalog and list remaining metadata-only
formats. If `zig-out/bin/bioformats-zig.exe` exists, the audit uses the
binary's runtime `formats` response so build-time optional dependencies are
checked as embedders will see them:

```powershell
./tools/audit-readers.ps1
```

## Protocol Smoke Test

After building the binary, exercise the embedder-facing stdio boundary with both
line-delimited JSON-RPC and `Content-Length` framing:

```powershell
zig build
./tools/smoke-jsonrpc.ps1
```

When the sibling `../bioformats` checkout is available, a small upstream sample
smoke test exercises OME-XML files from Bio-Formats' own schema fixtures through
the same JSON-RPC binary:

```powershell
./tools/smoke-upstream-samples.ps1
```

## Fixture Sources

Public fixture discovery is tracked in `fixtures/`. The current catalog points
to OME's public sample image download tree and the Bio-Formats Zenodo community,
with per-format source status for the implemented readers. Large sample images
should be downloaded into a local cache outside git and exercised through the
JSON-RPC `probe`, `metadata`, and small-region `readPlane` methods.

## Web Viewer

A small local testing UI lives in `webapp/`. It uses React/Vite in the browser,
a Node WebSocket bridge, and the `zig-out/bin/bioformats-zig` JSON-RPC binary as
the image reader process.

```sh
zig build
cd webapp
npm install
npm run dev
```

Open the Vite URL printed by the command. The viewer includes a browser-rendered
file dialog backed by the Node bridge, with folder entry, file selection, Up, and
Home controls. React communicates with Node over WebSocket, then Node forwards
image operations to the Zig JSON-RPC binary. The UI can inspect metadata, choose
a plane, and draw the returned base64 pixels on a canvas.

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

For companion-file formats, path-based requests may use neighboring files. For
example, Analyze 7.5 `.hdr`/`.img`, Olympus APL `.apl/.tnb/.mtb` plus TIFF
planes, ICS `.ics`/`.ids`, IMAGIC `.hed`/`.img`, CellVoyager
`MeasurementResult.xml` plus `Image` TIFF planes, CellWorx `.htd` plus
Deltavision `.pnl` planes, Columbus
`MeasurementIndex.ColumbusIDX.xml` plus TIFF planes, Yokogawa CV7000
`.wpi`/`MeasurementData.mlf` datasets plus TIFF planes, Fuji LAS 3000
`.inf`/`.img`, Inveon `.hdr`/data pairs, MetaXpress `.htd` plus neighboring
TIFF planes, Flex `.mea/.res` files plus sibling `.flex` TIFF planes,
Micro-Manager `metadata.txt` plus TIFF planes, PerkinElmer `.htm`
plus TIFF planes, JDCE `.jdce`/CSV datasets plus TIFF planes, Perkin Elmer
Densitometer `.hdr`/`.img`, Hitachi S-4800 `.txt` plus neighboring TIFF/BMP/JPEG,
PCO-RAW `.pcoraw`/`.rec`, Tecan `.db` plus `Images` TIFF planes,
TillVision `.pst/.inf`, and Unisoku STM
`.HDR`/`.DAT` datasets can be opened
by selecting either file; inline `data` can identify the header but cannot
provide the paired pixel file.

Example:

```json
{"jsonrpc":"2.0","id":1,"method":"metadata","params":{"path":"sample.ppm"}}
```

Batch requests are supported on a single line:

```json
[{"jsonrpc":"2.0","id":1,"method":"initialize"},{"jsonrpc":"2.0","id":2,"method":"formats"}]
```

Hosts that already use Language Server Protocol style stdio framing can send the
same JSON body with a `Content-Length` header:

```text
Content-Length: 46

{"jsonrpc":"2.0","id":1,"method":"initialize"}
```

`readPlane` returns raw plane bytes as base64:

```json
{"metadata":{"format":"netpbm","width":1,"height":1,"sizeC":3,"sizeZ":1,"sizeT":1,"pixelType":"rgb8","littleEndian":false,"planeCount":1,"imageCount":1,"seriesCount":1,"samplesPerPixel":3},"encoding":"base64","data":"ChQe"}
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
`metadata.planeCount`; `metadata.imageCount` is the same per-series image count,
and `metadata.seriesCount` reports the number of series modeled by the reader.
`readPlane` also accepts an optional pixel region.
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

Path-based ND2 and CZI reads also accept zero-based `series` when
`metadata.seriesCount` is greater than 1.

These inline data, region, and `z`/`c`/`t` addressing capabilities are
advertised by the `initialize` response.

TIFF `ImageDescription` is exposed as `metadata.imageDescription`; OME-TIFF
files commonly store OME-XML in that field. When an OME `Pixels` element is
present, `SizeZ`, `SizeC`, `SizeT`, and `DimensionOrder` are reflected in the
JSON metadata. `samplesPerPixel` remains the physical samples stored in each
plane, which can differ from logical OME `sizeC`.

## Implemented Readers

- Aperio AFI XML sidecars that list neighboring SVS files, delegated through the first referenced SVS image and reported as `afi`; multi-channel AFI assembly and per-channel SVS metadata merging are not yet handled.
- AIM int16 volumes with legacy and V030 dimension headers; Z slices are exposed as planes.
- Alicona AL3D files with single-channel 8/16-bit texture planes or 32-bit floating-point depth planes; color texture variants are not yet supported.
- AmiraMesh/Avizo binary single-stream lattice files with raw or `HxZip`-compressed 8/16/32-bit integer and 32-bit floating-point scalar planes; ASCII, `HxByteRLE`, and multi-stream variants are not yet supported.
- Analyze 7.5 `.hdr`/`.img` pairs with scalar 8-bit, signed 16/32-bit, 32/64-bit floating-point, and RGB8 pixel data; path-based JSON-RPC requests can open either companion file, while inline header data is metadata-only.
- Olympus APL `.apl/.tnb/.mtb` datasets delegated through the first nested or selected TIFF plane and reported as `apl`; MDB metadata, XML sidecars, multi-series assembly, and physical calibration are not yet surfaced.
- Animated PNG files identified by the `acTL` chunk, with the default PNG image decoded through the PNG reader; subsequent animation frames, frame coordinates, blending/disposal, and loop metadata are not yet handled.
- ARF files with little/big-endian unsigned 8/16/32-bit raw planes; version 2 image stacks are exposed as time planes.
- AVI files with uncompressed DIB `00db`/`00dc` frames for 8-bit grayscale, 24-bit RGB, and 32-bit RGBA planes; compressed AVI codecs, palettes, audio streams, and metadata beyond core dimensions are not yet handled.
- Bio-Rad PIC single-file images with 8/16-bit grayscale planes; companion XML/raw grouping and note metadata are not yet handled.
- BD Pathway TIFF files identified by MATROX Imaging Library software tags, plus `.exp` experiment paths delegated through the first TIFF in the experiment root or first `Well ...` folder; full experiment metadata, HCS well/field grouping, channel names, ROIs, and acquisition metadata are not yet handled.
- BigDataViewer XML/HDF5 datasets are detected from `SpimData` XML and parsed as `bdv` using `ViewSetup` size/channel and timepoint declarations, with XML path reads resolving the companion HDF5 file and exposing contiguous uncompressed uint16 `ZYX` datasets as scalar planes; chunked/compressed HDF5 datasets, actual pixel type detection beyond uint16, multi-resolution metadata, labels/ROIs, colors, and physical calibration are not yet implemented.
- Bio-Rad GEL `.1sc` files with fixed magic and metadata block dimensions, decoded from uncompressed tail pixels with row-order normalization; Bio-Formats' cropped-image offset heuristics and acquisition metadata are not yet handled.
- Netpbm plain and binary PBM/PGM/PPM (`P1`-`P6`) plus simple PAM (`P7`) black-and-white, grayscale/grayscale-alpha/RGB/RGBA with 1-bit bitmap and 8/16-bit samples; omitted PAM tuple types are inferred for grayscale, grayscale-alpha, RGB, and RGBA depths when unambiguous.
- BMP BI_RGB 1/4/8-bit indexed, 16-bit RGB555, 24-bit, and 32-bit files, including extended-header RGB/RGBA masks; indexed and 24-bit OS/2 core-header BMP; BI_RLE4/BI_RLE8 indexed files; plus 16/32-bit BI_BITFIELDS/BI_ALPHABITFIELDS RGB/RGBA masks, returned as RGB/RGBA.
- Burleigh SPM `.img` files with little-endian 16-bit grayscale planes for version 2.1 and 3.1 headers.
- Canon RAW fixed-length Bayer dumps matching Bio-Formats' legacy 18,653,760-byte reader, unpacked from 12-bit samples into interpolated little-endian RGB16 planes.
- DNG/RAW TIFF-like files identified by DNGVersion or Canon TIFF-EP/private tags, decoded through the TIFF pixel path when the stored image is directly TIFF-readable, including baseline JPEG-in-TIFF preview strips; compressed RAW subIFDs, non-TIFF Canon CRW variants beyond the fixed-length legacy RAW reader, and white-balance metadata expansion are not yet handled.
- Bio-Rad SCN multipart files identified by Image Lab headers, with dimensions and pixel type parsed from XML and one raw octet-stream image block decoded; acquisition metadata, detector metadata, and physical pixel sizes are not yet surfaced.
- CellH5 `.ch5` HDF5 files are detected from CellH5 group markers and parsed from the first rank-5 CTZYX dataspace, with contiguous uncompressed dataset layouts exposed as scalar planes; full HDF5 traversal, multi-series plate/well/site mapping, segmentation/ROI/classification metadata, chunk/deflate pixel reads, and LUTs are not yet implemented.
- Cellomics C01/DIB files with uncompressed little-endian raw planes at the standard offset; compressed `.c01` streams, multi-file plate/channel grouping, MDB metadata, and missing-channel fill behavior are not yet handled.
- Olympus cellSens `.vsi` files with TIFF-readable embedded planes are delegated through the TIFF path and reported as `cellsens`; companion `.ets` tile files are discovered for path reads, with base image bounds, RGB pixel metadata, and pyramid series counts derived from VSI `IMAGE_BOUNDARY` records and ETS chunk tables. Full proprietary VSI tag-tree metadata, channel/Z/T assembly beyond the first plane, non-JPEG/RAW ETS compression variants, and acquisition metadata are not yet handled.
- Yokogawa CellVoyager/CV1000 `MeasurementResult.xml` datasets delegated through TIFF planes in the `Image` directory using the Bio-Formats filename pattern; tile stitching, well/area series assembly, malformed OME-XML repair, plate metadata, and physical/acquisition metadata are not yet surfaced.
- CellWorx `.htd` plate files delegated through matching Deltavision `.pnl` planes and reported as `cellworx`; full HCS multi-series assembly, field mapping beyond the first selected field, log files, and OME plate metadata are not yet surfaced.
- Columbus `MeasurementIndex.ColumbusIDX.xml` datasets delegated through recursively discovered neighboring TIFF planes and reported as `columbus`; full HCS plate/well/field mapping, missing-plane fill, acquisition metadata, and OME plate metadata are not yet surfaced.
- Yokogawa CV7000 `.wpi`/`MeasurementData.mlf` datasets delegated through the TIFF plane paths listed in measurement records and reported as `cv7000`; HCS plate/well/field multi-series mapping, duplicate-plane fill behavior, companion `.mrf/.mes/.ppf` metadata, and physical/acquisition metadata are not yet surfaced.
- Bruker MRI datasets opened from `acqp`, `fid`, `reco`, or `2dseq`, with dimensions and pixel type parsed from `acqp`/`pdata/1/reco` and uncompressed planes read from `pdata/1/2dseq`; multiple reconstructions/acquisitions, FID reconstruction, timestamps, and medical metadata are not yet handled.
- Hamamatsu DCIMG version 1 files with little-endian mono8/mono16 frames exposed as time planes, including row-order normalization; grouped `.dcimg` Z stacks, version 0 footers, frame footer four-pixel correction, timestamps, and acquisition metadata are not yet handled.
- Deltavision DV/R3D files with fixed headers and uncompressed 8/16/32-bit integer or 32/64-bit floating-point raw planes, including stored Z/W/T sequence mapping and row-order normalization; extended-header metadata, log files, panel/position series splitting, tiling/stage metadata, and objective/channel metadata are not yet handled.
- DICOM files with a `DICM` preamble, or no-preamble implicit VR little-endian datasets, and native explicit VR little-endian, implicit VR little-endian, or explicit VR big-endian pixel data for 8/16-bit grayscale, RGB, and RGBA planes, including planar RGB/RGBA normalization to interleaved output and MONOCHROME1 grayscale inversion; compressed transfer syntaxes, encapsulated fragments, palettes, WSI tiling, and multi-file series grouping are not yet handled.
- ECAT7 files with `MATRIX70v` or `MATRIX72v` headers and big-endian unsigned 16-bit planes, including Bio-Formats' per-frame padding rule; other ECAT7 matrix data types and medical metadata fields are not yet surfaced.
- EPS/PostScript files with declared 8-bit grayscale or RGB raster image data stored as ASCII hex or raw bytes; TIFF previews and vector-only EPS are not yet supported.
- Bio-Formats simulated `.fake` files with filename-derived dimensions, integer/floating pixel types, dimension order, endianness, scale factor, and deterministic generated planes; `.fake.ini`, RGB/indexed/SPW metadata, labels, annotations, ROIs, and pyramids are not yet handled.
- FEI/Philips SEM IMG files with interlaced 8-bit grayscale pixels.
- FEI TIFF files identified by S-FEG, Helios, or Titan private metadata tags, decoded through the TIFF pixel path.
- File pattern `.pattern` files with a literal relative or absolute target path delegated through the existing reader stack; wildcard/range expansion and multi-file stitching are not yet handled.
- FITS primary image HDUs with 8-bit unsigned, 16/32-bit signed integer, and 32/64-bit floating-point pixels, with `NAXIS3` exposed as planes.
- Evotec Flex `.flex` TIFF files identified by private XML tag 65200 and decoded through the TIFF pixel path; `.mea/.res` selection delegates to the first sibling `.flex`, while HCS grouping, XML metadata, intensity factors, and multi-file plate assembly are not yet surfaced.
- FlowSight CIF files identified by first-IFD metadata XML, with the first image IFD exposed as channel planes for FlowSight bitmask and greyscale compression; additional FlowSight image IFDs, channel metadata, masks as separate series, and acquisition metadata are not yet modeled.
- Olympus Fluoview/ABD TIFF files identified by Fluoview or Andor comments and private metadata tags, decoded through the TIFF pixel path; montage/field grouping, timestamps, physical sizes, and hardware metadata parsing are not yet handled.
- Olympus FV1000 OIF datasets are parsed from the `.oif` `ProfileSaveInfo` companion plus neighboring `.pty` files, and OIB compound files are mapped through `OibInfo.txt` streams; both paths delegate pixel reads through TIFF planes as `fv1000`. ROI/LUT metadata, previews, physical calibration, and detailed acquisition metadata are not yet handled.
- Fuji LAS 3000 `.inf`/`.img` pairs with uncompressed unsigned 8/16/32-bit planes; physical calibration, timestamps, and instrument metadata are not yet surfaced.
- Gatan Digital Micrograph DM3/DM4 files with tag-tree dimensions, `DataType`, and contiguous uncompressed data arrays; montage splitting, ROI overlays, physical sizes, timestamps, microscope metadata, and compressed/packed variants are not yet handled.
- Gatan DM2 files with fixed headers and contiguous big-endian integer pixels; footer tag metadata, physical sizes, and timestamps are not yet handled.
- Amersham Biosciences GEL TIFF files identified by Molecular Dynamics private tags, decoded through the TIFF pixel path for single-IFD linear files; square-root scaled GEL images and two-IFD merge variants are rejected as unsupported.
- GIF87a/GIF89a indexed color images exposed as planes, with global or local palettes, image descriptor offsets on the logical canvas, interlaced row reordering, Graphic Control transparency, and LZW image data, returned as RGB/RGBA.
- Hamamatsu VMS `.vms` datasets with INI metadata and level-0 JPEG tile stitching for requested regions; macro/map series, physical sizes, objective metadata, optimisation-file restart offsets, and multi-layer focal planes are not yet handled.
- Hamamatsu HIS single-series files with little-endian 8/16-bit grayscale or RGB planes; packed 12-bit and multi-series HIS files are not yet supported.
- Hitachi S-4800 `.txt` sidecars with neighboring TIFF/BMP/JPEG pixel files delegated through the existing image readers.
- NOAA-HRD Gridded Data Format surface wind component tables exposed as two big-endian 64-bit floating-point channel planes.
- I2I int16 and 32-bit floating-point volumes with little/big endian data and optional extra time-like dimension exposed as planes.
- Imacon `.fff` TIFF files identified by Imacon XML private metadata tags, decoded through the TIFF pixel path.
- Image Cytometry Standard `.ics`/`.ids` v1 pairs, including EOF-terminated v1 headers, and inline v2 `.ics` files with uncompressed scalar integer or floating-point planes; gzip compression, lifetime/RGB reordering, and full instrument metadata mapping are not yet handled.
- IMAGIC `.hed`/`.img` pairs with 8-bit packed, 16-bit integer, and 32-bit floating-point planes exposed as Z slices; path-based JSON-RPC requests can open either companion file, while inline header data is metadata-only.
- PerkinElmer Nuance IM3 files with nested `DataSet` records, `Shape` dimensions, and interleaved little-endian uint16 spectral channels exposed as planes; spectral library metadata, wavelength names, and alternate record variants are not yet handled.
- InCell 1000/2000 `.xdce`/`.xml` companion datasets delegated through referenced or synthesized TIFF plane names and reported as `incell`; raw `.im` planes, full HCS plate/well/field multi-series mapping, duplicated missing planes, and acquisition metadata are not yet surfaced.
- InCell 3000 `.frm` files with little-endian 16-bit planes expanded from Bio-Formats' packed delta runs; acquisition timestamps and auxiliary metadata are not yet surfaced.
- Inveon text `.hdr` datasets with companion raw image data, signed integer and 32-bit floating-point pixel types, Z/T planes, explicit data offsets, and path-based JSON-RPC requests that can open either the header or data file; multiple bed-position series, renamed-file discovery, and medical metadata expansion are not yet handled.
- Bitplane Imaris raw `.ims` files with big-endian fixed headers and uncompressed 8-bit grayscale Z/C planes; metadata, physical sizes, timestamps, detector/channel settings, and newer Imaris TIFF variants are not yet handled.
- Bitplane Imaris HDF `.ims` files are detected from the HDF5 signature and parsed as `imarishdf` from compact Imaris attributes such as `ImageSizeX/Y/Z`, `FileTimePoints`, and channel labels, with rank-3 contiguous uncompressed `ZYX` datasets exposed as scalar planes in time/channel order; HDF5 group path traversal, pixel type detection beyond the current uint8 default, LZ4/zlib/deflate decompression, multiresolution series, physical sizes, and timestamps are not yet implemented.
- Bitplane Imaris 3 TIFF `.ims` files delegated through the TIFF pixel path and reported as `imaristiff`; thumbnail/stack IFD reshaping, channel metadata, dates, and wavelengths are not yet modeled.
- IMOD `.mod` model files identified by `IMODV1.2`, exposing blank RGB planes with parsed model dimensions to match Bio-Formats' disabled point-rendering path; ROI/model object metadata and contour drawing are not yet surfaced.
- Improvision TIFF files identified by Improvision image descriptions, decoded through the TIFF pixel path; multi-file grouping and Improvision axis metadata interpretation are not yet handled.
- LaVision Imspector `.msr` files with first-block uncompressed little-endian uint16 Z/T planes; FLIM lifetime metadata, multi-block PMT/channel grouping, mosaic tiles, and extended acquisition metadata are not yet surfaced.
- INR raw fixed-size images with 8/16/32-bit signed or unsigned integer samples; `ZDIM` and `VDIM` are exposed as plane axes.
- Ionpath MIBI TIFF files identified by IonpathMIBI software tags, decoded through the TIFF pixel path; SIMS series grouping and channel metadata parsing are not yet handled.
- IPLab files with 8/16/32-bit integer and 32/64-bit floating-point raw planes; Z/T images are exposed as planes.
- Image-Pro Workspace `.ipw` OLE containers with regular FAT `ImageTIFF` streams decoded through the TIFF pixel path; mini-stream embedded TIFFs and non-TIFF workspace objects are not yet handled.
- Molecular Devices JDCE `.jdce` datasets delegated through CSV-listed TIFF planes and reported as `jdce`; full HCS plate/well/field metadata, plane timing/positions, wavelengths, and multi-series mapping are not yet surfaced.
- IVision `.ipm` files with big-endian inline 8/16/32-bit scalar pixels plus padded RGB8 and RGB16 planes; 16-bit color compaction, square-root encoding, XML metadata, LUT extraction, and acquisition metadata are not yet handled.
- JEOL `MG`/`IM` single-file images with little-endian metadata and 8-bit grayscale pixels; companion `.par` metadata grouping is not yet handled.
- JPEG files are detected from SOI/SOF markers, with 8-bit baseline Huffman grayscale and YCbCr/RGB planes decoded as `jpeg`; progressive/arithmetic JPEG, EXIF orientation/color metadata, CMYK/YCCK handling, and restart-interval edge cases are not yet implemented.
- Tile JPEG path requests reuse the JPEG baseline decoder and report decoded pixels as `tilejpeg`; TurboJPEG acceleration, progressive/arithmetic JPEG, CMYK/YCCK, and advanced tile metadata are not yet implemented.
- JPEG-2000 raw codestreams and JP2 boxed files are detected from SOC/SIZ or JP2 `ihdr` headers and decoded through OpenJPEG when an OpenJPEG/vcpkg installation is available at build time; JPX multi-codestream/timepoint handling, lookup tables, comments, and resolution pyramids are not yet implemented.
- JPX `.jpx` path requests reuse the JPEG-2000 parser and OpenJPEG decode path; multiple codestream/timepoint offsets are not yet implemented.
- JPK Instruments `.jpk` TIFF files delegated through the TIFF pixel path and reported as `jpk`; multi-series JPK TIFF splitting and private tag metadata are not yet modeled.
- Khoros XV raw rasters with 8/16-bit grayscale or RGB samples and 8-bit indexed LUT images expanded to RGB.
- KLB single-file volumes with uncompressed single-block 8/16/32-bit integer or 32/64-bit floating-point scalar pixels, exposing Z slices as planes; block tiling, bzip2/zlib compression, grouped time/channel folders, projections, and physical-size metadata are not yet handled.
- Kodak Molecular Imaging BIP files with big-endian 32-bit floating-point grayscale planes.
- Li-Cor L2D `.l2d/.scn` datasets delegated through the first listed TIFF plane and reported as `l2d`; multi-scan/multi-channel assembly, metadata directory crawling, wavelengths, dates, and instrument metadata are not yet handled.
- Leica TIFF files identified by the Leica private TIFF tag and delegated through the TIFF pixel path; full `.lei` companion metadata parsing, raw companion planes, timestamps, and Leica-specific instrument metadata are not yet handled.
- LEO TIFF files with private LEO metadata tags, decoded through the TIFF pixel path.
- Leica SCN TIFF files identified by Leica SCN XML in the TIFF image description, decoded through the TIFF pixel path; SCN XML dimension mapping, supplemental images, subresolution hierarchy, and Leica acquisition metadata are not yet handled.
- Leica LIF files are detected from the LAS AF memory/XML header and decoded from the first uncompressed memory block for scalar integer/floating-point planes, including simple row padding, BGR-to-RGB correction for RGB samples, and Bio-Formats-style default first-series core metadata with LIF image count exposed as `seriesCount`; memory-block ID remapping, per-series metadata selection, tiled fields, physical sizes, LUTs, ROIs, timestamps, and instrument metadata are not yet implemented.
- LI-FLIM `.fli` files with embedded version 1/2 headers, uncompressed or gzip-compressed 8/16/32-bit integer or 32/64-bit floating-point little-endian planes, Bio-Formats v2 camera pixel-format names, and uncompressed packed 12-bit data expanded to uint16; background/dark image series, ROI overlays, timestamps, and exposure metadata are not yet handled.
- Laboratory Imaging LIM uncompressed files with 8/16/32-bit grayscale or BGR/RGB planes; compressed LIM is not yet supported.
- Leica LOF files are detected from the `LMS_Object_File` header and decoded from uncompressed raw memory blocks for scalar integer/floating-point planes, including simple row padding from LASX dimension strides; tiled coordinate remapping, BGR correction, LUTs, physical sizes, ROIs, timestamps, and instrument metadata are not yet implemented.
- Metamorph STK/TIFF files identified by Metamorph software strings or UIC private tags, decoded through the TIFF pixel path; `.nd/.scan` grouping and UIC metadata interpretation are not yet handled.
- MetaXpress `.htd` plate files delegated through matching neighboring TIFF planes and reported as `metaxpress`; full CellWorx-style HCS series assembly, well metadata, log files, thumbnails, and directory fallbacks beyond the first selected well are not yet handled.
- MIAS TIFF files identified by eaZYX, SCIL_Image, or IDL software tags, decoded through the TIFF pixel path; plate/well grouping, tile stitching, masks, overlays, and analysis-result metadata are not yet handled.
- Micro-Manager 1.x-style `metadata.txt` datasets delegated through neighboring TIFF planes and reported as `micromanager`; multi-position series separation, acquisition XML metadata, display colors, physical sizes, and full per-plane metadata maps are not yet surfaced.
- MicroCT VFF files with inline `ncaa` headers and signed 8/16/32-bit raw planes, including row-order normalization; directory file-pattern grouping, XML side metadata, dates, exposure time, and physical size metadata are not yet surfaced.
- Mikroscan TIFF files identified by Mikroscan image descriptions, decoded through the TIFF pixel path; SVS-style subresolution/label/macro series mapping and Mikroscan-specific metadata parsing are not yet handled.
- MINC MRI v1 classic NetCDF `.mnc` files with 8/16/32-bit integer and 32/64-bit floating-point scalar planes; MINC2/HDF5, per-slice scaling, spatial coordinate metadata, and medical metadata expansion are not yet handled.
- Molecular Imaging STP files with inline metadata and little-endian 16-bit grayscale planes.
- Minolta MRW files with PRD/WBG metadata blocks, 12/16-bit Bayer pixels, white-balance scaling, and linear interpolation into RGB16 planes; embedded TIFF/EXIF metadata blocks are not yet surfaced.
- MNG files identified by the MNG signature and `MHDR` chunk, with the first embedded PNG image decoded through the PNG reader; JNG chunks, multiple frames/series, loops, and animation timing are not yet handled.
- PNG 1/2/4/8-bit grayscale/indexed color, 8/16-bit grayscale and grayscale-alpha/RGB/RGBA, optional tRNS transparency, standard scanline filters, and Adam7 interlace.
- MRC microscopy volumes with 8-bit unsigned, 16-bit signed/unsigned, 32-bit floating-point, and RGB byte modes; Z slices are exposed as planes and row order is normalized to top-down output.
- Hamamatsu Aquacosmos NAF files with first-series uncompressed 8/16/32-bit integer or 64-bit floating-point planes exposed in `XYCZT` order; compressed data, additional series, LUT handling, and acquisition metadata are not yet surfaced.
- Hamamatsu NDPI TIFF files identified by Hamamatsu private NDPI tags, decoded through the TIFF pixel path for TIFF-readable planes; JPEG tile acceleration, high-byte offset tags, pyramid/label/macro series mapping, and NDPI metadata expansion are not yet handled.
- Hamamatsu NDPIS `.ndpis` sidecars that list neighboring `.ndpi` files, delegated through the first referenced NDPI image; multi-NDPI channel merging, emission wavelengths, and shading metadata are not yet modeled.
- NIfTI single-file `.nii` images with inline 8/16/32-bit integer and 32/64-bit floating-point planes, plus RGB/RGBA byte samples; `.hdr/.img` pairs and `.nii.gz` are not yet handled.
- Nikon ND2 files are detected from Nikon magic bytes and common embedded XML/text metadata keys are parsed as `nd2`, with simple ordered raw `ImageDataSeq|...!` scalar payloads or v3 tail/file-map `ImageDataSeq|...!` offsets exposed as planes when payload lengths match the parsed dimensions, including Bio-Formats-style one-indexed image sequences, zlib/lossless chunk-map payloads, and 4-byte padded scanlines. ImageAttributesLV, ImageMetadataLV/SLxExperiment loop counts, series raster mapping, acquisition timestamp counts, and stage-position array counts are parsed, including CustomData counts referenced only from the path file map; JPEG-2000 pixel decoding, per-plane stage/time value exposure, ROIs, LUTs, and full Nikon metadata are not yet implemented.
- Nikon NEF/TIFF files identified by TIFF-EP tags or Nikon Make tags, decoded through the TIFF pixel path when the stored image is directly TIFF-readable; Nikon compressed RAW decompression, maker-note metadata, CFA/white-balance expansion, and NEF subIFD handling are not yet handled.
- Nikon Elements TIFF files identified by Nikon XML private metadata tags, decoded through the TIFF pixel path.
- Nikon EZ-C1 TIFF files identified by Nikon software tags, decoded through the TIFF pixel path; Nikon microscope metadata parsing for objectives, lasers, filters, wavelengths, and physical sizes is not yet handled.
- NRRD attached raw single-file images and detached `.nhdr`/raw companion pairs with 2D/3D scalar raster data plus 4D leading vector axes exposed as samples per pixel; `sizes` third/fourth axes are exposed as planes, while gzip/bzip2 encodings and richer medical metadata are not yet handled.
- Imspector OBF/MSR files with uncompressed contiguous stacks and scalar integer or floating-point planes; compressed/chunked stacks, footer labels, embedded OME-XML, and multi-series metadata mapping are not yet handled.
- Olympus OIR files are detected from `OLYMPUSRAWFORMAT`, interspersed XML blocks provide dimensions with disabled axes ignored, and raw pixel blocks are assembled into scalar planes using pixel-block channel IDs for Bio-Formats-style channel counts; tiled plane assembly, external `.oir` companion chunks, LUTs, physical sizes, timestamps, and instrument metadata are not yet surfaced.
- Olympus `.omp2info` tile datasets are parsed from MATL XML and stitched from referenced `.vsi` tiles when those tiles are TIFF-readable through the `cellsens` reader; `.oir` tile pixels, overlap/physical-size correction, multi-resolution metadata, acquisition metadata, and non-cellSens tile formats are not yet handled.
- OME-XML files with inline uncompressed or zlib-compressed base64 `BinData` for integer and floating-point pixel types, including namespaced `Pixels`/`BinData` elements, per-`BinData` endian overrides, and `Channel SamplesPerPixel` plane byte sizing, plus blank planes when no `BinData` is stored; bzip2/JPEG/JPEG-2000 BinData, multi-image documents, OME-TIFF companion files, and full OME metadata mapping are not yet handled.
- OME-TIFF files identified by OME-XML in the first IFD image description, decoded through the TIFF pixel path; OME plane-to-IFD mapping, multi-file OME-TIFF datasets, companion-only metadata files, and full OME metadata mapping are not yet handled.
- PerkinElmer Operetta TIFF files identified by Harmony/Operetta XML private tags, decoded through the TIFF pixel path; Index XML directory grouping, HCS plate/well/field mapping, channel metadata, and acquisition metadata are not yet handled.
- Openlab LIFF files are detected from the `impr` header and v2/v5 image tags, with v2 uncompressed raw grayscale, uint16, and RGB planes decoded; PICT, palette expansion, bit-packed grayscale, v5 LZO-compressed planes, and richer metadata are not yet implemented.
- Openlab RAW files with fixed per-image records, 8/16-bit grayscale, and RGB byte planes.
- Oxford Instruments TOP files identified by fixed headers, with little-endian 16-bit pixels read after the LUT block; descriptive metadata strings, acquisition timestamps, and physical calibration are not yet surfaced.
- PCX 8-bit grayscale, 256-color palette, and three-plane RGB files with PCX RLE compression, returned as grayscale or RGB.
- Compix Simple-PCI `.cxd` OLE containers with embedded TIFF image streams delegated through TIFF or simple raw `Data`/`Bitmap` streams decoded from `Image_Width`, `Image_Height`, `Image_Depth`, and `Field Count`; hierarchical duplicate stream names, timestamps, calibration metadata, Z grouping, and tiled TIFF details are not yet handled.
- Apple PICT files are detected from the classic 512-byte header plus PICT v1/v2 frame rectangle, with uncompressed PICT v1 1-bit `BitsRect`/`PackBitsRect` bitmap planes expanded to uint8 samples; general opcode rendering, PackBits-compressed rows, JPEG embedded image decoding, palettes, comments, and PICT v2 pixel reads are not yet implemented.
- PCO-RAW `.pcoraw` TIFF datasets with optional neighboring `.rec` metadata sidecar, delegated through the TIFF pixel path; `.rec` exposure metadata and >4 GiB offset repair are not yet surfaced.
- Perkin Elmer Densitometer `.hdr`/`.img` pairs with little-endian 16-bit grayscale planes, fixed-record row padding, and stored-axis reversal; RGB/LUT variants and acquisition metadata are not yet surfaced.
- PerkinElmer `.htm` datasets delegated through neighboring TIFF planes and reported as `perkinelmer`; numbered raw pixel files, companion `.tim/.csv/.zpo` metadata expansion, timestamps, wavelengths, and physical sizes are not yet surfaced.
- Photoshop TIFF files identified by image source data private tags, with the merged TIFF image decoded; Photoshop layer extraction is not yet handled.
- PicoQuant BIN FLIM files with little-endian 32-bit unsigned lifetime bins exposed as time planes.
- Photoshop PSD files with uncompressed merged 8/16-bit grayscale, 8/16-bit RGB, and 8-bit indexed-color pixels; PackBits-compressed PSD pixels, layer extraction, CMYK/Lab/multichannel modes, and vector data are not yet handled.
- POV-Ray DF3 volumes with 8/16/32-bit big-endian unsigned samples; Z slices are exposed as planes.
- Prairie TIFF files identified by Prairie software and private TIFF tags, decoded through the TIFF pixel path; companion `.xml/.cfg/.env` grouping, channel/sequence metadata, time points, and physical calibration are not yet handled.
- Pyramid TIFF files identified by Faas software tags, decoded through the TIFF pixel path; pyramid resolution metadata is not yet modeled as series.
- QuickTime `.mov`/`.qt` files are detected from MOV atoms, parsed from `tkhd`/`stsd`/`stsz`/`stco`, and decoded for uncompressed `raw ` 24-bit RGB and 32-bit ARGB frames; RLE, RPZA, MJPB, JPEG, resource-fork variants, timing metadata, and complex chunk/sample tables are not yet implemented.
- Quesant AFM files with square little-endian 16-bit grayscale planes.
- RCPNL `.rcpnl` DeltaVision variant files decoded through the DeltaVision pixel path and reported as `rcpnl`; position/timepoint metadata and Nikon objective mappings are not yet surfaced.
- RHK Technologies SPM files with 8-bit unsigned, 16/32-bit signed integer, and 32-bit floating-point scalar planes, including text-header axis flips.
- SBIG astronomy images with little-endian 16-bit grayscale pixels and SBIG row compression.
- Olympus ScanR TIFF files identified by National Instruments IMAQ software tags, decoded through the TIFF pixel path; `experiment_descriptor.xml`/`.dat` grouping, HCS plate/well/field mapping, channel metadata, exposure times, and stage positions are not yet handled.
- Becker & Hickl SPCImage SDT files with uncompressed uint16 FLIM blocks exposed as lifetime/time planes; ZIP-compressed blocks, intensity projection mode, multiple data-block series, and full measurement metadata are not yet handled.
- Seiko `.xqd/.xqf` files with fixed-header little-endian 16-bit grayscale planes.
- Image-Pro Sequence TIFF files identified by Image-Pro private array tags, decoded through the TIFF pixel path with multi-IFD stacks exposed as Z planes; `.ips` grouping files, channel names, and multi-file Z/T/position expansion are not yet handled.
- Andor SIF files with little-endian 32-bit floating-point image planes.
- SimplePCI TIFF files identified by Hamamatsu SimplePCI image descriptions, decoded through the TIFF pixel path; channel splitting from SimplePCI metadata is not yet handled.
- Olympus SIS TIFF files identified by SIS private tags with analySIS/Olympus metadata, decoded through the TIFF pixel path with SIS INI Z/C/T dimension reshaping; SIS-specific physical size and channel metadata parsing are not yet handled.
- Legacy SlideBook `.sld/.spl` files are detected from native endian/magic headers and fixed-size `i`/`u` metadata blocks, with contiguous uint16 raw plane blocks read when the block length matches the parsed dimensions; broader raw pixel block discovery, spool metadata, SlideBook 7 `.sldy/.sldyz`, YAML metadata, Zstd/Numpy planes, annotations, positions, and channel names are not yet implemented.
- SlideBook 7 `.sldy/.sldyz` datasets resolve the companion `.dir/* .imgdir/ImageRecord.yaml` and read uncompressed little-endian `.npy` `ImageData_Ch*_TP*.npy` planes for the first image group; multi-capture selection beyond the first image group, `.npyz`/Zstd decompression, masks, annotations, stage positions, and channel/lens metadata are not yet implemented.
- Slidebook TIFF files identified by SlideBook software and private stage/channel metadata tags, decoded through the TIFF pixel path; multi-file grouping, channel naming, stage positions, and physical size metadata parsing are not yet handled.
- Becker & Hickl SPC FIFO `.set/.spc` pairs with pixel, line, frame, channel, and lifetime-bin events expanded to little-endian uint16 FLIM planes; setup metadata beyond TAC timing, macro-time semantics, and system-specific line-mode details are not yet surfaced.
- SPIDER EM images/stacks with 32-bit floating-point planes and little/big endian header detection.
- Princeton Instruments SPE files with 16/32-bit integer and 32-bit floating-point raw frames exposed as time planes, including Bio-Formats' legacy stack-size fallback when the frame-count field is empty.
- SM Camera fixed-header 8-bit grayscale images.
- Aperio SVS TIFF files identified by Aperio image descriptions and multiple IFDs, decoded through the TIFF pixel path; SVS label/macro/subresolution series mapping and metadata extraction are not yet handled.
- Leica TCS TIFF files identified by `CHANNEL` document names or `TCS` software tags, decoded through the TIFF pixel path; companion XML, multi-file grouping, timestamps, physical sizes, exposure times, and Leica XML metadata are not yet handled.
- Tecan Spark Cyto workspaces opened from `.db` files by locating the associated `Images` directory, or from TIFFs under `Images` when a nearby `.db` is present, and decoded through the TIFF pixel path; SQLite plate/well/channel metadata, time/field mapping, results/overlays, and spreadsheet/export metadata are not yet surfaced.
- TGA uncompressed and RLE 8/16-bit color-mapped with 15/16/24/32-bit palettes, 8-bit grayscale, 16-bit grayscale/alpha, 15/16/24-bit truecolor, and 16/32-bit truecolor/alpha files, including truecolor/grayscale files with unused color maps.
- Text/CSV tables with `x` and `y` coordinate columns plus one or more numeric value columns exposed as big-endian 32-bit floating-point channel planes.
- TissueFAXS `.tfcyto` SQLite databases, or `.aqproj` projects resolved to the first `Slide */*.tfcyto` database, are parsed from `region`, `fovs`, `images`, and `channels` tables, with level-0 raw/passthrough tile blobs stitched for scalar no-overlap regions; JPEG/JPEG-XR tiles, overlapping stitch correction, TMA subregions, correction images, pyramid resolutions, physical calibration, and full OME metadata are not yet implemented.
- TillVision raw `.pst/.inf` pairs with dimensions and datatype parsed from `[Info]`, exposed as little-endian scalar planes; embedded OLE `.vws`, acquisition metadata, image names, dates, and exposure timing are not yet surfaced.
- TIFF/BigTIFF baseline 1/2/4-bit packed and 8/16/32-bit grayscale, RGB (`rgb8`/`rgb16`), RGBA (`rgba8`/`rgba16`, including four-sample RGB files that omit `ExtraSamples`), 1/2/4/8-bit palette color, signed integer grayscale, 32/64-bit float grayscale strips and tiles, single-strip baseline JPEG-compressed RGB/YCbCr preview images, and regional baseline JPEG-compressed RGB/YCbCr tiles. Uncompressed, PackBits, LZW, and Deflate compression are supported for scalar/RGB/RGBA strips and tiles, including horizontal differencing Predictor=2 for 8/16-bit integer samples. BlackIsZero and WhiteIsZero grayscale, FillOrder 1/2 for packed low-bit samples, chunky RGB/RGBA, color-map expansion to RGB, separated planar RGB/RGBA strips and tiles, and ImageJ `channels`/`slices`/`frames` hyperstack dimensions are supported.
- TopoMetrix `.tfr/.ffr/.zfr/.zfp/.2fl` files with little-endian 16-bit grayscale planes.
- Trestle TIFF files identified by Trestle copyright tags, decoded through the TIFF pixel path; companion `.sld/.slx/.ROI` grouping, overlap handling, and ROI metadata are not yet handled.
- UBM `.pr3` files with little-endian 32-bit unsigned grayscale planes and per-row padding.
- Unisoku STM `.HDR`/`.DAT` pairs with text headers and little-endian scalar pixel data; path-based JSON-RPC requests can open either companion file, while inline header data is metadata-only.
- Varian FDF single-file images with 8/16/32-bit unsigned and 32-bit floating-point raw planes; rows are normalized to top-down output. Directory-based multifile FDF grouping is not yet handled.
- PerkinElmer Vectra/QPTIFF files identified by QPI software tags, decoded through the TIFF pixel path; profile XML, annotation companion files, subresolution modeling, and Vectra channel metadata parsing are not yet handled.
- Veeco AFM classic NetCDF `.hdf` files with a first 2D 8-bit or 16-bit signed image variable; HDF5/HDF4 variants, additional variables, attributes, calibration, and AFM metadata expansion are not yet handled.
- Ventana BIF TIFF files identified by iScan XML private metadata, decoded through the TIFF pixel path; tile stitching, split-tile mode, subresolution mapping, and Ventana XML metadata extraction are not yet handled.
- Volocity `.mvd2` libraries are supported for the external `Data/*.aisf` stack subset by resolving the first AISF stack and reusing the raw Volocity stack path; Metakit table parsing, multi-stack/channel association, timestamps, LZO clipping streams, and embedded streams are not yet implemented.
- Visitech XYS datasets with HTML report-derived dimensions and raw `.xys` companion pixels; multi-position splitting, per-plane padding heuristics, acquisition metadata, and physical sizes are not yet handled.
- VG SAM DTI files with big-endian 8/16-bit unsigned or 32-bit floating-point grayscale planes.
- Volocity Library Clipping `.acff` files with inline uncompressed 8-bit planes; LZO-compressed clipping payloads are not yet handled.
- WA Technology TOP `.wat` files with fixed-header little-endian signed 16-bit grayscale planes.
- Leica XLEF projects that reference XLIF metadata and TIFF/JPEG/PNG/BMP frame files, including namespaced `Reference`/`Frame` XML elements, delegated through the first readable frame with Bio-Formats-style `XYCZT` order; LOF, multi-image/tile assembly, stage metadata, and Leica-specific metadata translation are not yet handled.
- Zeiss CZI files are detected from `ZISRAWFILE` segments, subblock directory entries provide dimensions and pixel type, `S` scene dimensions are exposed as series, raw `ZISRAWMETADATA` XML is exposed as `imageDescription`, full-size uncompressed scalar/BGR/RGBA subblock planes are read, and uint8/RGB8 JPEG-compressed, LZW-compressed, ZSTD-0/ZSTD-1-compressed, or camera-packed 12-bit full-size subblocks and tiles are decoded by path/range using C/Z/T/series subblock coordinates; pyramid subblocks are filtered from base-plane metadata/reads, but exposing pyramid resolutions, JPEG-XR compressed payloads, attachments, translated XML metadata, and mosaics is not yet implemented.
- Zeiss LMS files identified by the LMSFLE marker, with CSM 700 fixed-size little-endian 16-bit Z planes read after the thumbnail and LUT blocks; the thumbnail series, palette LUT, objective magnification, and other instrument metadata are not yet surfaced.
- Zeiss LSM TIFF files identified by the private `TIF_CZ_LSMINFO` tag, decoded through the TIFF pixel path with paired thumbnail IFDs skipped, multi-sample planes split into channel planes, and basic Z/C/T dimensions and scan-type dimension order parsed from the LSM info block; channel names/colors, LUTs, timestamps, ROIs, and MDB multi-file grouping are not yet parsed.
- Zeiss AxioVision TIFF datasets with `_meta.xml` companion detection, delegated through the matching TIFF pixel path; XML tag metadata, multifile plane grouping, ROIs, and acquisition metadata are not yet handled.
- Zeiss XRM `.txm/.txrm` OLE containers with `ImageWidth`, `ImageHeight`, `DataType`, and `ImageN` streams decoded as vertically flipped raw planes; acquisition metadata, reference data, reconstruction metadata, multi-channel/time layouts, and compressed or non-standard stream variants are not yet handled.
- Zeiss ZVI files are detected from OLE/CFB image streams and decoded from uncompressed contiguous AxioVision `CONTENTS` streams, including BGR-to-RGB channel correction; POI stream metadata, JPEG/zlib decompression, tiled/ROI metadata, and full coordinate remapping are not yet implemented.
- ZIP archives are delegated to the first stored or deflated local-file AIM, Alicona, Amersham GEL TIFF, Amira/Avizo, APNG, ARF, AVI, BD Pathway TIFF, Becker & Hickl SDT, Bio-Rad GEL, Bio-Rad PIC, Bio-Rad SCN, BMP, Burleigh SPM, Canon DNG TIFF, Canon RAW, Cellomics C01/DIB, DCIMG, Deltavision DV/R3D, DICOM, ECAT7, EPS/PostScript, FEI TIFF, FEI/Philips SEM IMG, FITS, FlowSight CIF, Fluoview TIFF, Gatan DM2, Gatan DM3/DM4, GIF, Hamamatsu Aquacosmos NAF, Hamamatsu HIS, Hamamatsu NDPI TIFF, HRD GDF, I2I, Imacon TIFF, InCell 3000, Image-Pro SEQ, Image-Pro Workspace, Imaris raw, IMOD, Improvision TIFF, INR, Ionpath MIBI TIFF, IPLab, IVision, JEOL MG/IM, Khoros XV, KLB, Kodak BIP, Laboratory Imaging LIM, Leica SCN TIFF, Leica TCS TIFF, LEO TIFF, LI-FLIM, MetaMorph TIFF, MIAS TIFF, MicroCT VFF, Mikroscan TIFF, MINC MRI, Minolta MRW, MNG, Molecular Imaging, MRC, Netpbm, NIfTI, Nikon Elements TIFF, Nikon NEF/TIFF, Nikon TIFF, NRRD, Olympus ScanR TIFF, OME-XML, OME-TIFF, Openlab RAW, Oxford Instruments TOP, PCX, PerkinElmer Nuance IM3, PerkinElmer Operetta TIFF, Photoshop TIFF, PicoQuant BIN, PNG, POV-Ray DF3, Prairie TIFF, PSD, Pyramid TIFF, Quesant AFM, RHK SPM, SBIG, Seiko, SIF, SimplePCI TIFF, SIS TIFF, SlideBook TIFF, SM Camera, SPE, SPIDER, SVS TIFF, Text/CSV, TGA, TopoMetrix, Trestle, UBM, Varian FDF, Vectra/QPTIFF, Veeco AFM NetCDF, Ventana BIF, VG SAM, Volocity Clipping, WA Technology TOP, Zeiss LMS, Zeiss LSM, or baseline TIFF entry; encrypted/data-descriptor ZIP entries, central-directory-only archives, other inner formats, and multi-file dataset grouping inside ZIPs are not yet handled.

Bio-Formats Java reader-name aliases currently advertised by `formats` include
`bd`, `ionpathmibitiff`, `metamorphtiff`, `metaxpresstiff`,
`mikroscantiff`, `nikonelementstiff`, `pgm`, `simplepcitiff`, and `targa`.

This is not a complete Bio-Formats replacement yet. The repository now has the
embedding boundary and reader shape needed to port additional `FormatReader`
implementations from `../bioformats`.
