# Self-Host Plan

Status: **SELF-HOSTING FIXED POINT ACHIEVED.** Stage2 == stage3 byte-identical,
172/172 self-tests pass. **12/13 examples build** (all 11 non-async + both async
examples); **11/13 run identically to Ruby**. `async_stress_test` builds and
crashes at runtime on a pre-existing async task-frame use-after-free (the
Ruby-built binary also aborts early on the same example). `async_network_lobby`
builds all its non-async paths but still has ~24 C errors from three deep,
narrow gaps (cross-module generic-instance recovery in CPS, `?`-propagation in
`std.binary`, and `Result[T, void]` `map_error`). The self-host itself uses no
async and no array-by-value returns, so all landed work carries **zero
fixed-point risk** (verified: stage2==stage3 after every change).
Last updated: 2026-07-14

---

## 0. Current State

### 0.1 Bootstrap

```sh
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-current
tmp/mtc-current build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-stage2 --keep-c tmp/stage2.c
tmp/mtc-stage2 build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-stage3 --keep-c tmp/stage3.c
diff tmp/stage2.c tmp/stage3.c        # identical
tmp/mtc-stage2 test projects/mtc -I .  # 172/172
```

### 0.2 Example parity

| Example | Status |
|---------|--------|
| `data_structures` | MATCH |
| `event_stress_test` | MATCH |
| `memory_stress_test` | MATCH |
| `multithreading_test` | MATCH |
| `nested_struct_stress_test` | MATCH |
| `nullable_and_variant_test` | MATCH |
| `option_and_result_surface` | MATCH |
| `reflection_advanced` | MATCH |
| `integration_test` | self-host builds & runs (Ruby warns-as-errors) |
| `language_baseline` | MATCH |
| `string_test` | MATCH |
| `async_stress_test` | BUILDS; runtime UAF (Ruby-built binary also aborts early) |
| `async_network_lobby` | ~24 C errors (3 deep gaps, see §2) |

---

## 1b. Fixes landed this session (async + array ABI)

1. **Async `main` entrypoint** — `build_async_main_entrypoint` synthesizes the
   C `main()`: wraps the CPS-lowered `<module>_main` constructor in a root proc,
   drives it via `std.async.wait[int]` (specialized through `find_generic_function`
   so it reuses the deepest backend impl) / `run` for void, releases the proc.
2. **`own[T]` auto-deref** — `is_own_type()` lets `read()`, member-access, and
   field-type resolution treat `own[T]` like a pointer (Ruby's `pointer_type?`
   includes own).
3. **Arm-payload topo ordering** — variant arm-payload structs (`<V>_<arm>`) are
   registered as `by_key` aliases to the variant node, so async frame fields that
   embed them by value are ordered after the full variant definition.
4. **`own[T]` foreign arg** — passing `own[T]` to a `ptr`/`const_ptr` foreign
   param no longer takes its address.
5. **Match-scrutinee await hoist** — `match await expr:` in a CPS body hoists the
   scrutinee await into a suspend/resume point (was silently dropped).
6. **Method-spec CPS isolation** — `ensure_monomorphized_method` saves/clears/
   restores the async CPS state, so a generic method first specialized while an
   async body is CPS-lowered doesn't inherit `__mt_frame`/resume labels.
7. **`ptr_of` referent-type recovery** — recompute `<kind>[inner]` when the
   analyzer recorded a pointer to a void/error element and the operand is concrete
   (fixes `ptr_of(read(ptr).imported_struct_field)` → `ptr[void]`).
8. **Arm-name-disambiguated CPS match fields** — same-named bindings in different
   match arms (`Result.failure as p` / `Result.success as p`) get distinct frame
   fields instead of colliding on one mistyped field.
9. **Array-by-value C ABI** — `array[T,N]`-returning functions lower to
   `void f(T (*__mt_out)[N], ...)`; array-returning calls in argument position are
   materialized into `__mt_array_call_N` temps; array-literal returns/assignments
   memcpy from a temp; named array-length params (`array[T,N]`) resolve through
   the type substitution; `array[T,N]` args coerce to `span[T]` aggregates.

---

## 1. Fixes landed (earlier sessions)


### 1.1 Self-hosting blocker: cross-module same-name type collision

`lower_monomorphized_method` picked the *first* module declaring a struct
of a given simple name (`map.Entries` vs `fs.Entries`, `ir.Program` vs
`loader.Program`). Fixed: `GenericReceiver.owner_module` sourced from the
receiver type itself; method lowering prefers it over the by-name scan.

### 1.2 Nullable fn-pointer locals

`c_declaration` emitted `void (*)(int32_t) pred` (invalid C). Added a
`ty_nullable` case → `c_fn_ptr_declarator(base, name)` → `void (*pred)(int32_t)`.

### 1.3 Global variable initializers dropped

Module-level `var p = proc(...)` zero-initialized (null vtable → segfault).
Now lowered, emitted as C static initializer, and seeded for reachability.

### 1.4 `str_buffer[N]` capacity lost

`N` resolved via `resolve_type_ref` (not `ty_literal_int`), capacity 0 →
abort. Fixed: `types.literal_int(resolve_array_length(...))` like `array[T, N]`.

### 1.5 Const comparisons produced `cv_int` not `cv_bool`

`const_binary_op` wrapped `==` results as `cv_int`; `inline if` only accepts
`cv_bool`. Comparisons now yield `cv_bool`.

### 1.6 Compile-time reflection / type dispatch

- `inline if` else-if chains, `field.type == T`/`T == int` via `cv_type`,
  `fields_of(T)` type-param + cross-module resolution, inline-for binding
  local + `field.name`, nested const-function-call argument scoping.
  Fixes `reflection_advanced` end-to-end.

### 1.7 Format strings (`f"..."`)

Parser splits lexeme into `expr_format_string` parts, re-lexes+parses each
`#{expr}`. Static strings collapse to literals; dynamic ones lower via
GCC/Clang statement-expressions. Full `mt_format_*` runtime + type/spec
dispatch. `string_test` matches Ruby.

### 1.8 Async CPS — core (direct awaits)

`lower_async_fn` emits frame struct, goto resume state machine, vtable,
constructor. Degenerate `lower_function(is_async=true)` deleted. Spilling:
params → `param_<N>`, locals → `local_<N>`, awaited tasks → `await_<N>`;
bindings carry `"__mt_frame->field"` C names so existing `lower_expr` renders
frame accesses automatically. `async_emit_await`: suspend via `set_waiter` +
`return`; resume via `take_result` + `release`. Frame `calloc`'d (garbage
`waiter`→crash). `async_waiter_wake` saves temp before nulling. Direct awaits,
nested async+Result, awaits in loops, `language_baseline` all verified.

### 1.9 Async methods CPS-lowered

- `FnSig.is_async` → analyzer wraps method returns in `Task[T]`.
  `collect_extending_methods` passes `m.is_async`.
- `lower_extending_block` routes async non-generic methods to a generalized
  `lower_async_fn` with `this` → `param_this`.
- `try_generic_method_call` returns `none` for `gm.method.is_async`, so the
  call falls through to `resolve_method_info` which returns `Task[T]` + eager
  CPS constructor.
- Field-collection pointer isolation prevents nested-lowering contamination.

### 1.10 Embedded-await hoisting

`async_hoist_awaits` — recursive AST rewrite lifts embedded awaits into
`local_await_tmp_N` frame fields, replaces with identifiers. CPS-aware
`lower_propagate_let` (failure → `frame->result` + goto complete; success →
spill). CPS-aware `lower_guard_local`. Compound `+=`, `while` condition
(→ `while(true)` + break), single-branch `if` condition, `return`.

### 1.11 Match-binding CPS spilling

Five match-arm binding sites made CPS-aware (match-expr, switch variant,
goto struct-pattern payload + as-binding + field bindings). Bindings spill
to frame fields instead of C locals → survive await in arm body.

### 1.12 Nested-generic arm-payload field types

`arm_payload_field_type` falls back to `prelude_arm_field_types` registry
for prelude arms not in `match`-only `arm_payload_fields`. Fixed
`Result[Option[Msg], int].success.value` → `Option[Msg]` (was `_phantom`).

### 1.13 Specialization label isolation

`lower_and_cache_specialization_with_sub` now disables `async_cps_active`
and clears CPS labels before lowering specialized bodies → runtime wrappers
no longer embed `goto <other_fn>_resume_complete` (was 3 such errors, now 0).


## 2. Remaining work (async_network_lobby's ~24 C errors)

All 12 other examples build; `async_network_lobby` builds every non-async path
but hits three narrow, deep gaps. None affect the self-host itself, so the fixed
point is unaffected.

### 2.1 Cross-module generic-instance recovery in CPS

`match await disc.discover(...)` yields `Result[Vec[Server], int]`; binding
`var servers = sp.value` spills a frame field typed with the *collapsed* generic
C name (`std_vec_Vec_lib_disc_Server`). The `Vec[Server]` instance was registered
in the *defining* module's `generic_struct_instances` (when `discover`'s return
type was qualified), not in the root module's per-module map, so
`generic_receiver_info` misses it and `servers.len()`/`.get()`/`.release()`
resolve to the current-module fallback (`<root>_std_vec_Vec_..._len`). Fields
like `local_first_ptr` / `local_info` then also fail to spill.

Fix options: (a) make `generic_struct_instances` a program-wide shared registry
threaded through `lower_module` (mirrors `program_returns`); or (b) have
`generic_receiver_info` reconstruct owner+args from the collapsed name by
searching loaded modules. (a) is cleaner. Repro: `tmp/asynclib/app6.mt`-style —
an async `main` awaiting a cross-module async fn returning `Result[Vec[T], E]`,
then calling a `Vec` method on the unwrapped value.

### 2.2 `?`-propagation malformed C in `std.binary`

`std.binary.Reader.read_str` etc. emit `(uintptr_t) ?read_uint(this)` — a stray
`?` token. The `?` postfix operator inside a cast/expression position isn't
lowered to the propagation if/return form there. Pre-existing; unrelated to the
async work.

### 2.3 `Result[T, void]` `map_error`

`map_error` producing `Result[T, void]` emits `_void_failure has no member
error` — the `void` error arm has no `error` field but the failure path still
references it. Needs the `void`-error arm to be handled specially.

### 2.4 async task-frame use-after-free (runtime, async_stress_test)

`async_stress_test` builds but crashes at runtime: an awaited child task frame is
`free`d by the parent's await-completion release while the child's `resume` is
still on the call stack (synchronous completion path). The Ruby-built binary also
aborts early on this example (different message), so it is runtime-unstable under
both compilers. Fix is in the async release ordering / deferred-free of a task
frame whose resume synchronously re-enters the waiter.

### 2.5 CPS for-loop induction-var spilling (latent)

A `for i in 0..N` / `for v in col` inside an async body creates C locals for the
induction and stop values; these don't survive an await inside the loop body.
No current example exercises it. Fix: `lower_for_range` should
`async_register_local_field` for the induction/stop temps when
`ctx.async_cps_active`.
