# Self-Host Plan

Status: **SELF-HOSTING FIXED POINT ACHIEVED.** Stage2 == stage3 byte-identical,
172/172 self-tests pass. **10/13 examples match Ruby**; the two async examples
(102/32 C errors) are regressing on pre-existing `std.net` type-resolution bugs +
missing `async main` entrypoint. Format strings and async CPS core are done.
The self-host uses no async, so remaining work carries **zero fixed-point risk**.
Last updated: 2026-07-13

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
| `async_stress_test` | ~102 C errors (pre-existing std.net + missing async main entrypoint) |
| `async_network_lobby` | ~32 C errors (same root causes) |

---

## 1. Fixes landed

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

---

## 2. Remaining work (for a new session)

### 2.1 Async `main` entrypoint (Blocker 3)

`build_async_main_entrypoint` is a stub → `async function main` emits no
C `main` (link error). The async main is already CPS-lowered as a constructor
returning `Task[T]`. Implementation:

1. Build zero-capture root proc via `lower_fn_to_proc(ctx, <module>_main, fn() -> Task[T])`.
2. Trigger `std.async.wait[int]` specialization: find `std.async`'s analysis,
   locate `wait`'s AST decl, build `GenericFunctionMatch`, substitute
   `T → inner_ty`, call `lower_and_cache_specialization_with_sub`, get C name
   `std_async_wait__int`. (For void main, use `run`.)
3. Emit `main()` body: `let p = <proc>; let r = wait(p); p.release(env); return r;`
   using the specialized C name.
4. `main(argc, argv)` reuses the argv→`span[str]` bridge from
   `build_root_main_entrypoint`.

**Files:** `lowering.mt` (`build_async_main_entrypoint` ≈ line 14554).

### 2.2 `std.net` guard/type-resolution bugs (pre-existing)

The C errors in `async_network_lobby` (~32) and `async_stress_test` (~102) are
almost entirely in `std.net` functions — `declared void`, int-from-pointer,
type-mismatched initializers. The guard form
`let x = read(state).inner.<field> else:` on a struct field holding a
type-aliased pointer to an imported opaque (`SocketAddress.storage` →
`ptr[NativeSocketStorage]?`, where `NativeSocketStorage = libuv.sockaddr_storage`)
resolves the member access to `void`. Isolated reproductions with simpler types
work; the failure is specific to `std.net`'s multi-nested read chain +
type-aliased-opaque pattern. Fix is in the general member-access type
resolution, not in CPS.

### 2.3 CPS for-loop binding spilling (correctness, not fixing current errors)

A `for i in 0..N` or `for v in col` inside an async body creates C locals for
the induction var and stop value; these don't survive an await inside the loop
body. No current example exercises this, but it is a latent correctness gap.
Fix: `lower_for_range` should call `async_register_local_field` when
`ctx.async_cps_active`.
