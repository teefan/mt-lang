# Self-Host Plan: Lowering + C-Backend

Status: **Phases 0–4 complete, Phase 5 in progress.** 5 of 7 Phase 5 items done:
fn pointer types, method dispatch + extending blocks, proc closures
(non-capturing, capturing with ref-counted lifecycle, fn→proc coercion,
indirect calls), is + match-expressions.  Remaining: dyn[I], str_buffer[N],
format strings.
Owner: compiler team
Last updated: 2026-07-06 (commits through cab27b68)

Pipeline:

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

Self-host source layout (src ≈ 21.0k LOC):

| Stage | Path | LOC |
|-------|------|-----|
| Lexer | `src/mtc/lexer/` | ~1,600 |
| Parser + AST | `src/mtc/parser/*.mt` | ~4,700 |
| Pretty printers | `src/mtc/pretty_printer/*.mt` | ~2,000 |
| Semantic analyzer | `src/mtc/semantic/*.mt` | ~5,000 |
| Loader | `src/mtc/loader/*.mt` | ~700 |
| IR | `src/mtc/ir.mt` | ~220 |
| Lowering | `src/mtc/lowering/lowering.mt` | ~3,750 |
| C Backend | `src/mtc/c_backend/c_backend.mt` | ~2,590 |
| Build driver | `src/mtc/build.mt` | ~80 |
| C naming (shared) | `src/mtc/c_naming.mt` | ~70 |

**All 172 self-host tests pass, 0 files failed.**

---

## 1. What is complete

### Phases 0–3 — Scalars, control flow, aggregates
Byte-identical to Ruby on 11 differential programs.

### Phase 4a — Multi-module assembly
`lower()` concatenates all non-external modules. Cross-module calls via
`analysis.imports` + shared `program_returns`. Un-annotated local types
prefer IR type (correct cross-module qual).

### Phase 4b — Non-generic variants
Variant decls, arm constructors, switch + if/goto match strategies, field
destructure bindings, dead-code elimination, compound-literal payload casts,
`goto`/`label` emission. Byte-identical to Ruby on 3 variant programs.

### Phase 4c — Generics monomorphization (complete)

**Architecture:**
- **Inline monomorphization** — generic calls lowered immediately on encounter
  (`lower_specialization_call` → `lower_monomorphized_call` →
  `lower_and_cache_specialization`).
- Cached in `specialization_cache`; entries pushed to program functions.
- Generic struct decls by lowering (AST field types + `substitute_type_params`).
- `type_substitution` map in LowerCtx, consulted by `resolve_type_ref`/`resolve_field_type_ref`
  during monomorphized body lowering.
- `cross_module_return_type` checks `ctx.function_returns` for monomorphized functions.
- Cycle detection via `spec_in_progress` guard.
- `prelude_variant_arm_info` parameterized with concrete type args.
- Backend: `collect_generic_variants` filtered to prelude types only.

**Key fixes:**
- `resolve_type_ref`/`resolve_field_type_ref` `ty_named` fallback for type params.
- `resolve_field_type_ref` delegates to `resolve_generic_type_ref` for complex types.
- Generic struct fields read from AST (not `analysis.structs`, which stores `ty_error`).
- Body expressions in monomorphized functions use substituted concrete types.
- `c_type`: `ty_var` handler, `ty_named` handler, mangled match arms fixed.
- `ir_expr_type` handles `expr_variant_literal` and `expr_array_literal`.
- `gen_variants_have_str` detects str in synthetic generic variant fields.

**Final gap resolved (2026-07-07):**
- **Symptom:** `import imp3; imp3.make[int](40, 2)` crashed in lowering when
  `make[T] → Pair[T, T]` returned a user-defined generic struct.
- **Root cause (refined):** During monomorphization of `make[int]`, the
  function body contained `Pair[int, int](first = a, second = b)` — a struct
  constructor referencing *Pair* (defined in the imported `imp3` module).
  `lower_specialization_call` only checked `ctx.analysis.structs` (the
  caller's module) when routing `Name[TypeArgs](named_args)` to
  `lower_generic_aggregate_literal`. Since main3 didn't declare *Pair*, the
  constructor was misrouted to `lower_monomorphized_call`, which tried to
  monomorphize it as a generic function — failing because *Pair* is a struct.
- **Fix:** Added `struct_exists_in_imports(ctx, name)` (16 LOC) — iterates
  `ctx.analysis.imports`, walks each imported module's analysis, and checks
  its `structs` map.  Called in `lower_specialization_call` as a fallback
  when the current module doesn't own the struct name.  Total fix: 29 LOC
  in `lowering.mt`.
- **Debug methodology:** Used file-based debug output (`std.fs.write_text`)
  to trace the callee name and module context, revealing that the callee was
  *Pair* (not *make*), which pointed to the real problem.  Future debugging
  should prefer `std.log` (unbuffered stderr) over file I/O.

**10 verification programs (all correct exits):**

| Program | Feature | Exit |
|---------|---------|------|
| `id[T](42)` | Same-module generic identity | 42 |
| `Pair[A,B] + first[T]` | Same-module generic struct + function | 42 |
| `Option[int]` | Prelude variant + match | 42 |
| `lib.Pair[int,int]` | Cross-module struct constructor | 42 |
| `Result[int,str]` | Non-int error type | 7 |
| `Option[int].none` | Generic no-payload variant | 42 |
| `single make[int]` | Same-module struct-returning function | 40 |
| `imp.id[int](42)` | Cross-module generic identity | 42 |
| `imp2.make[int](40,2)` | Cross-module scalar-returning function | 40 |
| `imp3.make[int](40,2)` | Cross-module struct-returning function | 42 |

### Pre-existing issues fixed
- DA scoping false-positives (scope-name stack with per-block marks).
- `array[T,N](...)` constructor (lowering + backend emission).
- Dead code removed (~104 LOC).

---

## 2. Deferred items

- **Guards and equality patterns** in struct-pattern match arms. Target: Phase 5.
- **Build-mode codegen parity**. Target: Phase 7.
- **`as cstr` for non-literal values**. Target: Phase 5.
- **Prelude module prefix** (`std_option_Option_int` vs `Option_int`). Target: Phase 7.
- **proc selective retain** (retain on assign only for non-fresh procs). Target: Phase 5 (proc polish).
- **proc release on scope exit** (defer-style env release). Target: Phase 5 (proc polish).
- **SoA**: deferred indefinitely.

---

## 3. Remaining work per phase

### Phase 5 — proc/fn, dyn, method dispatch, str_buffer, format, `is`

| # | Item | Est. LOC | Status | Notes |
|---|------|----------|--------|-------|
| 1 | **proc closures** | ~800 | ✅ done | Non-capturing + capturing with ref-counted lifecycle + fn→proc coercion + `expr_call_indirect` |
| 2 | **fn pointer types** | ~50 | ✅ done | `c_fn_ptr_declarator`, `ty_function` in `c_type`/`c_declaration` |
| 3 | **dyn[I] interfaces** | ~200 | pending | Vtable struct + fat pointer + `adapt` |
| 4 | **Method dispatch** | ~400 | ✅ done | Extending block lowering, `MethodInfo`, `resolve_method_info`, receiver passing (pointer/value/static) |
| 5 | **str_buffer[N]** | ~150 | pending | Type decl + append/assign/as_str methods |
| 6 | **Format strings** | ~250 | pending | `f"..."` desugaring + format-value lowering |
| 7 | **`is` + match-expressions** | ~200 | ✅ done | Enum + variant `expr_match` hoisting, `lower_match_expression_local` |
| **Total** | | **~2,050** | 5/7 done |

### Phase 6 — events, async, parallel, compile-time

| # | Item | Est. LOC | Ruby ref | Notes |
|---|------|----------|----------|-------|
| 1 | **Events** — `emit`, `subscribe`, `unsubscribe` | ~600 | `events.rb` 1,054 | Event queue + handler dispatch |
| 2 | **Async/await** — state-machine transform | ~2,000 | `async/*` 2,834 | Highest-risk module after generics |
| 3 | **parallel/detach/gather** — libuv dispatch | ~400 | — | Thread pool + handle tracking |
| 4 | **Compile-time** — `const function`, `when`, `inline`, `emit`, reflection | ~800 | `compile_time/*` + `const_eval.rb` | CT eval + emit code generation |
| **Total** | | **~3,800** | | |

### Phase 7 — Build parity + self-host bootstrap

| # | Item | Notes |
|---|------|-------|
| 1 | Build cache + `--no-cache` / `--keep-c` | |
| 2 | Module roots / package graph (`--root`, `package.toml`) | |
| 3 | Platform targets (linux/windows/wasm) | |
| 4 | `--debug-guards` (loop iteration guards) | |
| 5 | `#line` directives in emitted C | |
| 6 | Build-mode include set (`<stdlib.h>`, `mt_fatal` always-on) | |
| 7 | Prelude module prefix (`std_option_` names) | |
| 8 | **Milestone: `mtc build projects/mtc`** — self-host compiles itself | |

---

## 4. Progress checklist

- [x] Phase 0 — IR + scaffolding
- [x] Phase 1 — return-int binary
- [x] Phase 2 — control flow, str/cstr, enums, foreign
- [x] Phase 3 — non-generic aggregates
- [x] Phase 4a — multi-module assembly + cross-module calls
- [x] Phase 4b — non-generic variants + match strategies + variant literals
- [x] Phase 4c — generics monomorphization (complete)
  - [x] Same-module generic functions
  - [x] Same-module generic structs
  - [x] Prelude variant pipeline (Option/Result)
  - [x] Type substitution (ty_var/ty_named/ty_imported/ty_generic)
  - [x] Specialization cache + inline monomorphization
  - [x] Cross-module generic structs (imported module AST search)
  - [x] Cross-module struct constructors (expr_member_access)
  - [x] Result[T,E] field types from concrete args
  - [x] expr_specialization as value expression (Option.none)
  - [x] Cycle detection (spec_in_progress)
  - [x] Cross-module struct constructors in monomorphized bodies
        (`struct_exists_in_imports` — 29 LOC in lowering.mt)
- [ ] Phase 5 — dyn, str_buffer, format (remaining 2/7) [see §5 for completed items]
  - [x] proc closures (non-capturing + capturing + fn→proc coercion + indirect calls)
  - [x] fn pointer types (c_fn_ptr_declarator, c_type/c_declaration ty_function)
  - [x] method dispatch + extending block lowering (MethodInfo, resolve_method_info)
  - [x] is + match-expressions (lower_match_expression_local, enum + variant)
  - [ ] dyn[I] interfaces — vtable, fat pointer, adapt
  - [ ] str_buffer[N] — type decl + append/assign/as_str
  - [ ] format strings — f"..." desugaring + format-value lowering
- [ ] Phase 6 — events, async, parallel, compile-time
- [ ] Phase 7 — build parity + self-host bootstrap

---

## 5. Next session context

### Phase 5 status

**Completed (5 of 7):**

| # | Item | Key implementation |
|---|------|-------------------|
| 1 | proc closures | `lower_proc_expression`, `build_env_setup_fn`, `build_capturing_invoke`/`release`/`retain`, `lower_fn_to_proc` (fn→proc coercion), `is_proc_type`, `proc_ensure_struct_decl`, `lower_proc_call` via `expr_call_indirect` |
| 2 | fn pointer types | `c_fn_ptr_declarator`, `resolve_function_type_ref`, `ty_function` in `c_type`/`c_declaration` |
| 4 | method dispatch | `lower_extending_block`, `resolve_method_info`, `lower_method_resolved` (pointer/value/static receiver), `MethodInfo` struct |
| 7 | is/match-expr | `lower_match_expression_local`, `lower_enum_match_expr`, `lower_variant_match_expr` |

**Remaining (2 of 7):**

| # | Item | Est. LOC | Ruby ref | Notes |
|---|------|----------|----------|-------|
| 3 | dyn[I] interfaces | ~200 | `dyn.rb` 233 | Vtable struct + fat pointer + `adapt` |
| 5 | str_buffer[N] | ~150 | `str_buffer.rb` 115 | Type decl + runtime helpers for clear/assign/append/as_str |
| 6 | format strings | ~250 | `format.rb` | `f"..."` desugaring + per-field-type `format_value[T]` dispatch |

### Recommended resume order

1. **Split lowering file** — `lowering.mt` is 3,750 LOC. Extract `proc`, `dyn`, `str_buffer`, and `format` into separate modules under `src/mtc/lowering/` per the self-host plan. This should happen before adding more features to keep the codebase manageable.
2. **dyn[I] interfaces** — requires method dispatch (done) + proc infrastructure (done). The hardest remaining item.
3. **str_buffer[N]** — type decl emission + runtime C helpers. More self-contained.
4. **Format strings** — depends on method dispatch (done) for `format_value[T]` resolution.

### Key context for resume

- **IR additions**: `expr_call_indirect(callee: ptr[Expr], arguments: span[Expr], ty: types.Type)` added for function-pointer calls through proc `invoke` fields.
- **Proc type system**: `proc_type_name_from_signature` produces shared type names like `mt_proc_int_int`. `proc_ensure_struct_decl` registers struct declarations in `pending_env_structs`. Multiple procs with the same signature share the same struct type.
- **Proc call path**: `is_proc_type` checks `ty_named` with `__proc_` or `mt_proc_` prefix AND `ty_function`. `lower_proc_call` uses `expr_call_indirect` through `p.invoke` field.
- **fn→proc coercion**: `lower_expr` → `expr_identifier` → when function reference detected, wraps in proc struct via `lower_fn_to_proc` with synthetic invoke.
- **Debugging**: Use `std.log` (unbuffered stderr) for traces. File-based debug (`std.fs.write_text`) as fallback.
- **Lowering cleanup**: 142 lines of dead code removed (old `wrap_fn_in_proc` path). Comment placement fixed for `function_return_type`.

---

## 6. Cross-cutting principles

- **IR is the frozen seam.** Backend reads only `IR`; Lowering reads only `Analysis`.
- **Byte-identical C as the correctness oracle.**
- **Mirror Ruby's file split**, never grow monoliths.
- **Fail loud on substrate gaps** (`LoweringError` on `ty_error` for emittable nodes).
- **Sandbox every built binary** (`timeout` + `ulimit -v`).

---

## 7. Risks

| Risk | Phase | LOC | Notes |
|------|-------|-----|-------|
| Method dispatch table | 5 | ~400 | Generic method receivers |
| Async state-machine | 6 | ~2,834 | Second-hardest module |
| Analyzer permissiveness | all | ongoing | Hidden long pole |
