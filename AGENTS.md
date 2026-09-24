# simd

Zig 0.16.0 static library for SIMD byte operations, UTF-8 checks, structural indexes, validated token tapes, on-demand traversal, and streaming parsers. `src/root.zig` exports adapters for JSON, JSONL, JSONC, JSON5, Markdown, XML, and restricted `yaml-basic-1.2.2`. The `simd` executable visualizes masks over a fixed JSON sample; it is not a general parser CLI. `docs/architecture-stage2-stream.md` includes historical records and future plans as well as current contracts; do not treat roadmap sections as implemented APIs.

## Code and constraints

- `src/core/simd.zig` contains vector and byte primitives. `stage1.zig` owns structural indexes; `stage2.zig` builds validated tapes and cursors; `ondemand.zig` owns the JSON on-demand model; `stream.zig` indexes the JSON family and JSONL incrementally. `src/formats/` contains format-specific adapters.
- `-Dvector_len=N` requires `N >= 4`. Native defaults are 64 bytes with AVX-512F and AVX-512BW, 32 with AVX2, and 16 otherwise.
- `StructuralIndex` uses `u32` offsets and ends with `input_len`, `input_len`, zero. Reject inputs that cannot fit.
- Preserve each format's quote, comment, framing, and token rules; similar JSON-family APIs do not imply shared dialect rules.
- A Stage 2 document owns its tape but borrows source bytes. Keep source and document alive through every cursor and raw slice.
- An on-demand parser owns reusable indexes and permits one active document. Release that document before parser reuse or deinitialization.
- `StreamIndexer` copies chunks into padded slots and transfers its final index through `take`. Markdown and XML have format-local stream indexers.
- Keep corpus tests offline and pin fixture provenance. Preserve scalar differential checks and fixed Smith fuzz seeds across SIMD changes.

## Work locally

`build.zig.zon` pins Zig 0.16.0 with no external packages. `devenv.nix` provides that toolchain and direnv loads it through `.envrc`, so add system dependencies there instead of installing them imperatively. From the repository root:

```sh
zig build
zig build run
zig build test
zig build fuzz
zig build corpus
zig build test -Dvector_len=16
```

`zig build test` includes deterministic Smith fuzzing; `zig build corpus` runs separate offline catalogs.
