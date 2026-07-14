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

**Semantic-facts rules** (`redundant-cast`, `redundant-type-annotation`, `prefer-own-ptr`, `reserved-primitive-name`):
- These require `@sema_facts` (binding resolution from semantic analysis). The self-host does not yet have semantic-facts integration for lint.

**CFG/flow rules** (`constant-condition`, `redundant-null-check`,
`loop-single-iteration`, `dead-assignment`, `unreachable-code`, `missing-return`): need full control-flow graph + constant propagation. The self-host already has `ControlFlow::Builder` infrastructure for the parts needed here.

**AST pattern rules** (`prefer-inline-if`, `prefer-conditional-expression`, `prefer-or-pattern`, `prefer-let-else`, `prefer-var-else`, `prefer-try`, `prefer-is-variant`, `prefer-struct-with`):
- AST-only or small flow analysis; can be added to the existing visitor without scope tracking.

**Ownership rules** (`owning-release-leak`, `owning-release-double`, `borrow-and-mutate`): require sema facts for ownership tracking.

**Token-based rules** (`line-too-long`): needs `Formatter` wrap-detection +
UTF-8 character (not byte) length to match Ruby's message text.

**Tooling**: `--select` / `--ignore` / `--fix`, `.mt-lint.yml` config, wiring
lint into `check` (`lint_tier: :full`).

---

## 2. Remaining work

### 2.1 Remaining lint rules (~23 rules)

**AST pattern rules** (`prefer-inline-if`, `prefer-conditional-expression`,
`prefer-or-pattern`, `prefer-let-else`, `prefer-var-else`, `prefer-try`,
`prefer-is-variant`, `prefer-struct-with`): AST-only or small flow analysis.
Can be added to the existing `visit_stmt` / `visit_expr` without scope
tracking or sema facts.

**Semantic-facts rules** (`redundant-cast`, `redundant-type-annotation`,
`prefer-own-ptr`, `reserved-primitive-name`): require `@sema_facts` (binding
resolution from semantic analysis). Not yet available in self-host lint.

**CFG/flow rules** (`constant-condition`, `redundant-null-check`,
`loop-single-iteration`, `dead-assignment`, `unreachable-code`,
`missing-return`): need control-flow graph. The self-host already has
`ControlFlow::Builder` in `mtc.semantic.control_flow.builder`.

**Ownership rules** (`owning-release-leak`, `owning-release-double`,
`borrow-and-mutate`): require sema facts and release-tracking pass.

**Token-based** (`line-too-long`): standalone; needs UTF-8 char width and
formatter integration.

**Tooling**: `--select` / `--ignore` / `--fix`, `.mt-lint.yml` config.

### 2.2 Out-of-scope subsystems (separate projects)

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
