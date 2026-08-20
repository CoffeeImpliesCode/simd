# Stage 2 JSONC evidence

## Result

Use a **strict JSON plus comments** profile for Stage 2 JSONC.

This profile uses the JSON grammar from [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259.html). It adds JavaScript line and block comments only. It rejects trailing commas, empty input, and all other JSON5 extensions.

JSONC does not have a standards-body specification in the sources reviewed here. Microsoft owns the main documentation and implementation used for this profile. The corpus below is a de-facto implementation suite, not an official conformance suite.

## Authority and provenance

| Source | Authority | Evidence | Revision used |
| --- | --- | --- | --- |
| [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259.html) | IETF Standards Track specification for the base JSON grammar | Sections 2 through 7 define JSON texts, objects, arrays, numbers, strings, and whitespace. | RFC 8259, December 2017 |
| [VS Code JSON with Comments documentation](https://github.com/microsoft/vscode-docs/blob/670dd5bde48e6479d53dfd1c5850c727434fda74/docs/languages/json.md#L44-L48) | Owning product documentation for the `jsonc` language mode | It names `jsonc`, permits `//` and `/* */` comments, and describes trailing commas as accepted with a warning. | `microsoft/vscode-docs` commit `670dd5bde48e6479d53dfd1c5850c727434fda74` |
| [`microsoft/node-jsonc-parser`](https://github.com/microsoft/node-jsonc-parser/tree/37e207ed23f544efc33a1893f21e0bf10b250df0) | Microsoft-owned reference implementation and de-facto behavioral reference | The README defines JSONC as JSON with JavaScript-style comments. The package metadata identifies Microsoft as the author. | Commit `37e207ed23f544efc33a1893f21e0bf10b250df0`, package version `4.0.0-next.2` |
| [JSON5 specification 1.0.0](https://spec.json5.org/#summary-of-features) | Owning specification for JSON5, used only to define the exclusion boundary | The feature summary lists the syntax that JSON5 adds beyond JSON. | Version 1.0.0, March 2018 |

The `node-jsonc-parser` README calls JSONC “JSON with JavaScript style comments.” It also describes a fault-tolerant parser rather than a normative grammar ([README lines 9–18](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/README.md#L9-L18)). Its package metadata names Microsoft Corporation, the repository, and the MIT license ([package.json lines 13–18](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/package.json#L13-L18)).

## Stage 2 conformance profile

### Accepted syntax

A conforming input must first satisfy RFC 8259. The parser then treats these forms as trivia between JSON tokens:

- A line comment starts with `//` and continues to the next line ending or end of input.
- A block comment starts with `/*` and ends with the next `*/`.
- Comments can occur before or after a root value. They can also occur between object, array, name, value, and separator tokens.
- Comment markers inside a double-quoted string remain string data.

The upstream scanner tests cover line comments, block comments, line endings inside block comments, unterminated block comments, and a lone slash ([`json.test.ts` lines 145–157](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/src/test/json.test.ts#L145-L157)). Parser cases place comments after a root number and before an object value ([lines 240–268](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/src/test/json.test.ts#L240-L268)). Visitor cases place both comment forms around object tokens ([lines 539–572](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/src/test/json.test.ts#L539-L572)).

### Parser options and defaults

The public API exposes `disallowComments`, `allowTrailingComma`, and `allowEmptyContent` ([`main.ts` lines 231–235](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/src/main.ts#L231-L235)). The implementation sets `allowTrailingComma` to `false` by default ([`parser.ts` lines 22–25](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/src/impl/parser.ts#L22-L25)). It reports a comment-token error when `disallowComments` is true ([lines 434–469](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/src/impl/parser.ts#L434-L469)).

Use these Stage 2 settings:

| Option | Stage 2 value | Result |
| --- | --- | --- |
| Comments | allowed | Accept `//` and `/* */` as trivia. |
| Trailing comma | rejected | Preserve the reference parser default. |
| Empty content | rejected | Preserve the reference parser default and RFC 8259 root-value requirement. |
| Error recovery | not conformance | Any reported syntax error makes the input invalid, even if recovery returns a value. |

The upstream option tests prove the important split. Default parsing rejects trailing commas. `allowTrailingComma: true` accepts them ([`json.test.ts` lines 308–321](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/src/test/json.test.ts#L308-L321)). `disallowComments: true` changes a comment from valid trivia to an error ([lines 299–306](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/src/test/json.test.ts#L299-L306)).

### VS Code variant

VS Code uses a more permissive editor policy. Its `jsonc` mode accepts trailing commas but displays a warning ([VS Code documentation](https://github.com/microsoft/vscode-docs/blob/670dd5bde48e6479d53dfd1c5850c727434fda74/docs/languages/json.md#L44-L48)).

Do not use that warning policy as Stage 2 acceptance behavior. Stage 2 uses the stricter default of `node-jsonc-parser`. A future VS Code-compatible mode must be a separate option or variant.

## JSONC is not JSON5

JSON5 is a larger language. Its official feature summary permits unquoted identifier keys, single-quoted strings, line continuations, extra escapes, hexadecimal numbers, leading or trailing decimal points, signed numbers, `Infinity`, `NaN`, extra whitespace, comments, and trailing commas ([JSON5 specification, section 1.1](https://spec.json5.org/#summary-of-features)).

Strict Stage 2 JSONC accepts only the comment feature from that list. It must reject these representative JSON5 forms:

| JSON5 form | Example | Strict JSONC result |
| --- | --- | --- |
| Unquoted property name | `{answer: 42}` | Reject |
| Single-quoted string | `{'answer': 'yes'}` | Reject |
| Hexadecimal number | `0x2a` | Reject |
| Leading plus | `+1` | Reject |
| Leading or trailing decimal point | `.5`, `5.` | Reject |
| Non-finite number | `NaN`, `Infinity`, `-Infinity` | Reject |
| JSON5 string escape | `"\x41"`, `"\v"` | Reject |
| Escaped line continuation | A string with a backslash immediately before a line ending | Reject |
| Extra JSON5 whitespace | U+00A0 between tokens | Reject |
| Trailing comma | `{"a": 1,}` | Reject in the strict profile |

The upstream JSONC scanner rejects `\v`, rejects `.0` as a number, tokenizes leading-zero numbers separately, and accepts only lowercase JSON keywords ([`json.test.ts` lines 160–219](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/src/test/json.test.ts#L160-L219)). These cases support the strict boundary.

## De-facto corpus

### Source and structure

Use [`microsoft/node-jsonc-parser/src/test`](https://github.com/microsoft/node-jsonc-parser/tree/37e207ed23f544efc33a1893f21e0bf10b250df0/src/test) as the de-facto upstream corpus. Pin commit `37e207ed23f544efc33a1893f21e0bf10b250df0`. The JSON grammar cases are inline TypeScript strings in [`src/test/json.test.ts`](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/src/test/json.test.ts). The file blob at this revision is `f6c7601da1e944b5d215cbf5e603838b684b76b3`.

The directory does not provide a standalone valid/invalid fixture tree or a conformance manifest. It contains these implementation test files:

- `json.test.ts` covers scanning, parsing, trees, visitors, locations, comments, recovery, and parser options.
- `format.test.ts` covers formatting.
- `edit.test.ts` covers document edits.
- `string-intern.test.ts` covers string interning.

Only `json.test.ts` is a direct Stage 2 syntax source. Formatting, editing, location, and interning cases do not define input conformance.

### Relevant valid coverage

The inline cases cover these accepted inputs:

- All JSON structural tokens and lowercase literal names.
- Root literals, objects, arrays, nesting, numbers, escapes, and Unicode string content.
- Line comments and block comments.
- Comments before a value, after a value, and between structural tokens.
- CR, LF, and CRLF handling in trivia and comments.
- Trailing commas only under the explicit permissive option.

The valid helper requires an empty error list and an equal recovered value ([`json.test.ts` lines 35–41](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/src/test/json.test.ts#L35-L41)). This rule maps cleanly to an accept case plus an optional semantic-value check.

### Relevant invalid coverage

The inline cases cover these rejected inputs:

- Unterminated comments and strings.
- Invalid escapes and control characters in strings.
- Invalid words, symbols, number starts, and number endings.
- Missing commas, colons, names, values, and closing delimiters.
- Extra commas and default-profile trailing commas.
- Empty input and multiple root values.
- Comments when `disallowComments` is true.

The invalid helper requires one or more errors. It also checks the value produced by recovery ([`json.test.ts` lines 43–49](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/src/test/json.test.ts#L43-L49)). Most invalid cases do not require an exact diagnostic code or offset. Some tree and visitor cases do require exact diagnostics.

### Corpus limits

This suite tests a fault-tolerant JavaScript parser. It is not an exhaustive, language-neutral conformance suite.

Inputs are JavaScript strings. The suite therefore does not establish raw UTF-8 decoding behavior by itself. It also mixes grammar tests with recovery, tree, visitor, and editor API behavior. The malformed visitor test explicitly says its callback sequence depends on implementation details ([`json.test.ts` lines 574–576](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/src/test/json.test.ts#L574-L576)). Do not copy that callback sequence into Stage 2 conformance requirements.

## Licensing and redistribution

`node-jsonc-parser` uses the MIT License. The license permits use, copying, modification, publication, distribution, sublicensing, and sale. Redistributed copies or substantial portions must include the copyright and permission notice ([upstream license lines 5–13](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/LICENSE.md#L5-L13)). The test source also carries a Microsoft MIT header.

Local redistribution of extracted fixtures is permitted under those terms. Keep the upstream `LICENSE.md`, the copyright notice, the commit ID, and source links with the imported corpus.

The VS Code documentation repository licenses documentation under CC BY 3.0 US and code under MIT ([`vscode-docs/LICENSE.md`](https://github.com/microsoft/vscode-docs/blob/670dd5bde48e6479d53dfd1c5850c727434fda74/LICENSE.md)). This evidence document cites that documentation but does not propose copying it into the corpus.

The JSON5 specification source uses MIT ([`json5/json5-spec` license](https://github.com/json5/json5-spec/blob/master/LICENSE)). It serves only as boundary evidence. Do not mix JSON5 implementation cases into the JSONC corpus.

## Local-ingestion recommendation

Do not vendor the upstream repository without a review. Import a small, auditable derivative corpus from the pinned test source.

1. Create `tests/corpora/jsonc/node-jsonc-parser/37e207ed23f544efc33a1893f21e0bf10b250df0/` in the later ingestion change.
2. Copy the upstream `LICENSE.md` into that directory.
3. Add a manifest with the upstream repository URL, commit ID, source blob ID, extraction tool revision, and fixture hashes.
4. Evaluate TypeScript string literals with a pinned parser. Do not extract them with a regular expression.
5. Encode each evaluated string as UTF-8 bytes. Preserve explicit CR, LF, CRLF, NUL, and Unicode content.
6. Store one input per file under `valid/`, `invalid/`, `scanner/`, or `diagnostic/`.
7. Record `source_url`, source lines, parser options, expected validity, expected error presence, and optional recovered value for each case.
8. Classify default-option `assertValidParse` cases as strict-profile valid cases.
9. Classify default-option `assertInvalidParse` cases as strict-profile invalid cases.
10. Keep `allowTrailingComma: true` cases in a separate `variant-vscode-trailing-comma/` group. Do not run them as strict-profile valid cases.
11. Keep `disallowComments: true` cases as JSON-mode option cases. Do not run them as JSONC invalid cases without that option.
12. Import exact diagnostic codes and offsets only when the upstream test asserts them.
13. Exclude formatting, editing, location, tree-shape, visitor-order, and interning assertions from syntax conformance.
14. Add separate local boundary cases for each JSON5-only feature in the table above. Mark them as project-authored, not upstream JSONC cases.

The Stage 2 harness must treat any syntax diagnostic as rejection. It must not use the recovered value as proof of validity. This rule matches the upstream helper contract and prevents fault-tolerant recovery from widening the language.
