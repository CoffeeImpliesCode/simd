# JSON corpus reference

No JSONTestSuite payloads are vendored in this directory.

- Source: <https://github.com/nst/JSONTestSuite>.
- Commit: `1ef36fa01286573e846ac449e8683f8833c5b26a`.
- Root tree: `f3d680c9b9065eaa6bfa6dac14adade610d6e054`.
- Corpus: `test_parsing/`, with 95 `y_`, 188 `n_`, and 35 `i_` files.
- `y_` means accept. `n_` means reject. `i_` requires a stated implementation policy.
- `test_transform/` covers materialization rather than syntax.
- License: MIT, Copyright (c) 2016 Nicolas Seriot.
  Copies must retain the complete [pinned license](https://github.com/nst/JSONTestSuite/blob/1ef36fa01286573e846ac449e8683f8833c5b26a/LICENSE).

The suite is an interoperability corpus, not an IETF or Ecma conformance suite.
Tests must use only checked-in corpus files and metadata. They must not fetch upstream resources.
