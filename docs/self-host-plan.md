# Self-Host Plan

Single planning document for the Milk Tea self-host (`projects/mtc`, branch
`selfhost`).  The Ruby host (`ruby -Ilib bin/mtc`) is the reference; "parity"
means byte-identical where a harness can compare, "better" means a documented
deliberate extension.  The goal is a self-host that matches the host everywhere,
or is documented as deliberately better.

**Start here:** read *Status at a glance*, *Handoff*, *How to start a work
session*, and *The program* (the tracks and their stopping rules).  The Ledger
carries the last verified number per gate.  The pre-compaction version of this
file — with the full session-by-session records (§0a–§0k, §1–§7) — is at commit
`d8a199c7`; use `git show d8a199c7:docs/self-host-plan.md` when you need the
history.

## Contents

- [Status at a glance](#status-at-a-glance-session-71-2026-11-13)
- [Handoff](#handoff-session-71)
- [How to start a work session](#how-to-start-a-work-session)
- [The program — tracks and stopping rules (all closed)](#the-program--tracks-and-stopping-rules-all-closed)
- [Deliberate differences (do not chase)](#deliberate-differences-do-not-chase)
- [Ledger](#ledger)
- [Porting notes](#porting-notes)
- [Risks and notes](#risks-and-notes)
- [Provenance](#provenance)

## Status at a glance (session 72, 2026-11-13)

| Area | State |
| --- | --- |
| Bootstrap fixed point | **holds** (`stage2.c == stage3.c`); self-test suite **22 files / 0 failed** |
| `test/mt` | **60 files / 0 failed** (session 72 on stage2) |
| Examples | **13/13** synchronous top-level examples build with stdout+exit identical to the host; the two `async_*` examples hit the host's own loop guard at rc 134 on both compilers (documented CPS-resume limit); `examples/sdl3` **34/34** builds; the raylib sample builds |
| `sexpr lex` / `parse` | 0 differ (lex **739/739**; parse **735 match / 0 differ / 4 host-rejected of 739**; counts drift with the tree and `tmp` fixtures) |
| `sexpr lower` | **683 match / 3 differ / 53 host-rejected / 0 self-rejected of 739 files** (session 72; the baseline tree measures the same 683/3/53/0, so the session-71 "684/2" count was stale — `examples/sdl3/demo/woodeneye.mt` was already differing and is now counted).  The three differ are `memory_stress_test` (leaked auto-lifetime), `main.mt` (`--sexpr` loop guard) and `woodeneye` (a pre-existing double-literal rendering difference in `std/math` constants, present before this session's changes) |
| `cli:parity` | **92 match / 0 differ / 0 pending** of 92 cases (`--timings` values and `debug`'s Ruby node ids are normalized) |
| **`check` diagnostics (new)** | **501 agree / 0 verdict / 0 position / 3 message of 504** files (`tools/diag_parity.rb check`; the 3 message rows are the documented `std/cli.mt` ×2 and `examples/reflection_advanced.mt` rows).  Before this session: 44 verdict, 177 position diffs and a wholly different rendering. |
| Linter corpus | **632 agree / 3 differ** of 635 (hostfail 0, selffail 0); **43/43 rules, 13/13 fixers**.  The 3 residual rows are documented self-better/host-artifact rows. |
| LSP | harness **30/30 capability keys + 4 documented entries**; project audit canonical **6** differing entries (4 documented rows + 2 builtin-hover warm artifacts), non-canonical 4–5 with ±drift; recovery **6/6**; `milkTea/debugInfo` **byte-equal**; valgrind **0 errors**; edit latency **4.9 ms median**; soak **74–75 KB/cycle raw / ~28 LS at 200 cycles** (meter, one-time index level documented) |
| DAP | **zero differing rows** on the `dap_smoke` matrix, except the documented self-better `lldb-real frame0 name`; the real lldb-dap bridge closes the VS Code F5 launch deadlock (configurationDone no longer waits for the launch response), proven by `tools/dap_async_probe.rb` |
| Formatter | **739/739** byte-identical in all three modes (`:canonical`, `:preserve`, `:tidy`; counts drift) |
| Imported bindings | **29/29 verified** against the host generator and the checked-in modules (re-verified session 72) |
| Bindgen reproducibility | **33 match / 0 differ / 0 error / 1 custom of 34 registry bindings** (re-verified session 72).  The one custom entry is `tracy`, whose host registry generator returns the hand-written checked-in `std/c/tracy.mt` verbatim. |

Rough completion against the per-track Definition of Done: **100%**.  The
self-hosting foundation, `lower` dump parity, the CLI behavior matrix, wasm,
docs, the linter corpus, the imported bindings and bindgen reproducibility are
done, and session 72 added the analyzer/`check` surface that no gate had
measured.  The only residuals are the documented `tracy` custom-generator
entry, the optional desktop F5 smoke, and the optional Track G throughput work.

## Session 72 — the `check`/analyzer surface

`check` is the only command that reports the semantic analyzer's verdict, and no
gate compared it: `sexpr_parity` only compares files both compilers *accept*
(its `hostfail` bucket hides every accept/reject disagreement) and
`cli_parity`'s `check` fixtures abort at `unknown callable print` before any
diagnostic renders.  Session 72 measured that surface and closed it.

New harnesses (keep both; they are the only measurement of this class):

- **`tools/diag_parity.rb [parse|check] [TARGET...]`** — compares the diagnostic
  *verdict* (does the file check?), the `code: message` set, and the positions,
  independent of rendering.  Retries a host killed by a signal (parallel Ruby
  hosts are OOM casualties, not disagreements).  Live: `check` **0 verdict / 0
  position / 3 message of 504**; `parse` **0 differing of 504**.
- **`tools/check_parity.rb [TARGET...]`** — byte-for-byte `stdout`/`stderr`/exit
  of `check`, for the rendering half.

The gaps it found, and their fixes:

1. **Constant-value coercion (the plan's last open analyzer item).**  The host's
   `exact_compile_time_numeric_compatibility?` folds an expression's integer
   value and accepts it when the value fits the numeric target's range; the self
   accepted *every* numeric literal regardless of value and rejected named
   constants.  `semantic/type_compatibility.mt` gained `fold_int_constant`
   (literals, named consts, unary `-`/`~`, integer arithmetic/bitwise) and
   `constant_fits_target` (tri-state: fits / does-not-fit / not-static), and
   `semantic/types.mt` gained `integer_constant_fits` (the host's
   `value_fits_integer_type?`, `char` in `0..255`).  The rule is applied at
   return, assignment and local-initializer sites through
   `incompatible_value_with_consts`; a binary operator is *not* folded (the host
   types its literal operands with the expected type instead).
   `infer_expr_inner` now lets a bare integer literal adopt a fitting expected
   integer type (the host's `infer_integer_literal`; `char` excluded, so
   `let nl: char = 10` still lowers `char<-10`), and `infer_binary` propagates
   the numeric expected type into both operands.  Result: `return 300` into
   `ubyte` is rejected, `return 200` and `const C: uint = 200; return C` are
   accepted, `300 + 0` is rejected while `200 + 56` is accepted — all equal to
   the host.  A type that already equals the target short-circuits the range
   test, so a `ulong` literal the parser stores as a negative `long`
   (`14695981039346656037`) keeps its declared type.
2. **`check` rendered lint results through the `lint` one-liner on stdout.**  The
   host funnels every `check` diagnostic through `ErrorFormatter` — a full block
   on **stderr**, sorted by `[line, column]` — and buckets severities
   (`39 warnings; 59 notes`), printing the separator blank line but no count
   line for a hint-only file.  `main.mt` gained
   `print_severity_diagnostic_block`, `sort_lint_warnings_by_location` and a
   three-counter summary; a positionless diagnostic renders the bare message
   (the host's `ErrorFormatter` fallback for a node with no line), and a
   whole-file load failure renders `<message>: <path>`.
3. **The platform guard was missing from the loader.**  The host's
   `resolve_source_path` raises when a file pinned to one platform
   (`std/fs.windows.mt`) is loaded for another; the self analyzed and linted it.
   `loader/module_loader.mt` now returns a one-diagnostic program
   (`empty_program_with_diagnostics`), which `check` renders byte-identically.
4. **The `checked <path> as <module>` line** was verbose-gated and only fired on
   a clean analysis; the host prints it unless `--quiet`, for a file that
   produced *no* diagnostics of any severity (its `elsif module_name` arm), with
   the operand spelled as passed.  `lint` results also now use the absolute
   path (`File.expand_path`), matching the host's `resolved_path`.
5. **`prefer-try` anchored at column 0** instead of the scrutinee's column
   (`linter/linter.mt`).

Verification: bootstrap fixed point, 22/0 self-tests, `test/mt` 60/0, lower
683/3/53/0 (identical to the pre-session baseline), lex 739/739, parse
735/0/4, `cli:parity` 92/92, lint corpus 501/3 of 504 on `std`+`examples`
(the documented rows).

## Handoff (session 71)

The parity program is complete: every track is at its documented stopping
point and the Track H matrix passed on the frozen tree.  The session-71 commit
carries the bindgen reproducibility port (with `tools/bindgen_parity.rb`), the
bare `build`/`run` package-root fix (CLI 89 -> 92 cases), and the DAP
`configurationDone`/launch ordering fix (with `tools/dap_async_probe.rb`).

To re-verify a change: build the dev compiler
(`ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev`), run
`tmp/mtc-dev test projects/mtc -I . --timeout 120`, and measure only the class
the change can move with the matching harness; run `tools/gates.sh` (or
`tools/bootstrap.sh -j 16 --fast` for the fixed point) once on frozen sources.
Do not replay the whole matrix for a docs-only change.

What is deliberately not done:
- a desktop VS Code F5 click-through — the protocol path is covered by
  `tools/dap_async_probe.rb` against the real `lldb-dap`; the headless UI drive
  reproduced the pre-fix timeout and the fix is verified at the wire level;
- Track G compiler throughput (3.9x self-to-host, behavior-neutral, optional);
- the documented differences and the lower/linter residue rows
  (*Deliberate differences* — do not chase).

Session-69 batch (Track C closed at its documented residue; lint 571/63 ->
631/3): seven rule families plus two analyzer facts fields closed the whole
per-rule residue.  The linter now mirrors the host's **CFG reachability** for
`loop-single-iteration` (`Builder#build_loop_body`: the fall-through/`continue`
target must be unreachable) and `unreachable-code` (nodes unreachable from the
entry, anchored at their statement's own span, including `if`/`match` nodes),
and its **`Termination.block_always_terminates?`** for `prefer-let-else`/`var-else`
(a fresh branch graph).  `prefer-let-else` anchors at the `if` line with the
host's source condition span, skips `_`-prefixed names, and `prefer-var-else`
requires the innermost scope's binding to be mutated.  `prefer-or-pattern`
skips identity-shared bodies (expanded `A | B` alternatives) and compares a full
`node_fingerprint`-equivalent structural equality (locals, if/while/for/match,
when, defer, casts, specializations, format strings, proc bodies, type refs).
`constant-condition` gained the CFG's mutating-argument writes (analyzer
`mutating_argument_sites` -> `Cfg.mutating_sites`; the span is owned by
`lint_body_rules`), local-initializer write collection (`ptr_of`/`ref_of`), and
the host's float-literal harmonization/re-recording in `infer_binary`
(`double<-x * 1000.0` types `1000.0` as `double`).  `redundant-cast` treats
`ptr_int`/`ptr_uint` as pointer-width fixed-width integers (host
`Primitive#fixed_width_integer?`).  `prefer-let` now marks the host's
`mutable_lvalue_argument_identifier_ids` (array/`str_buffer` -> `span`
arguments; new `Analysis.mutable_lvalue_sites` threaded into the linter).
`prefer-struct-with` equates `ty_named`/`ty_imported` by qualified name, and
`prefer-conditional-expression`/`prefer-try`/`prefer-or-pattern` emit in the
host's match order.  The two rules the corpus never triggered are ported in the
same session: **`directional-ffi-arg`** (the analyzer records `in`/`out`/`inout`
foreign/extern parameters per function and exports them through `ModuleBinding`;
call checks record a site when an argument re-states the direction via
`in/out/inout x`, `ptr_of(x)`/`ref_of(x)`, or a pointer-like cast of an lvalue,
and the linter emits it at the call's visit with the host's message) and
**`platform-api-drift`** (`linter/platform_drift.mt`: platform-variant sibling
discovery, a full exported-surface renderer for every declaration kind, the
host's anchor ladder and `missing`/`extra` summary text; verified
message-for-message against the host linter on scratch `.linux`/`.windows`
fixture pairs).  Gates: lint 632/3 of 635 (the 3 documented below), dev
self-tests 22/0, `test/mt` 60/0, lower 683/2/53/0 unchanged, bootstrap fixed
point holds.

Session-70 bindgen batch (Track D item 3 closed): `tools/bindgen_parity.rb`
drives every registry binding through the host library and the self CLI with the
same raw-binding option table (the self-only `--options-json` flag); the result
is **33 match / 0 differ / 0 error / 1 custom of 34** (from 11/36).  The port
was restructured onto the host's two-phase architecture rather than patched:
`extract_top_level_nodes` keeps the host's node indices (direct declarations
plus typedef-owned tags, deduped by AST id), `index_referenceable_records`
walks the whole AST for `struct`/`union` definitions (complete preferred),
`build_alias_maps` records typedef→record/enum ids *and* the by-tag fallback,
and the selection passes mirror `declaration.rb`: records (opaque upgraded by
a later complete definition), typedef→record resolution through the
referenceable index, enum kinds, type aliases (function-pointer typedefs map
through `FunctionProtoType`), qualified-constant `VarDecl`s (the host's
`constant_var_decl?`, `constant_qual_type`, aggregate/array init lists), and
functions (first declaration wins, per-declaration error skip, variadic).
Emission follows `emitter.rb`: synthetics first (in discovery order), then all
declarations sorted by node index; opaque records carry the host's
`record_c_name` linkage; anonymous/nested aggregates flatten their unnamed
members and synthesize `Owner_field` records; field types go through
`aggregate_field_type` with field overrides keyed by the owner name; enums
choose `flags` from the power-of-two test.  Type mapping now ports
`type_mapper.rb`: top-level nullability (`?`), array/function-pointer parsing
(including `void (**)(...)` and function-pointer-returning-function-pointer),
`cstr`/`va_list`/`__va_list_tag`, `size_t`/`__uint32_t`-style primitives,
type/tag overrides, typedef-name preservation (`map_type_node`), and
unknown-type rejection (a function/typedef that cannot map is skipped exactly
where the host rescues `BindgenError`).  Supporting fixes: the TU prelude now
matches the host's order (defines, header, then `bindgen_include_directives` —
`SDL_main.h`-style headers changed the AST order), both clang invocations pass
`-fno-builtin` (without it clang synthesizes unnamed builtin redeclarations),
the macro scan uses the host's header-only provenance (the generated TU's own
`#define`s are not constants), the clang AST JSON is viewed without
`str.as_str()` UTF-8 validation (the host parses it unvalidated; the scan hit
the C backend's debug loop guard on the multi-hundred-MB SDL3 AST), and
`heap.copy_bytes` now calls `memcpy` instead of a byte loop.  Tracy is
classified `custom`: its host registry generator returns the checked-in
hand-written module verbatim, so there is no generic reference; the parity
tool exits non-zero only on a real differ or error.  Gates on the frozen tree:
bootstrap fixed point holds with 22/0, `test/mt` 60/0, examples 49/49, lex
739/739, parse 735/0/4 of 739, lower 684/2/53/0 of 739 (the two documented
artifacts), cli 89/89, lint 632/3 of 635, imported bindings 29/29, bindgen
33/34 + 1 custom, and the changed files 4/4 in all formatter modes.  The
`--nullable-policy` probe still renders byte-identical output and report (the
policy merges into the same override maps the host CLI uses).

Session-71 batch (Track H final matrix; CLI 89->92, DAP F5 launch fix):
- **Bare `build`/`run` package-root discovery.**  The dispatcher's `args.len < 2`
  guard blocked `parse_source_operand`'s existing discovery, so `mtc build` in a
  package root printed "missing source file path" while the host built it.  The
  guard is gone for `build`/`run` (a non-package root still errors identically)
  and `cli_parity` gained `build-no-operand-package`,
  `build-no-operand-no-package` and `run-no-operand-bare-package`: **92/92**.
- **DAP launch ordering (VS Code F5).**  `configurationDone` was deferred
  whenever the launch request was in flight, even after the adapter's
  `initialized` event; lldb-dap answers `launch` only once the target starts, so
  the session deadlocked until the 5 s adapter deadline and VS Code tore it down
  with "backend request timed out: launch".  The gate now mirrors the host's
  `backend_configuration_pending?` (`start_pending` and not `config_ready`), and
  a deferred `configurationDone` is released when the adapter becomes ready
  (and when the launch has been sent).  `tools/dap_async_probe.rb` (launch,
  then configurationDone without waiting) proves against the real lldb-dap:
  launch success -> entry stop -> breakpoint stop -> frame `main` -> locals
  `x=3` -> evaluate `3`; `dap_smoke` stays at zero differing rows (the
  documented frame0 row).
- `bindgen --options-json`'s non-object error path now releases the parsed value
  and root (a leak on the self-only options path).
- **Full matrix on the frozen tree:** bootstrap fixed point + 22/0, `test/mt`
  60/0, examples 49/49, lex 739/739, parse 735/0/4, lower 684/2/53/0, cli 92/92,
  lint 632/3, unused-import 635/635, formatter 739/739 (and the changed files in
  all three modes), imported bindings 29/29, bindgen 33/34 + 1 custom, LSP
  harness 4 documented entries + recovery 6/6 + canonical audit 6 + valgrind 0
  + Neovim, DAP zero differing rows, wasm/docs smoke, and SimpleGame built and
  run identically by host and self.  Ledger re-stamped to session 71.

Session-68 batch (Track B closed; CLI parity 89/89): the `deps` subsystem is
ported into `projects/mtc/src/mtc/packages/` (`version`, `paths`, `manifest`,
`editor`, `solver`, `graph`, `lock`, `source`, `registry`, `manager_cli`) and
wired as `mtc deps add|remove|update|tree|lock|publish|fetch`; `--locked` and
`--frozen` now load the locked (or live) package graph and join its source roots
to module resolution in `build`, `run` and `debug`.  Verified on a shared
fixture: `package.lock` renders byte-identically (schema 2, SHA-256 instance
ids), and `tree`/`fetch`/`add`/`update`/`publish` output, the registry
`.tar.gz`/`versions.txt` artifacts and the allocation of `__mt_fmt_*`/proc temp
names match the host.  Three lowering gaps the port exposed are fixed: a
dotted imported type reference now follows a re-exported type alias
(`aio.Runtime` -> `std.async.libuv_runtime.Runtime`) in
`resolve_generic_type_ref`/`resolve_field_type_ref`, and the async statement
paths reproduce the host's two asymmetries (no format-sink streaming and no
prepared-expression cleanups; cstr temp frees still emit).  New in-language
tests: `projects/mtc/test/packages_test.mt`, `package_version_test.mt`
(22 self-test files, 0 failed).  Gates: fixed point holds, `test/mt` 60/0,
`cli:parity` 89/89, lower 683/2/53/0 of 738, lex 738/738, parse 734/0/4.

Session-65 batches (measurement truth + CLI forms): `cli_parity`
replaced the ten `KNOWN_GAPS` regexes with case-backed `pending:` metadata (nine
of the ten patterns had no case); the matrix is now **89 cases / 78 match / 0
differ / 11 pending**, and a pending case that starts matching is a failure.
The second session-65 batch closed the multi-operand/directory forms:
`parse`/`emit-c` PATH|DIR expansion with headers, `format` directories and
multiple sources plus the `requires --check or --write` rule, and the host's
`check`/`lint` unknown-flag validation, and `lint --init` (with the 43-code
rule registry).  Remaining pending: `deps`, wasm, `toolchain doctor`,
locked/frozen build, bundle/archive run.  Bootstrap at the end of the batch
reached a fixed point (`stage2.c == stage3.c`), the dev suite was 19/0, and
stage2's `test/mt` was 60/0.
`lint_parity` gained `hostfail`/`selffail` buckets and a SHA-256 host-source
cache key (mtime invalidation could reuse stale output after a checkout); the
full corpus re-read is **618 files / 496 agree / 122 differ / hostfail 0 /
selffail 0** (the earlier 495/121 figures were stale).
`dap_smoke` now exits non-zero on an unlisted differing row, requires a real
`lldb-dap` (versioned `lldb-dap-<N>` names are discovered; `--allow-skip` opts
out), and reported `differing rows: none` over the full drive. `gates.sh` labels
were corrected and areas added for `packages`, `docs_cli`, `wasm`, `toolchain`
and `tools`. Baseline re-confirmed: `cli_parity` 65/65 on the original matrix,
bindings 3/25 of 28.

Session-66 batch (Track D closed): the imported-bindings emitter now matches the
host generator byte-for-byte on all 29 bindings (`box3d` added; type aliases,
overrides, bare-alias resolution, function-type handle projection, method
wrappers built from generated entries, tidy formatting).  The self-only command
gained `--stdout`/`--json`; `tools/imported_bindings_parity.rb` reports
29 verified / 0 changed, and both bindings gates are hard.  The host's 37
OpenGL naming vectors are pinned in
`projects/mtc/test/imported_bindings_naming_test.mt` (self suite 20/0).
Bindgen reproducibility (Track D item 3) remains open and is deferred behind
the linter/analyzer track.

The same session's analyzer batches closed the reserved-name diagnostics
(module consts/vars/functions/events, params/locals, host message and
positions), the qualified return-mismatch rendering with the host's statement
fallback for position-less literal returns, null assignability, immutable
parameters, the member-assignment immutability ladder, and specialized
editable-call recording.  The fix engine now follows the host's rule order and
pass structure, refuses fixes on unresolved imports, validates the candidate
parse, re-analyzes against the loader-backed imports, and generates the
`redundant-unsafe` fix (13/13 fixers).  Lint corpus: 495 agree / 123 differ of
618, with `borrow-and-mutate` 29 and `loop-single-iteration` 8 (both improved);
`prefer-own-ptr`'s candidate set now matches the host (20 self-only
use-accounting rows remain), and the redundant-cast comparison sibling and
editable-site matching were tightened.

Session-67 batch (CLI Track B, doctor): `toolchain doctor` now reproduces the
host's 60-row report byte-for-byte (`Checking system tools...` +
`Checking vendored libraries...` + `Checking bindings...`, the 8 tool rows with
`$CC/$AR/$CLANG/$CMAKE` overrides, the 18 vendored sentinels with the
`config/upstream_versions.yml` overrides, and the 34 `std.c.*` raw-binding
header rows sorted by name, including the `skipped (missing C compiler)` and
header-not-found messages). The self-only 34-row header projection lives in
`projects/mtc/src/mtc/toolchain_bindings.mt`; the option maps stay in the
host bindgen table for Track D.  Fixed `is_executable` to use the stat-based
`fs.is_file` (`fs.metadata` is lstat-based, so symlinked tools such as
`/usr/bin/cc` and `/usr/bin/clang` were reported missing).  `cli:parity` is
now **82 match / 0 differ / 7 pending** of 89; the pending set is `deps`
(5 cases) and locked/frozen build (2).

The same session-67 batch closed `run --bundle` and `run --archive`: `run` now
parses both flags, loads the package manifest for the bundle root/assets/entry
name (using the manifest's profile/platform defaults when the CLI does not
override them), shares the host's `build/dist/<platform>/<profile>/<name>`
layout through `resolve_bundle_paths`, and re-stages assets plus the
`<bundle_root>.tar.gz` on a successful build or cache hit via
`stage_run_bundle`.  The entry executable is run from the bundle; build output
stays silent exactly as the host's `Run` path.  `cli:parity` is **82 match /
0 differ / 7 pending**.

The wasm build half of Track B item 1 closed in the same batch: the build driver
now takes the target platform, embeds the host's 48-line shell template plus its
canvas/output/bootstrap fragments (`projects/mtc/src/mtc/wasm_shell.mt`,
generated from the host constants), resolves `$EMCC`/`emcc`, renders a custom
`[build] html_template` with the host's exactly-once placeholder validation,
passes `--shell-file -sINCOMING_MODULE_JS_API=canvas,print,printErr`, preloads
each `build.assets` entry, normalizes `.html` output paths, cleans stale emcc
sidecars, and emits the host's debug-map sidecar.  `--keep-c` now saves the
host's non-debug/non-guard rendering (not the compiled debug source), and the C
backend no longer emits a separator when every imported constant is pruned
(which was one blank line in `emit-c`/saved-C output).  On the scratch package,
host and self wasm builds produce byte-identical C, `.data`, and the same
`.html/.js/.wasm/.mtdbg.json` set.

The preview server half of item 1 closed in the same session:
`projects/mtc/src/mtc/wasm_preview.mt` serves the output directory on an
ephemeral 127.0.0.1 port with the host's MIME table and headers
(`Cache-Control: no-cache`, COOP/COEP, `Connection: close`), GET/HEAD, 404/405,
default-entry selection, a canonicalising traversal guard, the
`serving <url> (press Ctrl-C to stop)` banner, and `xdg-open`/`cmd /c start`.
SIGINT/SIGTERM are libuv signal handles that close the listener; the outer
accept loop is a sync `wait_on`/`run_on_proc` driver (one coroutine per request)
because a CPS `while` across repeated awaits could spin after the first
connection.  `run --platform wasm` now builds to the package/source
`build/bin/wasm/<profile>/<name>.html` (not a temp path) and starts the preview.
The compiler fix behind this: `Task[void]` structs now carry the
`take_result` function-pointer field the runtime calls, and `std.async` gained
`run_on_proc`.  `tools/wasm_smoke.rb` drives host and self through a real
preview session (entry/JS/WASM/HEAD/404/405/SIGTERM) and is the hard
`wasm_smoke` gate.

The `docs` command closed in the same session: `docs_app.mt` serves the
reference index (`/`, `/reference/`, `/reference` 302), the stdlib catalog
(`/stdlib`, `/stdlib/:name`), raw source and node-highlighted source
(`/stdlib/:name/source/:file[/hl]`), JSON search (`/api/search?q=`), the copied
CSS/JS assets, and a 404 page.  It reuses the shared `http_util` response/signal
helpers, discovers modules/doc comments/declarations from `std/`, and runs the
copy of the VS Code snapshot script with the 2026-dark theme.  `docs` parses
`--port/-p`/`--open/-o`, prints `Serving Milk Tea docs at <url>` +
`Press Ctrl+C to stop.`, and handles SIGINT.  `tools/docs_smoke.rb` compares
host and self route statuses/content types and the byte-stable reference,
source, highlight, CSS and JS bodies, and is the hard `docs_smoke` gate.

The first Track C batch in the same session closed `borrow-and-mutate`
(29 self-only rows): the collector now applies the host's
`inside_call_argument` gate (a `ref_of`/`ptr_of` that is itself a call argument
is ignored), records the first borrow site's line/column/length instead of
anchoring every warning at line 1, and mirrors the host's expression set.
`loop-single-iteration` now uses the host's message text on both loop kinds and
recurses into `when`/`defer` bodies (the `while true` exemption stays until the
CFG termination port).  The new docs/preview files were made lint-clean
(`prefer-let-else` in `http_util`, `?` validation in `wasm_shell`), and the dead
`is_package` local in `build_command` was removed (host-only `unused-local`).
Lint corpus: **510 agree / 114 differ of 624**, hostfail 0, selffail 0.

Session-51 batch: the event synthetic bodies (host slot/snapshot shapes), the
reused await-field recording plus nested-await hoisting in a direct-await
local, multi-digit `int_to_str`, the binary operands' conditional peer-type
propagation, and `ir_expr_type`'s unsigned-literal arm.  Flipped
`event_stress_test`, `build_cache`, `imported_bindings/{main,methods}`,
`lsp/{debug_info,server}` and one example.

Session-52 batch: await-free nested async bodies lower as plain locals (with
the analysis' frame fields pre-registered and no line/path on the decl), the
AST CFG decides the async fall-through cleanup, CPS whiles drop the sync
scoping block, guard locals spill their storage as a member-expression target,
`or` short-circuits swap their branch bodies, range bounds take the common
integer type, async local literals take the declared type, the fresh-temp
counter resets per async function, and raw-module forward-declarable opaques +
builtin-generic receiver names (`ptr_receiver_arg0_…`) match the host.
Flipped `std/net/{packet,punch}`, `std/tracy`, `std/raylib/tracy_gpu`,
`std/simd`, `tracy_profiler` and three `projects/mtc` files.

Session-53 batch: module-constant string arguments are cstr-backed (a direct
`.data` cast at a `str as cstr` boundary), and a statement-position foreign
call with a `consuming` parameter nulls the bare nullable binding afterwards
(a guard-bound storage included) with a null flow refinement.  Flipped
`raylib/{core/storage_values,core/text_file_loading,text/font_sdf,text/strings_management}`.

Session-54 batch: a nested foreign call with cstr temps materializes
`__mt_foreign_result_N` inside a discarded-statement window too, a raw-module
receiver's monomorphized method links bare (`Image_draw_pixel`), a pointer
offset literal takes the host's default `int` (a `0z` suffix is ignored) and a
nullable pointer projects to a plain pointer foreign boundary as a cast.
Flipped `raylib/{core/automation_events,audio/spectrum_visualizer,
textures/image_processing}` and three more raylib/SDL examples.

Session-55 batch: proc closure structs ride the non-dumped
`Program.monomorphized_structs` (the host's C backend collects them), a
same-module type alias resolves in union fields, a pure integer constant enum
member value takes the backing type (`1 << 0` in a `flags` block), a bitwise
binary with missing analyzer type falls back to its equal operands' type, and
`get()` lowers to `IR::NullableIndex`/`IR::NullableSpanIndex` (NULL on
out-of-bounds; the backend emits the host's nullable helper names). An async
`if` expression with awaits in its branches hoists like the host's
normalization: the result temp registers before the branch temps, numbered
after them. Flipped `engine/{types,systems,guards}`.

Session-56 batch: a `ty_named` enum resolves its backing against its own
`module_name` (raw `std.c.*` enums cast to `int` in comparisons), a char
literal is a compile-time numeric constant (a `uint` assignment casts it), a
comparison's IR type is always `bool`, a float binary peer contextualizes an
`if`-expression operand (`(if c: W else: H) / sqrtf(x)` casts each branch), the
generated range/collection/iterator loops use the host's native
`ContinueStmt`/`BreakStmt` (labels remain for defer flushes and switch arms),
and a rebuilt foreign-mapping binary/unary keeps the analyzer's recorded type.
Flipped `sdl3/{pen/drawing_lines,renderer/read_pixels,renderer/affine_textures,
asyncio/load_bitmaps,demo/infinite_monkeys}` and `raylib/others/rlgl_standalone`.

Session-57 batch: a plain expression constant takes the host's
`lower_compile_time_literal` path (typed, not width-masked: `~268435455` stays
`-268435456` in a `uint`), a `char` array-constructor element casts its integer
literal (`array[char, 512](0, …)`), and an *inferred* generic function instance
joins its type arguments with single underscores after one double underscore
(`find_state_hooks__World_Context`, not `__World__Context`).  Flipped
`test/mt/{fsm,goap,htn}_test`.

Session-58 batch: function placement reproduces the host's `lower_modules`
setup pass + `lower_functions` fixpoint — a specialization is emitted at its
owner declaration's next visit, gated on the function that created it, with
analyzer-pre-instantiated bindings available from the setup pass (the `wait`
chain is lowering-created and waves correctly; the `completed`/`Result` keys
render via the host's qualified `to_s`).  A `?` operand gets its own prepared
window so a proc argument materializes before `__mt_propagate_N`; the async
constructor always carries `take_result` (void included); async non-await
`if`s emit `nil` for an empty else; async `unsafe` bodies splice; the release
and cancel vtable functions free pointer-lowered params; a discarded void
await still calls `take_result`; a literal return with defers completes after
the cleanups; and the async-main root proc's invoke carries the source path.
Flipped `examples/async_stress_test` and `std/net/{channel,clock,manager,mux,
session,sync}`, plus `std/tls`.  Lower and the self-test suites were re-run
(19/0, 60/0).

Session-58 second batch: a match scrutinee is lowered exactly once (the
recorded type is only a fallback) inside the statement's prepared window, so a
proc argument materializes before `__mt_match_value_N` and the cleanups follow
the match; a signed float literal (`-1.0`) takes a `float`/`double` context
through its unary at binary, call-argument and return sites; and
`expect_eq`/`expect_ne` type each operand against the other like a normal
binary.  Flipped `test/mt/{vec,math}_test` and
`projects/mtc/test/tidy_formatter_test` (19/0 and 60/0 re-run).

Session-59 batch: async scalar/enum match cases append the CPS break
(`std/http`, `std/oauth2`); a guard local in a no-await async body carries no
line/path (`std/net/lobby`); async local/assignment initializers materialize
array calls (`__mt_array_call_N`) and the `?`-operand prepared windows precede
`__mt_propagate_N` (`std/net/{discovery,nat,stun,turn}`,
`examples/async_network_lobby`).  Cross-module async calls are Task-wrapped for
every return type (the analyzer's imported binding type).  Plain local reads and
assignment targets carry the flow-refined visible type (sdl3 gamepad/joystick,
the `raw_fields` family).  Inline-for binds its loop variable as a comptime
constant (no local) and folds constant branch conditions; `emit` declarations
lower a second time into the emitted tail; an ordinary const-function call stays
a runtime call and a non-constant argument no longer folds to 0
(`examples/{comptime,reflection_advanced}`, `test/mt/reflect_test`).  The
analyzer types vec/mat/quat members and Simd arithmetic, SoA fields type as
`array[T, N]`, and an unannotated local keeps the recorded simd/vec aggregate
over its scalar binary node (`projects/stress/src/engine/math`,
`examples/simd_features` advances to the `SimdLaneWith` IR node).  A no-await
async body registers its frame fields in the host analysis' normalized order
(an `and`/`or` temp before the branch locals), which flipped `std/net/rpc`.
Flipped 15 files; ledger `sexpr lower` 630/36/51/0 of 717 (from 615/51); 19/0
and 60/0 re-run.

Session-60 verification at the committed tree: full bootstrap (fixed point plus
19/0), `test/mt` 60/0, `sexpr lower` 630/36/51/0, lex 717/717 and parse
713 match / 0 differ / 4 host-rejected.  No code changes; the plan header and
Ledger were re-stamped, and the ranked Track A leaders stand as below.

Session-61 batch: the async normalizer's two-phase `and`/`or` shape (both operands
lowered into child windows, the result temp allocated after them but its frame
field registered at the pre-recursion slot and its declaration emitted first), the
CPS while restructure for await-free `and`/`or` conditions (with the extra
`cond_name` bool temp and a native break guard), direct-await guard locals taking
the awaited result straight into the guard's frame field (no temp field), and the
if-expression branch assignments using the textual frame `Name` (await stores keep
`Member`).  `std/http/server`, `projects/stress/src/main` and
`engine/async_tasks` now match through their async frames; their first differences
moved to the async-main proc env bridge / proc-helper placement and the tuple
struct name.  `std/net/rpc` stays matching.  Gates: fixed point holds, `test/mt`
60/0, lower 630/36/51/0 (unchanged count, deeper first diffs), examples 49/0.

Session-61 second batch: named tuple struct names follow `Types::Tuple#to_s`
(`(x: int, y: int)`); a static-assert message lowers as StringView while the C
backend still emits a bare C string for a literal; proc calls through struct
fields and array elements take the proc's return type (void/error/proc records
fall back to the closure signature); a qualified imported enum member resolves
in an inline-match scrutinee/pattern; a user generic variant instance classifies
as `Types::VariantInstance`; and a capturing proc's release frees captured proc
fields before the env.  Flipped `projects/stress/src/engine/{compile,closures}.mt`;
lower **632 match / 34 differ / 51 host-rejected / 0 self-rejected of 717**
(from 630/36; the set diff shows no newly differing files).  Gates: fixed point
holds, `test/mt` 60/0, examples 49/0, dev self-tests 19/0.

Session-61 third batch: a generic struct receiver in `concrete_field_type` is
monomorphized before the field lookup, and the proc retain/release walks use the
concrete instance's substituted fields (`proc_struct_fields`) instead of the
declared `analyzer.structs` entry, so `PipelineStep[int].handler` carries
`proc(input: int)`.  `stress/main` advances from that field type to event
function ordering; count unchanged at 632/34/51/0, gates as above.

Session-61 fourth batch: event runtime functions and dyn wrappers join the
program-wide synthetic function tail in creation order (the host's single
`@artifacts.synthetic_functions` list); a multi-iterable `for` mirrors the host's
parallel collection-for (per-iterable `__mt_for_items_N`, the matching-length
fatal check, and a block-wrapped `__mt_for_index_N` loop); proc-call arguments
and `.with(...)` replacements take the target parameter/field literal type; and
a proc literal in a CPS local initializer uses a prepared window, so no
`__proc_N__setup_env` synthetic function is emitted.  Flipped
`projects/stress/src/engine/async_tasks.mt` and `projects/stress/src/main.mt`;
lower **634 match / 32 differ / 51 host-rejected / 0 self-rejected of 717**
(from 632/34; the set diff shows no newly differing files).  Gates: fixed point
holds, `test/mt` 60/0, examples 49/0, dev self-tests 19/0.

Session-61 fifth batch: the root async `main` entrypoint now synthesizes the
host's argc/argv bridge — `span[str]` (`__mt_args_items`/`__mt_args`), raw
`ptr[cstr]`, or `ptr[ptr[char]]` — with the `__mt_async_main_arg_N` locals, a
capturing root proc whose env is named from the root local
(`__mt___mt_async_main_root_env_1`), and the argv cleanup; a call to the root
async `main` targets its `__async_main` constructor.  `std/http/server` now
matches through the entrypoint and advances to a dynamic format-string part
(`__mt_fmt_part_N`) difference; count unchanged at 634/32/51/0 with no newly
differing files.  Gates as above.

Session-61 sixth batch: every CPS local initializer now uses a prepared window
(the host's CF local path), so a dynamic format string's `__mt_fmt_part_N`
locals, a proc literal's env setup, and array-call temps precede the frame
store instead of nesting in a `StmtExpr`; the proc-literal special case folds
into the same rule.  `std/http/server` advances from the format parts to a
release-cleanup shape (`String_release(&frame->local_...)` vs
`mt_format_str_release(...)`); count unchanged at 634/32/51/0 with no newly
differing files.  Gates as above.

Session-62 batch (18 files flipped, 634/32 → 648/18):
- `std/http/server`: a CPS local initializer that stores a dynamic format
  string registers the frame field for the frame's release/cancel cleanup
  instead of deferring the temp release (the host's `format_str_fields`), and
  the release/cancel vtable functions free those fields; the CPS while
  restructure picks the host's body mode (plain locals when neither the
  condition nor the body awaits; the original body stays CF when the condition
  setup awaits).
- Foreign calls: argument values are all lowered before the call's own cstr
  temps allocate (host phase 3), `unsafe:` is transparent to the `in`
  addressability check, a multi-reference non-duplicable argument materializes
  the call into `__mt_foreign_expr_N` in expression positions (return values
  are statement roots), and a float/double parameter threads its expected type
  into an arithmetic binary argument (literal retyping + promoted operand
  casts, no constant-fit cast).  Flipped `raylib/{basic_pbr,
  spotlight_rendering}`, `raylib/shapes/{digital_clock,pie_chart}` and
  `raylib/text/unicode_emojis`.
- `sdl3/demo/woodeneye`: the analyzer's expected-type hint no longer leaks
  through a prefix cast (the host infers a cast operand with no expected type),
  so `ubyte<-(if c: 0 else: 255)` re-infers the conditional as `int`.
- Generic-instance placement: the analyzer-vs-lowering split is modelled
  explicitly.  A specialization records `body_validated` (the host's
  `validate_specialized_function_body!`) separately from
  `pre_instantiated`; the iterator protocol instantiates `iter`/`next`/
  `current` without validating their bodies.  Normal-call reach edges are
  recorded, upgrades are sticky across cache hits, and a placement fixpoint
  recomputes the classification from the graph (the analyzer ran before
  lowering, so lowering order must not decide it).  Recursive monomorphized
  self-calls resolve their return type from the pre-registered
  `function_returns` entry.  Flipped `test/mt/{queue,stack,priority_queue,
  set,multiset,ordered_map,ordered_set}_test`.

Session-62 second batch (657/9, from 648/18):
- Extending blocks resolve a nested struct target (`extending Rectangle.Edge:`)
  through the analysis' registered types in the declaration-visit pass too, so
  the method emits at its source position (`examples/nested_struct_stress_test`).
- A generic specialization created from a plain function *reference* is
  analyzer-instantiated but not body-validated (the host validates only call
  sites), so its nested concrete calls stay creator-gated
  (`examples/data_structures`).
- String matches compare the prepared scrutinee node directly (no
  `__mt_match_str_N` temp), the host's `lower_string_match_stmt` shape
  (`projects/mtc/src/mtc/lowering/lowering.mt`, `debug_map_test`,
  `lowering_test`).
- The `simd[E, N].with(lane, value)` builtin emits the host's
  `IR::SimdLaneWith` node (new IR variant, dumper, formatter and C backend).
- A concrete generic struct instance's field lookup uses the *defining*
  module's qualified name, so a field literal takes its declared type
  (`SyncValue[uint](value = 0)`, `test/mt/net_sync_test`).
- The synthesized sync `main(span[str])` argc/argv bridge initializes its args
  array with a null literal (not a `NULL` name).
- A method receiver's speculative type query is now effect-free: it discards
  its setup statements and restores the temp/format counters, so a chained
  method call's receiver is built once with the host's name
  (`std/mem/tracking`, `test/mt/mem_tracking_test`).

Session-62 third batch (659/7, from 657/9):
- The synthesized root `main` wrapper names its captured result `__mt_result`
  (host `build_root_main_entrypoint`), and recursive variant payload fields
  take the host's auto-address type (the value's own type, not `ptr[field]`).
- Variant arm payload member accesses use the declared field name; C struct
  members may be keywords (`sizeof`), so the arm-field sanitizer was wrong.

Session-62 fourth batch (660/6, from 659/7):
- An imported constant whose folded value cannot be represented literally
  (an integer standing for a `char` field, per the host's
  `lower_compile_time_literal` nil result) falls back to lowering the
  referenced constant's declaration initializer in its own module context —
  the host's `rewrite_static_storage_initializer` path.  Closes `std/flecs`.

Session-63 batch (Track A closed, 662/4 → 665/2; the residual two are the
documented `memory_stress_test` artifact and `main.mt`'s `--sexpr` loop guard):
- Module setup order: `lower_module` now follows the host's per-module passes
  (constants, globals, types, then function bodies); globals' proc symbols and
  synthetic creation order match.
- Module-level `when` expansion is shared with the placement pass, so an
  expanded function keeps its source position instead of being appended.
- Parallel IR: ported the host's `@parallel_for_counter` naming
  (`_pfor_N`/`_spawn_N`/`_detach_N`, `mt_pfor_cap_/work_`, `mt_spawn_cap_/work_`,
  `mt_detach_work_`), per-spawn capture structs with array-capture pointer
  fields and rewrite, written-capture write-back, write-conflict validation,
  and `mt_cap`/`mt_pfor_data` shapes; fixed the capture order to
  first-occurrence (Map keys are hashed, not insertion-ordered).
- Proc symbols: a final pass (`lowering/proc_renumber.mt`) renumbers
  `__proc_<N>__` ids from the assembled program in host allocation order
  (setup values, then module-function emission order) and reorders the
  invoke/release/retain tail; it is gated off when any helper has no literal in
  that prefix (async synthetic bodies), preserving their existing numbering.
- Types: added the host's `Types::Handle` singleton for `detach`; `dyn[I]`
  carries interface type arguments (`Types::Dyn :type_arguments`), including
  `iface_method_return_type` substitution; tuple instance suffixes render like
  `sanitize_identifier(to_s)` (`Option[(int, int)].unwrap` →
  `Option_unwrap__int_int`) and prelude `Option`/`Result` compare equal across
  their generic and imported forms.
- Smaller fixes: flags implicit members honor `value_explicit` (parser-synthesized
  literals no longer reset auto values), `str_index` passes its index through,
  range-index assignment emits plain `Index`, `let x = match` materializes the
  host's `__mt_match_expr_N` copy, `?` returns the propagate temp when the
  return type matches, chained calls lower through the callable-value path,
  tuple literals keep proc literals inline, a ref/pointer receiver decides
  pointer lowering from its referent, and monomorphized calls apply the ref
  argument bridge.
- C backend: void-typed struct/variant fields materialize as `uint8_t`
  (`c_field_declaration`) and initializers wrap a void value as `(expr, 0)`,
  matching the host's `Result[void, E].success` / `WorkState[void]` shapes;
  previously the self emitted an empty arm struct and invalid C.
- Gates: fixed point holds, `test/mt` 60/0, self-tests 19/0, examples 49/49,
  lex 718/718, parse 714/0/4; host-vs-self runtime output is identical for
  `examples/language_baseline` (flags/dyn/proc/match/detach) and
  `examples/multithreading_test` (parallel for/spawn/gather).

Session-63 CLI batch (24/37 → 60/1 of 61; only the `debug` formatter remains):
- Errors and usage blocks now go to stderr in the host's shape: `new`,
  `format --check --write`, `completions`, `std`, `toolchain`, `snapshot`,
  `test`, `build` (`--kind`, unknown options, missing values), `lex`/`debug`
  missing-file and directory messages, package-entry errors
  (`build.entry not found: … (resolved to …)`, directory-as-source), and
  `std show`/`build`'s no-entrypoint line.
- The analyzer reports the host's `unknown callable <name>` for an unresolved
  bare call (value/builtin/handle/type allowlists, loader-backed analysis only),
  and `check` prints only the first error per file (the host aborts there).
- `lex`'s default output is Ruby's `PP.pp(tokens)` shape (field-per-line Data
  objects, Ruby string inspection, integer/float `literal` values).
- `lower`/`emit-c` directory operands expand to sorted `.mt` files with the
  `# --- <path> ---` headers; a package root is discovered when neither
  `build` nor `run` gets an operand.
- The parser's missing-closing-delimiter diagnostics report the *previous*
  token (the host's `consume` rule) and call arguments say `expected ')' after
  call arguments`; `parse` renders lexer errors as `error[lex/error]` blocks
  and the lexer's unclosed-grouping error carries the host's line/column.
- `cache status` uses the host's `data_root/tmp/mtc-cache` (checkout root, XDG
  fallback), counts program dirs/binaries and formats MiB; `cli_parity.rb`
  normalizes `--timings` wall-clock values (the report structure still
  compared).
- Gates: fixed point holds, `test/mt` 60/0, self-tests 19/0, examples 49/49,
  lex 718/718, parse 714/0/4, lower 665/2/51/0.

Session-64 CLI batch (61/61; Track B's behavior matrix closed):
- `debug` now drives the ported LSP renderer (`lsp/debug_info.mt`) instead of
  the old ad-hoc summary: header with the expanded path and the token EOF line,
  the full token table (empty semantic column, as the host CLI passes none),
  parser AST (bare `SourceFile` — the CLI's tree carries no line, unlike the
  LSP cached re-wrap), parse errors, facts, bindings and diagnostics.  The
  facts/bindings/diagnostics sections print "(not available)" when the root
  fails to parse, matching the host's nil snapshot.  The Methods block is
  gated on the file's own extending blocks (prelude-only `method_sigs` must
  not open an empty block).  The harness normalizes the Bindings section's
  Ruby `object_id` keys (process-local identities; binding ids/order still
  compare).
- `test` argument forms: file operands (compile-fail fixture, lex/parse error
  blocks, `main` rejection, filtered-empty silence, missing-file message
  `mtc test: not a file or directory: …`), `--jobs N` validation (accepted;
  files still run in order — see *Deliberate differences*), the build flags
  `--cc/--profile/--platform/-o/--keep-c/--kind` with the host's errors and
  exit codes, first-positional path selection, the host's empty-tree messages,
  and a blank line before the summary.  Discovery is a separate pass (a lex
  error aborts before any file runs), compile-fail fixtures honor the `-n`
  basename filter, and the runner files are named with the process id (the
  host's `__mt_test_runner_<pid>`), so parallel `mtc test` invocations no
  longer collide.  The synthesized runner forces guards off and uses the
  requested compiler/profile/platform; failure details take the first
  non-blank stderr/stdout line.  `tools/gates.sh`'s per-file fan-out now uses
  the file operand instead of the one-file symlink workaround.
- Gates: dev build, self-tests 19/0, CLI matrix 61/61, LSP harness 30/30 + 4
  documented entries (`milkTea/debugInfo` still byte-equal), test matrix
  compared against the host across 25 directory/file/flag/error cases.

Session-64 second batch (Track B's cheap flags/subcommands):
- `toolchain bootstrap` is implemented from the host's `UpstreamSources` table
  (18 pinned sources, sentinel checks, `git clone` + `checkout --detach`, the
  two `config/upstream_versions.yml` override shapes, `-q/--quiet`, ANSI
  progress lines and the host's summary/error text).  `toolchain tools` builds
  the Tracy profiler (cmake configure/build, install to `<data>/bin`, the
  host's messages).  `-q/--quiet` and `--` are extracted like the host, and
  extra arguments/unknown subcommands print the host's errors.  The commands
  live in `projects/mtc/src/mtc/toolchain_cli.mt` (mirroring the Ruby file).
- `build --kind static|shared` now produces a static archive (`ar rcs`) or a
  shared object (`cc -shared -fPIC`) instead of "not implemented".  IR
  functions carry a `public_export` flag (never dumped, so `lower` parity is
  unchanged); the C backend keeps public top-level functions `static` for
  executables (byte-identical C) and exports them when building a library.
  Archives are rebuilt from clean output, and the CLI skips the missing-entry
  check and binary cache for library kinds.  The host's own static/shared path
  raises `NoMethodError: generate_header`; this is the working equivalent.
- Bindgen gained `--clang-arg` (threaded into both clang invocations),
  `--nullable-policy` (the host's JSON validation messages, function/parameter
  target validation, return/param type overrides in the emitted module) and
  `--nullable-report` (the host's JSON shape: module/header, summary, sorted
  manual entries with override/auto/c types; identical bytes on the probe).
  Generated-module include/macro differences remain Track D work.
- Gates: dev build, self-tests 19/0, CLI matrix 61/61, executable C
  byte-identical to the previous stage2, static/shared libraries link from a C
  consumer, bindgen nullable output/report byte-equal to the host on the probe,
  `toolchain bootstrap` byte-equal and its error/flag cases equal.

Session-64 third batch (package builds, `--bundle`/`--archive`):
- `loader/package_manifest.mt` now parses the host's build-relevant
  `PackageManifest` view (name, kind, source_root, entry, profile/platform
  defaults, output, assets with the host's not-found/duplicate-basename
  errors, html_template) and applies the host's
  `use_package_build_for?` rule (a directory package needs a resolved entry;
  a file operand must be that entry).  `build` uses the package output layout
  (`build/bin/<platform>/<profile>/<name>`, or `[build] output`) instead of
  the raw source stem; library packages and entry-less applications fall back
  to the host's "expected a source file, got a directory" path.
- `--bundle`/`--archive`: the bundle root is `-o`/`[build] output`/
  `build/dist/<platform>/<profile>/<name>`; the executable's parent is
  created, `build.assets` are staged beside a non-bundle binary or packed
  into `assets.mtpack`, and `--archive` writes `<bundle_root>.tar.gz` with
  `std/tar`.  The messages (`built <operand> -> <dir>`, `entry executable`,
  `  [cached]`, `archive`) and clean targets match the host, and a cache hit
  re-stages assets/archive like `build_cached`.
- `std/asset_pack.mt` gained the host's MTAP writer (28-byte header, 32-byte
  entries, sorted logical paths, raw data; packs are byte-identical on the
  probe).  The reader's `close`/state handling was fixed so a host-produced
  pack opens and reads in-language.
- `std/toml.mt` duplicate-key/table messages match Tomlrb
  (`Cannot overwrite value with key x`, `Key x is already used`); `run` now
  prints `[cached]` on a cache hit.
- Harness: 65/65 (bundle, archive, clean and non-package cases; the `pkg`
  fixture now has an asset tree and a real `stdio.print_line` program).
- Gates: dev build, self-tests 19/0, CLI matrix 65/65, MTAP byte-identical,
  tar listing/extraction equal, host-vs-self bundle error/clean matrix equal,
  focused lower 3/4 (only the documented `main.mt` artifact).


## How to start a work session

### Entry points

| Workstream | Read | Verify with |
| --- | --- | --- |
| `lower` dump parity (**closed**, keep at 0 real differ) | *The program* Track A; `docs/language-design.md` | `ruby tools/sexpr_parity.rb lower -q -j 16 --host-cache tmp/sexpr-host-cache` (~1 min warm, ~4 min cold) |
| CLI behavior parity | Track B; `tools/cli_parity.rb --help` | `rake "cli:parity"` |
| Wasm build/preview | Track B item 1 (closed); `wasm_preview.mt` | `ruby tools/wasm_smoke.rb` |
| Docs server | Track B item 2 (closed); `docs_app.mt` | `ruby tools/docs_smoke.rb` |
| Linter corpus residue | Track C; the linter sections of `docs/language-design.md` | `ruby tools/lint_parity.rb -q` (`--host-cache FILE` makes re-runs ~20 s), `rake "parity:scoreboard"` |
| Analyzer / `check` diagnostics | the session-72 section; Track C's analyzer notes | `ruby tools/diag_parity.rb check -j 8 std examples`; `ruby tools/check_parity.rb` |
| Imported bindings / bindgen | Track D; `docs/bootstrap-design.md` | `build/stage2/mtc imported-bindings --all --check`; `ruby tools/imported_bindings_parity.rb --json tmp/ib-parity.json`; `ruby tools/bindgen_parity.rb --self build/stage2/mtc`; regenerate `std/c/*.mt` and diff |
| LSP feature parity / residue | Track E; `docs/lsp-design.md` (esp. §8 differences), `docs/lsp-performance.md` | `tools/lsp_parity.rb record --server host\|self` + `compare`; `tools/lsp_project_audit.rb --workspace DIR [--canonical]`; `tools/lsp_recovery_probe.rb --check`; `tools/lsp_soak.rb` |
| DAP | Track F (closed); `docs/dap-design.md` (gaps in §10) | `ruby tools/dap_smoke.rb [--server host\|self\|both]`; `ruby tools/dap_async_probe.rb` |
| Formatter (`:tidy`, `:preserve`, `:canonical`) | Track E/formatter history at `d8a199c7` §7 | `ruby tools/format_parity.rb all -j 16` (739/739, counts drift) |
| Bootstrap / release | `docs/bootstrap-design.md` | `tools/bootstrap.sh -j 16` (full); `--fast` = fixed point only |
| In-language tests | `docs/testing.md` | `build/stage2/mtc test test/mt -I .` |
| Example builds | Track H | per-family sweeps (15 top-level, `examples/sdl3` 34/34, a raylib sample) |

### Verification tiers

Iterate cheap, prove once:

- **Tier 1 — per edit.**  Build the dev compiler
  (`ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev`, ~50 s)
  and run `tmp/mtc-dev test projects/mtc -I . --timeout 120`.  Measure only the
  class you touch: a focused `ruby tools/lint_parity.rb -q <paths>`, a single
  file's host-vs-self diff, `ruby tools/sexpr_parity.rb lower -q <path>` (the
  host cache makes repeats cheap), or the matching parity harness on one case.
- **Tier 2 — once per commit, on frozen sources.**  `tools/gates.sh` prints the
  gate set for the working-tree diff (or accepts `--areas linter`); `--run`
  executes them with logs under `tmp/gates/`.  Hard proofs: `tools/bootstrap.sh
  -j 16 --fast` (fixed point; the full form also runs the suite) and
  `build/stage2/mtc test test/mt -I .` (60/0), then the sweep that covers the
  area (lower/lint/CLI/LSP/DAP/format).
- **Batch the ceremony, not the care.**  Land 3–5 fixes per commit, each
  verified against the host before the next; run tier 2 once on the frozen tree.
  A batch costs about an hour instead of five ~45-minute cycles.
- **Do not replay a baseline a previous session verified at the same commit.**
  The Ledger records the last verified numbers; re-measure only the classes your
  change can move, and only when the tree moved.
- **Rebuild before measuring.**  A stale `build/stage2/mtc` is the classic false
  result.  `tools/bootstrap.sh` rewrites `projects/mtc/src/mtc/version_info.mt`, which makes the sexpr
  staleness warning fire harmlessly.
- **Quote sets where counters drift** (sexpr's file count with `tmp` fixtures,
  the LSP audit's ±10 between runs, the lint corpus with `tmp` files).
- **Long gates in the background.**  Do not idle on a ~10–25-minute bootstrap;
  start it and keep reading/planning (but see the frozen-tree rule below).
- **`tmp/` is scratch.**  Session probes under `tmp/` are not durable; durable
  conventions are `tmp/sexpr-host-cache`, `tmp/gates/`, and `tmp/mtc-dev`.
  Recreate a probe from the host's code/tests when one is cited.

### HARD RULES

- **Never edit sources while a gate runs** — `tools/bootstrap.sh` compiles the working
  tree, and `tools/sexpr_parity.rb`'s host side analyzes imported working-tree
  sources, so a mid-run edit silently corrupts the result.  Check the exit
  status, not just the tail.
- **No hacks, no workarounds** — fix root causes where the wrong state is
  produced, not in the layer where the symptom surfaces.
- **Sandbox generated binaries**: `timeout 10 bash -c 'ulimit -v 20000000; …'`.
  A 124 exit is a hang, 137 an OOM/SIGKILL, 139 a SIGSEGV, 134 a SIGABRT/double
  free — investigate, don't call it test noise.
- **Check the self-test suite's file count, not just `0 failed`** — `mtc test`
  silently skips a file that fails to lex/parse (`18 test file(s), 0 failed`
  with a broken `projects/mtc/test/*.mt`); the full-corpus sweep's `hostfail`
  count catches the same mistake one file late.
- **Never run `mtc test` while another gate runs** — the suite synthesizes
  `__mt_test_runner_*.mt` into `projects/mtc/test/`, so concurrent runs discover
  each other's runners (`duplicate value main`), and a stray runner left by a
  killed run poisons the next bootstrap.
- **Sync this file's Ledger (and any changed workstream doc) in the same commit
  as the code change.**
- **Generated binaries are not deliverables** — clean stray runners and scratch
  artifacts; gitignored gate output under `tmp/` and `build/` may stay.
- Commit trailer: `Co-authored-by: CommandCodeBot <noreply@commandcode.ai>`.

### Phase order and current position

0. **Hard build parity** — **DONE** (session 49; re-verified session 50): all
   15 top-level examples build, the synchronous set's stdout+exit is identical,
   `examples/sdl3` 34/34, `test/mt` 60/0.
1. **`lower` dump parity** — **CLOSED** (session 63): 665/2/51/0 of 718, the
   two residuals are documented host artifacts.  See Track A.
2. **CLI behavior parity — CLOSED (session 68; 92/92 after the session-71
   bare-operand cases)**.  Sessions 64–68 landed `debug`, the `test` argument
   forms, `toolchain bootstrap|tools|doctor`, `build --kind static|shared`, the
   bindgen nullable flags, `--bundle`/`--archive`, wasm build/preview, `docs`,
   `deps` and `--locked`/`--frozen`.
3. **Linter corpus residue — CLOSED (session 69)**: 632 agree / 3 differ of
   635 (the three documented rows), **43/43 rules and 13/13 fixers**.
4. **Imported bindings / bindgen** — **CLOSED**: imported bindings 29/29 and
   bindgen reproducibility 33/34 with the one documented custom generator
   (`tracy`).
5. **Final verification** — Track H, **passed session 71**.

LSP, DAP and the formatter are **closed** at their documented differences; only
their listed residues (ref-lifetime modelling; the optional desktop F5
click-through) remain.

### Definition of done (per track)

- **`lower`**: 0 differing files in `sexpr_parity lower` (residuals only if
  proven host artifacts, each documented); lex/parse stay 0-diff; no build
  regressions anywhere.
- **CLI**: every host command/flag exists with equivalent behavior; `cli:parity`
  all matches; `deps`/`docs`/wasm/bundle/toolchain functional.
- **Linter**: per-rule counts/messages/severities/positions equal the host on
  `examples/language_baseline.mt`, `examples/memory_stress_test.mt` and the whole-corpus sweep;
  every host rule/fix exists.  Residual rows are acceptable only when proven a
  host artifact or a documented self-better fact (the three current rows are in
  *Deliberate differences*).
- **LSP**: harness 0 unintended entries (only the documented rows); the audit's
  completion class closed; `debugInfo` byte-equal; `[LSP perf]` ≤ ~10 ms per
  edit (met); valgrind clean (met).  **Met at session 31–38.**
- **DAP**: a real VS Code session debugs a `.mt` program end-to-end with the
  default `lldb-dap` backend (breakpoints, stepping, evaluate; Milk Tea
  frames/locals via the debug map); process backend unchanged; `dap_smoke`
  green on both.  **Met at the protocol level (session 71):** `dap_smoke` has
  zero differing rows and `tools/dap_async_probe.rb` drives VS Code's ordering
  against the real `lldb-dap` through launch → breakpoint → `main` frame →
  locals → evaluate.  A desktop F5 click-through is an optional manual smoke.
- **Bindings/bindgen**: `imported-bindings --all --check` 29/29 verified (or each
  residual delta justified as cosmetic with evidence); bindgen output
  reproducible for the repo's bindings (**met**: 33/34 byte-identical, the one
  residual is the host's custom `tracy` generator).
- **Formatter**: all modes byte-identical (739/739 at the session-71 re-run;
  counts drift).  **Met.**

### Session kickoff prompt

```
Continue the Milk Tea self-host work in /home/teefan/Projects/Ruby/mt-lang
(branch `selfhost`). The parity program is closed (Track H passed, session 71):
start from this file's Handoff section, not a ranked item. Work in tiers:
iterate on the dev compiler
(ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev, ~50 s;
tmp/mtc-dev test projects/mtc -I . --timeout 120), measure only the class you
touch, and run the tier-2 proofs once on frozen sources — `tools/gates.sh`
prints the set (`--run` executes it, logs in tmp/gates/). Do not replay the
ledger's verified baselines unless the tree moved.

Read first: this file's Status at a glance, Handoff, How to start a work
session, and The program (the tracks and their stopping rules). The
pre-compaction history is at `git show d8a199c7:docs/self-host-plan.md`.

If you change a subsystem: one item per commit, sync the gate set and this
file's Ledger in the same commit, and keep the documented deliberate
differences intact. Commit trailer:
Co-authored-by: CommandCodeBot <noreply@commandcode.ai>.

HARD RULES: never edit sources while a gate runs (bootstrap compiles the
working tree — check the exit status, not the tail); rebuild before measuring;
quote sets where a counter drifts; run generated binaries as
`timeout 10 bash -c 'ulimit -v 20000000; …'`; no hacks — fix root causes.
```

## The program — tracks and stopping rules (all closed)

Goal: close every remaining self-host gap so `build/stage2/mtc` matches the Ruby
host on observable behavior everywhere — `--sexpr` dumps, CLI messages/commands,
LSP, DAP, linter, formatter, imported bindings, bindgen — while keeping the
self-host's documented improvements (malformed-frame recovery, synchronous
facts, speed, determinism).  **Every track is closed at its documented
residue (session 71); Track H's final matrix passed.  There is no ranked open
parity work left; the track sections below are the stopping rules to preserve.**

Confirmed scope decision: **all** unported CLI subsystems are in scope (`deps`,
`docs`, wasm/emcc + preview, `--bundle`/`--archive`, `--jobs`, toolchain
bootstrap/tools, `--kind static|shared`, the bindgen policy flags), and all are
now ported.  Tracks A–D reached their targets; LSP/DAP/formatter are closed at
their documented differences.  Anchor by symbol names, not line numbers —
lines drift.

### Track A — `lower` dump parity (CLOSED: 684/2 of 739)

Current set: **684 match / 2 differ / 53 host-rejected / 0 self-rejected of 739
files** (session 70).  The host-rejected bucket is `external` and platform-pinned
files; the count drifts with the tree and `tmp` fixtures — quote the set.

The two counted differs are the documented host artifacts, not work:

1. **`examples/memory_stress_test`** — the host's leaked `ref[@_mt_0, T]`
   lifetime; the self renders the declared `ref[T]` (see *Deliberate
   differences*).
2. **`projects/mtc/src/mtc/main.mt`** — the `--sexpr` loop-guard artifact (the
   dump exceeds the generated C loop guard's UTF-8 scan); documented under
   *Deliberate differences*.

Track A reached its stopping rule: **0 real differing files**.  Keep lex/parse
at 0-diff and re-measure both after any lowering-adjacent change.

### Track B — CLI parity (92 cases; 92 match, 0 pending; **closed**)

The **original 65-case behavior matrix is byte-equal** (session 64; `--timings`
values and `debug`'s Ruby node ids normalized).  `debug`/`test`'s argument forms
and the bundle/archive cases closed there — see the session-64 batches.  The
fixed `pkg` fixture now builds and runs a real program (the old fixture used a
bare `print`, so its build/run cases only compared a semantic-error path).

Session 65 replaced the regex allowlist with case-backed pending metadata;
session 67 closed `toolchain doctor`, `run --bundle`, `run --archive`,
`build --platform wasm` and the wasm preview; session 68 closed `deps` and the
locked/frozen build, so the matrix is **92 cases / 92 match / 0 differ /
0 pending** — the whole CLI surface is byte-equal.  Session 71 added the bare
`build`/`run` package-root forms (the dispatcher no longer blocks
`parse_source_operand`'s discovery) and their three cases.  A future gap adds a
`pending:` case, and a pending case that starts matching must be promoted (the
harness fails otherwise).  The session-65
second batch closed `parse`/`emit-c` multi+directory forms, `format`
multi/directory and its batch summaries, `check`/`lint` unknown-flag
validation, and `lint --init`.  Remaining work:

1. **Wasm/emcc + preview — CLOSED (session 67).**  `build --platform wasm`
   covers compiler resolution, the embedded shell/custom template, preload
   flags, `.html` output rules and emcc sidecar cleanup; `run --platform wasm`
   builds to the package/source output path and serves it through
   `wasm_preview.mt` (MIME/COOP/COEP, GET/HEAD/404/405, traversal guard,
   SIGINT/SIGTERM).  `tools/wasm_smoke.rb` is the hard `wasm_smoke` gate; the
   host/self C and `.data` are byte-identical on the scratch package.  The
   enabling compiler fix was the `Task[void]` `take_result` field (and
   `std.async.run_on_proc`).  **Do not** add an emcc row to `toolchain doctor`
   (the host has none).
2. **`docs` — CLOSED (session 67).**  `docs_app.mt` implements the reference,
   stdlib, module, source, highlight, search, static-asset and 404 routes;
   `--port/-p`/`--open/-o` and the two banner lines match.  HTML is generated
   directly (functional, not byte-identical) while the reference index, source,
   highlight, CSS and JS responses are byte-equal.  `tools/docs_smoke.rb` is the
   hard `docs_smoke` gate (it uses SIGINT, the host's Ctrl+C path).
3. **`deps` — CLOSED (session 68).**  `projects/mtc/src/mtc/packages/*.mt`
   ports the whole subsystem: `version` (semver plus `^`/`~`/range
   requirements), `manifest` (full `PackageManifest`/`DependencyView`, path/git/
   registry validation with the host's messages), `paths`, `editor` (`add`/
   `remove` through the host's textual `[dependencies]` rewrite), `solver`
   (branching registry resolution with locked pins and cycle detection),
   `graph` (source roots, `package_for_path`, `deps tree`), `lock` (schema 1/2,
   SHA-256 instance ids, byte-identical rendering, `--check`), `source`
   (identities, shared cache, git/registry materialization) and `registry`
   (`$MILK_TEA_PACKAGE_REGISTRY`, filesystem/HTTP upstreams, `.tar.gz` +
   `versions.txt`, sync-on-demand).  `deps add|remove|update|tree|lock|publish|
   fetch` are wired in `main.mt`; `--locked`/`--frozen` load the locked (or live)
   graph and add its source roots to module resolution in `build`, `run` and
   `debug`.  Verified on a shared package fixture: the rendered `package.lock`
   is byte-identical to the host's, and `tree`/`fetch`/`add`/`update`/`publish`
   output plus the registry archive contents and `versions.txt` match.  The root
   graph is `deps lock`'s (`Graph.load`), so a selective `update` pins the
   unselected registry versions exactly as the host does.  In-language tests:
   `projects/mtc/test/packages_test.mt`, `package_version_test.mt`.
4. **Harness — closed.**  92/92 cases match with no pending entries; a future
   gap adds a `pending:` case (the harness fails when one starts matching).
   Timing values are normalized (wall-clock measurements never compare
   byte-for-byte); the report structure is.

Session-64 `toolchain`/`build --kind`/bindgen-nullable flips are recorded in
the session-64 second batch above.  Session 67 closed `toolchain doctor` to
byte parity (60 rows: 8 tools + 18 vendored sentinels + 34 raw-binding
headers), `run --bundle`/`run --archive` and `build --platform wasm`; session 68
closed `deps` (5 cases) and locked/frozen build (2), emptying the pending set.

Session-63 CLI flips: all 37 original diffs except `debug` — lex/parse/lower/
emit-c diagnostics and formats, check/lint/format/debug messages and channels,
package build/run entry points, `new`, `completions`, `std`, `test`, `cache`,
`toolchain`, `snapshot`.  Session 64 closed `debug` (shared renderer) and
`test`'s argument forms.

### Track C — linter corpus residue (631/3 of 634; 41/43 rules)

State: **631 agree / 3 differ of 634, hostfail 0, selffail 0** (session 69).
The residual three rows are documented under *Deliberate differences*: two
`redundant-cast` rows in `std/cli.mt` (the self's flow-refined type exposes a
genuinely redundant nullable-pointer cast the host's unrefined fact misses) and
one in `projects/mtc/src/mtc/main.mt` (the host's character-indexed source scan
misses a cast after multibyte text; the self uses byte columns), plus one
host-only `constant-condition` in `examples/reflection_advanced.mt` (the host's
inline-if non-chosen branch lacks a binding id, so its constant propagation
keeps `count = 0`).  The corpus count drifts with the tree; quote the set.

Session-69 linter batch (571/63 -> 631/3): see the session-69 batch in *Status
at a glance* for the per-rule mechanics.  Closing summary by rule (pairs are
self-only / host-only before -> after): `constant-condition` 11/1 -> 0/1,
`prefer-or-pattern` 10/10 -> 0/0, `loop-single-iteration` 9/0 -> 0/0,
`unreachable-code` 5/0 -> 0/0, `redundant-cast` 2/8 -> 3/0,
`prefer-let` 2/2 -> 0/0, `prefer-var-else` 2/0 -> 0/0,
`prefer-struct-with` 0/1 -> 0/0.

Session-68 linter batch:
- **`prefer-let` receiver mutation (75/141 -> 7/5).**  The analyzer now records
  an editable method's receiver at its *root* identifier (walking member/index
  receivers, stopping at a call — the host's `mark_mutated` shape), so
  `datagram.data.release()` marks `datagram`; the linter's site match uses the
  same walk.  The linter's `ctx_mark_mutated` no longer descends into
  `read(x)` targets (the host's does not either).
- **`redundant-cast` type identity (75/48 -> 2/8).**  `same_type` equates a
  qualified `ty_named` with a `ty_imported` of the same module/type (the
  host's `to_s` comparison), so `ptr[Expr]` from a local alias and from an
  import are one type.
- **`prefer-try` (76/40 -> 0/0).**  Three fixes: the anchor is the scrutinee's
  *own* line (a node kind with no line renders the host's positionless
  `path::` form, now supported by the lint printer); `Result[int, E].failure`'s
  specialization receiver counts as the written base name on both the pattern
  and the propagated return; and the rule is suppressed inside generic bodies
  (the host's facts carry no expression types there).
- **`shadow` (20/0 -> 0/0).**  Two bugs: the scope window stride was a fixed
  16 entries while a scope may hold up to 128, so a large function scope spilled
  into the next scope's window and a sibling block's bindings looked like outer
  ones; and match-arm scopes suppressed the check entirely (`match_arm_depth`),
  while the host treats an arm's scope like any other.  The window stride is now
  `MAX_ENTRIES` with a `SCOPE_WINDOW_TOTAL` buffer.
- **`prefer-own-ptr` (19/0 -> 0/0).**  The host's annotated-declaration test
  compares `type_ref_source(...)` (the bare `ptr` name part) against
  `include?("ptr[")`, which never matches, and `heap.must_alloc[T](…)` parses
  through a `Specialization` callee that `heap_alloc_call?` does not match, so
  the rule never fires on the corpus shapes.  The self now mirrors both.
- **Binary numeric promotion.**  `infer_binary`'s numeric fallback now returns
  the promoted `common_numeric_type` (an `int` operand with a `float` sibling
  is `float`), with dedicated arms for a bare integer/float literal adapting to
  the sibling and for shifts (`<<`/`>>` keep the left type after literal
  harmonization).  This fixed both the linter's `int<-((CONST) * 0.1)` false
  positive and three `lower` regressions the first attempt introduced.  The `prefer-own-ptr`
candidate set now matches the host (annotated `ptr[...]` locals plus
`must_alloc`-family and `alloc_expr/alloc_stmt/alloc_decl` initializers), so the
38 host-only rows are gone; the remaining 20 are safe/unsafe use-accounting.
`redundant-cast`'s integer-literal comparison sibling is restricted to
primitives/enums, and the linter's editable-site records carry the receiver
column (not just name/line).  Closed with no residue:
`redundant-unsafe`, `owning-release-leak`, `owning-release-double`,
`prefer-inline-if`, `prefer-conditional-expression`.

Closed in session 69: **`directional-ffi-arg`**
(`lib/milk_tea/tooling/linter/rules.rb:513-531`) and **`platform-api-drift`**
(`lib/milk_tea/tooling/linter/imports_platform.rb:32-62`).  The directional rule
is analyzer-recorded (local and imported `alias.fn(...)` calls) and emitted at
the call visit; the platform rule lives in `linter/platform_drift.mt` and was
verified message-for-message against the host linter on scratch platform-pair
fixtures.  All 43 host rule codes now exist.  The `redundant-unsafe` fix generator landed in
session 66 (13/13 auto-fixable fixers); the fix engine now follows the host's
`AUTO_FIXABLE_RULE_CODES` order, one batch per rule per pass, refuses fixes on
an unresolved import, rejects a candidate that does not parse, and re-analyzes
against the loader-backed imports.  Remaining fixer deltas: the host's
`reserved-primitive-name` re-lint cross-check and its span-based edit anchors
(the self re-finds the declaration text).

Analyzer gaps that gate lint rows and LSP entries:

- **Null assignability + immutable parameters — CLOSED (session 66).**  A bare
  `null` is accepted only by a nullable target (a typed null must match the
  nullable base; the host's `null_assignable_to?`), and parameters are bound
  immutably (`cannot assign to immutable p`).  **Remaining:** the host's
  positive generic-vs-scalar split (`ptr[int]` → `str`) and the
  `call_argument_compatible?`/`implicit_ref_argument_compatible?` argument-only
  coercions; the self's fallback is still permissive for those pairs.
- **Constant-value coercion — CLOSED (session 72).**  The host folds via
  `evaluate_compile_time_const_value` (`semantic_analyzer/top_level.rb:280`) +
  `numeric_constant_fits_type?`; the self now folds through
  `type_compatibility.fold_int_constant` + `constant_fits_target` and
  `types.integer_constant_fits` at the return/assignment/local sites (see the
  session-72 section).  `return sdl.ALPHA_OPAQUE` from `-> ubyte` is accepted,
  `return 300` is rejected, both matching the host.
- **Member-assignment immutability — CLOSED (session 66).**  The host's
  `infer_lvalue_receiver` ladder is ported: `ref[T]`, mutable raw pointers and
  `own[T]` receivers are assignable; `const_ptr` reports
  `cannot assign through read-only raw pointer`; a `span` parameter is allowed;
  a `let`/parameter/`this` in a non-editable method reports
  `cannot assign through immutable <name>`.
- **`prefer-let` and specialized editable calls — CLOSED (session 66).**
  `check_specialized_method_call` records/enforces the editable receiver, the
  linter unwraps an `expr_specialization` callee to its member access, and the
  fix engine re-analyzes candidate sources against the loader-backed imports
  (`Analysis.imported_modules`), so `var r` in
  `examples/reflection_advanced.mt` is preserved.
- **`--fix` unresolved-import guard — CLOSED (session 66).**  `fix_source`
  returns the source unchanged when `options.unresolved_import_paths` is
  non-empty; the loader's binding map is retained for the fix engine's
  re-analysis.
- **Reserved-name errors — CLOSED (session 66).**  Module-level consts,
  variables, functions and events plus parameters/locals now report the host's
  `<kind> <name> uses reserved built-in type name <name>` at the declaration
  position; `Option`/`Result` joined the value-name set
  (`ensure_non_reserved_value_type_name!`).
- **Sema message rendering and return-mismatch position — CLOSED (session 66).**
  `return type mismatch` renders the host's qualified `to_s`
  (`expected std.vec.Vec[int], got int`); a position-less literal return falls
  back to the return statement's position (the host's literal nodes carry no
  position), so `return "x"` reports the `return` site rather than `0:0`.
  `cannot assign to immutable x` remains byte-equal.

Tool: `ruby tools/lint_parity.rb -q` (add `--host-cache FILE`; warm fill ~4 min,
then ~20 s per full run); `rake "parity:scoreboard"` for the per-rule table.

### Track D — imported bindings and bindgen

1. **OpenGL naming transforms — CLOSED (session 66).**  The six tables and
   seven functions are in `projects/mtc/src/mtc/imported_bindings/naming.mt`,
   with the host's `snake_case` gsubs, full-gsub `replace`,
   `openglize_binding_name`, split reserved sets, and the 37 golden vectors in
   `projects/mtc/test/imported_bindings_naming_test.mt`.  The emitter keeps
   type case, applies `types.overrides` (name/mapping/kind), resolves bare
   raw aliases (`Uint16 -> ushort`, `enet_uint32 -> uint`), projects handles in
   function-type params, builds method wrappers from the generated entries
   (modes, public types, exclusions), and tidy-formats the assembled module.
2. **29-binding verification — CLOSED (session 66).**  The self-only
   `imported-bindings` command has `--stdout` (byte comparison), `--json`
   (per-entry status + first diff offset/line), and `--soft`;
   `tools/imported_bindings_parity.rb` compares self vs host vs checked-in and
   classifies every changed binding.  The Phase-0 baseline was 3 verified / 26
   changed of 29; the landed result is **29 verified / 0 changed / 0 new of
   29** (`box3d` added to the self registry).  `bindings` and
   `bindings_parity` are hard gates.
3. **Bindgen reproducibility — CLOSED (session 70).**  `tools/bindgen_parity.rb`
   drives the host generator and the self CLI with the same raw-binding option
   table (`--options-json` is a self-only flag; the host CLI has no option
   table): **33 match / 0 differ / 0 error / 1 custom of 34**.  The port is the
   host's two-phase architecture (extraction with node indices, referenceable
   record index, insertion-ordered selection with opaque→complete upgrade,
   synthetics-first emission, then index-sorted declarations), a literal port
   of `type_mapper.rb` (nullability, function pointers, typedef preservation,
   unknown-type rejection), and the host's prelude/`-fno-builtin` invocation
   semantics.  The single custom entry, `tracy`, is the host registry's
   `generator:` lambda reading `std/c/tracy.mt` verbatim; `bindgen_parity`
   classifies custom generators separately and exits non-zero only on a real
   differ/error.  `bindgen_parity` is a hard gate (`tools/gates.sh --only
   bindgen_parity --run`).

### Track E — LSP residue (closed at documented differences)

The LSP reached its Definition of Done: 30/30 capability keys, 4 documented
harness entries, the completion class closed, `debugInfo` byte-equal, valgrind
0, edit latency ≤ 10 ms, soak at 74–75 KB/cycle raw / ~28 LS at 200 cycles
(session 71 re-measure; the per-edit leak is owned by per-entry
regions; the one-time index walk's arena-leaked ASTs are a documented level, not
a slope, and the loader's small `qname_to_str` strings remain).  Remaining items are optional / documentation
decisions:

- **Ref-lifetime modelling** — the host's synthesized `ref[@_mt_N, T]` lifetime
  in a field detail (`mst@224:18`), where the self renders the declared
  `ref[T]`.  This is a documented deliberate difference; porting the host's
  `lib/milk_tea/core/semantic_analyzer/type_declaration.rb:516-522` auto-lifetime rewrite is only worth it if the
  same machinery is needed elsewhere.
- **Imported enum/flags member locations** — for `alias.Enum.member` the self
  resolves the member text and deliberately drops the location (matching the
  host's classifier miss).  Pointing both at the imported declaration would be a
  documented self-better difference; decide and document, don't drift into it.
- **Documented rows stay documented** unless their machinery is built for
  another reason (see *Deliberate differences* and `docs/lsp-design.md` §8).

### Track F — DAP (closed)

The debug map, build-on-launch, pause diagnostics/modules, the lldb-dap bridge
and the process backend are done; `dap_smoke` is row-for-row equal except the
documented self-better `lldb-real frame0 name`.  Session 71 fixed the
`configurationDone`/launch ordering deadlock: the bridge deferred
`configurationDone` whenever the start request was in flight, but lldb-dap
answers `launch` only after the target starts (which needs `configurationDone`),
so VS Code's F5 session waited out the 5 s adapter deadline and tore down with
"backend request timed out: launch".  The gate now mirrors the host's
`backend_configuration_pending?` and releases a deferred `configurationDone`
when the adapter is initialized (or the start has answered).  A real-lldb-dap
async-order probe (launch, then `configurationDone` without waiting) proves
launch success → entry stop → breakpoint stop → frame `main` → locals `x=3` →
evaluate `3`.  The protocol path is closed; a desktop VS Code click-through
remains an optional manual smoke, not a known gap.

### Track G — compiler throughput (not parity)

The self compiles its own sources in ~157 s (`emit-c` of
`projects/mtc/src/mtc/main.mt`) where the host takes ~40 s (3.9×); a full
bootstrap pays it twice.  One profiling session on the self's front-end/lowering/
C-emit (candidates: repeated analysis/type resolution per module, the
string-heavy rendering paths, the C emitter's text building) buys every future
gate several minutes.  Behavior must not change — only wall time; verify with
`emit-c` timing plus the fixed point.

### Track H — final verification (PASSED, session 71)

On a clean tree: `tools/bootstrap.sh -j 16` (stage2 == stage3, 22/0),
`build/stage2/mtc test test/mt -I .` (60/0), the 15 top-level examples, sdl3
34/34, the raylib sample, the vendored families, `sexpr_parity` lex/parse/lower,
`cli:parity`, both LSP harnesses + valgrind + a Neovim and a VS Code session,
`dap_smoke` on both backends, `format_parity all`, `imported-bindings --all
--check`, the lint corpus, and `~/Projects/MilkTea/SimpleGame` building and
running.  Update this file's Ledger and any changed workstream docs.

The session-71 pass: bootstrap fixed point + 22/0, `test/mt` 60/0, examples
49/49, lex 739/739, parse 735/0/4, lower 684/2/53/0 (the two documented
artifacts), cli 92/92, lint 632/3 (the three documented rows), unused-import
635/635, formatter 739/739 in all three modes, imported bindings 29/29,
bindgen 33/34 + 1 custom, LSP harness 4 documented entries + recovery 6/6 +
canonical audit 6 (the 4 documented + 2 warm artifacts) + valgrind 0 + Neovim
hover, DAP zero differing rows + the async-order F5 probe, wasm/docs smoke, and
SimpleGame built and run identically by host and self.  Every Ledger counter is
at its target; the only manual item left is a desktop VS Code F5 click-through.

## Deliberate differences (do not chase)

Parity work must not "fix" these.  The canonical LSP table is
`docs/lsp-design.md` §8 (12 rows with direction and pinning tool); the main
ones:

- **LSP harness (4 documented entries):** the host's parser recovery; the host
  hanging on a malformed frame (the self answers `-32700` and keeps serving);
  the host's facts lag (the self answers synchronously); the host's
  directory-form module `typeDefinition` path (where the self resolves the
  imported declaration the host's `module_path_for_name` cannot reach).
- **LSP audit (4 stable rows):** completion `mst@224:18` (the host leaks its
  synthesized `ref[@_mt_0, ubyte]` lifetime; the self shows the declared
  `ref[ubyte]`), completion `lb@818:17` (the host's facts give up on the
  `map_error` arm binding; the self answers the field), hover `type quat`
  `lb@1653:24` and documentHighlight `lb@704:67` (the host's warm index/facts
  carry-forward; byte-equal cold).  The canonical warm audit adds the 2
  builtin-hover warm artifacts, and the host's first-file `documentSymbol` race
  appears as ±drift, not a work item.
- **DAP:** `lldb-real frame0 name` — self `add`, host `main_add` (the host's
  cache-hit map loss).
- **`lower`:** the host's leaked auto-lifetime names (`ref[@_mt_0, T]`) in
  `memory_stress_test`; the self renders the declared `ref[T]`.
- **`lower` `main.mt` (`--sexpr` only):** the dump is ~59 MB and the compiler's
  own `String.as_str` UTF-8 validation legitimately scans more than the C
  backend's 50,000,000-iteration loop guard; the host-built stage1 aborts
  identically (`build/stage1/mtc lower projects/mtc/src/mtc/main.mt -I .
  --sexpr` -> rc 134 `loop iteration limit exceeded in str_is_valid_utf8`),
  while only the Ruby host (which has no guard) completes.  Not a parity gap;
  the non-`--sexpr` formatting path completes on both C compilers.
- **`lower` `examples/sdl3/demo/woodeneye.mt`:** the self renders `std/math`'s
  `double` constants with 6 significant digits (`PI = 3.14159` where the host
  prints `3.141592653589793`).  Pre-existing in the constant-dump path (the
  pre-change tree produces byte-identical output) and previously hidden in the
  `hostfail` bucket; not introduced by session 72.
- **`check` diagnostic residue (3 rows, all deliberate):** the new `check` sweep
  (`tools/diag_parity.rb check`) reaches **0 verdict / 0 position** differences
  over `std`+`examples`; its 3 message rows are exactly the `std/cli.mt`
  `redundant-cast` pair and the `examples/reflection_advanced.mt` host-only
  `constant-condition` documented below, seen through `check`'s renderer.
- **Linter corpus residue (3 rows, all deliberate):**
  - `std/cli.mt:727,740` — `redundant-cast` on `ptr[X]<-value`.  The self's
    flow analysis narrows `value` to non-null after `if value == null: break`,
    so its recorded expression type is `ptr[X]` and the cast is genuinely
    redundant; the host's fact carries the declared `ptr[X]?`, so it misses the
    hint.  Removing the cast is type-correct under the self's refinement.
  - `projects/mtc/src/mtc/main.mt` (`c"── Tokens …"` block; line 5794 in
    session 71) — `redundant-cast` parentheses after
    multibyte text (`c"── Tokens …"`).  The host's `check_redundant_cast_parens`
    starts `line.index("<-", column - 1)` with a **character** index on a line
    whose earlier bytes are multibyte, so it never finds the `<-`; the self uses
    the compiler's byte columns and correctly reports the redundant parens.
  - `examples/reflection_advanced.mt:65` — host-only `constant-condition`
    (`inline if DEBUG_OFF:` branch assignment).  The host's analyzer does not
    bind expressions in the non-chosen inline branch, so its constant
    propagation keeps `count = 0` and reports the following `if count != 0` as
    always false; the self's name-keyed facts see the assignment and (correctly)
    do not report.  Reproducing the host would need its per-declaration binding
    ids in the linter CFG and would reintroduce the false positive.
- **`platform-api-drift` in the CLI:** the host `lint` command analyzes each
  operand from a bare `Parser.parse` (empty module name) while sibling files
  load through `ModuleLoader` (inferred names), so its module-name guard skips
  every CLI comparison; the rule only fires through the LSP.  The self compares
  the sibling paths it discovered (same stem, hence the same module by
  construction) and reports in both the CLI and the LSP — the rule's intent.
  Verified message-for-message against the host linter invoked directly, which
  loads the root through the module loader.
- **Better-than-host behaviours to preserve:** malformed-frame `-32700` + keep
  serving, synchronous facts with no lag, faster cold start, deterministic
  binding-map iteration; a capability the host lacks is not automatically a
  defect to remove.
- **`test --jobs N`:** validated and accepted, but the self still runs files
  sequentially.  The host's fork-per-file mode only changes wall time: its
  per-file results and order are identical, and it additionally folds each
  child's stderr into its stdout (a buffering artifact).  The sequential run
  keeps the streams correct; this is a throughput-only difference, not a
  behavior gap.
- **Bundle archive bytes:** `--archive`'s `.tar.gz` has the host's entry
  layout/order and extracts identically, but the bytes are not fixed (the
  host's TarWriter stamps entries with the current time).  The MTAP asset
  pack, which carries the assets, is byte-identical.
- **Build cache namespaces:** both compilers honor the shared
  `<data_root>/tmp/mtc-cache` root, but the self's entry layout
  (`<hash>/{key,binary}`) and key material differ from the host's
  (`programs|binaries/<2>/<sha>`), so cached artifacts are not shared across
  implementations.  Each compiler's cache still works independently.
- **Platform set:** the self's resolver targets `linux`, `windows` and `wasm`;
  the host's option parser also knows `darwin`, which the self does not target
  anywhere (no resolver variant, platform-pinned suffix, or build flags).  An
  invalid `--platform` value is still rejected on stderr as the host does.
- **Self-only `bindgen --options-json PATH`:** the host CLI cannot express the
  raw-binding option table (defines, tracked headers, prefixes, overrides,
  module imports); `tools/bindgen_parity.rb` extracts it and drives the self
  CLI.  The host reproduces the checked-in modules through its Ruby API/Rake
  tasks instead.  The self keeps the flag as its verification entry point.
- **Bindgen `tracy` (custom host generator):** the registry's `tracy` entry
  registers a `generator:` lambda that returns the hand-written
  `std/c/tracy.mt` verbatim, so there is no generated reference to match.
  `tools/bindgen_parity.rb` reports it as `custom` and requires 0 differ/0
  error; `steamworks` is a *generic* binding (helper header + tracked path) and
  now matches byte-for-byte.
- **Self-only `imported-bindings <name>|--all [--check]` command:** the host
  `COMMANDS` table has no such entry.  It is the self-host's binding-generation
  verification entry point (Track D) and stays; do not add it to the host
  command table.
- **`build --kind static|shared`:** the host's own path raises
  `NoMethodError: generate_header`, so there is no reference output.  The self
  archives a clean `ar rcs` (or links `-shared -fPIC`) and gives `public`
  top-level functions external linkage; no C header is generated (the host's
  generator is missing).  Executable C output is unchanged.

## Ledger

Last verified numbers; re-measure only the classes a change can move, and only
when the tree moved.  Target = the Definition of Done above.

| Gate | Live | Measured | Command |
| --- | --- | --- | --- |
| bootstrap fixed point | holds (`stage2.c == stage3.c`); **22 files / 0 failed** | session 72 (post-change `--fast` + 22/0) | `tools/bootstrap.sh -j 16` |
| `test/mt` | 60 files / 0 failed | session 72 (stage2) | `build/stage2/mtc test test/mt -I .` |
| examples / sdl3 | 49/49 same under the gate (15 top-level + 34 sdl3) | session 71 | `tools/gates.sh --only examples --run` |
| `sexpr lex` / `parse` | lex 739/739; parse 735 match / 0 differ / 4 host-rejected of 739 (counts include `tmp` fixtures) | session 72 | `ruby tools/sexpr_parity.rb lex\|parse -q --host-cache tmp/sexpr-host-cache` |
| `sexpr lower` | 683 match / 3 differ / 53 host-rejected / 0 self-rejected of 739 (the 3: documented `memory_stress_test` + `main.mt` artifacts, plus the pre-existing `woodeneye` double-literal row; the session-71 "684/2" was stale — the pre-change baseline measures the same 683/3/53/0) | session 72 (stage2) | `ruby tools/sexpr_parity.rb lower -q -j 16 --host-cache tmp/sexpr-host-cache` |
| `cli:parity` | **92 match / 0 differ / 0 pending** of 92 (case-backed; timings and `debug` node ids normalized) | session 72 (stage2) | `ruby tools/cli_parity.rb -q` |
| **`check` diagnostics** | **501 agree / 0 verdict / 0 position / 3 message of 504** (`std`+`examples`; the 3 are the documented `std/cli.mt` ×2 and `examples/reflection_advanced.mt` rows) | session 72 | `ruby tools/diag_parity.rb check -j 8 std examples`; byte-level: `ruby tools/check_parity.rb` |
| wasm preview | host=ok self=ok: entry/JS/WASM/HEAD/404/405, COOP/COEP, SIGTERM rc 0 | session 71 | `ruby tools/wasm_smoke.rb` |
| docs server | host=ok self=ok: reference/stdlib/source/highlight/search/assets/404, SIGINT rc 0 | session 71 | `ruby tools/docs_smoke.rb` |
| lint corpus | 632 agree / 3 differ of 635, hostfail 0, selffail 0; **43/43 rules, 13/13 fixers** (the 3 are documented deliberate rows) | session 72 (re-verified) | `ruby tools/lint_parity.rb -q` (`--host-cache`) |
| unused-import | 635/635 | session 71 | `ruby tools/unused_import_parity.rb` |
| LSP harness | 30/30 capabilities; 4 documented entries of 70 requests + 27 probes | session 71 (re-verified) | `tools/lsp_parity.rb record/compare --stress` |
| LSP project audit | canonical 6 (4 documented + 2 warm artifacts); non-canonical 4–5 ±drift | session 71 (canonical) | `tools/lsp_project_audit.rb --workspace ~/Projects/MilkTea/SimpleGame [--canonical]` |
| LSP recovery | 6/6 byte-equal | session 71 (re-verified) | `tools/lsp_recovery_probe.rb --check` |
| LSP edit latency | 4.9 ms median per `didChange`; `didOpen` ~52 ms cold | session 29 | `ruby tmp/lsp_edit_perf.rb --bin <bin>` (transient probe) |
| LSP valgrind | 0 errors over the harness drive; ~64 KB definitely-lost per 10-cycle soak (one-time index level) | session 71 (re-verified) | `tools/gates.sh --only valgrind_lsp --run` |
| LSP soak | 74–75 KB/cycle raw / ~28 KB/cycle least-squares at 200 cycles (meter; one-time index level) | session 71 (two runs) | `ruby tools/lsp_soak.rb --quiet` |
| formatter | 739/739 all three modes byte-identical | session 72 | `ruby tools/format_parity.rb all -j 16` |
| DAP | zero differing rows except the documented self-better frame0 row; the async-order F5 probe (`tools/dap_async_probe.rb`) proves launch → breakpoint → frame/locals → evaluate against real `lldb-dap` | session 71 | `ruby tools/dap_smoke.rb` (`--allow-skip` to waive a missing adapter); `ruby tools/dap_async_probe.rb` |
| imported bindings | **29 verified / 0 changed of 29** | session 72 (re-verified) | `build/stage2/mtc imported-bindings --all --check`; `ruby tools/imported_bindings_parity.rb` |
| bindgen | **33 match / 0 differ / 0 error / 1 custom of 34** registry entries (the custom entry is the host's `tracy` generator, which returns the checked-in module) | session 72 (re-verified) | `ruby tools/bindgen_parity.rb --self build/stage2/mtc` |

## Porting notes

Gotchas that cost rebuild cycles; apply them before writing code.

- `Analysis.resolved_expr_types` / `resolved_call_kinds` / `const_values` are
  keyed by **expression pointer** (`reinterpret[ptr_uint](ep)`); `Type`-valued
  maps (`types`, `type_alias_types`, `static_member_types`) are name-keyed.  A
  caller that re-parses must lint/analyze the *analysis' own AST* or rebuild the
  analysis from its parse (the fix engine does the latter per pass).
- `analysis.types` maps names (aliases resolved) → `Type`; enums/flags/variants
  are `ty_named` and also appear in `analysis.static_member_types`.
- `Map.get` returns `ptr[T]?` (nullable pointer); `Vec.get` returns
  `Option[ptr[T]]`; `read()` needs a narrowed *local*, not a struct field.
- Avoid language keywords as identifiers: `emit`, `match`, `type`, `link`,
  `include`, `event`, `final`, `inline`, `parallel`, `when`, `opaque`, `ref`,
  `own` (a function named `emit` failed to parse; a local `match` too).
- The self-host analyzer's binding ids are **name-keyed** where the host's are
  per-declaration (several gates note this; e.g. `dead-assignment`'s origin gate,
  the documentHighlight carry-forward).
- `resolve_cursor` facts must come from the loader-backed
  `analysis_for_document` / `ast_for_document`, never the standalone
  `check_source_file` (its `imported_modules` is null).  The host aborts a file
  at its first semantic error; probe one shape per file.

## Risks and notes

- **`lower` regressions:** the track is closed at 684/2/53/0 (the two
  documented artifacts).  A lowering-adjacent change can still move first
  differences deeper; re-run the sweep and keep the stopping rule (0 real
  differ, or a documented host artifact with a reproduction).
- **`deps`** is the largest single CLI subsystem (~3,000 lines); keep the port
  mechanical (module-per-file mirroring the Ruby layout) and use the host's
  `test/packages/*` as the spec.
- **emcc** may not be installed here; reproduce the host's detection/error text
  and verify the wasm path where emcc is available.
- **Throughput prices every gate** (3.9× self-to-host); Track G is optional but
  pays back across all future sessions.
- **History:** the full session records were removed from this file; they remain
  at `d8a199c7` and earlier.  If a compact digest of sessions 44–50 is wanted,
  add it in ≤30 lines rather than growing the file.

## Provenance

This file is the single self-host planning document; it absorbed the former
`docs/foundational-blockers-plan.md`, `docs/lsp-parity-plan.md`,
`docs/self-host-stress-todo.md` and the machine-local session plans on
2026-10-03 (session 25).  It was compacted to the current operational state in
session 50 (2026-11-08); the pre-compaction version, including §0a–§0k, §1–§7
and the Appendix, is at commit `d8a199c7`
(`git show d8a199c7:docs/self-host-plan.md`), and earlier originals are in git
history.  `projects/stress` parity (build, output and exit status identical)
was recorded done in the pre-compaction history.
