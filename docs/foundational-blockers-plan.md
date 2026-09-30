# Foundational blockers — the compiler-side work that gates the LSP residue

Status: **focused plan (session 14 close, 2026-09-30)**.  This is the durable copy;
the session copy (identical) is `~/.commandcode/plans/foundational-blockers-plan.md`.
Its session prompt is also pasted into
`~/.commandcode/plans/finish-self-host-full-parity.md`, and the LSP residue sections of
[lsp-parity-plan.md](./lsp-parity-plan.md) point here for their blockers.

## Why this plan exists

The SimpleGame LSP audit is at **18 differing entries** (hover 9, documentSymbol 5,
diagnostic 2, documentHighlight 1, semanticTokens 1).  Twelve of the eighteen are no
longer LSP code — they are **analyzer/linter facts** the LSP only measures, and the LSP
sessions keep ending with "documented residue" because the fix lives in another stage:

| LSP residue | Entries | Blocked on |
| --- | --- | --- |
| hover nullability four (`mst@25:7`, `@28:20`, `@205:7`, `@404:7`) | 4 | the host's *continuation* null refinement (a per-function nullability dataflow over a real CFG) |
| documentHighlight `lb@704:67` | 1 | the same snapshot machinery (which binding a completion snapshot carries at a line) |
| documentSymbol's refined locals (`memory_stress_test.mt`) | (part) | the same refined binding types |
| hover destructuring two (`lb@1861:23`, `lb@1931:25`) + match-arm payload (`lb@1915:25`) | 3 | stage 11c: arm payload structs + typed destructure bindings |
| `examples/async_network_lobby.mt`'s unused-import residual + prefer-let deltas | (repo-wide) | stage 11c |
| hover's `fn ` field (`lb@1127:9`) + the outline's function-type details | 1 | function-type **names** (`ty_function.name`, Phase 2 item 5) |
| diagnostic 2 | 2 | linter stages 11 + 11b (dead-assignment firing set + the per-rule table) |
| semanticTokens `identity` 275:40, `add` 1099:41 | (2 positions) | the analyzer's `callable_value_identifier_sites` |
| prefer-let repo-wide 507/606 | (repo-wide) | stage 11d: editable receivers in static extending methods |

Everything else in the tracker is LSP-side and already planned (the token scanner's
`callable_field_member_access?` and `dot_nested_type_member?`, the documentSymbol
enrichment, the readiness items C2–C5, the deliberate-difference table, D2/D3).

## F1 — the real control-flow graph (DONE, session 15; foundation for F2 and F3)

Landed `projects/mtc/src/mtc/semantic/control_flow/graph.mt` (the host's `Graph` +
`NullabilityFlow`-shaped solver: nodes with kind/statement/read/write sites, labelled
successor edges with null-test refinement maps, per-body fall-through targets for
`Termination`-shaped reachability) and `builder.build_graph_into` (the whole-body
binding-ID pass + the full `ControlFlow::Builder` statement walk).  `build_cfg_into`
keeps its narrower pre-scan for the linter; binding ids are 1-based so 0 can mean
"not a binding of this body".  Eight shape tests in `semantic_test.mt`; the record is
`docs/self-host-plan.md` §0k, "The real control-flow graph".

## F1 (original notes) — the real control-flow graph (foundation for F2 and F3)

**Host**: `lib/milk_tea/core/control_flow/builder.rb` (≈600 lines: nodes carrying
`kind`/`statement`/`reads`/`writes`, successor edges with refinement labels,
`build_block`/`build_statement` with `break_target:`/`continue_target:`,
`add_null_test_refinements` at `:541`), `graph.rb`, `dataflow.rb`
(`Dataflow.solve(direction:, initial:, join:, edge_transfer:, boundary_in:)`).

**Self today**: `projects/mtc/src/mtc/semantic/control_flow/builder.mt` is only a
binding-ID pre-scan (`CfgNode` has an `id`; `Cfg` has `nodes`/`binding_map`/`next_id`;
its own header says "a full graph with edges, read/write sets, and successor links is
not needed by the existing lint rules"); `projects/mtc/src/mtc/linter/cfg.mt` is
backward AST walks ("No graph edges are needed — the CFG is implicit in the AST
structure"); the analyzer's refinements are branch-local (`flow_refinements`
`analyzer.mt:2388`, `null_test_refinements` `:2428`, applied at `:2284-2306`).

**Change**: extend `semantic/control_flow/` into the host's graph shape — `CfgNode(id,
kind, statement, reads, writes)`, `CfgEdge(from, to, refinement)`, block/statement
building with break/continue targets and the null-test edge labels — and add the
dataflow solver over it.  Keep `build_cfg_into`'s existing signature/behaviour for the
linter's current callers (the binding-ID map must stay identical), and add the graph
behind it.  This one graph then serves F2 (nullability) and F3 (dead-assignment), and
later the host's definite-assignment/termination/reachability passes.

**Verify**: new `projects/mtc/test/semantic_test.mt` cases per shape (if/else join,
terminating then-branch, while/for back-edges, match arms, defer/unsafe nesting),
plus the existing suites (`test/mt` 60/0, the bootstrap fixed point).

## F2 — the nullability continuation refinement (DONE, session 15)

Landed, with three measured findings that correct this plan's model.  (1) The
continuation is applied **for the next statement at the end of the current one**
(the host's `apply_nullability_continuation_refinements!` order), not before each
statement — that ordering is what makes the state recorded at a guard line
already carry the narrowing.  (2) `flow_refinements`' falsy side of `and` (and
truthy side of `or`) is `{}` in the host, unlike the *builder's*
`null_check_pairs` left-only trick — the `mst@404:7` entry is the continuation's
work, not a falsy refinement.  (3) The record's consumer must scan in
*recording* order (the host's `latest_completion_snapshot`), not by greatest
position: a post-statement record at an earlier line still answers a later
cursor.  The if-arm's `keep_unassigned`/`intersect_post_refs` model was replaced
by the host's terminating-branch rule.  The record is `docs/self-host-plan.md`
§0k, "The nullability continuation refinement"; the four hover entries closed in
the full matrix (**17 → 13**, added 0).

## F2 (original notes) — the nullability continuation refinement

**Host**: `control_flow/nullability_flow.rb` (`NullabilityFlow.solve`: forward dataflow
whose **join is set intersection**, `edge_transfer` applying `:non_null`/nullable edge
refinements and subtracting the node's writes; `Result#nonnull_before(stmt)`),
`semantic_analyzer/nullability.rb:69-90`
(`apply_nullability_continuation_refinements!`: after each statement, look up
`nonnull_before(next_stmt)` and re-bind those bindings to their non-null storage type in
the scopes), `flow_refinement.rb:289`.

**Self today**: only the taken branch is refined (`flow_refinements` +
`apply_refinements_to_frame`/`intersect_post_refs` at `analyzer.mt:2284-2306`); the
statement *after* a terminating `if x == null: return` guard keeps the declared
`T?` type.  That is exactly the hover residue (`mst` 25:7/28:20/205:7/404:7 print
`ptr[int]?` where the host prints the refined `ptr[int]`/`null`), and the same
mechanism decides the completion snapshot a label token resolves to
(documentHighlight `lb@704:67`).

**Change**: port `NullabilityFlow` over F1's graph (statement→node map, in/out states as
binding-id sets, intersection join, the edge transfer), then before checking each
statement apply the non-null set to the scope frame (the self's analogue of
`apply_nullability_continuation_refinements!`).  The refined types must land in the same
records the LSP reads (`local_decl_types`, `resolved_expr_types`, and — new — whatever
per-reference-site record the hover/outline need; add that record here, not in the LSP).

**Verify**: `ruby tools/sexpr_parity.rb lower -q -j 16` (Phase 2 item 14's two files —
`data_structures.mt`, `reflection_advanced.mt`), a `test/mt` case per guard shape
(`if x == null: return …` then use; `if x != null: use`, then the join), and the LSP
audit: `--only hover` first, then the **full matrix** (the host's token/hover answers
for facts-dependent requests differ between `--only` and full runs; verify with
`tools/lsp_audit_diffs.rb --compare` — added must be 0).

## F3 — linter stages 11 + 11b (closes diagnostic 2)

**11 — `dead-assignment` firing set** (in-flight plan correction #1): the host has the
rule (`lib/milk_tea/tooling/linter/flow_rules.rb:6-37`, gated on `full_tier?`; the LSP
always uses that tier) with gates the self lacks — exclude `:call_argument` and
`:declaration` write origins, require `readable_bindings` + `locally_declared`, key
liveness by **binding id**.  Build on F1's graph, not `linter/cfg.mt`'s path-insensitive
walk.  Evidence: host 0 vs self 48 on `language_baseline.mt`.

**11b — the per-rule table**: `rake "parity:scoreboard"` prints the per-rule lint table
on `language_baseline.mt`; run the same comparison on `memory_stress_test.mt` (the LSP
audit's second diagnostic file).  Close, rule by rule:
- anchors: `redundant-return` 325:4-10 (self 4-5), `redundant-type-annotation` 422:8-12
  (self 8-13), `prefer-inline-if` / `prefer-conditional-expression` 474:4-5 (self 7-8),
  `owning-release-double` at the binding name (335:33) not the declaration (335:4);
- missing: `redundant-unsafe` (×4), `owning-release-leak`, `constant-condition` — the
  code strings exist in `linter.mt` already, so re-measure first: the delta is the
  trigger/message/position, not the code;
- extra: `prefer-own-ptr` ×2.

**Verify**: the per-rule table on both files (counts, messages, severities, positions),
`unused_import_parity.rb` (609/608 + any improvement), and the LSP audit's diagnostic
entries (the full matrix).

## F4 — stage 11c: payload structs and typed destructure bindings

Design (from the multi-session plan; **do not repeat the reverted bind-to-T model**):
1. register the prelude payload structs (`Option_some{value: T}`, `Option_none{}`,
   `Result_success{value: T}`, `Result_failure{error: E}`) at `register_prelude_type`,
   and export variant arm *fields* on `ModuleBinding` for user/imported variants;
2. at a `match`, compute the scrutinee type once, substitute the variant's declared type
   params with the scrutinee's type arguments, bind the arm name to the substituted
   payload struct (the host's `Types::VariantArmPayload`,
   `statements.rb:800-850`), and let `p.value` resolve through the normal struct-field
   path; expression matches (`analyzer.mt`'s `expr_match` arm) get the same treatment;
3. type **destructure** bindings from the initializer (`let (a, b) = tuple`,
   `let Vec2(x, y) = v`) instead of `ty_error` (`check_local`'s destructure arm,
   `analyzer.mt:2944-2956`), and record the per-name types where the LSP can read them
   (a new `Analysis` map/vec beside `local_decl_types`);
4. the LSP consumers, same commit or the next: `navigation.mt`'s `local_type_at_line`
   and the arm-binding hover (which returns empty today), and `symbols.mt`'s locals/arms.

**Verify**: `unused_import_parity.rb` (the `async_network_lobby` residual closes),
prefer-let repo-wide (the 507/606 recorded in the stage-6 log should rise), `test/mt`,
the bootstrap fixed point, and the LSP audit's three hover entries (full matrix).

## F5 — function-type names (Phase 2 item 5)

Add `name` to `ty_function` (`semantic/types.mt:50`), thread it through every
constructor/matcher (`analyzer.mt:1442,3378,3922,4112`; `lowering.mt:4547,5880,9191,9356`),
set it where an identifier resolves to a function (host
`semantic_analyzer/function_binding.rb:185`, `types.rb:1309/1341`), and render it in
`sexpr.mt:552`.  Broad mechanical change, one commit, bootstrap-gated.  The LSP then
renders the host's `fn ` (`Types::Function#to_s`) for the `lb@1127:9` hover and the
outline's function-type details.

**Verify**: `sexpr_parity lower -q` (item 6 in §0j), the LSP audit's hover entry, the
full compiler gate set (this touches the C-backend path indirectly — run the example
sweeps: `examples/*.mt` 13/15 documented, `examples/sdl3` 34/34, a raylib sample).

## F6 — stage 11d: the generic-context gate for `prefer-let` (DONE, session 15)

**Measured root cause (session 15, 2026-09-30).**  The planned "editable receivers in
static extending methods" diagnosis was wrong; the divergence on `std/vec.mt` (self 2,
host 0) and the prefer-let sweep was the *generic-context gate*: the host's
`allow_prefer_let: var && !generic_function_context?` treats a method inside an
`extending Type[T]:` block as generic (`extending_block_generic?`), and the self's scope
pass carried the counter without ever incrementing it.  Landed: `visit_decl` now raises
`generic_function_depth` for a function with type parameters and for every method of a
generic extending block.  `std/vec.mt` matches the host; the probe shape reproduces the
host's set exactly.  The residual prefer-let sweep (self-only 121 over `std/`, host 0) is
a *ty_error-receiver* residue: the bindings are match-arm payload fields and destructured
names, so no editable-receiver record exists — F4 (stage 11c) unblocks them.

## F6 (original notes) — stage 11d: editable receivers in static extending methods

`var result = Vec[T].create(); result.reserve(…)` inside `extending Vec[T]:`'s static
method must resolve `Vec.reserve`'s `editable` kind (host-clean `std/vec.mt`).  Small
analyzer fix; verify with `std/vec.mt` and the prefer-let sweep.

## F7 — the analyzer's callable-value record (2 of semanticTokens' 5 positions)

The host marks a bare function name's site only when it is used as a value **with an
expected function type** (`expressions.rb:356` → `record_callable_value_identifier_site`;
the `callable_of(identity)` shape is *not* recorded, which is why the host says
`variable:0` at `lb@275:40`).  In the self, the place that recognises the shape is
`argument_inference_type` (`analyzer.mt:4118-4145`, where a bare name resolves to
`ctx.functions`' signature); record `line*10000+column` there (only when the enclosing
parameter's expected type is a function/proc type), expose the set on `Analysis`, and
make the token scanner's value arm render `function` only for a recorded site (the
scanner currently says `function` for any name in `facts.functions`).

**Verify**: the position-keyed token diff (`ruby tmp/tok_self.rb` + `ruby tmp/tok_diff.rb`
against a full-run host reference, or `tools/lsp_token_diffs.rb` on a fresh audit) and
the full matrix.

## F8 — the LSP-side closures (after the facts land)

1. **semanticTokens (2 positions → class closes)**: the token scanner's
   `callable_field_member_access?` (a member call on a struct field of `fn`/`proc` type
   is a `property`) and `dot_nested_type_member?` (a nested type name renders `type`);
   the host references are `semantic_tokens.rb:1035-1056` and `:1094-1109`.
2. **documentSymbol (3–4 entries)**: the host's enrichment — merging an `extending`
   block's symbol into its type's symbol with the receiver named as written
   (`rl.Color` block → `rl`), the `when`-branch declarations in the AST walk
   (`flatten_module_declarations`' analogue in `symbols.mt`), and the refined locals F2
   produces.
3. **hover**: `type quat` (`lb@1653:24`) stays documented (the host's asynchronous
   definition warmup); the deliberate-difference table (`docs/lsp-design.md` §8) gets
   the documentSymbol first-file race and the references pacing entry.

## F9 — readiness foundations (C2/C3)

`ScanFacts` is never released (session 14 extended it with the binding vector and the
type-parameter scopes); the reference index keeps an owned copy of every noted
document's text (C2); `note_document_tokens` re-reads and re-hashes per request (C3).
Bound both and cache by (mtime, size)/content hash; verify with a long-session soak and
valgrind.

## Order

`F1 → F2` (the largest LSP pull), `F3` interleaved (different files, one commit per
rule group), `F6` (small, slots anywhere), `F4 → F5 → F7`, then `F8` (LSP-only
sessions), `F9` last.  One commit per item; docs + ledger synced in each.

## Gates

- **Compiler-side** (F1–F7): `tools/bootstrap.sh -j 16` (fixed point + 14/14),
  `build/stage2/mtc test test/mt -I .` (60/0), `rake "cli:parity"` (23/38/0),
  `ruby tools/sexpr_parity.rb lex -q` (705/705) + `parse -q` (701/0) + `lower -q -j 16`
  (the counter the item moves), `ruby tools/unused_import_parity.rb` (609/608, and the
  residual should close with F4), `rake "parity:scoreboard"` (the per-rule lint table),
  and for C-backend-touching changes the example sweeps (`examples/*.mt` 13/15
  documented, `examples/sdl3` 34/34, a raylib sample).  Behaviour changes get valgrind
  on the touched path and the headless-Neovim smoke where the LSP path moves.
- **LSP-side** (every item that should move the audit): the **full matrix**
  (`tools/lsp_project_audit.rb --workspace ~/Projects/MilkTea/SimpleGame --json …`,
  ~14 min — never quote `--only` for facts-dependent classes), verified with
  `tools/lsp_audit_diffs.rb --compare` (added must be 0), plus the harness (30/30 + 4),
  the recovery probe, the fixtures, valgrind, and the Neovim smoke.
- Never edit sources while a gate runs; rebuild before measuring; run generated
  binaries as `timeout 10 bash -c 'ulimit -v 20000000; …'`.

## Session prompt (copy-paste)

```
Continue the Milk Tea self-host compiler work in /home/teefan/Projects/Ruby/mt-lang
    (branch `selfhost`). Rebuild before measuring:
      ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o build/stage2/mtc

    Read first: docs/foundational-blockers-plan.md (the focused plan — the ranked
    blockers F1–F9; a copy is at ~/.commandcode/plans/foundational-blockers-plan.md),
    then ~/.commandcode/plans/finish-self-host-full-parity.md (the multi-session
    ledger + the session-14 log), docs/self-host-plan.md §0k ("Track B, sixteenth
    and seventeenth batch" for the current LSP residue), docs/lsp-parity-plan.md,
    and AGENTS.md's "Self-Host Parity Program" section (gates, drift, fixtures).

    This session is a COMPILER-STAGES session (analyzer/linter) with LSP
    verification: 12 of the 18 LSP audit entries are analyzer/linter facts the LSP
    only measures.  State at session-14 close: the SimpleGame full matrix (6456
    entries) is at 18 differ — hover 9, documentSymbol 5, diagnostic 2,
    documentHighlight 1, semanticTokens 1 (its streams differ in 5 positions of
    13576); definition/declaration/typeDefinition/implementation/references,
    codeLens and workspace/symbol are 0.  Everything else green: the harness 30/30
    + the 4 documented entries; recovery probe OK; cli:parity 23/38/0; sexpr lex
    705/705 and parse 701 comparable / 0 differ; unused-import 609/608 (the
    async_network_lobby residual — F4 should close it); bootstrap fixed point +
    14/14; test/mt 60/0; the probe fixtures unchanged.

    STEP 1 — re-measure before touching anything (in the background):
      ruby tools/lsp_project_audit.rb --workspace /home/teefan/Projects/MilkTea/SimpleGame \
        --json tmp/audit-s15.json --max-diffs 0 --timeout 60     # ~14 min
      ruby tools/lsp_audit_diffs.rb tmp/audit-s15.json
      rake "parity:scoreboard"          # the per-rule lint table (F3's baseline)
      ruby tools/unused_import_parity.rb    # ~20 min, start it early
    Expect 18 differ with the same class split (the documentSymbol wrapper race can
    move data_structures by one entry; the token positions are 5).  Fast fixtures
    (no regressions): tmp/probe-ws, probe2 (7 diffs), probe4–probe6, fieldprobe,
    thisprobe, defprobe, crash1, hover-probe2/-3/-4/-5, eventprobe — compare with
    `ruby tools/lsp_audit_diffs.rb --compare tmp/audit-s14-<ws>.json <new>`.

    STEP 2 — the blockers, in order (one commit each; the plan has the host and self
    references and the per-item evidence):

    F1. **The real control-flow graph** (`projects/mtc/src/mtc/semantic/control_flow/`):
        extend the binding-ID pre-scan into the host's graph
        (`lib/milk_tea/core/control_flow/builder.rb`: nodes with read/write sets,
        successor edges with refinement labels, break/continue targets,
        `add_null_test_refinements`) + a `Dataflow.solve`-shaped solver.  Keep
        `build_cfg_into`'s behaviour for the linter's callers.  Unit tests per shape.

    F2. **Nullability continuation refinement** (closes hover's nullability four,
        documentHighlight's survivor, documentSymbol's refined locals, `lower` item
        14): port `control_flow/nullability_flow.rb` (intersection join, edge
        transfer) and apply the non-null set before each statement's check, the
        analogue of `semantic_analyzer/nullability.rb:69-90`.  The refined types must
        reach the same records the LSP reads.  Verify with `sexpr_parity lower -q`
        and then the FULL LSP matrix (`--compare`, added must be 0) — the hover
        entries at `mst@25:7`, `@28:20`, `@205:7`, `@404:7` and
        `lb@704:67` are the target.

    F3. **Linter stages 11 + 11b** (closes diagnostic 2): `dead-assignment`'s firing
        set on F1's graph (exclude `:call_argument`/`:declaration` origins, require
        `readable_bindings` + `locally_declared`, key liveness by binding id; host
        `lib/milk_tea/tooling/linter/flow_rules.rb:6-37`), then the per-rule table on
        `language_baseline.mt` AND `memory_stress_test.mt`: anchors
        (`redundant-return` 325:4-10, `redundant-type-annotation` 422:8-12,
        `prefer-inline-if`/`prefer-conditional-expression` 474:4-5,
        `owning-release-double` at the binding name), missing rules
        (`redundant-unsafe` ×4, `owning-release-leak`, `constant-condition` — the
        codes exist, re-measure the triggers), extra (`prefer-own-ptr` ×2).

    F6. **Stage 11d** (small, can go first): editable receivers in generic/static
        extending methods (`var result = Vec[T].create(); result.reserve(…)` inside
        `extending Vec[T]:`); verify on `std/vec.mt` + the prefer-let sweep.

    F4. **Stage 11c** (closes hover's destructuring two + match-arm payload, the
        async_network_lobby unused-import, prefer-let deltas): prelude payload
        structs + arm bindings to the substituted payload struct (host
        `Types::VariantArmPayload`, `statements.rb:800-850`) + typed destructure
        bindings (`check_local`'s destructure arm; do NOT repeat the reverted
        bind-to-T model) + a per-name type record the LSP's hover/outline read
        (`navigation.mt` `local_type_at_line`, `symbols.mt`).

    F5. **Function-type names** (Phase 2 item 5; closes hover's `fn `): add `name` to
        `ty_function`, thread it, set it from the callee, render it in `sexpr.mt:552`;
        then the LSP renders `fn ` like the host's `Types::Function#to_s`.

    F7. **Callable-value record** (2 of semanticTokens' 5 positions): record the site
        where a bare function name is used as a value with an expected function type
        (`argument_inference_type`, `analyzer.mt:4118`), expose it on `Analysis`, and
        make the token scanner require it for `function`.

    Then, in LSP-only follow-up commits: the scanner's
    `callable_field_member_access?` + `dot_nested_type_member?` (closes
    semanticTokens), the documentSymbol enrichment (the extending-block merge /
    `rl.Color` naming / the `when`-branch declarations), the hover/outline consumers
    of F4's records, and F9's readiness items (ScanFacts release, the reference
    index's text bound, `note_document_tokens` caching).

    GATES for every commit: tools/bootstrap.sh -j 16 (fixed point + 14/14),
    build/stage2/mtc test test/mt -I . (60/0), rake "cli:parity" (23/38/0),
    ruby tools/sexpr_parity.rb lex -q (705/705) and parse -q (701/0) and — for the
    lowering-touching items — lower -q -j 16,
    ruby tools/unused_import_parity.rb (609/608, start it early),
    rake "parity:scoreboard" (the per-rule lint table where F3 moves),
    ruby tools/lsp_parity.rb record/compare (30/30 + the 4 documented entries),
    ruby tools/lsp_recovery_probe.rb --check, the probe fixtures, and the FULL LSP
    matrix for any item that should move the audit (never `--only` for
    facts-dependent classes; verify with lsp_audit_diffs.rb --compare — added must
    be 0).  C-backend-touching changes also get the example sweeps: examples/*.mt
    13/15 (the 2 async aborts documented), examples/sdl3 34/34, a raylib sample.
    Behaviour changes get valgrind on the touched path + the headless-Neovim smoke
    (`nvim --headless -u NONE -l tmp/nvim_hover_smoke.lua <binary> <file> <line> <col>`).
    Sync docs/self-host-plan.md, docs/lsp-design.md, docs/lsp-parity-plan.md and the
    plan ledger in the same commit; commit trailer:
    Co-authored-by: CommandCodeBot <noreply@commandcode.ai>.
    No hacks — fix root causes; never edit sources while a gate runs; rebuild before
    measuring; run generated binaries as
    `timeout 10 bash -c 'ulimit -v 20000000; …'`.
```
