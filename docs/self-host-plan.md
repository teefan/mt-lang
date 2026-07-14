# Self-Host Plan

Status: **SELF-HOSTING FIXED POINT ACHIEVED.** Stage2 == stage3 byte-identical.
391/391 self-tests pass. **13/13 examples build** with the self-hosted compiler.
**12/13 run identically to Ruby** (`async_stress_test` crashes under both — a
pre-existing libuv runtime bug in the stdlib, not a self-host issue).

The 4 core compiler commands (check/build/run/test) are now at feature parity
with the Ruby CLI for the self-host scope: platform-variant resolution, run
exit-code forwarding, build --clean, and the full test surface (--timeout/--mem
sandboxing, -n filter, --format tap|junit, compile-fail fixtures, and
@[expect_fatal] death tests).

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
| **FULL**  | lex, parse, lower, emit-c, format, help, version, check, build, run, test |
| **NOT IMPL** | run-module, new, lint, debug, deps, toolchain, bindgen, cache, docs, snapshot, completions |

The 4 core compiler commands are feature-complete for the self-host scope. The
remaining gaps (build cache, --bundle/--archive, wasm/emcc, package-graph
dependency resolution, lint) belong to separate subsystems (deps solver,
toolchain, lint) that are intentionally out of scope for compiler self-host
parity.

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

**CLI core-command parity (this session):**

13. **run exit-code forwarding** — `mtc run` returns the child's `normalized_code()` (128+signal for signals) instead of always 0, and routes captured stderr to stderr.

14. **build --clean** — removes the resolved output artifact (honoring `-o` and package `build.entry`) without compiling; idempotent.

15. **test sandboxing + failure detection** — each runner binary runs under `timeout <sec> bash -c 'ulimit -v <kb>'` (exit 124 = timeout); build failures and non-zero runner exits are now detected so failing files are counted and `mtc test` exits 1. Adds `--timeout` (default 30s) and `--mem` (default 1024MB).

16. **test -n/--name filter** — run only @[test] functions whose name contains the substring.

17. **test --format tap|junit** — parse runner `ok/skip/FAIL` lines and re-emit as TAP 13 or JUnit XML (TAP verified byte-identical to Ruby).

18. **test # expect-error: compile-fail fixtures** — type-check the fixture and verify each expected substring appears in an error diagnostic.

19. **test @[expect_fatal] death tests** — run in an isolated binary; pass iff the process aborts rather than returns/times out. Normal runner extracted to `run_normal_test_runner`; sandbox shared via `run_sandboxed`.

20. **platform-variant entry resolution** — confirmed already handled inside `check_program` (`resolve_source_path`), so check/build/run honor `name.<platform>.mt` for entry files and imports.

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

## 1. Remaining work

The 4 core compiler commands are at feature parity for the self-host scope.
The gaps that remain all belong to **separate subsystems** that are out of
scope for compiler self-host parity (they are large standalone projects, not
core-compiler behavior):

### 1.1 Out-of-scope subsystems (not core-compiler)

| Gap | Command(s) | Effort | Notes |
|-----|-----------|--------|-------|
| `--locked` / `--frozen` + package-graph resolution | check, build, run | Large | Requires `PackageGraph`, `PackageManifest`, dependency solver — part of the `deps` subsystem |
| Lint integration | check, lint | Large | 63 lint rules require semantic-analysis facts — separate `lint` project |
| Build cache | build, run | Large | Hash-keyed caching of compiled C + binaries |
| `--bundle` / `--archive` | build, run | Medium | `assets.mtpack`, tar.gz output — packaging subsystem |
| Wasm compilation (emcc) + preview server | build, run | Large | Emscripten linker flags, HTML shell, preload files — toolchain subsystem |
| `--jobs` parallel test execution | test | Medium | Needs `fork`-based orchestration |
| `--sanitize` | test | Medium | Pass `-fsanitize=address` and skip the `ulimit -v` cap |
| Self-hosted test-runner build | test | Large | Currently builds runners via `bin/mtc`; use the self-built `mtc` (needs argv[0]/toolchain path resolution) |

### 1.2 Completed this session

- `run` exit-code forwarding (+ stderr routing)
- `build --clean`
- `test` sandboxing (`--timeout` / `--mem`) + failure detection via exit code
- `test -n/--name` filter
- `test --format tap|junit`
- `test # expect-error:` compile-fail fixtures
- `test @[expect_fatal]` death tests
- Confirmed platform-variant entry resolution (already handled in `check_program`)
