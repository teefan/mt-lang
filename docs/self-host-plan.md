# Self-Host Plan

Status: **SELF-HOSTING FIXED POINT ACHIEVED.** Stage2 == stage3 byte-identical.
443/443 self-tests pass across 9 test files. **`mtc lint` has 12 rules
byte-identical to Ruby** across the entire codebase.

Last updated: 2026-07-14

---

## 0. Current State

### 0.1 Bootstrap

```sh
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-current
tmp/mtc-current build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-stage2 --keep-c tmp/stage2.c
tmp/mtc-stage2 build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-stage3 --keep-c tmp/stage3.c
diff tmp/stage2.c tmp/stage3.c        # identical
tmp/mtc-stage2 test projects/mtc -I .  # 443/443
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

**`mtc lint`** — 12 AST-only rules implemented, output byte-identical to Ruby
across the entire codebase (see §1.1).

**`mtc check`** — diagnostic format matches Ruby byte-for-byte (`error[sema/error]:`,
rjust-5 gutter, 6-space caret line, summary). Analyzer now reports unknown type
annotations and undefined names (the two former `check`-silence bugs).

### 0.4 Landed fixes (all sessions)

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

## 1. Linter (12 / ~40 rules)

### 1.1 Implemented rules (all byte-identical to Ruby)

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

### 1.2 Remaining lint rules (deferred)

**Semantic-facts rules** (`unused-local`, `unused-param`, `shadow`, `prefer-let`,
`dead-assignment`, `redundant-cast`, `reserved-primitive-name`,
`prefer-is-variant`, ownership rules, etc.):
- These require **scope tracking interleaved into the main AST visitor**
  (`declare_local` / `mark_used` / `mark_mutated` / `with_scope`). This is a
  30+-function mechanical refactor that threads mutable scope state through
  every visit function, with tight byte-parity constraints (scope warnings must
  emit at the exact same interleaved points as Ruby's visitor). The refactor
  itself is well-defined but is a dedicated effort — see §2.1.

**CFG/flow rules** (`constant-condition`, `redundant-null-check`,
`loop-single-iteration`): need full control-flow graph + constant propagation.

**Token-based rules** (`line-too-long`): needs `Formatter` wrap-detection +
UTF-8 character (not byte) length to match Ruby's message text.

**Tooling**: `--select` / `--ignore` / `--fix`, `.mt-lint.yml` config, wiring
lint into `check` (`lint_tier: :full`).

---

## 2. Remaining work

### 2.1 Semantic-facts rules (next major milestone)

The visitor refactor to thread scope tracking is the single remaining piece of
the lint system. Once in place, all scope-based rules (`unused-local`,
`unused-param`, `shadow`, `prefer-let`) fall out from `emit_scope_warnings` on
scope-pop. Flow analysis rules (`dead-assignment`) are a further step.

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
