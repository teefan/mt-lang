# Self-Host Plan

Status: **SELF-HOSTING FIXED POINT ACHIEVED.** Stage2 == stage3 byte-identical.
177/177 self-tests pass across 9 test files. **`mtc lint` has 31 rules**
(4 new Tier-1/3 AST rules, 2 new tooling features). `--select`/`--ignore`
supported. Lint wired into `mtc check`. Bootstrap via `tools/bootstrap.sh`.

Last updated: 2026-07-15

---

## 0. Current State

### 0.1 Bootstrap

```sh
tools/bootstrap.sh                                 # full 3-stage + fixed point + tests
tools/bootstrap.sh --stage 1 --no-verify            # fast dev build
MTC_BOOTSTRAP=build/stage2/mtc tools/bootstrap.sh   # Ruby-free bootstrap
```

Stage2 binary is the distributable compiler artifact. Stage3 exists only for
fixed-point verification (`diff stage2.c stage3.c` must be empty).

### 0.2 Example parity — language

13/13 language examples build with the self-hosted compiler. 12/13 run
identically to Ruby; `async_stress_test` crashes under both (a pre-existing
libuv runtime bug).

### 0.3 Example parity — raylib

**178 of 219 raylib examples build** (81%, up from 85). The remaining 41
files (85 C errors) are in §3.

### 0.4 CLI parity

| Status | Commands |
|--------|----------|
| **FULL**  | lex, parse, lower, emit-c, format, help, version, check, build, run, test, lint |
| **NOT IMPL** | run-module, new, debug, deps, toolchain, bindgen, cache, docs, snapshot, completions |

### 0.5 Linter

31 rules implemented (12 original AST-only + 5 scope-tracking + 9 new Tier-1
AST rules + 4 new Tier-3/heuristic rules + 1 ownership rule).

---

## 1. Landed C-Backend External-Type Fixes (2026-07-15)

This was the largest gap between the self-host and Ruby compilers. The self-host
could not compile raylib examples because it failed to resolve C type names for
structs/enums imported from external (`std.c.*`) modules through re-exporting
type aliases.

### 1.1 Type alias chain resolution

| Fix | What |
|-----|------|
| `resolve_type_ref` follows `type_alias_types` | Bare names and two-part names (`rl.Color`) follow `type Color = c.Color` to `std.c.*` module |
| `lower_call` struct routing via aliases | `rl.Camera2D(...)` → aggregate literal, not phantom function call |
| `resolve_single_imported_type` helper | Cross-module alias chain resolution |
| `imported_member_c_name` | Member C names through alias chains |
| `import_qualified_type` alias chain | Fallback type resolution via aliases |

### 1.2 Struct field access from external modules

| Fix | What |
|-----|------|
| `concrete_field_type` handles `ty_imported` | Field access on imported external structs |
| Field type qualification in owner context | Correct C module for field type names |
| `lower_index_access` IR type fallback | Index on member chains with external types |
| `imported_type_module` checks `type_alias_types` | Correct C module for re-exported aliases in `qualify_type` |

### 1.3 Foreign function boundary

| Fix | What |
|-----|------|
| `resolve_foreign_c_name` unwraps casts+functions | `= State<-c.GuiGetState()` mappings |
| `lower_foreign_arg` fmode_in address-of | `in value: T as const_ptr[void]` takes `&` |
| `is_ref_type` check in foreign args | Skip `&` for `ref[T]`/`own[T]` arguments |
| Null-arg address-of skip | `null` is already a pointer |

### 1.4 C backend preamble and type emission

| Fix | What |
|-----|------|
| `#include <stdio.h>` when `use_fatal`/format | Fixed `fputs`/`snprintf` undeclared |
| `#include <stdlib.h>` for format/foreign cstr | Fixed `malloc`/`free` undeclared |
| `ty_named` strips `std.c.` prefix | `std_c_raylib_Texture` → `Texture` |
| `struct tm` prefix for `<time.h>` | `tm` → `struct tm` |
| Span types in no-structs programs | `mt_span_float` typedef for `image_kernel` |

### 1.5 Array handling

| Fix | What |
|-----|------|
| Checked-index helpers skip nested arrays | `array[array[float,N],M]` → plain index |
| `c_declaration` multi-dim arrays | `float name[N][M]` instead of invalid `float[M] name[N]` |
| Null literal address-of skip | `&(NULL)` → `NULL` |

### 1.6 Bootstrap tooling

| Fix | What |
|-----|------|
| `tools/bootstrap.sh` | 3-stage build + fixed-point + test |
| `discover_project_root` | Auto-find `std/` parent, no `-I .` needed |

---

## 2. Remaining C-Backend Gaps

### 2.1 Unresolved C types from headers (4 files, 8 errors)

| Issue | Examples | Root cause |
|-------|----------|-----------|
| `variable 'pan' declared void` | `sound_positioning` | C struct field type from external header not resolved |
| `field 'production' has incomplete type` | `penrose_tile`, `strings_management` | Struct type from C header incomplete |
| `variable 'projection_scale' declared void` | `tesseract_view` | Same as above |

### 2.2 Address-of on non-lvalue (3 files, 11 errors)

`lvalue required as unary '&'` in `skybox_rendering`, `basic_pbr`, `depth_rendering`. Foreign function calls with pointer-type params where the lowered argument is a complex expression (not an addressable lvalue). The lowering should create a temp variable and take its address.

### 2.3 Checked-index helpers for local struct types (5 files, 30 errors)

`incompatible pointer type` for `mt_checked_index_array_EnvItem_0` and similar. Local struct types in example files produce checked-index helpers with incorrect pointer signatures. The array length is resolved as `0` instead of the MT constant value — `array_length` returns 0 for non-literal-int type args.

### 2.4 Foreign function argument count/style (2 files, 13 errors)

`too few arguments` and `incompatible type for argument` in `basic_pbr`, `image_kernel`. Foreign function calls with span/array arguments where the boundary projection doesn't match the C parameter count.

### 2.5 Pre-existing / environment (7 files, 7 errors)

| Issue | Examples |
|-------|----------|
| `TracyC.h: No such file` | `tracy_profiler` |
| Linker errors (`ld returned 1`) | `rlgl_loader`, `boxed_text` |
| `redefinition of 'struct Matrix'` | `cel_shading` |
| `implicit declaration of function 'v'` | `raylib_opengl_interop` |
| `mt_span_ubyte undeclared` | `storage_values` |

---

## 3. Remaining Linter Gaps (unchanged from previous)

### 3.1 Ownership — 1 remaining

| Rule | Status |
|------|--------|
| `owning-release-leak` | DEFERRED — needs sema_facts for `own[T]` type detection |

### 3.2 Semantic-facts — 2 remaining

| Rule | Status |
|------|--------|
| `redundant-cast` | Needs expression type resolution |
| `prefer-own-ptr` | Needs `own[T]` vs `ptr[T]` distinction |

### 3.3 Full CFG — 5 rules (very low ROI)

| Rule | Needs |
|------|-------|
| `dead-assignment` | Builder + Liveness |
| `unreachable-code` | Builder + Reachability |
| `constant-condition` | Builder + ConstantPropagation |
| `redundant-null-check` | Builder + NullabilityFlow |
| `loop-single-iteration` | Builder + Termination |

Combined impact: 9 warnings across the self-host codebase.

### 3.4 Tooling — 2 remaining

| Gap | Effort |
|-----|--------|
| `--fix` | Medium — per-rule auto-fix logic |
| `.mt-lint.yml` config | Medium — TOML parsing + rule config |

---

## 4. Out-of-scope Subsystems

| Gap | Effort |
|-----|--------|
| Package-graph resolution (`--locked`/`--frozen`) | Large |
| Build cache | Large |
| `--bundle` / `--archive` | Medium |
| Wasm compilation (emcc) + preview server | Large |
| `--jobs` parallel test execution | Medium |
| `--sanitize` | Medium |
| `run-module`, `new`, `debug`, `deps`, `toolchain`, `bindgen`, `cache`, `docs`, `snapshot`, `completions` | Varies |
