# Stage 2 JSONL evidence

## Result

Stage 2 must expose separate JSON Lines and NDJSON profiles. The formats use the same record model but differ at important boundaries.

Use RFC 8259 for the JSON grammar inside each record. Use the JSON Lines documentation for `.jsonl` files. Use NDJSON 1.0.0 for `.ndjson` streams.

No standards body owns a JSONL framing standard. The JSON Lines site is community-maintained primary documentation. NDJSON 1.0.0 is an author-owned core specification, not an IETF or W3C standard. RFC 8259 governs JSON records only. It does not define newline framing.

No official JSONL or NDJSON conformance corpus was found in the owning specification repositories. Use the two de-facto sources below with explicit limits.

## Authority and provenance

| Source | Authority | Evidence | Revision used |
| --- | --- | --- | --- |
| [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259.html) | IETF Standards Track specification for each JSON record | Section 2 defines a JSON text as `ws value ws`. Sections 3 through 7 define values and strings. Sections 8.1 and 9 define UTF-8 and parser obligations. | RFC 8259, December 2017 |
| [JSON Lines documentation](https://github.com/wardi/jsonlines/blob/a8e8671adf470477cd2cc1dfc40c30825f421baa/index.md#L17-L58) | Primary community documentation for the JSON Lines format | It requires UTF-8, one valid JSON value per line, and LF record termination. It permits a missing final terminator. | `wardi/jsonlines` commit `a8e8671adf470477cd2cc1dfc40c30825f421baa` |
| [NDJSON 1.0.0](https://github.com/ndjson/ndjson-spec/blob/8a5a2350ff95fd356993b827f63c5733a9d4f1a6/README.md#L30-L50) | Maintainer-owned core specification for NDJSON stream framing | It defines UTF-8 JSON texts, LF and CRLF delimiters, malformed-text errors, and optional empty-line skipping. | `ndjson/ndjson-spec` commit `8a5a2350ff95fd356993b827f63c5733a9d4f1a6` |
| [`nst/JSONTestSuite`](https://github.com/nst/JSONTestSuite/tree/1ef36fa01286573e846ac449e8683f8833c5b26a) | Community-maintained, de-facto JSON parser corpus | It classifies JSON documents as required accept, required reject, or implementation-defined. It is not JSONL-specific. | Commit `1ef36fa01286573e846ac449e8683f8833c5b26a` |
| [`wbolster/jsonlines` tests](https://github.com/wbolster/jsonlines/blob/43d1a30b9634f8b715b6af3f2473927caa1e704d/tests/test_jsonlines.py) | Upstream tests for a widely used Python implementation | The tests cover malformed records, empty lines, optional skipping, invalid UTF-8, and continued reading. They are not a format conformance suite. | Commit `43d1a30b9634f8b715b6af3f2473927caa1e704d` |

## Governing format rules

### JSON record grammar

RFC 8259 defines a JSON text as `ws value ws`. JSON whitespace includes space, tab, LF, and CR ([RFC 8259, section 2](https://www.rfc-editor.org/rfc/rfc8259.html#section-2)). A JSON value can be an object, array, number, string, `false`, `null`, or `true` ([section 3](https://www.rfc-editor.org/rfc/rfc8259.html#section-3)).

A raw LF or CR cannot occur inside a JSON string. The string grammar permits escaped `\n` and `\r`, but its unescaped range excludes control bytes ([section 7](https://www.rfc-editor.org/rfc/rfc8259.html#section-7)). This distinction keeps escaped newlines inside one record.

RFC 8259 requires UTF-8 for JSON exchanged outside a closed ecosystem. A generator must not add a byte order mark. A parser may ignore a byte order mark for interoperability ([section 8.1](https://www.rfc-editor.org/rfc/rfc8259.html#section-8.1)). The JSON Lines profile is stricter. It says a byte order mark must not occur ([JSON Lines lines 17–33](https://github.com/wardi/jsonlines/blob/a8e8671adf470477cd2cc1dfc40c30825f421baa/index.md#L17-L33)).

### JSON Lines profile

The JSON Lines documentation defines three requirements:

1. Encode the file as UTF-8.
2. Put one valid JSON value on each line. Any JSON value is valid, including `null`.
3. Use LF as the line terminator.

A blank line is not a JSON value and is invalid ([lines 35–41](https://github.com/wardi/jsonlines/blob/a8e8671adf470477cd2cc1dfc40c30825f421baa/index.md#L35-L41)). CRLF is supported because the CR is valid surrounding JSON whitespace ([lines 46–52](https://github.com/wardi/jsonlines/blob/a8e8671adf470477cd2cc1dfc40c30825f421baa/index.md#L46-L52)).

The final JSON value does not require a terminator. The documentation strongly recommends one. If present, the terminator must be the final byte ([lines 54–58](https://github.com/wardi/jsonlines/blob/a8e8671adf470477cd2cc1dfc40c30825f421baa/index.md#L54-L58)).

### NDJSON 1.0.0 profile

Each NDJSON JSON text must conform to RFC 8259. A serializer must follow each text with LF. One CR may precede that LF. A serialized JSON text must not contain LF or CR bytes ([NDJSON lines 30–38](https://github.com/ndjson/ndjson-spec/blob/8a5a2350ff95fd356993b827f63c5733a9d4f1a6/README.md#L30-L38)).

An NDJSON parser must accept LF and CRLF delimiters. It should report an unparsable JSON text. It may ignore empty lines only when it documents that behavior. The option should be user-configurable ([lines 40–44](https://github.com/ndjson/ndjson-spec/blob/8a5a2350ff95fd356993b827f63c5733a9d4f1a6/README.md#L40-L44)).

The serializer rule requires a terminator after every record. The parser section does not state how EOF closes an unterminated final record. Keep this case distinct in parser and serializer tests.

### Stage 2 profiles

| Rule | `jsonl` | `ndjson-strict` | `ndjson-ignore-empty` |
| --- | --- | --- | --- |
| Record JSON grammar | RFC 8259 | RFC 8259 | RFC 8259 |
| Encoding | UTF-8, no BOM | UTF-8 | UTF-8 |
| Delimiters | LF or CRLF | LF or CRLF | LF or CRLF |
| Final record without LF | Accept | Reject as a serialized NDJSON document | Reject as a serialized NDJSON document |
| Empty line | Reject | Reject | Ignore |
| Whitespace-only line | Reject | Reject | Reject unless a separate option documents the extension |
| Malformed record | Reject the document | Reject the document | Reject the document |

The strict NDJSON profile gives the optional empty-line rule a deterministic default. The optional profile tests the permitted extension. Do not make empty-line skipping an undocumented default.

Neither framing source requires at least one record. Accept an empty input as zero records. Mark this behavior as a Stage 2 decision because the sources do not state it directly.

## Boundary and malformed-record coverage

Use exact byte fixtures. Do not normalize line endings before validation.

| Input bytes | JSON Lines | Strict NDJSON | Reason |
| --- | --- | --- | --- |
| empty input | Accept zero records | Accept zero records | Stage 2 empty-stream decision |
| `null\n` | Accept | Accept | Any RFC 8259 value is a record |
| `1\n2\n` | Accept | Accept | Two LF-delimited records |
| `1\r\n2\r\n` | Accept | Accept | Both sources accept CRLF |
| `1\n2` | Accept | Reject serialized form | JSON Lines permits a missing final terminator. NDJSON serialization does not. |
| `1\n\n2\n` | Reject | Reject | JSON Lines rejects blanks. Strict NDJSON does not enable the optional skip. |
| `1\n\n2\n` with `ndjson-ignore-empty` | Not applicable | Accept | NDJSON permits documented empty-line skipping |
| `1\n \t\n2\n` | Reject | Reject | Whitespace alone is not a JSON value. NDJSON only names empty lines. |
| `1\r2\n` | Reject | Reject | A bare CR is not a record delimiter |
| `"a\\nb"\n` | Accept | Accept | The record contains an escaped LF, not an LF byte |
| `"a` + LF + `b"` + LF | Reject | Reject | The LF splits records and is illegal inside a JSON string |
| `1e\n2\n` | Reject | Reject | The first record is malformed JSON |
| `1\n ` | Reject | Reject | The final physical line contains only whitespace |
| UTF-8 BOM + `1\n` | Reject | Reject in the strict profile | JSON Lines forbids a BOM. Strict NDJSON uses the same interoperable byte policy. |
| invalid UTF-8 + LF | Reject | Reject | Both profiles require UTF-8 |

For malformed input, document validity and recovery as separate results. A reader may continue at the next delimiter for diagnostics. Continued reading must not make the full document valid.

## Source coordinates

The specifications give little diagnostic guidance. JSON Lines says that the first physical line is “line 1” and the first value is “value 1” ([lines 76–77](https://github.com/wardi/jsonlines/blob/a8e8671adf470477cd2cc1dfc40c30825f421baa/index.md#L76-L77)). NDJSON 1.0.0 does not define line, column, or byte offsets.

The `wbolster/jsonlines` implementation provides useful de-facto evidence. Its `InvalidLineError` stores the original line and a one-based `lineno` ([source lines 107–132](https://github.com/wbolster/jsonlines/blob/43d1a30b9634f8b715b6af3f2473927caa1e704d/jsonlines/jsonlines.py#L107-L132)). Its reader obtains the physical line number before it skips or parses a line ([lines 294–323](https://github.com/wbolster/jsonlines/blob/43d1a30b9634f8b715b6af3f2473927caa1e704d/jsonlines/jsonlines.py#L294-L323)). This behavior is implementation evidence, not a governing rule.

Use this Stage 2 coordinate contract:

1. Keep a zero-based absolute byte offset as the canonical coordinate.
2. Report a one-based physical line and a one-based byte column.
3. Count empty lines even when an NDJSON option ignores them.
4. Treat CRLF as one delimiter with a two-byte span.
5. Start the next line after the LF byte.
6. Keep offsets against the original bytes. Do not compute them after CRLF conversion or UTF-8 replacement.
7. Map a record-relative JSON error at offset `p` to `record_start + p`.
8. Point an incomplete record at its payload end. This position is before its delimiter or at EOF.
9. Point invalid UTF-8 at the first invalid byte.
10. Keep the physical line separate from a successful-value index. A malformed or skipped line must not change later source lines.

A byte column is not a Unicode character column. If the public API adds display columns later, give them a different name.

## De-facto corpora

### Official-suite status

The pinned JSON Lines repository contains website source and examples. The pinned NDJSON repository contains `README.md`, `index.md`, and an image. Neither repository contains a valid/invalid fixture tree or a conformance manifest. Their examples are specification examples, not a conformance corpus.

### JSONTestSuite

Use [`nst/JSONTestSuite/test_parsing`](https://github.com/nst/JSONTestSuite/tree/1ef36fa01286573e846ac449e8683f8833c5b26a/test_parsing) as the de-facto JSON-record grammar corpus. The project describes itself as a comprehensive RFC 8259 parser suite. Its README defines these filename classes ([README lines 1–24](https://github.com/nst/JSONTestSuite/blob/1ef36fa01286573e846ac449e8683f8833c5b26a/README.md#L1-L24)):

- `y_` means every conforming parser must accept the file.
- `n_` means every conforming parser must reject the file.
- `i_` means a parser may accept or reject the file.

The corpus covers root values, arrays, objects, numbers, strings, escapes, Unicode, nesting, whitespace, truncation, extra tokens, and malformed structure. The separate `test_transform/` directory covers values that parsers can transform differently. It does not define accept or reject results.

This corpus is community-maintained. It is not official JSONL or NDJSON data. Many files contain complete JSON documents with line breaks. Such files are valid JSON but are not one JSONL record.

For local JSONL use, select only `y_` and `n_` files that contain no raw LF or CR. Append one chosen delimiter after the exact source bytes. Use `y_` as valid record cases and `n_` as invalid record cases. Keep `i_` outside required conformance.

This subset tests record grammar only. It does not test blank lines, final terminators, CRLF framing, recovery, or source coordinates.

### `wbolster/jsonlines` implementation tests

The single upstream test module contains inline cases rather than a fixture tree. Relevant cases include:

- malformed JSON and preservation of the bad line ([lines 113–126](https://github.com/wbolster/jsonlines/blob/43d1a30b9634f8b715b6af3f2473927caa1e704d/tests/test_jsonlines.py#L113-L126));
- optional continuation after a malformed line ([lines 128–133](https://github.com/wbolster/jsonlines/blob/43d1a30b9634f8b715b6af3f2473927caa1e704d/tests/test_jsonlines.py#L128-L133));
- strict empty-line errors and optional empty-line skipping ([lines 135–162](https://github.com/wbolster/jsonlines/blob/43d1a30b9634f8b715b6af3f2473927caa1e704d/tests/test_jsonlines.py#L135-L162));
- invalid UTF-8 errors ([lines 146–150](https://github.com/wbolster/jsonlines/blob/43d1a30b9634f8b715b6af3f2473927caa1e704d/tests/test_jsonlines.py#L146-L150)).

The implementation treats whitespace-only lines as empty when `skip_empty` is enabled ([source lines 294–301](https://github.com/wbolster/jsonlines/blob/43d1a30b9634f8b715b6af3f2473927caa1e704d/jsonlines/jsonlines.py#L294-L301)). That behavior extends NDJSON's explicit empty-line example. Keep it in an implementation-compatibility group.

Do not import all expected results as syntax rules. This library permits BOM handling ([tests lines 49–83](https://github.com/wbolster/jsonlines/blob/43d1a30b9634f8b715b6af3f2473927caa1e704d/tests/test_jsonlines.py#L49-L83)) that strict JSON Lines forbids. It also treats JSON `null` as invalid by default unless the caller enables `allow_none` ([source lines 282–288](https://github.com/wbolster/jsonlines/blob/43d1a30b9634f8b715b6af3f2473927caa1e704d/jsonlines/jsonlines.py#L282-L288)). JSON Lines explicitly permits `null`.

The module has no explicit CRLF case and no byte-column assertion. Add project-authored cases for those gaps.

## Licensing and redistribution

### Specifications

RFC 8259 is copyright 2017 IETF Trust and its authors. It is subject to BCP 78 and the IETF Trust Legal Provisions. Extracted code components require the Simplified BSD notice ([RFC copyright notice](https://www.rfc-editor.org/rfc/rfc8259.html#copyright)). Cite the RFC. Do not copy its full text into the corpus.

The NDJSON source says the authors own its copyright and permit commercial and non-commercial use ([lines 52–54](https://github.com/ndjson/ndjson-spec/blob/8a5a2350ff95fd356993b827f63c5733a9d4f1a6/README.md#L52-L54)). The pinned repository has no separate license file. That sentence does not state standard terms for modification and redistribution. Cite the source, but do not vendor its text or image without a license review.

The pinned JSON Lines repository has no `LICENSE` file or redistribution grant. Its footer identifies Ian Ward as the page maintainer ([pinned footer](https://github.com/wardi/jsonlines/blob/a8e8671adf470477cd2cc1dfc40c30825f421baa/_includes/footer.html)). Cite the requirements, but do not copy website files or examples into the test corpus without permission.

### Corpora

JSONTestSuite uses the MIT License. Redistribution and modification are permitted when copies or substantial portions retain the copyright and permission notice ([pinned license](https://github.com/nst/JSONTestSuite/blob/1ef36fa01286573e846ac449e8683f8833c5b26a/LICENSE)). Local extraction is permitted under those terms.

`wbolster/jsonlines` uses the three-clause BSD License. Source redistribution must retain the copyright notice, conditions, and disclaimer. The author and contributor names cannot endorse derived products without permission ([pinned license](https://github.com/wbolster/jsonlines/blob/43d1a30b9634f8b715b6af3f2473927caa1e704d/LICENSE.rst)). Local extraction is permitted under those terms.

## Local-ingestion recommendation

Do not vendor either upstream repository in this research change. Use a later, reviewed ingestion change with this layout:

```text
tests/corpora/jsonl/
  manifest.json
  project-boundaries/
    jsonl/
    ndjson-strict/
    ndjson-ignore-empty/
    diagnostics/
  JSONTestSuite/1ef36fa01286573e846ac449e8683f8833c5b26a/
    LICENSE
    valid-record/
    invalid-record/
  wbolster-jsonlines/43d1a30b9634f8b715b6af3f2473927caa1e704d/
    LICENSE.rst
    compatibility/
```

Use this ingestion procedure:

1. Fetch each upstream repository at its full commit ID.
2. Verify the fetched commit before extraction.
3. Preserve source bytes. Do not parse and reserialize a fixture.
4. Copy the applicable upstream license into each redistributed corpus directory.
5. Record the repository, commit, source path, source case name, license, original hash, and output hash.
6. Select only line-break-free `y_` and `n_` JSONTestSuite files for record cases.
7. Append LF in one generated group and CRLF in a second generated group.
8. Record the append operation in the manifest. Keep the upstream hash for the unmodified record bytes.
9. Exclude `i_` files from required conformance. Keep them in an optional interoperability group if needed.
10. Extract only relevant `wbolster` inline bytes. Mark each case as implementation evidence.
11. Do not import its BOM or `null` result as strict JSONL behavior.
12. Create the framing and coordinate matrix locally. Mark each fixture as project-authored from the cited specifications.
13. Store expected validity per profile. Do not use one result for all variants.
14. Store expected `byte_offset`, `line`, and `byte_column` only when the specification-derived fixture has an unambiguous failure point.
15. Keep recovery expectations separate from validity expectations.

The manifest should use explicit fields such as `profile`, `expected_valid`, `recovery`, `byte_offset`, `line`, `byte_column`, `source_url`, `source_revision`, `source_case`, `license`, `source_sha256`, `transform`, and `fixture_sha256`.

This plan gives Stage 2 broad JSON grammar coverage without mislabeling JSONTestSuite as JSONL authority. The project-authored matrix supplies the missing framing and coordinate coverage.