# LSP Enhancement Plan

Status: **audit complete (session 144); phase 0 conformance harness landed (session 145);
implementation phases 1–4 not started.**
Baseline: **LSP 3.18.0** (2026-06-04); 3.19 is upcoming.
Implementation: `projects/mtc/src/mtc/lsp` — 43 `.mt` files, ~31.9k lines,
entry point `mtc lsp` (`projects/mtc/src/mtc/lsp/server.mt`).
Audit method: 3.18 meta-model diff, targeted code review, and live probes
against `build/stage2/mtc` (0.4.26, release) on 2026-11-21.

This is the plan of record for LSP work.  `docs/self-host-plan.md` remains the
project ledger; this document carries the LSP-specific state, findings and
phase gates.  The audit was targeted, not a line-by-line review of all 31.9k
lines: **the conformance harness (`tools/lsp_conformance.rb`) is the authority.**

## 1. Current state

The native server is single-threaded, stdio/JSON-RPC, with per-document text
and analysis caches.  It is self-only since the host retirement (session 143):
the archived Ruby host is at `archive/host-ruby-0.4.26` and must not be used as
an oracle.  The existing instruments are:

- `tools/lsp_parity.rb record --server self --out FILE [--stress]` /
  `compare` — corpus recording, no host.
- `tools/lsp_soak.rb --quiet` — RSS slope (session-143: 73.8 KB/cycle raw /
  19.0 LS at 200 cycles; raw in the 70–80 band).
- `tools/gates.sh --areas lsp --only valgrind_lsp,soak --run` — valgrind
  (`0 errors` in session 143) and soak.
- `projects/mtc/test/{completion,cursor,lsp_index,lsp_utils}_test.mt` — unit
  coverage for helpers, not protocol conformance.
- `tools/lsp_conformance.rb` — the spec oracle (phase 0, session 145): 26 cases
  from §5 with explicit assertions, a standalone stdio client, `--bin`,
  `--only`, `--timeout` and `--json`.  It is the `lsp_conformance` hard tier-2
  gate; at the phase-0 commit it is **red by design** (3 pass / 23 fail) and is
  the stopping rule for phases 1–4.  `--bin` accepts a wrapper, so the same
  cases can be driven under valgrind; the existing `valgrind_lsp` corpus drive
  remains the memory instrument because 26 cold valgrind server startups are
  not a better use of tier-2 time.

`tools/lsp_parity.rb` remains host-parity-shaped: it sends
`workspace/willRenameFiles` as a **notification**
(`tools/lsp_parity.rb:1116`) and its fixtures are ASCII.  The conformance
harness covers both blind spots; keep the parity corpus for endpoint coverage,
not conformance.

## 2. Spec coverage

Against the 3.18 meta-model (69 requests, 26 notifications):

| Bucket | Count |
|---|---|
| Client→server requests | 54 |
| Dispatched by `server.mt` | 42 |
| Capability keys advertised | 30 (of 36 top-level `ServerCapabilities` fields) |
| Client→server notifications handled | 10 of 19 |

Supported areas: definition/declaration/typeDefinition/implementation,
references, document highlight, hover, completion + resolve, signature help,
document/workspace symbols, rename + prepareRename, code actions, code lens +
resolve, document links + resolve, formatting/rangeFormatting/onTypeFormatting/
willSaveWaitUntil, folding range, selection range, linked editing, inlay hints,
semantic tokens (full/range/delta), diagnostics (push + pull), type hierarchy,
call hierarchy, executeCommand, workspace folders and a rename filter.

Missing client→server requests:

- Applicable but not implemented: `textDocument/rangesFormatting`,
  `workspace/willCreateFiles`, `workspace/willDeleteFiles`, and the
  `didCreate`/`didRename`/`didDelete` notifications.
- Low value / not applicable: `textDocument/moniker` (LSIF),
  `textDocument/inlineValue` (DAP covers values), `documentColor` /
  `colorPresentation` (no color-literal syntax), `notebookDocumentSync`,
  and the 3.18 additions `textDocument/inlineCompletion` and
  `workspace/textDocumentContent`.

Optional resolve requests are not advertised (`codeAction/resolve`,
`workspaceSymbol/resolve`, `inlayHint/resolve`); items are returned fully
resolved, so that is consistent.

## 3. Verified defects

### P0 — correctness / user-visible

**3.1 UTF-16 positions are only correct on ASCII lines.**  The server advertises
`"positionEncoding":"utf-16"` (`lsp/lifecycle.mt:33`) and decodes incoming
positions correctly (`lsp/utils.mt:42-85`), but every emitted range uses UTF-8
**byte** columns: no byte→UTF-16 converter exists.  Examples:

- `semanticTokens` length is `end_offset - start_offset` bytes
  (`lsp/semantic_tokens.mt:2264`).  Probe: `let s = "😀"` reports string length
  **6**, UTF-16 requires **4**.
- Diagnostics, hover ranges, highlights, references, rename/code-action edits,
  linked-editing and hierarchy ranges all emit byte columns.
- `didChange` counts Unicode scalars, not UTF-16 units
  (`lsp/text_docs.mt:174-195`).  Probe: replacing `1` at UTF-16 `[19,20)` in
  `    let s = "😀" + 1` appended `unknown_name` after the `1` (parse error)
  instead of replacing it.

Formatting is mostly safe because it emits a whole-document edit with
line-based ends (`lsp/formatting.mt:45,125`), and rangeFormatting echoes the
client's UTF-16 range.

**3.2 `codeAction` kinds use `quickFix`, not `quickfix`.**  Advertised at
`lsp/lifecycle.mt:53` and emitted at `lsp/code_actions.mt:305,456`.  VS Code's
`CodeActionKind` matching is case-sensitive, so quick fixes do not match the
standard `quickfix` filter used by the Quick Fix command; `source.fixAll`
(used on save) does work.

**3.3 `workspace/willRenameFiles` never responds.**  It is a request returning
`WorkspaceEdit | null`.  Dispatch calls the handler without the request id
(`lsp/server.mt:311`) and the handler writes no response
(`lsp/workspace_notifications.mt:81-83`).  Probe: no response within 4 s.  It
also only moves index entries; it never returns import rewrites, which is the
feature the capability advertises.

**3.4 Completion documentation is dead; resolve strips the item.**
`collect_doc_text` looks for lines that *start with the bare name*
(`lsp/completion.mt:322-344`), so it never finds `function foo`, `struct Foo`,
or indented methods/fields; the probe returned no docs.  When docs *are* found,
`handle_completion_resolve` rebuilds only `{"label","documentation"}`
(`lsp/completion.mt:280-289`), dropping `kind`, `detail`, `insertText`,
`textEdit`, `sortText`, `data`, etc.  The lookup is also label-only
(`:260`), so common names can resolve the wrong declaration.

### P1 — advertised behaviour

**3.5 Multi-root is advertised but ignored.**  `workspaceFolders.supported` and
`changeNotifications` are true (`lsp/lifecycle.mt:69`), but `Workspace` holds a
single `root_path` (`lsp/workspace.mt:137`), `initialize` reads only
`rootUri`/`rootPath`, and `didChangeWorkspaceFolders` only clears caches and
reindexes the existing root (`lsp/workspace_notifications.mt:70-72`).  Probe:
a symbol in an added folder returns `[]`.

**3.6 Watched files are in the wrong capability and never registered.**
`"workspace":{"didChangeWatchedFiles":{"dynamicRegistration":true}}`
(`lsp/lifecycle.mt:71`) is not a `ServerCapabilities` field; `WorkspaceOptions`
has only `workspaceFolders`, `fileOperations`, `textDocumentContent`.  The
handler exists, but no `client/registerCapability` is ever sent, so spec
clients do not deliver watched-file notifications.

**3.7 Pull diagnostics are partial and never refreshed.**
`workspace/diagnostic` advertises `workspaceDiagnostics: true` but reports
**open documents only** (`lsp/pull_diagnostics.mt:108-130`).  No
`workspace/diagnostic/refresh` is sent, so with `interFileDependencies: true`
a changed import leaves open dependents' diagnostics stale.  The per-document
`resultId`/`previousResultId` cache is otherwise correct.

**3.8 Lifecycle state machine is missing.**  Probes confirmed: a request before
`initialize` returns a result instead of `-32002 ServerNotInitialized`; a second
`initialize` succeeds instead of `-32600 InvalidRequest`; a request after
`shutdown` is still processed; `exit` without `shutdown` returns 0 (spec: 1).
`publishDiagnostics` omits `version`, and document versions are not tracked
(`lsp/diagnostics.mt:126-160`; `open_docs` is path→text only).

**3.9 `$/cancelRequest` cannot cancel and can cancel the wrong request.**  The
loop is synchronous, so a cancel for an in-flight request is read only after it
completes; the stale id remains set (`lsp/server.mt:70-77,576-593`) and can
cancel a later request that reuses the id.

### P2 — smaller conformance items

- `documentSymbol` always returns hierarchical `DocumentSymbol`s; it does not
  consult the client's `hierarchicalDocumentSymbolSupport` and fall back to
  flat `SymbolInformation`.
- `documentHighlight` never sets `kind` (allowed; read/write highlighting is
  lost).
- `positionEncoding` is hard-coded without reading the client's
  `general.positionEncodings`.
- `workspace/configuration` is requested without checking
  `workspace.configuration`.
- `didSave` advertises `includeText` but ignores the sent text.
- `serverInfo` and an `experimental` block for `milkTea/documentContext` /
  `milkTea/debugInfo` are absent.
- No progress (`window/workDoneProgress/create`, `$/progress`) or partial
  results for large workspace requests.

## 4. Work plan

Each phase is one commit, with the plan and ledger synced.  Tests come first in
every phase.

### Phase 0 — conformance harness (1 session) — **DONE (session 145)**

Create `tools/lsp_conformance.rb`: spawn `mtc lsp` over stdio, initialize, run
cases with **explicit assertions**, print a per-case pass/fail summary, exit 1
on failure, support `--json OUT` and `--bin PATH`.  No host.  Seed it with the
cases in §5.  Wire it into `tools/gates.sh` as a hard tier-2 gate
(`lsp_conformance`), add it to the `lsp` area and to `tools_check`, and add a
valgrind drive if practical.  Do not re-record the old host comparisons.

Landed: 26 cases (the §5 rows, with the UTF-16 and completion rows split so a
failure names one boundary), the gate in the `lsp` tier-2 set, and syntax
coverage through the existing `tools_check` glob (`tools/*.rb`).  Current
baseline: **3 pass / 23 fail** — ASCII output and the two behaviors already
implemented (`textDocument/diagnostic` full/unchanged and exit-after-shutdown)
pass; every audited P0/P1 defect is red.  The harness caps each server's
address space and reaps its process group; use `--only` for the phase loop.

### Phase 1 — position encoding (P0)

1. Decide the encoding model.  Recommended: negotiate `utf-8` when the client
   offers it (`general.positionEncodings`) and keep byte offsets internally;
   fall back to `utf-16` and convert on input **and** output.  Store the chosen
   encoding in `Workspace` and make `position_byte_offset`/`didChange` use it.
2. For the UTF-16 path, add `byte_to_utf16_column(line_text, byte_col)` to
   `lsp/utils.mt`, cache per-line text/unit maps per document version in the
   existing document cache, and use one conversion boundary for all emitters.
3. Replace `text_docs.mt`'s scalar `line_char_to_byte` with the shared decoder.
4. Audit every range emitter: `semantic_tokens`, `diagnostics`, `navigation`
   (hover), `highlight`, `references`, `rename`, `code_actions`,
   `linked_editing_range`, `selection`, `symbols`, `inlay_hints`,
   `type_hierarchy`, `call_hierarchy`, `document_link`, `code_lens`.
   Formatting is line-based/echoed and should need no change.
5. Tests: semantic token lengths, diagnostic ranges, rename edits, hover
   ranges, inlay hints, selection ranges, and an astral `didChange`, each on a
   UTF-16 fixture.  ASCII output must be unchanged.

### Phase 2 — small conformance fixes (P0/P1)

- `quickfix` spelling in the capability and every action.
- Completion resolve: find docs by `data.uri`/`data.name`, fix the declaration
  scan, and echo the original item with `documentation` added.
- Lifecycle: initialized/shutdown flags, `-32002` before init, `-32600` for a
  duplicate init and post-shutdown requests, exit code 1 without shutdown,
  `serverInfo`, `experimental`, document version tracking and
  `publishDiagnostics.version`.
- `$/cancelRequest`: track outstanding ids or deliberately ignore it (the
  single-threaded loop cannot cancel in-flight work); remove the stale set.

### Phase 3 — file and workspace operations (P1)

- `workspace/willRenameFiles`: always respond; return a `WorkspaceEdit` that
  rewrites imports in indexed files, or `null` when there are none.  Add
  `didRenameFiles` (and optionally will/did create/delete) only if needed for
  index coherence.
- Multi-root: either implement `roots: Vec[String]` (initialize from
  `workspaceFolders`, update on `didChangeWorkspaceFolders`, reindex) or stop
  advertising it.  Prefer implementing it for VS Code multi-root workspaces.
- Watched files: remove the invalid capability; send
  `client/registerCapability` for `workspace/didChangeWatchedFiles` when the
  client supports dynamic registration; invalidate caches/index in the
  handler.

### Phase 4 — pull diagnostics (P1)

- Either scan workspace roots for `workspace/diagnostic` (bounded, with
  progress/partial results) or set `workspaceDiagnostics: false` until it
  exists.  Do not advertise a workspace report that only covers open files.
- Parse `workspace.diagnostics.refreshSupport` and send
  `workspace/diagnostic/refresh` after changes that affect dependents
  (including watched-file changes).
- If push diagnostics remain for non-pull clients, republish dependents or
  document that they are refreshed on request only.

### Phase 5 — optional features (P2/P3)

- `textDocument/rangesFormatting` (3.16): loop over ranges; cheap.
- Progress (`window/workDoneProgress/create`, `$/progress`) and
  `partialResultToken` for workspace symbol/diagnostic scans.
- Refresh requests for code lens / semantic tokens / inlay hints where
  results depend on other files.
- 3.18 `inlineCompletion` and `workspace/textDocumentContent` only with a
  concrete use case; skip `moniker`, `inlineValue`, `documentColor` and
  notebooks unless the language gains a matching feature.

## 5. Conformance cases

Implemented in `tools/lsp_conformance.rb` (the UTF-16 and completion rows are
split into per-boundary cases).  Add new cases here first, then to the harness:

| Case | Assertion |
|---|---|
| UTF-16 BMP / astral fixture | semantic token lengths, diagnostic ranges, hover range, rename edit, inlay hint, selection range, and an incremental `didChange` all equal UTF-16 expectations |
| ASCII fixture | byte and UTF-16 outputs unchanged from the current recording |
| `codeAction` | advertised kinds are `quickfix`/`source.fixAll`; every returned action's kind is standard |
| completion + resolve | a documented `function foo` returns docs; the resolved item keeps `kind`, `detail`, `insertText`, `sortText`, `data` |
| `workspace/willRenameFiles` | **request** receives a `WorkspaceEdit` (or `null`) within the timeout; imports in a dependent file are rewritten |
| multi-root | a symbol in an added folder resolves; removing the folder removes it |
| watched files | after a dynamic registration, an on-disk change updates symbols/diagnostics without reopening |
| pull diagnostics | `textDocument/diagnostic` full/unchanged round-trip; `workspace/diagnostic` scope is as advertised; a dependent refresh follows an import change |
| lifecycle | pre-init `-32002`; duplicate init `-32600`; post-shutdown `-32600`; exit rc 0 after shutdown, 1 without |
| cancel | a cancel for a completed id does not cancel a later reused id |
| publish | `publishDiagnostics.version` matches the document version |

## 6. Verification

Tier 1 (per edit):

```sh
"$(tools/bootstrap.sh --print-stage0)" build projects/mtc -I . --no-cache -o tmp/mtc-dev
tmp/mtc-dev test projects/mtc -I . --timeout 120        # 22/0
ruby tools/lsp_conformance.rb --bin tmp/mtc-dev
```

Tier 2 (once per commit, frozen sources):

```sh
tools/bootstrap.sh -j 4                                  # fixed point + 22/0
build/stage2/mtc test test/mt -I .                       # 85/0
tools/gates.sh --areas lsp --run                         # conformance, valgrind, soak
ruby tools/lsp_parity.rb record --server self --out tmp/lsp-self.json --stress
ruby tools/lsp_soak.rb --quiet                           # raw slope in the 70–80 band
```

`lsp_conformance` is in the `lsp` area and `tools_check` covers its syntax.
Until the phases land the gate is red on purpose; run only the class being
fixed (`--only utf16`, `--only lifecycle`, …) while iterating, then the whole
suite once per phase.  Do not run the recorded CLI/diag/lint/format goldens for
an LSP-only change unless the compiler shared code changes.  A user-visible
change (quick fix, rename, multi-root) should also get a VS Code extension-host
smoke; the extension packaging fixes are a separate repo.

## 7. Constraints and risks

- **Single-threaded by design.**  True cancellation and progress need an async
  request architecture; do not fake them.  Prefer an honest limitation and a
  correct synchronous loop.
- **UTF-16 conversion cost.**  Cache per-document line/unit maps with the
  existing text cache; never rescan a document per range.
- **Workspace-wide diagnostics are expensive.**  Bound the scan and use
  progress/partial results, or defer and advertise `workspaceDiagnostics:false`.
- **No host.**  Expectations come from the 3.18 spec, not the archived Ruby
  behavior.  Do not port host bugs (the `quickFix` spelling is one).
- **JSON ownership.**  `std.json` objects share pointers; mutating a request
  object and responding (the code-lens pattern) is safe, but do not release a
  shared value twice (`protocol.mt` documents this).
- **Method order.**  The recorded golden fixtures are digest-keyed; an LSP-only
  change should not move them.

## 8. References

- LSP 3.18 specification:
  `https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/`
- 3.18 meta-model:
  `https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.18/metaModel/metaModel.json`
- Current design/history: `docs/lsp-design.md`, `docs/lsp-performance.md`.
- Live project state: `docs/self-host-plan.md` (status, handoff, ledger).

## 9. Session kickoff prompt

```
Start the LSP enhancement program in /home/teefan/Projects/Ruby/mt-lang
(branch `selfhost`). Read docs/lsp-enhancement-plan.md first: it carries the
3.18 coverage matrix, the verified defects, the phase plan and the conformance
cases. The compiler is the native self-host; the Ruby host is archived and
must not be used as an oracle.

Phase 0 is done: tools/lsp_conformance.rb and the lsp_conformance gate exist,
and the gate is red on the audited defects. Start phase 1 (position encoding:
negotiate utf-8 when offered, otherwise convert both directions with cached
line maps; replace the scalar didChange counter), then phases 2–4 in order.
Work the red cases with `ruby tools/lsp_conformance.rb --bin tmp/mtc-dev
--only <class>`; close each phase by making its cases pass and then run the
whole suite. Work in tiers: seed dev build (~25 s), tmp/mtc-dev test
projects/mtc (22/0), then bootstrap/test/mt and the LSP gates on frozen
sources. Sync docs/self-host-plan.md and this plan's status/ledger in the same
commit; commit trailer: Co-authored-by: CommandCodeBot <noreply@commandcode.ai>.
```
