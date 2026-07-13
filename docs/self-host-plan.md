# Self-Host Plan

Status: **SELF-HOSTING FIXED POINT ACHIEVED.** Stage2 == stage3 byte-identical,
172/172 self-tests pass. **13/13 examples build** with the self-hosted compiler
(up from 11); **11/13 run identically to Ruby**. The two async examples build
cleanly but diverge at runtime on deep async-runtime-lifetime bugs:
`async_network_lobby` hits a recv-task frame use-after-free in std.net's
manual-poll (`completed`/`result`) pattern; `async_stress_test` hits an awaited
child-frame use-after-free (its Ruby-built binary also aborts early). The
self-host itself uses no async and no array-by-value returns, so every landed
change is verified fixed-point-safe (stage2==stage3 re-checked after each).
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

| Example | Build | Run |
|---------|-------|-----|
| `data_structures` | OK | MATCH |
| `event_stress_test` | OK | MATCH |
| `memory_stress_test` | OK | MATCH |
| `multithreading_test` | OK | MATCH |
| `nested_struct_stress_test` | OK | MATCH |
| `nullable_and_variant_test` | OK | MATCH |
| `option_and_result_surface` | OK | MATCH |
| `reflection_advanced` | OK | MATCH |
| `integration_test` | OK | builds & runs (Ruby warns-as-errors) |
| `language_baseline` | OK | MATCH |
| `string_test` | OK | MATCH |
| `async_stress_test` | OK | runtime UAF (Ruby-built binary also aborts early) |
| `async_network_lobby` | OK | runtime UAF (recv-task frame; Ruby → SUCCESS) |

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


## 2. Remaining work (async runtime divergences)

All 13 examples now **build**. The three build gaps that previously blocked
`async_network_lobby` are fixed (cross-module generic-instance recovery via a
program-wide shared `generic_struct_instances` registry; `?`-propagation inside
a prefix cast and in assignment position; `Result[T, void]` `map_error` via
proc-arg return-type inference). The two async examples now diverge only at
**runtime**, on deep async-lifetime bugs:

### 2.1 async_network_lobby: recv-task frame use-after-free

`std.net.discovery.announce` uses a manual-poll pattern:

```mt
let recv_task = socket.recv_from(1500)   # created once, outside the inner loop
while frame < 120:
    if aio.completed(recv_task):
        let recv_result = aio.result(recv_task)   # result() has `defer release`
```

`result[T]` releases the task frame on exit (its `defer task.release`).
Valgrind shows `result` → internal `completed(task)` → `task.ready(frame)`
reading a **freed** `UdpReceiveState` frame, i.e. the recv frame is freed before
`result` finishes reading it. Ruby runs this to `SUCCESS`, so the divergence is
in the self-host's handling of the manually-polled task frame lifetime (likely
the CPS spilling / release ordering of `recv_task` across the poll loop).

Note: this also surfaced a benign duplicate specialization — `completed[T]`
called with an explicit `[T]` (inside `result`'s body) mangles to a single-`_`
key while the inferred `aio.completed(x)` call mangles to `__`; both bodies are
identical (`return task.ready(task.frame)`), so it is not the crash cause, but
unifying `specialization_key` and `try_inferred_generic_call`'s key schemes
would dedup them.

### 2.2 async_stress_test: awaited child-frame use-after-free

An awaited child task frame is `free`d by the parent's await-completion release
while the child's `resume` is still on the call stack (synchronous completion
path). The Ruby-built binary also aborts early on this example (different
message), so it is runtime-unstable under both compilers.

### 2.3 CPS for-loop induction-var spilling (latent)

A `for i in 0..N` / `for v in col` inside an async body creates C locals for the
induction and stop values; these don't survive an await inside the loop body.
No current example exercises it. Fix: `lower_for_range` should
`async_register_local_field` for the induction/stop temps when
`ctx.async_cps_active`.
