# Self-Host Plan: Lowering + C-Backend

Status: **Phase 7 — cross-module type system hardened; generic method monomorphization is the next blocker.**
Last updated: 2026-07-07 (P7.5)

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

Self-host source layout (src ≈ 24k LOC):

| Stage | Path | LOC |
|-------|------|-----|
| Lexer | `src/mtc/lexer/` | ~1,600 |
| Parser + AST | `src/mtc/parser/*.mt` | ~4,700 |
| Pretty printers | `src/mtc/pretty_printer/*.mt` | ~2,000 |
| Semantic analyzer | `src/mtc/semantic/analyzer.mt` | ~3,800 |
| Type system | `src/mtc/semantic/types.mt` | ~700 |
| Loader | `src/mtc/loader/` | ~700 |
| IR | `src/mtc/ir.mt` | ~220 |
| Lowering | `src/mtc/lowering/lowering.mt` | ~6,330 |
| C Backend | `src/mtc/c_backend/c_backend.mt` | ~3,100 |
| Build driver | `src/mtc/build.mt` | ~80 |
| C naming (shared) | `src/mtc/c_naming.mt` | ~70 |

**All 172 self-host tests pass (7 known permissiveness failures, 0 regressions).**

---

## 1. What is complete

### Phases 0–3 — Scalars, control flow, aggregates
Byte-identical to Ruby on 11 differential programs.

### Phase 4a — Multi-module assembly
`lower()` concatenates all non-external modules. Cross-module calls via
`analysis.imports` + shared `program_returns`.

### Phase 4b — Non-generic variants
Variant decls, arm constructors, switch + if/goto match strategies, field
destructure bindings.

### Phase 4c — Generics monomorphization (function-level)
Inline monomorphization with `type_substitution` map and `specialization_cache`.
Generic struct decls via `ensure_generic_struct_decl`. Cross-module struct
constructors via `struct_exists_in_imports`. **Note**: only handles generic
FUNCTIONS (e.g. `first[int](p)`), not METHODS on generic types.

### Phase 5 — proc/fn, dyn, method dispatch, str_buffer, format, `is` ✅

### Phase 6 — events, async, parallel, compile-time ✅ (serial approximations)

### Phase 7 — Cross-module type system hardening (complete)

All Phase 7 blocker items from the original plan are resolved:

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | Imported module method names | ✅ | `fallback_type` → `import_qualified_type` resolves `alias.Type` → `ty_imported` |
| 2 | `ty_imported` args propagation | ✅ | Added `args: span[Type]` field; `imported_type_with_args` in analyzer |
| 3 | 2-part name resolution | ✅ | `resolve_generic_type_ref`, `resolve_field_type_ref`, `resolve_type_ref` all handle `vec.Vec[Token]` |
| 4 | Nullable types in field resolution | ✅ | `resolve_field_type_ref` no longer returns `ty_error` for nullable |
| 5 | `substitute_type_params` recursion | ✅ | Recurses into `ty_nullable` and `ty_imported` args |
| 6 | Generic struct monomorphization | ✅ | `qualify_type` recursive; private struct search via `struct_in_source`; recursion guard via `spec_in_progress` |
| 7 | Cross-module enum match names | ✅ | `enum_source_module` lookup; `variant_match_allowed` prefix matching |
| 8 | Import alias member access | ✅ | `lower_member_access` resolves `import_alias.type/value` through imports |
| 9 | No-payload variant arm lowering | ✅ | `find_imported_variant_arm` → `expr_variant_literal` |
| 10 | Pointer access (. vs ->) | ✅ | `is_pointer_or_ref_type` for `ref[T]`/`ptr[T]` params |
| 11 | `_Alignof` rendering | ✅ | C backend uses C11 `_Alignof` |
| 12 | Module constants | ✅ | `decl_const` lowering emits `ir.Constant`; `lookup_qualified_constant` |
| 13 | Variant deduplication | ✅ | `dedup_append_structs`/`dedup_append_variants` during fragment merge |
| 14 | Generic method filtering | ✅ | `lower_extending_block` skips blocks with type params (methods monomorphized on demand) |
| 15 | `zero[T]` / `read()` builtins | ✅ | `expr_specialization` handles `zero`; `is_read_call` desugars `read(x)=v` |
| 16 | Raw type params → void | ✅ | `qualify_type` returns `void` for `T`/`K`/`V`/etc. |
| 17 | `std_c_*` re-exports | ✅ | Raw module constants use bare C macro names |
| 18 | Variant match for prelude types | ✅ | `variant_match_allowed` + `variant_base_c_name` handle qualified types |

---

## 2. Current state (2026-07-07 P7.5)

### Self-host build: `mtc build projects/mtc`

**Status**: 0 undeclared C errors, 1127 total C compiler errors.
Pipeline end-to-end works. The binary built by the Ruby compiler can
parse, check, lower, and generate C for its own source. The generated C
has errors that prevent native compilation.

### Error breakdown (1127 remaining)

All errors cascade from one root cause:

| Category | Count | Root cause |
|----------|-------|-----------|
| Generic method call names (`std_vec_Vec`, `std_map_Map`) | ~142 | Calls to `Vec[Diag].create()` use generic function names instead of monomorphized `Vec_Diag_create()` |
| Pointer init from int | ~200 | Cascade from unknown types → `void*` initialized with `0` |
| Member access on non-struct | ~150 | Cascade from unknown types → `.` on `void`/`int` |
| Variable declared void | ~45 | Local variable types resolve to `void` |
| Incomplete type fields | ~50 | Variant arm payload structs after struct definitions |
| Other | ~540 | Type mismatches, return type conflicts |

### Error elimination path

Fixing the generic method call name resolution (~142 errors) will
eliminate ~500 cascading errors. Estimated ~300 LOC change.

---

## 3. Current file sizes

| File | LOC | Change since original plan |
|------|-----|---------------------------|
| `lowering/lowering.mt` | 6,326 | +756 |
| `c_backend/c_backend.mt` | 3,106 | +106 |
| `semantic/analyzer.mt` | 3,818 | -1,182 (consolidation) |
| `semantic/types.mt` | 707 | — |
| `semantic/type_compatibility.mt` | 133 | — |
| `loader/module_loader.mt` | 335 | — |

---

## 4. Next session: Generic method monomorphization

### Context

The original Phase 4c completed *function-level* generics monomorphization:
`lower_monomorphized_call` monomorphizes bare generic functions like
`first[int](p)` by cloning the generic body with type substitution and
generating a specialized C function.

It does NOT cover *method calls* on generic types. When `Vec[Diag].create()`
is called, the specialization path in `lower_specialization_call` routes
through `resolve_method_info` which returns the generic function name
(`std_vec_Vec_create`) with the generic return type. The call uses the
raw generic function name, but the function doesn't exist (generic
extending blocks are skipped by `lower_extending_block`).

### What needs to happen

When a method call on a generic type with concrete type args is encountered
(e.g. `vec.Vec[Diag].create()`), the lowering must:

1. Find the method's AST declaration in the defining module's extending block
2. Build a type substitution map from the extending block's type params to the
   concrete args (e.g. `{T: Diag}`)
3. Clone the method body with the substitution applied
4. Generate a monomorphized C function (e.g. `std_vec_Vec_Diag_create`) with
   concrete return/param types
5. Replace the call site with the monomorphized name

### Key code paths

| Function | File:line | Purpose |
|----------|-----------|---------|
| `lower_specialization_call` | `lowering.mt:~2700` | Entry point for `Vec[Diag].create()` — currently routes through `resolve_method_info` |
| `resolve_method_info` | `lowering.mt:~3609` | Resolves method on receiver type, returns generic `MethodInfo` |
| `lower_method_resolved` | `lowering.mt:~3590` | Generates `expr_call` with the resolved C name |
| `lower_monomorphized_call` | `lowering.mt:~2846` | Monomorphizes generic FUNCTION calls — needs extending for method calls |
| `lower_extending_block` | `lowering.mt:~780` | Currently skips generic blocks — needs to be kept as source for monomorphization |
| `type_substitution` | `LowerCtx` field | Maps type param names to concrete types during monomorphization |
| `specialization_cache` | `LowerCtx` field | Cache of already-monomorphized function bodies |

### Implementation plan

1. **Modify `lower_extending_block`**: Instead of skipping generic blocks entirely,
   store the AST method declarations in a `generic_methods` map keyed by
   `(module, struct_name, method_name)`. Don't emit the IR functions.

2. **Modify `resolve_method_info`**: When receiver has concrete type args AND
   the method is generic, return a marker indicating monomorphization is needed.

3. **Add `lower_monomorphized_method`**: Takes the receiver type args, finds
   the generic method AST, builds substitution, clones the method body,
   generates the specialized function, and returns the monomorphized call.

4. **Wire into `lower_specialization_call`**: After `resolve_method_info`, if the
   method needs monomorphization, call `lower_monomorphized_method` instead of
   `lower_method_resolved`.

### Ruby compiler reference

The Ruby compiler's `lowering.rb` handles this in `lower_specialization_call`
and `lower_monomorphized_call`. Key patterns to follow:

- The monomorphized function name includes type args: `Vec_Diag_create`
- The body is cloned with `type_substitution` for all local types
- The specialized function is cached in `specialization_cache`
- Cross-module methods are found by searching `program_analyses` for the
  defining module's AST

### Testing approach

1. Create a minimal test: `import std.vec` + `var v = vec.Vec[int].create()`
2. Verify the generated C calls `std_vec_Vec_int_create()` with correct return type
3. Verify all 172 self-host tests still pass
4. Verify `std_vec_Vec` and `std_map_Map` raw name errors decrease

### Risks

| Risk | LOC | Notes |
|------|-----|-------|
| Method AST lookup across modules | ~50 | Need to search imported module's source_file.declarations |
| Body cloning with type substitution | ~100 | Need to handle local types, params, return types |
| Specialization caching key design | ~30 | Must include module + struct name + method name + type args |
| Recursive method calls | ~20 | Need recursion guard (similar to `spec_in_progress`) |

---

## 5. Progress checklist

- [x] Phase 0 — IR + scaffolding
- [x] Phase 1 — return-int binary
- [x] Phase 2 — control flow, str/cstr, enums, foreign
- [x] Phase 3 — non-generic aggregates
- [x] Phase 4a — multi-module assembly + cross-module calls
- [x] Phase 4b — non-generic variants + match strategies + variant literals
- [x] Phase 4c — generics monomorphization (function-level complete)
- [x] Phase 5 — proc/fn, dyn, method dispatch, str_buffer, format, `is`
- [x] Phase 6 — events, async, parallel, compile-time
- [ ] Phase 7 — build parity + self-host bootstrap (in progress)
  - [x] Imported module method names (18 fixes applied)
  - [x] Cross-module type system hardening
  - [x] Generic struct monomorphization
  - [x] Cross-module variant/enum/const resolution
  - [x] Builtin handling (zero, read, _Alignof, pointer flags)
  - [ ] Generic method monomorphization ← **next**
  - [ ] Milestone: `mtc build projects/mtc`

---

## 6. Deferred items

- Guards and equality patterns in struct-pattern match arms.
- Build-mode codegen parity (cache, debug-guards, line directives, include set).
- `as cstr` for non-literal values.
- Prelude module prefix (`std_option_` names).
- proc selective retain / scope-exit release.
- SoA: deferred indefinitely.
- CPS state machine for async/await.
- Capture analysis for parallel/detach (currently no-capture only).

---

## 7. Cross-cutting principles

- **IR is the frozen seam.** Backend reads only `IR`; Lowering reads only `Analysis`.
- **Byte-identical C as the correctness oracle.**
- **Follow Ruby's algorithmic structure.**
- **Fail loud on substrate gaps.**
- **Sandbox every built binary** (`timeout` + `ulimit -v`).
