# node-jsonc-parser JSONC Corpus Manifest

## Source Pin

| Field | Value |
| --- | --- |
| Upstream repository | `https://github.com/microsoft/node-jsonc-parser.git` |
| Commit | `37e207ed23f544efc33a1893f21e0bf10b250df0` |
| Test tree | `src/test/` |
| Grammar source | `src/test/json.test.ts` |
| Grammar source Git blob | `f6c7601da1e944b5d215cbf5e603838b684b76b3` |
| Grammar source SHA-256 | `c16cb6f0fc72542703ea9a3ab540b70b2068bf7bd49243b0e6b20b7c60981afd` |
| Pinned source | <https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/src/test/json.test.ts> |

The full commit is the immutable source pin. Do not import from a branch, tag, package release, or moving archive URL.

## License

The upstream project uses the MIT License. The pinned license is:

<https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/LICENSE.md>

The copyright notice is `Copyright (c) Microsoft`.

The license permits use, copying, modification, merging, publication, distribution, sublicensing, and sale. Copies or substantial portions must include the copyright notice and permission notice. The software has no warranty under the license.

An import must copy the complete pinned `LICENSE.md` beside the imported cases. Do not use this summary as a replacement for that license file.

## Scope and Upstream Layout

`src/test/json.test.ts` contains the JSON grammar cases as inline TypeScript strings. It covers scanning, parsing, comments, recovery, parser options, trees, visitors, and locations.

The test tree has no standalone valid and invalid fixture directories. These sibling files are outside this syntax corpus:

- `src/test/edit.test.ts` tests document edits.
- `src/test/format.test.ts` tests formatting.
- `src/test/string-intern.test.ts` tests string interning.

Tree-shape, visitor-order, location, formatting, editing, and interning assertions do not define JSONC syntax conformance.

## Local Layout

A later import must use this layout:

```text
test/corpus/upstream/jsonc/
├── MANIFEST.md
└── node-jsonc-parser/
    ├── LICENSE.md
    ├── FILES.sha256
    ├── UPSTREAM.json
    └── cases/
        ├── valid/
        ├── invalid/
        ├── scanner/
        ├── diagnostic/
        ├── variant-vscode-trailing-comma/
        └── option-json-disallow-comments/
```

Store one evaluated input per file. Preserve the upstream case order in stable file names.

`UPSTREAM.json` must record the repository, commit, source path, Git blob, source lines, parser options, expected validity, and optional diagnostic data. `FILES.sha256` must cover every copied or generated file except itself.

## Strict JSONC Classification

This corpus defines strict JSONC as RFC 8259 JSON with JavaScript-style line and block comments. It permits `//` and `/* ... */` comments only where JSON whitespace can occur.

Comments are the only JSONC syntax extension. Strict JSONC does not permit trailing commas.

JSON5 is a different language. Do not classify these JSON5-only forms as valid JSONC:

- Single-quoted strings.
- Unquoted object names.
- Trailing commas.
- Hexadecimal numbers.
- A leading plus sign on a number.
- Leading or trailing decimal points.
- `Infinity` or `NaN`.
- JSON5 string escapes or line continuations.
- Additional JSON5 whitespace or identifier syntax.

Do not classify a case as valid JSONC only because a JSON5 parser accepts it.

Use these upstream classifications:

- A default-option `assertValidParse` case is strict JSONC valid when it has no syntax diagnostic.
- A default-option `assertInvalidParse` case is strict JSONC invalid when it has one or more syntax diagnostics.
- An `allowTrailingComma: true` case belongs in `variant-vscode-trailing-comma/`. It is not strict JSONC valid.
- A `disallowComments: true` case belongs in `option-json-disallow-comments/`. It is not a JSONC invalid case without that option.
- A recovered value does not make an input valid. Any syntax diagnostic means rejection.
- Import an exact diagnostic code or offset only when the upstream test asserts it.

## Deterministic Import Procedure

1. Clone `https://github.com/microsoft/node-jsonc-parser.git` into a temporary directory.
2. Check out commit `37e207ed23f544efc33a1893f21e0bf10b250df0` in detached mode.
3. Confirm that `src/test/json.test.ts` has Git blob `f6c7601da1e944b5d215cbf5e603838b684b76b3`.
4. Confirm that the raw source SHA-256 is `c16cb6f0fc72542703ea9a3ab540b70b2068bf7bd49243b0e6b20b7c60981afd`.
5. Copy the pinned `LICENSE.md` without changes.
6. Parse `src/test/json.test.ts` with a pinned TypeScript parser.
7. Evaluate the selected TypeScript string literals. Do not extract strings with a regular expression.
8. Encode each evaluated string as UTF-8 bytes.
9. Preserve explicit CR, LF, CRLF, NUL, escape, and Unicode content.
10. Apply the strict classification rules in this manifest.
11. Write one case per file under the matching local directory.
12. Record each case source range, parser options, expected result, and upstream assertion in `UPSTREAM.json`.
13. Generate `FILES.sha256` in bytewise path order with a fixed locale.
14. Review the generated inventory before committing any upstream content.

The importer may use the network. Corpus tests must use only checked-in files and must never fetch upstream resources.
