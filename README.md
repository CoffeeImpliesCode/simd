# simd

Native Zig primitives, structural indexes and parsers for caller-owned byte slices.
The development compiler is **Zig 0.16.0**. `minimum_zig_version` is a manifest
floor, not a promise that later compiler releases work.

## Consume the package

Add a `simd` dependency to your project's `build.zig.zon`. For a sibling checkout:

```zig
.dependencies = .{
    .simd = .{ .path = "../simd" },
},
```

In your `build` function, use your consumer's `target`, `optimize` and executable:

```zig
const dependency = b.dependency("simd", .{
    .target = target,
    .optimize = optimize,
    .vector_len = @as(usize, 16),
});
exe.root_module.addImport("simd", dependency.module("simd"));
```

Then `@import("simd")` reaches the core namespaces and `formats`. The registered
module supplies its own `build_options`; do not reconstruct that import yourself.
The same route works with a fetched package. This README and `examples/consumer.zig`
are included in the package's `paths` allowlist.

`vector_len` is optional. Omit it for the target CPU's default: 64 with AVX-512F
and AVX-512BW, 32 with AVX2, otherwise 16. An explicit width must be at least 4;
it need not be a power of two. `Mask(N)` is a logical N-bit integer, not a claim
about storage size, object padding or a foreign ABI. Bit `i` represents lane `i`.

The named artifacts are separate build products:

- `dependency.artifact("simd-static")`: the installed static archive.
- `dependency.artifact("simd")`: the fixed-sample mask visualizer, not a parser CLI.

There is no C ABI or header. Import the native module for the generic Zig APIs;
the archive is not an alternative C binding. The static artifact was formerly
also named `simd`; callers retrieving the archive must use `simd-static` now.

## Select the contract

| Namespace | Work and boundary |
| --- | --- |
| `simd` | Vector/byte primitives, masks and UTF-8 checks; no parser grammar |
| `stage1` | Owned structural offsets with sentinels; no source ownership |
| `stage2` | Validated JSON-family tape, cursors and borrowed diagnostics |
| `json_value` | Strict JSON string/number conversion into caller-owned values/storage |
| `ondemand` | Reusable JSON-family indexes with one active resident document/focus |
| `stream` | Chunk-fed JSON-family/JSONL indexes, not chunk-fed Stage 2 traversal |
| `debug` | Visualization into a caller-supplied writer |
| `formats.json`, `jsonc`, `json5`, `jsonl` | Separate quote, comment, number and framing rules |
| `formats.markdown` | Marker-kind tape, not CommonMark semantic parsing |
| `formats.xml` | UTF-8-only lexical XML; no transcoding, namespace resolution or DTD processing |
| `formats.yaml` | The bounded `yaml-basic-1.2.2` profile |
| `formats.commonmark` | CommonMark 0.31.2 semantic document and HTML renderer; no streaming |
| `formats.yaml_extended` | Opt-in `yaml-extended-e2b-1.2.2`; no streaming or schema resolution |

Root aliases name the same core declarations; their contracts live at the owning
namespace. Reachable struct fields are not private. A documented internal-state
field must not be modified outside its stated protocol.

## Ownership and lifetime

Register cleanup immediately after successful construction. The runnable
[`examples/consumer.zig`](examples/consumer.zig) demonstrates eager conversion,
resident traversal, index transfer, semantic rendering and an unchanged output
buffer on decode failure.

```zig
var document = try simd.formats.json.buildJsonTape(allocator, input);
defer document.deinit(allocator);
const cursor = try document.root(input);
const raw = try cursor.rawValue();
```

This fragment applies to a scalar root. `document` owns its tape; `raw` borrows
`input`. For JSON-family Stage 2, `root(input)` does **not** enforce source identity:
pass the exact immutable bytes used to build the tape, not a same-shaped substitute.
Keep tape storage and source live through cursor use. Raw source slices keep their
own source-lifetime obligation even after a cursor's protocol lease is released.

| Resource | Owner and release | Caller obligation |
| --- | --- | --- |
| Structural index | Returned owner; `deinit` with its allocating allocator | Copies alias allocations; release once. Growth/disposal invalidates storage views |
| Eager tape | Returned document; its `deinit` | Keep original source immutable/live; operation allocator must be compatible |
| Reusable parser storage | Parser; `deinit` after document release | Keep allocator backing state live and parser address stable while borrowed |
| Resident document/focus | Lease over parser state; document release | One active document/focus; pin pointer-bearing documents while readers use them |
| Reusable JSONL record tape | `TapeRecordParser`; reused on iterator advance | Previous checked records/cursors become stale; raw slices still depend on source |
| CommonMark nodes/text/references | `CommonMarkDocument`; stored-allocator `deinit` | Copies are not independent owners; pin document for `ChildIterator` |
| Extended YAML tape/metadata/cooked bytes | Extended `Document`; allocator-taking `deinit` | `Value.ownership()` distinguishes source and document storage |
| Rendered HTML | Returned allocation; caller's rendering allocator frees it | Independent of the document after successful rendering |

Do not change a live owner's allocator identity. A copied allocator interface does
not extend its backing state's lifetime. Copying an owning handle frees nothing;
calling cleanup a second time through either handle can free the same allocation.

Generation checks reject stale protocol handles only while owner storage remains
live. Generations are finite and eventually repeat; they do not keep a destroyed
parser alive. Mutating parser/indexer/iterator operations require exclusive use.
Read-only semantic access also requires no concurrent storage mutation or disposal
and a suitable allocator for any concurrent rendering.

## Errors, defaults and trust

- Validation entrypoints that return `!?Diagnostic` use `null` for valid input,
  a diagnostic value for document failure, and the error union for operational
  failure. Diagnostic snippets borrow source; coordinates are specified on each type.
- JSON5 keys follow the ECMA-262 5.1 `IdentifierName` grammar, not the modern
  Unicode `ID_Start` and `ID_Continue` properties. A start is a `Lu`, `Ll`,
  `Lt`, `Lm`, `Lo` or `Nl` code point, `$` or `_`; a continuation adds `Mn`,
  `Mc`, `Nd` and `Pc` plus U+200C and U+200D. The tables carry Unicode 17.0.0
  categories, so `U+2E2F` is a letter here and the `Other_ID_Start` and
  `Other_ID_Continue` code points are not identifiers.
- Markdown diagnostics break lines at CR, LF and a CRLF pair. A pair is one
  two-byte ending whose bytes both belong to the line it terminates, so the
  column of a byte in the pair stays on that line and a snippet holds line
  content only. `byte_offset` past the input clamps to the input length.
- A rendered CommonMark link destination, image source and autolink are
  percent-encoded against the unsafe set the reference lists. `%` is left as
  written, so an already encoded destination survives, and the set covers `^`,
  `{`, `|`, `}` and every control byte, including one an entity reference
  decodes. HTML text and attribute output escape `&`, `<`, `>` and `"`, and an
  apostrophe is written as itself in both, as the reference does.
- A YAML quoted scalar may carry a literal U+FEFF. An initial UTF-8 BOM is also
  permitted. Otherwise U+FEFF stays invalid, including in plain content,
  comments and block scalar bodies. Other quoted noncharacters stay invalid.
- YAML streaming source checks carry quote, plain-scalar and block-scalar
  context across completed lines; `reset` clears it. Source-invalid content
  still reports `Invalid` after an earlier `Unsupported` block header.
- An `index…Into` error may leave an output prefix without returning a usable
  partial count. Discard that output; do not infer whole-scan atomicity from a
  capacity check inside one mask extractor.
- `json_value.decodeString` checks source, overlap and required capacity before
  writing. The returned slice borrows the output buffer; every error leaves it unchanged.
- Streaming options default to one document. `.mode = .jsonl` requires
  `.dialect = .json`; JSONC/JSON5 combinations fail with `error.InvalidOptions`
  before allocation. Indexing does not validate record grammar.
- Stream `take` transfers only after successful `finish`, once per document.
  Assertion-backed preconditions diagnose reached misuse in Debug/ReleaseSafe;
  ReleaseFast/ReleaseSmall treat violations as unchecked illegal behavior.
- `feedFrom` borrows the supplied Reader/provider during the call and may block.
  Reader failures arrive as `error.ReadFailed`; inspect the concrete provider for
  detail, including cancellation. Already consumed/indexed prefixes survive an error.
- Zero limits do not share one universal meaning. Parser capacity zero can mean
  checked grow-on-demand; semantic resource limits have their own validation rules.
  Read the option field before using zero as unlimited.
- CommonMark IDs are document-local indexes, not owner identities. `NodeData.raw`
  names owned semantic text, not necessarily untouched source. Inline `SourceSpan`
  values can be `0..0`; they are not a general source map.
- A CommonMark `ChildIterator` can return `null` for exhaustion or invalid links;
  check `isInvalid()` after traversal.
- CommonMark HTML defaults to `.safe`: raw HTML is omitted and dangerous URL
  schemes are filtered. This is a bounded policy, not a general-purpose sanitizer
  or transcoder. `.conformance` is deliberately unsafe; use it only with a trusted
  input/spec harness or a separate sanitization boundary.

## Build and verify

```sh
zig build
zig build run
zig build example
zig build docs
zig build check
```

`check` retains all native roots, offline corpora, width-matrix checks and required
external analyzers/cross-tests; it also runs the ownership example. Host tool
requirements and checkout-specific scratch setup are development infrastructure,
not native consumer dependencies. Missing tools fail the gate. A passing default
build, a compiled foreign target and an executed test are different evidence.
No performance or full cross-target execution claim follows from this guide.

For ZLS build-on-save, set `build_on_save_args` to `["install"]` in the editor's
ZLS settings. ZLS otherwise selects `check` automatically. This repository's
`check` runs tests and external tools, not only compilation. A second gate can
conflict with the first gate's cross-test output lock. Run the full gate
explicitly with `zig build check`.

## API changes

- Registered native module: `simd`, with generated width options attached.
- Static artifact: `simd-static`; executable: `simd`.
- Conflicting JSONL/comment-dialect stream options now return `InvalidOptions`.
- Attached contracts specify ownership, aliases, source retention, defaults,
  trusted preconditions and failure residue; borrowing and allocator regimes remain.
- Generic visualization writers get signature-bearing compile errors for missing
  members; their argument and result types are checked by ordinary Zig calls.

The checkout also contains historical design records under `docs/`; those files
are not packaged and can describe proposals, not implemented APIs. The packaged
contract is this consumer guide plus the attached source declarations.
