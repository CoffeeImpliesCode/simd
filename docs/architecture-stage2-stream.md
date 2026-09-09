# simd — Stage 2, On-Demand, and Streaming Architecture

Status: Stage 1 indexing and Stage 2 validation are implemented for JSON,
JSONL, JSONC, JSON5, Markdown, XML, and YAML. Each format also exposes a
resident on-demand reader and a chunk-fed `StreamIndexer`.

Scope: this document records current contracts and the remaining roadmap.
Sections marked **Future roadmap** are designs, not current APIs. Sections
marked **Historical design record** describe the plan used for completed work.

Grounded in: `papers/1902.08318_parsing_gigabytes_of_json_per_second.pdf`,
`papers/2312.17149_on_demand_json.pdf`,
`~/projects/github-simdjson-simdjson/doc/ondemand_design.md`, simdjson
`json_scanner.h` / `json_structural_indexer.h` / tape design, RFC 8259, and the
current repo (`src/core/stage1.zig`, `src/core/stage2.zig`,
`src/core/ondemand.zig`, `src/core/stream.zig`, and `src/formats/*`).

---

## Item 1 — On-Demand Event Interface (implemented for all formats)

Each format exposes `initOnDemandDocument(parser, input)`. The document owns
no complete tape and borrows the caller-owned input slice. `tokenCursor()`
and `eventReader()` read through parser-owned reusable state under a
single-focus lease; `EventReader` emits a pull event sequence, but it is not
a chunk-at-a-time input reader.

### Historical design record: pull-based cursor over `Stage1.StructuralIndex`

The selected front-end was a zero-allocation pull cursor over the Stage 1
index, modeled on simdjson On-Demand. The 2023 paper reports a 5.1
instructions-per-byte geometric mean, about 70 percent faster than a DOM tape,
and up to 8.7 GiB/s on field-heavy queries. A zero-allocation `EventReader`
adapts the cursor to pull events over resident input. The 64-bit tape provides
a separate validated layer for cursor navigation.

```zig
pub const Error = error{
    UnexpectedEnd,         // incomplete array/object at end of input
    IncorrectType,         // requested conversion does not match token kind
    NumberError,           // malformed number on conversion
    StringError,           // unescaping failure
    OutOfOrderIteration,   // re-use of a consumed value
    NoSuchField,           // unordered findField missed
    DepthExceeded,         // fixed-depth stack overflow
    InputTooLarge,         // offset does not fit u32 (input >= 4 GiB)
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    capacity: usize,          // 0 = grow on demand
    indexes: []u32,           // stage-1 structural index, sentinel-padded
    string_buf: []u8,         // unescape scratch, parser-owned, reused
    pub fn init(allocator: std.mem.Allocator, max_capacity: usize) !Parser;
    pub fn deinit(self: *Parser) void;
    pub fn iterate(self: *Parser, input: []const u8) Error!Document;
};

pub const Document = struct {
    indexes: []const u32,     // pointer + len into Parser.indexes
    input: []const u8,        // caller keeps alive (padded-view rule)
    depth: i32 = 1,           // 0 = finished, 1 = root value, n = nested
    pos: u32 = 1,             // current tape position (index into `indexes`)
    string_buf: []u8,         // parser-owned unescape buffer (borrowed)
};
```

- Zero per-document heap allocation: `indexes` and `string_buf` are parser
  scratch reused across documents.
- Consume-once rule (simdjson semantics): a value converts at most once; a
  second `getString` after the buffer was overwritten → `OutOfOrderIteration`.
- One focus per `Document`; losing a child drops focus, detected via an
  `is_alive` flag.

### `TokenCursor` (pull engine) and the depth-delta skip

```zig
pub const TokenCursor = struct {
    doc: *Document,
    pub inline fn peek(self: *const TokenCursor) ?Token;
    pub inline fn advance(self: *TokenCursor) ?Token;
    pub inline fn peekIndex(self: *const TokenCursor, delta: i32) u32;
    pub inline fn peekLength(self: *const TokenCursor, delta: i32) u32;
    pub inline fn position(self: *const TokenCursor) u32;
    pub fn skipChild(self: *TokenCursor, parent_depth: i32) Error!void;
};
```

**Depth-delta skip.** Every structural byte maps to a fixed delta; all other
tokens contribute 0. The cursor consumes tokens accumulating depth until it
returns to the parent's depth. No recursion, no heap stack, no allocation —
the depth counter IS the state. O(sub-tree tokens).

```zig
const depth_delta: [256]i8 = blk: {
    var t: [256]i8 = @splat(0);
    t['{'] = 1;   t['['] = 1;
    t['}'] = -1;  t[']'] = -1;
    break :blk t;
};

pub fn skipChild(self: *TokenCursor, parent_depth: i32) Error!void {
    const doc = self.doc;
    var d = doc.depth;
    if (d <= parent_depth) return;
    while (d > parent_depth) : (doc.pos += 1) {
        if (doc.pos >= doc.indexes.len) return error.UnexpectedEnd;
        d += depth_delta[doc.input[doc.indexes[doc.pos]]];
    }
    doc.depth = d;
}
```

Sentinel padding guarantees `doc.indexes[doc.pos]` never reads out of bounds
and the loop terminates (every opened container closes exactly once).
`peekLength(delta) = indexes[pos+delta+1] - indexes[pos+delta]`; the sentinel
triple makes the last token's length well-defined and EOF exact.

### 64-bit `TapeWord` (shared with Item 4) and container back-patch

```zig
pub const TapeKind = enum(u8) {
    object_start, array_start, object_end, array_end,
    string, key, number, true_literal, false_literal, null_literal,
};

pub const TapeWord = packed struct(u64) {
    kind: u8,         // stored enum tag
    payload: u24,     // element count | jump-back | string length
    offset: u32,      // absolute input offset

    pub fn tapeKind(self: TapeWord) TapeKind {
        return @enumFromInt(self.kind);
    }
};
comptime { std.debug.assert(@bitSizeOf(TapeWord) == 64); }
```

### JSON-family `Document.root(input)` and `TapeCursor` ownership

A JSON-family Stage 2 `Document` owns only its tape and records its `Dialect`.
`Document.root(input)` borrows the exact immutable bytes used to build that
tape. The input and the `Document` must outlive the returned `TapeCursor`. Raw
string, number, and literal views are zero-copy slices of the borrowed input.

Container tape slots are append-only, so back-patch targets are stable. On
open, Stage 2 emits `{kind=open, payload=0}` and records the tape index. On
close, it emits `{kind=close, payload=tape_index_of_open}`, then stores the
element count in the opening word. A cursor scans nested words to skip forward
from an opening word. A closing word supports an O(1) `matchingStart()` jump
back to its opening word. `:` and `,` never appear on the tape.

### Zero-allocation `EventReader` pull adapter over resident input

```zig
pub const Event = union(enum) {
    object_start, object_end,
    array_start, array_end,
    key: []const u8,      // raw (still-escaped) slice; unescape on demand
    string: []const u8,
    number: []const u8,
    bool: bool,
    null,
};

pub const EventReader = struct {
    cursor: TokenCursor,
    stack: [max_depth]DepthEntry = undefined,  // fixed-depth — no heap
    top: usize = 0,
    pub fn next(self: *EventReader) Error!?Event;
    pub fn peek(self: *const EventReader) Error!?Event;
    pub fn skip(self: *EventReader) Error!void;
};
```

`next()` emission rules: `{`/`[` → push depth entry + start event; `}`/`]` →
pop + end event; string token → `key` iff enclosing container is an object and
a key is expected (tracked in the depth entry), else `string`; atom first byte
`-`/digit → `number`, `t`/`f` → `bool`, `n` → `null`; `:`/`,` are separators,
consumed silently. Laziness: events carry raw slices; unescape/convert only on
`.get()`/`.int()`/`.double()`. Zero-alloc: `stack` lives in the struct (1024 ×
~16 B = 16 KiB, matching Item 4 `max_depth`).

### Completed Stage 1 contract (index ↔ cursor bridge)

Strict JSON and JSONL Stage 1 index structural characters, atom starts, and
unescaped double-quote string openings. Their Stage 2 parsers can therefore
find keys and string values without another quote search. For these formats,
the implementation mirrors simdjson `json_scanner.h`: opening quotes are
pseudo-structural, but closing quotes are not.

```zig
// Strict JSON and JSONL only.
const string_start_quotes = unescaped_quotes & inside_without_closing;
const structural_indexes = (structural | atom_starts | string_start_quotes) & outside_string;
```

JSONC and JSON5 Stage 1 do not emit opening or closing string quotes in the
structural index. When Stage 2 reaches an opening quote in the source, it scans
through the matching closing quote and validates the string. This source scan
handles JSONC double-quoted strings and JSON5 single-quoted or double-quoted
strings.

After Stage 1 finishes, each indexer writes three sentinel entries:
`indexes[n] = len`, `indexes[n+1] = len`, and `indexes[n+2] = 0`. This makes
`peekLength` well-defined for the last real token and makes EOF detection exact.
`StructuralIndex` reserves the three sentinel slots.

Each JSON-family adapter pairs its Stage 1 quote and comment rules with the
matching Stage 2 `Dialect`. JSONL applies strict JSON rules to each record.
JSON On-Demand uses the same strict JSON quote and sentinel rules. Opening
quote indexing applies only to strict JSON and JSONL. JSONC and JSON5 use the
Stage 2 source scan described above.

### Performance: locality and allocation

| Property | On-Demand cursor | EventReader | Stage 2 tape cursor |
|---|---|---|---|
| Heap allocations per document | 0 (parser scratch reused) | 0 | owned tape |
| Per-token working set | 4-byte index + input byte | same | 8-byte tape word + input |
| Forward skip cost | O(subtree), depth counter | same | O(subtree), tape scan |
| Convert cost | only on `get_*` | only on `.get()` | raw views stay lazy |
| End-to-start navigation | no | no | O(1) with `matchingStart()` |

The tape is useful for validated repeated traversal. It does not own source
bytes. Raw-value access requires the exact immutable input passed to
`Document.root(input)`. On-Demand is useful for single-pass event iteration,
partial reads, format conversion, constrained memory, and skip-heavy traversal.
Numbers that a caller does not read are not converted.

---

## Item 3 — Vector-Width Dispatch (implemented)

The current indexers select 16-, 32-, or 64-byte vectors at compile time. The
design and adaptation inventory below are a **Historical design record**.

### Decision: comptime monomorphization, not a runtime vtable

```zig
pub fn indexJson(allocator: Allocator, input: []const u8) !StructuralIndex {
    return indexJsonImpl(detectVlen(), allocator, input);
}
```

Why comptime, not a runtime `Dispatch` vtable (`vlen, indexJson: *const fn`):
- The repo is vtable-free by style; a vtable adds an icache-indirect call per
  chunk and needs a CPUID/`/proc/cpuinfo` shim the repo does not have.
- `builtin.cpu.features` is comptime-known for native and `-Dcpu` targets;
  `featureSetHas` folds to a constant. Runtime detection buys nothing.
- Cost: 3 monomorphs × 6 indexers ≈ 3× code, < 10 KiB/format; a normal build
  instantiates only the selected width.
- The vtable stays documented as a fallback for heterogeneous prebuilt
  binaries; do not implement now.

### Width-generic core primitives (`src/core/simd.zig`)

The core is already generic except two u64-hardwired helpers. `Mask(bits)` =
`@Int(.unsigned, bits)` yields `u16`/`u32`/`u64` for VLEN 16/32/64, so
`Mask(VLEN)` is the single mask type and all `matchByte`/`matchAny2`/`matchAny4`/
`matchRange` helpers stay untouched.

```zig
// prefixXor(comptime T, bitmask) is ALREADY generic over u16/u32/u64 — no change.

pub fn computeBackslashRuns(comptime T: type, backslash_mask: T, prev_ends_in_backslash: bool) BackslashResult(T) {
    // generic over u16/u32/u64; even/odd masks per width:
    //   u16: 0x5555 / 0xAAAA;  u32: 0x55555555 / 0xAAAAAAAA;  u64: 0x55…/0xAA…
}
pub const BackslashResult = struct { odd_backslash_mask: T, ends_in_backslash: bool };
pub const BackslashResult64 = BackslashResult(u64); // comptime alias
pub const computeBackslashRuns64 = computeBackslashRuns;   // comptime alias

pub fn extractBitIndexes(comptime T: type, bitmask: T, base_offset: usize, out_indexes: []u32) usize {
    // body unchanged from u64 version: @ctz(mask) → usize, mask &= mask - 1
}
```

`trailingBackslashRunOdd` takes `Vec(VLEN, u8)` instead of `Vec(64, u8)`.

### Shift typing: `Log2Int(T)` is u4/u5/u6

`@ctz`/`@ctlz` on `u16`/`u32`/`u64` return `std.math.Log2Int(T)` = `u4`/`u5`/`u6`.
Today the shift RHS is hardcoded `@as(u6, @intCast(k))`; generic code types it
per width:

```zig
const Shift = std.math.Log2Int(Mask(VLEN)); // u4 | u5 | u6

fn validByteMask(comptime VLEN: usize, valid_count: usize) Mask(VLEN) {
    if (valid_count == VLEN) return ~@as(Mask(VLEN), 0);
    if (valid_count == 0) return 0;
    return (@as(Mask(VLEN), 1) << @as(Shift, @intCast(valid_count))) - 1;
}
```

Covers `leadingRunEndMask` and the end-of-chunk carries that today read
`@as(u64, 1) << 63`.

### Comptime CPU selection — `detectVlen()`

```zig
fn detectVlen() comptime_int {
    return switch (builtin.cpu.arch) {
        .x86, .x86_64 => if (comptime std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f))
            64
        else if (comptime std.Target.x86.featureSetHas(builtin.cpu.features, .avx2))
            32
        else
            16,
        else => 16, // arm/aarch64 (.neon), unknown targets: 128-bit = 16 bytes
    };
}
```

`avx512f` → 64, `avx2` → 32, else 16. On arm, `.neon`/aarch64 baseline is
exactly 16 bytes; on x86, 16 = SSE2. `@Vector(16, u8)` lowers on baseline
targets — 16 is the universal fallback, no scalar-dedicated path needed. The
backslash-run algorithm is branchless and width-independent; speedup comes by
construction from `@Vector` lowering. CI exercises all three widths via
`-Dcpu=x86_64+avx512f` (64), `-Dcpu=x86_64_v3` (32), baseline (16); `build.zig`
needs no width plumbing.

### Historical adaptation inventory

| File | Pre-implementation state | Implemented change |
|---|---|---|
| `src/core/simd.zig` | `computeBackslashRuns64`, `BackslashResult64`, `extractBitIndexes(u64,…)`, `trailingBackslashRunOdd(Vec(64,u8),…)` | genericize; keep `…64` comptime aliases |
| `src/core/stage1.zig` | none | unchanged |
| `src/formats/json.zig` | `windows(64)`, `matchByte(64)`/`matchAny4(64)`/`matchRange(64)`, `validByteMask(usize) u64`, `computeBackslashRuns64`, `prefixXor(u64,…)`, `[64]u32` candidates, `@as(u64,1)<<63` carries | `indexJsonImpl(comptime VLEN)`; `Mask(VLEN)`, `[VLEN]u32`, `Shift`-typed, `@min(input.len - base, VLEN)` |
| `src/formats/jsonl.zig` | same as json + `matchByte(64,'\n')` | same parametrization |
| `src/formats/jsonc.zig` | same + per-byte `visible_mask: u64`, `[64]u32`, scalar `trailingParse` | `Mask(VLEN)`, `[VLEN]u32`, `[VLEN]u8` trailingParse param |
| `src/formats/json5.zig` | same as jsonc + `[64]u8` chunk_bytes | `chunk_bytes[VLEN]` |
| `src/formats/markdown.zig` | `markdownCandidateMask(Vec(64,u8)) u64`, `markdownValidMask(usize) u64`, `[64]u32`, `extractBitIndexes(u64,…)` | `markdownCandidateMask(comptime VLEN, Vec(VLEN,u8)) Mask(VLEN)`; `*Impl(comptime VLEN)` |
| `src/formats/xml.zig` | `windows(64)`, `matchByte/Any2(64)`, `[64]u32`, `extractBitIndexes` | `indexXmlImpl(comptime VLEN)`; scalar post-filter over `[VLEN]u32` |
| `src/core/debug.zig` | `highlightMulti(Vec(64,u8), u64)`, `[64]u8`, `u64 bit` | `highlightMulti(comptime VLEN, Vec(VLEN,u8), Mask(VLEN))`; `printAscii` unchanged |
| `src/main.zig` | `comptime assert(vector_len == 64)`, `@as(u64,1)<<63` | `vector_len = detectVlen()`; literals via `lib.Mask(VLEN)` |
| `src/root.zig` | `computeBackslashRuns64` export | export generic `computeBackslashRuns`; keep alias |
| `test/root_test.zig` | parity at 64 only | width sweep |

Cross-section: Item 4 (Stage 2) is fully scalar over the index — no width
dependency. Item 5's resident-pad margin is VLEN-sensitive:
`SAFE_PAD = VLEN + @max(UTF8_MAX_TAIL, XML_LOOKAHEAD)`, from the same
`detectVlen()`, never exceeding today's 73 (VLEN ≤ 64).

### Scalar differential oracle at all 3 widths

The scalar oracles take `[]const u8` only — width-free — so they validate any
VLEN instantiation unchanged. Keep them; extend the sweep:

- `inline for (.{16, 32, 64}) |vlen| expectMatchesScalar(indexImpl(vlen,…), scalar(…))`
  over boundary corpora `{0,1,14,15,16,17,30,31,32,33,62,63,64,65,66}` + `@embedFile` corpus.
- `computeBackslashRuns` differential at u16/u32/u64 against the scalar
  run-parity oracle at cross-chunk offsets `{14..17}` and `{30..33}`.
- `extractBitIndexes` width typing: assert `@ctz` returns `Log2Int(T)` per width.
- Deterministic Smith fuzz stays input-sized, executes at the comptime VLEN.

---

## Item 4 — Stage 2 Structural Validation (implemented for seven formats)

`src/core/stage2.zig` owns the JSON-family parser, `Dialect`, tape, cursor, and
shared diagnostic. `Dialect` contains `.json`, `.jsonc`, and `.json5`.
Each JSON-family adapter runs its Stage 1 indexer and selects the matching
dialect. JSONL derives record spans from its Stage 1 index and uses `.json` for
each record. Markdown, XML, and YAML own format-local documents, tapes,
validators, errors, and diagnostics. They do not use the JSON `Dialect` or
JSON tape. YAML keeps a scalar oracle (`scalarIndexYaml`) that the SIMD
newline-indexed path must match at every supported width.

### JSON-family tape layout — `TapeWord` (64-bit packed, shared with Item 1)

The tape allocates at most one word per input byte. Absolute input offsets use
`u32`. The `u24` payload stores container counts, closing-word jump-back tape
indexes, and string lengths. Stage 2 returns `error.TapeTooLarge` before any
payload value greater than `std.math.maxInt(u24)` is stored. Inputs whose
offsets do not fit `u32` also return `error.TapeTooLarge`.

### Depth — `DepthEntry` / `DepthStack`

```zig
pub const max_depth: usize = 1024;

pub const DepthEntry = struct {
    is_array: bool,   // container kind on top (close-token match check)
    tape_index: u32,  // tape slot of the opening word (back-patch target)
    open_offset: u32, // input offset of the opening bracket (unclosed diagnostic)
    count: u32,       // elements/members seen so far
};

pub const DepthStack = struct {
    entries: [max_depth]DepthEntry,
    top: usize = 0,
    pub fn push(self: *DepthStack, e: DepthEntry) Error!void {
        if (self.top >= max_depth) return error.DepthExceeded;
        self.entries[self.top] = e;  self.top += 1;
    }
    pub fn pop(self: *DepthStack) DepthEntry {
        std.debug.assert(self.top > 0);
        self.top -= 1;  return self.entries[self.top];
    }
    pub fn peek(self: *DepthStack) *DepthEntry {
        std.debug.assert(self.top > 0);
        return &self.entries[self.top - 1];
    }
};
```

Fixed 1024-entry stack, zero heap, 16 KiB footprint on the caller's stack. RFC
8259 imposes no nesting limit — `max_depth = 1024` is a documented deviation,
simdjson-compatible. Per-level bitset rejected: `tape_index`/`count`/`open_offset`
are needed per level anyway.

### Tape back-patching

When a container closes, Stage 2 stores its element count in the opening word.
It stores the opening tape index in the closing word. The `u24` payload bound
applies to both values. `TapeCursor.skipValue()` scans and validates each word
in a forward subtree, so its cost is O(subtree). From a closing word,
`matchingStart()` uses the stored jump-back index in O(1).

### JSON-family error set (confirmed 12)

```zig
pub const Error = error{
    UnexpectedToken, UnclosedObject, UnclosedArray, InvalidNumber, InvalidEscape,
    TrailingComma, DuplicateKey, EmptyDocument, RootNotSingular,
    DepthExceeded, UnterminatedString, InvalidUtf8,
};
```

Explicit set, no `anyerror`. `OutOfMemory` is not semantic. Builders and
validators union allocation failure only at their public call sites. The
`DuplicateKey` enum member is reserved and is not emitted by current
validators. Policy: raw control bytes < 0x20 inside strings → `InvalidEscape`
(RFC 8259 §7); malformed literals (`tru`, `nulx`) → `UnexpectedToken` with
context `expected literal true/false/null`; `InvalidNumber` is reserved for
number grammar.

### Future roadmap: optional validation policies

- The current `u24` payload reports `TapeTooLarge` for a string longer than
  `std.math.maxInt(u24)` bytes. A wider payload or a continuation word could
  remove this bound.
- The BOM policy can become an explicit option. The current RFC JSON path does
  not expose such an option.
- Duplicate-key equality and escaped-key normalization need a defined policy
  before duplicate-key checking becomes a supported option.

### JSON-family `Diagnostic` — fail-fast, first error only

```zig
pub const Diagnostic = struct {
    err: Error,
    byte_offset: usize,   // absolute 0-based offset where the error was detected
    line: u32,            // 1-based, lazily computed by diagnosticAt()
    column: u32,          // 1-based byte column
    snippet: []const u8,  // zero-copy view INTO input, never an allocation
    snippet_start: usize, // absolute offset of snippet[0]
};
pub fn diagnosticAt(input: []const u8, err: Error, byte_offset: usize) Diagnostic
```

`diagnosticAt` scans back from `byte_offset` to the previous `\n` (O(offset),
paid only on the error path). Snippet =
`input[max(0,off-16) .. min(len,off+16)]` bounded by newlines, zero-copy.
Rendering (reusing `core/debug.zig` `printAscii`/`highlightMulti`) is a caller
concern. `UnclosedObject`/`UnclosedArray` point at the OPENING bracket
(`DepthEntry.open_offset`), not EOF.

### JSON-family state machine — 7 states

```zig
const Expect = enum(u3) {
    value_after_open,
    value_after_comma,
    key_after_open,
    key_after_comma,
    colon,
    value_after_colon,
    after_value,
};
```

The `.json` dialect implements the RFC 8259 grammar. The `.jsonc` dialect
permits line and block comments between JSON tokens. The `.json5` dialect adds
JSON5 keys, strings, numbers, whitespace, comments, and trailing commas while
it uses the same container state machine.

Transitions:
- `{`/`[`: emit an open word, push `DepthEntry`, then use
  `key_after_open` for an object or `value_after_open` for an array.
- A string or atom emits a word. A key moves to `colon`. A value moves to
  `after_value`. A root value sets `root_done`.
- `:` is valid only from `colon` and moves to `value_after_colon`.
- Empty containers close from `key_after_open` or `value_after_open` when
  their count is zero.
- `,` is valid only from `after_value` and moves to `value_after_comma` or
  `key_after_comma`.
- `]` and `}` close from the matching empty or `after_value` state. JSON5
  also closes from the matching comma state. Other states fail.
- EOF reports an unclosed container at its opening bracket. Empty input
  reports `EmptyDocument`. Trailing root input reports `RootNotSingular`.

### JSON-family number validation

The `.json` and `.jsonc` dialects use the RFC 8259 number grammar. Their atom
span is a maximal run of `[0-9 + - . e E]`. The next byte must be a delimiter
(`ws , ] } :`) or Stage 2 reports `UnexpectedToken`. The DFA rejects `01`,
`1.`, `.5`, `+1`, `1e`, `1e+`, `-`, and `--1`.

The `.json5` dialect accepts JSON5 decimal and hexadecimal numbers, leading
`+`, `Infinity`, and `NaN`. It also accepts leading or trailing decimal points
and JSON5 exponent forms. Stage 2 validates number syntax but does not convert
numeric values. Consumers can convert a valid span lazily. `TapeCursor`
exposes raw slices, so unread numbers are not converted.

### String and key validation

The `.json` and `.jsonc` dialects accept double-quoted strings with the RFC
8259 escape table. They reject raw control bytes below `0x20`. The `.json5`
dialect accepts single-quoted and double-quoted strings, JSON5 escapes, and
escaped line terminators. It also accepts validated JSON5 identifier names as
unquoted object keys. All three dialects validate string termination, Unicode
escapes, and UTF-8. Stage 2 does not decode strings, so `TapeCursor` returns
escaped raw views.

### Eager vs lazy (Item 4 verdict)

- **Eager at tape build:** structural validation, string extent scanning,
  escape and UTF-8 validation, and number syntax validation. This gives a
  sound-tape invariant and deterministic first-error diagnostics. The
  validate-only entry points in the support matrix return the first optional
  diagnostic without retaining a tape.
- **Lazy at consumption:** raw source views remain zero-copy. Numeric conversion
  and escape decoding belong to consumers and are not done for unread values.
- Cost: one extra byte walk per atom at build (~1–2 cycles/byte scalar), tape
  8 B/token vs 4 B index. Total memory is ≤ ~13× input in the worst case and
  typically 2–3×.
- **Future roadmap: duplicate keys.** `Error.DuplicateKey` reserves the error
  name, but the current API does not expose duplicate-key options. A later
  implementation can compare decoded keys and define duplicate-key policy.

### Future roadmap: error recovery

The current validator fails at the first `Diagnostic`. Recovery by scanning to
the next separator or matching close token remains future work.

### Current seven-format support matrix

| Format | Builder | Validator and diagnostic | Document and tape | Implemented grammar scope |
|---|---|---|---|---|
| JSON | `json.buildJsonTape(allocator, input) -> stage2.BuildError!stage2.Document` | `json.validateJson(allocator, input) -> stage2.ValidationError!?stage2.Diagnostic` | `stage2.Document` with `stage2.TapeWord` and `.json` | Strict RFC 8259 JSON |
| JSONC | `jsonc.buildJsoncTape(allocator, input) -> stage2.BuildError!stage2.Document` | `jsonc.validateJsonc(allocator, input) -> stage2.ValidationError!?stage2.Diagnostic` | `stage2.Document` with `stage2.TapeWord` and `.jsonc` | Strict JSON plus `//` and `/* ... */` comments. It accepts no other JSON5 syntax. |
| JSON5 | `json5.buildJson5Tape(allocator, input) -> stage2.BuildError!stage2.Document` | `json5.validateJson5(allocator, input) -> stage2.ValidationError!?stage2.Diagnostic` | `stage2.Document` with `stage2.TapeWord` and `.json5` | JSON5 grammar, including comments, single quotes, identifier keys, trailing commas, JSON5 numbers, whitespace, and escapes |
| JSONL | `jsonl.buildJsonlTape(allocator, input) -> stage2.BuildError!JsonlDocument` | `jsonl.validateJsonl(allocator, input) -> stage2.ValidationError!?JsonlDiagnostic` | `JsonlDocument` owns `JsonlRecord` metadata and one `stage2.Document` tape per record | Strict JSON for each nonblank record. A Stage 1-indexed LF outside strings ends a record. Blank and trailing records are skipped. |
| Markdown | `markdown.buildMarkdownTape(allocator, input) -> MarkdownBuildError!MarkdownDocument` | `markdown.validateMarkdown(allocator, input) -> MarkdownValidationError!?MarkdownDiagnostic` | Format-local `MarkdownDocument` with `MarkdownTapeWord` | Stage 1 token integrity for the Markdown marker stream. It is not CommonMark validation or a CommonMark AST. Marker spans are bounded by `u24`; source offsets remain `u32`. |
| XML | `xml.buildXmlTape(allocator, input) -> XmlBuildError!XmlDocument` | `xml.validateXml(input) -> XmlValidationError!?XmlDiagnostic` | Format-local `XmlDocument` with `XmlTapeWord` | The supported XML well-formedness subset covers one root, UTF-8 XML characters, names, attributes, built-in and numeric entities, comments, CDATA, processing instructions, and an XML 1.0 declaration. DTD and DOCTYPE declarations are unsupported. |
| YAML | `yaml.buildYamlTape(allocator, input) -> YamlBuildError!YamlDocument` | `yaml.validateYaml(allocator, input) -> YamlValidationError!?Failure` | Format-local `YamlDocument` with `YamlTapeWord` | The `yaml-basic-1.2.2` profile: block and flow collections, quoted and plain scalars, document markers, and comments. Anchors, tags, directives, and multiline block scalars are `Unsupported`. |

Markdown preserves these Stage 1 token kinds in its local tape: headings,
code fences, list items, blockquotes, inline code, link open and close
markers, and thematic breaks. XML accepts an XML declaration only with version
`1.0`, optional `UTF-8` encoding, and optional `yes` or `no` standalone values.

All six validators fail at the first format error and return `null` for valid
input. `stage2.Diagnostic` and `JsonlDiagnostic` use `stage2.Error`.
`MarkdownDiagnostic` uses `MarkdownError`. `XmlDiagnostic` uses `XmlError`.
All four diagnostic types contain an error, byte offset, line, column, snippet,
and snippet start. `JsonlDiagnostic` adds the record index and record source
bounds. Its byte, line, column, and snippet coordinates refer to the complete
JSONL input.

Each builder returns owned tape storage and borrows source bytes from the
caller. `JsonlDocument` keeps each record cursor inside its record source.
`MarkdownDocument` and `XmlDocument` are format-local token tapes. They are
not JSON documents, JSON tape cursors, or JSON DOMs.

---

## Item 5 — Streaming / Chunk-at-a-Time Input

### Implemented per-format baseline

Every format exposes a chunk-fed `StreamIndexer` with the public lifecycle
`init`, `feed`, `feedFrom`, `finish`, `take`, `reset`, and `deinit`. The JSON
indexer in `src/core/stream.zig` copies chunks through two fixed padded slots
and produces a `StructuralIndex`. The remaining formats retain only unfinished
lexical state plus output offsets; `take` transfers index storage to the
caller, and stream output matches the one-shot indexer under every partition.

`feedFrom` is an optional convenience adapter over `feed`:

```zig
pub fn feedFrom(
    self: *StreamIndexer,
    reader: *std.Io.Reader,
) FeedFromError!void;
```

It drains `reader.buffered()`, calls `feed` with each available slice, then
calls `reader.toss` only after `feed` succeeds. When no bytes are buffered it
calls `reader.fill(1)`. `error.EndOfStream` is normalized to `finish`; other
reader errors and all indexer errors propagate.

The adapter retains no `std.Io.Reader`, source slice, or reader buffer. The
reader object and its backing buffer must remain valid for the duration of the
`feedFrom` call. Each `feed` call borrows its input only until that call
returns because the indexer copies it into its resident padded slots. After
`feedFrom` returns, only the indexer's parser state and `StructuralIndex`
remain. `feedFrom` produces Stage 1 output only; Stage 2 and On-Demand still
require separate caller-owned complete input that outlives those consumers.

Stage 2 and On-Demand traversal still require separate caller-owned complete
input that outlives those consumers.

### General streaming reader boundary

For formats beyond JSON, the remaining goal is to feed arbitrarily large
documents through a reader, preserve format-specific state across arbitrary
boundaries, and match one-shot Stage 1 output for every supported format.

```zig
pub const CarryState = struct {
    // JSON / JSONL / JSONC / JSON5
    prev_in_string: bool = false,
    prev_ends_in_backslash: bool = false,
    prev_backslash_run_odd: bool = false,  // odd run of backslashes = escaped
    prev_in_atom: bool = false,
    string_quote: u8 = 0,                  // 0x22 '"' or 0x27 '\''
    comment_state: CommentState = .none,   // .none | .line | .block | .multiline_string
    // Markdown
    prev_was_blank: bool = false,
    prev_was_fence: bool = false,
    fence_char: u8 = 0,  fence_len: u8 = 0,
    in_fenced_code: bool = false,
    // XML
    tag_state: TagState = .none,           // .none | .lt_seen | .name_start | .in_name | .in_quote
    in_comment: bool = false,  in_cdata: bool = false,  in_doctype: bool = false,
    markup_quote: u8 = 0,
};
```

Rules: every field has a derived "incomplete" meaning — assessors
(`is_in_string()`, `is_in_comment()`, `is_in_atom()`) return `true` whenever the
document is mid-construct and would be invalid if the stream ended there; this
is how `finish()` reports truncation identically to the one-shot path. A chunk
boundary is only legal where no field needs lookahead; the margin (below) keeps
the needed bytes resident. `reset()` zeroes wholesale
(`*std.mem.zeroes(CarryState)`).

### Future `StreamIndexer` expansion (Model B: padded double buffer)

```zig
pub const StreamIndexer = struct {
    allocator: std.mem.Allocator,
    buf: []u8,                 // 2 * chunk_len + 2 * max_margin
    fill: usize = 0,           // bytes consumed into buf[0..fill] awaiting data
    carry: CarryState = .{},
    index: StructuralIndex,    // grows without bound
    pub fn init(allocator: std.mem.Allocator, chunk_len: usize) !StreamIndexer;
    pub fn deinit(self: *StreamIndexer) void;
    pub fn feed(self: *StreamIndexer, data: []const u8) FeedError!void;
    pub fn finish(self: *StreamIndexer) !void;        // flush carry, finalize
    pub fn reset(self: *StreamIndexer) void;          // back to empty document
    pub fn take(self: *StreamIndexer) StructuralIndex; // move index out (zero-copy)
};
```

- `feed` appends `data` up to the safe boundary `carve`, runs one Stage 1 pass
  over `buf[0..carve]` with normalized end-of-window carry, saves `carry`, moves
  the unprocessed `buf[carve..fill]` (plus margin) to the front, marks `fill`.
- `feed` is explicit-allocator only; `buf` allocated once in `init`, reused —
  steady-state `feed` performs zero buffer allocations. Only `index` growth
  allocates.
- `finish` is idempotent-safe, reports `error.Truncated` iff the last byte
  leaves any carry flag set, processes the final under-margin tail, finalizes.
- `reset` re-zeroes `fill`/`carry`, clears `index`, keeps `init` allocations;
  supports `take() + reset()` for multi-document streams.

### Margin math and minimum constants

```zig
pub const MAX_SIMD_WINDOW: usize = 64;
pub const UTF8_MAX_TAIL: usize = 3;   // max continuation bytes of one trailing codepoint
pub const XML_LOOKAHEAD: usize = 9;   // longest markup prefix "<![CDATA[" is 9
// VLEN = runtime-selected width (Item 3):
//   MIN_RUNNING_MARGIN = VLEN + UTF8_MAX_TAIL        // 67 at VLEN = 64
//   MIN_PADDED_MARGIN  = VLEN + XML_LOOKAHEAD        // 73 at VLEN = 64
//   SAFE_PAD = @max(MIN_RUNNING_MARGIN, MIN_PADDED_MARGIN)
// Worst-case SAFE_PAD = 73 (VLEN = 64); buffer sized for worst case so one
// allocation serves any dispatched width.
// Guarantee: carve <= fill, carve + SAFE_PAD <= buf.len - SIMD_WINDOW
```

Model B keeps at least `SAFE_PAD` unprocessed bytes in the buffer head between
`feed` calls, and pads the buffer end with `SAFE_PAD` zeros so the kernel's
final window load is always in-bounds. `carve` is the largest index
`<= fill - SAFE_PAD` not inside a carry construct, on a codepoint boundary.

### Alternative models (documented, rejected or demoted)

- **Model A** — simdjson-style document-boundary batches (kept as
  `DocumentStreamIndexer` facade for JSONL/NDJSON): each document/line is an
  independent one-shot pass, fresh `StructuralIndex`, caller concatenates. No
  cross-batch carry (document boundary = natural reset). Cannot split a single
  value mid-document; per-document `init` cost. Wraps Model B + `finish()/reset()`.
- **Model C** — JSONL delimiter hold-back on `\n` (rejected): hold back the last
  complete line, buffer the partial tail. Doubles worst-case memory for a
  pathological single line; defers all output until a delimiter; strictly worse
  than Model B's margin. Adopted only as the trivially-reusable special case
  inside `DocumentStreamIndexer` when a trailing `\n` exists.

### StructuralIndex growth: unmanaged ArrayList(u32)

```zig
pub const StructuralIndex = struct {
    events: std.ArrayListUnmanaged(u32) = .{}, // element kind + length
    locs:   std.ArrayListUnmanaged(u64) = .{}, // absolute offsets into the document
    arena:  std.heap.ArenaAllocator,           // string/atom payloads
};
```

`ArrayListUnmanaged` (Zig 0.16 default) holds capacity externally; the indexer
passes an allocator only on growth. `u32` records keep hot cost at 4 B; offsets
are `u64` in a parallel cold `locs` vec. Growth amortizes (`ensureTotalCapacity`
by chunk); the arena grows by the same chunk so per-chunk `feed` does one or
zero allocator calls. The one-shot path becomes Model B with a single `feed`,
refactored to the same backing stores so streaming and batch never fork.

### Seven chunk-transition invariants

1. **Byte identity.** Concatenating every chunk equals the input; no byte
   dropped/duplicated/reordered. Exact `fill`/`carve` bookkeeping.
2. **Codepoint alignment.** A chunk boundary never lands mid-codepoint; `carve`
   trims up to `UTF8_MAX_TAIL`; `feed` moves offending bytes to the head.
3. **Carry completeness.** After `buf[0..carve]`, `carry` fully describes state
   at `carve`; every crossing construct is in exactly one carry field.
4. **No fabricated reads.** The kernel never reads beyond `carve + SAFE_PAD`;
   padding never interpreted as content.
5. **Lookahead residency.** Every lookahead construct (XML prefix, escape
   parity, comment opener) has its full lookahead resident before `carve`.
6. **Idempotent boundary.** `buf[0..carve]` then `carve..` yields byte-identical
   events to a one-shot pass over the same bytes; `finish` never re-emits/drops.
   Goldens differ byte-for-byte.
7. **Termination parity.** `feed + finish` on any sequence equals the one-shot
   indexer on that sequence, including truncation: `error.Truncated` iff `carry`
   non-empty at end-of-stream.

### `std.Io.Reader` integration boundary

`std.Io.Reader` is the Zig 0.16 non-generic, vtable-backed reader interface.
`StreamIndexer.feedFrom` uses only its `buffered`, `fill`, and `toss` methods:

- Drain `reader.buffered()` and pass each returned slice to `feed`.
- Call `reader.toss(buffered.len)` only after that `feed` call succeeds.
- When no bytes are buffered, call `reader.fill(1)` to request progress.
- Normalize `error.EndOfStream` from `fill` to `finish`.
- Propagate `error.ReadFailed` and all `feed`/`finish` errors unchanged.

`feed` remains buffer-only, so tests and callers can supply synthetic chunks
without a real I/O source. `feedFrom` does not store the reader or its buffer;
the reader and its backing storage need only live through that call. The
resulting Stage 1 index does not retain source bytes. Stage 2 and On-Demand
therefore still require independent complete input owned by the caller.

---

## Current cross-cutting decisions

1. Strict JSON and JSONL Stage 1 index unescaped double-quote string openings.
   JSONC and JSON5 suppress quote positions, so Stage 2 scans their strings
   from the source. All Stage 1 indexers write `(len, len, 0)` sentinel padding.
2. `simd.default_vector_len` is the current vector-width source for the seven
   Stage 1 indexers. Scalar oracles stay width-free and validate every
   instantiation; YAML additionally sweeps widths 4 through 64.
3. JSON, JSONC, and JSON5 use `stage2.Document` with a core-owned `Dialect`.
4. JSONL uses Stage 1-indexed LF boundaries outside strings. Each nonblank
   record owns an independent strict JSON tape.
5. Markdown, XML, and YAML use format-local documents and tapes, not JSON DOMs.
6. Every on-demand reader consumes complete resident input through parser-owned
   reusable state under a single-focus lease. Failed peeks are sticky; copied
   documents cannot claim a second focus on shared state.
7. Streaming ends at index production; `feedFrom` is only an input adapter and
   does not make Stage 2 or on-demand cursors source-safe.
8. The `feedFrom` reader and its backing storage are caller-owned for the
   duration of the call only; the indexer retains parser state and indexes, not
   source bytes.

## Current reference-guided API additions

- `json_value.decodeString` decodes into caller-owned storage. It validates
  before writing and rejects overlapping source and output buffers.
  `json_value.parseNumber` returns the original source span and a typed
  `NumberValue`; it does not change strict JSON number grammar.
- `formats.jsonl.TapeRecordParser` retains reusable index and record-tape
  storage. Its active iterator borrows the complete source. Advancing or
  releasing the iterator, or resetting the parser, invalidates prior records
  and cursors.
  This API is separate from the eager document that owns all record tapes.
- XML text, CDATA, and attribute events expose checked `decodedLength` and
  `decodeInto` operations. `XmlDeclarationInfo` borrows declaration values;
  `XmlQName` splits lexical names without resolving namespaces. The parser
  remains UTF-8-only: declaration inspection is not a transcoder.
- `formats.yaml` retains `yaml-basic-1.2.2`. The opt-in
  `formats.yaml_extended` module implements `yaml-extended-e2b`: literal and
  folded block scalars, multiline quotes, and compact sequence mappings.
  Its document owns tape, metadata, and cooked bytes and borrows source bytes.
  `Limits` applies to both basic and extended syntax. Collection depth can be
  lowered from the shared 1024 limit, not raised. A quoted scalar's opening
  line counts toward its scalar-line limit; block headers and terminal line
  sentinels do not. Aliases, anchors, tags, complex keys, directives, multiple
  documents, schema resolution, and streaming remain outside this profile.
- `formats.commonmark` is a separate CommonMark 0.31.2 semantic parser, not
  an extension of the marker-only `formats.markdown` tape. Its flat document
  owns nodes and semantic text and borrows source bytes. Parsing has explicit
  input, node, text, delimiter, bracket, reference, depth, and work limits.
  More than 64 prefixes on one line returns `NestingTooDeep`. Rendering bounds
  output bytes and rejects malformed traversal links. Default safe rendering
  omits raw HTML and filters dangerous URL schemes, including autolinks and
  schemes containing browser-stripped controls. Conformance rendering is
  intentionally unsafe; the caller owns the trust or sanitization boundary.

`zig build commonmark` runs all 652 pinned examples without exclusions and
the ownership, safety, and resource regressions. `zig build corpus` includes
this suite. The YAML extension regressions run through `zig build test`.

## Future roadmap

1. Error recovery: validators fail at the first diagnostic; recovery by
   scanning to the next separator or matching close token remains future work.
2. Keep `std.Io.Reader` integration as an optional adapter without presenting
   pull events as an input streaming API.
3. Define how chunked source storage outlives Stage 2 or On-Demand cursors
   before those APIs consume streamed input.
4. Define wider tape payloads if values beyond the `u24` bound are required.
