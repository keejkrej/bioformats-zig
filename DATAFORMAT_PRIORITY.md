# Data Format Priority

This document ranks reader-porting work for Bio-Formats alignment. The ranking is intentionally biased toward formats users are most likely to bring from common microscope vendors, with ND2 and CZI fixed at the top.

## Alignment Proof Standard

A reader is not considered aligned just because it opens one file. For each priority format, implementation work should prove parity against the Java Bio-Formats reader in `../bioformats` with representative fixtures.

Required proof:

1. Format detection matches Bio-Formats for positive and negative fixtures.
2. Core metadata matches: `SizeX`, `SizeY`, `SizeZ`, `SizeC`, `SizeT`, pixel type, RGB/interleaving, endianness, dimension order, series count, and image count.
3. Plane indexing matches Bio-Formats for Z/C/T/series/position mapping.
4. Pixel payload matches for at least first, middle, and last planes where the format stores raw or losslessly decoded data.
5. Region reads match full-plane crop results.
6. Large files are read by path/range, not by whole-file allocation.
7. The proof fixture names and expected metadata are recorded in tests or a fixture manifest.

## Priority Ranking

| Priority | Format family | Main extensions | Brand / ecosystem | Why it ranks here | Alignment focus |
| --- | --- | --- | --- | --- | --- |
| P0 | Nikon NIS-Elements ND2 | `.nd2` | Nikon | Top user priority and common live-cell/confocal acquisition format. | Chunk map, `ImageMetadataLV`, `SLxExperiment`, positions/series, Z/C/T loops, `CustomData` stage/time arrays, compression variants. |
| P0 | Zeiss CZI | `.czi` | Zeiss | Top user priority and common multidimensional microscopy container. | Subblocks, scenes/series, pyramids, dimensions, attachments, compression, tiled region reads. |
| P1 | Leica LAS AF LIF / LOF / XLEF | `.lif`, `.lof`, `.xlef` | Leica | Major microscopy vendor family, frequent confocal and widefield data. | Series hierarchy, XML metadata, channels, timestamps, Z/T ordering, companion files. |
| P1 | Olympus / Evident OIR, OIF/OIB, cellSens VSI, and APL | `.oir`, `.oif`, `.oib`, `.vsi`, `.ets`, `.apl` companions | Olympus / Evident | Major microscopy vendor; common in confocal, slide, and cellSens workflows. | Multi-file layout, dimensions, channel metadata, compression, tile/plane ordering. |
| P1 | OME-TIFF and baseline TIFF microscopy variants | `.ome.tif`, `.ome.tiff`, `.tif`, `.tiff` | OME / broad ecosystem | Not a brand format, but it is the interchange baseline and validates shared TIFF infrastructure. | IFD traversal, OME-XML, pyramids, tiled reads, BigTIFF, multi-series and multi-plane indexing. |
| P2 | Zeiss LSM / ZVI / Zeiss TIFF | `.lsm`, `.zvi`, `.tif` | Zeiss | Older Zeiss data remains common in archives. | Legacy metadata blocks, channels, timestamps, Z/T ordering, tiled/striped TIFF variants. |
| P2 | Hamamatsu whole-slide formats | `.ndpi`, `.vms`, `.vmu` | Hamamatsu | Common digital pathology and slide scanner ecosystem. | Pyramids, tiles, huge-file range reads, focal planes, macro/label images. |
| P2 | PerkinElmer / Akoya screening formats | `.flex`, `.mea`, `.res`, `.tif` companions | PerkinElmer / Akoya | Common high-content screening and plate imaging. | Plate/well/field metadata, companion-file discovery, series mapping, channel metadata. |
| P2 | Molecular Devices / MetaMorph / MetaXpress | `.stk`, `.nd`, `.htd`, `.tif`, `.tiff` | Molecular Devices | Common in legacy widefield and screening workflows. | Companion metadata, stage positions, time/Z/channel mapping, TIFF plane ordering. |
| P2 | GE / Cytiva InCell | `.xdce`, `.tif`, `.frm` | GE / Cytiva | High-content screening vendor with plate-based datasets. | Plate/well/field dimensions, companion metadata, multi-file discovery. |
| P3 | Yokogawa CellVoyager / CV7000 | `.mrf`, `.tif`, related companions | Yokogawa | Relevant for high-content confocal screening, less universal than the big four microscope vendors. | Plate layout, field/channel/Z/T indexing, companion metadata. |
| P3 | BD Pathway | `.adf`, `.tif` companions | BD | Screening platform data; lower prevalence than current major vendor formats. | Plate metadata, companion lookup, field/channel indexing. |
| P3 | Imaris / Bitplane | `.ims` | Oxford Instruments / Bitplane | Common analysis/export format, not usually raw acquisition. | HDF5 hierarchy, pyramids, channels, time/Z dimensions. |
| P3 | Bruker / Prairie / Inveon / microCT families | `.xml`, `.tif`, `.mnc`, vendor-specific companions | Bruker and related systems | Important in specific modalities but narrower audience. | Companion metadata, modality-specific axes, tiled/stacked storage. |
| P4 | Camera, generic image, and archive formats | `.avi`, `.png`, `.jpg`, `.jp2`, `.zip`, `.bmp`, etc. | Generic ecosystem | Useful fallback coverage but not the main microscopy alignment risk. | Correct detection, simple metadata, decode parity, ZIP inner-reader dispatch. |
| P4 | Specialized or legacy scientific formats | many | Long-tail instruments and historical tools | Keep supported, but implement after high-frequency vendor formats unless a user fixture requires them. | Match Bio-Formats behavior per fixture, avoid speculative broad rewrites. |

## Current Hot Path

ND2 is the immediate alignment target. The current Zig ND2 reader can detect/read selected path-based ND2 chunk-map data, but it does not yet match Java Bio-Formats for dimension derivation. The next ND2 work should port the Java reader's loop and position logic before expanding pixel-codec coverage:

1. Parse chunk map entries into typed metadata blocks.
2. Parse `ImageAttributesLV` for physical plane shape and pixel type.
3. Parse `ImageMetadataLV` / `SLxExperiment` for loop counts and dimension order.
4. Parse `CustomData|X`, `CustomData|Y`, `CustomData|Z`, `CustomData|Z1`, and acquisition time arrays for position/stage/time metadata.
5. Build series and plane offsets using the same raster mapping as Java Bio-Formats.
6. Add a proof test against the large ND2 fixture metadata before changing UI assumptions.

## Reranking Rule

This file should be reranked when real user data contradicts the heuristic. A format with an active user fixture and a reproducible alignment failure moves above an otherwise popular vendor format until the failure is proven fixed.

## References

- Bio-Formats supported formats and quality/popularity guidance: https://docs.openmicroscopy.org/bio-formats/6.9.0/supported-formats.html
- Zeiss CZI format overview and Bio-Formats compatibility note: https://www.zeiss.com/microscopy/us/products/software/zeiss-zen/czi-image-file-format.html
- Common proprietary microscopy examples including Nikon ND2, Leica LIF, and Zeiss CZI: https://www.jmu.edu/microscopy/resources/microscopyDataManagement2016-05-19.pdf
