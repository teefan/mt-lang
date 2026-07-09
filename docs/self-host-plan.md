# Self-Host Plan: Path to 100% Ruby Parity

Status: **Self-compile fixpoint REACHED; general-program parity IN PROGRESS.**
The self-host (`projects/mtc`) compiles *itself* into byte-identical C across stages, but it
is not yet at 100% feature parity with the Ruby compiler for arbitrary programs. This
document tracks the remaining work to close that gap.

Last updated: 2026-07-09

---

## 1. Current state

### 1.1 What works (verified)

- **Self-compile fixpoint.** stage-1 (Ruby-built self-host) → stage-2 (self-built) →
  stage-3 (stage-2-built) all emit **byte-identical C** (52,275 lines, 0 diffs) for the
  self-host source. Each stage runs `lex` / `parse` / `check` correctly, and per-pipeline
  differentials (`lex`, `parse`, `check`, `lower`, `emit-c`) are byte-identical stage-1 vs
  stage-2 on every self-host source file.
- **Ordinary programs** using Vec / Map / String / generics / match / defer / tuples /
  detach compile, build, and run correctly (verified build-and-run).
- **All 181 self-host in-language tests pass** (`bin/mtc test projects/mtc`).

### 1.2 What does NOT work yet (the parity gap)

The self-host is complete *for the subset its own source uses*. General-program parity has
holes — reproduced 2026-07-09 by comparing self-host emit-c against Ruby emit-c:

| Feature | Self-host symptom | Ruby behaviour (target) |
|---------|-------------------|-------------------------|
| `atomic[T]` | emit-c stub: emits `atomic_int` (undefined) + undeclared `<mod>_atomic_store/add/load` calls + `void`-typed result | `_Atomic int32_t` + `__atomic_store_n` / `__atomic_fetch_add` / `__atomic_load_n` |
| `async` / `Task[T]` | lowering aborts: `could not find generic function decl for Task`; analyzer reports `unknown field Task.frame`, `unknown method Task.ready/take_result/release` | full Task runtime lowered |
| `emit` (compile-time codegen) | lowering aborts: `unsupported statement` | emits generated declarations |
| `events` (general programs) | emit-c returns 0 but produced C does not compile (`expected expression before <event>`) | valid subscription/emit C |
| `parallel for` (general programs) | emit-c returns 0 but produced C does not compile (`xs undeclared` — capture bug) | valid libuv chunk dispatch |
| `dyn[I]` (general programs) | emit-c returns 0 but produced C does not compile (`mt_vtable_..._Shape undeclared` — vtable global not emitted for single-file programs) | vtable struct + global emitted |
| `examples/language_baseline.mt` | `check` fails and `emit-c` aborts (via async runtime) | Ruby checks clean (warnings only) |

The self-host self-compiles despite these because its **own source avoids** them (no
`atomic`, no `emit`, careful async usage confined to std it does not re-lower for itself).

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

### Phase A — `atomic[T]` (smallest, self-contained)
- **Analyzer**: model `atomic[T]` methods `load`/`store`/`add`/`sub`/`exchange` with correct
  return types (currently `store`/`add` resolve to `void`).
- **Lowering**: emit `__atomic_load_n`/`__atomic_store_n`/`__atomic_fetch_add`/
  `__atomic_fetch_sub`/`__atomic_exchange_n` with the seq-cst memory-order constant (Ruby
  uses `5`).
- **C backend**: render the `atomic[T]` type as `_Atomic <c_type(T)>` (not `atomic_int`).
- **Gate**: `atomic_demo`-style program builds and runs; diff self-host vs Ruby emit-c.

### Phase B — `emit` (compile-time code generation)
- **Lowering**: implement the `emit` statement inside `const function` / `inline` bodies —
  collect emitted declarations and splice them into the program (mirror Ruby's
  compile-time codegen collection). Currently hits `unsupported statement`.
- **Gate**: `emit`-based program (`emit function ...`) builds and runs; diff vs Ruby.

### Phase C — single-file general-program codegen completeness
These already work inside the self-host's own build but mis-emit for standalone programs
because a support decl/typedef is skipped when the triggering construct is absent from the
rest of the module.
- **`dyn[I]`**: emit the vtable struct + vtable global for a `dyn` used in an otherwise
  minimal program (currently `mt_vtable_..._Shape undeclared`).
- **`events`**: fix event subscription/emit C emission for a standalone event program
  (`expected expression before <event>`).
- **span typedefs / external-constant initializers**: struct-less programs don't emit
  `mt_span_str` etc.; `c.EOF`-style external-constant const initializers mis-emit.
- **Gate**: each minimal single-file program builds+runs; diff vs Ruby.

### Phase D — `break`/`continue` in `match`-in-loop (systemic)
- **C backend / lowering**: when a loop body contains a `match`, and an arm uses
  `break`/`continue`, emit a loop-exit/continue `goto` label and translate the break/continue
  to `goto` (mirror Ruby). Remove the flag-based workarounds once the general mechanism lands.
- **Gate**: the 26 `std/` instances lower correctly; add a focused differential test.

### Phase E — `parallel for` capture (general programs)
- **Lowering**: fix capture emission so array/scalar captures are threaded into the worker
  chunk correctly (currently `xs undeclared` for a standalone parallel loop). Ruby passes
  arrays by pointer, spans/scalars by value.
- **Gate**: standalone `parallel for` program builds+runs; diff vs Ruby.

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
- Cache, debug-guards, line directives, include-set parity between self-host `build` and
  Ruby `build`.
- Debug-guard false-positive on large byte-scan loops.
- `as cstr` for non-literal values; proc selective retain / scope-exit release.
- Byte-identical-C hardening (e.g. deferred `_static` nominal naming).

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
