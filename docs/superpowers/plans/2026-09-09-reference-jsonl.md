# JSONL reference analysis and parity plan

## Scope and evidence rules

This document covers the JSONL rows in `jsonl-comparisons.json`. It covers simdjson, yyjson, RapidJSON, and nlohmann/json. It does not treat a wrapper result as a pure parser result.

Evidence labels have these meanings:

- **MEASURED**: a benchmark packet, profile, or trace contains the value.
- **SOURCE FACT**: the inspected source or primary library documentation states the behavior.
- **INFERENCE**: source and measurements support the explanation, but do not prove its size.

The direction rule is descriptive. A ratio above `1.05` favors the reference. A ratio below `0.95` favors simd JSONL. A ratio from `0.95` through `1.05` is similar. This band is not a significance test.

**MEASURED:** The comparison rows contain three samples. The native report identifies `working_copy=329dc3a0e611f45021bb163b7c1a8e95139378b0` with parent `fbc75b5f5c2fcad4f110ff5cc6af07bebdf3ff7c`. A source-provenance check reports only the parser-performance plan changed between that snapshot and inspected parent `24edee4b`; native source, build, and test content are identical. These ratios therefore describe the inspected source. Re-measure each future source change.

**SOURCE FACT:** The earlier optimization wave already added exact strict-JSON tape capacities and reset all reader state in place. This plan does not propose those changes again.

## Coverage and measured reversals

### Accepted inputs

For accepted rows, the table value is:

`reference throughput / simd JSONL throughput`

“ref” means the reference is faster. “ours” means simd JSONL is faster. The header gives `records / source bytes`.

| Mode | Reference | valid `3 / 106` | sparse `128 / 510,482` | dense `4,096 / 152,317` | escaped `256 / 251,026` | Unicode `256 / 513,170` | real `100 / 466,564` |
|---|---|---:|---:|---:|---:|---:|---:|
| validate | simdjson | 39.37× ref | 2.95× ref | 39.68× ref | 4.67× ref | 3.64× ref | 4.94× ref |
| validate | yyjson | 104.40× ref | 2.78× ref | 52.50× ref | 5.58× ref | 2.82× ref | 5.10× ref |
| validate | RapidJSON | 15.08× ref | 0.71× ours | 16.94× ref | 2.55× ref | 1.29× ref | 1.76× ref |
| validate | nlohmann/json | 13.04× ref | 0.28× ours | 7.15× ref | 0.76× ours | 0.48× ours | 0.47× ours |
| dom | simdjson | 36.61× ref | 7.75× ref | 22.06× ref | 7.36× ref | 7.91× ref | 6.72× ref |
| dom | yyjson | 54.82× ref | 7.41× ref | 28.91× ref | 8.46× ref | 6.41× ref | 6.84× ref |
| dom | RapidJSON | 23.16× ref | 3.73× ref | 16.03× ref | 4.95× ref | 3.67× ref | 3.74× ref |
| dom | nlohmann/json | 6.41× ref | 1.69× ref | 6.01× ref | 1.87× ref | 1.80× ref | 1.24× ref |

**MEASURED:** This table covers all 48 accepted comparison rows.

**MEASURED:** simdjson and yyjson lead every accepted row. Their largest validate gaps occur on the tiny valid input and the 4,096-record dense input.

**MEASURED:** simd JSONL leads RapidJSON only for sparse validation. RapidJSON leads the same sparse input by 3.73× in DOM mode. This is a mode reversal.

**MEASURED:** simd JSONL leads nlohmann/json for sparse, escaped, Unicode, and real validation. nlohmann/json leads all four in DOM mode. These are four mode reversals. nlohmann/json also leads tiny-valid and dense validation.

**MEASURED:** Dense has 32 times as many records as sparse, but only 0.30 times as many bytes. Each reference has a much larger dense validate advantage than its sparse validate advantage.

**INFERENCE:** Record-count-sensitive setup and allocation are strong candidates. The ratio pattern does not assign a fraction of the gap to them.

### Rejected input

Rejected rows measure latency, not throughput. Each raw rejected row reports 100 completed timed iterations. The next table divides each `jsonl-comparisons.json` median `elapsed_ns` by 100. It preserves the median-of-three comparison basis. It does not substitute one raw report value.

The advantage value is:

`native latency / reference latency`

| Reference | Mode | Native ns/rejection | Reference ns/rejection | Advantage | Direction |
|---|---|---:|---:|---:|---|
| simdjson | validate | 16,201.16 | 292.10 | 55.46× | ref |
| simdjson | dom | 16,055.63 | 307.90 | 52.15× | ref |
| yyjson | validate | 16,201.16 | 113.95 | 142.18× | ref |
| yyjson | dom | 16,055.63 | 129.13 | 124.34× | ref |
| RapidJSON | validate | 16,201.16 | 505.44 | 32.05× | ref |
| RapidJSON | dom | 16,055.63 | 307.57 | 52.20× | ref |
| nlohmann/json | validate | 16,201.16 | 13,337.34 | 1.21× | ref |
| nlohmann/json | dom | 16,055.63 | 24,962.37 | 0.64× | ours |

**MEASURED:** This table covers all eight rejected comparison rows.

**SOURCE FACT:** All adapters fail before DOM traversal on this malformed input. The native validate and DOM paths are also identical until `buildJsonlTape` fails.

**MEASURED:** Native validate and DOM rejected latencies differ by less than 1%. The nlohmann/json direction reverses between modes.

**INFERENCE:** The nlohmann/json rejected reversal is not a traversal result. No traversal starts. Treat it as binary or run variation until a paired latency run reproduces it.

## Exact execution paths

### Shared reference wrapper

**SOURCE FACT:** `bench/adapters/jsonl.cpp:33-87` implements the wrapper used by all four references.

1. `run_jsonl_records` scans each input byte with a scalar loop.
2. It ends a record at each byte `0x0a`.
3. The `position <= input.size()` condition emits the final record without a final LF.
4. It drops the LF. It leaves a preceding CR in the record span.
5. It ignores a zero-byte physical record.
6. It sends every nonempty span to the selected JSON adapter.
7. It stops at the first rejected or failed record.
8. DOM mode hashes the accepted-record ordinal, source length, and record checksum.

**SOURCE FACT:** The wrapper does not ignore whitespace-only lines. It delegates them to a strict JSON parser. The simd parser ignores spaces, tabs, and CR-only records. The benchmark specification excludes whitespace-only records from the shared domain.

**SOURCE FACT:** The wrapper has no batch parser context of its own. Parser and allocator lifetime come from each JSON adapter.

### Native simd JSONL path

The current benchmark chain is:

`make_simd_jsonl_adapter` → `run_simd_jsonl` → `run_simd_family` → `simd_bench_jsonl_validate/dom` → `runJsonl` → `buildJsonlTape`

**SOURCE FACT:** The C function type contains only `(input pointer, input length, checksum pointer)`. It has no allocator or context parameter. `runJsonl` hard-codes `std.heap.page_allocator`.

**SOURCE FACT:** Input bytes are borrowed for the call. No document crosses the C boundary. The checksum is the only data result.

`buildJsonlTape` does this work:

1. `indexJsonl` allocates one global `StructuralIndex`.
2. `json_lexical.feed` indexes JSON structural bytes and LFs outside quoted strings.
3. `RecordIterator` walks the global offsets. It does not rescan all source bytes to find LF.
4. `RecordIterator` skips empty and ASCII-whitespace-only records.
5. Each record gets a borrowed source slice and a borrowed global-index slice.
6. `IndexView.init` checks the complete record index slice.
7. `stage2.buildTapeView` resets a `TokenReader`.
8. `TokenReader.reset` checks the same view again.
9. The shipped strict-JSON capacity pass walks the record offsets.
10. `buildTapeView` allocates one exact tape for that record.
11. The reader validates syntax and writes record-local tape words.
12. `records.append` stores the borrowed source span and the owned tape.
13. `records.toOwnedSlice` returns the owned metadata array.
14. The global structural index is freed before `buildJsonlTape` returns.

**SOURCE FACT:** `StructuralIndex.init(allocator, input.len)` allocates `input.len + 3` `u32` entries. This reserves about four source bytes of index storage for each input byte, independent of structural density.

**SOURCE FACT:** Validate mode still builds and retains every record tape. It only skips `checksumDocument` after the batch build.

**SOURCE FACT:** DOM mode retains all record tapes. It then traverses and hashes one record at a time. It frees all tapes only after the final checksum.

**SOURCE FACT:** Each `JsonlRecord.document` owns its tape. Each record source borrows bytes from `JsonlDocument.input`. `JsonlDocument.deinit` frees every record tape, then the metadata array.

**SOURCE FACT:** Container links use indices local to each record tape. A cursor cannot cross record boundaries.

**SOURCE FACT:** On a build failure, the index defer frees the global index. The records error defer frees all completed tapes and metadata. An append failure also frees the just-built tape. A checksum failure still runs the outer document defer.

**SOURCE FACT:** `validateJsonl` already provides an allocation-free Stage 2 validation path after global indexing. It returns the first record index and global byte, line, column, and snippet. The benchmark export does not call it.

### Page allocator behavior

**SOURCE FACT:** Zig 0.16.0 `PageAllocator.alloc` calls `map`. On this POSIX target, `map` rounds to page size and calls anonymous `mmap`. `free` unmaps the page-aligned region. A resize can call `mremap` or `munmap`.

**SOURCE FACT:** A small record tape can therefore cause a mapping and an unmapping. Exact requested tape capacity does not remove that syscall pair.

**MEASURED:** The shipped exact-capacity wave reduced the internal 49,152-record dense tape case from 98,314 to 49,162 allocation calls. Requested bytes fell from 26,931,440 to 18,673,904. The remaining count is still close to one allocation per record. Timing samples did not support a blanket speedup claim.

### Native DOM decoder and checksum

**SOURCE FACT:** Tape strings retain raw source bytes. Tape construction validates strings but does not store decoded strings or typed numbers.

**SOURCE FACT:** `checksumDocument` uses a fixed `[max_depth]ContainerChecksum` stack. `decodeChunk` uses a four-byte stack value. This checksum path makes no explicit heap allocation.

**SOURCE FACT:** `Hasher.addDecodedString` first calls `decodedStringLength`. It then calls `decodeChunk` again to hash the decoded bytes. An escaped string is decoded twice during checksum work. Tape construction also scanned it for validation.

**SOURCE FACT:** `hashNumber` parses the raw number again into `i64`, `u64`, or `f64`. Reference DOMs expose a typed number.

**MEASURED:** The native synthetic DOM user-cycle profile attributes 42.72% to `Hasher.addDecodedString` and 23.31% to `decodeChunk`. It attributes 3.18% to `stage2.validateString`, 2.57% to `stage2.validateNumber`, and 2.99% to the sampled `mmap` call chain. These are profile shares, not shares of the cross-library gap.

### simdjson 4.6.5

The wrapper path is:

`run_simdjson_jsonl` → `run_jsonl_records` → `run_simdjson`

**SOURCE FACT:** `run_simdjson` uses one namespace-scope `simdjson::dom::parser`. The parser retains internal buffers and one document across calls. A later parse overwrites that document.

**SOURCE FACT:** Each record creates a new `std::vector<std::byte>`, adds `SIMDJSON_PADDING`, copies the record, and calls `parser.parse(..., false)`. The vector dies when the record call returns.

**SOURCE FACT:** Validate mode still completes `dom::parser::parse`. It only skips `hash_value`.

**SOURCE FACT:** DOM mode recursively traverses the parsed DOM. Strings and typed numbers come from simdjson accessors.

**SOURCE FACT:** simdjson also provides `parse_many` and `load_many`. `load_many(path)` reads the complete file into memory owned by the parser, then exposes a lazy `document_stream`. `parse_many` is lazy over a complete caller-owned buffer, makes no input copy, and requires `SIMDJSON_PADDING`; both accept concatenated JSON documents separated by whitespace. Object and array documents can omit whitespace between them. It can use one look-ahead thread when `SIMDJSON_THREADS_ENABLED` is enabled.

**SOURCE FACT:** The wrapper does not use `parse_many`. Its fresh padded vector is visible inside the timed record call.

**INFERENCE:** `parse_many` cannot replace strict LF framing without an extra boundary check. Its accepted language is broader than one JSON value per physical line.

### yyjson 0.12.0

The wrapper path is:

`run_yyjson_jsonl` → `run_jsonl_records` → `run_yyjson`

**SOURCE FACT:** Each record calls `yyjson_read_opts` with `YYJSON_READ_NOFLAG` and a null allocator. Null selects the libc allocator.

**SOURCE FACT:** The adapter checks `yyjson_doc_get_read_size(document) == input.size()`. It frees the document on validation success, parse-size mismatch, and after DOM hashing.

**SOURCE FACT:** The default path does not use `YYJSON_READ_INSITU`, a pool allocator, or `YYJSON_READ_STOP_WHEN_DONE`.

**SOURCE FACT:** yyjson supports a caller allocator with a context. Its pool allocator can avoid malloc and realloc. The 0.12.0 documentation shows one pool reused for sequential documents after each `yyjson_doc_free`.

**SOURCE FACT:** `YYJSON_READ_STOP_WHEN_DONE` parses one JSON prefix in larger data such as NDJSON. `yyjson_doc_get_read_size` reports the consumed size. Unless `YYJSON_DISABLE_INCR_READER` disables it, yyjson also exposes `yyjson_incr_new`, repeated `yyjson_incr_read` calls with an incremented available length, and `yyjson_incr_free`; `YYJSON_READ_ERROR_MORE` means the retained buffer needs more bytes. The incremental reader is standard-JSON-only, ignores non-standard flags, and warns that very small increments are inefficient. The current yyjson reference path uses none of these APIs; the shared adapter supplies strict LF framing outside the library.

**MEASURED:** In the deep synthetic DOM profile, `hash_value` has 34.01% of user cycles. `run_yyjson_jsonl` has 32.15%. `yyjson_read_opts` has 24.17%. `malloc` and `_int_malloc` have 2.08% and 2.34%. These profile shares do not prove which source change will close the gap.

### RapidJSON 1.1.0-unstable-2025-02-05

The wrapper path is:

`run_rapidjson_jsonl` → `run_jsonl_records` → `run_rapidjson`

**SOURCE FACT:** The installed Nix derivation uses Tencent RapidJSON commit `24b5e7a8b27f42fa16b96fc70aade9106cf7102f`. Its version macros report 1.1.0.

**SOURCE FACT:** Every record creates a local `rapidjson::Document`. It parses with `kParseValidateEncodingFlag | kParseFullPrecisionFlag`.

**SOURCE FACT:** `GenericDocument` uses `MemoryPoolAllocator` by default for DOM values and a stack allocator during parsing. Its local destructor releases its owned allocator at record exit.

**SOURCE FACT:** Validate mode builds the DOM and checks `HasParseError`. It only skips recursive hashing.

**SOURCE FACT:** RapidJSON also has a SAX `Reader`, iterative parsing, `ParseStream`, and `kParseStopWhenDoneFlag`. The current wrapper uses none of them.

### nlohmann/json 3.12.0

The wrapper path is:

`run_nlohmann_jsonl` → `run_jsonl_records` → `run_nlohmann`

**SOURCE FACT:** The adapter has one namespace-scope `nlohmann::json document`. Each record parses an iterator range and assigns the result to that object.

**SOURCE FACT:** The JSON type defaults to `std::map`, `std::vector`, `std::string`, and `std::allocator`. The parsed tree owns its strings and container nodes.

**SOURCE FACT:** Parse errors use exceptions in this build. Validate mode still builds and assigns the full DOM. It leaves the final accepted document in the global destination.

**INFERENCE:** Assignment destroys or replaces the old tree during the next record update. The allocator does not provide a parser scratch arena that is reset as one block. Confirm exact allocation timing with an allocator trace before changing the destination strategy.

**SOURCE FACT:** nlohmann/json provides `accept` and `sax_parse` for no-DOM syntax checks and event handling. The current wrapper uses `parse` instead.

## Cost evidence and limits

### Allocation mismatch

| Selector | User seconds | System seconds | Minor faults | Major faults |
|---|---:|---:|---:|---:|
| simd-jsonl | 0.684266 | 1.439395 | 201,105 | 0 |
| jsonl-yyjson | 0.147374 | 0.004937 | 615 | 0 |
| jsonl-simdjson | 0.133882 | 0.002976 | 629 | 0 |
| jsonl-rapidjson | 0.363325 | 0.003960 | 612 | 0 |
| jsonl-nlohmann | 1.002243 | 0.003954 | 615 | 0 |

**MEASURED:** These are whole-process `taskset -c 2`, synthetic, validate, repeat-two observations. They include startup, input loading, warmup, output work, and all fixtures. Durations differ. Use them to identify a large system-work and fault mismatch. Do not use them as parser-only timings.

**MEASURED:** A separate whole-process `strace -c`, synthetic, validate, repeat-one run counted 99,804 `mmap`, 99,775 `munmap`, and 504 `mremap` calls for simd JSONL. The yyjson process counted 33 `mmap`, four `munmap`, and no `mremap`. The tracer perturbs time.

**SOURCE FACT:** The allocation topology and Zig `PageAllocator` implementation can produce this class of mapping traffic.

**INFERENCE:** Page-level allocation is a primary explanation for native validate behavior on many small records and early rejection. Only a same-algorithm allocator ablation can quantify removable time.

### Storage-lifetime mismatch

**SOURCE FACT:** Native eager JSONL holds all record tapes until the batch ends. The four wrappers parse records sequentially. yyjson and RapidJSON release each record document before the next call. simdjson overwrites one parser-owned document. nlohmann/json replaces one global destination.

**INFERENCE:** The reported work-profile names describe broad work. They do not make peak live DOM storage or allocator lifetime equal.

### Integrated indexing versus wrapper scanning

**SOURCE FACT:** Native JSONL performs one SIMD Stage 1 pass over the whole input. It then walks indexed LFs and structural offsets. Each reference wrapper performs a scalar raw LF pass and invokes a JSON parser for each record.

**INFERENCE:** The scalar wrapper line scan is not the cause of the native deficit. The references remain faster despite that extra scan. This does not prove that native Stage 1 is optimal.

### Shape effects

**MEASURED:** Native validation beats RapidJSON and nlohmann/json on the 510,482-byte sparse input. It loses by large factors on the 4,096-record dense input.

**INFERENCE:** Long records expose useful SIMD lexical work. Many small records expose fixed record work, mappings, and view setup. Measure those parts separately.

**MEASURED:** Native DOM loses to RapidJSON and nlohmann/json on sparse, escaped, Unicode, and real inputs where native validation is competitive or faster.

**INFERENCE:** Raw-tape checksum decoding is a strong reason for these reversals. The native DOM profile supports the hypothesis. It does not isolate checksum work from tape traversal.

### Rejected-path behavior

**SOURCE FACT:** The malformed fixture is 24 bytes. Native eager validation allocates and indexes before Stage 2 reports the syntax error. The references scan one line and fail in their record parser.

**INFERENCE:** A small number of page mappings can dominate this very short native path. The allocator ablation and the true validation adapter must report normalized nanoseconds per rejection.

## Feature and work matrix

| Capability | simd JSONL | simdjson 4.6.5 | yyjson 0.12.0 | RapidJSON pinned commit | nlohmann/json 3.12.0 | Current timed wrapper |
|---|---|---|---|---|---|---|
| Strict LF record framing | Native `RecordIterator` | No dedicated strict-LF API reviewed | Prefix parse only | Caller-managed stream/SAX | Caller-managed input/SAX | Scalar LF loop for references |
| Physical empty lines | Skipped | `parse_many` treats separators as whitespace | Caller policy | Caller policy | Caller policy | Skipped |
| Whitespace-only lines | Skipped | Broader whitespace separation | Caller policy | Caller policy | Caller policy | Parsed and normally rejected; outside shared domain |
| CRLF | LF delimiter; CR is JSON whitespace | Whitespace separator | Prefix/caller policy | Reader/caller policy | Caller policy | LF delimiter; CR remains in record |
| Final record without LF | Supported | Supported by batch input | Supported by caller prefix loop | Supported by stream end | Supported by caller loop | Supported |
| Eager batch DOM | `buildJsonlTape` | `parse_many` document stream, not strict LF | Repeated documents | Repeated documents | Repeated documents | Native retains all; references use one record at a time |
| Lazy/event API | `Parser` + `OnDemandDocument.eventReader/tokenCursor` | Lazy `document_stream` | No event API in reviewed reader | SAX `Reader` | `sax_parse` | Not exercised |
| Streaming/batch API | `initStreamIndexer` indexes caller-fed JSONL chunks | Preloaded lazy batch: `load_many` reads the whole file; `parse_many` consumes one complete padded buffer | Growing-buffer incremental: `yyjson_incr_new/read/free` with `MORE` | Pull stream: `GenericReader::Parse` / `ParseStream` | Input adapter or iterator range with `sax_parse` | Not exercised |
| Validation without record tapes | `validateJsonl` | Reviewed DOM batch API returns documents | Reviewed read API returns a document | SAX reader can validate | `accept` can validate | None exercised; every validate row builds a DOM/tape |

| Custom allocator | Public Zig allocator parameter | Parser owns internal storage | `yyjson_alc`, pool, dynamic allocator | Allocator template and caller pool | Allocator template parameters | Native hard-codes page allocator; references use defaults |
| In-situ input | No; input remains borrowed | Requires padding; batch makes no input copy | Optional and mutating | Optional and mutating | No default in-situ DOM | Not exercised |
| Global record diagnostic | `validateJsonl` returns record and global coordinates | Error plus stream position APIs | `yyjson_read_err` plus read size | Parse code and error offset | Exception byte position | Reduced to accepted/rejected/failed |
| Single active reusable parser | Enforced by resident lease | Parser is not thread-safe | Pool allocator is not thread-safe | Depends on caller allocator | Global adapter destination is not concurrent | No concurrency in timed runs |

**SOURCE FACT:** These APIs are different contracts, not interchangeable “chunk-fed” labels. The native `initStreamIndexer` consumes caller-fed chunks while preserving JSONL lexical state. simdjson `load_many` is a preloaded lazy batch and `parse_many` consumes one complete padded buffer. yyjson incremental parsing grows the available length of one retained buffer. RapidJSON `GenericReader::Parse` pulls from an `InputStream`; nlohmann/json input adapters and `sax_parse` likewise consume an input range or stream. None is exercised by the current timed wrapper.

**SOURCE FACT:** Capability does not prove cost on the measured corpus. The table marks what the benchmark actually calls.

## Prioritized implementation and experiment plan

Run these stages serially. Keep accepted throughput separate from rejected latency. Keep every new work profile separate from the current eager-DOM profile when work changes.

### P0 — Freeze attribution and invariants

**Targets:** `jsonl-comparisons.json`, raw JSONL reports, `jsonl-memory-syscalls.json`, `jsonl-process-attribution.json`, and the benchmark report schema.

**Plan:**

1. Record accepted elapsed time and throughput for all six accepted cases in both modes.
2. Record rejected latency as `median_elapsed_ns / completed_timed_iterations`.
3. Record allocation calls, requested bytes, peak live bytes, `mmap`, `munmap`, `mremap`, and minor faults.
4. Record record count, maximum record bytes, structural count, and tape words.
5. Keep compiler flags, CPU, work profile, preparation policy, checksum, and outcome in each row.

**Correctness gate:** All variants must preserve accepted checksums and outcome classes. A rejected syntax input must not become an allocator failure.

**Measurement gate:** A missing denominator, changed work profile, changed compiler flags, or changed checksum rejects the comparison.

### P1 — Same-work allocator ablation

**Targets:** `zig/json_family_api.zig:runJsonl`, `simd_bench_jsonl_validate`, `simd_bench_jsonl_dom`, `bench/adapters/simd_json_family.cpp:make_simd_jsonl_adapter`, `~/simd-bench-corpus/zig/build.zig:102-116`, and the matching CMake target.

**Contract:** Keep `buildJsonlTape`, record retention, Stage 1, Stage 2, checksum work, and destruction order unchanged. Change only the backing allocator. First compare `std.heap.page_allocator` with `std.heap.c_allocator` under separate selectors.

**Prerequisite:** The benchmark `api_module` at `~/simd-bench-corpus/zig/build.zig:102-116` has no `.link_libc=true`, while Zig's `c_allocator` is a comptime error unless `builtin.link_libc` is enabled. Enable libc consistently for that benchmark API module and the matching CMake/C++ target before the controlled pair. Record the revised compiler, linker, and build identity; this setup change is outside the allocator result.

**Data ownership:** The allocator remains inside one C call. All tapes and metadata die before return. Input remains borrowed. No allocation can escape to C++.

**SOURCE FACT:** Zig 0.16 `ArrayList.ensureTotalCapacityPrecise` and `toOwnedSlice` try `gpa.remap` first, then fall back to a new allocation plus copy. The page allocator may remap with `mremap`; the C allocator may resize in place or use `realloc` when alignment permits. Identical parser logic can therefore produce different physical alloc/remap/free counts and byte totals.

**Alternative:** An arena changes free timing and allocation-call behavior. Do not use it for the first allocator ablation. A persistent context also changes preparation policy. Measure it later.

**Dependencies:** P0 only.

**Correctness cases:**

- empty input and physical empty lines;
- spaces, tabs, and CR-only lines;
- LF and CRLF records;
- final record with and without LF;
- top-level scalar, object, and array records;
- quoted backslash and escaped quote near LF;
- malformed first, middle, and final records;
- depth, input-size, tape-size, and allocation failures.

**Acceptance gates:**

- Outcomes and accepted checksums are bit-identical.
- Logical capacity requests (index, per-record tape, metadata) and allocation/free lifetime order are identical between backings. Record allocator events separately as `alloc`, `resize`, `remap`, `free`, and alloc+copy fallback; do not reject a pair because physical event counts or backing byte totals differ.
- No accepted case is more than 5% slower by elapsed-time median.
- At least one of dense validate, tiny valid, or normalized rejection latency improves by more than 5% before changing the benchmark default.
- Report syscall and fault changes as measurements. Do not assign a percentage of the library gap from source.

**Reject decision:** If logical requests, lifetime, parser work, or build flags differ, the experiment is not allocator-only. Physical remap/fallback differences are expected evidence, not an automatic rejection. If C allocation regresses any accepted shape by more than 5%, keep it as an ablation selector and do not change the default.

### P2 — Add a true validation-only adapter and profile

**Targets:** `src/formats/jsonl.zig:validateJsonl`, `zig/json_family_api.zig:runJsonl`, the exported JSONL functions, `bench/common.hpp:WorkProfile` and label/parse serialization, `scripts/compare.zig:WorkProfile` and `profileMatchesReport`, the adapter selector table, report validation, and `WorkProfile`.

**Contract:** Add a distinct export and selector for syntax validation. Use a profile such as `jsonl_line_scan_validation`. Do not silently relabel `jsonl_line_scan_fresh_dom_parse`.

The native path is:

`indexJsonl` → `RecordIterator` → `IndexView` → `stage2.validateView`

It must not allocate record tapes or record metadata.

**Outcome mapping:**

- `null` diagnostic maps to accepted.
- A populated `JsonlDiagnostic` maps to rejected.
- allocation, capacity, and invalid-index failures map to failed.
- the diagnostic keeps accepted-record ordinal and global byte, line, column, and snippet.

**Reference alternatives:**

- Add RapidJSON `Reader` validation and nlohmann/json `accept` only under the same new profile.
- Do not put simdjson DOM parse or yyjson document construction in a no-DOM profile.
- A fully consumed simdjson on-demand traversal needs its own profile. It is not a no-work substitute.

**Dependencies:** Run P1 first so allocator and work changes remain separate.

**Correctness gate:** Match `buildJsonlTape` acceptance on the full strict shared domain. Cover UTF-8, escapes, numbers, one root, depth, CRLF, blank lines, final records, and first-error global coordinates.

**Resource gate:** Accepted validation has no tape or metadata allocation. The only current fresh allocation is the global structural index.

**Measurement gate:** Compare this selector only with other `jsonl_line_scan_validation` selectors. Report normalized rejected latency. If validation is not faster, keep the profile and investigate index work. Do not change its label.

### P3 — Remove benchmark checksum re-decoding

**Targets:** `zig/json_family_api.zig:Hasher.addDecodedString`, `decodedStringLength`, `decodeChunk`, `hashString`, `hashNumber`, and `checksumDocument`.

**Contract:** Preserve the canonical checksum byte for byte. Preserve raw-tape parser APIs.

**Implementation order:**

1. Add an unescaped fast path. If raw JSON string bytes contain no backslash, decoded length is `raw.len`. Hash the raw bytes directly after the length.
2. For escaped strings, decode once into one reusable scratch buffer. Then hash its length and bytes.
3. Keep the scratch buffer owned by one checksum run. Clear it between strings and retain its high-water capacity.
4. Free it on success and every failure.
5. Measure raw-number reparsing separately. Do not alter numeric checksum types in the same change.

**Alternative:** Changing the checksum order would remove the need to know length first. Reject it because it invalidates every checksum oracle. A decoded-length sidecar adds permanent tape memory. Defer it until the scratch experiment fails.

**Dependencies:** P1 establishes the allocator. P0 establishes checksum identity.

**Correctness cases:** Unescaped ASCII, raw UTF-8, all short escapes, solidus, embedded NUL from `\u0000`, BMP values, surrogate pairs, invalid lone surrogates, keys, empty strings, and the maximum supported raw length.

**Acceptance gates:**

- Every accepted checksum is unchanged.
- Validate mode has no measurable code-path change.
- Escaped checksum work performs at most scratch growth, not one allocation per string.
- No DOM case regresses by more than 5%.
- At least one of escaped, Unicode, dense, or real DOM improves by more than 5%.
- Re-profile. Require `addDecodedString` plus `decodeChunk` cycle share to decrease. Do not add their old shares to claim gap closure.

### P4 — Add reusable record-tape processing

**Targets:** `src/formats/jsonl.zig:Parser`, `OnDemandDocument`, `RecordIterator`, `JsonlRecord`, and `stage2.buildTapeView`; benchmark `runJsonl`, `bench/common.hpp` profile serialization, `scripts/compare.zig:WorkProfile`/`profileMatchesReport`, report validation, and profile metadata.

**API shape:** Add a strict-LF `TapeRecordParser` and iterator. Do not change `buildJsonlTape` in this stage.

The parser owns:

- resident global index storage;
- one reusable `ArrayList(stage2.TapeWord)` scratch tape;
- one reusable `stage2.TokenReader`;
- a single-active-iterator lease;
- a configured maximum input capacity.

Each `next` result borrows:

- `source`, valid while caller input lives;
- `tape`, valid only until the next `next`, iterator deinit, or parser reset;
- source and tape start/end values;
- the accepted-record ordinal.

The returned cursor sees only the record tape slice. Container links remain record-local.

**Failure contract:** A syntax result carries `JsonlDiagnostic`. Resource failures use the error set. A failed iterator releases its lease on deinit. The parser can start a new input after release. No partial record escapes.

**Benchmark use:** Parse one record, traverse and checksum it, then reuse the tape. Initialize and deinitialize the parser within one adapter call for a fresh-within-iteration profile. Add profile names that state reused record destination. Do not report this path as the old retain-all batch profile.

**Alternatives:**

- Existing `EventReader` avoids tapes. It is an on-demand event profile, not DOM parse plus traversal.
- A prepass can reserve the largest record tape exactly. It adds a pass. Start with high-water growth and measure it.
- A batch arena still retains all record data. It does not provide the borrowed-record contract.

**Dependencies:** P1 and P3. P3 prevents checksum work from hiding record reuse.

**Correctness cases:** All P1 framing cases, nested containers at the depth limit, record-local root/back links after many resets, a caller that consumes the cursor before `next`, misuse after `next`, and failure after earlier accepted records.

**Acceptance gates:**

- Outcomes, ordinals, lengths, and aggregate checksums match the eager path.
- Peak live tape words are bounded by the largest record, not the sum of records.
- Tape allocations depend on high-water growth, not record count.
- Dense validate and DOM improve by more than 5%, with no accepted case more than 5% slower, before the benchmark selects this profile by default.
- Report it beside, not merged with, retain-all batch results.

### P5 — Remove repeated trusted-index checks

**Targets:** `stage2.IndexView.init`, `IndexView.validateInput`, `IndexView.localOffset`, `TokenReader.reset`, `tapeCapacity`, and JSONL `RecordIterator` call sites.

**SOURCE FACT:** The current record path scans each record offset slice in `IndexView.init`. `TokenReader.reset` scans it again. The capacity pass walks it again. Token access also converts and checks global offsets.

**Contract:** Keep public and external-index paths fully checked. Add an internal trusted record-view path only for slices made by the library-owned JSONL index and `RecordIterator`.

**Security rule:** Do not expose an unchecked constructor. Do not trust caller-owned mutable offsets. A trusted view must keep base, limit, monotonicity, and range invariants from its owning index lease.

**Alternatives:**

- Removing `validateInput` for every `IndexView` weakens protection against caller mutation. Reject this global shortcut.
- Copying local offsets makes ownership simple but adds a pass and allocation. Reject it unless profiling favors it.

**Dependencies:** Centralize this work in P4 before adding a second private path.

**Correctness gate:** Checked external views still reject unsorted, duplicate, below-base, at-limit, overflowing, and mutated offsets. Trusted views never outlive index storage.

**Measurement gate:** Instrument offset visits before timing. The optimized path must remove the planned visits. Land hot-path complexity only if dense or tiny-record time improves by more than 5% and no shape regresses by more than 5%.

### P6 — Prototype a flat aggregate tape for retained batches

**Targets:** `JsonlDocument`, `JsonlRecord`, `buildJsonlTape`, `stage2.buildTapeView`, and `stage2.Document.root`.

This stage serves callers that must retain every record. P4 remains the preferred benchmark path for sequential record processing.

**Proposed ownership:**

```text
FlatJsonlDocument
  input: borrowed []const u8
  tape: one owned []TapeWord
  records: one owned []RecordMeta

RecordMeta
  source_start: u32
  source_end: u32
  tape_start: usize
  tape_end: usize

BorrowedRecordView
  source: borrowed from input
  tape: borrowed sub-slice of FlatJsonlDocument.tape
```

**Link contract:** Each record is built into its own tape sub-slice with index zero at `tape_start`. Start/end payloads stay local to that sub-slice. Never expose the complete aggregate as one Stage 2 document. Never rebase a record-local link to a global tape index.

**Capacity and error-order contract:** Before aggregate allocation, run an ordered prepass over records. For each record, perform the same `IndexView.init` and Stage 2 validation/resource checks, then compute its checked local capacity; stop at the first syntax or tape-limit diagnostic and map it through the existing global record diagnostic path before inspecting later records. Accumulate checked `usize` capacity sums only after the current record passes. Allocate the aggregate tape and metadata only after the complete ordered prepass. Record whether this prepass replaces existing per-record capacity work or adds a pass. An internal pass alone does not create a new profile; keep the existing work-profile label only when framing, validation, retention, checksum, preparation, and error contracts remain the same, and otherwise split the profile.

**Build contract:** Add an internal `buildTapeViewInto(out, input, view, dialect)` form. It writes only inside the supplied segment. It returns the used prefix. It makes no allocation.

**Failure cleanup:** The builder owns only the aggregate tape and metadata allocations. An error frees both once. Source spans remain borrowed. A syntax error maps to the same global record diagnostic path. Fault-inject every logical allocation point; if aggregate-allocation failure changes the first failing record or error relative to the eager builder, keep this type experimental and do not migrate the public API.

**Migration:**

1. Add `FlatJsonlDocument` as an explicit experimental type.
2. Measure it against current `JsonlDocument` with the same allocator and checksum order.
3. If accepted, make storage private in one breaking API change.
4. Change `record()` to return a borrowed view.
5. Migrate all callers before removing per-record `Document` ownership.
6. Do not keep aliases or dual deinit rules after the cutover.

**Alternatives:**

- An arena gives one bulk free but keeps per-record allocation calls and opaque fragmentation. It is a useful experiment, not the final representation.
- P4 uses less peak memory when records need not coexist. Do not force flat retention on streaming callers.

**Dependencies:** P1, P4, and P5. The P4 result decides whether the benchmark needs this type.

**Acceptance gates:**

- All current record cursors return identical tape events and raw spans.
- Aggregate checksum and first-error diagnostic match current behavior.
- Empty, whitespace, CRLF, final-record, and failure cleanup cases pass.
- Retained tape words equal the old sum. Metadata is no larger per record.
- Returned live storage uses one tape allocation and one metadata allocation.
- Deterministic allocation-fault runs report the same first failing record and error class as the eager builder; otherwise public migration is blocked.
- No accepted case regresses by more than 5%.
- Dense retain-all parse must improve by more than 5% or peak mapped regions must fall by at least 90% before public migration.

**Defer decision:** Do not migrate the public type if P4 removes the benchmark gap and no retained-batch workload needs flat storage.

### P7 — Measure resident index storage separately

**Targets:** `indexJsonlImpl`, `stage1.StructuralIndex.init`, JSONL `Parser.prepare`, `~/simd-bench-corpus/zig/build.zig:102-116` module linkage, `bench/common.hpp` profile enum/serialization, `scripts/compare.zig:WorkProfile`/`profileMatchesReport`, and any future benchmark context ABI.

**SOURCE FACT:** Fresh eager indexing reserves `input.len + 3` `u32` entries. Existing JSONL `Parser` can retain index storage up to a configured maximum.

**Plan:** Keep fresh per-iteration variants under one work-profile label when framing, validation, retention, checksum, and preparation work are unchanged; select `index_strategy` (`full_size`, `exact_count`, or `chunked`) in metadata and report each result. A resident full-size index reused across timed iterations changes preparation policy and receives a separate resident profile. If exact-count or chunked storage changes consumer semantics or preparation policy, split that variant into its own work profile; an added internal lexical pass within the same fresh preparation contract remains the same profile and is measured as implementation cost.

1. fresh full-size structural index;
2. fresh exact-count or chunked index storage, only as a prototype;
3. resident full-size index reused across timed iterations.

**Context ABI:** If the benchmark needs reuse across adapter calls, add explicit create, run, reset, and destroy functions. Extend the C++ adapter to own the context. Do not hide it in a process-global Zig object. Report context creation outside or inside timing.

**Resource contract:** A resident parser keeps a high-water allocation. It must enforce `max_capacity`, one active document, reset after failure, and explicit destruction. Provide an opt-in shrink operation if long-lived callers can receive one hostile large input.

**Alternative costs:** An exact-count index needs another lexical pass. A chunked ring needs cross-chunk quote state and record handoff. Neither is free. Measure offset density and maximum record size before selection.

**Profile-consumer gate:** Any genuinely new JSONL work profile must be added to `bench/common.hpp` enum, string serialization, and parser; adapter/report metadata must emit it; `scripts/compare.zig:profileMatchesReport` must classify JSONL, mode/traversal, and preparation policy. Same-contract checksum, index-strategy, or allocator revisions stay under the existing work-profile label and use metadata selectors.

**Acceptance gates:**

- A reused profile never ranks against a fresh profile under one label.
- Allocation and peak-byte reports show the intended storage change.
- No record, diagnostic, or framing behavior changes.
- Adopt two-pass or chunked storage only if it improves elapsed time by more than 5% on sparse or real input and does not regress dense by more than 5%.

## Feature-parity decisions

### Implement when the preceding gates pass

1. **Strict lazy record tapes.** P4 gives simd JSONL the useful part of a document stream while it keeps LF framing.
2. **Explicit validation-only measurement.** P2 exposes work that the library already supports.
3. **Explicit allocator and context ownership.** P1 and P7 make benchmark lifetime visible.
4. **Optional decoded-string output.** A caller-provided buffer can complement raw spans after P3. Keep raw access as the default.
5. **Detailed stream failures.** New iterators must keep record index and global source coordinates.

### Defer

1. **Use simdjson `parse_many` or `load_many` in the strict wrapper.** `load_many` preloads the complete file and both APIs use a broader concatenated-document language; a strict LF boundary layer needs separate design and measurement.
2. **Use yyjson prefix or incremental parsing as the benchmark default.** `yyjson_incr_*` uses a retained growing buffer and `MORE` state, while prefix parsing changes framing work and profile identity.
3. **Call native batch/stream APIs “chunk-fed” parity.** simdjson provides preloaded lazy batches, yyjson provides growing-buffer incremental parsing, and RapidJSON/nlohmann provide pull stream/input-adapter paths. Measure each only with an explicit framing, ownership, and preparation profile.
4. **Use in-situ parsing.** yyjson and RapidJSON can mutate input. The current packet uses borrowed immutable input. A separate destructive-input profile can test it.
5. **Parallel batch look-ahead.** The packet pins one logical CPU. A threaded profile needs separate CPU accounting.
6. **Always retain decoded strings or typed scalar sidecars.** This increases memory for callers that only need raw spans.

### Reject

1. **Change simd whitespace-only behavior to match the wrappers.** The current parser intentionally skips these lines. The shared benchmark excludes them.
2. **Call a DOM-building reference path “validation-only.”** Profile names must describe actual work.
3. **Expose a public unchecked `IndexView`.** Caller mutation can turn a saved branch into an out-of-bounds access.
4. **Rebase nested links across records.** Record-local links are part of the cursor safety contract.
5. **Replace strict JSONL with comments, trailing commas, or general concatenated JSON.** These are separate dialects or profiles.
6. **Change checksum order to gain speed.** It would invalidate cross-library oracles.
7. **Claim full NDJSON or streaming parity from Stage 1 indexing alone.** Indexing does not provide retained-document, backpressure, or stream-error semantics.

## Required serial probes

The integration owner should run these after implementation. This document does not contain benchmark results for them.

| Probe | Variable changed | Fixed work | Primary cases | Accept or reject |
|---|---|---|---|---|
| A1 | page allocator vs C allocator | retain-all tape parse and checksum | tiny valid, dense, invalid | P1 gates |
| V1 | eager tape validation vs `validateJsonl` | strict LF syntax and outcomes | all seven | Separate profile; zero record tapes |
| C1 | old string checksum vs fast path/scratch | tape and allocator | dense, escaped, Unicode, real DOM | P3 gates |
| R1 | retain-all vs reusable record tape | fresh input, strict LF, DOM checksum | sparse, dense, real | Separate lifetime profile; P4 gates |
| I1 | checked record views vs private trusted views | allocator and record storage | tiny, dense | P5 gates |
| F1 | per-record tapes vs flat retained tape | retain-all semantics | all accepted plus failure injection | P6 gates |
| X1 | fresh index vs resident index | parser and checksum | sparse, dense, real | Separate preparation profile; P7 gates |

For every rejected probe, report nanoseconds per completed rejection. Do not report MB/s. For every accepted probe, report elapsed time and throughput. Preserve raw results even when a gate rejects the implementation.

## Sources

### Repository and benchmark sources

- `src/formats/jsonl.zig:21-71` — record and document ownership.
- `src/formats/jsonl.zig:109-345` — resident parser, on-demand document, and event reader.
- `src/formats/jsonl.zig:519-678` — eager tapes, validation-only path, framing, blank records, and cleanup.
- `src/formats/jsonl.zig:684-734` — JSONL Stage 1 allocation and indexing.
- `src/core/stage1.zig:5-55` — `input.len + 3` structural-index capacity.
- `src/core/stage2.zig:443-559` — checked views, tape build, and validation.
- `src/core/stage2.zig:561-596` — shipped exact strict-JSON tape capacity.
- `src/core/stage2.zig:720-788` — reusable `TokenReader.reset` and repeated view check.
- `zig/json_family_api.zig:40-71,325-371,480-587,635-723` — decoding, scalar hashing, traversal, hard-coded page allocator, and C exports.
- `bench/adapters/jsonl.cpp:33-174` — shared line wrapper and profile metadata.
- `~/simd-bench-corpus/bench/common.hpp:29-45,193-238` — `WorkProfile`/`PreparationPolicy` enums and report label parsing.
- `~/simd-bench-corpus/scripts/compare.zig:21-45,387-415` — profile classification, mode/traversal checks, and preparation-policy acceptance.
- `bench/adapters/simd_json_family.cpp:45-87,113-123,275-284` — C ABI dispatch and simd JSONL metadata.
- `bench/adapters/simdjson.cpp:13-176` — reusable parser, per-record padded copy, DOM validation, and traversal.
- `bench/adapters/yyjson.cpp:13-143` — flags, allocator selection, document lifetime, and traversal.
- `bench/adapters/rapidjson.cpp:15-125` — parse flags, document lifetime, and traversal.
- `bench/adapters/nlohmann.cpp:14-114` — global destination, parse assignment, and traversal.
- `docs/superpowers/specs/2026-09-09-seven-format-profiles.md:19-43` — timed boundaries and JSONL shared domain.
- `results/2026-09-09-reference-analysis/jsonl-comparisons.json` — all 56 comparison rows.
- `results/2026-09-09-reference-analysis/source-provenance.json` — source/build/test identity check between the benchmark snapshot and parent `24edee4b`.
- `results/2026-09-09-comparative-rerun/full/*jsonl*synthetic.json` — raw completed-iteration denominators.
- `results/2026-09-09-reference-analysis/jsonl-process-attribution.json` — whole-process CPU time and faults.
- `results/2026-09-09-reference-analysis/jsonl-memory-syscalls.json` — whole-process mapping syscall counts.
- `results/2026-09-09-reference-analysis/jsonl-simd-jsonl-dom-hotspots.txt` — native DOM user-cycle profile.
- `results/2026-09-09-reference-analysis/jsonl-jsonl-yyjson-dom-deep-hotspots.txt` — yyjson deep DOM profile.
- `results/2026-09-09-priorities-2-5/accepted-summary.json` and `accepted-chunk-*.csv` — shipped tape-capacity allocation evidence.
- `~/simd-bench-corpus/zig/build.zig:102-116` — benchmark `api_module` linkage; libc must be enabled there before a `std.heap.c_allocator` variant can compile.
- `build-performance/CMakeCache.txt:226-254,297-307` — installed dependency paths and Zig 0.16.0.
- `/nix/store/fvlqxywq2p7h2147m0wdp8g0m38zdprp-zig-0.16.0/lib/zig/std/heap/PageAllocator.zig:15-19,44-165,187-245` — allocator vtable, POSIX mapping, remap, and free behavior.
- `/nix/store/fvlqxywq2p7h2147m0wdp8g0m38zdprp-zig-0.16.0/lib/zig/std/array_list.zig:654-665,1217-1241` — remap-first growth and alloc+copy fallback.
- `/nix/store/fvlqxywq2p7h2147m0wdp8g0m38zdprp-zig-0.16.0/lib/zig/std/heap.zig:134-155,291-331` — C allocator resize/remap/realloc/free behavior and libc prerequisite.

### Primary upstream sources

- Zig 0.16.0 standard library: [page allocator documentation](https://ziglang.org/documentation/0.16.0/std/#std.heap.page_allocator).
- simdjson 4.6.5: [`dom::parser`](https://github.com/simdjson/simdjson/blob/v4.6.5/include/simdjson/dom/parser.h) and [`document_stream`](https://github.com/simdjson/simdjson/blob/v4.6.5/include/simdjson/dom/document_stream.h).
- simdjson 4.6.5 source [`parser.h:315-320,386-420,484-510`](https://github.com/simdjson/simdjson/blob/v4.6.5/include/simdjson/dom/parser.h) — `load_many` whole-file ownership and lazy padded `parse_many` input contract.
- `/nix/store/dv6dvdcp0rhfhrxc20l9lgd31ynbfrvk-yyjson-0.12.0/include/yyjson.h:993-1051` — incremental reader availability, retained-buffer `MORE` state, standard-JSON restriction, and cleanup.
- yyjson 0.12.0: [`yyjson.h`](https://github.com/ibireme/yyjson/blob/0.12.0/src/yyjson.h), including allocator, `READ_STOP_WHEN_DONE`, read-size, and document-free contracts.
- RapidJSON installed revision: [commit `24b5e7a8b27f42fa16b96fc70aade9106cf7102f`](https://github.com/Tencent/rapidjson/tree/24b5e7a8b27f42fa16b96fc70aade9106cf7102f), [`reader.h`](https://github.com/Tencent/rapidjson/blob/24b5e7a8b27f42fa16b96fc70aade9106cf7102f/include/rapidjson/reader.h), [`document.h`](https://github.com/Tencent/rapidjson/blob/24b5e7a8b27f42fa16b96fc70aade9106cf7102f/include/rapidjson/document.h), and [`allocators.h`](https://github.com/Tencent/rapidjson/blob/24b5e7a8b27f42fa16b96fc70aade9106cf7102f/include/rapidjson/allocators.h).
- Nixpkgs RapidJSON pin: [`package.nix`](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/ra/rapidjson/package.nix).
- nlohmann/json 3.12.0: [`json.hpp`](https://github.com/nlohmann/json/blob/v3.12.0/include/nlohmann/json.hpp), including `parse`, `accept`, `sax_parse`, and allocator defaults.
