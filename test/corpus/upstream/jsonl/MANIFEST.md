# JSONL and NDJSON corpus references

No upstream payloads are vendored in this directory.
RFC 8259 defines each record's grammar, not framing.

| Source | Pin | Terms |
| --- | --- | --- |
| [wardi/jsonlines](https://github.com/wardi/jsonlines) | `a8e8671adf470477cd2cc1dfc40c30825f421baa`, `index.md` | No redistribution grant. Cite only. |
| [ndjson/ndjson-spec](https://github.com/ndjson/ndjson-spec) | `8a5a2350ff95fd356993b827f63c5733a9d4f1a6`, version 1.0.0 | Commercial/noncommercial use statement, without a standard redistribution license. Cite only. |
| [nst/JSONTestSuite](https://github.com/nst/JSONTestSuite) | `1ef36fa01286573e846ac449e8683f8833c5b26a`, `test_parsing/` | MIT. Retain the complete pinned `LICENSE` with copies or derived files. |
| [wbolster/jsonlines](https://github.com/wbolster/jsonlines) | `43d1a30b9634f8b715b6af3f2473927caa1e704d` | BSD-3-Clause. Retain the complete pinned `LICENSE.rst` with copies or derived files. |
| [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259.html) | December 2017 | Copyright 2017 IETF Trust and named authors. Cite rather than copy the full text. |

JSON Lines permits an unterminated final record. NDJSON serialization requires a final LF.
NDJSON permits configurable empty-line skipping. Whitespace-only lines are distinct from empty lines.
Implementation compatibility behavior, including permissive BOM handling, is separate from format rules.
Preserve source bytes when testing framing, CRLF splits, escapes, and UTF-8 chunk boundaries.
Tests must read checked-in files only. They must not fetch upstream resources.
