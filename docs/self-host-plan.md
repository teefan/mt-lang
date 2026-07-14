# Self-Host Plan

Status: **SELF-HOSTING FIXED POINT ACHIEVED.** Stage2 == stage3 byte-identical.
391/391 self-tests pass. **13/13 examples build** with the self-hosted compiler.
**12/13 run identically to Ruby** (`async_stress_test` crashes under both — a
pre-existing libuv runtime bug in the stdlib, not a self-host issue).

Last updated: 2026-07-14

---

## 0. Current State

### 0.1 Bootstrap

```sh
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-current
tmp/mtc-current build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-stage2 --keep-c tmp/stage2.c
tmp/mtc-stage2 build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-stage3 --keep-c tmp/stage3.c
diff tmp/stage2.c tmp/stage3.c        # identical
tmp/mtc-stage2 test projects/mtc -I .  # 391/391
```

### 0.2 Example parity

| Example | Build (Ruby) | Build (SH) | Run (Ruby) | Run (SH) |
|---------|-------------|-----------|-----------|---------|
| `data_structures` | OK | OK | 134 | 134 MATCH |
| `event_stress_test` | OK | OK | 4 | 4 MATCH |
| `memory_stress_test` | OK | OK | 0 | 0 MATCH |
| `multithreading_test` | OK | OK | 0 | 0 MATCH |
| `nested_struct_stress_test` | OK | OK | 0 | 0 MATCH |
| `nullable_and_variant_test` | OK | OK | 0 | 0 MATCH |
| `option_and_result_surface` | OK | OK | 0 | 0 MATCH |
| `reflection_advanced` | OK | OK | 0 | 0 MATCH |
| `integration_test` | FAIL (dyn vtable C-ABI bug) | OK | — | 0 |
| `language_baseline` | OK | OK | 0 | 0 MATCH |
| `string_test` | OK | OK | 0 | 0 MATCH |
| `async_stress_test` | OK | OK | 134 (UAF) | 134 (UAF) |
| `async_network_lobby` | OK | OK | 0 | 0 MATCH |

### 0.3 CLI parity

11 of 22 Ruby CLI commands implemented (50% overall, 100% core compiler):

| Status | Commands |
|--------|----------|
| **FULL**  | lex, parse, lower, emit-c, format, help, version |
| **PARTIAL** | check, build, run, test |
| **NOT IMPL** | run-module, new, lint, debug, deps, toolchain, bindgen, cache, docs, snapshot, completions |

### 0.4 Landed fixes (all sessions)

**Language lowering:**

1. **Loop break/continue with goto labels** — prevents C `break` inside `match`→`switch` from only exiting the innermost switch.

2. **Async frame release ready-check** — vtable `release` checks `!__mt_frame->ready` before freeing; only releases pending `await_N` sub-tasks when still pending.

3. **Ready-flag ordering** — `ready = true` set BEFORE `async_waiter_wake`, matching Ruby compiler.

4. **Async frame set_waiter ready-check** — calls waiter immediately on already-complete tasks (synchronous completion path).

5. **CPS return defer ordering** — `flush_all_defers` runs AFTER evaluating the return expression in CPS mode. Fixed `async_network_lobby` "heap.must_alloc out of memory" crash.

6. **Match equality/guard patterns** — equality patterns (`field = expr`) and guard patterns (`field > expr`) now emit conditional `goto next_arm` checks.

7. **CPS for-loop induction-var spilling** — `lower_for_range` and `lower_collection_for` register induction/stop/index/items variables as frame fields when `async_cps_active`.

8. **Async `main` entrypoint** — synthesizes C `main()`, wraps CPS-lowered constructor in root proc, drives via `std.async.wait[int]`/`run`.

9. **Array-by-value C ABI** — `array[T,N]`-returning functions lower to `void f(T (*__mt_out)[N], ...)`.

**CLI / Architecture:**

10. **check parity** — directory targets (recursive `*.mt` discovery), source-context error formatting with `^^^`, `-Werror`, per-severity summary counts.

11. **Cached common types** — `bool_ty`, `void_ty`, `ptr_void_ty` in `LowerCtx`, replacing 154 repeated `types.primitive()`/`ptr_void_type()` calls.

12. **Naming consistency** — `gsi_*` → `generic_instance_*` in lowering, `GVArmInfo`/`GVInfo`/`OptStructEntry` → `GenericVariantArmInfo`/`GenericVariantInfo`/`OptionStructEntry` in c_backend.

**Earlier fixes (cross-module, generics, async CPS core):**

- Cross-module same-name type collision (`GenericReceiver.owner_module`)
- Nullable fn-pointer locals, global variable initializers
- `str_buffer[N]` capacity, const comparison `cv_bool`
- Compile-time reflection / type dispatch (`reflection_advanced` end-to-end)
- Format strings (`f"..."` — `mt_format_*` runtime)
- Async CPS core (state machine, direct awaits, methods, hoisting)
- Match-binding CPS spilling, arm-payload field types
- Specialization label isolation, `ptr_of` referent-type recovery
- Arm-name-disambiguated CPS match fields

---

## 1. Remaining work: check, build, run, test full parity

The 4 core commands are implemented but have gaps blocking full feature
parity with the Ruby compiler.

### 1.1 `check` — pending gaps

| Gap | Effort | Notes |
|-----|--------|-------|
| `--locked` / `--frozen` wiring | Medium | Parse and use `package.lock` for dependency graph resolution |
| Package-graph resolution | Large | Requires `PackageGraph`, `PackageManifest`, dependency solver |
| Platform-specific file variant resolution | Medium | Prefer `name.linux.mt` → `name.mt` fallback per active platform |
| Lint integration | Large | 63 lint rules require semantic analysis facts; separate project |

### 1.2 `build` — pending gaps

| Gap | Effort | Notes |
|-----|--------|-------|
| `--bundle` / `--archive` | Medium | Package artifact bundling, `assets.mtpack`, tar.gz output |
| `--clean` | Small | Remove generated output artifacts |
| Build cache | Large | Caching compiled C + binaries with hash keys |
| Package-graph resolution | Large | Same as check §1.1 |
| Platform-specific file variant resolution | Medium | Same as check §1.1 |
| Wasm compilation (emcc) | Large | Emscripten linker flags, HTML shell, preload files |

### 1.3 `run` — pending gaps

| Gap | Effort | Notes |
|-----|--------|-------|
| `--bundle` / `--archive` | Medium | Same as build §1.2 |
| Wasm preview server | Small | Local HTTP server with COOP/COEP headers for Emscripten |
| Platform-specific file variants | Medium | Same as check §1.1 |
| Proper exit code forwarding | Small | Currently captures stdout/stderr but may not forward exit code |

### 1.4 `test` — pending gaps

| Gap | Effort | Notes |
|-----|--------|-------|
| `--timeout` / `--mem` | Small | Per-test timeout and virtual memory limits |
| `--jobs` | Medium | Parallel test execution via fork |
| `--format tap\|junit` | Small | Machine-readable test output |
| `--name` / `-n` filter | Small | Substring match on test function names |
| `--sanitize` | Medium | Pass `-fsanitize=address` to C compiler |
| Death tests (`@[expect_fatal]`) | Medium | Run test in subprocess, expect SIGABRT |
| Self-hosted test runner | Large | Use self-built `mtc` instead of `bin/mtc` for building test runners |
| Compile-fail fixtures (`# expect-error:`) | Medium | Check that expected compile errors match actual diagnostics |

### 1.5 Priority ordering

```
1. test --timeout         (1-line addition, safety-critical)
2. test --name filter     (simple substring match, quality-of-life)
3. build --clean          (removes output artifacts)
4. check platform variants (name.linux.mt → name.mt fallback)
5. build platform variants
6. test --format tap/junit
7. test compile-fail fixtures
8. run exit code forwarding
9. test death tests
10. build --bundle / --archive
```
