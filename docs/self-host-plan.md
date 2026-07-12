# Self-Host Plan: Path to 100% Ruby Parity

Status: **4/13 examples compile. Self-compile deterministic. 172/172 tests pass. P1-P9 DONE.**
Last updated: 2026-07-12

---

## 0. Current state (2026-07-12)

### 0.1 What works

- **Self-compile deterministic**: SHA256 identical stage-2 = stage-3.
- **Self-host tests itself**: `tmp/mtc-current test projects/mtc -I .` — 172/172 tests pass.
- **4/13 example files compile** with 0 C errors:

| Example | Status |
|---------|--------|
| `language_baseline.mt` | OK |
| `integration_test.mt` | OK |
| `string_test.mt` | OK |
| `data_structures.mt` | OK |

- **P1-P9**: ALL DONE. `own[T]` support, event runtime functions, cross-module naming, assignment wrapping, pointer coercion fixes.

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

# Generate C for comparison
bin/mtc emit-c examples/language_baseline.mt -I . > /tmp/baseline-ruby.c
tmp/mtc-current emit-c examples/language_baseline.mt -I . > /tmp/baseline-self.c
diff /tmp/baseline-ruby.c /tmp/baseline-self.c | wc -l   # 4577

# Compile examples (4 OK, 9 fail — see status below)
tmp/mtc-current build examples/language_baseline.mt -I . --no-cache --no-debug-guards -o tmp/baseline
tmp/mtc-current build examples/string_test.mt      -I . --no-cache --no-debug-guards -o tmp/st
tmp/mtc-current build examples/integration_test.mt  -I . --no-cache --no-debug-guards -o tmp/it
tmp/mtc-current build examples/data_structures.mt  -I . --no-cache --no-debug-guards -o tmp/ds
```

### 0.3 CLI coverage

```
mtc lex/parse/check/lower/emit-c         Full pipeline
mtc build [-I DIR] [-o] [--cc] [--keep-c] [--profile] [--platform] [--debug-guards|--no-debug-guards] [--no-cache]
mtc run   [-I DIR] [-o] [--cc] [--profile] [--platform] [--debug-guards|--no-debug-guards] [--no-cache]
mtc test  <dir> [-I DIR]                 Discover, build runner, execute, report
mtc format <file> [--check|--write]      Parse + pretty-print
mtc help                                 Print help
```

NOTE: `mtc lint` is not implemented — deferred.

---

## 1. Completed work (5 commits)

| Commit | Description |
|--------|-------------|
| `03f24850` | `own[T]` type support, event stateful subscribe, `ctx.type_substitution` leak repairs |
| `c1e20171` | Cross-module generic struct specialization naming (`spec_type_key`) |
| `06e493a1` | Variant arm C keyword sanitization (`sizeof` → `sizeof_`, `switch` → `switch_`) |
| `f8526015` | Remove `ty_imported` from pointer-like checks; nullable assignment wrapping; opt struct after struct defs |
| `03a8522e` | `is_pointer_or_ref_type` handles `ty_nullable` (fixes `*pivot` auto-deref in `coerce_arg_to_param`) |

### 1.1 Fix details

#### `own[T]` type support
`own` was missing from 5 type-checking functions across the lowering, C backend, and semantic analyzer. Added to:
- `is_generic_constructor_name` (sema) — recognizes `own[T]` as a valid type constructor
- `pointer_like_ctor_name` (lowering) — peels `own` layer during type inference
- `is_builtin_pointer_generic` (lowering) — prevents monomorphization of `own` as a user struct
- `is_pointer_or_ref_type` (lowering) — treats `own` as a pointer-like type
- `is_ptr_type` (C backend) — renders `own` with `*` suffix

#### `ctx.type_substitution` leak
Three locations where the current function's type substitution leaked into cross-module struct/function specializations:
- `extract_generic_struct_fields` — Vec field types were resolving as `str` instead of actual type arg
- `lower_specialized_function` — heap function return types resolved with wrong T
- `lower_and_cache_specialization_with_sub` — owner module context switch leaked subst

#### Cross-module struct specialization naming
`specialization_key` and `try_inferred_generic_call` used `type_c_key` without module prefix, so `Node[int,bool]` from `std.map` collided with `Node[int,bool]` from `std.linked_map`. Added `spec_type_key` that recursively qualifies user-defined generic struct types with the caller's module prefix.

#### Variant arm C keyword sanitization
Variant arms named `sizeof` and `switch` collide with C keywords when used as data union fields. Added `c_safe_field_name` (C backend) and `sanitize_arm_field` (lowering match arm access) that append `_` to C keywords.

#### Value-type nullable for imported structs
Removed `ty_imported` from `is_nullable_pointer_like` (lowering) and `is_pointer_like_for_nullable` (C backend). Imported struct types like `std.string.String` are now correctly treated as value-type nullable (`mt_opt_String`) rather than raw pointers with NULL. Added nullable wrapping for assignment statements (`String? = String`).

#### `coerce_arg_to_param` nullable fix
`is_pointer_or_ref_type` only matched `ty_generic`, missing `ty_nullable` types like `ptr[Node]?`. This caused `coerce_arg_to_param` to dereference (`*pivot`) pointer arguments when the parameter was a nullable pointer type. Added `ty_nullable` arm that recurses into the base type.

---

## 2. Example status

### 2.1 Compiling (4/13)

| Example | Errors |
|---------|--------|
| `language_baseline.mt` | 0 |
| `integration_test.mt` | 0 |
| `string_test.mt` | 0 |
| `data_structures.mt` | 0 |

### 2.2 Failing — pre-existing issues (9 examples, 111 errors)

All remaining errors were verified to exist before the `ty_imported` removal (commit `HEAD~2`). None are regressions from the 5 fix commits.

| # | Root Cause | Examples | Errors | Complexity |
|---|-----------|----------|--------|-----------|
| 1 | Opt struct ordering: `mt_opt_*` typedef before base struct | `nullable_and_variant_test` | 28 | High — needs opt structs in `topo_sort_types` |
| 2 | Result guard uses Option arm names (`kind_none`, `data.some`) | `option_and_result_surface` | 12 | Medium — variant arm resolution bug |
| 3 | `Result[void, E]` → `void value` field (void can't be struct member) | `memory_stress_test` | 4 | Low — special-case void arm payload |
| 4 | Missing `#include "uv.h"` from `std.c.libuv` external module | `multithreading_test` | 9 | Low — `collect_includes` skips external files |
| 5 | Unresolved types → `void` locals/fields | `nested_struct_stress_test`, `reflection_advanced` | 5+17 | Medium — type resolution in cross-module contexts |
| 6 | Variant comparison helpers not generated (==/!=) | `nullable_and_variant_test` | — | Medium — needs equality helpers for value-type variants |
| 7 | Value-type nullable initializer wrapping | `nullable_and_variant_test` | — | Medium — `let x: int? = 5` needs `{has_value=true, value=5}` |
| 8 | Implicit function declarations (method lowering for nested structs) | `nested_struct_stress_test` | — | Low — method resolution in cross-module contexts |
| 9 | Lowering crash (SIGABRT) | `async_network_lobby`, `async_stress_test`, `event_stress_test` | 0 | High — async/event runtime lowering paths |

---

## 3. Remaining work (by priority for next sessions)

### P10 — Opt struct ordering (#1, 28 errors)
Opt structs (`mt_opt_X`) are emitted inline as `typedef struct { bool has_value; X value; } mt_opt_X;` at a fixed position before the topo-sorted struct definitions section. Structs that reference opt types (e.g. `Config { mt_opt_int port; }`) are emitted after, but opt structs referencing their base types (e.g. `mt_opt_String { String value; }`) need the base struct to be fully defined first.

**Fix**: Build `StructDecl` entries for each needed opt type and merge them into the struct array passed to `topo_sort_types`. The topological sort will naturally order base-structs before opt-structs before dependent-structs.

Key files: `projects/mtc/src/mtc/c_backend/c_backend.mt` — `emit_opt_struct_defs_from_program` (~line 4572), `topo_sort_types` (~line 2308), `emit_struct` (~line 1900).

### P11 — Result guard arm names (#2, 12 errors)
Result guards (`let value = res else:`, `let value = res else as error:`) generate `kind_none` instead of `kind_failure` and access `data.some` instead of `data.success`. The guard lowering at lines 1934/1953 correctly uses `"failure"`/`"success"` for Result, so the bug may be in the variant name resolution or the `guard_storage_kind` function returning `"option"` instead of `"result"`.

Key files: `projects/mtc/src/mtc/lowering/lowering.mt` — `guard_storage_kind` (~line 1855), `guard_failure_condition` (~line 1921), `guard_success_projection` (~line 1964).

### P12 — `Result[void, E]` void fields (#3, 4 errors)
When a variant arm has `void` as the payload type (e.g. `Result[void, int].success`), the lowering generates a struct with `void value;` which is invalid C. The Ruby compiler skips the payload struct entirely for void-typed arms.

Key files: `projects/mtc/src/mtc/lowering/lowering.mt` — `ensure_generic_variant` (~line 2282), `emit_variant` (~line 2113).

### P13 — Missing libuv headers (#4, 9 errors)
`std.c.libuv` is an external file with `include "uv.h"` but the `collect_includes` function only visits `module_raw` modules, not `module_external`. External files with `include` directives need their headers collected.

Key files: `projects/mtc/src/mtc/lowering/lowering.mt` — `collect_includes` (~line 1041), `is_raw_module` (~line 427).

### P14 — Unresolved types → void (#5, 22 errors)
Various types resolve to `void` (error type) in cross-module contexts, producing `void v` locals and `void value` struct fields. Likely a type resolution failure when a struct/function from a transitive import module has not had its declarations registered in the current analysis.

Key files: `projects/mtc/src/mtc/lowering/lowering.mt` — `resolve_type_ref` (~line 2352), `resolve_field_type_ref` (~line 8899).

### P15 — Variant comparison helpers (#6)
Variants used in `==` / `!=` comparisons need per-variant helper functions that compare `kind` and payload fields. These are not generated for value-type variants.

### P16 — Async/event lowering crash (#9)
`async_network_lobby`, `async_stress_test`, `event_stress_test` crash with SIGABRT during the lowering phase. The async runtime lowering (`std.async` → `std.libuv`) has incomplete paths that call `fatal()`.

Key files: `projects/mtc/src/mtc/lowering/async.mt`, `projects/mtc/src/mtc/lowering/lowering.mt` — async function lowering.

---

## 4. Resume context

When resuming, build the latest self-host:
```sh
bin/mtc build projects/mtc -I . --no-cache --no-debug-guards -o tmp/mtc-current
```

Verify state:
```sh
tmp/mtc-current test projects/mtc -I .   # should be 172/172
tmp/mtc-current build examples/language_baseline.mt -I . --no-cache --no-debug-guards -o /dev/null  # should be OK
```

**Recommended next step**: Start with P13 (libuv headers — low complexity, 9 errors) or P12 (void fields — low complexity, 4 errors) for quick wins. Then tackle P10 (opt struct ordering — high complexity, 28 errors) as the highest-impact fix.

**Key files for all remaining work**:
- `projects/mtc/src/mtc/lowering/lowering.mt` — main lowering logic (~12,681 lines)
- `projects/mtc/src/mtc/c_backend/c_backend.mt` — C code generation (~5,444 lines)
- `projects/mtc/src/mtc/semantic/analyzer.mt` — type checking (~3,855 lines)
- `projects/mtc/src/mtc/lowering/async.mt` — async runtime lowering (~291 lines)
