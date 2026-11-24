# Refactoring the Self-Host Compiler

`projects/mtc` is ~169 files / ~163k lines. The recorded oracles and the
in-language suites prove observable behavior; they say nothing about shape.
This document is the refactoring safety suite: what is locked, what is
ratcheted, and the protocol for changing the self-host without changing what it
does.

The suite has two layers:

1. **Behavior lock** — the recorded oracles plus the in-language suites.  The
   `golden_cli`/`golden_diag`/`golden_lint`/`golden_format` replays and
   `test/mt` are hard: a diff stops the run.
2. **Structure ratchet** — `tools/refactor_guard.rb` measures layering, naming,
   dead exports, duplication, size, markers, and test-tree counts, with a
   committed baseline and growth checks.

## 1. The one command

```sh
tools/gates.sh --areas refactor --run
```

Tier 1 (fast, per edit): dev build, the 22-file self-host suite, the structural
guard. Tier 2 (once per commit, on frozen sources): `test/mt` under stage2 and
the 227-case CLI golden. Logs land in `tmp/gates/`.  The other recorded oracles
are in the `oracles` area; run them when the shared compiler code moves.

Print the set without running it with `tools/gates.sh --areas refactor`.
Source-area diffs now automatically include `dev_tests` and `refactor_guard`.

## 2. The structural guard

`tools/refactor_guard.rb` (implementation:
`tools/lib/refactor_guard.rb`) is textual and fast (~2 s), so it is safe to run
on every edit.  The implementation uses only the Ruby standard library and does
not load the compiler, so it survives the Ruby host's retirement.

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

Current state: **169 modules, 0 alias violations**.

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

Current baseline: **30 unused, 7 test-only**. Examples worth triaging:
`c_backend.CBackendError`, `lowering.LoweringError`, `lowering/async.mt` type
helpers, `lsp/navigation.mt analysis_for_document`/`ast_for_document`,
`ir.TypeId`, and the `packages/*` helpers.

### Duplication

Normalized 12-line windows (comments/blanks stripped, literals replaced with
`S`/`N`) hashed across all functions. Overlapping windows make the cluster count
large; `duplicated_lines` is the ratcheted metric. Current baseline:
**6,499 duplicated lines in 882 window clusters**.  Session 125 fixed the
function-end scan for multi-line signatures, so this baseline includes bodies
the earlier metric skipped; session 126's splits also shifted a few window
boundaries, session 131's completion/diagnostic feature growth added two
windows, and session 132's format-string context added one shared
parameter-loop window.  Sessions 149–154's memory and cache work added the
boxed `Type`-payload deref idiom (`let x_bp = unsafe: read(x.payload)`) and the
LSP cache-release helpers (+55 duplicated lines, −11 clusters).  Session 155's
static-libuv and version/help work removed ten duplicated lines, and session
156's outline change removed the duplicated type-parameter emission (16 more
lines, 3 clusters).  None is a duplication regression.  Use the clusters as pointers to repeated
emission/frame boilerplate, not as an absolute quality score.

### Area inference

`tools/gates.sh` infers areas from `git diff` and maps each to a gate set.  A
path with no case used to land in `other`, whose gate list is empty — a change
to `lexer/`, `main/`, `bindgen/` or a top-level file such as `ir.mt` planned
**zero** gates and exited 0.  Those now map to `parser`, `cli`, `bindings` and
`compiler_core` respectively, and an unclassified path is a hard error naming
the file.  CI does not use area inference (it runs a fixed list), so this hole
affected the local loop only.

### Size, markers, tests

- **129,509 code lines**; **3 functions ≥ 200 lines** (`binding_at` 385,
  excluded, `collect_binding_flags` 211, and `resolve_cursor` 200, exactly at
  the boundary); **11 files ≥ 2,000 code lines**. The ratchet counts these, so a
  refactor cannot trade one long function for another.
- **0 marker comments** (`TODO`/`FIXME`/`XXX`/`HACK`); any new one fails.
- Test trees: **22** files in `projects/mtc/test`, **85** in `test/mt`. The
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
   "$(tools/bootstrap.sh --print-stage0)" build projects/mtc -I . --no-cache -o tmp/mtc-dev   # ~25 s
   tmp/mtc-dev test projects/mtc -I . --timeout 120                        # 22 files
   ruby tools/refactor_guard.rb --check
   ```
   Then the recorded golden for the class you touched
   (`tools/gates.sh --areas oracles --run`). Count the test files, not just
   `0 failed` — `mtc test` silently skips a file that fails to lex/parse.

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

## 6. Current baseline (session 159, 2026-11-24)

| Metric | Value |
| --- | --- |
| source files / lines / code lines | 169 / 163,121 / 129,509 |
| layering edges / violations | 112 / 0 |
| naming violations | 0 |
| vocabulary violations | 0 |
| alias violations | 0 (169 modules) |
| dead exports (unused / test-only) | 30 / 7 |
| duplication (windows / duplicated lines) | 882 / 6,499 (window 12) |
| functions ≥ 200 lines | 3 |
| files ≥ 2,000 code lines | 11 |
| markers | 0 |
| test files (projects/mtc / test/mt) | 22 / 85 |

Session 159 refreshed the baseline for the audit fixes (+54 code lines): the
dynamic scope store in `linter/scope_tracking.mt` (the fixed 32×128 window is
gone), the LSP platform plumbing (`Workspace.platform` plus
`resolver.platform_from_label`, one new `main -> debug_map` edge, a legal
downward import), and `mtc test`'s debug-map sidecar cleanup.  Duplication,
function/file sizes and test counts are unchanged.

Session 158 refreshed the baseline for the Box2D migration's compiler fixes:
C keywords used as struct/union/SoA/variant fields are escaped in declarations,
member accesses, aggregate designators and equality guards; aggregate equality
registers the external layout for either operand (checked-index element and
parameter forms); and the equality pre-scan now descends blocks, `for` init/post
and `static_assert`.  The change added 13 code lines and raised the long-function
count to 3 (`binding_at` 385, `collect_binding_flags` 211, `resolve_cursor` 200).

Session 156 removed the `documentSymbol` type-parameter children and their
two helpers (−74 code lines, −16 duplicated lines, −3 clusters), then added the
reproducible temp-C naming, the OpenSSL 3 wrapper and the `$CC` forwarding in
the bootstrap (+78 code lines); no layering, alias or vocabulary invariant
moved.

Session 155 refreshed the baseline for the static-libuv link-order fix and
stale-prefix cleanup (+26 code lines) and the 0.5.0 version/help text; the
later libuv support-path fix (the fs/process/sync test-runner include and link
paths) added 10 more.  The comment churn left the duplication scan ten lines
shorter.  The version move does not change the layering, alias or vocabulary
invariants.

Session 154 refreshed the baseline for the LSP per-document cache eviction and
the map-key release (+56 code lines).  Session 153 added the `generate_c`
emitter release (+43).  Session 152 added the per-file region gate and
`reserve_exact` (129,337 code lines).  Sessions 149–151 added the memory
program's boxing (`Type` 72 → 24 B; the `payload` deref idiom accounts for most
of the growth) and the IR formatter's append-only emitters (session 151, +273).
The long-function count was 2 at session 154: `binding_at` (385, excluded) and
`resolve_cursor` (200, exactly at the boundary); session 158 added
`collect_binding_flags` (211).  The baseline records all three.

Session 148 refreshed the baseline for the aliased enum-member hover (+108
code lines: the alias target resolution, the program-analysis lookup, the
declaring-module scan, and the conformance case's harness-only code excluded
from this count).  Duplication, sizes and test counts are unchanged.
Session 147 refreshed the baseline for the non-text receiver completion
extension (+69 code lines: the parser's empty-name member recovery, the
analyzer's incomplete-access fact, and the completion fallback/helper split).
Duplication, sizes and test counts are unchanged.
Session 146 refreshed the baseline for the warning-anchor work (+30 code
lines: the five position emitters, the null-check condition carry, and the
unreachable statement-column fallback; the shifted baseline key for the
pre-existing `reserved_name_fixes` export).  Duplication, sizes and test counts
are unchanged.
Session 145 refreshed the baseline for the LSP position-encoding work (+253
code lines: negotiated UTF-8/UTF-16 boundaries, the per-document line-start
map, and the emitter audit; +106 duplicated lines from the per-module
conversion pattern; `position_to_byte` renamed to the two explicit decoders).
Phase 2 added the completion-resolve declaration scan, lifecycle/version state
and the semantic-token cache key fix (+188 code lines, +1 layering edge
`lsp -> cli_help`; duplication unchanged).  Phase 3 added multi-root state, the
`willRenameFiles` import rewrite, the watched-file registration and the
workspace-folder notification handler (+396 code lines; edges and duplication
unchanged).  Phase 4 added the workspace-wide diagnostic report and dependent
refresh requests (+82 code lines, +2 duplication clusters / 26 duplicated
lines).  Phase 5 added rangesFormatting, the shared refresh module and
progress/partial-result transport (+201 code lines, one new file; the
formatting helpers removed 10 duplication clusters / 7 duplicated lines).
Session 141 added the semantic conformance port (+522 code lines: condition
enforcement, named-argument canonicalization and lowering, extern/foreign
checks, imported/method specialization checks, and the exact-base nullable
rule; +2 duplicated lines).  Session 140 refreshed the baseline for the
per-document text cache, receiver facts and match dispatch (+244 code lines).
Session 139 added the call-argument compatibility port (+249 code lines:
per-parameter expected-type inference, the table-free literal fold, the
substituted-specialization check, and the array/span construction hints;
duplication unchanged).  Session 131 added the completion/diagnostic feature set (+296 code lines, +2
duplication windows, +1 test file); dead exports dropped from 35 to 33 as the
superseded cursor helpers were removed.  Session 132 added the format-string
completion context (+185 code lines, +1 shared parameter-loop window); the
`enclosing_function_for` scan is shared by the global bucket and the new
context, and the last parse-error hover bail was removed.  Session 133's audit
fixes removed the dead O(file²) hover scan (−30 lines), shared the hierarchy
item-field reader across the two hierarchy modules (−48 duplicated lines,
−13 windows), and added the imported enum member source line, the
hierarchy follow-up unwrapping and the specialization registration order.
The remaining function over the limit is the excluded `binding_at` (385).

Session 134 added the shared `lsp/fstring.mt` splitter (moved out of
`semantic_tokens`), the shared type-field lookup (moved from completion to
navigation), and the one-document token/binding caches (+413 code lines, −28
duplicated lines, −3 windows).  The caches are deliberately one-document: the
hover path only holds a span within the helper that fetched it, and the handoff
notes the multi-entry change any cross-file span would require.  Session 135's
chained-hover audit added file-scoped module resolution
(`resolve_module_source_path_for`), match-arm payload-field hover, the `str`
type key/builtin fields, and the self-better imported-variant-arm hover (+160
code lines, −12 duplicated lines, −6 windows).
