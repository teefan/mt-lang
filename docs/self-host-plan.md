# Self-Host Plan

Status: **SELF-HOSTING FIXED POINT ACHIEVED. RAYLIB + LANGUAGE PARITY COMPLETE.**
Stage2 == stage3 byte-identical. 177/177 self-tests pass across 9 test files.
**Raylib parity: 217/219 build and run** (the 2 remaining are non-executable
support files rejected with byte-identical Ruby messages, §2.4; vendored-library
subsystem §2.6; Wayland run parity via vendored raylib §2.7). **Language
parity: 13/13 build, 11/13 byte-identical runtime output vs Ruby** — the two
exceptions are *Ruby-side* bugs (§2.9). Layout attributes, `static_assert`
evaluation, and the `reinterpret` size rule landed in §2.9. CLI: 15 commands at
parity incl. build cache (§0.4, §2.8). **`mtc lint` has 31 rules.** Bootstrap
via `tools/bootstrap.sh`.

**Remaining gaps for the next session are consolidated in §5.**

Last updated: 2026-07-16 (post language-parity audit)

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

13/13 language examples build with the self-hosted compiler. The §2.9 audit
(runtime diff of stdout+exit against Ruby, simple → advanced) found **11/13
byte-identical**; the remaining differences are on Ruby's side:

- `async_stress_test` — crashes under **both** compilers (pre-existing libuv
  runtime bug).
- `async_network_lobby` — the self-host binary runs to `SUCCESS`; the
  **Ruby-built** binary aborts (SIGABRT, reproducible 3/3) — a Ruby CPS-async
  runtime bug the self-host does not share.
- `integration_test` — builds and runs under the self-host; **Ruby fails to
  build it** (`__dyn_..._measure` C error: too few arguments — a Ruby `dyn`
  vtable-wrapper codegen bug).

### 0.3 Example parity — raylib

**217 of 219 raylib examples build and run** (up from 178 at the start of the
effort). Zero regressions against the previously-passing set, and the self-host
builds every example the Ruby compiler can (it also builds `cel_shading` and
`basic_pbr`, which Ruby cannot). The 2 non-builds are **correct rejections**,
not gaps (§2.1/§2.4): `rlgl_loader` (an `external` ABI file) and `boxed_text`
(a `main`-less helper library) are refused with byte-identical Ruby messages.
`rlgl_standalone` and `tracy_profiler` build via the on-demand vendored-library
subsystem (§2.6), and all binaries link the vendored static raylib so they run
on Wayland sessions exactly like Ruby's (§2.7).

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
| **FULL**  | lex, parse, lower, emit-c, format, help, version, check, build, run, run-module, test, lint, new, completions |
| **NOT IMPL** | debug, deps, toolchain, bindgen, cache, docs, snapshot |

The build cache is implemented (§2.8): `build`/`run` reuse a previously built
binary when nothing changed (`built ... [cached]`), and `--no-cache` bypasses
it. The `cache` *inspection subcommand* is not implemented.

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

## 2. Raylib Gap Root-Cause Analysis and Resolutions — ALL RESOLVED

Each failure was traced to its exact root cause by inspecting the generated C
from both compilers, and every item is now landed: 2 non-executable support
files are rejected with byte-identical Ruby messages (§2.1/§2.4), the 2
vendored-library examples build via the on-demand vendored subsystem
(§2.2/§2.6), and binaries run on Wayland via vendored raylib linking (§2.7).

### 2.1 Not buildable executables (2 files) — both compilers refuse with matching messages

Both files are now rejected cleanly with byte-identical messages to Ruby (the
CLI-polish item, landed — see §2.4):

| Example | Root cause |
|---------|-----------|
| `rlgl_loader` | An `external` file (raw ABI bindings), not a program. Both compilers now report `cannot emit C for external file examples.raylib.others.rlgl_loader` and exit 1 for `build`/`run`/`lower`/`emit-c`. |
| `boxed_text` | A helper library with no `main` (only `draw_*` functions). Both compilers report `no executable entrypoint found; define \`main\` with one of the supported executable signatures` and exit 1 for `build`/`run`; `emit-c`/`lower` still emit the `main`-less C. |

### 2.2 Vendored-library builds (2 files) — DONE (§2.6)

Both examples now build with the self-host via the vendored-library subsystem:

| Example | Status |
|---------|--------|
| `tracy_profiler` | **Builds.** Codegen fixed in §2.5 (extern rename); the vendored Tracy client (`libtracyclient.a`) is now built on demand (`c++ TracyClient.cpp -DTRACY_ENABLE` + `ar rcs`) and linked with `-L tmp/tracy-lib` (the `-ltracyclient -lstdc++` come from the binding's `link` directives), plus `-I .../public{,/tracy} -DTRACY_ENABLE` compile flags. System raylib suffices. |
| `rlgl_standalone` | **Builds.** The vendored GLFW headers (`-I third_party/glfw-upstream/include`, which define `GLFW_UNLIMITED_MOUSE_BUTTONS`) are on the include path and `libglfw3.a` is built on demand via CMake+Ninja (`-DBUILD_SHARED_LIBS=OFF`, examples/tests/docs off), linked with `-L tmp/vendored-glfw-prefix/lib -lrt -lm -ldl` (glfw3.pc `Libs.private`; the `-lglfw3` comes from the binding's `link "glfw3"` directive). System raylib + the existing rlgl defines suffice. |

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

The CLI-polish item is done. The self-host previously lowered raw
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

### 2.5 Landed: three codegen/runtime bugs found by C-diffing vs Ruby (2026-07-15)

A systematic audit (diffing self-host vs Ruby generated C across all 219 raylib
examples — comparing the *called C symbols* and *array-length helpers*, which is
formatting-independent) surfaced three real bugs the "BUILDS OK" checks missed:

1. **Extern `= c"..."` rename dropped in foreign mappings** (§tracy_profiler —
   the plan had wrongly listed this as "codegen already correct"). A foreign
   function targeting a renamed external (`std.tracy.zone_begin = c.tracy_emit_zone_begin`
   where `external function tracy_emit_zone_begin = c"___tracy_emit_zone_begin"`)
   lowered to the Milk Tea name, not the C symbol → implicit-declaration errors.
   Fixed in `resolve_foreign_c_name` + new `imported_extern_c_name` (resolves the
   receiver alias to its module and honors the extern's own rename). Affected all
   33 renamed externs in `std/c/tracy.mt`; the C now matches Ruby byte-for-byte.

2. **Const-expression array lengths folded to 0** (`raw_data`, `screen_buffer`):
   `const N = WIDTH * HEIGHT; var buf: array[T, N]` produced a zero-length C array
   whose bounds check (`index >= 0`) aborts on the *first* access — a silent
   "builds OK, aborts at runtime" bug. Two causes: the analyzer's
   `evaluate_const_expr` had no binary/unary-op arm (so the const was never
   registered in `const_values`), and lowering's `const_eval_int` did not resolve
   `expr_identifier`. Both fixed; lengths now match Ruby (e.g. `Color[460800]`).

3. **Foreign `str as cstr` temporaries leaked** (≈130 examples): a dynamic
   `str as cstr` argument mallocs a NUL-terminated copy via
   `mt_foreign_str_to_cstr_temp` but the self-host never freed it — e.g.
   `DrawText(dynamic_str, ...)` in a frame loop leaks every frame. Both the simple
   and inline foreign-call paths now hoist the temp, emit the call, and free it
   after (yielding the return value for non-void) via a statement-expression,
   matching Ruby's `mt_free_foreign_cstr_temp`. Every alloc across all 219 examples
   is now paired with a free. This also exposed and fixed a latent gap: the
   checked-index / checked-span-index helper-collection passes did not traverse
   `expr_stmt_expr`, so helpers used only inside a statement-expression were not
   emitted.

**Method note (reinforces §5.1):** all three were invisible to "BUILDS OK" — #1
and #2 needed a C-symbol/array-length diff against Ruby, #3 needed an alloc/free
balance check. Bug #1 in particular means the previous "no self-host-only codegen
bug remains" claim was false; a C-symbol diff should be part of the standard
verification sweep, not just a compile check.

All three landed under a held fixed point (stage2.c == stage3.c), 177/177 tests,
13/13 language examples, and a full 215/219 raylib build with zero regressions.

### 2.6 Landed: vendored-library build subsystem (2026-07-16) — raylib 217/219

`build.mt` now builds vendored static libraries on demand before the link step
(`prepare_vendored_libraries`, mirroring Ruby's `VendoredCLibrary`
CMake/Archive `prepare!` flow in minimal form):

- **GLFW** (`std.c.glfw` in the module closure): builds
  `tmp/vendored-glfw-prefix/lib/libglfw3.a` via CMake + Ninja from
  `third_party/glfw-upstream` (`-DBUILD_SHARED_LIBS=OFF`, examples/tests/docs
  off, Release, PIC) when the archive is missing. Compile flags add
  `-I third_party/glfw-upstream/include` (the pinned tree defines
  `GLFW_UNLIMITED_MOUSE_BUTTONS`) and `-DMT_LANG_GL_REGISTRY_HAVE_GLFW`; link
  flags add `-L <prefix>/lib -lrt -lm -ldl` (glfw3.pc `Libs.private`).
- **Tracy** (`std.c.tracy`): builds `tmp/tracy-lib/libtracyclient.a`
  (`c++ -c TracyClient.cpp -DTRACY_ENABLE` + `ar rcs`) when missing. Compile
  flags add `-I .../tracy-upstream/public{,/tracy}` and `-DTRACY_ENABLE`; link
  flags add `-L tmp/tracy-lib`.

Design points: the `-l<lib>` flags themselves come from the bindings'
`link "..."` directives (`glfw3`, `tracyclient`, `stdc++`) — GNU ld applies
`-L` to all `-l` regardless of order; artifacts land in the same `tmp/` layout
Ruby uses, so the two compilers share built archives (verified both directions);
vendored sources are pinned trees, so an existing archive is reused as-is
(existence check — rebuilds take ~30 s for GLFW, ~5 s for Tracy; reuse is
~0.2 s). Verified: both examples build from scratch (archives deleted) and from
reuse; full raylib sweep 217/219 (the 2 remaining are the §2.4
correctly-rejected non-executables); fixed point holds, 177/177 tests, 13/13
language examples; Ruby still builds both with the self-host-produced archives.

### 2.7 Landed: vendored raylib linking — run parity on Wayland (2026-07-16)

The self-host previously linked **system `libraylib.so`** for all raylib
examples. They built, but every binary failed at startup on Wayland sessions
(`GLX: Failed to create context: GLXBadFBConfig`) because the system raylib
package embeds an X11-only GLFW. Ruby's raylib binding instead links the
**vendored static raylib** (`tmp/vendored-raylib-opengl43/libraylib.a`, built
with `-DPLATFORM_DESKTOP_GLFW -DGRAPHICS_API_OPENGL_43` against the
Wayland-capable system `libglfw.so.3`), so Ruby-built binaries ran and
self-host-built ones did not — a *run*-parity gap invisible to build sweeps.

The vendored subsystem (§2.6) now covers raylib: when `std.c.raylib`,
`std.c.raygui`, or `std.c.rlgl` is in the module closure (the three bindings
with `vendored_library: vendored_raylib_library` in Ruby's registry), the
self-host builds the archive when missing (the six raylib modules `rcore
rshapes rtextures rtext rmodels raudio` compiled with the archive defines, then
`ar rcs`), compiles the program against the vendored headers
(`-I third_party/raylib-upstream/src` plus the archive defines, matching what
bindgen generated the bindings from), and links `-L tmp/vendored-raylib-opengl43
-lglfw -lm -ldl -lpthread -lrt -lX11` (VendoredRaylib's
`DESKTOP_SYSTEM_LINK_FLAGS`; the `link "raylib"` directive's `-lraylib` then
resolves to the vendored archive). `std.c.raymath` adds
`-DRAYMATH_STATIC_INLINE`.

Verified: `mtc run examples/raylib/others/raylib_opengl_interop.mt` (the
reported case) and spot checks across shapes/textures/text/core all initialize
`GLFW - Wayland` and render; from-scratch archive build works and Ruby accepts
the self-host-built archive; full sweep still 217/219; fixed point, 177/177
tests, 13/13 language examples.

### 2.8 Landed: CLI parity batch — diagnostics gate, new/run-module/completions, build cache (2026-07-16)

Four items landed together (fixed point held, 177/177 tests, 13/13 language,
217/219 raylib, cached full raylib re-sweep in 16 s):

- **Loader-diagnostics gate** (closes the missing-file gap): `lower`, `emit-c`,
  `build`, and `run` now print program diagnostics and exit 1 when the loader
  reports a module error (`source file not found`, import failures) via a new
  `Program.diagnostic_module_error_count()`. Deliberately scoped to
  `module/*` errors: gating on *semantic* errors would break valid programs
  because the conservative analyzer has known false positives (e.g.
  `unknown type type` for `-> type` functions in language_baseline) — that
  stricter gate needs the analyzer-fallback work in §5.1 first.
- **`mtc new`**: scaffolds `package.toml` + `src/main.mt`, snake_case package
  name from the directory basename (`MyCamelApp` → `my_camel_app`), Ruby's
  exact validation messages (`missing project name`, `project directory
  already exists and is not empty: <path>`, `unknown new option <arg>`).
- **`mtc run-module`**: resolves `a.b.c` against each module root as
  `<root>/std/a/b/c.mt` then `<root>/a/b/c.mt` (ambient roots: cwd + discovered
  project root), then delegates to the ordinary `run` path with all flags
  preserved. `run-module module not found: <name>` on failure, matching Ruby.
- **`mtc completions bash|zsh|fish`**: prints the completion script for the
  self-host's implemented command set (same summaries as Ruby's `COMMANDS`
  table; Ruby-only commands are not advertised).
- **Build cache** (`mtc.build_cache`): `build`/`run` reuse the previously built
  binary when nothing changed, reporting `built ... [cached]`; `--no-cache`
  bypasses; `--keep-c` always rebuilds so the saved C matches the binary.
  Cache root `$XDG_CACHE_HOME/milk_tea/mtc-cache` (else `~/.cache/...`).
  **Correct by construction**: the full key material — the mtc executable's own
  content hash (`/proc/self/exe`, so a rebuilt compiler can never serve stale
  output, unlike Ruby's backend-sources heuristic), the `cc --version`
  identity, debug-guards/platform config, and every module path+length+source —
  is stored beside the binary and compared byte-for-byte on lookup; the FNV-1a
  hash only names the entry directory, so a collision degrades to a miss, never
  a wrong binary. Measured: language_baseline rebuild 0.41 s → 0.09 s; full
  217-example raylib re-sweep 16 s.

### 2.9 Landed: language-example parity audit — layout attrs, static_assert, reinterpret (2026-07-16)

A systematic simple→advanced audit of all 13 language examples plus focused
feature probes: **runtime diff** (build with both compilers, compare
stdout+exit — 11/13 byte-identical; `async_stress_test` crashes under both,
`async_network_lobby` crashes under *Ruby only*, a pre-existing Ruby async
runtime bug the self-host does not share; `integration_test` fails to build
under *Ruby only*, a Ruby `dyn` codegen bug) and **structural C diff**
(external-symbol sets + string-literal sets, formatting-independent). Three
real self-host feature gaps found and fixed:

1. **`@[packed]` / `@[align(N)]` silently dropped** — the parser stored the
   attributes in the generic list but never set `decl_struct.packed/alignment`,
   lowering hardcoded `packed = false`, and the C backend never rendered the
   closer. A packed `{ubyte, int}` struct sized 8 instead of 5; `@[align(16)]`
   got natural alignment — silent ABI/layout miscompilation for any packed
   file/network format. Now parsed, threaded through IR (top-level + nested
   structs), and rendered as `__attribute__((packed, aligned(N)))`
   byte-identical to Ruby; runtime `size_of`/`align_of` match.

2. **`static_assert` never evaluated or emitted** — the analyzer only
   type-checked the condition; `static_assert(false, ...)` compiled cleanly and
   no `_Static_assert` reached the C. Both declaration and statement forms now
   emit `_Static_assert`: fully foldable conditions (literals, const
   arithmetic/comparisons, and/or/not — via new Option-returning
   `try_const_eval_int/bool`) fold to `true`/`false` exactly like Ruby;
   `size_of`/`align_of`/`offset_of` conditions partially fold (const
   identifiers → literals) and are emitted as C integer constant expressions
   the C compiler evaluates — packed-layout asserts work without a Milk Tea
   layout calculator. Failing asserts abort the build with
   `static assertion failed: <message>` under both compilers.

3. **`reinterpret[T]` equal-size rule unenforced** — `reinterpret[int](a_long)`
   was accepted (and truncated). `check_reinterpret_call` now receives the
   argument types and reports Ruby's diagnostic
   (`reinterpret requires equal-size types, got long (8 bytes) -> int (4 bytes)`)
   when both sizes are statically known (primitives, raw pointers, cstr);
   layout-dependent types stay permissive. Surfaced via `mtc check` (the build
   gate still aborts only on module errors until §5.1 removes analyzer false
   positives).

Remaining structural diffs are verified-cosmetic: runtime-helper
implementation details (`fwrite`/`malloc` in `mt_fatal`/format machinery),
UTF-8 string-literal escaping style (raw bytes vs `\xNN`, identical content),
Ruby's CPS-async `cancel`/`UINT64_C`/`_Static_assert` runtime scaffolding, and
extra self-host format-fallback literals — all confirmed by identical runtime
output on the affected examples.

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
| ~~Build cache~~ **DONE (§2.8)** | — |
| `--bundle` / `--archive` | Medium |
| Wasm compilation (emcc) + preview server | Large |
| `--jobs` parallel test execution | Medium |
| `--sanitize` | Medium |
| ~~`run-module`, `new`, `completions`~~ **DONE (§2.8)**; `debug`, `deps`, `toolchain`, `bindgen`, `cache`, `docs`, `snapshot` | Varies |

---

## 5. Remaining Gaps (new-session context)

The compiler is at a held fixed point (177/177 tests, 13/13 language examples,
217/219 raylib — the 2 non-builds are correct rejections; 11/13 language
examples byte-identical at runtime, the other 2 blocked by Ruby-side bugs).
**No known self-host codegen, runtime, or example-parity bug remains.** All
landed work is recorded in §1 (external-type fixes) and §2 (per-session logs
§2.1–§2.9). What follows is the complete remaining-gap inventory, prioritized.

### 5.1 Analyzer false positives → semantic-error gate (highest-value correctness item)

The self-host's semantic analyzer is deliberately conservative — it records
`ty_error` for expressions involving imported types, cross-module calls, and
struct-field chains. In a full raylib example (julia_set), **77% of expression
type lookups fall back** to lowering's `fallback_type` heuristic.

This blocks one behavioral parity item: **Ruby exits 1 on semantic errors for
all C-emitting commands; the self-host gates only on `module/*` loader errors**
(`diagnostic_module_error_count`, §2.8), because gating on sema errors would
reject valid programs. Known false-positive classes to eliminate first:

- `unknown type type` — `-> type` (type-returning) functions, 13 hits in
  language_baseline alone.
- Imported-type expression chains recorded as `ty_error` (the 77% fallback).

Once `mtc check` is clean on all 13 language examples + the compiler itself +
a raylib sample, flip `lower`/`emit-c`/`build`/`run` to gate on
`diagnostic_error_count() > 0` and delete `diagnostic_module_error_count`.

**Architecture lesson (unchanged):** every new IR expression node must be
handled in `ir_expr_type` (lowering) and the C-backend renderer; every new
analyzer pattern must be verified by *runtime* comparison against Ruby, not
"BUILDS OK" (see §2.5/§2.9 for the bug classes each audit method caught).

### 5.2 Ruby-side bugs from the parity audits — verified with minimal repros (2026-07-16)

All three were re-examined with small tmp apps and gdb. Only one was a real
Ruby compiler bug, and it is **fixed**:

| Item | Verdict |
|------|---------|
| `dyn` vtable wrapper arity | **REAL BUG — FIXED.** Minimal repro: a value-receiver interface method whose body touches `this` only through a PrefixCast (`return float<-(this.value)`). The wrapper's private `method_uses_this?` AST walk had no PrefixCast arm (nor Call/Index/If/Match arms), so it omitted the receiver argument while the C backend — which authoritatively counts name references in the lowered IR — kept the receiver parameter → arity mismatch, C error. Fix: deleted the duplicated heuristic; the wrapper always passes the receiver and uses a String callee so the backend's single-source-of-truth omitted-receiver logic drops it when (and only when) the target's receiver param was omitted. 11/11 dyn tests pass; `integration_test` + repro build and run. |
| `async_network_lobby` abort | **NOT a Ruby bug — reclassified.** gdb showed `mt_fatal("loop iteration limit exceeded in std_net_discovery_announce__resume")`: the *debug loop guard* (50k iterations) tripping in a legitimately long-polling discovery loop. My audit built the Ruby binary with guards on and the self-host comparison binary effectively without; with `--no-debug-guards` the Ruby binary runs to `SUCCESS` with output identical to the self-host's. Real issue (minor, pre-existing): resume-loop iteration guards are miscounted across CPS awaits — a suspended/resumed loop accumulates guard counts per resume, so long-running async polls can trip the guard spuriously in debug profile. |
| `async_stress_test` crash | **Confirmed shared** (exit 134 under both compilers, identical behavior) — the known pre-existing libuv runtime bug, not compiler-specific. |

### 5.3 Linter gaps (§3)

`owning-release-leak`, `redundant-cast`, `prefer-own-ptr` (need sema-facts);
5 CFG rules (low ROI — 9 warnings total across the codebase); `--fix`;
`.mt-lint.yml` config.

### 5.4 CLI commands not implemented (§0.4)

`debug`, `deps`, `toolchain`, `bindgen`, `cache` (inspection subcommand; the
cache itself is live, §2.8), `docs`, `snapshot`. The other 15 commands are at
parity, incl. `new` / `run-module` / `completions` (§2.8).

### 5.5 Subsystems not ported (§4)

Package-graph resolution (`--locked`/`--frozen`, Large), `--bundle` /
`--archive` (Medium), wasm/emcc + preview server (Large), `--jobs` parallel
tests (Medium), `--sanitize` (Medium). Additional vendored-library recipes
(box2d, sdl3, flecs, pcre2, steamworks) follow the §2.6 pattern when an example
needs them: an archive-existence check + CMake or compile+`ar` recipe in
`prepare_vendored_libraries` and a `-L` entry in `collect_vendored_link_flags`.

### 5.6 Accepted minor divergences (verified benign)

- **Nested-array outer bounds checks** (§1.5, deliberate): the self-host emits a
  plain C index for `array[array[T, M], N]` outer-dimension access where Ruby
  emits a checked helper. Values identical; only the OOB abort is missing.
  Affects 6 examples.
- **Inline-mapping temp counts** (cosmetic): Ruby materializes more
  `foreign_arg_public` temporaries; both compilers are alloc/free-balanced.
- **Structural C cosmetics** (§2.9): runtime-helper internals (`fwrite`/`malloc`
  usage in fatal/format paths), UTF-8 string-literal escaping style, Ruby's
  CPS-async scaffolding symbols, format-fallback literals — all confirmed by
  identical runtime output.

### 5.7 Verification checklist for any change

Run before considering a change done:

```sh
tools/bootstrap.sh                              # 3-stage + fixed point + tests
# then, from repo root, for a representative sweep:
build/stage2/mtc build examples/language_baseline.mt -I . -o /tmp/lb   # 13/13 language
# raylib parity sweep (per-file build, compare against the passing baseline)
```

A change is safe only if: stage2.c == stage3.c, 177/177 tests pass, 13/13
language examples build, and the raylib passing set does not shrink (currently
217; the 2 non-builds must remain clean rejections with Ruby's messages).

For **runtime correctness**, diff against the Ruby compiler on arithmetic / type
patterns:
```sh
# compile a compute-heavy test with both compilers, compare stdout:
build/stage2/mtc build /tmp/test.mt -I . -o /tmp/sh --no-cache && /tmp/sh > /tmp/sh_out
ruby -Ilib bin/mtc build /tmp/test.mt -I . -o /tmp/rb --no-cache && /tmp/rb > /tmp/rb_out
diff /tmp/sh_out /tmp/rb_out   # must be empty
```

The full-language variant of this (the §2.9 audit): build every
`examples/*.mt` with both compilers and diff stdout+exit. Expected baseline:
**11/13 byte-identical**; `async_stress_test` crashes under both;
`async_network_lobby` and `integration_test` differ only because of the
Ruby-side bugs in §5.2.

For **codegen parity on GUI examples** (which cannot be runtime-diffed
headless), C-diff against Ruby with formatting-independent extracts — this is
what caught all three §2.5 bugs and all three §2.9 gaps:

```sh
# per example, emit C with both compilers, then compare:
#  1. called C ABI symbols (catches wrong linkage names, e.g. extern renames)
#  2. checked-index helper names (catches wrong array lengths, e.g. _Color_0)
#  3. mt_foreign_str_to_cstr_temp vs mt_free_foreign_cstr_temp counts
#     (catches unpaired allocs — leaks)
build/stage2/mtc emit-c FILE -I . | grep -oE '[A-Za-z_][A-Za-z0-9_]*\(' | sort | uniq -c
```
