# Milk Tea Self-Hosting Plan

This document tracks the plan, context, and progress for making the Milk Tea compiler self-hosting (written in Milk Tea, compiled by itself).

## Motivation

The Milk Tea compiler is currently written in Ruby. Self-hosting brings:

- The compiler becomes its own most demanding test suite — a large, real-world Milk Tea program
- Compiler performance improves (native binary vs interpreted Ruby)
- No external Ruby dependency for building Milk Tea programs (only a C compiler + committed bootstrap C)
- The language matures by confronting real systems-programming challenges

## Strategy

**Incremental stage-by-stage porting with JSON IR contracts between stages.**

Each pipeline stage is an independent program that consumes JSON from the previous stage and produces JSON for the next. A Milk Tea implementation of any stage can be verified by feeding its JSON output into the next stage of the Ruby compiler and confirming the final generated C is identical.

```
.mt source
    │
    ▼
┌──────────┐  Token JSON   ┌──────────┐   AST JSON   ┌───────────────────┐
│  Lexer   │ ────────────→ │  Parser  │ ───────────→ │ Semantic Analyzer │
│ (Stage 1)│               │ (Stage 2)│              │ (Stage 3)         │
│  DONE ✓  │               │  DONE ✓  │              │     later         │
└──────────┘               └──────────┘              └───────────────────┘
                                 │                           │
                           (AST JSON: emit-only,      Analysis JSON
                            no re-inject path)              │
                                                            ▼
┌───────────┐   C source    ┌──────────┐    IR JSON   ┌──────────┐
│ C Backend │ ←──────────── │ Lowering │ ←─────────── │ (Stage 3 │
│ (Stage 5) │               │ (Stage 4)│              │  output) │
│  partial  │               │  NEXT    │              │          │
└───────────┘               └──────────┘              └──────────┘
```

\* Stage 4's verification oracle was repaired (June 2026): `lower --from-analysis-json`
now produces IR JSON structurally identical to `lower` from source. See below.

### Current state (June 2026)

| Stage | Status | Verification |
|---|---|---|
| Lexer (1) | **DONE** | 476/476 files, positions included, 0 diffs |
| Parser (2) | **DONE ✓** | 13/13 pass, accuracy=0, shape=0 (~40% positions done) |
| Lowering (4) | **NEXT** | Oracle repaired — verified structurally identical IR JSON |
| C Backend (5) | partial | Prototype with known correctness gaps |
| Semantic Analyzer (3) | later | ~13k+ lines Ruby |

### Verifiable boundaries (the real constraint on stage order)

Only three JSON hand-off points are actually wired into the Ruby CLI, and they
determine which stages can be verified end-to-end:

| Boundary | Re-inject flag | Oracle quality |
|---|---|---|
| Token JSON | `--from-tokens-json` | clean ✓ (Lexer done) |
| AST JSON | **none** (`--emit-ast-json` only) | structural AST diff only — fast, reliable |
| Analysis JSON | `--from-analysis-json` | **clean ✓** (repaired June 2026) |
| IR JSON | `--from-ir-json` | clean |

Consequences:
- **There is no `--from-ast-json`.** The self-host parser's output can never be
  fed into Ruby's sema; its only verification is structural AST-JSON diffing
  (exactly what the parity harness does). That is a valid, reliable oracle.
- **Stage 4's oracle is now repaired** — `check --emit-analysis-json` produces
  a bundle with root + all imported module analyses; `lower --from-analysis-json`
  detects the bundle format and resolves `ModuleBindingStub` stubs through
  `ImportAnalysisProxy` with `method_missing` delegation and recursive import
  resolution. Verified structurally identical IR JSON vs `lower` from source.
- **Size asymmetry:** sema is ≈13k+ lines; lowering's transform is only 372
  lines of Ruby, but it consumes a heavy Analysis JSON (a 367-LOC source
  produces a ~242 KB Analysis JSON — ~660 B/line).

**Next phase = finish the Parser to true 100% parity** (it has a clean, reliable
oracle and bounded remaining work), *not* Stage 4. Re-evaluate Stage 3 vs Stage 4
afterward, and fix Ruby's `--from-analysis-json` faithfulness as a prerequisite
to Stage 4.

### Key design rules

1. **Each stage is independently developable and testable.** Stage N only needs to understand its input JSON and produce correct output JSON. It does not need the other stages to exist in Milk Tea.

2. **The JSON contracts are the single source of truth.** The schemas are derived from the Ruby compiler's existing data structures. If a schema needs to change, both sides update together.

3. **The Ruby compiler is the safety net throughout.** At every phase, any missing or broken Milk Tea stage can be substituted with the Ruby version. There is never a point where the compiler stops working.

4. **Stages are built front-to-back, with the C backend pulled forward.** Lexer → Parser → C Backend → Lowering → Semantic Analyzer. The C backend is simple (walk IR tree, print C) and unlocks self-hosting capability early.

5. **Bootstrap is always O(1).** A system C compiler + committed bootstrap C files is the only requirement to build the compiler from scratch. No chain of historical compiler versions.

---

## Stage 1: Lexer — DONE ✓

**Location:** `projects/mtc/src/lexer/`

**Verification:** Full structural parity (token JSON) against Ruby across the **entire 476-file corpus** (examples, stdlib, tests), **positions included.** 0 diff tokens on any file. Verified via the differential parity harness (`projects/mtc/tools/parity.rb`), which classifies any divergence as accuracy/shape/position.

**Features implemented:**
- All literal types: integers (dec/hex/bin with `_` and type suffixes), floats (scientific, f/d suffix), strings, cstrings, char literals (with `\xNN`), heredocs (`<<-`, `c<<-`, `f<<-`), format strings with interpolation and format specs
- Indentation-based blocks (INDENT/DEDENT), line continuation after operators, grouping depth suppression
- All operators (1-char, 2-char, 3-char), all 54 keywords
- Adjacent string concatenation, comments (`#`)
- Token JSON output with `type`, `lexeme`, `literal`, `line`, `column`, `start_offset`, `end_offset`

**Key fixes applied during parity drive:**
- Integer literal overflow: `parse_int` now returns `ulong` (was 32-bit `int`)
- Heredoc trailing-newline: literal ends with `\n`, lexeme stops at terminator text
- f-string heredoc interpolation: `f<<-` now parses `#{...}` parts
- f-string text escape decoding: `\n`/`\r`/`\t` decoded like regular strings
- Multiline-string line-number off-by-one: `lex_strlit` now sets `line_off` to the last physical line's start
- f-string expr column: recorded at expr start, not after `}`
- EOF trailing dedent line number: emitted at `line_num - 1` (matching Ruby's `@line_count`)
- Adjacent-string indent guard: continuation lines must be strictly more indented than the opening line
- All fixes verified by the differential parity harness

**Code size:** ~1300 lines in `lexer.mt` + 66 lines `keywords.mt`.

**Tests:** 20 regression tests + 29 parser tests in `src/test/`, run via `mtc test` (49/49 pass).

**CLI:** `mtc lex <file>` — outputs token JSON to stdout.

**Architecture note — `Token.lit_json` ownership:** `Token.lit_json` is now an **owned `String`** (was a bare `str` slice that dangled in the token-vector path used by `lex_to_tokens`). This was necessary so the parser can safely read integer/float/string/char literal values from tokens. The per-parse leak is bounded (one-shot tool); listed as a future cleanup item.

---

## Stage 2: Parser — DONE ✓ (substantially complete)

**Location:** `projects/mtc/src/parser/`

**Verification:** Differential parity harness (`projects/mtc/tools/parity.rb`). **13 of 13 examples fully pass (0 diffs) with --ignore-positions.** Positions are partially implemented (~40% done, 11497 remaining diffs, all null vs real values). 0 errors, crash-safe by construction. **49/49 internal tests pass.**

All structural diffs eliminated. The remaining work is Milestone B: completing positions on the remaining ~10 inline JSON builder sites and sub-node type fields (TypeRef, params, etc.).

**Code size:** ~4270 lines (parser.mt), up from 1180.

**Architecture:**
- `token_stream.mt` (68 lines): peek/advance/check/match/consume cursor over `Vec[lexer.Token]`
- `ast_json.mt` (115 lines): AST JSON emitters with `$mt_type` and `$sym` encoding matching Ruby format
- `parser.mt` (~3200 lines, up from 1180): **fully recursive-descent parser** including declarations, type expressions, expressions, and statements

### What is implemented and contract-conformant

**Declarations — fully populated:**
- All declaration types: const, var, type alias, function, async function, const function, external, foreign, struct (with implements + fields), union (with fields), enum (with backing + members w/ auto-increment), flags, variant (with arms), opaque, interface, extending, attribute, static_assert, event, when, public
- **Types** (`TypeRef`, `QualifiedName`, `TypeArgument`, `FunctionType`, `ProcType`, `DynType`, `TupleType`): production `parse_type` with generics, nullable, lifetime (`@a`), `fn`/`proc`/`dyn`/tuple forms, int/float type-args
- **Const/var values**: literal values (int/float/bool/null/string/char/cstring), and **full expression values** via `parse_expr`
- **Visibility**: always emits `private`/`public` symbol (contract requirement)
- **Type parameters**: `TypeParam`/`ValueTypeParam` with `implements` constraints for functions, structs, and interfaces
- **Struct/union/variant fields, enum/flags members**: parsed with auto-increment (matching Ruby's `parse_enum_decl`)
- **Static_assert**: parses the actual condition + message expressions
- **Implements clause**: emits `QualifiedName` nodes (not strings), with type-arguments for generic interfaces
- **Extending type_name, event capacity/payload**: emits `TypeRef` / captures capacity
- **Extending/interface method bodies**: `parse_method_block` parses the indented method list and emits `MethodDef` (extending: type_params + params + return_type + crash-safe body + kind/visibility) or `InterfaceMethodDecl` (interface: params + return_type + kind, no body/visibility). Method `kind` (`plain`/`editable`/`static`) and `async` are parsed from the head. Crash-safe: the block's matching dedent is found up front and the cursor is snapped to it regardless, and each node is emitted with no early return so the JSON is always well-formed.

**Expression parser — full precedence ladder:**
- Precedence-climbing binary operators (or → and → pipe → caret → amp → equality → comparison → shift → additive → multiplicative)
- Unary operators (`not`, `-`, `+`, `~`), `await`
- Postfix: member access (`.`), index (`[expr]`), call (`(args)` with named args), `?` propagation
- Primary: all literals (int/float/string/cstring/char/bool/null), identifiers, paren/tuple → `ExpressionList`, `size_of`/`align_of`/`offset_of`, typed null (`null[T]`)
- **Prefix casts** (`int<-expr`, `char<-expr`, etc.) — detected via type-like name + `<` `-` adjacency and emitted as `PrefixCast`
- **Specialization** (`Option[int]`, `array[int,4]`, `damage_one[NPC]`): accurate classification via a token pre-pass that collects known-generic-callable names (`function NAME[`), plus builtin-list and receiver-name/content-type checks. Emits `Specialization{callee, arguments}` with `TypeArgument` nodes.
- **Match expressions** (both statement and value positions): patterns with `|` alternatives, `as` bindings, block-form arms → `MatchArm`, expr-form arms → `MatchExprArm`, `MatchStmt` / `MatchExpr` / `ExpressionStmt`
- **Proc expressions** (`proc(params) -> ret: body`): inline body → `[ReturnStmt]`, block body → statement list, `ProcExpr`
- **Format strings** (f-strings): `FormatString` from fstring token lexeme, with `FormatTextPart`/`FormatExprPart` and standalone expression re-parsing (`parse_standalone_expr`) for `#{expr}` interpolation. `format_spec` JSON conversion for `:b`/`:x`/`:B`/`:o`/`:O`/`.2`.

**Statement parser — leaf + control-flow, crash-safe by construction:**
- **Crash-safe foundation**: non-aborting `consume` (sets `stmt_failed` instead of `fatal`), **cursor save/restore** around each function body (find matching dedent up front, parse, snap cursor to end regardless, discard JSON on failure), and always-advance primaries (no hangs)
- **Ledger statements**: `pass`, `break`, `continue`, `return [expr]`
- **Locals**: `let`/`var` (name + type + value + `else:` / `else as name:` guard blocks)
- **Assignment / expression-stmt**: full assignment operators (`+=`, `*=`, etc.) with the `end_or_fail` guard
- **Control flow**: `if`/`else if`/`else` (block + inline branches), `while`, `for` (bindings + iterables), `defer` (block + inline), `unsafe` (block + inline), **inline** `for`/`while`/`match`/`if` (with `inline:true`)
- **Match** / **when** statements — dispatched to the respective parsers
- All body discards eliminated — every statement/expression form is handled directly (not via `stmt_failed` fallback)

### Remaining work (edge cases only)

| Feature | Diffs | Notes |
|---|---|---|
| Milestone B: positions | 11497 | ~40% done. All declaration-level positions done. Remaining: ~10 inline JSON builder sites and TypeRef sub-nodes. |
| Milestone B: positions (inline) | — | Remaining sites in: parse_type, parse_type_params_json, parse_struct_params, parse_return_stmt, parse_if_branch, parse_while_stmt, parse_defer_stmt, parse_unsafe_block_stmt, parse_when_stmt, parse_proc_expr, parse_dyn_type, parse_callable_type |

All other features from the original remaining-work table are **DONE**: declaration-level `when` block, extending/interface methods, qualified receivers, struct body, lifetime params, packed/alignment, f-strings with FormatString, `parallel for`, destructure locals, `gather`, `detach`, `unsafe:` expression, `is` expression, field-level attributes, `static_assert` statement, emit block parsing (EmitStmt), prefix cast with type args, `*_of` keywords.

---

## Next Phase: unblock and implement Stage 4 (Lowering)

The Parser is done. The next viable stage is **Lowering (Stage 4)**. Reasoning:

### Why not Stage 3 (Sema) next?
- Sema is ~13k+ lines (name_resolution 1454, expression_checker 1681, statement_checker 1261, etc.) — the largest, hardest stage by far.
- Sema has NO clean JSON boundary on its *input* side (no `--from-ast-json` in CLI). Verification would require a custom AST-JSON reader path in Ruby.
- Sema would benefit from having the self-hosted lowering verified first — so its output (Analysis JSON) can be fed through a trusted lowering pipeline.

### Why Stage 4 (Lowering)?
- **372 lines** of Ruby — the smallest stage.
- Its input ("Analysis JSON") CAN be emitted by Ruby's `check --emit-analysis-json`, so it doesn't depend on Stage 3 being ported.
- Its output ("IR JSON") CAN be fed into `ruby bin/mtc emit-c --from-ir-json` → C output can be diffed against Ruby's. **A complete end-to-end verification pipeline exists once the oracle is fixed.**
- A verified self-host lowering + C backend forms a **complete self-hosted backend** (analysis in, C out) that can compile real programs independently of the Ruby compiler.

### Prerequisite: fix the `--from-analysis-json` oracle
Before any Stage 4 work begins, Ruby's `lower --from-analysis-json` must produce IDENTICAL IR JSON to `lower` from source. Currently it loses module/import context (emits `unknown identifier stdio`) and exits nonzero on some files. This is the unblocking task.

**Next phase = implement Stage 4 (Lowering).** The oracle is repaired.

### Execution order
1. **~~Repair Ruby's `--from-analysis-json` faithfulness~~** — **DONE** (6 bugs fixed)
2. **Implement self-host lowering** — the next step: reads Analysis JSON bundle, lowers to IR JSON
3. **Verify end-to-end**: `check --emit-analysis-json` → self-host `lower` → `emit-c --from-ir-json` → diff C output
4. **Improve C backend** (address known gaps from the architecture review)
5. **Stage 3 (Sema)** — now has a verified lowering+backend to feed into, making verification tractable

### New pitfalls from Stage 2

- **`inline` is a Milk Tea keyword** — cannot be used as a parameter name. Use `is_inline` instead.
- **`consume()` fatally aborts.** The body-parse path must use non-aborting `consume` (sets `stmt_failed` instead). The global `consume` wrapper in `parser.mt` was changed to be non-aborting for the body path.
- **Cursor save/restore is critical for crash-safety.** Before parsing any block body, find the matching dedent (the body end), record it, then parse. After parsing, snap `p.tokens.pos` to the recorded end regardless of success/failure. This bounds any desync to the body and guarantees the declaration parse is never corrupted.
- **Heuristic specialization classification measures net-negative.** The specialization decision (`IndexAccess` vs `Specialization`) was attempted twice with heuristics (capitalization + builtin-list); both times measured net-negative because partial-correctness backfires — a kept-but-imperfect body explodes into many leaf diffs. The accurate approach uses **known-name tracking** via a token pre-pass that collects generic-callable names, plus builtin-list + capitalization + **content-type check** (bracket content is a type → specialization regardless of receiver name). This combined approach is accurate and net-positive.
- **Block-consuming value expressions need special handling at statement-end.** When a `let`/`return` value is a block-form proc or match expression, the expression's block already consumed its trailing dedent — the cursor lands at the *next* statement, not at a newline. The `end_or_fail` guard would falsely flag this as a desync. The fix: `block_expr_done` flag set by block-form value expressions, checked+consumed by `end_or_fail`, so the statement-end logic skips the end-of-statement check when the block already ended it.
- **Member-name tracking for specialization.** Specialization can occur on qualified names (`module.Type[args]`), not just bare identifiers. The parser tracks the *last member name* in `recv_ident` (updated on `.member`, cleared on `[`/`(`/`?`) so that `member[Type]` is correctly classified.

### Code size (parser.mt)

~4270 lines (up from the original 1180-line skeleton).

### Tests

49 tests (20 lexer + 29 parser). Run via `mtc test`. All pass (49/49).

### CLI

`mtc lex <file>` + `mtc parse <file>` + `mtc test`.

---

## Differential parity harness

**Location:** `projects/mtc/tools/parity.rb`

A Ruby script that serves as the CI-gradable oracle for contract-conformance. For each stage (`lex`/`parse`) and each corpus file:
1. Runs the self-host binary (sandboxed: `timeout` + `ulimit -v`) and the authoritative Ruby CLI.
2. `JSON.parse` both outputs and performs a recursive structural diff.
3. Classifies each divergence as **ACCURACY** (objectively wrong about the source), **SHAPE** (valid-but-different representation / field presence), or **POSITION** (`line`/`column`/`*_offset`/`*_length` and any key ending in `_line`/`_column`/`_offset`).
4. Aggregates pass/fail/bucket counts; exits nonzero on any non-position diff (Milestone A; `--ignore-positions` toggles).

**Usage:**
```
ruby projects/mtc/tools/parity.rb <lex|parse|both> [FILES...] [--ignore-positions] [--build] [--first N]
```

This harness was used to drive the lexer to 100% parity and the parser through all the progress documented above.

---

## Stage 4: Lowering — NEXT

**Goal:** Consume Analysis JSON (from Ruby `check --emit-analysis-json`), produce IR JSON consumable by `ruby bin/mtc emit-c --from-ir-json`.

**Oracle status: REPAIRED ✓.** `lower --from-analysis-json` now produces IR JSON structurally identical to `lower` from source (verified with complex inputs: imports, constants, control flow, f-strings, function calls). The repair involved 6 fixes:
- Bundle format (`$mt_analysis_bundle`) for `check --emit-analysis-json`
- `ImportAnalysisProxy` with `method_missing` delegation and recursive import resolution
- `FunctionBinding` owner patching for deserialized bindings
- Fallback `to_s`-based type lookup for deserialized type identity

**Steps:**
1. Parse Analysis JSON into internal representation
2. Lower types: structs, enums, unions, variants, opaques → IR type declarations
3. Lower constants, globals → IR values
4. Lower functions: parse AST bodies → IR statement/expression trees
5. Produce IR JSON matching `Serializer.ir_to_json`

**Verification:** Produce IR JSON → feed into `ruby bin/mtc emit-c --from-ir-json` → confirm C output matches Ruby's. (Requires the blocker above to be fixed.)

**Prerequisites:**
- **Fix the `--from-analysis-json` faithfulness blocker above.**
- Read `lib/milk_tea/core/lowering.rb` (372 lines) for the lowering architecture
- Read `lib/milk_tea/core/serializer.rb` `ir_to_json` for the exact IR JSON contract
- The `lower` command has `--from-analysis-json` flag (line 810 of cli.rb); `check --emit-analysis-json` (cli.rb:657) produces the input
- Budget for the heavy Analysis-JSON reader, not the 372-line transform (a 367-LOC source → ~242 KB Analysis JSON)

---

## Stage 5: C Backend — partial (prototype)

**Location:** `projects/mtc/src/c_backend/`

**Architecture:**
- `ir_reader.mt` (220 lines): `IrCursor` — lazy, zero-allocation JSON field reader using borrowed `str` slices
- `c_backend.mt` (756 lines): recursive C emitter from IR JSON

**Verification:** Self-host `emit-c` produces C source from IR JSON. Verified with `cc -std=c11` → compiles and runs correctly for structs, enums, constants, globals, if/while/for, aggregate literals, function calls (simple standalone programs only).

**Architecture review (June 2026):** The implementation handles a working subset but has several correctness gaps relative to the Ruby contract:

- **Member access never emits `->`.** `IR:Member` always emits `.`; Ruby chooses `->` for pointer receivers (`pointer_member_receiver?`). Any pointer-receiver member access generates wrong C.
- **Pointer params/locals drop the `*`.** The param emitter and `type_to_c` ignore the IR `Param.pointer` field.
- **Indirect calls dump raw JSON.** `Call.callee` may be an expression node; the emitter only handles string callees. Object callees (function pointers, method dispatch) emit raw `{…}` JSON.
- **Struct field types bypass type dispatch.** `emit_structs` uses `c_type(field_str("name"))` instead of `type_to_c`, so struct/union/pointer-typed fields get no `struct`/`*` prefix. Same shortcut in `Cast`/`Sizeof`/`Alignof`/`Offsetof`.
- **Type coverage is thin.** `type_to_c` only dispatches on `Struct`/`Union`; everything else falls to `c_type_str(name)` which only handles a fixed list of primitives. Pointer, Span, Enum, Flags, Opaque, StringView, Variant, Function/Proc/Tuple/Dyn refs are not handled.
- **Variants unimplemented.** `emit_variants` is a `pass` stub; `VariantLiteral` emits `{0}`.
- **`field_str` doesn't unescape JSON** — string-literal values with escapes/embedded quotes produce malformed C.
- **O(n²) performance.** Every `field_*` rescans the object from offset 1; arrays re-split on each pass. Acceptable for small inputs; a bottleneck for self-hosting a large compiler IR.

These are confirmed against the Ruby `c_backend/expressions.rb`, `ir.rb`, and `serializer.rb`. The C backend is correctly labeled "partial" — it handles a narrow subset faithfully enough for simple programs, but is not a faithful port of the Ruby C backend.

---

## Pitfalls (cross-cutting)

### General

- **Sandbox every self-host binary invocation** with `timeout` + `ulimit -v`. Per-invocation, never loop over many inputs without a timeout.
- **Run `mtc test` after every commit** that changes the parser or lexer. The parity harness is the primary oracle, but the internal 49 tests are the regression gate. They can silently break when AST enrichment changes node counts (e.g., the `parse_and_get_decls` skeleton-era heuristic broke when types/values populated the AST).

### JSON contracts, Milk Tea, and parser design

- String lifetimes: return `String`, not `str`, from functions that build local buffers. "string.as_str text must be valid UTF-8" crashes come from dangling `str` slices.
- `Token.lit_json` owned-String fix: see Lexer architecture note above.
- `inline` is a reserved keyword — use `is_inline` as a parameter name.
- `match` is a reserved word — use as expression only, not function name.
- `out` is a keyword — don't use as variable name.
- Bracket-depth tracking: increment AFTER consuming `[`/`(`, decrement AND advance past `]`/`)` in the same conditional block.

### C backend specific

- `c_type(str)` returning `str` creates dangling references — always return `String` and release at call site.
- JSON field reading with `$`: `$mt_type` and `$type_ref` are valid field names in IR JSON.
- Array element iteration: use `split_array_elements` with depth tracking for nested objects.
- IR type objects may have null `linkage_name` — generate from `module_name + "_" + name`.
