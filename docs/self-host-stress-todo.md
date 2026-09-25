# Self-host: build `projects/stress` — remaining work

Goal: `build/stage2/mtc build projects/stress` compiles, links, and runs with
output matching the Ruby host compiler's build of the same project.

Status as of `ea010947`: the **front end is clear**. `projects/stress` parses,
analyzes (zero diagnostics) and lowers without aborting. Everything that
remains is codegen: declarations that are referenced but never emitted, plus
one malformed construct.

## How to reproduce and localize

```sh
# 1. Build the self-host compiler from the current sources
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o build/stage2/mtc

# 2. Build the target project
timeout 300 bash -c 'ulimit -v 20000000; \
  build/stage2/mtc build projects/stress -I . --no-cache -o /tmp/stress_self'

# 3. Get exact C line numbers.  The driver's source mapping is approximate
#    (it points at the call site, not the defect); the saved C does not lie.
C=$(ls -t /tmp/mtc_build_stress_self_*.c | head -1)
cc -fsyntax-only -I . -I std -I std/c "$C" 2>&1 | grep -A4 "error:" | head -30
```

Always run the fixed-point gate after every change, never only at the end of a
batch — two changes in the session that produced this list looked correct at
the CLI level and broke the compiler's own bootstrap:

```sh
tools/bootstrap.sh -j 16     # must print: stage2.c == stage3.c (fixed point holds)
```

## TODO

### 1. `mt_proc_*` struct never declared for proc-typed type aliases

* **Symptom**: `error: unknown type name 'mt_proc_bool_ulong'` — from the emitted
  `typedef mt_proc_bool_ulong engine_types_Predicate;`
  (`projects/stress/src/engine/types.mt`). Only `mt_proc_bool_int` exists.
* **Cause**: proc value structs are registered only when a proc *literal* is
  lowered (three sites in resolver/alias handling all call
  `proc_ensure_struct_decl`). The type-alias emission pass in
  `projects/mtc/src/mtc/lowering/lowering.mt` (~lines 558-563) rewrites a
  proc-typed alias target to
  `ty_named(module_name = "", name = proc_type_name_from_signature(tv))`
  and pushes an `ir.TypeAlias` **without registering the declaration**. An alias
  that is only ever referenced as a typedef (never through
  `resolve_type_ref`'s alias branch) therefore emits a typedef with no
  definition.
* **Why it cannot simply call the existing helper**: that pass has no
  `LowerCtx`, and `proc_ensure_struct_decl` needs one (it builds fields and
  pushes into `ctx.pending_proc_structs`).
* **Fix**: confirm whether the alias pass is in the same function as the
  `lower_module(…, ref_of(monomorphized_structs), …)` /
  `dedup_append_structs(…)` code (~lines 470-500); it appears to be, which
  puts the IR's struct collection in scope. Then factor the
  `{ env, invoke, release, retain }` field shape out of
  `proc_ensure_struct_decl` into a `LowerCtx`-free helper and append the struct
  through the same `dedup_append_structs` path. Otherwise register at
  alias-lowering time, where a `LowerCtx` exists.
* **Verify**: the `mt_proc_bool_ulong` error disappears from
  `cc -fsyntax-only`; fixed point holds.

### 2. dyn interface symbols are not canonical

* **Symptom**: `error: unknown type name 'mt_dyn_Identifiable'; did you mean
  'mt_dyn_ifaces_Identifiable'?` (same for `Damageable`).
* **Cause**: one interface is written two ways — bare (`dyn[Identifiable]`
  inside `projects/stress/src/engine/interfaces.mt`) and through an import alias
  (`dyn[ifaces.Identifiable]` in `main.mt`). `ea010947` sanitized the names
  (dots are not valid in C identifiers, previously
  `struct mt_vtable_ifaces.Identifiable { … }`), but the two spellings still
  produce two different symbols.
* **Fix**: canonicalize on the interface *declaration's* module plus name —
  `InterfaceAnalysis.module_name`, the field the lookup deliberately leaves as
  written — and route every `mt_dyn_*` / `mt_vtable_*` construction through one
  helper that uses it. These sites must change **together**
  (`c_backend.mt` ~2033 and the several `j3("mt_dyn_", …)` /
  `j3("mt_vtable_", …)` sites in `lowering.mt`): changing only that field is
  what broke the bootstrap in an earlier attempt.
* **Verify**: both spellings emit the same symbol; fixed point holds.

### 3. Monomorphized generic variant instance not collected

* **Symptom**: `error: expected specifier-qualifier-list before
  'engine_types_Outcome_int_engine_types_EngineError'` — the type is referenced
  by a field but never declared.
* **Fix**: mirror how struct instances reach `monomorphized_structs`; the
  program-lowering call already passes `ref_of(monomorphized_variants)`, so the
  gap is in what feeds that collection.

### 4. Malformed C in the dyn / `adapt[…]` helper

* **Symptom**: `error: expected ';', ',' or ')' before '->'` at generated-C
  line 1430 (near the dyn uses at 1434-1435).
* **Fix**: re-read that line once 2 and 3 land — it is likely the same code
  path and may fall out of 2.

### 5. End-to-end verification and gates

* `build/stage2/mtc build projects/stress` succeeds; run the binary and compare
  stdout + exit status against the Ruby host's build of the same project.
* Then: `tools/bootstrap.sh` (fixed point), the self-test suite
  (`build/stage2/mtc test test/mt -I .`) and `rake "cli:parity"` — the latter
  two were last green at the parent of `18886806`.

## Already fixed on this path (do not re-investigate)

| Commit | Fix |
| --- | --- |
| `ade972cc` | guard-value projection (single storage local), match temp naming, absent-else shape |
| `a543165e` | `defer` inside `unsafe:` / nested blocks replayed after the block closed |
| `f3651dbd` | qualified destructuring (`let types.Transform(x, y, rot) = t`); `packed`/`align`/`deprecated`/`test`/`expect_fatal` builtin attributes |
| `47684ed8` | type-parameter method fallback (`entity_killed.emit(entity.id_value())`) |
| `18886806` | `dyn[alias.Interface]` lookup resolved through the import alias (`dyn lowering: interface not found`) |
| `ea010947` | dyn interface names sanitized for C (dotted alias leaked into symbols) |

Regression tests are still owed for the `defer`-scope and dyn-alias fixes (both
produced crashes rather than diagnostics) and for qualified destructuring and
the type-parameter fallback. Test location: `test/mt/`.
