# Self-Host Plan: Path to 100% Ruby Parity

Status: **11/13 examples compile. 172/172 tests pass. P1-P38 in progress.**
Last updated: 2026-07-13 (session — P33-P38 fixes, 25/45 errors remaining)

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

### P33 — Cross-module fn-pointer field calls (ptr_waiter)
**Files:** `projects/mtc/src/mtc/lowering/lowering.mt`

`concrete_field_type` now searches imported module analyses for non-generic struct fields. Call-lowering fallback strips pointer wrappers before resolving struct names. Fixes `state.waiter(state.waiter_frame)` generating `ptr_waiter` instead of a direct fn-pointer call. (-1 error)

### P34 — Module-level variable array indexing
**Files:** `projects/mtc/src/mtc/lowering/lowering.mt`

`index_receiver_type` and `fallback_type` now resolve module-level variables via `module_var_type` lookup. Fixes checked_index helpers using dimension 0 instead of the actual array length. (-20 errors)

### P35 — Cross-module ty_imported alias resolution
**Files:** `projects/mtc/src/mtc/lowering/lowering.mt`

`qualify_type` for `ty_imported` now resolves type aliases in the owning module, so chains like `NativeBuffer → libuv.uv_buf_t → c.uv_buf_t` resolve to the bare C type name. (-7 errors)

### P36 — std.c.* struct prefix (sockaddr_types)
**Files:** `projects/mtc/src/mtc/c_backend/c_backend.mt`

Hard-coded `struct` prefix for `sockaddr`, `sockaddr_storage`, `sockaddr_in`, `sockaddr_in6` from `std.c.*` modules in `c_type`. Added `std_c_backing` Emitter field and `collect_std_c_backing` utility for future generalization. (-14 errors)

### P37 — Task type discovery from function bodies
**Files:** `projects/mtc/src/mtc/c_backend/c_backend.mt`

Added `task_scan_stmts`/`task_scan_stmt`/`task_scan_expr` to walk IR function bodies collecting Task types referenced in aggregate literals, return values, and other expressions. Follows the same proven pattern as `checked_from_stmts`. (-2 errors + type resolution fixes)

### P38 — Fix void value in Task structs
**Files:** `projects/mtc/src/mtc/c_backend/c_backend.mt`

`is_void_type` now returns true for `ty_error` types, preventing invalid `void value;` field emission in Task struct definitions. (-1 error)

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
| 1 | Task return type mismatches + incomplete Task struct fields + libuv type + variable scoping | `async_stress_test`, `async_network_lobby` | 25/27 |

The async examples dropped from 73/45 → 25/27 after P33-P38. Remaining errors are pre-existing type mismatches in the async/monomorphization lowering (Task return types conflicting with non-Task signatures), incomplete Task struct field types, libuv callback type mismatches, and variable scoping issues.

---

## 3. Remaining work

### 3.1 Task return type mismatches in monomorphized functions (~6 errors)

Monomorphized async functions like `Deque[OutgoingMessage].next_index` have return types mismatched: the C signature declares `uintptr_t` but the body returns `mt_task_int` or `mt_task_ptr_uint`. This is a lowering bug where async body lowering incorrectly wraps return values in Task aggregate literals.

**Fix approach**: In `lower_async_fn`, check if the function is actually async before wrapping returns in Task aggregates. Or fix the body scan to detect when a function body is using Task types but the signature doesn't match.

### 3.2 Incomplete Task struct field types (~2 errors)

Task structs with element types that are forward-declared but not yet fully defined (e.g. `Task[std_result_Result_std_option_Option_std_net_channel_Message_std_net_Error]`) have `value` fields with incomplete types. The Option payload struct references the Task type before the Task struct is defined.

**Fix approach**: Ensure Task struct definitions are emitted AFTER their element type structs. This may require topological sorting of struct definitions.

### 3.3 Libuv callback type mismatches (~4 errors)

`uv_ip4_addr` and `uv_ip6_addr` have incompatible argument types. The suseelf-host passes struct types where the C function expects different pointer types.

**Fix approach**: Add explicit pointer casts at libuv call sites, or ensure the type alias chain produces the correct C pointer types.

### 3.4 Variable scoping issues (~4 errors)

Variables `x`, `y`, `player_joined`, `connected` are used without being declared in scope. These might be from match arm destructuring patterns or inline variable bindings that the self-host doesn't lower correctly.

**Fix approach**: Debug the specific source code patterns that produce these variables and fix the lowering.

### 3.5 Miscellaneous (~9 errors)

- `invalid initializer` (2) — Task struct initialization issues
- `'return' with a value in non-void function` (2)
- Wrong Config types (1)
- Incompatible type for arguments (1)
- 'too many arguments' (1)

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
tmp/mtc-current test projects/mtc -I .     # 172/172
tmp/mtc-current build examples/async_stress_test.mt -I . --no-cache --no-debug-guards -o /dev/null 2>&1 | grep -c "error:"  # 25
tmp/mtc-current build examples/async_network_lobby.mt -I . --no-cache --no-debug-guards -o /dev/null 2>&1 | grep -c "error:"  # 27
```

**Recommended next steps** (in priority order):

1. **Fix Task return type mismatches** (§3.1) — most impactful, ~6 errors. The async body lowering wraps non-async function returns in Task aggregates. Fix by checking whether the function is actually async before applying the wrap.

2. **Fix incomplete Task struct field types** (§3.2) — topologically sort Task struct emission after their element type structs.

3. **Fix libuv callback types** (§3.4) — add pointer casts at libuv call sites.

4. **Fix variable scoping** (§3.4) — debug match arm destructuring patterns.

5. **Fix miscellaneous** (§3.5) — remaining type mismatches and invalid initializers.
