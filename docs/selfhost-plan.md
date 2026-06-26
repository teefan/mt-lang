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
│  DONE ✓  │               │  DONE ✓  │              │     NEXT          │
└──────────┘               └──────────┘              └───────────────────┘
                                                              │
                                                        Analysis JSON
                                                              │
                                                              ▼
┌───────────┐   C source    ┌──────────┐    IR JSON   ┌──────────┐
│ C Backend │ ←──────────── │ Lowering │ ←─────────── │ (Stage 3 │
│ (Stage 5) │               │ (Stage 4)│              │  output) │
│  DONE ✓   │               │  NEXT    │              │          │
└───────────┘               └──────────┘              └──────────┘
```

### Key design rules

1. **Each stage is independently developable and testable.** Stage N only needs to understand its input JSON and produce correct output JSON. It does not need the other stages to exist in Milk Tea.

2. **The JSON contracts are the single source of truth.** The schemas are derived from the Ruby compiler's existing data structures. If a schema needs to change, both sides update together.

3. **The Ruby compiler is the safety net throughout.** At every phase, any missing or broken Milk Tea stage can be substituted with the Ruby version. There is never a point where the compiler stops working.

4. **Stages are built front-to-back, with the C backend pulled forward.** Lexer → Parser → C Backend → Lowering → Semantic Analyzer. The C backend is simple (walk IR tree, print C) and unlocks self-hosting capability early.

5. **Bootstrap is always O(1).** A system C compiler + committed bootstrap C files is the only requirement to build the compiler from scratch. No chain of historical compiler versions.

## Stage 1: Lexer — DONE

**Location:** `projects/mtc/src/lexer/`

**Verification:** Lex all 13 `examples/*.mt` files → pipe token JSON into `ruby bin/mtc parse --from-tokens-json` → all parse OK (25,181 total tokens).

**Features implemented:**
- All literal types: integers (dec/hex/bin with `_` and type suffixes), floats (scientific, f/d suffix), strings, cstrings, char literals (with `\xNN`), heredocs (`<<-`, `c<<-`, `f<<-`), format strings with interpolation and format specs
- Indentation-based blocks (INDENT/DEDENT), line continuation after operators, grouping depth suppression
- All operators (1-char, 2-char, 3-char), all 54 keywords
- Adjacent string concatenation, comments (`#`), doc comments (`##`)
- Token JSON output with `type`, `lexeme`, `literal`, `line`, `column`, `start_offset`, `end_offset`

**Code size:** ~1070 lines in `lexer.mt` + 66 lines `keywords.mt`.

**Tests:** 20 regression tests in `src/test/lexer_test.mt`, run via `mtc test`.

**CLI:** `mtc lex <file>` — outputs token JSON to stdout.

## Stage 2: Parser — DONE

**Location:** `projects/mtc/src/parser/`

**Verification:** Parse all 13 `examples/*.mt` → all produce valid AST JSON. 158 declarations from `language_baseline.mt` with 66 FunctionDefs recording correct param counts.

**Architecture:**
- `token_stream.mt` (80 lines): peek/advance/check/match/consume cursor over `Vec[lexer.Token]`
- `ast_json.mt` (140 lines): AST JSON emitters with `$mt_type` and `$sym` encoding matching Ruby format
- `parser.mt` (1180 lines): recursive-descent parser, all 18 declaration types, depth-tracked bracket/paren skipping

**Declaration types:** const, var, type alias, function, async function, const function, external function, foreign function, struct (with implements), enum (with backing type), flags, union, variant, opaque (with implements), interface, extending, attribute, static_assert, event, when, public (all forms)

**Statement types (skipped, not parsed in detail):** if/else if/else, while, for, match, let, var, return, break, continue, pass, defer, unsafe, when, inline, parallel, detach, gather, emit, assignment, expression statements

**Code size:** ~1180 lines parser.mt + 140 lines ast_json.mt + 80 lines token_stream.mt

**Tests:** 49 tests (20 lexer + 29 parser). Run via `mtc test`.

**CLI:** `mtc lex <file>` + `mtc parse <file>` + `mtc test`

**Key fixes post-audit:**
- `last_kind` tracking: uses `output_tokens.last().kind` for accurate line continuation after operators
- `ForeignFunctionDecl.mapping`: captures actual mapping name instead of function name
- `skip_expression`: no longer double-advances after `(`/`[`
- `lex_to_json`: releases `output_tokens` Vec (was leaked)
- Comma tracking: dangling boolean with buffer-length emission check
- Bracket advance: `parse_params_ast` breaks early inside lbracket loop when bd hits 0

**Known limitations (intentionally scoped out):**
- Statement bodies are skipped via `skip_statement`, not parsed into detailed AST nodes
- Expression trees not built (expressions skipped token-by-token)
- Type annotations recorded as null, field details not populated
- `@[test]` attribute content consumed but not recorded in AST

## Stage 5: C Backend — DONE

**Location:** `projects/mtc/src/c_backend/`

**Architecture:**
- `ir_reader.mt` (220 lines): `IrCursor` — lazy, zero-allocation JSON field reader using borrowed `str` slices
- `c_backend.mt` (756 lines): recursive C emitter from IR JSON

**Verification:** Self-host `emit-c` produces C source from IR JSON. Verified with `cc -std=c11` → compiles and runs correctly for structs, enums, constants, globals, if/while/for, aggregate literals, function calls.

**IR → C pipeline:**
1. `emit_c(ir_json)` → walks `IR::Program`
2. Top-level: `emit_includes`, `emit_constants`, `emit_globals`, `emit_opaques`, `emit_enums`, `emit_structs`, `emit_functions`
3. Functions: forward declarations + definitions with typed params
4. Bodies: `emit_body` → statement dispatch (14 types)
5. Expressions: `emit_expression` → dispatches 24 types to C text
6. Types: `type_to_c` → `$type_ref` dispatch to `c_struct_type` (Struct/Union) or `c_type_str` (Primitive)

**Code size:** 756 lines c_backend.mt + 220 lines ir_reader.mt

**Cli:** `mtc emit-c <ir_json_file>` — outputs C source to stdout.

**Known limitations:**
- `struct _int` edge case in `type_to_c` param-type path (primitives occasionally hit `c_struct_type`)
- No runtime helpers (mt_fatal, mt_str, format, async) — standalone simple programs only
- No dead code elimination, no topological type sorting
- Duplicate includes in some edge cases

## Stage 4: Lowering — NEXT

**Goal:** Consume Analysis JSON (from Ruby sema or Stage 3), produce IR JSON consumable by `ruby bin/mtc emit-c --from-ir-json`.

**Steps:**
1. Parse Analysis JSON into internal representation
2. Lower types: structs, enums, unions, variants, opaques → IR type declarations
3. Lower constants, globals → IR values
4. Lower functions: parse AST bodies → IR statement/expression trees
5. Produce IR JSON matching `Serializer.ir_to_json`

**Verification:** Produce IR JSON → feed into `ruby bin/mtc emit-c --from-ir-json` → confirm C output matches Ruby's.

**Prerequisites:**
- Read `lib/milk_tea/core/lowering.rb` for the lowering architecture
- Read `lib/milk_tea/core/serializer.rb` `ir_to_json` for the exact IR JSON contract
- The `lower` command has `--from-analysis-json` flag (line 810 of cli.rb)

### Pitfalls from Stage 1 + 2

- **`Build.build` always uses `package.toml` entry point.** Tests live in `src/test/` and a custom `test` subcommand runs them manually. Don't rely on `mtc test` for in-project test discovery.
- **Test functions must be `public`** to be callable from the test runner.
- **`str` methods from `std.str`** require `import std.str`.
- **String lifetimes:** return `String`, not `str`, from functions that build local buffers.
- **Use heredocs for multi-line test source code.**
- **`defer` takes a single expression** (no colon) for single-statement cleanup.
- **`match` is a reserved word** — use as expression only, not function name.
- **`out` is a keyword** — don't use as variable name.
- **`ptr[void]<-expr` casts require `unsafe` blocks.**
- **Sandbox every self-host binary invocation** with `timeout` + `ulimit -v`.
- **Sandbox Ruby compiler invocations too** in automated test loops. `check --json` on large files with stdlib imports can consume 4GB+ and hang for minutes due to cross-module linter analysis. Use `check` (text mode) for verification; avoid `--json` on `language_baseline.mt`.
- **Inline JSON building needs careful comma tracking** — dangling comma flag pattern with buffer-length checks.
- **Bracket-depth tracking** must increment AFTER consuming `[`/`(`, and decrement AND advance past `]`/`)` in the same conditional block to avoid extra advances.
- **String lifetimes in C backend:** `c_type(str)` returning `str` creates dangling references — always return `String` and release at call site. Major source of "string.as_str text must be valid UTF-8" crashes.
- **JSON field reading with `$`:** `$mt_type` and `$type_ref` are valid field names in IR JSON. `parse_json_string_slice` handles `$` correctly as a regular byte.
- **Array element iteration:** use `split_array_elements` with depth tracking instead of naive `{` matching — nested objects in function bodies produce ghost elements.
- **Function params use `(void)` for empty lists** — track `first_param` flag.
- **Entry point functions:** no `static` prefix, no extra wrapper generation (the IR already has the wrapper function).
- **IR type objects may have null `linkage_name`** — generate from `module_name + "_" + name` in `c_struct_type`.
