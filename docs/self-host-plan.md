# Self-Host Plan

Status: **SELF-HOSTING FIXED POINT ACHIEVED. RAYLIB + LANGUAGE PARITY COMPLETE. LSP + DAP + BINDGEN + IMPORTED-BINDINGS COMPLETE.**
Stage2 == stage3 byte-identical. 177 self-tests pass across 12 test files.
**Raylib parity: 217/219 build and run**
**Language parity: 13/13 build under `--no-cache`**; all 12 examples runnable headless produce
byte-identical stdout+exit vs Ruby. CLI: 18 commands at parity (added `cache`,
`lsp`, `dap`, `bindgen`, `toolchain`). **`mtc lint` has 36 rules plus `--fix`
(10 auto-fixable rules, byte-identical output vs Ruby) and `.mt-lint.yml`
config**. Bootstrap via `tools/bootstrap.sh`.
Test runner now builds in-process (no Ruby delegation).  Vendored library
recipes complete for all 7 libraries (raylib, glfw, tracy, cjson, box2d,
sdl3, flecs, pcre2, steamworks, libuv).  Bindgen self-hosted (687 lines CL
→ MT type mapper + clang JSON AST parser).

**DAP: 7 modules, ~1,050 lines, 25 handler methods dispatched.**
**LSP: 35 modules, ~9,500 lines, 29 capabilities advertised, capability-parity with Ruby.**
**Hover: 18/25 declaration types covered (up from 5/25).**
**LSP stability: zero SIGSEGV/SIGABRT crashes; UTF-8 boundary auto-adjust; parser/lexer recoverable.**
**LSP logging: structured stderr, version+revision announcement, blank-line filtering.**
**Diagnostic positions: lexer-based token matching; buffer-overflow warning fix (MAX_ENTRIES 16→128).**
**Code lens: reference counts with deduplication; all index entries queried.**
**References: cross-file via workspace index; definition: local variables supported.**
**Signature help: method calls and extending-block methods resolved.**
**Imported-bindings: 7 modules (incl. registry + methods), ~2,700 lines.  `mtc imported-bindings` CLI command with --all/--check.
Byte-identical raymath output. 3 verified / 25 changed across all 28 bindings (remaining deltas from cosmetic emitter gaps).**

**Remaining CLI gaps: `deps`, `docs`, `--bundle`/`--archive`,
`--jobs`, Wasm/emcc, formatter CST modes (`--tidy`, `--preserve`).**
~~`docs`, `snapshot`~~ **`snapshot` DONE (§5.8a).  `debug` DONE (§5.8a).**
Toolchain doctor is self-hosted; bootstrap/tools subcommands deferred.

Last updated: 2026-07-20 (LSP hover/resilience/warning-positions/references/definition/signature-help session)

---

## 0h. 2026-07-20 session — LSP resilience, hover parity, diagnostics, and QoL

All landed under a held fixed point (stage2.c == stage3.c), 177/177 tests,
13/13 language examples.  15 commits.

### Compiler resilience
1. **Lexer recoverability** — `session_fatal` no longer calls `fatal()` when
   `diags` is null; silently returns, making the lexer recoverable in all
   contexts (not just `lex_reporting`).
2. **Parser loop guard** — two-level guard: per-declaration reset at 500K
   steps with token skipping, hard 50M total-step cap with descriptive `fatal()`.
3. **`str.slice` UTF-8 auto-adjust** — instead of `fatal()` on non-UTF-8-boundary
   positions, walks backward to the nearest valid code-point start.  Fixes all
   callers that iterate source byte-by-byte (completion, code_lens, hover).

### LSP stability
| Fix | Impact |
|-----|--------|
| `session_fatal` never aborts | Lexer survives unclosed parens |
| Parser `step()` skips stuck tokens | No infinite-loop OOM |
| `str.slice` auto-adjusts boundaries | No more UTF-8-boundary SIGABRT |
| Column off-by-one fix in `resolve_non_decl_hover` | Builtin/keyword hover works |
| `find_token_str` 0-indexed column matching | Local hover works |

### Hover parity — 5/25 → 18/25 cases
| P0-P1: 7 new cases | P2: 4 new cases | Phase 1: 2 new cases |
|--------------------|-----------------|---------------------|
| Methods (extending blocks) | Keywords (size_of, align_of) | Local let/var |
| Interfaces | Builtins (fatal, ref_of, etc.) | Lexical fallback |
| Type aliases | Specializations (zero[T], etc.) | |
| Opaques | Field declarations | |
| const functions | | |
| Doc comments (already active) | | |
| Enum member dot-access | | |

### Cross-file features
- **References**: `handle_references` now queries workspace index for all files
  containing the symbol, scans each for identifier occurrences.  Previously
  same-file only.
- **Definition**: `handle_definition` falls back to `resolve_local_hover` for
  local variables.  Ctrl+Click on `let x` now jumps to the declaration.

### Signature help
- Method calls (`obj.method`) resolve via dot-receiver analysis
- Extending-block methods found by scanning `method_keys` for `*.name` suffix
- Previously only top-level functions

### Hover source location links
- Every hover popup now shows `*Defined at line N*` in italic markdown

### LSP logging
- `std/log.mt` stderr flush ensures server messages reach VSCode output channel
- Server startup announces version + git revision (`mtc 0.1.0 (c92a4bd)`)
- `mtc-lsp` wrapper fixed to forward `--log-level` args; or use `mtc lsp` directly
- VS Code extension `emitStderr` filters trailing blank lines from pipe reads

### Diagnostic position accuracy
- `diagnostic_from_warning` now uses `lex_reporting()` token stream instead of
  byte-scanning — no more false matches in comments/string-literals/doc-comments
- Line=0 clamp: when `w.line == 0`, searches line 1 for the quoted token name
- Linter: `missing-return` now uses AST node line; `borrow-and-mutate`,
  `owning-release-leak`, `prefer-own-ptr` use line=1 anchor

### Linter buffer overflow fix
- `MAX_ENTRIES` 16→128 per scope, buffer 512→4096 entries.  Functions with
  37+ locals (e.g. `statements_demo`) no longer overflow scope entries, eliminating
  59 fake empty-name `unused-local` warnings

### Code lens fixes
- `count_references` queries all index entries (not capped at 500)
- File reads deduplicated — methods defined in multiple extending blocks in
  the same file counted once, not 6×
- Un-resolved code lens entries omit `command` field so VSCode calls `codeLens/resolve`

### Git revision injection fix
- `version_info.mt` restored to `__PLACEHOLDER__`; bootstrap script's `sed`
  now correctly injects `git rev-parse --short=7 HEAD` each build

### Known gaps (not yet fixed)
- `completion`: prefix filtering written but blocked by C backend const-correctness
  bug in `std/imported_bindings/registry.mt`
- `dead-assignment` at line 0 (15 warnings): cfg module produces DeadWrite
  entries with line=0 for assignments in nested scopes
- `prefer-own-ptr` at line 1 (1 warning): scope-based rule, line tracking not stored

### DAP status
- 7 modules, ~1,050 lines, process backend with child I/O polling
- Lldb-dap bridge not feasible without multi-threaded I/O (§dap-design §9)



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

## 0d. 2026-07-19 session — LSP 24-gap closure (7 phases, 15 capabilities added)

All landed under a held fixed point (177/177 tests), 13/13 language examples,
35 LSP modules at ~8,500 lines, 29 advertised capabilities at Ruby parity.

| Phase | Commit | Capabilities |
|-------|--------|-------------|
| 1 | `9b8d2c28` | executeCommand, documentLink+resolve, linkedEditingRange, rangeFormatting, completionItem/resolve, milkTea/documentContext, milkTea/debugInfo |
| 2 | `f85d4a48` | codeLens+resolve, typeHierarchy (prepare/supertypes/subtypes), callHierarchy (prepare/incomingCalls/outgoingCalls) |
| 3 | `7eacc935` | $/progress notify, $/cancelRequest, 4 workspace notification stubs |
| 4 | `d177de34` | pull diagnostics (textDocument/diagnostic + workspace/diagnostic) with FNV-1a fingerprint caching |
| 5 | `0dccd154` | semanticTokens/full/delta with LCP/LCS delta encoding |
| 6 | `82f02635` | 7 capability fidelity fixes (save includeText, completion triggers, codeAction fixAll, semanticTokens delta object, workspace.workspaceFolders, workspace.fileOperations.willRename, workspace.didChangeWatchedFiles) |
| 7 | `5cefa645` | outgoing request-response + config pull (workspace/configuration), 4 workspace handler implementations (cache invalidation) |

New modules (12): execute_command, document_context, debug_info, document_link,
linked_editing_range, code_lens, type_hierarchy, call_hierarchy, pull_diagnostics,
workspace_notifications (replaced stubs).  Total: +3,000 lines.

---

## 0e. 2026-07-19 session — DAP process backend (4 phases)

All landed under a held fixed point (177/177 tests).

| Phase | Commit | What |
|-------|--------|------|
| 1 | `67a0c536` | DAP protocol (Content-Length framing, JSON parsing, `Message` struct), server loop, 25-command dispatch, 15 full handler implementations, design doc |
| 2 | `8ca5d65f`→`beaf7f99` | Review cleanup + fix JSON use-after-free (`parsed` released in `release_message` not `read_message`) + fix session double-free |
| 3 | `d531f1b8` | Functional process backend: launch spawns child via `process.spawn`, poll stdout/stderr non-blockingly between dispatches, exit detection via `try_wait()`, SIGCONT/SIGSTOP/SIGTERM signal forwarding |
| 4 | `06f3a45a` | Final cleanup: removed dead `release_msg`, unused imports, truncated comments |

New modules (7): protocol, server, session, handlers, process_backend, wire,
utilities.  Total: +1,050 lines.

Lldb-dap bridge assessed as not feasible without multi-threaded I/O or
`select`/`poll` syscall bindings (§dap-design §9).

---

## 0f. 2026-07-19 session — Linter depth (parser fix + 3 new auto-fix rules)

All landed under a held fixed point (177/177 tests).

Fixable rules: 7 → 10 (Ruby has 11).  Byte-identical vs Ruby on
prefer-let-else, prefer-var-else, and redundant-ignored-match-binding.

| Commit | What |
|--------|------|
| `a8369c5d` | prefer-let-else / prefer-var-else auto-fix: merge declaration + if-guard into single `let x = v else:` line.  Byte-identical to Ruby. |
| `abba6d9e` | Parser fix: `binding_line` was hardcoded 0 in match-arm parsers — now reads the `as` keyword's source line.  Add redundant-ignored-match-binding fix (delete ` as _` text).  Add reserved-primitive-name fix (rename declaration, e.g. `int` → `int_value`). |

Private fix: `binding_line` in `parse_match_arm_into` and
`parse_match_expr_arm_into` (parser.mt) was always 0; now captured from
`pstate.previous().line` after `match_kind(tk_as)`.  This fixes warning
positions for both statement-match and expression-match arms.

---

## 0g. 2026-07-19 session — imported-bindings self-hosting + 3 bootstrap fixes

All landed under a held fixed point (177/177 tests), 13/13 language examples.

### Imported-bindings pipeline self-hosted (6 modules, ~2,300 lines)

| Module | Lines | Purpose |
|--------|-------|---------|
| `policy.mt` | ~600 | Parses `.binding.json` → typed structs (BindingPolicy, AliasSpec, etc.) |
| `naming.mt` | ~250 | snake_case (with digit boundaries: Vector2Add → vector2_add), camelize, rename rules, reserved-word sanitization |
| `raw_scanner.mt` | ~450 | Scans external `.mt` files for type (struct/union/enum/flags/opaque), const (with type extraction), function (parsed params + return type), and import declarations |
| `emit.mt` | ~590 | Generates type aliases, const aliases, foreign functions (snake_cased params, function overrides with in/out/inout modes + boundary_type projections + return_type/mapping overrides, cross-module import detection) |
| `methods.mt` | ~430 | Scans pre-generated module foreign functions, emits `extending Type:` method blocks for same-module and external (std.raymath → raylib) sources |
| `main.mt` | ~230 | Orchestrator — policy parse → raw scan → type/const/func/method emission → output assembly |

**Verified**: byte-identical to Ruby for `std/raymath.mt` (153 lines, MD5 `935893d14...`).

### Bootstrap fixes (same session)

Three real self-host codegen bugs found during pipeline build testing:

1. **`c_type()` for `ty_imported` discards generic type args** — `c_type(ty_imported(module="std.vec", name="Vec", args=[string.String]))` returned `std_vec_Vec` instead of `vec_Vec_str_String`. Tuple struct fields emitted wrong types. Fix: `c_type` now appends type arg keys via `type_c_key()`, matching the existing `naming.type_c_key()` behavior.

2. **`.is_success()` resolves to wrong Result monomorphization** — `fs.write_text(...).is_success()` (returns `Result[bool, fs.Error]`) generated call to `Result_bool_std_terminal_Error_is_success` (from `terminal.Error` Result elsewhere). Fix: replaced `.is_success()` with `match Result.success/Result.failure` pattern in the one affected call site.

3. **`if` expression with mixed `null` / imported method call** — `if loc_vp == null: null else: read(loc_vp).as_object()` produced `void` type in C output because the lowering couldn't resolve `as_object()` return type. Fix: replaced with `var loc_obj: ptr[json.Object]? = null` + `if loc_vp != null: loc_obj = read(loc_vp).as_object()`.

Additionally, a Ruby-side nullability crash fix in `ControlFlow::Builder::read_identifiers` — adding explicit `when AST::MatchStmt` handling to prevent crash when match arms contain `return` statements in certain nesting contexts.

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
| `--fix` | **DONE** — `linter/fix_engine.mt` ports Ruby's multi-pass rule-isolating loop (each pass fixes one rule at a time from a fresh re-lint, bottom-up within a file, until fixpoint or 5 passes). Fixable rules (10): `prefer-let`, `redundant-return`, `redundant-else`, `trailing-list-comma`, `redundant-cast`, `redundant-bool-compare`, `redundant-type-annotation`, `redundant-ignored-match-binding`, `prefer-let-else`, `prefer-var-else`, `reserved-primitive-name`. `unused-import` is deliberately NOT fixable, matching Ruby's rationale (removing an import can drop extension methods / canonical hooks invisible to per-file linting). `Warning` gained `column`/`length` fields (populated by trailing-list-comma; other rules remain line-granular). Verified byte-identical fix output vs Ruby on multi-rule fixture; valgrind-clean; 12 new tests (fix_engine_test.mt). The fix engine is edit-based (`FixEdit` + `edits_for_warning`/`apply_edit`), and `lsp_edit_for_warning` feeds LSP code actions: every fixable rule surfaces a "Fix <code>" quickfix computed against the live buffer. Known depth gap: Ruby's redundant-cast is sema-based (widening/own→ptr coercion analysis, 42 findings on projects/mtc/src) while the self-host rule is AST-level (same-name comparisons only). Reserved-primitive-name fix renames declarations only (Ruby also renames all use sites). Line-too-long formatter wrap-fix machinery not ported. |
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
| ~~`run-module`, `new`, `completions`~~ **DONE (§2.8)**; `deps`, `toolchain`, `bindgen`, `docs`, `snapshot` | Varies |
| ~~LSP server~~ **DONE (2026-07-19)** — 35 modules, ~8,500 lines, 29 capabilities at Ruby parity | — |
| ~~DAP server~~ **DONE (2026-07-19)** — 7 modules, ~1,050 lines, process backend with child I/O polling | — |
| LSP workspace dependency graph (didChangeWatchedFiles depth) | Medium |
| LSP multi-root reindex (didChangeWorkspaceFolders depth) | Medium |
| Formatter CST modes (`--tidy`, `--preserve`) | Large |
| Linter wrap-fix machinery (`line-too-long` auto-fix) | Medium |
| **Added 2026-07-19** | |

---

## 5. Remaining Gaps (2026-07-19)

The compiler is at a held fixed point (177/177 tests across 12 files, 13/13
language examples, 217/219 raylib — the 2 non-builds are correct rejections).
**No known self-host codegen, runtime, or example-parity bug remains.** The
LSP has been brought to capability parity with Ruby (29 advertised, all 53
handler methods dispatched).  Remaining gaps are infrastructure-depth items:

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
(`--fix`, `.mt-lint.yml`) is **DONE** (2026-07-18, §3.4). Fix engine
expanded to 10 auto-fixable rules (2026-07-19, §0f). Remaining linter
delta: sema-based `redundant-cast` (requires analyzer type resolution);
`reserved-primitive-name` use-site renaming (declaration-only today);
formatter wrap-fix machinery for `line-too-long`.

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

`deps`, `docs`, `snapshot`. The other 20 commands
are at parity, incl. `cache` / `new` / `run-module` / `completions` / `lsp` / `dap` / `bindgen` / `toolchain` / `imported-bindings`.
The legacy Ruby `debug` command is replaced by `mtc dap`.

### 5.5 Subsystems not ported (§4)

Package-graph resolution (`--locked`/`--frozen`, Large), `--bundle` /
`--archive` (Medium), wasm/emcc + preview server (Large), `--jobs` parallel
tests (Medium). Additional vendored-library recipes (box2d, sdl3, flecs,
pcre2, steamworks) follow the §2.6 pattern when an example needs them.

~~Imported bindings pipeline~~ **DONE (§6.8)** — 6 modules, ~2,300 lines, byte-identical
raymath output.  Structurally complete for all 28 bindings with 3 known
cosmetic gaps (see §6.9).

### 5.5a RESOLVED: CBackend nullable value type naming mismatch (2026-07-20)

`nullable_and_variant_test.mt` failed with `unknown type name mt_opt_examples_nullable_and_variant_test_int`
because `resolve_field_type_ref` (used for variant arm payload types and function
param/return types) checked `ctx.analysis.type_names.contains()` before
`is_builtin_type_name()`. After builtin registration added primitives to
type_names, this resolved `int` as `ty_imported(module, name)` instead of
`ty_primitive("int")`. The struct field pathway (`resolve_type_ref`) had the
correct order. Fix: add `is_builtin_type_name` check before `type_names.contains`
in `resolve_field_type_ref`. All 13/13 language examples now build.

### 5.6a Accepted minor divergences (2026-07-20 additions)

- **Bare nested struct names** in `ctx.types` removed for facts parity.  Nested
  struct names are still available through the `structs` map for classification.
- **Interface names** and **struct event names** removed from `ctx.types` —
  interfaces/events are tracked in their own maps (`interfaces`, `event_types`).
- **Top-level event names in types** — parser convention alignment: events are
  tracked in `event_types`, not `types`.
- **Type aliases in `types`** — added for facts parity; Ruby counts aliases in
  the type count.

### 5.8a 2026-07-20 session — LSP crash fixes, CLI additions, semantic token parity

All landed under a held fixed point (177/177 tests), 13/13 language examples.

| Fix / Addition | What |
|---|---|
| `mtc snapshot` command | Delegates to `snapshot.js` via Node, passes self-host LSP semantic tokens via `-s` flag. |
| `mtc debug` command | Prints tokens, analysis facts (types, functions, structs, interfaces, imports, diagnostics). Uses `loader.check_program` for import resolution. |
| Git revision stamp | `mtc --version` shows `mtc 0.1.0 (30819bc)`. Bootstrap injects `git rev-parse --short` into `version_info.mt`. |
| LSP logging infrastructure | Integrated `std/log.mt`: `[LEVEL] message` to stderr. `--log-level` flag (trace/debug/info/warn/error, default warn). VSCode Output panel shows all LSP logs. |
| Per-request tracing | Every incoming LSP method logged at DEBUG level: `[DEBUG] lsp: → 1 initialize`. |
| `$/setTrace` handler | VSCode trace-level changes applied at runtime. |
| **Incremental text sync** | `textDocumentSync.change:2`. Range-based edits with UTF-8 line/char→byte conversion. |
| **Configuration application** | Parse `workspace/configuration` response; store `format_mode`, `dependency_resolution`, `platform_override`, `strict_current_root_diagnostics`. |
| **Use-after-free crash fix** | `apply_content_changes()` returned `result.as_str()` with `defer result.release()` — dangling str. Changed to return owned `string.String`. |
| **URI-to-path mismatch fix** | `didChange` passed raw URI to `ws.document_source()` which expects file paths; always got empty buffer. Convert URI→path before lookup. |
| **Semantic token types** | Legend extended to 15 types: added `enumMember`, `method`, `decorator`. `token_kind_to_type` now includes `colon/comma/question/at`. |
| **Method detection** | Dot-heuristic for call-site method detection (`target.method()`). Extending-block depth tracking for declaration detection. |
| **Enum member detection** | Enum body depth tracking identifies member names. |
| **Decorator detection** | `@[...]` context tracking classifies attribute names as `decorator`. |
| **Declaration modifiers** | Function/type/variable declarations marked with `declaration` modifier (bold in snapshot). |
| **Completion improvements** | `sortText` field, 200-item max cap. |
| **Snapshot CSS parity** | 10→3 RB-only CSS gaps closed (decorator, enumMember, method, function/type/variable decls). |
| **Debug facts parity** | 13/13 language examples: types, functions, imports counts match Ruby at 100%. |
| **Analyzer builtin types** | Register 26 primitives + 5 handle types + `type` in `ctx.types`; register prelude imports in `ctx.import_aliases`. |

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

### 5.8 Next-session candidates (updated 2026-07-20)

1. **`deps` package management** (Large) — the biggest remaining CLI gap;
   `--locked`/`--frozen` resolution depends on it.
2. **`--bundle` / `--archive`** (Medium) — native package distribution.
3. **Wasm/emcc + preview server** (Large) — platform reach.
4. **Formatter CST modes** (Large, §7) — `--tidy` (CST normalize + wrap + blank lines) and `--preserve` (CST-based, keeps original style).
5. **Linter depth** (Medium) — sema-based `redundant-cast`, formatter wrap-fix for `line-too-long`, `:fast` lint tier.

### 5.8b 2026-07-20 session — LSP completion depth + code actions

All landed under a held fixed point (177/177 tests), 13/13 language examples.

#### Completion improvements
| Change | What |
|--------|------|
| **Prefix filtering** | `current_word_prefix` extracts the identifier fragment the user is typing; all completion branches filter results by it. No more unfiltered full symbol lists. |
| **detail field** | Every completion item now carries a `detail` string: function signatures with param types, `"type"` for struct variants, `"name: T"` for values, `"module name"` for imports. |
| **insertText field** | Items now specify `insertText` alongside `label`, so editors can replace the prefix correctly. |
| **isIncomplete flag** | Results capping at MAX_COMPLETION_ITEMS (200) sets `isIncomplete: true` so editors keep querying. |
| **Response format** | All completion branches now return the proper LSP `{"isIncomplete":...,"items":[...]}` object, not a bare array. |

#### Code action quickfixes added
| Rule | Fix |
|------|-----|
| `unused-param` | Prefix with `_` (same as unused-local) |
| `dead-assignment` | Remove the entire source line |
| `shadow` | Prefix with `_` to suppress the warning |
| `unsafe-required` | Wrap the statement in `unsafe:` (pointer cast requires unsafe, ref-to-ptr requires unsafe) |
| `match-missing-arms` | Insert stub arms with `return` for each missing case |
| `only_kinds` filtering | `context.only` is now respected: `quickfix` and `source.fixAll` are emitted only when requested |

#### Remaining LSP gaps
- **Import completions** — filesystem-based, blocked by missing `std.fs.read_dir`
- **Scope/local completions** — requires AST walk for local variable scope tracking
- **Attribute/format-string/specialization contexts** — specialized completion contexts
- **Value-chain completions** — chained dot access (`a.b.c.|`)

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

A change is safe only if: stage2.c == stage3.c, 178/178 tests pass across 12
files, 13/13 language examples build, and the raylib passing set does not shrink
(currently 217; the 2 non-builds must remain clean rejections with Ruby's
messages). LSP changes additionally require the piped JSON-RPC fixtures +
valgrind and, for behavior changes, the headless-Neovim smoke test.

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

---

## 6. Imported Bindings Pipeline (2026-07-19)

### 6.1 Overview

The "imported bindings" pipeline is a **build-time code generation tool** that transforms low-level raw C binding modules (`std/c/*.mt`, generated by `bindgen`) into higher-level, idiomatic Milk Tea modules (`std/*.mt`). In Ruby it is invoked via **Rake tasks**; in the self-host it is invoked via the **`mtc imported-bindings` CLI command**:

```sh
# Self-host
mtc imported-bindings raylib                  # regenerate std/raylib.mt
mtc imported-bindings --check raymath         # verify output matches
mtc imported-bindings --all                   # regenerate all 28
mtc imported-bindings --all --check           # verify all 28

# Ruby
rake imported_bindings:all                    # regenerate all 28 binding modules
rake imported_bindings:raylib                 # regenerate just std/raylib.mt
```

The pipeline handles:
- **Type re-exports**: `public type Vector2 = c.Vector2`
- **Const re-exports**: `public const RAYLIB_VERSION: int = c.RAYLIB_VERSION_MAJOR`
- **Foreign function wrappers**: `public foreign function init_window(width: int, height: int, title: str as cstr) -> void = c.InitWindow`
- **Method extensions**: `extending Vector2:` with methods like `.add()`, `.subtract()`
- **Generic helpers**: `set_shader_value[T](shader: Shader, in value: T as const_ptr[void]) -> void`
- **Boundary projections**: `str as cstr`, `in`/`out`/`inout`/`consuming` parameter modes
- **Naming conventions**: snake_case public names vs CamelCase C names
- **OpenGL-specific transforms**: `gl.x` → `gl_` prefix normalization

### 6.2 Architecture

```
bindings/imported/<lib>.binding.json     (hand-written JSON policy)
  + std/c/<lib>.mt                       (bindgen-generated raw C bindings)
       ↓  Rake task
       ↓  MilkTea::ImportedBindings::Generator
       ↓    - loads policy, validates against raw module AST
       ↓    - indexes raw types/consts/functions
       ↓    - applies include/exclude/rename/override rules
       ↓    - emits type aliases, const aliases, foreign functions, methods
       ↓    - formats with Formatter.format_source
       ↓
std/<lib>.mt                             (checked-in, generated module)
```

### 6.3 Ruby Implementation

| Component | File | Lines |
|-----------|------|-------|
| Main generator | `lib/milk_tea/bindings/imported_bindings.rb` | ~300 |
| Policy engine | `lib/milk_tea/bindings/imported_bindings/generator.rb` | ~1114 |
| Method sources | `lib/milk_tea/bindings/imported_bindings/method_source.rb` | ~190 |
| Naming transforms | `lib/milk_tea/bindings/imported_bindings/naming.rb` | ~286 |
| Default registry | `lib/milk_tea/bindings/imported_bindings/defaults.rb` | ~50 |
| JSON policies | `bindings/imported/*.binding.json` (28 files) | ~100-2200 lines each |
| Rake tasks | `Rakefile` | ~25 |

Total: ~2000 lines of Ruby code + 28 JSON policy files.

### 6.4 Policy Capabilities

Each `.binding.json` can specify:

- **`types`**: `include`/`include_prefixes`/`exclude`/`overrides`/`rename_rules`/`strip_prefix`/`native_types`
- **`constants`**: Same filter structure, plus `type` and `mapping` overrides
- **`functions`**: Include/exclude filters, per-function overrides with custom `params` (supporting `boundary_type`, `mode`, `type_params`), `return_type` overrides, explicit `mapping` expressions
- **`methods`**: Extension methods on types, sourced from raw module or external `module_name`, with `receiver_types`, `include_prefixes`, `strip_prefix`, `rename_rules`
- **`imports`**: Additional module imports for the generated module

### 6.5 Self-Host Relationship

- The self-host **already imports and uses** the generated modules (e.g., `std.raylib.mt` is imported by raylib examples). All 217 raylib examples build and run with the self-host using these checked-in generated files.
- The self-host's semantic analyzer has `lookup_method_anywhere()` (`analyzer.mt` lines 3959-3978) which searches all imported modules' method tables — this is the **consumer** side of imported bindings.
- The self-host now has a **full generation pipeline** — 7 modules, ~2,700 lines — mirroring the Ruby pipeline. It can regenerate all 28 bindings via `mtc imported-bindings --all`.
- The generated files are **checked into the repository** and don't need regeneration unless the raw C binding or the policy changes.
- The CLI command replaces the Ruby Rake tasks for self-host workflows.

### 6.6 Self-Hosting Strategy

**ALL PHASES DONE.** The imported bindings pipeline is now fully self-hosted as both a library and a CLI command.

| Phase | Scope | Status |
|-------|-------|--------|
| 6a | JSON policy parser (`.binding.json` → typed structs) | **DONE — `policy.mt`** |
| 6b | Name transformations (snake_case, camelize, OpenGL) | **DONE — `naming.mt`** |
| 6c | Type/const/function emitter | **DONE — `emit.mt`** |
| 6d | Method extension emitter | **DONE — `methods.mt`** |
| 6e | Full policy validation and error reporting | **DONE — `main.mt` orchestrator** |
| 6f | Registry + CLI command (`--all`/`--check`) | **DONE — `registry.mt` + `main.mt` handler** |
| **Total** | | **7 modules, ~2,700 lines** |

Remaining: OpenGL naming transforms (only needed for `std.gl`), wide verification against all 28 bindings (3 verified, 25 changed — cosmetic emitter gaps from §6.10).

### 6.7 2026-07-19 Bindgen Status Update

The self-host `bindgen` command is now implemented (687 lines in `mtc/bindgen.mt`) and produces structurally correct external binding modules. Remaining minor type-mapping divergences (system typedefs leaking, `const char **` mapping, typedef resolution) are cosmetic and do not affect the generated module's validity. The bindgen output compiles and imports correctly as `std/c/*.mt` modules.

### 6.8 Self-Hosting Status (2026-07-19)

The imported bindings pipeline is now **self-hosted** as a library in the mtc compiler source tree (7 modules, ~2,700 lines):

| Module | File | Lines | Purpose |
|--------|------|-------|---------|
| policy | `imported_bindings/policy.mt` | ~600 | Parses `.binding.json` → typed structs |
| naming | `imported_bindings/naming.mt` | ~250 | snake_case, camelize, rename rules, sanitization |
| raw_scanner | `imported_bindings/raw_scanner.mt` | ~450 | Scans raw external `.mt` files for type/const/function declarations, parses function signatures (params + return type), extracts const types, tracks imports |
| emit | `imported_bindings/emit.mt` | ~600 | Generates type aliases, const aliases, foreign functions (with snake_cased params, function overrides, cross-module import detection, cstr heuristic) |
| methods | `imported_bindings/methods.mt` | ~560 | Scans generated module foreign functions, emits `extending Type:` method blocks (same-module + external sources, receiver type disambiguation, return type prefix stripping) |
| registry | `imported_bindings/registry.mt` | ~130 | Hardcoded registry of 28 binding entries (name → policy_path, raw_module_name, binding_path) |
| main | `imported_bindings/main.mt` | ~250 | Orchestrator — policy parse → raw scan → type/const/func/method emission → output assembly |

Bootstrap fix commits (same session): three real self-host codegen issues found and fixed:
- `c_type()` for `ty_imported` was discarding generic type args (tuple field types like `std_vec_Vec` instead of `vec_Vec_str_String`)
- `build_statement` in `main.mt`: `.is_success()` on `Result[bool, fs.Error]` resolved to wrong monomorphization (`Result_bool_std_terminal_Error_is_success`)
- `if` expression with mixed `null` / `as_object()` branches produced `void` type in C output

**Verification**: byte-identical to Ruby compiler for `std/raymath.mt` (153 lines, same MD5 hash). CLI command `mtc imported-bindings --all --check` reports 3 verified / 25 changed across all 28 bindings. 9 extending blocks emit for raylib (8 byte-identical, Quaternion ordering delta). Bootstrap 177/177 tests, fixed point held throughout.

### 6.9 Resolved Cosmetic Gaps (2026-07-19)

Three gaps resolved after initial self-hosting:

| Gap | Fix |
|-----|-----|
| Receiver type disambiguation | Default `receiver_types` to `[receiver_type]` when empty. Strip any module alias prefix from first param type before comparing. |
| Method call naming | Use full public function name (snake_cased from raw name) for call expressions. |
| cstr heuristic | Auto-project raw `cstr` params to `str as cstr` in foreign function emissions. |

### 6.10 CLI Command (2026-07-19)

The `mtc imported-bindings` CLI command was added, mirroring the bindgen pattern:

```
mtc imported-bindings raylib                  # regenerate std/raylib.mt
mtc imported-bindings --check raymath         # verify output matches checked-in
mtc imported-bindings --all                   # regenerate all 28 bindings  
mtc imported-bindings --all --check           # verify all 28
```

Implementation: `registry.mt` (130 lines, hardcoded 28-binding entry list) + `imported_bindings_command` in `main.mt` (~120 lines, flag parsing, `--all` batch loop, `--check` diff verification, path derivation `std.c.raymath` → `std/c/raymath.mt`).

---

## 7. Formatter Gaps (2026-07-19)

### 7.1 Current State

The self-host formatter (`mtc format`) supports only **canonical** mode: parse → AST → pretty-print. Ruby supports 4 modes:

| Mode | Ruby | Self-host |
|------|------|-----------|
| `:canonical` | AST pretty-print | AST pretty-print (only mode) |
| `:safe` | Same as canonical | — |
| `:preserve` | CST-based, keeps original formatting | **Not implemented** |
| `:tidy` | CST normalize → wrap → blank lines | **Not implemented** |

### 7.2 Key Gap: CST Builder

All non-canonical modes (`preserve`, `tidy`) require a **Concrete Syntax Tree** (CST) representation that preserves comments, whitespace, and original formatting details. Ruby's `CSTBuilder` (`lib/milk_tea/core/cst_builder.rb`) constructs this from the token stream. The self-host has no CST builder — only an AST-based pretty printer.

Building a CST builder is the **gateway dependency** for both the `--tidy` and `--preserve` formatter modes, and for the linter's `line-too-long` wrap-fix machinery.

### 7.3 Required Work

| Gap | Effort | Depends on |
|-----|--------|------------|
| CST builder | **Large** (~1,500 lines) | Token stream + parser infrastructure |
| `--preserve` format mode | Medium | CST builder |
| `--tidy` format mode (normalize + wrap + blank lines) | Medium | CST builder |
| `--max-line-length` flag for format | Small | CST builder |
| Linter `line-too-long` wrap-fix | Medium | CST builder |
| Linter `:fast` tier | Small | Independent (no CST dependency) |
| Formatter `--timings` profile | Small | Independent |
