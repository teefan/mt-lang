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
│  DONE ✓  │               │          │              │                   │
└──────────┘               └──────────┘              └───────────────────┘
                                                              │
                                                        Analysis JSON
                                                              │
                                                              ▼
┌───────────┐   C source    ┌──────────┐    IR JSON   ┌──────────┐
│ C Backend │ ←──────────── │ Lowering │ ←─────────── │ (Stage 3 │
│ (Stage 5) │               │ (Stage 4)│              │  output) │
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

## Stage 2: Parser — NEXT

**Goal:** Consume token JSON (from Stage 1 or Ruby lexer), produce AST JSON consumable by the Ruby semantic analyzer (`check --from-ast-json`).

**Steps:**
1. Token stream wrapper (peek, advance, check) out of the token JSON array
2. Parse source file → imports, directives, declarations
3. Parse declarations: function, struct, enum, variant, const, var, type alias, etc.
4. Parse statements: if, match, for, while, let/var, assignment, defer, unsafe, etc.
5. Parse expressions with correct precedence (14 levels)
6. Parse types (primitives, generics, function types, nullable, tuples, etc.)
7. AST JSON output matching `Serializer.ast_to_json`

**Verification:** Parse token JSON → produce AST JSON → feed into `ruby bin/mtc check --from-ast-json` → confirm Analysis JSON matches.

### Context for resuming

- The token JSON format is documented in the Ruby `Serializer.tokens_to_json` / `token_to_hash` methods in `lib/milk_tea/core/serializer.rb`.
- The AST node types are defined in `lib/milk_tea/core/ast.rb`. The AST JSON format is produced by `Serializer.ast_to_json`.
- The Ruby parser is split across `lib/milk_tea/core/parser/` — `declarations.rb`, `expressions.rb`, `statements.rb`, `type_parsing.rb`, `attributes.rb`, `blocks.rb`, `recovery.rb`.
- The CLI `parse --from-tokens-json <file>` feeds into `Parser.parse_from_tokens_json`.
- The same `--json` flag on Ruby `mtc parse` outputs AST JSON.
- The self-host lexer JSON was verified round-trip with `mtc parse --from-tokens-json`.
- The AST JSON → check round-trip should work with `mtc check --from-ast-json` (check the CLI for exact flag name).

## Prerequisite reading (for any stage)

To avoid cold-start exploration, load these files in order before implementing:

### 1. Language surface (20 min)
| File | Why |
|---|---|
| `docs/language-manual.md` | §§3–6: every declaration, statement, expression, and type form the parser must handle. Skim §2 (lexical) and §7 (builtins) as reference. |
| `examples/language_baseline.mt` | 1354-line stress test exercising the complete language. The Stage 2 target: must parse this to AST JSON. |

### 2. JSON contracts (15 min)
| File | What to look for |
|---|---|
| `lib/milk_tea/core/serializer.rb` | `token_to_hash` / `tokens_from_json` (input format for parser). `ast_to_json` / `ast_from_json` (output format the parser must produce). `serialize_literal` / `deserialize_literal` (how literal values round-trip through JSON). |
| `lib/milk_tea/core/ast.rb` | All `AST::*` Data classes — these map 1:1 to the JSON contract. Every node the parser emits has a class here. |
| `lib/milk_tea/core/token.rb` | Token structure: `type` (Symbol), `lexeme`, `literal`, `line`, `column`. Parser reads these fields. |

### 3. Ruby parser structure (30 min)
| File | Focus |
|---|---|
| `lib/milk_tea/core/parser.rb` | Class structure, `parse` entry point, `parse_collecting_errors` for recovery mode. The `Parser` mixes in the modules below. |
| `lib/milk_tea/core/token_stream.rb` | `SyntaxTokenStream` — thin wrapper. Methods: `peek`, `advance`, `check`, `match`, `previous`. The parser's only interface to tokens. Read this first — all parsing helpers depend on it. |
| `lib/milk_tea/core/parser/blocks.rb` | How the Ruby parser handles indentation: `parse_block` expects INDENT/DEDENT framing around block bodies. Critical for statement parsing. |
| `lib/milk_tea/core/parser/expressions.rb` | 14-level precedence climbing (`parse_or` → `parse_and` → ... → `parse_primary`). Every expression form lives here: literals, calls, member access, indexing, `if`-expr, `match`-expr, `proc`, etc. |
| `lib/milk_tea/core/parser/declarations.rb` | Top-level: `function`, `struct`, `enum`, `variant`, `const`, `var`, `type`, `interface`, `extending`, `event`, etc. |
| `lib/milk_tea/core/parser/statements.rb` | All statement forms: `let`/`var` decls, `if`/`match`/`while`/`for`, `return`, `break`, `continue`, `defer`, `unsafe`, assignment, expression statements, etc. |
| `lib/milk_tea/core/parser/type_parsing.rb` | Type parsing: primitives, generics (`Foo[T]`), function types (`fn(...) -> R`), nullable (`T?`), tuples, `dyn[...]`, `ref[...]`. |
| `lib/milk_tea/core/parser/attributes.rb` | `@[name(args)]` attribute parsing. |

### 4. Self-host project conventions (10 min)
| File | What to note |
|---|---|
| `projects/mtc/src/main.mt` | CLI structure. The `lex` subcommand pattern: read args from `main(args: span[str])`, dispatch, call stage function. Extend with `parse` subcommand. |
| `projects/mtc/src/lexer/lexer.mt` | The output format the parser consumes. Note: `emit_tok` builds token JSON inline — the parser will consume this. |
| `projects/mtc/src/test/lexer_test.mt` | Test pattern: heredoc for test source, `std.testing` assertions, `public` functions registered in `all_tests.mt`. |
| `projects/mtc/src/test/all_tests.mt` | Manual test registration. Add parser test entries here. |

### 5. Key stdlib modules (skim, 10 min)
| Module | What the parser will use |
|---|---|
| `std/vec.mt` | `Vec[T]` for dynamic arrays (token stream buffer, child node lists). Methods: `push`, `pop`, `get`, `len`, `at`, `release`. |
| `std/string.mt` | `String` for building JSON output. Methods: `create`, `append`, `push_byte`, `as_str`, `release`. |
| `std/str.mt` | `str` methods available when imported: `byte_at`, `slice`, `starts_with`, `ends_with`, `find_substring`, `trim_ascii_whitespace`, `equal`, `compare`. |
| `std/fmt.mt` | `append_int`, `append_ptr_uint`, `append_bool` — formatting values into JSON. |
| `std/map.mt` | `Map[K, V]` for operator precedence tables, keyword-to-AST-node dispatch. |

### Pitfalls from Stage 1

- **`Build.build` always uses `package.toml` entry point.** Tests live in `src/test/` and a custom `test` subcommand runs them manually. Don't rely on `mtc test` for in-project test discovery.
- **Test functions must be `public`** to be callable from the test runner.
- **`str` methods from `std.str`** (`.contains_substring`, `.starts_with`, `.trim_ascii_whitespace`, etc.) require `import std.str`.
- **String lifetimes:** functions that build a local `String` and return `str` create dangling references. Always return `String` and release at the call site.
- **Use heredocs (`<<-TAG`)** for multi-line test source code — avoids `\n` and `\"` escaping issues.
- **`ptr[void]<-expr` casts require `unsafe` blocks.**
- **`defer` takes a single expression** (no colon) for single-statement cleanup.
- **Sandbox every self-host binary invocation** with `timeout` + `ulimit -v`.
