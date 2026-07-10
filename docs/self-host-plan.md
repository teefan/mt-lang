# Self-Host Plan: Path to 100% Ruby Parity

Status: **Self-compile fixpoint REACHED; general-program parity IN PROGRESS.**
Baseline emits C without crashes (3,800+ lines); 271 C compilation errors remain (down from 288).

Last updated: 2026-07-10 (sessions: Phases C2, E rendering, F serial async, G crashes→baseline emit-c, systematic fixes)

---

## 1. Current state

### 1.1 What works (verified)

- **Self-compile fixpoint.** stage-1 (Ruby-built self-host) → stage-2 (self-built) →
  stage-3 (stage-2-built) all emit **byte-identical C** (~53,226 lines, 0 diffs) for the
  self-host source (re-verified 2026-07-09 after Phase H naming fixes).
- **All 172 self-host in-language tests pass** (0 failures).
- **`examples/language_baseline.mt`** survives the full self-host pipeline (lex→parse→check→
  lower→emit-c) without crashes, producing **3,800+ lines of C**.
- Phases A/B/C1/D: `atomic[T]`, `emit`, `dyn[I]`, break/continue in match-in-loop — DONE.
- **Events (Phase C2)** — DONE: per-event typed subscribe/emit wrapper functions with
  `Option[mt_subscription]` return; guard patterns work; struct-field access avoids padding.
- **Parallel for ptr-to-array rendering (Phase E)** — DONE: `c_declaration` renders
  `ptr[array[T,N]]` as `T (*name)[N]`.
- **Serial async (Phase F)** — PARTIAL (foundation DONE):
  - Analyzer: `Task[T]` return type wrapping, Task field/method registration
  - Lowering: return value wrapped in Task struct, `await` extracts `.value`, Task
    constructor calls lowered to aggregate literals
  - C backend: `typedef struct { T value; bool ready; } mt_task_T;` emission
  - Chained async programs compile and run correctly
  - Remaining: full CPS lowering (frame/resume/waiter), `std.async` runtime integration
- **Type alias emission** — DONE: `type X = proc() -> T` now emits C `typedef`; 471
  typedefs in baseline; ordered before struct definitions.
- **Generic fn type substitution** — DONE: `substitute_type_params` handles `ty_function`,
  fixing `T (*run_work)(void)` in struct fields.
- **Vector/matrix builtins** — DONE: `vec2`..`quat` struct typedefs emitted unconditionally;
  `is_primitive_name` updated to include them; vector math type inference in
  `infer_binary` + `promoted_binary_operand_type`.
- **Zero-init for struct types** — DONE: `render_zero_initializer` returns `{0}` for
  vec/mat/quat types (not plain `0`).
- **Array/tuple literal positional rendering** — DONE: aggregate initializers with `_0`,
  `_1` field names render as positional `{val, val, ...}`.

### 1.2 What does NOT work yet (the parity gap)

| Feature | Self-host symptom | Status |
|---------|-------------------|--------|
| ~~`atomic[T]`~~ | — | DONE (Phase A) |
| ~~`emit`~~ | — | DONE (Phase B) |
| ~~`dyn[I]`~~ | — | DONE (Phase C1) |
| ~~`events`~~ | — | DONE (Phase C2) |
| ~~`break/continue` in match-in-loop~~ | — | DONE behavioral (Phase D) |
| ~~`ptr[array[T,N]]` rendering~~ | — | DONE (Phase E rendering) |
| `parallel for` captures | capture infra needs re-application | DEFERRED (Phase E captures) |
| `async` / `Task[T]` | serial approximation works; full CPS + runtime integration needed | PARTIAL (Phase F) |
| `examples/language_baseline.mt` | emits C without crashes; 271 C compilation errors remain | IN PROGRESS (Phase G) |
| Phase H polish | Option naming, format helpers, fixpoint | NOT STARTED |

### 1.3 Remaining C compilation errors (271, down from 288)

| Category | Count | Root Cause |
|----------|-------|------------|
| fn→proc coercion in struct fields | 9 | `fn` fields wrapped in proc env structs |
| Mask bare type names | 6 | Module qualification for local enums/flags |
| Void variable declarations | 5 | Cascading from type resolution failures |
| str→int type mismatch | 5 | Match expression common type wrong |
| start/end member access | 8 | Nested struct `Rectangle.Edge` not resolved |
| Option naming | 4 | Option_int vs std_option_Option_int (Phase H) |
| Unary minus on vec | 4 | Needs vec negation lowering |
| T in interface/dyn | 4 | Generic interface method params |
| Other cascading | ~226 | From above root causes |

---

## 2. Architecture reference

Pipeline (self-host mirrors Ruby stage-for-stage):

```
source → lexer → token stream → parser → AST → semantic analyzer → module loader → Program
                                                                                     ↓
                                                                     Lowering (lowering/lowering.mt)
                                                                                     ↓
                                                                     IR::Program (ir.mt)
                                                                                     ↓
                                                                     CBackend (c_backend/c_backend.mt)
                                                                                     ↓
                                                                     C source → cc → binary
```

Self-host source layout (`projects/mtc/src`, ≈30k LOC):

| Stage | Path | LOC |
|-------|------|-----|
| Lexer | `src/mtc/lexer/` | ~1,590 |
| Parser + AST | `src/mtc/parser/*.mt` | ~4,860 |
| Pretty printers | `src/mtc/pretty_printer/*.mt` | ~2,190 |
| Semantic analyzer | `src/mtc/semantic/analyzer.mt` | ~4,080 |
| Type system | `src/mtc/semantic/types.mt` | ~710 |
| Loader | `src/mtc/loader/` | ~730 |
| IR | `src/mtc/ir.mt` | ~230 |
| Lowering | `src/mtc/lowering/lowering.mt` | ~9,480 |
| C Backend | `src/mtc/c_backend/c_backend.mt` | ~3,880 |
| Build driver | `src/mtc/build.mt` | ~160 |
| C naming (shared) | `src/mtc/c_naming.mt` | ~137 |

### 2.1 Key seams (reuse, don't re-derive)

- **Monomorphization**: method calls route through `try_generic_method_call` →
  `lower_monomorphized_method`.
- **Naming**: `naming.type_c_key(ty)` is the single source of truth.
- **Member typing** order: span `.data`/`.len` → `concrete_field_type` →
  `arm_payload_field_type` → `imported_field_type` → analyzer `expr_type`.
- **Match**: `lower_match` prefers `ir_expr_type(lower_expr(scrutinee))`.
- **Prelude variants**: globally named — never module-prefix them.
- **Cross-module call resolution**: variant-arm ctor → `imported_foreign_call` →
  `imported_extern_call` → `try_inferred_generic_call` → plain qualified call.
- **`defer`**: per-block `DeferGroup` stack; flushed reverse-order.
- **`inside_async`**: tracked in `LowerCtx`; return values wrapped in `make_task_literal`;
  `await` unwrapped via `unwrap_task_value`.
- **Event helpers**: per-event typed IR functions built in `build_event_subscribe_fn` /
  `build_event_emit_fn`; added to `pending_event_functions`.
- **Type aliases**: `type_alias_types` in `Analysis` → `ir.TypeAlias` → C `typedef`.
- **Vector math**: `is_vec_math_name` in both analyzer and lowering;
  `render_zero_initializer` handles vec/mat/quat.
- **Task types**: `make_task_type` / `make_task_literal` / `unwrap_task_value` in lowering;
  `emit_task_structs` in C backend.

## 3. The plan to 100% parity

### Phase A — `atomic[T]` — **DONE**
### Phase B — `emit` — **DONE**
### Phase C1 — `dyn[I]` — **DONE**
### Phase C2 — `events` — **DONE**
### Phase D — break/continue in match-in-loop — **DONE** (behavioral)
### Phase E — parallel for captures — **PARTIAL** (rendering DONE; captures DEFERRED)
### Phase F — async / Task[T] — **PARTIAL** (serial foundation DONE; full CPS needed)
### Phase G — baseline parity gate — **IN PROGRESS** (emit-c works; 271 C errors remain)
### Phase H — final polish — **NOT STARTED**

### Recommended next actions
1. **Continue Phase G**: Fix remaining C compilation errors to get baseline compiling and
   running. Prioritize: Option naming (Phase H), Mask bare names, str type mismatch,
   start/end member access.
2. **Phase F completion**: Full CPS lowering for async (frame/resume/waiter/cancel),
   `std.async` runtime integration.
3. **Phase E captures**: Re-apply capture infra (collector, struct, init, unmarshal).
4. **Phase H**: Option naming fixpoint, format helpers, string-literal-index stabilization.

---

## 4. Differential harness

```sh
# Build stage-1 (Ruby-built self-host).
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-noguard

# Per-feature differential.
diff <(bin/mtc              emit-c FEATURE.mt) \
     <(tmp/mtc-noguard      emit-c FEATURE.mt --root .)

# Baseline emit-c test.
tmp/mtc-noguard emit-c examples/language_baseline.mt --root examples --root . > tmp/baseline.c
cc -std=c11 -D_GNU_SOURCE -I std/c tmp/baseline.c -o tmp/baseline -luv -lpthread -lm

# Self-compile fixpoint check.
tmp/mtc-noguard emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root . > tmp/self.c
cc -std=c11 -D_GNU_SOURCE -I std/c tmp/self.c -o tmp/mtc-stage2 -luv -lpthread -lm
diff <(tmp/mtc-noguard emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root .) \
     <(tmp/mtc-stage2  emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root .)

# Run in-language tests.
bin/mtc test projects/mtc
```

---

## 5. Cross-cutting principles

- **IR is the frozen seam.** Backend reads only `IR`; Lowering reads only `Analysis`.
- **Byte-identical C is the correctness oracle.**
- **Follow Ruby's algorithmic structure.**
- **Fail loud on substrate gaps** (no silent wrong C).
- **Small anchored edits** near function boundaries; rebuild immediately.
- **Sandbox every built binary** (`timeout` + `ulimit -v`).

---

## 6. Resume context (2026-07-10 sessions)

### Committed in previous session (2026-07-09)
- Phase A: `atomic[T]` (`4de40f43`)
- Phase B: `emit` (`72f91f78`)
- Phase C1: `dyn[I]` (`d3a46fd8`)
- Phase D: break/continue in match-in-loop (`8b5f346a`)
- Phase E: parallel for for-loop wrapper (`560209b4`)
- Phase H: preamble parity, naming fixes, prelude variant prefix (`3ec4b921`, `6307aad2`, `362094ff`)

### Uncommitted changes (2026-07-10 sessions, working tree dirty)

**Files modified:**
- `projects/mtc/src/mtc/lowering/lowering.mt` — ~650 lines added
- `projects/mtc/src/mtc/c_backend/c_backend.mt` — ~120 lines added
- `projects/mtc/src/mtc/semantic/analyzer.mt` — ~70 lines added
- `projects/mtc/src/mtc/ir.mt` — 2 fields + 1 struct added

**Phases completed:**
- **Phase C2 (events)**: Per-event wrappers, `Option[mt_subscription]` return, guard support
- **Phase E (rendering)**: `c_declaration` ptr-to-array fix, operator precedence fix
- **Phase F (serial async)**: Task wrapping, return/await, Task struct, Task constructor, builtins
- **Phase G (baseline survive)**: 20+ crash fixes, baseline emits C without crashes

**Systematic fixes:**
- Type alias emission (typedefs for proc/fn types)
- Generic function type substitution in struct fields
- Vector/matrix/quaternion builtin type definitions
- Vector math type inference (analyzer + lowering)
- Zero-init for struct types (vec/mat/quat)
- Positional array/tuple literal rendering
- `is_primitive_name` extended with vec/mat/quat/ivec names

**Key added functions in lowering.mt:**
- `make_task_type` / `make_task_literal` / `unwrap_task_value`
- `lower_task_constructor` / `lower_multi_for`
- `is_vec_math_name` / `primitive_type_name` / `is_void_type_lowered`

**Key added functions in c_backend.mt:**
- `emit_task_structs` / `emit_task_struct_type` / `task_type_element`
- `emit_type_aliases` / `emit_builtin_type_defs` / `collect_builtin_types`
- `is_vec_math_name` / `is_void_type`

**Key changes in analyzer.mt:**
- `build_fn_sig` with `is_async` param + `make_task_type`
- `register_task_methods` (take_result/release/set_waiter/cancel/ready)
- Task field handling in `check_member`
- `infer_binary` with vector math support

**Current state (before commit):**
- All 172 self-host tests pass (0 failures)
- Baseline emits 3,804 lines of C without crashes
- 271 C compilation errors remain (down from 288)
- Build: `bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-noguard`

### Build/test commands (from project root)
```sh
# Build stage-1 self-host (from Ruby)
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-noguard

# Run in-language tests
bin/mtc test projects/mtc

# Per-feature differential
diff <(bin/mtc emit-c FEATURE.mt) <(tmp/mtc-noguard emit-c FEATURE.mt --root .)

# Baseline emit-c + compile check
tmp/mtc-noguard emit-c examples/language_baseline.mt --root examples --root . > tmp/baseline.c
cc -std=c11 -D_GNU_SOURCE -I std/c tmp/baseline.c -o /dev/null -luv -lpthread -lm 2>&1 | grep "error:" | wc -l

# Self-compile fixpoint check
tmp/mtc-noguard emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root . > tmp/self.c
cc -std=c11 -D_GNU_SOURCE -I std/c tmp/self.c -o tmp/mtc-stage2 -luv -lpthread -lm
diff <(tmp/mtc-noguard emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root .) \
     <(tmp/mtc-stage2  emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root .)
```
