# SIMD priorities 1–4: handoff after acceptance closure (2026-10-01)

## Current status and user instructions

Repository: `~/simd`.
All observations below were collected on 2026-10-01; this handoff was last
updated the same day, after the acceptance-closure verification pass.

Original objective: **“radically orchestrate: handle priorities 1 - 4.”**
The user then said **“always orchestrate.”** Substantial implementation
and review were delegated; the parent owned integration and verification.

That work was paused once, after the `FinalEvidenceDocs` subagent finished, and
this file originally carried a temporary halt plus “do not restart until the
user resumes”. **The user has since authorized `orchestrate: do 1 - 4`**, which
supersedes that halt. The resume/unblock/no-commit-unless-asked instructions
that this file used to carry are retired. The interpreted phases are:

1. Acceptance closure — **closed**; see “Acceptance closure, 2026-10-01”.
2. Focused Jujutsu commits of the accepted change set — **pending, next**.
3. Separate CommonMark and extended-YAML semantic measurements — **pending**.
4. Selecting/documenting the next consumer-driven API and source-ownership
   track — **pending**.

Do not read this file as a claim that phases 2–4 are done. Closing acceptance
closes only the original priorities 1–4 implementation and its verification.

No push is authorized. Commits are authorized for phase 2 only and must be
focused. Never fabricate a commit ID, description, or result.

No commit was made by this workflow while it was paused. The starting review
fixed point was `9d883d0be2133e09884a6f1d1743fc305149913f`; VCS state was not
freshly inventoried after that, so that hash is historical provenance, not
current status. Preserve unrelated user changes.

Historical session identity: `01a0f4ba-d29e-7727-bdbf-2b6ced26b230`. That
session’s `agent://…` reports and `local://simd-priorities-acceptance.md` are
**not registered in the current session** — they were tried here and not found.
Their essential facts are preserved inline in this file; do not imply they were
recovered.

## Acceptance closure, 2026-10-01 (current)

This section is the current status. The older observation sections below it are
historical context and are labelled where their numbers were superseded.

### Gate (actual current run)

```sh
zig build check -j2 --summary all
```

**PASS: 128/128 build steps, 4445/4445 tests.** This was an actual run after
the final comment corrections and strengthened regression coverage, not the
older 382/482 historical observations.

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
inputs / 210 cases. CommonMark and extended YAML have no benchmark rows; the
semantic measurements the user asked for are phase 3 and are not implemented.
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
measurements are a separate, later authorized phase: not implemented, and never
to be back-filled from these archives.

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
history. Where the closure pass produced a stronger statement, the
“Acceptance closure, 2026-10-01” section above wins.

### Complete gate after the final source corrections

```sh
zig build check -j2 --summary all
```

**PASS: 128/128 build steps, 4445/4445 tests.**

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

Resolved at closure: `/tmp/simd-acceptance.u399fP/old-source-mismatch` was read
directly and is not found, so “the old-source mismatch created no directory” is
now an observed filesystem fact rather than an inference from preflight order.

## Remaining authorized work (phases 2–4)

Acceptance closure is closed. The items below are the rest of the user’s
`orchestrate: do 1 - 4` request; none of them are done, and none may be called
done on the strength of the passing gate. The former resume/unblock list,
including “no commit unless requested”, is retired: focused commits are now
authorized for phase 2, and no push is authorized.

### Phase 2 — focused Jujutsu commits (next)

1. Commit the accepted change set as focused commits, parent-owned. Never
   fabricate a commit ID, description, or result; never push or rewrite history.
2. Treat the fixed point hash above as historical provenance and re-inventory
   actual VCS state before committing.
3. Preserve unrelated user changes and keep this file’s historical-versus-
   current evidence boundaries intact.

### Phase 3 — CommonMark and extended-YAML semantic measurements

4. Not implemented. Design the measurement profile, oracle, and limits before
   recording anything. The legacy 35-input/210-case domain has no CommonMark or
   extended-YAML rows, and must not be extended by back-filling them.

### Phase 4 — next consumer-driven API / source-ownership track

5. Not implemented: select and document the next API direction and its source
   lifetime/ownership boundary from actual consumers. Keep the guardrails above
   — logical width never implies raw object-padding observability.

### Working rules

6. Orchestrate substantial independent slices with one writer per file. Do not
   reuse cancelled writers, allow overlapping ownership, or silently shrink
   scope.
7. Agents MUST skip all compiler probes, builds, tests, gates, lint, and
   formatters; the parent runs gates once after writers finish.
8. Verify behavioral changes with a real smoke run in addition to the full gate,
   preserving the six-root width matrix and all offline examples.
9. Reproduction after captured-source changes requires a fresh exclusive
   recording, never a rewritten old manifest or archive.
10. Delete nothing further: no other temporary-path cleanup is authorized, and
    the retained archives and the `.zig-cache` symlink stay.

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
