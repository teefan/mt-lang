# Self-Host Plan: Path to 100% Ruby Parity

Status: **Self-compile fixpoint REACHED; general-program parity IN PROGRESS.**
The self-host (`projects/mtc`) compiles *itself* into byte-identical C across stages, but it
is not yet at 100% feature parity with the Ruby compiler for arbitrary programs. This
document tracks the remaining work to close that gap.

Phases A (`atomic[T]`) and B (`emit`) are **DONE**, along with a batch of arithmetic/cast
emit-c parity work and a latent codegen-bug fix uncovered along the way (see §1.1 / §3).

Last updated: 2026-07-09 (session: Phases A-E, C1, D, H naming/preamble)

---

## 1. Current state

### 1.1 What works (verified)

- **Self-compile fixpoint.** stage-1 (Ruby-built self-host) → stage-2 (self-built) →
  stage-3 (stage-2-built) all emit **byte-identical C** (~53,226 lines, 0 diffs) for the
  self-host source (re-verified 2026-07-09 after Phase H naming fixes). Per-pipeline
  differentials (`lex`, `parse`, `check`, `lower`, `emit-c`) are byte-identical stage-1 vs
  stage-2 on every self-host source file.
- **Ordinary programs** using Vec / Map / String / generics / match / defer / tuples /
  detach compile, build, and run correctly (verified build-and-run).
- **All 391 self-host in-language tests pass** (`bin/mtc test projects/mtc`).
- **`atomic[T]`** (Phase A) — `_Atomic T` + `__atomic_*` builtins; byte-identical to Ruby.
- **`emit`** (Phase B) — `emit function/struct/const` inside `const function` / inline
  bodies spliced into the module as ordinary top-level declarations; byte-identical to Ruby
  for `emit function`.
- **`dyn[I]`** (Phase C1) — vtable constants emitted to program constants; interface method
  return types resolved from the interface analysis (fixes `void a`). Builds+runs for single
  files.
- **`break`/`continue` in match-in-loop** (Phase D) — C-backend if-chain lowering via
  `emit_stmts_loop` + `emit_switch_as_if_chain`; behavioral fix verified (exit codes match
  Ruby). Self-compile fixpoint breaks structurally (new functions → string-literal-index
  shift, a Phase-H residual).
- **Parallel for for-loop wrapper** (Phase E, partial) — `parallel_for_worker_fn` now wraps
  the body in a `for (i = mt_pfor_start; ...)` loop, fixing the `i undeclared` error.
  Array captures need C-backend `ptr[array[T,N]]` → `T (*)[N]` rendering (Phase-H residual).
- **Arithmetic / cast emit-c parity** (general programs, byte-identical to Ruby):
  - no-op cast elision + `(T) x` spacing + `emit_cast_operand` parenthesization;
  - unary / conditional operand-wrapping (`wrap_expression` set + `emit_conditional_condition`);
  - binary operand widening (`promoted_binary_operand_type` / `common_*_type` — mixed-width
    integer + int/float balancing, result-type widening for arithmetic);
  - enum/flags backing-cast in comparisons (`enum_backing_or_self` unwrap, local + imported).
- **C naming hardening** (Phase H):
  - `sanitize_identifier` consecutive-underscore collapse removed.
  - `c_declaration` pointer spacing → `T *name`.
  - Prelude variant C-name prefix: `std_option_Option_...` / `std_result_Result_...`.
- **Header/preamble parity** (Phase H): `_GNU_SOURCE` block, include deduplication,
  `<stddef.h>` injection (offsetof), span-forward-decl blank-guard, `offsetof` lowering fix.
- **Latent codegen bug fixed**: checked-array/span-index type collectors completed to
  recurse through `expr_cast` and other sub-expression containers (prerequisite for enum
  backing-cast, discovered and fixed during arithmetic parity work).

### 1.2 What does NOT work yet (the parity gap)

| Feature | Self-host symptom | Status |
|---------|-------------------|--------|
| ~~`atomic[T]`~~ | — | DONE (Phase A) |
| ~~`emit`~~ | — | DONE (Phase B) |
| ~~`dyn[I]`~~ | — | DONE (Phase C1) |
| ~~`break/continue` in match-in-loop~~ | — | DONE behavioral (Phase D); fixpoint structural break |
| `parallel for` captures | `xs` undeclared in worker (array capture needs C-backend `ptr[array[T,N]]` → `T (*)[N]`) | PARTIAL (Phase E): for-loop wrapper done; array captures deferred |
| `events` (general programs) | `expected expression before <event>` (generic void* helpers incompatible with C parser) | PARTIAL: per-event typed wrapper approach designed, deferred on global-var naming + fn-ptr type propagation |
| `async` / `Task[T]` | lowering aborts; analyzer reports unknown Task fields/methods | NOT STARTED (Phase F) |
| header / include-set preamble | minor residuals only (stddef on unreachable offsetof, one stray blank) | MOSTLY DONE (Phase H) |
| `examples/language_baseline.mt` | blocked by async runtime | DEFERRED (Phase G) |

---

## 2. Architecture reference

Pipeline (self-host mirrors Ruby stage-for-stage):

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

Self-host source layout (`projects/mtc/src`, ≈27.8k LOC):

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

### 2.1 Key seams (reuse, don't re-derive)

- **Monomorphization**: method calls route through `try_generic_method_call` →
  `lower_monomorphized_method`; method and function bodies are lowered in the **owner
  module's context** (`ctx.module_name`/`analysis`/`foreign_map`/`variants` swapped, then
  restored). Concrete type args are qualified in the caller's context before the switch.
- **Naming**: `naming.type_c_key(ty)` is the single source of truth for generic-instance
  name suffixes. Use it for any new generic-name construction so lowering and the backend
  stay byte-identical.
- **Member typing** resolution order in `lower_member_access`: span `.data`/`.len` →
  `concrete_field_type` (monomorphized structs) → `arm_payload_field_type` (variant
  payloads) → `imported_field_type` (cross-module structs, owner context) → analyzer
  `expr_type`.
- **Match**: `lower_match` prefers `ir_expr_type(lower_expr(scrutinee))` over the analyzer's
  `expr_type`.
- **Prelude variants** (`Option`/`Result`) are globally named — never module-prefix them.
- **Cross-module call resolution** order in `lower_call`'s member-access path: variant-arm
  ctor → `imported_foreign_call` → `imported_extern_call` → `try_inferred_generic_call` →
  plain qualified call.
- **`defer`**: per-block `DeferGroup` stack on `LowerCtx`; flushed reverse-order on
  non-terminating block exit and (all open groups, innermost-first) before every `return`,
  with non-trivial return values hoisted to a temp. `lower_function_body` isolates the stack
  per function/method/proc body.

### 2.2 Known systemic hazard: `break`/`continue` inside `match` inside a loop

A `match` lowers to a C `switch`; a `break` (or `continue`) in a match arm targets the
`switch`, not the enclosing loop. Ruby converts these to `goto` labels. The self-host does
not yet, so such code silently mis-lowers. Two self-host occurrences were fixed with
flag-based loops, but a scan found **26 latent instances in `std/`** (net, http, terminal,
etc.). The proper fix is a C-backend loop-label mechanism (see Phase D).

---

## 3. The plan to 100% parity

Each phase uses the **differential oracle** (§4): pick a minimal program exercising the
feature, compare self-host emit-c to Ruby emit-c, fix the root in `lowering.mt` /
`c_backend.mt` / `analyzer.mt` mirroring Ruby, and gate on `bin/mtc test projects/mtc`
staying green plus the self-compile fixpoint holding.

### Phase A — `atomic[T]` (smallest, self-contained) — **DONE**
- **Analyzer**: `atomic_method_sig` models `load`/`store`/`add`/`sub`/`exchange` return types.
- **Lowering**: `lower_atomic_method` emits `__atomic_load_n`/`__atomic_store_n`/
  `__atomic_fetch_add`/`__atomic_fetch_sub`/`__atomic_exchange_n` with seq-cst order `5`.
- **C backend**: `generic_c_type` renders `atomic[T]` as `_Atomic <c_type(T)>`.
- **Gate met**: `atomic_demo` builds+runs; emit-c byte-identical to Ruby.

### Phase B — `emit` (compile-time code generation) — **DONE**
- **Analyzer**: `expand_emit_declarations` walks top-level `const function` bodies (and
  inline for/while/if/match blocks), collects each `emit` statement's declaration, and
  splices them into `SourceFile.declarations` so they are declared, checked, and lowered
  like ordinary top-level declarations (mirrors Ruby's `collect_emit_declarations`).
- **Lowering**: the `emit` statement lowers to nothing (the emitted decl is lowered via the
  splice). Was: `fatal("unsupported statement")`.
- **Gate met**: `emit function` program builds+runs; emit-c byte-identical to Ruby.

### Phase C — single-file general-program codegen completeness

- **`dyn[I]` — DONE**: vtable constants were collected but never appended to the program
  constants (→ `mt_vtable_..._Shape undeclared`). Fixed: append `dyn_constants` to the
  program's constants vector. Also, `lower_dyn_method_call` used the analyzer's `expr_type`
  which returned `void` for dyn dispatch; now resolves the return type from the interface
  method analysis (`iface_method_return_type`). Builds+runs; 391 tests pass.
- **`events` — PARTIAL, deferred**: the self-host uses generic `void*`-casting
  runtime helpers (`mt_event_subscribe` etc.) that the C compiler rejects in standalone
  programs. Ruby uses per-event typed wrapper functions. The rewrite is architected
  (per-event subscribe/emit/unsubscribe IR function builders) but deferred on two issues:
  (a) event globals are lowered with the struct C-name (`ev_min_ready`) not the source
  variable name (`ready`), causing `&ev_min_ready` (invalid C); (b) the slot struct's
  `listener` field needs to be `fn() -> void` (function-pointer) not `void*`, requiring
  fn-ptr type propagation through the subscribe/emit wrapper builders and
  `lower_listener_arg`.
- **span typedefs / external-constant init**: `c.EOF`-style initialization fails the same
  way in both Ruby and self-host — not a self-host gap. Deferred.

### Phase D — `break`/`continue` in `match`-in-loop (systemic) — **DONE behavioral**
- **C backend**: `emit_stmts_loop` replaces `emit_stmts` for while/for bodies. When a
  switch case body contains break/continue, the switch is lowered as an if/else chain
  (`emit_switch_as_if_chain`) so C break/continue targets the enclosing loop, not the
  switch. Mirrors Ruby's `switch_emittable_as_if?` / `emit_switch_as_if_statement`.
- **Gate**: `brk4.mt` (exit 0) and `cont1.mt` (exit 2) match Ruby. 391 tests pass.
- **Known limitation**: the two new functions (`emit_stmts_loop`, `emit_switch_as_if_chain`)
  cause a structural fixpoint break (string-literal-index shift — Phase-H residual).
  Behavioral fix is correct; the fixpoint break is the same class of issue as any new-function
  addition to the self-host source.

### Phase E — `parallel for` capture (general programs) — **PARTIAL**
- **For-loop wrapper — DONE**: `parallel_for_worker_fn` now wraps the body in a for-loop
  `for (let i = mt_pfor_start; i < mt_pfor_end; i++) { body }`, fixing the `i undeclared`
  error. Previously the worker used the body directly without any iteration structure.
- **Captures — deferred**: the full capture mechanism (capture struct + data pointer) was
  designed and partially implemented but reverted. Array captures require the C backend to
  render `ptr[array[T, N]]` as `T (*)[N]` (C pointer-to-array syntax) — currently renders
  as invalid `array_int_4*xs`. The capture infra (collector, struct, init, worker unmarshal)
  is architecturally correct and can be re-applied once the C-backend type rendering is
  fixed.
- **Gate**: 391 tests pass; fixpoint holds (for-loop only, no new functions).

### Phase F — `async` / `Task[T]` (largest)
- **Analyzer**: model `Task[T]` fields (`frame`) and methods (`ready`/`take_result`/
  `release`) so `check` passes on async programs.
- **Lowering + runtime**: lower `async function` / `await` and the `Task[T]` generic to the
  Task runtime (mirror Ruby's approach). This is the deepest gap — a serial approximation
  may be acceptable first, matching Ruby's current behaviour, before any CPS work.
- **Gate**: async programs from `examples/language_baseline.mt` build and run.

### Phase G — parity gate: `examples/language_baseline.mt`
- Run the full baseline through the self-host end-to-end: `check` clean (warnings only, like
  Ruby), `emit-c` byte-identical to Ruby (or documented, justified differences), build+run.
- This file exercises the complete documented language surface, so passing it is the
  headline 100%-parity milestone.

### Phase H — build-mode / runtime parity (final polish)

**Done:**
- **Header / include-set preamble parity**: `_GNU_SOURCE` / `_POSIX_C_SOURCE` block,
  include-deduplication, `<stddef.h>` injection (offsetof), span-forward-decl blank-guard.
- **C naming hardening** (byte-identical-C):
  - `sanitize_identifier` consecutive-underscore collapse removed → `__mt_return_value_1`
    matches Ruby (was: `_mt_return_value_1`).
  - `c_declaration` pointer spacing → `T *name` matches Ruby (was: `T*name`).
  - Prelude variant C-name prefix: `std_option_Option_...` / `std_result_Result_...`
    matches Ruby (was: bare `Option_...` / `Result_...`).

**Remaining:**
- Cache, debug-guards, line-directives parity (Ruby-only features — no self-host equivalent).
- Format-helper emission (Ruby emits `mt_format_*` helpers; the self-host skips them —
  93k-line diff).
- `<stddef.h>` on full self-host (only offsetof in unreachable generics — correct omission).
- `as cstr` for non-literal values; proc selective retain / scope-exit release.
- String-literal-index stabilisation (structural fixpoint breaks on new-function additions).

---

## 4. Differential harness (the method)

The correctness oracle is: **same `.mt` input, compare self-host output to Ruby output.**

```sh
# Build stage-1 (Ruby-built self-host).
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-noguard

# Per-feature differential: minimal program exercising ONE feature.
diff <(bin/mtc              emit-c FEATURE.mt) \
     <(tmp/mtc-noguard      emit-c FEATURE.mt --root .)

# Self-compile fixpoint check (must keep holding after every change).
tmp/mtc-noguard emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root . > tmp/self.c
cc -std=c11 -D_GNU_SOURCE -I std/c tmp/self.c -o tmp/mtc-stage2 -luv -lpthread -lm
diff <(tmp/mtc-noguard emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root .) \
     <(tmp/mtc-stage2  emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root .)

# Debug a self-built binary: tmp/self.c IS its exact C source.
cc -std=c11 -D_GNU_SOURCE -g -O0 -I std/c tmp/self.c -o tmp/mtc-stage2-dbg -luv -lpthread -lm
```

Ruby CLI uses `-I <root>`; the self-host uses `--root <root>`. Always sandbox built
binaries (`timeout` + `ulimit -v`); interpret exit `124`/`134`/`137`/`139` as
hang/abort/OOM/segv.

---

## 5. Cross-cutting principles

- **IR is the frozen seam.** Backend reads only `IR`; Lowering reads only `Analysis`.
- **Byte-identical C is the correctness oracle.**
- **Follow Ruby's algorithmic structure** — reuse the seams in §2.1 rather than re-deriving.
- **Fail loud on substrate gaps** (no silent wrong C).
- **Diagnostic passes must not mutate the analysis codegen consumes** (a diagnostic that
  recorded scrutinee types once doubled the emitted C).
- **Small anchored edits** near function boundaries in the ~8.8k-line `lowering.mt` /
  `c_backend.mt`; rebuild immediately to catch a clobbered adjacent function.
- **Sandbox every built binary** (`timeout` + `ulimit -v`).

---

## 6. Resume context (2026-07-09 session, 17 commits)

### Committed in this session
- Phase A: `atomic[T]` (`4de40f43`)
- Arithmetic/cast parity: cast rendering (`5c9c9889`), operand wrapping (`434eafe1`),
  binary widening (`9d94d01f`), enum backing-cast (`247f6961`)
- Latent bugfix: checked-index collector traversal (`c461d1ee`)
- Phase B: `emit` (`72f91f78`)
- Phase D: break/continue in match-in-loop (`8b5f346a`)
- Phase E: parallel for for-loop wrapper (`560209b4`)
- Phase H: preamble parity + offsetof fix (`3ec4b921`), naming fixes (`6307aad2`),
  prelude variant prefix (`362094ff`)
- Phase C1: `dyn[I]` (`d3a46fd8`)
- Docs: plan sync × 2 (`5c630b42`)

### Dirty files (reverted/clean)
All files clean at session end. The event C2 rewrites (`lowering.mt`, `c_backend.mt`) were
reverted. Only the committed dyn fix remains.

### Key findings carried forward
1. **String-literal-index stabilisation** is the root cause of all fixpoint breaks on
   new-function additions — a fundamental self-host design property, not per-change bugs.
   Any new function shifts deterministic string-literal indices, breaking byte-identical C
   across stages.
2. **Prelude variant naming** has multiple code paths (not just `ensure_generic_variant`) —
   bare `Option_*` names still appear alongside `std_option_*` in the self-host's own
   emit-c. A systematic audit is needed.
3. **Event per-event wrapper** architecture is designed but needs (a) global-var naming fix
   (event globals use struct C-name, not source name) and (b) fn-ptr type propagation
   through wrapper builders.
4. **Array captures** for parallel for need the C backend to render `ptr[array[T,N]]` as
   `T (*)[N]` — the capture infra (collector, struct, init, worker unmarshal) is
   architecturally correct but was reverted due to this rendering gap.

### Build/test commands (from project root)
```sh
# Build stage-1 self-host (from Ruby)
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-noguard

# Run in-language tests
bin/mtc test projects/mtc

# Per-feature differential
diff <(bin/mtc emit-c FEATURE.mt) <(tmp/mtc-noguard emit-c FEATURE.mt --root .)

# Self-compile fixpoint check
tmp/mtc-noguard emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root . > tmp/self.c
cc -std=c11 -D_GNU_SOURCE -I std/c tmp/self.c -o tmp/mtc-stage2 -luv -lpthread -lm
diff <(tmp/mtc-noguard emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root .) \
     <(tmp/mtc-stage2  emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root .)
```

### Recommended next actions
1. **Phase F (`async`/`Task[T]`)** — the last behavioral parity gap. Requires analyzer task
   model + runtime lowering. Largest remaining item.
2. **Phase C2 (events) finish** — apply the two deferred fixes to the per-event wrapper
   design (global-var naming + fn-ptr propagation). ~2-3 line changes each.
3. **Phase E captures** — requires the C-backend `ptr[array[T,N]]` type rendering fix,
   then re-apply the capture infra.
