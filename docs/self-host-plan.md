# Self-Host Plan: Lowering + C-Backend

Status: **Phase 8 — self-compile C-error elimination. 7 C errors remain (all D1; measured with `-I std/c`).**
Last updated: 2026-07-09 (P8, Seam A + B §3.1 + C + §3.4 + E + 8b void* landed)


> **Measurement note:** always compile the self-compiled C with the external header
> path and GNU source, i.e.
> `cc -std=c11 -D_GNU_SOURCE -Wno-implicit-function-declaration -I std/c -c tmp/self.c`.
> Earlier baselines that omitted `-I std/c` stopped at the first missing header and
> undercounted; the honest count with headers in scope was ~493 at the start of the
> 2026-07-08 session.

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

Self-host source layout (src ≈ 26k LOC):

| Stage | Path | LOC |
|-------|------|-----|
| Lexer | `src/mtc/lexer/` | ~1,590 |
| Parser + AST | `src/mtc/parser/*.mt` | ~4,860 |
| Pretty printers | `src/mtc/pretty_printer/*.mt` | ~2,190 |
| Semantic analyzer | `src/mtc/semantic/analyzer.mt` | ~3,880 |
| Type system | `src/mtc/semantic/types.mt` | ~710 |
| Loader | `src/mtc/loader/` | ~720 |
| IR | `src/mtc/ir.mt` | ~220 |
| Lowering | `src/mtc/lowering/lowering.mt` | ~7,205 |
| C Backend | `src/mtc/c_backend/c_backend.mt` | ~3,320 |
| Build driver | `src/mtc/build.mt` | ~80 |
| C naming (shared) | `src/mtc/c_naming.mt` | ~137 |

**All 172 self-host tests pass, 0 failures** (the former "7 known permissiveness failures" were fixed by `check_match`).

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

### Phase 4c — Generic function monomorphization
Inline monomorphization with `type_substitution` map and `specialization_cache`.

### Phase 5 — proc/fn, dyn, method dispatch, str_buffer, format, `is` ✅

### Phase 6 — events, async, parallel, compile-time ✅ (serial approximations)

### Phase 7 — Cross-module type system hardening ✅ (see git history for the 18-item table)

### Phase 7.5 — Generic method/function monomorphization + codegen correctness ✅ (this session)

The former "next blocker" is done, plus a large batch of codegen-correctness fixes
that drove self-compile C errors from **1127 → 516** (via **2227** once method bodies
started emitting — see §2). Commits `1fe8924f`…`24476860`:

| Area | What landed | Key symbols |
|------|-------------|-------------|
| Generic **method** monomorphization | Method calls on generic types (`Vec[int].create()`, `v.push(x)`) clone the method body, substituting the struct's type params, and emit a specialized C function. Body lowered in the **owner module's context**. | `lower_monomorphized_method`, `ensure_monomorphized_method`, `lower_specialized_method`, `try_generic_method_call`, `generic_receiver_info`, `spec_receiver_info`, `find_generic_method` |
| Generic **function** owner-context | Generic function bodies also lowered in the owner module's context; instances named by owner + dedup'd across callers. | `lower_and_cache_specialization`, `find_generic_function`, `dedup_append_functions` |
| **Naming** | Module-qualified generic-instance names via a shared pure key (fixes `Vec[ir.Field]` vs `Vec[ast.Field]` collisions). | `naming.type_c_key` (used by `generic_struct_c_name`, `generic_c_type`, `span_type_name`, `specialization_key`, tuple/str_buffer/checked-index/variant/fn names) |
| **Member/field typing** | Field types resolved from concrete monomorphized struct decls, imported-struct decls (owner context), and variant arm-payload info. Auto-ref/deref receiver passing. | `concrete_field_type`, `imported_field_type`, `arm_payload_field_type`, `build_receiver_arg`, `build_imported_variant_info` (owner-context field types) |
| **Match** | `lower_match` prefers the lowered scrutinee's type; integer→switch, string→if-chain; exhaustiveness diagnostics. | `lower_scalar_match`, `lower_string_match`, `check_match` (diagnostic-only, `infer_expr_inner`) |
| **Builtins/casts** | rvalue `read(p)`→deref; `size_of`/`align_of`/`reinterpret`/`zero`/cast targets qualified; pointer arithmetic typed by the pointer operand; span `.data`/`.len`; `hash`/`equal`/`order`→canonical hooks with implicit borrow; native `str(data=, len=)`→`mt_str` aggregate. | |
| **Ordering/emission** | Combined struct+variant topological sort; generic-variant instance collection scans expressions and nested type args; reachability walk scans variant-literal fields. | `topo_sort_types`, `collect_gv_from_expr`, `collect_gv_from_type`, `reach_from_expr` |
| **Prelude variants** | `Option`/`Result` instances kept globally named (`Option_str`, not `<module>_Option_str`) through `qualify_type`. | |

---

## 2. Current state (Phase 8, as of 2026-07-09)

### Self-compile: the Ruby-built self-host binary compiles its own source

The pipeline works end-to-end: `mtc emit-c` → 47,814 lines of C → `cc -c`.  The
compiled shared system comes from *all* of the self-host's modules in aggregate, so each
fix measured against the full emit-c + `cc` baseline.

```sh
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-noguard
tmp/mtc-noguard emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root . > tmp/self.c
cc -std=c11 -D_GNU_SOURCE -Wno-implicit-function-declaration -I std/c -c tmp/self.c -o /dev/null 2>tmp/errs.txt
```

**Status**: 7 `cc` errors, 172/172 tests pass. (Was 83 at the start of this session; Seams A, B §3.1,
C, §3.4, E, and the Phase-8b void* external-ABI cluster landed — see the progress checklist in §5 for
the authoritative, up-to-date breakdown.  **All 7 remaining errors are D1** — see below.)

### Error breakdown (7 remaining — all D1)

| Root cause | Count | Notes |
|-----------|-------|-------|
| `return match` hoist (D1) | 7 | LIVE `return match` in token.mt (enum), keywords.mt (str), lexer.mt x2 (tuple). Needs real hoist + tuple-scrutinee support + latent `lower_variant_match_expr` crash fix. Deferred to a dedicated session — see §5 D1 entry. |

Everything else (scattered singletons and the `void*` libc external-ABI cluster) is resolved.

### Historical breakdown (83, grouped by root cause) — mostly RESOLVED this session

| Root cause | Count | Status |
|-----------|-------|-----------------------|
| Match-expression lowering (stub-generated) | ~12 | Partly resolved via §3.4; 7 remain as D1 (`return match`, re-characterized as live code). |
| `std_map_Option_` variant-literal prefix | ~3 | ✅ Fixed by Seam B §3.1 (prelude variant method monomorphization). |
| `String.create()` static method return type | ~8 | ✅ Fixed by Seam A (static-method returns via resolve_method_info). |
| `void*` return-from-int (std_mem_heap) | 4 | Still open — Phase 8b (external ABI). |
| `mtc_ir_Expr` vs `ast_Expr` pointer mismatch | 3 | ✅ Fixed by §3.4 (arm-payload collision guard). |
| Declared void / `mt_` fallback (Map/Vec methods) | ~6 | ✅ Fixed by Seam A (chained/read() receiver typing) + Seam C. |
| Map/vec `.contains()` arg type mismatches | 4 | ✅ Fixed by Seam C (ref[T] implicit borrow). |
| Scattered singletons | ~43 | Mostly collapsed by A/B/C/§3.4; ~9 remain (Seam E). |

### Already fixed this session (208 → 83, −125)

See §5 checklist for the full list. The big items:

- **str-method naming overhaul** (−27): bare `<type>_<method>` for primitive/str receivers, `_static` for hooks.
- **RemovedEntry qualification** (−12): `qualify_type` on generic-variant-literal type args.
- **current-module field typing** (−30): `imported_field_type` resolves current-module struct fields.
- **Cross-ctx prelude `_phantom`** (−43): shared `prelude_arm_field_types` program-wide registry.
- **array const C emission** (−5): `render_constant`/`render_global` use `c_declaration` for array types.
- **match-expr infrastructure** (3 bugfixes, no net change): `enum_source_module`, `var ty → ty_error`, `lower_str_match_expr`.
- **prelude method C naming** (in progress): `method_c_name` + `prelude_variant_base` for global Option/Result methods.

### Infrastructure ready, hoist pending

The 3 match-expression infrastructure bugs are fixed. The `return match` hoist works on all 4 individual match-expr files (keywords.mt/81, token.mt/enum, lexer.mt/2 tuples). Full self-compile crashes with `lowering: unsupported variant match expression pattern` when the hoist is enabled — root cause not yet isolated. The crash is NOT a guard trip (unguarded also crashes), NOT from the str-routing change, and NOT from the `let x = match` path. Suspect a side-effect from `lower_match_expression_local` during lowering that triggers `lower_variant_match_expr`'s goto-path in a subsequent module's variant match.

---

## 3. Ranked path to zero (83 → 0)

### 3.1 `std_map_Option_` variant-literal prefix (~3, plus may cascade)

The remaining `std_map_Option_...` lines come from variant-literal constructions
(`Option[RemovedEntry].some(value = ...)`) in `Map.remove()`, not from method calls.
The `.some(...)` arm body emits `Option[RemovedEntry]` with `std_map_` prefixing the
outer Option. Fix: the variant-literal type argument build path must recognize prelude
variant outer names (Option/Result) and use global naming, similar to the method-call
fix in `method_c_name`.

**Approach**: in `lower_generic_variant_literal` or `ensure_generic_variant`, when the
outer variant is a prelude variant, use a bare global name (no module prefix) for the
outer variant C name — matching the already-fixed method-name path.

### 3.2 `String.create()` static method return type (~8)

`String.create()` / `String.with_capacity()` / `String.from_str()` return `String` (a
nominal struct), but static methods are **not** in the `function_returns` table (only
free functions are registered by `collect_program_returns`). When lowered, the call's
return type resolves as `void` or `int`, cascading into `String` unknown-type,
return-type mismatches, and `reserve`/`append` arg-type errors.

**Approach**: either (a) register static method return types in `function_returns`
during `collect_program_returns` (by iterating each module's `method_sigs` for static
methods whose return type is a nominal struct and adding entries keyed by the member
C name), or (b) teach `function_return_type` to search `method_sigs` when the functions
table has no entry. Approach (a) is more surgical and mirrors how free-function returns
are already collected.

### 3.3 Match-expression hoist (unblocked, the ~12 cosmetic cluster)

The 3 infrastructure bugs are fixed. The `return match` hoist in `lower_stmt` works on
all 4 individual match-expr files. Full self-compile crashes — root cause to isolate:

- The crash is `lowering: unsupported variant match expression pattern` from
  `lower_variant_match_expr`'s goto-path. The goto-path fires for variant matches with
  struct-pattern arms.
- The crash occurs **only** during full compilation (all modules), never on individual
  files — suggesting a side-effect or state-leak from the hoist's
  `lower_match_expression_local` call that triggers the variant path in a later module.

**Debug plan**: add a unique fatal identifier to each `variant_match_arm_name_from_pattern`
call site (3 in total) to identify which module's match triggers it; add a `lower_match_expression_local`
suppression flag to skip the hoist path and see if the crash persists; bisect which module
causes the crash by compiling subsets of modules.

### 3.4 `mtc_ir_Expr` vs `ast_Expr` pointer mismatch (3)

Variant registry keyed by bare `Expr` name — `mtc.ir.Expr` and `mtc.parser.ast.Expr`
collide. The arm-payload path has a workaround, but match dispatch and other lookups may
still be affected.

**Approach**: change the variant registry key to use module-qualified names, or add
module-qualified fallback lookup in the relevant paths.

### 3.5 Declared void / `mt_` fallback on Map/Vec methods (~6)

`_prev`/`last`/`kinds`/`found`/`configured` all come from monomorphized Map/Vec method
calls (`.set()`, `.get()`, `.byte_at()`, `as_span()`) falling to the `<module>_mt_<method>`
fallback because the method's return type isn't in the return-type table for
monomorphized instances.

**Approach**: similar to §3.2 — register monomorphized method return types, or resolve
them from the method's FnSig in `resolve_method_info`.

### 3.6 Map/vec `.contains()` arg mismatches (4)

Monomorphized generic method call arg types don't match the concrete struct decl. Likely
a key-type qualification inconsistency between the struct-decl site and the call site.

**Approach**: check how `Map.contains(key)` arg types are qualified in the call
lowering vs the struct decl emitted for `Map[span_str, VariantInfo]`.

### 3.7 Scattered singletons (~43)

No dominant root; most are single-occurrence. After the clusters above are fixed, a
final pass to identify any remaining groups will likely resolve most of these.

---

---

## 4. Architecture notes for the next session

Established this session; reuse these seams rather than re-deriving them:

- **Monomorphization**: method calls route through `try_generic_method_call` →
  `lower_monomorphized_method`; both method and function bodies are lowered in the **owner
  module's context** (`ctx.module_name`/`analysis`/`foreign_map`/`variants` swapped, then
  restored). Concrete type args are **qualified in the caller's context** before the switch,
  so a type from a module the owner does not import still renders correctly.
- **Naming**: `naming.type_c_key(ty)` is the single source of truth for generic-instance
  name suffixes — use it for any new generic-name construction so lowering and the backend
  stay byte-identical.
- **Member typing** resolution order in `lower_member_access`: span `.data`/`.len` →
  `concrete_field_type` (monomorphized structs) → `arm_payload_field_type` (variant payloads)
  → `imported_field_type` (cross-module structs, owner context) → analyzer `expr_type`.
- **Match**: `lower_match` prefers `ir_expr_type(lower_expr(scrutinee))` over the analyzer's
  `expr_type` (more accurate for Option-typed fields / `read(ptr)`).
- **Prelude variants** (`Option`/`Result`) are globally named — never module-prefix them.

## 5. Progress checklist

- [x] Phase 0 — IR + scaffolding
- [x] Phase 1 — return-int binary
- [x] Phase 2 — control flow, str/cstr, enums, foreign
- [x] Phase 3 — non-generic aggregates
- [x] Phase 4a — multi-module assembly + cross-module calls
- [x] Phase 4b — non-generic variants + match strategies + variant literals
- [x] Phase 4c — generic function monomorphization
- [x] Phase 5 — proc/fn, dyn, method dispatch, str_buffer, format, `is`
- [x] Phase 6 — events, async, parallel, compile-time
- [x] Phase 7 — cross-module type system hardening
- [x] Phase 7.5 — generic **method** monomorphization + owner-context + naming + codegen fixes
- [ ] Phase 8 — self-compile C-error elimination (in progress; **493 → 83** with `-I std/c`)
  - [x] Prelude Option/Result match-arm payload `_phantom` — same-LowerCtx cases
  - [x] External ABI type names (std.c.* bare C name) + gather external `include` directives (493 → 465)
  - [x] Method-call receiver types resolved in owner-module context — kills FnSig/FieldEntry
        misattribution cluster (465 → 355)
  - [x] `let/var ... else:` guard lowering with success unwrapping (355 → 313)
  - [x] Cross-module + external call return-type resolution in fallback_type (313 → 307)
  - [x] Stop double-qualifying cross-module call return types (307 → 304)
  - [x] Dispatch `fatal(str)` to `mt_fatal_str` helper (304 → 298)
  - [x] Register imported variant arm-payload field types by qualified name — fixes the
        `ir.Expr`/`ast.Expr` registry name-collision (`mt_str==mt_str`) (298 → 282)
  - [x] Recover generic method receiver args from analyzer type for cross-module-bound
        instances (`da.check()` → `Vec[Diag]`) — fixes `void*`/`declared void` cascade (282 → 273)
  - [x] Type `str.data`/`.len` synthetic fields + integer arithmetic result types — fixes the
        `mt_str x = ....len` mis-inference cascade (273 → 249)
  - [x] Coerce pointer args to by-value params in generic method calls (`Map.find_node(this, ...)`
        inside editable methods) (249 → 222)
  - [x] Qualify imported bare type names against their owner module (`qualify_type` +
        `imported_type_module`) — kills the `Diag` → `mtc_semantic_analyzer_Diag` misattribution (222 → 206)
  - [x] **str method naming overhaul (208 → 181, −27).** `str` instance methods
        (`slice`/`byte_at`/...) fell to the `mt_` fallback (returning `int`), the instance
        `equal(right)` collided with the static `equal(left,right)` hook (both `std_str_str_equal`),
        and the `this` receiver was typed `std_str_str` instead of `mt_str`. Fixed by mirroring
        Ruby's `function_binding_c_name` / `c_type_name` for primitive/`str` receivers:
        `method_link_name` emits a bare `<type>_<method>` C name (no module prefix) with a
        `_static` suffix for static hooks (`str_equal_static`/`str_hash_static`/`str_order_static`);
        `extending_receiver_type` types the receiver as the real primitive/`str` type;
        `resolve_primitive_method_info` resolves instance calls on primitive/`str` receivers; and a
        `lower_static_call_args` path handles static hook calls on a bare type name (`str.order(a,b)`).
        Coordinated across `lower_extending_block` (def site), `resolve_method_info` (call site), and
        `resolve_canonical_hook` (hook path). Eliminated all `int-vs-mt_str-return`, `std_str_str`,
        and `str`-undeclared clusters; 172/172 tests still pass. (Nominal-type `_static` deferred —
        no collisions in self-host source; revisit for byte-identical C.)
  - [x] `Option[RemovedEntry[K,V]]` prelude-variant instance naming (181 → 169, −12). The
        `remove_entry` body built `Option_RemovedEntry_str_bool` (bare) while its signature used
        `Option_std_map_RemovedEntry_str_bool` (qualified). Fixed by applying `qualify_type` to the
        resolved type args in BOTH generic-variant-literal paths — `lower_generic_variant_literal`
        (the `.some` arm) and the no-payload arm path in `lower_member_access` (the `.none` arm) —
        so a locally-defined struct arg like `RemovedEntry` is monomorphized to its module-qualified
        C name in the body, matching the signature and the emitted variant decl.
  - [x] Proc typedef over-qualification (169 → 167, −2). A `proc(...)` param/field type resolves to a
        global `ty_named("mt_proc_...")` typedef, but `qualify_type` module-prefixed it in a
        monomorphized context (`std_vec_mt_proc_int_ptr_str_ptr_str`). Added `mt_proc_` to the
        `Option_`/`Result_` global-name passthrough in `qualify_type`.
  - [x] **`mt_` fallback / current-module field typing (167 → 137, −30).** Method calls whose receiver
        type resolved to void/error fell to the `<module>_mt_<method>` fallback (`mt_equal` on a `str`
        from `read(ptr[str])` / field access, etc.). Root: `read(ptr[LocalStruct])` gets type
        `ty_imported(current_module, LocalStruct)` after `qualify_type`, but `concrete_field_type` only
        matched `ty_named` and `imported_field_type` explicitly bailed for the current module — so a
        field on a current-module struct fell through all recovery paths when the analyzer's
        `expr_type` (keyed by AST-node identity) had no record. Fix: `imported_field_type` now resolves
        current-module struct fields via `ctx.analysis.source_file` directly. Eliminated all `mt_equal`
        fallbacks; cascaded broadly (−30).
  - [x] **Cross-ctx prelude payload `_phantom` (137 → 94, −43).** A match on a cross-module call
        returning `Option[T]`/`Result[T,E]` (`fs.read_text(...)`) bound `s.value`/`f.error` to an
        undeclared `_phantom` type: the concrete decl's arm field types live only in the *defining*
        module's per-ctx `pending_generic_variants`, and `lower_match` collapses the scrutinee type to
        an arg-less C name so the fallback also failed. Fix (plan's recommended "shared program-wide
        registry"): added `LowerCtx.prelude_arm_field_types` — a `program_returns`-style shared
        `ptr[Map]` keyed by the arm's payload struct C name (`Result_std_string_String_std_fs_Error_success`
        → `std_string_String`), populated by `ensure_generic_variant` during `collect_program_returns`
        (before any body lowers) and consulted first in `concrete_prelude_field_type`. Eliminated all
        `_phantom` errors and their `int-init`/`declared-void` cascades (−43).
  - [x] local_decl_type qualification (94 → 88, −6). A local variable with a declared monomorphized
        type (`var previous: ptr[Node[K,V]]?`) kept the bare `Node_str_bool` after
        `resolve_type_ref` because `local_decl_type` returned the resolved annotation without
        `qualify_type`. Now mirrors `resolve_param_type`/`resolve_return_type` by applying
         `qualify_type`. Also fixed a dormant infinite loop in `lower_enum_match_expr` (missing
         `i += 1` before `continue` in the non-enum-member-pattern branch).
  - [x] **Seam A — return-type table completeness (83 → 69, −14).** Cascade-first landing so calls
        stop falling to the `<module>_mt_<method>` fallback (which typed results `void`/`int`). Four
        coordinated fixes in `lowering.mt`: (a) **static methods on struct type names**
        (`String.create()`): `lower_call` routes an identifier receiver naming a struct through
        `resolve_method_info` and emits a static call (mirrors Ruby's `resolve_type_expression` +
        `static:<method>` path), killing the `std_string_mt_create(std_string_String)` fallback and the
        bare-`String` local-type cascade (−8). (b) **current-module return qualification**:
        `resolve_method_info`'s current-module nominal path now applies `qualify_type` to the return
        type (`String` → `std_string_String`). (c) **chained / `read()` method receivers**:
        `method_receiver_type` types method-call and `read(ptr)` receivers by lowering them
        (side-effect-free), so `result.as_str().byte_at(i)` and `read(frame_ptr).set(...)` resolve
        (`last`/`_prev`/`found` no longer `void`) (−5). (d) **cross-module foreign-function returns**:
        `collect_program_returns` registers `decl_foreign_function` returns (via nullable-aware
        `resolve_type_ref`) under the module-qualified key, so `libc.get_environment_variable() -> cstr?`
         no longer resolves `void` (−1). 172/172 tests pass. Leftover: the single `array.as_span()`
         builtin on a const array (`kinds`) still hits the `mt_` fallback — a builtin-method seam (§3.6
         family), not a return-type gap.
  - [x] **Seam B §3.1 — monomorphize prelude variant methods (69 → 57, −12).** The plan's framing
        ("variant-literal naming, ~3") was inaccurate: prelude `Option`/`Result` methods
        (`unwrap`/`unwrap_or`/`is_some`/…) were **existence-only** in the analyzer with NO lowering path
        — emitted as undefined functions (compile errors on `.unwrap().value`, latent link errors
        elsewhere). Fixed with faithful **Strategy A** monomorphization (mirroring Ruby):
        (a) the loader now **seeds `std.option` / `std.result` as prelude modules** (like Ruby's
        `PreludeInstaller`) via `seed_prelude_module`, so their real `extending` method bodies are
        parsed/checked and available; (b) `generic_receiver_info` recovers prelude-variant receivers —
        structured `ty_generic`/`ty_imported` args, or a collapsed `ty_named` via `prelude_instance_args`
        (recovered from the pending generic-variant registry's arm field types); (c) `find_generic_method`
        searches variant-declaring modules (`variant_in_source`), not just structs; (d)
        `monomorphized_method_c_name` uses the global `Option_<typeargs>_<method>` scheme for prelude
        variants. 172/172 tests pass. Note: pre-existing self-host `check`-command gaps (8 errors, e.g.
         `.is_none()`/`.unwrap()` unknown-method and `pointer cast requires unsafe`) are unrelated to the
         emit-c self-compile path and unchanged.
  - [x] **Seam C — monomorphized call arg qualification + array builtins (57 → 44, −13).** Two fixes:
        (a) **implicit borrow for `ref[T]` call args (57 → 49):** a by-value argument passed to a
        `ref[T]` parameter was emitted verbatim, producing a value/pointer mismatch (e.g.
        `vec_contains_str(covered)` where the param is `ref[Vec[str]]`, plus the Map `.contains()`
        cluster). `lower_plain_call` now threads the callee's `FnSig` (via `lower_plain_call_sig`) and
        `coerce_arg_to_ref_param` takes the address (`&arg`) when the parameter is `ref[T]` and the
        argument is not already pointer-typed — mirroring the analyzer's call-site borrow rule.
        (b) **`array[T, N].as_span()` builtin (49 → 44):** it fell to the `<module>_mt_as_span`
        fallback (declared void). Intercepted in the method-call dispatch and lowered to a span
        aggregate literal `{ data = &arr[0], len = N }` (mirrors Ruby's `:array_as_span`). The length
        is recovered from the array type, or from the const/var declaration's type annotation when the
        recorded receiver type dropped its literal count; the index receiver type is rebuilt with the
        recovered length so the correct `mt_checked_index_array_*_N` helper is emitted (fixes a latent
        `len=0` / `[0]`-helper bug on const array references). 172/172 tests pass.
  - [x] **§3.4 — `ir.Stmt`/`ast.Stmt` arm-payload collision (44 → 20, −24).** In `lower_stmt`,
        `loc.destructure_bindings` (an `Option` field) lowered to a garbage `switch`, and `loc.value`
        (`ptr[ast.Expr]?`) was typed `mtc_ir_Expr*`. Root cause: when a module imports two variants
        sharing a bare name (both `ir.Stmt` and `ast.Stmt` are "Stmt"), a match on one re-registered its
        arm-payload fields from `ctx.variants[base_name]`, which the bare-name collision could resolve to
        the WRONG module's variant — clobbering the authoritative, module-qualified entry that
        `install_imported_variants` had already registered (field types resolved in the owner context).
        Fix: `register_arm_payload_fields` skips re-registration when a non-prelude entry already exists,
        so the `install_imported_variants` entry wins; prelude variants still re-register to specialize
         their `_phantom` placeholder. Corrected both `loc.destructure_bindings` and `loc.value` typing,
         cascading −24. 172/172 tests pass.
  - [x] **Seam E — scattered singletons (20 → 11, −9).** Seven independent, mostly-mechanical fixes,
        each mirroring Ruby semantics; all gated on 172/172 tests:
        (a) **topo-order generic-variant by-value deps** (20→19): a field embedding a generic-variant
        instance by value (`stmt_local.destructure_bindings: Option[span[str]]`) produced no topo edge
        ("incomplete type"); `by_value_dep_key` now returns the instance name for non-pointer generics.
        (b) **`ptr_of`/`ref_of` on pointer values** (19→17): applying them to an already-pointer value
        (a `ref[T]` param) emitted `T**`; now uses the pointer directly / the `*p` operand, per Ruby.
        (c) **scope unsafe/block locals** (17→16): sibling `unsafe:` blocks declaring the same local
        collided; wrap each body in `ir.Stmt.stmt_block` for a distinct C scope.
        (d) **skip `_` discards in destructuring** (16→15): `let (_, x, _) = ...` emitted a local per
        discard ("conflicting types for value"); skip `_` bindings, per Ruby's `next if name == "_"`.
        (e) **auto-deref pointer receiver in `resolve_method_info`** (15→14): `this.m()` in an editable
        method resolved against builtin "ptr", mis-naming `<module>_ptr_<method>`; now derefs to the
        pointee type first.
        (f) **cross-module foreign calls** (14→13): `libc.get_environment_variable(...)` emitted an
        undefined Milk Tea symbol instead of the mapped C function; added `imported_foreign_call` to
        lower it to the mapped C name (`getenv`).
        (g) **integer result type for int-literal arithmetic** (13→11): `len + len + 2` mis-typed the
        result (struct) because the `+ 2` mixed `ptr_uint` with an `int` literal; adopt the non-literal
        operand's integer type (scoped narrowly to `int`-literal operands to avoid over-broad
        reclassification — a broader first attempt regressed to 758 and was reverted).
  - [x] **Phase 8b (partial) — cross-module external function calls (11 → 7, −4).** `libc.malloc` /
        `calloc` / `realloc` / `aligned_alloc` emitted an undefined module-qualified symbol
        (`std_c_libc_malloc`) instead of the bare C name, so they returned implicit `int` and failed
        `void*` assignments. Added `imported_extern_call` to resolve an `external function` decl in the
        target module and lower the call to its bare C linkage name (`extern_c_name`) with the resolved
        return type. Scoped to externals whose params are all plain (`extern_all_plain_params`), so
        `out`/`inout` externals (`mt_fs_*`, `mt_process_*`) keep their existing lowering and are not
        prematurely exposed (a first, unscoped attempt surfaced their latent `out`-param arg mismatches
        — masked today by undefined-function tolerance — and was scoped back). NOTE: those `out`-param
        cross-module external calls remain latent errors that WILL surface at Phase 8b linking and need
        proper `out`-param pointer handling then. 172/172 tests pass.
  - [ ] **D1 — match-expression `return match` hoist (7 errors, DEFERRED — needs a dedicated session).**
        RE-CHARACTERIZED: this is NOT a dead stub. The 7 `match_expr` errors come from LIVE `return match`
        code: `token.mt` `kind_name` (enum scrutinee), `keywords.mt` `keyword_kind` (**str** scrutinee),
        `lexer.mt` `three_char_token`/`two_char_token` (**tuple** scrutinee). `lower_stmt`'s `stmt_ret`
        lowers the value via `lower_expr`, which hits the `lower_expression_match` stub emitting an
        undeclared `match_expr` placeholder. Attempted fix this session (a `return match` hoist reusing a
        shared `lower_match_expression_temp`) but it triggers a pre-existing crash
        `lowering: unsupported variant match expression pattern` in `lower_variant_match_expr`
        (scrutinee_ty="Expr", module `mtc.parser.parser`) — even though parser.mt has no match
        expressions, so the crash is triggered indirectly (suspect: eager arm-value lowering in the
        type-inference helper, or `expr_type` mis-typing a hoisted match result). Also, the **tuple
        scrutinee** case is entirely unsupported by the expression-form lowering (no tuple path). Proper
        fix requires: (a) a hoist that infers the result type without side-effecting arm lowering, (b)
        tuple-scrutinee match-expression support, (c) isolating the latent `lower_variant_match_expr`
        crash. Reverted cleanly; tree stays at 20. Do this as its own focused session (the plan's original
        multi-session estimate stands).
  - [x] `array[T,N]` const emission (88 → 83, −5). `render_constant`/`render_global` used `c_type`
        for arrays, which produced the backend-internal `array_str_N` struct name (no typedef
        emitted). Fixed to use `c_declaration` which renders C-native `TYPE NAME[N]`.
  - [x] **Match-expr infrastructure** (3 bugfixes, no net error change):
        (a) `lower_enum_match_expr` now uses `enum_source_module` for imported enum member C names;
        (b) `var ty = types.Type.ty_error` replaces the default `ty_primitive("")` which crashed
        the backend; (c) added `lower_str_match_expr` (if-chain for str scrutinees) + `is_str_scrutinee`
        routing.  Also restored the `continue` infinite-loop fix.  The `return match` hoist works on
        all 4 individual match-expr files; full self-compile crash deferred (§3.3).
  - [x] **Prelude variant method C naming** (halved `std_map_Option_` prefix, 6→3).
        `resolve_method_info` used the full concrete variant type name (e.g.
        `std_map_Option_std_map_RemovedEntry_ptr_uint_bool`) to construct the method lookup key, but
        prelude methods (Option.is_some, Result.unwrap) are registered under the base variant name
        (`Option_is_some`).  The keys mismatched, so method calls fell to the `mt_` fallback.
        Added `prelude_variant_base` to extract the base name from qualified concrete names, plus
        `contains_substring` checks in `is_prelude_variant_name` for `_Option_`/`_Result_` embedded
        in module-qualified names.  `method_c_name` delegates to `prelude_variant_base` for global
        naming.  Remaining 3 `std_map_Option_` lines come from variant-literal constructions
        (`.some(...)`, not method calls — §3.1).
  - [ ] **`std_map_Option_` variant-literal prefix** (3 — §3.1).  The remaining occurrences come
        from `Option[RemovedEntry].some(value = ...)` in monomorphized method bodies.
  - [ ] **`String.create()` static method return type** (~8 — §3.2).  Static methods on nominal
        types are not in the `function_returns` table.
  - [ ] **Match-expression hoist crash** (~12 cosmetic — §3.3).  Infrastructure is ready; hoist
        works on individual files; full self-compile crashes with lowering variant error.
  - [ ] **`mtc_ir_Expr` vs `ast_Expr` pointer mismatch** (3 — §3.4).  Variant registry name collision.
  - [ ] **Declared void / `mt_` fallback** (~6 — §3.5).  Monomorphized Map/Vec method return types
        not resolved.
  - [ ] **Map/vec `.contains()` arg mismatches** (4 — §3.6).
  - [ ] **Scattered singletons** (~43).
  - [ ] Milestone: `mtc build projects/mtc` produces a native binary
- [ ] Phase 9 — correctness verification (differential C + bootstrap fixpoint)
- [ ] Phase 10 — debug-guard fix + build-mode/runtime parity

---

## 6. Deferred items

- Match-expression hoisting for str/int scrutinees (see §3.1 — the OOM blocker).
- Guards and equality patterns in struct-pattern match arms.
- Build-mode codegen parity (cache, debug-guards, line directives, include set).
- Debug-guard false-positive on large byte-scan loops (§3.3).
- `as cstr` for non-literal values.
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
- **Diagnostic passes must not mutate the analysis codegen consumes** (learned the hard way:
  `check_match` recording scrutinee types doubled the emitted C).
- **A rising C-error count can mean progress** — correct typing / un-dropping bodies emits
  more real code, which surfaces the next layer. Track categories, not just totals.
- **Sandbox every built binary** (`timeout` + `ulimit -v`); interpret `137`/`134` as OOM/abort.
