# Reference Analysis and Parity Plan: libyaml

## Executive summary

This document compares the current restricted `simd-yaml` path with the pinned
`libyaml` 0.2.5 adapter. It covers all sixteen rows in
`yaml-comparisons.json`: five accepted fixtures in `validate`, the same five in
`dom`, and three rejected fixtures in each mode.

The common benchmark profile is `yaml-basic-1.2.2`. It accepts one document,
block and flow collections, plain scalars, single-quoted scalars, and
double-quoted scalars. It excludes directives, multiple documents, block
scalars, multiline quoted scalars, block compact sequence mappings, tags,
anchors, aliases, and complex keys. The timed fixtures exercise flow
collections in the dense case. The adapter unit test also exercises a flow map
inside a sequence at `yaml_adapter_test.cpp:63-77`; no timed accepted fixture
has that shape. Do not infer a cost for an excluded feature from its presence
in libyaml alone.

On accepted inputs, `libyaml` has lower throughput in all ten rows. On rejected
inputs, `libyaml` has lower rejection latency in all six rows. The rejection
rows measure rejected calls, not throughput.

`libyaml` version 0.2.5 is verified by both `yaml_get_version_string()` in the
adapter and the pinned Nix include and library paths. The source review proves
that libyaml has scanner, parser, event, and document-composer paths for the
listed YAML constructs. It does not prove full YAML 1.2.2 conformance. The
feature matrix therefore separates source-path evidence, adapter exercise,
and schema semantics.

## Coverage and measured reversals

### Measurement basis

The comparison artifact has three process samples per row. The runner executes
five repeats of twenty timed iterations, so each sample has 100 completed timed
iterations. `median_elapsed_ns` in the comparison artifact is the median of the
three **100-iteration batches**. It is not one-call latency.

For accepted rows, the artifact reports median throughput in MB/s. The ratio in
the accepted table is `libyaml throughput / simd-yaml throughput`. Thus a value
below 0.95 means that the reference is slower by more than the descriptive 5%
band. For rejected rows, the ratio is the normalized latency ratio
`simd-yaml batch time / libyaml batch time`; it is unchanged by dividing both
batch times by 100. The tables show both the median batch and the derived
per-call value to avoid a unit error.

The runner performs one warmup before timing. It then calls the adapter inside
the timed loop and checks outcomes and DOM checksums in that loop.

[MEASURED: `~/simd-bench-corpus/results/2026-09-09-reference-analysis/yaml-comparisons.json:1-658`]
[SOURCE FACT: `~/simd-bench-corpus/bench/runner.hpp:610-645,662-705,733-748`]
[SOURCE FACT: `~/simd-bench-corpus/results/2026-09-09-comparative-rerun/full/1-yaml-simd-yaml-validate-synthetic.json:11-18,24-45,131-157`]
[SOURCE FACT: `~/simd-bench-corpus/build-performance/CMakeCache.txt:41-52,256-289`]

The build uses C++23, `-march=x86-64-v3`, `-mtune=generic`, `-O3`, and
`-DNDEBUG`. Both adapters use CPU 2. The dependency metadata pins
`libyaml-0.2.5` and its development headers.

### Accepted cases: throughput

| Mode | Corpus case | Bytes | simd-yaml MB/s | libyaml MB/s | Reference ratio | Direction and row meaning |
|---|---|---:|---:|---:|---:|---|
| validate | `synthetic-yaml-sparse` | 55,000 | 40.14 | 17.66 | 0.440 | reference slower; sparse block mapping |
| validate | `synthetic-yaml-dense` | 134,409 | 46.77 | 9.09 | 0.194 | reference slower; dense flow collections |
| validate | `synthetic-yaml-unicode` | 57,900 | 40.23 | 20.22 | 0.503 | reference slower; UTF-8 scalar bytes |
| validate | `synthetic-yaml-quoted` | 79,900 | 59.28 | 25.67 | 0.433 | reference slower; quoted scalars with `''`, `\u`, and `\n` escapes |
| validate | `real-kubernetes-configmap-yaml` | 189 | 12.48 | 8.35 | 0.669 | reference slower; real short mapping |
| dom | `synthetic-yaml-sparse` | 55,000 | 16.05 | 9.58 | 0.597 | reference slower; parse plus checksum |
| dom | `synthetic-yaml-dense` | 134,409 | 16.84 | 9.21 | 0.547 | reference slower; parse plus checksum |
| dom | `synthetic-yaml-unicode` | 57,900 | 16.72 | 14.04 | 0.840 | reference slower; parse plus checksum |
| dom | `synthetic-yaml-quoted` | 79,900 | 21.98 | 16.20 | 0.737 | reference slower; parse plus checksum |
| dom | `real-kubernetes-configmap-yaml` | 189 | 6.26 | 3.80 | 0.606 | reference slower; parse plus checksum on short input |

All ten rows have the same direction. The ratio is the measured result, not a
claim that one source function explains the whole gap.

[MEASURED: `~/simd-bench-corpus/results/2026-09-09-reference-analysis/yaml-comparisons.json:1-165,289-493,617-658`]
[SOURCE FACT: `~/simd-bench-corpus/corpus/synthetic/yaml/synthetic-yaml-quoted.yaml:1-24`]

### Rejected cases: latency, not throughput

The malformed fixtures are:

- `synthetic-yaml-invalid-flow`: `root: [one, two` (16 bytes).
- `synthetic-yaml-invalid-quote`: `root: "unterminated` (20 bytes).
- `synthetic-yaml-invalid-delimiter`: `root: {left: one, right: [two, three}` (38 bytes).

Each `median batch ns` value below is the median of three process samples for
100 completed timed iterations. `ns/rejected call` is that value divided by
100. It is not a raw single-call measurement.

| Mode | Corpus case | simd-yaml median batch ns | libyaml median batch ns | simd-yaml ns/rejected call | libyaml ns/rejected call | Ratio | Direction |
|---|---|---:|---:|---:|---:|---:|---|
| validate | invalid-flow | 1,125,704 | 12,638 | 11,257.04 | 126.38 | 89.07 | reference faster |
| validate | invalid-quote | 1,153,978 | 9,932 | 11,539.78 | 99.32 | 116.19 | reference faster |
| validate | invalid-delimiter | 1,158,791 | 28,962 | 11,587.91 | 289.62 | 40.01 | reference faster |
| dom | invalid-flow | 1,060,285 | 25,910 | 10,602.85 | 259.10 | 40.92 | reference faster |
| dom | invalid-quote | 1,074,375 | 21,671 | 10,743.75 | 216.71 | 49.58 | reference faster |
| dom | invalid-delimiter | 1,099,898 | 59,665 | 10,998.98 | 596.65 | 18.43 | reference faster |

Row explanations:

1. **Validate invalid-flow.** The libyaml adapter sees an open `[` and reaches
a newline with `flow_depth != 0`. Its pre-scan returns rejection before parser
initialization. `simd-yaml` performs source validation and starts tape
construction before reporting the malformed flow. The normalized values are
11,257.04 ns and 126.38 ns per call.
2. **Validate invalid-quote.** The adapter sees `"` at byte 6 and reaches the
newline while `double_quote` is still true. It returns rejection without
libyaml work. `simd-yaml` scans the input and constructs no usable tape before
it reports the error. The normalized values are 11,539.78 ns and 99.32 ns per
call.
3. **Validate invalid-delimiter.** The adapter tracks `{` and `[` and reaches
the final LF with a nonzero flow depth. It returns rejection before libyaml
setup. `simd-yaml` takes its validation and tape error path. The normalized
values are 11,587.91 ns and 289.62 ns per call.
4. **DOM invalid-flow.** Both adapters reject before DOM checksum traversal.
The adapter pre-scan still avoids libyaml setup. `simd-yaml` still reaches its
build error path. The normalized values are 10,602.85 ns and 259.10 ns per
call.
5. **DOM invalid-quote.** Both adapters reject before DOM checksum traversal.
The same pre-scan shortcut applies to libyaml. The normalized values are
10,743.75 ns and 216.71 ns per call.
6. **DOM invalid-delimiter.** Both adapters reject before DOM checksum
traversal. The same unmatched-flow check applies. The normalized values are
10,998.98 ns and 596.65 ns per call.

[MEASURED: `~/simd-bench-corpus/results/2026-09-09-reference-analysis/yaml-comparisons.json:166-288,494-616`]
[SOURCE FACT: `~/simd-bench-corpus/corpus/synthetic/yaml/synthetic-yaml-invalid-flow.yaml:1`]
[SOURCE FACT: `~/simd-bench-corpus/corpus/synthetic/yaml/synthetic-yaml-invalid-quote.yaml:1`]
[SOURCE FACT: `~/simd-bench-corpus/corpus/synthetic/yaml/synthetic-yaml-invalid-delimiter.yaml:1`]

## Exact execution paths

### libyaml adapter path

`make_yaml_adapter()` reports `yaml_get_version_string()`, `fresh_dom_parse`
for validate, `fresh_dom_parse_traversal` for DOM, and
a `direct_input_fresh_allocation` preparation policy.

[SOURCE FACT: `~/simd-bench-corpus/bench/adapters/yaml.cpp:422-432`]

For each timed call, `run_libyaml` does the following:

1. **Argument checks.** It clears the output checksum and checks mode and input
pointer.
2. **Adapter pre-scan.** `source_has_unsupported_construct()` scans the raw
bytes. It rejects unsupported line endings, tabs, directives, node properties,
flow errors, block scalar indicators, merge-key spelling, and block compact
sequence mappings. This is adapter policy. It is not libyaml parser behavior.
3. **Parser setup.** `yaml_parser_initialize()` initializes two buffers, one
token queue, and five stacks: indents, simple keys, parser states, marks, and
tag directives. `yaml_parser_set_input_string()` installs a string read handler.
The read handler copies input into libyaml's raw buffer when the reader asks for
more bytes.
4. **Document load.** `yaml_parser_load()` asks the scanner for tokens, the
parser for events, and the loader for a `yaml_document_t`. The loader creates
node storage and sequence or mapping arrays. It transfers the event scalar
value pointer into `yaml_node_t`; it does not call `yaml_strdup` for every
scalar value. For an implicit scalar tag, it duplicates the default `!!str`
tag. Explicit tags and node properties also have owned strings. Anchors are
stored in a per-document alias table.
5. **Profile check.** `profile_node_allowed()` walks the composed document. It
requires scalar mapping keys and rejects literal and folded scalar styles. It
also enforces the adapter depth bound.
6. **Trailing-document check.** A second `yaml_parser_load()` call checks for a
second document. The temporary document is deleted. This keeps the benchmark
at one document even though libyaml can parse successive documents.
7. **DOM checksum.** Only in DOM mode, `hash_node()` walks sequence items and
mapping pairs. It hashes scalar byte values, ordered sequence children, and
order-independent mapping pairs.
8. **Destruction.** RAII guards call `yaml_document_delete()` and
`yaml_parser_delete()`. The document frees node-owned tags, scalar values,
sequence arrays, mapping arrays, directives, and nodes. The parser frees
buffers, queued tokens, and stacks.

[SOURCE FACT: `~/simd-bench-corpus/bench/adapters/yaml.cpp:116-126,128-245,247-387`]
[SOURCE FACT: `https://raw.githubusercontent.com/yaml/libyaml/0.2.5/src/api.c`, `yaml_parser_initialize` at source lines 181-218, `yaml_parser_delete` at 224-252, `yaml_parser_set_input_string` at 293-300]
[SOURCE FACT: `https://raw.githubusercontent.com/yaml/libyaml/0.2.5/src/scanner.c`, declarations and dispatch at source lines 594-742 and 805-1000]
[SOURCE FACT: `https://raw.githubusercontent.com/yaml/libyaml/0.2.5/src/parser.c`, state dispatch and declarations at source lines 109-161 and 249-286]
[SOURCE FACT: `https://raw.githubusercontent.com/yaml/libyaml/0.2.5/src/loader.c`, load and ownership paths at source lines 89-263 and 268-405]
[SOURCE FACT: `/nix/store/skmvbzmzdd7fqgmsw72vnmfdj0ij6gdr-libyaml-0.2.5-dev/include/yaml.h:354-478,691-813,1087-1309`]

### simd-yaml adapter path

`run()` in the Zig C ABI shim clears the checksum, bounds-checks the input
length, calls `buildYamlTape(std.heap.page_allocator, input)`, and maps parser
errors to the C ABI outcome. Validation returns after tape construction. DOM
calls `document.root(input)`, hashes through `YamlCursor`, checks the trailing
`document_end`, writes the checksum, and then destroys the tape.

`buildYamlTape()` first calls `validateYamlSource()`. It reserves an
`ArrayList(YamlTapeWord)` with `min(input.len, 64)` words, then asks
`YamlResidentEngine.next()` for events and appends each event directly as a
packed word. `toOwnedSlice()` transfers the tape allocation to the document.
The source remains borrowed. Scalar bytes remain source spans. The engine owns
only stack state and source positions.

The event loop uses `prepareLine`, `trimCommentEnd`, `findBlockColon`,
`stepLine`, `stepFlow`, `parseScalar`, and `parsePlain`. `YamlDocument.root()`
checks source identity and tape bounds, then re-runs the resident event stream
against every tape word. This protects the public cursor API from an invalid
tape, but it repeats parser work in DOM mode.

The DOM shim's `hashScalar()` decodes each scalar twice: once to compute decoded
length and once to hash decoded bytes. `ScalarDecoder` handles plain, single
quoted, double quoted, `\\` escapes, and UTF-16 surrogate pairs. This checksum
code is part of the measured DOM adapter. It is not the parser's scalar storage.

[SOURCE FACT: `~/simd-bench-corpus/zig/yaml_api.zig:1-216,246-350`]
[SOURCE FACT: `~/projects/simd-performance/src/formats/yaml.zig:150-185,1238-1355,1449-1520,1684-1724,1936-2297,2378-2429,2811-2822`]

### Timed work and ownership boundaries

- Input loading and the warmup occur outside the timed loop.
- Adapter calls, fresh parser/tape construction, validation, DOM traversal, and
checksum verification occur inside the timed loop.
- `libyaml` owns its parser buffers and document nodes for one call. It uses
`yaml_malloc`/`yaml_realloc`/`yaml_free`, which map to C allocation functions.
- `simd-yaml` owns one tape allocation per call through the shim's
  `std.heap.page_allocator`. The exact OS allocator calls were not traced here.
  Do not attribute a fixed `mmap` or `munmap` cost without a probe.
- Both adapter entry points borrow the runner's input pointer. Libyaml copies
  those bytes into its internal reader buffers inside the timed parser call.
  Simd-yaml keeps its source spans borrowed. Neither path performs file I/O in
  the timed function.

[SOURCE FACT: `https://raw.githubusercontent.com/yaml/libyaml/0.2.5/src/api.c`, allocator functions at source lines 35-70]
[SOURCE FACT: `~/simd-bench-corpus/bench/runner.hpp:662-705,733-748`]

## Why each implementation is faster or slower

### Accepted inputs

[MEASURED] The reference ratio is below 0.95 for every accepted row. The
validate ratios range from 0.194 to 0.669. The DOM ratios range from 0.547 to
0.840. The dense validate row is the largest accepted gap. The Unicode DOM row
is the smallest.

[SOURCE FACT] libyaml's parser path converts the input into tokens, events, and
an owned document. Its parser object has two buffers, a token queue, and parser
stacks. Its loader owns a node array and per-container arrays. Its loader also
creates default tag strings for untagged nodes. The source does not show a
zero-copy document representation.

[SOURCE FACT] `yaml_parser_update_buffer()` reads into libyaml's raw buffer,
determines encoding, validates code points, and writes the internal buffer.
This gives libyaml a normalized reader stream but adds a copy and decode path.

[SOURCE FACT] The current `simd-yaml` path stores packed `(kind, source length,
source offset)` words and borrows scalar bytes from the input. The implemented
wave removed intermediate structural arrays and builds the tape directly from
resident events. It also uses printable-ASCII block validation with a scalar
fallback for non-ASCII or control bytes.

[MEASURED] The libyaml DOM profile samples allocator symbols, reader-buffer
updates, token fetching, parser transitions, and wrapper/checksum work. The
simd-yaml DOM profile samples resident event production, source validation,
comment and colon scans, cursor hashing, and the shim scalar decoder. These
samples identify hot symbols. They do not allocate a percentage of the speed
gap to any one symbol.

[INFERENCE] The accepted gap is consistent with less representation work and
less allocation in the direct tape path. The exact contribution of document
allocation, reader copying, resident scans, and checksum work needs paired
experiments.

[MEASURED: `~/simd-bench-corpus/results/2026-09-09-reference-analysis/yaml-simd-yaml-dom-hotspots.txt`]
[MEASURED: `~/simd-bench-corpus/results/2026-09-09-reference-analysis/yaml-yaml-dom-hotspots.txt`]
[SOURCE FACT: `~/projects/simd-performance/docs/superpowers/plans/2026-09-09-parser-performance.md:296-388`]

### Rejected inputs

[SOURCE FACT] The adapter's pre-scan returns `Outcome::rejected` before
`yaml_parser_initialize()` for all three malformed fixtures. In `validate`
and `dom`, the libyaml calls therefore perform no parser allocation, document
load, profile walk, checksum, or destruction. The exact branch is
`if (source_has_unsupported_construct(input)) return Outcome::rejected`.

[SOURCE FACT] The Zig shim has no equivalent adapter pre-scan. It enters
`buildYamlTape()`, runs `validateYamlSource()`, allocates the tape list, and
starts resident parsing before it maps the error to rejection. The DOM branch
never reaches `document.root()` or `hashNode()` for these malformed inputs.

[INFERENCE] The early libyaml branch explains the reversal. The simd-yaml
allocation path may add time, but this review did not trace page allocator
system calls. Treat allocator contribution as unknown until a paired
allocation probe isolates it.

[MEASURED] The normalized per-call values are 10.6-11.6 microseconds for
simd-yaml and 0.10-0.60 microseconds for libyaml. These values came from the
100-iteration medians in the comparison artifact. They are not throughput
values and are not the individual raw report values.

## Feature matrix: source support versus exercised work

The version column is pinned to libyaml 0.2.5. A `source path` entry means that
the implementation has a scanner, parser, event, or composer path for the
construct. It does not mean that the adapter exercises that path or that the
library passes all YAML 1.2.2 conformance tests.

| Feature | YAML 1.2.2 reference | libyaml 0.2.5 source status | Adapter baseline | simd-yaml baseline | Exercised / cost in these 16 rows |
|---|---|---|---|---|---|
| Plain scalars and basic block mappings | Sections 7.3 and 8.2 | `yaml_parser_scan_plain_scalar`; block mapping parser states | Allowed | Allowed | Exercised; parser, tape, validation, and checksum cost |
| Flow sequences and flow mappings | Sections 7.4 and flow productions | Flow scanner and flow parser states | Allowed, including `{}` inside a sequence | Allowed | Timed dense fixture exercises flow collections; map-inside-sequence is unit-test-only at `yaml_adapter_test.cpp:63-77` |
| Literal block scalar `\|` | Section 8.1, productions 162-173 | `yaml_parser_fetch_block_scalar` and `yaml_parser_scan_block_scalar` | Pre-scan rejects `\|` at token start; profile also rejects literal style | `error.Unsupported` | Not exercised; no block-scalar cost measured |
| Folded block scalar `>` | Section 8.1, productions 174-182 | Same block-scalar scanner with folded mode and break scanning | Pre-scan rejects `>` at token start; profile rejects folded style | `error.Unsupported` | Not exercised; no folded-scalar cost measured |
| Chomping and indentation indicators | Section 8.1.1 | `yaml_parser_scan_block_scalar` parses indicators and `yaml_parser_scan_block_scalar_breaks` resolves indentation and breaks | Rejected with block scalar | Rejected as unsupported | Not exercised; no indicator cost measured |
| Multiline quoted scalars | Section 7.3 | `yaml_parser_scan_flow_scalar` scans flow scalar content, escapes, and line breaks | Newline while quote or flow depth is open is pre-scan rejection | Resident parser rejects an unclosed or multiline quoted span in the restricted profile | Not exercised; no multiline folding cost measured |
| Block compact sequence mapping (`- key: value`) | Section 8.2.1, compact mapping production | Block sequence and mapping parser states are present | Adapter rejects colon after a block sequence entry | `error.Unsupported` for this shape | Not in timed rows; flow maps inside sequences are unit-test-only at `yaml_adapter_test.cpp:63-77` |
| Directives (`%YAML`, `%TAG`) | Section 6.8, productions 82-95 | `yaml_parser_process_directives`; scanner directive functions; document event carries directive pointers | Pre-scan rejects `%` at token start | `error.Unsupported` | Explicit directives not exercised; libyaml still processes default tag handles |
| Multiple documents (`---`, `...`) | Chapter 9, productions 205-211 | `yaml_parser_load` returns successive documents; document stores start/end marks and implicit flags | First document only; second load rejects a trailing document | Single-document tape; trailing content is rejected | Not exercised as a feature; libyaml pays the second EOF-check load on accepted rows |
| Anchors and aliases (`&name`, `*name`) | Sections 6.9.2 and 7.1 | Scanner tokens, parser events, and loader alias table. Alias events attach an existing node index. Anchor lookup is a linear scan in `yaml_parser_register_anchor` and `yaml_parser_load_alias` | Pre-scan rejects `&` and `*` at property positions | `error.Unsupported` | Explicit anchors and aliases not exercised; libyaml initializes an empty alias stack per non-empty document |
| Explicit tags (`!tag`, `!!str`) | Section 6.9.1, productions 96-100 | Scanner tag-handle and tag-URI paths. Loader stores node tags and duplicates owned tag strings | Pre-scan rejects `!` at token start or after separation | `error.Unsupported` | Explicit tags not exercised; libyaml still processes default `!` and `!!` handles and default node tags |
| Complex mapping keys (`? key`, sequence/map key) | Section 8.2.2, productions 191-192 | Block and flow mapping parser states accept arbitrary node events as key nodes | Pre-scan rejects `?` at token start; profile requires scalar keys | `error.Unsupported` | Not exercised; mapping checksum is scalar-key only |
| Implicit typing | Sections 10.2-10.3 schemas | No schema resolver in the inspected parser/loader path. Header tag constants do not prove resolution. Untagged scalars receive default `!!str` in the loader | No schema resolution | All scalar bytes remain strings | Not exercised; no typed value cost |
| Merge key `<<` | YAML 1.1 merge working draft; not a YAML 1.2 core syntax rule | No merge transform in scanner, parser, or loader. `<<` can be a scalar key; an alias is a separate composer feature | Explicit `<<:` spelling is pre-scan rejection | Rejected in restricted profile | Not exercised; no merge cost |

The default-handle and alias-stack work above is a real baseline cost. It is
separate from the excluded explicit directive, tag, anchor, and alias syntax.
`yaml_parser_process_directives()` appends the default `!` and `!!` handles on
each document. `yaml_parser_load()` initializes the alias stack for each
non-empty document. The adapter pre-scan prevents explicit entries from
reaching those paths, but it does not remove these common setup paths.

[SOURCE FACT: `https://raw.githubusercontent.com/yaml/libyaml/0.2.5/src/parser.c:1233-1323`]
[SOURCE FACT: `https://raw.githubusercontent.com/yaml/libyaml/0.2.5/src/loader.c:89-119,268-277`]

Primary implementation evidence:

- Scanner declarations and dispatch: `https://raw.githubusercontent.com/yaml/libyaml/0.2.5/src/scanner.c`, source lines 594-742, 805-1000, 1831-1910, 2325-2454, 2745-3045.
- Reader refill, encoding, and UTF validation: `https://raw.githubusercontent.com/yaml/libyaml/0.2.5/src/reader.c`, source lines 14-24, 56-147, 147-191, and 214-470.
- Parser states, directives, and node properties:
  `https://raw.githubusercontent.com/yaml/libyaml/0.2.5/src/parser.c`, source
  lines 109-161, 249-286, 533-610, 730-1063, 1233-1378.
- Loader composition, alias identity, and scalar value transfer:
  `https://raw.githubusercontent.com/yaml/libyaml/0.2.5/src/loader.c`, source
  lines 89-263, 268-405, 418-548.
- Public token, event, node, and parser contracts:
  `/nix/store/skmvbzmzdd7fqgmsw72vnmfdj0ij6gdr-libyaml-0.2.5-dev/include/yaml.h:215-336,354-478,691-813,1087-1309`.
- Adapter filter and profile restrictions:
  `~/simd-bench-corpus/bench/adapters/yaml.cpp:128-284`.
- YAML 1.2.2 specification: `https://yaml.org/spec/1.2.2/`, Sections 6.8,
  6.9, 7.1, 7.3, 8.1, 8.2, 9, and 10.
- Merge working draft: `https://yaml.org/type/merge.html`.

## Prioritized optimization tasks

Direct event-to-tape construction and printable-ASCII block validation are
already shipped. Do not re-propose them as new work. The following tasks keep
the restricted profile as the default.

### 1. Fuse validation with resident line preparation

- **Targets:** `validateYamlSource`, `validateYamlInput`,
  `YamlResidentEngine.prepareLine`, `trimCommentEnd`, and `findBlockColon` in
  `src/formats/yaml.zig`.
- **Current work:** `buildYamlTape` validates the entire source. Each resident
  line then calls `validateYamlInput` again. `prepareLine` also scans the line
  for carriage returns, comments, indentation, and a block colon.
- **Contract and ownership:** Keep input borrowed. Produce the same event
  offsets, source lengths, errors, and diagnostic precedence. A combined pass
  may keep a small `ResidentLine` result on the stack. It must not create a
  default heap side table.
- **Implementation alternatives:**
  1. Move the source validation result into `prepareLine` and remove the full
     pre-pass only when the complete-input API can prove EOF and capacity
     bounds.
  2. Keep the full pre-pass but cache line metadata for the resident engine.
  3. Keep two passes if error precedence or windowed parsing requires it.
- **Dependencies:** None. Re-check window mode and BOM handling before coding.
- **Correctness cases:** printable ASCII at 32-byte boundaries; UTF-8 and
  malformed UTF-8; DEL and C0 controls; BOM only at byte zero; LF and CRLF;
  bare CR; leading tabs; comments containing `#`, quotes, and backslashes;
  invalid flow, quote, and delimiter fixtures; source line/column diagnostics.
- **Measurement gate:** Run the complete 16-row comparison and focused source
  counters. Accept only if no accepted row is slower than 5% and at least one
  accepted validate or DOM row is faster than 5%, with identical checksums and
  rejection outcomes. Reject a neutral result. Record input bytes read if the
  combined pass is claimed as the cause.

### 2. Add an owning build-to-cursor path, not a public replay bypass

- **Targets:** `YamlDocument.root` and `buildYamlTape` in
  `src/formats/yaml.zig`.
- **Current work:** `root()` validates source identity and then reruns
  `YamlResidentEngine.next()` against every tape word. This is a public safety
  boundary. Existing tests mutate public tape words after construction and
  expect `root()` to reject them. A construction witness cannot replace this
  replay because an in-bounds, same-length mutation can still change a scalar
  span or event kind.
- **Contract and ownership:** Keep public `YamlDocument.root()` replay
  unchanged. If profiling justifies a fast path, add a separate
  `YamlOwnedCursor` or equivalent consuming API. `buildYamlTape` must validate
  every emitted event before it transfers the tape into that cursor. The cursor
  owns the tape and has a `deinit` path. It must not expose a mutable tape or
  leave a caller-mutable `YamlDocument` alias alive while the cursor is used.
  The borrowed input must remain immutable for the cursor lifetime. If that
  ownership contract cannot be enforced, do not add the fast path.
- **Implementation alternatives:**
  1. Keep `root()` as the verifier and add no bypass.
  2. Add a consuming build-to-cursor function with private tape storage and
     immediate build-and-consume use in the benchmark shim.
  3. Copy the source into an owned buffer to enforce immutability. Reject this
     for the parser benchmark unless a paired measurement shows a net gain.
- **Dependencies:** Task 1 is preferred so the consuming path does not retain
  duplicate per-line validation.
- **Correctness cases:** forged kind, offset, payload, and trailing word;
  source slice with equal bytes but a different pointer; source length mismatch;
  same-length source mutation; mutable tape mutation; missing or extra
  `document_end`; all five accepted DOM checksums; all three rejected fixtures;
  depth and tape-size errors.
- **Measurement gate:** Public `root()` tests must remain unchanged. Compare
  the consuming path with the current path in DOM and validate separately.
  Accept only if no accepted row is slower than 5% and at least one DOM row is
  faster than 5%. Reject if the new cursor exposes mutable storage, accepts a
  changed source, or gains only within the descriptive neutral band.

### 3. Fast-path unescaped quoted spans in the resident parser

- **Targets:** `YamlResidentEngine.parseQuoted`, `parseScalar`, `stepFlow`, and
  `parsePlain` in `src/formats/yaml.zig`.
- **Current work:** `parseQuoted` checks each byte for a terminator and escape.
  The flow state then checks delimiters and line ends. The hotspot report shows
  resident `next`, `parseScalar`, and `findBlockColon` work in DOM mode.
- **Contract and ownership:** Keep raw source spans and existing scalar checksum
  semantics. Use bulk search only after a fast scan proves that the quoted span
  has no backslash, doubled single quote, newline, or invalid delimiter. Fall
  back to the current byte loop for escapes and malformed input. Do not decode
  or allocate a scalar in the tape builder.
- **Implementation alternatives:**
  1. Use `std.mem.indexOfScalar` for the next quote and retain the current loop
     as the escape fallback.
  2. Add a SIMD quote/backslash candidate scan, followed by the same scalar
     verifier.
  3. Keep the current loop if branch and call overhead erase the gain on short
     quoted values.
- **Dependencies:** Task 1 is independent. Task 2 is useful for DOM isolation.
- **Correctness cases:** empty quotes; single-quote doubling; escaped double
  quote, slash, backslash, and `u` sequences; quote at a line end; unclosed
  quote; flow delimiters; comments after a scalar; Unicode bytes; all existing
  adapter checksum tests.
- **Measurement gate:** No accepted row may lose more than 5%. Accept only if
  the quoted validate row or quoted DOM row is faster than 5% and the sampled
  resident parser time decreases. Reject if it changes source offsets or only
  speeds the benchmark shim checksum.

### 4. Fuse checksum decoding for plain scalar spans

- **Targets:** `hashScalar` and `hashKey` in
  `zig/yaml_api.zig:184-215`, reached from `hashNode()` and
  `ObjectChecksum.add()`.
- **Change:** For a plain scalar or mapping-key span, use `raw.len` as the
  decoded length and remove the first `ScalarDecoder` pass. Decode the span
  once while adding bytes to the existing hasher. Keep the two-pass behavior
  for quoted spans unless a bounded one-pass implementation proves identical
  decoded bytes and length. Never use `raw.len` for a quoted span whose escapes
  or quote syntax change its value length.
- **Contract:** Keep `Hasher` tags, decoded-byte order, length field, mapping
  order-independent accumulation, error mapping, checksum oracle, and
  `fresh_dom_parse_traversal` unchanged. This is a same-profile adapter
  optimization. Any gain is adapter/checksum work, not parser work.
- **Correctness cases:** Plain empty and non-empty scalars; plain keys;
  single-quote doubling; double-quote `\u` and `\n` escapes; Unicode;
  malformed escapes; `StringTooLong`; mapping order; and every existing
  adapter checksum test.
- **Gate:** Run the existing 16-row basic matrix. Require byte-for-byte
  checksum equality and unchanged accepted/rejected outcomes. Accept only if
  at least one DOM row improves by more than the descriptive 5% band and
  `hashScalar`/`hashKey` samples decrease. Reject any basic validate-row
  regression over 5% or any checksum/oracle change. Do not add a new profile
  for this inner-loop change.

## Feature-parity plan with explicit semantics and limits

The restricted profile remains the default. Each extension must use an explicit
profile selector. It must not silently broaden accepted input or add a hidden
branch to the basic path. New profiles need separate fixtures and separate
throughput and rejection-latency rows.

### Stage E0: profile boundary

- Add no grammar support.
- Name the existing contract `yaml-basic-1.2.2` in the profile configuration.
- Preserve `YamlDocument`, `YamlCursor`, `YamlTokenKind`, source spans, and
  error classes for this profile.
- Add an explicit extension profile value. Do not auto-detect and fall back.
- Gate: all existing 16 rows and all existing adapter tests remain unchanged.

### Companion adapter, C ABI, and oracle wiring

The current adapters hard-code the restricted profile. Feature work is not
runnable until the adapter and checksum paths select the same explicit profile.

- **Reference adapter:** Keep `source_has_unsupported_construct()` and
  `make_yaml_adapter()` unchanged for `yaml-basic-1.2.2`. Add a profile-specific
  reference path in `yaml.cpp:128-387` that does not reject the syntax owned by
  E1-E4. Make `profile_node_allowed()` profile-aware. Keep scalar-key and
  resource checks explicit.
- **Simd C ABI:** Keep `simd_bench_yaml_validate()` and
  `simd_bench_yaml_dom()` as basic-profile wrappers. Add an explicit profile
  argument or separate extension entry points in `yaml_api.zig:295-350`.
  Route E1-E2 to the extended scalar-value cursor, E3 to the stream cursor,
  and E4 to the graph cursor. Do not auto-detect syntax or silently fall back
  to the basic path.
- **Checksum contract:** Basic DOM continues to use `hashNode()` and the
  existing checksum oracle. E1-E2 must hash cooked scalar values from
  `value()`, not raw source spans. E3 must define whether one checksum covers
  the stream or each document. E4 must use a separate graph checksum that
  records alias identity. Do not compare graph checksums with the basic tree
  checksum.
- **Fixtures and tests:** Extend `yaml_adapter_test.cpp:62-152` with one
  fixture family per stage. Each family must test both adapters, accepted and
  rejected cases, source diagnostics, and checksum stability. Keep the current
  common-subset and malformed-input tests unchanged.
- **Benchmark metadata:** Give each extension row an explicit profile name.
  Keep `fresh_dom_parse` and `fresh_dom_parse_traversal` when the timed work is
  unchanged. If an adapter-only checksum optimization is measured, label it as
  adapter work and do not call it a parser gain.
- **Gate:** Run the existing 16-row basic matrix first. Run extension rows in
  separate batches. Reject any stage that changes basic acceptance, checksum,
  allocator policy, or error mapping.

### Stage E1: literal block scalars

- **Scope:** Literal `|` scalars. Implement clip, strip, and keep chomping.
  Implement automatic indentation and explicit indentation indicators `1`-`9`.
- **Targets:** resident line state, scalar parser, tape/event construction, and
  a new extended scalar-value owner in `src/formats/yaml.zig`.
- **Event and tape contract:** Keep the existing `scalar` source span for
  diagnostics and compatibility. Add style and cooked-value metadata in an
  extension side table keyed by the scalar event index. The side table owns
  normalized bytes only when source bytes cannot represent the value. The
  basic cursor does not see this side table. The extended cursor exposes
  `rawSpan()` and `value()` as different operations.
- **Semantics:** `rawSpan()` starts at the `|` header and ends at the last
  content byte. `value()` applies indentation removal and chomping. Preserve
  line breaks for literal style. Report the header offset for malformed
  indicators and the content offset for indentation errors.
- **Limits:** Bound scalar source span, cooked bytes, line count, and indentation
  by the profile configuration. Return a resource error, not `Invalid`, when a
  bound is exceeded.
- **Correctness fixtures:** empty block; `|`, `|-`, `|+`; explicit indent; blank
  lines; nested block mapping; tabs in content; malformed indicator; content
  less indented than the detected block.
- **Gate:** New E1 checksums must match a trusted YAML event oracle. Existing
  accepted rows must stay within 5% of their baseline. Reject the stage if
  default-profile code or allocations change measurably without a gain.

### Stage E2: folded blocks and multiline quoted scalars

- **Scope:** Folded `>` with clip, strip, keep, and explicit indentation.
  Then multiline single- and double-quoted scalars with YAML line-folding and
  escape rules.
- **Targets:** `parseQuoted`, block-scalar break handling, extended scalar side
  table, and diagnostics.
- **Event and value contract:** Use the same raw-versus-cooked split as E1.
  The value owner must preserve the exact YAML folding rules. Do not return a
  source slice as a cooked value when line folding changes bytes.
- **Limits:** Bound cooked scalar bytes and line count before allocation. Use
  checked size arithmetic. Do not grow an unbounded scratch buffer.
- **Correctness fixtures:** one-line and blank-line folding; more-indented
  lines; CRLF; escaped line breaks; Unicode; invalid escape; unterminated
  multiline quote; trailing comments.
- **Gate:** Compare E1/E2 fixtures in validate and DOM profiles. Existing 16
  rows must stay within 5%. Reject if the extension changes basic checksum
  semantics or if limit failures can allocate before detection.

### Stage E2b: block compact sequence mappings

- **Scope:** Block sequence entries with an inline mapping, such as
  `- key: value`, including nested entries and empty values.
- **Targets:** `YamlResidentEngine.stepLine`, block-frame transitions, colon
  detection, and tape/event construction in `src/formats/yaml.zig`.
- **Event and tape contract:** Emit the same logical events as an equivalent
  expanded form: sequence start, mapping start, scalar key, value events,
  mapping end, and sequence end. Keep the dash and key source offsets for
  diagnostics. Do not stringify the mapping or change scalar-key checksum
  semantics.
- **Limits:** Reuse the existing depth and tape-word limits. Check nested
  frame growth before writing a new event. Keep the basic profile rejection
  unchanged.
- **Correctness fixtures:** one inline pair; multiple pairs; empty value;
  nested block value; quoted key and value; comment after value; malformed
  colon; block scalar after the colon; and a sequence of inline mappings.
- **Gate:** Add validate and DOM rows with an event/checksum oracle. Keep all
  existing 16 rows within 5% of baseline. Reject the stage if it broadens the
  basic profile or if it cannot preserve source offsets.

### Stage E3: stream framing and directives

- **Scope:** Multiple documents separated by `---` and `...`; `%YAML` and `%TAG`
  directives.
- **Public API contract:** Keep `YamlDocument` as one-document API. Add an
  explicit `YamlStream` owner and `YamlStreamCursor` for multiple documents.
  A stream owns one tape and a bounded document-header table. Each document has
  one `document_start` and one `document_end` event. The stream has explicit
  start/end framing in the stream API. Empty documents remain documents.
- **Directive semantics:** Store parsed version and tag-directive metadata in
  the document header. Do not turn directives into mapping data. Preserve raw
  spans for diagnostics. Do not resolve tags or types in this stage.
- **Limits:** Bound document count, directive bytes, tag-handle length, total
  tape words, and total input bytes. Check limits before growth.
- **Correctness fixtures:** empty documents; explicit and implicit end; two and
  many documents; duplicate directives; `%YAML` version values; `%TAG` handle
  and prefix; directive after a document; trailing content.
- **Gate:** Existing one-document rows remain within 5%. New stream checks must
  show correct document count and source boundaries. Reject if the basic API
  starts accepting a second document or pays per-document heap setup without a
  measured need.

### Stage E4: metadata-only tags, anchors, and aliases

- **Scope:** Parse node properties and preserve tags, anchor definitions, and
  alias references. Do not resolve schemas or merge mappings.
- **Event and tape contract:** Keep node properties as metadata on the node-start
  event, matching libyaml's event contract. Add `YamlNodeProperties` side data
  keyed by node-start event. Emit an `alias` event with an anchor-table ID. An
  alias is a reference, not a copied subtree. The basic token kinds and cursor
  remain unchanged.
- **Ownership:** Anchor and tag names borrow source spans when possible. If a
  normalized URI or handle is required, the extension document owns bounded
  bytes. The per-document anchor table owns IDs and target event indices and is
  cleared at each document boundary.
- **Graph mode:** The default E4 cursor preserves graph identity and yields alias
  events. It does not expand aliases. A graph checksum must include reference
  identity and must not be compared with the existing tree checksum.
- **Optional expansion mode:** Provide a separate, explicit expansion policy.
  Track active targets for cycle detection and a checked expanded-node budget.
  Return `CircularReference` for a cycle in expansion mode and a resource error
  when the budget is exhausted. Graph mode must still accept recursive graphs
  if the profile allows them.
- **Limits:** Configure maximum anchors, aliases, anchor-name bytes, node depth,
  physical tape words, and expanded nodes. Use a hash-plus-byte-equality table
  or another bounded lookup. Do not copy or recursively expand an alias without
  charging the expansion budget.
- **Correctness fixtures:** forward alias rejection; backward alias; duplicate
  anchor; undefined alias; repeated alias; alias to scalar, sequence, and map;
  recursive graph; expansion cycle; expansion budget; anchor at a document
  boundary; tagged anchored node.
- **Gate:** Basic rows remain within 5%. New graph rows must preserve alias
  identity and reject undefined anchors. Expansion tests must terminate within
  the configured node and depth limits. Reject any implementation that silently
  duplicates aliases or turns cycles into stack exhaustion.

### Explicit defer and reject decisions

1. **Block compact sequence mappings: defer to E2b.** The construct is valid
   YAML and has a direct event representation, but it needs a new block-frame
   transition. Keep it rejected in `yaml-basic-1.2.2` until E2b has source
   offsets, empty-value behavior, nested-value handling, and checksum vectors.
2. **Complex mapping keys: reject in the basic and first extension profiles.**
   The current public data model and checksum require scalar mapping keys. A
   future graph API could preserve arbitrary key nodes, but that requires a new
   equality, hashing, and ownership contract. Do not add an implicit conversion
   to strings. This is a compatibility and resource boundary, not a claim that
   YAML syntax forbids complex keys.
3. **Implicit typing: defer to an explicit resolver layer.** The parser should
   preserve scalar bytes and explicit tags. A resolver may later provide named
   Core, JSON, or YAML 1.1 policies. It must not run in the default parser and
   must not execute application constructors. This avoids version-dependent
   booleans, numbers, timestamps, and security-sensitive type handlers.
4. **Merge key: reject `<<:` in the basic profile and defer transform semantics
   until E4 graph identity exists.** The YAML 1.1 merge working draft is not a
   YAML 1.2 core schema rule. Under a raw parser contract, `<<` may remain a
   scalar key. A future transform must define precedence, duplicate keys,
   sequence-of-maps merges, aliases, cycles, and resource limits. Do not make
   merge behavior a side effect of scanning or tag resolution.
5. **Full YAML 1.2.2 conformance: reject as a promise.** The planned profiles
   cover named constructs only. They do not justify a claim of full YAML 1.2.2
   support. Add a conformance claim only after a versioned test corpus and a
   documented schema and graph contract exist.

## Requested probes and unknowns

The following probes are required before attributing a source-level gain:

1. Compare `buildYamlTape` with and without the initial full validation pass,
   while keeping the resident per-line validation and diagnostics unchanged.
2. Compare `YamlDocument.root` replay against a private verified cursor, with
   public forged-tape checks retained in a separate test path.
3. Record allocator calls or allocation bytes for one libyaml call and one
   simd-yaml call. Do not infer `mmap`/`munmap` time from the allocator name.
4. Split DOM timing into parse, root verification, scalar decode, and checksum
   phases without changing the checksum oracle.
5. Add feature-isolated fixtures for block scalars, multiline quotes, compact
   sequence mappings, directives, multiple documents, tags, anchors, aliases,
   complex keys, and merge spelling. Record accepted/rejected status separately
   from throughput.
6. Run a tagged YAML 1.2.2 schema corpus before adding any typing claim.

Unknowns remain: exact allocator contribution in both adapters; exact share of
root replay versus scalar checksum in DOM mode; libyaml conformance behavior on
constructs that the adapter prefilters; and the desired graph checksum contract
for alias-preserving output.

## Sources

1. YAML 1.2.2 specification: <https://yaml.org/spec/1.2.2/>. Sections 6.8,
   6.9, 7.1, 7.3, 8.1, 8.2, 9, and 10.
2. YAML 1.1 merge working draft: <https://yaml.org/type/merge.html>.
3. libyaml 0.2.5 release announcement:
   <https://raw.githubusercontent.com/yaml/libyaml/0.2.5/announcement.msg>.
4. libyaml 0.2.5 version source:
   <https://raw.githubusercontent.com/yaml/libyaml/0.2.5/configure.ac>.
5. libyaml 0.2.5 source: `api.c`, `reader.c`, `scanner.c`, `parser.c`, and
   `loader.c` at
   <https://raw.githubusercontent.com/yaml/libyaml/0.2.5/src/>.
6. Pinned libyaml header:
   `/nix/store/skmvbzmzdd7fqgmsw72vnmfdj0ij6gdr-libyaml-0.2.5-dev/include/yaml.h`.
7. Benchmark adapter:
   `~/simd-bench-corpus/bench/adapters/yaml.cpp`.
8. Benchmark runner:
   `~/simd-bench-corpus/bench/runner.hpp`.
9. Zig C ABI shim: `~/simd-bench-corpus/zig/yaml_api.zig`.
10. Native parser source:
    `~/projects/simd-performance/src/formats/yaml.zig`.
11. Adapter tests:
    `~/simd-bench-corpus/bench/yaml_adapter_test.cpp`.
12. Version and build metadata:
    `~/simd-bench-corpus/build-performance/CMakeCache.txt`.
13. Comparative rows:
    `~/simd-bench-corpus/results/2026-09-09-reference-analysis/yaml-comparisons.json`.
14. Raw timing packets:
    `~/simd-bench-corpus/results/2026-09-09-comparative-rerun/full/`.
15. Native and libyaml hotspot reports:
    `~/simd-bench-corpus/results/2026-09-09-reference-analysis/yaml-simd-yaml-dom-hotspots.txt`
    and
    `~/simd-bench-corpus/results/2026-09-09-reference-analysis/yaml-yaml-dom-hotspots.txt`.
16. Implemented parser wave:
    `~/projects/simd-performance/docs/superpowers/plans/2026-09-09-parser-performance.md`.
