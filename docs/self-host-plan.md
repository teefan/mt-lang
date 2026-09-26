# Self-Host Plan

> **Starting a session?** Read **"How to start a work session"** below (phase
> order, per-workstream entry points and gates), then **§0k** for the active LSP-
> parity phase (live counters, the remaining entries, and the **stage 5/6
> capsules** — `milkTea/debugInfo`, then formatting/tidy — with opening files,
> host references and budgets) and **§0j** for the compiler-side remaining work
> (`lower`, builds, CLI).

> **Workstream status (self-host vs `projects/stress`)**: **DONE** — the
> self-host compiler builds, links and runs `projects/stress` with output and
> exit status identical to the Ruby host's build (exit 242, empty stdout).  The
> root causes fixed on the way (task-root proc bridge, proc bodies inside async
> functions, builtin vector constructors, format-string locals, `inline for`
> reflection) plus reproduction and verification steps are recorded in
> [self-host-stress-todo.md](./self-host-stress-todo.md).

Status: **SELF-HOSTING FIXED POINT ACHIEVED. LSP + DAP + BINDGEN + IMPORTED-BINDINGS COMPLETE.**
Stage2 == stage3 byte-identical; `tools/bootstrap.sh` self-test: **506 tests
across 14 files, 511 tests, 0 failed** (measured 2026-09-26).
**Linter parity: 14/16 common rules byte-identical with Ruby on language_baseline.mt.**
**Raylib parity: 217/219 build and run** (2026-07-16 sweep).
**Language examples: 11/15 build under `--no-cache`** (measured 2026-09-25:
`async_network_lobby`, `async_stress_test`, `data_structures`,
`nullable_and_variant_test` fail on the self-host while the host builds all
four — see §0j); every example that builds also matches the host's
stdout+exit (sampled: `integration_test`, `reflection_advanced`,
`language_baseline`, `event_stress_test`). **The vendored example families now
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

**DAP: 7 modules, ~1,050 lines, 25 handler methods dispatched.**
**LSP: 37 modules, ~14.4k lines, 29 capabilities advertised, capability-parity with Ruby; feature parity measured at 1/53 harness requests and 2/15 stress probes still differing — 3 entries (§0k), plus a cross-file reference-scoping gap the corpus does not cover yet.  All 30 capability keys match, both semantic-token comparisons are byte-equal, and a real VS Code session runs clean (the 2026-09-26 `codeLens/resolve` double free is fixed, and the harness now drives the resolve endpoints a real client sends).**
**Formatting: the CST-backed `:tidy` / `:preserve` modes are self-hosted and byte-identical to the host across the repository (`tools/format_parity.rb`: 702/702 both modes); the LSP's `formatting` and `rangeFormatting` entries are closed, and the canonical AST printer still drops comments (host reattaches trivia).**
**Hover: 18/25 declaration types covered (up from 5/25).**
**LSP stability: zero SIGSEGV/SIGABRT crashes; UTF-8 boundary auto-adjust; parser/lexer recoverable.**
**LSP logging: structured stderr, version+revision announcement, blank-line filtering.**
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

**`--sexpr` parity (measured 2026-09-26 over 702 files): lex 700/700 comparable
byte-identical (1 host-side rejection); parse 696 comparable files byte-identical
with 0 differences (5 host-side rejections: external files, platform-pinned); `lower` 38 match /
604 differ / 52 host-rejected / 0 self-rejected.**  The ref/lifetime and dyn
vtable categories are closed, and so are the three levers §0j ranked first —
**raw-module method linkage naming**, **unsigned literals in the unsigned
domain** (`18446744073709551615`, provenance-tracked so `~0` still prints `-1`)
and **`:path` attribution for statements lowered from AST nodes** (a 19-file
sample went from 138 pathless `return` statements to 0, matching the host), and
**floating-point literals are emitted the way the host spells them**
(`0.2f`, not `0.20000000000000001`; shortest round-trip form plus the `f` suffix
for `float` literals).
**Same-module foreign calls returning a nominal type** no longer lower to
`Types::Error`.  The remaining `lower` deltas start 30–40 KB into the dumps for
those families; they are dominated by opaque declarations (the sdl3 family's
first difference *and* its build failure), zero-valued aggregate field types,
`null` contextual typing, event-field modelling and generic-specialization
parameter types (§0j).

Last updated: 2026-09-26 (LSP parity stage 5: the formatting family — trivia-aware
lexing, the CST reconstruct, the tidy wrap + blank-line pipeline, and the LSP mode
dispatch — leaves the harness at 3 differing entries, and `tools/format_parity.rb`
measures tidy 702/702 and preserve 702/702 byte-identical; catalogue and working
order in §0k; `lower`/CLI remaining work unchanged in §0j)

---

## How to start a work session (read this first)

Entry point for any self-host work: **this file's §0j** (current state, measured
gates, and the ranked remaining-work table with an approach per item), then the
workstream doc for the area you are touching:

| Workstream | Read | Verify with |
| --- | --- | --- |
| `lower` dump parity | §0j "Remaining work" 1–6, §0i roadmap, `docs/language-design.md` for semantics | `ruby tools/sexpr_parity.rb lower -j 16` (~3 min) |
| Hard build failures (`examples/*`, `test/mt`) | §0j item 7 | `build/stage2/mtc test test/mt -I .` and building the four examples |
| CLI behavior parity | §0j item 8, `tools/cli_parity.rb` (`--help`) | `rake "cli:parity"` |
| LSP feature parity (**in progress**, §0k) | §0k's gap list + the stage 6 capsule, `docs/lsp-design.md`, `docs/lsp-performance.md` | `tools/lsp_parity.rb` (`record --server host|self`, `compare`, `--stress`), plus valgrind and the headless-Neovim smoke test for behavior changes |
| Formatter modes (`:tidy`, `:preserve`) | §7, `docs/lsp-design.md` | `ruby tools/format_parity.rb all -j 16` (preserve/tidy must stay 702/702; canonical is the comment-reattachment delta) |
| DAP | `docs/dap-design.md` | `build/stage2/mtc test projects/mtc` covers the compiler, not DAP; drive `mtc dap` by hand (no self-host DAP harness yet) |
| Bootstrap / release | `docs/bootstrap-design.md` | `tools/bootstrap.sh -j 16` |
| In-language test suite | `docs/testing.md` | `build/stage2/mtc test test/mt -I .` |

**Always** finish a change with `tools/bootstrap.sh -j 16` (fixed point +
compiler self-test) plus the sweep that covers the area — several changes that
looked correct at the CLI level broke the compiler's own bootstrap.

### Phase order and current position

1. **`lower` dump parity** — paused: 0 self-rejections, 38/694 byte-identical,
   the remaining categories ranked in §0j.
2. **CLI behavior parity** — 21/61 harness cases match; the 39 differ on message
   text, output channel and argument precedence (§0j item 8).
3. **LSP feature parity** — **the active phase** (2026-09-26): the self-vs-host
   harness (`tools/lsp_parity.rb`) measures 330/30 capability keys, 1 of 53 request
   entries and 2 of 15 stress probes differing (3 entries), and 0 semantic-token
   comparisons; the remaining families and the working order are in §0k.  Stages 1
   (seven isolated entries), 2 (completion), 3 (documentSymbol), 4
   (diagnostics + semantic tokens), 5 (formatting/tidy — plus the
   `tools/format_parity.rb` mode sweep), 5b (the VS Code startup crash and the
   resolve endpoints the harness was missing) and 6 (`codeLens/resolve`) are
   closed.  The self-host survives the whole stress corpus without a crash or
   hang, and a real VS Code session runs clean under valgrind.
4. **DAP** — phase 1 (process backend, 25 handlers) delivered; the lldb-dap
   bridge was assessed as not feasible without multi-threaded I/O
   (`dap-design.md`).

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
  `initialize.rootUri`, and drives a 53-request corpus covering every endpoint
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
   **53 requests + 15 probes** — `willSaveWaitUntil`, `codeLens/resolve`,
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
is clean; the harness records 53 + 15 with no crash and no timeouts.

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

Harness: a std-generic fixture (`containers.mt`) locks the outline details and
the diagnostics on std-generic code — **53 requests + 15 probes**, still 3
differing entries, 0 crashes, 0 timeouts.

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

### Remaining LSP gaps (all reproducible with the harness)

Re-measured 2026-09-26 after stage 6c (53 requests): **3 differing entries** — 1 of 53 requests,
2 of 15 probes, 0 semantic-token comparisons — plus one gap the corpus does not
cover yet (row 2).

| # | Family | Entries | Evidence / target |
| --- | --- | --- | --- |
| 1 | **`milkTea/debugInfo`** | `milkTea/debugInfo` | host renders `{text}` with Header/Tokens/AST/Parse Errors/Facts/Bindings/Diagnostics (`tooling/debug_info_formatter.rb`, 454 lines); self renders its own workspace summary as `{formatted,content}`.  **Measured 2026-09-26**: the host text embeds Ruby `object_id`s (`obj 992 → binding_id: 3`), binding ids in host allocation order, `ValueBinding[id: N]` reprs, Ruby AST class/member names and `node_ids: {123 entries}` counts, so literal byte-parity needs (a) harness normalization for the object ids, (b) a binding-id model in the self analyzer and (c) a Ruby-AST-shaped tree/facts renderer — re-scope its acceptance before starting it |
| 2 | **Cross-file reference scoping** | `references/imported-decl` matches; the same-file case is not corpus-covered | the host scopes cross-file references to files that **import the declaration's module** (`reverse_import_dependents_for`), while the self-host walks every workspace-index entry named `name`.  The corpus's cross-file entry (references at an imported function's declaration) agrees — both return just the declaration — but a hand probe (2026-09-26) shows the difference where an unrelated file in the `std/` ancestor tree declares the same name: `references` at `sum`'s declaration in the fixture returned 4 locations (Two from that file) where the host returns 2.  The code-lens count now uses the host's same-file rule, so it no longer over-counts; the references walk itself still can.  Approach: restrict the cross-file candidate set to import dependents (see stage 7 in "Where the next session starts") |
| 3 | **Parser recovery on broken input** | `stress/unterminated-source+diagnostic` | the host's recovering parser reports 5 items for the probe buffer (2 `lex/error`, 3 `parse/error`); the self reports 13 (its own messages, plus sema/lint items the host does not produce).  Matching needs the host's parser behaviour, not an LSP change: `consume_name` clearing a keyword-name error to `keyword 'X' cannot be used as <role>` (`parser.rb:230-242`), `parse_param` recording that error *and continuing* so `consume(:rparen, "expected ')' after parameters")` fires at the previous token (`types.rb:18-36`), one error per function with a skeleton AST (`declarations.rb:647-658`), and a top-level `expected declaration` that ends the parse (`declarations.rb:115`) |
| 4 | **Host facts lag** | `stress/unicode+semanticTokens` | 2 modifier bits: the host omits `readonly` on two `let`-local references when tokens are requested right after a content change — its facts for the new content are not recomputed yet.  Verified: the same document served 2 s after `didOpen` gets `readonly` (and a freshly-opened document does too), so this is a host timing artifact, not a classification rule; the self computes facts synchronously |
| 5 | **Generic function-call inference** | not corpus-covered (found 2026-09-26 by diffing `examples/data_structures.mt`'s outline) | the 9 remaining local details there: `iter.iter_filter(vec_iter, is_even)` shows `Iter[T]` where the host infers `Iter[int]`, `paths.path_to(4)` shows `<error>` instead of `Vec[ptr_uint]`, `b.test(3)` instead of `bool`.  A *free* generic call must infer its type arguments from the argument types (`T` from an `Iter[int]` argument) and substitute them into the signature; stage 6c's instantiated-receiver path covers the receiver forms.  Approach: build the substitution from the callee's declared type params and the argument types in the analyzer's `check_call`, then reuse `substitute_type` at the same call sites 6c wired |
| 6 | **`prefer-let` misses editable-method mutation** | not corpus-covered (found by the stage-6c fixture) | `var v = vec.Vec[int].create()` + `v.push(1)` is correct code (the analyzer itself reports `cannot call editable method push on an immutable receiver` for the `let` form), so the host's `prefer-let` stays quiet — the self-host's linter flags it, because it does not track editable calls.  §5.3c item 1's plan (an editable-receiver set recorded during analysis, queried by the scope-tracking pass) is the fix.  The self-host-only `dead-assignment` rule also adds items where it fires — a deliberate value-add, kept |

### Where the next session starts (LSP parity)

Read this order: this §0k → `docs/lsp-design.md` (architecture; its banner points
back here for status) → `tools/lsp_parity.rb` (the gate).  Rebuild before
measuring — the harness silently uses a stale `build/stage2/mtc`:

```sh
ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o build/stage2/mtc
ruby tools/lsp_parity.rb record --server host --out tmp/lsp-host.json --stress
ruby tools/lsp_parity.rb record --server self --out tmp/lsp-self.json --stress
ruby tools/lsp_parity.rb compare tmp/lsp-host.json tmp/lsp-self.json --full
tools/bootstrap.sh -j 16          # fixed point + tests, before every commit
```

Stages 1–6 are closed (seven isolated entries; completion; documentSymbol;
diagnostics + semantic tokens; formatting/tidy — which also delivered the CST
that §7's formatter modes and the linter's wrap fix need, plus the
`tools/format_parity.rb` mode sweep; stage 5b, the VS Code startup crash plus
the resolve-endpoint coverage the harness was missing; and stage 6, the
`codeLens/resolve` count).  **Two LSP items remain**, one of which needs its
acceptance re-scoped before work starts.

**Stage 7 — cross-file reference scoping** (not corpus-covered yet; see the
table row 2)
- self: `navigation.build_references_json_cross_file` walks every
  workspace-index entry named `name`, so a name that also appears in the `std/`
  ancestor tree pulls in unrelated files (the probe below), and
  `count_declaration_references` (the code-lens count) omits the host's
  cross-file term entirely.
- host: same-file, binding-aware locations plus `find_all_references_in(name,
  reverse_import_dependents_for(facts.module_name))` — i.e. only files that
  import the declaration's module.
- work: infer the declaration's module name (`resolver.infer_module_name`),
  collect the files under the client root plus the open documents that import
  it (a lex-level `import <module>` scan), and use that candidate set in both
  `build_references_json_cross_file` and the lens count.  Add a corpus entry
  (`references` at an imported function's declaration in `mod_alpha`) so the
  gate covers it.  Budget ≈120–200 MT lines.

**Stage 8 — `milkTea/debugInfo`** (1 entry; counters 3 → 2)
- self: `lsp/debug_info.mt` (73 lines: `build_debug_text` 11–46,
  `handle_debug_info` 49–62) + dispatch at `lsp/server.mt:250-251`; it currently
  returns its own workspace summary as `{formatted, content}`.
- host: `tooling/debug_info_formatter.rb` (454 lines) renders `{text}` with seven
  sections — Header 24–30, Tokens 32–77 (per-token kind/lexeme/line/column plus a
  semantic-token column), AST 79–272 (tree walker with compact single-line reprs),
  Parse Errors 274–286, Facts 288–390 (`types`/`functions`/`values`/`methods`/
  `imports` + `local_completion_frames`, callable-value site maps,
  `required_unsafe_lines`), Bindings 392–424, Diagnostics 426–454.  The envelope
  itself changes: `{text: …}`, not `{formatted, content}`.
- **Measured 2026-09-26** against the live recording: the text is host-internal
  throughout — `obj 992 → binding_id: 3` are Ruby `object_id`s (not
  reproducible), `ValueBinding[id: N]`/`binding_id: N` come from the host's
  binding-id counter in its name-resolution order, the AST section prints Ruby
  AST class/member names and `node_ids: {123 entries}`, and the Facts section
  prints host `Type#to_s` reprs and analyzer counters (`local_completion_frames:
  4`).  Literal byte-parity therefore needs (a) a harness normalizer for the
  object ids, (b) the binding-id model in `semantic/analyzer.mt` (scope frames
  carrying ids; `identifier_binding_ids`/`declaration_binding_ids`/
  `binding_types` keyed by `reinterpret[ptr_uint]`; allocated in the host's
  order) and (c) a Ruby-AST-shaped renderer over the self-host's variant AST.
  Re-scope the acceptance (normalized comparison, and/or which sections must be
  byte-equal) before starting it — as written ("byte-equal") it is not
  reachable.
- acceptance (proposed): harness `milkTea/debugInfo` equal **after the harness
  normalizes host object ids**; counters move to 2.

**Not stages of their own:**
- `stress/unterminated-source+diagnostic` (parser recovery, row 3) changes
  `mtc check`'s error text too, so it belongs with the CLI-parity work (§0j
  item 10) rather than the LSP rows.
- `stress/unicode+semanticTokens` (host facts lag, row 4) is not actionable on
  the self side.
- Canonical-mode comment reattachment (the 398-file `canonical` delta in
  `tools/format_parity.rb`) is a formatter-completeness item (§7), not an LSP
  entry: the LSP's configured default is `tidy`.

Each phase is done only when its harness entries are byte-equal **and** the global
counters move; the docs in this file and in `lsp-design.md` are synced in the
same commit as the change.  Re-run the §5.9 gate list (bootstrap fixed point +
self-tests, `test/mt`, `cli:parity`, the harness, valgrind on the new paths, and
the headless-Neovim smoke test for behavior changes).

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

### Why the `lower` sweep's "HOST-FAIL" bucket is not a host bug

The sweep reports files the *host* refuses to lower separately instead of
counting them as differences.  Of 56 rejections: 44 are `external` files (raw C
bindings such as `std/c/*.mt` — no IR exists to dump), 4 are platform-pinned
(`*.wasm.mt`, `*.windows.mt`), 4 were our own unparseable test files (fixed
above), 1 is a compile-fail fixture (`test/examples/compile_fail/*`), and 3 are
genuine host-side bugs/limitations: a `double` literal rejected where a `float`
is expected (`examples/raylib/core/custom_frame_control.mt`), an inline foreign
call that needs temporary text storage (`unicode_emojis.mt`), and an unsupported
foreign boundary mapping `ptr[Color] as const_ptr[void]`
(`image_processing.mt`).  The last three belong to the §5.2 family and are
independent of the self-host work.

### Remaining work (planned for the next session)

There are **no self-rejections left**: the self-host analyzes and lowers all 694
corpus files the host can.  What remains is *dump fidelity* (604 files differ
somewhere) plus the hard build failures in four top-level examples and seven
`test/mt` files.  Ranking after the third pass (items 18–19 closed the former
#1 and #2); 1–3 below are the categories the current first differences are
dominated by, and 1 is the only item that also fixes hard build failures:

| # | Item | Evidence | Approach |
| --- | --- | --- | --- |
| 1 | **Opaque declarations** (`IR::OpaqueDecl`) | the first difference for the whole `examples/sdl3` family *and* its build failure: host `(IR::OpaqueDecl :name "Window" :linkage_name "SDL_Window" :forward_declarable true :source_module "std.sdl3")` vs self `(:name "std_sdl3_Window" :forward_declarable false)`; the emitted C is `typedef struct SDL_Window SDL_Window;` vs `typedef SDL_Window std_sdl3_Window;`, which leaves `SDL_Window` incomplete and fails the build | a re-exported opaque keeps its *declared* name and forwards `typedef struct <c_name> <name>;`; mirror the host's `OpaqueDecl` naming/`forward_declarable` (roadmap #6, now ranked first because it gates a whole family's builds) |
| 2 | **Zero-valued aggregate fields typed by field type** | `box3d/ragdoll`'s first difference: host `(IR::AggregateField :name "metric" :value (IR::FloatLiteral :value 0.0 :type (Types::Primitive :name "float")))` vs self `(IR::IntegerLiteral :value 0 :type (Types::Primitive :name "int"))` | an omitted/zeroed field must take the *field's* type and literal kind (float field → `0.0` float); the self-host emits an untyped int 0 |
| 3 | **`null` literal contextual typing** | `data_structures` / `reflection_advanced`'s first difference: host `(IR::NullLiteral :type (Types::Nullable :base (Types::Generic :name "ptr" :arguments ((Types::Primitive :name "ubyte")))))` vs self `(IR::NullLiteral :type (Types::Primitive :name "void"))` | a `null` in a typed position takes the expected nullable pointer type, as the host's `infer_null_literal_type` does; the existing `null_literal_to_context_type` helper covers only part of the sites (comparisons here) |
| 4 | **Event fields in event-carrying structs** | `event_stress_test`'s first difference: host `(IR::Field :name "__event_closed" :type (Types::Event :name "closed" :capacity 4 …))` vs self `(IR::Field :name "closed" :type (Types::Struct :name "mt_event_…_closed_4"))` | the event runtime models each `event` field as `__event_<name>` typed `Types::Event`; the self-host emits the listener-slot struct under the bare name.  Mirror the host's field naming/type in the event-declaration lowering |
| 5 | **Generic-specialization parameter types** | `language_baseline`'s first difference: host `(Types::Parameter :name "x" :type (Types::Primitive :name "int"))` vs self `(Types::Struct :name "T" :module_name "")` | a specialization's parameter types must be substituted like its body/locals; same family as the 7 `test/mt` build failures (item 9).  Check `lower_specialized_function`'s param path for `type_substitution` |
| 6 | **Function-type names** (`Types::Function :name ""`) | visible in the sdl3 dumps right after item 1's first difference: host `:name "run_app_no_args_uninitialized"` vs self `:name ""` | the function *type* of a function reference carries the callee's name in the host; thread it through the analyzer/lowering type construction |
| 7 | **Include set** (`math_bindgen.h` vs `raymath.h`, box2d/drop.mt) | the first difference for `examples/box2d` | the binding's include directives must match the host's registry (std.math → raymath) |
| 8 | **Struct/declaration ordering**, **const-folding shape**, **enum-member const folding**, **variant-match goto** | `ClockSync` vs `std_net_recv_impl_frame`; `IR::IntegerLiteral` vs `IR::Cast` (`errno_test.mt`); 4 / 1 files | mirror the host's decl ordering in the C backend's sort; fold `T<-literal` casts in constant position; roadmap #7/#13 |
| 9 | **Four example build failures** (`async_network_lobby`, `async_stress_test`, `data_structures`, `nullable_and_variant_test`) and the 7 `test/mt` build failures | verified failing with the pre-change compiler too | two are `field 'local_*' has incomplete type` — a value-optional/RESULT frame field is emitted before the struct it embeds; one is `unknown type name 'mt_span_error'` (a `span` of the permissive error type reaching C — the analyzer should reject or type it concretely); one is a recursive variant payload mismatch (`incompatible type for argument 1 of eval_expr`); the `test/mt` seven are all the generic-instance naming/typing family (`std_goap_find_node_index__error__error__error`, `std_blackboard_find_entry__error` given a `Blackboard_bool *`, `Tree[<runner>Context]`) — item 5 above is likely the same root cause |
| 10 | **CLI message parity** | `rake "cli:parity"` 39/61 differ, set unchanged all session | message text, stdout-vs-stderr channel and argument-precedence differences (e.g. `std show` prints to stdout instead of stderr; `build --bogus` reports "accepts a single source path" instead of "unknown build option") |
| 11 | **Host-side bugs (report, not fix here)** | 3 files | `double` literal rejected where `float` is expected (`custom_frame_control.mt`), inline foreign call needing temporary storage (`unicode_emojis.mt`), unsupported foreign boundary mapping (`image_processing.mt`); plus the `inline for` const-folding quirk noted in the stress doc |
| 12 | **Const functions returning alias-qualified aggregates** (2026-09-26, found building `MilkTea/SimpleGame`) | `public const MIDNIGHT: rl.Color = rl.Color.from_hex_str("#10121c")` | host folds to `{ .r = 16, .g = 18, .b = 28, .a = 255 }`; self emits the call, so the C compiler rejects the non-constant initializer (`initializer element is not constant`).  The const evaluator is reached for scalar-returning const methods and for `alias.Type.method(...)` (fixed 2026-09-26), but the aggregate path needs the **type-alias chain**: `rl.Color` is `public type Color = c.Color` in `std.raylib`, so `struct_exists_in_imports("Color")` is false in `try_const_call_ir`, and `try_const_struct_literal_ir` would also need the field types and the named type from the alias's owner module (the same alias routing `lower_call` and `find_struct_field_type` already do at runtime).  Reproduce with the probe in the stage-5c notes (`rl.Color.literal()` — a const method returning `rl.Color(r = 1, …)`)|

### `lower` differences, by first difference (after items 18–19)

| Files (sampled) | First difference |
| --- | --- |
| 34 (`examples/sdl3/**`) | opaque declaration naming/`forward_declarable` (was the unsigned literal, then the function-type name) — item 1 |
| 2 (`box3d/ragdoll`, `box3d/box_stack`) | zero-valued aggregate field typed `int 0` instead of the field's `float 0.0` — item 2 |
| 2+ (`data_structures`, `reflection_advanced`) | `null` literal typed `void` instead of the expected nullable pointer — item 3 |
| 1 (`event_stress_test`) | event field naming/type (`__event_closed` typed `Types::Event`) — item 4 |
| 1 (`language_baseline`) | generic-specialization parameter type not substituted (`T` instead of `int`) — item 5 |
| 1 (`box2d/drop`) | include set (`math_bindgen.h` vs `raymath.h`) — item 7 |
| remainder | declaration ordering, const-folding shape, enum-member const folding, variant-match goto, plus cases beyond each file's first difference |

Contextual literal typing (the dominant category at the start of the session,
213 files), raw-module linkage naming, unsigned-literal rendering and void-return
`:path` attribution all now match the host; the vendored families' linkage-name
*sets* equal the host's, and a 19-file sample has **0** pathless `return`
statements (host: 0, before: 138) and all 5 huge-literal constants the host
dumps.  The remaining `lower` mismatches start 30–40 KB into the dumps for the
families this session touched (they were at ~1.5–2.3 KB).

### Next, ranked by files moved per unit of work

Item 1 is the only remaining item that fixes *builds* as well as dumps (the
whole sdl3 family), and item 2/3 are each a handful of lines that clear the
first difference of the box3d and data-structures families.  Item 5 is the
lever for the `test/mt` build failures.

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
| ~~Formatter CST modes (`--tidy`, `--preserve`)~~ **DONE (§7, 2026-09-26)** | — |
| Linter wrap-fix machinery (`line-too-long` auto-fix) — pipeline landed (§7.2), wiring left | Small |
| **Added 2026-07-19** | |

---

## 5. Remaining Gaps (2026-07-19, re-measured 2026-09-25 in §0j)

The compiler is at a held fixed point (511 tests across 14 files as of
2026-09-26; 217/219 raylib — the 2 non-builds are correct rejections).
**Corrected 2026-09-25:** the "13/13 language examples" figure below was stale —
the self-host builds **11 of the 15 top-level examples** today (§0j), and four
`test/mt` files had been silently skipped by the test runner, which hid one more
pre-existing build failure.  The LSP is at capability parity with Ruby (29
advertised, all 53 handler methods dispatched).  Remaining gaps are
infrastructure-depth items plus the four example build bugs and the analyzer
false positives listed in §0j:

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

##### 1. `prefer-let` remaining (16→13): sema-side editable receiver + out/inout tracking

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

##### 4. `unused-import` (1→0): extension method import detection

`import std.linear_algebra` provides `vec3.dot()`, `vec3.length()`, etc. as extension methods, but the import name `linear_algebra` is never directly referenced.

**Ruby's approach:** Ruby doesn't flag this import as unused because the extension methods it provides ARE used in the file.

**Self-host changes needed:**
1. **A.** In `check_unused_imports`, when an import has no alias, check if any method call in any function body matches a method from the imported module's extending blocks.
2. **B.** Load the imported module's extending blocks and check their method names against function body method calls.
3. **C.** Simpler alternative: when an import's exported module provides any extending blocks, conservatively treat the import as used.

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

A change is safe only if: stage2.c == stage3.c, **14 test files / 511 tests pass
with 0 failures** (`tools/bootstrap.sh -j 16` reports the count), the language
examples do not regress (live baseline: **11 of 15** build — the four failures and
their causes are §0j item 9), and the raylib passing set does not shrink
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

**Live baseline (2026-09-25, §0j):** lex 694/694; parse 690 comparable files with
0 differences; `lower` 38/694 byte-identical with **0 self-rejections** — the
remaining differences are the mechanical categories ranked in §0j's "Remaining
work" table (raw-module linkage naming, `:path` attribution, declaration
ordering, const-folding shape, include set, opaques/const folding).

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
| `:canonical` | AST pretty-print with trivia reattached | AST pretty-print, **comments dropped** (see 7.3) |
| `:safe` | Same as canonical | Same as canonical |
| `:preserve` | CST-based, keeps original formatting | **DONE** — `formatter/cst.mt` |
| `:tidy` | CST normalize → wrap → blank lines | **DONE** — `formatter/tidy.mt` |

Measured by `tools/format_parity.rb` (host in-process, self per file, `-j`
workers) over the repository's 702 `.mt` files: **preserve 702/702 and tidy
702/702 byte-identical**; canonical 302/702 (the comment-reattachment delta
below).  The LSP's `formatting` + `rangeFormatting` entries are closed by the
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

### 7.3 Remaining

| Gap | Effort | Depends on |
| --- | --- | --- |
| Canonical-mode comment reattachment (host `PrettyPrinter.format_ast(ast, trivia:)`; 398/702 files differ by dropped comments) | Medium | the CST trivia (now available) |
| Linter `line-too-long` wrap-fix (reuse `formatter.tidy.wrap_long_argument_lists` / `build_long_line_wrap_fix`) | Small | landed pipeline |
| Linter `:fast` tier | Small | independent |
| Formatter `--timings` profile phases | Small | independent |
