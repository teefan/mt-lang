# Self-Host Plan

Status: **SELF-HOSTING FIXED POINT ACHIEVED.** Stage2 == stage3 byte-identical.
177/177 self-tests pass across 9 test files. **`mtc lint` has 27 rules**
across the self-host codebase (9 new Tier-1 AST rules, 1 ownership rule added).

Last updated: 2026-07-14

---

## 0. Current State

### 0.1 Bootstrap

```sh
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-current
tmp/mtc-current build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-stage2 --keep-c tmp/stage2.c
tmp/mtc-stage2 build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-stage3 --keep-c tmp/stage3.c
diff tmp/stage2.c tmp/stage3.c        # identical
tmp/mtc-stage2 test projects/mtc -I .  # 177/177, 0 failed
```

### 0.2 Example parity

13/13 examples build with the self-hosted compiler. 12/13 run identically to
Ruby; `async_stress_test` crashes under both (a pre-existing libuv runtime bug).

### 0.3 CLI parity

| Status | Commands |
|--------|----------|
| **FULL**  | lex, parse, lower, emit-c, format, help, version, check, build, run, test, lint |
| **NOT IMPL** | run-module, new, debug, deps, toolchain, bindgen, cache, docs, snapshot, completions |

**Core compiler commands (check/build/run/test) at full feature parity:**
platform-variant entry/import resolution, run exit-code forwarding (128+signal
for signals), build --clean, test --timeout/--mem sandboxing, -n filter,
--format tap|junit, compile-fail fixtures, @[expect_fatal] death tests.

**`mtc lint`** — 27 rules implemented. Warning counts (self-host / Ruby):
- prefer-let: 1458 / 425 (self-host detects more because scope tracking uses a
  broader `var`-is-never-reassigned check without requiring semantic facts)
- unused-import: 113 / 9
- unused-local: 89 / 28
- unused-param: 54 / 54 (matches Ruby)
- shadow: 27 / 3
- trailing-list-comma: 185 / 185 (matches Ruby)
- redundant-else: 11 / 11 (matches Ruby)

**`mtc check`** — diagnostic format matches Ruby byte-for-byte (`error[sema/error]:`,
rjust-5 gutter, 6-space caret line, summary). Analyzer now reports unknown type
annotations and undefined names (the two former `check`-silence bugs).

### 0.4 Landed fixes (all sessions)

**C-backend — array[T,N] inside structs (2026-07-14):**
- Root cause: the semantic analyzer returned `ty_error` for integer-literal
  type arguments (e.g. `32` in `array[ptr_uint, 32]`); the lowering's
  `qualify_type` (used for struct field types) did not resolve `ty_error` to
  `ty_literal_int`, so the C backend emitted `T field[0]` for every array
  field inside a struct.
- Fix: changed `resolve_named` in `analyzer.mt` to return
  `types.literal_int(parse_str_int(name))` when `is_all_digits(name)` is
  true, matching the Ruby compiler's `Types::LiteralTypeArg.new(value)`.
- Added `parse_str_int` helper alongside `is_all_digits`.
- Before: `uintptr_t scope_starts[0]; uintptr_t scope_counts[0];`
- After:  `uintptr_t scope_starts[32]; uintptr_t scope_counts[32];`

**Linter — scope tracking pass (2026-07-14):**
- Added `mtc.linter.scope_tracking` module with separate scope-tracking AST pass
  (~650 lines).
- Implements 5 scope-based rules: unused-local, unused-param, prefer-let,
  shadow, unused-import.
- Uses a flat pointer-based design: `ScopeCtx` stores a `ptr[ScopeEntry]`
  pointing to a stack-allocated `entries_buf: array[ScopeEntry, 512]` in
  `lint_scope_pass`, plus small `scope_starts`/`scope_counts` arrays for
  per-scope metadata.  This avoids the self-host C-backend
  `array[T,N]-inside-struct` bug (fixed separately — see above).
- Warning emission order: scope-based rules run after AST-only rules (separate
  pass), unlike Ruby's interleaved visitor.  This means the first-scope-seen
  ordering differs slightly, but all warnings are still emitted.

**Analyzer (semantic errors):**
- Unknown type annotations now reported (e.g. `let x: NoSuchType`)
- Undefined names now reported (e.g. `return typo_name`); match-arm bindings
  and destructuring names are bound into scope so they are not falsely reported

**Diagnostic-format parity:**
- `check` output matches Ruby: `error[sema/error]:` / `error[parse/error]:` /
  `error[module/error]:` with bracketed codes, rjust-5 line gutter, 6-space
  caret line, and `error: could not check due to N errors` summary

**CLI / Architecture:**
- run exit-code forwarding (was always 0; now forwards `normalized_code()`)
- run stderr routing (captured stderr → `terminal.write_stderr`)
- build --clean (removes resolved output artifact; idempotent)
- test --timeout/--mem sandboxing (per-runner `timeout` + `ulimit -v`)
- test -n/--name substring filter
- test --format tap|junit (TAP verified byte-identical to Ruby)
- test compile-fail fixtures (# expect-error:)
- test @[expect_fatal] death tests
- platform-variant entry/import resolution (confirmed in `check_program`)
- directory `check` UTF-8 crash fixed (was use-after-free on borrowed dir paths)
- directory `lint` silently-reporting-clean bug fixed (same UAF)
- parser now records `else` keyword line on `stmt_if` (was hardcoded 0)

**Language lowering (15182 lines, ~490 functions):**
- Loop break/continue with goto labels, async frame release, ready-flag
  ordering, CPS return defer ordering, match equality/guard patterns, CPS
  for-loop spilling, async main entrypoint, array-by-value C ABI
- Cached common types (`bool_ty`, `void_ty`, `ptr_void_ty` in `LowerCtx`)
- Naming consistency pass (`gsi_*` → `generic_instance_*`, etc.)
- **8 of 8 Ruby lowering modules analyzed: full parity on 7, partial on 1**
  - Type resolution (resolve) — **EXISTS** (all functions present)
  - Dyn trait objects — **EXISTS** (adapt, vtable, wrapper, cross-module)
  - Events — **EXISTS** (subscribe/emit/wait, runtime synthesis, snapshots)
  - str_buffer[N] — **EXISTS** (all 9 methods, struct emission)
  - Proc expressions — **EXISTS** (captures, env structs, invoke/release/retain)
  - Pre-lowering scans — **EXISTS** (enhanced — more explicit than Ruby)
  - Statement type coverage — **EXISTS** (all 18+ types; async CPS on 7)
  - Foreign cstr boundary — **PARTIAL** (basic `as cstr` works; cstr-list boundary and metadata tracking missing — see §2.7)

**Earlier fixes (cross-module, generics, async CPS core):**
- Cross-module same-name type collision, nullable fn-pointer locals, global var
  initializers, `str_buffer[N]` capacity, const comparison, compile-time
  reflection/type dispatch, format strings, async CPS core, match-binding CPS
  spilling, specialization label isolation, `ptr_of` recovery, etc.

---

**Linter — Tier 1 rules (2026-07-14):**
- Added 9 new AST-based lint rules to `linter.mt` (~1000 lines):
  - `missing-return` — non-void function whose body does not always return (error)
  - `prefer-inline-if` — multi-line if/else with single-statement branches (hint)
  - `prefer-or-pattern` — adjacent match arms with identical bodies (hint)
  - `prefer-conditional-expression` — if/match where every branch returns/assigns (hint)
  - `prefer-let-else` — `let x = expr; if x == null: ...` patterns (hint)
  - `prefer-try` — match over Option/Result that only propagates failure (hint)
  - `prefer-is-variant` — `match v: Arm: true; _: false` → `v is Arm` (hint)
  - `prefer-struct-with` — struct construction with copy-field arguments (hint)
  - `line-too-long` — lines exceeding 120 columns with UTF-8 char counting (warning)
- All implemented as AST-only structural heuristics (no sema_facts dependency).
- Warning counts (self-host): ~1089 line-too-long, 86 prefer-inline-if, 27
  prefer-conditional-expression, 7 prefer-or-pattern, ~12 prefer-let-else, 10
  prefer-try, 0 prefer-is-variant, ~6 prefer-struct-with, 0 missing-return.

**Linter — Tier 2 ownership rules (2026-07-14):**
- `owning-release-double` — AST-based sequential double-release detection (active).
  Detects `x.release()` called twice on the same local in the same scope.
  Produces 0 warnings on the self-host codebase (matches Ruby).
- `owning-release-leak` — deferred. The AST-only heuristic is too noisy without
  type information (`own[T]` vs `ptr[T]` distinction needs sema_facts).


## 1. Linter (27 / ~40 rules)

### 1.1 Implemented rules

#### Original AST-only rules (12 rules)

| Rule | Severity | Category |
|------|----------|----------|
| self-assignment | warning | AST-only |
| self-comparison | warning | AST-only |
| redundant-bool-compare | hint | AST-only |
| redundant-return | hint | AST-only |
| useless-expression | warning | AST-only |
| duplicate-if-condition | warning | AST-only |
| noop-compound-assignment | hint | AST-only |
| redundant-ignored-match-binding | hint | AST-only |
| redundant-else | hint | AST-only + flow |
| event-capacity | warning | AST-only (whole-file) |
| trailing-list-comma | hint | token-based (re-lexes source) |
| doc-tag | hint | source-line + AST |

#### Scope-tracking rules (5 rules)

| Rule | Severity | Category |
|------|----------|----------|
| unused-local | warning | scope-based |
| unused-param | warning | scope-based |
| prefer-let | hint | scope-based |
| shadow | warning | scope-based |
| unused-import | hint | module-level |

#### New Tier 1 rules (9 rules, added 2026-07-14)

| Rule | Severity | Category |
|------|----------|----------|
| line-too-long | warning | source-level |
| missing-return | error | AST-only |
| prefer-inline-if | hint | AST-only |
| prefer-or-pattern | hint | AST-only |
| prefer-conditional-expression | hint | AST-only |
| prefer-let-else | hint | AST-only + flow |
| prefer-try | hint | AST-structure |
| prefer-is-variant | hint | AST-structure |
| prefer-struct-with | hint | AST-structure |

#### Ownership rules (1 new rule)

| Rule | Severity | Category |
|------|----------|----------|
| owning-release-double | warning | AST-only |

### 1.2 Remaining lint rules (deferred)

Below are the ~23 missing lint rules categorised by their *prerequisite work*.
The self-host already covers the heavy machinery (AST visitors, scope tracking,
`always_returns`, `body_can_break`) so the gap is narrower than it first looks.

#### 1.2a AST-only — 9 of 10 now implemented

| Rule | Status |
|------|--------|
| `missing-return` | **DONE** |
| `prefer-inline-if` | **DONE** |
| `prefer-conditional-expression` | **DONE** |
| `prefer-or-pattern` | **DONE** |
| `prefer-let-else` | **DONE** (AST-structural heuristic; no sema_facts needed) |
| `prefer-var-else` | Not yet implemented |
| `prefer-try` | **DONE** (AST-structural heuristic) |
| `prefer-is-variant` | **DONE** (AST-structural heuristic) |
| `prefer-struct-with` | **DONE** (AST-structural heuristic) |
| `line-too-long` | **DONE** (UTF-8 char-width counter, 120-char default) |

#### 1.2b Ownership — 1 of 2 implemented

| Rule | Status |
|------|--------|
| `owning-release-leak` | DEFERRED (needs sema_facts for `own[T]` type detection) |
| `owning-release-double` | **DONE** (AST-only sequential release detection) |

#### 1.2c Semantic-facts — needs `@sema_facts` integration

The self-host does not yet thread resolved-binding information into the
linter visitor (the Ruby `@sema_facts` object that maps every AST identifier to
its binding kind, declared type, owner module, etc.).

| Rule | Category | Notes |
|------|----------|-------|
| `redundant-cast` | hint | Needs type info per expression |
| `redundant-type-annotation` | hint | Needs type info per `let`/`var` |
| `prefer-own-ptr` | hint | Needs to know when a variable has `own[T]` type |
| `reserved-primitive-name` | warning | Needs binding resolution (is the name a local shadowing a primitive?) |
| `borrow-and-mutate` | warning | Needs `ref` vs value tracking per expression |

#### 1.2d Full CFG — needs graph builder + flow solvers

These rules require a proper Control-Flow Graph (nodes with succ/pred edges,
read/write sets, edge labels) plus analysis passes run over that graph.  The
self-host `builder.mt` today only assigns name→ID; it has no graph, no edges,
no read/write sets, and no solvers.

The Ruby pipeline for these rules is:

```
CFG Builder (graph with edges + read/write sets)
  → Reachability (identifies unreachable nodes)
  → NullabilityFlow (null/non-null across branches)
  → ConstantPropagation (always-true/false conditions)
  → Liveness (variable live/dead at each node)
  → Termination (nodes that always exit)
```

| Rule | Needs (minimum) | Notes |
|------|----------------|-------|
| `dead-assignment` | Builder + Liveness | Find writes that are never read |
| `unreachable-code` | Builder + Reachability | Nodes with no path from entry |
| `constant-condition` | Builder + ConstantPropagation | Always-true/false in if/while |
| `redundant-null-check` | Builder + NullabilityFlow | Null check after !null branch |
| `loop-single-iteration` | Builder + Termination | Loop whose body always breaks |

#### 1.2e Tooling

| Gap | Notes |
|-----|-------|
| `--select` / `--ignore` | Filter rules by code; CLI parsing is stubbed (`main.mt:455`) |
| `--fix` | Auto-fix lint violations in-place |
| `.mt-lint.yml` config | Per-project lint configuration file |

---

## 2. Remaining work (ordered by impact ÷ effort)

### 2.1 Tier 1 — AST-only — COMPLETED (9 of 9 rules)

All 9 Tier-1 rules are now implemented. ~1361 additional warnings generated across the self-host codebase.

| # | Rule | Ruby warnings | Status |
|---|------|--------------|--------|
| 1 | `line-too-long` | **1089** | **DONE** — UTF-8 char-width counter, 120-char default |
| 2 | `prefer-inline-if` | 85 | **DONE** |
| 3 | `prefer-or-pattern` | 76 | **DONE** |
| 4 | `prefer-conditional-expression` | 65 | **DONE** |
| 5 | `prefer-let-else` | 20 | **DONE** |
| 6 | `prefer-try` | 10 | **DONE** |
| 7 | `prefer-is-variant` | 6 | **DONE** |
| 8 | `prefer-struct-with` | 5 | **DONE** |
| 9 | `missing-return` | 0 | **DONE** |

### 2.2 Tier 2 — Ownership AST fallback — PARTIAL (1 of 2 rules)

| # | Rule | Ruby warnings | Status |
|---|------|--------------|--------|
| 10 | `owning-release-leak` | 148 | DEFERRED — needs sema_facts for `own[T]` type detection |
| 11 | `owning-release-double` | 0 | **DONE** — AST-only sequential release detection |

### 2.3 Tier 3 — Semantic-facts rules (5 rules, 75 warnings, blocked on §2.4)

These need `@sema_facts` — a per-identifier table from the analyzer mapping
each AST identifier to its resolved binding (kind, type, module).  Currently
the self-host linter has no access to this data.

| # | Rule | Ruby warnings | Prerequisite from sema_facts |
|---|------|--------------|------------------------------|
| 12 | `prefer-own-ptr` | 38 | Is variable `own[T]` vs `ptr[T]`? |
| 13 | `redundant-cast` | 37 | Expression type vs target cast type |
| 14 | `redundant-type-annotation` | 0 | Declared type annotation vs inferred type |
| 15 | `reserved-primitive-name` | 0 | Does local/param name shadow a primitive type name? |
| 16 | `borrow-and-mutate` | 0 | Does expression yield `ref[T]` while a `T` is also borrowed? |

### 2.4 Tier 4 — Full CFG (5 rules, 9 warnings, needs 7-layer infrastructure)

These require a proper Control-Flow Graph with nodes, edges, read/write sets,
and edge labels — none of which the self-host `builder.mt` (name→ID pre-scan)
provides.  The Ruby CFG is ~2,100 lines across 9 modules.

| # | Rule | Ruby warnings | Minimum CFG layer |
|---|------|--------------|-------------------|
| 17 | `dead-assignment` | 3 | Builder + Liveness |
| 18 | `unreachable-code` | 2 | Builder + Reachability |
| 19 | `redundant-null-check` | 2 | Builder + NullabilityFlow |
| 20 | `loop-single-iteration` | 2 | Builder + Termination (or ConstantPropagation) |
| 21 | `constant-condition` | 0 | Builder + ConstantPropagation |

**Combined impact: 9 warnings.** This is < 0.4% of the remaining warning gap.
CFG infrastructure is useful for correctness (dead-assignment, unreachable-code
are real bugs when they fire), but the warning-count return on investment is
minimal.  This tier should be re-evaluated once Tier 1–3 are complete.

### 2.5 Lowering correctness gaps

| # | Gap | Impact | Notes |
|---|-----|--------|-------|
| 22 | Match expression hoisting (`lowering.mt:9214`) | **Correctness**, zero occurrences in self-host codebase | Non-return-position multi-arm match expressions emit a placeholder `match_expr` IR node.  `return match` is fine; `let x = match {...}` would silently produce wrong C. |
| 23 | Foreign cstr list boundary | **Zero occurrences in self-host codebase** | `str[] → cstr[]` conversion for foreign function params.  Only affects foreign functions with `span[str]` parameters — none exist in the self-host. |

### 2.6 Tooling

| # | Gap | Effort |
|---|-----|--------|
| 24 | `--select` / `--ignore` | Small — CLI parsing stubbed at `main.mt:455` |
| 25 | `--fix` | Medium — per-rule auto-fix logic |
| 26 | `.mt-lint.yml` config | Medium — TOML parsing + rule config |
| 27 | Wire lint into `check` (`lint_tier: :full`) | Small — call `lint_source` from `check_program` |

### 2.7 Out-of-scope subsystems (separate projects)

| Gap | Effort | Notes |
|-----|--------|-------|
| Package-graph resolution (`--locked`/`--frozen`) | Large | `PackageGraph`, `PackageManifest`, dependency solver |
| Build cache | Large | Hash-keyed caching of compiled C + binaries |
| `--bundle` / `--archive` | Medium | `assets.mtpack`, tar.gz |
| Wasm compilation (emcc) + preview server | Large | Emscripten linker flags, HTML shell |
| `--jobs` parallel test execution | Medium | `fork`-based orchestration |
| `--sanitize` | Medium | `-fsanitize=address` + skip ulimit cap |
| Self-hosted test-runner build | Large | Build runners via `argv[0]` statt `bin/mtc` |
| `run-module`, `new`, `debug`, `deps`, `toolchain`, `bindgen`, `cache`, `docs`, `snapshot`, `completions` | Varies | Non-core CLI commands |
