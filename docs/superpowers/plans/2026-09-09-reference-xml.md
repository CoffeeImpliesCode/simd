# XML reference analysis: pugixml 1.16

## Scope and evidence rules

This document is an analysis and an implementation plan. It does not change the parser or the benchmark.

The measured reference is **wrapped pugixml 1.16**, not bare pugixml. The installed header sets
`PUGIXML_VERSION` to `1160`. The Nix source derivation fetches tag `v1.16` with content hash
`sha256-gdfVktqG4Adcq1QvLyvx7EFV336gnNWXL+X/NOFJ0gs=`. The installed configuration uses the
normal `char` and pointer layouts. It does not enable compact mode or disable XPath. [L10] [P1]

The labels below have fixed meanings:

- **MEASURED**: a benchmark result or a sampled profile observation.
- **SOURCE FACT**: behavior that follows from the inspected source.
- **INFERENCE**: a proposed explanation. It needs a controlled experiment.

For accepted inputs, the ratio is wrapped-pugixml throughput divided by native throughput. For
rejected inputs, the ratio is native latency divided by wrapped-pugixml latency. Thus, a ratio above
`1.05` means that the reference is faster. Ratios from `0.95` through `1.05` are neutral. This band
is descriptive. It is not a statistical test. [L2]

## Coverage and measured reversals

### Accepted inputs

**MEASURED:** Each cell is the median of three process samples. Every row has the same input hash,
outcome, checksum, work profile, preparation policy, timed iteration count, and selected CPU on both
sides. All ten accepted comparisons put the reference outside the five-percent band. [L2]

| Mode | Corpus ID | Bytes | Native MB/s | Wrapped pugixml MB/s | Reference/native | Direction |
|---|---|---:|---:|---:|---:|---|
| validate | `synthetic-xml-sparse` | 4,610 | 49.17 | 125.61 | 2.555 | reference faster |
| validate | `synthetic-xml-dense` | 4,354 | 55.82 | 123.83 | 2.218 | reference faster |
| validate | `synthetic-xml-unicode` | 7,588 | 63.40 | 134.03 | 2.114 | reference faster |
| validate | `synthetic-xml-escaped` | 20,343 | 59.18 | 103.72 | 1.753 | reference faster |
| validate | `real-xml-pugixml-character` | 181 | 16.57 | 89.74 | 5.415 | reference faster |
| DOM | `synthetic-xml-sparse` | 4,610 | 28.31 | 83.54 | 2.951 | reference faster |
| DOM | `synthetic-xml-dense` | 4,354 | 33.08 | 87.89 | 2.657 | reference faster |
| DOM | `synthetic-xml-unicode` | 7,588 | 29.44 | 95.44 | 3.242 | reference faster |
| DOM | `synthetic-xml-escaped` | 20,343 | 29.00 | 87.35 | 3.012 | reference faster |
| DOM | `real-xml-pugixml-character` | 181 | 13.14 | 116.85 | 8.891 | reference faster |

The accepted fixtures cover these paths. [L4]

| Corpus ID | Structure and exercised behavior |
|---|---|
| `synthetic-xml-sparse` | XML declaration and 128 shallow sibling records. It stresses short names, attributes, and self-closing elements. |
| `synthetic-xml-dense` | One-line outer `<dense depth="80">` with 80 nested `<level>` elements and a `<leaf>` (82 element levels under the wrapper's root-depth convention). It stresses stack, element, text, escaped-ampersand, and CDATA paths. |
| `synthetic-xml-unicode` | CJK element names; Greek and CJK attribute values; Cyrillic, CJK, accented, and emoji text. It exercises native UTF-8 and XML Name checks. |
| `synthetic-xml-escaped` | Predefined and numeric references in attribute and text values. It exercises entity decoding in both value kinds. |
| `real-xml-pugixml-character` | A 181-byte pugixml sample with a declaration, processing instruction, and self-closing elements. |

**MEASURED:** The reference advantage grows from validate to DOM on every accepted case. Among the
four synthetic cases, the largest change is escaped XML, from `1.753x` to `3.012x`; Unicode grows
from `2.114x` to `3.242x`. The real 181-byte row changes more, but its fixed-cost sensitivity
requires the matched rerun below. [L2]

**MEASURED:** The real reference result reverses its own expected mode order. Its DOM result is
`116.85 MB/s`, but its validate result is `89.74 MB/s`. DOM executes an extra checksum traversal in
source. The source does not explain a cheaper DOM path. Do not use this reversal as a parser claim.
The 181-byte input amplifies fixed runner, call, allocation, and clock effects. A matched alternating
rerun is required. [L2] [L7]

**MEASURED:** Native DOM is slower than native validate on every accepted case. The four synthetic
changes agree with the extra native checksum work. The real result is also in that direction. [L2]
**MEASURED:** There is no native/reference direction reversal for sparse, dense, Unicode, escaped,
real, or rejected cases. Every comparison row favors wrapped pugixml; the only reversal is the
wrapped reference's real-case DOM-versus-validate ordering above. [L2]

### Rejected inputs

The comparison JSON stores total elapsed nanoseconds for a timed batch. It does not store a
single-rejection latency in `median_elapsed_ns`. Every raw XML row reports 100 completed timed
iterations. The table divides each comparison median by 100. Therefore, every value below is
**normalized nanoseconds per rejection**. The ratio is unchanged. [L2] [L3]

**MEASURED:** All fourteen rejected comparisons put the reference outside the five-percent band.
Rejected rows are latency results. They are not throughput results. [L2]

| Mode | Corpus ID | Bytes | Native ns/rejection | Wrapped pugixml ns/rejection | Native/reference latency | Direction |
|---|---|---:|---:|---:|---:|---|
| validate | `synthetic-xml-mismatch` | 21 | 7,599.53 | 243.64 | 31.192 | reference faster |
| validate | `synthetic-xml-truncated` | 19 | 7,465.62 | 294.73 | 25.330 | reference faster |
| validate | `synthetic-xml-unknown-entity` | 26 | 7,758.78 | 100.16 | 77.464 | reference faster |
| validate | `synthetic-xml-invalid-codepoint` | 23 | 8,768.99 | 106.65 | 82.222 | reference faster |
| validate | `synthetic-xml-doctype` | 45 | 4,719.57 | 33.66 | 140.213 | reference faster |
| validate | `synthetic-xml-duplicate-attribute` | 26 | 7,791.03 | 318.38 | 24.471 | reference faster |
| validate | `synthetic-xml-multiple-roots` | 18 | 7,696.05 | 370.07 | 20.796 | reference faster |
| DOM | `synthetic-xml-mismatch` | 21 | 7,669.07 | 242.95 | 31.566 | reference faster |
| DOM | `synthetic-xml-truncated` | 19 | 7,538.27 | 294.81 | 25.570 | reference faster |
| DOM | `synthetic-xml-unknown-entity` | 26 | 8,037.50 | 103.15 | 77.921 | reference faster |
| DOM | `synthetic-xml-invalid-codepoint` | 23 | 8,023.95 | 106.81 | 75.124 | reference faster |
| DOM | `synthetic-xml-doctype` | 45 | 4,328.92 | 34.40 | 125.841 | reference faster |
| DOM | `synthetic-xml-duplicate-attribute` | 26 | 7,681.11 | 319.96 | 24.006 | reference faster |
| DOM | `synthetic-xml-multiple-roots` | 18 | 7,448.62 | 371.81 | 20.033 | reference faster |

**SOURCE FACT:** Both modes take the same path until a rejection. Neither adapter computes a DOM
checksum after rejection. Thus, validate-to-DOM changes in rejected rows do not measure traversal.
They show separate-run variation and fixed dispatch or runner costs. [L6] [L7]

The exact rejection paths are as follows. These paths apply to both measured modes. [L6] [L7]

| Corpus ID | Native stopping path | Wrapped pugixml stopping path |
|---|---|---|
| `synthetic-xml-mismatch` | `buildXmlTape` allocates, validates the source, builds nodes, and rejects in `parseClosingElement`. | The restriction scan passes. `load_buffer` copies the input, builds a partial tree, and reports a start/end mismatch. |
| `synthetic-xml-truncated` | Allocation and source validation complete. Grammar reaches end-of-input with an open element. | The restriction scan passes. `load_buffer` copies and parses before reporting an unclosed element. |
| `synthetic-xml-unknown-entity` | Allocation and source validation complete. `validateData` rejects in `parseXmlEntity`. | `valid_restricted_input` rejects in `valid_entity` before `xml_document` construction. |
| `synthetic-xml-invalid-codepoint` | Allocation and source validation complete. `parseXmlEntity` rejects the XML character value. | `valid_entity` rejects the numeric value before `xml_document` construction. |
| `synthetic-xml-doctype` | Allocation and full source validation run first. `runGrammar` then rejects the `<!` opener at byte zero. | `valid_restricted_input` sees `<!` and returns before `xml_document` construction. |
| `synthetic-xml-duplicate-attribute` | `parseOpeningElement` calls `hasPreviousXmlAttribute` and rejects the second name. | Bare pugixml builds both attributes. The timed `valid_tree` nested scan rejects the duplicate. |
| `synthetic-xml-multiple-roots` | The first root closes. `parseOpeningElement` rejects the second root. | Bare pugixml builds both roots. The timed root-count loop rejects them. |

**INFERENCE:** Early wrapper exits explain why DOCTYPE, unknown entity, and invalid codepoint have the
smallest reference latencies. They do not isolate pugixml parser speed. The runner loop also becomes
 a material part of the 34 to 107 ns/rejection early-exit results. [L5] [L7]

Do not add fixture-specific early exits to close these ratios. If rejection latency becomes a product
requirement, use a separate hostile-input workload with lengths and error positions swept across the
input.

## Exact timed execution paths

### Runner boundary

**SOURCE FACT:** The runner loads the corpus and performs one warmup before timing. Each timed inner
iteration calls the adapter, checks its outcome and checksum, updates the completed count, and mixes
a sink. The timer includes those checks. It excludes the warmup and final report checks. The
comparative raw rows use 20 iterations per repeat and five repeats, for 100 calls. [L5]

**SOURCE FACT:** Both XML adapters declare `direct_input_fresh_allocation`. Validate uses
`fresh_dom_parse`. DOM uses `fresh_dom_parse_traversal`. The corpus input itself is already resident.
Fresh parser allocation and destruction occur inside each adapter call. [L7]

### Native `simd-xml`

1. **SOURCE FACT:** `run_simd_xml` checks mode and dispatches through the C ABI to
   `simd_bench_xml_validate` or `simd_bench_xml_dom`. [L7]
2. **SOURCE FACT:** Both exports call `buildAndRun`. It clears the checksum and calls
   `buildXmlTape(std.heap.page_allocator, input)`. Validate does not call the allocation-free
   `validateXml` API because the declared profile requires a fresh DOM-like tape. [L6]
3. **SOURCE FACT:** `buildXmlTape` reserves `min(input.len, 64)` tape words before parsing. It uses a
   fixed 1,024-frame stack. It converts the array list to an owned slice after success. [L8]
4. **SOURCE FACT:** `XmlParser.run` first calls `simd.validateUtf8`. `validateSource` then decodes the
   full source again to enforce XML character ranges. Grammar scans declarations, names, attributes,
   entities, comments, CDATA, processing instructions, roots, and matching close tags. [L8]
5. **SOURCE FACT:** The parser stores one eight-byte tape word per event. Names and values remain
   borrowed slices of caller input; parser writes its owned tape during construction but never mutates
   source. The public `XmlDocument.tape` field remains caller-mutable after construction; no strings
   are allocated. [L8]
6. **SOURCE FACT:** Validate destroys the completed tape and returns zero checksum. DOM first runs
   `canonicalChecksum`. It walks all tape words and calls the safe public `sourceSpan` for each word.
   `sourceSpan` invokes `xmlTapeSpanMatchesKind`, which reparses each raw span. [L6] [L8]
7. **SOURCE FACT:** The checksum parser finds element and attribute boundaries again. It decodes each
   attribute or text value once to find normalized length and again to hash normalized bytes. The
   deferred `deinit` then frees the tape through the page allocator. [L6]

### Wrapped pugixml

1. **SOURCE FACT:** `run_pugixml` validates the mode and checksum pointer. It makes a non-owning
   `std::string_view` over the resident corpus bytes. [L7]
2. **SOURCE FACT:** `valid_restricted_input` scans for NUL, excluded declarations, and entities. It
   skips comments, CDATA, and processing instructions. It validates only predefined or numeric
   entities and XML character values. This scan is inside the timed call. [L7]
3. **SOURCE FACT:** The adapter constructs `pugi::xml_document` only after the restriction scan.
   `xml_document` contains a 192-byte static area. The default allocator uses `malloc` and `free`.
   Additional node and attribute objects use 32 KiB document pages. [L10] [P2] [P3]
4. **SOURCE FACT:** The adapter calls `load_buffer`, not `load_buffer_inplace` and not
   `load_buffer_inplace_own`. It passes `encoding_utf8` explicitly. For non-empty input,
   `load_buffer` allocates a mutable private buffer, copies the UTF-8 input, adds a terminator, and
   then parses that private buffer in place. [L7] [P4]
5. **SOURCE FACT:** Parse flags are `parse_default | parse_comments | parse_pi`. They enable CDATA,
   entity expansion, EOL conversion, CDATA-style attribute whitespace conversion, comments, and
   processing-instruction nodes. They do not materialize declaration or DOCTYPE nodes. [L7] [P1]
6. **SOURCE FACT:** The parser replaces delimiters with NUL bytes. Names and decoded values point
   into its private input copy. Node and attribute objects use linked pointer layouts from pooled
   pages. It appends attributes without a duplicate-name check. [P3] [P5]
7. **SOURCE FACT:** After parsing, the adapter counts top-level roots. `valid_tree` then scans every
   node recursively. It enforces depth 256 and compares each attribute with all previous attributes.
   These timed checks are wrapper work. [L7]
8. **SOURCE FACT:** Validate returns after `valid_tree`. DOM recursively calls `add_element`. It
   hashes decoded NUL-terminated names and values and ignores comments, processing instructions, and
   declarations. The local document destructor frees the private buffer and all dynamic pages before
   the adapter returns. [L7] [P6]

### In-place parsing distinction

**SOURCE FACT:** Pugixml exposes `load_buffer_inplace` and `load_buffer_inplace_own`. Both parse
mutable caller-supplied storage and retain it for the document lifetime. The `_own` variant transfers
deallocation ownership to the document. The measured adapter cannot use them on the immutable shared
corpus buffer. The measured `load_buffer` copy is real timed work. [P1] [P4]

An in-place experiment must still copy the corpus into a fresh mutable buffer inside the timer. Moving
that copy into preparation would change `direct_input_fresh_allocation` and make the result
incomparable. An in-place result must remain diagnostic. It must not replace the ranked reference.

## Pinned pugixml hot paths and layout

### Name and markup scanning

**SOURCE FACT:** Pugixml classifies bytes through `chartype_table`. `ct_symbol` accepts ASCII name
bytes and every byte above 127. `ct_start_symbol` has the same broad high-byte rule. Name loops use a
four-byte unrolled scanner. The parser does not decode each non-ASCII name codepoint. [P5]

**SOURCE FACT:** Native `parseXmlName` now has a direct ASCII path and a checked Unicode fallback.
`skipXmlAsciiData` now skips ordinary ASCII text and attribute runs. This work is already shipped. The
focused internal XML probe fell from 12.675 to 3.007 billion user cycles and from 21.642 to 10.606
billion instructions. Do not propose the old scalar-decode removal again. [L9]

**SOURCE FACT:** Native still validates complete XML 1.0 Name ranges for Unicode names. Pugixml calls
itself non-validating and does not validate Unicode input. The timed wrapper does not add a UTF-8 or
Unicode-name pass. This feature difference is exercised by valid Unicode names. Invalid UTF-8 and
invalid Unicode names are not in the measured corpus. [L7] [L8] [P1]

### Text, attributes, and entities

**SOURCE FACT:** Pugixml transforms text and attributes while it parses the private mutable buffer.
`strconv_pcdata_impl` and `strconv_attribute_impl` use unrolled special-byte scans. `strconv_escape`
decodes predefined and numeric references in place. Gap compaction removes bytes after shorter
normalizations. [P7]

**SOURCE FACT:** Bare pugixml does not fail every unknown or invalid entity. Its conversion routine can
cancel conversion and continue. The adapter restriction scan supplies the measured rejection
contract. [L7] [P7]

**SOURCE FACT:** Native validates references during tape construction but keeps raw source values.
The benchmark checksum decodes them later. This preserves zero-copy storage and shifts decoding into
DOM traversal. [L6] [L8]

### Pools, object layout, and destruction

**SOURCE FACT:** The installed build does not define `PUGIXML_COMPACT`. A standard attribute stores a
header, name and value pointers, and previous and next links. A standard node also stores parent,
first-child, sibling, and first-attribute links. [L10] [P3]

**SOURCE FACT:** The document allocator uses a 32 KiB default page. Each new node or attribute calls
`reserve`, allocates from the current page, and links the object. Destruction frees the private input
buffer and each dynamic page. The root sentinel remains in the document's static storage. [P2] [P3]

**INFERENCE:** Pooled bump allocation can have lower per-object overhead than repeated growth of a
page-allocator-backed tape. It also stores much more metadata. Source structure alone cannot assign
any fraction of the measured gap to either effect. Count allocation calls, requested bytes, and tape
capacity per fixture before a capacity change.

### Whole-process user-cycle profiles

**MEASURED:** The available profiles are synthetic DOM process runs at 499 Hz with `cycles:u`,
`--call-graph dwarf,8192`, CPU 2, and `repeat: 3` for both implementations. The report contains
55 native samples and 21 reference samples, with zero lost samples. The sample count is low.
`user_seconds` in the metadata is 0.185901 for native and 0.104387 for the reference; these are
process-level observations, not timed-loop-only parser measurements. Symbol shares guide work within
one process. Aggregate events and durations cannot compare the two processes. [L11]

The listed top-level overhead rows are self samples for each process. Nested call-chain annotations
provide context, not extra shares; `run_pugixml` and `simd_bench_xml_dom` include wrapper work.

| Native symbol | User-cycle sample share |
|---|---:|
| `formats.xml.buildXmlTape` | 29.44% |
| `formats.xml.decodeXml` | 13.99% |
| C export `simd_bench_xml_dom` | 12.34% |
| `formats.xml.XmlParser.validateData` | 10.96% |
| `formats.xml.parseXmlName` | 9.89% |
| benchmark `xml_api.parseEntity` | 4.09% |
| `mem.findScalarPos` via `hasPreviousXmlAttribute` | 4.09% |
| `formats.xml.XmlParser.parseOpeningElement` | 3.97% |
| `formats.xml.XmlParser.emit` | 3.33% |
| `mem.eql` via `xml_api.parseEntity` | 2.03% |
| `core.simd.validateUtf8` | 2.00% |

| Wrapped-reference symbol | User-cycle sample share |
|---|---:|
| `run_pugixml` | 42.67% |
| pugixml `append_new_node` | 6.34% |
| wrapper `valid_entity` | 6.33% |
| `memcmp` | 6.32% |
| pugixml `strconv_pcdata_impl` | 6.31% |
| pugixml `memmoveFast` from PCDATA conversion | 6.31% |
| `xml_attribute` conversion operator via `valid_tree` | 5.30% |
| pugixml `load_buffer_impl` | 4.63% |
| pugixml `strconv_attribute_impl` | 3.94% |
| `xml_node::first_attribute` via `add_element` | 3.34% |
| wrapper `valid_tree` | 2.79% |

**INFERENCE:** The reference profile directly shows wrapper restrictions, node allocation, string
comparison, PCDATA/attribute conversion, and DOM traversal. The native profile shows the full-source
validation/tape build, checksum export, XML name parsing, duplicate-attribute scan, entity decoding,
and UTF-8 validation. These are attribution clues only; they do not prove a percentage of the
throughput gap. [L11]

### High-repeat deep profiles

**MEASURED:** Separate deep profiles also ran the synthetic DOM benchmark at 499 Hz with
`cycles:u`, `--call-graph dwarf,8192`, and CPU 2. The native process used benchmark `repeat: 66`;
the reference process used `repeat: 172`. Both reports have about 1,000 samples and zero lost
samples. These are whole-process profiles: runner, parser, checksum/traversal, allocation, and
destruction work remain in the process. The unequal repeat counts prevent aggregate event or duration
comparisons. [L12]

The listed top-level overhead rows are self samples for each process. Nested call-chain annotations
provide context, not extra shares. They are not a cross-process speed-gap decomposition.

| Native symbol | User-cycle sample share |
|---|---:|
| `formats.xml.XmlParser.validateData` | 18.25% |
| `formats.xml.buildXmlTape` | 15.83% |
| C export `simd_bench_xml_dom` | 12.15% |
| `formats.xml.parseXmlName` | 10.05% |
| benchmark `xml_api.parseEntity` | 8.41% |
| `formats.xml.decodeXml` | 8.29% |
| `mem.eql` via `formats.xml.parseXmlEntity` | 8.13% |
| `formats.xml.XmlParser.parseOpeningElement` | 5.13% |
| benchmark `xml_api.addNormalizedData` | 3.81% |
| `formats.xml.XmlParser.emit` | 2.71% |
| `formats.xml.hasPreviousXmlAttribute` | 2.32% |

| Wrapped-reference symbol | User-cycle sample share |
|---|---:|
| `run_pugixml` | 28.92% |
| checksum `add_element` | 14.14% |
| `memcmp` | 7.60% |
| wrapper `valid_entity` | 7.37% |
| pugixml `load_buffer_impl` | 6.08% |
| `strlen` | 4.60% |
| pugixml `strconv_escape` | 4.55% |
| pugixml attribute conversion | 3.49% |
| wrapper `valid_tree` | 3.00% |
| pugixml PCDATA conversion | 2.82% |
| `memchr` | 2.21% |

**INFERENCE:** The deep native profile strengthens the case for first measuring checksum span
validation, global source-proof reuse, entity normalization, names, and duplicate scans. The deep
reference profile shows wrapper restriction, checksum traversal, input loading, string-length scans,
and in-place conversion. It still cannot identify which change closes a cross-process throughput gap.
The low-repeat profile above is complementary, not a replacement. [L11] [L12]

## Why the current result is slower

1. **MEASURED:** Current native is slower on every accepted and rejected row. There is no direction
   reversal between implementations. [L2]
2. **SOURCE FACT:** Native validates UTF-8 once, then decodes the complete source again for XML
   character validity. Valid grammar paths inspect text and attributes again in `validateData`.
   **INFERENCE:** Reusing the global proof can remove accepted-input work. [L8]
3. **SOURCE FACT:** Native DOM calls the public corruption-safe `sourceSpan` for each tape word.
   `sourceSpan` reparses the word before the checksum parses its fields again. **INFERENCE:** A private
   trusted view for the just-built tape can remove redundant DOM work without weakening the public
   API. [L6] [L8]
4. **SOURCE FACT:** Escaped attribute and text values are validated during parse. The checksum then
   parses each reference to determine decoded length and parses it again to emit bytes. Pugixml
   decodes during parse and hashes stored decoded values. **INFERENCE:** This helps explain why the
   measured gap grows sharply in escaped DOM. It does not quantify the gap. [L2] [L6] [P7]
5. **SOURCE FACT:** Native validates Unicode codepoints and full XML Name ranges. Pugixml uses broad
   high-byte name classes, and the wrapper does not add that validation. **INFERENCE:** This extra
   contract adds work to valid Unicode input. The measured data cannot isolate its cost. [L7] [L8] [P8]
6. **SOURCE FACT:** The 181-byte real case still allocates and destroys a native tape. It also runs
   full source validation. **INFERENCE:** Fixed work dominates that case. The reference DOM reversal
   prevents a stronger allocation claim without a rerun. [L2] [L6]
7. **SOURCE FACT:** Duplicate checking is quadratic in attribute count on both sides. Native reparses
   prior raw attribute syntax. The wrapper compares names already stored by pugixml. The measured
   accepted fixtures have ordinary attribute counts. The one rejected fixture has only two duplicate
   attributes. **INFERENCE:** This is a scale risk, not an explanation for most current rows. [L4]
8. **MEASURED:** The low-repeat native profile gives 4.09% to `mem.findScalarPos` through
   `hasPreviousXmlAttribute`; the high-repeat deep profile gives 2.32% to
   `formats.xml.hasPreviousXmlAttribute`. Both mix all synthetic DOM cases. They give larger shares
   to validation, names, and checksum decoding. Do not prioritize a duplicate table only from the
   current corpus. [L11] [L12]

No source fact assigns a percentage of the speed gap. Only controlled variants can do that.

## Feature matrix

| Capability | Native XML now | Pugixml 1.16 now | Exercised by this benchmark | Decision and cost |
|---|---|---|---|---|
| Storage model | Eight-byte tape. The parser writes tape words during construction and does not mutate borrowed `[]const u8` source; public `XmlDocument.tape` is a mutable slice and `source` is caller storage. Names and values borrow source. | Mutable linked DOM. Names and decoded values point into a private mutable input copy or pool strings. | Yes, on every accepted row. | Preserve native zero-copy ownership and lifetime contract. Do not turn the tape into a pointer DOM for parity. |
| In-place load | Borrows caller-supplied source through `[]const u8`; parser does not copy or mutate it. Source and document lifetime remain caller contracts. | `load_buffer_inplace` and `_own` are supported. The measured adapter uses copying `load_buffer`. | Pugixml in-place APIs are not exercised. | Keep any in-place reference run diagnostic. Never move its required copy outside timing. |
| DOM mutation | No node or attribute mutation API. | Add, insert, move, copy, rename, set, and remove APIs are present. | No. | Defer. This needs ownership, stable handles, reclamation, and structural invariants unrelated to the fast parser. |
| Serialization | No XML serializer. Raw source remains available to its owner. | `xml_node::print`, `xml_document::save`, streams, files, flags, BOMs, and encoding conversion are present. | No. | Defer a full serializer with mutable DOM. A later streaming writer must be a separate module and profile. |
| XPath | No XPath engine. | XPath 1.0 query objects and selectors are built. Pugixml documents conformance limits. | No query compiles or executes. | Reject parser coupling. Consider a separate query layer only after a concrete workload exists. |
| Input encodings | UTF-8 with optional UTF-8 BOM. A declaration can only name UTF-8. Invalid UTF-8 is rejected. | Auto, UTF-8, UTF-16 LE/BE/native, UTF-32 LE/BE/native, native `wchar_t`, and Latin-1. Standard `char` storage is UTF-8. | The adapter passes explicit UTF-8. No detection or transcoding runs. | Add separate explicit transcoders only if users need them. Keep the UTF-8 parser unchanged and separately benchmarked. |
| XML declaration | Enforces one leading `xml` declaration. It requires version `1.0`, permits UTF-8 and standalone `yes` or `no`, checks order, and records a raw tape event. | Can parse and optionally materialize a declaration node. The measured flags do not materialize it. | Sparse and real accepted inputs have declarations. Malformed forms are not measured. | Add a typed read-only declaration view. Do not broaden accepted declaration syntax implicitly. |
| DOCTYPE and DTD | Rejects DOCTYPE and all other `<!...>` declarations except comments and CDATA. | Can parse and store an opaque DOCTYPE node. It does not process inner DTD declarations or validate from a DTD. | The rejected DOCTYPE case is caught by the wrapper before pugixml. | Keep rejected by default. An opaque token would need an explicit profile and size limit. Do not add DTD processing. |
| Predefined and numeric entities | Validates five predefined names and decimal or hexadecimal numeric references. Tape values stay raw. Benchmark checksum decodes them. | Expands predefined and numeric references in place. The wrapper supplies strict invalid-reference rejection. | Escaped, unknown-entity, and invalid-codepoint cases exercise this area. | Add reusable decoded-value access. Keep general entities disabled. |
| General or external entities | Unsupported and rejected as unknown references. No network path exists. | Pugixml does not process DTD entities. It has no automatic external-entity fetch in this parse path. | No accepted case. Unknown entity is rejected. | Reject automatic expansion and all network access. See the security decision below. |
| Namespaces | Colons are XML Name characters. `xmlns` is an ordinary attribute. There is no URI resolver or expanded-name API. | DOM names are QNames. XPath has no namespace nodes and compares QNames rather than expanded names. | No namespace-resolution case exists. | Add a lexical QName helper first. Defer scoped URI resolution until a real API contract exists. |
| Duplicate attributes | Rejected during parse by exact byte equality after reparsing prior attributes. | Bare parser retains duplicates. Timed `valid_tree` rejects by exact name equality. | One two-attribute rejection. High counts are not in the comparative corpus. | Prototype a bounded Bloom prefilter with exact confirmation. Never trust a hash alone. |
| Roots and depth | Enforces one root and a 1,024-frame open-element stack; a self-closing leaf at the full-frame boundary differs from a paired child. | Bare parser can retain multiple roots. Wrapper enforces one root and depth 256 uniformly per element. | Multiple roots are measured. Dense has 82 element levels under the wrapper's root-depth convention. The limit difference is not exercised. | Keep the core frame limit. Keep the benchmark profile at inputs no deeper than 256. Add boundary probes before changing either limit. |
| Comments, CDATA, and processing instructions | Validates and records all three as borrowed events. | The measured flags materialize all three. | Dense uses CDATA. Real uses a processing instruction. | Existing parity is sufficient for this profile. |
| XML character and name validity | Validates UTF-8, XML character ranges, and XML 1.0 Name ranges. | Non-validating parser. It does not validate Unicode and accepts broad high-byte name bytes. | Valid Unicode paths run. Invalid UTF-8 and invalid names do not. | Preserve strict native checks. Never remove correctness to match reference speed. [P8] |
| Well-formedness edge checks | Rejects raw `<` in attributes, `--` in comments, invalid references/chars, and other XML 1.0 violations. | Manual documents raw `<` attributes and `--` comments as not rejected; wrapper scans NUL, `<!`, and entities while skipping comment/CDATA/PI bodies, but adds neither check. | No raw-`<` attribute or malformed-comment fixture; unknown entity, invalid codepoint, and DOCTYPE are measured. | Preserve strict native behavior. Add non-comparative probes before any compatibility change. [P1] [P8] |

**SOURCE FACT:** Pugixml's XPath is not fully conformant. It does not expose namespace nodes. QName
name tests do not use expanded names. DTD information does not support `id()`. Some string functions
are not fully Unicode-aware. Calling it “full XPath and namespace support” would be incorrect. [P1]

## Prioritized performance plan

The shipped ASCII name and text work is the baseline. Each task below starts from that source. Do not
repeat the old direct-ASCII experiment. Apply one task at a time, then rebuild the comparison packet.

### Stage 0: split parser, wrapper, traversal, allocation, and destruction costs

This stage is diagnostic. It does not change ranked adapter behavior.

**Targets**

- `zig/xml_api.zig`: `buildAndRun`, `canonicalChecksum`, `addAttribute`, and `addText`.
- `bench/adapters/xml.cpp`: `valid_restricted_input`, `run_pugixml`, `valid_tree`, and `add_element`.
- `src/formats/xml.zig`: `buildXmlTape`, `XmlParser.run`, and `XmlDocument.sourceSpan`.

**Experiments**

1. Add temporary native variants for build and destroy, build plus current checksum, and checksum over
   a prebuilt tape. The prebuilt variant is attribution only. It is not a throughput result.
2. Add temporary reference variants for restriction scan only, load and destroy, load plus
   `valid_tree`, and the full checksum path.
3. Add a reference `load_buffer_inplace_own` variant. Allocate and copy the mutable buffer inside each
   timed call. Allocate that buffer with pugixml's configured allocation function so ownership and
   deallocation match. Keep this result outside the ranked comparison.
4. Count allocation calls, requested bytes, final tape length, and retained tape capacity per fixture.
   Compare the current page allocator with `c_allocator` only as an allocator attribution probe.
5. Run per-case `cycles`, `instructions`, `branches`, `branch-misses`, and cache counters. Do not use
   the mixed whole-process profile to assign one case's cost.
6. Add wrapper depth 256/257 probes and native 1,024-frame probes with both self-closing and paired
   leaves. Record that native core and benchmark wrapper limits are intentionally different before any
   limit change.

**Gate**

Each full variant must preserve outcome and checksum. Only the existing full paths can produce a
ranked result. Reject any attribution run that moves input copy, allocation, validation, or destruction
outside its stated timer.

### Stage 1: stop reparsing trusted tape spans in the benchmark checksum

**Evidence:** The high-repeat deep profile places `validateData` and `parseOpeningElement` below
`xmlTapeSpanMatchesKind -> sourceSpan -> canonicalChecksum`. `sourceSpan` is designed to reject a
corrupted public tape. The benchmark consumes a local tape immediately after successful construction.
[L8] [L12]

**Exact change**

1. Add a private `trustedSourceSpan` in `zig/xml_api.zig`.
2. Check that `document.source` matches `input` by pointer and length, then check tape index, kind
   range, offset, length, and monotonic order.
3. Do not call `xmlTapeSpanMatchesKind` from this private path.
4. Use it only in `canonicalChecksum` for the local `XmlDocument` returned by the same `buildAndRun`.
5. Keep `XmlDocument.sourceSpan`, `xmlTapeToken`, `root`, and cursor validation unchanged.

**Ownership and API contract**

In the benchmark, document and input aliases remain local until checksum completion; source is read
through `[]const u8`, and no caller-mutated tape crosses this boundary. This is a local trust
boundary, not a public immutable guarantee. The public corruption-safe APIs retain all current checks.
There is no new export. `XmlDocument.root` still replays `validateXmlTape` and checked
`xmlTapeToken`/span validation for public caller data; that cost is not in benchmark `canonicalChecksum`.

**Alternatives**

- Do not weaken `sourceSpan` globally. External callers can mutate public tape words.
- Do not add a public “unchecked tape” API before another trusted consumer exists.
- Do not fuse checksum generation into parse. That would stop measuring a post-parse traversal.

**Correctness cases**

Run every checksum oracle. Include self-closing elements with attributes, comments around content,
declaration, CDATA, Unicode names, entities, CRLF, and empty values. Keep existing corrupted-tape
tests on the public APIs.

**Measurement gate**

Accept only if all five accepted DOM cases are at or below `0.95` candidate/baseline median time, or
if the aggregate gain has a documented per-case tradeoff. Validate should stay in the neutral band.
Reject on any checksum change, accepted-input error, or public tape-safety change.

### Stage 2: reuse the global source-validity proof in `validateData`

**Evidence:** `XmlParser.run` invokes `validateSource` before grammar on the normal build path. However,
`xmlTapeSpanMatchesKind` and `xmlTapeAttributeMatches` construct fresh `XmlParser` values with the
default `source_error == null` and call `parseText`, `parseOpeningElement`, or `validateData` directly.
Therefore `source_error == null` alone is **not** proof of full-source validity. On the normal path,
`validateData` still decodes non-ASCII bytes and checks XML character ranges again. The low-repeat
profile samples `validateData`, `validateSource`, and `decodeXml`; the deep profile supplies the
larger attribution. [L8] [L11] [L12]

**Exact change**

1. Keep `validateData` as the checked path. Add a private `validateDataAfterSourceProof` entry and
   the private grammar call chain needed to pass a proof token.
2. In `run`, call `validateSource`; only after success create a stack-local private proof token and
   invoke the proven-valid grammar path. Do not store the token or a validity enum in any public
   document or parser field.
3. In the proven-valid path, scan only context-sensitive ASCII bytes: `&`, `<`, and the possible
   start of `]]>`. Treat all other bytes as globally validated data. Keep entity syntax and numeric
   XML-character checks in `parseXmlEntity`.
4. `xmlTapeSpanMatchesKind`, `xmlTapeAttributeMatches`, `initOnDemandDocument`, public `root`, and
   every other caller use the checked path. If `validateSource` records an error, still run checked
   grammar and retain the current source-versus-grammar earliest-error comparison; do not return
   `source_error` before grammar. Never infer proof from `source_error == null`; it is the default in
   reparsing and on-demand parsers.
5. Use a four-byte or vector special-byte scan only after the semantic split proves useful. Do not add
   another copy of the shipped ASCII classifier.

**Ownership and API contract**

No tape or event layout changes. `validateXml`, `buildXmlTape`, resident parsing, and on-demand parsing
must return the same errors and offsets. The proof token is stack-local to the eager `run` call; it
cannot cross borrowed caller turns or on-demand document lifetimes. Expose no public trust bit or
forgeable validity field. Public tape/source safety checks remain unchanged.

**Alternatives**

A full fusion of UTF-8 validation into grammar could save another pass. Defer it because it risks
source-error precedence and would duplicate the shared SIMD UTF-8 validator.

**Correctness cases**

Cover invalid UTF-8 and invalid XML characters before, at, and after grammar errors. Place them at
vector boundaries. Cover non-ASCII text, names, attributes, comments, CDATA, and processing
instructions. Retain exact byte, line, and column diagnostics against XML 1.0 Char/Name/EOL rules.
[P8]

**Measurement gate**

Target validate and DOM for sparse, dense, escaped, Unicode, and real inputs. Accept when at least
three cases improve beyond the band and none regresses beyond it. Require lower instructions on the
changed path. Reject any diagnostic change.

### Stage 3: add a bounded, collision-safe duplicate prefilter

**Evidence:** `hasPreviousXmlAttribute` reparses every earlier name and skips every earlier quoted
value for each new attribute. The focused workload already has 1, 8, 32, and 128 attribute shapes.
The low- and high-repeat profiles sample this function, but the comparative accepted corpus has low
attribute counts. [L8] [L9] [L11] [L12]

**Exact change**

1. Add a local `XmlAttributeNameFilter` near `hasPreviousXmlAttribute`.
2. Use a fixed 1,024-bit Bloom filter with two bit positions from one 64-bit name hash.
3. Reset its 128 bytes for each opening element and declaration.
4. If either bit is clear, set both bits and skip the prior-attribute scan.
5. If both bits are set, call the current `hasPreviousXmlAttribute` for exact byte comparison.
6. Keep exact confirmation permanently. A hash match alone must never reject input.
7. Use the same filter in `parseOpeningElement` and `parseDeclarationAttributes`.

**Ownership and API contract**

The filter is fixed stack state for the current attribute list. It stores no borrowed pointer beyond
the current call. It allocates no memory. Hash collisions only cause slower exact confirmation.
They cannot cause a false rejection or false acceptance.

**Alternatives**

- Reject a fixed open-addressing table. Table overflow needs a fallback and raises stack or clear cost.
- Reject a growable hash map until allocation counts prove a benefit.
- Reject an attribute-count limit in the existing API. That would narrow accepted input.

**Correctness cases**

Cover duplicate first, middle, and last attributes. Cover equal prefixes, Unicode names, declaration
pseudo-attributes, and generated hash collisions. Cover 1, 8, 32, 128, and more than 512 unique
attributes. The overflow-free Bloom design must still accept all unique names.

**Measurement gate**

Require lower cycles and instructions for 32 and 128 attributes. Keep 1 and 8 attributes within the
neutral band. Keep sparse, dense, Unicode, escaped, and real cases within the neutral band. Reject any
outcome or diagnostic-offset change.

### Stage 4: normalize each benchmark value once

**Evidence:** `addAttribute` and `addText` parse entities once for decoded length and again through
`addNormalizedData`. CDATA also scans once for length and once for output. The low-repeat profile
reports `xml_api.parseEntity` at 4.09%; the deep profile reports 8.41%. The low-repeat profile does
not isolate `addNormalizedData`; the deep profile reports it at 3.81%. [L6] [L11] [L12]

**Exact change**

1. Add a fixed 512-byte `NormalizedValueScratch` owned by `canonicalChecksum`.
2. Decode and normalize a value into scratch while computing its length.
3. Hash the length, then hash the completed scratch slice.
4. If output exceeds 512 bytes, fall back to the existing allocation-free two-pass path.
5. Reuse the same scratch for each attribute, text node, and CDATA node.
6. Fast-return the raw slice when no entity, CR, or attribute whitespace conversion is present.

**Ownership and API contract**

Scratch lives on the checksum stack. No decoded slice escapes the current value. The canonical hash
format stays byte-for-byte identical. Large values remain allocation-free through the fallback.

**Alternatives**

- Do not change the hash to put length after bytes. That would invalidate all cross-adapter oracles.
- Do not add one heap allocation per value.
- Do not store decoded copies in every tape. That would change the zero-copy parser profile.

**Correctness cases**

Cover all five predefined entities, decimal and hexadecimal values, one- through four-byte UTF-8
outputs, CR, CRLF, tab, newline, empty values, exactly 512 decoded bytes, spill at 513, and long values.
Check attribute whitespace separately from text EOL rules.

**Measurement gate**

Target escaped DOM first. Accept if it improves beyond the band and all other DOM cases remain within
the band or improve. Validate must remain unchanged. Reject any checksum or allocation-count change
on the ordinary path.

### Stage 5: test a wider ASCII Name continuation scan

**Evidence:** Direct ASCII name classification is already shipped, but `parseXmlName` still has a
per-byte continuation loop. It is 9.89% of the low-repeat samples and 10.05% of the high-repeat
deep samples. Pugixml uses a four-byte unrolled class-table loop. [L8] [L9] [L11] [L12] [P5]

**Exact experiment**

1. Keep the first-byte XML NameStart check unchanged.
2. Compare a four-byte unroll with a machine-word XML NameChar mask.
3. Stop before any high byte. Use the existing Unicode decoder from that byte.
4. Keep exact delimiter location and invalid-name diagnostics.
5. Select one implementation from measured short, medium, and long name distributions. Do not keep
   two general loops.

**Ownership and API contract**

`parseXmlName` continues to return a source offset into borrowed input. The scan allocates no memory,
does not mutate source or tape, and leaves `parseName`/grammar error offsets unchanged.

**Alternatives and correctness cases**

Retain the current scalar continuation loop as the baseline and test one four-byte or word-mask
implementation. Cover empty and one-byte names, delimiters at every unroll boundary, invalid ASCII,
high-byte fallback, Unicode NameStart/NameChar, and names ending at input. Reject any changed error
offset or accepted language.

**Measurement gate**

Target sparse, dense, and Unicode. Short names must not regress beyond the band. Unicode must retain
all NameStart and NameChar boundary behavior. Reject a wider scan that only wins a synthetic long-name
microbenchmark.

### Stage 6: change tape allocation only after counters identify it

**Evidence:** `buildXmlTape` reserves `min(input.len, 64)` words, grows through `ArrayList`, and calls
`toOwnedSlice`. The low- and high-repeat profiles do not isolate allocator time. The internal
allocation report uses a different allocator from the external adapter. [L6] [L8] [L9] [L11] [L12]

**Decision rule**

Measure allocation count, requested bytes, final tape length, capacity, and destruction cost for each
external fixture. If growth is material, compare a conservative capacity hint with current growth.
If `toOwnedSlice` is material, design explicit capacity ownership before removing shrinkage. Do not
free a retained-capacity allocation through a shorter slice.

**Ownership and API contract**

The returned `XmlDocument` owns the tape allocation through the caller-supplied allocator.
Capacity metadata must describe the allocation actually freed by `XmlDocument.deinit`; no borrowed
source or retained-capacity slice may outlive its documented owner.

**Alternatives and correctness cases**

Compare only measured capacity hints and current growth. Reject one-word-per-byte reservation and
allocator changes hidden in the adapter. Cover empty and short inputs, exact growth boundaries,
allocation failure, capacity overflow, successful `deinit`, and checksum/outcome preservation.

**Measurement gate**

Require lower real and sparse fixed costs without more than five-percent requested-byte growth on
dense or escaped input. Reject a one-word-per-byte reservation. Reject an adapter-only allocator
change as a parser speedup claim.

## Explicit feature-parity plan

These tasks must use opt-in APIs. They must not expand the current benchmark profile silently.

### Parity 1: reusable decoded-value access

**Decision:** Implement when a parser consumer needs decoded XML values. This is the closest useful
parity extension because the benchmark currently duplicates the decoder.

**Target contract**

- Add a public, allocation-free decoded-value iterator or writer near `XmlAttributeEvent` and
  `XmlTextEvent` in `src/formats/xml.zig`.
- Accept caller-owned output or a writer. Return decoded byte count and exact errors.
- Normalize attribute whitespace and text EOL by explicit mode.
- Decode only predefined and numeric references; return the existing invalid-reference errors.
- Keep every existing raw event field and fast path unchanged.

**Dependencies and costs**

The public iterator must validate raw event boundaries and references, or consume a checked cursor; a
forged event or `[]const u8` argument is not validity proof. Borrowed source must remain alive and
unchanged, and caller output must not overlap source unless the implementation explicitly handles that
case.
Refactor `parseXmlEntity` to return both `next` and `codepoint`, and reuse it in the iterator. A
semantics-preserving decoder replacement may route `zig/xml_api.zig` through the iterator while
retaining `fresh_dom_parse_traversal` and `direct_input_fresh_allocation`; it remains rank-eligible
under the existing checksum contract. Raw-only diagnostics or new decoded-output semantics require
explicit new work-profile labels and comparison only within those contracts. The caller owns output
memory. Add no hidden allocation. Separately benchmark raw and decoded traversal.

**Correctness and measurement**

Cover predefined and numeric references, CR/CRLF, tabs and newlines, empty values, CDATA, and
decoded outputs above the scratch size. Compare decoded bytes and lengths with a strict oracle. Reject
any raw-event or ranked-checksum change; benchmark the decoded iterator under its own explicit label.

### Parity 2: typed declarations and lexical QNames

**Decision:** Implement as on-demand views. Do not change parser acceptance by default.

**Target contract**

- Add `XmlDeclarationInfo` with borrowed `version`, optional `encoding`, and optional `standalone`.
- Add `parseDeclarationInfo(raw)` and keep the raw declaration event.
- Add `XmlQName.split(raw_name)` with borrowed prefix and local-name slices.
- Define and validate empty prefix, empty local name, and multiple-colon behavior explicitly.

**Dependencies and costs**

These helpers allocate nothing. They borrow `raw`; returned slices are valid only while that storage
remains alive and unchanged. `parseDeclarationInfo(raw)` must validate declaration syntax and return
exact errors; `XmlQName.split(raw_name)` must validate the lexical QName or be explicitly named
unchecked and kept private. A `[]const u8` argument is not provenance proof. A lexical QName split is
not namespace resolution. Do not label it as such.

**Correctness and measurement**

Cover absent and present declarations, pseudo-attribute order, quote styles, encoding case, bare
names, prefixed names, empty and multiple-colon forms, and malformed raw slices. Returned views must
remain valid only for the unchanged input lifetime. Keep malformed-input errors explicit and do not
change the default parser language.

### Parity 3: explicit non-UTF-8 front ends

**Decision:** Conditional. Add only for a concrete user requirement.

- Add a separate transcoder for explicit UTF-16 LE/BE, UTF-32 LE/BE, and Latin-1 input.
- Return an owning UTF-8 buffer with source-encoding metadata and a required `deinit` contract.
- Preserve the original declaration metadata. Normalize the declaration's encoding field for the
  UTF-8 parser, or handle that field outside the parser. Never pass `encoding="UTF-16"` to the
  UTF-8-only declaration parser.
- Check BOM and declaration consistency. Reject malformed units and overlong output sizes.
- Put auto-detection in a separate convenience API, not in `buildXmlTape`.

**Compatibility and resource cost**

Transcoding allocates and can expand data. It changes lifetime and peak-memory behavior. Use checked
size arithmetic and an input/output byte limit. Benchmark transcode plus parse separately from native
UTF-8 parse.

**Correctness and measurement**

Cover each BOM and byte order, surrogate and scalar boundaries, malformed units, declaration
mismatches, NUL, and output-limit overflow. Compare transcoded UTF-8 with a trusted oracle. Measure
transcode plus parse separately; never fold this allocation and copy into the UTF-8 ranked profile.

### Defer: namespace URI resolution

A scoped namespace resolver needs binding stacks, default-namespace rules, reserved prefix checks,
and expanded-name identity. Neither current benchmark side provides full expanded-name semantics.
Defer it until a consumer defines lookup and error contracts. If implemented, keep it as an optional
layer over events and add explicit depth and binding limits.

### Defer: mutable DOM, mutation, full serialization, and XPath

These features need owned strings, stable handles, subtree lifetime rules, mutation checks, output
escaping, query compilation, and temporary query storage. They would replace or wrap the current deep
zero-copy module with a broad object model. They are not exercised by any measured case. Build them
as separate modules only after a product requirement. Do not load their cost into the restricted fast
API or its benchmark.

### Reject by default: DTD semantics, general entities, external entities, and network access

Pugixml does not process DTD declarations for parsing, despite its opaque DOCTYPE node. Full parity
does not require this behavior. General entity expansion adds exponential expansion risk. External
entities add file disclosure, request forgery, credential exposure, nondeterminism, and blocking I/O.

Keep all such behavior disabled in the parser. If an application later needs external resolution, put
it in an application-owned layer. Require an allowlisted resolver callback, no default network
implementation, byte and entity limits, expansion-depth limits, timeouts, cancellation, and explicit
provenance. Never make it part of the measured restricted profile.

## Measurement acceptance and rejection rules

1. Run seven alternating candidate/baseline process pairs for each changed stage. Pin the same logical
   CPU and preserve compiler definitions, input hashes, outcomes, checksums, and iteration counts.
2. Use per-case cycles and instructions for attribution. Use wall time for the external result.
3. Treat `0.95` through `1.05` as the descriptive neutral band. Do not use significance language.
4. Normalize every rejected batch by its recorded `completed_timed_iterations`. Prefer the raw
   `rejection_latency_ns_per_iteration` field when reporting one raw run.
5. Report rejected latency separately from accepted throughput.
6. Keep the reference restriction scan, root check, `valid_tree`, checksum, allocation, input copy,
   and destruction inside the timed wrapper.
7. Preserve all public restricted APIs. Profile expansion must use a new explicit API and a separate
   benchmark label.
8. Reject any optimization that changes diagnostics, accepted language, checksum, source borrowing,
   tape ownership, or resource limits without an approved contract change.
9. Reject any result that moves work into preparation, uses a prebuilt tree as throughput, or calls an
   in-place reference path on shared immutable corpus memory.
10. Do not convert sampled symbol shares into percentages of the implementation speed gap.

## Requested probes and remaining unknowns

1. Rerun the 181-byte real case with matched alternating order. Resolve the measured reference DOM
   versus validate reversal before any fixed-overhead claim.
2. Profile each accepted XML case separately. The whole-process profile mixes sparse, dense, Unicode,
   escaped, rejected, and fixture-specific paths.
3. Count external page-allocator operations. Current internal allocation counts use another allocator
   and cannot answer the external fixed-cost question.
4. Quantify how much `canonicalChecksum` spends in public span validation versus canonical decoding.
5. Measure Bloom-filter false-positive rates on 1, 8, 32, 128, and adversarial attribute names.
6. Add non-comparative invalid UTF-8, invalid Unicode Name, declaration-order, malformed-comment,
   raw-`<`-in-attribute, and depth-boundary probes. Include native self-closing and paired-leaf cases
   at the 1,024-frame boundary. They document feature differences that the current corpus does not test.
7. Keep the current pugi `load_buffer` result as the ranked reference. Record any in-place run as a
   counterfactual with its copy placement stated.

## Sources

### Local benchmark and native sources

- **[L1] Profile contract:**
  `~/simd-bench-corpus/docs/superpowers/specs/2026-09-09-seven-format-profiles.md:51-55`.
- **[L2] Comparison data:**
  `~/simd-bench-corpus/results/2026-09-09-reference-analysis/xml-comparisons.json:1-985`.
  It records 24 rows, three process samples per side, versions, work profiles, directions, throughput,
  and total elapsed batch time.
- **[L3] Raw timing rows:**
  `~/simd-bench-corpus/results/2026-09-09-comparative-rerun/full/1-xml-simd-xml-validate-synthetic.json:215-298`
  and
  `~/simd-bench-corpus/results/2026-09-09-comparative-rerun/full/1-xml-xml-validate-synthetic.json:135-320`.
- **[L4] Corpus manifest and fixtures:**
  `~/simd-bench-corpus/corpus/MANIFEST.json:361-484`,
  `~/simd-bench-corpus/corpus/synthetic/xml/*.xml`, and
  `~/simd-bench-corpus/corpus/real/xml/character.xml`.
- **[L5] Timer:**
  `~/simd-bench-corpus/bench/runner.hpp:610-776`.
- **[L6] Native benchmark wrapper:**
  `~/simd-bench-corpus/zig/xml_api.zig:90-406`.
- **[L7] C++ XML adapters:**
  `~/simd-bench-corpus/bench/adapters/xml.cpp:70-370`.
- **[L8] Native parser:**
  `~/projects/simd-performance/src/formats/xml.zig:1305-1734,1871-2373,2828-3010`.
- **[L9] Shipped performance wave:**
  `~/projects/simd-performance/docs/superpowers/plans/2026-09-09-parser-performance.md:296-388`.
- **[L10] Installed pin and configuration:**
  `~/simd-bench-corpus/build-performance/CMakeCache.txt:241-245`,
  `/nix/store/zi3y6h10cfdmj68qa3f0h3w0kpwnda42-pugixml-1.16/include/pugixml.hpp:1-16,1130-1199,1538-1549`,
  and `/nix/store/zi3y6h10cfdmj68qa3f0h3w0kpwnda42-pugixml-1.16/include/pugiconfig.hpp:12-31`.
  The Nix source pin is `https://github.com/zeux/pugixml/archive/refs/tags/v1.16.tar.gz`
  with hash `sha256-gdfVktqG4Adcq1QvLyvx7EFV336gnNWXL+X/NOFJ0gs=`.
  Derivation provenance: `/nix/store/d4z757af0pjkwigcxmlz8smvql1zzzva-pugixml-1.16.drv`;
  source derivation: `/nix/store/411905jr754hmh8k09c9kmqi9f71fzmp-source.drv`.
- **[L11] Whole-process user-cycle profiles:**
  `~/simd-bench-corpus/results/2026-09-09-reference-analysis/profiles.json:453-534`,
  `~/simd-bench-corpus/results/2026-09-09-reference-analysis/xml-simd-xml-dom-hotspots.txt:1-239`,
  and `~/simd-bench-corpus/results/2026-09-09-reference-analysis/xml-xml-dom-hotspots.txt:1-166`.
- **[L12] High-repeat deep profiles:**
  `~/simd-bench-corpus/results/2026-09-09-reference-analysis/deep-profiles.json:146-216`,
  `~/simd-bench-corpus/results/2026-09-09-reference-analysis/xml-simd-xml-dom-deep-hotspots.txt:1-144`,
  and `~/simd-bench-corpus/results/2026-09-09-reference-analysis/xml-xml-dom-deep-hotspots.txt:1-150`.

### Pugixml 1.16 primary sources

- **[P1] Header and manual:**
  [pugixml.hpp at v1.16](https://github.com/zeux/pugixml/blob/v1.16/src/pugixml.hpp#L200-L269),
  [buffer loading](https://github.com/zeux/pugixml/blob/v1.16/docs/manual.adoc#L590-L604),
  [parse flags and encodings](https://github.com/zeux/pugixml/blob/v1.16/docs/manual.adoc#L719-L812),
  [well-formedness compatibility gaps](https://github.com/zeux/pugixml/blob/v1.16/docs/manual.adoc#L811-L828),
  [mutation](https://github.com/zeux/pugixml/blob/v1.16/docs/manual.adoc#L1284-L1477),
  [serialization](https://github.com/zeux/pugixml/blob/v1.16/docs/manual.adoc#L1669-L1825), and
  [XPath limits](https://github.com/zeux/pugixml/blob/v1.16/docs/manual.adoc#L2198-L2205).
- **[P2] Allocator and page size:**
  [pugixml.cpp lines 459-613](https://github.com/zeux/pugixml/blob/v1.16/src/pugixml.cpp#L459-L613)
  and
  [manual memory internals](https://github.com/zeux/pugixml/blob/v1.16/docs/manual.adoc#L522-L553).
- **[P3] Standard node layout, allocation, and destruction:**
  [pugixml.cpp lines 1145-1305](https://github.com/zeux/pugixml/blob/v1.16/src/pugixml.cpp#L1145-L1305),
  [append allocation](https://github.com/zeux/pugixml/blob/v1.16/src/pugixml.cpp#L1490-L1510), and
  [document destruction](https://github.com/zeux/pugixml/blob/v1.16/src/pugixml.cpp#L7661-L7704).
- **[P4] Immutable-buffer copy and load:**
  [pugixml.cpp lines 2129-2150](https://github.com/zeux/pugixml/blob/v1.16/src/pugixml.cpp#L2129-L2150),
  [UTF-8 conversion dispatch](https://github.com/zeux/pugixml/blob/v1.16/src/pugixml.cpp#L2334-L2364), and
  [load_buffer_impl](https://github.com/zeux/pugixml/blob/v1.16/src/pugixml.cpp#L4847-L4891).
- **[P5] Character tables and tree parser:**
  [pugixml.cpp lines 1894-2047](https://github.com/zeux/pugixml/blob/v1.16/src/pugixml.cpp#L1894-L2047)
  and
  [pugixml.cpp lines 3331-3555](https://github.com/zeux/pugixml/blob/v1.16/src/pugixml.cpp#L3331-L3555).
- **[P6] Parse completion and document lifetime:**
  [pugixml.cpp lines 3609-3655](https://github.com/zeux/pugixml/blob/v1.16/src/pugixml.cpp#L3609-L3655)
  and
  [pugixml.cpp lines 7673-7704](https://github.com/zeux/pugixml/blob/v1.16/src/pugixml.cpp#L7673-L7704).
- **[P7] Entity, PCDATA, and attribute conversion:**
  [pugixml.cpp lines 2537-2630](https://github.com/zeux/pugixml/blob/v1.16/src/pugixml.cpp#L2537-L2630)
  and
  [pugixml.cpp lines 2634-2990](https://github.com/zeux/pugixml/blob/v1.16/src/pugixml.cpp#L2634-L2990).
- **[P8] XML and Namespaces conformance rules:**
  [XML 1.0 `Char`](https://www.w3.org/TR/xml/#NT-Char),
  [XML 1.0 `Name`](https://www.w3.org/TR/xml/#NT-Name),
  [XML 1.0 line-end normalization](https://www.w3.org/TR/xml/#sec-line-ends),
  [XML 1.0 attribute-value normalization](https://www.w3.org/TR/xml/#AVNormalize), and
  [Namespaces in XML qualified names](https://www.w3.org/TR/xml-names/#ns-qualnames).
