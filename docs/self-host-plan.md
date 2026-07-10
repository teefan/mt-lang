# Self-Host Plan: Path to 100% Ruby Parity

Status: **Self-compile fixpoint REACHED; general-program parity ACTIVE.**
Baseline emits C without crashes; 9 C compilation errors remain (down from 271).

Last updated: 2026-07-10 (session: Phase G complete — batches 2+3: 47→9, -81%)

---

## 1. Current state

### 1.1 What works (verified)

- **Self-compile fixpoint.** stage-1 (Ruby-built self-host) → stage-2 (self-built) →
  stage-3 (stage-2-built) all emit **byte-identical C**.
- **All 172 self-host in-language tests pass** (0 failures).
- **`examples/language_baseline.mt`** survives the full self-host pipeline (lex→parse→check→
  lower→emit-c) without crashes.
- Phases A/B/C1/C2/D/E: DONE.
- Phase F (async/Task) — PARTIAL (foundation DONE; full CPS needed).
- Phase G — **DONE** (271→9, -97%).

### 1.2 Session progress (2026-07-10)

271 → 9 errors (-97%), 15 commits in batch 3 (batches 1+2: 21 commits, 271→20):

**Batch 3** (20→9, -55%, 7 commits):

| Commit | What | Delta |
|--------|------|-------|
| `1953e805` | parallel captures — IR name scanner, capture struct gen, worker preamble, scalar + array via memcpy | 20→17 |
| `e2c2718d` | array captures via memcpy + restore loop_body reassignment | 18→17 |
| `b02e2a1e` | chain calls in return — hoist proc result to temp for f()(args) pattern | 17→15 |
| `dc1139b4` | range index assignment — expand arr[0..2]=(e1,e2) into individual checked-index writes | 15→14 |
| `4519fa58` | generic method-level type params + unify_type_param proc/fn detection + proc_return_type split | 13→10 |
| `8b9db2bf` | fix receiver struct-args for methods with extra type params | 10→9 |

### 1.3 Remaining C compilation errors (9)

| Category | Count | Lines | Root Cause |
|----------|-------|-------|------------|
| Async void cascade (`result` void, `mt_task_void`, `void value`) | 4 | 375, 409, 430, 807 | async runtime structs; full CPS lowering needed |
| Tuple type mismatches (destructure/match with named vs positional) | 3 | 2729, 2731, 2749 | match/destructure lowering doesn't account for named-vs-positional tuple types |
| get() return-type mixup (`int32_t*` returned from `int` function) | 1 | 2219 | `val_ptr` (ptr) added to int return in builtins_demo |
| `std_async_wait` implicit declaration | 1 | 2862 | async runtime; goes with async void cascade |

### 1.4 Infrastructure added this session (batch 3)

| Feature | Location | Notes |
|---------|----------|-------|
| Parallel captures | `lowering.mt` `lower_parallel_block`/`lower_parallel_for` | IR name scanner `collect_ir_names`, capture detection via `find_local_before`, capture struct via `pending_env_structs`, worker preamble injection, array captures via `memcpy` |
| Chain calls in return | `lowering.mt` `stmt_ret` | `f()(args)` pattern hoisted to temp + `lower_proc_call` |
| Range index assignment | `lowering.mt` `lower_range_index_assignment` | Expands `arr[0..2]=(e1,e2)` to per-element checked-index writes |
| Generic method-level type params | `lowering.mt` `try_generic_method_call` | Extends `concrete_args` with inferred method-level params (e.g. `F` in `map_error[F]`) |
| `unify_type_param` proc/fn detection | `lowering.mt` | Uses `is_proc`/`is_fn` + `fn_return` fields instead of `name`/`arguments` |
| `proc_return_type` split | `lowering.mt` | Splits `mt_proc_str_int` at first `_` to extract return type `str` |
| Receiver struct-args for methods | `lowering.mt` `lower_specialized_method` | Uses only struct-level args for receiver type, not extended method-level args

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
- **Parallel captures**: `collect_ir_names` / `collect_ir_expr_names` walk lowered IR for outer-scope locals; capture struct via `pending_env_structs`; worker preamble injects capture-unpacking; array fields use `memcpy`
- **Chain calls**: `stmt_ret` handler detects `return f()(args)` pattern, hoists intermediate proc result to temp, calls through with `lower_proc_call`
- **Range index assignment**: `lower_range_index_assignment` expands `arr[0..2]=(e1,e2)` to per-element `checked_index` writes with computed start+offset indices
- **Generic method-level type params**: `try_generic_method_call` infers method-level params (e.g. `F` in `map_error[F]`) from arguments, extends `concrete_args`; `ensure_monomorphized_method` maps both struct-level and method-level params in substitution
- **unify_type_param proc/fn detection**: uses `is_proc`/`is_fn` + `fn_return` AST fields instead of `name`/`arguments` (parser stores callable types specially)

---

## 3. The plan to 100% parity

### Phase A — `atomic[T]` — DONE
### Phase B — `emit` — DONE
### Phase C1 — `dyn[I]` — DONE
### Phase C2 — `events` — DONE
### Phase D — break/continue in match-in-loop — DONE
### Phase E — parallel for captures — DONE (scalar + array captures)
### Phase F — async / Task[T] — PARTIAL (foundation DONE; full CPS needed)
### Phase G — baseline parity gate — DONE (271→9, -97%)
### Phase H — final polish — ACTIVE

### Remaining items (9 errors, 3 categories)

1. **Tuple match/destructure** (3 errors) — match arms and destructure patterns need to
   unify named and positional tuple field access. Named tuples now have distinct struct
   types (`mt_tuple_int_int_x_y` vs `mt_tuple_int_int`), but destructure bindings and
   match-arm patterns still produce positional field access.
   - Fix: lower_match / lower_destructure need to inspect `ty_tuple.field_names` and route
     field access through the correct named or positional fields.

2. **Async void cascade** (5 errors) — full async CPS lowering for `Task[void]` structs
   and async runtime type generation. The `import std.async` import triggers generation of
   async runtime structs (`mt_task_void`, work-state types) that reference void/unresolved
   fields. Needs the full Phase F CPS infrastructure.  Comprising:
   - 4 async struct void errors + 1 `std_async_wait` implicit.

3. **get() return-type cast** (1 error) — `val_ptr` (`int32_t*` from `unsafe: read(raw_p)`)
   is added to the `int` return sum in `builtins_demo` without a cast.  Pre-existing
   from before batch 2.

## 4. Differential harness

- **IR is the frozen seam.** Backend reads only `IR`; Lowering reads only `Analysis`.
- **Byte-identical C is the correctness oracle.**
- **Follow Ruby's algorithmic structure.**
- **Fail loud on substrate gaps** (no silent wrong C).
- **Small anchored edits** near function boundaries; rebuild immediately.
- **Sandbox every built binary** (`timeout` + `ulimit -v`).

---

## 6. Resume context (2026-07-10, batch 3)

### Committed (this session, in order)

| Hash | Description | Delta |
|------|-------------|-------|
| `1953e805` | parallel captures — IR name scanner, capture struct gen, worker preamble, scalar + array via memcpy | 20→17 |
| `e2c2718d` | array captures via memcpy + restore loop_body reassignment | 18→17 |
| `b02e2a1e` | chain calls in return — hoist proc result to temp for f()(args) pattern | 17→15 |
| `dc1139b4` | range index assignment — expand arr[0..2]=(e1,e2) into individual checked-index writes | 15→14 |
| `4519fa58` | generic method-level type params + unify_type_param proc/fn detection + proc_return_type split | 13→10 |
| `8b9db2bf` | fix receiver struct-args for methods with extra type params | 10→9 |

### Key files modified (cumulative)

- `projects/mtc/src/mtc/lowering/lowering.mt` — parallel captures (~313 lines), chain calls, range index assignment, generic method-level params, unify_type_param proc/fn, proc_return_type split, receiver struct-args (~11,850 LOC)
- `projects/mtc/src/mtc/semantic/types.mt` — `ty_tuple.field_names: Option[span[str]]`
- `projects/mtc/src/mtc/c_backend/c_backend.mt` — tuple named field emission, array type in C type position

### Next session prompts

- **Tuple match/destructure** (3 errors): `lower_destructure` and match-arm field access need to inspect `ty_tuple.field_names` — if named, use those names; if `Option.none`, use `_0`/`_1`.
- **Async void cascade** (5 errors): Phase F full CPS. Async runtime structs (`mt_task_void`, work-state types) generated by `std.async` import produce void fields. Needs the async lowering pipeline that Ruby has — task continuation splitting, yielded member access, async runtime struct emission with resolved types.
- **get() return-type cast** (1 error): Pre-existing. `val_ptr` is `int32_t*` from `read(raw_p)` where `raw_p` is `ptr_of(handle)`. The `unsafe: read(raw_p)` produces `ptr[int]` (`int32_t*`), not `int`. The sum expression at the return site needs a cast or the baseline source has a type that resolves differently from what the Ruby compiler produces.

### Build/test commands

```sh
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-noguard
bin/mtc test projects/mtc
tmp/mtc-noguard emit-c examples/language_baseline.mt --root examples --root . > tmp/baseline.c
cc -std=c11 -D_GNU_SOURCE -I std/c -c tmp/baseline.c -o /dev/null 2>&1 | grep "error:" | wc -l
```
