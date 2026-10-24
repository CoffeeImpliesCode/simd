# Indexes, tapes, and streams

## Parsing layers

Stage 1 produces structural offsets and sentinels. It does not validate document grammar.
Stage 2 validates the complete source and produces a format-specific tape.
Resident parsers reuse index storage and expose one active document/focus.
Their token cursors and event readers borrow complete caller-owned input.

JSON, JSONC, and JSON5 share `core/stage2.zig` with separate dialect rules.
JSON and JSONC use RFC 8259 numbers and double-quoted strings.
JSONC adds line and block comments, without trailing commas.
JSON5 adds single quotes, identifier keys, trailing commas, and its number and whitespace rules.
JSON5 identifiers use ECMA-262 5.1 `IdentifierName` categories with Unicode 17.0.0 tables.
They do not use the modern `ID_Start` and `ID_Continue` properties.

A JSON-family tape word stores a kind, a `u32` source offset, and a `u24` payload.
Container closing words point back to their opening word.
Opening words store element counts. Forward skipping scans nested words.
Colons and commas do not appear on the tape.
A string or tape count that exceeds its representation returns `TapeTooLarge`.

JSONL owns record metadata and one JSON tape per eager record.
LF outside strings ends a record. Blank and trailing records are skipped.
`TapeRecordParser` instead reuses one record tape.
Iterator advance, release, or parser reset invalidates its previous checked records and cursors.

## Source and storage checks

JSON-family `Document.root(input)` checks for an empty tape, not source identity.
The caller must supply the original immutable bytes and keep the source and tape alive.
Raw source views retain this source-lifetime requirement after a protocol lease ends.

The format-local checks compare the recorded source pointer and length:

| Accessor | Source mismatch error |
| --- | --- |
| `MarkdownDocument.root` | `InvalidSource` |
| `XmlDocument.root` | `SourceMismatch` |
| `YamlDocument.root` | `SourceOutOfBounds` |
| Extended YAML `Document.ensureSource` | `SourceOutOfBounds` |

Reusable JSONL records also check record-source identity.
Generation checks reject stale handles only while the owner remains alive.
Generations are finite. They do not extend owner or allocator lifetime.

`json_value.decodeString` checks source, overlap, and capacity before writing.
Every error leaves the caller's output buffer unchanged.
`json_value.parseNumber` returns a source span and typed value without changing JSON grammar.
XML text, CDATA, and attribute events provide `decodedLength(source)` and `decodeInto(options)`.
`XmlQName` splits lexical names without namespace resolution.

## Format-local models

- Markdown tapes contain headings, fences, list items, blockquotes, inline code, link markers, and thematic breaks.
  They describe marker streams, not a CommonMark semantic document.
- XML supports UTF-8 XML 1.0 names, attributes, built-in and numeric entities, comments, CDATA, and processing instructions.
  Declarations permit version `1.0`, optional UTF-8 encoding, and optional `yes` or `no` standalone values.
  DTDs, DOCTYPE declarations, external entity expansion, transcoding, and namespace resolution are unsupported.
- Basic YAML supports block and flow collections, quoted and plain scalars, document markers, and comments.
  Anchors, tags, directives, and multiline block scalars return `Unsupported`.
- Extended YAML adds literal and folded block scalars, multiline quotes, and compact sequence mappings.
  Its document owns tape, metadata, and cooked bytes while it borrows source bytes.
  Its explicit limits can lower the fixed depth cap of 1024, but cannot raise it or set it to zero.
  The opening line of a quoted scalar counts toward its scalar-line limit.
  Block headers and terminal line sentinels do not count.
  Aliases, anchors, tags, complex keys, directives, multiple documents, and schema resolution remain unsupported.
- CommonMark 0.31.2 uses a separate flat semantic document with nodes, text, and references.
  Parser options bound input, nodes, text, delimiters, brackets, references, depth, and work.
  The text budget cannot exceed the `u32` representation. More than 64 prefixes on one line returns `NestingTooDeep`.
  Node IDs are document-local indexes. Text can be normalized rather than a source slice.
  Inline source spans can be `0..0`.
  `ChildIterator.next()` can return null for exhaustion or invalid links. Check `isInvalid()` after traversal.

YAML permits U+FEFF inside quoted scalars and as an initial UTF-8 BOM.
It rejects U+FEFF elsewhere and rejects other quoted noncharacters.
Streaming YAML preserves quote, plain-scalar, and block-scalar context across completed lines.
A source encoding error still reports `Invalid` after an earlier `Unsupported` block header.

CommonMark HTML defaults to `.safe`: raw HTML is omitted and dangerous URL schemes are filtered.
This bounded policy is not a general-purpose sanitizer or transcoder.
`.conformance` permits unsafe content and requires trusted input or a separate sanitization boundary.
Link destinations, image sources, and autolinks percent-encode unsafe characters, while preserving existing percent escapes.
HTML text and attributes escape `&`, `<`, `>`, and double quotes. Apostrophes remain unchanged.

## Errors and limits

Validators return `null` for valid input, a diagnostic for the first format error, and an error union for operational failures.
Diagnostics borrow snippets from the source.
JSONL coordinates refer to the complete input and include record bounds and an index.
Markdown treats CR, LF, and CRLF as line endings. Both CRLF bytes belong to the preceding line.
Its snippets exclude line endings and offsets past the source clamp to its length.

An `index…Into` failure can leave an output prefix without a usable count. Discard that prefix.
Zero limits have type-specific meanings. Read each option before treating zero as unlimited.
Assertion-backed preconditions diagnose misuse in `debug` and `safe` builds.
Violations in `fast` and `small` builds are unchecked illegal behavior.

## Streaming boundary

JSON, JSONL, JSONC, JSON5, Markdown, XML, and basic YAML expose `StreamIndexer`:
`init`, `feed`, `feedFrom`, `finish`, `take`, `reset`, and `deinit`.
JSON-family streams use two padded slots and shared lexical carry state.
Markdown, XML, and YAML retain their own unfinished lexical or line state.
`feed` borrows a chunk only for the call. `take` transfers index storage after successful `finish`, once per document.

`feedFrom` drains `std.Io.Reader.buffered()`, feeds those bytes, and tosses them only after success.
It calls `fill(1)` when needed and converts `EndOfStream` to `finish`.
Other reader errors return `ReadFailed`. Inspect the provider for detail, including cancellation.
Already consumed and indexed prefixes remain after an error.
The reader and its backing buffer must remain alive throughout the call.

Default options select one document. JSONL mode requires the JSON dialect.
Combining JSONL with JSONC or JSON5 returns `InvalidOptions` before allocation.
Indexing does not validate record grammar.
Stage 2 and resident traversal still require a separate complete source buffer.
CommonMark and extended YAML have no stream indexer.

## Benchmark archives

`bench` measures seven formats, five workloads, and six stages: 210 cases over 35 inputs.
Markdown rows measure markers. YAML rows use the basic profile.
`traverse_prefix8` consumes eight events or EOF.
`bench-semantic` measures CommonMark and extended YAML on each fixture's declared stages.
It accepts one positional iteration count from 1 to 32, default 3.
Neither semantic parser supports streaming.

`benchmark` and `benchmark-semantic` accept `record OUT`, `verify ARCHIVE`, and `reproduce OLD NEW`.
Recording options are `--samples N` and `--iterations N`, from 1 to 32, default 3.
The non-semantic command also accepts `--stream-chunk-size N`: 64, 256, 1024, 4096, or 16384, default 4096.
Archives use exclusive creation. An existing output directory is an error.
A failed recording writes a failed manifest and exits nonzero.
Archives contain the executable, source capture, manifest, and sample stdout/stderr with sizes and SHA-256 hashes.

The schemas are `simd-benchmark-archive` and `simd-semantic-benchmark-archive`, both version 1.
Verification rechecks stored files, metadata, and decoded captures without network access.
Reproduction requires matching source, executable, toolchain, build configuration, and host identity.
It compares input identities, checksums, and allocation counts and sizes. It does not compare timings.
Timings describe the recording host. These measurements do not rank other libraries.

Archive load tests inject each allocation failure with backing-allocator resizing disabled for a deterministic allocation sequence.
