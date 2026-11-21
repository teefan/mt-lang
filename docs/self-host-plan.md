# Self-Host Plan

Single planning document for the Milk Tea compiler (`projects/mtc`, branch
`selfhost`).  The native self-host is the implementation; the Ruby host that
originally implemented the language is archived at `archive/host-ruby-0.4.26`.
In the historical records below, "parity" means byte-identical against that
archived reference and "better" a documented deliberate extension.

**Start here:** read *Status at a glance*, *Handoff*, *How to start a work
session*, and *The program* (the tracks and their stopping rules).  The Ledger
carries the last verified number per gate.  The pre-compaction version of this
file — with the full session-by-session records (§0a–§0k, §1–§7) — is at commit
`d8a199c7`; use `git show d8a199c7:docs/self-host-plan.md` when you need the
history.

## Contents

- [Status at a glance](#status-at-a-glance-session-146-2026-11-21)
- [LSP enhancement plan](./lsp-enhancement-plan.md) (session 144 audit)
- [Host retirement program](#host-retirement-program)
- [Session 146 — output diagnostics: caret length and warning anchors](#session-146--output-diagnostics-caret-length-and-warning-anchors)
- [Session 145 — LSP conformance and protocol work (phases 0–5)](#session-145--lsp-conformance-and-protocol-work-phases-05)
- [Session 144 — LSP conformance audit and enhancement plan](#session-144--lsp-conformance-audit-and-enhancement-plan)
- [Session 143 — host retirement phase 4 (delete)](#session-143--host-retirement-phase-4-delete)
- [Session 142 — seed, guard carve-out, recorded oracles, release path (phases 0–3)](#session-142--seed-guard-carve-out-recorded-oracles-release-path-phases-03)
- [Session 141 — semantic conformance: conditions, named arguments, FFI](#session-141--semantic-conformance-conditions-named-arguments-ffi)
- [Session 140 — LSP hover latency and chained receivers](#session-140--lsp-hover-latency-and-chained-receivers)
- [Session 139 — call-argument compatibility](#session-139--call-argument-compatibility)
- [Session 138 — formatter audit](#session-138--formatter-audit)
- [Session 137 — nested-type facts and the rename index move](#session-137--nested-type-facts-and-the-rename-index-move)
- [Session 136 — guarded-local member hover](#session-136--guarded-local-member-hover)
- [Session 135 — chained-hover audit](#session-135--chained-hover-audit)
- [Session 134 — the session-133 LSP follow-ups and hover latency](#session-134--the-session-133-lsp-follow-ups-and-hover-latency)
- [Session 133 — VS Code LSP audit on the compiler sources](#session-133--vs-code-lsp-audit-on-the-compiler-sources)
- [Session 132 — format-string completion, the hover bail, and the attribute probe](#session-132--format-string-completion-the-hover-bail-and-the-attribute-probe)
- [Session 131 — VS Code LSP sweep and completion/diagnostic fixes](#session-131--vs-code-lsp-sweep-and-completiondiagnostic-fixes)
- [Session 130 — long-function closeout](#session-130--long-function-closeout)
- [Session 129 — dispatch/format/lint/AST splits and bounded test builds](#session-129--dispatchformatlintast-splits-and-bounded-test-builds)
- [Session 128 — ordering, hover, type equality, and AST dump splits](#session-128--ordering-hover-type-equality-and-ast-dump-splits)
- [Session 127 — lowering, manifest, linter, and semantic-token splits](#session-127--lowering-manifest-linter-and-semantic-token-splits)
- [Session 126 — build, dispatch, C preamble, check, parser, and test splits](#session-126--build-dispatch-c-preamble-check-parser-and-test-splits)
- [Session 125 — command and parser-section decomposition](#session-125--command-and-parser-section-decomposition)
- [Session 124 — identifier member resolution](#session-124--identifier-member-resolution)
- [Session 123 — lower_module declaration arms](#session-123--lower_module-declaration-arms)
- [Session 122 — parallel worker extraction](#session-122--parallel-worker-extraction)
- [Session 121 — lower_expr decomposition](#session-121--lower_expr-decomposition)
- [Session 120 — parser expression-forms module](#session-120--parser-expression-forms-module)
- [Session 119 — parser specialization module](#session-119--parser-specialization-module)
- [Session 118 — lower_async_fn decomposition](#session-118--lower_async_fn-decomposition)
- [Session 117 — generate_c decomposition](#session-117--generate_c-decomposition)
- [Session 116 — parser declaration-forms module](#session-116--parser-declaration-forms-module)
- [Session 115 — parser declarations module](#session-115--parser-declarations-module)
- [Session 114 — parser expressions module](#session-114--parser-expressions-module)
- [Session 113 — analyzer check_module_opts decomposition](#session-113--analyzer-check_module_opts-decomposition)
- [Session 112 — analyzer resolve_named decomposition](#session-112--analyzer-resolve_named-decomposition)
- [Session 111 — analyzer infer_binary decomposition](#session-111--analyzer-infer_binary-decomposition)
- [Session 110 — analyzer check_stmt decomposition](#session-110--analyzer-check_stmt-decomposition)
- [Session 109 — analyzer check_member decomposition](#session-109--analyzer-check_member-decomposition)
- [Session 108 — analyzer infer_expr decomposition](#session-108--analyzer-infer_expr-decomposition)
- [Session 107 — parser statements module](#session-107--parser-statements-module)
- [Session 106 — bindgen nullable-report module](#session-106--bindgen-nullable-report-module)
- [Session 105 — bindgen options-JSON module](#session-105--bindgen-options-json-module)
- [Session 104 — bindgen macro-probe module](#session-104--bindgen-macro-probe-module)
- [Session 103 — bindgen emitter module](#session-103--bindgen-emitter-module)
- [Session 102 — nullable-policy bindgen module](#session-102--nullable-policy-bindgen-module)
- [Session 101 — redundant-else linter rule module](#session-101--redundant-else-linter-rule-module)
- [Session 100 — trailing-comma linter rule module](#session-100--trailing-comma-linter-rule-module)
- [Session 99 — doc-tag linter rule module](#session-99--doc-tag-linter-rule-module)
- [Session 98 — build/run command module](#session-98--buildrun-command-module)
- [Session 97 — snapshot/debug command module](#session-97--snapshotdebug-command-module)
- [Session 96 — test command module](#session-96--test-command-module)
- [Session 95 — format command module](#session-95--format-command-module)
- [Session 94 — bindings command module](#session-94--bindings-command-module)
- [Session 93 — std catalog command module](#session-93--std-catalog-command-module)
- [Session 92 — c_backend reachability module](#session-92--c_backend-reachability-module)
- [Session 91 — lower_call decomposition](#session-91--lower_call-decomposition)
- [Session 90 — lower_stmt decomposition](#session-90--lower_stmt-decomposition)
- [Session 89 — if/for/iteration module](#session-89--ifforiteration-module)
- [Session 88 — monomorphized function and module-driver module](#session-88--monomorphized-function-and-module-driver-module)
- [Session 87 — include scan module](#session-87--include-scan-module)
- [Session 86 — match and variant introspection module](#session-86--match-and-variant-introspection-module)
- [Session 85 — parallel/detach/gather module](#session-85--paralleldetachgather-module)
- [Session 84 — type and expression helpers](#session-84--type-and-expression-helpers)
- [Session 83 — async CPS module](#session-83--async-cps-module)
- [Session 82 — format string module](#session-82--format-string-module)
- [Session 81 — task and parallel-for module](#session-81--task-and-parallel-for-module)
- [Session 80 — layout module](#session-80--layout-module)
- [Session 79 — inline control-flow module](#session-79--inline-control-flow-module)
- [Session 78 — const evaluation module](#session-78--const-evaluation-module)
- [Session 77 — import cycles and the first lowering split](#session-77--import-cycles-and-the-first-lowering-split)
- [Session 76 — naming foundation and shared text leaf](#session-76--naming-foundation-and-shared-text-leaf)
- [Session 75 — refactoring safety suite](#session-75--refactoring-safety-suite)
- [Session 74 — decisions closed](#session-74--decisions-closed)
- [Session 73 — the `mtc test` CLI matrix](#session-73--the-mtc-test-cli-matrix)
- [Session 72 — the `check`/analyzer surface](#session-72--the-checkanalyzer-surface)
- [Handoff](#handoff-session-146)
- [How to start a work session](#how-to-start-a-work-session)
- [The program — tracks and stopping rules (all tracks closed)](#the-program--tracks-and-stopping-rules-all-tracks-closed)
- [Deliberate differences (do not chase)](#deliberate-differences-do-not-chase)
- [Ledger](#ledger)
- [Porting notes](#porting-notes)
- [Risks and notes](#risks-and-notes)
- [Provenance](#provenance)

## Status at a glance (session 146, 2026-11-21)

| Area | State |
| --- | --- |
| Compiler | **native self-host only**; the Ruby host is archived at tag `archive/host-ruby-0.4.26`, and `lib/`, the Ruby `test/**` suite, `milk_tea.gemspec`, `Rakefile`, `Gemfile` and `bin/mtc` are removed (session 143) |
| Bootstrap fixed point | **holds** (`stage2.c == stage3.c`); self-test suite **22 files / 0 failed** (session 145, stage0 = the committed seed, a `ruby` shim that exits 127 never invoked) |
| Bootstrap stage0 | **committed seed only**, `vendor/bootstrap/linux-x86_64/mtc` + `mtc.sha256` (`b29241f4…`, release); `--bootstrap PATH`/`$MTC_BOOTSTRAP` override; `--allow-ruby-host` is gone |
| Release archive | **3.52 MiB deterministic tar.gz** (`mtc-0.4.26-linux-x86_64`), checksummed beside the archive; identical across two packagings of the same inputs; clean-path smoke (std build/run, LSP initialize, docs page/CSS/JS/404) green; the version is the authored `cli_help.VERSION` |
| Analyzer memory | `check main.mt` **712 MiB / 6.6 s** (was 9,228 MiB / ~58 s); `lowering.mt` **274 MiB** (was 2,322 MiB).  All tooling fan-out is capped at **4**, so the worst 4-way sweep is ~3 GiB (session 142) |
| `test/mt` | **85 files / 0 failed** (62 in-language tests + 23 compile-fail diagnostics fixtures; session 146 replayed); peak RSS **135 MB** under the region-scoped test compiler |
| Examples | **49/49 build** under the self-only `emit-c` gate (15 top-level + `examples/sdl3` 34/34; session 143; was host-compared 49/49 in session 141) |
| Recorded oracles | **CLI 227/227 cases; diagnostics 504 files / 0 differ; lint 673 files / 0 differ; formatter 775 files × 3 modes / 0 differ** — digest-keyed and replayed green with no host source present (session 146 refreshed the diag, CLI, lint and formatter fixtures for the output-diagnostic fixes and stale session-145 rows) |
| `check` diagnostics | the 504-file diagnostic oracle is the gate; the two `loop-single-iteration` columns now match the host (16), and the historical host comparison's 3 message rows are retired with the host |
| Analyzer call-argument compatibility (CLOSED, sessions 139/141) | The session-138 coercion table matched the archived host in both directions and at the same message/position.  Session 139 ported per-parameter expected types and compile-time numeric folding; session 141 closed named arguments, imported/method explicit specializations, extern/foreign arity/types, nullable numeric targets, and strictly-bool conditions.  The constructor-field anchor is a reviewed difference, not a residual (session 146). |
| Linter | **43/43 rules, 13/13 fixers**; the 673-file lint oracle is the corpus gate (the live host-diff corpus is retired).  The historical residue (3 self-only `std` files, the host-timeout rows) is recorded in *Deliberate differences*. |
| LSP | self-only instruments: valgrind **0 errors**; edit latency **4.9 ms median**; hover **2.0–7.7 ms median** by probe class on `analyzer.mt`; soak **68.9 KB/cycle raw / 5.7 LS at 200 cycles** (session 145; no positive slope); `milkTea/debugInfo` byte-equal on the recorded fixtures.  The host-differential harness/audit/recovery probes are retired with the host; `lsp_parity record --server self` and `lsp_soak` remain |
| LSP conformance | **phases 0–5 landed (session 145)**: `tools/lsp_conformance.rb`, **35 spec cases, 35 pass / 0 fail**; the `lsp_conformance` tier-2 gate is green.  Coverage 42/54 requests, 30 capability keys; rangesFormatting, refresh endpoints and progress/partial results are implemented; only the deliberately skipped editor features remain out of scope.  Plan and evidence: `docs/lsp-enhancement-plan.md` |
| DAP | self-only `dap_smoke`: all probes answer, the real lldb-dap breakpoint session reaches `add` and terminates; `dap_async_probe` proves the VS Code launch ordering; desktop F5 smoke passed session 74 |
| Formatter | **775 files × 3 modes** (`:canonical`, `:preserve`, `:tidy`) replay from the digest-keyed oracle; counts drift with the tree |
| Imported bindings | **29/29 verified** by the native `imported-bindings --all --check` (the host parity report is retired) |
| Bindgen | the native `mtc bindgen` / `bindings` commands are the generator of record; the host reproducibility harness is retired |
| Compiler throughput | **`emit-c` 17.1 s** and full `build` 32.7 s (session 72; the archived host measured 54.3 s / 76.3 s); `bootstrap --fast` 2.6 min.  C output unchanged |
| **Refactoring safety** | structural guard: 169 files / 127,752 code lines; 111 edges / **0 layering violations**; **0 naming, 0 alias / vocabulary violations**; **32 unused + 6 test-only** public declarations; 6,470 duplicated lines / 896 clusters; **1 function ≥ 200 lines** (the excluded `binding_at`); **11 files ≥ 2,000 code lines**; 0 markers; tests 22/85.  Protocol `docs/refactoring.md`; baseline `tools/refactor_baseline.json`; one command: `tools/gates.sh --areas refactor --run` (baseline refreshed session 146 for the warning-anchor logic and a shifted dead-export key) |

Rough completion against the per-track Definition of Done: **~100%**, now
against the archived host record rather than a live reference.  The
self-hosting foundation, `lower` dump parity, the CLI behavior matrix, wasm,
docs, the linter corpus, the imported bindings and bindgen reproducibility were
closed in sessions 49–141.  Sessions 139/140/141 closed the call-argument model,
the LSP hover latency and the invalid-match lowering abort.  Session 142 opened
the host retirement program; **session 143 completed phase 4**, so the tree now
builds, tests, and replays every oracle without a second compiler.

Remaining residuals are limited to diagnostic type qualification,
module/positionless diagnostic rendering and `lint` on an unresolved import;
all three are differences from a retired host and are re-adjudicated on merit
as they are touched.  The CLI caret length, the five zero-column linter
warnings and the unreachable expression anchor were fixed in session 146.  The
constructor-field anchor keeps the construction column by design (the host's
declaration anchor is less precise), and the optional desktop F5 smoke remains
an extension-repo item.

## Host retirement program

Decision (session 142): the native self-host becomes the shipped compiler; the
Ruby host (`lib/`) is frozen and retired.  Parity is no longer an invariant —
new work lands in `projects/mtc` and `std/` only.  Correctness is defined by
`docs/language-manual.md`, `test/mt` and the recorded oracles, not by host
byte-identity.  **The program is complete (session 143): phases 0–4 are done.**

Phases, in order; each gate proves the previous one:

| Phase | Work | Gate |
| --- | --- | --- |
| 0. Seed | committed sha256-verified stage2 seed; Ruby host behind `--allow-ruby-host` | **DONE (session 142)**: full bootstrap with a failing `ruby` shim → fixed point + 22/0; `test/mt` 62/0 |
| 1. Guard | carve `MilkTea::RefactorGuard` (820 Ruby lines, stdlib only) out of `lib/` into `tools/lib/`; a native `.mt` port is deferred | **DONE (session 142)**: report and JSON byte-identical to the pre-move guard; 15 tests pass |
| 2. Oracles | **DONE (session 142)**: shared `tools/lib/golden.rb`; `--record`/`--expect` in the four sweeps; digest-keyed fixtures under `tools/golden/`; negative corpus as `# expect-error:` fixtures under `test/mt/diagnostics/` | the replay set runs green with `lib/` moved away (no host process is started) |
| 3. Product | **DONE (session 142)**: `tools/release.sh` builds a deterministic archive (`bin/mtc`, `std/`, `docs/`, `docs_public/`, `VERSION`, `README`, `LICENSE`) with a checksum and optional seed refresh; `tools/release_smoke.sh` verifies a clean-path extract | extract outside the checkout → std-importing program builds/runs, LSP initialize handshake, docs page/assets/404 |
| 4. Delete | **DONE (session 143)**: archive `lib/milk_tea`, the Ruby `test/**` suite, the gemspec, `Rakefile`, `Gemfile`, `bin/mtc` and the host-coupled harnesses; swap the gates to the recorded oracles; remove `--allow-ruby-host` | a tracked-files-only tree + vendored `third_party/` with a `ruby` shim that exits 127: bootstrap fixed point + `test/mt` **85/0**; goldens replay **227 / 504 / 672 / 774×3** |

Why this order: the seed must exist before any self-only language change; the
guard protects the refactorings the flip itself needs; the goldens must be
recorded before behavior changes, or the remaining parity rows become
permanently red.  `sexpr lower` goldens are deliberately out of scope (779 IR
dumps; the backend is already proven by the fixed point and the example sweeps).

Consequences for the session-141 batch: the CLI caret length, the zero-column
linter warnings and the constructor-field column are real defects and stay in
scope; session 146 fixed the first two and re-adjudicated the third (the
construction column is the more precise anchor).  Qualified-type rendering,
module/`static_assert` bare-vs-block and `lint` on an unresolved import are
differences from a host that will no longer be maintained; re-adjudicate each
on its own merit.

## Session 142 — seed, guard carve-out, recorded oracles, release path (phases 0–3)

Removed the Ruby host from the default bootstrap path and moved the last live
host component out of `lib/`.

**Seed.** `vendor/bootstrap/linux-x86_64/mtc` is a release-profile **stage2**
compiler (6.28 MB, built at `6a67c937` by the Ruby host → stage1 → stage2, so
its code generation is Milk Tea's), shipped with `mtc.sha256`.
`tools/bootstrap.sh` now resolves stage0 as `--bootstrap` → `$MTC_BOOTSTRAP` →
the platform seed (checksum-verified) → the Ruby host only with
`--allow-ruby-host` → error.  The legacy `bin/bootstrap-mtc` path is gone.  A
missing platform, a missing checksum and a mismatch are hard errors that name
the expected path.

**Docs.** `docs/bootstrap-design.md` §2 reverses its earlier "never commit
binaries" decision, with the reason recorded: there is no CI and no artifact
host, so download-on-demand would leave a fresh clone unable to build without
Ruby.  `vendor/bootstrap/README.md` carries provenance and the replacement
policy (refresh at a release, or when the seed can no longer compile the tree).
`.gitattributes` marks `vendor/bootstrap/**/mtc` binary so `* text=auto` cannot
mangle the executable (the README and checksum stay text).

**Proof.** Full 3-stage bootstrap (`--keep-c -j 16`) with a `ruby` shim first on
`PATH` that exits 127: the shim was never invoked, `stage2.c == stage3.c`, the
self-test built itself, **22 files / 0 failed**; `test/mt` **62/0**.  Negative
paths verified separately: missing seed → the platform-named error;
corrupted checksum → mismatch error; `--allow-ruby-host` with the seed removed
→ Ruby host build.

**Guard (phase 1).**  The guard turned out to be purely textual, not
parser-coupled: `RefactorGuard` scans `projects/mtc/src` with anchored regexes
and depends only on the Ruby stdlib (`digest`, `fileutils`, `json`).  That makes
a native `.mt` port unnecessary work — reimplementing nine regexes as hand
scanners is how a guard silently drifts from the rules it claims to enforce —
so the file moved instead: `lib/milk_tea/tooling/refactor_guard.rb` →
`tools/lib/refactor_guard.rb`, its test → `tools/test/refactor_guard_test.rb`
(dropping the `test_helper` dependency, which loaded the whole host), and
`tools/gates.sh` follows the new paths.  `tools/lib/*.rb` joined the marker
globs with the guard's existing self-skip.  The report and the `--json` output
are byte-identical to the pre-move guard, and the relocated test is **15 runs /
52 assertions / 0 failures**.  A native `.mt` guard remains optional and would
belong with a parse-based facts surface, not a scanner port.

**Open next.**  Phase 2: the recorded oracles.  Known host tooling couplings to
re-home: `cli_parity` calls `MilkTea::CLI.start` and `format_parity` calls
`MilkTea::Formatter.check_source` in-process, `sexpr_parity` borrows
`MilkTea::ModuleLoader` for module-name resolution, `gen_cli_help` generates
`cli_help.mt` from the host's command table, and the bindgen/imported-bindings
harnesses use the Ruby registries as the generator of record (the self owns
`imported-bindings --all --check`, 29/29).

### Phase 2 in the same session — recorded oracles

`tools/lib/golden.rb` is one record/replay helper: `--record FILE` writes the
self's normalized results, `--expect FILE` replays them without starting the
host.  All four sweeps gained the pair:

- `cli_parity` records per case `{stdout, stderr, rc}`.  The recorded path
  isolates `XDG_CACHE_HOME` (an empty per-run root), because build cases report
  `[cached]` on a warm cache and the record/replay pair must see the same cache
  history.
- `diag_parity`, `lint_parity` and `format_parity` record per file (formatter:
  per mode) and are **digest-keyed**: an input whose text changed since
  recording is skipped and reported as `changed=N`; an input with no row is
  `unrecorded=N`.  Only unchanged inputs are compared, so a source edit does
  not turn the gate red.  The recorded branches never `require "milk_tea"` (the
  host banner and the host worker are parity-only), which is the property the
  phase gate verifies by moving `lib/` aside.

The negative corpus reuses the in-language runner instead of a second harness:
23 fixtures under `test/mt/diagnostics/`, one `# expect-error:` per rejected
construct, run by the ordinary `mtc test test/mt` gate.

**Bugs the corpus exposed (fixed).**  The three probes that disagreed with the
host were genuine self-accepts-invalid gaps:

- `let … else:` never checked its initializer shape.  `check_local` now reports
  the host's message when the value is not nullable/`Option`/`Result` (error
  types stay permissive).
- Postfix `?` never checked its source.  `infer_unary` now requires
  `Option`/`Result` and reports at the statement anchor, matching the host.
- `read` accepted zero/one argument without validation, any non-pointer, and a
  nullable pointer.  The builtin now reports the host's arity and operand
  messages and rejects nullable operands (error types stay permissive).
- `str`/`cstr` categories: `scalar_category` classified neither `str` nor
  `cstr` as its own category, so `puts(1)` passed the permissive fallback, and
  the `str as cstr` boundary rule matched only `ty_primitive("str")` while the
  public type is `ty_str`.  Both fixed; `std/raylib/runtime.mt` accepts
  `cstr` arguments again and `extern` calls reject `int`.

**Nullability merge bug (fixed).**  The corpus's flow probe found a real CFG
bug: `pred_edge_state` applied each predecessor's edge refinement *after*
intersecting the predecessor states, so the non-null set depended on predecessor
order.  `if value == null: pass` therefore narrowed `value` to non-null past the
merge, and the self accepted `read(value)` on a nullable pointer with no guard.
The refinement is now folded into the predecessor's contribution before the
intersection, and
`test_cfg_fallthrough_branch_does_not_narrow_after_merge` pins it.

**Verification.**  Fixed point holds on the new sources, and the four recorded
gates replay green **with `lib/` moved aside** (no host process is started):
CLI **227/227**, diagnostics **504 files / 0 differ**, lint **672 compared /
0 differ** (0 unrecorded after the phase-3 memory fix), and the formatter
**778 files × 3 modes / 0 differ**.  Live parity is unchanged:
`cli_parity` **227/227**, `diag_parity check std examples`
**501 agree / 0 verdict / 3 message / 0 position of 504**.  `test/mt` is now
**85/0** and the dev suite **22/0**.  The guard passes
`--check --strict --ratchet` after a reviewed refresh: **126,602 code lines**,
tests **22/85** (its glob now counts subdirectories, so the new fixtures are
visible).

**Linter performance — resolved in phase 3.**  The self linter took ~58 s and
9.2 GiB on `main.mt`, and 7 compiler-sized files exceeded the 180 s per-file
timeout.  The phase-3 investigation below found the cause and fixed it; the lint
sweep no longer times out.

**Still open from phase 2:** nothing.

### Phase 3 in the same session — release path

`tools/release.sh` reads the version from the authored
`projects/mtc/src/mtc/cli_help.mt` (`VERSION` plus the help banner), refuses a
mismatch, builds a release-profile stage2 with the seed, and packs
`bin/mtc` + `std/` + `docs/` + `docs_public/` + `VERSION` + `README.md` +
`LICENSE`.  The archive is deterministic: sorted entries, owner 0, a fixed
`--mtime`, and `gzip -n`; two packagings of the same binary produce the same
checksum.  `--refresh-seed` copies the release compiler into
`vendor/bootstrap/<platform>/` and regenerates `mtc.sha256`.

`tools/release_smoke.sh` extracts the archive under `/tmp` (outside the
checkout, so an ancestor `std/` cannot mask a missing one), clears
`MILK_TEA_MODULE_ROOT`/`MILK_TEA_STD_ROOT`, builds and runs a `std.stdio`
program, completes an LSP `initialize` handshake, and checks `mtc docs` for the
reference page, `/css/docs.css`, `/js/docs.js`, and a 404.  The docs check found
a real packaging bug: `serve_asset` resolved only the checkout path
(`projects/mtc/src/mtc/docs_public`), so the first archive 404'd its own CSS.
It now prefers `<root>/docs_public/` and falls back to the checkout path.

**Version stamping.**  `version_info.mt` was a gitignored generated file whose
`__PLACEHOLDER__` had long since been replaced, leaving a frozen `98c096e` that
nothing read; `bootstrap.sh` still rewrote it every run and `main.mt` imported
it for no reason.  Removed all three.  The version is `cli_help.VERSION`, an
authored constant, so a release build never consults git.

**Distribution.**  README install now documents the native archive (with the
gem marked deprecated); the gemspec description and post-install message mark
the gem deprecated.  `docs/build-guide.md` §10 documents the archive layout,
module-root resolution, the release commands, and building from the seed.  The
gemspec and the host tests are removed in phase 4.

### Analyzer memory (found while capping the fan-out)

A `mtc lint` run was exhausting RAM.  One `lint main.mt` measured **9,228 MiB**,
identical to `check main.mt` — the linter was innocent; the analyzer was the
consumer.  Per-file measurements isolated it: `lowering.mt` 2,322 MiB while
`analyzer.mt` was 73 MiB, so it was not closure size either.  Massif with
`--pages-as-heap=yes` attributed 61% of the 2.47 GiB peak to `String` builds in
`record_imported_constants`: the analyzer's exported `const_values` carried the
qualified imported aliases it had synthesized for folding, so every importer
re-prefixed them and the names compounded along the import graph (a 13k-line
file imports its way to millions of `<alias>.<name>` keys).

The fix splits the maps: `Analysis.declared_const_values` holds only the
module's own constants and is what the binding exports; `ctx.const_values`
remains the internal fold cache.  Measured after: `check main.mt`
**712 MiB in 6.6 s** (was 9,228 MiB / ~58 s), `lowering.mt` **274 MiB** (was
2,322 MiB), and lint matches check.  The recorded lint sweep drops from
**3:44 with 7 files timing out** to **39 s with 0 timeouts** (672 files).  The
host rejects a transitive `a.C`, which matches the narrowed export; the self
still accepts *unknown* members on an imported module (`a.NOPE`), a separate
pre-existing gap.

### Parallelism cap

Every harness routes its worker count through `tools/lib/jobs.rb`
(`Jobs::MAX = 4`), `bootstrap.sh` and `release.sh` clamp `-j` at 4, and the gate
commands use `-j 4`.  The clamp warns when an explicit value is higher.  With
the memory fix above, the worst compiler-sized lint is ~700 MiB, so a 4-way
sweep stays around 3 GiB.

**Verification.**  The release build and smoke pass; two packagings of the same
inputs produce the same checksum (the first mismatch was a docs edit between
runs, not the archive).  The refreshed seed reaches the fixed point
(`stage2.c == stage3.c`), and a bootstrap through the fixed seed analyzes the
compiler at **3.6 GiB** instead of 12.3 GiB.  The recorded gates are re-recorded
on the fixed compiler and replay with no skips, including with `lib/` moved
aside; `test/mt` 85/0, `cli:parity` 227/227, `diag_parity` 501/0/0/3 of 504,
docs smoke host+self ok, and the guard ratchet after a reviewed baseline
refresh (126,602 code lines).

## Session 146 — output diagnostics: caret length and warning anchors

Closed the output-diagnostic batch.  `print_program_diagnostics` now renders
`^` plus `~` for every column after the first when the diagnostic carries a
length, matching the archived host's `ErrorFormatter`; the build/run sema block
previously ignored `rd.length` (the `check` renderer already honored it).

The five positionless linter rules now carry real anchors:

- `duplicate-if-condition` — the duplicate condition expression's own
  line/column/length (`a == 1` in `else if a == 1` anchors at `a`).
- `redundant-else` — the `else` keyword (`else_column`, length 4).
- `loop-single-iteration` — the loop statement's column; `while` keeps the
  parser's keyword length (fallback 5), `for` uses 3.  A `for` anchors at its
  first binding because both the self parser and the host's `ForStmt` do.
- `redundant-null-check` — `nullcheck.Diag` now carries the branch condition;
  the linter computes the host's `condition_span` (the source `if`/`else if`
  keyword-to-colon span) and falls back to the expression span.
- `unreachable-code` — CFG nodes built from expression statements carry
  column 0; `unreachable_column` now falls back to `statement_column`
  (expression column, then the first non-space source column), so `helper()`
  after a `return` reports `6:5` instead of `6:0`.

The constructor-field column was re-adjudicated, not changed: the self anchors
`unknown field` / `field ... expects` at the construction expression (e.g.
`Foo` in `let x = Foo(bad = 1)`), which names the offending construction.  The
archived host's declaration anchor came from its error-node stack and is less
precise; with host parity retired there is no reason to regress it.  Recorded
under *Deliberate differences*.

**Verification.** Dev suite **22/0**; bootstrap fixed point + **22/0**;
`test/mt` **85/0**; diagnostics replay **504/0** (two re-recorded rows: the
`loop-single-iteration` columns 0 → 16 for the two `inline for` sites in
`examples/reflection_advanced.mt`, matching the host's `ForStmt.column`);
CLI **227/227** (one re-recorded caret row: the `emit-c-external` parse error
now renders `^~~~~~~`); lint **673/0** (the fixture was refreshed: session
145's LSP edits had left 25 stale rows and `projects/mtc/src/mtc/lsp/refresh.mt`
unrecorded); formatter **775×3/0** (same stale-row refresh, including
`refresh.mt`); guard `--check --strict --ratchet` after the reviewed baseline
refresh (**127,752** code lines; 6,470 duplicated / 896 clusters; 32 unused +
6 test-only; tests 22/85).  `cli_parity` and `format_parity` now use a
spawn/wait capture instead of Open3: its reader threads trip a Ruby 4.0 VM
teardown segfault (caught once as a post-summary rc 139), and the sibling
sweeps already use spawn.  The in-language linter tests pin the new spans
(duplicate 13, `else` 5/4, `while` 5/5, `for` 9/3, null-check 12/9,
unreachable expression 5/6).  No LSP or runtime code changed, so the valgrind
and soak meters were not re-run.

## Session 145 — LSP conformance and protocol work (phases 0–5)

Added the spec oracle for the LSP enhancement program and closed the position
encoding P0.  Phase 0 changed no compiler code; phase 1 changed only the LSP
subsystem and its unit test.

**Harness.** One standalone Ruby stdio client (`Content-Length` JSON-RPC,
buffered reads with deadlines, server→client requests answered, process groups
reaped, `RLIMIT_AS` capped at the project's 20 GB binary-testing rule).  26
cases seeded from `docs/lsp-enhancement-plan.md` §5, with explicit assertions:
the UTF-16 row is split per boundary (semantic token, diagnostic, hover,
rename, inlay hint, selection, incremental `didChange`) and completion is split
into docs and item preservation.  Options: `--bin`, `--only`, `--timeout`,
`--json`; exit 1 on any failure.  `--bin` takes a wrapper, so a focused valgrind
drive is possible, but the existing `valgrind_lsp` corpus drive stays the
memory instrument (26 cold valgrind startups buy less than one long session).

**Gate.** `lsp_conformance` is a hard tier-2 gate in the `lsp` area
(`ruby tools/lsp_conformance.rb --bin build/stage2/mtc`); `tools_check` already
syntax-checks it through the `tools/*.rb` glob.  The gate is **red on purpose**
until phases 1–4 land — the failing set is the work list, not a regression.

**Baseline (23.8 s seed dev build; fresh dev suite 22/0):** 3 pass / 23 fail.
Passing: ASCII ranges/tokens unchanged, `textDocument/diagnostic`
full/unchanged, exit-after-shutdown.  Failing, matching the session-144 audit:
all seven UTF-16 cases; `quickfix` capability and returned action kind;
completion-resolve docs and preserved item; `willRenameFiles` response/import
rewrite; multi-root add/remove; watched-file registration; workspace-diagnostic
scope and refresh; `publishDiagnostics.version`; pre-init/duplicate-init/
post-shutdown codes; exit status without shutdown; stale `$/cancelRequest`.

### Phase 1 in the same session — position encoding

`initialize` now reads `capabilities.general.positionEncodings`: it advertises
`utf-8` when the client offers it (the server's byte columns stay the wire
format), otherwise the LSP default UTF-16, and sets
`Workspace.position_encoding_utf16` for both boundaries.

**Incoming.** `position_byte_offset_in` routes to
`utils.position_to_byte_utf16`/`position_to_byte_utf8`; position params,
selection ranges, range formatting and inlay-hint ranges share it.
`didChange` applies each edit against its own in-progress buffer through the
same decoder — the scalar `line_char_to_byte` and `is_cont_byte` are gone, so an
astral edit lands at the UTF-16 offset the client meant.

**Outgoing.** `utils.byte_to_utf16_column` plus the line-start map cached in
every `TextCacheEntry` (`utils.build_line_starts`/`line_at_index`) make a
conversion O(line length); `output_character_in`/`output_character` are the
shared helpers.  The audit converted semantic tokens (one line split per pass),
diagnostics, hover and definition locations, highlight, references, rename,
code actions, linked editing, selection, document and workspace symbols, inlay
hints, type and call hierarchy, and document links.  Code lens, formatting and
on-type formatting are line-based or echo the client's range.  The semantic
token cache records its column encoding, so a cached UTF-8 pass is never
replayed to a UTF-16 client.

**Tests and verification.** The conformance suite grew to 29 cases: UTF-8
negotiation, document highlight and references joined the seven UTF-16 cases
and the ASCII anchor.  `lsp_conformance` is **13 pass / 16 fail**; the
remaining failures are the phase 2–4 list.  `lsp_utils_test.mt` covers both
decoders, `byte_to_utf16_column` and the line-start map.  ASCII endpoint
parity against the pre-change recording is **88/88 entries, 0 differ**.
Seed dev build; dev suite **22/0**; bootstrap fixed point + **22/0**;
`test/mt` **85/0**; valgrind **0 errors**; soak **76.0 KB/cycle raw / 19.5 LS**
at 200 cycles; guard `--check --strict --ratchet` after the reviewed baseline
refresh (**126,855** code lines; 6,451 duplicated / 904 clusters; 32 unused +
6 test-only exports; tests 22/85).

### Phase 2 in the same session — conformance fixes

The `codeAction` capability and both action emitters use the spec spelling
`quickfix`.  `completionItem/resolve` reads `data.uri`/`data.name`, scans
keyword/modifier/indented declarations and contiguous `##` blocks, falls back
to the workspace index only for non-local items, and adds `documentation` to
the original item instead of rebuilding it.

The message loop now enforces lifecycle state: `-32002` before initialize,
`-32600` for a duplicate initialize and every post-shutdown request, exit
status 1 without a prior shutdown, `serverInfo`/`experimental` in the
initialize result, and document-version tracking for `publishDiagnostics` and
workspace diagnostics.  `$/cancelRequest` is deliberately ignored and the
stale id set is removed (the synchronous loop cannot cancel in-flight work).

The phase also fixed the semantic-token cache's key churn: an entry is updated
in place on each document version, and removal/clear releases the map-owned
key as well as the entry's strings and data.

**Verification.** The conformance suite is **30 cases / 24 pass**; the six
remaining failures are phase 3–4.  ASCII endpoint replay against the
pre-phase-2 recording has exactly five intended differences (capability
spelling, initialize `serverInfo`/`experimental`, two code actions, workspace
diagnostic version).  Dev suite **22/0**; bootstrap fixed point + **22/0**;
`test/mt` **85/0**; valgrind **0 errors**; soak **74.0 KB/cycle raw / 13.7 LS**
at 200 cycles.

### Phase 3 in the same session — file and workspace operations

`workspace/willRenameFiles` is now a real request: it is dispatched with its
id and answers a `WorkspaceEdit` that replaces the old module path token in
every indexed importer (open buffers included), or `null` when no import
matches; the index entries move afterward, and the legacy notification form
moves the index without writing an id-null response.

Multi-root is implemented: `initialize` maps `workspaceFolders` into
`Workspace.roots` (falling back to `rootUri`/`rootPath`), every folder
contributes module and workspace-symbol walk roots, labels use the first root,
and `didChangeWorkspaceFolders` updates the set and re-roots the caches/index.

The invalid `workspace.didChangeWatchedFiles` capability is gone.  When the
client advertises dynamic registration, `initialized` sends
`client/registerCapability` for `workspace/didChangeWatchedFiles`; the handler
invalidates diagnostics, semantic tokens, definition/reference entries and
reindexes the changed paths.

**Verification.** Conformance **30 cases / 28 pass**; the only red cases are
the phase-4 workspace-diagnostic scope and refresh.  Bootstrap fixed point +
**22/0**; `test/mt` **85/0**; valgrind **0 errors**; soak **70.9 KB/cycle raw /
39.6 LS** at 200 cycles.  ASCII endpoint replay has six intended phase 2–3
differences (quickfix capability, workspace capability, initialize, two code
actions, workspace-diagnostic version) and no others.

### Phase 4 in the same session — pull diagnostics

`workspace/diagnostic` now reports the indexed workspace instead of only open
documents: it walks up to 500 indexed `.mt` files, appends open documents the
index has not seen, reuses the per-document fingerprint cache, and carries
versions for open documents.  `initialize` reads
`workspace.diagnostics.refreshSupport`; after `didChange`, configuration,
workspace-folder and watched-file changes the server sends
`workspace/diagnostic/refresh` when the client advertised it.  Push-only
clients keep the edited document's diagnostics; dependent open documents are
not proactively republished and update on their next edit, save or pull.

**Verification.** Conformance **30/30**, the gate is green.  Bootstrap fixed
point + **22/0**; `test/mt` **85/0**; valgrind **0 errors**; soak **75.6
KB/cycle raw / 16.2 LS** at 200 cycles.  ASCII endpoint replay still has only
the six intended phase 2–3 differences, with the workspace-diagnostic response
now covering the indexed workspace.

### Phase 5 in the same session — optional features

`documentRangeFormattingProvider.rangesSupport` is advertised and
`textDocument/rangesFormatting` formats each requested range independently,
returning one edit per changed range.  A shared `lsp/refresh.mt` sends
`workspace/{diagnostic,codeLens,semanticTokens,inlayHint}/refresh` after
content/configuration/folder/watched changes when the corresponding client
`refreshSupport` flag is set.

`workspace/diagnostic` and `workspace/symbol` honor client work-done and
partial-result tokens: diagnostics stream one document per `$/progress`
notification (final response empty), symbols send one partial array, and
begin/end bracket both.  No server-created progress token is needed; the work
is request-scoped, so `window/workDoneProgress/create` is not used.
`inlineCompletion`, `textDocumentContent`, `moniker`, `inlineValue`,
`documentColor` and notebooks remain intentionally unadvertised.

**Verification.** Conformance **35/35**, gate green.  Bootstrap fixed point +
**22/0**; `test/mt` **85/0**; valgrind **0 errors**; soak **68.9 KB/cycle raw /
5.7 LS** at 200 cycles; release archive and clean-path smoke green.  ASCII
endpoint replay has seven intended differences (the phase 2–3 set plus the
range-formatting capability object) and no others.

**Next.** No active LSP work; the program is complete.

## Session 144 — LSP conformance audit and enhancement plan

Audited the native LSP against the LSP 3.18 meta-model and live probes on
`build/stage2/mtc` (0.4.26).  No code changed; the durable output is
`docs/lsp-enhancement-plan.md`.

**Coverage.**  42 of 54 client→server requests are dispatched and 30 capability
keys are advertised.  Every core editor feature is present; missing items are
mostly auxiliary (`rangesFormatting`, file-create/delete operations, `moniker`,
`inlineValue`, `documentColor`, notebooks, and the 3.18 `inlineCompletion` /
`textDocumentContent` additions).

**Verified defects (P0).**

- **UTF-16 positions:** incoming positions are decoded correctly, but every
  emitted range is a UTF-8 byte column (semantic-token length for `"😀"` is 6
  instead of 4), and `didChange` counts scalars, so an astral edit lands at the
  wrong offset.
- **`codeAction` kinds:** `quickFix` instead of `quickfix`, so the standard
  Quick Fix filter does not match.
- **`workspace/willRenameFiles`:** it is a request returning `WorkspaceEdit |
  null`; the server dispatches it without an id and never responds (probe:
  timeout), and it does not compute import rewrites.
- **Completion resolve:** `collect_doc_text` searches for a line starting with
  the bare name (never matches `function foo`), and the resolve response
  rebuilds only `label`+`documentation` when docs are found.

**P1:** multi-root is advertised but `Workspace` has one root;
`workspace/didChangeWatchedFiles` is in the wrong capability and is never
dynamically registered; `workspace/diagnostic` reports open documents only and
never sends `workspace/diagnostic/refresh`; the lifecycle lacks
initialized/shutdown state and the exit-code rule; `$/cancelRequest` leaves
stale ids that can cancel a later reused id.  The host-parity harness masked
the rename defect (it sends the request as a notification) and the UTF-16
defects (ASCII fixtures).

## Session 143 — host retirement phase 4 (delete)

Retired the Ruby host tree.  The compiler, its suite and every gate are now
self-contained; the archived host is a read-only historical record.

**Archive and deletion.**  Tag `archive/host-ruby-0.4.26` (annotated, at the
session-142 tip) holds the complete pre-deletion tree.  Removed: `lib/` (269
files), the Ruby `test/**` suite (147 files; `test/mt` stays), `milk_tea.gemspec`,
`Rakefile`, `Gemfile`, `Gemfile.lock`, `.ruby-version`, `bin/mtc`,
`bin/profile-mtc-checks`, the VS Code grammar-sync dev script and its npm
script.  The Rakefile had no survivor: every task loaded the compiler through
`lib/milk_tea`, and the native commands (`bindings`, `imported-bindings`,
`toolchain`, `deps`) already own the vendored-library workflows.

**Host-coupled tools removed.**  `gen_cli_help` (its `cli_help.mt` is
authored), `bindgen_parity`, `imported_bindings_parity`, `check_parity`,
`unused_import_parity`, `parity_scoreboard`, `sexpr_parity`,
`sexpr_attribution`, and the LSP differential set (`lsp_project_audit`,
`lsp_audit_diffs`, `lsp_token_diffs`, `lsp_recovery_probe`, `lsp_cold_start`).

**Adapted to self-only.**
`cli_parity`/`diag_parity`/`lint_parity`/`format_parity` now require
`--record` or `--expect`; the live host branches, `--host*` options and
`pending:` markers are gone.  `lsp_parity` defaults to `--server self` (a
wrapper path still drives the valgrind gate); `dap_smoke` drives only the
native adapter and asserts the real lldb-dap breakpoint (`add`, breakpoint
stop, terminated); `wasm_smoke`/`docs_smoke` assert the self server only.
`gates.sh` drops every live parity gate, uses `golden_*` for the
analyzer/cli/linter/formatter/refactor areas, builds the dev compiler from the
seed (via the new `tools/bootstrap.sh --print-stage0`), and makes the examples
gate a self-only 49/49 build.  `bootstrap.sh` no longer accepts
`--allow-ruby-host`: a missing seed is a hard error.

**Bug found while validating the gates.**  The diagnostic harness crashed at
process teardown (Ruby 4.0.6, `coroutine_transfer` → `rb_source_location_cstr`)
after a 504-file sweep: `Open3`'s per-call reader threads trip a VM bug at
shutdown.  `diag_parity` and `lint_parity` now use a bounded spawn/wait pool
(`Process.spawn` + `Process.wait2`, temp-file redirection, `rlimit_as` for the
memory cap) with no Ruby threads, and force captured output to UTF-8 so the
recorded messages compare byte-for-byte.  Three consecutive 504-file replays
and two 672-file replays are green.

**Fresh-tree portability (found by the phase gate).**  A fresh `git clone`
under `/tmp` exposed three harness assumptions.  `format_parity` excluded
any path with an ancestor named `tmp`, so a checkout under `/tmp` formatted
nothing; it now checks repository-relative components.  `cache status` reported
the checkout's accumulated cache population; the oracle normalizes the counts
and byte total.  `toolchain doctor` prints machine state, so its row normalizes
the per-checkout pcre2 prefix and ignores the command's exit status while still
pinning the output shape.  It also stopped checking `ruby` and `bundle`: the
native toolchain needs neither.  The diagnostic/lint fixtures now write rows
sorted by path, so a re-record diffs by content instead of worker completion
order.  A literal fresh clone also needs the vendored `third_party/` sources
(what `mtc toolchain bootstrap` fetches once); the tracked tree plus those
sources builds with a failing `ruby` shim.

**Verification.**  Full bootstrap with a `ruby` shim that exits 127: the shim
was never invoked, **fixed point holds**, self-tests **22/0** (5:26).  Seed dev
build **24.6 s**.  `test/mt` **85/0**.  Recorded oracles: CLI **227/227**,
diagnostics **504 / 0 differ**, lint **672 / 0 differ**, formatter **774 × 3
modes / 0 differ** (the four `test/examples` fixtures were deleted, so the
fixture was re-recorded: 12 stale rows removed).  Examples **49/49**.
Imported bindings **29/29**.  DAP self-only green (real lldb-dap: `add`
breakpoint, terminated).  Docs and wasm smokes self=ok.  Valgrind **0 errors**;
soak **73.8 KB/cycle raw / 19.0 LS** (raw in the 70–80 band).  Release
`--skip-build` + `release_smoke` green.  Guard tests 15 runs / 52 assertions;
`--check --strict --ratchet` ok (two dead doctor helpers removed).  **Fresh-clone
gate:** a `git clone` of the phase-4 commit plus the vendored sources
bootstraps with the `ruby` shim (fixed point, 22/0, shim never invoked),
`test/mt` **85/0**, and replays the four oracles **227 / 504 / 672 / 774×3**
with no skips.

**Still open:** the output-diagnostic defects (CLI caret length, zero-column
linter warnings, constructor-field column) and the optional
completion-after-receiver extension.  No parity item remains.

## Session 141 — semantic conformance: conditions, named arguments, FFI

Closed the functional residuals the session-140 audit found: the self accepted
invalid programs in five areas, and valid out-of-order named arguments were
miscompiled by both compilers.

**Conditions.** `check_condition` now accepts only `bool` (an unresolved type
variable or `<error>` stays permissive) instead of "definitely non-bool", so
structs, enums, pointers, nullables and `null` reject with the host's message.
`infer_if_expr_type` checks the previously unchecked if-expression condition at
the enclosing statement anchor (`let n = if 1: …` reports at the binding).
`static_assert` includes `, got <type>`.  A function-typed field call
(`node.condition_fn(…)`) now yields its declared return type
(`member_call_result_type`), so the strict condition check does not reject
`std/behavior_tree.mt`, `std/fsm.mt`, `std/goap.mt` or `std/htn.mt`.

**Named arguments.** `infer_and_check_call` canonicalizes named arguments
before inference (`canonicalize_call_arguments`): unknown names, duplicate
names and a positional after a named argument are reported at the host's
message/position; a positional fills the first free slot and a named argument
may overwrite a positional slot, as the host does; omitted defaulted parameters
get a permissive placeholder so later arguments keep their parameter alignment.
Expected-type hints now follow parameter order for direct and imported
functions, methods and explicit specializations.  Lowering:
`expand_default_args` no longer returns early when the declaration has no
defaults but the call has named arguments, and the reorder/default fill now
runs for plain, imported, method, specialized-function and specialized-method
calls.  The host's method lowering had the same bug (`sub(y = 1, x = 10)`
returned -9 instead of 9); `lib/milk_tea/core/lowering/calls.rb` now applies
`expand_function_defaults` on the method path, and the new
`test/mt/named_arguments_test.mt` pins plain, method, defaulted and specialized
calls in both compilers.

**Extern/foreign calls.** `build_foreign_fn_sig` preserves the declaration's
`variadic` flag (it forced `true`), so a non-variadic foreign call checks arity
(`ext()` and `ext(1, 2)` reject).  `check_signature_call` checks external
arguments through `types_compatible_external_with_consts` (structural +
`str`/`cstr` boundary + void-pointer rules), and
`check_substituted_arguments` uses the same model.  Imported constants are
recorded under their qualified name (`sdl.ALPHA_OPAQUE`) and folded from
literal/member expressions; a constant whose initializer references the
imported module's own imports (`ALPHA_OPAQUE = c.SDL_ALPHA_OPAQUE`) is exempted
from the FFI range test, matching the host's fold.

**Imported/method specializations.** `check_imported_specialization_call` and
`check_specialized_method_call` now receive the argument list and run
`check_substituted_arguments` (arity + substituted parameter types) instead of
only substituting the return type; the session-140 `spec_method` and imported
`ident[int]` probes now match the host's message and position.

**Nullable targets.** `types_compatible_with_consts` skips the compile-time
numeric coercion when the target is nullable, and nullable auto-wrap is
exact-base plus the host's pointer coercions (`ptr`→`const_ptr`,
`own`→`ptr`/`const_ptr`); both-nullable bases compare likewise.  `ubyte? = 32`
and `g(32)` now reject like the host.  Type variables stay permissive until
substitution, keeping the generic arena/string paths valid.

Verification: the 57-file audit probe matrix is **36 agree / 0 verdict / 20
message / 1 position** (the message rows are the output-parity batch; two are
`diag_parity` import-path artifacts).  Dev suite **22/0**; host and self
`test/mt` **62/0**; bootstrap fixed point + self-tests **22/0**; `cli:parity`
**227/227**; `diag_parity check` **501/0/0/3 of 504**; `check_parity`
**647/26 of 673**; focused lint **501/3 of 504**; examples **49/49**;
`sexpr lower` **718 match / 1 differ / 53 host-rejected / 7 self-fail of 779**;
LSP harness 30/30 with the documented 3 request + 3 stress rows, recovery
6/6, canonical audit **10**; refactor guard `--check --strict --ratchet` after
the reviewed baseline refresh (**126,536** code lines; 6,345 duplicated / 884
windows; tests 22/62).

Remaining: the constructor-field position (only for a `let` initializer), and
the output-parity batch described in the Handoff (diagnostic type
qualification, module/positionless rendering, the CLI caret length, linter
warning columns, `lint` on unresolved imports).  Completion after a non-text
receiver remains an optional LSP extension.

## Session 140 — LSP hover latency and chained receivers

Closed the handoff's LSP latency item and added member resolution for receivers
the source text cannot resolve.

**Hover latency.** Baseline on `semantic/analyzer.mt`: **27–37 ms** median per
hover (host floor 10–18 ms).  A `perf record` of the hover drive put **45% of
samples in `str_byte_at`**, split between `String.as_str` UTF-8 validation
(21%) and direct scans: every hover arm re-fetched an owned copy of the
document (`document_source`), validated it again, and re-hashed the whole file
for the token, binding and analysis caches; `position_params` re-did the same
for the request position.  The fix is one per-document text cache:

- `Workspace.document_text` returns the current `str` and content hash,
  validated/hashed **once per document version**.  An open document borrows its
  `open_docs` buffer (no copy; the entry is dropped on every open/change/close);
  a closed one owns a copy and is revalidated by its `(size, mtime)` stamp.
- `Workspace.document_hash_for` lets `document_tokens` and `document_bindings`
  reuse that hash when the caller passes the cached view (pointer + length
  identity), instead of scanning the text per lookup.
- `analysis_entry_for` and `position_byte_offset` read the cached view, and
  `handle_hover`/`resolve_cursor_at`/`resolve_import_cursor` pass it down.

Result: **2.0–7.7 ms median** by probe class on `analyzer.mt` (`local` 4.6,
`str-method` 3.4, `field-method` 2.0, `field-chain` 7.7, `keyword` 4.6 ms),
now faster than the host's 10–18 ms floor.  Behavior is unchanged: the harness
is 88/88 requests with only the documented rows, the audit's differing set is
the documented rows plus the new receiver rows below, and the soak stays in the
recorded raw band (78.3 KB/cycle / 30.2 LS).

**Chained receivers.** The host's `member_access_chain_at` requires an
identifier immediately before the dot, so `read(obj_ptr).get_object(key)`,
`make_sample().sum()` and `particles[0].y` answer null (or, for definitions, a
same-named global).  The analyzer now records the inferred type of a member
access's receiver at the member name's position
(`Analysis.member_receiver_types`, keyed by `binding_key`) when the receiver is
not a plain name/field chain; `receiver_is_text_chain` gates the record so a
chain keeps its existing text resolution.  The LSP adds
`cursor.member_dot_at` (a dot member regardless of the receiver shape) and falls
back to `analyzer.member_receiver_type_at` when `receiver_path_type` cannot
resolve the text path.  Hover, definition, declaration and typeDefinition share
the arm, so all four resolve; completion after such a receiver (`read(p).|`) is
**not** extended (there is no member token to key the fact on).  The added fact
is O(1) per lookup and costs no per-hover scan; the map is analysis-only and
does not affect lowering/C output.

**Memory incident (operational).**  The full `sexpr lower -j 16` sweep ran the
seven `main*.mt` loop-guard artifacts concurrently: each peaks **3.8 GiB**
(`VmPeak 3.84 GiB`, measured; `emit-c main.mt` 3.39 GiB, `build main.mt`
3.43 GiB) and the seven plus the editor/browser exhausted this 31 GiB
workstation (the kernel killed an unrelated 12.9 GiB Python process).  The gate
and the documented command are now `-j 4 --mem-mb 8000` (validated: the cap
still reaches the loop guard), and `sexpr_parity` caps the default lower jobs at
4 and warns when no cap is passed.

**Match-scrutinee dispatch (fixed).**  Matching on a variant-arm payload value
(`match x:` where `x` is bound by `Outer.some as x`) was rejected by the host
with `match requires an enum, variant, or integer scrutinee, got Outer.some
payload`, while the self's analyzer accepted it and the lowering aborted with
`match requires known type, got Outer_some`.  The same fatal hit a `float`,
`bool`, `char` or nullable scrutinee.  `check_match_stmt` and
`infer_match_expr_type` now run the host's dispatch first (enum, variant,
integer, `str`, tuple; a recovered `<error>` stays permissive), report the
host's message at the `match` token with its length, and skip the arms — so
structs, flags, payloads, floats, bools, chars and nullables are diagnosed
instead of crashing.  `match_scrutinee_text` renders the host's qualified
`to_s` for the message (`tmp.main.S`, `std.vec.Vec[int]`, `Outer.some payload`).
A prelude type with no import binding (`Option[int]` in a single-file check)
keeps its local arm table.

The check exposed a real inference gap: the self typed event `wait()` as
`void`, while the host returns `Task[Result[payload|void, EventError]]`.
`event_method_call_type` now builds that type from the event's declared payload,
so `match await no_payload_event.wait()` in `examples/event_stress_test.mt`
remains a valid `Result` match (the example builds and runs byte-identically).
Regression: `test_match_on_arm_payload_is_flagged` (message, line, column).

**Harness signal handling.**  `sexpr_parity` recorded a signal-killed self
process (the documented `main*` loop-guard abort is SIGABRT) as exit status 0,
which classified its empty output as a `differ` and could hide a real self
crash.  The runner now records `128 + signal`; the focused artifact run is
**1 differ + 7 self-fail**, and so is the full sweep (717 match / 1 differ / 53
host-rejected / 7 self-fail of 778), deterministic.

Verification: bootstrap fixed point + self-tests **22/0**; `test/mt` **61/0**;
CLI **227/227**; `diag_parity check` **501/0/0/3 of 504**; `check_parity`
**647/26 of 673**; examples **49/49** (the event example included); focused
lint unchanged; `sexpr lower` **717 match / 1 differ / 53 host-rejected / 7
self-fail** with the same eight artifacts; LSP harness **88
requests** (3 documented request rows: `hover/chained-method`,
`hover/imported-variant-arm`, `typeDefinition/imported`) + the 3 stress rows;
recovery **6/6**; canonical audit **10** (the 8 documented rows + 2 warm
artifacts); valgrind **0 errors**; soak **78.3 KB/cycle raw / 30.2 LS**;
refactor guard `--check --strict --ratchet` after the reviewed baseline refresh
(126,014 code lines; duplication unchanged).


## Session 139 — call-argument compatibility

Ported the host's call-argument model; the session-138 table now matches in both
directions, including the diagnostic message and column.

**Expected-type inference.**  `infer_and_check_call` now resolves per-argument
expected types before inferring any argument (`call_argument_expected_types`,
`semantic/analyzer.mt`): direct functions, imported module functions, local and
imported struct constructors (by field name), static struct methods, value-
receiver methods on a bare local or `this` (the receiver's declared type is in
scope, so no inference is needed), and explicit specializations through a quiet
type-argument subset.  An argument whose parameter is not statically known
(generic parameter, unresolved callee, named-argument call) is inferred with
**no** hint, not with the enclosing expression's hint — a `return f(...)` no
longer forces `f`'s arguments to the function's return type.  Named-argument
calls keep no positional hints because the host canonicalizes argument order and
the self does not.

**Compile-time numeric range.**  `fold_int_constant` no longer requires a
`const` table: literals and literal arithmetic fold everywhere, and the table is
only needed to resolve named constants.  `types_compatible_with_consts` no
longer accepts an unevaluable integer literal chain as compatible (the float and
char contextual forms keep their rules), so `f(if cond: 300 else: 200)` cannot
hide behind the old blanket rule; the if/match hint checks now pass
`ctx.const_values`, which is what makes the *fitting* branch chain (`32`/`200`
into `ubyte`) keep the declared type while the out-of-range one selects the
common type and is rejected.  The same folding is applied at
`check_signature_call`, struct construction, the `array`/`span`/`simd` builtin
constructions (which now also set the element/`len` expected type), and
`expect_eq`/`expect_ne`.

**Explicit specializations.**  `check_specialization_call` argument-checks a
generic function's positional arguments with the explicitly substituted
parameter types (`check_substituted_arguments`).  A bare specialized value
(`work_ready[Frame]` passed as a function value) is not an arity check: the
`infer_expr_inner` path passes `check_call = false`.

**Host pathology found while iterating.**  A `let resolved = f(...) else:` guard
binding an `Option[types.Type]` payload in this module made the host analyze the
self-host source ~4.5x slower (69 s → 297 s for `mtc check .../main.mt`,
GC-dominated); the equivalent `match` keeps it at 66 s.  The quiet-specialization
helper uses the `match` form; keep that shape in mind for future
`Option[types.Type]` guards in the compiler sources.

Verification: the 26-probe matrix (the seven session-138 rows in both statement
and `return` contexts, plus methods, static methods, constructors, imported
functions, and explicit specializations) is 26/26 on exit status and message;
dev suite **22/0**; bootstrap fixed point + self-tests **22/0**; `test/mt`
**61/0**; CLI **227/227**; `diag_parity check` **501/0/0/3 of 504**;
`check_parity` **647/26 of 673** (identical to the pre-change compiler); focused
lint **501/3 of 504** (the documented residue); `sexpr lower` **717 match / 8
differ / 53 host-rejected of 778** (the same eight artifacts); examples
**49/49**; LSP harness **87 requests** with the same 2 request + 3 stress rows,
capabilities 30/30, recovery OK; refactor guard `--check --strict --ratchet`
after the reviewed baseline refresh (125,770 code lines; 6,343 duplicated lines
/ 883 windows).

Known and left alone (each is outside the session-138 table and pre-dates this
change unless noted):

- **Named call arguments** still skip positional type checking (the self's
  `check_signature_call` bails on `any_named`; the host canonicalizes them to
  parameter order).  Constructors are checked by field name.
- **Explicit specialization on imported functions and specialized methods**
  (`heap.must_alloc[T](...)`, `x.method[T](...)`) resolves and substitutes the
  return type but does not yet argument-check; local generic functions do.
- **Extern/foreign call arguments** remain unchecked (`check_signature_call`
  returns early for `sig.is_extern`); the host checks them with
  `call_argument_compatible?(external: true)` and the passing-mode rules.
- **Nullable numeric parameters**: `let x: ubyte? = 200` and `g(200)` with
  `g(x: ubyte?)` are still accepted, while the host rejects both.  The
  nullable auto-wrap rule in `types_compatible_with_consts` recurses into the
  numeric coercion; the accurate fix is the host's exact-base auto-wrap plus
  nullable-aware pointer-coercion rules, deliberately not changed here because
  it moves assignment/return diagnostics the handoff asked to keep stable.
- **Constructor field diagnostics report the construction expression's column**
  rather than the host's binding/statement column (`field P.value expects ...`);
  pre-existing, visible for the newly rejected out-of-range constants.

**Closed by session 141:** named arguments are canonicalized and type-checked;
imported/method explicit specializations argument- and arity-check;
extern/foreign calls check arity and the external compatibility rules; nullable
targets use the host's exact-base auto-wrap.  The constructor-field column
remains the only item from this list and was re-adjudicated in session 146
(the self keeps the construction expression's column by design).


## Session 138 — formatter audit

Audited `mtc format` against the host on a scratch corpus of style cases (long
parameter/call/logical/wrapped expressions, doc and inline comments, blank-line
runs, trailing commas, continuation layout, numeric literals, variants, control
flow, attributes, external directives, Unicode, CRLF, tabs, syntax errors,
empty files) across `--preserve`, `--canonical`, `--tidy` and a 60-column
`--max-line-length`, plus `--check`, `--write`, directory operands, `.mt-lint.yml`
configuration, `--timings` and the CLI validation errors.  Four defects fell
out:

1. **`format DIR` without `--check`/`--write` walked the tree before rejecting
   it.**  The multi-source guard ran after `expand_source_operands`; on the
   repository's `tmp/` (184k files) the recursive walker's sorted insertion did
   not finish, so the command hung instead of printing the host's usage error.
   The guard now runs before expansion: the same message and exit status as the
   host, in 0 s.
2. **Formatter failures printed a generic `error: <path>: parse error` on
   stdout** instead of the host's `error[lex/error]` / `error[parse/error]`
   block on stderr.  The command now re-lexes/re-parses on the failure path and
   renders the first diagnostic exactly as the host's raised error does.
3. **Diagnostic blocks rendered tabs verbatim.**  The host's `ErrorFormatter`
   replaces a tab with one space; `print_diagnostic_block` now does the same, so
   a tab-indentation error is byte-equal.
4. **Canonical formatting of an empty (or whitespace-only) file returned an
   empty string**, while the host's pretty printer emits one newline.  The
   canonical path now appends the newline; `--preserve`/`--tidy` still leave an
   empty file empty, as the host does.

The matrix ran 339 host/self comparisons (outputs, stderr, exit codes,
idempotency and `--check` on formatted output); every one matches except the
documented Unicode `--check` difference below.  `format --write` and
`format --check` on a directory, `.mt-lint.yml`'s `max_line_length`, the
`--max-line-length` override and `--timings` (phase list normalized) match.
`--preserve` is byte-identical on every LF fixture; CRLF normalizes to LF in
all three modes, as the host does.

Documented difference: **`format --check` on non-ASCII canonical source**.  The
host's canonical printer returns an ASCII-8BIT string, so its
`source != formatted` comparison is true whenever the file contains non-ASCII
bytes, and `--check` reports `needs formatting` even though the bytes are
identical (and `--write` would rewrite the file).  The self compares bytes and
reports `already formatted`.  This is host-side; do not "fix" it back.

Discovered while testing (not fixed): **call-argument compatibility is wrong in
both directions.**  A scratch coercion matrix with `f(x: ubyte)`:

| argument | self | host |
| --- | --- | --- |
| `f(32)` | ok | ok |
| `f(300)` | **ok** | error |
| `f(if cond: 32 else: 200)` | ok | ok |
| `f(if cond: 32 else: ch)` (`ch: ubyte`) | **error** | ok |
| `f(if cond: lo else: hi)` (both `ubyte`) | **error** | ok |
| `f(if cond: 300 else: 200)` | **ok** | error |
| `let x: ubyte = if cond: 32 else: 300` | **ok** | error |

Root cause: `infer_and_check_call` (`analyzer.mt:6249`) infers every argument
before the callee signature is resolved, with the ambient
`ctx.expected_type_hint`; inside `return f(...)` that hint is the function's
return type (`int`), so a `ubyte`-typed conditional argument is forced to `int`
and rejected.  The host resolves the callee first and infers each positional
argument with `expected_type: parameter.type`
(`core/semantic_analyzer/calls.rb:817`).  The second half is the self's
`check_signature_call` -> `incompatible_value`, whose scalar fallback is
permissive (`f(300)` passes); the host's `call_argument_compatible?`
(`core/semantic_analyzer/type_compatibility.rb:6`) applies
`exact_compile_time_numeric_compatibility?`, `lossless_integer_compatibility?`,
nullability, mutable-to-const pointer, own-to-raw, cstr-literal, external and
proc/task rules.  The accurate fix is one port of that model (per-parameter
expected-type inference plus the compatibility function at argument sites), not
a conditional-inference tweak or a call-site cast; the `push_byte(if ch == 9: 32
else: ch)` occurrence in `main.mt` was worked around with explicit branches and
is not itself a target.  Recreate the matrix from this table.

Regression coverage: in-language
`test_empty_source_formats_to_a_newline` (`projects/mtc/test/ast_formatter_test.mt`)
and three CLI parity cases (`format-directory-no-check`, `format-parse-error`,
`format-unicode`) — **227 cases**.

Verification: dev suite 22/0; bootstrap fixed point; `test/mt` 61/0; CLI
**227/227**; formatter **778/778** in all three modes; refactor guard
`--check --strict --ratchet` after the reviewed baseline refresh (125,521 code lines; 6,343 duplicated lines / 883 windows).

## Session 137 — nested-type facts and the rename index move

Closed the two findings recorded in session 136.

**1. `milkTea/debugInfo`'s Functions section now qualifies nested named types.**
`binding_type_repr` resolved only a bare top-level `ty_named` through
`analysis.types`; a nullable base or a generic argument kept the recorded
spelling, so a function returning `Sample?` rendered `Sample?` against the
host's `main.Sample?`, and `Option[Sample]` rendered `Option[Sample]` against
`std.option.Option[main.Sample]`.  The renderer now walks the type
(`append_binding_type_repr`): a named type without a module takes the declared
type's module, a `ty_nullable` recurses through its base and re-appends `?`,
generic/imported arguments recurse, and the prelude variants render under
`std.option`/`std.result` (their `analysis.types` entries are deliberately
bare, so the special case is required and is also what keeps the recursion
finite).  Harness: new `nested_types.mt` fixture with `Sample`, `Sample?`,
`Option[Sample]` and `Pair[int, Sample]` returns, opened so the host uses its
loader-backed cached AST; `milkTea/debugInfo/nested-types` is byte-equal.

**2. `workspace/willRenameFiles` moves the index entries.**
The old handler only cleared the old path's diagnostic and semantic-token
caches.  The host's `rename_indexed_file` moves the indexed document to the new
URI and applies module-index events, so the moved content joins the workspace
scans.  The self now reads the old path's content (open buffer or disk), notes
it in the reference index under the new path, warms the definition index there,
and drops the old path's diagnostic/semantic-token/definition/reference
entries before reindexing.

The moved path is deliberately **not** a feature document: an isolated probe
shows the host answering no hover, `documentSymbol` or `references` for the new
URI and listing no symbol for it in `workspace/symbol`, because the client
completes the rename with didOpen/didClose.  A first implementation with a
virtual-document map served hover/symbols/references for the new path and had
to be removed; the recorded `c5/willRenameFiles+references` row pins that the
rename does not leak the moved copy into the old document's reference answer.

Verification: dev suite 22/0; `test/mt` 61/0; bootstrap fixed point; harness
**87 requests + 28 stress probes** with the 2 documented request rows and 3
documented stress rows; recovery 6/6; refactor guard `--check --strict
--ratchet` after the reviewed baseline refresh (125,477 code lines;
`debug_info.mt` +67, `workspace_notifications.mt` +25, `workspace.mt`
unchanged).

Known and left alone: the host's first `workspace/symbol` answer after a cold
start can lag its asynchronous index (observed as a main-only answer against
the self's complete one on a fresh probe workspace); the harness's warm
sequence is byte-equal.

## Session 136 — guarded-local member hover

Hovering a member of a local declared with an `else` guard
(`var file_path = uri_ops.file_uri_to_path(uri) else:` at
`projects/mtc/src/mtc/lsp/code_lens.mt:30`) answered null on `.release`
(line 33) and `.as_str` (line 40), while the host answered the
`std.string.String` method.  The analyzer narrows the guarded binding to the
success type (`String`), and both `completion.mt` and the host's facts use that
type, but `navigation.mt`'s `local_type_at_line` returned the initializer's
recorded type (`Option[String]`) for an unannotated local; `receiver_path_type`
therefore started at `Option` and every member path bailed.

New `type_render.local_binding_type(analysis, stmt)` is the single binding-type
rule: the resolved annotation for an annotated local, else the initializer's
inferred type, narrowed with `analyzer.unwrap_nullable_type` when the
declaration carries an `else` body (`T?`, `Option[T]`, `Result[T, E]`).
`navigation.mt`'s `local_type_at_line` and `completion.mt`'s `find_local_type`
both delegate to it, so the narrowing cannot drift between them again
(`completion.mt` already had it inline; navigation did not).

Verified against the host: `code_lens.mt:33:21` and `:38:19` answer
`editable function release() -> void` at `std/string.mt:56`, and `:40:25`
answers `function as_str() -> str` at `std/string.mt:211` — text and location
byte-equal.  Harness: **86 requests**; new `hover/guarded-local-method`
(nullable struct local, `holder.doubled()`) and `hover/guarded-local-str-method`
(`Option[string.String]` local, `text.as_str()`) in `strings.mt`.  Two C5
probe fixes were needed for the recorded set to stay stable: the
cache-invalidating notifications (`willRenameFiles` included) now run after
every measured probe — the host moves its indexed document to `renamed.mt`,
and a later references query saw that copy — and the added-workspace-folder
symbol probe polls a fixed number of times so the host's asynchronous reindex
has settled.

Verification: dev suite 22/0; `test/mt` 61/0; bootstrap fixed point; harness
86 requests with the two documented request rows and three stress rows
(stable over two runs); recovery 6/6; project audit hover on SimpleGame 915
entries with the one documented `lb@1653:24` row; `tmp/probe-ws` 0 hover
diffs; refactor guard `--check --strict --ratchet` after the reviewed baseline
refresh (125,385 code lines; completion −11, navigation −5, type_render +17).

Discovered while extending the fixture, not fixed here (both fixed in session
137):

1. **`milkTea/debugInfo`'s Functions section does not qualify nested named
   types.**  A function returning `Sample?` renders `Sample?` (host
   `main.Sample?`), and `Option[Sample]` renders `Option[Sample]` (host
   `std.option.Option[main.Sample]`): `binding_type_repr` resolves a bare
   `ty_named` through `analysis.types` but does not recurse into a nullable
   base or generic arguments.  The recorded main fixture has no such return
   type, so its row stayed byte-equal; adding one reproduces the diff.
2. **`workspace/willRenameFiles` does not move the index entry.**  The host's
   `rename_indexed_file` moves the cached document (and applies module-index
   events) to the new URI, so later references include `renamed.mt`; the self
   invalidates caches for the old path only.  Both predate this session and are
   orthogonal to the binding-type fix.

## Session 135 — chained-hover audit

Audited hover at `projects/mtc/src/mtc/lsp/completion.mt:1863`
(`ast.Decl.decl_const as c:`), then followed the chain into `c.name`,
`c.const_type` and the package-local module paths.  Four defects and one
documented artifact:

1. **Module resolution ignored the requesting file's package root**
   (`navigation.mt`).  `resolve_module_source_path` resolved against the
   workspace roots only, while the loader and every analysis use the file's
   effective roots.  A project-local module (`import node` under a package
   `source_root`, or any `mtc.*` module in the compiler sources) therefore
   failed on import-line hover and on the alias/member/type-method/field/enum
   paths, even though the analysis had loaded it: `ast` and `Decl` on the audit
   line returned null while the local's hover rendered `Decl … *From
   mtc.parser.ast*`.  New `resolve_module_source_path_for(ws, name, from_path)`
   tries the workspace roots first and falls back to the file's effective roots;
   it is threaded through `resolve_module_reference`/`resolve_module_member`/
   `import_alias_member_decl`/`resolve_type_method_hover`/`field_hover_result`/
   `resolve_member_method_hover`/`imported_type_method_hover`/`resolve_enum_member`/
   `handle_type_definition`/`alias_member_module_path`/`named_argument_label_hover`.
   The line now hovers `ast` → `module mtc.parser.ast`, `Decl` → `type Decl`;
   an extending method in a package-local module (`b.get()`) resolves instead of
   falling through to the builtin `get`.
2. **Match-arm payload fields had no hover** (`navigation.mt`).
   `type_of_value_with_bindings` did not resolve an `as name` binding (it only
   looked at `stmt_local` and parameters), and `field_hover_result` scanned only
   struct declarations, so `a.value`/`o.value`/`c.name` were null.  The arm
   binding's recorded payload type is now a fallback after the ordinary
   local/parameter scan, and `variant_arm_field_hover` renders the payload
   field; `field_of_type` walks payload fields too, so the chain continues.
   `c.name` → `field name: str`; `c.const_type` →
   `field const_type: ptr[TypeRef]` `*From mtc.parser.ast*`.
3. **`str` member hover was unreachable** (`navigation.mt`).  `ty_str` is its
   own type variant, and neither `type_to_key_name` nor `receiver_type_name`
   mapped it to `"str"`, so any member access on a `str` (`c.name.equal`,
   `s.len()`, `s.slice(…)`) bailed before the method table; `str`'s builtin
   fields were also missing from `builtin_field_type_name`.  Added the `ty_str`
   key on both helpers, `str.data`/`str.len` from the host's `StringView` field
   table, and payload-field walking in `field_of_type`.  `equal`, `slice` and
   `len` now match the host (`function equal(right: str) -> bool`,
   `field len: ptr_uint`, …).
4. **Module-qualified variant arms — self-better extension.**  `decl_const` in
   `ast.Decl.decl_const` now answers `Decl.decl_const(name: str, …)`, and
   `local.Local.one` answers `Local.one(value: int)`.  New
   `resolve_imported_variant_arm` resolves the alias/type's module, takes the
   module AST from the requesting document's loaded program
   (`DocumentAnalysis.program`, so no extra parse), and finds the arm in that
   type.  The host returns null for a module-qualified arm (it resolves only the
   local `Kind.alpha` form); this is documented as a self-better difference and
   pinned by `hover/imported-variant-arm`.  Warm cost is the same as the former
   null path (~23 ms on the audit line; callgrind puts the arm lookup itself at
   <0.1%); the program entry is threaded from the analysis already loaded for
   the request.
5. **`Defined at` on an arm binding.**  The self prints
   `completion.mt:334` for `c` — the only indexed `c` declaration before the
   arm; `as` bindings are not in the definition index.  The host's token-index
   answer for an arm binding is the same artifact class (on the fixture it
   pointed into an unrelated `examples/box2d` file).  The hover *text* is
   correct; the location is the documented index behaviour.

Performance: the new file-scoped fallback pays a package-manifest walk only when
the workspace roots miss a module; the hover mix on `analyzer.mt` moved from
30.5 to **32.5 ms** on the stage2 bench (a 35.6 ms dev-build run), host 16 ms,
still ~3.7x below the pre-token-cache 119.7 ms.  The ordinary `std`/root paths
take the same cheap first attempt as before; `str` method hover (`equal`,
`slice`) walks the imports to `std.str` and then hits the analysis cache.  The
imported-arm hover on `completion.mt` is **20.3 ms** warm (the former null path
was 23 ms; the arm lookup is <0.1% in callgrind) and a `Decl` type hover is
8.8 ms; the requesting document's program is threaded from the analysis already
loaded for the request, so no extra parse.

Harness: **84 requests** (77 + `hover/package-module`, `hover/package-type`,
`hover/variant-payload-field`, `hover/package-method`, `hover/str-method`,
`hover/str-method-field-chain`, `hover/imported-variant-arm`; the package
fixture is a nested `pkg/package.toml` with `source_root = "src"` plus
`pkg/src/local_mod.mt` and `pkg/src/user.mt`, and `strings.mt` holds the `str`
receiver/field-chain cases; the new fixtures stay closed so they add no
workspace diagnostics).

Verification: dev suite 22/0; `test/mt` 61/0; bootstrap fixed point; LSP harness
84 requests with the documented `typeDefinition/imported` and self-better `imported-variant-arm` rows; recovery OK;
canonical project audit **6**; valgrind **0 errors**; soak **70–80 KB/cycle raw
/ ~3–28 LS** (meter; the raw slope is noisy at 200 cycles); refactor guard
`--check --strict --ratchet` after the reviewed refresh (125,384 code lines;
6,341 duplicated lines / 882 windows).

## Session 134 — the session-133 LSP follow-ups and hover latency

Closed the four session-133 functional gaps and the hover re-lex:

1. **Hover inside `f"#{…}"`** (`lsp/fstring.mt`, new; `cursor.mt`).  The
   interpolation splitter (find the `#{`, balance braces, split the format
   spec, re-lex the expression) moved out of `semantic_tokens` into a shared
   module.  Cursor gained token-stream variants
   (`interpolation_token_at_in`, `interpolation_identifier_at_in`) so the hover
   range and resolution answer the *inner* identifier with the host's document
   coordinates.  A definition request keeps the plain token, as the host's
   definition pipeline does.  `hover/format-string` is host-identical (the range
   is the inner identifier, not the whole f-string).
2. **Cross-file rename** (`rename.mt`).  The self followed the host's
   `workspace_symbol_identity_rename_changes`: a cursor on a local binding keeps
   the scope-filtered same-file rename; every other name resolves the cursor's
   definition and renames each occurrence in every open document whose *own*
   definition resolves to the same `(path, line, column)`, with the host's
   lexical same-file fallback when nothing resolves.  Renaming an imported
   extending method now updates the declaration in its defining module and the
   call site.  `rename/imported-function` (a flat module is required: the host's
   import-dependency graph does not link the directory-shaped
   `mod_alpha/lib.mt`) covers it in the harness.
3. **`ref[ImportedStruct]` completion** (`completion.mt`).
   `imported_value_receiver_completions` now projects `ref`/`ptr` and nullable
   before the imported-member lookup, matching the host's
   `project_field_receiver_type_for_completion`; `r.` answers the struct fields.
4. **Imported generic field method hover** (`navigation.mt`, `completion.mt`).
   `resolve_member_method_hover` walks the full receiver chain (`ctx.lookup.set`,
   `this.cache.set`) instead of looking only at the segment before the dot:
   the first segment resolves through the analysis, each later one through the
   previous field's type.  `ImportedTypeRef`/`imported_type_reference`/
   `project_value_receiver_type`/`type_to_key_name`/`field_of_type` moved from
   completion to navigation so both features share one lookup.  Both the value
   and `ref[ImportedStruct]` receivers are host-identical on
   `hover/imported-field-method`.
5. **Per-document token and binding caches** (`workspace.mt`, `cursor.mt`,
   `navigation.mt`).  Hover asked for the same whole-file token stream a dozen
   times per request; each lookup re-lexed the file.  `Workspace` now keeps the
   one-document token stream (`document_tokens`) and scope bindings
   (`document_bindings`, with the source copy its name views point into), keyed
   by path and content hash; cursor gained `_in` variants over an existing token
   stream.  The hover path takes one source copy, passes it to every helper, and
   `note_document_tokens` skips the content hash when the reference index already
   holds the document (the index is dropped on every open/change/close).  Median
   hover on `semantic/analyzer.mt` (9,684 lines): **117–119.7 ms → 33.0 ms**
   (audit probe; 30.7 ms on the stage2 hover bench), host 16 ms; ~78% of the
   old cost was repeated `lex_reporting`, and the remaining gap is the
   loader-backed analysis lookup and definition-index warm, not tokenization.

Verification: dev suite 22/0; `test/mt` 61/0; bootstrap fixed point; LSP harness
**77 requests** (the 72 record plus `hover/format-string`,
`completion/ref-imported-field`, `hover/imported-field-method` ×2,
`rename/imported-function`) with only the documented `typeDefinition/imported`
row; recovery OK; canonical project audit **6**; valgrind **0 errors**; soak
**70.4 KB/cycle raw / 10.7 KB/cycle least-squares** at 200 cycles; refactor
guard `--check --strict --ratchet` after a reviewed baseline refresh (125,224
code lines; 6,353 duplicated lines / 888 windows — the shared f-string/type
lookup removed 28 duplicated lines).

## Session 133 — VS Code LSP audit on the compiler sources

Audited the self-host LSP in VS Code (`xdotool` + `spectacle`) on
`projects/mtc/src`: `semantic/analyzer.mt` (9,684 lines),
`lowering/lowering.mt` (18,472) and `lsp/completion.mt` (3,656), plus direct
host-vs-self probes (`tmp/lsp_audit_probe.rb`, `tmp/lsp_feature_matrix.rb`,
`tmp/lsp_hover_bench.rb` — scratch; recreate from this record).

Fixed in this session (host parity re-checked; the remaining differences are
listed below):

1. **Dead O(file²) hover scan** (`lsp/navigation.mt`).  `lexical_local_hover`
   always returned none — it built a hover string and released it — yet walked
   every line from the cursor back to line 1 with a full `cursor.source_line`
   scan.  It ran on every local-hover fallback: a string-literal hover on
   `analyzer.mt` took **675 ms**, now **144 ms**.  The function and its call
   are gone.
2. **Imported enum member hover** now reports the host's `*From <module>*` line
   (the owning module of the member's type).
3. **Hierarchy follow-ups were broken for standard requests**.  The spec nests
   the item under `params.item`, but `extract_item_field` read only top-level
   fields/arrays, so `typeHierarchy/supertypes|subtypes` and
   `callHierarchy/incomingCalls|outgoingCalls` returned null in VS Code.  The
   reader is now shared (`lsp.utils.extract_hierarchy_item_field`, deduplicating
   the two copies), unwraps `item` and `data`, and type-hierarchy items carry
   the host's `data` payload.
4. **Specialization completion order** (`name[...`) emitted the same 37 types
   in `Map` bucket order; it now follows the host's `facts.types` registration
   order (built-ins, prelude, module declarations).

Remaining findings, ranked:

- **Hover inside `f"... #{...}"` returns null** (host resolves the binding).
  The self's token pipeline sees the whole f-string token, so `identifier_at`
  never reaches the inner expression.  Fix: scan the f-string parts and resolve
  the inner expression through the cursor pipeline (the semantic-token scanner
  already splits them).
- **Rename is single-file** (`lsp/rename.mt` scans the current source only):
  renaming an imported extending method updates the call site but not the
  declaration in the defining module.  Reuse the references pipeline.
- **`ref[ImportedStruct]` receiver completion omits the struct fields** (host
  lists fields then extending methods); the receiver-type path needs to unwrap
  `ref` before the imported-member lookup.
- **Hover on `receiver.field.method(...)` with an imported generic field
  returns null** (`ctx.binding_type_by_id.set` in `analyzer.mt`; reproduced with
  a public `Holder.lookup: map_mod.Map[str, int]`).  The host resolves the Map
  method; the self's member chain stops at the field.
- **Large-file latency** (self; host comparison where noted): didOpen→diagnostics
  **0.79 s** (`analyzer`) / **5.8 s** (`lowering`); didChange→diagnostics
  **0.67 s** / **5.0 s**; `semanticTokens/full` **1.33 s / 4.5 s** (0.74 / 1.52 MB);
  `inlayHint` **149 / 652 ms** (266 / 577 KB); `documentSymbol` **35 / 74 ms**
  (412 / 834 KB); hover median **117 ms / 202 ms** vs the host's **16 ms** on
  `analyzer.mt`; `references` **1.8 s**.  `perf` over 40 hovers: ~78% in
  `handle_hover`, dominated by repeated whole-file `lex_reporting` calls plus
  `str_byte_at`/UTF-8 revalidation (18% of samples).  The host caches tokens per
  document; the self re-lexes for each lookup (the dedicated follow-up is a
  per-document token cache).
- **Memory**: LSP RSS 100 MB after `analyzer` diagnostics, **506 MB** after the
  feature sweep, 550 MB final; `lowering` 458 MB → 660 MB.
- **Diagnostics volume**: 370 items on `analyzer.mt` (291 warnings: 196
  `line-too-long`, 81 `owning-release-leak`) and 1,682 on `lowering.mt`.  The
  host reports the same counts, so this is parity, not an LSP divergence; the
  Problems panel is simply dominated by style warnings on the compiler source.
- **Minor**: `semanticTokens` omits `resultId` (no delta); type-hierarchy's
  range is the name span where the host uses a zero-width range (self-better);
  the self emits an extra correct `value:` inlay hint the host misses
  (self-better).

Verification: dev suite 22/0; `test/mt` 61/0; bootstrap fixed point; LSP harness
72 requests with only the documented `typeDefinition/imported` row; refactor
guard `--check --strict --ratchet` after the reviewed baseline refresh
(124,816 code lines; 6,381 duplicated lines / 891 windows — the shared
hierarchy-item reader removed 48 duplicated lines).

## Session 132 — format-string completion, the hover bail, and the attribute probe

Closed the three session-131 LSP residues; two were real and one was a
misdiagnosis:

1. **Format-string completion** (`lsp/completion.mt`).  Inside `f"...#{|}` the
   self fell through to the global bucket; the host answers only module values
   (sort `0_`, detail `name: type`), functions (`1_`, detail `function <name>`,
   no signature or snippet) and the enclosing function's completion-snapshot
   locals (`2_`).  New `format_string_completion_items` reproduces the host's
   context scan (the last `#{` with no `}` after it) and its item shapes.
   Locals come from the new shared `enclosing_function_for` scan: parameters
   typed from the analyzer's `FnSig`, then the function's direct `let`/`var`
   statements declared before the cursor (destructured names included); a
   nested block's binding and the statement declaring the binding stay out,
   exactly as in the host snapshot.  `emit_value_item`, `emit_module_value_items`
   and `emit_local_item` now take the sort bucket so the global bucket and this
   context share the emitters, and `find_local_type` resolves destructured
   names.
2. **Field-declaration hover on parse errors** (`lsp/navigation.mt`).  Removed
   the last `parse_error_count_for` bail; the helper answers from the
   loader-backed analysis, as `resolve_cursor` does since session 131.
   `parse_error_count_for` and `workspace.document_parse_error_count` had no
   other users and are gone (with the two imports the former used).
3. **Imported attributes in `@[...` completion: not a gap.**  A direct host
   probe shows `facts.attributes` is the same local-only set (built-ins plus
   the module's own declared attributes); an attribute imported from another
   module is absent from the host's list too.  Recorded so the residue is not
   re-opened.

Verification: dev suite 22/0; `test/mt` 61/0; bootstrap fixed point holds;
LSP harness **72 requests** (added `completion/format-string` and
`hover/field-declaration`) with only the documented `typeDefinition/imported`
row; recovery 6/6; canonical project audit **6** (the 4 documented rows plus
the 2 `str` builtin-hover warm artifacts); valgrind **0 errors**; the soak meter
reads the usual 74–75 KB/cycle raw; CLI parity 224/224; the direct host-vs-self
probe matches on all seven contexts (valid interpolation, mid-edit `#{`, nested
block, warmed and cold parse-error field hovers, attribute completion); refactor
guard `--check --strict --ratchet` with a reviewed baseline refresh (+185 code
lines, +1 shared parameter-loop window).

## Session 131 — VS Code LSP sweep and completion/diagnostic fixes

The session opened on the session-130 tree with an uncommitted LSP/loader batch
(found in the editor): cyclic-module pass-1 analyses are now owned by the cache
entry's region (pass-2 types borrow them; the old request-scoped scratch region
dangled them once a program was cached past the request), `effective_module_roots_for`
adds the file's enclosing `package.toml` source root and project root (a nested
package resolves by bare name from a monorepo root), the workspace index resolves
each file's imports through that source root, `collect_toplevel_names` hoists
`last_line` out of its declaration loop (quadratic on large files), inlay hints
collect scope bindings once per request, and signature help reports the real
active parameter via `cursor.call_context_at`.  Regression tests:
`module_loader_test` (`test_cycle_regions_survive_the_request_boundary`),
`module_roots_test` (7), `cursor_test` (4, new file).

The VS Code X11 sweep (xdotool + spectacle; direct LSP probes for host parity)
then fixed four defects:

1. **Crash on `completionItem/resolve`** — the completion doc-comment scan
   compared line prefixes by slicing `name.len` bytes; a multi-byte code point
   crossing that window aborted the server (`str slice end must be a UTF-8
   boundary`; core-dumped and gdb-confirmed).  New `str.starts_with_at` compares
   bytes at an offset without slicing; used by the completion scan, the two
   `navigation` prefix scans, and the linter scans (`reserved_name_column`,
   `is_struct_decl`, `matches_word_at`, `platform_drift.find_from`).  Regression
   test in `completion_test`.
2. **Missing completion contexts vs the host** — `@[...` attributes (built-ins
   then declared), named arguments for struct constructors plus the
   already-provided filter (function parameters and type fields), and `name[...`
   specialization type lists.  Parameter items now carry the host's
   `parameter name: type` detail.  Unit tests cover all four.
3. **Duplicate diagnostics** — the server pushed `publishDiagnostics` on
   open/change while also serving pull diagnostics; VS Code showed each item
   twice in hovers and tab badges.  `handle_initialize` records
   `Workspace.pull_diagnostics_active` from the client capability, and
   `publish_for_uri` / `publish_empty_for_uri` skip pushes exactly as the host's
   `@pull_diagnostics_active` gate does.
4. **Hover on buffers with parse errors** — `resolve_cursor` bailed on any parse
   error; the host hovers the partial AST.  The bail is gone: definition and
   hover answer on broken buffers like the host.

Also removed the now-dead `cursor.call_name_at` / `callee_before` (the
text-based named-argument path and `call_context_at` supersede them).

Verification: self suite **22/0**; `test/mt` **61/0**; LSP harness **30/30**
capabilities with only the documented `typeDefinition/imported` row (70 requests
re-recorded); `refactor_guard --check` ok; bootstrap fixed point **holds**
(`stage2.c == stage3.c`).  Not re-measured: the corpus-wide lint / `lower` / CLI
sweeps (no output path changed).  The editor checks covered highlight across token
types, hover, completion (member, named-argument, attribute, specialization,
import, global), signature help, inlay hints, definition, references, rename,
document/workspace symbols and code lenses.

Known LSP residues left (all closed in session 132 — see that section): format-string
(`f"... #{`) completion still falls back to the global bucket (the host narrows to
values/functions/locals); `field_declaration_hover` still bails on parse
errors; imported attributes are not listed in `@[...` completion (the analysis
exposes only local `declared_attributes`).

## Session 130 — long-function closeout

Decomposed the remaining nine functions ≥ 200 lines, closing the target list
(`binding_at` stays excluded):

1. **`std_registry_lookup`** (`std_catalog.mt`) 238 -> 120 by collapsing each
   registry entry to the established inline `if name == "...": return ...`
   form.  The table stays in one function: splitting a homogeneous table would
   create cross-function duplicate windows (the session-122 `binding_at`
   lesson).
2. **`generate_internal`** (`bindgen.mt`) 221 -> 40 via
   `create_translation_unit` (85), `clang_ast_arguments`,
   `generate_from_clang_result` (92), `clang_failure_message`, and the shared
   `translation_unit_write_error`.
3. **`emit_format_string_helpers`** (`c_backend.mt`) 219 -> 4 via
   `emit_format_string_core` (99), `emit_format_string_length_helpers` (29),
   and `emit_format_string_append_helpers` (93), in the original emission
   order; C output is byte-identical.
4. **`load_context`** (`packages/lock.mt`) 218 -> 100 via
   `parse_lock_schema_version` (15), `validate_lock_root_package` (31), and
   `parse_lock_records` (90).
5. **`bindgen_command`** (`main/bindings_cli.mt`) 216 -> 87 via
   `parse_bindgen_args` (73) with `BindgenCliArgs`/`BindgenCliError`,
   `load_bindgen_policy` (11), `run_bindgen_with_report` (35),
   `run_bindgen_with_output` (23), and the shared
   `write_generated_source`/`print_generated`.
6. **`build_manifest`** (`packages/manifest.mt`) 213 -> 150 via
   `resolve_package_kind` (21), `resolve_manifest_source_root` (27),
   `resolve_manifest_profile` (15), `resolve_manifest_platform` (15), and
   `resolve_manifest_html_template` (22).
7. **`dump_ir_with_analyses`** (`sexpr.mt`) 212 -> 21 via
   `register_program_decl_kinds` (34) and the ten `ir_*_value` collection
   builders.
8. **`resolve_name_in_analysis`** (`lsp/navigation.mt`) 209 -> 56 via
   `function_name_hover` (18), `method_name_hover` (70),
   `value_name_hover` (28), `interface_name_hover` (48), and
   `type_name_hover` (57).
9. **`choose_registry_version`** (`packages/solver.mt`) 207 -> 62 via
   `load_registry_versions` (33), `select_matching_versions` (21),
   `filter_locked_registry_versions` (17), `locked_version_error` (15),
   `no_matching_version_error` (12), `append_version_requirement` (11), and
   `visit_registry_candidates` (77).

Structural: **168 files / 156,522 lines / 124,328 code**; 111 edges; 0
layering/naming/alias/vocabulary violations; 35 unused + 6 test-only exports;
**6,379 duplicated lines / 901 windows** (unchanged); **1 function >= 200
lines** (from 10; only the excluded `binding_at`, 385); 11 files >= 2,000; 0
markers; tests 21/61.  The +173 code lines are helper signatures and call
sites; the baseline refresh records the deliberate structure change.

Verification: dev suite 21/0; `test/mt` 61/0; full CLI **224/224**; `sexpr
lower` **715 match / 8 differ / 53 host-rejected / 0 self-failed of 776** (the
same eight documented artifacts); LSP **30/30 capabilities + the documented
`typeDefinition/imported` row**, recovery 6/6; bindgen **33 match / 0 differ /
0 error / 1 custom of 34**; `std list` byte-identical to the host and the
`emit-c` output for `examples/language_baseline.mt` byte-identical to the
stage2 compiler; bootstrap fixed point holds (`stage2.c == stage3.c`); guard
`--check --strict --ratchet`; guard tests 15/15; refactor gate 6/6.

Next: no long-function targets remain.  `binding_at` (385) stays excluded — a
constant table whose split raised duplication when attempted in session 122.

## Session 129 — dispatch/format/lint/AST splits and bounded test builds

Decomposed four long functions and fixed the `mtc test` memory accumulation
found while measuring the verification sweeps:

1. **`dispatch_method`** (`lsp/server.mt`) 202 -> 31 via
   `dispatch_known_method` returning `Option[bool]` (continue / exit /
   unhandled).
2. **`emit_decl`** (`pretty_printer/ast_formatter.mt`) 221 -> 147 via
   `emit_decl_struct` (returns the header index for inline comments),
   `emit_decl_variant`, and `emit_decl_when`.
3. **`stmts_structural_equal`** (`linter/linter.mt`) 204 -> 171 via
   `stmt_if_equal` and `stmt_for_equal`.
4. **`expr_value`** (`sexpr.mt`) 204 -> 191 via `expr_if_value` and
   `expr_match_value`.
5. **Memory: `mtc test` builds are region-scoped** (`main/test_cli.mt`).
   `build_runner_file` now compiles each synthesized runner inside a
   `heap.Region` and calls `release_all()` when the build finishes; diagnostics
   and build errors are copied out before the region is freed.  The parser/AST,
   analyzer, lowering IR, and C backend allocations are therefore reclaimed
   after every test file instead of accumulating until process exit.
   Measurements: `test projects/mtc` (21 files) 7.17 GB -> 2.80 GB, now bounded
   by its largest single build (`c_backend_test` 2.57 GB);
   `test/mt` (61 files) peaks at 135 MB; 21 trivial files peak at 10.8 MB.
   The remaining parallel spike is the parity harnesses spawning independent
   compilers (`-j`); use `--mem-mb` and a lower `-j` for heavy `lower` sweeps.

Structural: **168 files / 156,268 lines / 124,155 code**; 111 edges; 0
layering/naming/alias/vocabulary violations; 35 unused + 6 test-only exports;
**6,379 duplicated lines / 901 windows**; **10 functions >= 200 lines** (from
14); 11 files >= 2,000; 0 markers; tests 21/61.

Verification: dev suite 21/0; `mtc test projects/mtc` 21/0; `test/mt` 61/0
(peak 135 MB); full CLI **224/224**; `sexpr parse` **772 / 0 / 4 of 776**;
formatter **776/776 in all three modes**; focused lint **501 / 3 of 504**; LSP **30/30
+ the documented `typeDefinition/imported`**; guard
`--check --strict --ratchet`; bootstrap fixed point; refactor gate 6/6.

Next: `std_registry_lookup` (238), `generate_internal` (221),
`emit_format_string_helpers` (219), `load_context` (218), `bindgen_command`
(216), `build_manifest` (213), `dump_ir_with_analyses` (212),
`resolve_name_in_analysis` (209), and `choose_registry_version` (207).
`binding_at` (385) stays excluded.

## Session 128 — ordering, hover, type equality, and AST dump splits

Decomposed the next four long functions:

1. **`order_module_functions`** (`lowering/monomorphized.mt`) 240 -> 169 via
   `validate_spec_creation_graph` (the creation-graph fixpoint).
2. **`named_argument_label_hover`** (`lsp/navigation.mt`) 227 -> 167 via
   `find_aggregate_head` (+ `AggregateHead`) and `find_variant_arm_name`.
3. **`type_equals`** (`semantic/types.mt`) 223 -> 164 via
   `imported_type_matches` and `generic_type_matches`.
4. **`decl_value`** (`sexpr.mt`) 224 -> 182 via `decl_value_const`,
   `decl_value_function`, `decl_value_struct`, and `decl_value_fallback`.

Structural: **168 files / 156,177 lines / 124,093 code**; 111 edges; 0
layering/naming/alias/vocabulary violations; 35 unused + 6 test-only exports;
**6,379 duplicated lines / 901 windows**; **14 functions >= 200 lines** (from
18); 11 files >= 2,000; 0 markers; tests 21/61.

Verification: dev suite 21/0; full CLI **224/224**; `sexpr parse`
**772 / 0 / 4 of 776**; `sexpr lower` **715 / 3 / 53 / 5 of 776** (the same
eight artifacts); `check` diagnostics **501 / 0 / 0 / 3 of 504**; examples
**49/49 same**; LSP **30/30 + the documented `typeDefinition/imported`**;
guard `--check --strict --ratchet`; bootstrap fixed point; `test/mt` 61/0;
refactor gate 6/6.

Next: `std_registry_lookup` (238), `emit_decl` (221), `generate_internal`
(221), `emit_format_string_helpers` (219), `load_context` (218),
`bindgen_command` (216), `build_manifest` (213), `dump_ir_with_analyses` (212),
`resolve_name_in_analysis` (209), `choose_registry_version` (207),
`expr_value` (204), `stmts_structural_equal` (204), `dispatch_method` (202).
`binding_at` (385) stays excluded.

## Session 127 — lowering, manifest, linter, and semantic-token splits

Decomposed the next six long functions:

1. **`lower_async_fn`** (`lowering/async_cps.mt`) 260 -> 141 via
   `build_async_resume_body` (140).
2. **`lower`** (`lowering/lowering.mt`) 259 -> 162 via
   `append_synthetic_decls` and `collect_type_aliases`.
3. **`parse_package_manifest`** (`loader/package_manifest.mt`) 252 -> 193 via
   `finish_package_build` (output/assets/template construction).
4. **`lower_specialization_call`** (`lowering/lowering.mt`) 245 -> 142 via
   `lower_array_literal_call` and `lower_builtin_hook_call`.
5. **`exprs_structural_equal`** (`linter/linter.mt`) 247 -> 185 via
   `format_parts_equal`, `call_exprs_equal`, `match_exprs_equal`, and
   `proc_exprs_equal`.
6. **`classify_scan_identifier`** (`lsp/semantic_tokens.mt`) 245 -> 107 via
   `classify_declaration_name`, `classify_dot_member`, `classify_call_site`,
   and `classify_name_reference`.

Structural: **168 files / 156,088 lines / 124,036 code**; 111 edges; 0
layering/naming/alias/vocabulary violations; 35 unused + 6 test-only exports;
**6,379 duplicated lines / 901 windows**; **18 functions >= 200 lines** (from
24); 11 files >= 2,000; 0 markers; tests 21/61.

Verification: dev suite 21/0; full CLI **224/224**; `sexpr parse`
**772 / 0 / 4 of 776**; `sexpr lower` 715 match + 53 host-rejected with the
same eight artifacts (1 real differ, `memory_stress_test`; 7 `main*.mt` guard
artifacts whose differ/self-fail split varies with timing); `check`
diagnostics **501 / 0 / 0 / 3 of 504**; examples **49/49 same**; focused lint
**501 / 3 of 504**; LSP **30/30 capabilities + the documented
`typeDefinition/imported` entry**; guard `--check --strict --ratchet`;
bootstrap fixed point (`stage2.c == stage3.c`; stage2 self-test 21/0);
`test/mt` 61/0; refactor gate 6/6.

Next: `order_module_functions` (240), `std_registry_lookup` (238),
`named_argument_label_hover` (227), `decl_value` (224), `type_equals` (223),
`emit_decl` / `generate_internal` (221).  `binding_at` (385) stays excluded.

## Session 126 — build, dispatch, C preamble, check, parser, and test splits

Decomposed the next six long functions (all now below 200):

1. **`build`** (`build.mt`) 327 -> 180 via `prepare_build_toolchain`,
   `generate_build_c_source`, `write_temp_c_source`, `prepare_wasm_shell`, and
   `push_compile_arguments`.
2. **`dispatch_cli`** (`main.mt`) 301 -> 58 via `extract_global_options`,
   `extract_include_paths` (returning `IncludeExtraction`), and
   `dispatch_command` (157) carrying the command table.
3. **`generate_c`** (`c_backend`) 277 -> 180 via `emit_preamble` (88) and
   `emit_runtime_helpers` (15); span-type collection stays in the driver.
4. **`check_command`** (`main.mt`) 264 -> 75 via `check_one_file`
   (`CheckFileResult` counts); directory expansion reuses
   `collect_lint_source_files`, and the dead `file_count` local is gone.
5. **`parse_primary`** (`parser/specialization.mt`) 263 -> 134 via
   `parse_string_primary`, `keyword_identifier_matches`/
   `parse_keyword_identifier`, and `parse_paren_primary`.
6. **`test_command`** (`main/test_cli.mt`) 253 -> 72 via
   `parse_test_limit_flags` and `parse_test_build_flags` plus the two flag
   structs.

Structural: **168 files / 155,893 lines / 123,892 code**; 111 edges; 0
layering/naming/alias/vocabulary violations; 35 unused + 6 test-only exports;
**6,379 duplicated lines / 901 windows**; **24 functions >= 200 lines** (from
30); 11 files >= 2,000; 0 markers; tests 21/61.

Verification: dev suite 21/0; full CLI **224/224**; `sexpr parse`
**772 / 0 / 4 of 776**; `check` diagnostics **501 / 0 / 0 / 3 of 504**;
examples **49/49 same**; guard `--check --strict --ratchet`; bootstrap fixed
point (`stage2.c == stage3.c`; stage2 self-test 21/0); `test/mt` 61/0.

Next: `lower_async_fn` (260), `lower` (259), `parse_package_manifest` (252),
`exprs_structural_equal` (247), `lower_specialization_call` (245),
`classify_scan_identifier` (245), and `order_module_functions` (240).

## Session 125 — command and parser-section decomposition

Completed the session-124 target list.

1. **`build`/`run` share one flag parser** (`main/build_cli.mt`).  `BuildOptions`
   and `parse_command_options` replace the two near-identical loops; the mode
   gates `--clean`/`--kind` and the `--` program-argument split, and the
   diagnostics are unchanged.  `build_command` drops 526 -> 197 and
   `run_command` 401 -> 161, split into `resolve_build_output` (effective source
   plus bundle/clean destinations), `run_build_clean`,
   `compute_build_cache_key`, `try_cached_build`, `resolve_run_output`, and
   `try_cached_run`.  The two parsers differed only in those two build-only
   options and the program-argument split; every option literal is distinct, so
   the unified check order is behaviorally equivalent.
2. **`lint_command` decomposition** (`main.mt`).  `LintFlags` +
   `parse_lint_options`, `collect_lint_source_files`, and `lint_one_file`
   (read/fix/analysis/timings/report) replace the 366-line body; the command
   shell is 117 lines and the per-file scan is one helper.
3. **`print_command_help` family split** (`cli_help.mt`, generator
   `tools/gen_cli_help.rb`).  The generator now emits five family helpers
   (`print_cli/project/source/tooling/server_command_help`) and a 12-line
   dispatcher; the help strings stay inline in declaration order (no constant
   tables).  The generator validates that the family list covers `COMMANDS`
   exactly, and `--check` remains byte-identical.
4. **Parser call-args section** (`parser/call_args.mt`).  `parse_call_args`
   moved out of parser.mt; parser.mt and expressions.mt import it (same-rank
   parser cycle).  It calls the `pstate` helpers directly and the public
   `parser.check_name`/`check_next`/`keyword_token_check` through the alias.
   parser.mt is 1,290 lines (from 1,326).
5. **Guard measurement fix** (`lib/milk_tea/tooling/refactor_guard.rb`).  The
   function-end scan stopped at a multi-line signature's closing `)`, excluding
   those bodies from the size and duplication metrics.  It now advances to the
   signature's `:`.  This surfaced `build` (327) and
   `classify_scan_identifier` (245) and corrected the duplication baseline to
   6,351 lines / 898 windows.  Guard tests are 15/15 (one new fixture); the
   baseline refresh is a measurement correction, not growth.

Structural: **168 files / 155,727 lines / 123,783 code**; 111 edges; 0
layering/naming/alias/vocabulary violations; 35 unused + 6 test-only exports;
**6,351 duplicated lines / 898 windows** (corrected; the old scan skipped
multi-line function bodies); **30 functions >= 200 lines** (24 before the
correction); 11 files >= 2,000; 0 markers; tests 21/61.

Verification: dev suite 21/0; full CLI **224/224**; `sexpr parse`
**772 match / 0 differ / 4 host-rejected of 776**; `sexpr lower`
**715 / 3 / 53 / 5 of 776** — the same eight artifacts (`main.mt`,
`build_cli.mt`, and `memory_stress_test` differ; the other five `main/*.mt`
self-fail on the guard); examples **49/49 same**; focused lint parity
**501 / 3 of 504** (the documented residue); guard
`--check --strict --ratchet`; bootstrap fixed point holds
(`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: the remaining long functions, led by `dispatch_cli` (301), `generate_c`
(277), and `check_command` (264); `binding_at` (385) stays excluded because its
attempted split raised duplication.

## Session 124 — identifier member resolution

Extracted the bare-identifier arm of `lower_member_access` into
`lower_identifier_member` (152 lines): variant constructors, synthetic type
constants, static members, import aliases, and module-qualified
specialization constructors.  The helper returns `Option[ptr[ir.Expr]]`; the
caller returns the value or falls through to the SoA/index and struct-field
paths.

- `lower_member_access` drops from 331 to 190 lines; `lowering.mt` is 18,433
  lines / 13,577 code (from 18,421 / 13,570); its max function drops from 331
  to 259.
- Long functions drop from **29 to 28**; duplication stays at 5,154.
- Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; **examples 49/49
  same** (C output byte-identical); lower parity **714/2/53/6 of 775** (same
  eight artifacts); refactor gate 6/6; bootstrap fixed point holds (`stage2.c
  == stage3.c`; stage2 self-test 21/0).
- Structural baseline refreshed: 167 files / 123,746 code lines; 167 alias
  modules; 111 edges; 5,154 duplicated lines; 28 functions >= 200 lines; 11
  files >= 2,000 code lines.

Next: `build_command` 529, `lint_command` 368, or `print_command_help` 344
(avoid constant-table splits), plus the parser call-args section.

## Session 123 — lower_module declaration arms

Extracted five declaration-lowering arms from `lower_module` into per-kind
helpers: `lower_module_function_decl` (29 lines), `lower_module_struct_decl`
(19), `lower_module_var_decl` (53), `lower_module_const_decl` (102), and
`lower_module_event_decl` (22).  Each helper re-matches the declaration and
takes its output vector by reference; the module's `ctx` is already a ref, so
the helpers pass it directly.

- `lower_module` drops from 381 to 193 lines; `monomorphized.mt` is 1,382
  lines / 1,102 code (from 1,342 / 1,072); its max function drops from 376 to
  240.
- Long functions drop from **30 to 29**; duplication stays at 5,154.
- Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; **examples 49/49
  same** (C output byte-identical); lower parity **714/2/53/6 of 775** (same
  eight artifacts); refactor gate 6/6; bootstrap fixed point holds (`stage2.c
  == stage3.c`; stage2 self-test 21/0).
- Structural baseline refreshed: 167 files / 123,739 code lines; 167 alias
  modules; 111 edges; 5,154 duplicated lines; 29 functions >= 200 lines; 11
  files >= 2,000 code lines.

Next: `build_command` 529, `lint_command` 368, or `print_command_help` 344
(avoid constant-table splits), plus the parser call-args section.

## Session 122 — parallel worker extraction

First parallel lowering decomposition: the 160-line per-body worker
construction loop moved out of `lower_parallel_block` into
`build_parallel_workers`.  The helper takes `ctx`, `bodies`, `infos`,
`uid_base`, `void_ty`, `void_ptr` and preserves the capture analysis, the
synthetic worker functions, and the `SpawnBlockInfo` population.

- `lower_parallel_block` drops from 271 to 115 lines; the helper is 160.
  `parallel.mt` is 1,031 lines / 923 code (from 1,027 / 921); its max function
  drops from 269 to 181.
- Long functions drop from **31 to 30**; duplication stays at 5,154.
- A first attempt split `toolchain_bindings.binding_at` (a 385-line constant
  table) into range helpers; it raised duplication from 5,154 to 5,498, so it
  was reverted.  Constant tables are a poor split target under the windowed
  duplication metric.
- Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; **examples 49/49
  same** (C output byte-identical); refactor gate 6/6; bootstrap fixed point
  holds (`stage2.c == stage3.c`; stage2 self-test 21/0).
- Structural baseline refreshed: 167 files / 123,709 code lines; 167 alias
  modules; 111 edges; 5,154 duplicated lines; 30 functions >= 200 lines; 11
  files >= 2,000 code lines.

Next: `build_command` 529, `lower_module` 381, `lint_command` 368, or
`print_command_help` 344 (avoid constant-table splits), plus the parser
call-args section.

## Session 121 — lower_expr decomposition

Seventh lowering decomposition: `lower_expr` (459 lines) became a 146-line
dispatcher plus three per-kind helpers — `lower_identifier_expr` (64),
`lower_binary_expr` (197), and `lower_specialization_expr` (67).  The helpers
take the arm fields as parameters; the specialization helper carries its own
`unsafe:` wrapper for the callee pointer read.

- `lowering.mt` is 18,421 lines / 13,570 code (from 18,410 / 13,565); its
  largest function drops from **459 to 331 lines**.
- Long functions drop from **32 to 31**.
- Removed the now-unused `std.stdio` and `mtc.semantic.expressions` imports.
- Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; **examples 49/49
  same** (C output byte-identical); lower parity **714/8/53/0 of 775**
  (unchanged); refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
  stage3.c`; stage2 self-test 21/0).
- Structural baseline refreshed: 167 files / 123,707 code lines; 167 alias
  modules; 111 edges; 5,154 duplicated lines; 31 functions >= 200 lines; 11
  files >= 2,000 code lines.

Next: `build_command` 526 or `toolchain_bindings` 385, the parser call-args
section, and the remaining long functions.

## Session 120 — parser expression-forms module

Sixth parser split: move the expression forms out of `parser/parser.mt` into
`parser/expression_forms.mt` — if/match/proc/unsafe expressions, the `is`
desugaring, and the `T<-expr` prefix cast (9 functions / 210 code lines).

- `expression_forms.mt` is 257 lines / 210 code (max function 44); `parser.mt`
  is 1,324 lines / 1,051 code (from 1,574 / 1,252).
- `parse_if_expr`, `parse_match_expr`, `parse_match_expr_arm_into`,
  `parse_proc_expr_after_proc`, `parse_unsafe_expr`, `is_desugar` and
  `try_parse_prefix_cast_expr` are public; all helpers the block calls were
  already public (`known_type_like_name`, `check_next`, `block_expr`,
  `alloc_expr`, `alloc_stmt`).  `expressions.mt`, `specialization.mt` and
  `statements.mt` now call `expression_forms.*`.  The parser area keeps its
  same-rank cycle (111 edges, 0 violations); the alias table adds
  `parser.expression_forms` (167 modules).
- The moved bodies are identical after the prefix/visibility normalization
  (242 lines before the new header).
- Parse parity: **772 match / 0 differ / 4 host-rejected of 776**.
- Lower parity: **714 match / 8 differ / 53 host-rejected / 0 self-failed of
  775**; the new module matches and the same eight documented artifacts remain.
- Structural baseline refreshed: 167 files / 123,702 code lines; 167 alias
  modules; 111 edges; 5,154 duplicated lines; 32 functions >= 200 lines; 11
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; parse parity
772/0/4 of 776; lower parity 714/8/53/0 of 775; refactor gate 6/6; bootstrap
fixed point holds (`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: call arguments (the last parser section), then the remaining long
functions.

## Session 119 — parser specialization module

Fifth parser split: move the specialization-target disambiguation out of
`parser/parser.mt` into `parser/specialization.mt` — the identifier/target
checks, definite/explicit type-argument analysis, named-argument detection,
`specialization_value_target`/`specialization_call_target`, and `parse_primary`
(14 functions / 382 code lines).

- `specialization.mt` is 421 lines / 382 code (max function 263, the moved
  `parse_primary`); `parser.mt` is 1,574 lines / 1,252 code (from 1,987 /
  1,625).
- `specialization_value_target`, `specialization_call_target` and
  `parse_primary` stay public; parser exposes the seven helpers the block
  calls (`known_type_like_name`, `keyword_token_check`, `parse_float_literal`,
  `parse_char_value`, `parse_format_string_expr`, `skip_attribute_content`,
  `parse_proc_expr_after_proc`).  `expressions.mt` now calls
  `specialization.parse_primary` and the two target predicates.  The parser
  area keeps its same-rank cycle (111 edges, 0 violations); the alias table
  adds `parser.specialization` (166 modules).
- The moved bodies are identical after the prefix/visibility normalization
  (405 lines before the new header).
- Parse parity: **770 match / 0 differ / 4 host-rejected of 774** (clean on the
  settled rerun; the first showed a transient cache-miss diff).
- Lower parity: **713 match / 4 differ / 53 host-rejected / 4 self-failed of
  774**; the new module matches and the same eight documented artifacts remain
  (this run split the guard aborts between differ and self-fail).
- Structural baseline refreshed: 166 files / 123,690 code lines; 166 alias
  modules; 111 edges; 5,154 duplicated lines; 32 functions >= 200 lines; 11
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; parse parity
770/0/4 of 774; lower parity 713/4/53/4 of 774; refactor gate 6/6; bootstrap
fixed point holds (`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: the expression-form sections (if/match/proc/unsafe/is/prefix-cast) and
call arguments, then the remaining long functions.

## Session 118 — lower_async_fn decomposition

First async CPS decomposition: `lower_async_fn` (590 lines) became a 262-line
orchestrator plus three phase helpers — `emit_async_vtable` (ready,
set_waiter, release and take_result, ~139 lines), `emit_async_cancel_fn`
(~95), and `emit_async_constructor` (~101).  The helpers take the shared
frame/param state; the vtable and cancel helpers recreate their bool/void,
`bool_true`, `wake_fn_ty` and linkage-name locals, and the constructor
recreates `frame_ty`/`resume_c`/`task_ty` and the five vtable names.

- `async_cps.mt` is 1,782 lines / 1,335 code (from 1,751 / 1,310); its largest
  function drops from **587 to 260 lines**.
- The first extraction pushed the long-function count from 32 to 33 because
  the vtable helper was still 229 lines; extracting the cancel builder brought
  it back to **32**.
- Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; **examples 49/49
  same** (C output byte-identical); refactor gate 6/6; bootstrap fixed point
  holds (`stage2.c == stage3.c`; stage2 self-test 21/0).
- Structural baseline refreshed: 165 files / 123,680 code lines; 165 alias
  modules; 111 edges; 5,154 duplicated lines; 32 functions >= 200 lines; 11
  files >= 2,000 code lines.

Next: the remaining parser sections (specialization/expression forms/call
arguments) and the remaining long functions.

## Session 117 — generate_c decomposition

First c_backend decomposition: `generate_c` (537 lines) became a 277-line
orchestrator plus two phase helpers — `emit_program_types` (the struct, union,
tuple, variant, enum, task, type-alias, span and SoA type block, 150 lines) and
`emit_program_bodies` (forward declarations, checked accessors, string
literals, equality/slice helpers, constants, globals, static asserts,
str_buffer/argv helpers, and function bodies, 112 lines).

- `c_backend.mt` is 8,042 lines / 6,128 code (from 8,031 / 6,121); its largest
  function drops from **537 to 277 lines**.
- `emit_program_types` takes `e`/`program`/`span_types`/`tuple_types`/
  `gen_variants`/`opt_structs`/`funcs`, keeps mutable locals for the two
  `ref_of` calls, and both helpers declare their own loop index `i` (the
  orchestrator's `i` is no longer borrowed).
- The now-unused `std.libc` import was removed.
- Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; **examples 49/49
  same** (C output byte-identical); refactor gate 6/6; bootstrap fixed point
  holds (`stage2.c == stage3.c`; stage2 self-test 21/0).
- Structural baseline refreshed: 165 files / 123,655 code lines; 165 alias
  modules; 111 edges; 5,154 duplicated lines; 32 functions >= 200 lines; 11
  files >= 2,000 code lines.

Next: `lower_async_fn` 587 lines, then the remaining parser sections
(specialization/expression forms/call arguments).

## Session 116 — parser declaration-forms module

Fourth parser split: move the declaration forms out of `parser/parser.mt`
into `parser/decl_forms.mt` — structs, enums, variants, interfaces, opaque
types, extending blocks, methods, extern/foreign declarations, events, `when`
declarations, attributes, and signatures (31 functions / 781 code lines).

- `decl_forms.mt` is 875 lines / 781 code (max function 79); `parser.mt` is
  1,987 lines / 1,625 code (from 2,846 / 2,395) and is no longer a 2,000-line
  file; the project total of files >= 2,000 code lines drops from 12 to 11.
- `parse_struct_decl`, `drain_pending_decls`, `parse_struct_member`,
  `parse_qualified_name_with_type_args`, `parse_type_alias`, `parse_enum_decl`,
  `parse_variant_decl`, `parse_interface_decl`, `parse_opaque_decl`,
  `parse_extending_block`, `parse_extern_decl`, `parse_foreign_decl`,
  `parse_static_assert`, `parse_event_decl`, `parse_when_decl` and
  `parse_attribute_decl` are public; parser exposes the five helpers the block
  calls (`recover_top_level`, `check_next`, `parse_int_literal`,
  `parse_attribute_applications`, `parse_decl`).  `declarations.mt` now calls
  `decl_forms.parse_qualified_name_with_type_args`.  The parser area keeps its
  same-rank cycle (111 edges, 0 violations); the alias table adds
  `parser.decl_forms` (165 modules).
- The moved bodies are identical after the prefix/visibility normalization
  (858 lines before the new header).
- Parse parity: **769 match / 0 differ / 4 host-rejected of 773** (clean on the
  settled rerun; the first showed a transient cache-miss diff).
- Lower parity: **712 match / 8 differ / 53 host-rejected / 0 self-failed of
  773**; the new module matches and the same eight documented artifacts remain
  (this run classified the six `main/*.mt` guard aborts as differ again).
- Structural baseline refreshed: 165 files / 123,648 code lines; 165 alias
  modules; 111 edges; 5,154 duplicated lines; 32 functions >= 200 lines; 11
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; parse parity
769/0/4 of 773; lower parity 712/8/53/0 of 773; refactor gate 6/6; bootstrap
fixed point holds (`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: `generate_c` and `lower_async_fn` (the two largest functions), then the
remaining parser sections (specialization/expression forms/call arguments).

## Session 115 — parser declarations module

Third parser split: move the declaration layer out of `parser/parser.mt` into
`parser/declarations.mt` — const/var/function declarations, parameter lists,
type references, and block bodies (17 functions / 509 code lines).

- `declarations.mt` is 566 lines / 509 code (max function 72); `parser.mt` is
  2,846 lines / 2,395 code (from 3,401 / 2,893).
- `parse_const_decl`, `parse_var_decl`, `parse_function_def`,
  `parse_optional_c_name`, `parse_declaration_type_params`, `parse_params`,
  `parse_type_ref`, `parse_named_type_ref`, `parse_type_argument`, `parse_block`
  and `parse_block_body` are public; parser exposes the six helpers the block
  calls (`recover_statement`, `check_next`, `parse_string_content`,
  `alloc_stmt`, `alloc_decl`, `parse_qualified_name_with_type_args`).
  `statements.mt` and `expressions.mt` now call `declarations.parse_type_ref` /
  `parse_block_body` / `parse_type_argument`.  The parser area keeps its
  same-rank cycle (111 edges, 0 violations); the alias table adds
  `parser.declarations` (164 modules).  The two `parse_source_file` locals named
  `declarations` were renamed `decls` to avoid the module alias.
- The moved bodies are identical after the prefix/visibility normalization
  (550 lines before the new header).
- Parse parity: **768 match / 0 differ / 4 host-rejected of 772** (the first
  run showed one transient cache-miss diff; the settled rerun is clean).
- Lower parity: **711 match / 2 differ / 53 host-rejected / 6 self-failed of
  772**; the new module matches and the same eight documented artifacts remain.
- Structural baseline refreshed: 164 files / 123,636 code lines; 164 alias
  modules; 111 edges; 5,154 duplicated lines; 32 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; parse parity
768/0/4 of 772; lower parity 711/2/53/6 of 772; refactor gate 6/6; bootstrap
fixed point holds (`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: the declaration tail (struct/enum/variant/interface/opaque/extending/
extern/foreign/event/when parsers), then `generate_c` / `lower_async_fn`.

## Session 114 — parser expressions module

Second parser split: move the expression layer out of `parser/parser.mt` into
`parser/expressions.mt` — the precedence-climbing expression parser and its
specialization-target disambiguation (20 functions / 317 code lines).

- `expressions.mt` is 369 lines / 317 code (max function 51); `parser.mt` is
  3,401 lines / 2,893 code (from 3,763 / 3,203).
- `parse_expr`, `parse_unary`, `specialization_target` and
  `parse_bitwise_xor` are public; parser exposes the 11 helpers the expressions
  call (`matching_rbracket_index`, `parse_type_argument`,
  `specialization_value_target`, `specialization_call_target`, `parse_primary`,
  `parse_if_expr`, `parse_match_expr`, `parse_unsafe_expr`, `is_desugar`,
  `try_parse_prefix_cast_expr`, `parse_call_args`).  `statements.mt` now calls
  `expressions.parse_expr` / `expressions.parse_bitwise_xor`.  The parser area
  keeps its same-rank cycle (111 edges, 0 violations); the alias table adds
  `parser.expressions` (163 modules).
- The moved bodies are identical after the prefix/visibility normalization
  (357 lines before the new header).
- Parse parity: **767 match / 0 differ / 4 host-rejected of 771** (the first
  run showed one transient cache-miss diff; the settled rerun is clean).
- Lower parity: **710 match / 2 differ / 53 host-rejected / 6 self-failed of
  771**.  The eight artifacts are unchanged: `memory_stress_test` and
  `main.mt` differ, and the six `main/*.mt` submodules hit the known 50M
  UTF-8 guard (standalone `std_cli` aborts at 31 s, rc 134); under the sweep's
  parallel load they are classified as self-fail rather than diff.  The new
  expressions module matches.
- Structural baseline refreshed: 163 files / 123,623 code lines; 163 alias
  modules; 111 edges; 5,170 duplicated lines; 32 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; parse parity
767/0/4 of 771; lower parity 710/2/53/6 of 771 (eight documented artifacts);
refactor gate 6/6; bootstrap fixed point holds (`stage2.c == stage3.c`;
stage2 self-test 21/0).

Next: parser declarations/call-args, then the `generate_c` / `lower_async_fn`
orchestration functions.

## Session 113 — analyzer check_module_opts decomposition

Sixth analyzer decomposition: `check_module_opts` (190 lines) dropped to 111
lines by moving its 82-line `Context` literal into a `create_context`
constructor (91 lines).  The constructor takes `module_name`,
`imported_modules`, and `require_resolved_imports`; the pipeline and the
`Analysis` assembly stay in the entry point.

- `analyzer.mt` is 9,683 lines / 7,204 code (from 9,679 / 7,202).
- The analyzer's largest function drops from **190 to 109 lines**; long
  functions stay at **32** (none crosses 200 now).
- Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; diagnostic parity
  **501 agree / 0 verdict / 0 position / 3 message of 504** (unchanged); parse
  parity 766/0/4 of 770; lower parity 709/8/53 of 770 (same eight documented
  artifacts); refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
  stage3.c`; stage2 self-test 21/0).

Next: parser expressions/declarations and the `generate_c` /
`lower_async_fn` orchestration functions.

## Session 112 — analyzer resolve_named decomposition

Fifth analyzer decomposition: `resolve_named` (116 lines) became a 50-line
lookup chain plus three phase helpers — `resolve_generic_type` (generic
constructors, including the explicit `ref` lifetime argument),
`resolve_registered_type` (registered builtin/module/local type names), and
`fold_qualified_const_type` (module-qualified constants in type-argument
position).  The qualified-constant helper returns `ty_error` when no fold
applies and the caller continues to the unresolved-name checks.

- `analyzer.mt` is 9,679 lines / 7,202 code (from 9,664 / 7,193); its largest
  function remains `check_module_opts` at 190 lines.
- Long functions stay at **32**; all other metrics unchanged (162 alias
  modules, 111 edges, 5,170 duplicated lines).
- Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; diagnostic parity
  **501 agree / 0 verdict / 0 position / 3 message of 504** (unchanged); parse
  parity 766/0/4 of 770; lower parity 709/8/53 of 770 (same eight documented
  artifacts); refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
  stage3.c`; stage2 self-test 21/0).

Next: `check_module_opts` 190, then parser expressions/declarations and the
`generate_c` / `lower_async_fn` orchestration functions.

## Session 111 — analyzer infer_binary decomposition

Fourth analyzer decomposition: `infer_binary` (134 lines) became a 73-line
orchestrator plus three phase helpers — `infer_numeric_binary_type` (numeric
promotion and literal adaptation), `infer_simd_binary_type` (vector
arithmetic), and `harmonize_float_binary_operands` (float-literal
re-inference).  The SIMD helper returns `ty_error` for no match and the caller
continues; the numeric helper is called only under the original numeric guard.

- `analyzer.mt` is 9,664 lines / 7,193 code (from 9,649 / 7,184); its largest
  function remains `check_module_opts` at 190 lines.
- Long functions stay at **32**; all other metrics unchanged (162 alias
  modules, 111 edges, 5,170 duplicated lines).
- Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; diagnostic parity
  **501 agree / 0 verdict / 0 position / 3 message of 504** (unchanged); parse
  parity 766/0/4 of 770; lower parity 709/8/53 of 770 (same eight documented
  artifacts); refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
  stage3.c`; stage2 self-test 21/0).

Next: `check_module_opts` 190 and `resolve_named` 116, then parser
expressions/declarations and the `generate_c` / `lower_async_fn` orchestration
functions.

## Session 110 — analyzer check_stmt decomposition

Third analyzer decomposition: `check_stmt_inner` (160 lines) became a 62-line
match dispatcher plus five statement-form helpers — `check_return_stmt`,
`check_if_stmt`, `check_while_stmt`, `check_match_stmt`, and
`check_assignment_stmt`.  The if/match helpers carry their own `unsafe:`
wrapper for the arm loops' pointer reads; the while helper takes the nullable
body pointer directly.

- `analyzer.mt` is 9,649 lines / 7,184 code (from 9,627 / 7,172); its largest
  function remains `check_module_opts` at 190 lines.
- Long functions stay at **32**; all other metrics unchanged (162 alias
  modules, 111 edges, 5,170 duplicated lines).
- Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; diagnostic parity
  **501 agree / 0 verdict / 0 position / 3 message of 504** (unchanged); parse
  parity 766/0/4 of 770; lower parity 709/8/53 of 770 (same eight documented
  artifacts); refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
  stage3.c`; stage2 self-test 21/0).

Next: `check_module_opts` 190, `infer_binary` 136, `resolve_named` 116, then
parser expressions/declarations and the `generate_c` / `lower_async_fn`
orchestration functions.

## Session 109 — analyzer check_member decomposition

Second analyzer decomposition: `check_member` (174 lines) became a 50-line
match dispatcher plus four receiver-type helpers — `check_named_member`,
`check_imported_receiver_member`, `check_primitive_member`, and
`check_generic_member`.  The helpers take the receiver fields as parameters;
the existing `unsafe:` blocks moved with their bodies.

- `analyzer.mt` is 9,627 lines / 7,172 code (from 9,611 / 7,164); its largest
  function remains `check_module_opts` at 190 lines.
- Long functions stay at **32**; all other metrics unchanged (162 alias
  modules, 111 edges, 5,170 duplicated lines).
- Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; diagnostic parity
  **501 agree / 0 verdict / 0 position / 3 message of 504** (unchanged); parse
  parity 766/0/4 of 770; lower parity 709/8/53 of 770 (same eight documented
  artifacts); refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
  stage3.c`; stage2 self-test 21/0).

Next: `check_module_opts` 190, `check_stmt_inner` 160, `infer_binary` 136,
`resolve_named` 116, then parser expressions/declarations and the
`generate_c` / `lower_async_fn` orchestration functions.

## Session 108 — analyzer infer_expr decomposition

Analyzer module extraction is blocked: every cohesive section (binding ids,
structural collection, type resolution, interface conformance, expression
inference) takes the private `Context`, so moving one would expose the
analyzer's internal state wholesale.  The analyzer track therefore starts with
an in-file decomposition of its largest dispatcher.

- `infer_expr_inner` (243 lines) became an 81-line dispatcher plus nine
  per-kind helpers: integer literal, index access, unsafe, await, null literal,
  proc, if, match, and detach.  The helper bodies are the original arm
  statements with the arm fields rebound to parameters; helpers whose pointer
  reads moved out of the dispatcher's outer `unsafe:` block carry their own
  `unsafe:` wrapper.
- `analyzer.mt` is 9,611 lines / 7,164 code (from 9,580 / 7,143); its largest
  function is now `check_module_opts` at 190 lines (was `infer_expr_inner` at
  243).
- Long functions drop from **33 to 32**; all other metrics are unchanged
  (162 alias modules, 111 edges, 5,170 duplicated lines).
- Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; diagnostic parity
  **501 agree / 0 verdict / 0 position / 3 message of 504** (unchanged); parse
  parity 766/0/4 of 770; lower parity 709/8/53 of 770 (same eight documented
  artifacts); refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
  stage3.c`; stage2 self-test 21/0).

Next: continue the analyzer's long functions (`check_module_opts` 190,
`check_member` 174, `check_stmt_inner` 160, `infer_binary` 136, `resolve_named`
116), then parser expressions/declarations and the `generate_c` /
`lower_async_fn` orchestration functions.

## Session 107 — parser statements module

First parser split: move the statement layer out of `parser/parser.mt` into
`parser/statements.mt` — the statement dispatcher and every statement form
(locals, control flow, match, defer, unsafe, parallel/gather, emit, and the
inline forms), 28 functions / 829 code lines.

- `statements.mt` is 905 lines / 829 code (max function 105);
  `parser.mt` is 3,763 lines / 3,203 code (from 4,657 / 4,024).
- `parse_statement`, `parse_pattern`, `is_wildcard_match` and
  `parse_match_arm_into` are public; parser exposes the 14 core helpers the
  statements call (`consume_or_sync`, `panic_error_expr`, `recover_statement`,
  `recover_match_arm`, `check_next`, `block_expr`, `alloc_expr`, `alloc_stmt`,
  `parse_decl`, `parse_type_ref`, `parse_block_body`, `parse_expr`,
  `parse_bitwise_xor`, `parse_match_expr_arm_into`) plus the nine parser-local
  token wrappers.  Token access in the new module is `pstate.*` for the ten
  state helpers and `parser.*` for the nine parser-local wrappers.  The parser
  area gains a same-rank cycle (111 edges, 0 violations); the alias table adds
  `parser.statements` (162 modules).
- The moved bodies are identical after the prefix/visibility normalization
  (891 lines before the new header).
- Duplication drops from 789 / 5,228 to **771 / 5,170**; the window clustering
  changed with the module boundary.
- Parse parity: **766 match / 0 differ / 4 host-rejected of 770** (clean).
- Lower parity: **709 match / 8 differ / 53 host-rejected / 0 self-rejected of
  770**.  The 8 are the documented `memory_stress_test` lifetime-name artifact,
  `main.mt`, and its six `main/*.mt` submodules — all six abort in the known
  50M-iteration UTF-8 guard under both the host-built stage1 and stage2
  (`std_cli` and `bindings_cli` re-checked explicitly), so they are not
  regressions.  The sweep now covers the post-session-91 modules for the first
  time; the honest count replaces the old 699 / 2 / 53 of 754.
- Structural baseline refreshed: 162 files / 123,554 code lines; 162 alias
  modules; 111 edges; 5,170 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; parse parity
766/0/4 of 770; lower parity 709/8/53 of 770 (8 documented); refactor gate 6/6;
bootstrap fixed point holds (`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: the analyzer, then parser expressions/declarations; the largest functions
remain `lower_async_fn` 587, `generate_c` 537, `build_command` 526,
`lower_expr` 459 and `run_command` 401.

## Session 106 — bindgen nullable-report module

Fifth bindgen split: move the nullable-policy report out of `bindgen.mt` into
`bindgen/nullable_report.mt` — the parameter/return override comparison and
release helpers, `build_nullable_report`, and its JSON text writer (9 functions
+ 2 report structs / 210 code lines).

- `nullable_report.mt` is 243 lines / 210 code (max function 25); `bindgen.mt`
  is 3,187 lines / 2,713 code (from 3,424 / 2,917).
- `build_nullable_report` is public for the generation pipeline;
  `uint_to_str`, `map_type`, `CDecl` and `BindgenOptions` are referenced through
  the `bindgen` alias, and the policy lookups through `nullable_policy`.  The
  bindgen area keeps its same-rank edge (111 edges, 0 violations); the alias
  table adds `bindgen.nullable_report` (161 modules).
- The moved bodies are verbatim (232 lines before the new header); the new
  module imports `std.str` for `str.compare`.
- Bindgen parity: **33 match / 0 differ / 0 error / 1 custom of 34**.
- Structural baseline refreshed: 161 files / 123,546 code lines; 161 alias
  modules; 111 edges; 5,228 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; bindgen parity
33/34 (1 custom); refactor gate 6/6; bootstrap fixed point holds
(`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: parser and analyzer; the largest functions remain `lower_async_fn` 587,
`generate_c` 537, `build_command` 526, `lower_expr` 459 and `run_command` 401.
`bindgen.mt` is now 3,187 lines, down from 4,772 at the start of the bindgen
splits.

## Session 105 — bindgen options-JSON module

Fourth bindgen split: move the `--options-json` loader out of `bindgen.mt`
into `bindgen/options_json.mt` — the raw-binding metadata table loader, its
release, and the typed JSON field helpers (9 functions / 165 code lines).

- `options_json.mt` is 194 lines / 165 code (max function 50); `bindgen.mt` is
  3,424 lines / 2,917 code (from 3,609 / 3,075).
- `load_options_json` and `release_options_json` stay public; `jget_bool` is
  public for the two declaration-selection call sites.  `ModuleImport` and
  `BindgenOptions` stay in bindgen and are referenced through the `bindgen`
  alias.  The bindgen area keeps its same-rank edge (111 edges, 0 violations);
  the alias table adds `bindgen.options_json` (160 modules).
- `main/bindings_cli.mt` now calls `options_json.load_options_json` /
  `options_json.release_options_json`; its local `options_json` flag was renamed
  `options_json_path` to avoid the module alias.
- `bindgen.mt` drops its now-unused `std.mem.heap` import.
- The moved bodies are verbatim (180 lines before the new header).
- Bindgen parity: **33 match / 0 differ / 0 error / 1 custom of 34**.
- Structural baseline refreshed: 160 files / 123,540 code lines; 160 alias
  modules; 111 edges; 5,228 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; bindgen parity
33/34 (1 custom); refactor gate 6/6; bootstrap fixed point holds
(`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: the nullable-policy report section still in bindgen, then parser and
analyzer; the largest functions remain `lower_async_fn` 587, `generate_c` 537,
`build_command` 526, `lower_expr` 459 and `run_command` 401.

## Session 104 — bindgen macro-probe module

Third bindgen split: move the macro constant probes out of `bindgen.mt` into
`bindgen/macro_probes.mt` — `#define` discovery, macro-body normalisation,
constant lowering, initializer-list lowering, and the synthetic probe
declarations (17 functions + `MACRO_PROBE_PREFIX` + `ArrayTypeInfo` / 483 code
lines).

- `macro_probes.mt` is 539 lines / 489 code (max function 52); `bindgen.mt` is
  3,609 lines / 3,075 code (from 4,137 / 3,557).
- `MACRO_PROBE_PREFIX`, `first_inner_child`, `macro_candidates` and
  `lower_constant` are public; bindgen exposes the ten helpers the probes call
  (`str_has_prefix`, `uint_to_str`, `absolute_path`, `tracked_macro_file`,
  `allowed_declaration_name`, `find_aggregate_node`, `uppercase_macro_name`,
  `find_macro_index`, `release_macro_names`, `is_ident_byte`) plus
  `BindgenOptions`.  The probe's map-failure writes go through
  `set_bindgen_map_failed` / `bindgen_map_failed_flag`.  The bindgen area keeps
  its same-rank edge (111 edges, 0 violations); the alias table adds
  `bindgen.macro_probes` (159 modules).
- The moved bodies are identical after the binding prefixes and the map-failure
  accessor rewrite (526 lines before the new header).
- Bindgen parity: **33 match / 0 differ / 0 error / 1 custom of 34**.
- Structural baseline refreshed: 159 files / 123,532 code lines; 159 alias
  modules; 111 edges; 5,228 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; bindgen parity
33/34 (1 custom); refactor gate 6/6; bootstrap fixed point holds
(`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: bindgen's options-JSON section, then parser and analyzer; the largest
functions remain `lower_async_fn` 587, `generate_c` 537, `build_command` 526,
`lower_expr` 459 and `run_command` 401.

## Session 103 — bindgen emitter module

Second bindgen split: move the source emitter out of `bindgen.mt` into
`bindgen/emitter.mt` — aggregate field/declaration emission, synthetic
declarations, declaration ordering, and the module source writer (8 functions /
300 code lines).

- `emitter.mt` is 337 lines / 306 code (max function 100); `bindgen.mt` is
  4,137 lines / 3,557 code (from 4,457 / 3,851).
- `emit_module`, `GenState`, and three state accessors are public;
  bindgen exposes the ten helpers the emitter calls (`jget_str`, `jget_inner`,
  `map_type`, `emitted_name`, `record_c_name`, `field_unnamed`, `node_non_null`,
  `anonymous_record_decl_for_field`, `aggregate_field_name`,
  `aggregate_field_type`) plus `SyntheticDecl`.  `bindgen_state` and
  `bindgen_map_failed` stay private behind `bindgen_state_ptr`,
  `bindgen_map_failed_flag` and `set_bindgen_map_failed`.  The bindgen area
  keeps its same-rank edge (111 edges, 0 violations); the alias table adds
  `bindgen.emitter` (158 modules).
- `bindgen.mt` drops its now-unused `std.path` import.
- The moved bodies are verbatim (325 lines before the new header); only the
  three global reads were rewritten to the accessors.
- Bindgen parity: **33 match / 0 differ / 0 error / 1 custom of 34**.
- Structural baseline refreshed: 158 files / 123,525 code lines; 158 alias
  modules; 111 edges; 5,228 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; bindgen parity
33/34 (1 custom); refactor gate 6/6; bootstrap fixed point holds
(`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: bindgen's macro-probe and options-JSON sections, then parser and
analyzer; the largest functions remain `lower_async_fn` 587, `generate_c` 537,
`build_command` 526, `lower_expr` 459 and `run_command` 401.

## Session 102 — nullable-policy bindgen module

First bindgen split: move the nullable-policy overrides out of `bindgen.mt` into
`bindgen/nullable_policy.mt` — clang signature/parameter parsing, override
lookup, target validation, policy-file loading, and the `NullablePolicy` type
(10 functions + 2 structs / 265 code lines).

- `nullable_policy.mt` is 325 lines / 272 code (max function 116);
  `bindgen.mt` is 4,457 lines / 3,851 code (from 4,772 / 4,116).
- `FunctionSigText`, `NullablePolicy`, and the ten functions are public;
  bindgen exposes `CDecl` and `str_strip` for the moved code.  The bindgen area
  gains a same-rank `bindgen -> bindgen` edge (111 edges total, 0 violations);
  the alias table adds `bindgen.nullable_policy` (157 modules).
- `main/bindings_cli.mt` now calls `nullable_policy.NullablePolicy` /
  `nullable_policy.load_nullable_policy`; its local `nullable_policy` flag was
  renamed `nullable_policy_path` to avoid the module alias.
- The moved bodies are verbatim (312 lines before the new header).
- Bindgen parity: **33 match / 0 differ / 0 error / 1 custom of 34** (the
  custom entry is the host's `tracy` generator).
- Structural baseline refreshed: 157 files / 123,513 code lines; 157 alias
  modules; 111 edges; 5,228 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; bindgen parity
33/34 (1 custom); refactor gate 6/6; bootstrap fixed point holds
(`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: the remaining bindgen sections (emitter, macro probes, options JSON),
parser, analyzer; the largest functions remain `lower_async_fn` 587,
`generate_c` 537, `build_command` 526, `lower_expr` 459 and `run_command` 401.

## Session 101 — redundant-else linter rule module

Third linter-rule split: move the `redundant-else` rule out of
`linter/linter.mt` into `linter/rules_redundant_else.mt` — terminating
expressions, cannot-return/break analysis, true/false literal checks, branch
return analysis, and the else-block warning (15 functions / 229 code lines).

- `rules_redundant_else.mt` is 273 lines / 233 code (max function 46);
  `linter.mt` is 6,935 lines / 5,567 code (from 7,204 / 5,796).
- `check_redundant_else`, `always_returns_body`, `block_is_nonempty` and
  `statement_line` are public; linter exposes `push_warning` for the moved
  rule (`expression_line` already was).  The linter area keeps its same-rank
  cycle (110 edges, 0 violations); the alias table adds
  `linter.rules_redundant_else` (156 modules).
- The moved bodies are verbatim (264 lines before the new header).
- The dev linter tests cover the redundant-else cases; the focused
  `std`+`examples` parity is **501 agree / 3 differ of 504** (the documented
  residue).
- Structural baseline refreshed: 156 files / 123,505 code lines; 156 alias
  modules; 110 edges; 5,228 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; refactor gate 6/6;
bootstrap fixed point holds (`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: `prefer-inline-methods` (the last linter rule group), analyzer, parser,
bindgen; the largest functions remain `lower_async_fn` 587, `generate_c` 537,
`build_command` 526, `lower_expr` 459 and `run_command` 401.

## Session 100 — trailing-comma linter rule module

Second linter-rule split: move the token-based `trailing-list-comma` rule out
of `linter/linter.mt` into `linter/rules_trailing_comma.mt` — location keying,
the token walk, trivia handling, and the statement/expression recursion
(11 functions / 266 code lines).

- `rules_trailing_comma.mt` is 318 lines / 273 code (max function 75);
  `linter.mt` is 7,204 lines / 5,796 code (from 7,515 / 6,062).
- `lint_trailing_commas` is public; linter exposes `expression_line` and
  `expression_column` for the moved rule (`push_warning_at` already was).
  The linter area keeps its same-rank cycle (110 edges, 0 violations); the
  alias table adds `linter.rules_trailing_comma` (155 modules).
- The moved bodies are verbatim (306 lines before the new header).
- The dev linter tests cover the trailing-list-comma cases; the focused
  `std`+`examples` parity is **501 agree / 3 differ of 504** (the documented
  residue).
- Structural baseline refreshed: 155 files / 123,501 code lines; 155 alias
  modules; 110 edges; 5,228 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; refactor gate 6/6;
bootstrap fixed point holds (`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: the remaining linter rules (`redundant-else`, `prefer-inline-methods`),
analyzer, parser, bindgen; the largest functions remain `lower_async_fn` 587,
`generate_c` 537, `build_command` 526, `lower_expr` 459 and `run_command` 401.

## Session 99 — doc-tag linter rule module

First linter-rule split: move the `doc-tag` rule out of `linter/linter.mt` into
`linter/rules_doc_tag.mt` — doc-comment scanning, tag parsing, parameter-name
matching, and warning emission (16 functions + 2 structs / 258 code lines).

- `rules_doc_tag.mt` is 322 lines / 264 code (max function 78);
  `linter.mt` is 7,515 lines / 6,062 code (from 7,830 / 6,320).
- `lint_doc_tags` and `names_contains` are public; linter exposes
  `push_warning_at` and `is_void_type` for the moved rule.  The linter area
  keeps its same-rank cycle (110 edges, 0 violations); the alias table adds
  `linter.rules_doc_tag` (154 modules).
- The moved bodies are verbatim (311 lines before the new header).  The module
  imports `std.str` for the byte/string methods it calls.
- The dev linter tests cover the doc-tag cases; the full corpus parity is
  re-run on the fresh stage2.
- Structural baseline refreshed: 154 files / 123,494 code lines; 154 alias
  modules; 110 edges; 5,228 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; refactor gate 6/6;
bootstrap fixed point holds (`stage2.c == stage3.c`; stage2 self-test 21/0).
Full lint parity scans 658 files: **624 agree / 34 differ**; the `std`+`examples`
residue is still the 4 documented rows, and the 30 additional rows are
`projects/mtc/src` files where the host linter times out (`<timeout after
180s>`) or reports pre-existing source-only warnings.

Next: the remaining linter rules (`trailing-comma`, `redundant-else`,
`prefer-inline-methods`), analyzer, parser, bindgen; the largest functions
remain `lower_async_fn` 587, `generate_c` 537, `build_command` 526,
`lower_expr` 459 and `run_command` 401.

## Session 98 — build/run command module

Sixth `main.mt` split and the largest command subsystem: move `mtc build`,
`mtc run`, and `mtc run-module` out of main.mt into `main/build_cli.mt` — the
two flag parsers, package resolution, bundle/archive staging, wasm output,
cache/build-driver calls, and binary execution (14 functions / 1,196 code
lines).

- `build_cli.mt` is 1,351 lines / 1,222 code (max function 526,
  `build_command`, already counted); `main.mt` is 3,648 lines / 3,010 code
  (from 4,965 / 4,206).
- `build_command`, `run_command` and `run_module_command` are public; main
  exposes `print_program_diagnostics`, `parse_platform_name`,
  `platform_label`, `parse_source_operand`, `reject_external_root` and
  `reject_missing_entrypoint` for the moved code, plus a `cli_is_quiet()`
  accessor (`cli_is_verbose` already existed).  The same-rank `main -> main`
  edge already existed (110 edges, 0 violations); the alias table adds
  `main.build_cli` (153 modules).
- The moved bodies are verbatim (1,321 lines before the new header).
  Duplication drops 5,252 -> 5,228 lines.
- CLI parity covers build/run/run-module; the example sweep rebuilds 49/49
  examples.
- Structural baseline refreshed: 153 files / 123,488 code lines; 153 alias
  modules; 110 edges; 5,228 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; examples 49/49;
refactor gate 6/6; bootstrap fixed point holds (`stage2.c == stage3.c`;
stage2 self-test 21/0).

Next: analyzer, linter, parser, bindgen; the largest functions remain
`lower_async_fn` 587, `generate_c` 537, `build_command` 526, `lower_expr` 459
and `run_command` 401.

## Session 97 — snapshot/debug command module

Fifth `main.mt` split: move `mtc snapshot` and `mtc debug` out of main.mt into
`main/snapshot_debug_cli.mt` — the highlighted HTML snapshot and the CLI
debug-info dump (2 functions / 237 code lines).

- `snapshot_debug_cli.mt` is 283 lines / 252 code (max function 191);
  `main.mt` is 4,965 lines / 4,206 code (from 5,229 / 4,443).
- `snapshot_command` and `debug_command` are public; main exposes
  `extract_resolution_flags_span`, `validate_source_operands`,
  `split_include_pairs`, `effective_source_path` and
  `apply_package_resolution` for the moved code (`expand_source_operands`,
  `operand_label`, `add_module_roots` and `eprint_line` were already public).
  The same-rank `main -> main` edge already existed (110 edges, 0 violations);
  the alias table adds `main.snapshot_debug_cli` (152 modules).
- The moved bodies are verbatim (263 lines before the new header).
  Duplication re-clusters to 790 windows / 5,252 lines (+10); no new duplicate
  code.
- CLI parity covers the snapshot/debug command surfaces.
- Structural baseline refreshed: 152 files / 123,462 code lines; 152 alias
  modules; 110 edges; 5,252 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; refactor gate 6/6;
bootstrap fixed point holds (`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: main `build_command` (526) / `run_command` (401); analyzer, linter,
parser, bindgen; the largest functions remain `lower_async_fn` 587,
`generate_c` 537, `build_command` 526, `lower_expr` 459 and `run_command` 401.

## Session 96 — test command module

Fourth and largest `main.mt` split: move the whole test subsystem out of
main.mt into `main/test_cli.mt` — the test runner, death tests, compile-fail
fixtures, human/TAP/JUnit reporters, and the test result/option types
(29 functions + 6 types / 1,110 code lines).

- `test_cli.mt` is 1,362 lines / 1,132 code (max function 253,
  `test_command`, already counted); `main.mt` is 5,229 lines / 4,443 code
  (from 6,565 / 5,553).
- `test_command`, `eprint_missing_option_value` and `is_known_build_kind` are
  public; main exposes `first_error_line`, `eprint_message`,
  `print_lex_diagnostics`, `print_parse_diagnostics` and
  `apply_package_resolution_result` for the moved code.  The same-rank
  `main -> main` edge already existed (110 edges, 0 violations); the alias
  table adds `main.test_cli` (151 modules).
- The moved bodies are verbatim (1,335 lines before the new header).
- CLI parity covers the 43 `mtc test` cases.
- Structural baseline refreshed: 151 files / 123,447 code lines; 151 alias
  modules; 110 edges; 5,242 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; refactor gate 6/6;
bootstrap fixed point holds (`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: the remaining large files (main: `build_command` 526 / `run_command`
401 and the snapshot/debug cluster, analyzer, linter, parser, bindgen); the
largest functions remain `lower_async_fn` 587, `generate_c` 537,
`build_command` 526, `lower_expr` 459 and `run_command` 401.

## Session 95 — format command module

Third `main.mt` split: move `mtc format` out of main.mt into
`main/format_cli.mt` — single-file and batch formatting, check/write modes,
single-file output rules, default output paths, and the format timing profile
(6 functions / 255 code lines).

- `format_cli.mt` is 306 lines / 269 code (max function 114); `main.mt` is
  6,565 lines / 5,553 code (from 6,850 / 5,808).
- `format_command`, `default_output_path` and `monotonic_ms` are public;
  main exposes `expand_source_operands`, `operand_label`,
  `report_missing_source`, `j2_path` and `parse_positive_int` for the moved
  code, plus a `cli_is_verbose()` accessor for the `-v` flag.  The same-rank
  `main -> main` edge already existed (110 edges, 0 violations); the alias
  table adds `main.format_cli` (150 modules).
- The moved bodies are verbatim (289 lines before the new header).
  Duplication drops 5,256 -> 5,242 duplicated lines.
- CLI parity covers the format command surface.
- Structural baseline refreshed: 150 files / 123,425 code lines; 150 alias
  modules; 110 edges; 5,242 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; refactor gate 6/6;
bootstrap fixed point holds (`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: the remaining large files (main: `build_command` 526 / `run_command`
401, the snapshot/debug/test command clusters, analyzer, linter, parser,
bindgen); the largest functions remain `lower_async_fn` 587, `generate_c` 537,
`build_command` 526, `lower_expr` 459 and `run_command` 401.

## Session 94 — bindings command module

Second `main.mt` split: move `mtc bindgen` and `mtc imported-bindings` out of
`main.mt` into `main/bindings_cli.mt` — the two command handlers, JSON/report
helpers, diff/status helpers, and `IbOutcome` (10 functions / 501 code lines).

- `bindings_cli.mt` is 575 lines / 517 code (max function 216,
  `bindgen_command`, already counted); `main.mt` is 6,850 lines / 5,808 code
  (from 7,403 / 6,309).
- `bindgen_command` and `imported_bindings_command` are public;
  `ptr_uint_to_str` becomes public in main for the moved module (`eprint_line`
  already is).  The same-rank `main -> main` edge already existed, so the edge
  count stays 110; the alias table adds `main.bindings_cli` (149 modules).
- The moved bodies are verbatim (554 lines before the new header).
- CLI parity covers the bindgen/imported-bindings surfaces.
- Structural baseline refreshed: 149 files / 123,411 code lines; 149 alias
  modules; 110 edges; 5,256 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; refactor gate 6/6;
bootstrap fixed point holds (`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: the remaining large files (main: `build_command` 526 / `run_command`
401, analyzer, linter, parser, bindgen); the largest functions remain
`lower_async_fn` 587, `generate_c` 537, `build_command` 526, `lower_expr` 459
and `run_command` 401.

## Session 93 — std catalog command module

First `main.mt` split: move the `mtc std list|show|source` command out of
`main.mt` into `main/std_cli.mt` — the dispatch, catalog collection/sorting,
path preference, doc summaries, text/JSON listing, and the `StdCatalogEntry`
struct (18 functions / 391 code lines).

- `std_cli.mt` is 461 lines / 402 code (max function 50); `main.mt` is 7,403
  lines / 6,309 code (from 7,848 / 6,700).
- `std_command` and `append_json_string` are public; `eprint_line` and
  `add_module_roots` become public in main for the moved module.  The main
  area gains a same-rank `main -> main` edge (110 edges total, 0 violations);
  the alias table adds both `main` (now imported) and `main.std_cli` (148
  modules).
- The moved bodies are verbatim (444 lines before the new header).
- CLI parity covers the std command surface; `lower` is unchanged.
- Structural baseline refreshed: 148 files / 123,395 code lines; 148 alias
  modules; 110 edges; 5,256 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; refactor gate 6/6;
bootstrap fixed point holds (`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: the remaining large files (main: `build_command` 526 / `run_command`
401, analyzer, linter, parser, bindgen); the largest functions remain
`lower_async_fn` 587, `generate_c` 537, `build_command` 526, `lower_expr` 459
and `run_command` 401.

## Session 92 — c_backend reachability module

First module of the large-file pass: move the reachability analysis out of
`c_backend/c_backend.mt` into `c_backend/reachability.mt` — `emitted_constants`
and its constant-reference walks, `emitted_functions` and its
reach-from-expression/statement walks (9 functions / 349 code lines).

- `reachability.mt` is 393 lines / 349 code (max function 75); `c_backend.mt`
  is 8,031 lines / 6,121 code (from 8,415 / 6,462).
- `emitted_constants` and `emitted_functions` are public; the other seven
  helpers stay private.  `else_stmts_or_empty` becomes public in c_backend for
  the moved walks, so the c_backend area gains a same-rank `c_backend ->
  c_backend` edge (109 edges total, 0 violations).
- The moved bodies are verbatim (378 lines before the new header).  The
  module needs `std.str` for the `str` methods it calls.
- `lower` is unchanged (the c_backend split is downstream of lowering).
- Structural baseline refreshed: 147 files / 123,384 code lines; 146 alias
  modules; 109 edges; 5,256 duplicated lines; 33 functions >= 200 lines; 12
  files >= 2,000 code lines.

Verification: dev suite 21/0; `test/mt` 61/0; examples 49/49; CLI 224/224;
refactor gate 6/6; bootstrap fixed point holds (`stage2.c == stage3.c`;
stage2 self-test 21/0).

Next: the remaining large files (main: `build_command` 526 / `run_command`
401, analyzer, linter, parser, bindgen) and the c_backend `generate_c` (537) /
`lower_async_fn` (587) functions.

## Session 91 — lower_call decomposition

Decompose `lower_call` (764 lines) into a 48-line dispatcher plus seven
private helpers.  The identifier callee splits into the builtin dispatch
(`lower_identifier_call`), the `ptr_of`/`ref_of`/`const_ptr_of` path
(`lower_addr_builtin_call`), and the plain call path
(`lower_plain_identifier_call`); the member callee keeps its receiver match in
`lower_member_call` (194 lines) and returns through `lower_member_dispatch`
and `lower_member_field_call`; specializations go through
`lower_specialization_callee_call`.

- `lowering.mt` is 18,410 lines / 13,565 code (from 18,355 / 13,524); the
  +41 code lines are the wrapper and `unsafe:` lines.
- All helpers are below 200 lines (largest: `lower_member_field_call` 195,
  `lower_member_call` 194, `lower_plain_identifier_call` 98).  The
  long-function count drops **34 → 33**; `lower_expr` (459 lines) is now the
  largest lowering function.
- The moved blocks are verbatim.  The `ptr_of` and plain-call bodies get
  their own `unsafe:` wrapper because they were inside `lower_call`'s; the
  member receiver match stays in `lower_member_call` so its early returns
  still exit the call lowering.
- `lower` is 699 match / 2 differ / 53 host-rejected / 0 self-rejected of 754
  (the two documented artifacts).

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; refactor gate 6/6;
guard 0 layering/alias/naming/vocabulary violations, 35 unused / 6 test-only,
789 clusters / 5,256 duplicated lines, 33 functions ≥ 200; bootstrap fixed
point holds (`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: the other large files (c_backend, main, analyzer, linter, parser,
bindgen); the largest remaining functions are `lower_async_fn` (587),
`generate_c` (537), `build_command` (526), `lower_expr` (459) and
`run_command` (401).

## Session 90 — lower_stmt decomposition

Decompose `lower_stmt` (915 lines) into a dispatcher plus per-statement-kind
helpers.  The 20-arm `match read(sp)` becomes a 43-line `lower_stmt` dispatching
to 19 private helpers (`lower_return_stmt`, `lower_local_stmt`,
`lower_assignment_stmt`, …); the `stmt_local` arm splits again into
`lower_local_stmt` (async CPS, destructure, guard, `?` and match-expression
forms) and `lower_plain_local_stmt` (the declaration path), passing the
once-computed discard temp name `c_name`.

- `lowering.mt` is 18,355 lines / 13,524 code (from 18,175 / 13,384); the
  +140 code lines are the 20 re-match wrappers.
- All helpers are below the 200-line limit (largest:
  `lower_plain_local_stmt`, 179 lines; `lower_assignment_stmt`, 155;
  `lower_while_stmt`, 149; `lower_return_stmt`, 145).  The long-function
  count drops **35 → 34**; `lower_call` (764 lines) is now the largest.
- The arm bodies move verbatim (checked against the pre-split function); the
  dispatcher's `_` arm keeps the unsupported-statement `fatal`.
- `lower` is 699 match / 2 differ / 53 host-rejected / 0 self-rejected of 754
  (the two documented artifacts).

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; refactor gate 6/6;
guard 0 layering/alias/naming/vocabulary violations, 35 unused / 6 test-only,
789 clusters / 5,256 duplicated lines, 34 functions ≥ 200; bootstrap fixed
point holds (`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: `lower_call` (764 lines), then the other large files (c_backend, main,
analyzer, linter, parser, bindgen).

## Session 89 — if/for/iteration module

First module of the statement-core pass: move the if/else chain, range and
collection `for`, custom-iterator, and array-to-span lowering out of
`lowering/lowering.mt` into `lowering/control_flow.mt` — `lower_if_chain`,
`lower_if_chain_at`, `lower_for_range`, `lower_collection_for`,
`lower_custom_iter_for`, `if_branches_all_terminate`, `ast_is_integer_literal`,
`is_numeric_const_expr`, `array_length_of`, `lower_array_as_span` — 10 functions
/ 402 code lines.

- `control_flow.mt` is 553 lines / 402 code (max function 125);
  `lowering.mt` is 18,175 lines / 13,384 code (from 18,699 / 13,768).
- Three moved functions become public (`lower_if_chain`, `lower_for_range`,
  `lower_array_as_span`); `lower_if_chain_at`, `ast_is_integer_literal` and
  `array_length_of` stay public.  `append_hoist_cleanups`,
  `guard_binding_projection` and `lower_call` become public for the moved
  module; `inline.mt`, `parallel.mt`, `comptime.mt` and `tasks.mt` now reach the
  moved helpers through `control_flow`.
- `BindingProjection` is a variant, and variant arms are not resolvable across
  a mutual import cycle, so lowering exposes `plain_binding_projection()`
  instead of making the variant public.  The module also imports `std.str` for
  its `Map[str, …]` refinements.
- `lower` is 699 match / 2 differ / 53 host-rejected / 0 self-rejected of 754
  (the two documented artifacts; `control_flow.mt` matches).

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; refactor gate 6/6;
guard 0 layering/alias/naming/vocabulary violations, 35 unused / 6 test-only,
789 clusters / 5,256 duplicated lines; bootstrap fixed point holds
(`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: `lower_call` (764 lines) and `lower_stmt` (909 lines), then the other
large files (c_backend, main, analyzer, linter, parser, bindgen).

## Session 88 — monomorphized function and module-driver module

Twelfth module of the lowering split: move the whole `Monomorphized function
lowering` section out of `lowering/lowering.mt` into
`lowering/monomorphized.mt` — type-parameter substitution, the generic-instance
registry accessors, `create_lowering_context`, `collect_program_returns`,
specialization ordering (`DeclVisit`, `build_decl_visits`, `spec_creator_ready`,
`order_module_functions`), the per-module driver (`lower_module`), and
`collect_opaque_decls` — 20 functions / 1,072 code lines plus the `DeclVisit`
struct.

- `monomorphized.mt` is 1,344 lines / 1,072 code (max function 376,
  `lower_module`); `lowering.mt` is 18,699 lines / 13,768 code (from 20,017 /
  14,819).
- Ten moved entry points are public (`lower_specialized_function`,
  `substitute_type_params`, `generic_instance_get/set/contains`,
  `collect_program_returns`, `spec_arg_type_to_s`, `order_module_functions`,
  `lower_module`, `collect_opaque_decls`); eight were private before the move.
  The shared types the module constructs are public too (`DeferGroup`,
  `PendingSpecialization`, `EventRuntimeInfo`, `SpecInfo`, `GenericReceiver`),
  and 21 lowering helpers become public for the moved walk.
- `monomorphized` imports lowering, and lowering/`type_helpers`/`async_cps`
  import it; the lowering submodules now form one SCC.  Session 77's cycle
  support handles it.  The module needs `import std.str`: its `Map[str, …]`
  keys resolve `hash[str]`/`equal[str]` through that import, and the host
  rejects the module without it.
- `lower` is 698 match / 2 differ / 53 host-rejected / 0 self-rejected of 753
  (the two documented artifacts; `monomorphized.mt` matches).

Verification: dev suite 21/0; `test/mt` 61/0; CLI 224/224; refactor gate 6/6;
guard 0 layering/alias/naming/vocabulary violations, 35 unused / 6 test-only,
789 clusters / 5,256 duplicated lines; bootstrap fixed point holds
(`stage2.c == stage3.c`; stage2 self-test 21/0).

Next: the remaining expression/statement core (`lower_stmt` 909 lines,
`lower_call` 764 lines), then the other large files (c_backend, main, analyzer,
linter, parser, bindgen).

## Session 87 — include scan module

Eleventh module of the lowering split, and the first piece of the
monomorphized-function/module-driver section.  Move the include scanner and
emitter out of `lowering/lowering.mt` into `lowering/include_scan.mt`: the
`fatal`/`offsetof` usage scans, raw-module `#include` collection and emission,
the string sort helpers, and the C runtime header helpers — 17 functions and
the two `SCAN_*` constants / 309 code lines.

- `include_scan.mt` is 400 lines / 319 code (max function 62); `lowering.mt` is
  20,017 lines / 14,819 code (from 20,400 / 15,127).
- `collect_includes` and `str_less_than` become public: `lower` and the module
  function ordering call them through the new module; `is_raw_module` stays
  public in lowering.
- `lower` is 697 match / 2 differ / 53 host-rejected / 0 self-rejected of 752
  (the two documented artifacts; `include_scan.mt` matches).

Verification: dev suite 21/0 with host-built and self-built compilers;
`test/mt` 61/0; CLI 224/224; refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
stage3.c`; stage2 self-test 21/0).

Next: the remaining monomorphized-function/module-driver functions
(specialization machinery, `lower_module`, `create_lowering_context`), then the
expression/statement core and the other large files (c_backend, main,
analyzer, linter, parser, bindgen).

## Session 86 — match and variant introspection module

Tenth module of the lowering split.  Move the match lowering and the variant
arm/payload introspection helpers out of `lowering/lowering.mt` into
`lowering/match.mt`: scalar/string/tuple/enum/variant match lowering, variant
arm naming/payload resolution, and the prelude-variant helpers — 54 functions /
1,158 code lines.  The generic `stmts_terminate`, `contains_label_target`,
`append_span_stmts`, `current_return_type`, `fatal_arg_is_cstr`,
`is_integer_scrutinee` and `named_type_name` helpers stay in lowering.

- `match.mt` is 1,569 lines / 1,158 code (max function 104); `lowering.mt` is
  20,400 lines / 15,127 code (from 21,952 / 16,266).
- The async match-binding counter is program-scoped and cannot be mutated
  across modules; lowering now exposes `next_async_binding_index()` and the
  moved match bindings advance it through that accessor.
- Twenty moved functions become public for the remaining lowering; the
  private lowering helpers the module calls (`duplicable_foreign_value`,
  `is_raw_module`, `is_tuple_type`, `tuple_element_type`,
  `is_integer_scrutinee`, `named_type_name`) become public too.
- `lower` is 696 match / 2 differ / 53 host-rejected / 0 self-rejected of 751
  (the two documented artifacts; `match.mt` matches).

Verification: dev suite 21/0 with host-built and self-built compilers;
`test/mt` 61/0; CLI 224/224; refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
stage3.c`; stage2 self-test 21/0).  One gate run hit a flaky Ruby exit SIGSEGV after printing a
224/224 CLI summary; the rerun was clean.

Next: the monomorphized-function/module-driver section (it also contains
`lower_module`, `create_lowering_context` and the include scanner, so it needs
subdivision), then the remaining expression/statement core and the other large
files (c_backend, main, analyzer, linter, parser, bindgen).

## Session 85 — parallel/detach/gather module

Ninth module of the lowering split.  Move the parallel/detach/gather lowering
out of `lowering/lowering.mt` into `lowering/parallel.mt`: the per-module
parallel counter, `parallel for` capture/name collection and rewriting,
parallel blocks, detach workers, gather joins, and their two private types
(`PforNames`, `SpawnBlockInfo`) — 21 functions / 920 code lines.

- `parallel.mt` is 1,026 lines / 920 code (max function 269); `lowering.mt` is
  21,952 lines / 16,266 code (from 22,965 / 17,172).
- The shared `find_local` and `pw1_str` helpers stay in lowering (both are
  used outside the parallel constructs); `pw1_str` is called as
  `lowering.pw1_str` from the new module.
- Three lowering helpers become public (`ast_is_integer_literal`,
  `resume_stmt_setup`, `suspend_stmt_setup`); four moved functions
  (`lower_parallel_block`, `lower_parallel_for`, `lower_gather_stmt`,
  `lower_detach_expr`) become public for `lower_stmt`/`lower_expr`.
- `lower` is 695 match / 2 differ / 53 host-rejected / 0 self-rejected of 750
  (the two documented artifacts; `parallel.mt` matches).

Verification: dev suite 21/0 with host-built and self-built compilers;
`test/mt` 61/0; CLI 224/224; refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
stage3.c`; stage2 self-test 21/0).

Next: match lowering (~1,251 code), then the monomorphized-function section
(~1,361 code), then the remaining expression/statement core and the other
large files (c_backend, main, analyzer, linter, parser, bindgen).

## Session 84 — type and expression helpers

Eighth module of the lowering split.  Move the "Type resolution helpers"
section out of `lowering/lowering.mt` into `lowering/type_helpers.mt`:
signature lookup (`find_fn_sig`, `find_imported_fn_sig`, `resolve_param_type`,
`resolve_return_type`), `expr_type`, operator/vector typing, flow refinements,
and the termination analysis — 47 functions / 708 code lines.

- `type_helpers.mt` is 962 lines / 719 code (max function 128); `lowering.mt`
  is 22,965 lines / 17,172 code (from 23,909 / 17,879).
- Eight lowering helpers become public (`builtin_addr_type_name`,
  `imported_field_type`, `module_var_type`, `resolve_field_type_ref`,
  `resolve_scalar_type_ref`, `resolve_single_imported_type`,
  `substitute_type_params`, `try_spec_type_name`); the moved functions that
  remaining lowering calls (35, including the already-public signature and
  `expr_type` helpers) are public.
- `comptime.mt`, `const_eval.mt`, `format.mt` and `async_cps.mt` now import
  `type_helpers` for their former `lowering.*` calls.
- `lower` is 694 match / 2 differ / 53 host-rejected / 0 self-rejected of 749
  (the two documented artifacts; `type_helpers.mt` matches).

Verification: dev suite 21/0 with host-built and self-built compilers;
`test/mt` 61/0; CLI 224/224; refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
stage3.c`; stage2 self-test 21/0).  A killed test run had left a `__mt_test_runner_*.mt` sidecar in
`projects/mtc/test`; it was removed before the final suite.

Next: the remaining lowering core (statement/expression/declaration lowering),
then the other large files (c_backend, main, analyzer, linter, parser,
bindgen).

## Session 83 — async CPS module

Seventh module of the lowering split.  Move the async CPS lowering out of
`lowering/lowering.mt` into `lowering/async_cps.mt`: frame-field collection,
await suspension/resume, async completion, task literals, `lower_async_fn`, the
synthesized async-main entrypoint, and `AsyncFieldEntry` — 40 functions /
1,290 code lines.

- `async_cps.mt` is 1,749 lines / 1,308 code (max function 587); `lowering.mt`
  is 23,909 lines / 17,879 code (from 25,635 / 19,171).
- The program-scoped `async_binding_cnt` and its two prepass functions stay in
  lowering: cross-module mutable vars are not supported (the host rejects
  `alias.var += 1`), so the counter stays with every writer.
- Twenty-eight lowering helpers become public (frame/field collection,
  statement setup, proc/fn signature lookup, specialization hooks, `sp_str`,
  `single_ty_span`, and `async_prepass_match_bindings`); twenty-two moved
  functions become public for `lower_expr`, `lower_stmt`, the guard/propagate
  paths, `lower_call`, `lower_module` and `lower_extending_block`.
- `lower` is 693 match / 2 differ / 53 host-rejected / 0 self-rejected of 748
  (the two documented artifacts; `async_cps.mt` matches).

Verification: dev suite 21/0 with host-built and self-built compilers;
`test/mt` 61/0; CLI 224/224; refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
stage3.c`; stage2 self-test 21/0).

Next: the type-resolution helpers (~708 code), then the remaining lowering
core and the other large files (c_backend, main, analyzer, linter, parser,
bindgen).

## Session 82 — format string module

Sixth module of the lowering split.  Move the format string lowering and the
explicit format sinks out of `lowering/lowering.mt` into `lowering/format.mt`:
the format plan/result builders, cstr-backed metadata, the
`append_format`/`assign_format` sink lowering, and their four private types
(`FormatPlan`, `FormatSinkInfo`, `FormatSinkTarget`, `FormatSinkPart`) —
30 functions / 937 code lines.

- `format.mt` is 1,165 lines / 948 code (max function 139); `lowering.mt` is
  25,635 lines / 19,171 code (from 26,782 / 20,107).
- Sixteen lowering helpers become public (the format receiver/ref coercion,
  method resolution, `sp_*`/`sp_expr*`, `str_buffer_capacity_of`,
  `struct_fields_of`, and the statement-setup trio), plus `HoistSaved` and
  `HoistMode`; thirteen moved functions become public for `lower_expr`,
  `lower_stmt`, the guard/async locals and the cstr argument path.
- `lower` is 692 match / 2 differ / 53 host-rejected / 0 self-rejected of 747
  (the two documented artifacts; `format.mt` matches).

Verification: dev suite 21/0 with host-built and self-built compilers;
`test/mt` 61/0; CLI 224/224; refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
stage3.c`; stage2 self-test 21/0).

Next: the async CPS section (~1,346 code), then the type-resolution helpers,
then the other large files (c_backend, main, analyzer, linter, parser,
bindgen).

## Session 81 — task and parallel-for module

Fifth module of the lowering split.  Move the task/parallel-for cluster out of
`lowering/lowering.mt` into `lowering/tasks.mt`: the `Task[T]` type and literal
constructors, task-value unwrapping, `lower_task_constructor`,
`lower_multi_for`/`multi_for_stop`, and `has_non_lifetime_type_params` —
8 functions / 187 code lines.

- `tasks.mt` is 236 lines / 194 code (max function 134); `lowering.mt` is
  26,782 lines / 20,107 code (from 27,004 / 20,293).
- Eight lowering helpers become public (`alloc_stmt`, `contains_label_target`,
  `fresh_c_temp_name`, `generic_first_arg`, `index_receiver_type`,
  `is_array_type`, `pw1_str`, `single_expr_span`); seven moved functions become
  public for the async lowering, `lower_module`, `lower_expr`, `lower_stmt`,
  `lower_for_range` and `lower_monomorphized_call`.
- `lower` is 691 match / 2 differ / 53 host-rejected / 0 self-rejected of 746
  (the two documented artifacts; `tasks.mt` matches).

Verification: dev suite 21/0 with host-built and self-built compilers;
`test/mt` 61/0; CLI 224/224; refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
stage3.c`; stage2 self-test 21/0).

Next: the remaining lowering internals, then the other large files (c_backend,
main, analyzer, linter, parser, bindgen).

## Session 80 — layout module

Fourth module of the lowering split.  Move the compile-time layout cluster out
of `lowering/lowering.mt` into `lowering/layout.mt`: `LayoutInfo`,
`StructMeta`, and the eleven `layout_*` helpers — 217 code lines in the
contiguous block, 238 code in the module.

- `layout.mt` is 285 lines / 238 code (max function 84); `lowering.mt` is
  27,004 lines / 20,293 code (from 27,279 / 20,526).
- `LayoutInfo` becomes private (its only users are the layout helpers); the
  three entry points (`layout_size`, `layout_alignment`, `layout_offset_of`)
  stay public for `comptime.mt`, `const_eval.mt` and lowering's
  `try_const_eval_int`.
- The import alias is `layout_mod`: `layout` is already a local in
  `collect_external_structs`, and `async_mod`/`inline_mod` set the precedent.
- `lower` is 690 match / 2 differ / 53 host-rejected / 0 self-rejected of 745
  (the two documented artifacts; `layout.mt` matches).

Verification: dev suite 21/0 with host-built and self-built compilers;
`test/mt` 61/0; CLI 224/224; refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
stage3.c`; stage2 self-test 21/0).

Next: the task/multi-for helpers, then the other large files (c_backend,
main, analyzer, linter, parser, bindgen).

## Session 79 — inline control-flow module

Third module of the lowering split.  Move the compile-time inline control-flow
lowering out of `lowering/lowering.mt` into `lowering/inline.mt`: 16 functions /
355 code lines — `lower_when_stmt`, inline `if`/`match`/`while`/`for`, the
inline-for field iteration and substitution helpers, and the condition folding.

- `inline.mt` is 446 lines / 355 code (max function 55); `lowering.mt` is
  27,279 lines / 20,526 code (from 27,713 / 20,870).  The section banner and
  `MAX_INLINE_WHILE_ITERS` move with the module; `inline` is a keyword, so the
  import alias is `inline_mod` (matching `async_mod`).
- Six lowering helpers become public (`append_span_stmts`, `lower_block`,
  `lower_block_stmts`, `lower_if_chain_at`, `lower_span_stmts`,
  `lower_stmt`); eight moved functions become public for `lower_stmt`,
  `lower_member_access` and `resolve_type_ref`.
- The SCC keeps `collect_includes`' cycle ordering; `lower` is 689 match /
  2 differ / 53 host-rejected / 0 self-rejected of 744 (the two documented
  artifacts; `inline.mt` matches).

Verification: dev suite 21/0 with host-built and self-built compilers;
`test/mt` 61/0; CLI 224/224; refactor gate 6/6; bootstrap fixed point holds (`stage2.c ==
stage3.c`; stage2 self-test 21/0).

Next: the layout cluster, then the task/multi-for helpers, then the other
large files (c_backend, main, analyzer, linter, parser, bindgen).

## Session 78 — const evaluation module

Second module of the lowering split.  Move the compile-time constant
subsystem — AST evaluation, const IR construction, and enum/flags member
resolution — out of `lowering/lowering.mt` into `lowering/const_eval.mt`:
48 functions / 1,562 code lines.

- The module owns `try_const_*`, `evaluate_const_*`, the attribute-argument
  helpers, enum member lookup, and the pure const-literal retyping helpers.
  The four generic integer helpers (`apply_int_op`,
  `retype_int_element_literal`, `float32_round`, `wrap_int_value`) stay in
  lowering.
- Boundary visibility: thirteen lowering helpers and the
  `ForeignInfo`/`LocalBinding`/`VariantInfo` context structs become public
  for `const_eval.mt`; nine moved functions become public for lowering's
  callers, and `comptime.mt` now reaches `enum_member_value_in_file`,
  `is_const_comparison_op`, `resolve_const_operand` and
  `try_const_value_ir` through `const_eval`.
- `lowering.mt` is 27,713 lines / 20,870 code (from 29,518 / 22,421);
  `const_eval.mt` is 1,820 lines / 1,562 code, max function 178, so the
  35-function / 12-file limits are unchanged.  The expanded cycle
  (`lowering` ↔ `comptime` ↔ `const_eval`) reuses the include-order fix:
  `collect_includes` walks each cycle member's dependency closure first and
  then the root's.

Verification: dev suite 21/0 with host-built and self-built compilers;
`sexpr lower` **688 match / 2 differ / 53 host-rejected / 0 self-rejected of
743** (the two documented artifacts; `const_eval.mt` matches); `test/mt` 61/0;
CLI 224/224; refactor gate 6/6; bootstrap fixed point holds (`stage2.c == stage3.c`;
stage2 self-test 21/0).

Next: the remaining compile-time lowering (`when`/inline-for, layout), then
the task/multi-for helpers, then the other large files (c_backend, main,
analyzer, linter, parser, bindgen).

## Session 77 — import cycles and the first lowering split

First module of the largest-first file split (`docs/refactoring.md`): move the
comptime/const family out of `lowering/lowering.mt`.

1. **Import-cycle support in the self loader** (`67b24227`).  The requested
   split necessarily makes `lowering` and `comptime` import each other.  The
   host accepts cycles (pre-registered forward type bindings, two analysis
   passes); the self loader rejected every back-edge with
   `cyclic import detected`.  Ported the host's shape to the self:
   `binder.bind_forward_module` registers a module's type names (empty
   struct/union fields, enum/flags/variant names, opaque markers, generic
   parameters); the parse walk records every resolved dependency path (not only
   under the cache) and cycle members are the modules that reach themselves.
   A cyclic program is checked as: forward-bind the members, analyse their
   acyclic dependencies, pass 1, replace with the full pass-1 bindings, pass 2,
   then the rest in dependency-first order.  Only final-pass diagnostics are
   emitted; provisional analyses live in a scratch region retired after pass 2.
   The cache reuses a cycle whose members are current and invalidates the cycle
   plus its dependents when a member changes.  Variant arms remain in an
   acyclic shared module (`comptime_types.mt`): the host itself cannot resolve a
   variant's arms across a mutual import cycle, so the shared value types sit
   below both modules.
2. **`lowering/comptime.mt`** — 1,330 code lines / 59 functions (19
   `comptime_*` + 40 `const_*`, including `const_array_length` and
   `const_eval_int`) plus the three value variants.  `LoweringContext` and the
   twenty lowering helpers the module calls are now public cross-module
   surface; the moved functions that `lowering.mt` still calls are public as
   well.  `lowering.mt` is 29,518 lines (22,421 code), down from 31,017.
3. **Include-order parity** (`collect_includes`).  The host's
   `analyses_by_module_name` insertion order changes under a cycle (cycle
   members are checked before the acyclic closure), and raw-module `#include`
   directives follow that order.  The self now reproduces it: each cycle
   member's dependency closure first (cycle edges skipped, as the host's
   forward bindings do), then the root's remaining closure.  This closed the
   only two new `lower` differs the split introduced.

Verification: host-built dev compiler and the self-built stage2 both pass the
**21/0** suite; `sexpr lower` is **687 match / 2 differ / 53 host-rejected /
0 self-rejected of 742** (the two documented artifacts; `comptime.mt` and
`comptime_types.mt` match); the guard's 35-function / 12-file limits are
unchanged (the new module is 1,330 code lines, below the 2,000 threshold);
bootstrap fixed point holds (`stage2.c == stage3.c`; stage2 self-test 21/0),
`test/mt` is 61/0, CLI parity is 224/224, and the refactor gate is 6/6 rc=0.

Next: continue the lowering split with the rest of the compile-time section
(`try_const_*`, `evaluate_const_*`, `when`/inline-for lowering, layout), then
the other large files (c_backend, main, analyzer, linter, parser, bindgen).

## Session 76 — naming foundation and shared text leaf

First pass of the refactoring program (`docs/refactoring.md`).  Three batches:

1. **Naming-rule violations — fixed** (`509676cb`).  Twelve lowercase constants
   became UPPER_SNAKE (`CAT_*`, `KIND_*`, `INT_SUFFIX_*`) and
   `DeclarationTokenOf` became `declaration_token_of`; 46 whole-word
   replacements in three files.
2. **Shared join helpers — extracted** (`f44204f5`).  `j2`..`j6` were defined 29
   times across eight modules (real bodies plus wrappers).  `mtc.strings` now
   provides `join_two`..`join_six`, 691 call sites were redirected, and the C
   backend's only `lowering.utils` dependency — and therefore the
   `c_backend -> lowering` edge — is gone.
3. **Aliases and type suffixes — canonicalized** (`47ca1ae1`).  One effective
   alias per module (44 imports plus their call-site prefixes); duplicate
   imports and cross-target alias collisions are now guard errors.
   `pkg_source` is the single override, for `packages.source` (both `source`
   and `package_source` are common locals).  Five type renames: `Context`
   (`redundant_cast`), `LoweringContext`, `ScopeContext`, `SexprContext`,
   `MethodDecl` — 621 replacements in seven files.
4. **`lower` regression found and fixed** (`d9892739`).  The refactor gate
   surfaced a third `lower` differ: session 73's `adapter_watch = null` arm in
   `dap/server.mt` is flow-refined to `Types::Null`, and the assignment
   lowering used that refined type as the RHS context.  The host passes the
   lowered target's storage type (`block.rb:527,555`); the self now does too.
   Locked by the extended `test_null_literal_takes_context_type` (fails before,
   passes after).  `lower` is now **685 match / 2 differ / 53 host-rejected /
   0 self-rejected of 740**.
5. **Test-tree hygiene.**  `heap_region_test.mt` (a `std.mem.heap` test) moved
   from `projects/mtc/test` to `test/mt` (suite split now **21 / 61**), and the
   empty `projects/mtc/src/support/` directory was removed.  The shared
   test-helper extraction is deferred: it needs a `projects/mtc/test` module
   root in `dev_tests` and bootstrap.

Current structure: **132 files / 154,135 lines / 122,610 code lines**; 108 import
edges, **0 layering / 0 alias / 0 naming / 0 vocabulary violations**; 35 unused
+ 6 test-only public declarations; 786 duplication clusters / 5,206 duplicated
lines; 35 functions >= 200 lines; 12 files >= 2,000 code lines.

Verification after each batch: dev build, **21/0** self-host suite; guard tests
**14/14**; `--check --strict --ratchet` green; baseline refreshed.  Final pass:
bootstrap fixed point holds, `test/mt` 61/0, CLI 224/224, `lower` 685/2/53/0.

Next in the program: the file splits largest-first (lowering, c_backend, main,
analyzer, linter, parser, bindgen).  The shared test-helper extraction is
deferred behind a `projects/mtc/test` module root in `dev_tests`/bootstrap.

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
  (dev build; dev suite 21/0; guard ok; `test/mt` 61/0; CLI 224/224;
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

## Handoff (session 146)

**Next session:** the output-diagnostic batch is closed.  The CLI caret now
honors the diagnostic length, and the five positionless linter rules carry real
anchors with in-language position tests.  The constructor-field anchor is a
reviewed decision, not a pending fix (see *Deliberate differences*).  The
remaining optional items are completion after a non-text receiver and the
extension-repo `activationEvents` fix; neither is compiler work.

**Baseline:** dev suite **22/0**; bootstrap fixed point + **22/0**; `test/mt`
**85/0**; diagnostics **504/0**; CLI **227/227**; lint **673/0**; formatter
**775×3/0**.  The tier-2 set for a diagnostics/linter change is
`tools/gates.sh --areas linter,cli,oracles --run`.

**Fixtures refreshed this session:** diagnostics (two loop anchors), CLI (one
parse caret), lint (29 stale/changed rows plus the unrecorded `refresh.mt`) and
formatter (32 stale rows plus `refresh.mt`).  Every other row is byte-identical;
re-record only for a reviewed change.

## Handoff (session 145)

**Next session:** the LSP enhancement program is complete (phases 0–5);
`lsp_conformance` is **green 35/35**.  No active LSP work remains:

- rangesFormatting, workspace refresh requests, and work-done/partial-result
  streaming are implemented.
- `inlineCompletion`, `textDocumentContent`, `moniker`, `inlineValue`,
  `documentColor` and notebooks are intentionally unadvertised; revisit only
  if the language gains a matching feature.
- The workspace diagnostic scan is bounded to 500 indexed files; a larger
  workspace can still pull individual documents.

**Baseline:** conformance 35/35 (gate green); bootstrap fixed point + self-tests
22/0; `test/mt` 85/0; valgrind 0; soak 68.9 KB/cycle raw / 5.7 LS; release
archive and clean-path smoke green.  ASCII endpoint replay has seven intended
differences (phase 2–3 set plus the range-formatting capability) and no others.
The tier-2 set for an LSP change is `tools/gates.sh --areas lsp --run`.

## Handoff (session 144)

**Next session:** start the **LSP enhancement program**.  Read
`docs/lsp-enhancement-plan.md` — it is the plan of record, with the 3.18
coverage matrix, the verified defects and file locations, the phase plan, the
conformance cases and the kickoff prompt.  No code changed in the audit
session; the tree starts at the host-retirement state.

The audit found the server covers 42/54 client→server requests and 30
capability keys, but has four P0 conformance defects:

1. **UTF-16 positions** are byte columns on output and scalars on incremental
   input (only ASCII is correct); fix the encoding at one boundary, preferably
   by negotiating `utf-8` and falling back to a cached byte↔unit conversion.
2. **`quickFix`** must be `quickfix` in the capability and every action.
3. **`workspace/willRenameFiles`** must answer (it is a request) with a
   `WorkspaceEdit` that rewrites imports, or `null`.
4. **Completion resolve** must find docs from `data.uri`/`data.name` and echo
   the full item with `documentation` added.

Then P1: multi-root, watched-file registration, pull-diagnostic scope/refresh,
lifecycle, and safe `$/cancelRequest` handling.  **First action: phase 0**, the
new `tools/lsp_conformance.rb` (the existing harness is host-parity-shaped and
masks the rename and UTF-16 defects); wire it into `tools/gates.sh` and make
the cases fail before fixing them.

**Build state:** unchanged from session 143 — seed `b29241f4…`, seed dev build
~25 s, `test/mt` 85/0, dev suite 22/0, valgrind 0, soak in the 70–80 raw band.
Do not use the archived Ruby host as an oracle for LSP behavior.

## Handoff (session 143)

**Next session:** the host-retirement program is complete.  There is one
compiler; work lands in `projects/mtc` and `std/` only.  The archived host is
read-only (`archive/host-ruby-0.4.26`) and is not a build or test dependency.

Open defects, in priority order:

1. **Output diagnostics.**  The CLI caret length (`print_program_diagnostics`
   ignores `rd.length`), the zero-column linter warnings (`redundant-else`,
   `unreachable-code`, `redundant-null-check`, `loop-single-iteration`,
   `duplicate-if-condition`), and the constructor-field column in a `let`
   initializer.  These are accuracy defects, not parity gaps.
2. **Optional LSP extension.**  Completion after a non-text receiver
   (`read(p).|`) is not extended (no member token to key the analyzer fact on).
3. **Extension packaging (separate repo).**  `activationEvents:
   ["onDebug:milk-tea"]` is ignored by VS Code 1.146; add `onLanguage:milk-tea`
   so the extension activates on a `.mt` file.

Then the normal protocols: read *Status at a glance*, the Ledger, and
`docs/refactoring.md` before structural work.  `tools/gates.sh` now selects
only self-contained gates: seed dev build, bootstrap, `test/mt`, the four
recorded oracles, examples, bindings, DAP, wasm/docs smoke, LSP valgrind/soak,
and the structural guard.

**Recorded gates.**  `--expect` replays `tools/golden/{cli,diag,lint,format}.json`;
diagnostics/lint/format rows are digest-keyed, so changed inputs are skipped
(`changed=N`).  Re-record only for a reviewed behavior change.  The archived
host tree is at tag `archive/host-ruby-0.4.26` for historical inspection
(`git show archive/host-ruby-0.4.26:lib/...`), and the pre-compaction plan is at
`d8a199c7`.

**Build prerequisite.**  A literal clone has no `third_party/`; fetch it once
with the seed (`vendor/bootstrap/<platform>/mtc toolchain bootstrap`, network)
or copy an existing checkout's `third_party/`.  The bootstrap error names the
missing source.  Ruby is not needed anywhere in the build or test path.

**Build state.**  `vendor/bootstrap/linux-x86_64/mtc` is the seed
(`b29241f4…`, release, 6,289,144 B).  A seed dev build is ~25 s; a full
bootstrap ~3 min (`--fast`) / ~12 min (full).  The release artifact is
`mtc-0.4.26-linux-x86_64.tar.gz` (3.52 MiB, deterministic, checksummed).

## Handoff (session 142)

**Next session:** host retirement **phase 4 — retire the host tree**.  Phases
0–3 are done: the seed bootstraps a fresh clone, the guard lives in
`tools/lib/`, the recorded gates replay without the host, and
`tools/release.sh` produces a deterministic archive with a clean-path smoke.

- Move `lib/milk_tea`, the Ruby `test/**` suite and `milk_tea.gemspec` to an
  archive tag.  Keep only Rakefile tasks that are vendored-library tooling and
  do not load the compiler; `tools/lib/refactor_guard.rb` already stands alone.
- Remove the host-coupled tools: `gen_cli_help.rb` (its output `cli_help.mt` is
  now authored), `bindgen_parity.rb` and `imported_bindings_parity.rb` (the self
  owns `imported-bindings --all --check`), and the host side of
  `cli_parity`/`format_parity`/`diag_parity`/`lint_parity` (the `--expect` path
  is the survivor).
- Swap the gates: use `golden_*` in the analyzer/cli/linter/formatter area sets
  and drop the live parity twins.  Remove `--allow-ruby-host` once the frozen
  host is gone.
- Phase 4's gate: a fresh clone with only a C compiler builds, passes
  `test/mt`, and replays every golden.

**Recorded gates now.**  `--expect` replays against
`tools/golden/{cli,diag,lint,format}.json`; diagnostics/lint/format rows are
digest-keyed, so changed inputs are skipped (`changed=N`) instead of failing.
`tools/gates.sh --areas oracles --run` runs the set.  They are deliberately not
yet in the analyzer/cli/linter/formatter area sets — the live parity gates still
cover those areas, and running both would double tier-2 cost.  Phase 4 swaps
them in.

**Build state.**  `vendor/bootstrap/linux-x86_64/mtc` is the seed
(`b29241f4…`, release, 6,289,144 B), refreshed from the release build.  The
release artifact is `mtc-0.4.26-linux-x86_64.tar.gz` (3.52 MiB, deterministic,
checksummed beside the archive).  The guard's numbers are **126,602 code lines**,
6,345 duplicated / 884 windows, tests **22/85**; the baseline was refreshed for
the phase-2 semantic fixes and the phase-3 source removals.

## Handoff (session 141)

**Next session:** semantic conformance is closed; the remaining work is the
output-parity batch found by the session-140 audit.  The 57-file probe matrix
(`tmp/audit`, scratch) is 36 agree / 0 verdict / 20 message / 1 position; the
verdicts now all match.

- **Type qualification.**  `cannot assign`, `argument`, `condition` and
  construction-typed `return`/`match` messages use the display renderer
  (`type_to_string`, module dropped) instead of the host's qualified `to_s`;
  `try_construction` returns `ty_named(module_name = "")`, and the qualified
  renderer does not recurse through `ty_generic` (`ptr[S]`).  Use one recursive
  diagnostic renderer and set the construction module.
- **`check`/`build` rendering.**  Module errors print a full block instead of
  the host's bare `module not found: …`; `static_assert` uses a block where the
  host prints bare; `print_program_diagnostics` ignores `rd.length` (the CLI
  caret is a lone `^` where the host renders `^~~~~`); linter warnings with
  column 0 (`redundant-else`, `unreachable-code`, `redundant-null-check`,
  `loop-single-iteration`, `duplicate-if-condition`) need their real columns,
  while `owning-release-double` should stay positionless.  `lint` on an
  unresolved import is the host-CLI-facts artifact class (host reports
  `unused-import`, self suppresses) — document or match.
- **Remaining position.**  Constructor-field errors in a `let` initializer
  report the construction column instead of the bound name's column.
- **Optional LSP extension.**  Completion after a non-text receiver
  (`read(p).|`) is not extended (no member token to key the analyzer fact on).

**Build state:** `build/stage2/mtc` is current; the refactor baseline was
refreshed for the semantic port (126,536 code lines; 6,345 duplicated / 884
windows; tests 22/62).  The host method-lowering fix is in
`lib/milk_tea/core/lowering/calls.rb`; `test/mt/named_arguments_test.mt` pins
the runtime order/default cases in both compilers.  The 57 audit probes under
`tmp/audit` are scratch; recreate any cited one from the session record.

## Handoff (session 140)

**Next session:** no functional parity item is open.  Session 139 closed the
**call-argument compatibility port**, and session 140 closed the **LSP
hover-latency** item (32–36 → 2.0–7.7 ms median on `analyzer.mt`, now faster
than the host's 10–18 ms floor) while extending member resolution to
call/index receivers (`read(p).get_object`, `make().sum()`, `particles[0].y`),
a self-better extension over the host's identifier-only receiver chain.
Residuals: completion after a non-text receiver is not extended (no member
token to key the analyzer fact); the narrow session-139 divergences (named call
arguments, imported/method explicit specialization checks, extern/foreign
argument checks, nullable numeric parameters, constructor field columns) stay
documented.  The LSP audit's canonical set is now 10 (8 documented rows + 2
warm artifacts); the four new `data_structures@250:17` rows are the
index-receiver resolution and stay.

**Match-scrutinee dispatch (fixed in session 140):** a `match` on a variant-arm
payload value (nested match through `Outer.some as x`) is rejected by the host
with `match requires an enum, variant, or integer scrutinee, got Outer.some
payload`; the self used to accept it and abort in the lowering (`match requires
known type, got Outer_some`).  `check_match_stmt`/`infer_match_expr_type` now
run the host's dispatch (enum, variant, integer, `str`, tuple) and report the
host's message/position before the arms; structs, flags, floats, bools, chars
and nullables are covered too.  The check exposed a wrong event type — `wait()`
was `void`, now `Task[Result[payload|void, EventError]]` — so the event example
stays valid.  The CLI sema block still renders a lone caret (the diagnostic
carries the `match` token length for the LSP; the block printer is a pre-existing
gap).

**Watch the host compile time.**  Binding an `Option[types.Type]` payload with
`let ... else:` in the compiler sources makes the host analyzer ~4.5x slower on
that module (69 s → 297 s for `mtc check .../main.mt`, GC-dominated); the
equivalent `match` is flat.  Session 139 hit this in
`try_quiet_type_substitutions` and kept the `match` form.

**Memory.**  Keep heavy sweeps memory-capped: `-j 4 --mem-mb 8000` for
`sexpr lower`.  Each compiler-sized closure peaks 3.4–3.8 GiB, and the seven
`main*.mt` loop-guard artifacts together exhausted this 31 GiB workstation at
`-j 16` (session 140: the kernel killed an unrelated 12.9 GiB Python process;
the `mtc lsp` server was 94 MB).  `sexpr_parity` now defaults lower to 4 jobs,
warns when no cap is passed, and records a signal-killed self process as
`128 + signal` (the loop-guard aborts are self-fail, not empty-output differ).

**Current tree (session 140):** `lsp/workspace.mt` (the per-document text
cache, `document_text`/`document_hash_for`, stat-stamped closed documents),
`lsp/navigation.mt` (the text-view hand-off, the receiver fallback),
`lsp/cursor.mt` (`member_dot_at`), `semantic/analyzer.mt`
(`member_receiver_types`, `receiver_is_text_chain`, the
`check_member_call`/`resolve_member_access` recording, the match-scrutinee
dispatch and its type text, and the event `wait()` result type), the three
tests in `test/semantic_test.mt` (two receiver facts + the match diagnostic),
the `hover/chained-method` case (88 requests), the `sexpr_parity` signal/cap
handling, and the refreshed `tools/refactor_baseline.json`.  The previous tree
is the session-140 LSP commit (`6843cdf9`); the session-139 call-argument port
is `1ca2b78f` and session 138 (`f7661b52`) below it.

**First actions:** rebuild and smoke the tree before measuring —
`ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev`
(~105 s host-side), `tmp/mtc-dev test projects/mtc -I . --timeout 120`,
`ruby tools/refactor_guard.rb --check`.  The analyzer gates are
`ruby tools/diag_parity.rb check -j 8 std examples`,
`ruby tools/check_parity.rb`, `ruby tools/cli_parity.rb -q`,
`tools/bootstrap.sh -j 16`, `build/stage2/mtc test test/mt -I .`, and
`ruby tools/sexpr_parity.rb lower -q -j 4 --mem-mb 8000 --host-cache
tmp/sexpr-host-cache`.  Re-record the LSP harness (self and host; **88
requests**; expect the documented `typeDefinition/imported` row, the
self-better `imported-variant-arm` and `chained-method` rows, and the 3 stress
rows), run `tools/lsp_recovery_probe.rb --check`, and use `-j 2`–`4` for the
project audit.  The hover probe is `tmp/lsp_hover_perf.rb` (transient); the
class medians to expect are listed in the session-140 record.  The formatter
sweep is `ruby tools/format_parity.rb all -j 16` (778/778) and the CLI matrix is
**227 cases**.


**Read this first, then *Status at a glance* and the Ledger.**  The parity
program stays closed, and session 73 closed the last *measurement* gaps: the
`mtc test` CLI surface, then a command-surface sweep over every remaining
command.  The matrix is now **227/227**, and the fixes it forced are in the
commands themselves (see the session-73 section).

Sessions 75–130 added the refactoring safety suite (structural guard, gate
wiring, committed baseline), its first pass (naming violations, the shared
`mtc.strings` leaf, alias and type canonicalization), import-cycle support in
the loader, the lowering splits (`comptime.mt`, `const_eval.mt`,
`inline.mt`, `layout.mt`, `tasks.mt`, `format.mt`, `async_cps.mt`,
`type_helpers.mt`, `parallel.mt`, `match.mt`, `include_scan.mt`,
`monomorphized.mt`, `control_flow.mt`), the `lower_stmt` / `lower_call` /
`lower_expr` / parallel-worker / `lower_module` declaration-arm /
`lower_identifier_member` decompositions (the long-function count is now 1, the
excluded `binding_at`),
the c_backend/main splits
(`c_backend/reachability.mt`, the `generate_c` type/body phases,
`main/std_cli.mt`, `main/bindings_cli.mt`, `main/format_cli.mt`,
`main/test_cli.mt`, `main/snapshot_debug_cli.mt`, `main/build_cli.mt`), the
linter rule modules (`linter/rules_doc_tag.mt`,
`linter/rules_trailing_comma.mt`, `linter/rules_redundant_else.mt`), the
bindgen modules (`bindgen/nullable_policy.mt`, `bindgen/emitter.mt`,
`bindgen/macro_probes.mt`, `bindgen/options_json.mt`,
`bindgen/nullable_report.mt`), the parser modules
(`parser/statements.mt`, `parser/expressions.mt`,
`parser/declarations.mt`, `parser/decl_forms.mt`,
`parser/specialization.mt`, `parser/expression_forms.mt`,
`parser/call_args.mt`), the analyzer
`infer_expr_inner`, `check_member`, `check_stmt_inner`, `infer_binary`,
`resolve_named` and `check_module_opts` decompositions, and the
`lower_async_fn` vtable/cancel/constructor phases.  Session 125 added the
shared `build`/`run` options parser and phase helpers, the lint
option/scan split, the generated help-family helpers, and `parser/call_args.mt`.
Sessions 126–130 decomposed the next 29 long functions and region-scoped
`mtc test` runner builds (the old cross-file AST/analysis/IR accumulation is
gone; `test/mt` peaks at 135 MB).  The analyzer's largest
function is 109 lines; `lower_async_fn` is 141 and `generate_c` is 180;
session 130 closed the remaining nine, so every other function is below 200.
The lowering submodules now form one import SCC; keep `import std.str` in
cyclic modules that use `Map[str, …]` keys, and expose a constructor from
lowering instead of referencing a variant arm across the cycle.  Parser
submodules call the `pstate` state helpers directly and the parser-local token
wrappers through the `parser` alias.  Statement expressions go through
`expressions`, type refs/blocks through `declarations`, declaration forms
through `decl_forms`, specialization targets through `specialization`, and
if/match/proc/unsafe/prefix-cast through `expression_forms`; rename any local
named `declarations` when adding to the parser cycle.  Analyzer sections all
take the private `Context`, so prefer in-file decomposition until that state is
deliberately opened.

Session 129 decomposed `dispatch_method`, `emit_decl`,
`stmts_structural_equal`, and `expr_value`; session 130 decomposed the
remaining nine (`std_registry_lookup`, `generate_internal`,
`emit_format_string_helpers`, `load_context`, `bindgen_command`,
`build_manifest`, `dump_ir_with_analyses`, `resolve_name_in_analysis`, and
`choose_registry_version`).  No decomposition targets remain.
`binding_at` (385) stays excluded — the attempted split raised duplication and
was reverted; do not reintroduce per-command constant tables there or in the
generated help.  Verify the current shape with
`ruby tools/refactor_guard.rb --json tmp/refactor.json`.

Use `tools/gates.sh --areas refactor --run` and read `docs/refactoring.md`
before changing the self-host's shape.

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

Build the dev compiler with the seed
(`"$(tools/bootstrap.sh --print-stage0)" build projects/mtc -I . --no-cache -o tmp/mtc-dev`,
~25 s), run `tmp/mtc-dev test projects/mtc -I . --timeout 120`, and measure only
the class the change can move (`tools/gates.sh --only <gate> --run`).  Run the
tier-2 proofs once on frozen sources: `tools/gates.sh --areas cli --run`
(bootstrap, `test/mt`, `golden_cli`; logs under `tmp/gates/`).  **Do not replay
the ledger's baselines unless the tree moved.**

### Open items, in priority order

1. **LSP enhancement — CLOSED (session 145: phases 0–5).**  The audit found
   42/54 client→server requests and 30 capability keys implemented.  Phases 1–5
   closed the UTF-16 position defect, `quickfix` spelling, completion resolve,
   lifecycle/cancel, publish version, `willRenameFiles`, multi-root,
   watched-file registration, workspace-diagnostic scope/refresh,
   rangesFormatting, refresh requests and progress/partial results.  The
   `lsp_conformance` spec gate is **35/35 green**.  Only the deliberately
   skipped editor features remain out of scope; the plan is in
   `docs/lsp-enhancement-plan.md`.
2. **Host retirement — CLOSED (session 143).**  Phases 0–4 are done: the seed
   is the only stage0, the guard lives in `tools/lib/`, the recorded oracles
   replay with no host source present, the release path is deterministic, and
   `lib/`, the Ruby suite, the gemspec and the host-coupled harnesses are
   removed.  The archived tag is `archive/host-ruby-0.4.26`.
3. **Output-diagnostic defects — CLOSED (session 146).**  The CLI caret length,
   the five zero-column linter warnings and the unreachable expression anchor
   are fixed and position-tested.  The constructor-field anchor is
   re-adjudicated: the self keeps the construction expression's column, which
   identifies the offending construction more precisely than the archived
   host's declaration anchor (see *Deliberate differences*).
4. **Call-argument compatibility and conditions — CLOSED (sessions 139/141).**
   The session-138 table matches the archived host in both directions;
   session 141 closed named arguments, imported/method explicit specialization
   checks, extern/foreign arity/types, and nullable numeric targets, and made
   `if`/`while`/`static_assert`/if-expression conditions strictly bool.
5. **Earlier LSP follow-ups (sessions 134–140) — CLOSED.**  Hover latency is
   2.0–7.7 ms on `analyzer.mt`, call/index receivers resolve, and the earlier
   hover/completion/rename gaps are fixed.  Completion after a non-text
   receiver (`read(p).|`) remains unextended and is folded into the enhancement
   plan rather than tracked separately.
6. **Track G follow-ups are recorded, not pending.**  The post-fix profile is
   flat; `String.as_str()`'s per-call UTF-8 revalidation (~7%) is a documented
   invariant, and the ~2% scans are over small collections.  Reopen only with a
   fresh `perf record` showing a hotspot.
7. **No manual items remain.**  The desktop F5 click-through passed (session
   74); it found an extension-packaging defect: `activationEvents:
   ["onDebug:milk-tea"]` is ignored by VS Code 1.146, so the extension should
   add `onLanguage:milk-tea` in the extension repo.  The LSP ref-lifetime and
   imported-member-location decisions are closed.

**Do not chase** the archived host differences — the `lower` artifacts, the old
`check`/linter rows, the old LSP audit rows, the DAP frame0 row or the
test-runner binary directory.  They are historical records with the reason each
was a host artifact, not gates.  Fix only the real defects listed above; the
LSP program uses the 3.18 spec, not the archived host, as its reference.

### Session records (historical)

The per-session batch logs (sessions 51–71) are not kept in this file; none is
pending work.  The full text is recoverable from git history (`git log -p --
docs/self-host-plan.md`), and the pre-compaction snapshot through session 50 is
at `git show d8a199c7:docs/self-host-plan.md`.  Current state lives in *Status
at a glance* and the Ledger; the causes that still matter are in the track
sections and *Deliberate differences*.

## How to start a work session

### Entry points

The recorded oracles are the regression surface after host retirement:
`--expect` replays, `--record` refreshes (review the fixture diff in the same
commit).  The host-differential harnesses (`sexpr`, live CLI/lint/check, LSP
audit/recovery, bindgen/imported-bindings parity) were removed in session 143;
their historical record is the archived tag `archive/host-ruby-0.4.26`.

| Workstream | Read | Verify with |
| --- | --- | --- |
| CLI behavior | Track B; `tools/golden/README.md` | `ruby tools/cli_parity.rb --expect tools/golden/cli.json -q` (227 cases) |
| Analyzer / `check` diagnostics | the session-72/139/141 records | `ruby tools/diag_parity.rb check std examples --expect tools/golden/diag.json -q` (504 files) |
| Linter | Track C; the linter sections of `docs/language-design.md` | `ruby tools/lint_parity.rb --expect tools/golden/lint.json -q` (673 files) |
| Formatter (`:tidy`, `:preserve`, `:canonical`) | Track E/formatter history at `d8a199c7` §7 | `ruby tools/format_parity.rb all -j 4 --expect tools/golden/format.json -q` |
| Wasm build/preview | Track B item 1; `wasm_preview.mt` | `ruby tools/wasm_smoke.rb --self build/stage2/mtc` |
| Docs server | Track B item 2; `docs_app.mt` | `ruby tools/docs_smoke.rb --self build/stage2/mtc` |
| Imported bindings / bindgen | Track D; `docs/bootstrap-design.md` | `build/stage2/mtc imported-bindings --all --check`; `build/stage2/mtc bindings ...` |
| LSP | Track E; `docs/lsp-enhancement-plan.md`, `docs/lsp-design.md`, `docs/lsp-performance.md` | `ruby tools/lsp_conformance.rb --bin build/stage2/mtc` (the spec gate); `ruby tools/lsp_parity.rb record --server self --out tmp/lsp-self.json`; `tools/gates.sh --areas lsp --only valgrind_lsp,soak --run` |
| DAP | Track F; `docs/dap-design.md` | `ruby tools/dap_smoke.rb`; `ruby tools/dap_async_probe.rb` |
| Bootstrap / release | `docs/bootstrap-design.md`; `vendor/bootstrap/README.md` | `tools/bootstrap.sh -j 4`; `tools/release.sh --skip-build` |
| In-language tests | `docs/testing.md` | `build/stage2/mtc test test/mt -I .` (85/0) |
| Refactoring pass | `docs/refactoring.md` | `tools/gates.sh --areas refactor --run`; `ruby tools/refactor_guard.rb --check --strict --ratchet` |
| Example builds | Track H | `tools/gates.sh --areas examples --run` (49/49) |

### Verification tiers

Iterate cheap, prove once:

- **Tier 1 — per edit.**  Build the dev compiler with the seed
  (`"$(tools/bootstrap.sh --print-stage0)" build projects/mtc -I . --no-cache -o tmp/mtc-dev`,
  ~25 s) and run `tmp/mtc-dev test projects/mtc -I . --timeout 120`.  Measure
  only the class you touch: `tools/gates.sh --only golden_diag --run`, a single
  golden row, or the matching self-only smoke.
- **Tier 2 — once per commit, on frozen sources.**  `tools/gates.sh` prints the
  gate set for the working-tree diff (or accepts `--areas linter`); `--run`
  executes them with logs under `tmp/gates/`.  Hard proofs: `tools/bootstrap.sh
  -j 4` (fixed point + the suite) and `build/stage2/mtc test test/mt -I .`
  (85/0), then the sweep that covers the area (goldens/examples/DAP/LSP smoke).
- **Batch the ceremony, not the care.**  Land 3–5 fixes per commit, each
  verified before the next; run tier 2 once on the frozen tree.  A batch costs
  about an hour instead of five ~45-minute cycles.
- **Do not replay a baseline a previous session verified at the same commit.**
  The Ledger records the last verified numbers; re-measure only the classes your
  change can move, and only when the tree moved.
- **Rebuild before measuring.**  A stale `build/stage2/mtc` is the classic false
  result.
- **Quote sets where counters drift** (the golden file count with `tmp`
  fixtures, the lint corpus with `tmp` files).
- **Long gates in the background.**  Do not idle on a ~10–25-minute bootstrap;
  start it and keep reading/planning (but see the frozen-tree rule below).
- **`tmp/` is scratch.**  `tmp/gates/` and `tmp/mtc-dev` are the durable
  conventions; recreate a probe from the code/tests when one is cited.

### HARD RULES

- **Never edit sources while a gate runs** — `tools/bootstrap.sh` compiles the
  working tree and the recorded sweeps read it, so a mid-run edit silently
  corrupts the result.  Check the exit status, not just the tail.
- **The archived host is read-only** — never restore `lib/` to run a retired
  tool.  Update the recorded oracle (with a reviewed `--record`) or write a
  self-only check instead.
- **No hacks, no workarounds** — fix root causes where the wrong state is
  produced, not in the layer where the symptom surfaces.
- **Sandbox generated binaries**: `timeout 10 bash -c 'ulimit -v 20000000; …'`.
  A 124 exit is a hang, 137 an OOM/SIGKILL, 139 a SIGSEGV, 134 a SIGABRT/double
  free — investigate, don't call it test noise.
- **Parallelism is capped at 4**: every harness routes `-j` through
  `tools/lib/jobs.rb`; `bootstrap.sh` and `release.sh` clamp too.  The compiler
  is a multi-GiB process, so a wider fan-out exhausts RAM.
- **Check the self-test suite's file count, not just `0 failed`** — `mtc test`
  silently skips a file that fails to lex/parse (`18 test file(s), 0 failed`
  with a broken `projects/mtc/test/*.mt`); compare the count with the expected
  total.
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
  artifacts; gitignored gate output under `tmp/`, `build/` and `dist/` may stay.
  The committed bootstrap seed under `vendor/bootstrap/` is the deliberate
  exception; `tools/release.sh --refresh-seed` produces it.  `bin/mtc` is no
  longer a checkout artifact (the release archive ships its own).
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
   (recorded oracles + `dev_tests` on every source area) and the structural
   guard with a committed baseline; see `docs/refactoring.md`.
7. **Host retirement — DONE (session 143)**: phases 0–4 complete; the Ruby host
   is archived at `archive/host-ruby-0.4.26`, and the tree builds/tests/replays
   with only the native seed.

LSP, DAP and the formatter are **closed**; their remaining residues (ref-lifetime
modelling; the optional desktop F5 click-through) are unchanged.

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
Continue the Milk Tea compiler work in /home/teefan/Projects/Ruby/mt-lang
(branch `selfhost`). The host-retirement program is complete (session 143):
the native self-host is the only compiler, the Ruby host is archived at tag
archive/host-ruby-0.4.26, and the regression surface is test/mt plus the four
recorded oracles (tools/golden/{cli,diag,lint,format}.json). New work lands in
projects/mtc and std/ only, and correctness is the language manual + the
suite, not host byte-identity.

Start from this file's Handoff, Status at a glance and Ledger. No compiler
defect is pending: the output-diagnostic batch closed in session 146. The
remaining optional items are completion after a non-text receiver and the
extension-repo `activationEvents` fix. Work in tiers:
build the dev compiler with the seed
("$(tools/bootstrap.sh --print-stage0)" build projects/mtc -I . --no-cache -o
tmp/mtc-dev, ~25 s), run tmp/mtc-dev test projects/mtc -I . --timeout 120,
measure only the class you touch, and run the tier-2 proofs once on frozen
sources — tools/gates.sh prints the set (--run executes it, logs in tmp/gates/).
Do not replay the ledger's verified baselines unless the tree moved.

Read first: this file's Status at a glance, Handoff, How to start a work
session, and The program. The pre-compaction history is at
`git show d8a199c7:docs/self-host-plan.md`; the archived host is at
`git show archive/host-ruby-0.4.26:path`.

If you change a subsystem: one item per commit, sync the gate set and this
file's Ledger in the same commit, and keep the documented deliberate
differences intact. Commit trailer:
Co-authored-by: CommandCodeBot <noreply@commandcode.ai>.

HARD RULES: never edit sources while a gate runs (bootstrap compiles the
working tree — check the exit status, not the tail); rebuild before measuring;
quote sets where a counter drifts; run generated binaries as
`timeout 10 bash -c 'ulimit -v 20000000; …'`; no hacks — fix root causes;
never restore lib/ to run a retired tool (refresh the golden instead).
```

## The program — tracks and stopping rules (all tracks closed)

Goal: close every remaining self-host gap so `build/stage2/mtc` matches the Ruby
host on observable behavior everywhere — `--sexpr` dumps, CLI messages/commands,
LSP, DAP, linter, formatter, imported bindings, bindgen — while keeping the
self-host's documented improvements (malformed-frame recovery, synchronous
facts, speed, determinism).  **Every track is closed at its documented
residue (session 73); Track H's final matrix passed, session 72 measured the
one surface no gate had covered (`check`) and cleared it, session 73
measured and cleared the `mtc test` surface, session 139 closed the
call-argument compatibility port, session 141 closed the remaining semantic
verdict residuals (named arguments, imported/method specializations,
extern/foreign calls, nullable numeric, conditions), and session 140 closed the
LSP hover-latency item and extended member resolution to call/index receivers.
Any remaining differences are the documented residuals; the output-diagnostic
batch and the constructor-field position are the only open compiler items; the
track sections below are the stopping rules to preserve.**

Confirmed scope decision: **all** unported CLI subsystems are in scope (`deps`,
`docs`, wasm/emcc + preview, `--bundle`/`--archive`, `--jobs`, toolchain
bootstrap/tools, `--kind static|shared`, the bindgen policy flags), and all are
now ported.  Tracks A–D reached their targets; LSP/DAP/formatter are closed at
their documented differences.  Anchor by symbol names, not line numbers —
lines drift.

### Track A — `lower` dump parity (CLOSED: 685/2 of 740)

Current set: **685 match / 2 differ / 53 host-rejected / 0 self-rejected of 740
files** (session 76).  The host-rejected bucket is `external` and platform-pinned
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

### Track B — CLI parity (227 cases; 227 match, 0 pending; **closed**)

The **original 65-case behavior matrix is byte-equal** (session 64; `--timings`
values and `debug`'s Ruby node ids normalized).  `debug`/`test`'s argument forms
and the bundle/archive cases closed there.  The
fixed `pkg` fixture now builds and runs a real program (the old fixture used a
bare `print`, so its build/run cases only compared a semantic-error path).

Session 138 added the three formatter CLI cases (`format-directory-no-check`,
`format-parse-error`, `format-unicode`), so the matrix is **227 cases / 227
match / 0 differ / 0 pending**.  Session 65 replaced the regex allowlist with
case-backed pending metadata;
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
  immutably (`cannot assign to immutable p`).  **Call-argument model — CLOSED
  (session 139).**  The self infers each positional argument with its
  parameter's expected type and folds compile-time numeric constants at
  argument sites (direct/imported functions, constructors, static and
  value-receiver methods, explicit specializations).  The session-138 table
  matches in both directions.  The narrow residuals (named arguments, imported/
  method explicit specialization checks, extern/foreign argument checks,
  nullable numeric parameters, constructor field columns) are listed at the end
  of the session-139 record; the host's positive generic-vs-scalar split
  (`ptr[int]` → `str`) remains a permissive self fallback, which the corpus does
  not exercise.
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

Tool: `ruby tools/lint_parity.rb --expect tools/golden/lint.json -q` (the live
host comparison is retired; the 672-file oracle is the gate).

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

The LSP reached its Definition of Done: 30/30 capability keys, 6 documented
harness entries (the fifth, a module-qualified variant arm, is a self-better
extension added in session 135; the sixth, a call receiver, is session 140), the
completion class closed, `debugInfo` byte-equal, valgrind 0, hover **2.0–7.7 ms**
on `analyzer.mt` (session 140; below the host's 10–18 ms floor), edit latency
≤ 10 ms, soak at the documented meter level (session 140: 78.3 KB/cycle raw /
30.2 LS at 200 cycles) (session 71 re-measure; the per-edit leak is owned by
per-entry regions; the one-time index walk's arena-leaked ASTs are a documented
level, not a slope, and the loader's small `qname_to_str` strings remain).  Both
remaining documentation decisions are **CLOSED (session 74)** — see that
section:

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

## Deliberate differences (archived-host record)

These rows record where the self deliberately differed from the **archived Ruby
host** (`archive/host-ruby-0.4.26`).  They are history: the host is not a gate
and the host-differential tools are removed.  Do not reintroduce a host
dependency to "fix" one; if a row describes a real defect, fix the defect on
its own merit.  The canonical LSP table is `docs/lsp-design.md` §8; the main
ones:

- **LSP harness (6 documented entries):** the host's parser recovery; the host
  hanging on a malformed frame (the self answers `-32700` and keeps serving);
  the host's facts lag (the self answers synchronously); the host's
  directory-form module `typeDefinition` path (where the self resolves the
  imported declaration the host's `module_path_for_name` cannot reach); a
  module-qualified variant arm (`local.Local.one`), where the host returns null
  and the self answers the arm from the requesting document's loaded program
  (a self-better extension); and a call receiver (`make_sample().sum()`) —
  the host's member chain requires an identifier immediately before the dot and
  returns null, while the self resolves the method through the analyzer's
  recorded receiver type (session 140, self-better).
- **LSP audit (8 stable rows):** completion `mst@224:18` (the host leaks its
  synthesized `ref[@_mt_0, ubyte]` lifetime; the self shows the declared
  `ref[ubyte]`), completion `lb@818:17` (the host's facts give up on the
  `map_error` arm binding; the self answers the field), hover `type quat`
  `lb@1653:24` (the host's warm index adds the `Defined at` link; cold it
  answers null while the self answers the docs) and documentHighlight
  `lb@704:67` (the host's warm facts carry forward one range; byte-equal cold),
  plus the four `data_structures@250:17` rows
  (declaration/definition/hover/typeDefinition on `particles[0].y`): the host
  answers null or a same-named global from its definition index, while the self
  resolves the index receiver's element type and answers the field (session
  140, self-better — the same receiver fact behind the harness row above).  The
  canonical warm audit adds the 2 builtin-hover warm artifacts, and the host's
  first-file `documentSymbol` race appears as ±drift, not a work item.
- **DAP:** `lldb-real frame0 name` — self `add`, host `main_add` (the host's
  cache-hit map loss).
- **`lower`:** the host's leaked auto-lifetime names (`ref[@_mt_0, T]`) in
  `memory_stress_test`; the self renders the declared `ref[T]`.
- **`lower` `main.mt` and its submodules (`--sexpr` only):** the `main.mt` dump
  is ~59 MB and the compiler's own `String.as_str` UTF-8 validation legitimately
  scans more than the C backend's 50,000,000-iteration loop guard; the
  host-built stage1 aborts identically (`build/stage1/mtc lower
  projects/mtc/src/mtc/main.mt -I . --sexpr` -> rc 134 `loop iteration limit
  exceeded in str_is_valid_utf8`), while only the Ruby host (which has no
  guard) completes.  The six `main/*.mt` submodules import `main` and hit the
  same limit (`std_cli` and `bindings_cli` re-checked under stage1 and stage2 in
  session 107; standalone `std_cli` aborts at 31 s with rc 134).  Under the
  parallel `sexpr lower` sweep the six are counted as self-fail rather than
  differ.  Not a parity gap; the non-`--sexpr` formatting path completes on
  both C compilers.
- **`check` diagnostic residue (3 files, mixed):** the `check` sweep
  (`tools/diag_parity.rb check`) reaches **0 verdict / 0 position** at its
  per-file category over `std`+`examples`.  The three message files are:
  `std/cli.mt` (the self-only `redundant-cast` pair), `reflection_advanced.mt`
  (the host-only `constant-condition` documented below; the two
  `loop-single-iteration` diagnostics now carry the host's column 16 — session
  146), and `examples/memory_stress_test.mt` (the self emits a full
  `owning-release-double` warning block at `336:0`; the host prints the
  positionless bare message, which `diag_parity`'s host parser does not
  recognize).  The column/positionless rendering is the output-parity batch,
  not a deliberate host artifact; byte-level `check_parity` is **647/26 of
  673**.
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
  - `projects/mtc/src/mtc/main.mt` — the host linter times out on this file
    (`<timeout after 240s>` in the focused harness) and, in the full corpus,
    reports a positionless `prefer-or-pattern` (adjacent match arms with
    identical bodies) whose `--fix` makes no change; the self's linter does not
    match that node.  (The former self-only multibyte `redundant-cast` row
    disappeared with the deleted `--machine` lex output.)
- **`platform-api-drift` in the CLI:** the host `lint` command analyzes each
  operand from a bare `Parser.parse` (empty module name) while sibling files
  load through `ModuleLoader` (inferred names), so its module-name guard skips
  every CLI comparison; the rule only fires through the LSP.  The self compares
  the sibling paths it discovered (same stem, hence the same module by
  construction) and reports in both the CLI and the LSP — the rule's intent.
  Verified message-for-message against the host linter invoked directly, which
  loads the root through the module loader.
- **Constructor-field diagnostics anchor at the construction expression:** the
  self reports `unknown field Foo.bad` and `field Foo.value expects ...` at the
  `Foo(...)` call.  The archived host filled missing positions from its
  error-node/statement context, which yields the declaration's column.  The
  construction column identifies the offending expression and is kept by
  review (session 146); do not regress it to the declaration anchor.
- **Better-than-host behaviours to preserve:** malformed-frame `-32700` + keep
  serving, synchronous facts with no lag, faster cold start, deterministic
  binding-map iteration, member resolution through a call/index receiver
  (`read(p).method`, `particles[0].field`) where the host requires an
  identifier before the dot; a capability the host lacks is not automatically a
  defect to remove.
- **`format --check` on non-ASCII canonical source:** the host's canonical
  printer returns an ASCII-8BIT string, so its `source != formatted` comparison
  reports `needs formatting` for any file with non-ASCII bytes even when the
  formatted bytes are identical (and `--write` would rewrite it).  The self
  compares bytes and reports `already formatted`.  This is a host encoding
  artifact; do not reproduce it.
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
when the tree moved.  Target = the Definition of Done above.  The live parity
rows were retired with the host (session 143); the archived tag holds their
historical record.

| Gate | Live | Measured | Command |
| --- | --- | --- | --- |
| host tree | **removed**; `lib/`, Ruby `test/**`, gemspec, Rakefile, Gemfile and `bin/mtc` are gone; archived tag `archive/host-ruby-0.4.26` | session 143 | `git show archive/host-ruby-0.4.26:path` |
| bootstrap fixed point | holds (`stage2.c == stage3.c`); **22 files / 0 failed**; a `ruby` shim that exits 127 is never invoked | session 146 (replayed) | `tools/bootstrap.sh -j 4` |
| bootstrap seed | `vendor/bootstrap/linux-x86_64/mtc`, release stage2, 6,289,144 B, sha256 `b29241f4…`; the only stage0 | session 142 | `tools/bootstrap.sh --print-stage0` |
| fresh-clone gate | a `git clone` + `third_party/` (no `build/`, `tmp/`, `lib/`): a `ruby` shim that exits 127 is never invoked; fixed point + 22/0; `test/mt` 85/0; goldens 227 / 504 / 672 / 774×3 | session 143 | `git clone`, symlink/copy `third_party/`, `tools/bootstrap.sh -j 4` |
| `test/mt` | **85 files / 0 failed** (62 in-language + 23 compile-fail diagnostics fixtures); peak RSS 135 MB | session 146 (replayed) | `build/stage2/mtc test test/mt -I .` |
| output diagnostics | caret `^` + `~` per `length`; five linter anchors (duplicate condition, `else`, loop, null-check condition span, unreachable expression fallback) pinned by in-language spans | session 146 | `tmp/mtc-dev test projects/mtc -I . --timeout 120`; `ruby tools/refactor_guard.rb --check --strict --ratchet` |
| examples | **49/49 build** under the self-only `emit-c` gate (15 top-level + 34 sdl3) | session 143 | `tools/gates.sh --areas examples --run` |
| recorded CLI oracle | **227/227 cases**, host-free | session 146 (replayed) | `ruby tools/cli_parity.rb --expect tools/golden/cli.json -q` |
| recorded diagnostics oracle | **504 files / 0 differ** (`changed=0`, `unrecorded=0`); the two `loop-single-iteration` anchors are now column 16 | session 146 (replayed) | `ruby tools/diag_parity.rb check std examples --expect tools/golden/diag.json -q` |
| recorded lint oracle | **673 files / 0 differ** (`changed=0`, `unrecorded=0`); 43/43 rules, 13/13 fixers | session 146 (replayed) | `ruby tools/lint_parity.rb --expect tools/golden/lint.json -q` |
| recorded formatter oracle | **775 files × 3 modes / 0 differ** (`changed=0`, `unrecorded=0`) | session 146 (replayed) | `ruby tools/format_parity.rb all -j 4 --expect tools/golden/format.json -q` |
| wasm preview | self=ok: entry/JS/WASM/HEAD/404/405, COOP/COEP, SIGTERM rc 0 | session 71 (tool now self-only) | `ruby tools/wasm_smoke.rb --self build/stage2/mtc` |
| docs server | self=ok: reference/stdlib/source/highlight/search/assets/404, SIGINT rc 0 | session 71 (tool now self-only) | `ruby tools/docs_smoke.rb --self build/stage2/mtc` |
| LSP instruments | valgrind **0 errors**; edit latency **4.9 ms median**; hover **2.0–7.7 ms median** by probe class; soak **68.9 KB/cycle raw / 5.7 LS** at 200 cycles (session 145; no positive slope); `debugInfo` byte-equal | sessions 135/140/145 (self-only) | `tools/gates.sh --areas lsp --only valgrind_lsp,soak --run`; `ruby tools/lsp_parity.rb record --server self --out tmp/lsp-self.json` |
| LSP spec conformance | **phases 0–5: 35 cases, 35 pass / 0 fail**; gate green; all protocol, workspace, pull-diagnostic, formatting-range, refresh and progress/partial cases green; coverage 42/54 requests, 30 capability keys; plan in `docs/lsp-enhancement-plan.md` | session 145 | `ruby tools/lsp_conformance.rb --bin build/stage2/mtc` |
| DAP | self-only smoke: every probe answers; real lldb-dap reaches the `add` breakpoint and terminates; async launch-order probe green | session 143 (adapted) | `ruby tools/dap_smoke.rb`; `ruby tools/dap_async_probe.rb` |
| imported bindings | **29 verified / 0 changed of 29** (native check; the host parity report is retired) | session 72 (native) | `build/stage2/mtc imported-bindings --all --check` |
| throughput | `emit-c` **17.1 s**, full `build` **32.7 s**, `bootstrap --fast` **2.6 min** (session 72; the archived host measured 54.3 s / 76.3 s) | session 72 | time `build/stage2/mtc emit-c projects/mtc/src/mtc/main.mt -I .` |
| analyzer memory | `check main.mt` **712 MiB / 6.6 s**; `lowering.mt` **274 MiB**; fan-out capped at 4 | session 142 | `time build/stage2/mtc check projects/mtc/src/mtc/main.mt` |
| release archive | 3.52 MiB deterministic `mtc-0.4.26-linux-x86_64.tar.gz`, checksummed; clean-path smoke green | session 142 | `tools/release.sh --skip-build`; `tools/release_smoke.sh` |
| refactor guard | **0 layering / 0 alias / 0 naming / 0 vocabulary violations** (111 edges, 169 files); 32 unused / 6 test-only exports; 6,470 duplicated lines / 896 clusters; 1 function ≥ 200 lines (`binding_at`); 11 files ≥ 2,000 code lines; 0 markers; tests 22/85; `--check --strict --ratchet` ok | session 146 (baseline refreshed for the warning-anchor logic and a shifted dead-export key) | `ruby tools/refactor_guard.rb --check --strict --ratchet`; `ruby tools/test/refactor_guard_test.rb`; `tools/gates.sh --areas refactor --run` |

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

- **`lower` regressions:** the track is closed at 685/2/53/0 (the two documented
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
