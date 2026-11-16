# Refactoring the Self-Host Compiler

`projects/mtc` is ~167 files / ~155k lines. The parity harnesses prove observable
behavior; they say nothing about shape. This document is the refactoring safety
suite: what is locked, what is ratcheted, and the protocol for changing the
self-host without changing what it does.

The suite has two layers:

1. **Behavior lock** — every host-vs-self oracle plus the in-language suites, run
   from one gate set. Exact-parity gates (`cli_parity`, `sexpr lex/parse`,
   `diag_parity`, `format`, `unused_import`) are **hard**: a diff stops the run.
   `sexpr lower` stays a meter for its two documented artifacts.
2. **Structure ratchet** — `tools/refactor_guard.rb` measures layering, naming,
   dead exports, duplication, size, markers, and test-tree counts, with a
   committed baseline and growth checks.

## 1. The one command

```sh
tools/gates.sh --areas refactor --run
```

Tier 1 (fast, per edit): dev build, the 21-file self-host suite, the structural
guard. Tier 2 (once per commit, on frozen sources): `test/mt` under stage2, the
224-case CLI matrix, and the parity scoreboard. Logs land in `tmp/gates/`.

Print the set without running it with `tools/gates.sh --areas refactor`.
Source-area diffs now automatically include `dev_tests` and `refactor_guard`.

## 2. The structural guard

`tools/refactor_guard.rb` (implementation:
`lib/milk_tea/tooling/refactor_guard.rb`) is textual and fast (~2 s), so it is
safe to run on every edit.

```sh
ruby tools/refactor_guard.rb                  # human report
ruby tools/refactor_guard.rb --check          # hard invariants (gate)
ruby tools/refactor_guard.rb --check --strict # + new dead exports
ruby tools/refactor_guard.rb --check --strict --ratchet  # + growth checks
ruby tools/refactor_guard.rb --write-baseline # refresh the committed baseline
ruby tools/refactor_guard.rb --json FILE      # full machine-readable report
```

### Layering

Every top-level area has a rank (0 foundational → 10 CLI). An import may target
an equal or lower rank; same-rank cycles are allowed (Milk Tea supports them).
An unclassified module or import target is a violation, so a new file must be
classified deliberately. The rank table lives in `LAYER_RANKS`; legitimate
upward edges would go in `ALLOWED_UPWARD` with a reason.

Current graph: **111 edges, 0 violations**. Notable same-rank peers:
`semantic`/`c_naming` (type-name mangling), `linter`/`formatter` (fix candidates
use tidy), `pretty_printer`/`ir` (the IR formatter), and
`imported_bindings`/`formatter`.  `strings` is the shared rank-0 text leaf; the
C backend's former `lowering.utils` dependency is gone.

### Naming

- files: `[a-z][a-z0-9_]*.mt`
- functions/events: `snake_case`
- `struct|enum|variant|type|interface`: `PascalCase`
- top-level `const`: `UPPER_SNAKE`

The current tree has **0 violations**.  The naming-foundation pass fixed the
13 baselined deviations (12 lowercase constants, `DeclarationTokenOf`) and
kept the rule strict afterwards.

### Import aliases

One effective alias per module: `semantic.types` is always `types`,
`lexer.token` always `token_mod`, and so on.  The guard derives the canonical
alias from the tree (majority; the longer alias breaks a tie), and `--check`
fails on a deviation, a duplicate import of the same module, or two targets
sharing one alias in a file.  `packages.source` is the single override
(`pkg_source`) because both `source` and `package_source` are common
locals/parameters in the files that use it.

Current state: **167 modules, 0 alias violations**.

### Operation vocabulary

One spelling per operation family: `create_*` constructs a value, `alloc_*`
allocates memory, `find_*` searches a collection/table, `resolve_*` resolves a
name/type, `render_*` produces text, `emit_*` writes C source, and compiler
nodes use the short `decl`/`expr` nouns already carried by their types.  The
retired spellings (`new_*`, `lookup_*`, `*_declaration`, `*_expression`) are a
hard, baseline-diffed guard violation, so a new inconsistency fails at the
gate.

### Dead exports

Top-level `public` declarations are indexed against every identifier in
`projects/mtc/src` and both test trees. `unused` = no reference anywhere;
`test_only` = referenced only by tests. It is a candidate list, not a proof:
textual counting cannot see aliasing or dynamic dispatch, and names are matched
globally (two modules exporting the same name can mask each other). Existing
candidates are frozen; a **new** one fails `--strict`.

Current baseline: **35 unused, 6 test-only**. Examples worth triaging:
`c_backend.CBackendError`, `lowering.LoweringError`, `lowering/async.mt` type
helpers, `lsp/navigation.mt analysis_for_document`/`ast_for_document`,
`packages/*` helpers, and `version_info.GIT_REVISION`.

### Duplication

Normalized 12-line windows (comments/blanks stripped, literals replaced with
`S`/`N`) hashed across all functions. Overlapping windows make the cluster count
large; `duplicated_lines` is the ratcheted metric. Current baseline:
**5,154 duplicated lines in 766 window clusters**. Use the clusters as pointers
to repeated emission/frame boilerplate, not as an absolute quality score.

### Size, markers, tests

- **123,746 code lines**; **28 functions ≥ 200 lines**; **11 files ≥ 2,000 code
  lines**. The ratchet counts these, so a refactor cannot trade one long
  function for another.
- **0 marker comments** (`TODO`/`FIXME`/`XXX`/`HACK`); any new one fails.
- Test trees: **21** files in `projects/mtc/test`, **61** in `test/mt`. The
  ratchet fails if either count drops (silent-skip protection).

## 3. The refactor protocol

1. **Baseline first.**
   ```sh
   tools/gates.sh --areas refactor --run
   ```
   It must be green before you start. If the baseline is stale, refresh it in a
   separate commit and explain why.

2. **Iterate cheap.**
   ```sh
   ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev   # ~35 s
   tmp/mtc-dev test projects/mtc -I . --timeout 120                        # 21 files
   ruby tools/refactor_guard.rb --check
   ```
   Then the focused parity harness for the class you touched (lint, sexpr,
   CLI, LSP, formatter). Count the test files, not just `0 failed` — `mtc test`
   silently skips a file that fails to lex/parse.

3. **Measure before and after.**
   ```sh
   ruby tools/refactor_guard.rb --json tmp/refactor-before.json
   # ... refactor ...
   ruby tools/refactor_guard.rb --json tmp/refactor-after.json
   ```
   Compare code lines, long-function count, file-size count, and
   `duplicated_lines`. A refactor should not grow any of them.

4. **Prove on frozen sources.**
   ```sh
   tools/gates.sh --areas refactor --run
   ```
   No source edits while a gate runs (`bootstrap.sh` compiles the working tree).

5. **Land one mechanical change per commit**, with its FIXTURE/test update and
   this file's baseline refresh when the structure intentionally changed.

## 4. Body-local dead code

The guard is module-level. For function-local dead code, run the linter's
dead-code subset and compare the count with the previous pass:

```sh
tmp/mtc-dev lint projects/mtc/src \
  --select unused-local,unused-param,dead-assignment,unreachable-code,useless-expression,self-assignment,duplicate-if-condition
```

`mtc lint` exits 1 on any warning (including hints), so record the warning count
rather than gating on the exit status. Do not run the full 43-rule lint: the
tree has ~2,900 long lines and known hint noise, and `lint` is not a cleanliness
gate here.

## 5. Baseline policy

`tools/refactor_baseline.json` is committed. Refresh it **only** when a change
deliberately alters the structure:

- a new module/area (classify it in `LAYER_RANKS` first),
- a new public API that is legitimately unreferenced at landing time,
- a refactor that removes duplication, shortens functions, or renames a
  baselined identifier.

Review the baseline diff like code: it should shrink or be explained. Never
refresh it to silence a check. The invariants (layering, naming, markers) do
not depend on line counts, so ordinary feature commits do not need a refresh.

## 6. Current baseline (session 124, 2026-11-14)

| Metric | Value |
| --- | --- |
| source files / lines / code lines | 167 / 155,611 / 123,746 |
| layering edges / violations | 111 / 0 |
| naming violations | 0 |
| vocabulary violations | 0 |
| alias violations | 0 (167 modules) |
| dead exports (unused / test-only) | 35 / 6 |
| duplication (windows / duplicated lines) | 766 / 5,154 (window 12) |
| functions ≥ 200 lines | 28 |
| files ≥ 2,000 code lines | 11 |
| markers | 0 |
| test files (projects/mtc / test/mt) | 21 / 61 |
