# JSON5 upstream corpus manifest

## Source pin

- Upstream repository: <https://github.com/json5/json5-tests.git>
- Upstream description: parse test cases maintained by the JSON5 project
- Pinned revision: `ceb24d4080137d70833f86c25659c1331b80a387`
- Pinned tree: <https://github.com/json5/json5-tests/tree/ceb24d4080137d70833f86c25659c1331b80a387>
- Source form: a Git tree, not a single release artifact

The commit ID is the immutable source pin. Do not import from a branch, tag, or unpinned archive URL.

The JSON5 specification defines the language. This upstream repository supplies useful test candidates, but it is not a formal conformance suite.

## License

The pinned repository uses the MIT License. Its `LICENSE.md` file contains the copyright notice and permission terms.

The license permits use, copy, modification, publication, distribution, sublicensing, and sale. Copies or substantial portions must retain the copyright and permission notice.

Preserve the upstream `LICENSE.md` file in every imported raw snapshot. Keep project-owned cases outside the raw snapshot to make the license boundary clear.

## Corpus structure

The pinned tree groups cases under these directories:

- `arrays/`
- `comments/`
- `misc/`
- `new-lines/`
- `numbers/`
- `objects/`
- `strings/`
- `todo/`

The upstream `README.md` assigns an expected result by file extension. An `.errorSpec` sidecar can provide parser-specific diagnostic metadata.

The `new-lines/` directory contains deliberate LF, CR, and CRLF byte sequences. Its `.gitattributes` file marks fixtures as binary to prevent newline conversion.

## Candidate classification

Classify each imported path before a test uses it. The upstream extension supplies the initial classification, not an automatic Stage2 test assignment.

| Path or extension | Upstream meaning | Local candidate class |
| --- | --- | --- |
| `*.json` | Valid JSON and valid JSON5 | `json-accept`, unless an exception below applies |
| `*.json5` | Valid JSON5 with a JSON5-only feature | `json5-accept` |
| `*.js` | Valid ES5 syntax that JSON5 rejects | `json5-reject` |
| `*.txt` | Invalid ES5 and invalid JSON5 | `json5-reject` |
| `*.errorSpec` | Optional expected diagnostic data | `diagnostic-metadata` |
| `todo/**` | Incomplete or inactive upstream coverage | `excluded-todo` |
| `README.md`, `LICENSE.md`, `.gitattributes` | Provenance, terms, and byte-handling controls | `source-metadata` |

`comments/irregular-block-comment.json` contains a JSON5 block comment despite its `.json` suffix. Classify this case as `json5-accept`, or quarantine it from strict JSON tests.

Do not use `.errorSpec` messages or coordinates as normative JSON5 requirements. Keep them as optional evidence for local diagnostic tests.

For each input candidate, assign one test-layer disposition after review:

- `stage2-accept` for a valid whole-document Stage2 syntax case.
- `stage2-reject` for an invalid whole-document Stage2 syntax case.
- `lexical-only` for a case that tests only token recognition or byte handling.
- `metadata-only` for a file that is not parser input.
- `excluded` for an inactive, duplicate, ambiguous, or unsupported candidate.

This review prevents a blanket claim that every upstream file is a Stage2 syntax case.

## JSON5 lexical coverage

The pinned corpus provides candidates for these JSON5 variants:

- Unquoted ASCII member names with letters, `$`, `_`, and digit continuations.
- A reserved word used as an unquoted member name.
- Invalid numeric and symbol starts for unquoted member names.
- Single-quoted strings, escaped quotes, line continuations, and invalid raw multiline strings.
- Line comments and block comments before, after, and between JSON5 tokens.
- Comment markers inside strings, comment-only documents, irregular boundaries, and unterminated block comments.
- Form-feed white space and LF, CR, and CRLF line endings.
- Signed numbers, leading and trailing decimal points, exponents, hexadecimal forms, `Infinity`, and `NaN`.
- Invalid octal forms, malformed exponents, and incomplete hexadecimal forms.
- Valid trailing commas in arrays and objects.
- Invalid leading commas, lone commas, and missing separator commas.

The active corpus does not cover the complete JSON5 lexical grammar. Unicode and escaped Unicode member-name cases remain under `todo/`. The string fixtures do not form a complete escape matrix. The white-space fixtures do not isolate every permitted Unicode white-space character.

Keep project-owned cases for missing normative boundaries separate from the unchanged upstream snapshot.

## Local raw-byte layout

A later import must use this layout:

```text
test/corpus/upstream/json5/
├── MANIFEST.md
├── raw/
│   └── json5-tests-ceb24d4080137d70833f86c25659c1331b80a387/
│       ├── LICENSE.md
│       ├── README.md
│       ├── arrays/
│       ├── comments/
│       ├── misc/
│       ├── new-lines/
│       ├── numbers/
│       ├── objects/
│       ├── strings/
│       └── todo/
└── catalog/
    ├── FILES.sha256
    └── CASES.tsv
```

`raw/` contains the exact Git blob bytes from the pinned tree. Do not edit, reformat, decode, transcode, or normalize these files.

`catalog/FILES.sha256` records the SHA-256 digest and relative path of every file under `raw/`. `catalog/CASES.tsv` records the relative path, upstream class, local disposition, and review note.

Do not place generated files inside `raw/`. Tests must read only checked-in local files and must never fetch network resources.

## Import procedure

1. Create a temporary empty Git repository.
2. Add `https://github.com/json5/json5-tests.git` as its `origin` remote.
3. Fetch only commit `ceb24d4080137d70833f86c25659c1331b80a387`.
4. Verify that `FETCH_HEAD` equals the full pinned commit ID.
5. Use `git archive` on `FETCH_HEAD` to export Git blob bytes into the pinned `raw/` directory.
6. Do not use a text-mode copy or a checkout that can apply line-ending conversion.
7. Preserve the complete tree, including `LICENSE.md`, `README.md`, `.gitattributes`, sidecars, and `todo/`.
8. Generate `catalog/FILES.sha256` from the exported files in byte-sorted relative-path order.
9. Review each candidate and write its classification to `catalog/CASES.tsv`.
10. Apply the irregular block-comment exception before any strict JSON test selects cases.
11. Exclude `todo/` from executable test sets until a separate review activates a case.
12. Commit the raw snapshot, catalog, and this manifest in the same change.

The import process can use the network. Repository tests and corpus readers cannot use the network.

## Stage2 test policy

Treat the upstream result as evidence, not as the project test oracle. Compare each candidate with the JSON5 specification and the supported parser contract.

A `stage2-accept` test must consume the complete input and accept its JSON5 grammar. A `stage2-reject` test must reject the input for a grammar reason covered by Stage2.

A lexical boundary can remain `lexical-only` when the case does not establish a complete Stage2 document contract. Metadata and inactive cases do not enter Stage2 test sets.

Preserve raw bytes when a case tests comments, string continuation, white space, encoding, or line terminators. Do not infer line endings from rendered text.
