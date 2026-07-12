# Self-Host Plan: Path to 100% Ruby Parity

Status: **11/13 examples compile. Self-compile deterministic. 172/172 tests pass. P1-P32 DONE.**
Last updated: 2026-07-12 (session end — P32: Task ? propagation fix)

---

## 0. Current state

### 0.1 What works

- **Self-compile deterministic**: SHA256 identical stage-2 = stage-3.
- **Self-host tests itself**: `tmp/mtc-current test projects/mtc -I .` — 172/172 tests pass.
- **11/13 example files compile** with 0 C errors:

| Example | Status | Error count |
|---------|--------|-------------|
| `language_baseline.mt` | OK | 0 |
| `integration_test.mt` | OK | 0 |
| `string_test.mt` | OK | 0 |
| `data_structures.mt` | OK | 0 |
| `memory_stress_test.mt` | OK | 0 |
| `multithreading_test.mt` | OK | 0 |
| `option_and_result_surface.mt` | OK | 0 |
| `nested_struct_stress_test.mt` | OK | 0 |
| `nullable_and_variant_test.mt` | OK | 0 |
| `event_stress_test.mt` | OK | 0 |
| `reflection_advanced.mt` | OK | 0 |
| `async_stress_test.mt` | FAIL | 73 |
| `async_network_lobby.mt` | FAIL | 45 |

- **P1-P32**: P1-P20 DONE (prior session). P21-P32 DONE (this session).

### 0.2 Verification commands

```sh
# Build self-host
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-current

# Self-host tests itself
tmp/mtc-current test projects/mtc -I .                  # expect 172/172

# Deterministic self-compile
rm -f tmp/mtc-s2 tmp/mtc-s3
tmp/mtc-current build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-s2
tmp/mtc-s2 build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-s3
sha256sum tmp/mtc-s2 tmp/mtc-s3                         # identical

# Check error counts
tmp/mtc-current build examples/reflection_advanced.mt -I . --no-cache --no-debug-guards -o /dev/null 2>&1 | grep -c "error:"  # 0
tmp/mtc-current build examples/async_stress_test.mt -I . --no-cache --no-debug-guards -o /dev/null 2>&1 | grep -c "error:"        # 73
tmp/mtc-current build examples/async_network_lobby.mt -I . --no-cache --no-debug-guards -o /dev/null 2>&1 | grep -c "error:"      # 45
```

---

## 1. Completed work (P21-P32, this session)

### P21 — Generic method resolution + cross-module typedef emission
**Files:** `projects/mtc/src/mtc/lowering/lowering.mt`

Fixed `r.unpack[CompactHeader]()` resolving to the wrong generic function. Seven changes:
1. `find_generic_method` searches ALL loaded modules (not just struct-defining module)
2. `qname_last` instead of `qname_first` for qualified type name matching
3. Removed `type_ref.arguments.len > 0` requirement (methods can have own type params on non-generic structs)
4. Intercepted member-access specialization in `lower_call`
5. Removed fallback struct_args population in `lower_specialized_method`
6. Added `struct_defining_module_for_type` for correct C naming
7. Separated struct/method args in `monomorphized_method_c_name`

Also: bare `?` propagation handling, cross-module typedef emission for `std.c.*` targets.
Async improved: 143→99, 100+→53.

### P22 — Cross-type `?` propagation
**Files:** `projects/mtc/src/mtc/lowering/lowering.mt`

Added `current_fn_return_type` to `LowerCtx` with save/restore in `lower_function`, `lower_method`, and `lower_specialized_method`. Modified `lower_propagate_let` to extract error and wrap in return type's failure arm.
**reflection_advanced now compiles with 0 errors.**

### P23 — Task type naming for prelude variants
**Files:** `projects/mtc/src/mtc/c_naming.mt`

Added `std_result_`/`std_option_` prefix in `type_c_key` for `ty_generic` Option/Result. Fixed `mt_task_Result_*` → `mt_task_std_result_Result_*` naming.
Async: 99→92, 53→50.

### P24 — Remove std.async skips
**Files:** `projects/mtc/src/mtc/lowering/lowering.mt`

Removed skips that returned zero_init/stubs for `std.async` module functions in `lower_monomorphized_call` and `try_inferred_generic_call`. Necessary for async helper monomorphization; blocked upstream by `unify_type_param` gap (fixed in P30).

### P25 — Task struct field access as indirect calls
**Files:** `projects/mtc/src/mtc/lowering/lowering.mt`

Task[T] fields (ready, set_waiter, release, take_result, cancel) treated as struct field access + indirect calls, not method calls. Added `is_task_fn_field` helper.
Async: 92→89.

### P26 — Libuv enum member access (bare C constant names)
**Files:** `projects/mtc/src/mtc/lowering/lowering.mt`, `projects/mtc/src/mtc/c_backend/c_backend.mt`

Lowering assigns `ty_type_meta` for type-name expressions from imports. C backend detects `ty_type_meta` receiver and emits bare member name for enum access. lang_base: 6→4.

### P27 — Recursive type alias resolution in `lookup_decl_c_name_cross`
**Files:** `projects/mtc/src/mtc/lowering/lowering.mt`

When the target is `ty_imported` from a non-std.c module that has it as a type alias, follow the chain recursively. Also fixed `lower_fn_field_call` to use function type's return type for indirect call result type.

### P28 — Task `take_result` return type for monomorphized `mt_task_*`
**Files:** `projects/mtc/src/mtc/lowering/lowering.mt`

Detect Task structs via `mt_task_` prefix in `ty_named`/`ty_imported`. Extract element type from `generic_struct_instances` map. Fixed `__mt_return_value_1` declared void.

### P29 — Opaque/union type resolution in imported modules
**Files:** `projects/mtc/src/mtc/semantic/analyzer.mt`, `projects/mtc/src/mtc/loader/binder.mt`

`ModuleBinding` and `bind_module` didn't track opaque/union declarations, so `type uv_handle_t = c.uv_handle_t` resolved to `ty_error`. Added `types` field to `ModuleBinding`, handled `decl_opaque`/`decl_union` in binder, checked `binding.types.contains()` in `resolve_imported_type`.
**lang_base: 3→0.** Async: 87→81, 47→41.

### P30 — Nested generic instance matching in `unify_type_param`
**Files:** `projects/mtc/src/mtc/lowering/lowering.mt`

Mirrors Ruby's `collect_type_substitutions` for GenericInstance types. When param is `Task[T]` and arg is `Task[int]`, recursively unify nested type arguments. Fixed `std_async_completed__int` monomorphization. No net count change (fixed 1, exposed 1).

### P31 — Complete Task struct emission from all IR sources
**Files:** `projects/mtc/src/mtc/c_backend/c_backend.mt`

`emit_task_forward_decls` and `emit_task_structs` now scan: function return types/params, struct field types (async frame `await_N` fields), and type alias target types. `collect_task_type` handles `ty_generic`, `ty_named`, `ty_imported` `mt_task_*`. Forward decls emitted BEFORE type aliases (ordering fix).
Async: 81→77.

### P32 — Fix `?` propagation for Task-returning async functions
**Files:** `projects/mtc/src/mtc/lowering/lowering.mt`

When async function returns `Task[Result[T, E]]` and uses `?` propagation, failure branch was creating Result variant literal on Task struct (wrong fields). Now constructs Task aggregate literal wrapping failure Result in `.value`, with zero-initialized vtable fields. Added `extract_task_element_type` helper.
Async: 77→73.

---

## 2. Example status

### 2.1 Compiling (11/13)

| Example | Errors |
|---------|--------|
| `language_baseline.mt` | 0 |
| `integration_test.mt` | 0 |
| `string_test.mt` | 0 |
| `data_structures.mt` | 0 |
| `memory_stress_test.mt` | 0 |
| `multithreading_test.mt` | 0 |
| `option_and_result_surface.mt` | 0 |
| `nested_struct_stress_test.mt` | 0 |
| `nullable_and_variant_test.mt` | 0 |
| `event_stress_test.mt` | 0 |
| `reflection_advanced.mt` | 0 |

### 2.2 Failing (2 examples)

| # | Root Cause | Examples | Errors |
|---|-----------|----------|--------|
| 1 | Missing async helpers + type mismatches + remaining task types | `async_stress_test`, `async_network_lobby` | 73/45 |

---

## 3. Remaining work

### 3.1 Missing function bodies (~10 errors)

| Function | Description |
|----------|-------------|
| `std_async_libuv_runtime_ptr_waiter` | Async runtime waiter function not generated by `lower_async_fn` |
| `std_net_release_uv_buffer` | Net module release function not emitted |
| `std_net_session_ChanHostMessageTask_release` | Session module Task release function |
| `std_net_session_ChanMessageTask_release` | Session module Task release function |
| `std_net_udp_receive_alloc_callback` | UDP receive callback not emitted |

These are async infrastructure helpers the Ruby compiler generates during async lowering. The self-host's `lower_async_fn` doesn't produce them.

### 3.2 Type alias chain mismatches (~15 errors)

Cross-module type aliases like `ChanMessageTask = Task[Option[Message]]` create type name mismatches between the typedef and the actual usage. The generated C uses `std_option_Option_Task_...` and `std_option_Option_std_net_session_ChanMessageTask` interchangeably.

**Fix approach**: Resolve type aliases through the monomorphization chain so the lowering produces consistent C type names.

### 3.3 Remaining Task types (~5 errors)

`mt_task_ptr_uint`, `mt_task_std_net_manager_NetworkConfig`, `mt_task_std_option_Option_std_net_session_OutgoingMessage` — not discovered by the Task struct emission scan because they appear only in IR expression bodies.

**Fix approach**: Also scan IR function bodies (local variables, return expressions) for Task type references.

### 3.4 Libuv callback type mismatches (~10 errors)

`uv_ip4_addr`, `uv_ip6_addr`, `uv_udp_recv_start` — wrong pointer types passed to libuv C functions.

**Fix approach**: Add explicit casts at libuv call sites in the C backend or lowering.

### 3.5 Various pointer/type mismatches (~30 errors)

`sockaddr_storage *` vs `int *`, `mt_task_int` vs `_Bool`/`uintptr_t` return types, Option-to-Task type assignments, struct member access on wrong types, undeclared variables.

---

## 4. Uncommitted changes inventory

All changes committed. When resuming, work starts from clean HEAD.

**Key files for remaining work**:
- `projects/mtc/src/mtc/lowering/lowering.mt` — `lower_async_fn`, async runtime function generation
- `projects/mtc/src/mtc/c_backend/c_backend.mt` — `collect_task_type`, libuv callback coercion
- `projects/mtc/src/mtc/loader/binder.mt` — opaque/union type tracking (already fixed in P29)
- `projects/mtc/src/mtc/semantic/analyzer.mt` — `resolve_imported_type` (already fixed in P29)
- `lib/milk_tea/core/lowering/async/` — Ruby reference for async lowering

---

## 5. Resume context

```sh
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-current
tmp/mtc-current test projects/mtc -I .     # expect 172/172
```

**Recommended next steps** (in priority order):

1. **Fix async helper functions** (§3.1) — most impactful single fix. Investigate `lower_async_fn` to generate `ptr_waiter`, `ChanMessageTask_release`, and similar helpers that the Ruby compiler produces during async frame lowering.

2. **Fix remaining Task type discovery** (§3.3) — scan IR function bodies for `mt_task_*` type references.

3. **Fix type alias chain** (§3.2) — resolve cross-module type aliases through monomorphization.

4. **Fix libuv callback types** (§3.4) — add pointer casts at libuv call sites.
