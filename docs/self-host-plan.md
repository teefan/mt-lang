# Self-Host Plan: Path to 100% Ruby Parity

Status: **Async CPS Steps 1-6 DONE. 172 tests pass. Self-compile verified.**
Last updated: 2026-07-11 (session: CPS Steps 1-6 + package build + parity fixes)

---

## 1. Current state

### 1.1 What works (verified)

- **Self-compile:** stage-1 (Ruby-built self-host) → stage-2 (self-built) verified.
  ```sh
  bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-final
  tmp/mtc-final build projects/mtc --root .          # stage-2 binary produced
  tmp/mtc-final check projects/mtc --root .          # output: "ok"
  ```
- **172/172 tests pass** (0 failures).
- **`examples/language_baseline.mt`**: full pipeline (lex→parse→check→lower→emit-c) without crashes.
  C compilation: 2 pre-existing POSIX errors (sockaddr, addrinfo from std/c/fs.h). All async CPS code generates compilable C.
- **Phases A-E**: DONE (atomic, emit, dyn[I], events, parallel captures).
- **Phase F**: DONE (async CPS Steps 1-6).
- **Phase G**: DONE (baseline parity gate).
- **Phase H**: DONE (package build support, dead code removal).

### 1.2 Session progress (2026-07-11)

10 commits in this session across two batches:

**Batch 1 — parity fixes (3 commits):**

| Commit | What |
|--------|------|
| `1e5b80db` | Phase H: package build support (directory targets + TOML) + dead code |
| `79d9611e` | Semantic fixes: method resolution, Option unwrapping, prelude C naming, pointer cast line numbers |
| `698a98ba` | fn→proc coercion for monomorphized method calls (fixes sort_by) |

**Batch 2 — type alias + builtin naming + stddef (1 commit):**

| Commit | What |
|--------|------|
| `ff081b5d` | Fix cross-module type alias resolution, builtin naming (mt_vec2), stddef.h inclusion |

**Batch 3 — async CPS implementation (6 commits):**

| Step | Commit | Feature |
|------|--------|---------|
| 1 | `0d4d0f67` `52002939` | Task vtable struct + frame/synthetic funcs |
| 2 | `e88eafb0` | Await detection + switch state dispatch |
| 3 | `c5261f37` | `async.mt` module + sequential await lowering |
| 4 | `0501214b` | Waiter wake + set_waiter immediate callback |
| 5 | `d1b9a747` | Lower no-await body + return-value extraction |
| 6 | `e8d950ba` | Cross-path `.value` in constructor |

### 1.3 Async CPS feature summary

| Feature | Location | Status |
|---------|----------|--------|
| Task struct (value + vtable) | `c_backend.mt` `emit_task_struct_type` | Done |
| Frame struct per async fn | `lowering.mt` `lower_async_fn` | Done |
| Resume function (no-await: body + return→frame) | `lowering.mt` | Done |
| Resume function (with-await: switch dispatch stub) | `lowering.mt` `lower_async_cps_body` | Done |
| Constructor (malloc, resume, Task aggregate) | `lowering.mt` | Done |
| Vtable: ready | `lowering.mt` | Done |
| Vtable: release (free) | `lowering.mt` | Done |
| Vtable: set_waiter (immediate-wake-if-ready) | `lowering.mt` | Done |
| Vtable: take_result | `lowering.mt` | Done |
| Vtable: cancel | `lowering.mt` | Done |
| Await detection (body/stmt/expr_has_await) | `async.mt` | Done |
| State counting (count_await_states) | `async.mt` | Done |
| Waiter wake on completion | `lowering.mt` `async_waiter_wake` | Done |
| Cross-path `.value` extraction | `lowering.mt` constructor | Done |
| Routing: no-await→CPS, with-await→normal lowering | `lowering.mt` `lower_module` | Done |
| Nested control flow CPS (if/while/for with await) | — | Deferred (handled by normal path) |

### 1.4 Baseline C compilation status

```
2 errors — both pre-existing POSIX types from std/c/fs.h:
  - unknown type name 'sockaddr'
  - unknown type name 'addrinfo'
```

All async CPS code generates compilable C. No self-inflicted errors remain.

## 2. Architecture reference

Pipeline (self-host mirrors Ruby stage-for-stage):

```
source → lexer → token stream → parser → AST → semantic analyzer → module loader → Program
                                                                                     ↓
                                                                     Lowering (lowering/lowering.mt)
                                                                     async.mt (await detection + analysis)
                                                                                     ↓
                                                                     IR::Program (ir.mt)
                                                                                     ↓
                                                                     CBackend (c_backend/c_backend.mt)
                                                                                     ↓
                                                                     C source → cc → binary
```

Self-host source layout (`projects/mtc/src`, 33,262 LOC):

| Stage | Path | LOC |
|-------|------|-----|
| Lexer | `src/mtc/lexer/` | ~1,590 |
| Parser + AST | `src/mtc/parser/*.mt` | ~4,860 |
| Pretty printers | `src/mtc/pretty_printer/*.mt` | ~2,190 |
| Semantic analyzer | `src/mtc/semantic/analyzer.mt` | ~4,150 |
| Type system | `src/mtc/semantic/types.mt` | ~710 |
| Loader | `src/mtc/loader/` | ~730 |
| IR | `src/mtc/ir.mt` | ~230 |
| Lowering | `src/mtc/lowering/lowering.mt` | ~12,517 |
| Lowering (async) | `src/mtc/lowering/async.mt` | ~303 |
| C Backend | `src/mtc/c_backend/c_backend.mt` | ~4,384 |
| Build driver | `src/mtc/build.mt` | ~160 |
| CLI | `src/mtc/main.mt` | ~599 |
| C naming | `src/mtc/c_naming.mt` | ~137 |

## 3. Phase completion

| Phase | Status |
|-------|--------|
| A — atomic[T] | Done |
| B — emit | Done |
| C1 — dyn[I] | Done |
| C2 — events | Done |
| D — break/continue in match-in-loop | Done |
| E — parallel for captures | Done |
| F — async / Task[T] | Done (Steps 1-6) |
| G — baseline parity gate | Done |
| H — final polish | Done |

## 4. Verification commands

```sh
# Build self-host
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-final

# Run tests
bin/mtc test projects/mtc

# Generate baseline C
tmp/mtc-final emit-c examples/language_baseline.mt --root examples --root . > tmp/baseline.c

# Compile baseline C (expect 2 POSIX errors)
cc -std=c11 -D_GNU_SOURCE -I std/c -c tmp/baseline.c -o /dev/null 2>&1 | grep "error:" | wc -l
# Expected: 2 (sockaddr, addrinfo)

# Self-compile check
tmp/mtc-final check projects/mtc --root .

# Self-build (stage-2)
tmp/mtc-final build projects/mtc --root .
```

## 5. Resume context (2026-07-11)

### Committed this session (10 commits, ff081b5d..e8d950ba)

| Hash | Description |
|------|-------------|
| `ff081b5d` | Fix type alias resolution, builtin naming (mt_vec2), stddef.h |
| `79d9611e` | Semantic fixes: method resolution, Option unwrapping, prelude C naming |
| `698a98ba` | fn→proc coercion for monomorphized methods |
| `1e5b80db` | Phase H: package build + dead code removal |
| `0d4d0f67` | CPS Step 1: Task vtable + frame/synthetic funcs |
| `52002939` | CPS Step 1b: fix constructor frame type |
| `e88eafb0` | CPS Step 2: await detection + switch dispatch |
| `c5261f37` | CPS Step 3: async.mt module + await lowering |
| `0501214b` | CPS Step 4: waiter wake + set_waiter callback |
| `d1b9a747` | CPS Step 5: lower no-await body + return-value extraction |
| `e8d950ba` | CPS Step 6: cross-path .value extraction |

### Key files modified

| File | Changes |
|------|---------|
| `lowering/lowering.mt` | CPS integration (lower_async_fn, lower_async_cps_body, async_waiter_wake, make_task_literal update), await detection, state counting, frame struct, synthetic funcs, return-value replacement |
| `lowering/async.mt` | NEW — 303 lines: await detection, state counting, type helpers |
| `c_backend/c_backend.mt` | Task struct vtable + value field |
| `main.mt` | Package build support (TOML reader, directory targets) |
| `semantic/analyzer.mt` | Type alias export, resolve_method_sig fix, check_local fix |
| `semantic/types.mt` | is_raw_pointer nullable handling |
| `loader/binder.mt` | type_alias_types in ModuleBinding |

### Next session prompts

- **Nested control flow CPS**: Deferred — if/while/for/match with awaits currently use normal lowering path (inside_async). Full CPS transform for these would enable true async suspend/resume.
- **Defer cleanup across suspend**: Defer blocks in async functions with awaits should run on both normal completion and suspension.
- **Byte-identical C baseline**: 4678 lines differ from Ruby output (ordering + format helpers). 2 pre-existing POSIX errors remain.
- **CLI tooling**: `run`, `test`, `new`, `format`, `lint`, `deps`, `debug` commands not yet implemented in self-host.
- **Build options**: `-o`, `--cc`, `--profile`, `--platform`, `--bundle` etc. not yet supported.

### Service endpoints

Remote caching is available via the `serve` action — see `docs/build-guide.md` § 2.4 for details on the per-project package source cache.
