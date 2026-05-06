# Fixture Sources

This directory tracks public fixture sources for exercising the
`bioformats-zig` JSON-RPC binary against real files. Fixtures are not vendored
because many microscopy datasets are large or have redistribution limits.

## Upstream Sources

- Bio-Formats documentation says public example files that OME can redistribute
  are hosted at `https://downloads.openmicroscopy.org/images/`.
- The Bio-Formats contributor guide asks contributors to submit new test data
  through Zenodo when files can be public.
- OpenSlide publishes whole-slide test data for some Bio-Formats-overlapping
  formats, including Hamamatsu VMS.
- The checked-out `../bioformats` source tree does not include the full public
  test image corpus; it only includes source, OME-XML schema samples, and a
  small logo PNG.
- For Openlab LIFF/RAW specifically, Bio-Formats documentation says OME has
  datasets internally, but the public OME image index has no Openlab directory
  and the 2026-05-05 Zenodo/web search did not turn up a small public download.
- Public probes on 2026-05-06 found that the OME Olympus FluoView `.oib`
  fixture works as an FV1000 pixel smoke test, and the OpenSlide/OME
  Hamamatsu VMS fixture works as a regional JPEG-tile pixel smoke test. OME
  Olympus OIR `.oir` files are useful metadata leads, but currently expose Zig
  reader pixel-read gaps. The Figshare MINC dataset provides small `.mnc.gz`
  downloads, but those are MINC2/HDF5-style files rather than the classic
  NetCDF variant supported by the current Zig MINC reader.

## Verified Pixel Fixtures

These public cached fixtures have been smoke-tested with `probe`, `metadata`,
and a small `readPlane` request against the Zig JSON-RPC binary:

| Format | Public source | Representative file |
| --- | --- | --- |
| amira | `ome_images/AmiraMesh/ignacio/` | `test.am` |
| flex | `ome_images/Flex/idr0007/Plate1/` | `001001000.flex` |
| fv1000 | `ome_images/Olympus-FluoView/imagesc-71616/` | `20220824_4492_cord_dapi__iba568_60x.oib` |
| hamamatsuvms | `ome_images/Hamamatsu-VMS/openslide/CMU-3/` | `CMU-3-40x - 2010-01-12 13.57.09.vms` |
| imaristiff | `ome_images/Imaris-IMS/davemason/` | `Convallaria_3C_10T_confocal_IMS3.ims` |
| jdce | `ome_images/JDCE/molecular-devices/Converted/mini-actin_confocal_CDE/` | `mini-actin_confocal_CDE.JDCE` |
| micromanager | `ome_images/Micro-Manager/1.4.16/serge/Pos0/` | `metadata.txt` |
| ndpi | `ome_images/Hamamatsu-NDPI/manuel/` | `test3-DAPI 2 (387) .ndpi` |
| nd2 | `ome_images/ND2/` | `MeOh_high_fluo_003.nd2` |
| spc | `ome_images/SPC-FIFO/biofisika/` | `conv-256x256.set` |
| zeissczi | `ome_images/Zeiss-CZI/` | `Plate1-Blue-A-02-Scene-1-P2-E1-01.czi` |
| zeisslsm | `zenodo/10.5281/zenodo.14510432` | `10-01.lsm` |

The full local cache may contain additional verified formats depending on what
has been fetched on the machine running the tests; `fixtures/cache/` remains
ignored by git.

## Workflow

1. Prefer the OME sample image download directory listed in `sources.json`.
2. If no OME fixture exists, use small generated fixtures for standard formats
   where the repo already has byte-level synthetic tests.
3. For formats that still lack public samples, search Zenodo or vendor/sample
   repositories and add the source URL here before downloading large data.
4. Keep downloaded datasets outside git, for example under `fixtures/cache/`
   ignored by the user, then run the JSON-RPC binary with `metadata`, `probe`,
   and a small `readPlane` region.

Use the helper script to list known sources or fetch a small public candidate
from the first direct OME/HTTP directory or Zenodo record source:

```powershell
./fixtures/audit.ps1
./fixtures/audit.ps1 -List
./fixtures/fetch.ps1 -List
./fixtures/fetch.ps1 -Format tiff -MaxBytes 52428800
```

After building the binary, run the cached fixtures through JSON-RPC smoke checks:

```powershell
zig build
./fixtures/smoke.ps1
```

`implemented_format_sources` tracks formats currently advertised by
`src/root.zig`. `pending_reader_sources` tracks fixture leads for concrete
Bio-Formats Java readers that still need Zig implementations; do not count
those as supported until a reader is wired into `src/root.zig`.

Example smoke request:

```json
{"jsonrpc":"2.0","id":1,"method":"metadata","params":{"path":"fixtures/cache/example.tif"}}
```
