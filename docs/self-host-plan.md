# Self-Host Plan: Path to 100% Ruby Parity

Status: **Self-compile fixpoint REACHED; general-program parity ACTIVE.**
Baseline emits C without crashes (3,573 lines); 121 C compilation errors remain (down from 271).

Last updated: 2026-07-10 (sessions: Phase G systematic fixes, fn-proc, inline-for, type system, variant equality, type aliases)

---

## 1. Current state

### 1.1 What works (verified)

- **Self-compile fixpoint.** stage-1 (Ruby-built self-host) → stage-2 (self-built) →
  stage-3 (stage-2-built) all emit **byte-identical C** (~53,226 lines, 0 diffs).
- **All 172 self-host in-language tests pass** (0 failures).
- **`examples/language_baseline.mt`** survives the full self-host pipeline (lex→parse→check→
  lower→emit-c) without crashes, producing **3,573 lines of C**.
- Phases A/B/C1/D: `atomic[T]`, `emit`, `dyn[I]`, break/continue in match-in-loop — DONE.
- **Events (Phase C2)** — DONE.
- **Parallel for rendering (Phase E)** — DONE (ptr-to-array, captures deferred).
- **Serial async (Phase F)** — PARTIAL (foundation DONE; full CPS needed).
- Phase H parts: prelude variant naming, underscore normalization, pointer spacing — DONE.

### 1.2 Recent progress (session 2026-07-10)

271 → 121 errors (-55%), commits `5e4afe3e` through current:

| Commit | What | Delta |
|--------|------|-------|
| `5e4afe3e` | Nested struct types, module-qualified type names, vec unary minus, variant match path, match expr type, duplicate vec defs | 271→228 |
| `bc6fc7ac` | Inline for unrolling (fields_of, members_of, attributes_of) | 228→206 |
| `790f0816` | Inline for member access substitution (field.type, member.value) | 206→201 |
| `e168badf` | Libuv opaque `_s`→`_t` via cross-module c_name lookup | 201→155 |
| `080bf55d` | T generic param in vtable/dyn structs | 155→147 |
| `44bf8b0f` | SimpleRange custom iterator guard | 147→144 |
| `03b98aa8` | Inline for type-guard `field.type != float` | 144→140 |
| `bce4d312` | fn→proc coercion via `is_proc` on `ty_function` | 140→136 |
| `e88956df` | Refactor lowering.mt (dedup, rename, extract factory) | 136 (no change) |
| *(this session)* | Skip `std.c.*` type aliases + skip raw-module alias collection | 136→126 |
| *(this session)* | Variant equality: C-backend helper generation for `mt_variant_eq_<type>` | 126→121 |

### 1.3 Remaining C compilation errors (121, down from 271)

| Category | Count | Root Cause |
|----------|-------|------------|
| Void variables (cascading) | ~30 | From type resolution failures (get(), .with(), nested struct, proc/fn type alias) |
| Native type operators (vec/mat/quat) | ~15 | vec3+vec3, mat4*mat4, quat*quat, etc. not lowered to component ops |
| SoA index access | ~10 | `SoA[T,N]` struct index access not lowered to C field access |
| Proc/fn type alias | ~15 | `ty_function(is_proc=true)` in type alias `target_type` not converted to proc struct; fn->proc coercion; invoke/env member access |
| Option naming | 4 | Prelude variant methods use bare `Option_int` vs qualified `std_option_Option_int` |
| Subscription comparison | 3 | `mt_subscription == void*` — per-event subscribe returns Result-wrapped struct, not nullable |
| Buffer lifetime struct | 5 | `@a` lifetime struct `language_baseline_Buffer` has no C definition; `buffer_advance` not emitted |
| Compile-time reflection | 5 | `has_attribute`, `field_of`, `static_assert` not constant-folded at emit time; `type`/`ptr` type constants |
| Other cascading | ~30 | From above root causes: str_buffer len, tuple assignment, nested struct, `s` redefinitions |

### 1.4 Type system changes (this session)

- **`ty_function`** now carries `is_proc: bool` to distinguish `fn` from `proc`
- **`ty_named`** now carries `module_name: str` for module-qualified C name generation
- **`ir.TypeAlias`** now carries `backing_c_name: Option[str]` for libuv opaque type mapping
- **`LowerCtx`** new fields: `inline_for_element`, `defer_stack`
- All 12 `ty_function` constructors updated across analyzer + lowering
- **`Emitter`** new field: `variant_eq_set: Map[str, bool]` for tracking variant equality helpers
- **`c_backend.mt`**: new functions — `is_variant_equality`, `render_variant_equality`, `scan_variant_equality`, `emit_variant_equality_helpers`, `emit_variant_eq_helper`, `emit_variant_field_compare`, `variant_c_name_for_type`, `variant_equality_helper_name`
- **`lowering.mt`**: new function — `type_is_from_std_c`; type alias collection now skips raw modules and `std.c.*` target types

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
| Lowering | `src/mtc/lowering/lowering.mt` | ~10,062 |
| C Backend | `src/mtc/c_backend/c_backend.mt` | ~4,182 |
| Build driver | `src/mtc/build.mt` | ~160 |
| C naming (shared) | `src/mtc/c_naming.mt` | ~137 |

### 2.1 Key seams

- **Monomorphization**: `try_generic_method_call` → `lower_monomorphized_method`
- **Naming**: `naming.type_c_key(ty)` is the single source of truth
- **fn vs proc**: `ty_function.is_proc` distinguishes; `is_proc_type` checks it
- **Proc struct conversion**: `qualify_type` converts `ty_function(is_proc=true)` to `ty_named(mt_proc_…)`
- **Inline for**: `lower_inline_for_stmt` → `comptime_iterable_elements` → per-element unrolling
- **Cross-module opaque**: `lookup_decl_c_name_cross` follows import chain for C type mapping
- **LowerCtx factory**: `new_lowering_context(analysis, …)` single init point
- **Variant equality**: C backend `emit_variant_equality_helpers` generates `mt_variant_eq_<type>` static helpers; `scan_variant_equality` pre-scans IR for variant comparisons; `is_variant_equality` / `render_variant_equality` redirect `==`/`!=` to helpers at emission time
- **Type alias collection**: `type_is_from_std_c` skips aliases from `std.c.*` modules; `is_raw_module` skip added to type-alias loop
- **Naming conventions** (post-refactor): `nominal_type_name` (not `primitive_type_name`), `is_builtin_type_name` (not `is_primitive_name`)

---

## 3. The plan to 100% parity

### Phase A — `atomic[T]` — DONE
### Phase B — `emit` — DONE
### Phase C1 — `dyn[I]` — DONE
### Phase C2 — `events` — DONE
### Phase D — break/continue in match-in-loop — DONE
### Phase E — parallel for captures — PARTIAL (rendering DONE; captures deferred)
### Phase F — async / Task[T] — PARTIAL (serial foundation DONE; full CPS needed)
### Phase G — baseline parity gate — ACTIVE (121 errors remain, down from 271)
### Phase H — final polish — NOT STARTED

### Recommended next actions (priority order)

1. **Option naming consolidation** — Prelude variant methods use bare `Option_int` vs qualified `std_option_Option_int`. Affects 4 errors. Fix: `ty_generic` handling in `c_type` and `render_variant_initializer` should use qualified names for prelude types.
2. **Subscription comparison** — Event subscribe returns `Result[Subscription, EventError]` but lowering emits raw `mt_subscription` struct. Affects 3 errors.
3. **Buffer lifetime struct** — `language_baseline_Buffer` (lifetime-annotated struct) has no C definition emitted. Affects 5 errors.
4. **SoA index access** — `SoA[T,N]` generates struct but `particles[0]` needs C-level accessor lowering. Affects ~10 errors.
5. **Proc type alias qualification** — `ty_function(is_proc=true)` in type alias `target_type` not converted to proc struct. Affects ~15 invoke/env errors.
6. **Native type operators** — vec3+vec3, mat4*mat4, quat*quat, etc. not lowered to component operations. Affects ~15 errors.
7. **Phase H** — format helpers, string-literal-index stabilization.

---

## 4. Differential harness

```sh
# Build stage-1 (Ruby-built self-host).
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-noguard

# Baseline emit-c + compile check.
tmp/mtc-noguard emit-c examples/language_baseline.mt --root examples --root . > tmp/baseline.c
cc -std=c11 -D_GNU_SOURCE -I std/c -c tmp/baseline.c -o /dev/null 2>&1 | grep "error:" | wc -l

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

## 6. Resume context (2026-07-10)

### Committed (this session, in order)

| Hash | Description |
|------|-------------|
| `5e4afe3e` | Nested struct types, module-qualified names, vec unary minus, variant match path, match expr type, duplicate vec defs |
| `bc6fc7ac` | Inline for unrolling (fields_of, members_of, attributes_of) |
| `790f0816` | Inline for member access substitution (field.type, member.value) |
| `e168badf` | Libuv opaque `_s`→`_t` via cross-module c_name lookup |
| `080bf55d` | T generic param in vtable/dyn structs and wrappers |
| `44bf8b0f` | SimpleRange custom iterator guard (skip on non-array/span) |
| `03b98aa8` | Inline for type-guard `field.type != float` comptime evaluation |
| `bce4d312` | fn→proc coercion — `is_proc` on `ty_function`, qualify_type converts, `is_proc_type` checks |
| `e88956df` | Refactor lowering.mt: remove dead code, extract factory, rename helpers |
| *(pending)* | Skip `std.c.*` raw-module type aliases + `type_is_from_std_c` helper |
| *(pending)* | Variant equality helpers: `is_variant_equality`, `scan_variant_equality`, `emit_variant_equality_helpers`, `emit_variant_eq_helper`, `emit_variant_field_compare` |

### Key files modified (cumulative)

- `projects/mtc/src/mtc/semantic/types.mt` — `is_proc` on `ty_function`, `module_name` on `ty_named`
- `projects/mtc/src/mtc/semantic/analyzer.mt` — nested type registration, `ctx.module_name` propagation, `is_proc` setting
- `projects/mtc/src/mtc/c_naming.mt` — `type_c_key` for module-qualified `ty_named`
- `projects/mtc/src/mtc/c_backend/c_backend.mt` — `c_type` for module-qualified, `backing_c_name` in type aliases, variant equality helpers, `Emitter.variant_eq_set`
- `projects/mtc/src/mtc/ir.mt` — `backing_c_name` on `TypeAlias`
- `projects/mtc/src/mtc/lowering/lowering.mt` — all fixes above + refactor + `type_is_from_std_c` + raw-module alias skip (10,062 LOC)

### Build/test commands

```sh
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-noguard
bin/mtc test projects/mtc
tmp/mtc-noguard emit-c examples/language_baseline.mt --root examples --root . > tmp/baseline.c
cc -std=c11 -D_GNU_SOURCE -I std/c -c tmp/baseline.c -o /dev/null 2>&1 | grep "error:" | wc -l
```
