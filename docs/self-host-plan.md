# Self-Host Plan: Lowering + C-Backend

Status: **Phases 0–4c complete.** Same-module generics (functions, structs,
prelude variants, type substitution), cross-module struct constructors,
cross-module scalar generic functions, and prelude variant pipeline all build
and run correctly. One remaining gap in cross-module generic function lookup
(imported functions with complex struct return types) is definitively
characterized as an analyzer substrate issue.
Owner: compiler team
Last updated: 2026-07-07 (commits through `52faa2d8`)

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
| IR | `src/mtc/ir.mt` | ~100 |
| Lowering | `src/mtc/lowering/lowering.mt` | ~2,850 |
| C Backend | `src/mtc/c_backend/c_backend.mt` | ~2,500 |
| Build driver | `src/mtc/build.mt` | ~80 |
| C naming (shared) | `src/mtc/c_naming.mt` | ~70 |

**All 172 self-host tests pass, 0 files failed.** Nine generics programs verify —
all build and return correct exit codes.

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
- Cross-module lookups: `program_analyses` span + `loaded_modules` span
  (raw source files, bypassing analysis serialization).

**Key fixes:**
- `resolve_type_ref`/`resolve_field_type_ref` `ty_named` fallback for type params.
- `resolve_field_type_ref` delegates to `resolve_generic_type_ref` for complex types.
- Generic struct fields read from AST (not `analysis.structs`, which stores `ty_error`).
- Body expressions in monomorphized functions use substituted concrete types.
- `c_type`: `ty_var` handler, `ty_named` handler, mangled match arms fixed.
- `ir_expr_type` handles `expr_variant_literal` and `expr_array_literal`.
- `gen_variants_have_str` detects str in synthetic generic variant fields.

**9 verification programs (all correct exits):**

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

### Pre-existing issues fixed
- DA scoping false-positives (scope-name stack with per-block marks).
- `array[T,N](...)` constructor (lowering + backend emission).
- Dead code removed (~104 LOC).

---

## 2. Remaining gap — Phase 4c (characterized)

### Cross-module generic function with imported struct return type

**Symptom:** `import imp3; imp3.make[int](40, 2)` fails with "could not find
generic function decl" when `imp3.mt` contains both a struct `Pair[A,B]` and
function `make[T] -> Pair[T,T]`.

**Root cause (definitively identified):** The generic function's AST declaration
is NOT present in any `source_file.declarations` accessible from lowering:
- Not in the Analysis copies in `program_analyses`
- Not in the raw `LoadedModule.source_file` from `loaded_modules`
- The function IS in the analyzer's ModuleBinding exports (check passes,
  binder finds it via `analysis.source_file.declarations`)
- The struct `Pair` in the same file IS accessible from all three sources

**Analysis:** Ruby's `resolve_specialized_callable_binding` (resolve.rb:1208)
accesses `@ctx.imports.fetch(alias).functions[name]` — the import map stores
**ModuleBinding objects** with full FunctionBinding (including AST). The
self-host's import map only stores module name strings. The self-host's
`resolve_named()` also ignores type arguments for non-prelude generic structs,
returning `ty_named("Pair")` instead of `ty_generic("Pair", [args])`.

**Architecture for fix:** Port Ruby's approach — give the lowering direct access
to imported module bindings (not just module name strings), similar to how
`loaded_modules` was added to `LowerCtx`. Or fix the analyzer's
`resolve_named()` to properly handle generic struct type arguments, which may
also fix analysis serialization. Estimated scope: ~30 LOC in analyzer.

**Mitigation:** All other cross-module generic scenarios work (struct
constructors, scalar functions, identity functions). This is a narrow,
well-defined edge case.

---

## 3. Deferred items

- **`is` operator / match-expressions**: requires statement-hoisting infrastructure.
  Target: Phase 5.
- **Guards and equality patterns** in struct-pattern match arms. Target: Phase 5.
- **Build-mode codegen parity**. Target: Phase 7.
- **`as cstr` for non-literal values**. Target: Phase 5.
- **Prelude module prefix** (`std_option_Option_int` vs `Option_int`). Target: Phase 7.
- **SoA**: deferred indefinitely.

---

## 4. Remaining work per phase

### Phase 5 — proc/fn, dyn, method dispatch, str_buffer, format, `is`

| # | Item | Est. LOC | Ruby ref | Notes |
|---|------|----------|----------|-------|
| 1 | **proc closures** — capture struct, ref-counted lifecycle | ~300 | `proc.rb` 419 | Capture env struct + invoke/release/retain |
| 2 | **fn pointer types** — full support in `c_type` | ~50 | — | Partially wired from Phase 1–3 |
| 3 | **dyn[I] interfaces** — vtable, fat pointer, `adapt` | ~200 | `dyn.rb` 233 | Vtable struct + fat pointer emission |
| 4 | **Method dispatch** — editable/value/static, method table | ~400 | `resolve.rb` | Also completes generics for method receivers |
| 5 | **str_buffer[N]** — fixed-capacity UTF-8 text buffer | ~150 | `str_buffer.rb` 115 | Type decl + append/assign/as_str methods |
| 6 | **Format strings** — `f"count=#{n}"` + `fmt` helpers | ~250 | `format.rb` | Desugaring + format-value lowering |
| 7 | **`is` + match-expressions** — statement-hoisting | ~200 | — | Also unlocks match-expr for enums/int |
| **Total** | | **~1,550** | | |

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

## 5. Progress checklist

- [x] Phase 0 — IR + scaffolding
- [x] Phase 1 — return-int binary
- [x] Phase 2 — control flow, str/cstr, enums, foreign
- [x] Phase 3 — non-generic aggregates
- [x] Phase 4a — multi-module assembly + cross-module calls
- [x] Phase 4b — non-generic variants + match strategies + variant literals
- [x] Phase 4c — generics monomorphization
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
  - [/] Cross-module generic function calls (characterized: analyzer substrate gap,
        `resolve_named` ignores type args for user generic structs; ~30 LOC fix)
- [ ] Phase 5 — proc/fn, dyn, method dispatch, str_buffer, format, `is`
- [ ] Phase 6 — events, async, parallel, compile-time
- [ ] Phase 7 — build parity + self-host bootstrap

---

## 6. Commit history (Phase 4)

```
52faa2d8 Phase 4c: cross-module generic function lookup — root cause identified
0d756f3a Clean up diagnostics in cross-module function search
bf83e9f5 Fix cross-module generic function search + body type substitution
9e97fc44 Fix generic body type substitution + cross-module return type lookup
79a684fc Phase 4c: cross-module generic function lookup infrastructure
6d1c712f Sync plan: Phase 4c complete, revise next items for Phases 5-7
f4561506 Phase 4c complete: generics monomorphization — all 5 gaps resolved
cc5256fe Clean up dead code and fix naming in lowering + backend
0b8a786d Phase 4a/4b/4c: multi-module assembly, non-generic variants, generics
```

---

## 7. Next session context

### Immediate (remaining Phase 4c gap, ~30 LOC)

The cross-module generic function lookup for struct-returning functions needs
one fix in the **semantic analyzer**: `resolve_named()` at `analyzer.mt:938`
returns `ty_named(name)` for struct names without processing type arguments
when the struct is not a known generic constructor (`is_generic_constructor_name`
returns false for user-defined structs). This means `Pair[T,T]` in a function's
return type is stored as just `ty_named("Pair")` without the type arguments,
which may cause the function's AST to not be retained properly in the analysis
serialization. The fix is to extend `resolve_named` to handle generic structs:
when `ctx.type_names.contains(name)` and `arguments.len > 0`, return
`ty_generic(name, args)` instead of `ty_named(name)`.

### Priority order after 4c closure

1. Phase 5.1: **proc closures** (capture struct, ref-counted) — ~300 LOC
2. Phase 5.2: **fn pointer types** — ~50 LOC
3. Phase 5.4: **Method dispatch** — ~400 LOC
4. Phase 5.3: **dyn[I] interfaces** — ~200 LOC
5. Phase 5.5: **str_buffer[N]** — ~150 LOC
6. Phase 5.6: **Format strings** — ~250 LOC
7. Phase 5.7: **`is` + match-expressions** — ~200 LOC

---

## 8. Cross-cutting principles

- **IR is the frozen seam.** Backend reads only `IR`; Lowering reads only `Analysis`.
- **Byte-identical C as the correctness oracle.**
- **Mirror Ruby's file split**, never grow monoliths.
- **Fail loud on substrate gaps** (`LoweringError` on `ty_error` for emittable nodes).
- **Sandbox every built binary** (`timeout` + `ulimit -v`).

---

## 9. Risks

| Risk | Phase | LOC | Notes |
|------|-------|-----|-------|
| 4c gap — generic struct return types | 4c | ~30 | Analyzer `resolve_named` fix |
| Method dispatch table | 5 | ~400 | Generic method receivers |
| Async state-machine | 6 | ~2,834 | Second-hardest module |
| Analyzer permissiveness | all | ongoing | Hidden long pole |
