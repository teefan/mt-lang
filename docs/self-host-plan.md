# Self-Host Plan: Lowering + C-Backend

Status: **Phases 0–3 complete; Phases 4a–4b complete; Phase 4c partial (prelude
generic-variant pipeline: constructors, literals, match, declarations — builds
and runs correctly; Option[int] programs produce correct exit codes).** Remaining
in 4c: full generics monomorphization (specialization worklist, type substitution,
caching — Ruby `resolve.rb` = 2,511 LOC). Then: closures, dyn, format, async,
compile-time, build parity, self-host bootstrap.
Owner: compiler team
Last updated: 2026-07-07

This document is the durable, cross-session plan for extending the self-hosted
Milk Tea compiler (`mtc`, `projects/mtc/`) from a front-end-only checker into a
full compiler that emits C and produces a binary — ultimately compiling itself.

Guiding constraint: **follow the Ruby reference compiler (`lib/milk_tea/core/`)
architecture, algorithms, and file decomposition as closely as possible.** It is
proven and well-tested. Each compiler stage must stay decoupled, self-contained,
and isolated behind a stable data contract.

---

## 1. Current state

`mtc` implements a self-hosted compiler that **lexes, parses, type-checks, lowers,
emits C, and builds native binaries**. The front-end (lexer through module loader)
pre-existed; the middle- and back-end (lowering through C emission + `cc` build
driver) were added in Phases 0–4b of this plan, with Phase 4c partially complete.

Pipeline as wired in `projects/mtc/src/mtc/main.mt`:

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

Self-host source layout (src ≈ 20.3k LOC):

| Stage | Path | LOC (approx) |
|-------|------|---------------|
| Lexer | `src/mtc/lexer/` | ~1,600 |
| Parser + AST | `src/mtc/parser/*.mt` | ~4,700 |
| Pretty printers | `src/mtc/pretty_printer/*.mt` | ~2,000 |
| Semantic analyzer | `src/mtc/semantic/*.mt` | ~5,000 |
| Loader | `src/mtc/loader/*.mt` | ~700 |
| IR | `src/mtc/ir.mt` | ~100 |
| Lowering | `src/mtc/lowering/lowering.mt` | ~2,300 |
| C Backend | `src/mtc/c_backend/c_backend.mt` | ~2,400 |
| Build driver | `src/mtc/build.mt` | ~80 |
| C naming (shared) | `src/mtc/c_naming.mt` | ~70 |

**All 172 self-host tests pass, 0 files failed.**

### Pre-existing issues fixed

- **DA scoping false-positives** — scope-aware pass with per-block marks.
- **`array[T,N](...)` constructor** — lowering + backend emission.
- **`c_type` mangled match arms** — duplicate fatal; `ty_named` missing handler.

### Deferred to later work

- **`is` operator / match-expressions** — requires statement-hoisting infrastructure
  (also affects enum/int match-expr from Phase 2). Target: Phase 5+.
- **Guards and equality patterns** in struct-pattern match arms — not exercised by
  any test or stdlib code. Target: Phase 5.
- **Build-mode codegen parity** (`<stdlib.h>`, `mt_fatal`, `#line`). Target: Phase 7.
- **`as cstr` for non-literal values** — runtime str→cstr helper. Target: Phase 5.
- **Prelude module prefix** (`std_option_Option_int` vs `Option_int`) — cosmetic;
  self-host uses bare type-arg-inclusive names (`Option_int`, `Option_int_some`,
  `Option_int_kind_some`); functionally correct. Target: Phase 7.
- **SoA** — deferred indefinitely.

---

## 2. Prerequisite substrate gaps

1. **Analyzer permissiveness** — `ty_error` fallback; each phase requires matching
   analyzer hardening.
2. **No binding layer** — AST-driven approach works through 4b; may be needed for
   full monomorphization.

---

## 3. Phased plan

### Phase 0–3 — IR, scalars, control flow, aggregates

- [x] **Done.** All byte-identical to Ruby on 11 differential programs.

### Phase 4a — Multi-module assembly

- [x] **Done.** Cross-module calls via `program_returns` map.

### Phase 4b — Non-generic variants

- [x] **Done.** Variant decls, arm constructors, switch + if/goto match strategies,
  field destructure bindings, dead-code elimination, compound-literal casts,
  `goto`/`label` emission. 3 variant programs byte-identical to Ruby.

### Phase 4c — Prelude generic-variant pipeline (done)

The prelude types `Option[T]` and `Result[T,E]` are synthetic — they're registered
internally by the analyzer but have no AST `decl_variant` nodes. The lowering and
backend now handle them through a generic-variant path distinct from non-generic
variants.

- **Variant registry** — `install_prelude_variants` registers `Option`/`Result`
  with arm payload structures (field names via `sp_str`/`sp_str_type` placeholders).
- **Generic variant constructors** — `Option[int].some(value=42)` → `lower_generic_
  variant_literal` → IR `expr_variant_literal(ty=ty_generic(...))`.
- **Consistent C naming** — `variant_base_c_name(scrutinee_ty, module)` produces
  type-arg-inclusive names (`Option_int`, `Option_int_some`, `Option_int_kind_some`)
  for discriminants, arm types, and declarations.
- **Match dispatch** — `generic_variant_name` extracts the base name from
  `ty_generic`; `lower_variant_match` routes through switch or if/goto strategies.
- **Variant type declarations** — `collect_generic_variants` scans the lowered IR
  for used concrete specializations and emits synthetic `ir.VariantDecl` nodes
  with per-arm payload structs populated from `prelude_variant_arm_info`.
- **IR type pipeline** — `ir_expr_type` handles `expr_variant_literal` +
  `expr_array_literal` (previously fell to `ty_error`).
- **Backend** — `render_variant_initializer` and `c_declaration` handle
  `ty_generic` inline; `generic_c_type` has variant naming fallback.
- **Verified:** `Option[int]` programs with constructors, match-as-binding, and
  build+run produce correct exit codes (e.g., 42). The diff from Ruby is cosmetic
  (bare names vs `std_option_` prefix). 172/172 tests clean.

### Phase 4c — Generics monomorphization (IN PROGRESS, highest risk)

The full generics subsystem (Ruby `resolve.rb` = 2,511 LOC) gates compilation of
all generic std collections (`Vec[T]`, `Map[K,V]`, `String`) and the self-host's
own generic code (`ast.mt`, `semantic/types.mt`).

**Architecture:**
1. **Specialization worklist** — during lowering, collect generic function call
   sites that reference a generic function with concrete type arguments. Each
   unique `(function, concrete_type_args)` pair becomes a specialization key.
   Process the worklist iteratively: for each key, lower a monomorphized copy of
   the generic function body with type parameters substituted by concrete types.
   Monomorphized bodies may themselves contain generic calls → add to worklist.
   Converges when no new specializations are discovered.
2. **Type substitution** — given a generic function's AST body and its declared
   type parameters, produce a lowered body where every reference to a type param
   is replaced by the concrete type. This includes: function signatures, local
   declarations, field types, call targets, aggregate constructors.
3. **Specialization caching** — a `map[specialization_key → lowered_functions]`
   avoids re-lowering. The key encodes the generic function's qualified name +
   concrete type args in canonical order.
4. **Method-definition resolution** — generic bodies that call methods on
   type-param receivers (`this.append(...)`) need the concrete struct's method
   bound at specialization time via `@method_definitions`.
5. **Cross-module generics** — `Vec[T]` in `std/vec.mt` instantiated for
   `T = int` in the calling module; linkage name encodes the specialization.

Substrate check: the analyzer records `FnSig` with type param info and resolves
generic type parameters. The lowering needs:
- A `SpecializationCache` struct in `LowerCtx` (maps key → lowered function IR).
- A `substitute_type_params` helper (replaces type params in `types.Type`).
- A worklist in `lower` that iterates until convergence.

**Remaining (in priority order):**
1. Specialization worklist + cache in `lower()` (collect generic calls; iterate).
2. Type-substitution helper (map type-param names to concrete types).
3. Lower generic function body with substituted types.
4. Cross-module generic function instantiation.
5. Generic struct/variant emission (per-specialization IR decls).

### Phase 5 — proc/fn closures, dyn interfaces, method dispatch, str_buffer, format strings

### Phase 6 — events, async/await, parallel/detach/gather, compile-time

### Phase 7 — Build parity + self-host bootstrap (mtc builds mtc)

---

## 4. Progress checklist

- [x] Phase 0 — IR contract + stage scaffolding + CLI stubs
- [x] Phase 1 — return-int binary end-to-end
- [x] Phase 2 — control flow, str/cstr, enums, foreign functions
- [x] Phase 3 — non-generic aggregates (structs, unions, arrays, spans, tuples)
- [x] Phase 4a — multi-module assembly + cross-module calls
- [x] Phase 4b — non-generic variants + match (switch + if/goto) + variant literals
- [/] Phase 4c — generics/monomorphization
  - [x] Prelude generic-variant pipeline (Option/Result constructors, literals,
        match, declarations — builds and runs correctly)
  - [ ] Specialization worklist + type substitution + caching
  - [ ] Cross-module generic function instantiation (Vec[T], Map[K,V], String)
  - [ ] Generic struct/variant emission per specialization
- [ ] Phase 5 — proc/fn, dyn, method dispatch, str_buffer, format strings
- [ ] Phase 6 — events, async, parallel/detach, compile-time
- [ ] Phase 7 — build parity + self-host bootstrap (mtc builds mtc)

---

## 5. Cross-cutting principles

- **IR is the frozen seam.** Backend reads only `IR`; Lowering reads only
  `Analysis`.
- **Byte-identical C as the correctness oracle.**
- **Mirror Ruby's file split**, never grow monoliths.
- **Fail loud on substrate gaps.**
- **Sandbox every built binary.**
