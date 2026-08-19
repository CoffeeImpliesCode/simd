# simd — Agent Rules (Zig, hardcore quality)

SIMD microbenchmarks and experiments in Zig. Status: scratch. Stack: Zig only.

- Zig: **0.16.0** (pinned) · VCS: `jj` (colocated git; never raw git
  except `jj git push`)
- New work starts on a **clean change**; parallel work in
  `jj worktree add <path>`
- Read before coding: `zig-tiger-style`, `zig-best-practices`,
  `zig-project`, `zig-linting`, `zig-coverage`, `zig-testing`,
  `verification-before-completion`, `code-review`, `jj-core`,
  `using-git-worktrees`

## 0. Tools over shell (MANDATORY)

- File changes go through the `edit` tool (targeted edits) or `write` (new files) — NEVER through shell commands.
- NEVER patch files with inline python/perl/sed/awk scripts, heredocs, or `echo >` redirection. This corrupts files and bypasses review.
- Read with `read`, search with `grep`/`glob`. Shell is for builds, tests, and one-shot fact queries only.
- A single logical change = one `edit` call. If an `edit` fails, read the file and retry with exact text — never fall back to scripting.

## 1. Golden rules (loose Tiger Style)

Safety > Performance > Developer Experience.

- **Explicit everything**: allocators as params (never global), explicit
  error sets (no `anyerror` in APIs), explicit control flow. No hidden
  allocations, state, or macros.
- **All errors handled**; never discard with `_ =`. Every `if` asks: does
  the `else` need handling? Assert positive AND negative space at
  boundaries.
- **Assertions** detect programmer errors: pair them (write + read-back),
  split compound (`assert(a); assert(b);`), assert comptime relationships
  (`comptime assert(@sizeOf(H) == 128);`).
- **Loops have fixed upper bounds**; fail fast. Event loops assert
  non-termination.
- **Small functions**: push `if`s up, `for`s down. Parent owns mutable
  state; helpers compute, don't apply.
- **Naming**: fns `camelCase`, types `PascalCase`, vars `snake_case`;
  units appended (`latency_ms_max`); no abbreviations; options-struct for
  2+ same-typed args; callbacks last, named `<caller>_callback`.
- **Formatting**: `zig fmt`, 100 cols hard limit, braces on multi-line
  `if`. Division explicit: `@divExact`/`@divFloor`/`div_ceil`.
- **Comments say WHY**; an obviously-true assertion beats a comment.
- **No backwards compatibility**: delete, don't deprecate; no
  aliases/shims/unused params.
- **Zero deps unless justified**; scripts as `scripts/*.zig`, not shell.

## 2. Architecture: extreme-testable by default

Mandatory for new code, default for refactors; reviewers enforce it:

- **`io: std.Io` threaded explicitly** (never global) → deterministic
  simulation (VOPR pattern; marionette on 0.16): deterministic Io swap,
  seed+commit reproducibility, time as data. Logic never reads
  clock/env/cwd — lifted inputs (leap_day: a `localtime()` failure hid a
  4-yearly bug behind 100% line coverage).
- **State is a parameter, not a capture** (`process(e, &count)`);
  sequence bugs like `(5,4)` after `(5,0)` become visible. Pure fns
  return new state.
- **Split at the bridges**: 27-path dispatch → 3-path loop + 6-path
  processor; each step provably independent. Prime-path count ≈
  cyclomatic complexity — keep low.
- **Allocator injection + fail-N**: failing allocator, fail Nth alloc
  from 0 until success — every OOM path exercised; failures you never see
  show up in coverage. Same for I/O errors (Tripwire-style injection
  proves `errdefer` runs).
- **Errors are values**: explicit error sets + comptime error-set sweeps
  (`inline for` over `@typeInfo(ErrorSet)`) exercise every error path at
  compile time.
- **Comptime exhaustiveness**: `try comptime testFn();` / `inline for`
  over enumerable domains (matklad: every sorted list ≤7 of 0..6) — the
  strongest coverage substitute Zig has.
- **`unreachable` is a claim**: marks impossible cases so coverage is
  honest; every uncovered path answered test/refactor/accept, never
  "test because coverage said so" (binary-search: 6 contradictions →
  refactor, not tests).
- **Determinism is a feature**: seeds injected, no wall-clock in logic,
  `Smith` fuzz at parser/decoder boundaries, metamorphic oracles where
  transforms exist (marble), mutation checks on the suite (zentinel) so
  coverage means detection.

A module that can't be deterministically driven or failure-injected is a
review finding, not a documented limitation.

## 3. Before you start

0. **Clean environment first — never lose work to a revert.** `jj st`:
   dirty change? `jj commit -m "wip: ..."` (checkpoint) or a fresh change.
   jj snapshots the working copy into the current change — a dirty tree
   mixes new work with WIP, and `jj restore`/abandon sweeps both.
   Risky/parallel work: `jj worktree add <path>` (git fallback:
   `git worktree add .worktrees/<feature>`, dir gitignored). Detect
   existing isolation first; never nest worktrees. Editing subagents get
   their own isolated worktree/change. Baseline tests must pass before
   the first edit — a red suite is provably yours.
1. Read this file again + `RULES.md`, `README.md`, `SPEC.md`/`docs/*.md`,
   `TODO.md`. Once per task.
2. Bug fixes: **red-green** — failing test first, prove it fails, then
   fix; regression tests exhibit the bug.
3. Features: agree test seams up front; vertical slices (test → impl →
   repeat), never horizontal dumps.
4. Non-trivial work: state plan (what/where/how verified) before editing;
   check §2 while planning.

## 4. Quality gates — definition of done

`verification-before-completion`: **no completion claim without fresh
evidence in the same turn.**

| # | Gate | Evidence |
|---|------|----------|
| 1 | Format | `zig fmt --check .` — zero diffs |
| 2 | Build | `zig build -Doptimize=Debug` + `ReleaseSafe` — exit 0 |
| 3 | Tests | `zig build test` Debug + ReleaseSafe — all green, zero leaks (`std.testing.allocator`) |
| 4 | Syntax | `zig ast-check` on every changed `.zig` |
| 5 | Compile-all | `refAllDecls` test in each root — unused decls still type-check |
| 6 | Lint | project linter (see §6) — zero errors on changed files |
| 7 | Coverage | measure changed paths (kcov 0.16 / zcov 0.17-dev); every uncovered path: test, refactor, or accept with a written reason |
| 8 | Static analysis | if configured: zwanzig (path-sensitive) / zippy (memory) — zero new findings |
| 9 | Sanitizers | optional: `-fsanitize-c=full`, `-fsanitize-thread`, valgrind (`-fvalgrind`) |
| 10 | Fuzz | parsers/decoders: `zig build test --fuzz=<bounded>` — no crashes, inputs replayed |

Density rule: 12/357 paths is noise; 352/357 makes each missing path a
judgment call. Coverage guides, never gates alone.

## 5. Reviewer workflow (MANDATORY after every implementation)

Non-optional for changes >1 file or touching shared code:

1. **Self-gates** (§4) — attach raw output (exit codes, counts), no
   summaries.
2. **Standards axis**: §1 + §2 + §4 + Fowler smells (mysterious names,
   duplication, feature envy, data clumps, primitive obsession, repeated
   switches, shotgun surgery, divergent change, speculative generality,
   message chains, middle man, refused bequest). Repo rules override
   baseline; smells are judgment calls. **§2 is a standard**: hidden
   inputs/state, non-injectable failure paths, non-deterministic seams =
   findings.
3. **Spec axis**: re-read task/issue — missing requirements, scope
   creep, wrong implementations; quote the spec line per finding.
4. **Spawn a reviewer subagent** (non-trivial diffs): diff range + this
   file + task. Reviewer independently runs gates 1–3, 6–8, re-checks
   both axes; findings per file, hard violations vs judgment calls,
   <400 words.
5. **Fix at root cause**; re-run failed gates.
6. **Report** (shape below). 3 failed fix attempts on one file → stop,
   escalate.

```
GATES: fmt=PASS build=PASS test=Debug 47/47 ReleaseSafe 47/47 leaks=0
       ast=OK refAllDecls=OK lint=0 coverage=NEW 91% (accepted: …)
REVIEW: Standards: N (worst: …) | Spec: N (worst: …)
FIXED: … | SKIPPED (reason): … | DEBT: (ceiling + trigger)
```

## 6. Tooling (pinned to Zig version)

- **Local tools preferred**: use the locally built binaries
  (`~/tools/ziglint`, `~/tools/zbc`, `~/tools/zcov`, `~/tools/zlint`,
  `~/tools/zls`) — they may be patched for this setup; prefer them over
  nixpkgs/system-installed versions.
- **One linter, recorded in repo**: `zlinter` (build.zig-integrated,
  `zig build lint`, custom rules — default) · `ziglint` (standalone
  style/API Z001–Z033) · `zlint` (standalone semantic; catches dead code
  the compiler skips). Deeper: `zwanzig` (path-sensitive CFG/ZIR) +
  `zippy` (build-graph memory lints) as separate opt-in CI jobs.
- **Coverage**: kcov on the global-cache test binary (0.16); zcov on
  0.17-dev (`use_llvm`, `fuzz`, `link_libc` in build.zig).
- **zls** tracks the pinned Zig version. Config files live in the repo
  (`zlinter.zon`/`.ziglint.zon`/`zlint.json`); suppressions are documented
  decisions, never blanket.

## 7. CI (mirror of the gates)

One job per gate group: `fmt → ast-check → test(Debug) →
test(ReleaseSafe) → lint → coverage (artifact + density comment) →
[fuzz: weekly] → [zwanzig/zippy: nightly]`

## 8. Committing

- Conventional Commits (`type(scope): subject`, ≤50 chars); atomic; tests
  pass in the commit.
- **Checkpoint often** (`jj commit -m "wip: ..."`) — a revert/`jj
  restore` then only undoes a bounded change, never a day of mixed edits.
- Verification evidence in the body when a gate drove a follow-up fix.
- Red gate blocks the push, not a workaround.

## 9. AI-slop guard (reviewers and agents self-check)

- **Obvious comments** (restating code, dividers, vague TODOs) — remove;
  KEEP why-comments.
- **Over-defensive code** — checks for guaranteed values, multi-layer
  duplicate validation. KEEP boundary validation; prove redundancy before
  deleting.
- **Excessive complexity** — nesting >3, god fns (>50 lines), long param
  lists (options struct), clever one-liners.
- **Needless abstraction** — single-use wrappers, speculative
  indirection, one-implementer interfaces.
- **Dead code** — unused decls/imports, debug leftovers
  (`std.debug.print` in non-test code).
- **Duplication** — extract only when intent is shared, not incidental
  similarity.
- **Missing tests** — behavior not locked by a regression test → add the
  narrowest test, don't remove code.
- **Oversized modules** — >250 pure LOC must split by responsibility
  (never `utils.zig`), plan shown first.
- **Performance equivalences** — only when provably equivalent; no
  hot-path micro-opts without a benchmark; unsure → SKIP.

When in doubt: **SKIP, don't guess.** Silent skips forbidden; report
`N/A` explicitly.
