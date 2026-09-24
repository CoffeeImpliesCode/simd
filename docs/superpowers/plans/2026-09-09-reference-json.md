# Strict JSON reference analysis: simdjson, yyjson, RapidJSON, nlohmann/json

Scope: strict JSON only. Shared strict reader symbols below are owned here.
Dialect-only symbols are owned by RefDialects. JSONL framing is owned by
RefJsonl. This document only reads shared paths. It makes no production edit.

Ownership boundary (agreed with RefDialects):

- Owned here: `stage2.TokenReader.next/nextUncached/run/reset`,
  `buildTapeView/validateView/tapeCapacity` core, `validateString/skipStringBody`,
  `validateNumber/validateJsonNumber`, `TapeCursor.rawValue/rawString/rawNumber/
  valueEnd/skipValue`, `json_family_api.checksumDocument/addTapeChecksum/
  decodeChunk/hashString/hashNumber/Hasher`, page-allocator fresh tape ownership.
- Dialect-only (dependency only): `processDialectBlock/processDialectByte`,
  JSON5 atom/identifier/escape/quote/comment branches, `skipIgnored` comment
  branches, `json5WhitespaceWidth/json5LineTerminatorWidth`,
  `validateJson5Number/validateJson5Identifier`, JSONC/JSON5 quote-count capacity.

Shipped work (do not re-propose):

- Single validation of external views before allocation or slice.
- In-place reader reset (no 16,384-byte return copy).
- Strict JSON exact emitted-word reserve.
- JSONC/JSON5 conservative bound in place of one word per byte.
- See `2026-09-09-parser-performance.md` Implemented optimization wave.

Evidence labels used below:

- `MEASURED`: direct benchmark or profile number.
- `SOURCE FACT`: pinned source or adapter line.
- `INFERENCE`: likely cause, not proven by source alone. No share of a speed
  gap is assigned from source alone.

Reusable event traversal is not fresh DOM construction. A plan that reuses
events must still prove a fresh DOM cost model before it claims DOM parity.

## 1. Coverage and measured reversals

Source: `results/2026-09-09-reference-analysis/json-comparisons.json`
(64 rows: 4 references x 2 modes x 8 corpus cases).

Modes:

- `validate`: complete parse and accept or reject. Native checksum stays zero.
- `dom`: parse plus traversal plus canonical checksum plus destruction.
- Rejected input is a latency workload. In the comparative summary,
  `median_elapsed_ns` is the total timed-batch elapsed time. The absolute
  values below are `median_elapsed_ns / completed_timed_iterations` (100
  here), preserving the comparison median-of-three; raw
  `rejection_latency_ns_per_iteration` fields only verify the divisor.
  Accepted input reports throughput (`median_MB_s`). Do not compare latency
  with throughput.

Direction is descriptive with a ±5% band. It is not significance.

Corpus: `synthetic-json-valid`, `synthetic-json-invalid` (rejected),
`synthetic-json-sparse`, `synthetic-json-dense`, `synthetic-json-escaped`,
`synthetic-json-unicode`, `real-census-state-california`,
`real-simdjson-twitter`.

### Validate (native `event_stream_validate`; references `fresh_dom_parse`)

`MEASURED` reference speed ratio = reference rate / native rate for accepted
cases; native latency / reference latency for rejected cases. Value >1 means
the reference is faster.

- simdjson, all `reference_faster`:
  valid 6.087, invalid 4.944, sparse 4.266, dense 8.321, escaped 2.052,
  unicode 3.330, census 5.091, twitter 6.674.
- yyjson, all `reference_faster`:
  valid 4.077, invalid 3.036, sparse 2.976, dense 11.902, escaped 3.530,
  unicode 1.483, census 3.556, twitter 2.798.
- RapidJSON, mixed:
  valid 2.063 faster, invalid 1.576 faster, sparse 0.327 slower,
  dense 2.087 faster, escaped 0.751 slower, unicode 0.273 slower,
  census 1.717 faster, twitter 1.235 faster.
- nlohmann/json, all `reference_slower` (native faster):
  valid 0.551, invalid 0.058, sparse 0.127, dense 0.570, escaped 0.210,
  unicode 0.118, census 0.531, twitter 0.313.

Reversals in validate: native beats RapidJSON on sparse, escaped, and Unicode.
Native beats nlohmann/json on all 8 validate cases. The invalid case is
latency: native 810.47 ns/rejection vs simdjson 163.92 ns/rejection,
yyjson 266.94 ns/rejection, RapidJSON 514.36 ns/rejection, nlohmann/json
13,925.84 ns/rejection. The comparison median uses 100 completed timed
iterations per run.

### DOM (native `event_stream_checksum`; references `fresh_dom_parse_traversal`)

- simdjson, all `reference_faster`:
  valid 5.277, invalid 8.260, sparse 8.970, dense 4.125, escaped 6.302,
  unicode 8.707, census 2.971, twitter 9.441.
- yyjson, all `reference_faster`:
  valid 4.250, invalid 4.929, sparse 8.825, dense 4.855, escaped 7.861,
  unicode 7.081, census 5.642, twitter 5.583.
- RapidJSON, all `reference_faster`:
  valid 2.538, invalid 2.529, sparse 2.805, dense 2.043, escaped 3.606,
  unicode 2.983, census 2.523, twitter 2.772.
- nlohmann/json, mixed:
  valid 0.884 slower, invalid 0.087 slower, sparse 1.249 faster,
  dense 0.694 slower, escaped 1.191 faster, unicode 1.252 faster,
  census 0.515 slower, twitter 0.831 slower.

Reversals in DOM: nlohmann/json beats native on sparse, escaped, and Unicode
despite losing on valid, dense, census, twitter, and rejected latency. The
reversal matches the validate pattern in reverse: native validation is fast
on those shapes, but native DOM checksum work changes the balance.
The invalid DOM case is latency: native 1,308.06 ns/rejection vs simdjson
158.37 ns/rejection, yyjson 265.4 ns/rejection, RapidJSON 517.2 ns/rejection,
nlohmann/json 14,993.79 ns/rejection. The comparison median uses 100
completed timed iterations per run.

Full raw runs live in the benchmark packet under
`results/2026-09-09-comparative-rerun/full` and the seven-format packet
`results/2026-09-09-seven-format/full`. The comparison medians above are
directional only. The host was not isolated. See the parser performance plan
for noise limits.

### Profiles used for split analysis

`MEASURED` profile scope, all reports below:

- Whole synthetic DOM or validate process user cycles at 499 Hz, DWARF 8192.
- Includes startup, input loading, warmup, checksum traversal, and destruction.
- Not pure parse time and not timed-loop-only samples.
- Zero lost samples in the cited runs.
- Repetition counts differ to reach samples. Do not compare raw aggregate
  durations or event counts across runs. Only within-run shares are cited.
- A flat share is not a causal speedup bound and is not dense-specific.

Files under `results/2026-09-09-reference-analysis/`:

- Native DOM: `json-simd-dom-hotspots.txt` (1K samples).
- Deep DOM: `json-yyjson-dom-deep-hotspots.txt`,
  `json-simdjson-dom-deep-hotspots.txt`,
  `json-rapidjson-dom-deep-hotspots.txt`, metadata `deep-profiles.json`
  (yyjson repeat 26, simdjson repeat 24, RapidJSON repeat 11).
- Validate: `json-simd-validate-hotspots.txt` (895 samples, repeat 12),
  `json-yyjson-validate-hotspots.txt` (1K, repeat 60),
  `json-simdjson-validate-hotspots.txt` (817, repeat 60),
  `json-rapidjson-validate-hotspots.txt` (1K, repeat 20),
  `json-nlohmann-validate-hotspots.txt` (1K, repeat 6),
  metadata `validation-profiles.json`.
- nlohmann DOM short profile: `json-nlohmann-dom-hotspots.txt` (821 samples).

Key `MEASURED` splits:

- Native DOM: `bench_api.Hasher.addDecodedString` 52.09% plus
  `bench_api.JsonStringDecoder.next` 23.37% flat. `formats.json.
  initOnDemandDocument` 4.85%. `core.stage2.TokenReader.next` 3.92%.
  `core.simd.validateUtf8` 2.52%. `core.ondemand.EventReader.next` 2.33%.
  Parser work is small in DOM. Adapter checksum and unescape dominate.
- Native validate: `TokenReader.next` 27.11%, `initOnDemandDocument` 23.71%,
  `EventReader.next` 11.92%, `validateString` 9.00%, `validateUtf8` 7.77%,
  `validateNumber` 5.74%. No adapter checksum runs here. This is the parser
  baseline; the separate whole-process profiles indicate an added checksum
  path but do not isolate checksum time.
- yyjson DOM deep: adapter `hash_value` 55.59%, `yyjson_read_opts` 40.59%,
  `memmove` 2.90%. yyjson validate: `yyjson_read_opts` 93.86%,
  `memmove` 5.01%. Parse alone is the validate share. DOM adds the large
  adapter traversal share.
- simdjson DOM deep: adapter `hash_value` 62.36%, `stage2` 20.76%,
  `stage1` 10.92%, `memmove` 3.42%. simdjson validate: `stage2` 55.79%,
  `stage1` 30.47%, `memmove` 7.95%, `memset` 4.17%. DOM adds the large
  adapter traversal share on top of a two-stage parse.
- RapidJSON DOM deep: `ParseString` 60.05%, adapter `hash_value` 23.92%,
  `ParseValue` 6.11%, `ParseNumber` 5.06%, `memmove` 2.21%.
  RapidJSON validate: `ParseString` 79.61%, `ParseValue` 7.81%,
  `ParseNumber` 5.99%, `memmove` 2.62%. String parse dominates both modes.
- nlohmann DOM short: `lexer::get` 21.62%, `string::push_back` 20.87%,
  `lexer::scan_string` 12.18%, adapter `hash_value` 10.67%,
  `next_byte_in_range` 8.00%, `lexer::scan` 4.75%, `json_value::destroy`
  3.89%, `malloc_consolidate` 2.19%, `_int_malloc` 2.06%.
  nlohmann validate: `push_back` 24.02%, `lexer::get` 23.89%,
  `scan_string` 14.55%, `next_byte_in_range` 9.39%, `scan` 3.94%,
  `json_value::destroy` 5.09%. String building and per-char dispatch dominate.

## 2. Exact execution paths

### Native strict JSON (both modes)

`SOURCE FACT` adapter shell:

- `bench/adapters/simd.cpp:42-115` `SimdState` allocates context plus scratch
  once in `initialize`. `run_simd` calls `simd_bench_validate` or
  `simd_bench_dom` per iteration. Preparation policy is
  `preallocated_reused_context`. No per-iteration parser allocation.
- `zig/bench_api.zig:419-485` reports context size, alignment, and worst-case
  scratch (`input_len + 3` u32 indexes). `simd_bench_context_init` builds a
  `FixedBufferAllocator` over caller scratch and a `Parser` with
  `max_capacity`.
- `zig/bench_api.zig:488-562` `run` checks capacity, calls
  `formats.json.initOnDemandDocument`, loops `reader.next()` to EOF, and for
  `.dom` folds each event with `addEventChecksum`. Validate returns checksum
  zero. DOM returns the canonical typed checksum. `document.deinit` releases
  focus. No tape is built. No input is retained.

Index path:

- `src/formats/json.zig:54-61` `initOnDemandDocument` calls
  `parser.prepareDocument`, then `indexJsonInto`, then
  `parser.completeDocument`.
- `src/formats/json.zig:192-212` `indexJsonInto` feeds `lexical.feed` with
  `.json` and finishes with `lexical.finish`.
- `src/core/json_lexical.zig:80-99,134-204` `feed` dispatches strict blocks to
  `processStrictBlock`. That block tracks backslash runs, unescaped quotes,
  string masks with prefix-XOR, structural bytes, whitespace, atom starts,
  and opening quotes. It emits structural plus atom-start plus opening-quote
  offsets with `appendMask`.
- `src/core/ondemand.zig:105-110,142-243` `prepareDocument` returns parser-owned
  index storage. `completeDocument` writes sentinels, validates indexes,
  builds an `IndexView`, resets the token reader, marks the document active,
  and bumps generation.

Token and event path:

- `src/core/stage2.zig:754-778` `TokenReader.reset` validates the view and
  bounds input. Shipped work removed the duplicate validation.
- `src/core/stage2.zig:780-879` `next/nextUncached` skips whitespace,
  enforces single root, takes indexed bytes with `takeIndexedByte`, and
  dispatches containers, colon, comma, string, number, and literals.
- `src/core/stage2.zig:1347-1488` `validateString` uses vector
  `skipStringBody` to find quote, backslash, or control fast, then handles
  escapes, `\u` units, and UTF-8 with `firstInvalidUtf8Byte`.
- `src/core/stage2.zig:1513-1596` `validateNumber/validateJsonNumber` runs a
  strict state machine and stops at atom boundaries.
- `src/core/ondemand.zig:436-497,499-512` `EventReader.next` pulls
  `token_reader.next` through `nextParsed` and maps `ParsedToken` to `Event`
  with `eventFromToken`. Key, string, and number events borrow raw spans.
  `skip` walks nested events without materializing values.

Checksum path (DOM only):

- `zig/bench_api.zig:62-88` `Hasher` is FNV-1a with tag plus little-endian u64
  plus length-prefixed bytes. `addDecodedString` first calls
  `decodedStringLength`, then decodes again and hashes decoded bytes. Each
  string is decoded twice.
- `zig/bench_api.zig:154-236` `JsonStringDecoder.next` handles simple escapes
  per byte and `\u` with surrogate combination plus UTF-8 encode. No scratch
  buffer. Each chunk is one to four bytes.
- `zig/bench_api.zig:278-294` `hashString` tags, length-prefixes, and hashes
  decoded content.
- `zig/bench_api.zig:296-322` `hashNumber` scans for `.eE`, then calls
  `parseFloat` or `parseInt` and hashes the typed bit pattern. Validation
  already scanned the same span once.
- `zig/bench_api.zig:336-416` `addValueChecksum/addEventChecksum` maintains a
  fixed stack of array and object checksums to `max_depth` 1024. Object
  members hash key plus child digest in an order-independent sum and xor.
- `zig/json_family_api.zig:59-72,232-334` is the family-generic twin of the
  same decode-twice algorithm. Strict bench runs use `bench_api.zig`, not
  this file, but any fix must keep both oracles identical.

`TapeCursor` (`stage2.zig:109-303`: `rawValue/rawString/rawNumber/valueEnd/
skipValue/containerCount/matchingStart`) is not exercised by the benchmark.
The benchmark uses the event reader. Tape work is a separate API contract.

### simdjson (both modes)

`SOURCE FACT`:

- `bench/adapters/simdjson.cpp:16` one global `dom::parser` is reused.
- `bench/adapters/simdjson.cpp:125-176` `run_simdjson` rejects empty input,
  guards `SIMDJSON_PADDING` overflow, allocates a fresh padded vector and
  `memcpy` per iteration, then calls `parser.parse(padded, size, false)`.
  `false` disables simdjson's input-buffer padding reallocation; parser and
  document capacity can still allocate as needed (`simdjson.h:5788-5799`).
  `parse_outcome` maps `MEMALLOC/CAPACITY/OUT_OF_CAPACITY` to error and other
  failures to rejected.
- Validate still builds a full DOM, then discards it and returns zero.
  DOM walks the DOM with local `hash_value` (`simdjson.cpp:29-121`) using
  `get_object/get_array/get_string/get_int64/get_uint64/get_double/get_bool`
  and the shared `ObjectChecksum/ArrayChecksum/hash_*` from
  `json_adapters.hpp:19-161`. `BIGINT` hashes raw digits.
- Preparation: `direct_input_fresh_allocation`. The adapter creates a fresh
  padded input vector each iteration. Parser and document buffers are reused
  across parses, and can grow when capacity is insufficient. Each parse still
  performs fresh tape and string-buffer fills. Logical document destruction is
  reuse, not free.
- Upstream: `simdjson.h:5804,9617-9619` `parser::parse`; `:3624-3708`
  `dom_parser_implementation::stage1/stage2/allocate`; `:6075`
  `parser::allocate`. Pinned `4.6.5` at
  `/nix/store/2jk1npb9vlgji9af41yiyhsj5574rcxd-simdjson-4.6.5`,
  `SIMDJSON_VERSION` reported by the adapter. Source:
  `https://github.com/simdjson/simdjson/tree/v4.6.5`.

### yyjson (both modes)

`SOURCE FACT`:

- `bench/adapters/yyjson.cpp:99-144` `run_yyjson` calls `yyjson_read_opts`
  with `YYJSON_READ_NOFLAG`, null allocator, and an error struct. It rejects
  trailing data when `yyjson_doc_get_read_size != input.size`. It frees with
  `yyjson_doc_free` on both modes. Validate discards the fresh DOM.
- DOM walks with `yyjson_get_type/subtype/str/len/uint/sint/real` and the
  same shared checksum helpers (`yyjson.cpp:21-95`).
- Preparation: `direct_input_fresh_allocation`. Default heap allocator.
  No pool is passed. Each iteration allocates and frees a contiguous doc
  plus string pool.
- Upstream: `yyjson.h:733` `YYJSON_READ_NOFLAG = 0`; `:915-918`
  `yyjson_read_opts`; `:5130-5136` `yyjson_doc_free`; `:1090-1108`
  `yyjson_read_max_memory_usage`. Pinned `0.12.0` at
  `/nix/store/dv6dvdcp0rhfhrxc20l9lgd31ynbfrvk-yyjson-0.12.0`,
  `YYJSON_VERSION_STRING` reported by the adapter. Source:
  `https://github.com/ibireme/yyjson/tree/0.12.0`.

### RapidJSON (both modes)

`SOURCE FACT`:

- `bench/adapters/rapidjson.cpp:75-126` `run_rapidjson` rejects empty input
  and any embedded NUL, builds a fresh `GenericDocument` per iteration, and
  calls `Parse<kParseValidateEncodingFlag|kParseFullPrecisionFlag>`.
  `HasParseError` maps to rejected. Validate discards the fresh DOM.
- DOM walks `IsObject/IsArray/IsString/IsInt64/IsUint64/IsDouble/IsBool/
  IsNull` with `GetString/GetStringLength/GetInt64/GetUint64/GetDouble/
  GetBool` (`rapidjson.cpp:15-71`).
- Preparation: `direct_input_fresh_allocation`. Default
  `MemoryPoolAllocator<CrtAllocator>` plus `CrtAllocator` stack. Chunks grow
  from the pool. The pool is freed with the per-iteration `Document`.
- Upstream: `rapidjson/document.h` `GenericDocument::ParseStream/ParseInsitu`;
  `rapidjson/reader.h` `GenericReader::ParseString/ParseNumber/ParseValue`;
  `rapidjson/allocators.h:110-173` `MemoryPoolAllocator`;
  `RAPIDJSON_VERSION_STRING` reported by the adapter. Pinned
  `1.1.0-unstable-2025-02-05` at
  `/nix/store/x3s19aa6pvksi853jvc6njyiyndp3xcv-rapidjson-1.1.0-unstable-2025-02-05`.
  Source: `https://github.com/Tencent/rapidjson`.

### nlohmann/json (both modes)

`SOURCE FACT`:

- `bench/adapters/nlohmann.cpp:14,75-115` one global `document` is reused as
  destination, but `parse(first, last)` builds a fresh value and move-assigns
  it each iteration. Preparation is `direct_input_reused_destination`, not
  preallocated context. Old storage is destroyed during assignment.
- `parse_error` and `out_of_range` map to rejected. `bad_alloc` maps to
  error. Validate discards the fresh DOM.
- DOM walks `is_object/is_array/is_string/is_number_unsigned/is_number_integer/
  is_number_float/is_boolean/is_null` with `items()`, range iteration, and
  `get_ref/get` (`nlohmann.cpp:16-71`).
- Default types from `json.hpp:222-348`: `object_t` is `std::map` with default
  comparator, `array_t` is `std::vector`, `string_t` is `std::string`. Each
  object node and each string does allocator work. Hotspot confirms
  `std::map<std::vector<std::string` template identity.
- Upstream parse and SAX paths: `detail/input/parser.hpp`
  `parser::parse/sax_parse_internal`, `detail/input/json_sax.hpp`
  `json_sax_dom_parser`, `detail/input/lexer.hpp`
  `lexer::scan_string/get/scan/next_byte_in_range`. Version `3.12.0` from
  `NLOHMANN_JSON_VERSION_*` at
  `/nix/store/ymc296bfq75wwf7n44gzz8xng7xrsaci-nlohmann_json-3.12.0`.
  Source: `https://github.com/nlohmann/json/tree/v3.12.0`.

Runner timing (`bench/runner.hpp:610-810,1360-1390`):

- One warmup call outside timing checks outcome and DOM oracle.
- Timed loop runs 20 iterations per repeat, catches exceptions, enforces
  stable outcome and stable DOM checksum, folds checksum plus outcome into a
  sink, and reports throughput or rejection latency. Input load, hash check,
  and adapter construction stay outside timing. Per-iteration allocation,
  copy, parse, traversal, and destruction stay inside timing.

## 3. Why faster or slower

Profile shares below are within-run whole-process user cycles. They do not
prove how much of a cross-library gap a symbol causes.

### simdjson and yyjson beat native in both modes on all 8 cases

- `MEASURED`: validate gaps reach 8.321x (simdjson dense) and 11.902x
  (yyjson dense). DOM gaps reach 9.441x (simdjson twitter) and 8.825x
  (yyjson sparse). Smallest gaps are yyjson Unicode validate 1.483x and
  simdjson census DOM 2.971x.
- `MEASURED`: native validate hotspots show real parser cost in
  `TokenReader.next`, `processStrictBlock`, `validateString`, `validateUtf8`,
  and `validateJsonNumber`. Native DOM adds dominant adapter checksum cost
  on top. simdjson validate spends most cycles in its own `stage2` plus
  `stage1`. yyjson validate spends almost all cycles in `yyjson_read_opts`.
- `SOURCE FACT`: both references build a logical DOM even in validate mode,
  yet still lead. Their storage policies differ: simdjson reuses parser and
  document capacity; yyjson creates and frees a document and its pools per
  call. The native event loop does less DOM work in validate, so the gap
  points at indexing plus token validation plus event dispatch, not at DOM
  retention alone.
- `SOURCE FACT`: simdjson uses two SIMD stages with separate tape and string
  buffers and a reused parser allocation. yyjson does a single
  fused read with contiguous value and string pools. Both decode strings
  once into owned storage during parse. Native validates strings, then the
  DOM adapter decodes the same raw span twice more for length plus hash.
- `INFERENCE`: likely large costs are repeated string decode, repeated number
  conversion, per-event dispatch with borrowed spans, and scalar state
  machines after a SIMD index. Likely small costs are sentinel handling and
  exact-capacity reservation, already shipped.
- `INFERENCE`: dense numbers stress native `validateJsonNumber` plus
  `hashNumber` double scan. Escaped and Unicode strings stress
  `validateString` plus double decode. The sparse fixture is minified records
  with long unescaped ASCII strings and spaces inside strings; it tests
  payload/token density and string-span work, not outside-string whitespace.
  Any `skipWhitespace/takeIndexedByte` claim needs a separate whitespace-
  density experiment.

### RapidJSON loses to native on sparse, escaped, and Unicode validate

- `MEASURED`: native is about 3.06x faster on sparse, 1.33x on escaped, and
  3.66x on Unicode validate (inverse of 0.327, 0.751, 0.273). RapidJSON still
  leads native DOM on the same three inputs by 2.805x, 3.606x, and 2.983x.
- `MEASURED`: RapidJSON validate spends 79.61% in `ParseString` and 5.99% in
  `ParseNumber`. The string path dominates even without escapes.
- `SOURCE FACT`: the adapter uses non-destructive parse with
  `kParseValidateEncodingFlag|kParseFullPrecisionFlag`, a per-iteration fresh
  `Document`, and a chunked pool allocator. It also pre-scans for NUL with
  `source.find('\0')` before parse. Sparse inputs pay per-document and
  per-string setup plus DOM cost at low token density despite long payload
  strings. Unicode inputs pay full UTF-8 validation plus DOM string allocation
  per value.
- `SOURCE FACT`: native sparse validate does SIMD structural plus atom-start
  detection and only validates visited tokens. No DOM allocation occurs.
  The shipped exact reserve does not affect validate.
- `INFERENCE`: RapidJSON fixed per-document and per-string costs likely hurt
  it on sparse and Unicode validate. Native DOM then loses on the same inputs
  because its own per-string decode-twice checksum exceeds the reference DOM
  traversal cost there. The reversal is a checksum effect, not proof that
  native parsing is uniformly faster on those shapes.

### nlohmann/json loses validate everywhere but wins sparse, escaped, Unicode DOM

- `MEASURED`: validate gaps are extreme: invalid 0.058x, unicode 0.118x,
  sparse 0.127x. DOM gaps narrow and flip on three shapes: sparse 1.249x,
  escaped 1.191x, unicode 1.252x for nlohmann/json.
- `MEASURED`: nlohmann validate and DOM both spend most cycles in
  `lexer::scan_string/get`, `string::push_back`, and `next_byte_in_range`.
  DOM adds only about 10.67% adapter `hash_value` plus `destroy`, `malloc`,
  and consolidate. Parse dominates. Destruction and allocation are visible
  but smaller than string scanning.
- `SOURCE FACT`: default `std::map` objects, `std::vector` arrays, and
  `std::string` values allocate per entity. Global document reuse does not
  avoid per-iteration node and string allocation. Exceptions map parse errors
  to rejected, which adds throw cost on the invalid path.
- `INFERENCE`: native validate wins because it never allocates a DOM and
  never builds ordered-map nodes. Native DOM loses on sparse, escaped, and
  Unicode because its double-decode string checksum costs more than walking
  an already-decoded `std::string`, even with map overhead. Dense numeric
  inputs and the real twitter object workload keep native ahead in this
  sample. Census also favors native, but its array-of-strings shape provides
  no evidence for numeric or map-cost attribution.
- Rejected latency is not throughput. nlohmann invalid latency is about
  17x native validate latency and about 11x native DOM latency. Do not rank
  it as a throughput gap.

### DOM checksum work, not parser SIMD, is the first native target

- `MEASURED`: Separate whole-process profiles show the DOM run's
  `addDecodedString` plus `JsonStringDecoder.next` at about 75% of its
  cycles. The validate run shows `TokenReader.next` 27.11% and
  `initOnDemandDocument` 23.71%; the DOM run shows those at 3.92% and
  4.85%. This indicates an added checksum path, but separate profiles do
  not support subtracting parser stages or isolating checksum time.
- `SOURCE FACT`: `addDecodedString` calls `decodedStringLength` then decodes
  again. Both passes call `JsonStringDecoder.next` per byte or escape.
  References expose already-decoded strings to their hash walk.
- `INFERENCE`: a no-escape raw-span fast path plus a decode-once scratch
  path likely removes the largest native DOM cost without touching SIMD
  indexing. Parser SIMD rewrite before this fix would optimize the smaller
  share.

## 4. Feature matrix

Exercised means the benchmark times it. Supported means the pinned source
has it, whether timed or not. Supported does not prove cost on these inputs.

| Area | Native strict JSON | simdjson | yyjson | RapidJSON | nlohmann/json |
|---|---|---|---|---|---|
| Strict parse plus single-root plus trailing check, exercised | Yes: index plus `TokenReader` plus `EventReader` | Yes: `parse` plus error code | Yes: `read_opts` plus read-size check | Yes: `Parse` plus `HasParseError`, plus NUL pre-scan | Yes: `parse(first,last)` plus exception map |
| Typed DOM checksum traversal, exercised | Yes: event-fold checksum, no retained DOM | Yes: DOM walk with decoded `string_view` | Yes: DOM walk with pooled strings | Yes: DOM walk with `GetString/Length` | Yes: DOM walk with `std::string` ref |
| String decode policy, exercised | Validate only; DOM decodes twice per string | Decode once to string buffer during `stage2` | Copy or pool strings during `read_opts` | Decode to pooled strings during `ParseString` | Build `std::string` during `scan_string` |
| Number typing, exercised | Validate grammar, then `parseFloat/parseInt` in checksum | Typed tape values plus `get_*` | Subtype uint/sint/real plus `get_*` | `IsInt64/IsUint64/IsDouble` plus full-precision parse | Unsigned/integer/float plus `get` |
| Allocation in timing, exercised | None per iteration; reused parser plus scratch | Reused parser; fresh padded copy plus tape/string fill | Fresh doc plus pools; freed per iteration | Fresh `Document` plus pool chunks; freed per iteration | Fresh nodes plus strings; old doc destroyed on assign |
| Rejection path, exercised as latency | `errorCode` maps grammar errors to rejected | Error code maps to rejected, alloc errors to error | `read_code` maps alloc errors to error, else rejected | `HasParseError` to rejected; NUL to rejected | `parse_error/out_of_range` to rejected |
| Streaming or lazy field access, not exercised | `TokenCursor/skipChild`, `EventReader.peek/skip` exist; benchmark always drains all events | On Demand API exists upstream; adapter uses DOM only | Incremental `yyjson_incr_read` exists upstream; adapter uses one-shot DOM | SAX `GenericReader/Handler` exists upstream; adapter uses DOM only | SAX acceptor and callback parser exist upstream; adapter uses DOM `parse` |
| Mutation plus serialization, not exercised | No public mutation or writer; tape is read-only | `simdjson::builder` and `to_string/minify` exist upstream; not used | Mutable doc plus `yyjson_mut_*` plus `yyjson_write_*` exist upstream; not used | `GenericDocument` mutation plus `Writer` exist upstream; not used | `patch/merge_patch/dump` plus initializer mutation exist; not used |
| Pointer or path lookup, not exercised | No JSON Pointer or Path API | JSON Pointer (`at_pointer/at_path`) exists upstream; not used | JSON Pointer/ Patch (`ptr_add/get`, `merge_patch`) exist upstream; not used | JSON Pointer (`GenericPointer`) exists upstream; not used | JSON Pointer (`json_pointer`) plus `at` plus `contains` exist; not used |
| In-situ or pooled input choice, not exercised | Borrowed input; parser-owned indexes; no input mutation | `padded_string` reuse; adapter copies per iteration | `YYJSON_READ_INSITU` supported upstream; adapter uses `NOFLAG` copy | `ParseInsitu` supported upstream; adapter uses non-destructive parse | Iterator-range parse; no in-situ mode |
| Duplicate keys and nonfinite values | Outside shared ranked domain per packet spec | Behavior exists upstream; not ranked here | Behavior exists upstream; not ranked here | Behavior exists upstream; not ranked here | Behavior exists upstream; not ranked here |

Do not claim reusable event work equals fresh DOM work. Native validate
avoids DOM allocation by design. Native DOM still avoids DOM allocation but
pays event-fold decode. Reference adapters parse a DOM in both modes, but
allocation differs: simdjson reuses parser/document capacity while filling
buffers per parse; yyjson and RapidJSON allocate and free fresh documents;
nlohmann builds a fresh value and destroys old storage on assignment.
The comparison is a system tradeoff, not a pure scan race.

## 5. Prioritized optimization tasks

Keep fast and restricted APIs unchanged. Gate profile expansion separately.
Each task states target symbols, ownership, contract, alternative,
dependency, correctness cases, and accept or reject gates.

### P0-1. Fast-path raw strings; isolate decode-once scratch

Primary strict targets: `zig/bench_api.zig:28-32 Context`,
`:62-88 Hasher.addDecodedString`, `:278-294 hashString`,
`:154-221 JsonStringDecoder.next`, `:278-287 decodedStringLength`, and
`:419-470 simd_bench_context_required_scratch/simd_bench_context_init`.
`zig/json_family_api.zig:59-72,232-340` is the canonical-oracle twin, not
the same preparation or scratch-lifetime contract.

Ownership: the strict adapter caller owns `Context` and its scratch for the
full prepared lifetime. A strict decode slice may be reserved in that
caller-owned storage only through an explicit required-scratch and context-init
contract under the existing `preallocated_reused_context` policy. The parser
still returns borrowed, still-escaped spans; no `TokenReader`, `EventReader`,
or `TapeCursor` lifetime changes. The fresh JSONC, JSON5, and JSONL family
calls have no equivalent prepared context; their timed call owns all temporary
storage.

Plan:

1. In both checksum helpers, add a branch for a raw span with no backslash:
   hash its length plus bytes directly. This path needs no decode scratch,
   allocation, or preparation-policy change.
2. For strict JSON escaped strings, prototype one-pass decode into a dedicated
   caller-owned byte slice reserved by the existing prepared context lifecycle.
   Make any required-scratch formula or context ABI change explicit. Capacity
   must cover every accepted string in the profile; do not use a fixed stack
   buffer or overlap live parser indexes. Record decoded length, then hash the
   length prefix plus decoded bytes.
3. Do not apply strict scratch reuse to `json_family_api`. Keep its escaped
   strings on the current two-pass path unless allocation, growth, and free
   remain inside the fresh timed call. A prepared family variant requires a
   distinct preparation policy and work-profile name, with separate results;
   it must not replace a fresh profile silently.
4. Keep the canonical oracle identical: tag, decoded-length u64, decoded
   bytes. A `memchr`-style backslash scan is enough for the first step.

Alternatives: ship only the allocation-free no-escape path; keep strict
escaped strings on two passes if context partitioning is unsafe; or measure a
fresh family decode buffer whose allocation and destruction remain timed.
Reject a persistent family cache under the current fresh profiles because it
changes setup and lifetime semantics.

Dependencies: none on parser stages. Coordinate with RefJsonl and RefDialects
on shared oracle bytes, but not on scratch ownership. `json_family_api`
semantics must retain joint checksum vectors while each adapter keeps its
declared preparation policy.

Correctness: empty strings, all simple escapes, `\u` plus surrogates,
lone low/high surrogates (reject), overlong or invalid UTF-8 already
rejected by `validateString`, embedded `/`, `b/f/n/r/t`, very long strings
at the supported input and token-span limits, object keys plus values.

Gates:

- Accept strict: identical DOM checksums on all accepted strict-JSON fixtures
  plus targeted escape, surrogate, and long-string vectors; repeatable gain on
  synthetic escaped, Unicode, dense, and real twitter DOM under the paired
  policy; no validate allocation or parser-index overlap.
- Accept family: identical cross-family checksums; the raw-span fast path adds
  no allocation; any escaped decode buffer allocates, grows, and frees inside
  the fresh timed call.
- Reject: oracle change; hidden setup outside timing; silent preparation or
  work-profile change; fixed scratch that rejects valid long strings; lifetime
  escape; or a no-escape dense DOM regression beyond noise.

This is the first task. Do not start parser SIMD rewrite before measuring it.

### P0-2. Avoid double number scan in DOM checksum

Targets: `zig/bench_api.zig:296-322 hashNumber`;
`src/core/stage2.zig:1170-1187 consumeNumber`,
`:1525-1596 validateJsonNumber`; event payload `ondemand.Event.number`.

Ownership: parser owns grammar validation. Checksum owns typed conversion.
Options must preserve the borrowed raw-span event contract.

Plan:

1. Measure `hashNumber` alone on dense and twitter DOM with a counter or
   focused profile. Split integer vs float spans. Keep the census
   array-of-strings control in paired checksum runs, but report it as zero
   numeric-token coverage.
2. Prototype one: keep raw span, but select integer vs float from the first
   pass (presence of `.eE` plus sign) without rescanning for selection, then
   convert once. Prototype two: emit a one-byte number class from
   `consumeNumber` alongside the raw span for checksum use only.
3. Keep `parseFloat/parseInt` semantics and nonfinite rejection. Do not
   accept `Infinity/NaN` in strict JSON.

Alternatives: full custom float parser; or cache converted numbers in tape.
Reject both for now. Custom float parsing risks oracle drift. Tape caching
changes event ownership.

Dependencies: P0-1 for clean DOM attribution. No index change.

Correctness: `-0`, large u64 vs i64 boundaries, exponent forms, fraction
forms, leading-zero rejection, plus/dot/Infinity/NaN rejection in strict
mode, twitter integer ids. The census array-of-strings control must remain
checksum-stable and is not numeric coverage.

Gates:

- Accept: identical checksums on dense, census control, twitter, plus boundary
  integer and float vectors; repeatable DOM gain on number-heavy inputs with
  no validate regression.
- Reject: any typed-hash change; any strict-grammar widening; any float
  rounding difference from `parseFloat` bit pattern.

### P1-1. Reduce per-event dispatch on validate after checksum is fixed

Targets: `src/core/stage2.zig:780-879 TokenReader.next/nextUncached`,
`:1004-1029 takeIndexedByte`; `src/core/ondemand.zig:436-497
EventReader.next/nextParsed`, `:499-512 eventFromToken`;
`src/formats/json.zig:54-61 initOnDemandDocument`.

Ownership: shared reader owned here. Changes must not alter dialect error
precedence owned in part by RefDialects. Keep `reset` single-validation
contract from shipped work.

Plan:

1. Use fresh validate profiles (`json-simd-validate-hotspots.txt`) as the
   baseline, not DOM. Split `processStrictBlock`, `takeIndexedByte`,
   `skipWhitespace`, `validateString`, and `validateJsonNumber`.
2. Test narrow wins only: branch ordering for common structural bytes,
   fewer bounds checks on the hot `byte_position` path, cheaper
   `indexCount` access. Inspect generated code before keeping a change.
3. Do not fuse index and validation into one pass yet. That is a larger
   architecture change with error-offset risk.

Alternatives: full pull-parser state rewrite; or table-driven dispatch.
Defer both until P0 gains are measured.

Dependencies: P0-1 and P0-2 for correct attribution. No capacity change.

Correctness: all rejected fixtures, trailing data, single-root violations,
unclosed containers, depth limit 1024, control bytes in strings,
truncated escapes and numbers.

Gates:

- Accept: identical errors, offsets, diagnostics, outcomes, and checksums;
  repeatable validate gain on valid, dense, sparse, and real inputs under
  the paired policy.
- Reject: any diagnostic offset change; any `InvalidStructuralIndex`
  precedence change; any dialect-only behavior change claimed as strict win.

### P1-2. Add a timed rejection fast path only with latency proof

Targets: `src/core/stage2.zig:885-898 finish`,
`:906-968 skipIgnored` strict early return, `errorCode` in
`zig/bench_api.zig:572-592`; invalid fixture `synthetic-json-invalid`.

Ownership: strict grammar owned here. No new error code in the C ABI.
Map stays accepted, rejected, invalid argument, input too large.

Plan:

1. Profile invalid validate and invalid DOM separately. Find where native
   spends 810.47 ns/rejection (validate) and 1,308.06 ns/rejection (DOM),
   versus simdjson 163.92 and 158.37 ns/rejection. The comparison median
   uses 100 completed timed iterations per run; keep aggregate-batch fields
   labeled as such.
2. Test early structural mismatch detection only if it preserves first-error
   offsets. Example: fail fast on unindexed bytes without extra scans.
3. Keep exception-free behavior. nlohmann throw cost is not a model to copy.

Alternatives: speculative SIMD error search ahead of the reader. Defer
unless P1-1 leaves a proven invalid-only hotspot.

Dependencies: P1-1. No allocator change.

Correctness: truncated documents, bad escapes, bad numbers, unclosed
containers, trailing garbage, empty input. Offsets must not move.

Gates:

- Accept: identical invalid offsets and outcomes plus repeatable latency
  reduction on the invalid fixture in both modes.
- Reject: any offset change; any accepted-input regression; any claim that
  latency gain implies throughput gain.

### P2-1. Prove whether index throughput or validation dominates sparse

Targets: `src/core/json_lexical.zig:134-204 processStrictBlock`;
`src/formats/json.zig:192-212 indexJsonInto`;
`src/core/stage2.zig:993-1029 indexCount/indexAt/takeIndexedByte`.

Ownership: strict index owned here. JSONL line scan is owned by RefJsonl.
Do not change JSONL record-boundary masks here.

Plan:

1. Run exact payload experiments: vary payload string length, token density,
   and string-scan length on fixed byte size; count `appendMask` writes vs
   `TokenReader` steps. Keep the sparse fixture's minified long strings as a
   control; its spaces are inside strings.
2. Add a separate whitespace-density experiment with spaces outside strings
   before attributing cost to `skipWhitespace/takeIndexedByte`.
3. Test `extractBitIndexesChecked` tuning and wider VLEN handling only with
   scalar-differential coverage at 4, 16, 32, 64.
4. Keep `u32` offsets and three sentinels unchanged.

Alternatives: sparse skip index; or combined index-validate kernel. Both are
research only until measurement isolates index cost from validation cost.

Dependencies: P1-1. Needs paired measurement policy from the parser plan.

Correctness: vector-boundary splits, backslash-run carry, quote carry,
atom-start carry, empty and whitespace-only inputs.

Gates:

- Accept: scalar-differential equality at all widths plus repeatable sparse
  and valid gain with no dense or Unicode regression.
- Reject: any index-order change; any sentinel change; any width-specific
  failure.

## 6. Feature parity: useful vs unrelated

Preserve existing fast and restricted APIs by default. Any expansion is
explicit and separately benchmarked.

Useful parity (small, benchmark-relevant):

- Decoded-string view for traversal without changing the event contract.
  Form: optional helper that decodes a borrowed raw span into caller scratch.
  Cost: scratch size plus UTF-8 policy. Benefit: lets future DOM users avoid
  re-decode. Gate: oracle unchanged; no hidden allocation; explicit scratch
  ownership.
- Typed-number view for traversal. Form: return integer class or float bits
  alongside raw span on request. Cost: conversion policy plus error mapping.
  Benefit: avoids second scan for checksum-like consumers. Gate: strict
  grammar unchanged; bit-identical hashes.
- Reusable `Parser` plus scratch guidance for embedding. Already true for
  native. Document capacity and `document_active` rules. No code change is
  required.

Defer or reject (application APIs, not parser gaps):

- simdjson On Demand and DOM mutation, serialization, JSON Pointer/Path.
  Defer. Useful for applications, but the benchmark never calls them. Adding
  them does not fix decode-twice cost. Security and resource costs include
  new cursor lifetimes and output allocation. Revisit only with a dedicated
  lazy-traversal benchmark and explicit API approval.
- yyjson mutable doc, `yyjson_mut_*`, `yyjson_write_*`, JSON Pointer/Patch,
  and incremental read. Defer. Same reason. In-situ mode mutates input and
  conflicts with borrowed-source guarantees. Any in-situ experiment needs a
  separate opt-in API and safety review.
- RapidJSON SAX handler, in-situ parse, `GenericPointer`, and `Writer`.
  Defer. SAX would be a different work contract from fresh DOM traversal.
  In-situ parsing mutates caller bytes. A SAX-shaped native API would need
  its own work profile and checksum oracle before any comparison.
- nlohmann/json `json_pointer`, `patch`, `merge_patch`, `dump`, iterators,
  and implicit conversions. Reject for parser parity. These are application
  conveniences over an owning DOM. They carry map, string, exception, and
  allocation costs already visible in profiles. Do not copy the owning
  `std::map` model into the borrowing parser.
- Full CommonMark, XML namespace/DTD, or YAML type resolution as implied by
  partial extensions. Do not promise. This document covers strict JSON only.
  Cross-format claims belong in their own reference documents.

Compatibility, security, and resource notes for any parity work:

- Keep UTF-8 validation and first-error offsets. Do not trade diagnostics
  for speed.
- Keep depth limit 1024 and u32 bounds. Any scratch growth needs explicit
  overflow and `TapeTooLarge` behavior.
- Keep no-allocate validate guarantee. Any helper that allocates must be a
  separate explicit call, not a silent change to `next`.
- Keep source borrowing. Any decoded or converted view must state whether
  bytes are borrowed, scratch-owned, or freshly allocated, and who frees.

## 7. Sources

Pinned builds (`build-performance/CMakeCache.txt`):

- `CMAKE_CXX_FLAGS=-std=c++23 -march=x86-64-v3 -mtune=generic`,
  `CMAKE_BUILD_TYPE=Release` (`-O3 -DNDEBUG`), `SIMD_BENCH_CPU_PROFILE=
  x86_64_v3`, `SIMD_BENCH_TARGET_TRIPLE=x86_64-linux-gnu`.
- `SIMDJSON_INCLUDE_DIR=/nix/store/2jk1npb9vlgji9af41yiyhsj5574rcxd-
  simdjson-4.6.5/include`,
  `SIMDJSON_LIBRARY=.../lib/libsimdjson.so`.
- `YYJSON_INCLUDE_DIR=/nix/store/dv6dvdcp0rhfhrxc20l9lgd31ynbfrvk-
  yyjson-0.12.0/include`, `YYJSON_LIBRARY=.../lib/libyyjson.a`.
- `RAPIDJSON_INCLUDE_DIR=/nix/store/x3s19aa6pvksi853jvc6njyiyndp3xcv-
  rapidjson-1.1.0-unstable-2025-02-05/include`.
- `NLOHMANN_INCLUDE_DIR=/nix/store/ymc296bfq75wwf7n44gzz8xng7xrsaci-
  nlohmann_json-3.12.0/include`.
- `SIMD_SOURCE_ROOT=~/projects/simd-performance`,
  `ZIG_EXECUTABLE=.../zig-0.16.0/bin/zig`.
- Dependency CPU note per packet spec: `dependency_build_profile=
  external-prebuilt`, `dependency_cpu_profile=unknown`.

Measured inputs:

- `results/2026-09-09-reference-analysis/json-comparisons.json` (64 rows).
- `results/2026-09-09-reference-analysis/json-simd-dom-hotspots.txt`.
- `results/2026-09-09-reference-analysis/json-yyjson-dom-deep-hotspots.txt`,
  `json-simdjson-dom-deep-hotspots.txt`,
  `json-rapidjson-dom-deep-hotspots.txt`, `deep-profiles.json`.
- `results/2026-09-09-reference-analysis/json-simd-validate-hotspots.txt`,
  `json-yyjson-validate-hotspots.txt`,
  `json-simdjson-validate-hotspots.txt`,
  `json-rapidjson-validate-hotspots.txt`,
  `json-nlohmann-validate-hotspots.txt`, `validation-profiles.json`.
- `results/2026-09-09-reference-analysis/json-nlohmann-dom-hotspots.txt`.
- Packet contracts:
  `~/simd-bench-corpus/docs/superpowers/specs/
  2026-09-09-seven-format-profiles.md`.
- Shipped baseline and noise policy:
  `~/projects/simd-performance/docs/superpowers/plans/
  2026-09-09-parser-performance.md`, especially Implemented optimization wave.

Adapter and native paths cited inline:

- `bench/adapters/json_adapters.hpp:19-161`,
  `bench/adapters/simdjson.cpp:16,29-176`,
  `bench/adapters/yyjson.cpp:21-144`,
  `bench/adapters/rapidjson.cpp:15-126`,
  `bench/adapters/nlohmann.cpp:14-115`,
  `bench/adapters/simd.cpp:42-176`,
  `bench/runner.hpp:610-810,1360-1390`,
  `zig/bench_api.zig:62-88,154-236,278-322,336-562,572-592`,
  `zig/json_family_api.zig:59-72,232-334`,
  `src/formats/json.zig:54-61,192-212`,
  `src/core/json_lexical.zig:80-99,134-204`,
  `src/core/stage2.zig:109-303,754-879,1004-1029,1347-1596`,
  `src/core/ondemand.zig:105-110,142-243,436-512`.

Upstream identities:

- simdjson `4.6.5`, `SIMDJSON_VERSION`, `SIMDJSON_PADDING`,
  `dom::parser::parse`, `dom_parser_implementation::stage1/stage2/allocate`.
  Upstream: `https://github.com/simdjson/simdjson/tree/v4.6.5`.
  Installed: `/nix/store/2jk1npb9vlgji9af41yiyhsj5574rcxd-simdjson-4.6.5/
  include/simdjson.h`.
- yyjson `0.12.0`, `YYJSON_READ_NOFLAG`, `yyjson_read_opts`,
  `yyjson_doc_free`, `yyjson_get_type/subtype/str/len`.
  Upstream: `https://github.com/ibireme/yyjson/tree/0.12.0`.
  Installed: `/nix/store/dv6dvdcp0rhfhrxc20l9lgd31ynbfrvk-yyjson-0.12.0/
  include/yyjson.h`.
- RapidJSON `1.1.0-unstable-2025-02-05`, `RAPIDJSON_VERSION_STRING`,
  `GenericDocument::Parse<kParseValidateEncodingFlag|
  kParseFullPrecisionFlag>`, `GenericReader::ParseString/ParseNumber/
  ParseValue`, `MemoryPoolAllocator/CrtAllocator`.
  Upstream: `https://github.com/Tencent/rapidjson`.
  Installed: `/nix/store/x3s19aa6pvksi853jvc6njyiyndp3xcv-
  rapidjson-1.1.0-unstable-2025-02-05/include/rapidjson/`.
- nlohmann/json `3.12.0`, `NLOHMANN_JSON_VERSION_*`,
  `basic_json::parse`, `lexer::scan_string/get/scan`,
  `parser::sax_parse_internal`, `json_sax_dom_parser`.
  Upstream: `https://github.com/nlohmann/json/tree/v3.12.0`.
  Installed: `/nix/store/ymc296bfq75wwf7n44gzz8xng7xrsaci-
  nlohmann_json-3.12.0/include/nlohmann/`.
