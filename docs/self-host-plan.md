# Self-Host Plan: Path to 100% Ruby Parity

Status: **10/13 examples compile. Self-compile deterministic. 172/172 tests pass. P1-P21 DONE.**
Last updated: 2026-07-12 (session end — P21: generic method resolution + cross-module typedef emission)

---

## 0. Current state (2026-07-12 session end)

### 0.1 What works

- **Self-compile deterministic**: SHA256 identical stage-2 = stage-3.
- **Self-host tests itself**: `tmp/mtc-current test projects/mtc -I .` — 172/172 tests pass.
- **10/13 example files compile** with 0 C errors:

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
| `async_stress_test.mt` | FAIL | 99 |
| `async_network_lobby.mt` | FAIL | 53 |
| `reflection_advanced.mt` | FAIL | 2 |

- **P1-P20**: P1-P16 DONE (prior session). P17-P20 DONE (this session).

### 0.2 Verification commands

```sh
# Build self-host
bin/mtc build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-current

# Self-host tests itself
tmp/mtc-current test projects/mtc -I .

# Deterministic self-compile
rm -f tmp/mtc-s2 tmp/mtc-s3
tmp/mtc-current build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-s2
tmp/mtc-s2 build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-s3
sha256sum tmp/mtc-s2 tmp/mtc-s3  # identical

# Example build
tmp/mtc-current build examples/language_baseline.mt -I . --no-cache --no-debug-guards -o /dev/null
```

---

## 1. Completed work (P10-P20)

### P10–P16 (prior session)
Described in prior plan documents. All lowering crashes and most C compilation errors resolved.

### P17 — Task type specializations (C backend ordering)
- Added `emit_task_forward_decls` to forward-declare Task types before struct/variant definitions.
- Moved `emit_task_structs` after `topo_sort_types` so variant/struct dependencies are defined before Task structs.
- Changed Task struct emission from anonymous `typedef struct {...} name;` to named `struct name {...}; typedef struct name name;` to match forward declarations.

Key files: `projects/mtc/src/mtc/c_backend/c_backend.mt` — `emit_task_forward_decls`, `emit_task_struct_type`, `generate_c`.

### P18 — Event wait function (event_stress_test now OK)
- Added 5 synthetic wait functions: `build_event_wait_ready_fn`, `build_event_wait_set_waiter_fn`, `build_event_wait_release_fn`, `build_event_wait_take_result_fn`, `build_event_wait_fn`.
- Added wait_frame struct emission to `ensure_event_runtime`.
- Modified `build_event_emit_fn` to handle wait_frame slots during event dispatch (stores result in frame, wakes waiter).
- Fixed `lower_event_method` "wait" to return `Task[Result[...]]` instead of `Task[void]`.
- Added new fields to `EventRuntimeInfo`: `wait_frame_c_name`, `wait_ready_c_name`, `wait_set_waiter_c_name`, `wait_release_c_name`, `wait_take_result_c_name`, `wait_result_ty`.

Key files: `projects/mtc/src/mtc/lowering/lowering.mt` — event wait functions, `ensure_event_runtime`, `build_event_emit_fn`, `lower_event_method`. Ruby reference: `lib/milk_tea/core/lowering/events.rb:270-1050`.

### P19 — Generation double-evaluation bug
Fixed all subscribe functions (`build_event_subscribe_fn`, `build_event_subscribe_stateful_fn`, `build_event_wait_fn`) to use a local variable (`__mt_gen`) to capture the computed generation value. Previously, `gen_plus = gen_ref + 1` was an expression tree that evaluated twice (once for the slot assignment, once for the subscription aggregate literal), producing a mismatched generation after the first evaluation mutated the slot.

Key file: `projects/mtc/src/mtc/lowering/lowering.mt` — subscribe/wait function bodies.

### P21 — Generic method resolution + cross-module typedef emission (this session)

#### 21a: Generic method resolution for cross-module extending blocks
**Files:** `projects/mtc/src/mtc/lowering/lowering.mt`

Fixed `r.unpack[CompactHeader]()` resolving to `std.serialize.unpack` (standalone generic function) instead of `std.binary.Reader.unpack` (extending-block method):

1. **`find_generic_method` now searches ALL loaded modules** (not just the struct's defining module). Extending blocks like `std.serialize.extending.bin.Reader` were invisible because `Reader` is defined in `std.binary` not `std.serialize`.

2. **`qname_last` instead of `qname_first`** for matching qualified type names: `extending bin.Reader` matches against `"Reader"` (last component) not `"bin"` (first).

3. **Removed `type_ref.arguments.len > 0`** requirement — methods can have their own type params on non-generic structs (`unpack[T]()` on `Reader`).

4. **Added interception in `lower_call`** for `expr_specialization(callee = expr_member_access(...))` patterns. Before routing to `lower_specialization_call` (which picks standalone generic functions), the code now resolves through `generic_receiver_info` + `find_generic_method` for extending-block methods with own type params.

5. **Removed fallback `struct_args` population** in `lower_specialized_method` — was incorrectly adding all concrete_args (including method-level type params) as struct type args when `struct_args.len == 0`.

6. **Added `struct_defining_module_for_type`** — uses the struct's defining module (e.g. `std_binary`) for C naming, not the extending-block module (e.g. `std_serialize`).

7. **`monomorphized_method_c_name` separates struct args from method args** — produces `Reader_unpack_CompactHeader` not `Reader_CompactHeader_unpack`.

#### 21b: Bare `?` propagation in expression statements
**Files:** `projects/mtc/src/mtc/lowering/lowering.mt`

Added handling for bare `expr?` as an expression statement (was previously being emitted literally as `?` in C). The `lower_stmt` → `stmt_expression` branch now detects `expr_unary_op(operator = "?")` and desugars to the same guard-like unwrap as `let _ = expr?`.

#### 21c: Cross-module typedef emission for type aliases targeting std.c.*
**Files:** `projects/mtc/src/mtc/lowering/lowering.mt` — type alias collection loop (~line 380)

When a non-raw module declares `type NativeSocketStorage = libuv.sockaddr_storage` where the target resolves to `std.c.libuv.sockaddr_storage`, the lowering now emits a C `typedef struct sockaddr_storage std_net_NativeSocketStorage;`. Previously all aliases targeting `std.c.*` types were unconditionally skipped because "the target already has a valid C name" — but the ALIAS didn't, causing `unknown type name 'std_net_NativeSocketStorage'` errors.

The fix only emits typedefs when the target has a known C declaration in the external module (found via `lookup_decl_c_name_cross`). Targets without explicit declarations (e.g. enum fields like `uv_tcp_flags`) are still skipped.

Async examples benefited: `async_stress_test` 145→99 errors (-46), `async_network_lobby` 100+→53 (-47).

### P20 — Cross-module type tracking + misc fixes

#### 20a: `resolve_named` stores module-qualified types
**File:** `projects/mtc/src/mtc/semantic/analyzer.mt:1169`

Changed `resolve_named` from `ty_named(module_name = "", name = name)` to `ty_named(module_name = ctx.module_name, name = name)`. When locally-declared types appear in function signatures and propagate through monomorphization, the module prefix is preserved. The lowering's `qualify_type` uses `n.module_name` to resolve cross-module references.

**Why `ty_named` not `ty_imported`**: `ty_named` keeps all existing `match ty_named as n` patterns transparent — consumers access `n.name` (unchanged). Using `ty_imported` broke constraint checking because it's a different variant that wasn't handled in many match arms.

#### 20b: `offset_of` field name resolution in inline-for loops
**File:** `projects/mtc/src/mtc/lowering/lowering.mt` — `lower_expr` for `expr_offsetof`

When `offset_of(T, field)` appears inside `inline for field in fields_of(T)`, the `field` argument resolves to the inline-for binding. The lowering now checks `ctx.inline_for_element` context and substitutes the actual struct field name from the `ComptimeElement`. Fixed the "Vec3 has no member named 'field'" error.

#### 20c: `&this` double-pointer fix for editable methods
**File:** `projects/mtc/src/mtc/lowering/lowering.mt:1168-1170`

Editable method receivers (`this`) were stored with `pointer = false` even though the type is `ptr[T]`. When `ref_of(this)` was called, the `pointer` check in the `ref_of` handler failed, falling through to `expr_address_of` which emitted `&this` (double pointer). Fixed by computing `recv_is_ptr = is_pointer_or_ref_type(recv_ty)` and using it for both the parameter and local binding.

```mt
// Before: pointer = false (hardcoded)
// After:  pointer = recv_is_ptr (computed from recv_ty)
let recv_is_ptr = is_pointer_or_ref_type(recv_ty)
ir_params.push(ir.Param(name = "this", ty = recv_ty, pointer = recv_is_ptr))
ctx.locals.push(LocalBinding(name = "this", ty = recv_ty, pointer = recv_is_ptr))
```

---

## 2. Example status

### 2.1 Compiling (10/13)

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

### 2.2 Failing (3 examples)

| # | Root Cause | Examples | Errors | Complexity |
|---|-----------|----------|--------|-----------|
| 1 | Missing Task type specializations for deeply nested types + wrong async function refs + libuv callback mismatches | `async_stress_test`, `async_network_lobby` | 99/53 | **HIGH PRIORITY** — remaining async infrastructure gaps |
| 2 | Cross-type `?` propagation (`Result[bool, E]?` in function returning `Result[Bytes, E]` fails to wrap error in correct return type) | `reflection_advanced` | 2 | Medium — needs proper error extraction/wrapping in `lower_propagate_let` |

---

## 3. Remaining work (async infrastructure + ? propagation)

The cross-module type emission fix (P21c) resolved the `NativeSocketStorage`/`NativeSockAddr` typedef issue. The remaining async errors are pre-existing infrastructural gaps:

### 3.1 Async errors (99 + 53 remaining)

| Category | Count | Description |
|----------|-------|-------------|
| Task type specializations | ~30 | `mt_task_std_result_Result_std_option_Option_...` — deeply nested Task types aren't forward-declared or emitted |
| Wrong async function refs | ~15 | `std_async_libuv_runtime_sleep` vs `std_async_runtime_sleep` — wrong module prefix for async runtime functions |
| Callback type mismatches | ~20 | `uv_udp_recv_start`/`uv_close` expect specific callback signatures |
| Missing libuv enum types | ~10 | `uv_tcp_flags`, `uv_fs_event_flags`, etc. — referenced as type aliases but not actual types |
| Heap.release specialization names | ~15 | `std_mem_heap_release__std_net_NativeSocketStorage` — wrong naming |
| Other type mismatches | ~20 | Various pointer/struct type mismatches |

### 3.2 ? propagation (2 errors in reflection_advanced)

The `?` operator on `Result[bool, Error]` inside a function returning `Result[Bytes, Error]` fails because `lower_propagate_let` returns the raw storage value (type `Result[bool, Error]`) instead of extracting the error and wrapping it in `Result[Bytes, Error].failure(error = ...)`.

Fix needed: add `current_fn_return_type` to `LowerCtx`, set it during function lowering, and use it in `lower_propagate_let` to construct the correct failure variant when the propagation type differs from the return type (mirroring Ruby's `prepare_result_propagation_for_inline_lowering` — the `storage_type == return_type` check at line 1122 of `lib/milk_tea/core/lowering/utils.rb`).

---

## 4. Uncommitted changes inventory

The following files have uncommitted modifications. When resuming:

**`projects/mtc/src/mtc/lowering/lowering.mt`** (~13k lines, heavily modified):
- P18: Event wait functions (`build_event_wait_*`), wait_frame struct, `EventRuntimeInfo` wait fields
- P18: `build_event_emit_fn` wait_frame dispatch handling
- P18: `lower_event_method` wait return type + generation local variable fix
- P19: Generation local variable fix in `build_event_subscribe_fn`, `build_event_subscribe_stateful_fn`
- P20b: `offset_of` field name resolution from `ctx.inline_for_element`
- P20c: `recv_is_ptr` fix for editable method `this` parameter
- P21a: `find_generic_method` cross-module search, `qname_last`, removed `type_ref.arguments.len > 0`
- P21a: `lower_call` member-access specialization interception
- P21a: `struct_defining_module_for_type`, `monomorphized_method_c_name` struct/method arg separation
- P21a: Removed fallback struct_args population in `lower_specialized_method`
- P21b: Bare `?` propagation in `lower_stmt` → `stmt_expression`
- P21c: Cross-module typedef emission for type aliases targeting std.c.*
- Prior: Event infrastructure, subscribe builders, variant helpers, guard lowering, etc.

**`projects/mtc/src/mtc/c_backend/c_backend.mt`** (~5500 lines):
- P17: `emit_task_forward_decls`, `emit_task_struct_type` (named struct), `generate_c` ordering
- Prior: `OptStructEntry`, `topo_sort_types`, `emit_event_helpers`, `emit_variant`, etc.

**`projects/mtc/src/mtc/semantic/analyzer.mt`** (~3900 lines):
- P20a: `resolve_named` stores `ty_named(ctx.module_name, name)` instead of `ty_named("", name)`
- Prior: `register_struct_events`, `resolve_field_entries_with_events`, etc.

**`projects/mtc/src/mtc/build.mt`**:
- Prior: `collect_link_flags`: -luv detection for `uses_parallel_for`

**`docs/self-host-plan.md`**:
- P21 updates, current state, remaining work sections refreshed

---

## 5. Resume context

When resuming, build the latest self-host:
```sh
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-current
```

Verify state:
```sh
tmp/mtc-current test projects/mtc -I .   # should be 172/172
tmp/mtc-current build examples/language_baseline.mt -I . --no-cache --no-debug-guards -o /dev/null  # should be OK
tmp/mtc-current build examples/event_stress_test.mt -I . --no-cache --no-debug-guards -o /dev/null  # DONE!
```

Check current fail counts:
```sh
tmp/mtc-current build examples/reflection_advanced.mt -I . --no-cache --no-debug-guards -o /dev/null 2>&1 | grep "error:" | wc -l  # should be 2
tmp/mtc-current build examples/async_stress_test.mt -I . --no-cache --no-debug-guards -o /dev/null 2>&1 | grep "error:" | wc -l  # should be 99
tmp/mtc-current build examples/async_network_lobby.mt -I . --no-cache --no-debug-guards -o /dev/null 2>&1 | grep "error:" | wc -l  # should be 53
```

**Recommended next step**: Fix `?` cross-type propagation (§3.2) — the 2 remaining errors in `reflection_advanced.mt`. This is a narrow, well-understood bug: `lower_propagate_let` needs `current_fn_return_type` to construct the correct failure variant when the propagated `Result[bool, E]` type differs from the enclosing function's `Result[Bytes, E]` return type. See §3.2 and §3.3 for detailed analysis.

After that, address async infrastructure gaps (§3.1): Task type specializations for deeply nested types, wrong async function references, and callback type mismatches.

**Key files for remaining work**:
- `projects/mtc/src/mtc/lowering/lowering.mt` — `lower_propagate_let`, async runtime function references
- `projects/mtc/src/mtc/c_backend/c_backend.mt` — `emit_task_forward_decls`, `emit_task_structs` for deeply nested types
- `lib/milk_tea/core/lowering/utils.rb` — Ruby reference for `prepare_result_propagation_for_inline_lowering`

---

## 6. ? Cross-Type Propagation — Detailed Approach

### 6.1 The bug

In `std.binary.Reader.read_bytes` (returns `Result[Bytes, Error]`):

```mt
this.check_remaining(count)?   # check_remaining returns Result[bool, Error]
```

The self-host's `lower_propagate_let` emits:

```c
__mt_propagate_1 = std_binary_reader_check_remaining(this, count);
if (__mt_propagate_1.kind == ...failure) return __mt_propagate_1;
```

But `__mt_propagate_1` is type `Result[bool, Error]` and the function returns `Result[Bytes, Error]` — type mismatch.

### 6.2 Ruby reference

`lib/milk_tea/core/lowering/utils.rb:1122`:

```ruby
failure_return = if storage_type == return_type
                   result_ref                          # same type → return raw
                 elsif is_option
                   IR::VariantLiteral.new(              # Option → .none
                     type: return_type, arm_name: "none", fields: [])
                 else
                   IR::VariantLiteral.new(              # Result → extract error
                     type: return_type, arm_name: "failure",
                     fields: [IR::AggregateField.new(
                       name: "error",
                       value: variant_binding_projection_expression(
                         result_ref, storage_type, "failure", "error", error_type
                       ),
                     )],
                   )
                 end
```

### 6.3 Approach

Three surgical changes in `lowering.mt`:

1. **Add `current_fn_return_type: types.Type` to `LowerCtx` struct** (~line 96). Set it to `ret_ty` at two points: `lower_function` (~line 1278) and `lower_specialized_method` (~line 7119), just before `lower_function_body`.

2. **Modify `lower_propagate_let` failure-branch construction** (~line 1879), replacing the hardcoded `return storage_ref` with logic mirroring Ruby:
   - If `storage_ty == ctx.current_fn_return_type`: return `storage_ref` (same as today)
   - If `kind == "result"`: extract the error via `storage_ref.data.failure.error` (three-level member access), construct `ir.Expr.expr_variant_literal(ty = ret_ty, arm_name = "failure", fields = [{name="error", value=error_member}])`
   - If `kind == "option"`: construct `ir.Expr.expr_variant_literal(ty = ret_ty, arm_name = "none")`
   
3. **Update `LowerCtx` constructor** (~line 668) with `current_fn_return_type = types.primitive("void")`.

### 6.4 Risk assessment

- **Low risk**: The `LowerCtx` change is additive — all existing paths either use a void default or set the real return type before function body lowering.
- **Self-host tests**: The existing 172 tests will still pass because they don't exercise cross-type `?` propagation.
- **No regression for same-type propagation**: When `storage_ty == ret_ty`, the code path is identical to today.
