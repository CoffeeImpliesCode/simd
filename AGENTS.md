# simd

Zig 0.16.0 static library for SIMD byte operations, UTF-8 checks, structural
indexes, validated token tapes, on-demand traversal, and streaming parsers.
`src/root.zig` exports adapters for JSON, JSONL, JSONC, JSON5, Markdown,
CommonMark, XML, `yaml-basic-1.2.2`, and the opt-in `yaml-extended-e2b-1.2.2`
profile. The `simd` executable visualizes masks over a fixed JSON sample; it is
not a general parser CLI. `docs/architecture-stage2-stream.md` carries current
contracts, historical design records, and the future roadmap; do not read a
roadmap section as an implemented API.

## Code and constraints

- `src/core/simd.zig` holds the vector and byte primitives. `stage1.zig` owns
  structural indexes; `stage2.zig` builds validated tapes and cursors;
  `json_value.zig` holds allocation-free value conversion; `resident.zig` owns
  the lease and guard state the JSONL, Markdown, XML, and YAML readers share;
  `ondemand.zig` owns the JSON on-demand model and implements the same
  single-focus rule independently, with its own generation and focus state and
  its own `FocusLost` error name instead of the shared module; `stream.zig`
  indexes the JSON family and JSONL incrementally. `src/formats/` contains the
  format-specific adapters.
- `-Dvector_len=N` requires `N >= 4`, and `build.zig` rejects a smaller value.
  Width is not limited to 16, 32, or 64: the mask type is
  `Mask(N) = @Int(.unsigned, N)`, which is defined for every width from 4
  upward. Native defaults are 64 bytes with AVX-512F and AVX-512BW, 32 with
  AVX2, and 16 otherwise.
- A logical width is not a storage width. On this checkout's Zig 0.16.0, a
  logical `Mask` width of 5, 24, 48, 65, or 257 occupies 1, 4, 8, 16, or 48
  storage bytes, and `@ctz` of a logical zero returns 5, 24, 48, 65, or 257. A
  storage-zero scan must normalize to the logical value before counting
  trailing zeros, or it advances by the backing width. No contract here
  describes how raw physical object padding reads.
- `StructuralIndex` uses `u32` offsets and ends with `input_len`, `input_len`,
  zero. Reject inputs that cannot fit.
- Preserve each format's quote, comment, framing, and token rules. Similar
  JSON-family APIs do not imply shared dialect rules.
- A Stage 2 document owns its tape but borrows source bytes. Keep source and
  document alive through every cursor and raw slice.
- An on-demand parser owns reusable indexes and permits one active document.
  Release that document before parser reuse or deinitialization.
- `StreamIndexer` copies chunks into padded slots and transfers its final index
  through `take`. The seven tape formats (JSON, JSONL, JSONC, JSON5, Markdown,
  XML, YAML) expose `initStreamIndexer`; Markdown, XML, and YAML back theirs
  with a format-local indexer. `formats.commonmark` and
  `formats.yaml_extended` expose no stream indexer.
- Streaming ends at index production. `feedFrom` is an input adapter, not a
  chunk-at-a-time Stage 2 source; it does not make a Stage 2 or on-demand
  cursor source-safe.
- Keep corpus tests offline and pin fixture provenance. Preserve scalar
  differential checks and fixed Smith fuzz seeds across SIMD changes.

## Shipped value-level APIs

These are additive. They do not change tape ownership, dialect rules, or
cursor lifetimes.

- `json_value.decodeString` decodes into caller-owned storage. It checks
  the complete input and the required output length before it writes any byte,
  so every error leaves the output buffer unchanged. Overlapping source and
  output ranges are rejected with `OverlappingBuffers`.
- `json_value.parseNumber` returns a `NumberView` holding the original source
  span plus a typed `NumberValue` of `signed`, `unsigned`, or `float`. It
  enforces the strict JSON number grammar and rejects integer overflow instead
  of truncating. It converts only; Stage 2 remains the grammar authority.
- `formats.jsonl.TapeRecordParser` is the reusable record path. The parser
  owns one structural index and one high-water tape that it reuses across
  documents and borrows the source. `iterate` returns a
  `TapeRecordIterator` under a document lease; a second `iterate` while one is
  active is `DocumentActive`. Advancing the iterator, deinitializing it, or
  calling `reset` invalidates every prior `TapeRecord` and cursor, and stale
  use reports an error instead of returning a wrong tape. `reset` clears the
  active lease, so stale use after a reset fails with `DocumentReleased`. The
  second stale error, `OutOfOrderIteration`, comes from the record generation
  rather than from the lease: advancing the iterator invalidates the previous
  record while the lease is still held, so a record or cursor kept across an
  advance fails with `OutOfOrderIteration` (`src/formats/jsonl.zig:288-295`,
  `346-350`, `364-373`, `632`). `TapeRecordOptions` bounds input and tape
  capacity, and a zero limit grows to the checked `u32` boundary. This API is
  separate from the eager `JsonlDocument`, which owns every record tape at
  once.
- XML value access is checked. Text, CDATA, and attribute events expose
  `decodedLength(source)`, which takes the source slice and returns the
  required output length, and `decodeInto(options)`, which takes
  `XmlDecodeOptions` carrying that source slice and the caller-owned output
  slice; overlapping source and output and malformed raw boundaries are
  rejected.
  `XmlDeclarationInfo` borrows declaration values, `XmlQName.split` splits a
  lexical name into prefix and local name, and `XmlDocument.declarationInfo`
  returns the borrowed declaration. The parser stays UTF-8-only: none of this
  is a transcoder, a namespace resolver, or a DTD processor.
- `formats.commonmark` is a separate CommonMark 0.31.2 semantic parser, not an
  extension of the marker-only `formats.markdown` tape. `parseCommonMark`
  returns a flat document that owns its nodes and semantic text and borrows
  the source, under explicit input, node, text, delimiter, bracket, reference,
  depth, and work limits. `renderCommonMarkHtml` has two modes.
  `HtmlRenderMode.safe` is the default: it omits raw HTML and filters dangerous
  URL schemes on links, images, and autolinks, including a scheme whose
  browser-stripped controls only appear after decoding.
  `HtmlRenderMode.conformance` is intentionally unsafe and reproduces the
  pinned spec output; the caller owns the trust or sanitization boundary there.
  Rendering bounds output bytes and rejects malformed traversal links.
- `formats.yaml` remains `yaml-basic-1.2.2`. `formats.yaml_extended` is the
  opt-in `yaml-extended-e2b-1.2.2` profile and adds literal and folded block
  scalars, multiline quoted scalars, and compact sequence mappings. Its
  `Document` owns the tape, the scalar metadata, and the cooked bytes while it
  still borrows the source, and `Value.ownership` reports `source_borrowed` or
  `document_owned` so a caller knows which storage a value lives in.
  `yaml_extended.Limits` is validated on entry: source bytes, cooked bytes,
  per-scalar source bytes, physical line count, per-scalar line count,
  indentation, tape words, and `depth_max` have checked bounds, and `depth_max`
  can be lowered below `yaml.yaml_max_depth` (1024) but never raised. A quoted
  scalar's opening line counts toward its scalar-line limit; block headers and
  terminal line sentinels do not. Aliases, anchors, tags, complex keys,
  directives, multiple documents, schema resolution, and streaming stay outside
  this profile.

## Work locally

`build.zig.zon` pins Zig 0.16.0 with no external packages. `devenv.nix` provides
that toolchain and direnv loads it through `.envrc`, so add system dependencies
there instead of installing them imperatively. From the repository root:

```sh
zig build
zig build run
zig build test
zig build fuzz
zig build corpus
zig build commonmark
zig build test -Dvector_len=16
```

`zig build test` includes deterministic Smith fuzzing; `zig build corpus` runs
the separate offline catalogs and the pinned CommonMark conformance suite.
`zig build check` is the gate and supersedes running that list by hand.

## Gate: `zig build check`

`zig build check` is the single command that gates a change. It covers, in one
step:

- The native-width full test roots: the source-local library root, the public
  `test/root_test.zig` root with its contract modules, the `simd` executable
  root, and the deterministic Smith fuzz root.
- The offline corpus catalogs and the pinned CommonMark 0.31.2 conformance
  suite, with no network access and no excluded example.
- A visualizer smoke run of the real `simd` executable.
- `zig fmt --check` over the Zig sources this repository owns:
  `build.zig`, `build.zig.zon`, `src`, `test`, `scripts`, `library_test.zig`,
  `bench.zig`, `kernel_bench.zig`, `semantic_bench.zig`, and `string_bench.zig`.
- The `scripts/benchmark.zig` behavior tests, once, on the host. They are not
  repeated per width.
- The same `scripts/benchmark.zig` source compiled again in semantic mode with
  its behavior tests, once, on the host, and the semantic measurement
  executable and archive runner compiled but never run. Neither is repeated per
  width, and no gate step launches a semantic measurement.
- The same test roots at a representative matrix of explicit widths in
  `[4, 5, 7, 12, 16, 24, 32, 64]`: the enforced minimum, several irregular and
  narrow widths that no native CPU selects, and the native widths. A width
  below 4 must fail, not silently fall back.

The matrix is a representative sample, not a proof about every width.
`Mask(N) = @Int(.unsigned, N)` is what makes every width from 4 upward a
supported instantiation; the matrix defends the irregular and narrow widths
that a native run never reaches, and a green matrix says nothing about widths
it does not contain. `-Dvector_len` is not restricted to that list. Do not
narrow the gate to a hand-picked subset of widths or roots.

`zig build` and `zig build check` are side-effect free with respect to benchmark
archives: constructing the build graph records nothing and touches no archive.
Only `zig build benchmark` and `zig build benchmark-semantic` write one.

## Repository layout notes

The checkout's `.zig-cache` is a symlink to a shared cache outside the work
tree. `.gitignore` must list `.zig-cache` without a trailing slash, because a
trailing slash matches a directory only and would not match that symlink.

## Evidence

Counts and timings under `docs/superpowers/plans/` are historical records from a
different host. `382/382`, `482/482`, the AVX2-host native width of 32, and
every `~/...` path describe that run, not this machine. Do not
restate them as current results, and do not derive a ranking from them.

This checkout has its own observation, recorded on 2026-10-01 on the host that
has AVX-512F and AVX-512BW, so its native width is 64:

- `zig build check -j2 --summary all` passed: 128 of 128 build steps and 4445
  of 4445 tests, including the `[4, 5, 7, 12, 16, 24, 32, 64]` matrix over all
  six test roots, the native roots, the offline corpora, the pinned CommonMark
  suite, `zig fmt --check`, the visualizer smoke, and 35 benchmark-script
  tests run once on the host. The native column is 350 library, 103 public
  root, 1 executable, 9 fuzz, 1 corpus, and 26 CommonMark tests. This is the
  actual current run, not the historical `382/382` or `482/482` counts.
- A fresh `zig-out/bin/simd` visualizer run printed its banner and five chunks.
- Six Markdown consumer binaries, Debug, ReleaseSafe, and ReleaseFast crossed
  with the default width 64 and the explicit width 5, checked exact marker
  offsets, kinds, and sentinels at widths 4, 5, 7, 12, 16, 24, 48, 65, and 72,
  and streamed the same document at widths 5 and 64 with chunks of 1, 7, 31,
  and 73 bytes. That source carries 312 letters and a CRLF prefix before the
  markers, so the widths above 64 execute full windows rather than only a
  tail.
- A local benchmark baseline was recorded, verified, and reproduced on
  2026-10-01 from source identity
  `033b3923543f486a32d0fb00f6492e7c9911d977a6417b4d01b1092c7d740a3c`:
  `baseline-final-20261001` at 3 samples, `reproduce-final-20261001` at 3
  samples with all 35 inputs and 210 cases reported identical, and
  `chunk256-final-20261001` at 1 sample, each over 35 inputs and 210 cases.
  Acceptance-closure work then edited the sources those archives captured, so
  they are historical snapshots now; reproducing one from the present tree is
  refused with `IdentityMismatch`, and none is overwritten or deleted. Their
  manifest records `zig` 0.16.0, compiler executable SHA-256
  `2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c` over
  172,641,672 bytes, target `x86_64-linux` with glibc 2.39, CPU
  `icelake_server`, ReleaseFast, and an explicit vector length of 32. Each
  sample entry carries no timing of its own; each case carries its actual
  per-sample timing array, which is an observation excluded from the
  reproduction comparison.

These are this machine's observations, not portable guarantees and not a
performance ranking. Rerun `zig build check` for a current count.
None of these observations compares this parser against another library or
ranks anything.

The original external comparison packet is unavailable and was not recovered:
filesystem and archive searches found no packet source or result history, the
authenticated owner-repository listing exposed only the private
`CoffeeImpliesCode/simd`, the authenticated `simd-bench-corpus` API returned
404, the recorded packet commits are absent, and no SSH recovery host is
configured. The decision is a new local baseline, not a recreated packet.

The current source reproduction baseline lives under the ignored
`zig-out/bench-evidence/`, recorded on 2026-10-01 from source identity
`fcdb7c0e7c8719fb9fd22385aecee9d3998d36317a40950e36fa55c108fb9c49`:

- `acceptance-closed-20261001`: recorded with `-Doptimize=ReleaseFast
  -Dvector_len=32`, 3 samples, 3 iterations, and 4096-byte chunks. It verifies
  from its own bytes: 35 inputs, 210 cases.
- `acceptance-closed-reproduce-20261001`: produced by `reproduce` from that
  archive, and independently verified: 3 samples, 35 inputs, 210 cases, every
  input and case identical.
- `acceptance-closed-chunk256-20261001`: recorded with 256-byte stream chunks,
  1 sample, and 3 iterations, and independently verified: 35 inputs, 210 cases.

The work domain behind all three is unchanged: 7 formats x 5 workloads x 6
stages is 35 inputs and 210 cases, with no `formats.commonmark` row and no
`yaml-extended-e2b-1.2.2` row.

`baseline-final-20261001`, `reproduce-final-20261001`, and
`chunk256-final-20261001` are the earlier `033b3923` family described above.
They remain immutable historical observations, they are not the current source
reproduction baseline, and none is overwritten or deleted. So do
`baseline-20261001`, `reproduce-20261001`, and `chunk256-20261001`, recorded
earlier the same day from the tree whose source identity was
`76f4b3b414f208a7934aca1720f325c80b7bbf0450f1713722c7ef2bfe0a8a8d`; the
sources they captured have been edited since, so reproducing one of them now is
refused with `IdentityMismatch`.

They live outside version control on purpose, and an archive names the sources
it captured, so a later edit to any captured source makes `reproduce` report
`IdentityMismatch` instead of a false match. `zig build` and `zig build check`
never write them; only `zig build benchmark` does.

The failure paths were observed on this machine, on copies of recorded archives
with the originals left untouched: reusing an existing output
directory fails with `PathAlreadyExists` and does not truncate it; reproducing
the `76f4b3b4`-era archive from the current tree fails with `IdentityMismatch`
before creating any directory; a copy whose first raw capture byte was changed
fails verification with `HashMismatch`; a copy whose manifest timing for case 0
was changed from 11470 to 11471 fails with `ManifestIncomplete`; and
`--samples 0`, `--stream-chunk-size 7`, and an unknown flag each exit 1.

`scripts/benchmark.zig` owns that baseline:

```sh
zig build benchmark -Doptimize=ReleaseFast -Dvector_len=32 -- record OUT_DIR [--samples N] [--iterations N] [--stream-chunk-size N]
zig build benchmark -Doptimize=ReleaseFast -Dvector_len=32 -- verify ARCHIVE_DIR
zig build benchmark -Doptimize=ReleaseFast -Dvector_len=32 -- reproduce OLD_ARCHIVE_DIR NEW_ARCHIVE_DIR
```

Defaults are 3 samples, 3 iterations, and a 4096-byte stream chunk. Samples
and iterations are 1 to 32; chunk sizes are 64, 256, 1024, 4096, or 16384.
`zig build benchmark-test` runs the script's behavior tests and `zig build
check` includes them.

`record` creates `OUT_DIR` with an exclusive mkdir and writes every archive file
exclusively, so a recording is immutable evidence and an existing directory or
file is a failure rather than a truncation. A failed sample still writes
`manifest.json` with `"status":"failed"` and a reason before exiting 1, so a
partial run is never published as complete; a successful run records
`"status":"complete"`, and `verify` reports a failed archive as failed instead
of as incomplete evidence. Every usage, verification, or comparison failure
exits 1.

An archive holds `manifest.json`, the `simd-bench` binary it ran, one
stdout/stderr pair per sample, and the sources it captured. Identity is a
repository-relative source path plus a content hash, never an absolute
workstation path. The manifest records the Zig basename, version, and executable
SHA-256 rather than a Zig path. Execution identity comes from the executable
the current build
provides through `benchmark_options` (`zig_exe`, `bench_target`, `bench_cpu`,
`bench_optimize`, `bench_vector_len`), never from an executable named inside an
archived manifest.

A sample entry records its index, both stream sizes and digests, and its
termination kind and value. It carries no timing of its own: the retired
per-sample `elapsed_ns` key is no longer written, and an older archive that
still carries it still verifies, because the manifest decoder ignores members
it does not read and `schema_version` stays 1.

`verify` re-checks one archive. `reproduce` verifies the old archive, preflights
the current sources, toolchain, build configuration, and CPU identity, records
a new archive with the old options, and compares the two case by case on input
hash, byte count, checksum, allocation count, and allocated bytes. The retained
per-case `elapsed_ns` timing arrays are never part of that comparison, never
ranked, and never printed as a ranking; `verify` re-derives each of them from
the archive's own captured stdout, so a recorded timing the capture does not
contain fails verification with `ManifestIncomplete`.

The work domain is the existing `bench.zig` contract, unchanged: 7 formats x 5
workloads x 6 stages is 210 cases over 35 input hashes, drawn from pinned
embedded fixtures and deterministic generated workloads. Markdown rows are a
marker-kind projection, YAML rows are `yaml-basic-1.2.2`, and the resident
`traverse_prefix8` stage consumes eight events or EOF. There is no
`formats.commonmark` or `yaml-extended-e2b-1.2.2` row.

Exact match is the reproducibility claim. A recording's timings are retained
as observations, not a ranking: nothing here compares against another library,
declares a winner, or restores the historical packet's results.

## Semantic measurement

`zig build bench-semantic` is a second measurement, not an extension of the
baseline above. `semantic_bench.zig` is its own root and its own executable,
with its own two format modules, its own fixture tables, and its own decoder;
what it shares with `bench.zig` is how one case is reported: the same counting
allocator, the same awake clock, and the same stdout discipline. The legacy
work domain is untouched by it: 7 formats x 5 workloads x 6 stages is still
210 cases over 35 input hashes, and that domain contains no semantic row.

The two parsers under measurement are the pinned CommonMark 0.31.2
specification and the opt-in `yaml-extended-e2b-1.2.2` profile, and the capture
names both pinned versions in its headers. Neither exposes a stream indexer.

```sh
zig build bench-semantic -- [ITERATIONS]
```

`ITERATIONS` is one optional positional decimal from 1 to 32, default 3. This
executable has no flags: a token that starts with `-` is refused rather than
ignored, and a second positional is refused. There is no stream-chunk option
here and none may be added, because neither measured parser streams, so a
chunk size would assert a capability the measurement does not have.

`zig build benchmark-semantic` records, verifies, and reproduces that same
measurement:

```sh
zig build benchmark-semantic -- record OUT_DIR [--samples N] [--iterations N]
zig build benchmark-semantic -- verify ARCHIVE_DIR
zig build benchmark-semantic -- reproduce OLD_ARCHIVE_DIR NEW_ARCHIVE_DIR
```

Samples and iterations are decimal from 1 to 32 and default to 3. Each of
`--samples` and `--iterations` may appear once, and no other flag is accepted,
so the legacy `--stream-chunk-size` is `UnknownFlag` here rather than a no-op.
That runner is `scripts/benchmark.zig` compiled again with `semantic_mode`
true; `benchmark_options.semantic_mode` is a build-provided constant, not a
runtime switch a caller could flip. The semantic compilation declares
`schema="simd-semantic-benchmark-archive"` at `schema_version` 1 and stores the
executable it ran at `bench/simd-semantic-bench`, beside the legacy
`simd-benchmark-archive` and its `bench/simd-bench`. It captures the source of
its own measurement: `build.zig`, `build.zig.zon`, `semantic_bench.zig`,
`scripts/benchmark.zig`, `scripts/semantic_contract.zig`,
`scripts/semantic_benchmark_report.zig`, `scripts/commonmark_bench.zig`,
`scripts/commonmark_bench_fixtures.zig`, `scripts/yaml_extended_bench.zig`,
`scripts/yaml_extended_bench_fixtures.zig`, and `src/**/*.zig`. The legacy
bench and its corpus fixtures are not input to this measurement and are not
captured under it. An archive is identified by its own schema name, so neither
measurement's archive verifies as the other's; what the two share is the
archive layout, the exclusive creation rule, the failed-manifest rule, the
offline verification, the sampling rules, and the toolchain provenance.

The work domain is the declared fixture list rather than a Cartesian product:
24 fixtures, 9 CommonMark and 15 YAML extended, each measured on exactly the
stages it declares, which is 41 cases. CommonMark declares four accepted
families, one raw HTML family, and four resource families, and an accepted
fixture measures `parse`, `traverse`, and `render_html`. The YAML profile
declares seven accepted families, five rejection families, and three resource
families, and an accepted fixture measures `parse` and `traverse`, because the
YAML profile has no renderer. A rejection or resource fixture declares exactly
one stage, and its row records the error name the real call returned. A stage
a fixture does not declare has no row, and the decoder admits no other row
order.

Every fixture carries an independently authored expectation, and every one is
checked against the real parser before any timing and before the first byte of
stdout. The first disagreement ends the run with `OracleMismatch`; the run
fails rather than adopting what it observed. The decoder then checks every row
against its own fixture's oracle again and refuses a contradicting outcome
with `UnexpectedOutcome`, and a capture whose headers name another CommonMark
revision or another YAML profile is refused with `ProfileMismatch`.

Each measured iteration is a fresh parse, that stage's named consumption, and
the destruction of what the parse owned, all inside the timed region. Nothing
is prebuilt and nothing is retained between iterations. A row's `outcome` is
what the real call returned, `accepted` or an `@errorName`, never an
expectation copied into a successful result, and every later iteration of a
case must repeat the first one's outcome and checksum or the run fails with
`OutcomeDrift` or `ChecksumDrift`.

Semantic timings are observations from the machine that produced them. The
capture states `streaming=none` and `ranking=none`, and the decoder refuses
any other boundary claim with `BoundaryViolation`. Nothing in this surface
presents a ranking, a speedup, or a comparison against another library.

Semantic archives are immutable evidence under the same rules as the legacy
ones: `record` creates `OUT_DIR` with an exclusive mkdir and writes every
archive file exclusively, a failed run still writes `manifest.json` with
`"status":"failed"` and a reason before exiting 1, and a later edit to any
captured source makes `reproduce` report `IdentityMismatch` instead of a false
match. `zig build check` compiles both semantic executables and runs their
behavior tests without launching a measurement; `bench-semantic` and
`benchmark-semantic` are the only steps that run them.
