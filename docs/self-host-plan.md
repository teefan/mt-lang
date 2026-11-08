# Self-Host Plan

Single planning document for the Milk Tea self-host (`projects/mtc`, branch
`selfhost`).  The Ruby host (`ruby -Ilib bin/mtc`) is the reference; "parity"
means byte-identical where a harness can compare, "better" means a documented
deliberate extension.  The goal is a self-host that matches the host everywhere,
or is documented as deliberately better.

**Start here:** read *Status at a glance*, *How to start a work session*, and
*The program* (the ranked open work).  The Ledger carries the last verified
number per gate.  The pre-compaction version of this file — with the full
session-by-session records (§0a–§0k, §1–§7) — is at commit `d8a199c7`; use
`git show d8a199c7:docs/self-host-plan.md` when you need the history.

## Contents

- [Status at a glance](#status-at-a-glance-session-50-2026-11-08)
- [How to start a work session](#how-to-start-a-work-session)
- [The program — ranked remaining work](#the-program--ranked-remaining-work)
- [Deliberate differences (do not chase)](#deliberate-differences-do-not-chase)
- [Ledger](#ledger)
- [Porting notes](#porting-notes)
- [Risks and notes](#risks-and-notes)
- [Provenance](#provenance)

## Status at a glance (session 54, 2026-11-08)

| Area | State |
| --- | --- |
| Bootstrap fixed point | **holds** (`stage2.c == stage3.c`, session 54 full); full self-test suite **19 files / 0 failed** |
| `test/mt` | **60 files / 0 failed** (session 54) |
| Examples | **13/13** synchronous top-level examples build with stdout+exit identical to the host; the two `async_*` examples hit the host's own loop guard at rc 134 on both compilers (documented CPS-resume limit); `examples/sdl3` **34/34** builds; the raylib sample builds |
| `sexpr lex` / `parse` | 0 differ (lex 712/712; parse 713 match / 0 differ / 4 host-rejected at the session-49 scoreboard; counts drift with the tree) |
| `sexpr lower` | **592 match / 74 differ / 51 host-rejected / 0 self-rejected of 717 files** (session 54) |
| `cli:parity` | **24 match / 37 differ / 0 pending** of 61 cases (last re-measured session 49, unchanged since session 35) |
| Linter corpus | **495 agree / 121 differ** of 616 files (session 50 re-read) |
| LSP | harness **30/30 capability keys + 4 documented entries**; project audit canonical **6** differing entries (4 documented rows + 2 builtin-hover warm artifacts), non-canonical 4–5 with ±drift; recovery **6/6**; `milkTea/debugInfo` **byte-equal**; valgrind **0 errors**; edit latency **4.9 ms median**; soak **68.1 KB/cycle raw / 19.9 LS** (one-time index level documented) |
| DAP | **zero differing rows** on the `dap_smoke` matrix, except the documented self-better `lldb-real frame0 name`; the live VS Code F5 check is the remaining manual step |
| Formatter | **712/712** byte-identical in all three modes (`:canonical`, `:preserve`, `:tidy`; counts drift) |
| Imported bindings | bindgen self-hosted; **3 verified / 25 changed of 28** (deltas are cosmetic emitter gaps, unverified) |

Rough completion against the per-track Definition of Done: **~80%**.  The
self-hosting foundation is done; the residue is concentrated in the `lower`
dump (74 files), CLI (37 cases + unported subsystems), the linter corpus (121
files), and bindings verification.  LSP, DAP and formatter are closed at their
documented differences.

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

## How to start a work session

### Entry points

| Workstream | Read | Verify with |
| --- | --- | --- |
| `lower` dump parity (**active**) | *The program* Track A; `docs/language-design.md` | `ruby tools/sexpr_parity.rb lower -q -j 16 --host-cache tmp/sexpr-host-cache` (~1 min warm, ~4 min cold) |
| CLI behavior parity | Track B; `tools/cli_parity.rb --help` | `rake "cli:parity"` |
| Linter corpus residue | Track C; the linter sections of `docs/language-design.md` | `ruby tools/lint_parity.rb -q` (616 files; `--host-cache FILE` makes re-runs ~20 s), `rake "parity:scoreboard"` |
| Imported bindings / bindgen | Track D; `docs/bootstrap-design.md` | `build/stage2/mtc imported-bindings --all --check`; regenerate `std/c/*.mt` and diff |
| LSP feature parity / residue | Track E; `docs/lsp-design.md` (esp. §8 differences), `docs/lsp-performance.md` | `tools/lsp_parity.rb record --server host\|self` + `compare`; `tools/lsp_project_audit.rb --workspace DIR [--canonical]`; `tools/lsp_recovery_probe.rb --check`; `tools/lsp_soak.rb` |
| DAP | Track F; `docs/dap-design.md` (gaps in §10) | `ruby tools/dap_smoke.rb [--server host\|self\|both]` |
| Formatter (`:tidy`, `:preserve`, `:canonical`) | Track E/formatter history at `d8a199c7` §7 | `ruby tools/format_parity.rb all -j 16` (712/712, counts drift) |
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
  tree, so a mid-run edit silently corrupts the result.  Check the exit status,
  not just the tail.
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
1. **`lower` dump parity** — **ACTIVE**: 567/99/51/0 of 717.  Work the ranked
   leaders in Track A; every item moves files' first differences deeper and can
   expose new families, so re-rank after each item.
2. **CLI behavior parity** — open: 24/37/0 of 61, plus the unported subsystems
   (`deps`, `docs`, wasm/emcc, `--bundle`/`--archive`, `--jobs`, toolchain
   bootstrap/tools, `--kind`, bindgen policy flags).
3. **Linter corpus residue** — open: 495/121 of 616, two unported rules and one
   unported fix, plus the analyzer gaps in Track C.
4. **Imported bindings / bindgen** — open: 28/28 verification and the bindgen
   gaps in Track D.
5. **Final verification** — Track H, only after the tracks above reach their
   targets.

LSP, DAP and the formatter are **closed** at their documented differences; only
their listed residues (ref-lifetime modelling, the DAP F5 manual check) remain.

### Definition of done (per track)

- **`lower`**: 0 differing files in `sexpr_parity lower` (residuals only if
  proven host artifacts, each documented); lex/parse stay 0-diff; no build
  regressions anywhere.
- **CLI**: every host command/flag exists with equivalent behavior; `cli:parity`
  all matches; `deps`/`docs`/wasm/bundle/jobs/toolchain functional.
- **Linter**: per-rule counts/messages/severities/positions equal the host on
  `examples/language_baseline.mt`, `examples/memory_stress_test.mt` and the whole-corpus sweep;
  every host rule/fix exists.
- **LSP**: harness 0 unintended entries (only the documented rows); the audit's
  completion class closed; `debugInfo` byte-equal; `[LSP perf]` ≤ ~10 ms per
  edit (met); valgrind clean (met).  **Met at session 31–38.**
- **DAP**: a real VS Code session debugs a `.mt` program end-to-end with the
  default `lldb-dap` backend (breakpoints, stepping, evaluate; Milk Tea
  frames/locals via the debug map); process backend unchanged; `dap_smoke`
  green on both.
- **Bindings/bindgen**: `imported-bindings --all --check` 28/28 verified (or each
  residual delta justified as cosmetic with evidence); bindgen output
  reproducible for the repo's bindings.
- **Formatter**: all modes byte-identical (712/712 at the session-33 audit;
  counts drift).  **Met.**

### Session kickoff prompt

```
Continue the Milk Tea self-host work in /home/teefan/Projects/Ruby/mt-lang
(branch `selfhost`). Work in tiers: iterate on the dev compiler
(ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev, ~50 s;
tmp/mtc-dev test projects/mtc -I . --timeout 120), measure only the class you
touch, and run the tier-2 proofs once on frozen sources — `tools/gates.sh`
prints the set (`--run` executes it, logs in tmp/gates/). Do not replay the
ledger's verified baselines unless the tree moved.

Read first: this file's Status at a glance, How to start a work session, and
The program (pick the next ranked item). The pre-compaction history is at
`git show d8a199c7:docs/self-host-plan.md`.

STEP 1 — one item per commit from the program's ranked list; each commit ends
with the gate set and this file's Ledger synced in the same commit; commit
trailer: Co-authored-by: CommandCodeBot <noreply@commandcode.ai>.

HARD RULES: never edit sources while a gate runs (bootstrap compiles the
working tree — check the exit status, not the tail); rebuild before measuring;
quote sets where a counter drifts; run generated binaries as
`timeout 10 bash -c 'ulimit -v 20000000; …'`; no hacks — fix root causes.
```

## The program — ranked remaining work

Goal: close every remaining self-host gap so `build/stage2/mtc` matches the Ruby
host on observable behavior everywhere — `--sexpr` dumps, CLI messages/commands,
LSP, DAP, linter, formatter, imported bindings, bindgen — while keeping the
self-host's documented improvements (malformed-frame recovery, synchronous
facts, speed, determinism).

Confirmed scope decision: **all** unported CLI subsystems are in scope (`deps`,
`docs`, wasm/emcc + preview, `--bundle`/`--archive`, `--jobs`, toolchain
bootstrap/tools, `--kind static|shared`, the bindgen policy flags).  Current
order: finish `lower` first, then CLI/linter/bindings, then the final matrix;
LSP/DAP/formatter are closed at their documented differences.  Anchor by symbol
names, not line numbers — lines drift.

### Track A — `lower` dump parity (592/74 of 717)

Current set: **592 match / 74 differ / 51 host-rejected / 0 self-rejected of 717
files** (session 54).  The host-rejected bucket is `external` and platform-pinned
files; the count drifts with the tree and `tmp` fixtures — quote the set.

Work one item per commit; after each item re-run
`ruby tools/sexpr_parity.rb lower -q -j 16 --host-cache tmp/sexpr-host-cache`
and re-rank.  Open leaders, largest first (re-ranked session 54):

1. **Generic-instance wave placement** (~21) — `async_stress_test`'s first
   difference: the host's `lower_functions` fixpoint lowers a generic
   declaration only when its instances exist at the start of that pass, so
   `run_on`/`run`/`run_with_runtime` (non-generic) precede `wait__int` and
   `wait_on__int` (instances appearing in later waves); the self appends
   instances in source order.  Re-derive the host's per-module wave loop
   (`lib/milk_tea/core/lowering.rb:203-234`) in the self's function placement.
2. **Proc counter numbering** (`test/mt/vec_test` and the collection tests) —
   host `mt_vec_test__proc_5__env`, self `__proc_7__`: the host's `fresh_proc_symbol`
   counter is consumed by a different set of proc expressions (or at a
   different point) than the self's.  Re-derive `fresh_proc_symbol` allocations
   from `proc.rb`/`functions.rb`.
3. **Async tails in the net/TLS corpus** (`std/net/*`, `std/http*`, `std/tls`,
   `std/oauth2`, ~18) — first differences now sit at 1.7M–3.0M bytes, past the
   await-free-body/guard/short-circuit shapes fixed in session 52; re-rank each
   file's next difference.
4. **Foreign-call protocol residue** (raylib/SDL3 examples, ~30) — first
   differences in the 20K–570K range: a nested foreign call with cstr temps
   must materialize `__mt_foreign_result_N` even in a `hm_discard` window
   (`prepare_statement_lowered_foreign_call`), the `__mt_foreign_arg_N` /
   `__mt_foreign_in_N` policy (`inlineable_single_direct_call_names`,
   addressable operands) and the cstr-temp numbering need the host's exact
   ordering.  Classify each file's first difference before working it.
5. **Simd member types** (`examples/simd_features.mt`, `projects/stress/src/engine/math.mt`)
   — a `simd` value's `x` member resolves to `void` in the self where the host
   has `array[double, 4]`; the vector-scalar binary expansion also needs the
   host's lane shapes.
6. **Parallel for/block shapes and naming** (`multithreading_test`) — port the
   host's `mt_pfor_cap_<prefix>_pfor_<N>` / `mt_pfor_work_*` /
   `mt_spawn_cap_<prefix>_spawn_<N>_<idx>` / `mt_spawn_work_*` names, the
   `mt_pfor_cap` / `mt_spawn_cap_<idx>` locals, the capture aggregate literals
   (no zero-init+assign), the `mt_pfor_data/start/end` worker params, and the
   direct-stop `mt_parallel_for` call (`loops.rb:445-601,603-798`).
7. **Visible-vs-storage local binding type** (`lowering.mt`) — the host's
   binding keeps the initializer's visible type (`Types::Null` for an annotated
   `var x: ptr[T]? = null`) while storage stays the declared nullable; the self
   reads the declared type.  Model `binding[:type]` vs `storage_type` and rewrite
   on assignment.
8. **Unsigned literal folding** (`std/flecs.mt` line 329) — host `-268435456`,
   self `4026531840` for a `uint` constant: the host folds through a signed
   long, the self keeps the unsigned value.
9. **`main.mt` crash** — lowering `projects/mtc/src/mtc/main.mt` with its
   project roots aborts in `str_is_valid_utf8` (loop guard) on both stage2 and
   the dev compiler; investigate the corrupt `str` length feeding it.
10. **Tail (file-by-file):** `memory_stress_test` is the documented host
    `ref[@_mt_0, T]` artifact (do not chase); re-rank the remaining
    `projects/stress`, `projects/mtc/test` and `test/mt` files individually.

Stopping rule: **0 differing files, or a documented host artifact with a
reproduction** (e.g. the host's leaked `ref[@_mt_0, T]` lifetime in
`examples/memory_stress_test.mt` — the self renders the declared `ref[T]`; see *Deliberate
differences*).

### Track B — CLI parity (24/37 of 61)

Open work, cheapest first:

1. **Message/channel/precedence parity** — enumerate the 37 differing cases with
   `ruby tools/cli_parity.rb --max-diffs 37 --keep` (per-case `host/self`
   `{out,err,rc}` under `tmp/cli-parity/cases/`); fix each to byte-equal.
   Examples: `std show` prints to stdout instead of stderr; `build --bogus`
   reports "accepts a single source path" instead of "unknown build option".
   Exit: 61/61.
2. **`test` argument forms** — the self accepts only a directory: `--jobs N`
   (the help advertises it but nothing parses it; a stray `16` lands in the path
   slot), `--cc/--profile/--platform`, and **file** arguments the host accepts
   (`mtc test path/file.mt`).  Port the host's fork-per-file, order-preserving
   parallel runner (`lib/milk_tea/tooling/cli/commands/test.rb:281-335`); `build` already honors
   `--cc`.  `gates_dev_tests` uses one-file temp dirs as a workaround.
3. **Cheap flags/subcommands** — `build --kind static|shared`
   (`lib/milk_tea/tooling/build.rb`); `toolchain bootstrap`/`toolchain tools`
   (`lib/milk_tea/tooling/toolchain_cli.rb:68-205`; only `doctor` is dispatched); `bindgen
   --nullable-policy/--nullable-report/--clang-arg` (advertised, not parsed).
4. **`--bundle`/`--archive`** — host `lib/milk_tea/tooling/build.rb:143-164,459-464,962-1032` and
   `lib/milk_tea/tooling/asset_pack.rb` (MTAP).  Implement the archive in-language (`std/tar.mt` and
   `std/gzip.mt` exist).  Verify `tar tzf` lists it, extraction runs, and each
   compiler consumes the other's archive.
5. **Wasm/emcc + preview** — `projects/mtc/src/mtc/build.mt` ignores `Platform.wasm`.  Port
   `compile_wasm` and shell rendering (`lib/milk_tea/tooling/build.rb:26-69,704-779,900-937,953-960`,
   `lib/milk_tea/tooling/templates/wasm_shell.html`), `--preload-file` for `build.assets`, `.html`
   output, and `run --platform wasm` (`lib/milk_tea/tooling/cli/commands/run.rb:11-207`) on `std/http/server.mt`.
   Detect `$EMCC`/`emcc` in `toolchain doctor`; reproduce the host's error text
   when absent.  Verify with emcc installed and byte-compare the HTML shell.
6. **`docs`** — port `lib/milk_tea/tooling/cli/commands/docs.rb` + `lib/milk_tea/tooling/docs_app.rb` routes
   (`/`, `/reference`, `/stdlib`, `/stdlib/:name`, `/api/search`) onto
   `std/http/server.mt`, reusing the repo's `docs/` assets and `snapshot.js`;
   `--port/-p`, `--open/-o`, the `Serving Milk Tea docs at <url>` line.
   Acceptance: functional parity, not byte-identical HTML.
7. **`deps`** (largest, ~3,000 lines + 485-line CLI) — port
   `lib/milk_tea/packages/*` into `projects/mtc/src/mtc/packages/*.mt` and
   `deps add|remove|update|tree|lock|publish|fetch`; extend
   `projects/mtc/src/mtc/loader/package_manifest.mt` (currently `source_root` only) into the full
   manifest/graph, wire `--locked`/`--frozen` and the package graph into
   `build`/`run`/`check`; network via `std/http`.  Verify against the host's
   `test/packages/*` fixtures and a local-registry probe.
8. **Harness** — add `tools/cli_parity.rb` cases for every command/flag above and
   delete the matching `KNOWN_GAPS` entries; exit: every case matches.

### Track C — linter corpus residue (495/121 of 616)

State: **495 agree / 121 differ** (session 50 re-read; the corpus and agree
counts drift with `tmp` files — quote the set).  Per-rule deltas, session-33
classification (re-measure before working a rule): `redundant-cast` 74/25,
`prefer-try` 66/39, `prefer-let` 60/141, `borrow-and-mutate` 29/0, `shadow`
20/0, `prefer-own-ptr` 16/45, `constant-condition` 11/1, `prefer-or-pattern`
10/4, `loop-single-iteration` 9/2, `unreachable-code` 4/0, `prefer-var-else`
2/0.  Closed so far (no residue): `redundant-unsafe`, `owning-release-leak`,
`owning-release-double`, `prefer-inline-if`, `prefer-struct-with`,
`prefer-conditional-expression`.

Still absent: the host's **`directional-ffi-arg`** (`lib/milk_tea/tooling/linter/rules.rb:513-531`)
and **`platform-api-drift`** (`lib/milk_tea/tooling/linter/imports_platform.rb:32-62`) rules, and the
**`redundant-unsafe`** fix generator (41 of 43 rules, 12 of 13 auto-fixable).
No corpus file currently triggers the two missing rules — a file that does would
be the first visible difference.

Analyzer gaps that gate lint rows and LSP entries:

- **Null assignability pair** (session 22): a bare `null` into a non-nullable
  target (`return null` for `ptr[int]`/`str`) is unflagged (`ty_null` is
  kind-unknown in `definitely_incompatible`/`types_compatible`); and
  generic-vs-scalar pairs (`ptr[int]` → `str`) need the host's positive
  `call_argument_compatible?`/`implicit_ref_argument_compatible?` split.
  Assigning to an immutable parameter is also unflagged.
- **Constant-value coercion** (session 23): a folded constant that fits a narrow
  integer target is host-accepted and self-rejected (`return sdl.ALPHA_OPAQUE`
  from `-> ubyte`); the host folds via `constant_value_for`, the self's
  `is_numeric_literal_valued_expr` sees only literal nodes/`if`-chains.
- **Member-assignment immutability** (session 28): the host rejects
  `x.field = …` through an immutable receiver and `this.field = …` in a
  non-editable method (host `infer_lvalue_receiver`,
  `lib/milk_tea/core/semantic_analyzer/expressions.rb:76`,
  `lib/milk_tea/core/semantic_analyzer/function_binding.rb:594-605`); the self
  has no such check, so `check` accepts
  sources the host rejects and `--fix` applies batches the host withholds
  (repro: an `extending Counter:` with a second block plus `this.value = 0`).
  Port the receiver-implicitness ladder and the generic-method scan.
- **`prefer-let` and specialized editable calls** (session 28): the self rewrites
  `examples/reflection_advanced.mt`'s `var r`, which must stay `var` because
  `r.unpack[CompactHeader]()` is editable; the editable-site recording misses
  the specialized editable call.
- **`--fix` unresolved-import guard** (session 28): the host's
  `fix_source_single_pass` refuses all fixes when an import did not resolve; the
  self proceeds.  `options.unresolved_import_paths` exists but the CLI lint path
  never fills it like `check` does.
- **Reserved-name errors** (session 28): the host raises `function int uses
  reserved built-in type name int` (module-level) and `local int uses reserved
  built-in type name int` (locals); the self checks only locals/params with a
  different message, and its module-level functions/consts/vars/events have no
  check (`ensure_non_reserved_value_type_name!`/`ensure_non_reserved_name!`).
- **Sema message rendering and return-mismatch position** (session 40): the host
  renders `return type mismatch: expected X, got Y` with its qualified `to_s`
  (`expected std.vec.Vec[int], got int`) at the return site; the self uses the
  display form and reports `0:0`.  `cannot assign to immutable x` is byte-equal,
  so the gap is this site's renderer/position.

Tool: `ruby tools/lint_parity.rb -q` (add `--host-cache FILE`; warm fill ~4 min,
then ~20 s per full run); `rake "parity:scoreboard"` for the per-rule table.

### Track D — imported bindings and bindgen

1. **OpenGL naming transforms** — port the six tables + seven functions
   (`lib/milk_tea/bindings/imported_bindings/naming.rb:7-280`) into
   `projects/mtc/src/mtc/imported_bindings/naming.mt`, wire the call sites (host
   `lib/milk_tea/bindings/imported_bindings/generator.rb:707,875`), add the missing `snake_case` trailing normalization
   (`lib/milk_tea/bindings/imported_bindings/naming.rb:259`).
2. **28-binding verification** — make `imported-bindings --all --check` emit a
   machine-readable report and add `tools/imported_bindings_parity.rb` that
   prints per-binding delta categories (baseline **3 verified / 25 changed**,
   cosmetic emitter gaps).  Close to 28/28 (including the raylib Quaternion
   member-ordering delta) or justify each residual byte-for-byte.
3. **Bindgen gaps** — header-provenance filter in `walk` (`projects/mtc/src/mtc/bindgen.mt:346-445`;
   host `lib/milk_tea/bindings/bindgen/ast_parser.rb:105-132`, `allowed_declaration_name?`); unknown-type
   policy instead of echoing bare names (`projects/mtc/src/mtc/bindgen.mt:259`; host
   `lib/milk_tea/bindings/bindgen/type_mapper.rb:62` + `lib/milk_tea/bindings/bindgen/declaration.rb:123`); nested `const char*` → `cstr` in
   the pointer branch (`projects/mtc/src/mtc/bindgen.mt:169-190`; host `lib/milk_tea/bindings/bindgen/type_mapper.rb:21-22,528-532`);
   the typedef record/enum alias maps (`projects/mtc/src/mtc/bindgen.mt:730-737`; host
   `lib/milk_tea/bindings/bindgen/ast_parser.rb:159-176`, `synthesize_typedef_dependency:326-337`).  Verify by
   regenerating `std/c/*.mt` and diffing against the checked-in files and the
   host's output.

### Track E — LSP residue (closed at documented differences)

The LSP reached its Definition of Done: 30/30 capability keys, 4 documented
harness entries, the completion class closed, `debugInfo` byte-equal, valgrind
0, edit latency ≤ 10 ms, soak at 68.1 KB/cycle raw / 19.9 LS (the per-edit leak is owned by per-entry
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

### Track F — DAP manual check

The debug map, build-on-launch, pause diagnostics/modules, the lldb-dap bridge
and the process backend are done; `dap_smoke` is row-for-row equal except the
documented self-better `lldb-real frame0 name`.  Remaining: a live **VS Code F5**
session on a `.mt` program with the default `lldb-dap` backend (breakpoints,
stepping, evaluate; Milk Tea frames/locals via the debug map).

### Track G — compiler throughput (not parity)

The self compiles its own sources in ~157 s (`emit-c` of
`projects/mtc/src/mtc/main.mt`) where the host takes ~40 s (3.9×); a full
bootstrap pays it twice.  One profiling session on the self's front-end/lowering/
C-emit (candidates: repeated analysis/type resolution per module, the
string-heavy rendering paths, the C emitter's text building) buys every future
gate several minutes.  Behavior must not change — only wall time; verify with
`emit-c` timing plus the fixed point.

### Track H — final verification

On a clean tree: `tools/bootstrap.sh -j 16` (stage2 == stage3, 19/0),
`build/stage2/mtc test test/mt -I .` (60/0), the 15 top-level examples, sdl3
34/34, the raylib sample, the vendored families, `sexpr_parity` lex/parse/lower,
`cli:parity`, both LSP harnesses + valgrind + a Neovim and a VS Code session,
`dap_smoke` on both backends, `format_parity all`, `imported-bindings --all
--check`, the lint corpus, and `~/Projects/MilkTea/SimpleGame` building and
running.  Update this file's Ledger and any changed workstream docs.  Declare
done only when the Ledger shows every counter at its target.

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
- **Better-than-host behaviours to preserve:** malformed-frame `-32700` + keep
  serving, synchronous facts with no lag, faster cold start, deterministic
  binding-map iteration; a capability the host lacks is not automatically a
  defect to remove.

## Ledger

Last verified numbers; re-measure only the classes a change can move, and only
when the tree moved.  Target = the Definition of Done above.

| Gate | Live | Measured | Command |
| --- | --- | --- | --- |
| bootstrap fixed point | holds; 19 files / 0 failed | session 54 (full) | `tools/bootstrap.sh -j 16` |
| `test/mt` | 60 files / 0 failed | session 54 | `build/stage2/mtc test test/mt -I .` |
| examples / sdl3 | 13/13 sync top-level identical (+2 async at the host's rc 134); sdl3 34/34; raylib sample builds | session 50 (raylib 49) | per-family sweeps |
| `sexpr lex` / `parse` | lex 712/712; parse 713 match / 0 differ / 4 host-rejected | lex session 33, parse session 49 | `ruby tools/sexpr_parity.rb lex\|parse -q --host-cache tmp/sexpr-host-cache` |
| `sexpr lower` | 592 match / 74 differ / 51 host-rejected / 0 self-rejected of 717 | session 54 | `ruby tools/sexpr_parity.rb lower -q -j 16 --host-cache tmp/sexpr-host-cache` |
| `cli:parity` | 24 match / 37 differ / 0 pending of 61 | session 49 | `rake "cli:parity"` |
| lint corpus | 495 agree / 121 differ of 616 | session 50 | `ruby tools/lint_parity.rb -q` (`--host-cache`) |
| LSP harness | 30/30 capabilities; 4 documented entries of 70 requests + 27 probes | session 38 (re-verified session 49) | `tools/lsp_parity.rb record/compare --stress` |
| LSP project audit | canonical 6 (4 documented + 2 warm artifacts); non-canonical 4–5 ±drift | session 43 | `tools/lsp_project_audit.rb --workspace ~/Projects/MilkTea/SimpleGame [--canonical]` |
| LSP recovery | 6/6 byte-equal | session 37 | `tools/lsp_recovery_probe.rb --check` |
| LSP edit latency | 4.9 ms median per `didChange`; `didOpen` ~52 ms cold | session 29 | `ruby tmp/lsp_edit_perf.rb --bin <bin>` (transient probe) |
| LSP valgrind | 0 errors over the harness drive; ~64 KB definitely-lost per 10-cycle soak (one-time index level) | session 38 | `tools/gates.sh --only valgrind_lsp --run` |
| LSP soak | 68.1 KB/cycle raw / 19.9 KB/cycle least-squares at 200 cycles | session 38 | `ruby tools/lsp_soak.rb --cycles 100` |
| formatter | 712/712 all three modes byte-identical | session 33 | `ruby tools/format_parity.rb all -j 16` |
| DAP | zero differing rows except the documented self-better frame0 row; valgrind 0 errors | session 34 | `ruby tools/dap_smoke.rb` |
| imported bindings | 3 verified / 25 changed of 28 (cosmetic emitter gaps) | 2026-10-03 | `build/stage2/mtc imported-bindings --all --check` |

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

- **`lower` tail:** every fix moves files' first differences deeper and can
  expose new families; the ranked order + sweep loop is the process, and the
  stopping rule is 0 differ or a documented host artifact with a reproduction.
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
