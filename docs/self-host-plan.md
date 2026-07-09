# Self-Host Plan: Lowering + C-Backend

Status: **Phase 9 COMPLETE. Whole-program emit-c is BYTE-IDENTICAL between stage-1 (Ruby-built self-host) and stage-2 (self-built). The bootstrap fixpoint has been reached: the self-host compiles itself into identical C, and that C compiles and links to a working binary (0 cc errors, 172/172 tests pass).**
Last updated: 2026-07-09 (P9 COMPLETE: 5 correctness fixes — defer lowering, string-match-expr, string-escape decode, break-in-match-in-while x2; whole-program emit-c fixpoint)


> **Measurement note:** the self-host emit-c output now compiles cleanly WITHOUT the
> implicit-declaration crutch:
> `cc -std=c11 -D_GNU_SOURCE -I std/c -c tmp/self.c` → 0 errors.
> (Historically the count was measured with `-Wno-implicit-function-declaration`; that flag
> is no longer needed since Phase 8b resolved the out-param externals and inferred generic
> calls. `-I std/c` is still required so the external ABI headers are in scope.)

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

Self-host source layout (src ≈ 27.8k LOC):

| Stage | Path | LOC |
|-------|------|-----|
| Lexer | `src/mtc/lexer/` | ~1,590 |
| Parser + AST | `src/mtc/parser/*.mt` | ~4,860 |
| Pretty printers | `src/mtc/pretty_printer/*.mt` | ~2,190 |
| Semantic analyzer | `src/mtc/semantic/analyzer.mt` | ~3,880 |
| Type system | `src/mtc/semantic/types.mt` | ~710 |
| Loader | `src/mtc/loader/` | ~730 |
| IR | `src/mtc/ir.mt` | ~220 |
| Lowering | `src/mtc/lowering/lowering.mt` | ~8,830 |
| C Backend | `src/mtc/c_backend/c_backend.mt` | ~3,410 |
| Build driver | `src/mtc/build.mt` | ~160 |
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

## 2. RESUME HERE — Phase 9 COMPLETE (as of 2026-07-09)

**Phase 9 is COMPLETE. Whole-program emit-c is byte-identical between stage-1
and stage-2 (52,275 lines, 0 diffs). The bootstrap fixpoint has been reached.**

Five correctness fixes landed this session:
1. **defer lowering** — `defer` emitted at declaration site instead of scope-exit/return.
   Implemented Ruby's active_defers/local_defers model per LowerCtx DeferGroup stack.
2. **string-match-expr** — independent `if`s instead of else-if chain (keyword→identifier).
3. **string-escape decode** — parser never decoded `\n`/`\r`/`\t`/etc., so C backend
   emitted `\\n` literally.
4. **break-in-match-in-while #1** — `break` inside `match` inside `while true:` in C
   breaks the `switch`, not the loop. `ensure_generic_struct_decl_named` failed to register
   Vec[String] struct decl. Fixed with flag-based loop.
5. **break-in-match-in-while #2** — same pattern in `lower_aggregate_literal`. ir.Param
   aggregate constructors rendered as ast.Param. Fixed with flag-based loop.

Because `break`-in-`match`-in-`while` is a systemic C-lowering semantics gap (Ruby
converts such breaks to goto-labels), a scan found 26 additional latent instances
in std/ modules (net, http, terminal, etc.). These are not triggered by the self-host's
transitive import chain and are deferred to a systematic C-backend fix.

172/172 self-host tests pass throughout; all per-pipeline-stage differentials are
byte-identical (lex, parse, check, lower, emit-c).

**Next: Phase 10 — debug-guard fix + build-mode/runtime parity (deferred Phase 8 items).**

### 2.0 Phase 9 fixes landed this session

1. **defer lowering** (`2b073267`) — the self-host emitted every `defer` inline at its
   declaration site instead of at block exit and before each `return`, so scope-bound
   cleanups ran immediately. This was the direct cause of the `arena.to_cstr out of memory`
   abort (`fs.read_text`'s arena `storage` was released right after creation). Implemented
   Ruby's active_defers/local_defers model: a per-block `DeferGroup` stack on `LowerCtx`,
   flushed (reverse order) on non-terminating block exit and (all open groups, innermost
   first) before every `return`, with non-trivial return values hoisted into a temp.
   `lower_function_body` isolates the stack per function/method/proc body so lazily-
   monomorphized generic bodies do not flush the enclosing body's defers.
2. **string-match-expr** (`4d6329e5`) — `lower_str_match_expr` emitted independent `if`s
   with only the last arm carrying the wildcard as its `else`, so the last arm's `else`
   clobbered any earlier match. `keyword_kind` therefore classified every keyword as
   `identifier`. Rewrote it as a proper else-if chain (default as final else), mirroring
   Ruby and the self-host's own statement-form `lower_string_match`.
3. **string-escape decode** (`ae88ee59`) — `parse_string_content` only stripped quotes; it
   never decoded escapes, so `c"...\n"` kept a literal backslash+n which the C backend then
   re-escaped to `\\n`. Added escape decoding mirroring Ruby's `decode_escape`
   (`\n \r \t \0 \" \' \\`; unknown `\x` drops the backslash), building into an arena-leaked
   String.

### 2.1 Reproduce the current state (from a clean checkout)

```sh
# 1. Build the self-host with the Ruby compiler (stage-1 binary).
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-noguard

# 2. Self-host emits its own C, which compiles to an object file with 0 errors.
tmp/mtc-noguard emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root . > tmp/self.c
cc -std=c11 -D_GNU_SOURCE -I std/c -c tmp/self.c -o /dev/null     # => 0 errors

# 3. Self-host builds ITSELF into a native binary (stage-2). The self-host only
#    needs -luv -lpthread -lm to link; build a debug stage-2 straight from the C:
cc -std=c11 -D_GNU_SOURCE -O0 -I std/c tmp/self.c -o tmp/mtc-stage2 -luv -lpthread -lm

# 4. Stage-2 now RUNS real work. lex + parse are byte-identical to stage-1:
timeout 10 bash -c 'ulimit -v 2000000; tmp/mtc-stage2 lex tmp/hello.mt'      # works
diff <(tmp/mtc-noguard parse projects/mtc/src/mtc/lowering/lowering.mt) \
     <(tmp/mtc-stage2  parse projects/mtc/src/mtc/lowering/lowering.mt)      # identical
```

`bin/mtc test projects/mtc` => **172/172 pass**.

### 2.2 Phase 9 NEXT TARGET — differential `check`

`lex` and `parse` reach the bootstrap fixpoint (stage-2 output == stage-1 output byte-for-byte
on every self-host source file, including the 6.5k-line `lowering.mt`). Advance the
differential up the pipeline: run `tmp/mtc-stage2 check <file> --root ...` vs the Ruby-built
`tmp/mtc-noguard check ...` on self-host sources and diff. Each new divergence is the next
stage-2 miscompile to localize (differential + `gdb` on `tmp/self.c`, which IS the stage-2 C
source) and fix at its root in `lowering.mt` / `c_backend.mt`, mirroring Ruby.

### 2.3 Differential harness (Phase 9 method)

The correctness oracle is: **same `.mt` input, compare stage-1 (Ruby-built self-host) vs
stage-2 (self-built) behaviour**, and compare stage-2's emitted C vs stage-1's emitted C.
`tmp/self.c` (from step 2 above) is the exact C the stage-2 binary was built from — inspect
it directly. Bootstrap fixpoint goal: stage-2 emits byte-identical C to stage-1 for the
whole self-host source.

---

## 3. Phase 8 history (COMPLETE — kept for reference)

All of Phase 8 (self-compile C-error elimination, 493 → 0) and the native-binary milestone
are done. The full blow-by-blow is in the §5 progress checklist. The end-state:

- `mtc emit-c` of the self-host → ~48k lines of C → `cc -c` = **0 errors** (no crutch flags).
- Self-host **builds itself** into a runnable binary (argv bridge + runtime helpers + link
  flags + CLI wiring all landed).
- **172/172 self-host tests pass.**

The former "ranked path to zero" (§3.1–§3.7 clusters: prelude variant-literal prefix,
`String.create()` static returns, match-expr hoist, `ir.Expr`/`ast.Expr` collision, Map/Vec
`mt_` fallback, `.contains()` arg mismatch, scattered singletons) is **entirely resolved** —
each item is checked off with its resolving commit in §5.

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

Added this session (Phase 8 completion + native binary) — key seams for Phase 9:

- **Prelude modules are loaded**: `module_loader.check_program` calls `seed_prelude_module`
  for `std.option` / `std.result` so their real `extending` method bodies exist for
  monomorphization (mirrors Ruby's `PreludeInstaller`). Prelude variant methods
  monomorphize via `generic_receiver_info` (recovers args from collapsed `ty_named` via
  `prelude_instance_args`) + `find_generic_method` (`variant_in_source`) +
  `monomorphized_method_c_name` (global `Option_<T>_<method>` name).
- **Cross-module call resolution order** in `lower_call`'s member-access path:
  variant-arm ctor → `imported_foreign_call` (foreign → mapped C name via `lower_foreign_call`)
  → `imported_extern_call` (external → bare C name via `lower_extern_call`, `out`/`inout`
  args passed by `&arg`) → `try_inferred_generic_call` (infer type args from arg types via
  `unify_type_param`, monomorphize) → plain qualified call.
- **Generic specialization** now has two entry points: `lower_and_cache_specialization`
  (explicit AST type args) and `lower_and_cache_specialization_with_sub` (a pre-built
  `str→types.Type` substitution map, used by inferred generic calls).
- **Match expressions**: `is` desugars to a 2-arm match → `lower_expression_match` detects
  it (`is_variant_membership_arms`) and emits a pure `scrut.kind == Kind_arm` bool. Real
  `return match` hoists via `lower_match_expr_to_ref` (str/tuple/variant/enum dispatch);
  `lower_tuple_match_expr` + `tuple_pattern_condition` handle tuple scrutinees.
- **Entry point**: `build_root_main_entrypoint` handles both no-arg `main` and
  `main(args: span[str])` (emits `int main(int argc, char** argv)` + `mt_entry_argv_to_span_str`
  bridge). The bridge runtime helpers are emitted by the c_backend (`uses_entry_argv` →
  `emit_entry_argv_helpers`), which also forces `use_string_view`.
- **Build driver** (`build.mt`): `collect_link_flags` reads `link "<lib>"` directives →
  `-l<lib>`; `std_c_include_flag` adds `-I<root>/std/c`; uses `-D_GNU_SOURCE`; no
  implicit-decl crutch. CLI `build_command` passes `roots` through.

### EDITING HAZARD (learned this session)

Twice, an `edit` whose `oldString` spanned a function boundary silently deleted/duplicated a
whole adjacent function (`find_generic_function`, `emit_builtin_helpers`), producing orphaned
statement fragments. Both were caught by the next build and fixed by `git checkout <file>` +
clean re-apply. When editing near function boundaries in the ~8.8k-line `lowering.mt` or
`c_backend.mt`, prefer small anchored edits and rebuild immediately to catch clobbering.

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
- [x] Phase 8 — self-compile C-error elimination COMPLETE (**493 → 0** with `-I std/c`; G1 reached, 172/172 tests)
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
  - [x] **D1 — match expressions COMPLETE (7 → 0, G1 reached).** Solved in three coordinated parts,
        each mirroring Ruby's structure where practical:
        (1) **`is`-operator (parser + lowering).** `is` desugars to a two-arm match expr
        `[Variant.Arm -> true, _ -> false]`. First fixed a genuine **parser precedence bug**: `parse_is`
        parsed the arm pattern with `parse_expression`, so `e is A or e is B` mis-grouped as
        `e is (A or e is B)`; changed to `parse_bitwise_or` + a left-associative `while` loop, mirroring
        Ruby's `parse_is`. Then `lower_expression_match` detects the `is`-desugar shape
        (`is_variant_membership_arms`) and lowers it to a pure discriminant test
        `scrut.kind == Outer_kind_arm` — a plain bool expr that composes inside `or`/`and`/`if` with no
        statement hoisting (the self-host's `lower_expr` cannot emit setup statements mid-expression).
        Fixed `block_expression`, `specialization_target`, `null_test_refinements`.
        (2) **`return match` hoist.** `lower_stmt`'s `stmt_ret` detects an `expr_match` value, hoists it
        into a zero-init temp + switch/if-chain (shared `lower_match_expr_to_ref`), and returns the temp;
        `current_return_type` infers the result type. Fixed `kind_name` (enum), `keyword_kind` (str).
        (3) **tuple match-expr.** `lower_tuple_match_expr` + `tuple_pattern_condition` lower a tuple
        scrutinee to element-wise conjunction tests (`scrut._0 == e0 && ...`, `_` skipped), wildcard
        assigned first. Fixed `three_char_token` / `two_char_token`.
        The feared `lower_variant_match_expr` crash did **not** reproduce: the `is` cases now lower as
        pure discriminant tests (never reaching the variant-match-expr path), and §3.4 had already fixed
        the arm-payload collision that likely triggered the earlier crash. Refactored the shared body
        builder into `lower_match_expr_to_ref` (str/tuple/variant/enum dispatch), used by both
        `let x = match` and the return hoist. 172/172 tests pass. **This reaches G1: the self-host
        emit-c output compiles to 0 cc errors.**
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
  - [x] **`std_map_Option_` variant-literal prefix** (§3.1) — resolved by Seam B §3.1 (prelude method monomorphization).
  - [x] **`String.create()` static method return type** (§3.2) — resolved by Seam A.
  - [x] **Match-expression hoist** (§3.3) — resolved by D1 (is-operator + return-match hoist + tuple match-expr).
  - [x] **`mtc_ir_Expr` vs `ast_Expr` pointer mismatch** (§3.4) — resolved (arm-payload collision guard).
  - [x] **Declared void / `mt_` fallback** (§3.5) — resolved by Seam A (chained/read receiver typing).
  - [x] **Map/vec `.contains()` arg mismatches** (§3.6) — resolved by Seam C (ref[T] implicit borrow).
  - [x] **Scattered singletons** — resolved by Seam E (7 fixes).
  - [x] **Phase 8b (compile-clean): self-emitted C compiles to an object file with 0 errors.** Beyond
        `cc -c` with the `-Wno-implicit-function-declaration` crutch, the self-host emit-c output now
        compiles cleanly (`cc -std=c11 -D_GNU_SOURCE -I std/c -c` → 0 errors, no implicit declarations).
        Two fixes: (a) **out-param cross-module external calls** — `imported_extern_call` now carries the
        params and `lower_extern_call` passes `out`/`inout` args by address (`&arg`), so `mt_fs_read_text`
        etc. use the bare C name with the right pointer args (mirrors Ruby's
        `lower_foreign_pointer_argument_value`); (b) **inferred generic function calls** — `heap.release(x)`
        (`release[T]`) now infers `T` from the argument (`try_inferred_generic_call` + `unify_type_param`
        peeling ptr/const_ptr/ref/span/nullable) and monomorphizes per T
        (`std_mem_heap_release_ubyte/_str/_ptr_uint`), via the new sub-map-driven
        `lower_and_cache_specialization_with_sub`. 172/172 tests pass.
  - [x] **Milestone: `mtc build projects/mtc` produces a runnable native binary — REACHED.** The
        self-host binary compiles+links itself into a working executable (stage-2 runs, prints help).
        Four coordinated pieces, all mirroring Ruby:
        1. **argv main bridge** — `build_root_main_entrypoint` now supports `main(args: span[str])`,
           emitting `int main(int argc, char** argv)` + `mt_entry_argv_to_span_str` conversion + cleanup.
        2. **runtime helper emission** — c_backend emits `mt_entry_argv_to_span_str` /
           `mt_free_entry_argv_strs` (`uses_entry_argv` detector), pulls in `<stdlib.h>`/`<string.h>`, and
           forces `use_string_view` so `mt_str`/`mt_span_str` are defined.
        3. **link flags** — `build.mt` collects `-l<lib>` from `link` directives (`link "uv"` → `-luv`),
           adds `-I<root>/std/c` + `-D_GNU_SOURCE`, and drops the `-Wno-implicit-function-declaration` crutch.
        4. **CLI wiring** — `build_command` passes roots to `build_driver.build`; help updated.
        KNOWN ISSUE (→ Phase 9): stage-2 aborts at runtime on real work (`arena.to_cstr out of memory`) —
        a correctness bug in the generated code / runtime, not a build/link issue. This is exactly the
         bootstrap-fixpoint work of Phase 9.
- [x] Phase 9 — correctness verification (differential C + bootstrap fixpoint). COMPLETE:
      stage-2 runtime abort FIXED (defer lowering); string-match-expr + string-escape decode
      + break-in-match-in-while x2 fixed. Stage-2 `lex`, `parse`, `check`, and whole-program
      `emit-c` are byte-identical to stage-1 (52,275 lines, 0 diffs). 172/172 tests pass.
- [ ] Phase 10 — debug-guard fix + build-mode/runtime parity

---

## 6. Deferred items

- Guards and equality patterns in struct-pattern match arms.
- Build-mode codegen parity (cache, debug-guards, line directives, include set).
- Debug-guard false-positive on large byte-scan loops.
- `as cstr` for non-literal values.
- proc selective retain / scope-exit release.
- SoA: deferred indefinitely.
- CPS state machine for async/await.
- Capture analysis for parallel/detach (currently no-capture only).
- Struct-less programs don't emit span typedefs (`mt_span_str` undefined) and the
  `c.EOF`-style external-constant const initializer mis-emits — both surfaced when
  `build`-ing a tiny non-self-host program; not on the self-host critical path.
- Byte-identical-C hardening (deferred `_static` nominal naming, etc.) — for the Phase 9
  fixpoint oracle.

---

## 6b. Parity gap audit (2026-07-09) — what "self-host complete" does and does NOT mean

**What works (verified):** The self-host reaches the self-compile fixpoint. stage-1
(Ruby-built) → stage-2 (self-built) → stage-3 (stage-2-built) all produce **byte-identical
C** for the self-host source, and every stage runs `lex`/`parse`/`check` correctly. The
self-host also compiles+builds+runs ordinary non-async programs (Vec/Map/String/generics/
match/defer/tuples), verified by build-and-run.

**What does NOT work yet (self-host is NOT at 100% parity with the Ruby compiler).**
The self-host is complete *for the subset its own source uses*, but general-program parity
has holes. Concrete, reproduced gaps (self-host vs Ruby, 2026-07-09):

| Feature | Symptom in self-host | Ruby behaviour |
|---------|---------------------|----------------|
| `async`/`Task[T]` | lowering aborts: `could not find generic function decl for Task`; analyzer reports `unknown field Task.frame`, `unknown method Task.ready/take_result/release` | full CPS-ish Task runtime lowered |
| `atomic[T]` | emit-c is a **stub**: emits `atomic_int` (undefined) + undeclared `<mod>_atomic_store/add/load` calls + `void`-typed result | `_Atomic int32_t` + `__atomic_store_n`/`__atomic_fetch_add`/`__atomic_load_n` |
| `emit` (compile-time codegen) | lowering aborts: `unsupported statement` | emits the generated declarations |
| `events` (general programs) | emit-c returns 0 but produced C does **not** compile (`expected expression before <event>`) | valid subscription/emit C |
| `parallel for` (general programs) | emit-c returns 0 but produced C does not compile (`xs undeclared` — capture bug) | valid libuv chunk dispatch |
| `dyn[I]` (general programs) | emit-c returns 0 but produced C does not compile (`mt_vtable_..._Shape undeclared` — vtable global not emitted for single-file programs) | vtable struct+global emitted |
| baseline `examples/language_baseline.mt` | self-host `check` fails and `emit-c` aborts (via the async runtime) | Ruby checks clean (warnings only) |

Note several of these "return 0 but bad C" cases match §6 deferred items (struct-less
programs don't emit span typedefs; scattered singletons). The self-host passes its 181
in-language tests and self-compiles because its **own source avoids** these paths (no
`atomic`, no `emit`, careful async usage only inside std it does not re-lower for itself).

**Remaining work for true 100% parity** (rough order): (1) `atomic[T]` proper lowering
(`_Atomic`/`__atomic_*`); (2) async/`Task[T]` lowering + runtime; (3) `emit` statement
lowering; (4) single-file-program codegen completeness for events / parallel-for capture /
dyn vtable emission (the general-program vs self-host-source divergence); (5) then re-run
`examples/language_baseline.mt` end-to-end as the parity gate. The differential oracle stays
the method: compare self-host emit-c to Ruby emit-c per feature, fix the root in
`lowering.mt`/`c_backend.mt` mirroring Ruby.

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
