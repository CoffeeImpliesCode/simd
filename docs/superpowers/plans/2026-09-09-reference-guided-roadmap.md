# Reference-guided parser roadmap

## Document status

The plan is retained as written, and the implementation record at the end is
the shipped summary. Both are historical: the packet, workspace, and snapshot
paths they cite are not present in this checkout.

- The `~/...` packet, workspace, and snapshot paths are historical
  records. They have not been relocated, and no substitute location is claimed
  for them.
- The `MEASURED` and `SOURCE FACT` labels below describe that run on that host.
  They are not current-machine results and support no new performance ranking.
- A pass count such as `482/482` and a native width of 32 on an AVX2 host
  describe that host. This checkout's own observation, recorded on 2026-10-01 on
  an AVX-512 host, is `zig build check -j2 --summary all` passing 128 of 128
  build steps and 4445 of 4445 tests, with a native width of 64; see `AGENTS.md`.
- The external C++ reference adapters live outside this repository. No command
  here recreates their results; `zig build bench` measures this parser only,
  over 7 formats x 5 workloads x 6 stages, with Markdown rows limited to a
  marker-kind projection, YAML rows limited to `yaml-basic-1.2.2`, and a
  resident `traverse_prefix8` stage that is neither full validation nor full
  traversal. It has no `formats.commonmark` or `yaml-extended-e2b-1.2.2` row.
- The packet was searched for and not found. Local filesystem and archive
  searches found no packet source or result history; the authenticated
  owner-repository listing exposed only the private `CoffeeImpliesCode/simd`;
  the authenticated `simd-bench-corpus` API returned 404; the recorded packet
  commits are absent; and no SSH recovery host is configured.
- The approved response is a NEW LOCAL BASELINE, not recovery of the packet.
  `scripts/benchmark.zig` records this repository's own parser measurements
  through a shared `record`, `verify`, and `reproduce` CLI, documented in the
  [parser performance plan](2026-09-09-parser-performance.md). That baseline
  is a fresh record: it restores no packet result, makes nothing below
  reproducible again, and claims no ranking.
- That baseline is the 2026-10-01 recording from source identity
  `fcdb7c0e7c8719fb9fd22385aecee9d3998d36317a40950e36fa55c108fb9c49`:
  `zig-out/bench-evidence/acceptance-closed-20261001` (ReleaseFast,
  `-Dvector_len=32`, 3 samples, 3 iterations, 4096-byte chunks),
  `acceptance-closed-reproduce-20261001` recorded from it with every input and
  case identical, and `acceptance-closed-chunk256-20261001` at 256-byte chunks
  with 1 sample. Each verifies over 35 inputs and 210 cases. It is a new
  record, not a recovered packet result, and it ranks nothing.
- The `033b3923` family (`baseline-final-20261001`,
  `reproduce-final-20261001`, `chunk256-final-20261001`) and the earlier
  `76f4b3b4` family (`baseline-20261001`, `reproduce-20261001`,
  `chunk256-20261001`) are immutable historical recordings: their captured
  sources have since been edited, so neither is the current source
  reproduction baseline, and none is overwritten or deleted.

## Scope and decision

This document combines the independently reviewed reference studies for strict JSON, JSONL, JSONC,
JSON5, Markdown, XML, and YAML. The plan is followed by an implementation record
that distinguishes shipped contracts from rejected experiments.

**DECISION:** The implementation order is deliberate:

1. Correct the measurement domain and checksum oracles.
2. Remove repeated JSON-family checksum decoding.
3. Run the same-work JSONL allocator ablation.
4. Prove private tape-consumption and ownership changes.
5. Optimize measured number, lexer, name, and index work.
6. Add useful parity through explicit APIs and profiles only.

Do not start with a blanket SIMD rewrite. Do not add broad DOM features to a compact parser only
because a reference library has them.

## Evidence rules

The following labels are normative in this document:

- **MEASURED**: a value from the fixed comparison or profile packet.
- **SOURCE FACT**: behavior established from the inspected pinned source.
- **INFERENCE**: an explanation that needs a controlled experiment.
- **DECISION**: the selected plan or boundary. It is not a measured result.

For accepted input, a ratio is reference throughput divided by native throughput. For rejected input,
a ratio is native elapsed time divided by reference elapsed time. A ratio above `1.05` favors the
reference. A ratio below `0.95` favors native. The `0.95` through `1.05` band is descriptive. It is not
a significance test.

**SOURCE FACT:** every raw result row completed 100 timed iterations. A rejected comparison
`median_elapsed_ns` is the median batch time. Any reported latency per rejection must divide that
median by 100. It must not use one raw sample as the comparison median.

**MEASURED:** the packet contains 196 comparisons over 302 underlying groups, 240 raw invocations,
and 906 raw result rows. The profile verification covers 30 profiles and 192 verified result rows,
with zero lost samples.

**MEASURED:** profiles sample whole-process user cycles. They include runner, adapter, parser,
checksum or traversal, allocation, and destruction work. Flat `--no-children` overhead is self work.
Nested call chains locate callers and inlined work; they are not extra additive shares. Profile shares
do not decompose a cross-process speed gap. XML priorities use the high-repeat deep profiles
(`repeat: 66` native and `repeat: 172` reference, about 1,000 samples each), not the 55- and 21-sample
initial tables.

**SOURCE FACT:**
`~/simd-bench-corpus/results/2026-09-09-reference-analysis/source-provenance.json`
shows that the benchmark snapshot and parent `24edee4b` have identical native source, build, and test
content. Only the prior performance plan changed from
`329dc3a0e611f45021bb163b7c1a8e95139378b0`. The results are not a pre-optimization baseline merely
because the commit IDs differ. Any later source or build change requires a new provenance record and
a new comparison packet.

**SOURCE FACT:** the benchmark executable used the recorded x86-64-v3 build. The CPU build flags for
every packaged reference dependency are not established. Do not claim equal dependency code
generation without that evidence.

## Evidence index

Format studies:

- [Strict JSON](2026-09-09-reference-json.md)
- [JSONL](2026-09-09-reference-jsonl.md)
- [JSONC and JSON5](2026-09-09-reference-dialects.md)
- [Markdown](2026-09-09-reference-markdown.md)
- [XML](2026-09-09-reference-xml.md)
- [YAML](2026-09-09-reference-yaml.md)

Shared evidence (historical paths on the original host, not present in this
checkout; the names are kept for traceability and are not claims that these
files can be opened here):

- Benchmark contract:
  `~/simd-bench-corpus/docs/superpowers/specs/2026-09-09-seven-format-profiles.md`
- Coverage:
  `~/simd-bench-corpus/results/2026-09-09-reference-analysis/coverage-summary.json`
- Profile verification:
  `~/simd-bench-corpus/results/2026-09-09-reference-analysis/profile-verification.json`
- Source provenance:
  `~/simd-bench-corpus/results/2026-09-09-reference-analysis/source-provenance.json`
- JSONL process attribution:
  `~/simd-bench-corpus/results/2026-09-09-reference-analysis/jsonl-process-attribution.json`
- JSONL syscall counts:
  `~/simd-bench-corpus/results/2026-09-09-reference-analysis/jsonl-memory-syscalls.json`
- XML deep profiles:
  `~/simd-bench-corpus/results/2026-09-09-reference-analysis/deep-profiles.json`
- Shipped baseline work:
  [Parser performance plan](2026-09-09-parser-performance.md)

## Coverage and comparison domains

The eight distinct reference libraries are simdjson 4.6.5, yyjson 0.12.0, RapidJSON
1.1.0-unstable-2025-02-05, nlohmann/json 3.12.0, jsoncons 1.9.0, cmark 0.31.2,
pugixml 1.16, and libyaml 0.2.5.

| Format | Reference libraries | Accepted / rejected comparisons | Reference faster | Native faster | Neutral |
|---|---|---:|---:|---:|---:|
| Strict JSON | simdjson, yyjson, RapidJSON, nlohmann/json | 56 / 8 | 48 | 16 | 0 |
| JSONL | simdjson, yyjson, RapidJSON, nlohmann/json | 48 / 8 | 50 | 6 | 0 |
| JSONC | jsoncons | 12 / 2 | 10 | 2 | 2 |
| JSON5 | jsoncons common subset | 10 / 2 | 12 | 0 | 0 |
| Markdown | cmark | 10 / 0 | 6 | 3 | 1 |
| XML | wrapped pugixml | 10 / 14 | 24 | 0 | 0 |
| YAML | libyaml | 10 / 6 | 6 | 10 | 0 |

The direction columns count all comparison rows. They do not imply semantic equivalence outside each
fixed profile.

| Format | Timed contract and important boundary |
|---|---|
| Strict JSON | Typed checksum over decoded strings and typed numbers. Duplicate keys and nonfinite values are outside the shared domain. Native validate uses an event stream; each reference validate path builds a DOM. |
| JSONL | Strict LF-framed records. Physical empty lines are skipped. Whitespace-only records are outside the ranked domain because native and references differ. The checksum includes ordinal, source byte length, and the strict typed JSON checksum. |
| JSONC | Comments under the restricted native grammar; trailing commas are rejected in this profile. Native accepts comments after the root and rejects invalid UTF-8 in comments; jsoncons differs. These differences are not ranked. |
| JSON5 | The ranked reference is a jsoncons common subset, not full JSON5. Native-only single quotes, unquoted keys, hex, dotted numbers, nonfinite values, Unicode whitespace, and line continuations are not measured as parity with jsoncons. |
| Markdown | The native result is a contextual marker projection. Marker checksums agree, but cmark builds CommonMark block and inline semantics while native stores marker words. The AST and tape semantics are not equivalent. CommonMark has no syntax-rejection rows. |
| XML | The reference is wrapped pugixml, not bare pugixml. Timed wrapper checks restrict entities, roots, duplicate attributes, and depth. Native also enforces UTF-8, XML character, and full XML Name rules that pugixml does not. |
| YAML | The ranked profile is restricted `yaml-basic-1.2.2`, not general YAML. The libyaml adapter rejects unsupported cases in a prefilter before parser setup. Those rejected rows are adapter rejection, not libyaml parser rejection. |

## Direction reversals and their meaning

The table lists every material direction reversal or band transition in the reviewed packet.

| Format and reference | Validate or accepted direction | DOM or other direction | Evidence-backed reading |
|---|---|---|---|
| Strict JSON, RapidJSON | Native wins sparse (`0.327`), escaped (`0.751`), and Unicode (`0.273`). | RapidJSON wins the same three in DOM (`2.805`, `3.606`, `2.983`). | **SOURCE FACT:** RapidJSON builds a fresh `GenericDocument` and pooled decoded strings. Native DOM adds typed checksum decoding over borrowed raw spans. **INFERENCE:** the extra native traversal changes the balance; a phase split must quantify it. |
| Strict JSON, nlohmann/json | Native wins all eight validate cases. | nlohmann wins sparse (`1.249`), escaped (`1.191`), and Unicode (`1.252`), while native still wins the other five. | **SOURCE FACT:** nlohmann validate builds `std::map`, vectors, and strings. Native DOM decodes strings for the checksum. **INFERENCE:** decoded representation helps nlohmann only on the three string-heavy shapes. |
| JSONL, RapidJSON | Native wins sparse validate (`0.71`). | RapidJSON wins sparse DOM (`3.73`). | **SOURCE FACT:** native retains a tape for every record and DOM adds aggregate checksum traversal. RapidJSON destroys each record DOM after use. **INFERENCE:** representation lifetime may change the result; allocator and traversal ablations must separate it from LF scanning. |
| JSONL, nlohmann/json accepted | Native wins sparse, escaped, Unicode, and real validate (`0.28`, `0.76`, `0.48`, `0.47`). | nlohmann wins those DOM rows (`1.69`, `1.87`, `1.80`, `1.24`). | **INFERENCE:** native per-record allocation and checksum work erase its validate advantage. The allocator ablation and reusable-record profile must test the two causes separately. |
| JSONL, nlohmann/json rejected | Reference is faster in validate (`1.21`). | Native is faster in DOM (`0.64`). | **SOURCE FACT:** neither path traverses after rejection. This is a mode-run reversal, not a traversal result. Treat it as fixed-cost or run variation until a matched latency rerun resolves it. |
| JSONC, jsoncons | Native wins sparse (`0.613`) and Unicode (`0.587`) validate; dense (`1.005`) and real (`0.997`) are neutral. | jsoncons wins all DOM cases; sparse is `4.194` and Unicode is `3.613`. | **SOURCE FACT:** both sides build a representation in validate, but native skips checksum traversal. Native DOM decodes each string twice. Split build, traversal, checksum, and destruction before a lexer change. |
| Markdown, cmark | Native wins Unicode (`0.881`); escaped is neutral (`1.003`). | cmark wins Unicode (`1.154`) and escaped (`1.099`). | **SOURCE FACT:** native DOM replays `validateMarkdownTape`, scans again, and checks each cursor word repeatedly. This bridge-only duplicate work is the first marker-path target. |
| YAML, libyaml | Native wins every accepted validate and DOM row (`0.194` through `0.840`). | libyaml wins every rejected row. | **SOURCE FACT:** the adapter prefilter rejects the three unsupported shapes before libyaml setup, while native enters source validation and tape construction. Do not add fixture-specific early exits or call these rows parser speed. |

There is no implementation-direction reversal for simdjson, yyjson, jsoncons JSON5, or wrapped
pugixml. JSON5 and XML favor the reference on every row. Wrapped pugixml has one internal anomaly on
the 181-byte real fixture: reference DOM reports 116.85 MB/s and reference validate reports 89.74
MB/s even though DOM does more work. A matched alternating rerun is required; this is not a native
parser claim. cmark remains slower on dense marker input in both modes (`0.151` validate and `0.233`
DOM). This does not show that native implements CommonMark faster.

## Cost model by reference library

| Library | Representation, allocation, decoding, validation, and API cost | Roadmap consequence |
|---|---|---|
| simdjson | Reuses a parser, creates a padded input copy, and builds decoded DOM tape/string state. JSONL repeats that per record. Its structural and string paths are highly optimized. | Do not copy its DOM design. First remove native checksum duplication and JSONL record-allocation topology. |
| yyjson | Builds a fresh compact document and string pool, then frees it. JSONL repeats `yyjson_read_opts` and `yyjson_doc_free` per record. | Its speed despite fresh ownership makes native page mappings and repeated tape retention suspect; prove this with same-work allocation data. |
| RapidJSON | Builds a fresh `GenericDocument` with `MemoryPoolAllocator`. String parsing dominates its measured validate and DOM profiles. | Native already wins some validate shapes. Preserve that path and isolate only native DOM checksum and ownership costs. |
| nlohmann/json | Uses owning `std::map`, vector, and string objects plus exception-based parse handling. This is expensive in validate, but traversal receives decoded values. | Do not add an owning tree for speed. Offer decoded views with caller storage and keep raw borrowed events. |
| jsoncons | Builds an owning DOM in validate and DOM. It supports broader number and cursor facilities, but the JSON5 benchmark exercises only a common subset. | Fix the native checksum oracle first. Preserve JSONC and JSON5 grammars; do not weaken UTF-8 checks or copy unmeasured bignum modes into the fast path. |
| cmark | Builds blocks, inlines, references, consolidated text, and an AST. Reference-map setup is timed, but definition normalization and reference resolution are not exercised by these fixtures. Native stores marker words only. | Keep marker optimization and semantic CommonMark work in separate modules, checksums, and work profiles. |
| pugixml | The timed wrapper prechecks the restricted domain. `load_buffer` then allocates and copies to mutable private storage; pugixml decodes in place and uses 32 KiB pooled DOM pages. | Preserve native zero-copy strictness. Remove only proven repeated checks behind private eager boundaries. Keep public corruption checks. |
| libyaml | Initializes a general scanner/parser/composer with queues, stacks, tags, owned document nodes, and decoded scalar storage. The timed prefilter narrows the accepted grammar. | Keep the compact restricted event tape. Add broader YAML features only through explicit extension profiles and bounded ownership. |

**MEASURED:** strict native DOM flat self samples place `Hasher.addDecodedString` at 52.09% and
`JsonStringDecoder.next` at 23.37%. JSONC and JSON5 show the same duplicated checksum shape.

**MEASURED:** the JSONL whole process reports 0.684266 s user and 1.439395 s system time for native,
compared with 0.147374 s user and 0.004937 s system for yyjson. A separate traced run counts 200,090
native memory-management syscalls versus 44 for yyjson. The tracer perturbs execution, and the two
measurements are separate. These values do not assign a causal speed fraction.

**MEASURED:** the XML deep native profile places `validateData` at 18.25%, `buildXmlTape` at 15.83%,
`parseXmlName` at 10.05%, benchmark entity parsing at 8.41%, and
`hasPreviousXmlAttribute` at 2.32%. Use these as task-order clues, not additive gap shares.

**MEASURED:** the Markdown deep profile places benchmark export work at 27.50%, tape construction at
24.09%, chunk iteration at 16.35%, and `MarkdownCursor.currentWord` at 12.97%. The call chain includes
`root -> validateMarkdownTape -> scanMarkdown`.

## Invariants that every stage must preserve

1. `src/core/stage1.zig:StructuralIndex` keeps `u32` source offsets and the current three sentinels:
   `input_len`, `input_len`, and zero. No task may silently change index width or sentinel order.
2. `src/core/stage2.zig` keeps record-local root and container links. The packed JSON `TapeWord` remains 64 bits (`kind` u8, `payload` u24, `offset` u32); record-local payload and offset bounds must not wrap. Eager tape emission returns `TapeTooLarge` when a payload exceeds u24, while raw-span/on-demand validation keeps its checked oversized-span behavior. A JSONL aggregate must never expose record-local links as global tape indexes.
3. Markdown keeps the packed kind, 24-bit marker length, and 32-bit source offset. YAML keeps its
   packed kind, 24-bit payload, and 32-bit source offset. XML keeps its eight-byte event tape unless a
   separate representation profile is approved.
4. Parsed strings, names, and scalar spans remain borrowed from caller input unless an API explicitly
   returns caller-owned or document-owned decoded storage. The owner and lifetime must be in the type
   contract.
5. Public tapes and caller offsets are mutable or forgeable. `[]const u8`, pointer plus length, a
   Boolean, or `source_error == null` does not prove provenance or immutability.
6. Public mutation, bounds, source-identity, and diagnostic checks remain. A faster path must be
   private to the producer and immediate consumer, or it must own immutable storage and prevent a
   mutable alias.
7. The one-active-document lease on resident or on-demand parsers remains explicit. Reset, failure,
   and deinit must release it exactly once.
8. Same-checksum inner-loop work keeps its current work profile. Changed promised work, representation
   retention, or preparation policy gets a new profile and cannot rank against the old profile.
9. Ranked restricted grammars remain restricted. New syntax is opt-in. No task may silently broaden
   JSONC, JSON5, Markdown, XML, or YAML acceptance.
10. Outcome, checksum, first error class, byte offset, line, column, resource limits, and allocation
    cleanup are acceptance criteria, not secondary checks.

## Risk-ordered implementation plan

Run one numbered stage at a time. Rebuild the complete evidence packet after each source stage. A
failed gate stops that branch; it does not justify a broader rewrite.

### 0. Correct domains, oracles, and profile routing

**Boundary:** benchmark and evidence code only.

**Targets:**

- `~/simd-bench-corpus/zig/json_family_api.zig:161-322`:
  `decodeChunk`, `encodeCodepoint`, and JSON5 line-continuation handling.
- `~/simd-bench-corpus/bench/json_family_adapter_test.cpp:78-117`.
- `~/simd-bench-corpus/bench/common.hpp:194-217`:
  `work_profile_label`.
- `~/simd-bench-corpus/bench/common.hpp:220-239`:
  `parse_work_profile`.
- `~/simd-bench-corpus/bench/runner.hpp:951-1008`:
  work-profile and preparation validation.
- `~/simd-bench-corpus/scripts/compare.zig:21-39,387-414`:
  `WorkProfile` and `profileMatchesReport`.

**Plan:**

1. Repair benchmark JSON5 checksum handling for non-ASCII `\xHH`. Hash the UTF-8 encoding of
   U+0000 through U+00FF, as for the corresponding `\u00HH` value.
2. Remove LF, CR, CRLF, U+2028, and U+2029 JSON5 line continuations from decoded checksum bytes.
3. Treat this as benchmark-oracle repair. Do not claim that it fixes a production JSON5 parser bug.
4. Add unranked compatibility probes for JSONC and JSON5 comments before, within, and after the root;
   invalid UTF-8 in comments; JSON5 extension strings; and trailing comments. Do not mix known native
   and jsoncons domain differences into ranked rows.
5. Add unranked XML probes for invalid UTF-8, invalid Unicode Names, raw `<` in attributes, malformed
   comments, declaration order, and the native 1,024-frame versus wrapper 256-depth boundaries.
6. Keep Markdown malformed-looking documents as accepted throughput. Report only explicit resource
   failures under a resource-error profile.
7. Route every genuinely new profile through all producers and both consumers listed above. A string
   label without comparator and report validation is incomplete.

**Gate:** `\xE9`, `\u00E9`, and literal `é` have equal JSON5 hashes. Every accepted continuation hashes
like the joined string. ASCII `\x21` remains unchanged. Existing ranked input hashes, outcomes, and
checksums remain fixed. Every report records compiler, linker, CPU, work profile, preparation policy,
iterations, and source provenance.

### 1. Decode JSON-family checksum strings once

**Boundary:** benchmark checksum first; public parser behavior unchanged.

**Targets:**

- `~/simd-bench-corpus/zig/bench_api.zig`: `Context`,
  `Hasher.addDecodedString`, `JsonStringDecoder.next`, `decodedStringLength`, `hashString`,
  `simd_bench_context_required_scratch`, and `simd_bench_context_init`.
- `~/simd-bench-corpus/zig/json_family_api.zig`: its decoder twin,
  `Hasher.addDecodedString`, `addTapeChecksum`, `checksumDocument`, `runDocument`, and `runJsonl`.

**Plan:**

1. Add an allocation-free raw fast path when a string has no backslash. Hash `raw.len` and raw bytes.
2. In strict JSON, decode an escaped string once into scratch owned by the existing reusable
   `bench_api.Context`. Extend the explicit required-scratch formula and context initialization if
   needed. The scratch must not overlap live structural indexes.
3. JSONC, JSON5, and JSONL use fresh adapter calls. Any escaped-string buffer must allocate, grow, and
   free inside the timed call. Otherwise, retain the current two-pass path. A prepared family context
   requires a distinct preparation policy and profile.
4. Keep tag, little-endian decoded-length field, decoded bytes, object order rules, and number typing
   byte-for-byte identical.

**Gate:** all accepted checksums match the current oracle, including empty strings, simple escapes,
NUL, BMP, surrogate pairs, raw UTF-8, keys, values, and maximum supported lengths. Validate mode has
no path or allocation change. Accept only a repeatable DOM improvement outside the band on at least
one escaped, Unicode, dense, or real case, with no DOM case slower outside the band. Re-profile the
changed checksum path. Do not add old flat shares to claim closed gap.

### 2. Run the same-work JSONL allocator ablation

**Boundary:** adapter allocation backing only. Parser work and retention stay identical.

**Targets:**

- `~/simd-bench-corpus/zig/json_family_api.zig:runJsonl`,
  `simd_bench_jsonl_validate`, and `simd_bench_jsonl_dom`.
- `~/simd-bench-corpus/bench/adapters/simd_json_family.cpp`:
  `make_simd_jsonl_adapter`.
- `~/simd-bench-corpus/zig/build.zig:102-116`: `api_module`.
- The matching CMake target.

**Plan:** compare `std.heap.page_allocator` with `std.heap.c_allocator` under separate selectors. Keep
`buildJsonlTape`, global Stage 1, per-record Stage 2, retain-all metadata and tapes, checksum order,
and destruction order unchanged. First enable libc consistently for `api_module` and the matching
CMake/C++ target; record that setup as a new build identity outside the allocator result.

The allocator remains inside one C call. Input is borrowed. Every allocation dies before return.
Record logical capacity requests and lifetime order separately from physical `alloc`, `resize`,
`remap`, `free`, and allocate-plus-copy events. Physical event counts can differ because
`ArrayList.toOwnedSlice` tries allocator remap first. Do not reject a valid ablation only because
`mremap` and `realloc` behavior differ.

**Gate:** outcomes and checksums are identical; a syntax rejection never becomes an allocation
failure. No accepted case regresses outside the band. At least one of dense validate, tiny valid, or
normalized rejection latency improves outside the band before changing the default allocator. Keep a
neutral or mixed result as an attribution selector. Do not convert syscall changes into a percentage
of the reference gap.

### 3. Add distinct JSONL validation and reusable-record profiles

This stage changes promised work. It follows the allocator ablation and uses new profiles.

#### 3.1 Validation-only

**Targets:** `src/formats/jsonl.zig:validateJsonl`, `RecordIterator`, and diagnostic mapping;
`~/simd-bench-corpus/zig/json_family_api.zig:runJsonl` and exports; all profile producers and
consumers from Stage 0.

Add `jsonl_line_scan_validation`:

`indexJsonl -> RecordIterator -> checked IndexView -> stage2.validateView`

Do not allocate record tapes or metadata. Preserve record ordinal and global byte, line, column, and
snippet. Compare only with references that perform the same validation work. RapidJSON `Reader` and
nlohmann `accept` are candidates. A simdjson on-demand traversal is a consumed-on-demand profile, not
no-DOM validation. yyjson document construction is not validation-only.

**Gate:** for inputs whose source offsets and event payloads are representable by both APIs, acceptance and first diagnostics match the eager builder over strict JSON, LF and CRLF, empty lines, final records, escapes, numbers, depth, and malformed first, middle, and final records. Preserve each API's own u32/u24, resource, and error contract: index OOM remains an operational failed/error outcome, not syntax rejection, and the no-tape path is not required to return eager tape `TapeTooLarge` for an unrepresentable payload. Test those boundary cases separately. Accepted validation has no record-tape or metadata allocation. Keep the profile even if it is not faster; never relabel it as the eager profile.

#### 3.2 Reusable record tape

**Targets:** `src/formats/jsonl.zig:Parser`, `OnDemandDocument`, `RecordIterator`, `JsonlRecord`;
`src/core/stage2.zig:buildTapeView`; benchmark `runJsonl`; profile routing.

Add a strict-LF `TapeRecordParser`. It owns the global index, one high-water tape buffer, one
`TokenReader`, a capacity limit, and one active iterator lease. Each result borrows source for the
caller-input lifetime and borrows tape only until the next `next`, iterator deinit, or parser reset.
Consume and checksum each record before advancing. Keep container links record-local. Initialize and
destroy the parser within one adapter call for a fresh-within-iteration profile.

**Gate:** outcome, ordinal, raw spans, tape events, first diagnostic, and aggregate checksum match the
eager path. Peak live tape words are bounded by the largest record, not the sum. Tape allocation count
follows high-water growth, not record count. Report this profile beside retain-all results. Do not
merge them.

#### 3.3 Private trusted record view

**Targets:** `src/core/stage2.zig:IndexView.init`, `IndexView.validateInput`, `IndexView.localOffset`,
`TokenReader.reset`, and `tapeCapacity`; JSONL `RecordIterator` call sites.

Only the library-owned structural index and active iterator lease may create a private trusted record
view. Keep base, limit, monotonicity, range, and storage lifetime in that owner. Public and
external-index paths remain checked. Do not expose an unchecked constructor or a trust flag.
Instrument offset visits first. Land the path only if it removes the planned scans and improves a
dense or tiny-record case outside the band without a regression outside the band.

#### 3.4 Retained-batch alternatives

Prototype a flat aggregate only if a real caller must retain all records after 3.2. Use one owned tape
and one owned `RecordMeta` array. Run an ordered prepass to preserve syntax order, but do not treat
that pass alone as proof of resource-failure equivalence. Under deterministic logical allocation
faults, compare the first error and record with the eager builder; an earlier allocation failure must
not become a later syntax error. If consolidation changes the first error, first record, or cleanup
behavior, keep the type experimental and block public migration. Each borrowed record exposes a tape
sub-slice whose links stay local. Never rebase nested links or expose the full aggregate as one Stage 2
document. Defer public migration if reusable record processing removes the benchmark gap and no
retained-batch workload exists.

### 4. Prove private immediate-consumption paths

These changes remove defensive work only inside a closed producer-consumer boundary. They do not
weaken public APIs.

#### 4.1 XML benchmark checksum

**Targets:** `~/simd-bench-corpus/zig/xml_api.zig:buildAndRun`, `canonicalChecksum`,
`addAttribute`, and `addText`; `src/formats/xml.zig:XmlDocument.sourceSpan` and its public validators.

Add a private `trustedSourceSpan` for the `XmlDocument` built and consumed in the same `buildAndRun`.
Check source pointer and length, tape index, kind range, offset, length, and monotonic order once. Do
not call `xmlTapeSpanMatchesKind` on this private path. Keep public `sourceSpan`, `xmlTapeToken`,
`root`, cursor validation, and corrupted-tape checks unchanged. Do not fuse checksum into parse; the
profile promises post-parse traversal.

**Gate:** all five accepted DOM checksums match, public corrupted-tape cases still reject, validate is
neutral, and DOM improves outside the band on the specified cases or has a documented aggregate
trade-off. Any public safety change rejects the stage.

#### 4.2 Markdown benchmark bridge

**Targets:** `~/simd-bench-corpus/zig/markdown_api.zig:73-117` `run(.dom)`;
`src/formats/markdown.zig:MarkdownDocument.root`, `validateMarkdownTape`, and
`MarkdownCursor.peek/raw/advance/currentWord`.

Iterate the newly built local `document.tape` once in the benchmark bridge. Validate kind, offset, and
length once before forming each raw slice. Hash selected marker kinds in source order. Keep public
`MarkdownDocument.root` replay and cursor checks unchanged. This remains the marker-projection work
profile.

**Gate:** all marker checksums match; forged public tapes still fail; validate is unchanged; DOM gains
outside the band without a row regressing outside it. Do not describe the result as CommonMark speed.

#### 4.3 YAML immediate benchmark path

**Targets:** `~/simd-bench-corpus/zig/yaml_api.zig:run`, `hashNode`, `hashScalar`, and
`hashKey`; `src/formats/yaml.zig:buildYamlTape` and public `YamlDocument.root`.

First test a shim-local path that builds, validates, hashes, and deinitializes before the C call
returns. It may consume private tape state immediately, but it must not publish a cursor or mutable
alias. Keep public `YamlDocument.root` source-identity and full event replay checks unchanged.

A product `YamlOwnedCursor` is a later API only if it is an opaque implementation handle/type whose
module methods own the tape, enforce exclusive transfer, and keep source immutable. Do not expose a
public struct with supposedly private fields. A `[]const u8`, pointer plus length, or Boolean does not
prove immutability. If the opaque ownership contract cannot be enforced, keep public replay.

**Gate:** all five accepted DOM checksums, three rejected outcomes, mutation tests, offsets, error
precedence, and deinit paths match. Accept only a DOM gain outside the band with no accepted regression
outside it.

### 5. Remove repeated parser work with explicit proofs

#### 5.1 YAML validation and line preparation

**Targets:** `src/formats/yaml.zig:validateYamlSource`, `validateYamlInput`,
`YamlResidentEngine.prepareLine`, `trimCommentEnd`, and `findBlockColon`.

Fuse full-source validation with resident line preparation only when the complete-input path can prove
EOF and capacity bounds. Otherwise, cache small stack-owned `ResidentLine` metadata or keep both
passes. Preserve BOM, UTF-8, control-byte, CR/LF, comment, flow, quote, offset, and diagnostic
precedence. Do not add a default heap side table.

**Gate:** all 16 YAML rows retain outcomes and checksums; no accepted row regresses outside the band;
at least one accepted row improves outside it. Record bytes read before claiming pass removal.

#### 5.2 XML source-validity proof

**Targets:** `src/formats/xml.zig:XmlParser.run`, `validateSource`, `validateData`, parser grammar call
sites, `xmlTapeSpanMatchesKind`, `xmlTapeAttributeMatches`, and `initOnDemandDocument`.

Keep `validateData` as the checked entry. Add private `validateDataAfterSourceProof` and a stack-local,
eager-only proof token. `XmlParser.run` may create the token only after `validateSource` succeeds.
The proven path scans context-sensitive `&`, `<`, and `]]>` starts while retaining entity checks.

`source_error == null` is also the default in standalone reparsing and on-demand parsers. It is not
proof that source validation ran. Public span checks, token checks, root checks, resident parsing, and
on-demand parsing must use the checked path. If source validation records an error, still run checked
grammar and preserve the current earliest source-versus-grammar error decision.

**Gate:** invalid UTF-8 and invalid XML characters before, at, and after grammar errors keep exact
byte, line, and column diagnostics. Accepted text, names, attributes, comments, CDATA, and processing
instructions match. At least three accepted cases improve outside the band, none regresses outside it,
and instructions fall on the changed path.

### 6. Optimize measured value and lexer work

#### 6.1 Strict JSON number classification

**Targets:** `~/simd-bench-corpus/zig/bench_api.zig:hashNumber`;
`src/core/stage2.zig:consumeNumber`, `validateJsonNumber`; `ondemand.Event.number`.

Measure integer and float checksum conversion separately after Stage 1. First avoid the extra `.eE`
selection scan while keeping raw spans and the existing `parseInt`/`parseFloat` bit patterns. Test a
one-byte class emitted by `consumeNumber` only if the local change is neutral. Do not cache converted
numbers in every tape and do not write a new float parser.

**Gate:** `-0`, signed and unsigned limits, exponents, fractions, leading-zero rejection, strict
nonfinite rejection, and real fixtures keep identical typed hashes. Require a number-heavy DOM gain
and no validate regression.

#### 6.2 JSONC and JSON5 candidate work

**Targets:** `src/core/json_lexical.zig:processDialectBlock`, `processDialectByte`, quote masks,
high-byte candidates, and comment states; `src/core/stage2.zig:skipIgnored`,
`json5WhitespaceWidth`, identifier and number validators; dialect `build*Tape` capacity call sites.

1. Split index, tape, traversal, checksum, and destruction before a lexer change.
2. If quote count is measured for tape capacity, pass a private conservative raw-quote upper-bound hint directly from the immediate scanner result. Preserve raw single- and double-quote counts, range binding, and the existing fallback. Do not add unproved quote-count metadata to public checked `IndexView`.
3. Count high-byte candidates discarded inside strings. Change masks only if the discarded share is
   material. Existing dialect loops are already comptime-specialized; do not duplicate them.
4. Make comment scanning proportional to comment density only with exact trailing-root behavior and
   invalid-comment UTF-8 offsets.
5. Work on JSON5 identifiers only after an identifier-heavy profile exists.

**Gate:** structural offsets, checksums, accepted grammar, error class, and byte offset match at vector
widths 4, 16, 32, and 64. Require lower candidate count and an improvement outside the band on the
matching case, with JSONC or dense controls neutral. A broad SIMD rewrite or new runtime mode branch
fails the gate.

#### 6.3 XML name, duplicate, normalization, and capacity work

Run these as separate experiments in this order:

1. Add a four-byte or word-mask ASCII continuation scan in `parseXmlName`. Stop before high bytes and
   use the existing Unicode decoder. The direct ASCII name and text classifier is already shipped; do
   not repeat it.
2. Add stack-local `XmlAttributeNameFilter` near `hasPreviousXmlAttribute`: 1,024 Bloom bits and two
   positions from one hash, with permanent exact confirmation on a possible match. It can only skip
   known-unique names; it can never reject from a hash alone.
3. Add a 512-byte `NormalizedValueScratch` in benchmark `canonicalChecksum`. Decode and normalize an
   attribute, text, or CDATA value once. Keep the current allocation-free two-pass fallback above 512
   bytes. Hash order and lengths stay fixed.
4. Measure allocation count, requested bytes, final tape length, retained capacity, and destruction
   before changing `buildXmlTape` reserve or `toOwnedSlice`. Capacity metadata must describe the
   allocation that `XmlDocument.deinit` frees.

**Gates:** name scans preserve every NameStart/NameChar boundary and error offset. The Bloom filter
must accept adversarial collisions and improve 32- or 128-attribute inputs without hurting ordinary
fixtures. Scratch must improve escaped DOM while validate stays unchanged. Allocation changes need a
measured fixed-cost gain without more than 5% requested-byte growth on dense or escaped input.

#### 6.4 Markdown and YAML focused inner loops

For Markdown, measure `MarkdownTapeSink.grow` at 0, 1, 5, 64, 640, 4,095, 4,096, and 4,097 markers.
Compare bounded initial capacities only after Stage 4.2. Do not restore an exact-size two-pass count;
the shipped experiment repeatedly regressed. Then test one-shot line-end and marker-candidate scanning
without changing `MarkdownStreamIndexer` chunk behavior.

For YAML, use raw length directly for plain scalar and key checksum spans in
`~/simd-bench-corpus/zig/yaml_api.zig:184-215` `hashScalar` and `hashKey`. Keep quoted spans
on checked decoding unless a bounded one-pass variant proves identical output. This is same-profile
checksum work, not a parser gain. Test resident quoted-span search in
`YamlResidentEngine.parseQuoted` only after a fast scan can prove no escape, doubled quote, newline,
or invalid delimiter.

## Feature parity: adopt, defer, reject

Feature work must have a consumer, explicit semantics, ownership, resource limits, and a separate
profile when it changes work.

| Format | Adopt or conditionally adopt | Defer | Reject from the fast default |
|---|---|---|---|
| Strict JSON | Allocation-free decoded-string iterator or writer into caller scratch; typed-number view that preserves raw spans; explicit framed stream helper if a caller needs it. | Owning DOM, mutation, serializers, JSON Pointer/Patch, in-situ parsing, SAX comparison, lossless big-number modes without a corpus. | Hidden allocation, implicit type conversion, changed number bits, nonfinite strict JSON, or a broad reference-shaped DOM in Stage 2. |
| JSONL | Explicit validation-only profile; strict lazy reusable record tapes; detailed record/global diagnostics; optional caller-buffer string decoding; explicit allocator/context ownership. | Flat retained batch unless a caller needs it; resident index until fresh and reused profiles are separate; prefix parsing, threaded parsing, and alternate framing. | Calling eager DOM work validation-only; whitespace-only behavior changes; unchecked public indexes; rebased record links; silent NDJSON grammar expansion. |
| JSONC and JSON5 | Complete native JSON5 extension checksum parity; preserve native single quotes, identifiers, hex, dotted and nonfinite syntax behind JSON5; add compatibility probes. | Duplicate-key policy, bignum/lossless mode, identifier-heavy benchmark, streaming comparisons until profiles exist. | Weakening comment UTF-8 validation, removing JSON5 features to match jsoncons, accepting trailing-comment behavior only for benchmark parity, duplicate comptime specializations. |
| Markdown | Keep the marker module. If semantic CommonMark is required, add separate `src/formats/commonmark.zig`, `parseCommonMark`, a flat owned node arena, and distinct `commonmark-parse`, `commonmark-dom`, `commonmark-render-html`, and `commonmark-resource-error` profiles. Publish only after all 652 CommonMark 0.31.2 examples pass. | Mutable AST, full CommonMark streaming, XML/man/CommonMark/LaTeX renderers, and GFM extensions. | Semantic nodes in `MarkdownTokenKind`; a “full” flag on the marker scanner; partial support called CommonMark; recursive destruction; raw HTML or unsafe URLs by default; two-pass marker counting. |
| XML | Caller-output decoded-value iterator with raw-boundary validation; read-only `XmlDeclarationInfo`; lexical `XmlQName.split`; explicit non-UTF-8 transcoder only for a concrete requirement and under its own profile. | Namespace URI resolution, mutable DOM, full serialization, XPath, and alternate encodings without a user need. | Public unchecked tape/span APIs; DTD processing; general or external entity expansion; automatic file or network access; weaker UTF-8, XML Char, or Name checks. |
| YAML | Name the existing `yaml-basic-1.2.2` profile. Add literal `|`, folded `>`, multiline quoted scalars, and compact `- key: value` mappings in explicit extension profiles with owned cooked values and limits. | Directives and streams; tags; anchors and aliases with graph identity; namespace-like tag resolution; complex keys; implicit typing and merge transforms until consumer semantics exist. | Silent fallback from basic to extended grammar; alias expansion by copying; unbounded graph expansion; a public replay bypass from a Boolean or borrowed slice; claims of full YAML 1.2.2 conformance. |

### CommonMark semantic track

If selected, import the pinned 0.31.2 conformance artifact first. Build block structure, then inline
semantics and reference resolution, then one HTML renderer with a safe public default. Parsing and
rendering stay separate. The conformance-only unsafe/raw-HTML mode must be explicit. No stage may be
published as CommonMark until the 652-example oracle passes. Marker performance results remain
separate and cannot support a semantic parser speed claim.

### YAML extension track

Use this order: profile boundary; literal block scalars with clip/strip/keep and indentation metadata;
folded and multiline quoted values; compact sequence mappings; document streams and directives; then
metadata-preserving tags, anchors, and aliases. Basic-profile adapters must reject these constructs as
before. Each extension needs feature-isolated accepted and rejected rows, checksum vectors, depth and
byte limits, allocation-failure coverage, and an explicit decoded-value owner.

### XML parity track

Decoded access must validate raw event boundaries or consume a checked cursor. Caller output must not
overlap source unless the API handles overlap. Declaration and QName views borrow unchanged input and
must validate malformed raw arguments. A QName split is lexical, not namespace resolution. A
non-UTF-8 front end owns its transcoded UTF-8 buffer, checks BOM/declaration consistency and size
arithmetic, and reports transcode-plus-parse separately. It must never change the ranked UTF-8 path.

## Global experiment and acceptance protocol

This protocol was written for the original comparison packet and is retained as
the standard under which those results were accepted. The packet is
unavailable, so item 1 now names a baseline that no longer exists, and no
comparison in it can be re-run from this checkout.

1. Keep the current packet as the baseline until source or build content changes. Then regenerate
   source provenance and all affected comparisons.
2. Run seven alternating candidate/baseline process pairs on the same logical CPU for a source stage.
   Keep input hash, outcome, checksum, work profile, preparation policy, iteration count, compiler flags,
   and benchmark configuration equal. Record source provenance and executable identity; a source
   optimization is expected to change those identities.
3. Report accepted throughput and elapsed time. Report rejected latency as batch median divided by
   completed iterations. Never report rejection MB/s.
4. Use wall time for ranked results. Use cycles, instructions, branches, misses, allocation events,
   peak bytes, syscalls, or faults only for attribution.
5. Profile each changed workload after it passes the correctness gate. Use flat self overhead and call
   chains correctly. Do not subtract separate process profiles or add nested shares.
6. Preserve scalar differential checks and fixed fuzz seeds. For lexical changes, cover vector widths
   4, 16, 32, and 64 and cross-block quote, escape, UTF-8, comment, and delimiter state.
7. Exercise allocation failure at every new logical allocation point. Confirm exact deinit and lease
   release after success, syntax error, resource error, and caller misuse.
8. A same-profile optimization must keep promised work and preparation unchanged. A new semantic,
   retention, validation, streaming, decoded-output, or resident-context contract gets a new profile.
9. No speedup statement is valid unless the matching complete adapter path passes its gate. A
   throwaway prebuilt, parser-only, in-place, or moved-preparation variant remains attribution only.
10. Use the five-percent band only as a decision threshold. Do not use significance language.

## Explicit non-goals

- No blanket SIMD rewrite.
- No duplicate comptime specialization of existing JSONC or JSON5 loops.
- No public trust flag, unchecked `IndexView`, unchecked XML span, or unchecked YAML root.
- No quote-count capacity promise on forgeable public indexes.
- No two-pass Markdown marker count.
- No change to `u32` structural offsets, tape word widths, or sentinel layout without a separate data
  model decision and migration.
- No feature-parity claim from dormant reference code.
- No parser speed claim from benchmark-only checksum, wrapper, or allocator work.
- No silent expansion of a restricted grammar.
- No unsupported percentage attribution from profile shares, syscall counts, or source inspection.

## Implementation record

The historical implementation workspace was `~/projects/simd-performance`,
based on `1dc602534a8419056a476af2d71b1be67d015995`; it is not present in this
checkout. The original dirty parser checkout was not changed. Benchmark
integration lived in `~/simd-bench-corpus`, also absent here. The
shipped contracts below are current and verifiable in this repository; the
paths and counts around them are not.

### Shipped contracts

- JSON provides caller-storage string decoding and raw-preserving typed number
  views. The APIs do not introduce implicit allocation or change number grammar.
- JSONL provides a reusable record-tape parser with explicit document leases,
  record-local offsets, and record/global diagnostics. The checked public index
  path remains. This repository's benchmark measures a fixed domain of 7
  formats x 5 workloads x 6 stages and prints one row per case. Its CLI accepts
  two arguments: `--stream-chunk-size`, which only the `stream` stage consumes,
  restricted to 64, 256, 1024, 4096, or 16384 bytes and defaulting to 4096; and
  one positional iteration count, a nonzero decimal defaulting to 3. Every row
  records `checksum`, `allocation_count`, and `allocated_bytes` from a counting
  allocator over the process allocator. The validation-only, reusable
  record-tape, and libc-allocation selector vocabulary belongs to the
  comparison packet, which is unavailable and not present in this checkout;
  `bench.zig` parses no such option, and the default allocator and
  retained-batch ownership are unchanged.
- XML provides checked decoded-value access, declaration information, and lexical
  QName splitting. Source overlap and malformed raw boundaries are rejected.
  QName splitting does not resolve namespaces. No transcoder, DTD processing,
  external entity loading, or unchecked public reader was added.
- `yaml-basic-1.2.2` remains restricted. The opt-in `yaml-extended-e2b-1.2.2`
  profile adds literal/folded blocks, multiline quoted scalars, and compact
  mappings with owned cooked values. Source characters, collection depth,
  scalar source bytes, physical scalar lines, cooked bytes, and tape words have
  checked limits. Root scalars and explicit document-end markers work. Aliases,
  anchors, directives, tags, multiple documents, and implicit typing remain out
  of scope.
- `formats.commonmark` is separate from the marker-only Markdown module.
  `parseCommonMark` owns flat semantic nodes and normalized text while borrowing
  source bytes. `renderCommonMarkHtml` has a safe default and an explicit
  conformance mode: `HtmlRenderMode.safe` and `HtmlRenderMode.conformance`.
  Safe rendering filters autolinks as well as ordinary links
  and images, including schemes with decoded URL controls. Rendering checks root
  ancestry and bounds sibling traversal. Destruction is iterative.

### Optimization decisions

All rows below describe isolated attribution probes, not cross-library rankings
or complete-adapter speedup claims. The five-percent band remains a decision
threshold, not a significance test.

| Experiment | Decision |
|---|---|
| YAML resident source validation | Retained. Final seven-pair full-size medians are 0.829 sparse, 0.909 dense, 0.923 quoted, 0.851 Unicode, and 0.882 real input. Longer small-input controls remove the unresolved short-batch regression. Allocation counts and requested bytes match. |
| XML private source proof | Retained. Full-size candidate/baseline medians range from 0.867 to 0.971. Checked public access remains unchanged. |
| XML attribute duplicate prefilter | Retained with exact collision confirmation. Medians are 0.190 for 32 attributes and 0.101 for 128; ordinary accepted fixtures range from 0.931 to 0.969. |
| XML ASCII name unroll | Rejected. The 32- and 128-attribute controls regress; the original continuation loop is restored. |
| Markdown fused first-vector scan | Rejected. Escaped and Unicode controls are 1.236 and 1.208. The original scanner and the CRLF boundary regression coverage remain. |
| JSON5 high-byte suppression | Rejected. Unicode JSON5 improves, but the broader JSONC/rejection controls do not pass the gate. |
| Dialect bulk comment scan | Rejected. JSONC comment-heavy input is 1.091 in the final native-width run. |
| JSON5 ASCII identifier fast path | Rejected. Identifier-heavy input improves, but real and comment-heavy JSONC controls regress. |
| YAML quoted-span scan | Rejected. The focused controls did not establish the required gain without regressions; the scalar path remains. |
| Private JSONL index bypass and flat/resident storage variants | Rejected. The retained checked path and ownership model remain; new selectors do not imply a default-policy change. |
| Strict number, event dispatch, rejection, and sparse-index rewrites | No rewrite retained. Semantic, allocation, diagnostic-offset, and scalar-width probes remain attribution evidence, not a latency or speedup claim. |

The private dialect capacity calculation reports arithmetic overflow instead of
silently changing the bound. No quote-count metadata was added to public views.
Boundary tests defend behavior rather than a particular reservation count.

### Source verification (historical)

Recorded on the original host after integration and removal of rejected
candidates. These are not current-machine results:

- `zig build` passed.
- `zig build test corpus commonmark` passed **482/482 tests** at native width and
  explicit widths **4, 16, and 64**. Native width on that AVX2 host was 32.
  Do not restate the count or the native width as a result for this checkout,
  and do not present the current width gate as `4, 16, 64`:
  `zig build check` sweeps `[4, 5, 7, 12, 16, 24, 32, 64]`.
- The CommonMark conformance test compares exact HTML for **all 652 pinned
  CommonMark 0.31.2 examples**. No example is skipped.
- The YAML scalar differential matches libyaml on **273/273 cases**, including
  indentation, chomping, blank lines, quoting, and escaped whitespace.
- The final YAML acceptance harness passes **52/52** semantic, stream, and
  cross-width controls, including **20** checked public-mutation cases.
- `zig fmt --check src test build.zig` and the actual `zig build run` visualizer
  smoke command pass.

Historical raw evidence, not present in this checkout, was retained under
`~/simd-bench-corpus/results/2026-09-09-reference-analysis/`:
`final-native-verification.json`, `final-candidate-decisions.json`,
`yaml-scalar-differential-final.json`, `yaml-final-source-correctness.jsonl`,
`yaml-final-long-controls-timing.jsonl`, `xml-pinned-timing.jsonl`,
`markdown-fused-final-timing.jsonl`, and
`dialect-final-native-width-pairs.jsonl`. Final external adapter build and report
evidence belongs to the benchmark packet, separate from these source gates.
