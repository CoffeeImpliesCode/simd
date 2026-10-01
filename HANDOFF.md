# SIMD priorities 1–4: handoff after the phase 3–4 closure (2026-10-01)

## Current status and user instructions

Repository: `~/simd`.
All observations below were collected on 2026-10-01; this handoff was last
updated the same day, after the phase 3 and phase 4 closure pass.

Original objective: **“radically orchestrate: handle priorities 1 - 4.”**
The user then said **“always orchestrate.”** Substantial implementation
and review were delegated; the parent owned integration and verification.

That work was paused once, after the `FinalEvidenceDocs` subagent finished, and
this file originally carried a temporary halt plus “do not restart until the
user resumes”. **The user has since authorized `orchestrate: do 1 - 4`**, which
supersedes that halt. The resume/unblock/no-commit-unless-asked instructions
that this file used to carry are retired. The interpreted phases are:

1. Acceptance closure — **closed**; see “Acceptance closure, 2026-10-01”.
2. Focused Jujutsu commits of the accepted change set — **closed**; see
   “Phase 2 — focused Jujutsu commits (done)”.
3. Separate CommonMark and extended-YAML semantic measurements —
   **implemented and verified**; see “Phases 3 and 4 closure, 2026-10-01”.
4. Selecting/documenting the next consumer-driven API and source-ownership
   track — **closed as a design record**. The record selects a contract and
   implements none of it. Also in that section.

All four phases of `orchestrate: do 1 - 4` are therefore accounted for.
Phase 4 is closed as a *proposal*: the recorded-borrow contract it selects is
not in the code, and no clause of it may be called shipped because a document
argues for it.

No push is authorized. Focused commits were authorized for each phase that
reached a green gate, and must stay focused. Never fabricate a commit ID,
description, or result.

No commit was made by this workflow while it was paused. The starting review
fixed point was `9d883d0be2133e09884a6f1d1743fc305149913f`; VCS state was not
freshly inventoried after that, so that hash is historical provenance, not
current status. Preserve unrelated user changes.

Historical session identity: `01a0f4ba-d29e-7727-bdbf-2b6ced26b230`. That
session’s `agent://…` reports and `local://simd-priorities-acceptance.md` are
**not registered in the current session** — they were tried here and not found.
Their essential facts are preserved inline in this file; do not imply they were
recovered.

## Phases 3 and 4 closure, 2026-10-01 (current)

This section is the current status. The acceptance-closure section below it
records the state at the end of phase 1 and is kept as history: where its
gate counts and archive identities were superseded, this section wins and
those numbers were not deleted.

### Gate (actual current run)

```sh
zig build check -j2 --summary all
```

**PASS: 135/135 build steps, 4512/4512 tests.** The acceptance-closure pass
reported 128/128 and 4445/4445 earlier the same day. Both are real runs;
4512 is the current one. The difference is added coverage, not a regression:
the six test roots, all nine of their columns, and the 35 host-only legacy
benchmark-script tests are unchanged in number, and the 67 additional tests
are the two new host-only roots below.

New in the gate:

- `semantic-benchmark`: the host-only behavior-test root of the semantic
  measurement (`scripts/semantic_benchmark_test.zig`). It exercises the stdout
  protocol and the declared work domain, never a parser, so it runs once on
  the host and is never swept across the width matrix.
- `semantic-benchmark-script`: the same `scripts/benchmark.zig` source
  compiled again with `semantic_mode` true, running the semantic half of that
  file’s own behavior tests — same host target, same pinned seed, one
  invocation, never swept.
- `simd-semantic-bench` and `simd-semantic-benchmark`: the semantic
  measurement executable and the semantic archive runner. The gate depends on
  their compile steps only (`build.zig:667-678`); no gate step runs them, so
  recording is still an explicit act.

Still in the gate and unchanged: the six-root matrix at widths
`[4, 5, 7, 12, 16, 24, 32, 64]` plus the native width-64 column, the offline
corpora, the pinned CommonMark conformance suite, `zig fmt --check` over the
owned sources, the 35 benchmark-script tests, and the visualizer smoke.

### Semantic measurement surface (implemented)

Semantic measurement is a second domain, not an extension of the legacy
benchmark, and the legacy domain is untouched by it.

```sh
zig build bench-semantic -- [ITERATIONS]
zig build benchmark-semantic -- record OUT_DIR [--samples N] [--iterations N]
zig build benchmark-semantic -- verify ARCHIVE_DIR
zig build benchmark-semantic -- reproduce OLD_ARCHIVE_DIR NEW_ARCHIVE_DIR
```

- The measurement step takes one optional positional decimal, 1..32, default
  3. It has no flags: a token starting with `-` is refused
  (`UnknownArgument`), and a second positional is refused
  (`UnexpectedArgument`).
- The archive step takes `record`, `verify`, or `reproduce`, and accepts
  `--samples` and `--iterations` (1..32, default 3) once each. There is no
  stream-chunk option in semantic mode and none may be added: neither
  measured parser has a stream indexer, so a chunk size would assert a
  capability the measurement does not have.
- The two measured parsers are the pinned CommonMark 0.31.2 specification and
  the opt-in `yaml-extended-e2b-1.2.2` profile.
- The semantic archive declares its own schema name
  `simd-semantic-benchmark-archive` at `schema_version` 1 and stores the
  executable it ran at `bench/simd-semantic-bench`, beside the legacy
  `simd-benchmark-archive` and `bench/simd-bench`. The runner reports itself
  as `simd-semantic-benchmark` in semantic mode and `simd-benchmark` in
  legacy mode; the legacy spelling is unchanged.
- The legacy measured domain is unchanged: 7 formats × 5 workloads × 6
  stages is still 35 inputs and 210 cases, and it contains no semantic row.
- The semantic domain is 24 fixtures — 9 CommonMark, 15 YAML extended — each
  measured on exactly the stages it declares, which is 41 cases. It is the
  declared fixture list, not a Cartesian product.

### Semantic archives (observed today)

Fresh semantic archives under ignored `zig-out/bench-evidence/`, recorded,
verified, and reproduced with ReleaseFast, `vector_len=32`, 3 samples, 3
iterations:

| Archive | Observed result |
| --- | --- |
| `semantic-final-20261001` | Record and verify passed; 3 samples, 24 inputs, 41 cases |
| `semantic-final-reproduce-20261001` | Reproduce and verify passed; 3 samples, all 24 inputs / 41 cases identical to `semantic-final-20261001` |

Source identity of both:

```text
4fa28013ae213a4ee40005110ce029c10bc164e0189f51809c14712e61f27f2f
```

`semantic-closed-20261001` and `semantic-closed-reproduce-20261001`
(3 samples, 24 inputs, 41 cases each, source identity
`55c44300a760dc9ba67635f5615fcfb370f7fabb87abb366d2425d4d4c4677b7`) were
recorded earlier the same day and are historical now, because the sources
they captured were edited afterwards. Like every other recording they are
immutable evidence: not overwritten, not deleted.

Semantic timings inside these archives are observations of this machine. They
are excluded from reproduction comparison, and nothing in this surface is a
ranking, a speedup, or a comparison against any other library.

### Legacy domain after the change (observed)

The legacy domain was re-recorded after the semantic work:

| Archive | Source identity | Observed result |
| --- | --- | --- |
| `legacy-post-semantic-20261001` | `b4eb02a6b71c50be5821c01dc916cb5be22cba093db21d594c4e743b71eda941` | 3 samples, 35 inputs, 210 cases |
| `legacy-final-20261001` | `5ee8fa0e3d6ca98272beee5420f8e648acdd1b14fdf61b8943df772f772a38b4` | 3 samples, 35 inputs, 210 cases |

Each was compared case by case against the pre-change closure archive
`acceptance-closed-20261001` (source identity `fcdb7c0e…`): the case key set
is identical and zero cases differ across input hash, byte count, checksum,
allocation count, and allocated bytes. `legacy-final-20261001` is the current
legacy identity, so the `fcdb…` closure family is history for the legacy
domain now, exactly as the `033b…` family already was.

Measured checksums and allocation observations were byte-identical across
Debug, ReleaseSafe, and ReleaseFast.

### Real CLI negative controls (observed today)

Observed refusals in semantic mode. No directory was created by any of them.

- Recording over an existing output directory: `PathAlreadyExists`.
- Verifying a legacy archive as a semantic one: `ManifestSchemaMismatch`.
- `--samples 0`: `SampleCountOutOfRange`.
- The legacy `--stream-chunk-size` in semantic mode: `UnknownFlag`.

### Defects this work found and fixed

Recorded because each one shows where the previous gate was blind.

- The semantic measurement executable did not compile at all until its
  duplicate `build_options` module was removed: a root that declares its own
  options module and also imports the library hands the same generated
  options file to two modules of one compilation, which the compiler
  rejects. The measured width now arrives through `simd_lib`
  (`semantic_bench.zig:35-41`).
- An exhausted allocator was being recorded as a measured parser outcome.
  `error.OutOfMemory` is now propagated out of every measured and every
  verified call in both format modules, so it aborts a run instead of
  becoming an outcome string, a checksum, or an oracle comparison.
- Allocation failures inside the manifest parser were being reported as
  `ManifestInvalid`, a corrupt manifest, for a manifest that was never read.
  They now surface as `error.OutOfMemory` (`scripts/benchmark.zig:499-505`).
- One fixture’s source was one byte short of what its own oracle described,
  because a multiline string literal supplies no trailing newline. The
  fixtures now spell the final newline explicitly where the oracle expects
  one.
- The check gate never compiled the two semantic executables, which is why
  the first defect above reached a run at all. The gate now depends on their
  compile steps.

### Phase 4 — design record, no code

`docs/superpowers/plans/2026-10-01-source-ownership-contract.md` is the phase 4
design record. It selects a **recorded-borrow** source-lifetime and resource
contract: documents record their borrowed source once, accessors stop taking a
source argument, derived values carry the lease and generation of the storage
they read, and a returned slice names its storage as one of three kinds. It
implements none of it. Every clause is labelled **Enforced today**,
**Documented, not enforced**, or **Proposed**, and nothing outside those
labels is shipped behavior.

A read-only review of the record found wrong line citations and several wrong
counts, and those corrections were applied. Separate documentation
corrections made the current contract text match the code where it had
described as shared, or as checked, what is in fact independent and
unchecked: the architecture document now states that the JSON-family Stage 2
accessor performs no source identity check and that pairing the exact bytes
is a caller obligation (`docs/architecture-stage2-stream.md:163-173`), and it
and `AGENTS.md` now describe the JSON on-demand reader’s single-focus rule as
implemented independently, with its own state and its own `FocusLost` name,
which is what `src/core/ondemand.zig` does.

Nothing is pushed. No commit authorization covers phases 3 or 4.

## Acceptance closure, 2026-10-01 (current at that pass)

This section records the state at the end of phase 1. The phase 3–4 section
above is the current status. The older observation sections below this one
are historical context and are labelled where their numbers were superseded.

### Gate (actual current run)

```sh
zig build check -j2 --summary all
```

**PASS: 128/128 build steps, 4445/4445 tests.** This was an actual run after
the final comment corrections and strengthened regression coverage, not the
older 382/482 historical observations. Those are this pass’s numbers: the
phase 3–4 pass later the same day reports 135/135 and 4512/4512, and that is
the current count.

Native column: 350 library + 103 public root + 1 executable + 9 fuzz + 1 corpus
+ 26 CommonMark = 490 tests. The eight explicit-width columns run those same six
roots at widths 4, 5, 7, 12, 16, 24, 32, 64 (native column width is 64), and
the 35 benchmark-script tests run once on the host. Owned-source formatting,
offline corpora, all 652 CommonMark examples, and the visualizer smoke remain
in the gate. Earlier 4440/4440 checkpoints precede the five new archive
regressions and must not replace the final count.

### Real consumer binaries

Six real Markdown consumer binaries passed — Debug, ReleaseSafe, and
ReleaseFast crossed with the default native width 64 and explicit width 5. Each
checked exact marker offsets, kinds, and sentinels at one-shot widths 4, 5, 7,
12, 16, 24, 48, 65, 72 and streams with chunk sizes 1, 7, 31, 73. The source
carries 312 letters plus a CRLF prefix before the markers, so widths above 64
execute full windows rather than marker tails only.

Coverage was strengthened in existing permanent tests, not in throwaway ones:
the Markdown regression now uses that 312-letter + CRLF prefix at widths 4, 5,
6, 7, 9, 12, 17, 20, 24, 48, 65, 72, and the existing matcher scalar oracle
uses widths 4, 5, 7, 12, 16, 20, 24, 32, 48, 64, 65, 72. Other shared
`vector_widths` consumers remain at 16, 32, 64.

Fresh `zig-out/bin/simd` ran its real visualizer: banner plus five chunks.

ZLS diagnostics returned OK for `test/checking.zig`,
`src/core/{json_lexical,stage2,debug}.zig`, `src/main.zig`,
`src/formats/markdown.zig`, and `scripts/benchmark.zig`.

### Benchmark archives

New closure archives under ignored `zig-out/bench-evidence/`, each recorded and
verified with ReleaseFast, `vector_len=32`, 3 iterations:

| Archive | Observed result |
| --- | --- |
| `acceptance-closed-20261001` | Record and verify passed; 3 samples, 4096-byte chunks, 35 inputs, 210 cases |
| `acceptance-closed-reproduce-20261001` | Reproduce and verify passed; 3 samples, all 35 inputs / 210 cases identical to `acceptance-closed-20261001` |
| `acceptance-closed-chunk256-20261001` | Record and verify passed; 1 sample, 256-byte chunks, 35 inputs, 210 cases |

Source identity of all three closure archives:

```text
fcdb7c0e7c8719fb9fd22385aecee9d3998d36317a40950e36fa55c108fb9c49
```

Retained earlier archives `baseline-final-20261001`, `reproduce-final-20261001`,
and `chunk256-final-20261001` were independently verified during the same
execution (3/3/1 samples, 35 inputs, 210 cases each, source identity
`033b…d740a3c`). They are historical snapshots now, because the sources they
captured were edited afterwards. They were neither overwritten nor deleted and
must stay that way. The `76f4b3b4…` archives and the intermediate
`acceptance-*-u399fP` recordings are likewise immutable history.

The measured domain is unchanged: 7 formats × 5 workloads × 6 stages = 35
inputs / 210 cases. CommonMark and extended YAML still have no row here; the
semantic measurements the user asked for were built later as their own domain,
with their own schema and their own archives, and are never back-filled into
these. See “Phases 3 and 4 closure, 2026-10-01”.
Recorded timings are per-case, per-sample observations, excluded from
deterministic comparison, and never a speed ranking or external-library
comparison.

### Filesystem and temporary-path checks (closed)

- `/tmp/simd-acceptance.u399fP/old-source-mismatch` was read directly: **not
  found**. The old caveat about this specific check is resolved, and the
  statement may now be treated as an observed filesystem fact.
- `/tmp/wrepro` was read directly: **not found**. The cancelled width worker’s
  scratch path does not exist.
- A fresh complete listing of the scratch root contained only known agent probe
  sources/configs, six smoke binaries, and two corrupted archive copies; no
  failed-operation target directory was present.
- `/tmp/simd-acceptance.u399fP` was then removed by exact-path `rm`, after those
  checks. That cleanup is finished.

**Do not repeat that cleanup, and do not delete any other temporary path or
user file.** All `zig-out/bench-evidence/` recordings and the original
`.zig-cache` symlink must be preserved; the symlink target is still
`/tmp/zig-cache-simd`, and `.gitignore` lists `.zig-cache`
without a trailing slash.

### Compiler facts re-checked during closure

Zig 0.16 on this target: logical widths 5/24/48/65/257 occupy storage bytes
1/4/8/16/48; `MaskStorage` widths 8/32/64/128/384; `@ctz` of a logical zero
returns 5/24/48/65/257. Never write that a u24 occupies 3 bytes, that
`@ctz(0)` is undefined, or that logical-width integer comparisons
intrinsically observe padding. Explicit bounded storage normalization remains
the design, and storage-zero scans must guard before `ctz` so a scan cannot
advance by the backing width.

`std.Build.addRunArtifact` does add the graph seed automatically via
`enableTestRunnerMode`, and the explicit gate seed still wins the test-runner
last-one-wins parse, so the existing build seed rationale is accurate. One
synthetic-report comment was corrected from a last row of 256 to 257.

Core, lexical, Markdown, and archive audits found no remaining runtime defect.
A proposed raw object-padding guarantee and test was deliberately rejected:
no consumer-visible invariant is specified for raw physical padding, and
normalized logical values are the relevant contract. XML’s three older private
storage ladders are behaviorally bounded — a consistency observation, not a
defect, and left out of scope.

### Open item carried forward (not applied here)

The guidance review was still assembling its result during closure; apply only
evidence-backed findings. One known wording issue remains for the parent: in
XML, `decodedLength` takes the source and returns the required length, while
`decodeInto` takes `XmlDecodeOptions` containing the caller’s output. Never
imply that `decodedLength` takes the options. This batch changed only
`HANDOFF.md`, so no guidance file was touched here.

## Four priorities and implemented work

### 1. Arbitrary-width Markdown/SIMD correctness

Original observations: native and widths 8/16/32/64 passed; widths
4–7, 9–15, 17, 20, 24, and 48 failed Markdown scalar/index/stream parity checks.
Do not rerun the original failures merely to confirm those observations.

Implemented work includes:

- Target-derived `MaskStorage` and `exactMask` in `src/core/simd.zig`.
- Consistent explicit storage-width representations for affected mask scans,
  comparisons, extraction, and Markdown fused/streaming line scans.
- Checked extraction with capacity and u32-boundary behavior preserved.
- A zero-mask guard in `stage2.skipStringBody` before `@ctz`.
- Deterministic consumer/scalar regressions, including widths above 64.
- Fixed Smith seeds preserved. No parser allocation or per-lane-loop fallback
  was introduced for the width repair.

Keep `Mask(N) = @Int(.unsigned, N)` and arbitrary vector widths **N >= 4**.
Do not whitelist the matrix widths or impose a <=64 ceiling.

Important review correction: do **not** claim that Zig's logical-width integer
comparisons or `@ctz`/`@clz`/`@popCount` intrinsically observe object padding.
Source comments were corrected to describe explicit storage-width normalization
without making that false language-level claim. Derive storage from `@sizeOf`,
not byte alignment or a universal power-of-two assumption; on this target,
24 logical bits occupy 32, 48 occupy 64, and 257 can occupy 384.

Primary files: `src/core/simd.zig`, `src/formats/markdown.zig`. The final reviewer
also traced JSON lexical/stage2, YAML source, debug, and visualizer consumers.
The closure audit has now established the complete actual working set, so this
primary-file list was never exhaustive and no working-set gap remains open.

Closure status: **closed**. Core, lexical, and Markdown audits found no
remaining runtime defect, the compiler facts were re-probed, and six real
consumer binaries pass. See “Acceptance closure, 2026-10-01”.

### 2. Durable verification gate

`build.zig` now provides **`zig build check`**, directly composing:

- Native library, public root, executable, deterministic fuzz, offline corpus,
  and pinned CommonMark roots.
- The same six roots at explicit widths `[4, 5, 7, 12, 16, 24, 32, 64]`.
- Matching library/test `build_options` per width and pinned test-runner seed.
- Installed library/executable, real visualizer smoke, and owned-source
  `zig fmt --check`.
- Benchmark-script behavior tests once on the host, not per width.

The matrix is representative evidence, not proof about every supported width.
A build with `-Dvector_len=3` was observed to fail with exit 1 and the minimum-
width diagnostic. Normal build/test/fuzz/corpus/commonmark/bench steps remain.
`build.zig.zon` packages the required script and benchmark source files.
Ordinary build/check do not write benchmark archives.
Closure status: **closed**. The gate was actually run at closure time against
the current sources and passes; the authoritative counts and widths are in
“Acceptance closure, 2026-10-01”. Keep the full six-root matrix and the
host-only benchmark step whenever anything changes.

### 3. Approved replacement: a new local benchmark baseline

The original external C++ comparison packet could not be recovered. The user
explicitly selected **“Create a new local baseline.”** This supersedes the old
recovery prerequisite; do not leave the goal blocked on obtaining that packet.
Do not call the new evidence recovered historical results or a cross-library
performance ranking.

Recovery evidence already collected:

- Filesystem/archive/history searches did not recover the packet sources or
  retained results; the historical `~/...` checkout is absent.
- Authenticated owner-repository listing exposed only private
  `CoffeeImpliesCode/simd`; authenticated `simd-bench-corpus` API returned 404.
- Recorded packet commits are absent, and no SSH recovery host is configured.

Implemented files:

- `scripts/benchmark.zig`: archive runtime and 34 behavior tests.
- `scripts/benchmark_report.zig`: strict pure report decoder and 1 behavior test.
- `build.zig`: `benchmark`, `benchmark-test`, host runner, and build-provided
  `benchmark_options` (`zig_exe`, `bench_target`, `bench_cpu`, `bench_optimize`,
  `bench_vector_len`).

CLI:

```sh
zig build benchmark -Doptimize=ReleaseFast -Dvector_len=32 -- record OUT_DIR [--samples N] [--iterations N] [--stream-chunk-size N]
zig build benchmark -Doptimize=ReleaseFast -Dvector_len=32 -- verify ARCHIVE_DIR
zig build benchmark -Doptimize=ReleaseFast -Dvector_len=32 -- reproduce OLD_ARCHIVE_DIR NEW_ARCHIVE_DIR
zig build benchmark-test
```

Defaults: 3 samples, 3 iterations, 4096-byte chunks. Samples/iterations accept
1..32; chunks accept 64, 256, 1024, 4096, or 16384.

The unchanged measured domain is 7 formats × 5 workloads × 6 stages:
**35 inputs and 210 cases**. Markdown is a marker-kind projection, YAML is
`yaml-basic-1.2.2`, and `traverse_prefix8` consumes eight native events or EOF.
There are no CommonMark or extended-YAML benchmark rows.

Archives retain raw stdout/stderr, the benchmark binary, source snapshots,
relative-path/content identities, compiler executable SHA-256, selected build
configuration, static CPU/affinity/environment facts, options, and status.
Creation is exclusive; never overwrite an existing recording. A failed run is
not published as complete. Verification rechecks archive bytes; nothing from
an archive is executed. Reproduction uses the current build-provided artifact,
preflights identity, then compares input hashes/bytes, checksums, allocation
counts, and allocated bytes. Timing is never an equality or ranking criterion.

Final archive review found and corrected:

- JSON-writer depth-flag storage was one element too short for its guard.
- An unmeasured per-sample `elapsed_ns = 0` field was removed completely from
  production struct/emitter/decoder/construction. Real **per-case** CSV timing
  arrays remain and are verified against captured stdout.
- Five permanent archive regressions were added: manifest symlink, source
  payload symlink, forged successful termination, forged timing value, and
  timing-array length mismatch.

Schema remains version 1; generic ignored JSON members allow older archives to
verify without introducing a special legacy shim. Older source identities must
still fail current-source reproduction preflight.
Closure status: **closed for the legacy domain**. New `acceptance-closed-*`
archives were recorded, reproduced, and verified against the current sources;
see “Acceptance closure, 2026-10-01”. The CommonMark and extended-YAML semantic
measurements are a separate domain and are not back-filled into these
archives; they were implemented later, with their own schema, bench path, and
recordings. See “Phases 3 and 4 closure, 2026-10-01”.

### 4. Repository guidance and cache hygiene

Updated:

- `AGENTS.md`
- `docs/architecture-stage2-stream.md`
- `docs/superpowers/plans/2026-09-09-parser-performance.md`
- `docs/superpowers/plans/2026-09-09-reference-guided-roadmap.md`
- `.gitignore`

Guidance now distinguishes shipped semantic APIs, borrowing/leases, safe versus
unsafe CommonMark rendering, exact extended-YAML profile/limits, index-only
streaming, and current versus historical evidence. The last docs worker also
corrected YAML validator return type/counts, JSON-family error-set count, and
shared versus format-local stream indexer descriptions.

`.gitignore` lists `.zig-cache` **without a trailing slash**. The parent already
ran `jj file untrack .zig-cache`; the original symlink survived and its target
was `/tmp/zig-cache-simd`. Do not delete it. Historical 382/382,
482/482, AVX2-native32 claims, `~/...` paths, and timing tables remain
historical, not current results.
Closure status: guidance edits are in place. The scratch directory
`/tmp/simd-acceptance.u399fP` was already removed by exact-path `rm`; nothing
else may be deleted. The guidance review was still assembling its result at
closure time — apply only evidence-backed findings, including the open XML
`decodedLength`/`decodeInto` wording item recorded above.

## Directly observed verification (historical, pre-closure)

Everything in this section was observed before the closure pass and is kept as
history. Where a later pass produced a stronger statement, the section above
it wins: “Acceptance closure, 2026-10-01” for the phase 1 state, and
“Phases 3 and 4 closure, 2026-10-01” for the gate counts and archive
identities that the phase 3–4 work superseded.

### Complete gate after the final source corrections

```sh
zig build check -j2 --summary all
```

**PASS: 128/128 build steps, 4445/4445 tests.** This was that pass’s count;
the current one is 135/135 and 4512/4512, recorded above.

Native column: 350 library + 103 public root + 1 executable + 9 fuzz + 1 corpus
+ 26 CommonMark = 490 tests. The eight explicit-width columns run those same
six roots; 35 benchmark-script tests run once. Native width here is 64.
Earlier 4440/4440 checkpoints preceded the five new archive regressions and
must not replace the final count.

### Actual Markdown consumer

The parent ran an isolated executable, not only tests. A long plain prefix
ensured wide scans were exercised; it checked nine exact marker offsets,
kinds, and all three sentinels.

- One-shot widths: **4, 5, 7, 12, 16, 24, 48, 65, 72**.
- Stream widths: **5 and 64**; chunks **1, 7, 31, 73**.
- All combinations passed in **Debug, ReleaseSafe, ReleaseFast**.

The first throwaway oracle mistakenly omitted parentheses from link markers;
it was corrected to match the existing Markdown marker contract. The final
runs all passed. No parser change was made to satisfy the mistaken oracle.

At closure this was repeated as six real consumer binaries — three optimize
modes crossed with the default native width 64 and explicit width 5 — as
recorded in the closure section above.

### Final immutable benchmark evidence (historical source identity)

Under ignored `zig-out/bench-evidence/`:

| Archive | Observed result |
| --- | --- |
| `baseline-final-20261001` | Record and verify passed; 3 samples, 3 iterations, 4096-byte chunks, 35 inputs, 210 cases |
| `reproduce-final-20261001` | Reproduce and verify passed; all 35 inputs / 210 cases identical |
| `chunk256-final-20261001` | Record and verify passed; 1 sample, 3 iterations, 256-byte chunks, 35 inputs, 210 cases |

Source identity:

```text
033b3923543f486a32d0fb00f6492e7c9911d977a6417b4d01b1092c7d740a3c
```

Actual compiler: `zig` 0.16.0, 172,641,672 bytes, SHA-256:

```text
2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c
```

Manifest build identity: `x86_64-linux.6.12...6.12-gnu.2.39`,
`icelake_server+rtm+sgx+smap+smep`, ReleaseFast, explicit vector length 32.
Direct manifest inspection confirmed no sample-level timing key and actual
per-case timing arrays. No speedup or ranking was derived.

Older archives `baseline-20261001`, `reproduce-20261001`, and
`chunk256-20261001` retain source identity
`76f4b3b414f208a7934aca1720f325c80b7bbf0450f1713722c7ef2bfe0a8a8d`.
They are immutable historical observations, not the current baseline.
Additional intermediate `acceptance-*-u399fP` recordings were created during
verification. Do not overwrite/delete recorded evidence as routine cleanup.

The `033b…` archives above were independently re-verified during the closure
pass and are now historical snapshots, because the sources they captured were
edited afterwards. They were neither overwritten nor deleted. The current
closure recordings carry the `fcdb…` source identity instead.

### Real CLI negative controls

Observed exit 1:

- Existing output directory: `PathAlreadyExists`.
- Different vector-width build: `IdentityMismatch`; absence of its output
  directory was explicitly checked.
- Old source identity with current build: `IdentityMismatch`.
- Copied final raw capture, first byte changed: `HashMismatch`.
- Copied final manifest, case-0 timing 11470 -> 11471: `ManifestIncomplete`.
- `--samples 0`: `SampleCountOutOfRange`.
- `--stream-chunk-size 7`: `UnsupportedChunkSize`.
- Unknown option: `UnknownFlag`.
- Recorded archive copy whose manifest status was changed to failed:
  `ManifestFailedStatus`. Observed on a fresh exclusive copy of
  `acceptance-closed-chunk256-20261001`; the copy was removed afterwards and the
  originals were untouched.

Resolved at closure: `/tmp/simd-acceptance.u399fP/old-source-mismatch` was read
directly and is not found, so “the old-source mismatch created no directory” is
now an observed filesystem fact rather than an inference from preflight order.

## Phases 2–4 (all closed)

All four phases of the user’s `orchestrate: do 1 - 4` request are accounted
for: phase 2 by its focused commits, phase 3 by an implemented and recorded
semantic measurement, phase 4 by a design record that proposes rather than
implements. None of them may be called done on the strength of the passing
gate; each is recorded above with what was actually observed. The former
resume/unblock list, including “no commit unless requested”, is retired:
focused commits were authorized for phase 2 and have been made. Phases 3 and 4
reached a green gate afterwards and are committed the same way. No push is
authorized.

### Phase 2 — focused Jujutsu commits (done)

Committed as four focused changes, oldest first, with no push and no history
rewrite:

- `a6968e45` `chore(repo): ignore the shared cache symlink without a trailing slash`
- `bc2fcab3` `fix(simd): bound lane masks to storage width before scanning`
- `ce28d524` `feat(bench): record, verify, and reproduce immutable benchmark archives`
- `0611ae5c` `docs: record acceptance closure evidence and correct shipped-contract claims`

Those IDs were read back from the repository after the split, and no commit
after them is authorized. The phase 3 and phase 4 work is not covered by them
and must not be folded into a phase-2 commit.

### Phase 3 — CommonMark and extended-YAML semantic measurements (done)

Implemented, recorded, verified, and reproduced: 24 fixtures and 41 measured
cases across the pinned CommonMark 0.31.2 specification and the opt-in
`yaml-extended-e2b-1.2.2` profile, in their own schema, their own bench path,
and their own archives. The legacy 35-input/210-case domain was re-recorded
afterwards and is unchanged case for case. Commands, identities, negative
controls, and the defects this work found are in “Phases 3 and 4 closure,
2026-10-01”.

### Phase 4 — next consumer-driven API / source-ownership track (done as a record)

`docs/superpowers/plans/2026-10-01-source-ownership-contract.md` selects and
documents a recorded-borrow source-lifetime and ownership boundary derived
from actual consumers. It implements nothing, and no clause of it is shipped
behavior unless the record itself labels it **Enforced today**. Keep the
guardrails above — logical width never implies raw object-padding
observability.

### Working rules

1. Orchestrate substantial independent slices with one writer per file. Do not
   reuse cancelled writers, allow overlapping ownership, or silently shrink
   scope.
2. Agents MUST skip all compiler probes, builds, tests, gates, lint, and
   formatters; the parent runs gates once after writers finish.
3. Verify behavioral changes with a real smoke run in addition to the full gate,
   preserving the six-root width matrix and all offline examples.
4. Reproduction after captured-source changes requires a fresh exclusive
   recording, never a rewritten old manifest or archive.
5. No recording under `zig-out/bench-evidence/` may be overwritten or deleted,
   and the shared `.zig-cache` symlink stays. Scratch created outside the
   repository is temporary and may be removed; no other temporary path and no
   user file may be.

## Worker handoffs (historical, links unavailable)

The original session’s reports are **not registered in the current session**:
`agent://FinishWidthCorrection`, `agent://FinalWidthReview`,
`agent://FinalArchiveReview`, `agent://ArchiveClosureFix`,
`agent://FinalEvidenceDocs`, and `local://simd-priorities-acceptance.md` were
tried here and returned not found. Do not imply they were recovered and do not
block on them; their essential facts are preserved inline above.

- `FinishWidthCorrection` — width implementation; its early root-cause prose
  overstated Zig padding semantics, superseded by the later review/corrections.
- `FinalWidthReview` — no actionable behavioral or gate defect; it identified
  inaccurate source comments that the parent then corrected.
- `FinalArchiveReview` — JSON depth, fabricated timing, and missing
  symlink-regression findings, all addressed by `ArchiveClosureFix`.
- `ArchiveClosureFix` — the final narrow fixes and the five new tests.
- `FinalEvidenceDocs` — the four-file docs handoff: published gate, archives,
  API audit, and historical-evidence boundaries.
- The acceptance artifact recorded the approved “Create a new local baseline”
  scope, which is what priority 3 implements.
