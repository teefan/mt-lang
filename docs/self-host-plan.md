# Self-Host Plan

Status: **SELF-HOSTING FIXED POINT ACHIEVED.** Stage2 == stage3 byte-identical.
177/177 self-tests pass across 9 test files. **Raylib parity: 215/219 build**
(98%; the 4 remaining are 2 non-buildable support files — now rejected with
byte-identical Ruby messages, see §2.4 — and 2 vendored-library (GLFW/Tracy)
build gaps. No self-host-only codegen bug remains, and every example the Ruby
compiler can build the self-host now also builds). 13/13 language examples build.
**`mtc lint` has 31 rules** (4 new Tier-1/3 AST rules, 2 new tooling features).
`--select`/`--ignore` supported. Lint wired into `mtc check`. Bootstrap via
`tools/bootstrap.sh`.

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

**215 of 219 raylib examples build** (98%, up from 178). Zero regressions
against the previously-passing set, and the self-host now builds every example
the Ruby compiler can (it also builds `cel_shading` and `basic_pbr`, which Ruby
cannot). The 4 remaining are **not self-host codegen gaps** — see §2:

- **2 non-buildable support files** (`rlgl_loader`, `boxed_text`): an `external`
  raw-binding file and a `main`-less helper library. Both compilers correctly
  refuse them (they are not executables).
- **2 vendored-library builds** (`rlgl_standalone`, `tracy_profiler`): the
  compiler now emits correct C (rlgl_standalone compiles cleanly after the
  opaque fixes) but the build driver would need to compile a vendored library
  from source (GLFW → `libglfw3`, the Tracy client).

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
| Opaque nullables | `File?` / any opaque `T?` lowers to a nullable C pointer (`FILE*`) instead of an invalid value-optional over an incomplete type (see §2.3) |
| `cstr` return coercion | Bare string literals returned from `-> cstr` functions lower as C strings |
| Module-level generic `var` | `var m: Map[str, str]` qualifies its declared type → `std_map_Map_str_str` (globals previously skipped `qualify_type`, emitting the never-defined `std_map_Map`) |
| Opaque re-export typedefs | Non-`std.c` opaques (`std.glfw.Window = c"GLFWwindow"`) emit `typedef GLFWwindow std_glfw_Window;` so their qualified name resolves; completes `rlgl_standalone` codegen |
| External include order | Binding headers emitted in deterministic sorted order so `raylib.h` precedes `rlgl.h` regardless of import order; fixes `cel_shading` |
| Aggregate array-call fields | `S(arr = f(...))` where `f` returns an array omits the field from the C initializer and fills it via `f(&s.arr, ...)` after the struct is built; fixes `basic_pbr` (Ruby cannot build it) |
| Build driver | Add raygui/rlgl/gl binding build flags (`-I<vendored raygui>`, `-DRAYGUI_IMPLEMENTATION`, `-DGRAPHICS_API_OPENGL_43`, `-DMT_LANG_GL_REGISTRY_HAVE_RAYLIB`, and `-DMT_LANG_GL_REGISTRY_HELPERS_IMPLEMENTATION` for the header-only OpenGL registry — GL entry points resolve dynamically through raylib's loader, no `-lGL`) |
| **Runtime correctness audit** | 6 miscompilations found by diffing runtime output against Ruby (all had no C compile error — "builds OK but runs wrong"): |
| Float-literal rendering | Whole-number floats (`1.0`) formatted without `.0` → C parsed as `int` → `1.0 / 3.0 == 0` |
| Integer literal overflow | Parser stored `long`-width literals in 32-bit `int` AST field → `9000000000l` truncated |
| `ir_expr_type` gaps | Missing `expr_float_literal` + 7 other variants in `ir_expr_type` → float in tuples typed `void`, `size_of`/`offset_of`/`reinterpret` in expressions typed `error` |
| Native vector typedefs | `emit_builtin_type_defs` gated on `use_string_view` and didn't collect from function bodies → `mt_vec3` undefined |
| Flags/enum binary ops | `infer_binary` didn't handle flags `\| & ^` or enum arithmetic → `void p = Perm.read \| Perm.write` |
| `reinterpret[T](x)` numeric cast | Lowering turned `reinterpret` into a plain `expr_cast` → `reinterpret[uint](3.14f)` yielded `3`, not the IEEE bit pattern; silently broke float hashing |

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

## 2. Remaining raylib Gaps (4 files) — deep root-cause analysis

Each remaining failure has been traced to its exact root cause by inspecting the
generated C from both compilers. None is a self-host codegen gap: 2 are
non-buildable support files (both compilers correctly refuse them) and 2 need the
vendored-library build subsystem.

### 2.1 Not buildable executables (2 files) — both compilers refuse with matching messages

Both files are now rejected cleanly with byte-identical messages to Ruby (the
CLI-polish item from §5.2 is landed — see §2.4):

| Example | Root cause |
|---------|-----------|
| `rlgl_loader` | An `external` file (raw ABI bindings), not a program. Both compilers now report `cannot emit C for external file examples.raylib.others.rlgl_loader` and exit 1 for `build`/`run`/`lower`/`emit-c`. |
| `boxed_text` | A helper library with no `main` (only `draw_*` functions). Both compilers report `no executable entrypoint found; define \`main\` with one of the supported executable signatures` and exit 1 for `build`/`run`; `emit-c`/`lower` still emit the `main`-less C. |

### 2.2 Vendored-library builds (2 files) — compiler emits correct C

| Example | Root cause + status |
|---------|--------------------|
| `tracy_profiler` | `#include "TracyC.h"` needs the vendored Tracy include path and `-ltracyclient`, which must be compiled from `third_party/tracy-upstream`. No system package provides it. |
| `rlgl_standalone` | **Codegen now compiles cleanly** (the opaque-nullable and opaque-typedef fixes — §2.3 — resolved every codegen error; verified with the vendored GLFW header, 0 C errors). The only remaining blocker is GLFW linking: the binding links `-lglfw3` while the system provides `libglfw`, and `GLFW_UNLIMITED_MOUSE_BUTTONS` exists only in `third_party/glfw-upstream`. Needs the vendored GLFW build (→ `libglfw3`), i.e. the §5.3 subsystem. |

### 2.3 Landed: opaque codegen fixes (general correctness)

Two opaque fixes landed this pass:

- **Opaque nullable → pointer** (`stdio.File?`/`FILE?`, `GLFWwindow?`): an opaque
  type is pointer-like, so `T?` must lower to a nullable C pointer. The self-host
  previously wrapped it in a value tagged-optional struct (`mt_opt_..._FILE` with
  a `FILE value` field) — an invalid initializer for `fopen()`'s `FILE*` return.
  Now `qualify_type` recognises opaque bases (via a program-wide opaque-key set
  built from every module's `decl_opaque`, including raw `std.c.*` files) and
  wraps them in `ptr[...]`, so `File? -> FILE*`, matching Ruby.
- **Opaque re-export typedef** (`std.glfw.Window`): a non-`std.c` opaque
  re-export renders as its module-qualified name (`std_glfw_Window`); now
  `typedef GLFWwindow std_glfw_Window;` is emitted so it resolves. Only opaques
  with an explicit `= c"..."` backing get a typedef (a bare `opaque X` is a
  forward-declared struct).

Verified end-to-end (`FILE* f = fopen(...)` compiles and runs; rlgl_standalone
codegen compiles with 0 C errors), fixed point holds, 177/177 tests, 13/13
language examples, zero raylib regressions.

### 2.4 Landed: non-buildable-target rejection (CLI parity, 2026-07-15)

The §5.2 CLI-polish item is done. The self-host previously lowered raw
`external` files and `main`-less programs into C that failed at link with an
opaque `undefined reference to 'main'` linker error. It now rejects both cleanly
with the exact Ruby messages, before invoking the C compiler:

- **External-file rejection** — `build`/`run`/`lower`/`emit-c` on a raw
  `external` file print `cannot emit C for external file <module.name>` and exit
  1, mirroring Ruby's `LoweringError` (raised in `lower_modules` for
  `:raw_module`). Implemented as `Program.root_is_raw_module()` +
  `reject_external_root` at the CLI layer.
- **Missing-entrypoint rejection** — `build`/`run` on a program with no valid
  executable `main` print `no executable entrypoint found; ...`, or
  `root main is not a valid executable entrypoint; ...` when a `main` exists with
  an unsupported signature — matching Ruby's `Build.ensure_program_has_entrypoint!`.
  Implemented as `ir.has_entrypoint(ir_program)` (the lowered-IR
  `entry_point` check) + `Program.root_has_main()` + `reject_missing_entrypoint`.
  `emit-c`/`lower` still emit the `main`-less C, exactly as Ruby does.

Refactor: `build_driver.build` now takes the caller-lowered `ir.Program`, so the
CLI lowers once and shares that IR between the entrypoint check, `--keep-c`, and
the build (previously lowering happened inside `build` and again in
`keep_c_to_file`). Fixed point holds, 177/177 tests, 13/13 language examples,
41-example raylib spot-check with zero regressions.

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
tests, 13/13 language, 215/219 raylib); everything below is additive.

**Done this pass (§0.3 table):** module-level generic `var` monomorphization,
opaque-nullable → pointer, opaque re-export typedefs, deterministic external
include ordering (fixed `cel_shading`), aggregate array-call-field
materialisation (fixed `basic_pbr`), and 6 runtime miscompilations found by
diffing runtime output against Ruby (float-literal C rendering, integer literal
overflow, `ir_expr_type` gaps, native vector typedef emission, flags/enum binary
op inference, and `reinterpret[T]` bit reinterpret). Every example the Ruby
compiler can build, the self-host now also builds.

**Done next pass (§2.4):** non-buildable-target rejection — `external` files and
`main`-less programs are now rejected with byte-identical Ruby messages and exit
codes across `build`/`run`/`lower`/`emit-c` instead of emitting a `main`-less
binary that fails at link (§5.2 item 2 closed). The items below remain.

### 5.1 Architectural finding: analyzer fallback reliance

The self-host's semantic analyzer is deliberately conservative — it records
`ty_error` for expressions involving imported types, cross-module calls, and
struct-field chains. In a full raylib example (julia_set), **77% of expression
type lookups fall back** to lowering's `fallback_type` heuristic, and **133
expressions get a bad (void/error) type even after fallback**.  The `ir_expr_type`
function had 8 missing expression-variant arms, each silently returning
`ty_error`.

This two-phase architecture (conservative validator-analyser + best-effort
lowering heuristic) means **every new IR expression node and every new
analyser-supported pattern creates a latent gap in the fallback**: if the
analyser records `ty_error` and `fallback_type`/`ir_expr_type` both miss the
expression kind, the C type becomes `void` — a silent miscompilation, not a
crash.

**Lesson for future work:** any new expression kind added to the IR must be
handled in `ir_expr_type` (lowering) and the C-backend renderer, and any new
pattern added to the analyser should be verified by a *runtime* comparison
against Ruby, not just `"BUILDS OK"`.  A `"BUILDS OK"` test only proves the C
compiled — it says nothing about runtime values.  The 6 bugs fixed this pass all
produced valid C programs with wrong numeric output.

### 5.2 Remaining raylib gaps

Only one gap remains, and it needs out-of-codegen work:

| # | Example(s) | Fix | Effort |
|---|-----------|-----|--------|
| 1 | `rlgl_standalone`, `tracy_profiler` | Vendored-library build subsystem (§5.3). Codegen is already correct. | Large |
| 2 | `rlgl_loader`, `boxed_text` | **DONE (§2.4).** CLI polish: detect `external`-file / no-`main` build targets and reject cleanly with byte-identical Ruby messages instead of emitting a `main`-less binary that fails at link. They still do not "build" (they are not executables) but the messages and exit codes now match Ruby. | Small |

### 5.3 Vendored-library build subsystem (large; unblocks rlgl_standalone + tracy + box2d etc.)

Needed for `rlgl_standalone` (GLFW; codegen already compiles cleanly) and
`tracy_profiler` (Tracy), and any binding with a `vendored_library`. Port the
Ruby binding registry's `prepare:` / `vendored_library` flow: build the C library
from `third_party/<lib>` (or resolve a system lib), add its include path + link
flag. Note the `-lglfw3` (vendored) vs system `-lglfw` naming and the
vendored-only `GLFW_UNLIMITED_MOUSE_BUTTONS` header constant. Large; separate from
compiler codegen.

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
215).

For **runtime correctness**, diff against the Ruby compiler on arithmetic / type
patterns:
```sh
# compile a compute-heavy test with both compilers, compare stdout:
build/stage2/mtc build /tmp/test.mt -I . -o /tmp/sh --no-cache && /tmp/sh > /tmp/sh_out
ruby -Ilib bin/mtc build /tmp/test.mt -I . -o /tmp/rb --no-cache && /tmp/rb > /tmp/rb_out
diff /tmp/sh_out /tmp/rb_out   # must be empty
```
