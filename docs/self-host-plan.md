# Self-Host Plan: Path to 100% Ruby Parity

Status: **Self-compile fixpoint REACHED; general-program parity ACTIVE.**
Baseline emits C without crashes (3,707 lines); 136 C compilation errors remain (down from 271).

Last updated: 2026-07-10 (sessions: Phase G systematic fixes, fn-proc, inline-for, type system)

---

## 1. Current state

### 1.1 What works (verified)

- **Self-compile fixpoint.** stage-1 (Ruby-built self-host) → stage-2 (self-built) →
  stage-3 (stage-2-built) all emit **byte-identical C** (~53,226 lines, 0 diffs).
- **All 172 self-host in-language tests pass** (0 failures).
- **`examples/language_baseline.mt`** survives the full self-host pipeline (lex→parse→check→
  lower→emit-c) without crashes, producing **3,707 lines of C**.
- Phases A/B/C1/D: `atomic[T]`, `emit`, `dyn[I]`, break/continue in match-in-loop — DONE.
- **Events (Phase C2)** — DONE.
- **Parallel for rendering (Phase E)** — DONE (ptr-to-array, captures deferred).
- **Serial async (Phase F)** — PARTIAL (foundation DONE; full CPS needed).
- Phase H parts: prelude variant naming, underscore normalization, pointer spacing — DONE.

### 1.2 Recent progress (session 2026-07-10)

271 → 136 errors (-50%), commits `5e4afe3e` through `e88956df`:

| Commit | What | Delta |
|--------|------|-------|
| `5e4afe3e` | Nested struct types, module-qualified type names, vec unary minus, variant match path, match expr type, duplicate vec defs | 271→228 |
| `bc6fc7ac` | Inline for unrolling (fields_of, members_of, attributes_of) | 228→206 |
| `790f0816` | Inline for member access substitution (field.type, member.value) | 206→201 |
| `e168badf` | Libuv opaque `_s`→`_t` via cross-module c_name lookup | 201→155 |
| `080bf55d` | T generic param in vtable/dyn structs | 155→147 |
| `44bf8b0f` | SimpleRange custom iterator guard | 147→144 |
| `03b98aa8` | Inline for type-guard `field.type != float` | 144→140 |
| `bce4d312` | fn→proc coercion via `is_proc` on `ty_function` | 140→136 |
| `e88956df` | Refactor lowering.mt (dedup, rename, extract factory) | 136 (no change) |

### 1.3 Remaining C compilation errors (136, down from 271)

| Category | Count | Root Cause |
|----------|-------|------------|
| Subscripted value not array/pointer | 9 | SoA `particles[0].x` — struct index not lowered |
| Option naming | 4 | Prelude variant methods use bare `Option_int` vs qualified `std_option_Option_int` |
| invoke/env member access | 4 | Proc-typed array elements resolved as fn ptr — type alias `target_type` not qualified |
| Buffer lifetime struct | 3 | `@a` lifetime struct has no C definition generated |
| Subscription comparison | 3 | `mt_subscription == void*` — per-event wrapper needed |
| Variant comparison | 5 | `TokenKind == TokenKind` not lowered to discriminator compare |
| Array assignment | 3 | Proc capture env struct holds array member, assign fails |
| Void variables | 7 | Cascading from type resolution failures (get(), .with(), nested struct) |
| Redefinition of `s` | 2 | Proc capture naming collision from match arms |
| Remaining libuv types | ~8 | `uv_tcp_flags` etc. — flags types not in c_name lookup; `sockaddr` needs `struct` prefix in fn-ptr |
| Other cascading | ~88 | From above root causes |

### 1.4 Type system changes (this session)

- **`ty_function`** now carries `is_proc: bool` to distinguish `fn` from `proc`
- **`ty_named`** now carries `module_name: str` for module-qualified C name generation
- **`ir.TypeAlias`** now carries `backing_c_name: Option[str]` for libuv opaque type mapping
- **`LowerCtx`** new fields: `inline_for_element`, `defer_stack`
- All 12 `ty_function` constructors updated across analyzer + lowering

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

Self-host source layout (`projects/mtc/src`, ≈30k LOC):

| Stage | Path | LOC |
|-------|------|-----|
| Lexer | `src/mtc/lexer/` | ~1,590 |
| Parser + AST | `src/mtc/parser/*.mt` | ~4,860 |
| Pretty printers | `src/mtc/pretty_printer/*.mt` | ~2,190 |
| Semantic analyzer | `src/mtc/semantic/analyzer.mt` | ~4,080 |
| Type system | `src/mtc/semantic/types.mt` | ~710 |
| Loader | `src/mtc/loader/` | ~730 |
| IR | `src/mtc/ir.mt` | ~230 |
| Lowering | `src/mtc/lowering/lowering.mt` | ~10,040 |
| C Backend | `src/mtc/c_backend/c_backend.mt` | ~3,880 |
| Build driver | `src/mtc/build.mt` | ~160 |
| C naming (shared) | `src/mtc/c_naming.mt` | ~137 |

### 2.1 Key seams

- **Monomorphization**: `try_generic_method_call` → `lower_monomorphized_method`
- **Naming**: `naming.type_c_key(ty)` is the single source of truth
- **fn vs proc**: `ty_function.is_proc` distinguishes; `is_proc_type` checks it
- **Proc struct conversion**: `qualify_type` converts `ty_function(is_proc=true)` to `ty_named(mt_proc_…)`
- **Inline for**: `lower_inline_for_stmt` → `comptime_iterable_elements` → per-element unrolling
- **Cross-module opaque**: `lookup_decl_c_name_cross` follows import chain for C type mapping
- **LowerCtx factory**: `new_lowering_context(analysis, …)` single init point
- **Naming conventions** (post-refactor): `nominal_type_name` (not `primitive_type_name`), `is_builtin_type_name` (not `is_primitive_name`)

---

## 3. The plan to 100% parity

### Phase A — `atomic[T]` — DONE
### Phase B — `emit` — DONE
### Phase C1 — `dyn[I]` — DONE
### Phase C2 — `events` — DONE
### Phase D — break/continue in match-in-loop — DONE
### Phase E — parallel for captures — PARTIAL (rendering DONE; captures deferred)
### Phase F — async / Task[T] — PARTIAL (serial foundation DONE; full CPS needed)
### Phase G — baseline parity gate — ACTIVE (136 errors remain, down from 271)
### Phase H — final polish — NOT STARTED

### Recommended next actions (priority order)

1. **Proc type alias qualification** — `ty_function(is_proc=true)` in type alias `target_type` not converted to proc struct. Affects 4 invoke/env errors. Fix: qualify type alias target_type during collection.
2. **Option naming consolidation** — Prelude variant methods use bare names vs module-qualified. Affects 4 errors. Fix: prelude variant base_c_name should use `std_option_` prefix.
3. **SoA index access** — `SoA[T,N]` generates struct but `particles[0]` needs C-level accessor lowering. Affects 9 errors.
4. **Variant comparison** — `TokenKind == TokenKind` needs discriminator-based lowering. Affects 5 errors.
5. **Phase H** — format helpers, string-literal-index stabilization.

---

## 4. Differential harness

```sh
# Build stage-1 (Ruby-built self-host).
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-noguard

# Baseline emit-c + compile check.
tmp/mtc-noguard emit-c examples/language_baseline.mt --root examples --root . > tmp/baseline.c
cc -std=c11 -D_GNU_SOURCE -I std/c -c tmp/baseline.c -o /dev/null 2>&1 | grep "error:" | wc -l

# Self-compile fixpoint check.
tmp/mtc-noguard emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root . > tmp/self.c
cc -std=c11 -D_GNU_SOURCE -I std/c tmp/self.c -o tmp/mtc-stage2 -luv -lpthread -lm
diff <(tmp/mtc-noguard emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root .) \
     <(tmp/mtc-stage2  emit-c projects/mtc/src/mtc/main.mt --root projects/mtc/src --root .)

# Run in-language tests.
bin/mtc test projects/mtc
```

---

## 5. Cross-cutting principles

- **IR is the frozen seam.** Backend reads only `IR`; Lowering reads only `Analysis`.
- **Byte-identical C is the correctness oracle.**
- **Follow Ruby's algorithmic structure.**
- **Fail loud on substrate gaps** (no silent wrong C).
- **Small anchored edits** near function boundaries; rebuild immediately.
- **Sandbox every built binary** (`timeout` + `ulimit -v`).

---

## 6. Resume context (2026-07-10)

### Committed (this session, in order)

| Hash | Description |
|------|-------------|
| `5e4afe3e` | Nested struct types, module-qualified names, vec unary minus, variant match path, match expr type, duplicate vec defs |
| `bc6fc7ac` | Inline for unrolling (fields_of, members_of, attributes_of) |
| `790f0816` | Inline for member access substitution (field.type, member.value) |
| `e168badf` | Libuv opaque `_s`→`_t` via cross-module c_name lookup |
| `080bf55d` | T generic param in vtable/dyn structs and wrappers |
| `44bf8b0f` | SimpleRange custom iterator guard (skip on non-array/span) |
| `03b98aa8` | Inline for type-guard `field.type != float` comptime evaluation |
| `bce4d312` | fn→proc coercion — `is_proc` on `ty_function`, qualify_type converts, `is_proc_type` checks |
| `e88956df` | Refactor lowering.mt: remove dead code, extract factory, rename helpers |

### Key files modified (cumulative)

- `projects/mtc/src/mtc/semantic/types.mt` — `is_proc` on `ty_function`, `module_name` on `ty_named`
- `projects/mtc/src/mtc/semantic/analyzer.mt` — nested type registration, `ctx.module_name` propagation, `is_proc` setting
- `projects/mtc/src/mtc/c_naming.mt` — `type_c_key` for module-qualified `ty_named`
- `projects/mtc/src/mtc/c_backend/c_backend.mt` — `c_type` for module-qualified, `backing_c_name` in type aliases
- `projects/mtc/src/mtc/ir.mt` — `backing_c_name` on `TypeAlias`
- `projects/mtc/src/mtc/lowering/lowering.mt` — all fixes above + refactor (10,040 LOC)

### Build/test commands

```sh
bin/mtc build projects/mtc --no-cache --no-debug-guards -o tmp/mtc-noguard
bin/mtc test projects/mtc
tmp/mtc-noguard emit-c examples/language_baseline.mt --root examples --root . > tmp/baseline.c
cc -std=c11 -D_GNU_SOURCE -I std/c -c tmp/baseline.c -o /dev/null 2>&1 | grep "error:" | wc -l
```
