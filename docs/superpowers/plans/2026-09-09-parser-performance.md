# Parser Performance Implementation Plan

> **For agentic workers:** Use `subagent-driven-development` or `executing-plans` when implementing an approved candidate. Checkboxes below describe future experiments, not work completed by this benchmark run.

**Goal:** Reduce measured parser costs without changing accepted grammar, diagnostics, source lifetimes, or cursor behavior.

**Architecture:** Keep format-specific grammars and the current staged parser model. Start with redundant work and allocation ownership, then optimize measured byte loops. These are candidate experiments, not promised speedups or approval to implement every candidate.

**Tech Stack:** Zig 0.16.0, C++23/GCC 15.3.0 reference adapters, pinned Nix dependencies, Linux perf, Jujutsu.

## Document status

This file is a historical record. Every measurement, count, and path below was
captured on a different host and is preserved verbatim for its provenance.
Nothing here is a current-machine result and nothing here may be restated as
one.

- The `~/...` packet, snapshot, and workspace paths are not present in
  this checkout. They are retained because their provenance and measured
  values are the evidence for the completed work. They have not been relocated,
  and no substitute location is claimed for them.
- A pass count such as `382/382` describes that run. This checkout's own
  observation, recorded on 2026-10-01 on an AVX-512 host, is `zig build check
  -j2 --summary all` passing 128 of 128 build steps and 4445 of 4445 tests, with
  a native width of 64; see `AGENTS.md`.
- This repository is the Zig parser only. The comparison packet and its C++
  reference adapters live outside it, so no command in this repository
  recreates their results.
- The packet was searched for and not found. Local filesystem and archive
  searches found no packet source or result history; the authenticated
  owner-repository listing exposed only the private `CoffeeImpliesCode/simd`;
  the authenticated `simd-bench-corpus` API returned 404; the recorded packet
  commits are absent; and no SSH recovery host is configured.
- The approved response is a NEW LOCAL BASELINE, not recovery of the original
  external packet. `scripts/benchmark.zig` records this repository's own
  parser measurements; see **The record, verify, reproduce CLI**. No new
  performance ranking and no recovered packet result is claimed.
- That baseline was recorded on 2026-10-01 from source identity
  `033b3923543f486a32d0fb00f6492e7c9911d977a6417b4d01b1092c7d740a3c` as
  `zig-out/bench-evidence/baseline-final-20261001` (ReleaseFast,
  `-Dvector_len=32`, 3 samples, 3 iterations, 4096-byte chunks), verified over
  35 inputs and 210 cases, and reproduced into `reproduce-final-20261001` with
  all 35 inputs and 210 cases identical; `chunk256-final-20261001` records the
  same work at 256-byte chunks with 1 sample and also verifies. Acceptance work
  then edited the sources those archives captured, so that family is a
  historical observation and is not the current source reproduction baseline.
- The current source reproduction baseline is the later 2026-10-01 recording
  from source identity
  `fcdb7c0e7c8719fb9fd22385aecee9d3998d36317a40950e36fa55c108fb9c49` in the
  same directory: `acceptance-closed-20261001` (ReleaseFast,
  `-Dvector_len=32`, 3 samples, 3 iterations, 4096-byte chunks),
  `acceptance-closed-reproduce-20261001` recorded from it with every input and
  case identical, and `acceptance-closed-chunk256-20261001` at 256-byte chunks
  with 1 sample. Each verifies over 35 inputs and 210 cases of the unchanged
  legacy domain, which has no CommonMark and no extended-YAML row.
- The still earlier `baseline-20261001`, `reproduce-20261001`, and
  `chunk256-20261001` from source identity
  `76f4b3b414f208a7934aca1720f325c80b7bbf0450f1713722c7ef2bfe0a8a8d` are
  historical observations as well. No archive family is overwritten or
  deleted, and `AGENTS.md` records the full evidence.

## Global constraints

- Preserve the four-byte minimum vector width and scalar differential checks.
- Preserve `u32` structural offsets and the three trailing sentinels: input length, input length, zero.
- Preserve source borrowing, tape ownership, cursor lifetimes, and the one-active-document rule.
- Preserve each dialect's grammar and first-error behavior. Do not merge JSON-family grammars for convenience.
- Keep corpus tests offline, with pinned hashes and provenance.
- Do not overwrite the existing dirty parser checkout. Start each approved optimization in a fresh jj change/workspace.
- Keep an optimization only after correctness checks and repeated measurements support it. Allocation volume is not peak RSS; sampling percentages are not speedup estimates.

---

## Completed benchmark work

The comparative packet is `~/simd-bench-corpus`. Its grammar and measurement contracts are in `docs/superpowers/specs/2026-09-09-seven-format-profiles.md` there.

- Expanded the packet to JSON, JSONL, JSONC, JSON5, Markdown, XML, and YAML.
- Added 53 offline fixtures: 39 accepted and 14 rejected, totaling 8,457,207 source bytes.
- Added native SIMD adapters and cmark, pugixml, and libyaml references. JSON5's reference is a documented common subset through jsoncons, not full JSON5.
- Added all-format runner/report handling and `scripts/run.zig --build-dir`.
- Corrected two YAML corpus oracles through independent semantic reconstruction; both parsers agree with the corrected values.
- Added timed duplicate-attribute rejection to the pugixml wrapper and fixed YAML output-checksum clearing on invalid mode.
- Excluded generated Zig caches from source identity inputs. Comparable compiler settings omit the main implementation dispatch selector, but retain other definitions.
- Full Release build passed. All seven CTest targets passed. The runner's malformed-option test and both comparator tests passed; Zig formatting checks passed.
- Actual runner invocation with `--build-dir build-current` passed.
- Smoke matrix: 80 invocations, zero failures.
- Measured matrix: 240 invocations, 906 result rows, zero failures. Each row has 100 timed iterations; every workload/implementation/mode has three independent process samples. Batch 2 reverses command order.
- Verified every input hash, byte count, outcome, DOM checksum, iteration count, and CPU affinity. All 302 result groups have stable checksums across three processes.
- The strict comparator accepted all 80 same-implementation batch-1/batch-2 report pairs across all seven formats.

No parser optimization was implemented in this work.

## Measurement identity and limits

The frozen parser source is `~/projects/simd-benchmark-snapshot`, clean working copy `91a55c8b75f20cfe7dcca7013f645a10fb896e57`, parent `bb23a906dd2fccb551971ae40b78324d57103d14`. It remains available for reproduction. The packet identity embedded in measured reports is working copy `06a087a3d12d20f21be292829abf23dd0b3fb1d7`, parent `a3fa508f77602010928bfe9ba1b7b35d5d3f83b3`.

CPU: Intel Core i7-9750H, Linux logical CPU 2, SMT sibling 8. The governor was `performance`. The CPU was not isolated; sibling activity, background load, and temperature were not controlled. C++ targets use `-O3 -march=x86-64-v3 -mtune=generic`. Zig uses ReleaseFast and vector width 32. Reference packages are pinned but prebuilt; their internal CPU optimization profiles are not known.

These are directional measurements, not publication-grade rankings. Among 144 accepted groups with inputs at least 100,000 bytes, the median largest/smallest process-time ratio was **1.425**, and the worst was **5.104**. The worst group was simdjson JSONL dense validation. Three samples are insufficient to resolve small gains under this noise.

There are five recorded compiler-flag groups: the common flags, plus the four JSONL reference dispatch definitions. The raw reports were not normalized or rewritten.

The current strict comparator keys rows by implementation and requires matching versions. It therefore rejects different libraries with `MissingResult`, even when work profiles agree. It also needs a deliberate identity-versus-environment policy before it can compare parser revisions. The table below is a display of independent measurements, not output from a cross-library ranking mode.

## Selected comparative results

Median decimal MB/s over three processes, **DOM mode, synthetic dense fixture**. Each format has its own input; do not compare rates between formats as if the bytes or work were equivalent. All reference results, other workloads, and rejection latencies remain in the raw reports.

| Format | SIMD MB/s | Selected reference | Reference MB/s | Boundary |
|---|---:|---|---:|---|
| JSON | 20.31 | yyjson | 107.55 | SIMD uses reusable event traversal; yyjson builds a fresh DOM |
| JSONC | 19.14 | jsoncons | 23.89 | Fresh tape/DOM plus checksum |
| JSON5 subset | 11.91 | jsoncons | 25.67 | Comments plus JSON values; not full JSON5 parity |
| JSONL | 2.79 | yyjson | 101.46 | Fresh parsing plus record-framed checksum; different storage strategies |
| Markdown | 90.52 | cmark | 19.99 | Marker-kind projection only; not equivalent full CommonMark work |
| XML | 15.76 | wrapped pugixml | 65.71 | Restricted shared grammar; reference profile checks are timed |
| YAML | 12.18 | wrapped libyaml | 11.85 | Restricted YAML profile; scalars remain strings |

The YAML difference is smaller than observed run noise. Do not claim a winner. Do not claim a full Markdown parser speedup from the marker projection.

## Internal stage and allocation evidence

Three independent internal benchmark processes ran five iterations per case. All 210 stage/workload checksums agreed across processes. The internal `tape` stage includes construction, sampled checksum consumption, and destruction; it is not pure construction time. Resident traversal excludes parser allocation/warmup but includes document initialization/indexing, traversal, and release. Prefix traversal consumes only eight events or EOF.

Dense tape-stage allocator requests, per document:

| Format | Input bytes | Allocation calls | Requested bytes | Requested/input |
|---|---:|---:|---:|---:|
| JSON | 421,719 | 2 | 2,735,472 | 6.49 |
| JSONL | 2,478,977 | 98,314 | 26,931,440 | 10.86 |
| JSONC | 382,108 | 2 | 4,585,308 | 12.00 |
| JSON5 | 382,109 | 2 | 4,585,320 | 12.00 |
| Markdown | 2,299,034 | 1 | 18,392,272 | 8.00 |
| XML | 873,640 | 8 | 1,219,480 | 1.40 |
| YAML | 578,721 | 4 | 10,810,318 | 18.68 |

These are successful allocator requests and growth bytes counted through `init.gpa`, not OS allocation counts or peak resident memory. The external eager SIMD adapters instead use the page allocator, so their absolute timing is a different allocation profile.

JSONL dense contains 49,152 records. Its median internal times were 107.16 ms for validation, 129.85 ms for tape construction/consumption, and 89.90 ms for resident full traversal. Allocation removal alone cannot explain or remove all of that cost.

A 499 Hz user-cycle sample captured approximately 4,000 samples with zero lost samples. Selected flat symbol shares:

| Symbol | Share |
|---|---:|
| `stage2.TokenReader.next` | 9.44% |
| `compiler_rt.memcpy.memcpyFast` | 8.72% |
| `yaml.validateYamlInput` | 5.43% |
| `xml.parseXmlName` | 3.48% |
| `xml.XmlParser.run` | 3.34% |
| `simd.validateUtf8` | 3.28% |
| `yaml.YamlResidentEngine.next` | 3.18% |
| `stage2.validateNumber` | 3.01% |
| `stage2.validateString` | 2.94% |
| `json5.indexJson5Into` | 2.78% |
| `xml.XmlParser.validateData` | 2.51% |
| `yaml.trimCommentEnd` | 2.05% |

This sample mixes formats and stages. Caller attribution for `memcpyFast` was not established. Do not assume those copies come from tokens, reader initialization, or tape shrinkage without a focused profile and generated-code inspection.

## File map and ownership

| Area | Files and responsibility |
|---|---|
| Measurement policy | Packet `CMakeLists.txt`, `bench/runner.hpp`, `scripts/compare.zig`: separate identity from comparable execution conditions |
| Shared JSON tape/reader | `src/core/stage2.zig`: checked index views, reader reset, fixed-capacity tape writes |
| JSONL | `src/formats/jsonl.zig`: record framing, per-record tape ownership, global diagnostics |
| YAML | `src/formats/yaml.zig`: source validation, resident events, structural arrays, tape conversion |
| XML | `src/formats/xml.zig`: names, character/entity validation, duplicate attributes |
| Markdown | `src/formats/markdown.zig`: trusted marker scanner, tape reservation |
| JSON dialect indexing | `src/core/json_lexical.zig`, `src/formats/jsonc.zig`, `src/formats/json5.zig` |
| Streaming measurement | Existing `bench.zig` and `src/core/stream.zig`; format-local Markdown/XML streamers |
| Correctness gates | Existing source tests, `test/root_test.zig`, `test/fuzz_test.zig`, `test/corpus_test.zig` |

Serialize changes to `stage2.zig`. YAML and XML experiments can run independently after the measurement baseline is fixed. Do not split large format modules merely for this performance work.

## Candidate 0: Make small performance changes measurable

**Priority:** Required before accepting a small optimization.

- [ ] Run focused baseline/candidate pairs in alternating order, with at least seven independent processes per side. Keep CPU, vector width, optimization mode, allocator, input hashes, work profile, and checksum consumption identical. Record frequency, temperature, sibling activity, and background load; do not silently change system power settings.
- [ ] Separate comparable execution settings from implementation identity in the packet report policy. Preserve complete source/version/compiler provenance. Default to same-implementation regression comparison; any cross-library mode must explicitly require a common grammar and work contract. Do not globally remove the existing compatibility checks.
- [ ] Reject a small result when process variability can explain it. A confidence interval for the paired time ratio must exclude 1 before calling a speedup. Keep raw process samples, not only aggregate throughput.

**Acceptance:** A repeatable baseline and a comparison policy that permits a recorded parser revision change without ignoring a changed workload, allocator policy, CPU profile, or oracle.

## Candidate 1: Remove duplicate index validation at the shared reader boundary

**Files:** `src/core/stage2.zig`, especially `buildTapeView`, `validateView`, `TokenReader.init`, and `TokenReader.reset`; JSONL callers in `src/formats/jsonl.zig`.

**Evidence:** `buildTapeView` and `validateView` call `view.validateInput`; `TokenReader.init` then calls `reset`, which validates the same view again. JSONL also constructs a checked view for each record. This is repeated work, independent of the uncertain memcpy attribution.

- [ ] Measure JSONL dense validation/tape and JSON dense validation before the change.
- [ ] Test the narrow reordering below: let reader initialization validate before allocation or slicing, then use the reader's bounded source. Keep public validation of caller-supplied views.

```zig
pub fn buildTapeView(
    allocator: std.mem.Allocator,
    input: []const u8,
    view: IndexView,
    dialect: Dialect,
) BuildError!Document {
    var reader = try TokenReader.init(input, view, dialect);
    const bounded_input = reader.input;
    const tape_capacity = if (dialect == .json) view.count() else bounded_input.len;
    var tape = try std.ArrayList(TapeWord).initCapacity(allocator, tape_capacity);
    errdefer tape.deinit(allocator);
    reader.tape = &tape;
    try reader.run();
    return .{ .tape = try tape.toOwnedSlice(allocator), .dialect = dialect };
}

pub fn validateView(
    input: []const u8,
    view: IndexView,
    dialect: Dialect,
) ValidationError!?Diagnostic {
    var reader = try TokenReader.init(input, view, dialect);
    reader.run() catch |err| {
        if (err == error.TapeTooLarge) return error.TapeTooLarge;
        if (err == error.InvalidStructuralIndex) return error.InvalidStructuralIndex;
        return diagnosticAt(reader.input, @errorCast(err), reader.failure_offset);
    };
    return null;
}
```

- [ ] Run existing invalid-view and diagnostic tests. Check that an invalid view still fails before allocation failure and cannot cause an out-of-bounds source slice. Add that precedence regression only if existing tests do not cover it.
- [ ] Profile repeated JSONL reader initialization separately. The resident JSONL reader already reuses `TokenReader.reset`; do not implement that reuse again. Investigate the validation/tape paths and inspect generated copies before changing return-by-value APIs.

**Acceptance:** Same errors, offsets, checksums, ownership, and allocation failure behavior; a repeatable reduction in relevant per-record costs. Do not replace the public checked view with an unchecked alias.

## Candidate 2: Remove JSONL's per-record tape allocation pattern

**Files:** `src/formats/jsonl.zig:519-563`, `src/core/stage2.zig:516-537`, plus all `JsonlDocument`/`JsonlRecord` owners and cursor callsites found with LSP references.

**Evidence:** `buildJsonlTape` already shares the structural index through borrowed `IndexView`s. It still calls `buildTapeView` for every record and stores independently owned documents. The dense workload makes about two allocation calls per record plus aggregate growth.

- [ ] Attribute allocation size/count and shrink/copy behavior on records with 1, 5, and many fields. Do not propose another shared structural index: it already exists.
- [ ] Compare retaining per-record capacity against a document-owned contiguous tape with record spans. The latter requires an explicit ownership/API design: the aggregate owns storage; record views borrow it. Do not add ambiguous owner flags or two deinitialization paths.
- [ ] For a selected design, preserve independently cursorable records, record-local tape links, global diagnostics, source ranges, blank-line rules, CR handling, and the final record without a newline. Exercise nested containers in consecutive records and allocation failure partway through construction.

**Acceptance:** Substantial reduction from 98,314 allocation calls on the fixed dense workload, with bounded aggregate storage and unchanged traversal/checksum behavior. A flat-owner design needs review before implementation because it changes the current ownership contract.

## Candidate 3: Build YAML tape directly from resident events

**Files:** `src/formats/yaml.zig:1167-1229,1621-1649`; `YamlResidentEngine` in the same file.

**Evidence:** `buildYamlTape` first allocates offsets, kinds, and lengths through `parseYamlIndex`, then allocates a tape and copies those arrays into words. Structural capacity is `2 * input.len + 8`; this explains the large fixed reservation. The resident engine already emits the required kind, offset, and raw span.

- [ ] Prototype a tape sink driven by `YamlResidentEngine.next`, using the current emitted token count and the same source validation order. Avoid the three intermediate structural arrays on this path; keep the public index builder unchanged.
- [ ] Check flow/block boundaries, empty values, Unicode and escapes, `u24` span limits, depth limits, unsupported syntax, and failure offsets. Preserve the engine's event order rather than implementing another YAML parser.
- [ ] Compare allocation calls, requested bytes, tape time, and resident traversal. Include sparse and dense files; do not optimize only the dense generator.

**Acceptance:** Lower requested storage than the measured 18.68 times input, no extra parser pass, and no statistically supported time regression. This is independent of the shared JSON tape changes.

## Candidate 4: Accelerate YAML source validation without changing precedence

**Files:** `src/formats/yaml.zig:1231-1284,1386-1460`.

**Evidence:** `validateYamlInput` accounts for 5.43% of the mixed sample; `trimCommentEnd` accounts for 2.05%. The code scans source validity, indentation/line endings, and line syntax in separate passes.

- [ ] Start with a printable-ASCII block fast path in `validateYamlInput`; fall back at controls, DEL, or non-ASCII bytes to the existing scalar rules. Preserve leading/interior BOM behavior and exact invalid UTF-8 offsets.
- [ ] Measure repeated quote/comment/colon scans before attempting to share their lexical results. Do not combine passes if it changes which error wins when an early indentation error precedes a later invalid byte.

**Acceptance:** Correct scalar differential results at vector widths 4, 16, 32, and 64; exact diagnostics across vector boundaries; lower cycles on both plain ASCII and mixed UTF-8 cases. Reject a fast path that penalizes Unicode inputs enough to erase the gain.

## Candidate 5: Reduce XML name and text scanning work

**Files:** `src/formats/xml.zig:1993-2032,2817-2855,2943-2992`.

**Evidence:** Name parsing and data validation are visible hotspots. `decodeXml` already has a single-byte ASCII fast path, so adding another identical branch is not an optimization. Duplicate-attribute checking reparses previous attribute names and values.

- [ ] Measure name-heavy documents with 1, 8, 32, and 128 attributes per element to distinguish ordinary name cost from repeated attribute scans.
- [ ] Prototype direct ASCII name-span classification, with the existing Unicode name rules as fallback. Separately test a bulk text scan that stops at entity, delimiter, control, or non-ASCII boundaries.
- [ ] Preserve duplicate-attribute rejection, entity validity, XML character ranges, `]]>` rules, source-error precedence, and exact diagnostic offsets. Do not replace duplicate checks with a collision-prone hash-only test.

**Acceptance:** Lower XML-local cycles/instructions and stable accepted/rejected corpus results. Any auxiliary attribute storage must have measured benefit over the existing allocation-free scan.

## Candidate 6: Reduce oversized tape reservations

**Files:** `src/core/stage2.zig:525-526,1270-1289`; `src/formats/markdown.zig:720-742`.

**Evidence:** JSONC/JSON5 reserve one tape word per input byte; Markdown does the same and then shrinks. Dense allocation ratios are 12 and 8 times input respectively, including the associated allocations.

- [ ] Derive and test a safe format-specific capacity bound for JSONC and JSON5. Do not replace byte length with structural count without a proof: the dialect index and emitted tape do not have an assumed one-to-one relation.
- [ ] Preserve the fixed-capacity reader contract. It currently returns `TapeTooLarge` when capacity is exhausted and has no allocator for growth. A geometric-growth design would need an explicit allocator/error-contract change, not a one-line capacity reduction.
- [ ] For Markdown, compare a marker-count pass followed by exact allocation against the current single scan. Treat this as a memory/time tradeoff: a smaller allocation is not a speedup if the extra scan dominates.

**Acceptance:** Lower requested storage without valid-input rejection, new out-of-bounds writes, changed allocation errors, or an unaccepted time regression. Keep sparse, dense, escaped, Unicode, and maximum-span cases.

## Candidate 7: Specialize dialect loops and measure streaming boundaries

**Files:** `src/core/json_lexical.zig`, `src/formats/json5.zig`, `src/core/stage2.zig`; existing `bench.zig` and stream indexers.

**Evidence:** JSON5 indexing, identifier/whitespace validation, and dialect-byte processing appear in the mixed profile. Stream timings currently use a fixed 4,096-byte chunk.

- [ ] Inspect generated dialect dispatch first. Specialize only runtime branches that remain in hot loops; do not duplicate branches already removed by comptime specialization. Preserve dialect-specific quote, comment, number, and whitespace rules.
- [ ] Run a chunk-size sweep at 64, 256, 1,024, 4,096, and 16,384 bytes. Keep total bytes, checksums, and framing identical. Include splits inside UTF-8 sequences, backslash runs, CRLF, comments, and XML delimiters.
- [ ] Compare streaming with streaming, and resident full traversal with resident full traversal. An eight-event prefix is neither complete validation nor complete traversal.

**Acceptance:** A measured local bottleneck and a repeatable improvement on its matching profile. Do not start a broad SIMD rewrite from the mixed sample alone.

## Verification and integration gates

For each selected parser change, use existing regression coverage first. Add a permanent test only for an uncertain observable boundary, transition, error precedence, or lifetime rule. Allocation instrumentation and benchmark drivers can remain experiment artifacts instead of permanent tests.

From the parser repository, after each independent accepted change:

```sh
zig build
zig build test
zig build corpus
zig build test -Dvector_len=4
zig build test -Dvector_len=16
zig build test -Dvector_len=32
zig build test -Dvector_len=64
```

`zig build test` includes deterministic Smith fuzzing. Retain all fixed seeds. Build and smoke the corresponding external adapters against the new clean parser snapshot, then run paired measurements with matching work profiles. Keep one focused jj change per accepted optimization; discard unsuccessful experiments without touching the user's original dirty work.

Recommended order: measurement policy, duplicate index validation, JSONL ownership experiment, YAML direct tape, then independent YAML/XML byte-loop work. Reservation and dialect/stream experiments follow only where the focused measurements justify them.

## Evidence and reproduction

All paths below are under `~/simd-bench-corpus/results/2026-09-09-seven-format/`.
They are a historical record from the original host and are not present in this
checkout. The list names them so the evidence stays traceable; it does not
claim they can be opened here:

- `full/index.json`: exact commands, start times, selectors, report paths, and exit codes for 240 runs.
- `full/*.json`: full timing, checksum, dependency, compiler, source, CPU, and corpus provenance.
- `full/failures.json`: empty array after the measured run.
- `comparative-summary.json`: 302 groups with three-process medians, minima, maxima, and work profiles.
- `comparison-checks.json`: 80 successful strict same-implementation batch comparisons.
- `internal-stages-{1,2,3}.csv`, `internal-summary.json`: internal stage samples and medians.
- `allocation-findings.json`: dense allocation requests.
- `internal.perf.data`, `internal-hotspots.txt`: flat sample evidence.
- `environment.json`: recorded machine conditions.
- `matrix-driver.py`: the exact experiment driver; accepts output label, process-batch count, and repeat count. The driver reverses order on alternate batches and checks CPU affinity and error rows.

From the packet directory, reproduce the matrix in a separate result subdirectory:

```sh
python3 results/2026-09-09-seven-format/matrix-driver.py rerun 3 5
```

The driver uses the existing `build-current` binaries. Rebuild against a clean, pinned source snapshot first when code changes. Do not overwrite the baseline `full` directory.

## Local reproduction contract

The comparison packet is not part of this repository, so no command here
recreates the external C++ reference results recorded above. `zig build bench`
in this repository measures this parser only, under a fixed contract that any
new local recording must preserve:

- 7 formats (JSON, JSONL, JSONC, JSON5, Markdown, XML, YAML) times 5 workloads
  times 6 stages is 210 stage rows over 35 input hashes.
- Markdown rows are a marker-kind projection, not a CommonMark parse. There is
  no `formats.commonmark` benchmark row.
- YAML rows are the `yaml-basic-1.2.2` profile. There is no
  `yaml-extended-e2b-1.2.2` benchmark row.
- The resident `traverse_prefix8` stage consumes eight events or EOF. It is
  neither full validation nor full traversal.
- The internal `tape` stage includes construction, sampled checksum
  consumption, and destruction. It is not pure construction time.

These limits are why a local run may not be reported as a recreated
comparison, and why no ranking of the semantic CommonMark parser or the
extended YAML profile may be derived from this harness. A new local recording
adds rows; it does not restore the packet. Record a recovery status only where
an owner has supplied the evidence for it.

### The record, verify, reproduce CLI

The owner approved a new local baseline. `scripts/benchmark.zig` records it.
The runner receives `[runner, bench_executable_path, repository_root_path,
operation, operation_args...]`:

```sh
zig build benchmark -Doptimize=ReleaseFast -Dvector_len=32 -- record OUT_DIR [--samples N] [--iterations N] [--stream-chunk-size N]
zig build benchmark -Doptimize=ReleaseFast -Dvector_len=32 -- verify ARCHIVE_DIR
zig build benchmark -Doptimize=ReleaseFast -Dvector_len=32 -- reproduce OLD_ARCHIVE_DIR NEW_ARCHIVE_DIR
```

Defaults are 3 samples, 3 iterations, and a 4096-byte stream chunk. Samples
and iterations are decimal integers from 1 to 32; stream chunk size is one of
64, 256, 1024, 4096, or 16384. A flag may appear once. An unknown flag, a
missing value, an out-of-range value, or an extra positional prints usage on
stdout and exits 1.

`zig build benchmark-test` runs the script's behavior tests, and `zig build
check` includes them.

**Immutable archive.** `record` creates `OUT_DIR` with an exclusive mkdir and
creates every archive file exclusively, so a recording is immutable evidence:
an existing output directory or file is a failure, never a truncation, and an
earlier recording cannot be silently replaced. A failed run still writes
`manifest.json` with `"status":"failed"` and a `reason` naming the failure
before exiting 1, so a partial run is never published as complete. A successful
run records `"status":"complete"`, and `verify` reports a failed archive as
failed rather than as incomplete evidence. An archive holds `manifest.json`,
`bench/simd-bench`, `samples/sample-NN.stdout` and `samples/sample-NN.stderr` per
sample, and `sources/<repo-relative path>` for the captured sources.

**Manifest.** `manifest.json` records the schema and version, the status and its
reason, the unix timestamp, the effective options, the work shape
(`expected_inputs` 35, `expected_cases` 210), the compiler
basename, version, and executable SHA-256, the build's target, cpu, optimize,
and vector length, the
archived binary and every captured source and payload file with sizes and
SHA-256 values, the recorded environment, the verbatim benchmark headers, and
the per-input identity and byte count. Identity is a repository-relative source
path plus a content hash, never an absolute workstation path, so it survives a
move to another machine. The manifest records the Zig basename, version, and
executable SHA-256 rather than a Zig path. Every input records the identity and
byte count the benchmark reports, whether it came from a fixture or a generated
workload.

Execution identity is the benchmark executable the current build provides, read
from the `benchmark_options` module (`zig_exe`, `bench_target`, `bench_cpu`,
`bench_optimize`, `bench_vector_len`). An archived manifest may describe an
executable, but it may not select one: reproduction runs the build-provided
executable and never an arbitrary path named by archived or otherwise
untrusted data.

**Verification and reproduction.** `verify ARCHIVE_DIR` re-checks one archive.
`reproduce OLD NEW` verifies the old archive offline, preflights the current
source path set and hashes, the benchmark executable hash, the Zig version,
basename and executable SHA-256, the build configuration, and the CPU identity.
It records a new archive
with the old archive's options, and compares the two case by case on
`input_hash`, `input_bytes`, `checksum`, `allocation_count`, and
`allocated_bytes`, plus the headers and input identities. Any mismatch exits 1.
Reproduction is an exact-match claim over identity and results.

**What is not claimed.** The retained per-case `elapsed_ns` timing arrays are
never part of the reproduction comparison, never ranked, and never printed as a
ranking; `verify` re-derives each of them from the archive's own captured
stdout, so a recorded timing the capture does not contain fails verification
with `ManifestIncomplete`. A sample entry carries no timing of its own: the
retired per-sample `elapsed_ns` key is no longer written, an older archive that
still carries it still verifies because the manifest decoder ignores members it
does not read, and `schema_version` stays 1. Timings in a recording are
observations from the machine that produced
them. They are not compared against another library and are not a winner. Exact
match is the reproducibility claim; timing is not.

## Implemented optimization wave

The isolated workspace for that wave was `~/projects/simd-performance`,
which is not present in this checkout. The original
dirty checkout was not edited. Public tape ownership, source borrowing, dialect
rules, and cursor APIs are unchanged.

- Shared readers validate external views once, before allocation or slicing.
  In-place reader reset removes a confirmed 16,384-byte return-value copy.
- Strict JSON reserves the exact emitted word count. JSONL retains independently
  owned record tapes but no longer shrinks each one. JSONC and JSON5 use a proven
  conservative bound instead of one word per source byte.
- YAML builds its tape directly from resident events. The public structural
  index builder is unchanged. Source validation skips printable ASCII blocks;
  scalar fallback consumes the failed block instead of repeatedly loading
  overlapping vectors. The previous input-size and error-order limits remain.
- XML scans ASCII names and ordinary text in bulk, with existing Unicode,
  entity, and duplicate-attribute checks. Narrow masks are normalized before
  trailing-zero extraction; the four-byte corpus gate caught this boundary.
- Markdown uses one trusted scan and a bounded growable tape. The exact-size
  two-pass experiment was rejected after repeated timing regressions.
- Existing dialect loops were already specialized; no duplicate lexer was added.
  `zig build bench -- 5 --stream-chunk-size 1024` selects streaming chunks.
  Supported sizes are 64, 256, 1024, 4096, and 16384; default remains 4096.

Final internal measurements use seven alternating process pairs, five iterations
per case, ReleaseFast, vector width 32, and logical CPU 2. All 210 case checksums,
input byte counts, and iteration counts match within their respective profiles.
Streaming is compared with streaming; resident full traversal is compared with
resident full traversal, not with the eight-event prefix.

Dense tape results, including sampled consumption and destruction:

| Format | Baseline requested bytes | Candidate requested bytes | Median candidate/baseline time |
|---|---:|---:|---:|
| JSON | 2,735,472 | 2,211,192 | 0.815 |
| JSONL | 26,931,440 | 18,673,904 | 0.723 |
| JSONC | 4,585,308 | 2,052,748 | 0.951 |
| JSON5 | 4,585,320 | 2,052,752 | 0.899 |
| Markdown | 18,392,272 | 2,129,920 | 0.844 |
| XML | 1,219,480 | 1,219,480 | 0.627 |
| YAML | 10,810,318 | 572,680 | 0.550 |

JSONL dense allocation calls fall from 98,314 to 49,162. The focused 512-record
probe falls from 1,033 to 521 calls for each of the 1-, 5-, and 32-field cases.
YAML and Markdown trade larger reservations for growth; requested bytes are
not peak RSS. Markdown fixture storage is unchanged.

Timing remains noisy: the host was not isolated, and background load, SMT sibling
activity, and temperature were not controlled. XML tape ratios stay below one in
all seven pairs for all five workloads. YAML dense ratios range from 0.393 to
0.646. JSONL dense and Markdown dense ranges cross one; their displayed medians
are not claims of a resolved speedup. No blanket speedup is claimed for JSONC,
JSON5, Markdown, or Unicode YAML. Keep the memory reductions distinct from timing.

Historical verification, not a current-machine result: `zig build` passed.
`zig build test corpus` passed 382/382 tests at each of vector widths 4, 16,
32, and 64, including fixed-seed fuzzing.
The final five-size chunk sweep checked 1,050 stage rows against the baseline;
all checksums match. Missing and unsupported chunk values fail. The 382/382
count and that width set describe that host. Do not restate them as this
checkout's result, and do not present the current width gate as `[4, 16, 32,
64]`: `zig build check` sweeps `[4, 5, 7, 12, 16, 24, 32, 64]`.

Historical evidence, not present in this checkout, was collected under
`~/simd-bench-corpus/results/2026-09-09-priorities-2-5/`:
`accepted-paired-*.csv`, `accepted-summary.json`, `accepted-chunk-*.csv`,
`reader-copy-attribution.txt`, and the focused JSONL/XML probe outputs.
Earlier `initial-paired-*`, `final-paired-*`, and `final-summary.json` describe
the rejected two-pass Markdown binary. `single-pass-paired-*` precedes the final
YAML fallback correction. Only the `accepted-*` series describes the final source.

External integration also passed: the declared Nix environment completed the
full Release build in `build-performance` against the clean parser snapshot.
All seven CTest targets passed. A 56-invocation baseline/candidate smoke matrix
covered all seven native adapters, both modes, and both corpus groups. Its 106
case pairs match source hashes, byte counts, outcomes, checksums, work profiles,
preparation policies, timed iteration counts, and CPU affinity. See
`external-checks.json` and `external-*.json`. This is correctness smoke evidence,
not an external timing ranking or a change to the packet comparator policy.

Focused XML counters over the attribute/text probe decreased from 12.675 to
3.007 billion user cycles and from 21.642 to 10.606 billion retired instructions.
The combined probe includes validation and tape consumption; see
`xml-counters.json` for exact commands.

Seven additional paired YAML validation probes exercised long printable spans.
Median candidate/baseline user-cycle ratios were 0.770 for ASCII and 0.815 for
mixed UTF-8; instruction ratios were 0.793 and 0.856. Every pair improved.
The separate 32-byte-line boundary probe had neutral ASCII timing and about
0.7% more instructions: it cannot skip a full printable block. These results
bound the claim to inputs with useful printable spans. Sources and raw counters
are in `yaml-validation-probe.zig` and `yaml-validation*-counters.json`.

`reproduce-pairs.py` checks archived executable hashes, alternates process order,
and verifies all 210 cases and 35 input hashes per pair. Its standalone
`reproduction-check` run passed all seven pairs. `accepted-identity.json` records
the final executable hashes and measurement limits.
