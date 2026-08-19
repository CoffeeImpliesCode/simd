# simd — Stage 2, Streaming, On-Demand Architecture Plan

Status: research + synthesis complete (Items 1, 3, 4, 5). No code changed.
Scope: plan only. Each section is independently implementable; Item 1 and
Item 4 share one Stage-1 contract and must land together.

Grounded in: `papers/1902.08318_parsing_gigabytes_of_json_per_second.pdf`,
`papers/2312.17149_on_demand_json.pdf`,
`~/projects/github-simdjson-simdjson/doc/ondemand_design.md`, simdjson
`json_scanner.h` / `json_structural_indexer.h` / tape design, RFC 8259, and the
current repo (`src/core/simd.zig`, `src/core/stage1.zig`, `src/formats/*`).

Current state: Stage 1 SIMD indexers for JSON/JSONL/JSONC/JSON5/Markdown/XML
(all 64-byte hardwired), one-shot `[]const u8` → `StructuralIndex`. No Stage 2,
no tape, no on-demand cursor, no streaming layer.

---

## Item 1 — On-Demand Event Interface

### Model: pull-based On-Demand cursor over `Stage1.StructuralIndex`

Recommended front-end: a zero-alloc pull cursor over the Stage 1 index,
mirroring simdjson On-Demand's `json_iterator`/`value_iterator` (2023 paper:
5.1 instr/byte geomean, ~70% faster than a DOM tape, up to 8.7 GiB/s on
field-heavy queries). The cursor is the core; a zero-alloc `EventReader`
(pull-SAX) is a thin adapter for streaming; the 64-bit tape (Item 4) remains
the optional DOM layer for random access.

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
    kind: TapeKind,   // 8 bits
    payload: u24,     // 24 bits: element count | jump-back | string length
    offset: u32,      // 32 bits: absolute input offset
};
comptime { std.debug.assert(@bitSizeOf(TapeWord) == 64); }
```

Container back-patch: tape slots are append-only, so patch targets are stable;
every back-patch is one store. On open, emit `{kind=open, payload=0}` and push
a depth entry recording tape index + opening offset. On close, emit
`{kind=close, payload=tape_index_of_open}` (jump-back), then patch the open
word in place: `tape[open].payload = element_count`. Effect: open word → O(1)
container skip via jump-back; close word → O(1) jump to matching open. `:` and
`,` never appear on the tape.

### Zero-alloc `EventReader` pull-adapter (SAX/streaming)

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

### Stage 1 extension requirement (index ↔ cursor bridge)

Current Stage 1 indexes structural chars and atom starts but NOT string-opening
quotes. Without them no parser can find keys/string values from the index.
Mirror simdjson `json_scanner.h` (opening quotes are pseudo-structural; closing
quotes are not — `structural_start & ~string_tail`):

```zig
const string_start_quotes = unescaped_quotes & inside_without_closing;
const structural_indexes = (structural | atom_starts | string_start_quotes) & outside_string;
```

One-line delta to the existing `structural_indexes` expression in
`src/formats/json.zig` (and `jsonl.zig`); all four mask variables already exist.

**Sentinel padding (mandatory, mirrors simdjson `json_structural_indexer.h`).**
After stage 1 finishes, write three sentinel entries: `indexes[n] = len;
indexes[n+1] = len; indexes[n+2] = 0`. Effects: `peekLength` on the last real
token is well-defined; EOF detection is exact; `skipChild` is bounds-checked.
Requires `StructuralIndex.init` to allocate `max_capacity + 3` and the indexers
to fill sentinels at the end of their last window.

> Coordination note: this supersedes the "quotes NOT indexed" assumption in the
> Item 4 draft (tape string offsets become `opening quote` from the index
> instead of a validator re-scan). Items 1 and 4 MUST share one Stage-1
> contract; the merged design resolves which section is authoritative.

### Performance: locality, allocation, DOM crossover

| Property | On-Demand cursor | EventReader | DOM tape (Item 4) |
|---|---|---|---|
| Heap allocs per doc | 0 (scratch reused) | 0 | index + tape + string buffer |
| Per-token working set | 4 B index + 1 input byte | same | index + 8 B tape word |
| Skip cost | O(sub-tree), depth counter | same | O(1) jump-back |
| Convert cost | only on `get_*` | only on `.get()` | eager at build |
| Random access | rewind + re-scan | no | yes (O(1) container skip) |

DOM tape wins for: many point queries, repeated reads of the same nested value,
retaining the tree after the input buffer is mutated. On-demand wins for:
single-pass streaming, partial reads, format conversion, memory-constrained
hosts, skip-heavy traversals. Numbers nobody reads are never converted.

---

## Item 3 — Vector-Width Dispatch (16/32/64 bytes)

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

### Adaptation inventory

| File | Today (64-hardwired) | Change |
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

## Item 4 — Stage 2 Structural Validation (`src/core/stage2.zig`)

New module, exported from `src/root.zig` as `stage2` (follows `stage1`;
`root_test.zig` extends `refAllDecls`). Consumes the Stage 1 `StructuralIndex`
as a cursor, produces a validated tape. Stage 2 drives the scan from the index
but reads input bytes directly for strings/atom interiors, asserting index
consistency at each token (`assert(index[i] == pos)`); invisible garbage bytes
Stage 1 skipped are caught here as `UnexpectedToken` at the exact byte.

### Tape layout — `TapeWord` (64-bit packed, shared with Item 1)

Capacity = `input.len` words (one token max per byte, matching `StructuralIndex`
capacity precedent). Open-container element counts and jump-back tape indexes are
< `input.len` ≤ 2^32; both fit. The u24 payload caps a single string at 16 MiB.

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

On close of container `e = depth.pop()`:
`tape[e.tape_index].payload = e.count` (open ← element count);
`tape[tape_count] = {.kind = end, .payload = @intCast(e.tape_index), .offset = close_pos}`
(close ← jump-back). The close word carries the jump-back so Stage 3 skips a
container in O(1).

### Error set (confirmed 12)

```zig
pub const Error = error{
    UnexpectedToken, UnclosedObject, UnclosedArray, InvalidNumber, InvalidEscape,
    TrailingComma, DuplicateKey, EmptyDocument, RootNotSingular,
    DepthExceeded, UnterminatedString, InvalidUtf8,
};
```

Explicit set, no `anyerror`. `OutOfMemory` is not semantic; unioned at call
sites only where the option-gated duplicate-key map allocates. Policy: raw
control bytes < 0x20 inside strings → `InvalidEscape` (RFC 8259 §7); malformed
literals (`tru`, `nulx`) → `UnexpectedToken` with context
`expected literal true/false/null`; `InvalidNumber` reserved for number-grammar.

**Open decisions for Main:**
- `StringTooLong`: u24 caps one string at 16 MiB. If longer strings must be
  supported: add `StringTooLong` as a 13th error, or spill length to a second
  tape word.
- BOM policy: accept+skip leading UTF-8 BOM (`EF BB BF`) or reject as
  `UnexpectedToken`. RFC 8259 permits either.
- Duplicate-key equality is raw-byte in v1 (`"a"` vs `"\u0061"` not detected);
  escaped-key unescaping is a later refinement.

### `Diagnostic` — fail-fast, first error only

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
paid only on the error path, memoized per validator). Snippet =
`input[max(0,off-16) .. min(len,off+16)]` bounded by newlines, zero-copy.
Rendering (reusing `core/debug.zig` `printAscii`/`highlightMulti`) is a caller
concern. `UnclosedObject`/`UnclosedArray` point at the OPENING bracket
(`DepthEntry.open_offset`), not EOF.

### RFC 8259 state machine — 6 states

```zig
const Expect = enum(u3) { value_after_open, value_after_comma, key_after_open, key_after_comma, colon, after_value };
```

Transitions:
- `{`/`[`: emit open word (payload 0), push `DepthEntry`, state →
  `key_after_open` (obj) / `value_after_open` (arr).
- string/atom: emit word; state → `colon` (key in obj) / `after_value` (value);
  `peek().count += 1`; at root → `root_done = true`.
- `:`: only from `colon` → `value_after_open`; close-token check is top-entry
  matches token (`]` on object top → `UnexpectedToken`), so post-colon values
  are sound.
- Empty container: `[`→`]` valid only from `value_after_open` with `count == 0`;
  `{`→`}` only from `key_after_open` with `count == 0`.
- `,`: only from `after_value` → `value_after_comma` / `key_after_comma`; else
  `UnexpectedToken`.
- `]`: valid from `value_after_open` (empty) or `after_value`; from
  `value_after_comma` → `TrailingComma`. `}` analogously. Mismatched closer or
  empty stack: `root_done ? RootNotSingular : UnexpectedToken`.
- EOF: `depth.top > 0` → `UnclosedArray`/`UnclosedObject` (at `open_offset`);
  no non-whitespace consumed → `EmptyDocument`; `root_done` with trailing bytes
  → `RootNotSingular` at first trailing token.

### Number validation (RFC 8259 §6)

Atom span = maximal run of `[0-9 + - . e E]`; the byte after MUST be a delimiter
(`ws , ] } :`) else `UnexpectedToken` at that byte (catches `1a`). DFA rejects
`01`, `1.`, `.5`, `+1`, `1e`, `1e+`, `-`, `--1`; accepts RFC-valid numbers.
Conversion is strictly lazy (Stage 3): span without `.`/`e`/`E` →
`std.fmt.parseInt(i64, atom, 10)`; else `std.fmt.parseFloat(f64, atom)`.
`parseFloat`'s accepted superset is unreachable (DFA ran first); `1e400`
(grammar-valid) → `error.Overflow` at iteration, never at validation. Numbers
nobody reads are never converted.

### String validation

Scalar scan from `q+1`: `\` → escape table (`" \ / b f n r t` → advance 2; `u`
→ exactly 4 hex digits via `std.fmt.charToDigit` else `InvalidEscape`); `"` →
close; byte < 0x20 → `InvalidEscape`; `i == input.len` → `UnterminatedString` at
`q`. UTF-8: `std.unicode.utf8ValidateSlice(content)` else `InvalidUtf8` (first
invalid byte via `Utf8Iterator`). Escape bytes are ASCII so validating raw
content is correct; `\uD8xx\uDCxx` surrogate pairs stay literal text at Stage 2,
unpaired surrogates fail only at Stage 3 decode (flagged).

### Eager vs lazy (Item 4 verdict)

- **Eager at tape build:** structural validation (bracket matching, colon/comma
  placement, counts/jumps); string EXTENT scanning (length lives in the tape
  word); escape/UTF-8/number-SYNTAX validation. Payoff: sound-tape invariant,
  deterministic first-error diagnostics, a validate-only entry point
  (`validateJson` = Stage 1 + 2, tape discarded).
- **Lazy at iteration:** numeric VALUE conversion and surrogate decoding.
- Cost: one extra byte walk per atom at build (~1–2 cycles/byte scalar), tape
  8 B/token vs 4 B index; total memory ≤ ~13× input worst case, typically 2–3×.
- **Duplicate keys** (option-gated): `ValidateOptions { check_duplicate_keys:
  bool = false, max_string_length: u32 = 16 MiB }`. When enabled: open-addressing
  set of FNV-1a-64 hashes over raw key content per open object (pow2 ≥ 2×members,
  doubling at load 0.5, freed at close); hash+length match → byte compare →
  `DuplicateKey` at second key's quote. Disabled → zero cost.

### Error recovery

v1 = fail-fast with a single `Diagnostic` (simdjson-style). Recovery mode
(re-scan to next `,`/close at same depth) is out of v1 scope.

### Wiring & verification

- `src/root.zig`: `pub const stage2 = @import("core/stage2.zig");` + `refAllDecls`.
- `src/formats/json.zig`: `buildJsonTape(allocator, input)` = `indexJson` +
  `stage2.buildTape`; `validateJson(input)` → first `Diagnostic`.
- `src/formats/jsonl.zig`: `validateJsonl` — records split on indexed `\n`
  (`\r\n` handled), empty/whitespace-only records skipped, absolute diagnostics.
- `build.zig`: unchanged (existing `zig build test` runs lib + exe + Smith fuzz).
- Verification: scalar reference twin; Smith differential fuzz (accept/reject
  agreement + tape invariants: open-word count == elements walked, close-word
  jump-back == open tape index, string offsets monotone); error-set comptime
  sweep (`inline for` over `@typeInfo(Error)`); depth 1024/1025 boundaries;
  grammar tables (number DFA, escapes, `\uXXXX`, raw control bytes, Unicode,
  dup-key on/off, BOM); corpus goldens (twitter.json / example_config.json);
  `refAllDecls`.

---

## Item 5 — Streaming / Chunk-at-a-Time Reader

### Goal

Feed arbitrarily large documents in chunks split at arbitrary byte boundaries,
getting identical structural output to the one-shot path, growing the index
without bound.

### `CarryState`: unified cross-chunk tokenizer state

Today each indexer scatters per-format tokenizer state in locals over one pass.
Streaming splits that pass; any state surviving a chunk boundary is collected
into one struct.

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

### `StreamIndexer` API (Model B: padded double buffer)

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

### Zig 0.16 `std.Io.Reader` integration (non-generic)

Use `std.Io.Reader` (Io-instance world; non-generic, vtable-backed — do not
implement per-stream generic `Reader` types):
- `reader.buffer(size)` → `[]u8` for zero-copy chunk fill.
- `reader.fill(want)` guarantees `want` bytes (blocks short reads), tops up the
  margin before `carve`.
- `reader.seek(advance)` / `reader.pos` → forward-only consumption mapping onto
  `buf.toss(n)` + `fill(buf.resolve(n))`.
- `reader.takeDelimiter(allocator, delim)` → Model C/JSONL line path.
- `reader.end` (eof) terminates `finish`.
- A `StreamIndexer` takes a `std.Io.Reader` in a `feedFrom` helper; `feed` stays
  buffer-only so tests feed synthetic chunks without a real I/O source.
- NixOS: avoid `std.c`-backed reads in the hot loop; one `read` per `feed`.

---

## Cross-cutting decisions for Main

1. **Item 1 ↔ Item 4 shared Stage-1 contract.** Stage 1 must index string
   opening quotes AND write `(len, len, 0)` sentinel padding. This supersedes
   "quotes NOT indexed" in the Item 4 draft. Land Items 1 and 4 together or
   sequence 4 then 1 with the contract fixed first.
2. **`StringTooLong` (13th error) / BOM policy / raw-byte dup-key equality** —
   three open decisions gated on corpus/streaming needs (Item 4).
3. **`detectVlen()`** is the single source of truth for width across indexers,
   `main`, and the streaming margin (Item 3 ↔ Item 5).
4. **No native `--fuzz`** — the deterministic Smith harness is the fuzz path
   (upstream Zig 0.16 `--fuzz` runner is broken; already worked around).

## Proposed implementation order

1. **Item 3 (vector width)** — self-contained, no contract coupling, enables
   Item 5's VLEN-aware margin. Lowest risk, do first.
2. **Item 4 (Stage 2 validation)** — scalar over the index, independent of
   width. Establishes the tape + depth + error/diagnostic surface.
3. **Item 1 (on-demand cursor + EventReader)** — depends on Item 4's tape and
   on the Stage-1 quote/sentinel contract. Requires the Stage-1 extension.
4. **Item 5 (streaming)** — depends on Item 3 (VLEN margin) and Item 1
   (DocumentStreamIndexer facade).

Each step lands as its own atomic commit, green (fmt + Debug/ReleaseSafe test +
Smith fuzz) before the next.
