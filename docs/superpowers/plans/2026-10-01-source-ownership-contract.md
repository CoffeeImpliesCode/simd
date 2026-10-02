# Source Ownership and Resource Contract: Design Record

Phase 4 design record. This document selects a source-lifetime and resource
contract for the library, derived from what callers actually need. It records a
decision; it implements nothing. Every current-state claim below was re-read
from the tree on 2026-10-01 and carries a file and line. Where the supplied
evidence base disagreed with the tree, the tree won and the disagreement is
named in **Corrections to the supplied evidence base**.

Labels used throughout:

- **Enforced today** — the code checks it.
- **Documented, not enforced** — the code documents it and checks nothing.
- **Proposed** — not implemented; this record only argues for it.

---

## 1. Decision

The library adopts a **recorded-borrow** contract: every document type that can
hand out a slice of source bytes records that source once, at build time, as a
`(ptr, len)` identity; no public accessor takes a source argument, so pairing a
document with the wrong bytes is unrepresentable rather than merely detectable;
every derived cursor and value carries the lease and generation of the storage
it reads; and the ownership of any returned slice is one of three named kinds —
document-owned, parser-owned reusable, or caller source. This extends to the
whole tree the identity check that only the format-local documents perform
today, and unifies the two vocabularies — the shared `resident` lease and the
independently reimplemented JSON on-demand lease — into one exported one.

Nothing in this record is implemented. Every clause in section 4 that is not
labelled **Enforced today** is a proposal.

---

## 2. Consumer requirements

These are what a caller must be able to do without reading the library source.

**R1 — Pair a derived cursor with the bytes that built it, or be told no.**
Given a document and a source buffer, the caller must learn whether the pairing
is valid *before* reading any byte through the result. Today the JSON-family
Stage 2 path cannot do this: `Document.root` stores no source and performs no
identity check (`src/core/stage2.zig:66-83`, **Documented, not enforced**).
`test/root_test.zig:711-715` shows the only detection that exists: a document
built from `"value"` paired with `"x"` fails at read time with
`SourceOutOfBounds` because offset 1 is out of range for a 3-byte buffer, and
paired with `"valuex"` fails with `InvalidSource` because the escape shape is
wrong. Both are shape accidents. A mismatched source of the same length whose
bytes satisfy the same per-token shape checks is not detected, and the caller
reads the wrong bytes with no signal.

**R2 — Hold a derived cursor across a reset, a reuse, or a deinit and get a
defined error.** Not a stale read, not undefined behavior, not a parse
result from the previous document. The reusable JSONL record path already
achieves this (**Enforced today**, `src/formats/jsonl.zig:364-373`,
`test/jsonl_record_tape_test.zig:184-206`). The JSON on-demand path achieves
it under a second, separately named error vocabulary
(`src/core/ondemand.zig:18`, `:355-362`, `:471-475`). The Stage 2 tape cursor
achieves it not at all: a `TapeCursor` is a plain value
(`src/core/stage2.zig:110-114`) with no lease and no generation.

**R3 — Know, for any `[]const u8` the library returns, which storage it points
into.** Three cases exist today and are not named consistently:
document-owned (`yaml_extended.Document.cooked`,
`src/formats/yaml_extended.zig:119`; CommonMark's normalized text at
`src/formats/commonmark.zig:160`); parser-owned reusable (the JSONL high-water
tape at `src/formats/jsonl.zig:242`, recycled by `TapeReuseAllocator` at
`:454-508`, and the on-demand parser's index array at
`src/core/ondemand.zig:47`); and caller source (`stage2.TapeCursor.rawValue`,
`src/core/stage2.zig:173`). Only the extended YAML value path names the
distinction (`src/formats/yaml_extended.zig:30-33`, `:80-91`).

**R4 — Not observe a public type whose defining module the root does not
export.** Today 25 public struct fields, 3 public error sets, and 2 public type
aliases name types from non-exported modules (section 5.3). A caller cannot
name the type of `jsonl.TapeRecord.lease` through any path the library exports.

**R5 — One lease vocabulary across all nine parser families.** Of the nine,
four route through `core/resident.zig` — `jsonl`, `markdown`, `xml`, and
`yaml` — and three share `core/ondemand.zig`: `json`, `jsonc`, and `json5`
(`src/formats/json.zig:54-61`, `jsonc.zig:51`, `json5.zig:51`, all delegating
to the same `ondemand.Parser`). The remaining two, `commonmark` and
`yaml_extended`, expose no reader at all. The three JSON-family formats reach
the shared module only by not using it: `core/ondemand.zig` re-implements the
lease and generation rule inline
(`src/core/ondemand.zig:51-53`, `:210-212`, `:276-285`) and declares
`error.FocusLost` (`:18`), a name that exists nowhere else in the tree.

**R6 — Decode into caller-owned output without the output aliasing what is
read, with one stated check order and no partial write.** The two decoders
disagree on both points (section 5.6).

**R7 — Keep a structural index after releasing the source, and know that doing
so does not produce a document.** A `stage1.StructuralIndex` owns only `u32`
offsets and borrows nothing (`src/core/stage1.zig:5-56`); `feed` copies into
padded slots and borrows only for the call (`src/core/stream.zig:160-194`,
`:195-214`); `take` hands the index over (`:234-243`). That boundary is sound
today. It is not stated as a rule, and nothing stops a caller from treating an
index as a document.

---

## 3. Alternatives considered

Four interface shapes for expressing source lifetime and resource ownership.
Each is a real design, not a strawman.

### 3.1 Alternative A — Recorded identity, accessors keep their source argument

Add `source: []const u8` to `stage2.Document`, record it in
`buildTape`/`buildTapeView`, and have `Document.root(input)` compare
`(input.ptr, input.len)` against the recorded value, returning the format's
existing mismatch error. Extend the same treatment to `CommonMarkDocument`,
which stores a source slice today and compares it in no accessor
(**Documented, not enforced**, `src/formats/commonmark.zig:157`, `:171-199`).

*What it costs.* One `u32`-pair compare per accessor call on the Stage 2 path,
which `rawValue` and `matchingStart` call per token. One extra field per
document. Every `stage2.Document.root(input)` call site in the tree must then
pass a source that is already the right one. The census, from
`grep -rnE "\.root\(" src test bench.zig scripts`, is 89 sites, 35 of them
Stage 2: 16 in `src/core/stage2.zig` tests
(`:2401`, `:2437`, `:2796`, `:2832`, `:2871`, `:2912`, `:2928`, `:2963`,
`:2990`, `:3002`, `:3009`, `:3016`, `:3025`, `:3033`, `:3043`, `:3052`, all
below the first `test` at `:2267`); 3 in the JSON-family format tests
(`src/formats/json.zig:878`, `jsonc.zig:350`, `json5.zig:380`); 2 in
`test/checking.zig` (`:184`, `:214`); 11 in `test/root_test.zig`
(`:199`, `:238`, `:271`, `:657`, `:711`, `:714`, `:723`, `:731`, `:742`,
`:760`, `:784`); 1 in `bench.zig:437`; and the two production `stage2` callers
(`src/formats/jsonl.zig:30` and `:526`). The other 54 sites call another
format's `root`: 33 pass a source — Markdown (`src/formats/markdown.zig:944`,
`:2501`, `:2503`, `:2509`, `:2512`, `:2591`), XML (`src/formats/xml.zig:4250`,
`:4253`, `:4260`, `:4577`, `:4655`, `:4662`; `test/xml_value_views_test.zig:50`,
`:93`, `:112`, `:139`, `:172`, `:187`, `:203`, `:225`, `:251`, `:257`), and
YAML (`src/formats/yaml.zig:2823`, `:2949`, `:2957`, `:3147`, `:3314`, `:3318`,
`:3323`, `:3458`; `test/checking.zig:238`; `test/root_test.zig:562`;
`bench.zig:526`) — and 21 take none and route through one that does
(`src/formats/jsonl.zig:34`, `:61`, `:536`, `:1677`, `:1725`, `:1729`, `:1731`;
`test/jsonl_record_tape_test.zig:39`, `:40`, `:133`, `:180`, `:195`, `:204`,
`:213`, `:275`, `:316`; `test/root_test.zig:328`, `:429`; `bench.zig:465`;
`scripts/commonmark_bench.zig:151`, `:185`). The three format-local
`sourceSpan` accessors (`src/formats/markdown.zig:939`,
`src/formats/xml.zig:1584`, `src/formats/yaml.zig:203`) take that same
argument; only the Markdown one reaches a `root` (`:944`), while the XML and
YAML ones read the word inline (`:1589`, `:212`).

*What it breaks.* `src/formats/jsonl.zig:525-526` constructs a fresh
`stage2.Document` per record from `tape_storage` and immediately calls
`root(self.source)`; the new field must be filled there or the struct literal
fails. `test/root_test.zig:711-715` currently asserts a *read-time* error
(`SourceOutOfBounds`, then `InvalidSource`) for a wrong source; with a
construction-time or root-time identity check the same test would get
`SourceOutOfBounds` from `root` itself, so the test must be rewritten, not
merely extended. The `Document` struct literal is public, so external
construction sites break.

*Why it was not chosen.* It leaves the mispairing expressible. The caller can
still hand `root` the wrong buffer; the library only answers "no" instead of
"yes, and here are the wrong bytes." Every future accessor re-implements the
compare, and every one is a chance to compare the wrong pair. It also keeps
documented, unenforced prose alive in the architecture document at
`docs/architecture-stage2-stream.md:264-268`.

### 3.2 Alternative B — The document owns its source

Every builder copies the input into document-owned storage; no borrowed source
survives a build. `Document.deinit` frees it.

*What it costs.* One full copy of the input per document, on every path. This
is the exact cost the staged design exists to avoid: the tape is eight bytes
per token and the source is copied once, so a JSON-heavy caller pays
`input.len` bytes of extra residency per live document. The reusable JSONL
record parser reuses one high-water tape across records
(`src/formats/jsonl.zig:242`, `:454-508`); it would additionally have to own one
source buffer sized to the largest record, or re-copy per record. The
`TapeRecordParser` capacity model at `src/formats/jsonl.zig:227-230` has two
ceilings, input and tape; a third, owned-source, would need a third option and
a third failure. The on-demand paths are explicitly zero-copy over caller input
(`src/formats/json.zig:51-61`), and the seven `initOnDemandDocument` adapters
are built on that premise.

*What it breaks.* Every `[]const u8` currently borrowed from the caller's buffer
becomes document-owned, so `XmlDecodeOptions.source`
(`src/formats/xml.zig:1350-1353`), `XmlEvent.raw` (`:1522`), and every
caller-owned-output overlap check all change meaning.
`stream.StreamIndexer.take` handing back an index that no longer relates to any
caller buffer (`src/core/stream.zig:234-243`) becomes a different API.

*Why it was not chosen.* It trades the design's central property — copy the
bytes once at the boundary, never again — for a guarantee the caller can
already obtain by not freeing the buffer. It is the right answer for a library
whose callers cannot hold a buffer, which this one has no evidence of.

### 3.3 Alternative C — A `Source` capability object with a generation counter

Introduce one type, say `Source`, that owns the `[]const u8` pointer and a
`u64` generation. Documents, cursors, events, and diagnostics all carry a
`Source` by value. `Source` is invalidated when its owner drops the buffer;
every derived value validates its `Source` against the live one.

*What it costs.* A new vocabulary type threaded through every public struct in
the tree, including the 25 fields already typed from un-exported modules
(section 5.3) and every `Event` type that currently carries a bare `[]const u8`
field (`src/core/ondemand.zig:389-399`, `src/formats/jsonl.zig:106`,
`src/formats/markdown.zig:1360`). It also has to answer a question the current
design answers for free: what invalidates a `Source`? Releasing a borrow is a
caller-side event the library cannot observe. A generation counter only helps
if the library owns the increment, which means the library must own the buffer
— which collapses Alternative C into Alternative B.

*What it breaks.* Every public event and value type. It also duplicates the
existing `resident.State` generation (`src/core/resident.zig:14-19`, `:23-26`),
producing two generation vocabularies instead of one, which is the failure R5
already reports.

*Why it was not chosen.* It adds a state machine to express a fact the caller
already knows — they hold the buffer — and it does not make the mispairing
unrepresentable either, only detectable, so it is strictly worse than 3.1 on
the same axis.

### 3.4 Alternative D — Generative, non-interchangeable view types

Make the type of a cursor depend on the type of the source it was built from:
`stage2.JsonCursor`, `stage2.JsoncCursor`, `stage2.Json5Cursor`, and so on, so
`root` no longer takes a dialect-bearing document. A cursor can then only be
paired with the bytes its own builder saw.

*What it costs.* One type per (document kind x dialect) pair. Stage 2 has three
dialects (`src/core/stage2.zig:25-29`) and six public entry points that build a
document: `buildTape` (`src/core/stage2.zig:634`) and `buildTapeView` (`:517-542`),
plus the four per-format builders that wrap them
(`src/formats/json.zig:136`, `jsonc.zig:68`, `json5.zig:68`, `jsonl.zig:1023`).
Public names multiply, `matchingStart` returns a differently-typed
value in each instantiation (`src/core/stage2.zig:141-164`), and every generic
caller that writes `fn walk(c: anytype)` against a `TapeCursor` has to become
generic or duplicated. It also does not address R2 or R4 at all.

*What it breaks.* `stage2.TapeCursor` is named in public signatures
(`src/core/stage2.zig:74`, `test/root_test.zig:657` names
`lib.stage2.TapeCursor` explicitly), in `jsonl.TapeRecordCursor.cursor`
(`src/formats/jsonl.zig:573`), and in the on-demand `Token`/`Event` shapes.

*Why it was not chosen.* The dialect is already carried in the document and
copied into the cursor (`src/core/stage2.zig:68`, `:79`, `:113`); the
generality is what makes the tape reusable across the three dialects. Trading
that for a compile-time pairing guarantee multiplies the public surface to fix
a problem the selected contract's source-argument removal (C2) fixes at zero
type-level cost.

### 3.5 Selected

Not an "alternative": the selected contract in section 4 is Alternative A's
identity check plus the removal of the source argument, plus Alternative C's
three-way ownership vocabulary applied to return values rather than to buffer
lifetime, plus the single exported lease vocabulary. Sections 4, 5, and 6
state it precisely.

---

## 4. The selected contract

Nine clauses. C3 is **Enforced today** in part; C4-C8 each pair a current-state
label — **Documented, not enforced** in C4, **Enforced today** in the rest —
with a **Proposed** part; C1, C2, and C9 are **Proposed** throughout; each
clause says which.

### C1 — A document records its borrowed source once, at build time

**Proposed.** Every document type that can return a slice of source bytes gains
a `source: []const u8` field, written by its builder, never by an accessor.
Today five of the six document types already have it:
`MarkdownDocument` (`src/formats/markdown.zig:912-914`),
`XmlDocument` (`src/formats/xml.zig:1570-1572`, optional and possibly `null`),
`YamlDocument` (`src/formats/yaml.zig:168-170`),
`yaml_extended.Document` (`src/formats/yaml_extended.zig:115-119`), and
`CommonMarkDocument` (`src/formats/commonmark.zig:155-161`). Only
`stage2.Document` (`src/core/stage2.zig:66-68`) lacks it, and it is the one
that hands out raw strings, numbers, and literals
(`src/core/stage2.zig:173-196`).

Checkable: after this clause, no public document struct lacks a source field,
and no builder drops the caller's slice on the floor.

### C2 — No public accessor takes a source argument

**Proposed.** A signature that accepts `input: []const u8` next to a document
that already knows its source is the defect. `Document.root()` takes none.
`rawSpan`, `value`, `sourceSpan`, `decodeInto`, and every `raw` accessor take
none. Today the opposite is true: `stage2.Document.root` (`:74`),
`MarkdownDocument.root` (`:921`), `MarkdownDocument.sourceSpan` (`:939`),
`XmlDocument.root` (`:1620`), `XmlDocument.sourceSpan` (`:1584`),
`XmlDocument.declarationInfo` (`:1605`), `YamlDocument.root` (`:177`),
`YamlDocument.sourceSpan` (`:203`), `yaml_extended.Document.rawSpan` (`:152`),
`yaml_extended.Document.value` (`:202`), and the whole `XmlDecodeOptions`
surface (`src/formats/xml.zig:1350-1353`, `:1535`, `:1544`).

Checkable: `grep -E "fn .*\(.*(input|source): \[\]const u8" src/` returns only
constructors and the caller-owned-output decoders, which keep their argument
because their argument *is* the storage they write into.

### C3 — Identity is `(ptr, len)`, compared before any byte is read

**Enforced today** for `MarkdownDocument.root` → `InvalidSource`
(`src/formats/markdown.zig:921-924`), `XmlDocument.root` → `SourceMismatch`
(`src/formats/xml.zig:1620-1622`), `YamlDocument.root` → `SourceOutOfBounds`
(`src/formats/yaml.zig:177-181`), `yaml_extended.Document.ensureSource` →
`SourceOutOfBounds` (`src/formats/yaml_extended.zig:128-132`, reached from
`rawSpan` and `value` through `checkedWord` at `:134-150`), and
`jsonl.TapeRecord.check` → `SourceOutOfBounds`
(`src/formats/jsonl.zig:544-557`, reached from `root`, `cursor`, and
`tapeWords`). **Not enforced** for `stage2.Document.root`
(`src/core/stage2.zig:74-83`, which rejects only an empty tape at `:75`) and
for every `CommonMarkDocument` accessor (`src/formats/commonmark.zig:171-199`,
`:201-228`; `self.source` is never read).

Two gaps inside the "enforced" group, both **Enforced today** as a partial
result:

- `yaml_extended.Document.scalarInfo` takes no `input` and validates only
  against `self.source` (`src/formats/yaml_extended.zig:164-200`), so it cannot
  observe a mismatch; `rawSpan` and `value` can, because `checkedWord` calls
  `ensureSource` first (`:139`).
- `XmlDocument.source` is `?[]const u8` (`src/formats/xml.zig:1572`), so a
  document built through a path that leaves it `null` reports `SourceMismatch`
  for *every* input, including the correct one (`:1621`).

Checkable: for each document type, a call with a same-length, shape-valid but
different buffer returns the family's mismatch error and reads nothing.

### C4 — The borrow lasts from build to `deinit`, and a derived value never
outlives it

**Documented, not enforced** as a runtime property — it is a caller obligation
today, stated at `src/core/stage2.zig:70-73` ("The caller must keep `input` and
this document alive for as long as the returned cursor is used"),
`src/formats/json.zig:51-53` ("The input must outlive the returned
document"), `AGENTS.md:38-39`, and
`docs/architecture-stage2-stream.md:264-268`. **Proposed** as a written
contract with one term: the borrow is held from the `build*` / `init*Document`
call until the matching `deinit` / release returns. Every slice derived from a
document — cursor, event, value, span, diagnostic snippet
(`src/core/stage2.zig:391-398`, `src/formats/jsonl.zig:74-84`,
`src/formats/markdown.zig:1073-1080`, `src/formats/yaml.zig:77-85`,
`src/formats/xml.zig:1419-1426`,
`src/formats/yaml_extended.zig:70-78`) — is valid for no longer than the borrow.

Checkable: every `deinit` on a document type frees exactly the fields it owns
and does not free `source`. This is already true of all six:
`stage2.Document.deinit` frees only `tape` (`src/core/stage2.zig:85-88`),
`MarkdownDocument.deinit` only `tape` (`:916-919`), `XmlDocument.deinit` only
`tape` (`:1574-1577`), `YamlDocument.deinit` only `tape` (`:172-175`),
`yaml_extended.Document.deinit` frees `tape`, `scalar_metadata`, and `cooked`
but not `source` (`:121-126`), and `CommonMarkDocument.deinit` frees
`references`, `text_bytes`, `texts`, and `nodes` but not `source` (`:163-169`).

### C5 — Derived cursors and values are invalidated by a named event, and
report a named error

**Enforced today** on the reusable-parser paths, **Proposed** as one table
covering all of them.

| Invalidation event | Where the value is checked | Error today | Error under this contract |
|---|---|---|---|
| Document `deinit` / release | `resident.Lease.check`, `src/core/resident.zig:47-50` | `DocumentReleased` | unchanged |
| Second `init*Document` on a live parser | `resident.State.begin`, `:20-21` | `DocumentActive` | unchanged |
| Parser `reset` (JSONL record path) | `checkRecord`, `src/formats/jsonl.zig:364-373`; lease cleared by `releaseLease`, `:346-350` | `DocumentReleased` | unchanged |
| Iterator advance invalidates the previous record | `invalidateRecord`, `:359-362`, reached from `TapeRecordIterator.next`, `:632` | `OutOfOrderIteration` | unchanged |
| Stale iterator deinit against a newer lease | `TapeRecordIterator.deinit`, `:675-681`; guarded by `Lease.release`, `src/core/resident.zig:52-58` | silently ignored | unchanged |
| Focus stolen by a sibling cursor | `resident.Lease.claim`, `:60-69` | `FocusAlreadyClaimed` | one name tree-wide |
| Cursor advanced by a copy | `resident.Guard.check`, `:76-81` | `OutOfOrderIteration` | unchanged |
| Document `deinit` (JSON on-demand) | `ondemand.Document.ensureAlive`, `src/core/ondemand.zig:276-279` | `DocumentReleased` | unchanged |
| Focus stolen (JSON on-demand) | `ondemand.TokenCursor.ensureFocused`, `:355-362`; `EventReader`, `:471-475` | `FocusLost` (`:18`) | one name tree-wide |
| Stage 2 `TapeCursor` past `deinit` | nothing — `src/core/stage2.zig:110-114` | none | `DocumentReleased` |

The two "one name tree-wide" rows are the R5 failure. `error.FocusLost` is
declared at `src/core/ondemand.zig:18` and returned at `:358` and `:472`, and
appears nowhere else in the tree. The shared module has no equivalent: it
reports a stolen claim at `claim` time (`:62`) and a moved position at
`Guard.check` (`:79`), so a cursor that loses focus while the document is
released-and-reclaimed reports `DocumentReleased` rather than a distinct
condition.

Checkable: the last column is the union of the invalidation errors reachable
from every derived-value accessor in the tree, and no such accessor returns an
invalidation error outside that column.

### C6 — A returned slice's storage is one of three named kinds

**Enforced today** for exactly one path, **Proposed** tree-wide. The
vocabulary already exists as `yaml_extended.ValueOwnership`
(`src/formats/yaml_extended.zig:30-33`, `:80-91`) and is read by a real
non-test consumer (`scripts/yaml_extended_bench.zig:170`, `:241`; wired into
the build at `build.zig:485-488`, `:577-581` via `semantic_bench.zig:45`).

| Kind | Meaning | Example today |
|---|---|---|
| `document_owned` | valid until the document's `deinit` | `yaml_extended.Document.cooked` (`:119`) |
| `parser_owned_reusable` | valid until the next reuse of the parser | JSONL high-water tape (`src/formats/jsonl.zig:242`); on-demand index array (`src/core/ondemand.zig:47`) |
| `caller_source` | valid for the caller's buffer | `stage2.TapeCursor.rawValue` (`src/core/stage2.zig:173`) |

The generalized form is a `Borrowed` wrapper carrying the slice and the kind,
returned by every accessor that today returns a bare `[]const u8`. A caller who
does not need the distinction pays one word.

One correction to a natural inference: `ScalarInfo.ownership`
(`src/formats/yaml_extended.zig:93-100`) is populated at `:198` and is **read
nowhere in the tree**. The only consumers of that record read `style`,
`chomping`, `indentation`, `indentation_indicator`, and `indentation_width`
(`test/yaml_extended_test.zig:41-42`, `:204-205`, `:272-283`;
`scripts/yaml_extended_bench.zig:171-173`). The ownership a caller actually
learns comes from `Value.ownership()` (`:88-90`). The generalized form must not
reproduce a second, unread ownership field on an information record.

### C7 — An index is not a document

**Enforced today** (`src/core/stage1.zig:5-56`, `src/core/stream.zig:160-243`),
**Proposed** as an explicit rule. A structural index owns `u32` offsets and
borrows nothing: `feed` copies into padded slots and keeps no reference to the
caller's chunk (`src/core/stream.zig:160-194`), `feedFrom` borrows the reader
buffer only for each `feed` call (`:195-214`), and `take` transfers the index
out (`:234-243`). The format-local indexes are the same shape
(`src/formats/markdown.zig:19-48`, `src/formats/yaml.zig:95-117`,
`src/formats/xml.zig:22-32`), and the two `sourceSpan` accessors they do carry
return offsets into a caller buffer the index never stored
(`src/formats/markdown.zig:30-47`, `src/formats/yaml.zig:110-116`).

Rule: releasing the source while keeping the index is correct; using the index
to build a document or a cursor is not, because the document is what records
the source under C1.

### C8 — Caller-owned output: one check order, no partial write

**Enforced today** in both decoders, **Proposed** as one order. Both already
promise that an error leaves the output unmodified
(`src/core/json_value.zig:33-35`; `src/formats/xml.zig:1348-1349`). They
disagree on the order and on what the overlap check compares.

Today's two orders:

- `json_value.decodeString` (`src/core/json_value.zig:36-47`): overlap against
  `raw`, the span being decoded (`:37`, `:73-82`) → UTF-8 validation (`:39-42`)
  → length preflight (`:44`) → write (`:45`).
- The XML event decoders — `decodeXmlAttributeEvent`
  (`src/formats/xml.zig:3817-3830`), `decodeXmlTextEvent` (`:3832-3845`), and
  `decodeXmlCdataEvent` (`:3847-3860`): validate the event (`:3822`) → dry-run
  decode for the required length (`:3823`) → overlap against `source`, the
  *whole* document buffer from `XmlDecodeOptions` (`:3825`, `:3632-3640`) →
  capacity (`:3826`) → write (`:3827`).

The contract fixes the order to: validate the event or value; derive the exact
span to be read; reject overlap of *that span* with the output; compute the
required length; reject insufficient capacity; write. The change is
substantive, not cosmetic: the XML check today rejects a caller that decodes
one attribute into a scratch buffer carved out of the same document, which the
span-level check would permit, so the XML side loses a false rejection while
the JSON side keeps its current, correct behavior.

### C9 — Every public type is reachable from the root

**Proposed.** No public struct field, public error set, or public type alias may
name a type from a module `src/root.zig` does not export. The root exports
`simd`, `stage1`, `stage2`, `json_value`, `ondemand`, `stream`, `debug`
(`src/root.zig:4-10`) and the nine format modules (`:27-37`). It does not export
`core/resident.zig`, `core/json_lexical.zig`, or `formats/yaml_source.zig`.

---

## 5. Mapping onto every current public entry point

### 5.1 Entry points that enforce source identity today

| Entry point | Check | Error |
|---|---|---|
| `markdown.MarkdownDocument.root` | `src/formats/markdown.zig:921-924` | `InvalidSource` |
| `markdown.MarkdownDocument.sourceSpan` | `:939-944` (via `root`) | `InvalidSource` |
| `xml.XmlDocument.root` | `src/formats/xml.zig:1620-1622` | `SourceMismatch` |
| `xml.XmlDocument.declarationInfo` | `:1605-1609` (via `ensureXmlDocumentSource`) | `SourceMismatch` |
| `xml.XmlDocument.sourceSpan` | `:1584-1602` — **no identity check**, only bounds and kind | `SourceOutOfBounds` |
| `yaml.YamlDocument.root` | `src/formats/yaml.zig:177-181` | `SourceOutOfBounds` |
| `yaml.YamlDocument.sourceSpan` | `:203-221`, identity compared inline at `:208-210` | `SourceOutOfBounds` |
| `yaml_extended.Document.rawSpan` | `src/formats/yaml_extended.zig:152-162` (via `checkedWord` → `ensureSource`) | `SourceOutOfBounds` |
| `yaml_extended.Document.value` | `:202-230` (same path) | `SourceOutOfBounds` |
| `jsonl.TapeRecord.root` / `.cursor` / `.tapeWords` | `src/formats/jsonl.zig:522-542` (via `check`, `:544-565`) | `SourceOutOfBounds` |

### 5.2 Entry points that do not enforce source identity today

| Entry point | Why it does not need to, or what it lacks |
|---|---|
| `ondemand.Document` and everything derived from it (`tokenCursor` `:261`, `eventReader` `:272`, `TokenCursor` `:293`, `EventReader` `:401`) | The source is bound at construction: `Document.input` (`:242`) is set by `finishOwnedDocument` (`:178-223`) and read through `self.document.input` (`:309`). `ensureAlive` (`:276-279`) checks liveness and generation, not identity, and does not need to. |
| `jsonl.OnDemandDocument`, `EventReader` (`:712`), `TokenCursor` (`:851`) | Same shape: the source is bound at `initOnDemandDocument` (`:167-179`) and stored on the document (`:183`). |
| `markdown.OnDemandDocument`, `EventReader` (`:1429`), `TokenCursor` (`:1460`) | Same shape; `initOnDemandDocument` at `:1332` and `:1396`, document at `:1365-1370`. |
| `xml.XmlOnDemandDocument`, `XmlEventReader` (`:3071`), `XmlTokenCursor` (`:3113`) | Same shape; `initOnDemandDocument` at `:2712` and `:3172`, document at `:2737-2743`. |
| `yaml.OnDemandDocument`, `EventReader` (`:374`), `TokenCursor` (`:411`) | Same shape; `initOnDemandDocument` at `:358`, document at `:331-335`. |
| **`stage2.Document.root`** | **No source recorded, no identity check.** `src/core/stage2.zig:66-83`. This is the defect R1 names. |
| `stage2.TapeCursor.rawValue` | Returns a slice of the caller-supplied `input` (`:173-196`, `rawString` at `:292-`). With C1 and C2 the cursor would carry the document's recorded source instead. |
| `stage2.TapeCursor.matchingStart` | Propagates `self.input` unchecked (`:158-163`). |
| **`commonmark.CommonMarkDocument`** — `root` (`:171`), `node` (`:176`), `nodeChildren` (`:182`), `text` (`:191`), `ChildIterator.nextChild` (`:207`), `renderCommonMarkHtml` (`:2688`) | **Stores `source` (`:157`) and reads it in no accessor.** `Node.source` is a `SourceSpan` of `u32` offsets (`:42-45`, `:89`), not an identity token, so a node cannot be checked against a buffer. |
| `xml.XmlDocument.sourceSpan` | Bounds and kind only (`:1584-1602`); no comparison against `self.source`. |
| `yaml_extended.Document.scalarInfo` | Takes no `input` (`:164-200`); validates only against the recorded `self.source`. |
| `stage1.StructuralIndex.slice` and the two format-local index `sourceSpan` accessors | By design (C7): an index borrows nothing. `src/core/stage1.zig:53-55`, `src/formats/markdown.zig:30-47`, `src/formats/yaml.zig:110-116`. `XmlStructuralIndex` (`src/formats/xml.zig:22-32`) has no `sourceSpan` at all. |
| `json_value.decodeString` (`:36`), `json_value.parseNumber` (`:55`) | Take the bytes to read as their argument; there is no document to pair with. Governed by C8. |
| The `XmlDecodeOptions` surface: `XmlAttributeEvent.decodeInto` (`:1445`), `XmlTextEvent.decodeInto` (`:1461`), `XmlCdataEvent.decodeInto` (`:1484`), `XmlEvent.decodeInto` (`:1544`), and the four `decodedLength` accessors (`:1441`, `:1457`, `:1480`, `:1535`) | Take the whole document `source` in options (`:1350-1353`). Governed by C8. |
| `xml.XmlQName.split` (`:1369`), `xml.XmlDeclarationEvent.info` (`:1503`), `xml.parseDeclarationInfo` (`:3871`), `xml.parsePredefinedEntity` (`:3429`) | Operate on a caller-supplied `[]const u8` and return a sub-slice of it; no document, no tape, nothing to pair. |
| `ondemand.Event` and `jsonl.Event` payload slices (`:389-399`, `src/formats/jsonl.zig:106`) | Slices of the document's own `input` field, bound at construction. |
| The six `Diagnostic` types and their constructors | `snippet` is a slice of the input passed to the diagnostic constructor: `stage2.Diagnostic` (`src/core/stage2.zig:391-398`) built by `diagnosticAt` (`:659`), `jsonl.JsonlDiagnostic` (`src/formats/jsonl.zig:74-84`) built at `:684-704`, `yaml.YamlDiagnostic` (`:77-85`) by `yamlDiagnosticAt` (`:1481`), `markdown.MarkdownDiagnostic` (`:1073-1080`) by `markdownDiagnosticAt` (`:1145`), `xml.XmlDiagnostic` (`:1419-1426`), and `yaml_extended.Diagnostic` (`src/formats/yaml_extended.zig:70-78`). Valid for the borrow. |

### 5.3 Entry points that expose types from modules the root does not export

Verified by reading every `pub` declaration in `src/`. 25 public struct fields,
3 public error sets, 2 public type aliases, plus 4 `pub fn` declarations inside
private structs that are not reachable.

Public struct fields, 24 typed from `core/resident.zig`:

| Field | Location |
|---|---|
| `jsonl.Parser.storage` / `.state` | `src/formats/jsonl.zig:116`, `:120` |
| `jsonl.OnDemandDocument.lease` | `:185` |
| `jsonl.TapeRecordParser.storage` / `.state` | `:241`, `:245` |
| `jsonl.TapeRecord.lease` | `:513` |
| `jsonl.TapeRecordCursor.lease` | `:571` |
| `jsonl.TapeRecordIterator.lease` / `.guard` | `:622`, `:623` |
| `jsonl.EventReader.guard` | `:714` |
| `jsonl.TokenCursor.guard` | `:853` |
| `markdown.Parser.candidates` / `.resident_state` | `src/formats/markdown.zig:1295`, `:1296` |
| `markdown.OnDemandDocument.lease` | `:1368` |
| `markdown.EventReader.guard` | `:1433` |
| `markdown.TokenCursor.guard` | `:1464` |
| `xml.Parser.state` | `src/formats/xml.zig:2690` |
| `xml.XmlOnDemandDocument.lease` | `:2739` |
| `xml.XmlEventReader.guard` | `:3073` |
| `xml.XmlTokenCursor.guard` | `:3115` |
| `yaml.Parser.state` | `src/formats/yaml.zig:314` |
| `yaml.OnDemandDocument.lease` | `:334` |
| `yaml.EventReader.guard` | `:377` |
| `yaml.TokenCursor.guard` | `:414` |

Plus one from `core/json_lexical.zig`:

| Field | Location |
|---|---|
| `stream.StreamIndexer.carry` | `src/core/stream.zig:51` |

Public error sets, 3:

| Set | Location |
|---|---|
| `jsonl.TapeRecordError` | `src/formats/jsonl.zig:209-216` |
| `markdown.MarkdownOnDemandError` | `src/formats/markdown.zig:1283` |
| `yaml.ResidentError` | `src/formats/yaml.zig:304-309` |

Public type aliases, 2:

| Alias | Location |
|---|---|
| `stream.CommentState` = `lexical.CommentState` | `src/core/stream.zig:36` |
| `stream.CarryState` = `lexical.State` | `src/core/stream.zig:37` |

Not reachable, listed for completeness: `pub fn appendOffset(... ) lexical.Error`
at `src/core/stream.zig:59`, `src/formats/json.zig:15`, `jsonc.zig:15`,
`json5.zig:15` sit inside private sink structs (`const ScanSink = struct` at
`src/core/stream.zig:56`; `const IndexSink = struct` at
`src/formats/json.zig:11`), so they are not public entry points.

### 5.4 Entry points that are entry points only because of a lease type

Every accessor in this group is reachable only through a value whose type names
`resident.Lease` or `resident.Guard`: the `OnDemandDocument.deinit`,
`eventReader`, `tokenCursor` triples across `jsonl` (`:187-200`),
`markdown` (`:1371-1392`), `xml` (`:2744-2764`), `yaml` (`:336-355`); the
`TapeRecord*` family (`src/formats/jsonl.zig:511-618`); and the
`TapeRecordIterator` (`:620-682`). Under C9 these stop being reachable only
through an unnameable type.

### 5.5 Entry points that already match the contract

`stage1.StructuralIndex` and its three format-local siblings (C7);
`XmlQName.split`; `ondemand.initDocument` (`:232-238`); the seven
`initStreamIndexer` adapters and seven `initOnDemandDocument` adapters
(`src/formats/json.zig:40`, `:54`; `jsonl.zig:10`, `:167`; `jsonc.zig:40`,
`:51`; `json5.zig:40`, `:51`; `markdown.zig:511`, `:1332`; `xml.zig:3179`,
`:2712`; `yaml.zig:2747`, `:358`) — note that `formats.commonmark` and
`formats.yaml_extended` expose neither, and that boundary is unchanged by this
record.

### 5.6 The two caller-owned-output decoders, side by side

| | `json_value.decodeString` | XML event decoders |
|---|---|---|
| Entry points | `src/core/json_value.zig:36` | `src/formats/xml.zig:1445`, `:1461`, `:1484`, `:1544` |
| Overlap compared against | the decoded span `raw` (`:37`) | the whole `options.source` (`:3825`, `:3840`, `:3855`) |
| Order | overlap → UTF-8 → length → write (`:37`, `:39`, `:44`, `:45`) | validate → dry-run length → overlap → capacity → write (`:3822`, `:3823`, `:3825`, `:3826`, `:3827`) |
| Output on error | unmodified (`:33-35`) | unmodified (`:1348-1349`) |
| Overlap error | `OverlappingBuffers` (`src/core/json_value.zig:9`) | `OverlappingBuffers` (`src/formats/xml.zig:1336`) |
| Capacity error | `CapacityExceeded` (`:8`) | `CapacityExceeded` |

---

## 6. What would have to change to adopt this

Nine steps. Each is independently reviewable: each can land, be read, and be
reverted without the others. Each names the check that closes it. No step
changes an accepted grammar, a diagnostic, a checksum, or a streaming boundary.

**Step 1 — Export the lease vocabulary from the root.**
Add one `pub const lease` namespace to `src/root.zig` re-exporting `State`,
`Lease`, `Guard`, `IndexBuffer`, and `Error` from `core/resident.zig`; have
`jsonl`, `markdown`, `xml`, and `yaml` alias that namespace instead of naming
the private module. Closes C9 for the 24 resident-typed fields and 3 error sets.
Check: the 27 declarations in section 5.3 name only root-reachable types.
Independent: no behavior change; this step alone is provable by compiling the
root and the six format modules.

**Step 2 — Export the lexical state from the root, or stop aliasing it.**
Either add `core/json_lexical.zig` to `src/root.zig`, or retype
`stream.StreamIndexer.carry` (`src/core/stream.zig:51`) and the
`CommentState` / `CarryState` aliases (`:36-37`) in terms of something the root
exports. Closes the remaining two aliases and one field. Check: the two
aliases and one field in section 5.3 are gone or reachable.
Independent of step 1; both are pure re-export work and can be reviewed
together or apart.

**Step 3 — Route the JSON on-demand module through the shared lease.**
Replace `ondemand.Parser.generation` / `.document_active` / `.focus`
(`src/core/ondemand.zig:51-53`), `Document.ensureAlive` (`:276-279`), and
`claimFocus` (`:281-285`) with `resident.State`, `resident.Lease`, and
`resident.Guard`, keeping the focus-owner check that the shared module lacks.
Decide the one name for "a sibling cursor took the focus": either adopt
`FocusLost` into `resident.Error` (`src/core/resident.zig:7-12`) or collapse it
into `OutOfOrderIteration`. The record's choice is to add `FocusLost` to
`resident.Error` and delete `ondemand`'s declaration, because the condition is
real and distinct from both release and position drift.
Check: `error.FocusLost` occurs in exactly one declaration in the tree.
Independent: behavior is unchanged except that the name has one home.

**Step 4 — Route the JSONL release path through `Lease.release`.**
Replace `TapeRecordParser.releaseLease` (`src/formats/jsonl.zig:346-350`), which
mutates `state.active`, `state.claimed`, and `state.position` directly and skips
both guards in `Lease.release` (`src/core/resident.zig:53-54`), with a call that
goes through the shared module. Called from `TapeRecordParser.deinit` (`:278`)
and `reset` (`:289`).
Check: `releaseLease` no longer writes `resident.State` fields;
`test/jsonl_record_tape_test.zig:167-219` still passes unchanged, including the
stale-iterator-cannot-release-a-newer-lease case at `:209-210`.
Independent: no signature change.

**Step 5 — Record the source in `stage2.Document`.**
Add `source: []const u8` to `src/core/stage2.zig:66-68`; set it in `buildTape`
(`:634`) and `buildTapeView` (`:517-542`) from the same `input` the reader
validated — note that `TokenReader.reset` narrows the input to the view's limit
(`:762`), so the recorded value is `reader.input`, the bounded slice, not the
caller's whole buffer. Check: every `stage2.Document` construction site in the
tree sets it, including the per-record literal at `src/formats/jsonl.zig:525`.
Independent: the field is added and set; no accessor reads it yet.

**Step 6 — Remove the source argument from the accessors that can drop it.**
This is C2. In order: `stage2.Document.root` (`src/core/stage2.zig:74-83`),
`TapeCursor.rawValue` (`:173-196`) and `matchingStart` (`:141-164`) to read the
cursor's recorded source; then `MarkdownDocument.root` / `.sourceSpan`
(`src/formats/markdown.zig:921`, `:939`), `XmlDocument.root` / `.sourceSpan` /
`.declarationInfo` (`:1620`, `:1584`, `:1605`), `YamlDocument.root` /
`.sourceSpan` (`:177`, `:203`), `yaml_extended.Document.rawSpan` / `.value`
(`:152`, `:202`). Make `XmlDocument.source` non-optional
(`src/formats/xml.zig:1572`) so the `null`-means-`SourceMismatch` case at `:1621`
disappears. Migrate the 89 call sites in the section 3.1 census — every `root`
above, with or without a source argument — plus the `sourceSpan`,
`declarationInfo`, `rawSpan`, and `value` call sites in sections 5.1 and 5.2,
including `test/root_test.zig:711-731`, whose wrong-source expectations move
from read-time to access-time.
Check: the grep in C2 returns only constructors and C8 decoders.
Independent of steps 1-5.

**Step 7 — Give `CommonMarkDocument` an enforced source.**
Its `source` field (`src/formats/commonmark.zig:157`) is already recorded and
already survives `deinit` (`:163-169`). Add the accessors the other five
documents have — a source-bearing entry point that returns offsets, not bytes —
and state the borrow in the doc comment. `Node.source` stays a `SourceSpan` of
`u32` offsets (`:42-45`, `:89`); do not widen it to a pointer, and do not
convert a node access into a fallible one that the other formats do not have,
because that would change `node` (`:176`) from `?*const Node` semantics for
identity rather than for bounds.
Check: `self.source` is read by at least one accessor; `node`, `text`, and
`nodeChildren` keep their current return types.
Independent.

**Step 8 — Adopt C8's single check order.**
In `src/core/json_value.zig:36-47` move the overlap check after the span is
known (it already is) and keep it against the decoded span. In
`src/formats/xml.zig:3817-3860` move the overlap check from the whole
`options.source` to the event's decoded span, and reorder to validate → span →
overlap → required length → capacity → write. The three event decoders and
`XmlEvent.decodeInto` (`:1544`) share this shape and must change together.
Check: for each of the four entry points, a deliberately overlapping output
returns `OverlappingBuffers` and leaves the output unmodified; the three
existing error names are unchanged.
Independent.

**Step 9 — Generalize the ownership vocabulary and delete the unread field.**
Promote `ValueOwnership` (`src/formats/yaml_extended.zig:30-33`) to a
tree-level type, return a `Borrowed` carrying slice plus kind from the accessors
in section 5.2 that hand out bare `[]const u8`, and remove `ScalarInfo.ownership`
(`:99`, written at `:198`, read nowhere) rather than generalizing it. Keep
`Value.ownership()` (`:88-90`) as the only ownership accessor.
Check: every accessor in the table of C6 returns a value whose kind is stated;
`ScalarInfo` has five fields, not six.
Independent.

Sequencing note: steps 1-4 are lease and export hygiene and can land in any
order. Step 5 must precede step 6. Step 6 is the only breaking change to
caller code and should be reviewed on its own. Steps 7-9 are independent of
1-6. No step requires touching a grammar, a dialect rule, a diagnostic, or a
stream indexer.

---

## 7. Explicitly deferred

Nothing in this record changes any of the following. These boundaries are
restated here so the record cannot be read as reopening them.

**Shipped dialect rules, unchanged.** The seven tape formats keep their
current accepted grammars and their per-dialect first-error behavior. The
extended YAML profile keeps exactly what it accepts today: literal and folded
block scalars, multiline quoted scalars, and compact sequence mappings. No
step in section 6 widens a grammar, changes an offset, changes a diagnostic
coordinate, or changes a checksum.

**Tape ownership versus borrowed source, unchanged.** Documents keep owning
their tapes (`src/core/stage2.zig:85-88`, `src/formats/markdown.zig:916-919`,
`src/formats/xml.zig:1574-1577`, `src/formats/yaml.zig:172-175`,
`src/formats/yaml_extended.zig:121-126`) and keep borrowing source. C1 adds a
recorded pointer; it does not move a byte into the document. Alternative B is
rejected on exactly this ground.

**The seven-versus-two streaming split, unchanged.** `initStreamIndexer` and
`initOnDemandDocument` exist for JSON, JSONL, JSONC, JSON5, Markdown, XML, and
YAML (`AGENTS.md:42-46`, `docs/architecture-stage2-stream.md:46`).
`formats.commonmark` and `formats.yaml_extended` expose neither. This record
adds no stream indexer to either and removes none from the other seven.

**The index-only streaming boundary, unchanged.** `feed` borrows for the call;
`feedFrom` borrows the reader buffer for each `feed`; `take` hands the index
over; Stage 2 and the on-demand readers still require caller-owned complete
input that outlives them (`docs/architecture-stage2-stream.md:657-662`,
`:682-685`, `:879-883`). C7 restates this; it does not move it. Streaming is
not added to `formats.commonmark` or `formats.yaml_extended`, and `feedFrom` is
not extended to produce a cursor.

**Deferred-feature boundaries, unchanged.** For the extended YAML profile,
aliases, anchors, tags, complex keys, directives, multiple documents, schema
resolution, and streaming stay outside the profile (`AGENTS.md:114-116`). The
`yaml-basic-1.2.2` profile keeps anchors, tags, and directives as
`Unsupported` (`docs/architecture-stage2-stream.md:603`). For XML, DTD and
DOCTYPE remain unsupported — both the tape and on-demand paths reject `<!` with
`UnsupportedDeclaration` (`src/formats/xml.zig:2190-2191` and `:2944-2945`,
declared at `:1326`) — and the parser stays UTF-8-only with no namespace
resolution, no transcoder, and no DTD processing (`AGENTS.md:88-91`). For
CommonMark, the flat document stays flat; no mutable
AST, no full CommonMark streaming, and no additional renderer are in scope
(`AGENTS.md:71-73`, `:119-123`).

**The legacy benchmark domain, not back-filled.** The benchmark's YAML rows
remain `yaml-basic-1.2.2` and its Markdown rows remain a marker-kind projection
(`AGENTS.md:320-323`,
`docs/architecture-stage2-stream.md:1045-1048`). The semantic benchmark already
compiles `scripts/yaml_extended_bench.zig` into the semantic measurement
(`semantic_bench.zig:45`, `build.zig:485-488`, `:577-581`); this
record does not add a legacy row, and does not move the `yaml_extended` module
into the legacy runner.

**Not proposed here.** Source hashing or content fingerprints. An arena or
per-document allocator (there is no arena under `src/` today, and the
`JsonlDocument` already needs one records slice plus one tape per record,
`src/formats/jsonl.zig:47-71` and `:23-41`). A DOM or a typed value tree. Any
streaming reader. A relocated public type as an alternative to a re-export.
Fixing the two documentation disagreements below belongs to the writer that
owns those files, not to this record.

---

## Corrections to the supplied evidence base

Each item was re-checked against the tree on 2026-10-01.

**Stale: "no non-test consumer of the extended YAML value API."** The tree has
one, and it is wired into the build graph. `semantic_bench.zig:45` imports
`scripts/yaml_extended_bench.zig`, which calls `document.value(input, index)`
at `scripts/yaml_extended_bench.zig:168` and `:239` and
`document.scalarInfo(...)` at `:169` and `:240` from its public `run` (`:440`).
`build.zig:264-270` gives that file's importer the `simd_lib` and
`semantic_contract` imports, `:485-488` makes it the `simd-semantic-bench`
executable, and `:577-581` exposes it as `bench-semantic`. The brief's
refutation of the "no non-test consumer" claim is correct; the tree agrees with
the brief, not with the original claim.

**Stale: "the guidance says stale JSONL use after reset fails with either of
two errors when in practice the released-document error always fires first."**
`AGENTS.md:72-78` already states the distinction correctly — `reset` clears the
lease so stale use reports `DocumentReleased`, while `OutOfOrderIteration` comes
from the record generation when the iterator advances. The tree's own test
proves both halves separately: advance yields `OutOfOrderIteration`
(`test/jsonl_record_tape_test.zig:184-186`), `reset` yields
`DocumentReleased` (`:205-206`), and iterator `deinit` yields
`DocumentReleased` (`:187-188`, `:196-197`). The ordering inside
`checkRecord` (`src/formats/jsonl.zig:369` before `:370`) is real, and is
correctly described in the guidance.

**Refined, not wrong: the arena claim.** "No arena exists under the library
source" is correct — no `ArenaAllocator` or `arena` appears anywhere under
`src/`. The "a small fixed number of slices" half is the part that needed
correcting, and the brief already flags it: `JsonlDocument` owns one records
slice plus one tape per record (`src/formats/jsonl.zig:47-71`, `:23-41`,
`:37-40`), `yaml_extended.Document` owns three
(`src/formats/yaml_extended.zig:115-119`), and `CommonMarkDocument` owns four
(`src/formats/commonmark.zig:155-161`, `:163-169`).

**Refined, not wrong: the caller-owned-output precedence.** Both decoders do
validate before writing, and both do reject overlap, but the orders differ and
so does what the overlap check compares: `json_value.decodeString` checks
overlap first and against the decoded span (`src/core/json_value.zig:37`),
while the XML decoders validate, dry-run, then check overlap against the whole
document buffer (`src/formats/xml.zig:3822`, `:3823`, `:3825`). Section 5.6
gives the full comparison and C8 the target order.

**Confirmed and sharper: the vacuous ownership field.** `ScalarInfo.ownership`
(`src/formats/yaml_extended.zig:99`) is written at `:198` from
`ScalarMeta.ownership` (`:110`) and is read nowhere in the tree. The report a
caller actually gets is `Value.ownership()` (`:88-90`), which has a live
non-test consumer. C6 adopts the `Value` form and drops the `ScalarInfo` field.

**Corrected in detail: the public-type inventory.** The brief's counts — 22
fields, 3 error sets, 2 aliases — are right about the three error sets and the
two aliases, but the field count is short: the tree has 24 public struct fields
typed from `core/resident.zig` and a 25th, `stream.StreamIndexer.carry`, typed
from `core/json_lexical.zig` (`src/core/stream.zig:51`) — a second unexported
module. The four `pub fn appendOffset(... ) lexical.Error` declarations at
`src/core/stream.zig:59`, `src/formats/json.zig:15`, `jsonc.zig:15`,
`json5.zig:15` are inside private structs and are not public entry points.
Section 5.3 lists all of it.

**Confirmed: the Stage 2 gap.** `stage2.Document` holds only `tape` and
`dialect` and has no source field (`src/core/stage2.zig:66-68`); `root`
performs no identity check and rejects only an empty tape (`:74-83`);
`buildTapeView` returns a document with the same two fields (`:538-541`). A
cursor can be paired with different input and nothing reports it, except by the
shape accident that `test/root_test.zig:711-715` happens to exercise.

**Confirmed: the CommonMark exception.** `CommonMarkDocument` stores a source
slice (`src/formats/commonmark.zig:157`) that no accessor compares
(`:171-199`, `:201-228`), and per-node source is an offset pair
(`SourceSpan{start: u32, end: u32}` at `:42-45`, used at `:89`), not an
identity token. This is a second instance of the Stage 2 defect, not a
uniqueness of Stage 2.

**Confirmed: the JSONL release bypass.** `TapeRecordParser.releaseLease`
(`src/formats/jsonl.zig:346-350`) writes `resident.State` fields directly and
skips both guards that `Lease.release` applies (`src/core/resident.zig:53-54`).
It is reachable from the public `deinit` (`:278`) and `reset` (`:289`).

**Confirmed: the duplicated on-demand lease.** `src/core/ondemand.zig`
implements the lease and generation rule inline (`:51-53`, `:210-212`,
`:276-285`, `:355-362`, `:471-475`) without importing `core/resident.zig`, and
declares `error.FocusLost` (`:18`) which occurs nowhere else in the tree.

**Documentation disagreements, noted and left to their owner.** The
architecture document already describes the Stage 2 gap accurately at
`docs/architecture-stage2-stream.md:165-173`, but `:264-268` still says raw
value access "requires the exact immutable input passed to
`Document.root(input)`" as though it were checked. `AGENTS.md:16-20` and
`docs/architecture-stage2-stream.md:870-878` both describe the JSON on-demand
reader as implementing the single-focus rule independently with its own
`FocusLost` name, which the tree confirms and which step 3's single lease
vocabulary would change. A separate writer owns `AGENTS.md` and the
architecture document; this
record cites them and edits neither.
