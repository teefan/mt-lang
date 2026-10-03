# Self-Host Plan

> **Starting a session?** Read **"How to start a work session"** below (the entry
> points and the tiered gate protocol), then **The program** — the single ranked
> remaining-work list — and the *latest* session record in **§0k**.  The
> **Ledger** carries the last verified number per gate.  This file is the single
> self-host planning document: it absorbed the former plan files (the sibling
> `foundational-blockers` / `lsp-parity` plans and the `~/.commandcode/plans`
> session plans) on 2026-10-03 (session 25) — the originals are in git history;
> see *Provenance* at the end.

## Contents

- [How to start a work session](#how-to-start-a-work-session-read-this-first)
- [The program — ranked remaining work](#the-program--ranked-remaining-work)
- [Ledger and scoreboard](#ledger-and-scoreboard)
- §0k — LSP / linter / formatter records and the session history (sessions 4–24)
- §0j — stress, parse and `lower` records · §0i, §0h, §0a–§0f — older sessions
- §1–§7 — subsystem records · Appendix (working notes) · Provenance

> **Workstream status (self-host vs `projects/stress`)**: **DONE** — the
> self-host compiler builds, links and runs `projects/stress` with output and
> exit status identical to the Ruby host's build (exit 242, empty stdout).  The
> root causes fixed on the way (task-root proc bridge, proc bodies inside async
> functions, builtin vector constructors, format-string locals, `inline for`
> reflection) plus reproduction and verification steps are in §0j's
> "The `projects/stress` build — absorbed record" below.

Status: **SELF-HOSTING FIXED POINT ACHIEVED. LSP + DAP + BINDGEN + IMPORTED-BINDINGS COMPLETE.**
**A real user project outside the repository builds and runs under the
self-host** (`~/Projects/MilkTea/SimpleGame`, the const-aggregate blocker of
§0j item 12 — fixed in session 2; the binary initializes raylib and audio and
runs).
Stage2 == stage3 byte-identical; the compiler self-test suite is **596 tests
across 15 files, 0 failed** (re-measured 2026-10-03 session 27; 591 at session
26, 516 at session 2);
the self-host also builds every example and `test/mt` file the host does (see
§0j's 2026-09-27 section).
**Linter parity: `language_baseline.mt`'s and `memory_stress_test.mt`'s
diagnostic arrays are byte-identical to the Ruby host's (98/98 and 10/10, 0
differing lines; sessions 17–18), and the whole-corpus sweep reads 494 agree /
115 differ (below).**
**Raylib parity: 217/219 build and run** (2026-07-16 sweep).
**Language examples: 15/15 build under `--no-cache`** (2026-09-27; the four that
failed — `async_network_lobby`, `async_stress_test`, `data_structures`,
`nullable_and_variant_test` — are fixed, see §0j's 2026-09-27 section) and
**the `examples/sdl3` family is 34/34** (it built none before); every example
that builds also matches the host's stdout+exit (sampled: `integration_test`,
`reflection_advanced`, `language_baseline`, `event_stress_test`). **The vendored example families now
build and run at parity**: `box2d/drop`, `box2d/explosion`, `box3d/ragdoll` and
`box3d/box_stack` produce byte-identical stdout under both compilers, and
`examples/sdl3` files `check` clean (§0j items 5–13). **`mtc lint` has 37 rules plus `--fix`
(10 auto-fixable rules, byte-identical output vs Ruby) and `.mt-lint.yml`
config** (`prefer-inline-methods` landed with the LSP diagnostics work; its
auto-fix is not ported).  Bootstrap via `tools/bootstrap.sh`.
Test runner now builds in-process (no Ruby delegation).  Vendored library
recipes complete for all **11** vendored families (raylib, glfw, tracy, cjson,
box2d, box3d, sdl3, flecs, pcre2, steamworks, libuv).  Bindgen self-hosted (687 lines CL
→ MT type mapper + clang JSON AST parser).

**DAP: 7 modules, ~1,050 lines; the dispatcher answers 26 DAP commands (15 with
dedicated handlers; `attach`, `evaluate`, `next`/`stepIn`/`stepOut`, `restart`,
`setVariable`, `setExpression` and `dataBreakpointInfo` return the process
backend's explicit "not supported" errors until the lldb-dap bridge).  `tools/dap_smoke.rb`
audits it against the host per request (2026-09-27: capabilities, launch, threads,
stackTrace, scopes, variables, breakpoints and the whole error surface are identical
for the process backend; re-measured 2026-10-03 — request parity holds, while the
terminal *event order* differs (`terminated`→`exited` vs `exited`→`terminated`)
and build-on-launch is missing; the remaining gaps — build-on-launch, the
lldb-dap bridge, the debug map — are §10 of `docs/dap-design.md`).**
**LSP: 40 modules, ~24.6k lines (2026-10-03 count); capability-parity with Ruby; feature parity measured at **5 differing entries** (§0k), all deliberate and documented (the `milkTea/debugInfo` remainder, host parser recovery, the host hanging on a malformed frame, the host's facts lag, and the host's directory-form module `typeDefinition` path, where the self resolves the imported declaration — session 28).  The harness corpus is **66 requests + 19 probes**.  All 30 capability keys match, both semantic-token comparisons are byte-equal, and a real VS Code session runs clean (the 2026-09-26 `codeLens/resolve` double free is fixed, and the harness now drives the resolve endpoints a real client sends).**
**LSP project audit (live counter, 2026-10-03 session 27): `tools/lsp_project_audit.rb --workspace ~/Projects/MilkTea/SimpleGame` — 7075 entries, **4 stable differing entries + the host's first-file `documentSymbol` race**: `completion` **2** (the session-26 close read 4; the two byte-vs-character position entries are closed by the request-boundary conversion — the residue is the host's synthesized `ref` lifetime `mst@224:18` and the host giving up on a `map_error` arm binding `lb@818:17`, both documented), `hover` 1 (the documented `type quat` `lb@1653:24`) and `documentHighlight` 1 (`lb@704:67`, the host's warm-facts snapshot carry-forward); the race entry (`docs/data_structures.mt documentSymbol`) appears only when the host's first-file facts lag (measured in the gates run).  **Every other class 0**, including `diagnostic` (all seven files' diagnostic arrays are byte-identical after the session-18 linter work), `definition`/`declaration`/`typeDefinition`/`implementation`/`references` (915 each, 0), `documentSymbol` and the file-level endpoints.**
**LSP project audit (previous live counter, 2026-10-03 session 26): 7075 entries, **6 differ = `completion` 4 + the 2 documented entries**: completion **4** (235 at the session-24 close; the residue is classified in §0k's part-3 record — the host's synthesized `ref` lifetime, the host giving up on a `map_error` arm binding, and two byte-vs-character positions inside comment lines), `hover` 1 (the documented `type quat` `lb@1653:24`) and `documentHighlight` 1 (`lb@704:67`, the host's warm-facts snapshot carry-forward).**  Earlier live counters: session 18 read 2 differ on the then-6456-entry corpus (the entry count grew with the completion pass), session 13 read 22.
**LSP project audit (live counter, 2026-09-29 session 13): `tools/lsp_project_audit.rb --workspace ~/Projects/MilkTea/SimpleGame` — 6456 entries, **22 differ** (session 13 close): hover 9, documentSymbol 5, semanticTokens 5, diagnostic 2, documentHighlight 1; codeLens, workspace/symbol and definition/declaration/typeDefinition/implementation/**references 0**.  The progression is 1328 (session start) → 332 (sessions 6–9) → 269 (session 10) → 224 (session 11: hover 32 → 14) → 56 (session 12: the definition pipeline) → 37 (session 13: the cross-file definition index — Track C1 — definition/declaration 5 → 0 each, typeDefinition 4 → 0, implementation 1 → 0, hover 13 → 9) → 25 (session 13's second batch: documentHighlight 14 → 2, the host's binding node set) → 22 (session 13's third: codeLens and workspace/symbol 1 → 0 each via the host's token-pair symbol list, documentHighlight 2 → 1, and the token scanner's keyword/heredoc/type-argument rules).  The per-method counters move a few entries between runs because the host's definition index and facts caches warm up as the audit proceeds, so treat each counter as ±10 and compare *sets of differing keys* when verifying a fix.  The hover residue is the analyzer's flow-refinement family (4), stage 11c's payload/destructuring bindings (3), the `fn ` field rendering (1) and a member chain's third segment (1); documentHighlight's single survivor needs the host's carried-forward binding resolution (a label token resolving a binding that is out of scope at that line).  Hover/definition/declaration/typeDefinition are at **0 differing entries** on the probe fixtures (`tmp/probe-ws`, `probe4`–`probe6`, `fieldprobe`, `thisprobe`; `probe2` keeps its 2 deliberate answers), and so are their references; `hover-probe4` closed 6 navigation entries in this session.  Cold start (session 13, `tools/lsp_cold_start.rb`): spawn → the first `workspace/symbol` response fell from 2723.5 ms to **213.3 ms** on SimpleGame and from 2455.1 ms to **2.3 ms** on a one-file project (the index walk is the workspace root now, not every module root).  Residue classified in §0k.**
**LSP recovery (`tools/lsp_recovery_probe.rb --check`, 2026-09-28 session 9): the six-edit corpus of mid-edit states (truncated `n.`/`a.inner.`, unterminated string/block, half-typed `import`, cut-off expression) is at **recovery parity — all six cases byte-equal**, after the parser's panic-based unwinding, the parse/lex location suffix, and the four lint/analyzer knock-ons it exposed (§0k, session 9).**
**Formatting: the CST-backed `:tidy` / `:preserve` modes are self-hosted and byte-identical to the host across the repository (`tools/format_parity.rb`, re-measured 2026-10-03: **705/705 in all three modes**; the file count drifts with tmp fixtures — the canonical printer reattaches comments and trivia like the host); the LSP's `formatting` and `rangeFormatting` entries are closed.**
**Hover: 9 entries left (session 13 close; §0k classifies them — the four
nullability renderings (the analyzer's flow/continuation refinement), the two
destructuring bindings with the match-arm payload (stage 11c), the function-typed
field's `fn ` (the host's `Types::Function#to_s`, the compiler stages'
function-type names item), `type quat`'s cross-file location, and the member
chain's third segment).**
**LSP stability: zero SIGSEGV/SIGABRT crashes; UTF-8 boundary auto-adjust; parser/lexer recoverable.**
**LSP logging: structured stderr, version+revision announcement, a `[LSP perf] req <method> <ms>`
line per request (the host's shape), default level `info`, and `milkTea.lsp.logLevel`
forwarded by the extension as `--log-level`.**
**Diagnostic positions: lexer-based token matching; buffer-overflow warning fix (MAX_ENTRIES 16→128).**
**Code lens: reference counts with deduplication; all index entries queried.**
**References: cross-file via workspace index; definition: local variables supported.**
**Signature help: method calls and extending-block methods resolved.**
**Imported-bindings: 7 modules (incl. registry + methods), ~2,700 lines.  `mtc imported-bindings` CLI command with --all/--check.
Byte-identical raymath output. 3 verified / 25 changed across all 28 bindings (remaining deltas from cosmetic emitter gaps).**

**Remaining CLI gaps: `deps` and `docs` (listed in the ported help text but
not dispatched — the command falls through to the usage block), and
`--bundle`/`--archive`, `--jobs` (none parsed in the self source), Wasm/emcc
(`--platform wasm` parses; `build.mt` ignores it).**  `snapshot` and `debug`
are implemented (§5.8a); the formatter CST modes (`--tidy`, `--preserve`) landed
on 2026-09-26 (§7).
`rake "cli:parity"` (re-measured 2026-10-03) is
**24 match / 37 differ / 0 pending of 61 cases**; the differing cases are
message text/channel/argument-precedence differences, not missing commands
(§0j).  Toolchain doctor is self-hosted; bootstrap/tools subcommands deferred.

**`--sexpr` parity (session-2 snapshot, 2026-09-27; the live numbers are in the Ledger): lex 702/702
comparable byte-identical; parse 698 comparable files byte-identical with 0
differences (4 host-side rejections: external files, platform-pinned); `lower`
39 match / 613 differ / 50 host-rejected / 0 self-rejected** (the host-rejected
bucket is only `external` and platform-pinned files; one file became
byte-identical in session 2 and every family whose first difference was closed
moved 15–63 KB deeper into its dump).  The ref/lifetime and dyn vtable
categories are closed, and so are the three levers §0j ranked first —
**raw-module method linkage naming**, **unsigned literals in the unsigned
domain** (`18446744073709551615`, provenance-tracked so `~0` still prints `-1`)
and **`:path` attribution for statements lowered from AST nodes** (a 19-file
sample went from 138 pathless `return` statements to 0, matching the host), and
**floating-point literals are emitted the way the host spells them**
(`0.2f`, not `0.20000000000000001`; shortest round-trip form plus the `f` suffix
for `float` literals).
**Same-module foreign calls returning a nominal type** no longer lower to
`Types::Error`, and session 2 closed the four ranked items that followed:
**alias-qualified const aggregates** (the `MilkTea/SimpleGame` blocker),
**zero-valued aggregate field/element types**, **`null` contextual typing** and
**`dyn` vtable method-slot substitution**, plus integer literals in local/global
declarations.  The remaining `lower` deltas are dominated by opaque declaration
*fields* (the sdl3 family's first difference), globals initialized from imported
constants, refined nullable operand types, event-field modelling, function-type
names and the proc representation (§0j).  The sdl3 family's *builds* are fixed
(2026-09-27) — the dump-level differences above remain.

Last updated: session 28 close (2026-10-03) — Track 7's **stage-14 leftovers**
landed with harness locks: `prepareCallHierarchy`'s item shape (always kind 12,
`receiver_type: null`), `linkedEditingRange`'s local-binding gate and
empty→null, `inlayHint`'s receiver-aware callee resolution and inferred return
hints (`-> Task[void]`), `executeCommand`'s unknown→null, and the
`typeDefinition` verification (on functions and imported methods already
matching; on directory-form modules the self answers the declaration the
host's path helper cannot reach — the fifth documented harness entry).  Two
extras the new fixture surfaced: `workspace/symbol` now walks the host's
document set (glob-sorted walked files, then warm, then open) and the
immutable-assignment sema message/range match the host.  The harness corpus is
**66 requests + 19 probes**, 30/30 capability keys, 5 documented entries; the
SimpleGame audit stays **4 stable differing entries + the first-file
`documentSymbol` race**.  Session 27 had converted the request boundary's
UTF-16 positions to byte offsets (completion 4 → 2).  Session 26 had taken
completion **235 → 4** (the merge order, the prelude merge, the receiver
families); session 24 had taken it **600 → 366 → 235**.  Session 23 closed
`owning-release-leak` 602/286 → 0/0, `owning-release-double` 0/12 → 0/0 (the CFG
precision analysis) and `prefer-struct-with` 93/0 → 0/0 (the host's gates +
imported-alias resolution), taking the corpus lint to **494 agree / 115 differ**;
`--sexpr` lower on the same tree reads 39/615/51/0 (the session-17 set).
Earlier sessions' records are in §0k (session 22's assignability rule and
`inline_if_too_wide?`; sessions 19–21's corpus work; sessions 15–18's foundational
blockers; sessions 5–14's LSP pipeline ports).  The plan files were consolidated
into this document on 2026-10-03 (session 25); see *Provenance*.

**Audited 2026-10-03 (session 25).**  Re-measured on this tree (sources
unchanged since session 24): completion **235** differing entries (exact),
corpus lint **494 agree / 115 differ** (exact), `cli:parity` **24/37/0**
(exact), `lower` **39/615/51/0** (exact), lex/parse and formatter **0
differences** (705/705 per mode), `test/mt` **60/0**, self-test suite
**591/0** (session 27: **596 tests / 15 files / 0 failed**),
recovery probe **OK**, imported-bindings **3 verified / 25 changed** (exact),
DAP process-backend request parity (the terminal event order and build-on-launch
differ — Track 5).  Corrected in the audit: the "516 tests", "14/16 linter
rules", "37 LSP modules", "29 DAP handlers" and "7 vendored libraries" claims;
the `--timings`, `static_type_method_references` and scoreboard-LSP-row TODO
statuses; and the CLI help-text-vs-dispatch nuances.  Not re-run (the tree is
unchanged since the session-24 green close): the bootstrap fixed point, the
example/sdl3/raylib sweeps, the LSP harness record/compare, valgrind, and the
Neovim/VS Code smokes.

---

## How to start a work session (read this first)

Entry point for any self-host work: **The program** below (the single ranked
remaining-work list, with the approach for each item), then the workstream doc
for the area you are touching:

| Workstream | Read | Verify with |
| --- | --- | --- |
| LSP completion parity (**closed in session 27** — 2 documented entries) | the program's Track 1 + §0k's part-1/2/3 and "The request boundary" records | `tools/lsp_project_audit.rb --workspace DIR` (its member-completion pass); `tmp/hl_probe.rb --method textDocument/completion` (`--warm` first for the host) |
| LSP feature parity / audit residue | the program's LSP track + §0k; `docs/lsp-design.md` (esp. §8 differences), `docs/lsp-performance.md` | `tools/lsp_parity.rb` (`record --server host\|self`, `compare`, `--stress`), `tools/lsp_project_audit.rb --workspace DIR` (per-file, every position, both servers live), plus valgrind and the headless-Neovim smoke for behavior changes |
| Linter corpus residue | the program's linter track + §0k's sessions 19–23 | `ruby tools/lint_parity.rb -q` (609 files; `--host-cache FILE` makes re-runs ~20 s), `rake "parity:scoreboard"` |
| `lower` dump parity | the program's `lower` track, §0j's records, `docs/language-design.md` for semantics | `ruby tools/sexpr_parity.rb lower -j 16` (~3 min; quote the set) |
| Example / vendored-family builds (no known failures since 2026-09-27) | §0j's 2026-09-27 section | the 15 top-level examples, `find examples/sdl3 -name '*.mt'`, a raylib sample |
| CLI behavior parity | the program's CLI track, `tools/cli_parity.rb` (`--help`) | `rake "cli:parity"` |
| Formatter modes (`:tidy`, `:preserve`) | §7, `docs/lsp-design.md` | `ruby tools/format_parity.rb all -j 16` (all modes must stay byte-identical — 705/705, file counts drift) |
| DAP | the program's DAP track, `docs/dap-design.md` (gaps in §10) | `ruby tools/dap_smoke.rb [--server host\|self\|both] [--json OUT]` — runs a session on both adapters and prints a per-request diff |
| Bootstrap / release | `docs/bootstrap-design.md` | `tools/bootstrap.sh -j 16` |
| In-language test suite | `docs/testing.md` | `build/stage2/mtc test test/mt -I .` |

**Start by checking what your task can move, not by replaying the matrix.**  The
**Ledger** below holds the last verified numbers per gate; a session only
re-measures the classes its change touches, and only when the tree moved (or a
number looks surprising).  Iterate on the dev compiler
(`ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev`, ~50 s;
`tmp/mtc-dev test projects/mtc -I .`) with a *focused* meter — a single file's
host-vs-self lint/check diff, `tmp/diag_probe.rb`, `ruby tools/lint_parity.rb -q
<paths>`, `ruby tools/sexpr_parity.rb lex|parse -q` — and save the wide sweeps
for the commit.

**Once per commit, on frozen sources**, run the tier-2 proofs: `tools/bootstrap.sh
-j 16` (fixed point + compiler self-test — several changes that looked correct at
the CLI level broke the compiler's own bootstrap) plus the sweep that covers the
area.  `tools/gates.sh` picks the set for you:

```sh
tools/gates.sh                 # list the gates for the working-tree diff
tools/gates.sh --areas linter  # or name the areas
tools/gates.sh --run           # execute them (logs under tmp/gates/)
```

**Never edit sources while a gate runs** — `bootstrap.sh` compiles the working
tree, so a mid-run edit silently corrupts the result.  Check the exit status, not
just the tail.

One command for every counter: `rake "parity:scoreboard"` (cheap sections:
cli/lex/parse/lint; add `FULL=1` for lower/format/LSP/DAP).

**HARD RULES (all learned the expensive way):** rebuild before measuring (a stale
`build/stage2/mtc` is the classic false result; `bootstrap.sh` rewrites
`version_info.mt`, which makes `sexpr_parity`'s staleness warning fire
harmlessly); quote *sets* where a counter drifts (sexpr's file count with the
tmp fixtures, the audit's ±10 between runs); run generated binaries as
`timeout 10 bash -c 'ulimit -v 20000000; …'`; no hacks — fix root causes; sync
this file's records + ledger in the same commit as the code change.

### Phase order and current position

0. **Hard build parity** — **complete (2026-09-27)**: the self-host builds every
   example and test the host builds (15/15 language examples, 34/34 `examples/sdl3`,
   a 40-file raylib sample, `test/mt` 60/60 with 0 failures).  Six root causes are
   recorded in §0j's 2026-09-27 section; regressions should show up as a build
   failure in those sweeps.
1. **`lower` dump parity** — session-17 measurement: **39 match / 615 differ /
   51 host-rejected / 0 self-rejected** (the count drifts with the tmp fixtures;
   quote the set).  The ranked items are the program's `lower` track; the biggest
   single mover is item 1 (opaque declaration naming/`forward_declarable`, the
   first difference for all 34 sdl3 files).
2. **CLI behavior parity** — **24 match / 37 differ / 0 pending** of 61 harness
   cases (session 22); the differ on message text, output channel and argument
   precedence.  The unported subsystems are the program's CLI track.
3. **LSP feature parity** — **the active phase**.  The harness is at 30/30
   capability keys + its 4 documented differing entries; the project audit is at
   **4 stable differing entries + the host's first-file `documentSymbol` race**
   after session 27 (completion **2**: the host's synthesized `ref` lifetime and
   the host giving up on a `map_error` arm binding — the two byte-vs-character
   position entries closed with the request-boundary conversion; hover
   `type quat`; documentHighlight `lb@704:67`).  The completion class's
   *unintended* entries are now 0; the open work is the readiness residue
   (F9/C2–C6/D2–D4), then the optional `ref`-lifetime modeling.  Recovery parity
   holds, the stress corpus runs without a crash or hang, and a real VS Code
   session runs clean under valgrind.
4. **DAP** — phase 1 (process backend; 26 commands, 15 dedicated handlers) delivered; the lldb-dap
   bridge is now feasible (`std/libuv.mt` poll + `std/async`) but unstarted
   (`dap-design.md` §10).  The self's `*launch(.mt)` reports `error: Milk Tea
   binary not found: src/main` where the host is `ok` — build-on-launch is the
   first DAP item (program track 5).

### Session kickoff prompt (copy-paste template)

```
Continue the Milk Tea self-host work in /home/teefan/Projects/Ruby/mt-lang
    (branch `selfhost`). Work in tiers: iterate on the dev compiler
    (ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev, ~50 s;
    tmp/mtc-dev test projects/mtc -I . --timeout 120), measure only the class you
    touch, and run the tier-2 proofs once on frozen sources — `tools/gates.sh`
    prints the set (or `--run` executes it, logs in tmp/gates/).  Do not replay
    the ledger's verified baselines unless the tree moved.

    Read first: this file's "How to start a work session", "The program" (pick
    the next ranked item), the Ledger, and the latest §0k records.

    STEP 1 — one item per commit from the program's ranked list; each commit ends
    with the gate set and this file's records + ledger synced in the same commit;
    commit trailer: Co-authored-by: CommandCodeBot <noreply@commandcode.ai>.

    HARD RULES: never edit sources while a gate runs (bootstrap compiles the
    working tree — check the exit status, not the tail); rebuild before
    measuring; quote *sets* where a counter drifts; run generated binaries as
    `timeout 10 bash -c 'ulimit -v 20000000; …'`; no hacks — fix root causes.
```

## The program — ranked remaining work

**Goal.** Close every remaining self-host gap so `build/stage2/mtc` matches the
Ruby host (`ruby -Ilib bin/mtc`) on observable behavior everywhere — `--sexpr`
dumps, CLI messages/commands, LSP, DAP, linter, formatter, imported bindings,
bindgen — while keeping the self-host's existing deliberate improvements
(malformed-frame recovery, synchronous facts with no lag, speed, determinism).
"Parity" means byte-identical where a harness can compare; "better" means
documented deliberate extensions only.

**Confirmed scope decisions (2026-09-27).** (1) **All** unported CLI subsystems
are in scope: `deps`, `docs`, wasm/emcc + preview, `--bundle`/`--archive`,
`--jobs`, `toolchain bootstrap/tools`, `--kind static|shared`, the bindgen policy
flags — sequenced after the parity-critical tracks.  (2) Ordering: finish the LSP
workstreams first (the completion class, then the readiness residue), then
`lower`, CLI, DAP, bindings/bindgen, and the final verification — pick by user
value where the tracks are independent.  (3) The lldb-dap bridge is included (the
VS Code extension's default backend).

Line references are from the session that wrote the note; re-grep the symbol if a
line misses — the symbol names are the stable anchors.

### Definition of done (per track)

- **`lower`**: 0 differing files in `sexpr_parity lower` (residuals only if
  proven host artifacts, each documented); lex/parse stay 0-diff; no build
  regressions anywhere.
- **CLI**: every host command/flag exists with equivalent behavior;
  `cli:parity` all-match; `deps`/`docs`/wasm/bundle/jobs/toolchain functional.
- **LSP**: harness at 0 unintended entries (only the documented rows); the
  audit's completion class closed (0 unintended); `milkTea/debugInfo` byte-equal
  after object-id normalization; `[LSP perf]` ≤ ~10 ms per edit after the
  per-module cache; valgrind clean.
- **Linter**: per-rule counts/messages/severities/positions equal the host on
  `language_baseline.mt`, `memory_stress_test.mt` **and** the 609-file corpus
  sweep.
- **DAP**: a real VS Code session debugs a `.mt` program end-to-end with the
  default `lldb-dap` backend (breakpoints, stepping, evaluate; frames/locals
  shown as Milk Tea names via the debug map); process backend unchanged;
  `dap_smoke` green on both.
- **Bindings/bindgen**: `mtc imported-bindings --all --check` 28/28 verified (or
  each residual delta justified as cosmetic with evidence); bindgen output
  reproducible for the repo's bindings.
- **Formatter**: all modes byte-identical (705/705 at the 2026-10-03 audit; the
  count drifts with tmp fixtures).

### Track 1 — LSP completion parity (2 documented entries left; parts 1–3 landed and the position residue closed)

Session 24 added the audit's member-completion pass (**600 of 619** entries
differing) and took the class to **235** in two batches; session 26 ported the
registration order, the prelude merge and the receiver families to **4**;
session 27 converted the request boundary's positions (`mst@10:52`,
`mst@11:21`) and the class reads **2**, both documented differences.  The
unintended entries are 0.  Remaining residue, ranked (each classified in §0k's
part-3 record and the session-27 record):

| Entries | Position | Approach |
| --- | --- | --- |
| 1 | `mst@224:18` | the host renders a synthesized `ref` lifetime (`ref[@_mt_0, ubyte]`; the self renders the declared `ref[ubyte]`).  **Documented (session 27): the host leaks its internal auto-lifetime name into user-facing details; the self shows the declared type.**  Modeling it means the host's `type_declaration.rb:516-522` auto-lifetime rewrite in the self's field resolution, with rendering/lowering knock-ons — a separate work item if pursued |
| 1 | `lb@818:17` | the host's facts fail to type the `map_error` result's arm binding (method fallback where the self answers the field) — the documented "self answers where the host gives up" family; keep documented |

Tools: the audit's `member_completion_positions` pass, `tmp/comp_diff2.rb`
(per-entry receiver context + label-set / field / order grouping),
`tmp/hl_probe.rb --method textDocument/completion` — `--warm` sends a diagnostic
first (the host answers completion only once its facts exist) and the two
servers should be probed in separate runs.  Records: §0k, "Completion parity,
parts 1–3" and "The request boundary".

### Track 2 — Linter corpus residue

`tools/lint_parity.rb -q` over `std examples projects/mtc/src`: 609 files,
**494 agree / 115 differ** (session 23 close; re-measured 2026-10-03; from
357/252 in session 19).
Closed so far: `redundant-unsafe` 807 → 0, `owning-release-leak` 602/286 → 0/0,
`owning-release-double` 0/12 → 0/0, `prefer-inline-if` 213 → 0,
`prefer-struct-with` 93/0 → 0/0, `prefer-conditional-expression` 25 → 0.
Remaining ranked deltas (self-extra / host-only; re-measured 2026-10-03):
`redundant-cast` 74/22, `prefer-try` 64/39, `prefer-let` 51/142,
`borrow-and-mutate` 28/0, `shadow` 20/0, `prefer-own-ptr` 16/45,
`constant-condition` 11/1, `prefer-or-pattern` 10/4, `loop-single-iteration`
8/2, `unreachable-code` 3/0, `prefer-var-else` 2/0.  All
differences are pre-existing (the pre-change binary's output is identical on
them); quote *sets*, not just counts.  Tool: `tools/lint_parity.rb` with
`--host-cache FILE` (warm fill ~4 min, then ~20 s per full run).

Also open from the analyzer track (they gate audit entries and lint rows):

- **The session-22 residual assignability pair**: (a) a bare `null` into a
  non-nullable target (`return null` for a `ptr[int]`/`str`; `ty_null` is
  kind-unknown in `definitely_incompatible` and `types_compatible` has no null
  arm) and (b) generic-vs-scalar pairs (`ptr[int]` → `str`; tightening needs the
  host's positive `call_argument_compatible?`/
  `implicit_ref_argument_compatible?` split so the `ref[T]` call-site borrow
  keeps working).  Also measured: assigning to an immutable parameter is
  unflagged (the immutable check tracks only `let` bindings).
- **Constant-value coercion** (session 23): a constant whose folded value fits a
  narrow integer target is host-accepted and self-rejected (`return
  sdl.ALPHA_OPAQUE` from `-> ubyte`, `let x: ubyte = sdl.ALPHA_OPAQUE`, the same
  in a field/argument).  The host folds (`constant_value_for`); the self's
  `is_numeric_literal_valued_expr` sees only literal nodes/`if`-chains.  Evidence
  `tmp/probe-const-narrow.mt`.

Records: §0k sessions 19–23.

### Track 3 — Compiler `lower` dump parity

Work in §0j's ranked order; after **each** item re-run
`ruby tools/sexpr_parity.rb lower -q -j 16` and re-rank.  Current set:
**39 match / 615 differ / 51 host-rejected / 0 self-rejected** (session 17; the
file count drifts with the tmp fixtures — quote the set).

1. **Opaque declarations** (`IR::OpaqueDecl` item 1; the first difference for all
   34 sdl3 files; dump-only, builds fixed).  `lowering.mt:1473
   collect_opaque_decls` (wired `:590`) must keep the *declared* name, compute
   `linkage_name` from the resolved backing type and `forward_declarable` per the
   host rule (`core/lowering/utils.rb:1059-1069`, `declarations.rb:182-194`);
   `c_backend.mt:7367 emit_opaque_typedefs` (`:253`) becomes the host's
   `emit_forward_declarations` (`c_backend/type_declaration.rb:19`): `typedef
   struct <linkage> <linkage>;` for forward-declarable entries, deduped by
   linkage; the `c_type` opaque arm (`c_backend.mt:2080-2088`) keeps using the
   backing name.  Re-verify opaque-as-pointer
   (`projects/mtc/test/c_backend_test.mt:385`) and the sdl3 sweep.
2. **A global initialized from an imported constant** (item 13; `box3d/ragdoll` +
   `box_stack`'s first difference).  In the `decl_var` arm
   (`lowering.mt:1247-1276`) try `try_const_typed_value_ir` (`:18553`) /
   `try_const_value_ir` (`:18024`) before `lower_expr`, mirroring the host's
   `lower_static_storage_initializer` + `rewrite_static_storage_initializer`
   (`lowering/utils.rb:335-419`, `declarations.rb:166-174`).  Add a lowering test
   for a global initialized from an imported const.
3. **Refined (non-null) operand types after a null check** (item 14;
   `data_structures` + `reflection_advanced`'s first difference).  **Verify
   first** — F2's continuation refinement (session 15) may already have closed
   this dump difference; if not, port the refined-type recording into
   `expr_type` for guarded uses (`analyzer.mt`'s `flow_types` record is the base).
4. **Event fields** (item 4; `event_stress_test`).  `lower_struct_decl`
   (`lowering.mt:13974`, rewrite `:13987-13991`, push `:14002`) must emit
   `IR::Field(name = "__event_<name>", ty = <ty_event>)` (host
   `declarations.rb:239`, `Types::Event#hidden_field_name` `types.rb:775`);
   adjust the analyzer's `FieldEntry` (`analyzer.mt:1062`) if the field name is
   sourced there.
5. **Function-type names** (item 6) — **DONE (session 16, F5, `6ad423ce`)**:
   `ty_function` carries the callee's name, `type_to_string` renders `fn <name>`
   and `sexpr.mt` emits it.  Keep as a regression watch only.
6. **Include set** (item 7; `box2d/drop`).  `collect_includes`
   (`lowering.mt:1705`) iterates canonical post-order; the host iterates its
   analysis cache and its directives come from the raw-bindings registry
   (`lowering/scans.rb:45`, `module_loader.rb:233`,
   `bindings/raw_bindings/defaults.rb` — raymath `:742`, math `:871`).  Add each
   library's include directives to `imported_bindings/registry.mt` (or a
   parallel raw-bindings table), drive `collect_includes` and
   `build.mt:253 collect_binding_flags` from it, and pin the emitted order to
   the host's.
7. **Item 8 sub-items.**  (a) *Declaration ordering* (`ClockSync` vs
   `std_net_recv_impl_frame`): diff the host's seed list
   (`c_backend.rb:191-196`) against `topo_sort_types`' node construction
   (`c_backend.mt:3584-3645`).  (b) *Enum-member + const folding shape*
   (`errno_test.mt`): extend `imported_const_value_ir` (`lowering.mt:18705`) /
   `try_const_member_ir` (`:18737`) to resolve `alias.EnumType.MEMBER` to its
   integer (host `resolve_type_member_const_value` +
   `resolve_imported_module_const_value`, `resolve.rb:1515-1599`).
   (c) *Variant-match goto* residual (1 file): diff `lower_variant_match_goto`
   (`:15556`) arm-by-arm against `block.rb:936-1079`.
8. **Proc representation** (item 15, §0i roadmap item 2 — the largest single
   item), staged A→D.  Self-host today: type refs and literals materialize as
   `ty_named(mt_proc_*)` structs (`lowering.mt:4344-4366, 13111-13196`); the
   analyzer already carries `ty_function(is_proc)` and `sexpr.mt:545-559`
   renders it.  Two doc corrections: the host has **no** `__setup_env` function
   (it inlines env setup, `lowering/block.rb:106-153`) — the separate one is
   self-host-only (`lowering.mt:6013, 6097-6159`); the host allocates envs with
   `mt_async_alloc/free` (`block.rb:123`, `proc.rb:82`) vs raw `malloc/free`
   (`lowering.mt:6123, 6264`).
   - **A (dump-visible, low risk):** keep runtime helpers and
     env/invoke/release/retain names; make the lowering carry
     `ty_function(is_proc=true)` as the proc value type (as the analyzer does)
     and have the C backend synthesize the `mt_proc_*` typedef from the type
     (host `c_backend/type_collectors.rb:468-729`, `type_system.rb:214`).
     `is_proc_type` accepts both forms during migration.
   - **B:** align the C struct name to the host's `mt_proc_proc_<ret>_<params>`
     (`c_naming.mt:95`, `proc_type_name_from_signature`).
   - **C:** IR shape — inline env setup and switch to `mt_async_alloc/free`.
   - **D (highest risk):** port the contained-proc retain/release lifecycle
     (`lowering/proc.rb:276-362`: local decls, struct fields, async frames; the
     self-host has none today).  Verify against the host's lifecycle cases
     (`test/compiler/c/basic_2_test.rb:1819-1965, 2639-2722`) and the fixed
     point — the compiler's own sources use procs heavily (~29 files).
9. **§0i residue sweep** (visible beyond each file's first difference; lowest
   priority, 2–3 per commit, driven by per-file diffs): `let…else` guard temp
   naming (`__mt_guard_N` vs the binding's name), nested struct C names
   (`<Parent>_<Child>`, union `<Variant>_data`), generic-instance ordering,
   parallel-for/detach naming (`mt_pfor_cap_*`/`mt_pfor_work_*`/
   `mt_spawn_work_*`), for-loop `__mt_for_stop_N` hoisting, integer-promotion
   casts in bit ops.
10. **Tail loop:** repeat {re-run sweep → take the largest remaining category →
    fix → regression test} until `lower` is 0 differ.  Every C-side change also
    gets the §2.5-style formatting-independent check (external symbol sets,
    array lengths); proc work additionally gets an alloc/free balance check.

Gates per item: bootstrap + `test/mt` + `sexpr_parity` lex/parse/lower +
examples 15/15, sdl3 34/34, a raylib sample; new tests in
`projects/mtc/test/lowering_test.mt` / `c_backend_test.mt` / `semantic_test.mt`.

### Track 4 — CLI parity (messages, then commands, then subsystems)

1. **Message/channel/precedence parity** — enumerate the 37 differing cases with
   `ruby tools/cli_parity.rb --max-diffs 37` (add `--keep` to dump per-case
   `host/self.{out,err,rc}` under `tmp/cli-parity/cases/`); fix each to
   byte-equal (examples: `std show` prints to stdout instead of stderr;
   `build --bogus` reports "accepts a single source path" instead of "unknown
   build option").  Exit: 61/61 on the current corpus.
2. **Cheap flags/subcommands**: `test --jobs N` (the ported help advertises it;
   nothing parses it today) and `--cc/--profile/--platform` for `test` (port
   the host's fork-per-file, order-preserving parallel runner,
   `cli/commands/test.rb:281-335`; `build` already honors `--cc`);
   `build --kind static|shared` (`tooling/build.rb` kind handling);
   `toolchain bootstrap`/`toolchain tools` (`toolchain_cli.rb:68-205`; only
   `doctor` is dispatched today); `bindgen
   --nullable-policy/--nullable-report/--clang-arg` (advertised in the help,
   not parsed).
3. **`--bundle`/`--archive`** (host `build.rb:143-164, 459-464, 962-1032`;
   `asset_pack.rb` MTAP).  `std/tar.mt` and `std/gzip.mt` already exist —
   implement the archive in-language.  Verify: `tar tzf` lists it, extraction
   runs the program, and each host consumes the other's archive.
4. **Wasm/emcc + preview** — `build.mt` currently ignores `Platform.wasm`.  Port
   `compile_wasm` + shell rendering (`build.rb:26-69, 704-779, 900-937,
   953-960`, `templates/wasm_shell.html`), `--preload-file` for `build.assets`,
   `.html` output, and the `run --platform wasm` preview server
   (`run.rb:11-207`) on `std/http/server.mt`.  Detect `$EMCC`/`emcc` in
   `toolchain doctor`; if emcc is absent, reproduce the host's error text.
   Verify with emcc installed and byte-compare the emitted HTML shell.
5. **`docs`** — port `cli/commands/docs.rb` + `tooling/docs_app.rb` (Sinatra)
   routes (`/`, `/reference`, `/stdlib`, `/stdlib/:name`, `/api/search`) onto
   `std/http/server.mt`, reusing the repo's `docs/` assets and `snapshot.js`
   verbatim; `--port/-p`, `--open/-o`, the host's
   `Serving Milk Tea docs at <url>` line.  Acceptance: functional parity (same
   routes/URLs/content), not byte-identical HTML.  (The ported help already
   lists `docs` and its options; nothing is dispatched today.)
6. **`deps` (largest subsystem, ~3,000 lines + 485-line CLI)** — port
   `lib/milk_tea/packages/*` (manifest, manifest_editor, lock, graph,
   dependency_solver, source_resolver, source_fetcher, source_cache,
   registry_store, registry_metadata_provider, version, atomic_write, services)
   into `projects/mtc/src/mtc/packages/*.mt` +
   `deps add|remove|update|tree|lock|publish|fetch`; extend
   `loader/package_manifest.mt` (currently `source_root` only) into the full
   manifest/graph, then wire `--locked`/`--frozen` and package-graph resolution
   into `build`/`run`/`check` (the host's `PackageGraph.load` path).  Network via
   `std/http`.  Verify against the host's package fixtures (adapt
   `test/packages/*` into MT tests) and a local-registry probe.  (The ported
   help lists `deps` and its subcommands; the dispatcher has no `deps` branch.)
7. **Harness**: add `cli_parity.rb` cases for every command/flag above and
   delete the matching `KNOWN_GAPS` entries as they land; exit: all cases match.

### Track 5 — DAP (debug map → build-on-launch → pause/modules → lldb-dap bridge)

1. **Debug map (prerequisite).**  New `dap/debug_map.mt`: walk
   `ir.Program.functions` (`ir.mt:191-226`) collecting params and `stmt_local`
   locals (`:110`) with line/`source_path`, serialize the host's shape
   (`{version, functions:[{name,cName,params,locals,sourcePath,line}],
   binaryPath, programSourcePath}` — `tooling/debug_map.rb:9-50,130-196`) and
   write `<output>.mtdbg.json` from `build.mt` after a successful link
   (`build.mt:97-158`).  Add the loader + frame/variable/expression rewriters of
   `dap/server/debug_map.rb:45-225`.
2. **Build-on-launch.**  Rewrite `dap/utilities.mt`'s `resolve_launch_program`
   (`:17-41` — today it only accepts a pre-built binary and errors `Milk Tea
   binary not found: <path> (build with mtc build first)` on a `.mt` source):
   for a `.mt` source, spawn the running compiler (`/proc/self/exe`) as
   `mtc build <program> -o <tmp>/<name> --profile debug`, track temp dirs for
   cleanup, return the runnable path and load its debug map (host
   `dap/server/launch.rb:120-153`).
3. **Pause diagnostics + `modules`.**  Dispatch `modules` in
   `handlers.mt:27-93` and load the map from the backend's response (host
   `debug_map.rb:13-36`); make `handle_pause` emit the host's console `output`
   event built from a `stackTrace` (`pause_diagnostics.rb:7-53`).
4. **lldb-dap bridge (largest/riskiest).**  New `dap/lldb_backend.mt` + an
   fd-parameterized `protocol.mt` (readers/writers are stdio-only today,
   `:32-223`) + a `server.mt` loop that runs a libuv poll loop when
   `--backend=lldb-dap` (`std/libuv.mt poll_init/start :354-357`, `std/async`,
   the pattern in `std/tls.mt:242-299`).  Single-threaded state machine: pending
   table for client→adapter responses, reverse adapter→client requests with
   their own pending table + timeout and capability merging, adapter
   `initialized` suppressed, stderr drained, `--adapter-path` parsed (the
   extension sends it), shutdown ordering.  Reference:
   `dap/lldb_dap_backend.rb` (153 lines) + `dap/server/lldb_backend.rb:7-213,349-361`.
5. **Verification.**  Extend `tools/dap_smoke.rb`: per-server `--backend`,
   build the smoke program with *each* server (so the self emits the map), and
   add the lldb section (breakpoint → `stopped` → `stackTrace` shows Milk Tea
   names → scopes/variables → `evaluate`/`next`/`stepIn`/`stepOut`/`continue` →
   `modules` → pause console output).  Finish with a real xvfb VS Code session
   on the default backend.
6. **Terminal event order (measured 2026-10-03).**  The process backend's final
   events differ: the host emits `terminated` then `exited`, the self `exited`
   then `terminated` (`tmp/dap-s25.json`, the `events` row).  Align the order.

### Track 6 — Imported bindings and bindgen

1. **OpenGL naming transforms** — port the six tables + seven functions
   (`bindings/imported_bindings/naming.rb:7-280`) into
   `imported_bindings/naming.mt`; wire the call sites (host
   `generator.rb:707,875`) and add the missing `snake_case` trailing
   normalization (`naming.rb:259`).
2. **28-binding verification** — make `mtc imported-bindings --all --check` emit
   a machine-readable report and add `tools/imported_bindings_parity.rb` that
   prints the per-binding delta categories (baseline 3 verified / 25 changed,
   cosmetic emitter gaps).  Close them to 28/28 (the named raylib Quaternion
   member-ordering delta included) or justify any residual byte-for-byte.
3. **Bindgen gaps (§6.7)** — header-provenance filter in `walk`
   (`bindgen.mt:346-445`; host `ast_parser.rb:105-132`,
   `allowed_declaration_name?`), unknown-type policy instead of echoing bare
   names (`bindgen.mt:259`; host `type_mapper.rb:62` + `declaration.rb:123`),
   nested `const char*` → `cstr` in the pointer branch (`bindgen.mt:169-190`;
   host `type_mapper.rb:21-22,528-532`), and the typedef record/enum alias maps
   (`bindgen.mt:730-737`; host `ast_parser.rb:159-176`,
   `synthesize_typedef_dependency:326-337`).  Verify by regenerating the repo's
   `std/c/*.mt` and diffing against the checked-in files (and the host's output).

### Track 7 — LSP readiness and residue

- **F9 readiness foundations (C2/C3).**  `ScanFacts` is never released (session 14
  extended it with the binding vector and the type-parameter scopes); the
  reference index keeps an owned copy of every noted document's text (C2);
  `note_document_tokens` re-reads and re-hashes per request (C3).  Bound both and
  cache by (mtime, size)/content hash; verify with a long-session soak and
  valgrind (~12.7 MB "definitely lost" over the session-19 harness drive, 0
  memory errors).
- **C4 large files/workspaces.**  Add a soak target (≥5k lines, ≥10k requests,
  mixed methods, timeouts + valgrind + RSS ceiling) to the gates.
- **C5 client behaviours.**  workspace folders, `didChangeConfiguration`, watched
  files, `includeDeclaration: false`, cancellation, closed-file edits —
  cross-check against the host and add harness cases for any that differ.
- **C6 deliberate differences, one table.**  Keep and document: malformed-frame
  recovery, synchronous facts (no lag), faster cold start, the recovery-adjacent
  differences Track A left, the host's first-file `documentSymbol` race, the
  `documentHighlight` snapshot carry-forward and the `type quat` asynchronous
  location (`docs/lsp-design.md` §8 is the canonical table).
- **D2.**  `tools/lsp_project_audit.rb --canonical` (or a documented
  substitute) to pin the request history so the ±10 drift disappears.  **D3 is
  done**: `tools/parity_scoreboard.rb` has an `lsp` section (`--full`).  D4:
  keep the standing gates exactly as this file's protocol and AGENTS.md list
  them.
- **Stage-plan residue (absorbed; verify each against §0k before starting):**
  - **per-module `ModuleCache`** (edit-latency foundation; closes the
    re-parse/re-analyze of the whole import closure on each content version —
    the remaining 39 ms → target ≤ ~10 ms/edit on `SimpleGame/src/main.mt`).
    Design: `lsp.Workspace`-owned cache keyed by resolved path →
    `{content_hash, owned source, the SAME AST instance (resolved_expr_types is
    pointer-keyed), analysis, ModuleBinding, lex/parse diagnostics, direct-import
    versions}`; `module_loader.check_program_with_source` consults it,
    `parse_all` skips unmodified modules, `check_and_bind_module` reuses when the
    module's hash and every direct import's version are unchanged;
    `lsp/semantic_tokens.mt`'s `register_resolved_import`/`build_scan_facts` read
    the alias surface from it.  Verify with the dependency-edit probe
    (edit `std/vec.mt` → a dependent's diagnostics refresh) and valgrind.
  - **`reserved-primitive-name --fix` use-site renaming** (stage 8): a
    declaration-token edit exists (`reserved_primitive_name_edit`: the
    `<name>_value` rename fires once at the declaration), but the host's
    multi-site rewrite (every identifier use + the collision resolution
    `resolve_reserved_primitive_name_conflicts!`) is missing, as are
    `column`/`length`/`symbol_name` on the warning; byte parity vs the host
    `--fix` is the gate.
  - **`prefer-inline-methods` auto-fix** (stage 10): port
    `prefer_inline_methods_edits`, add to `fixable_codes()` — `--fix`,
    `source.fixAll` and the quickfix all see it (host
    `fix_engine.rb:161-…`, title "Inline methods into struct").
  - **Stage-14 leftovers — DONE (session 28).**  The five items landed with
    harness locks (`tools/lsp_parity.rb` now carries `prepareCallHierarchy/
    method`, `typeDefinition/function|imported|std-member|imported-method`,
    `definition/imported-member`, `linkedEditingRange/type|function`,
    `executeCommand/unknown` and the `inlay.mt` fixture): `call_hierarchy`'s
    prepare emits the host's always-kind-12 / `receiver_type: null` item
    (`build_call_hierarchy_item`'s `respond_to?(:receiver_type)` is false on
    the facts' bindings); `linked_editing_range` applies the host's
    local-binding gate and answers `null` for empty ranges
    (`linked_editing_range.rb:7-25`, `rename.rb:302-326`); `inlay_hints` gained
    the receiver-aware callee resolution (a value's type, a bare type name or
    an imported type, then the merged method table) and
    `collect_inferred_return_hints` (the reachable non-void case is the async
    wrapper, `-> Task[void]`); `executeCommand`'s unknown command answers
    `null`.  `typeDefinition` on a function or an imported method already
    resolved; on a *directory-form* module member (`mod_alpha/lib.mt`) the
    host's `module_path_for_name` gives up where the loader-backed self
    answers the declaration — the harness's fifth documented entry.
    Two extras found on the way: the `workspace/symbol` document set now
    matches the host's `@indexed_documents.keys + @open_documents.keys` (the
    walked files in `Dir.glob(**/*.mt).sort` order, then the on-demand and open
    ones), and the immutable-assignment sema error carries the host's message
    (`cannot assign to immutable <name>`) and its name-length range.
    (The module-symbol wrapper landed in session 14;
    `static_type_method_references`/stage 15 landed in session 8, `c15594c3` —
    do not redo either.)
  - **`--timings` breakdowns** (stage 18; partially landed `298481ee`,
    2026-09-23).  The flag and a total line exist for `format` and `lint`
    (`print_timings_line`: `format profile <path>: Xms`), but the host's shapes
    are missing: format's per-phase
    `(format: …, format.parse: …, format.lex: …)` and lint's
    `rules=… total=…` + per-rule lines (`formatter.rb:37-59`,
    `cli/commands/format.rb:173-196`).
  - **Quickfix extras** (stage 16): `Cast expression to <type>` for
    `cannot assign …` (parenthesize non-simple values, wrap in `unsafe:` if
    required); `Import <module>` for unknown-name/type diagnostics
    (`code_actions.rb:38-55, 265-285`); titles byte-equal.
  - **`milkTea/debugInfo` byte-parity** (stage 17, highest-risk; partial today —
    the matrix's 4 documented entries include its remainder).  The absorbed
    sub-steps: section order/envelope (Header, Tokens, AST, Parse Errors, Facts,
    Bindings, Diagnostics; drop the self-only `Workspace` section); the
    histogram tie order (port `ruby_qsort` for that exact sort); the AST section
    (`format_ast`/`compact_ast_repr` + the host's node-id semantics
    (`core/ast.rb:316-356`)); the Facts section (`format_facts` shapes); the
    Bindings section (binding-id allocation in the host's order +
    `binding_types`, the 30-entry cap); the Diagnostics section; and the
    harness `normalize` extension for Ruby `object_id` values.
  - **The linter's `:fast`/`:full` tier flag** (stage 11's first half):
    `LintOptions.lint_tier` with the host's `full_tier?` gating; the CLI and
    LSP pass `:full` like the host CLI, and diagnostics *scheduling* stays out
    of scope.  Verify the current state first (§7.3 lists it as open).
- **The documented entries stay documented** unless their machinery is built for
  another reason: the harness's 5 (debugInfo remainder, host parser recovery,
  host hang on a malformed frame, host facts lag, and — session 28 — the host's
  directory-form module `typeDefinition` path, where the self answers the
  imported declaration the host's `module_path_for_name` cannot reach) and the
  audit's 4 — the two pre-existing ones (`documentHighlight` `lb@704:67` — the
  host's warm snapshot carry-forward, byte-equal cold; `hover` `type quat`
  `lb@1653:24` — the host's asynchronous index warm; an eager fix adds 153
  entries, measured and rejected in session 18) and the two completion residues
  classified in session 27 (`mst@224:18` — the host's synthesized
  `ref[@_mt_N, T]` lifetime in a field detail, where the self renders the
  declared `ref[T]`; `lb@818:17` — the `map_error` arm binding the host's facts
  never type, where the self answers the field and the host falls back to its
  method table).
- **First-file `documentSymbol` race** (±drift, documented): the host's first
  `documentSymbol` answer after `didOpen` can carry its pre-facts tree; the
  gates' audit run read `docs/data_structures.mt documentSymbol` differing,
  the standalone run read 0.  Keep as a drift entry, not a work item.

### Track 8 — Final verification

- Clean-tree run of the full matrix: `tools/bootstrap.sh -j 16` (stage2 ==
  stage3, 14/14 tests), `build/stage2/mtc test test/mt -I .` (60/60), 15/15
  examples, 34/34 sdl3, 217/219 raylib, vendored families, `sexpr_parity`
  lex/parse/lower, `cli:parity`, both LSP harnesses + valgrind + a Neovim and a
  VS Code session, `dap_smoke` on both backends, `format_parity all`,
  `imported-bindings --all --check`, the lint corpus, and
  `~/Projects/MilkTea/SimpleGame` building and running.
- Update this file's header, records and ledger; `docs/lsp-design.md`,
  `docs/dap-design.md` as their areas change.
- Declare done only when the Ledger shows every counter at its target.

### Risks and notes

- **`lower` tail**: every fix moves files' first differences deeper and can
  expose new categories; the ranked order + sweep loop is the process.  Treat "0
  differ, or a documented host artifact with a reproduction" as the stopping
  rule.
- **Proc stage D** changes runtime lifecycle semantics and must not break the
  fixed point (the compiler bootstraps itself with procs).  Land A–C first.
- **DAP bridge** is the highest-risk single item (single-threaded correlation of
  two directions); it lands last in its track with the debug map and
  pause/modules already in place, so each step is independently smoke-testable.
- **`deps`** is the largest subsystem; keep the port mechanical (module-per-file
  mirroring the Ruby layout) and lean on the host's tests as the spec.
- **emcc** may not be installed on this machine; reproduce the host's
  detection/error behavior and verify the wasm path where emcc is available.
- Deliberate "better than host" behaviors stay (malformed-frame `-32700` + keep
  serving, synchronous facts with no lag, faster cold start, deterministic
  binding-map iteration); parity work must not regress them.

## Ledger and scoreboard

Newest verified numbers (session 24 close, 2026-10-02) — re-measure only the
classes a change can move, and only when the tree moved.  Target = the
definition of done above.

| Gate | Live | Target | Command |
| --- | --- | --- | --- |
| bootstrap fixed point | holds (2026-10-03 session 27 — `stage2.c == stage3.c`); self-test suite 15 files / **596 tests** / 0 failed | stay green | `tools/bootstrap.sh -j 16` |
| `test/mt` | 60 files / 0 failed (re-run 2026-10-03) | stay green | `build/stage2/mtc test test/mt -I .` |
| examples / sdl3 / raylib | 15/15, 34/34, 217/219 | stay green | per-family sweeps |
| `sexpr lex` / `parse` | 705/705; 702 comparable / 0 differ (re-measured 2026-10-03; file counts drift) | stay 0-diff | `ruby tools/sexpr_parity.rb lex\|parse -q` |
| `sexpr lower` | 39 match / 615 differ / 51 host-rejected / 0 self-rejected (re-measured 2026-10-03) | 0 differ | `ruby tools/sexpr_parity.rb lower -q -j 16` |
| `cli:parity` | 24 match / 37 differ / 0 pending (61 cases; re-measured 2026-10-03) | all match | `rake "cli:parity"` |
| LSP harness | 30/30 capability keys; 5 documented entries of **66 requests + 19 probes** (re-measured 2026-10-03 session 28, `--stress` included) | 0 unintended | `tools/lsp_parity.rb record/compare --stress` |
| LSP project audit | **4 stable differ + the host's first-file `documentSymbol` race** (re-measured 2026-10-03 session 27 on 7075 entries: completion 2, hover 1, documentHighlight 1; completion 4 → 2 this session; the race appeared in the gates run and not in the standalone run) | 0 unintended | `tools/lsp_project_audit.rb --workspace ~/Projects/MilkTea/SimpleGame` |
| LSP recovery | 6/6 cases byte-equal | stay green | `tools/lsp_recovery_probe.rb --check` |
| formatter | 705/705 all three modes (re-measured 2026-10-03; file counts drift) | stay green | `ruby tools/format_parity.rb all -j 16` |
| lint corpus | 494 agree / 115 differ (609 files; re-measured 2026-10-03) | 0 differ | `ruby tools/lint_parity.rb -q` (`--host-cache`) |
| DAP | process-backend request parity (re-measured 2026-10-03; terminal event order and build-on-launch differ); lldb-dap unstarted | VS Code end-to-end under lldb-dap | `ruby tools/dap_smoke.rb` |
| imported-bindings | 3 verified / 25 changed (re-measured 2026-10-03; cosmetic emitter gaps) | 28/28 or each justified | `mtc imported-bindings --all --check` |

Baseline for reference only (Phase 0, session 5): bootstrap 14/0, `test/mt`
60/0, lex 702/702, parse 698/0, lower 39/613/51/0, cli 22/39, LSP 4 documented,
lint lb host 98 / self 158.  **Do not replay a baseline a previous session
verified at the same commit** — counts drift (sexpr's file count with the tmp
fixtures, the audit's ±10 between runs, the lint corpus with tmp files).

---

## 0k. 2026-09-25/26 session — LSP parity harness + gap closure

Goal: do what phase 3 above says — actually exercise `build/stage2/mtc lsp`
against the Ruby server and close what differs.

### The harness (`tools/lsp_parity.rb`)

The missing piece: an **out-of-process** driver, because every existing LSP test
drives the Ruby server in-process (`test/tooling/lsp/server/helpers.rb` spawns
`RbConfig.ruby -I lib -e "require 'milk_tea'; ..."`).  `tools/lsp_parity.rb`:

```
ruby tools/lsp_parity.rb record --server host  --out tmp/host.json [--stress]
ruby tools/lsp_parity.rb record --server self  --out tmp/self.json [--stress]
ruby tools/lsp_parity.rb compare tmp/host.json tmp/self.json [--full]
```

- builds one synthetic multi-module workspace at a **fixed path**
  (`tmp/lsp-parity-ws`, so URIs compare equal), opens it with
  `initialize.rootUri`, and drives a 55-request corpus covering every endpoint
  (hover at 8 positions, definition/declaration/typeDefinition/implementation,
  references, documentHighlight/Symbol, folding/selection/linkedEditing ranges,
  completion at 4 positions, signatureHelp, prepareRename/rename, inlayHint,
  semanticTokens full/range, codeLens, codeAction, documentLink,
  call/typeHierarchy prepares, pull + workspace diagnostics,
  `milkTea/documentContext`, `milkTea/debugInfo`, workspace/symbol, formatting,
  rangeFormatting, onTypeFormatting, willSaveWaitUntil, cross-file hover/symbols);
- **follows up with the resolve endpoints a real editor calls** —
  `codeLens/resolve`, `completionItem/resolve` and `documentLink/resolve`, with
  payloads derived from the responses just recorded — plus the notification-form
  `didSave`, `$/setTrace` and `milkTea/documentContext`, and (after the measured
  probes) the cache-invalidating `didChangeConfiguration`,
  `didChangeWatchedFiles`, `didChangeWorkspaceFolders` and `willRenameFiles`
  notifications.  Stage 5b: the resolve endpoints were missing, which is how the
  VS Code startup double free shipped;
- **normalizes** the volatile parts before comparing (workspace path, `resultId`
  fingerprints) and decodes semantic tokens with each server's own legend so
  token *types* compare by name, not by legend index;
- answers server→client requests (`workspace/configuration`) the way a real
  client must — without that the self-host's `milkTea/documentContext` looked
  like a hang;
- `--stress` adds 15 adversarial probes: 20 rapid incremental `didChange`s,
  5 full-document replacements, out-of-range/negative positions, unknown
  methods, missing params, wrong param types, unknown documents, unterminated
  source, emoji/UTF-8 positions, open/close cycling.

### Fixed this session

1. **`initialize.rootUri` was ignored; the workspace root came from argv.**
   `handle_initialize(id)` never read its params and `workspace_root_from_args`
   returned `args[0]` — the *command name* (`lsp`), so the workspace root was
   literally `"lsp"`.  The index, diagnostics, references and `workspace/symbol`
   therefore ran against the wrong tree (`milkTea/debugInfo` showed
   `Root path: lsp`, `Index entries: 21292` — the repo).  Now
   `handle_initialize(id, params, ws)` applies `rootUri`/`rootPath` through
   `Workspace.set_root` (re-discovering module roots and dropping the stale
   index/diagnostic caches), and the CLI arg is only the pre-initialize default.
2. **Capability parity: 30/30 keys.**  Added `positionEncoding`,
   `textDocumentSync.willSaveWaitUntil`, the host's `diagnosticProvider`,
   `codeActionProvider.codeActionKinds` case, and the host's full semantic-token
   legend (23 token types / 10 modifiers — the self-host advertised 15/3 and
   classified with its own indices, so `semantic_tokens.mt`'s `TOKEN_*`
   constants were renumbered and `SNAPSHOT_TOKEN_NAMES` extended).
3. **Cross-file `references` emitted malformed JSON** (`"}}` where three closing
   braces are needed), which aborted the whole response frame; fixed, and
   `references/compute` is now byte-identical to the host.
4. **`milkTea/documentContext` never answered a request.**  The host replies
   `null`; the self-host treated it as a notification only.
5. **Hover now carries the host's location line and range**:
   `Defined at: [main.mt:33](file:///…/main.mt#L33)` (instead of
   `*Defined at line 33*`) plus the `"range"` object for the hovered token.
6. **`definition` / `declaration` / `typeDefinition` return a bare `Location`
   object** when there is one result, as the host does (they returned a
   single-element array).

**Stages 1–3 commits (2026-09-26).**  `7e980196` (stage 1 — the seven isolated
harness entries), `36d42b3c` (stage 2 — completion mirrors the host's branches),
`23d6460f` (stage 3 — documentSymbol mirrors the host's tree).

### Fixed this session (2026-09-26)

1. **Keyword/builtin hover docs are the host's tables.** `mtc/lsp/hover_docs.mt`
   (new) carries `KEYWORD_HOVER_INFO` + `LANGUAGE_KEYWORD_HOVER_INFO`
   (`lib/milk_tea/lsp/server/hover.rb`) and `BUILTIN_CALL_HOVER_INFO`
   (`lib/milk_tea/lsp/server.rb`) verbatim, generated from the Ruby constants;
   `resolve_non_decl_hover` renders them with the host's shape (blank line before
   the docs, no `Defined at` line for keywords/builtins).  Closes
   `hover/struct`, `hover/local`, `hover/keyword`, `hover/alpha`,
   `stress/open-close+hover`.
2. **Keyword/builtin hovers carry a `range`.** They had none, because
   `hover_range_json` only accepted identifiers; `cursor.token_at` now resolves
   any non-structural token kind for that fallback.
3. **`builtin_specialization_hover` requires a following `[`** — it used to answer
   `builtin zero[...]` for a bare `zero`/`default`/`reinterpret`/`array`/`span`
   (with a dead token-kind check); those now fall through to the builtin-call
   table like the host.
4. **`signatureHelp`** labels carry the return type; **`prepareRename`** answers
   `{range, placeholder}`; **`documentLink`**'s direct tooltip is
   `Open linked file`.
5. **Inferred local types** (`mtc/lsp/type_render.mt`, new).  A local hover now
   renders the host's `let s: Sample (immutable)` — the declared type when
   annotated, else `analysis.resolved_expr_types[<initializer pointer>]` — plus
   the host's `*From <module>*` line, fed by `type_render.shorten_signature`,
   which strips `module.` prefixes and reports them; the file's module name comes
   from `resolver.infer_module_name` (the compiler's own rule).
   `CursorResult` carries the stripped modules and the renderer prints them after
   the fence.  Inline hints gained the host's `: Sample` type hint (kind 1,
   `paddingRight false`, emitted after the parameter hints) and
   `paddingRight true` on the parameter hints.  Closes `hover/method-call`,
   `inlayHint`, `stress/rapid-didChange+hover`.
6. **Local definition ranges and aggregate-literal labels.**  A local's
   `CursorResult` now carries the 0-based column of its name on the declaration
   line (`cursor.token_start_in_line`), so `definition/local` lands on the name
   token as the host does.  `named_argument_label_hover` resolves a label inside
   a struct aggregate literal (`Sample(x = 1, …)` on `x`) to that field's
   declaration line and semantic type, rendering the host's `field x: int`.
   Function-call labels stay unresolved (the host answers with a parameter
   hover there — not corpus-covered, noted as a gap).  Closes `hover/field`.

### Fixed this session (2026-09-26, stage 4 — diagnostics + semantic tokens)

**Re-measured**: capabilities 30/30 keys identical; **3/47 requests and 2/15
stress probes differ (5 entries)**; 0 timeouts; 0 crashes; **both
semantic-token comparisons are byte-equal**.  Entries closed: `diagnostic/pull`,
`workspace/diagnostic`, `semanticTokens/full`, `semanticTokens/range`.

1. **Diagnostics analyse the editor buffer, not the file on disk.**  The self
   hashed the buffer but loaded diagnostics from disk, so a `didChange` without
   save (the stress probe's premise) reported stale items.
   `loader.check_program_with_source` parses the *root* module from the caller's
   text (imports still read from disk); `collect_diagnostics` passes the buffer
   through.
2. **Lexer diagnostics reach the client.**  `parser.parse_source_reporting`
   exposes the lexer's recoverable errors; `LoadedModule` carries them and
   `check_and_bind_module` reports them as `lex/error` *before* the parse errors
   (the host's `lex_errors + parse_errors` order).  Semantic analysis now also
   runs on a recovered AST, so parse errors no longer short-circuit it.
3. **Diagnostic fidelity** (`lsp/diagnostics.mt`): the LSP derives the host's
   codes (`module/error` → `import/load-error`) and `data.stage`
   (`lex`/`parse`/`import`/`sema`/`lint`); ranges span the offending token (new
   `LoadDiagnostic.length`, import failures anchored at the module-path text via
   the host's `import_path_span`); sema messages that quote identifiers become
   MarkupContent; items are scoped to the requested document.  `SemanticDiagnostic`
   gained a `length` (`unknown name X` spans the name).
4. **`workspace/diagnostic`** reports *every* open document in didOpen order
   (`Workspace.open_doc_order`, because the map is hash-ordered) with the host's
   `{uri,kind,resultId,items,version:null}` shape and `previousResultIds`
   handling, instead of only cache misses.
5. **One semantic-token scanner** for full/range/delta.  The divergent
   `emit_semantic_tokens`/`compute_token_data` pair became a single
   `classify_scan_identifier` porting the host's `classify_name_semantic` order:
   import path segments vs the alias (`namespace` + `declaration` on the
   *alias*, not the first path segment), declaration names after their keywords
   (struct/union/enum/flags/variant/type/opaque/interface names are `type`, not
   `struct`/`interface`), struct fields / enum members / variant arms / payload
   fields, parameter declarations, named-argument labels in type constructors
   (`property`), dotted members (imported-module member through the resolved
   alias surface; `enumMember` for a type receiver; `method` when called and
   `property` otherwise), builtin `defaultLibrary` type and function names, and
   type-constructor calls (`Sample(...)` → `type`).  `handle_semantic_tokens_range`
   reproduces the host's band quirk (the requested range's first line is never
   emitted, `semantic_tokens.rb:105-118`).
6. **Linter parity for those items**: `prefer-inline-methods` implemented
   (host `rules.rb:600-631`; hint; `extending X:` on a same-file struct),
   `unused-import` skips unresolved imports (the LSP hands the loader's list to
   `lint_source_unresolved`), and `doc-tag` warnings carry the host's `@` column
   and lengths instead of `[0,1]`.  `mtc lint` itself still passes no unresolved
   list (its command has no module roots), so the CLI keeps flagging unresolved
   imports — a CLI-parity follow-up.
7. **Unresolved import aliases stay unbound in the LSP path**
   (`check_module_requiring_resolved_imports`, the host's `allow_missing_imports`
   behaviour), so `alpha.fn_alpha(10)` reports `unknown name alpha` like the
   host, while the compile path keeps the permissive aliasing the lowering tests
   depend on.

**Costs measured**: the token scanner loads each *resolved* import's surface per
request (a resolve stat plus a parse/analyze of the imported module), so
`semanticTokens/full` on `projects/mtc/src/mtc/main.mt` (28.8k tokens, ~30
imports) takes 557 ms and a diagnostic pull 694 ms (std/raylib.mt: 168 ms /
41 ms).  Acceptable for now; a content-keyed alias-surface cache in `Workspace`
is the follow-up if it hurts editing.

**Gates re-run for this change**: `tools/bootstrap.sh -j 16` (fixed point holds —
`stage2.c == stage3.c` — 12 test files / 0 failed), `build/stage2/mtc test test/mt`
(60 files / 7 pre-existing build failures), `rake "cli:parity"` (21 match / 39
differ / 1 pending, unchanged), `sexpr_parity lex` 696/696 and `parse` 0
differences, `lower` 38 match / 606 differ / 0 self-rejected, valgrind on the new
diagnostics + token paths (0 invalid reads/writes; leaks only), and a headless
Neovim 0.12 attach/edit/shutdown smoke test (an unsaved edit changes the pull
diagnostics, proving the buffer path).

### Fixed this session (2026-09-26, stage 5 — formatting/tidy)

**Re-measured**: capabilities 30/30 keys identical; **1/47 requests and 2/15
stress probes differ (3 entries)**; 0 timeouts; 0 crashes; both semantic-token
comparisons byte-equal.  Entries closed: `formatting`, `rangeFormatting`.

1. **Trivia-aware lexing** (`mtc/lexer/trivia.mt` + `lexer.mt`): a
   `lex_with_trivia` mode records blank lines, comment-only lines, indentation,
   interior space runs, inline comments and grouping newlines in source order —
   a port of `core/lexer.rb:136-193, 207-292, 424-440` and
   `core/lexer/trivia.rb`.  `lex`/`lex_reporting` are untouched, so the
   compiler's token stream and the `--sexpr lex` dump stay byte-identical.
2. **CST** (`mtc/formatter/cst.mt`): `build_cst`, `reconstruct` (verbatim) and
   `reconstruct_normalized` (interior runs collapse to one space; indentation,
   comments and blank lines stay) — a port of `core/cst.rb`.  The Ruby CST
   attaches leading/trailing trivia per token; the port merges the
   source-ordered trivia list with the token list by offset, which emits the
   same bytes because trivia never crosses a token span.
3. **Tidy pipeline** (`mtc/formatter/tidy.mt`): the mode dispatch
   (`safe`/`canonical` → the existing AST printer, `preserve` → CST reconstruct,
   `tidy` → normalize → wrap → blank lines; `formatter.rb:13-24, 54-69`),
   `normalize_blank_lines` with its helper set (`225-621`) and the long-line wrap
   machinery (`71-216`, `623-778`) including its 100-iteration cap and
   per-candidate re-parse validation.
4. **LSP handlers** (`lsp/formatting.mt`) match `lsp/server/formatting.rb:646-693`:
   the mode comes from the client configuration (empty ⇒ `tidy`, the host's
   default), a full format always answers one edit ending at `count("\n") + 1`,
   `rangeFormatting` formats the *segment* (the requested range's bytes) and
   carries the requested range, and any formatter failure answers `[]`.  The
   advertised-but-unhandled `textDocument/willSaveWaitUntil` capability now has
   its host handler too (`lsp/server/text_documents.rb:109-135`: one edit, or
   `null` when the buffer is already formatted; the host's 0.5 s cap is not
   ported).
5. **CLI**: `mtc format` gained `--tidy` / `--preserve` / `--canonical` /
   `--safe` / `--max-line-length N` / `-w` / `--` (`format.rb:111-171`); the
   default stays the canonical printer.
6. **New sweep** `tools/format_parity.rb` (host formatter in-process, self-host
   per file with timeout + memory cap, `-j` workers): repository-wide
   **preserve 702/702 and tidy 702/702 byte-identical**.  It found two port bugs
   the LSP harness cannot reach — the wrap candidate sort must be *stable* (the
   host's `sort_by` keeps equal keys in discovery order for the small candidate
   lists a line produces), and the wrap's slices mix the lexer's byte columns
   with Ruby's **character** indexing, which is also why the host refuses to
   wrap lines whose arguments contain multi-byte text (both behaviours are
   reproduced exactly and pinned in `projects/mtc/test/tidy_formatter_test.mt`).
   `canonical` is 302/702: the host reattaches trivia into the AST printer while
   the self-host's `pretty_printer/ast_formatter.mt` still drops comments — the
   pre-existing canonical-mode gap, untouched by this stage.

**Costs measured** (host vs self, same file): `format --tidy` on
`projects/mtc/src/mtc/main.mt` (4.5k lines, many over-length lines) 17.6 s →
1.35 s; `std/raylib.mt` (long file, no over-length lines) formats in 16 ms.  The
cost is the wrap loop, which re-lexes and re-validates the whole file per applied
fix (100-iteration cap) — the host does exactly the same, so the profile matches
by construction; the LSP `formatting` request inherits it for large files with
many long lines.

### Fixed this session (2026-09-26, stage 5b — the VS Code startup crash)

A real VS Code session aborted with `free(): double free detected in tcache 2`
within ~20 ms of `initialize` (the client restarted the server five times, then
gave up).  Reproduced by running the extension host headlessly
(`xvfb-run code --extensionDevelopmentPath=bindings/vscode …`) with the server
wrapped in valgrind, which reported two `Invalid free`s: a 16-byte block
allocated in `code_lens.mt:140` (`title.append`), freed by the handler's
`defer: title.release()` **and** again by the JSON release chain.

1. **`codeLens/resolve` double-freed its title** (`lsp/code_lens.mt`):
   `json.string_value(title)` takes ownership of the `String`, so the handler's
   `defer` and the response's release both freed the same buffer.  Now the title
   is copied in with `json.string_from_str(title.as_str())`, matching the
   adjacent `command` field.
2. **`documentLink/resolve` emitted malformed JSON** (`lsp/document_link.mt`):
   the response was hand-built without the `range` field and started with a
   stray comma (`{,"target":…`), which the client's frame parser rejects —
   caught the moment the harness gained the entry.  Replaced with the host's
   semantics (`handle_document_link_resolve`): echo the link back with
   `tooltip = "<path>\n<first line>"` (unchanged when the target is unreadable).
3. **`codeLens/resolve` counted references by raw text** (`lsp/code_lens.mt`):
   `count_references` summed word-boundary matches across every indexed file
   (4 for the fixture's `sum` where the host reports 2 — a repo file whose index
   entry is also named `sum` contributes).  It now counts the same locations the
   references handler produces (`navigation.count_reference_locations`), which is
   the host's fallback rule.  The host's *static-method* path
   (`resolve_static_type_reference_target` → `static_type_method_references`,
   receiver-type aware) is still not ported, so method lenses can still differ
   — catalogued in the table below.
4. **The harness could not see any of this**: it never sent the resolve
   endpoints a real client always sends.  `tools/lsp_parity.rb` now drives
   **55 requests + 19 probes** — `willSaveWaitUntil`, `codeLens/resolve`,
   `completionItem/resolve` and `documentLink/resolve` (payloads derived from
   the responses just recorded), plus `didSave`, `$/setTrace`,
   `milkTea/documentContext` (notification form), and, after the measured probes,
   the cache-invalidating `didChangeConfiguration` / `didChangeWatchedFiles` /
   `didChangeWorkspaceFolders` / `willRenameFiles` notifications (crash coverage;
   placed last so they cannot perturb the probe results).

**Verified**: the headless VS Code session (initialize → didOpen → codeLens →
resolve → links → diagnostics; 12,176 allocations) reports **0 valgrind errors**
where it previously aborted; the extended valgrind drive over
formatting/rangeFormatting/codeLens-resolve/documentLink-resolve/willSaveWaitUntil
is clean; the harness records 55 + 19 with no crash and no timeouts.

### Fixed this session (2026-09-26, stage 5c — module roots for real projects)

Reported from a real VS Code session: a project **outside this repository**
(`/home/teefan/Projects/MilkTea/SimpleGame`) reported `module not found:
std.raylib` — in the editor *and* under `mtc check` / `mtc build`.  Root cause:
the self-host built module roots from the source path (the nearest `std/`
ancestor) and the explicit `-I` flags only, while Ruby's
`ModuleRoots.roots_for_path` also appends **the enclosing package's source
root** and **the compiler's own root** (`MilkTea.root`), plus the
`MILK_TEA_MODULE_ROOT` / `MILK_TEA_STD_ROOT` environment roots.

1. **Compiler roots** (`loader/path_resolver.mt`):
   `compiler_root_candidates()` returns the env roots (PATH-separated,
   normalized like `ModuleRoots.normalize_root`) and the directory containing
   `std/` next to the running binary (`fs.canonicalize("/proc/self/exe")` →
   `fs.find_ancestor_containing`).
2. **Package roots** (`loader/package_manifest.mt`, new): the nearest ancestor
   `package.toml`'s `[package] source_root` (default `src`), so `import game`
   resolves `SimpleGame/src/game.mt` for any file inside the package.
3. **CLI**: `add_module_roots` (`main.mt`) replaces the bare
   `discover_project_root` calls in `check`, `build`/`run`, `run-module`,
   `snapshot` and the `std` command, appending package + compiler roots after
   the discovered project root.
4. **LSP**: `Workspace.create` / `set_root` append the same candidates
   (`append_compiler_module_roots`), so the editor resolves `std.*` and the
   package's own modules for any workspace root.

Verified against the reported project: `mtc check src/main.mt` now prints the
host's 3 warnings and no `module not found`; driving the LSP with
`initialize(rootUri=SimpleGame)` reports those same diagnostics, resolves
`game` to `SimpleGame/src/game.mt`, and answers codeLens; `mtc build .` gets
past resolution (the const-folding gap it then hits is §0j row 12).

Two more fixes found while building that project:

- **`cstr` contextual typing** (`lowering.mt`): a bare string literal in a
  `cstr` slot (`var Title: cstr = "Hello"`, `let local: cstr = "local"`) now
  lowers to a cstring literal as the host's `lower_compile_time_literal` does.
  The self-host emitted the `mt_str` aggregate into a `const char*` slot —
  invalid C.
- **Qualified const-method calls** (`lowering.mt`): `alias.Type.method(...)` in
  const position now reaches the const evaluator (`try_const_method_value`), so
  `const B: int = rl.Color.arithmetic()` folds like the host's.

### Fixed this session (2026-09-26, stage 6c — imported generics, outline details, linter parity)

Reported from VS Code: the outline (`documentSymbol` details) rendered every
local as `<error>` — `v :: <error>` where the host shows `v :: Vec[int]`.
Three fixes:

1. **`extending Vec[T]:` never registered the block's type parameters.**  The
   signature pass entered only the *method's* type params, so a `T` in a
   method's parameter or return type resolved to `ty_error` — every generic
   extending method (`std.vec`, `std.iter`, …) had an untyped signature.
   `enter_extending_type_params` now registers the block target's arguments in
   both the signature and the body pass.
2. **Instantiated imported receivers had no member resolution.**
   `resolve_member_access` / `check_member_call` resolve
   `alias.Type[args].method(...)` and instance methods on an instantiated
   imported receiver, substituting the type arguments into the binding's
   signature (`substitute_type` recurses into `ty_imported` args; bindings
   export their types' declared parameters; the method search covers every
   visible binding, because `std.iter` declares `extending Vec[T]:` on a type
   another module owns).  Arguments are still checked, so cross-module
   arity/type mismatches stay diagnosed.
3. **`documentSymbol` uses a loader-backed analysis.**  New
   `Workspace.analysis_for(path)` runs the loader (imports bound, cached per
   content fingerprint, the owning Program retained so name views stay valid)
   and `symbols.mt` walks *that* AST, because `resolved_expr_types` is keyed by
   expression pointer.  This is the path the host's facts come from.

Measured on `examples/data_structures.mt` (the file in the report): the outline
now differs from the host in **9 of 81 local details** (was 81 of 81).  The
remaining ones are generic *function* calls whose type arguments must be
inferred from the arguments (`iter.iter_filter(vec_iter, is_even)` →
`Iter[int]`, `paths.path_to(4)` → `Vec[ptr_uint]`, `b.test(3)` → `bool`) — the
analyzer's generic-call inference, catalogued in the gaps table.

Linter parity fixes found by the same fixture (`mtc lint` is now byte-identical
on it): `unused-import` walks a local's initializer, so an import used only as
`vec.Vec[int]` is not reported unused; `owning-release-leak` anchors on the
binding's declaration line (was line 1) and names the type — `owning binding 'v'
of type 'Vec' is never released`, matching the host.  Still open there:
`prefer-let` does not see mutation through *editable* methods (`var v` +
`v.push(1)` is correct code the host does not flag — §5.3c item 1), and the
self-host-only `dead-assignment` rule adds items the host has no rule for (a
deliberate value-add; files where it fires differ by design).

4. **Cross-file references are scoped to import dependents.**  The walk used to
   visit every workspace-index entry *named* the same symbol — an over-inclusive
   rule (an unrelated `std/` file declaring `sum` contributed two locations) —
   while the host asks the declaration's importers
   (`reverse_import_dependents_for`).  The index now records each file's imports
   resolved to the files they name (`Index.files`), and `references` collects
   occurrences from the request's file plus its importers.  Measured
   (2026-09-26): in a two-file probe where `b.mt` imports `a.mt` and calls its
   `sum`, both servers now return the declaration **and** `b.mt`'s call site
   (before, the self-host returned only the declaration).

5. **`prefer-let` no longer fires on editable-method mutation.**  `var v =
   vec.Vec[int].create()` plus `v.push(1)` is correct code (the analyzer itself
   reports `cannot call editable method push on an immutable receiver` for the
   `let` form), but the linter could not see method kinds, so it told users to
   make the binding `let` — 28 such false hints on `examples/data_structures.mt`
   alone.  The analyzer now records every `editable` method call's receiver
   (`EditableSite`: name + the receiver's line, the host's
   `editable_receiver_expression_ids`), `lint_source_with` /
   `lint_source_unresolved` take those sites, and the scope pass marks the
   binding mutated, so the hint only appears when the host reports it.
   Restoring that check also fixed a stage-6c regression: the instantiated
   imported-receiver path returned before the editable check, so
   `let v` + `v.push(1)` was accepted silently; the check now runs before the
   type is substituted, and its message matches the host
   (`cannot call editable method push on an immutable receiver`, not
   `… method v.push … on an immutable value`).  That exposed one more gap:
   `resolve_method_sig`'s bare-name case stopped at the current module, so a
   value whose type arrives as a re-exported/raw struct name
   (`bitset.with_capacity(64)` → `Bitset`) never resolved `Bitset.set`, and the
   editable check stayed silent where the host reports it; it now also consults
   the receiver's module binding and every visible binding, like
   `lookup_method_anywhere`.  Measured: prefer-let hints on
   `examples/data_structures.mt` 28 → **0** (the host reports none), so the
   linter's only remaining delta there is the self-host-only `dead-assignment`
   rule (4 hints the host has no rule for).
   The `mtc lint` subcommand and its `--fix` still lint standalone files, so they
   pass no sites and keep the old hints; the `check` path and the LSP's
   diagnostics use the root analysis.  **Known hazard (pre-existing, not a
   regression):** `mtc lint --fix --select prefer-let` therefore still rewrites
   `var v = vec.Vec[int].create()` to `let v` while `v.push(1)` remains, i.e. it
   emits code the analyzer rejects.  The fix is to make the `lint` command
   loader-backed like `check` (pass the root analysis' `editable_receiver_sites`
   to `lint_source_opts` and `fix_engine.fix_source`), which also brings its
   hint set to parity; a conservative "skip prefer-let when the binding is a
   call receiver" guard in the fix engine is the alternative if the command must
   stay standalone.

Harness: a std-generic fixture (`containers.mt`) locks the outline details and
the diagnostics on std-generic code (including the editable mutation case), and
a resolvable import pair
(`helper.mt`/`user.mt`; the importer stays closed because the host's pull
diagnostics report `unknown callable` for it while its reference facts resolve
it) locks cross-file references — **55 requests + 19 probes**, 4 differing entries (the extra one is the
malformed-frame probe below, where the host times out and the self answers),
0 crashes, 0 timeouts.

### Robustness and performance (2026-09-26, stage 6d)

A robustness pass over the running server — malformed traffic, broken documents,
edit storms, pathological input, then the latencies of a real edit cycle.

**Recovery**

- **A malformed frame used to shut the server down.**  `read_message` returned
  none for EOF *and* for every protocol error, and the loop treats none as EOF,
  so one bad message (invalid JSON, a missing or bogus `Content-Length`, a
  negative length) ended the session.  `read_message_status` now reports
  `READ_EOF` / `READ_MALFORMED`, the loop answers a malformed frame with a
  JSON-RPC `-32700` (id null) and keeps serving, and a declared body larger than
  256 MB is rejected instead of read.  Verified: garbage frames interleaved with
  real requests no longer disturb the session, and unknown methods answer
  `-32601`.
- **Syntax errors no longer disable the outline.**  `documentSymbol` returned
  `-32800` for any file with parse errors, so the outline went blank exactly
  while typing; the host reports the symbols it could parse (measured: 1 item
  for the broken fixture) and so do we now.
- **Import cycles, a 1 MB string literal, and 2 000 nested parentheses** all
  answer within ~85 ms with no hang and no crash (checked under valgrind:
  0 errors).
- **200 `didChange` notifications in a row** leave the server responsive and
  every following request sees the newest text (`documentSymbol` returned the
  last edit's locals).  Closing a document re-reads it from disk.

**Stale state**

- **The workspace index was only built once**, so an edit that added a symbol
  was invisible to `workspace/symbol`, completion and document links.  Content
  changes now mark the file dirty and the next index-backed request re-indexes
  just that file (`Index.remove_file` + `collect_file_symbols_with_source`,
  reading the editor buffer, not disk); a full tree walk is no longer needed.
  Verified against the host: after adding `beta_fn` in an edit,
  `workspace/symbol` and `references` both find it, matching the host.
- **`semanticTokens/full/delta` compared the current scan with a rescan of the
  same text**, so it always reported an empty edit list and the client kept
  stale colours.  The cache now stores the token data that produced its
  `resultId` and the delta diffs against that.  The response *shape* for plain
  `full` stays the host's (no `resultId`), so the harness entries are unchanged.

**Performance** (measured on a 1 700-line file with std imports, per request)

| request | before | after |
| --- | --- | --- |
| `semanticTokens/full` (same content) | 143 ms | 7.8 ms |
| `semanticTokens/full` (after an edit) | 144 ms | 58 ms |
| `textDocument/diagnostic` (pull) | 155 ms | 110 ms |
| `codeLens` | 10 ms | 1.7 ms |
| `inlayHint` | 58 ms | 45 ms |
| `documentSymbol` (after an edit) | 74 ms | 73 ms |

- The pull diagnostic rebuilt the loader program per request; it now reads the
  workspace's cached one (built once per content version).
- The token scan re-read, re-parsed *and re-checked every imported module on
  every request*; it now goes through the workspace's parse cache.
- `documentSymbol`, `codeLens`, `inlayHint` and the token scan each re-parsed and
  re-checked the document per request; `Workspace.parsed_analysis_for` caches the
  pair (the AST with the analysis, since `resolved_expr_types` is keyed by
  expression pointer) per content fingerprint.  The cache owns its copy of the
  source text — the AST's views outlive the request that produced them, which is
  what valgrind caught when the first version cached them without it.
- `scan_is_destructure_let` walked the *whole* token array for every identifier
  (O(n²): 99 ms of the 1700-line file's scan); it now starts at the line's first
  token, with identical results.

**Lint and fix**

- `mtc lint` and `codeActions`' `source.fixAll` now analyze the file like
  `check` does, so they see `editable` receivers, owning types and unresolved
  imports.  That closes the hazard documented in the previous commit: the
  `prefer-let` fix can no longer rewrite `var v = vec.Vec[int].create()` while
  `v.push(1)` requires the `var`, because the warning is no longer produced.
  A binding that really is never mutated is still rewritten.  `mtc lint` on
  `examples/data_structures.mt` now differs from the host only by the
  self-host-only `dead-assignment` rule.

**Real client (Neovim's LSP client, headless)**

`nvim --headless` starts the server, requests symbols/tokens/diagnostics/inlay
hints/code lenses, then inserts a line twelve times with a `documentSymbol`
after each edit.  On the SimpleGame project every request answered in ~1.3 ms
and the client stayed attached throughout; on this repo's 1 700-line
`navigation.mt` the per-edit symbol request cost 28–49 ms end-to-end through the
client, with the cold baseline at 643 ms for the first symbol request and
597 ms for the first inlay-hint request (cold caches), 100 ms for the first pull
diagnostic and 9.7 ms for tokens.  (The VS Code extension host launches its own
server from `milkTea.lsp.serverPath`; driving it headlessly here is unreliable
because the launcher forks to a running instance, so the client-level edit storm
above is the automated real-client check, with the earlier manual VS Code run
as the editor-level one.)

**Locked by the harness** (3 new stress probes, 15 → 19)

- `stress/unterminated-source+symbols` — a file with parse errors still yields
  an outline (identical to the host).
- `stress/edited-symbol+workspaceSymbol` — a symbol added by an edit is found by
  `workspace/symbol` right away (identical to the host).
- `stress/malformed-frame+parseError` — a frame whose body is not JSON.  The
  self answers `-32700`; the host **times out** (it neither answers nor closes),
  so this entry differs by design, and `stress/malformed-frame+recovery`
  confirms the next request is served by both.

**Determinism (found by the fixed-point check, not by a test)**

- The stage2/stage3 comparison failed after this batch with `mt_str_lit_*`
  renumbering: three method lookups that walk *every visible binding* returned
  whichever match the map yielded first (`lookup_method_anywhere`, and the two
  helpers that resolve an instantiated imported receiver).  Which binding wins
  changes the inferred type and therefore the emitted C.  All three now pick the
  lexicographically smallest module name, so the choice cannot depend on map
  iteration order — a self-hosting requirement worth remembering for any new
  cross-binding search.

Still open on this axis: the loader re-parses and re-analyzes its whole import
closure per content version (the 73 ms `documentSymbol` above); a per-module
cache keyed by module content would cut that to the root module's own work
(~20 ms), and is the next performance step if the file sizes here grow.

### Outline parity and generic-call inference (2026-09-26, stage 6e)

`examples/data_structures.mt`'s outline was the file in the user's report; its
local details now render **exactly as the host renders them** (162 differing
lines at the start of the stage-6c work, 0 now).  Four analyzer/rendering rules
closed it:

- **Free generic calls infer their type arguments.**  `iter.iter_filter(it, pred)`
  and `iter.iter_map(it, triple)` now produce `Iter[int]`, and a *qualifying*
  call infers from every argument shape, including a bare function reference
  (`triple` has no inferred type of its own — `ty_error`, so code generation is
  untouched — but inference sees its signature).  `unify` also recurses into
  imported generic type arguments (`Iter[T]` vs `Iter[int]`), which it did not
  before.  The bindings export each function's declared type parameters
  (`function_type_params`), as they already did for types.
- **A receiver whose type arrives as a bare name resolves its methods**
  (`bitset.with_capacity(64)` gives a `Bitset`, whose `test`/`release` live in
  the binding), so those locals type.
- **The outline renders what the host renders**: methods carry no `static`/`mut`
  prefix (only `async`), a type declaration's type parameters are listed first as
  `TypeParameter` (kind 26) children on their own token, field types come from
  the analysis (`fn(value: int) -> bool` renders as `fn(int) -> bool`), and a
  type the analyzer could not resolve renders as **no detail** rather than
  `<error>` — which is what the user saw.
- **Diagnostic ranges cover the symbol the message quotes** when the rule
  tracked only a position (`unused parameter 'self'` spans `self`, not one
  character).

A wider sweep (130 files: `examples/*.mt` and `std/*.mt`, details compared line
by line) went from 6 886 differing lines to 252 on an 8-file sample of the worst
files, and the remainder is almost entirely *our* side resolving locals the host
leaves untyped (e.g. `std/tween.mt`'s `let n1 = 7.5625` → we show `float`, the
host shows nothing; `std/tls.mt` states we type and it does not) — the same
direction as the `Hash`/module-member cases noted below.  The corpus locks the
shape rules with a new `documentSymbol/generics` fixture (generic struct with a
function-typed field, variant, extending block with static/editable/async
methods).

### `milkTea/debugInfo` port (2026-09-26, stage 6f)

The handler now renders the host's `DebugInfoFormatter` sections instead of a
workspace summary, taking the request's `textDocument.uri` and answering with
`{text}` exactly as the host does:

- **Header** — `File:`/`Content: N lines, N bytes`.  The line count comes from
  the lexer's last line, which is the same number as the host's
  `content.count("\n") + 1`.
- **Tokens** — the count, the per-kind histogram (counts descending) and one row
  per token: `"%3d:%-3d  %-*s  %-16s  %s  %-22s  %s"` with the lexeme quoted the
  way Ruby's `String#inspect` quotes it, `Ln %2d  Col %3d-%d`, and the semantic
  class the semanticTokens endpoints would give that token (`type
  (declaration)`, `namespace`, `keyword`, …).  Measured on the corpus file: the
  header, the histogram counts and **245 of 246 rows are byte-identical**.
- **Parse Errors** — `── Parse Errors  N ──` plus one `ERROR [Ln N, Col N]:
  message` line per diagnostic.
- **Workspace** — a self-host addition (root, module roots, open documents,
  index state); the host has no equivalent section.

`semantic_class_entries` shares the semanticTokens scanner, so the debug dump
and the editor's colours cannot disagree; the label tables
(`token_type_name`, `token_modifier_names`) come from the same legend the
capabilities advertise.

Two gaps, both measured and recorded in the table above: the histogram's tie
order (MRI's qsort leaves equal counts in an order first-appearance ordering does
not reproduce) and the host's AST/Facts/Bindings sections, which render the
host's own data structures (Ruby AST class names, `node_ids`, `ValueBinding[id:
N]`, object ids).

### Editor responsiveness, recovery and logging (2026-09-26, stage 6g)

Reported from VS Code: after fixing a syntax error the old errors stayed on
screen, recovery felt poor, and the server felt slower than the Ruby host.

**The stale errors were a publish bug.**  The host calls
`schedule_diagnostics(uri, lint_tier: :full)` on *every* `didOpen` and
`didChange` (`server/text_documents.rb:19,51`); the self published only on open
and save, so a client that shows *pushed* diagnostics kept the broken state's
errors until the file was saved.  `handle_did_change` now re-checks and
publishes (the diagnostic cache is content-keyed, so the work is the same one
loader run the first request after the edit would have paid anyway).  Verified
with a push-only probe: open → clean, break → `lex/error`+`parse/error`, fix →
clean again.

**Recovery itself works** — the lexer and parser recover (they report the error
and keep building a tree: `documentSymbol` still answers, `semanticTokens` still
colour, and sema/lint run on the recovered AST, as the host's LSP pipeline does).
What still differs from the host is the *error set* on broken input, not the
ability to recover: for the probe file the host reports
`[lex/error, parse/error, prefer-let]` where the self reports
`[parse/error, prefer-let]` for a missing `)`, and for an unterminated string
both report `lex/error`+`parse/error` but the self then adds its own sema/lint
items.  Row 3 of the gaps table records the host behaviours to port
(`consume_name` keyword-name errors, one error per function, the top-level
`expected declaration` that ends the parse).

**Measured edit cycle** (`src/main.mt` of the SimpleGame project, which imports
`std.raylib`; per request, `[LSP perf]` lines):

| step | host | self |
| --- | --- | --- |
| open + first `documentSymbol` | 1336 ms | 39 ms |
| edit → pushed diagnostics | (scheduled) | 39 ms |
| edit → `semanticTokens/full` | 11 ms | 19 ms |
| edit → `textDocument/diagnostic` | 28 ms | 0.2 ms (cache hit) |
| `documentSymbol` after an edit | — | 0.2 ms (cache hit) |

The self's cold start is ~34× faster (Ruby parses the whole raylib closure once
per request); per edit it pays **one** loader run for the changed content
(~39 ms) and every other request in that version is a cache hit, where the host
pays its facts rebuild per request.  The self's caches are content-keyed
(loader program per root fingerprint, parse+analysis per document, semantic
tokens per version, diagnostics per content, index per edited file); the
remaining gap is that the loader re-parses and re-analyzes the *whole import
closure* on each content version.  A per-module cache (content hash plus the
analyses' versions of the module's direct imports, so a change cascades to
dependents) would cut that 39 ms to the changed module's own work — the same
incremental shape as the host's facts cache, and the next performance step.

**Logging now matches the host's shape.**  Every request logs
`[LSP perf] req <method> <ms>` (the host's line is
`[LSP perf] req #{method} #{ms}ms`), the default level is `info` (lifecycle,
timings and warnings; `trace`/`debug` add the per-message trace), and the
extension forwards `milkTea.lsp.logLevel` to the server as `--log-level`, so the
window-level setting now controls the server's own output as it does for the
host.

### Feature audit and completion fixes (2026-09-27, stage 6h)

Reported: `import std.stdio as io` then `io.` suggested nothing.  A per-feature
audit (every advertised request, both servers, on `SimpleGame/src/main.mt`)
found the cause and several related ones:

- **Raw/binding modules declare their API as foreign functions** (`public
  foreign function file_open(...)`), and module-member completion only knew
  `decl_function`: `io.` listed the module's types and constants and none of its
  56 functions.  Fixed; the item shape now matches the host byte for byte
  (label, kind 12, `function name(params) -> ret` detail, snippet, `0_` sort
  text, `data`, `labelDetails`), including the host's three-pass bucket order
  (functions, values, types).
- **The alias bucket iterated the wrong list**: imports live in
  `ast_file.imports`, not in `declarations`, so `n`/`no`/`node` never offered
  the module alias and the global list was 5–6 items short of the host's.
- **`definition` / `hover` / `typeDefinition` on module members**: the
  declaration finder had no `decl_foreign_function` arm, so F12 on
  `io.print_format` or `rl.init_window` resolved to nothing.
- **`typeDefinition` on a local** used the single-file analysis (imported types
  stayed `<error>`); it now uses the loader-backed analysis, and a bare `ty_named`
  searches the visible imports, so `var n = node.Node.create(...)` jumps to
  `node.mt`'s `Node` (the host answers with the local's own position).
- **False `owning-release-leak`**: any `X.create(...)` counted as an owning
  creation; it is now gated on the owning-type set, so `Node.create(...)` no
  longer warns (the host reports only `prefer-let` for that file).
- **`prefer-let` on `var v` + `v.push(1)`** no longer fires (the analyzer
  records `editable` receivers; `mtc lint`/`--fix` and `source.fixAll` are
  analysis-backed) and `owning-release-leak`/`unused-import` match the host
  byte-for-byte.

Measured after the fixes, all requests identical to the host except the items
listed in the handoff: completion `io.`/`rl.`/`game.`/`node.`/`s.`/argument
counts, hover (module member, local, type), signatureHelp, definition,
declaration, implementation, references, documentHighlight, documentSymbol,
codeAction, codeLens, documentLink, formatting, rangeFormatting,
onTypeFormatting, foldingRange, selectionRange, semanticTokens, workspaceSymbol,
workspace/diagnostic.

**Session 4 close (2026-09-27) — the stage-plan foundations.**  `f33c5740` (one
lint-options funnel with `.mt-lint.yml` and suppressions everywhere, `mtc check`
full lint, 6 new tests), `2e739191` (canonical comment reattachment + four
printer-fidelity fixes — format_parity **702/702 in all three modes**),
`2b8d59c3` (`line-too-long`: wrappable gate, host message, LSP wrap quickfix;
`navigation.mt` byte-identical), `a0642272` (sema-backed `redundant-cast` with
the host's six checks; `str[i]: ubyte`; the CLI lints the analysis' AST).  These
are stages 1–4 of the stage plan (the records below use the session's 8a/8b/8c
labels); gates for all four: bootstrap fixed point + 14/14, `test/mt` 60/0,
`cli:parity` 22/39/0, `lower` 39/613/50/0 unchanged.

### Linter `redundant-cast` is sema-backed (2026-09-27 session 4, stage 8c)

`linter/redundant_cast.mt` was rewritten as a complete AST walker with the
host's six checks (`visitors.rb:1079-1364` and its boundary call sites):

- cast to same type / `own`->ptr (resolved-type comparison over the
  self-host's type model), with the host's literal-name fallback when the
  inner expression is untyped;
- redundant parentheses (source-line based, no sema needed);
- implicit widening at a coercion slot (typed `let`/`var`, `return`, plain
  `=`) and integer-literal coercion at the same slots;
- implicit float widening inside an arithmetic/comparison operand and
  integer-literal coercion inside a comparison (enum siblings included).

Messages now carry the host's `: <target><-` suffix, and the fix engine
removes the orphaned parens with a cast (single spanning edit) and handles
the parentheses-only warning through the message it now receives
(`edits_for_warning`/`lsp_edit_for_warning` take the warning message).

Two structural fixes the port needed:

- **`str[i]` types as `ubyte`** in the analyzer (it was `ty_error`), matching
  the host's `infer_index_access` — this is what makes
  `int<-text[0]`'s widening visible;
- **the CLI `lint`/`check` paths lint the analysis' AST**
  (`read(analysis).source_file`) instead of a fresh parse: the expression-type
  maps are keyed by expression pointer, so a different parse instance can never
  match (the LSP already did this).  The fix engine builds a fresh single-file
  analysis per re-parse for the same reason.

Measured on `examples/language_baseline.mt`: **redundant-cast 0 -> 1, the
identical line and message as the host** (`424: implicit widening makes this
cast redundant: int<-`); 6 new linter tests; projects/mtc 14 files / 0 failed;
test/mt 60 / 0; the `lower` sweep unchanged (39/613/50/0).

**Session 5 close (2026-09-27).**  Stage 5 (`unused-import` credit parity) landed
as `a16e2c85`, stage 6 (`prefer-let` mutation facts) as `4d23fd79` (`out`/`inout`
foreign arguments — same-module and imported, via
`Analysis`/`ModuleBinding.mutating_param_indices` — str_buffer mutating builtins
as `editable`, and the host's `ref_of`/`ptr_of` alias rule).  `language_baseline`
prefer-let is now **19/19** (was 21); repo-wide prefer-let **507/606**, dominated
by two analyzer gaps: match-arm payload bindings typed `ty_error` (stage 11c) and
editable-receiver resolution in `extending Type[T]` static methods (stage 11d).
The Phase-0 baseline and scoreboard (`tools/parity_scoreboard.rb` +
`rake "parity:scoreboard"`) also landed this session.  Stage 11c's design was
explored here — **do not repeat the reverted bind-to-T model**: register the
prelude payload structs (`Option_some{value: T}`, `Option_none{}`,
`Result_success{value: T}`, `Result_failure{error: E}`) at
`register_prelude_type`, export variant arm *fields* on `ModuleBinding`, compute
the scrutinee type once at a match, substitute the variant's declared type params
with the scrutinee's arguments, bind the arm name to the substituted payload
struct (host `Types::VariantArmPayload`) and resolve `p.value` through the normal
struct-field path; expression matches keep the `ty_error` binding until the same
substitution is threaded there.  Next: stage 11c, 11d, then stage 7.

### Linter `unused-import` credit parity (2026-09-27 session 5)

`unused-import` now ports both of the host's collectors
(`linter/imports_platform.rb`):

- **`collect_used_names`** — lexical root names: type refs (annotations, casts,
  `sizeof`/`alignof`/`offsetof`, proc/function types), expression identifiers,
  match patterns.  The walker (`scope_tracking.mt`'s `credit_walk_*` /
  `credit_typeref`) mirrors the host's statement/expression list exactly —
  notably it does *not* credit specialization type arguments, enum-member
  initializers, or `parallel`/`gather`/`emit` statements, because the host's
  collector does not (those are the host's own omissions; matching them keeps
  the warning sets byte-identical).
- **`collect_method_only_import_uses`** — `credit_member_call` credits the
  import owning the receiver's resolved type module and every import whose
  module declares the receiver method; `credit_hook_call` credits every import
  providing a canonical hook method (`hash`/`equal`/`order`/`default`) when a
  hook builtin is used.  Providers come from
  `build_import_method_providers` (one entry per `file.imports` entry, in
  order, resolving each dotted import against the loader program's analyses)
  and are threaded through `LintOptions.method_providers`; `mtc check`,
  `mtc lint` and the LSP diagnostics path build them from their program.

Pitfalls found while driving the sweep to zero:

1. **Prelude keys are merged into every module's `method_keys`**
   (`install_prelude_types` → `merge_prelude_binding_methods`), so a naive
   provider check credits *every* import whenever a prelude method is called
   (`fmt`/`log` went un-flagged in `navigation.mt`).  `provider_owns_prelude_key`
   gates `Option.*`/`Result.*` to their owning prelude module and excludes the
   builtin `EventError.*`/`Subscription.*` keys.
2. **Receiver types**: `ty_str` is its own type variant (not `ty_primitive`),
   and builtin receivers (`vec3`) are primitives — `type_leaf_name` covers
   primitives, `ty_str`, `ty_named`, `ty_imported`, `ty_generic`, `ty_opaque`,
   `ty_var` and nullable unwrapping, so `s.starts_with(...)` and `v.dot(...)`
   credit their provider imports.

Counters: `examples/language_baseline.mt` unused-import **1 → 0** (host 0);
repo sweep (`tools/unused_import_parity.rb`, 606 files: `std/`, `examples/`,
`projects/mtc/src/`) **605 agree / 1 differ**.  The residual is
`examples/async_network_lobby.mt`: its `Vec` value arrives through a match-arm
payload binding (`Result.success as servers_p`), which our analyzer types
`ty_error`, so the receiver cannot be attributed to `import std.vec`; the host
types the binding from the variant payload.  **Follow-up:** variant payload
typing for match-arm bindings (also improves LSP hover/outline on arm
bindings).

New tooling: `tools/parity_scoreboard.rb` + `rake "parity:scoreboard"` (one
counter table; `FULL=1` adds lower/format/LSP/DAP) and
`tools/unused_import_parity.rb` (the lint sweep above).

Gates for this change: bootstrap fixed point + 14/14 self-tests, `test/mt`
60/0, `cli:parity` 22/39/0 unchanged, `sexpr_parity` lex 702/702 + parse 698/0,
LSP harness unchanged (4 documented entries), `examples/sdl3` 34/34.

### Linter `prefer-let` mutation facts (2026-09-27 session 5b)

`language_baseline`'s last two prefer-let false positives (`var buf` passed to an
`out` foreign parameter; `var buffer: str_buffer[64]` mutated by
`assign`/`append`) are closed, and both mechanisms are ported:

- **`out`/`inout` foreign arguments** (host `mutating_argument_identifier_ids`,
  `calls.rb:802-807`): `record_mutating_param_indices` stores each foreign
  function's out/inout parameter indices at declaration time;
  `record_mutating_argument_sites` records identifier arguments at the call site
  into `Analysis.mutating_argument_sites`, and `mutating_param_indices` is
  exported on `Analysis` **and `ModuleBinding`** so *imported* `alias.fn(...)`
  calls record too (raygui's `check_box(..., inout checked)` — the raylib-example
  case).  The scope pass consumes the sites by `(name, line)` and additionally
  marks explicit `out x`/`inout x` unary arguments.
- **str_buffer mutating builtins**: `clear`/`assign`/`append`/`assign_format`/
  `append_format` now resolve as `editable` (the host's
  `check_str_buffer_method_call`), so the receiver site is recorded and a `let`
  receiver is rejected like the host.
- **Alias sources**: `ref_of(x)`/`ptr_of(x)` with exactly one argument mark the
  argument through `mark_mutated`'s index/member recursion (`ptr_of(arr[0])`
  marks `arr`) — the host's `mark_alias_source_mutated`; `const_ptr_of` no
  longer marks.

Measured: `language_baseline` prefer-let **21 → 19** (identical set to the
host); `examples/raylib/shapes/ring_drawing.mt` 8 → 0.

**Repo-wide prefer-let is 507/606** (99 files differ).  The residual is
dominated by two analyzer gaps, both scheduled:

1. **Match-arm payload bindings are `ty_error`** (`bind_match_arm_names`), so a
   `match … as payload` binding and its field accesses have no type, no
   editable-receiver sites are recorded, and prefer-let fires where the host
   stays silent (plan stage 11c; also the one remaining `unused-import`
   residual).
2. **Editable receivers inside generic/static contexts**: `std/vec.mt`'s
   `with_capacity` (`var result = Vec[T].create(); result.reserve(…)`) is clean
   on the host but ours reports prefer-let — the receiver does not reach the
   editable method from an `extending Type[T]` *static* method (same family as
   the extending-type-param work; to diagnose).

Rendering follow-up: our str_buffer receiver types render without the size
(`str_buffer` vs the host's `str_buffer[64]`), so the new `let`-receiver error
text differs even though rule and position match.

Gates: bootstrap fixed point + 14/14 self-tests, `test/mt` 60/0, `cli:parity`
22/39/0, `sexpr_parity` lex 702/702 + parse 698/0.

**Session 6 close (2026-09-28)** — the SimpleGame hover report; five commits,
hover 286 → 181 of 915, each fully gated.  The report's hypothesis was wrong on
item 1: the alias chain was already correct — `resolve_cursor` built its facts
with the *standalone* `check_source_file` (whose `imported_modules` is null), so
every `alias.Type` became `ty_error`.  Fixes: loader-backed facts +
`shorten_signature` + `value_hover_signature` + the audit's stderr-drain fix
(`98c096eb`); the parameter hover's resolved type (`1174b632`); the `alias` kind
in `find_decl_line_in` + `type_hover_signature` (`bf81591f`); named-argument
labels (`29382f4e`); member methods (`901a2f62`); plus the scope-region fix
`cbbfd180`.  Session deltas: hover 286 → 181, references 278 → 256,
documentHighlight 26 → 15, definition 194 → 138, declaration 194 → 139
(typeDefinition 334 untouched).  Residue ranked: the host's global definition
fallback (62, also driving definition/declaration), rendering shapes (66), the
analyzer's alias-typed generic constructors + static receivers (28),
`this`/unreached parameters (9), member-access fields (7), `type parameter T` (2),
builtin-vs-member precedence (6), one deliberate self-answer.  Five positions the
scope fix moved the other way need a re-check (`docs/data_structures.mt@6:11`;
`docs/memory_stress_test.mt@74:8, 175:20, 370:20, 396:20`).

### LSP hover: imported types resolve through the module-aware analysis (2026-09-28 session 6, plan fix 1)

**Symptom** (SimpleGame report): hover on `MIDNIGHT` in `SimpleGame/src/colors.mt`
rendered `const MIDNIGHT: <error>`, and every signature that named an
alias-qualified imported type degraded the same way
(`function tint(c: <error>) -> <error>`).

**Root cause — not the alias chain.** `resolve_cursor` (the shared resolver
behind hover, definition and typeDefinition) built its facts with
`analyzer.check_source_file(ast_file)`, a *standalone* check whose
`imported_modules` is null.  With no bindings, `resolve_imported_type`
(`analyzer.mt:1497`) answers none for every `alias.Type` reference, and
`resolve_named`'s dotted-name arm then returns `ty_error` — so the analysis the
LSP read carried `ty_error` for exactly the types that named an imported alias.
The recorded alias target was already correct: a loader-backed test
(`projects/mtc/test/semantic_test.mt`, `test_alias_of_alias_records_the_declaring_module`)
pins `type Color = c.Color` re-exported through a second module to
`ty_imported("base", "Color")`, for the alias map, the const's `value_types`
entry and the enclosing `FnSig`'s parameter and return types.

**Fix.** `resolve_cursor` now takes its `Analysis` and AST from
`analysis_for_document` / `ast_for_document` (the loader-backed, import-resolving
path the other LSP features already used), and `resolve_module_member` does the
same for the imported module's own file (so a member's signature types resolve
through *its* imports too).  The hover signatures that render types now use
`type_render.qualified_name` + `shorten_signature` instead of the bare
`types.type_to_string`, which restores the host's `*From <module>*` line, and a
module-level value renders the host's `value_hover_signature` shape —
`const MIDNIGHT: Color (immutable)` / `var counter: int (mutable)` (the
mutability suffix was missing entirely).

**Measured** (`tools/lsp_project_audit.rb --workspace tmp/probe-ws --only textDocument/hover`):
12 → 10 differing entries of 25 — `const MIDNIGHT` and `function tint` are now
byte-identical to the host, and the same fix removed the `<error>` from every
signature hover in the SimpleGame audit.  Verified through a real client
(`nvim --headless` + `vim.lsp.start`, hover on both positions) and valgrind
(0 errors).

**Audit baseline for the rest of the program** (new, full matrix, first run):
`tools/lsp_project_audit.rb --workspace ~/Projects/MilkTea/SimpleGame
--json tmp/audit-all.json --max-diffs 0` → 6456 entries, **1328 differ**:
typeDefinition 334/915, hover 286/915, references 278/915, definition 194/915,
declaration 194/915, documentHighlight 26/915, documentSymbol 5/7,
semanticTokens/full 5/7, diagnostic 3/7, codeLens 1/7, implementation 1/915,
workspace/symbol 1/1.  By file: `src/colors.mt` 410, `docs/data_structures.mt`
321, `docs/language_baseline.mt` 240, `docs/memory_stress_test.mt` 181,
`src/main.mt` 107, `src/node.mt` 43, `src/game.mt` 11.

**Audit tool fix.** The full run used to deadlock: the audit never drained a
server's stderr, and the self-host's one-line-per-request `[LSP perf]` log fills
the 64 KiB pipe and blocks the server mid-`write` (reproduced: the server stalls
after ~1229 requests with 65224 bytes buffered).  `tools/lsp_project_audit.rb`
now drains stderr on its own thread, as a real client does.

Gates: bootstrap fixed point + 14/14 self-tests, `test/mt` 60/0, `cli:parity`
22/39/0 unchanged, `sexpr_parity` lex 702/702 + parse 698/0, LSP harness
30/30 capabilities + 4 documented entries.

### LSP hover: parameters render their resolved signature type (2026-09-28 session 6, plan fix 2)

`parameter_hover_result` rendered the written TypeRef's **first name part**, so
`function tint(c: rl.Color)` hovered as `parameter c: rl (immutable)` where the
host answers `parameter c: Color (immutable)` + `*From std.c.raylib*`; a
parameter whose type the host cannot resolve rendered the same bogus `rl` where
the host renders `<error>`.  The hover now takes the enclosing callable's
**resolved** parameter type — this is what makes an imported type render its
short name plus the From line — via `parameter_hover_in_decl`, which reads the
`FnSig` (`analysis.functions` for a function, `method_signature_for` for an
extending-block method, matched by parameter list because one name can be
extended on several types).

Parameters of `extending` methods had no hover at all: `scope.mt`'s binding walk
only modelled `decl_function`, so `local_binding_line` never matched inside an
`extending` block and `resolve_local_hover` never reached its parameter arm.
`collect_decl_bindings` now gives each extending method its own parameter and
body scopes, and `resolve_local_hover` / `enclosing_local_decl_line` scan
`decl_extending_block` methods alongside functions (so a *local* declared inside
an extending method also resolves to its own declaration).

Measured (`tmp/probe-ws`, hover only): 10 → 8 differing entries of 25; the two
parameter hovers are byte-identical.  Verified through a real client
(`nvim --headless`).

Gates: bootstrap fixed point + 14/14 self-tests, `test/mt` 60/0, `cli:parity`
22/39/0 unchanged, `sexpr_parity` lex 702/702 + parse 698/0, LSP harness
30/30 capabilities + 4 documented entries.

### LSP hover: type members and type names render the host's `type` shape (2026-09-28 session 6, plan fix 3)

Hover on the `Color` segment of `rl.Color` returned null; the host answers
`type Color` with the declaration in the importing module
(`std/raylib.mt:11`).  Two independent gaps produced that:

- `find_decl_line_in` had **no `alias` kind**, so a `type X = …` declaration was
  never located: the alias arm of `resolve_name_in_analysis` could not fire and
  the location-bearing hovers/definitions on an alias were empty.  Added, behind
  the new `type_declaration_line` helper (aggregates first, then aliases).
- A type reached through a module alias is a *module member*: the host's
  `module_binding.types` arm renders the bare `type <name>` (no `=` target) and
  points at the declaration inside that module.  `resolve_module_member` now
  answers that shape before delegating to the generic name resolver.

The same host rule applies to a type named in the file itself: every
`facts.types` entry goes through `type_hover_signature` — `type Name`, or
`type Name = <module-qualified type>` (shortened, so the file's own struct
reports `*From <module>*`) — **never** a declaration body.  The self-host was
rendering `struct Stack[T]:` + its field list (and `enum X:` + members) where the
host renders `type Stack`; both arms now use `type_hover_signature`, and the
now-dead `append_struct_fields_from_ast` / `static_type_keyword` helpers are
gone.  `types.nominal_module` is public for the renderer.

Measured: `tmp/probe-ws` hover 8 → **4** differing entries of 25 (the residue is
plan fix 4); the second fixture (`tmp/probe2/basics.mt`) 13 → 4.  `definition`,
`declaration` and `typeDefinition` on `alias.Type` gain the same location, so
those classes move too.

Gates: bootstrap fixed point + 14/14 self-tests, `test/mt` 60/0, `cli:parity`
22/39/0 unchanged, `sexpr_parity` lex 702/702 + parse 698/0, LSP harness
30/30 capabilities + 4 documented entries.

### LSP hover: field labels, in literals and in declarations (2026-09-28 session 6, plan fix 4)

Hover on a named-argument label of a struct aggregate literal
(`rl.Color(r = 1, …)`) returned null; the host answers `field r: ubyte` with the
field's declaration (`std/c/raylib.mt:45`).  The self-host already had the shape
for a struct declared in the hovered file, but it looked the receiver up in the
local AST only, so an *imported* struct never resolved — and `std.raylib` does
not declare `struct Color` at all, it re-exports `type Color = c.Color`.

`named_argument_label_hover` now resolves the receiver the way the host resolves
a type receiver: the head identifier before the literal's `(` (optionally
`alias.`-qualified) is looked up in that module's **type table**, and a
re-exported alias is followed through `nominal_module`/`nominal_name` to the
module that *declares* the struct — the field (its line, column and semantic
type) is then read from that module's own file, and the result carries the
module's URI so the hover's `Defined at` line links across files.  A head that
is not a type (an ordinary call) stays unresolved, as before
(`types.nominal_name` is public for the renderer).

The declaration-site sibling had a byte-level bug: `field_declaration_hover`
compared the AST's 1-based `Field.column` against the request's 0-based
`character`, so hovering a field name **in its own declaration** (`field x: int`
in `struct Point:`) matched nothing.  Both compare 0-based now.

Measured (`tools/lsp_project_audit.rb --only textDocument/hover`): the probe
fixture is at **0 differing entries of 25** (was 4), and the second fixture
(`struct Point` + `Deque` locals) 4 → 2 — the residue is the host answering
*twice* as `null` where the self resolves the same `let` through an unresolved
`vec.Deque[int]`: a deliberate "answers where the host gives up" extension.

Gates: bootstrap fixed point + 14/14 self-tests, `test/mt` 60/0, `cli:parity`
22/39/0 unchanged, `sexpr_parity` lex 702/702 + parse 698/0, LSP harness
30/30 capabilities + 4 documented entries, valgrind 0 errors.

### LSP hover: member methods resolve to their defining module (2026-09-28 session 6, plan fix 5)

Hover on a method name at a call site (`d.push_back(1)`, `q.dequeue()`)
returned null — the largest hover class in the audit (119 of 286).  The host's
member-access arm resolves the receiver's *type* from its facts and then looks
the method up in the local module and in every imported binding, rendering
`method_signature(binding)`.  `resolve_member_method_hover` does the same from
the analyzer's tables: the receiver's type comes from `type_of_value` (a local,
parameter or module-level value — the same source `local_hover_result` uses),
the method from `method_sigs` keyed `<Type>.<method>` (matching `Vec[T]` for a
receiver seen as `Vec`), first in this module's `extending` blocks and then in
the module that declares the receiver's type — whose file supplies the
declaration line, the hover's source URI, and the docs.  `method_signature_text`
renders the host's `[async ]<keyword> function name(params) -> ret` (the
keyword from the method kind, the return type always present), so `dequeue()`
reports `*From std.option*` through its `Option[T]` return type exactly as the
host does.

It runs **after** `resolve_name_in_analysis` in `resolve_cursor`, so
`EnumType.member` and `alias.member` keep their paths and a local declaration
that already answered still wins.

Measured (full SimpleGame hover matrix, `--only textDocument/hover`):
**286 → 181** differing entries of 915.

**Hover residue after fixes 1–5** (181 entries; the audit's per-classes, with
the cause):

| Class | Entries | Cause |
| --- | --- | --- |
| same signature, `Defined at` differs | 62 | the host's `find_definition_token_global` fallback (a per-file token-pair definition index over the *whole workspace*, then `candidate_definition_uris`); not ported |
| `var particles: SoA[Point, 4]` vs `SoA`; `interface X:` wording; `module std.mem.ptr` vs `type ptr` | 66 | generic-argument rendering for a builtin generic, the interface hover shape, and builtin-vs-member-alias precedence |
| method `self-null` | 17 + 11 | imported generic constructors through a **type alias** record `ty_error` (`var s = hset.Set[int].create()` → `var s: <error>`; `vec.Deque` the host also fails on), and *static* receivers (`Vec[int].create()`, whose receiver is a type, not a value) |
| `parameter self-null` | 9 | the implicit `this` binding of an editable method, and parameters whose enclosing signature the scope walk does not reach |
| `field self-null` | 7 | member-access fields (`p.radius` → `field radius: float`), the member analogue of fix 4 |
| `type parameter T` | 2 | the host's `type_parameter_hover_signature` |
| builtin table wins over a member of the same name | 6 | `resolve_non_decl_hover` consults its builtin tables before `resolve_cursor`, where the host's member arm runs first (`get`, `default`) |
| self answers where the host gives up | 1 | deliberate |

Gates: bootstrap fixed point + 14/14 self-tests, `test/mt` 60/0, `cli:parity`
22/39/0 unchanged, `sexpr_parity` lex 702/702 + parse 698/0, LSP harness
30/30 capabilities + 4 documented entries.

### LSP scope tracking: a declaration's region, not its first statement's line (2026-09-28 session 6, follow-up)

Giving extending methods their own scopes (fix 2 above) exposed a latent bug in
`scope.mt`: `block_last_line` sums each statement's **first** line
(`stmt_ret.line`), so a body whose last statement spans several lines ended its
bindings early.  For `from_hex_str`'s one multi-line `return`, the parameter
`color` got `scope_end` = the `return` line, so `references` and
`documentHighlight` dropped its uses on the following lines — one position
regressed (the parameter's own uses) while everything else about fix 2 held.

A declaration's region is now derived from the source layout instead:
`declaration_region_end` ends it at the line before the next top-level
declaration (or the file's last line), and each extending method ends at the
next method's line.  That is the model the scope walk wants — a body cannot
extend past the next declaration — and it is independent of how many lines a
statement happens to occupy.  `body_end_of`/`stmt_line` stay as they are for the
branch-local scopes they were written for.

Measured: `src/colors.mt@14:71` (references + documentHighlight) is back to the
host's seven occurrences; the SimpleGame references/documentHighlight/definition
counters are unchanged otherwise, and the probe fixtures keep their counts.

Gates: bootstrap fixed point + 14/14 self-tests, `test/mt` 60/0, `cli:parity`
22/39/0 unchanged, `sexpr_parity` lex 702/702 + parse 698/0, LSP harness
30/30 capabilities + 4 documented entries.

**Session 7 close (2026-09-28)** — two commits.  `30851d50`: the host's
definition index (`lsp/definition_index.mt`), the `typeDefinition` pipeline,
hover locations from the index, static type receivers (`Vec[int].create()`,
`alias.Type.method()`), member-access fields (`p.radius`), `type_of_value`
resolved through the scope walk, interface hover wording — plus a C-backend fix
(`collect_span_types` walked only emitted functions while the generic-instance
collection walks all lowered ones, so a pruned function's `Option[span[X]]`
instance had no `mt_span_…` typedef; `maybe_add_span` now recurses into type
arguments and the collection reads `program.functions` — the bootstrap's
"14 test files, 1 failed").  `3585e781`: the host's hover dispatch order
(field/label → bindings → names → members → keyword/builtin tables last), the
import-alias arm's position, primitive builtin precedence, module-qualified
annotation renderings.  Counters: typeDefinition **334 → 91**, hover
**286 → 121**, definition and declaration **194 → 93**, references 278 → 267,
documentHighlight 26 → 15, total **1328 → 696**.  Probes (`probe-ws`,
`probe4`–`probe7`) at 0 for hover/definition/declaration/typeDefinition;
`probe2` keeps its 2 deliberate self-answers.  Next: references (267), then
hover's 121 and the member-pipeline classes.

### LSP definition and member pipeline: the host's global index, typeDefinition, location rule (2026-09-28 session 7)

One root runs through this batch: the host answers `definition`, `declaration`,
`typeDefinition` and every member access from its **binding facts**, falls back
to a workspace-wide *declaration-token index* when those have nothing, and takes
a binding's hover location from that same index.  The self-host had neither the
index nor the host's shapes.

**The definition index** (new `lsp/definition_index.mt`; the host's
`lsp/workspace/definition_index.rb` plus the `definition_token_index` pair scan
in `lsp/workspace/utilities.rb`).  A *definition identifier* is an identifier
immediately preceded by a declaration keyword (`function`, `struct`, `type`,
`const`, `let`, …).  The index keeps that pair list per document plus the names
each document's declaration lines introduce, and answers over a candidate list
the caller orders: the requesting document first (there, the last declaration
*strictly* before the cursor wins, falling back to its **first** when the
position filter matches nothing — which is what happens when the cursor sits on
the declaration itself), then every other open document in didOpen order (first
declaration wins).  `Workspace` owns it and invalidates a document on
didOpen/didChange/didClose.  The host's `@definition_index` / miss / candidate
caches are deliberately not ported: they cache the same answers for speed, and
the per-document indexes already avoid rescanning.

`handle_definition` now mirrors the host's order — facts-based resolution
(`resolve_cursor`), then the local/parameter binding, then the index — so a
parameter or a plain reference that no other rule covers answers where the host
answers.  `definition` and `declaration` share the handler, as the host shares
`handle_definition_request`.

**`typeDefinition`** was resolving the *type of* the symbol under the cursor — a
different question, and the audit's largest class (334 entries).  The host's
`resolve_type_definition_location` is now ported literally: an `import` path
segment answers the module file; a type or interface **the document itself
declares** answers its own declaration; an `alias.Member` answers that member's
declaration in the aliased module (or the module file when the member is not a
declaration there); everything else answers exactly as `definition` does.
`respond_imported_type_location` locates a member through the module's *token
index* (the host's `module_member_definition_location` →
`find_definition_token_in_file`), so a function, a const or a re-exported
`type Color = c.Color` all resolve — and it emits a bare `Location`, like the
host, not a one-element array.

**Hover locations** follow the host's rule: a result that carries no
facts-based source location (a local, a parameter, a `for`/`match` binding, a
keyword, a builtin) takes its location from the same index — the last
declaration strictly before the cursor, else the first — and prints **no**
`Defined at` line when the index has nothing.  That is why a hover on a local's
own declaration points at the *previous* same-named declaration (or itself when
it is the first), exactly as the host's does.

**Member access** gained the two shapes the host resolves from a receiver type:
a *type* receiver (`Vec[int].create()`, `alias.Type.method()`) resolves the
static method in the type's own module — `cursor.type_receiver_at` skips the
receiver's `[…]` argument list, which is what made `dot_receiver_at` miss these —
and a *field* (`p.radius`) answers `field radius: float` with the field's
declaration in the declaring module before the method lookup, as the host's
member chain checks fields first.

**`type_of_value`** (the receiver-type lookup hover and the member hovers share)
walked the first declaration that passed `line <= target`, so a same-named local
in an *earlier* function answered for a later one — SimpleGame has
`var q = fifo.Queue[…]` and `var q = pq.PriorityQueue[…]` in different
functions, and the second's methods resolved against `std/queue.mt`.  The
binding now comes from the scope walk (`local_binding_line` +
`find_local_decl_at_line`), with parameters resolved from the enclosing
signature.

**Interface hovers** render the host's `interface_signature`: `interface <name>`
(no colon) followed by `    [async ][editable ]function <name>(<params>) -> <ret>`
per method, the return type always present.

Measured (full SimpleGame matrix, `--max-diffs 0`):

| Method | Before | After |
| --- | --- | --- |
| typeDefinition | 334 | 92 |
| hover | 181 | 131 |
| definition | 142 | 94 |
| declaration | 142 | 94 |
| references | 267 | 267 |
| documentHighlight | 15 | 15 |
| **total** | **1092** | **709** |

The probe fixtures are all at **0 differing entries** for
hover/definition/declaration/typeDefinition: `tmp/probe-ws` (25 positions), the
`probe4` container fixture `pq.PriorityQueue`/`fifo.Queue`, the `probe5`
cross-file definition fixture, and the new `probe6` field fixture; `tmp/probe2`
keeps its 2 deliberate self-answers (the host gives up on an unresolved
`vec.Deque` type where the self resolves the `let`).

**Compiler bug exposed by this batch — nested span typedefs (C backend).**
`collect_span_types` walked only the *emitted* functions while the generic
instance and struct collection walk **all** lowered functions, so a pruned
function's `Option[span[DefinitionToken]]` instance was emitted with its span
embedded by value and no `mt_span_…` typedef — an "unknown type name" C error in
that test runner.  `maybe_add_span` now recurses into a type's arguments
(generics, imported generics, nullable, tuple, callable) and the span collection
reads `program.functions`, matching the instance collection.  This was the
bootstrap's `14 test file(s), 1 failed`.

Gates: bootstrap fixed point + 14/14 self-tests, `test/mt` 60/0, `cli:parity`
22/39/0 unchanged, `sexpr_parity` lex 702/702 + parse 698/0, LSP harness
30/30 capabilities + 4 documented entries, valgrind 0 errors.

**Hover dispatch order and annotation/location rendering (same session, second batch).**
The host's hover dispatch runs *field declarations and named-argument labels*,
then bindings, then names, then members, and its **keyword/builtin tables last**.
The self-host had the builtin tables first, so a builtin name shadowed a
declared one: `m.get(…)` answered `builtin get(collection, index)` where the
host answers the declared method, and `ptr` as an import alias answered
`type ptr` where the host answers `module std.mem.ptr`.  `handle_hover` now
follows the host's order (`resolve_field_or_label_hover` →
`resolve_local_hover` → `resolve_cursor` → `resolve_keyword_or_builtin_hover`),
and inside `resolve_cursor` the import-alias arm moved *after* the name tables,
because the host's `facts.types` registers the primitives: `str` answers
`type str` with its docs even in a file whose `import std.str` shares the name
(and `vec3` answers `type vec3` + the `extending vec3:` declaration, which
`type_declaration_line` now also locates).  A `type X = …`-style annotation on a
local renders its resolved spelling with the owning module's qualifier
(`var particles: SoA[Point, 4]` + `*From docs.data_structures*`) instead of the
TypeRef's first name part, and a primitive renders bare.

Measured: hover 131 → **121**, definition/declaration 94 → 93, typeDefinition
92 → 91 (total 709 → **696**).

**Residue after this batch, ranked** (696 entries):

1. **references 267** — the largest class, untouched here.  210 are
   `self-fewer`: the host lists occurrences from every file that *imports* the
   declaring module (its dependency graph / open-document set), which the self
   does not track; 56 are `self-more`: for a method, the host answers the
   method's declaration plus its call sites from the defining module, while the
   self answers a name/scope-based occurrence list.
2. **hover 131** — annotation rendering (`var particles: SoA[Point, 4]` renders
   `SoA` because `local_hover_result` prints the TypeRef's first name part),
   builtin-vs-module-alias precedence (`ptr` as an import alias answers the
   builtin `type ptr`; the host's member arm runs before its builtin table), the
   implicit `this` binding of editable methods, `type parameter T`, attribute
   hovers and enum members.
3. **typeDefinition 92 / definition 94** — the same member-access shapes plus
   the host's `module_member_binding_location` artifact: for a method reached
   through an imported type receiver the host reports the *binding's* line with
   the *canonical module's* URI (`rl.Color.hex_digit` → `std/raylib.mt:5`), an
   artifact the self does not reproduce.
4. **documentHighlight 15 / documentSymbol 5 / semanticTokens 5 / diagnostic 3 /
   codeLens 1 / implementation 1 / workspace/symbol 1** — small, independent
   classes.

**Session 8 close (2026-09-28)** — the references pipeline ported into new
`lsp/references.mt` + `lsp/reference_index.mt`: the host's arms in order (static
type-receiver method with the `module_member_binding_location` artifact, scoped
local, module-level name + importing files' identifier tokens, the workspace
identifier index), the tokenization order noted per request, candidates = open /
content-touched / workspace-root documents, only `INSTALLABLE_BUILTIN_TYPE_NAMES`
module-level (`ptr`/`array`/`own`/`ref`/`span` fall through to the token index).
Three `lsp/scope.mt` fixes: region ends = nearest later start line (the analyzer
appends `emit`-expanded declarations out of order), statement last lines cover
every kind, the binding walk descends into `unsafe`/`defer`/`while`/`for`/`when`
bodies.  references **267 → 9** (references-only 255 → 1); the second batch
followed the host's hover order, the type-receiver location artifact and the
builtin specialization arms: hover **121 → 83**, definition/declaration
**95 → 72**, typeDefinition **93 → 70**, total **443 → 336**.  Residue: 9
full-matrix entries (files the host's hovers tokenized and the self's did not —
`option.mt`, `linear_algebra.mt` — plus 1 references-only pacing entry) and 6
deliberate self-better definition answers.

### LSP references: the host's pipeline, index and arm order (2026-09-28 session 8)

`handle_references` is now a literal port of the host's pipeline
(`lsp/server/references.rb`) in a new `lsp/references.mt`, and the workspace
keeps the identifier index the host keeps (`lsp/reference_index.mt`).  Both
halves matter: the *arms* decide which occurrences are correct, the *index*
decides which documents exist to be searched — and the host's index grows with
the session, because every `get_tokens` call tokenizes a document.

**The pipeline**, in the host's order: the identifier under the cursor; a
*static* method reached through a type receiver (`Vec[int].create()`,
`rl.Color.hex_digit(...)`) or through its own declaration; a scoped local
binding; a module-level name of this document (an AST scan of this file plus the
identifier tokens of every file that imports it); and finally the workspace
identifier index (`find_all_references`).

Ported pieces and the host details they carry:

- **The identifier index** (new `lsp/reference_index.mt`): lexeme → (path, line,
  column) in *tokenization order*, because `find_all_references` returns the
  indexed entries in that order and only then scans the documents it has not
  seen.  A document is noted when a request lexes it: the current document of a
  hover/references request, and the definition file a facts-based hover resolves
  into (the host's `hover_definition_entry_from_location` → `find_token_at`).
  Import-line, field-declaration, named-argument-label and keyword/builtin
  hovers resolve no such entry in the host — they render their own `source_uri`
  — so the hooks sit on the same arms and those files stay out of the index.
- **Candidates**: `reverse_import_dependents_for` is built over the documents
  the server knows — open, content-/token-touched, and (because `initialized`
  starts the background `index_workspace` thread) every `.mt` file under the
  workspace root.  A workspace-index hit outside that set is not a candidate.
- **The static arm** reproduces the host's artifact: the location pairs the
  resolved module's *file* with the method-name position in the file that
  *declares* it, so `rl.Color.hex_digit` reached through a receiver reports
  `std/raylib.mt` with the line inside `colors.mt`; each candidate reference is
  re-resolved the same way and kept only when it lands on the same location.
- **The same-file AST scan** walks identifier expressions (skipping ones a local
  binding owns), member accesses and module-level declaration names — so type
  positions (`ptr[Node]`, `i: int`) and named-argument labels are *not*
  occurrences, which a token scan cannot know.  An enum's or flags' member
  values are not walked either: the host's reflection walk reads `node.members`,
  which `EnumDecl`/`FlagsDecl` shadow with their own member list, so no
  descendant of those declarations is ever visited.
- **The scoped arm** is the same walk restricted to the binding's scope: a
  call's callee is not an occurrence (the host never binds `p` in `p(x)` to the
  parameter), and neither are labels, member names, destructuring bindings or
  nested-proc uses the host's binding resolution misses.
- **Builtins**: only the names the host's `facts.types` registers
  (`INSTALLABLE_BUILTIN_TYPE_NAMES` — the primitives and the handle types) make
  a name module-level.  The *generic* constructors (`ptr`, `array`, `own`,
  `ref`, `span`, `const_ptr`) do not, so a search on one of those falls through
  to the token index and finds type-position occurrences.
- **`includeDeclaration`** is honored per arm the way the host does it (the
  declaration arm, the static location filter, and the fallback's
  `find_definition_token_global` rejection).

**Scope-tracking follow-ups** the port forced, all general improvements in
`lsp/scope.mt`: a declaration's region end is now the nearest *later start line*
rather than the next list entry (the analyzer appends `emit`-expanded
declarations at the end of the file's list, out of source order); a statement's
last line covers every statement kind (an assignment, call or loop used to end
its scope early and hide the enclosing binding); and the binding walk descends
into `unsafe`/`defer`/`while`/`for`/`when` bodies.

Measured (SimpleGame, full matrix `--max-diffs 0`): references **267 → 9**,
documentHighlight 15 → 14, total **696 → 443**.  The references-only audit (915
requests, `--only references`) is at **1** (was 255): the one entry is a file's
first request, where the host's lazy facts are still nil and its handler falls
through to the token index while the self's synchronous facts take the
module-level arm — the documented "synchronous facts, no lag" difference.  The
full matrix's 9 are a knock-on of the remaining *hover* diffs: the host's hovers
resolve `Option.unwrap`, `Option.value` and `vec3.x`, which tokenizes `option.mt`
and `linear_algebra.mt`, while the self's hovers at those positions return null
or a local, so those files never enter its index.

**Two definition entries stay deliberately better.**  Where the host's binding
resolution misses a local (`total` inside `main`'s long body, `code` from a
destructuring `let`), its definition path falls back to the file's *first*
declaration of the name or to null; the self resolves the real binding.  That is
6 audit entries (2 positions × definition/declaration/typeDefinition); the same
positions' *hovers* agree with the host.

**Probe fixtures**: `tmp/probe-ws` (25 positions), `probe4`, `probe5`,
`probe6` are at **0 differing entries for references** in the full matrix, and
hover/definition/declaration/typeDefinition stay at 0; `probe2` keeps its 2
deliberate hover self-answers.

### LSP hover: the member-access order, the type-receiver location and the builtin arms (2026-09-28 session 8, second batch)

Three host behaviors `resolve_cursor` did not follow:

- **Member accesses resolve before the name tables.**  The host's
  `resolve_hover_info` runs `resolve_member_access_hover_info` *ahead* of the
  signature lookup, so a method reached through a receiver reports its defining
  module even when the name also resolves in this file.  The self-host ran the
  name lookup first, so `rl.Color.from_hex_str(…)` answered the local
  `extending` block's location; `resolve_cursor` now tries the value- and
  type-receiver arms first (and no longer returns early on a failed
  type-receiver lookup, so the name tables still get their turn).
- **The type-receiver location artifact.**  `module_member_binding_location`
  resolves the path from the receiver's *module name*, so a method an
  `extending` block in this document adds to an imported type reports
  `std/raylib.mt` (the module) with the line inside `colors.mt` (the
  declaration) — `resolve_type_method_hover` and `resolve_member_method_hover`
  now pair the module's file with the declaring line the same way.
- **The builtin specialization arms** (`builtin_hover_info`): `zero[T]` /
  `default[T]` / `reinterpret[T](value)`, the associated hooks
  (`hash[T](value) -> uint`, `equal[…]`, `order[…]`), and the type constructors
  (`builtin type ptr[int]`, `array[int, 3]`, `own[int]`, …) — with the host's
  per-name docs.  They answer *before* the `type <name>` table (only a
  *registered* type reaches that shape), and, unlike a language keyword, they
  carry no token-index location: `handle_hover` now applies
  `apply_hover_index_location` to keywords only.

Measured (full matrix, `--max-diffs 0`): hover **121 → 83**, definition and
declaration **95 → 72** each, typeDefinition **93 → 70**, total **443 → 336**
(the same member pipeline feeds all four).  The probe fixtures and the LSP
harness are unchanged (references 0; 30/30 capabilities + the 4 documented
entries).

**Residue, ranked** (336 entries): hover 83 — the prelude/inherent methods of
generic types (`Option.unwrap()` is still null: `resolve_member_method_hover`
has no signature for a type with no owning module, where the host's
`methods_for_receiver_type` merges `facts.methods`), `field name: cstr`-style
fields of workspace types (the host prints no `Defined at` where the self
prints one), `type parameter T`, attribute hovers, bare variant-arm
constructors (`Result.success(value: T)`, `MyOption.some(value: T)`) and enum
members (`Kind.c = 6`), and `let x: <error>` locals whose initializer is
`own[…]`/`Result[…]` (an analyzer gap); then definition/declaration 72 and
typeDefinition 70 (the same member shapes), documentHighlight 14, the small
classes (documentSymbol 5, semanticTokens 5, diagnostic 3, codeLens 1,
implementation 1, workspace/symbol 1), and references 9 (gated on the hover
residue).

**Session 9 close (2026-09-28)** — Track A closed.  The instrument first:
`tools/lsp_recovery_probe.rb` (new) drives both servers through six mid-edit
states — `n.` (+ an incremental `.`), `a.inner.`, an unterminated string, an
unterminated block, a half-typed `import`, a cut-off expression — and
byte-compares the pull diagnostics; `--check` exits non-zero on any difference
(corpus under `tmp/lsp-recovery/`).  Then A1 the JSON blob (the analyzer's
duplicate `missing-return` sema error — the host has only the linter rule —
removed, which also fixed `mtc build` refusing programs the host builds),
A2 the ` at <uri>:<line>:<col>` suffix (built in the LSP diagnostic conversion
from the document URI), A3/A4 the parser's panic-based unwinding
(`ParserState.panic` + the error token index; `recover_statement` /
`recover_top_level` / `recover_match_arm`, the local-decl rescue and the partial
`FunctionDef` rescue) with the lints that followed (the scope pass stopped
counting assignment targets as uses, dead-assignment's gates/message/severity,
`missing-return` after the scope pass, the outline's token anchoring).
**Counters**: recovery probe OK (6/6 byte-equal); audit 336 → 335 (diagnostic
3 → 2, hover 83 → 80 via the `proc(...)` rendering); references-only 0;
`cli:parity` 23/38/0 (`lint-warns` closed); lex 705/705, parse 701/0;
unused-import 609/608.  **Not emulated**: the host's nested declaration rescues
(a nested declaration dropped inside a block recovers as dropped, not as the
host's partial node) — revisit only if a fixture shows it.

### Recovery parity: the parser's unwinding, the diagnostic suffix and the blob (2026-09-28 session 9)

`tools/lsp_recovery_probe.rb` (the focused plan's A5) drives both servers through
a six-edit corpus of mid-edit states — the `n.` truncation (plus an incremental
`.`), an `a.inner.` truncation, an unterminated string, an unterminated block, a
half-typed `import`, and a cut-off expression — and byte-compares the pull
diagnostics of every state.  `--check` exits non-zero on any difference.  The
corpus workspace is written by the tool under `tmp/lsp-recovery/`.  All six cases
match now; the divergences were one root cause each:

- **A1 — the JSON-blob `message`.**  The self's *analyzer* reported its own
  `missing-return` sema error; because that message quotes `'main'`, the LSP
  conversion turned it into MarkupContent (`{"kind":"markdown",…}`).  The host
  has only the linter rule, so the analyzer check and its now-dead termination
  helpers are gone — which also fixes `mtc build`: the self used to *refuse* a
  program the host builds (a non-void function that does not always return).
- **A2 — the location suffix.**  `parse/error` and `lex/error` messages carry the
  host's ` at <uri>:<line>:<col>` (its `ParseError`/`LexError` constructors embed
  the path they were built with — the document URI under the LSP).
  `collect_diagnostics` now takes the URI, so push and pull agree; the CLI text
  is unchanged (the host strips the suffix there too).
- **A3/A4 — the recovery points and the recovered AST.**  The self's parser used
  to skip to a sync point *inside* the failing rule and keep parsing the garbage
  (hence the extra `expected end of statement` at the wrong position, the bogus
  `unknown field Sample.` node, and the lint set that followed it).  The host
  raises and unwinds to the nearest rescue instead, which substitutes a sentinel.
  `ParserState.panic` now marks a statement/declaration broken: the first error
  records the token it happened at, later errors in the same unit are ignored
  (the host's exception never runs them), and the recovery point —
  `recover_statement`, `recover_top_level`, `recover_match_arm`, the local-decl
  rescue, or the function rescue — rewinds to that token and synchronizes, or
  substitutes the host's node: a `LocalDecl` whose value is an `expr_error`, or a
  function declaration keeping its name (the host's partial `FunctionDef`).
- **The lints on recovered code followed**, not special-cased: the scope pass no
  longer counts a plain assignment target as a *use* (the host marks reads only),
  the dead-assignment rule skips declaration-origin writes and never-read
  bindings and carries the host's message and `warning` severity, and
  `missing-return` is emitted after the scope pass (the host checks each function
  once its scope frame pops).  The outline keeps the host's token anchoring: a
  declaration the parser drops still appears (a bare symbol, like the host's
  base pass), and a partial `FunctionDef` renders `-> void`.

Measured: recovery probe **OK** (6/6); `cli:parity` **23 match / 38 differ** (was
22/39 — the dead-assignment rule closed `lint-warns`); `sexpr_parity` lex
705/705 + parse 701 comparable / 0 differ; `unused_import_parity` 609/608 (the
documented `async_network_lobby.mt` residual); LSP harness 30/30 capabilities +
the same 4 documented entries; project audit **335 differ** (diagnostic 3 → 2,
every other counter unchanged); references-only audit **0**; fixtures at 0 for
hover/definition/declaration/typeDefinition/references (`probe2` keeps its 2
deliberate hovers); `test/mt` 60/0; bootstrap fixed point + 14/14; valgrind 0
errors on the recovery drive; the headless-Neovim smoke renders hovers.

Not emulated yet (the host has ~30 per-production rescues): the *nested*
declaration rescues (`parse_method_def`, the local-decl `else` variant, the
struct/union field loops) — a nested declaration dropped inside a block recovers
as a dropped declaration, not as the host's partial node.  The corpus and the
harness do not cover that shape yet; the focused plan's A3 keeps it as the next
recovery item.

**Track B, first batch (same session).**  Hover **83 → 80**: `Types.type_to_string`
rendered every function type as `fn(...)`, so a `proc`-typed local or parameter
read `fn(int) -> int` where the host prints `proc(int) -> int` (three entries in
`docs/language_baseline.mt`).  `ty_function.is_proc` now selects the keyword.
The hover residue is classified for the next batch (measured from the session-9
recording, 80 entries): **17** locals whose initializer the analyzer leaves
`<error>` (specialized calls `heap.must_alloc[ubyte](64)`, builtin generic
arm calls `Result[int,int].success(…)` / `Option[float].some(…)`, unary ops
`~mask_a`, tuple literals `(1, 2)`, method calls on `Result`); **15** where the
`*From <module>*` line differs (the annotation is rendered from the source text,
so an import alias leaks in as `vec` instead of `std.vec`, and a specialization
like `SoA[Point, 4]` loses the owner module); **19** self-null (enum/flags
members in a declaration body `Mask.a = 1`, bare variant-arm constructors
`Result.success(value: T)` with their named-argument labels, attribute targets
and applications, `type parameter T`, fields read through a `ref` receiver, the
implicit `this`, prelude/inherent methods on builtin generics); **5** nullability
(the host prints the *storage* type where the self prints the flow type: `var
handle: null (mutable)` vs `ptr[int]?`); 3 tuple/alias renderings, and the rest
the member-location artifacts.

**Session 10 close (2026-09-29)** — five batches (Track B, largest-first), audit
332 → 269.  (1) The host's C string-literal escaping: `String#inspect`'s `\xNN`
escapes absorbed the following hex digit in C, so the host-built binary crashed
on non-ASCII hover docs (`×`, `–`) with `string.as_str text must be valid UTF-8`;
the host now emits non-ASCII bytes raw.  (2) The analyzer's expression typing
(hover 80 → 46): unary `~`/`+`, tuple literals, `Type[args].arm(…)` instances,
imported specialization calls (`heap.must_alloc[ubyte](64)` → `own[ubyte]`),
bare builtin type receivers (`mat4.identity()`), builtin event methods, `get`,
`detach`; hover-side: guarded-local narrowing, module-less builtins render bare,
signature shape (`-> <ret>`), builtin arms take the definition index's location
— with three lowering-visible consequences the gates caught (an early-returning
member arm must still infer its receiver; a `Type[args]` receiver resolves
struct members as associated functions; member receivers project through
pointer-likes).  (3) `a9333965` the member resolution the new types exposed
(imported `extending` methods, builtin vector/matrix/quaternion fields,
`ref`/`ptr`/`own` projection).  (4) The variant arm constructors
(`Result.success(value: T)`, named-argument labels; hover 44 → 37).
(5) The `*From*` renderings (qualification at every level, prelude
`type Result = Result`; hover 37 → 32).  Full matrix 269; references 0;
examples 13/15 (the 2 async `__mt_loop_N` aborts documented).

### The host's C string-literal escaping (2026-09-29 session 10)

Hovering a builtin type (`mat4.identity()`'s receiver) killed the host-built
self binary with `string.as_str text must be valid UTF-8`, taking the LSP down
mid-audit.  Root cause: the host emitted `String#inspect`'s `\xNN` escapes, and
C's hex escape absorbs every following hex digit — `"4\xC3\x974 col"` compiles
to `4`, `0xC3`, `t` — corrupting the text and its recorded byte length.
`hover_docs.mt`'s `mat3`/`mat4` doc strings (`×`, `–`) are the compiler's only
non-ASCII literals, so every hover on those types died (and the same literal
was wrong in any `emit-c` output built from them, host or self).

The host now emits non-ASCII bytes raw (`c_string_literal` in
`c_backend/runtime_helpers.rb`, used by the literal-constant section, the
inline `mt_str` initializers and the static-assert message), byte-identical to
the self-host's `c_string_literal`.  Verified: `emit-c` on a non-ASCII fixture
and on `projects/mtc/src/mtc/lsp/hover_docs.mt`'s literal lines match byte for
byte; the headless-Neovim smoke renders the `mat4` hover with its `×` doc
through a real client.

### Track B, second batch (2026-09-29 session 10): the analyzer's `<error>` locals

Full matrix **332 → 275** (hover **80 → 37** by the batch's end; definition and
declaration 72 → 70 each, typeDefinition 70 → 68, references **9 → 0**).  The
per-class numbers in this record are `--only` runs, which drift ±10 from the
full matrix (the host warms its caches as the audit proceeds); the full-matrix
table is the authoritative one.

**The analyzer's expression typing.**  `infer_expr_inner` left these `<error>`,
so a hover printed `let x: <error>` where the host resolved the type:

- `~mask_a` — `infer_unary` handled only `not`/`-`; `~`/`+` now yield the operand
  type (the host's `infer_unary`).
- `(1, 2)` — a tuple literal built no type; `infer_tuple_literal` mirrors
  `Types::Registry.tuple(element_types, field_names:)` (named elements included).
- `Result[int, int].success(value = 7)` / `Option[float].none` — a *type
  instance receiver*: `type_instance_receiver` resolves the specialization to a
  module-qualified instance (`std.result.Result[int, int]`), so the hover's
  `*From std.result*` line follows.
- `heap.must_alloc[ubyte](64)` — an imported generic function called with
  explicit type arguments (`check_imported_specialization_call`): the type
  arguments substitute into the declared return type (`own[ubyte]`).
- `mat4.identity()` — a bare builtin type name as receiver
  (`static_builtin_type_name`): the member resolves on the type itself, wherever
  its `extending` block lives (`std.linear_algebra`).
- `ready.subscribe(listener) else:` — the builtin event methods
  (`event_method_call_type`): `Result[Subscription, EventError]`, so the guard
  binding narrows to `Subscription` like the host.
- `get(arr, idx) else:` — the `get` builtin, `ptr[T]?`.
- `detach f()` — `Handle`.

**The hover-side knock-ons** (each one visible in the same `<error>` entries):
`unwrap_nullable_type` is public and a guarded local's hover applies it (the
host prints the guard's *success* type); `Handle`/`Subscription`/`EventError`
are module-less builtins and render bare (`type_render`); `format_fn_signature`
prints the declared parameter list with no `, ...` marker and always
`-> <return-type>` (the host's `method_signature`); the builtin type/call arms
also take the workspace definition index's location, like the host's
`resolve_hover_info` fallback (`let ptr: ptr[int]?` gives `builtin type ptr[int]`
its `Defined at` line).

**Two lowering-visible consequences the gates caught** (the analyzer is
lowering's type oracle):

- An early-returning member arm must still infer its receiver — the event-method
  arm now records the receiver's `mt_event_*` type, which the lowering reads via
  `method_receiver_type`; without it a `match` on a `subscribe` call silently
  lowered to nothing (`test_stateful_event_listener_receives_state_pointer`).
- A type-instance receiver must resolve a *struct's* member as an associated
  function (`BinaryHeap[T].parent_index(child)` → `ptr_uint`) and only answer
  the instance itself for a variant/enum/flags arm; treating every instance
  member as the instance broke four `test/mt` builds.
- Member/method receivers project through pointer-likes (`own[T]`/`ptr[T]`
  member reads and methods resolve on the pointee).  `own[SleepState].ready`
  compiled before only because the initializer was `<error>`; the projection is
  gated on the pointer type itself declaring no method of that name, so
  `ptr[T].load()` (`extending ptr[T]` in `std.mem.ptr`) still resolves on the
  pointer.

The residual hover is the classification the first batch recorded: the
`*From <module>*` renderings from the *source-text* annotation (15), the
self-null member/attribute/`this`/prelude-method arms (19), the nullability
renderings (5) and the member-location artifacts, plus the small classes.

### Track B, third batch (same session): imported methods and builtin fields

The same three member-resolution gaps the second batch's types exposed:

- **Imported methods** (`vec3.cross`, `mat4.identity`).  The host's
  `methods_for_receiver_type` merges the enclosing module's methods with every
  *imported* module's, so a builtin receiver's method resolves through its
  `extending` block wherever it lives.  `imported_type_method_hover` walks the
  analysis' imports, analyses each module, looks the method up by type name and
  stamps the result with the declaring module's URI; the declaration line comes
  from `find_method_line_in_type`, which prefers the `extending` block naming
  the receiver's type (`std.linear_algebra`'s third `identity` is mat4's, not
  mat3's).
- **Builtin vector/matrix/quaternion fields** (`vec3.x`, `mat4.col0`,
  `quat.w`): `field x: float` with no location, the host's
  `Types::Vector`/`Matrix`/`Quaternion` field tables.
- **Receiver projection** for the *hover* path: the receiver's type projects
  through `ref`/`ptr`/`own` first (`project_pointer_receiver` is public), so a
  field read on a `ref[vec3]` resolves the vector's field.

Measured (`--only` runs): hover 46 → 44, definition and declaration 67 → 66,
typeDefinition 66 → 65; the probe fixture `tmp/hover-probe5` 10 → 8; no new
diffs anywhere (diff-set compared per entry).  Gates: harness 30/30 + 4;
recovery OK; test/mt 60/0; bootstrap fixed point + 14/14; cli:parity 23/38/0
with the same diff set; sexpr 705/705 + 701/0; valgrind clean; the Neovim smoke
renders `vec3.cross` and `mat4.identity` with their std locations.

### Track B, fourth batch (same session): variant arm constructors

The host's `find_variant_arm_in_types` and `variant_arm_constructor_info`:

- **A bare arm name** (`Result.success(value: T)`, `Primitive.circle(radius:
  float)`, `MyOption.some(value: T)`) renders `Type.arm(field: T, …)` — the
  file's declared variants scanned in reverse order, then the prelude variants
  from std.result / std.option (the host's prelude-installed types), ahead of
  every name lookup (`variant_arm_name_hover`).
- **A named argument inside an arm constructor** (`value: T`, `radius: float`)
  renders `field_name: field_type` with no location, including the generic form
  `Result[int, int].success(value = 7)` (the `[…]` group before the dot is
  walked back) and the `Primitive.circle(radius = 2.0)` form
  (`variant_arm_label_hover`).

Full matrix **275 → 274** (hover 46 → 37 `--only`, 37 in the full matrix);
definition 70, declaration 70, typeDefinition 68, references 0, the rest
unchanged.  No new diffs (hover diff sets compared entry by entry).  Gates:
bootstrap fixed point + 14/14, test/mt 60/0, cli:parity 23/38/0 (same diff set),
sexpr lex 705/705 + parse 701/0, harness 30/30 + 4 documented entries,
recovery OK, fixtures unchanged, valgrind clean, Neovim smoke renders
`Result.success(value: T)` and `value: T`.

### Track B, fifth batch (same session): the `*From*` renderings

The annotated-local hover rendered the *source text* of the annotation, so an
import alias leaked in as `vec` where the host spells the resolved module, and a
specialization's type arguments carried no module at all:

- `annotated_type_text` now qualifies at every level: a bare name through the
  module's type table (a type declared in the file being hovered spells the
  file's own module, the host's single-file `Types::Struct#to_s`), an
  `alias.Type` spelling through the import alias's real module, and each type
  *argument* recursively — so `vec.Vec[Point]` renders `Vec[Point]` with the
  host's `*From std.vec, <module>*` and `SoA[Point, 4]` gains its owner module
  from the argument.  A registered primitive (`int`, `vec3`) stays bare.
- The prelude types render `type Result = Result` with `*From std.result*`:
  `type_hover_signature` consults `type_render.prelude_type_module` (now
  public), and the builtin-docs arm of `resolve_decl_hover` uses it for a
  prelude type with no declaration in the file.

Full matrix **274 → 269** (hover 37 → 32); no new diffs (hover diff sets
compared entry by entry; `tmp/probe2`'s two `*From*` hovers closed, its two
deliberate self-answers remain).  Gates: bootstrap fixed point + 14/14,
test/mt 60/0, cli:parity 23/38/0 (same diff set), sexpr lex 705/705 + parse
701/0, harness 30/30 + 4 documented entries, recovery OK, fixtures unchanged
for hover, valgrind clean, Neovim smoke renders `Vec[…Point]` with
`*From std.vec, …*`.

**Session 11 close (2026-09-29)** — five batches + a follow-up; six commits
(`4abd6ff8` field locations from the host's token scan — a `public struct`'s
fields carry no location and a field declaration hover renders the *resolved*
type; `12527c82` the member arms with `variant_types`/`const_eval_int`;
`48e80cd0` attributes/type parameters/`this`; `d51af37a` the `this` and
annotated-local receivers via `Analysis.local_decl_types`; `2bf28f10` the method
`-> void` and `_` as a discard; `3568fef1` the attribute arm kept off the
definition path).  Hover **32 → 14** (18 closed, none added); the member pipeline
followed: definition/declaration **70 → 61** each, typeDefinition **68 → 59**
(1 traded at `lb@1915:25` — the host's definition index answers a different
function's `p`); audit **269 → 224**.  Each batch verified by a focused
`--only hover` re-scan with the diff *set* compared entry by entry (the full
matrix is authoritative; `--only` drifts ±10).  Next: hover's 14 (the location
artifacts, the nullability four, stage 11c's three, the union function field,
the member chain's third segment, the nested-`unsafe` binding), then
definition/declaration 61 and typeDefinition 59.

### Track B, sixth through tenth batch (2026-09-29 session 11): member arms, attributes, receivers, field tokens

Hover **32 → 14** in five batches, each verified by a focused `--only hover`
re-scan whose diff *set* was compared entry by entry (the full matrix is
authoritative for the class; `--only` counts drift ±10).  No batch introduced a
new diff.

1. **A field's location is the host's token scan, not the AST's field.**  The
   host's `find_field_token_in_type` / `find_field_token_in_body`
   (`lsp/server/definition.rb`) are now ported as
   `first_non_trivia_on_line` + `find_field_token_in_body` +
   `find_field_token_in_type` in `lsp/navigation.mt`.  The scan stops at the
   first line-leading token at or left of the `struct`/`union` keyword's column,
   so a field of a `public struct X:` (fields at column 5, the `struct` keyword
   at column 8) is never reached: the host prints **no** `Defined at` line for
   those fields, and the self used to add one.  The three hover arms that report
   a field's location (its own declaration, a named-argument label, a field
   read) now take it from this scan, and the declaration hover renders the
   field's *resolved* type (`field parent: ptr[Node]?` + `*From node*`) instead
   of the source TypeRef's first name part.  Closed: `main.mt@18:36`,
   `main.mt@18:55`, `node.mt@1:4`, `node.mt@2:4`, `node.mt@6:20`.
2. **The member arms.**  `bare_member_hover` is the host's
   `find_member_in_types`: a bare identifier naming an enum/flags member renders
   `Type.member = value` for the file's *last-declared* type with that member,
   with the value folded by `analyzer.const_eval_int` (now public, refactored to
   take the `const` table so consumers outside the analysis pass can use it) —
   hence `Kind.c = 6` and `Kind.a = 0`.  The static-member arm no longer renders
   a *variant*'s arms as enum members: `Context`/`Analysis` carry
   `variant_types` (set by `variant` declarations and by the prelude
   `Option`/`Result`), so `Result.success as s:` resolves the arm constructor
   `Result.success(value: T)` and `TokenKind.ident(name: str)`.  The flat local
   fallback in `resolve_local_hover` is now bounded by the *enclosing*
   declaration (`enclosing_decl_index`), so a same-named local of an earlier
   function can no longer answer for a position in a later one (which is how
   `@a` in `struct Buffer[@a]` used to resolve to another function's `let a`).
   Closed: `lb@141:4`, `lb@1757:15`, `lb@568:15`.
3. **Attributes, type parameters and `this`.**  `type_parameter_signature`
   (the host's `type_parameter_hover_signature`: `[T]`, `[T implements I]`,
   `[N: int]`, and no answer for an attribute's target list),
   `attribute_target_token` (`attribute target callable`) and
   `declared_attribute_hover` (`attribute [callable] traced(tag: str)`, with the
   *module's* location — line 1 of the declaring file, as
   `module_definition_location` does), plus `this_receiver_hover`
   (`parameter this: vec3 (immutable)`), which answers only inside an
   `extending Type:` method: a struct's own methods get no completion frame in
   the host either, so they stay null.  Closed: `lb@228:25`, `lb@364:19`,
   `lb@236:10`, `lb@275:51`, `lb@1545:33`.
4. **Receivers: `this` and annotated locals.**  `type_of_value` resolves `this`
   through `this_receiver_name` / `this_receiver_type` (the enclosing
   `extending` method's target type), and the analyzer now records an annotated
   local's *declared* type in `Analysis.local_decl_types` (keyed by declaration
   line; the host reads the same type off its scope binding), which
   `local_type_at_line` uses instead of returning none.  `enclosing_decl_index`
   picks its declaration by *line*, not by list position: the analysis appends
   `emit`-expanded declarations out of source order.  Closed: `lb@1822:44`
   (`this.radius`), `lb@1957:6`, `lb@1967:26` (`r.top_edge` through a
   `var r: Rectangle`).
5. **Two leftovers.**  The method branch of `resolve_name_in_analysis` always
   prints the return type (`function destroy() -> void`; the host's
   `method_signature`), and `_` is a discard rather than a binding
   (`find_local_in_block`, `local_stmt_declares`) — the analyzer registers no
   `_` binding, so a `let _ = …` hover is null in the host.  Closed:
   `node.mt@9:13`, `mst@457:8`.

Measured (full matrix re-run at close, the authoritative numbers): the audit
**269 → 224** differing entries — hover **32 → 14** (18 closed, none added) and
the member pipeline the hover work feeds: definition **70 → 61**, declaration
**70 → 61**, typeDefinition **68 → 59** (10 closed each; 1 traded per class at
`lb@1915:25`, where the host's definition index answers a different function's
`p` and the self's flat fallback now answers the enclosing function's — the
position's *hover* location became the host's in the same batch).  The small
classes are unchanged (documentHighlight 14, diagnostic 2, documentSymbol 5,
semanticTokens 5, codeLens 1, implementation 1, workspace/symbol 1), references
stay **0**.  Fixtures unchanged (`probe-ws`, `probe4`–`probe6`, `fieldprobe`,
`crash1`, `thisprobe` at 0 differing entries; `probe2` keeps its 2 deliberate
self-answers).  Gates: bootstrap fixed point + 14/14,
`test/mt` 60/0, `cli:parity` 23/38/0 (same diff set), sexpr lex 705/705 + parse
701/0, `unused_import_parity` 609/608 (the documented `async_network_lobby`
residual), harness 30/30 capability keys + the 4 documented entries, recovery
probe OK, references-only audit 0, valgrind clean on the hover drive
(`ERROR SUMMARY: 0 errors from 0 contexts`), the headless-Neovim smoke renders
`parameter this: vec3 (immutable)`, the `quat` docs and `Kind.a = 0`.

The hover residue (14) and what each needs: the **location artifacts** — a
method call resolving to a different declaration of the same name in
`std/graph.mt` (`release()`), `take_damage`, `type quat`'s missing
`std/linear_algebra.mt` location, and a `std/spatial.mt` parameter's location
needing the host's cross-file definition index; the **4 nullability** entries
(the host prints the *storage* type where the self prints the flow type — the
host's completion snapshots carry the analyzer's continuation refinement);
**destructuring bindings** (`let (a, b) = result` — the analyzer binds each name
to `ty_error`, so the self has no element type to print); a **match-arm payload
binding** (`local p: Option[(str, str)].some payload`, the queued stage 11c); a
**union field of function type** (the host renders the bare `fn ` — its union
field table loses the signature); a **member chain's third segment**
(`r.top_edge.start`, needing the host's `member_access_chain_at` walk); and a
binding inside **nested `unsafe` blocks** (`let b = read(inner)` under a second
`unsafe:`).

**Session 12 close (2026-09-29)** — the definition pipeline; the session began
with the classification the previous review asked for: of the 224 remaining
entries, 181 were definition/declaration/typeDefinition, and 45–49 of the 61 per
class were one shape.  Three commits porting the host's local definition rule
(its completion bindings carry no AST node, so a definition answers the *file's
first* same-named `let`/`var`/`for` declaration before the cursor —
`find_local_declaration_ast_node` + `first_local_declaration`/
`first_local_in_stmt(s)`; destructured names and `as` bindings never match; the
bare member and variant-arm arms are hover-only; the `is_builtin_name?` bail),
the import alias's member declaration (`find_definition_token_in_file`, the
token-pair scan, definition-only), and the receiver-typed method line
(`find_method_line_in_type` in both method paths).  Definition **61 → 5**,
declaration **61 → 5**, typeDefinition **59 → 4** (closed 56/56/55, none added;
audit 224 → 60 → 56).  The 5/5/4 residue is the cross-file/index location family
(Track C1).  Next: Track C1, then hover's remaining classes, then B4 and C2–C5.

### Track B, eleventh and twelfth batch (2026-09-29 session 12): the definition pipeline

The session started by *classifying* definition/declaration/typeDefinition instead
of guessing: 181 of the 224 remaining entries, and 45–49 of the 61 per class were
one shape.  Classifying paid: the audit went **224 → 60**.

1. **The host's *local* definition rule.**  Its completion bindings
   (`Bindings::ValueBinding`) carry no AST node, so a definition request for a
   name bound in scope goes through `find_local_declaration_ast_node`, which walks
   the whole file and answers the **first** `let`/`var`/`for` declaration of that
   name *before* the cursor — not the enclosing binding.  An editor therefore
   jumps to an unrelated same-named local earlier in the file; that artefact is
   what the port reproduces.  `resolve_local_definition` gates on the scope walk
   (`local_binding_line`, the same region model the hover's own rendering uses)
   and then walks the AST (`first_local_declaration` → `first_local_in_stmt(s)`):
   declarations in order, statements in source order including nested bodies, the
   `for` bindings before their body, and — as in the host — destructured names and
   `as` bindings are not a `LocalDecl`'s own name, so they never match.
2. **The hover-only arms must not answer a definition.**  `resolve_cursor`'s
   `for_hover` flag (from session 11's attribute fix) now also gates the bare
   member arm (`flags Mask`'s `b` used to answer for a local `let b`) and the
   variant-arm arm; the definition pipeline has neither, so a definition request
   for such a name keeps resolving through the local rule and the index.
3. **The builtin gate.**  The host answers *nothing* for a name that resolves
   through `builtin_hover_info` (`is_builtin_name?`) — before both its binding arm
   and its index arm.  `builtin_name_at` shares the self's builtin
   specialization/hook/type-constructor arms with the hover, and
   `handle_definition` responds null there instead of letting the index answer
   another open document's `let ptr: ptr[int]?`.
4. **An import alias's member declaration.**  The host's definition tries
   `module_member_definition_location` for the alias's *own* name first
   (`find_definition_token_in_file`: the first token a definition keyword
   introduces with that lexeme) and only then the module file: `hash` finds
   `function hash` in `std/hash.mt`, `ptr` the `extending ptr[T]:` block in
   `std/mem/ptr.mt`.  `import_alias_member_declaration` ports the token-pair scan
   behind the alias arm (definition-only: a hover answers the module, as the
   host's hover does).  The alias arm for `alias.Member` now also requires an
   identifier token under the cursor, so an `alias.member` spelled inside a
   comment defines nothing.
5. **A method's declaration line follows the receiver's type.**
   `resolve_member_method_hover` and `resolve_type_method_hover` resolved the
   receiver's type for the signature but used the type-blind `find_method_line`
   for the location, so `dg.release()` on a `DenseGraph[str]` pointed at
   `extending Graph[T]`'s `release` (std/graph.mt:345) instead of
   `extending DenseGraph[T]`'s (:699).  Both tails call
   `find_method_line_in_type` now.

Measured (full matrix, authoritative): the audit **224 → 60 → 56** —
definition **61 → 5**, declaration **61 → 5**, typeDefinition **59 → 4**
(closed 56/56/55 in total, none added), hover **32 → 13** (the last one the same
`release()` position), the small classes unchanged, references **0**.  The
navigation residue is five positions in all three classes, all cross-file/index
location shapes: an interface method's own token (`lb@181:22`, take_damage),
`type quat`'s missing `std/linear_algebra.mt:237` and `parameter idx`'s
`std/spatial.mt:125` (the host's cross-file definition index reaching files the
audit never opened), `start` (`lb@412:24`, `std/graph.mt:363`) and a field's
`parent` (`node.mt@2:4`, the host answering `std/binary_heap.mt:49`) — the last
four are the same index-scope family.  These are Track C1's work.

**Session 13 close (2026-09-29)** — Track C1: the host's cross-file definition
index (the `@definition_candidate_uris` / `@definition_names_by_uri` registry;
`find_definition_global` over the candidates — preferred document first with the
cursor filter, then warm order — and the **hover-driven** warm
(`hover_definition_entry_from_location` → `find_token_at` → `get_tokens` →
`get_content`), found by tracing `get_content` with a `RUBYOPT` hook instead of
guessing) and the index walk at the workspace root (`workspace_index_roots`) —
cold start (`tools/lsp_cold_start.rb`, new): SimpleGame **2723.5 → 213.3 ms**,
one-file project **2455.1 → 2.3 ms**.  Plus the interface method's own
declaration line, the implementation pipeline, typeDefinition's early null and
block-statement bindings; a crash the session caused and fixed (a `Map`-stored
`Vec` mutated through a `ptr` without write-back).  Definition/declaration/
typeDefinition **5/5/4 → 0**, implementation **1 → 0**, hover **13 → 9**,
documentHighlight **14 → 1**, audit **56 → 37 → 25**; the same session's second
push (codeLens and workspace/symbol from the token-pair symbol list, `this`
scoped to its method, the token scanner's rules) took the audit **25 → 22** and
the token positions **952 → 676**.  The synthetic `--only references` mode is
pacing-coupled (the host's background indexing depends on the self's speed) —
never quote its counts; the full matrix is the measure.

### Track B, thirteenth batch + Track C1 (2026-09-29 session 13): the cross-file definition index, the interface method, block bindings

Session 12 left 56 entries, seven of them the C1 family above.  The session found
the host's mechanism by *tracing* it rather than guessing: a `RUBYOPT` hook on
`WorkspaceCaches#get_content` over a full audit shows the host reading std module
files **from the hover path** — `hover_definition_entry_from_location` renders a
resolved location through `find_token_at` → `get_tokens` → `lex_document` →
`get_content`, and `get_content` is what inserts the path into
`@indexed_documents`, the definition index's candidate set.  So the index grows
with the files a hover resolves *into*, in request order (the same reason a full
run's `workspace/symbol` lists 34 documents: the 7 workspace files plus 27 std
modules).  Guessing "the loader read them" instead produced a 249-entry audit
(all hostile: `host=null, self=std`) and taught the second half of C1.

1. **The candidate registry** (`lsp/definition_index.mt`): the host's
   `@definition_candidate_uris` and `@definition_names_by_uri` (its answer and
   miss caches stay unported, as before).  `warm_names` registers a document's
   declaration names from the same cheap line scan the host's
   `DEFINITION_NAME_REGEX` uses (no lexing); `candidate_paths_for` answers the
   documents that declare a name in warm order; `forget` drops a document's
   entries on an edit and `drop_names`
   writes the shortened Vec back into the map (a Vec is a value — mutating one
   through a `ptr` without write-back left the map holding a stale length, which
   is what the session's first crash was: the harness's `didChange` stress step
   aborted with `string.as_str text must be valid UTF-8`).
2. **`find_definition_global` searches the index's candidates**, not "the open
   documents": the requesting document first with the cursor as the position
   filter, then warm order.  The **warm** happens where the host's does —
   `note_hover_definition_file` (the hover hook that already mirrored
   `find_token_at` for the identifier index) now calls
   `warm_definition_document`; `open`/`change`/`close` warm the document itself,
   and the workspace index build warms the workspace tree.  Warming anywhere else
   is visible: warming every module the loader read added 172 entries, and
   warming on every `note_document_tokens` moved the synthetic references-only
   mode off its 0 with std occurrences.
3. **The index scope** (`Workspace#workspace_index_roots`): the workspace
   *symbol* index walks the workspace root (plus the package's source root);
   `module_roots` stays wider for import resolution only.  Before, a project
   outside the compiler tree indexed the whole compiler tree at the first
   index-needing request.  `tools/lsp_cold_start.rb` (new) measures spawn → the
   first `workspace/symbol` response with the audit's file set; against a
   session-12 binary built from the same tree: SimpleGame **2723.5 → 213.3 ms**,
   a one-file fresh project **2455.1 → 2.3 ms**.
4. **A method's own declaration token answers its own line**
   (`method_declaration_at`): the host's `method_binding_at_token` matches the
   *binding's* AST against the cursor, so the interface's `editable function
   take_damage` answers the interface's line even though an `extending` block
   implements it — the self answered the implementation's line for hover,
   definition, declaration and typeDefinition at `lb@181:22`.
5. **The implementation pipeline** (`handle_implementation`): an interface
   method's own declaration token answers each implementing type's method
   (`interface_method_declared_at` + `append_method_implementation_locations`,
   which walks the open documents' `implemented_interfaces` and reports each
   implementing type's declaration line through `find_method_line_in_type`), and
   only a type that really declares the method answers — a generic constraint
   (`T implements Damageable`) has none, as the host's
   `methods_for_receiver_type(...)[name]` lookup does.
6. **typeDefinition's early return**: `resolve_type_definition_location` returns
   the *current* module's `module_member_definition_location` for a name in
   `facts.types` and stops — an imported type with no declaration token here
   (`quat` in a file that only uses it) answers null rather than the index.
7. **Bindings inside block statements**: `find_local_decl_at_line` descended into
   blocks, `if`, `while`, `for` and `match` only, so a hover on a binding inside
   `unsafe:`, `defer:`, `when:` or an error block answered null (the scope walk
   already collected them).

Measured (full matrix, authoritative): the audit **56 → 37** — definition
**5 → 0**, declaration **5 → 0**, typeDefinition **4 → 0**, implementation
**1 → 0**, hover **13 → 9**; documentHighlight 14, documentSymbol 5,
semanticTokens 5, diagnostic 2, codeLens 1, workspace/symbol 1 unchanged,
references **0**.  The hover residue is now: 4 nullability renderings
(`mst@25:7`, `@28:20`, `@205:7`, `@404:7` — the host prints the flow-refined
type where the self prints the declared one, the analyzer's continuation
refinement), 2 destructuring bindings + a match-arm payload (`lb@1861:23`,
`lb@1931:25`, `lb@1915:25` — stage 11c), a function-typed field's `fn `
(`lb@1127:9`, the host's `Types::Function#to_s`, queued as the compiler stages'
function-type names item), `type quat`'s missing std location (`lb@1653:24` —
the index does not reach `std/linear_algebra.mt` in the hover order the audit
produces), and a member chain's third segment (`lb@1958:16`).  The synthetic
references-only mode moved 0 → 56 in the same session, but **every one of the
916 self answers is byte-identical to the previous binary's** — the mode's
counts are pacing-coupled (the audit alternates host/self requests, so the
self's changed speed shifts the host's background indexing), and the full matrix,
where references are 0 in every run, is the authoritative measure.

Gates: bootstrap fixed point + 14/14 self-tests, `test/mt` 60/0, `cli:parity`
23/38/0, sexpr lex 705/705 + parse 701/0, the harness 30/30 + the 4 documented
entries (a regression the session caused and fixed: a map-stored Vec mutated
through a `ptr` without write-back corrupted the definition index and the
harness's `didChange` stress step aborted), recovery probe OK, the fixtures
identical to the session-12 binary's diff sets (hover-probe4 *gains* 6 closed
navigation entries), valgrind 0 errors on the LSP drive, and the headless-Neovim
smoke renders the `quat` hover.

### Track B, fourteenth batch (same session): documentHighlight's binding node set

The host's `documentHighlight` tries `scoped_local_reference_locations`, then
`rename_target_binding_id` + `scoped_binding_occurrence_ranges` — both list only
the AST identifier nodes bound to a resolved *binding* — and only then falls back
to a plain token scan.  Named-argument labels, member names after a dot, a call's
callee and a destructuring pattern's name are not nodes it binds, so a scoped
answer never contains them; the self's token scan with a line-range scope filter
listed all four (that was 12 of the 14 entries, `lb@704:67` and `lb@1545:33`
aside).  `unbound_occurrence` now filters them out of the scoped arm's
occurrences, mirroring the host's node kinds.  Measured (full matrix): the audit
**37 → 25**, documentHighlight **14 → 2** (12 closed, none added); the single
survivor (`lb@704:67`) needs the host's *carried-forward* binding resolution — a
label token resolves to a binding that is out of scope at that line — which the
self's region-based scope walk deliberately does not reproduce.

### Track B, fifteenth batch (same session): code lenses, workspace symbols, `this`, and the token scanner

1. **`this` is scoped to its method** (`enclosing_method_span`): the host binds the
   implicit receiver per method, so only the enclosing `extending` block's instance
   method's occurrences answer — the earlier token scan lit up every method of every
   receiver.  documentHighlight **2 → 1**.
2. **Code lenses and workspace symbols are one port.**  The host's
   `extract_symbols_from_tokens` — every identifier a declaration keyword introduces,
   with its LSP SymbolKind, in document order — now lives in `lsp/definition_index.mt`
   (`SymbolEntry`, built while the token-pair index is warmed, `symbols_for`), together
   with the warm order of its documents (`warmed_paths`, the host's
   `@indexed_documents.keys`).  `handle_code_lens` lists the document's `function`
   symbols, which also reaches the nested declarations of a `when` branch and the
   `emit`-expanded functions an AST walk over the top level missed (4 lenses), and
   `handle_workspace_symbol` walks the indexed documents then the open ones, filtering
   by a case-insensitive name substring — the host's `all_documents`, with no cap and no
   root filter.  Measured: codeLens **1 → 0** (145 lenses byte-equal) and
   `workspace/symbol` **1 → 0** (the 3374-entry answer byte-equal).  The codeLens
   handler no longer parses (the host's symbol list is lexical), which also drops its
   `-32800` error path for a mid-edit file.
3. **The token scanner** (`compute_token_data`): a *keyword* module-path segment
   (`import std.async as aio`) renders `namespace`; a character literal gets no entry
   (the host's classifier has no arm for one, and the self used to emit `string`); a
   keyword before a colon — a declaration name, or a `null` ending an `if …:` line — is
   a property, as is a keyword after a dot; a heredoc is emitted **one entry per line**
   (only the embedded-language tags the host leaves to the editor grammar are skipped;
   the self dropped every heredoc); and a *declared* type name in a type-argument
   position drops the `defaultLibrary` modifier (`Vec[int]`), while a builtin
   constructor keeps it (`null[ptr[int]]` — the host's `known_type_name?` counts only
   the facts' types).  The five files still differ as whole streams, so the class
   counter stays 5; a position-keyed comparison of the full matrix (a token-index diff
   misleads once the streams shift) shows the differing positions **952 → 676** (276
   fixed, 0 traded).  The residue is a longer list of shapes — import-alias receivers,
   `emit`-expanded declarations, variant payload fields, `typeParameter` renderings,
   and scope-aware binding resolution for a name that is both a parameter and a local.

Measured (full matrix, authoritative): the audit **25 → 22** — codeLens 1 → 0,
workspace/symbol 1 → 0, documentHighlight 2 → 1; hover 9, documentSymbol 5,
semanticTokens 5, diagnostic 2 unchanged.  `documentSymbol`'s host answers are
*timing-coupled*: the module hierarchy (`docs` → file) appears only once the host's
module-name index is warm, so its five entries alternate between "wrapped" and
"unwrapped" shapes between runs; the self's outline matches the unwrapped shape's
symbol set exactly (118 symbols on `data_structures.mt`, same names and kinds).

**Session 14 close (2026-09-30)** — the token classifier's *facts*:
scope-resolved bindings (`Binding.kind` / `function_level`; the host's snapshot
rule — only parameters and locals declared directly in a function body, and only
from a later line), the static-member table (`<Type>.<member>`), type-parameter
scopes, the type-position/dot-receiver/specialized-call arms, f-strings and
multi-line strings, attribute-name overrides.  Token positions **676 → 5**,
semanticTokens **5 → 1** (four of the five files byte-equal), audit **22 → 18**.
Continuation (the outline's wrapper and key order): the module wrapper, the
host's per-shape key order and locals in every block apply only when the host
wraps `docs/data_structures.mt` (its first-file warm artifact); the remaining
four outlines need the enrichment (the `extending` block's symbol merge +
`rl.Color` naming, the locals' flow-refined types, the `when`-branch
declarations, the function-type rendering).  Next: the three semantic-token facts
(`callable_value_identifier_sites`, `callable_field_member_access?`,
`dot_nested_type_member?`), then hover's 9 and B4's classes, then C2–C5 and
D2/D3.

### Track B, sixteenth batch (2026-09-30 session 14): the token classifier's scope and facts

The five files' token streams differed in **676 positions** at session 13's close.
This batch ported the host classifier's *facts* rather than adding shapes one by one:
the streams are now **5 positions** from byte-equal (`data_structures.mt`,
`memory_stress_test.mt`, `colors.mt` and `main.mt` are byte-equal) and the class
counter went semanticTokens **5 → 1** — the audit **22 → 18** (closed 4, added 0).

1. **Scope-resolved bindings** (`lsp/scope.mt` + the scanner).  The scanner's
   `param_names`/`readonly_names` were flat file-wide name sets; the host resolves the
   *innermost binding in scope* (`local_semantic_value_binding`) and reads its kind.
   `Binding` grew `kind` (param / immutable / mutable — the host's `ValueBinding#kind`)
   and `function_level`, and `binding_kind_at` reproduces the host's snapshot facts:
   only parameters and locals declared *directly in a function body* resolve — a local
   bound inside `if`/`while`/`for`/`match`/`unsafe`/`defer` and a `for`/match-arm
   binding are absent from the snapshot the classifier reads — and the binding must be
   declared on an *earlier* line (a name used inside its own declaration,
   `let ptr: ptr[int]?`, is not in the snapshot yet).  A parameter declaration token
   carries the declaration modifier, and the `in` of a `for v in values:` line answers
   the host's `parameter_declaration_token?` there too (it sits in
   `FOREIGN_PARAM_MODE_TOKENS`).
2. **Static members** (`collect_static_members`).  `<Type>.<member>` keys of every
   *static* method — the file's own and each resolved import's, bare and
   alias-qualified, mirroring the host's `methods_for_receiver_type` merge — tell a
   static call (`NPC.max_hp()`) from a variant arm (`Option.some(...)`): a type-name
   receiver (type arguments and a module path seen through) renders `method` for a
   static member and `enumMember` for anything else.
3. **Type parameters** (`scope.collect_type_param_scopes`).  Each declaration's
   `[T, U]` names are in scope over its line range (an `extending Vec[T]` block's
   receiver arguments per method), so a declaration token renders `typeParameter` +
   declaration and a reference in a type position (a type-argument list, after
   `:`/`->`) renders `typeParameter`; the scanner gained the keyword forms
   (`keyword_lifetime_or_type_param`, `keyword_type_annotation` — `[@a]`,
   `x: proc() -> int`).
4. **Type positions and calls.**  A name in a type-reference position (`:`/`->`/`as`,
   `= B` on a `type`-headed line, a type-argument list) resolves as a type — a builtin
   with `defaultLibrary` — *before* the binding and imports arms, and a *receiver
   before a dot* is a type or a namespace before anything else (`Option.some` →
   `type:0`).  A specialized call (`span[int](...)`, `zero[int]`, `hash[int](...)`)
   counts as a call shape, a bound value shadows a same-named function at a call site,
   and a builtin name resolves as a type before an import alias of the same name.
5. **Format strings and multi-line strings.**  An f-string's literal runs render
   `string` while each `#{…}` expression is re-lexed, shifted to the document's
   coordinates (so a scope lookup sees the file's bindings) and classified, its format
   spec lexed too (the host's `fstring_interpolation_entries`); a multi-line string
   token is emitted one entry per line (`token_semantic_entries`) — the implicitly
   concatenated literals were one entry before.
6. **Attribute names and lifetimes.**  `attribute[field] rename(...)` renders the
   declared attribute's name as `decorator` + declaration (an AST-built position
   table), the name a `has_attribute`/`attribute_of` call reads as `decorator`, and the
   decorator state machine enters only on `@[` — a lifetime `@a` no longer swallows the
   rest of its line.  A variant/enum/flags member declaration is found by searching the
   whole *header line* (the backward scan stopped at a token before the header
   keyword, so every arm declaration was missed).

One readiness note: `ScanFacts` (the scanner's per-scan tables) is not released — the
pre-existing pattern, now carrying the binding vector and the type-parameter scopes too,
so a scan leaks a few KB per distinct document version; Track C2's memory work should
fold it in.

The residue (5 positions, all `docs/language_baseline.mt`): the host's
`callable_value_identifier_sites` (`identity` 275:40, `add` 1099:41 — a function-value
reference is `function` only where the analyzer recorded one, so an unrecorded site
falls back to the plain value arms), its `callable_field_member_access?` (`check`
1127:9, `invoke` 1160:13 — a member call on a struct field of function/proc type is a
`property`), and `dot_nested_type_member?` (`Rectangle.Edge` 1962:29 — a nested type
name renders `type`).  The first two need analyzer-side records, the third a
nested-type-name table.

Measured (full matrix, authoritative): the audit **22 → 18** — semanticTokens **5 → 1**
(closed `data_structures.mt`, `memory_stress_test.mt`, `colors.mt`, `main.mt`; none
added); the differing positions **676 → 5**.  Gates: bootstrap fixed point + 14/14, `test/mt` 60/0, `cli:parity`
23/38/0, sexpr lex 705/705 + parse 701/0, the harness 30/30 + the 4 documented entries,
recovery probe OK, the fixtures at their session baselines with 8 entries closed and none
added, valgrind 0 errors over the LSP drive, the headless-Neovim smoke.

### Track B, seventeenth batch (2026-09-30 session 14, continued): the outline's module wrapper and key order

`documentSymbol`'s five entries were next, and the first finding corrects the record:
the host's module-hierarchy wrapper is **not** timing-coupled per se.  Across full runs
the `docs/*` files were wrapped every time and the `src/*` files never were (their
module names are a single segment), while `docs/data_structures.mt` — the *first* file
audited, whose warm `documentSymbol` request runs before the loader has resolved the
file's module name, and whose answer the host then serves from its
(content-hash, facts-id) outline cache — alternated between wrapped and flat.  A file's
answer is stable once its facts exist; only the run's first file races.

Port:

1. **The module wrapper** (`lsp/symbols.mt`): `outline_module_name` mirrors the host's
   `resolve_outline_module_name` — the document's module name only when the path lives
   under a package root (`package_manifest.package_source_root_for_path`: the source
   root first, else the package directory) or the `std/` tree, and only when the name
   has more than one segment; `append_module_wrapper` nests the outline in one
   `{name, kind: 2, range: whole file, selectionRange, children}` object per segment,
   the file range's end line being the newline count.
2. **The host's key order** — the audit compares raw JSON, so the emitters must match
   the host's per-shape hash order: fields, events, variant arms and locals put
   `detail` *before* `range` (the host's `child_field_symbol` / `local_decl_symbol`),
   while methods keep it after `selectionRange` (the host's `child_method_symbol`);
   `render_method_symbol` and `render_local_symbol` join `render_block_symbol`.
3. **Locals in every block**: `collect_stmt_locals` descends into `unsafe`, `defer`,
   `when` and error blocks (and `parallel` bodies) too, and a body that declares *any*
   local — a discarded `let _`, a destructure — gets an empty `children` array exactly
   where the host creates the key (`BodyLocals.has_declarations`).

Measured: `docs/data_structures.mt`'s documentSymbol payload is byte-equal to the
host's whenever the host wraps that file (this run's host answered it *flat* — the
cold-start cache artifact above — so the class counter stayed 5); the other four
entries need the *enrichment* (the extending block's symbol merge and `rl.Color`
naming, the locals' flow-refined types, the `when`-branch declarations, the
function-type rendering).  Gates: bootstrap fixed point + 14/14, `test/mt` 60/0,
`cli:parity` 23/38/0, sexpr 705/705 + 701/0, the harness 30/30 + 4 documented entries,
recovery probe OK, the fixtures unchanged (8 closed overall, none added), valgrind 0
errors, the Neovim smoke.

**Next**: the three residue shapes above, then hover's 9 (the nullability four print the
host's *flow-refined* type — its snapshot selection at a guard line; the destructuring
two + the match-arm payload are stage 11c; the `fn ` rendering is the compiler stages'
function-type names item; `type quat`'s cross-file location; a member chain's third
segment), then B4's other classes (documentSymbol 5 — timing-coupled on the host, the
self's unwrapped outline matches the symbol set; documentHighlight 1 — the host's
carried-forward snapshot binding; diagnostic 2 — a *linter* residue), then C2–C5 and
D2/D3.

### Session-18 close (2026-10-01): the diagnostic class closed, the matrix at 2

Four commits: the linter's emission order (`a37938b5` — F3 part 3), the
`constant-condition` dataflow rule (`bb323ea2`), the owning-release pair
(`9680a6c1`) and this docs close (`dd2ed8ac`).

State at the close — the SimpleGame full matrix (6456 entries) reads
**2 differing entries**: `documentHighlight` 1 (`docs/language_baseline.mt@704:67`,
the host's warm-facts snapshot carry-forward — documented) and `hover` 1
(`docs/language_baseline.mt@1653:24`, `type quat` — documented, with the eager
index-coverage fix measured and rejected: 153 added entries,
`docs/lsp-design.md` §8).  `diagnostic` is **0**: all seven files' diagnostic
arrays are byte-identical to the host's (lb 98/98, mst 10/10; `tmp/lint_table.rb`
0 differing lines and `rake parity:scoreboard` 0 rules with a count mismatch on
both).  `documentSymbol`, `semanticTokens`, `codeLens`, `foldingRange`,
`inlayHint`, `documentLink`, `workspace/symbol` and definition/declaration/
typeDefinition/implementation/references are all 0.

Everything else green: bootstrap fixed point + 14/14, `test/mt` 60/0,
`cli:parity` 23/38/0, sexpr lex 705/705 + parse 701/0, `unused_import_parity`
609/609, the harness 30/30 + its 4 documented entries, the recovery probe, the
fixture sweep at every baseline except the two documented closures
(`defprobe`'s seven hover entries from earlier sessions, `hover-probe4`'s
diagnostic entry closed by the emission order), valgrind 0 errors over an LSP
drive, the headless-Neovim smoke.

Known cost: the `constant-condition` rule builds its own CFG and solves per body
where the host caches one flow analysis per statement list; `mtc lint
projects/mtc/src/mtc/main.mt` takes ~50 s against the host's ~22 s.  A shared
per-body cache is the follow-up (this ledger's session-18 log, "Measured cost
note").  **Closed in session 19 — and the ~50 s was wrong: the real figure was
316 s (see the record below).**

### The linter's constant propagation: dense states, the shared graph, a true RPO (2026-10-01 session 19)

The cost above was re-measured before touching anything: `mtc lint
projects/mtc/src/mtc/main.mt` takes **316 s** against the host's **22 s**.
Phase instrumentation (temporary marks in `lint_source_with`, removed before the
commit) put **320 of the 321 s** in the declaration walk's per-body rule group,
and a per-rule breakdown put **all of it** in `constant-condition`: 97 bodies,
the worst (243 nodes × 65 bindings) at **168 s**.  The rule's state tables were
flat `(node, key)` vectors scanned linearly — `state_same` above all, which
called the linear `state_get` inside its own loop, so every node's per-round
work was quadratic in the *whole* table.

1. **Dense per-node state tables** (`linter/constprop.mt`).  `FlowStates` is the
   host's `Result#in_states` as a dense `node × key` table
   (`cells[node * key_count + key]`; a zeroed cell is `undef`, so an unwritten
   key reads as undef exactly as the host's absent-hash-key lookup does).
   `solve_into` follows the host's `Dataflow.solve` shape: forward, rounds over
   the RPO until no state changes, the entry node's in-state empty
   (`boundary_in`), each node's in-state the join of its predecessors'
   out-states and its out-state the in-state plus its writes.  The old
   `rounds < next_id + 1` cap — which the host does not have — is gone with the
   tables that needed it.  `eval_expr`/`eval_write`/`state_lookup` take a state
   base instead of a `(table, node)` pair; `condition_value_of` reads the dense
   table.
2. **One per-body graph, not two** (`linter/linter.mt`).  `lint_body_rules`
   builds the graph once and passes it to `lint_dead_body` and
   `lint_const_cond_in_body` — the host's shared `statement_flow_analysis` per
   statement list.  Each rule still runs its own solve (liveness, constant
   propagation) once per body.
3. **`graph_rpo_ids` returned a post-order, not a reverse post-order**
   (`semantic/control_flow/graph.mt`).  The DFS pushes a node after its
   successors and the list was never reversed, while the host's `rpo_ids`
   *prepends* (`order.unshift(id)`).  With the wrong order the forward solvers
   recompute a node from its successors' stale states, and with the dense tables
   that turned into a **non-converging oscillation**: on
   `examples/raylib/core/text_file_loading.mt`'s while loop the states of two
   body nodes swapped the value of `text_top` (int 45 / NAC) every round —
   **836,511 rounds** on a body of 14 keys and 33 nodes.  The file is 176 lines
   and the whole file took >120 s while every function prefix was <50 ms; the
   in/out cells of two consecutive rounds (dumped to disk) showed the 2-cycle.
   Fixed by reversing the DFS post-order, as the host does.  The nullability
   solver (F2) uses the same order and keeps its fixpoint (`test/mt`, the audit).

**Measured**: `mtc lint projects/mtc/src/mtc/main.mt` **316 s → 1.9 s** (the host
is 22 s); the worst body's solve **168 s → 99 ms**; 420 warnings on `main.mt`,
byte-identical to the pre-change binary's output; the previously pathological
`text_file_loading.mt` at **50 ms** (the pre-change binary needed 1 s there; the
interim state never finished).  A corpus-wide whole-output host-vs-self lint
comparison (the new `tools/lint_parity.rb`, below) re-ran the pre-change binary
over every file where the host and the new self differ: **247 of 252 identical**,
the 5 differences being exactly the files where the *old* binary timed out at
300 s (`main.mt`, `lowering.mt`, `c_backend.mt`, `semantic_tokens.mt`,
`3d_drawing.mt`) and now complete — so the change is behavior-preserving where
the old binary could finish, and removes the pathology where it could not.

**The corpus-wide lint measurement (new).**  `tools/lint_parity.rb` compares the
*whole* lint output (not just `unused-import`) file by file over `std examples
projects/mtc/src` with a worker pool: **609 files, 357 agree / 252 differ**, and
every difference is pre-existing (see above).  The two-file scoreboard could
never see this; the per-rule deltas, self-extra / host-only, are:
`redundant-unsafe` 807/0 (91 files), `owning-release-leak` 599/290 (99/10),
`prefer-inline-if` 214/0, `redundant-cast` 105/41, `prefer-struct-with` 93/0,
`prefer-let` 85/142, `prefer-try` 63/39, `borrow-and-mutate` 27/0,
`prefer-conditional-expression` 25/0, `shadow` 20/0, `prefer-own-ptr` 16/45,
`constant-condition` 11/1, `prefer-or-pattern` 10/4, `loop-single-iteration` 8/2,
`unreachable-code` 3/0, `prefer-var-else` 2/0, `owning-release-double` 0/12.
This is the ranked next linter workstream (the ledger's session-19 log keeps the
numbers; `tmp/lint-parity-final.log` is the run).

**Gates**: bootstrap fixed point + 14/14 (`stage2.c == stage3.c`), `test/mt` 60/0,
`cli:parity` 23/38/0 (same diff set), sexpr lex 705/705 + parse 701 comparable /
0 differ, `unused_import_parity` 609/609, `rake parity:scoreboard` (lb host 98 /
self 98, 0 differing lines, 0 rules with a count mismatch) and `tmp/lint_table.rb`
(mst 10/10, 0 mismatches), the full SimpleGame audit **2 differing entries**
(`documentHighlight` 1, `hover` 1 — both documented; `diagnostic` 0;
`tmp/audit-s19-final.json`), the fixture sweep at every baseline (added 0),
valgrind over the harness's LSP drive (0 invalid reads/writes/frees,
0 uninitialised uses; the 1860 "errors" are the documented F9 leak records), and
the headless-Neovim smoke.

**The backlog's first lead, measured but not fixed (same session):** the largest
self-extra rule is `redundant-unsafe` (807 warnings over 91 files), and the
divergence is in the analyzer's `required_unsafe_lines` marking, not in the rule.
Probes (`tmp/probe-unsafe.mt`, `tmp/probe-unsafe2.mt`, `tmp/probe-cast2.mt`,
`tmp/probe-cast3.mt`):

- the host *requires* unsafe for a `ptr[T] <- ptr[U]` cast (`check` errors where
  the self accepts it — a missing sema check as well as a missing mark);
- the host marks `unsafe: str(data = text, len = 4)` (an aggregate literal with a
  pointer field, no cast) where the self reports it redundant;
- `unsafe: cstr_len(cstr<-text)` is redundant in *both*, so the cast does not
  mark in every context;
- the host positions the cast diagnostic on the *operand* (`calls.rb:158-190`
  passes the argument expression) where the self reports the cast's target
  column, and the host has a second message
  (`ref to pointer cast requires unsafe`) the self never emits.

The host's predicate is `pointer_cast_type?` (`cstr`, `ptr`/`const_ptr`/`own`,
a nullable of a pointer/function, a function type, a typed null) applied to
**both** sides (`check_cast_call`), plus `ref_to_pointer_cast?`; the marking is
`AnalysisContext#require_unsafe!` → `mark_current_unsafe_required!`
(`analysis_context.rb:20-32`).  Next session: port `check_cast_call` faithfully
(predicate, both messages, operand positions) and then re-probe the remaining
marking sites (aggregate literals with pointer fields, call arguments)
corpus-wide with `tools/lint_parity.rb`.

### The corpus-wide lint residue's first lead — done (2026-10-02 session 20)

The session-19 measurement (609 files, 357 agree / 252 differ; `redundant-unsafe`
self-extra 807 over 91 files) led with `redundant-unsafe`: the self called `unsafe:`
blocks redundant where the host marked them required.  The divergence is not the rule —
it reads `Analysis.unsafe_statement_lines`/`required_unsafe_lines`, the analyzer's mark
record — it is the *marking sites and the typing they depend on*.  Landed, one commit:

1. **`check_cast_call`** (`analyzer.mt`): the cast predicate is the host's
   `pointer_cast_type?` on **both** sides — `ptr`/`const_ptr`/`own`, `cstr`, a function
   value, a nullable of a pointer or function, a typed null to one of those — plus
   `ref_to_pointer_cast?` with its own message (`ref to pointer cast requires unsafe`).
   The old predicate (“target is a raw pointer, source is not”) missed `ptr[T]<-ptr[U]`,
   every `cstr` cast, `own[T]<-ptr[T]`, nullable and function casts — the casts that
   dominate `std/net.mt`, `std/async/libuv_runtime.mt`, `std/fs.*.mt` and the compiler's
   own sources.  The unsafe diagnostics sit on the **operand's** position, like the
   host's `source_line`/`source_column` walk (`expr_source_line`/`expr_source_column`
   port that descent); the incompatible-types error (`cast requires compatible types,
   got X -> Y`) is emitted for sides the self can classify concretely
   (`cast_operand_unknown`/`cast_side_incompatible` keep the error type, type variables
   and enum-likes permissive — the first cut reported `<error> -> ptr[ubyte]` on
   `str.data` and was caught by the self-build).
2. **`str construction requires unsafe`** (`check_str_construction_unsafe`):
   `str(data = …, len = …)`, and a construction through a type alias of `str`, mark /
   report like the host's `check_aggregate_construction` StringView arm.
3. **`str`'s fields** (`check_member`'s new `ty_str` arm): `data: ptr[char]`,
   `len: ptr_uint` — the host's `Types::StringView#fields`.  This is what makes
   `ubyte<-read(text.data + i)` mark (the lexer's 59 entries; `str.data + i` is pointer
   arithmetic and `read` is a dereference).
4. **Arm payload fields for user and imported variants** (the recorded stage-11c
   remainder): `Context.arm_payload_field_types` now holds every declared variant arm's
   resolved fields (the variant's type parameters as `ty_var`), exported through
   `ModuleBinding.variant_arm_fields` and consulted by `match_arm_payload_type` for
   local, prelude and imported variants alike (the `else` branch substitutes the
   scrutinee's arguments).  Before, only Option/Result carried payload fields, so
   `match d: ast.Decl.decl_var as v:` left `v.value` unresolved — the single largest
   cause of the residue (`lowering.mt` 155 → 5, `c_backend.mt` 64 → 0, `lexer.mt` 59 → 0,
   `std/toml.mt` 3 → 0).
5. **A foreign `ty_named` resolves through the binding** (`check_member`): an exported
   field's type carrying its declaring module's name (`ty_named(module, name)`) now
   routes through `check_imported_member`, gated on `binding_has_struct_type` (which
   also consults the private struct/union tables, so a private type reached through a
   public signature resolves) — a member chain like `tref.name.parts.data` resolves
   where it used to stop at the first foreign type.
6. **The guard's else block is analyzed** (`check_local_else_body`): `let x = e else:`
   bodies were never checked, so every `unsafe:` inside one looked redundant
   (`std/net.mt`'s 17).  The `else as name` binding carries the initializer's error type
   (`Result[T, E]`'s `E`, `let_else_error_type`).
7. **Proc literal bodies are checked** (`check_proc_body`: the parameters in a fresh
   scope, the block checked with the proc's return type) and **format-string
   interpolation parts are inferred** (`check_format_string_parts`), the host's
   `infer_proc_expression` / `check_format_string_literal` (`std/toml.mt`, `std/json.mt`,
   `lsp/semantic_tokens.mt`).
8. The `read` diagnostic text is the host's `raw pointer dereference requires unsafe`
   (was `pointer dereference requires unsafe`).

**Measured** (the stage2 from this session's bootstrap): `tools/lint_parity.rb -q`
over `std examples projects/mtc/src`: **609 files, 381 agree / 228 differ** (session 19:
357/252), and the per-rule self-extra `redundant-unsafe` went **807 → 11**.  The other
deltas moved with the facts: `prefer-let` 85 → 68, `prefer-inline-if` 214 → 213,
`redundant-cast` 105 → 107 — the rule is sema-backed and the newly resolved types let
it fire in generic bodies where the host's facts stay absent; **104 of the 107 are
`ptr_uint<-size_of(T)`-shaped generic-body sites** (same-body rule: the next lead).

**The remaining 11, with their causes** (the next lead): `std/goap.mt:62` and
`std/input.mt:130` iterate a `ref[Vec[T]]`/`Vec[T]` whose element the self binds at
`ty_error` (`bind_for_names`; the host's iterator protocol / collection element type is
not ported); `std/process.mt:273` is an assignment *through* `read(…)` whose lvalue path
does not mark and `:288` follows it; the rest are per-file typing gaps —
`c_backend.mt:7166` (`read(nl.base)` on a nested payload field),
`definition_index.mt:190` (`read(name)` on a `Vec.get` unwrap),
`code_actions.mt:60`/`inlay_hints.mt:64` (an `Option.unwrap()` pointer),
`navigation.mt:4812` and `references.mt:350` (`read(container.data + i)` on a
`FnSig`/map value), `lowering.mt:3880` (an imported alias-map lookup).

**Gates**: bootstrap fixed point (`stage2.c == stage3.c`) + 14/14 (568 tests — 15 new:
8 linter, 7 semantic; two old cast tests re-pinned: `ptr[int]<-0` is an incompatible
cast in the host too), `test/mt` 60/0, `cli:parity` 61 cases 23/38/0 (the same case
set — `tmp/cli-diffs-s20.txt`), sexpr lex 705/705 + parse 701/0, `rake
parity:scoreboard` (lb 98/98, 0 differing lines, 0 rules with a count mismatch),
`tmp/lint_table.rb` (mst 10/10), the harness 30/30 + its 4 documented entries (the same
set), the recovery probe OK, the fixture sweep (added 0; `hover-probe4`'s diagnostic
closure, as recorded), the full SimpleGame audit **2 differing entries**
(`documentHighlight` 1 + `hover` 1, both documented; `diagnostic`, `documentSymbol`,
`semanticTokens` and the navigation classes all 0; `tmp/audit-s20.json`),
`unused_import_parity` 609/609, the example sweeps (`examples/*.mt` 15/15,
`examples/sdl3` 34/34, emit-c), valgrind over an LSP drive (0 errors) and the
headless-Neovim smoke (the `zero[mat4]` hover renders).

### The last `redundant-unsafe` sites and the generic-body cast residue (2026-10-02 session 21)

The session-20 close left `redundant-unsafe` at 11 self-only and ranked the
generic-body `redundant-cast` sites (104 of 107) next.  Both are closed; the
`redundant-unsafe` class is now **0/0** corpus-wide.  Landed, one commit:

1. **For-loop element typing** (`bind_for_binding_types` + helpers): a range yields its
   bounds' (harmonized) integer type; an array/span its element — a `ref[element]` for a
   struct element, the host's `collection_loop_type`/`collection_loop_binding_type`; and
   anything else runs the iterator protocol (`iter()`'s result's `next()`: a nullable
   pointer-like item yields its base, a `bool` yields `current()`).  The iterables are
   inferred too.  Closes `std/goap.mt:62` (`for entry in open_list` over a
   `ref[Vec[ptr_uint]]`) and `std/input.mt:130`.
2. **`x.method[T](args)` on a value receiver** (`check_specialized_method_call`; the
   method's declared type parameters exported through
   `Analysis.method_type_params`/`ModuleBinding.method_type_params`): the explicit
   arguments substitute the method's return type (`storage.alloc[ptr[char]](n)` ->
   `ptr[ptr[char]]?`).  Closes `std/process.mt:273`/`:288`.
3. **`read` is the host's `infer_reference_value_type`**: a `ref` reads its referent; a
   raw pointer dereferences and requires unsafe; an `own[T]` auto-dereferences (no
   requirement); a nullable pointer is not a read source (the host rejects it, staying
   permissive here).
4. **Prelude method signatures for typing** (`Context.prelude_method_sigs`, filled from
   the seeded std.option/std.result bindings; `check_typed_method_call` substitutes a
   generic receiver's own arguments): `Option[int].unwrap()` -> `int`, the receiver's
   method calls type like the host's.  Deliberately **not** exported on the `Analysis`
   — the LSP resolves a member's declaration from the receiver's own module, and an
   exported prelude signature made `unwrap`'s hover/definition/references answers go
   null (8 new audit entries; the separate table fixed them).
5. **Imported generic struct fields are substituted** (`substituted_field_type`, also
   for the private struct/union tables): `entry.value` on a
   `RemovedEntry[K, V]` no longer returns the declaring type's `ty_var` but the
   receiver's argument.
6. **Short-circuit and branch refinements** — the host's `infer_binary`'s `and`/`or`
   right-operand refinement, `infer_if_expression`'s per-branch refinements, and
   `check_while_stmt`'s body refinement.  This is what the faithful `read` change
   exposed (30 self-only entries mid-session: `p != null and read(p)…`,
   `if p != null: read(p)`, `while p != null: read(p)` had never been narrowed).
7. **The generic-body gate for `redundant-cast`** (`redundant_cast.Ctx.generic_body`,
   set from the linter's `lint_generic_depth`): the host's analyzer does not check
   generic bodies, so its linter has no expression types there and the sema-backed cast
   checks fall back to the literal-only paths; the self records the types, so the flag
   suppresses them to match (heap/arena/pool/iter's `ptr_uint<-size_of(T)` family).

**Measured**: `tools/lint_parity.rb -q` over `std examples projects/mtc/src`:
**609 files, 385 agree / 224 differ** (session 20: 381/228); **`redundant-unsafe`
0/0**, `redundant-cast` self 107 → **74** (host 28 → 24), `prefer-let` self 68 → 51.

**A pre-existing assignability gap measured while writing the tests** (next lead): the
self does not flag a *nullable pointer* against a `str` return —
`function f(p: ptr[int]?) -> str: return p` is a host error and self-silent
(`incompatible_value`/`types_compat` treats the nullable pointer as compatible).

**Gates**: bootstrap fixed point (`stage2.c == stage3.c`) + 14/14 (9 new tests: 4
linter — the `and`/if-expression/while marks and the generic-cast gate — and 5 semantic
— for-loop element typing, the prelude `unwrap` via a temp-workspace prelude stub,
imported generic field substitution, and the value-receiver specialization), `test/mt`
60/0, `cli:parity` 61 cases 23/38/0 (the same set), sexpr lex 705/705 + parse 701/0,
`rake parity:scoreboard` (lb 98/98, 0 differing lines, 0 rules with a count mismatch)
and `tmp/lint_table.rb` (mst 10/10), the harness 30/30 + its 4 documented entries
(`tmp/lsp-self-s21b.json`), the recovery probe OK, the fixture sweep at every baseline
(added 0), the full SimpleGame audit **2 documented entries** (`tmp/audit-s21b.json`;
the first run carried the documented `docs/data_structures.mt` `documentSymbol` race
phantom — the self's answer equals the previous quiet run's host answer), the example
sweeps (`examples/*.mt` 15/15, `examples/sdl3` 34/34, emit-c), valgrind over an LSP
drive (0 errors) and the headless-Neovim smoke.

### The analyzer's nullability assignability rule and the binding storage type (2026-10-02 session 22)

The session-21 close ranked the assignability gap first: `function f(p: ptr[int]?) -> str:
return p` is a host error and was self-silent.  The host's rule set was measured first on
single-shape probe files (the host aborts a file at its first error, so each shape needs
its own file):

| Shape | Host |
| --- | --- |
| `return p` / `take(p)` / `var x: T = p` with `p: T?` | error (`return type mismatch: expected T, got T?`, `argument x to f expects T, got T?`, `cannot assign T? to x: expected T`) |
| `return null` into a non-nullable `ptr[int]`/`str` | error (`… got null`) |
| `return p` after `if p == null: return …`, in an `if p != null:` branch, in an `and` guard, in a `while` body | clean — the flow refinement narrows `p` |
| `x = v` where `x: T?` was refined non-null | clean — the target is the **storage** type |
| module-level `var g: T?` with `if g == null: return` then `take(g)` | clean — the host seeds module bindings into its scopes |

Landed, one commit:

1. **`types_compatible` no longer accepts `T?` → non-nullable**: the permissive rule 6 in
   `type_compatibility.mt` is gone, and `definitely_incompatible` (`types.mt`) reports the
   pair — unless the target or the unwrapped base is a type variable or *contains* one
   (`contains_type_var`, new), so generic bodies stay permissive exactly as the host's
   (it does not check them).  F2's flow refinement is what keeps the guarded shapes
   working: it changes the *inferred* type of the use before the check.
2. **The binding storage type** (`semantic/scope.mt`): a parallel frame stack
   (`scope_set_storage` / `scope_get_storage`) holds the declared/initializer type and
   refinements only touch the flow frame; `check_local` stores the host's `LocalDecl` rule
   (a plain declaration keeps its final type; a guarded one keeps the raw initializer for
   a `let` and the success type for a `var`), parameters / `this` / for / match-arm /
   destructure / else bindings store theirs, and `assign_target_type` uses it for a plain
   identifier assignment target (the host's `infer_lvalue` → `binding.storage_type`), so
   a refined non-null binding still accepts its declared nullable type.  Two regressions
   the first cut caused and the tests caught: `std/map.mt`'s `node = read(node_ptr).next`
   (a generic body — the `contains_type_var` gate) and a frame-coherent lookup variant,
   which broke refinements (they write into the *current* frame, not the binding's).
3. **Module-level values refine like locals**: `refinement_type_ptr` falls back to
   `ctx.value_types` and `note_refinement_storage` records the declared type in the
   refinement frame, so `if g == null: return` narrows a global for the rest of the body.
   The first full gate bus caught this as a false positive it *caused*:
   `examples/sdl3/misc/clipboard.mt`'s `pasted_str` global (the host accepted the guarded
   `text_ops.chars_as_str(pasted_str)` call, the self had started rejecting it); the fix
   is part of the same commit and the second bus reads examples 49/0.
4. **The local-declaration message and the return anchor**: `cannot assign <got> to
   <name>: expected <expected>` (was `type mismatch: cannot assign <got> to <expected>`)
   and a return mismatch anchors on the value expression
   (`expr_source_line`/`expr_source_column`), as the host's `ensure_assignable!` does.

Measured: the probe set matches the host's messages *and* positions byte-for-byte;
`cli:parity` 61 cases **24 match / 37 differ / 0 pending** (was 23/38 — `check-sema-error`
closed; `tmp/cli-diffs-s22.txt` against `tmp/cli-diffs-s20.txt` shows exactly that one
closure, no additions).  Gates (final tree, `tools/gates.sh --areas analyzer --only
… --run`; the first bus's failing examples gate is what forced fix 3): bootstrap fixed
point (`stage2.c == stage3.c`) + 14/14, `test/mt` 60/0, `cli:parity` 24/37, scoreboard
lb 98/98 + parse 705/701/0 (unchanged), `tools/lint_parity.rb -q` 609 files 385/224
(unchanged — no lint facts move), `unused_import_parity` 609/609, the harness 30/30
capability keys + its 4 documented entries, the recovery probe OK, the fixture sweep at
every baseline (closed 0, added 0), the SimpleGame audit **2 documented entries**
(`tmp/audit-gates.json`: `documentHighlight` 1 + `hover` 1), **examples same=49
differ=0**, valgrind over the LSP drive (0 errors) and the headless-Neovim smoke.

**Residuals of the same function, measured and ranked next** (both self-silent where the
host errors): a bare `null` into a non-nullable target (`return null` for `ptr[int]` /
`str`; the self's `ty_null` is kind-unknown in `definitely_incompatible`, and
`types_compatible` has no null arm) and generic-vs-scalar pairs (`ptr[int]` → `str`,
permissive by the cross-kind fallback; tightening needs the host's positive
`call_argument_compatible?` split, because `implicit_ref_argument_compatible?` lets a
`ref[T]` parameter borrow a `T` argument at call sites only).  One adjacent measured gap
surfaced by the probes: assigning to an immutable *parameter* is not flagged
(`function f(v: int?): v = null` is a host error; the self's immutable check only tracks
`let` bindings) — pre-existing, unrelated to this change.

### The host's `inline_if_too_wide?` join simulation (2026-10-02 session 22, second commit)

`prefer-inline-if` was the largest remaining conciseness-rule delta (213 self-only, 0
host-only): the self had ported the host's `visually_inline_if?` half of the gate but
not the other half, `inline_if_too_wide?` (`visitors.rb:838-882`), which decides whether
the whole `if`/`else if`/`else` chain can actually be joined onto one physical line:

- the header line must start with `if `;
- every branch body must be a single physical line (a second body line at a deeper
  indent is unjoinable);
- the chain must end in a same-indent `else:`;
- the composed line (`indent + "header body"` segments joined by spaces) must be at most
  120 *characters* (Ruby's `String#length`, not bytes) and have balanced `()`/`[]`.

Ported as `inline_if_too_wide` plus the helpers `source_line_at`,
`leading_whitespace_len`, `right_trim_ascii`, `utf8_char_count` and
`balanced_inline_line`.  The `prefer-conditional-expression` if-arm had a *different*
gate in the self (`visually_inline_if`) where the host uses `inline_if_too_wide?`; it now
shares the join simulation (and its now-dead `else_line` parameter is gone).

Measured: `tools/lint_parity.rb -q` over the corpus **385 agree / 224 differ → 434
agree / 175 differ**; `prefer-inline-if` **213 → 0** self-only and
`prefer-conditional-expression` **25 → 0**; every other rule's delta unchanged
(`owning-release-leak` reads 602 — the three-warning drift from the session-21 close is
content, not behaviour: a scan with a binary built from `48c36dc7` over the same sources
produces the byte-identical self-only leak set).  Three new linter tests pin the
joinable / over-budget / multi-line-body shapes, each first verified against the host.
Gates: bootstrap fixed point + 14/14, `test/mt` 60/0, `cli:parity` 24/37 (unchanged),
scoreboard lb 98/98 + parse 705/701/0, `lint_parity` 434/175, the harness 30/30 + its 4
documented entries, recovery OK, fixtures at baselines, the audit **2 documented**,
examples 49/0, valgrind 0 errors, the Neovim smoke.

### The release rules' CFG precision analysis (2026-10-02 session 23)

The session-22 close ranked the corpus lint residue; `owning-release-leak`
(602 self-only / 286 host-only) was the largest rule delta.  The cause was a
missing port, not a gate: the host's `emit_owning_release_warnings`
(`release_rules.rb`) runs `emit_owning_release_cfg_warnings` whenever its
`sema_facts` exist — and `mtc lint` / the LSP always have them — while the
self always ran the *simple* AST path (the host's no-facts fallback).  The CFG
path is a different algorithm: per struct-owning local, a leak means **some
path** from the declaration reaches an exit before any consumer (a release, a
by-name return or a struct-field transfer), not "no release anywhere"; and a
release reachable from another release before a reassignment is a double
release (the host-only 12 in the corpus).

Landed, one commit (linter only):

- `ownership_walk_body` dispatches on the analysis: `ownership_cfg_warnings`
  over F1's graph when `lint_analysis != null` (the host's `cfg_available`),
  the simple path otherwise (kept — it is the host's real fallback for a file
  whose context bootstrap fails, e.g. a lint with no analysis).
- The ported pieces: `ownership_find_decl_node` (the `local_decl` node with a
  `declaration` write — and the host's builder writes one only when the local
  has an initializer, so an uninitialized `var x: T` is skipped while the
  self's shared builder records the write unconditionally),
  `ownership_reachable_ids` (BFS from the entry), `ownership_classify_nodes`
  (releases / consumers / reassigns),
  `ownership_release_call_in_stmt` / `ownership_expr_has_release` (including
  the `release_*`-helper idiom and defer bodies), `ownership_return_for_name`,
  `ownership_struct_transfer_in_stmt` (the host's `_expr_contains_transfer?` /
  `argument_transfers?`), the `every_path_to_exit_has_consumer?` and
  `find_reachable_release` BFS walks, and the owning-locals collection
  (`resolve_local_owning_type`: the annotation's base name, or a zero-argument
  `create` / `with_capacity` / `empty` / `from_str` call whose receiver names
  the type — the host's `extract_initializer_type` rejects argument-taking
  calls).
- One pre-existing port bug fixed on the way: `own_transferred?` uses the
  host's `_any_stmt?` and therefore **recurses into nested bodies**
  (`unsafe:` / `if` / `while` / `for` / `match` / `defer`); the self's port did
  not, so every heap allocation handed over inside an `unsafe:` block (86 of
  the corpus's 89 residual sites, e.g. `read(bucket_ptr + index) = node` in
  `std/map.mt` and the parser's `alloc_*` helpers) was reported as a leak.

Measured: `tools/lint_parity.rb -q` over `std examples projects/mtc/src`:
**475 agree / 134 differ** (session 22: 434/175); `owning-release-leak`
**602/286 → 0/0** and `owning-release-double` **0/12 → 0/0**; no other rule
moved.  `tmp/rl_scan.rb` (the session-local focused scan, host outputs from the
host cache) reads 0/0.  The two diagnostic files stay byte-identical (lb 98/98,
mst 10/10, 0 differing lines).  Four new tests in
`projects/mtc/test/linter_test.mt` pin the CFG shapes: the conditional-release
leak, the uninitialized-declaration skip, the `unsafe:`-nested `own[T]`
transfer and the loop-back-edge double release (each first verified against
the host).

Tooling: `tools/lint_parity.rb` gained `--host-cache FILE` — the host's
per-file outputs are cached under the file's digest (and the whole cache drops
when the host compiler's sources change), so corpus iterations run the host
once and the self side live afterwards (609 files: minutes before, ~20 s after
the first warm).

### `prefer-struct-with`: the host's gates and the imported-alias resolution (2026-10-02 session 23, second)

The ranked residue's next self-only class was `prefer-struct-with` (93
self-only, 0 host-only): the self's rule was a shape match with none of the
host's gates.  The host (`visitors.rb:977-1015`) requires: the callee is an
identifier or member access (a specialized `Vec[T](…)` is neither), every
argument is named, `copied >= 2` and `changed >= 1` from a single source
value, the target resolves to a `Types::Struct` (not a generic instance,
union, enum or variant), the copied source's type is that same struct, and
the copied names are exactly the struct's fields minus the changed ones.  The
message renders `expr_source_name` (dotted chains, `…` otherwise) and anchors
at the callee.

Ported all of it (`prefer_struct_with_fields` / `_same_type` /
`_partition_ok` / `_source_name`, the callee gate, the analysis gate); the old
message format (`width = ..., height = ...`) was wrong in both the separator
and the ellipsis and is now the host's
(``copies 2 field(s) from `s`; use `s.with(width, height = …)` ``).

Two analyzer gaps surfaced behind it and were fixed with it:

1. **Re-exported imported aliases.**  `rl.Rectangle` is `type Rectangle =
   c.Rectangle` in std.raylib; the expression path (`try_imported_type`) and
   the imported constructor path (`try_imported_call`) only looked in the
   binding's `structs`, so a constructor through the alias recorded `ty_error`
   and its member reads lost the declaring module.  Both now follow
   `type_alias_types` to the resolved target exactly as the type-reference
   path (`resolve_imported_type`) already did — `rl.Rectangle(…)` types as
   `std.c.raylib.Rectangle`.  The alias construction is deliberately *not*
   field-validated there: a first cut validated it against the declaring
   binding and rejected `examples/sdl3/demo/bytepusher.mt`
   (`a = sdl.ALPHA_OPAQUE`, declared `int`, into a `ubyte` field) — the host
   folds the const and accepts, the self's coercion rule does not fold yet
   (also `return sdl.ALPHA_OPAQUE` from a `ubyte` function, a pre-existing
   analyzer gap; the next lead below).
2. **Moduleless local constructors.**  A local struct constructor records
   `ty_named(module_name="", name=…)` while an annotation carries the module;
   the same-type gate treats an empty module as a match (the host's type
   identity has no such distinction).

Measured: `tools/lint_parity.rb -q` over the corpus **475 agree / 130 differ →
494 / 115**; `prefer-struct-with` **93/0 → 0/0**.  Three new tests pin the
copy-fields hint (byte-equal message), the source-type gate and the
all-arguments-named gate.  lb 98/98 and mst 10/10 stay byte-identical.

**Documented follow-up (found by the alias work):** a *constant expression*
whose folded value fits a narrow integer target is host-accepted and
self-rejected — `return sdl.ALPHA_OPAQUE` from `-> ubyte`, `let x: ubyte =
sdl.ALPHA_OPAQUE`, and the same value in a field/argument.  The host's
compatibility rule folds the const (its `constant_value_for`); the self's
`is_numeric_literal_valued_expr` (`type_compatibility.mt`) only recognizes
literal nodes and `if`-chains, so the declared `int` type of the imported
const mismatches `ubyte`.  Fixing it means threading a folded-constant
notion into `types_compatible` (or pre-folding at the call sites) — a
separate analyzer change.

### Completion parity, part 1: the project audit's dot pass (2026-10-02 session 24)

The LSP harness's synthetic completion cases (member, import-member,
top-level, struct-field) were green, but the *project audit* never requested
completion at all, so real-project completion was unmeasured.  The audit now
has a member-completion pass (`member_completion_positions`: the character
after every `.` followed by an identifier, sampled like the other position
endpoints), and the first run on SimpleGame read **600 of 619 entries
differing** — the harness had masked the whole class.

Fixed in this batch (completion.mt unless noted):

- **Module-alias members are uncapped.**  The host's 200-item cap applies to
  its global and method-fallback paths only; `rl.` answers all 689 members
  (`isIncomplete: false`).  Module types also carry the host's kind 5.
- **`labelDetails` is emitted when either part exists** (a no-parameter module
  function still carries the module as its `description`).
- **Module-member signatures render from the target module's loaded analysis**
  (`target_module_analysis`: the current document's program, matched by
  `module_name`) — the host's `facts.imports[alias]` binding data, with
  fully-qualified types (`ref[std.vec.Vec[T]]`, `std.iter.Iter[T]`).  The
  AST-based rendering stays as the fallback for an unloaded module.
- **`type_render.qualified_name` renders a proc/function's nested types
  qualified** (`proc(std.async.libuv_runtime.Runtime) -> T`); previously it
  fell through to `type_to_string` (bare names).
- **Import completion is the host's shape**: `module <name>` detail, `0_`
  sort group, the current document's `data`, plus the platform variants
  (`fs.linux`/`fs.windows`) the self used to skip; the import path is uncapped.
- **Enum-member and module-value `sortText` carried the name** (`0_idle`,
  `1_ptr_uint_max`); both were emitting the bare group prefix.
- **Snippets gate `insertTextFormat`**: the host sets it only when a snippet
  was produced (a >5-parameter function inserts the bare name), where the
  module item hardcoded `2`.
- **Analyzer**: a foreign/extern function's declared type parameters are
  `ty_var` in its signature, not the suppressed `<error>` (`enter_type_params`
  on top of `enter_suppressed_type_params`).  The host's binding types carry
  `T` (`value: T`, `ptr[T]`); call-site checking is unchanged because
  `check_signature_call` returns early for `is_extern`.

Measured: completion audit **600 → 366 differing entries**; the full matrix
shows no regressions (hover 1, documentHighlight 1, documentSymbol 1 — the
documented entries plus the known host first-file race), the harness stays at
30/30 + 4 documented, and the `n.` `static:create` case on SimpleGame's
`src/main.mt` is byte-identical to the host (the host renders `static:`-prefixed
method labels on value receivers; a *type* receiver strips the prefix — both
already matched).  Three new instruments: the audit's dot pass,
`tmp/comp_diff.rb` (the diff-family classifier) and `tmp/sg-probe2` (the
mid-edit `n.` workspace).

**Remaining completion families, ranked** (from the classifier):

| Entries | Family |
| --- | --- |
| 49 | Type-receiver misses a receiver type's methods declared in *other* modules (the host's `methods_for_receiver_type` merges the current module + every import; `rl.Color.from_hsv` from std.raylib while the local `extending` block supplies the rest) |
| ~97 | **Order-only**: same labels/sortTexts, different array order — the merge order above (fields, then current-module methods, then each import's, deduped) |
| 25 + 18 | The method-fallback path: the host lists its whole method table with raw keys (`static:default`) and takes that path for *any* dot position (its `find_dot_receiver_path` accepts digit/bracket segments the self rejects, so the self falls to the global list instead) |
| 15 + 15 + 14 + … | Receiver resolution: `Vec[int].` (specialized type receiver), `Option`/`Result` prelude receivers (host lists prelude methods), missing single methods (`as_iter`) |

### Completion parity, part 2: the receiver merge and the alias-qualified receivers (2026-10-02 session 24)

Part 1 left **366** differing completion entries; this batch takes the class to
**235** (from the 600 the dot pass first measured):

- **The host's `methods_for_receiver_type` merge** (`merged_receiver_methods`):
  the current module's methods for the receiver type in registration order,
  then every import's (in the file's import order), deduped by name — replacing
  the AST walks that saw only the current file's `extending` blocks.  The
  type-receiver path emits statics alone with the `static:` marker stripped;
  value receivers keep it as their label.  Details/params/snippets render with
  *absolute* type names (`static:create() -> std.vec.Vec[T]`), as the host's
  `Types#to_s` does.
- **`imported_type_members` now covers public type aliases**
  (`collect_binding_alias_members`): `rl.Rectangle`/`rl.Color` are `public type
  X = c.X`, so the alias spelling had no entry — the module's
  `<Alias>.<method>` extending methods (`std.raylib`'s `Color.from_hsv`) and the
  target's fields were invisible.  (This also completes the
  `prefer-struct-with` fields path for aliased structs.)
- **Alias-qualified type receivers** (`rl.Color.`): `type_receiver_completions`
  accepts the receiver segment when the alias's module carries it
  (`type_receiver_known`), fed by `cursor.type_receiver_at`'s module alias —
  the host's `resolve_type_receiver_info` fall-through.
- **The method fallback** walks the file's declarations in order (the host's
  per-type registration order; inline methods are desugared into `extending`
  blocks by the parser) and labels statics with the `static:` prefix, rendering
  resolved signatures absolutely — the host's method-table iteration.
- **Completion-only dot detection** (`cursor.member_receiver_at`): a port of the
  host's `find_dot_receiver_path` — any dot context yields a receiver (digit
  segments and `[…]` groups included; the *rightmost* path segment is the
  receiver), so the fallback answers exactly where the host does.  The
  hover/definition endpoints keep the stricter `dot_receiver_at`.

Measured: completion audit **366 → 235 differing entries**; the full matrix at
the same tree reads **237** (235 completion + the 2 documented entries), the
harness is back to **30/30 + the 4 documented entries**, dev tests 14 files / 0
failed, and the corpus lint is unchanged at 494/115.

**Remaining completion families** (ranked; unchanged labels are order-only
unless noted):

| Entries | Family |
| --- | --- |
| ~120 | **Order-only**: the same labels, a different array order.  The host's merge order is per *type object* across every import; the self's per-module entry order still differs for some receivers (e.g. `docs/data_structures.mt@260`) |
| 15 | A module that *extends* a type it does not declare has no `<module>.<Type>` entry, so its methods are missing from the merge (`std.iter`'s `Vec.as_iter`).  Fix: collect method-only entries from each binding's method table |
| ~26 | Prelude `Option`/`Result` receivers: the host's `BUILTIN_TYPE_METHOD_SIGNATURES` table supplies `unwrap`/`expect`/…; the self's prelude stubs are a different set (and absent from the fallback, correctly) |
| 15 | `vec.Vec[int].`-style specialized type receivers fall through to the fallback instead of the type-receiver path |
| ~30 | Small resolved-vs-unresolved receiver differences (`lb@123:16`'s `a,b,both`, `lb@1577:27`, `lb@1653`-style positions) |

*(All of these closed in part 3, below; the class is at 5.)*

### Completion parity, part 3: registration order, the prelude merge and the receiver families (2026-10-03 session 26)

Part 2 left **235** differing completion entries; this session takes the class to
**4** — the audit's completion pass reads **4 of 619**, the harness stays at
**30/30 + its 4 documented entries**, the corpus lint at **494 agree / 115
differ**, and the dev tests (14 files / 0 failed), bootstrap (fixed point +
14/14) and `test/mt` (60/0) stay green.

**Registration-ordered method tables (the order-only family, ~120 entries).**
`merged_receiver_methods` iterated `analysis.method_sigs` — a bucketed
`map_mod.Map` — so each type's method order was hash order, while the host's
`methods_for_receiver_type` merges in *registration* order (the current module's
methods for the receiver, then each import's).  New `method_order: vec.Vec[str]`
records every registration: `Context`/`Analysis`/`ModuleBinding` (the binder's
`export_methods` appends in declaration order) and each `ImportedTypeMembers`
(`collect_type_methods` fills it from the binding's order).  `register_method_sig`
is the one registration point (first registration wins, like the host's
`methods[name] ||=`), and the merge, the type/value receivers and the imported
records iterate the vectors instead of the maps.

**Method-only entries (the `as_iter` family, 15 entries).**  A module that
declares `extending X:` without declaring `X` (std.iter's `Vec.as_iter`) had no
`ImportedTypeMembers` entry, so its methods never reached the merge.
`collect_method_only_members` creates entries from each binding's method table;
they carry `declared = false`, so `type_receiver_known` keeps the host's
`module_binding.types` gate (a method-only entry is not a type receiver).

**Imports and the prelude merge (the Option/Result family, ~26 entries).**
`Analysis.import_order` mirrors the host's `facts.imports` key order — the
file's imports in source order, then the seeded prelude modules
(`install_prelude_types`) — and the receiver merge follows it, so an
`Option`/`Result` receiver carries std.option's/std.result's real method sets
(`is_some` … `unwrap_or_else`; `is_success` … `map_error`) instead of the
analyzer's prelude stubs.  The global list's import bucket emits the same order
and the host's *alias* labels (`import std.hash` binds `hash`).

**Receiver resolution (the largest remaining family).**  The value-receiver path
now mirrors the host's `project_field_receiver_type_for_completion` /
`project_method_receiver_type_for_completion` (nullable unwrap + one
`ref`/`ptr`/`const_ptr` projection), and the analyzer records what the host's
scope snapshot carries: `this_types` (each non-static extending method's
resolved receiver type — `this.` receivers), arm payload bindings
(`Option.some as s`, scoped to the enclosing function), the resolved declared
type of annotated locals (`local_decl_types`, so `SoA[Point, 4]` resolves), the
narrowed type of a guarded `let` (`unwrap_nullable_type`, so `get(…) else:`
binds `ptr[int]` and not `ptr[int]?`), and the enclosing function's `FnSig`
parameter types (`ref[NPC]` projects).  Builtin field tables (vectors, matrices,
quaternions, `span`'s `data`/`len`, `SoA`'s per-field arrays), nested types
(`Rectangle.` → `Edge`), tuple fields (`_0`/named), match-arm payload fields and
the host's `value_chain_completions` (multi-segment paths: `m.col0.`,
`r.top_edge.`) are ported; field details render the analyzer's resolved field
type (the host's `ftype.to_s`: `fn `, `docs.language_baseline.Edge`,
`value: int`).

**Global list.**  Foreign/extern functions join the functions bucket (with the
*declared* variadic flag for the `…` marker), nested types follow their parent,
the values bucket registers consts then vars, type aliases come after the other
types, and the `when` branch declarations (`Analysis.when_declarations`) merge
into the declaration walks by line (the host's expanded AST keeps them in
place).

**Remaining completion residue (4, each classified):**

| Entries | Position | Cause |
| --- | --- | --- |
| 1 | `mst@224:18` | the host renders a synthesized `ref` lifetime on a struct field (`ref[@_mt_0, ubyte]`; the self `ref[ubyte]`) |
| 1 | `lb@818:17` | the host's facts fail to type the `map_error` result's arm binding and answer the method fallback where the self answers the field (`f.error`) — the documented "self answers where the host gives up" family |
| 2 | `mst@10:52`, `mst@11:21` | positions inside comment lines containing multi-byte characters (`§`): the audit's positions are character offsets while the self's cursor walk is byte-based (the documented approximation in `cursor.mt`) |

**The corpus lint caught a real bug on the way.**  The first gate run of this
batch read **487 agree / 122 differ** with `redundant-unsafe` 0 → 390 self-only —
every file in `projects/mtc/src` with an `unsafe:` block, untouched files
included.  Bisecting (a host-built dev binary reproduces it, so it is a source
bug, not a codegen one) traced it to `binder.mt`: the `member_names` edit had
dropped the unrelated `type_param_names.set(vr.name, vr.type_params)` line, so
an importer's binding lost every variant's type parameters.  Restored — and with
the variant type parameters back, the arm-payload substitution through a
prelude method (`err_val.error()`) also resolves, closing completion's
`lb@803:23` **and** the `lb@807:8` hover: both classes now say `Option[int]`
where they said `Option[E]`.

### The request boundary: UTF-16 positions converted to byte offsets (2026-10-03 session 27)

Track 1's last unintended completion entries were the two byte-vs-character
positions (`mst@10:52`, `mst@11:21`): the audit sends **character** offsets
(Ruby `MatchData#end`), the self's token scanners work in **bytes**, and on a
line with a preceding `§` (2 bytes, 1 UTF-16 code unit) the raw value lands one
byte short — on the dot rather than after it — so the receiver walk fell back
where the host lists the receiver's members (`heap.` answers the module's 26
items at byte 53, the prefix fallback's 2 at byte 52).  The probes
(`tmp/hl_probe.rb`, the two positions ±1) confirmed the conversion hypothesis
before any code changed.

- **The boundary** (`mtc/lsp/utils.mt`, `workspace.mt`, `server.mt`,
  `formatting.mt`, `cursor.mt`'s header): `utils.utf16_column_to_byte` walks a
  line's UTF-8 (1 unit per ASCII/BMP character, 2 for an astral one, a
  mid-surrogate column clamping forward to the character's end) and
  `utils.position_to_byte` slices out the 0-based line; a column past the line's
  UTF-16 length — or a line past the end — keeps the raw value, so the
  out-of-range probes keep the callers' existing bounds behavior.
  `Workspace.position_byte_offset(uri, line, character)` runs it against the
  document's current text (open buffer first, like every handler);
  `position_params` wraps `extract_position_params` for the 14
  position-carrying dispatch arms, `extract_selection_positions` converts each
  `selectionRange` position, and `rangeFormatting` converts its range's start
  and end (the response still echoes the requested range).
- **What stays as it is**: *emitted* positions remain byte columns, exactly as
  the Ruby host's are (its lexer runs on the `String#b` line, so `token.column`
  is a byte column and `encode_char_for_client` is an identity).  The host's own
  input decoding (`decode_client_char`) is a plain copy under utf-16, so it
  resolves its slice-based paths by characters; the self now resolves every path
  by the byte offset a spec client means — a deliberate correction that also
  makes a real editor's cursor land on the identifier it points at.
- **Measured**: the SimpleGame audit's completion pass **4 → 2** (both
  documented: the host's synthesized `ref[@_mt_N, ubyte]` field detail, and the
  host's method fallback for an untyped `map_error` arm binding where the self
  answers the field) and the full matrix **6 → 4 stable + the first-file
  `documentSymbol` race**; hover/definition/declaration/typeDefinition/
  implementation/references/semanticTokens/diagnostic/documentSymbol all 0 (the
  16 `mst` and 18 `data_structures` sampled positions after non-ASCII text sit
  inside comments and stay null on both sides).  The 2-file fixture
  (`tmp/s27-ws`) reads the same residues (5 → 3, the two extra being the
  completion-only run's host facts-lag artifact and the `ref` lifetime); the
  harness stays 30/30 + 4 documented (the `stress/unicode+*` probes are
  position-adjacent and unchanged); recovery is OK; valgrind 0 errors; the
  Neovim smoke passes.
- **Gates**: dev build + `tmp/mtc-dev test projects/mtc` (15 files / 0 failed),
  bootstrap (fixed point, 15 files / **596 tests** / 0), `build/stage2/mtc test
  test/mt` (60/0), the LSP gate set above.  New
  `projects/mtc/test/lsp_utils_test.mt` pins the ASCII/BMP/astral mappings, the
  out-of-range rule and the line-slicing.

### Stage-14 leftovers: call hierarchy, linked editing, inlay hints, executeCommand (2026-10-03 session 28)

Track 7's five small parity items, each **verified first** (the plan's "verify
each against §0k before starting"): the old records had drifted —
`prepareCallHierarchy` on an imported callee answers null on *both* servers
(the host's `facts.imports[alias].functions` path needs a receiver the harness
shape has), and `typeDefinition` on a function already resolved.  The corpus
gained eleven entries plus an `inlay.mt` fixture (**66 requests + 19 probes**),
and the harness now reads **5 documented entries** — 2 in the request corpus
(`milkTea/debugInfo`, `typeDefinition/imported`), 3 in the stress probes (the
parser-recovery, malformed-frame and facts-lag rows).

- **`prepareCallHierarchy`** (`call_hierarchy.mt`): the host's item is always
  `kind: 12` with `"receiver_type": null` — `build_call_hierarchy_item`'s
  `binding.respond_to?(:receiver_type)` is false for the facts' callable
  bindings — so the self's method rendering (kind 6,
  `receiver_type: "Sample"`) went; `KIND_METHOD`, `render_receiver_type` and
  the now-unused `ast_formatter` import are gone.
- **`linkedEditingRange`** (`linked_editing_range.mt`): the host's gate
  requires a *local* binding (`rename_target_binding_id` + `local_binding_id?`
  over `LocalDecl`/`Param`/`ForBinding`/`MatchArm`/`MatchExprArm`) and
  non-empty ranges.  The self answered any same-scope occurrence, so a type or
  function name returned ranges the host leaves null;
  `scope.local_binding_line` now provides the gate, and an empty range set
  answers null.
- **`inlayHint`** (`inlay_hints.mt`): two gaps the fixture pinned —
  (a) the host's inferred **return** hints (`collect_inferred_return_hints`):
  a callable without a written return type whose resolved type is not `void`,
  which in practice is the async wrapper (`-> Task[void]`) — the self's
  `has_return_type` carries the same distinction, and the hint is emitted last,
  in declaration order, like the host's concatenation; (b) **receiver-aware
  argument hints** (`s.scale(2)`): the receiver resolves to a value type
  (`navigation.type_of_value`, made public), a bare type name, or an imported
  declared type, and the signature comes from the current module's
  `method_sigs` or an import's table, first wins — the host's
  `methods_for_receiver_type` merge.
- **`executeCommand`** (`execute_command.mt`): an unknown command answers
  `null` like the host (was `-32601`).
- **`typeDefinition`** (verified, then classified): on a function, a std
  member and an imported *method* both servers agree (the new
  `typeDefinition/function`, `/std-member`, `/imported-method` and
  `definition/imported-member` entries lock them); on a **directory-form
  module** member (`import mod_alpha` → `mod_alpha/lib.mt`) the host answers
  `null` — its `module_path_for_name` builds `<root>/mod_alpha.mt`, which does
  not exist — while the loader-backed self answers the declaration.  Kept as
  the fifth documented entry (self-better, like the audit's `lb@818:17`).

**Two extras the fixture surfaced.**

- **`workspace/symbol`** (`workspace_symbols.mt`): the host's document set is
  `@indexed_documents.keys + @open_documents.keys` — the workspace-walked
  documents in `Dir.glob(File.join(root, '**', '*.mt')).sort` order, then the
  on-demand reads, then the open ones, deduplicated.  The self iterated only
  the definition index's warm paths then the open documents, so a
  walked-but-unwarmed file's symbols were missing and the order differed (the
  index walk itself is readdir order).  The handler now collects the walked
  paths, sorts them and emits through a shared per-document emitter.  Cost: a
  `document_source` read per walked file per request (the host caches contents
  — the F9/C3 content-cache item is the follow-up).
- **The immutable-assignment sema message** (`diagnostics.mt`, `analyzer.mt`):
  the self said `cannot assign to immutable binding <name>`; the host says
  `cannot assign to immutable <name>` and anchors the error at the assignment
  operator while spanning the *target's name length* (`raise_sema_error` with
  no node → `current_error_node` = the `AST::Assignment`, whose column is the
  operator; `source_length` falls back to the target's name).  Both fixed,
  locked by the fixture's `total += ...` (the same file's diagnostic array is
  part of the `workspace/diagnostic` entry).

**Measured**: harness **66 requests + 19 probes**, 30/30 capability keys,
5 documented entries with `--stress`; the SimpleGame audit unchanged at
**4 stable differing entries + the first-file `documentSymbol` race**
(completion 2, hover 1, documentHighlight 1 — `diagnostic`, `inlayHint` and
`workspace/symbol` all 0); recovery OK; valgrind 0 errors; the Neovim smoke
passes.  Gates: dev tests 15/0, bootstrap fixed point (15/0), `test/mt` 60/0,
the analyzer/CLI/lint meters at their ledger values.

### The owning-release pair: the host's release rules (2026-10-01 session 18)

`owning-release-double` was anchored on the *receiver* (`heap.release_and_null(x)`
reported `heap`) and fired at the wrong sites, and `owning-release-leak` never
fired for `own[T]`.  Both are now the host's `release_rules.rb` paths:

- **the sequential double release** (`check_owning_release_double`): per
  statement list, a release site per binding — `x.release()` (no arguments) and
  `heap.release(x)` / `heap.release_and_null(x)` (naming the last direct
  identifier argument, through `ref_of`/`unsafe:`), with an `=` assignment to a
  visible binding clearing that binding's history; two releases through one
  sequence report at the *last* release's line with the binding's name (the LSP
  recovers the range from the quoted name, exactly as the host's nil-column
  warning does).  `unsafe:` and `defer:` bodies are separate sequences whose
  results merge after the outer one.
- **the `own[T]` leak** (`check_own_release_leaks`): a local whose initializer
  is a heap allocation (`own[<inferred>]`) or whose resolved initializer type is
  an `own[T]` generic instance (from the analyzer's `resolved_expr_types`) that
  is never released and never transferred — anchored at the declaration with
  the resolved type name (`owning binding 'raw' of type 'own[int]' is never
  released`).
- the old heuristic double-release emission (receiver-named, per expression) is
  gone from the struct-owning walk, which keeps its leak half — and its release
  bookkeeping: `x.release()` still marks x as released for the struct-leak check
  (the host's `_collect_released_names_in_expr`), which the first cut of the
  change had dropped, re-reporting twenty `Vec`/`Deque`/`Queue` leaks on
  `docs/data_structures.mt`.

**Measured**: `docs/memory_stress_test.mt`'s diagnostic array is **byte-identical
to the host's** (10/10 items: `335:33-38 'owned'` and `440:8-11 'raw'` where the
self had `335:4 'heap'`, `403:8 'heap'` and no leak), and
`docs/language_baseline.mt` stays identical.  With this the **diagnostic class
reads 0 differing entries** in the full matrix — all seven files' diagnostic
arrays are byte-identical to the host's (the initial cut's dropped release
bookkeeping showed up as 20 self-only leaks on `docs/data_structures.mt`; the
fix is in the same commit).

### `constant-condition`: the host's dataflow rule (2026-10-01 session 18)

The self's rule was a forward integer-value map plus a trivial
self-comparison check; the host runs `ControlFlow::ConstantPropagation` over
the CFG and folds the condition with `CompileTime.evaluate` (identifier
resolution only — member access and calls are "not constant").  The port
replaces the whole rule:

- `linter/constprop.mt` is the host's lattice: `undef` / a constant / `nac`,
  `join_lattice` (undef yields, nac absorbs, two different constants meet at
  nac, an int and an equal float are the same constant), and the per-write
  transfer (`local_decl` initializers, assignment values with the compound
  operators).  Values are integers, floats, booleans, strings, `..` ranges
  (the host materializes `(left...right).to_a`; only indexing, slicing and
  comparison matter) and expression lists.  The folder covers literals,
  identifiers, unary/binary operators (arithmetic, bitwise, shifts,
  comparisons, `and`/`or` short-circuit), index access (a string's byte or
  slice, a range's element or sub-range, an expression list's element), `if`
  expressions and numeric prefix casts.
- the rule walks the graph's `if_condition`/`while_condition` nodes in node
  order, skips an if-condition the host's `compute_loop_body_nodes` marks as
  reachable from a back edge (the host's over-approximation is why an
  if-condition *after* a loop is skipped too), skips `while true`, and anchors
  on the source line's keyword-to-colon span (`condition_span` /
  `source_condition_span`), with the `branch condition is always true|false`
  and `loop condition is always …` messages.  The trivial self-comparison
  fallback is gone: a comparison of two unknown bindings folds to nac in the
  host, so it never fires.
- the walk carries the file's source lines (`lint_source_lines`) for that span.
- **the graph builder gained a missing edge**: a `let … else:` declaration's
  success node dead-ended (the host's `add_linear_node(…, next_id)` continues
  into the next statement), so nothing after a let-else had a dataflow state.
  With the edge, `let val = maybe_int else: …` folds `val` to the initializer's
  value (the lb 1387 entry).

**Measured**: `docs/language_baseline.mt`'s diagnostic array is **byte-identical
to the host's** — 98/98 items, `tmp/lint_table.rb` reports 0 differing lines
and `rake parity:scoreboard` 0 rules with a count mismatch (both were 8 lines
at the session-17 close).  The fixture sweep is at its baselines (the two
already-documented closures only) and the self-host linter tests for `if a == a`
were updated to the host's semantics (no warning: `a` is nac).  Gates:
bootstrap fixed point + 14/14, `test/mt` 60/0, `cli:parity` 23/38/0, sexpr lex
705/705 + parse 701/0, `unused_import_parity` 609/609.

### The linter's walk: the host's emission order (2026-10-01 session 18, F3 part 3)

The diagnostic class compares whole *arrays*, and the two files' counts already
matched after session 17 — what was left was the order.  The self ran two walks
(the linter's inline visitor over the whole file, then `scope_tracking`'s scope
pass) where the host has one, plus whole-file passes at the end.  Now the
linter's visitor **drives** the scope state machine, so the warnings interleave
exactly as the host's visitor emits them:

1. `unused-import` and the module-level reserved names lead (the host's
   `seed_module_bindings` + `check_unused_imports`).
2. Per declaration, in source order: a method's reserved name (before its body),
   then the function scope, the type-parameter reserved names, the parameters,
   the statement walk (with each nested scope's pop *inside* it), the per-body
   rule group — dead-assignment → unreachable → borrow → constant-condition →
   redundant-null-check → loop-single-iteration → owning-release →
   prefer-let-else/prefer-var-else — then `redundant-return`, then the function
   scope's pop (`unused-local`/`unused-param`/`prefer-let`/`prefer-own-ptr`),
   then `missing-return`.
3. The whole-file passes keep their tail order: doc-tag, event-capacity,
   trailing-list-comma, prefer-inline-methods, line-too-long.

The pieces of the move:

- `scope_tracking` keeps only the state (push/pop, declare, mark-used/mutated,
  editable/mutating/alias hooks, binding ids) and the `unused-import` prelude;
  its separate walk and its emission are gone.  The linter owns the pop's
  warnings, so `prefer-own-ptr` fires there too — its state is name-keyed like
  the host's (`@ptr_candidates` + `@binding_ptr_unsafe_uses`), filled at each
  local declaration and each identifier use with the enclosing `unsafe:` depth.
- `redundant-cast` moves from its whole-file walk to per-site hooks the walk
  drains in order (`check_local`/`check_assignment`/`check_return`/
  `check_prefix_cast`/`check_binary_operands`).
- `reserved-primitive-name` moves to its host positions: module-level
  declarations at the head (function/constant/module variable/event/extern/
  foreign, the host's `seed_module_bindings`), a method's name before its body,
  type parameters at the function's entry, locals and parameters at their
  declaration.  The self-only struct/enum/type-alias arms are dropped — the
  host has no arm for those declarations.
- `constant-condition`'s forward-propagation fold is back as the per-body
  `constprop.collect_constant_conditions_body` (the whole-file wrapper is gone).
- The walk now matches the host's statement semantics: a statement list stops
  visiting after `return`/`break`/`continue`, a `parallel:` block is *not*
  visited (the host has no arm; `parallel for` is a normal `ForStmt`), `for`
  raises the loop depth like `while`, and a match arm's binding declares its
  local inside the arm scope.
- `defer` bodies are their own scope and `let … else:` declares its
  `else_binding` in the else scope (the host's `LocalDecl` arm).

**Measured**: the two diagnostic arrays now agree item-for-item except the two
content rows — `docs/language_baseline.mt`'s first divergence moves from index
0 to index 7 (the `constant-condition` anchors) and
`docs/memory_stress_test.mt`'s from 0 to 3 (the `owning-release` rows); every
other item is byte-identical (same range, code, message, severity).  Counts
unchanged: lb host 98 / self 98, mst host 10 / self 10, `rake parity:scoreboard`
0 rules with a count mismatch.  The fixture sweep is at every baseline except
`hover-probe4`'s diagnostic entry, which this order closes (the host emits the
owning-release leak before the function scope's pop; the self did the reverse).
Gates: bootstrap fixed point + 14/14, `test/mt` 60/0, `cli:parity` 23/38/0,
sexpr lex 705/705 + parse 701/0, `unused_import_parity` 609/609, every fixture
at its baseline (the one closure above).  The self-only linter tests for
`x == x` constant conditions were updated to the host's semantics (a
comparison of two unknown bindings is not constant).

### Session-17 close (2026-10-01): the matrix at 4, and what is left

Three commits: F8.2 closed (`cc624800`, documentSymbol 1 → 0, the matrix
5 → 4), the linter's per-rule anchor/message/firing deltas (`1e147e12`, every
*count* now matching — `rake parity:scoreboard` reads **0 rules with a count
mismatch**, from 8) and the imported-type completion fix (`5e272a4f`, below).

State at the close — the SimpleGame full matrix (6456 entries) reads
**4 differing entries**: `diagnostic` 2, `documentHighlight` 1, `hover` 1;
`documentSymbol`, `semanticTokens`, `codeLens`, `foldingRange`, `inlayHint`,
`documentLink`, `workspace/symbol` and definition/declaration/typeDefinition/
implementation/references are all **0**.  Everything else green: bootstrap fixed
point + 14/14, `test/mt` 60/0, `cli:parity` 23/38/0, sexpr lex 705/705 + parse
701/0 + `lower` 39 match / 615 differ / 51 host-rejected / 0 self-rejected,
`unused_import_parity` 609/609, the harness 30/30 + its 4 documented entries,
the recovery probe, the fixture sweep at every baseline (added 0), the formatter
**705/705 in all three modes**, the example sweeps (15/15, 34/34, two raylib),
valgrind 0 errors over an LSP drive, the headless-Neovim smoke.

What is left, revised at the session-17 close (a snapshot — the live ranked list
is the program above):

1. **`diagnostic` 2 — the linter's emission order** (the two-walk merge: the
   scope walk drives, the inline rules fire at each statement, the per-function
   flow rules and the function's scope pop follow, then `missing_return`; the
   whole-file passes keep their tail order).  With the counts already matching,
   this alone should close the class.
2. **`diagnostic` 2 — `constant-condition`** (lb, 4 items: the source-line
   `condition_span`, the `branch`/`loop` message, the `ConstantPropagation` port)
   and **`owning-release-double`/`-leak`** (mst, 3 items: the CFG release path
   and the released binding's `symbol_name`).  One commit each.
3. **`hover` 1 — `type quat`** (`lb@1653:24`): the definition index never
   covered a std module nobody opened; warm/index the std modules whose
   `extending` blocks a file references (or resolve from the loaded module
   binding) and re-run the audit twice.
4. **`documentHighlight` 1** (`lb@704:67`): the host's warm-facts snapshot
   carry-forward, measured in both states — the self matches the host's *cold*
   answer byte for byte, and the host's warm answer is a name-keyed-snapshot
   artifact the self's bindings cannot express.  Documented as a deliberate
   difference; no action unless the snapshot machinery is built for other reasons.
5. **F9 readiness** (`ScanFacts` release, the reference index's document texts,
   `note_document_tokens` caching) — valgrind reads ~91 MB "definitely lost" over
   an LSP drive.
6. Beyond the LSP: the compiler tracks — `lower` dump parity (615 differing
   files, Phase 2's ranked items), CLI parity (38 differing cases), DAP's
   build-on-launch (`*launch(.mt)` reports "Milk Tea binary not found" on the
   self where the host is `ok`), and the self-only `imported-bindings --all
   --check` (3 verified / 25 "changed" — triage cosmetic vs behavioural first).

### Imported-type member completion (2026-10-01 session 17): `n.` on an imported struct

Reported from the SimpleGame project: in `src/main.mt` a `Node` local
`var n = node.Node.create(c"Hello")` offered **no** completions after `n.`,
while the host lists `name`, `parent` and `static:create`.  Two causes, both in
the completion path:

1. **The buffer was checked single-file.**  `handle_completion` ran
   `analyzer.check_source_file` — no imports bound — so the imported
   construction's type was `ty_error` and the receiver resolved to nothing.  It
   now uses the loader-backed analysis through the same convention the hover,
   outline and definition paths use (`analysis_for_document` /
   `ast_for_document`), re-pointing `ast_file` at the tree the analysis was built
   from, since `resolved_expr_types` is keyed by expression pointer.
2. **The value-receiver path only read the current module's tables.**  An
   imported struct's fields are in neither `Analysis.structs` nor the file's AST,
   and the empty-but-non-null result suppressed the host's method-list fallback.
   The analyzer now records every imported module's structs and unions with their
   method signatures while the bindings are borrowed (`Analysis.imported_type_members`,
   keyed `<module>.<Type>`), and the completion reads that record for a
   `ty_imported` or module-qualified `ty_named` receiver — the two shapes the
   analyzer produces for one imported type — rendering each member with the
   declaring module's qualification, exactly the host's `Types::Struct#to_s`.

A third delta surfaced while checking a *local* struct receiver: the method list
rendered from the AST alone (`make() -> LocalThing`, no `static:` marker) where
the host renders from its method table (`static:make() -> local_probe.LocalThing`).
`emit_type_methods` now goes through `emit_resolved_method_item`, which prefers
the analysis's signature for the label, the parameter text, the detail, the call
snippet and the label details, and falls back to the AST rendering when no
signature is recorded (`method_fallback_completions` keeps using that).
`append_item_ext` also emits `insertTextFormat` **last**, where the host sets it
— key order is invisible to clients but visible to a byte comparison.

Measured on SimpleGame `src/main.mt`: the host's three items and the self's are
**byte-identical** — `name` (`name: cstr`), `parent` (`parent: ptr[node.Node]?`)
and `static:create` (`static:create(name: cstr) -> node.Node`, with the
`${1:name}` snippet, the ` (name: cstr)` label detail and `insertTextFormat: 2`).
Verified both in the committed file (`… n.name …`) and in the reported mid-edit
shape — a bare `n.` line whose buffer no longer parses — and the local-struct
pair (`first`/`second`/`static:make`/`describe`) matches too.  The host answers
completion only once its facts exist (`unless facts → []`), so the probe warms
with a `textDocument/diagnostic` first (`tmp/hl_probe.rb --warm`); the full
matrix is unchanged by all of this (`4 -> 4`, closed 0, added 0).

### Linter stage 11b: the anchor, message and firing deltas (2026-10-01 session 17, F3 part 2)

The diagnostic class compares whole *arrays*, so this is the content half of F3;
the order half (the host's walk order, which the self still does not reproduce)
is planned in §0k's absorbed F-block ("Foundational blockers — absorbed plan
record") and the session-18 records.  Every row below was measured with `tmp/diag_probe.rb`
(per-item ranges/messages) and `tmp/lint_table.rb` (per-rule counts and the
differing lines).

**The range conversion itself.**  `lsp/diagnostics.mt` now mirrors the host's
`extract_warning_range` exactly: a warning that carries a *column* and no length
spans **one** character (`len = 1 if len <= 0`), and the quoted-symbol search
runs only for warnings with no column at all.  The self used the quoted name in
both cases, which is why the conciseness hints came out 6–10 columns wide where
the host's are one.

**New span helpers** (`linter/linter.mt`), all mirroring the host's
`source_helpers.rb`: `expression_length` (an identifier is its name, literals
their lexeme, `bool` 4/5, `null` 4, a binary expression the distance from its
left operand's column to the right operand's end, else 1),
`binary_expression_length`, `statement_column` / `statement_length` (the
statement's own recorded length — the parser stamps `return`/`while` — with the
host's per-kind fallbacks), `first_branch_column` and `visually_inline_if`
(the host's `visually_inline_if?`: every branch body on its branch's own line and
the else body on the else line — the host's `inline_if_too_wide?` reports
exactly these as unjoinable, which is its gate on the conditional-expression
rule).

**Rule rows closed** (each verified by the probe: the entry disappears):

1. `noop-compound-assignment` — the assignment's line, the target's column, the
   target identifier's length.
2. `self-comparison` — the whole binary expression's span.
3. `redundant-return` — the statement's own length (the `return` keyword, 6).
4. `redundant-type-annotation` — skips a *nullable* annotation
   (`let x: int? = 42` never warns, the host's `return if statement.type.nullable`)
   and spans the local's name.
5. `unreachable-code` — `statement_column`/`statement_length` and the bare
   message `unreachable code` (was `0:0→1` with
   "…after a terminating statement").
6. `prefer-inline-if` — anchored on the branch (the `if` keyword), plus the
   `visually_inline_if` gate; `prefer-conditional-expression` — the host's
   messages (`every if branch assigns to 'X'; rewrite as `let X = if …`
   expression`), the `if`/`match` anchors, the loop-depth gate (a new
   module-level `lint_loop_depth`, the host's `@loop_depth`) and the same
   visually-inline gate.
7. `prefer-or-pattern` — `expression_column` now returns a member access's *own*
   column (the member token's), as the host's `expression_column` does with its
   first `expr.column` check; the pattern `Palette.green` anchors at `green`.
8. `prefer-is-variant` — the host's `desugared_from_is` gate (the three lb
   firings were all `is`-expression desugarings) and the match expression's own
   span.
9. The scope warnings (`unused-local`/`unused-param`/`prefer-let`/
   `unused-import`/`shadow`) carry the binding name's length
   (`ScopeWarning.length`, the host's `binding.name.length`), and a
   destructuring `let (a, b) = …` declares **no** tracked binding — the host's
   LocalDecl arm declares only `statement.name`, so a destructured name never
   draws unused-local (`msg` at lb 1942 closed).
10. `reserved-primitive-name` — `RESERVED_VALUE_NAMES` is now the host's
    `Types::RESERVED_VALUE_TYPE_NAMES` exactly (`BUILTIN_PRIMITIVE_NAMES` +
    `Option`/`Result`): the container names (`ptr`, `ref`, `span`, `own`) and
    `type`/`fn` are **not** reserved value names, so
    `let ptr: ptr[int]? = null` is clean (this is the lb 1377 firing).
11. `prefer-own-ptr`'s message now matches the host's
    ("…consider converting its type from ptr to own…").
12. **`redundant-unsafe` — the rule was missing entirely.**  The analyzer now
    carries the host's record: `Context.unsafe_statement_lines` (a stack of the
    enclosing `unsafe:` nodes' lines, pushed at both the statement and the
    expression form) and `required_unsafe_lines`; every operation that
    *requires* unsafe marks the enclosing node's line
    (`mark_required_unsafe`, the host's `mark_current_unsafe_required!`) — the
    five sites are the pointer cast, pointer indexing, pointer arithmetic,
    `reinterpret` and `read`.  `Analysis.unsafe_statement_lines` (a field that
    had been a placeholder) now carries the set, and the linter's visitor emits
    the host's warning at the `unsafe:` node itself (block *and* expression
    form, column + length 6), skipping generic bodies
    (`lint_generic_depth`, the host's `generic_function_context?`).

13. **`prefer-own-ptr` is the host's rule** — the old implementation warned when
    a `ptr[...]`-annotated local had no *observed* use, which is why it fired on
    `let ptr: ptr[int]? = null` (never used) and on `as_byte_ptr` (used only as a
    method receiver).  `linter/own_ptr.mt` now mirrors the host: candidates are
    declarations with a `ptr`/`const_ptr` annotation **or** a heap-allocation
    initializer (`heap.must_alloc`… family), uses are counted recursively with
    the enclosing `unsafe:` depth (identifier uses and member receivers), and the
    warning fires only for a non-parameter binding with `unsafe > 0` and
    `safe == 0`.  Its anchor is the binding (`line`, `column`, `name.length`).

14. Two analyzer facts the linter rules above were reading through stubs:
    `span[T]`'s members are now `data: ptr[T]` / `len: ptr_uint` (the host's
    `Span#fields` — this is what made `redundant-unsafe` fire at `mst 323`, where
    `read(view.data + 0)` needs unsafe), and a *field read through a raw pointer*
    requires unsafe (`resolve_member_access` reports, or marks the enclosing
    `unsafe:` node inside one) — the host's
    `raw pointer dereference requires unsafe`, which is what the `eventprobe`
    fixture caught.

**Measured**: `language_baseline.mt` host **98 / self 98** and
`memory_stress_test.mt` host **10 / self 10** — the counts now match on both
files.  What remains is the *array order* (the emission restructure above) plus
two content rows: `constant-condition` (lb: four entries whose anchors/messages
differ — the source-line `condition_span`, the `branch`/`loop` message and the
`ConstantPropagation` port that decides *which* condition is true) and the
`owning-release` pair (mst: `owning-release-double` anchored at the binding
rather than the declaration and `owning-release-leak` missing — the CFG path and
the released binding's `symbol_name`).

### The analyzer's initializer typing and the outline residue (2026-09-30 session 17, F8.2 closed)

The outline's remaining `docs/language_baseline.mt` residue was **24 details plus
one ordering**, not the fifteen the session-16 note listed: `tmp/ds_diff.py`
compares by array index, and the two `emit` symbols sitting in the wrong place
shifted every later index, hiding the tail.  The working comparison
(`tmp/ds_residue.py`) keys by name and compares the probe's *self* against the
**full audit's host** — the probe's own host answer can be the cold-state one.

**The analyzer typing** (`semantic/analyzer.mt`), each entry measured against the
host's recorded type:

1. `str + str` concatenates (`infer_binary`'s `"+"` case; new `types.is_str`) —
   `hello`/`prefix`/`_h`/`_p`.
2. A builtin construction with explicit type arguments resolves to the
   specialized builtin type: `check_specialization_call` routes `array[T, N](…)`
   and `span[T](…)` to `check_builtin_construction`, which mirrors the host's
   `check_array_construction` / `check_aggregate_construction` — named arguments
   against `span`'s `data: ptr[T]` / `len: ptr_uint`, at most N positional
   elements for `array[T, N]` — reports the host's messages (`array expects at
   most 3 elements, got 4`, `field span[int].data expects ptr[int], got
   own[ubyte]`), and yields the error type on failure so nothing is recorded for
   the expression.  `span_data_fits` states the host's pointer rule: the pointee
   must match **exactly** (the self's general assignability would widen `ubyte`
   to `int`).
3. `ptr_of` over a borrow is the pointee's pointer: `ptr_of(ref_of(x))` is
   `ptr[T]`, not `ptr[ref[T]]` (the host's `check_ptr_of_call`).
4. A `ptr[T]` method table (`ptr_method_sig`, beside the `atomic`/`str_buffer`
   ones): `load`/`store`/`load_at`/`store_at`, the API `std.mem.ptr` declares
   through `extending ptr[T]:`.
5. A native vec/mat/quat `with` returns the receiver's type
   (`v3.with(x = 99.0)` -> `vec3`).
6. Tuple element access resolves through `check_member`'s new `ty_tuple` arm:
   `pair._0` positionally, a named tuple's `point.x` by name.
7. An instantiated *local* generic struct's fields read with the instance's
   arguments substituted (`local_type_substitution`): `Pair[int, float](…)`'s
   `pair.first` is `int`, not `<error>`.

**The outline renderings** (`lsp/symbols.mt`, `lsp/type_render.mt`):
`append_own_name` keeps only a nested type's own segment (`Rectangle.Edge` is the
host's `Edge` — the host's `short_type_detail` renders the declared type's
`name`); `short_name` renders a named tuple (`(x: int, y: int)`);
`append_ast_type` renders `dyn[Mapper]` from the interface name alone;
`append_type_decl_detail` carries lifetime parameters (`[@a]` for
`struct Buffer[@a]`); and a **local in a generic body carries no inferred
detail** — the host's facts record none for a body inside a generic function or
a generic `extending` block (an explicit annotation still renders, and `let n =
5` there has no detail either).  The harness's `documentSymbol/generics` entry
is what caught the latter: the self's new `A` detail was *more* correct than the
host's omission and still a parity difference.

**The emit ordering**: `emit`-declared functions are appended to the declaration
list by the analyzer (`expand_emit_declarations`, mirroring the host), while the
host's outline lists each where it is written.
`append_emit_declaration_symbols` walks the enclosing const function's body for
`stmt_emit` statements (including the inline forms the analyzer's own
`collect_emit_from_body` descends into) and emits their symbols there; the
top-level walk stops at the appended tail (`emitted_start`, from the
pre-expansion declaration count).

**Measured**: the audit's documentSymbol class **1 → 0** — all seven files
byte-identical to the host's answers, `docs/language_baseline.mt`'s 758 symbols
included, with `zero_meaning`/`hex_prefix` at their source position.  The matrix
went 5 → 4 on the real residue (the run reading 5 has the host's first-file
`docs/data_structures.mt` race as its fifth: the host answers it unwrapped and
detail-less, and the self's answer equals the *previous* run's host answer byte
for byte).  The harness reads 30/30 capabilities and its documented 4 differing
entries with `--stress` (1 request — `milkTea/debugInfo`'s token-kind line — and
3 stress probes); `documentSymbol/generics` closed with the generic-context
rule.  Lint scoreboard unchanged (host 98 / self 107, 8 rules
mismatching — the `documentSymbol` work is analyzer *typing*, and the span
validation adds no diagnostic on the audit's files).  Gates: bootstrap fixed
point + 14/14, `test/mt` 60/0, `cli:parity` 23/38/0, sexpr lex 705/705 + parse
701/0, `lower` 39 match / 615 differ / 51 host-rejected / **0 self-rejected**
(the two `projects/stress` guarded-`Result` files that used to be the
self-rejected pair now compile; that pair is the whole 613 → 615 drift),
`unused_import_parity` 609/609, the fixture sweep at its baselines everywhere
(closed 0, added 0 — `hover-probe5`'s intermediate state, which added its
documentSymbol entry, is what the span validation closes), the example sweeps
(`examples/*.mt` 15/15, `examples/sdl3` 34/34, two raylib samples), valgrind and
the headless-Neovim smoke.

**Session 16 close (2026-09-30)** — seven commits, audit 13 → 5, in the order
F3 part 1 → F4 → F5 → F7 + F8.1 → F8.2 (the all-or-nothing linter class left
last): F3 part 1 (liveness → `dead-assignment`, `501ab123`; the firing set by
ascending node id; `linter/cfg.mt` and its import deleted), F4 (destructure types
+ variant arm payloads, `15a8572b`; the prefer-let sweep over `std/` 121 → 45 →
32), F7 + F8.1 (callable-value sites + the scanner's nested-type and
callable-field rules, `a90c2e19` — `language_baseline`'s token stream
byte-identical), F5 (function-type names, `6ad423ce` — hover 2 → 1) and F8.2's
outline shapes (three of four files byte-identical).  Residue at close: hover 1
(the documented `type quat`), documentSymbol 1 (`language_baseline`'s thirteen
locals whose initializer type is still `ty_error`, plus two `emit`-expanded
consts), diagnostic 2 (the F3 linter residue: the emission-order restructure +
the 18 per-rule deltas), documentHighlight 1 (F8.3).  `lower` 39/613,
`unused_import_parity` **609/609** (the `async_network_lobby` residual closed),
prefer-let over `std/` 32 (imported-receiver method chains typed `ty_error`).
Next: F8.3's decision, then the F3 residue, then the analyzer's initializer
typing.

### The outline's declaration shapes (2026-09-30 session 16, F8.2)

`src/colors.mt`, `src/node.mt` and `docs/memory_stress_test.mt` are now
byte-identical to the host's outline; `docs/language_baseline.mt` is down to a
residue that is *analyzer* typing, not outline building (below).

The four measured causes, each now matched:

1. **An inline `extending` block merges into its struct's symbol.**  A struct
   whose methods are declared inside its body (`struct Node:` … `create`,
   `destroy`) used to produce two symbols (fields, then an
   `implementation`-detailed method block); the host reports one, with the
   fields and the methods as children, the `implementation` detail *after* the
   children (its enrichment appends children first), and the inline block itself
   contributes no symbol (`inline_struct_methods`, `emit_merged_struct_symbol`).
2. **A qualified `extending` receiver keeps the host's two symbols.**  For
   `extending rl.Color:` the host's flat token symbol is named after the
   receiver's *first* identifier (`rl`, in source order) and the enriched symbol
   — named as written (`rl.Color`) — is *appended after every flat symbol* with
   the host's hand-built key order (`emit_synthesized_extending_symbol`); the
   anchor pass no longer duplicates the first-part symbol.
3. **A module-level `when` keeps every branch's declarations** in source order
   (the host's flat token list sees each `keyword name` pair; only the analyzer
   reduces a `when` to its chosen branch), and the declarations of an `emit`
   block appear where they are written.
4. **The declaration details follow the host's renderers**: a function-typed
   field/alias renders `fn(int) -> bool` from the *source* annotation (the
   `fn ` shape is `Types::Function#to_s` — the hover's rendering, not the
   outline's), an interface carries its `[T, U]` clause and its type parameters
   as first children, a union reports no children, a nested type always reports
   a `children` array (with its own members), enum/variant members key their
   `detail` before the ranges, an extern/foreign declaration shows its return
   type, and `implements` keeps the interface's type arguments
   (`(Converter[int, int])`).  The two proc renderings are genuinely different on
   the host: the *outline's* detail prints the signature's parameter names
   (`proc(x: int) -> int`, its `Types::Proc#to_s`), while the *hover* prints the
   types alone (`proc(int) -> int`) — `outline_local_detail` mirrors the former
   and `types.type_to_string` the latter.  Substituting an *imported*
   `Option`/`Result` (the loader's `ty_imported` shape) now narrows like the
   generic one, which closed the four `guard_demo` details.

**The remaining `language_baseline.mt` residue** is thirteen locals whose
*initializer type* the analyzer still records as `ty_error`, so the outline has
no detail to print (`hello`/`prefix` — `str` concatenation; `nums`/`offsets` —
`array[int, 3](…)`; `sp` — `span[int](…)` and `value[0..1]`; `val_ptr` —
`raw_p.load()`; `_third` — `third.load()`; `expr_result` — a chain of operands;
`v3_partial` — a vector construction; `raw_p` — `ptr_of(...)` rendering
`ptr[ref[int]]` where the host says `ptr[int]`), plus the two `emit`-expanded
consts that keep a spurious `children` key.  Those are the same class as the
prefer-let sweep's imported-receiver residue: the *analyzer's* expression typing
for constructions, builtins and method calls — not outline work.

### The callable-value record and the scanner's two rules (2026-09-30 session 16, F7 + F8.1)

The last five differing token positions in `docs/language_baseline.mt` are now
identical to the host's — `ruby tmp/tok_diff.rb` reports **0**.

**F7 — the callable-value record.**  The scanner used to render `function` for
*any* identifier whose lexeme names a module function; the host renders it only
for the sites its analyzer recorded through `infer_identifier(..., expected_type:)`
(`callable_value_identifier_sites`).  The self now records the same sites in
`infer_identifier` (`Analysis.callable_value_sites`, a `line`/`column` pair),
with two guards: `Context.callable_site_suppression` is raised around the
compile-time handle builtins whose arguments are declaration *names*, not values
(`callable_of(identity)`, `field_of(T, f)`, `has_attribute`, `size_of`, …) —
which is why the host answers `variable` there; and declaration initializers the
self never infers (a const's value, a `foreign function … = atoi` mapping) are
walked by `record_decl_callable_sites` so their bare function names are recorded
too.  The scanner's value arm now requires `scan_callable_value_site`, so
`identity` (275:40) and the proc-parameter read `add` (1099:41) render
`variable` like the host's.  F7's original note — that `callable_of` needs "its
own hook" — was right about the cause and wrong about the direction: the hook is
an *exclusion*, not a record.

**F8.1 — the scanner's two rules.**  `dot_nested_type_member?`: a member of a
type-name receiver that names a type nested in that struct renders `type`
(`Rectangle.Edge`), collected as `<Type>.<Nested>` keys by a declaration walk.
`callable_field_member_access?`: a call through a struct field of `fn`/`proc`
type renders `property` (`f.check(5)`, `c.invoke()`); the scanner collects the
callable fields of every declared struct and the `<name>.<Struct>` pairs of
`let x = Struct(...)` receivers.  Because the self's receiver table is
name-keyed over the whole file (the host resolves the receiver scope-aware),
a later `let c = <other struct>(…)` used to hide the earlier binding: the table
keeps every pair and the lookup accepts any struct the name is bound to.

### Stage 11c: destructure bindings and variant arm payloads (2026-09-30 session 16, F4)

The analyzer now types the two binding forms that used to be permissive
`ty_error` placeholders, which is what three hover entries were waiting on.

**Destructuring** (`let (a, b) = …`): each name carries the tuple element at its
position (the host's `check_local_decl_tuple_destructure`), and the per-name
types are recorded in `Analysis.destructure_types` (line + name + type) — the
initializer itself is inferred *without* recording, so the recorded types (and
thus codegen) stay otherwise identical.  The LSP's `local_type_at_line` consults
that record before the initializer path, so `let sum_dest = a + b`'s `b` answers
`let b: int (immutable)` (`lb@1861:23`, `lb@1931:25`).

**Variant arm payloads** (`Option.some as p`): the binding is the host's
`Types::VariantArmPayload` — `types.ty_variant_arm_payload` gained
`display_name` (the instantiated `std.option.Option[(str, str)]`) and `fields`
(`PayloadField`), with a new `variant_arm_payload_with` constructor for the
analyzer; the lowering keeps calling the four-argument constructor, so its
payload struct names are untouched.  The prelude's arms register their declared
field names (`register_prelude_arm_field`: `Option_some` -> `value: T`,
`Result_failure` -> `error: E`) and their type parameters
(`variant_param_names`: `Option` -> `[T]`, `Result` -> `[T, E]`), and
`match_arm_payload_type` substitutes the scrutinee's type arguments into each
field (`Result[bytes.Bytes, Error].success as ok_payload` -> `value:
bytes.Bytes`).  Both match forms (statement and expression) compute the
scrutinee's type **once**, before the arms, and pass it to `check_match`
(recomputing it there would double-report an unknown name in the scrutinee).

Consequences: `p.value` resolves through `check_member`'s payload arm; the
analyzer records `Analysis.arm_binding_types` so the LSP answers
`local p: Option[(str, str)].some payload (mutable)` with the host's
`*From std.option*` line at the declaration *and* at every use
(`lb@1915:25`); and `record_expr_type` never records a payload type, because the
lowering registers the payload struct's C name itself
(`variant_arm_payload_binding`) — handing it an analyzer-built type whose C name
it never declared would break codegen.

**Measured**: the SimpleGame full matrix **13 → 11 differing entries** (hover
5 → 2: only F5's `fn ` field and the documented `type quat` remain; added 0
apart from the host's first-file documentSymbol race, below).  The prefer-let
sweep over `std/` drops **121 → 45** from the payload typing, then **45 → 32**
with the try operator's type (`infer_unary`'s `?` now yields the unwrapped
success type — `Result[T,E]?` / `Option[T]?` give `T`).  The remaining 32 are a
different root cause: a method chain on an *imported* receiver
(`read(protocol).pending_reliable.pop()`), whose result type the analyzer still
records as `ty_error`, so the editable-receiver record never fires.

### Liveness over the graph: `dead-assignment` (2026-09-30 session 16, F3 part 1)

The linter's `dead-assignment` rule no longer walks the AST: `lint_dead_assignment`
builds F1's graph per function body (`flow_builder.build_graph_into` with the
body's parameters), solves a new **backward union dataflow** over it
(`graph.mt`'s `LivenessFlow`: `reads | (live_out - writes)`, union join, empty
bottom, `live_out_has(node, key)` the host's `Result#live_out`), and emits the
host's `emit_dead_assignment_warnings` firing set from the write sites by
ascending node id — the builder's reverse-statement order, which is also the
host's emission order (verified on a two-dead-write fixture, which the host
prints 6-then-3 and the self now prints identically).

One deliberate divergence, forced by the self's *name-keyed* binding ids: the
host's guard chain is "skip `declaration`/`call_argument` origins, require
`readable_bindings` + `locally_declared`", which under its per-declaration ids
can only ever fire on an `assignment` origin.  Under name-keyed ids a `for`
binding whose name is declared again later in the same body inherits the
declaration (this is what made `language_baseline.mt`'s `for i in 0..4:` warn),
so the self states that equivalence directly: only `assignment`-origin writes
are candidates.  `linter/cfg.mt` (the old path-insensitive backward walk) is
deleted — nothing else used it.

Measured on the audit's two diagnostic files: `dead-assignment` **16 → 0** on
`language_baseline.mt` and 0 on `memory_stress_test.mt` (host 0 on both; the
self's warning total on the first file drops 123 → 107).  Gates: bootstrap fixed
point + 14/14, `test/mt` 60/0, `cli:parity` 23/38/0, sexpr lex 705/705 + parse
701/0.

**The diagnostic class needs more than rule content.**  The audit compares each
file's diagnostic *array*, and the host's order is its visitor order: statement
rules fire as the walk reaches them, a scope's `unused-local`/`unused-param`/
`prefer-let` fire when that scope pops (inside the walk), and the per-function
flow rules (`dead-assignment`, `unreachable`, `constant-condition`, the release
rules, `prefer-let-else`, `redundant-return`) fire at the *end of that function*.
The self emits all visitor warnings for the whole file first, then a separate
scope pass, then whole-file passes — so the sets can be equal and the arrays
still differ (`language_baseline.mt`'s host order starts `285 unused-local,
325 redundant-return, …` while the self's starts `325, 422, …`; on
`memory_stress_test.mt` the host emits `441 redundant-unsafe` *before*
`440 owning-release-leak`).  Closing diagnostic 2 therefore also needs the
linter's emission restructured to that walk order.  The remaining per-rule
content deltas (ranges, messages, firing sets) are listed in the session-16
prompt's ledger entry.

### Foundational blockers — absorbed plan record (F1–F9, sessions 15–18)

The focused plan (`docs/foundational-blockers-plan.md`, absorbed into this
document) ranked the analyzer/linter facts that gated the LSP residue.  Outcome:
**every F item is done** except the deliberately documented ones and the
readiness residue — F1 the real CFG and F2 the nullability continuation
refinement (session 15), F3 linter stages 11/11b (the firing set + anchors +
the emission order + the two content rows, sessions 16–18; the corpus-wide
residue it uncovered is the program's linter track), F4 stage 11c's
payload/destructure types (session 16), F5 function-type names (session 16,
`6ad423ce`), F6 the generic-context gate (session 15), F7 + F8.1 the
callable-value record and the scanner's two rules (session 16), F8.2
documentSymbol (session 17), F8.3 the `documentHighlight` survivor
(documented — `docs/lsp-design.md` §8), F9 readiness (`ScanFacts` release, the
reference index's owned texts, `note_document_tokens` caching — open; the
program's LSP track).  The per-item landed records are the session-15/16/17/18
entries below; the residue tables became the program's tracks.

Original design notes (superseded; kept for provenance only):

- **F1** (host): `core/control_flow/builder.rb` (nodes carrying
  `kind`/`statement`/`reads`/`writes`, successor edges with refinement labels,
  `build_block`/`build_statement` with `break_target:`/`continue_target:`,
  `add_null_test_refinements` at `:541`), `graph.rb`, `dataflow.rb`
  (`Dataflow.solve(direction:, initial:, join:, edge_transfer:, boundary_in:)`).
  `build_cfg_into` keeps its signature for the linter's callers.
- **F2** (host): `control_flow/nullability_flow.rb` (`NullabilityFlow.solve`,
  intersection join, `Result#nonnull_before(stmt)`),
  `semantic_analyzer/nullability.rb:69-90`
  (`apply_nullability_continuation_refinements!`), `flow_refinement.rb:289`.
  Verify with the `lower` track's item 14 files.
- **F4** (host): `Types::VariantArmPayload`, `statements.rb:800-850`; the
  destructure arm at `analyzer.mt:2944-2956`; **do not repeat the reverted
  bind-to-T model** (recorded in the session-5 close above).
- **F6** (host): `allow_prefer_let: var && !generic_function_context?` +
  `extending_block_generic?`.
- **F7** (host): `expressions.rb:356` → `record_callable_value_identifier_site`;
  `callable_of(identity)` is *not* recorded (the host answers `variable:0`).

**Session 15 close (2026-09-30)** — the foundational blockers began; three
commits, each with its own gate run: F6 `a689d176` (the generic-context gate for
`prefer-let` — the planned "editable receivers" diagnosis was wrong; `visit_decl`
now raises `generic_function_depth` for a function with type parameters and for
every method of a generic extending block), F1 `c030fe16` (the real
control-flow graph: `semantic/control_flow/graph.mt` = the host's `Graph` +
`NullabilityFlow`-shaped solver + per-body fall-through targets;
`builder.build_graph_into`'s whole-body binding-ID pass; binding ids 1-based so 0
can mean "not a binding of this body"; eight shape tests) and F2 `c295db50` (the
nullability continuation refinement — applied at the end of each statement for
the *next* one, the host's order; the bare-`null` side ported; the
terminating-branch rule; the `Analysis.flow_types` record the LSP scans in
*recording* order).  Audit **18 → 17 → 13** (the four
`memory_stress_test.mt` nullability hovers byte-equal, added 0).  Also measured:
`lower -q -j 16` 39/614/51/**2** — the 2 self-rejections are the *pre-existing*
`projects/stress` guarded-`Result` pair; prefer-let over `std/` self-only 121
(host 0), dominated by `ty_error` receivers (F4's work).

### The nullability continuation refinement (2026-09-30 session 15, F2)

The analyzer now carries the host's control-flow narrowing, and it closed the
four `memory_stress_test.mt` hover entries (`25:7`, `28:20`, `205:7`, `404:7`) —
the full matrix went **17 → 13** (closed 4, added 0; nothing else moved).  The
port has three parts:

1. **The pre-pass and the continuation.**  `check_function_body` builds the
   body's CFG and solves the non-null dataflow before checking any statement;
   after each statement the dataflow's non-null set for the **next** statement
   narrows the scope (`apply_flow_continuation`, the host's
   `apply_nullability_continuation_refinements!`).  This is *not* a
   prefix-of-statement application: the host refines at the end of statement N
   for statement N+1, which is also what makes the state it records at N's own
   position already carry the narrowing — that ordering is what answers a guard
   line with the refined type.
2. **The host's `null_test_refinements` polarity.**  The self only produced the
   *non-null* side of a null test; the host refines the other side to the bare
   `null` (`x == null` truthy, `x != null` falsy), which is exactly what
   `205:7`'s `var handle: null` prints.
3. **The if statement's continuation** (the host's IfStmt arm).  The self's
   `keep_unassigned`/`intersect_post_refs` post-refinement model is gone: each
   branch is checked with the previous branches' *falsy* refinements in scope,
   and an if with no else whose **every branch body terminates**
   (`graph_body_terminates`, CFG reachability — the host's
   `Termination.block_always_terminates?`) continues with the merged *falsy*
   refinements, the only way control can get past it.  (`flow_refinements`
   itself returns `{}` for the falsy side of `and`/the truthy side of `or`,
   exactly as the host's does; the `404:7` case is the *continuation*'s work.)

**The refinement record** (`Analysis.flow_types`).  The host answers a local
hover from its completion snapshots, and the entries showed how: the record
holds the entries whose type *changed* at a statement boundary, positioned at
the statement (`line * 1000000 + column`), plus a barrier entry (an empty name)
per function body so an earlier body's refinements cannot apply.  `navigation.mt`
resolves a hover through `flow_type_at`: the **last** entry at or before the
cursor in *recording* order (not the greatest position — a post-statement record
at an earlier line still answers a later cursor, the same carry-forward the
documentHighlight residue shows), with the last matching barrier resetting it;
the local and parameter hover arms then render that type instead of the
declaration's.

**Pre-existing divergence found while gating**: `projects/stress/src/engine/
guards.mt` (and its importer `main.mt`) report two false-positive
`sema/error` return-type mismatches in the self where the host reports none —
a guarded `let x = <Result> else as error:` binding the self keeps at
`Result[int, EngineError]` instead of narrowing to the success type.  It
predates this session (the stage3 binary built at F1's bootstrap shows it
identically); the `lower` sweep's `selffail` counter is therefore **2**, not the
0 recorded earlier.

Measured: the full SimpleGame matrix **17 → 13** (closed the four hover entries,
added 0 — and the class split is now hover 5, documentSymbol 4, diagnostic 2,
documentHighlight 1, semanticTokens 1).  Gates: bootstrap fixed point + 14/14,
`test/mt` 60/0, `cli:parity` 23/38/0, sexpr lex 706/706 + parse 702/0 + `lower -q
-j 16` 39/614/51/2 (the pre-existing pair above), the harness 30/30 + the 4
documented entries, the recovery probe OK, every probe fixture unchanged
(closed 0, added 0 across `probe-ws`, `probe2`, `probe4`–`probe6`, `fieldprobe`,
`thisprobe`, `defprobe`, `crash1`, `hover-probe2`–`hover-probe5`, `eventprobe`),
valgrind 0 errors over an LSP drive, the headless-Neovim smoke, and the lint
scoreboard unchanged.  The semantic-token residue is now precisely five
positions in `docs/language_baseline.mt`: `identity` 275:40 and `add` 1099:41
(host `variable`, self `function` — F7's callable-value record), `check`
1127:9 and `invoke` 1160:13 (host `property`, self `method`), and `Edge`
1962:29 (host `type`, self `enumMember`).

### The real control-flow graph (2026-09-30 session 15, F1)

`projects/mtc/src/mtc/semantic/control_flow/graph.mt` is the host's
`ControlFlow::Graph` ported: `CfgNode`s carrying their kind, the statement they
were built from (as an address — the self's `object_id`), and their binding
read/write sites; successor edges with the host's `true_branch`/`false_branch`
labels and its `set_edge_refinement` null-test maps; per-body fall-through
targets (so `Termination`-shaped reachability answers "does this body always
terminate?") and the forward dataflow solver `NullabilityFlow` runs over them —
the host's `Dataflow.solve` shape: forward, **intersection join**, an edge
transfer that subtracts the node's writes then applies the taken edge's
refinements, and an empty entry state.

`builder.mt` grew `build_graph_into` with the whole-body binding-ID pass the
graph needs (`for` bindings, match-arm `as` bindings, destructured names, a
guarded decl's else binding) and the full `ControlFlow::Builder` statement walk
(backwards, threading each statement's continuation, break/continue targets,
`:fatal` for a literal-false `assert`/`expect`, transparent `unsafe:` blocks).
The linter's `build_cfg_into` keeps its narrower pre-scan, so its binding-ID map
is unchanged; binding ids are now **1-based** (0 = "not a binding of this
body"), the self's analogue of the host's nil — a 0-based first parameter used
to collide with that sentinel and drop its access records.

Eight unit tests in `projects/mtc/test/semantic_test.mt` pin the shapes: a
terminating guard's non-null continuation, the false edge of a merging if, the
write that clears a narrowing, the loop back edge, `for` bindings and iterable
reads, match-arm bindings, `unsafe`/`defer` nesting, and the break/continue
targets.  Gates: bootstrap fixed point + 14/14 (the new tests included),
`test/mt` 60/0, `cli:parity` 23/38/0, sexpr lex 705/705 + parse 701/0, the
lint scoreboard unchanged.

### Linter stage 11d (2026-09-30 session 15): the generic-context gate for `prefer-let`

`prefer-let` no longer fires on a `var` bound in a generic context.  The host's
rule is `allow_prefer_let: var && !generic_function_context?`, where a function
body is generic when the function declares type parameters *or* its enclosing
`extending` block's receiver carries type arguments (`extending Vec[T]:` —
the host's `extending_block_generic?`).  The self's scope pass already had the
counter (`generic_function_depth`) and the gate, but never incremented the
counter, so every `var` in a generic method was reported: `std/vec.mt` now
matches the host exactly (0 warnings, was 2), and the probe shape
(`generic_plain[T]`, `extending Box[T]`, a non-generic extending method, an
editable receiver) reproduces the host's 5-warning set.

The rest of the prefer-let sweep is *not* this rule: over `std/` the self still
reports 121 warnings the host does not, and they are dominated by bindings
whose types the analyzer records as `ty_error` (a match-arm payload field, a
destructured name) — the editable-receiver record then never fires, because the
method kind cannot be resolved on an `<error>` receiver.  Stage 11c (F4) is
what unblocks those.

Measured: the full SimpleGame matrix **18 → 17 differing entries** (closed
`docs/data_structures.mt`'s documentSymbol — the host wrapped that file in this
run; added 0; the diagnostic class is unchanged at 2).  Gates: bootstrap fixed
point + 14/14, `test/mt` 60/0, `cli:parity` 23/38/0, sexpr lex 705/705 + parse
701/0, the harness 30/30 + the 4 documented entries, the recovery probe OK, the
lint scoreboard unchanged.

### Linter `line-too-long` parity (2026-09-27 session 4, stage 8b)

The rule now mirrors the host (`linter/source_helpers.rb`): only **wrappable**
over-long lines are reported (the host gates on
`Formatter.wrappable_long_line_candidate_text?`), the warning carries the host's
`column = max + 1` / `length = line.length - max`, the message gains the
`; wrap the expression` suffix when the formatter can build a fix, and the
external/foreign-function header predicate is the host's regex (word prefixes
included, so `public foreign function …` is skipped).

- `formatter/tidy.mt` exposes `WrapFix`, `wrappable_long_line_candidate_text`
  and `build_long_line_wrap_fix(source, line_index, max, path, validate)` (plus
  a token-carrying variant the linter uses) over the existing wrap machinery;
  `validate: false` mirrors the host's linter call, the LSP quickfix uses
  `validate: true`.
- The LSP offers the host's `Wrap long line` quickfix from a `line-too-long`
  diagnostic (`code_actions.rb:118-142`), with the config-resolved limit.
- `--fix` still excludes the rule, matching the host's `AUTO_FIXABLE_RULE_CODES`.

Verified: `mtc lint`'s `line-too-long` lines are byte-identical to the host's on
`projects/mtc/src/mtc/lsp/navigation.mt` (three warnings, one non-wrappable
without the suffix); three new linter tests; `cli:parity` 22/39/0 and the LSP
harness's 4 entries unchanged.

### Lint options plumbing (2026-09-27 session 4, stage 8a)

The linter's entry points became one options funnel (`linter.LintOptions`),
mirroring the host's `Linter.lint_source` (`linter.rb:209-260`): the CLI
(`check`/`lint`), the LSP diagnostics path and the fix engine all pass the same
struct — owning types, unresolved imports, the analyzer's editable receivers,
the analysis pointer itself (for the type-backed rules that follow), the
line-length limit and explicit select/ignore lists.

- **`.mt-lint.yml` is honored on every path now**, not just `mtc lint`: the
  config supplies the line-length limit and the select/ignore lists when the
  caller passes none (explicit CLI flags still win, as the host's
  `select ||= cfg[:select]` does), and `mtc lint` no longer merges the config
  itself.  This also closes the documented divergence where the LSP path ignored
  the config (and therefore ran `dead-assignment` ungated).
- **`# lint: ignore` / `# lint: ignore(a, b)` suppressions** are ported
  (`linter.rb:703-736`): comments come from a single `lex_with_trivia` pass whose
  tokens are shared with the trailing-comma rule; a suppression drops warnings on
  its own line or the following one.
- **`mtc check` runs the full lint** (owning types, unresolved imports, the root
  analysis' editable receivers, the config), matching the host's `check`.
- `lint_source_opts` / `lint_source_unresolved` are gone; `lint_source_with`
  takes the options struct, and `fix_engine.fix_source(source, path, options)`
  resolves the enabled rule set from the same lists.

Counters: `projects/mtc` self-tests 14 files / 0 failed (6 new linter tests:
suppression same-line / preceding-line / all / other-code and select/ignore
filtering); `test/mt` 60 files / 0 failed; `rake "cli:parity"` unchanged at
22 match / 39 differ / 0 pending; LSP harness unchanged at 4 differing entries
(the two documented host artifacts, parser recovery and debugInfo).

### Measured (same corpus, both servers)

The table below is the **2026-09-25/26 session's** before/after record — its
"After" column is historical.  The stage re-measurements that follow it are the
live counters.

| Gate | Before | After |
| --- | --- | --- |
| `initialize` capabilities | 5 of 30 keys differ | **0 differ** |
| requests differing | 33 of 47 | **15 of 47** |
| stress probes differing | 15 of 15 | **6 of 15** (`ae12a5be` closed the method-not-found message) |
| requests timing out | 1 (`milkTea/documentContext`) | **0** |
| crashes / hangs | — | **none** (all 62 probes complete; no SIGSEGV/SIGABRT) |
| byte-identical endpoints | — | hover (all 8), `inlayHint`, `definition/compute`, `definition/local`, `declaration/struct`, `typeDefinition/circle`, `references/compute`, `signatureHelp`, `prepareRename`, `documentLink`, `stress/open-close+hover`, `stress/rapid-didChange+hover` |
| **differing entries, total** | — | **23** (2 semantic-token entries + 15 requests + 6 probes) |

**Re-measured 2026-09-26 (fresh stage2, both servers recorded with `--stress`)**:
capabilities 30/30 keys identical; 15/47 requests and 6/15 probes differ; 0 timeouts;
0 crashes.  Closed this session: the keyword/builtin hover docs tables and hover
token ranges (5 entries), `signatureHelp`, `prepareRename`, `documentLink`'s
tooltip, inferred local types in hover + inline hints (3), `definition/local`'s
range and the aggregate-literal label hover `hover/field`.

**Re-measured 2026-09-26 (stage 3 — documentSymbol closed)**: capabilities 30/30
keys identical; **5/47 requests, 2/15 probes and 2 semantic-token comparisons
differ (9 entries)**; 0 timeouts; 0 crashes.  Stage 3 rewrote `lsp/symbols.mt`
against the host's tree: declaration symbols in source order with the host's kinds,
name-token `range`/`selectionRange`, `detail` text (`-> ret` with
`const`/`async`/`mut`/`static` prefixes, `(impls)`, `: backing`, `[generics]`,
`= target`, `event[cap](payload)`, `implementation` for `extending` blocks),
field/enum-member/variant-arm children on the host's line spans (arms report on the
variant's line) and function locals as kind-13 name-span children (`_` skipped).

**Re-measured 2026-09-26 (stage 2 — completion closed)**: capabilities 30/30 keys
identical; **7/47 requests, 3/15 probes and 2 semantic-token comparisons differ
(12 entries)**; 0 timeouts; 0 crashes.  Stage 2 rewrote `lsp/completion.mt` against
the host's shapes: the import/module, type-receiver, value-receiver (fields then
methods) and method-fallback branches of the dot-receiver chain (a dot receiver is
never answered with the keyword list), the global bucket list (functions, imported
and local types, resolved imports, values, locals, type constructors, keywords —
each with the host's kinds, `sortText` keys, `data` payloads, snippets and
`labelDetails`) and the host's keyword/type-constructor tables.  The receiver's
type is resolved from the enclosing function's locals (`type_render.initializer_type`)
and declared annotations.

**Re-measured 2026-09-26 (stage 1 — seven isolated entries closed)**: capabilities
30/30 keys identical; **10/47 requests, 4/15 probes and 2 semantic-token
comparisons differ (16 entries)**; 0 timeouts; 0 crashes.  The stage-1 root causes:

1. **`selectionRange`** — `utils.split_lines` now mirrors Ruby's `split("\n", -1)`
   (a trailing newline keeps a final empty line) and `enclosing_block_range` stops
   at the first body line instead of including the function header; the outer block
   is `{36,0}-{47,0}` like the host.
2. **`codeLens`** — interface methods are lensed, `data` is the host's
   `{uri,name,line,column}` object, and `codeLens/resolve` answers the lens with
   its command attached instead of a bare command object.
3. **`prepareCallHierarchy`** — the item carries the *declaration* range and
   selectionRange plus `data {name,uri,receiver_type}` (functions and
   extending-block methods) instead of the call-site range.
4. **`references/sum`** — the same-file scan was passed the URI where
   `document_source` expects a path, so it always missed; names that resolve to a
   non-top-level binding now go through `lsp/scope.mt` (`Binding` records
   `is_toplevel`, `local_binding_line` finds the innermost local).
5. **`workspace/symbol`** — results are scoped to the client root (the index also
   walks the `std/` ancestor), index entries carry the name-token column, and the
   kind mapping follows the host (`variant`/`opaque` -> 23, extending methods -> 12).
6. **`stress/wrong-param-type`** — `extract_position_params` reports whether the
   request carried a usable position object; hover answers `null` when it did not
   (the host raises and rescues to null).
7. **`stress/unterminated-source+tokens`** — `scan_string_segment` is bounded by
   the line (`line_stop` was passed but ignored), so an unterminated literal ends
   the token at end-of-line and reports the real line/column instead of `(0,0)`.

### Crash / memory-safety verification

- **Stress corpus** (15 adversarial probes: rapid and full-document edits,
  out-of-range and negative positions, unknown methods, missing/ill-typed
  params, unknown documents, unterminated source, emoji positions, open/close
  cycling): **no crash, no hang, no timeout** — every probe answered, and the
  server kept serving afterwards.
- **valgrind** (`--leak-check=full`, driving initialize → didOpen → hover,
  definition, references, documentSymbol, semanticTokens, completion, pull
  diagnostics, codeLens, foldingRange, inlayHint → shutdown/exit):
  **0 invalid reads/writes, 0 uninitialised-value uses, 0 invalid frees**.
  All 1329 valgrind "errors" are leak records.  The leaks are real but
  structural: arena-style buffers the codebase never frees, dominated by the
  workspace index (`workspace_index_collect_directory` → `parse_source` per
  file), which in this run also walked the *repository* root because
  `discover_project_root` appends the nearest `std/` ancestor to the module
  roots.  Worth a follow-up (an editor session is long-lived), but it is not a
  correctness bug and not new.

### Project audit — SimpleGame, every file (2026-09-27 session 3)

`tools/lsp_project_audit.rb` (new) drives both servers **live** against an
existing project: every `.mt` file is opened, the file-level endpoints (outline,
folding, lenses, hints, links, tokens, pull diagnostics) run once per file, and
the position endpoints (hover, definition, declaration, typeDefinition,
implementation, references, documentHighlight) run at every identifier position
(evenly sampled above `--cap`).  Per file it warms the facts first (the host
recomputes them lazily, the self answers settled immediately), records each
response, and diffs per method; a malformed frame or a dead server restarts that
side and retries, so one bad frame cannot hide the rest.

Run against `~/Projects/MilkTea/SimpleGame` (7 files, 3 104 lines) it found one
protocol bug and six behavioural gaps, all fixed in this session:

1. **Malformed `references` JSON** (the stream-desynchronizing bug): the element
   separator followed the *occurrence index*, so a skipped out-of-scope
   occurrence emitted a leading comma (`[,{…}]`) — a frame a real client
   rejects.  The separator now follows what was emitted.
2. **`documentHighlight` was not scope-aware**: it lit every same-named
   occurrence in the file, including another function's local (`v` in two
   demos).  It now uses the same scope rule as `references`.
3. **Hover source labels** printed the *basename*; the host prints the path
   relative to the workspace root, absolute when the file is outside it (a
   `std/` declaration in a user project).  `hover_path_label` mirrors
   `hover_source_label`.
4. **Import paths**: hover/definition/declaration/typeDefinition on a module
   path segment or an import alias (`import std.str`, `import std.vec as vec`)
   answered null — or the *builtin type* docs for `str` — and now resolve to the
   module file exactly as the host's `import_path_info_at` +
   `module_definition_location` do.
5. **Locals and parameters**: `resolve_local_hover` returned the first same-named
   local in *any* earlier function (`s.contains(1)` in one demo answered another
   demo's `s`).  It now resolves through the scope bindings
   (`local_binding_line`) to the innermost enclosing binding and its declaration
   node — nested blocks included — and a parameter answers the host's
   `parameter <name>: <type> (immutable)`.  `typeDefinition` on a local answers
   its own declaration and on a callable its declaration, as the host does.
6. **Builtin type hovers**: the host's `BUILTIN_TYPE_DOCS` (46 entries,
   `type int` + docs) is ported verbatim into `lsp/hover_docs.mt`;
   `int`/`str`/`ptr`/… answered null before.
7. **Linter severities**: four rules were hints where the host (and its LSP
   mapping) emits warnings — `unused-import`, `constant-condition`,
   `redundant-else`, `loop-single-iteration`.

Verified with `tools/lsp_project_audit.rb`: the isolated fixture (locals,
parameters, types, references) is at **1 differing entry of 19**, and that one is
a deliberate extension (the host answers `workspace/symbol` for an empty query
with *every* symbol including locals; the self requires a non-empty query).
A targeted probe on the audited file (`docs/data_structures.mt`: import path
segments and the alias, a method receiver in a *sibling* function, a local's
highlight scope, `_first`, a comment position, a builtin type name) matches the
host at **11 of 12 positions**; the remaining one is the host's own lazy-facts
artifact — on a partially warmed server it resolves `s.contains(1)` to another
function's `s`, where both the settled host and the self answer the innermost
binding.  `tools/bootstrap.sh -j 16` stays green (fixed point + 14 files / 516
tests).

Remaining differences on the real project, all documented and none a crash:

- **Host facts lag** (the existing row): the host's *first* answer after
  `didOpen` classifies `vec.Vec[int]`/`create` with its fallback
  (`variable`/`property`/`enumMember`) and drops the `defaultLibrary` modifier on
  `int`; a warm re-request matches the self-host, which answers the settled
  classes immediately.
- **`static_type_method_references` is still unported** (the stage-5b note):
  references on a *declared type* name answer the host's method references there
  and the name's occurrences here.  Builtin type names (`int`, `str`) now answer
  `[]` exactly like the host.
- **`dead-assignment`** remains a self-host-only rule (extra hints), the item-6
  policy decision.
- **Parameter references** resolve here and answer `[]` on the host — a
  deliberate "at least as good" extension, as is the empty-query
  `workspace/symbol` rule above.
- **`documentSymbol` for a file outside the package source root** (`docs/` in
  this project) nests under a module symbol in the host; the self returns the
  flat symbol list.

### Remaining LSP gaps (all reproducible with the harness)

Re-measured 2026-09-26 after stage 6e (55 requests, 19 probes): **4 differing
entries** — 1 of 55 requests, 3 of 19 probes, 0 semantic-token comparisons — plus
one gap the corpus does not cover yet (row 2).  Re-measured 2026-09-28 session 9:
still the same 4 entries, with row 3 narrower (the self no longer adds sema/lint
items the host does not produce).

| # | Family | Entries | Evidence / target |
| --- | --- | --- | --- |
| 1 | **`milkTea/debugInfo`** | `milkTea/debugInfo` | **Partially ported (stage 6f).** The host's Header, Tokens and Parse Errors sections are implemented: the header, the token histogram and **245 of 246 token rows are byte-identical** on the corpus file (lexeme, kind, location and semantic class columns).  Two known gaps remain, both measured: (a) the histogram's *tie order* — the host's `group_by` + Ruby `sort_by` leaves equal counts in an order only MRI's qsort reproduces (e.g. `2 star, 2 float, …` where first-appearance order gives `2 import, 2 as, …`); the self order is stable and documented rather than emulated.  (b) the host's **AST** (Ruby class names plus `node_ids: {N entries}`), **Facts** (`40 types, 2 functions, 2 method_sets, 1 interfaces, 2 imports`, method sets, owning types) and **Bindings** (`ValueBinding[id: N]`, `obj <object_id> → binding_id: N`) sections are not implemented: they render the host implementation's own data structures, so matching them byte-for-byte needs a Ruby-AST-shaped renderer, a binding-id model and harness normalization for the object ids.  The self adds a `Workspace` section the host has no equivalent for. |
| 2 | **Malformed frame: the host hangs** | `stress/malformed-frame+parseError` | a JSON-RPC frame whose body is not JSON (or carries a bogus `Content-Length`) leaves the Ruby host blocked — it never answers that frame (the probe times out) and only resumes on the next one.  The self answers `-32700` with a null id and keeps serving.  This entry differs by design and is a self-host improvement; it also locks the crash it used to cause (a malformed frame used to be treated as EOF and shut the server down) |
| 3 | **Parser recovery on broken input** | `stress/unterminated-source+diagnostic` | the host's recovering parser reports 5 items for the probe buffer (2 `lex/error`, 3 `parse/error`); the self reports **3** (re-measured session 9 — the panic-based unwinding removed the extra sema/lint items, so only parser recovery is left).  Two gaps: (a) the self's second `lex/error` (`unclosed grouping delimiter`) carries no position (`0:0`) where the host reports the opening delimiter's (`0:15`); (b) the parse errors — the host continues past the bad parameter name and adds `expected ')' after parameters` and a top-level `expected declaration`, while the self stops at `expected parameter name`.  Matching needs the host's parser behaviour, not an LSP change: `consume_name` clearing a keyword-name error to `keyword 'X' cannot be used as <role>` (`parser.rb:230-242`), `parse_param` recording that error *and continuing* so `consume(:rparen, "expected ')' after parameters")` fires at the previous token (`types.rb:18-36`), one error per function with a skeleton AST (`declarations.rb:647-658`, the self now keeps the name but not the continued parameter parse), and a top-level `expected declaration` that ends the parse (`declarations.rb:115`) |
| 4 | **Host facts lag** | `stress/unicode+semanticTokens` | 2 modifier bits: the host omits `readonly` on two `let`-local references when tokens are requested right after a content change — its facts for the new content are not recomputed yet.  Verified: the same document served 2 s after `didOpen` gets `readonly` (and a freshly-opened document does too), so this is a host timing artifact, not a classification rule; the self computes facts synchronously |

### Where the next session starts

Read this order: this §0k → `docs/lsp-design.md` (LSP architecture) →
`docs/dap-design.md` §10 (DAP gaps) → the gates below.  Rebuild before measuring
— every harness silently uses a stale `build/stage2/mtc`.  The LSP iteration loop
is a `tmp/mtc-dev` build plus the *focused* meter for the class being worked; the
sweeps below run once per commit, on frozen sources (`tools/gates.sh --run` runs
the right subset):

```sh
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev   # iterate
tmp/mtc-dev test projects/mtc -I . --timeout 120                       # iterate
ruby tools/lsp_project_audit.rb --workspace ~/Projects/MilkTea/SimpleGame --only <method>
tools/gates.sh --run                                                   # per commit
```

**Closed since the stage list below was written** (details in the stage records
above): cross-file references scoped to import dependents; generic function-call
inference (the reported outline file is now byte-identical); the outline
rendering rules (type parameters as children, no `static`/`mut` on methods,
field types from the analysis, unresolved types rendering no detail); the
linter fixes (`unused-import` initializer, `owning-release-leak` line+type, no
false leak on `X.create(...)` for non-owning types); module-member completion
(foreign functions, import aliases); definition/hover/typeDefinition on module
members; diagnostics published on every change (the stale-error report);
per-request `[LSP perf]` logging with the level forwarded from the extension;
`milkTea/debugInfo`'s header/token-table/parse-errors sections (245 of 246 token
rows byte-identical); and the DAP items in `dap-design.md` §10.

**Remaining, highest value first:**

1. **Edit latency: cache loader analyses per module** (`module_loader.mt`).
   Every content version re-parses and re-analyzes the whole import closure
   (measured: 38 ms per edit on `SimpleGame/src/main.mt` with `std.raylib`,
   against the host's 15–25 ms per request).  Design: a `ModuleCache` (owned by
   the LSP `Workspace`, passed to `check_program_with_source`) keyed by
   `(path, content hash)`, each entry recording the *versions* of the module's
   direct imports; a module is re-analyzed when its own hash changes or any
   direct import's version moved (the version bump cascades, so dependents of
   dependents invalidate too, like the host's facts cache).  Entries own their
   source text (the AST views it) — the same ownership rule as
   `Workspace.parsed_analysis_for`.  Verify: `[LSP perf]` lines drop below
   ~10 ms per edit, and the LSP harness plus a dependency-edit probe (edit
   `std/vec.mt`, expect the dependent's diagnostics to refresh) stay green.
2. **`milkTea/debugInfo` remainder** (1 of 55 requests; the acceptance re-scope
   in the "Stage 8" record below still applies): the AST, Facts and Bindings
   sections and the histogram's tie order.  The token table, header and parse
   errors are done and byte-identical.
3. **Parser recovery parity** (row 3, narrowed by session 9): our lexer/parser
   recover (outline, tokens and sema keep working, and lex/parse errors are
   reported), and the panic-based unwinding now removes the extra sema/lint items
   — the probe buffer is down to 3 items against the host's 5.  Two behaviours
   remain: the lexer's `unclosed grouping delimiter` position, and `parse_param`
   continuing past a bad parameter name (so `expected ')'` and a top-level
   `expected declaration` follow).  This also changes `mtc check` text, so it
   belongs with the CLI-parity work (§0j).
4. **DAP** (`docs/dap-design.md` §10): (a) `launch` on a `.mt` source must build
   it (spawn `mtc build <program> -o <tmp>`), (b) the lldb-dap bridge — now
   feasible: `std/libuv.mt` exposes `uv_poll_*` and `std/async` a libuv runtime,
   so one event loop can watch stdin and the adapter; the host's
   `lldb_dap_backend.rb` is the 152-line reference and the extension's default
   backend is `lldb-dap`, (c) emit `<output>.mtdbg.json` from `mtc build` (the
   map only has to match *our* symbol names), (d) pause diagnostics + `modules`.
5. **Feature-audit leftovers** (measured 2026-09-27 with the audit table in this
   section's commits; all small): `callHierarchy prepare` returns null where the
   host resolves the callee; `linkedEditingRange` returns a result where the
   host returns null; `typeDefinition` on a *function* returns null where the
   host jumps to its declaration; `inlayHint` emits more argument-name hints
   than the host (mostly correct — `rl.init_window(width, …)` — with one
   mislabelled `text:` where the method's parameter is `name:`, i.e. the callee
   resolved to the wrong `create`); `executeCommand` answers MethodNotFound
   where the host answers null (deliberate: the spec allows it, and we advertise
   only `mtc.restartServer`).
6. **`dead-assignment` policy** — **CLOSED (session 9)**: the rule now matches the
   host (`linter/cfg.mt` skips declaration-origin writes and never-read bindings,
   and the warning carries the host's message and `warning` severity); the one
   structural difference left is that the liveness walk keys on *names* where the
   host keys on binding ids, which can only show in shadowed-name cases.
7. **Compiler-side work** is §0j (`lower` dump parity 39/613, CLI message parity,
   `deps`/`--bundle`/`--jobs`/Wasm); the example and `test/mt` build failures it
   used to list are fixed (2026-09-27).
   Note for that work: `f"{{"` is **not** an escape in Milk Tea — both compilers
   emit two literal braces (the DAP's `exited` body relied on Ruby habits and
   broke clients; fixed 2026-09-27).

**Stage records that follow are historical** (their "counters" and line numbers
describe the tree at the time); the live counters are the header block, §0k's
table and `dap-design.md` §10.

### Stage notes (historical)

**Stage 7 — cross-file reference scoping** (CLOSED 2026-09-26): the index records
each file's resolved imports and `references` walks the declaration's import
dependents (`reverse_import_dependents_for` in the host).

**Stage 8 — `milkTea/debugInfo`** (partially ported 2026-09-26; the remainder is
item 2 above).  The re-scope reasoning is unchanged: the host text embeds Ruby
`object_id`s, binding ids in host allocation order, `ValueBinding[id: N]` reprs,
Ruby AST class names and `node_ids: {N entries}`, so literal byte-parity needs
(a) a harness normalizer for object ids, (b) a binding-id model in
`semantic/analyzer.mt` and (c) a Ruby-AST-shaped renderer.  What landed: the
`{text}` envelope, the header, the full token table (lexeme, kind, location and
semantic class from the same scanner the tokens endpoints use) and the parse
errors.

**Not stages of their own:**
- `stress/unterminated-source+diagnostic` (parser recovery) is item 3.
- `stress/unicode+semanticTokens` (host facts lag) is not actionable on our side.
- Canonical-mode comment reattachment is formatter completeness (§7), not an LSP
  entry: the LSP's configured default is `tidy`.

Each phase is done only when its harness entries are byte-equal **and** the global
counters move; the docs in this file, `lsp-design.md` and `dap-design.md` are
synced in the same commit as the change.  Re-run the §5.9 gate list (bootstrap
fixed point + self-tests, `test/mt`, `cli:parity`, both harnesses, valgrind on
the new paths, and the headless-Neovim smoke test for behavior changes).

### How to re-run

```sh
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o build/stage2/mtc
ruby tools/lsp_parity.rb record --server host --out tmp/lsp-host.json --stress
ruby tools/lsp_parity.rb record --server self --out tmp/lsp-self.json --stress
ruby tools/lsp_parity.rb compare tmp/lsp-host.json tmp/lsp-self.json
```

### How to re-run (formatter modes)

```sh
ruby tools/format_parity.rb all -j 16        # preserve / tidy must be 702/702
ruby tools/format_parity.rb tidy examples/raylib   # a subset when iterating
```

---

## 0j. 2026-09-25 session — stress parity, parse parity, measured status sweep

Goal: build `projects/stress` with the self-host compiler, then take a measured
inventory of the remaining self-host gaps instead of the estimates in §0i.

### Delivered

1. **`projects/stress` builds and runs at parity** — five root causes fixed
   (task-root proc bridge, proc bodies inside async functions, builtin vector
   constructors, format-string locals, `inline for` reflection).  Details and
   verification are in "The `projects/stress` build — absorbed record" below.
2. **`parse --sexpr` reached zero differences**: `:destructure_type_name`
   rendered the joined `"types.Transform"` where the host's AST holds the part
   list (`("types" "Transform")`); the dumper now splits the stored name like
   the host.
3. **Project-root discovery no longer depends on `-I`** (`main.mt`): Ruby's
   `ModuleRoots.roots_for_path` always appends the discovered project root and
   its own root, so a source under a `std/` ancestor resolves `std.*` even when
   explicit `-I` roots are given.  The walk-up also absolutizes first, so a
   *relative* operand (`mtc build standalone/x.mt` from a fixture directory)
   finds the root as `File.expand_path` would.
4. **Four test files that never ran** (`binary_test`, `blackboard_test`,
   `input_test`, `pool_test`) had match arms with empty bodies; both compilers
   reject them and `mtc test` silently skips unparseable files, so the suite
   reported 56 of 60 files.  Each empty arm now has a `pass` body.
5. **Union members are modelled by the analyzer.**  `ctx.unions` (and the
   binder's `unions`/`private_unions` export surface) now carry union field
   types, and both member-check paths consult them.  Previously a union was
   exported as opaque, so every `ev.type`-style read on an imported union
   reported `unknown field SDL_Event.type` — the false positive that blocked all
   34 `examples/sdl3` files (a sample file now `check`s clean).
6. **Type aliases resolve in a second pass.**  `declare_named_types` resolved an
   alias target eagerly while still walking the file, so an alias over a type
   declared *later* (`type b3CreateDebugShapeCallback = fn(arg0:
   const_ptr[b3DebugShape], ...)`) reported `unknown type b3DebugShape` — 14 of
   the `examples/box3d` failures.  All names are registered first, then aliases
   resolve.
7. **`extending <alias>.<Type>:` attaches to the resolved type.**  `extending
   b3.Vec3:` (with `type Vec3 = c.b3Vec3` in std.box3d) declares methods on the C
   struct `b3Vec3`, which is the name a receiver resolves to at a call site.  The
   analyzer now registers method keys and signatures under both the literal name
   and the canonical one (`canonical_extending_base` follows the import alias and
   the type-alias chain), the binder exports the canonical keys so *importing*
   modules resolve them, the imported-member path consults the current module's
   keys and any visible binding's canonical key, and the lowering emits the
   definitions under the canonical name with the resolved receiver type.
   Previously `examples/box3d/common.mt` and `examples/box2d/common.mt` reported
   a dozen `unknown method b3Vec3.scale` / `b2Vec2.add` false positives each, and
   the definitions that were emitted never matched the calls.
8. **Union members and forward aliases aside, the box3d *build* recipe was
   missing entirely**: `collect_binding_flags` / `prepare_vendored_libraries` /
   `collect_vendored_link_flags` had no `box3d` entry, so the C compile failed on
   `#include "box3d/box3d.h"`.  It now mirrors the box2d recipe (include path,
   CMake static build into `tmp/vendored-box3d-prefix`, `-L…/lib -lbox3d -lm`).
9. **Raw-module enum members in `match` arms.**  An arm like
   `b3.BodyType.b3_staticBody` was emitted as the scoped constant
   `std_c_box3d_b3BodyType_b3_staticBody`, which a raw module never defines; the
   host uses the C header's bare enumerator (`b3_staticBody`) — mirroring its
   `imported_value_c_name` raw-module rule.  Match-arm lowering now does the
   same (`enum_member_reference_c_name`).

State of the vendored families after 5–9: `examples/sdl3` files `check` clean;
`examples/box3d` (`ragdoll`) `check`s clean; `examples/box2d` was down to 1–3
analyzer errors per file, all cleared by 10–13 below.

10. **`in` foreign parameters pass an address.**  `foreign function create_world(in
   world_def: WorldDef) = c.b3CreateWorld` takes a `const WorldDef*`; the
   argument lowering only handled `out`/`inout` (and `in` only when a boundary
   type was declared), so the value was passed where a pointer was expected.
   A plain `in` parameter now takes the argument's address unless it is already
   pointer-like (hoisting rvalues into a temp, as `materialize_foreign_address_arg`
   already did).
11. **Struct equality for raw-binding structs.**  `s_drag_body != b3.b3_nullBodyId`
   on a `b3BodyId` emitted a raw `!=` — invalid C — because the backend builds
   `mt_struct_eq_<T>` helpers from `Program.structs` and raw modules never lower
   their declarations there (the host falls back to the `Types::Struct` object).
   The lowering now synthesizes the field-wise helper from the analyzer's field
   list (`is_equality_struct_type` / `ensure_equality_helper_for_struct`,
   `:str` via `mt_str_equal`, nested raw structs recursing) and rewrites the
   comparison; unsupported field types leave the comparison untouched rather than
   emitting invalid C.
12. **Constants in type-argument position.**  A `const` used as an array size
   reported `unknown type`: struct fields resolve before `const_values` is
   filled, and `ModuleBinding` did not export constants.  Values/functions are
   now declared *before* struct fields resolve, and the binder exports
   `const_values` so a module-qualified constant (`human.BONE_COUNT`) folds
   through its import alias.  This was the last analyzer blocker for
   `examples/box2d` (15 files).
13. **Match exhaustiveness is module-aware.**  `match error:` on `pack.Error`
   reported the *local* `Error` enum's members as missing when the two share a
   bare name; the check now reads the case table from the scrutinee type's
   declaring module (`match_case_names_for`).

14. **Contextual literal typing** (the last hard rejection and the largest dump
   difference): an integer literal now takes the *contextual* type in every place
   the host gives it one — aggregate-literal fields resolved through a type alias
   (`rl.Color(r = 200)` with `type Color = c.Color`), constant initializers
   (folded `LIGHTGLOW`-style struct constants keep `ubyte` fields instead of
   `int`), and numeric-literal-valued `if`/`match` branches assigned to a
   narrower numeric type (`let shade: ubyte = if c: 0xFF else: 0x00`, which used
   to be a false "cannot assign int to ubyte").  Concretely: the per-field lookup
   follows the alias chain, the const-folding literal builder re-types against
   the field, and `types_compatible` accepts a literal-valued branch chain.

With 10–14 the vendored families build and run at parity.  Verified by running
both compilers' binaries and diffing: `box2d/drop` (exit 0, 49 lines),
`box2d/explosion` (0, 49), `box3d/ragdoll` (0, 52), `box3d/box_stack` (0, 52) —
stdout byte-identical in every case.  (`box2d/pyramid` and `box3d/pyramid` fail
under *both* compilers.)  Note for parallel sweeps: two concurrent builds of the
same project race on the vendored archives (`tmp/vendored-*/lib*.a` reports
"file truncated"), in either compiler — run vendored-family builds serially.

`examples/box2d` (30 files) and `examples/box3d` (14) failed on
`extending <alias>.<Type>:` methods: `collect_extending_methods` keyed methods by
the *literal* qualified name (`method_key("b2.Vec2", "length")`) while a call site
resolved the receiver through the alias chain to the canonical type
(`b2Vec2`, looked up in the *source* module's binding).  Item 7 fixed the
registration, the export surface and the lookup; the families now get past the
analyzer (`box3d/ragdoll.mt` `check`s clean, `box2d/*` is down to the const
issues in "Newly exposed gaps").

**Session commits (2026-09-25).**  `c796a227` (the CLI parity harness + the
lower-diff attribution tool), `697e9e53` (the host's CLI dispatch, help text and
version output), `e2f91867`/`aff18af6` (the revert and reapply of sending
diagnostics and the check summary to stderr), `117e7bc6` (diagnostics on the
host's one-line header), `a543165e` (`unsafe:` and bare block bodies get their
own defer scope), `ade972cc` (guard bindings read through their projection).

### Same session, second pass — linkage naming and foreign return types

15. **Raw-module method linkage naming** (ranked item 1, the dominant first
    difference in the raylib/box2d/box3d families): the host names a method from
    the receiver's *own* resolved type — `c_type_name(receiver_type)` in
    `function_binding_c_name` — and that name is **bare** whenever the receiver
    lives in a raw (`std.c.*`) module.  The self-host always prefixed with the
    module that *declares* the `extending` block, so `extending Color:` in
    std.raylib produced `std_raylib_Color_is_equal` (host: `Color_is_equal`) and
    `extending b3.Vec3:` in examples.box3d.common produced
    `examples_box3d_common_b3Vec3_scale` (host: `b3Vec3_scale`).  Three pieces
    (all in `lowering.mt`):
    - `extending_receiver_target` resolves an `extending` target the way the host
      does — a single-part target through the declaring module's own alias chain
      (`type Color = c.Color`), a qualified target through its import alias and
      that module's chain — and `lower_extending_block` now takes the receiver
      type (and the `this` parameter's type) from it.  `resolve_single_imported_type`
      was split so the ordering pass resolves identically without a `LowerCtx`
      (`resolve_imported_alias_type`).
    - `receiver_c_type_name` / `method_c_name_for_receiver` mirror `c_type_name`:
      bare for `std.c.*` receivers, module-qualified otherwise, with a
      `_static` suffix for static methods, falling back to the old
      declaring-module scheme when the receiver carries no module.
    - the same naming is used at every call site that resolves a method
      (`resolve_method_info`, `resolve_method_info_imported`,
      `resolve_canonical_hook`) and by the ordering pass.

16. **Same-module foreign calls returning a nominal type** (found while
    verifying 15; 269 of 312 example files had *some* `Types::Error` the host did
    not): `collect_foreign_functions` resolved a same-module foreign function's
    return type with the scalar-only `resolve_scalar_type_ref`, so `-> Vector4`
    (through `type Vector4 = c.Vector4`) yielded `ty_error` — and every call then
    carried `Types::Error` (also poisoning the hoisted `__mt_foreign_ret_N`
    temporaries).  The imported-callee path already used the full resolver
    (`imported_foreign_call`); the same-module path now does too.  `std/raylib.mt`
    and the box2d/box3d examples are down to **zero** `Types::Error`.

17. **Raw receivers search every module for the method** (required by 15 — box2d
    stopped compiling without it): `resolve_method_info` restricts the imported
    search to the receiver's own module to disambiguate same-named structs
    (§0a).  A raw module has no `extending` blocks, so for a `std.c.*` receiver
    that restriction could never match, and the call fell through to a fallback
    that re-resolved with a *module-less* type name (`examples_box2d_common_b2Vec2_add`
    against the emitted `b2Vec2_add`).  The restriction now applies only to
    non-raw receivers.

20. **Floating-point literals are emitted at full precision** (found in the
    emitted C, not in the dumps): `0.2` became `0.20000000000000001` because the
    backend formatted every literal with `%.17g`.  The host renders an integral
    value with one decimal (`1.0`, `100000000000000000000.0`), anything else
    with the shortest decimal string that round-trips (Ruby's `Float#to_s`), and
    appends C's `f` suffix for `float`-typed literals.  `double_to_str` now
    tries `%.1f` and otherwise searches the smallest `%.*g` precision that
    parses back to the same double (`std/fmt.append_double_g`), with Ruby's
    exponent spelling (`1.0e-07`).  The `f` suffix needs the literal's type,
    which exposed a missing piece of contextual literal inference: an untyped
    `0.2` in a `double` position now takes `double`
    (`float_literal_to_context_type`) at local declarations, returns and
    struct-field initializers.  Verified byte-identical against the host for
    nine literal shapes and for the unique float-literal sets of seven files
    (`examples/box3d/ragdoll.mt`: 36 literals, `std/raylib.mt`, `std/sdl3.mt`,
    `examples/language_baseline.mt`, …).

Verification for 15–17: `tools/bootstrap.sh -j 16` (fixed point holds, 12 files /
0 failed); `box2d/drop` and `box3d/ragdoll` build under both compilers and their
output is byte-identical (both are windowed, so runs are `timeout`-bounded);
`lower` sweep unchanged at 38 match / 604 differ / 0 self-rejected with the
*sets* of linkage names now equal to the host's for the vendored families.
Token-level measurement (`diff` over whitespace-split tokens of the `--sexpr
lower` dumps, before → after): `box3d/ragdoll` 34,083 → 5,087;
`box3d/box_stack` 34,121 → 5,133; `box2d/common` 31,622 → 5,558; `box2d/drop`
33,537 → 7,701; each sampled raylib example and `std/raylib.mt` −1,136.  Files
without raw-module `extending` blocks are unchanged, so the corpus-wide *file*
count does not move — every one of the 604 still differs in some later category.

### Same session, third pass — unsigned literals and `:path` attribution

18. **Unsigned literals render in the unsigned domain** (ranked item 1 of the
    second pass; the first difference for the whole `examples/sdl3` family).  The
    host's lexer stores an unbounded Ruby Integer, so `const SDL_MAX_UINT64:
    ptr_uint = 18446744073709551615` stays *positive* and dumps/emits
    `18446744073709551615`, while the self-host's signed `long` holds only the
    same bit pattern and printed `-1`.  The distinction is **provenance, not type
    or value** — the host folds `~0` to `-1` and prints `-1` for the same
    `ptr_uint` type (`std/mem/heap.ptr_uint_max`), so a type- or value-based rule
    cannot work.  The first attempt (render unsigned whenever the type is
    unsigned) fixed the sdl3 constant and broke `ptr_uint_max`, i.e. exactly
    swapped one diff for another.  Landed instead:
    - `ir.mt` gains `expr_unsigned_integer_literal(value: ptr_uint, ty)`, the
      node for a lexeme whose magnitude does not fit a signed `long`; the dumper
      renders it with the same `IR::IntegerLiteral` tag (as the host does), and
      the C backend and pretty printer emit it unsigned.
    - `lowering.integer_literal_expr(lexeme, value, ty)` builds the node wherever
      an *AST literal* becomes IR (contextual typing, const folding, attribute
      args, `evaluate_const_expr_to_ir`); `coerce_const_value` preserves the
      provenance when re-typing.  Folded arithmetic keeps the signed node.
    - `types.is_unsigned_integer_name/_type` mirror the host's
      `unsigned_integer?`.
    Measured: the 5 huge-literal constants the host dumps (sdl3 family) now match
    (0 → 5 in the sample), `~0` still prints `-1`, and both the dump and the
    emitted C match the host for both shapes.  The sdl3 family's first difference
    moved from ~1.5 KB to ~37.8 KB into the dump.

19. **`:path` attribution for statements lowered from an AST node** (ranked item
    2): the bare `return;` lowering used `source_path = ""`, so every guard-style
    void return (e.g. `if size_bytes == 0: return` in `std/mem/heap.mt`) dumped
    `:line 102 :path nil` where the host has the module's path.  One-line fix in
    `lower_stmt` (`ctx.analysis.source_path`, matching the async branch right
    above it).  Measured on a 19-file sample: pathless `return` statements
    **138 → 0**, matching the host exactly; `examples/data_structures.mt`'s
    `:path nil` count fell 47 → 11 (the host has 12; the remaining nils are
    per-function synthetic statements that both compilers leave pathless).

### Measured status (2026-09-25)

> Historical table (the counters describe the tree at that date).  The live
> numbers are the header block and §0j's 2026-09-27 session-2 section: 15/15
> language examples, 34/34 sdl3 files, 60/60 `test/mt`, `lower` 39/613/50/0.

| Gate | Result |
| --- | --- |
| `tools/bootstrap.sh -j 16` | fixed point holds (`stage2.c == stage3.c`), self-test 12 files / 498 tests / 0 failed |
| `build/dev/mtc build projects/stress` | builds; exit 242, empty stdout — identical to the host |
| Language examples (15 top-level `.mt`) | **11 build**, 4 fail: `async_network_lobby`, `async_stress_test`, `data_structures`, `nullable_and_variant_test` (all four build under the host — item 8 of the next list) |
| `test/mt` under the self-host | 60 files run (315 tests pass); **7 fail to build** — the 6 pre-existing ones plus `blackboard_test`, newly enabled by the parse fix, which hits the same generic-instance family (`std_blackboard_find_entry__error` receiver type) |
| `rake "cli:parity"` | 61 cases: 21 match / 39 differ / 1 pending; diff set unchanged by the refactor work |
| `sexpr_parity lex` | 694/694 byte-identical |
| `sexpr_parity parse` | 690 comparable, **0 differ**, 4 host-side rejections |
| `sexpr_parity lower` | 38 match / 604 differ / 52 host-rejected / **0 self-rejected** — every file the host lowers, the self-host lowers too (start of session: 35 / 520 / 53 / 86) |
| Vendored families (sample) | `box2d/drop`, `box2d/explosion`, `box3d/ragdoll`, `box3d/box_stack` build and run with byte-identical stdout in both compilers |

### 2026-09-27 session — self-host hard-build fixes (sdl3 family, `test/mt`, language examples)

Goal: remove the self-host's remaining *hard* failures — the places where it
cannot build what the host builds.  The self-host now builds **15/15 top-level
language examples**, **34/34 `examples/sdl3` files** (it built none), runs
**60/60 `test/mt` files with 0 failures** (seven failed to build), and the
bootstrap fixed point holds with 14/14 test files green.

The fixes, each a distinct root cause:

1. **`extending` block type parameters were not in scope while the receiver
   resolved** (`semantic/analyzer.mt` `check_extending_methods`).  `this` inside
   `extending StateMachine[State, Event, Context]:` was typed
   `StateMachine[<error>, <error>, <error>]`, so every expression recording that
   type (e.g. `ref_of(this)`) lost the bindings and an *inferred* generic call
   specialized under a collapsed `__error__error__error` name with a mismatched
   signature.  The block's type parameters are now entered before the receiver
   type resolves.  This closed six of the seven `test/mt` build failures
   (`behavior_tree`, `blackboard`, `fsm`, `goap`, `htn`, `spatial`) and
   `examples/async_network_lobby`/`async_stress_test`/`data_structures`.
2. **Async frame fields typed as a match-arm payload had no ordering edge**
   (`c_backend.mt` `by_value_dep_key`).  `Result[T, E].success as p` spilled
   across an `await` stores `<variant>_success` in the frame struct, but the key
   function had no `ty_variant_arm_payload` case, so the frame was emitted before
   the variant that defines the payload struct (`field 'local_success_kp' has
   incomplete type`).  The arm name is already registered as an alias of the
   owning variant node; the dependency edge now uses it.  Closed `net_sync` and
   the async frame family.
3. **Opaque values were emitted as values** (`c_backend.mt` `c_type`,
   `render_zero_initializer`/`_expression`, and `guard_success_type` in the
   lowering).  A re-exported opaque (`public opaque Window = c"SDL_Window"`)
   names a C struct that is never defined, so a *value* must be a pointer — the
   host's `Types::Opaque` model (`base*`).  `var window: sdl.Window` now emits
   `std_sdl3_Window* window = NULL;` instead of a value of an incomplete type,
   and a nullable opaque keeps that same pointer form.  Also: the vendored SDL3
   link line now carries `-pthread -lm` (the flags in the vendored build's
   `sdl3.pc`), which the family needs for `fmod`/`atan`.
4. **`ptr_of` on a raw-pointer variable returned the pointer instead of its
   address** (`lowering.mt`).  The "already a pointer" shortcut applied to any
   `ptr[T]`-typed name; the host only short-circuits pointer-lowered bindings
   and `ref[T]`.  `ptr_of(wav_data)` now takes the address (`&wav_data`) as
   `lower_addr_expression` does, which `sdl3/audio/load_wav` needs.
5. **`array[T, N]` arguments at a foreign `span[T]` boundary were materialized
   as arrays** (`lowering.mt` `lower_inline_foreign_mapping`): the mapping's
   `points.data` / `points.len` then addressed an array temp.  The projection now
   coerces through `array_value_to_span` (`{ data = &arr[0], len = N }`), taking
   the element type from the argument because the declared name is an alias of
   the binding's module.
6. **Recursive variant arm fields were read without the dereference**
   (`lowering.mt` `lower_member_access`): a field that embeds the enclosing
   variant is stored as a pointer (`.left = &a`), so reads must be `*b.left`.
   The auto-deref handled `ty_named`/`ty_imported` receivers; a match *binding*
   is typed `ty_variant_arm_payload`, which is now handled too.  Closed
   `examples/nullable_and_variant_test`.

Verification: `tools/bootstrap.sh -j 16` (fixed point holds, 14/14 files),
`build/dev/mtc test test/mt -I .` (**60 files, 0 failed**), the 15 language
examples, the full sdl3 sweep, a 40-file raylib sample (40/40), runtime
stdout+exit parity against host-built binaries for `data_structures`,
`nullable_and_variant_test` and `option_and_result_surface`, `cli:parity`
(22/39/0, unchanged), `sexpr_parity` lex 702/702, parse 698 comparable / 0
differ, `lower` 38/615/49/0 (unchanged).  New self-host tests live in
`projects/mtc/test/c_backend_test.mt` (opaque-as-pointer, `ptr_of` address,
recursive-payload deref, generic extending block); the fsm/htn/goap family in
`test/mt` locks fix 1 under both compilers.

### 2026-09-27 session 2 — `lower` fidelity: const aggregates, literal typing, dyn vtables

Goal: work §0j's ranked table from the top, starting with the reported blocker.
Five fixes, each verified against the host's `--sexpr lower` output; the
before → after figures are the affected file's *first difference* depth.

1. **Const aggregates of an alias-qualified type** (item 12 — the reported
   `MilkTea/SimpleGame` blocker).  `public const MIDNIGHT: rl.Color =
   rl.Color.from_hex_str("#10121c")` with `type Color = c.Color` in std.raylib now
   folds to the host's `(IR::AggregateLiteral :type (Types::Struct :name "Color"
   :module_name "std.c.raylib") …)` with `ubyte` fields instead of staying an
   `IR::Call` (which the C compiler rejects as a non-constant initializer).
   Three pieces, all in `lowering.mt`: `const_aggregate_target_type` resolves a
   constructor's target through the same alias chain the runtime construction
   path uses (`lower_aggregate_literal_impl`), `try_const_struct_literal_ir` now
   takes the *resolved* type plus its declaring module (so the field lookups
   follow the alias), and `const_value_to_field_type` types every folded field
   value by the field's own type (the host's `lower_compile_time_literal`),
   recursing into `array[T, N]` elements.  **Verified end-to-end**:
   `mtc build .` on `~/Projects/MilkTea/SimpleGame` prints
   `built ./src/main.mt -> build/simple_game` and the binary runs (raylib and
   audio initialize; no crash); `colors.mt`'s dump matches the host's
   byte-for-byte up to an unrelated foreign-cstr temp-naming difference (first
   difference 20.7 KB → 63.2 KB).  Regression test:
   `projects/mtc/test/lowering_test.mt`
   `test_const_aggregate_through_imported_type_alias` — a three-module fixture
   (raw struct module, alias re-export, extending block + consts in the root)
   asserting both the formatted IR and the sexpr type/field shape.

2. **Zero-valued aggregate fields and array elements typed by field/element
   type** (item 2).  The same typing makes `b3_emptyDistanceCache`'s
   `metric = 0` a `float` literal and `indexA = array[ubyte, 4](0, 0, 0, 0)`
   keep `ubyte` elements, and the runtime `array`/`simd` constructors type their
   elements contextually (the host's `lower_contextual_expression`).
   `box3d/ragdoll` 15.5 KB → 50.4 KB, `box3d/box_stack` → 50.7 KB.

3. **`null` contextual typing** (item 3).  A bare `null` operand of `==`/`!=`
   takes the other operand's type (`source == null` types the literal
   `Nullable(ptr[ubyte])`), and the runtime path gives a *typed* `null[T]` its
   `Types::Null :target_type T` instead of `void`.  The second half needed a
   matching C-backend guard: `variant_c_name_for_type` fed every operand type to
   `c_type`, which has no `Types::Null` arm (the host decides variant-ness by
   type class, never by `c_type`), so `null[ptr[T]]` in a comparison aborted the
   backend (`async_network_lobby`, `async_stress_test`); it now returns the empty
   name for non-nominal types, mirroring the host's type-class check.
   `data_structures` 37.1 KB → 38.9 KB, `reflection_advanced` 32.1 KB → 32.8 KB.
   **Documented divergence:** for a *left-hand* bare null (`null == x`) the host
   records `bool` on the literal node — an artifact of a later inference pass
   recording the comparison's expected type there — while the self-host types it
   from the other operand; no corpus file uses that shape
   (`tmp/probes/reversed_null.mt` is the only probe).

4. **Integer literals take the declared type in local and global declarations.**
   `var index: ptr_uint = 0` (`std/mem/heap.mt`) and `var shorts: short = 0`
   (`language_baseline`) now carry the declared type, mirroring the host's
   contextual literal inference for local declarations and module-level `var`s.
   These were the next first differences for the data-structures/reflection
   families and for `language_baseline` after fixes 3 and 5.

5. **`dyn` vtable constants substitute the interface's type parameters** (item
   5).  `mt_vtable_DoublerMap_Mapper`'s method slot is
   `fn(ptr[void], int) -> int` rather than the interface's bare `T`:
   `gen_dyn_vtable_constant` now substitutes exactly as the vtable struct and the
   wrapper functions already did.  `language_baseline` 33.0 KB → 34.2 KB (its
   next first difference is the proc representation, §0i item 2).

Gates: `tools/bootstrap.sh -j 16` (fixed point holds; 14 files / 516 tests / 0
failed — the bootstrap exits non-zero on a broken fixed point, and it exited 0),
`sexpr_parity` lex/parse unchanged, `lower` **39 match / 613 differ /
50 host-rejected / 0 self-rejected** (was 38/614/50/0 — one more file is
byte-identical, the rest moved deeper), `cli:parity` unchanged at 22/39/0, and
the SimpleGame build + run above.

### Why the `lower` sweep's "HOST-FAIL" bucket is not a host bug

The sweep reports files the *host* refuses to lower separately instead of
counting them as differences.  The bucket is now (2026-09-27 session 2, 702
files: 39 match / 613 differ / **50 host-rejected** / 0 self-rejected) entirely
`external` files (raw C bindings such as `std/c/*.mt` — no IR exists to dump)
and platform-pinned files (`*.wasm.mt`, `*.windows.mt`), i.e. *not* host bugs.
The previous three genuine host-side rejections are fixed:

- `examples/raylib/core/custom_frame_control.mt` — the host's
  implicit-conversion rule is deliberate (`double` → `float` needs a cast, see
  `test_explicit_double_to_float_is_rejected`); the example now annotates its
  time variables `double` and casts where it narrows, so both compilers build it.
- `examples/raylib/text/unicode_emojis.mt` — a foreign call that must be lowered
  as a statement now prepares its own arguments first, so a nested foreign call
  that needs a temporary is hoisted ahead of it instead of failing the
  inline-only check.
- `examples/raylib/textures/image_processing.mt` — a nullable pointer
  (`ptr[Color]?`) now projects as its base at a foreign boundary, because a
  nullable pointer has the same C representation (`pointer_represented_nullable_base?`).

Fixing those exposed two further host bugs, both fixed in the same pass:

- a checked-index argument for a pointer-to-array receiver emitted the *array*
  pointer where the helper takes the *element* pointer
  (`read(ref[array[T, N]])[i]` produced invalid C);
- an embedded array field initialized from an array-valued expression emitted
  an invalid array assignment (`Holder(colors = make())`, and the same for
  `array[array[T, N], M](f(), g())`); it now copies element by element.

### The `projects/stress` build — absorbed record (2026-09-25, DONE)

Goal: `build/stage2/mtc build projects/stress` compiles, links and runs with
output matching the host's build.  **Achieved**: exit **242**, empty
stdout/stderr; the fixed-point gate holds.

Reproduce and verify:

```sh
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o build/dev/mtc        # 1. compiler
timeout 300 bash -c 'ulimit -v 20000000; \
  build/dev/mtc build projects/stress -I . --no-cache -o /tmp/stress_self'    # 2. target
timeout 20 bash -c 'ulimit -v 20000000; /tmp/stress_self'; echo $?            # 3. must exit 242
tools/bootstrap.sh -j 16                                        # 4. fixed point holds
```

Per-section parity was checked with a probe driver (each section's subtotal
printed through `std.terminal`): all 12 sections — including `compile_time`,
`math` and `async` — are byte-identical to the host.  Reference behavior: the
host build exits **242** with empty stdout/stderr.

What was broken (root causes, not symptoms):

| Area | Root cause | Fix |
| --- | --- | --- |
| `aio.wait(task_expr)` | a `Task[X]` argument passed to a `proc() -> Task[X]` parameter was handed over bare; the narrow bridge matched only same-module bare-identifier callees, so a qualified `atasks.task_pipeline()` fell through | the host's task-expression→root-proc bridge in `lower_call_with_callee`: the argument AST is wrapped in a synthesized `proc() -> Task[X]` thunk (`lower_task_expression_as_root_proc`) and lowered through the proc path, capturing enclosing locals; `lower_proc_expression_typed` split out; the invoke builders take the resolved return type |
| proc literal inside an async function | the invoke builders cleared the CPS state but not `ctx.inside_async`, so `return x + offset` was wrapped in a task literal while the invoke returned `int32_t` | save/clear/restore `inside_async` with the other CPS flags |
| `3.0 * v3` | builtin `vec3(...)`/`mat4(...)`/`quat(...)` were unknown callables → `<error>` → the numeric fallback emitted `(mt_vec3) 3.0 * v3` | `try_construction` resolves the builtin names (host `lookup_named_type`); `lower_vec_binary_op` expands component-wise |
| `f"#{hex}"` on a format-string local | `lower_format_string_local` emitted the C local but never pushed a `LocalBinding`, so the interpolation formatted `str` as int | register the local binding; capacity/append use `.len` + `mt_format_append_str` |
| `inline for` over `members_of`/`attributes_of` | qualified type args unresolved; member names/values only in the current module; `attributes_of` hardcoded; `member.name` never substituted | `comptime_type_arg_name` resolves module-qualified names; program-wide member lookup; real attribute applications (declaration-level + the new field-level `field_attribute_apps`); `inline_for_member_subst` handles `.name` |

Regression tests added (passing under both compilers): `test/mt/reflect_test.mt`
(`inline for` over `members_of`/`attributes_of`), `test/mt/fmt_test.mt`
(interpolating format-string locals), `test/mt/linear_algebra_test.mt` (new —
vec/ivec/mat/quat arithmetic and `std.linear_algebra`).  The verification log
also recorded: `rake "cli:parity"`'s differ set byte-identical to the
pre-change compiler's; the Ruby-host suites (`lowering_test`, `semantic/*`,
`examples_smoke_test`, `in_language_tests_test`) all pass.  Known gaps at the
time, both fixed 2026-09-27: the seven `test/mt` build failures
(generic-instance naming/typing — `check_extending_methods` resolved `this`
before the block's type parameters; an async frame field typed as a match-arm
payload lacked a `by_value_dep_key` ordering edge) and the `inline for`
first-branch fold quirk (`lower_if_stmt` now walks the branches in order —
locked by `test/mt/reflect_test.mt`'s `test_members_of_name_selection_chain`).

### The `lower` ranking at the last sweep (frozen 2026-09-27; live list: the program's Track 3)

There are **no self-rejections left**: the self-host analyzes and lowers every
corpus file the host can.  What remains is *dump fidelity*; **all hard build
failures are closed** (2026-09-27: 15/15 language examples, 34/34 sdl3 files,
60/60 `test/mt`, and the reported `MilkTea/SimpleGame` project).  Ranking after
the fourth pass (the second 2026-09-27 session closed items 2, 3, 5 and 12 —
see "2026-09-27 session 2" below); item 1 plus the three items it uncovered
(13–15) are the categories the current first differences are dominated by.
The table below is the frozen evidence/approach record from that sweep; the live
ranked list — merged with the per-item notes — is **the program's Track 3**.

| # | Item | Evidence | Approach |
| --- | --- | --- | --- |
| 1 | **Opaque declarations** (`IR::OpaqueDecl`) — *dump difference only; the builds are FIXED (2026-09-27)* | the first difference for the whole `examples/sdl3` family: host `(IR::OpaqueDecl :name "Window" :linkage_name "SDL_Window" :forward_declarable true :source_module "std.sdl3")` vs self `(:name "std_sdl3_Window" :forward_declarable false)`.  The family's *build* failure had a different root cause (opaque values emitted as values, plus missing SDL3 private link flags) and is fixed — all 34 sdl3 files build | a re-exported opaque keeps its *declared* name and forwards `typedef struct <c_name> <name>;`; mirror the host's `OpaqueDecl` naming/`forward_declarable` (roadmap #6).  `collect_opaque_decls` builds the entry; the C backend's opaque typedef emission must move with it |
| 2 | ~~**Zero-valued aggregate fields typed by field type**~~ **FIXED (2026-09-27 session 2)** | `box3d/ragdoll`'s first difference was host `(IR::AggregateField :name "metric" :value (IR::FloatLiteral :value 0.0 :type (Types::Primitive :name "float")))` vs self `(IR::IntegerLiteral :value 0 :type (Types::Primitive :name "int"))` | `const_value_to_field_type` re-types every folded field value by the *field's* type (the host's `lower_compile_time_literal`), recursing into `array[T, N]` elements, and the runtime `array`/`simd` constructors type their elements contextually.  The family's first difference moved from ~15.5 KB to ~50 KB into the dump (now item 13) |
| 3 | ~~**`null` literal contextual typing**~~ **FIXED (2026-09-27 session 2)** | `data_structures` / `reflection_advanced`'s first difference was host `(IR::NullLiteral :type (Types::Nullable :base (Types::Generic :name "ptr" …)))` vs self `(IR::NullLiteral :type (Types::Primitive :name "void"))` | comparisons now re-type a bare `null` operand from the other side (the host propagates the left operand's type to the right), and the runtime path gives a typed `null[T]` its `Types::Null :target_type T`.  **Documented divergence:** the host types a *left-hand* bare null (`null == x`) as `bool` — an artifact of a later inference pass recording the comparison's expected type on the literal node; the self-host types it from the other operand.  No corpus file has that shape (`tmp/probes/reversed_null.mt` is the only probe).  Both files' first differences moved deeper (now item 14) |
| 4 | **Event fields in event-carrying structs** | `event_stress_test`'s first difference: host `(IR::Field :name "__event_closed" :type (Types::Event :name "closed" :capacity 4 …))` vs self `(IR::Field :name "closed" :type (Types::Struct :name "mt_event_…_closed_4"))` | the event runtime models each `event` field as `__event_<name>` typed `Types::Event`; the self-host emits the listener-slot struct under the bare name.  Mirror the host's field naming/type in the event-declaration lowering |
| 5 | ~~**Generic-specialization parameter types**~~ **FIXED (2026-09-27 session 2)** | `language_baseline`'s first difference was `(Types::Parameter :name "x" :type (Types::Struct :name "T" :module_name ""))` where the host has `int` | `gen_dyn_vtable_constant` now substitutes the interface's type parameters like the vtable struct and the wrapper functions already do (the const is a `DynVtable`'s method slot).  `language_baseline`'s first difference moved past it (now the proc-representation gap, §0i item 2) |
| 6 | ~~**Function-type names**~~ **FIXED (session 16, F5)** | visible in the sdl3 dumps right after item 1's first difference: host `:name "run_app_no_args_uninitialized"` vs self `:name ""` | `ty_function` carries the host's `name` and `sexpr.mt` emits it (`6ad423ce`); keep as a regression watch only |
| 7 | **Include set** (`math_bindgen.h` vs `raymath.h`, box2d/drop.mt) | the first difference for `examples/box2d` | the binding's include directives must match the host's registry (std.math → raymath) |
| 8 | **Struct/declaration ordering**, **const-folding shape**, **enum-member const folding**, **variant-match goto** | `ClockSync` vs `std_net_recv_impl_frame`; `IR::IntegerLiteral` vs `IR::Cast` (`errno_test.mt`); 4 / 1 files | mirror the host's decl ordering in the C backend's sort; fold `T<-literal` casts in constant position; roadmap #7/#13 |
| 9 | ~~**Four example build failures** (`async_network_lobby`, `async_stress_test`, `data_structures`, `nullable_and_variant_test`) and the 7 `test/mt` build failures~~ **FIXED (2026-09-27)** | all four examples build and run at stdout+exit parity with the host; `test/mt` is 60 files / 0 failed | four root causes: the analyzer's extending-block type parameters (three examples + six `test/mt` files), an async frame field typed as a match-arm payload with no ordering edge (`net_sync`), opaque values emitted as values, and recursive variant arm reads missing their dereference.  Details in the 2026-09-27 section above |
| 10 | **CLI message parity** | `rake "cli:parity"` 39/61 differ, set unchanged all session | message text, stdout-vs-stderr channel and argument-precedence differences (e.g. `std show` prints to stdout instead of stderr; `build --bogus` reports "accepts a single source path" instead of "unknown build option") |
| 11 | ~~**Host-side bugs (report, not fix here)**~~ **FIXED (2026-09-27)** | 3 files + the `inline for` quirk | `custom_frame_control.mt` (implicit double→float is rejected by design — the *example* now annotates its time variables `double` and casts where it narrows), `unicode_emojis.mt` (a statement-lowered foreign call now prepares its arguments so nested calls with temporaries hoist ahead of it), `image_processing.mt` (a nullable pointer projects as its base at a foreign boundary).  Two further bugs exposed and fixed: the checked-index argument for a pointer-to-array receiver, and an embedded array field initialized from an array-valued expression.  Regression tests: `test/compiler/c/basic_1_test.rb` (`nullable_pointer_through_const_void_boundary`, `nested_foreign_call_in_variadic_argument`), `test/compiler/c/basic_2_test.rb` (`checked_index_through_ref_array`, `writes_array_through_ref`, `array_field_initialized_from_array_call`, `copies_array_field_from_array_call`), and the `inline for` name-selection chain in `test/mt/reflect_test.mt` |
| 12 | ~~**Const functions returning alias-qualified aggregates**~~ **FIXED (2026-09-27 session 2)** — the reported `MilkTea/SimpleGame` blocker | `public const MIDNIGHT: rl.Color = rl.Color.from_hex_str("#10121c")` with `type Color = c.Color` in std.raylib | `const_aggregate_target_type` resolves the constructor's target through the same alias chain the runtime path uses, `try_const_struct_literal_ir` takes the resolved type plus its declaring module for field lookups, and `const_value_to_field_type` types each folded field.  Verified: SimpleGame builds and runs under the self-host, and the file's dump matches the host up to an unrelated foreign-cstr temp-naming difference.  Regression test: `projects/mtc/test/lowering_test.mt` `test_const_aggregate_through_imported_type_alias` |
| 13 | **A global initialized from an imported constant** | `box3d/ragdoll`/`box_stack`'s first difference: host `(IR::Global :name "s_world_id" … :value (IR::AggregateLiteral :type b3WorldId :fields …))` vs self `(IR::Name :name "std_box3d_b3_nullWorldId" :type (Types::Error))` | `examples/box3d/common.mt`'s `var s_world_id: b3.b3WorldId = b3.b3_nullWorldId`: the host inlines the referenced constant's value into the global's static initializer; the self-host resolves the name but cannot type it (`Types::Error`).  Port the host's `lower_static_storage_initializer` (`utils.rb:336`: `compile_time_const_value` → `lower_compile_time_literal`) for module-level globals |
| 14 | **Refined (non-null) operand types after a null check** | `data_structures`/`reflection_advanced`'s first difference after item 3: host `:left (… :type (Types::Generic :name "ptr" …))` vs self `:type (Types::Nullable :base (Types::Generic :name "ptr" …))` | the host narrows a nullable binding's *expression* type after an `is null`/`!= null` guard (flow refinement); the self-host keeps the storage type.  Port the refinement's refined-type recording into `expr_type` for guarded uses |
| 15 | **Proc representation** (host `Types::Proc` + `__proc_N__env` vs self `Types::Struct mt_proc_T`) | `language_baseline`'s first difference after item 5 | §0i roadmap item 2 — the largest remaining item; **not started** (27 corpus files use proc literals) |

### `lower` differences, by first difference (after the 2026-09-27 session-2 fixes)

| Files (sampled) | First difference |
| --- | --- |
| 34 (`examples/sdl3/**`) | opaque declaration naming/`forward_declarable` — item 1 |
| 2 (`box3d/ragdoll`, `box3d/box_stack`) | a global initialized from an imported constant (`b3.b3_nullWorldId`): the host inlines the aggregate, the self emits a `Types::Error` name — item 13 |
| 2+ (`data_structures`, `reflection_advanced`) | a guarded nullable operand keeps `Types::Nullable` where the host's flow refinement narrowed it to `ptr[...]` — item 14 |
| 1 (`event_stress_test`) | event field naming/type (`__event_closed` typed `Types::Event`) — item 4 |
| 1 (`language_baseline`) | proc representation (`Types::Proc` vs `mt_proc_T`) — item 15 |
| 1 (`box2d/drop`) | include set (`math_bindgen.h` vs `raymath.h`) — item 7 |
| remainder | declaration ordering, const-folding shape, enum-member const folding, variant-match goto, plus cases beyond each file's first difference |

Contextual literal typing (the dominant category at the start of that session,
213 files), raw-module linkage naming, unsigned-literal rendering, void-return
`:path` attribution, alias-qualified const aggregates, aggregate field/element
literal typing, `null`/typed-null contextual typing and the `dyn` vtable's
substituted method slots all now match the host; the vendored families'
linkage-name *sets* equal the host's, and a 19-file sample has **0** pathless
`return` statements (host: 0, before: 138) and all 5 huge-literal constants the
host dumps.  The remaining `lower` mismatches start 35–63 KB into the dumps for
the families these sessions touched (they were at ~1.5–2.3 KB at the start).

---

## 0i. 2026-09-24 session — `--sexpr` lex/parse parity + sweep tool

Goal: make the self-host `lex|parse|lower --sexpr` output byte-identical to
Ruby's. `lex` and `parse` are now effectively at parity; `lower` still has the
type-model gaps listed below.

### Fixed
- **Unsigned 64-bit integer literals** render unsigned (`18446744073709551615`,
  not `-1`); hex/binary literals accept `_` separators (`0xff_ff_00_00`).
- **Float literals** use correctly-rounded `strtod` (the host's `.to_f`), fixing
  e.g. `3.14159265358979323846` → `3.14159`.
- **External files**: directives carry nil positions, declarations render nil
  visibility, and the raw module line is the `external` line.
- **Parser**: block-form `if` expressions (`let x = if c:` newline body `else:`)
  and `event`/`struct` used as struct field names.
- **`parse` module names** follow the host's package-source-root + project-root
  fallback; `parse` resolves active-platform variants.
- **Variant arm payloads** are tagged `Types::VariantArmPayload` and absent IR
  node types are modelled as nil, matching the host.

### Tooling
`tools/sexpr_parity.rb` + `rake "sexpr:parity[mode]"` load the Ruby compiler
once and fork workers, so full-repo sweeps are lex ~4s, parse ~7s, lower ~3min
(vs ~6–30min per-file). Host-side rejections are reported, not counted as
failures; the tool warns when `--self` is stale.

### Baseline (as of this session — see §0j for the live numbers)
- **lex: 692/692 byte-identical.**
- **parse: 683/692** — remaining: module-qualified struct destructuring
  (`let types.Transform(x, y) = t`); 8 host-side rejections (platform-pinned
  files, empty match arms).  *(Closed 2026-09-25: parse is 690/690 comparable
  files byte-identical.)*
- **lower: still divergent** (see roadmap).  *(Re-measured 2026-09-25: 0
  self-rejections; the live ranking is in §0j.)*

### Remaining `lower` gaps (roadmap)
1. **`ref[T]` / pointer representation** — **DONE**: a pointer-lowered receiver
   is its base type with `:pointer true` (C adds the `*`), params are never
   pointer-lowered, implicit method borrow/coercions recognize pointer-flagged
   names, and explicit lifetime args render like the host (`ref[@a, T]`) with
   the referent taken from the last argument at every extraction site.
2. **Proc / closure lowering** — host `Types::Proc` + `__proc_N__env` struct +
   `__proc_N__invoke/release/retain/setup_env`; self `Types::Struct mt_proc_T`
   with inlined setup. **Not started** (largest remaining item; 27 corpus files
   use proc literals).
3. **Dyn interface vtables** — **DONE**: `Types::DynVtable`, vtable struct
   `vtable_<Iface>`, wrapper `__dyn_<Concrete>_<method>`, the
   `mt_dyn_<Iface>` value struct routed to `Program.monomorphized_structs`
   (host parity), vtable field `void*`/`data`-named, adapt-call cast
   `ptr[DynVtable] → void*`, method slot typed with the vtable's
   `Types::Function`.
4. **`let … else:` guard binding** — host names the guard temp after the user
   binding (`value`); self uses `__mt_guard_N`.
5. **Nested struct C names** — host `<Parent>_<Child>`; self drops the parent
   path (`<Child>`); C only (host also names the union
   `<Variant>_data`, self `<Variant>__data`).
6. **Opaque/enum declarations missing** — host emits `:opaques` (`RawHandle`,
   `CFile`) and e.g. `EventError`; self emits none.
7. **Const folding** — string constants lower to `IR::ZeroInit` (e.g.
   `RENAME_ARG`); enum/global scalar types default wrong (`short`/`byte`/
   `ptr_int` vs `int`).
8. **Generic-instance ordering** — host lists generic base functions
   (`load`/`store`) before their specializations; self emits specializations
   first; constant ordering differs.
9. **Parallel-for / detach naming** — host `mt_pfor_cap_<mod>_pfor_N`,
   `mt_pfor_work_…`, `mt_spawn_work_…`; self `mt_pcap_…`, `mt_p_work_…`.
10. **For-loop lowering** — host hoists `__mt_for_stop_N`; self differs.
11. **Integer-promotion casts** in bit ops differ.
12. **Contextual integer-literal typing** — host types an integer literal used
    where a `ptr_uint`/`ubyte` field is expected (e.g. `len = 64`) with the
    field's type; self types it `int`.
13. **Variant-match goto** — host emits an explicit `IR::GotoStmt` to the match
    end after each no-fallthrough arm body; self omits it.

Priority: 2 is the last pervasive item; 4–13 are localized/mechanical.

**Re-measured 2026-09-25 (§0j)**: the corpus is 694 files; the self-host now
lowers **every file the host lowers** (0 self-rejections), 38 byte-identical and
604 differing.  Item 12 (contextual literal typing) is **done** — it was the
largest category at 213 files.  The live ranking and the approach for each
remaining item are in §0j's "Remaining work" table (raw-module linkage naming,
`:path` attribution, declaration ordering, const-folding shape, include set,
opaques/const folding, then the hard example/`test/mt` build failures).  Note
that proc/closure lowering (item 2 above) appears in only 8 files' first
difference, consistent with just **27 corpus files containing a proc literal**, so
it is not the pervasive blocker this list implies.

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
- 7 modules, 1,050 lines, process backend with child I/O polling
- Audited 2026-09-27 with `tools/dap_smoke.rb`: process-backend parity per request,
  four small bugs fixed (malformed `exited` body, missing `process` event,
  `dataBreakpointInfo`/`setExpression` undispatched, `--backend` ignored)
- Lldb-dap bridge **is feasible now** — `std/libuv.mt` exposes `uv_poll_*` and
  `std/async` a libuv runtime, so one event loop can watch stdin and the adapter
  (§dap-design §9, rewritten); the extension's default backend is `lldb-dap`,
  which is why stepping/evaluate/attach still answer with the process backend's
  errors
- `launch` on a `.mt` source does not build it yet (the host does), and the
  self-host build does not emit `<output>.mtdbg.json` — §10 rows 1 and 3



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
| ~~Formatter CST modes (`--tidy`, `--preserve`)~~ **DONE (§7, 2026-09-26)** | — |
| Linter wrap-fix machinery (`line-too-long` auto-fix) — pipeline landed (§7.2), wiring left | Small |
| **Added 2026-07-19** | |

---

## 5. Remaining Gaps (2026-07-19, re-measured 2026-09-25 in §0j)

The compiler is at a held fixed point (516 tests across 14 files at the
2026-09-27 session-2 measurement; 591 by 2026-10-02; 217/219 raylib — the 2
non-builds are correct rejections).
**Corrected 2026-09-25:** the "13/13 language examples" figure below was stale —
the self-host built **11 of the 15 top-level examples** then, and four `test/mt`
files had been silently skipped by the test runner, which hid one more
pre-existing build failure.  **Both are closed (2026-09-27):** the examples are
15/15, `test/mt` is 60/60, and the sdl3 family is 34/34 (see §0j's 2026-09-27
section).  The LSP is at capability parity with Ruby (29 advertised, all 53
handler methods dispatched).  Remaining gaps are infrastructure-depth items, the
`lower` dump differences and the analyzer false positives listed in §0j:

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
expanded to 10 auto-fixable rules (2026-07-19, §0f). **Sema-based
`redundant-cast` is DONE (2026-09-27 session 4, stage 8c).** Remaining linter
delta: `reserved-primitive-name` use-site renaming (declaration-only today);
`constant-condition` compound-assignment tracking.

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

### 5.3c Linter parity session — 2026-07-22

Extensive parity work brought the self-host linter output on `language_baseline.mt` to near-identical matching with Ruby. Summary:

| Rule | Before | After | Target | Status |
|------|--------|-------|--------|--------|
| `prefer-is-variant` | 0 | 3 | 3 | ✓ parity |
| `prefer-conditional-expression` | 2 | 6 | 6 | ✓ parity |
| `prefer-or-pattern` | 5 | 3 | 3 | ✓ parity |
| `unused-local` | 25 | 24 | 24 | ✓ parity |
| `redundant-type-annotation` | 1 | 2 | 2 | ✓ parity |
| `constant-condition` | 1 | 3 | 3 | ✓ parity |
| `prefer-inline-if` | 2 | 2 | 2 | ✓ parity |
| `self-comparison` | 2 | 2 | 2 | ✓ parity |
| `unreachable-code` | 1 | 1 | 1 | ✓ parity |
| `redundant-return` | 1 | 1 | 1 | ✓ parity |
| `line-too-long` | 1 | 1 | 1 | ✓ parity |
| `unused-param` | 5 | 5 | 5 | ✓ parity |
| `noop-compound-assignment` | 17 | 17 | 17 | ✓ parity |
| `prefer-let` | 37 | 16 | 13 | Improved |
| `dead-assignment` | 45 | 32 | 0 | Improved |
| `redundant-cast` | 0 | 1 | 4 | Improved |

**14 rules at exact parity. 3 rules improved but still have gaps.**

#### Fixes applied (files: `linter/linter.mt`, `linter/cfg.mt`, `linter/scope_tracking.mt`, `linter/redundant_cast.mt`, `linter/constprop.mt`, `lsp/semantic_tokens.mt`):

1. **`prefer-is-variant`** (0→3): `classify_is_variant_arms` treated `pattern=null` (wildcard in `is_desugar`) as not-a-wildcard. Fixed to accept `pattern==null` as wildcard.

2. **`prefer-conditional-expression`** (2→6): `check_prefer_conditional_expression_match` had same `pattern!=null` guard that rejected wildcard arms. Fixed to accept `pattern==null`.

3. **`prefer-or-pattern`** (5→3): `stmts_structural_equal` for `stmt_ret` only matched void returns. Added value comparison via `exprs_structural_equal`. Also `stmt_assignment` equality was missing RHS value comparison — added `exprs_structural_equal(aa.value, ab.value)`.

4. **`constant-condition`** (1→3): New `linter/constprop.mt` module adds forward constant propagation. Tracks integer/boolean values of `let` bindings and simple assignments, evaluates if/while conditions. Old trivial check reduced to only cover self-comparisons (`x==x`).

5. **`unused-local`** (25→24): `expr_sizeof`/`expr_alignof`/`expr_offsetof` and `expr_specialization` type arguments were not visited in `visit_expr`. Added `visit_typeref` to mark identifiers in TypeRef name parts as used.

6. **`redundant-type-annotation`** (1→2): `type_ref_leaf_name` rejected nullable types (`int?`). Added `type_ref_leaf_name_nullable` that strips `?`.

7. **`prefer-let`** (37→16): Three improvements:
   - Index/member-access targets in `ctx_mark_mutated` recurse to the root identifier
   - `read(...)` calls in assignments mark arguments as mutated
   - New `ctx_mark_alias_source` detects `ref_of(x)`/`ptr_of(x)`/`const_ptr_of(x)` and marks the source identifier as potentially mutated

8. **`redundant-cast`** (0→1): Added literal-type detection (`float<-1.5`, `int<-42`) in `check_expr`. Remaining gap: sema-based type resolution for function returns and type aliases.

9. **`dead-assignment`** (45→32): `walk_stmt_backward` now treats compound assignments (`+=`, `-=`, etc.) as reads-writes (keeps variable in live set). Added `expr_match` handling, `stmt_for` binding removal, `stmt_parallel_block`/`stmt_gather` support.

10. **Semantic token fixes** (snapshot + LSP): Decorator tracking (`@[...]`), enum member dot-access via `static_member_types`, parameter-name collision in enum body, struct/union body separation from enum/flags body.

#### Remaining gaps — architectural plan

##### 1. `prefer-let` mutation facts — **DONE (2026-09-27 session 5b)**

Landed (see §0k's "Linter `prefer-let` mutation facts" record): `out`/`inout`
foreign arguments are recorded by the analyzer and exported so *imported*
`alias.fn(...)` calls credit them too, str_buffer's mutating builtins resolve as
`editable`, and `ref_of`/`ptr_of` alias sources mark their argument with the
host's exact rule.  `language_baseline` is 19/19 against the host.  The
historical plan follows.

The self-host's `ctx_mark_mutated` now handles AST-level mutation patterns (direct assignment, index access, member access, `read()` calls, `ref_of`/`ptr_of` aliases). Three false positives remain that require **sema-side tracking**, matching Ruby's approach:

**Ruby's approach:** The semantic analyzer records three sets in `BindingResolution`:
- `mutating_argument_identifier_ids`: identifiers passed to `out`/`inout` FFI parameters
- `editable_receiver_expression_ids`: receivers of `editable` method calls  
- `mutable_lvalue_argument_identifier_ids`: array/str_buffer→span coercion sites

The linter queries these via `mark_call_argument_mutated` and `mark_call_receiver_mutated`.

**Self-host changes needed:**
1. **A.** Add `editable_receiver_ids: Map[ptr_uint, bool]` to `Analysis` struct — populated during `check_call` when `call_kind.editable == true`. Store `reinterpret[ptr_uint](receiver_expr)` as key.
2. **B.** Add `mutating_arg_ids: Map[ptr_uint, bool]` — populated when an identifier is passed to a foreign function parameter with `out`/`inout`/`consuming` mode.
3. **C.** In `ctx_mark_mutated` or a new `visit_expr` hook, query these sets. When visiting a `call`, check if the callee receiver is in `editable_receiver_ids` → mark as mutated. When visiting a call argument, check if the argument identifier is in `mutating_arg_ids` → mark as mutated.
4. **D.** Thread the `Analysis` ref through `lint_source_opts` to the scope_tracking pass.

The three specific false positives:
- L354: `var buf: int` → `wrap_write(buf, 99)` — `buf` passed to `out` parameter (needs `mutating_arg_ids`)
- L1177: `var buffer: str_buffer[64]` → `buffer.assign("hello")` etc. — method calls mutate receiver (needs `editable_receiver_ids`)
- L1653: `var counter: atomic[int]` → `counter.store(0)` — editable method call

##### 2. `redundant-cast` (1→4): sema-based type resolution

Current AST-level check only handles:
- Same-name identifier casts (`int<-x` where `x` declared as `int`)
- Literal casts (`float<-1.5`)

Missing: function-return-value casts (`int<-(func())`), type-alias casts (`Seconds<-2.0` where `Seconds = float`), and inferred-variable casts (`int<-(prev)` where `prev` is inferred).

**Ruby's approach:** `resolve_expr_type` maps `AST.node_ids[expr.object_id]` → `@sema_facts.resolved_expr_types[node_id]` to get the semantic type. Then compares `cast_type` vs `inner_type` structurally.

**Self-host changes needed:**
1. **A.** Modify `redundant_cast.check()` to accept an optional `ptr[analyzer.Analysis]`.
2. **B.** Add `resolve_expr_type(analysis, expr) -> Option[types.Type]` bridge: use `reinterpret[ptr_uint](expr)` as key into `analysis.resolved_expr_types`.
3. **C.** For function call expressions (`expr_call`), resolve the return type from `resolved_call_kinds` → function signature.
4. **D.** For type-alias casts, follow `analysis.type_alias_types` chain to resolve `Seconds` → `float`.
5. **E.** Thread the Analysis through `lint_source_opts` to `lint_redundant_cast`.
6. **F.** Pass `lint_source_opts(..., analysis)` from the main CLI path where `check_program` produces the Analysis.

##### 3. `constant-condition` (3 vs 3, 1 mismatch): compound assignment value tracking

Current constprop removes variables from the tracking map on compound assignments (`+=`, `-=`, etc.), preventing detection of conditions like `x > 0` after `y += 1` (where only `y` was modified, `x` is still a known constant).

**Ruby's approach:** Full dataflow framework (`control_flow/constant_propagation.rb`) with fixpoint solver, lattice (UNDEF → ConstVal → NAC), and `ConstEval.evaluate` for expression-level constant folding.

**Self-host changes needed (simpler than full dataflow):**
1. **A.** In `const_eval_expr` for `stmt_assignment` with compound operators, attempt to evaluate `old_value + amount` before removing.
2. **B.** For `+=`/`-=` etc., look up the current value from the map, evaluate the RHS, compute new value, and store it.
3. **C.** For assignments where either operand is not constant, remove from map (NAC — current behavior).

##### 4. `unused-import` — **DONE (2026-09-27 session 5)**

The self-host now ports both of the host's collectors: `collect_used_names`
(lexical: root names of type refs, identifiers in expressions, match patterns)
and `collect_method_only_import_uses` (receiver-type module, method-provider
modules, canonical hook providers).  See §0k's "Linter `unused-import` credit
parity" record: `language_baseline` 1 → 0, and 605 of 606 sampled files agree
with the host; the one residual (`examples/async_network_lobby.mt`) needs
match-arm payload typing in the analyzer (follow-up).

##### 5. `dead-assignment` (32→0): self-host-only feature

The 32 remaining hits are mostly genuinely dead writes (c, d, e in `expressions_demo` are computed but never contribute to the return value). Ruby does not implement this rule. The backward-walk liveness approach is path-insensitive — it doesn't model if/else join points.

No architectural changes planned — this is a self-host value-add feature. The 32 remaining hits are either genuinely dead writes or edge cases from the path-insensitive approach.

### 5.4 CLI commands not implemented (§0.4)

`deps` and `docs`.  The other 21 commands exist in the self-host, and
`rake "cli:parity"` measures 22 of 61 fixture cases matching (the rest differ in
message text/channel/argument precedence, not command coverage — §0j).
`snapshot` and the legacy `debug` command are implemented.

### 5.5 Subsystems not ported (§4)

Package-graph resolution (`--locked`/`--frozen`, Large), `--bundle` /
`--archive` (Medium), wasm/emcc + preview server (Large), `--jobs` parallel
tests (Medium).  The vendored-library recipes (raylib, glfw, tracy, cjson, box2d,
box3d, sdl3, flecs, pcre2, steamworks, libuv) all exist in the self-host's
`build.mt`; the sdl3 family's private link flags (`-pthread -lm`) were the last
gap and landed 2026-09-27.

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

> Historical list — the live ranking is §0j's "Remaining work" table (compiler/
> CLI) and §0k's gap table (LSP).  As of 2026-09-27 there are no hard build
> failures left, so 1–3 and 5 below are the remaining *breadth* items.

1. **`deps` package management** (Large) — the biggest remaining CLI gap;
   `--locked`/`--frozen` resolution depends on it.
2. **`--bundle` / `--archive`** (Medium) — native package distribution.
3. **Wasm/emcc + preview server** (Large) — platform reach.
4. ~~**Formatter CST modes**~~ **DONE (2026-09-26, §7)** — `--tidy` and `--preserve` are self-hosted and byte-identical across the repository; the remaining formatter gap is canonical-mode comment reattachment.
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
- **Format-string completions** — `f"...#{...}"` interpolation context
- **Snippet completions** — `funcName(${1:arg1}, ${2:arg2})` parameter insertion
- **Value-chain completions** — chained dot access (`a.b.c.|`)
- **Specialization completions** — `name[...]` generic arg context
- **Type-cast insertion code action** — parse expected type from diagnostic data
- **Linter: sema-based `redundant-cast`** — needs analyzer type resolution
- **Linter: `line-too-long` wrap-fix** — needs formatter CST builder
- **Import completions filtering** — minor: filter adjustment for prefix-match when filter is non-empty but shorter than prefix (currently uses OR logic; should AND for non-empty prefix)
- **Sporadic SIGSEGV** — crash-guards in place; no reliable repro

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

A change is safe only if: stage2.c == stage3.c, **14 test files / 591 tests pass
with 0 failures** (`tools/bootstrap.sh -j 16` reports the count; re-measured
2026-10-03), the language
examples do not regress (live baseline: **15 of 15** build, and `examples/sdl3`
is 34/34), and the raylib passing set does not shrink
(currently 217; the 2 non-builds must remain clean rejections with Ruby's
messages).  LSP changes additionally require the self-vs-host harness
(`tools/lsp_parity.rb`, §0k — it drives the resolve endpoints a real editor
calls) plus valgrind and, for behavior changes, the headless-Neovim smoke test;
user-visible LSP changes should also run the headless VS Code session with the
server under valgrind (that is how the 2026-09-26 `codeLens/resolve` double free
was found).  Formatter changes add the mode sweep:

```sh
ruby tools/format_parity.rb all -j 16    # preserve / tidy must be 702/702
```

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

For **`--sexpr` output parity** (lex/parse/lower), use the dedicated sweep tool
`tools/sexpr_parity.rb`. It loads the Ruby compiler once and runs both compilers
in parallel, so a full-repo sweep takes seconds instead of minutes (Ruby process
startup, ~0.5s, otherwise dominates). Build a fresh self-host binary first —
stale binaries give false results (the tool warns when `--self` is older than the
newest self-host source):

```sh
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o build/stage2/mtc

ruby tools/sexpr_parity.rb lex   -q            # repo-wide, ~4s
ruby tools/sexpr_parity.rb parse -q            # repo-wide, ~7s
ruby tools/sexpr_parity.rb lower -q            # repo-wide, ~3min (nproc jobs)
ruby tools/sexpr_parity.rb all examples/*.mt   # lex+parse+lower on a subset
rake "sexpr:parity[lex]"                       # same via Rake
```

Exit status is 0 only when every comparable file matches; host-side rejections
(e.g. external raw bindings, platform-pinned files, compile-fail fixtures) are
reported but not counted as failures.

**Live baseline (2026-09-27 session 2, §0j):** lex 702/702; parse 698 comparable
files with 0 differences (4 host-side rejections); `lower` **39 match / 613
differ / 50 host-rejected / 0 self-rejected** over 702 files — the host-rejected
bucket is only external and platform-pinned files, and the differing files are
the mechanical categories ranked in §0j's "Remaining work" table (opaque
declaration fields, globals initialized from imported constants, refined
nullable operands, event fields, function-type names, include sets, declaration
ordering, proc representation).

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

## 7. Formatter Gaps (CST modes landed 2026-09-26)

### 7.1 Current State

`mtc format` supports all four of Ruby's modes:

| Mode | Ruby | Self-host |
| --- | --- | --- |
| `:canonical` | AST pretty-print with trivia reattached | **DONE** — comments reattached (`format_source_file_with_trivia`) |
| `:safe` | Same as canonical | Same as canonical |
| `:preserve` | CST-based, keeps original formatting | **DONE** — `formatter/cst.mt` |
| `:tidy` | CST normalize → wrap → blank lines | **DONE** — `formatter/tidy.mt` |

Measured by `tools/format_parity.rb` (host in-process, self per file, `-j`
workers) over the repository's 702 `.mt` files: **preserve 702/702, tidy
702/702 and canonical 702/702 byte-identical** (2026-09-27 session 4 — canonical
was 302/702 before the comment reattachment and the four printer-fidelity fixes
in §7.2b).  The LSP's `formatting` + `rangeFormatting` entries are closed by the
same pipeline (§0k stage 5).

### 7.2 Landed 2026-09-26

| Piece | Where | Host reference |
| --- | --- | --- |
| Trivia-aware lexing | `lexer/trivia.mt`, `lexer.mt` (`lex_with_trivia`) | `core/lexer.rb:136-193, 207-292, 424-440`, `core/lexer/trivia.rb` |
| CST build + reconstruct | `formatter/cst.mt` | `core/cst.rb` |
| Mode dispatch, wrap, blank lines | `formatter/tidy.mt` | `tooling/formatter.rb:13-24, 54-216, 225-778` |
| LSP handlers | `lsp/formatting.mt` | `lsp/server/formatting.rb:646-693` |
| CLI flags (`--tidy`/`--preserve`/`--canonical`/`--safe`/`--max-line-length`/`-w`/`--`) | `main.mt` `format_command` | `tooling/cli/commands/format.rb:111-171` |
| Sweep | `tools/format_parity.rb` | — |
| Tests | `projects/mtc/test/tidy_formatter_test.mt` | host goldens |

### 7.2b Landed 2026-09-27 session 4 — canonical comment reattachment + printer fidelity

The canonical printer now takes the lexer's trivia and reattaches comments like
the host's `PrettyPrinter.format_ast(ast, trivia:)`:

- `format_source_file_with_trivia(file, source, trivia)` builds the comment
  state (comment-per-line map + blank-line set) and emits leading comments
  (`flush_leading_comments_before`), inline comments on the header line
  (`attach_inline_comment`, splicing before the recorded line's newline) and the
  remaining comments at the end (`flush_remaining_comments`); the struct case
  re-anchors its header after attribute lines, exactly like the host, and a
  comment/blank line between `unsafe:` and its single statement blocks the
  inline collapse (`unsafe_inline_comment_conflict`).  Proc-body captures share
  the parent's comment state, so comments inside procs stay inside the proc
  text.  `mtc parse` keeps using the trivia-free entry, as the host's does.
- `formatter/tidy.mt`'s `format_canonical` lexes with trivia and passes it in.

The sweep then exposed four pre-existing printer gaps, all fixed against the
host's `ast_formatter.rb`:

1. **Format strings rendered as nothing** — `render_expression` had no
   `expr_format_string` arm, so `draw(f"x = #{a}")` printed `draw()`.  Ported
   `render_format_string_part` + `escape_format_text` (precision/hex/oct/bin
   specs, `\`/quote/control escapes).
2. **Implicit enum/flags member values** printed as `circle = 0`; the host
   prints `circle`.  Gated on `EnumMember.value_explicit`.
3. **Method `const`** was dropped: `const function area()` / `static const
   function make(...)` now render through the host's
   `visibility, async, kind, const, function` order (`Method.is_const`).
4. **Struct lifetime parameters** (`struct SliceView[@a]`) were dropped; the
   header now uses `render_struct_params(lifetime_params, type_params)`.

Verified with `ruby tools/format_parity.rb all -j 16`: **preserve 702/702, tidy
702/702, canonical 702/702**; `projects/mtc` self-tests 14 files / 0 failed with
new comment/format-string tests; the canonical f-string and box2d/comptime
fixtures diff clean against the host.

### 7.3 Remaining

| Gap | Effort | Depends on |
| --- | --- | --- |
| ~~Canonical-mode comment reattachment~~ **DONE (2026-09-27 session 4, §7.2b)** | — | — |
| ~~Linter `line-too-long` wrap-fix~~ **DONE (2026-09-27 session 4, stage 8b: wrappable gate + message suffix + LSP `Wrap long line` quickfix)** | — | — |
| Linter `:fast` tier | Small | independent |
| Formatter `--timings` profile phases | Small | independent |

The two open rows (`:fast` tier, `--timings`) are tracked in the program
(Track 7's stage-plan residue).

## Appendix — working notes (absorbed)

Structural rules learned while porting, each costing a rebuild cycle (from the
absorbed stage plan):

- `Analysis.resolved_expr_types` / `resolved_call_kinds` / `const_values` are
  keyed by **expression pointer** (`reinterpret[ptr_uint](ep)`); `Type`-valued
  maps (`types`, `type_alias_types`, `static_member_types`) are fine (name
  keys).  Any caller that re-parses the source must lint/analyze the *analysis'
  own AST* (`read(analysis).source_file`) or rebuild the analysis from its parse
  (the fix engine does the latter per pass).
- `analysis.types` maps names (aliases resolved) → `Type`; enums/flags/variants
  are `ty_named` and also appear in `analysis.static_member_types`.
- `Map.get` returns `ptr[T]?` (nullable pointer), `Vec.get` returns
  `Option[ptr[T]]`; `read()` needs a narrowed *local*, not a struct field.
- Language keywords to avoid as identifiers: `emit`, `match`, `type`, `link`,
  `include`, `event`, `final`, `inline`, `parallel`, `when`, `opaque`, `ref`,
  `own` (a function named `emit` failed to parse; a local `match` too).
- The self-host's analyzer binding ids are **name-keyed** where the host's are
  per-declaration — several gates note this in the records (e.g.
  `dead-assignment`'s origin gate, the documentHighlight carry-forward).
- `resolve_cursor` facts must come from the loader-backed
  `analysis_for_document` / `ast_for_document`, never the standalone
  `check_source_file` (whose `imported_modules` is null) — the session-6
  finding.
- The host aborts a file at its first semantic error; probe one shape per file
  (the session-22 rule-set measurement).

## Provenance

This document absorbed and replaced the following planning files on 2026-10-03
(session 25).  Their content is merged above; the three `docs/` originals are in
git history, and the nine machine-local session plans under
`~/.commandcode/plans/` were removed (the durable record was always this file
plus those session plans, which the merge superseded):

- `docs/foundational-blockers-plan.md` → the absorbed F1–F9 record in §0k and
  the program's LSP track.
- `docs/lsp-parity-plan.md` → the program's LSP track + the §0k session
  records it summarized.
- `docs/self-host-stress-todo.md` → §0j's "The `projects/stress` build —
  absorbed record".
- `~/.commandcode/plans/finish-self-host-full-parity.md` → the program, the
  Ledger, and the session close blocks in §0k.
- `~/.commandcode/plans/remaining-lsp-linter-formatter-parity.md` → the
  program's LSP track (the unexecuted stage residue) + this appendix.
- `~/.commandcode/plans/foundational-blockers-plan.md` and
  `lsp-real-project-parity.md` (stale session copies), and the superseded
  session plans `self-host-cli-and-lowering-parity.md`, `lsp-parity-gaps.md`,
  `lsp-parity-gap-closure.md`, `lsp-stage4-diagnostics-semantic-tokens.md`,
  `lsp-formatting-tidy-parity.md`.
