# LSP for real projects — parity, recovery and readiness plan

**Goal.** Make the self-hosted `mtc lsp` a daily driver on real projects: byte-parity
with the Ruby host on everything an editor can observe (diagnostics included), plus the
readiness properties parity alone does not test — cold start, steady-state memory, large
files, long sessions, real clients (Neovim/VS Code).

**Where we are** (branch `selfhost`, session 10, 2026-09-29): SimpleGame audit
6456 entries / **269 differ** (hover 32, definition/declaration 70 each,
typeDefinition 68, documentHighlight 14, diagnostic 2, documentSymbol 5,
semanticTokens 5, codeLens 1, implementation 1, workspace/symbol 1;
references 0); references-only audit **0**; synthetic harness 30/30
capabilities + 4 documented entries; probe fixtures 0 (references) / 0–8 (small
classes); bootstrap fixed point + 14/14; `cli:parity` 23/38/0.  Per-class
numbers measured with `--only` drift ±10 against the full matrix (the host
warms its caches as the audit proceeds); the full matrix is authoritative.

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

## Track B — the audit residue (269 entries, was 332)

- **B1. hover 80 → 32.** Session 10's batches closed the **17**
  analyzer-`<error>` locals with the renderings they exposed, then the member
  resolution those types uncovered (imported `extending` methods, builtin
  vector/matrix/quaternion fields, receiver projection), the variant arm
  constructors with their named-argument labels, and the module-qualified
  annotation renderings.  The residue (measured
  live, 32) is the classification the first batch recorded, minus the closed
  classes: **self-null** (enum/flags members in a declaration body, attribute
  targets/applications, `type parameter T`, the implicit `this`, prelude/
  inherent methods on builtin generics — the host's `BUILTIN_TYPE_METHOD_SIGNATURES`
  table and the attribute/type-parameter arms); **5** nullability (the host
  prints the *storage* type where the self prints the flow type); the tuple/alias
  renderings; and the host's member-location artifacts (`editable function
  release()` pointing at a different declaration, a field's location absent under
  a `public struct` header, a field read through a member *chain*).
- **B2. definition 70 / declaration 70 / typeDefinition 68 (full matrix).** Re-measure after
  each B1 fix (the member pipeline feeds all three); the remaining shapes are the same member
  cases plus the host's location artifacts.
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
`proc`-vs-`fn` hover rendering, hover 83 → 80), and session 10's five commits
(the host's C string-literal escaping; the analyzer's `<error>` locals and their
renderings; imported methods and builtin fields; the variant arm constructors
and their labels; the module-qualified annotation renderings — hover 80 → 32,
the full matrix 332 → 269).  Remaining, in order:

1. B1's residual classes, largest first: the self-null member/attribute/`this`/
   prelude-method arms (the host's `BUILTIN_TYPE_METHOD_SIGNATURES`, the
   attribute and `type parameter T` tables), then the 5 nullability renderings
   and the tuple/alias ones, then the member-location artifacts.
2. B2 (definition/declaration 70, typeDefinition 68 — re-measure with each hover
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

    Read first: docs/lsp-parity-plan.md (the focused plan — Track A CLOSED;
    Track B is at 269 entries, its live record in docs/self-host-plan.md §0k
    "Track B, second through fifth batch"), then
    ~/.commandcode/plans/finish-self-host-full-parity.md (the session-10 log),
    docs/lsp-design.md §8/§9, and AGENTS.md's "Self-Host Parity Program"
    section (gates, drift, fixtures).

    This session is LSP-only.  State at session-10 close: the SimpleGame full
    matrix is 6456 entries / 269 differ — hover 32, definition/declaration 70
    each, typeDefinition 68, documentHighlight 14, diagnostic 2, documentSymbol
    5, semanticTokens 5, codeLens 1, implementation 1, workspace/symbol 1;
    references 0; the harness 30/30 capability keys + the 4 documented entries;
    recovery probe OK; cli:parity 23/38/0; sexpr lex 705/705 and parse 701
    comparable / 0 differ; unused-import 609/608; bootstrap fixed point +
    14/14; test/mt 60/0.

    MEASUREMENT RULE: the full matrix is authoritative.  `--only <method>` runs
    drift ±10 per method (the host warms its caches as the audit proceeds), so
    quote per-class numbers from the full run and verify a fix by comparing
    *sets of differing keys*, not counts.

    STEP 1 — re-measure before touching anything:
      ruby tools/lsp_project_audit.rb --workspace /home/teefan/Projects/MilkTea/SimpleGame \
        --json tmp/audit-s11.json --max-diffs 0 --timeout 60
    then the references-only baseline (expect 0) and the harness:
      ruby tools/lsp_project_audit.rb --workspace … --only references --max-diffs 0 --timeout 60
      ruby tools/lsp_parity.rb record --server host --out tmp/lsp-host.json --stress
      ruby tools/lsp_parity.rb record --server self --out tmp/lsp-self.json --stress
      ruby tools/lsp_parity.rb compare tmp/lsp-host.json tmp/lsp-self.json
    Fast fixtures (session-10 scratch under tmp/, recreate if cleaned):
    probe-ws, probe2 (2 deliberate hovers), probe4-probe6 (0 for
    hover/definition/declaration/typeDefinition/references), hover-probe2
    (annotation `*From*`), hover-probe3/-4 (the analyzer `<error>` shapes),
    hover-probe5 (mat4 / heap / tuple / detach / span), fieldprobe, crash1 (the
    non-ASCII hover), eventprobe (event lowering), plus the valgrind wrapper
    (/tmp/mtc-vg.sh) and tmp/nvim_hover_smoke.lua.

    STEP 2 — work the hover residue largest-first, one commit per sub-class
    (rebuild + focused re-audit + the gates + docs/ledger synced in the same
    commit).  The 32 measured entries group as:

    1. Enum/flags/arm *member* arms (3) — the host's `member_info` arm renders
       `Type.member = value` and runs *ahead* of the name tables: `Kind.c = 6`
       (self null), `Kind.a = 0` (self answers a same-named local), and the
       member-access chain form `Result[int, int].success(value = T)`
       (`lb@568:15`; the bare-name arm already handles `success(value: T)`).
    2. Attributes, type parameters and `this` (5): `type parameter T` (the
       host's `type_parameter_hover_signature`), `attribute target callable`,
       `attribute [callable] traced(tag: str)` plus its Defined at, and the
       implicit receiver `parameter this: vec3 (immutable)`.
    3. Fields through a value / `this` / a member *chain* (6): `field radius:
       float` through `this`, `field top_edge: Edge` + `*From*` + a location for
       `r.top_edge` (the host's `member_access_chain_at`; the self's
       `dot_receiver_at` sees one segment only), the *declaration* hover
       `field parent: ptr[Node]?` + `*From node*` (the self renders the
       source-text type `ptr?` and adds a location), and the two `let b: int` /
       `let advance: ptr[int]` nulls.
    4. Nullability (5): the host prints the *storage* type where the self prints
       the flow type — `parameter handle: ptr[int]` vs `ptr[int]?`,
       `var handle: null` vs `ptr[int]?`, `let a: own[int]` vs `own[int]?`.
    5. Member-location artifacts (4): the `public struct`-field artifact (the
       host's `find_field_token_in_body` treats a field at a column ≤ the
       `struct` keyword's as a dedent, so a `public struct`'s fields carry no
       location and the self adds one), `editable function release()` /
       `take_damage` pointing at a different declaration, `parameter idx`
       missing its std/spatial.mt location, and `type quat`'s index location.
    6. Leftovers (5): `field check: fn ` (the host renders a union field's
       function type bare), a match-arm payload binding (`local p:
       Option[…].some payload`), a destructuring binding typed `int` by the host
       but bare by the self, a self-more `let _: void`, and `function destroy()`
       missing `-> void` (a *method* hover path that does not go through
       `format_fn_signature`).

    7. Then B2 — definition/declaration 70 and typeDefinition 68 (the same member
       pipeline; re-measure after every hover fix) — then B4 (documentHighlight
       14, documentSymbol 5, semanticTokens 5, diagnostic 2 = the lint emission
       order, codeLens 1, implementation 1, workspace/symbol 1).
    8. Then Track C readiness: index scope and cold start (C1), the
       reference-index memory bound (C2), note-document caching (C3), the
       large-file soak (C4), client behaviours (C5), and the deliberate-
       difference table in docs/lsp-design.md §8; D2/D3 (audit determinism,
       scoreboard row).

    Do not re-chase the session-10 crash: hovering a builtin type (`mat4`) used
    to kill the host-built binary with `string.as_str text must be valid UTF-8`
    (the host's `\xNN` C escapes absorbed the following hex digit); fixed in
    ad14ad89.  If a non-ASCII doc dies again, rebuild with the host and check
    `emit-c`'s literal bytes first.

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
