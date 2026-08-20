# CommonMark 0.31.2 corpus manifest

## Purpose

This manifest pins the CommonMark 0.31.2 example corpus for later local import.

This project tests marker-stream parity. It does not test CommonMark rendering conformance.

The project does not vendor the corpus in this change. The paths below define the layout for a later reviewed import.

## Upstream source

| Item | Pinned value |
|---|---|
| Project | `commonmark/commonmark-spec` |
| Release | `0.31.2` |
| Release tag | `0.31.2` |
| Tag commit | `9103e341a973013013bb1a80e13567007c5cef6f` |
| Generated artifact | <https://spec.commonmark.org/0.31.2/spec.json> |
| Source specification | <https://raw.githubusercontent.com/commonmark/commonmark-spec/9103e341a973013013bb1a80e13567007c5cef6f/spec.txt> |
| Upstream extractor | <https://raw.githubusercontent.com/commonmark/commonmark-spec/9103e341a973013013bb1a80e13567007c5cef6f/test/spec_tests.py> |
| Upstream license | <https://raw.githubusercontent.com/commonmark/commonmark-spec/9103e341a973013013bb1a80e13567007c5cef6f/LICENSE> |

The upstream repository does not track `spec.json`. Its `Makefile` generates the file from `spec.txt` with this command:

```text
python3 test/spec_tests.py --dump-tests < spec.txt > spec.json
```

The commit pins the source and extractor. The versioned URL and digest pin the generated artifact bytes.

## Artifact integrity

Import the artifact only when all these values match:

| Property | Required value |
|---|---|
| Byte length | `140487` |
| SHA-256 | `d431b29d97b6f73e69d547109cf5081578fac931e72afe95639ebe766c1b2a20` |
| JSON root | Array |
| Record count | `652` |
| Example numbers | Every integer from `1` through `652`, in order |
| Section count | `26` |

The digest applies to the exact response bytes from the generated artifact URL. Do not change line endings before digest verification.

## Corpus structure

Each array record has these six fields:

- `markdown`: the Markdown input fragment.
- `html`: the upstream expected rendered HTML.
- `example`: the stable example number for release 0.31.2.
- `start_line`: the first source line in `spec.txt`.
- `end_line`: the last source line in `spec.txt`.
- `section`: the CommonMark section name.

Preserve all six fields and the upstream record order. Preserve tabs, Unicode code points, escapes, and line endings in each decoded `markdown` value.

CommonMark accepts every character sequence as a document. Do not classify corpus records as valid or invalid documents.

Some records contain syntax-like text that CommonMark treats as literal text. These are grammar boundary examples, not invalid documents.

## License boundaries

The pinned upstream `LICENSE` applies different terms to different material:

- `spec.txt` and `CommonMark.dtd` use Creative Commons Attribution-ShareAlike 4.0.
- `spec.json` derives from examples in `spec.txt`. Treat the artifact and extracted example data as CC BY-SA 4.0 material.
- Software in upstream `test/` and `tools/` uses the BSD-style terms in the pinned `LICENSE`.
- Normalization code derived from `markdowntest` also carries the MIT notice in the pinned `LICENSE`.

A raw corpus import must keep the CommonMark attribution, the CC BY-SA 4.0 link, and a change notice. An adapted example corpus must use the same license.

If an import copies upstream test or tool code, it must also keep the BSD and MIT notices. This manifest does not authorize copying that software.

Use this attribution for the raw example data:

```text
CommonMark specification examples, version 0.31.2.
Copyright (C) 2014-16 John MacFarlane.
Licensed under CC BY-SA 4.0: https://creativecommons.org/licenses/by-sa/4.0/
Source commit: 9103e341a973013013bb1a80e13567007c5cef6f
Source artifact: https://spec.commonmark.org/0.31.2/spec.json
Changes: none in raw/spec.json.
```

## Local layout

A later reviewed import must use this layout:

```text
test/corpus/upstream/markdown/
├── MANIFEST.md
├── raw/
│   └── 0.31.2/
│       ├── LICENSE
│       └── spec.json
└── selected/
    └── 0.31.2/
        └── markers.json
```

`raw/0.31.2/spec.json` must contain the exact verified artifact bytes. `raw/0.31.2/LICENSE` must contain the license file from the pinned commit.

`selected/0.31.2/markers.json` is project-authored review data. It must not replace or modify the raw artifact.

## Import procedure

1. Download `spec.json` from the versioned artifact URL to a temporary file outside the repository.
2. Require HTTPS and reject redirects to a different host.
3. Verify the temporary file length and SHA-256 before JSON decoding.
4. Parse the file as UTF-8 JSON.
5. Require one array with exactly 652 records.
6. Require the six named fields in every record.
7. Require example numbers 1 through 652 in exact order.
8. Require nonempty `section` strings and valid inclusive source-line ranges.
9. Download `LICENSE` from the pinned commit.
10. Copy the verified files to `raw/0.31.2/` without byte changes.
11. Preserve `example` and `section` in all derived failure reports.
12. Record any later corpus transformation as a change under CC BY-SA 4.0.

The importer must not fetch network resources during tests. A separate reviewed import step must create or update checked-in corpus files.

## Selected-marker policy

Run every `markdown` value through both the whole-buffer and streaming marker indexers. Compare the exact ordered marker kind and UTF-8 byte offset stream.

Use the full 652-record corpus for termination, bounds, ordering, chunk-boundary, and marker-stream parity checks. Do not use the upstream `html` field as a local oracle.

Keep hand-reviewed marker expectations in `selected/0.31.2/markers.json`. Select records by an explicit allowlist of upstream example numbers.

Do not infer the allowlist from section names, rendered HTML, or current scanner output. A scanner must not generate its own expected results.

Each selected record must contain:

- the upstream `example` number and `section`;
- a SHA-256 of the decoded `markdown` UTF-8 bytes;
- the exact ordered local marker kinds and byte offsets;
- a short reason for selection.

The selected set must cover all current local marker kinds:

- `heading`;
- `code_fence`;
- `list_item`;
- `blockquote`;
- `inline_code`;
- `link_open`;
- `link_close`;
- `thematic_break`.

Include positive cases and local non-recognition boundaries. Include indentation, tabs, delimiter runs, fence suppression, inline-code suppression, and marker-like literal text.

Do not claim support for CommonMark nodes that the local marker stream does not represent. Examples include Setext headings, emphasis, link resolution, and HTML rendering.

A passing import means the streaming and whole-buffer paths produce the same local marker stream. It does not mean the project conforms to CommonMark 0.31.2.
