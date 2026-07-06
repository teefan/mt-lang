# Self-Host Plan: Lowering + C-Backend

Status: **Phases 0–4c complete** — same-module and cross-module generics
(generic functions, generic structs, prelude variants with arbitrary concrete
types, cross-module struct constructors, `expr_specialization` as value
expression, cycle detection). 6 verification programs build and run correctly;
172/172 self-host tests pass.
Owner: compiler team
Last updated: 2026-07-07 (commits through `f4561506`)

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

Self-host source layout (src ≈ 20.9k LOC):

| Stage | Path | LOC |
|-------|------|-----|
| Lexer | `src/mtc/lexer/` | ~1,600 |
| Parser + AST | `src/mtc/parser/*.mt` | ~4,700 |
| Pretty printers | `src/mtc/pretty_printer/*.mt` | ~2,000 |
| Semantic analyzer | `src/mtc/semantic/*.mt` | ~5,000 |
| Loader | `src/mtc/loader/*.mt` | ~700 |
| IR | `src/mtc/ir.mt` | ~100 |
| Lowering | `src/mtc/lowering/lowering.mt` | ~2,800 |
| C Backend | `src/mtc/c_backend/c_backend.mt` | ~2,500 |
| Build driver | `src/mtc/build.mt` | ~80 |
| C naming (shared) | `src/mtc/c_naming.mt` | ~70 |

**All 172 self-host tests pass, 0 files failed.** Six generics programs verify
across the full Phase 4c surface — all build and return correct exit codes.

---

## 1. What is complete

### Phase 0 — IR + scaffolding
- `ir.mt`, `ir_formatter.mt`, CLI stubs.

### Phase 1 — First binary
- Scalar lowering + C backend. Byte-identical to Ruby on 8 programs.

### Phase 2 — Control flow, str/cstr, enums, foreign
- if/else/while/for, `mt_str`, enums/flags + switch, foreign/external calls.

### Phase 3 — Non-generic aggregates
- Structs, unions, arrays, spans, tuples. Reachability pruning. Byte-identical to
  Ruby on 11 programs.

### Phase 4a — Multi-module assembly
- `lower()` concatenates all non-external modules in dependency-first order.
- Cross-module calls via `analysis.imports` + shared `program_returns`.

### Phase 4b — Non-generic variants
- Variant declarations, arm constructors, switch + if/goto match strategies,
  field destructure, dead-code elimination, compound-literal casts.
  Byte-identical to Ruby on 3 variant programs.

### Phase 4c — Generics monomorphization (complete)

All five planned gaps resolved:

| # | Item | Verified |
|---|------|----------|
| 0 | Cross-module lookup infrastructure (`program_analyses` + `find_imported_analysis`) | — |
| 1 | Cross-module generic struct emission (imported module AST search) | `lib.Pair[int,int](...)` exit=42 |
| 2 | Imported struct constructor (`expr_member_access` in `lower_specialization_call`) | `lib.Pair[int,int](...)` exit=42 |
| 3 | Result[T,E] field types from concrete type args | `Result[int,str]` exit=7 |
| 4 | `expr_specialization` as value expression (`Option[int].none`) | `Option[int].none` exit=42 |
| 5 | Cycle detection (`spec_in_progress` set) | — |

**6 verification programs (all correct exits):**

```
id[T]             → exit=42 (identity generic)
Pair[A,B]+first[T] → exit=42 (generic struct + function)
Option[int]        → exit=42 (prelude variant + match)
lib.Pair[int,int]  → exit=42 (cross-module struct constructor)
Result[int,str]    → exit=7  (non-int error type)
Option[int].none   → exit=42 (generic no-payload variant)
```

**Architecture:**
- **Inline monomorphization** (`lower_specialization_call` →
  `lower_monomorphized_call` → `lower_and_cache_specialization`).
- Cached in `specialization_cache`; entries pushed to program functions.
- Generic struct decls by lowering (AST field types + `substitute_type_params`).
- Cross-module lookups via `program_analyses` span + `find_imported_analysis`.
- Cycle detection via `spec_in_progress` guard in `lower_and_cache_specialization`.
- `prelude_variant_arm_info` parameterized with concrete type args.

**Key fixes in this phase:**
- `resolve_type_ref`/`resolve_field_type_ref` `ty_named` fallback for type params.
- `resolve_field_type_ref` delegates to `resolve_generic_type_ref` for complex types.
- Generic struct fields read from AST (not `analysis.structs`, which stores `ty_error`).
- `c_type`: `ty_var` handler, `ty_named` handler, mangled match arms fixed.
- `ir_expr_type`: added `expr_variant_literal` and `expr_array_literal` cases.
- `gen_variants_have_str` detects str in synthetic generic variant fields.

### Pre-existing issues fixed
- DA scoping false-positives (scope-name stack with per-block marks).
- `array[T,N](...)` constructor (lowering + backend emission).
- Dead code removed (~104 LOC across lowering + backend).

---

## 2. Deferred items

- **`is` operator / match-expressions**: requires statement-hoisting infrastructure.
  Target: Phase 5.
- **Guards and equality patterns** in struct-pattern match arms. Target: Phase 5.
- **Build-mode codegen parity**. Target: Phase 7.
- **`as cstr` for non-literal values**. Target: Phase 5.
- **Prelude module prefix** (`std_option_Option_int` vs `Option_int`). Target: Phase 7.
- **SoA**: deferred indefinitely.
- **Cross-module generic function calls** (`lib.make[int](...)` from imported
  module): infrastructure in place (`find_imported_analysis`, `specialization_key`
  handles `expr_member_access`, `lower_and_cache_specialization` searches imported
  analyses), but the foreign function-lookup path needs one more debugging pass.
  Target: next session (~30 LOC).

---

## 3. Remaining work per phase

### Phase 5 — proc/fn, dyn, method dispatch, str_buffer, format, `is`

| # | Item | Est. LOC | Notes |
|---|------|----------|-------|
| 1 | **proc closures** — capture struct, ref-counted lifecycle | ~300 | Ruby `proc.rb` = 419 LOC |
| 2 | **fn pointer types** — full support in `c_type` | ~50 | Partially wired |
| 3 | **dyn[I] interfaces** — vtable, fat pointer, `adapt` | ~200 | Ruby `dyn.rb` = 233 LOC |
| 4 | **Method dispatch** — editable/value/static, method table | ~400 | Also completes generics for method receivers |
| 5 | **str_buffer[N]** — fixed-capacity UTF-8 text buffer | ~150 | Ruby `str_buffer.rb` = 115 LOC |
| 6 | **Format strings** — `f"count=#{n}"` + `fmt` helpers | ~250 | |
| 7 | **`is` + match-expressions** — statement-hoisting | ~200 | Also unlocks match-expr for enums/int |
| **Total** | | **~1,550** | |

**After Phase 5:** closures, dyn dispatch, format strings, `is` expressions.

### Phase 6 — events, async, parallel, compile-time

| # | Item | Est. LOC | Notes |
|---|------|----------|-------|
| 1 | **Events** — `emit`, `subscribe`, `unsubscribe` | ~600 | Ruby `events.rb` = 1,054 LOC |
| 2 | **Async/await** — state-machine transform | ~2,000 | Highest-risk module after generics |
| 3 | **parallel/detach/gather** — libuv dispatch | ~400 | |
| 4 | **Compile-time** — `const function`, `when`, `inline`, `emit`, reflection | ~800 | Ruby `compile_time/*` + `const_eval.rb` |
| **Total** | | **~3,800** | |

**After Phase 6:** async programs, events, compile-time metaprogramming.

### Phase 7 — Build parity + self-host bootstrap

| # | Item | Notes |
|---|------|-------|
| 1 | Build cache + `--no-cache` / `--keep-c` | |
| 2 | Module roots / package graph | |
| 3 | Platform targets (linux/windows/wasm) | |
| 4 | `--debug-guards` (loop iteration guards) | |
| 5 | `#line` directives in emitted C | |
| 6 | Build-mode include set (`<stdlib.h>`, `mt_fatal` always-on) | |
| 7 | Prelude module prefix (`std_option_` names) | |
| 8 | **Milestone: `mtc build projects/mtc`** — self-host compiles itself | |

---

## 4. Cross-cutting principles

- **IR is the frozen seam.** Backend reads only `IR`; Lowering reads only `Analysis`.
- **Byte-identical C as the correctness oracle.**
- **Mirror Ruby's file split**, never grow monoliths.
- **Fail loud on substrate gaps** (`LoweringError` on `ty_error` for emittable nodes).
- **Sandbox every built binary** (`timeout` + `ulimit -v`).

---

## 5. Risks

| Risk | Phase | LOC | Notes |
|------|-------|-----|-------|
| Method dispatch table | 5 | ~400 | Generic method receivers |
| Async state-machine | 6 | ~2,834 | Second-hardest module after generics |
| Analyzer permissiveness | all | ongoing | Hidden long pole |

---

## 6. Progress checklist

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
  - [ ] Cross-module generic function calls (imported function lookup — needs one debugging pass)
- [ ] Phase 5 — proc/fn, dyn, method dispatch, str_buffer, format, `is`
- [ ] Phase 6 — events, async, parallel, compile-time
- [ ] Phase 7 — build parity + self-host bootstrap

## 7. Commit history (Phase 4c)

```
f4561506 Phase 4c complete: generics monomorphization — all 5 gaps resolved
cc5256fe Clean up dead code and fix naming in lowering + backend
0b8a786d Phase 4a/4b/4c partial: multi-module assembly, non-generic variants, generics monomorphization
```
