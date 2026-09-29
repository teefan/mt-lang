# LSP for real projects — parity, recovery and readiness plan

**Goal.** Make the self-hosted `mtc lsp` a daily driver on real projects: byte-parity
with the Ruby host on everything an editor can observe (diagnostics included), plus the
readiness properties parity alone does not test — cold start, steady-state memory, large
files, long sessions, real clients (Neovim/VS Code).

**Where we are** (branch `selfhost`, session 10, 2026-09-29): SimpleGame audit
6456 entries / **259 differ** (hover 44, definition/declaration 66 each,
typeDefinition 65, documentHighlight 14, diagnostic 2, documentSymbol 5,
semanticTokens 5, codeLens 1, implementation 1, workspace/symbol 1);
references-only audit **0**; synthetic harness 30/30 capabilities + 4 documented
entries; probe fixtures 0 (references) / 0–8 (small classes); bootstrap fixed
point + 14/14; `cli:parity` 23/38/0.

**Track B, second and third batches** (session 10): hover **80 → 44** and the
class's knock-ons — definition/declaration 72 → 66, typeDefinition 70 → 65,
references **9 → 0** — by typing the analyzer's `<error>` locals (unary `~`,
tuple literals, `Type[args].arm(…)` instances, imported specialization calls,
builtin static receivers, event methods, `get`, `detach`) and the renderings
that followed (guarded-local narrowing, module-less builtin types, the function
signature shape, the builtin arms' definition-index location), then the member
resolution the new types exposed (imported modules' `extending` methods —
`vec3.cross` in std.linear_algebra — the builtin vector/matrix/quaternion field
tables, and receiver projection through `ref`/`ptr`/`own`).  The host's C
string-literal escaping was fixed first: its `\xNN` escapes absorbed following
hex digits, so the host-built self binary crashed on any non-ASCII hover doc
(`mat3`/`mat4`).  The record is `docs/self-host-plan.md` §0k, "Track B, second
batch" and "third batch"; the residual classification is unchanged (the
`*From*` source-text renderings, the self-null member/attribute/`this`/prelude
arms, nullability, and the member-location artifacts).

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

## Track B — the audit residue (259 entries, was 332)

- **B1. hover 80 → 44.** Session 10's batches closed the **17**
  analyzer-`<error>` locals with the renderings they exposed, then the member
  resolution those types uncovered (imported `extending` methods, builtin
  vector/matrix/quaternion fields, receiver projection).  The residue (measured
  live, 44) is the classification the first batch recorded, unchanged in shape:
  **15** where the
  `*From <module>*` line differs (the annotation is rendered from the source text,
  so an import alias leaks in as `vec` instead of `std.vec`, and a specialization
  like `SoA[Point, 4]` loses its owner module); **19** self-null (enum/flags
  members in a declaration body, bare variant-arm constructors and their
  named-argument labels, attribute targets/applications, `type parameter T`,
  fields read through a `ref` receiver, the implicit `this`, prelude/inherent
  methods on builtin generics — the host's `methods_for_receiver_type` merges
  `facts.methods` and `BUILTIN_TYPE_METHOD_SIGNATURES`); **5** nullability (the
  host prints the *storage* type where the self prints the flow type); 3
  tuple/alias renderings (`type Result = Result`, `(int, int)`); the rest are the
  host's member-location artifacts (`editable function release()` pointing at a
  different declaration, a field's location absent under a `public struct`
  header).
- **B2. definition 66 / declaration 66 / typeDefinition 65.** Re-measure after each B1 fix
  (the member pipeline feeds all three); the remaining shapes are the same member cases
  plus the host's location artifacts.
- **B3. references 0 (closed, session 10).** The 9 full-matrix entries were the
  hover residue's knock-on (files the host's hovers tokenized and the self's did
  not); typing the analyzer's `<error>` locals closed them.
- **B4. small classes.** documentHighlight 14, documentSymbol 5, semanticTokens 5,
  diagnostic 2, codeLens 1, implementation 1, workspace/symbol 1 — independent, mostly
  rendering/order (the two remaining `diagnostic` entries are lint *ordering*: the host
  interleaves scope/flow/whole-file rules per function, the self is pass-major).

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
`proc`-vs-`fn` hover rendering, hover 83 → 80), and session 10's three commits
(the host's C string-literal escaping; the analyzer's `<error>` locals and their
renderings — hover 80 → 46, definition/declaration 72 → 67, typeDefinition
70 → 66, references 9 → 0; then imported methods and builtin fields — hover
46 → 44, definition/declaration 67 → 66, typeDefinition 66 → 65).  Remaining,
in order:

1. B1's residual classes, largest first: the variant-arm constructors and their
   named-argument labels (the host's `find_variant_arm_in_types` and
   `variant_arm_constructor_info`), the self-null member/attribute/`this`/
   prelude-method arms, the 15 `*From*` module renderings, then the 5
   nullability renderings and the tuple/alias ones.
2. B2 (definition/declaration 66, typeDefinition 65 — re-measure with each hover
   fix), then B4 (the small classes; `diagnostic` is the
   lint emission order).  B3 is closed (references 0).
3. C1 → C2/C3 → C4/C5 (readiness), with the deliberate-difference table in
   `docs/lsp-design.md` §8; D2/D3 (audit determinism, scoreboard row).

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

    Read first: docs/lsp-parity-plan.md (the focused plan — Track A is CLOSED,
    Track B's classification is in docs/self-host-plan.md §0k under "Track B,
    first batch"), then ~/.commandcode/plans/finish-self-host-full-parity.md
    (ledger + the session-9 log), docs/lsp-design.md §8/§9,
    docs/lsp-performance.md, and AGENTS.md's "Self-Host Parity Program" section
    (gates, drift, fixtures).

    This session is LSP-only.  State at session-9 close: recovery parity OK
    (`ruby tools/lsp_recovery_probe.rb --check`); the SimpleGame audit is at
    332 differing entries — hover 80, definition/declaration 72 each,
    typeDefinition 70, documentHighlight 14, references 9, documentSymbol 5,
    semanticTokens 5, diagnostic 2, codeLens 1, implementation 1,
    workspace/symbol 1; references-only 0; the harness 30/30 capability keys +
    the 4 documented entries; cli:parity 23/38/0.

    Work Track B largest-first, one commit per sub-class, re-measuring with
      ruby tools/lsp_project_audit.rb --workspace /home/teefan/Projects/MilkTea/SimpleGame \
        --json tmp/audit-<item>.json --max-diffs 0 --timeout 60 --only hover
    (and --only definition / declaration / typeDefinition after each hover fix —
    the member pipeline feeds all three).  Fast repro fixtures from session 9:
    tmp/hover-probe2 (From-module renderings), tmp/hover-probe3,
    tmp/hover-probe4 (the analyzer-`<error>` shapes).

    1. hover's 17 analyzer-`<error>` locals (the biggest single shape).  The
       analyzer's infer_expr_inner leaves these `<error>`, so the hover prints
       `let x: <error>`: specialized calls (`heap.must_alloc[ubyte](64)`),
       builtin-generic arm construction (`Result[int,int].success(value = 7)`,
       `Option[float].some(value = 5)`), unary ops on a flags value (`~mask_a`),
       tuple literals (`(1, 2)` — the host builds
       `Types::Registry.tuple(element_types, field_names:)` at
       semantic_analyzer/expressions.rb:227-250), `Result` method calls
       (`err_val.error()`).  Fix the analyzer recording, not the hover.
    2. hover's 15 `*From <module>*` entries: the annotated local type is
       rendered from the AST source text (`annotated_type_text` +
       `qualified_name`), so an import alias leaks in (host `*From std.vec,
       kinds*` where the self says `*From vec*`) and a specialization
       (`SoA[Point, 4]`) loses its owner module.  The host renders the *resolved*
       type — module-qualified, type arguments included — and then shortens it
       (`hover.rb`'s `shorten_qualified_types`).  Repro: tmp/hover-probe2.
    3. hover's 19 self-null entries: enum/flags members in a declaration body
       (`Mask.a = 1`), bare variant-arm constructors and their named-argument
       labels (`Result.success(value: T)`, `value: T` — the host's
       find_variant_arm_in_types), attribute targets and applications
       (`attribute target callable`, `attribute [callable] traced(tag: str)`),
       `type parameter T`, fields read through a `ref` receiver, the implicit
       `this` (`parameter this: vec3 (immutable)`), and prelude/inherent methods
       on builtin generics (`Option.unwrap()`, `vec3.cross(v)` — port the host's
       `methods_for_receiver_type` = `facts.methods` + imported modules' methods
       + `BUILTIN_TYPE_METHOD_SIGNATURES`).
    4. hover's 5 nullability renderings (the host prints the *storage* type:
       `parameter handle: ptr[int]` and `var handle: null (mutable)` where the
       self prints the flow type), the tuple/alias renderings
       (`type Result = Result` plus its From std.result line, `(int, int)`), and
       `field name: cstr` (the host omits `Defined at` for a field).
    5. Then B2 — definition/declaration 72 and typeDefinition 70 (the same member
       pipeline; re-measure after every hover fix) — then B3 (references 9), then
       B4 (documentHighlight 14, documentSymbol 5, semanticTokens 5, diagnostic 2
       = the lint emission order, codeLens 1, implementation 1,
       workspace/symbol 1).
    6. Then Track C readiness: index scope and cold start (C1), the
       reference-index memory bound (C2), note-document caching (C3), the
       large-file soak (C4), client behaviours (C5), and the deliberate-difference
       table in docs/lsp-design.md §8; D2/D3 (audit determinism, scoreboard row).

    Optional, bounded recovery follow-up (docs/self-host-plan.md §0k row 3): the
    remaining two gaps in `stress/unterminated-source+diagnostic` — the lexer's
    `unclosed grouping delimiter` lex/error carries no position (`0:0` where the
    host reports the opening delimiter's), and the host's parameter parse
    continues past a bad parameter name (adding `expected ')' after parameters`
    and a top-level `expected declaration`) where the self stops after
    `expected parameter name`.

    GATES for every commit (AGENTS.md): tools/bootstrap.sh -j 16 (fixed point +
    14/14), build/stage2/mtc test test/mt -I . (60/0), rake "cli:parity" (23/38/0),
    ruby tools/sexpr_parity.rb lex -q (705/705) and parse -q (701 comparable /
    0 differ), ruby tools/unused_import_parity.rb (609/608, the documented
    residual), ruby tools/lsp_parity.rb record --server host|self --stress then
    compare (30/30 capability keys + 4 documented entries),
    ruby tools/lsp_recovery_probe.rb --check, the probe fixtures (tmp/probe-ws,
    probe2, probe4-probe6), and
    ruby tools/lsp_project_audit.rb --workspace … --only <method> for the class
    being worked; behaviour changes also get valgrind on the touched path plus the
    headless-Neovim smoke.  Sync docs/self-host-plan.md §0k, docs/lsp-design.md,
    docs/lsp-parity-plan.md's counters and the plan ledger in the same commit;
    commit trailer: Co-authored-by: CommandCodeBot <noreply@commandcode.ai>.
    No hacks — fix root causes; never edit sources while a gate runs; run generated
    binaries as `timeout 10 bash -c 'ulimit -v 20000000; …'`.
```
