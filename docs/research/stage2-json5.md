# JSON5 Stage 2 evidence

## Source status and pinned revisions

| Source | Status and use | Pinned revision | License |
| --- | --- | --- | --- |
| [JSON5 Data Interchange Format](https://spec.json5.org/) | Normative JSON5 specification, version 1.0.0 from March 2018. The JSON5 project calls this the [official specification](https://json5.org/#specification). | Source repository [`json5/json5-spec@d77331d96bc6b74622703e5d009d6124072f04dd`](https://github.com/json5/json5-spec/tree/d77331d96bc6b74622703e5d009d6124072f04dd). Its [README](https://github.com/json5/json5-spec/blob/d77331d96bc6b74622703e5d009d6124072f04dd/README.md) identifies the repository as the specification source. | [MIT](https://spec.json5.org/#license). The notice and permission text must remain in copies or substantial portions. |
| [ECMA-262 Edition 5.1](https://262.ecma-international.org/5.1/) | Normative source for ECMAScript productions that JSON5 imports, including `IdentifierName`, escapes, and numeric literals. The PDF is the definitive ECMA text. | Edition 5.1, June 2011. | ECMA permits copies and explanatory derivative works under the conditions in its [copyright notice](https://262.ecma-international.org/5.1/). Do not redistribute a modified copy as the standard. |
| [`json5/json5-tests`](https://github.com/json5/json5-tests) | JSON5-organization upstream parse corpus. Its README calls the files “Parse Test Cases for JSON5.” It does not claim standards-body approval, completeness, or formal conformance-suite status. | [`ceb24d4080137d70833f86c25659c1331b80a387`](https://github.com/json5/json5-tests/commit/ceb24d4080137d70833f86c25659c1331b80a387) | [MIT](https://github.com/json5/json5-tests/blob/ceb24d4080137d70833f86c25659c1331b80a387/LICENSE.md). Redistribution is allowed if copies retain the copyright and permission notice. |
| [`json5/json5`](https://github.com/json5/json5) | Project reference implementation. Its JavaScript unit tests provide useful supplemental evidence where the standalone corpus is sparse. They are not the formal JSON5 specification. | [`b935d4a280eafa8835e6182551b63809e61243b0`](https://github.com/json5/json5/commit/b935d4a280eafa8835e6182551b63809e61243b0) | [MIT](https://github.com/json5/json5/blob/b935d4a280eafa8835e6182551b63809e61243b0/LICENSE.md). |

Use the JSON5 specification as the acceptance authority. Use `json5-tests` as project-owned evidence, not as the definition of JSON5.

## Stage 2 lexical requirements

### `IdentifierName`

A JSON5 object member name can be a string or a `JSON5Identifier`. The lexical grammar defines `JSON5Identifier` as the ECMAScript 5.1 `IdentifierName` production. See [Objects](https://spec.json5.org/#objects) and [Lexical Grammar](https://spec.json5.org/#lexical-grammar).

ECMAScript 5.1 defines the exact character classes in [section 7.6](https://262.ecma-international.org/5.1/#sec-7.6):

- `IdentifierStart` permits a Unicode letter, `$`, `_`, or a valid `\uHHHH` escape.
- `IdentifierPart` also permits combining marks, decimal digits, connector punctuation, U+200C, and U+200D.
- An escape must decode to a character that is valid at that position.
- Reserved words are still `IdentifierName` values. JSON5 does not apply the narrower ECMAScript `Identifier` restriction to member names.
- ECMA-262 5.1 bases these categories on Unicode 3.0. It permits implementations to recognize later identifier characters.

Stage 2 must decode identifier escapes before it reports or stores the member name. It must reject an invalid start, invalid continuation, malformed escape, or an escape for an illegal character.

The corpus covers ASCII letters, `$`, `_`, digits after the first character, and mixed forms in [`objects/unquoted-keys.json5`](https://github.com/json5/json5-tests/blob/ceb24d4080137d70833f86c25659c1331b80a387/objects/unquoted-keys.json5). It covers a reserved word in [`objects/reserved-unquoted-key.json5`](https://github.com/json5/json5-tests/blob/ceb24d4080137d70833f86c25659c1331b80a387/objects/reserved-unquoted-key.json5). It rejects a numeric start and a symbol in the [`objects`](https://github.com/json5/json5-tests/tree/ceb24d4080137d70833f86c25659c1331b80a387/objects) directory.

Unicode and escaped Unicode member-name fixtures remain under the upstream [`todo`](https://github.com/json5/json5-tests/tree/ceb24d4080137d70833f86c25659c1331b80a387/todo) directory. Thus, the standalone corpus does not establish active coverage for the full production. The reference implementation adds accepted Unicode and escaped names in [`test/parse.js`](https://github.com/json5/json5/blob/b935d4a280eafa8835e6182551b63809e61243b0/test/parse.js). It adds invalid start, continuation, and escape cases in [`test/errors.js`](https://github.com/json5/json5/blob/b935d4a280eafa8835e6182551b63809e61243b0/test/errors.js).

### Strings

The [Strings](https://spec.json5.org/#strings) and [Escapes](https://spec.json5.org/#escapes) clauses require these forms:

- A string can use matching single or double quotes.
- The active quote, reverse solidus, and line terminators must use an escape.
- `\xHH` has exactly two hexadecimal digits. `\uHHHH` has exactly four hexadecimal digits.
- The named escapes include `\b`, `\f`, `\n`, `\r`, `\t`, `\v`, and `\0`. A decimal digit cannot follow `\0`.
- A reverse solidus plus a line-terminator sequence continues a string. The continuation bytes do not become string data.
- A reverse solidus before another permitted character removes the reverse solidus. Escaped digits `1` through `9` are invalid.
- Unescaped U+2028 and U+2029 are valid JSON5 string characters. The specification recommends a parser warning and generator escaping.

The standalone [`strings`](https://github.com/json5/json5-tests/tree/ceb24d4080137d70833f86c25659c1331b80a387/strings) directory covers single quotes, an escaped single quote, an escaped multiline string, and an invalid unescaped multiline string. It does not provide a complete escape matrix. The reference implementation’s [`test/parse.js`](https://github.com/json5/json5/blob/b935d4a280eafa8835e6182551b63809e61243b0/test/parse.js) covers named, hexadecimal, Unicode, line-continuation, identity, U+2028, and U+2029 cases. Its [`test/errors.js`](https://github.com/json5/json5/blob/b935d4a280eafa8835e6182551b63809e61243b0/test/errors.js) covers malformed escapes, numeric escapes, octal escapes, raw newlines, and unterminated strings.

### Comments

The [Comments](https://spec.json5.org/#comments) clause permits `//` and `/* ... */` comments before or after any JSON5 token. A line comment ends at a line terminator or end of input. A block comment ends at the first `*/` and cannot nest. An unterminated block comment is invalid.

The upstream [`comments`](https://github.com/json5/json5-tests/tree/ceb24d4080137d70833f86c25659c1331b80a387/comments) directory covers comments before and after top-level values, comments after array elements, comment markers inside strings, internal asterisks, comment-only documents, and unterminated block comments. It also contains an irregular block-comment boundary case.

### White space and line terminators

The [White Space](https://spec.json5.org/#white-space) clause permits white space before and after any token. Its table includes U+0009, U+000A, U+000B, U+000C, U+000D, U+0020, U+00A0, U+2028, U+2029, U+FEFF, and all other Unicode `Zs` characters.

The standalone corpus has one focused [`misc/valid-whitespace.json5`](https://github.com/json5/json5-tests/blob/ceb24d4080137d70833f86c25659c1331b80a387/misc/valid-whitespace.json5) fixture with a form-feed byte. The [`new-lines`](https://github.com/json5/json5-tests/tree/ceb24d4080137d70833f86c25659c1331b80a387/new-lines) directory covers LF, CR, and CRLF in comments and string continuations. Its [`.gitattributes`](https://github.com/json5/json5-tests/blob/ceb24d4080137d70833f86c25659c1331b80a387/new-lines/.gitattributes) marks these files as binary to prevent newline conversion.

The corpus does not isolate every white-space code point. The reference implementation’s [`test/parse.js`](https://github.com/json5/json5/blob/b935d4a280eafa8835e6182551b63809e61243b0/test/parse.js) covers tab, vertical tab, form feed, space, non-breaking space, BOM, LF, CR, U+2028, U+2029, and U+2003.

### Numbers

The [Numbers](https://spec.json5.org/#numbers) clause permits these forms:

- Decimal integers, fractions, and exponents.
- A leading or trailing decimal point when the complete token remains a numeric literal.
- Lowercase or uppercase exponent markers with an optional exponent sign and required decimal digits.
- Hexadecimal literals with `0x` or `0X` and at least one hexadecimal digit.
- An optional leading `+` or `-` for finite numeric literals.
- `Infinity`, `+Infinity`, `-Infinity`, `NaN`, `+NaN`, and `-NaN`.

The [`numbers`](https://github.com/json5/json5-tests/tree/ceb24d4080137d70833f86c25659c1331b80a387/numbers) directory contains 67 cases. It covers signs, zero and negative zero, leading and trailing decimal points, decimal exponents, hexadecimal forms, infinities, NaN, malformed exponents, empty hexadecimal literals, and disallowed octal forms. This area has the corpus’s strongest standalone coverage.

### Trailing commas

The [Objects](https://spec.json5.org/#objects) and [Arrays](https://spec.json5.org/#arrays) grammars permit one comma after the final member or element. They do not permit a comma in an otherwise empty object or array. They also do not permit array elisions.

The corpus accepts [`arrays/trailing-comma-array.json5`](https://github.com/json5/json5-tests/blob/ceb24d4080137d70833f86c25659c1331b80a387/arrays/trailing-comma-array.json5) and [`objects/trailing-comma-object.json5`](https://github.com/json5/json5-tests/blob/ceb24d4080137d70833f86c25659c1331b80a387/objects/trailing-comma-object.json5). It rejects leading commas, missing separator commas, and lone commas. The array lone-comma case uses [`.js`](https://github.com/json5/json5-tests/blob/ceb24d4080137d70833f86c25659c1331b80a387/arrays/lone-trailing-comma-array.js) because an ECMAScript array elision is not JSON5. The object case uses [`.txt`](https://github.com/json5/json5-tests/blob/ceb24d4080137d70833f86c25659c1331b80a387/objects/lone-trailing-comma-object.txt).

## Upstream corpus structure and limits

At the pinned revision, the repository tree contains 126 files. The extension protocol identifies 114 candidate inputs. The remaining files are eight `.errorSpec` sidecars, two newline-control files, the README, and the license. The [pinned tree](https://github.com/json5/json5-tests/tree/ceb24d4080137d70833f86c25659c1331b80a387) supplies the file manifest.

The corpus [`README.md`](https://github.com/json5/json5-tests/blob/ceb24d4080137d70833f86c25659c1331b80a387/README.md) defines the classification:

| Extension | Upstream meaning | Count at pin |
| --- | --- | ---: |
| `.json` | Valid JSON, and therefore valid JSON5. The upstream method is `JSON.parse()`. | 26 |
| `.json5` | JSON5-only feature that must also be valid ES5. The upstream method is `eval()`. | 57 |
| `.js` | Valid ES5 form that JSON5 explicitly disallows. Expected result is rejection. | 6 |
| `.txt` | Invalid ES5 and invalid JSON5. Expected result is rejection. | 25 |
| `.errorSpec` | Partial diagnostic sidecar with an `at` position, line, column, and message fields. The README does not define this extension. | 8 |

The candidate cases are grouped as follows: arrays 6, comments 13, miscellaneous 5, newlines 6, numbers 67, objects 11, strings 4, and `todo` 2. The repository contains data files and metadata, but no runner or package manifest at this revision.

Two limits require explicit handling:

1. The two Unicode `IdentifierName` cases remain in `todo`. Do not count them as active upstream coverage.
2. [`comments/irregular-block-comment.json`](https://github.com/json5/json5-tests/blob/ceb24d4080137d70833f86c25659c1331b80a387/comments/irregular-block-comment.json) contains a JSON5 block comment. Its `.json` suffix conflicts with the README’s `JSON.parse()` rule. Treat it as valid JSON5-only input or quarantine it from any JSON baseline check.

The `.errorSpec` messages are not normative JSON5 results. The [Parsers](https://spec.json5.org/#parsers) clause requires acceptance of conforming text, but it does not define diagnostic wording or positions.

## Local-ingestion recommendation

Use a pinned snapshot of `json5/json5-tests`, not the moving `master` branch.

1. Fetch commit `ceb24d4080137d70833f86c25659c1331b80a387` from `https://github.com/json5/json5-tests.git`.
2. Copy the fixtures without text conversion into `tests/corpus/json5/json5-tests/`.
3. Preserve `LICENSE.md`, `README.md`, the source URL, and the commit SHA beside the imported snapshot.
4. Preserve the `new-lines` files byte-for-byte. Do not normalize CR, LF, or CRLF.
5. Include `.json` and `.json5` files in the acceptance set. Reclassify `comments/irregular-block-comment.json` as JSON5-only.
6. Include `.js` and `.txt` files in the rejection set.
7. Exclude the `todo/` directory from the executable manifest.
8. Keep `.errorSpec` files as optional upstream metadata. Do not require their parser-specific messages or coordinates.
9. Generate a checked-in manifest with relative path, expected accept/reject result, upstream commit, and file hash.
10. Run every manifest entry through the Stage 2 whole-document API. Require full input consumption for accepted cases.

Add project-owned tests for uncovered normative boundaries when test work starts. The first additions should cover full ES5.1 `IdentifierName`, malformed identifier escapes, every white-space class, and the complete string-escape matrix. Keep those tests separate from the unchanged upstream snapshot.
