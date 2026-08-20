# YAML Test Suite corpus manifest

## Source pin

- Upstream repository: <https://github.com/yaml/yaml-test-suite>
- Release: `data-2022-01-17`
- Pinned revision: `6e6c296ae9c9d2d5c4134b4b64d01b29ac19ff6f`
- Release tag object: `5f49729577242103ae23838ac2ad4d9145aec126`
- Pinned tree: <https://github.com/yaml/yaml-test-suite/tree/6e6c296ae9c9d2d5c4134b4b64d01b29ac19ff6f>
- License: MIT

The commit ID is the immutable source pin. Do not import from the moving `data` branch.
The release contains YAML 1.2.2 test data and metadata. The upstream README defines `in.yaml`, `test.event`, `in.json`, `out.yaml`, `error`, and `emit.yaml`.

## Local policy

Tests must read only checked-in corpus files and metadata. Tests must not access the network.
The local `yaml-basic-1.2.2` profile accepts only the supported subset. A valid upstream case outside this profile is `Unsupported`, not `Invalid`.

The project-owned supported fixture is `test/corpus/yaml/basic.yaml`. It is not a copied upstream case. It covers one document, block mappings, a nested block sequence, quoted scalars, a flow mapping, comments, and document markers.

## Provenance

YAML Test Suite data-2022-01-17 (`yaml/yaml-test-suite`; commit `6e6c296ae9c9d2d5c4134b4b64d01b29ac19ff6f`; tag object `5f49729577242103ae23838ac2ad4d9145aec126`; MIT License; downloaded from <https://github.com/yaml/yaml-test-suite>).
