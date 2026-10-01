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
| diagnostic 2 — the emission **order** | (2 files) | the linter's two-walk merge (F3's restructure below) |
| diagnostic 2 — `constant-condition` | 4 (lb) | the source-line `condition_span`, the `branch`/`loop` message and a `ConstantPropagation` port |
| diagnostic 2 — `owning-release-double`/`-leak` | 3 (mst) | the CFG release path (`classify_cfg_nodes`/`find_reachable_release`) and the released binding's `symbol_name` |
| documentHighlight `lb@704:67` | 1 | the host's warm-facts snapshot carry-forward — **documented** (the self matches the host's cold answer byte for byte); `docs/lsp-design.md` §8 |
| hover `type quat` `lb@1653:24` | 1 | the definition index's coverage of a never-opened std module (`extending quat:`); `apply_hover_index_location` is already on the arm |
| F9 readiness: `ScanFacts` release, the index's document texts, `note_document_tokens` caching | (repo-wide) | valgrind reads ~91 MB "definitely lost" over an LSP drive (0 errors) |

Closed since the table above was written: the nullability four (F2), the
documentSymbol class (F8.2), semanticTokens (F7 + F8.1), the `fn ` field (F5),
the destructuring/payload hovers and the unused-import/prefer-let residuals (F4),
the favourite `prefer-let` gate (F6), and every per-rule **count** in the linter
(F3 part 2 — `rake parity:scoreboard` reads 0 rules with a count mismatch, up from 8).

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

**PART DONE (session 16): `dead-assignment` over the graph.**  `graph.mt` gained the
backward-union `LivenessFlow` (`reads | (live_out - writes)`, `live_out_has`) and
`graph_declared_keys`; `lint_dead_assignment` builds F1's graph per body, solves
liveness, and emits the host's firing set by ascending node id (the host's order).
`linter/cfg.mt` is deleted.  Measured: `language_baseline.mt` dead-assignment **16 → 0**
(host 0), warning total 123 → 107.  Record: `docs/self-host-plan.md` §0k, "Liveness over
the graph".

**NEW BLOCKER (session 16, measured): the diagnostic class compares *arrays*.**
The host emits in visitor order — statement rules inline, a scope's
`unused-local`/`unused-param`/`prefer-let` at that scope's pop *inside* the walk, and the
per-function flow rules (`dead-assignment`, `unreachable`, `constant-condition`, the
release rules, `prefer-let-else`, `prefer-var-else`, `redundant-return`) at the end of
that function; `missing_return` after them.  The self emits all visitor warnings for the
file, then a whole-file scope pass, then whole-file rule passes, so equal *sets* still
differ as arrays (lb: host starts `285 unused-local, 325 redundant-return, 333
unused-param …`, self starts `325, 422, 474 …`; mst: host emits `441 redundant-unsafe`
before `440 owning-release-leak`).  Closing diagnostic 2 requires restructuring the
self's linter to that walk order (scope pops inside the walk, flow rules per function) —
on top of the per-rule deltas below.

**PART DONE (session 17): the anchor/message/firing rows.**  Closed, each
verified with `tmp/diag_probe.rb` (the entry disappears) and
`tmp/lint_table.rb` (counts unchanged): `noop-compound-assignment`,
`self-comparison`, `redundant-return`, `redundant-type-annotation` (plus its
nullable gate), `unreachable-code` (span + message), `prefer-inline-if`,
`prefer-conditional-expression` (messages, anchors, loop-depth gate,
visually-inline gate), `prefer-or-pattern` (the member-access column),
`prefer-is-variant` (`desugared_from_is`), the scope warnings' name lengths
(`ScopeWarning.length`), the destructuring-name credit, `reserved-primitive-name`
(the host's exact `RESERVED_VALUE_TYPE_NAMES` — `ptr` is *not* in it) and
`prefer-own-ptr`'s message, and `redundant-unsafe` (the rule was missing: the
analyzer's `Context.unsafe_statement_lines`/`required_unsafe_lines` +
`mark_required_unsafe` at the five require-unsafe sites, the
`Analysis.unsafe_statement_lines` record and the visitor's emission at the
`unsafe:` node with the generic-context skip), `prefer-own-ptr` (the host's
candidate/use-counting gates) plus the two analyzer facts they need
(`span[T]`'s `data`/`len` member table, and the raw-pointer field read's unsafe
requirement).  The LSP's range conversion (`lsp/diagnostics.mt`) now mirrors the
host's `extract_warning_range`: a tracked column with no length spans one
character.  Measured: **lb host 98 / self 98, mst host 10 / self 10** — the
warning counts match on both files.

**The rows still open** (measured, session-17 probe — the counts already match, so
each row is now only *which* item and *where*):

- `constant-condition` (lb, 4 items): the host anchors on
  `condition_span(expr, line:, keyword_pattern:)`, which prefers a
  **source-line** span (scanning the line for `if`/`while` up to the `:`) over the
  expression's own position, and its message names the *branch*
  (`branch condition is always true/false`) where the self says `if condition …`;
  the two answers also differ in *which* condition is true, so the
  `ConstantPropagation` port (the host's constant folding over the statement)
  is part of the row.  Host anchors: `434:7-19`, `474:7-17`, `476:12-17`,
  `1387:7-16`; self: `445:0-1`, `474:0-1`, `531:0-1`, `1387:0-1`.
- `owning-release-double`/`-leak` (mst, 3 items): the host anchors
  `owning-release-double` at the **released binding's name** (`335:33-38`,
  `owned`) and reports the leak at `440:8-11` (`raw`, `own[int]`); the self
  anchors at the declaration (`335:4-8`), also fires at `403:8-12` for `heap`, and
  reports no leak.  The host's path is `release_rules.rb`'s
  `classify_cfg_nodes`/`find_reachable_release` (a release reachable on some path
  is a double release; an owning binding never released on any path leaks) plus
  `own_typed_local_bindings`/`own_transferred?` — F1's graph carries what it needs.

Then the emission-order restructure closes the class (see "the restructure,
concretely" in the ledger's session-17 log).

**The remaining per-rule deltas, measured with `tmp/diag_probe.rb` (session-16
baseline, `tmp/diag-s16-base.txt`)** — ranges/messages first (mechanical): every rule
below needs a host-shaped span, and several need a message fix.

| rule | host | self | delta |
| --- | --- | --- | --- |
| `noop-compound-assignment` (20) | 12→18 | 12→13 | length = target identifier length (`expression_column`/`name.length`) |
| `self-comparison` (2) | 19→35 | 19→25 | the whole binary expression's span |
| `redundant-return` | 4→10 | 4→5 | the statement's own `length` |
| `redundant-type-annotation` | 422:8→12 | 8→13 | `name.length`; the self also fires once too often (`let maybe_int: int? = 42` — the host skips nullable annotations) |
| `unreachable-code` | 1305:4→10, "unreachable code" | 0:0→1, "…after a terminating statement" | `statement_column`/`statement_length` + the host's message |
| `constant-condition` (4) | condition span, "branch condition is always…" | `0:0→1`, "if condition is always…" | `condition_span` (source-line based) + the `branch`/`loop` message; the host's answers also differ in which condition is `true` vs `false` (a `ConstantPropagation` port) |
| `prefer-inline-if` | 474:4→5 | 474:7→8 | the `if` keyword span; the self fires once too often (482) |
| `prefer-conditional-expression` | 6, keyword span, "every if branch assigns to 'X'; rewrite as \`let X = if …\` expression" | 7 (3 with an empty range), "every … branch assigns the same target" | message + span + drop the extras |
| `prefer-or-pattern` | 698:19→20 | 698:8→9 | the pattern's position, not the body's |
| `prefer-is-variant` | 0 | 3 | the self fires on `is` *expressions*; the host fires on a match whose arms map one variant to opposite booleans (`column`/`length` = the match expression) |
| `prefer-own-ptr` | 0 | 4 (2 lb, 2 mst) | gates: `@ptr_candidates` + uses counted by identifier occurrence with `unsafe_depth` (`uses[:unsafe] > 0 && uses[:safe] == 0`, never params) |
| `reserved-primitive-name` | 0 | 1 (lb 1376 `ptr`) | the host's module-binding scan order/exclusions |
| `unused-local` | 24 | 25 (`msg`, a destructured name) | the host credits a destructuring `let (a, b) = …` name |
| `redundant-unsafe` | 1 lb + 5 mst | 0 | the rule is missing entirely: `@sema_facts.required_unsafe_lines`, generic-context skip, `column` + length 6, for `unsafe:` blocks *and* expressions |
| `owning-release-double` | mst 1 at 335:33→38 'owned' | 2 at 335:4 'heap', 403 | the CFG-based path (`classify_cfg_nodes`, `find_reachable_release`) + `symbol_name` (the released binding, not the `heap` receiver) |
| `owning-release-leak` | mst 1 at 440:8→11 'raw' own[int] | 0 | the `own_typed_local_bindings`/`own_transferred?` path (needs resolved initializer types) |

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
`unused_import_parity.rb` (609/609, differ 0), and the LSP audit's diagnostic
entries (the full matrix).

## F4 — stage 11c: payload structs and typed destructure bindings (DONE, session 16)

Landed: destructure bindings carry their per-name types (recorded in
`Analysis.destructure_types`, the initializer inferred without recording so codegen is
otherwise unchanged) and `as name` arm bindings carry the host's payload type
(`ty_variant_arm_payload` + `display_name`/`PayloadField` fields and the
`variant_arm_payload_with` constructor; prelude arms register their fields and variant
type parameters; `match_arm_payload_type` substitutes the scrutinee's arguments;
`check_member` resolves `p.value`; `Analysis.arm_binding_types` feeds the LSP hover at
declaration and use; `record_expr_type` never records a payload type because the
lowering owns that struct's C name).  Also `?` now yields the unwrapped success type.
Measured: the audit **13 → 11** (hover 5 → 2, added 0 apart from the host's
first-file documentSymbol race), prefer-let over `std/` **121 → 32**.  The residue of
those 32 is a different root cause — an imported-receiver method chain
(`read(protocol).pending_reliable.pop()`) that the analyzer still types as `ty_error`
— so the "sweep closes" prediction was only two thirds right.  Record:
`docs/self-host-plan.md` §0k, "Stage 11c".

## F4 (original notes) — stage 11c: payload structs and typed destructure bindings

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

## F7 — the analyzer's callable-value record (DONE, session 16)

The scanner only renders `function` for a lexeme in `Analysis.callable_value_sites`,
which `infer_identifier` fills for every bare top-level function name it resolves
as a value — except inside the compile-time handle builtins
(`Context.callable_site_suppression`: `callable_of`, `field_of`, `has_attribute`,
`size_of`, …), whose arguments are declaration *names*; `record_decl_callable_sites`
covers the const initializers and `foreign function … = name` mappings the self never
infers.  The two measured positions (`identity` 275:40, `add` 1099:41) render
`variable` like the host's.  Record: `docs/self-host-plan.md` §0k.

## F8.1 — the scanner's two rules (DONE, session 16)

`dot_nested_type_member?` (`<Type>.<Nested>` → `type`) and
`callable_field_member_access?` (a call through a `fn`/`proc` struct field →
`property`), both driven by tables the scanner now collects from the AST and the
analysis (`nested_type_keys`, `callable_fields`, `receiver_structs`).  With F7, the
`docs/language_baseline.mt` token stream is **byte-identical** (0 differing
positions).  Record: `docs/self-host-plan.md` §0k.

## F7 (original notes) — the analyzer's callable-value record (2 of semanticTokens' 5 positions)

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

## F8.2 — documentSymbol (DONE, session 17)

Closed in session 17: the thirteen-locals residue below turned out to be **24
details plus one ordering** (the index-based `ds_diff.py` hid the tail behind the
`emit` pair's shift).  The analyzer now types `str + str`, builtin constructions
(`array[T, N](…)`, `span[T](…)`, with the host's argument validation),
`ptr_of(ref[T])`, `ptr[T]` methods, a native `with`, tuple element access and an
instantiated local generic struct's fields; the outline renders a nested type's
own segment, a named tuple, `dyn[Interface]`, lifetime parameters, and no
inferred detail for a local in a generic body; and the `emit`-declared symbols
are emitted inside their enclosing const function.  The audit's documentSymbol
class reads **0** (all seven files byte-identical).  Record: §0k, "The analyzer's
initializer typing and the outline residue".

## F8.2 (session-16 notes) — documentSymbol (MOSTLY DONE, session 16)

`src/colors.mt`, `src/node.mt` and `docs/memory_stress_test.mt` match the host byte for
byte; `docs/language_baseline.mt` is down to thirteen locals whose *initializer type* the
analyzer still records as `ty_error` (str concatenation, `array[int, 3](…)`,
`span[int](…)`, `.load()`, `ptr_of(...)`, a vector construction) plus two `emit`-expanded
consts with a spurious `children` key — **an analyzer-typing residue, not outline work**.
Also fixed along the way: the guard narrowing now applies to imported
`Option`/`Result` (`unwrap_nullable_type` handles `ty_imported`), the function/proc detail
renderers, and the declaration-shape details listed in `docs/self-host-plan.md` §0k.

## F8 — the LSP-side closures (after the facts land) — CLOSED except F8.3

1. ~~semanticTokens~~ — **DONE (F7 + F8.1, session 16)**: the scanner's
   `callable_field_member_access?` and `dot_nested_type_member?`; the class reads 0.
2. ~~documentSymbol~~ — **DONE (F8.2, session 17)**: the wrapper, the key order,
   the `extending`-block merge, the `when` branches, the refined locals, the
   function-type details and the `emit` symbols' source position; the class reads 0
   on all seven files.
3. **hover**: `type quat` (`lb@1653:24`) is the one remaining entry — its fix is
   the definition index's coverage of a never-opened std module (do *not* port the
   blanket index fallback: an earlier attempt closed it and added five; the host's
   asynchronous definition warmup is why).  The deliberate-difference table
   (`docs/lsp-design.md` §8) also carries the documentSymbol first-file race, the
   references pacing entry and the documentHighlight snapshot carry-forward.
4. **F8.3 (new, session 17)**: the documentHighlight survivor `lb@704:67` —
   measured both cold (the host equals the self) and warm (one range via the
   host's carried-forward snapshot binding); documented, no action unless the
   snapshot machinery is built.

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
  (the counter the item moves), `ruby tools/unused_import_parity.rb` (609/609),
  `rake "parity:scoreboard"` (the per-rule lint table),
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

The live copy is the ledger's **"Session 18 prompt"**
(`~/.commandcode/plans/finish-self-host-full-parity.md`): it opens with the
session-17 close (the matrix at 4 differing entries, every per-rule lint *count*
now matching) and lists the remaining work in order — F3's emission-order
restructure, `constant-condition`, the `owning-release` pair, the `type quat`
index-coverage fix, the documented `documentHighlight` decision, then F9's
readiness items and the compiler tracks (lower/CLI/DAP/bindings).  Its
per-entry evidence and the restructure's concrete plan are in the ledger's
session-17 log.
