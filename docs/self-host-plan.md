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
- §0k — LSP / linter / formatter records and the session history (sessions 4–44)
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
Stage2 == stage3 byte-identical; the compiler self-test suite is **19 test
files, 726 tests, 0 failed** (re-measured 2026-11-03 session 45 batch 9; 618
tests across 17 files at session 33, 516 at session 2);
the self-host also builds every example and `test/mt` file the host does (see
§0j's 2026-09-27 section).
**Linter parity: `language_baseline.mt`'s and `memory_stress_test.mt`'s
diagnostic arrays are byte-identical to the Ruby host's (98/98 and 10/10, 0
differing lines; sessions 17–18), and the whole-corpus sweep reads 495 agree /
121 differ of 616 files (session 40 re-measure, below).**
**Raylib parity: 217/219 build and run** (2026-07-16 sweep).
**Language examples: 15/15 build under `--no-cache`** (2026-09-27; the four that
failed — `async_network_lobby`, `async_stress_test`, `data_structures`,
`nullable_and_variant_test` — are fixed, see §0j's 2026-09-27 section) and
**the `examples/sdl3` family is 34/34** (it built none before); every example
that builds also matches the host's stdout+exit (sampled: `integration_test`,
`reflection_advanced`, `language_baseline`, `event_stress_test`). **The vendored example families now
build and run at parity**: `box2d/drop`, `box2d/explosion`, `box3d/ragdoll` and
`box3d/box_stack` produce byte-identical stdout under both compilers, and
`examples/sdl3` files `check` clean (§0j items 5–13). **`mtc lint` implements 41 of the host's
43 rules plus `--fix` (12 of the host's 13 auto-fixable rules; the `lint --fix`
sweep over 15 examples × 12 rules is 179/180 byte-identical, the one divergence
pre-existing — Track 2) and `.mt-lint.yml` config**; unported (audit, session 33): the
host's `directional-ffi-arg` and `platform-api-drift` rules and the
`redundant-unsafe` fix generator (`prefer-inline-methods`'s auto-fix landed in
session 28).  Bootstrap via `tools/bootstrap.sh`.
Test runner now builds in-process (no Ruby delegation).  Vendored library
recipes complete for all **11** vendored families (raylib, glfw, tracy, cjson,
box2d, box3d, sdl3, flecs, pcre2, steamworks, libuv).  Bindgen self-hosted (687 lines CL
→ MT type mapper + clang JSON AST parser).

**DAP: 7 modules plus `mtc/debug_map.mt`, `dap/lldb_backend.mt` and
`dap/lldb_policy.mt`; the dispatcher answers 26 DAP commands.**  The process
backend is **row-for-row equal** to the host on `tools/dap_smoke.rb`
(2026-10-04 session 34: request surface, error text, `terminated`→`exited`
order, `launch` on a `.mt` source building it into a temp dir), and the
**lldb-dap bridge** (the VS Code extension's default) is in: the adapter
handshake, capability merge, event forwarding, reverse requests and command
forwarding all match the host against the harness's fake adapter, with the
debug-map frame/variable rewrites and pause diagnostics landing next.  The
remaining gaps are §10's #3/#4 of `docs/dap-design.md`.**
**LSP: 42 modules, ~29.3k lines (2026-10-04 session 33 count); capability-parity with Ruby; feature parity measured at **4 differing entries** (§0k), all deliberate and documented (host parser recovery, the host hanging on a malformed frame, the host's facts lag, and the host's directory-form module `typeDefinition` path, where the self resolves the imported declaration — session 28); `milkTea/debugInfo` is **byte-equal** (session 35's Facts/Bindings port closed session 33's fifth entry).  The harness corpus is **70 requests + 27 probes**.  All 30 capability keys match, both semantic-token comparisons are byte-equal, and a real VS Code session runs clean (the 2026-09-26 `codeLens/resolve` double free is fixed, and the harness now drives the resolve endpoints a real client sends).**
**LSP project audit (live counter, 2026-10-03 session 27): `tools/lsp_project_audit.rb --workspace ~/Projects/MilkTea/SimpleGame` — 7075 entries, **4 stable differing entries + the host's first-file `documentSymbol` race**: `completion` **2** (the session-26 close read 4; the two byte-vs-character position entries are closed by the request-boundary conversion — the residue is the host's synthesized `ref` lifetime `mst@224:18` and the host giving up on a `map_error` arm binding `lb@818:17`, both documented), `hover` 1 (the documented `type quat` `lb@1653:24`) and `documentHighlight` 1 (`lb@704:67`, the host's warm-facts snapshot carry-forward); the race entry (`docs/data_structures.mt documentSymbol`) appears only when the host's first-file facts lag (measured in the gates run).  **Every other class 0**, including `diagnostic` (all seven files' diagnostic arrays are byte-identical after the session-18 linter work), `definition`/`declaration`/`typeDefinition`/`implementation`/`references` (915 each, 0), `documentSymbol` and the file-level endpoints.**
**LSP project audit (previous live counter, 2026-10-03 session 26): 7075 entries, **6 differ = `completion` 4 + the 2 documented entries**: completion **4** (235 at the session-24 close; the residue is classified in §0k's part-3 record — the host's synthesized `ref` lifetime, the host giving up on a `map_error` arm binding, and two byte-vs-character positions inside comment lines), `hover` 1 (the documented `type quat` `lb@1653:24`) and `documentHighlight` 1 (`lb@704:67`, the host's warm-facts snapshot carry-forward).**  Earlier live counters: session 18 read 2 differ on the then-6456-entry corpus (the entry count grew with the completion pass), session 13 read 22.
**LSP project audit (live counter, 2026-09-29 session 13): `tools/lsp_project_audit.rb --workspace ~/Projects/MilkTea/SimpleGame` — 6456 entries, **22 differ** (session 13 close): hover 9, documentSymbol 5, semanticTokens 5, diagnostic 2, documentHighlight 1; codeLens, workspace/symbol and definition/declaration/typeDefinition/implementation/**references 0**.  The progression is 1328 (session start) → 332 (sessions 6–9) → 269 (session 10) → 224 (session 11: hover 32 → 14) → 56 (session 12: the definition pipeline) → 37 (session 13: the cross-file definition index — Track C1 — definition/declaration 5 → 0 each, typeDefinition 4 → 0, implementation 1 → 0, hover 13 → 9) → 25 (session 13's second batch: documentHighlight 14 → 2, the host's binding node set) → 22 (session 13's third: codeLens and workspace/symbol 1 → 0 each via the host's token-pair symbol list, documentHighlight 2 → 1, and the token scanner's keyword/heredoc/type-argument rules).  The per-method counters move a few entries between runs because the host's definition index and facts caches warm up as the audit proceeds, so treat each counter as ±10 and compare *sets of differing keys* when verifying a fix.  The hover residue is the analyzer's flow-refinement family (4), stage 11c's payload/destructuring bindings (3), the `fn ` field rendering (1) and a member chain's third segment (1); documentHighlight's single survivor needs the host's carried-forward binding resolution (a label token resolving a binding that is out of scope at that line).  Hover/definition/declaration/typeDefinition are at **0 differing entries** on the probe fixtures (`tmp/probe-ws`, `probe4`–`probe6`, `fieldprobe`, `thisprobe`; `probe2` keeps its 2 deliberate answers), and so are their references; `hover-probe4` closed 6 navigation entries in this session.  Cold start (session 13, `tools/lsp_cold_start.rb`): spawn → the first `workspace/symbol` response fell from 2723.5 ms to **213.3 ms** on SimpleGame and from 2455.1 ms to **2.3 ms** on a one-file project (the index walk is the workspace root now, not every module root).  Residue classified in §0k.**
**LSP recovery (`tools/lsp_recovery_probe.rb --check`, 2026-09-28 session 9): the six-edit corpus of mid-edit states (truncated `n.`/`a.inner.`, unterminated string/block, half-typed `import`, cut-off expression) is at **recovery parity — all six cases byte-equal**, after the parser's panic-based unwinding, the parse/lex location suffix, and the four lint/analyzer knock-ons it exposed (§0k, session 9).**
**Formatting: the CST-backed `:tidy` / `:preserve` modes are self-hosted and byte-identical to the host across the repository (`tools/format_parity.rb`, re-measured 2026-10-04 session 33: **712/712 in all three modes**; the file count drifts with tmp fixtures — the canonical printer reattaches comments and trivia like the host); the LSP's `formatting` and `rangeFormatting` entries are closed.**
**Hover: 1 entry left in the audit — the documented `type quat` cross-file
location `lb@1653:24` (session 13's list of 9 was cut by the completion-parity
sessions and the request-boundary conversion; the classification history is
§0k's session-13 and part-3 records).**
**LSP stability: zero SIGSEGV/SIGABRT crashes; UTF-8 boundary auto-adjust; parser/lexer recoverable.**
**LSP logging: structured stderr, version+revision announcement, a `[LSP perf] req <method> <ms>`
line per request (the host's shape), default level `info`, and `milkTea.lsp.logLevel`
forwarded by the extension as `--log-level`.**
**Diagnostic positions: lexer-based token matching; buffer-overflow warning fix (MAX_ENTRIES 16→128).**
**Code lens: reference counts with deduplication; all index entries queried.**
**References: cross-file via workspace index; definition: local variables supported.**
**Signature help: method calls and extending-block methods resolved.**
**Imported-bindings: 7 modules (incl. registry + methods), ~2,900 lines.  `mtc imported-bindings` CLI command with --all/--check.
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

**`--sexpr` parity (lex/parse re-measured 2026-10-04 session 33; `lower`
re-measured 2026-11-03 session 45): lex 712/712
comparable byte-identical; parse 708 comparable files byte-identical with 0
differences (4 host-side rejections: external files, platform-pinned); `lower`
**479 match / 187 differ / 51 host-rejected / 0 self-rejected of 717 files** (the
host-rejected bucket is only `external` and platform-pinned files; the count
drifts with the tree's own sources — quote the set; session 44's batches (1–17)
took it 216 → 286, the batch-19–21 proc stages kept the set with the dumps
moving closer, and session 45's fourteen batches took it 286 → 479; the ledger
carries each batch's movement).  The
ref/lifetime and dyn vtable
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
declarations.  The remaining `lower` deltas (session 45 batch-14 read) are led by
the remaining foreign-call argument/temp materialization (the cstr-temp
ordering and the nested `foreign_expr` residue), the array/const literal shape,
the nullable field type drop (`opaque_backing_names`), the `?` propagation's
statement/return shape, the late-instance placement residue (the host's
`lower_functions` fixpoint), the event runtime names (10e/4b), the async frame
field's nullable drop and a statement's line/path shape — see Track 3's ranked
list.  The explicit format sink (3z), the contextual numeric casts, the
prefix-cast constant fold, the `and`/`or` result temp, the variadic cstr
projection and the foreign-call component protocol (batch 14) landed in batches
10–14, and the post-guard assignment target and the foreign-boundary
projections are closed.  Item 8a (the `const_ptr_of` boundary cast) is closed.
The sdl3 family's *builds* are fixed
(2026-09-27) — the dump-level differences above remain.

Last updated: session 45 (2026-11-03) — **`lower` batches 1–14: 286 → 479 match**.  Batch 14 ported the host's foreign-call component protocol (`bind_foreign_mapping_arguments`'s three passes: public-alias reuse/`foreign_arg_public`, value preparation, `foreign_arg` temps), the `prepare_foreign_in_argument` hoist on both the mapping and simple paths, the cstr assignment-metadata refresh (a plain `str` assignment clears a literal-backed local's cstr flag), and the nested value-position foreign result materialization (`foreign_result` before the frees; a statement-root call still stores directly) — 467 → 479 (+12), 0 new differing files.  Batch 13 applied the cstr projection to a `str` argument in a foreign wrapper's variadic slot (`text_format(c"%s", value)` → `Cast(cstr, Member(value,"data"))`, or the temp copy for a non-cstr-backed value) — 454 → 467 (+13), 0 regressions; the `TextFormat`/`DrawText` family is byte-identical.  Batch 12 folded a prefix cast's compile-time constant (`uint<-MoverBit` → 2, wrapping to the target width/signedness — the box2d `categoryBits` outer cast) and ported the host's prepared `and`/`or` shape (a setup-producing operand hoists a `__mt_and_N`/`__mt_or_N` result local and guards the right operand with `if result` / `if not result`) — 444 → 454 (+10), 0 regressions.  Batch 11 ported the host's contextual numeric compatibility (a folded constant that fits the declared type, int→char, the declared-float int→float arm — skipped for a foreign-call initializer, and the external-numeric assignment pair; the struct aggregate fields use the shared helper), and moved the synthetic proc/worker functions to the host's program-level creation-ordered tail (appended after every module's functions, not a per-module leftover) — 427 → 443 (+16 after the contextual batch's +7), 0 regressions; the compiler-source subset went 49 → 63 match.  The `?` propagation's failure return now carries the analysis path with no source line (the success binding keeps its line/path).  Batch 10 ported the explicit format sink (3z: `std.fmt.append_format/assign_format`, `String.*_format` and `str_buffer[N].*_format` stream into the destination through the host's part/copy/offset protocol and four-argument `mt_str_buffer_clear`, with no built `str` or release; `String.as_str` and the custom-hook parts take the host's aggregate/slice shapes), made a local/assignment format release a block defer (the host's `local_defers`, while a foreign call's temp free stays immediate), kept a non-owning `return f"..."` release with a `__mt_return_value_N` temp (an owning `str` return drops it), hoisted an assertion condition's prepared setup, and typed signed literals through their declared context (`let delta: short = -42`) — 414 → 420 (+6), 0 new differing files; `test/mt/fmt_test.mt` is byte-identical.  Batch 9 typed a foreign mapping's fixed literal argument against the raw C parameter (`= c.SDL_RunApp(..., null)`'s null is `Nullable(ptr[void])`), inlined a compile-time constant range-for stop (`__mt_for_stop_N` only for non-constants), saved/restored the caller's format state across a lazy generic-method specialization (a nested `String.as_str` no longer makes a later `f"..."` lose `__fmt_<dest>`), gave a `let … else:` guard's storage the block's format destination, and promoted mixed-signedness integer operands to the host's signed common type (`uint` vs `int` → `long`).  Batch 8 closed the post-guard assignment target (the multi-line flow replay is a *view*, not a transition — `std/map.mt`'s `previous = node` keeps the storage `Nullable`), prepared the inline match expression (`__mt_match_expr_<N>` plus its switch in the statement's setup), gave the `_` local its host declaration (`__mt___N`, the stored value), and ported the conditional's expected/common type (pointer-sized integers as fixed-width 64 and `ptr_int` as signed, the host's numeric common type and compatibility fallbacks, a `Context.expected_type_hint` for declared locals/assignments/returns, and the signed-literal harmonization) — 385 → 405 match, 0 new differing files.  Batch 7 gave a variant struct-pattern equality arm's guard its present empty else (`else_body ()`, not nil).  Batch 6 flushed the loop-scoped `defer`s before a `break`/`continue` (the host's `lower_loop_exit`): the cleanup runs before the label goto instead of the exit dropping it (a real leak).  Batch 5 made a `let … else:` guard a prepared position (the initializer's foreign-call temps hoist before the storage local, with the wrapper's declared return as the storage type), typed the `?` propagation's failure member chain like the host (`data` nil, the arm payload, the error field) and its return path, and materialized a propagation binding's success value into a real local.  Batch 4 closed **item 8a** and the foreign-boundary projections: an `in`/plain `as` wrapper argument takes the host's `AddressOf(const_ptr[parameter.type])` and `foreign_identity_projection_expression` (`Cast` to the declared boundary), and a generic wrapper lowers under its inferred call-site substitution (the host's `binding.type_substitutions`).  It also nested the tuple match expression's if-chain into else bodies (the wildcard arm innermost), typed an unannotated local from a foreign wrapper's declared return (`cstr?`) while the call keeps the raw `ptr[char]`, and gave a guarded identifier's local inference the flow-refined visible type.  The monomorphized-call argument is now contextually typed (`lower_plain_call_spec`: a literal takes the specialized parameter's type — `heap.must_alloc_zeroed[SleepState](1)`'s `1` is `ptr_uint`); the async main's `wait` resolves the *public* `std.async.wait` binding (the host's `async_main_runtime_callee_name`), so the whole delegation chain (`std_async_wait__int`, `std_async_runtime_wait__int`, `std_async_libuv_runtime_wait__int`) is emitted; a generic declaration's instances sort by the host's `type_arguments.map(&:to_s).join(",")` rendering (the 3ad residue — `span[TypeParamConstraint]` precedes `span[TypeParam]` because `C` < `]`); an imported variant's arm-payload binding carries its declaring module; `as_span()`'s decay is a plain `IR::Index`; and an assignment target takes the flow-refined visible type (the host's `lower_assignment_target` rule, via the new position-ordered `analyzer.flow_type_at_position`, with the active type substitution applied; the plain-target equality case keeps the binding's own type, because the record can carry the same nominal without its module — `examples/raylib/core/undo_redo.mt` caught that).  Batch 2 then landed the assertion intrinsics (default messages with ` at <path>:<line>`, the synthesized fatal statement's nil line + analysis path), static-method-call literal typing, the switch-arm `continue`'s loop label, the iterator-loop binding's nullable storage projection, the `ptr_of`/`ref_of`/`const_ptr_of` casts (`cast_expression` shapes), and function-reference type names (`Types::Function :name <declaration>`).  Batch 3 added the hash-hook argument casts (the `order`/`equal`/`hash` builtins take `const_ptr[T]`, the host's `lower_hash_operation_argument`) and the implicit `ref[T]` argument bridge (a pointer-lowered receiver casts to the ref target, a plain addressable value is borrowed).  Batch 9 measured **414/252/51/0** (was 286/380), +128 flips through batch 9 (batch 1 +16, batch 2 +36, batch 3 +2, batch 4 +35, batch 5 +8, batch 6 +1, batch 7 +1, batch 8 +20, batch 9 +9); batch 10 measured **420/246/51/0**, +6 flips, 0 regressions (before/after differing-set comparisons against the batch-9 binary), and `test/mt/fmt_test.mt` is byte-identical; batch 11 measured **443/223/51/0**, +23 (contextual numeric casts +7, the synthetic program tail +16), 0 regressions; batch 12 measured **454/212/51/0**, +11 (the prefix-cast constant fold +1, the `and`/`or` result temp +10), 0 regressions; batch 13 measured **467/199/51/0**, +13 (the variadic foreign `str` argument's cstr projection), 0 regressions; `tmp/async_probe.mt` is content-complete (the delegating chain is present; its first difference is the late-instance *placement*, the wave-model residue below).  The full wave model (creator-tracked fixpoint emission) was implemented and **reverted with evidence**: it mispredicts because the Ruby analyzer instantiates generic bodies per instance before lowering while the self's analyzer checks declarations once, so the emission waves differ (corpus 286 → 264); the late-instance placement stays a known residue with the `SpecInfo`-based model recorded here.  Batch 13 gates: bootstrap fixed point holds, dev suite 19/0 (46 new tests total; 739 tests), `test/mt` 60/0, examples 49/49, `sexpr_lower` 467/199/51/0, LSP harness 30/30 + 4 documented, recovery OK.

Session 44 batch 21 (2026-10-10) — **`lower` item 8A stage D: the
contained-proc retain/release lifecycle** — a proc-containing local registers a
guarded release defer at its declaration (flushed at every scope exit, branch
exit and return) and retains a non-fresh initializer; a proc-containing
assignment goes through the host's `proc_assign` temp (selective retain of the
RHS, guarded release of the old value); a returned proc-containing value is
retained before the defers; a proc-storing capture is retained by its env; and
the async frame retains proc params in the ctor and releases proc-storing frame
fields in its release/cancel bodies.  All six sync proc probes are now
**byte-identical** (`tmp/proc_probe.mt`, `tmp/proc_let_probe.mt`,
`tmp/proc_fn_probe.mt`, `tmp/proc_sort_probe.mt`, `tmp/probe_b13.mt`), the
`tmp/async_probe.mt` residue is the delegating `wait` chain, and the corpus
holds 286/380/51/0 with the dumps moving closer
(`examples/language_baseline.mt` 1,717,013 → 1,742,976 of the host's 1,760,611;
`test/mt/vec_test.mt` 675,596 → 680,290 of 687,612), 0 flips / 0 regressions /
0 shallower.
Session 44 batch 20 (2026-10-10) — **`lower` item 8A stage C: the
proc literal's IR shape** — the env setup is now inline in the enclosing
statement stream (the host's `lower_proc_expression_for_local` shape: a
`__mt___mt_proc_expr_<N>_env_<M>` local from `mt_async_alloc(sizeof(env))`,
`__mt_ref_count = 1`, the capture stores), the literal itself materializes into
a `__mt_proc_expr_<N>` local (the host's `materialize_prepared_expression`), and
the invoke/release/retain bodies take the host's naming (`env` param,
`__mt_proc_env_ptr`, `__mt_capture_<name>`).  The separate `__setup_env`
function survives only as the lazy-region fallback (no prepared position).
Measured: `tmp/proc_probe.mt` moves 2,963 → 10,853, the new
`tmp/proc_let_probe.mt` starts at 8,149 (both residues are stage D's
retain/release lifecycle), `tmp/proc_fn_probe.mt` and `tmp/probe_b13.mt` stay
byte-identical, and the proc probes build and run identically on both
compilers; the corpus holds 286/380/51/0 with 2 files' first difference deeper
(`std/toml.mt` and `test/mt/toml_test.mt`, +105,556), 0 flips / 0 regressions /
0 shallower.
Session 44 batch 19 (2026-10-10) — **`lower` item 8A stage A (+
its stage-B naming): the proc type representation** — a proc value's IR type is
now the closure's own `ty_function(is_proc=true)` (rendered `Types::Proc`, the
analyzer's form) instead of the `mt_proc_*` named struct, which becomes a
backend artifact; the C struct takes the host's `proc_type_name` spelling
(`mt_proc_proc_int_int`, elements module-qualified so `std.toml.Entry` and
`std.json.Entry` no longer collide); the C backend maps the type to the struct
(declarations, arrays, `by_value_dep_key`) and the fn-pointer declarators carry
the host's parameter names; a call to an `fn`-typed local emits the host's
Name-typed callee.  Measured: `tmp/proc_fn_probe.mt` is **byte-identical**,
`tmp/proc_probe.mt` moves 731 → 2,963, `tmp/async_probe.mt` 178,016 → 199,969
(both build and run identically on both compilers, `tmp/probe_b13.mt` stays
byte-identical); the corpus holds 286/380/51/0 with **70 files' first difference
deeper** (max +666,663 — the compiler's own sources, `std/net/*`,
`std/toml.mt`, `std/tar.mt`, `projects/tetris`), 0 flips / 0 regressions /
0 shallower.  The bootstrap caught one real bug on the way (the fn→proc
coercion wrapped a bare function name with the name's plain `fn` type).
Session 44 batch 18 (2026-10-10) — **`lower` item 10l and the
async runtime shapes (the host's inline `async_complete_statements` replaces the
completion label/goto; the no-await resume's result store; the release's
not-ready guard; the set_waiter typing; the full cancel body; the Task
members' field types; the async main's `___async_main` ctor linkage)** — the
`tmp/probe_b13.mt` fixture is **byte-identical** (the batch-17 14,909-offset
residue is closed end to end), `tmp/async_probe.mt`'s first difference moves
23,882 → 178,016 and its built programs run identically on both compilers
(no-await async, CPS chains, `?` propagation, waiters, async main); the corpus
holds 286/380/51/0 (26 async-family dumps change behind item 8A's mask).  A new
`ir.Expr.expr_assignment` variant carries the host's
`IR::ExpressionStmt(IR::Assignment)` cancel shape.
Session 44 batch 17 (2026-10-10) — **`lower` items 10j/10k (the
ctor aggregate's vtable entries take the host's names/linkages
(`<ctor>__<role>_fn` / `<ctor>__<role>`, `<name>__resume`), field types (the
vtable signatures) and param names (`frame`/`__mt_frame_raw`,
`waiter_frame`, `waiter`))** — the probe moves 5,243 → 14,909 (10l the no-await
resume's result store is the residue); the corpus holds 286/380.
Session 44 batch 16 (2026-10-10) — **`lower` item 10i(c)
(`ir.Expr` `Name.pointer` and `LocalBinding.pointer` are `Option[bool]`: 210
`expr_name(` + 36 `LocalBinding(` sites wrapped, the readers take
`unwrap_or(false)`, `none` only at the async param bindings/copies) plus the
ctor aggregate's `value` field removal** — the probe moves 3,962 → 5,243 (10j
the vtable names/types is the residue); the corpus holds 286/380.
Session 44 batch 15 (2026-10-10) — **`lower` items 10h and
10i(a/b/d) (the frame stores become the host's `IR::Member(frame, field)`
targets; the async ctor drops its zero-stores and frame-Name pointer flags and
passes the frame's `ptr[void]` cast to the resume call and the task aggregate)**
— verified at the probe level (the ctor's only residue is 10i(c), the param-copy
Names' `:pointer nil`); the corpus's first differences are unchanged (0/0/0 on
the subset, 286/380/51/0 overall) because 10i(c) and item 8A mask them.
Session 44 batch 14 (2026-10-10) — **`lower` item 10d (the async
ctor params carry the host's unset `:pointer nil`; `ir.Param.pointer` is now
`Option[bool]`), the synthetic types' `:module_name nil` rendering, and item
8C's first half (the refcounted `mt_async_alloc`/`mt_async_free` for every
frame/proc-env/event-wait-frame allocation, with the C backend emitting the
allocator)** — the probe's first difference moves 2,912 → 3,962; the subset
reads 0 flips / 0 new / 0 shallower and the corpus holds 286/380; the newly
exposed ctor-body shapes are recorded as 10i.
Session 44 batch 13 (2026-10-10) — **`lower` items 10f/10g (an
embedded await hoists into the host's `__mt_async_tmp_<N>` local from the `?`
operands, and a `let _ =` discard registers/stores the host's
`local_discard_<line>` field)** — 0 flips, 0 newly differing, 0 shallower,
**12 files' first difference deeper** (the `std/net` async family; clock's
frames now byte-identical); 10h (the frame store's `IR::Member` shape) recorded
as the newly exposed block.
Session 44 batch 12 (2026-10-10) — **the proc capture set is
reference-based (the host's `proc_capture_entries` walk) and the proc/binding
counters are program-scoped** (the host's per-`Lowering` counters; 10c's
frame-position insert included) — 0 flips, 0 newly differing, 0 shallower,
**68 files' first difference deeper** (`std/json.mt` 7,207 → 290,642,
`std/toml.mt` 12,598 → 336,009, `dap/server.mt` 64,382 → 651,011); the async
frames' next block is the embedded-await temp (10f) and the `let _ =` discard
field (10g).
Session 44 batch 11 (2026-10-10) — **`lower` Track 3 item 10b (the
async match bindings take the host's analysis-registered
`local_match_binding_<N>` frame fields — post-order, with the shared interleaved
counter — while the binding itself stays a plain C local)** — 0 flips, 0 newly
differing, 0 shallower, **22 files' first difference deeper**; the newly exposed
shapes are the frame's *position* among the synthetic structs (10c) and the async
ctor params' `:pointer nil` rendering (10d), both recorded in Track 3.
Session 44 batch 10 (2026-10-08) — **`lower` Track 3 item 10a (a
nested struct's C name carries its parents: `<mod>_Rectangle_Edge`)**, with the
field-context bucket's remaining shapes recorded (10b the async frame's extra
payload fields, the event-slot struct, the ref lifetime argument).
Session 44 batch 9 (2026-10-08) — **`lower` Track 3 item 9a (a
*const* array initializer's enum members fold to their values; the runtime case
keeps its member names)** — the corpus holds at 286 match while the compiler's
own sources advance hugely (`formatter/tidy.mt` 8,744 → 1,301,873).
Session 44 batch 8 (2026-10-08) — **`lower` Track 3 item 8b (the
synthetic `str_buffer[N]` structs leave the IR for a backend-only
`Program.str_buffer_structs`, the 3r precedent); 8a (the `const_ptr_of`
boundary cast) reverted with evidence (a blanket pointer-mismatch cast regressed
114 files)** — the corpus holds at 286 match, the 17-file str_buffer family 15
files deeper.
Session 44 batch 7 (2026-10-08) — **`lower` Track 3 item 6a (the
array-of-arrays element takes the checked index; the checked-index backend now
emits the host's element-pointer declarators + `&array[index]` bodies + decayed
calls, for scalars, arrays *and* function-pointer elements)** — the corpus
285 → 286 match, subset 262 → 263.
Session 44 batch 6 (2026-10-08) — **`lower` Track 3 items 6b
(the async `__frame`/`__resume` names) and 6c/6d (the match scrutinee's hoist
rule and the `return match` path); 6a (the array-of-arrays checked index)
deferred to a backend pass** — the corpus 277 → 285 match, subset 258 → 262.
Session 44 batch 5 (2026-10-08) — **`lower` Track 3 items 5a
(a scalar-shaped constant array element folds — the enum member's value lives
in the cast fold) and 5b (the `in`-mode and raw `external` call arguments take
the parameter's declared type)** — the corpus 273 → 277 match, subset
254 → 258.
Session 44 batch 4 (2026-10-08) — **`lower` Track 3 items 4a
(a compile-time constant array element inlines its aggregate) and 4b/4c (the
cstr-backed predicate recurses through `if`/`unsafe`)** — the corpus 265 → 273
match, subset 246 → 254.
Session 44 batch 3 (2026-10-08) — **`lower` Track 3 items 3fa
(the function-typed module variable's call carries a callee `IR::Name`), 3fb
(a `defer` body's statements replay flat) and 3fc (every foreign-argument
literal takes the parameter's type)** — the corpus 241 → 265 match, subset
222 → 246.
Session 44 batch 2 (2026-10-08) — **`lower` Track 3 items 3ag
(the foreign parameter resolves in its declaring module — the imported opaque
alias), 3ae re-applied on top of it (a bare `null` argument takes the
parameter's declared type) and 3wf (the dynamic format counter is env-scoped)**.
Session 44 batch 1 (2026-10-08) — **items 3af
(the unannotated decl's type is the host's *inference* of the initializer —
+12 flips, the corpus 216 → 228) and 3ac (a bare integer literal picks the
narrowest fitting width — deeper-only)**, plus **3ae implemented and reverted**
on the gap it exposed, now ranked item **3ag (imported opaque aliases)**.
Session 44 (2026-10-07) — **`lower` Track 3 items 3r, 3s, 3t,
3u, 3v, 3w, 3x, 3y, 3aa and 3ad** (the struct equality desugaring; the box2d
family's first difference).  The lowering keeps the host's `IR::Binary` on
struct values and registers the external (raw-module ABI) struct's field layout
in the new `Program.external_structs`; the C backend synthesizes the
`mt_struct_eq_<T>` helper from it exactly where the host does (the IR carries
no helper function) —
**30 files' first difference deeper (+21,667 to +21,677), 0 flips, 0 shallower,
0 newly differing, 0 lost**.  **3s** then folded a module-qualified constant in
an array-length position through the alias's module (the const's value
expression evaluated in the module that declares it, the lowering's
`try_const_eval_int` gaining the member arm) — `array[b2.Vec2,
b2.B2_MAX_POLYGON_VERTICES]` renders `:value 8` on the host and `:value 0`
before — **the same 30 files' first difference deeper again, 0
flips/shallower/newly differing/lost**.  **3t** typed the dyn vtable member from
the interface declaration when the generated `mt_vtable_<Iface>` struct is not
in this module's lowering (`dyn_vtable_method_fn_type`'s interface-driven
fallback, the host's `dyn_vtable_struct_type`) — **the full corpus goes 131 →
132 match** (`projects/stress/src/engine/interfaces.mt` flips), the same 30
files deeper again (+1,925); it also fixes a *runtime* divergence (the pre-3t
self binary aborted `array index out of bounds` where the host and the post-3t
self run).  **3u** then qualified *before* deepening in the `out`/`inout`
foreign-argument boundary (the `in` branch's order) so the std.c pairing
`deep_alias_target` resolves exists — **8 flips** (`examples/box2d/common.mt`,
`compound_shapes`, `confined`, `human`, `kinematic`, `rounded`,
`tiny_pyramid`, `examples/raylib/core/3d_camera_free.mt`; the subset 122 → 130
match) with 42 files' first difference deeper (23 box2d, 14 box3d, 5 raylib;
+181 … +252,788), 0 shallower/newly differing/lost.  **3v** then gave a plain
sync method with an array-storing receiver type the host's borrow convention
(`pointer_lowered_method_receiver?` — `this` as `ptr[T]`, auto-borrow at the
call sites, the dyn wrappers included) — **3 flips** (`examples/box2d/contact.mt`,
`examples/box2d/sensor_funnel.mt`, `std/noise.mt`) with 15 files deeper
(+64 … +76,462), 0 shallower/newly differing/lost; the full corpus reads
**143 match / 523 differ**.  **3w** then ported the host's dynamic
format-string protocol — the build hoists into the statement stream with the
destination-named result temp (`__fmt_<name>`, `_cap`/`_off`, `_2` repeats),
the parts' temps first and the capacity accumulations after, casts only where
the types differ, and the `mt_format_str_release` cleanup after the statement
(dropped when the target owns the buffer) — **15 flips** (the whole box2d
family) with 30 files deeper (15 raylib, 11 sdl3, 3 box2d, 1 std), 0
shallower/newly differing/lost; the full corpus reads **158 match / 508
differ**.  **3x** then modeled the host's cstr-backed bindings: a `str as cstr`
foreign argument whose value is a string-literal local, a cstr-backed local or
a dynamic format string's temp passes its `data` pointer directly instead of
allocating a `mt_foreign_str_to_cstr_temp` copy — **18 flips** (the raylib core
family and `std/raylib/debug_console.mt`), 1 file deeper, 0
shallower/newly differing/lost; the full corpus reads **176 match / 490
differ**.  **3y** then made an `if` condition a *prepared* position: a
statement-lowered foreign call in a condition materializes into
`__mt_foreign_result_N` with its cleanups before the `IfStmt` (the `hm_return`
shape), and an `else if` chain's setup precedes the nested `IfStmt` inside the
else body — **34 flips** (the raylib audio/models/textures families) with 66
files deeper, 0 shallower/newly differing/lost; the full corpus reads **210
match / 456 differ**.  **3aa** then set the monomorphized body's
`current_fn_return_type` to the *substituted* return type, so `return null` in
`alloc[T](…) -> own[T]?` types the literal `Nullable(own[int])` like the host
(not `void`) — **3 flips** (`std/bitset.mt`, `std/bytes.mt`, `std/mem/pool.mt`)
with **97 files' first difference deeper** (39 `test`, 30 `std`, 17 sdl3, 7
raylib, +6,370 … +237,261), 0 shallower/newly differing/lost; the full corpus
reads **213 match / 453 differ**.  **3ad** then grouped a method's instances
under the module that *declares* the extending block (`SpecInfo.owner_module =
gm.owner_module`), so a cross-module call site's registration (`Vec.create[String]`
written in `std.string`) no longer scatters the specs into the caller's
leftovers — **3 flips** (`examples/raylib/core/random_sequence.mt`,
`std/graph.mt`, `projects/mtc/src/mtc/lsp/utils.mt`) with **122 files' first
difference deeper** (36 `test`, 24 `std`, 17 sdl3, 4 raylib), 0
shallower/newly differing/lost; the full corpus reads **216 match / 450
differ**.  The next leaders are a local declaration's nullable-typed operand
(~51 — the host keeps the declared `ptr[ubyte]` where the self carries the
`Nullable(ptr[ubyte])` read type), a foreign argument's `null` literal (~34),
the `4294967295` literal (~16) and the `mt_str_buffer_*` decls (~15).
Session 43 had landed **`lower` Track 3 items 3k, 3j, 3l, 3m, 3o, 3i-b, 3g and
3q**.
3k, the refinement record's post-statement positions: a guard inside a compound
statement — the `std/mem/heap.mt` `contains` shape — answered `reinterpret`'s
source type with the storage `Nullable` where the host carries the refined
pointer; the record's post-statement snapshot now sits at the statement's end
with the host's start replay, skipping cleared transitions, and the lookup
keeps the host's last-record rule — **209 files' first difference deeper
(+30,767), 0 shallower/new/lost**.  3j, the simple-path call's raw return type:
`= c.getenv` types the emitted call with the raw declaration's `ptr[char]`, not
the wrapper's `cstr?` — **100 files deeper, 0 shallower/new/lost**.  3l, the
`read(x) =` target's literal type: the value literal takes the target's type
(`read(header - 1) = 0` → `ptr_uint`) — **26 flips** (the heap-importing
`std/**` family) and `std/mem/heap.mt` byte-identical.  3m, the call-argument
and variant-field literals: plain/method call arguments and (non-generic)
variant arm field values take the parameter's/field's type, and a bare float
literal operand is re-typed against a float peer instead of being cast up
(truncating) — **2 more flips**, taking the sweep **55/611 → 83/583**; 3o, the
prelude generic variant's arm field type: `Option[ptr_uint].some(value = 0)`
now resolves `value` to the instance's `ptr_uint` (the arm info is registered
on demand) — **80 files deeper**; 3i-b, the `break` half of the loop-flow model:
a plain `while`'s `break` is now a native `IR::BreakStmt` (with the
switch-backed match arms invalidated) — **8 flips** (`std/str.mt`
byte-identical), taking the sweep **83/583 → 91/575**; 3g, the flags/enum type
rendering: the dumper classifies raw-module and flags nominals — **35 flips**
(the raylib core family), **91/575 → 126/540** — and body_move now
advances to the `const_ptr[T]` boundary type's element loss (3q); 3q, the
foreign address-of's boundary type: `in` addresses are `const_ptr[T]` and
`out`/`inout` `ptr[slot]` (the boundary pointer, not a `ptr[void]` placeholder),
with the element deepened through the wrapper's std.c alias — **5 flips** (the
raylib shapes family), **126/540 → 131/535**.  The LSP reads its documented
entries.
Session 42 had landed **the `sexpr_parity` host-output
cache** (a tools change: `--host-cache` reuses the host's outputs per file /
resolved import-closure digest, the self always runs live; the 717-file lower
sweep reads 55/611/51/0 cold and warm, warm in 58 s vs 4m04s).
Session 41 had landed **`lower` Track 3: the
statement-position hoisting channel** (the census's largest bucket, the
foreign-call shape): a statement-lowered foreign call (a `str as cstr` argument
needs a `mt_foreign_str_to_cstr_temp`) hoists its setup into the statement
stream instead of an `IR::StmtExpr`, mirroring the host's
`prepare_expression_with_cleanups` split (setup before the statement, cleanups
after it).  A `LowerCtx` window (`hoist_mode`/`hoist_stmts`/`hoist_cleanups`/
`hoist_root_ep`) collects both halves with three host shapes: `hm_return` (the
call materializes into `__mt_foreign_result_N` and the frees follow it before
the return), `hm_value` (the call is the local/assignment value and the frees
are cleanups after the statement) and `hm_discard` (an expression statement's
root call is emitted by the foreign lowering itself with
`line 0`/`path ""` — nil in the dump, the host's `discard_result`).  Lazy
regions (if branches, `and`/`or` right operands, proc bodies, `detach`, format
strings) suspend the window and keep the inline StmtExpr; the temp prefixes now
match the host (`foreign_arg`, `foreign_result`).  The sweep counts and *set*
are unchanged — **44 match / 622 differ / 51 host-rejected / 0 self-rejected of
717** as of the hoisting and items 3d/3e (max delta +118,892: the raylib family
205, box2d 29, box3d 14, `std/raylib.mt` and 4 more std files), and **item 3f
flips 11 files to byte-identical — `std/raylib.mt`, `std/raygui.mt` and 9
raylib examples — taking the sweep to 55 match / 611 differ**, with the raylib
family first-differing at ~92% of its dump on `CAMERA_PERSPECTIVE`'s
flags/struct type (the next ranked item, 3g).  The first items of the session:
a statement-lowered foreign call hoists its setup into the statement stream
instead of an `IR::StmtExpr` (the host's `hm_return`/`hm_value`/`hm_discard`
shapes, `foreign_arg`/`foreign_result` temp names); an already-pointer
`inout`/`out` argument (a `this` receiver, `*p`) is cast to the boundary's
pointer type, not addressed again (the host's `lower_addr_expression`), and
every statement-position foreign call is emitted by the lowering with nil
line/path (the corrected `hm_discard` rule); and a referenced mapping parameter
is temporary-bound only where the host binds one — every other argument value
is substituted into the mapping through `mapping_replacements` — and an
embedded mapping call is typed with the raw C function's declared return type
resolved in the mapping's owner module (`ForeignInfo.owner_module`).  **Item 3c
landed last**: the guard-bound nullable pointer arithmetic keeps the analyzer's
refined pointer on the binary (the lowering's pointer-arithmetic branch had
overwritten it with the storage `Nullable`; session 40's note pointed at the
binding read, which really is `Nullable` on both compilers) — 255 files +1287,
set unchanged; **item 3i's continue half** then made a plain `while` body's
`continue` native (`IR::ContinueStmt`, no goto label) — the same 255 files +222
— leaving 3k (the guard-bound `reinterpret` source type at the next node) as the
next item; 3i's `break` half still needs the host's `switch_loop_target`
invalidation.  All seven
items are locked by
`test_foreign_call_setup_hoists_at_statement_position`,
`test_pointer_receiver_foreign_argument_is_cast_not_addressed`,
`test_mapping_arguments_are_substituted_not_tempped`,
`test_mapping_external_call_takes_the_declared_return_type`,
`test_guard_bound_nullable_pointer_arithmetic_is_unwrapped` and
`test_assignment_literals_take_the_target_type`, with the fixtures
byte-identical to the host.  Session 40 had
landed **`lower` Track 3 item 2, a global initialized from an imported
constant** (the box2d/box3d families' first difference): the `decl_var` arm now
folds a compile-time-known initializer
through `try_const_typed_value_ir` + `coerce_const_value` before falling back to
`lower_expr`, mirroring the host's `lower_static_storage_initializer`
(`compile_time_const_value` → `lower_compile_time_literal`).  The sweep stayed at
**43 match / 623 differ / 51 host-rejected / 0 self-rejected of 717** with **no
newly differing file** and **23 files' first difference moved deeper** (0
shallower; the box2d/box3d families, two raylib/sdl3 examples and
`test/mt/signal_test.mt`), locked by
`test_global_initialized_from_imported_const`.  **Item 2b landed in the same
session**: a bare function name used as a value is typed with the function
binding's own type (declared name + variadic flag) in `fallback_type_raw` — the
sweep again unchanged in set (43/623/51/0) with **29 more files' first
difference deeper**.  **Item 2c landed in the same session**: tuple value
structs (`mt_tuple_*`) are registered at tuple literals and at const/global
storage types, named and emitted like the host's `ensure_tuple_struct` (the
shared `naming.tuple_type_c_name` + the qualified `Tuple#to_s` renderer, and
the backend now filters IR-declared tuples out of its own collection so each is
emitted once, from the IR) — the sweep set unchanged again with **6 files'
first difference deeper** (`box3d/common.mt`, the two `box2d` files,
`raw_scanner.mt`, `std/color.mt`, `test/mt/color_test.mt`), locked by
`test_tuple_literal_registers_value_struct` and
`test_storage_tuple_registers_value_struct`; the emitted C for a tuple now
matches the host's byte-for-byte.  **Item 2d landed in the same session**:
every synthetic value struct — tuple `mt_tuple_*`, proc envs and capture caps,
async frames, dyn vtables, the event runtime structs and str buffers — now
joins one creation-ordered `pending_synthetic_structs` list drained after the
module declarations, the host's single `@artifacts.synthetic_structs` shape;
the sweep set is unchanged with **42 files' first difference deeper** (the
whole box2d/box3d families at +13,164, the `std/net/**` async family,
`async_stress_test`/`async_network_lobby`, stress/tetris, the DAP protocol
modules).  **Item 2e(a) landed in the same session**: an anonymous tuple's
type renders the host's default `_0..` field names, and the folded-tuple
aggregate names its fields the same way — `std/color.mt` flips to
byte-identical (**43 → 44 match / 622 differ**) and `test/mt/color_test.mt`
moves +46,643.  **Item 2e(b) landed in the same session**: a tuple-typed
constant with an expression-list value lowers to the host's `IR::ArrayLiteral`
(every element literal typed `int` — the host's fallback element type, since
`Types::Tuple` has no `arguments`) — corpus-neutral (the sweep set is
unchanged; the `use.mt`/`mixuse.mt` fixtures are byte-identical).  **Item 3 is
verified closed** (F2's continuation refinement had already fixed the
refined-operand difference); its files first-differed on the **`reinterpret`
lowering** — **item 3b landed in the same session**: `reinterpret[T](x)`
always lowers to `IR::ReinterpretExpr` with the flow-refined source type
(the nullability pre-pass now runs for method bodies, and `flow_type_at`
moved to the analyzer and scans the cursor's body span so the two-pass check
order can't corrupt it) — **169 files' first difference deeper** with the
set unchanged at 44/622; those files' next difference is **3c** (a
pointer-like guard binding's read carries the storage type where the host's
carries the narrowed success type), recorded in Track 3.  **Item 6 landed in
the same session**: raw-binding include directives follow the host's
analysis-cache insertion order — a DFS post-order from the root with each
module's imports visited in declaration order — instead of the canonical
module order; **91 files' first difference deeper** (up to +136,782), set
unchanged at 44/622.  The next ranked item was the **hoisting/foreign-call
shape** (~222 files) — **landed in session 41**.  **Item 4 landed in the same session**: struct-declared
events become `__event_<name>` fields typed `Types::Event`, member accesses
route through the hidden name, and the backend gained the `ty_event` topo
dependency — `examples/event_stress_test.mt` +737, its (and the `ev.mt`
fixture's) next first difference being **4b**: the owner-qualified event
runtime naming (`mt_event_<module>_<owner>_<name>[_<payload>]_<capacity>`),
where the self still keys its event runtimes by bare name.  Session
39 had landed **`lower` Track 3 item 1: opaque
declarations** (the first difference for all 34 sdl3 files): declared names,
the host's `forward_declarable` rule, forward-declaration emission and the
backing-name `c_type`.  The sweep went **39 → 43 match / 627 → 623 differ**
with no newly differing file — `std/glfw.mt`, `std/gl.mt`, `std/box3d.mt` and
`std/sdl3.mt` are byte-identical.  Session 38 had landed **C4: the LSP's
per-parse ownership** — the parser/lexer scratch release, the `heap.Region`
allocator, per-entry parse/analysis regions, the request-boundary quarantine
and the residue the valgrind stacks exposed; the soak is now **68 KB/cycle raw
(19.9 least-squares) at `--cycles 200`**, level ~33 MB (was 656 MB), `steady`
~0, valgrind 0 errors.  Session 37 had routed the per-request parse
sites through the shared caches, cutting the full-cycle slope
**11.4 → 3.96 MB/cycle** (the gate read 3.98 at `--cycles 200`); the residual is
the per-edit loader parse+analysis leak (per-parse ownership is the remaining
C4 blocker, documented in Track 7).  Session 36 had closed the canonical
audit's four references warm-coverage rows (**10 → 6 differing entries**,
closed 4, added 0); session 35 closed **`milkTea/debugInfo` byte-parity** (the
Facts and Bindings sections, the cached-AST `SourceFile` header and the
harness's `object_id` normalization — the harness's fifth documented entry,
4 remain); session 34 (2026-10-04) closed **DAP Track 5**.  The
self-host's `mtc dap` is at parity with the Ruby host on `tools/dap_smoke.rb`'s
whole matrix: the process backend (now starting the program at
`configurationDone`, `terminated`→`exited` with the real exit code) and the
**lldb-dap bridge** (the VS Code extension's default) against both the
embedded fake adapter and a real `/usr/bin/lldb-dap`, reverse requests
(`runInTerminal`) and the debug-map rewriters included.  Landed across six
commits: `0d1dacab` the debug-map sidecar from the self build
(`projects/mtc/src/mtc/debug_map.mt` + `debug_map_test.mt`); `02c2c335`
build-on-launch (`/proc/self/exe build … --profile debug
--no-debug-guards` into a temp dir, with the binary cache carrying the
sidecar — the host loses its map on a program-cache hit); `9d3b27db` the
unified libuv loop (a `Framer` over raw fd reads, poll handle + 100 ms timer,
callbacks fill / dispatch between turns; spawn moved to `configurationDone`;
real terminal order); `c3e7ce99` the bridge transport + policy (deferred
initialize with merged capabilities, launch/attach forwarding, config gating,
terminate→disconnect fallback, `--adapter-path`); `66d0b555` the frame/
variable/expression rewrites, breakpoint sync + the host's `breakpoint
changed` events, pause diagnostics and the `modules` fallback; and this
commit — the real-lldb smoke section, the extension's argv-order fix and the
docs.  **Measured: `dap_smoke` zero differing rows except one documented
self-better row** (`lldb-real frame0 name`: self `add`, host `main_add` —
the host's cache-hit map loss); valgrind 0 errors on both backends; the live
VS Code F5 is the one remaining manual check.  Gates: bootstrap fixed point
(18 files / 618 tests / 0 failed), dap smoke.

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
| LSP feature parity / audit residue | the program's LSP track + §0k; `docs/lsp-design.md` (esp. §8 differences), `docs/lsp-performance.md` | `tools/lsp_parity.rb` (`record --server host\|self`, `compare`, `--stress`), `tools/lsp_project_audit.rb --workspace DIR` (per-file, every position, both servers live; add `--canonical` to pin the warm-up history when verifying), `tools/lsp_soak.rb` (RSS slope), plus valgrind and the headless-Neovim smoke for behavior changes |
| Linter corpus residue | the program's linter track + §0k's sessions 19–23 | `ruby tools/lint_parity.rb -q` (609 files; `--host-cache FILE` makes re-runs ~20 s), `rake "parity:scoreboard"` |
| `lower` dump parity | the program's `lower` track, §0j's records, `docs/language-design.md` for semantics | `ruby tools/sexpr_parity.rb lower -j 16 --host-cache tmp/sexpr-host-cache` (~1 min warm / ~4 min cold; quote the set) |
| Example / vendored-family builds (no known failures since 2026-09-27) | §0j's 2026-09-27 section | the 15 top-level examples, `find examples/sdl3 -name '*.mt'`, a raylib sample |
| CLI behavior parity | the program's CLI track, `tools/cli_parity.rb` (`--help`) | `rake "cli:parity"` |
| Formatter modes (`:tidy`, `:preserve`) | §7, `docs/lsp-design.md` | `ruby tools/format_parity.rb all -j 16` (all modes must stay byte-identical — 712/712, file counts drift) |
| DAP | the program's DAP track, `docs/dap-design.md` (gaps in §10) | `ruby tools/dap_smoke.rb [--server host\|self\|both] [--json OUT]` — runs a session on both adapters and prints a per-request diff |
| Bootstrap / release | `docs/bootstrap-design.md` | `tools/bootstrap.sh -j 16` (full); `--fast` = fixed point only, no self-test rebuild/suite |
| In-language test suite | `docs/testing.md` | `build/stage2/mtc test test/mt -I .` |

**Start by checking what your task can move, not by replaying the matrix.**  The
**Ledger** below holds the last verified numbers per gate; a session only
re-measures the classes its change touches, and only when the tree moved (or a
number looks surprising).  Iterate on the dev compiler
(`ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev`, ~50 s;
`tmp/mtc-dev test projects/mtc -I .`) with a *focused* meter — a single file's
host-vs-self lint/check diff, `tmp/diag_probe.rb`, `ruby tools/lint_parity.rb -q
<paths>`, `ruby tools/sexpr_parity.rb lex|parse -q` — and save the wide sweeps
for the commit.  The sexpr sweeps take `--host-cache tmp/sexpr-host-cache`
(session 42): the host's outputs are reused per (file, resolved import closure)
digest and only the self re-runs live — the repo-wide `lower` sweep drops from
~4 min to ~1 min warm.

**Once per commit, on frozen sources**, run the tier-2 proofs: `tools/bootstrap.sh
-j 16` (fixed point + compiler self-test — several changes that looked correct at
the CLI level broke the compiler's own bootstrap) plus the sweep that covers the
area.  `tools/bootstrap.sh -j 16 --fast` is the per-batch form: it implies
`--keep-c` (skipping the two re-emit rebuilds the fixed-point check used to do),
drops the `stage2-self` rebuild (the stage-3 build already *is* stage2 compiling
itself) and the in-script suite — same `stage2.c == stage3.c` comparison, ~10 min
less.  `tools/gates.sh` picks the set for you:

```sh
tools/gates.sh                 # list the gates for the working-tree diff
tools/gates.sh --areas linter  # or name the areas
tools/gates.sh --run           # execute them (logs under tmp/gates/)
```

**Batch the ceremony, not the care.**  The per-fix loop is tier 1 only: the dev
build (~50 s), the focused sweep (the `lower` subset re-runs in seconds warm) and
`tmp/mtc-dev test projects/mtc -I .` (now ~40 s — `gates_dev_tests` runs each of
the 19 test files as its own process, since the self's `test` takes only a
directory and does not parse `--jobs`).  Land 3–5 fixes per commit, then run the
tier-2 set once on the frozen tree.  A batch of five fixes costs ~1 h end to end
instead of five ~45-min cycles, and every fix is still verified against the host
before the next one starts.

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
`timeout 10 bash -c 'ulimit -v 20000000; …'`; **check the self-test suite's file
count, not just `0 failed`** — `mtc test` silently *skips* a test file that does
not lex/parse (`18 test file(s), 0 failed` with a broken
`projects/mtc/test/*.mt`; the full-corpus sweep's `hostfail` count catches the
same mistake one file late); no hacks — fix root causes; sync
this file's records + ledger in the same commit as the code change; never run
`mtc test` while a gate runs — the suite synthesizes `__mt_test_runner_*.mt`
into `projects/mtc/test/`, so two concurrent runs discover each other's
runners (`duplicate value main`), and a stray runner left by a killed run
poisons the next bootstrap.

### Phase order and current position

0. **Hard build parity** — **complete (2026-09-27)**: the self-host builds every
   example and test the host builds (15/15 language examples, 34/34 `examples/sdl3`,
   a 40-file raylib sample, `test/mt` 60/60 with 0 failures).  Six root causes are
   recorded in §0j's 2026-09-27 section; regressions should show up as a build
   failure in those sweeps.
1. **`lower` dump parity** — session-45 batch-14 measurement (2026-11-03):
   **479 match / 187 differ / 51 host-rejected / 0 self-rejected of 717 files**
   (the count drifts with the tree's own sources and the tmp fixtures; quote the
   set).  The ranked items are the program's `lower` track; the current leaders
   are the remaining foreign-call cstr-temp ordering and nested `foreign_expr`
   shapes (the three-pass protocol landed in batch 14), the array/const literal
   shape (57), the nullable field type drop (`opaque_backing_names`), the `?`
   propagation's statement/return shape, the late-instance/proc **placement**
   residue (the host's `lower_functions` fixpoint — the json/toml proc first,
   ~20), 10e/4b (the event runtime names/order), the async frame field's nullable
   drop (~10) and a statement's line/path shape (~13), then the tail.
   Item 8a, the foreign-boundary projections, the guard/propagation family, the
   loop-exit cleanup shape, the post-guard assignment target, the explicit
   format sink, the contextual numeric casts, the prefix-cast constant fold, the
   `and`/`or` result temp, the variadic cstr projection and the foreign-call
   component protocol are closed.
2. **CLI behavior parity** — **24 match / 37 differ / 0 pending** of 61 harness
   cases (session 22); the differ on message text, output channel and argument
   precedence.  The unported subsystems are the program's CLI track.
3. **LSP feature parity** — **the active phase**.  The harness is at 30/30
   capability keys + its 4 documented differing entries; the project audit is at
   **4 stable differing entries + the host's first-file `documentSymbol` race**
   (completion **2**: the host's synthesized `ref` lifetime and
   the host giving up on a `map_error` arm binding — the two byte-vs-character
   position entries closed with the request-boundary conversion; hover
   `type quat`; documentHighlight `lb@704:67`).  The completion class's
   *unintended* entries are now 0; session 29 closed the **per-module
   `ModuleCache`** (5.0 ms median per edit, 54.3 before) and made imported
   modules honor open editor buffers.  Session 35 closed the **`debugInfo`**
   Facts/Bindings remainder (the dump is byte-equal on the fixture; the harness
   normalizes Ruby object ids), session 36 closed the canonical audit's four
   `references` warm-coverage rows (**10 → 6 differing entries**, closed 4,
   added 0), and session 37 routed every per-request parse through the shared
   caches (**soak 11.4 → 3.96 MB/cycle**).  The remaining LSP work is the
   per-parse ownership residual (C4's blocker: the per-edit parse+analysis
   leak), then the optional `ref`-lifetime modeling.  Recovery parity
   holds, the stress corpus runs without a crash or hang, and a real VS Code
   session runs clean under valgrind.
4. **DAP** — **DONE (session 34, 2026-10-04)**: the process backend and the
   lldb-dap bridge (the VS Code extension's default) are at parity on
   `tools/dap_smoke.rb`'s whole matrix — build-on-launch, the debug-map
   rewrites, breakpoint sync, pause diagnostics, reverse requests and a real
   `/usr/bin/lldb-dap` session included.  The live VS Code F5 check is the one
   remaining manual step (`docs/dap-design.md` §10).

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
  per-module cache — **met 2026-10-04: 5.0 ms median, session 29**; valgrind
  clean (0 errors on the harness drive).
- **Linter**: per-rule counts/messages/severities/positions equal the host on
  `language_baseline.mt`, `memory_stress_test.mt` **and** the whole-corpus sweep
  (613 files at the session-33 audit), and every host rule/fix exists (two rules
  and one fix are unported — Track 2's session-33 audit note).
- **DAP**: a real VS Code session debugs a `.mt` program end-to-end with the
  default `lldb-dap` backend (breakpoints, stepping, evaluate; frames/locals
  shown as Milk Tea names via the debug map); process backend unchanged;
  `dap_smoke` green on both.
- **Bindings/bindgen**: `mtc imported-bindings --all --check` 28/28 verified (or
  each residual delta justified as cosmetic with evidence); bindgen output
  reproducible for the repo's bindings.
- **Formatter**: all modes byte-identical (712/712 at the 2026-10-04 session-33
  audit; the count drifts with the tree's own sources and tmp fixtures).

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

`tools/lint_parity.rb -q` over `std examples projects/mtc/src`: 616 files,
**495 agree / 121 differ** (session 40 re-measure, 2026-10-06; the per-rule
deltas below are the session-33 classification and are unchanged in kind — the
changed files carry them; the corpus and agree counts drift with the tree's own
sources, so quote the set).
Closed so far: `redundant-unsafe` 807 → 0, `owning-release-leak` 602/286 → 0/0,
`owning-release-double` 0/12 → 0/0, `prefer-inline-if` 213 → 0,
`prefer-struct-with` 93/0 → 0/0, `prefer-conditional-expression` 25 → 0.
Remaining ranked deltas (self-extra / host-only; re-measured 2026-10-04
session 33):
`redundant-cast` 74/25, `prefer-try` 66/39, `prefer-let` 60/141,
`borrow-and-mutate` 29/0, `shadow` 20/0, `prefer-own-ptr` 16/45,
`constant-condition` 11/1, `prefer-or-pattern` 10/4, `loop-single-iteration`
9/2, `unreachable-code` 4/0, `prefer-var-else` 2/0.  All
differences are pre-existing (the pre-change binary's output is identical on
them); quote *sets*, not just counts.  Tool: `tools/lint_parity.rb` with
`--host-cache FILE` (warm fill ~4 min, then ~20 s per full run).

**Audit (session 33): two host rules and one host fix are absent.**  The host's
`KNOWN_RULE_CODES` (`linter.rb:21-64`) has **43** entries; the self's linter
emits **41** — `directional-ffi-arg` (`linter/rules.rb:513-531`) and
`platform-api-drift` (`linter/imports_platform.rb:32-62`, sibling
platform-variant API-surface drift) are not ported.  The host's
`AUTO_FIXABLE_RULE_CODES` has **13** entries; the self's `fixable_codes()` has
**12** (`redundant-unsafe` has no fix generator).  Neither rule's diagnostics
appear in the sweep's per-rule deltas, so a corpus file that triggers them
would be the first visible difference.

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
- **Member-assignment immutability** (found in session 28): the host's
  `infer_lvalue_receiver` rejects `x.field = ...` through an immutable receiver
  (`cannot assign through immutable <name>`) and the same for `this.field = ...`
  in a non-editable method (`cannot assign through immutable this`,
  `expressions.rb:76` and `function_binding.rb:594-605`); the self has no such
  check at all, so `check` accepts sources the host rejects — and because the
  host's `--fix` validation (`validated_fixed_source`) sees those errors, the
  host *refuses* fix batches the self applies (repro: an
  `extending Counter:` with a second block plus a `this.value = 0` method; the
  host leaves the file untouched, the self inlines two blocks).  Matching the
  host means porting the receiver-implicitness ladder (identifier/`this`/
  index chains, mutable pointers, ref/str views) *and* the generic-method scan.
- **`prefer-let` and specialized editable calls** (found in session 28,
  pre-existing): `examples/reflection_advanced.mt`'s `var r` must stay `var`
  because `r.unpack[CompactHeader]()` is an editable method; the host's
  validation rejects the rewritten source, the self rewrites it.  The self's
  editable-site recording misses the specialized editable call.
- **The `--fix` unresolved-import guard** (found in session 28, pre-existing):
  the host's `fix_source_single_pass` refuses to fix *any* rule when an import
  did not resolve ("facts are incomplete … leave such sources to the author");
  the self always proceeds, so on such files it applies fixes the host
  withholds (repro: `import alpha_mod as Option` where the module is not
  resolvable).  The self's fix engine has `options.unresolved_import_paths`
  but never consults it; the CLI lint path must fill it like `check` does.
- **The analyzer's reserved-name errors** (found in session 28): the host
  raises `function int uses reserved built-in type name int` (no linter
  phrasing) for module-level declarations and `local int uses reserved
  built-in type name int` for locals; the self checks only locals/params and
  with a different message (`local int shadows a reserved type name`), and its
  module-level functions/consts/vars/events have no sema check at all
  (`ensure_non_reserved_value_type_name!`/`ensure_non_reserved_name!`,
  `type_declaration.rb:322-862`, `function_binding.rb:217-227`).
- **Sema message type rendering and the return-mismatch position** (found in
  session 40 while probing tuple rendering): the host's `return type mismatch:
  expected X, got Y` renders types with its `to_s` — module-qualified,
  `expected std.vec.Vec[int], got int` — and reports the return site's position
  (`…/bad.mt:4:5`); the self renders the display form (`expected Vec[int],
  got int`) and reports `0:0`.  Repro: `return 1` from a function declared
  `-> vec.Vec[int]`.  `cannot assign to immutable x` is byte-equal (`:10:7`),
  so the gap is this site's rendering/position, not the diagnostic pipeline.
  The host-flavored qualified renderer is the same machinery item 2c's tuple
  decl name needs.

Records: §0k sessions 19–23; session 28.

### Track 3 — Compiler `lower` dump parity

Work in the ranked order below; after **each** item re-run
`ruby tools/sexpr_parity.rb lower -q -j 16 --host-cache tmp/sexpr-host-cache`
and re-rank — session 42's host cache makes the repeat measurement cheap.  Current set:
**479 match / 187 differ / 51 host-rejected / 0 self-rejected of 717 files**
(session 45 batch-14 read, 2026-11-03; session 44's batches took it 216 → 286 —
the batch-19–21 proc stages kept the set while moving it (stage A/B moved 70
files deeper, stage C 2 files deeper, stage D moved the dumps closer) — and
session 45's fourteen batches took it 286 → 479; the count drifts with the
tree's own sources and the tmp fixtures — quote the set).

**Session 45's landed items (the re-ranking after them).**  Batch 14 ports the
**foreign-call component protocol** (`bind_foreign_mapping_arguments`'s three
passes: public-alias reuse/`foreign_arg_public`, value preparation, `foreign_arg`
temps), the **`prepare_foreign_in_argument` hoist** (a non-addressable `in`
operand gets a `foreign_in` temp before the boundary projection, on both the
mapping and simple paths), the **cstr assignment-metadata refresh** (a plain
`str` assignment clears a literal-backed local's cstr flag, so a later
`str as cstr` boundary copies), and the **nested foreign result
materialization** (`foreign_result` before the frees for a value-position nested
call; a statement-root call still stores directly) — 467 → 479 (+12), 0 new
differing files.  Batch 13 adds the
**variadic foreign `str` argument's cstr projection** (a foreign wrapper's
variadic slot has no declared parameter, but a `str` value still takes the
host's cstr rule: a string literal becomes a C string literal, a cstr-backed
value passes its `data` pointer in an `IR::Cast(cstr)`, anything else takes the
malloc temp — `text_format(c"%s", value)`; the `TextFormat`/`DrawText` family
is byte-identical) — 454 → 467 (+13), 0 regressions.  Batch 12 adds the
**prefix-cast constant fold** (`uint<-MoverBit` evaluates to 2 with the host's
width/signedness wrapping, so the box2d `categoryBits` field gets its outer
`ptr_uint` cast) and the **prepared `and`/`or` shape** (a setup-producing
operand hoists a `__mt_and_N`/`__mt_or_N` result local and guards the right
operand with `if result` / `if not result`; no setup keeps the plain binary) —
444 → 454 (+10), 0 regressions.  Batch 11 adds the
**contextual numeric compatibility** (a folded constant that fits the declared
type, int→char, the declared-float int→float arm — skipped for a foreign-call
initializer — and the external-numeric assignment pair; the struct aggregate
fields use the shared helper), the **synthetic function program tail** (proc
invoke/release/retain bodies and pfor/spawn workers follow every module's
functions, the host's `@artifacts.synthetic_functions`), and the **propagation
failure return's `line nil`/path set** (the success binding keeps its
line/path) — 420 → 443 (+23: contextual +7, synthetic tail +16), 0 regressions;
the compiler-source subset 49 → 63 match.  Batch 10 adds the **explicit format
sink** (3z: all three forms, the host's four-argument `mt_str_buffer_clear`,
`String.as_str`'s aggregate view and the custom-hook slice form), **deferred
local/assignment format releases** (the host's `local_defers`; a foreign temp
free stays immediate), the **non-owning return release + `__mt_return_value_N`**
(an owning `str` return drops it), the **assertion condition's prepared
setup**, the **signed literal's declared context type**, and **`String` sink
recognition by resolved linkage** — 414 → 420 (+6), 0 new differing files;
`test/mt/fmt_test.mt` is byte-identical.  (1) A
monomorphized call's literal argument takes the specialized parameter's type
(`lower_plain_call_spec`; `heap.must_alloc_zeroed[SleepState](1)`).  (2) The
async main's `wait` is the public `std.async.wait` instance, so the whole
delegation chain is emitted (content-complete; the late-instance *placement*
remains — see the wave residue below).  (3) A declaration's instances sort by
the host's rendered `type_arguments.map(&:to_s).join(",")` (the 3ad residue).
(4) An imported variant's arm-payload binding carries its declaring module
(`build_imported_variant_info`).  (5) `as_span()`'s decay is a plain
`IR::Index`.  (6) An assignment target takes the flow-refined visible type (the
host's `lower_assignment_target` rule), via `analyzer.flow_type_at_position` +
the active type substitution; the plain-target equality case keeps the binding's own type (the record can carry the same nominal without its module); list above is batch 1 only — batch 2 adds the assertion intrinsics, static-call literals, switch-arm continues, iterator-loop storage projection, pointer-intrinsic casts and function-reference type names.  Batch 4 adds: **item 8a** (the `in`/plain `as` argument takes `AddressOf(const_ptr[parameter.type])` and `foreign_identity_projection_expression`; the generic wrapper lowers under its inferred call-site substitution), **the tuple match expression's nested else-chain** (the wildcard arm innermost), **the unannotated local's foreign-wrapper return type** (`cstr?` while the call keeps `ptr[char]`), and **the guarded identifier's flow-refined visible type**.  Batch 5 adds the **guard local as a prepared position** (the initializer's temps hoist before the storage local; the storage type is the host's inference — the wrapper's declared return), the **`?` propagation's typed failure chain and return path**, and the **propagation success local** (a real `LocalDecl` initialized from the projection).  Batch 6 adds the **loop-exit defer flush** (a `break`/`continue` with loop-scoped defers emits the cleanup + label goto; `stats.zig`-style leaks in `linter/config.mt`).  Batch 7 adds the **equality-pattern guard's empty else** (a struct-pattern arm's `field = value` check emits the host's present `else_body ()`).  Batch 8 adds the **flow replay's bookkeeping** (a multi-line statement's post-state replay at its start is a view, not a transition — it must not advance `flow_recorded`, or the end-of-statement transition is suppressed and the lowering's greatest-position lookup resolves an out-of-scope branch refinement: `std/map.mt`'s `previous = node` after `if previous == null`), the **prepared match expression** (a zero-initialized `__mt_match_expr_<N>` result local plus its switch/if chain in the statement's setup, the host's `prepare_match_expression_for_inline_lowering`), the **`_` local's host declaration** (IR name `_`, linkage `__mt___N` via `let_else_storage_c_name`, the stored value), and the **conditional's expected/common type** (the host's `common_numeric_type`/`common_integer_type` with pointer-sized integers as fixed-width 64 and `ptr_int` signed, the expression-carrying `conditional_common_type` compatibility fallbacks, a `Context.expected_type_hint` set for a declared local / assignment target / return — cleared for tuple-literal elements — so `let n: uint = if p: uint<-x else: 0` is uint, and `expr_if`'s conditional type + literal-branch retyping; a signed literal `-128` is a literal expression for the harmonization).  Batch 9 adds the **foreign mapping's literal context** (a fixed mapping argument — `= c.SDL_RunApp(..., null)`'s null — takes the raw C parameter's declared type, `Nullable(ptr[void])`), the **compile-time constant range-for stop** (`is_numeric_const_expression`; the host's `compile_time_numeric_const_expression?`), the **lazy specialization's caller state** (a nested `String.as_str` specialization no longer clobbers the caller's `fmt_dest_name`/`fmt_counter`/`fmt_counter_visible`/`cstr_backed_names`; the body gets fresh maps), the **guard local's format destination** (its storage binding, allocated before the initializer's temps, is the block's `__fmt_<dest>`), and the **mixed-signedness integer promotion** (`uint` vs `int` → `long`, via the semantic common-integer port).  Measured: **286 → 414 match**, 0 regressions, verified by a before/after differing-set comparison (batch 4: +35, the raylib shader/audio family + 3 dap/inference flips; batch 5: +8 — `std/json.mt`, `std/env.mt`, `std/cookie.mt`, `std/uri.mt`, `examples/option_and_result_surface.mt` and 3 path-resolver/uri test files; batch 6: +1 — `projects/mtc/src/mtc/linter/config.mt`, with the leak fix; batch 7: +1 — `examples/integration_test.mt`; batch 8: +20, 0 new differing files — the flow replay 9, the conditional/expected-type cluster the rest; batch 9: +9, 0 new differing files).
Open residue: the remaining foreign-call cstr-temp ordering and nested
`foreign_expr` shapes (the three-pass protocol landed in batch 14; the residual
is where the host still hoists a temp the self inlines, or vice versa), the
array/const literal shape (57, `projects/mtc/src`), the nullable field type drop
(`opaque_backing_names`), the `?` propagation's statement/return shape, the
late-instance placement (`lower_functions`'s fixpoint) — **the creator-tracked
wave model was implemented and reverted**: it mispredicts because the Ruby
analyzer instantiates generic bodies per instance before lowering while the
self's analyzer checks declarations once (measured corpus 264 vs 302 at the
batch-1 state; 479 now) — the event runtime names (10e/4b), the async frame
field's nullable drop (~10) and a statement's line/path shape (~13).  The
**explicit format sink** (3z), the **contextual numeric casts**, the
**prefix-cast constant fold**, the **`and`/`or` result temp**, the
**variadic cstr projection** and the **foreign-call component protocol** are
closed (batches 10–14).

**First-difference census (session 43) — the track's re-ranking.**  Bucketing
the 585 differing files by their first difference (a throwaway classifier over
the sweep's own `host:`/`self:` context lines; treat the sizes as ±a few): the
session-40 census's categories are all landed — the foreign-call body shape, the
`reinterpret` lowering (3b), the include set/order (item 6) and the guard
binding's read type (3c, the last leader) — along with the four shapes session
41's hoisting exposed (3d, 3e, 3f and the `hm_discard` correction), which took
the sweep 44 → 55 match, and session 43's four items: **3k** (209 files'
first difference deeper by +30,767 in the `std examples test` subset), **3j**
(100 files deeper), **3l** (183 files deeper and **26 flips** — the
heap-importing `std/**` family) and **3m** (82 files deeper and **2 flips**;
its mono-path seam also forced the bare-float-literal operand retyping),
taking the sweep **55/611 → 83/583**; 3o, 3i-b, 3g and 3q continued
**83 → 131 match / 583 → 535 differ** in the same session; each
measured as a subset comparison with the identical corpus, 0 shallower, 0 newly
differing, 0 lost).  Session 44 landed **3r** (30 files' first difference deeper
by +21,667 to +21,677, 0 flips, 0 shallower/newly differing/lost on the same
subset), **3s** in the same session (the array-length literal: the lowering
folds a module-qualified constant through the alias's module, the const's value
expression evaluated where it is declared) — **the same 30 files deeper again**,
0 flips/shallower/newly differing/lost — **3t** (the dyn vtable member typed
from the interface declaration when the generated struct is not in this
module's lowering): **the full corpus 131 → 132 match**
(`projects/stress/src/engine/interfaces.mt` flips), 30 files deeper again, 0
shallower/newly differing/lost — and **3u** (the `out`/`inout` foreign boundary
qualifies before deepening, so the alias's std.c pairing exists): **8 flips**
(the box2d family + `examples/raylib/core/3d_camera_free.mt`), the subset
122 → 130 match, 42 files deeper again (+181 … +252,788), 0
shallower/newly differing/lost — **the full corpus 140 match / 526 differ** —
and **3v** (the array-storing receiver's borrow convention: `this` as `ptr[T]`,
auto-borrow at the call sites, the dyn wrappers included): **3 flips**
(`examples/box2d/contact.mt`, `sensor_funnel.mt`, `std/noise.mt`), 15 files
deeper again (+64 … +76,462), 0 shallower/newly differing/lost — **the full
corpus 143 match / 523 differ** — and **3w** (the dynamic format-string
protocol: the build hoists with the destination-named result temp, the parts'
temps first, casts only where the types differ, and the release cleanup after
the statement): **15 flips** (the box2d family — `body_move`, `body_type`,
`bridge`, `circle_stack`, `drop`, `explosion`, `falling_hinges`, `prismatic`,
`ragdoll`, `ray_cast`, `revolute`, `shape_cast`, `skinny_box`,
`vertical_stack`, `wheel`), 30 files deeper again (15 raylib, 11 sdl3, 3 box2d,
1 std), 0 shallower/newly differing/lost — **the full corpus 158 match / 508
differ** — and **3x** (the cstr-backed `str as cstr` argument: a
string-literal local, a cstr-backed local or a dynamic format string's temp
passes its `data` pointer directly instead of the `mt_foreign_str_to_cstr_temp`
copy): **18 flips** (the raylib core family and `std/raylib/debug_console.mt`),
1 file deeper, 0 shallower/newly differing/lost — **the full corpus 176 match /
490 differ** — and **3y** (the `if` condition as a prepared position: a
statement-lowered foreign call materializes into `__mt_foreign_result_N` with
its cleanups before the `IfStmt`; an `else if`'s setup precedes the nested
`IfStmt` in the else body): **34 flips** (the raylib audio/models/textures
families), 66 files deeper again, 0 shallower/newly differing/lost — **the full
corpus 210 match / 456 differ** — and **3aa** (the monomorphized body's
substituted `current_fn_return_type`, so `return null` takes
`Nullable(own[T])`): **3 flips**, 97 files deeper again, 0
shallower/newly differing/lost — **the full corpus 213 match / 453 differ** —
and **3ad** (the declaring-module grouping for monomorphized methods):
**3 flips**, 122 files deeper again, 0 shallower/newly differing/lost — **the
full corpus 216 match / 450 differ**.  The post-3ad census (session 44,
historical — several rows have since landed: 3af/3ac/3ae in batches 1–2, 8b in
batch 8, 9a in batch 9, 8A stages A–D in batches 19–21; the *current* leaders
are the paragraph after item 8 above):

| Files | First difference | Where |
| --- | --- | --- |
| ~51 | **a local declaration's nullable operand**: the host keeps the declared `ptr[ubyte]` where the self carries the `Nullable(ptr[ubyte])` read type (`let data_ptr: ptr[ubyte] = data`) | `examples/**`, `test/**` |
| ~34 | **3ae, a foreign argument's `null` literal**: the host types it `(Types::Nullable :base (Types::Primitive :name "cstr"))`, the self `void` (`LoadShader(null, …)`) | `examples/raylib/**` |
| ~16 | **3ac, an unsigned-boundary literal** typed `long` where the self types `int` (`4294967295` in a `ulong` bit op) | `examples/box3d/**`, `examples/box2d/**` |
| ~15 | **the `mt_str_buffer_*` decls** (no host counterpart — the 2d residual) | `examples/raylib/**`, `std/raylib/**` |
| ~13 | a statement's line/path shape (`:line nil :path …` vs `:line N :path nil`) | `test/**` |
| ~57 | an array/const literal element shape (host `IR::IntegerLiteral` where the self emits `IR::Name`; `projects/mtc/src/mtc/build.mt`'s first difference) | `projects/mtc/src/**` |
| ~21 | a struct field's member order (`IR::Field :name "key"` vs `:name "current"`; `projects/mtc/src/mtc/bindgen.mt`) | `projects/mtc/src/**` |
| ~7 | a const array's enum-member element: the host folds the member to its literal (`256`) where the self emits `(IR::Cast int (IR::Name "KEY_ESCAPE" …))` | `examples/raylib/**` |
| 2 | **3n, the async frame struct's name** (`std_net_recv_impl__frame` vs `std_net_recv_impl_frame`) | the two `examples/async_*` |

The foreign-call shape and the format-string shape share a root cause: the self
has no statement-hoisting channel for multi-step expressions and wraps them in
`StmtExpr` where the host hoists locals into the block
(`prepare_expression_with_cleanups`).  Session 41 landed the channel, the
foreign-call family, the pointer/mapping-substitution/call-typing rules and the
guard-region fix; the format-string hoist (with the host's cleanup placement) is
a follow-up on the same machinery.  **3k, 3j, 3l, 3m, 3o, 3i-b, 3g and 3q all
landed in session 43** (3l flipped 26 files — the heap-importing `std/**`
family — made `std/mem/heap.mt` byte-identical, 3m flipped 2 more and re-typed
bare float literals in binary operands, 3o resolved the prelude generic variant's
arm field type, 3i-b flipped 8 more — `std/str.mt` byte-identical — for the
native `break`, 3g flipped 35 (the raylib core family) by classifying raw-module
and flags nominals in the dumper and 3q flipped 5 more (the raylib shapes
family) by typing the foreign address-of with its boundary pointer and deepening
the wrapper alias; the sweep reads 55/611 → 131/535 with the diffs' *content*
advancing at each step).  **3r landed in session 44**: the lowering keeps the
host's `IR::Binary` on struct values and the C backend synthesizes the
`mt_struct_eq_<T>` helper from the layout the lowering registers in
`Program.external_structs` (the IR carries no helper function, as on the host) —
30 files deeper, 0 flips; **3s** followed in the same session (the array-length
fold — 30 deeper again) and **3t** (the dyn vtable member typed from the
interface declaration — the corpus's 131 → 132 flip, 30 deeper again) and **3u**
(the `out`/`inout` foreign boundary's alias deepening — 8 flips, 42 deeper
again, the corpus 143/523) and **3v** (the array-storing receiver's borrow
convention — 3 flips, 15 deeper again, the corpus 143/523) and **3w** (the
dynamic format-string protocol — 15 flips, 30 deeper again, the corpus 158/508)
and **3x** (the cstr-backed `str as cstr` argument — 18 flips, the corpus
176/490) and **3y** (the `if` condition's prepared shape — 34 flips, 66 deeper
again, the corpus 210/456) and **3aa** (the monomorphized null return — 3
flips, 97 deeper again, the corpus 213/453) and **3ad** (the declaring-module
grouping for monomorphized methods — 3 flips, 122 deeper again, the corpus
216/450).  The batches since landed 3af, 3ac, 3ae (on 3ag), 3wf, 3fa–3fc, 4a–4c,
5a/5b, 6a–6d, 8b, 9a, 10a, 10b, 10c, 10f, 10g, 10d, 10h, 10i(a–d), 10j/10k, 10l
(the async runtime shapes: the inline completion model, the resume's result
store, the release/set_waiter/cancel bodies, the Task member types, the async
`main`'s `___async_main` linkage — `tmp/probe_b13.mt` byte-identical,
`tmp/async_probe.mt` 23,882 → 178,016 and running identically on both
compilers), 8A stage A + B (the proc type representation: `Types::Proc` as the
value type, the host's `mt_proc_proc_*` struct names, the fn-pointer declarator
names, the fn-typed local callee — `tmp/proc_fn_probe.mt` byte-identical,
`tmp/proc_probe.mt` 731 → 2,963, 70 files deeper), 8A stage C (the proc literal's
IR shape: the inline env setup with the `__mt_proc_expr_N` naming, the
materialized literal local, the helper bodies' `env`/`__mt_proc_env_ptr`/
`__mt_capture_<name>` naming — `tmp/proc_probe.mt` 2,963 → 10,853,
`std/toml.mt` +105,556), 8A stage D (the contained-proc retain/release
lifecycle — every sync proc probe byte-identical, the dumps moving closer with
the set unchanged), 8C's first half and the
reference-based capture set + the program-scoped counters;
the current leaders (the batch-13 read) are the foreign-call argument/temp
materialization (`__mt_foreign_arg_N` ordering and the inline foreign-in /
mapping substitution), the array/const literal shape (57,
`projects/mtc/src`), the nullable field type drop (`opaque_backing_names`), the
`?` propagation's statement/return shape, the late-instance/proc **placement**
residue (~21; the synthetic tail landed in batch 11, the late instances
remain), 10e/4b (the event runtime names), the async frame field's nullable
drop (~10), a statement's line/path shape (~13), and the tail: 3n (the async
frame name), 3p (the unnamed variant-arm construction's missing sema check — a
pre-existing abort), the nested `foreign_expr` materialization, then items 7–9
— file by file.  The explicit format sink (3z), the contextual numeric casts,
the prefix-cast constant fold, the `and`/`or` result temp and the variadic cstr
projection landed in batches 10–13; `fmt_test.mt` is byte-identical.

1. **Opaque declarations** — **DONE (session 39, 2026-10-05)**.  `collect_opaque_decls`
   keeps the declared name, resolves the backing per `opaque_c_type_name`, sets
   `forward_declarable` by the host rule and skips raw modules by kind;
   `emit_opaque_forward_decls` emits `typedef struct <linkage> <linkage>;` deduped by
   linkage; `c_type` renders the backing name through `opaque_backing_names`.  The sweep
   went 39 → 43 match / 627 → 623 differ with no newly differing file; the sdl3 family's
   first difference is now the format-string lowering shape (host-hoisted `__mt_fmt_part_N`
   locals vs the self's `StmtExpr` wrapper) or the null-literal type (`Types::Nullable` vs
   `void`) — both ranked below.
1b. **Null-literal context typing** — **DONE (session 39)**.  Bare `null` initializers and
   field values take the context type (`null_literal_to_context_type` at globals, locals,
   struct/generic-struct fields, array elements and const-folded fields; the locals/field
   nullable wraps' `NullLiteral → ZeroInit` special cases are gone, and the backend renders
   a nullable-typed `NullLiteral` as `(mt_opt_X){0}`).  Counts unchanged (43/623) but 296
   files' first difference moved deeper; locked by `test_null_literal_takes_context_type`.
2. **A global initialized from an imported constant** (item 13; `box3d/ragdoll` +
   `box_stack`'s first difference) — **DONE (session 40, 2026-10-06)**.  The
   `decl_var` arm folds the initializer through `try_const_typed_value_ir`
   (`lowering.mt:18567`, which falls back to `try_const_value_ir`, `:18038`) +
   `coerce_const_value` (`:18246`) before `lower_expr`, mirroring the host's
   `lower_static_storage_initializer` (`compile_time_const_value` →
   `lower_compile_time_literal`; `lowering/utils.rb:335-419`,
   `declarations.rb:166-174`).  The sweep set is unchanged (43/623/51/0) with 23
   files' first difference deeper and none newly differing; locked by
   `test_global_initialized_from_imported_const` (a global ← module const ← raw
   module const chain folds to the raw struct's aggregate).
2b. **Bare function-reference value types** — **DONE (session 40, 2026-10-06)**.
   `fallback_type_raw` (`lowering.mt:16473-16492`) now reconstructs a bare
   function name's type with `name = id.name` and `variadic = sig.is_variadic`,
   mirroring the host's `infer_expression_type` (`lowering/resolve.rb:750` →
   `function_type_for_name` → `binding.type`); locked by
   `test_function_reference_carries_declared_name`.  The sweep set is again
   unchanged with **29 files' first difference deeper, 0 shallower, 0 newly
   differing** (the box3d family plus 20 `examples/sdl3/**` files; the box2d
   family's first difference is another category).
2c. **Tuple struct registration** — **DONE (session 40, 2026-10-06)**.
   `ensure_tuple_struct_ir` (`lowering.mt:6440`) registers one `IR::StructDecl`
   per tuple type — `name` = the qualified `Tuple#to_s` via the new
   `naming.type_to_s_qualified` (`(main.P, int)`,
   `(std.vec.Vec[int], array[int, 3])`), linkage = the new
   `naming.tuple_type_c_name` (`mt_tuple_<sanitized elements>` with the host's
   `sanitize_type_name_for_tuple` collapse/strip and the non-default
   field-name suffix), fields `_0..` or the named ones — registered at tuple
   literals (`lower_tuple_literal_with_names`) and at `decl_var`/`decl_const`
   for the declared type (`ensure_storage_type_tuples`, the host's recursive
   `ensure_registered_storage_type_types` shape), drained into `structs` after
   the module fragments (`lower()` via `dedup_append_structs`, the host's
   `assemble_modules` tail placement).  The C backend now shares the name
   function and drops IR-declared tuples from its own collection
   (`filter_declared_tuple_types`), so each tuple struct is emitted once, from
   the IR — the emitted C for a tuple matches the host's byte-for-byte.
   Measured: sweep set unchanged (43/623/51/0) with **6 files' first
   difference deeper, 0 shallower, 0 newly differing** (`examples/box3d/
   common.mt`, `examples/box2d/common.mt`, `examples/box2d/human.mt`,
   `imported_bindings/raw_scanner.mt`, `std/color.mt`,
   `test/mt/color_test.mt`; +12,335 to +27,907).  Locked by
   `test_tuple_literal_registers_value_struct` and
   `test_storage_tuple_registers_value_struct`.
2d. **Synthetic-struct ordering** — **DONE (session 40, 2026-10-06)**.  The
   host keeps ONE creation-ordered `@artifacts.synthetic_structs` populated by
   11 producers — proc envs (`block.rb:112`), async frames (`functions.rb:210`),
   pfor/spawn caps (`loops.rb:497,648`), dyn vtables (`dyn.rb:86-95`), five
   event structs (`events.rb:102,175,189,204,218`) and tuples
   (`expressions.rb:1075`) — and `assemble_modules` appends the deduped list
   after all module structs (`lowering.rb:283`).  The self now mirrors it:
   `LowerCtx.pending_synthetic_structs` is pushed *at creation time* by every
   producer — tuples (`ensure_tuple_struct_ir`), proc envs and capture caps,
   async frames (`lower_async_fn`, whose `structs` parameter and
   `lower_extending_block`'s are gone), dyn vtables (dual-pushed; the kind list
   still backs the two vtable lookups), the five event runtime structs and the
   str-buffer structs — and `lower_module` drains it into the program-level
   list that `lower()` appends after the module fragments
   (`pending_env_structs`/`pending_event_structs` and the per-kind fragment
   pushes are gone).  Measured: sweep set unchanged (43/623/51/0) with **42
   files' first difference deeper, 0 shallower, 0 newly differing** — the
   box2d/box3d families (+13,164), the `std/net/**` async family (up to
   +14,294), `async_stress_test` (+16,069), `async_network_lobby` (+16,622),
   tetris/stress, the DAP protocol modules and `imported_bindings/main`.
   Locked by `test_synthetic_structs_follow_creation_order` (fails at the 2c
   state).  Residual: the `mt_str_buffer_*` decls have **no host counterpart**
   (the host's IR carries none — `examples/raylib/core/compute_hash.mt`: host
   0, self 3); they now ride the same list, and removing them from the IR
   needs backend-side synthesis — a separate item if pursued.
2e. **Tuple type rendering and the folded-tuple literal shape**.
   (a) **DONE (session 40, 2026-10-06)**: the sexpr dumper now renders an
   anonymous tuple's `Types::Tuple#field_names` with the host's default
   positional names (`("_0" "_1")`) instead of `nil`, and `try_const_tuple_ir`
   names a folded tuple's aggregate fields `_0..` (they were `0`/`1`) — the
   sweep went **43 → 44 match / 623 → 622 differ** (`std/color.mt` is
   byte-identical) with `test/mt/color_test.mt` moving +46,643 and 0 newly
   differing; locked by `test_anonymous_tuple_renders_default_field_names`.
   The self's internal model keeps `None` for an anonymous tuple (the dumper
   and the C name/field paths handle both forms), so only the dump changes.
   (b) **DONE (session 40, 2026-10-06)**: a tuple-typed constant with an
   expression-list (or call/specialization) value takes the host's
   `lower_const_value_literal` path — `const_tuple_array_literal` + the
   `const_value_literal_path` guard in `decl_const` emit an
   `IR::ArrayLiteral` whose element literals are re-typed to `int` (the host's
   fallback element type, since `Types::Tuple` has no `arguments`; integers
   are masked to 32 bits), with a non-scalar element falling back to the
   aggregate.  Corpus-neutral: no corpus file carries the shape, so the sweep
   set/counts are unchanged; the `use.mt` and `mixuse.mt` fixtures
   (`(int, bool)`/`(bool, int)` element typing) are byte-identical, locked by
   `test_tuple_constant_lowers_to_array_literal` (fails with the change
   reverted).
3. **Refined (non-null) operand types after a null check** (item 14;
   `data_structures` + `reflection_advanced`'s first difference) —
   **VERIFIED CLOSED (session 40, 2026-10-06)**: F2's continuation refinement
   (session 15) already fixed the dump difference; both files' first
   difference is now 3b.
3b. **`reinterpret` lowering** — **DONE (session 40, 2026-10-06)**.  The
   builtin now always lowers to `IR::ReinterpretExpr` (`lowering.mt:7737-7758`),
   with the source type read from the host's refined env for an identifier
   argument: `analyzer.flow_type_at` (moved from `lsp/navigation.mt` so the
   lowering can share it) supplies the narrowed local type — `ptr[void]` after
   `if p == null: return`, the declared `ptr[void]?` without a guard.  Two
   supporting fixes: **the nullability pre-pass now runs for method bodies**
   (`check_method_body` mirrors `check_function_body`'s CFG build + solve +
   barrier — `std/mem/heap.mt`'s `contains` is a method, so without it the
   heap sites never refined), and **`flow_type_at` scans the cursor's body
   span** (the greatest start-barrier position at or before the cursor, then
   entries up to the next barrier) because the check passes run functions
   then methods — out of positional order — and the old flat scan let a later
   body's barrier wipe an earlier body's records (repro: a method + a guarded
   free function in one file; the two-pass order itself is host-locked by
   `test_binding_ids_follow_the_hosts_allocation_order`, so the merge into one
   positional pass was tried and reverted).  The C keeps the union
   compound-literal rendering (valid once the source type matches; the host's
   memcpy helper is a C-text difference, not a behavioural one — the builds
   and runs are green).  Measured: sweep set unchanged (44/622/51/0) with
   **169 files' first difference deeper, +1527 each** (the shared heap
   module's reinterpret sites), 0 shallower/new; locked by
   `test_reinterpret_always_reinterprets_with_refined_source` (fails with the
   change reverted); the `re.mt`/`re4.mt`/`reintfix` fixtures are
   byte-identical.  Gates: bootstrap fixed point + 19/0, `test/mt` 60/0,
   cli_parity 24/37/0 unchanged, recovery OK, examples 49/49, the LSP harness
   at its 4 documented entries and the project audit at its documented 5
   (re-run after the `flow_type_at` change).
3c. **A pointer-like guard binding's read type** — **DONE (session 41,
    2026-10-06)**; the census's last leader (~355 files, the box2d family's
    first difference and `std/mem/heap.mt`'s `contains`).  The wrong-site note
    stands: session 40's "carry the success type" attempt was made in
    `guard_success_projection` (the *binding read*), but the *read* is
    `Nullable(ptr[T])` on **both** compilers — the host's `IR::Name` really is
    the storage type.  The actual divergence is the **binary's type**: for
    `blocks + i` (a guard-bound `ptr[T]?` local) the analyzer's inference *is*
    refined (`infer_binary`'s `is_raw_pointer(lt)` returns the refined
    `ptr[T]` — probed with temporary instrumentation, the recorded
    `resolved_expr_types` entry is `ptr[Block]`), but the lowering's
    pointer-arithmetic branch (`lowering.mt:6041-6044`) overwrote `result_ty`
    with the *lowered* left operand's type, whose `Nullable(ptr[T])` passes
    `is_raw_pointer` (it unwraps nullables).  The fix unwraps the nullable for
    the result type — `result_ty = if types.is_nullable_type(left_ty):
    types.unwrap_nullable(left_ty) else: left_ty` — so the binary keeps the
    analyzer's refined pointer (the host's `pointer_arithmetic_result` returns
    the *refined* left type) while the `IR::Name` read stays the storage type.
    Noted, not changed: the self's *analyzer* accepts unguarded nullable
    pointer arithmetic (`p + 1` on a plain `ptr[T]?`) where the host rejects it
    ("operator + requires compatible numeric types, got ptr[Block]? and int") —
    no corpus file can contain it (the host refuses them).  Measured: the sweep
    set is unchanged (55/611/51/0) with **255 files' first difference deeper by
    +1287** (the same heap node across the importing corpus), 0 shallower/new;
    locked by `test_guard_bound_nullable_pointer_arithmetic_is_unwrapped`.  The
    newly exposed first differences in that heap region are 3h/3i below, and the
    raylib audio family's is 3j.
3h. **The compound-assignment literal's contextual type** — **DONE (session 41,
    2026-10-06)**.  `i = 1` / `i += 1` / `i -= 3` on a `ptr_uint` target now emit
    `ptr_uint` literals, not `int` ones: the assignment arm applies the local
    declaration arm's literal set (`int_literal_to_context_type`,
    `float_…`, `string_…`, `null_…`) against `expr_type(target)` after lowering
    the value — the host's `lower_contextual_expression` with the target as the
    expected type.  Measured: the sweep set unchanged (55/611/51/0) with **255
    files' first difference deeper by +18**; locked by
    `test_assignment_literals_take_the_target_type`.  The same heap node's next
    difference is 3i.
3i. **A `continue` inside a loop body** — **DONE (session 41, 2026-10-06, the
    continue half)**.  A `continue` inside a **plain `while`** now lowers to
    `IR::ContinueStmt` (the host's `loop_exit_continue` kind): the loop lowering
    sets `LowerCtx.loop_continue_native` around the body, since a plain C
    `while`'s continue point is the loop's condition — exactly where the
    self's `__mt_loop_continue_N` label sat.  The label/goto form stays for
    every other loop: for-loops (their desugared post sits after the continue
    point — the `stmt_for` arm clears the flag), the async `while true` rewrite
    (its own labels), and a `continue` inside a match's `switch` needs no
    special case at all (C's `continue` reaches the loop through a `switch`).
    **The `break` half landed in session 43** (3i-b below: a native break in a
    plain `while`, with the switch-backed match arms' bodies invalidated so
    their breaks keep the label/goto form).  Measured: the sweep set unchanged
    (55/611/51/0) with
    **255 files' first difference deeper by +222** (the shared `std/mem/heap.mt`
    node), 0 shallower/newly differing; locked by
    `test_continue_in_a_plain_while_is_native`.  The same heap node's next
    difference was 3k (the `reinterpret` below it), **fixed in session 43**.
3k. **The guard-bound `reinterpret` source type** — **DONE (session 43,
    2026-10-07)**.  `let start = reinterpret[ptr_uint](data)` (`data` a
    guard-bound `ptr[ubyte]?`, `std/mem/heap.mt`'s `contains`) carried the
    storage `Nullable` where the host carries the refined `ptr[ubyte]`.  The
    trigger was **any guard inside a compound statement**, not the `continue`
    (both a `while` body's guard and an `if …: return` arm's refinement
    reproduced); the refinement record's post-statement snapshot carried the
    statement's *start* position, so the enclosing statement's post-record
    shadowed the body's entry for cursors inside the body.  Landed: the record's
    post-statement snapshot now sits at the statement's *end*
    (`statement_end_line`, sentinel column, plus the host's start-position
    replay for multi-line statements — with the replay skipping *cleared*
    transitions, which the self's delta record would otherwise emit at the
    statement's start, shadowing the body's own entries under the order-based
    lookup).  Measured (subset `std examples test`, the
    identical corpus for both binaries): **209 files' first difference deeper
    (+30,767 each), 0 shallower, 0 newly differing, 0 lost**; the full corpus
    stays 55/611/51/0 and `std/mem/heap.mt`'s reinterpret sites are
    byte-identical (its first difference moved 13,466 → 47,201).  Locked by
    `test_guards_inside_statements_keep_their_refinement`.  The LSP is
    unchanged: the harness reads its 4 documented entries, the pre/post-fix
    self recordings are byte-identical and the canonical audit reads its
    documented set (`docs/memory_stress_test.mt@39:24`'s refined-parameter
    hover drove the final design: the host's replay carries the outer state).
3l. **The `read(x) =` target's literal type** — **DONE (session 43, 2026-10-07)**
    (newly exposed by 3k; `std/mem/heap.mt`'s `read(header - 1) = 0`).  The
    `read(x) = value` arm lowers the value with no contextual typing, so a bare
    literal kept `int` where the host types it with the *target's* type
    (`ptr_uint` — the host's `lower_assignment_stmt` passes `target.type` as the
    expected type for every target shape).  Landed: the literal set is factored
    into `assignment_value_to_target_type` (int/float/string/null — the host's
    `lower_contextual_expression`) and applied on the read-target path as well
    (the plain-target path keeps using it).  Measured: **`std/mem/heap.mt` is
    byte-identical** and the sweep went **55 → 81 match / 611 → 585 differ**
    (**26 flips**: `std/behavior_tree.mt`, `std/binary_heap.mt`,
    `std/blackboard.mt`, `std/box.mt`, `std/cmd.mt`, `std/counter.mt`,
    `std/deque.mt`, `std/fsm.mt`, `std/htn.mt`, `std/iter.mt`,
    `std/linked_map.mt` and the other heap-importing std files), with the
    subset comparison reading 48 → 74 match, 183 files deeper, 0 shallower,
    0 newly differing, 0 lost.  Locked by
    `test_read_target_literals_take_the_pointee_type`.
3m. **The call-argument and variant-field literals** — **DONE (session 43,
    2026-10-07)** (newly exposed by 3l; the box2d/box3d families — `Arena(...)`
    construction and friends).  The host lowers every call argument and variant
    arm field value with the parameter's/field's type as the expected type; the
    self kept the literal defaults.  Landed on 3l's
    `literal_value_to_context_type` (renamed from
    `assignment_value_to_target_type`): plain calls
    (`lower_call_with_callee`, from the callee signature's params), method
    calls (`coerce_literal_to_mono_param`, against the *specialized* IR
    function's params — `lower_monomorphized_method` is the path for ordinary
    method calls) and variant arm fields (`collect_variant_literal_fields`,
    against `variant_field_type_from_arm`'s field type; non-generic variants —
    the generic case is **3o** below).  The mono seam exposed a second,
    *pre-existing* divergence: a bare (suffix-less) float literal operand was
    left at its default `float` type and turned into a cast
    (`(double) 2.718281828459045f`, truncating the value) where the host
    re-types it against a float peer — the binary arm now does the same
    (`is_bare_float_literal`; an explicit `f`/`d` suffix keeps its own type),
    and `test/mt`'s binary float round-trip caught the truncation.  Measured:
    the `std examples test` subset went 74 → 76 match (**2 flips**:
    `std/mem/arena.mt`, `std/mem/stack.mt`) with 82 files' first difference
    deeper, 0 shallower, 0 newly differing, 0 lost; the full corpus went
    **81 → 83 match / 585 → 583 differ**.  `body_move.mt`'s first difference
    moved past the arena constructor to the generic-variant arm field (3o).
    Locked by `test_call_argument_literals_take_the_parameter_type`.
3o. **The generic-variant arm field type** — **DONE (session 43, 2026-10-07)**
    (newly exposed by 3m; `std/str.mt:220`'s `Option[ptr_uint].some(value = 0)`,
    the box2d family's first difference).  `variant_field_type_from_arm` keys
    the arm payload registry by `naming.type_c_key(instance)` + `_` + arm, but a
    *prelude* variant instance's arm info is only registered where a match or
    the `?`-propagation path touches it — so at a construction site the field
    type was unresolved and the literal kept `int` (host: `ptr_uint`).  Landed:
    on a registry miss, `variant_field_type_from_arm` registers the prelude
    instance's arm fields on demand via `variant_info_for_c_name` (the
    `std_option_*`/`std_result_*` C name maps back to the installed
    `Option`/`Result` `VariantInfo`) + the existing
    `register_arm_payload_fields`/`specialize_prelude_arm_info` machinery.
    Measured: the fixture is byte-identical; `std/str.mt`'s first difference
    moved 198,147 → 201,728 and `body_move.mt`'s 420,484 → 424,065 — both now
    the **3i break half** — with 80 files' first difference deeper on the
    subset, 0 shallower, 0 newly differing, 0 lost; the full corpus stays
    83/583 (no flips yet — the box2d family's next block is the break).  Locked
    by `test_generic_variant_arm_field_takes_the_instance_type`.
3g. **The flags/enum type rendering** — **DONE (session 43, 2026-10-07)** (the
    census's old leader, ~24+ files: the raylib core family and the box2d
    examples' early dumps).  Two root causes, both in the *dumper's*
    classification of nominals (the host dumps the type *object*'s class; the
    self recovers it from declared names):
    - a raw (`external`) module's enum/flags/union/variant/opaque has no IR
      declaration (the module emits only includes), so `ty_imported` (and a
      module-qualified `ty_named`) fell back to `Types::Struct`;
    - a *flags* declaration is an `IR::EnumDecl` with `is_flags`, so even a
      declared flags type rendered `Types::Enum` — `named_type_class` had no
      Flags case.
    Landed: `dump_ir_with_analyses` (the CLI passes `program.analyses`; plain
    `dump_ir` keeps an empty span for the tests), `register_decl_kinds` (each
    analysis's source declarations → `<module>.<name>` → class, covering
    Enum/Flags/Union/Variant/Opaque/Struct), `imported_type_class` (the
    qualified lookup, used by `ty_imported` *and* a module-qualified
    `ty_named`), and the ctx's `flags_names` set.  Measured: the fixture's
    class renderings match the host exactly (`Types::Enum`/`Types::Flags`/
    `Types::Opaque` with the raw module name), **35 files flipped** (the raylib
    core family: `2d_camera*`, `3d_camera*`, `input_*`, `basic_screen_manager`,
    `scissor_test`, `screen_recording`, …), the subset 82 → 117 match with 83
    files' first difference deeper, 0 shallower, 0 newly differing, 0 lost; the
    full corpus **91 → 126 match / 575 → 540 differ**.  Only `main.mt` imports
    the dumper, so the LSP is untouched.  Locked by
    `test_raw_module_declaration_kinds_render_in_the_dump`.  The box2d family's
    next block is **3q** below.
3q. **The foreign address-of's boundary type** — **DONE (session 43,
    2026-10-07)** (newly exposed by 3g; the box2d family —
    `examples/box2d/common.mt:371`'s `b2.create_world(world_def)`).  Three
    `lower_foreign_arg` sites typed the address-of with a `ptr[void]`
    placeholder where the host's `lower_addr_expression` uses the boundary's
    pointer `target_type`:
    - a plain `in` parameter → `const_pointer_to(parameter.type)` — the
      AddressOf is `const_ptr[T]`, and the element is the *resolved* declared
      type;
    - `out`/`inout` → `pointer_to(foreign_slot_boundary_value_type(t))` (the
      nullable pointer-like slot unwraps to its base) — the cast path and the
      address path now share `slot_ptr_ty`.
    A second part: the element type must follow the wrapper's alias chain to
    the raw target (`WorldDef` → `c.b2WorldDef`), which `qualify_type` keeps by
    name for std.c-targeting aliases (a deliberate C-signature choice) —
    `deep_alias_target` follows module-local aliases, and
    `resolve_alias_targeting_module` handles the pairing the qualifier leaves
    (`ty_imported("<target module>", "<alias name>")`) by looking the alias up
    where it is declared and accepting it only when it targets that module.
    Measured: the fixture (three modules: raw `std.c.raw.lib` + wrapper alias +
    caller) is byte-identical and the `const_ptr[Def]` element matches the
    host; **5 files flipped** (the raylib *shapes* family: `hilbert_curve`,
    `math_sine_cosine`, `rlgl_color_wheel`, `splines_drawing`,
    `triangle_strip`), the subset 117 → 122 match with 55 files' first
    difference deeper, 0 shallower, 0 newly differing, 0 lost; the full corpus
    **126 → 131 match / 540 → 535 differ**.  `body_move.mt`'s first difference
    moved to **3r** below.  Locked by
    `test_foreign_in_argument_addresses_the_resolved_boundary_type`.
3r. **The struct equality desugaring** (newly exposed by 3q; the box2d family —
    `common.mt`'s `mouse_joint != some_id`) — **DONE (session 44, 2026-10-07)**.
    The host emits `(IR::Binary :operator "!=" …)` on the struct values and
    synthesizes the `mt_struct_eq_<T>` helper in its C backend from the *type
    object's* fields (its IR carries no helper); the self desugared in the
    lowering to `(IR::Unary "!" (IR::Call "mt_struct_eq_std_c_box2d_b2JointId"
    …))` *and* carried the helper as an IR function — raw (`external`) modules
    emit only includes, so their structs have no IR declaration and the backend
    had no field layout to synthesize from.  Landed: the lowering keeps the
    host's `IR::Binary` and registers the layout (transitively, for nested
    external structs) in the new `Program.external_structs`
    (`ExternalStructLayout`, keyed by `naming.type_c_key`; a non-declaration
    section the dumper ignores, like `monomorphized_structs`); the C backend's
    `register_equality_type`/`emit_struct_equality_helpers`/
    `equality_helpers_need_str` consult it through `external_eq_fields`/
    `equality_fields_for` and synthesize the helper exactly where the host does
    (the emitted helper is byte-identical to the host's:
    `static bool mt_struct_eq_b2JointId(struct b2JointId left, …)` with the same
    field guards).  Measured: the subset comparison (identical corpus,
    `std examples test`) reads **122/399/47/0 on both binaries** with **30 files'
    first difference deeper by +21,667 to +21,677** (`examples/box2d/**`), 0
    flips, 0 shallower, 0 newly differing, 0 lost; the full corpus stays
    **131/535/51/0 of 717**.  Locked by
    `test_external_struct_equality_keeps_the_binary_and_registers_the_layout`
    (the dump keeps the `IR::Binary`, has no `mt_struct_eq`, and registers both
    the compared and the nested layout) and
    `test_external_struct_equality_helper_is_synthesized` (the emitted C:
    forward decl + field guards + negated call site).
3s. **The array-length literal from an imported constant** (newly exposed by 3r;
    the 30 box2d files).  `var points: array[b2.Vec2, b2.B2_MAX_POLYGON_VERTICES]`
    (`common.mt`'s `random_polygon`) renders `(Types::LiteralTypeArg :value 8)`
    on the host and `:value 0` on the self — both for the wrapper re-export
    (`std/box2d.mt:111` ← `std/c/box2d.mt:1253`) **and** the direct raw form
    (`import std.c.box2d as c` + `array[c.b2Vec2, c.B2_MAX_POLYGON_VERTICES]` —
    probed), so the wrapper hop is not the trigger; a local const and a literal
    digit already resolved on both.  — **DONE (session 44, 2026-10-07)**.  Root
    cause: the *lowering*'s `resolve_array_length_type` folded only single-part
    names (literal digits, type-substitution entries, the current module's
    const table) and fell into `resolve_array_length` for a dotted name — which
    returns 0 for anything that is not a single decimal part — so every
    module-qualified length rendered `literal_int(0)`.  Landed: the dotted case
    folds through the alias's module (`ctx.analysis.imports` → the target
    analysis → the const's value expression evaluated *there*, the host's
    `resolve_imported_module_const_value`), and `try_const_eval_int` gained a
    member-access arm so a const whose value chains (`std/box2d.mt`'s
    `= c.B2_MAX_POLYGON_VERTICES`, and `+ 1` arithmetic on it) folds too.
    Measured: the three probes now match the host (`array[…, 8]`, the direct raw
    form `8`, and a normal module's `public const` `4`); the identical-corpus
    subset comparison reads **122/399/47/0 on both binaries** with **the same 30
    files' first difference deeper again (+19,298 to +19,308)**, 0 flips, 0
    shallower, 0 newly differing, 0 lost; the full corpus stays 131/535/51/0.
    Locked by `test_array_length_folds_through_an_imported_const` (the direct
    raw const and the wrapper chain `c.MAX_PARTS + 1` → 8 and 9).  Residue: the
    *analyzer*'s dotted-const branch (`resolve_named`, `analyzer.mt:2609-2629`)
    still records `ty_error` for a chained imported const — its fold evaluates
    the target's value expression against the *current* module's tables and
    `ModuleBinding` carries no import aliases to chase a further hop; invisible
    on the dump (the lowering re-resolves the declared type) and in the corpus,
    recorded for an analyzer-parity pass.  Also found while probing: the self
    accepts `points.len` on a fixed array where the host reports `cannot access
    member len of array[…]`.
3t. **The dyn vtable slot's function type** (newly exposed by 3s; the 30 box2d
    files — `common.mt`'s `sample.vtable.on_step(…)`) — **DONE (session 44,
    2026-10-07)**.  The host types the vtable member
    `(Types::Function :name "" :params ((data: ptr[void]) …) :return_type …)`,
    the self `(Types::Generic :name "ptr" :arguments ((Types::Primitive :name
    "void")))`: `dyn_vtable_method_fn_type` looked the slot's function type up
    in the generated `mt_vtable_<Iface>` struct, which lives in the ctx of the
    module whose `adapt` site created it — the dispatch site is in the module
    that *declares* the interface, so the lookup missed and the `ptr[void]`
    fallback was emitted (the host's `dyn_vtable_struct_type` always builds the
    slot from the interface binding, never from the generated struct).  Landed:
    the interface declaration is the fallback — `find_interface_analysis` →
    `data: ptr[void]` + the method's `resolve_field_type_ref`'d parameters
    (the same construction `ensure_dyn_vtable_struct` uses; the struct lookup
    stays first for the substituted forms a generic instantiation produced).
    Measured: the corpus's own flip — **`projects/stress/src/engine/interfaces.mt`
    becomes byte-identical; the full corpus goes 131 → 132 match / 535 → 534
    differ**, and the identical-corpus subset comparison reads 122/399/47/0 on
    both binaries with the same 30 files deeper (+1,925 each), 0 shallower, 0
    newly differing, 0 lost.  The fixture (an interface + dispatch in one
    module, the `adapt` site in another) is byte-identical to the host
    end-to-end.  **Runtime**: the pre-3t self binary aborted
    `array index out of bounds` (rc 134) running `examples/box2d/body_move.mt`;
    the post-3t build runs like the host (render loop, rc 124 under the 10 s
    sandbox) — the type fed the C backend's indirect call.  Locked by
    `test_dyn_vtable_member_takes_the_interface_method_type`.
3u. **The `out`/`inout` foreign boundary's alias deepening** (newly exposed by
    3t; the 30 box2d files — `b2.world_draw(world_id, s_debug_draw)` for
    `foreign function world_draw(world_id: WorldId, inout draw: DebugDraw) = c.b2World_Draw`)
    — **DONE (session 44, 2026-10-07)**.  The address-of was typed
    `ptr[DebugDraw]` where the host has `ptr[b2DebugDraw]`: the `in` branch
    qualifies then deepens (`deep_alias_target(qualify_type(…))` — 3q), but the
    `out`/`inout` branch deepened the *unqualified* resolve first, so the
    std.c pairing `deep_alias_target` resolves
    (`ty_imported("std.c.box2d", "DebugDraw")`) never existed at deepen time and
    `qualify_type` produced it afterwards.  Landed: qualify before deepen in
    that branch, the `in` branch's order (the type is the same for a raw
    pointer slot — the deepener leaves generics alone).  Measured: the
    `inout` probe (raw `struct Def` + wrapper `type MyDef = c.Def` +
    `foreign function take_it(inout d: MyDef)`) is byte-identical; **8 files
    flip** (`examples/box2d/common.mt`, `compound_shapes`, `confined`, `human`,
    `kinematic`, `rounded`, `tiny_pyramid`,
    `examples/raylib/core/3d_camera_free.mt`) and **42 files' first difference
    moves deeper** (23 box2d, 14 box3d, 5 raylib; +181 … +252,788), 0 shallower,
    0 newly differing, 0 lost; the subset reads 122 → **130 match**, the full
    corpus **132 → 140 match / 534 → 526 differ**.  Locked by
    `test_inout_argument_addresses_the_deepened_boundary_type`.
3v. **The array-storing receiver's borrow convention** (newly exposed by 3u; the
    box2d family — `this.find_body_index(move_event.bodyId)`) — **DONE (session
    44, 2026-10-07)**.  The host passes `(IR::Name "this" …)` to a plain
    method when the receiver type *contains array storage*
    (`pointer_lowered_method_receiver?`: `receiver_editable` or
    `type_contains_array_storage?` — `ContainsArrayStorageVisitor` walks
    struct fields and nullable bases, only an `array` instance sets the flag)
    and the self passed `(IR::Unary "*" "this")` — every plain method took
    `this` by value.  Landed: `receiver_by_pointer`/`type_contains_array_storage`
    port that rule; the method-function params (`lower_method`, the
    monomorphized-method site), `build_receiver_arg` (now ctx- and
    `MethodInfo.is_async`-aware — async keeps the value convention, as the host
    excludes it) and the dyn vtable wrappers all use it.  Measured: the probes
    (a 4-byte struct keeps the value convention, the array-storing one borrows —
    both byte-identical), **3 flips** (`examples/box2d/contact.mt`,
    `sensor_funnel.mt`, `std/noise.mt`) with 15 files' first difference deeper
    (14 box2d + 1 test; +64 … +76,462), 0 shallower, 0 newly differing, 0 lost;
    the subset 130 → **133 match**, the full corpus **140 → 143 match / 526 →
    523 differ**.  Locked by `test_array_storing_receiver_is_borrowed`.
3w. **The format-string hoist** (the census's top row after 3v; the sdl3 family
    and the box2d family's `draw_text_line` sites) — **DONE (session 44,
    2026-10-07)**.  The host's dynamic format string is a *statement-level*
    protocol: `prepare_format_string_expression_for_inline_lowering` builds it
    into the statement's setup and registers a `mt_format_str_release(temp)`
    cleanup, `build_dynamic_format_string_temp_setup` names the result after the
    most recent local declaration (`__fmt_<name>`, `_cap`/`_off`, `_2` for a
    destination's repeats), orders the parts' temps first, then the capacity,
    the accumulations (`cap = cap + len(…)`), the result (`mt_format_str_make`)
    and the offset, and only casts a part whose type differs from its append
    argument.  The self wrapped the whole build in an `IR::StmtExpr` and used
    its own `__mt_fmt_cap/off/result_N` names.  Landed: the arm now builds into
    the statement's hoisting window (`hoist_stmts`) with the release pushed to
    `hoist_cleanups` (skipped for `return`, whose str case transfers ownership),
    `build_format_string_dynamic` mirrors the host's naming/order/cast shapes,
    `fmt_dest_name` (set by the local-decl arm, block-scoped like the host's
    per-block env) and the per-function `fmt_counter` drive the names, and the
    local/assignment arms drop the release for `str`/`cstr`/string-holding
    targets (`drop_format_release_cleanups` — the host's
    `reject_format_releases_for_assignment`).  The dedicated
    `lower_format_string_local` path is gone (the general window path produces
    the host's `__fmt_<name>` temp + `name = temp` decl).  Measured: the fixture
    (a repeated destination) is byte-identical end-to-end; **15 flips** (the
    whole box2d family) with 30 files deeper (15 raylib, 11 sdl3, 3 box2d, 1
    std), 0 shallower, 0 newly differing, 0 lost; the subset 133 → **148
    match**, the full corpus **143 → 158 match / 523 → 508 differ**.  Locked by
    `test_dynamic_format_string_hoists_with_the_destination_name`.
    Residue: a format string in a lazily-evaluated region (the window is
    suspended) keeps the inline `StmtExpr` and no release (the host has no such
    shape); the custom `format_len`/`append_format` hook path keeps the self's
    shapes (its `fmt_part_len` temp / span-output append is a separate port —
    not corpus-visible: only `test/mt/fmt_test.mt` exercises it and that file's
    first difference is the `mt_str_buffer_*` decls).
3x. **The cstr-backed `str as cstr` argument** (newly exposed by 3w; 18 files —
    the raylib core family, `std/raylib/debug_console.mt`) — **DONE (session
    44, 2026-10-07)**.  The first difference the census called "the nested
    foreign-call argument": `DrawTextEx(GetFontDefault(), <str>, …)` — the
    nested call already matched; the *`str` argument* was the difference.  The
    host passes a **cstr-backed** value's `data` pointer directly
    (`cstr_backed_expression?` + the `foreign_identity_projection_expression`
    cast), the self always allocated an `mt_foreign_str_to_cstr_temp` copy.  A
    value is cstr-backed when it is a `cstr`-typed expression, a string
    literal, another cstr-backed local, or a dynamic format string's result
    temp (the host's `register_prepared_temp!(…, cstr_backed: true)`, whose
    *prepared identifier* then flows into a local declaration's
    `cstr_backed_storage_value?`).  Landed: `ctx.cstr_backed_names` (per
    function, cleared with the other body state), registered by the local-decl
    arm via `cstr_backed_binding` (the lowered value's cstr type, a
    cstr-backed read, or a literal initializer) and by the format arm for its
    result temp; `lower_foreign_arg`'s cstr branch emits the direct
    `(IR::Cast cstr (IR::Member … "data"))` for a cstr-backed read and keeps
    the malloc temp otherwise.  Measured: the fixture (a literal local, a
    format local and a call result → two direct casts and one temp) is
    byte-identical end-to-end; **18 flips**, 1 file deeper, 0 shallower, 0
    newly differing, 0 lost; the subset 148 → **166 match**, the full corpus
    **158 → 176 match / 508 → 490 differ**.  Locked by
    `test_cstr_backed_strings_pass_data_directly`.
3y. **The branch-position foreign-call setup** (the session-44 re-census's
    leader, ~101 then ~134 files after 3y; the audio family's second difference)
    — **DONE (session 44, 2026-10-07)**.  An `if` condition is a *prepared*
    position on the host: `prepare_expression_with_cleanups(branch.condition)`
    → `prepare_statement_lowered_foreign_call` →
    `materialize_prepared_expression`, so a statement-lowered foreign call's
    argument temps, the `__mt_foreign_result_N` materialization and its
    cleanups all precede the `IfStmt`, whose condition reads the result temp;
    `else if` setups land at the head of the enclosing else body, and the
    condition's *other* cleanups are duplicated into both branches
    (`condition_cleanup_statements`).  The self lowered the condition with no
    window (an inline `IR::StmtExpr`).  Landed: `lower_if_chain` takes the
    output vec, opens an `hm_return` window around each branch condition, emits
    the collected setup before the `IfStmt`, and heads both branches with the
    collected cleanups (both call sites updated — the async await-hoist path
    splices the same shapes).  Measured: the fixture (a foreign `if` condition
    with a `str as cstr` argument) is byte-identical — arg temp, result temp,
    free, `IfStmt(result)`; **34 flips** (the raylib audio/models/textures
    families), 66 files deeper, 0 shallower, 0 newly differing, 0 lost; the
    subset 166 → **200 match**, the full corpus **176 → 210 match / 490 → 456
    differ**.  Locked by
    `test_if_condition_foreign_setup_hoists_before_the_statement`.
    Residue: the `while` condition's prepared shape (the host rewrites the loop
    to `while true { setup; if !cond { cleanups; break } else { cleanups };
    body }`, `loops.rb:45-68`) is not ported — no current leader.
3aa. **`return null` into an `own`/nullable return** (the post-3y re-census's
    leader, ~134 files — `std/mem/heap.mt`'s null-returning helpers and their
    importers) — **DONE (session 44, 2026-10-07)**.  The host types the literal
    `(Types::Nullable :base (Types::Generic :name "own" :arguments ((Types::Primitive :name "int"))))`
    where the self emitted `(Types::Primitive :name "void")`.  Root cause:
    `lower_specialized_function` (the *monomorphized* body path) never set
    `ctx.current_fn_return_type`, so the return arm's contextual null typing
    (`null_literal_to_context_type` against `ctx.current_fn_return_type`) saw
    the default `void` — the non-generic `lower_function`/`lower_method` paths
    set it (and `lower_specialized_method` already did).  Landed: the
    substituted `ret_ty` (computed for the IR function anyway) is installed
    around the body lowering, saved/restored like the other paths.  Measured
    (same subset protocol, the 3y `build/stage2/mtc` vs `tmp/mtc-dev`): the
    fixture (`maybe[T](flag) -> own[T]?` returning `null`, called as
    `maybe[Box]`) is byte-identical; **3 flips** (`std/bitset.mt`,
    `std/bytes.mt`, `std/mem/pool.mt`) with **97 files' first difference
    deeper** (39 `test`, 30 `std`, 17 sdl3, 7 raylib; +6,370 … +237,261), 0
    shallower, 0 newly differing, 0 lost; the subset 200 → **203 match**, the
    full corpus **210 → 213 match / 456 → 453 differ**.  Locked by
    `test_monomorphized_null_return_takes_the_substituted_type`.
3ad. **The monomorphized method's declaring-module grouping** (the post-3aa
    re-census's leader, ~91 files) — **DONE (session 44, 2026-10-07, the
    grouping half)**.  The host groups a method's instances under the module
    that *declares* the extending block (`lower_functions` walks that module's
    declarations); the self's `SpecInfo.owner_module` used the *receiver
    type's* module, which a cross-module call site can have registered as its
    own (`Vec.create[String]` written in `std.string` captured "std.string"),
    so those instances fell into the creating module's leftovers instead of
    their declaration's slot (`examples/nullable_and_variant_test.mt`'s first
    difference).  Landed: `ensure_monomorphized_method` records
    `gm.owner_module` (the declaring analysis, already used to lower the body)
    in the `SpecInfo`.  Residue (the *instance order within one declaration*,
    `examples/data_structures.mt`'s `std_mem_heap_release__*`): the host's
    `binding.instances.values.sort_by { type_arguments.map(&:to_s).join(",") }`
    leaves instances with equal keys in their creation (insertion) order — the
    host's observed sequence (`Node[...]` group, `str`, `ubyte`, then the
    `std.iter.*` states) does not match any plain rendering sort, so the
    creation-wave semantics (which instances exist at each module's walk) need
    the host's `lower_functions`/`lower_function_decl` interplay to mirror
    exactly; the self sorts by `naming.type_c_key` (a stable, but different,
    order).  Repro: `examples/data_structures.mt` at byte 329,462 after 3aa.
3ae. **A foreign call argument's `null` literal** (the post-3aa re-census, ~34
    files — the raylib `LoadShader(null, …)` family): the host types the
    literal `(Types::Nullable :base (Types::Primitive :name "cstr"))`, the self
    `void` — the foreign-argument path does not apply the contextual null
    typing.  Repro: `examples/raylib/shaders/ascii_rendering.mt` at its first
    difference.  **DONE (session 44 batch 2, 2026-10-08 — re-applied on top of
    3ag)**: the bare `null` takes the parameter's declared type (+8 subset
    flips), locked by `test_foreign_null_argument_takes_the_parameter_type`.
3wf. **The dynamic format counter's env scope** (the 3w follow-up; the batch-1
    census's ~6 files, `examples/box2d/convex_hull.mt`): the counter is created
    lazily at the first use *in an env* and shared with that env's descendants
    (`env[:fmt_counter] ||= {}` on a `duplicate_env`'d hash), so a sibling block
    whose parent holds no counter restarts at 1 — the self counted across
    siblings.  **DONE (session 44 batch 2, 2026-10-08)**: a visibility flag
    saved/restored in `lower_block` with the slot created at the first
    `format_string_result_base`; subset 219 → 222, locked by
    `test_format_counter_is_env_scoped`.
3fa. **A function-typed module variable's call** (the post-batch-2 census's
    73-file leader, `examples/box3d/*`'s `s_scene_draw()`): the host's callee is
    an `IR::Name` carrying the function type, the self emitted a bare C-name
    callee.  **DONE (session 44 batch 3, 2026-10-08)** — the identifier arm takes
    the `module_var_type`-is-a-function case through
    `lower_call_with_callee_expr`; locked by
    `test_function_typed_module_var_call_uses_a_callee_name`.
3fb. **The `defer` body's flat replay** (`examples/box3d/common.mt`'s `run`):
    the host's `lower_defer_cleanup_body` = `lower_block`, so a braced body's
    statements replay as siblings; the self wrapped each in an `IR::BlockStmt`.
    **DONE (session 44 batch 3, 2026-10-08)** — the defer arm splices
    `lower_block`'s span into the cleanup; **+17 subset flips**; locked by
    `test_defer_body_splices_its_statements_flat`.
3fc. **Every foreign-argument literal takes the parameter's type** (the 3ae
    extension; `raylib_opengl_interop.mt`'s `uint` literal): the host's
    `lower_contextual_expression` retypes int/float/str, not just `null`.
    **DONE (session 44 batch 3, 2026-10-08)** — `literal_value_to_context_type`
    in the plain path; **+7 subset flips**; locked by
    `test_foreign_integer_argument_takes_the_parameter_type`.
10a. **A nested struct's qualified C name** (the post-batch-9 field-context
    bucket; `nested_struct_stress_test.mt`, `event_stress_test.mt`): the host's
    `:linkage_name` carries the parents (`<mod>_Rectangle_Edge`) while the IR
    `:name` stays plain.  **DONE (session 44 batch 10, 2026-10-08)** —
    `lower_struct_decl` takes the qualified lookup name + linkage base and the
    nested walk threads the chain; 2 files deeper; locked by
    `test_nested_struct_linkage_carries_its_parent`.
10b. **The async frame's extra payload fields** (the same bucket, ~22 files:
    `async_network_lobby.mt`, `async_stress_test.mt`): the self's frame carried
    `local_<arm>_payload` projections the host's does not.  **DONE (session 44
    batch 11, 2026-10-10)** — the self now mirrors the host's two-part shape: an
    analysis-registered, never-referenced `local_match_binding_<N>` field for
    each arm whose body awaits (post-order, named from the shared counter the
    lowering also advances) and a plain `LocalDecl` for the binding itself;
    `recv_impl`'s frame and the interleaved names (`local_match_binding_1`, then
    `_6` two functions later) match the host byte-for-byte on the probes, 0
    flips with 22 files' first difference deeper, the corpus holding 286/380.
    Locked by `test_async_match_bindings_use_local_match_binding_fields`.
10c. **The async frame's position among the synthetic structs** (newly exposed
    by 10b): the host pushes the frame at `lower_async_function_decl` *before*
    the body's structs (`functions.rb:210`), so a body-lowered proc env follows
    it in `@artifacts.synthetic_structs`; the self pushes at the end of
    `lower_async_fn`, so the body's envs precede it
    (`examples/async_stress_test.mt`: `std_net_clock__proc_*__env` before
    `std_net_clock_measure_offset__frame`).  **DONE (session 44 batch 12,
    2026-10-10)** — `lower_async_fn` records `pending_synthetic_structs.len()`
    before the body lowering and inserts the frame at that index
    (`lowering.mt`'s `frame_index`/`insert`).
10d. **The async constructor params' `:pointer nil`** (newly exposed by 10b) —
    **DONE (session 44 batch 14, 2026-10-10)**: `ir.Param.pointer` is now the
    host's `Option[bool]` (the 45 construction sites carry `some(...)`, the
    async ctor loop computes `receiver_type && receiver_editable && name ==
    "this"`, the dumper's `field_optional_bool` renders nil, and the C backend /
    IR formatter read `unwrap_or(false)`); the same batch maps an empty type
    module name to `:module_name nil` (`field_module_name`).
10i. **The async ctor body's remaining shapes** (newly exposed by batch 14):
    (a) the ctor's `ready`/`cancelled`/`state` zero-stores, (b) the ctor's frame
    `Name` pointer, (c) the param-copy value `Name`s' `:pointer nil`, (d) the
    resume call / task aggregate carrying the frame's `ptr[void]` cast —
    **a, b, c and d DONE (sessions 44 batch 15/16, 2026-10-10)**; (c) landed as
    the `Option[bool]` sweep (210 `expr_name(` + 36 `LocalBinding(` sites, the
    readers `unwrap_or(false)`, `none` only at the async param bindings and the
    ctor copies): see batch 16's record.
10j. **The ctor aggregate's vtable entries** (newly exposed by batch 16) —
    **DONE (session 44 batch 17, 2026-10-10)**: the vtable functions are
    `<ctor>__<role>_fn` with linkage `<ctor>__<role>`, the resume is
    `<name>__resume`, the aggregate's Names carry the vtable signatures' types
    (with the host's parameter names), and the vtable params are
    `frame`/`__mt_frame_raw`, `waiter_frame`/`waiter_frame`,
    `waiter`/`waiter`; the probe's first difference moved 5,243 → 14,909.
10l. **The no-await resume's result store** (newly exposed by batch 17) —
    **DONE (session 44 batch 18, 2026-10-10, with the whole async-runtime-shape
    cluster)**: the host lowers every async return straight into
    `frame->result` (`IR::Member(__mt_frame, "result")`; no `__mt_result` local,
    no copy at a label) and completes the frame inline
    (`async_complete_statements`); the self's `__mt_result` local, its label and
    the completion goto are gone (see the batch-18 record), and
    `tmp/probe_b13.mt` is **byte-identical**.  The batch also ported the
    release/set_waiter/cancel bodies, the Task members' field types and the
    async `main`'s `___async_main` linkage.
10m. **The async main's constructor linkage** (newly exposed by
    `tmp/async_probe.mt`) — **DONE (session 44 batch 18, 2026-10-10)**: an async
    `main`'s constructor is `<module>___async_main` (the host's
    `function_binding_c_name`, `utils.rb:1089-1092`), not `<module>_main`.
10e. **The event runtime's owner-qualified names** (the same field-context
    bucket; `event_stress_test.mt`): item 4b's port — the host's
    `mt_event_<module>_<owner>_<name>[_<payload>]_<capacity>` naming, its shared
    `Subscription` struct (a built-in registry type the self has no counterpart
    for) and the self's bare-name-keyed `ctx.event_runtimes` (**two same-named
    events in different structs share one runtime today**).  **OPEN** — see
    item 4b below.
10f. **The embedded-await hoist temp** (newly exposed by batch 12;
    `std/net/clock.mt`'s `measure_offset` — `(await socket.send_to(...)).map_error(...)?`)
    — **DONE (session 44 batch 13, 2026-10-10)**: the three `lower_propagate_*`
    paths hoist the operand's embedded awaits (`async_hoist_awaits`), and the
    hoist temp takes the host's per-function `__mt_async_tmp_<N>` name (field
    `local___mt_async_tmp_<N>`; `ctx.async_tmp_counter`, reset per function);
    locked by `test_async_embedded_await_temps_and_discards`.
10g. **The `let _ =` discard field** (newly exposed by batch 12;
    `std/net/clock.mt`'s `respond_to_sync` — `let _ = await socket.send_to(...)`)
    — **DONE (session 44 batch 13, 2026-10-10)**: the discard registers the
    host's `local_discard_<line>` field and stores the (awaited) value there
    (`async_register_unused_field` + `async_emit_await`'s field target);
    locked by the same test.
10h. **The frame-field store's IR shape** (newly exposed by batch 13, behind
    10d/item 8A): the host builds a frame store's target as
    `IR::Member(receiver `IR::Name("__mt_frame")`, member "local_x")`
    (`async_frame_field_expression`) while the self stored through
    `IR::Name("__mt_frame->local_x")` (the *reads* use that same name on both
    sides).  **DONE (session 44 batch 15, 2026-10-10)** — all six store targets
    (the spilled-local value store, the direct-await store, the hoisted-await
    store, the discard's two and the `?`-propagate success store) are the host's
    `Member`; the probe's store members match exactly.
9a. **A const array's enum members fold to their values** (the post-batch-8
    census's 57-file leader — the compiler's own `mtc.lexer.token_kinds` tables):
    the host emits `(IR::IntegerLiteral :value … :type (Types::Enum TokenKind))`
    elements in a *const* initializer while a *runtime* array literal keeps the
    member names.  **DONE (session 44 batch 9, 2026-10-08)** — the fold sits in
    `try_const_array_literal_ir` with the shared `enum_member_value_of_expr`
    lookup; the compiler's own sources advance hugely (`formatter/tidy.mt`
    8,744 → 1,301,873); locked by
    `test_const_enum_table_folds_members_to_values`.
8a. **The foreign boundary projection** (the post-batch-7 census's 32 files,
    `examples/raylib/audio/amp_envelope.mt`, `raw_stream.mt`, `vr_simulator.mt`):
    `ptr_of(buffer[0])` — a `ptr[float]` — passed at a `const_ptr[void]` boundary;
    the host wraps it in an `IR::Cast`.  **DONE (session 45 batch 4,
    2026-11-02)**.  The earlier blanket attempt regressed 114 files because it
    cast by *source* type; the host's rule compares the *lowered expression's*
    type to the boundary (`foreign_identity_projection_expression`: equal → the
    value; cast-compatible → `IR::Cast`; else the external-layout
    `ReinterpretExpr`).  Landed: `project_foreign_boundary` +
    `foreign_projection_cast_compatible` (the pointer/nullable/cstr/opaque
    subset), `foreign_boundary_type` (the declared `as` type resolved in the
    wrapper's owner module), the `in` branch's
    `AddressOf(const_ptr[parameter.type])` + projection, and the plain `as`
    branch's contextual literal typing + projection.  A generic wrapper's
    `T as const_ptr[void]` resolves through `foreign_call_substitution` (the
    host's `binding.type_substitutions`), inferred from the call's arguments.
    Measured: **20 flips** (the raylib shader core family and
    `examples/raylib/core/vr_simulator.mt`), later +8 audio/shader/textures
    flips once the plain `as` branch projected too, 0 regressions; locked by
    `test_foreign_in_boundary_projects_to_const_ptr` and
    `test_foreign_plain_boundary_projects_the_pointer`.
8b. **The synthetic `str_buffer[N]` structs leave the IR** (the census's 17
    files): the host collects them from the type universe in the C backend.
    **DONE (session 44 batch 8, 2026-10-08)** — they ride a backend-only
    `Program.str_buffer_structs` (the 3r precedent) and the dumper no longer sees
    them; 15 files' first difference deeper (+33,141 … +400,294); locked by
    `test_str_buffer_struct_is_not_in_the_dump` and
    `test_emits_the_str_buffer_struct_from_the_backend`.
6a. **The array-of-arrays checked index** (the post-batch-5 census's 57-file
    leader): the host emits `IR::CheckedIndex` for an array element
    (`POINTS_OF_INEST[0]` over `array[array[float, 2], 6]`).  **DONE (session 44
    batch 7, 2026-10-08)** — the lowering's carve-out is gone and the backend
    emits the host's shapes (the element-pointer nested declarator, the
    `&array[index]` body, the decayed calls); +1 subset flip, 3 files deeper;
    locked by `test_array_of_arrays_element_uses_a_checked_index`.
6b. **The async frame/resume names** (the census's 22-file `async` family):
    the host uses a *double* underscore (`<…>__frame`, `<…>__resume`);
    **DONE (session 44 batch 6, 2026-10-08)** — deeper-only (+1,198 each);
    locked by `test_async_frame_names_use_a_double_underscore`.
6c. **The match scrutinee's hoist rule** (the census's 16-file bucket): the
    host hoists a `match_value` temp only for a variant with payload bindings
    and a non-duplicable expression — an enum scrutinee (`match h.kind`)
    switches on the expression itself, and the `return match …` hoist's return
    keeps the statement's path.  **DONE (session 44 batch 6, 2026-10-08)** — +4
    subset flips; locked by `test_match_member_scrutinee_switches_directly` and
    `test_return_match_carries_the_statement_path`.
5a. **A scalar-shaped constant array element folds** (the post-batch-4 census's
    57-file leader — `raylib/*`'s key tables, `projects/mtc/src`'s tables): the
    host folds `int<-Kind.A` → 0, `-1` → -1, `1 + 2` → 3; the enum member's
    value is consulted only inside the cast fold (a bare member reference keeps
    its name).  **DONE (session 44 batch 5, 2026-10-08)**; +4 subset flips;
    locked by `test_array_element_scalar_constant_folds`.
5b. **The `in`-mode and raw `external` call arguments' literal context**
    (`std/time.mt`'s `c.time(null)`): the parameter's declared type
    (`Nullable(ptr[time_t])`), via `foreign_param_context_type` shared with the
    plain path.  **DONE (session 44 batch 5, 2026-10-08)** — deeper-only;
    locked by `test_extern_call_literal_takes_the_parameter_type`.
4a. **A compile-time constant array element inlines its aggregate** (the
    `raylib/*` colour tables): the host folds `array[Color, N](c.RED, …)`'s
    elements to `IR::AggregateLiteral`s.  **DONE (session 44 batch 4,
    2026-10-08)** — the array arm folds Name-valued elements through
    `try_const_value_ir` after the contextual literal retyping; +6 subset flips;
    locked by `test_array_element_constant_folds_to_its_aggregate`.
4b. **The cstr-backed predicate recurses through `if`/`unsafe`** (the host's
    `cstr_backed_expression?`): a `let t = if flag: "a" else: "b"` local is
    cstr-backed, and a *direct* `if` argument at a `str as cstr` boundary passes
    `.data`.  **DONE (session 44 batch 4, 2026-10-08)** — `ast_expr_cstr_backed`
    used by `cstr_backed_binding` and the foreign cstr boundary; +2 subset
    flips; locked by `test_cstr_backed_if_passes_its_data_pointer`.
3ag. **Imported opaque aliases** (found by 3ae's revert, session 44 batch 1):
    `public type File = c.FILE` (`std/stdio.mt:3`, the raw module's
    `opaque FILE = c"FILE"` at `std/c/stdio.mt:5`) resolves in the self to
    `(Types::Struct :name "File" :module_name "std.c.stdio")` where the host
    has `(Types::Opaque :name "FILE" :module_name "std.c.stdio")` — the alias
    keeps its own short name and the struct kind instead of resolving through
    the imported binding's opaque declarations (the analyzer's
    `resolve_imported_type`/`type_alias_types` path).  Repro:
    `tmp/probe_flush.mt` (`lower` dump differs at the `fflush` argument; the
    self's C references `mt_opt_std_c_stdio_File`, the host's emits `NULL`).
    Sibling of 3q's `deep_alias_target`; re-check the census's alias-shaped
    buckets after it lands.  **DONE (session 44 batch 2, 2026-10-08)** — the
    foreign parameter resolves in its *declaring* module (ctx switched to
    `info.owner_module`) and is deepened + opaqueified; `tmp/probe_flush.mt` is
    byte-identical, its C emits `fflush(NULL)`, and the bootstrap's stage 2
    compiles again (fixed point holds).  Locked by
    `test_foreign_null_argument_resolves_the_alias_in_its_declaring_module`.
3af. **A local declaration's nullable-typed operand** (the post-3ad re-census's
    leader, ~51 files): `let data_ptr: ptr[ubyte] = data` keeps the declared
    `ptr[ubyte]` on the host where the self carries the `Nullable(ptr[ubyte])`
    read type into the local's value.  Repro:
    `examples/nullable_and_variant_test.mt` at its first difference
    (`String.split`'s `data_ptr`).  **DONE (session 44 batch 1, 2026-10-08)** —
    the unannotated decl's type is the host's *inference* of the initializer
    (identifiers take the binding's visible type; the recorded-type shortcut
    skips them), 216 → 228 match, 59 subset files deeper, 0 newly
    differing/shallower; locked by
    `test_unannotated_local_infers_the_guards_visible_type`.
3ab. **The match scrutinee temp** (the post-3y re-census, ~43 files): for an
    enum/struct scrutinee the host switches on the scrutinee expression
    directly where the self materializes `__mt_match_scrut_N` first.  Repro:
    `examples/box2d/bounce_house.mt` at its first difference.
3ac. **The unsigned literal's type** (the post-3y re-census, ~16 files;
    `4294967295` in a `ulong` bit op): the host types it `long`, the self
    `int`.  Repro: `examples/box3d/body_type.mt` at its first difference.
    **DONE (session 44 batch 1, 2026-10-08)** — the analyzer's narrowest-fitting
    rule (int → long → ulong), the binary-op harmonization keyed on the literal
    *syntactically* (the host's `harmonize_binary_integer_literal_types`) and
    the suffix precedence in the contextual retype; deeper-only on the corpus
    (box3d `common.mt` +75,571), locked by
    `test_bare_integer_literal_picks_the_narrowest_fitting_type`.
3z. **The explicit format sink** (the host's `std.fmt`-sink lowering; ~41
    corpus files use the shape — `std/cli.mt`, `std/terminal.mt`, the
    `projects/mtc/src` DAP/LSP modules): `std.fmt`-module calls whose second
    argument is a format string lower to a *streaming* build on the host
    (`explicit_format_sink_call_info` → `lower_explicit_format_sink_expression_statement`,
    `expressions.rb:484-560`; `append`/`write`/`assign` targets and
    `copy_explicit_format_sink_str_parts`), with no `str` result and no release.
    The self has no sink form at all (it builds a `str` and passes it) — the
    port is a subsystem.  Not yet a first-difference leader (those files'
    first differences are the array/const and field-order shapes); rank it once
    the `projects/mtc/src` leaders are closed.
3i-b. **The `break` half of the loop-flow model** — **DONE (session 43,
    2026-10-07)** (newly exposed by 3o; the box2d/raylib/sdl3 families' first
    difference, `std/str.mt`'s nested `while`).  The host emits a native
    `IR::BreakStmt` for a `break` with no cleanups (`loop_exit_statement`'s
    `:break` kind) and only falls back to the label/goto where a `switch`
    intervenes (its `switch_loop_flow`/`switch_loop_target` convert the loop
    targets to `:label` inside a match's switch, because C's `break` would exit
    the switch).  Landed: `LowerCtx.loop_break_native` (mirroring session 41's
    `loop_continue_native`) set around a plain `while` body, and
    `lower_switch_arm_body` clearing it around the arm bodies of the three
    switch-backed match lowerings (`lower_match`'s enum path,
    `lower_scalar_match`, `lower_variant_match_switch`) — `continue` needs no
    invalidation (C's `continue` reaches the loop through a `switch`).  A
    `break` now emits `IR::BreakStmt` natively, exactly where the host does.
    Measured: the shape fixture is byte-identical (`break` native in a plain
    `while`; `goto __mt_loop_break_2` inside a match's switch) and
    **`std/str.mt` is byte-identical**; the subset went 76 → 82 match (**6
    flips**: `std/str.mt`, `std/map.mt`, `std/set.mt`, `std/hash.mt`,
    `std/encoding.mt`, `examples/raylib/shapes/math_angle_rotation.mt`) with 74
    files deeper, 0 shallower, 0 newly differing, 0 lost; the full corpus went
    **83 → 91 match / 583 → 575 differ** (8 flips).  `body_move.mt`'s first
    difference moved 424,065 → 487,753 — the **3g flags/enum rendering**
    (`Types::Enum b2HexColor` vs the self's `Types::Struct`), now the top-ranked
    item.  Locked by `test_break_in_a_plain_while_is_native`.
3p. **An unnamed variant-arm construction aborts the lowering** (found while
    probing 3m; pre-existing): `V.a(1)` is host-rejected with
    `variant arm construction requires named arguments` (a *sema* error), where
    the self's analyzer accepts it and the lowerer calls
    `fatal(c"lowering: variant arm construction requires named fields")` →
    SIGABRT.  Scope: the analyzer's construction check for unnamed arm fields,
    so the lowerer's fatal is unreachable.
3n. **The async frame struct's name** (newly exposed by 3k, 2 files:
    `examples/async_network_lobby.mt`, `examples/async_stress_test.mt`): the
    host names the frame `std_net_recv_impl__frame` (a doubled separator under
    the module prefix) where the self emits `std_net_recv_impl_frame`.
3j. **The simple-path call's raw return type** — **DONE (session 43,
    2026-10-07)** (newly exposed by 3c; the raylib audio family, ~100 files).
    For `= c.getenv(name)` (a *simple* mapping) the host typed the emitted call
    with the raw declaration's return type —
    `(IR::Call :callee "getenv" … :type (Types::Generic :name "ptr"
    :arguments ((Types::Primitive :name "char"))))` — while the self used
    `info.return_ty` (the wrapper's declared `cstr?`, `Nullable(cstr)`); the
    surrounding temp/return types agreed, so only the call node's type
    differed.  Landed: `simple_mapping_callee` (the mapping's receiver/name,
    unwrapping the call/prefix-cast shapes `resolve_foreign_c_name` already
    recurses through — the *mapping* expression, not the caller's callee) plus
    the 3f lookup `mapping_call_return_type(ctx, info.owner_module, receiver,
    name)` on the simple path (`lower_foreign_call`); the wrapper's `ret_ty`
    still types the result temp and the cleanups.  Measured: the `std examples
    test` subset reads 48/473/47/0 on both binaries with **100 files' first
    difference deeper, 0 shallower, 0 newly differing, 0 lost**;
    `examples/raylib/audio/mixed_processor.mt`'s first difference moved
    209,821 → 211,625 (the branch-position foreign-call setup, above).  Locked
    by `test_simple_mapping_call_takes_the_declared_return_type` (the fixture
    dump is byte-identical to the host's).
3d. **A pointer-like foreign argument** — **DONE (session 41, 2026-10-06,
    landed with the hoisting)**.  The host lowers a pointer-typed argument at a
    pointer boundary as `foreign_identity_projection_expression`
    (`resolve.rb:1077`), whose address-taking passes through
    `lower_addr_expression` (`calls.rb:356-365`): a lowered value that already is
    a C pointer — an `IR::Name` with `pointer: true` (an editable method's `this`
    receiver) or a `*p` dereference — is cast to the boundary's pointer type
    (`(IR::Cast :target_type (Types::Generic :name "ptr" :arguments
    ((Types::Struct :name "Image" …))) :expression (IR::Name "this" … :pointer
    true))`), where the self addressed it again
    (`(IR::AddressOf … :type ptr[void])` — a wrong pointer level, `Image**` for a
    `Image*` parameter).  `addr_operand_expression` ports the rule and is wired
    into `lower_foreign_arg`'s and `lower_inline_foreign_mapping`'s
    `out`/`inout` branches; the probe also corrected session 41's `hm_discard`
    rule (every statement-position foreign call is emitted by the lowering with
    nil line/path, plain calls included).  Repro:
    `examples/raylib/core/3d_camera_fps.mt`'s `Image.format` before the fix;
    locked by `test_pointer_receiver_foreign_argument_is_cast_not_addressed`.
    The `in`/plain pointer paths keep their existing semantics (a follow-up if a
    corpus shape needs them).
3e. **The mapping-argument temp rule** — **DONE (session 41, 2026-10-06,
    landed with the hoisting batch)**.  The host temps a referenced mapping
    parameter only when
    `reference_count > 1 && !duplicable_foreign_argument_expression?` or
    `!inlineable_foreign_argument_expression?`
    (`foreign_argument_needs_temporary_binding?`, `calls.rb:1491`; plus
    `inlineable_single_direct_call_names`' single-`IR::Call` exception,
    `calls.rb:702`) and otherwise substitutes the lowered *value* into the
    mapping (`replacements`, `bind_foreign_mapping_arguments`' else branch).
    The self materialized `__mt_foreign_arg_N` for every referenced parameter, so
    `ImageKernelConvolution`'s body carried temps where the host inlines the
    `this` cast and `(IR::Member (IR::Name "kernel") "data")`.  Landed:
    `mapping_replacements` on `LowerCtx` (resolved by `lower_expr`'s identifier
    arm ahead of the locals; `member_receiver_is_local` counts a replacement as
    bound), the `duplicable_foreign_value`/`inlineable_foreign_value`/
    `mapping_reference_count` predicates over the self's IR, and
    `lower_inline_foreign_mapping`'s record-then-decide restructure; the kernel
    fixture's call body is byte-identical to the host's, locked by
    `test_mapping_arguments_are_substituted_not_tempped`.  Repro:
    `examples/raylib/core/3d_camera_fps.mt`'s `Image.kernel_convolution` before
    the fix.
3f. **The mapping call's return type** — **DONE (session 41, 2026-10-06,
    landed with the hoisting batch)**.  `walk_mapping_expr` typed an embedded
    external call with the mapping's return type; the host types it with the raw
    C function's declared return type (via its `owner_analysis`).  Landed:
    `ForeignInfo.owner_module` (set at all three construction sites),
    `mapping_call_return_type` (the owner's alias → the target module's
    `foreign function`/`external function` declaration),
    `walk_mapping_expr`/`walk_mapping_construction` threading the owner module
    and typing the call with the declared return type (the member keeps the
    mapping's).  Measured: **11 files flipped to byte-identical** —
    `std/raylib.mt`, `std/raygui.mt` and 9 raylib examples — 44 → 55 match;
    locked by `test_mapping_external_call_takes_the_declared_return_type`.
3g. **The flags/enum type rendering** (the census's new leading bucket, ~205
    files: the raylib examples' first difference at ~92% of their dumps).
    `CAMERA_PERSPECTIVE` (a flags member) renders `Types::Flags :name
    "CameraProjection"` on the host where the self has `Types::Struct :name
    "CameraProjection"` — the analyzer's recorded type for a *flags member*
    reference (`CameraProjection.CAMERA_PERSPECTIVE`-style value; the lowering
    reads the analyzer type through `expr_type`).  Repro:
    `examples/raylib/core/3d_camera_fps.mt` (the `camera` aggregate literal's
    `projection` field, byte 276,470 after 3f) at the session-41 sweep.  Scope:
    the analyzer's member-access typing for flags/enum members (the host's
    `Types::Flags`, not the struct) and whatever the lowering's
    `types.is_enum/flags` consumers expect.
4. **Event fields** — **DONE (session 40, 2026-10-06)**.  `lower_struct_decl`
   emits `IR::Field(name = "__event_<name>", ty = Types::Event …)` built from
   the runtime info (name/capacity/payload/linkage), and `lower_member_access`
   routes an event-typed member through the hidden name *and* the event type
   (`is_event_type` + `event_name_from_type` + the local `events` map),
   mirroring the host's `lower_struct_decl` (`declarations.rb:236-240`) and
   `member_c_name` (`expressions.rb:1743-1745`); the C backend's
   `by_value_dep_key` gained a `ty_event` arm returning the event's linkage
   name so the embedding struct is ordered behind the runtime definition (the
   fixture failed with "field has incomplete type" without it).  Measured:
   sweep set unchanged with `examples/event_stress_test.mt` **+737** (its
   first difference moves to 4b); locked by
   `test_event_fields_use_hidden_name_and_event_type` (fails with the change
   reverted); the `ev.mt` fixture (struct event + `emit`) builds and runs on
   both compilers, and `projects/stress` still builds and exits 242.
   Residual: a cross-module event field (`is_event_type` consults only the
   local module's `events` map) is not routed through the hidden name — no
   corpus file exercises it (only `event_stress_test` moved, and no std file
   even declares an event), but a cross-module event member access would emit
   `.closed` against the renamed C struct; fold this into 4b.
4b. **Owner-qualified event runtime naming** (newly exposed by item 4; the
   `ev.mt` fixture's first difference at byte 655, `event_stress_test`'s after
   its +737).  The host's `Types::Event#linkage_name` (`types.rb:748-756`) is
   `mt_event[_<sanitized module>][_<sanitized owner>][_<sanitized name>]` +
   `[_<sanitized payload to_s>]_<capacity>`, where `owner_type_name` is the
   declaring struct's qualified name (`type_declaration.rb:564,870`; nested
   `Container.Inner`); the self's `ensure_event_runtime` keys
   `ctx.event_runtimes` by the bare event *name* and builds
   `mt_event_<module>_<name>_<capacity>` — no owner and no payload segment, so
   **two same-named events in different structs share one runtime today** (a
   correctness bug the host does not have).  Scope: key the runtimes by
   (owner, name) — keeping the module level the nil-owner case — thread the
   owner from `lower_struct_decl` (the struct's qualified name), the member
   access (the receiver type's owner) and `decl_event`; extend the linkage
   construction with the owner/payload segments; update every `event_c_name`
   consumer (runtime struct names and suffixes, field/member types, the
   cross-module rename residual from item 4); then re-sweep
   `event_stress_test`, `nested_struct_stress_test`, `language_baseline` and
   `projects/stress`.
5. **Function-type names** (item 6) — **DONE (session 16, F5, `6ad423ce`)**:
   `ty_function` carries the callee's name, `type_to_string` renders `fn <name>`
   and `sexpr.mt` emits it.  Keep as a regression watch only.
6. **Include set/order** (item 7; `box2d/drop` and 91 more) — **DONE (session
   40, 2026-10-06)**.  The set was already right; the order was not.
   `collect_includes` now appends the raw modules' directives in the host's
   analysis-cache insertion order — a **DFS post-order from the root** with
   each module's imports visited in declaration order (the host's
   `check_path` resolves imports on demand and inserts an analysis after its
   imports; `lowering.mt`'s `emit_raw_module_includes` mirrors it over the
   analyses' `source_file.imports`), replacing the canonical module order.
   The first attempt (the host's `topo_sort_levels` shape) was wrong: the
   levels are only a scheduling frame around the on-demand DFS, and the
   `raylib_opengl_interop` include order exposed the difference (its 166-file
   shallower set).  Measured: sweep set unchanged (44/622/51/0) with **91
   files' first difference deeper** (min +8456, max +136,782: the `raylib`/
   `box2d`/`box3d`/`sdl3` examples and 42+ `projects/mtc/src` sources), 0
   shallower/newly differing; locked by
   `test_includes_follow_the_hosts_dfs_post_order` (a fixture whose post-order
   contradicts the module sort; fails with the change reverted).  Gates:
   bootstrap fixed point + 19/0, dev self-test 19/0, `test/mt` 60/0, examples
   49/49.  Not in scope: the *linker* binding flags (`build.mt`'s
   `collect_binding_flags`) — no gate compares their order and the example
   builds already link.
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
   item), staged A→D.  **Landed ahead of the stages (session 44 batch 12): the
   reference-based capture set** (`collect_proc_captures`, the host's
   `proc_capture_entries` walk — the env structs now carry exactly the body's
   referenced enclosing locals, in first-reference order; non-capturing procs
   get no env) **and the program-scoped proc/binding counters** (the
   `__proc_<N>` symbols — the function-to-proc wrapper included — number per
   compile like the host's `@synthetic_proc_counter`, and the async
   `local_match_binding_<N>` counter likewise; both reset in `lower()`).
   **8C's first half landed in session 44 batch 14**: every frame/proc-env/
   event-wait-frame allocation goes through the host's refcounted
   `mt_async_alloc`/`mt_async_free` and the C backend emits the allocator block
   when used (`mt_async_retain` is dead code on the host — no call sites); the
   host's ctor needs no zero-stores because that allocator callocs.
   **Stage A landed in session 44 batch 19** (with the stage-B naming): the
   lowering carries `ty_function(is_proc=true)` as the proc value type (the
   `mt_proc_*` struct is a backend artifact), the C backend maps the type to the
   host-named struct (`naming.proc_type_c_name`, `mt_proc_proc_int_int` with
   module-qualified elements) and the fn-pointer declarators carry the host's
   parameter names — see the batch-19 record for the measured movement (70 files
   deeper, max +666,663) and the bootstrap-caught coercion bug.
   **Stage C landed in session 44 batch 20** (the proc literal's IR shape): the
   env setup is inline in the enclosing statement stream, the literal
   materializes into a `__mt_proc_expr_N` local, and the invoke/release/retain
   bodies take the host's naming — see the batch-20 record (probe 2,963 →
   10,853, the residue was stage D; `std/toml.mt` +105,556).
   **Stage D landed in session 44 batch 21** (the contained-proc
   retain/release lifecycle) — see the batch-21 record; all six sync proc
   probes are byte-identical.  **Item 8 is complete**; the residues are the
   lazy-region `__setup_env` fallback, generic-instance field substitution in
   `contains_proc_storage_type`, and the pre-existing proc-counter numbering.
   - **A (dump-visible, low risk) — DONE (session 44 batch 19, 2026-10-10):**
     the lowering carries `ty_function(is_proc=true)` as the proc value type (as
     the analyzer does) and the C backend maps the type to the `mt_proc_*`
     struct — see the batch-19 record.  Batch 18's `tmp/async_probe.mt` widened
     the mask (its first difference at 178,016 was 8A-family): (i) a call to a
     **function-typed parameter/local** — `std/async/libuv_runtime.mt`'s
     `waiter(waiter_frame)` — emitted a bare C-name `(IR::Call :callee "waiter"
     …)` where the host emits a Name
     `(IR::Call :callee (IR::Name "waiter" :type (Types::Function …)) …)`;
     **fixed in batch 19** (the fn-typed local callee path now emits the Name
     and takes the call's type from the callee's signature); (ii) the
     **delegating `wait` chain's instances** (`std_async_wait__int`,
     `std_async_runtime_wait__int`) are absent from the self's dump — only the
     deepest implementation (`std_async_libuv_runtime_wait__int`) is emitted
     (the `find_generic_function` deepest-backend resolution in
     `ensure_async_wait_specialization`) — **still open**; (iii) the root proc's
     invoke/release/retain bodies — **still open**.
   - **B:** align the C struct name to the host's `mt_proc_proc_<ret>_<params>`
     (`c_naming.mt:95`, `proc_type_name_from_signature`).
     **DONE (session 44 batch 19, 2026-10-10)**: `naming.sanitize_c_identifier`
     + `naming.proc_type_c_name` produce `mt_proc_proc_int_int` with
     module-qualified elements (and the fn-pointer declarators carry the host's
     parameter names).
   - **C:** IR shape — inline env setup and switch to `mt_async_alloc/free`.
     **DONE (session 44 batch 20, 2026-10-10)**: the env setup is inline in the
     enclosing statement stream (the `__mt_proc_expr_N` naming scheme included)
     and the capture allocator is the refcounted `mt_async_alloc`; the
     invoke/release/retain bodies take the host's `env`/`__mt_proc_env_ptr`/
     `__mt_capture_<name>` naming.  The `__setup_env` function remains only as
     the lazy-region fallback.
   - **D (highest risk):** port the contained-proc retain/release lifecycle
     (`lowering/proc.rb:276-362`: local decls, struct fields, async frames; the
     self-host has none today).  **DONE (session 44 batch 21, 2026-10-10)**:
     the walkers (`contains_proc_storage_type`, the guarded/unguarded
     release/retain and the selective-retain rule), the local-decl release defer
     + non-fresh retain, the assignment's `proc_assign` temp, the return's
     retain, the env's capture retains and the async ctor/release/cancel
     variants — see the batch-21 record; all six sync proc probes are
     byte-identical and the probes run identically on both compilers.  Residues:
     the lazy-region `__setup_env` fallback, generic-instance field substitution
     in `contains_proc_storage_type`, and the pre-existing proc-counter
     numbering (`language_baseline.mt`'s `modvar_proc` is `__proc_10` on the
     self, `__proc_1` on the host).  Verify against the host's lifecycle cases
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
   nothing parses it today — a stray `16` lands in the path slot and the run dies
   "not a directory: 16") and `--cc/--profile/--platform` for `test` (port
   the host's fork-per-file, order-preserving parallel runner,
   `cli/commands/test.rb:281-335`; `build` already honors `--cc`); the same
   function also rejects **file** arguments the host accepts (`mtc test
   path/file.mt` → "not a directory: …"; the host runs that file).  All three
   survived the CLI sweep — `cli_parity.rb` does not exercise `test`'s argument
   forms, so a green `cli` column does not cover this command.  Session 44
   worked around the directory-only limit for the gate (one-process-per-file via
   temp one-file dirs, `gates_dev_tests`);
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

1. **Debug map (prerequisite).**  **Emission landed (session 34, 2026-10-04)**:
   `projects/mtc/src/mtc/debug_map.mt` ports the host's model + writer + loader
   (`lib/milk_tea/tooling/debug_map.rb`: Entry/Function shapes, `from_ir`,
   `collect_locals`, `first_statement_*`, relative payload paths, tolerant
   `load_for_binary`), `build.mt`'s success branch writes
   `<output>.mtdbg.json` (a write failure only warns — the binary stays the
   deliverable), and `projects/mtc/test/debug_map_test.mt` locks the model and
   the write→load round trip.  The self's map is semantically equal to the
   host's on the smoke fixture.  The DAP-side frame/variable/expression
   rewriters (host `dap/server/debug_map.rb:45–225`) land with item 4.
2. **Build-on-launch.**  **Landed (session 34, 2026-10-04)**: `dap/utilities.mt`'s
   `resolve_launch_program` compiles a `.mt` source with the running compiler
   (`/proc/self/exe build <abs.mt> -o <tmp>/<stem> --profile debug
   --no-debug-guards`, the host's `debug: true, debug_guards: false`) into a
   fresh `milk-tea-dap-*` temp directory; `Session.tmp_dirs` remembers it and
   `cleanup_tmp_dirs` removes it on terminate/disconnect (host
   `dap/server/launch.rb:125-137`, `utilities.rb:149-155`).  A failed build
   becomes the launch error response and removes the temp dir.  The binary
   cache carries the sidecar (`build_cache.store`/`materialize`), so cached
   builds keep their map where the host skips it.  The `process` event's
   `name` is now appended (it was emitted empty).
3. **Pause diagnostics + `modules`.**  **Landed (session 34, 2026-10-04)**: a
   pause-requested stop issues the 8-level `stackTrace` and emits the host's
   console `output` summary (`pause_diagnostics.rb`'s informative-frame
   selection and formatting ported), the SIGSTOP exception stop is rewritten
   to `reason: "pause"`, and the `modules`-driven map fallback loads a sidecar
   from the adapter's module list when a stackTrace arrives without one.
   `modules` is dispatched through the generic forwarding path.
4. **lldb-dap bridge (largest/riskiest).**  **Landed (session 34, 2026-10-04;
   frame/variable/expression rewrites, breakpoint sync and pause diagnostics
   included)**:
   `dap/lldb_backend.mt` (transport: spawn, Content-Length framing to the
   adapter's stdin, pending request table with 5 s deadlines, the 15 s reverse
   table) + `dap/lldb_policy.mt` (policy: deferred client initialize with the
   merged capabilities, suppressed adapter `initialized`, launch/attach
   forwarding with `backend_start_arguments`, `configurationDone` gating on the
   start response, terminate→disconnect fallback, generic forwarding, event
   rewriting, `--adapter-path` parsing with `.rb`→ruby).  `server.mt` registers
   a poll handle for the adapter's stdout when it starts, drains it in `pump`,
   and routes client responses for reverse requests.  `tools/dap_smoke.rb`
   drives an embedded fake adapter on both servers: every row matches except
   the two the remaining items cover.
5. **Verification.**  **Landed (session 34, 2026-10-04)**: `tools/dap_smoke.rb`
   carries a fake-adapter section (an embedded port of the host's test fake,
   `runInTerminal` reverse request included) and a real-lldb section that
   builds the `.mt` source with *each* server so each side's own debug map is
   in play: breakpoint → `stopped(breakpoint)` → `stackTrace` (Milk Tea frame
   name + `.mt` source) → scopes/variables → `evaluate` → `next` → `continue`
   → `exited`/`terminated`.  The full matrix is zero differing rows except one
   documented self-better row.  The live VS Code F5 remains the manual check;
   the extension's argv order was fixed (`adapterPath` now follows the `dap`
   subcommand instead of preceding it, which both CLIs rejected).
6. **Terminal event order (measured 2026-10-03); unified loop (session 34).**
   **Landed**: the process backend now emits `terminated` then `exited` with the
   real exit code (the host's order), and the debuggee starts at
   `configurationDone` (the host's `maybe_start_or_stop_on_entry`; `continue`
   starts it after an entry stop, `pause`/`continue` SIGSTOP/SIGCONT,
   `terminate`/`disconnect` SIGTERM and let the exit produce the events).  The
   blocking stdio reader became a `Framer` over raw fd reads
   (`std.process.read_fd`) driven by a libuv loop: a poll handle on fd 0 plus a
   100 ms wake-up timer, with frames dispatched and the child drained between
   loop turns.  `dap_smoke` is row-for-row equal on the process backend
   (including `events`); a stopOnEntry → continue probe matches the host;
   valgrind on the loop reads 0 errors.

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

- **F9 readiness foundations (C2/C3)** — **DONE (session 30, 2026-10-04)**:
  `release_scan_facts` frees one token scan's tables (the ~20 maps/vecs, the
  binding and type-parameter vectors, and a `key_storage` vector that owns the
  composite `<alias>.<member>` / `<Type>.<field>` keys), called at both build
  sites; the reference index bounds its retained text
  (`max_retained_bytes`, 32 MiB default) by dropping the oldest documents with
  their hash/stamp entries, and `note_document_tokens` indexes open buffers
  without a copy and skips an unchanged closed document by its recorded
  `(mtime, size)` (`DocumentStamp`); hashes/stamps update in place and
  `forget`/eviction release their map keys.  Measured: valgrind 0 errors over
  the 68+19 harness drive (7,138,997 B definitely lost — the analyzer's
  per-analysis small strings, not these tables).  Record: §0k session 30.
- **C4 large files/workspaces** — the driver landed (session 30):
  `tools/lsp_soak.rb` generates a ~5k-line synthetic workspace and drives
  mixed requests (`--cycles 2500` is the ≥10k-request target), reporting the
  RSS slope; the `soak` meter gate runs a short version per commit.  **The
  per-request parse sites are routed through the shared caches (session 37,
  2026-10-05)**: the full-cycle slope went **11.4 → 3.96 MB/cycle** (the gate's
  `--cycles 200` read **3.98**, was 11.5) on the same workspace — the token
  path, navigation's 18 sites, references, completion, the hierarchies,
  symbols, signature help, highlight, rename, linked editing, inlay hints and
  the index's per-edit re-index now take the AST and analysis from
  `workspace.document_analysis_for`/`analysis_entry_for` (the loader entry when
  the document loads; the single-file parse cache otherwise) instead of parsing
  per request.  **The residual RSS growth (~3.9 MB/cycle, every mode alike) is
  the per-edit loader parse+analysis leak** — the parser/analyzer allocate with
  `heap.must_alloc` "one file per run and exits" — true for the CLI, not for a
  long-lived server.  A real ceiling needs per-parse ownership (an arena the
  LSP can release when a superseded cache entry is replaced); the valgrind
  attribution (session 37) shows the dominant blocks are the lexer's
  `Vec[Token]` buffers and the parser/analyzer vectors, and the replaced
  entries' *heap copies* are already released (`release_entry_analysis`) —
  what is missing is ownership of the AST/analysis internals.  **Landed in session
  38 (2026-10-05).**  Part 1 released the parser and lexer scratch buffers (the
  two token vectors, the name maps, `pending_decls`, the indent stack; 3.96 →
  3.17 MB/cycle).  Part 2 added the `heap.Region` growable bump allocator and
  the scoped heap routing (`begin_region`/`end_region`; region-owned
  `release`/`resize` semantics), locked by `heap_region_test.mt`.  Parts 3–4
  gave every module-cache entry a parse and an analysis region and the parse
  cache its own region, quarantined superseded regions to the request boundary
  (`retired_regions` + the server-loop drain), and released the residue the
  measurements exposed (the linter's per-body `Cfg`, `didChange`'s source copy,
  the diagnostic-cache/publish/pull strings, per-run Program containers).  The
  soak is **68 KB/cycle raw / 19.9 LS at `--cycles 200`** (level 656 → 33 MB).
  Remaining, documented: the workspace-index walk's one-time arena-leaked ASTs
  (a level, not a slope) and the loader's small `qname_to_str` lookup strings;
  the deliberate-difference row for the reference-index bound stays.  Record:
  §0k session 38; §0k session 37; §0k session 30's "Soak profile and the long-session blocker".
- **C5 client behaviours** — **DONE (session 31, 2026-10-04)**: the harness's
  stress section now measures six client-behaviour probes (`c5/…`):
  `references` with `includeDeclaration: false`, a `didChangeConfiguration`
  formatter-mode switch (and back), a watched file created on disk, a
  `$/cancelRequest` for an unknown id, an added workspace folder, and a
  closed-file disk edit (hover before/after, no notification).  Two real gaps
  surfaced and were fixed: the self ignored `settings.milkTea.format.mode` in
  `didChangeConfiguration` (it now applies it with the host's fallback paths),
  and a watched-file change never entered the workspace symbol index (changed
  paths are now marked dirty and their definition/reference entries dropped).
  Every probe is byte-equal to the host now; the two fixes are in
  `workspace_notifications.mt`.
- **C6 deliberate differences, one table** — **DONE (session 31)**: the
  canonical table is in `docs/lsp-design.md` §8 (12 rows: the malformed-frame
  recovery, synchronous facts, cold start, parser-recovery layout, the host's
  `documentSymbol` race and the three warm-facts artifacts, the directory-form
  `typeDefinition`, the two completion residues, the reference-index bound and
  the `debugInfo` remainder), each with its direction and the tool that pins
  it, plus the verification checklist.
- **D2.** — **DONE (session 31)**: `tools/lsp_project_audit.rb --canonical`
  sends the whole request history twice and records the second pass, pinning
  the warm-up history; two canonical runs return **identical** differing sets
  (verified), and the canonical run replaces the ±drift as the verification
  mode (see the record).  **D3 is done**:
  `tools/parity_scoreboard.rb` has an `lsp` section (`--full`).  D4: keep the
  standing gates exactly as this file's protocol and AGENTS.md list them (the
  gates keep the fast non-canonical audit; use `--canonical` when verifying a
  fix).
- **Stage-plan residue (absorbed; verify each against §0k before starting):**
  - **per-module `ModuleCache`** (edit-latency foundation) — **DONE (session 29,
    2026-10-04)**: `lsp.Workspace` owns a `loader.ModuleCache` keyed by resolved
    path → `{content_hash, the parsed module (owned source, AST, lex/parse
    diagnostics), version, analysis, ModuleBinding, direct-import paths +
    versions}`; `check_program_with_source` consults it, `parse_all` reuses a
    module whose content hash matches, and the check loop reuses an analysis
    when the module's import-path list matches its snapshot and every forward
    import's version matches (cycle back-edges skipped).  The workspace's
    per-root Program entries are validated against the cache's generation
    (`change`/`open`/`close` bump it), so an edit anywhere invalidates
    dependents' cached Programs and the rebuild re-analyzes exactly the edited
    module's dependent closure.  The same change closes a pre-existing parity
    gap the probe exposed: imported modules now parse from **open editor
    buffers** when present (the host's `source_overrides`), not disk.
    **Measured: 54.3 → 5.0 ms median per edit** on `SimpleGame/src/main.mt`
    (target ≤ ~10 ms; `didOpen` unchanged at ~52 ms); the dependency-edit probe
    (direct + two-hop + create/restore; `tmp/lsp_dependency_probe.rb`) went 3
    FAILures on the pre-change binary → all PASS; the LSP fixture sweep closed
    22 entries across the probe workspaces (0 added); valgrind: 0 errors over
    the 68+19 harness drive.  Record: §0k, "The per-module `ModuleCache`"
    (session 29).
  - **`reserved-primitive-name --fix` use-site renaming** (stage 8) — **DONE
    (session 28)**: the linter now collects the host's
    `ReservedPrimitiveNameFix` set — a fix per module-level binding
    (function → `_fn`, import alias → `_module` via
    `RESERVED_IMPORT_ALIAS_NAMES` = `Option`/`Result` only, everything else →
    `_value`), per local and per parameter — with the declaration site plus
    every identifier use, attributed through the scope walk (an identifier that
    resolves to a local records against *that* binding, so a shadowed module
    binding keeps only its declaration), the host's `_2`/`_3` conflict
    resolution against the visible names, and the warning's column/length.
    `--fix` applies every site right-to-left (`apply_reserved_name_fixes`), and
    the LSP's quickfix is the host's multi-edit `Rename 'x' to 'y'` action,
    matched by declaration site.  Locked by the harness's
    `codeAction/reserved-name` entry and three `fix_engine_test.mt` cases
    (uses, conflict, shadow).  **Residue**: the CLI `--fix` path lacks the
    host's unresolved-import guard (`fix_source_single_pass` returns the source
    unchanged when an import did not resolve), so on such files the self still
    applies fixes the host withholds (Track 2); and the analyzer's own
    reserved-name errors differ (Track 2).
  - **`prefer-inline-methods` auto-fix** (stage 10) — **DONE (session 28)**:
    `prefer_inline_methods_edit` ports the host's `prefer_inline_methods_edits`
    (the struct's last member + a blank line + the `extending` block's method
    lines, one whole-range edit; non-adjacent layouts are left alone), and the
    code is in `fixable_codes()`, so `--fix`, `source.fixAll` and the quickfix
    all see it.  The same commit ports the host's
    **`validated_fixed_source`** guard: a pass is kept only when a fresh
    analysis of the fixed source adds no error signature (line, column,
    message), which is what makes the host refuse batches whose stale line
    numbers overlap.  Locked by two `fix_engine_test.mt` cases (the canonical
    inline and the non-adjacent no-op) and a host-vs-self `--fix` sweep
    (15 examples × 12 rules: 179/180 identical; the one divergence,
    `reflection_advanced.mt` `prefer-let`, is pre-existing — the host rejects
    the rewrite because its analysis flags an editable-method call the self
    does not, Track 2).  Known residue: on a file that carries a
    *member-assignment immutability* error the host rejects the batch where
    the self accepts it — same root cause (the missing check, Track 2).
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
  - **`--timings` breakdowns** (stage 18) — **DONE (session 31, 2026-10-04)**:
    the host's shapes are implemented on a shared `mtc.profile.Profile` (the
    host's `Linter::Profile`): `format` records `format`/`format.lex`/
    `format.parse`/`format.ast` or `format.cst`/`format.cst_fmt`/
    `format.normalize`/`format.wrap`/`format.blank_lines` per mode and prints
    `format profile <path>: <ms>ms (<phases ≥ 0.1ms, descending>)`; `lint`
    records per-rule (`rule.<code>`) and structural phases and prints the
    host's `lint profile <path> (lint scan|pre-fix scan): rules=… total=…`,
    the per-rule rows (`<code>: <n>x total=… avg=… share=…%`, 12 rows), the
    `non-rule hot phases` line, then the `Profile (lint): N file(s)` block and
    `Total:`.  Verified shape-by-shape against the host on
    `examples/language_baseline.mt` and a fix run; the numbers themselves are
    not compared (nondeterministic).  Record: §0k session 31.
  - **Quickfix extras** (stage 16) — **DONE (session 28)**: the whole
    per-diagnostic branch set now mirrors the host (`code_actions.rb:29-297`)
    with byte-equal titles (the host's `STATIC_QUICK_FIX_TITLES` table,
    including the `null` title for `unused-import`), every action echoing the
    request's diagnostic object (`diagnostics: [diag]`), the new
    `Cast expression to <type>` action (the host's line rewrite with its
    doubled indent reproduced exactly) and the `Import <path>` action (the
    `data.suggestion` "did you mean" path); `shadow` is the host's
    annotation-only action, `unused-param` renames to `_x`, the unsafe wrap
    uses the host's block body and `Wrap statement in unsafe block` title,
    the match-arms action carries the case list in its title and inserts
    after the match, and `source.fixAll` is titled `Apply all auto-fixes`.
    Locked by the harness's `codeAction/quickfixes` entry (nine manufactured
    diagnostics, one per branch — every action byte-equal) and the fix-engine
    LSP shapes (whole-line rewrites now carry the host's exact ranges/texts:
    `prefer-let`, `prefer-let-else`, `redundant-else` — whose buffer scan had
    to stop treating `split_lines`' trailing empty element as a body line —
    and `prefer-inline-methods`).
    **Residue**: `reserved-primitive-name`'s quickfix still renames only the
    declaration site (stage 8's multi-site rewrite is the open item), and the
    analyzer produces no "did you mean" suggestions, so the `Import` action
    only fires for diagnostics a client sends.
  - **`milkTea/debugInfo` byte-parity** (stage 17, highest-risk; **first half
    landed in session 33, second half in session 35**) — **DONE**: section
    order/envelope (the self-only `Workspace` section is gone), the **histogram
    tie order** (MRI's *uniform* introsort — `rb_uniform_intro_sort_2`; the old
    "port `ruby_qsort`" note was wrong, see the session-33 record), the
    **Diagnostics** section, the **AST** section (`format_ast`/`compact_ast_repr`
    + the host's node-id semantics, the cached `SourceFile` header and the
    dropped `node_path_ids` map), and now the **Facts** section (ordered
    types/interfaces/functions/values/methods/imports, `ValueBinding` ids and
    the host's function/method binding shapes) and the **Bindings** section (the
    host's binding-id allocation order, identifier/declaration sites, binding
    types, the 30-entry cap) — plus the harness `normalize` extension for Ruby
    `object_id` values.  All byte-equal on the harness fixture (session 35).
    Residue: the self's expression *literals* have no line/column, so the host's
    locations for match-arm headers and `RangeExpr` columns differ where the
    pattern/bound is a literal (a parser-wide AST change if pursued);
    `examples/language_baseline.mt`'s node count reads 6759 vs 6760; generic
    *instances* and foreign-boundary alias params allocate no binding ids where
    the host's do, and callable-value member-access sites are not counted
    (`callable_value_member_access_sites` always renders 0) — all invisible on
    the fixture, all recorded in the session-35 record.
  - **The linter's `:fast`/`:full` tier flag** (stage 11's first half) —
    **DONE (session 31, 2026-10-04)**: `LintOptions.lint_tier` (`LintTier.fast`/
    `full`, default `full`, so the CLI and LSP behave exactly as before) with
    the host's `full_tier?` gating: the per-body flow rules (dead-assignment,
    unreachable, borrow, constant-condition, redundant-null-check,
    loop-single-iteration), the If/Match preference rules (`prefer-inline-if`,
    `prefer-conditional-expression` (if and match), `prefer-or-pattern`,
    `prefer-try`, `prefer-is-variant`), `prefer-struct-with` and `doc-tag` are
    full-tier only; the release rule is full-tier only in **proc** bodies (the
    host's `visit_function`/`ProcExpr` asymmetry); everything else runs in both.
    Locked by three `linter_test.mt` cases (fast skips the flow rules, full
    runs them, fast keeps an always-on rule).  Diagnostics scheduling stays out
    of scope, as planned.
- **Canonical-audit residue (session 31, warm-state; the references half closed
  in session 36)** — the canonical (warm-up) audit's differing set is the honest
  steady-state one; beyond the documented rows it surfaced:
  - **Four `references` entries** (`docs/data_structures.mt@34:25`, `@112:29`,
    `@167:37`, `@195:37`) — **CLOSED (session 36, 2026-10-05)**: the host's warm
    list included many more `std/` files (25 entries vs the self's 4 at
    `@34:25`; e.g. `binary_heap`, `graph`, `sparse_set`) because the self's
    static-method reference candidates came from the workspace index alone,
    while the host's `reverse_import_dependents_for` covers every document it
    knows.  `reference_index.documents_importing` (the import names each noted
    document carries) plus the name-based `dependent_documents` now match the
    host: canonical **10 → 6 differing entries, closed 4, added 0**; the
    non-canonical set is unchanged (5 → 5, the documented 4 + drift).  Record:
    §0k session 36.
  - **Two `hover` entries** (`ds@140:33`, `colors.mt@12:46`, builtin `str`):
    once the host's definition index warms it appends
    `Defined at: std/str.mt:58` to builtin-type hovers; the self omits
    builtin/std type locations — the same family as the documented
    `type quat` row (an eager fix was measured at 153 extra entries and
    rejected, session 18).
  The hover rows are not a regression from session 31 (its changes do not touch
  hover); they were previously invisible because the non-canonical audit sampled
  different positions and ran with the host's index only partially warm.
  Record: §0k sessions 31 and 36.
- **Imported enum/flags member locations (session 32, deferred)**: for
  `alias.Enum.member` the self resolves the member text but deliberately drops
  the location — the host's `type_name_member_access?` classifier misses the
  aliased receiver, so its hover has no `Defined at` and its go-to-definition
  is the generic fallback, and the self matches that.  Pointing both at the
  imported declaration would be a documented self-better difference (the
  machinery is in `imported_enum_member_result`, which computes the declaration
  and then clears it) — decide and document it, don't drift into it.
- **The documented entries stay documented** unless their machinery is built for
  another reason: the harness's 4 (host parser recovery,
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
  stage3, 19 test files / 0 failed), `build/stage2/mtc test test/mt -I .` (60/60), 15/15
  examples, 34/34 sdl3, 217/219 raylib, vendored families, `sexpr_parity`
  lex/parse/lower, `cli:parity`, both LSP harnesses + valgrind + a Neovim and a
  VS Code session, `dap_smoke` on both backends, `format_parity all`,
  `imported-bindings --all --check`, the lint corpus, and
  `~/Projects/MilkTea/SimpleGame` building and running.
- Update this file's header, records and ledger; `docs/lsp-design.md`,
  `docs/dap-design.md` as their areas change.
- Declare done only when the Ledger shows every counter at its target.

### Track 9 — compiler throughput (not parity; it prices every gate)

The self compiles the compiler's own sources in **157 s** (`emit-c` of
`projects/mtc/src/mtc/main.mt`) where the host takes **40 s** — a 3.9× gap, and
every `bootstrap.sh` pays it twice (the stage2 and stage3 builds).  After the
session-44 tooling pass it is the single biggest line item in the gate loop: a
full bootstrap is ~26 min, `--fast` ~12 min, and ~10 of those minutes are the two
self-builds (~5 min each at load).  One session profiling the self's
front-end/lowering/C-emit on its own sources (candidates: repeated
analysis/type resolution per module, the string-heavy rendering paths, the C
emitter's text building) buys every future gate back several minutes; nothing
else does.  **Not a parity item** — behavior must not change, only wall time.
Verify with `emit-c` timing plus the fixed point.

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

Newest verified numbers (session 44 batch 21, 2026-10-10; per-gate dates in the
rows) — re-measure only the
classes a change can move, and only when the tree moved.  Target = the
definition of done above.

| Gate | Live | Target | Command |
| --- | --- | --- | --- |
| bootstrap fixed point | holds (2026-10-05 session 38 part 2 — `stage2.c == stage3.c`); self-test suite 19 files / 0 failed (session 44 re-measured green across all ten items; `--fast` re-verified `stage2.c == stage3.c` at 11.7 min) | stay green | `tools/bootstrap.sh -j 16 --fast` (per batch; the full form also runs the suite) |
| `test/mt` | 60 files / 0 failed (re-run 2026-10-05 session 35) | stay green | `build/stage2/mtc test test/mt -I .` |
| examples / sdl3 / raylib | 15/15, 34/34, 217/219 (emit-c sweep re-measured 2026-10-05 session 35: 49/49 same, 0 differ) | stay green | per-family sweeps |
| `sexpr lex` / `parse` | 712/712; 708 comparable / 0 differ (session 33; the session-35 scoreboard re-read `parse` 712 match / 0 differ of 716 files — counts drift with the tree's own sources) | stay 0-diff | `ruby tools/sexpr_parity.rb lex\|parse -q --host-cache tmp/sexpr-host-cache` |
| `sexpr lower` | **479 match / 187 differ / 51 host-rejected / 0 self-rejected of 717 files (session 45 batch 14, 2026-11-03 — fourteen batches; batch 14 is the foreign-call component protocol (the three-pass `bind_foreign_mapping_arguments`: public-alias reuse/`foreign_arg_public`, value preparation, `foreign_arg` temps), the `prepare_foreign_in_argument` hoist on both the mapping and simple paths, the cstr assignment-metadata refresh, and the nested `foreign_result` materialization (a statement-root call still stores directly): 467 → 479 (+12), 0 new differing files; 742 tests.  Batch 13 is the variadic foreign `str` argument's cstr projection (`text_format(c"%s", value)`: a string literal becomes a C string literal, a cstr-backed value passes its `data` pointer in an `IR::Cast(cstr)`, anything else takes the malloc temp): 454 → 467 (+13), 0 new differing files; 739 tests.  Batch 12 is the prefix-cast constant fold (`uint<-MoverBit` → 2 with the host's width/signedness wrapping, so the box2d `categoryBits` field gets its outer `ptr_uint` cast) and the prepared `and`/`or` shape (a setup-producing operand hoists a `__mt_and_N`/`__mt_or_N` result local and guards the right operand with `if result` / `if not result`): 444 → 454 (+10), 0 new differing files; 738 tests.  Batch 11 is the contextual numeric compatibility (a folded constant that fits the declared type, int→char, the declared-float int→float arm skipped for a foreign-call initializer, and the external-numeric assignment pair), the synthetic proc/worker functions' program-level creation-ordered tail (after every module's functions; the compiler-source subset 49 → 63), and the propagation failure return's `line nil`/path set: 420 → 443 (+23), 0 new differing files; 736 tests.  Batch 10 is the explicit format sink 3z (all three forms, the host's four-argument `mt_str_buffer_clear`, the `String.as_str`/`str_buffer.as_str` aggregate views, and the custom-hook slice form), the deferred local/assignment format release (the host's `local_defers`; a foreign call's temp free stays immediate), the non-owning `return f"..."` release + `__mt_return_value_N` (an owning `str` return drops it), the assertion condition's prepared setup, and the signed literal's declared context type: 414 → 420 (+6), 0 new differing files; `test/mt/fmt_test.mt` is byte-identical.  Batch 9: the foreign mapping's fixed literal argument typed against the raw C parameter (`= c.SDL_RunApp(..., null)`'s null is `Nullable(ptr[void])`), the compile-time constant range-for stop, the lazy generic-method specialization's saved/restored caller format state (`fmt_dest_name`/`fmt_counter`/`fmt_counter_visible`/`cstr_backed_names`; the body gets fresh maps), the guard local's storage binding as the block's format destination, and the mixed-signedness integer promotion (`uint` vs `int` → `long`): 405 → 414 (+9), 0 new differing files.  Dev suite 19/0, 726 tests; bootstrap fixed point, `test/mt` 60/0, examples 49/49, LSP harness 30/30 + 4 documented, recovery OK re-verified on the batch's frozen tree.  Batch 8: the flow replay's bookkeeping (the multi-line post-state replay no longer advances `flow_recorded`), the prepared match expression (`__mt_match_expr_<N>` + its switch in the statement's setup), the `_` local's host declaration (`__mt___N`), and the conditional's expected/common type (pointer-sized ints fixed-width 64, the host's numeric common type + compatibility fallbacks, `expected_type_hint`, signed-literal harmonization): 385 → 405 (+20), 0 new differing files.  Batch 1: the monomorphized-call literal's contextual type (`lower_plain_call_spec`), the async main's public `std.async.wait` chain, the rendered-argument instance sort (3ad), the imported arm payload's owner module, the plain `IR::Index` for `as_span()`, the flow-refined assignment target (`flow_type_at_position` + substitution, the plain-target equality case keeping the binding's type), and the `undo_redo.mt` regression check.  Batch 2: the assertion intrinsics' messages/statement shape, static-method-call literal typing, the switch-arm `continue`'s loop label, the iterator-loop binding's nullable storage projection, the pointer-intrinsic casts, and function-reference type names.  Batch 3: the hash-hook `const_ptr[T]` argument casts and the implicit `ref[T]` argument bridge.  Batch 4: item 8a's foreign boundary projection (the `in`/plain `as` argument takes `AddressOf(const_ptr[parameter.type])` and projects to the declared boundary; the generic wrapper lowers under its inferred call-site substitution), the tuple match expression's nested else-chain, the unannotated local's foreign-wrapper return type, and the guarded identifier's flow-refined visible type.  Batch 5: the guard local as a prepared position (the initializer's foreign-call temps hoist before the storage local; the storage type is the host's inference — the wrapper's declared return), the `?` propagation's typed failure member chain (`data` nil, the arm payload, the error field) and return path, and the propagation success local (`LocalDecl <name> = <projection>`).  Batch 6: the loop-exit defer flush (a `break`/`continue` with loop-scoped defers emits the cleanup + label goto, the host's `lower_loop_exit`).  Batch 7: the variant equality-pattern guard's present empty else (`else_body ()`).  Measured: **286 → 385 match / 380 → 281 differ**, +99 flips (286 → 302 → 338 → 340 → 375 → 383 → 384 → 385), 0 regressions (before/after differing-set comparisons against `tmp/mtc-head`; one batch-1 regression, `examples/raylib/core/undo_redo.mt`, was caught and fixed inside the batch); `tmp/async_probe.mt` first difference moves 199,968 → 229,310 and is content-complete (the delegating chain exists; the residue is late-instance placement); the creator-tracked wave model was tried and reverted (corpus 264); `projects/mtc/src/mtc/build.mt`'s first difference 483,301 → 5,024,041; bootstrap fixed point holds, dev suite 19/0 (23 new tests), `test/mt` 60/0, examples 49/49, 716 tests)**.  286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 21, 2026-10-10 — 8A stage D: the contained-proc retain/release lifecycle (a proc-containing local's guarded release defer + the non-fresh initializer's retain, the `proc_assign` temp's selective retain + old-value release, the returned value's retain before the defers, the proc-storing capture's retain in its env, and the async frame's ctor param retains + release/cancel proc-field releases).  Measured: all six sync proc probes are **byte-identical** (`tmp/proc_probe.mt`, `tmp/proc_let_probe.mt`, `tmp/proc_fn_probe.mt`, `tmp/proc_sort_probe.mt`, `tmp/probe_b13.mt`); `tmp/async_probe.mt` stays at 199,969 (the delegating `wait` chain); the corpus set holds 286/380/51/0 and the dumps move closer (`examples/language_baseline.mt` 1,717,013 → 1,742,976 of the host's 1,760,611; `test/mt/vec_test.mt` 675,596 → 680,290 of 687,612), 0 flips / 0 regressions / 0 shallower; the probes build and run identically on both compilers; the bootstrap fixed point holds, dev suite 19/0, `test/mt` 60/0, examples 49/49)**.  286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 20, 2026-10-10 — 8A stage C: the proc literal's env setup is inline in the enclosing statement stream (the host's `lower_proc_expression_for_local` shape — a `__mt___mt_proc_expr_<N>_env_<M>` local from `mt_async_alloc(sizeof(env))`, `__mt_ref_count = 1`, the capture stores), the literal materializes into a `__mt_proc_expr_<N>` local (the host's `materialize_prepared_expression`; the `__setup_env` function survives only as the lazy-region fallback), and the invoke/release/retain bodies take the host's naming (`env` param, `__mt_proc_env_ptr`, `__mt_capture_<name>`).  Measured: `tmp/proc_probe.mt` 2,963 → 10,853 (residue = stage D's lifecycle), the new `tmp/proc_let_probe.mt` starts at 8,149, `tmp/proc_fn_probe.mt` and `tmp/probe_b13.mt` stay byte-identical, the proc probes build/run identically on both compilers; the corpus set holds with 2 files' first difference deeper (`std/toml.mt`, `test/mt/toml_test.mt`, +105,556), 0 flips / 0 regressions / 0 shallower; the bootstrap fixed point holds, dev suite 19/0, `test/mt` 60/0, examples 49/49)**.  286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 19, 2026-10-10 — 8A stage A: a proc value's IR type is the closure's `ty_function(is_proc=true)` (the dumper's `Types::Proc`, the analyzer's form) instead of the `mt_proc_*` named struct, which becomes a backend artifact; the C struct name is the host's `proc_type_name` (`mt_proc_proc_int_int`; elements module-qualified, so `std.toml.Entry` and `std.json.Entry` no longer collide — `naming.sanitize_c_identifier` + `naming.proc_type_c_name`); the backend maps the type to the struct (`c_type`/`c_declaration`/the array-element case/`by_value_dep_key`) and the fn-pointer declarators carry the host's parameter names; the proc struct's `invoke`/`release`/`retain` field types take the host's named shape and the proc-call `invoke` member is typed with it; a call to an `fn`-typed local emits the host's Name-typed callee with the call's type from the callee's signature.  Measured: `tmp/proc_fn_probe.mt` is **byte-identical**, `tmp/proc_probe.mt` 731 → 2,963, `tmp/async_probe.mt` 178,016 → 199,969 (the probes build and run identically on both compilers), `tmp/probe_b13.mt` stays byte-identical; the corpus set is unchanged with **70 files' first difference deeper** (max +666,663: the compiler's own sources, `std/net/*`, `std/toml.mt`, `std/tar.mt`, `projects/tetris`), 0 flips / 0 regressions / 0 shallower; the bootstrap fixed point holds (it caught the fn→proc coercion bug: `coerce_monomorphized_arg_to_proc` passed the bare name's plain `fn` type), dev suite 19/0, `test/mt` 60/0, examples 49/49)**.  286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 18, 2026-10-10 — 10l and the async runtime shapes: the host's inline `async_complete_statements` (result store, ready, waiter wake, return) replaces the completion label/goto in every async resume — the no-await path included; the no-await resume drops its `__mt_result` local and its label; the release gains its not-ready guard and the per-await release shape; set_waiter types its Names with the wake function type; cancel gets the host's full body (`ExpressionStmt(Assignment)` via the new `ir.Expr.expr_assignment`); Task member accesses carry the Task struct's field types; an async `main`'s ctor linkage is `<module>___async_main` — `tmp/probe_b13.mt` is **byte-identical**, `tmp/async_probe.mt` moves 23,882 → 178,016 and both compilers' built programs run identically (async main, awaits, `?` propagation, waiters); the corpus set is unchanged (26 async-family dumps change behind item 8A's mask; 0 flips / 0 regressions / 0 shallower); the bootstrap fixed point holds, dev suite 19/0, `test/mt` 60/0, examples 49/49)**.  286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 17, 2026-10-10 — 10j/10k: the ctor aggregate's vtable entries take the host's names (`<ctor>__<role>_fn` name, `<ctor>__<role>` linkage), the resume's `<name>__resume`, the aggregate's field types (the vtable signatures) and the host's param names (`frame`/`__mt_frame_raw`, `waiter_frame`, `waiter`) — the probe moves 5,243 → 14,909 (10l the no-await resume's result store is the residue), the subset reads 0/0/0 and the corpus holds; the bootstrap fixed point holds, dev suite 19/0, `test/mt` 60/0, examples 49/49)**.  286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 16, 2026-10-10 — 10i(c)/the ctor aggregate: `ir.Expr` `Name.pointer` and `LocalBinding.pointer` became `Option[bool]` (210 `expr_name(` + 36 `LocalBinding(` sites wrapped in `some(...)`, the readers `unwrap_or(false)`, the dumper's `field_optional_bool`, `none` only at the async param bindings/copies via `async_param_pointer`) and the ctor's task aggregate drops its `value` field — the probe moves 3,962 → 5,243 (10j the vtable names/types is the residue), the subset reads 0/0/0 and the corpus holds; the bootstrap fixed point holds, dev suite 19/0, `test/mt` 60/0, examples 49/49)**.  286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 15, 2026-10-10 — 10h/10i(a/b/d): every frame store is the host's `IR::Member(frame, field)`, the async ctor drops its `ready`/`cancelled`/`state` zero-stores and its frame-Name pointer flags, and the resume call / task aggregate carry the frame's `ptr[void]` cast — verified at the probe level (`tmp/probe_b13.mt`: the store members match exactly, the ctor's residue is only 10i(c)'s param-copy `:pointer nil`); the corpus's first differences are unmoved (0 flips / 0 newly differing / 0 shallower) because 10i(c) and item 8A precede them; the bootstrap fixed point holds, dev suite 19/0, `test/mt` 60/0, examples 49/49)**.  286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 14, 2026-10-10 — 10d (the async ctor params' `:pointer nil`, `ir.Param.pointer` now `Option[bool]` with all 45 sites wrapped), the synthetic types' `:module_name nil` rendering (`field_module_name`) and item 8C's first half (the refcounted `mt_async_alloc`/`mt_async_free` for the frame/proc-env/event-wait-frame allocations + the backend's allocator block): the `tmp/probe_b13.mt` first difference moves 2,912 → 3,962, the `std examples test` subset reads 0 flips / 0 newly differing / 0 shallower, and the corpus holds at these counts; the bootstrap fixed point holds (the allocator swap validated end-to-end), dev suite 19/0, `test/mt` 60/0, examples 49/49)**.  286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 13, 2026-10-10 — 10f/10g: an embedded await hoists into the host's per-function `__mt_async_tmp_<N>` local from the `?` operands (the propagate paths hoist before lowering), and a `let _ =` discard registers/stores the host's `local_discard_<line>` field — the identical-corpus `std examples test` subset comparison reads 0 flips, 0 newly differing, 0 shallower, **12 files' first difference deeper** (the `std/net` async family; `clock.mt`'s frames are byte-identical); the bootstrap fixed point holds, dev suite 19/0, `test/mt` 60/0, examples 49/49)**.  286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 12, 2026-10-10 — the reference-based proc capture set (the host's `proc_capture_entries` walk) plus the program-scoped proc/binding counters (the host's per-`Lowering` counters; `lower_fn_to_proc` now shares the `__proc_<N>` scheme) and 10c's frame-position insert: 0 flips, 0 newly differing, 0 shallower, **68 files' first difference deeper** (`dap/server.mt` 64,382 → 651,011, `std/json.mt` 7,207 → 290,642, `std/toml.mt` 12,598 → 336,009); the bootstrap fixed point holds, dev suite 19/0, `test/mt` 60/0, examples 49/49)**.  286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 11, 2026-10-10 — 10b takes the host's async match-binding shape: an analysis-registered, never-referenced `local_match_binding_<N>` frame field for each arm whose body awaits (post-order, named from the shared interleaved counter the lowering also advances) and a plain `LocalDecl` for the binding itself — 0 flips, 0 newly differing, 0 shallower, **22 files' first difference deeper** (the `std/net` async family + `examples/async_network_lobby.mt`/`async_stress_test.mt`); the bootstrap fixed point holds, dev suite 19/0, `test/mt` 60/0, examples 49/49)**.  286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 10, 2026-10-08 — 10a gives a nested struct the host's parent-carrying C name (`<mod>_Rectangle_Edge`): 0 flips, 0 newly differing, 2 files deeper (`nested_struct_stress_test.mt` 1,012 → 7,303; `event_stress_test.mt` 21,949 → 22,496), 0 shallower; the bootstrap fixed point holds)**.  286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 9, 2026-10-08 — 9a folds a *const* array initializer's enum members to `(IR::IntegerLiteral :value … :type (Types::Enum …))`, the runtime case keeping its member names: the corpus holds at 286 (those files carry further differences) while the compiler's own sources advance hugely — `formatter/tidy.mt` 8,744 → 1,301,873, `formatter/cst.mt` 8,634 → 375,187, `build.mt` 22,979 → 118,893 — 0 newly differing, 0 shallower; the bootstrap fixed point holds)**.  286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 8, 2026-10-08 — 8b the synthetic `str_buffer[N]` structs ride `Program.str_buffer_structs` (backend-only) and leave the dump: 0 flips, 15 files' first difference deeper by +33,141 … +400,294, 0 newly differing/shallower; 8a reverted with its evidence; the bootstrap fixed point holds)**.  286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 7, 2026-10-08 — 6a the array-of-arrays checked index + the checked-index backend pass; the `std examples test` subset 262 → 263, the batch's set comparison reads 1 flip (`basic_voxel.mt`), 3 files' first difference deeper by +1,310 … +4,938, 0 newly differing/shallower; the backend correction was caught by `test/mt` (`signal_test.mt`'s function-pointer element parameter), fixed within the batch, and the bootstrap fixed point holds)**.  285 match / 381 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 6, 2026-10-08 — 6b the async `__frame`/`__resume` names and 6c/6d the match scrutinee's hoist rule (+4 subset flips, `bounce_house.mt`, `chain_shape.mt`, `path.mt`, `process.mt`); 6a deferred to a backend pass; the `std examples test` subset 258 → 262, the batch's set comparison reads 4 flips, 28 files' first difference deeper by +1,198 … +190,572, 0 newly differing/shallower; the bootstrap fixed point holds)**.  277 match / 389 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 5, 2026-10-08 — 5a the scalar element fold (+4 subset flips) and 5b the `in`/external call's literal context (deeper-only); the `std examples test` subset 254 → 258, the batch's set comparison reads 4 flips, 13 files' first difference deeper by +515 … +21,556, 0 newly differing/shallower; the bootstrap fixed point holds)**.  273 match / 393 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 4, 2026-10-08 — 4a the constant array element's aggregate (+6 subset flips) and 4b/4c the cstr-backed `if` (+2); the `std examples test` subset 246 → 254, the batch's set comparison reads 8 flips, 2 files deeper (+7,776, +10,386), 0 newly differing/shallower; the bootstrap fixed point holds)**.  265 match / 401 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 3, 2026-10-08 — 3fa the function-typed callee, 3fb the defer's flat replay (+17 subset flips) and 3fc every foreign literal (+7); the `std examples test` subset 222 → 246, the batch's set comparison reads 24 flips, 7 files' first difference deeper by +593 … +31,613, 0 newly differing/shallower; the bootstrap fixed point holds)**.  241 match / 425 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 2, 2026-10-08 — 3ag + 3ae re-applied: the `std examples test` subset 211 → 219 (+8); 3wf: 219 → 222 (+3); the batch's subset set comparison reads 11 flips, 21 files' first difference deeper by +1,208 … +27,010, 0 newly differing/shallower; the bootstrap fixed point holds)**.  228 match / 438 differ / 51 host-rejected / 0 self-rejected of 717 files (session 44 batch 1, 2026-10-08 — 3af's unannotated-decl inference: +12 flips, the `std examples test` subset 205 → 211 with 6 flips, 59 subset files' first difference deeper by +30,394 … +288,383, 0 newly differing/shallower; 3ac is deeper-only; 3ae implemented and reverted — blocked by 3ag, the imported opaque alias)**.  216 match / 450 differ / 51 host-rejected / 0 self-rejected of 717 files (re-measured 2026-10-07 session 44 — **3r's struct equality desugaring**: the identical-corpus `std examples test` subset comparison read **122/399/47/0 on both the pre-fix (`tmp/mtc-head`) and post-fix (`tmp/mtc-dev`) binaries** with **30 files' first difference deeper by +21,667 to +21,677** (the box2d family), 0 flips, 0 shallower, 0 newly differing, 0 lost; the full corpus set is unchanged.  **3s's array-length fold** (same session): the same subset protocol read **122/399/47/0 on both binaries** with **the same 30 files' first difference deeper again (+19,298 to +19,308)**, 0 flips, 0 shallower, 0 newly differing, 0 lost; the full corpus stays 131/535/51/0.  **3t's dyn vtable member type** (same session): **the full corpus 131 → 132 match / 535 → 534 differ** (`projects/stress/src/engine/interfaces.mt` flips), the same 30 files deeper (+1,925 each), 0 shallower/newly differing/lost — and the slot type was a real miscompile (the pre-fix binary aborted rc 134 running `body_move.mt`, the host runs the render loop).  **3u's out/inout boundary deepening** (same session): **8 files flip** (`examples/box2d/common.mt`, `compound_shapes`, `confined`, `human`, `kinematic`, `rounded`, `tiny_pyramid`, `examples/raylib/core/3d_camera_free.mt`), the subset 122 → **130 match**, with **42 files' first difference deeper** (23 box2d, 14 box3d, 5 raylib; +181 … +252,788), 0 shallower/newly differing/lost — **the full corpus 132 → 140 match / 534 → 526 differ**.  **3v's array-storing receiver borrow** (same session): **3 files flip** (`examples/box2d/contact.mt`, `examples/box2d/sensor_funnel.mt`, `std/noise.mt`), the subset 130 → **133 match**, 15 files' first difference deeper (14 box2d + 1 test; +64 … +76,462), 0 shallower/newly differing/lost — **the full corpus 140 → 143 match / 526 → 523 differ**.  **3w's dynamic format-string protocol** (same session): the build hoists with the destination-named result temp (`__fmt_<name>`, `_cap`/`_off`, `_2` repeats), the parts' temps first, casts only where the types differ, and the `mt_format_str_release` cleanup after the statement — **15 files flip** (the whole box2d family: `body_move`, `body_type`, `bridge`, `circle_stack`, `drop`, `explosion`, `falling_hinges`, `prismatic`, `ragdoll`, `ray_cast`, `revolute`, `shape_cast`, `skinny_box`, `vertical_stack`, `wheel`), the subset 133 → **148 match**, 30 files' first difference deeper (15 raylib, 11 sdl3, 3 box2d, 1 std; +31 … +32,056), 0 shallower/newly differing/lost — **the full corpus 143 → 158 match / 523 → 508 differ**.  **3x's cstr-backed `str as cstr` argument** (same session): a string-literal local, a cstr-backed local or a dynamic format string's temp passes `data` directly instead of the `mt_foreign_str_to_cstr_temp` copy — **18 files flip** (the raylib core family and `std/raylib/debug_console.mt`), the subset 148 → **166 match**, 1 file deeper, 0 shallower/newly differing/lost — **the full corpus 158 → 176 match / 508 → 490 differ**.  **3y's if-condition prepared shape** (same session): a statement-lowered foreign call in an `if` condition materializes into `__mt_foreign_result_N` with its cleanups before the `IfStmt` (an `else if`'s setup at the head of the enclosing else body) — **34 files flip** (the raylib audio/models/textures families), the subset 166 → **200 match**, 66 files' first difference deeper, 0 shallower/newly differing/lost — **the full corpus 176 → 210 match / 490 → 456 differ**.  **3aa's monomorphized null return** (same session): `lower_specialized_function` now installs the substituted `current_fn_return_type`, so `return null` in `alloc[T](…) -> own[T]?` takes `Nullable(own[int])` — **3 files flip** (`std/bitset.mt`, `std/bytes.mt`, `std/mem/pool.mt`), the subset 200 → **203 match**, 97 files' first difference deeper, 0 shallower/newly differing/lost — **the full corpus 210 → 213 match / 456 → 453 differ**.  **3ad's declaring-module grouping** (same session): a method's instances are grouped under the module that declares the extending block (`SpecInfo.owner_module = gm.owner_module`) — **3 files flip** (`examples/raylib/core/random_sequence.mt`, `std/graph.mt`, `projects/mtc/src/mtc/lsp/utils.mt`), the subset 203 → **205 match**, 122 files' first difference deeper, 0 shallower/newly differing/lost — **the full corpus 213 → 216 match / 453 → 450 differ**.  Session 43 — **3k's refinement-record positions**, **3j's simple-path call type**, **3l's `read(x) =` target literal**, **3m's call-argument/variant-field literals + the bare-float-literal operand retyping**, **3o's prelude generic variant arm field type**, **3i-b's native `break`**, **3g's raw-module/flags type classification** and **3q's foreign address-of boundary type**: `std examples test` subset comparisons with the identical corpus read 48/473/47/0 on the pre-fix (`build/stage2/mtc`) and post-fix (`tmp/mtc-dev`) binaries — 3k moves **209 files' first difference deeper (+30,767 each)**, 3j **100 files deeper**, 3l **183 files deeper with 26 flips** (the heap-importing `std/**` family), 3m **82 files deeper with 2 flips**, 3o **80 files deeper**, 3i-b **74 files deeper with 6 flips** (`std/str.mt` byte-identical), 3g **83 files deeper with 35 flips** (the raylib core family) and 3q **55 files deeper with 5 flips** (the raylib shapes family), 0 shallower, 0 newly differing, 0 lost throughout; session 41: **the statement-position hoisting channel** — a statement-lowered foreign call's setup now hoists into the statement stream with the host's `hm_return`/`hm_value`/`hm_discard` shapes and the host's `foreign_arg`/`foreign_result` temp names, instead of an `IR::StmtExpr` — plus **item 3d, the pointer-like foreign argument** (an already-pointer `this`/`*p` argument is cast to the boundary pointer type, not addressed again; the discard statement's nil line/path rule corrected), **item 3e, the mapping-argument temp rule** (a referenced mapping parameter is temp-bound only where the host binds one and the other values are substituted into the mapping via `mapping_replacements`), **item 3f, the mapping call's return type** (an embedded external call takes the raw declaration's return type, resolved in the mapping's owner module), **item 3c, the guard-bound nullable pointer arithmetic** (the lowering's pointer-arithmetic result keeps the analyzer's refined pointer instead of the storage `Nullable`) and **item 3h, the assignment literal's contextual type** (`i = 1` / `i += 1` on a `ptr_uint` target emit `ptr_uint` literals) and **item 3i's continue half** (a `continue` in a plain `while` lowers to `IR::ContinueStmt`): set unchanged throughout (3c: 255 files +1287; 3h: 255 files +18; 3i: 255 files +222) and **3f flips 11 files to byte-identical — `std/raylib.mt`, `std/raygui.mt` and 9 raylib examples** — taking the sweep **44 → 55 match / 622 → 611 differ**, with **242 files' first difference deeper (max +314,637), 0 shallower, 0 newly differing, 0 lost**; the remaining leaders are 3i (the `continue` lowering, ~255), 3j (the simple-path call's raw type, ~100), the array/const literal shape (57), 3g (the flags/enum member type, 24) and the format-string hoist (9).  Session 40: items 2, 2b, 2c, 2d, 2e(a), 2e(b), 3b, 4 and 6 — global-from-imported-const folding, named function-reference types, tuple value structs, the synthetic-struct ordering, the anonymous-tuple default field names, the tuple constant's `ArrayLiteral` shape, the `reinterpret` lowering, the event fields and the include order — leave the differing set unchanged, with **23 + 29 + 6 + 42 files' first difference deeper** plus **3b's 169 files (+1527 each)**, **item 6's 91 files (+8456 … +136,782)** and `examples/event_stress_test.mt` **+737**, 0 shallower/newly differing, and **item 2e(a) flips `std/color.mt` to byte-identical (43 → 44 match / 623 → 622 differ)**; 2e(b) is corpus-neutral (fixtures byte-identical); item 3 verified closed.  Session 39: item 1 flipped `std/glfw.mt`, `std/gl.mt`, `std/box3d.mt`, `std/sdl3.mt`, 39 → 43; item 1b moved 296 files deeper) | 0 differ | `ruby tools/sexpr_parity.rb lower -q -j 16 --host-cache tmp/sexpr-host-cache` |
| `cli:parity` | 24 match / 37 differ / 0 pending (61 cases; re-measured 2026-10-05 session 35 — unchanged; the `lint-timings` case can never be byte-equal, see session 31's record) | all match | `rake "cli:parity"` |
| LSP harness | 30/30 capability keys; **4 documented entries** of **70 requests + 27 probes** (re-measured 2026-10-05 session 38: a fresh host+self pair reads the documented 4; the gate's pairing once read 5 because the *host* nondeterministically adds a phantom `renamed.mt` hit to `c5/references-no-declaration` after `willRenameFiles` — host-vs-host records agree, and the self matches the host's stable answer.  `milkTea/debugInfo` is **byte-equal** after the session-35 Facts/Bindings port; the 4 are the host parser recovery, the host's malformed-frame hang, the host's facts lag and the host's directory-form `typeDefinition` path) | 0 unintended | `tools/lsp_parity.rb record/compare --stress` |
| LSP project audit | **canonical (warm) set: 6 differ** (re-read 2026-10-07 session 43: 6 → 6, the same keys, after 3k's record-position change — a greatest-position scan had briefly surfaced the refined-parameter hover `docs/memory_stress_test.mt@39:24`; the final order-based lookup mirrors the host and closes it.  2026-10-05 sessions 36–37, `--cap 200`: the 4 documented completion/highlight rows + the `type quat` hover + the 2 builtin-hover warm artifacts; the four references warm-coverage rows closed — 10 → 6, closed 4, added 0; session 37 re-confirmed 6 → 6, added 0).  Non-canonical runs read 4–5 with ±drift (session 37's gate read **4**, session 36's **4**, session 35's **5**, session 38's gate **4**); two canonical runs return identical sets | 0 unintended | `tools/lsp_project_audit.rb --workspace ~/Projects/MilkTea/SimpleGame [--canonical]` |
| LSP recovery | 6/6 cases byte-equal (re-measured 2026-10-05 session 37) | stay green | `tools/lsp_recovery_probe.rb --check` |
| LSP edit latency | **4.9 ms median per `didChange`** on `SimpleGame/src/main.mt` (was 54.3; 8 edits, `tmp/lsp_edit_perf.rb`); `didOpen` ~52 ms cold; diagnostic pull 0.2 ms | ≤ ~10 ms | `ruby tmp/lsp_edit_perf.rb --bin <bin>` |
| LSP valgrind | 0 errors over the harness drive (re-measured 2026-10-05 session 38); the definitely-lost residue is down to ~64 KB per 10-cycle soak (was ~7.8 MB), dominated by the one-time index walk's arena-leaked ASTs | 0 errors | `tools/gates.sh --only valgrind_lsp --run` |
| LSP soak | **68.1 KB/cycle raw / 19.9 KB/cycle least-squares** at `--cycles 200` on the synthetic ~5k-line workspace (session 38 close; was 3.96/3.98 MB/cycle — the per-edit AST/analysis leak is now owned by per-entry regions and drained per request; level 656 → 33 MB peak; the new `steady` mode reads 12.6 raw / 0.0 LS, `diag` 12.0 LS).  Residue: the one-time index walk's arena-leaked ASTs (~600 KB per workspace build, a level not a slope, documented) | slope → flat | `ruby tools/lsp_soak.rb --cycles 100` |
| formatter | 712/712 all three modes byte-identical (re-measured 2026-10-04 session 33; file counts drift) | stay green | `ruby tools/format_parity.rb all -j 16` |
| lint corpus | 495 agree / 121 differ (616 files; re-measured 2026-10-06 session 40 — the shift over session 35's 496/120 is the session-40 corpus edits: re-running at HEAD reads the same 495/121, and the three files 3b edits read 3/3 differ at HEAD too; per-rule deltas unchanged in kind: redundant-cast 76/27, prefer-try 69/39, prefer-let 65/141, borrow-and-mutate 29/0, shadow 20/0, prefer-own-ptr 16/45 …) | 0 differ | `ruby tools/lint_parity.rb -q` (`--host-cache`) |
| DAP | **zero differing rows** on the whole `dap_smoke` matrix (2026-10-04 session 34 — process backend, fake-adapter lldb and real `/usr/bin/lldb-dap` sessions), except the documented self-better `lldb-real frame0 name` (self `add`, host `main_add` — the host's cache-hit map loss); valgrind 0 errors on both backends | VS Code end-to-end under lldb-dap (manual) | `ruby tools/dap_smoke.rb` |
| imported-bindings | 3 verified / 25 changed (re-measured 2026-10-03; cosmetic emitter gaps) | 28/28 or each justified | `mtc imported-bindings --all --check` |

Baseline for reference only (Phase 0, session 5): bootstrap 14/0, `test/mt`
60/0, lex 702/702, parse 698/0, lower 39/613/51/0, cli 22/39, LSP 4 documented,
lint lb host 98 / self 158.  **Do not replay a baseline a previous session
verified at the same commit** — counts drift (sexpr's file count with the tmp
fixtures, the audit's ±10 between runs, the lint corpus with tmp files).

---

## 0k. 2026-09-25/26 session — LSP parity harness + gap closure

### Session 45 (2026-11-02) — `lower` batches 1–3: 286 → 340

**The post-batch-21 re-ranking's leading families**, landed as one batch (each
locked by a `projects/mtc/test/lowering_test.mt` case where the fixture is a
plain source tree; the async chain's lock is the `tmp/async_probe.mt` probe).

- **The monomorphized call's literal context.**  `lower_monomorphized_call` and
  `try_inferred_generic_call` lowered arguments through `lower_plain_call`,
  which has no parameter signature, so a bare literal kept its default type.
  The host types every call argument against the substituted parameter
  (`lower_contextual_expression`).  Landed: `lower_plain_call_spec` lowers each
  argument, then applies the existing `coerce_literal_to_mono_param` against
  the cached specialization's params (the monomorphized-method path's rule);
  the inferred path keeps the synthesized-`FnSig` branch for async `wait`/`run`
  (the task-root-proc bridge) and uses the spec-function path otherwise.
  Repro: `std/async/libuv_runtime.mt:338`'s `heap.must_alloc_zeroed[SleepState](1)`
  emitted an `int` literal where the host emits `ptr_uint`.  Locked by
  `test_monomorphized_call_literal_takes_the_parameter_type`.
- **The async main's `wait` chain.**  `ensure_async_wait_specialization`
  resolved `wait` with `find_generic_function`, whose program-order scan hit the
  *deepest* backend declaration (`std.async.libuv_runtime.wait`), so only
  `std_async_libuv_runtime_wait__int` (and its `wait_on`) was emitted.  The host
  instantiates the binding declared in `std.async`
  (`async_main_runtime_callee_name`) and its fixpoint then walks the delegation
  (`std.async.wait` → `std.async.runtime.wait` → `std.async.libuv_runtime.wait`).
  Landed: `find_generic_function_in_module(ctx, "std.async", "wait")`.  Measured:
  `tmp/async_probe.mt` is content-complete — all three `wait` functions exist —
  and its first difference moves 199,968 → 229,310, now the *placement* of the
  late instances (below).
- **The instance sort key (the 3ad residue).**  The host sorts a declaration's
  instances by `type_arguments.map(&:to_s).join(",")`, i.e. the *rendered*
  arguments; the self used the C key.  The difference is real: in
  `projects/mtc/src/mtc/build.mt`'s `std_mem_heap_alloc__std_map_Node_*` group the
  host puts `span[mtc.parser.ast.TypeParamConstraint]` before
  `span[...TypeParam]` (the `]` closing the shorter element name sorts after
  `C`), while the C key orders `TypeParam` first.  Landed: both `SpecInfo`
  construction sites build `args_key` with `naming.type_to_s_qualified` joined
  with ",".  Locked by
  `test_specialization_instances_sort_by_rendered_arguments` (`array[A, 2]`
  before `array[AB, 2]`).
- **The imported arm payload's module.**  `build_imported_variant_info` returned
  `VariantInfo(module_name = "")`, so an `as name` binding of an imported
  variant rendered `(Types::VariantArmPayload :name "Type_ty_function"
  :module_name nil)` where the host carries the declaring module
  (`mtc.semantic.types`).  Landed: the owner module is recorded.  Locked by
  `test_imported_variant_arm_payload_keeps_its_owner_module` (a two-file
  fixture: `lib.mt` declares the variant, `main.mt` matches it).
- **`as_span()`'s decay index.**  The host's
  `lower_array_to_span_expression` builds `&array[0]` as a plain `IR::Index`
  (`resolve.rb:128`); the self used the runtime subscript's `IR::CheckedIndex`,
  so `lower_array_as_span` now emits `expr_index` (the length recovery stays for
  the `len` field; the `index_array_ty` rebuild is gone with the checked
  helper).  Repro: `std/../lowering/utils.mt:210`'s `RESERVED_WORDS.as_span()`.
  Locked by `test_array_as_span_uses_an_unchecked_index`.
- **The assignment target's visible type.**  The host's
  `lower_assignment_target` (`utils.rb:1237`) types a bare local's target
  `IR::Name` with the binding's *visible* (flow-refined) type when it equals the
  storage type or is the storage nullable's base; reads keep the storage type.
  The self lowered the target with `lower_expr`, i.e. the storage type.  Landed:
  `lower_assignment_target` consults the analyzer's refinement record and
  applies the active type substitution (a generic body's record carries type
  parameters).  The record lookup needed a lowering-specific ordering: the LSP's
  `flow_type_at` is *order*-based for the host's reverse walk (session 43), and a
  compound statement's post-state replayed at its start shadows the body's inner
  records; the new `analyzer.flow_type_at_position` picks the greatest position
  at or before the cursor (ties: the later record), which is the lowering env's
  lexical view.  Repro: `std/map.mt:74`'s `node = read(node_ptr).next` inside
  `while node != null`.  Locked by `test_assignment_target_takes_the_refined_type`.
  Residue: a target *after* a returning branch (`std/map.mt`'s `previous = node`,
  line 291) still picks the leaked branch refinement — the flow records are not
  a lexical env; the real fix is a lowering-side refinement scope
  (`env_with_refinements`' port).
- **Measured**: the full corpus **286 → 302 match / 380 → 364 differ / 51 / 0**
  (+16 flips, 0 regressions, verified by a before/after differing-set comparison
  against the parent revision's binary `tmp/mtc-head`); `projects/mtc/src/mtc/build.mt`'s first difference
  483,301 → 5,024,041 (its next difference is the `previous` residue above).
- **Tried and reverted: the creator-tracked wave model.**  The host's
  `lower_functions` emits instances lazily: an instance whose binding is created
  while lowering a body joins a later pass and is appended at its module's end.
  A faithful-looking port tracked each specialization's creator (the linkage of
  the function whose body created it) plus its module index, then ran the
  host's pass loop (`available`/`created_by`/`prepend` per module, leftovers
  excluding instances).  Measured: **264 match** — worse than the 286 baseline.
  Root cause: the Ruby analyzer instantiates generic *bodies* per instance
  before lowering runs (e.g. `Set.remove[int]`'s body creates
  `Option.is_some[bool]` at analysis time), while the self's analyzer checks each
  declaration once with type parameters, so the self cannot name the analyzer's
  instance set; the wave boundary is therefore unreachable from the lowering's
  data.  Reverted whole; the late-instance placement stays the documented
  residue (`tmp/async_probe.mt`'s first difference; the wave model needs the
  analyzer's per-instance instantiation set first).
- **Gates**: bootstrap fixed point holds, dev suite 19/0 (6 new tests), `test/mt`
  60/0, examples 49/49, `sexpr_lower` 302/364/51/0 on the frozen tree.

### Session 45, batch 2 (2026-11-02) — assertions, static calls, switch continues, iterator storage, pointer intrinsics: 302 → 338

**The next first-difference families after batch 1.**  Measured: the full corpus
**302 → 338 match / 364 → 328 differ / 51 / 0** (+36 flips, 0 regressions by the
before/after differing-set comparison); the `test/` corpus alone went **0 → 29
match** (the assertion messages were its top blocker).

- **The assertion intrinsics** (`lowering/assertions.rb`'s port).  `assert` /
  `expect` / `expect_eq` / `expect_ne` are statement-only builtins; the self
  lowered them but its default message was the bare text.  The host's
  `default_assert_message` appends ` at <path>:<line>` (the analysis path and
  the *statement's* line) and the synthesized `fatal` statement carries the
  host's statement-position shape — `:line nil` and the analysis path (the
  host's AST call expression has no line).  Landed: `assert_default_message`
  builds the suffixed text and `lower_assert_stmt` emits `line = 0` +
  `source_path = ctx.analysis.source_path`.  Locked by
  `test_assert_default_message_carries_the_callsite`.
- **Static method call literals.**  `lower_static_call_args` (used for
  `Type.static_method(args)` and `default[T]()`) did the pointer deref but not
  the literal contextual typing, so `Color.from_rgba(10, 20, 30, 200)` kept
  `int` literals where the host emits `ubyte`.  Landed:
  `coerce_literal_to_param_type` against `mi.params`, as in
  `lower_method_resolved`.  Locked by
  `test_static_method_call_literals_take_the_parameter_type`.
- **A continue inside a switch-backed match.**  The host's
  `switch_loop_flow`/`switch_loop_target` convert *both* exits to the loop-label
  form inside a `switch`; session 43's break half cleared only
  `loop_break_native`, and the 3i note's claim that `continue` needs no
  invalidation is wrong for the dump (`std/behavior_tree.mt`'s
  `tick_node` arm).  Landed: `lower_switch_arm_body` clears both native flags.
  Locked by `test_continue_in_a_match_arm_uses_the_loop_label`.
- **Iterator-loop binding storage.**  A `for x in collection` over the iterator
  protocol registers the binding with `next()`'s storage (nullable) and the
  unwrapped item as its visible type (`iterator_loop_info`'s
  `item_storage_type`/`item_type`); the self bound the visible type directly,
  so a pointer-like item's read lost the `Nullable` (the blackboard/cmd tests,
  `read(child_ptr)` in `std/behavior_tree.mt`).  Landed: the binding carries
  `guard_binding_projection("nullable", next_ty)`.  Locked by
  `test_iterator_loop_binding_keeps_the_nullable_storage`.
- **Pointer-intrinsic casts.**  The host's `:ptr_of` wraps a ref-typed argument
  in `IR::Cast(target_type: T, expression: Name, type: T)`, and
  `lower_addr_expression` (used by `ref_of`/`const_ptr_of`, and `ptr_of` for
  non-ref arguments) runs `cast_expression` on a pointer-lowered Name / a `*p`
  operand — the Name keeps its own type and a differing target becomes a cast.
  The self retyped the Name in place, so `ref_of(this)`/`ptr_of(ref)` rendered
  a retyped Name where the host has the Cast.  Landed: the three shapes mirror
  `cast_expression`, and the `ptr_of(ref)` branch returns the Cast.  Locked by
  `test_pointer_intrinsic_casts_like_the_host`.
- **Function-reference type names.**  A bare or explicitly specialized generic
  function used as a value (`condition_fn = default_condition[Context]`) types
  its `IR::Name` with `Types::Function :name <declaration>` on the host; the
  self's `expr_specialization` value path rebuilt the type with `name = ""`, and
  the identifier path trusted the analyzer's contextual (empty-name) form.
  Landed: both carry `id.name`.  Locked by
  `test_specialized_function_value_carries_its_name`.
- **Residue noted on the way**: a local enum-typed *parameter* resolves to
  `void` in the self (`function run(k: K)`), while the host types it as the
  enum; a member-typed match avoids it.  Not corpus-visible yet (recorded for a
  semantic-parity pass).

### Session 45, batch 3 (2026-11-02) — the hash-hook casts and the implicit ref argument bridge: 338 → 340

- **The hash/order/equal hook arguments** (`lower_hash_operation_argument`,
  `calls.rb:367-379`).  The builtins take `const_ptr[T]`: a pointer/ref
  argument is `cast_expression`d to that target (so a `ptr[Key]` at a
  `const_ptr[Key]` hook emits an `IR::Cast`), a `*p` operand casts its pointer,
  and an addressable value is borrowed with `AddressOf(const_ptr[T])`.  The
  self passed pointer arguments through with their own type and borrowed with
  `const_ptr[arg_ty]`; `std/binary_heap.mt`/`std/graph.mt`'s `order[K](…)` sites
  exposed it.  Locked by `test_hash_hook_arguments_cast_to_const_ptr`.
- **The implicit `ref[T]` argument bridge** (`implicit_ref_argument_bridge?` +
  the `ref_of` lowering).  For a `ref[T]` parameter and an argument whose value
  type is `T`, the host rewrites the argument to `ref_of(value)`: a
  pointer-lowered value (an editable `this`, a pointer Name) is cast to `ref[T]`,
  a `*p` operand casts its pointer, and a plain addressable value is borrowed.
  The self's `coerce_arg_to_ref_param`/`coerce_arg_to_param` passed pointer
  arguments through, and `lower_static_call_args`/`lower_method_resolved` had
  no bridge at all (`LinkedMap.unlink_order_node(this, …)`,
  `BinaryHeap.sift_up(this)`).  Landed: one `coerce_arg_to_ref_bridge` helper
  used by all four call paths.  Locked by
  `test_ref_argument_bridge_casts_a_pointer_receiver`.
- **Measured**: **338 → 340 match / 328 → 326 differ**, 0 regressions
  (differing-set comparison).  A related semantic-parity residue recorded: a
  local nominal type in a *type-argument* position of a non-generic call can
  resolve to `void` (`equal[K](…)` with `K` a local struct), while the host
  resolves it — the same family as the local enum-typed parameter residue above.

### Session 45, batch 4 (2026-11-02) — the foreign boundary projection, the tuple-match chain, two local-inference rules: 340 → 375

**The re-ranking after batch 3.**  Measured: the full corpus
**340 → 375 match / 326 → 291 differ / 51 / 0** (+35 flips, 0 regressions by the
before/after differing-set comparison); four locking tests added (712 tests /
19 files / 0 failed), bootstrap fixed point holds, `test/mt` 60/0, examples
49/49.

- **Item 8a — the foreign boundary projection** (the census's largest open
  family: the raylib shader/audio examples).  The host lowers an `in` argument
  with `lower_addr_expression(target_type: const_pointer_to(parameter.type))`
  and then projects the address to the declared `as` boundary
  (`foreign_identity_projection_expression`: equal type → unchanged,
  cast-compatible → `IR::Cast`, external-layout → `ReinterpretExpr`).  The self
  emitted `AddressOf(ptr[void])` with no projection on the `in` path and
  returned the plain lower for a plain `as` parameter.  The earlier blanket
  attempt had regressed 114 files because it cast by *source* type; the host's
  rule compares the *lowered expression's* type, so an already-cast value is
  never wrapped twice.  Landed: `project_foreign_boundary` +
  `foreign_projection_cast_compatible` (the pointer/nullable/cstr/opaque
  subset), `foreign_boundary_type` (the `as` type resolved in the wrapper's
  owner module), the `in` branch's `AddressOf(const_ptr[parameter.type])` +
  projection (with the `Name(pointer)`/`*p` `cast_expression` exceptions), and
  the plain `as` branch's contextual literal typing + projection.  A *generic*
  wrapper (`set_shader_value[T]`, `update_audio_stream[T]`) needs the host's
  `binding.type_substitutions`: `ForeignInfo.type_params` plus
  `foreign_call_substitution` infer `T` from the call's arguments and install
  the map around `lower_foreign_call` (deferred restore), so
  `T as const_ptr[void]` resolves to the concrete type.  Measured: **20 flips**
  first (the raylib shader core family + `vr_simulator.mt`), then **+8** once the
  plain `as` branch projected too (`amp_envelope`, `raw_stream`, four shader
  files, two textures examples), 0 regressions.  Locked by
  `test_foreign_in_boundary_projects_to_const_ptr` and
  `test_foreign_plain_boundary_projects_the_pointer`.
- **The tuple match expression's chain shape.**  The host nests a tuple
  scrutinee's if-chain into else bodies (`non_wildcard.reverse_each`, the
  wildcard assignment innermost); the self emitted the wildcard assignment
  first and then flat independent ifs.  Landed: `lower_tuple_match_expr`
  builds the wildcard else body first, then wraps each arm from the tail
  backwards, exactly the host's shape.  Repro: `projects/mtc/src/mtc/lexer/
  lexer.mt` (the `three_char_token`/`two_char_token` tables).  Measured: **4
  flips** (`formatter/cst.mt`, `lexer/lexer.mt`, `lsp/cursor.mt`,
  `test/lexer_test.mt`), 0 regressions.  Locked by
  `test_tuple_match_expression_nests_the_wildcard_else`.
- **The foreign wrapper's return type in an unannotated local.**  `let
  configured = libc.get_environment_variable("TMPDIR")`: the host's
  `infer_expression_type` takes the wrapper's declared `cstr?`, while the
  lowered simple-mapping call is typed with the raw declaration's `ptr[char]`
  (the 3j rule).  The self used the lowered value's type.  Landed:
  `foreign_wrapper_call_return_type` (the current module's `foreign_map` or an
  imported alias's `imported_foreign_call`) supplies the local's type; every
  other non-identifier initializer keeps the lowered value's type (so a
  nominal's module qualification is preserved — a bare `expr_type` first
  regressed 62 files on struct literals and casts).  Measured: **3 flips**
  (`projects/mtc/src/mtc/dap/utilities.mt`, `std/fs.linux.mt`,
  `std/pcre2/runtime.mt`), 0 regressions.  Locked by
  `test_unannotated_local_takes_the_wrapper_return_type`.
- **The guarded identifier's visible type in local inference.**  `let current =
  child` inside `while child != null` takes the binding's flow-refined
  `ptr[cJSON]`, not its storage `Nullable(ptr[cJSON])` — the host's
  `lookup_value`.  Landed: the identifier branch consults
  `analyzer.flow_type_at_position`; the record is accepted only when it equals
  the binding's own type or its nullable's base (a record can carry a stale
  nominal the lowering resolved correctly — `lower_stmt`'s `let rv = r.value`
  caught it as a C type error when accepted unconditionally).  Measured:
  deeper-only on the set (the `current` family), locked by
  `test_unannotated_local_takes_the_refined_visible_type`.
- **Residue noted on the way**: a *non-identifier* local inference still uses
  the lowered value's type; the host's `infer_expression_type` would take a
  cast's target type and a struct literal's declared struct, so a future
  `expr_type`-based path needs qualification and cast handling first.

### Session 45, batch 5 (2026-11-02) — the guard/propagation prepared positions: 375 → 383

**The re-ranking after batch 4.**  Measured: the full corpus **375 → 383
match / 291 → 283 differ / 51 / 0** (+8 flips, 0 regressions by the
before/after differing-set comparison); two locking tests added (714 tests /
19 files / 0 failed), bootstrap fixed point holds, `test/mt` 60/0, examples
49/49.

- **A `let … else:` guard's initializer is a prepared position.**  The host's
  `lower_local_decl_stmt` lowers the value through
  `prepare_expression_with_cleanups` (setup before the storage local, cleanups
  after it), so a foreign call's `str as cstr` temp is a statement-stream
  `LocalDecl`, not an `IR::StmtExpr` inside the value.  The self's
  `lower_guard_local` called `lower_expr` with no window.  Landed: the guard
  opens `hm_value`, emits the setup before the storage local and the cleanups
  after it.
- **The guard storage type is the host's inference.**  With the window in
  place, the value is the bare call (typed with the raw declaration's return,
  `ptr[char]`, the 3j rule), so `ir_expr_type(value_ir)` produced the wrong
  storage type.  The host's `infer_expression_type` takes the wrapper's
  declared `cstr?`.  Landed: `lower_guard_local` consults
  `foreign_wrapper_call_return_type` for a call initializer.  This was a real
  C-level regression on `std/env.mt` (`raw` became `char*` and
  `cstr_as_str(raw)` received the wrong shape) caught by the dev suite's
  `module_roots_test` build.
- **The `?` propagation's failure chain.**  The self hand-built
  `storage.data.failure.error` with `void` member types and a nil source path;
  the host's `variant_binding_projection_expression` types the chain
  (`data` nil, the arm payload, the error field) and its return carries the
  analysis path.  Landed: the three propagate sites use the existing
  `guard_failure_projection` and the propagation returns use
  `ctx.analysis.source_path`.
- **The propagation success local.**  `let raw = make(flag)?` materializes a
  real `LocalDecl raw = <storage>.data.success.value` on the host; the self
  registered a projection binding over the hidden storage with no local.  The
  two agree semantically but not in the dump, and the projection also changed
  later read shapes.  Landed: `lower_propagate_let` emits the local with the
  statement's line (a new `line` parameter) and registers a plain binding; the
  `_` and async paths keep their behavior.
- **Measured**: **8 flips** — `std/json.mt` (the whole conversion region),
  `std/env.mt`, `std/cookie.mt`, `std/uri.mt`,
  `examples/option_and_result_surface.mt`,
  `projects/mtc/src/mtc/loader/path_resolver.mt`,
  `projects/mtc/test/path_resolver_test.mt`, `test/mt/uri_test.mt` — with 0
  regressions; `projects/mtc/src/mtc/bindgen.mt`'s first difference moved
  1,016,872 → 1,100,002, now the program-scoped proc/instance *placement*
  residue.  Locked by `test_guard_local_hoists_foreign_argument_temps` (the
  temp decl, the storage type and no `StmtExpr`) and
  `test_propagate_let_materializes_the_success_local` (the typed failure chain
  + path and the success local).

### Session 45, batch 6 (2026-11-02) — the loop-exit defer flush: 383 → 384

**The re-ranking after batch 5.**  `break`/`continue` in a loop body with a
loop-scoped `defer` dropped the cleanup: the self emitted a native
`BreakStmt`/`ContinueStmt`, while the host's `lower_loop_exit` emits
`cleanup...; goto <label>` whenever `local_defers` is non-empty.  This was a
real leak in `std/fs.linux.mt`-style directory walks
(`projects/mtc/src/mtc/linter/config.mt`: `defer: candidate.release()` before a
`break`).

Landed: `LowerCtx.loop_defer_depth` (saved/restored by every loop lowering —
the plain `while`, the async `while true` rewrite, for-range, collection-for and
the custom-iterator loop), `has_loop_defers`/`flush_loop_defers` (the defer
groups opened inside the loop, innermost first, flushed without popping so the
fall-through path keeps its own copy), and the break/continue arms preferring
the label/goto form when a loop-scoped defer is pending.  The enclosing scopes'
defers are untouched.

Measured: `lower` **383 → 384 match / 283 → 282 differ** (+1 flip,
`projects/mtc/src/mtc/linter/config.mt`; 0 regressions by the differing-set
comparison — many files' first difference moved deeper), the emitted C for the
directory walk now runs the release before the jump.  Locked by
`test_break_and_continue_flush_loop_defers` (the release is the first statement
of the exit's then body, ahead of the label goto).  Gates: dev suite 19/0 (715
tests), bootstrap fixed point, `test/mt` 60/0, examples 49/49.

### Session 45, batch 7 (2026-11-02) — the equality-pattern guard's empty else: 384 → 385

**The re-ranking after batch 6.**  A variant struct-pattern arm's equality check
(`Entity.enemy(boss = true)` in `examples/integration_test.mt`) emitted
`else_body = none` where the host's `IR::IfStmt.new(condition:, then_body:
[goto], else_body: [])` carries a present empty span.  Landed:
`lower_variant_field_bindings`'s equality arm emits `some(span[ir.Stmt]())`.

Measured: `lower` **384 → 385 match / 282 → 281 differ** (+1 flip,
`examples/integration_test.mt`; 0 regressions), locked by
`test_variant_equality_pattern_guard_has_an_empty_else`. Gates: dev suite
19/0 (716 tests), bootstrap fixed point, `test/mt` 60/0, examples 49/49.

### Session 45, batch 8 (2026-11-03) — the flow replay's bookkeeping, prepared match expressions, the `_` local, and the conditional's expected type: 385 → 405

**The re-ranking after batch 7.**  The 55-file leader was the post-guard
assignment target (`std/map.mt`'s `previous = node` in every monomorphized
instance), then the late proc/instance placement (21), a null literal at a
`ptr[void]` boundary (20), the contextual casts (14+8) and the async frame
field's nullable drop (10).  Measured: the full corpus **385 → 405 match /
281 → 261 differ / 51 host-rejected / 0 self-rejected of 717 files** (+20
flips, 0 new differing files by the before/after set comparison); five locking
tests added (721 tests / 19 files / 0 failed); bootstrap fixed point, `test/mt`
60/0, examples 49/49, the LSP harness at 30/30 + the 4 documented entries and
recovery OK re-verified on the batch's frozen tree.

- **The flow replay is a view, not a transition** (the 55-file `previous`
  family).  `check_stmt`'s multi-line replay records the *post*-statement state
  at the statement's start (for the LSP's declaration-line lookup) and also
  advanced `ctx.flow_recorded`.  That suppressed the genuine
  end-of-statement transition: at `previous = node` the greatest record at or
  before the cursor was the inner `if previous == null` else-arm's `ptr[Node]`
  refinement, long out of scope (the host's lowering env is lexical).  Landed:
  `record_flow_snapshot_at`'s `replay` flag — a replay pushes its entries but
  leaves `flow_recorded` alone, so the end record is emitted and the lookup
  finds the storage `Nullable`.  The LSP's order-based `flow_type_at` is
  unchanged (the extra end record only answers cursors after the statement).
  Measured: the first **9 flips** — `projects/mtc/src/mtc/lsp/
  definition_index.mt`, `reference_index.mt`, `projects/mtc/src/mtc/semantic/
  control_flow/definite_assignment.mt`, `projects/mtc/test/lsp_index_test.mt`
  and `test/mt/{counter,linked_map,linked_set,lru_cache,map}_test.mt`.  Locked
  by `test_assignment_after_a_guard_keeps_the_storage_type`.
- **The prepared match expression** (the same files' next first difference; the
  35-file `__mt_match_expr_1` family).  The host's
  `prepare_match_expression_for_inline_lowering` materializes a
  zero-initialized `__mt_match_expr_<N>` result local plus the strategy's
  switch/if chain in the enclosing statement's setup; the self inlined the
  `is`-desugar's kind test and had only a placeholder for other inline match
  expressions.  Landed: `lower_expression_match` uses the open hoisting window
  and `lower_match_expr_to_ref` (the inline kind test stays the no-window lazy
  fallback).  Locked by
  `test_match_expression_in_a_condition_prepares_the_host_temp`.
- **The `_` local's host declaration.**  `let _ = value` is a real declaration
  on the host: IR name `_`, linkage `__mt___N` (`let_else_storage_c_name`), the
  value stored; the self emitted an expression statement.  Landed: the normal
  local path with the discard linkage (the `?` propagation still propagates).
  Locked by `test_discard_local_keeps_the_hosts_declaration`.
- **The conditional's expected and common type** (the 35-file `arg_id` family
  and the 6 self-failures the first attempt exposed).  `conditional_common_type`
  lacked the host's `common_numeric_type` and the compatibility fallbacks;
  `types.integer_width` treated `ptr_int`/`ptr_uint` as widthless where the host
  has them fixed-width 64, and `is_signed_integer_name` omitted `ptr_int`.  The
  analyzer also lacked the host's expected-type short-circuit: `let n: uint =
  if p: uint<-x else: 0` is `uint` on the host (each branch fits the annotation)
  though the branches' common type is `long`.  Landed: the host's numeric
  common-type family in `semantic/expressions.mt` (with
  `signed_type_above_width`), expression-carrying
  `conditional_common_type`/`match_expression_common_type`, the pointer-sized
  integer widths, a `Context.expected_type_hint` set for a declared local, an
  assignment target and a return type — cleared for tuple-literal elements,
  where the host gives no element expected type (the first attempt handed a
  tuple-typed return's elements the tuple type and broke the C build) — and
  `expr_if`'s conditional now uses the inferred type with literal branches
  retyped to it.  A signed literal (`-128`) is a literal expression for
  `int_literal_to_context_type`, so `value >= -128` against a `long` peer keeps
  a long unary with no cast.  Measured: **+11 net flips** and 6 surface self
  failures resolved; locked by
  `test_if_expression_takes_the_expected_and_common_types` and
  `test_negative_literal_takes_the_peer_type`.

**The re-ranking after the batch.**  The new leader (46 files) is the explicit
format sink's `mt_str_buffer_clear` ordering (item 3z), then the late
proc/instance placement (20), the null literal at a `ptr[void]` boundary (20),
10e/4b and the async frame field's nullable drop (~10).

### Session 45, batch 9 (2026-11-03) — the mapping literal's context, the for-stop constant, the specialization's state, the guard's format destination, and mixed-signedness promotion: 405 → 414

**The re-ranking after batch 8.**  Measured: the full corpus **405 → 414
match / 261 → 252 differ / 51 host-rejected / 0 self-rejected of 717 files**
(+9 flips, 0 new differing files by the before/after set comparison); five
locking tests added (726 tests / 19 files / 0 failed); bootstrap fixed point,
`test/mt` 60/0, examples 49/49 and sexpr lower 414/252/51/0 re-verified on the
batch's frozen tree.

- **A foreign mapping's literal argument** (the 20-file null-literal family).
  The host lowers every mapping argument against the raw C declaration's
  parameter; the self's `walk_mapping_expr` lowered a fixed literal with no
  context, so `= c.SDL_RunApp(..., null)`'s null was `void` where the host emits
  `Nullable(ptr[void])`.  Landed: `mapping_call_foreign_info` (the raw
  `ForeignInfo`, resolved like `mapping_call_return_type`) and the per-argument
  `literal_value_to_context_type` + `foreign_param_context_type` — item 5b's
  rule on the mapping path.  Flips: `examples/sdl3/input/gamepad_events.mt`,
  `joystick_events.mt` and `std/sdl3/runtime.mt`; the rest of the family moved
  deeper and exposed the format sink work below.  Locked by
  `test_foreign_mapping_literal_takes_the_raw_parameter_type`.
- **The range-for stop's compile-time constant.**  `inline_stop` recognized
  only an integer literal; the host inlines a compile-time numeric constant
  expression (`compile_time_numeric_const_expression?`) — a module constant, an
  enum member or a fold — and hoists `__mt_for_stop_N` only otherwise.  Landed:
  `is_numeric_const_expression` over the existing `try_evaluate_const_expr`.
  Locked by `test_range_for_stop_inlines_a_compile_time_constant`.
- **A lazy specialization's caller state** (the 17-file format-numbering
  family).  A generic method specialized *while an expression is being
  lowered* (`String.as_str` inside a foreign argument) ran
  `ensure_monomorphized_method` / `lower_and_cache_specialization_with_sub`,
  which cleared the caller's `fmt_dest_name`, `fmt_counter` (by `.clear()` on
  the caller's shared map), `fmt_counter_visible` and `cstr_backed_names` and
  restored none of them.  A later `f"..."` in the caller then lost its
  `__fmt_<dest>` name (and the repeat numbering drifted).  Landed: save the
  four around the nested lowering, give the body fresh maps instead of clearing
  the caller's, and restore them.  Locked by
  `test_lazy_specialization_keeps_the_callers_format_destination`.
- **The guard local's format destination.**  A `let n = value else:` guard's
  storage binding (the host's `current_local_name = linkage_name`) is the
  block's format destination, and the linkage is allocated before the
  initializer's temps (`let_else_storage_c_name`).  `lower_guard_local` now
  computes the storage name first, sets `fmt_dest_name`, and only then lowers
  the initializer and the else body.  Locked by
  `test_guard_binding_names_the_blocks_format_destination`.
- **Mixed-signedness integer promotion.**  The lowering's
  `common_integer_type` refused every mixed-signedness pair, so
  `ev.type == int<-SDL_EVENT_QUIT` (uint vs int) left the left operand uncast;
  the host promotes to the narrowest signed type that holds both ranges (`long`)
  and only gives up when the unsigned side is 64-bit.  Landed: the lowering
  delegates to the semantic port (`sem_exprs.common_integer_type`), which
  also feeds `common_numeric_type` and `promoted_binary_operand_type`.  Locked
  by `test_mixed_signedness_integer_promotion_casts_both_operands`.

**The re-ranking after the batch.**  The leader (48 files) remains the explicit
format sink's `mt_str_buffer_clear` ordering (3z), then the contextual casts
(23) and the late proc/instance placement (21).

### Session 45, batch 10 (2026-11-03) — the explicit format sink, deferred format releases, the return ownership rule, and the assertion/signed-literal shapes: 414 → 420

**The re-ranking after batch 9.**  The 48-file leader was the explicit format
sink (3z), then the contextual casts (23) and the late proc/instance placement
(21).  Measured: the full corpus **414 → 420 match / 252 → 246 differ / 51
host-rejected / 0 self-rejected of 717 files** (+6 flips, 0 new differing files
by the before/after set comparison against the batch-9 binary); seven locking
tests added (733 tests / 19 files / 0 failed); bootstrap fixed point,
`test/mt` 60/0, examples 49/49, `sexpr lower` 420/246/51/0 and the LSP harness
30/30 + its 4 documented entries re-verified on the batch's frozen tree.
`test/mt/fmt_test.mt` is byte-identical to the host's dump.

- **The explicit format sink (3z).**  A statement-form
  `std.fmt.append_format/assign_format(ref, f"...")`,
  `String.append_format/assign_format(f"...")` or
  `str_buffer[N].append_format/assign_format(f"...")` is a *sink* on the host:
  the parts stream into the destination instead of building a `str` and copying
  it (`lower_explicit_format_sink_expression_statement`,
  `lowering/expressions.rb:488-861`).  Landed: `explicit_format_sink_info`
  (`std.fmt` function form, `String` method form, `str_buffer` receiver form;
  `.assign`/`.append` stay ordinary calls), `lower_format_sink_target`
  (`String`: the editable-method borrow / declared `ref[String]` parameter;
  `str_buffer`: the `data`/`len`/`dirty` addresses and capacity),
  `build_format_sink_parts` + `copy_format_sink_parts` (the host's part temps,
  the `__mt_fmt_part_len_N` custom length, and the `__mt_fmt_sink_str_N`
  copies for a `str` argument — and a `cstr` one in a buffer sink),
  the static shortcut (`std_string_String_assign/append` or
  `mt_str_buffer_assign/append`, no clear), and `emit_format_sink_dynamic`
  (`String`: `std_string_String_clear` for assign + one
  `std_string_String_append`/`std_fmt_append_*` per part; `str_buffer`:
  `mt_str_buffer_clear`, a `__mt_fmt_sink_offset_N`, the `str` view
  `{data = &data[0], len = capacity}`, one `mt_format_append_*` per part, and
  `*(&buffer.len) = offset`).  The custom-hook part takes the host's slice form
  (a `String` view at `data + offset`, the hook call, the expected-length check,
  the offset advance and the NUL).  Supporting shapes: the `str_buffer` `data`
  member is `array[char, N + 1]`, `as_str()` is the host's
  `{data, len = mt_str_buffer_len(...)}` aggregate, `.clear()` emits the
  four-argument `mt_str_buffer_clear`, and the C backend's helper takes
  `(char* data, uintptr_t cap, uintptr_t* len, bool* dirty)` with a `memset`;
  `uses_format_helpers` detects a direct `mt_format_append_*` call so a sink
  that never calls `mt_format_str_make` still pulls the helper block in.
  Locked by `test_explicit_format_sink_strings`,
  `test_explicit_format_sink_str_buffer`,
  `test_explicit_format_sink_static_format` and
  `test_str_buffer_sink_emits_the_four_argument_clear_and_format_helpers`.
- **Deferred format releases and the return ownership rule.**  A local
  declaration's or assignment's prepared cleanups are the host's
  `local_defers`: a dynamic format string's release runs at scope exit (or
  before a return), after later locals and their return temp — not immediately
  after the declaration.  A foreign call's cstr-temp free is the call's own
  `cleanup_statements` and stays immediate (the first attempt deferred both and
  regressed eight files — `std/env.mt`, `std/json.mt`,
  `projects/mtc/{loader/path_resolver,test/path_resolver_test}.mt` and four
  raylib examples — the before/after set comparison caught it).  The
  `place-or-emit` rule is `record_or_emit_local_cleanups`: format releases are
  recorded as defers, everything else is emitted.  A non-owning
  `return f"...".len` keeps the release and materializes the value into
  `__mt_return_value_N` before it; a `-> str` return transfers the buffer, so
  its release is dropped (`filter_return_format_cleanups`).  The assertion
  intrinsics' condition is now a prepared position (its setup hoists before the
  `IfStmt`; the cleanups follow it, matching the host's assert shape).  Locked
  by `test_format_release_is_deferred_out_of_a_local_declaration` and
  `test_return_format_cleanup_keeps_or_transfers_ownership`.
- **Signed literals take their declared context type.**  `literal_value_to_context_type`
  now dispatches a unary `-`/`+` literal through `int_literal_to_context_type`
  (the host's contextual inference), and the local-declaration arm uses the
  shared helper for every literal kind.  `let delta: short = -42` emits a
  `short` literal and a `short` unary.  Locked by
  `test_signed_literal_takes_the_declared_type`.

**The re-ranking after the batch.**  The new leaders are the contextual casts
(23), the array/const literal shape (57, `projects/mtc/src`), the late
proc/instance placement (21), the event runtime names (10e/4b), the async
frame field's nullable drop (~10) and a statement's line/path shape (~13).

### Session 45, batch 11 (2026-11-03) — contextual numeric casts, the synthetic function tail, and the propagation failure-return position: 427 → 443

**The re-ranking after batch 10.**  The contextual casts (23) led, followed by
the array/const literal shape (57) and the late proc/instance placement (21).
Measured: **420 → 427 match** with the contextual casts (+7), then **443 match /
223 differ / 51 host-rejected / 0 self-rejected of 717 files** with the synthetic
tail (+16), 0 new differing files by the before/after set comparison; the
compiler-source subset went **49 → 63 match**.  Three locking tests added (736
tests / 19 files / 0 failed); bootstrap fixed point, `test/mt` 60/0, examples
49/49, `sexpr lower` 443/223/51/0 and the LSP harness 30/30 + its 4 documented
entries re-verified on the batch's frozen tree.

- **Contextual numeric compatibility.**  The host's `lower_contextual_expression`
  ends with `cast_expression` when `contextual_numeric_compatibility?` holds: a
  compile-time numeric constant that fits the expected type, an integer-like
  value in a `char` context, an integer in a declared float/double context
  (the `contextual_int_to_float` flag), and a lossless external-numeric pair at
  an assignment through a raw-module field.  Landed: `contextual_numeric_cast`
  (the host's four arms; `try_evaluate_const_expr` for the folded constant;
  `numeric_int_fits_context` with the `2^24` float / `2^53` double integer
  bounds; `external_numeric_compatible` for the fixed-width pairs),
  `contextual_value_to_type` at the declared sites (local/assignment/return;
  the struct aggregate fields use `literal_value_to_context_type`), and
  `external_numeric_assignment_target` for the `std.c.*` receiver.  A
  foreign-call initializer bypasses the int→float arm — the host's local and
  assignment foreign branches emit the call's value directly; the first attempt
  without that gate regressed seven raylib files (`float size =
  GetScreenHeight()` gained a cast), all caught by the before/after set
  comparison.  `int_value_fits_type` remains the integer-range arm.
  Locked by `test_contextual_numeric_constant_casts`.
- **The synthetic function tail.**  The host's proc invoke/release/retain bodies
  and pfor/spawn workers live in one program-level creation-ordered
  `@artifacts.synthetic_functions` list appended after every module's functions
  (`assemble_modules`); the self appended `pending_synthetic_functions` to each
  module's own list, so a proc literal in `std.json` preceded the next module's
  functions (`std_json__proc_1__invoke` was the first difference in most
  `projects/mtc/src` files).  Landed: `lower_module` takes a program-level
  `synthetic_functions` vec, pushes the pending list there, and `lower()`
  dedup-appends it after the module-ordering loop.  Measured: **+16 flips**, 0
  regressions, and the compiler-source subset `49 → 63` match (the remaining
  compiler first differences are the raw-field type, the `or` short-circuit
  local and the `?` statement shape).  Locked by
  `test_synthetic_functions_follow_all_modules`.
- **The propagation failure-return position.**  The host's `?` failure
  terminator is `IR::ReturnStmt.new(value: failure_return, path:
  @ctx.analysis_path)` — the path is set and the line is nil; the self passed
  the `return` statement's line.  The failure returns now carry `line 0`/path
  set; the success binding keeps the statement's line/path (the first attempt
  cleared both and regressed `std/uri.mt`/`std/json.mt`/`std/cookie.mt` and two
  importers — the success local's line/path was the wrong site).  Neutral on
  the corpus count, locked by
  `test_propagate_failure_return_has_no_line`.

**The re-ranking after the batch.**  The new leaders are the array/const literal
shape (57), the raw-field type resolution (`b2QueryFilter.categoryBits` —
`uint` vs the raw `ptr_uint`), the `or` short-circuit local (`__mt_or_N`), the
`?` propagation's statement/return shape, the nullable field type drop
(`opaque_backing_names`), the late proc/instance placement (~21; the synthetic
tail is now closed), 10e/4b (the event runtime names), the async frame field's
nullable drop (~10) and a statement's line/path shape (~13).

### Session 45, batch 12 (2026-11-03) — the prefix-cast constant fold and the prepared `and`/`or` temp: 444 → 454

**The re-ranking after batch 11.**  The contextual/const cluster led with the
box2d `categoryBits` field and the raylib `or` conditions.  Measured: **443 →
444 match** with the prefix-cast fold (+1), then **454 match / 212 differ / 51
host-rejected / 0 self-rejected of 717 files** with the `and`/`or` temp (+10),
0 new differing files; two locking tests added (738 tests / 19 files / 0
failed); bootstrap fixed point, `test/mt` 60/0, examples 49/49 and `sexpr
lower` 454/212/51/0 re-verified on the batch's frozen tree.

- **The prefix-cast constant fold.**  `CompileTime.evaluate_prefix_cast` folds
  a constant through the cast's target primitive, wrapping integers to the
  target width/signedness (`uint<-MoverBit` → 2, `ubyte<-300` → 44).  The
  self's `try_evaluate_const_expr` had no `PrefixCast` arm, so
  `uint<-MoverBit` stayed unfolded and the box2d `categoryBits` field's
  compile-time numeric compatibility missed its outer `ptr_uint` cast
  (`b2.QueryFilter(categoryBits = uint<-MoverBit)`).  Landed:
  `evaluate_const_prefix_cast` (the target primitive, bool/int/float arms) and
  `wrap_const_integer` (the width mask and signed adjustment, width 64
  pass-through).  `examples/box2d/mover.mt` is byte-identical.  Locked by
  `test_const_prefix_cast_folds`.
- **The prepared `and`/`or` shape.**  The host's
  `prepare_binary_expression_for_inline_lowering` hoists a
  `__mt_and_N`/`__mt_or_N` result local when either operand's preparation
  produces setup: the left setup, `LocalDecl(result, left)`, then
  `if result { right_setup; result = right }` (and) or `if not result { … }`
  (or); no setup on either side keeps the plain binary.  The self lowered the
  operands and emitted the binary always (the right operand suspended into a
  `StmtExpr`).  Landed: `lower_short_circuit_binary`, wired into the binary arm
  when a hoisting window is open; it captures the left's setup length, lowers
  the right in a fresh window with the same mode, appends the right's cleanups
  to the enclosing window, and emits the host's temp/guard shape (nil
  line/path on the temp; the right's setup stays inside the then body).  The
  raylib `input_gamepad`/`loading`/`text_file_loading` family flips or moves
  deeper; +10 flips, 0 regressions.  Locked by
  `test_short_circuit_binary_hoists_the_result_temp`.

**The re-ranking after the batch.**  The new leaders are the foreign-call
argument/temp materialization (`__mt_foreign_arg_N` ordering, the `str as cstr`
`Member(data)` cast, the inline foreign-in argument), the array/const literal
shape (57), the nullable field type drop (`opaque_backing_names`), the `?`
propagation's statement/return shape, the late proc/instance placement (~21),
10e/4b (the event runtime names), the async frame field's nullable drop (~10)
and a statement's line/path shape (~13).

### Session 45, batch 13 (2026-11-03) — the variadic foreign `str` argument's cstr projection: 454 → 467

**The re-ranking after batch 12.**  The foreign-call argument/temp
materialization led, with a large raylib `TextFormat`/`DrawText` cluster: a
`str` local passed in a foreign wrapper's variadic slot.  Measured: **454 → 467
match / 212 → 199 differ / 51 host-rejected / 0 self-rejected of 717 files**
(+13 flips, 0 new differing files); one locking test added (739 tests / 19
files / 0 failed); bootstrap fixed point, `test/mt` 60/0, examples 49/49 and
`sexpr lower` 467/199/51/0 re-verified on the batch's frozen tree.

- **The variadic slot's cstr rule.**  A foreign wrapper's `...` slot has no
  declared parameter, so the self's `lower_foreign_call` lowered the argument
  with `lower_expr` and passed the `str` aggregate directly.  The host still
  applies the cstr projection: `text_format(c"%s", value)` →
  `IR::Cast(cstr, IR::Member(value, "data"))` for a cstr-backed value, a C
  string literal for a string literal, and the `mt_foreign_str_to_cstr_temp`
  copy otherwise.  Landed: `lower_cstr_argument` (the rule factored out of
  `lower_foreign_arg`'s `str as cstr` branch) and the variadic branch's
  `is_str_typed` call; the existing `__mt_foreign_arg_N` hoist/free machinery
  handles the temp.  The raw external `c.TextFormat` path is deliberately
  unchanged — the host leaves its variadic `str` argument bare (verified with a
  probe).  The `TextFormat`/`DrawText` family is byte-identical, +13 flips, 0
  regressions.  Locked by
  `test_variadic_foreign_str_argument_takes_the_cstr_projection`.

**The re-ranking after the batch.**  The new leaders are the remaining
foreign-call argument/temp materialization (`__mt_foreign_arg_N` ordering and
the inline foreign-in/mapping substitution), the array/const literal shape
(57), the nullable field type drop (`opaque_backing_names`), the `?`
propagation's statement/return shape, the late proc/instance placement (~21),
10e/4b (the event runtime names), the async frame field's nullable drop (~10)
and a statement's line/path shape (~13).

### Session 45, batch 14 (2026-11-03) — the foreign-call component protocol: 467 → 479

**The re-ranking after batch 13.**  The foreign-call argument/temp
materialization led (the `__mt_foreign_arg_N` ordering, the public aliases and
the inline foreign-in substitution), with the raylib/sdl3 families' first
differences.  Measured: **467 → 479 match / 199 → 187 differ / 51
host-rejected / 0 self-rejected of 717 files** (+12 flips, 0 new differing
files); three locking tests added (742 tests / 19 files / 0 failed); bootstrap
fixed point, `test/mt` 60/0, examples 49/49 (one transient host `emit-c` crash
on `async_stress_test.mt`; re-running both compilers on that file succeeded) and
`sexpr lower` 479/187/51/0 re-verified on the batch's frozen tree.

- **The three-pass mapping protocol.**  `lower_inline_foreign_mapping` now
  mirrors the host's `bind_foreign_mapping_arguments`: (1) the `as` boundary's
  public alias (`<name>_public`), reusing the argument's `IR::Name` when it
  already is one and materializing a `foreign_arg_public` temp otherwise, before
  any parameter value; (2) every referenced parameter's value in declaration
  order (the public alias supplies the source, `prepare_foreign_in_argument`,
  the str-buffer `mt_str_buffer_prepare_write` projection, the array→span
  coercion, and the address-argument materialization); (3) the `foreign_arg`
  temporaries decided by the reference-count/inlineability rule plus the
  `inlineable_single_direct_call_names` exception and the cstr cleanup.  The
  mapping substitutions are a fresh map for the three passes, so an argument's
  lowering never sees another parameter's replacement.  `clipboard_text.mt` and
  `compute_hash.mt` flip (the `GuiTextBox` buffer's `_public` alias no longer
  allocates a temp).
- **The `in` prepare hoist.**  `prepare_foreign_in_argument_mt` ports the
  host's rule on both the inline-mapping and simple paths: an `in` operand that
  is not addressable storage (an integer literal, a cast, a call) materializes
  into a `foreign_in` temp *before* the boundary projection, so the C never
  takes the address of a non-lvalue.  `depth_rendering.mt` flips;
  `skybox_rendering.mt`'s first difference moves deeper.
- **The cstr assignment metadata.**  `update_cstr_metadata_for_assignment_mt`
  ports the host's `update_cstr_metadata_for_assignment!`: a `str` local's
  cstr-backed flag is refreshed on every assignment — `= <cstr-backed value>`
  keeps it, a plain `str` or a compound assignment clears it.  `skybox_file_name
  = dropped_path` now copies through `mt_foreign_str_to_cstr_temp` instead of
  passing `.data`.
- **The nested result materialization.**  A value-position foreign call with
  cstr temporaries nested inside another expression now materializes its result
  into `__mt_foreign_result_N` before the frees — the host's
  `prepare_statement_lowered_foreign_call` shape.  The statement-root case
  (assignment/local/return destination) still stores the call directly (the
  host's `lower_foreign_call_components` path), via the now-set
  `hoist_root_ep` on the local-declaration, assignment and format-sink
  windows.  Nine files flip (`stream_callback`, `loading_vox`, `skybox`,
  `simple_particles`, `3d_drawing`, `boxed_text`, `inline_styling`,
  `rectangle_bounds`, `sprite_fonts`).

**The re-ranking after the batch.**  The new leaders are the remaining
foreign-call cstr-temp ordering and nested `foreign_expr` shapes, the array/const
literal shape (57), the nullable field type drop (`opaque_backing_names`), the
`?` propagation's statement/return shape, the late proc/instance placement
(~21), 10e/4b (the event runtime names), the async frame field's nullable drop
(~10) and a statement's line/path shape (~13).

### Session 44 (2026-10-07) — `lower` Track 3 item 3r: the struct equality desugaring

Goal: the ranked item — `s_mouse_joint != b2.b2_nullJointId`
(`examples/box2d/common.mt`, the census's ~30-file leader; `body_move.mt`'s
first difference at byte 579,507).  Baseline at this commit: **131 match / 535
differ / 51 host-rejected / 0 self-rejected of 717** (session 43's close).

- **Root cause** (measured on both dumps): the self desugared external-struct
  equality in the lowering
  (`(IR::Unary "!" (IR::Call "mt_struct_eq_std_c_box2d_b2JointId" …))`) *and*
  carried the field-wise helper as an IR function, because raw (`external`)
  modules emit only includes: their structs never enter `Program.structs`, so
  the C backend's `register_equality_type` had no field layout to synthesize a
  helper from.  The host keeps `(IR::Binary :operator "!=" … :type bool)` and
  synthesizes `mt_struct_eq_<T>` in its C backend from the *type object's*
  fields (`c_backend/runtime_helpers.rb:135-172`, `feature_detection.rb`'s
  `aggregate_equality_types`); its IR carries no helper at all (the host's
  `body_move.mt` dump has zero `mt_struct_eq` occurrences, the self's had the
  calls plus two helper functions).
- **Landed**: `Program.external_structs` (a new `ir.ExternalStructLayout(key,
  fields)` section — a non-declaration section the dumper ignores, like
  `monomorphized_structs`) carries the layout of every external struct that
  participates in equality; the lowering registers it at the comparison
  (`register_external_struct_layout`, transitively for nested external structs,
  keyed by `naming.type_c_key`) and returns the host's `IR::Binary`; the C
  backend registers such types into `struct_eq_set` from the layout
  (`external_eq_fields`, keyed by `c_type`'s C name) and emits the helper
  through the existing `emit_struct_eq_helper`/`emit_eq_field_guard` path —
  `equality_fields_for` serves the forward declarations, the helper emission
  and the `mt_str_equal` gating.  Deleted: `ensure_equality_helper_for_struct`,
  `struct_field_differs_condition` and the `LowerCtx.struct_equality_helpers`
  memo.
- **Emitted C**: byte-identical to the host's —
  `static bool mt_struct_eq_b2JointId(struct b2JointId left, struct b2JointId
  right) { … }` with the same three field guards (checked against
  `ruby -Ilib bin/mtc emit-c examples/box2d/body_move.mt`); the helper *name*
  now matches the host's (`mt_struct_eq_b2JointId`, not the lowering's
  `mt_struct_eq_std_c_box2d_b2JointId`).
- **Measured**: the identical-corpus subset comparison (`std examples test`,
  568 files) reads **122 match / 399 differ / 47 host-rejected / 0
  self-rejected on both binaries**; the per-file set shows **30 files' first
  difference deeper (+21,667 to +21,677)** — the whole `examples/box2d/**`
  family — with 0 flips, 0 shallower, 0 newly differing, 0 lost.  Full corpus:
  131/535/51/0 (set unchanged; the same 30 deeper).  The newly exposed first
  difference is **3s** (the array-length literal from an imported constant:
  `common.mt`'s `random_polygon` renders `array[b2Vec2, 8]` on the host and
  `array[b2Vec2, 0]` on the self).
- **Locked by**
  `test_external_struct_equality_keeps_the_binary_and_registers_the_layout`
  (a raw `std.c.raw.lib` fixture: the dump keeps the `IR::Binary`, contains no
  `mt_struct_eq`, and `Program.external_structs` carries both the compared and
  the nested struct's layout with 2 fields each) and
  `test_external_struct_equality_helper_is_synthesized` (the emitted C carries
  the forward declaration, both field guards and `!mt_struct_eq_Part(a, b)`).
- **Gates** (frozen tree, `tools/gates.sh --run`): dev build + 19/0; bootstrap
  fixed point (`stage2.c == stage3.c`) + 19/0; `test/mt` 60/0; `sexpr_lower`
  131/535/51/0; examples 49/49.  Smoke: `body_move.mt` builds with the dev
  compiler and its headless run (rc 134, `array index out of bounds`) is
  identical pre/post fix.
- **Item 3s (landed in the same session) — the array-length literal from an
  imported constant.**  `var points: array[b2.Vec2, b2.B2_MAX_POLYGON_VERTICES]`
  (`common.mt`'s `random_polygon`, the box2d family's new first difference at
  601,174) rendered `(Types::LiteralTypeArg :value 0)` where the host carries
  `:value 8`.  Root cause: the *lowering*'s `resolve_array_length_type` folded
  only single-part names and sent a dotted name to `resolve_array_length`, whose
  non-single-part branch is a bare 0.  Landed: the dotted case folds through the
  alias's module (`ctx.analysis.imports` → `find_imported_analysis` → the
  const's value expression evaluated with that analysis in `ctx`, restoring
  afterwards — the `imported_const_value_ir` swap pattern), and
  `try_const_eval_int` gained a member-access arm so the wrapper const's own
  value (`std/box2d.mt`'s `= c.B2_MAX_POLYGON_VERTICES`, and arithmetic over it)
  folds too.  Probes (all three now match the host): the wrapper chain → 8, the
  direct raw form → 8, a normal module's `public const` → 4.  Measured (same
  subset protocol, `build/stage2/mtc` (3r) vs `tmp/mtc-dev`): 122/399/47/0 on
  both, **30 files' first difference deeper again (+19,298 min)**, 0 flips,
  0 shallower, 0 newly differing, 0 lost; the full corpus stays 131/535/51/0.
  Locked by `test_array_length_folds_through_an_imported_const`.  Residue: the
  analyzer's own dotted-const branch still records `ty_error` for a chained
  imported const (its fold uses the current module's tables and
  `ModuleBinding` carries no import aliases); invisible on the dump and in the
  corpus — see Track 3's 3s entry.
- **Item 3t (landed in the same session) — the dyn vtable slot's function
  type.**  `sample.vtable.on_step(…)` typed the member `ptr[void]` (the
  fallback) where the host carries the interface method's `Types::Function`
  (`body_move.mt` byte 620,472 after 3s).  Root cause:
  `dyn_vtable_method_fn_type` looked the slot type up in the *generated*
  `mt_vtable_<Iface>` struct — which is created in the ctx of the module whose
  `adapt` site lowers, while the dispatch site is the module that *declares*
  the interface (in the corpus: `common.mt` declares `Sample` and its `run`
  dispatch; the examples adapt) — so the lookup missed.  The host's
  `dyn_vtable_struct_type` never consults the generated struct: it builds the
  slot from the interface binding.  Landed: the interface declaration is the
  fallback (`find_interface_analysis` → `data: ptr[void]` + the method's
  `resolve_field_type_ref`'d parameters; the struct lookup stays first so a
  generic instantiation's substituted forms still win).  Measured (same subset
  protocol, the 3s `build/stage2/mtc` vs `tmp/mtc-dev`): 122/399/47/0 on both,
  the same 30 files deeper (+1,925 each), 0 shallower/newly differing/lost;
  **the full corpus goes 131 → 132 match / 535 → 534 differ** —
  `projects/stress/src/engine/interfaces.mt` flips.  The fixture (interface +
  dispatch in one module, the `adapt` site in another) is byte-identical to the
  host end-to-end.  **The type was a real miscompile**: the pre-3t self binary
  aborted `array index out of bounds` (rc 134) running `body_move.mt` where the
  host (and the post-3t self) run the render loop (rc 124 under the 10 s
  sandbox) — the slot's function type feeds the C backend's indirect call.
  Locked by `test_dyn_vtable_member_takes_the_interface_method_type`.
- **Item 3u (landed in the same session) — the `out`/`inout` foreign boundary's
  alias deepening.**  `b2.world_draw(world_id, s_debug_draw)` (the wrapper's
  `foreign function world_draw(world_id: WorldId, inout draw: DebugDraw) =
  c.b2World_Draw`) typed the address-of `ptr[DebugDraw]` where the host has
  `ptr[b2DebugDraw]` (`body_move.mt` byte 622,397 after 3t).  Root cause: the
  `in` branch qualifies then deepens (`deep_alias_target(qualify_type(…))`, 3q),
  the `out`/`inout` branch deepened the *unqualified* resolve first — the
  std.c pairing `deep_alias_target` resolves
  (`ty_imported("std.c.box2d", "DebugDraw")`) never existed at deepen time, and
  `qualify_type` produced it afterwards (which is why the emitted type carried
  the alias name paired with the *target* module).  Landed: that branch now
  qualifies before deepening too (a raw pointer slot is unaffected — the
  deepener leaves generics alone).  Measured (same subset protocol, the 3t
  `build/stage2/mtc` vs `tmp/mtc-dev`): **8 flips** — `examples/box2d/common.mt`,
  `compound_shapes`, `confined`, `human`, `kinematic`, `rounded`,
  `tiny_pyramid` and `examples/raylib/core/3d_camera_free.mt` — the subset
  122 → **130 match**, with **42 files' first difference deeper** (23 box2d, 14
  box3d, 5 raylib; +181 … +252,788), 0 shallower, 0 newly differing, 0 lost;
  the full corpus **132 → 140 match / 534 → 526 differ**.  The `inout` probe
  (raw `struct Def` + wrapper `type MyDef = c.Def` + `foreign function
  take_it(inout d: MyDef) = c.take_ptr`) is byte-identical to the host.
  Locked by `test_inout_argument_addresses_the_deepened_boundary_type`.
- **Item 3v (landed in the same session) — the array-storing receiver's borrow
  convention.**  `this.find_body_index(move_event.bodyId)` passed
  `(IR::Unary "*" (IR::Name "this" :pointer true))` where the host passes the
  `IR::Name` itself (`body_move.mt` byte 663,269 after 3u) — and the emitted C
  confirmed it: the host's method took `BodyMove *this` and the self's a
  `BodyMove` **by value** (a per-call copy).  Root cause: the self's method
  convention was `editable → ptr[T]`, everything else by value; the host's
  `pointer_lowered_method_receiver?` is `receiver_editable` **or**
  `type_contains_array_storage?` (`ContainsArrayStorageVisitor`: struct fields
  and nullable bases walked, only an `array` instance sets the flag — a 4-byte
  struct keeps the value convention, an array-storing one borrows; probed on
  both).  Landed: `receiver_by_pointer` + `type_contains_array_storage` port
  the rule and drive the method-function params (`lower_method`, the
  monomorphized-method site), the receiver argument (`build_receiver_arg`,
  now ctx- and `MethodInfo.is_async`-aware — async keeps the value convention,
  mirroring the host's exclusion) and the dyn vtable wrappers.  Measured (same
  subset protocol, the 3u `build/stage2/mtc` vs `tmp/mtc-dev`): **3 flips** —
  `examples/box2d/contact.mt`, `examples/box2d/sensor_funnel.mt`,
  `std/noise.mt` — the subset 130 → **133 match**, with 15 files' first
  difference deeper (14 box2d + 1 test; +64 … +76,462), 0 shallower, 0 newly
  differing, 0 lost; the full corpus **140 → 143 match / 526 → 523 differ**.
  Locked by `test_array_storing_receiver_is_borrowed` (the pointer param, the
  `this` pass-through and the `&b` borrow at a value call site).
- **Item 3w (landed in the same session) — the dynamic format-string
  protocol.**  A dynamic format string wrapped its whole build in an
  `IR::StmtExpr` with self-invented `__mt_fmt_cap/off/result_N` names and
  `+=` accumulations; the host builds it as a *statement-level* protocol
  (`prepare_format_string_expression_for_inline_lowering` +
  `build_dynamic_format_string_temp_setup`): the setup hoists into the
  statement stream, the result temp is named after the most recent local
  declaration (`__fmt_<dest>`, `_cap`/`_off`, `_2` for repeats — the host's
  `env[:current_local_name]`/`fmt_counter`), the parts' temps come first and
  the `cap = cap + len(…)` accumulations after, a part is cast only when its
  type differs from its append argument, and a
  `mt_format_str_release(temp)` cleanup runs *after* the statement (dropped
  when the target owns the buffer — `reject_format_releases_for_assignment`).
  Landed: the `expr_format_string` arm builds into the statement's hoisting
  window and pushes the release to `hoist_cleanups` (skipped in `hm_return`,
  whose str case transfers ownership); `build_format_string_dynamic` mirrors
  the host's naming/order/cast shapes; `fmt_dest_name` (set by the local-decl
  arm; block-scoped, restored by `lower_block`) and the per-function
  `fmt_counter` (cleared at every function body) drive the names;
  `drop_format_release_cleanups` + `format_owning_target_type` mirror the
  ownership rule for locals and assignments; the dedicated
  `lower_format_string_local` fast path is gone (the general path now produces
  the host's `__fmt_<name>` temp + the local decl).  Measured (same subset
  protocol, the 3v `build/stage2/mtc` vs `tmp/mtc-dev`): the fixture (two
  format strings after one local — the `_2` suffix, the release, the no-cast
  part) is byte-identical end-to-end; **15 flips** — the whole box2d family
  (`body_move`, `body_type`, `bridge`, `circle_stack`, `drop`, `explosion`,
  `falling_hinges`, `prismatic`, `ragdoll`, `ray_cast`, `revolute`,
  `shape_cast`, `skinny_box`, `vertical_stack`, `wheel`) — the subset 133 →
  **148 match**, with 30 files' first difference deeper (15 raylib, 11 sdl3, 3
  box2d, 1 std; +31 … +32,056), 0 shallower, 0 newly differing, 0 lost; the
  full corpus **143 → 158 match / 523 → 508 differ**.  Locked by
  `test_dynamic_format_string_hoists_with_the_destination_name`.  Residue: the
  suspended-window (lazy region) case keeps the StmtExpr and no release; the
  custom `format_len`/`append_format` hook keeps the self's shapes (not
  corpus-visible).
- **Item 3x (landed in the same session) — the cstr-backed `str as cstr`
  argument.**  The census's "nested foreign-call argument" turned out to be the
  *`str` argument* itself: `DrawTextEx(GetFontDefault(), <str>, …)` — the host
  passes a **cstr-backed** value's `data` pointer directly
  (`cstr_backed_expression?`; the nested call already matched), the self always
  allocated an `mt_foreign_str_to_cstr_temp` copy.  cstr-backed =
  a `cstr`-typed expression, a string literal, another cstr-backed local, or a
  dynamic format string's result temp — the host's
  `register_prepared_temp!(…, cstr_backed: true)` marks the *prepared*
  identifier, which then flows into a local declaration's
  `cstr_backed_storage_value?` (the local inherits the flag; a *reassignment*
  does not clear it, which is why `debug_console.mt`'s `fps_text`
  (`let fps_text = f"…"`, later reassigned) still passes `data` directly).
  Landed: `ctx.cstr_backed_names` (per function, cleared with the other body
  state), registered by the local-decl arm via `cstr_backed_binding` (the
  lowered value's cstr type, a cstr-backed read — including the format temp
  the format arm registers — or a literal initializer) and by the format arm;
  `lower_foreign_arg`'s cstr branch emits the direct
  `(IR::Cast cstr (IR::Member … "data"))` for a cstr-backed read and keeps the
  malloc temp otherwise.  Measured (same subset protocol, the 3w
  `build/stage2/mtc` vs `tmp/mtc-dev`): the fixture (a literal local, a format
  local, a call result → two direct casts and one temp) is byte-identical; the
  raylib core family and `std/raylib/debug_console.mt` flip — **18 flips**
  (`2d_camera_mouse_zoom`, `3d_camera_first_person`, `3d_picking`,
  `highdpi_demo`, `input_mouse_wheel`, `input_multitouch`,
  `monitor_detector`, `random_values`, `smooth_pixelperfect`,
  `viewport_scaling`, `window_flags`, `window_letterbox`, `world_screen`,
  `circle_sector_drawing`, `ring_drawing`, `rounded_rectangle_drawing`,
  `writing_anim`, `std/raylib/debug_console.mt`) — the subset 148 → **166
  match**, 1 file deeper, 0 shallower, 0 newly differing, 0 lost; the full
  corpus **158 → 176 match / 508 → 490 differ**.  Locked by
  `test_cstr_backed_strings_pass_data_directly`.
- **Item 3y (landed in the same session) — the `if` condition's prepared
  shape.**  The re-census's ~101-file leader (mixed_processor and the audio
  family): `if change_directory(dir):` wrapped the statement-lowered foreign
  call's setup in an `IR::StmtExpr` inside the condition, where the host treats
  a condition as a *prepared* position — `prepare_expression_with_cleanups` →
  `prepare_statement_lowered_foreign_call` → `materialize_prepared_expression`
  — so the argument temps, the `__mt_foreign_result_N` materialization and its
  cleanups precede the `IfStmt` and the condition reads the result temp
  (an `else if`'s setup lands at the head of the enclosing else body; other
  condition cleanups are duplicated into both branches).  Landed:
  `lower_if_chain` takes the output vec, opens an `hm_return` window per branch
  condition, emits the setup before the `IfStmt` and heads both branches with
  the cleanups; the async await-hoist call site splices the same shapes.
  Measured (same subset protocol, the 3x `build/stage2/mtc` vs `tmp/mtc-dev`):
  the fixture (a foreign `if` condition with a `str as cstr` argument) is
  byte-identical — arg temp, result temp, free, `IfStmt(result)`; **34 flips**
  (the raylib audio/models/textures families), 66 files' first difference
  deeper, 0 shallower, 0 newly differing, 0 lost; the subset 166 → **200
  match**, the full corpus **176 → 210 match / 490 → 456 differ**.  Locked by
  `test_if_condition_foreign_setup_hoists_before_the_statement`.  Residue: the
  `while` condition's prepared rewrite (`while true { setup; if !cond {
  cleanups; break } else { cleanups }; body }`, `loops.rb:45-68`) is not
  ported — no current leader.
- **Item 3aa (landed in the same session) — the monomorphized null return.**
  The post-3y re-census's ~134-file leader: `return null` in
  `alloc[T](count) -> own[T]?` (`std/mem/heap.mt`) typed the literal
  `(Types::Primitive :name "void")` where the host types
  `(Types::Nullable :base (own[int]))`.  Root cause: `lower_specialized_function`
  (the monomorphized *function* body path) never set
  `ctx.current_fn_return_type`, so the return arm's contextual null typing
  (`null_literal_to_context_type` against it, item 1b) saw the `void` default —
  `lower_function`, `lower_method` and `lower_specialized_method` all set it.
  Landed: the already-computed substituted `ret_ty` is installed around the
  body lowering (saved/restored).  Measured (same subset protocol, the 3y
  `build/stage2/mtc` vs `tmp/mtc-dev`): the fixture (`maybe[T](flag) ->
  own[T]?` ×2 `return null`, called as `maybe[Box]`) is byte-identical;
  **3 flips** (`std/bitset.mt`, `std/bytes.mt`, `std/mem/pool.mt`) with **97
  files' first difference deeper** (39 `test`, 30 `std`, 17 sdl3, 7 raylib;
  +6,370 … +237,261), 0 shallower, 0 newly differing, 0 lost; the subset 200 →
  **203 match**, the full corpus **210 → 213 match / 456 → 453 differ**.
  Locked by `test_monomorphized_null_return_takes_the_substituted_type`.
- **Item 3ad (landed in the same session) — the declaring-module grouping for
  monomorphized methods.**  The post-3aa re-census's ~91-file leader
  (`examples/nullable_and_variant_test.mt`'s first difference): the host groups
  a method's instances under the module that *declares* the extending block
  (`lower_functions` walks that module's declarations), so
  `Vec.create[String]` — instantiated while lowering `std.string`'s
  `split` — belongs at `std.vec`'s declaration slot.  The self's
  `SpecInfo.owner_module` carried the *receiver type's* module, which for a
  bare-name receiver registered by the creating module (`generic_instance_set`
  with `owner_module = ctx.module_name`) was the *caller* — the spec then fell
  into that module's leftovers (`std.string`'s fragment tail) instead of its
  declaration's position.  Landed: `ensure_monomorphized_method` records
  `gm.owner_module` (the declaring analysis found by the extending-block scan —
  the same module the body is lowered in) in the `SpecInfo`.  Measured (same
  subset protocol, the 3aa `build/stage2/mtc` vs `tmp/mtc-dev`): the fixture
  (`a.Holder[T]`'s `make` static + `clear`, instantiated `Holder[Thing]` from
  `b`) emits `make` before `clear` — pre-fix the order was reversed — and is
  byte-identical to the host; **3 flips**
  (`examples/raylib/core/random_sequence.mt`, `std/graph.mt`,
  `projects/mtc/src/mtc/lsp/utils.mt`) with **122 files' first difference
  deeper** (36 `test`, 24 `std`, 17 sdl3, 4 raylib), 0 shallower, 0 newly
  differing, 0 lost; the subset 203 → **205 match**, the full corpus **213 →
  216 match / 453 → 450 differ**.  Locked by
  `test_method_specializations_group_under_the_declaring_module`.  Residue: the
  *instance order within one declaration* follows the host's creation-wave
  semantics (see Track 3's 3ad entry — the `std_mem_heap_release__*` order in
  `data_structures.mt` needs the host's per-module walk interplay).
- The post-3ad re-census (the biggest buckets): a local declaration's
  nullable-typed operand (~51), a foreign argument's `null` literal (~34), the
  unsigned-boundary literal (~16), the `mt_str_buffer_*` decls (~15) and a
  statement's line/path shape (~13).  Carried into Track 3's ranked items
  3af/3ae/3ac.

### Session 44, batch 21 (2026-10-10) — 8A stage D: the proc lifecycle

**The last stage of the proc item**: the contained-proc retain/release
lifecycle (the host's `lowering/proc.rb:276-362`), which the probes'
`add.release(add.env)` / `adder.retain(adder.env)` shapes exposed.  All six sync
proc probes are now byte-identical.

- **The walkers** (new helpers after `proc_lifecycle_fn_type`):
  `contains_proc_storage_type` (the host's `utils.rb:486-500`; struct fields
  recurse through `struct_fields_of`, with a depth guard; a generic instance's
  type-parameter fields are a recorded residue), `proc_contained_release_stmts`,
  `proc_nullable_release_stmts` (guarded by the proc's `invoke` field),
  `proc_contained_retain_stmts`, `proc_selective_retain_stmts` (a fresh proc
  literal transfers ownership; a struct field takes its own AST source from the
  RHS aggregate literal's named argument, the host's `ast_field_source`) and
  `proc_expr_contains_proc_expr` (the host's fresh-expression walk).  The
  release/retain calls are `p.release(p.env)` / `p.retain(p.env)`.
- **Local declarations**: a proc-containing local records a **guarded release
  defer** (the self's `record_defer`, i.e. the host's `local_defers` — flushed
  at every block end, branch exit and return in reverse encounter order) and
  retains a non-fresh initializer (`block.rb:824-830`).
- **Assignments** (`=` to a proc-containing target): the host's `proc_assign`
  shape — a `__mt_proc_assign_<N>` temp (the self's `fresh_c_temp_name(ctx,
  "proc_assign")`), the selective retain of the RHS, the guarded release of the
  old target, then the store (`block.rb:583-590`; the same rule covers the
  async assignment path, which shares the arm).
- **Returns**: when defers are pending and the returned value is not fresh, the
  value is materialized into a `return_value` temp and retained before the
  defers flush (`block.rb:503-509`).
- **Proc captures**: a proc-storing capture is retained by its env (the inline
  setup's stores and the `__setup_env` fallback's body).
- **Async frames**: the ctor retains non-pointer proc-storing params
  (`frame_builder.rb:298-302`), and the release/cancel bodies release
  proc-storing param and local frame fields (guarded; `frame_builder.rb:455-470,
  551-564`).
- **Two ordering fixes the probes exposed**: the no-capture literal's synthetic
  functions and the fn→proc wrapper's must be emitted invoke, release, retain
  (the self had retain first), and `lower_fn_to_proc`'s invoke params take the
  proc type's own parameter names (`left`/`right`, not `arg_N`).
- **Measured**: `tmp/proc_probe.mt`, `tmp/proc_let_probe.mt`,
  `tmp/proc_fn_probe.mt`, `tmp/proc_sort_probe.mt` and `tmp/probe_b13.mt` are
  **byte-identical** (`proc_probe` 10,853 → identical; `proc_let_probe` 8,149 →
  identical; `proc_sort_probe` 138,141 → identical); `tmp/async_probe.mt` keeps
  its 199,969 residue (the delegating `wait` chain, not a proc shape).  All the
  sync probes **build and run identically on both compilers** (the refcount
  protocol's proof), as does the compiler's self-build (0 C errors) and both
  suites.  Corpus: **286/380/51/0** with the set unchanged and the dumps moving
  closer — `examples/language_baseline.mt` 1,717,013 → 1,742,976 of the host's
  1,760,611 and `test/mt/vec_test.mt` 675,596 → 680,290 of 687,612 — 0 flips /
  0 regressions / 0 shallower (the lifecycle sites sit behind those files'
  first differences).  Gates: dev build + 19/0, bootstrap fixed point (the
  lifecycle's refcount swap validated end-to-end), `test/mt` 60/0, sexpr_lower
  286/380/51/0, examples 49/49.
- **Item 8 is complete** (stages A–D landed across batches 19–21; the capture
  set, the counters, 8C's allocator half and 10c's insert landed earlier).
  Residues recorded: the lazy-region `__setup_env` fallback; generic-instance
  field substitution in `contains_proc_storage_type`; and the **proc counter
  numbering** — `examples/language_baseline.mt`'s `modvar_proc` literal is
  `__proc_10` on the self and `__proc_1` on the host (verified identical on the
  batch-20 and batch-21 binaries, i.e. pre-existing): the host's
  `@synthetic_proc_counter` ordering differs for module-level literals.

### Session 44, batch 20 (2026-10-10) — 8A stage C: the proc literal's IR shape

**The stage-A residue**: a proc literal's env setup now lands in the enclosing
statement stream, and the invoke/release/retain bodies take the host's naming.
`tmp/proc_probe.mt` and the new `tmp/proc_let_probe.mt` (a capturing literal in a
`let`) anchor it.

- **The literal.**  `lower_proc_expression_typed` follows the host's
  `lower_proc_expression_for_local` + `materialize_prepared_expression` pair:
  the temp names are requested in the host's order (the local base first, the
  env temp from it — `fresh_c_temp_name(ctx, "<base>_env")` — then the literal's
  own), the env setup is emitted into the *enclosing* statement's hoisting
  window (`__mt___mt_proc_expr_<N>_env_<M> = cast(mt_async_alloc(sizeof(env)))`,
  `__mt_ref_count = 1`, the capture stores reading the enclosing bindings), and
  the aggregate literal materializes into its own `__mt_proc_expr_<N>` local
  (`materialize_proc_literal`), whose Name is the expression's value.  The
  window is suspended while the synthetic helpers are built (their bodies use
  their own temp counters, as the host's do) and restored before the setup is
  emitted.  The separate `__setup_env` function survives only as the
  **lazy-region fallback** — a position with no prepared window (a recorded
  residue; the host has no such position).
- **The helper bodies.**  `invoke`/`release`/`retain` (and the no-op pair) now
  match the host byte-for-byte: the `env` parameter name (linkage
  `__mt_proc_env`), the cast local `__mt_proc_env_ptr` (`proc.rb:19`), and the
  capture unpack `LocalDecl name "<cap>" linkage "__mt_capture_<cap>"` with the
  body reading the linkage name (`proc.rb:27`).
- **Measured**: `tmp/proc_probe.mt`'s first difference moves 2,963 → **10,853**
  (the residue is stage D's retain/release lifecycle — the host's guarded
  `add.release(add.env)` at the branch exit and `adder.retain(adder.env)` after
  the call); the new `tmp/proc_let_probe.mt` starts at **8,149** (the same
  lifecycle); `tmp/proc_fn_probe.mt` and `tmp/probe_b13.mt` stay
  **byte-identical**; all proc probes build and run identically on both
  compilers.  Corpus: **286/380/51/0** with **2 files' first difference deeper**
  (`std/toml.mt` 588,011 → 693,567 and `test/mt/toml_test.mt`, +105,556),
  0 flips / 0 regressions / 0 shallower — the proc-heavy corpus files are
  masked by earlier differences, so the probe evidence carries this batch.
  Gates: dev build + 19/0, bootstrap fixed point, `test/mt` 60/0, sexpr_lower
  286/380/51/0, examples 49/49.
- **Residue (the next item)**: **stage D** — the contained-proc retain/release
  lifecycle (`lowering/proc.rb:276-362`): a proc local's guarded release at
  scope exits and returns, the selective retain for non-fresh values, and the
  struct-field/async-frame variants.

### Session 44, batch 19 (2026-10-10) — 8A stage A: the proc type representation

**The ranked item's first stage** (the proc value type + its C struct naming),
plus the fn-typed-local call shape the batch-18 probes exposed.  `tmp/proc_probe.mt`
(new fixture: a proc-typed parameter, a capturing and a non-capturing literal, a
`?`-style coercion) anchors it.

- **The value type.**  A proc value's IR type is now the closure's own
  `ty_function(is_proc = true)` — the analyzer's form, rendered `Types::Proc` by
  the dumper — instead of the `mt_proc_*` named struct.  Every production site
  changed: `qualify_type`'s proc arm, `resolve_type_ref`, the local-annotation
  path (`resolve_local_annotation_type`), `proc_alias_struct_type` and the
  type-alias pass now register the struct decl and return the function type;
  `proc_ensure_struct_decl` returns the value type (the struct stays a backend
  artifact in `Program.monomorphized_structs`); the proc literals
  (`lower_proc_expression_typed`, `lower_fn_to_proc`) carry `proc_ty` as their
  aggregate literal's type.  The old `proc_type_name_from_signature` is gone.
- **The C struct name (stage B).**  `naming.sanitize_c_identifier` ports the
  host's `sanitize_identifier` (`type_system.rb:247-250`: non-alnum runs to `_`,
  collapsed, stripped) and `naming.proc_type_c_name` ports `proc_type_name`
  (`type_system.rb:213-215`): `mt_proc_` + the sanitized `proc(<params>) -> <ret>`
  spelling, so `proc(int) -> int` → **`mt_proc_proc_int_int`** (the self's old
  `mt_proc_int_int`).  Elements render module-qualified (`naming.type_to_s_qualified`,
  the host's `to_s`), which fixed a **real name collision**: `proc(ptr[Entry])`
  for `std.toml.Entry` and `std.json.Entry` used to unify to one struct — the
  bootstrap's C build caught it (`std/vec.mt`'s `predicate.invoke` argument and
  `std/toml.mt`'s aggregate were the two error sites).
- **The C backend.**  `c_type`/`c_declaration` map a proc function type to the
  struct name (the array-element declarator case included), `by_value_dep_key`
  orders an embedder behind the proc struct, and `c_fn_ptr_declarator` now emits
  the host's parameter names (`int32_t (*invoke)(void *env, int32_t x)` — the
  host's `Types::Function` parameters are named).  The proc struct's field types
  take the host's shapes: `proc_invoke_field_type` is a plain function with the
  named `env` parameter followed by the proc's own names (the host's
  `proc_invoke_function_type`, `utils.rb:531-537`) and `proc_lifecycle_fn_type`
  names its `env` parameter; `lower_proc_call`/`lower_proc_field_call` type the
  `invoke` member with it (the host's member type, previously the *call's* type).
- **The fn-typed local call.**  `waiter(waiter_frame)` (a local of `fn` type):
  the self emitted a bare C-name `(IR::Call :callee "waiter" …)` with a `void`
  call type; it now emits the host's Name-typed callee
  (`(IR::Call :callee (IR::Name "waiter" :type (Types::Function …)) …)`), with
  the call's type falling back to the callee's return type when the analyzer
  recorded none (the `lower_proc_call` rule).
- **The bug the bootstrap caught** (a real one, not a gate artifact):
  `coerce_monomorphized_arg_to_proc` wrapped a bare function name with **the
  name's own type** — a plain `fn` — so after the change the proc literal's
  aggregate cast rendered as a *function-pointer* `(int32_t (*)(…)){ .env = … }`.
  It now takes the parameter's proc type (`param.ty`).  Before stage A the named
  struct had masked the difference.  Lesson: the fixed point is the C-level
  proof the dump sweeps cannot give.
- **Measured**: `tmp/proc_fn_probe.mt` (new: an `fn`-typed param called
  directly) is **byte-identical**; `tmp/proc_probe.mt`'s first difference moves
  731 → **2,963**; `tmp/async_probe.mt` 178,016 → **199,969**; `tmp/probe_b13.mt`
  stays **byte-identical**; `tmp/proc_sort_probe.mt` (new: `Vec.sort_by(fn_name)`)
  builds and runs identically on both compilers, as do the other proc probes.
  Corpus: **286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717**
  with **70 files' first difference deeper** (max +666,663 — the compiler's own
  sources: `imported_bindings/emit|main|methods|policy.mt`, `lowering.mt`,
  `bindgen.mt`, the DAP modules, the lowering/bindgen tests; plus `std/net/*`,
  `std/toml.mt`, `std/tar.mt`, `std/raylib/packed_assets.mt`,
  `projects/tetris/src/main.mt`), 0 flips / 0 regressions / 0 shallower.
  Gates: dev build + 19/0, bootstrap fixed point, `test/mt` 60/0, sexpr_lower
  286/380/51/0, examples 49/49.
- **Residue (recorded)**: the proc *literal*'s IR shape — the host inlines the
  env setup into the enclosing statement stream (`__mt_proc_expr_N` locals:
  `mt_async_alloc(sizeof(env))`, `__mt_ref_count = 1`, the capture stores) where
  the self still emits a separate `__setup_env` function and calls it; the
  invoke/release/retain bodies' naming (`env`/`__mt_proc_env_ptr`/`__mt_capture_<name>`);
  and stage D's retain/release lifecycle.  These are the next 8A sub-items, then
  the delegating `wait` chain's instances.

### Session 44, batch 18 (2026-10-10) — the async runtime shapes (10l and the vtable bodies)

**Item 10l plus the shapes the batch-17 probe exposed behind it** — the goal was
`tmp/probe_b13.mt`'s 14,909-offset residue (the no-await resume's `__mt_result`
local), which turned out to open a whole cluster: the resume's completion model,
the four vtable bodies, and the Task members' types.  All of it is now the host's
shape; the fixture is byte-identical.

- **The completion model (the batch's core).**  The host has no completion label:
  `async_complete_statements` (`async_lowering.rb:1271`) is emitted inline at
  every `return` and every `?`-failure — result store (when a value is given),
  `ready = true`, `if frame->waiter_frame != NULL { void *waiter_frame =
  frame->waiter_frame; frame->waiter_frame = NULL; frame->waiter(waiter_frame);
  return; }`, `return;`.  The self's `goto __mt_complete` + label/epilogue model
  is gone: `LowerCtx.async_resume_return_label` / `async_complete_label` /
  `async_result_c_name` are replaced by one `async_completion_active` bool (set
  for **both** the no-await and CPS resume bodies, cleared by the same
  proc/monomorphization sites that cleared the labels), `async_complete_statements`
  + `async_result_target` + `async_wake_fn_type` are the new helpers, and the
  resume tail follows the host: a **void** result whose lowered body can fall
  through gets a trailing completion (`async_block_terminates`, the IR mirror of
  the host's `cfg_block_always_terminates?`), and a non-void result gets none.
  The no-await path loses its zero-initialized `__mt_result` local, its label and
  its copy; a `?` failure in a no-await async body now completes the frame too
  (it previously emitted a bare `return` from the void resume — a latent bug).
- **The resume's result store.**  `return expr` stores directly into
  `IR::Member(Name("__mt_frame"), "result")` (the host's
  `async_frame_field_expression`), and `return await X` takes the same target
  through `lower_async_await_into`.
- **The vtable bodies.**  `set_waiter` types its `waiter` Name and the field
  targets with the wake function type (`fn(frame: ptr[void]) -> void`) and its
  `waiter_frame` Names as `ptr[void]` with `pointer false`; `release` gains the
  host's not-ready guard (`if !frame->ready { <per-await If(task.frame) {
  task.release(task.frame) }>, mt_async_free(raw), return }` — for **both** paths,
  and the per-await condition is the `frame` member itself, not a `!= NULL`
  compare); `cancel` is ported whole (already-ready early return,
  `cancelled = true`, the per-await `if task.frame { if task.cancel {
  task.cancel(task.frame) }; task.release(task.frame) }` block, `ready = true`,
  the `if frame->waiter_frame { … frame->waiter(__mt_waiter_frame) }` wake with
  its text-Name callee `__mt_frame->waiter`, `return`).  The function **order**
  is the host's too: resume, ready, set_waiter, release, take_result, cancel,
  constructor.
- **`ir.Expr.expr_assignment`** (new variant): the host's
  `IR::ExpressionStmt(IR::Assignment)` cancel stores (`cancelled`/`ready`, and
  the cancel wake's `waiter_frame = NULL`) are assignment *expressions*; the
  self's IR had no expression-position assignment, so the variant was added with
  its dumper (`IR::Assignment`, rendered exactly like the statement), the C
  backend renderer (`target op value`), the pretty printer and the visitor cases
  (`expr_result_type`, constant/reachability/slice/span/tuple/checked/builtin
  collectors) and `ir_expr_type`.
- **The Task members' types.**  `task_field_type(ctx, result_ty, field)` mirrors
  `Types::Task#fields` (`types.rb:590-664`): `frame` `ptr[void]`, `ready`
  `fn(ptr[void]) -> bool`, `set_waiter` with the `wake_fn` param, `release`/
  `cancel` `fn(ptr[void]) -> void`, `take_result` returning the result type.
  `async_emit_await` types every `await_N` member access with it (the callee
  members *and* the `frame` arguments) and the `set_waiter` call's third
  argument (the resume Name) with the wake function type; the ctor aggregate's
  field types now come from the same helper (batch 17's inline construction).
- **The async `main` linkage (newly exposed by the new
  `tmp/async_probe.mt`):** the host's `function_binding_c_name`
  (`utils.rb:1089-1092`) gives an async `main` the constructor linkage
  `<module>___async_main`; the self used `<module>_main`.  Fixed in this batch —
  `lower_module`'s async arm and `build_async_main_entrypoint`'s proc wrapper
  both take it.
- **Measured**: `tmp/probe_b13.mt` is **byte-identical** (81,575 bytes — the
  batch-17 14,909 offset is closed and the whole file matches); the new
  `tmp/async_probe.mt` (an async main, a no-await function, CPS chains, `?`
  propagation and a Result-returning failure path) moves its first difference
  23,882 → **178,016** (the residue is item 8A's proc types — see below) and its
  built programs **run identically on both compilers** (`v=42 / ok=42 / err2=1`,
  rc 0).  The corpus is unchanged as a set: **286 match / 380 differ / 51
  host-rejected / 0 self-rejected of 717** with **0 flips / 0 regressions / 0
  shallower** — 26 async-family dumps change behind item 8A's mask (their first
  differences are unmoved, as batch 17 predicted).
- **Newly exposed (recorded, not fixed)**: **8A's scope widened** — the
  `tmp/async_probe.mt` residue is (a) `std/async/libuv_runtime.mt`'s
  function-typed **parameter call** (`waiter(waiter_frame)`): the host's callee
  is a Name typed `Types::Function`, the self emits a bare C-name `IR::Call`
  (the 3fa sibling for a local/param binding); and (b) the delegating `wait`
  chain's instances (`std_async_wait__int`, `std_async_runtime_wait__int`) are
  absent from the self's dump — only the deepest implementation
  (`std_async_libuv_runtime_wait__int`) is emitted; plus the root proc's
  invoke/release/retain bodies.
- **Found, pre-existing (not fixed)**: the self's emitted C for
  `examples/async_stress_test.mt` / `async_network_lobby.mt` fails to compile
  (`std/net/channel.mt`'s async `send`/`send_reliable` and `session.mt` sites:
  `Channel *x = <Channel **>` — GCC's incompatible-pointer-types error; 66
  errors, identical on the batch-17 and batch-18 binaries).  Masked from the
  gates (the example gate compares emit-c diagnostics, and no `test/mt` file
  reaches those reachable-in-that-build sites).  Worth a ranked item once the
  async dump parity allows.
- **Locked by** the extended compiler suite (`tmp/mtc-dev test projects/mtc`:
  19 files / 0 failed, `test/mt` 60 files / 0 failed under both binaries) and the
  two probes' byte-level comparison; the probe files are session-local fixtures
  (`tmp/probe_b13.mt`, `tmp/async_probe.mt`).

### Session 44, batch 17 (2026-10-10) — the ctor aggregate's vtable entries

**Items 10j/10k — the vtable names, linkages and field types.**  The ctor's
task aggregate and the vtable functions: the host names the synthetic vtable
functions `<ctor>__ready_fn` … (linkage `<ctor>__ready`) and the resume
`<name>__resume` (linkage `<ctor>__resume`); the self used `<name>_ready` with
linkage `<ctor>__frame_ready`, and a single-underscore `_resume`.  The
aggregate's Names carry the Task struct's *field types*
(`async_info[:task_type].field("ready")` — a `Types::Function` with the
vtable's parameter names) where the self typed them `ptr[void]`.  The vtable
params themselves: the host's are `frame`/`__mt_frame_raw`,
`waiter_frame`/`waiter_frame`, `waiter`/`waiter` (the self used the `__mt_*`
names for both fields).

- **Landed** (`lowering.mt`): the five vtable linkage names are
  `j2(link_base, "__ready")` … and the functions' `name`s are `<linkage>_fn`;
  the resume's name takes the double underscore; the aggregate's five field
  types are built from the vtable signatures (`ready_field_ty`,
  `release_field_ty`/`cancel_field_ty`, `take_field_ty`, `wake_field_ty` and the
  `set_waiter` type with its `frame`/`waiter_frame`/`waiter` parameter names);
  the common vtable param is `name = "frame"` with linkage `__mt_frame_raw`,
  and the set_waiter extras are `waiter_frame`/`waiter` (their body reads
  renamed to match the C linkage).  Measured (probe): 5,243 → **14,909**.
- **10l — newly exposed (recorded)**: the *no-await* resume's result handling —
  the host lowers the returns straight into `frame->result` (a
  `IR::Member(__mt_frame, "result")` assignment; `step__resume`'s body has no
  `__mt_result` local and no `frame->result = __mt_result` copy), while the self
  declares a zero-initialized `__mt_result` local, stores returns into it and
  copies it at the label (`async_result_c_name` is only set on the CPS path;
  the store itself a text `Name` rather than the host's `Member`).  Repro
  `tmp/probe_b13.mt` at byte 14,909.
- **Measured**: the probe's first difference moved 5,243 → **14,909**; the
  `std examples test` subset reads 0 flips / 0 newly differing / 0 shallower
  (the async files' first differences are still masked by item 8A's proc type
  and 10l) and the full corpus holds **286 match / 380 differ / 51
  host-rejected / 0 self-rejected of 717**.
- **Gates** (frozen tree, `tools/gates.sh --run`): dev build + 19/0;
  bootstrap fixed point (`stage2.c == stage3.c`); `test/mt` 60/0;
  sexpr_lower 286/380/51/0; examples 49/49.

### Session 44, batch 16 (2026-10-10) — the nullable pointer model (10i(c)) and the ctor aggregate

**Item 10i(c) — `ir.Expr` `Name.pointer` and `LocalBinding.pointer` are now
`Option[bool]`.**  The host leaves a `Name`'s pointer unset for the async
parameter bindings and the ctor's param-copy values (`async_resume_env_for`,
`frame_builder.rb:296` — `:pointer nil`), while the self's plain bools rendered
`:pointer false`.  Landed: the two model fields became `Option[bool]`; a
paren-balanced sweep wrapped **all 210 `ir.Expr.expr_name(` sites and 36
`LocalBinding(` sites** in `some(...)`; the readers take `unwrap_or(false)`
(`pointer_member_receiver` and every other `n.pointer`/`lb.pointer` read in the
C backend, the lowering and the IR formatter); the dumper's `IR::Name` case uses
`field_optional_bool`; and `none` is emitted only at the two async-param places
— the ctor's param-copy value Names and the resume's `param_*` bindings (the
rule factored into `async_param_pointer`, shared with the ctor's `ir.Param`s).

**The ctor's task aggregate has no `value` field** (landed in the same batch):
the host's aggregate is `[frame, ready, set_waiter, release, take_result,
cancel]` (`frame_builder.rb:308-318`) — the result reaches the task through
`take_result` — while the self prepended a `value` field.

- **Measured**: the probe's first difference moves 3,962 → **5,243** (past the
  param reads/copies and the aggregate) and its residue is now **10j**; the
  `std examples test` subset reads 0 flips / 0 newly differing / 0 shallower
  (the async files are still masked by 10j/item 8A) and the full corpus holds
  **286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717**.
- **10j — newly exposed (recorded)**: the ctor aggregate's vtable entries — the
  host names them `<ctor>__ready`/`__set_waiter`/`__release`/`__take_result`/
  `__cancel` (functions.rb:201-205; the self's `ready_lk = j2(frame_c, "_ready")`
  gives `<ctor>__frame_ready`) and types each Name with the Task struct's
  corresponding function type (`async_info[:task_type].field("ready")`), where
  the self types them `ptr[void]`.  Repro `tmp/probe_b13.mt` at byte 5,243.
- **Locked by** the extended `test_async_ctor_params_and_refcounted_allocator`
  (the `param_x` read and the `x` copy both `:pointer nil`).
- **Gates** (frozen tree, `tools/gates.sh --run`): dev build + 19/0;
  bootstrap fixed point (`stage2.c == stage3.c`); `test/mt` 60/0;
  sexpr_lower 286/380/51/0; examples 49/49.

### Session 44, batch 15 (2026-10-10) — the async ctor body and the frame-store Members

**Items 10h and 10i(a/b/d) — the async bodies' store and ctor shapes.**  The
batch-14 probe's next differences: the self's ctor stored `ready = false` /
`cancelled = false` / `state = 0` (the host stores none — the refcounted
`mt_async_alloc` calloc is the initializer), passed the bare frame `Name` to the
resume call and the task aggregate's `frame` field (the host passes
`raw_frame_expr`, the frame's `ptr[void]` cast), marked the frame/raw `Name`s
`pointer true` (the pointer lives in the type on the host), and stored spilled
locals through the `__mt_frame->local_x` **text Name** where the host builds
`IR::Member(receiver `IR::Name("__mt_frame")`, member "local_x")`
(`async_frame_field_expression`).

- **Landed** (`lowering.mt`): the ctor's three zero-stores and the now-unused
  `bool_false` are gone; the ctor's resume call and the aggregate's `frame`
  field carry a `raw_cframe` cast; the four frame/raw `Name`s drop
  `pointer = true`; and **every store target** — the spilled-local value store,
  the direct-await store, the hoisted-await store, the discard's await/value
  stores and the `?`-propagate success store — is now the host's `Member`
  (the reads keep the text Name).
- **Verified at the probe level** (`tmp/probe_b13.mt`): the store *members* are
  now exactly the host's three (`local___mt_async_tmp_1`, `local_ok`,
  `local_discard_6`), the ctor region matches down to its single remaining
  difference — the param-copy value `Name`s' `:pointer nil` — and the
  resume-call/frame-aggregate casts match.  The corpus's first differences do
  not move yet (0 flips / 0 newly differing / 0 shallower on the `std examples
  test` subset; the full corpus holds **286/380/51/0**): they are masked by
  **10i(c)** and item 8A, which precede these sites.
- **10i(c) — recorded, not landed**: the resume body's `__mt_frame->param_<name>`
  reads and the ctor's param-copy value `Name`s are `:pointer nil` on the host
  while the self's `ir.Expr` `Name.pointer` (and the async param `LocalBinding`)
  are plain bools — the fix is the same `Option[bool]` treatment (210
  `ir.Expr.expr_name(` sites + 36 `LocalBinding(` sites + the dumper's
  `ir_expr_value`/`field_optional_bool` + the C backend's
  `pointer_member_receiver`/`n.pointer` reads and the lowering's three
  `n.pointer` reads), with `none` only at the async ctor's copies and the resume
  param bindings.  **10i(c) + item 8A (the proc type representation) are the
  remaining masks on every async body.**
- **Locked by** the extended `test_async_ctor_params_and_refcounted_allocator`
  (the resume-call cast, `:member "param_x"`, no `false` literal) and the
  batch-13 test's updated discard assertion (`:member "local_discard_6"`).
- **Gates** (frozen tree, `tools/gates.sh --run`): dev build + 19/0;
  bootstrap fixed point (`stage2.c == stage3.c`); `test/mt` 60/0;
  sexpr_lower 286/380/51/0; examples 49/49.

### Session 44, batch 14 (2026-10-10) — the async ctor params, the module-name nil, the refcounted allocator

**Item 10d — the async constructor params' `:pointer nil`.**  The async ctor
params rendered `:pointer false` on the self where the host renders the *unset*
`:pointer nil` (`analysis.rb:20` + `frame_builder.rb:291`:
`field_info[:pointer]` = `receiver_type && receiver_editable && name == "this"`):
nil for a plain function's params, `true` for an editable receiver (`this`),
`false` for a method's other params.

- **Landed**: `ir.Param.pointer` became `Option[bool]` (the host's nullable
  model) — all 45 construction sites carry `some(...)`, the async ctor loop
  computes the host's rule (`has_receiver`/`recv_editable`), the dumper renders
  through the new `field_optional_bool`, and the C backend and IR formatter read
  `unwrap_or(false)`.

**The synthetic types' `:module_name nil`** (landed in the same batch): the
host's module-less types (`<mod>__frame`, `mt_proc_*`, `mt_tuple_*`, …) carry
`module_name: nil`; the self models the absent module as `""` and rendered
`:module_name ""`.  The dumper now maps an empty module name to nil
(`field_module_name`, used by `ty_named` and `ty_variant_arm_payload`).

**Item 8C (first half) — the refcounted async allocator.**  The host allocates
every async frame (and proc env and event wait frame) through
`mt_async_alloc`/`mt_async_free` — a hidden header (magic + refcount) in front
of the block, so the allocation is *zeroed* (its `calloc` is why the host's ctor
needs no `ready`/`cancelled`/`state` zero-stores) and the free only returns the
block at refcount zero (`runtime_helpers.rb:224-255`; the `mt_async_retain`
helper is dead code — no call sites).  The self used `calloc(1, sizeof(frame))`
and plain `free`/`malloc` at six sites.

- **Landed** (lowering): the frame ctor's `calloc(1, sizeof)` →
  `mt_async_alloc(sizeof(frame))` typed `ptr[void]`; the frame release passes
  `__mt_frame_raw` to `mt_async_free`; the proc env (`build_env_setup_fn`/
  `build_capturing_release`) and the event wait frame
  (alloc/release) likewise.  The C backend emits the allocator block when used
  (`uses_async_memory_helpers` + `emit_async_memory_helpers`).
- **Measured**: the `tmp/probe_b13.mt` first difference moves 2,912 → **3,962**
  (past the params, the frame type and the allocation); the `std examples test`
  subset reads **0 flips, 0 newly differing, 0 shallower** (the async files'
  first differences are still masked by the earlier proc-type/constructor
  region) and the full corpus holds **286 match / 380 differ / 51 host-rejected
  / 0 self-rejected of 717**.
- **Newly exposed (10i)** — the async ctor *body*'s remaining shapes: (a) the
  self's `ready = false` / `cancelled = false` / `state = 0` stores, which the
  host omits (the refcounted `calloc` zeroes them); (b) the ctor's frame `Name`
  carries `:pointer true` on the self where the host uses `false` (the pointer
  lives in the type); (c) the ctor's param-copy value Names render
  `:pointer nil` on the host — an `ir.Expr` `Name`'s pointer would need the same
  `Option[bool]` treatment (a wide model change, its own item).
- **Locked by** `test_async_ctor_params_and_refcounted_allocator` (the
  `:pointer nil` param, the frame type's `:module_name nil`, the
  `mt_async_alloc`/`mt_async_free` callees, no `calloc`).
- **Gates** (frozen tree, `tools/gates.sh --run` + `--areas tests --run`):
  dev build + 19/0 (the new test included); bootstrap fixed point
  (`stage2.c == stage3.c` — the allocator swap validated end-to-end); `test/mt`
  60/0; sexpr_lower 286/380/51/0; examples 49/49.

### Session 44, batch 13 (2026-10-10) — the embedded-await temp and the discard field

**Item 10f — an embedded await hoists like the host's normalization.**  The
post-batch-12 census's async shape (`std/net/clock.mt`'s `measure_offset`,
`(await socket.send_to(request.as_span(), peer)).map_error(proc(...))?`): the
host's `normalize_async_expression` hoists an embedded `AwaitExpr` into a
`let __mt_async_tmp_<N> = <await>` LocalDecl (`fresh_async_temp_name`'s
per-function counter, normalization.rb:475), so the analysis registers the
frame field `local___mt_async_tmp_<N>` and the await's own field
(`await_0 Result`); the self's `?`-operand paths lowered the operand directly
(`lower_propagate_let`/`_assign`/`_return` → `lower_expr`), the embedded await
became a *synchronous* task unwrap with no field and no await registration
(`await_0 int` only, the later sleep).

- **Landed**: the three `lower_propagate_*` functions hoist the operand's
  embedded awaits first (`async_hoist_awaits`) when `ctx.async_cps_active`; and
  `async_hoist_awaits`'s temp takes the host's name —
  `ctx.async_tmp_counter` (the `fresh_async_temp_name` counter, reset per
  function) with `__mt_async_tmp_<N>`, so the field is
  `local___mt_async_tmp_<N>` (the old `await_tmp_<N>`/`local_await_tmp_<N>`
  naming is gone).
- **Item 10g — the `let _ =` discard field** (landed in the same batch; the same
  frame): the host's analysis registers `local_discard_<line>` for a `let _`
  declaration and its lowering *stores* the (awaited) value there
  (`async_local_decl_field_name`'s `_` case, `lower_async_await_statement`'s
  LocalDecl arm); the self's `lower_async_local` returned early for `_`,
  registering nothing and discarding the value.  Now the discard registers the
  field (field-only, via `async_register_unused_field`) and stores into it —
  `async_emit_await` with the field target for the await case, a plain
  assignment for the value case.
- **Measured** (the identical-corpus `std examples test` subset comparison,
  `build/stage2/mtc` pre vs `tmp/mtc-dev` post): **0 flips, 0 newly differing,
  0 shallower, 12 files' first difference deeper** — the whole `std/net` async
  family and the two async examples (`async_network_lobby.mt` 72,429 → 96,033,
  `async_stress_test.mt` 70,700 → 87,869, `std/net/channel.mt` 44,926 → 57,286,
  `lobby`/`manager`/`mux`/`rpc`/`session`/`sync`, `discovery.mt` 42,229 →
  48,208, `clock.mt` 43,829 → 47,724, `test/mt/net_sync_test.mt` 61,187 →
  73,547).  `clock.mt`'s `measure_offset`/`respond_to_sync` frames are now
  byte-identical to the host's, `local___mt_async_tmp_1`/`local_discard_194`
  included; the full corpus holds **286 match / 380 differ / 51 host-rejected /
  0 self-rejected of 717**.
- **Newly exposed** (the async bodies' next block — previously masked by the
  frame region): **10h**, the frame-field *store* shape — the host builds a
  store target as `IR::Member(receiver `IR::Name("__mt_frame")`, member
  "local_x")` (`async_frame_field_expression`) while the self stores through
  `IR::Name("__mt_frame->local_x")` (the *reads* use that name on both).
  Behind it sit the already-ranked **10d** (the async ctor params'
  `:pointer nil`, visible before every async body), the frame type's
  `module_name` rendering (`nil` vs `""`), and the `mt_async_alloc` vs
  `calloc` allocation (item 8's stage C) — each is the next blocker for the
  async family's bodies.
- **Locked by** `test_async_embedded_await_temps_and_discards` (the work frame's
  `local___mt_async_tmp_1`, `local_ok`, `local_discard_6` field list; the
  discard's store; no `await_tmp_` naming anywhere).
- **Gates** (frozen tree, `tools/gates.sh --run`): dev build + 19/0 (the new
  test included); bootstrap fixed point (`stage2.c == stage3.c`); `test/mt`
  60/0; sexpr_lower 286/380/51/0; examples 49/49.

### Session 44, batch 12 (2026-10-10) — the proc capture set and the program-scoped counters

**Item 10b's follow-on — the proc capture set is reference-based.**  The
post-batch-11 census's proc-env bucket (`projects/mtc/src/mtc/bindgen.mt`'s
first difference, and the `__env` structs across `std/`): the self's
`collect_locals_for_capture` captured *every* visible local into the env struct
(`std_json__proc_1__env: __mt_ref_count, current, key`; `std_net_clock`'s three
procs each captured four-to-six enclosing locals), while the host walks the proc
*body* (`proc_capture_entries`, `proc.rb:137-250`) in first-reference order and
captures only the free identifiers that resolve to an enclosing local — names
bound inside the proc (params, locals, `for` names, match bindings) shadow, a
name with no enclosing local (a module var/const/function) is not captured, and
a nested proc's body is skipped.  A proc whose only free names are module-level
(constants, like `std/net/clock.mt`'s `map_error` closures over `err_bad_packet`
and friends) gets **no env at all** on the host; the self synthesized envs with
refcounts for them.

- **Landed** (`lowering.mt`): `collect_proc_captures` (the host's
  first-reference-order walk) with `proc_capture_visit_stmt`/`_expr`/`_scope`/
  `_stmts`, `proc_capture_name_bound` (the proc's own scope stack) and
  `proc_capture_scope_add`; the enclosing binding (its `read_expr`, so a
  frame-bound async local still resolves) comes from `find_local`.  The old
  all-locals collector is gone.
- **Measured**: `std/json.mt` 7,207 → **290,642**, `std/toml.mt` 12,598 →
  **336,009**, `test/mt/toml_test.mt` 12,602 → 336,013,
  `examples/option_and_result_surface.mt` 263 → 16,563,
  `std/raylib/packed_assets.mt` 30,294 → 35,390, `std/net/discovery.mt` 40,458 →
  42,229; clock's phantom envs gone.

**The counters are program-scoped, not per module.**  Verifying the above exposed
the batch-11 counter's scope bug: `std/net/clock.mt`'s `respond_to_sync` read
`local_match_binding_3/4` where the host reads **5/6** — `lower_module` builds a
fresh `LowerCtx` per module, so the binding counter restarted at each module's
boundary while the host's `@async_binding_counter` is per *compile*
(`lowering.rb:129`).  The same class of bug sat on the proc symbols: the host's
`@synthetic_proc_counter` (`fresh_proc_symbol`) numbers globally — in
`projects/mtc/src/mtc/main.mt`'s closure the host's envs are
`std_json__proc_1__env` then `std_toml__proc_3..5__env` — and the self's
`ctx.proc_counter` restarted per module; worse, the self's function-to-proc
wrapper used its own `__fn_wrap_<N>` prefix where the host shares the proc
scheme (`resolve.rb:62`: `<module_prefix>__proc_<N>__invoke/release/retain`).

- **Landed**: `async_binding_cnt` and `proc_counter` became program-scoped
  module globals, both reset at the top of `lower()` (the host's
  `Lowering#initialize`); `lower_async_fn`'s prepass, the two async match sites
  and `lower_proc_expression_typed`/`lower_fn_to_proc` use them, and the
  fn-to-proc wrapper emits `__proc_<N>__*`.
- **Item 10c (landed in the same batch) — the async frame's position among the
  synthetic structs**: the host appends the frame *before* the body's lowering
  (`functions.rb:210`), so a body-created struct follows it; the self pushed
  after, so proc envs preceded the frame (`std_net_clock__proc_*__env` before
  `std_net_clock_measure_offset__frame`).  `lower_async_fn` now records
  `pending_synthetic_structs.len()` before the body and inserts the frame there
  (`Vec.insert`).
- **Measured (the batch)**: the identical-corpus full-sweep comparison
  (`build/stage2/mtc` pre vs `tmp/mtc-dev` post) reads **0 flips, 0 newly
  differing, 0 shallower, 68 files' first difference deeper** — the biggest
  movers `dap/server.mt` 64,382 → **651,011**, `imported_bindings/main.mt`
  20,684 → 556,975, `dap/handlers.mt` 48,494 → 582,457, `lsp/code_actions.mt`
  160,901 → 685,621, `bindgen.mt` 15,617 → 406,666.  The full corpus holds
  **286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717**.
- **Newly exposed** (the async frames' next block, both in
  `std/net/clock.mt`'s `measure_offset`/`respond_to_sync`): **10f**, the
  embedded-await hoist temp — the host's normalization hoists
  `(await socket.send_to(...)).map_error(...)?` into a
  `let __mt_async_tmp_1 = <await>` LocalDecl, so its frame carries
  `local___mt_async_tmp_1` *and* two await fields where the self has neither;
  and **10g**, the `let _ =` discard field — the host registers
  `local_discard_194` for `let _ = await socket.send_to(...)`, the self's
  `lower_async_local` skips the `_` name entirely.  Both recorded in Track 3.
- **Locked by** `test_proc_captures_and_counters_are_program_scoped` (a
  two-module fixture: alpha's env is exactly `__mt_ref_count, x` with the
  unreferenced `unused_outer` absent, beta's proc is symbol 2 and its awaited
  arm is `local_match_binding_4`; the pre-fix binary reads
  `alpha: x, unused_outer`, `beta__proc_1__env` and `local_match_binding_1`).
- **Gates** (frozen tree, `tools/gates.sh --run`): dev build + 19/0 (both new
  tests included); bootstrap fixed point (`stage2.c == stage3.c`); `test/mt`
  60/0; sexpr_lower 286/380/51/0; examples 49/49.

### Session 44, batch 11 (2026-10-10) — the async match bindings' frame fields

**Item 10b — the async match bindings take the host's names and shapes.**  The
post-batch-10 census's async shape (`examples/async_network_lobby.mt`,
`examples/async_stress_test.mt`, ~22 files): the self spilled every arm's
payload binding to a `local_<arm>_<binding>`-named frame field
(`local_failure_payload`, `local_success_q`, …) and referenced it in the resume
body, while the host emits (a) an *analysis-registered, never-referenced*
`local_match_binding_<N>` field for arms whose body awaits
(`analyze_async_statements!`'s MatchStmt arm, `analysis.rb:125-145` — post-order,
after the arm body's own locals) and (b) a plain `LocalDecl` for the binding
(`async_variant_match_arm_binding`, `async_lowering.rb:1323-1353`: the
field-key lookup never matches because the analysis and the lowering each
advance the shared `@async_binding_counter`, so the registered field stays
unused).  `recv_impl`'s frame (`std/net.mt:2296`) pinned it: the host's fields
are `… local_received, local_datagram, local_data, await_0`; the self carried
`local_failure_payload`/`local_success_payload` between them and the body wrote
`__mt_frame->…`.

- **The model** (validated on synthetic probes): the counter is per *compile*
  (`lowering.rb:129`), advanced (1) once per arm with an `as` binding whose body
  contains an await — the analysis registration, which also names the field
  `local_match_binding_<N>` — and (2) once per *lowered* payload-binding arm
  (`async_match_binding_field_key` at the `async_variant_match_arm_binding` call
  sites).  The passes interleave per async function (analysis, then that
  function's lowering), which is why the host's names are sparse (1, 4, 5, 6, 9,
  10, … in the corpus).
- **Landed** (`lowering.mt`): `LowerCtx.async_match_binding_counter` +
  `async_match_binding_names`; `async_prepass_match_bindings` (the
  analysis-style walk — recursing into each arm body first, then registering an
  armed-with-await arm; mirrors `analyze_async_statements!`'s statement cases)
  called from `lower_async_fn` before the body lowering;
  `async_register_unused_field` (field-only registration, so the host's dead
  field is reproduced without a local binding); `lower_variant_match_switch` and
  `lower_variant_match_goto` emit the binding as a `LocalDecl` in *both* the sync
  and CPS modes, advance the counter for payload-binding arms while
  `ctx.inside_async` (the host's lowering advance) and register the
  prepass-assigned field after the arm body; the match-*expression* path
  (`lower_variant_match_expr`) takes the host's plain `LocalDecl` shape with no
  spill at all (`expressions.rb:1166-1173` — its async path has no frame branch).
  The `local_<arm>_<binding>` spills and the goto path's `as`-field spill are
  gone.
- **Measured** (same subset protocol, the pre-fix `build/stage2/mtc` vs
  `tmp/mtc-dev` on `std examples test`): **0 flips, 0 newly differing, 0
  shallower, 22 files' first difference deeper** (the `std/net` async family +
  the two async examples); the full corpus holds
  **286 match / 380 differ / 51 host-rejected / 0 self-rejected of 717**.
  Cross-checked against the host on three probes (`tmp/probe_async_binding*.mt`):
  the frames match byte-for-byte, including the interleaved names (1 in the
  first async function, 6 two functions later).
- **Newly exposed** (the async files' next blocks): the proc env structs
  themselves (item 8 — `std_json__proc_1__env` captures `current` where the host
  captures only `key`: the capture-set analysis, and the `__proc_<N>` numbering);
  **10c**, the frame struct's *position* among the synthetic structs (the host
  pushes it before the body's structs, the self after —
  `std_net_clock__proc_*__env` before the frame); **10d**, the async ctor
  params' `:pointer nil` (a model change to `Option[bool]`).
  `event_stress_test.mt`'s next block is **10e** (item 4b's owner-qualified
  event runtime names and the host's shared `Subscription` struct — the self's
  runtimes key by bare name, so two same-named events in different structs share
  one runtime today).
- **Locked by** `test_async_match_bindings_use_local_match_binding_fields` (the
  counter interleaving: 1 then 4; the non-awaited arms get no field; the
  bindings are plain C locals).  It fails on the pre-fix binary (its dump has no
  `local_match_binding_*` and the `local_success_*` spills).
- **Gates** (frozen tree, `tools/gates.sh --run`): dev build + 19/0 (the new
  test included); bootstrap fixed point (`stage2.c == stage3.c`); `test/mt`
  60/0; sexpr_lower 286/380/51/0; examples 49/49.

### Session 44, batch 10 (2026-10-08) — the nested struct's qualified C name

**Item 10a — a nested struct's C name carries its parents.**  The post-batch-9
census's field-context bucket (83 files) is a mix; its cleanest shape is the
nested-struct naming: for `Rectangle.Edge` (`nested_struct_stress_test.mt`,
`event_stress_test.mt`'s `Container.Inner`) the host's IR keeps `:name "Edge"`
while its `:linkage_name` is `<mod>_Rectangle_Edge` — the analyzer's qualified
`"#{parent}.#{nested}"`, flattened for C — and the self's linkage was
`<mod>_Edge`.  Landed: `lower_struct_decl` takes the qualified *lookup* name and
a *linkage base*, and `lower_nested_struct_decls` threads
`<parent>.<child>` / `<parent>_<child>` down so deeper nesting chains.

Measured: 0 flips, 0 newly differing, 2 files deeper (`nested_struct_stress_test.mt`
1,012 → 7,303; `event_stress_test.mt` 21,949 → 22,496), 0 shallower.  Locked by
`test_nested_struct_linkage_carries_its_parent`.

**The bucket's remaining shapes** (the census's 83, ranked): the *async frame's*
extra `local_<arm>_payload` fields (~22 — the self adds payload projection fields
the host's frame does not carry: `async_network_lobby.mt`, `async_stress_test.mt`);
an *extra synthetic event-slot struct* (`mt_event_…__slot` in
`event_stress_test.mt`'s struct list where the host has `Subscription`); and a
*ref lifetime argument* rendering (`(Types::Generic :name "ref" :arguments
("@_mt_0" (…)))`, `memory_stress_test.mt`).

### Session 44, batch 9 (2026-10-08) — the const table's enum members fold

**Item 9a — a *const* array initializer's enum members fold to their values.**
The post-batch-8 census's 57-file leader is the compiler's own lexer tables
(`const TOKEN_TABLE: array[TokenKind, 19] = array[TokenKind, 19](TokenKind.dot_dot, …)`
in `projects/mtc/src/mtc/build.mt`, `build_cache.mt`, `formatter/*`): the host
folds each member to `(IR::IntegerLiteral :value 33 :type (Types::Enum
TokenKind))`, the self emitted the member names.  The rule is *positional*: a
first attempt in the runtime array arm regressed the local case
(`let kinds = array[Kind, 2](Kind.A, Kind.B)` keeps its names on the host) — the
fold belongs to the **const initializer** path, which is where it landed
(`try_const_array_literal_ir`, with the shared `enum_member_value_of_expr`
lookup: the member's own type names the enum, with the name-based fallback).

Measured: the corpus holds at 286 match (the files carry further differences)
and the subset set comparison reads 0/0/0/0 — but the compiler's own sources
advance hugely: `formatter/tidy.mt` **8,744 → 1,301,873**,
`formatter/cst.mt` 8,634 → 375,187, `build.mt` 22,979 → 118,893,
`build_cache.mt` 18,773 → 106,527 — 0 newly differing, 0 shallower.  Locked by
`test_const_enum_table_folds_members_to_values`.

### Session 44, batch 8 (2026-10-08) — the str_buffer structs ride the backend

**Item 8b (landed) — the synthetic `str_buffer[N]` structs leave the IR.**  The
post-batch-7 census's 17-file bucket: the self's *lowering* registered an
`IR::StructDecl mt_str_buffer_<N>`, which the host has not — it collects the
structs from the type universe in the **C backend**.  Landed with the
`external_structs` precedent (3r): a new backend-only `Program.str_buffer_structs`
field (the dumper ignores it), the lowering partitions its
`pending_synthetic_structs` so the `mt_str_buffer_*` entries ride there, and the
backend's merge pass (alongside `monomorphized_structs`) folds them into the
declaration list that every scan and the emission walk.  The dumps lose the
struct; the emitted C keeps the typedef and the definition (verified against the
host's `examples/raylib/core/clipboard_text.mt`: the same six mentions' shapes,
with the self's two extra `__mt_foreign_arg_public_N` temporaries a separate
open item).  Measured: **0 flips, 0 newly differing, 15 files' first difference
deeper by +33,141 … +400,294, 0 shallower** — the struct sat early in those
dumps.  Locked by `test_str_buffer_struct_is_not_in_the_dump` and
`test_emits_the_str_buffer_struct_from_the_backend`.

**Item 8a (reverted, evidence logged).**  The `const_ptr_of(buffer[0])` boundary
cast (`const_ptr[float]` passed as `const_ptr[void]`, 32 files): a *blanket*
"pointer-like argument of a different pointer type takes the parameter's type"
cast regressed **114 files** — the box2d family already carries its own
`ptr[void]` cast and the host adds nothing there, while the `AddressOf` shapes
want the cast.  The distinguishing rule is not yet pinned; the call site carries
the evidence in a comment.

### Session 44, batch 7 (2026-10-08) — the array element's checked index, backend pass

**Item 6a (landed) — the array-of-arrays element takes the checked index.**
The post-batch-5 census's 57-file leader: `POINTS_OF_INEST[0]` over
`array[array[float, 2], 6]` emitted `IR::Index` where the host emits
`IR::CheckedIndex`.  The lowering's carve-out is gone (an array receiver always
takes the checked index), and the *backend* now emits the host's shapes:

- the helper for an array element gets the nested declarator and a pointer to
  the element — `static inline float (*name(float (*array)[2],
  uintptr_t index))[2]` with the body `return &array[index];` — and the *plain*
  helper follows the host too (`float *array` + `&array[index]`, replacing the
  self's `float (*array)[N]` + `&(*array)[index]`, an equivalent but different
  spelling);
- every checked-index call passes the receiver *decayed* (`name(x, 0)`, not
  `name(&x, 0)`), matching the host's C byte-for-byte on
  `examples/raylib/shaders/julia_set.mt` (helpers and call sites).

Measured: **+1 subset flip** (`basic_voxel.mt`), 3 files deeper (+1,310 …
+4,938 — `julia_set.mt`, `palette_switch.mt`, `spectrum_visualizer.mt`), 0 newly
differing, 0 shallower; locked by
`test_array_of_arrays_element_uses_a_checked_index` (a byte-identical fixture).
The next shape in those files is the `const_ptr_of(array)` cast (`(IR::Cast
const_ptr[void] (IR::AddressOf …))` where the self emits a bare `AddressOf`
typed `ptr[void]`) — a follow-up.

### Session 44, batch 6 (2026-10-08) — the match scrutinee's hoist rule, the async names

**Item 6a — deferred to batch 7.**  Removing the array-of-arrays carve-out in
`lower_index_access` (so `POINTS_OF_INEST[0]` over `array[array[float, 2], 6]`
emits the host's `IR::CheckedIndex`) exposes a *backend* gap: the checked-index
helper for an *array* element needs the host's nested declarator
(`static inline float (*name(float (*array)[2], uintptr_t index))[2]`) and a
*decayed* call (`name(x, 0)`, not `name(&x, 0)`) — without them the emitted C
references an undefined helper.  Kept as the plain index with a pointer comment
at the site; a dedicated backend pass ranks it.

**Item 6b — the async frame/resume names use a double underscore.**  The host
derives them as `#{constructor_linkage_name}__frame` / `...__resume`
(`functions.rb:199-200`); the self used a single `_frame`/`_resume`.  Landed:
both names (and the resume function's `name`) take `__`.  Deeper-only: the 22
files of the `async`/`net` family move by exactly **+1,198** each; locked by
`test_async_frame_names_use_a_double_underscore`.

**Items 6c/6d — the match scrutinee's hoist rule and the synthetic return's
path.**  The host hoists a scrutinee into a `match_value` temp *only* for a
variant whose arms bind payloads and whose expression is not duplicable
(`expressions.rb:1148-1154`, `block.rb:847-853`) — an enum scrutinee reached by
a member access (`match h.kind` in `examples/box2d/bounce_house.mt`) switches on
the expression itself; the self materialized `__mt_match_scrut_N` for any
non-name scrutinee.  And the `return match …` hoist's synthetic return keeps
the statement's line/path where the self passed an empty path.  Landed: the
host's condition at both match sites (with the host's `match_value` name) and
the return's `source_path`.  **+4 subset flips** (`bounce_house.mt`,
`chain_shape.mt`, `path.mt`, `process.mt`); locked by
`test_match_member_scrutinee_switches_directly` and
`test_return_match_carries_the_statement_path`.

### Session 44, batch 5 (2026-10-08) — the scalar element fold, the raw call's literal

**Item 5a — a *scalar-shaped* constant array element folds.**  The post-batch-4
census's 57-file leader: the host folds `array[int, 3](int<-Kind.A, -1, 1 + 2)`
to `0`, `-1`, `3`, the self emitted the cast/negation/binary.  Landed: the array
arm folds elements whose *lowered* shape is a Name/Cast/Unary/Binary (a
compile-time constant) through `try_const_value_ir`, with the enum member's
value consulted *inside the cast fold* only (`int<-Kind.A` → 0; a bare enum
*member* reference keeps its name, so `std/log.mt`'s global initializer and
`b2HexColor`-typed array elements are untouched — the first cut folded those
and read 4 files shallower, which the batch's set comparison caught).
**+4 subset flips** (`keyboard_testbed.mt`, `bone_socket.mt`, `image_kernel.mt`,
`errno.mt`).

**Item 5b — the raw external call's literal takes the parameter's type.**  The
`in`-mode and `external`-call argument paths share the plain path's rule now
(`foreign_param_context_type` factored out of 3ag): `c.time(null)` in
`std/time.mt` carries `Nullable(ptr[time_t])` instead of `void`, and an `in`
parameter's `null` likewise.  Deeper-only (`custom_logging.mt` +8,484, `time.mt`
and `cookie.mt` +8,484 each).

Locked by `test_array_element_scalar_constant_folds` and
`test_extern_call_literal_takes_the_parameter_type`.

### Session 44, batch 4 (2026-10-08) — the element's aggregate, the cstr-backed `if`

**Item 4a — a compile-time constant array element inlines its aggregate.**  The
`raylib/*` colour tables (`array[rl.Color, 14](rl.ORANGE, rl.RED, …)`): the host
inlines each constant's aggregate (`IR::AggregateLiteral` with the `Color`
fields), the self emitted the constant's C name.  Landed: the `array[T, N](…)`
arm folds a Name-valued element through `try_const_value_ir` (which answers
*only* for compile-time constants — a variable reference stays a name), after
the contextual literal retyping so `array[ubyte, 4](0, …)` is unaffected.
**+6 subset flips**, `module_playing.mt` byte-identical.

**Items 4b/4c — the cstr-backed predicate recurses.**  3x's rule looked at the
*lowered* value (a Name in the cstr-backed set), missing a *syntactically*
cstr-backed expression: the host's `cstr_backed_expression?` accepts a string
literal, a cstr-typed/backed local, and an `if`/`unsafe` whose parts are all
cstr-backed.  Landed: `ast_expr_cstr_backed` (the syntactic mirror) used by
`cstr_backed_binding` (so `let t = if flag: "a" else: "b"` is cstr-backed) and
by the foreign `str as cstr` boundary (so a *direct* `if` argument passes
`.data` instead of the runtime temp).  `point_rendering.mt` and
`ellipse_collision.mt` are byte-identical; **+2 subset flips**.

Locked by `test_array_element_constant_folds_to_its_aggregate` and
`test_cstr_backed_if_passes_its_data_pointer`.

### Session 44, batch 3 (2026-10-08) — the function-typed callee, the defer's flat replay, every foreign literal

**Item 3fa — a function-typed module variable is called through its value.**
The post-batch-2 census's 73-file leader (`examples/box3d/*`'s `s_scene_draw()`,
`var s_scene_draw: fn() -> void = noop_scene_draw`): the host's callee is an
`IR::Name` carrying the function type, the self emitted a bare C-name callee (a
direct call).  Landed: `lower_call`'s identifier arm gains the function-typed
module-variable case (guarded by `module_var_type`, which answers only for
module-level variables, so function declarations keep the direct-call path) and
builds the callee through `lower_call_with_callee_expr`.  Deeper-only on the
subset (box3d `common.mt` +2,908) — it exposed the next item in those files.

**Item 3fb — a `defer` body replays flat.**  The host's
`lower_defer_cleanup_body` is `lower_block` (a flat statement list), so a braced
body's statements replay as *siblings*; the self went through the `stmt_block`
arm and wrapped each body in an `IR::BlockStmt`
(`examples/box3d/common.mt`'s three defers → `UnloadModel`, `b3DestroyWorld`,
`CloseWindow`).  Landed: the defer arm splices `lower_block`'s result into the
cleanup span.  **+17 subset flips** (the box3d family and `raylib/*`), and
`box3d/common.mt` is byte-identical.

**Item 3fc — every foreign-argument literal takes the parameter's type.**  3ae
handled `null`; the host's `lower_contextual_expression` retypes int/float/str
too (`raylib_opengl_interop.mt`'s `uint` literal where the self emitted `int`).
Landed: the plain path calls `literal_value_to_context_type` instead of the
null-only helper.  **+7 subset flips** (`raylib_opengl_interop.mt` byte-identical).

Locked by `test_function_typed_module_var_call_uses_a_callee_name`,
`test_defer_body_splices_its_statements_flat` and
`test_foreign_integer_argument_takes_the_parameter_type`.

### Session 44, batch 2 (2026-10-08) — the opaque alias, the null re-applied, the format counter's env

**Item 3ag — the foreign parameter resolves in its *declaring* module.**  The
gap batch 1's revert exposed: for `stdio.file_flush(null)` the param TypeRef
(`File?`, `std.stdio`) was resolved while the lowering had its context switched
to the raw target (`std.c.stdio`), where the bare alias name resolves to a
bogus `ty_imported("std.c.stdio", "File")` — the host has
`Types::Opaque FILE`.  Landed: `lower_foreign_arg` now takes the `ForeignInfo`
and resolves the param type with `ctx.module_name`/`ctx.analysis` temporarily
switched to `info.owner_module` (the same temporary-switch the `ForeignInfo`
builder already uses), then deepens and opaqueifies it
(`opaqueify_type(deep_alias_target(qualify_type(resolve_type_ref(…))))`).
`tmp/probe_flush.mt` is now byte-identical and its C emits `fflush(NULL)`
(no undeclared `mt_opt_std_c_stdio_File`); the bootstrap's stage 2 compiles and
the fixed point holds.  Locked by
`test_foreign_null_argument_resolves_the_alias_in_its_declaring_module`.
Follow-up worth watching: the `in`/`out` boundary types still resolve in the
*calling* context (they only deepen); no corpus file shows it today, but the
mechanism is the same.

**Item 3ae re-applied** on top of 3ag: a bare `null` foreign argument takes the
parameter's declared type (`Nullable(cstr)` for `load_shader(null, …)` ×39
files) — **+8 subset flips**, locked again by
`test_foreign_null_argument_takes_the_parameter_type`.

**Item 3wf — the dynamic format counter is env-scoped.**  The counter that
suffixes repeats (`__fmt_<dest>`, `_2` …) is created *lazily at the first use in
an env* and shared with that env's descendants (the host's
`env[:fmt_counter] ||= {}` on a `duplicate_env`'d hash): a sibling block whose
parent holds no counter restarts at 1.  The self's flat `LowerCtx` now mirrors
it with a visibility flag saved/restored in `lower_block` and the slot created
at the first `format_string_result_base` call.  `examples/box2d/convex_hull.mt`
flips (**subset 219 → 222**), and the fixture locks both halves — a same-env
sequence continuing (`__fmt_buf` … `__fmt_buf_4`) and sibling branches each
emitting `__fmt_index` with no `_2` (`test_format_counter_is_env_scoped`).

### Session 44, batch 1 (2026-10-08) — the guard-read decl, the literal's width; 3ae reverted on the opaque-alias gap

**Item 3af — the unannotated decl's type is *inference*, not the lowered value.**
The census leader (141 files; `std/string.mt`'s `let data_ptr = data` after
`let data = this.data else:`): the host's `lower_local_decl_stmt`
(`block.rb:718-729`) takes the decl type from `infer_expression_type(value)`,
and that inference mirrors `infer_expression_type`'s shape exactly — **an
identifier takes its binding's visible type** (the cache shortcut at
`resolve.rb:706` deliberately skips identifiers, so refinement/unwrapping live
in `lookup_value`), every other expression takes the analyzer's recorded type.
The lowered read carries the storage `Nullable(ptr[ubyte])` (the pointer-like
rule) while the inference is `ptr[ubyte]`.  Landed: the split rule in
`lower_local_decl`'s unannotated arm.  The measurement also proved the split is
*load-bearing*: the broad version (recorded type for identifiers too) regressed
**61 subset files**.  Measured: **216 → 228 match / 450 → 438 differ** (+12
flips: `examples/raylib/core/drop_files.mt`, `std/crypto.mt`, `std/fmt.mt`,
`std/gzip.mt`, `std/string.mt`, `std/url.mt` in the subset, six more outside it),
**59 subset files' first difference deeper** (min +30,394; max +288,383;
`delta_time.mt`, `process.mt`), **0 newly differing, 0 shallower**.  Locked by
`test_unannotated_local_infers_the_guards_visible_type`.

**Item 3ac — a bare integer literal picks the narrowest fitting width.**
`ulong<-0xFFFFFFFF` (`examples/box3d/*`): the host types the literal `long`
(`infer_integer_literal`: int → long → ulong, the narrowest that holds it), the
self `int` — an overflowing `int` in the IR.  Landed: the analyzer's rule ported
in `infer_expr_inner`, plus the binary-op harmonization keyed on the literal
*syntactically* (the host's `harmonize_binary_integer_literal_types` recognizes
`AST::IntegerLiteral`, not a type — the old `== "int"` guard missed exactly the
values this item re-types), plus the suffix precedence in
`int_literal_to_context_type` (`1u` stays `uint` against a `ulong` context; the
host checks the suffix first).  The harmonization relaxation regressed
`std/noise.mt` (`state * 6364136223846793005` must be `ulong` from its peer) —
caught by the in-batch set comparison and fixed before the gates.  Measured: 0
flips, deeper-only (box3d `common.mt` +75,571); locked by
`test_bare_integer_literal_picks_the_narrowest_fitting_type`.

**Item 3ae — the foreign `null` argument: implemented, then reverted.**  The fix
(typing a bare `null` foreign argument with the parameter's declared type; the
host lowers every argument with `expected_type: parameter.type`) was correct for
the raylib family (`load_shader(null, …)` → `Nullable(cstr)`) and measured
**+8 subset flips**, but it exposed a pre-existing gap on **opaque** bases:
`std.stdio`'s `File` (`public type File = c.FILE`, the raw module's
`opaque FILE`) resolves in the self to `Struct File` where the host has
`Types::Opaque FILE`, so a null typed `Nullable(File)` made the C backend
reference an undeclared `mt_opt_std_c_stdio_File` where the host emits
`fflush(NULL)` — the stage-2 gcc error that failed the first tier-2 run
(`projects/mtc/src/mtc/{dap,lsp}/protocol.mt`'s `file_flush(null)`; repro
`tmp/probe_flush.mt`).  Reverted, with a pointer comment at the call site.
**New ranked item (next batch): imported opaque aliases** — resolve
`alias.Type` through the imported binding's opaque declarations; 3ae re-applies
on top of it.

**Tooling**: `gates_dev_tests` hardened — the fan-out is capped at `nproc/2`
and a failing file is re-run once, alone, before it counts.  A 16-wide run
aborted `debug_info_test.mt` under browser memory pressure (it passes serially;
two consecutive green runs, 41 s each, after the cap).

**Batch gates** (frozen tree): `dev_build`; `dev_tests` 19 files / **671 tests /
0 failed**; `bootstrap --fast` **fixed point holds**; `test_mt` 60/0;
`sexpr_lower` **228/438/51/0**; `examples` 49/49; `cli_parity` 24/37/0 and
`lint_parity` 495/121 and the LSP harness (30 keys, 4 documented) all
**unchanged** — the analyzer touch moved no meter but the sweep.

### Session 44, tools pass (2026-10-07) — the gate loop's cost, halved

Goal: make the per-fix loop cheap enough that `lower` items land in batches
(user ask: the diffs were resolving at ~1 item/45 min).  Measured on the 16-core
box at session-44 load:

| step | before | after |
| --- | --- | --- |
| self suite (19 files, 669 tests) | 243 s — `tmp/mtc-dev test projects/mtc`, strictly sequential | **37.6 s** — `gates_dev_tests`: one process per test file under `xargs -P16` |
| bootstrap | ~26 min (five compiler builds: stage1, stage2, stage3, two `--keep-c` re-emits, a `stage2-self` rebuild) + the in-script suite | **11.7 min** — `--fast`: `--keep-c` from the start, no re-emit rebuilds, no `stage2-self` (the stage-3 build already *is* stage2 compiling itself), no in-script suite; `stage2.c == stage3.c` still verified by diff |

Root causes found: (1) the self's `test` accepts only a **directory** and parses
no `--jobs` (both advertised in the ported help; the host's fork-per-file runner
is `cli/commands/test.rb:208, 281-335`) — a bare file argument dies "not a
directory", and a stray `--jobs 16` lands in the path slot the same way, so the
suite was 19 sequential builds; (2) `bootstrap.sh` rebuilt the fixed-point C
files it had just emitted (because `--keep-c` was not passed on the real builds)
and rebuilt `stage2-self` that stage 3 had just produced.  The gate fan-out works
around the directory-only limit with one-file temp dirs (`gates_dev_tests`; the
test path does not touch the build cache, so the workers are independent — the
first run verified 19/0 rc=0 in 37.6 s).

**Logged as work** (Track 4 item 2): `test`'s missing file arguments, `--jobs`
and `--cc/--profile/--platform` — note `cli_parity.rb` does not exercise `test`'s
argument forms, so a green CLI column did not cover this command.  **Track 9**
(new): the self emits its own sources in 157 s against the host's 40 s (3.9×);
that gap is the remaining ~10 min of every bootstrap, so a profiling pass is the
one change that makes all future gates cheaper.

**Process change carried with it**: the per-fix loop is tier 1 only (dev build
~50 s + the focused sweep seconds warm + the 40 s suite); the tier-2 set
(`bootstrap --fast`, `test_mt`, the area sweep, `examples`) runs once per batch
of 3–5 fixes, on the frozen tree, with one plan record — not once per item.

### Session 43 (2026-10-07) — `lower` Track 3 item 3k: the refinement record's post-statement positions

Goal: the ranked item — `let start = reinterpret[ptr_uint](data)` (`data` a
guard-bound `ptr[ubyte]?` inside a `while` body; `std/mem/heap.mt`'s `contains`)
carried the storage `Nullable` where the host carries the refined `ptr[ubyte]`
(the census's ~255-file leader: the box2d/raylib/compiler families).

- **Root cause** (found by instrumenting `flow_type_at` and dumping the entry
  span): the record is appended in *check order*, and a compound statement's
  post-record — recorded after its body was checked — carried the statement's
  *start* position, while the scan took the **last-recorded** entry at or
  before the cursor.  The `while`'s post-record (`data` cleared, at the loop
  line) therefore shadowed the body's own `data → ptr[ubyte]` entry.  Session
  41's note named the wrong trigger ("after the guard's `continue`"): a minimal
  probe shows *any* guard inside a compound statement misses — both
  `loop_continue` and `loop_return` fail, `plain` (straight line) refines.
- **The host's model** (`semantic_analyzer/statements.rb:11-35`,
  `flow_refinement.rb`): a snapshot at `(line, column)` *before* each statement
  and at `(end_line, 1_000_000)` *after* it — `statement_end_line` is the last
  line of the statement's span — plus a replay at the statement's own start for
  a multi-line statement; the lookup (`latest_completion_snapshot`) walks the
  snapshots **in reverse** and takes the first whose position is at or before
  the cursor (the position is a filter, the record order decides).
- **Landed**: (a) `statement_end_line` + `stmt_own_line`/`body_last_line`/
  `statements_last_line`/`expr_last_line` ported from the host; (b)
  `check_stmt`'s post-record sits at the statement's end, and a multi-line
  statement replays it at its own start — but **the replay skips cleared
  transitions**: the host's replay is a full scope snapshot, while the self's
  delta record would otherwise emit the scope-exit clear at the *statement's
  start* and — recorded after the body's entries — shadow them under the
  (order-based) lookup; (c) the lookup keeps the *last record* rule.  Two wrong
  turns are worth recording: a greatest-position scan plus an end-position
  forcing fixed 3k but made the hover at a refined *parameter* answer the
  refined type (`docs/memory_stress_test.mt@39:24`: the host's replay carries
  the *outer* state and wins by record order — the self must mirror the quirk),
  and the unguarded replay shadowed the loop body's own entries.
- **Measured**: subset `std examples test` (the identical corpus for both
  binaries — `projects/mtc/src` is both compiler and corpus, so the full-corpus
  set can also move with the source edit), pre-fix `build/stage2/mtc` vs
  post-fix `tmp/mtc-dev`: **48/473/47/0** both sides; **209 files' first
  difference deeper (+30,767 each), 0 shallower, 0 newly differing, 0 lost**.
  Full corpus: 55/611/51/0 of 717 (unchanged).  `std/mem/heap.mt`'s `contains`
  is byte-identical through the reinterpret sites; its first difference moved
  **13,466 → 47,201** (the next item, **3l**: the assignment literal through a
  deref-member target, `ptr_uint` on the host vs `int` on the self).
- **LSP**: recovery 6/6 byte-equal; the harness reads its 4 documented entries
  (70 requests / 27 probes) and the pre-fix vs post-fix *self recordings* are
  byte-identical apart from the `stderr` announcement; the project audit reads
  its canonical set (below).
- **Locked by** `test_guards_inside_statements_keep_their_refinement` (the loop
  guard and the terminating-`if` shapes; asserts the refined source types and
  the absence of any `Types::Null` source type).
- **Item 3j (landed in the same session) — the simple-path call's raw return
  type.**  A *simple* mapping's emitted C call (`= c.getenv`, the raylib audio
  family) was typed with `info.return_ty` (the wrapper's declared `cstr?`,
  `Nullable(cstr)`) where the host types it with the raw declaration's return
  type (`ptr[char]`).  Landed: `simple_mapping_callee` reads the *mapping*
  expression (not the caller's callee — the first attempt looked at `call_ep`
  and found the wrapper's own name), unwrapping the call/prefix-cast shapes
  `resolve_foreign_c_name` already recurses through, plus the 3f lookup
  `mapping_call_return_type(ctx, info.owner_module, receiver, name)` on the
  simple path; the wrapper's `ret_ty` still types the result temp and the
  cleanups.  Measured on the same subset: 48/473/47/0 both sides, **100 files'
  first difference deeper, 0 shallower, 0 newly differing, 0 lost**;
  `mixed_processor.mt`'s first difference moved 209,821 → 211,625 (the
  *branch-position foreign-call setup*: the host hoists a setup into the
  branch's statement stream where the self wraps it in a `StmtExpr` — a
  follow-up on session 41's hoisting channel).  Locked by
  `test_simple_mapping_call_takes_the_declared_return_type`.
- **Item 3l (landed in the same session) — the `read(x) =` target's literal
  type.**  The read-target arm lowered the value with no contextual typing, so
  `read(header - 1) = 0` (heap.mt) kept an `int` literal where the host types it
  with the target's type (`ptr_uint`).  Landed: the literal set is factored into
  `assignment_value_to_target_type` (the host's `lower_contextual_expression`)
  and applied on the read-target path too.  **`std/mem/heap.mt` is
  byte-identical**; **26 files flip** (the heap-importing `std/**` family —
  `behavior_tree`, `binary_heap`, `blackboard`, `box`, `cmd`, `counter`,
  `deque`, `fsm`, `htn`, `iter`, `linked_map`, …), taking the sweep
  **55/611 → 81/585**, with 183 files deeper, 0 shallower, 0 newly differing,
  0 lost.  Locked by `test_read_target_literals_take_the_pointee_type` (its
  first fixture used a *nullable* pointer — a source the host rejects; the
  test caught it).
- **Item 3m (landed in the same session) — the call-argument and variant-field
  literals.**  The host lowers every call argument and variant arm field value
  with the parameter's/field's type as the expected type; the self kept the
  literal defaults (`int`, `float`).  Three seams landed on 3l's
  `literal_value_to_context_type`: plain calls (from the callee signature's
  params), method calls (`coerce_literal_to_mono_param`, against the
  *specialized* IR function's params — `lower_monomorphized_method` is the
  path ordinary method calls take; the first attempt patched
  `lower_method_resolved`, which never runs for them) and variant arm fields
  (`collect_variant_literal_fields`; non-generic variants — the generic case is
  **3o**).  The mono seam exposed a *pre-existing* divergence: a bare
  (suffix-less) float literal operand stayed at its default `float` type and
  was cast up (`(double) 2.718281828459045f`, truncating it) where the host
  re-types it against a float peer; the binary arm now does the same
  (`is_bare_float_literal`; an explicit `f`/`d` suffix keeps its own type).
  `test/mt`'s `test_binary_round_trips_floats` caught the truncation (the
  probe/emit-c comparison showed the self's C differing from the host's at the
  comparison literal).  Measured: subset 74 → 76 match (**2 flips**:
  `std/mem/arena.mt`, `std/mem/stack.mt`), 82 files deeper, 0 shallower, 0
  newly differing, 0 lost; full corpus **81 → 83 match / 585 → 583 differ**.
  Locked by `test_call_argument_literals_take_the_parameter_type`; also found
  on the way: **3p** (an unnamed variant-arm construction aborts the lowering
  where the host reports a sema error — pre-existing).
- **Item 3o (landed in the same session) — the prelude generic variant's arm
  field type.**  `Option[ptr_uint].some(value = 0)` (std/str.mt:220) kept an
  `int` field value: `variant_field_type_from_arm` looks the arm info up in
  `ctx.arm_payload_fields` under `naming.type_c_key(instance) + "_" + arm`,
  which only exists once a match or the `?`-propagation path registered it.
  Landed: on a miss the lookup registers the prelude instance's arm fields on
  demand — `variant_info_for_c_name` maps `std_option_*`/`std_result_*` back to
  the installed `Option`/`Result` `VariantInfo`, then the existing
  `register_arm_payload_fields`/`specialize_prelude_arm_info` specialize the
  `_phantom` fields against the instance.  The fixture is byte-identical;
  `std/str.mt` 198,147 → 201,728 and `body_move.mt` 420,484 → 424,065 (both now
  the **3i break half** — 3i-b below); 80 files deeper, 0 shallower/new/lost;
  the full set stays 83/583.  Locked by
  `test_generic_variant_arm_field_takes_the_instance_type`.
- **Item 3i-b (landed in the same session) — the `break` half of the loop-flow
  model.**  A `break` in a plain `while` was always a `goto __mt_loop_break_N`;
  the host emits a native `IR::BreakStmt` (its `loop_exit_statement` `:break`
  kind) and converts the target to a `:label` only inside a match's `switch`
  (`switch_loop_flow`/`switch_loop_target`).  Landed:
  `LowerCtx.loop_break_native` (set around a plain `while` body like session
  41's `loop_continue_native`) and `lower_switch_arm_body`, which clears the
  flag around the arm bodies of the three switch-backed match lowerings
  (`lower_match`'s enum path, `lower_scalar_match`,
  `lower_variant_match_switch`) — `continue` needs no invalidation (C's
  `continue` reaches the loop through a `switch`).  Measured: the shape fixture
  is byte-identical and **`std/str.mt` is byte-identical**; the subset went
  76 → 82 match (**6 flips**: `std/str.mt`, `std/map.mt`, `std/set.mt`,
  `std/hash.mt`, `std/encoding.mt`,
  `examples/raylib/shapes/math_angle_rotation.mt`), 74 files deeper, 0
  shallower/new/lost; the full corpus **83 → 91 match / 583 → 575 differ** (8
  flips).  `body_move.mt`'s first difference moved to the 3g flags/enum
  rendering.  Locked by `test_break_in_a_plain_while_is_native`.
- **Item 3g (landed in the same session) — the flags/enum type rendering.**  The
  raylib core family's first difference was a raw-module nominal rendering
  `Types::Struct` (`b2HexColor`, `CameraProjection`) where the host dumps the
  type *object*'s class.  Two dumper-side root causes: raw (`external`) modules
  emit no IR declarations (so `ty_imported` — and a module-qualified
  `ty_named` — fell back to Struct), and a flags declaration is an `IR::EnumDecl`
  with `is_flags`, which `named_type_class` classified `Enum` (no Flags case).
  Landed: `dump_ir_with_analyses` (the CLI passes `program.analyses`; plain
  `dump_ir` supplies an empty span so the tests keep their signature),
  `register_decl_kinds` (every analysis's declarations → `<module>.<name>` →
  class), `imported_type_class` (the qualified lookup for `ty_imported` and a
  module-qualified `ty_named`) and the ctx's `flags_names` set.  Measured: the
  fixture's class renderings match the host exactly; **35 files flipped** (the
  raylib core family), the subset 82 → 117 match with 83 files deeper, 0
  shallower/new/lost; the full corpus **91 → 126 match / 575 → 540 differ**.
  Only `main.mt` imports the dumper, so the LSP is untouched.  Locked by
  `test_raw_module_declaration_kinds_render_in_the_dump`.  The box2d family's
  next block is **3q** (the `const_ptr[T]` boundary type loses its element).
- **Item 3q (landed in the same session) — the foreign address-of's boundary
  type.**  `lower_foreign_arg`'s three address-taking sites typed the
  address-of with a `ptr[void]` placeholder; the host's `lower_addr_expression`
  takes the boundary's pointer type.  Landed: the plain `in` path types it
  `const_ptr[<resolved declared type>]` (`const_pointer_to(parameter.type)`),
  the `out`/`inout` path shares the cast path's `ptr[slot_ty]` (with the
  host's `foreign_slot_boundary_value_type` nullable unwrap), and the element is
  deepened through the wrapper's alias chain by `deep_alias_target` +
  `resolve_alias_targeting_module` (the qualifier keeps std.c-targeting aliases
  by name and pairs them with the target module — `("std.c.box2d",
  "WorldDef")` — so the lookup runs where the alias is declared and only
  accepts a target in that same module).  Measured: the three-module fixture is
  byte-identical (`const_ptr[Def]`), **5 files flipped** (the raylib shapes
  family), the subset 117 → 122 match with 55 files deeper, 0
  shallower/new/lost; the full corpus **126 → 131 match / 540 → 535 differ**.
  `body_move.mt`'s first difference moved to **3r** (the struct equality
  desugaring: `IR::Binary !=` on the host vs `!(mt_struct_eq_…)` on the self).
  Locked by `test_foreign_in_argument_addresses_the_resolved_boundary_type`.
- **Gates** (frozen tree, re-run for 3j, 3l, 3m, 3o, 3i-b, 3g and 3q): dev
  self-tests 19/0; bootstrap fixed point + 19/0; `test/mt` 60/0; examples 49/49;
  `cli:parity` 24/37/0; lint corpus 495/121 of 616; `sexpr lex` 717/717 and
  `parse` 713/0; `sexpr lower` 131/535/51/0 (3k's gates read 55/611 — the items
  are lowering- and dumper-side; only `main.mt` imports the dumper, so the LSP
  is untouched).
- Discovery worth keeping: `bin/mtc build` (the *host*) with a semantic error in
  a big module **spins for minutes** instead of failing fast — two 6-minute
  builds during this session (`bin/mtc check <file>` reports the same error in
  ~4 s, so check before building when editing the analyzer).

### Session 42 (2026-10-07) — the `sexpr_parity` host-output cache (tools)

Goal: stop re-running the host across the whole corpus on every sweep.  The host
is deterministic but expensive — one Ruby process per lex/parse file, a whole
compile per `lower` (measured: `std/color.mt` 1.10 s, `examples/raylib/core/
3d_camera_fps.mt` 1.93 s, `mtc/lowering/lowering.mt` 17.9 s on the host vs
0.007 / 0.068 / 2.5 s on the self) — so `tools/sexpr_parity.rb` gained
**`--host-cache DIR`** (the gates pass `tmp/sexpr-host-cache`); the self always
runs live, because it is the thing under test.

- **The key.**  `lex`/`parse`: the effective source's digest + inferred module
  name (their dumps are pure per-file reads).  `lower`: those plus the digests
  of every module the host's own resolution reads — the explicit imports
  transitively, plus the loader installers' implicit modules (`std.option`/
  `std.result`, and `std.async` for a module declaring an `async fn main`, both
  asked of the host's own `PreludeInstaller`/`AsyncRuntimeInstaller` objects so
  the rule cannot drift).  The recorded import *names* are re-resolved through
  the host's `ModulePathResolver` on every run — resolution only stats files —
  so a module appearing at an earlier root still wins and a moved resolution
  misses; the effective path applies the CLI's platform substitution
  (`foo.mt` → `foo.linux.mt`, `projects/tetris/src/platform_info.mt`).
- **Safety.**  Only `rc == 0` runs are stored; a file whose closure does not
  resolve/read is never cached; `lib/**`/`bin/mtc` changes wipe the cache via a
  revision stamp, and `CACHE_FORMAT` guards the key scheme.  A stale entry is
  therefore only possible if the host's resolution reads something the walk
  does not — and any resolution failure bypasses the cache entirely.
- **Measured** (717-file corpus, `-j 16`, `--self tmp/mtc-dev`): cold 4m04s →
  warm **58 s** (lex 3.6 → 0.9 s, parse 7.2 → 0.8 s, lower 210.8 → 48.9 s;
  2092 hits / 47 misses / 12 uncacheable / re-storing 0), with **every counter
  unchanged**: lex 717/717, parse 713 match / 4 host-rejected / 0 differ, lower
  55 match / 611 differ / 51 host-rejected / 0 self-rejected — the ledger's set,
  re-read cold and warm.  Through the gates themselves (`build/stage2/mtc`,
  `tools/gates.sh --areas codegen --only sexpr_lower --run`): the same
  55/611/51/0 at **217.9 s cold / 44.3 s warm**; lex 3.4 s / parse 7.3 s cold.
- **Locked by** fixture checks: cold→warm→edit-an-import→re-run (the edit
  misses and re-runs; the two stored dumps differ), a module appearing at an
  earlier `-I` root (misses by re-resolution), an `-I` change (misses), and an
  unresolved import (stays uncacheable, no entry, across runs).
- Tools-only change: no parity counter moved.  `tools/gates.sh`'s
  `sexpr_lex`/`sexpr_parse`/`sexpr_lower` pass the cache, as do the
  scoreboard's lex/parse/lower sections and `rake sexpr:parity` (via
  `HOST_CACHE`).  The full-corpus cache is **~1.5 GB** under `tmp/` — the
  `lower` dumps dominate; it is disposable (`rm -rf tmp/sexpr-host-cache`).

### Session 41 (2026-10-06) — `lower` Track 3: the statement-position hoisting channel (foreign-call shapes)

Goal: the ranked `lower` item — the census's largest bucket (~222 files, 205 in the
raylib family alone): a statement-lowered foreign call (a `str as cstr` argument
needs a `mt_foreign_str_to_cstr_temp`) was wrapped in an `IR::StmtExpr`, where the
host hoists the setup statements into the enclosing block (its
`prepare_expression_with_cleanups` split: `prepared_setup` before the statement,
`prepared_cleanups` after it).  Items 3d (the pointer-like foreign argument),
3e (the mapping-argument temp rule), 3f (the mapping call's return type) and 3c
(the guard-bound nullable pointer arithmetic) landed in the same session.
Baseline at this commit: **44 match / 622 differ / 51 host-rejected / 0
self-rejected of 717** (session 40's close).

- **The hoisting window** (`LowerCtx.hoist_mode`/`hoist_stmts`/`hoist_cleanups`/
  `hoist_stmt_emitted`/`hoist_root_ep`, the `HoistSaved` carrier, and
  `begin_stmt_setup`/`collect_stmt_setup`/`emit_hoist_setup`/`append_hoist_cleanups`/
  `lower_expr_hoisting`/`suspend_stmt_setup`/`resume_stmt_setup`): while a statement
  lowers its root expression, a multi-step setup pushes into the window instead of
  the StmtExpr.  Three host-mirroring modes:
  - **`hm_return`** (`return f(x)`): the value must survive the cleanups, so the call
    materializes into a `__mt_foreign_result_N` temp, the frees follow it, and the
    return uses the temp — all hoisted before the ReturnStmt (the host's
    `lower_foreign_call_statement`).
  - **`hm_value`** (`let v = f(x)` / `t = f(x)`): the call is the statement's value
    and the frees are cleanups emitted after the statement (the host's
    `lower_foreign_call_components` shapes).
  - **`hm_discard`** (expression statements, `let _ =`): a root foreign call is
    emitted by the foreign lowering itself with `line 0`/`path ""` (dumping as
    `nil`/`nil`, the host's `discard_result` shape) and the arm skips its own
    ExpressionStmt — whatever the arguments needed (the host emits *every*
    statement-position foreign call this way, plain calls included; corrected
    with item 3d below, which probed bare and member callees, with and without
    cstr temps).
  Root-ness is pointer identity between the window's root AST expression and the
  foreign call's `call_ep`, so a nested call in a discard window keeps the arm's
  statement.
- **Statement arms** wired to the window: `stmt_ret` (plain path), `stmt_local`
  (the value computation through the `stmt_local` push), `stmt_assignment` (the main
  path and the `read(x) =` path), `stmt_expression`, and the `let _` branch.
- **Lazy-region isolation** (`suspend_stmt_setup`): if-expression branches,
  short-circuit `and`/`or` right operands, proc bodies (`lower_proc_expression_typed`),
  `detach` workers and format strings keep the inline StmtExpr — a region that may
  not run must not hoist its setup (the format-string hoist is its own item).
- **Temp naming**: `foreign_cstr` → `foreign_arg`, `foreign_ret` → `foreign_result`,
  matching the host's prefixes (`bind_foreign_mapping_arguments`,
  `lower_foreign_call_statement`); the shared per-function counter numbering was
  already right.
- **Measured** (all five items of the session): the sweep went **44 → 55 match /
  622 → 611 differ / 51 host-rejected / 0 self-rejected of 717** — the hoisting,
  items 3d/3e and item 3c left the set unchanged (max delta +4063 → +12014 →
  +118,892; 3c: 255 files deeper by +1287) and **item 3f flipped 11 files to
  byte-identical: `std/raylib.mt`, `std/raygui.mt` and 9 raylib examples**,
  with **242 files' first difference deeper (max +314,637), 0 shallower, 0 newly
  differing, 0 lost** overall (the raylib family 205, box2d 29, box3d 14,
  `std/raylib/runtime.mt`, `std/raylib/debug_console.mt`, `std/parse.mt` among
  them).  The raylib first difference moved from the `Image.text` StmtExpr
  through `Image.format`'s pointer cast, `Image.kernel_convolution`'s mapping
  temp, `Vector3.float_v`'s call type and `CAMERA_PERSPECTIVE`'s flags/struct
  type; after 3c the box2d/raylib/compiler families first-differ inside
  `std/mem/heap.mt`'s `contains` (3h/3i), the audio family on 3j.
- **Item 3d (landed in the same session) — the pointer-like foreign argument.**
  An `inout`/`out` foreign argument whose lowered value already is a C pointer —
  an editable method's `this` receiver — was addressed again
  (`(IR::AddressOf :expression (IR::Name "this" :pointer true) :type ptr[void])`,
  a wrong pointer level: `Image**` where the C call wants `Image*`), where the
  host casts it to the boundary's pointer type.  `addr_operand_expression` ports
  the host's `lower_addr_expression` (`calls.rb:356-365`): an `IR::Name` with
  `pointer: true` is the pointer itself and `*p` unwraps to `p`; both are cast to
  `ptr[<param type>]` instead of taking `IR::AddressOf`.  Wired into
  `lower_foreign_arg`'s and `lower_inline_foreign_mapping`'s `out`/`inout`
  branches (the host's `lower_foreign_pointer_argument_value` at both call
  sites); the `in`/plain paths keep their existing semantics (a following item if
  a corpus shape needs the same rule).  Locked by
  `test_pointer_receiver_foreign_argument_is_cast_not_addressed`; the session-41
  fixture and the member/bare/discard probes stay byte-identical (the discard
  probe also pinned the corrected `hm_discard` rule above).
- **Item 3e (landed in the same session) — the mapping-argument temp rule.**
  The census's new leading bucket (~252 files): the self temporary-binds *every*
  referenced parameter of an inline foreign mapping, where the host binds one
  only when `reference_count > 1 && !duplicable_foreign_argument_expression?` or
  `!inlineable_foreign_argument_expression?`
  (`foreign_argument_needs_temporary_binding?`, `calls.rb:1491`), substituting
  the value into the mapping otherwise, with the
  `inlineable_single_direct_call_names` exception (`calls.rb:702`: exactly one
  blocked entry with `reference_count == 1` and a plain `IR::Call` value is
  embedded directly).  `mapping_replacements` (a `Map[str, ptr[ir.Expr]]` on
  `LowerCtx`) holds the substituted values; `lower_expr`'s identifier arm
  resolves them ahead of the locals and `member_receiver_is_local` counts a
  replacement as bound, so a method call on a substituted parameter stays a
  normal member call (not an `alias.CFunc(...)` external call); the map is
  created per mapping walk and restored afterwards, so nested mapping calls
  compose.  `duplicable_foreign_value`/`inlineable_foreign_value` port
  `calls.rb:1469-1495` and `foreign_cstr.rb:142-174` over the self's IR, and
  `mapping_reference_count` ports `foreign_mapping_reference_counts`'
  single-name form; `lower_inline_foreign_mapping` collects
  `MappingParamBinding` records in the parameter loop and decides temp vs
  substitution after it (public-alias temps stay ahead of the parameter temps,
  the host's phase order).  Locked by
  `test_mapping_arguments_are_substituted_not_tempped`; the kernel fixture
  (`= c.ImageKernelConvolution(image, kernel.data, int<-kernel.len)`) lowers
  byte-identically to the host's call body — `(IR::Cast(this),
  (IR::Member (IR::Name "kernel") "data"), (IR::Cast int (IR::Member … "len")))`
  with no temps.
- **Item 3f (landed in the same session) — the mapping call's return type.**
  `walk_mapping_expr` typed an embedded external call with `top_ret_ty` (the
  *mapping's* return type) where the host types it with the callee's declared
  return type, resolved through its `owner_analysis`
  (`= c.Vector3ToFloatV(x).v`: host `(IR::Call :callee "Vector3ToFloatV" …
  :type (Types::Struct :name "Float3Array" :module_name "std.c.raymath"))` with
  an `array[float, 3]` member; the self had `array[float, 3]` on both).
  `ForeignInfo` gained `owner_module` (the declaring module, set at all three
  construction sites); `mapping_call_return_type` resolves the mapping's
  receiver alias against the *owner's* imports and then the member against the
  target module's `foreign function`/`external function` declarations (via
  `imported_foreign_call`/`imported_extern_call`); `walk_mapping_expr`/
  `walk_mapping_construction` thread the owner module and use that return type
  for the call node (the member keeps the mapping's type).  **Measured**: the
  sweep went **44 → 55 match / 622 → 611 differ / 51 host-rejected / 0
  self-rejected** — **`std/raylib.mt` and `std/raygui.mt` are byte-identical**,
  plus 9 raylib examples (`basic_window`, `render_texture`, `window_web`,
  `basic_shapes`, `following_eyes`, `logo_raylib`, `mouse_trail`,
  `rectangle_advanced`, `format_text`) — with **242 files' first difference
  deeper (max +314,637)**, 0 shallower, 0 newly differing, 0 lost.  The raylib
  files now first-differ at ~92% of their dump (`3d_camera_fps.mt` at byte
  276,470 of 301,044) on `CAMERA_PERSPECTIVE`'s type: the host renders
  `Types::Flags` where the self has `Types::Struct` (the next item, 3g).  Locked
  by `test_mapping_external_call_takes_the_declared_return_type` (the raw
  `Holder` call type + the mapping's `array[int, 2]` member; the fixture dump is
  byte-identical to the host's).
- **Item 3c (landed in the same session) — the guard-bound nullable pointer
  arithmetic.**  The census's last leader (~355 files): session 40 wrote the
  split behaviour down against the wrong site — the *binding read*
  (`guard_success_projection`) is `Nullable(ptr[T])` on both compilers (the
  host's `IR::Name` really is the storage type); the divergence is the
  **binary's type**.  `blocks + i`'s recorded analyzer type *is* refined
  (`infer_binary`'s `is_raw_pointer(lt)` returns `ptr[Block]` — probed with
  temporary instrumentation on both `infer_expr` and the lowering), but the
  lowering's pointer-arithmetic branch overwrote `result_ty` with the *lowered*
  left operand's type, and `Nullable(ptr[T])` passes `is_raw_pointer` (it
  unwraps nullables).  The fix unwraps the nullable for the result type
  (`result_ty = if types.is_nullable_type(left_ty):
  types.unwrap_nullable(left_ty) else: left_ty`), so the binary keeps the
  refined pointer while the read keeps its storage type.  Measured: the sweep
  set is unchanged (55/611/51/0) with **255 files' first difference deeper by
  +1287** (the shared heap node), 0 shallower/new; locked by
  `test_guard_bound_nullable_pointer_arithmetic_is_unwrapped`.  Noted, not
  changed: the self's analyzer accepts unguarded nullable pointer arithmetic
  where the host rejects it (no corpus file can contain it).  Newly exposed at
  the same heap node: **3h** (`i += 1`'s literal typed `int` where the host
  types it `ptr_uint`) and **3i** (a guard-branch `continue` emitting
  `GotoStmt __mt_loop_continue_1` where the host emits `IR::ContinueStmt`),
  plus **3j** for the raylib audio family (`= c.getenv(name)`'s call typed
  `Nullable(cstr)` instead of the raw `ptr[char]`).
- **Item 3h (landed last in the session) — the assignment literal's contextual
  type.**  `i = 1` / `i += 1` / `i -= 3` on a `ptr_uint` target emitted `int`
  literals where the host types them `ptr_uint` (its `lower_contextual_expression`
  with the target as the expected type).  The assignment arm now applies the
  local declaration arm's literal set (`int_literal_to_context_type`,
  `float_…`, `string_…`, `null_…`) against `expr_type(target)`.  Measured: the
  sweep set unchanged (55/611/51/0) with **255 files' first difference deeper by
  +18**; locked by `test_assignment_literals_take_the_target_type`.  The same
  heap node's next difference is 3i (the port of the host's loop-flow kind
  model, `loop_exit_continue`/`loop_exit_break`, for native break/continue).
- **Item 3i's continue half (landed last) — a native `continue` in a plain
  `while`.**  `LowerCtx.loop_continue_native` is set around the body of a plain
  C `while` (whose continue point is the loop's condition), so `continue`
  lowers to `IR::ContinueStmt` instead of `goto __mt_loop_continue_N` + an
  appended label; for-loops clear the flag (their desugared post sits after the
  continue point), the async `while true` rewrite keeps its own labels, and
  `continue` needs no switch-interposition tracking (C's `continue` reaches the
  loop through a `switch`).  Measured: the sweep set unchanged (55/611/51/0)
  with **255 files' first difference deeper by +222**; locked by
  `test_continue_in_a_plain_while_is_native`.  `break` keeps the goto (its
  native form needs the host's `switch_loop_target` invalidation — still open),
  and the same heap node's next difference is 3k (the guard-bound `reinterpret`
  source type).
- **Locked by** `test_foreign_call_setup_hoists_at_statement_position` (the four
  hoisted shapes), `test_pointer_receiver_foreign_argument_is_cast_not_addressed`
  (the cast, no `AddressOf` of `this`, the nil line/path plain statement),
  `test_mapping_arguments_are_substituted_not_tempped`,
  `test_mapping_external_call_takes_the_declared_return_type`,
  `test_guard_bound_nullable_pointer_arithmetic_is_unwrapped` and
  `test_assignment_literals_take_the_target_type`; the session-41
  fixture's dump is byte-identical to the host's (checked manually — the four
  function bodies match exactly).
- Newly exposed, ranked: (a) **3i** (~255 files — the heap guard region's
  `continue` lowering; 3h, the literal typing at the same node, landed); (b)
  **3j** (~100 — the
  simple-path call's raw return type); (c) the flags/enum member type (3g, ~24);
  (d) a nested statement-lowered call in a *value* position: the host
  materializes `__mt_foreign_expr_N`, the self inlines it; (e) `let _ = expr` is
  a host `LocalDecl` named `_` with linkage `__mt___N` (the self discards it as
  an ExpressionStmt — pre-existing, general, visible in the fixture's `drop`
  function); (f) format strings still take the StmtExpr shape (the sdl3 family's
  first difference).
- **Gates** (frozen tree, `tools/gates.sh --run`): dev build + 19/0; bootstrap
  fixed point (`stage2.c == stage3.c`) + 19/0; `test/mt` 60/0; the lower sweep
  44/622/51/0 with the set comparison; examples 49/49.

### Session 40 (2026-10-06) — `lower` Track 3 items 2 and 2b: globals from imported constants, named function references

Goal: the ranked `lower` item 2 — the first difference for the box2d/box3d
example families: `var s_world_id: b3.WorldId = b3.b3_nullWorldId`, a global
initialized from an imported (generated) constant that re-exports a raw
module's struct constant.  Baseline at this commit: **43 match / 623 differ /
51 host-rejected / 0 self-rejected of 717** (session 39's close).

- **The `decl_var` arm** (`lowering.mt:1262-1288`) now mirrors the host's
  `lower_static_storage_initializer`: it first folds the initializer with
  `try_const_typed_value_ir` (the typed literal/array/null forms plus the
  `try_const_value_ir` fallback — const references, imported consts, const
  function/method calls and their aggregates) and takes the folded IR through
  `coerce_const_value`; only when the fold fails does the initializer lower
  with `lower_expr` and the contextual literal conversions, as before.  Before
  the fix the global held `(IR::Name :name "std_box3d_b3_nullWorldId" :type
  (Types::Error) :pointer false)` where the host inlines the aggregate
  (`IR::AggregateLiteral :type (Types::Struct :name "b3WorldId" :module_name
  "std.c.box3d")` with `index1`/`generation` fields).
- **Measured**: the sweep counts and set are unchanged — **43/623/51/0** — with
  **23 files' first difference moved deeper** (0 shallower, 0 newly differing):
  the box3d family (9 files incl. `common.mt`), the box2d family (10),
  `examples/raylib/core/3d_camera_fps.mt`,
  `examples/sdl3/pen/drawing_lines.mt`,
  `examples/raylib/shapes/penrose_tile.mt` and `test/mt/signal_test.mt`
  (+361 B to +11,937 B deeper).
- **Item 2b (landed in the same session) — bare function-reference types.**
  The next first difference the fold exposed was
  `s_scene_draw: fn() -> void = noop_scene_draw`: the reference's value was
  `(IR::Name :name "examples_box3d_common_noop_scene_draw" :type
  (Types::Function :name "" …))` where the host's type carries the callee's
  name.  `fallback_type_raw` (`lowering.mt:16473-16492`) now builds the type
  from the `FnSig` with `name = id.name` and `variadic = sig.is_variadic`,
  mirroring the host's `infer_expression_type` → `function_type_for_name` →
  `binding.type` (`lowering/resolve.rb:750`); locked by
  `test_function_reference_carries_declared_name` (fails with the change
  reverted).  Sweep: set unchanged, **29 files' first difference deeper, 0
  shallower, 0 newly differing** (the box3d family, 20 `examples/sdl3/**`
  files; the box2d family's first difference is another category).
- **Item 2c (landed in the same session) — tuple value structs.**  The next
  first difference was the missing `mt_tuple_*` decl for
  `quat_axis_angle`'s `(b3.Vec3, float)` return tuple.  Landed: the qualified
  `Tuple#to_s` renderer (`naming.type_to_s_qualified`) and the shared C name
  (`naming.tuple_type_c_name` — the host's `tuple_type_name`, with
  `sanitize_type_name_for_tuple`'s collapse/strip and the non-default
  field-name suffix); `ensure_tuple_struct_ir` (`lowering.mt:6440`) with the
  literal and storage-type registration sites (`lower_tuple_literal_with_names`,
  `ensure_storage_type_tuples` at `decl_var`/`decl_const`); the
  `pending_tuple_structs` drain after the module fragments in `lower()`; and
  the backend's `filter_declared_tuple_types` so IR-declared tuples are
  emitted once, from the IR (the local `tuple_type_name` deleted).  Measured:
  set unchanged (43/623/51/0), **6 files deeper** (`box3d/common`,
  `box2d/common`, `box2d/human`, `raw_scanner`, `std/color`, `color_test`;
  +12,335 to +27,907), 0 shallower/new; the emitted C for a tuple example is
  byte-identical to the host's (`typedef` + single `struct` def).  Both new
  tests (`test_tuple_literal_registers_value_struct`,
  `test_storage_tuple_registers_value_struct`) fail with the change reverted.
  The newly exposed next differences are ranked as items 2d (the host's single
  creation-ordered `synthetic_structs` vs the self's per-fragment placement —
  the box families' tuple-before-`vtable_Sample` order) and 2e (the tuple
  type's default `field_names` rendering and the folded-tuple
  `IR::ArrayLiteral` shape); the str_buffer discovery (the host has no
  `mt_str_buffer_*` decl in its IR at all) is recorded in 2d.
- **Item 2d (landed in the same session) — synthetic-struct ordering.**  The
  host keeps one creation-ordered `@artifacts.synthetic_structs` list (proc
  envs, async frames, pfor/spawn caps, dyn vtables, five event structs, tuples)
  appended after all module structs.  The self now mirrors it: a
  `pending_synthetic_structs` list on `LowerCtx`, pushed *at creation time* by
  every producer — tuples (`ensure_tuple_struct_ir`), proc envs and capture
  caps, async frames (`lower_async_fn`, whose `structs` parameter and
  `lower_extending_block`'s are gone), dyn vtables (dual-pushed; the kind list
  still backs the two vtable lookups), the five event runtime structs and the
  str-buffer structs — drained program-level after the module fragments
  (`lower()`), with `pending_env_structs`/`pending_event_structs` and the
  per-kind fragment pushes retired.  Measured: set unchanged, **42 files'
  first difference deeper, 0 shallower, 0 newly differing** — the box2d/box3d
  families (+13,164), the `std/net/**` async family (up to +14,294:
  `mux`, `rpc`, `sync`, `session`, `manager`, `lobby`, `channel`), 
  `async_stress_test` (+16,069), `async_network_lobby` (+16,622), tetris,
  `projects/stress`, the DAP protocol modules and `imported_bindings/main`.
  Locked by `test_synthetic_structs_follow_creation_order` (fails at the 2c
  state).  Residual: the `mt_str_buffer_*` decls have no host counterpart (the
  host's IR carries none) — they ride the same list now; removing them from
  the IR needs backend-side synthesis.
- **Item 2e(a) (landed in the same session) — the anonymous tuple's default
  field names.**  The host's `Types::Tuple#field_names` always carries the
  defaults; the self's model omits them, so the dumper now fills `("_0"
  "_1" …)` when `field_names` is `None`, and `try_const_tuple_ir` names a
  folded tuple's aggregate fields `_0..` (they were `0`/`1`).  Measured: the
  sweep went **43 → 44 match / 623 → 622 differ** with **`std/color.mt`
  byte-identical** (its first difference was exactly this rendering) and
  `test/mt/color_test.mt` +46,643; 0 newly differing, 0 shallower.  Locked by
  `test_anonymous_tuple_renders_default_field_names` (fails with the change
  reverted).  The tuple fixtures `p.mt`, `store.mt` and `ord.mt` are now
  byte-identical end-to-end; `use.mt` keeps 2e(b) (the host lowers a folded
  tuple const through `lower_const_value_literal` into an `IR::ArrayLiteral`).
- **Item 2e(b) (landed in the same session) — the tuple constant's
  `IR::ArrayLiteral` shape.**  A tuple-typed constant with an expression-list
  (or call/specialization) value now takes the host's
  `lower_const_value_literal` path: `const_tuple_array_literal` converts the
  folded aggregate into an `IR::ArrayLiteral` whose element literals are
  re-typed to `int` (the host's fallback element type; integers masked to 32
  bits, bools/floats/strings keep their values), applied under the new
  `const_value_literal_path` guard in `decl_const`; a non-scalar element
  falls back to the aggregate.  Measured: corpus-neutral — the sweep
  set/counts are unchanged (no corpus file carries the shape) — and the
  `use.mt`/`mixuse.mt` fixtures are byte-identical (probed: `(int, bool)` and
  `(bool, int)` element typing matches the host's `int` fallback).  Locked by
  `test_tuple_constant_lowers_to_array_literal` (fails with the change
  reverted).
- **Item 3 (verified in the same session) — CLOSED.**  F2's continuation
  refinement (session 15) had already fixed the refined-operand dump
  difference: `examples/data_structures.mt` and
  `examples/reflection_advanced.mt` no longer first-differ there — both now
  first-differ on **3b**, the `reinterpret` lowering (host
  `IR::ReinterpretExpr` always, rendered through a `memcpy` helper with a
  `_Static_assert`; self `IR::Cast` except for floats, rendered as a union
  compound literal), with the source type needing the host's unwrapped
  pointer resolution.  Recorded in Track 3 with the corpus sites and the
  nullable-source pitfall.
- **Item 3b (landed in the same session) — the `reinterpret` lowering.**  The
  builtin always emits `IR::ReinterpretExpr` now, with the source type from
  `analyzer.flow_type_at` for an identifier argument (the function moved out
  of `lsp/navigation.mt` so the lowering shares it).  Two supporting fixes
  were needed to make the heap sites refine: **the nullability pre-pass for
  method bodies** (`check_method_body` now mirrors `check_function_body`'s
  CFG build + solve + barrier — `std/mem/heap.mt`'s `contains` is a method)
  and **a body-scoped `flow_type_at`** (the greatest start-barrier position
  at or before the cursor, then entries up to the next barrier) because the
  two-pass check order (functions, then methods — host-locked by
  `test_binding_ids_follow_the_hosts_allocation_order`, which caught an
  attempted positional-pass merge and forced the body-scoped scan) made the
  old flat scan let a later body's barrier wipe an earlier body's records.
  Measured: sweep set unchanged (44/622/51/0), **169 files' first difference
  deeper, +1527 each** (the shared heap module), 0 shallower/new; the
  `re.mt`/`re4.mt`/`reintfix` fixtures are byte-identical, locked by
  `test_reinterpret_always_reinterprets_with_refined_source`.  Gates
  (clean tree, nothing else touching `projects/mtc/test`): bootstrap fixed
  point + 19/0, `test/mt` 60/0, cli_parity 24/37/0, lint_parity 495/121
  (unchanged from HEAD — the shift from the ledger's 496/120 is the
  session-40 corpus edits, verified by re-running at HEAD), recovery OK,
  examples 49/49; the LSP harness reads its 4 documented entries and the
  audit its documented 5 after the change.  **Gate-rule lesson**: the
  bootstrap's self-test suite and a concurrent `mtc test` run both synthesize
  `__mt_test_runner_*.mt` in `projects/mtc/test/` and discover each other's
  runners (`duplicate value main`) — never run the suite while a gate runs.
- **Item 6 (landed in the same session) — the include set/order.**  The
  include *set* already matched; the **order** did not.  The host appends the
  raw modules' directives in its analysis-cache insertion order, which is a
  **DFS post-order from the root** (its `check_path` resolves each module's
  imports on demand in declaration order and inserts the analysis after its
  imports) — not the canonical module order the self used, and not a
  `topo_sort_levels` shape either (an attempted level-based version was
  rejected when `raylib_opengl_interop`'s include order regressed 166 files
  *shallower*).  `collect_includes` now mirrors the post-order via
  `emit_raw_module_includes`, walking the analyses' `source_file.imports`.
  Measured: set unchanged (44/622/51/0), **91 files' first difference
  deeper** (min +8456, max +136,782 — the raylib/box2d/box3d/sdl3 examples
  and the compiler's own sources), 0 shallower/new; locked by
  `test_includes_follow_the_hosts_dfs_post_order` (a fixture whose post-order
  contradicts the module sort).  Gates: bootstrap fixed point + 19/0, dev
  self-test 19/0, `test/mt` 60/0, examples 49/49.
- **Item 4 (landed in the same session) — event fields.**  A struct-declared
  event is now emitted as `IR::Field(name = "__event_<name>", ty =
  Types::Event …)` (runtime info: capacity/payload/linkage) and every
  event-typed member access is routed through the hidden name and the event
  type (`lower_member_access`'s `is_event_type`/`event_name_from_type`
  branch), mirroring the host's `lower_struct_decl`/`member_c_name`; the C
  backend's `by_value_dep_key` gained the `ty_event` arm so the embedding
  struct is topo-ordered after the runtime definition (the `ev.mt` fixture
  otherwise failed with GCC's "field has incomplete type").  Measured: sweep
  set unchanged, `examples/event_stress_test.mt` **+737** (21212 → 21949,
  where the next difference is the nested-struct C name `Container_Inner` vs
  `Inner` — the track-9 residue family), 0 newly differing, 0 shallower.
  Locked by `test_event_fields_use_hidden_name_and_event_type` (fails with
  the change reverted).  Smoke: the `ev.mt` fixture builds and runs on both
  compilers; `projects/stress` builds and exits 242; dev self-test 19/0.
  Newly exposed: **4b** — the host's event linkage embeds the owner struct
  and payload (`mt_event_<module>_<owner>_<name>_<payload>_<capacity>`,
  `types.rb:748-756`), while the self keys its runtimes by bare name and omits
  both segments, so two same-named events in different structs share one
  runtime today (the `ev.mt` fixture first-differs at byte 655 on
  `mt_event_ev_Window_closed_4__slot` vs `mt_event_ev_closed_4__slot`).
  Residual: cross-module event member accesses are not hidden-name-routed
  (`is_event_type` consults only the local `events` map; no corpus case).
- **Verification**: `test_global_initialized_from_imported_const` locks the
  fold — a main-module global ← generated module const ← raw-module struct
  const chain, asserting the aggregate entry in the dump; all ten new tests
  fail with their change reverted (checked).  Tier-2 gates on the frozen tree
  (the trimmed `tools/gates.sh --only` sets for 3b and item 6; the full
  codegen+tests set for items 2–4): dev build + dev self-test (19 files / 0
  failed), bootstrap fixed point (`stage2.c == stage3.c`, 19 files / 0
  failed), `test/mt` 60/0, the `lower` sweep **44/622/51/0** with the set
  comparisons above, examples 49/49 same; the LSP harness (4 documented) and
  the project audit (the documented 5) were re-run after the `flow_type_at`
  change; the `box_stack.mt` (dyn vtable + tuple) and `event_stress_test.mt`
  builds, the `p.mt`/`store.mt`/`ord.mt`/`use.mt`/`mixuse.mt`/`ev.mt`/
  `re*.mt`/include fixtures and the emitted C for a tuple are the smoke
  checks.

### Session 39 (2026-10-05) — `lower` Track 3 item 1: opaque declarations

Goal: the ranked `lower` item 1 — the first dump difference for all 34 sdl3 files.
Baseline at this commit: **39 match / 627 differ / 51 host-rejected / 0 self-rejected of
717** (session 33's 39/622/51/0 of 712 plus the tree's own new sources).

- **`collect_opaque_decls`** (lowering) now mirrors the host's `lower_opaques`: every
  non-raw module's `opaque` declarations are collected with the **declared** name (the self
  used the module-qualified alias), the C backing resolved the host's way
  (`opaque_c_type_name`: the explicit `= c"..."` name when present, else the
  module-qualified name), and `forward_declarable` = the backing is a plain C identifier
  (host `opaque_forward_declarable?` — every non-raw module is non-external, so that half
  of the rule is moot).  Raw (`external`) modules are skipped by module kind, not by the
  `std.c.` prefix.  `naming.is_c_identifier` ports the host's regex.
- **`emit_opaque_typedefs` → `emit_opaque_forward_decls`**: the host's
  `emit_forward_declarations` opaque half — `typedef struct <linkage> <linkage>;` per
  forward-declarable opaque, deduped by linkage.  `c_type`'s opaque arm renders the
  resolved backing name (`SDL_Window*`) through a new `opaque_backing_names` map
  (`collect_opaque_backings`, the `std_c_backing_names` pattern); the qualified-name
  fallback stays for synthesized opaques.  The backend's opaque-name set also records the
  qualified key, so `collect_opt_type`'s nullable-opaque check is unchanged.
- **Measured**: `sexpr lower` **39 → 43 match / 627 → 623 differ / 51 host-rejected / 0
  self-rejected of 717**.  The newly matching files are exactly the opaque-bearing modules
  `std/glfw.mt`, `std/gl.mt`, `std/box3d.mt`, `std/sdl3.mt` (their dumps are now
  byte-identical), and the pre/post per-file sets show **no newly differing file**.  The
  sdl3 family's first difference moved past the opaques to the format-string lowering shape
  (the host hoists `__mt_fmt_part_N` locals into the branch body; the self wraps them in a
  `StmtExpr`) and, in some files, to the null-literal type (`Types::Nullable :base …` on the
  host vs `Types::Primitive :name "void"` on the self, e.g. for `std/mem/heap.mt`'s new
  `active_region: ptr[Region]? = null` global) — both newly exposed and ranked next.
- **Verification**: tests updated/added (`test_opaque_value_renders_as_pointer` now expects
  the host's `typedef struct HANDLE HANDLE;` + `HANDLE* h = NULL;`;
  `test_opaque_decls_keep_declared_name_and_backing` locks name/linkage/forward-declarable
  for a re-export, a non-identifier backing and a bare opaque); full example builds pass
  with the dev compiler (`examples/sdl3/renderer/clear.mt`, `examples/box3d/box_stack.mt`,
  `examples/raylib/others/raylib_opengl_interop.mt`, each matching the host), and the
  emitted C's opaque lines match the host's (modulo the pre-existing helper ordering).

**Item 1b (newly exposed, landed in the same session) — null-literal context typing.**  The
opaque fix exposed the next first difference for most sdl3/box3d files: a bare `null`
initializer was typed `void` where the host types it from the context
(`infer_null_literal_type`: `expected_type || null_type`).  The existing
`null_literal_to_context_type` helper (already used for returns and comparisons) is now
applied at the other contextual sites the sibling literal coercions cover — globals,
locals, struct-construction fields, generic-struct fields, array elements and
const-folded fields — and the locals/field nullable wraps no longer need their
`NullLiteral → ZeroInit` special case (the backend already renders a nullable-typed
`NullLiteral` as `(mt_opt_X){0}`), so a value-nullable local keeps the host's typed
`NullLiteral`.  `sexpr lower` stays at **43/623/51/0** — no file flips — but **296 files'
first difference moved deeper** (327 unchanged, 0 shallower, 0 newly differing): a pure
forward move.  Locked by `test_null_literal_takes_context_type` (global, pointer local
and value-nullable local all `Types::Nullable`-typed).  Next categories to rank: the
format-string setup shape, the include set/order, global-init-from-imported-const
(item 2) and the nullable/reinterpret cluster.

### Session 38 (2026-10-05) — C4 part 1: the parser/lexer scratch release

Goal: start Track 7's C4 (per-parse ownership — the ~3.9 MB/cycle LSP residual) with its
zero-ownership-risk half: the parser's token and scratch allocations, which the session-37
valgrind attribution ranked first ("the lexer's `Vec[Token]` buffers").  The per-entry
region work is designed (a growable `heap.Region` behind a scoped allocator switch,
per-entry parse/analysis regions, superseded regions quarantined to the request boundary)
and follows as parts 2–4.

- **`parser.mt`**: the three entry points (`parse`, `parse_reporting`,
  `parse_source_reporting`) now hold the lexer's token vector and release it right after
  `ts.create` copies it, and release the finished `ParserState`'s scratch — the stream
  copy, the three known-name maps, the type-parameter list and `pending_decls` — through
  `release_parser_scratch`.  The embedded-interpolation sub-parse releases its raw and
  filtered token vectors, its stream copy and its own `pending_decls`; it never touches
  the maps or the type-parameter list it shares with the parent, and it deliberately keeps
  `padded` (the parsed expression's string views point into it).  The AST holds no
  references into any released buffer: token lexemes are views into the source text and
  every AST list owns its backing buffer.
- **`lexer.mt`**: `lex`, `lex_reporting` and `lex_with_trivia` release the indent stack
  (previously leaked once per lex).
- **Measured**: the soak slope fell **3.96 → 3.17 MB/cycle** on the dev build (the gate's
  stage2 at `--cycles 200` read **3.19**, was 3.98; peak RSS 417 → 336 MB at 100 cycles).
- **Verification** (`tools/gates.sh` on the frozen tree): bootstrap fixed point (18 files /
  0 failed), `test/mt` 60/0, sexpr lex 716/716 and parse 712 comparable / 0 differ,
  examples 49/49, recovery OK, harness 30/30 at 4 documented entries, fixture sweep closed
  5 / added 0, valgrind 0 errors, Neovim smoke OK, soak 3.19.  Targeted valgrind on an
  example build: 0 errors.
- **Part 2 (`std/mem/heap.mt`): the `Region` allocator and the scoped routing.**  A region
  is a growable bump allocator: a geometric block list, a per-allocation 16-byte size
  header, `contains` via `reinterpret[ptr_uint]` block ranges, resize = new payload +
  copy, `release()` frees every block.  While a region is active
  (`begin_region`/`end_region`, nesting save/restore), `alloc_bytes`,
  `alloc_bytes_aligned`, `alloc_zeroed_bytes` and `resize_bytes` serve from it, and
  `release_bytes` on region memory is a no-op; with no active region every path is libc
  exactly as before (one global load, no scans).  Region bookkeeping allocates through
  libc directly, so a region's blocks can never be captured by another region.
  Locked by `projects/mtc/test/heap_region_test.mt` (7 cases: multi-block growth,
  zeroing, resize preservation, the release no-op, libc-vs-region containment, nesting,
  container buffers).  Inert by construction and by measurement: soak 3190.5 KB/cycle
  (part 1: 3190.3), `test/mt` 60/0, examples 49/49, harness 4 documented, valgrind 0
  errors, bootstrap fixed point at 19 test files / 0 failed.
- **Part 3 (`module_loader.mt`, `workspace.mt`, `server.mt`): the per-entry regions.**
  With a cache in use, `parse_all` runs the parse inside a fresh parse region and
  `check_and_bind_module` runs `analyzer.check_module*` + `binder.bind_module` inside a
  fresh analysis region; the entry owns both.  Entry teardown releases the module's
  name/path/source Strings and `import_paths`/`dep_versions` (ordinary heap) plus the
  regions (which own the AST, the diagnostics buffers and the analysis internals); the two
  `release_module_cache_entry`/`release_entry_analysis` sites branch explicitly instead of
  releasing region internals.  **Superseded regions are quarantined, not freed**
  (`ModuleCache.retired_regions`) and drained at the request boundary from the server loop
  (`Workspace.drain_retired_regions`), because request-local values can still borrow a
  region they replaced mid-request (the token scanner's module surfaces) — freeing at
  replacement would be a use-after-free.  The audit caught a name-resolution collision the
  new methods introduced: `Region.release`/`alloc_bytes_aligned`/`resize_bytes` shadowed the
  module-level `heap.release`/`heap.alloc_bytes_aligned`/`heap.resize_bytes` for the host's
  facts, so `heap.release(raw)` resolved differently on the two servers; the methods are
  now `release_all`/`alloc_aligned_bytes`/`resize_payload`.  Locked by a
  `module_loader_test.mt` case (retire > 0, drain 0).
- **Part 4 (parse cache + the residue the measurements exposed).**  `ParseCacheEntry` owns
  a region around `parser.parse_source` + `analyzer.check_source_file` (the diagnostics
  buffer included); stale regions retire to `Workspace.retired_regions`; `Workspace.release`
  now releases the parse/analysis caches.  The valgrind-soak stacks then attributed the
  remaining per-request leaks: the linter leaked the per-body `Cfg` (fixed with
  `flow_builder.cfg_release` via defer in `lint_body_rules`), `didChange` never released
  its `document_source` copy, and the diagnostic cache/publish/the `diagnostic` pull
  dropped Strings (all released now).  Also released: `Program.release`'s
  `analyses`/`owning_type_names` vectors, the per-run `bindings` map,
  `canonical_analysis_order`'s containers and `visit_analysis_name`'s `deps`.  Tried and
  reverted: a region around the workspace-index walk — the index mutates its own persistent
  vecs during collection, and containers that outlive a scope must not allocate into it
  (the soak caught the invalid `realloc` immediately); that invariant is now recorded at
  the site.
- **Soak tool**: a `steady` mode (requests only, no `didChange`) that must read ~0, the
  final RSS appended as a sample, and a `slope_ls` least-squares slope that excludes the
  warm-up sample.
- **Measured (final)**: full soak **3.96 MB/cycle → 68.1 KB/cycle raw / 19.9 KB/cycle LS**
  at `--cycles 200` (level 656 → 33 MB; `steady` 12.6 raw / 0.0 LS; `diag` 12.0 LS).
  Valgrind over the harness drive: 0 errors; the definitely-lost residue is ~64 KB per
  10-cycle soak, dominated by the one-time index walk's arena-leaked ASTs.
- **Verification (final, frozen tree)**: bootstrap fixed point (19 files / 0 failed),
  `test/mt` 60/0, sexpr lex 717/717 + parse 713 comparable / 0 differ, examples 49/49,
  recovery OK, canonical audit **4** differing entries (the documented set), harness **4**
  documented on a fresh host+self pair (the gate's pairing read 5 because the *host*
  nondeterministically adds a phantom `renamed.mt` hit to `c5/references-no-declaration`
  after `willRenameFiles` — host-vs-host records agree and a fresh host+self pair reads 4,
  so the self matches the host's stable answer), fixture sweep closed 5 / added 0, valgrind
  0 errors, Neovim OK, lint corpus 496/120 unchanged, soak 68.1/19.9.

### Session 37 (2026-10-05) — the soak: per-request parses routed through the shared caches

Goal: the last open LSP item — Track 7's C4 readiness residue ("the remaining
per-request `parser.parse_source` sites (~38)").  The parse sites are now
routed through the workspace's shared caches; the residual growth is the
per-edit parse ownership, documented below.

- **`workspace.document_analysis_for(ws, path)`** (new): the AST and analysis
  for a document's current text from *one* tree — the loader-backed entry when
  the file loads (imports bound, shared with the diagnostics publish and every
  other request, cached per content version), else the single-file parse cache
  (`parsed_analysis_for`).  `DocumentAnalysis` also carries
  `parsed_declaration_count` (the raw parse's declaration count, for the
  outline's emit-tail cutoff) and `document_parse_error_count` /
  `document_raw_ast` expose the loader's recorded parse errors and raw tree.
  Two subtleties fixed on the way: the Program's `modules` are dependency-first
  while `analyses`/`root_index` are canonical, so the root module is found **by
  module name** (a `modules[root_index]` lookup read the wrong module and an
  outline walked past its tree — valgrind caught it); and
  `document_analysis_for` reads the source itself only on the fallback path.
- **Routed sites**: `semantic_tokens`' two consumers (the full/range/delta
  scanner and `semantic_class_entries`), navigation's 18 sites (hover,
  definition/typeDefinition/implementation, the local/owner/module/decl
  resolvers — with the parse-error bails kept through
  `parse_error_count_for`), `references` (module-level and static-method
  helpers and the per-candidate verifier), `completion` (the main handler and
  the two module-member passes), `call_hierarchy`/`type_hierarchy` (request
  docs and the index loops), `symbols`, `signature_help`, `highlight`,
  `rename`, `linked_editing_range`, `inlay_hints`, and the workspace index's
  per-edit re-index (`workspace_index.collect_file_symbols_from_ast`, fed the
  loader's raw tree from `document_raw_ast`).  The two remaining
  `parse_source` calls in those paths are deliberate fallbacks (the
  no-loader-entry case) plus the CLI's `snapshot_semantic_entries`.
- **One allocation fix**: `semantic_tokens.build_tokens_json` emitted each data
  value through `append_format(f"#{v}")` — a temporary per value (42k blocks
  per edited request on the soak workspace).  It now uses `fmt.append_uint`.
- **Measured** (`tools/lsp_soak.rb`, same synthetic ~5k-line workspace):
  full-cycle slope **11.4 → 3.96 MB/cycle** at `--cycles 100`, and the gate's
  `--cycles 200` run read **3.98** (was 11.5); tokens 8.8 → 3.87, refs 5.8 →
  3.88, diag 3.95 (unchanged).  Every mode now converges to ~3.9 MB/cycle: the
  per-edit loader parse+analysis leak (the parser/analyzer allocate with
  `heap.must_alloc` "one file per run and exits"; a superseded entry's heap
  copies are released but its AST/analysis internals are not owned).  A real
  ceiling needs the per-parse arena/ownership work item — the valgrind
  attribution shows the lexer `Vec[Token]` buffers and the parser/analyzer
  vectors dominating, with the index walk and the prelude seeds as one-time
  costs.
- **Verification**: harness 30/30 at **4 documented entries** (1 differing
  entry in the non-stress corpus: the documented directory-form
  `typeDefinition`); canonical audit **6 → 6, closed 0, added 0** (the routing
  is behavior-neutral); recovery OK; fixture sweep closed 5 / 0 added; audit 4
  (meter); valgrind 0 errors; Neovim smoke OK; bootstrap fixed point + 18/0
  tests.  (`tools/gates.sh --run` on the frozen tree.)

### Session 36 (2026-10-05) — warm references parity: the reverse-import candidate set

Goal: the canonical audit's last four *unintended* entries — the `references`
positions whose warm candidate set was narrower than the host's
(`docs/data_structures.mt@34:25`, `@112:29`, `@167:37`, `@195:37`; at `@34:25`
the host returns 25 occurrences against the self's 4).

Root cause: the target is a static method reached through a type receiver
(`vec.Vec[int].create()`), so `handle_references` takes the
`static_type_method_references` path, whose candidates are the import
dependents of the declaring module.  The self computed them from the
*workspace index* only (`ws_idx.dependents_of` over `Index.files`, filled by
the workspace-root walk), so a module file the loader had fetched for another
file's facts — the repo `std/` files `graph.mt`, `spatial.mt`, `sparse_set.mt`,
`binary_heap.mt`, all importers of `std.vec` — was never a candidate.  The
host's `reverse_import_dependents_for` is built over *all* documents it knows:
its `ensure_full_reverse_import_index` iterates
`@indexed_documents + @open_documents` and reads each one's imports (the host's
content cache memoizes every file a request touched, including modules fetched
through analysis, so tokenizing a navigation target is enough).

Fix:

- **`reference_index.mt`**: `IndexedDocument` now records its import module
  names (views into the stored source); `collect_document_metadata` lexes once
  and fills both the identifier tokens and the dotted name after each `import`
  (before `as`); `documents_importing(index, module_name, results)` answers a
  module's importers in index (tokenization) order — the host's
  reverse-dependents lookup; `release_document` releases the new vector.
- **`references.mt`**: `dependent_documents` takes the declaring module's
  *name* plus its path; candidates = the reference index's importers of the
  name ∪ the workspace index's resolved-path dependents, filtered by
  `document_known_to_host` exactly as before.  The module-level arm passes the
  request analysis' `module_name`; the static-method arm infers the location
  file's module name via `resolver.infer_module_name` over the workspace's
  effective module roots (`module_name_for_source_path`), matching the host's
  `target_facts.module_name`.  The output order stays the reference index's
  document order — the same order the host's identifier index gives.
- **`lsp_index_test.mt`**: `test_reference_index_records_document_imports` pins
  the importers in index order and the re-note update (an import removed by an
  edit drops the document).

Measured: the canonical audit (`--canonical --cap 200`, SimpleGame) went
**10 → 6 differing entries, closed 4, added 0** — the four references
positions; the residue is the documented completion 2 / documentHighlight 1 /
hover 3 (the hover rows being the documented `type quat` and the two
builtin-hover warm artifacts).  The non-canonical audit is **5 → 5, closed 0,
added 0** (the documented 4 + the `documentSymbol` drift; this session's gate
run read **4**).  Gates (`tools/gates.sh --run`): dev build + 18/0 tests,
bootstrap fixed point + 18/0, harness 30/30 at **4 documented entries**,
recovery OK, fixture sweep closed 5 / 0 added, audit 4 (meter), valgrind 0
errors, Neovim smoke OK, soak 11.5 MB/cycle at `--cycles 200` (unchanged).

### Session 35 (2026-10-05) — `milkTea/debugInfo` bytes: the Facts and Bindings sections

Goal: close stage 17's second half — the **Facts** and **Bindings** sections of
the debug dump — plus the two AST residues the fixture exposed, so the
`milkTea/debugInfo` entry the harness has documented since session 33 becomes
byte-equal.  One commit, gated on the frozen tree.

1. **The binding-id substratum** (`semantic/analyzer.mt`, `semantic/scope.mt`).
   The analyzer now allocates the host's binding ids and records the host's
   binding-resolution snapshot:
   - `allocate_binding_id` / `next_binding_id`; ids are consumed exactly where
     the host's `value_binding` consumes them.  `allocate_declaration_binding_ids`
     runs the two declaration phases in the host's order — module-level values
     (const/var/event) in source order, then every function's and method's
     parameters in source order (`this` first for instance methods)
     — keyed by declaration-node address so the body checks can look their ids
     up (`param_id_base`, `this_binding_ids`; exported on `Analysis`).
   - `preassign_body_binding_ids` ports `nullability.rb`'s per-body walk
     (locals, `let … else` bindings, match-arm `as` bindings, struct-pattern
     positional args, for bindings, recursing into proc bodies and expression
     match arms); each body's map resets, mirroring
     `preassign_local_binding_ids`' node-keyed `||= allocate`.
   - The binding sites now record: locals/destructures/arms/for/else bindings
     fetch their preassigned id (or allocate, like the host's `||=`),
     `record_binding_type` stores the type under the id (a destructure's names
     share one id, last name wins — the host's overwrite), and identifiers
     resolved to a scope binding or a module value record
     `record_identifier_site` (the host's `record_identifier_binding`).
   - `scope.mt` gained a fourth frame stack (`binding_ids`) so identifier uses
     carry the binding's id; generic bodies (`suppress_binding_records`, the
     host's `check_function` early return for `type_params.any?`) allocate and
     record nothing.
   - Verified against the Ruby host's own `binding_resolution` on the test
     source before landing: `projects/mtc/test/semantic_test.mt`'s
     `test_binding_ids_follow_the_hosts_allocation_order` pins ids 1–5, the
     identifier-site sequence `[2,3,5,4,5,1]` and the declaration-site sequence
     `[2,3,4,5]` (recorded from `MilkTea::SemanticAnalyzer.check`).
2. **The Facts section** (`lsp/debug_info.mt`, `lsp/debug_ast.mt`).  Renders
   the host's `format_facts` shapes: ordered `Types` (the host's
   `INSTALLABLE_BUILTIN_TYPE_NAMES` order, then the prelude with its owning
   modules — the self's prelude registration is module-less, so the renderer
   supplies `std.option`/`std.result` — then `module_type_order`, recorded at
   every `declare_named_types` insertion), `Interfaces` (declaration order,
   `interface_order`), `Functions`/`Methods`/`Values` (source-order walks with
   `ValueBinding` reprs, `fn <name>`/`fn <receiver>.<name>` type strings, the
   AST headers, `external`/`async`/`const` flags, `body_return_type` with the
   async `Task[T]` unwrap, method receiver groups and the `static:` display
   key), `Imports` (resolved import order + exported-symbol counts summed over
   the self's per-kind export maps — `ModuleBinding.types` alone is opaques),
   and the trailing counters (`local_completion_frames` counted per checked
   body — foreign functions included, externals excluded; the callable-site
   counts; `required_unsafe_lines` as a Ruby array).
3. **The Bindings section** renders `identifier_binding_ids` /
   `declaration_binding_ids` in insertion order (`.take(30)` + `... (N more)`)
   and `binding_types` in id order, with the module-qualified type rendering
   the host's `to_s` gives (`main.Sample`; a bare constructed name resolves
   through the declared-type table).
4. **The AST residue the fixture exposed**: the host's debug AST is its cached,
   workspace-wrapped `SourceFile` — `SourceFile [Ln 1]`, a
   `module_name: QualifiedName(main)` child and a **`node_path_ids` map that is
   empty on this path** (dropped by the host's `skip_child_value?`).  The self
   now renders exactly that: `append_ast_section` takes the analysis' module
   name, the header is `[Ln 1]`, and `node_path_ids` is no longer emitted.
5. **The harness** (`tools/lsp_parity.rb`) normalizes `obj <n> → binding_id:`
   rows in the debug text (`obj <OBJ>`), so only the binding-id sequence
   compares; `tools/gates.sh`'s description strings were refreshed (4
   documented entries, unused-import 616/616, cli 24/37/0).

**Measured**: the whole debugInfo text is **byte-identical** to the host's on
the harness fixture (before the object-id normalization the only differing
bytes are the obj keys by construction); the corpus compare reads **1 differing
entry** — the documented directory-form `typeDefinition/imported` (the self
resolves where the host gives up) — and with `--stress` the documented set is
**4** (parser recovery, malformed frame, host facts lag, that typeDefinition).
Gates on the frozen tree: `tools/gates.sh --run` — dev build + 18/0 tests,
bootstrap fixed point (`stage2.c == stage3.c`) + 18/0, `test/mt` 60/0, cli
24/37/0, scoreboard parse 712/0, lint corpus 616 files / 496 agree / 120 differ
(the +3/+3 over session 33's 613/117 are session 34's new sources and edits; no
session-35 file flipped — `analyzer.mt` was already a differing file at HEAD),
unused-import 616/616, recovery OK, fixture sweep closed 7 entries / 0 added,
audit 5 differ (the documented 4 + the first-file `documentSymbol` race), emit-c
sweeps 49/49 same, valgrind 0 errors, Neovim smoke OK, soak 11.5 MB/cycle at
`--cycles 200`.

Residue (invisible on the fixture, staged for a later pass): generic
*instances* and foreign-boundary alias parameters allocate no ids where the
host's `validate_specialized_function_body!`/`foreign_mapping_public_alias_name`
do; `callable_value_member_access_sites` always renders 0 (the self records
identifier sites only); `structural_method_set` ordering for generic receivers
falls back to the literal target name; the `.take(30)` obj keys are node keys,
not Ruby object ids (normalized by the harness); and the session-33 literal
position/node-count residues stand.

### Session 34 (2026-10-04) — DAP Track 5: the bridge, the loop and the map

Goal: finish DAP so VS Code's default `lldb-dap` backend debugs a `.mt`
program end to end.  Six commits, each gated (dev build + 18/0 tests +
`tools/gates.sh --areas dap --run`; valgrind on the loop and both backends);
at close the whole `dap_smoke` matrix is zero differing rows except the
documented self-better frame-mapping row.

1. **`0d1dacab` — the debug-map sidecar.**  `projects/mtc/src/mtc/debug_map.mt`
   ports `lib/milk_tea/tooling/debug_map.rb` (model, `from_ir` with
   `first_statement_*`/`collect_locals`, relative payload paths, a tolerant
   `load_for_binary`); `build.mt`'s success branch writes
   `<output>.mtdbg.json` (write failures warn only).  The map is semantically
   equal to the host's on the smoke fixture; `line: 0` is synthetic and
   omitted like the host; `debug_map_test.mt` locks the model and the
   write→load round trip.
2. **`02c2c335` — build-on-launch and the cache-carried sidecar.**
   `resolve_launch_program` spawns the running compiler
   (`/proc/self/exe build <abs.mt> -o <tmp>/<stem> --profile debug
   --no-debug-guards`), remembers the temp dir on the Session for
   terminate/disconnect cleanup, and turns a failed build into the launch
   error.  `build_cache.store`/`materialize` carry `debug-map.json` so a
   `[cached]` build still maps frames — the host skips its map on a
   program-cache hit, which is why its real-lldb row shows the unmapped
   `main_add`.  Also fixed the `process` event's empty `name`.
3. **`9d3b27db` — one libuv loop, start on configurationDone.**
   `protocol.mt`'s stdio reader became a `Framer` over `std.process.read_fd`
   (new public wrapper); `server.mt` runs `uv_run(UV_RUN_ONCE)` over a stdin
   poll handle and a 100 ms wake-up timer, with non-capturing callbacks that
   only fill framers, dispatching between turns.  The process backend now
   matches the host: start at `configurationDone`
   (`maybe_start_or_stop_on_entry`), `continue` starts after an entry stop,
   `pause`/`continue` SIGSTOP/SIGCONT, `terminate`/`disconnect` SIGTERM and the
   exit produces `terminated` → `exited` with the real code.  Valgrind found a
   framer use-after-free (`framer_next` parsed the sliced body after `compact`
   freed the buffer) — parse first, then compact.
4. **`c3e7ce99` — the bridge.**  `lldb_backend.mt` (adapter spawn, stdin
   framing, adapter→client pending with 5 s deadlines, the 15 s reverse table)
   and `lldb_policy.mt` (deferred client initialize with merged capabilities,
   suppressed adapter `initialized`, launch/attach `backend_start_arguments`,
   `configurationDone` gated on the start response, terminate→disconnect
   fallback, generic forwarding, SIGSTOP→pause rewriting, continued dedup,
   `--adapter-path` with `.rb`→ruby).  The server registers the adapter's
   stdout poll handle when it starts.  `dap_smoke` gained the embedded fake
   adapter and a reverse `runInTerminal` round trip.
5. **`66d0b555` — rewrites, sync, pause diagnostics.**  The map loads at launch
   or from the adapter's `modules`; stackTrace frames rename and feed the frame
   map; scopes record variablesReferences; Locals variables rename with
   `__mt_*` dropped; evaluate/setVariable/setExpression/dataBreakpointInfo
   rewrite through the ported token scanner; setVariable falls back to
   setExpression via the scope frame; breakpoints are stored and re-synced at
   `configurationDone` with the host's `breakpoint changed` events (including
   its string-key/symbol-key comparison quirk); a pause-requested stop emits
   the host's console `output` summary.  Valgrind found and fixed a second
   use-after-free (`stop` freeing the framer mid-`pump` — the loop re-reads it
   each turn), and a timed-out `launch` now releases a deferred
   `configurationDone` (the host's timeout does the same).
6. **This commit — real lldb + VS Code.**  `dap_smoke`'s real section builds
   the `.mt` source with each server and drives the breakpoint session on real
   `/usr/bin/lldb-dap`: every row matches except `frame0 name` (self `add`,
   host `main_add`).  The extension's descriptor factory now emits
   `mtc dap --backend=… [--adapter-path=…] …extraArgs` (the old `unshift` put
   the flag before the subcommand and both CLIs rejected it); the local
   extension bundle was rebuilt.  The live VS Code F5 check is the remaining
   manual step.

Residue/notes: the `launch` response with real lldb-dap exceeds the 5 s
backend timeout because lldb-dap answers after `configurationDone` — the host
behaves identically (both write the timeout error and continue), and VS Code
does not block on the launch response, so this is the host's shape rather than
a defect; `stepIn`/`stepOut`/`attach`/`restart` are forwarded but not
exercised by the smoke's real section; the bridge's leaks (~13 KB definitely
lost per session) are the JSON-lookup/convention class already accepted by the
LSP gate (0 errors is the criterion).

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

### `prefer-inline-methods --fix` and the fix-validation guard (2026-10-03 session 28)

The stage-10 auto-fix plus the guard that makes the fix engine's accept/reject
decisions match the host's.

- **`prefer_inline_methods_edit`** (`linter/fix_engine.mt`): the host's
  `prefer_inline_methods_edits` — locate the first `struct <name>` declaration,
  its last member line, the block's last non-blank line, require the lines
  between to be blank, then replace `[last_member, ext_end + 1)` with the
  member line + a blank line + the method lines.  The block's target name is
  parsed from the warning's line (`extending <Name>:`), since the self's
  `Warning` carries no `symbol_name`.  Registered in `fixable_codes()`, so
  `--fix`, `source.fixAll` and the quickfix all see it.
- **`validated_fixed_source`** (the same file): the host
  (`tooling/linter.rb:493-514`) keeps a fix pass only when a re-analysis of the
  fixed source adds no error signature — `(line, column, message)` counts, so a
  fix that merely *shifts* a pre-existing error's line is rejected too.  The
  self's `fix_rule_single_pass` now re-parses and re-checks the candidate and
  compares the diagnostics against the pass's own analysis; a batch that
  corrupts the source (the multi-block `prefer-inline-methods` case: two edits
  built from the same lint snapshot with stale line numbers) is discarded.
- **Locked** by two `fix_engine_test.mt` cases (canonical inline, non-adjacent
  no-op) and a host-vs-self `lint --fix` sweep over 15 examples × 12 rules:
  **179/180 byte-identical**; the single divergence
  (`reflection_advanced.mt` `prefer-let`, `stage2 == self`, so pre-existing) is
  the self's missing editable-site for a specialized call (`Track 2`).
- **Residue**: on a source carrying a *member-assignment immutability* error
  (`this.value = 0` in a non-editable method) the host's validation rejects
  where the self's analysis reports nothing — the missing
  `cannot assign through immutable this` check (Track 2, new item).

### Code actions: the host's per-diagnostic branch set, byte-equal (2026-10-03 session 28)

Stage 16.  The self's quickfix dispatch offered a *different* set from the
host's (`Fix <code>` titles, an `unused-local` action the host has none of,
engine fixes for rules the host does not route there, no `diagnostics` echo).
The rewrite mirrors `lsp/server/code_actions.rb:29-297` branch for branch:

- **Titles** (`quick_fix_title`): the host's `STATIC_QUICK_FIX_TITLES` table,
  and a code with no entry emits a JSON `null` title — which is how the
  `unused-import` action looks (its engine edit is offered, its title is nil).
- **The cast action** (new): any `cannot assign … expected T` message; the
  line's first `=` splits it, a "simple" operand (dotted identifier or numeric
  literal) is cast bare and anything else parenthesized, and the host
  re-prefixes the line's indent to the already-indented left side — the doubled
  indent is reproduced exactly (`        let s = int<-(…)`).
- **The import action** (new): `unknown type|callable X` with
  `data.suggestion` "did you mean '<path>'" and a dotted path → `Import
  <path>`, inserting `import <module>\n` at 0:0.  The self's analyzer emits no
  suggestions, so this fires only for diagnostics a client echoes.
- **The rest**: `shadow` = the host's annotation-only action (no edit);
  `unused-param` = `Rename parameter 'a' to '_a'`; `dead-assignment` = remove
  the line; the unsafe wrap = the host's block body (`indent + "unsafe:"`,
  body indented one level) and title; the match arms = the case list in the
  title and the insertion after the match's last line (`find_match_end_line`);
  `source.fixAll` = `Apply all auto-fixes`; every action carries
  `diagnostics: [diag]` (the request's object re-rendered through
  `std.json.render`).  The `context.only` gate had a real bug — `source.fixAll`
  defaulted on for *any* non-empty `only` (a `only: ["quickFix"]` request got
  the fix-all action the host does not send); `want_fixall` now starts false.
  The self keeps accepting the spec's lowercase `quickfix` spelling where the
  host checks only `quickFix`.
- **Engine LSP shapes**: the host's whole-line rewrites carry their new line
  and a trailing newline; the self's `lsp_edit_for_warning` is now a
  passthrough and the generators match (`prefer-let` whole-line,
  `prefer-let-else` and `prefer-inline-methods` trailing newlines,
  `redundant-else`'s replacement ends with one too).  Fixing
  `redundant-else` exposed a representation bug: the scan treated
  `split_lines`' trailing empty element (the source's final newline) as a body
  line, so the rewrite silently consumed the final newline — the new
  `content_line_count` keeps it.

**Measured**: the harness's new `codeAction/quickfixes` entry (nine
manufactured diagnostics, one per branch) is **byte-equal action for action**;
the corpus is **67 requests + 19 probes** at the same 5 documented entries; the
`lint --fix` sweep stays 179/180 (the one divergence pre-existing, Track 2) and
all 15 self-test files pass.  The `LSP fix shapes` also lost their
`--fix`-only conversion: `apply_edit`'s insertion now splits like Ruby
(a trailing newline terminates a line instead of adding an empty one).

**Residue**: `redundant-cast`'s LSP edit is a single spanning edit where the
host emits two in the parentheses-only case.  (The reserved-name quickfix's
single-site rewrite was closed later in the session — see the
`reserved-primitive-name` record below.)

### `reserved-primitive-name`: the multi-site rename (2026-10-03 session 28)

Stage 8.  The self's fix renamed the *first* reserved word on the warning's
line to `<name>_value` — the wrong suffix for functions (`_fn`) and import
aliases (`_module`), no use sites, no conflict resolution, and a warning
without a column.  The port follows the host's `reserved_names.rb`:

- **Collection** (`linter.mt`): the seed pass registers a fix per import alias
  (only `Option`/`Result` collide, `RESERVED_IMPORT_ALIAS_NAMES`) and per
  module declaration (functions/extern/foreign → `_fn`, consts/vars/events →
  `_value`), and the declaration walk registers locals/params (`_value`); each
  fix carries its declaration site and the warning now carries the host's
  column/length.  `next_available_reserved_primitive_name` computes
  `<base>`, `<base>_2`, … against the names in play, and the conflict pass
  re-runs on every declaration, bumping any fix that wants the newly declared
  name.
- **Use sites**: the identifier-expression arm records the position against the
  binding the scope walk resolves — `ctx_mark_used` now returns the innermost
  entry's fix index (0 = no local, 1 = local without a fix, 2 + index = with
  one), so a local `int` shadowing a module `int` claims its own uses
  (`return int` → `int_value`, the module's stays `int_fn`).  Module bindings
  answer through a name → fix map when no local matched.
- **Applying**: `--fix` applies every site right-to-left
  (`apply_reserved_name_fixes`, deduplicated, bounds-checked through
  `apply_edit`); the LSP action is the host's `Rename 'x' to 'y'` with one edit
  per site, matched by declaration site (`code_actions.rb:70-97`).

**Measured**: the fixtures match the host byte for byte — a function with three
uses (`int_fn`), a const (`int_value`), an `int_fn` name collision
(`int_fn_2`), and the shadow case; the harness's new
`codeAction/reserved-name` entry (a closed `reserved.mt` fixture, so its sema
error stays out of `workspace/diagnostic`) is byte-equal; the corpus is
**68 requests + 19 probes** at 2 request-level + 3 stress documented entries,
and the `lint --fix` sweep stays 179/180.

**Found on the way (Track 2):** the CLI `--fix` path lacks the host's
unresolved-import guard, and the analyzer's reserved-name *errors* differ (the
host errors on module-level reserved names too, with its own message; the self
checks only locals/params, with another message).

### The per-module `ModuleCache`: an edit re-analyzes only its own module and its dependents (2026-10-04 session 29)

Track 7's edit-latency foundation.  Every content version used to re-parse and
re-analyze the whole import closure (measured 54.3 ms per edit on
`SimpleGame/src/main.mt`); the loader now keeps a workspace-owned cache of
parsed modules and their analyses, so an edit costs one parse + one analysis +
the dependents' re-checks.

- **`loader.ModuleCache`** (`module_loader.mt`) is keyed by resolved module
  path.  Each entry owns the parsed module (source, AST, lex/parse diagnostics),
  its analysis and export binding on the heap, an analysis **version** assigned
  from the cache counter on every parse/re-analysis, and a snapshot of its
  **direct-import paths + versions** taken when the analysis was built.
- **`check_program_with_source`** takes an optional cache (and the open-document
  map).  `parse_all` reuses a cached module whose content hash matches (the
  freshly read copy is dropped) — including the AST, which matters because
  `resolved_expr_types` is pointer-keyed.  `module_needs_rebuild` decides
  analysis reuse at check time: the module's resolved import-path list must
  match its snapshot and every **forward** direct import's version must match
  (a cycle back-edge is skipped — the module's check could not see that
  dependency's binding, and comparing it would thrash the `std.option` ↔
  `std.result` cycle).  A moved version cascades through direct edges in
  dependency order, so a rebuild chain stops exactly at the edited module's
  dependents; dependency-order checks mean no fixpoint is needed.
- **Cross-program invalidation** (`lsp/workspace.mt`): each per-root Program
  entry records the module cache's **generation**; `open`/`change`/`close` bump
  it and every lookup validates it, so an edit to an imported module invalidates
  the dependent's cached Program and the rebuild re-analyzes the changed chain.
  Without this, a dependent answered its stale snapshot until edited itself —
  the dependency probe's pre-change behaviour.
- **Open buffers beat disk for imports** (the host's `source_overrides`): the
  loader consults the workspace's `open_docs` before reading a module from disk.
  This was a pre-existing parity gap the dependency probe exposed: an unsaved
  edit to an imported module previously reached no dependent at all.
- **Ownership**: cache entries own module storage; cache-built Programs hold
  shallow copies and release only the modules vector (`Program.modules_owned`);
  a replaced entry releases its module, its previous analysis' retained
  diagnostics and its snapshots (`release_module_cache_entry`), while analysis
  *contents* keep the compiler's arena-leak convention.  A stale Program is
  never read after its entry is replaced: the generation moves first
  (`release_entry_analysis` documents the argument).  The CLI path (`cache =
  null`) keeps its exact previous ownership and behavior.

**Measured.**  Edit cycles on `SimpleGame/src/main.mt` (`tmp/lsp_edit_perf.rb`,
10 edits): **didChange 54.3 → 5.0 ms median** (min 4.8, max 5.4; the
diagnostic pull 0.2 ms; `didOpen` unchanged at ~52 ms — the cold build of the
whole closure).  Dependency probe (`tmp/lsp_dependency_probe.rb`: direct
signature edit, two-hop field-type chain via a mid module, create + restore):
the pre-change binary fails 3 checks, the new one passes all.  `mtc test`: 15
files / 0 failed (5 new `module_loader_test.mt` cases: unchanged-closure reuse
(2 parses/2 analyses → unchanged), root-only re-analysis (+1/+1), dependency
cascade (+1 parse/+2 analyses and the dependent's new diagnostic), a created
import (the importer re-analyzes when its unresolved import appears), and the
open-buffer override).  CLI paths byte-identical (check and emit-c against the
pre-change binary on `language_baseline.mt` and error probes).  Gates on the
frozen tree: bootstrap fixed point (stage2.c == stage3.c, 15/0), `test/mt`
60/0, `cli:parity` 24/37/0, examples 49/49 same, fixtures closed 22 entries
(0 added), audit 4 stable entries (completion 2, hover 1, documentHighlight 1;
diagnostic/definition/references/typeDefinition/inlayHint/workspace-symbol all
0), harness 30/30 keys at 5 documented entries, recovery OK, valgrind over the
68+19 harness drive 0 errors (7,375,764 bytes definitely lost — the drive's
standing analyzer/cache leaks, not new errors), Neovim hover OK.

**Fixed on the way (tools):** `gates.sh`'s valgrind gate passed its wrapper to
`lsp_parity.rb` as `--server <wrapper>`, which spawns the wrapper with **no
arguments** (the compiler CLI, not `lsp`); it is a meter gate, so the broken
invocation never failed the run.  It now passes `--server self --self
<wrapper>`, and the gate genuinely runs the 68+19 drive under valgrind (0
errors on this commit).

**Residue:** `[LSP perf]` on a *closed* dependency re-reads and hashes every
closure file per rebuild (open documents come from memory) — **session 30
reduced this for the token path** (import surfaces now come from the module
cache) and for references (the loader analysis replaces an eager discarded
parse).  The F9/C2–C3 memory items were **closed in session 30** (the analysis
small-strings leak remains the pre-existing convention).

### Readiness: scan tables released, the index bounded and stamp-cached, request paths served from the module cache (2026-10-04 session 30)

Track 7's F9/C2–C3, plus the avoidable per-request re-reads the new soak
exposed.

- **ScanFacts release** (`semantic_tokens.mt`): one token scan builds ~20
  maps/vecs plus the binding and type-parameter vectors, and nothing freed
  them.  `release_scan_facts` (called at both `build_scan_facts` sites) now
  releases all of it, and a new `key_storage` vector owns the composite
  `<alias>.<member>` / `<Type>.<field>` key buffers the maps hold `str` views
  into — every key builder pushes its buffer there (alias exports, static
  members, nested type keys, callable fields, receiver structs).  Two lookup
  paths that built keys without releasing them (`scan_nested_type_member`,
  `scan_callable_field_call`'s per-candidate `field_key`) release now.
- **Reference index bound + stamp cache (C2/C3)** (`reference_index.mt`,
  `workspace.mt`): `note_document_tokens` indexes an open document's buffer
  directly (no `document_source` copy) and for a closed document compares the
  file's `(size, mtime)` against a recorded `DocumentStamp` before reading and
  lexing — an unchanged closed document costs one `stat` instead of a read +
  two hashes.  The index tracks `retained_bytes` and drops the oldest documents
  (with their hash and stamp entries, so a re-note re-reads them) past
  `max_retained_bytes` (32 MiB default; a field so tests shrink it).  Hashes
  and stamps update **in place** (the old code leaked a path `String` per
  re-index), and `forget`/eviction release their map keys.
- **Module-cache request paths**: `loader.cached_module_surface` hands out a
  cached module's `{source_file, analysis}` by value, and
  `register_resolved_import` prefers it — the token scanner no longer re-reads
  and re-parses every import per request (a cold import is warmed through
  `analysis_entry_for`, with the old direct parse kept as a last-resort
  fallback).  `handle_references` now takes its AST/analysis from
  `analysis_entry_for` (the loader analysis the other requests share) and only
  parses single-file when the document does not load — its old eager parse ran
  and was discarded on every request.
- **Soak profile and the long-session blocker**: `tools/lsp_soak.rb` generates
  a ~5k-line synthetic workspace (two ~500-line imports, cross-references) and
  drives mixed cycles (edit + `semanticTokens/full` + `diagnostic` +
  `references`, hover every tenth), reporting the RSS slope; a `soak` meter
  gate runs a short pass per commit.  On that workspace the full-cycle slope
  went **15.2 → 9.7 MB/cycle** (100 cycles: 1.52 → 0.97 GB); the breakdown
  after the changes is roughly 3.5 MB for the per-edit Program rebuild,
  3.5 MB for the token path's single-file parse, 2.2 MB for the references
  path, plus hover.  **The residue is the per-parse leak convention**: a
  valgrind attribution run shows the biggest losses are the lexer's
  `Vec[Token]` buffers and parser AST vectors (`parse_params`, …) allocated
  with `heap.must_alloc` — the parser documents "one file per run and exits",
  which is true for the CLI and false for a long-lived server.  A real RSS
  ceiling (C4) needs per-parse ownership (an arena the LSP can release when a
  parse is replaced) or the remaining ~38 per-request `parser.parse_source`
  sites routed through the shared caches; both are their own work items.
- **Tests**: four `lsp_index_test.mt` cases (note idempotence, re-index order,
  the retained-text bound with a synthetic budget, stamps + `forget`) and one
  `module_loader_test.mt` case (`cached_module_surface` cold → served), for
  **16 files / 611 tests / 0 failed**.
- **Measured**: harness 30/30 keys at the 5 documented entries; audit 4 stable
  entries (completion 2, hover 1, documentHighlight 1; references/semantic
  tokens/diagnostic all 0 — the token and references rewiring is
  byte-neutral); recovery OK; valgrind 0 errors over the 68+19 drive
  (7,138,997 B definitely lost, the analyzer's per-analysis small strings);
  `[LSP perf]` stays 4.9 ms median per edit on `SimpleGame/src/main.mt`.
- **Found on the way**: `workspace.note_document_source` is dead (no callers),
  left in place; the fixture sweep's probe workspaces and the audits should be
  run **serially** — a soak or test run in parallel with the audit starves it
  and turns timeouts into mass false differences (seen once this session,
  re-run clean).

### LSP close-out: `--timings`, the lint tier, canonical audits, client behaviours and the differences table (2026-10-04 session 31)

Track 7's remaining readiness residue plus the stage-18/stage-11 leftovers.

- **`--timings` breakdowns (stage 18)**: a new `mtc.profile` module carries the
  host's `Linter::Profile` (named phases with totals and call counts, the
  descending-total renderings, `rule.*` rows and the shared monotonic clock).
  `tidy.format_source_profiled` records `format` plus each mode's steps
  (`format.lex`/`format.parse`/`format.ast` for the AST modes,
  `format.cst`/`format.cst_fmt`/`format.normalize`/`format.wrap`/
  `format.blank_lines` for the CST ones) and the format command prints the
  host's single-file line (leading blank line, phases ≥ 0.1 ms, descending,
  last after the output).  The linter takes `LintOptions.profile` and records
  `rule.<code>` for every rule it dispatches (`unused-import`,
  `reserved-primitive-name`, the per-body group, `doc-tag`, `event-capacity`,
  `trailing-list-comma`, `prefer-inline-methods`, `line-too-long`,
  `missing-return`; the combined prefer-else pass records as
  `prefer_let_else`) plus structural `visit_decl`/`flow.graph` phases; the lint
  command prints the host's shapes — `lint profile <path> (lint scan|pre-fix
  scan): rules=… total=…`, the rows (`<code>: <n>x total=… avg=… share=…%`,
  12), `non-rule hot phases`, then `Profile (lint): N file(s)` + `Total:` (the
  clean path prints only the file block, as the host does).  Verified against
  the host shape-by-shape on `language_baseline.mt` and a `--fix` run; the
  numbers themselves are nondeterministic and are not compared anywhere (the
  `cli_parity` `lint-timings` case can therefore never be byte-equal — a
  normalizer for `[0-9.]+ms` is the Track 4 follow-up).
- **Linter `:fast`/`:full` tier (stage 11, first half)**: `LintOptions.lint_tier`
  (`LintTier.fast`/`full`, default `full`) with the host's `full_tier?` gating
  — the six per-body flow rules, the If/Match preference rules (including
  `prefer-is-variant`), `prefer-struct-with` and `doc-tag` are full-only, and
  the release rule is full-only in **proc** bodies only (the host's
  `visit_function` vs `ProcExpr` asymmetry).  The CLI/LSP keep passing `full`
  (the default) so nothing observable changes; diagnostics scheduling stays out
  of scope.  Three `linter_test.mt` cases lock it (fast skips the flow rules,
  full runs them, fast keeps an always-on rule).
- **D2 — canonical audit mode**: `tools/lsp_project_audit.rb --canonical` sends
  the identical request history twice and records the second pass, so both
  servers are equally warm; `--canonical-settle SEC` (default 1.0) waits in
  between.  Two canonical runs at `--cap 30` returned **identical differing
  sets**; the drift's source is the host's asynchronous warm-up, and the
  canonical run is now the verification mode (the gates keep the fast
  non-canonical audit).
- **The canonical audit's full run surfaced warm-state residue** (new, detailed
  in Track 7): 10 differing entries — the 4 documented completion/highlight
  ones plus the builtin-type hover family (`type quat`, `str`) and **four
  `references` entries** (`docs/data_structures.mt@34:25`, `@112:29`,
  `@167:37`, `@195:37`) where the host's warm candidate coverage includes many
  more `std/` files (25 vs 4 at `@34:25`).  Neither class is a session-31
  regression (this session's changes do not touch references/hover).
- **C5 client behaviours**: six measured probes in the harness's stress section
  (`c5/…`): `references` with `includeDeclaration: false`, a
  `didChangeConfiguration` formatter-mode switch and back, a watched file
  created on disk, a `$/cancelRequest` for an unknown id, an added workspace
  folder, and a closed-file disk edit.  Two real gaps surfaced and were fixed
  in `workspace_notifications.mt`: `didChangeConfiguration` now applies
  `settings.milkTea.format.mode` (with the host's `milk_tea`/bare-`format`
  fallbacks), and `didChangeWatchedFiles` now marks each changed path dirty in
  the workspace symbol index (and drops its definition/reference entries), so a
  created file joins `workspace/symbol` on the next query like the host's.  All
  six probes are byte-equal.
- **C6**: the deliberate-differences table is `docs/lsp-design.md` §8 (12 rows
  with direction and pinning tool, plus the verification checklist).
- **Measured**: bootstrap fixed point (16 files / **614 tests** / 0 failed),
  `test/mt` 60/0, `cli:parity` 24/37/0 (unchanged), formatter 708/708 all three
  modes, harness 30/30 keys and the 5 documented entries (the new `c5/` probes
  included, all equal), recovery OK, the canonical audit's 10-entry set above,
  valgrind 0 errors over the (now 68+27) harness drive, Neovim hover OK, soak
  10.8 MB/cycle (200 cycles, the meter).  The lint corpus reads **610 files /
  493 agree / 117 differ** — the drift from the recorded 609/494/115 is the
  sweep linting this session's own compiler sources (the changed files carry
  the documented `prefer-let`/`prefer-try`/`redundant-cast`
  float-widening/prefer-let-else column deltas), not a linter regression.
  Residue: the builtin-hover/canonical references rows (Track 7), the
  `cli_parity` timings normalizer, and the canonical audit staying a
  session-verification run rather than a gate.

### LSP accuracy: qualified enum/flags members, member-before-binding order, exact inlay ranges (2026-10-04 session 32)

A user-requested accuracy pass over `examples/language_baseline.mt` (hover,
completion, navigation, outline, diagnostics; both servers driven side by side
with a curated probe table, then judged semantically).  Three real defects:

- **Qualified enum/flags members were a stub.**  `resolve_enum_member` (the
  `EnumType.member` arm) rendered `Type.member` at a hardcoded `line = 1`, with
  the member lookup keyed on `match_case_names` — which omits *flags* members
  (flags are not matchable), so `Mask.a` hovered `null` and `State.running`
  claimed `Defined at: <file>:1` with a definition at line 0.  The host's shape
  is `member: Type` plus the explicit value rendered by its AST formatter
  (`running: State = 1`, `a: Mask = 1 << 0`; an implicit member carries no
  value) located at the member's own declaration.  The self now does exactly
  that: an in-file scan of the enum/flags declaration, then an imported-module
  fallback that scans the importing file's modules' cached ASTs (via
  `analysis_entry_for`, no reparse) — but the imported result deliberately
  keeps **no location**, because the host's `type_name_member_access?`
  classifier misses `alias.Enum.member` (its hover has no `Defined at` and its
  definition answer is the generic fallback); pointing at the imported
  declaration is recorded as a Track 7 improvement candidate.  A new public
  `ast_formatter.render_expression_text` renders the value expression the same
  way the host's `enum_member_value_text` does.
- **A dotted member could lose to a same-named local.**  `handle_hover` calls
  `resolve_local_hover` before the member arms, so `Mask.a` with a local `a` in
  scope answered the local (the host resolves member accesses ahead of its name
  tables).  `resolve_local_hover` now returns none for a token with a dot
  receiver; the member/method arms in `resolve_cursor` handle it, which also
  fixes field-read shadows (`let x = s.x` with a local `x`).
- **Inlay hints used a line-only range.**  The host's `position_in_range?`
  compares (line, character) at both ends; the self compared lines, so a hint
  at the request's end line past the end column was emitted where the host
  omits it (found when a corpus line landed exactly on `line 40, char 0`).  The
  request's characters now thread through as a `HintRange` and every check
  (call, local, return) uses the host's predicate.  The semantic-token range
  path stays line-granular — the host's is too.

**Locked by the corpus**: the harness gained `hover/enum-member` and
`definition/enum-member` (`Color.green` in the synthetic workspace) and now
covers 70 requests + 27 probes; the inlayHint entry's fixed range exposes the
boundary.  **Measured**: probes on `language_baseline.mt` (26 positions, 82
outcomes), on a copy with extra member contexts (103 outcomes) and on an
imported-enum/flags fixture (18 outcomes) — **0 host/self differences**; the
harness's differing set is the 5 documented entries (both new corpus entries
byte-equal); tests 16 files / 0 failed; the fixture sweep's 14 workspaces all
"added 0"; the audit reads the 4 documented entries plus the documented
first-file `documentSymbol` race.  Deferred: the imported-member location
improvement (Track 7 residue).

### Completion labels: the `static:` table-key leak (2026-10-04 session 32, second commit)

A user report: accepting a completion on a value receiver inserted
`n.static:create(name)` — invalid source (a live parse error in the user's
`SimpleGame/src/main.mt`).  Root cause: the host's method table keys static
methods `static:<name>`, and `completion_items_for_value_receiver` used the raw
key for the item's **label, detail, insertText, sortText and data**, so the
prefix filter (`mname.start_with?(prefix)`) never matched a typed prefix
either.  The host's own audit test asserted the *intended* behavior
(`refute_includes labels, "create", "completion on value should NOT include
static method 'create'"`) — it had passed vacuously, because the mangled label
hid the static method from the assertion.

Fix, in both implementations (parity kept):
- a **value** receiver's completion skips static methods — they belong to the
  type receiver (`Player.` → `zero`), which already stripped the key;
- the unresolved-receiver **method-fallback** keeps every method but emits the
  **bare** name (never a `static:` key) as label/insert/detail/data;
- the self's `emit_receiver_method` takes a `ReceiverMethodScope`
  (statics-only / instances-only / all) instead of the `static_only` flag, so
  the three call-site classes are explicit.

The host test gained an assertion that no label or `insertText` starts with
`static:`.

**Verified**: `n.` on `SimpleGame/src/main.mt` → the two fields, no static
(host and self byte-equal); `mod_a.Box.` → `create` with the
`create(${1:value})` snippet; a typed prefix (`b2.cr`) → `create` via the
fallback; host LSP tests green (`completion_test` 20 runs, the audit test 28 —
previously 1 failure); self tests 16 files / 0 failed; the harness's differing
set stays the 5 documented entries; the fixture sweep 14/14 "added 0"; and the
project audit on a *clean copy* of SimpleGame reads the 4 documented entries.
The live SimpleGame audit reads 147 entries only because `src/main.mt` still
carries the breakage the old insertion produced (its parse error cascades
through every request on that file) — the user's file needs that line removed
or replaced (`node.Node.create(c"World")`).

### `milkTea/debugInfo`: the histogram tie order, the Diagnostics section and the AST tree (2026-10-04 session 33)

Stage 17's first half.  The host's dump has seven sections; the self rendered
four (Header, Tokens, Parse Errors, plus a self-only `Workspace` section).
Everything except **Facts** and **Bindings** is now byte-equal on the harness
fixture:

- **The histogram's tie order is MRI's *uniform* introsort, not `ruby_qsort`.**
  The plan's note ("port `ruby_qsort`") was wrong: `Array#sort_by` /
  `Hash#sort_by` build `[key, value]` pairs and sort them with `sort_by_cmp`,
  and when every computed key is a Fixnum (`-count` is) the *uniform* path
  `rb_uniform_intro_sort_2` (`enum.c`) runs instead — a depth-limited introsort
  (Hoare partition around `med3_val`, insertion sort ≤ 16, heapsort after
  `2·⌊log2 n⌋` levels, with an already-descending short-circuit).  Found by
  building the candidates (MRI's `ruby_qsort`/qs6 from `util.c`, glibc's
  `qsort_r`) and comparing permutations against Ruby's on the fixture and on
  random tables: qs6 and glibc both disagree with Ruby, the uniform introsort
  matches.  The Ruby-side transliteration was validated on **5000 random count
  tables** before porting; `debug_info.mt`'s `histogram_intro_sort` reproduces
  it (the one port bug found — a flipped child comparison in `heap_down` — is
  covered by `debug_info_test.mt`'s alternating-count case).
- **The Diagnostics section** renders the loader-backed analysis' semantic
  diagnostics in the host's shape (`E ERROR   sema/error [Ln 42, Col 14]: …`);
  the self-only `Workspace` section is gone.
- **The AST section** ports the host's generic renderer (`format_ast`,
  `compact_ast_repr`, `value_repr`, `ast_node_header`).  The host walks Ruby
  `Data` members, so each host class has a hand-written counterpart with its
  member order, labels and skip rules (`line`/`column`/`length`/`module_kind`/
  `visibility`/`name` never render as members; `name` feeds the header).
  Behaviours reproduced deliberately: `EnumDecl`/`FlagsDecl` render **no**
  children (their `members` field shadows `Data#members`); `body` members are
  statement arrays on the host while the self wraps them in `stmt_block` (the
  wrapper never renders); `MethodDef`'s and `InterfaceMethodDecl`'s `kind`
  always renders; a non-compact single child renders with no member label; a
  compact child renders `member: repr`; `value_repr`'s 57-char `...`
  truncation; `Data#to_s` inside format-string part reprs; the synthesized
  `FunctionType`/`ProcType`/`TupleType`/`DynType` nodes the self encodes inside
  `TypeRef`; tuple-element arrays; `TypeArg(<compact value>)`; wildcard match
  arms as `pattern: id:_` with the arm's location from the pattern; statement
  `when` branches rendered as `MatchArm` (the host parses them with
  `parse_match_arms`) while module `when` branches are `WhenBranch`;
  `AttributeDecl` symbol targets (`:field`); `ValueTypeParam ◆ N`; `DetachExpr`'s
  synthetic `ExpressionStmt` body; `LocalDecl`'s nil name for destructuring;
  `else_binding` as an Identifier.  The AST section is **byte-equal on the
  harness fixture** (158 lines) and down to two `RangeExpr Col 0` rows on
  `examples/language_baseline.mt`.
- **Node counts**: `node_ids`/`node_path_ids` are the **sizes of the host's
  maps** — the number of distinct AST objects its `assign_node_ids` traversal
  reaches (a re-visit overwrites the same key, so the count does not double).
  `count_ast_nodes` mirrors the traversal: blocks contribute their statements
  (never the wrapper), nested `parallel` body arrays are not traversed, an
  implicit enum member's synthesized value expression is not counted, and a
  numeric type argument is an `IntegerLiteral`/`FloatLiteral` on the host while
  the self encodes it as a position-less `TypeRef`.  The counts are exact on
  the fixture set (main 126/126, containers 69, generics 152, inlay 78,
  scratch 6) and read 6759 vs the host's 6760 on `language_baseline.mt` (one
  node, not yet located; recorded as residue).
- **`fmt.append_double` is C's `%g`**, not Ruby's `Float#to_s`, and the debug
  AST needs the latter: `c_backend`'s `double_to_str` + helpers moved to the
  new `mtc/float_text.mt`, shared by the backend and the debug renderer.  New
  files also: `mtc/lsp/debug_text.mt` (Ruby inspect/truncation helpers,
  `append_rule`) and `mtc/lsp/debug_ast.mt` (the renderer + counter).
- **Tests**: `projects/mtc/test/debug_info_test.mt` pins the introsort
  (the fixture table, a tie pair, an ascending-reversal case, an
  n > 16 alternating case that exercises the partition path and the heapsort
  fallback, and the descending short-circuit) — 17 files / **618 tests** / 0
  failed.

**Measured** (gates on the frozen tree): bootstrap fixed point holds (stage2 ==
stage3; 17 files / 618 tests / 0 failed); `test/mt` 60/0; `cli:parity`
unchanged; examples 49/49 same; `sexpr lower` 39 match / 622 differ / 51
host-rejected / 0 self-rejected of 712 files (the +7 files and differs over
session 17's 615 are this session's own new compiler sources; the match count
is unchanged, so no file regressed); LSP harness 30/30 keys at the **5
documented entries** (the debugInfo entry now differs only in the missing
Facts/Bindings sections); recovery OK; the fixture sweep closed 5 entries (0
added); audit 4 stable entries; valgrind 0 errors; Neovim smoke OK; soak
10.8 MB/cycle (unchanged); lint corpus 613 files / 496 agree / 117 differ (the
+3 files/agrees are this session's new sources).

**Residue for the second half** (the next item): the Facts section needs the
analyzer's type/value registration order (the maps are hash-ordered) plus
ValueBinding ids and the per-function binding views (`body_params`,
`body_return_type`, `instances`, the AST node); the Bindings section needs the
host's binding-id allocation order, the identifier/declaration node maps and
`binding_types`; the harness `normalize` gains the `object_id` rule.  The
literal-position gap (the self's `expr_integer_literal`/`expr_float_literal`/
`expr_string_literal`/`expr_bool_literal`/`expr_null_literal`/`expr_format_string`
have no line/column, so a match-arm header or `RangeExpr` column whose pattern
or bound is a literal cannot match the host) is a parser-wide AST change, not
part of this item unless pursued deliberately.

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

1. **Edit latency: cache loader analyses per module** — **CLOSED (session 29,
   2026-10-04)**: the `ModuleCache` landed as designed (direct-import version
   snapshots, cascade through the dependent closure, plus the open-buffer
   override for imports).  `[LSP perf]` reads **5.0 ms median per edit** on
   `SimpleGame/src/main.mt` (was 54.3), and the dependency-edit probe passes
   where the pre-change binary failed 3 checks.  See §0k's "The per-module
   `ModuleCache`" record; the next open LSP item is the readiness residue's
   per-parse **ownership** residual (C4) — session 37 routed the per-request
   parses through the shared caches (soak 11.4 → 3.96 MB/cycle) and closed the
   soak's addressable half; the remaining ~3.9 MB/cycle is the per-edit
   parse+analysis leak (Track 7's C4).  The canonical-audit residue's four
   references rows are closed (session 36) and its two builtin-hover rows are
   documented/rejected.
2. **`milkTea/debugInfo` remainder** — **CLOSED (session 35, 2026-10-05)**:
   the **Facts** and **Bindings** sections, the cached-AST `SourceFile`
   header/`node_path_ids` residue and the harness's `object_id` normalization
   landed; the whole dump is byte-equal on the fixture and the harness's fifth
   documented entry is gone (4 remain).  See §0k's session-35 record; the
   residue it lists (generic instances/foreign aliases, member-access callable
   sites, literal positions) is not fixture-visible.
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
5. **Feature-audit leftovers — CLOSED (session 28, 2026-10-03)**: each item was
   verified against the host first and then fixed or classified —
   `prepareCallHierarchy` answers the host's always-kind-12 null-receiver item
   (null on an imported callee *on both servers*), `linkedEditingRange` applies
   the host's local-binding gate (null for types/functions and empty ranges),
   `typeDefinition` on a function already resolved, `inlayHint` gained the
   receiver-aware callee resolution (the mislabelled `text:` case is gone), and
   `executeCommand` now answers `null` for an unknown command.  Records: §0k's
   "Stage-14 leftovers" (session 28); the harness locks each with an entry.
6. **`dead-assignment` policy** — **CLOSED (session 9)**: the rule now matches the
   host (`linter/cfg.mt` skips declaration-origin writes and never-read bindings,
   and the warning carries the host's message and `warning` severity); the one
   structural difference left is that the liveness walk keys on *names* where the
   host keys on binding ids, which can only show in shadowed-name cases.
7. **Compiler-side work** is §0j (`lower` dump parity 39/622 of 712 files,
   CLI message parity, `deps`/`--bundle`/`--jobs`/Wasm); the example and `test/mt` build failures it
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
| 15 | **Proc representation** (host `Types::Proc` + `__proc_N__env` vs self `Types::Struct mt_proc_T`) | `language_baseline`'s first difference after item 5 | §0i roadmap item 2 — **DONE** (the ranked Track 3 item 8, stages A–D across session 44 batches 19–21: the `Types::Proc` value type, the host's `mt_proc_proc_*` names and declarator names, the inline literal setup with `__mt_proc_expr_N`, and the retain/release lifecycle; all sync proc probes byte-identical).  Residues: the lazy-region `__setup_env` fallback, generic-instance field substitution in `contains_proc_storage_type`, the proc-counter numbering |

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

# --host-cache reuses the host's outputs (session 42): lex/parse per file
# digest, lower per (file, resolved import closure) digest; the self always
# runs live, so every counter still measures it.  Warm ~1 min, cold ~4 min.
ruby tools/sexpr_parity.rb lex   -q --host-cache tmp/sexpr-host-cache   # repo-wide, ~1s warm
ruby tools/sexpr_parity.rb parse -q --host-cache tmp/sexpr-host-cache   # repo-wide, ~1s warm
ruby tools/sexpr_parity.rb lower -q --host-cache tmp/sexpr-host-cache   # ~1min warm / ~3min cold
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
