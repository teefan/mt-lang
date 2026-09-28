# Self-Host Plan

> **Starting a session?** Read **"How to start a work session"** below (phase
> order, per-workstream entry points and gates), then **"First steps for the next
> session (2026-09-27 handoff)"** — the builds are at parity, so what remains is
> `lower` dump fidelity (§0j's ranked table), CLI message parity, and the LSP
> (§0k) / DAP (`dap-design.md` §10) leftovers.

> **Workstream status (self-host vs `projects/stress`)**: **DONE** — the
> self-host compiler builds, links and runs `projects/stress` with output and
> exit status identical to the Ruby host's build (exit 242, empty stdout).  The
> root causes fixed on the way (task-root proc bridge, proc bodies inside async
> functions, builtin vector constructors, format-string locals, `inline for`
> reflection) plus reproduction and verification steps are recorded in
> [self-host-stress-todo.md](./self-host-stress-todo.md).

Status: **SELF-HOSTING FIXED POINT ACHIEVED. LSP + DAP + BINDGEN + IMPORTED-BINDINGS COMPLETE.**
**A real user project outside the repository builds and runs under the
self-host** (`~/Projects/MilkTea/SimpleGame`, the const-aggregate blocker of
§0j item 12 — fixed in session 2; the binary initializes raylib and audio and
runs).
Stage2 == stage3 byte-identical; `tools/bootstrap.sh` self-test: **516 tests
across 14 files, 0 failed** (measured 2026-09-27 session 2);
the self-host also builds every example and `test/mt` file the host does (see
§0j's 2026-09-27 section).
**Linter parity: 14/16 common rules byte-identical with Ruby on language_baseline.mt.**
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
recipes complete for all 7 libraries (raylib, glfw, tracy, cjson, box2d,
sdl3, flecs, pcre2, steamworks, libuv).  Bindgen self-hosted (687 lines CL
→ MT type mapper + clang JSON AST parser).

**DAP: 7 modules, 1,050 lines, 29 handler methods dispatched.  `tools/dap_smoke.rb`
audits it against the host per request (2026-09-27: capabilities, launch, threads,
stackTrace, scopes, variables, breakpoints and the whole error surface are identical
for the process backend; the remaining gaps — build-on-launch, the lldb-dap bridge,
the debug map — are §10 of `docs/dap-design.md`).**
**LSP: 37 modules, ~14.4k lines, 29 capabilities advertised, capability-parity with Ruby; feature parity measured at **1 of 55 harness requests and 3 of 19 stress probes still differing — 4 entries** (§0k), all documented (debugInfo, host parser recovery, the host hanging on a malformed frame, the host's facts lag).  All 30 capability keys match, both semantic-token comparisons are byte-equal, and a real VS Code session runs clean (the 2026-09-26 `codeLens/resolve` double free is fixed, and the harness now drives the resolve endpoints a real client sends).**
**LSP project audit (new counter, 2026-09-28): `tools/lsp_project_audit.rb --workspace ~/Projects/MilkTea/SimpleGame` — 6456 entries, **1328 differ** at session start (typeDefinition 334, hover 286, references 278, definition/declaration 194 each, documentHighlight 26, documentSymbol 5/7, semanticTokens 5/7, diagnostic 3/7, codeLens 1/7, implementation 1, workspace/symbol 1); after the session-6 hover fixes **hover 286 → 181** (`--only textDocument/hover`), and the probe fixtures `tmp/probe-ws` (0 of 25) and `tmp/probe2` (2 of 41) are at parity.  The hover residue is classified in §0k; the rest is the host's global declaration-index fallback and imported-member navigation.**
**Formatting: the CST-backed `:tidy` / `:preserve` modes are self-hosted and byte-identical to the host across the repository (`tools/format_parity.rb`: 702/702 in **all three modes** — the canonical printer reattaches comments and trivia like the host); the LSP's `formatting` and `rangeFormatting` entries are closed.**
**Hover: 18/25 declaration types covered (up from 5/25).**
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

**Remaining CLI gaps: `deps` and `docs` (absent from the self-host command
list), `--bundle`/`--archive`, `--jobs`, Wasm/emcc.**  `snapshot` and `debug`
are implemented (§5.8a); the formatter CST modes (`--tidy`, `--preserve`) landed
on 2026-09-26 (§7).
`rake "cli:parity"` (measured 2026-09-26) is
**22 match / 39 differ / 0 pending of 61 cases** (the pending case was the
`format` mode-flag case, now matching); the differing cases are
message text/channel/argument-precedence differences, not missing commands
(§0j).  Toolchain doctor is self-hosted; bootstrap/tools subcommands deferred.

**`--sexpr` parity (measured 2026-09-27 session 2 over 702 files): lex 702/702
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

Last updated: 2026-09-27 session 3 (project-audited the LSP against
`~/Projects/MilkTea/SimpleGame` with `tools/lsp_project_audit.rb`: a malformed
`references` frame plus six behavioural gaps — highlight scoping, hover label
paths, import-path navigation, local/parameter resolution, builtin type hovers,
four linter severities — are fixed, and the fixture is at 1 deliberate
difference of 19.  The reported `MilkTea/SimpleGame` builds and runs under the
self-host (§0j items 2, 3, 5, 12 closed, `lower` 39/613/50/0, fixed point with 14
files / 516 tests / 0 failed).  Remaining work: §0j item 1 (opaque declarations,
34 sdl3 files) and items 13–15, CLI message parity, and the LSP/DAP leftovers)

---

## How to start a work session (read this first)

Entry point for any self-host work: **this file's §0j** (current state, measured
gates, and the ranked remaining-work table with an approach per item), then the
workstream doc for the area you are touching:

| Workstream | Read | Verify with |
| --- | --- | --- |
| `lower` dump parity | §0j "Remaining work" (items 1, 4, 6–8, 13–15), §0i roadmap, `docs/language-design.md` for semantics | `ruby tools/sexpr_parity.rb lower -j 16` (~3 min) |
| Example / vendored-family builds (no known failures since 2026-09-27) | §0j's 2026-09-27 section | the 15 top-level examples, `find examples/sdl3 -name '*.mt'`, a raylib sample |
| CLI behavior parity | §0j item 10, `tools/cli_parity.rb` (`--help`) | `rake "cli:parity"` |
| LSP feature parity (**in progress**, §0k) | §0k's gap list + the stage 6 capsule, `docs/lsp-design.md`, `docs/lsp-performance.md` | `tools/lsp_parity.rb` (`record --server host|self`, `compare`, `--stress`), `tools/lsp_project_audit.rb --workspace DIR` (per-file, every position, both servers live), plus valgrind and the headless-Neovim smoke test for behavior changes |
| Formatter modes (`:tidy`, `:preserve`) | §7, `docs/lsp-design.md` | `ruby tools/format_parity.rb all -j 16` (preserve/tidy must stay 702/702; canonical is the comment-reattachment delta) |
| DAP | `docs/dap-design.md` (gaps in §10) | `ruby tools/dap_smoke.rb [--server host\|self\|both] [--json OUT]` — runs a session on both adapters and prints a per-request diff |
| Bootstrap / release | `docs/bootstrap-design.md` | `tools/bootstrap.sh -j 16` |
| In-language test suite | `docs/testing.md` | `build/stage2/mtc test test/mt -I .` |

**Always** finish a change with `tools/bootstrap.sh -j 16` (fixed point +
compiler self-test) plus the sweep that covers the area — several changes that
looked correct at the CLI level broke the compiler's own bootstrap.

One command for every counter: `rake "parity:scoreboard"` (cheap sections:
cli/lex/parse/lint; add `FULL=1` for lower/format/LSP/DAP).  Lint parity has
its own sweep: `ruby tools/unused_import_parity.rb`.

### Phase order and current position

0. **Hard build parity** — **complete (2026-09-27)**: the self-host builds every
   example and test the host builds (15/15 language examples, 34/34 `examples/sdl3`,
   a 40-file raylib sample, `test/mt` 60/60 with 0 failures).  Six root causes are
   recorded in §0j's 2026-09-27 section; regressions should show up as a build
   failure in those sweeps.
1. **`lower` dump parity** — paused: 0 self-rejections, 38/702 byte-identical,
   the remaining categories ranked in §0j.
2. **CLI behavior parity** — 22/61 harness cases match; the 39 differ on message
   text, output channel and argument precedence (§0j item 10).
3. **LSP feature parity** — **the active phase** (2026-09-26): the self-vs-host
   harness (`tools/lsp_parity.rb`) measures 30/30 capability keys, 1 of 55 request
   entries and 3 of 19 stress probes differing (4 entries), and 0 semantic-token
   comparisons; the remaining families and the working order are in §0k.  Stages 1
   (seven isolated entries), 2 (completion), 3 (documentSymbol), 4
   (diagnostics + semantic tokens), 5 (formatting/tidy — plus the
   `tools/format_parity.rb` mode sweep), 5b (the VS Code startup crash and the
   resolve endpoints the harness was missing) and 6 (`codeLens/resolve`) are
   closed.  The self-host survives the whole stress corpus without a crash or
   hang, and a real VS Code session runs clean under valgrind.
4. **DAP** — phase 1 (process backend, 29 handlers) delivered; the lldb-dap
   bridge is now feasible (`std/libuv.mt` poll + `std/async`) but unstarted
   (`dap-design.md` §10).

### First steps for the next session (2026-09-27 session-2 handoff)

Nothing is broken: the builds are at parity and the reported `MilkTea/SimpleGame`
project builds and runs, so every remaining item is a *fidelity* or *breadth*
item, and each one is verified by a counter moving (not by a new passing
program).  Suggested order:

1. **Re-measure before changing anything** (a stale binary is the classic false
   result; note the bootstrap rewrites `version_info.mt` after stage2 is built,
   which makes `sexpr_parity`'s staleness warning fire harmlessly):
   ```sh
   ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o build/stage2/mtc
   ruby tools/sexpr_parity.rb lower -q -j 16      # baseline 39 match / 613 differ / 50 host-rejected / 0 self-rejected
   rake "cli:parity"                              # baseline 22 match / 39 differ / 0 pending
   ```
2. **The biggest single mover** — §0j item 1 (opaque `IR::OpaqueDecl`
   naming/`forward_declarable`: the first difference for all 34 sdl3 files; the
   C backend's opaque typedef emission moves with it).
3. **The two localized next-first-differences** — §0j item 13 (a global
   initialized from an imported constant: `box3d/ragdoll` + `box_stack`) and item
   14 (refined non-null operand types after a null check: `data_structures` +
   `reflection_advanced`).
4. **Then the residue** — items 4, 6, 7, 8 (event fields, function-type names,
   include sets, declaration ordering/const-folding) and item 15 (proc
   representation, §0i item 2 — the largest single item).
5. **CLI message parity** (§0j item 10) and the **LSP leftovers** (§0k: the
   `debugInfo` remainder, parser-recovery parity, the feature-audit items) and
   **DAP** (`dap-design.md` §10) are independent tracks; pick by user value.

Each change still ends with `tools/bootstrap.sh -j 16` (fixed point + compiler
self-test) plus the sweep that covers the area — `sexpr_parity` for lowering,
`rake "cli:parity"` for CLI text, `tools/lsp_parity.rb` for LSP,
`tools/dap_smoke.rb` for DAP.

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

Re-measured 2026-09-26 after stage 6e (55 requests, 19 probes): **4 differing entries** — 1 of 55 requests,
3 of 19 probes, 0 semantic-token comparisons — plus one gap the corpus does not
cover yet (row 2).

| # | Family | Entries | Evidence / target |
| --- | --- | --- | --- |
| 1 | **`milkTea/debugInfo`** | `milkTea/debugInfo` | **Partially ported (stage 6f).** The host's Header, Tokens and Parse Errors sections are implemented: the header, the token histogram and **245 of 246 token rows are byte-identical** on the corpus file (lexeme, kind, location and semantic class columns).  Two known gaps remain, both measured: (a) the histogram's *tie order* — the host's `group_by` + Ruby `sort_by` leaves equal counts in an order only MRI's qsort reproduces (e.g. `2 star, 2 float, …` where first-appearance order gives `2 import, 2 as, …`); the self order is stable and documented rather than emulated.  (b) the host's **AST** (Ruby class names plus `node_ids: {N entries}`), **Facts** (`40 types, 2 functions, 2 method_sets, 1 interfaces, 2 imports`, method sets, owning types) and **Bindings** (`ValueBinding[id: N]`, `obj <object_id> → binding_id: N`) sections are not implemented: they render the host implementation's own data structures, so matching them byte-for-byte needs a Ruby-AST-shaped renderer, a binding-id model and harness normalization for the object ids.  The self adds a `Workspace` section the host has no equivalent for. |
| 2 | **Malformed frame: the host hangs** | `stress/malformed-frame+parseError` | a JSON-RPC frame whose body is not JSON (or carries a bogus `Content-Length`) leaves the Ruby host blocked — it never answers that frame (the probe times out) and only resumes on the next one.  The self answers `-32700` with a null id and keeps serving.  This entry differs by design and is a self-host improvement; it also locks the crash it used to cause (a malformed frame used to be treated as EOF and shut the server down) |
| 3 | **Parser recovery on broken input** | `stress/unterminated-source+diagnostic` | the host's recovering parser reports 5 items for the probe buffer (2 `lex/error`, 3 `parse/error`); the self reports 13 (its own messages, plus sema/lint items the host does not produce).  Matching needs the host's parser behaviour, not an LSP change: `consume_name` clearing a keyword-name error to `keyword 'X' cannot be used as <role>` (`parser.rb:230-242`), `parse_param` recording that error *and continuing* so `consume(:rparen, "expected ')' after parameters")` fires at the previous token (`types.rb:18-36`), one error per function with a skeleton AST (`declarations.rb:647-658`), and a top-level `expected declaration` that ends the parse (`declarations.rb:115`) |
| 4 | **Host facts lag** | `stress/unicode+semanticTokens` | 2 modifier bits: the host omits `readonly` on two `let`-local references when tokens are requested right after a content change — its facts for the new content are not recomputed yet.  Verified: the same document served 2 s after `didOpen` gets `readonly` (and a freshly-opened document does too), so this is a host timing artifact, not a classification rule; the self computes facts synchronously |

### Where the next session starts

Read this order: this §0k → `docs/lsp-design.md` (LSP architecture) →
`docs/dap-design.md` §10 (DAP gaps) → the gates below.  Rebuild before measuring
— every harness silently uses a stale `build/stage2/mtc`:

```sh
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o build/stage2/mtc
ruby tools/lsp_parity.rb record --server host --out tmp/lsp-host.json --stress
ruby tools/lsp_parity.rb record --server self --out tmp/lsp-self.json --stress
ruby tools/lsp_parity.rb compare tmp/lsp-host.json tmp/lsp-self.json --full
ruby tools/dap_smoke.rb --json tmp/dap.json        # DAP: per-request host/self diff
tools/bootstrap.sh -j 16                            # fixed point + tests, before every commit
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
3. **Parser recovery parity** (row 3): our lexer/parser recover (outline,
   tokens and sema keep working, and lex/parse errors are reported), but the
   error *set* on broken input differs from the host's.  The host behaviours to
   port are listed in the row: `consume_name` keyword-name errors, `parse_param`
   continuing so `expected ')'` fires, one error per function with a skeleton
   AST, and a top-level `expected declaration` that ends the parse.  This also
   changes `mtc check` text, so it belongs with the CLI-parity work (§0j).
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
6. **`dead-assignment` policy** (still open from earlier sessions): it is a
   self-host-only rule, so files where it fires differ from the host by design.
   Either keep it (documented value-add) or gate it behind a config flag so the
   editor matches the host exactly.
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
   verification live in [self-host-stress-todo.md](./self-host-stress-todo.md).
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

### Remaining work (planned for the next session)

There are **no self-rejections left**: the self-host analyzes and lowers every
corpus file the host can.  What remains is *dump fidelity*; **all hard build
failures are closed** (2026-09-27: 15/15 language examples, 34/34 sdl3 files,
60/60 `test/mt`, and the reported `MilkTea/SimpleGame` project).  Ranking after
the fourth pass (the second 2026-09-27 session closed items 2, 3, 5 and 12 —
see "2026-09-27 session 2" below); item 1 plus the three items it uncovered
(13–15) are the categories the current first differences are dominated by:

| # | Item | Evidence | Approach |
| --- | --- | --- | --- |
| 1 | **Opaque declarations** (`IR::OpaqueDecl`) — *dump difference only; the builds are FIXED (2026-09-27)* | the first difference for the whole `examples/sdl3` family: host `(IR::OpaqueDecl :name "Window" :linkage_name "SDL_Window" :forward_declarable true :source_module "std.sdl3")` vs self `(:name "std_sdl3_Window" :forward_declarable false)`.  The family's *build* failure had a different root cause (opaque values emitted as values, plus missing SDL3 private link flags) and is fixed — all 34 sdl3 files build | a re-exported opaque keeps its *declared* name and forwards `typedef struct <c_name> <name>;`; mirror the host's `OpaqueDecl` naming/`forward_declarable` (roadmap #6).  `collect_opaque_decls` builds the entry; the C backend's opaque typedef emission must move with it |
| 2 | ~~**Zero-valued aggregate fields typed by field type**~~ **FIXED (2026-09-27 session 2)** | `box3d/ragdoll`'s first difference was host `(IR::AggregateField :name "metric" :value (IR::FloatLiteral :value 0.0 :type (Types::Primitive :name "float")))` vs self `(IR::IntegerLiteral :value 0 :type (Types::Primitive :name "int"))` | `const_value_to_field_type` re-types every folded field value by the *field's* type (the host's `lower_compile_time_literal`), recursing into `array[T, N]` elements, and the runtime `array`/`simd` constructors type their elements contextually.  The family's first difference moved from ~15.5 KB to ~50 KB into the dump (now item 13) |
| 3 | ~~**`null` literal contextual typing**~~ **FIXED (2026-09-27 session 2)** | `data_structures` / `reflection_advanced`'s first difference was host `(IR::NullLiteral :type (Types::Nullable :base (Types::Generic :name "ptr" …)))` vs self `(IR::NullLiteral :type (Types::Primitive :name "void"))` | comparisons now re-type a bare `null` operand from the other side (the host propagates the left operand's type to the right), and the runtime path gives a typed `null[T]` its `Types::Null :target_type T`.  **Documented divergence:** the host types a *left-hand* bare null (`null == x`) as `bool` — an artifact of a later inference pass recording the comparison's expected type on the literal node; the self-host types it from the other operand.  No corpus file has that shape (`tmp/probes/reversed_null.mt` is the only probe).  Both files' first differences moved deeper (now item 14) |
| 4 | **Event fields in event-carrying structs** | `event_stress_test`'s first difference: host `(IR::Field :name "__event_closed" :type (Types::Event :name "closed" :capacity 4 …))` vs self `(IR::Field :name "closed" :type (Types::Struct :name "mt_event_…_closed_4"))` | the event runtime models each `event` field as `__event_<name>` typed `Types::Event`; the self-host emits the listener-slot struct under the bare name.  Mirror the host's field naming/type in the event-declaration lowering |
| 5 | ~~**Generic-specialization parameter types**~~ **FIXED (2026-09-27 session 2)** | `language_baseline`'s first difference was `(Types::Parameter :name "x" :type (Types::Struct :name "T" :module_name ""))` where the host has `int` | `gen_dyn_vtable_constant` now substitutes the interface's type parameters like the vtable struct and the wrapper functions already do (the const is a `DynVtable`'s method slot).  `language_baseline`'s first difference moved past it (now the proc-representation gap, §0i item 2) |
| 6 | **Function-type names** (`Types::Function :name ""`) | visible in the sdl3 dumps right after item 1's first difference: host `:name "run_app_no_args_uninitialized"` vs self `:name ""` | the function *type* of a function reference carries the callee's name in the host; thread it through the analyzer/lowering type construction |
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

### Next, ranked by files moved per unit of work

No build blockers remain (2026-09-27), so the remaining items move *dumps* only —
except item 1, which also unblocks the sdl3 family's C-side naming.  Item 1
(opaque `IR::OpaqueDecl` naming/`forward_declarable`) is the single biggest
mover (34 files) and the first difference for that whole family; item 13 (a
global initialized from an imported constant) and item 14 (refined nullable
operands) are the box3d and data-structures families' next first differences and
are each localized; then item 4 (event fields), items 6–8 (function-type names,
include sets, declaration ordering) and item 15 (proc representation, the
largest single item).  CLI message parity (item 10) and the LSP/DAP leftovers
(§0k, `dap-design.md` §10) are independent tracks.

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

The compiler is at a held fixed point (516 tests across 14 files as of
2026-09-27; 217/219 raylib — the 2 non-builds are correct rejections).
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

A change is safe only if: stage2.c == stage3.c, **14 test files / 516 tests pass
with 0 failures** (`tools/bootstrap.sh -j 16` reports the count), the language
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
