# Fixture Sources

This directory tracks public fixture sources for exercising the
`bioformats-zig` JSON-RPC binary against real files. Fixtures are not vendored
because many microscopy datasets are large or have redistribution limits.

## Upstream Sources

- Bio-Formats documentation says public example files that OME can redistribute
  are hosted at `https://downloads.openmicroscopy.org/images/`.
- The Bio-Formats contributor guide asks contributors to submit new test data
  through Zenodo when files can be public.
- The checked-out `../bioformats` source tree does not include the actual public
  test image corpus; it only includes source and a small logo PNG.
- For Openlab LIFF/RAW specifically, Bio-Formats documentation says OME has
  datasets internally, but the public OME image index has no Openlab directory
  and the 2026-05-05 Zenodo/web search did not turn up a small public download.

## Workflow

1. Prefer the OME sample image download directory listed in `sources.json`.
2. If no OME fixture exists, use small generated fixtures for standard formats
   where the repo already has byte-level synthetic tests.
3. For formats that still lack public samples, search Zenodo or vendor/sample
   repositories and add the source URL here before downloading large data.
4. Keep downloaded datasets outside git, for example under `fixtures/cache/`
   ignored by the user, then run the JSON-RPC binary with `metadata`, `probe`,
   and a small `readPlane` region.

`implemented_format_sources` tracks formats currently advertised by
`src/root.zig`. `pending_reader_sources` tracks fixture leads for concrete
Bio-Formats Java readers that still need Zig implementations; do not count
those as supported until a reader is wired into `src/root.zig`.

Example smoke request:

```json
{"jsonrpc":"2.0","id":1,"method":"metadata","params":{"path":"fixtures/cache/example.tif"}}
```
