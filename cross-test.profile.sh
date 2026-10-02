#!/usr/bin/env bash
# Keep cross-test's complete compiler-version-pinned Tier 1/2 matrix and
# automatic runners. No CROSS_MATRIX, TARGETS, or compile-only overrides.
CROSS_BUILD_STEP=test
CROSS_JOBS=2
CROSS_BUILD_JOBS=1
