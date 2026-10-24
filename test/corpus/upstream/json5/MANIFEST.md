# JSON5 corpus reference

No upstream payloads are vendored in this directory.

- Source: <https://github.com/json5/json5-tests.git>.
- Commit: `ceb24d4080137d70833f86c25659c1331b80a387`.
- Directories: `arrays`, `comments`, `misc`, `new-lines`, `numbers`, `objects`, `strings`, and inactive `todo`.
- License: MIT. Copies must retain the complete pinned `LICENSE.md` and its copyright notice.
- Upstream extensions classify `.json` as JSON/JSON5, `.json5` as JSON5, `.js` as ES5-only, and `.txt` as invalid.
- `comments/irregular-block-comment.json` contains a JSON5 comment despite its suffix. It is not a strict JSON case.
- `.errorSpec` sidecars describe implementation-specific diagnostics, not normative JSON5 requirements.

The JSON5 specification defines grammar. This repository supplies interoperability cases rather than a formal conformance suite.
Preserve raw bytes, including the line endings in `new-lines/`.
Tests must read only checked-in local files and must not fetch upstream resources.
