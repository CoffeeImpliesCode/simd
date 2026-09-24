# cmark Reference Analysis and Markdown Parity Plan

## Scope

This document analyzes the cmark 0.31.2 reference against the current Markdown marker parser. It does not implement a parser.

The existing benchmark compares a contextual marker projection. It does not compare equivalent CommonMark trees or rendered output. Keep that boundary in every performance statement.

Evidence labels have these meanings:

- **MEASURED**: archived benchmark or profile output.
- **SOURCE FACT**: behavior shown by the cited source or specification.
- **INFERENCE**: a testable explanation that the available measurements do not isolate.

A ratio in this document is cmark throughput divided by SIMD throughput. Ratios from `0.95` through `1.05` are within the descriptive five-percent band. This band is not a significance test.

## Coverage and measured reversals

### Fixture coverage

**SOURCE FACT:** The benchmark profile has five accepted Markdown fixtures. It excludes fences, inline code, links, images, emphasis, setext headings, HTML, reference resolution, nesting, and rendering. The checksum includes headings, block quotes, list items, and thematic breaks only. See the benchmark contract at `docs/superpowers/specs/2026-09-09-seven-format-profiles.md:45-50` in the packet.

| Fixture | Bytes | Selected constructs | Other exercised input |
|---|---:|---|---|
| `synthetic-markdown-sparse` | 216 | 1 heading, 1 block quote, 2 list items, 1 thematic break | Paragraph text, valid UTF-8, escaped punctuation |
| `synthetic-markdown-dense` | 21,112 | 128 headings, 128 block quotes, 256 list items, 128 thematic breaks | 128 repeated paragraphs, valid UTF-8, escaped asterisks |
| `synthetic-markdown-unicode` | 482 | 1 heading, 1 block quote, 2 list items, 1 thematic break | Latin, Greek, Cyrillic, Arabic, Hebrew, CJK, emoji, escapes |
| `synthetic-markdown-escaped` | 362 | 1 heading, 1 block quote, 2 list items, 1 thematic break | Escaped line markers and escaped punctuation |
| `real-commonmark-selected-markdown` | 204 | 4 headings, 1 block quote, 5 list items, 3 thematic breaks | One plain paragraph |

**SOURCE FACT:** The fixture identities, hashes, expected outcomes, and checksum oracles are in `corpus/MANIFEST.json:306-359`. The files are under `corpus/synthetic/markdown/` and `corpus/real/markdown/`.

### All ten case and mode comparisons

**MEASURED:** The table contains every row from `results/2026-09-09-reference-analysis/markdown-comparisons.json`. Each median uses three independent process samples. Each report row completed 100 timed iterations.

| Mode | Fixture | SIMD MB/s | cmark MB/s | cmark/SIMD | Direction | SIMD/cmark spread ratio |
|---|---|---:|---:|---:|---|---:|
| validate | `synthetic-markdown-sparse` | 22.85 | 41.06 | 1.797 | cmark faster | 1.481 / 1.074 |
| validate | `synthetic-markdown-dense` | 234.35 | 35.38 | 0.151 | cmark slower | 1.482 / 1.453 |
| validate | `synthetic-markdown-unicode` | 58.67 | 51.69 | 0.881 | cmark slower | 1.064 / 1.952 |
| validate | `synthetic-markdown-escaped` | 44.13 | 44.26 | 1.003 | within five percent | 1.026 / 2.189 |
| validate | `real-commonmark-selected-markdown` | 22.55 | 25.97 | 1.151 | cmark faster | 1.352 / 1.020 |
| DOM | `synthetic-markdown-sparse` | 24.61 | 38.25 | 1.554 | cmark faster | 1.665 / 2.115 |
| DOM | `synthetic-markdown-dense` | 131.40 | 30.65 | 0.233 | cmark slower | 1.928 / 1.161 |
| DOM | `synthetic-markdown-unicode` | 51.62 | 59.55 | 1.154 | cmark faster | 1.535 / 1.046 |
| DOM | `synthetic-markdown-escaped` | 39.48 | 43.40 | 1.099 | cmark faster | 1.433 / 1.003 |
| DOM | `real-commonmark-selected-markdown` | 18.05 | 23.92 | 1.326 | cmark faster | 1.261 / 1.142 |

The observed directions are specific:

- **MEASURED:** cmark is slower on dense input in both modes.
- **MEASURED:** cmark is faster on sparse and real input in both modes.
- **MEASURED:** Unicode reverses by mode. cmark is slower in validation and faster in DOM mode.
- **MEASURED:** Escaped input is within five percent in validation. cmark is faster in DOM mode.
- **MEASURED:** All ten rows are accepted throughput rows. There is no Markdown rejection-latency row.
- **SOURCE FACT:** CommonMark defines every character sequence as a valid document. The local corpus manifest also forbids classifying CommonMark examples as invalid documents. See `test/corpus/upstream/markdown/MANIFEST.md:58-62`.

Do not reduce this table to “cmark is faster” or “SIMD is faster.” Do not use the dense result as a full-parser speedup claim.

### Measurement limits

**MEASURED:** The process spread reaches `2.189` for cmark escaped validation and `1.928` for SIMD dense DOM. Three process samples cannot resolve a small difference reliably.

**SOURCE FACT:** Input loading, source hashing, and warmup are outside timed iterations. Parsing, fresh allocation, and destruction are inside both modes. DOM also includes traversal and checksum work. See the benchmark contract at `docs/superpowers/specs/2026-09-09-seven-format-profiles.md:19-29`.

**SOURCE FACT:** Both adapters report `direct_input_fresh_allocation`. Both report `fresh_dom_parse` for validation and `fresh_dom_parse_traversal` for DOM. This common label does not mean equal semantic work or equal allocators. See `bench/adapters/markdown.cpp:179-205`.

## Exact measured execution paths

### SIMD validation path

1. **SOURCE FACT:** `run_simd_markdown` validates the output pointer and mode. It dispatches to `simd_bench_markdown_validate`. See `bench/adapters/markdown.cpp:146-169`.
2. **SOURCE FACT:** `simd_bench_markdown_validate` calls `run(.validate, ...)`. See `zig/markdown_api.zig:119-126`.
3. **SOURCE FACT:** `run` borrows the input span and uses `std.heap.page_allocator`. It calls `buildMarkdownTape` for every iteration. See `zig/markdown_api.zig:69-91`.
4. **SOURCE FACT:** `buildMarkdownTape` scans once through `scanMarkdown`. `MarkdownTapeSink` grows a tape and stores one 64-bit word per marker. The word contains an 8-bit kind, a 24-bit marker length, and a 32-bit byte offset. See `src/formats/markdown.zig:59-108,569-587,749-771`.
5. **SOURCE FACT:** Validation mode does not call `validateMarkdown`, `validateMarkdownTape`, or a cursor. It accepts after successful tape construction, then frees the tape. See `zig/markdown_api.zig:89-95`.

The benchmark label “validate” therefore means fresh trusted marker-tape construction and destruction for this adapter. It does not mean CommonMark conformance validation.

### SIMD DOM path

1. **SOURCE FACT:** DOM mode builds the same fresh tape and retains the borrowed input until destruction. See `zig/markdown_api.zig:89-100`.
2. **SOURCE FACT:** `MarkdownDocument.root` checks source identity and calls `validateMarkdownTape`. That function validates every word, then runs the marker scanner again to prove exact tape equality. See `src/formats/markdown.zig:622-633,720-747`.
3. **SOURCE FACT:** The bridge calls `peek`, `raw`, and `advance` for each marker. Each call reaches `MarkdownCursor.currentWord`, so the bridge checks a marker up to three times. See `zig/markdown_api.zig:101-112` and `src/formats/markdown.zig:658-717`.
4. **SOURCE FACT:** The bridge traverses every marker. It hashes only heading, block quote, list item, and thematic-break kinds. It ignores code-fence, inline-code, and link-delimiter kinds. See `zig/markdown_api.zig:38-60,97-115`.
5. **SOURCE FACT:** `MarkdownDocument.deinit` frees the owned tape. It does not free the borrowed input. See `src/formats/markdown.zig:612-620`.

### cmark validation path

1. **SOURCE FACT:** `run_cmark` validates the output pointer and mode, then passes the input directly to `cmark_parse_document` with `CMARK_OPT_DEFAULT`. See `bench/adapters/markdown.cpp:82-101`.
2. **SOURCE FACT:** `cmark_parse_document` creates a parser, feeds the complete buffer with end-of-file set, finishes the parser, frees parser state, and returns the document tree. The simple API expands to `cmark_parser_new`, `S_parser_feed`, `cmark_parser_finish`, and `cmark_parser_free`. See cmark 0.31.2 `src/blocks.c:561-571,1327-1348`, symbols `cmark_parse_document`, `S_parser_feed`, and `cmark_parser_finish`.
3. **SOURCE FACT:** Parser creation allocates the parser object, a document node, a reference map, and one preallocated `curline` backing buffer. The `curline` buffer starts with a 256-byte initial target, and cmark's growth rule requests 392 bytes after its 50 percent growth and alignment. It initializes the `curline`, `linebuf`, and `content` string-buffer fields, but `linebuf` and `content` have no backing allocation at creation. `content` grows later when block parsing needs it. cmark uses its default `calloc`, `realloc`, and `free` allocator. Allocation failure aborts the process. See cmark 0.31.2 `src/blocks.c:72-133`, `src/buffer.c:22-30,51-58`, and `src/cmark.c:13-33`.
4. **SOURCE FACT:** `S_parser_feed` strips an initial UTF-8 BOM, replaces NUL with U+FFFD, separates line endings, and sends each line to `S_process_line`. `CMARK_OPT_DEFAULT` does not enable optional invalid-UTF-8 replacement. See cmark 0.31.2 `src/blocks.c:561-649` and installed `cmark.h:593-642`.
5. **SOURCE FACT:** `S_process_line` checks open containers, opens new blocks, and adds content. It handles paragraph continuation, block quotes, headings, lists, code blocks, HTML blocks, and thematic breaks. See cmark 0.31.2 `src/blocks.c:930-1120,1271-1325`.
6. **SOURCE FACT:** Finalization resolves reference definitions at paragraph boundaries. It stores block content and list tightness. It then parses inlines in paragraphs and headings. See cmark 0.31.2 `src/blocks.c:233-421,521-538`.
7. **SOURCE FACT:** Inline parsing creates text and semantic inline nodes. It runs escape, entity, code-span, HTML, delimiter, bracket, link, and image logic as required by the source. See cmark 0.31.2 `src/inlines.c:649-760,1010-1265,1330-1427`, symbols `parse_inline`, `process_emphasis`, and `handle_close_bracket`.
8. **SOURCE FACT:** `cmark_parser_finish` consolidates adjacent text nodes after inline parsing. The legacy `CMARK_OPT_NORMALIZE` flag has no effect. See cmark 0.31.2 `src/blocks.c:1327-1351`, `src/iterator.c:90-120`, and installed `cmark.h:631-638`.
9. **SOURCE FACT:** Validation mode calls `cmark_node_free` immediately after the full AST is complete. The iterative free path releases owned node text, code info, link URLs, link titles, and every node. See `bench/adapters/markdown.cpp:103-106` and cmark 0.31.2 `src/node.c:121-164`.

**SOURCE FACT:** Reference labels pass through `normalize_reference`, which applies Unicode case folding, trimming, and internal-whitespace normalization. Each new definition is prepended, so the linked chain is in reverse insertion order. Each definition also records its insertion age. Lookup lazily sorts pointers by normalized label and then ascending age, removes later duplicate labels from the searchable array, and uses binary search. The age tie-break and deduplication preserve first-definition lookup precedence. See cmark 0.31.2 `src/references.c:21-45,47-110,112-147`. The map and every owned label, URL, and title are freed after parsing at `src/references.c:149-174`.

### cmark DOM path and adapter projection

1. **SOURCE FACT:** DOM mode performs the complete validation path first.
2. **SOURCE FACT:** The adapter allocates a `cmark_iter` and walks enter and exit events until `CMARK_EVENT_DONE`. Leaf nodes do not emit exit events. See `bench/adapters/markdown.cpp:108-135`, installed `cmark.h:173-246`, and cmark 0.31.2 `src/iterator.c:15-82`.
3. **SOURCE FACT:** On each enter event, the adapter calls `cmark_node_get_type`. It hashes headings, block quotes, items, and thematic breaks. It still visits document, paragraph, text, list, and other AST nodes. See `bench/adapters/markdown.cpp:61-80,114-140`.
4. **SOURCE FACT:** The adapter frees the iterator and the complete AST inside the measured call. It never calls a renderer.

### Ownership and representation contrast

| Property | Current marker parser | cmark 0.31.2 |
|---|---|---|
| Primary result | Flat marker tape | Parent, child, and sibling AST |
| Source lifetime | Document borrows the input | Nodes own copied or normalized content where needed |
| Owned storage | One contiguous `MarkdownTapeWord` slice | Per-node allocation plus strings, parser buffers, references, and iterator objects |
| Location | Byte offset and marker-byte length | Start and end line and column on nodes |
| Meaning | Marker candidate and local suppression state | Resolved block and inline semantics |
| Destruction | One tape slice free | Iterative node and owned-string frees |
| Measured allocator | Zig page allocator | cmark default libc allocator |
| Empty input | Empty tape, no cursor | Document AST |

**SOURCE FACT:** cmark exposes node attributes for heading level, list type, delimiter, start, tightness, fence info, URL, title, and source position. See installed `cmark.h:267-420`.

## Fresh user-cycle profiles

### Profile boundary

**MEASURED:** The deep profiles ran the actual `build-performance` binaries in synthetic DOM mode on logical CPU 2. They used `cycles:u`, 499 Hz sampling, and DWARF call graphs. The SIMD run used repeat 300. The cmark run used repeat 80. See `results/2026-09-09-reference-analysis/deep-profiles.json:218-289`.

**MEASURED:** The SIMD profile has 956 samples. The cmark profile has 905 samples. Both have zero lost samples.

These are whole-process user-cycle profiles. They include startup, manifest loading, warmup, checksum work, and destruction. The table reports flat self-overhead (`perf report --no-children`). Nested call chains locate inlined work within those samples; do not add them to the enclosing share. Do not compare aggregate event counts or durations because the repetitions differ.

### Selected observed call paths

| Implementation | Reported share | Observed symbol or call path |
|---|---:|---|
| SIMD | 27.50% | `simd_bench_markdown_dom`, including `root -> validateMarkdownTape -> scanMarkdown` frames |
| SIMD | 24.09% | `buildMarkdownTape` |
| SIMD | 16.35% | `ChunkIterator(u8,32,true).next` across build and validation scans |
| SIMD | 12.97% | `MarkdownCursor.currentWord` |
| SIMD | 5.20% | `MarkdownTapeSink.append` |
| SIMD | 4.57% | `processMarkdownLineMarker` on the build path |
| SIMD | 4.34% | `processMarkdownLineMarker` on the validation path |
| SIMD | 3.45% | `compiler_rt.memcpy.memcpyFast` without established caller attribution |
| cmark | 12.10% | `cmark_iter_next`, split across inline processing, consolidation, and adapter traversal |
| cmark | 11.65% | `cmark_parse_inlines` |
| cmark | 11.44% | `S_process_line` |
| cmark | 8.89% | libc `_int_malloc` through cmark node and text allocation paths |
| cmark | 8.01% | libc `calloc` through `add_child` and `make_str` |
| cmark | 6.23% | `S_parser_feed` |
| cmark | 4.44% | generated scanner `_scan_at` from block processing |
| cmark | 4.41% | libc free path, including `cmark_node_free` |
| cmark | 3.43% | `cmark_node_free` |
| cmark | 3.00% | `finalize` |

**MEASURED:** The SIMD profile proves that the measured DOM path includes a second scanner traversal and repeated cursor checks. It does not prove the speedup from removing either path.

**MEASURED:** The cmark profile proves that block processing, inline parsing, AST iteration, allocation, and destruction all execute in this workload. It does not assign a causal fraction of the cmark/SIMD gap.

## Why each direction is plausible

### Dense input

**MEASURED:** SIMD is about 6.62 times cmark throughput in dense validation and 4.29 times cmark throughput in dense DOM mode.

**SOURCE FACT:** The dense fixture repeats 128 simple sections. The marker parser emits 640 selected marker words and does not build paragraphs, text nodes, list containers, or inline semantics. cmark builds these nodes and parses escaped inline text.

**MEASURED:** The cmark deep profile contains substantial `S_process_line`, `cmark_parse_inlines`, iterator, allocation, and free activity.

**INFERENCE:** Repeated semantic AST construction is consistent with cmark's lower dense throughput. The current data does not isolate its share of the gap.

### Sparse and real input

**MEASURED:** cmark is faster in both modes for the 216-byte sparse fixture and the 204-byte real fixture. This remains true although cmark builds more semantic output.

**SOURCE FACT:** The SIMD bridge uses the page allocator for every fresh tape. Its DOM path also rescans the source and checks each marker several times. cmark uses libc allocation and its optimized C parser.

**INFERENCE:** Fixed allocator, adapter, tape-finalization, and defensive-navigation costs can dominate these small inputs. The current measurements do not separate these costs.

### Unicode reversal

**MEASURED:** SIMD leads Unicode validation by 13.5 percent in throughput terms. cmark leads Unicode DOM by 15.4 percent. These modes came from separate noisy process groups.

**SOURCE FACT:** cmark uses `CMARK_OPT_DEFAULT`, so optional invalid-UTF-8 checking is off. The fixture contains valid UTF-8. The marker parser also does not validate Unicode semantics.

**INFERENCE:** The reversal is not evidence for a Unicode algorithm advantage. A mode-local fixed-cost or sample-variation explanation remains possible.

### Escaped input reversal

**MEASURED:** Escaped validation is within five percent. cmark leads escaped DOM by 9.9 percent.

**SOURCE FACT:** cmark executes backslash-escape handling and creates text nodes. The marker parser does not decode escapes. Its line-marker logic sees only the first non-space byte, while its inline loop ignores asterisks and underscores.

**INFERENCE:** The DOM result cannot be attributed to escape handling alone. The two adapters traverse different representations, and the cmark validation spread is `2.189`.

### Rejection behavior

**SOURCE FACT:** The cmark adapter has no syntax-rejected return path. A null document becomes an operational error. The SIMD bridge also maps tape-construction failures to an operational error.

**MEASURED:** No Markdown fixture is rejected. No rejection latency appears in the ten comparisons.

A future malformed-looking CommonMark case remains an accepted throughput case. Resource-limit failures must use a separate error-latency profile.

## Feature and runtime matrix

Support does not prove cost on the measured subset. The final column states what the benchmark actually exercises.

| Feature | cmark 0.31.2 semantics | Current marker parser | Measured state |
|---|---|---|---|
| Plain paragraphs and text | Paragraph and text AST nodes with inline parsing | No paragraph or text representation | Executed by cmark on every fixture, absent from marker output |
| ATX headings | Validates prefix rules, stores level, parses inline children | Emits one `heading` marker for any line-leading `#` after at most three spaces | Simple ATX forms exercised, levels not checksummed |
| Setext headings | Converts eligible paragraphs after precedence checks | No setext node, underline can look like a thematic marker | Dormant and excluded |
| Block quotes | Nested block container with continuation and lazy-line rules | One line-leading marker with no extent or parent | Single-line, non-nested quotes only |
| Lists and items | List and item nodes with bullet type, ordered start, delimiter, nesting, padding, and tightness | One marker for a line-leading bullet or digits followed by `.` | Flat container creation, bullet or ordered type, start, delimiter, padding, compatibility checks, and tightness finalization execute but are not checksummed. Nesting, lazy continuation, and loose-list cases are unexercised |
| Thematic breaks | Applies setext, list, and thematic precedence | Checks three matching markers with spaces or tabs | Simple `---`, `***`, and `___` forms exercised |
| Fenced and indented code | Code-block node, fence rules, info string, content normalization | Opening and closing fence markers, with candidate suppression inside | Marker capability exists but benchmark excludes it |
| Inline code | Code node with code-span delimiter and whitespace rules | Emits each backtick marker and suppresses link delimiters while in a run | Marker capability exists but benchmark excludes it |
| Emphasis and strong | Delimiter stack and flanking rules create nested nodes | No emphasis kinds or tree | Actual emphasis is absent, escaped asterisks exercise cmark escape handling |
| Links and images | Bracket stack, destination, title, nesting precedence, and semantic nodes | Unrelated `[` or `(` open markers and `]` or `)` close markers outside code runs | Dormant and excluded |
| Reference definitions | Extracted during paragraph finalization, normalized, sorted, resolved, and expansion-limited | No reference map or resolution | Empty reference-map allocation and free execute, lookup and normalization do not |
| Reference normalization | Unicode case fold, trim, and internal-whitespace collapse | None | Dormant |
| Entities and escapes | Decodes entities and backslash escapes in applicable inline contexts | Does not decode either | Escapes execute, entities are absent |
| HTML blocks and inline HTML | Creates raw HTML nodes under CommonMark block and inline rules | No HTML representation | Dormant and excluded |
| Line ending and NUL handling | Splits CR, LF, and CRLF, strips initial BOM, replaces NUL | Recognizes CR, LF, and CRLF boundaries, keeps source bytes | Fixtures use ordinary LF and contain no BOM or NUL |
| Invalid UTF-8 option | Can replace invalid sequences when `CMARK_OPT_VALIDATE_UTF8` is set | No Unicode validation | Option is off and unexercised |
| Text consolidation | Always traverses the AST and merges adjacent text nodes | No text nodes | Executed, with profile samples in `cmark_consolidate_text_nodes` |
| Source locations | Stores node start and end line and column | Stores marker byte offset and marker-byte length | Both construct locations, but checksum reads neither location value |
| AST traversal | Enter and exit iterator over all nodes | Sequential cursor over tape words | Both execute in DOM mode, with different output volume and meaning |
| Rendering | HTML, XML, man, CommonMark, and LaTeX APIs | No renderer | Dormant in both benchmark modes |
| Raw HTML and unsafe URL policy | HTML renderer omits raw HTML and dangerous URLs by default | Not applicable | Dormant because no renderer runs |
| Streaming | `cmark_parser_feed` and `finish` retain full parse state | `MarkdownStreamIndexer` retains an unfinished line and marker output | Both capabilities are dormant because adapters use whole buffers |
| Reusable resident traversal | No equivalent adapter path | `Parser.initOnDemandDocument` reuses marker buffers with a one-document lease | Dormant because the bridge builds a fresh tape |
| Syntax rejection | Every character sequence is a CommonMark document | Scanner accepts arbitrary marker-like input unless resource checks fail | No rejected case exists |

## Existing marker API boundary

**SOURCE FACT:** `MarkdownTokenKind` has eight marker kinds. It has no semantic node kind. See `src/formats/markdown.zig:8-17`.

**SOURCE FACT:** `MarkdownDocument` owns one tape and borrows one exact input slice. `MarkdownCursor` is sequential. `TokenCursor.skipChild` explicitly states that the stream is not a CommonMark tree. See `src/formats/markdown.zig:612-718,1190-1323`.

**SOURCE FACT:** The whole-buffer, streaming, and resident APIs share marker scanning behavior. The streaming API owns only its unfinished line and output. It does not retain completed input bytes. See `src/formats/markdown.zig:213-510`.

This API is useful for fast marker search, editor hints, and structural prefiltering. Adding paragraphs or resolved links to `MarkdownTokenKind` would change its data model and performance contract.

## Prioritized marker-profile optimization tasks

These tasks preserve the current marker grammar and API by default. They do not add CommonMark semantics.

### M1. Remove benchmark-only defensive traversal duplication

**Priority:** First.

**Evidence:** The deep profile shows `root -> validateMarkdownTape -> scanMarkdown` and `MarkdownCursor.currentWord` in the measured DOM path.

**Targets:**

- Packet `zig/markdown_api.zig`, `run(.dom)` at lines 73-117.
- Parser `MarkdownDocument.root` at `src/formats/markdown.zig:622-633`.
- Parser `validateMarkdownTape` at `src/formats/markdown.zig:720-747`.
- Parser `MarkdownCursor.peek`, `raw`, `advance`, and `currentWord` at `src/formats/markdown.zig:658-717`.

**Selected experiment:** Change only the benchmark bridge. Iterate the newly built `document.tape` once before `deinit`. Switch on the raw kind with an explicit invalid-kind error. Check each offset and length once before forming the raw slice. Hash every selected kind in source order.

**Ownership and API contract:** The tape remains owned by `MarkdownDocument`. The input remains borrowed. The bridge consumes the tape immediately after trusted construction. No public parser API changes.

**Alternative:** Add a public “trusted cursor.” Reject this alternative. A public caller can mutate the exposed tape, so a trusted cursor would weaken the checked navigation contract.

**Dependencies:** None.

**Correctness cases:** Empty input, invalid mode, null checksum, all eight marker kinds, nonempty raw spans, ordered-marker lengths, fence lengths, maximum 24-bit span, and source-order hashing. Existing `markdown_adapter_test.cpp:20-96` remains the checksum oracle. Do not change its constants to accept a mismatch.

**Measurement gate:** Keep `fresh_dom_parse_traversal`. Validation results must remain byte-for-byte unchanged. All five DOM outcomes, input hashes, checksums, and iteration counts must match. Classify each paired median with the five-percent band. Keep the change only if repeated paired measurements show a DOM benefit and no repeatable case regression above five percent.

**Rejection gate:** Reject on any changed work profile, checksum, error mapping, or source lifetime. Reject if the improvement exists only after removing tape construction.

### M2. Measure small-document allocation policy

**Priority:** Second, after M1 isolates traversal.

**Evidence:** cmark leads four small DOM fixtures and two small validation fixtures. The bridge uses `page_allocator`. `MarkdownTapeSink.grow` starts from a 4,096-word target, bounded by input length.

**Targets:**

- `markdown_tape_capacity_initial` at `src/formats/markdown.zig:59`.
- `MarkdownTapeSink.grow` at `src/formats/markdown.zig:93-108`.
- `buildMarkdownTape` final ownership at `src/formats/markdown.zig:749-771`.
- `page_allocator` at `zig/markdown_api.zig:69-91`.

**Experiment:** Record allocation calls, requested bytes, and retained tape capacity for 0, 1, 5, 64, 640, and more than 4,096 markers. Compare initial capacities of 64, 256, 1,024, and 4,096. In a separate attribution build, compare the page allocator with `c_allocator` without changing parser code.

**Ownership and API contract:** Keep one owned contiguous tape. Keep allocator choice explicit at `buildMarkdownTape`. Preserve `OutOfMemory`, `TapeTooLarge`, input-size, and deinitialization behavior.

**Alternative:** Count markers and allocate exactly in a first pass. Reject this alternative. The shipped one-pass growth path replaced that two-pass experiment after repeated timing regressions. See `docs/superpowers/plans/2026-09-09-parser-performance.md:296-361`.

**Dependencies:** M1 results, so cursor rescanning does not hide allocation effects.

**Correctness cases:** Empty documents, no-marker documents, one-byte input, growth at every capacity boundary, allocator failure at initial and later growth, 32-bit input limit, and 24-bit marker-length limit.

**Measurement gate:** Preserve all marker cases at vector widths 4, 16, 32, and 64 in the future implementation run. Keep a capacity only when requested bytes fall and paired elapsed time does not regress above five percent on any fixture. Treat page-versus-C-allocator output as attribution only unless the production ownership policy also remains suitable.

**Rejection gate:** Reject an input-size branch that creates two performance classes without a measured benefit. Reject any capacity that increases growth calls enough to erase the small-case result.

### M3. Prototype one-shot line and candidate scanning

**Priority:** Third.

**Evidence:** The deep profile shows `ChunkIterator.next` in both `findMarkdownLineEnd` and `scanMarkdownLine`. M1 removes the second whole-document validation only from the bridge. The construction path still locates a line and then scans that line for candidates.

**Targets:**

- `scanMarkdown` at `src/formats/markdown.zig:518-539`.
- `findMarkdownLineEnd` at `src/formats/markdown.zig:541-556`.
- `scanMarkdownLine` at `src/formats/markdown.zig:945-1068`.
- `markdownCandidateMask` at `src/formats/markdown.zig:929-939`.
- `processMarkdownLineMarker` at `src/formats/markdown.zig:1070-1114`.

**Experiment:** Prototype a one-shot whole-buffer scanner that derives newline and marker-candidate masks from each loaded vector. Keep `scanMarkdownLine` for the streaming indexer. Do not allocate candidate arrays across lines. Fall back to the current line helper when a long-line construct needs the final line boundary.

**Ownership and API contract:** Sinks and emitted marker order remain unchanged. Whole-buffer and streaming output must stay identical. The tape remains one-pass and growable.

**Alternative:** Keep the current two byte scans per line. Prefer this alternative if fusion duplicates state logic or slows short lines.

**Dependencies:** M1 and focused generated-code inspection. Do not infer a bottleneck from accumulated profile shares alone.

**Correctness cases:** CR, LF, CRLF, empty final line, no final newline, vector boundaries, three-space and four-space prefixes, tabs, long thematic breaks, ordered-marker digit runs, matching and mismatched fence runs, backticks across vectors, link delimiters inside code, and unclosed fences.

**Measurement gate:** Require exact scalar-oracle and streaming parity first. Keep the prototype only if cycles and instructions fall on dense construction and no accepted sparse, Unicode, escaped, or real case regresses above five percent in repeated paired runs.

**Rejection gate:** Reject extra temporary allocation, duplicate grammar state, changed marker order, or a code-size increase without a repeatable construction result.

## Staged semantic and CommonMark parity plan

### Architectural rule

Keep `simd.formats.markdown` as the marker profile. Add semantic parsing under a separate explicit module and API. Do not add a mode flag to `buildMarkdownTape` or `indexMarkdown`.

The proposed public seam is:

- `simd.formats.markdown`: existing restricted marker APIs, unchanged.
- `simd.formats.commonmark`: opt-in semantic parser and renderer.
- `parseCommonMark(allocator, input, options)`: full-tree entry point only after conformance gates pass.

Partial stages must use an internal or clearly experimental name. They must not claim CommonMark support.

### C0. Import the separate conformance corpus

**Targets:**

- Existing `test/corpus/upstream/markdown/MANIFEST.md`.
- `test/corpus/upstream/markdown/raw/0.31.2/spec.json`.
- `test/corpus/upstream/markdown/raw/0.31.2/LICENSE`.
- New `test/commonmark_conformance_test.zig`.
- `build.zig`, with a separate `commonmark` test step.

**Change:** Follow the existing manifest exactly. Import the raw artifact without byte changes. Keep the marker catalog and semantic conformance harness separate.

**Corpus contract:** Require 140,487 bytes, SHA-256 `d431b29d97b6f73e69d547109cf5081578fac931e72afe95639ebe766c1b2a20`, 652 ordered examples, and 26 sections. Preserve example number, section, Markdown bytes, expected HTML, and source lines. Preserve the CC BY-SA attribution and license.

**Oracle rule:** Never regenerate expected HTML from this parser or cmark. The pinned upstream `html` field is the oracle. Tests remain offline.

**Acceptance:** The import verifier accepts the exact pinned artifact and rejects a changed byte, missing field, duplicate example, reordered example, wrong count, or wrong license file.

### C1. Define the semantic model and source spans

**Targets:**

- New `src/formats/commonmark.zig`.
- `src/root.zig:26-34`, adding an explicit `commonmark` export.
- New symbols `CommonMarkParser`, `CommonMarkDocument`, `Node`, `NodeId`, `NodeKind`, `SourceSpan`, `TextId`, and `CommonMarkOptions`.

**Selected model:** Use a document-owned flat node arena. Store parent, first-child, next-sibling, and optional last-child indexes. Use a tagged payload for heading, list, code-block, link, and image attributes.

**Source contract:** `SourceSpan` is a half-open UTF-8 byte range into the borrowed original input. It never means line and column. Store line-start offsets once if callers request line and column conversion.

**Text ownership:** Raw text can borrow a source span. Decoded escapes, entities, normalized code spans, fence info, URLs, titles, and normalized labels live in a document-owned byte arena. Nodes refer to owned values through `TextId`.

**Limits:** Keep source offsets and node IDs at 32 bits. Reject inputs or node counts that exceed the documented limits. Check all text-arena growth. Use an iterative traversal and destruction model.

**Options:** Pin semantics to CommonMark 0.31.2. Make invalid-UTF-8 and NUL replacement policies explicit. Keep raw-HTML rendering policy out of parser options.

**Alternatives:**

- Reject one heap allocation per node. It copies cmark's ownership cost without an API need.
- Reject overloading `MarkdownTapeWord`. A marker word cannot represent hierarchy, normalized text, or resolved references.
- Defer a mutable AST. Mutation makes source spans and shared text ownership harder to keep valid.

**Dependencies:** C0.

**Correctness cases:** Empty document, empty paragraph boundaries, multi-byte source offsets, tabs, CRLF, NUL replacement, invalid UTF-8 policy, maximum input, maximum nodes, allocation failure, and iterative destruction of deep trees.

**Acceptance:** Hand-reviewed model tests prove parent and sibling invariants, exact byte spans, borrowed-source lifetime, owned-text lifetime, and leak-free error cleanup. The marker API and benchmark remain unchanged.

### C2. Implement block semantics as a separate phase

**Targets:**

- `CommonMarkParser.feedLine`.
- `CommonMarkParser.checkOpenBlocks`.
- `CommonMarkParser.openNewBlocks`.
- `CommonMarkParser.finalizeBlock`.
- `CommonMarkParser.finishBlocks`.
- Node payloads `HeadingData`, `ListData`, and `CodeBlockData`.

**Change:** Implement the CommonMark two-phase model. Phase one builds block structure line by line. It maintains an explicit container stack and defers inline parsing.

**Required block scope:** Paragraphs, ATX and setext headings, thematic breaks, block quotes, list and item containers, nesting, list tightness, indented code, fenced code with info, HTML blocks, and link-reference definitions.

**Precedence cases:** Setext versus thematic break, list marker versus thematic break, paragraph interruption, lazy continuation, blank lines in nested lists, tab-expanded indentation, changing bullet types, ordered delimiters, and fenced-block closure.

**Reference-definition contract:** Extract definitions when a paragraph finalizes. Keep first-definition precedence. Store raw source spans and owned cleaned destination and title text. Do not resolve inline references yet.

**Resource contract:** Bound container depth and total nodes with explicit options. Return a resource error, not a syntax rejection. Avoid recursive close and free paths.

**Alternative:** Reject a marker-first conversion that tries to infer blocks from `MarkdownTapeWord`. The marker tape omits paragraph boundaries, indentation semantics, continuation lines, and precedence information.

**Dependencies:** C1.

**Acceptance:** Match hand-reviewed block trees and attributes for every relevant section in the 0.31.2 corpus. Record example and section on failure. Do not advertise full CommonMark while inline and renderer stages remain incomplete.

### C3. Implement inline semantics and reference resolution

**Targets:**

- `CommonMarkParser.parseInlines`.
- `InlineSubject`.
- `DelimiterStack`.
- `BracketStack`.
- `ReferenceMap.normalizeLabel`.
- `ReferenceMap.resolve`.
- Text-arena helpers `decodeEntity`, `decodeEscape`, `cleanDestination`, and `cleanTitle`.

**Change order:**

1. Add text, soft break, hard break, backslash escape, entity, and code-span nodes.
2. Add delimiter-stack emphasis and strong emphasis with CommonMark flanking and multiple-of-three rules.
3. Add bracket-stack inline links, images, full references, collapsed references, shortcut references, and nesting precedence.
4. Add autolinks and inline HTML.
5. Resolve reference links after all definitions are known.

**Normalization contract:** Case-fold labels with the required Unicode behavior. Trim leading and trailing whitespace. Collapse internal whitespace. Before normalization, require at most 999 Unicode code points inside the raw label brackets, as CommonMark 0.31.2 specifies. cmark's `MAX_LINK_LABEL_LENGTH = 1000` is a byte-oriented implementation boundary, not the semantic contract. See <https://spec.commonmark.org/0.31.2/#link-label> and cmark 0.31.2 `src/parser.h:13`, `src/inlines.c:1012-1047`.

**Ownership contract:** Reference entries own normalized labels and cleaned values in the document arena. Immutable link nodes can refer to stable arena IDs. They do not need per-link URL and title copies.

**Resource contract:** Use bounded delimiter and bracket storage. Prevent quadratic rescans. Define a reference-expansion budget. cmark sets this budget to the document size or exactly 100,000 bytes, whichever is larger. This is a cmark implementation choice rather than a CommonMark syntax rule. See cmark 0.31.2 `src/blocks.c:528-533`.

**Correctness cases:** Escaped delimiters, delimiter runs, intraword underscores, nested emphasis, links containing emphasis, images containing links, prohibited links inside links, code-span precedence, nested destination parentheses, titles, Unicode labels, duplicate definitions, unmatched brackets, 999-code-point and 1,000-code-point raw label interiors in ASCII and multibyte forms, entity boundaries, and raw HTML termination.

**Alternative:** Reject repeated rescans for each closer. Use delimiter and bracket stacks so adversarial inputs remain bounded.

**Dependencies:** C2 and a pinned Unicode case-fold implementation.

**Acceptance:** Match the applicable 0.31.2 expected trees and later rendered output. Add adversarial growth probes for delimiter runs, brackets, references, and nested parentheses. Reject any superlinear case before public release.

### C4. Add HTML rendering and complete conformance

**Targets:**

- New `renderCommonMarkHtml`.
- `HtmlRenderOptions`.
- Iterative node walker over `CommonMarkDocument`.
- `test/commonmark_conformance_test.zig`.

**Change:** Add one HTML renderer first. Keep parsing and rendering as separate calls. Do not include rendering in parser throughput results.

**Security contract:** Public rendering defaults to safe output. It escapes text and attributes, omits raw HTML, and suppresses dangerous URL schemes. Raw HTML and unsafe URLs require an explicit unsafe option.

**Conformance mode:** The upstream HTML corpus expects raw CommonMark HTML behavior. Run the 652-example conformance oracle only with an explicit conformance or unsafe rendering option. Add separate tests for the safe default. Never weaken the public default to make the conformance corpus pass.

**Acceptance:**

- The explicit conformance renderer matches all 652 expected HTML values exactly.
- The safe renderer omits block and inline raw HTML.
- The safe renderer suppresses `javascript:`, `vbscript:`, `file:`, and unsafe `data:` destinations.
- The marker parser has unchanged output and performance gates.
- Failures report release, example number, section, and source-line range.

**Dependencies:** C3.

### C5. Publish the opt-in CommonMark parser

Publish `parseCommonMark` only after C0 through C4 pass. Keep `indexMarkdown`, `buildMarkdownTape`, `MarkdownStreamIndexer`, and the resident `Parser` unchanged.

A full CommonMark streaming parser is a later project. It must retain open containers, pending delimiter state, reference definitions, and unresolved inline content across chunks. The existing marker streamer's unfinished-line model is not sufficient.

## CommonMark performance measurement contract

Do not reuse the marker-projection ranking for the semantic parser.

A future semantic comparison must use these separate profiles:

1. `commonmark-parse`: build a complete semantic document and destroy it.
2. `commonmark-dom`: build the document, traverse every semantic node and attribute, hash decoded text, then destroy it.
3. `commonmark-render-html`: parse, render with a named safety policy, consume output, and destroy all storage.
4. `commonmark-resource-error`: report latency for explicit size or depth failures. Do not report MB/s for these rows.

The cmark and SIMD adapters must use the same CommonMark version, source policy, options, and checksum domain. The semantic checksum must include node kind, child order, heading level, list attributes, code info and text, decoded text, links, images, destinations, and titles. Do not include implementation-specific allocation layout.

Keep the five marker fixtures for marker regression measurements. Add semantic fixtures for paragraphs, nested blocks, fences, code spans, emphasis, links, images, references, HTML, entities, line endings, and adversarial resource limits.

A semantic parser result is publishable only after conformance. This plan makes no CommonMark parser speedup claim.

## Compatibility, security, and resource decisions

| Decision | Status | Reason and cost |
|---|---|---|
| Preserve all marker APIs and token meanings | Keep | Existing users depend on the fast restricted profile |
| Add semantic kinds to `MarkdownTokenKind` | Reject | A flat marker stream cannot preserve tree meaning or precedence |
| Add “full” flags to `scanMarkdownLine` | Reject | CommonMark needs interacting block and inline phases |
| Reintroduce an exact-size two-pass tape build | Reject | The measured experiment regressed and one-pass growth already shipped |
| Add a separate `commonmark` module | Keep | It makes semantic cost and compatibility explicit |
| Claim partial block support as CommonMark | Reject | Partial extensions do not satisfy the 652-example contract |
| Mutable AST parity with cmark | Defer | Mutation needs span invalidation and more ownership rules |
| XML, man, CommonMark, and LaTeX renderers | Defer | They are not needed for parser or HTML conformance |
| Full CommonMark streaming | Defer | It requires persistent block, inline, and reference state |
| GFM tables, task lists, strikethrough, footnotes | Reject from this project | They are extensions, not CommonMark 0.31.2 |
| Raw HTML by default | Reject | It creates an injection risk at render time |
| Unsafe URL schemes by default | Reject | They create script and local-resource risks |
| Recursive tree destruction | Reject | Deep input can exhaust the call stack |
| Unbounded nodes, nesting, labels, or decoded output | Reject | Crafted input can exhaust memory or create superlinear work |
| Treat resource errors as Markdown rejection | Reject | CommonMark syntax accepts every character sequence |

## Requested probes for the implementation owner

Run these only in the controlled measurement phase. Do not infer their answers from source.

1. Instrument `MarkdownTapeSink.grow` by fixture. Record call count, requested bytes, final length, and retained capacity.
2. Compare current DOM traversal with M1. Preserve tape construction and all checksum work.
3. Attribute `memcpyFast` with call-site stacks before changing tape finalization.
4. Measure no-marker, one-marker, five-marker, 640-marker, 4,095-marker, 4,096-marker, and 4,097-marker documents.
5. Alternate baseline and candidate process order at least seven times on the fixed CPU and hashes.
6. Report the five-percent direction band separately from any paired confidence interval used to accept code.
7. Profile the semantic parser only after it passes the full conformance corpus. Compare it with cmark semantic work, never with marker projection.

## Sources

### Local parser and benchmark sources

- `src/formats/markdown.zig:8-17,19-47,59-108,181-211,213-556,569-843,893-1114,1126-1323`.
- `src/root.zig:26-34`.
- Packet `zig/markdown_api.zig:15-135`.
- Packet `bench/adapters/markdown.cpp:26-205`.
- Packet `bench/markdown_adapter_test.cpp:20-96`.
- Packet `docs/superpowers/specs/2026-09-09-seven-format-profiles.md:19-29,45-50`.
- Packet `corpus/MANIFEST.json:306-359` and the five cited fixture files.
- `test/corpus/upstream/markdown/MANIFEST.md:1-157`.
- `docs/superpowers/plans/2026-09-09-parser-performance.md:296-361`.

### Measurement sources

- Packet `results/2026-09-09-reference-analysis/markdown-comparisons.json`.
- Packet `results/2026-09-09-reference-analysis/deep-profiles.json:218-289`.
- Packet `results/2026-09-09-reference-analysis/markdown-simd-markdown-dom-deep-hotspots.txt`.
- Packet `results/2026-09-09-reference-analysis/markdown-markdown-dom-deep-hotspots.txt`.
- Packet `results/2026-09-09-comparative-rerun/full/1-markdown-*.json` for report metadata and work profiles.

### Installed cmark 0.31.2

- `build-performance/CMakeCache.txt:202-205,260-269` pins `/nix/store/sjxyx09n6a44nyqqpjw8pwpcjnha2q6l-cmark-0.31.2`.
- Installed `include/cmark_version.h` defines `CMARK_VERSION_STRING "0.31.2"`.
- Installed `include/cmark.h:34-67,91-106,126-145,173-246,267-420,449-642` defines nodes, allocation, iteration, parsing, rendering, and options.
- Installed `lib/pkgconfig/libcmark.pc` reports version 0.31.2.

### Primary upstream sources

- CommonMark 0.31.2 specification: <https://spec.commonmark.org/0.31.2/>.
- CommonMark 0.31.2 conformance data: <https://spec.commonmark.org/0.31.2/spec.json>.
- cmark block parser, tag 0.31.2: <https://github.com/commonmark/cmark/blob/0.31.2/src/blocks.c>.
- cmark inline parser, tag 0.31.2: <https://github.com/commonmark/cmark/blob/0.31.2/src/inlines.c>.
- cmark string buffers, tag 0.31.2: <https://github.com/commonmark/cmark/blob/0.31.2/src/buffer.c>.
- cmark parser constants, tag 0.31.2: <https://github.com/commonmark/cmark/blob/0.31.2/src/parser.h>.
- cmark reference map, tag 0.31.2: <https://github.com/commonmark/cmark/blob/0.31.2/src/references.c>.
- cmark node layout and lifecycle, tag 0.31.2: <https://github.com/commonmark/cmark/blob/0.31.2/src/node.h> and <https://github.com/commonmark/cmark/blob/0.31.2/src/node.c>.
- cmark iterator, tag 0.31.2: <https://github.com/commonmark/cmark/blob/0.31.2/src/iterator.c>.
- cmark default allocator, tag 0.31.2: <https://github.com/commonmark/cmark/blob/0.31.2/src/cmark.c>.
- cmark HTML renderer and safe defaults, tag 0.31.2: <https://github.com/commonmark/cmark/blob/0.31.2/src/html.c>.
