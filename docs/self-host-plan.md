# Self-Host Plan: Path to 100% Ruby Parity

Status: **10/13 examples compile. Self-compile deterministic. 172/172 tests pass. P1-P20 DONE.**
Last updated: 2026-07-12 (session end)

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
| `async_stress_test.mt` | FAIL | 143 |
| `async_network_lobby.mt` | FAIL | 100+ |
| `reflection_advanced.mt` | FAIL | 1 |

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
| 1 | Missing `sockaddr_storage` + cross-module type emission from std.net/std.binary | `async_stress_test`, `async_network_lobby` | 143/100+ | **HIGHEST PRIORITY** — Cross-module type collection + system header includes |
| 2 | Method resolution: `r.unpack[CompactHeader]()` finds `std.serialize.unpack` instead of `std.binary.Reader.unpack` | `reflection_advanced` | 1 | Medium — method resolution picks wrong module's generic function |

---

## 3. Remaining work: Cross-Module Import Resolution (PRIORITY #1)

The three failing examples all share a common root cause: **the self-host does not properly collect and emit all transitive type dependencies from imported modules**.

### 3.1 Root Cause Analysis

When `reflection_advanced.mt` or `async_stress_test.mt` imports modules like `std.binary`, `std.net`, or `std.serialize`, the self-host emits their locally-declared types into the C output. However, it does NOT emit:

1. **All transitive generic variant instantiations** — `Result[SocketAddress, Error]`, `Result[ChannelMessage, Error]`, etc. from `std.net` are not in the C output
2. **System header types** — `sockaddr_storage` from `<sys/socket.h>` never gets an `#include`
3. **Proc struct types referencing imported errors** — `proc[..., Error]` structs referencing `std_binary_Error` or `std_net_Error` fail with incomplete type

The type resolution fix (P20a — `ty_named` with module prefix) is the correct architectural direction but is only the FIRST step. It ensures types created BY the analyzer carry their module origin. What's still needed:

- **Step A**: The C backend's `c_type` function does not resolve bare type names (`ty_named("", name)`) by searching program analyses for the defining module. Fix: add a reverse lookup when `n.module_name.len == 0` to find the actual C-qualified name.
- **Step B**: The lowering's `qualify_type` (`imported_type_module`) only searches *direct* imports of the current module. For types from transitive dependencies, the lookup fails. Fix: make `imported_type_module` walk transitive import chains.
- **Step C**: System headers for external bindings (`std.c.net`, etc.) need their `#include` directives emitted into the generated C. The self-host currently emits includes only for directly-imported external files.
- **Step D**: Proc struct types that reference cross-module error types need the error type defined before the proc struct. This is the same ordering issue that P17 fixed for Task types, but for proc types.

### 3.2 Recommended Approach for Next Session

**Step A** is the highest-leverage fix. It makes `c_type` resolve any bare `ty_named("", "Error")` by searching through the program's pending variant declarations to find a qualified version (e.g., `std_binary_Error`). This can be done without major refactoring.

1. In the C backend's `emit_variant`, when emitting arm field types:
   - If `c_type(f.ty)` produces a bare name (no underscore, no module prefix)
   - Search `program.variants` and `gen_variants` for arm fields with the same field name but a qualified type
   - If found, use the qualified C name instead

2. For system headers (`sockaddr_storage`):
   - Walk the IR program's `includes` list and emit `#include` directives for all transitive dependencies
   - Currently only root module's includes are emitted

3. For proc structs:
   - Add proc structs to the topological sort (like Task types were added in P17)
   - Or ensure the error type variants are emitted before proc structs

**Step B** (transitive imports in `imported_type_module`) and **Step D** are architectural improvements needed for full correctness.

### 3.3 reflection_advanced remaining error (method resolution)

The single remaining error in `reflection_advanced.mt`:

```
too few arguments to function 'std_serialize_unpack_...'
```

This is caused by `r.unpack[CompactHeader]()` where `r` is `bin.Reader` (from `std.binary`). The lowering resolves `unpack` to `std.serialize.unpack` instead of `std.binary.Reader.unpack`. The serializer's `unpack` takes `(source: span[ubyte])` as argument, while `Reader.unpack` takes no args (reads from internal buffer).

The bug is in `lower_specialization_call` → `try_generic_method_call` → `find_generic_method`. The function searches all program analyses for a struct/owner that has an `unpack[T]` extending block. Both `std.serialize` (which has a standalone `unpack[T]`) and `std.binary.Reader` (which has `extending Reader: function unpack[T]`) match. The wrong one is chosen.

Fix: `find_generic_method` should prefer the method whose owner matches the receiver type's STRUCT name. Currently it iterates all analyses and returns the first match.

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
- Prior: Event infrastructure, subscribe builders, variant helpers, guard lowering, etc.

**`projects/mtc/src/mtc/c_backend/c_backend.mt`** (~5500 lines):
- P17: `emit_task_forward_decls`, `emit_task_struct_type` (named struct), `generate_c` ordering
- Prior: `OptStructEntry`, `topo_sort_types`, `emit_event_helpers`, `emit_variant`, etc.

**`projects/mtc/src/mtc/semantic/analyzer.mt`** (~3900 lines):
- P20a: `resolve_named` stores `ty_named(ctx.module_name, name)` instead of `ty_named("", name)`
- Prior: `register_struct_events`, `resolve_field_entries_with_events`, etc.

**`projects/mtc/src/mtc/build.mt`**:
- Prior: `collect_link_flags`: -luv detection for `uses_parallel_for`

---

## 5. Resume context

When resuming, build the latest self-host:
```sh
bin/mtc build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-current
```

Verify state:
```sh
tmp/mtc-current test projects/mtc -I .   # should be 172/172
tmp/mtc-current build examples/language_baseline.mt -I . --no-cache --no-debug-guards -o /dev/null  # should be OK
tmp/mtc-current build examples/event_stress_test.mt -I . --no-cache --no-debug-guards -o /dev/null  # DONE!
```

Check current fail counts:
```sh
tmp/mtc-current build examples/reflection_advanced.mt -I . --no-cache --no-debug-guards -o /dev/null 2>&1 | grep "error:" | wc -l  # should be 1
tmp/mtc-current build examples/async_stress_test.mt -I . --no-cache --no-debug-guards -o /dev/null 2>&1 | grep "error:" | wc -l  # should be 143
tmp/mtc-current build examples/async_network_lobby.mt -I . --no-cache --no-debug-guards -o /dev/null 2>&1 | grep "error:" | wc -l  # should be 100+
```

**Recommended next step — PRIORITY #1**: Fix cross-module type emission in the C backend (Step A from §3.2):
1. Fix `c_type` for `ty_named("", name)` to search program analyses for the defining module
2. Emit system headers from all transitive external-file imports
3. After fixing, retest all 3 failing examples

**Key files for remaining work**:
- `projects/mtc/src/mtc/c_backend/c_backend.mt` — `c_type`, `emit_variant`, `generate_c` includes emission
- `projects/mtc/src/mtc/lowering/lowering.mt` — `imported_type_module`, `find_generic_method`
- `projects/mtc/src/mtc/semantic/analyzer.mt` — `resolve_named` (already fixed)
- `lib/milk_tea/core/lowering/calls.rb` — Ruby reference for method resolution
- `lib/milk_tea/core/c_backend.rb` — Ruby reference for C type emission
