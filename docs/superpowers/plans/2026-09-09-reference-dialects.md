# JSONC and JSON5 dialect reference analysis

Scope: native `simd-jsonc` and `simd-json5` versus jsoncons 1.9.0.
The JSON5 reference is a common subset through jsoncons. It is not a full JSON5 implementation.
Direction uses a descriptive ±5% band. It is not a significance test.
Labels: `MEASURED` means a number from a report or profile. `SOURCE FACT` means a fact read from pinned source. `INFERENCE` means an interpretation that needs a new experiment.

Ownership: shared scanner, string, number, reader, tape, and checksum contracts belong to the strict JSON roadmap (`RefJson`). This document owns dialect grammar, comment, trailing-comma, quote, identifier, number-extension, whitespace, and first-error work. Shared items appear below only as dependencies.

## 1. Coverage and measured reversals

### 1.1 Measurement identity

- `MEASURED`: comparisons aggregate three processes per workload, implementation, and mode. Reports carry 100 timed iterations per case. `SOURCE FACT`: `~/simd-bench-corpus/docs/superpowers/specs/2026-09-09-seven-format-profiles.md:19-27` defines modes, work profiles, preparation, CPU pinning, and compiler identity checks.
- `SOURCE FACT`: native and reference adapters use `fresh_dom_parse` for `validate` and `fresh_dom_parse_traversal` for `dom`, with `direct_input_fresh_allocation`. Native descriptors: `~/simd-bench-corpus/bench/adapters/simd_json_family.cpp:251-272`. Reference JSONC descriptor: `~/simd-bench-corpus/bench/adapters/jsoncons.cpp:146-156`. Reference JSON5 descriptor: `~/simd-bench-corpus/bench/adapters/simd_json_family.cpp:287-297`.
- `SOURCE FACT`: `validate` measures complete parsing and acceptance or rejection. Native JSONC, JSON5, Markdown, XML, and YAML adapters build a fresh tape even in `validate` mode and then discard it. Spec: `~/simd-bench-corpus/docs/superpowers/specs/2026-09-09-seven-format-profiles.md:19-23`.
- `SOURCE FACT`: native `runDocument` builds a tape for both modes and runs the checksum only in `dom` mode. It uses the page allocator. All build errors map to accept, reject, or fail. Paths: `~/simd-bench-corpus/zig/json_family_api.zig:589-633`.
- `SOURCE FACT`: jsoncons `validate` builds a full DOM through `try_decode_json` and skips only the checksum in `validate` mode. JSONC path: `~/simd-bench-corpus/bench/adapters/jsoncons.cpp:105-140`. JSON5 path: `~/simd-bench-corpus/bench/adapters/simd_json_family.cpp:209-245`.
- `MEASURED`: whole-process profiles use synthetic DOM runs, repeat 3, `perf record -q -e cycles:u -F 499 --call-graph dwarf,8192`, `taskset -c 2`. They include startup, loading, warmup, checksum, and destruction. They are not pure parse time. User cycles exclude kernel time. Metadata: `~/simd-bench-corpus/results/2026-09-09-reference-analysis/profiles.json:289-452`.
- `MEASURED`: native JSONC process user time is 2.48 s versus 1.06 s for jsoncons. Native JSON5 process user time is 3.44 s versus 1.01 s for the JSON5 reference. Same metadata rows. Do not compare raw aggregate durations across runs that use different repetition counts. Use shares for structure and medians for speed.
- Rejected rows report 100-call batch time, not throughput. Their `median_MB_s` is zero. `median_elapsed_ns` is the median batch total; per-rejection values below divide that total by 100. Ratios are unchanged by this division. `SOURCE FACT`: raw reports record `completed_timed_iterations: 100` and a per-iteration field; for example `~/simd-bench-corpus/results/2026-09-09-comparative-rerun/full/3-jsonc-simd-jsonc-dom-synthetic.json:47-68`. Accepted rows compare `median_MB_s`.

### 1.2 JSONC versus jsoncons, all cases

`MEASURED` source: `~/simd-bench-corpus/results/2026-09-09-reference-analysis/jsonc-comparisons.json`. Ratios are reference speed ratios. Accepted ratios use throughput. Rejected ratios use elapsed time.

| Mode | Case | Bytes | Native | Reference | Ratio | Band |
|---|---|---:|---|---|---|---|
| `validate` | `synthetic-jsonc-valid` | 108 | 6.42 MB/s | 40.95 MB/s | 6.375x | reference faster |
| `validate` | `synthetic-jsonc-invalid` | 17 | 1562708 ns/100-call batch; 15627.08 ns/rejection | 32066 ns/100-call batch; 320.66 ns/rejection | 48.734x | reference faster, rejection latency |
| `validate` | `synthetic-jsonc-sparse` | 510526 | 392.02 MB/s | 240.50 MB/s | 0.613x | native faster |
| `validate` | `synthetic-jsonc-dense` | 152361 | 28.44 MB/s | 28.59 MB/s | 1.005x | neutral |
| `validate` | `synthetic-jsonc-escaped` | 251070 | 161.47 MB/s | 176.10 MB/s | 1.091x | reference faster |
| `validate` | `synthetic-jsonc-unicode` | 513214 | 350.31 MB/s | 205.56 MB/s | 0.587x | native faster |
| `validate` | `real-jsonc-twitter-derived` | 631564 | 79.65 MB/s | 79.43 MB/s | 0.997x | neutral |
| `dom` | `synthetic-jsonc-valid` | 108 | 5.90 MB/s | 54.24 MB/s | 9.194x | reference faster |
| `dom` | `synthetic-jsonc-invalid` | 17 | 1523171 ns/100-call batch; 15231.71 ns/rejection | 31755 ns/100-call batch; 317.55 ns/rejection | 47.966x | reference faster, rejection latency |
| `dom` | `synthetic-jsonc-sparse` | 510526 | 43.00 MB/s | 180.33 MB/s | 4.194x | reference faster |
| `dom` | `synthetic-jsonc-dense` | 152361 | 18.84 MB/s | 24.57 MB/s | 1.304x | reference faster |
| `dom` | `synthetic-jsonc-escaped` | 251070 | 34.83 MB/s | 139.61 MB/s | 4.008x | reference faster |
| `dom` | `synthetic-jsonc-unicode` | 513214 | 42.29 MB/s | 152.80 MB/s | 3.613x | reference faster |
| `dom` | `real-jsonc-twitter-derived` | 631564 | 37.01 MB/s | 74.21 MB/s | 2.005x | reference faster |

Reversals:

- Native wins are validate-only: sparse and Unicode. Dense and real Twitter validate are neutral. All DOM cases favor jsoncons.
- The mode reversal on sparse and Unicode is the main JSONC signal. The same bytes parse faster natively in validate but slower in DOM. `INFERENCE`: DOM adds native tape traversal and checksum work that the validate path skips. This needs a focused parse-only versus traversal-only split before assigning cost.
- Tiny cases show large reference gaps: 108-byte valid and 17-byte invalid. `MEASURED`: their time-spread ratios are 1.447 versus 2.179 in validate and 1.043 versus 1.003 in DOM. `INFERENCE`: fixed setup dominates tiny inputs. Do not tune the lexer for 108 bytes.
- Rejected cases are per-rejection latency gaps of about 48x. They do not measure throughput. The corpus invalid fixture is `{"missing":}` at `~/simd-bench-corpus/corpus/synthetic/jsonc-invalid.jsonc:1-3`.

### 1.3 JSON5 common subset versus jsoncons, all cases

`MEASURED` source: `~/simd-bench-corpus/results/2026-09-09-reference-analysis/json5-comparisons.json`.

| Mode | Case | Bytes | Native | Reference | Ratio | Band |
|---|---|---:|---|---|---|---|
| `validate` | `synthetic-json5-sparse` | 510526 | 195.80 MB/s | 210.01 MB/s | 1.073x | reference faster |
| `validate` | `synthetic-json5-dense` | 152361 | 23.85 MB/s | 30.69 MB/s | 1.286x | reference faster |
| `validate` | `synthetic-json5-escaped` | 251070 | 107.49 MB/s | 179.38 MB/s | 1.669x | reference faster |
| `validate` | `synthetic-json5-unicode` | 513214 | 82.08 MB/s | 211.68 MB/s | 2.579x | reference faster |
| `validate` | `synthetic-json5-invalid` | 16 | 1981250 ns/100-call batch; 19812.50 ns/rejection | 53397 ns/100-call batch; 533.97 ns/rejection | 37.104x | reference faster, rejection latency |
| `validate` | `real-json5-twitter-derived` | 631564 | 69.02 MB/s | 84.39 MB/s | 1.223x | reference faster |
| `dom` | `synthetic-json5-sparse` | 510526 | 39.38 MB/s | 165.01 MB/s | 4.190x | reference faster |
| `dom` | `synthetic-json5-dense` | 152361 | 16.85 MB/s | 25.17 MB/s | 1.494x | reference faster |
| `dom` | `synthetic-json5-escaped` | 251070 | 35.42 MB/s | 134.67 MB/s | 3.802x | reference faster |
| `dom` | `synthetic-json5-unicode` | 513214 | 30.10 MB/s | 154.63 MB/s | 5.138x | reference faster |
| `dom` | `synthetic-json5-invalid` | 16 | 1905524 ns/100-call batch; 19055.24 ns/rejection | 102169 ns/100-call batch; 1021.69 ns/rejection | 18.651x | reference faster, rejection latency |
| `dom` | `real-json5-twitter-derived` | 631564 | 34.19 MB/s | 77.00 MB/s | 2.252x | reference faster |

Reversals: there are none in favor of native JSON5. The closest case is sparse validate at 1.073x. Unicode shows the largest DOM gap at 5.138x. The invalid fixture is `{"broken": [1,}` at `~/simd-bench-corpus/corpus/synthetic/json5/synthetic-json5-invalid.json5:1`.

Checksums agree on every accepted DOM case for both dialects. `MEASURED`: native and reference checksums match in the byte-size probe, including sparse, dense, escaped, Unicode, and real Twitter cases. `INFERENCE`: equal checksums show that the compared outputs agree, so the speed gap reflects different work and not a checksum mismatch.

## 2. Exact execution paths

### 2.1 Native JSONC path

1. The C++ adapter selects `simd_bench_jsonc_validate` or `simd_bench_jsonc_dom`. `SOURCE FACT`: declarations at `~/simd-bench-corpus/bench/adapters/simd_json_family.cpp:18-25` and dispatch at `:59-99`.
2. The Zig export builds a tape for both modes. `SOURCE FACT`: `~/simd-bench-corpus/zig/json_family_api.zig:677-691` exports the two symbols. `runDocument` at `:607-633` sets output to zero, uses `std.heap.page_allocator`, calls `buildJsoncTape`, defers `deinit`, and runs `checksumDocument` only for `dom`.
3. `buildJsoncTape` and `validateJsonc` index the whole input and then build or validate a tape. `SOURCE FACT`: `~/projects/simd-performance/src/formats/jsonc.zig:60-91`.
4. The lexer feeds mode-specialized blocks. `SOURCE FACT`: `indexJsoncInto` calls `lexical.feed` with `.jsonc` at `~/projects/simd-performance/src/formats/jsonc.zig:93-113`. `feed` dispatches `.jsonc` and `.json5` to `processDialectBlock` at `~/projects/simd-performance/src/core/json_lexical.zig:59-104`.
5. The dialect block builds SIMD candidate masks and then walks candidates byte by byte. `SOURCE FACT`: mask setup at `~/projects/simd-performance/src/core/json_lexical.zig:206-270`, byte loop at `:272-328`, per-byte state at `processDialectByte` `:330-492`.
6. JSONC atoms are narrow: `-`, digits, `t`, `f`, `n`. `SOURCE FACT`: `isJsoncAtomByte` at `~/projects/simd-performance/src/core/json_lexical.zig:714-719`. The scalar model at `~/projects/simd-performance/src/formats/jsonc.zig:229-234` matches this set.
7. Stage 2 reads the index through a checked view. `SOURCE FACT`: `buildTapeView` and `validateView` at `~/projects/simd-performance/src/core/stage2.zig:516-559`. `TokenReader.reset` validates the view and bounds the input at `:754-778`.
8. `TokenReader.next` skips whitespace and comments, then consumes one structural byte, string, number, literal, or JSON5 identifier. `SOURCE FACT`: dispatch at `~/projects/simd-performance/src/core/stage2.zig:780-883`. Comment skipping and UTF-8 checks live in `skipIgnored` at `:906-969`. Whitespace lives in `skipWhitespace` at `:971-991`.
9. Strings use a SIMD body skip plus scalar escape handling. `SOURCE FACT`: `skipStringBody` at `~/projects/simd-performance/src/core/stage2.zig:1347-1368`, `validateString` at `:1370-1488`.
10. JSONC numbers use the strict number state machine. `SOURCE FACT`: `validateNumber` dispatches non-JSON5 dialects to `validateJsonNumber` at `~/projects/simd-performance/src/core/stage2.zig:1513-1523`. States live at `:1525-1596`.
11. Tape words are fixed capacity. `SOURCE FACT`: `emit` returns `TapeTooLarge` when the list is full at `~/projects/simd-performance/src/core/stage2.zig:1312-1332`. Capacity is an index-plus-quote bound clamped to input length at `:568-597`.
12. DOM traversal walks the tape and decodes each string and number for the checksum. `SOURCE FACT`: `checksumDocument` and `addTapeChecksum` at `~/simd-bench-corpus/zig/json_family_api.zig:566-587` and `:480-564`. String decode calls `decodeChunk` twice per value through length and content passes at `:59-71` and `:325-341`. Number hashing lives at `:343-372`.
13. Tape destruction frees the owned slice. `SOURCE FACT`: `Document.deinit` at `~/projects/simd-performance/src/core/stage2.zig:85-88`.

### 2.2 Native JSON5 path

Steps 1 to 3 match JSONC with JSON5 symbols: adapter dispatch at `~/simd-bench-corpus/bench/adapters/simd_json_family.cpp:101-111`, exports at `~/simd-bench-corpus/zig/json_family_api.zig:693-707`, and `indexJson5`, `buildJson5Tape`, `validateJson5` at `~/projects/simd-performance/src/formats/json5.zig:60-113`.

Differences:

- The lexer accepts single quotes, more atom bytes, high-byte candidates, backslashes, and line ends. `SOURCE FACT`: quote masks at `~/projects/simd-performance/src/core/json_lexical.zig:237-242`, candidate union at `:261-269`, JSON5 atom mask at `:680-694`, per-byte Unicode whitespace at `:466-471` and `:494-585`, line-comment U+2028 and U+2029 handling at `:344-372` and `:586-606`.
- The scalar model accepts letters, `$`, `_`, `+`, `.`, escapes, and Unicode lead bytes. `SOURCE FACT`: `~/projects/simd-performance/src/formats/json5.zig:137-179`.
- The reader accepts single-quoted strings, `+`, `.`, `I`, `N`, and identifiers in key position. `SOURCE FACT`: `~/projects/simd-performance/src/core/stage2.zig:802-871`.
- Comments accept U+2028 and U+2029 as line ends. `SOURCE FACT`: `skipIgnored` at `~/projects/simd-performance/src/core/stage2.zig:919-927`, width helper at `:1768-1785`.
- Whitespace accepts vertical tab, form feed, NBSP, ZWNBSP, and the JSON5 Unicode space set. `SOURCE FACT`: `skipWhitespace` at `:971-991`, `json5WhitespaceWidth` at `:1728-1766`.
- Strings accept single quotes, `\v`, `\0` without a following digit, `\xHH`, other non-digit escapes as themselves, and line continuations. `SOURCE FACT`: `validateString` JSON5 branches at `~/projects/simd-performance/src/core/stage2.zig:1411-1483`. The benchmark checksum decoder at `~/simd-bench-corpus/zig/json_family_api.zig:161-322` does not cover the full accepted grammar: non-ASCII `\xHH` emits one byte instead of the UTF-8 encoding used by `\u00HH`, and U+2028 or U+2029 line continuations are not removed. The existing adapter test covers only ASCII `\x21`: `~/simd-bench-corpus/bench/json_family_adapter_test.cpp:78-101`.
- Numbers accept sign, `Infinity`, `NaN`, hex, leading-dot and trailing-dot fractions, and exponents. `SOURCE FACT`: `validateJson5Number` at `~/projects/simd-performance/src/core/stage2.zig:1598-1686`. The benchmark checksum handler is `hashJson5Number` at `~/simd-bench-corpus/zig/json_family_api.zig:374-443`.
- Keys accept identifiers, including `$`, `_`, Unicode ID ranges, and `\u` escapes with surrogate-pair handling. `SOURCE FACT`: `consumeIdentifier` at `~/projects/simd-performance/src/core/stage2.zig:1189-1211`, `validateJson5Identifier` at `:2076-2113`, escape decoding at `:2037-2074`, range tables at `:1787-1973`.
- Cursor raw views revalidate unquoted keys and quoted strings. `SOURCE FACT`: `rawString` at `~/projects/simd-performance/src/core/stage2.zig:292-339`, `rawNumber` at `:341-354`.

Native behavior tests pin this grammar: comments and raw slices at `~/projects/simd-performance/src/formats/jsonc.zig:345-365`, JSONC rejections for single quotes, trailing commas, and unterminated comments at `:367-390`, extended JSON5 values at `~/projects/simd-performance/src/formats/json5.zig:374-415`, JSON5 numeric and identifier diagnostics at `:417-433`, and control whitespace plus non-digit escapes at `:435-444`.

### 2.3 jsoncons JSONC path

1. Options allow comments and reject trailing commas. `SOURCE FACT`: `~/simd-bench-corpus/bench/adapters/jsoncons.cpp:98-103`.
2. `run_jsoncons_jsonc` rejects empty input, decodes to `jsoncons::json`, and hashes only in `dom`. `SOURCE FACT`: `~/simd-bench-corpus/bench/adapters/jsoncons.cpp:105-140`.
3. `try_decode_json<json>` creates a `json_decoder`, a `basic_json_reader` over `chars_source`, and calls `reader.read(ec)`. `SOURCE FACT`: `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/decode_json.hpp:27-50`.
4. The reader owns its source adaptor and parser, but it borrows the active decoder/visitor. `try_decode_json` creates the local decoder first and passes it by reference to the reader, so the decoder outlives the reader. `chars_source` stores pointers into the caller's input bytes; it does not own them. `SOURCE FACT`: construction at `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/decode_json.hpp:37-40`, fields and borrowed visitor at `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/json_reader.hpp:169-184` and `:214-221`, source pointers at `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/source.hpp:473-498`. `read_next` resets the parser, pulls source chunks, and calls `parse_some` at `json_reader.hpp:274-304`. `read` then checks for trailing content at `:390-401`.
5. The parser is a scalar state machine with a 256-byte string buffer reserve and a 66-entry state-stack reserve. `SOURCE FACT`: constructor at `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/json_parser.hpp:181-207`, buffer and stack reserves at `:199-205`.
6. Comments go through `slash`, `slash_slash`, `slash_star`, and `slash_star_star` states. With `allow_comments_` false the parser fails. With true it still calls the error handler for `illegal_comment`; the default handler accepts comments before or within the root. After the root, `check_done` accepts only ASCII whitespace, so a trailing line or block comment is `extra_character`. Comment states advance over arbitrary bytes without Unicode validation. `SOURCE FACT`: states and transitions at `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/json_parser.hpp:44-76`, `:521-540`, and `:1503-1597`; default handler at `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/json_options.hpp:45-51`.
7. A trailing comma calls the error handler for `extra_comma` when the option is false. `SOURCE FACT`: object case at `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/json_parser.hpp:963-978`, array case near `:1141-1150`.
8. A single quote is not a string delimiter. It calls the error handler for `single_quote`. `SOURCE FACT`: member-name cases at `:905-914` and `:979-988`.
9. Strings scan scalar bytes, handle escapes through goto labels, and validate Unicode at the end. `SOURCE FACT`: `parse_string` dispatch and text loop at `:1945-2046`, closing-quote path at `:2025-2041`, `end_string_value` plus `unicode_traits::validate` near `:2584-2600`.
10. Numbers accumulate in the same buffer and convert at value end. Integers try `dec_to_integer` as signed or unsigned, then fall back to bignum or double. Fractions convert with `decstr_to_double`. `SOURCE FACT`: `parse_number` at `:1721-1943`, integer dispatch at `:2447-2457`, negative and positive paths at `:2459-2541`, fraction path at `:2543-2578`.
11. The decoder builds a DOM incrementally. It keeps an item stack and a structure stack under the JSON allocator and a temporary allocator. `SOURCE FACT`: `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/json_decoder.hpp:57-83`. Object and array visitors live at `:125-217`. Key, string, integer, unsigned, double, boolean, and null visitors live at `:219-242` and `:286-404`.
12. The default `json` alias uses `sorted_policy`. `SOURCE FACT`: alias at `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/basic_json.hpp:5160`, default policy at `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/json_fwd.hpp:16-18`, policy definition near `basic_json.hpp:260-287`.
13. Numeric defaults keep bignums lossless and parse other numbers directly. `SOURCE FACT`: `lossless_number_{false}`, `lossless_bignum_{true}`, `allow_comments_{true}`, `allow_trailing_comma_{false}` at `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/json_options.hpp:259-262`.
14. DOM traversal walks `object_range` and `array_range`, hashes decoded strings and typed numbers, and destroys the DOM at scope exit. `SOURCE FACT`: adapter traversal at `~/simd-bench-corpus/bench/adapters/jsoncons.cpp:25-96`.

### 2.4 jsoncons JSON5 common-subset path

It uses the same decoder, reader, DOM, traversal, and destruction path. Only two facts change:

- Options allow comments and trailing commas. `SOURCE FACT`: `~/simd-bench-corpus/bench/adapters/simd_json_family.cpp:202-207`.
- Traversal uses `hash_json5_value`. It handles objects, arrays, bignum, string, int64, uint64, double, boolean, and null. `SOURCE FACT`: `~/simd-bench-corpus/bench/adapters/simd_json_family.cpp:140-200`.

Do not call this a full JSON5 implementation. The packet excludes full-JSON5-only constructs from the shared manifest. `SOURCE FACT`: `~/simd-bench-corpus/docs/superpowers/specs/2026-09-09-seven-format-profiles.md:37-39`. The adapter exclusion states that jsoncons 1.9.0 has no documented JSON5 decoder and does not support unquoted keys, single-quoted strings, hex numbers, or leading-dot numbers. `SOURCE FACT`: `~/simd-bench-corpus/bench/adapters/jsoncons.cpp:158-164`.

## 3. Why the results look this way

### 3.1 Whole-process hotspot structure

- `MEASURED`: native JSONC DOM hotspots are `Hasher.addDecodedString` 41.64%, `decodeChunk` 25.79%, `runDocument` with `processDialectBlock` 5.34%, `processDialectByte` 3.65%, `TokenReader.next` 3.52%, `validateString` 3.43%, `buildTapeView` with `tapeCapacity` 3.22%, `validateUtf8` 3.03%, and `validateNumber` 2.12%. Source: `~/simd-bench-corpus/results/2026-09-09-reference-analysis/jsonc-simd-jsonc-dom-hotspots.txt:12-96`.
- `MEASURED`: native JSON5 DOM hotspots are `addDecodedString` 31.12%, `decodeChunk` 19.41%, `runDocument` with `processDialectBlock` 14.32%, `processDialectByte` 8.04%, `buildTapeView` with `tapeCapacity` 5.95%, and `TokenReader.next` 4.79%. Source: `~/simd-bench-corpus/results/2026-09-09-reference-analysis/json5-simd-json5-dom-hotspots.txt:12-94`.
- `MEASURED`: jsoncons JSONC hotspots are `parse_string` 19.34%, adapter `hash_value` 18.76%, Unicode `validate` 11.05%, `try_decode_json` 5.88%, DOM `destroy` 3.31%, `malloc` 2.50%, and `parse_number` 2.44%. Source: `~/simd-bench-corpus/results/2026-09-09-reference-analysis/jsonc-jsoncons-dom-hotspots.txt:12-93`.
- `MEASURED`: jsoncons JSON5 hotspots are adapter `hash_json5_value` 20.78%, `parse_string` 20.40%, Unicode `validate` 11.44%, `try_decode_json` 7.10%, and DOM plus allocator teardown near 8%. Source: `~/simd-bench-corpus/results/2026-09-09-reference-analysis/json5-json5-jsoncons-dom-hotspots.txt:12-98`.
- `INFERENCE`: native DOM cost concentrates in checksum string decoding. Reference cost splits between string parsing and adapter traversal. This fits the mode reversal in JSONC, but the profiles do not isolate parse time from traversal, allocation, or destruction. Do not assign a percentage of the speed gap to any one function from these shares alone.

### 3.2 Case-by-case reading

- Sparse and Unicode validate favor native JSONC. `INFERENCE`: these are large inputs where one SIMD index pass plus a strict tape walk can beat a scalar parser plus a sorted DOM build. The DOM reversal on the same bytes points at native traversal and checksum work, not at the index pass alone. A parse-only versus traversal-only split must test this.
- Dense cases are close in validate and favor jsoncons in DOM. `INFERENCE`: dense inputs stress numbers, tape words, DOM nodes, and destruction on both sides. The smaller DOM gap fits a workload where both sides do real per-value work.
- Escaped cases favor jsoncons in both modes, with a larger DOM gap. `MEASURED`: native profiles put escaped-string decode in the two largest symbols. `SOURCE FACT`: native DOM decodes each string twice for length and content. `INFERENCE`: double decoding is a likely cost on escaped inputs, but the shared checksum owns that path. Keep it as a dependency, not a dialect fix.
- Real Twitter cases are neutral in JSONC validate and favor jsoncons in DOM. `INFERENCE`: the derived Twitter fixture adds one block comment to pinned Twitter JSON. Comment work is small. The DOM gap again points beyond comment handling.
- JSON5 Unicode has the largest gap. `MEASURED`: 2.579x in validate and 5.138x in DOM. `SOURCE FACT`: native JSON5 adds Unicode whitespace, line terminators, identifier tables, and extended escapes. `INFERENCE`: the extra JSON5 branches cost more than the exercised subset needs, but the comparative corpus does not isolate identifiers from whitespace from escapes. A feature-off probe must test this.
- Rejected inputs show very large per-rejection latency gaps. `SOURCE FACT`: the timed native adapter indexes the whole input, attempts to build a tape, and maps the returned error to the C outcome through `mapBuildError`; it does not call `diagnosticAt`. Reference parsing fails inside `parse_some` and returns an error code. `INFERENCE`: native work before the mapped error is the likely cause. Measure the actual adapter path. Preserve public first-error diagnostics as a separate correctness gate.

## 4. Feature matrix

`Exercised` means the shared comparative corpus uses the feature. `Unexercised` means only native unit tests or separate adapter tests use it. Duplicate keys and nonfinite values are outside the shared ranked JSON domain.

| Feature | Native JSONC | jsoncons JSONC | Native JSON5 | jsoncons JSON5 subset | Comparative corpus |
|---|---|---|---|---|---|
| Line comments | Supported, including after the root | Supported before or within the root; rejected after it | Supported, including after the root and with U+2028/U+2029 ends | Supported before or within the root; rejected after it | Exercised before/within root only |
| Block comments | Supported, including after the root | Supported before or within the root; rejected after it | Supported, including after the root | Supported before or within the root; rejected after it | Exercised before/within root; trailing position unexercised |
| Comments after root | Accepted because `nextUncached` skips ignored bytes before checking end of input | Rejected by `check_done` as `extra_character` | Accepted | Rejected by `check_done` | Unexercised compatibility difference |
| Unterminated comment | Rejected at comment start | Rejected by parser | Rejected at comment start | Rejected by parser | Unexercised except negative unit paths |
| Invalid UTF-8 in comments | Rejected with exact byte offset | Comment states skip bytes without Unicode validation | Rejected with exact byte offset | Comment states skip bytes without Unicode validation | Unexercised compatibility and security difference |
| Trailing comma in objects and arrays | Rejected as `TrailingComma` | Rejected as `extra_comma` | Accepted | Accepted, `allow_trailing_comma(true)` | Unexercised in shared medians; native tests cover it |
| Single-quoted strings | Rejected | Rejected as `single_quote` | Supported | Rejected | Unexercised in shared medians; native tests cover it |
| Unquoted keys | Rejected | Rejected | Supported, Unicode ID tables plus `\u` escapes | Rejected | Unexercised in shared medians; native tests cover it |
| Escaped keys | Supported as `\u` in quoted keys | Supported as `\u` in quoted keys | Supported, plus identifier escapes and pairs | Quoted `\u` only | Exercised only for quoted strings |
| Hex integers | Rejected | Rejected | Supported, signed | Rejected | Unexercised in shared medians |
| Leading `+` and leading or trailing dot | Rejected | Rejected | Supported | Rejected | Unexercised in shared medians |
| `Infinity` and `NaN` | Rejected | Rejected | Supported, signed checksum preserves sign bit | Rejected | Unexercised in shared medians |
| Leading-zero rules | Strict rejection | `leading_zero` rejection | JSON5 rejection for `01` | Strict rejection | Unexercised as a named case |
| Duplicate keys | Accepted, no duplicate check | Sorted DOM; duplicate semantics are not benchmarked | Accepted, no duplicate check | Sorted DOM; duplicate semantics are not benchmarked | Outside shared domain |
| Unicode whitespace | ASCII only | ASCII behavior in parser whitespace | Full JSON5 set plus vertical tab and form feed | ASCII behavior in parser whitespace | Unexercised; the Unicode workload exercises UTF-8 strings, not whitespace |
| Invalid UTF-8 in quoted strings | Rejected with byte offset | Rejected through string Unicode validation | Rejected with byte offset | Rejected through string Unicode validation | Unexercised as a rejection case; valid UTF-8 strings are exercised |
| String escapes `\b \f \n \r \t \" \\ \/ \u` | Supported | Supported | Supported | Supported | Exercised in escaped corpus |
| JSON5-only escapes `\v \0 \xHH`, other escapes as themselves, line continuations | Rejected | Rejected | Parser supports them; checksum parity is incomplete for non-ASCII `\xHH` and U+2028/U+2029 continuations | Rejected | Unexercised in shared medians; adapter test covers only ASCII `\x21` |
| Numeric storage | Tape borrows source; checksum types int, uint, real | DOM stores int64, uint64, double, bignum string | Tape borrows source; JSON5 checksum adds hex and nonfinite paths | Same DOM storage as JSONC | Exercised for ordinary integers and reals; bignum path unexercised |
| Streaming or event decoding | Chunk indexer exists; benchmark uses document tapes | Reader and cursor APIs exist; benchmark uses DOM decode | Chunk indexer exists; benchmark uses document tapes | Same reader and cursor APIs; benchmark uses DOM decode | Unexercised in timed comparisons |
| First-error diagnostics | Public API returns exact dialect offsets | Library result has error code, line, and column | Public API returns exact number and identifier offsets | Library result has error code, line, and column | Timed adapters expose only accept, reject, or fail; one invalid case per dialect |

## 5. Prioritized optimization tasks

These tasks preserve dialect grammar and first-error behavior. They preserve existing fast and restricted APIs by default. Profile expansion needs an explicit new benchmark.

### D1. Split native DOM time into parse, traversal, checksum, and destruction

- Target symbols: `jsonc.indexJsonc`, `json5.indexJson5`, `jsonc.buildJsoncTape`, `json5.buildJson5Tape`, `stage2.buildTapeView`, `stage2.TokenReader.run`, `json_family_api.addTapeChecksum`, `json_family_api.checksumDocument`, and `stage2.Document.deinit`.
- Ownership: dialect task owns the throwaway measurement harness. Shared parse, traversal, checksum, and tape changes stay with `RefJson`. The input remains borrowed; the structural index and tape remain owned and released within each complete iteration.
- Plan: record non-overlapping timestamps inside one complete leak-free iteration for (1) structural-index allocation, feed, and finish; (2) tape-capacity calculation, tape allocation, reader reset, and `TokenReader.run`; (3) structural-index destruction; (4) full cursor traversal and checksum decode/hash; and (5) tape destruction. Add a separate prebuilt-tape control-only traversal probe that performs no string or number decode. Do not subtract that probe from full checksum and call the remainder exact; report both. Release every allocation even when its release phase is timed separately. Use sparse, dense, escaped, Unicode, and real Twitter bytes with fixed allocator, vector width, CPU, and input hashes.
- Alternatives: cumulative “tape only / tape plus traversal / full checksum” totals. Reject this alternative because tape-only still includes index and tape release, so it cannot isolate allocation from destruction.
- Dependencies: none.
- Correctness cases: all accepted checksums stay equal; rejected adapters keep the same outcome and zero checksum. Separately, public validation keeps the same error enum and byte offset.
- Gates: require three alternating processes per phase. Report medians and the descriptive ±5% band. Call a phase neutral inside the band; do not use an undefined “crosses one” rule. Do not claim a speedup from instrumentation.

### D2. Remove the second quote-count pass from dialect tape capacity

- Target symbols: `stage2.IndexView`, `stage2.buildTapeView`, `stage2.tapeCapacity`, `jsonc.buildJsoncTape`, and `json5.buildJson5Tape` at `~/projects/simd-performance/src/core/stage2.zig:445-597` and the format build functions.
- `SOURCE FACT`: `IndexView` validates offset order and the local range defined by `base_offset` and `limit`. `buildTapeView` validates through `reader.reset` before allocation. Capacity then counts non-colon and non-comma index entries, scans the bounded input for raw quote bytes, and clamps to input length. JSON5 counts both quote kinds. A low bound makes fixed-capacity `emit` return `TapeTooLarge`.
- Ownership and API contract: do not add trusted count fields to public `IndexView`. If the lexer carries a hint, use a private scanner-produced object consumed only by the same synchronous `buildJsoncTape` or `buildJson5Tape` call. Bind it to the exact input pointer and length, `base_offset`, `limit`, dialect, and raw quote-byte counts. Do not persist it or accept it from callers.
- Plan: preserve `buildTapeView` for arbitrary, caller-created, rebased, or revalidated views. It must keep checked recomputation or the current conservative fallback after view validation. Only the private immediate scanner path can consume the hint. Count every raw `"` byte and, for JSON5, every raw `'` byte so the hint matches the current formula rather than assuming syntactic quote or structural counts. Use checked addition; overflow takes the existing safe error or fallback path.
- Alternatives: keep the second pass and optimize its byte loop. Prefer this if pointer/range binding, mutation rules, or fallback ownership makes the private path complex.
- Dependencies: D1. Do not change capacity before phase data shows that this pass or allocation matters.
- Correctness cases: invalid views fail before allocation; arbitrary and rebased views; nonzero `base_offset`; short `limit`; stale metadata; input mutation between independent API calls; count overflow; empty input; quote-heavy and escaped-quote input; single quotes; unquoted keys; maximum `u24` payloads; and underestimated bounds.
- Gates: public `buildTapeView` behavior stays unchanged. The private path must never reject a valid input, write out of bounds, or turn a parse rejection into `TapeTooLarge`. Accept only with lower requested bytes or time outside the ±5% band and no supported-case regression. Reject any structural-count bound without proof.

### D3. Measure and suppress no-op JSON5 high-byte candidates

- Target symbols: `json_lexical.processDialectBlock` and `json_lexical.processDialectByte` at `~/projects/simd-performance/src/core/json_lexical.zig:206-270` and `:330-404`, plus pending Unicode paths at `:494-606`.
- `SOURCE FACT`: these functions already receive `comptime mode`; the implemented wave already preserved that specialization. JSON5 still adds every byte from `0x80` through `0xff` to the candidate mask. A high-byte candidate inside an ordinary string reaches the `state.in_string` branch and returns without structural work.
- Ownership: dialect-only. Do not add another lexer or repeat comptime specialization work.
- Plan: first add a throwaway counter for total candidates and high-byte candidates discarded by `state.in_string`. Measure sparse, dense, escaped, Unicode, and real inputs. Only if that discarded share is material, prototype a quote-state mask that suppresses high bytes proved to be inside an ordinary string. Preserve candidates needed for quote/backslash state and pending JSON5 U+2028/U+2029 continuation handling. Keep all high-byte candidates outside strings for Unicode whitespace, identifiers, comments, and validation boundaries.
- Alternatives: if the discarded share is small or the proof adds runtime state, defer D3. Reject a broad SIMD rewrite without a local measured bottleneck.
- Dependencies: D1.
- Correctness cases: scalar differential checks at widths 4, 16, 32, and 64; strings spanning blocks; single and double quotes; escaped quotes and backslashes; split UTF-8; U+2028/U+2029 after backslash; Unicode identifiers and whitespace; invalid UTF-8; comments; and comment markers inside strings.
- Gates: require identical structural offsets, acceptance, error enum, and byte offset. Accept only if candidate count falls and the matching JSON5 phase improves outside ±5%; JSONC must stay neutral. Otherwise defer. Reject new runtime mode branches or duplicate specialization.

### D4. Make comment cost proportional to comment density

- Target symbols: `stage2.TokenReader.skipIgnored`, `stage2.TokenReader.skipWhitespace`, `json5LineTerminatorWidth`, `json5WhitespaceWidth`, `firstInvalidUtf8Byte` comment paths.
- `SOURCE FACT`: `skipIgnored` walks comment bytes one by one and validates each comment span as UTF-8. JSON5 checks multibyte terminators per byte.
- Ownership: dialect-only.
- Plan: prototype a bulk comment scan that stops at `*`, `/`, line ends, controls, or non-ASCII. Keep exact unterminated-comment offsets and invalid-UTF-8 offsets. Measure comment-free dense input separately from comment-heavy inputs so a comment fast path does not penalize ordinary JSON.
- Alternatives: SIMD comment search. Use it only if the bulk scalar scan proves that boundary checks dominate.
- Dependencies: D1.
- Correctness cases: line comment at EOF without newline, trailing line and block comments after a complete root, CRLF, U+2028 and U+2029 ends, unterminated block comment, invalid UTF-8 in line and block comments, comment markers inside strings, and `/*` inside a line comment.
- Gates: preserve native acceptance of trailing-root comments and rejection offsets for invalid comment UTF-8. Accept lower cycles on comment-heavy inputs with neutral dense behavior. Do not change native behavior to match jsoncons's narrower comment contract.

### D5. Reduce JSON5 identifier validation to exercised cost

- Target symbols: `stage2.validateJson5Identifier`, `decodeJson5IdentifierCodepoint`, `parseJson5IdentifierEscape`, identifier range tables.
- `SOURCE FACT`: validation decodes UTF-8 per codepoint and binary-searches large ID_Start and ID_Continue tables. The shared comparative corpus uses strict quoted keys, so this path is largely unexercised in medians.
- Ownership: dialect-only.
- Plan: add an ASCII-only fast path for identifier bytes. Fall back to the existing tables for high bytes and escapes. Do not change accepted names, rejected names, or failure offsets.
- Alternatives: no change. Prefer this if the fast path adds branches without a corpus that uses unquoted keys.
- Dependencies: none for correctness. Timing depends on a future identifier-heavy input.
- Correctness cases: `$`, `_`, ASCII names, Unicode names, `\u` escapes, split surrogate pairs, lone low surrogates, invalid UTF-8, names that end at `/`, whitespace, or structural bytes.
- Gates: accept only with an identifier-heavy workload and unchanged diagnostics. Otherwise defer.

### D6. Fast rejection without moving the first error

- Timed target symbols: `formats.jsonc.indexJsonc`, `formats.json5.indexJson5`, `buildJsoncTape`, `buildJson5Tape`, `stage2.TokenReader.run`, `stage2.TokenReader.nextUncached`, `json_family_api.runDocument`, and `json_family_api.mapBuildError`. Public correctness targets, not timed targets, are `validateJsonc`, `validateJson5`, `validateView`, and `diagnosticAt`.
- `SOURCE FACT`: the benchmark path indexes the whole input, attempts tape construction, and maps the error directly to accept, reject, or fail at `~/simd-bench-corpus/zig/json_family_api.zig:589-633`. It does not construct a `Diagnostic`. Reference parsing can fail inside `parse_some`. Measured per-rejection gaps are about 48x for JSONC and 19x to 37x for JSON5.
- Ownership: dialect error path. Shared reader-error and public diagnostic contracts stay with `RefJson`.
- Plan: instrument the actual fresh-allocation/build/error-mapping path to locate time before the returned error. Prototype early exit only for failures that the current phase can prove. Do not replace the benchmark's fresh tape-build work profile with validation-only work. If structural early exit requires a fused index/reader API, define it as a separate experiment and benchmark profile before changing production.
- Alternatives: accept slow rejection because rejected inputs are not throughput. This is valid for throughput-only work. It is not valid for mixed or adversarial latency requirements.
- Dependencies: D1.
- Correctness cases: both shipped invalid fixtures, truncated inputs, bad escapes at buffer ends, split comments, invalid UTF-8, and maximum-depth inputs. The timed adapter must keep outcome `rejected` and checksum zero. In a separate public-API run, keep the same error enum and byte offset.
- Gates: compare per-rejection nanoseconds, never MB/s. Accept lower latency outside ±5% only when adapter outcomes and public diagnostics remain unchanged. Reject any shortcut that reports a later public error, converts reject to fail, or changes the declared work profile.

## 6. Feature parity, defer, and reject decisions

Useful parity means work that the measured subset or a near-term corpus can exercise. Do not promise full JSON5 support.

### Useful parity

1. Keep JSONC trailing-comma rejection. `SOURCE FACT`: native tests expect `TrailingComma` at `~/projects/simd-performance/src/formats/jsonc.zig:376-382`. Reference JSONC rejects `extra_comma` with trailing commas disabled. No change.
2. Keep JSON5 trailing-comma acceptance in objects and arrays. `SOURCE FACT`: native extended-value test includes `trailing:[1,2,]` at `~/projects/simd-performance/src/formats/json5.zig:374-377`. Reference JSON5 allows trailing commas. No change.
3. Keep single-quote and unquoted-key support in native JSON5 only. These features are outside the shared manifest. They need extension coverage, not benchmark tuning.
4. Keep JSON5 hex, signed, dotted, `Infinity`, and `NaN` handling in native code and checksum. The reference subset rejects these forms. Do not remove them for speed.
5. Add a shared invalid-UTF-8 rejection case only if the packet owners accept a domain review, and place the invalid bytes inside a quoted string. Do not place them in a comment: native rejects invalid comment UTF-8 while jsoncons accepts it.
6. Add unranked compatibility probes for line and block comments before the root, within containers, and after the root, plus invalid UTF-8 inside both comment forms. Record the intentional acceptance differences before any domain expansion.
7. Repair native JSON5 extension checksum parity before claiming adapter support for the complete accepted string grammar. Target `decodeChunk`, `encodeCodepoint`, and JSON5 line-terminator handling. Contract: `\xHH` hashes the UTF-8 encoding of U+0000 through U+00FF, and LF, CR, CRLF, U+2028, and U+2029 continuations contribute no decoded bytes. Gates: `'\xE9'`, `'\u00E9'`, and literal `é` hash equally; every accepted continuation hashes like the joined string; ASCII `\x21` stays unchanged; rejected escapes stay rejected; and all common measured-domain checksums stay unchanged.

### Explicit defer

- Duplicate-key rejection. Native tapes accept duplicates. jsoncons uses a sorted DOM. Duplicates are outside the shared domain. Defer until a corpus defines the expected checksum and error behavior.
- Bignum and big-decimal parity. jsoncons keeps bignums lossless by default. Native checksums type ordinary integers and reals. The shared corpus does not stress overflow. Defer until an overflow corpus exists.
- Lossless number mode. jsoncons can preserve numbers as strings. Native tapes borrow source text already, but the checksum converts values. Defer until a consumer needs exact decimal preservation.
- Streaming parity in timed comparisons. Both sides have streaming or cursor APIs, but timed runs use document DOM. Defer cross-API timing until the packet defines a streaming work profile.
- Identifier-heavy benchmarking. Native JSON5 implements the identifier grammar used by this adapter. The shared corpus does not use it. Defer D5 timing until such an input exists.

### Explicit reject

- Add trailing commas to JSONC for speed or symmetry. Reject. The packet grammar forbids them.
- Add single quotes, unquoted keys, hex, or nonfinite numbers to JSONC to share JSON5 code. Reject. This merges dialects and breaks first-error behavior.
- Remove JSON5 extensions to match the reference subset. Reject. That trades real grammar for a narrower benchmark.
- Assume structural count bounds tape capacity. Reject without proof. The implemented wave kept a proven conservative bound for this reason.
- Add duplicate comptime lexer specialization. Reject. The implemented wave found the loops already specialized.
- Reject matching jsoncons by rejecting comments after the root. Native accepts them through `skipIgnored`; preserve that grammar.
- Reject matching jsoncons by accepting invalid UTF-8 in comments. Keep native validation because this is a security boundary.
- Reject calling the native JSON5 benchmark adapter checksum-complete for extensions until non-ASCII `\xHH` and Unicode line-continuation parity gates pass.

Compatibility, security, and resource costs:

- Comment handling must not accept unterminated comments or move UTF-8 failure offsets. Native trailing-root comments and invalid-comment-UTF-8 rejection are compatibility and security contracts, even though the jsoncons subset differs.
- Identifier tables are large static data. Keep them read-only and shared. Do not copy them per document.
- Tape ownership stays with the document. Source stays borrowed. Cursors must not outlive either.
- Page-allocator behavior differs from reference allocators. Report allocation and timing separately. Requested bytes are not peak RSS.
- Rejected-input work is a denial-of-service surface. D6 must not trade diagnostics for speed.

## 7. Sources

Pinned dependency:

- jsoncons 1.9.0 at `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include`. Version macros at `jsoncons/config/version.hpp:12-14`. CMake pin at `~/simd-bench-corpus/build-performance/CMakeCache.txt:227`, with `JSONCONS_INCLUDE_DIR` and dependency prefixes near `:260-266`.

Native and adapter sources:

- `~/projects/simd-performance/src/formats/jsonc.zig:60-113`, `:229-234`, `:345-414`
- `~/projects/simd-performance/src/formats/json5.zig:60-113`, `:137-179`, `:374-460`, `:767-770`
- `~/projects/simd-performance/src/core/json_lexical.zig:59-104`, `:206-270`, `:330-492`, `:494-606`, `:680-742`
- `~/projects/simd-performance/src/core/stage2.zig:445-597`, `:720-883`, `:906-991`, `:1004-1029`, `:1141-1211`, `:1312-1368`, `:1370-1488`, `:1513-1686`, `:1728-1785`, `:2037-2113`, `:2115-2130`
- `~/simd-bench-corpus/zig/json_family_api.zig:40-125`, `:161-372`, `:374-443`, `:480-587`, `:589-633`, `:677-707`
- `~/simd-bench-corpus/bench/adapters/simd_json_family.cpp:18-33`, `:59-127`, `:140-245`, `:251-297`
- `~/simd-bench-corpus/bench/adapters/jsoncons.cpp:25-103`, `:105-164`
- `~/simd-bench-corpus/bench/json_family_adapter_test.cpp:78-117`
- `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/decode_json.hpp:27-50`
- `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/json_reader.hpp:169-184`, `:214-221`, `:274-304`, `:390-401`
- `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/source.hpp:473-498`
- `/nix/store/sxa6gcpzqdxn46gpxk9qg8dpy62k6pah-jsoncons-1.9.0/include/jsoncons/json_parser.hpp:44-76`, `:521-540`, `:1503-1597`

Packet contracts and prior work:

- `~/simd-bench-corpus/docs/superpowers/specs/2026-09-09-seven-format-profiles.md:7-24`, `:33-39`, `:63-92`
- `~/projects/simd-performance/docs/superpowers/plans/2026-09-09-parser-performance.md:55-69`, `:71-108`, `:110-125`, `:230-252`, `:296-355`

Measured data:

- `~/simd-bench-corpus/results/2026-09-09-reference-analysis/jsonc-comparisons.json`
- `~/simd-bench-corpus/results/2026-09-09-reference-analysis/json5-comparisons.json`
- `~/simd-bench-corpus/results/2026-09-09-reference-analysis/profiles.json:289-452`
- `~/simd-bench-corpus/results/2026-09-09-reference-analysis/jsonc-simd-jsonc-dom-hotspots.txt`
- `~/simd-bench-corpus/results/2026-09-09-reference-analysis/jsonc-jsoncons-dom-hotspots.txt`
- `~/simd-bench-corpus/results/2026-09-09-reference-analysis/json5-simd-json5-dom-hotspots.txt`
- `~/simd-bench-corpus/results/2026-09-09-reference-analysis/json5-json5-jsoncons-dom-hotspots.txt`
- `~/simd-bench-corpus/results/2026-09-09-comparative-rerun/full/3-jsonc-simd-jsonc-dom-synthetic.json`
- `~/simd-bench-corpus/results/2026-09-09-comparative-rerun/full/3-jsonc-jsoncons-dom-synthetic.json`
- `~/simd-bench-corpus/results/2026-09-09-comparative-rerun/full/3-json5-simd-json5-dom-synthetic.json`
- `~/simd-bench-corpus/results/2026-09-09-comparative-rerun/full/3-json5-json5-jsoncons-dom-synthetic.json`
- `~/simd-bench-corpus/results/2026-09-09-comparative-rerun/full/3-jsonc-simd-jsonc-validate-synthetic.json`
- `~/simd-bench-corpus/results/2026-09-09-comparative-rerun/full/3-jsonc-jsoncons-validate-synthetic.json`
- `~/simd-bench-corpus/results/2026-09-09-comparative-rerun/full/3-json5-simd-json5-validate-synthetic.json`
- `~/simd-bench-corpus/results/2026-09-09-comparative-rerun/full/3-json5-json5-jsoncons-validate-synthetic.json`

Corpus fixtures:

- `~/simd-bench-corpus/corpus/synthetic/jsonc-valid.jsonc`
- `~/simd-bench-corpus/corpus/synthetic/jsonc-invalid.jsonc`
- `~/simd-bench-corpus/corpus/synthetic/json5-valid.json5`
- `~/simd-bench-corpus/corpus/synthetic/json5/synthetic-json5-invalid.json5`
- `~/simd-bench-corpus/corpus/synthetic/jsonc/`
- `~/simd-bench-corpus/corpus/synthetic/json5/`
- `~/simd-bench-corpus/corpus/real/jsonc/real-jsonc-twitter-derived.jsonc`
- `~/simd-bench-corpus/corpus/real/json5/real-json5-twitter-derived.json5`
