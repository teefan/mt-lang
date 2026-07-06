# Self-Host Plan: Lowering + C-Backend

Status: **Phases 0–3 complete; 4a (multi-module assembly) + 4b (non-generic
variants) complete; 4c (generics) partial — same-module generic functions,
generic structs, and prelude variants build and run correctly; cross-module
generics and full monomorphization worklist remain.**
Owner: compiler team
Last updated: 2026-07-07 (commit `0b8a786d`)

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

Self-host source layout (src ≈ 20.7k LOC):

| Stage | Path | LOC |
|-------|------|-----|
| Lexer | `src/mtc/lexer/` | ~1,600 |
| Parser + AST | `src/mtc/parser/*.mt` | ~4,700 |
| Pretty printers | `src/mtc/pretty_printer/*.mt` | ~2,000 |
| Semantic analyzer | `src/mtc/semantic/*.mt` | ~5,000 |
| Loader | `src/mtc/loader/*.mt` | ~700 |
| IR | `src/mtc/ir.mt` | ~100 |
| Lowering | `src/mtc/lowering/lowering.mt` | ~2,700 |
| C Backend | `src/mtc/c_backend/c_backend.mt` | ~2,500 |
| Build driver | `src/mtc/build.mt` | ~80 |
| C naming (shared) | `src/mtc/c_naming.mt` | ~70 |

**All 172 self-host tests pass, 0 files failed.** Three generics programs
verify: `id[T]` (identity), `Pair[A,B]` (generic struct + function), and
`Option[int]` (prelude variant with match) all build and return 42.

---

## 1. What is complete

### Phase 0 — IR + scaffolding
- `ir.mt`, `ir_formatter.mt`, CLI stubs. Program retains analyses in dependency order.

### Phase 1 — First binary
- Scalar lowering + C backend. Byte-identical to Ruby on 8 programs.

### Phase 2 — Control flow, str/cstr, enums, foreign functions
- if/else/while/for, str literals + `mt_str` type, enums/flags + switch, foreign/external calls. Byte-identical to Ruby.

### Phase 3 — Non-generic aggregates
- Structs, unions, arrays, spans, tuples. Reachability pruning. Byte-identical to Ruby on 11 programs.

### Phase 4a — Multi-module assembly
- `Lowering.lower` concatenates all non-external modules in dependency-first order.
- Cross-module calls (`mod.func(...)`) via `analysis.imports` + shared `program_returns`.
- Un-annotated local types prefer IR type (correct cross-module qual).

### Phase 4b — Non-generic variants
- Variant declarations, arm constructors (no-payload + payload).
- Match lowering: **switch** for member/`as name`/wildcard arms; **if/goto chain**
  for struct-pattern arms (payload temp, field destructure, `as name` binding).
- Backend: `emit_variant` (payload structs, kind enum, data union, tagged struct).
- Dead-code elimination (`used_labels` set, goto-after-terminator skip).
- Supporting: `aggregates_use_str`, compound-literal payload casts, `goto`/`label`
  statement emission. 3 variant programs byte-identical to Ruby.

### Phase 4c partial — Generics

**What works (same-module):**

| Feature | Verified |
|---------|----------|
| Generic function monomorphization (`id[T](x: T) → T` called as `id[int](42)`) | Builds, exit=42 |
| Generic struct constructors (`Pair[int, int](first=42, second=0)`) | Builds, exit=42 |
| Generic struct + generic function (`Pair[A,B]` + `first[T]`) | Builds, exit=42 |
| Prelude variant pipeline (`Option[int].some(...)` + match) | Builds, exit=42 |
| Type substitution (`substitute_type_params`: `ty_var`/`ty_named`/`ty_imported`/`ty_generic`) | ✓ |
| Specialization cache (`specialization_cache` map, keyed by C linkage name) | ✓ |
| Concrete struct IR emission (AST field types with substitution) | ✓ |

**Architecture:**
- **Inline monomorphization**: generic calls are lowered immediately on encounter
  (`lower_specialization_call` → `lower_monomorphized_call` → `lower_and_cache_specialization`).
- Cached in `specialization_cache`; entries pushed to program functions at end of
  `lower_module` via `values()` iteration.
- Generic struct decls emitted by lowering (`ensure_generic_struct_decl` reads AST
  field types directly, applies `substitute_type_params`). Backend's
  `collect_generic_variants` filtered to prelude types only.
- `resolve_field_type_ref` delegates to `resolve_generic_type_ref` for complex
  types; `resolve_type_ref` has `ty_named` fallback for type params.

**Key fixes in this phase:**
- `resolve_type_ref`/`resolve_field_type_ref` returned `ty_error` for type param
  names (not in `type_names`). Fixed with `ty_named(name)` fallback.
- `resolve_field_type_ref` returned `ty_error` for types with generic arguments
  (`Pair[T, int]`). Fixed by delegating to `resolve_generic_type_ref`.
- `analysis.structs` stored `ty_error` for generic struct fields (analyzer's
  `collect_struct_fields` resolves before type param scope is active). Fixed by
  reading fields from AST declarations directly.
- `c_type` had no `ty_var` handler. Added as defensive fallback.
- `c_type` match arms were mangled (duplicate fatal, swapped `ty_tuple` return).
  Fixed.
- `ir_expr_type` missing `expr_variant_literal` and `expr_array_literal` cases.
  Fixed.

### Pre-existing issues fixed
- **DA scoping false-positives**: scope-name stack with per-block marks.
- **`array[T,N](...)` constructor**: lowering + backend emission.

---

## 2. Deferred items (phased)

- **`is` operator / match-expressions**: requires statement-hoisting infrastructure
  (also affects enum/int match-expr from Phase 2). Target: Phase 5+.
- **Guards and equality patterns** in struct-pattern match arms. Not exercised by
  any test or stdlib. Target: Phase 5.
- **Build-mode codegen parity** (`<stdlib.h>`, `mt_fatal`, `#line`). Target: Phase 7.
- **`as cstr` for non-literal values**: runtime str→cstr helper. Target: Phase 5.
- **Prelude module prefix** (`std_option_Option_int` vs `Option_int`): cosmetic;
  self-host uses bare type-arg-inclusive names. Target: Phase 7.
- **SoA**: deferred indefinitely.

---

## 3. Remaining work per phase

### Phase 4c — Generics monomorphization (remaining)

1. **Cross-module generics** — `Vec[T]` from `std/vec.mt` instantiated for
   `T = int`. Requires: find the generic function in the imported module's
   `analysis`, build substitution from the call site's type args, lower the
   monomorphized copy, and append to the calling module's output. The
   `specialization_cache` and `substitute_type_params` already handle type
   substitution; the gap is function-lookup across modules.
   - **Estimated scope:** ~150 LOC in `lower_and_cache_specialization` (accept
     foreign analysis + function AST).

2. **Generic struct emission from imported modules** — `Pair[int, int]` from an
   imported module (`import lib; ... lib.Pair[int, int](...)`). The concrete
   struct `lib_Pair_int_int` must come from the imported module's AST. Currently
   `ensure_generic_struct_decl` only searches `ctx.analysis.source_file`.
   - **Estimated scope:** ~80 LOC (extend search to imported module analyses).

3. **Full worklist convergence** — currently the inline specialization lowers
   each call as encountered. If a monomorphized function's body contains further
   generic calls (e.g., `Vec[T].push()` inside `Vec[T].append_span()`), those
   inner calls must also be monomorphized. A proper worklist iterates until
   convergence.
   - **Estimated scope:** ~100 LOC (pending queue + iterative processing).

4. **Result[T, E] with non-int E types** — currently `prelude_variant_arm_info`
   hardcodes `ty_primitive("int")` for the `value` and `error` fields of
   Result. The field types should come from the concrete type args (T → value
   type, E → error type). This affects variant declaration emission and field
   types in match bindings.
   - **Estimated scope:** ~60 LOC (parameterize prelude_variant_arm_info).

5. **`expr_specialization` as value expression** — `Option[int].none` (without
   call) should resolve to a variant literal with correct type. Currently
   `lower_expr` fatals on `expr_specialization`.
   - **Estimated scope:** ~40 LOC (add handler in `lower_expr`).

**After Phase 4c:** self-host can compile programs using `Vec[int]`,
`Map[int, int]`, and other generic std collections with int/str key types.

### Phase 5 — proc/fn closures, dyn interfaces, method dispatch, str_buffer, format strings

1. **proc closures** — capture environment, ref-counted lifecycle. Ruby
   `proc.rb` = 419 LOC. Emit capture struct + invoke/release/retain functions.
   - **Estimated scope:** ~300 LOC (lowering + backend).

2. **fn pointer types** — function pointers as values, stored in structs,
   passed as args. Already partially handled (fn→proc coercion, fn struct
   fields from Phase 1–3). Remaining: full fn type support in `c_type`.
   - **Estimated scope:** ~50 LOC.

3. **dyn[I] interfaces** — vtable, fat pointer, `adapt[I](value)` builtin.
   Ruby `dyn.rb` = 233 LOC.
   - **Estimated scope:** ~200 LOC.

4. **Method dispatch** — generic method calls on receivers (editable/value/
   static). Requires building a method-definition table (`@method_definitions`
   in Ruby). This also completes generics for method receivers.
   - **Estimated scope:** ~400 LOC (method table + dispatch in lowering).

5. **str_buffer[N]** — fixed-capacity UTF-8 text buffer type with `append`,
   `assign`, `as_str`, etc. Ruby `str_buffer.rb` = 115 LOC.
   - **Estimated scope:** ~150 LOC.

6. **Format strings** — `f"count=#{n}"` desugaring + `fmt` helpers.
   - **Estimated scope:** ~250 LOC.

7. **`is` operator + match-expressions** — statement-hoisting infrastructure
   needed. Also unlocks match-expr for enums/integers. Deferred from Phase 4b.
   - **Estimated scope:** ~200 LOC.

**After Phase 5:** self-host can compile closures, dyn dispatch, format strings,
and `is` expressions.

### Phase 6 — events, async/await, parallel/detach/gather, compile-time

1. **Events** — event declaration, `emit`, `subscribe`, `unsubscribe`. Ruby
   `events.rb` = 1,054 LOC.
   - **Estimated scope:** ~600 LOC.

2. **Async/await** — state-machine transform. Ruby `async/*` = 2,834 LOC total
   (analysis + normalization + lowering). This is the second-highest risk module
   after generics.
   - **Estimated scope:** ~2,000 LOC.

3. **parallel for / parallel: / detach/gather** — libuv thread dispatch.
   - **Estimated scope:** ~400 LOC.

4. **Compile-time evaluation** — `const function`, `when`, `inline for/while/
   if/match`, `emit`, reflection builtins (`fields_of`, `size_of`, etc.).
   Ruby `compile_time/*` + `const_eval.rb`.
   - **Estimated scope:** ~800 LOC.

**After Phase 6:** self-host can compile async programs, events, compile-time
metaprogramming.

### Phase 7 — Build parity + self-host bootstrap

1. **Build cache** + `--no-cache` / `--keep-c`.
2. **Module roots / package graph** resolution (`--root`, `package.toml`).
3. **Platform targets** (linux/windows/wasm).
4. **`--debug-guards`** (loop iteration guards).
5. **`#line` directives** in emitted C.
6. **Build-mode include set** (`<stdlib.h>`, `mt_fatal` always-on).
7. **Prelude module prefix** (`std_option_` names).
8. **Milestone: `mtc build projects/mtc`** — the self-host compiles itself.

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
| Generics monomorphization (remaining) | 4c | ~400 | Cross-module + worklist convergence |
| Method dispatch table | 5 | ~400 | Generic method receivers |
| Async state-machine | 6 | ~2,834 | Second-hardest module |
| Analyzer permissiveness | all | ongoing | Hidden long pole |

---

## 6. Progress checklist

- [x] Phase 0 — IR + scaffolding
- [x] Phase 1 — return-int binary
- [x] Phase 2 — control flow, str/cstr, enums, foreign
- [x] Phase 3 — non-generic aggregates
- [x] Phase 4a — multi-module assembly + cross-module calls
- [x] Phase 4b — non-generic variants + match strategies + variant literals
- [/] Phase 4c — generics monomorphization
  - [x] Same-module generic functions (identity, struct methods)
  - [x] Same-module generic structs (constructors, concrete IR)
  - [x] Prelude variant pipeline (Option/Result constructors, match, decls)
  - [x] Type substitution infrastructure (ty_var/ty_named/ty_imported/ty_generic)
  - [x] Specialization cache + inline monomorphization
  - [ ] Cross-module generic functions (Vec[T] from std)
  - [ ] Generic struct emission from imported modules
  - [ ] Full worklist convergence
  - [ ] Result[T,E] with non-int error types
  - [ ] `expr_specialization` as value expression (Option.none without call)
- [ ] Phase 5 — proc/fn, dyn, method dispatch, str_buffer, format, `is`
- [ ] Phase 6 — events, async, parallel, compile-time
- [ ] Phase 7 — build parity + self-host bootstrap
