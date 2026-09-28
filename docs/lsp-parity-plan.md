# LSP for real projects — parity, recovery and readiness plan

**Goal.** Make the self-hosted `mtc lsp` a daily driver on real projects: byte-parity
with the Ruby host on everything an editor can observe (diagnostics included), plus the
readiness properties parity alone does not test — cold start, steady-state memory, large
files, long sessions, real clients (Neovim/VS Code).

**Where we are** (branch `selfhost`, session 9, 2026-09-28): SimpleGame audit
6456 entries / **335 differ** (hover 83, definition/declaration 72 each,
typeDefinition 70, documentHighlight 14, references 9, documentSymbol 5,
semanticTokens 5, diagnostic 2, codeLens 1, implementation 1, workspace/symbol 1);
references-only audit **0**; synthetic harness 30/30 capabilities + 4 documented
entries; probe fixtures 0 (references) / 0–8 (small classes); bootstrap fixed
point + 14/14; `cli:parity` 23/38/0.

**Track A is closed** (session 9): `tools/lsp_recovery_probe.rb --check` reports
recovery parity — all six mid-edit cases byte-equal.  A1 (the JSON-blob message)
was the analyzer's duplicate `missing-return` sema error; A2 is the ` at
<uri>:<line>:<col>` suffix on parse/lex messages (added in the diagnostic
conversion, from the document URI); A3/A4 are the parser's panic-based
unwinding (`ParserState.panic` + rewind-to-error + the host's recovery points and
partial nodes), which the statement/declaration/local/match-arm fixtures pin.
The lints on recovered code followed (scope-pass reads, dead-assignment, the
`missing-return` emission order) — recorded in `docs/self-host-plan.md` §0k,
session 9.

**This file is the durable plan** (checked in; the session plan file
`~/.commandcode/plans/lsp-real-project-parity.md` is a copy).  `docs/lsp-design.md`
§9 records the readiness findings and the deliberate-difference rows; `docs/self-host-plan.md`
§0k keeps the measured records, `~/.commandcode/plans/finish-self-host-full-parity.md`
the multi-session ledger.

---

## Track A — recovery & diagnostics parity (CLOSED, session 9)

`ruby tools/lsp_recovery_probe.rb --check` passes: the six mid-edit cases are
byte-equal.  The bullets below are kept as the record of what each item was; the
one piece deliberately not emulated yet is the host's *nested* declaration
rescues (its `parse_method_def`, the local-decl `else` variant, the field loops) —
a nested declaration dropped inside a block still recovers as a dropped
declaration rather than the host's partial node (§0k, session 9).

- **A1. The message-as-JSON blob.** Find where `mtc`'s diagnostics serializer forwards a
  *content object* into `message` (the entry appears as `sema/error` at the missing-return
  position with a markdown blob) and emit the plain text. Add a unit test with that exact
  source; assert `message` is a string for every diagnostic.
- **A2. Parse-error message suffix.** The host's diagnostics builder appends
  ` at <uri>:<line>:<col>` (1-based, the error's own position) to parser recovery errors.
  Port it in the self's diagnostic conversion (not in the parser's message text) and pin
  it with the probe.
- **A3. Recovery positions/sets.** `expected end of statement` after a truncated member
  access: the host reports the token position (10:13 1-based), the self the statement start
  (9:0 0-based). Diff `parse_collecting_errors` against the host's
  `Parser.parse_collecting_errors` on the fixture corpus (truncated `n.`, `a.b.`, an
  unterminated string/brace, a half-typed `import`, a cut-off expression) and align the
  recovery points one case at a time.
- **A4. Recovered-AST divergence.** The same truncation leaves the host with `unknown name v`
  and the self with `unknown field Sample.` — i.e. the two partial trees differ. Trace with
  `sexpr parse` on the fixtures (the parser-recovery text also feeds `cli:parity`'s 39
  differing cases and the in-flight plan's stage-12 note), fix the recovery shape, then let
  the *lint on recovered code* follow (`unused-local` vs `prefer-let`, `missing-return`
  timing) — re-check both after each parser fix rather than special-casing the linter.
- **A5. Harness.** Done: `tools/lsp_recovery_probe.rb` with `--check` (byte
  compare, non-zero exit on diff) and its corpus under `tmp/lsp-recovery/`
  (created by the tool).  Run in the session gates.

## Track B — the audit residue (336 entries)

- **B1. hover 83.** Ranked: prelude/inherent methods of generic types (`Option.unwrap()`,
  `Option.value` — the host's `methods_for_receiver_type` merges `facts.methods` (the
  local/prelude registration) and `BUILTIN_TYPE_METHOD_SIGNATURES`; the self's
  `resolve_member_method_hover` has no signature for a type with no owning module);
  fields of workspace types (the host prints **no** `Defined at` where the self prints
  one — `field name: cstr`); `type parameter T`; attribute hovers
  (`attribute [callable] traced(tag: str)`, `attribute target callable`); bare variant-arm
  constructors (`Result.success(value: T)`, `MyOption.some(value: T)`) and enum members
  (`Kind.c = 6`) from the host's `find_member_in_types` / `find_variant_arm_in_types`;
  the implicit `this`; and analyzer gaps (`let raw: own[ubyte]`, `Result`/`Option`
  initializers typed `<error>`, null-refinement on parameters inside guards — the latter
  ties into Phase 2's null-refinement item).
- **B2. definition 72 / declaration 72 / typeDefinition 70.** Re-measure after each B1 fix
  (the member pipeline feeds all three); the remaining shapes are the same member cases
  plus the host's location artifacts.
- **B3. references 9.** Gated on B1 (they are files the host's hovers tokenized and the
  self's did not: `option.mt`, `linear_algebra.mt`), plus the one lazy-facts first-request
  entry (documented deliberate: synchronous facts).
- **B4. small classes.** documentHighlight 14, documentSymbol 5, semanticTokens 5,
  diagnostic 3, codeLens 1, implementation 1, workspace/symbol 1 — independent, mostly
  rendering/order.

## Track C — real-project readiness (what parity alone does not test)

- **C1. Index scope and cold start.** The self's workspace index walks *module roots*;
  because the running binary lives inside the compiler tree, a project outside it gets the
  whole compiler tree indexed (startup latency, memory). Restrict the walk to the workspace
  root + package source roots + the explicit `-I` roots, index lazily (host's
  `index_workspace` on `initialized`), and record cold-start time before/after on
  SimpleGame and on a fresh empty project.
- **C2. Reference-index memory.** It keeps an owned copy of every noted document's text
  (token views point into it). Bound it: cap the document count / total bytes, drop on
  close + didChange, and verify with a long-session soak (thousands of requests; valgrind
  + RSS ceiling).
- **C3. Per-request re-hash.** `note_document_tokens` reads and hashes the file on every
  hover/references call; cache by (mtime, size) for disk files and by content hash for open
  buffers, then re-measure `[LSP perf]` ≤ ~10 ms/edit on a large file
  (`docs/lsp-performance.md`).
- **C4. Large files/workspaces.** Add a soak target (≥5k lines, ≥10k requests, mixed
  methods, timeouts + valgrind + RSS) to the gates so regressions surface before a user
  sees them.
- **C5. Client behaviours.** workspace folders, `didChangeConfiguration`, watched files,
  `includeDeclaration: false`, cancellation, closed-file edits — cross-check against the
  host and add harness cases for any that differ.
- **C6. Deliberate differences, one table.** Keep and document: malformed-frame recovery,
  synchronous facts (no lag), faster cold start, and the recovery knock-ons Track A does
  not remove. `docs/lsp-design.md` §8 is the place.

## Track D — verification infrastructure

- **D1.** Commit the recovery probe (A5) with `--check`.
- **D2.** `tools/lsp_project_audit.rb --canonical` (or a documented substitute) to pin the
  request history so the ±10 drift disappears from the counters.
- **D3.** Add an LSP row to `tools/parity_scoreboard.rb`.
- **D4.** Keep the standing gates exactly as AGENTS.md lists them (bootstrap, test/mt,
  cli:parity, sexpr lex/parse, unused-import, harness, fixtures, valgrind, Neovim smoke).

## Order (one commit per item; docs + ledger + this plan synced in each)

0. Commit this plan as `docs/lsp-parity-plan.md` + update `docs/lsp-design.md` (§3/§7/§8)
   + the `~/.commandcode/plans/finish-self-host-full-parity.md` ledger, and paste the
   session prompt below.
1. A1 → A2 → A5 (recovery quick wins + harness).
2. A3 → A4 (parser recovery parity; re-run cli:parity + sexpr parse after each).
3. B1 → B2 → B3 (hover pipeline, then the counters it drives).
4. B4 (small classes), C1 → C2/C3 → C4/C5, D2/D3.

## Gates (every commit)

`tools/bootstrap.sh -j 16` (fixed point + 14/14), `build/stage2/mtc test test/mt -I .`
(60/0), `rake "cli:parity"` (22/39/0), `ruby tools/sexpr_parity.rb lex -q` /
`parse -q` (0 differ), `ruby tools/unused_import_parity.rb` (documented residual),
`ruby tools/lsp_parity.rb record/compare` (30/30 + 4 documented),
`ruby tools/lsp_project_audit.rb --workspace … --only <method>`, the probe fixtures,
and for behaviour changes valgrind + the headless-Neovim smoke. Never edit sources
while a gate runs.

## Session prompt (copy-paste)

```
Continue the Milk Tea self-host LSP work in /home/teefan/Projects/Ruby/mt-lang
    (branch `selfhost`). Rebuild before measuring:
      ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o build/stage2/mtc

    Read first: docs/lsp-parity-plan.md (committed — the focused real-project LSP
    plan: recovery, the audit residue, readiness), then
    ~/.commandcode/plans/finish-self-host-full-parity.md (ledger + session logs),
    docs/lsp-design.md §3/§7/§8, docs/lsp-performance.md, and AGENTS.md's
    "Self-Host Parity Program" section (gates, drift, fixtures).

    This session is LSP-only.  Order (one commit per item, gates + docs + ledger
    in the same commit):

    1. RECOVERY FIRST (Track A).  Run the recovery probe and make it pass:
         ruby tools/lsp_recovery_probe.rb          # prints host vs self per edit
         ruby tools/lsp_recovery_probe.rb --check  # byte-compare, non-zero on diff
       a. A1: a diagnostic whose `message` is a JSON blob
          ({"kind"=>"markdown","value"=>…}) — find the serializer and emit text.
       b. A2: parse-error messages miss the host's ` at <uri>:<line>:<col>`
          suffix; port it in the diagnostic conversion.
       c. A3/A4: the recovered AST differs (`expected end of statement` at 9:0 vs
          9:12; `unknown name v` vs `unknown field Sample.`; `unused-local` vs
          `prefer-let`; `missing-return` timing).  Diff `parse_collecting_errors`
          against the host on truncated-member/unterminated-string/half-import
          fixtures, fix the recovery shape, then re-check the lint on recovered
          code (do not special-case the linter).  Re-run `rake "cli:parity"` and
          `sexpr_parity parse` after each change — recovery text feeds both.
    2. Then Track B largest-first, re-measuring hover after each fix:
           `ruby tools/lsp_project_audit.rb --workspace /home/teefan/Projects/MilkTea/SimpleGame --json tmp/audit-lsp.json --max-diffs 0 --timeout 60 --only hover`
       b1. hover 83: prelude/inherent methods of generic types (`Option.unwrap()`,
           `Option.value`: port the host's `methods_for_receiver_type` =
           `facts.methods[receiver]` + imported modules' methods +
           `BUILTIN_TYPE_METHOD_SIGNATURES`); fields of workspace types (the host
           prints no `Defined at`); `type parameter T`; attribute hovers; bare
           variant-arm constructors (`Result.success(value: T)`) and enum members
           (`Kind.c = 6`); the implicit `this`; analyzer gaps (`own[…]`/`Result[…]`
           initializers typed `<error>`, null-refined parameters in guards).
       b2. definition/declaration 72, typeDefinition 70 (same shapes; re-measure
           after every hover fix — the pipeline is shared).
       b3. references 9 (they follow the hover tokenization) + the documented
           lazy-facts entry.
       b4. documentHighlight 14, documentSymbol 5, semanticTokens 5, diagnostic 3,
           codeLens 1, implementation 1, workspace/symbol 1.
    3. Then Track C readiness: index scope/cold start (C1), reference-index memory
       bound (C2), note-document caching (C3), the large-file soak (C4), client
       behaviours (C5); document deliberate differences in docs/lsp-design.md §8.

    GATES for every commit (AGENTS.md): tools/bootstrap.sh -j 16 (fixed point +
    14/14), build/stage2/mtc test test/mt -I . (60/0), rake "cli:parity" (22/39/0),
    ruby tools/sexpr_parity.rb lex -q / parse -q (0 differ),
    ruby tools/unused_import_parity.rb (1 documented residual),
    ruby tools/lsp_parity.rb record/compare (30/30 + 4 documented),
    ruby tools/lsp_project_audit.rb --workspace … --only <method>, the probe
    fixtures, the recovery probe; behaviour changes also get valgrind + the
    headless-Neovim smoke.  Sync docs/self-host-plan.md §0k, docs/lsp-design.md,
    docs/lsp-parity-plan.md's counters and the plan ledger in the same commit;
    commit trailer: Co-authored-by: CommandCodeBot <noreply@commandcode.ai>.
    No hacks — fix root causes; never edit sources while a gate runs; run generated
    binaries as `timeout 10 bash -c 'ulimit -v 20000000; …'`.
```
