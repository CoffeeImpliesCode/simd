# JSONC corpus reference

No upstream payloads are vendored in this directory.

- Source: <https://github.com/microsoft/node-jsonc-parser.git>.
- Commit: `37e207ed23f544efc33a1893f21e0bf10b250df0`.
- Grammar cases: `src/test/json.test.ts`, as inline TypeScript strings.
- Source Git blob: `f6c7601da1e944b5d215cbf5e603838b684b76b3`.
- Source SHA-256: `c16cb6f0fc72542703ea9a3ab540b70b2068bf7bd49243b0e6b20b7c60981afd`.
- License: MIT, Copyright (c) Microsoft.
  Copies must retain the complete [pinned license](https://github.com/microsoft/node-jsonc-parser/blob/37e207ed23f544efc33a1893f21e0bf10b250df0/LICENSE.md).

The local JSONC grammar is RFC 8259 plus line and block comments, without trailing commas.
Upstream cases with `allowTrailingComma: true` or `disallowComments: true` need separate expectations.
Recovered values do not make malformed input valid.
Editing, formatting, visitor, and location assertions do not define syntax conformance.
Corpus tests must use only checked-in files and must not fetch upstream resources.
