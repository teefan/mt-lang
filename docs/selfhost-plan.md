# Milk Tea Self-Hosting Plan

This document tracks the plan, context, and progress for making the Milk Tea compiler self-hosting (written in Milk Tea, compiled by itself).

**Status: Phase 0 — not yet started.**

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

## Pipeline Stages and JSON Contracts

### Stage boundary: Token JSON

```jsonc
// Array of tokens produced by the lexer
[
  {
    "type": "keyword_function",    // token type symbol
    "lexeme": "function",          // source text
    "literal": null,               // integer/float/string value, or null
    "line": 1,                     // 1-based line number
    "column": 1,                   // 1-based column number
    "start_offset": 0,             // byte offset in source
    "end_offset": 8                // byte offset past last char
  }
]
```

Special pseudo-tokens: `:indent`, `:dedent`, `:newline`, `:eof`.

### Stage boundary: AST JSON

```jsonc
{
  "kind": "SourceFile",
  "module_name": "main",
  "module_kind": "module",
  "imports": [
    { "kind": "Import", "path": ["std", "vec"], "alias": "vec" }
  ],
  "directives": [],
  "declarations": [
    {
      "kind": "FunctionDef",
      "name": "main",
      "params": [],
      "return_type": { "kind": "TypeRef", "name": "int" },
      "body": [ /* statements */ ]
    }
  ]
}
```

The AST JSON schema mirrors `AST::*` Data class shapes. Each node has a `kind` field.

### Stage boundary: Analysis JSON

```jsonc
{
  "module_name": "main",
  "module_kind": "module",
  "types": { "main.Foo": { /* resolved type info */ } },
  "functions": { "main.main": { /* resolved function binding */ } },
  "values": { "main.X": { /* resolved const/var */ } },
  "methods": {},
  "interfaces": {},
  "resolved_expr_types": { "<node_id>": "int" },
  "binding_resolution": { "<node_id>": { /* name → declaration binding */ } },
  "implemented_interfaces": {}
}
```

### Stage boundary: IR JSON

```jsonc
{
  "kind": "Program",
  "module_name": "main",
  "includes": [],
  "constants": [],
  "globals": [],
  "structs": [
    {
      "kind": "StructDecl",
      "name": "Foo",
      "linkage_name": "main_Foo",
      "fields": [
        { "kind": "Field", "name": "x", "type": "float" }
      ]
    }
  ],
  "unions": [],
  "enums": [],
  "variants": [],
  "opaques": [],
  "static_asserts": [],
  "functions": [
    {
      "kind": "Function",
      "name": "main.main",
      "linkage_name": "main_main",
      "params": [],
      "return_type": "int",
      "body": { /* IR statements */ },
      "entry_point": true
    }
  ]
}
```

The IR JSON schema mirrors `IR::*` Data class shapes. Type references in IR are C-level type names (strings).

## Implementation Phases

### Phase 0: JSON Bridge (in Ruby)

Add JSON export and import at each pipeline stage boundary in the Ruby compiler. This is the foundation for all subsequent phases.

**Tasks:**

- [x] **0.1** Define JSON schemas for each stage boundary (Token, AST)
- [x] **0.2** Add JSON export to Token and AST pipeline stages
  - [x] `Lexer.lex_to_json` — Token JSON and files via `lib/milk_tea/core/serializer.rb`
  - [x] `Parser.parse_to_ast_json` — AST JSON via `lib/milk_tea/core/serializer.rb`
- [x] **0.3** Add JSON import to Token → Parser pipeline
  - [x] `Parser.parse_from_tokens_json` — reads Token JSON, parses to AST
  - [x] `Serializer.ast_from_json` / `Serializer.ast_from_json_with_ids` — deserializes AST JSON back to Ruby Data nodes
- [x] **0.4** Add CLI flags for JSON pipeline control
  - [x] `mtc lex --json` / `mtc lex --emit-tokens-json FILE` — Token JSON export
  - [x] `mtc parse --json` / `mtc parse --emit-ast-json FILE` — AST JSON export
  - [x] `mtc parse --from-tokens-json FILE` — read Token JSON → parse → text AST
  - [x] `mtc parse --from-tokens-json FILE --json` — read Token JSON → parse → AST JSON
- [x] **0.5** Implement roundtrip verification tests
  - [x] Ruby Lexer → Token JSON → Ruby Parser → compare AST to direct parse
  - [x] Ruby Parser → AST JSON → Ruby deserializer → compare to original AST
- [ ] **0.6** Define JSON schemas for Analysis and IR boundaries (deferred to future increments)
- [ ] **0.7** Add JSON export/import for Analysis and IR stages (deferred to future increments)

**Verification:** For every `.mt` test file (57 files tested), `Ruby Lexer → Token JSON → Ruby Parser → AST JSON → deserializer → PrettyPrinter` produces AST text identical to direct `PrettyPrinter` output. 54/57 files pass roundtrip; 3 failures are pre-existing PrettyPrinter bugs (ParallelBlockStmt, ValueTypeParam.constraints).

**Status:** Increment 1 (Token + AST JSON) complete. Increment 2 (IR JSON) and increment 3 (Analysis JSON) remain.

---

### Phase 1: Milk Tea Lexer

Write the lexer in Milk Tea. Consumes source text, produces Token JSON.

**Prerequisites:** Phase 0 complete.

**Tasks:**

- [ ] **1.1** Implement core lexer in Milk Tea: character-by-character scanning, keyword recognition, indentation tracking, token emission
- [ ] **1.2** Implement all literal forms: integers (decimal/hex/binary with suffixes), floats, strings, cstrings, format strings, heredocs, char literals
- [ ] **1.3** Implement error recovery mode (collect errors instead of aborting)
- [ ] **1.4** Implement trivia tracking (whitespace, comments) for IDE support
- [ ] **1.5** Test: `Milk Tea Lexer → Token JSON` matches `Ruby Lexer → Token JSON` for all test fixtures

**Verification:** Token JSON output is identical between Ruby and Milk Tea lexers for every `.mt` file in the test suite. Feed Milk Tea Token JSON into Ruby Parser → full pipeline → identical C.

**Status:** Not started.

---

### Phase 2: Milk Tea Parser

Write the parser in Milk Tea. Consumes Token JSON, produces AST JSON.

**Prerequisites:** Phase 1 (can consume Ruby Token JSON during development).

**Tasks:**

- [ ] **2.1** Implement token stream reader (consume Token JSON)
- [ ] **2.2** Implement type annotation parsing (TypeRef, function types, generic params)
- [ ] **2.3** Implement declaration parsing (struct, enum, union, flags, variant, function, const, var, type alias, interface, extending, attribute, external, foreign)
- [ ] **2.4** Implement expression parsing (precedence climbing, operators, calls, member access, indexing, literals)
- [ ] **2.5** Implement statement parsing (if, match, for, while, return, defer, unsafe, let, var, assignment, when, inline forms)
- [ ] **2.6** Implement block/indentation handling
- [ ] **2.7** Implement `seed_known_names` pre-scan for type/variable disambiguation
- [ ] **2.8** Implement error recovery and `ErrorExpr`/`ErrorStmt` node production
- [ ] **2.9** Test: `Milk Tea Parser → AST JSON` matches `Ruby Parser → AST JSON` for all test fixtures

**Verification:** AST JSON output is identical between Ruby and Milk Tea parsers. Feed Milk Tea AST JSON into Ruby Sema → full pipeline → identical C.

**Status:** Not started.

---

### Phase 3: Milk Tea C Backend

Write the C code generator in Milk Tea. Consumes IR JSON, produces C source.

**Prerequisites:** Phase 0 (can consume Ruby-produced IR JSON). Phase 2 desirable for self-compilation testing.

**Tasks:**

- [ ] **3.1** Implement IR JSON reader
- [ ] **3.2** Implement C type name emission (primitives, structs, pointers, arrays, function pointers)
- [ ] **3.3** Implement forward declaration emission (topological sort of aggregate types)
- [ ] **3.4** Implement aggregate type definition emission (structs, unions, enums, variants)
- [ ] **3.5** Implement constant and global variable emission
- [ ] **3.6** Implement expression emission (literals, names, member access, calls, casts, address-of, operators)
- [ ] **3.7** Implement statement emission (if, switch, while, for, goto/label, return, expressions, locals, assignments)
- [ ] **3.8** Implement runtime helper emission (fatal, format, span helpers, SoA, async, etc.)
- [ ] **3.9** Implement feature detection (only emit helpers that are actually used)
- [ ] **3.10** Implement `#include` and `#line` directive emission
- [ ] **3.11** Test: `Milk Tea CBackend → C source` matches `Ruby CBackend → C source` for all IR JSON fixtures

**Verification:** C source output is byte-identical between Ruby and Milk Tea C backends for the same IR JSON input. The generated C compiles with a C compiler and produces a working binary.

**Status:** Not started.

---

### Phase 4: Milk Tea Lowering

Write the lowering pass in Milk Tea. Consumes Analysis JSON, produces IR JSON.

**Prerequisites:** Phase 3 (or use Ruby C backend for testing).

**Tasks:**

- [ ] **4.1** Implement Analysis JSON reader
- [ ] **4.2** Implement type declaration lowering (struct → IR StructDecl, enum → IR EnumDecl, etc.)
- [ ] **4.3** Implement constant and global value lowering
- [ ] **4.4** Implement expression lowering (AST expressions → IR expressions)
- [ ] **4.5** Implement statement lowering (AST statements → IR statements)
- [ ] **4.6** Implement function/method call lowering (dispatch resolution, method → namespaced function)
- [ ] **4.7** Implement control flow lowering (if → IR if, match → IR switch, for → IR for/while, defer)
- [ ] **4.8** Implement proc/closure lowering (capture analysis, environment structs)
- [ ] **4.9** Implement async lowering (task state machines, await normalization)
- [ ] **4.10** Implement event lowering (publisher/subscriber runtime)
- [ ] **4.11** Implement string/format lowering (format string → runtime calls, String → IR helpers)
- [ ] **4.12** Implement dyn/interface lowering (vtable generation)
- [ ] **4.13** Test: `Milk Tea Lowering → IR JSON` matches `Ruby Lowering → IR JSON` for all Analysis JSON fixtures

**Verification:** IR JSON output is identical between Ruby and Milk Tea lowering. Feed Milk Tea IR JSON into Ruby CBackend → identical C. Feed Milk Tea IR JSON into Milk Tea CBackend → identical C.

**Status:** Not started.

---

### Phase 5: Milk Tea Semantic Analyzer

Write the semantic analyzer in Milk Tea. Consumes AST JSON, produces Analysis JSON.

**Prerequisites:** Phases 0–4.

**Tasks:**

- [ ] **5.1** Implement AST JSON reader
- [ ] **5.2** Implement builtin type and attribute installation
- [ ] **5.3** Implement import resolution (consume imported module Analysis JSON)
- [ ] **5.4** Implement named type declaration and resolution (structs, enums, unions, variants, interfaces)
- [ ] **5.5** Implement type alias resolution
- [ ] **5.6** Implement aggregate field resolution (struct/union fields, enum members, variant arms)
- [ ] **5.7** Implement type compatibility checking (equivalence, subtyping)
- [ ] **5.8** Implement function/method signature binding
- [ ] **5.9** Implement expression type-checking (operators, calls, member access, indexing, casts)
- [ ] **5.10** Implement statement type-checking (if, match, for, while, return, assignments, locals)
- [ ] **5.11** Implement name resolution and binding (identifiers → declarations)
- [ ] **5.12** Implement flow-sensitive type refinement
- [ ] **5.13** Implement nullability checking
- [ ] **5.14** Implement interface conformance verification
- [ ] **5.15** Implement attribute application validation
- [ ] **5.16** Implement generic type parameter constraint checking and monomorphization
- [ ] **5.17** Implement foreign function ABI validation
- [ ] **5.18** Implement const evaluation (compile-time expressions, `const function` bodies)
- [ ] **5.19** Test: `Milk Tea Sema → Analysis JSON` matches `Ruby Sema → Analysis JSON` for all AST JSON fixtures

**Verification:** Analysis JSON output is identical between Ruby and Milk Tea semantic analyzers. Feed Milk Tea Analysis JSON into Milk Tea Lowering → Milk Tea CBackend → C compiles and binary is bit-identical to Ruby full pipeline output.

**Status:** Not started.

---

### Phase 6: Full Self-Hosting

The Milk Tea compiler compiles itself end-to-end.

**Prerequisites:** Phases 0–5 complete.

**Tasks:**

- [ ] **6.1** Assemble the Milk Tea compiler as a Milk Tea program importing all stages
- [ ] **6.2** Compile with the Ruby compiler → C source for the Milk Tea compiler
- [ ] **6.3** Commit generated C as `bootstrap/` (like Vala/Zig seed approach)
- [ ] **6.4** `make bootstrap` compiles bootstrap C with system C compiler → `mtc-stage1`
- [ ] **6.5** `mtc-stage1` compiles the Milk Tea compiler source → new binary
- [ ] **6.6** Self-compile verification (new binary compiles itself → bit-identical binary)
- [ ] **6.7** Run full test suite with self-hosted compiler
- [ ] **6.8** Optionally freeze/remove Ruby compiler

**Verification:** Stage N binary compiles Milk Tea compiler source → Stage N+1 binary. Stage N+1 compiles Milk Tea compiler source → Stage N+2. Stage N+1 and Stage N+2 are byte-identical. Full test suite passes.

**Status:** Not started.

---

## Design Decisions

### Why JSON (not binary, not s-expressions)?

- **Diffable.** You can `diff` JSON output between Ruby and Milk Tea implementations to find discrepancies. Binary formats hide differences.
- **Human-readable.** Easy to inspect during development and debugging.
- **No parser needed in Milk Tea.** `std.json` already exists in the standard library.
- **Schema can evolve with the compiler.** Add fields without breaking old consumers (ignore unknown keys).
- **Performance is not critical for a bridge format.** JSON parse/generate overhead is negligible compared to compilation time. The JSON bridge is for development, verification, and bootstrapping — production self-hosted builds can use in-memory data structures directly.

### Why not skip the JSON bridge and just port directly?

Crystal tried that. They hit "dual-maintenance hell" — every bugfix in the Ruby compiler had to be manually ported to the Crystal compiler. The JSON bridge avoids this by making verification mechanical: `diff` the JSON output. If the JSONs match, the port is correct.

### Why build front-to-back (Lexer → Parser → C Backend → Lowering → Sema)?

- **Lexer and Parser are self-contained.** They don't need the type system, import resolution, or any other compiler infrastructure. Lowest risk to start with.
- **C Backend is surprisingly independent.** It just walks IR JSON and prints C strings. Building it third means we can compile Milk Tea programs (simple ones) to C early.
- **Lowering depends on Analysis.** But Analysis JSON is well-defined by Phase 0.
- **Semantic Analyzer is the hardest.** It depends on everything: type system, generics, interfaces, name resolution, const evaluation, flow analysis. Building it last means all the supporting infrastructure (lexer, parser, C backend, lowering, JSON I/O, standard library) is already working in Milk Tea.

### Why commit generated C as bootstrap (Vala/Zig approach)?

- **O(1) bootstrap forever.** Only need a C compiler. No 50-step chain of historical compiler versions (Kotlin's mistake).
- **The generated C is already the compiler's output format.** This is natural, not an extra artifact.
- **The C is readable and debuggable.** Matches the language's design goal.

### Why not use a mechanical Ruby→Milk Tea translator (Go/Nim approach)?

Ruby and Milk Tea have fundamentally different type systems, memory models, and execution models. A translator would be more work than a rewrite and would produce unidiomatic, unmaintainable code. The Go approach worked because Go's C codebase was already written in a restrained, Go-like style. Ruby is too dynamic for this.

## Testing Strategy

### Per-phase verification

| Phase | Test |
|-------|------|
| 0 | Ruby pipeline → JSON → Ruby pipeline → identical C (roundtrip) |
| 1 | Milk Tea Lexer → Token JSON == Ruby Lexer → Token JSON |
| 2 | Milk Tea Parser → AST JSON == Ruby Parser → AST JSON |
| 3 | Milk Tea CBackend(IR JSON) → C == Ruby CBackend(IR JSON) → C |
| 4 | Milk Tea Lowering(Analysis JSON) → IR JSON == Ruby Lowering(Analysis JSON) → IR JSON |
| 5 | Milk Tea Sema(AST JSON) → Analysis JSON == Ruby Sema(AST JSON) → Analysis JSON |
| 6 | Self-compile → bit-identical binary; full test suite passes |

### Cross-stage verification (always available)

For any phase N, feed Milk Tea Stage N output JSON into Ruby Stage N+1 and verify the final C is identical:

```
Milk Tea Stage N → JSON → Ruby Stage N+1 → ... → Ruby CBackend → C
                                                        ==
                    Ruby Stage N → ... → Ruby Stage N+1 → ... → Ruby CBackend → C
```

### Regression testing

Once a stage is complete and verified, its JSON output becomes part of the test suite. Any change to the Ruby compiler that changes JSON output must be reflected in the Milk Tea implementation (or vice versa).

## Progress Tracking

| Phase | Status | Started | Completed | Notes |
|-------|--------|---------|-----------|-------|
| 0: JSON Bridge | In progress | 2026-06-25 | — | Increment 1 (Token + AST JSON) complete |
| 1: Lexer | Not started | — | — | |
| 2: Parser | Not started | — | — | |
| 3: C Backend | Not started | — | — | Early self-hosting capability |
| 4: Lowering | Not started | — | — | |
| 5: Semantic Analyzer | Not started | — | — | Hardest phase |
| 6: Full Self-Hosting | Not started | — | — | |

## Risks and Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| JSON schemas become out of sync with Ruby data structures | Medium | Roundtrip tests in Phase 0 catch drift immediately. Schema changes must be made to both sides together. |
| Analysis JSON is too large/complex for practical diffing | Medium | Start with a minimal subset (types + functions + resolved_expr_types). Add fields incrementally. Use sorted keys for deterministic output. |
| Milk Tea standard library lacks features needed for compiler implementation | High | The stdlib already has Vec, String, Option, Result, arena, heap, Map, Set, etc. But compiler-specific needs (e.g. hash consing, persistent maps) may require additions. Add them to stdlib as needed — they benefit all Milk Tea programs. |
| Phase 5 (Sema) takes too long, blocking self-hosting | Medium | Can use Ruby sema indefinitely. A mixed pipeline (Milk Tea lexer + parser + Ruby sema + Milk Tea lowering + C backend) is a valid intermediate state. Self-hosting doesn't require every stage to be Milk Tea at once. |
| JSON bridge performance makes development iteration slow | Low | JSON I/O overhead is negligible vs. compilation time. For large programs, consider streaming JSON (line-delimited JSON or NDJSON). |
| The plan is wrong in ways we can't foresee | Medium | This document is a living plan. Each phase includes a retrospective at completion. Revise the plan based on what we learn. |

## Revision History

| Date | Revision | Notes |
|------|----------|-------|
| 2026-06-25 | Initial draft | Based on compiler architecture review, language manual, and self-hosting research from Rust/Zig/Go/Crystal/Nim/Vala/C#/TypeScript/Kotlin |
| 2026-06-25 | Phase 0 Increment 1 complete | Implemented Token JSON + AST JSON bridge: `lib/milk_tea/core/serializer.rb`, CLI flags (`--json`, `--emit-tokens-json`, `--emit-ast-json`, `--from-tokens-json`). 54/57 files roundtrip perfectly; 3 pre-existing PrettyPrinter failures unrelated to serializer. All 1228 compiler tests and 113 CLI tests pass. |
