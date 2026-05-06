# Bio-Formats Alignment Checks

Use this as the working checklist when aligning Zig readers to Java Bio-Formats in `../bioformats`.

## Source Of Truth

- Use the Java reader source in `../bioformats/components/.../src/loci/formats/in/` as the behavioral reference.
- For fixture expectations, probe Java Bio-Formats directly with `bioformats_package.jar` and record exact metadata, plane hashes, and region hashes in Zig tests.
- Prefer cached fixtures under `fixtures/cache/<format>/` when available.

## Required Evidence Per Format

For each priority format in `DATAFORMAT_PRIORITY.md`, add or maintain tests that prove:

1. Positive and negative detection behavior matches Java where practical.
2. Core metadata matches Java: `SizeX`, `SizeY`, `SizeZ`, `SizeC`, `SizeT`, pixel type, RGB/interleaving, endianness, dimension order, series count, and image count.
3. Plane indexing matches Java for Z/C/T/series/position mapping.
4. Pixel bytes match Java for first, middle, and last planes when data is raw or losslessly decoded.
5. Region reads match Java direct-region output, not only a Zig full-plane crop, when the reader has format-specific region logic.
6. Large fixtures are read through path/range APIs rather than whole-file allocation.
7. Fixture names and expected values are committed in tests or a manifest.

## Java Probe Pattern

For each fixture, run a small Java probe against the matching reader:

```java
IFormatReader r = new SomeReader();
r.setId(path);
r.setSeries(series);
System.out.println(r.getSizeX() + "x" + r.getSizeY());
System.out.println("Z=" + r.getSizeZ() + " C=" + r.getSizeC() + " T=" + r.getSizeT());
System.out.println("count=" + r.getImageCount() + " order=" + r.getDimensionOrder());
System.out.println("pixelType=" + FormatTools.getPixelTypeString(r.getPixelType()));
byte[] plane = r.openBytes(planeIndex);
byte[] region = r.openBytes(planeIndex, x, y, w, h);
```

Hash byte arrays with SHA-256 and paste the expected bytes into the Zig test.

## Recent Alignment Notes

- ND2: added proof for Java `ImageMetadataLV` raster mapping across Z/T/position loops.
- CZI: cached fixture now checks Java direct-region hash for plane 31 at `(2, 3, 4, 2)`.
- SDT: mode 13 metadata now follows Java dimensions and series count behavior; compressed block length no longer shrinks `SizeT`.
- SPC: cached fixture hashes use fresh Java reader instances because Java state can affect repeated reads.
- DCIMG: region reads must match Java's requested-region row flip, not a crop from Zig's full-plane orientation.
- LOF: cached fixture has Java metadata and full-plane hash coverage; add direct-region hashes when strengthening region proof.
- CellSens: JPEG-compressed ETS tiles should not use exact region hashes unless the decoder is shared; Bio-Formats and Zig differ by small IDCT rounding deltas. For `Image_V4.1_BF.vsi`, Java direct-region `(0, 0, 16, 16)` is SHA-256 `3cb8575c1bfe8e3c054497ecd857d4a8881f1668485b2bc9e6638829e88753a7`, but the Zig test asserts direct-region size, first-pixel tolerance, and channel/sum ranges tied to that Java probe.

## Verification Gates

Before committing an alignment change:

```powershell
zig fmt <changed files>
zig build test --summary all
zig build
git diff --check
```

`git diff --check` may report the repository's CRLF warning on Windows; treat actual whitespace errors as blockers.
