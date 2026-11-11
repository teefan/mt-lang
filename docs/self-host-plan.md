# Self-Host Plan

Single planning document for the Milk Tea self-host (`projects/mtc`, branch
`selfhost`).  The Ruby host (`ruby -Ilib bin/mtc`) is the reference; "parity"
means byte-identical where a harness can compare, "better" means a documented
deliberate extension.  The goal is a self-host that matches the host everywhere,
or is documented as deliberately better.

**Start here:** read *Status at a glance*, *How to start a work session*, and
*The program* (the ranked open work).  The Ledger carries the last verified
number per gate.  The pre-compaction version of this file — with the full
session-by-session records (§0a–§0k, §1–§7) — is at commit `d8a199c7`; use
`git show d8a199c7:docs/self-host-plan.md` when you need the history.

## Contents

- [Status at a glance](#status-at-a-glance-session-62-2026-11-10)
- [How to start a work session](#how-to-start-a-work-session)
- [The program — ranked remaining work](#the-program--ranked-remaining-work)
- [Deliberate differences (do not chase)](#deliberate-differences-do-not-chase)
- [Ledger](#ledger)
- [Porting notes](#porting-notes)
- [Risks and notes](#risks-and-notes)
- [Provenance](#provenance)

## Status at a glance (session 65, 2026-11-11)

| Area | State |
| --- | --- |
| Bootstrap fixed point | **holds** (`stage2.c == stage3.c`, session 65 re-verified at `c5a9bcd4`); full self-test suite **19 files / 0 failed** |
| `test/mt` | **60 files / 0 failed** (session 65 re-verified on stage2) |
| Examples | **13/13** synchronous top-level examples build with stdout+exit identical to the host; the two `async_*` examples hit the host's own loop guard at rc 134 on both compilers (documented CPS-resume limit); `examples/sdl3` **34/34** builds; the raylib sample builds |
| `sexpr lex` / `parse` | 0 differ (lex **718/718**; parse **714 match / 0 differ / 4 host-rejected of 718**; counts drift with the tree) |
| `sexpr lower` | **665 match / 2 differ / 51 host-rejected / 0 self-rejected of 718 files** (session 63) — the two differ are the documented `memory_stress_test` artifact and the `main.mt` `--sexpr` loop guard; **Track A closed** |
| `cli:parity` | **78 match / 0 differ / 11 case-backed pending** of 89 cases (session 65; `--timings` values and `debug`'s Ruby node ids are normalized). The pending set is `deps`, wasm, `toolchain doctor`, locked/frozen build, and bundle/archive run. |
| Linter corpus | **496 agree / 122 differ** of 618 (session 65 re-read with the content-hash host cache; hostfail 0, selffail 0); **41/43 rules, 12/13 fixers** |
| LSP | harness **30/30 capability keys + 4 documented entries**; project audit canonical **6** differing entries (4 documented rows + 2 builtin-hover warm artifacts), non-canonical 4–5 with ±drift; recovery **6/6**; `milkTea/debugInfo` **byte-equal**; valgrind **0 errors**; edit latency **4.9 ms median**; soak **68.1 KB/cycle raw / 19.9 LS** (one-time index level documented) |
| DAP | **zero differing rows** on the `dap_smoke` matrix, except the documented self-better `lldb-real frame0 name`; the live VS Code F5 check is the remaining manual step |
| Formatter | **712/712** byte-identical in all three modes (`:canonical`, `:preserve`, `:tidy`; counts drift) |
| Imported bindings | **29/29 verified** against the host generator and the checked-in modules (session 66; `box3d` closed; golden-vector naming test in `projects/mtc/test/imported_bindings_naming_test.mt`) |

Rough completion against the per-track Definition of Done: **~96%**.  The
self-hosting foundation, `lower` dump parity, the CLI behavior matrix and the
imported bindings are done; the residue is the CLI's largest unported
subsystems (`deps`, `docs`, wasm/emcc), the linter corpus (121 files), and
bindgen reproducibility.  LSP, DAP and formatter are closed at their documented
differences.

Session-65 batches (measurement truth + CLI forms): `cli_parity`
replaced the ten `KNOWN_GAPS` regexes with case-backed `pending:` metadata (nine
of the ten patterns had no case); the matrix is now **89 cases / 78 match / 0
differ / 11 pending**, and a pending case that starts matching is a failure.
The second session-65 batch closed the multi-operand/directory forms:
`parse`/`emit-c` PATH|DIR expansion with headers, `format` directories and
multiple sources plus the `requires --check or --write` rule, and the host's
`check`/`lint` unknown-flag validation, and `lint --init` (with the 43-code
rule registry).  Remaining pending: `deps`, wasm, `toolchain doctor`,
locked/frozen build, bundle/archive run.  Bootstrap at the end of the batch
reached a fixed point (`stage2.c == stage3.c`), the dev suite was 19/0, and
stage2's `test/mt` was 60/0.
`lint_parity` gained `hostfail`/`selffail` buckets and a SHA-256 host-source
cache key (mtime invalidation could reuse stale output after a checkout); the
full corpus re-read is **618 files / 496 agree / 122 differ / hostfail 0 /
selffail 0** (the earlier 495/121 figures were stale).
`dap_smoke` now exits non-zero on an unlisted differing row, requires a real
`lldb-dap` (versioned `lldb-dap-<N>` names are discovered; `--allow-skip` opts
out), and reported `differing rows: none` over the full drive. `gates.sh` labels
were corrected and areas added for `packages`, `docs_cli`, `wasm`, `toolchain`
and `tools`. Baseline re-confirmed: `cli_parity` 65/65 on the original matrix,
bindings 3/25 of 28.

Session-66 batch (Track D closed): the imported-bindings emitter now matches the
host generator byte-for-byte on all 29 bindings (`box3d` added; type aliases,
overrides, bare-alias resolution, function-type handle projection, method
wrappers built from generated entries, tidy formatting).  The self-only command
gained `--stdout`/`--json`; `tools/imported_bindings_parity.rb` reports
29 verified / 0 changed, and both bindings gates are hard.  The host's 37
OpenGL naming vectors are pinned in
`projects/mtc/test/imported_bindings_naming_test.mt` (self suite 20/0).

Session-51 batch: the event synthetic bodies (host slot/snapshot shapes), the
reused await-field recording plus nested-await hoisting in a direct-await
local, multi-digit `int_to_str`, the binary operands' conditional peer-type
propagation, and `ir_expr_type`'s unsigned-literal arm.  Flipped
`event_stress_test`, `build_cache`, `imported_bindings/{main,methods}`,
`lsp/{debug_info,server}` and one example.

Session-52 batch: await-free nested async bodies lower as plain locals (with
the analysis' frame fields pre-registered and no line/path on the decl), the
AST CFG decides the async fall-through cleanup, CPS whiles drop the sync
scoping block, guard locals spill their storage as a member-expression target,
`or` short-circuits swap their branch bodies, range bounds take the common
integer type, async local literals take the declared type, the fresh-temp
counter resets per async function, and raw-module forward-declarable opaques +
builtin-generic receiver names (`ptr_receiver_arg0_…`) match the host.
Flipped `std/net/{packet,punch}`, `std/tracy`, `std/raylib/tracy_gpu`,
`std/simd`, `tracy_profiler` and three `projects/mtc` files.

Session-53 batch: module-constant string arguments are cstr-backed (a direct
`.data` cast at a `str as cstr` boundary), and a statement-position foreign
call with a `consuming` parameter nulls the bare nullable binding afterwards
(a guard-bound storage included) with a null flow refinement.  Flipped
`raylib/{core/storage_values,core/text_file_loading,text/font_sdf,text/strings_management}`.

Session-54 batch: a nested foreign call with cstr temps materializes
`__mt_foreign_result_N` inside a discarded-statement window too, a raw-module
receiver's monomorphized method links bare (`Image_draw_pixel`), a pointer
offset literal takes the host's default `int` (a `0z` suffix is ignored) and a
nullable pointer projects to a plain pointer foreign boundary as a cast.
Flipped `raylib/{core/automation_events,audio/spectrum_visualizer,
textures/image_processing}` and three more raylib/SDL examples.

Session-55 batch: proc closure structs ride the non-dumped
`Program.monomorphized_structs` (the host's C backend collects them), a
same-module type alias resolves in union fields, a pure integer constant enum
member value takes the backing type (`1 << 0` in a `flags` block), a bitwise
binary with missing analyzer type falls back to its equal operands' type, and
`get()` lowers to `IR::NullableIndex`/`IR::NullableSpanIndex` (NULL on
out-of-bounds; the backend emits the host's nullable helper names). An async
`if` expression with awaits in its branches hoists like the host's
normalization: the result temp registers before the branch temps, numbered
after them. Flipped `engine/{types,systems,guards}`.

Session-56 batch: a `ty_named` enum resolves its backing against its own
`module_name` (raw `std.c.*` enums cast to `int` in comparisons), a char
literal is a compile-time numeric constant (a `uint` assignment casts it), a
comparison's IR type is always `bool`, a float binary peer contextualizes an
`if`-expression operand (`(if c: W else: H) / sqrtf(x)` casts each branch), the
generated range/collection/iterator loops use the host's native
`ContinueStmt`/`BreakStmt` (labels remain for defer flushes and switch arms),
and a rebuilt foreign-mapping binary/unary keeps the analyzer's recorded type.
Flipped `sdl3/{pen/drawing_lines,renderer/read_pixels,renderer/affine_textures,
asyncio/load_bitmaps,demo/infinite_monkeys}` and `raylib/others/rlgl_standalone`.

Session-57 batch: a plain expression constant takes the host's
`lower_compile_time_literal` path (typed, not width-masked: `~268435455` stays
`-268435456` in a `uint`), a `char` array-constructor element casts its integer
literal (`array[char, 512](0, …)`), and an *inferred* generic function instance
joins its type arguments with single underscores after one double underscore
(`find_state_hooks__World_Context`, not `__World__Context`).  Flipped
`test/mt/{fsm,goap,htn}_test`.

Session-58 batch: function placement reproduces the host's `lower_modules`
setup pass + `lower_functions` fixpoint — a specialization is emitted at its
owner declaration's next visit, gated on the function that created it, with
analyzer-pre-instantiated bindings available from the setup pass (the `wait`
chain is lowering-created and waves correctly; the `completed`/`Result` keys
render via the host's qualified `to_s`).  A `?` operand gets its own prepared
window so a proc argument materializes before `__mt_propagate_N`; the async
constructor always carries `take_result` (void included); async non-await
`if`s emit `nil` for an empty else; async `unsafe` bodies splice; the release
and cancel vtable functions free pointer-lowered params; a discarded void
await still calls `take_result`; a literal return with defers completes after
the cleanups; and the async-main root proc's invoke carries the source path.
Flipped `examples/async_stress_test` and `std/net/{channel,clock,manager,mux,
session,sync}`, plus `std/tls`.  Lower and the self-test suites were re-run
(19/0, 60/0).

Session-58 second batch: a match scrutinee is lowered exactly once (the
recorded type is only a fallback) inside the statement's prepared window, so a
proc argument materializes before `__mt_match_value_N` and the cleanups follow
the match; a signed float literal (`-1.0`) takes a `float`/`double` context
through its unary at binary, call-argument and return sites; and
`expect_eq`/`expect_ne` type each operand against the other like a normal
binary.  Flipped `test/mt/{vec,math}_test` and
`projects/mtc/test/tidy_formatter_test` (19/0 and 60/0 re-run).

Session-59 batch: async scalar/enum match cases append the CPS break
(`std/http`, `std/oauth2`); a guard local in a no-await async body carries no
line/path (`std/net/lobby`); async local/assignment initializers materialize
array calls (`__mt_array_call_N`) and the `?`-operand prepared windows precede
`__mt_propagate_N` (`std/net/{discovery,nat,stun,turn}`,
`examples/async_network_lobby`).  Cross-module async calls are Task-wrapped for
every return type (the analyzer's imported binding type).  Plain local reads and
assignment targets carry the flow-refined visible type (sdl3 gamepad/joystick,
the `raw_fields` family).  Inline-for binds its loop variable as a comptime
constant (no local) and folds constant branch conditions; `emit` declarations
lower a second time into the emitted tail; an ordinary const-function call stays
a runtime call and a non-constant argument no longer folds to 0
(`examples/{comptime,reflection_advanced}`, `test/mt/reflect_test`).  The
analyzer types vec/mat/quat members and Simd arithmetic, SoA fields type as
`array[T, N]`, and an unannotated local keeps the recorded simd/vec aggregate
over its scalar binary node (`projects/stress/src/engine/math`,
`examples/simd_features` advances to the `SimdLaneWith` IR node).  A no-await
async body registers its frame fields in the host analysis' normalized order
(an `and`/`or` temp before the branch locals), which flipped `std/net/rpc`.
Flipped 15 files; ledger `sexpr lower` 630/36/51/0 of 717 (from 615/51); 19/0
and 60/0 re-run.

Session-60 verification at the committed tree: full bootstrap (fixed point plus
19/0), `test/mt` 60/0, `sexpr lower` 630/36/51/0, lex 717/717 and parse
713 match / 0 differ / 4 host-rejected.  No code changes; the plan header and
Ledger were re-stamped, and the ranked Track A leaders stand as below.

Session-61 batch: the async normalizer's two-phase `and`/`or` shape (both operands
lowered into child windows, the result temp allocated after them but its frame
field registered at the pre-recursion slot and its declaration emitted first), the
CPS while restructure for await-free `and`/`or` conditions (with the extra
`cond_name` bool temp and a native break guard), direct-await guard locals taking
the awaited result straight into the guard's frame field (no temp field), and the
if-expression branch assignments using the textual frame `Name` (await stores keep
`Member`).  `std/http/server`, `projects/stress/src/main` and
`engine/async_tasks` now match through their async frames; their first differences
moved to the async-main proc env bridge / proc-helper placement and the tuple
struct name.  `std/net/rpc` stays matching.  Gates: fixed point holds, `test/mt`
60/0, lower 630/36/51/0 (unchanged count, deeper first diffs), examples 49/0.

Session-61 second batch: named tuple struct names follow `Types::Tuple#to_s`
(`(x: int, y: int)`); a static-assert message lowers as StringView while the C
backend still emits a bare C string for a literal; proc calls through struct
fields and array elements take the proc's return type (void/error/proc records
fall back to the closure signature); a qualified imported enum member resolves
in an inline-match scrutinee/pattern; a user generic variant instance classifies
as `Types::VariantInstance`; and a capturing proc's release frees captured proc
fields before the env.  Flipped `projects/stress/src/engine/{compile,closures}.mt`;
lower **632 match / 34 differ / 51 host-rejected / 0 self-rejected of 717**
(from 630/36; the set diff shows no newly differing files).  Gates: fixed point
holds, `test/mt` 60/0, examples 49/0, dev self-tests 19/0.

Session-61 third batch: a generic struct receiver in `concrete_field_type` is
monomorphized before the field lookup, and the proc retain/release walks use the
concrete instance's substituted fields (`proc_struct_fields`) instead of the
declared `analyzer.structs` entry, so `PipelineStep[int].handler` carries
`proc(input: int)`.  `stress/main` advances from that field type to event
function ordering; count unchanged at 632/34/51/0, gates as above.

Session-61 fourth batch: event runtime functions and dyn wrappers join the
program-wide synthetic function tail in creation order (the host's single
`@artifacts.synthetic_functions` list); a multi-iterable `for` mirrors the host's
parallel collection-for (per-iterable `__mt_for_items_N`, the matching-length
fatal check, and a block-wrapped `__mt_for_index_N` loop); proc-call arguments
and `.with(...)` replacements take the target parameter/field literal type; and
a proc literal in a CPS local initializer uses a prepared window, so no
`__proc_N__setup_env` synthetic function is emitted.  Flipped
`projects/stress/src/engine/async_tasks.mt` and `projects/stress/src/main.mt`;
lower **634 match / 32 differ / 51 host-rejected / 0 self-rejected of 717**
(from 632/34; the set diff shows no newly differing files).  Gates: fixed point
holds, `test/mt` 60/0, examples 49/0, dev self-tests 19/0.

Session-61 fifth batch: the root async `main` entrypoint now synthesizes the
host's argc/argv bridge — `span[str]` (`__mt_args_items`/`__mt_args`), raw
`ptr[cstr]`, or `ptr[ptr[char]]` — with the `__mt_async_main_arg_N` locals, a
capturing root proc whose env is named from the root local
(`__mt___mt_async_main_root_env_1`), and the argv cleanup; a call to the root
async `main` targets its `__async_main` constructor.  `std/http/server` now
matches through the entrypoint and advances to a dynamic format-string part
(`__mt_fmt_part_N`) difference; count unchanged at 634/32/51/0 with no newly
differing files.  Gates as above.

Session-61 sixth batch: every CPS local initializer now uses a prepared window
(the host's CF local path), so a dynamic format string's `__mt_fmt_part_N`
locals, a proc literal's env setup, and array-call temps precede the frame
store instead of nesting in a `StmtExpr`; the proc-literal special case folds
into the same rule.  `std/http/server` advances from the format parts to a
release-cleanup shape (`String_release(&frame->local_...)` vs
`mt_format_str_release(...)`); count unchanged at 634/32/51/0 with no newly
differing files.  Gates as above.

Session-62 batch (18 files flipped, 634/32 → 648/18):
- `std/http/server`: a CPS local initializer that stores a dynamic format
  string registers the frame field for the frame's release/cancel cleanup
  instead of deferring the temp release (the host's `format_str_fields`), and
  the release/cancel vtable functions free those fields; the CPS while
  restructure picks the host's body mode (plain locals when neither the
  condition nor the body awaits; the original body stays CF when the condition
  setup awaits).
- Foreign calls: argument values are all lowered before the call's own cstr
  temps allocate (host phase 3), `unsafe:` is transparent to the `in`
  addressability check, a multi-reference non-duplicable argument materializes
  the call into `__mt_foreign_expr_N` in expression positions (return values
  are statement roots), and a float/double parameter threads its expected type
  into an arithmetic binary argument (literal retyping + promoted operand
  casts, no constant-fit cast).  Flipped `raylib/{basic_pbr,
  spotlight_rendering}`, `raylib/shapes/{digital_clock,pie_chart}` and
  `raylib/text/unicode_emojis`.
- `sdl3/demo/woodeneye`: the analyzer's expected-type hint no longer leaks
  through a prefix cast (the host infers a cast operand with no expected type),
  so `ubyte<-(if c: 0 else: 255)` re-infers the conditional as `int`.
- Generic-instance placement: the analyzer-vs-lowering split is modelled
  explicitly.  A specialization records `body_validated` (the host's
  `validate_specialized_function_body!`) separately from
  `pre_instantiated`; the iterator protocol instantiates `iter`/`next`/
  `current` without validating their bodies.  Normal-call reach edges are
  recorded, upgrades are sticky across cache hits, and a placement fixpoint
  recomputes the classification from the graph (the analyzer ran before
  lowering, so lowering order must not decide it).  Recursive monomorphized
  self-calls resolve their return type from the pre-registered
  `function_returns` entry.  Flipped `test/mt/{queue,stack,priority_queue,
  set,multiset,ordered_map,ordered_set}_test`.

Session-62 second batch (657/9, from 648/18):
- Extending blocks resolve a nested struct target (`extending Rectangle.Edge:`)
  through the analysis' registered types in the declaration-visit pass too, so
  the method emits at its source position (`examples/nested_struct_stress_test`).
- A generic specialization created from a plain function *reference* is
  analyzer-instantiated but not body-validated (the host validates only call
  sites), so its nested concrete calls stay creator-gated
  (`examples/data_structures`).
- String matches compare the prepared scrutinee node directly (no
  `__mt_match_str_N` temp), the host's `lower_string_match_stmt` shape
  (`projects/mtc/src/mtc/lowering/lowering.mt`, `debug_map_test`,
  `lowering_test`).
- The `simd[E, N].with(lane, value)` builtin emits the host's
  `IR::SimdLaneWith` node (new IR variant, dumper, formatter and C backend).
- A concrete generic struct instance's field lookup uses the *defining*
  module's qualified name, so a field literal takes its declared type
  (`SyncValue[uint](value = 0)`, `test/mt/net_sync_test`).
- The synthesized sync `main(span[str])` argc/argv bridge initializes its args
  array with a null literal (not a `NULL` name).
- A method receiver's speculative type query is now effect-free: it discards
  its setup statements and restores the temp/format counters, so a chained
  method call's receiver is built once with the host's name
  (`std/mem/tracking`, `test/mt/mem_tracking_test`).

Session-62 third batch (659/7, from 657/9):
- The synthesized root `main` wrapper names its captured result `__mt_result`
  (host `build_root_main_entrypoint`), and recursive variant payload fields
  take the host's auto-address type (the value's own type, not `ptr[field]`).
- Variant arm payload member accesses use the declared field name; C struct
  members may be keywords (`sizeof`), so the arm-field sanitizer was wrong.

Session-62 fourth batch (660/6, from 659/7):
- An imported constant whose folded value cannot be represented literally
  (an integer standing for a `char` field, per the host's
  `lower_compile_time_literal` nil result) falls back to lowering the
  referenced constant's declaration initializer in its own module context —
  the host's `rewrite_static_storage_initializer` path.  Closes `std/flecs`.

Session-63 batch (Track A closed, 662/4 → 665/2; the residual two are the
documented `memory_stress_test` artifact and `main.mt`'s `--sexpr` loop guard):
- Module setup order: `lower_module` now follows the host's per-module passes
  (constants, globals, types, then function bodies); globals' proc symbols and
  synthetic creation order match.
- Module-level `when` expansion is shared with the placement pass, so an
  expanded function keeps its source position instead of being appended.
- Parallel IR: ported the host's `@parallel_for_counter` naming
  (`_pfor_N`/`_spawn_N`/`_detach_N`, `mt_pfor_cap_/work_`, `mt_spawn_cap_/work_`,
  `mt_detach_work_`), per-spawn capture structs with array-capture pointer
  fields and rewrite, written-capture write-back, write-conflict validation,
  and `mt_cap`/`mt_pfor_data` shapes; fixed the capture order to
  first-occurrence (Map keys are hashed, not insertion-ordered).
- Proc symbols: a final pass (`lowering/proc_renumber.mt`) renumbers
  `__proc_<N>__` ids from the assembled program in host allocation order
  (setup values, then module-function emission order) and reorders the
  invoke/release/retain tail; it is gated off when any helper has no literal in
  that prefix (async synthetic bodies), preserving their existing numbering.
- Types: added the host's `Types::Handle` singleton for `detach`; `dyn[I]`
  carries interface type arguments (`Types::Dyn :type_arguments`), including
  `iface_method_return_type` substitution; tuple instance suffixes render like
  `sanitize_identifier(to_s)` (`Option[(int, int)].unwrap` →
  `Option_unwrap__int_int`) and prelude `Option`/`Result` compare equal across
  their generic and imported forms.
- Smaller fixes: flags implicit members honor `value_explicit` (parser-synthesized
  literals no longer reset auto values), `str_index` passes its index through,
  range-index assignment emits plain `Index`, `let x = match` materializes the
  host's `__mt_match_expr_N` copy, `?` returns the propagate temp when the
  return type matches, chained calls lower through the callable-value path,
  tuple literals keep proc literals inline, a ref/pointer receiver decides
  pointer lowering from its referent, and monomorphized calls apply the ref
  argument bridge.
- C backend: void-typed struct/variant fields materialize as `uint8_t`
  (`c_field_declaration`) and initializers wrap a void value as `(expr, 0)`,
  matching the host's `Result[void, E].success` / `WorkState[void]` shapes;
  previously the self emitted an empty arm struct and invalid C.
- Gates: fixed point holds, `test/mt` 60/0, self-tests 19/0, examples 49/49,
  lex 718/718, parse 714/0/4; host-vs-self runtime output is identical for
  `examples/language_baseline` (flags/dyn/proc/match/detach) and
  `examples/multithreading_test` (parallel for/spawn/gather).

Session-63 CLI batch (24/37 → 60/1 of 61; only the `debug` formatter remains):
- Errors and usage blocks now go to stderr in the host's shape: `new`,
  `format --check --write`, `completions`, `std`, `toolchain`, `snapshot`,
  `test`, `build` (`--kind`, unknown options, missing values), `lex`/`debug`
  missing-file and directory messages, package-entry errors
  (`build.entry not found: … (resolved to …)`, directory-as-source), and
  `std show`/`build`'s no-entrypoint line.
- The analyzer reports the host's `unknown callable <name>` for an unresolved
  bare call (value/builtin/handle/type allowlists, loader-backed analysis only),
  and `check` prints only the first error per file (the host aborts there).
- `lex`'s default output is Ruby's `PP.pp(tokens)` shape (field-per-line Data
  objects, Ruby string inspection, integer/float `literal` values).
- `lower`/`emit-c` directory operands expand to sorted `.mt` files with the
  `# --- <path> ---` headers; a package root is discovered when neither
  `build` nor `run` gets an operand.
- The parser's missing-closing-delimiter diagnostics report the *previous*
  token (the host's `consume` rule) and call arguments say `expected ')' after
  call arguments`; `parse` renders lexer errors as `error[lex/error]` blocks
  and the lexer's unclosed-grouping error carries the host's line/column.
- `cache status` uses the host's `data_root/tmp/mtc-cache` (checkout root, XDG
  fallback), counts program dirs/binaries and formats MiB; `cli_parity.rb`
  normalizes `--timings` wall-clock values (the report structure still
  compared).
- Gates: fixed point holds, `test/mt` 60/0, self-tests 19/0, examples 49/49,
  lex 718/718, parse 714/0/4, lower 665/2/51/0.

Session-64 CLI batch (61/61; Track B's behavior matrix closed):
- `debug` now drives the ported LSP renderer (`lsp/debug_info.mt`) instead of
  the old ad-hoc summary: header with the expanded path and the token EOF line,
  the full token table (empty semantic column, as the host CLI passes none),
  parser AST (bare `SourceFile` — the CLI's tree carries no line, unlike the
  LSP cached re-wrap), parse errors, facts, bindings and diagnostics.  The
  facts/bindings/diagnostics sections print "(not available)" when the root
  fails to parse, matching the host's nil snapshot.  The Methods block is
  gated on the file's own extending blocks (prelude-only `method_sigs` must
  not open an empty block).  The harness normalizes the Bindings section's
  Ruby `object_id` keys (process-local identities; binding ids/order still
  compare).
- `test` argument forms: file operands (compile-fail fixture, lex/parse error
  blocks, `main` rejection, filtered-empty silence, missing-file message
  `mtc test: not a file or directory: …`), `--jobs N` validation (accepted;
  files still run in order — see *Deliberate differences*), the build flags
  `--cc/--profile/--platform/-o/--keep-c/--kind` with the host's errors and
  exit codes, first-positional path selection, the host's empty-tree messages,
  and a blank line before the summary.  Discovery is a separate pass (a lex
  error aborts before any file runs), compile-fail fixtures honor the `-n`
  basename filter, and the runner files are named with the process id (the
  host's `__mt_test_runner_<pid>`), so parallel `mtc test` invocations no
  longer collide.  The synthesized runner forces guards off and uses the
  requested compiler/profile/platform; failure details take the first
  non-blank stderr/stdout line.  `tools/gates.sh`'s per-file fan-out now uses
  the file operand instead of the one-file symlink workaround.
- Gates: dev build, self-tests 19/0, CLI matrix 61/61, LSP harness 30/30 + 4
  documented entries (`milkTea/debugInfo` still byte-equal), test matrix
  compared against the host across 25 directory/file/flag/error cases.

Session-64 second batch (Track B's cheap flags/subcommands):
- `toolchain bootstrap` is implemented from the host's `UpstreamSources` table
  (18 pinned sources, sentinel checks, `git clone` + `checkout --detach`, the
  two `config/upstream_versions.yml` override shapes, `-q/--quiet`, ANSI
  progress lines and the host's summary/error text).  `toolchain tools` builds
  the Tracy profiler (cmake configure/build, install to `<data>/bin`, the
  host's messages).  `-q/--quiet` and `--` are extracted like the host, and
  extra arguments/unknown subcommands print the host's errors.  The commands
  live in `projects/mtc/src/mtc/toolchain_cli.mt` (mirroring the Ruby file).
- `build --kind static|shared` now produces a static archive (`ar rcs`) or a
  shared object (`cc -shared -fPIC`) instead of "not implemented".  IR
  functions carry a `public_export` flag (never dumped, so `lower` parity is
  unchanged); the C backend keeps public top-level functions `static` for
  executables (byte-identical C) and exports them when building a library.
  Archives are rebuilt from clean output, and the CLI skips the missing-entry
  check and binary cache for library kinds.  The host's own static/shared path
  raises `NoMethodError: generate_header`; this is the working equivalent.
- Bindgen gained `--clang-arg` (threaded into both clang invocations),
  `--nullable-policy` (the host's JSON validation messages, function/parameter
  target validation, return/param type overrides in the emitted module) and
  `--nullable-report` (the host's JSON shape: module/header, summary, sorted
  manual entries with override/auto/c types; identical bytes on the probe).
  Generated-module include/macro differences remain Track D work.
- Gates: dev build, self-tests 19/0, CLI matrix 61/61, executable C
  byte-identical to the previous stage2, static/shared libraries link from a C
  consumer, bindgen nullable output/report byte-equal to the host on the probe,
  `toolchain bootstrap` byte-equal and its error/flag cases equal.

Session-64 third batch (package builds, `--bundle`/`--archive`):
- `loader/package_manifest.mt` now parses the host's build-relevant
  `PackageManifest` view (name, kind, source_root, entry, profile/platform
  defaults, output, assets with the host's not-found/duplicate-basename
  errors, html_template) and applies the host's
  `use_package_build_for?` rule (a directory package needs a resolved entry;
  a file operand must be that entry).  `build` uses the package output layout
  (`build/bin/<platform>/<profile>/<name>`, or `[build] output`) instead of
  the raw source stem; library packages and entry-less applications fall back
  to the host's "expected a source file, got a directory" path.
- `--bundle`/`--archive`: the bundle root is `-o`/`[build] output`/
  `build/dist/<platform>/<profile>/<name>`; the executable's parent is
  created, `build.assets` are staged beside a non-bundle binary or packed
  into `assets.mtpack`, and `--archive` writes `<bundle_root>.tar.gz` with
  `std/tar`.  The messages (`built <operand> -> <dir>`, `entry executable`,
  `  [cached]`, `archive`) and clean targets match the host, and a cache hit
  re-stages assets/archive like `build_cached`.
- `std/asset_pack.mt` gained the host's MTAP writer (28-byte header, 32-byte
  entries, sorted logical paths, raw data; packs are byte-identical on the
  probe).  The reader's `close`/state handling was fixed so a host-produced
  pack opens and reads in-language.
- `std/toml.mt` duplicate-key/table messages match Tomlrb
  (`Cannot overwrite value with key x`, `Key x is already used`); `run` now
  prints `[cached]` on a cache hit.
- Harness: 65/65 (bundle, archive, clean and non-package cases; the `pkg`
  fixture now has an asset tree and a real `stdio.print_line` program).
- Gates: dev build, self-tests 19/0, CLI matrix 65/65, MTAP byte-identical,
  tar listing/extraction equal, host-vs-self bundle error/clean matrix equal,
  focused lower 3/4 (only the documented `main.mt` artifact).


## How to start a work session

### Entry points

| Workstream | Read | Verify with |
| --- | --- | --- |
| `lower` dump parity (**closed**, keep at 0 real differ) | *The program* Track A; `docs/language-design.md` | `ruby tools/sexpr_parity.rb lower -q -j 16 --host-cache tmp/sexpr-host-cache` (~1 min warm, ~4 min cold) |
| CLI behavior parity | Track B; `tools/cli_parity.rb --help` | `rake "cli:parity"` |
| Linter corpus residue | Track C; the linter sections of `docs/language-design.md` | `ruby tools/lint_parity.rb -q` (615 files; `--host-cache FILE` makes re-runs ~20 s), `rake "parity:scoreboard"` |
| Imported bindings / bindgen | Track D; `docs/bootstrap-design.md` | `build/stage2/mtc imported-bindings --all --check`; `ruby tools/imported_bindings_parity.rb --json tmp/ib-parity.json`; regenerate `std/c/*.mt` and diff |
| LSP feature parity / residue | Track E; `docs/lsp-design.md` (esp. §8 differences), `docs/lsp-performance.md` | `tools/lsp_parity.rb record --server host\|self` + `compare`; `tools/lsp_project_audit.rb --workspace DIR [--canonical]`; `tools/lsp_recovery_probe.rb --check`; `tools/lsp_soak.rb` |
| DAP | Track F; `docs/dap-design.md` (gaps in §10) | `ruby tools/dap_smoke.rb [--server host\|self\|both]` |
| Formatter (`:tidy`, `:preserve`, `:canonical`) | Track E/formatter history at `d8a199c7` §7 | `ruby tools/format_parity.rb all -j 16` (712/712, counts drift) |
| Bootstrap / release | `docs/bootstrap-design.md` | `tools/bootstrap.sh -j 16` (full); `--fast` = fixed point only |
| In-language tests | `docs/testing.md` | `build/stage2/mtc test test/mt -I .` |
| Example builds | Track H | per-family sweeps (15 top-level, `examples/sdl3` 34/34, a raylib sample) |

### Verification tiers

Iterate cheap, prove once:

- **Tier 1 — per edit.**  Build the dev compiler
  (`ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev`, ~50 s)
  and run `tmp/mtc-dev test projects/mtc -I . --timeout 120`.  Measure only the
  class you touch: a focused `ruby tools/lint_parity.rb -q <paths>`, a single
  file's host-vs-self diff, `ruby tools/sexpr_parity.rb lower -q <path>` (the
  host cache makes repeats cheap), or the matching parity harness on one case.
- **Tier 2 — once per commit, on frozen sources.**  `tools/gates.sh` prints the
  gate set for the working-tree diff (or accepts `--areas linter`); `--run`
  executes them with logs under `tmp/gates/`.  Hard proofs: `tools/bootstrap.sh
  -j 16 --fast` (fixed point; the full form also runs the suite) and
  `build/stage2/mtc test test/mt -I .` (60/0), then the sweep that covers the
  area (lower/lint/CLI/LSP/DAP/format).
- **Batch the ceremony, not the care.**  Land 3–5 fixes per commit, each
  verified against the host before the next; run tier 2 once on the frozen tree.
  A batch costs about an hour instead of five ~45-minute cycles.
- **Do not replay a baseline a previous session verified at the same commit.**
  The Ledger records the last verified numbers; re-measure only the classes your
  change can move, and only when the tree moved.
- **Rebuild before measuring.**  A stale `build/stage2/mtc` is the classic false
  result.  `tools/bootstrap.sh` rewrites `projects/mtc/src/mtc/version_info.mt`, which makes the sexpr
  staleness warning fire harmlessly.
- **Quote sets where counters drift** (sexpr's file count with `tmp` fixtures,
  the LSP audit's ±10 between runs, the lint corpus with `tmp` files).
- **Long gates in the background.**  Do not idle on a ~10–25-minute bootstrap;
  start it and keep reading/planning (but see the frozen-tree rule below).
- **`tmp/` is scratch.**  Session probes under `tmp/` are not durable; durable
  conventions are `tmp/sexpr-host-cache`, `tmp/gates/`, and `tmp/mtc-dev`.
  Recreate a probe from the host's code/tests when one is cited.

### HARD RULES

- **Never edit sources while a gate runs** — `tools/bootstrap.sh` compiles the working
  tree, and `tools/sexpr_parity.rb`'s host side analyzes imported working-tree
  sources, so a mid-run edit silently corrupts the result.  Check the exit
  status, not just the tail.
- **No hacks, no workarounds** — fix root causes where the wrong state is
  produced, not in the layer where the symptom surfaces.
- **Sandbox generated binaries**: `timeout 10 bash -c 'ulimit -v 20000000; …'`.
  A 124 exit is a hang, 137 an OOM/SIGKILL, 139 a SIGSEGV, 134 a SIGABRT/double
  free — investigate, don't call it test noise.
- **Check the self-test suite's file count, not just `0 failed`** — `mtc test`
  silently skips a file that fails to lex/parse (`18 test file(s), 0 failed`
  with a broken `projects/mtc/test/*.mt`); the full-corpus sweep's `hostfail`
  count catches the same mistake one file late.
- **Never run `mtc test` while another gate runs** — the suite synthesizes
  `__mt_test_runner_*.mt` into `projects/mtc/test/`, so concurrent runs discover
  each other's runners (`duplicate value main`), and a stray runner left by a
  killed run poisons the next bootstrap.
- **Sync this file's Ledger (and any changed workstream doc) in the same commit
  as the code change.**
- **Generated binaries are not deliverables** — clean stray runners and scratch
  artifacts; gitignored gate output under `tmp/` and `build/` may stay.
- Commit trailer: `Co-authored-by: CommandCodeBot <noreply@commandcode.ai>`.

### Phase order and current position

0. **Hard build parity** — **DONE** (session 49; re-verified session 50): all
   15 top-level examples build, the synchronous set's stdout+exit is identical,
   `examples/sdl3` 34/34, `test/mt` 60/0.
1. **`lower` dump parity** — **CLOSED** (session 63): 665/2/51/0 of 718, the
   two residuals are documented host artifacts.  See Track A.
2. **CLI behavior parity** — **original 65/65 matrix closed** (session 64);
   session 65 made the remaining surface measurable and closed the
   multi-operand forms: **89 cases / 78 match / 0 differ / 11 pending**.  The
   unported subsystems remain (`deps`, `docs`, wasm/emcc, doctor,
   locked/frozen, bundle/archive run).  `toolchain
   bootstrap|tools`, `build --kind static|shared`, the bindgen nullable flags
   and `--bundle`/`--archive` landed in the session-64 batches.
3. **Linter corpus residue** — open: 496/122 of 618, **41/43 rules and 12/13
   fixers**, plus the analyzer gaps in Track C.
4. **Imported bindings / bindgen** — open: 28/28 verification and the bindgen
   gaps in Track D.
5. **Final verification** — Track H, only after the tracks above reach their
   targets.

LSP, DAP and the formatter are **closed** at their documented differences; only
their listed residues (ref-lifetime modelling, the DAP F5 manual check) remain.

### Definition of done (per track)

- **`lower`**: 0 differing files in `sexpr_parity lower` (residuals only if
  proven host artifacts, each documented); lex/parse stay 0-diff; no build
  regressions anywhere.
- **CLI**: every host command/flag exists with equivalent behavior; `cli:parity`
  all matches; `deps`/`docs`/wasm/bundle/toolchain functional.
- **Linter**: per-rule counts/messages/severities/positions equal the host on
  `examples/language_baseline.mt`, `examples/memory_stress_test.mt` and the whole-corpus sweep;
  every host rule/fix exists.
- **LSP**: harness 0 unintended entries (only the documented rows); the audit's
  completion class closed; `debugInfo` byte-equal; `[LSP perf]` ≤ ~10 ms per
  edit (met); valgrind clean (met).  **Met at session 31–38.**
- **DAP**: a real VS Code session debugs a `.mt` program end-to-end with the
  default `lldb-dap` backend (breakpoints, stepping, evaluate; Milk Tea
  frames/locals via the debug map); process backend unchanged; `dap_smoke`
  green on both.
- **Bindings/bindgen**: `imported-bindings --all --check` 28/28 verified (or each
  residual delta justified as cosmetic with evidence); bindgen output
  reproducible for the repo's bindings.
- **Formatter**: all modes byte-identical (712/712 at the session-33 audit;
  counts drift).  **Met.**

### Session kickoff prompt

```
Continue the Milk Tea self-host work in /home/teefan/Projects/Ruby/mt-lang
(branch `selfhost`). Work in tiers: iterate on the dev compiler
(ruby -Ilib bin/mtc build projects/mtc -I . --no-cache -o tmp/mtc-dev, ~50 s;
tmp/mtc-dev test projects/mtc -I . --timeout 120), measure only the class you
touch, and run the tier-2 proofs once on frozen sources — `tools/gates.sh`
prints the set (`--run` executes it, logs in tmp/gates/). Do not replay the
ledger's verified baselines unless the tree moved.

Read first: this file's Status at a glance, How to start a work session, and
The program (pick the next ranked item). The pre-compaction history is at
`git show d8a199c7:docs/self-host-plan.md`.

STEP 1 — one item per commit from the program's ranked list; each commit ends
with the gate set and this file's Ledger synced in the same commit; commit
trailer: Co-authored-by: CommandCodeBot <noreply@commandcode.ai>.

HARD RULES: never edit sources while a gate runs (bootstrap compiles the
working tree — check the exit status, not the tail); rebuild before measuring;
quote sets where a counter drifts; run generated binaries as
`timeout 10 bash -c 'ulimit -v 20000000; …'`; no hacks — fix root causes.
```

## The program — ranked remaining work

Goal: close every remaining self-host gap so `build/stage2/mtc` matches the Ruby
host on observable behavior everywhere — `--sexpr` dumps, CLI messages/commands,
LSP, DAP, linter, formatter, imported bindings, bindgen — while keeping the
self-host's documented improvements (malformed-frame recovery, synchronous
facts, speed, determinism).  **`lower` dump parity is closed (session 63);
CLI is the active front.**

Confirmed scope decision: **all** unported CLI subsystems are in scope (`deps`,
`docs`, wasm/emcc + preview, `--bundle`/`--archive`, `--jobs`, toolchain
bootstrap/tools, `--kind static|shared`, the bindgen policy flags).  Current
order: finish `lower` first, then CLI/linter/bindings, then the final matrix;
LSP/DAP/formatter are closed at their documented differences.  Anchor by symbol
names, not line numbers — lines drift.

### Track A — `lower` dump parity (CLOSED: 665/2 of 718)

Current set: **665 match / 2 differ / 51 host-rejected / 0 self-rejected of 718
files** (session 63).  The host-rejected bucket is `external` and platform-pinned
files; the count drifts with the tree and `tmp` fixtures — quote the set.

The two counted differs are the documented host artifacts, not work:

1. **`examples/memory_stress_test`** — the host's leaked `ref[@_mt_0, T]`
   lifetime; the self renders the declared `ref[T]` (see *Deliberate
   differences*).
2. **`projects/mtc/src/mtc/main.mt`** — the `--sexpr` loop-guard artifact (the
   dump exceeds the generated C loop guard's UTF-8 scan); documented under
   *Deliberate differences*.

Track A reached its stopping rule: **0 real differing files**.  Keep lex/parse
at 0-diff and re-measure both after any lowering-adjacent change.

### Track B — CLI parity (89 cases; 78 match, 11 pending)

The **original 65-case behavior matrix is byte-equal** (session 64; `--timings`
values and `debug`'s Ruby node ids normalized).  `debug`/`test`'s argument forms
and the bundle/archive cases closed there — see the session-64 batches.  The
fixed `pkg` fixture now builds and runs a real program (the old fixture used a
bare `print`, so its build/run cases only compared a semantic-error path).

Session 65 replaced the regex allowlist with case-backed pending metadata:
**89 cases / 78 match / 0 differ / 11 pending**.  The 65/65 figure is no longer
the matrix; the pending set is the work below, and a pending case that starts
matching must be promoted (the harness fails otherwise).  The session-65
second batch closed `parse`/`emit-c` multi+directory forms, `format`
multi/directory and its batch summaries, `check`/`lint` unknown-flag
validation, and `lint --init`.  Remaining work:

1. **Wasm/emcc + preview** — `projects/mtc/src/mtc/build.mt` ignores `Platform.wasm`.  Port
   `compile_wasm` and shell rendering (`lib/milk_tea/tooling/build.rb:26-69,704-779,900-937,953-960`,
   `lib/milk_tea/tooling/templates/wasm_shell.html`), `--preload-file` for `build.assets`, `.html`
   output, and `run --platform wasm` from `lib/milk_tea/tooling/run.rb`
   (`WasmPreviewServer` 11–207, `run_wasm_preview` 353–378,
   `wasm_target_requested?` 394–400 — **not** the 100-line
   `cli/commands/run.rb`) on `std/http/server.mt`.
   **Do not** add an emcc row to `toolchain doctor` (the host has none); reproduce
   the host's emcc resolution and `C compiler not found` error path
   (`build.rb:730,1112`).  Verify with emcc installed and byte-compare the HTML shell.
2. **`docs`** — port `lib/milk_tea/tooling/cli/commands/docs.rb` + `lib/milk_tea/tooling/docs_app.rb`
   routes (`/`, `/reference`, `/reference/`, `/stdlib`, `/stdlib/:name`,
   `/stdlib/:name/source/:file`, `/stdlib/:name/source/:file/hl`, `/api/search`)
   onto `std/http/server.mt`, reusing `lib/milk_tea/tooling/{views,public}`
   (541 lines) and `bindings/vscode/scripts/snapshot.js` +
   `themes/2026-dark.json`; `--port/-p`, `--open/-o`, the
   `Serving Milk Tea docs at <url>` line.  Acceptance: functional parity, not
   byte-identical HTML.  Exercise it with a dedicated smoke tool, not
   `cli_parity` (the host `docs` command starts a blocking server).
3. **`deps`** (largest: 14 package files / 3,039 lines **including** the
   485-line `manager_cli.rb`; 2,554 non-CLI) — port
   `lib/milk_tea/packages/*` into `projects/mtc/src/mtc/packages/*.mt` and
   `deps add|remove|update|tree|lock|publish|fetch`; extend
   `projects/mtc/src/mtc/loader/package_manifest.mt` (currently `source_root` only) into the full
   manifest/graph, wire `--locked`/`--frozen` and the package graph into
   `build`/`run`/`check`; network via `std/http`.  Verify against the host's
   `test/packages/*` fixtures and a local-registry probe.
4. **Harness** — the case-backed pending metadata is in place; promote each case
   as its subsystem lands and exit only at `differ=0 pending=0`.  Timing
   values are normalized (wall-clock measurements never compare byte-for-byte);
   the report structure still is.

Session-64 `toolchain`/`build --kind`/bindgen-nullable flips are recorded in
the session-64 second batch above; `toolchain doctor`'s rows are the one
deliberately simplified surface (see *Deliberate differences*).

Session-63 CLI flips: all 37 original diffs except `debug` — lex/parse/lower/
emit-c diagnostics and formats, check/lint/format/debug messages and channels,
package build/run entry points, `new`, `completions`, `std`, `test`, `cache`,
`toolchain`, `snapshot`.  Session 64 closed `debug` (shared renderer) and
`test`'s argument forms.

### Track C — linter corpus residue (496/122 of 618; 41/43 rules)

State: **496 agree / 122 differ of 618, hostfail 0, selffail 0** (session 65
re-read; this is the authoritative measurement after the host cache moved to a
content hash — the earlier 495/121 table was stale).  Per-rule deltas
(session-65 re-read; **pairs are self-only / host-only**, in that order):
`prefer-try` 75/39, `redundant-cast` 75/48, `prefer-let` 69/141,
`borrow-and-mutate` 31/0, `shadow` 20/0, `prefer-own-ptr` 16/38,
`constant-condition` 11/1, `prefer-or-pattern` 10/8,
`loop-single-iteration` 9/0, `unreachable-code` 4/0, `prefer-var-else` 2/0, and
one host-only `prefer-struct-with` (so that rule is not fully closed).  The
corpus count drifts with the tree; quote the set.  Closed with no residue:
`redundant-unsafe`, `owning-release-leak`, `owning-release-double`,
`prefer-inline-if`, `prefer-conditional-expression`.

Still absent: the host's **`directional-ffi-arg`** (`lib/milk_tea/tooling/linter/rules.rb:513-531`)
and **`platform-api-drift`** (`lib/milk_tea/tooling/linter/imports_platform.rb:32-62`) rules, and the
**`redundant-unsafe`** fix generator (41 of 43 rules, 12 of 13 auto-fixable).
No corpus file currently triggers the two missing rules — a file that does would
be the first visible difference.

Analyzer gaps that gate lint rows and LSP entries:

- **Null assignability pair** (session 22): a bare `null` into a non-nullable
  target (`return null` for `ptr[int]`/`str`) is unflagged (`ty_null` is
  kind-unknown in `definitely_incompatible`/`types_compatible`); and
  generic-vs-scalar pairs (`ptr[int]` → `str`) need the host's positive
  `call_argument_compatible?`/`implicit_ref_argument_compatible?` split.
  Assigning to an immutable parameter is also unflagged.
- **Constant-value coercion** (session 23): a folded constant that fits a narrow
  integer target is host-accepted and self-rejected (`return sdl.ALPHA_OPAQUE`
  from `-> ubyte`); the host folds via `evaluate_compile_time_const_value`
  (`semantic_analyzer/top_level.rb:280`) + `numeric_constant_fits_type?`, the
  self's `is_numeric_literal_valued_expr` sees only literal nodes/`if`-chains.
- **Member-assignment immutability** (session 28): the host rejects
  `x.field = …` through an immutable receiver and `this.field = …` in a
  non-editable method (host `infer_lvalue_receiver`,
  `lib/milk_tea/core/semantic_analyzer/expressions.rb:76`,
  `lib/milk_tea/core/semantic_analyzer/function_binding.rb:594-605`); the self
  has no such check, so `check` accepts
  sources the host rejects and `--fix` applies batches the host withholds
  (repro: an `extending Counter:` with a second block plus `this.value = 0`).
  Port the receiver-implicitness ladder and the generic-method scan.
- **`prefer-let` and specialized editable calls** (session 28): the self rewrites
  `examples/reflection_advanced.mt`'s `var r`, which must stay `var` because
  `r.unpack[CompactHeader]()` is editable; the editable-site recording misses
  the specialized editable call.
- **`--fix` unresolved-import guard** (session 28): the host's
  `fix_source_single_pass` refuses all fixes when an import did not resolve; the
  self proceeds.  The CLI lint path **does** fill
  `options.unresolved_import_paths` now (`main.mt:1090-1103`, before the fix
  branch); only the consumer is missing in `fix_engine.mt:79-108`.
- **Reserved-name errors** (session 28): the host raises `function int uses
  reserved built-in type name int` (module-level) and `local int uses reserved
  built-in type name int` (locals); the self checks only locals/params with a
  different message, and its module-level functions/consts/vars/events have no
  check (`ensure_non_reserved_value_type_name!`/`ensure_non_reserved_name!`).
- **Sema message rendering and return-mismatch position** (session 40): the host
  renders `return type mismatch: expected X, got Y` with its qualified `to_s`
  (`expected std.vec.Vec[int], got int`) at the return site; the self uses the
  display form and reports `0:0`.  `cannot assign to immutable x` is byte-equal,
  so the gap is this site's renderer/position.

Tool: `ruby tools/lint_parity.rb -q` (add `--host-cache FILE`; warm fill ~4 min,
then ~20 s per full run); `rake "parity:scoreboard"` for the per-rule table.

### Track D — imported bindings and bindgen

1. **OpenGL naming transforms — CLOSED (session 66).**  The six tables and
   seven functions are in `projects/mtc/src/mtc/imported_bindings/naming.mt`,
   with the host's `snake_case` gsubs, full-gsub `replace`,
   `openglize_binding_name`, split reserved sets, and the 37 golden vectors in
   `projects/mtc/test/imported_bindings_naming_test.mt`.  The emitter keeps
   type case, applies `types.overrides` (name/mapping/kind), resolves bare
   raw aliases (`Uint16 -> ushort`, `enet_uint32 -> uint`), projects handles in
   function-type params, builds method wrappers from the generated entries
   (modes, public types, exclusions), and tidy-formats the assembled module.
2. **29-binding verification — CLOSED (session 66).**  The self-only
   `imported-bindings` command has `--stdout` (byte comparison), `--json`
   (per-entry status + first diff offset/line), and `--soft`;
   `tools/imported_bindings_parity.rb` compares self vs host vs checked-in and
   classifies every changed binding.  The Phase-0 baseline was 3 verified / 26
   changed of 29; the landed result is **29 verified / 0 changed / 0 new of
   29** (`box3d` added to the self registry).  `bindings` and
   `bindings_parity` are hard gates.
3. **Bindgen gaps** — header-provenance filter in `walk` (`projects/mtc/src/mtc/bindgen.mt:346-445`;
   host `lib/milk_tea/bindings/bindgen/ast_parser.rb:105-132`, `allowed_declaration_name?`); unknown-type
   policy instead of echoing bare names (`projects/mtc/src/mtc/bindgen.mt:259`; host
   `lib/milk_tea/bindings/bindgen/type_mapper.rb:62` + `lib/milk_tea/bindings/bindgen/declaration.rb:123`); nested `const char*` → `cstr` in
   the pointer branch (`projects/mtc/src/mtc/bindgen.mt:169-190`; host `lib/milk_tea/bindings/bindgen/type_mapper.rb:21-22,528-532`);
   the typedef record/enum alias maps (`projects/mtc/src/mtc/bindgen.mt:730-737`; host
   `lib/milk_tea/bindings/bindgen/ast_parser.rb:159-176`, `synthesize_typedef_dependency:326-337`).  Verify by
   regenerating `std/c/*.mt` and diffing against the checked-in files and the
   host's output.

### Track E — LSP residue (closed at documented differences)

The LSP reached its Definition of Done: 30/30 capability keys, 4 documented
harness entries, the completion class closed, `debugInfo` byte-equal, valgrind
0, edit latency ≤ 10 ms, soak at 68.1 KB/cycle raw / 19.9 LS (the per-edit leak is owned by per-entry
regions; the one-time index walk's arena-leaked ASTs are a documented level, not
a slope, and the loader's small `qname_to_str` strings remain).  Remaining items are optional / documentation
decisions:

- **Ref-lifetime modelling** — the host's synthesized `ref[@_mt_N, T]` lifetime
  in a field detail (`mst@224:18`), where the self renders the declared
  `ref[T]`.  This is a documented deliberate difference; porting the host's
  `lib/milk_tea/core/semantic_analyzer/type_declaration.rb:516-522` auto-lifetime rewrite is only worth it if the
  same machinery is needed elsewhere.
- **Imported enum/flags member locations** — for `alias.Enum.member` the self
  resolves the member text and deliberately drops the location (matching the
  host's classifier miss).  Pointing both at the imported declaration would be a
  documented self-better difference; decide and document, don't drift into it.
- **Documented rows stay documented** unless their machinery is built for
  another reason (see *Deliberate differences* and `docs/lsp-design.md` §8).

### Track F — DAP manual check

The debug map, build-on-launch, pause diagnostics/modules, the lldb-dap bridge
and the process backend are done; `dap_smoke` is row-for-row equal except the
documented self-better `lldb-real frame0 name`.  Remaining: a live **VS Code F5**
session on a `.mt` program with the default `lldb-dap` backend (breakpoints,
stepping, evaluate; Milk Tea frames/locals via the debug map).

### Track G — compiler throughput (not parity)

The self compiles its own sources in ~157 s (`emit-c` of
`projects/mtc/src/mtc/main.mt`) where the host takes ~40 s (3.9×); a full
bootstrap pays it twice.  One profiling session on the self's front-end/lowering/
C-emit (candidates: repeated analysis/type resolution per module, the
string-heavy rendering paths, the C emitter's text building) buys every future
gate several minutes.  Behavior must not change — only wall time; verify with
`emit-c` timing plus the fixed point.

### Track H — final verification

On a clean tree: `tools/bootstrap.sh -j 16` (stage2 == stage3, 19/0),
`build/stage2/mtc test test/mt -I .` (60/0), the 15 top-level examples, sdl3
34/34, the raylib sample, the vendored families, `sexpr_parity` lex/parse/lower,
`cli:parity`, both LSP harnesses + valgrind + a Neovim and a VS Code session,
`dap_smoke` on both backends, `format_parity all`, `imported-bindings --all
--check`, the lint corpus, and `~/Projects/MilkTea/SimpleGame` building and
running.  Update this file's Ledger and any changed workstream docs.  Declare
done only when the Ledger shows every counter at its target.

## Deliberate differences (do not chase)

Parity work must not "fix" these.  The canonical LSP table is
`docs/lsp-design.md` §8 (12 rows with direction and pinning tool); the main
ones:

- **LSP harness (4 documented entries):** the host's parser recovery; the host
  hanging on a malformed frame (the self answers `-32700` and keeps serving);
  the host's facts lag (the self answers synchronously); the host's
  directory-form module `typeDefinition` path (where the self resolves the
  imported declaration the host's `module_path_for_name` cannot reach).
- **LSP audit (4 stable rows):** completion `mst@224:18` (the host leaks its
  synthesized `ref[@_mt_0, ubyte]` lifetime; the self shows the declared
  `ref[ubyte]`), completion `lb@818:17` (the host's facts give up on the
  `map_error` arm binding; the self answers the field), hover `type quat`
  `lb@1653:24` and documentHighlight `lb@704:67` (the host's warm index/facts
  carry-forward; byte-equal cold).  The canonical warm audit adds the 2
  builtin-hover warm artifacts, and the host's first-file `documentSymbol` race
  appears as ±drift, not a work item.
- **DAP:** `lldb-real frame0 name` — self `add`, host `main_add` (the host's
  cache-hit map loss).
- **`lower`:** the host's leaked auto-lifetime names (`ref[@_mt_0, T]`) in
  `memory_stress_test`; the self renders the declared `ref[T]`.
- **`lower` `main.mt` (`--sexpr` only):** the dump is ~59 MB and the compiler's
  own `String.as_str` UTF-8 validation legitimately scans more than the C
  backend's 50,000,000-iteration loop guard; the host-built stage1 aborts
  identically (`build/stage1/mtc lower projects/mtc/src/mtc/main.mt -I .
  --sexpr` -> rc 134 `loop iteration limit exceeded in str_is_valid_utf8`),
  while only the Ruby host (which has no guard) completes.  Not a parity gap;
  the non-`--sexpr` formatting path completes on both C compilers.
- **Better-than-host behaviours to preserve:** malformed-frame `-32700` + keep
  serving, synchronous facts with no lag, faster cold start, deterministic
  binding-map iteration; a capability the host lacks is not automatically a
  defect to remove.
- **`test --jobs N`:** validated and accepted, but the self still runs files
  sequentially.  The host's fork-per-file mode only changes wall time: its
  per-file results and order are identical, and it additionally folds each
  child's stderr into its stdout (a buffering artifact).  The sequential run
  keeps the streams correct; this is a throughput-only difference, not a
  behavior gap.
- **Bundle archive bytes:** `--archive`'s `.tar.gz` has the host's entry
  layout/order and extracts identically, but the bytes are not fixed (the
  host's TarWriter stamps entries with the current time).  The MTAP asset
  pack, which carries the assets, is byte-identical.
- **Build cache namespaces:** both compilers honor the shared
  `<data_root>/tmp/mtc-cache` root, but the self's entry layout
  (`<hash>/{key,binary}`) and key material differ from the host's
  (`programs|binaries/<2>/<sha>`), so cached artifacts are not shared across
  implementations.  Each compiler's cache still works independently.
- **Platform set:** the self's resolver targets `linux`, `windows` and `wasm`;
  the host's option parser also knows `darwin`, which the self does not target
  anywhere (no resolver variant, platform-pinned suffix, or build flags).  An
  invalid `--platform` value is still rejected on stderr as the host does.
- **Self-only `imported-bindings <name>|--all [--check]` command:** the host
  `COMMANDS` table has no such entry.  It is the self-host's binding-generation
  verification entry point (Track D) and stays; do not add it to the host
  command table.
- **`toolchain doctor` (open gap, Track B 1.5 — not a deliberate difference):**
  the self currently prints six `ok <name>` rows with no preambles; the host
  prints `Checking system tools...` with 8 rows (`ruby`, `cc`, `ar`, `bundle`,
  `git`, `clang`, `cmake`, `ninja`) in `ok <name>: <detail>` form, then 18
  vendored-sentinel rows and one row per raw `std.c.*` binding header.  Track B
  1.5 closes this to byte parity; only a self-relevant row-set decision may remain
  here, with a pinned `cli_parity` normalization.
- **`build --kind static|shared`:** the host's own path raises
  `NoMethodError: generate_header`, so there is no reference output.  The self
  archives a clean `ar rcs` (or links `-shared -fPIC`) and gives `public`
  top-level functions external linkage; no C header is generated (the host's
  generator is missing).  Executable C output is unchanged.

## Ledger

Last verified numbers; re-measure only the classes a change can move, and only
when the tree moved.  Target = the Definition of Done above.

| Gate | Live | Measured | Command |
| --- | --- | --- | --- |
| bootstrap fixed point | holds (`stage2.c == stage3.c`); 19 files / 0 failed | session 65 (`--fast`, at `c5a9bcd4`) | `tools/bootstrap.sh -j 16 --fast` |
| `test/mt` | 60 files / 0 failed | session 65 | `build/stage2/mtc test test/mt -I .` |
| examples / sdl3 | 49/49 same under the gate (15 top-level + 34 sdl3) | session 63 | `tools/gates.sh --only examples --run` |
| `sexpr lex` / `parse` | lex 718/718; parse 714 match / 0 differ / 4 host-rejected of 718 | session 63 | `ruby tools/sexpr_parity.rb lex\|parse -q --host-cache tmp/sexpr-host-cache` |
| `sexpr lower` | 665 match / 2 differ / 51 host-rejected / 0 self-rejected of 718 (the 2 are documented artifacts) | session 63 (stage2) | `ruby tools/sexpr_parity.rb lower -q -j 16 --host-cache tmp/sexpr-host-cache` |
| `cli:parity` | **78 match / 0 differ / 11 pending** of 89 (case-backed; the original 65/65; timings and `debug` node ids normalized) | session 65 | `ruby tools/cli_parity.rb -q` |
| lint corpus | 496 agree / 122 differ of 618, hostfail 0, selffail 0; **41/43 rules, 12/13 fixers** | session 65 | `ruby tools/lint_parity.rb -q` (`--host-cache`) |
| unused-import | 616/616 | session 64 | `ruby tools/unused_import_parity.rb` |
| LSP harness | 30/30 capabilities; 4 documented entries of 70 requests + 27 probes | session 38 (re-verified session 49) | `tools/lsp_parity.rb record/compare --stress` |
| LSP project audit | canonical 6 (4 documented + 2 warm artifacts); non-canonical 4–5 ±drift | session 43 | `tools/lsp_project_audit.rb --workspace ~/Projects/MilkTea/SimpleGame [--canonical]` |
| LSP recovery | 6/6 byte-equal | session 37 | `tools/lsp_recovery_probe.rb --check` |
| LSP edit latency | 4.9 ms median per `didChange`; `didOpen` ~52 ms cold | session 29 | `ruby tmp/lsp_edit_perf.rb --bin <bin>` (transient probe) |
| LSP valgrind | 0 errors over the harness drive; ~64 KB definitely-lost per 10-cycle soak (one-time index level) | session 38 | `tools/gates.sh --only valgrind_lsp --run` |
| LSP soak | 68.1 KB/cycle raw / 19.9 KB/cycle least-squares at 200 cycles | session 38 | `ruby tools/lsp_soak.rb --cycles 100` |
| formatter | 712/712 all three modes byte-identical | session 33 | `ruby tools/format_parity.rb all -j 16` |
| DAP | zero differing rows except the documented self-better frame0 row; harness now asserts (non-zero on an unlisted diff) and requires a real `lldb-dap` | session 65 (assertion layer) | `ruby tools/dap_smoke.rb` (`--allow-skip` to waive a missing adapter) |
| imported bindings | **29 verified / 0 changed of 29** | session 66 | `build/stage2/mtc imported-bindings --all --check`; `ruby tools/imported_bindings_parity.rb` |

## Porting notes

Gotchas that cost rebuild cycles; apply them before writing code.

- `Analysis.resolved_expr_types` / `resolved_call_kinds` / `const_values` are
  keyed by **expression pointer** (`reinterpret[ptr_uint](ep)`); `Type`-valued
  maps (`types`, `type_alias_types`, `static_member_types`) are name-keyed.  A
  caller that re-parses must lint/analyze the *analysis' own AST* or rebuild the
  analysis from its parse (the fix engine does the latter per pass).
- `analysis.types` maps names (aliases resolved) → `Type`; enums/flags/variants
  are `ty_named` and also appear in `analysis.static_member_types`.
- `Map.get` returns `ptr[T]?` (nullable pointer); `Vec.get` returns
  `Option[ptr[T]]`; `read()` needs a narrowed *local*, not a struct field.
- Avoid language keywords as identifiers: `emit`, `match`, `type`, `link`,
  `include`, `event`, `final`, `inline`, `parallel`, `when`, `opaque`, `ref`,
  `own` (a function named `emit` failed to parse; a local `match` too).
- The self-host analyzer's binding ids are **name-keyed** where the host's are
  per-declaration (several gates note this; e.g. `dead-assignment`'s origin gate,
  the documentHighlight carry-forward).
- `resolve_cursor` facts must come from the loader-backed
  `analysis_for_document` / `ast_for_document`, never the standalone
  `check_source_file` (its `imported_modules` is null).  The host aborts a file
  at its first semantic error; probe one shape per file.

## Risks and notes

- **`lower` tail:** every fix moves files' first differences deeper and can
  expose new families; the ranked order + sweep loop is the process, and the
  stopping rule is 0 differ or a documented host artifact with a reproduction.
- **`deps`** is the largest single CLI subsystem (~3,000 lines); keep the port
  mechanical (module-per-file mirroring the Ruby layout) and use the host's
  `test/packages/*` as the spec.
- **emcc** may not be installed here; reproduce the host's detection/error text
  and verify the wasm path where emcc is available.
- **Throughput prices every gate** (3.9× self-to-host); Track G is optional but
  pays back across all future sessions.
- **History:** the full session records were removed from this file; they remain
  at `d8a199c7` and earlier.  If a compact digest of sessions 44–50 is wanted,
  add it in ≤30 lines rather than growing the file.

## Provenance

This file is the single self-host planning document; it absorbed the former
`docs/foundational-blockers-plan.md`, `docs/lsp-parity-plan.md`,
`docs/self-host-stress-todo.md` and the machine-local session plans on
2026-10-03 (session 25).  It was compacted to the current operational state in
session 50 (2026-11-08); the pre-compaction version, including §0a–§0k, §1–§7
and the Appendix, is at commit `d8a199c7`
(`git show d8a199c7:docs/self-host-plan.md`), and earlier originals are in git
history.  `projects/stress` parity (build, output and exit status identical)
was recorded done in the pre-compaction history.
