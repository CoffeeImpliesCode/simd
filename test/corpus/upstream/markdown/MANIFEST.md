# CommonMark corpus reference

The vendored examples are in `../commonmark-0.31.2/`.
`formats.markdown` exposes markers. `formats.commonmark` parses semantic documents and renders HTML.

- Project: <https://github.com/commonmark/commonmark-spec>.
- Version: `0.31.2`.
- Source commit: `9103e341a973013013bb1a80e13567007c5cef6f`.
- Generated artifact: <https://spec.commonmark.org/0.31.2/spec.json>.
- Artifact length: `140487` bytes.
- Artifact SHA-256: `d431b29d97b6f73e69d547109cf5081578fac931e72afe95639ebe766c1b2a20`.
- Corpus: 652 examples across 26 sections, with `markdown`, `html`, `example`, `start_line`, `end_line`, and `section` fields.

The artifact derives from specification examples under CC BY-SA 4.0.
Copyright (C) 2014-16 John MacFarlane.
Keep attribution, <https://creativecommons.org/licenses/by-sa/4.0/>, and change notices with copies.
Adapted example data uses the same license.
Upstream software in `test/` and `tools/` uses BSD-style terms.
Normalization code derived from `markdowntest` also carries an MIT notice.
See the complete [pinned license](https://github.com/commonmark/commonmark-spec/blob/9103e341a973013013bb1a80e13567007c5cef6f/LICENSE).

CommonMark accepts every character sequence as a document.
HTML expectations apply to the semantic renderer, not the marker indexer.
Tests use checked-in files only. They must not fetch network resources during tests.
