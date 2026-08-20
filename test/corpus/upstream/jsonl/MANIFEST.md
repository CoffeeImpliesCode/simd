# JSONL and NDJSON upstream corpus manifest

## Scope

This manifest defines reproducible inputs for JSONL and NDJSON stream tests. It does not vendor upstream corpus payloads.

Tests must read checked-in files only. Tests must not fetch a repository, specification, or other network resource.

RFC 8259 defines the JSON grammar for one record. It does not define record framing.

## Pinned sources

| ID | Pinned source | Corpus use | License and redistribution policy |
| --- | --- | --- | --- |
| `json-lines-doc` | [`wardi/jsonlines` commit `a8e8671adf470477cd2cc1dfc40c30825f421baa`, `index.md`](https://github.com/wardi/jsonlines/blob/a8e8671adf470477cd2cc1dfc40c30825f421baa/index.md#L17-L58) | Primary JSON Lines framing reference | The repository has no `LICENSE` file or redistribution grant. Cite it only. Do not copy its files or examples. |
| `ndjson-1.0.0` | [`ndjson/ndjson-spec` commit `8a5a2350ff95fd356993b827f63c5733a9d4f1a6`, `README.md`](https://github.com/ndjson/ndjson-spec/blob/8a5a2350ff95fd356993b827f63c5733a9d4f1a6/README.md#L30-L54) | Primary NDJSON 1.0.0 framing reference | The source permits commercial and noncommercial use. It has no standard redistribution license. Cite it only. Do not copy its text or image. |
| `json-test-suite` | [`nst/JSONTestSuite` commit `1ef36fa01286573e846ac449e8683f8833c5b26a`, `test_parsing/`](https://github.com/nst/JSONTestSuite/tree/1ef36fa01286573e846ac449e8683f8833c5b26a/test_parsing) | JSON record grammar cases | MIT. Keep the pinned [`LICENSE`](https://github.com/nst/JSONTestSuite/blob/1ef36fa01286573e846ac449e8683f8833c5b26a/LICENSE) with copied or derived files. |
| `wbolster-jsonlines` | [`wbolster/jsonlines` commit `43d1a30b9634f8b715b6af3f2473927caa1e704d`](https://github.com/wbolster/jsonlines/tree/43d1a30b9634f8b715b6af3f2473927caa1e704d) | Implementation compatibility cases and diagnostic evidence | BSD-3-Clause. Keep the pinned [`LICENSE.rst`](https://github.com/wbolster/jsonlines/blob/43d1a30b9634f8b715b6af3f2473927caa1e704d/LICENSE.rst) with copied or derived files. |
| `rfc-8259` | [RFC 8259, December 2017](https://www.rfc-editor.org/rfc/rfc8259.html) | JSON record grammar and UTF-8 reference | Copyright 2017 IETF Trust and the named authors. Cite the RFC. Do not copy its full text. |

Each repository source uses a full Git commit as its immutable pin. A Git commit identifies a tree, not one artifact.

The importer must record a SHA-256 hash for every copied source file. It must also record a SHA-256 hash for every derived fixture.

## Local profiles

The importer must assign each fixture to one or more named profiles. It must not use one expected result for all profiles.

| Rule | `jsonl` | `jsonlines-permissive` | `ndjson-strict` | `ndjson-ignore-empty` |
| --- | --- | --- | --- | --- |
| Record grammar | RFC 8259 | RFC 8259 | RFC 8259 | RFC 8259 |
| Encoding | UTF-8, no BOM | UTF-8, no BOM | UTF-8, no BOM | UTF-8, no BOM |
| Accepted delimiter | LF or CRLF | LF or CRLF | LF or CRLF | LF or CRLF |
| Final record without LF | Accept | Accept | Reject as a serialized document | Reject as a serialized document |
| Empty physical line | Reject | Ignore | Reject | Ignore |
| Whitespace-only physical line | Reject | Ignore | Reject | Reject |
| Malformed record | Reject the document | Reject the document | Reject the document | Reject the document |

### Blank-line distinction

The primary JSON Lines documentation does not permit a blank line. A blank line is not a JSON value.

Some JSON Lines libraries give permissive blank-line guidance. The `wbolster/jsonlines` implementation can skip empty and whitespace-only lines.

This manifest isolates that behavior in `jsonlines-permissive`. It is implementation compatibility behavior, not a JSON Lines format rule.

NDJSON permits a parser to ignore empty lines only through a documented, configurable option. The `ndjson-strict` profile disables that option.

The `ndjson-ignore-empty` profile covers the permitted option. It ignores zero-byte physical lines only. It does not ignore whitespace-only lines.

## Classification policy

### JSONTestSuite

Use `test_parsing/` as a de-facto JSON record grammar corpus. It is not a JSONL or NDJSON conformance corpus.

1. Import `y_` files as required-accept JSON record cases.
2. Import `n_` files as required-reject JSON record cases.
3. Exclude `i_` files from required conformance.
4. Exclude a source file that contains a raw LF or CR byte.
5. Preserve each selected source file without changes under `raw/`.
6. Derive one LF fixture and one CRLF fixture from each selected file.
7. Append only the selected delimiter. Do not parse or reserialize the source bytes.
8. Keep the source classification separate from the framing classification.

An `i_` file can enter a later optional interoperability group. It must not change a required result.

### `wbolster/jsonlines`

Use `tests/test_jsonlines.py` and `jsonlines/jsonlines.py` as implementation evidence. Do not treat their results as format rules.

Relevant cases cover malformed records, empty-line skipping, invalid UTF-8, source line numbers, and recovery after an error.

Keep permissive BOM handling in the compatibility group. Keep the default rejection of JSON `null` out of strict results.

### Project-authored boundaries

Create the framing and chunk-boundary fixtures from byte literals in the importer. Mark their origin as `project-authored`.

Each project-authored case must cite the applicable pinned framing source. It must also state the local policy when a source is silent.

## Boundary classes

The corpus must cover these exact byte classes. The notation `BOM` means the UTF-8 bytes `EF BB BF`.

| Class | Representative bytes | `jsonl` | `ndjson-strict` | Purpose |
| --- | --- | --- | --- | --- |
| Empty stream | empty byte slice | Accept zero records | Accept zero records | Local empty-stream policy |
| Scalar record | `null\n` | Accept | Accept | Any RFC 8259 value is a record |
| Multiple LF records | `1\n2\n` | Accept | Accept | LF framing |
| Multiple CRLF records | `1\r\n2\r\n` | Accept | Accept | CRLF framing |
| Unterminated final record | `1\n2` | Accept | Reject | Profile-specific final terminator |
| Empty physical line | `1\n\n2\n` | Reject | Reject | Strict blank-line behavior |
| Whitespace-only line | `1\n \t\n2\n` | Reject | Reject | JSON whitespace is not a JSON value |
| Bare CR | `1\r2\n` | Reject | Reject | A bare CR is not a delimiter |
| Escaped newline | `"a\\nb"\n` | Accept | Accept | An escape does not split a record |
| Raw newline in string | `"a` + LF + `b"` + LF | Reject | Reject | A raw control byte splits malformed records |
| Malformed JSON | `1e\n2\n` | Reject | Reject | Record grammar failure |
| Trailing physical line | `1\n ` | Reject | Reject | Whitespace after a delimiter forms another line |
| BOM prefix | `BOM` + `1\n` | Reject | Reject | Strict interoperable byte policy |
| Invalid UTF-8 | invalid UTF-8 + LF | Reject | Reject | Encoding failure |

Also classify `1\n\n2\n` as accepted by `jsonlines-permissive` and `ndjson-ignore-empty`.

Classify `1\n \t\n2\n` as accepted by `jsonlines-permissive` only. This case distinguishes library behavior from NDJSON empty-line guidance.

For malformed input, record validity and recovery as separate results. Recovery must not make a complete document valid.

## Chunk-boundary coverage

The importer must preserve one canonical byte fixture for each boundary case. Chunk plans describe views of those bytes.

1. Replay every small fixture with a split at each byte offset.
2. Include zero-length chunks before, between, and after nonempty chunks.
3. Split CRLF between CR and LF.
4. Split a backslash escape after the backslash.
5. Split a multibyte UTF-8 sequence after each byte.
6. Split immediately before and after each record delimiter.
7. Split JSON numbers, literals, strings, and structural tokens.
8. Use fixed chunk sizes 1, 2, 3, 7, 15, 16, 17, 31, 32, 33, 63, 64, and 65 for larger fixtures.
9. Include a final chunk that ends without a delimiter for the JSON Lines profile.
10. Keep expected offsets relative to the original byte fixture.

A streaming test must not join or normalize chunks before it calls the streaming API.

## Raw-byte layout

A reviewed importer must create this layout later. This change creates only this manifest.

```text
test/corpus/upstream/jsonl/
  MANIFEST.md
  CASES.tsv
  raw/
    json-test-suite/1ef36fa01286573e846ac449e8683f8833c5b26a/
      LICENSE
      test_parsing/<source-name>
    wbolster-jsonlines/43d1a30b9634f8b715b6af3f2473927caa1e704d/
      LICENSE.rst
      tests/test_jsonlines.py
      jsonlines/jsonlines.py
  fixtures/
    json-record/lf/{accept,reject}/<source-name>.jsonl
    json-record/crlf/{accept,reject}/<source-name>.jsonl
    boundaries/jsonl/<case-name>.bin
    boundaries/jsonlines-permissive/<case-name>.bin
    boundaries/ndjson-strict/<case-name>.bin
    boundaries/ndjson-ignore-empty/<case-name>.bin
    compatibility/wbolster/<case-name>.bin
  chunks/<case-name>.tsv
```

Store raw files as bytes. Do not convert line endings, replace invalid UTF-8, decompress into the same path, or rewrite JSON.

`CASES.tsv` must contain these columns:

```text
fixture_path	profile	expected_valid	recovery	byte_offset	line	byte_column	source_id	source_url	source_revision	source_path	source_case	license	source_sha256	transform	fixture_sha256
```

Use an empty field when a coordinate does not apply. Use lowercase hexadecimal SHA-256 values.

The `transform` field must fully describe an append operation. Use `none`, `append-lf`, or `append-crlf` for upstream record cases.

## Importer procedure

Run this procedure only as an explicit corpus maintenance action. Never run it from a build or test.

1. Create a new temporary directory outside `test/corpus/upstream/jsonl/`.
2. Clone `https://github.com/nst/JSONTestSuite.git` without a moving branch dependency.
3. Check out detached commit `1ef36fa01286573e846ac449e8683f8833c5b26a`.
4. Clone `https://github.com/wbolster/jsonlines.git` without a moving branch dependency.
5. Check out detached commit `43d1a30b9634f8b715b6af3f2473927caa1e704d`.
6. Confirm that each checked-out `HEAD` equals its full pinned commit.
7. Copy each required license and selected source file with a byte-preserving file copy.
8. Calculate `source_sha256` from each copied raw file before any transform.
9. Select line-break-free JSONTestSuite `y_` and `n_` files according to the classification policy.
10. Sort selected source paths by raw UTF-8 path bytes.
11. Append LF or CRLF to a new fixture. Do not change the source bytes before the append.
12. Generate project boundary files from the exact byte forms in this manifest.
13. Extract only reviewed `wbolster` cases. Record the test function and literal ordinal in `source_case`.
14. Calculate `fixture_sha256` after the complete transform.
15. Write one `CASES.tsv` row for each profile result. Sort rows by `fixture_path`, then by `profile`.
16. Write chunk plans with zero-based half-open byte ranges into each canonical fixture.
17. Compare all generated paths and hashes with the reviewed import change before check-in.
18. Remove the temporary clones after review.

Do not bulk-copy either repository. Do not import generated caches, Git metadata, `i_` cases, transform fixtures, or unrelated tests.

A later import change must include the exact importer version in its review record. A changed upstream commit requires a separate manifest update and license review.
