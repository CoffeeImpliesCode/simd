# Markdown Stage 2 specification and corpus evidence

## Scope

This document records the upstream CommonMark sources and the local Markdown Stage 2 contract. These contracts are not equivalent.

CommonMark specifies Markdown parsing and uses expected HTML as its test oracle. This repository preserves a narrow stream of marker offsets and token kinds. It does not build a CommonMark AST or render HTML.

## Authoritative sources and pinned revision

| Source | Authority and use |
|---|---|
| [CommonMark specification index](https://spec.commonmark.org/) | Official release index. It identifies version 0.31.2 as the latest release, dated 2024-01-28. |
| [CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) | Released specification. Its introduction defines the embedded examples as conformance tests. |
| [CommonMark 0.31.2 JSON examples](https://spec.commonmark.org/0.31.2/spec.json) | Official generated corpus for release 0.31.2. |
| [`commonmark-spec` tag commit `9103e341a973013013bb1a80e13567007c5cef6f`](https://github.com/commonmark/commonmark-spec/tree/9103e341a973013013bb1a80e13567007c5cef6f) | Immutable upstream source revision for release 0.31.2. |
| [`spec.txt` at the pinned commit](https://github.com/commonmark/commonmark-spec/blob/9103e341a973013013bb1a80e13567007c5cef6f/spec.txt) | Source specification. It contains the prose and embedded Markdown-to-HTML examples. |
| [`test/spec_tests.py` at the pinned commit](https://github.com/commonmark/commonmark-spec/blob/9103e341a973013013bb1a80e13567007c5cef6f/test/spec_tests.py) | Official extractor and program test harness. |
| [Upstream `LICENSE` at the pinned commit](https://github.com/commonmark/commonmark-spec/blob/9103e341a973013013bb1a80e13567007c5cef6f/LICENSE) | License terms for the specification, DTD, test software, tools, and normalization code. |
| [Package metadata at the pinned commit](https://github.com/commonmark/commonmark-spec/blob/9103e341a973013013bb1a80e13567007c5cef6f/package.json) | Confirms package version 0.31.2 and the `CC-BY-SA-4.0` package license. |

The versioned JSON artifact is 140,487 bytes. Its SHA-256 is `d431b29d97b6f73e69d547109cf5081578fac931e72afe95639ebe766c1b2a20`.

## CommonMark corpus provenance and structure

The specification states that its examples are intended to double as conformance tests. It also supplies the command that runs `test/spec_tests.py` against a Markdown program. The [upstream README](https://github.com/commonmark/commonmark-spec/blob/9103e341a973013013bb1a80e13567007c5cef6f/README.md#running-tests-against-the-spec) gives the same provenance and extraction workflow.

Release 0.31.2 contains 652 examples across 26 sections. The first entry is example 1. The [last JSON entry](https://spec.commonmark.org/0.31.2/spec.json) is example 652.

Each JSON object contains these fields:

- `markdown`: the input document fragment.
- `html`: the expected rendered HTML.
- `example`: the stable example number within this release.
- `start_line` and `end_line`: source locations in `spec.txt`.
- `section`: the specification section name.

The pinned harness extracts the same fields from fenced example blocks in `spec.txt`. It runs a program, normalizes actual and expected HTML by default, and compares the strings. A nonzero program exit is an error. A different normalized rendering is a failure.

The corpus covers block and inline parsing. Its sections include tabs, escapes, entities, precedence, thematic breaks, both heading forms, both code block forms, HTML blocks, reference definitions, paragraphs, block quotes, lists, code spans, emphasis, links, images, autolinks, raw HTML, line breaks, and text.

### Valid and invalid coverage

CommonMark does not define an invalid-document class. The specification states, “Any sequence of characters is a valid CommonMark document.” Therefore, the corpus has no reject cases.

Some examples show text that resembles syntax but does not form a CommonMark construct. Their expected result renders the text literally or under another construct. These are negative grammar examples, not invalid documents.

The specification also warns that not every detail in the expected HTML is a required parser behavior. The automatic suite requires a renderer that matches those examples. A conforming parser can use another renderer for details that the specification does not mandate.

## License and redistribution

The pinned upstream license assigns `spec.txt` and `CommonMark.dtd` to [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). The package metadata also declares `CC-BY-SA-4.0` for the published specification and test cases.

The release JSON is generated from examples in `spec.txt`. Treat the JSON corpus as CC BY-SA 4.0 material. Redistribution is permitted with attribution, a license link, and a change notice. Adapted material must use the same license.

The Python test software and programs under `test/` and `tools/` use the BSD terms in the upstream license. The normalization code also carries the listed MIT-derived notice. These software terms do not replace the CC BY-SA terms for the specification examples.

If the project later vendors only `spec.json`, it should retain the CommonMark attribution and CC BY-SA notice beside the artifact. If it vendors the harness, it must also retain the BSD and MIT notices from the upstream license.

## Local Markdown contract

The local architecture document gives the controlling scope statement. Markdown Stage 2 checks “Stage 1 token integrity for the Markdown marker stream.” It is explicitly not CommonMark validation or a CommonMark AST. See the [Stage 2 support matrix](../architecture-stage2-stream.md#current-six-format-support-matrix).

The shared [`StructuralIndex`](../../src/core/stage1.zig#L5-L56) owns only ordered `u32` byte offsets and a count. `finish` appends three internal sentinels at the input length, while `slice` exposes only the counted offsets. The Markdown index adds its parallel `MarkdownTokenKind` array. This shared Stage 1 storage model is why local ingestion must compare offsets and kinds, not AST nodes.

The executable contract is in [`src/formats/markdown.zig`](../../src/formats/markdown.zig). `MarkdownTokenKind` defines eight token kinds:

1. `heading`
2. `code_fence`
3. `list_item`
4. `blockquote`
5. `inline_code`
6. `link_open`
7. `link_close`
8. `thematic_break`

The scanner records byte offsets. It recognizes line markers after no more than three leading spaces. It suppresses most marker candidates inside fenced code and inline code runs.

The local token names do not imply complete CommonMark nodes:

| Local token | Local Stage 1 meaning | Important limit |
|---|---|---|
| `heading` | A leading `#` marker. | No ATX node, heading level, content span, or Setext heading is produced. |
| `code_fence` | The first byte of an opening or closing backtick or tilde fence. | The token does not identify open versus close or produce a code block node. |
| `list_item` | A leading bullet byte, or the first digit of digits followed by `.`. | The token does not build list nesting, item bounds, delimiter style, or tightness. |
| `blockquote` | A leading `>` marker. | The token does not build block quote contents or nesting. |
| `inline_code` | Each backtick byte in a scanned delimiter run. | The token does not produce a code span or normalized span contents. |
| `link_open` and `link_close` | Bracket and parenthesis bytes outside suppressed code regions. | The scanner does not pair delimiters or resolve links, images, titles, or references. |
| `thematic_break` | A leading `-`, `*`, or `_` on a line with at least three matching markers and whitespace only. | The token is only a marker offset, not a block node. |

The Stage 2 validator checks the supplied token stream against a fresh scan. It checks count bounds, byte-offset bounds, strict offset order, source-byte compatibility, token kinds, missing tokens, and extra tokens. See [`validateMarkdownIndex`](../../src/formats/markdown.zig#L227-L272).

`buildMarkdownTape` then copies each token kind and offset into a packed tape word. The payload remains zero. See the [tape builder](../../src/formats/markdown.zig#L151-L210).

The public repository test confirms this contract. It checks Stage 1 and Stage 2 token parity, accepts an unclosed fence, and rejects a forged out-of-range index. See [`test/root_test.zig`](../../test/root_test.zig#L303-L353). The local [`document.md`](../../test/corpus/markdown/document.md) fixture is a project test input, not an external conformance corpus.

## CommonMark coverage versus local Stage 2 coverage

The full CommonMark corpus is useful input data, but its HTML oracle cannot validate the local tape.

| CommonMark sections | Useful local exercise | Not established locally |
|---|---|---|
| Thematic breaks, ATX headings, fenced code blocks, block quotes, list items, and lists | Marker selection, indentation boundaries, fence suppression, and token order. | Block tree, nesting, heading levels, list structure, and rendered HTML. |
| Code spans, links, images, link reference definitions, and precedence | Backtick-run state and bracket or parenthesis indexing. | Delimiter pairing, reference resolution, destination parsing, titles, and inline AST precedence. |
| Tabs, escapes, entities, Unicode text, and line endings | Byte safety, boundary handling, and deterministic scanning. | Unicode character semantics, escape interpretation, entity decoding, and renderer behavior. |
| Setext headings, indented code, HTML blocks, emphasis, autolinks, raw HTML, and line breaks | General non-crash and token-integrity input coverage. | CommonMark recognition for these constructs. The local token model has no matching node kinds. |

A successful local Stage 2 run on all 652 examples means only that token production and tape preservation agree. It does not mean that the parser conforms to CommonMark 0.31.2.

## Local ingestion recommendation

Do not convert the CommonMark JSON corpus into valid and invalid fixtures. That model conflicts with the specification.

For a later ingestion change:

1. Vendor the unchanged artifact at `test/corpus/upstream/commonmark/0.31.2/spec.json`.
2. Verify the SHA-256 value recorded above during the import process.
3. Add the upstream CC BY-SA attribution and license text beside the artifact.
4. Preserve all six JSON fields. Use `example` and `section` in failure reports.
5. Run every `markdown` value through Stage 1 and Stage 2.
6. Assert termination, index bounds, strict token order, and exact Stage 1-to-tape kind and offset parity.
7. Do not compare the upstream `html` field with local output. This repository has no CommonMark renderer.
8. Hand-author a smaller local expectation table for marker offsets and token kinds. Select examples from the locally relevant sections.
9. Keep forged-index rejection tests in the local suite. The upstream corpus cannot supply invalid-document cases.
10. Label results as `CommonMark input corpus / local token-integrity checks`. Do not label them CommonMark conformance results.

This split keeps the full official corpus intact for provenance. It also keeps local assertions aligned with the implemented non-AST contract. This research pass does not vendor any upstream corpus file.
