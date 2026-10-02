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
- A logical width is not a storage width. On Zig 0.16.0, a logical `Mask` width
  of 5, 24, 48, 65, or 257 occupies 1, 4, 8, 16, or 48 storage bytes, and
  `@ctz` of a logical zero returns 5, 24, 48, 65, or 257. A storage-zero scan
  must normalize to the logical value before counting trailing zeros, or it
  advances by the backing width. No contract here describes how raw physical
  object padding reads.
- `StructuralIndex` uses `u32` offsets and ends with `input_len`, `input_len`,
  zero. Reject inputs that cannot fit. A test that needs an input longer than
  `u32` max must compile on 32-bit targets too, so guard it on
  `@bitSizeOf(usize) > @bitSizeOf(u32)`: on those targets the oversized length is
  unrepresentable, not merely rejected.
- Matcher lane-to-bit contract: `Mask(len)` bit `i` carries the match result
  for lane `v[i]`, and the explicit walk establishes that by shifting each
  lane's 0/1 result into bit `lane`. The five public matchers — `matchByte`,
  `matchAny2`, `matchAny4`, `matchRange`, and `matchJsonWhitespace` — are
  `inline` and resolve that choice at comptime: the walk is taken only where
  `builtin.cpu.arch.endian() == .big`, or on `hexagon` with `len < 16`. That
  query is hoisted, not re-read: `src/core/simd.zig` resolves it once at
  comptime into the module constants `target_is_big_endian` and
  `target_is_hexagon` (`src/core/simd.zig:227-228`), so no matcher reads
  `builtin.cpu.arch` itself and no runtime `Arch.endian` call exists in these
  paths. Hoisting is load-bearing rather than cosmetic — an inlined caller
  instantiates one width at a time, and each repeat of that switch spent
  backwards branches of the caller's shared comptime budget. Every other
  target instantiates the packed body alone and never instantiates the walks.
  The walks are `noinline` and take the vector directly. Keep the public
  matchers `inline`, and forbid vector-to-array coercions **at the matcher and
  leaf boundaries** — the walks and the scalar oracles beside them, where a
  conversion inside a large inlined caller corrupted lanes at width 64 on
  `aarch64_be`. That rule is deliberately local: array-to-vector
  initialization (`const v: Vec(T, n) = bytes;`), the array-taking leaf
  helpers, and array arguments elsewhere in the tree are ordinary and must
  not be swept up into a tree-wide ban. The scope actually verified for this
  kernel is under **Evidence**; treat any new big-endian divergence as a bug
  to fix, never as an accepted difference.
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
- `zig-gate --no-zbc`: the external aggregate build, test, AST, and lint gate.
  `ZIG` is pinned to this build's own `b.graph.zig_exe` here too, so the
  aggregate gate and the standalone `cross-test` step use one compiler.
- `zbc --no-color` over every owned `.zig` source, as a separate required
  command rather than zig-gate's advisory borrow-checker invocation.
- `zwanzig --threads 2` over the same owned `.zig` sources, with its default
  rules and no disabled checks.
- `cross-test --jobs 2 --build-jobs 1`, with `ZIG` pinned to this build's own
  `b.graph.zig_exe` so the gate cannot switch toolchains, over its full
  version-pinned Tier 1/2 target matrix. It runs `test`, not `check`, in each
  target build, so the gate does not recurse.

All four external commands run on every gate invocation; their results are
not cached. Missing executables and nonzero exits fail the gate. Analyzer
findings and incompatible analyzer frontends must not be suppressed merely
to obtain a green run. The tools must be available on `PATH`; the gate does
not install them. They run once on the host, not once per SIMD width.

`zig-gate --no-zbc` is not narrower than that list. It drops only its own
advisory `zbc` section; its `zwanzig` section and its `cross-test` section stay
enabled, and the build graph passes neither `--no-zwanzig` nor `--no-cross`. So
the exact `zig-gate --no-zbc` required above also runs strict `zwanzig` and the
full 53-target `cross-test` internally, and `cross-test` is still required
standalone by this gate as well. Its `cross-test` section fails outright when
`./cross-test.profile.sh` is absent, so that file is a gate input. The profile
sets `CROSS_BUILD_STEP=test`, `CROSS_JOBS=2`, and `CROSS_BUILD_JOBS=1`, and
names no `CROSS_MATRIX`, no `TARGETS`, and no compile-only override, so the
complete compiler-pinned table and its automatic runners stay in force and the
matrix is not narrowed. `zig-gate` does not pass `--require-runners`, so its
own `partial` and `build_only` results are judged by the failure count alone.

`cross-test.profile.sh` is listed in `build.zig.zon`'s `paths`, so it is
packaged with the tree rather than copied by hand.

The standalone `cross-test` step retains its logs and `cross-test-summary.json`
under `zig-out/cross-test/`; the aggregate section inside `zig-gate` writes
under the namespaced cache-root path described under **Scratch storage**.
Missing foreign runtimes are reported as `build_only`, not as executed test
passes. Its default exit policy permits explicit partial execution coverage;
only `cross-test --require-runners` requires every target to execute. Do not
describe a successful default cross-test run as full execution coverage.

## Scratch storage

The gate writes its scratch to `$TMPDIR/<user>/simd-check` and hands that
directory to the gate subprocesses as their own `TMPDIR`. The root of that path
defaults to the temporary directory the environment already names and falls
back to `/tmp` where it names none, so a host that redirects `TMPDIR` places
gate scratch there without a repository change. `-Dscratch_dir` overrides the
root, not the per-user subdirectory below it. The directory is created by a gate
step rather than at configure time, so an ordinary `zig build` still touches no
shared disk.

Gate scratch is not small: cross-test keeps a per-target build cache there, and
the analyzers keep multi-hundred-megabyte build caches per target, so a host
whose temporary directory cannot hold them points `-Dscratch_dir` at a larger
root. Check what that root is and how much space is free before putting anything
large there, rather than assuming. `zig-gate` and `zbc` still write a few
hundred bytes at their own hardcoded `/tmp` paths; that residue is not
redirectable and is bounded.

The `mkdir -p` that creates that scratch directory is marked
`has_side_effects`, as are the four external commands, so the build graph runs
them every time instead of caching a result for them.

`zig-gate` holds its own scratch and caches to a stricter, *physical* rule,
which is the host tool's own policy rather than an infrastructure change this
repository makes. When it selects a scratch root automatically it enforces the
full rule itself: the directory must be owned, writable, not a symlink, and
carry at least 1 GiB free. An explicit `GATE_SCRATCH` override is a different
check — only that the resolved path is on an approved physical volume, after
which the gate creates it; the automatic
ownership, writability, symlink, and free-space selection is not re-run over
an explicit override. The NFS exports are refused either way, because every
directory that gate writes is a Zig cache or is read back by one, a Zig cache
needs `renameat2()`, and an NFS mount rejects it with `EINVAL`. Its cache
defaults follow `$ZIG_LOCAL_CACHE_DIR` and `$ZIG_GLOBAL_CACHE_DIR`, and an
ambient `TMPDIR` pointing outside an approved physical volume is corrected with
a notice rather than silently used. No repository change makes the `TMPDIR`
this gate exports and `zig-gate`'s approved-volume rule agree.

A `.zig-cache` in a checkout can be a symlink to a shared cache outside the work
tree, so treat the link itself as part of the setup: its contents are
regenerable, while the symlink and the directory it points to are not. Delete
the contents, never the symlink or its directory.

**Cross-output namespacing, and what it is not.** `zig-gate` derives its
cross-test output from `GATE_SCRATCH`, which the host policy above selects per
user and not per project, so its default prefix is one directory shared by
every project that same user gates; cross-test takes an exclusive lock there
and refuses to start rather than share it, which is how two unrelated
checkouts fail each other during setup instead of running. `build.zig` now
sets `GATE_CROSS_OUTPUT` for the aggregate section to
`<this build's local cache directory>/zig-gate-cross/<project-root basename>-<first
8 SHA-256 bytes of the resolved project root, rendered as 16 hex digits>`,
resolved against that cache directory's working directory. The standalone
`cross-test` step keeps cross-test's own default under `zig-out/cross-test/`,
so the two full 53-target runs remain separate steps writing separate trees
rather than contending for one prefix. Both stay uncached, both stay pinned to
this build's own compiler, and no lock was removed and no check was disabled
to get there.

Two limits travel with that contract. Logs under the cache root are real
diagnostic evidence: they are where a run's own output was captured and read to
classify that run. What they do not have is durability. They are volatile cache
contents, so a cache cleanup may remove them at any time, a missing log proves
nothing, and no claim here depends on one surviving. And the 16-hex-digit
suffix is a disambiguator, not a collision guarantee: it is a truncated SHA-256
prefix, which keeps two checkouts apart in practice and does not prove that two
distinct roots can never share one.

The matrix is a representative sample, not a proof about every width.
`Mask(N) = @Int(.unsigned, N)` is what makes every width from 4 upward a
supported instantiation; the matrix defends the irregular and narrow widths
that a native run never reaches, and a green matrix says nothing about widths
it does not contain. `-Dvector_len` is not restricted to that list. Do not
narrow the gate to a hand-picked subset of widths or roots.

`zig build` is side-effect free with respect to benchmark archives: constructing
the build graph records nothing and touches no archive. Only `zig build
benchmark` and `zig build benchmark-semantic` write one.

## Repository layout notes

`.zig-cache` can be a symlink to a cache outside the work tree. `.gitignore` must
list `.zig-cache` without a trailing slash, because a trailing slash matches a
directory only and would not match that symlink.

`zig build check` is not side-effect free with respect to scratch storage: it
creates the scratch directory above and the four external commands write into
it. It still touches no benchmark archive.

## Evidence

This section states what has been verified and what is not claimed. It keeps no
run log: no pass counts, no run identifiers, no host, CPU, or toolchain
identity, and no recorded archive identity. What follows is either a durable
contract or a deliberately scoped claim. Rerun `zig build check` for a current
result, and do not restate any of it as a fresh observation.

**Scope actually verified for the matcher kernel.** This is a focused scope,
not a gate: the matcher property tests, the original caller at widths 12, 64,
and 257 from byte starts 2, 0, and 255, and a real parser consumer at width 12
all pass in ReleaseSafe on `aarch64_be-linux`, `powerpc64-linux`, and
`s390x-linux`; a sparse and dense JSON consumer passes at widths 16, 32, 64,
128, 256, and 512 on LoongArch through the real parser; the `hexagon`
`len < 16` fallback property tests pass in Debug and ReleaseSafe; and the
`aarch64-macos` library root compiles under `--test-no-exec`, with no Apple
runtime executed and no Apple runtime result claimed. This records how lanes
map to bits and how target selection is made. It is not a claim about how raw
physical object padding reads, it is not an ABI mechanism, and it establishes
no pass of the expanded gate.

The `hexagon` proof covers exactly two `src/core/simd.zig` test families, and
those two are the entire claim. Those focused property-test invocations did not
run `test/checking.zig` and did not run the root boundary tests, so they are
evidence about neither of them:

- `comparison masks extract only matching vector lanes` at widths 4, 5, 7, 12,
  16, 24, 32, 48, 64, 65, and 257 — every matching lane at each width, every
  candidate position for `matchAny2`/`matchAny4`, the two-matching-lane case,
  and `extractBitIndexes` over a combined punctuation mask.
- `matchJsonWhitespace agrees with scalar classification for every byte` at
  widths 4, 5, 7, 12, 16, 24, 32, 48, 64, 129, and 257 — all 256 byte starts,
  and every lane at each start, against a kept-out-of-line scalar oracle.

The two width lists differ on purpose: the comparison family takes 65 and the
whitespace family takes 129. Quote each list from its own family, because one
merged list is not what either test contains.

The original-caller evidence quoted above — widths 12, 64, and 257 from byte
starts 2, 0, and 255 — is a separate measurement of a separate caller and is
not part of either family.

**No green expanded-gate result is claimed.** No pass of the expanded gate is
claimed anywhere in this document, and no scope above is one. The gate stays
strict until every analyzer finding it reports is resolved: no analyzer rule is
disabled, no finding is suppressed, and no narrower target list, width list, or
check stands in for one that would have to pass. Nothing is committed while the
expanded gate is red, and no push is authorized.

`zbc` classifies the `Lease` nested in `Guard.lease` as an owning field —
`owned-field-no-outer-cleanup` at `resident.zig:73` — and asks for a
`Guard.deinit` forwarding to a `deinit` or `close` on the lease, while `Lease`
in fact exposes `check`, `release`, and `claim` (`src/core/resident.zig:43-70`)
and `Guard` stores it by value (`src/core/resident.zig:72-73`). That is a model
gap rather than a runtime defect, and it is unresolved. `Guard` borrows a
generation and focus token and must **not** be released when it goes out of
scope — an automatic release would invalidate the active document — so the fix
is not to add a release, a `deinit`, a clamp, a recheck, or a duplicated
counter. Remediate the finding itself: a disabled rule and a suppressed report
are not a fix, and this repository does not claim that work is done.

An analyzer inventory is that analyzer's own unwrap, unused, and style rules
over fixtures and aliases. It is not evidence of a runtime fault, and it is not
evidence that no runtime defect exists anywhere in the tree; that claim is not
made and must not be read into an inventory. The runtime invariants these paths
do exercise are covered by the tests the gate runs.

Recorded benchmark archives are historical source snapshots. An archive names
the sources it captured, so a later edit to any captured source makes
`reproduce` report `IdentityMismatch` instead of a false match — the outcome the
identity contract requires once a captured source has changed. Archives live
outside version control on purpose, `zig build` and `zig build check` never
write them, and only `zig build benchmark` does.

The failure paths of that runner are contract, not anecdote: reusing an
existing output directory fails with `PathAlreadyExists` and does not truncate
it; reproducing an archive whose captured sources have since changed fails with
`IdentityMismatch` before creating any directory; an archive whose first raw
capture byte was altered fails verification with `HashMismatch`; an archive
whose manifest timing for a case was altered fails with `ManifestIncomplete`;
and `--samples 0`, `--stream-chunk-size 7`, and an unknown flag each exit 1.

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
declares a winner, or reproduces a result measured on a past tree.

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
