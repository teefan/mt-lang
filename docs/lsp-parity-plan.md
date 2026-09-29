# LSP for real projects — parity, recovery and readiness plan

**Goal.** Make the self-hosted `mtc lsp` a daily driver on real projects: byte-parity
with the Ruby host on everything an editor can observe (diagnostics included), plus the
readiness properties parity alone does not test — cold start, steady-state memory, large
files, long sessions, real clients (Neovim/VS Code).

**Where we are** (branch `selfhost`, session 13, 2026-09-29): SimpleGame audit
6456 entries / **22 differ** (hover 9, documentSymbol 5, semanticTokens 5,
diagnostic 2, documentHighlight 1; codeLens, workspace/symbol and
definition/declaration/typeDefinition/implementation/**references 0**);
synthetic harness 30/30 capabilities + 4 documented entries; probe fixtures at
their session-12 diff sets (`hover-probe4` closed 6 navigation entries);
bootstrap fixed point + 14/14; `cli:parity` 23/38/0.  Per-class
numbers measured with `--only` drift ±10 against the full matrix (the host
warms its caches as the audit proceeds); the full matrix is authoritative.

**Track B, fifteenth batch** (session 13, continued): code lenses and workspace
symbols from the host's token-pair symbol list (`extract_symbols_from_tokens` →
`SymbolEntry`/`symbols_for` in the definition index, plus `warmed_paths` for the
document set) — codeLens **1 → 0** (145 lenses, including the nested `when`-branch
and `emit`-expanded declarations an AST walk missed) and workspace/symbol
**1 → 0** (the 3374-entry answer byte-equal, no cap, no root filter) —
documentHighlight **2 → 1** (`this` scoped to its method), and the token scanner
gained the keyword-module-path, character-literal, keyword-before-colon,
per-line-heredoc and type-argument rules (the five files' differing positions
**952 → 676**; the streams still differ as a whole).

**Track C1 landed** (session 13): the host's cross-file definition index is
ported — the `@definition_candidate_uris` / `@definition_names_by_uri` registry,
`find_definition_global` searching those candidates, and the **hover-driven
warm** that grows the index exactly where the host's does
(`hover_definition_entry_from_location` → `find_token_at` → `get_tokens` →
`get_content`; found by tracing `get_content` with a `RUBYOPT` hook, not by
guessing).  The index *walk* is the workspace root now
(`Workspace#workspace_index_roots`), which is C1's cold-start half:
`tools/lsp_cold_start.rb` measures spawn → the first `workspace/symbol` response
at **2723.5 → 213.3 ms** on SimpleGame and **2455.1 → 2.3 ms** on a one-file
project.  The session also closed the interface method's own declaration line
(hover/definition/declaration/typeDefinition), the implementation pipeline, the
typeDefinition arm's early return and bindings inside `unsafe`/`defer`/`when`
blocks — the audit **56 → 37**, definition **5 → 0**, declaration **5 → 0**,
typeDefinition **4 → 0**, implementation **1 → 0**, hover **13 → 9**, and its
second batch closed documentHighlight **14 → 2** (`unbound_occurrence`: the
host's binding node set excludes named-argument labels, member names, call
callees and destructuring pattern names) — the audit **56 → 37 → 25** with no
entry ever added back.  The synthetic references-only mode moved 0 → 56 without
changing a single self answer (all 916 are byte-identical): its counts are
pacing-coupled, since the audit alternates host/self requests and the host's
background indexing progress depends on the self's speed.  The record is
`docs/self-host-plan.md` §0k, "Track B, thirteenth batch + Track C1" and
"Track B, fourteenth batch".

**Track B, batches 11–12** (session 12): the **definition pipeline** — definition
**61 → 5**, declaration **61 → 5**, typeDefinition **59 → 4**, hover **14 → 13**
(closed 56/56/55, none added; audit **224 → 60 → 56**) — by classifying the residue
first and porting five host behaviours: the local definition rule (its bindings
carry no AST node, so its `find_local_declaration_ast_node` answers the *file's
first* same-named `let`/`var`/`for` declaration before the cursor), the hover-only
nature of the member/variant arms, the `is_builtin_name?` gate, an import alias's
member declaration (`find_definition_token_in_file`), and the receiver-typed
method line (`find_method_line_in_type` in both method paths).  The record is
`docs/self-host-plan.md` §0k, "Track B, eleventh and twelfth batch".

**Track B, batches 6–10** (session 11): hover **32 → 14** and the member
pipeline it feeds — definition/declaration **70 → 61** each, typeDefinition
**68 → 59** (10 entries closed per class, 1 traded at `lb@1915:25`, where the
host's definition index answers a *different* function's declaration and the
self's flat fallback now answers the enclosing one) — as 
the host's indentation-sensitive field-token scan (`find_field_token_in_type`,
so a `public struct`'s fields carry no location) with the field declaration
hover rendering the *resolved* type, then the bare member arms
(`find_member_in_types` with `const_eval_int`; `variant_types` so a variant arm
renders its constructor form), then attributes/type parameters/`this`, then the
`this` and annotated-local receiver resolution (the analyzer records
`local_decl_types`), then two leftovers (the method signature's `-> void`, `_`
as a discard).  The record is `docs/self-host-plan.md` §0k, "Track B, sixth
through tenth batch".

**Track B, batches 2–5** (session 10): hover **80 → 32** and the class's
knock-ons — references **9 → 0**, definition/declaration 72 → 70,
typeDefinition 70 → 68 — by typing the analyzer's `<error>` locals (unary `~`,
tuple literals, `Type[args].arm(…)` instances, imported specialization calls,
builtin static receivers, event methods, `get`, `detach`) and the renderings
that followed (guarded-local narrowing, module-less builtin types, the function
signature shape, the builtin arms' definition-index location), then the member
resolution the new types exposed (imported modules' `extending` methods —
`vec3.cross` in std.linear_algebra — the builtin vector/matrix/quaternion field
tables, receiver projection through `ref`/`ptr`/`own`), then the variant arm
constructors and their named-argument labels, then the module-qualified
annotation renderings (`*From std.vec, …*`, `type Result = Result`).  The
host's C string-literal escaping was fixed first: its `\xNN` escapes absorbed
following hex digits, so the host-built self binary crashed on any non-ASCII
hover doc (`mat3`/`mat4`).  The record is `docs/self-host-plan.md` §0k,
"Track B, second through fifth batch".

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
byte-equal.  The bullets below are kept as the record of what each item was, with
the outcome one line each:

- **A1** (the JSON-blob message) → the analyzer's duplicate `missing-return` sema
  error; removed with its dead termination helpers.
- **A2** (the ` at <uri>:<line>:<col>` suffix) → emitted by the LSP diagnostic
  conversion from the document URI (push and pull agree; the CLI text is
  unchanged).
- **A3/A4** (positions and the recovered AST) → `ParserState.panic` plus the
  host's recovery points and partial nodes; the lints on recovered code followed
  from the AST.
- **A5** (the harness) → `tools/lsp_recovery_probe.rb` with `--check`, corpus
  under `tmp/lsp-recovery/`, run in the session gates.

The one piece deliberately not emulated yet is the host's *nested* declaration
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

## Track B — the audit residue (22 entries, was 332)

- **B1. hover 80 → 9.** Sessions 10–12 closed the
  analyzer-`<error>` locals with the renderings they exposed, the member
  resolution those types uncovered (imported `extending` methods, builtin
  vector/matrix/quaternion fields, receiver projection), the variant arm
  constructors with their named-argument labels, the module-qualified
  annotation renderings, then (session 11) the host's indentation-sensitive
  field-token scan and resolved field types, the bare enum/flags member arms,
  the attribute/type-parameter/`this` arms, the `this` and annotated-local
  receiver resolution, and the method signature's `-> void`; session 13 closed
  the method's own declaration line and the block-statement bindings.  The
  residue (measured live, session 13) is: **4 nullability** (`mst@25:7`,
  `@28:20`, `@205:7`, `@404:7` — the host prints the flow-refined type where the
  self prints the declared one: the analyzer's continuation refinement, the
  compiler-side item); **2 destructuring** (`lb@1861:23`, `lb@1931:25`) and a
  **match-arm payload binding** (`lb@1915:25`) — the analyzer binds those names
  to `ty_error` (stage 11c); a **function-typed field**'s bare `fn `
  (`lb@1127:9`, the host's `Types::Function#to_s` — the compiler stages'
  function-type names item); `type quat`'s cross-file location
  (`lb@1653:24` — the index does not reach `std/linear_algebra.mt` in the hover
  order the audit produces); and a **member chain's third segment**
  (`lb@1958:16`).
- **B2. definition 0 / declaration 0 / typeDefinition 0 (closed, session 13).**
  Session 12's definition-pipeline port closed 56/56/55 of what was left, and
  session 13's Track C1 closed the last five positions in each class (the
  cross-file definition index plus the interface method's own token).
- **B3. references 0 (closed, session 10).** The 9 full-matrix entries were the
  hover residue's knock-on (files the host's hovers tokenized and the self's did
  not); typing the analyzer's `<error>` locals closed them.
- **B4. small classes.** documentHighlight **1** (13 closed in session 13;
  the survivor needs the host's carried-forward binding resolution for a label
  token), documentSymbol 5 (host answers are timing-coupled: the module wrapper
  appears only once its module-name index is warm; the self's outline matches
  the unwrapped shape's symbol set), semanticTokens 5 (the streams differ in 676
  positions, from 952), diagnostic 2 (a *linter* residue, measured in session 13:
  rule anchors differ and rules are missing — `redundant-unsafe`,
  `owning-release-leak`; it is not the emission order) — codeLens,
  workspace/symbol and `implementation`
  closed in session 13.

## Track C — real-project readiness (what parity alone does not test)

- **C1. Index scope and cold start.** **Done (session 13).**  The workspace index
  walks the workspace root plus the package's source root now
  (`Workspace#workspace_index_roots`); `module_roots` stays wider for import
  resolution only, so a project outside the compiler tree no longer indexes the
  compiler tree.  The definition index grew its candidate registry and the
  hover-driven warm in the same session (see "Track C1 landed" above), and
  `tools/lsp_cold_start.rb` records the numbers: SimpleGame **2723.5 → 213.3 ms**,
  one-file project **2455.1 → 2.3 ms** (spawn → the first `workspace/symbol`
  response, against a binary built from the session-12 tree).  The self has no
  `-I` flag on `mtc lsp`, so the explicit-roots half is moot.
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
  synchronous facts (no lag), faster cold start, and the recovery-adjacent differences
  Track A left (the nested-declaration rescues not emulated, the host's parser-recovery
  rows in §0k). `docs/lsp-design.md` §8 is the place.

## Track D — verification infrastructure

- **D1.** Done (session 9): the recovery probe (A5) is committed with `--check`.
- **D2.** `tools/lsp_project_audit.rb --canonical` (or a documented substitute) to pin the
  request history so the ±10 drift disappears from the counters.
- **D3.** Add an LSP row to `tools/parity_scoreboard.rb`.
- **D4.** Keep the standing gates exactly as AGENTS.md lists them (bootstrap, test/mt,
  cli:parity, sexpr lex/parse, unused-import, harness, recovery probe, fixtures,
  valgrind, Neovim smoke).

## Order (one commit per item; docs + ledger + this plan synced in each)

Done: 0 (this plan committed), 1 (A1 → A2 → A5), 2 (A3 → A4 — one commit for the
parser unwinding and the knock-ons, session 9), the first B1 batch (the
`proc`-vs-`fn` hover rendering, hover 83 → 80), session 10's five commits
(the host's C string-literal escaping; the analyzer's `<error>` locals and their
renderings; imported methods and builtin fields; the variant arm constructors
and their labels; the module-qualified annotation renderings — hover 80 → 32,
the full matrix 332 → 269), session 11's five batches (field-token locations +
resolved field types; the member arms with `variant_types` and `const_eval_int`;
attributes/type parameters/`this`; the `this` and annotated-local receivers with
`local_decl_types`; the method `-> void` and the `_` discard — hover 32 → 14,
the full matrix 269 → 224), session 12's three commits (the local definition
rule with its gates; an import alias's member declaration; the receiver-typed
method line — definition 61 → 5, declaration 61 → 5, typeDefinition 59 → 4,
hover 14 → 13, the full matrix 224 → 56), and session 13 (Track C1's definition
index + index scope + cold start; the method's own declaration line; the
implementation pipeline; the typeDefinition early return; block-statement
bindings — definition/declaration/typeDefinition 5/5/4 → 0, implementation
1 → 0, hover 13 → 9, the full matrix 56 → 37).

Remaining, in order.  Note that the residue has crossed over: most of what is
left is *analyzer* work the LSP only measures, so the compiler stages the
multi-session plan already queues (Phase 2 item 3, stage 11c) come first for
those entries:

1. **documentHighlight 1** (B4).  `lb@704:67` is a named-argument label that the
   host resolves through its *carried-forward* snapshot bindings to a binding
   which is out of scope at that line (a match-arm binding declared 100 lines
   earlier); the self's region-based scope walk answers the whole-file token scan
   instead.  Reproducing it means emulating the host's completion-snapshot
   carry-forward, not a local rule.
2. **hover's 9, grouped by root cause:**
   - the **nullability** four (`mst@25:7`, `@28:20`, `@205:7`, `@404:7`) — the
     host prints the *flow-refined* type where the self prints the declared one,
     with its completion-snapshot selection deciding which refinement applies at a
     guard line (a terminating then-branch gives the falsy refinement, a joining
     branch the declared type).  Emulating it means reproducing the host's
     control-flow snapshot order — the same carry-forward machinery as item 1;
   - the **destructuring** two (`lb@1861:23`, `lb@1931:25`) and the **match-arm
     payload** (`lb@1915:25`) — stage 11c;
   - the function-typed field's bare `fn ` (`lb@1127:9`, the host's
     `Types::Function#to_s` — the compiler stages' function-type names item) and
     `type quat`'s cross-file location (`lb@1653:24`: the host's answer depends on
     its asynchronous definition warmup — see the finding below).
3. **B4's other classes** — documentSymbol 5 (the host's module hierarchy; its
   answers are timing-coupled, and the self's unwrapped outline already matches the
   symbol set) and semanticTokens 5 (676 differing positions, from 952: import-alias
   receivers, `emit`-expanded declarations, variant payload fields, `typeParameter`
   renderings, scope-aware binding resolution), then diagnostic 2 — a *linter*
   residue (see the finding below).
4. C2 → C3 → C4/C5 (readiness), with the deliberate-difference table in
   `docs/lsp-design.md` §8, then D2/D3 (audit determinism, scoreboard row).

**Findings for the next session.**

- **The hover index fallback is not uniform.**  The host's `resolve_hover_info`
  falls back to the workspace definition index when it resolves a signature without
  a `source_location` (and not through a bare member arm) — but porting that
  fallback for every location-less `resolve_cursor` result is *wrong*: it closed
  `lb@1653:24` and added five entries (`lb@141:4`, `lb@1757:15`, `mst@141:13`,
  `main.mt@18:36`, `@18:55`).  The host's answer at those positions depends on its
  **asynchronous definition warmup** (`enqueue_definition_warmup` runs on a
  thread), so a hover can precede the warm of the file it would find; the self is
  deliberately synchronous (the "synchronous facts" deliberate difference of
  `docs/lsp-design.md` §8), which is exactly the behaviour the residue shows.
- **`diagnostic` 2 is a linter residue, not emission order.**  On
  `language_baseline.mt` the host reports 98 items and the self 123: some rules are
  anchored differently (`redundant-return` 325:4-10 vs the self's 4-5,
  `redundant-type-annotation` 422:8-12 vs 8-13, `prefer-inline-if` /
  `prefer-conditional-expression` 474:4-5 vs 474:7-8) and the host reports rules the
  self lacks.  On `memory_stress_test.mt` (host 10 / self 7) the missing rules are
  `redundant-unsafe` (×4) and `owning-release-leak`; `owning-release-double`
  anchors at the binding name (335:33) where the self anchors at the declaration
  (335:4); the self reports `prefer-own-ptr` (×2) where the host does not.  That is
  the in-flight plan's linter stages (11/11b) work.
## Gates (every commit)

Rebuild with `ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o
build/stage2/mtc` first (never measure a stale binary).  Then
`tools/bootstrap.sh -j 16` (fixed point + 14/14), `build/stage2/mtc test test/mt -I .`
(60/0), `rake "cli:parity"` (23/38/0), `ruby tools/sexpr_parity.rb lex -q` (705/705)
and `parse -q` (701 comparable / 0 differ), `ruby tools/unused_import_parity.rb`
(609/608, the documented residual), `ruby tools/lsp_parity.rb record --server … --stress`
+ `compare` (30/30 capability keys + 4 documented entries),
`ruby tools/lsp_recovery_probe.rb --check` (mid-edit recovery), the probe fixtures
(`tmp/probe-ws`, `probe2`, `probe4`–`probe6`), and
`ruby tools/lsp_project_audit.rb --workspace … --only <method>` for the class being
worked.  Behaviour changes also get valgrind on the touched path plus the
headless-Neovim smoke.  Never edit sources while a gate runs.

## Session prompt (copy-paste)

```
Continue the Milk Tea self-host LSP work in /home/teefan/Projects/Ruby/mt-lang
    (branch `selfhost`). Rebuild before measuring:
      ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o build/stage2/mtc

    Read first: docs/lsp-parity-plan.md (the focused plan — Track A CLOSED,
    Track C1 DONE; Track B is at 37 entries, its live record in
    docs/self-host-plan.md §0k, "Track B, thirteenth batch + Track C1"), then
    ~/.commandcode/plans/finish-self-host-full-parity.md (the session-13 log),
    docs/lsp-design.md §8/§9, and AGENTS.md's "Self-Host Parity Program" section
    (gates, drift, fixtures).

    This session is LSP-only.  State at session-13 close: the SimpleGame full
    matrix is 6456 entries / 22 differ — hover 9, documentSymbol 5,
    semanticTokens 5, diagnostic 2, documentHighlight 1; codeLens,
    workspace/symbol and definition/declaration/typeDefinition/implementation/
    references 0 (codeLens and workspace/symbol closed via the host's token-pair
    symbol list, which also reaches `when`-branch and `emit`-expanded
    declarations); the harness 30/30 capability keys + the 4 documented entries;
    recovery probe OK; cli:parity 23/38/0; sexpr lex 705/705 and parse 701
    comparable / 0 differ; unused-import 609/608; bootstrap fixed point + 14/14;
    test/mt 60/0.  Note: the synthetic `--only references` mode is
    *pacing-coupled* — its host answers depend on the self's speed, so it reads
    0–56 without a single self-side change (verified in session 13 by comparing
    every self answer); the full matrix is the authoritative measure.

    MEASUREMENT RULE: the full matrix is authoritative.  `--only <method>` runs
    drift ±10 per method (the host warms its caches as the audit proceeds), so
    quote per-class numbers from the full run and verify a fix by comparing
    *sets of differing keys*, not counts.

    STEP 1 — re-measure before touching anything:
      ruby tools/lsp_project_audit.rb --workspace /home/teefan/Projects/MilkTea/SimpleGame \
        --json tmp/audit-s14.json --max-diffs 0 --timeout 60
    and the harness:
      ruby tools/lsp_parity.rb record --server host --out tmp/lsp-host.json --stress
      ruby tools/lsp_parity.rb record --server self --out tmp/lsp-self.json --stress
      ruby tools/lsp_parity.rb compare tmp/lsp-host.json tmp/lsp-self.json
    Fast fixtures: probe-ws, probe2 (2 deliberate hovers), probe4–probe6,
    fieldprobe, thisprobe, defprobe, crash1, hover-probe2 (annotation `*From*`),
    hover-probe3/-4 (the analyzer `<error>` shapes), hover-probe5 (mat4 / heap /
    tuple / detach / span), eventprobe, plus the valgrind wrapper
    (/tmp/mtc-vg-s12.sh) and tmp/nvim_hover_smoke.lua.

    STEP 2 — the residue, grouped by root cause, largest first:

    1. **documentHighlight 1** (B4): `lb@704:67`, a label token the host resolves
       through its carried-forward snapshot bindings to a binding out of scope at
       that line (a match-arm binding 100 lines earlier); the self's region-based
       scope walk answers the whole-file token scan instead.  The same
       carry-forward artefact drives hover's nullability family.
    2. **hover's 9:**
       - the four nullability entries (`mst@25:7`, `@28:20`, `@205:7`, `@404:7`):
         the host prints the *flow-refined* type where the self prints the
         declared one — the analyzer's flow/continuation refinement (the
         multi-session plan's Phase 2 item 3);
       - the two destructuring entries (`lb@1861:23`, `lb@1931:25`) and the
         match-arm payload (`lb@1915:25`): the analyzer binds destructured names
         to `ty_error` (stage 11c carries the payload design);
       - the singletons: `lb@1127:9` (a function-typed field renders the bare
         `fn ` in the host — `Types::Function#to_s`, the compiler stages'
         function-type names item), `lb@1653:24` (`type quat`'s cross-file
         location), `lb@1958:16` (a member chain's third segment).
    3. **B4's other classes** — documentSymbol 5 (timing-coupled on the host: the
       module wrapper appears only once its module-name index is warm; the self's
       unwrapped outline matches the symbol set) and semanticTokens 5 (676
       differing positions left, from 952: import-alias receivers,
       `emit`-expanded declarations, variant payload fields, `typeParameter`
       renderings, scope-aware binding resolution), then diagnostic 2 (a *linter*
       residue: rule anchors differ and rules are missing — `redundant-unsafe`,
       `owning-release-leak` — not the emission order).
    4. Then C2–C5 (reference-index memory, note-document caching, the large-file
       soak, client behaviours), the deliberate-difference table in
       docs/lsp-design.md §8, and D2/D3 (audit determinism, scoreboard row).

    GATES for every commit (AGENTS.md): tools/bootstrap.sh -j 16 (fixed point +
    14/14), build/stage2/mtc test test/mt -I . (60/0), rake "cli:parity"
    (23/38/0 with the same diff *set*), ruby tools/sexpr_parity.rb lex -q
    (705/705) and parse -q (701 comparable / 0 differ),
    ruby tools/unused_import_parity.rb (609/608, the documented
    async_network_lobby residual), the LSP harness (30/30 + 4),
    ruby tools/lsp_recovery_probe.rb --check, the probe fixtures, and
    ruby tools/lsp_project_audit.rb --workspace … --only <method> for the class
    being worked.  Behaviour changes also get valgrind on the touched path (wrap
    the binary in a script that execs valgrind and pass it as `--self` to the
    audit tool, then check the log for Invalid/ERROR SUMMARY lines) plus the
    headless-Neovim smoke (`nvim --headless -u NONE -l tmp/nvim_hover_smoke.lua
    <binary> <file> <line> <col> …`).  C-backend changes additionally get the
    example sweeps: examples/*.mt 13/15 (the 2 async `__mt_loop_N` aborts are
    documented pre-existing), examples/sdl3 34/34, a raylib sample.
    Sync docs/self-host-plan.md §0k, docs/lsp-design.md, docs/lsp-parity-plan.md's
    counters and the plan ledger in the same commit; commit trailer:
    Co-authored-by: CommandCodeBot <noreply@commandcode.ai>.
    No hacks — fix root causes; never edit sources while a gate runs; run
    generated binaries as `timeout 10 bash -c 'ulimit -v 20000000; …'`.
```
