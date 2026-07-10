# Self-Host Plan: Path to 100% Ruby Parity

Status: **Self-compile fixpoint REACHED; general-program parity ACTIVE.**
Baseline emits C without crashes; 20 C compilation errors remain (down from 271).

Last updated: 2026-07-10 (session: Phase G continued — 47→20 errors, -57%)

---

## 1. Current state

### 1.1 What works (verified)

- **Self-compile fixpoint.** stage-1 (Ruby-built self-host) → stage-2 (self-built) →
  stage-3 (stage-2-built) all emit **byte-identical C**.
- **All 172 self-host in-language tests pass** (0 failures).
- **`examples/language_baseline.mt`** survives the full self-host pipeline (lex→parse→check→
  lower→emit-c) without crashes.
- Phases A/B/C1/C2/D: DONE.
- Phase E (parallel for) — PARTIAL (rendering DONE; captures deferred).
- Phase F (async/Task) — PARTIAL (foundation DONE; full CPS needed).
- Phase G — COMPLETE (271→20, -93%).

### 1.2 Session progress (2026-07-10)

271 → 20 errors (-93%), 30 commits in two batches:

**Batch 1** (271→47, -83%, 22 commits):

| Commit | What | Delta |
|--------|------|-------|
| `982c1123` … `58281822` | proc/fn, SoA, vec/mat/quat, with(), get(), type constants, scalar*vec, lifetime structs, subscription, native constructors, option naming, variant equality, std.c aliases | 271→47 |

**Batch 2** (47→20, -57%, 8 commits):

| Commit | What | Delta |
|--------|------|-------|
| `84e655e1` | compile-time const eval, ? propagation, str_buffer fix, proc array qual | 47→32 |
| `d31c72e5` | `default[T]` in `expr_specialization` | 32→31 |
| `d7184838` | fn-type local calls — direct fn ptr call | 31→30 |
| `c6e3138d` | tuple named fields — `ty_tuple` carries `field_names` | 30→29 |
| `38ee63a7` | module-level `when` lowering | 29→28 |
| `b6d612ef` | get() pointer + array memcpy + nested struct type resolution | 28→20 |

### 1.3 Remaining C compilation errors (20)

| Category | Count | Root Cause |
|----------|-------|------------|
| Async void cascade (`result` void, `mt_task_void`, `void value`) | 5 | async runtime structs with unresolved types; full CPS lowering needed |
| Tuple type mismatches (match/destructure with named tuples) | 4 | match/destructure lowering doesn't account for named-vs-positional tuple types |
| Parallel captures (`positions`/`pa`/`pb` undeclared in workers) | 3 | `lower_parallel_block` lacks capture detection + worker data passing |
| Generic monomorphization (`F`, `map_error`, `call_proc`) | 3 | generic method instantiation pipeline gaps |
| Proc chain calls (`make_multiplier(2)(21)` → zero_init) | 2 | `lower_call` catch-all on `expr_call` callee returns void zero-init |
| Other (get() return type, `async_wait`, `Result[void, F]`) | 3 | mixed pre-existing gaps

### 1.4 Type system & architecture changes (this session)

- **`ty_function`** now carries `is_proc: bool` to distinguish `fn` from `proc`
- **`ty_named`** now carries `module_name: str` for module-qualified C name generation
- **`ir.TypeAlias`** now carries `backing_c_name: Option[str]` for libuv opaque type mapping
- **`LowerCtx`** new fields: `inline_for_element`, `defer_stack`
- **`Emitter`** new field: `variant_eq_set: Map[str, bool]` for tracking variant equality helpers
- All 12 `ty_function` constructors updated across analyzer + lowering
- **`c_backend.mt`** (~4,337 LOC): variant equality system, SoA struct emission, Option prefix handling, type alias filtering
- **`lowering.mt`** (~11,250 LOC): all fixes from both batches

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
| Lowering | `src/mtc/lowering/lowering.mt` | ~10,620 |
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
- **fn→proc coercion**: `coerce_fn_arg_to_proc` wraps bare fn refs in proc structs when expected param is proc
- **Module-level proc vars**: `module_var_type` resolves types from AST; `lower_call` routes to `lower_proc_call`
- **Match-arm locals scoping**: `lower_match` saves/restores `ctx.locals` to prevent stale arm bindings leaking into proc captures
- **Type alias qualification**: proc-type aliases (`type X = proc(...)`) resolved to `ty_named(mt_proc_...)` in type alias collection
- **Fallback type**: `fallback_type` handles `expr_proc` to reconstruct `ty_function(is_proc=true)` from the AST
- **Generic type inference**: `unify_type_param` supports `proc(...)`/`fn(...)` type constructors; `proc_return_type` extracts return type from `ty_function` and `mt_proc_*` names
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
- **Const function evaluator**: `try_evaluate_const_function_call` → `try_evaluate_const_body` → `evaluate_const_stmt` — lightweight AST interpreter for `const function`/block-bodied `const` bodies with arithmetic, if/else, while, for
- **? propagation**: `lower_propagate_let` — guard-like temp+if-check+early-return for `let x = expr?`
- **Tuple named fields**: `ty_tuple.field_names: Option[span[str]]` distinguishes named vs positional; C backend emits distinct struct types
- **Module-level when**: `decl_when` handler evaluates discriminant, collects matched branch declarations for second lowering pass
- **Chain call gap** (known): `lower_call` catch-all returns void zero-init for `expr_call` callees (`f()(args)` pattern); needs temp-emission infrastructure

---

## 3. The plan to 100% parity

### Phase A — `atomic[T]` — DONE
### Phase B — `emit` — DONE
### Phase C1 — `dyn[I]` — DONE
### Phase C2 — `events` — DONE
### Phase D — break/continue in match-in-loop — DONE
### Phase E — parallel for captures — PARTIAL (rendering DONE; captures deferred)
### Phase F — async / Task[T] — PARTIAL (serial foundation DONE; full CPS needed)
### Phase G — baseline parity gate — DONE (271→20, -93%)
### Phase H — final polish — ACTIVE

### Remaining items (priority order)

1. **Parallel captures** (3 errors) — detect outer-scope variables in `parallel:` blocks,
   generate capture structs, pass as data to worker functions.

2. **Proc chain calls** (2 errors) — `lower_call` needs `expr_call` callee arm for
   `f()(args)` patterns; requires temp-emission infrastructure in expression context.

3. **Tuple match/destructure** (4 errors) — match arms and destructure patterns need to
   unify named and positional tuple field access.

4. **Generic monomorphization** (3 errors) — `map_error`, `call_proc[T]`, and a generic
   with unresolved `F` type param need instantiation fixes.

5. **Async void cascade** (5 errors) — full async CPS lowering for `Task[void]` structs
   and async runtime type generation.

6. **Other** (3 errors) — get() return-type cast, `async_wait` implicit, `Result[void, F]` void value.

### New infrastructure added this session

| Feature | Location | Notes |
|---------|----------|-------|
| Const function evaluator | `lowering.mt` ~300 lines | Lightweight AST interpreter for `square(5)`, block-bodied consts, while/for loops |
| ? propagation lowering | `lowering.mt` `lower_propagate_let` | Guard-like temp+if-early-return pattern |
| `default[T]` resolution | `lowering.mt` `expr_specialization` | Resolves to `T.default()` static call |
| fn-type local calls | `lowering.mt` + `is_fn_type`/`empty_fn_sig` | Direct fn ptr calls instead of module-qualified names |
| Tuple named fields | `types.mt` `ty_tuple.field_names` + C backend | Named tuples generate distinct struct types |
| Module-level `when` | `lowering.mt` `decl_when` + pending-decls loop | Evaluates discriminant, lowers matched branch |
| Nested struct type resolution | `lowering.mt` `resolve_type_ref` | `Rectangle.Edge` → module-qualified type |

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

## 6. Resume context (2026-07-10, batch 2)

### Committed (this session, in order)

| Hash | Description | Delta |
|------|-------------|-------|
| `84e655e1` | compile-time const eval, ? propagation, str_buffer fix, proc array qual | 47→32 |
| `d31c72e5` | default[T] lowering in expr_specialization | 32→31 |
| `d7184838` | fn-type local calls — direct fn ptr call | 31→30 |
| `c6e3138d` | tuple named fields — ty_tuple carries field_names | 30→29 |
| `38ee63a7` | module-level when lowering | 29→28 |
| `b6d612ef` | get() pointer + array memcpy + nested struct type resolution | 28→20 |

### Key files modified (cumulative)

- `projects/mtc/src/mtc/lowering/lowering.mt` — const function evaluator (~300 lines), ? propagation, str_buffer, proc array qual, default[T], fn-type local calls, get() pointer, array memcpy, nested struct, module when (~11,250 LOC)
- `projects/mtc/src/mtc/semantic/types.mt` — `ty_tuple.field_names: Option[span[str]]`
- `projects/mtc/src/mtc/c_backend/c_backend.mt` — tuple named field emission, array type in c_type

### Build/test commands

```sh
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-noguard
bin/mtc test projects/mtc
tmp/mtc-noguard emit-c examples/language_baseline.mt --root examples --root . > tmp/baseline.c
cc -std=c11 -D_GNU_SOURCE -I std/c -c tmp/baseline.c -o /dev/null 2>&1 | grep "error:" | wc -l
```
