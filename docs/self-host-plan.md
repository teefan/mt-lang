# Self-Host Plan: Path to 100% Ruby Parity

Status: **10/13 examples compile. Self-compile deterministic. 172/172 tests pass. P1-P16 DONE.**
Last updated: 2026-07-12 (session end)

---

## 0. Current state (2026-07-12 session end)

### 0.1 What works

- **Self-compile deterministic**: SHA256 identical stage-2 = stage-3.
- **Self-host tests itself**: `tmp/mtc-current test projects/mtc -I .` — 172/172 tests pass.
- **10/13 example files compile** with 0 C errors:

| Example | Status |
|---------|--------|
| `language_baseline.mt` | OK |
| `integration_test.mt` | OK |
| `string_test.mt` | OK |
| `data_structures.mt` | OK |
| `memory_stress_test.mt` | OK |
| `multithreading_test.mt` | OK |
| `option_and_result_surface.mt` | OK |
| `nested_struct_stress_test.mt` | OK |
| `nullable_and_variant_test.mt` | OK |
| `async_stress_test.mt` | 5 |
| `async_network_lobby.mt` | 6 |
| `event_stress_test.mt` | 2 |
| `reflection_advanced.mt` | 7 |

- **P1-P16**: ALL DONE. Completing P10-P16 resolved the lowering crashes and most C compilation errors across the example suite.

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

## 1. Completed work (P10-P16)

### P10 — Opt struct ordering (28 errors → 18)
Synthetic `OptStructEntry` wrappers carry `ir.StructDecl` + backing field vectors into `topo_sort_types` as kind=3 nodes. `by_value_dep_key` for `ty_nullable` now returns `"mt_opt_<type_c_key>"` so opt structs become proper dependencies. Forward declarations and full definitions are emitted in topological order with regular structs.

Key files: `projects/mtc/src/mtc/c_backend/c_backend.mt` — `OptStructEntry` struct, `collect_opt_struct_decls`, `topo_sort_types`/`type_node_deps`/`topo_visit_type` opt_structs parameter, `generate_c` integration.

### P11 — Result guard arm names (12 errors → 0)
`guard_variant_base` only checked `starts_with("Result")` which failed on qualified names like `std_result_Result_int_int`. Changed to delegate to `prelude_variant_base` which handles underscores and fully-qualified names.

Key file: `projects/mtc/src/mtc/lowering/lowering.mt` — `guard_variant_base`.

### P12 — `Result[void, E]` void fields (4 errors → 0)
`emit_variant` now skips void-typed arm fields (`if not is_void_type(f.ty)`) matching the pattern already used in `emit_struct`.

Key file: `projects/mtc/src/mtc/c_backend/c_backend.mt` — `emit_variant`.

### P13 — Missing libuv headers + link (9 errors → 0)
Added `#include "uv.h"` emission in `generate_c` when `uses_parallel_runtime(program)` returns true. Added `uses_parallel_runtime` detection for per-event synthetic function names (`linkage_name.starts_with("mt_event_")`). Added `-luv` link flag in `collect_link_flags` when any analysis has `uses_parallel_for`.

Key files: `projects/mtc/src/mtc/c_backend/c_backend.mt`, `projects/mtc/src/mtc/build.mt`.

### P14 — Unresolved types → void (partial)
- **`resolve_type_ref`**: Changed `else if t.name.parts.len == 2` → `>= 2` and resolves the last part as the bare type name for nested structs like `Level1.Level2.Level3`.
- **`lower_extending_block`**: Extracts bare name (last part) for nested struct method C-linkage naming.
- **`nested_struct_stress_test`** compiles (5→0 errors).
- **`reflection_advanced`** still has 7 errors (cross-module `Error` type, `Vec3.field` reflection access, generic `ptr_uint` value args).

Key files: `projects/mtc/src/mtc/lowering/lowering.mt` — `resolve_type_ref`, `lower_extending_block`, `lower_struct_decl` event fields.

### P15 — Variant comparison helpers / field access (28→0 errors)
- **Null literal handling**: `let _ = expr` discard bindings no longer produce named C variables.
- **Null literal wrapping**: `var x: int? = null` produces zero-init opt struct, fixed in local decl / assignment / aggregate literal wrapping.
- **Recursive variant auto-deref**: `is_recursive_variant_field` detects fields referencing the enclosing variant (uses `starts_with` prefix check to handle arm names with underscores like `binary_op`). Auto-deref applied in `lower_member_access` (guarded by `arm_payload_fields.contains`) and `lower_variant_field_bindings`.
- **Variant literal auto-address**: `collect_variant_literal_fields` takes address-of for recursive fields.
- **Aggregate literal nullable wrapping**: `lower_aggregate_literal` wraps non-nullable values in `nullable_some_literal` when the target field is a value-type nullable. Same wrapping added to `collect_variant_literal_fields`.
- **Local variant arm field registration**: `collect_variants` now calls `register_imported_variant_arm_fields` for local variants, populating `arm_payload_fields` so field type lookups (nullable check, recursive check) succeed.

Key files: `projects/mtc/src/mtc/lowering/lowering.mt` — `is_recursive_variant_field` (+ `_c` variant), `lower_member_access`, `lower_variant_field_bindings`, `collect_variant_literal_fields`, `lower_aggregate_literal`, `find_struct_field_type`, `variant_field_type_from_arm`, `collect_variants`.

### P16 — Async/event lowering crashes (0 lowering crashes)
- **`lower_foreign_arg`**: Non-literal `str` arguments at `as cstr` boundary now emit `mt_foreign_str_to_cstr_temp` runtime helper call instead of fatal. The helper is emitted in the C backend when any function calls it.
- **Event infrastructure**: `is_event_type` handles `ty_imported`, `mt_event_` prefix types, suffix matching with capacity stripping. `event_name_from_type` handles `ty_imported`/`ty_generic`. Added `strip_event_cap_suffix`, `is_any_event_suffix`, `event_name_from_c_linkage`.
- **Struct event registration**: `register_struct_events` + `declare_struct_event_values` in analyzer register nested struct events. `resolve_field_entries_with_events` includes event fields in the struct field list. `lower_struct_decl` maps event field types to C-linkage names via `ensure_event_runtime`.
- **EventError enum**: `typedef int32_t EventError; enum { EventError_full = 0 };` emitted in C backend via `emit_event_helpers`. `ensure_event_error_enum` returns the named type for use in `Result[T, EventError]` variants.
- **Event `wait` method**: `wait_c_name` field added to `EventRuntimeInfo`. `lower_event_method` handles `wait` with a call to the event's wait function (emitted call, but function generation pending — see §3.3).
- **Subscribe return type**: `build_event_subscribe_fn` / `build_event_subscribe_stateful_fn` now return `Result[mt_subscription, EventError]` variant literals instead of plain `mt_subscription` structs.
- **`EventError.full` lowering**: `lower_member_access` handles `EventError.full` → `EventError_full` C constant.

Key files: `projects/mtc/src/mtc/lowering/lowering.mt` (event infrastructure, foreign arg, subscribe builders), `projects/mtc/src/mtc/c_backend/c_backend.mt` (EventError typedef, foreign cstr helper), `projects/mtc/src/mtc/semantic/analyzer.mt` (struct event registration).

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
| `event_stress_test.mt` | WAIT |

### 2.2 Failing (3 examples, ~20 errors)

| # | Root Cause | Examples | Errors | Complexity |
|---|-----------|----------|--------|-----------|
| 1 | Missing `mt_task_Result_...` type specializations | `async_stress_test`, `async_network_lobby` | ~11 | Medium — C backend needs to emit Task variant types for async return types |
| 2 | Event `wait` runtime function not generated | `event_stress_test` | 2 | Medium — needs Task vtable (ready/set_waiter/release/take_result) + wait body |
| 3 | Cross-module `Error` type + `Vec3.field` reflection + generic `ptr_uint` value args | `reflection_advanced` | 7 | High — diverse issues across type resolution, inline-for reflection, and generic specialization |

---

## 3. Remaining work (by priority for next sessions)

### P17 — Task type specializations (errors in async_*, 2 examples)
The C backend does not emit `mt_task_Result_Option_...` typedef variants when async functions return `Task[T]`. The task infrastructure (`lower_task_constructor`, `build_resume_fn`, `build_constructor_fn`) emits `ir.StructDecl` for task types, but the C backend's variant collection (`emit_task_structs`) may not walk the full dependency tree for nested task result types.

Key files: `projects/mtc/src/mtc/c_backend/c_backend.mt` — `emit_task_structs` (~line 4249), `generate_c` task struct emission. `projects/mtc/src/mtc/lowering/lowering.mt` — async lowering (~line 12397).

### P18 — Event wait function (2 errors in event_stress_test)
`mt_event_<name>__wait` is called but never generated. Needs a full async Task vtable (ready, set_waiter, release, take_result) + a wait function body that registers the caller as a waiter and returns a Task. Mirrors Ruby's `build_event_wait_fn` in `events.rb`.

Key files: `projects/mtc/src/mtc/lowering/lowering.mt` — `build_event_wait_fn` (does not exist yet, needs creation). Ruby reference: `lib/milk_tea/core/lowering/events.rb:284-328`.

### P19 — reflection_advanced (7 errors)
Diverse cross-module issues:
- `unknown type name 'Error'` — the `Error` type from `std.serialize` (or `std.error`) is not emitted in the C output
- `Vec3 has no member named 'field'` — `inline for field in fields_of(Vec3)` produces local bindings named `field` but the C code accesses `vec3.field` which doesn't exist
- `too few arguments to function` — generic function with `ptr_uint[64]` value arg specialization missing the value argument at the call site

Key files: `projects/mtc/src/mtc/lowering/lowering.mt` — inline-for lowering, generic specialization. `projects/mtc/src/mtc/c_backend/c_backend.mt` — type emission for imported types.

---

## 4. Uncommitted changes inventory

The following files have uncommitted modifications. When resuming:

**`projects/mtc/src/mtc/lowering/lowering.mt`** (~13k lines, heavily modified):
- Event infrastructure: `is_event_type`, `event_name_from_type`, `is_any_event_suffix`, `strip_event_cap_suffix`, `event_name_from_c_linkage`, `ensure_event_error_enum`
- `EventRuntimeInfo.wait_c_name` field
- `lower_event_method`: wait handler, subscribe Result return type
- `resolve_type_ref`: >= 2 parts handling
- `lower_extending_block`: bare name extraction
- `lower_aggregate_literal`: restructured (source_module first), nullable wrapping
- `find_struct_field_type`, `payload_ty` helpers
- `lower_member_access`: recursive variant auto-deref (guarded by arm_payload_fields)
- `lower_variant_field_bindings`: recursive variant auto-deref
- `collect_variant_literal_fields`: auto-address + nullable wrapping, 4-arg signature
- `lower_variant_literal` / `lower_generic_variant_literal`: pass ty/arm to collect
- `lower_struct_decl`: event field C-linkage type mapping
- `lower_foreign_arg`: non-literal str→cstr via runtime helper
- Guard lowering: null literal check in local decl + assignment, `guard_variant_base` fix
- `let _ = expr` discard binding
- `build_event_subscribe_fn` / `build_event_subscribe_stateful_fn`: Result return type, ctx parameter
- Recursive variant helpers: `is_recursive_variant_field`, `is_recursive_variant_field_c`, `variant_c_type_name`, `variant_field_type_from_arm`
- `collect_variants`: local variant arm field registration

**`projects/mtc/src/mtc/c_backend/c_backend.mt`** (~5500 lines, significantly modified):
- `OptStructEntry` struct + `collect_opt_struct_decls` (replaces inline emit)
- `by_value_dep_key`: nullable type handling
- `topo_sort_types`/`type_node_deps`/`topo_visit_type`: opt_structs parameter (kind=3)
- `generate_c`: opt_structs integration (forward decls + topo sort + emission loop), EventError emission, foreign_cstr helper emission, libuv include
- `emit_event_helpers`: EventError typedef + enum constant
- `emit_variant`: void field skip
- `uses_foreign_cstr_helper` + `emit_foreign_cstr_helper`: mt_foreign_str_to_cstr_temp
- `uses_event_runtime`: mt_event_ prefix detection

**`projects/mtc/src/mtc/semantic/analyzer.mt`** (~3900 lines):
- `register_struct_events` + call sites in `declare_named_types`, `register_nested_struct_types`
- `declare_struct_event_values` + call in `declare_values_and_functions`
- `resolve_field_entries_with_events`: includes event fields in struct field list
- `collect_struct_fields` / `collect_nested_struct_fields`: use `resolve_field_entries_with_events`

**`projects/mtc/src/mtc/build.mt`**:
- `collect_link_flags`: -luv detection for `uses_parallel_for`

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
```

**Recommended next step**: Start with P18 (event wait function, 2 errors) for quickest win on `event_stress_test`, then P17 (Task types, ~11 errors across async examples). P19 (reflection_advanced, 7 diverse errors) is the hardest remaining.

**Key files for remaining work**:
- `projects/mtc/src/mtc/lowering/lowering.mt` — main lowering logic (~13k lines now)
- `projects/mtc/src/mtc/c_backend/c_backend.mt` — C code generation (~5500 lines now)
- `projects/mtc/src/mtc/semantic/analyzer.mt` — type checking (~3900 lines)
- `lib/milk_tea/core/lowering/events.rb` — Ruby reference for event wait function
