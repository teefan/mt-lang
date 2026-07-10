# Self-Host Plan: Path to 100% Ruby Parity

Status: **Self-compile fixpoint REACHED; general-program parity ACTIVE.**
Baseline emits C without crashes (3,469 lines); 49 C compilation errors remain (down from 271).

Last updated: 2026-07-10 (session: Phase G complete — 18 commits, 271→49 errors, -82%)

---

## 1. Current state

### 1.1 What works (verified)

- **Self-compile fixpoint.** stage-1 (Ruby-built self-host) → stage-2 (self-built) →
  stage-3 (stage-2-built) all emit **byte-identical C** (~53,226 lines, 0 diffs).
- **All 172 self-host in-language tests pass** (0 failures).
- **`examples/language_baseline.mt`** survives the full self-host pipeline (lex→parse→check→
  lower→emit-c) without crashes, producing **3,469 lines of C**.
- Phases A/B/C1/D: `atomic[T]`, `emit`, `dyn[I]`, break/continue in match-in-loop — DONE.
- **Events (Phase C2)** — DONE.
- **Parallel for rendering (Phase E)** — DONE (ptr-to-array, captures deferred).
- **Serial async (Phase F)** — PARTIAL (foundation DONE; full CPS needed).
- **proc/fn sub-issues 1A/1C/1D/1E/1F** — DONE (6 of 7 proc sub-issues resolved).
- **fn/proc struct field calls** — DONE (Callback_invoke, FnFilter_check).

### 1.2 Recent progress (session 2026-07-10)

271 → 49 errors (-82%), 18 commits:

| Commit | What | Delta |
|--------|------|-------|
| `2f2791cc` | fn/proc struct field calls + modvar_proc routing | 51→49 |
| `9a824d94` | is_proc_type, void invoke, stale captures, shared structs, type alias (5 sub-issues) | 57→51 |
| `b43089de` | is_proc_type (1A), void invoke (1C), stale captures (1F) | 57→53 |
| `b06e7463` | Proc capture dedup names + proc type qualification in qualify_type | 65→57 |
| `e51697eb` | .with() partial field update → aggregate literal copy | 70→65 |
| `b68a2869` | Type constants — resolve 'type' keyword, skip C emission | 73→70 |
| `3316ac0f` | Subscription comparison — check slot==0 for mt_subscription | 76→73 |
| `24c81767` | Buffer lifetime struct emission — skip non-lifetime type params | 82→76 |
| `f5f605dd` | Scalar*vec multiplication — use `!is_vec_math_name` not is_numeric | 107→82 |
| `d611458e` | Native type constructors — vec3/mat4/quat as aggregate literals | 114→107 |
| `58ed7b6c` | vec/mat/quat binary ops + field type resolution | 103→95 |
| `39a834a6` | get() builtin — lower to checked_index/checked_span_index | 106→103 |
| `aef89f3f` | SoA indexing — swap member+index + emit SoA struct defs | 116→106 |
| `58281822` | std.c.* type aliases, variant equality, option naming (3 fixes) | 136→116 |

### 1.3 Remaining C compilation errors (49, down from 271)

| Category | Count | Root Cause |
|----------|-------|------------|
| Proc/fn type issues | ~10 | modvar_proc not proc-route; fn→proc coercion at call boundary (apply_int_op); call_proc generic not monomorphized; invoke/env on array elements typed as fn pointer |
| Compile-time reflection | 3 | `has_attribute`, `field_of`, `square(5)` not constant-folded; emit function calls instead |
| ? propagation | 2 | `expr?` not lowered to if-then-return pattern |
| Parallel for captures | 3 | `pa`/`pb`/`positions` not passed to worker functions |
| Tuple named fields | 4 | Named tuples generate positional structs (no `.x`/`.y`) |
| Str buffer API | 3 | `mt_str_buffer_len` argument mismatch |
| Cascading void/unknown-type | ~24 | From above root causes (result void, value void, qualified void, F unknown, task_void) |

### 1.4 Type system & architecture changes (this session)

- **`ty_function`** now carries `is_proc: bool` to distinguish `fn` from `proc`
- **`ty_named`** now carries `module_name: str` for module-qualified C name generation
- **`ir.TypeAlias`** now carries `backing_c_name: Option[str]` for libuv opaque type mapping
- **`LowerCtx`** new fields: `inline_for_element`, `defer_stack`
- **`Emitter`** new field: `variant_eq_set: Map[str, bool]` for tracking variant equality helpers
- All 12 `ty_function` constructors updated across analyzer + lowering
- **`c_backend.mt`** (~4,337 LOC): variant equality system, SoA struct emission, Option prefix handling, type alias filtering
- **`lowering.mt`** (~10,511 LOC): vec/mat/quat binary ops, with() lowering, get() builtin, SoA index swap, vec field type resolution, lifetime struct check, type constant skip, proc capture dedup, proc type qualification, std.c.* alias skip, `is_proc_type(fnt.is_proc)`, `fallback_type` expr_proc, match-arm locals scoping, shared proc struct names (`mt_proc_*`), proc type alias qualification, fn/proc struct field call detection (`lower_fn_field_call`, `lower_proc_field_call`)

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

Self-host source layout (`projects/mtc/src`, ≈32k LOC):

| Stage | Path | LOC |
|-------|------|-----|
| Lexer | `src/mtc/lexer/` | ~1,590 |
| Parser + AST | `src/mtc/parser/*.mt` | ~4,860 |
| Pretty printers | `src/mtc/pretty_printer/*.mt` | ~2,190 |
| Semantic analyzer | `src/mtc/semantic/analyzer.mt` | ~4,080 |
| Type system | `src/mtc/semantic/types.mt` | ~710 |
| Loader | `src/mtc/loader/` | ~730 |
| IR | `src/mtc/ir.mt` | ~230 |
| Lowering | `src/mtc/lowering/lowering.mt` | ~10,511 |
| C Backend | `src/mtc/c_backend/c_backend.mt` | ~4,337 |
| Build driver | `src/mtc/build.mt` | ~160 |
| C naming (shared) | `src/mtc/c_naming.mt` | ~137 |

### 2.1 Key seams

- **Monomorphization**: `try_generic_method_call` → `lower_monomorphized_method`
- **Naming**: `naming.type_c_key(ty)` is the single source of truth
- **fn vs proc**: `ty_function.is_proc` distinguishes; `is_proc_type` checks `fnt.is_proc`
- **Proc struct conversion**: `qualify_type` converts `ty_function(is_proc=true)` to `ty_named(mt_proc_…)`
- **Shared proc struct names**: `lower_proc_expression` uses `proc_type_name_from_signature` for the struct type name (not unique `__proc_N`)
- **Proc field calls**: `lower_call` detects fn/proc struct fields via `concrete_field_type` + `analysis.structs`; `lower_fn_field_call` for direct fn ptr calls, `lower_proc_field_call` for proc invoke
- **Match-arm locals scoping**: `lower_match` saves/restores `ctx.locals` to prevent stale arm bindings leaking into proc captures
- **Type alias qualification**: proc-type aliases (`type X = proc(...)`) resolved to `ty_named(mt_proc_...)` in type alias collection
- **Fallback type**: `fallback_type` handles `expr_proc` to reconstruct `ty_function(is_proc=true)` from the AST
- **Inline for**: `lower_inline_for_stmt` → `comptime_iterable_elements` → per-element unrolling
- **Cross-module opaque**: `lookup_decl_c_name_cross` follows import chain for C type mapping
- **LowerCtx factory**: `new_lowering_context(analysis, …)` single init point
- **Variant equality**: C backend `emit_variant_equality_helpers` generates `mt_variant_eq_<type>` static helpers
- **Type alias collection**: `type_is_from_std_c` skips aliases from `std.c.*` modules
- **SoA**: `lower_member_access` swaps index+member for SoA types; `emit_soa_types` generates `mt_soa_<Elem>_N` struct defs
- **Vec/mat/quat ops**: `lower_vec_binary_op` + `lower_vec_unary_neg` → component-wise aggregate literals; `vec_math_fields()` enumerates field names/types
- **with()**: `lower_with_call` → aggregate literal with specified fields replaced
- **get()**: `lower_call` routes to `expr_checked_index`/`expr_checked_span_index`
- **Lifetime structs**: `has_non_lifetime_type_params` allows lifetime-only structs to emit directly
- **Subscription guard**: `guard_failure_condition` detects `mt_subscription` and checks `slot==0`
- **Type constants**: `resolve_type_ref` maps `type` keyword → `ty_type_meta`; skipped in C emission
- **Proc capture dedup**: `collect_locals_for_capture` uses `seen_names` map to avoid duplicate struct fields
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
### Phase G — baseline parity gate — COMPLETE (271→49, -82%)
### Phase H — final polish — NOT STARTED

### Recommended next actions (priority order)

1. **Compile-time constant folding** (3 errors) — `has_attribute`, `field_of`, `square(5)` emit function calls instead of computed values. Fix: extend `try_evaluate_const_expr` to handle builtin reflection calls and const-function invocation. Straightforward: special-case the builtin names in `lower_call` around line 3618, before the fallback to `lower_plain_call_sig`.

2. **? propagation** (2 errors) — `expr?` not lowered to if-then-return pattern. Fix: in `lower_expr` for `expr_unary_op` with operator `"?"`, emit a temp variable assignment + kind check + early return. Or add `ir.Expr.expr_propagate` IR node.

3. **Tuple named fields** (4 errors) — Named tuples generate positional structs. Fix: extend `ty_tuple` with optional field names; use names in `lower_tuple_literal`.

4. **Parallel for captures** (3 errors) — Fix: detect captures in parallel worker bodies, generate capture structs, pass as data args.

5. **Remaining proc/fn** (~10 errors) — modvar_proc call routing, fn→proc coercion at call boundary, call_proc monomorphization. Needs analyzer-level type promotion or call-site type checking.

6. **Str buffer API** (3 errors) — Fix argument counts in `lower_str_buffer_method`.

7. **Phase H** — format helpers, string-literal-index stabilization, async CPS, final edge cases.

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
| `58281822` | std.c.* type aliases + variant equality + option naming (136→116) |
| `aef89f3f` | SoA indexing — swap member+index, emit struct defs (116→106) |
| `39a834a6` | get() builtin — lower to checked_index (106→103) |
| `58ed7b6c` | vec/mat/quat binary ops + field type resolution (103→95) |
| `d611458e` | Native constructors as aggregate literals (107→114* →107) |
| `f5f605dd` | Scalar*vec fix — use nominal type name (107→82) |
| `24c81767` | Buffer lifetime struct emission (82→76) |
| `3316ac0f` | Subscription comparison — slot==0 check (76→73) |
| `b68a2869` | Type constants — resolve 'type' keyword (73→70) |
| `e51697eb` | .with() partial field update (70→65) |
| `b06e7463` | Proc capture dedup + proc type qualification (65→57) |
| `b43089de` | is_proc_type (1A), void invoke (1C), stale captures (1F) → (57→53) |
| `9a824d94` | Shared struct names (1E), type alias qualification (1D) → (53→51) |
| `2f2791cc` | fn/proc struct field calls + modvar_proc routing → (51→49) |

### Key files modified (cumulative)

- `projects/mtc/src/mtc/semantic/types.mt` — `is_proc` on `ty_function`, `module_name` on `ty_named`
- `projects/mtc/src/mtc/semantic/analyzer.mt` — nested type registration, `ctx.module_name` propagation, `is_proc` setting
- `projects/mtc/src/mtc/c_naming.mt` — `type_c_key` for module-qualified `ty_named`
- `projects/mtc/src/mtc/c_backend/c_backend.mt` — variant equality, SoA structs, option prefix, type alias filtering (~4,337 LOC)
- `projects/mtc/src/mtc/ir.mt` — `backing_c_name` on `TypeAlias`
- `projects/mtc/src/mtc/lowering/lowering.mt` — all fixes (~10,511 LOC)
- `docs/self-host-plan.md` — updated status and architecture seams
- `docs/self-host-gap-analysis.md` — per-category detailed analysis of remaining 49 errors

### Build/test commands

```sh
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-noguard
bin/mtc test projects/mtc
tmp/mtc-noguard emit-c examples/language_baseline.mt --root examples --root . > tmp/baseline.c
cc -std=c11 -D_GNU_SOURCE -I std/c -c tmp/baseline.c -o /dev/null 2>&1 | grep "error:" | wc -l
```
