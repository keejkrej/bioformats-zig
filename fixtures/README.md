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
| cellomics | `ome_images/Cellomics/BBBC001/` | `AS_09125_050118150001_A03f00d0.DIB` |
| cellsens | `ome_images/CellSens/` | `Image_V4.1_BF.vsi` |
| columbus | `ome_images/PerkinElmer-Columbus/zenodo-6327496/tif/` | `MeasurementIndex.ColumbusIDX.xml` |
| dcimg | `ome_images/DCIMG/` | `bead_bot4__560_00000_00000.dcimg` |
| deltavision | `ome_images/DV/` | `U2OS_AurB_AurA_001_R3D.dv` |
| dicom | `ome_images/DICOM/` | `CR-MONO1-10-chest.dcm` |
| dng | `zenodo/10.5281/zenodo.15933943` | `PXL_20250709_150255952.RAW-02.ORIGINAL.dng` |
| ecat7 | `ome_images/ECAT7/torsten/` | `gradient-512x512x10.v` |
| flex | `ome_images/Flex/idr0007/Plate1/` | `001001000.flex` |
| fv1000 | `ome_images/Olympus-FluoView/imagesc-71616/` | `20220824_4492_cord_dapi__iba568_60x.oib` |
| gatan | `ome_images/Gatan/imagesc-36590/` | `191041a_ctl_M2_3VBSED_0045.dm4` |
| hamamatsuvms | `ome_images/Hamamatsu-VMS/openslide/CMU-3/` | `CMU-3-40x - 2010-01-12 13.57.09.vms` |
| ics | `ome_images/ICS/jan/` | `benchmark_v1_2018_x64y64z5c2s1t11_w1Laser4054BD4BP_5c8bc101d6559_hrm.ics` |
| imaristiff | `ome_images/Imaris-IMS/davemason/` | `Convallaria_3C_10T_confocal_IMS3.ims` |
| incell | `ome_images/InCell2000/zenodo-14777242/` | `Training_Demo_1.xdce` |
| incell3000 | `ome_images/InCell3000/BBBC013/BBBC013_v1_images_frm/` | `20041103 1049_01_REF-1049-03 - EvoTec_0_A10_0.frm` |
| jdce | `ome_images/JDCE/molecular-devices/Converted/mini-actin_confocal_CDE/` | `mini-actin_confocal_CDE.JDCE` |
| leo | `ome_images/LEO/` | `2160grating 1024.tif` |
| lif | `ome_images/Leica-LIF/` | `20191025 Test FRET 585. 423, 426.lif` |
| lof | `ome_images/Leica-XLEF/format test/format test LOF/` | `mono 8bit.lof` |
| metamorph | `ome_images/MetaXpress/idr0005/Primary_001/` | `2011-04-19-plate-1_A01_s1_[A192FCC1-DC1A-4523-97BB-07688327EAC3].tif` |
| metaxpress | `ome_images/MetaXpress/idr0005/Primary_001/` | `2011-04-19-plate-1.HTD` |
| micromanager | `ome_images/Micro-Manager/1.4.16/serge/Pos0/` | `metadata.txt` |
| mrc | `ome_images/MRC/EMDB/EMD-2225/` | `EMD-2225.map` |
| nd2 | `ome_images/ND2/` | `MeOh_high_fluo_003.nd2` |
| ndpi | `ome_images/Hamamatsu-NDPI/manuel/` | `test3-DAPI 2 (387) .ndpi` |
| ndpis | `ome_images/Hamamatsu-NDPI/manuel/` | `test3.ndpis` |
| nifti | `ome_images/NIfTI/` | `avg152T1_LR_nifti.nii` |
| nrrd | `ome_images/NRRD/gordon/` | `dt-helix.nhdr` |
| obf | `ome_images/OBF/ngladitz/v4/` | `test-v4-uncompressed.obf` |
| omexml | `ome_images/OME-XML/2011-06/` | `single-image.ome.xml` |
| ometiff | `ome_images/OME-TIFF/` | `Iron-Plate.ome.tiff` |
| operetta | `ome_images/PerkinElmer-Operetta/omer/006P_M3/006P__2017-08-19T12_42_59-Measurement 3/Images/` | `r01c02f01p01-ch1sk1fk1fl1.tiff` |
| png | `ome_images/PNG/` | `user-1 05 TEST.png` |
| scanr | `ome_images/ScanR/idr0009/0307-10--2007-05-30/data/` | `--W00002--P00001--Z00000--T00000--nucleus-dapi.tif` |
| sdt | `ome_images/SDT/` | `FocalCheck_A1_20x_8xzoom_800nm.sdt` |
| spc | `ome_images/SPC-FIFO/biofisika/` | `conv-256x256.set` |
| tiff | `ome_images/TIFF/` | `A1.pattern1.tif` |
| vectra | `ome_images/Vectra-QPTIFF/perkinelmer/PKI_fields/` | `HandEcompressed_[11004,54205]_2x2component_data.tif` |
| xlef | `ome_images/Leica-XLEF/format test/format test TIF/` | `format-test tif.xlef` |
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
