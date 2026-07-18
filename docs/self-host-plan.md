# Self-Host Plan

Status: **SELF-HOSTING FIXED POINT ACHIEVED. RAYLIB + LANGUAGE PARITY COMPLETE. LSP ALL 3 TIERS + 4 QUALITY PHASES COMPLETE. LINT --FIX COMPLETE.**
Stage2 == stage3 byte-identical. 494 self-tests pass across 10 test files.
**Raylib parity: 217/219 build and run** (the 2 remaining are non-executable
support files rejected with byte-identical Ruby messages, §2.4; vendored-library
subsystem §2.6; Wayland run parity via vendored raylib §2.7). **Language parity:
13/13 build under `--no-cache`** (the §5.3a sema-gate regression is fixed —
2026-07-17); all 11 examples runnable headless produce byte-identical
stdout+exit vs Ruby, including two with shared pre-existing runtime bugs
(§5.3b). Layout attributes, `static_assert`
evaluation, and the `reinterpret` size rule landed in §2.9. CLI: 17 commands at
parity (added `cache`, `lsp`). **`mtc lint` has 36 rules plus `--fix`
(7 auto-fixable rules, byte-identical output vs Ruby) and `.mt-lint.yml`
config** (§3.4). `mtc check` on `language_baseline.mt`: 0 errors. Bootstrap
via `tools/bootstrap.sh`.

**LSP: 23 modules, ~4,950 lines, 25 capabilities advertised, valgrind-clean.**
All 3 tiers plus 4 quality phases (§0b): buffer-synced documents, token-accurate
cursor/occurrence resolution, symbol-precise diagnostic ranges, rich hover with
signatures + `##` docs, symbol and `alias.` member completion, fact-based
semantic tokens, cross-file definition/hover into imported modules, folding,
selection ranges, workspace symbols, inlay parameter hints, onType formatting,
and fix-engine-backed quickfix code actions.  Verified against a real editor
(headless Neovim 0.12) and piped JSON-RPC fixtures.  See `docs/lsp-design.md`.

**Ruby compiler nullability crash fixed** (2026-07-18, commit `bf0e6719`):
parser creates `MatchStmt` with `MatchExprArm` objects when inline match arms
use single-expression bodies.  Fixed 4 `arm.body` call sites in `nullability.rb`
to handle both arm types.  Unblocks complex LSP modules.

**Remaining gaps for the next session are consolidated in §5 (see §5.8 for
the prioritized next-session candidates).**

Last updated: 2026-07-18 (LSP quality phases 0-4 complete; lint --fix +
.mt-lint.yml landed; fix engine feeds LSP code actions; suite at 494)

---

## 0a. 2026-07-18 session — three bugs fixed (2 self-host, 1 Ruby)

All landed under a held fixed point (stage2.c == stage3.c), 476/476 self-host
tests, Ruby suites green (1237 compiler + 96 std + 957 tooling), 13/13 language
examples `--no-cache`, 41-example raylib spot check clean, 8/8 headless
examples byte-identical runtime vs Ruby, LSP valgrind-clean.

1. **Self-host lowering: order-dependent bare-name struct field lookup**
   (the `docs/lsp-design.md` §7.7 "const_ptr_as_str" bug). `concrete_field_type`
   resolved a receiver's field by scanning **all** program analyses in
   dependency order for the first struct with a matching bare name, ignoring
   the receiver's owning module. In the mtc program, `std.map.Entry`
   (`key: const_ptr[K]`) precedes `std.json.Entry` (`key: string.String`), so
   `entry.key.as_str()` in `lsp/protocol.mt` typed the receiver `const_ptr`
   and emitted the nonexistent `mtc_lsp_protocol_const_ptr_as_str` — while
   standalone repros (different module order) worked. Fix in `lowering.mt`:
   when the base type is `ty_imported`, look the struct up in
   `find_imported_analysis(owner_module)` first; fall back to the ordered scan.
   This unblocked recursive JSON object serialization in the LSP
   (`append_json_value` now renders objects; the `{}` workaround is removed).
   **Fallout discovered**: `publishDiagnostics` params previously rendered as
   `{}` over the wire — real diagnostics now reach the editor — and
   `diagnostic_from_warning` never wrote `line`/`character` into its range
   positions (invisible while objects rendered as `{}`); both fixed.

2. **Self-host analyzer: `extending` methods on re-exported type aliases**
   (`unknown method Image.draw_pixel` false positive, sema-gated
   `spectrum_visualizer`). A receiver typed through `type Image = c.Image`
   resolves to `ty_imported(std.c.raylib, Image)`, but the `extending Image:`
   methods live in **std.raylib**'s binding under the alias name. New
   reverse-alias search (`alias_binding_has_member` in `analyzer.mt`): when the
   owner binding lacks the member and the forward alias-follow fails, scan
   visible bindings for a type alias resolving to the same imported type and
   check its member keys.

3. **Ruby backend: inconsistent C keyword field-name sanitization**
   (`spectrum_visualizer` failed under Ruby too — `FFTComplex` declared field
   `imaginary` but member access emitted `imaginary_`). `sanitize_c_identifier`
   was applied at member-access/arm-name sites but not at struct/union/variant
   field **declarations**, designated **initializers**, or `offsetof`. Any
   field named in `C_KEYWORDS` (e.g. `imaginary`, `complex`) miscompiled. All
   emission sites now sanitize consistently (`type_declaration.rb`,
   `expressions.rb`).

---

## 0b. 2026-07-18 sessions — LSP quality phases 0-4 + linter --fix

Commits `4a90cca6` (Phases 0+1), `b387853d` (Phase 2), `daff01b2` (Phase 3),
`f52f1343` (Phase 4), `850b9fc5` (--fix + config), `6466627d` (fix-set
expansion + LSP code actions). All under a held fixed point; suite grew
476 → 488 → 494 (new fix_engine_test.mt).

**LSP Phase 0 (correctness):** every position-based handler now reads the
open editor buffer (`Workspace.document_source`, buffer first / disk
fallback) instead of stale disk content; new shared `lsp/cursor.mt`
(token-at-position, call-name-at-position, identifier occurrences) replaced
three duplicated byte scanners; diagnostic ranges point at the offending
symbol (Ruby `extract_warning_range` parity; sema errors use
`LoadDiagnostic.column`); fixed an off-by-one that shifted every
reference/rename match beyond line 1.

**Phase 1 (quality of advertised features):** completion returns real module
symbols plus `alias.` member completion via module-path resolution; hover
renders markdown signatures (functions incl. async/variadic, const/var
types, struct fields from the AST TypeRef so generics show `own[T]?`, enum
members) with attached `##` docs; references/rename use identifier-token
occurrences (strings/comments never match); semantic tokens classify through
Analysis facts (function/type/namespace/parameter + builtin type names).

**Phase 2 (new capabilities, 13 → 19):** documentHighlight, prepareRename,
foldingRange (indent stack + import/comment runs, Ruby algorithm),
workspace/symbol (text prefilter, 200-result cap, non-empty query only —
0.26 s cold on this repo), selectionRange (word/line/statement/block),
semanticTokens/range.

**Phase 3 (19 → 25):** declaration/typeDefinition/implementation (the
definition family; typeDefinition reads `alias.Type` annotations straight
from the AST TypeRef), inlayHint (parameter-name hints, named-arg and
self-describing-arg suppression), onTypeFormatting (newline indent assist),
quickfix code actions. Lifecycle verified: shutdown → exit, EOF, and garbage
input all terminate cleanly.

**Phase 4 (cross-file + editor verification):** definition/hover resolve
`alias.member` into the imported module's file (signature + docs + exact
name range); an import alias resolves to its module file. Real-editor smoke
test via headless Neovim 0.12 passed (attach, cross-file hover/definition,
diagnostics, completion, clean shutdown, no orphan process). The smoke test
exposed a latent diagnostics bug: the root module was fetched via
`modules.last()`, but `modules` fills in DFS pre-order, so lint ranges and
token-based rules ran against the wrong source for any root with imports —
now indexed via `order.last()`.

**Linter --fix + .mt-lint.yml:** see §3.4. Fix engine is edit-based and
shared with LSP code actions ("Fix <code>" quickfixes computed against the
live buffer). 7 fixable rules, byte-identical output vs Ruby fixtures;
`unused-import` deliberately not fixable (Ruby rationale).

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
(runtime diff of stdout+exit against Ruby, simple → advanced) plus the §5.2
verification pass leaves **12/13 byte-identical under both compilers**:

- `async_stress_test` — crashes under **both** compilers (pre-existing libuv
  runtime bug, verified identical: exit 134 under each).
- `async_network_lobby` — identical output once build configs match: the
  earlier "Ruby crash" was the debug loop guard tripping in a long-polling
  CPS resume loop (`--no-debug-guards` on the Ruby side disables it, and
  the self-host has no guard injection); see §5.2.
- `integration_test` — Ruby's `dyn` vtable wrapper arity bug is **fixed**
  (§5.2); both compilers now build and run it identically.

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
fixed point, 476/476 tests, 13/13 language examples):

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
| **FULL**  | lex, parse, lower, emit-c, format, help, version, check, build, run, run-module, test, lint, new, completions, cache, lsp |
| **NOT IMPL** | debug, deps, toolchain, bindgen, docs, snapshot |

The build cache is implemented (§2.8): `build`/`run` reuse a previously built
binary when nothing changed (`built ... [cached]`), and `--no-cache` bypasses
it. `mtc cache status` reports entry count and total bytes; `mtc cache purge`
deletes all cached entries.

### 0.5 Linter

36 rules implemented (12 original AST-only + 5 scope-tracking + 10 Tier-1 AST
rules + 5 CFG/flow rules + 2 ownership rules + 2 sema-facts rules).
58 linter tests total (linter_test.mt). The five CFG/flow rules and the two
sema-facts rules are implemented in separate modules (`linter/cfg.mt`,
`linter/nullcheck.mt`, `linter/own_ptr.mt`, `linter/redundant_cast.mt`) —
the module split was a workaround for a parser step-counter limit that was
fixed in 2026-07-17 (§5.6); combined inlining is now safe but kept separate
for architectural clarity.

`redundant-null-check` (2026-07-17) uses a structural forward narrowing walk
(`linter/nullcheck.mt`): non-null name sets threaded through statements with
intersection at merges, `null_check_pairs`-style condition refinements
(`not`/`and`/`or` composition), write kills (including `ref_of`/`ptr_of`
borrows), loop kill-sets, and termination-aware `if x == null: return`
narrowing. Verified byte-identical findings vs Ruby across `projects/mtc/src`
(2 warnings, same lines) and `std/` (clean under both).

The `mtc lint` command previously double-counted warnings
(`total_warnings += warns.len()` after already adding the filtered count),
inflating "Found N warnings" 2× and forcing exit 1 when `--ignore`/`--select`
filtered everything out. Fixed (2026-07-17); `--ignore` now reports
`clean ...`/exit 0 at parity with Ruby.

`mtc lint --fix` and `.mt-lint.yml` config landed 2026-07-18 (§3.4):
7 auto-fixable rules through an edit-based multi-pass engine
(`linter/fix_engine.mt`), config discovery + YAML-subset parsing
(`linter/config.mt`), `Warning.column`/`length` fields, and
`lint_source_opts` for configurable line length. The same engine powers the
LSP's quickfix code actions.

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
codegen compiles with 0 C errors), fixed point holds, 476/476 tests, 13/13
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
`keep_c_to_file`). Fixed point holds, 476/476 tests, 13/13 language examples,
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

All three landed under a held fixed point (stage2.c == stage3.c), 476/476 tests,
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
correctly-rejected non-executables); fixed point holds, 476/476 tests, 13/13
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

Four items landed together (fixed point held, 476/476 tests, 13/13 language,
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
  identity, platform config, and every module path+length+source —
  is stored beside the binary and compared byte-for-byte on lookup; the FNV-1a
  hash only names the entry directory, so a collision degrades to a miss, never
  a wrong binary. Measured: language_baseline rebuild 0.41 s → 0.09 s; full
  217-example raylib re-sweep 16 s.

### 2.9 Landed: language-example parity audit — layout attrs, static_assert, reinterpret (2026-07-16)

A systematic simple→advanced audit of all 13 language examples plus focused
feature probes: **runtime diff** (build with both compilers, compare
stdout+exit — at the time 11/13 byte-identical, with `async_network_lobby` and
`integration_test` flagged as Ruby-side anomalies; both were subsequently
resolved — the former as a debug loop-guard config asymmetry, §5.2, and the
latter via a `dyn` fix) and **structural C diff**
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

## 3. Remaining Linter Gaps

### 3.1 Ownership — DONE (2026-07-16)

`owning-release-leak` and `owning-release-double` are both active. The owning
type set is built from method_keys in `module_loader.check_program` (types with
a `.release()` method), stored in `Program.owning_type_names`, and threaded to
`lint_source`.

### 3.2 Semantic-facts — DONE (2026-07-17)

`prefer-own-ptr` and `redundant-cast` are now implemented as separate modules
(`linter/own_ptr.mt`, `linter/redundant_cast.mt`) with thin wrappers in
`linter.mt`. Both work at the AST level without sema_facts:

- `prefer-own-ptr`: detects `ptr[T]`/`const_ptr[T]` type annotations, tracks
  unsafe depth per variable read, flags when all uses are inside `unsafe:` blocks.
- `redundant-cast`: collects declared types from `let`/`var` TypeRef annotations,
  compares cast target TypeRef against declared type.

### 3.3 Full CFG — 5 of 5 rules DONE (2026-07-17)

| Rule | Status |
|------|--------|
| `dead-assignment` | **DONE** — backward liveness walk in `linter/cfg.mt` |
| `unreachable-code` | **DONE** — `stmt_always_returns`-based structural check |
| `constant-condition` | **DONE** — AST pattern matching for literals and self-comparisons |
| `loop-single-iteration` | **DONE** — `always_returns_body`-based structural check |
| `redundant-null-check` | **DONE** — structural forward narrowing walk in `linter/nullcheck.mt` (§0.5); findings byte-identical to Ruby on `projects/mtc/src` and `std/` |

### 3.4 Tooling — DONE (2026-07-18)

| Gap | Status |
|-----|--------|
| `--fix` | **DONE** — `linter/fix_engine.mt` ports Ruby's multi-pass rule-isolating loop (each pass fixes one rule at a time from a fresh re-lint, bottom-up within a file, until fixpoint or 5 passes). Fixable rules: `prefer-let`, `redundant-return`, `redundant-else`, `trailing-list-comma`. `unused-import` is deliberately NOT fixable, matching Ruby's rationale (removing an import can drop extension methods / canonical hooks invisible to per-file linting). `Warning` gained `column`/`length` fields (populated by trailing-list-comma; other rules remain line-granular). Verified byte-identical fix output vs Ruby on a multi-rule fixture; valgrind-clean; 12 new tests (fix_engine_test.mt, suite now 488). **Expanded (same day)**: `redundant-cast` (drops `Type<-` and an inline `unsafe:` wrapper; rule now also covers let/var initializers and unsafe payloads, and carries the cast column), `redundant-bool-compare` (`x == true` → `x`, `x == false` → `not x`; identifier operands only, expression-first form only — both matching Ruby's fix output), and `redundant-type-annotation` (drops `: T`; rule now reports the real line instead of 0). The fix engine is edit-based (`FixEdit` + `edits_for_warning`/`apply_edit`), and `lsp_edit_for_warning` feeds LSP code actions: every fixable rule surfaces a "Fix <code>" quickfix computed against the live buffer. Suite now 494. Known depth gap: Ruby's redundant-cast is sema-based (widening/own→ptr coercion analysis, 42 findings on projects/mtc/src) while the self-host rule is AST-level (same-name comparisons only). |
| `.mt-lint.yml` config | **DONE** — `linter/config.mt`: ancestor-walk discovery (100-level cap, mirroring Ruby `load_config`) + minimal YAML-subset parser for `select:`/`ignore:` (block and inline lists) and `max_line_length:`. CLI flags override config; `max_line_length` threads through new `lint_source_opts`. Verified same warning sets as Ruby under a shared config. Known pre-existing divergence surfaced at tiny limits: Ruby's line-too-long skips non-wrappable lines (imports, simple statements) and appends "; wrap the expression" when a formatter wrap fix exists — the self-host flags all long lines with the plain message (formatter wrap-fix machinery not ported). |

---

## 4. Out-of-scope Subsystems

| Gap | Effort |
|-----|--------|
| Package-graph resolution (`--locked`/`--frozen`) | Large |
| ~~Build cache~~ **DONE (§2.8)** | — |
| `--bundle` / `--archive` | Medium |
| Wasm compilation (emcc) + preview server | Large |
| `--jobs` parallel test execution | Medium |
| ~~`--sanitize`~~ **DONE (2026-07-17)** | — |
| ~~`cache` inspection~~ **DONE (2026-07-17)** | — |
| ~~`run-module`, `new`, `completions`~~ **DONE (§2.8)**; `debug`, `deps`, `toolchain`, `bindgen`, `docs`, `snapshot` | Varies |
| LSP server | Medium | **DONE (2026-07-18)** — 23 modules, ~4,950 lines, 3 tiers + 4 quality phases, valgrind-clean, 25 capabilities advertised, editor-verified (headless Neovim) |

---

## 5. Remaining Gaps (new-session context)

The compiler is at a held fixed point (494/494 tests across 10 files, 13/13
language examples, 217/219 raylib — the 2 non-builds are correct rejections;
12/13 language examples byte-identical at runtime after the §5.2 `dyn` fix,
the one exception is the pre-existing shared libuv crash).
**No known self-host codegen, runtime, or example-parity bug remains.** All
landed work is recorded in §1 (external-type fixes) and §2 (per-session logs
§2.1–§2.9). What follows is the complete remaining-gap inventory, prioritized.

### 5.1 Analyzer false positives → semantic-error gate (DONE — 2026-07-16)

The self-host's semantic analyzer was deliberately conservative — it recorded
`ty_error` for expressions involving imported types, cross-module calls, and
struct-field chains. This blocked the semantic-error gate: gating on sema errors
would reject valid programs because the analyzer reported false positives on
perfectly valid code.

**All 13 check errors on `language_baseline.mt` are eliminated.** `mtc check` is
now 0 errors / 184 warnings (linter hints only). The gate is flipped from
`diagnostic_module_error_count()` to `diagnostic_error_count()` at all 4 sites
(lower, emit-c, build, run).

Fixes applied (all in `analyzer.mt`):

| Issue | Root cause | Fix |
|-------|-----------|-----|
| `unknown type type` (3) | `resolve_named` had no `"type" -> ty_type_meta` branch | Added check before generic-constructor resolution |
| `unknown type U` (2) | `resolve_constraint_method` called `build_fn_sig` without suppressing interface type params | Added `enter_suppressed_interface_method` + `suppressed_type_names.clear()` |
| `unknown name N` (4) | Generic value params `[N: int]` were not bound in the local scope for expression use | Bind value params as immutable locals in `check_function_body` |
| `unknown name value/rename/traced` (3) | Compile-time reflection builtins (`field_of`, `attribute_of`) pass bare field/attribute names that are not value identifiers | Extended `is_known_value_identifier` to recognize declared attribute names and struct field names |
| `unknown field` on re-exported enum members (4) | Type-aliased external enums (`type uv_run_mode = c.uv_run_mode`) had member lookups fail because the wrapper binding lacks member keys | `check_imported_member` now follows type-alias chains via `follow_type_alias` to the source external module |
| Imported types in expression position | `resolve_member_access` had no path for `alias.Type` as a type reference in expression context | Added `try_imported_type` dispatch between `static_type_receiver` and the `check_member` fallback |
| `imported_static_member` return type | Always returned `ty_error` for valid enum/flags/variant members | Returns `ty_imported(module, type_name)` for precise type tracking |

Fixed point holds, 476/476 tests pass, language examples build and run, raylib
examples unaffected. The 77% fallback rate in lowering remains — the analyzer
still delegates most expression type resolution to the lowering — but it no
longer reports false-positive errors on valid code in the common patterns.

### 5.2 Ruby-side bugs from the parity audits — verified with minimal repros (2026-07-16)

All three were re-examined with small tmp apps and gdb. Only one was a real
Ruby compiler bug, and it is **fixed** (the other two are a guard-config
asymmetry and a shared libuv crash, neither compiler-specific):

| Item | Verdict |
|------|---------|
| `dyn` vtable wrapper arity | **REAL BUG — FIXED.** Minimal repro: a value-receiver interface method whose body touches `this` only through a PrefixCast (`return float<-(this.value)`). The wrapper's private `method_uses_this?` AST walk had no PrefixCast arm (nor Call/Index/If/Match arms), so it omitted the receiver argument while the C backend — which authoritatively counts name references in the lowered IR — kept the receiver parameter → arity mismatch, C error. Fix: deleted the duplicated heuristic; the wrapper always passes the receiver and uses a String callee so the backend's single-source-of-truth omitted-receiver logic drops it when (and only when) the target's receiver param was omitted. 11/11 dyn tests pass; `integration_test` + repro build and run. |
| `async_network_lobby` abort | **NOT a Ruby bug — reclassified.** gdb showed `mt_fatal("loop iteration limit exceeded in std_net_discovery_announce__resume")`: the *debug loop guard* (50M iterations per function-call-local counter) tripping in a legitimately long-polling discovery loop. My audit built the Ruby binary with guards on and the self-host comparison binary effectively without; with `--no-debug-guards` the Ruby binary runs to `SUCCESS` with output identical to the self-host's. Real issue (minor, pre-existing): resume-loop iteration guards are miscounted across CPS awaits — a suspended/resumed loop accumulates guard counts per resume, so long-running async polls can trip the guard spuriously in debug profile. |
| `async_stress_test` crash | **Confirmed shared** (exit 134 under both compilers, identical behavior) — the known pre-existing libuv runtime bug, not compiler-specific. |

### 5.3 Linter gaps (§3)

`redundant-null-check` is **DONE** (2026-07-17, §0.5/§3.3). Tooling
(`--fix`, `.mt-lint.yml`) is **DONE** (2026-07-18, §3.4). Remaining linter
delta: Ruby's larger auto-fixable set (prefer-let-else/var-else,
redundant-bool-compare/cast/type-annotation, redundant-ignored-match-binding,
reserved-primitive-name renames) needs per-rule column tracking and the
formatter wrap-fix machinery.

### 5.3a RESOLVED: 5 language examples failed the sema gate (found + fixed 2026-07-17)

A `--no-cache` sweep of all 13 language examples revealed 5 build failures
(`async_network_lobby`, `async_stress_test`, `data_structures`,
`event_stress_test`, `option_and_result_surface`) — analyzer **false
positives** the §5.1 gate flip did not cover, present since the gate flip and
masked by cached sweeps. All five error classes were fixed in one pass
(fixed point held, 471 tests, 13/13 language build, 19-example raylib
`--no-cache` spot check clean, runtime byte-identical to Ruby on every
headless-runnable example):

| False positive | Root cause | Fix |
|---|---|---|
| `unknown method Task.map_error` | `expr_await` returned the lifted `Task[T]` type unchanged | `await` now unwraps `Task[T] -> T` (mirrors Ruby `infer_await`) |
| `return type mismatch: expected ubyte, got int` (`return 48 + value`), `cannot assign int to uint` (`1 << uint<-x`) | `infer_binary` always returned the left operand's type | Literal harmonization: an integer-literal operand adapts to the other operand's integer type; float literals likewise (mirrors Ruby `harmonize_binary_*_literal_types`) |
| `unknown method Option.expect` / `Result.expect` | Hardcoded prelude method list was stale vs `std/option.mt` / `std/result.mt` | `install_prelude_types` now merges the seeded `std.option`/`std.result` binding exports (`merge_prelude_binding_methods`), so new std methods are known automatically; fallback list also completed (`expect`, `expect_error`, `unwrap_or_else`) |
| `unknown name EventError` | Built-in event enum never registered by the analyzer (Ruby registers it in type_declaration.rb) | `register_builtin_event_types`: `EventError` (member `full`, match-exhaustive) + opaque `Subscription` |
| `return type mismatch: expected Keys[<error>, ptr_uint], got Keys` | (a) top-level-only `ty_error` suppression missed error *components*; (b) `nominal_key` compared `module.name` vs bare `name` for the same type | (a) new `types.contains_error` deep check gates `types_compatible`; (b) `nominal_definitely_different`: names must differ, or both carry known-but-different module qualifiers |

### 5.3b FIXED: Shared runtime bugs surfaced by the §5.3a sweep (2026-07-17)

A `valgrind`/`gdb` session traced both exit-134 / exit-4 anomalies:

| Example | Symptom | Root cause | Fix |
|---|---|---|---|
| `data_structures` | `free(): double free` (exit 134) before output | `std/graph.mt` `compile()` shallow-copied `this.nodes` (a `Vec[T]`) into the returned `DenseGraph`; both `release()` paths freed the same `data` pointer. Also, `must_alloc` used for `visited`/`in_degree` arrays in bfs/dfs/toposort — never zeroed → uninitialized reads (UB). | std/graph.mt: deep-copy nodes in `compile()` (new `Vec` + copy span); `must_alloc_zeroed` for bfs/dfs/toposort arrays |
| `event_stress_test` | exit 4 (`unsubscribe_active_subscription`); exit 8 (`subscribe_once_stateful_and_emit`); exit 12 (`stale_unsubscribe_ignored_on_emit`) | **Test-authored bugs**: four subscription-lifecycle leaks (listeners never unsubscribed after checks 1/3/7/9/11), filling 4-slot capacity so later checks' `subscribe` silently returned `false`. Exit 4 persisted because the global `no_payload_count` started >1 from a stale listener. **Compiler bug**: the self-host emit function dispatched stateful listeners as `((void (*)(void)) listener)()`, dropping the stored `slot.state` pointer → stateful callbacks had no state parameter and their writes went to garbage addresses. | examples/event_stress_test.mt: `subscribe_and_emit`, `subscribe_with_payload`, `stateful_subscribe_and_emit`, `multiple_subscribers`, `unsubscribe_and_resubscribe` all capture+unsubscribe their handles; `unsubscribe_active_subscription` assertion fixed (`== 0` → `== 1`, the persistent count from check #1 after cleanup). self-host `lowering.mt` `build_event_emit_fn`: added a `slot.state != NULL` guard that dispatches stateful listeners as `void(*)(void*, [payload])` — matching Ruby's snapshot-based dispatch. |

Both examples now exit 0 with byte-identical stdout+exit under both compilers, valgrind-clean (`data_structures`), and `--no-cache` build passes for all 13 language examples. The user's initial hypothesis of compiler-inserted auto-release was a red herring — the valgrind trace showed explicit `release()` calls were the double-free source, and the compiler does not inject scope-exit releases for `Vec[String]` fields (verified with a minimal probe via `Holder.items` copy).

### 5.4 CLI commands not implemented (§0.4)

`debug`, `deps`, `toolchain`, `bindgen`, `docs`, `snapshot`. The other 16 commands
are at parity, incl. `cache` / `new` / `run-module` / `completions`.

### 5.5 Subsystems not ported (§4)

Package-graph resolution (`--locked`/`--frozen`, Large), `--bundle` /
`--archive` (Medium), wasm/emcc + preview server (Large), `--jobs` parallel
tests (Medium). Additional vendored-library recipes (box2d, sdl3, flecs,
pcre2, steamworks) follow the §2.6 pattern when an example needs them.

### 5.6 Accepted minor divergences (verified benign)

- **Inline-while compile-time unrolling** — **FIXED (2026-07-17).** The self-host
  parsed `inline while` as `stmt_while.is_inline = true` but the lowering path
  never checked `is_inline` — it always emitted a runtime C `while` loop. The
  semantic analyzer also didn't validate that the condition is a compile-time
  constant, silently accepting `inline while n < LIMIT` where `n` is a `var`.
  Fix: analyzer now rejects non-constant inline-while conditions (mirroring
  Ruby's `check_inline_while_stmt`); lowering now intercepts `is_inline` and
  unrolls the body via `lower_inline_while` (capped at 10 000 iterations,
  matching Ruby's `lower_inline_while_stmt`). Verified: literal `5 > 0` →
  0 `while` keywords in C; const `N > 0` → 0 `while` keywords; var `n < LIMIT`
  → rejected; `language_baseline.mt` builds/runs.
- **Parser step-counter limit** — **FIXED (2026-07-17).** The parser's loop guard
  (`MAX_LOOP_STEPS = 100000` in `state.mt`) was a cumulative counter spanning
  the entire parse session. Large files (e.g. a combined linter with ~170K
  tokens) triggered a `fatal("parse loop guard: stuck at ...")` abort whose
  `fputs` in `mt_fatal` then segfaulted inside glibc — manifesting as "C codegen
  issues" / SIGSEGV at `0x7fff...` in libc. The prior module split was a
  workaround: each sub-module had its own fresh `ParserState` + counter. Fix:
  raised the limit from 100K to 2M, enough for ~57K functions or any practical
  single-file program. Verified: 3K-function × Vec+String-body file
  (parse→emit→build→run), 8K-function file (280K C lines emitted), full
  bootstrap fixed point, 13/13 `--no-cache`.
- **Stateful emit dispatch** — **FIXED (2026-07-17).** The self-host emit function
  previously cast all listeners as `((void (*)(void)) listener)()`, silently
  dropping the state pointer for stateful subscriptions. Now dispatches
  `slot.state != NULL` paths as `void(*)(void*, [payload])` — byte-identical
  to Ruby's snapshot-based dispatch. (Lowering `build_event_emit_fn`,
  `lowering.mt`.)
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

### 5.7 LSP remaining deltas (quality, not bugs)

25 of Ruby's 49 capabilities are advertised; every advertised feature is at
functional parity or better. Remaining Ruby-only capabilities (24): call
hierarchy (3 methods), type hierarchy (3), codeLens + resolve, documentLink +
resolve, rangeFormatting, linkedEditingRange, executeCommand,
completionItem/resolve, semanticTokens full/delta, pull diagnostics (2),
progress/configuration/cancel plumbing, `milkTea/*` custom methods. Quality
deltas inside shared capabilities: references/rename are token-accurate but
single-file and not scope-aware (shadowed locals conflate); completion lacks
method-receiver members and named-argument suggestions; inlay hints skip
`alias.fn(...)` calls; workspace/symbol requires a non-empty query (no
workspace index). See `docs/lsp-design.md` §8.

### 5.8 Next-session candidates (prioritized)

1. **`deps` package management** (Large) — the biggest remaining CLI gap;
   `--locked`/`--frozen` resolution depends on it. Multi-session project;
   start with `PackageManifest`/`PackageGraph` reading and `deps tree`.
2. **`bindgen`** (Medium-Large) — C header → binding module generation;
   unlocks self-serve external bindings.
3. **Wasm/emcc + preview server** (Large) — platform reach.
4. **Linter depth** (Medium) — sema-based `redundant-cast` (Ruby finds 42
   coercion-redundant casts on projects/mtc/src that the AST-level rule
   cannot), Ruby's line-too-long wrappable-candidate skip-set + "; wrap the
   expression" suffix (needs formatter wrap-fix machinery), remaining
   fixable rules (prefer-let-else/var-else, redundant-ignored-match-binding,
   reserved-primitive-name renames).
5. **LSP long-tail** (Small-Medium each) — scope-aware references/rename,
   method-receiver completion, workspace-symbol index, then §5.7's
   capability list by demand.

### 5.9 Verification checklist for any change

Run before considering a change done:

```sh
tools/bootstrap.sh                              # 3-stage + fixed point + tests
# then, from repo root, for a representative sweep:
build/stage2/mtc build examples/language_baseline.mt -I . -o /tmp/lb --no-cache
# full language sweep MUST use --no-cache (cached binaries masked the §5.3a
# 5-example sema-gate regression for two days); baseline: 13/13 build
# raylib parity sweep (per-file build, compare against the passing baseline)
```

A change is safe only if: stage2.c == stage3.c, 494/494 tests pass, 13/13
language examples build, and the raylib passing set does not shrink (currently
217; the 2 non-builds must remain clean rejections with Ruby's messages).
LSP changes additionally require the piped JSON-RPC fixtures + valgrind and,
for behavior changes, the headless-Neovim smoke test.

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
**12/13 byte-identical**; `async_stress_test` crashes under both; the
`async_network_lobby` guard-config asymmetry and the `integration_test` Ruby
`dyn` bug are resolved (see §5.2).

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
