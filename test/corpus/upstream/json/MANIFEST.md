# JSONTestSuite Ingestion Manifest

This manifest defines a future import of JSONTestSuite. No JSONTestSuite cases are vendored in this directory yet.

## Source Pin

- Repository: <https://github.com/nst/JSONTestSuite>
- Commit: [`1ef36fa01286573e846ac449e8683f8833c5b26a`](https://github.com/nst/JSONTestSuite/commit/1ef36fa01286573e846ac449e8683f8833c5b26a)
- Root Git tree: [`f3d680c9b9065eaa6bfa6dac14adade610d6e054`](https://api.github.com/repos/nst/JSONTestSuite/git/trees/f3d680c9b9065eaa6bfa6dac14adade610d6e054?recursive=1)
- Corpus subtree: [`test_parsing/`](https://github.com/nst/JSONTestSuite/tree/1ef36fa01286573e846ac449e8683f8833c5b26a/test_parsing)
- Classification source: [`README.md`](https://github.com/nst/JSONTestSuite/blob/1ef36fa01286573e846ac449e8683f8833c5b26a/README.md)

The commit and root tree are immutable source identifiers. Do not import from a branch, an unpinned archive, or a mirror.

JSONTestSuite is a community interoperability corpus. It is not an IETF or Ecma conformance suite.

## License

The pinned repository uses the MIT License. The notice identifies `Copyright (c) 2016 Nicolas Seriot`.

A future import must copy the pinned [`LICENSE`](https://github.com/nst/JSONTestSuite/blob/1ef36fa01286573e846ac449e8683f8833c5b26a/LICENSE) without changes. Store it at `JSONTestSuite/LICENSE`.

Every redistributed corpus copy must retain the complete copyright and permission notice. A summary in this manifest does not replace that notice.

## Scope and Inventory

Import only regular Git blobs below `test_parsing/`. Preserve each path relative to that directory.

The pinned tree contains this exact parsing inventory:

| Upstream class | Files | Meaning |
| --- | ---: | --- |
| `y_` | 95 | A conforming parser must accept the input. |
| `n_` | 188 | A conforming parser must reject the input. |
| `i_` | 35 | Acceptance depends on the implementation policy. |
| **Total** | **318** | All pinned `test_parsing/` files. |

The filename families have this distribution:

| Family | `y_` | `n_` | `i_` | Total |
| --- | ---: | ---: | ---: | ---: |
| Number | 19 | 51 | 10 | 80 |
| Object | 12 | 28 | 1 | 41 |
| String | 43 | 29 | 22 | 94 |
| Structure | 10 | 49 | 2 | 61 |
| Array | 11 | 26 | 0 | 37 |
| Residual invalid names | 0 | 5 | 0 | 5 |
| **Total** | **95** | **188** | **35** | **318** |

Exclude all 22 `test_transform/` files. They test value materialization and do not define strict binary syntax outcomes.

Reject the import if the path set, class counts, family counts, or total differs from this inventory.

## Local Raw-Byte Layout

A future importer must create this layout:

```text
test/corpus/upstream/json/
  MANIFEST.md
  JSONTestSuite/
    LICENSE
    FILES.sha256
    UPSTREAM.json
    test_parsing/
      i_*.json
      n_*.json
      y_*.json
```

Copy each Git blob as raw bytes. Do not decode, transcode, normalize Unicode, strip a byte-order mark, or change line endings.

Do not re-indent the files or remove trailing bytes. Preserve the upstream filename and relative path exactly.

## Classification Policy

The local harness must use these outcomes:

| Prefix | Local expectation | Required result |
| --- | --- | --- |
| `y_` | `accept` | Strict JSON validation succeeds for the complete input. |
| `n_` | `reject_strict` | Strict JSON validation returns a syntax or encoding error. |
| `i_` | Explicit per-file policy | The result matches the reviewed `UPSTREAM.json` entry. |

Never infer an `i_` result from its prefix alone. Each `i_` entry must record a policy key and one local expectation.

Use these policy rules for `i_` entries:

- Reject malformed raw UTF-8 in the UTF-8 JSON entry point.
- Reject UTF-16 and UTF-32 byte streams in the UTF-8 JSON entry point.
- Reject a UTF-8 byte-order mark in strict JSON mode.
- Accept a grammar-valid number before numeric range conversion.
- Accept a grammar-valid escaped surrogate at the syntax layer.
- Report configured depth or size limits as `resource_limit`, not malformed syntax.

The importer must stop if an `i_` file has no reviewed mapping. It must not choose a result from parser behavior.

## Deterministic Import

A future importer must use this procedure:

1. Fetch the pinned commit into a clean temporary Git object database.
2. Resolve the commit to its root tree.
3. Require the root tree to equal `f3d680c9b9065eaa6bfa6dac14adade610d6e054`.
4. Enumerate `test_parsing/` from the Git tree in bytewise path order.
5. Require 318 regular blobs and the inventory counts above.
6. Read each file with `git cat-file` or an equivalent raw Git object operation.
7. Copy the pinned `LICENSE` with the same raw Git object operation.
8. Write files only below `JSONTestSuite/` with the layout above.
9. Generate `UPSTREAM.json` with entries in bytewise path order.
10. Generate `FILES.sha256` after all raw files are present.

`UPSTREAM.json` must record the repository URL, commit, root tree, and corpus subtree. Each file entry must contain these fields:

- Relative path below `test_parsing/`.
- Upstream Git blob object ID.
- Byte length.
- Lowercase SHA-256 digest.
- Upstream class: `y`, `n`, or `i`.
- Local expectation: `accept`, `reject_strict`, or `resource_limit`.
- Policy key and expected diagnostic class when the upstream class is `i`.

The importer must reject duplicate paths, non-blob tree entries, missing mappings, unknown prefixes, and paths outside the destination root.

The importer must produce identical tracked bytes for repeated imports of the same pin. Do not put timestamps or temporary paths in tracked output.

## Hash Verification

The Git root tree verifies the complete pinned upstream object graph. Per-file SHA-256 digests verify the extracted bytes independently of Git object IDs.

`FILES.sha256` must cover `LICENSE` and all 318 files below `test_parsing/`. It must not cover itself or `UPSTREAM.json`.

Write one lowercase digest and relative path per line in the standard `sha256sum` form. Sort entries by the unsigned bytes of their UTF-8 relative paths.

The importer must hash each Git blob before writing and hash each destination file after writing. Both digests must match its `UPSTREAM.json` entry.

The first reviewed corpus import must check in `FILES.sha256`. A later import must reproduce that file exactly before it can replace corpus bytes.

Local verification uses `sha256sum -c FILES.sha256` from `JSONTestSuite/`, or an equivalent raw-byte SHA-256 implementation.

## Offline Test Rule

Tests must use only checked-in corpus files and metadata. Tests must not clone, fetch, download, or call a GitHub API.

The importer is a separate maintainer operation. It must never run as part of a build, test, fuzz, or benchmark command.

Do not add corpus files until a separate reviewed import adds the complete pinned inventory, license, metadata, and hashes together.
