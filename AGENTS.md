# simd

## Project

This active Zig 0.16.0 scratch and research package began as SIMD experiments.
It now provides a static library for SIMD byte operations, UTF-8 checks,
structural indexes, validated token tapes, on-demand traversal, and streaming
parsers. The build also installs a `simd` executable that visualizes masks over
a fixed JSON sample. It is not a general parser CLI.

Current format modules cover JSON, JSONL, JSONC, JSON5, Markdown, XML, and the
restricted `yaml-basic-1.2.2` profile. There is no root README.
`docs/architecture-stage2-stream.md` mixes current contracts, historical
design records, and future plans. Do not treat a section marked as a future
roadmap as an implemented API.

## Repository map

- `build.zig` defines the static library, visualizer, unit tests, deterministic
  Smith fuzz tests, offline corpus tests, and the `vector_len` option.
- `build.zig.zon` pins Zig 0.16.0 and declares no external package dependency.
- `src/root.zig` is the public module and exports all format adapters.
- `src/core/simd.zig` contains vector, mask, UTF-8, and byte-matching
  primitives.
- `src/core/stage1.zig` owns the shared structural-index representation.
- `src/core/stage2.zig` builds validated tapes and cursors.
- `src/core/ondemand.zig` provides the parser-owned JSON on-demand model.
- `src/core/stream.zig` incrementally indexes the JSON family and JSONL.
- `src/formats/` contains format-specific index, validation, tape, diagnostic,
  and streaming adapters.
- `test/root_test.zig` covers public contracts and checked-in examples.
  `test/fuzz_test.zig` uses fixed Smith seeds. `test/corpus_test.zig` runs the
  offline corpus catalogs.
- `test/corpus/` contains checked-in fixtures and provenance manifests.
- `docs/` and `papers/` contain the architecture record and research inputs.

## Local contracts

- Keep the build-time vector width at four bytes or more. The native default is
  64 bytes for AVX-512F plus AVX-512BW, 32 for AVX2, and 16 otherwise.
- `StructuralIndex` stores `u32` offsets and three trailing sentinels:
  `input_len`, `input_len`, and zero. Reject inputs that cannot fit this model.
- Preserve each format's quote, comment, framing, and token rules. Do not merge
  JSON-family dialect logic only because the APIs have similar shapes.
- A Stage 2 document owns its tape but borrows its source bytes. The source and
  document must outlive every cursor and raw value slice.
- An on-demand parser owns reusable indexes and permits one active document.
  Release the document before parser reuse or deinitialization.
- The shared `StreamIndexer` copies chunks into padded slots and transfers its
  final index through `take`. Markdown and XML use format-local stream
  indexers.
- Keep corpus tests offline. Add fixtures with pinned provenance metadata
  instead of fetching data during a test.
- Preserve scalar differential checks and fixed fuzz seeds when changing SIMD
  paths. They make behavior comparable across vector widths.

## Commands

Run these commands from the repository root:

```sh
zig build
zig build run
zig build test
zig build fuzz
zig build corpus
zig build test -Dvector_len=16
```

`zig build test` includes the deterministic Smith fuzz target.
`zig build corpus` runs the separate offline corpus catalogs. Use
`-Dvector_len=N` with `N >= 4` on any build step.

## NixOS, Development Environment & Shared Notes

- The host is NixOS. Never install system or development libraries
  imperatively. Declare dependencies, headers, runtime libraries, and tools
  in the repository's Nix environment definition.
- This repository has no `devenv.nix`, `flake.nix`, or `shell.nix`. Its
  repository-local Zig setup is `build.zig` and `build.zig.zon`, which pin Zig
  0.16.0 and declare no external package dependencies. If system packages are
  needed, declare them in a repository-local Nix environment before use rather
  than installing them imperatively.
- Store durable architecture, design, protocol, and experiment notes under
  `docs/`. Store cross-project or private agent handoff notes in
  `~/.agents/agent-notes/`; never commit those notes.
