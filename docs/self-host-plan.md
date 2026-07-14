# Self-Host Plan

Status: **SELF-HOSTING FIXED POINT ACHIEVED.** Stage2 == stage3 byte-identical.
177/177 self-tests pass across 9 test files. **`mtc lint` has 17 rules**
across the self-host codebase.

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

**`mtc lint`** — 17 rules implemented (12 AST-only + 5 scope-based via separate
`mtc.linter.scope_tracking` pass). All rules verified byte-identical to Ruby
across the entire self-host codebase (stage3 lint works end-to-end after the
`array[T,N]` C-backend fix). Warning counts (self-host / Ruby):
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

**Language lowering:**
- Loop break/continue with goto labels, async frame release, ready-flag
  ordering, CPS return defer ordering, match equality/guard patterns, CPS
  for-loop spilling, async main entrypoint, array-by-value C ABI
- Cached common types (`bool_ty`, `void_ty`, `ptr_void_ty` in `LowerCtx`)
- Naming consistency pass (`gsi_*` → `generic_instance_*`, etc.)

**Earlier fixes (cross-module, generics, async CPS core):**
- Cross-module same-name type collision, nullable fn-pointer locals, global var
  initializers, `str_buffer[N]` capacity, const comparison, compile-time
  reflection/type dispatch, format strings, async CPS core, match-binding CPS
  spilling, specialization label isolation, `ptr_of` recovery, etc.

---

## 1. Linter (17 / ~40 rules)

### 1.1 Implemented rules

#### AST-only rules (12 rules, all byte-identical to Ruby)

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

#### Scope-tracking rules (5 rules, in `mtc.linter.scope_tracking`)

| Rule | Severity | Category |
|------|----------|----------|
| unused-local | warning | scope-based |
| unused-param | warning | scope-based |
| prefer-let | hint | scope-based |
| shadow | warning | scope-based |
| unused-import | hint | module-level |

### 1.2 Remaining lint rules (deferred)

Below are the ~23 missing lint rules categorised by their *prerequisite work*.
The self-host already covers the heavy machinery (AST visitors, scope tracking,
`always_returns`, `body_can_break`) so the gap is narrower than it first looks.

#### 1.2a AST-only — implementable today

These rules work purely on the AST; the self-host already has all the
ingredients (`always_returns_stmts`, `stmt_always_returns`,
`block_is_nonempty`, `is_true_literal`, etc.):

| Rule | Category | What it checks |
|------|----------|----------------|
| `missing-return` | error | Non-void function whose body does not always return (uses `always_returns_stmts`) |
| `prefer-inline-if` | hint | Multi-line `if`/`else` where each branch is a single-statement single-line form |
| `prefer-conditional-expression` | hint | `if x: return a else: return b` → `return if x: a else: b` |
| `prefer-or-pattern` | hint | Adjacent match arms with identical bodies → merge with `\|` |
| `prefer-let-else` | hint | `let x = expr; if x != null:` → `let x = expr else:` |
| `prefer-var-else` | hint | Same for `var` declarations |
| `prefer-try` | hint | `match opt: Option.some as v: v else: return ...` → `opt?` |
| `prefer-is-variant` | hint | `match v: Arm: true; _: false` → `v is Arm` |
| `prefer-struct-with` | hint | Struct copy with one field changed → `struct.with(field = val)` |
| `line-too-long` | warning | Line length > configurable max (needs UTF-8 char width, not byte length) |

#### 1.2b Ownership — AST fallback exists in Ruby

| Rule | Category | Notes |
|------|----------|-------|
| `owning-release-leak` | warning | Ruby has CFG-based check *and* an AST fallback (`check_owning_release_leaks`). The AST fallback is pattern-matching only — detect `own[T]` locals that are never passed to `release`/`release_and_null`. |
| `owning-release-double` | warning | Same as above: AST fallback detects sequential `release` on the same name. |

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

## 2. Remaining work

### 2.1 AST-only lint rules (10 rules)

These can be implemented today — no infrastructure prerequisites.  The
self-host linter already has the full AST visitor framework plus key
helpers (`always_returns_stmts`, `body_can_break`, `is_true_literal`,
`block_is_nonempty`, `terminating_expression`).

| Priority | Rules | Est. effort |
|----------|-------|-------------|
| High | `missing-return` | Small — wraps `always_returns_stmts` at function-level |
| Medium | `prefer-inline-if`, `prefer-let-else`, `prefer-var-else` | Small — per-statement pattern matching |
| Medium | `prefer-conditional-expression` | Small — detect if-match-return pattern |
| Medium | `prefer-or-pattern`, `prefer-is-variant`, `prefer-try`, `prefer-struct-with` | Small — per-expression pattern matching |
| Low | `line-too-long` | Medium — needs UTF-8 character-width count + formatter max-length |

### 2.2 Ownership rules (2 rules, AST fallback)

The Ruby linter has a two-tier implementation for `owning-release-leak`
and `owning-release-double`:
1. **CFG-based** — precise, requires full graph + solvers
2. **AST fallback** — pattern matching without CFG

The AST fallback can be ported now.  It detects: (a) `own[T]` locals declared
but never passed to `release`/`release_and_null` (leak), and (b) the same name
passed to `release` twice along a sequential path (double-free).

`borrow-and-mutate` requires `@sema_facts` (needs ref/value tracking per
expression) and is blocked on §2.4.

### 2.3 Control-Flow Graph (6 rules blocked on full CFG)

The self-host CFG (`builder.mt`, 132 lines) is currently a name→ID pre-scan.
It has no graph nodes with edges, no read/write sets, and no flow solvers.
The Ruby CFG has 9 modules (580-line builder + 8 solver modules totalling
~1,500 lines).

To unlock the 6 flow-based lint rules, the following would need to be built:

| Layer | What | Used by |
|-------|------|---------|
| 1. Graph data structure | Nodes with succ/pred edges, read/write sets, edge labels (true/false branch), edge refinements (null-checks) | All rules |
| 2. Builder | Walk the AST and construct the graph with nodes and edges, recording reads/writes per node | All rules |
| 3. Reachability | Forward dataflow: which nodes are reachable from entry? | `unreachable-code` |
| 4. NullabilityFlow | Forward dataflow: is each nullable pointer null or non-null at each node? | `redundant-null-check` |
| 5. ConstantPropagation | Forward dataflow: which expressions evaluate to a constant at each node? | `constant-condition`, `loop-single-iteration` |
| 6. Liveness | Backward dataflow: which variables are live at each node? | `dead-assignment` |
| 7. Termination | Detect nodes that always return/break/continue from their subtree | `loop-single-iteration` |

The graph data structure and builder are the heaviest items (the Ruby builder
is 580 lines of per-statement-kind node/edge construction).  The solvers
(reachability, nullability, constant-prop, liveness) are each ~100-200 lines
of standard dataflow-algorithm code — mechanical but low-risk.

### 2.4 Semantic-facts integration (5 rules blocked)

The Ruby linter receives `@sema_facts` — a per-identifier table produced by
the semantic analyzer that maps every AST identifier node to its resolved
binding (kind, declared type, owner module).  The self-host linter has no such
table.  All 5 semantic-facts rules are blocked on building and plumbing this
mapping from the analyzer into the linter visitors.

| Rule | Needs from sema_facts |
|------|----------------------|
| `redundant-cast` | Expression type vs target cast type |
| `redundant-type-annotation` | Declared type annotation vs inferred type |
| `prefer-own-ptr` | Whether a variable has `own[T]` or `ptr[T]` type |
| `reserved-primitive-name` | Whether a local or param name shadows a primitive type name |
| `borrow-and-mutate` | Whether an expression yields `ref[T]` while a `T` is also borrowed |

### 2.5 Tooling

| Gap | Est. effort | Notes |
|-----|-------------|-------|
| `--select` / `--ignore` | Small | CLI parsing + filter check per warning |
| `--fix` | Medium | Per-rule auto-fix logic |
| `.mt-lint.yml` config | Medium | TOML parsing + rule configuration |
| Wire lint into `check` (`lint_tier: :full`) | Small | Call `lint_source` from `check_program` |

### 2.6 Out-of-scope subsystems (separate projects)

| Gap | Effort | Notes |
|-----|--------|-------|
| `--locked` / `--frozen` + package-graph resolution | Large | `PackageGraph`, `PackageManifest`, dependency solver — `deps` subsystem |
| Build cache | Large | Hash-keyed caching of compiled C + binaries |
| `--bundle` / `--archive` | Medium | `assets.mtpack`, tar.gz — packaging subsystem |
| Wasm compilation (emcc) + preview server | Large | Emscripten linker flags, HTML shell — toolchain subsystem |
| `--jobs` parallel test execution | Medium | `fork`-based orchestration |
| `--sanitize` | Medium | `-fsanitize=address` + skip ulimit cap |
| Self-hosted test-runner build | Large | Build runners via `argv[0]` instead of `bin/mtc` |
| `run-module`, `new`, `debug`, `deps`, `toolchain`, `bindgen`, `cache`, `docs`, `snapshot`, `completions` | Varies | Non-core-compiler CLI commands |
