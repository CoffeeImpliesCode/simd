# Trusted Structural-Index Completion Report

## Purpose

This report explains why the parser cannot expose an unchecked completion API.

## Normal Parser Path

The JSON parser works in four steps.

1. Stage 1 reads the JSON bytes.
2. Stage 1 writes structural offsets into parser-owned scratch memory.
3. The parser validates the offsets.
4. The parser creates an active document from the validated offsets.

An offset identifies a byte in the JSON input.

For this input:

```json
{"name":"Ada","items":[1,2]}
```

Stage 1 emits offsets for characters such as `{`, `"`, `:`, `[`, `,`, `]`, and `}`.

The parser later uses an offset to read the input:

```text
input[offset]
```

The parser must verify that every offset is valid before it uses it.

## Existing Checked API

The public API accepts an index stream from any caller.

```zig
parser.completeDocument(input, token_count)
```

This API runs `validateIndexes` before it creates a document.

`validateIndexes` checks these rules.

- Each offset is inside the input.
- Offsets are in ascending order.
- Offsets do not repeat.
- The count fits the parser scratch capacity.
- The index stream has the required sentinels.

If a caller supplies bad indexes, the public API returns an error.

## Optimization Goal

Our own Stage 1 indexer already produces valid indexes.

The parser currently performs this work twice.

```text
Stage 1 creates valid indexes
  → validateIndexes reads all indexes again
  → parser creates the document
```

We want to remove the second read for the internal Stage 1 path.

This can reduce instructions, loads, and parser latency.

## Unsafe Attempt

The abandoned change added this public method.

```zig
parser.completeGeneratedDocument(input, token_count)
```

The method skipped `validateIndexes`.

`json.initOnDemandDocument` was the intended caller.

```text
prepareDocument
  → indexJsonInto
  → completeGeneratedDocument
```

This intended call path was valid.

The method itself was not safe.

## How the Bypass Works

Any caller can access a public `Parser` method.

A caller can write bad data into parser scratch and then call the unchecked method.

```zig
const indexes = try parser.prepareDocument(input);
indexes[0] = 0xffff_ffff;
const document = try parser.completeGeneratedDocument(input, 1);
```

The unchecked method trusts the value `0xffff_ffff`.

The parser then creates an active document.

Later, the reader uses that value as an input index.

```text
input[0xffff_ffff]
```

That value is outside the input.

A safety build traps.

A release build can read invalid memory or produce invalid parser behavior.

The method also accepts duplicate or descending offsets.

Those offsets break the reader assumption that structural indexes are ordered.

## Why the Intended Caller Does Not Solve It

The code can state that only the JSON format module should call the method.

This does not restrict other callers.

A public method is available to:

- another project module;
- a future refactor;
- a test;
- downstream code that imports the parser.

A method name does not prove index provenance.

A boolean such as `.generated` does not prove provenance either.

Any caller can pass `.generated`.

## Safe Design

The parser must own both of these operations.

```text
write generated indexes
complete a trusted generated document
```

The public API must only expose checked completion.

```text
Public caller
  → supplies arbitrary indexes
  → completeDocument
  → validateIndexes

Parser-owned JSON path
  → generates indexes in parser scratch
  → private trusted completion
```

The trusted completion function must not be callable with arbitrary indexes.

## Required Refactor

The current JSON indexer lives in `src/formats/json.zig`.

The parser lives in `src/core/ondemand.zig`.

A safe optimization needs a new internal boundary.

One option is to move the production Stage 1 indexer into a parser-owned internal module.

```text
Parser-owned JSON initialization
  → reserve parser scratch
  → generate structural indexes
  → privately complete the document
```

The parser can then skip `validateIndexes` only after its own indexer completes.

External callers cannot invoke this path.

## Alternative Design

An authenticated generated-index proof can also work.

```text
Stage 1
  → emits indexes
  → emits an opaque proof

Parser
  → verifies the proof
  → completes the document
```

The proof must bind these values.

- Parser generation.
- Input identity and length.
- Index count.
- Exact index contents.

The parser must verify the proof before it creates a document.

A caller can otherwise keep a proof, modify the indexes, and reuse the old proof.

This design still reads the index stream to verify the proof.

It may not remove enough work to justify its complexity.

## Current Safe State

The unsafe completion commit was abandoned.

The direct Stage 1 index-emission optimization remains.

It removes the temporary `[VLEN]u32` index buffer and copy.

The parser still validates generated indexes through the public checked completion path.

Debug and ReleaseSafe test suites passed after that direct-emission change.

## Decision

Do not add a public unchecked completion method.

First move generated index creation behind a parser-owned boundary.

Then add a private trusted completion function.

Keep `completeDocument` checked for every public caller.
