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
│  DONE ✓  │               │ IN PROG  │              │     later         │
└──────────┘               └────┬─────┘              └───────────────────┘
                                │   ◀── NEXT PHASE: finish to 100%
                          (AST JSON: emit-only,                  │
                           no re-inject path)              Analysis JSON
                                                                 │
                                                                 ▼
┌───────────┐   C source    ┌──────────┐    IR JSON   ┌──────────┐
│ C Backend │ ←──────────── │ Lowering │ ←─────────── │ (Stage 3 │
│ (Stage 5) │               │ (Stage 4)│              │  output) │
│  partial  │               │ blocked* │              │          │
└───────────┘               └──────────┘              └──────────┘
```

\* Stage 4's verification oracle is broken in the reference compiler: Ruby's own
`lower --from-analysis-json` is unfaithful (loses module context — e.g. emits
`unknown identifier stdio` — and exits nonzero on some files) versus `lower`
from source. That reference path must be repaired before any self-host lowering
port has a trustworthy oracle. See "Verifiable boundaries" below.

### Verifiable boundaries (the real constraint on stage order)

Only three JSON hand-off points are actually wired into the Ruby CLI, and they
determine which stages can be verified end-to-end:

| Boundary | Re-inject flag | Oracle quality |
|---|---|---|
| Token JSON | `--from-tokens-json` | clean ✓ (Lexer done) |
| AST JSON | **none** (`--emit-ast-json` only) | structural AST diff only — fast, reliable |
| Analysis JSON | `--from-analysis-json` | **broken in Ruby itself** (see \* above) |
| IR JSON | `--from-ir-json` | clean |

Consequences:
- **There is no `--from-ast-json`.** The self-host parser's output can never be
  fed into Ruby's sema; its only verification is structural AST-JSON diffing
  (exactly what the parity harness does). That is a valid, reliable oracle.
- **Stage 4's oracle is broken** (see \*), so Stage 4 is *blocked* on first
  repairing Ruby's analysis-JSON re-injection faithfulness.
- **Size asymmetry:** sema is ≈13k+ lines (name_resolution 1454,
  expression_checker 1681, statement_checker 1261, …); lowering's transform is
  only 372 lines, but it sits behind a heavy Analysis-JSON reader (a 367-LOC
  source produces a ~242 KB Analysis JSON — ~660 B/line).

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

## Stage 2: Parser — IN PROGRESS (next phase: finish to 100%)

**Location:** `projects/mtc/src/parser/`

**Verification:** Differential parity harness (`projects/mtc/tools/parity.rb`) comparing self-host `mtc parse` AST JSON against `ruby bin/mtc parse --emit-ast-json` on the examples corpus with `--ignore-positions` (Milestone A). **6 of 13 examples fully pass (0 diffs); total diffs 72 (accuracy 57, shape 15).** Parser is **crash-safe by construction** for the statement/expression/method paths across the corpus — verified via the sandboxed binary.

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
- **Format strings** (f-strings): **not yet implemented** — they hit the primary fallback and set `stmt_failed` (discard the containing body)

**Statement parser — leaf + control-flow, crash-safe by construction:**
- **Crash-safe foundation**: non-aborting `consume` (sets `stmt_failed` instead of `fatal`), **cursor save/restore** around each function body (find matching dedent up front, parse, snap cursor to end regardless, discard JSON on failure), and always-advance primaries (no hangs)
- **Ledger statements**: `pass`, `break`, `continue`, `return [expr]`
- **Locals**: `let`/`var` (name + type + value + `else:` / `else as name:` guard blocks)
- **Assignment / expression-stmt**: full assignment operators (`+=`, `*=`, etc.) with the `end_or_fail` guard
- **Control flow**: `if`/`else if`/`else` (block + inline branches), `while`, `for` (bindings + iterables), `defer` (block + inline), `unsafe` (block + inline), **inline** `for`/`while`/`match`/`if` (with `inline:true`)
- **Match** / **when** statements — dispatched to the respective parsers
- **Conservative-by-design**: bodies containing not-yet-handled forms (f-strings, `parallel`, `gather`, destructure locals, `emit`) are **safely discarded** to `[]` via `stmt_failed` — never introduces new wrong-node diffs

### Strategy for the remaining work

Status: **6/13 pass, accuracy=57, shape=15, 0 errors** (Commit `7f3e7ed0`).

| Feature | Est. diffs | Notes |
|---|---|---|
| ~~Extending/interface methods~~ | ~~21~~ | **DONE** — `parse_method_block` / `parse_one_method`. Dropped accuracy 107 → 87. |
| ~~Qualified / `ptr[…]` extending receiver + `public foreign`~~ | ~~2 crashes~~ | **DONE** — `parse_type(p)` for receiver type_name; `parse_foreign_function_with_visibility`. Dropped accuracy 87 → 80, shape 23 → 14. |
| ~~Struct body (fields, nested_types, events)~~ | ~~32~~ | **DONE** — `parse_fields_json` no longer bails out; multi-pass body emits nested type decls + events. `parse_struct_params` splits lifetime params from type params. Dropped accuracy 80 → 57. |
| F-strings in bodies | ~5 | `FormatString` from fstring token parts with embedded-expression re-parsing. Cause of several `.body[len]` discards. |
| Parallel / gather / destructure | ~5 | `ForStmt{threaded:true}`, `GatherStmt`, destructure `let (a, b) = …`. Also trigger `.body[len]` discards. |
| Attribute parsing (`@[…]` decorators) | ~6 | Populates declaration-level `attributes` arrays; struct-level `@[packed]`/`@[alignment(N)]` → `packed`/`alignment` fields. |
| Event payload details | ~2 | EventDecl payload types differ (content accuracy). |
| Positions (Milestone B) | — | Turn on `line`/`column`/`length` on every AST node. |

### New pitfalls from Stage 2

- **`inline` is a Milk Tea keyword** — cannot be used as a parameter name. Use `is_inline` instead.
- **`consume()` fatally aborts.** The body-parse path must use non-aborting `consume` (sets `stmt_failed` instead). The global `consume` wrapper in `parser.mt` was changed to be non-aborting for the body path.
- **Cursor save/restore is critical for crash-safety.** Before parsing any block body, find the matching dedent (the body end), record it, then parse. After parsing, snap `p.tokens.pos` to the recorded end regardless of success/failure. This bounds any desync to the body and guarantees the declaration parse is never corrupted.
- **Heuristic specialization classification measures net-negative.** The specialization decision (`IndexAccess` vs `Specialization`) was attempted twice with heuristics (capitalization + builtin-list); both times measured net-negative because partial-correctness backfires — a kept-but-imperfect body explodes into many leaf diffs. The accurate approach uses **known-name tracking** via a token pre-pass that collects generic-callable names, plus builtin-list + capitalization + **content-type check** (bracket content is a type → specialization regardless of receiver name). This combined approach is accurate and net-positive.
- **Block-consuming value expressions need special handling at statement-end.** When a `let`/`return` value is a block-form proc or match expression, the expression's block already consumed its trailing dedent — the cursor lands at the *next* statement, not at a newline. The `end_or_fail` guard would falsely flag this as a desync. The fix: `block_expr_done` flag set by block-form value expressions, checked+consumed by `end_or_fail`, so the statement-end logic skips the end-of-statement check when the block already ended it.
- **Member-name tracking for specialization.** Specialization can occur on qualified names (`module.Type[args]`), not just bare identifiers. The parser tracks the *last member name* in `recv_ident` (updated on `.member`, cleared on `[`/`(`/`?`) so that `member[Type]` is correctly classified.

### Code size (parser.mt)

~3370 lines (up from the original 1180-line skeleton), covering all declaration types, a full expression parser, a crash-safe statement parser, struct body parsing with nested types and events, extending/interface methods, and the known-name tracking infrastructure.

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

## Stage 4: Lowering — BLOCKED (oracle repair required first)

**Goal:** Consume Analysis JSON (from Ruby sema or Stage 3), produce IR JSON consumable by `ruby bin/mtc emit-c --from-ir-json`.

**Blocker (must fix first):** Ruby's own `lower --from-analysis-json` is *unfaithful* — it loses module/import context across the JSON boundary (e.g. emits `unknown identifier stdio`) and exits nonzero on some files, whereas `lower` from source succeeds. Until the reference `--from-analysis-json` path equals `lower` from source, a self-host lowering port has **no trustworthy oracle**. Repair this in Ruby (`cli.rb` `lower` + whatever rehydrates Analysis JSON) before starting the port.

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
