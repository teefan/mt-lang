# Milk Tea Self-Hosting Plan

## Goal

`projects/mtc/` — a Milk Tea compiler written entirely in Milk Tea, capable
of compiling itself.  The Ruby compiler (`lib/milk_tea/core/`) remains the
bootstrap host and the reference implementation.

## Bootstrap strategy

```
Ruby mtc  ─── build ──→  mtc (v0)            # Ruby host
   │                         │
   │                         └── build ──→  mtc (v1)    # self-compiled
   │                                              │
   │                                              └── build ──→  mtc (v2)    # self-compiled, identical to v1
   │
   └── verify:  diff <(ruby mtc emit-c) <(mtc-vN emit-c)
```

Each phase's output becomes the host for the next phase.  The contract is
**identical emitted C** — the Ruby compiler and the Milk Tea compiler must
produce the same C for the same input.  This gives us a deterministic,
diff-verifiable bootstrap.

## Component map

Each Ruby compiler file maps to a Milk Tea module in `projects/mtc/src/mtc/`.

### Phase 1 — Lexer (foundation)

| Mt module | Ruby source | Purpose | Tok |
|---|---|---|---|
| `token.mt` | `token.rb` | `TokenKind` variant, `Token` struct | — |
| `token_stream.mt` | `token_stream.rb` | `TokenStream` with peek/advance/expect | token |
| `lexer.mt` | `lexer.rb` | `Lexer` struct: source → `Vec[Token]` | token, str |
| `source.mt` | — | `SourceView` (path + text), `Span` helpers | str |

**Milestone:** lexer tokenizes its own source (`check` passes, no crashes).

### Phase 2 — AST and parser

| Mt module | Ruby source | Purpose | Deps |
|---|---|---|---|
| `ast.mt` | `ast.rb` | ~40 AST node variants (declarations, expressions, statements) | token |
| `cst.mt` | `cst.rb` | Concrete syntax tree — raw parse tree | token |
| `cst_builder.mt` | `cst_builder.rb` | CST → AST builder | cst, ast |
| `parser.mt` | `parser.rb` | Recursive-descent parser | token_stream, ast, cst |
| `diagnostics.mt` | — | `Diagnostic` struct + `DiagnosticList` (Vec) | token |

**Milestone:** parser produces AST for the full language surface.

### Phase 3 — Types and semantic analysis

| Mt module | Ruby source | Purpose | Deps |
|---|---|---|---|
| `types.mt` | `types/types.rb` + `types/predicates.rb` | Type hierarchy (`Primitive`, `Struct`, `Variant`, `GenericVariantDefinition`, etc.) | — |
| `scope.mt` | — | `Scope` stack: `Map[str, Entity]` with parent chain | map, vec |
| `resolver.mt` | `sema/resolve.rb` | Name/type resolution, method dispatch | ast, types, scope |
| `sema/expr.mt` | `sema/expression_checker.rb` | Expression type inference | ast, types, scope, resolver |
| `sema/stmt.mt` | `sema/statement_checker.rb` | Statement checking (guards, match, `?`) | ast, types, scope |
| `sema/decl.mt` | `sema/type_declaration.rb` | Type declaration checking | ast, types |
| `sema/bindings.mt` | `sema/function_binding.rb` | Function/method binding, specialization | ast, types, resolver |
| `sema.mt` | `sema.rb` | Sema pipeline orchestrator + `Checker` | all sema/* |

**Milestone:** type-checker validates the full language surface without
lowering.

### Phase 4 — IR and lowering

| Mt module | Ruby source | Purpose | Deps |
|---|---|---|---|
| `ir.mt` | `ir.rb` | IR node definitions (~50 nodes) | types |
| `lowering/expr.mt` | `lowering/expressions.rb` | AST expression → IR expression | ast, ir |
| `lowering/stmt.mt` | `lowering/statements.rb` | AST statement → IR statement | ast, ir |
| `lowering/block.mt` | `lowering/block.rb` | Block lowering (let-else, defer, proc) | ast, ir |
| `lowering/decl.mt` | `lowering/declarations.rb` | Declaration lowering | ast, ir |
| `lowering/resolve.mt` | `lowering/resolve.rb` | Lowering-level type resolution | ir, types |
| `lowering/utils.mt` | `lowering/utils.rb` | Lowering utilities | ir, ast |
| `lowering.mt` | `lowering.rb` | Lowering pipeline orchestrator | all lowering/* |

**Milestone:** lowering produces correct IR for the full language surface.

### Phase 5 — C emission

| Mt module | Ruby source | Purpose | Deps |
|---|---|---|---|
| `emit/types.mt` | `c_backend/types.rb` | IR type → C declaration | ir, types |
| `emit/expr.mt` | `c_backend/expressions.rb` | IR expression → C expression | ir |
| `emit/stmt.mt` | `c_backend/statements.rb` | IR statement → C statement | ir |
| `emit/helpers.mt` | `c_backend/helpers.rb` | C helper functions | ir |
| `emit/aggregates.mt` | `c_backend/aggregate_utils.rb` | Struct/union/variant emission | ir |
| `emit.mt` | `c_backend.rb` | C emission orchestrator | all emit/* |

**Milestone:** emitted C compiles with `cc` and produces identical output to
the Ruby compiler.

### Phase 6 — Module system and CLI

| Mt module | Ruby source | Purpose | Deps |
|---|---|---|---|
| `module_loader.mt` | `module_loader.rb` + `module_path_resolver.rb` | Import graph, cycle detection, prelude | fs, path |
| `module_binder.mt` | `module_binder.rb` | Module binding (public types, methods) | ast |
| `module_roots.mt` | `module_roots.rb` | Module root resolution | fs, path |
| `compiler.mt` | — | Full pipeline: parse → check → lower → emit → compile | all above |
| `main.mt` | `tooling/cli.rb` (subset) | CLI entry: `check`, `build`, `run`, `emit-c` | compiler, cli |

**Milestone:** `mtc build projects/mtc` compiles itself, producing identical
C to the Ruby compiler.

## File dependencies (directed)

```
token
 ├─ token_stream
 │    └─ lexer
 │         └─ parser
 │              └─ cst_builder
 │                   └─ sema
 │                        └─ lowering
 │                             └─ emit
 │                                  └─ compiler
 │                                       └─ main
 ├─ ast
 │    ├─ parser
 │    ├─ cst_builder
 │    ├─ sema
 │    └─ lowering
 ├─ types
 │    ├─ sema
 │    ├─ ir
 │    └─ emit
 ├─ scope
 │    └─ sema
 ├─ ir
 │    ├─ lowering
 │    └─ emit
 ├─ diagnostics
 │    └─ all above
 └─ source
      ├─ lexer
      └─ compiler
```

## Progress

| Phase | Component | Status |
|-------|-----------|--------|
| 1 | `token.mt` | ✓ `TokenKind` variant (124 arms), `Token` struct with lexeme/start_offset |
| 1 | `lexer.mt` | ✓ Line-by-line indentation-based lexer; full keyword/operator/string/number/char |
| 1 | `source.mt` | ✓ `SourceView` (path+text), `Span` helpers |
| 1 | `token_stream.mt` | ✓ `SyntaxTokenStream` with len/get/at |
| 2 | `ast.mt` | ✓ 3 variants (Expr/Decl/Stmt, ~40 arms) + 20 helper structs, arena-based NodeId design |
| 2 | `diagnostics.mt` | ✓ Diagnostic + DiagnosticList with Severity enum |
| 2 | `parser.mt` | ✓ Full expression parser (precedence), statements, 15/17 declaration parsers, import, top-level |
| 2 | `cst.mt` | deferred (not needed — parser produces AST directly) |
| 2 | `cst_builder.mt` | deferred (not needed — parser produces AST directly) |
| 3 | `types.mt` | ✓ 37-arm Type variant + TypeArena + predicates + reserved-name checking |
| 3 | `scope.mt` | ✓ `Scope` with `Map[str, ValueBinding]`, `ScopeStack` for nested lookup |
| 3 | `sema/context.mt` | ✓ `ModuleContext` with types, functions, values, imports, diagnostics storage |
| 3 | `sema/resolver.mt` | ✓ Type/name resolution from AST NodeId expressions, generic instantiation |
| 3 | `sema.mt` | ✓ 8 structural phases + body checking (Phase 20: expression inference + statement walk) |
| 6 | `main.mt` | ✓ Wired: lex → parse → sema-check. `mtc build projects/mtc` produces a working binary that runs the pipeline. |
| 3 | `sema/expr.mt` | ✗ (consolidated into sema.mt — cross-module extending creates import cycles) |
| 3 | `sema/stmt.mt` | ✗ (consolidated into sema.mt — same reason) |
| 3 | `sema/decl.mt` | ✗ (consolidated into sema.mt structural phases) |
| 3 | `sema/bindings.mt` | ✗ (consolidated into sema.mt structural phases) |
| 4 | `ir.mt` | ✗ |
| 4 | `lowering/*` | ✗ |
| 5 | `emit/*` | ✗ |
| 6 | `module_loader.mt` | ✗ |
| 6 | `compiler.mt` | ✗ |

## Coding principles

1. **No workarounds.** If the language can't express something cleanly, fix
   the language first — do not contort the compiler to avoid a bug.
2. **Full bootstrap at each phase.** Every component must be type-checkable
   by the Ruby compiler and (once it exists) the previous-phase self-hosted
   compiler.
3. **No C keywords as identifiers.** Milk Tea's `T?` and C's `char *` share
   names with C keywords. Avoid `return`, `if`, `while`, `for`, `int`,
   `char`, `void`, `struct`, `union`, `enum`, `switch`, `case`, `break`,
   `continue`, `default`, `sizeof`, `typedef`, `static`, `const`, `volatile`,
   `register`, `auto`, `extern`, `goto`, `do`, `float`, `double`, `short`,
   `long`, `signed`, `unsigned` as Milk Tea identifiers in the compiler.
4. **Use `mtc check` to validate early.** Run `mtc check projects/mtc/`
   before every `build` to catch errors without waiting for C compilation.
5. **Clear cache with `--no-cache` on build.** Use `mtc build projects/mtc
   --no-cache` to avoid stale build cache during development.

## Risks

| Risk | Mitigation |
|------|-----------|
| Large variant match exhaustiveness | Milk Tea requires exhaustive match on variants; every place the compiler matches AST/IR must handle all arms |
| `str` lifetime in AST nodes | AST nodes store `str` slices — source must outlive AST; use `string.String` for owned text if needed |
| Recursive parser stack limits | Milk Tea generates C with function call recursion; the recursive-descent parser depth is bounded by expression nesting |
| Proc/closure captures in passes | Lowering passes that take proc callbacks need the capture work properly |
| Build cache staleness | `--no-cache` during development; verify with `diff` against Ruby output in CI |
| `map_error` type inference | Cross-module error wrapping relies on `map_error[F]` with proc type parameter inference; test thoroughly |

## Testing strategy

1. **Golden file tests.** After Phase 5, maintain a set of `.mt` input files
   and their expected `.c` output. The Ruby and Milk Tea compilers must both
   produce output that matches.
2. **Round-trip bootstrap.** After Phase 6, `mtc build projects/mtc` must
   produce a binary that, when run, produces identical C to the Ruby
   compiler.
3. **Incremental diff.** At each phase milestone, `diff` the emitted C of
   both compilers on a representative corpus.

## Language improvements needed

Issues discovered during self-hosting that require language-level fixes before
workarounds are considered:

| Issue | Status |
|-------|--------|
| Char literals should be `ubyte` (for lexer character dispatch) | ✓ Fixed |
| `proc_type_compatible?` must accept TypeVar return types (for `map_error`) | ✓ Fixed |
| `extending` must support variant receiver types | ✓ Fixed |
| Variant method dispatch needs type inference | ✓ Fixed |
| Parallel-for array capture C lowering | ✓ Fixed |
| `?` propagation at statement level (linter false positive) | ✓ Fixed |
| `==` on variant types | ✓ Fixed — sema, lowering, C backend |
| `is` keyword (variant arm membership test) | ✓ Fixed — parser desugaring; rejects struct patterns |
| `at()` safe value accessor on collections | ✓ Fixed — Vec, Deque, Map, Set, OrderedMap, OrderedSet, LinkedMap, LinkedSet |
| `_` discard in struct patterns (`Variant.arm(field, _, _)`) | ✓ Fixed — sema: skip binding/validation; lowering: skip IR emit |
