# Self-Host Plan

Status: **SELF-HOSTING FIXED POINT ACHIEVED.** Stage2 == stage3 byte-identical.
177/177 self-tests pass across 9 test files. **Raylib parity: 213/219 build**
(97%; the 6 remaining are 2 non-buildable support files, 2 shared-with-Ruby
compiler limitations, and 2 vendored-library (GLFW/Tracy) build gaps — none is a
self-host-only codegen bug). 13/13 language examples build. **`mtc lint` has 31
rules** (4 new Tier-1/3 AST rules, 2 new tooling features). `--select`/`--ignore`
supported. Lint wired into `mtc check`. Bootstrap via `tools/bootstrap.sh`.

**Next-session work is in §5.**

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

**213 of 219 raylib examples build** (97%, up from 178). Zero regressions
against the previously-passing set. The 6 remaining are **not self-host-only
codegen gaps** — see §2 for the exact, generated-C-verified root cause of each:

- **2 non-buildable support files** (`rlgl_loader`, `boxed_text`): an `external`
  raw-binding file and a `main`-less helper library. Both compilers correctly
  refuse them (they are not executables).
- **2 shared compiler limitations** (`basic_pbr`, `cel_shading`): both compilers
  fail identically — an array-returning call used as an aggregate-literal field
  initializer, and an `rlgl.h`-before-`raylib.h` include-order `struct Matrix`
  redefinition.
- **2 vendored-library builds** (`rlgl_standalone`, `tracy_profiler`): the
  compiler emits correct C but the build driver would need to compile a
  vendored library from source (GLFW → `libglfw3`, the Tracy client).

The 2026-07-15 gap-closing landed the following fixes (all under a held
fixed point, 177/177 tests, 13/13 language examples):

| Area | Fix |
|------|-----|
| Inline foreign mappings | Full argument-substitution lowering for `= c.Foo(int<-x, span.data, ...)`-style mappings (raygui/rlgl/raymath/raylib), rendered as GCC statement-expressions; recovered the ~18 raygui crashers plus `save_file_data`/`image_kernel_convolution` |
| `let _ = expr` | Self-host dropped the side-effecting call; now emits it as an expression statement (matched the async path) |
| Array length consts | Fold module-level int constants and generic value params in `array[T, CONST]` / `str_buffer[N]` in both analyzer and lowering |
| Nested array C decl | `array[array[T, M], N]` now emits `T x[N][M]` (outer dim first) |
| By-value array params | Array parameters copied into a local (`_input` + memcpy) so `&param` is pointer-to-array |
| Float-literal fallback | `<float-literal> + <expr>` no longer mistyped `void` |
| Member-access fallback | `rect.height` resolves the field type, not the receiver type |
| Array-to-array assignment | `arr = other_arr` emits `memcpy` |
| `str_buffer[N]` fields | Emit the backing struct (with `char[N+1]`) ordered before its users |
| `out`/`inout` foreign args | Always take the lvalue's address, except when the arg is already a pointer to a value-typed slot (an editable-method `this`) |
| Foreign `in` non-lvalue | Materialize a temp so `&literal` becomes `&temp` |
| `str_buffer as ptr[char]` | Project raygui text widgets through `mt_str_buffer_prepare_write` |
| Span typedef collection | Traverse expressions/statement-expressions so `mt_span_ubyte` temps are declared |
| Foreign mapping classifier | `c.Call(...).field` (e.g. `MatrixToFloatV(mat).v`) treated as an inline mapping, not a bare name |
| `proc` type aliases | `type Gen = proc(...)` resolves to its closure struct, matching direct `proc(...)` syntax |
| Opaque nullables | `File?` / any opaque `T?` lowers to a nullable C pointer (`FILE*`) instead of an invalid value-optional over an incomplete type (see §2.4) |
| `cstr` return coercion | Bare string literals returned from `-> cstr` functions lower as C strings |
| Build driver | Add raygui/rlgl/gl binding build flags (`-I<vendored raygui>`, `-DRAYGUI_IMPLEMENTATION`, `-DGRAPHICS_API_OPENGL_43`, `-DMT_LANG_GL_REGISTRY_HAVE_RAYLIB`, and `-DMT_LANG_GL_REGISTRY_HELPERS_IMPLEMENTATION` for the header-only OpenGL registry — GL entry points resolve dynamically through raylib's loader, no `-lGL`) |

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

## 2. Remaining raylib Gaps (6 files) — deep root-cause analysis

Each remaining failure has been traced to its exact root cause by inspecting the
generated C from both compilers. **4 of the 6 fail identically under the Ruby
compiler** (they are not self-host gaps); the other 2 need the vendored-library
build subsystem.

### 2.1 Not buildable executables (2 files) — both compilers correctly refuse

| Example | Root cause |
|---------|-----------|
| `rlgl_loader` | An `external` file (raw ABI bindings), not a program. Ruby reports "cannot emit C for external file". The self-host emits a `main`-less C file that fails at link; it should detect external-file build targets and reject them cleanly (a CLI-polish item, not codegen). |
| `boxed_text` | A helper library with no `main` (only `draw_*` functions). Both compilers report "no executable entrypoint found". |

### 2.2 Shared compiler limitations (2 files) — both compilers fail

| Example | Exact root cause |
|---------|-----------------|
| `basic_pbr` | `Light(color = color_vector(color), ...)` uses an **array-returning function call as a struct-field initializer** inside an aggregate literal. Array-returning functions use the `void f(T (*__mt_out)[N], ...)` out-param convention, which cannot appear as a value in a C initializer. Ruby hoists the call into a temp but then still cannot initialise the array field from an array temp; the self-host does not hoist it at all. Fully supporting this needs aggregate-array-field materialisation (build the aggregate, then `memcpy` each array field from a hoisted temp) — absent in **both** compilers. |
| `cel_shading` | **Include ordering.** The example imports `std.c.rlgl` on line 1 (before `std.raylib` on line 3), so `rlgl.h` is `#include`d before `raylib.h`. rlgl.h guards `struct Matrix` on `RL_MATRIX_TYPE`, but raylib.h `#define`s `RL_MATRIX_TYPE` and then defines `struct Matrix` **unconditionally**; with rlgl.h first, raylib.h's unconditional definition is a redefinition. Correct order is raylib.h before rlgl.h. Both compilers emit includes in module order and hit this. Fixing it requires modelling the rlgl.h→raylib.h C-header dependency, which neither compiler does. |

### 2.3 Vendored-library builds (2 files) — compiler emits correct C

| Example | Root cause + status |
|---------|--------------------|
| `tracy_profiler` | `#include "TracyC.h"` needs the vendored Tracy include path and `-ltracyclient`, which must be compiled from `third_party/tracy-upstream`. No system package provides it. |
| `rlgl_standalone` | Needs the vendored GLFW build (`GLFW_UNLIMITED_MOUSE_BUTTONS` exists only in `third_party/glfw-upstream`; the binding links `-lglfw3` while the system provides `libglfw`). The **opaque-nullable codegen bug it exercised is now fixed** (see §2.4); the only remaining codegen item is a C typedef for the non-`std.c` opaque re-export `std.glfw.Window` (`typedef GLFWwindow std_glfw_Window;`), which has no build payoff while GLFW linking is unavailable. |

### 2.4 Landed: opaque-nullable codegen fix (general correctness)

An opaque type used as `T?` (e.g. `stdio.File?`/`FILE?`, `GLFWwindow?`) is
pointer-like and must lower to a nullable C pointer. The self-host previously
wrapped it in a value tagged-optional struct (`mt_opt_..._FILE` with a `FILE
value` field) — an invalid initializer for `fopen()`'s `FILE*` return. Now
`qualify_type` recognises opaque bases (via a program-wide opaque-key set built
from every module's `decl_opaque`, including raw `std.c.*` files) and wraps them
in `ptr[...]`, so `File? -> FILE*`, matching Ruby. Verified end-to-end
(`FILE* f = fopen(...)`, compiles and runs), fixed point holds, 177/177 tests
pass, 13/13 language examples build, zero raylib regressions.

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

---

## 5. Next-Session TODO

Prioritized remaining work. The compiler is at a held fixed point (177/177
tests, 13/13 language, 213/219 raylib); everything below is additive.

### 5.1 Self-host codegen bugs found during research (fix first — real correctness)

| # | Bug | Root cause / fix | Effort | Payoff |
|---|-----|-------------------|--------|--------|
| 1 | Module-level generic `var` not monomorphized | A module-level `var x: Map[str, str] = ...` emits the unspecialized `std_map_Map` C type instead of `std_map_Map_str_str` (found when trying a backend-global opaque set). Monomorphization must run on module-level `var`/`const` initializer + declared types. | Medium | General correctness; unblocks program-scoped generic state |
| 2 | Non-`std.c` opaque re-export has no C typedef | `std.glfw.Window` (`opaque Window = c"GLFWwindow"`) renders as the undeclared `std_glfw_Window`. Emit `typedef GLFWwindow std_glfw_Window;` for opaques whose module is not `std.c.*` (populate `program.opaques` — `collect_opaques` was prototyped then reverted — and emit typedefs after includes). Completes `rlgl_standalone` codegen. | Small | Correctness for opaque re-exports (glfw etc.) |

### 5.2 Raylib example gaps (self-host can surpass Ruby here)

| # | Example(s) | Fix | Effort |
|---|-----------|-----|--------|
| 3 | `cel_shading` | Order raw-module `#include`s so a header's C-level prerequisites precede it (raylib.h before rlgl.h/raygui.h). Needs a header-dependency model or a raylib-family ordering rule. Makes self-host build it (Ruby still fails). | Medium |
| 4 | `basic_pbr` | Aggregate-literal array-field materialisation: when a struct field is `array[T,N]` initialised from an array-returning call, hoist the aggregate into a temp, then `memcpy` each such field from the call's `__mt_out` temp. | Medium–Large |
| 5 | `rlgl_loader`, `boxed_text` | CLI polish: detect `external`-file / no-`main` build targets and reject cleanly (match Ruby's messages) instead of emitting a `main`-less binary that fails at link. Does not make them "build" (they are not executables) but improves parity/UX. | Small |

### 5.3 Vendored-library build subsystem (large; unblocks 2 examples + box2d etc.)

Needed for `rlgl_standalone` (GLFW) and `tracy_profiler` (Tracy), and any binding
with a `vendored_library`. Port the Ruby binding registry's `prepare:` /
`vendored_library` flow: build the C library from `third_party/<lib>` (or resolve
a system lib), add its include path + link flag. Large; separate from compiler
codegen.

### 5.4 Linter (§3) and CLI (§0.4) parity

- Linter: `owning-release-leak`, `redundant-cast`, `prefer-own-ptr` (need
  sema-facts), 5 CFG rules (low ROI), `--fix`, `.mt-lint.yml` config.
- CLI not-implemented: `run-module`, `new`, `debug`, `deps`, `toolchain`,
  `bindgen`, `cache`, `docs`, `snapshot`, `completions`.

### 5.5 Out-of-scope subsystems (§4)

Package-graph resolution (`--locked`/`--frozen`), build cache, `--bundle` /
`--archive`, wasm/emcc + preview server, `--jobs` parallel tests, `--sanitize`.

### 5.6 Verification checklist for any change

Run before considering a change done:

```sh
tools/bootstrap.sh                              # 3-stage + fixed point + tests
# then, from repo root, for a representative sweep:
build/stage2/mtc build examples/language_baseline.mt -I . -o /tmp/lb   # 13/13 language
# raylib parity sweep (per-file build, compare against the passing baseline)
```

A change is safe only if: stage2.c == stage3.c, 177/177 tests pass, 13/13
language examples build, and the raylib passing set does not shrink (currently
213).
