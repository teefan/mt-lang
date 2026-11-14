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

- [Status at a glance](#status-at-a-glance-session-73-2026-11-13)
- [Session 75 — refactoring safety suite](#session-75--refactoring-safety-suite)
- [Session 74 — decisions closed](#session-74--decisions-closed)
- [Session 73 — the `mtc test` CLI matrix](#session-73--the-mtc-test-cli-matrix)
- [Session 72 — the `check`/analyzer surface](#session-72--the-checkanalyzer-surface)
- [Handoff](#handoff-session-75)
- [How to start a work session](#how-to-start-a-work-session)
- [The program — tracks and stopping rules (all closed)](#the-program--tracks-and-stopping-rules-all-closed)
- [Deliberate differences (do not chase)](#deliberate-differences-do-not-chase)
- [Ledger](#ledger)
- [Porting notes](#porting-notes)
- [Risks and notes](#risks-and-notes)
- [Provenance](#provenance)

## Status at a glance (session 73, 2026-11-13)

| Area | State |
| --- | --- |
| Bootstrap fixed point | **holds** (`stage2.c == stage3.c`); self-test suite **22 files / 0 failed** |
| `test/mt` | **60 files / 0 failed** (session 72 on stage2) |
| Examples | **13/13** synchronous top-level examples build with stdout+exit identical to the host; the two `async_*` examples hit the host's own loop guard at rc 134 on both compilers (documented CPS-resume limit); `examples/sdl3` **34/34** builds; the raylib sample builds |
| `sexpr lex` / `parse` | 0 differ (lex **739/739**; parse **735 match / 0 differ / 4 host-rejected of 739**; counts drift with the tree and `tmp` fixtures) |
| `sexpr lower` | **684 match / 2 differ / 53 host-rejected / 0 self-rejected of 739 files** (session 72) — the two differ are the documented `memory_stress_test` (leaked auto-lifetime) and `main.mt` (`--sexpr` loop guard) artifacts.  Session 72 closed the third row (`woodeneye`, hidden in `hostfail`) by fixing `%g` double rendering (now Ruby's round-trip `Float#to_s`), module-qualified named types in IR dumps, and an index literal taking the assignment's element type |
| `cli:parity` | **224 match / 0 differ / 0 pending** of 224 cases (`--timings` values, `debug`'s Ruby node ids and the synthesized test-runner path normalized; 43 `test` cases plus the second-batch sweep: global extraction, resolution flags, per-command operand models, missing/empty operands, completions/std/snapshot/cache/lsp/dap/bindgen/deps) |
| **`check` diagnostics (new)** | **501 agree / 0 verdict / 0 position / 3 message of 504** files (`tools/diag_parity.rb check`; the 3 message rows are the documented `std/cli.mt` ×2 and `examples/reflection_advanced.mt` rows).  Before this session: 44 verdict, 177 position diffs and a wholly different rendering. |
| Linter corpus | **631 agree / 4 differ** of 635 (hostfail 0, selffail 0); **43/43 rules, 13/13 fixers**.  The 4 rows are documented: two self-only `redundant-cast` in `std/cli.mt`, the self-only `prefer-let` cluster in `std/fs.windows.mt` (the host loses its facts on a platform-pinned root), the host-only `constant-condition` in `examples/reflection_advanced.mt`, and the host-only positionless `prefer-or-pattern` in `projects/mtc/src/mtc/main.mt`. |
| LSP | harness **30/30 capability keys + 4 documented entries**; project audit canonical **6** differing entries (4 documented rows + 2 builtin-hover warm artifacts), non-canonical 4–5 with ±drift; recovery **6/6**; `milkTea/debugInfo` **byte-equal**; valgrind **0 errors**; edit latency **4.9 ms median**; soak **74–75 KB/cycle raw / ~28 LS at 200 cycles** (meter, one-time index level documented) |
| DAP | **zero differing rows** on the `dap_smoke` matrix, except the documented self-better `lldb-real frame0 name`; the real lldb-dap bridge closes the VS Code F5 launch deadlock (configurationDone no longer waits for the launch response), proven by `tools/dap_async_probe.rb`; desktop F5 smoke passed session 74 |
| Formatter | **739/739** byte-identical in all three modes (`:canonical`, `:preserve`, `:tidy`; counts drift) |
| Imported bindings | **29/29 verified** against the host generator and the checked-in modules (re-verified session 72) |
| Bindgen reproducibility | **33 match / 0 differ / 0 error / 1 custom of 34 registry bindings** (re-verified session 72).  The one custom entry is `tracy`, whose host registry generator returns the hand-written checked-in `std/c/tracy.mt` verbatim. |
| Compiler throughput | **`emit-c` 17.1 s vs the host's 54.3 s** (3.2x faster); full `build` 32.7 s vs 76.3 s; `bootstrap --fast` 2.6 min (session 72, after making the variant lookup non-quadratic).  C output byte-identical |
| **Refactoring safety (new)** | structural guard: 103 edges / **0 layering violations**; 13 frozen naming deviations; **35 unused + 6 test-only** public declarations; 5,196 duplicated lines; 35 functions ≥ 200 lines; 0 markers.  Protocol `docs/refactoring.md`; baseline `tools/refactor_baseline.json`; one command: `tools/gates.sh --areas refactor --run` |

Rough completion against the per-track Definition of Done: **100%**.  The
self-hosting foundation, `lower` dump parity, the CLI behavior matrix (including
the `mtc test` surface and the command-surface sweep added in session 73), wasm,
docs, the linter corpus, the imported bindings and bindgen reproducibility are
done, and session 72 added the analyzer/`check` surface that no gate had
measured.  The only residuals are the documented `tracy` custom-generator entry
and the optional desktop F5 smoke.  Track G (throughput) closed in session 72:
the self is now faster than the host.

## Session 75 — refactoring safety suite

The parity program proves behavior, not shape; a refactoring pass had no
structural oracle and `dev_tests` never ran for source edits.  This session adds
the safety suite (protocol: `docs/refactoring.md`):

- **`RefactorGuard`** (`lib/milk_tea/tooling/refactor_guard.rb`, CLI
  `tools/refactor_guard.rb`, baseline `tools/refactor_baseline.json`, 11 tests in
  `test/tooling/refactor_guard_test.rb`) checks layering ranks (an import may
  target an equal or lower rank; same-rank cycles allowed), naming (files,
  snake_case functions, PascalCase types, UPPER_SNAKE consts), dead exports
  (cross-tree textual index), duplication (normalized 12-line windows), size,
  markers, and test-tree counts.  `--check` is the hard invariant set; `--strict`
  adds new dead exports; `--ratchet` adds code/duplication growth and test-count
  drops.  The rank table was calibrated against the real import graph: `c_naming`
  ranks with `semantic` (it mangles semantic types), `linter`/`formatter` share a
  rank (fix candidates use tidy), `pretty_printer` ranks with `ir`, and
  `imported_bindings` with `formatter`; the result is 0 upward edges.
- **Gates**: new hard tier-1 `refactor_guard` and `guard_tests`; `dev_tests` now
  runs for every self-host source area; `cli_parity`, `sexpr lex` and
  `sexpr parse` are promoted from meter to hard (all at exact parity); the
  previously unwired `check_parity` oracle is an analyzer meter.  New explicit
  area: `tools/gates.sh --areas refactor --run` = dev build, dev tests, guard,
  `test/mt`, CLI parity, scoreboard.  Stale labels/counts were corrected and the
  duplicate dead `wasm_smoke`/`docs_smoke` arms removed.
- **Baseline (session 75)**: 131 files / 154,257 lines / 122,711 code lines;
  103 import edges, **0 layering violations**; 13 frozen naming deviations
  (1 PascalCase function, 12 lowercase consts); **35 unused + 6 test-only**
  public declarations; 5,196 duplicated lines (781 window clusters); 35 functions
  >= 200 lines; 12 files >= 2,000 code lines; 0 markers; test trees 22 / 60.
  The dead-export candidates and long-function list are the refactor's first
  triage targets, not defects introduced here.
- **Verification**: guard tests **11/11**; `--check`, `--check --strict`,
  `--check --ratchet` all green on the frozen tree; `rake test:tooling`
  picks the new test up; `bash -n tools/gates.sh`.  The first full
  `tools/gates.sh --areas refactor --run` passed **6/6 rc=0 in 2m34s**
  (dev build; dev suite 22/0; guard ok; `test/mt` 60/0; CLI 224/224;
  scoreboard meter).  29 stray `__mt_test_runner_*` sidecars were removed.

## Session 74 — decisions closed

Docs-only session.  Session 73 landed as `747050f6` (the CLI matrix and the
command-surface fixes; its ledger test-matrix count is 43, not 42 — the
second-batch `test-package-no-operand` case).  The two remaining LSP decisions
are closed rather than ported:

1. **Ref-lifetime modelling — do not port.**  The host rewrites a bare field
   `ref[T]` into `ref[@_mt_N, T]` (`type_declaration.rb:516-522`) and leaks that
   synthesized name into `lower` dumps and LSP details.  Reproducing it would
   close the `memory_stress_test` `lower` artifact and the audit's `mst@224:18`
   row, but it reproduces an internal-name leak; under the "parity or better"
   bar the self's declared `ref[T]` is the better answer.  Both rows stay in
   *Deliberate differences*.
2. **Imported enum/flags member locations — keep the host behaviour.**  For
   `alias.Enum.member` the self resolves the member text and drops the location,
   matching the host's classifier miss.  Pointing at the imported declaration is
   legal but is a self-better extension with no measured user benefit; not done.
3. **Desktop VS Code F5 smoke — passed.**  Scratch workspace `tmp/f5-smoke/`
   (gitignored) with `milkTea.dap.serverPath` set to `build/stage2/mtc`: F5 built
   the program through the DAP server's build-on-launch, attached the real
   `lldb-dap`, printed `f5 smoke x = 3` and exited 0 in the Debug Console.
   Extension-side finding: the extension declares only
   `activationEvents: ["onDebug:milk-tea"]`, which VS Code 1.146 does not honor
   for the adapter-descriptor lookup, so F5 in a fresh window fails with
   "Couldn't find a debug adapter descriptor"; opening a `.mt` file
   (`onLanguage:milk-tea`) activates it and F5 works.  That is packaging in the
   extension repo, not a compiler or DAP defect.

## Session 73 — the `mtc test` CLI matrix

`mtc test` was the last CLI command with almost no matrix coverage: 92 cases,
one of them `test-missing-operand`.  The host and self both implement the whole
surface (`--format human|tap|junit`, `--jobs`, `--mem`, `--sanitize`,
`--timeout`, `-n/--name`, `--locked`, `--frozen`, file and directory operands,
compile-fail fixtures, `@[expect_fatal]`), but nothing measured it.  Session 73
added 42 cases and four fixture trees (`testtree`, `testjobs`, `testslow`,
`badlex`) and fixed the divergences they exposed.  `mtc test` now matches the
host byte for byte across the test cases: **134/134** (224/224 after the
second batch below).

Fixes in `projects/mtc/src/mtc/main.mt`:

1. **Module roots.**  The synthesized runner was analyzed with only the
   explicit `-I` roots plus a `src/mtc` walk-up, so a test importing `std.*`
   failed unless `-I` named the checkout (`module not found: std.thread`).  The
   runner build now mirrors the host's `module_roots_for`: `-I` roots, the
   discovered project root, the enclosing package's source root, the compiler's
   own roots and the cwd's ambient roots (`add_module_roots`).
2. **Two-phase flag extraction.**  The host pulls the test-limit flags out
   first, then parses build options, so `test --bogus --timeout 0 f.mt` reports
   `--timeout`.  The self was strictly left-to-right and reported `--bogus`.
   The command now extracts `-n/--timeout/--mem/--jobs/--sanitize/--format`
   first (stopping at `--`) and parses the rest afterwards.
3. **Machine-mode buffering.**  With `--format tap|junit` the host buffers the
   whole human run and discards it (only TAP/JUnit is emitted), so a
   `main`-defining file or a test taking parameters prints nothing to stderr;
   the self leaked those messages.  They are now machine-suppressed, and the
   exit code and empty `1..0` report still match.
4. **Directory headers.**  The host prints `# <file>` before running each
   discovered file, including one that then fails validation.  The header moved
   from the file runner into the directory loop (human mode only).
5. **The build-error split.**  The host guards a build failure only inside a
   directory run (`FAILED - <file> (build error)` + one diagnostic line on
   stderr, a `(build error)` row in machine mode) and lets it escape a file
   operand (one diagnostic line on stderr, no machine report).  The self
   reported every build error as a per-test/FAILED-on-stdout result.  A new
   `TestFileOutcome` distinguishes `build_error` from `test_failed`, and
   `report_runner_build_error` reproduces the host's channel matrix.  The
   one-line form follows the host's `ErrorFormatter` after it has lost the
   runner source: `error[code]: message -- path:line:col` for semantic errors,
   the bare message for `module/error`, `<message>: <path>` for `load/error`
   (new `first_error_line`); a C-compiler message prints verbatim with the
   host's newline behavior (`eprint_message`).
6. **`@[expect_fatal]` was broken.**  The synthesized death runner used
   `match test():` on a `void` call; that exits 232 even when the test returns,
   so a death test that does *not* abort was reported `ok`.  It now mirrors the
   host's `death_test_runner_main` (call, then `return 0`), so `ok` requires a
   real abort.  A death runner that fails to build is the file's build error
   (as the host's escaping exception makes it), not a per-test `FAIL ...
   (build error)`.
7. **`--frozen` / `--locked` were no-ops.**  `--frozen` now runs the host's
   up-front `ensure_current_lockfile!` (`package manifest not found ...` /
   `package.lock is missing ...`), and `--locked` resolves the package graph
   per test file inside the runner build (`apply_package_resolution_result`),
   so a package without a lock is that file's build error — both match the
   host, including `test --frozen <file>`.
8. **Cleanup/order.**  The runner build uses `options.platform` instead of a
   hardcoded linux; the test-command parser handles `--` like the host
   (including keeping the flags after it positional).

Harness: `normalize` collapses `<any dir>/__mt_test_runner_<pid>` to
`<RUNNER>` — the pid is process-local and the host builds the runner binary in
`Dir.tmpdir` while the self keeps it beside the source.  That directory is a
path-only difference in a spawn-failure message; the self cannot move the
binary to `/tmp` without losing `compiler_root_candidates`' std root (its
runtime root discovery walks up from the executable), which
`projects/mtc/test/module_roots_test.mt` verifies.  Recorded under *Deliberate
differences*.

Verification: `cli:parity` **134/134** (224/224 after the second batch below);
dev self-tests **22 files / 0 failed**; `test/mt` **60/0**; bootstrap fixed
point holds.

### Second batch — the command-surface sweep

A systematic host-vs-self sweep then covered the rest of the CLI: all 74 help
variants (`help CMD`, `CMD --help`, `CMD -h`), global flag extraction, every
command's operand/flag model, and the success paths of the less-covered
commands.  It found and fixed:

1. **Global extraction order.**  The host strips `-v/-q/--color` before the
   include pass, so a global flag between `-I` and its value changes what the
   include pass consumes; the self was a single left-to-right pass.  `--color`
   with no value now prints the host's message without `(got )`, the
   `--include-path` missing-value message uses the actual flag, and the
   unsupported-command error names the *first* include flag.  Deliberate
   difference: the self's include pass stops at `--`, so `run app -- -I x`
   forwards the argument (the host swallows it).
2. **Resolution flags on parse/lower/emit-c/check/lint/debug.**  The host's
   `extract_resolution_flags!` handles `--locked`, `--frozen` and `-Werror` for
   parse/lower/emit-c/check/debug; only check accepted them (and ignored them).
   Added `ResolutionFlags` + `extract_resolution_flags_span`,
   `validate_source_operands`, `ensure_current_lockfile_at` and
   `apply_locked_resolution`, wired into all six commands with the host's
   messages and exit codes (`package.lock is missing`, `package lock not found`;
   check reports a locked failure as a diagnostic and a `1 error found`
   summary).  lint's `--frozen` now checks every expanded path and `--locked`
   resolves the graph per file.
3. **Operand models.**  `lex` now mirrors the host (any argument is the path
   when none is set, a second is `unknown option:` on stderr; the self-only
   `--machine` flag was removed).  `lower` accepts the host's multiple operands
   and expands directories (a header prints only after a successful check).
   `debug` expands operands, debugs the first, ignores extra non-flag operands
   and accepts `-Werror`.  The self-only `--root` alias was removed everywhere
   (the host documents `-I`/`--include-path`); parse/emit-c/debug lost the
   self-only `--platform` (build/run/test still take it, as the host does).
4. **Empty and missing operands.**  check/lint/debug print the host's
   `no .mt files found in <label>` (debug returns 1); parse/lower/emit-c return
   an absolute `source file not found`, while check/lint/debug/format/lex use
   the operand as given; format's missing-file error moved to stderr with the
   host's text.
5. **build/run/run-module.**  Missing option values use `missing value for
   <flag>` + usage; invalid profiles print `unknown profile <v>; expected
   debug|release` on stderr; invalid platforms use the host's format (the
   self's list omits `darwin`, a documented difference).  `run-module` parses
   the host's build options (unknown flags are errors), reports
   `missing module name` + usage, writes its not-found error to stderr, and
   handles `--` like the host.
6. **completions/std/snapshot/cache.**  The completion scripts were a stale
   19-command subset in the wrong order; they now use the host's 23-command
   `COMMANDS` table (bash/zsh/fish byte-equal).  std's errors moved to stderr
   (with the command help where the host prints it).  `snapshot` now builds its
   semantic overlay from the LSP's own token pass
   (`semantic_tokens.snapshot_entries_for`) instead of a separate scanner, so
   the HTML is byte-identical; its errors use stderr and the expanded theme
   path.  `cache` with no subcommand prints the host's message + help.
7. **lsp/dap.**  Both validate their flags exactly like the host (`lsp` levels
   with Ruby's `inspect` formatting, unknown options/unexpected arguments;
   `dap`'s adapter-path existence check).  The LSP default level is the host's
   `warn` (the CLI lifecycle lines are gone), and the DAP server no longer
   aborts on a non-pollable stdin (`mtc dap < /dev/null` exits 0 like the host)
   instead of `uv_poll_init failed` + SIGABRT.
8. **bindgen/deps.**  bindgen consumes MODULE/HEADER before options, uses the
   host's `missing module name or header path`, `unknown bindgen option` and
   `missing value for <flag>` messages + help, and maps a spawn ENOENT to
   `clang not found: <bin>`.  deps' `fetch` parses flags before the path (so
   `fetch --bogus` is the host's unknown-option error), and add/remove/update
   no longer append a help block to the raised `missing package path`.

Matrix: 134 -> **224 cases**, all matching.  Remaining documented differences
in this class: the platform list (`darwin`) and the self's `--`-forwarding of
include flags.

Verification: `cli:parity` **224/224**; dev self-tests 22/0; `test/mt` 60/0;
bootstrap fixed point; bindgen 33/34 + 1 custom; DAP zero differing rows; LSP
harness 4 documented entries + recovery 6/6; lint corpus 631/4 (the
`std/fs.windows.mt` row is a pre-existing host-facts loss, reproduced at HEAD).

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

The same session then closed the last real `lower` residue, which had been
sitting in the `hostfail` bucket:

6. **`double` rendering used `%g`** — the IR formatter printed six significant
   digits, so `std/math`'s `PI` dumped `3.14159` where Ruby's `Float#to_s` gives
   the round-tripping `3.141592653589793`.  `ir_formatter.double_to_str` now
   delegates to `float_text.double_to_str` (the existing Ruby-compatible
   renderer, already used by the C backend and the LSP AST dump).
7. **Named types rendered unqualified in IR dumps** — the host interpolates its
   type objects, whose `to_s` carries the defining module
   (`examples.sdl3.demo.woodeneye.Player`); the self used the LSP *display* form
   (`Player`).  Added `types.type_to_qualified_string` (recursive into nullable
   / generic / imported arguments) and pointed `render_type` at it.  The display
   form is untouched — `type_to_string` still drops the module for the LSP and
   diagnostics, which is what those surfaces need.
8. **An index literal took the assignment's element type** — `infer_expr`'s
   `expr_index_access` inferred the index with the ambient
   `expected_type_hint`, so `state.players[i].color[0] = ubyte<-…` typed that
   `0` as `ubyte` where the host types every index `int`.  The index is now
   inferred with the hint cleared (the host's `infer_index_access` passes no
   expected type).

Result: `lower` **684 match / 2 differ / 53 host-rejected / 0 self-rejected**,
exactly the two documented host artifacts — Track A's stopping rule.  The three
files that had been counted as differs are now identical or reduced to the
documented artifacts; line-level residue on the formerly-differing files fell by
roughly 1,160 lines.

Verification: bootstrap fixed point, 22/0 self-tests, `test/mt` 60/0, lower
684/2/53/0, lex 739/739, parse 735/0/4, `cli:parity` 92/92, `check` diagnostics
501/0/0/3 of 504, lint corpus 501/3 of 504 on `std`+`examples` (the documented
rows), formatter 739/739 in all three modes.

## Handoff (session 75)

**Read this first, then *Status at a glance* and the Ledger.**  The parity
program stays closed, and session 73 closed the last *measurement* gaps: the
`mtc test` CLI surface, then a command-surface sweep over every remaining
command.  The matrix is now **224/224**, and the fixes it forced are in the
commands themselves (see the session-73 section).

Session 75 added the refactoring safety suite (structural guard, gate wiring,
committed baseline); use `tools/gates.sh --areas refactor --run` and read
`docs/refactoring.md` before changing the self-host's shape.

Session 73's changes landed as `747050f6`:

| Area | What |
| --- | --- |
| `tools/cli_parity.rb` | 43 `test` cases, four test fixture trees, and a second batch (global extraction, resolution flags, operand models, missing/empty operands, completions/std/snapshot/cache/lsp/dap/bindgen/deps) — 224 cases; `normalize` collapses the synthesized runner path. |
| `projects/mtc/src/mtc/main.mt` | Test-command fixes (runner roots, machine buffering, build-error channels, `expect_fatal`, `--frozen`/`--locked`, requested platform) plus the second batch: host-shaped global extraction, resolution flags on parse/lower/emit-c/check/lint/debug, host operand models, empty/missing-file messages, build/run/run-module errors, completions, std, snapshot, cache, lsp/dap validation. |
| `projects/mtc/src/mtc/lsp/server.mt`, `lsp/semantic_tokens.mt` | LSP default level `warn` and no CLI lifecycle logs; the snapshot semantic overlay now reuses the LSP token pass (`snapshot_entries_for`); the old standalone snapshot scanner was removed. |
| `projects/mtc/src/mtc/dap/server.mt` | Non-pollable stdin exits 0 instead of aborting on `uv_poll_init failed`; the unsupported-backend fallback logs at debug. |
| `projects/mtc/src/mtc/bindgen.mt`, `packages/manager_cli.mt` | bindgen maps a spawn ENOENT to `clang not found`; deps `fetch`/add/remove/update follow the host's flag/help semantics. |
| `tools/gates.sh` | `cli_parity` label 92 -> 224. |

### Verified numbers (session 73)

`cli:parity` **224 match / 0 differ / 0 pending**; dev self-tests **22 files /
0 failed**; `test/mt` **60/0**; bootstrap fixed point holds; bindgen
**33 match / 0 differ / 0 error / 1 custom of 34**; DAP **zero differing rows**;
LSP harness **30/30 + 4 documented entries**, recovery **6/6**; lint corpus
**631 agree / 4 differ of 635** (the four documented rows, including the
pre-existing `std/fs.windows.mt` host-facts loss).

### How to start

Build the dev compiler
(`ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev`, ~35 s),
run `tmp/mtc-dev test projects/mtc -I . --timeout 120`, and measure only the
class the change can move with the matching harness.  For the test command that
is `ruby tools/cli_parity.rb --self tmp/mtc-dev -f '^test-'`; the full matrix is
`ruby tools/cli_parity.rb -q`.  Run the tier-2 proofs once on frozen sources:
`tools/gates.sh --areas cli --run` (bootstrap, `test/mt`, `cli_parity`; logs
under `tmp/gates/`).  **Do not replay the ledger's baselines unless the tree
moved.**

### Open items, in priority order

1. **Track G follow-ups are recorded, not pending.**  The post-fix profile is
   flat; `String.as_str()`'s per-call UTF-8 revalidation (~7%) is a documented
   invariant, and the ~2% scans are over small collections.  Reopen only with a
   fresh `perf record` showing a hotspot.
2. **No manual items remain.**  The desktop F5 click-through passed (session 74,
   above); it also found an extension-packaging defect: `activationEvents:
   ["onDebug:milk-tea"]` is ignored by VS Code 1.146, so the extension must be
   activated by opening a `.mt` file first.  Fix that in the extension repo
   (add `onLanguage:milk-tea`); it is not a compiler item.  The LSP
   ref-lifetime and imported-member-location decisions are closed.

**Do not chase** the documented differences — the 2 `lower` artifacts, the
documented `check`/linter rows (3 `check` messages, 4 linter corpus files), the
LSP audit rows, the DAP frame0 row, the test-runner binary directory, or the
self-only/better behaviours.  They are listed in *Deliberate differences* with
the reason each is a host artifact or a deliberate extension.

### Session records (historical)

The per-session batch logs (sessions 51–71) are not kept in this file; none is
pending work.  The full text is recoverable from git history (`git log -p --
docs/self-host-plan.md`), and the pre-compaction snapshot through session 50 is
at `git show d8a199c7:docs/self-host-plan.md`.  Current state lives in *Status
at a glance* and the Ledger; the causes that still matter are in the track
sections and *Deliberate differences*.

## How to start a work session

### Entry points

| Workstream | Read | Verify with |
| --- | --- | --- |
| `lower` dump parity (**closed**, keep at 0 real differ) | *The program* Track A; `docs/language-design.md` | `ruby tools/sexpr_parity.rb lower -q -j 16 --host-cache tmp/sexpr-host-cache` (~1 min warm, ~4 min cold) |
| CLI behavior parity | Track B; `tools/cli_parity.rb --help` | `rake "cli:parity"` |
| `mtc test` (matrix closed) | the session-73 section; `docs/testing.md` | `ruby tools/cli_parity.rb --self build/stage2/mtc -f '^test-'` (43 cases) |
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
| Refactoring pass | `docs/refactoring.md`; `tools/refactor_guard.rb --help` | `tools/gates.sh --areas refactor --run`; `ruby tools/refactor_guard.rb --check --strict --ratchet` |
| Example builds | Track H | per-family sweeps (15 top-level, `examples/sdl3` 34/34, a raylib sample) |

### Verification tiers

Iterate cheap, prove once:

- **Tier 1 — per edit.**  Build the dev compiler
  (`ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev`, ~35 s)
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
- **Structural changes**: run `ruby tools/refactor_guard.rb --check` with the
  behavioral gates (`docs/refactoring.md`).  Refresh
  `tools/refactor_baseline.json` only for a deliberate structural change, never
  to silence a check.
- **Generated binaries are not deliverables** — clean stray runners and scratch
  artifacts; gitignored gate output under `tmp/` and `build/` may stay.
- Commit trailer: `Co-authored-by: CommandCodeBot <noreply@commandcode.ai>`.

### Phase order and current position

0. **Hard build parity** — **DONE** (session 49; re-verified session 50): all
   15 top-level examples build, the synchronous set's stdout+exit is identical,
   `examples/sdl3` 34/34, `test/mt` 60/0.
1. **`lower` dump parity** — **CLOSED** (session 63): 665/2/51/0 of 718, the
   two residuals are documented host artifacts.  See Track A.
2. **CLI behavior parity — CLOSED (session 68; 224/224 after session 73 added
   the `mtc test` matrix and the command-surface sweep)**.  Sessions 64–68 landed `debug`, the `test` argument
   forms, `toolchain bootstrap|tools|doctor`, `build --kind static|shared`, the
   bindgen nullable flags, `--bundle`/`--archive`, wasm build/preview, `docs`,
   `deps` and `--locked`/`--frozen`; session 73 closed the test command's own
   surface (module roots, machine-format buffering, build-error channels,
   `expect_fatal`, `--frozen`/`--locked`).
3. **Linter corpus residue — CLOSED (session 69; re-measured session 73)**:
   631 agree / 4 differ of 635 (the four documented rows), **43/43 rules and
   13/13 fixers**.
4. **Imported bindings / bindgen** — **CLOSED**: imported bindings 29/29 and
   bindgen reproducibility 33/34 with the one documented custom generator
   (`tracy`).
5. **Final verification** — Track H, **passed session 71**.
6. **Refactoring safety suite** — **LANDED (session 75)**: behavioral gate set
   (hard exact-parity oracles + `dev_tests` on every source area) and the
   structural guard with a committed baseline; see `docs/refactoring.md`.

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
(branch `selfhost`). The parity program is closed (Track H passed; session 72
closed the analyzer/`check` surface, the last real `lower` residue, and Track G
throughput; session 73 closed the `mtc test` CLI matrix and the command-surface
sweep — 224/224): start from
this file's Handoff, then the remaining optional items. Work in tiers:
iterate on the dev compiler
(ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev, ~35 s;
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
residue (session 73); Track H's final matrix passed, session 72 measured the
one surface no gate had covered (`check`) and cleared it, and session 73
measured and cleared the `mtc test` surface.  There is no ranked open parity
work left; the track sections below are the stopping rules to preserve.**

Confirmed scope decision: **all** unported CLI subsystems are in scope (`deps`,
`docs`, wasm/emcc + preview, `--bundle`/`--archive`, `--jobs`, toolchain
bootstrap/tools, `--kind static|shared`, the bindgen policy flags), and all are
now ported.  Tracks A–D reached their targets; LSP/DAP/formatter are closed at
their documented differences.  Anchor by symbol names, not line numbers —
lines drift.

### Track A — `lower` dump parity (CLOSED: 684/2 of 739)

Current set: **684 match / 2 differ / 53 host-rejected / 0 self-rejected of 739
files** (session 72).  The host-rejected bucket is `external` and platform-pinned
files; the count drifts with the tree and `tmp` fixtures — quote the set.

The two counted differs are the documented host artifacts, not work:

1. **`examples/memory_stress_test`** — the host's leaked `ref[@_mt_0, T]`
   lifetime; the self renders the declared `ref[T]` (see *Deliberate
   differences*).
2. **`projects/mtc/src/mtc/main.mt`** — the `--sexpr` loop-guard artifact (the
   dump exceeds the generated C loop guard's UTF-8 scan); documented under
   *Deliberate differences*.

Session 72 also removed the third row that had been hiding in the `hostfail`
bucket (`examples/sdl3/demo/woodeneye`): `%g` double rendering, unqualified
named types in IR dumps, and an index literal inheriting the assignment's
element type.  See the session-72 section.

Track A reached its stopping rule: **0 real differing files**.  Keep lex/parse
at 0-diff and re-measure both after any lowering-adjacent change.

### Track B — CLI parity (224 cases; 224 match, 0 pending; **closed**)

The **original 65-case behavior matrix is byte-equal** (session 64; `--timings`
values and `debug`'s Ruby node ids normalized).  `debug`/`test`'s argument forms
and the bundle/archive cases closed there.  The
fixed `pkg` fixture now builds and runs a real program (the old fixture used a
bare `print`, so its build/run cases only compared a semantic-error path).

Session 65 replaced the regex allowlist with case-backed pending metadata;
session 67 closed `toolchain doctor`, `run --bundle`, `run --archive`,
`build --platform wasm` and the wasm preview; session 68 closed `deps` and the
locked/frozen build, so the matrix was **92 cases / 92 match / 0 differ /
0 pending**.  Session 71 added the bare `build`/`run` package-root forms (the
dispatcher no longer blocks `parse_source_operand`'s discovery) and their three
cases.  Session 73 added the **43-case `mtc test` matrix** (file/directory
operands, human/TAP/JUnit, filters, death tests, `--timeout`/`--mem`/`--jobs`/
`--sanitize`, `--locked`/`--frozen`, validation errors, the build-error
channels and a package-root run), then the second-batch sweep (global
extraction, resolution flags, operand models, empty/missing operands, the
remaining command surfaces), so the matrix is now **224 cases / 224 match /
0 differ / 0 pending** — the whole CLI surface is byte-equal.  A future gap adds
a `pending:` case, and a pending case that starts matching must be promoted (the
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
4. **Harness — closed.**  224/224 cases match with no pending entries; a future
   gap adds a `pending:` case (the harness fails when one starts matching).
   Timing values are normalized (wall-clock measurements never compare
   byte-for-byte), as are `debug`'s process-local node ids and the synthesized
   `__mt_test_runner_<pid>` path; the report structure is.

Session-64 landed `toolchain bootstrap|tools`, `build --kind static|shared` and
the bindgen nullable flags (the library-build and self-only flag caveats are in
*Deliberate differences*).  Session 67 closed `toolchain doctor` to
byte parity (60 rows: 8 tools + 18 vendored sentinels + 34 raw-binding
headers), `run --bundle`/`run --archive` and `build --platform wasm`; session 68
closed `deps` (5 cases) and locked/frozen build (2), emptying the pending set.

Session-63 CLI flips: all 37 original diffs except `debug` — lex/parse/lower/
emit-c diagnostics and formats, check/lint/format/debug messages and channels,
package build/run entry points, `new`, `completions`, `std`, `test`, `cache`,
`toolchain`, `snapshot`.  Session 64 closed `debug` (shared renderer) and
`test`'s argument forms.

### Track C — linter corpus residue (631/4 of 635; 43/43 rules)

State: **631 agree / 4 differ of 635, hostfail 0, selffail 0** (session 73
re-measure; the file count drifts with the tree).  The four rows are documented
under *Deliberate differences*: two `redundant-cast` rows in `std/cli.mt` (the
self's flow-refined type exposes a genuinely redundant nullable-pointer cast
the host's unrefined fact misses), the self-only `prefer-let` cluster in
`std/fs.windows.mt` (the host loses its semantic facts on a platform-pinned
root, so it cannot evaluate the rule; the self analyses the root — verified
pre-existing at HEAD), the host-only `constant-condition` in
`examples/reflection_advanced.mt` (the host's inline-if non-chosen branch lacks
a binding id, so its constant propagation keeps `count = 0`), and the host-only
positionless `prefer-or-pattern` in `projects/mtc/src/mtc/main.mt` (the host
matches adjacent arms on a node whose source identity the self does not share;
its fix engine makes no change).  The session-73 test-command work removed the
old self-only `redundant-cast` row on the deleted `--machine` lex line.

Session-69 linter batch (571/63 -> 631/3).  Closing summary by rule (pairs are
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
a slope, and the loader's small `qname_to_str` strings remain).  Both remaining
documentation decisions are **CLOSED (session 74)** — see that section:

- **Ref-lifetime modelling — not ported.**  The host's synthesized
  `ref[@_mt_N, T]` lifetime in a field detail (`mst@224:18`), where the self
  renders the declared `ref[T]`.  Porting
  `lib/milk_tea/core/semantic_analyzer/type_declaration.rb:516-522` would close
  that row and the `memory_stress_test` `lower` artifact, but it reproduces an
  internal-name leak; the declared `ref[T]` is the better answer.
- **Imported enum/flags member locations — kept host-identical.**  For
  `alias.Enum.member` the self resolves the member text and deliberately drops
  the location (matching the host's classifier miss).
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
evaluate `3`.  The protocol path is closed, and the desktop F5 click-through
passed in session 74 (see that section).  The only residue is extension
packaging: `activationEvents: ["onDebug:milk-tea"]` is ignored by VS Code
1.146, so the extension only activates once a `.mt` file is open.

### Track G — compiler throughput (CLOSED: the self is now faster than the host)

**Measured (session 72).**  `perf record` on `emit-c` of
`projects/mtc/src/mtc/main.mt` put **46.3% of all samples in one function**:
the `collect_generic_variants` scan, reached through
`c_backend.expr_result_type` -> `collect_gv_from_expr` -> `collect_gv_from_stmts`.
The cause was not the scan itself but *where it ran*:
`find_variant_decl_by_c_name` rebuilt the whole variant lookup - a recursive
walk of every declaration and expression in the program - **on every call**.
That function runs once per type registered for an equality helper, so `emit-c`
was quadratic in program size.

**Fix.**  Build the lookup once in `generate_c` into a new
`Emitter.variant_decl_by_name` map (`program.variants` plus the concrete
`Option`/`Result` instances lowering keeps outside the IR), and have
`find_variant_decl_by_c_name` / `emit_variant_equality_helpers` read it.  The
duplicate `collect_generic_variants(program)` call in `generate_c` folds into the
first one, and `emit_variant_equality_helpers` drops its now-unused `program`
parameter.

**Result.**  C output is byte-identical: diffing the two `emit-c` dumps shows
zero differences outside the intentionally removed parameter.

| Measure | Before | After | Host |
| --- | --- | --- | --- |
| `emit-c` of `main.mt` | 260.6 s | **17.1 s** (15.2x) | 54.3 s |
| full `build` (incl. `cc`) | n/a | **32.7 s** | 76.3 s |
| `tools/bootstrap.sh --fast` | ~19 min | **2.6 min** | n/a |

The self now outruns the Ruby host on both measurements (3.2x on `emit-c`,
2.3x on a full build).  Behavior is unchanged: lower 684/2/53/0, CLI 92/92,
self-tests 22/0, `test/mt` 60/0, examples 49/49, and the bootstrap fixed point
holds.

**Probed and deliberately not done.**  The post-fix profile is flat (no symbol
above 12%).  `String.as_str()` revalidates UTF-8 on every call (~7% of
`emit-c` self time via `str_is_valid_utf8`, plus part of `str_byte_at`'s 12%).
Caching validity inside `String` would save ~1-2 s of a 17 s run, but
`docs/language-design.md` requires the borrowed-text boundary to enforce UTF-8,
so the check is a documented invariant, not an oversight.  The other visible
costs (`lowering.find_func_in_source`, `find_imported_analysis`, ~2% each) are
linear scans over one module's declarations or the program's analyses - the
collections are small, and caching them would add state for no measured win.
Nothing further is worth pursuing without a fresh profile showing a hotspot.

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
- **`check` diagnostic residue (3 rows, all deliberate):** the new `check` sweep
  (`tools/diag_parity.rb check`) reaches **0 verdict / 0 position** differences
  over `std`+`examples`; its 3 message rows are exactly the `std/cli.mt`
  `redundant-cast` pair and the `examples/reflection_advanced.mt` host-only
  `constant-condition` documented below, seen through `check`'s renderer.
- **Linter corpus residue (4 rows, all deliberate):**
  - `std/cli.mt:727,740` — `redundant-cast` on `ptr[X]<-value`.  The self's
    flow analysis narrows `value` to non-null after `if value == null: break`,
    so its recorded expression type is `ptr[X]` and the cast is genuinely
    redundant; the host's fact carries the declared `ptr[X]?`, so it misses the
    hint.  Removing the cast is type-correct under the self's refinement.
  - `std/fs.windows.mt` — self-only `prefer-let` (55 rows).  The host's
    `lint_sema_facts_for` loses its facts on this platform-pinned file (an
    import resolves through the platform guard and the loader error nils the
    snapshot), so the rule cannot see mutations and is suppressed; the self
    analyses the root and reports the immutable `var` bindings.  Reproduced at
    HEAD, so it is a pre-existing host-facts artifact, not a session-73
    regression.
  - `examples/reflection_advanced.mt:65` — host-only `constant-condition`
    (`inline if DEBUG_OFF:` branch assignment).  The host's analyzer does not
    bind expressions in the non-chosen inline branch, so its constant
    propagation keeps `count = 0` and reports the following `if count != 0` as
    always false; the self's name-keyed facts see the assignment and (correctly)
    do not report.  Reproducing the host would need its per-declaration binding
    ids in the linter CFG and would reintroduce the false positive.
  - `projects/mtc/src/mtc/main.mt` — host-only positionless `prefer-or-pattern`
    (adjacent match arms with identical bodies).  The host anchors the match on
    a node with no source position and its `--fix` makes no change; the self's
    linter does not match that node.  (The former self-only multibyte
    `redundant-cast` row disappeared with the deleted `--machine` lex output.)
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
- **`mtc test` runner binary directory:** the host builds each synthesized
  runner binary in `Dir.tmpdir`; the self keeps it beside the runner source
  (the host's `.mt` path is the same).  The location is visible only in a spawn
  failure (for example a `--mem` cap the loader cannot satisfy), and
  `cli_parity` normalizes the whole `__mt_test_runner_<pid>` path.  Moving the
  binary to `/tmp` would break the self-host runtime's
  `compiler_root_candidates`, which walks up from the running executable to the
  enclosing `std/`; `projects/mtc/test/module_roots_test.mt` pins that
  property.
- **`-I` after `--`:** the host's `extract_include_paths!` scans the whole argv,
  so `run app -- -I x` swallows `-I x` from the program arguments; the self
  stops its include pass at `--` and forwards them untouched (the intended
  behavior).  `cli_parity` has no case for this by design.
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
  `NoMethodError: generate_header`, and a valid executable source reaches
  `NoMethodError: compile_to_object` on a package `--kind static` build, so
  there is no reference output.  The self archives a clean `ar rcs` (or links
  `-shared -fPIC`) and gives `public` top-level functions external linkage; no
  C header is generated (the host's generator is missing).  Executable C output
  is unchanged.

## Ledger

Last verified numbers; re-measure only the classes a change can move, and only
when the tree moved.  Target = the Definition of Done above.

| Gate | Live | Measured | Command |
| --- | --- | --- | --- |
| bootstrap fixed point | holds (`stage2.c == stage3.c`); **22 files / 0 failed** | session 73 (gate `--fast` + stage2 suite 22/0) | `tools/bootstrap.sh -j 16` |
| `test/mt` | 60 files / 0 failed | session 73 (stage2) | `build/stage2/mtc test test/mt -I .` |
| examples / sdl3 | 49/49 same under the gate (15 top-level + 34 sdl3) | session 71 | `tools/gates.sh --only examples --run` |
| `sexpr lex` / `parse` | lex 739/739; parse 735 match / 0 differ / 4 host-rejected of 739 (counts include `tmp` fixtures) | session 72 | `ruby tools/sexpr_parity.rb lex\|parse -q --host-cache tmp/sexpr-host-cache` |
| `sexpr lower` | **684 match / 2 differ / 53 host-rejected / 0 self-rejected** of 739 (the 2 are the documented `memory_stress_test` + `main.mt` artifacts; session 72 closed the third row by fixing double rendering, type qualification and index hinting) | session 72 (stage2) | `ruby tools/sexpr_parity.rb lower -q -j 16 --host-cache tmp/sexpr-host-cache` |
| `cli:parity` | **224 match / 0 differ / 0 pending** of 224 (case-backed; timings, `debug` node ids and the synthesized test-runner path normalized) | session 73 | `ruby tools/cli_parity.rb -q` |
| `mtc test` matrix | **43 cases**, included in `cli:parity` 224/224: file/dir operands, human/TAP/JUnit, filters, death tests, `--timeout/--mem/--jobs/--sanitize`, `--locked/--frozen`, validation errors, build-error channels | session 73 | `ruby tools/cli_parity.rb -f '^test-'` |
| **`check` diagnostics** | **501 agree / 0 verdict / 0 position / 3 message of 504** (`std`+`examples`; the 3 are the documented `std/cli.mt` ×2 and `examples/reflection_advanced.mt` rows) | session 72 | `ruby tools/diag_parity.rb check -j 8 std examples`; byte-level: `ruby tools/check_parity.rb` |
| wasm preview | host=ok self=ok: entry/JS/WASM/HEAD/404/405, COOP/COEP, SIGTERM rc 0 | session 71 | `ruby tools/wasm_smoke.rb` |
| docs server | host=ok self=ok: reference/stdlib/source/highlight/search/assets/404, SIGINT rc 0 | session 71 | `ruby tools/docs_smoke.rb` |
| lint corpus | 631 agree / 4 differ of 635, hostfail 0, selffail 0; **43/43 rules, 13/13 fixers** (the 4 documented rows, including `std/fs.windows.mt`) | session 73 | `ruby tools/lint_parity.rb -q` (`--host-cache`) |
| unused-import | 635/635 | session 71 | `ruby tools/unused_import_parity.rb` |
| LSP harness | 30/30 capabilities; 4 documented entries of 70 requests + 27 probes | session 73 (re-verified) | `tools/lsp_parity.rb record/compare --stress` |
| LSP project audit | canonical 6 (4 documented + 2 warm artifacts); non-canonical 4–5 ±drift | session 71 (canonical) | `tools/lsp_project_audit.rb --workspace ~/Projects/MilkTea/SimpleGame [--canonical]` |
| LSP recovery | 6/6 byte-equal | session 73 (re-verified) | `tools/lsp_recovery_probe.rb --check` |
| LSP edit latency | 4.9 ms median per `didChange`; `didOpen` ~52 ms cold | session 29 | `ruby tmp/lsp_edit_perf.rb --bin <bin>` (transient probe) |
| LSP valgrind | 0 errors over the harness drive; ~64 KB definitely-lost per 10-cycle soak (one-time index level) | session 71 (re-verified) | `tools/gates.sh --only valgrind_lsp --run` |
| LSP soak | 74–75 KB/cycle raw / ~28 KB/cycle least-squares at 200 cycles (meter; one-time index level) | session 71 (two runs) | `ruby tools/lsp_soak.rb --quiet` |
| formatter | 739/739 all three modes byte-identical | session 72 | `ruby tools/format_parity.rb all -j 16` |
| DAP | zero differing rows except the documented self-better frame0 row; the async-order F5 probe (`tools/dap_async_probe.rb`) proves launch → breakpoint → frame/locals → evaluate against real `lldb-dap` | session 73 (re-verified) | `ruby tools/dap_smoke.rb` (`--allow-skip` to waive a missing adapter); `ruby tools/dap_async_probe.rb` |
| imported bindings | **29 verified / 0 changed of 29** | session 72 (re-verified) | `build/stage2/mtc imported-bindings --all --check`; `ruby tools/imported_bindings_parity.rb` |
| bindgen | **33 match / 0 differ / 0 error / 1 custom of 34** registry entries (the custom entry is the host's `tracy` generator, which returns the checked-in module) | session 73 (re-verified) | `ruby tools/bindgen_parity.rb --self build/stage2/mtc` |
| throughput | `emit-c` **17.1 s** (host 54.3 s); `build` **32.7 s** (host 76.3 s); `bootstrap --fast` **157 s**.  Output byte-identical to the pre-fix compiler | session 72 | time `build/stage2/mtc emit-c projects/mtc/src/mtc/main.mt -I .`; `tools/bootstrap.sh -j 16 --fast` |
| refactor guard | **0 layering violations** (103 edges); 13 frozen naming deviations; 35 unused / 6 test-only exports; 5,196 duplicated lines; 0 markers; **guard tests 11/11**; refactor gate **6/6 rc=0 (2m34s)** | session 75 | `ruby tools/refactor_guard.rb --check --strict --ratchet`; `ruby -Ilib -Itest test/tooling/refactor_guard_test.rb`; `tools/gates.sh --areas refactor --run` |

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

- **`lower` regressions:** the track is closed at 684/2/53/0 (the two documented
  artifacts).  A lowering-adjacent change can still move first differences
  deeper; re-run the sweep and keep the stopping rule (0 real differ, or a
  documented host artifact with a reproduction).
- **`deps`** is the largest single CLI subsystem (~3,000 lines); keep the port
  mechanical (module-per-file mirroring the Ruby layout) and use the host's
  `test/packages/*` as the spec.
- **emcc** may not be installed here; reproduce the host's detection/error text
  and verify the wasm path where emcc is available.
- **Throughput is closed** (session 72): the self beats the host on `emit-c`
  and on a full build, so gates no longer pay a self-host penalty.  Re-profile
  before reopening Track G.
- **History:** the per-session records are not kept in this file.  The snapshot
  through session 50 (including §0a–§0k, §1–§7 and the Appendix) is at
  `d8a199c7`; the session 51–71 batch logs live in this file's git history
  (`git log -p -- docs/self-host-plan.md`).  Keep the file operational — add
  causes to the track sections, not a growing session narrative.

## Provenance

This file is the single self-host planning document; it absorbed the former
`docs/foundational-blockers-plan.md`, `docs/lsp-parity-plan.md`,
`docs/self-host-stress-todo.md` and the machine-local session plans on
2026-10-03 (session 25).  It was compacted to the current operational state in
session 50 (2026-11-08) and re-compacted in session 74 (2026-11-14, session
batch logs pruned); the pre-compaction version, including §0a–§0k, §1–§7 and
the Appendix, is at commit `d8a199c7`
(`git show d8a199c7:docs/self-host-plan.md`), and earlier originals are in git
history.  `projects/stress` parity (build, output and exit status identical)
was recorded done in the pre-compaction history.
