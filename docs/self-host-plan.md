# Self-Host Plan: Lowering + C-Backend

Status: **Phase 8 — self-compile C-error elimination. 94 C errors remain (measured with `-I std/c`).**
Last updated: 2026-07-08 (P8)

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

## 2. Current state (Phase 8)

### Self-compile: the Ruby-built self-host binary compiles its own source

```sh
# The default (debug-guarded) binary trips a loop guard on the ~800KB source
# (str.is_valid_utf8 scans >50k bytes). Use a guard-free binary for now:
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-noguard
tmp/mtc-noguard emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root . > tmp/self.c
cc -std=c11 -Wno-implicit-function-declaration -c tmp/self.c -o /dev/null
```

**Status**: pipeline end-to-end works. Generated C is **44,065 lines** with **495 `cc` errors**
(down from 1127; the count rose to 2227 mid-session once method/function bodies began
emitting real code, then fell to 516, then to 495 — so 495 is measured against a far more
complete codebase than the earlier 1127).

### Error breakdown (495)

No single dominant root remains — it is a diverse tail. Approximate groupings:

| Theme | ~Count | Representative errors |
|-------|--------|-----------------------|
| Match-**expression** hoisting (return/arg positions) | ~22 | `match_expr` undeclared; some `return int but mt_str expected` |
| Residual member/field typing | ~40 | `mt_str == mt_str` (str field not typed str → not `mt_str_equal`); `member on non-struct` (`len`/`data`/`value`) |
| Cross-module type attribution / struct emission | ~25 | `mtc_main_LoadDiagnostic` (should be its defining module); `Diag`/`FnSig` unknown (struct not emitted) |
| Cross-ctx prelude payload `_phantom` | ~47 | `mtc_<mod>__phantom` — Option/Result payload arm bound in a module where the concrete variant instance was created in *another* module's LowerCtx (see §3.1.1) |
| Generic `Map` instance arg mismatches | ~21 | `std_map_Map_str_..._contains` argument type mismatch (span/struct keys) |
| Option/init handling | ~23 | `char* = Option_str`; `invalid initializer` |
| External/opaque ABI types | ~6 | `std_c_fs_mt_fs_error` unknown |
| Other | ~360 | scattered type/return mismatches in newly-emitted bodies |

**Landed this session (516 → 495, −21):** prelude `Option`/`Result` match-arm payload
bindings (`s.value` / `f.error`) previously resolved to an undeclared `_phantom` C type
because the prelude `VariantInfo` stores a `_phantom` placeholder payload type.
`register_arm_payload_fields` now specializes that placeholder via
`specialize_prelude_arm_info`: it first looks the concrete field type up in the
just-emitted concrete variant decl (`pending_generic_variants`, keyed by the payload
struct C name), then falls back to the scrutinee's own generic args. This fixed the
**same-LowerCtx** cases (`mtc_semantic_analyzer`, `std_process`). The remaining ~47
phantom refs are the **cross-ctx** case (§3.1.1).

---

## 3. Next steps to finish self-host

### 3.1 Drive self-compile C errors 495 → 0

Incremental grind; suggested order (highest leverage / cleanest first). Each fix tends
to un-mask the next layer, so re-measure after each.

#### 3.1.1 Cross-ctx prelude payload `_phantom` (~47, highest single root)

The scrutinee is a cross-module call returning `Option[T]`/`Result[T,E]` (e.g.
`fs.read_text(...)` → `Result[String, Error]`).

**Investigation (session 2, corrected findings — supersedes the earlier "not reached
via lower_match" note, which was a probe artifact: `stdio` writes to stdout and the
`emit-c` redirect discarded it; re-probing via `terminal.write_stderr` showed the real
flow):**

The pipeline IS `lower_match` → `lower_variant_match` → `lower_variant_match_switch` →
`register_arm_payload_fields` → `arm_payload_field_type`. Confirmed facts:

1. The analyzer resolves the scrutinee correctly: `try_imported_call` (analyzer.mt)
   returns the imported fn's `sig.return_type` = `Result[String, Error]` **with args**,
   and `expr_type` in `lower_match` returns it intact (verified via stderr probe).
2. But `lower_match` line ~5717 overrides `scrutinee_ty` with the **lowered** type
   (`ir_expr_type(lower_expr(scrutinee))`), which collapses to an arg-less
   `ty_named("Result_std_string_String_std_fs_Error")`. `register_arm_payload_fields`
   receives that collapsed type, so `variant_type_args` returns empty.
3. `arm_payload_fields` is **per-`LowerCtx`** (each module re-created). The concrete
   `Result[String,Error]` variant decl lives in `std.fs`'s ctx `pending_generic_variants`,
   not the consuming module's — so `prelude_field_type_from_variants` also misses.
4. Worse, the map is keyed only by payload struct C name, shared across sites: a site
   that fails to resolve **overwrites** a good entry a prior site set.

**Fix attempted (session 2), reverted — partial, insufficient:** three combined pieces —
(a) `fallback_type` member-access-callee case via new `imported_call_return_type`
(independently correct: resolves cross-module call types that were `ty_error`);
(b) capture `analyzer_scrutinee_ty` before the line-5717 override and thread it as a new
`arg_source_ty` param through `lower_variant_match`/`_switch`/`_goto` to the specializer;
(c) an anti-overwrite guard (`arm_info_has_phantom` + `existing_arm_info_phantom_free`).
Result: a plain-`match` isolation repro improved **4 → 2 phantom** (the `success`/arg-0
arm resolved; the `failure`/arg-1 arm still didn't — asymmetry not yet explained), but the
**full self-compile stayed at 495/47**. The real modules' matches did not benefit even
though their source (`module_loader.mt:205`) is the identical `match fs.read_text(k)`
shape — strongly implying the remaining resolution gap is the **arg-1 (`failure`/error)
fallback** and/or `qualify_type` of the analyzer arg in the consuming module's context.

**Recommended next approach (cleanest):** make the concrete payload field types
resolvable **without** relying on per-ctx state or the collapsed type — decode them from
the payload struct C name (which already encodes the fully-qualified args, e.g.
`Result_std_string_String_std_fs_Error_failure`), OR promote `arm_payload_fields` /
`pending_generic_variants` to a shared program-wide registry threaded through `LowerCtx`.
Debug the arg-1/`failure` asymmetry first with the minimal repro
`match fs.read_text(k): Result.failure as f: var e = f.error ...` and a stderr probe
(NOT stdout — emit-c writes C to stdout).

#### 3.1.2 Remaining tail

1. **Match-expression hoisting** (`return match …`, `match` in call args). `lower_expression_match`
   is a stub returning an undeclared `match_expr` name. Needs to hoist into a temp + switch.
   **Blocker to redo carefully:** `lower_match_expression_local` only handles enum/variant
   scrutinees; a str/int expression-match falls into `lower_enum_match_expr` and **infinite-loops
   (OOM)**. Add int/str expression-match lowering (mirror `lower_scalar_match`/`lower_string_match`)
   **before** wiring `return match` hoisting. Verify on a minimal str-scrutinee repro first.
2. **Residual member/field typing** — chase the remaining `member on non-struct` and `str ==`
   cases (fields whose type still resolves to void/int). Same theme as the arm-payload/imported-field
   fixes already landed; likely more `ty_named` receivers that bypass `imported_field_type`.
3. **Cross-module attribution & struct emission** — `LoadDiagnostic` attributed to `mtc.main`
   instead of its defining module; `Diag`/`FnSig` structs referenced but not emitted (reachability
   or module attribution). Audit where a bare type name gets the current module's prefix.
4. **Generic `Map` instance mismatches** — `contains(...)` arg types for `Map` with span/struct
   keys; check key-type qualification consistency between the struct decl and call sites.
5. **Option/init handling** — `char* = Option_str` and `invalid initializer` (Option-typed
   values used where a scalar/pointer is expected — likely a residual match/type-resolution gap).
6. **External ABI types** — `std_c_fs_mt_fs_error` (external `struct` types from `std.c.*`);
   ensure external-file structs are emitted/forward-declared.

### 3.2 Verify correctness beyond "it compiles"

Reaching 0 `cc` errors is necessary but not sufficient — dropped/empty bodies and wrong
codegen do not always surface as C errors. Once errors are low:

- **Differential C**: diff the self-host's C output against the Ruby compiler's C output
  for the same inputs (the 11 differential programs, then the self-host source). Target
  behavioral equivalence (byte-identical where feasible — the correctness oracle).
- **Bootstrap fixpoint**: guard-free self-host → C → `cc` → **stage-2** binary; stage-2
  compiles the source again → **stage-3**; assert `stage-2 output == stage-3 output`.

### 3.3 Fix the debug-guard false-positive

Linear scans over the whole source (`str.is_valid_utf8`, lexer loops) exceed the 50k
loop-iteration guard, so the **default (guarded) binary aborts on its own source**. A debug
self-host must be able to guard *its own* compilation loops without tripping on large input:
raise/scope the threshold, or exclude byte-scan loops. Needed before the guarded binary can
self-compile.

### 3.4 Build-mode / runtime parity (after self-compile is green)

Deferred codegen/runtime items (see §6) — cache, line directives, include set, `as cstr`
for non-literals, proc retain/release, async CPS, capture analysis.

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
- [ ] Phase 8 — self-compile C-error elimination (in progress; **493 → 94** with `-I std/c`)
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
  - [ ] Variant registry keyed by bare name collides across modules (`ir.Expr`/`ast.Expr`) — the
        arm-payload path is worked around, but match dispatch/other lookups may still be affected;
        consider module-qualifying the registry key
  - [ ] Match-expression hoisting (7, now the largest cluster; needs int/str expr-match first; avoid the OOM loop)
  - [ ] Diverse tail (~87): `void *` return-from-int, `mtc_ir_Expr` vs `ast_Expr` pointer mismatches,
        `String`/`array_str_N` unknown types, residual `member on non-struct`, generic `Map`/`vec_contains`
        arg mismatches — mostly 2-3 each, no dominant root.
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
