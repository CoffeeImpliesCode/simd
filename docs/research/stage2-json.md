# Stage 2 JSON specification and corpus evidence

Research snapshot: 2026-08-20.

## Decision

Use [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259) as the normative JSON definition. It is IETF Internet Standard STD 90. RFC 8259 also names ECMA-404 as a normative, grammar-aligned JSON specification.[^rfc-status] [^rfc-alignment]

Use `nst/JSONTestSuite` as the main external parser corpus. Pin commit [`1ef36fa01286573e846ac449e8683f8833c5b26a`](https://github.com/nst/JSONTestSuite/commit/1ef36fa01286573e846ac449e8683f8833c5b26a). This corpus is community-maintained and de-facto. The IETF and Ecma do not publish or endorse it as an official conformance suite.

Ingest only its `test_parsing/` files for the Stage 2 syntax gate. Preserve all input bytes without text conversion. Use `y_` and `n_` as strict-mode assertions. Record `i_` results by an explicit project policy.

## Primary specifications

### RFC 8259

- **Title:** *The JavaScript Object Notation (JSON) Data Interchange Format*.
- **Publisher and status:** IETF, December 2017, Internet Standard STD 90.[^rfc-status]
- **Stable identifier:** RFC 8259 and DOI [`10.17487/RFC8259`](https://doi.org/10.17487/RFC8259).
- **Canonical text:** <https://www.rfc-editor.org/rfc/rfc8259>.
- **Errata:** <https://www.rfc-editor.org/errata/rfc8259>. The errata index can change. The research snapshot found five verified errata, one reported erratum, and two held for document update.
- **Copyright:** The RFC carries the 2017 IETF Trust copyright notice. It points to the IETF Trust Legal Provisions and gives extracted code components the Simplified BSD terms.[^rfc-status] [^ietf-tlp]

RFC 8259 is the authority for parser behavior in this project. The following rules have direct Stage 2 value:

| Area | Normative rule | Stage 2 consequence |
| --- | --- | --- |
| Complete text | A JSON text is `ws value ws`. A top-level scalar is valid.[^rfc-grammar] | Accept top-level strings, numbers, booleans, and `null`. Reject a second value or trailing non-whitespace data. |
| Whitespace | Only space, tab, line feed, and carriage return are JSON whitespace.[^rfc-grammar] | Reject form feed, vertical tab, non-breaking space, and other Unicode spacing characters outside strings. |
| Literals | The only literal names are lowercase `false`, `null`, and `true`.[^rfc-values] | Reject alternate case, abbreviations, and unknown identifiers. |
| Objects | A member has a string name, one colon, and one value. Commas separate members.[^rfc-objects] | Reject bare keys, missing values, extra colons, comments, and trailing commas. |
| Duplicate names | Object names SHOULD be unique, but duplicate names remain grammar-valid.[^rfc-objects] | The syntax validator must not classify duplicate names as malformed JSON. A later semantic policy can report them. |
| Arrays | Commas separate zero or more values.[^rfc-arrays] | Reject holes, leading commas, trailing commas, and mismatched delimiters. |
| Numbers | Numbers use decimal grammar. Leading zeroes in the integer component are forbidden. `Infinity` and `NaN` are not JSON.[^rfc-numbers] | Validate the token grammar before number conversion. Do not let the host numeric parser define syntax. |
| Strings | Quotes delimit strings. U+0000 through U+001F, quote, and reverse solidus require an escape.[^rfc-strings] | Reject raw controls, unknown escapes, and incomplete `\u` escapes. Accept both uppercase and lowercase hexadecimal digits. |
| Encoding | Inter-system JSON text outside a closed ecosystem MUST use UTF-8.[^rfc-encoding] | The strict JSON format should reject malformed UTF-8 and UTF-16 or UTF-32 byte streams. |
| Byte-order mark | A generator must not add a BOM to network JSON. A parser MAY ignore a BOM.[^rfc-encoding] | BOM acceptance is a documented compatibility choice, not a universal conformance failure. |
| Surrogates | The grammar permits escapes such as a lone `\uDEAD`, but RFC 8259 warns that receiver behavior is unpredictable.[^rfc-unicode] | Separate JSON syntax acceptance from Unicode-scalar materialization policy. |
| Parser limits | A parser MAY limit text size, nesting depth, numbers, and strings. It MAY accept extensions.[^rfc-parsers] | Report a resource-limit error separately. Run the corpus in strict JSON mode, with extensions disabled. |

The current verified errata do not add a new JSON token or production. Relevant corrections clarify the leading-zero prose, distinguish Unicode code points, and repair ABNF presentation details.[^rfc-errata] Keep a reference to the live errata index when the corpus pin changes.

### ECMA-404

[ECMA-404, second edition, December 2017](https://ecma-international.org/publications-and-standards/standards/ecma-404/) is the other primary JSON syntax specification. Ecma states that it defines valid JSON syntax only. It does not define semantics or language mappings.[^ecma-404]

RFC 8259 states that the two grammars intend to define the same JSON text. RFC 8259 adds interoperability guidance that ECMA-404 does not provide.[^rfc-alignment] Use ECMA-404 to cross-check grammar changes. Use RFC 8259 for Stage 2 acceptance and interoperability policy.

## Conformance corpus assessment

### `nst/JSONTestSuite`: approved for local ingestion

#### Provenance and pin

Nicolas Seriot created JSONTestSuite as the appendix and executable corpus for his parser comparison work. The upstream README calls it a comprehensive suite for RFC 8259 parsers and defines its result classes.[^jts-readme]

This is not a standards-body corpus. Treat it as a broad, de-facto interoperability corpus.

Pin these immutable upstream objects:

- **Commit:** [`1ef36fa01286573e846ac449e8683f8833c5b26a`](https://github.com/nst/JSONTestSuite/commit/1ef36fa01286573e846ac449e8683f8833c5b26a), dated 2024-11-22.
- **Git tree:** [`f3d680c9b9065eaa6bfa6dac14adade610d6e054`](https://api.github.com/repos/nst/JSONTestSuite/git/trees/f3d680c9b9065eaa6bfa6dac14adade610d6e054?recursive=1).
- **Parsing corpus:** [`test_parsing/` at the pinned commit](https://github.com/nst/JSONTestSuite/tree/1ef36fa01286573e846ac449e8683f8833c5b26a/test_parsing).
- **Classification source:** [`README.md` at the pinned commit](https://github.com/nst/JSONTestSuite/blob/1ef36fa01286573e846ac449e8683f8833c5b26a/README.md).
- **License source:** [`LICENSE` at the pinned commit](https://github.com/nst/JSONTestSuite/blob/1ef36fa01286573e846ac449e8683f8833c5b26a/LICENSE).

Do not ingest from `master`, a release archive without a commit, or a third-party mirror.

#### License and redistribution

The pinned repository uses the MIT License, copyright 2016 Nicolas Seriot.[^jts-license] The license permits use, modification, and redistribution. A redistributed copy must include the copyright and permission notice.

Preserve the upstream `LICENSE` beside any local corpus copy. Also record the commit and tree SHA in the local manifest. This makes the source and redistribution terms auditable.

#### Structure and exact inventory

The upstream README defines these parsing classes:[^jts-readme]

- `y_`: parsers must accept the content.
- `n_`: parsers must reject the content.
- `i_`: parsers can accept or reject the content.

An inventory of the pinned Git tree gives **318 files** in `test_parsing/`:

| Class | Files | Stage 2 use |
| --- | ---: | --- |
| `y_` | 95 | Required success in strict JSON mode. |
| `n_` | 188 | Required syntax or encoding error in strict JSON mode. |
| `i_` | 35 | Policy case. Record the selected expectation and diagnostic class. |
| **Total** | **318** | Full raw-byte parsing corpus. |

The filename families give this exact distribution at the pin:

| Family | `y_` | `n_` | `i_` | Main coverage |
| --- | ---: | ---: | ---: | --- |
| Number | 19 | 51 | 10 | Integer, fraction, exponent, leading zero, overflow, and extreme magnitude. |
| Object | 12 | 28 | 1 | Keys, colons, commas, duplicate names, and malformed members. |
| String | 43 | 29 | 22 | Escapes, controls, Unicode, malformed bytes, surrogates, BOM, and alternate encodings. |
| Structure | 10 | 49 | 2 | Whole-text framing, whitespace, comments, trailing data, delimiter balance, and nesting. |
| Array | 11 | 26 | 0 | Element placement, commas, nesting, and delimiter errors. |
| Residual invalid names | 0 | 5 | 0 | Three incomplete values, one multidigit-number case, and one single-space text. |
| **Total** | **95** | **188** | **35** | **318 cases.** |

The repository also has 22 files in `test_transform/`. The README says these examine how parsers materialize huge numbers, similar keys, NUL characters, and invalid escaped strings.[^jts-readme] These files do not define a binary syntax expectation. Do not add them to the Stage 2 syntax gate. They can support later tape and value-materialization tests.

#### Valid, invalid, and malformed coverage

The `y_` set covers valid empty and nested containers, all JSON value kinds, allowed whitespace, legal escapes, Unicode text, duplicate object names, and extreme grammar-valid numbers. This directly tests RFC 8259 Section 9's requirement to accept grammar-conforming texts.[^rfc-parsers]

The `n_` set covers malformed containers, missing members or values, invalid separators, trailing data, comments, malformed number tokens, raw controls, invalid escapes, incomplete input, and malformed UTF-8. It also includes large unfinished structures. These cases test rejection without requiring value materialization.

The `i_` set covers areas where standards permit implementation limits or interoperability choices. Examples include 500 nested arrays, extreme number range, BOM handling, UTF-16 byte streams, raw malformed encodings, and escaped lone surrogates. Do not relabel the complete `i_` set as invalid.

The three classes are useful but not a formal proof of RFC conformance. RFC 8259 permits parsers to accept extensions and set resource limits.[^rfc-parsers] Therefore:

1. Run `n_` only against the project's strict JSON entry point.
2. Keep extensions disabled for this gate.
3. Distinguish `syntax_error`, `encoding_error`, and `resource_limit` results.
4. Store an explicit expected policy for every imported `i_` file.
5. Review any local expectation that differs from the upstream filename class.

### JSON.org `JSON_checker` suite: historical reference only

The original JSON.org JSON_checker page links a `test.zip` archive. It says the checker must accept all `pass*.json` files and reject all `fail*.json` files.[^json-checker]

The page and archive have no immutable revision identifier. The page also gives no license notice for the test archive. The separately published JSON_checker source does not establish redistribution rights for the archive.[^json-checker-source]

Do not vendor `test.zip` without separate license evidence and a content hash. It can serve as a historical comparison source. JSONTestSuite provides the stronger pinned and licensed ingestion source.

## Concrete local-ingestion recommendation

Use this layout in a later implementation change:

```text
tests/corpus/json/JSONTestSuite/
  LICENSE
  UPSTREAM.json
  test_parsing/
    i_*.json
    n_*.json
    y_*.json
```

Use this ingestion procedure:

1. Fetch the repository by Git object ID.
2. Check out commit `1ef36fa01286573e846ac449e8683f8833c5b26a`.
3. Copy only `test_parsing/` and `LICENSE`.
4. Preserve filenames and file bytes exactly.
5. Do not decode, normalize, re-indent, or change line endings.
6. Generate `UPSTREAM.json` from the checked-out tree.
7. Record the repository URL, commit SHA, tree SHA, license identifier, and retrieval date.
8. Record each file's relative path, byte length, SHA-256 digest, upstream class, and local expectation.
9. Make the harness enumerate the manifest, not the filesystem order.

The harness should pass each file as raw bytes to the Stage 2 JSON validator. It should enforce these outcomes:

| Upstream class | Local default | Gate behavior |
| --- | --- | --- |
| `y_` | `accept` | Fail if Stage 2 returns a syntax or encoding error. |
| `n_` | `reject_strict` | Fail if strict Stage 2 accepts the complete input. |
| `i_` | `policy` | Use a per-file expected result. Never infer one from the prefix alone. |

For `i_` files, start with these policy groups:

- Reject malformed raw UTF-8 in strict JSON mode.
- Reject UTF-16 and UTF-32 byte streams in the UTF-8 JSON entry point.
- Choose and document one UTF-8 BOM policy. RFC 8259 permits a parser to ignore it.
- Accept grammar-valid number tokens before range conversion. Report conversion limits separately.
- Accept grammar-valid escaped surrogate code points at the syntax layer. Apply Unicode-scalar restrictions during materialization.
- Return `resource_limit` for configured depth or size limits. Do not report malformed syntax.

This corpus supplies high-value Stage 2 coverage for token placement, whole-text completion, string and number boundaries, encoding failures, and deep malformed input. It does not test decoded value equality, duplicate-key resolution, number rounding, or string replacement behavior. Add those behaviors only where the public Stage 2 contract exposes them.

## Source index

[^rfc-status]: RFC Editor, [RFC 8259 information and canonical text](https://www.rfc-editor.org/info/rfc8259/). The page identifies RFC 8259 as STD 90 and reproduces its copyright notice.
[^rfc-alignment]: RFC 8259, [Section 1.2, Specifications of JSON](https://www.rfc-editor.org/rfc/rfc8259#section-1.2).
[^rfc-grammar]: RFC 8259, [Section 2, JSON Grammar](https://www.rfc-editor.org/rfc/rfc8259#section-2).
[^rfc-values]: RFC 8259, [Section 3, Values](https://www.rfc-editor.org/rfc/rfc8259#section-3).
[^rfc-objects]: RFC 8259, [Section 4, Objects](https://www.rfc-editor.org/rfc/rfc8259#section-4).
[^rfc-arrays]: RFC 8259, [Section 5, Arrays](https://www.rfc-editor.org/rfc/rfc8259#section-5).
[^rfc-numbers]: RFC 8259, [Section 6, Numbers](https://www.rfc-editor.org/rfc/rfc8259#section-6).
[^rfc-strings]: RFC 8259, [Section 7, Strings](https://www.rfc-editor.org/rfc/rfc8259#section-7).
[^rfc-encoding]: RFC 8259, [Section 8.1, Character Encoding](https://www.rfc-editor.org/rfc/rfc8259#section-8.1).
[^rfc-unicode]: RFC 8259, [Section 8.2, Unicode Characters](https://www.rfc-editor.org/rfc/rfc8259#section-8.2).
[^rfc-parsers]: RFC 8259, [Section 9, Parsers](https://www.rfc-editor.org/rfc/rfc8259#section-9).
[^rfc-errata]: RFC Editor, [errata for RFC 8259](https://www.rfc-editor.org/errata/rfc8259). Status observed on 2026-08-20.
[^ietf-tlp]: IETF Trust, [Trust Legal Provisions](https://trustee.ietf.org/documents/trust-legal-provisions/).
[^ecma-404]: Ecma International, [ECMA-404, second edition](https://ecma-international.org/publications-and-standards/standards/ecma-404/).
[^jts-readme]: `nst/JSONTestSuite`, [README at commit `1ef36fa`](https://github.com/nst/JSONTestSuite/blob/1ef36fa01286573e846ac449e8683f8833c5b26a/README.md).
[^jts-license]: `nst/JSONTestSuite`, [MIT License at commit `1ef36fa`](https://github.com/nst/JSONTestSuite/blob/1ef36fa01286573e846ac449e8683f8833c5b26a/LICENSE).
[^json-checker]: JSON.org, [JSON_checker page and test-suite description](https://www.json.org/JSON_checker/).
[^json-checker-source]: Douglas Crockford, [`JSON-c` source at commit `bb3e8d18a33e8335619519e62462c666370e232d`](https://github.com/douglascrockford/JSON-c/tree/bb3e8d18a33e8335619519e62462c666370e232d). The repository does not contain the linked `test.zip` corpus.
