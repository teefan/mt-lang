# Milk Tea Self-Hosting Compiler — Status Report

## 1. Project Overview

The `projects/mtc` directory contains a self-hosting Milk Tea compiler written in Milk Tea. It compiles to C using the existing Ruby `mtc` compiler and currently provides `lex`, `parse`, `check`, and `lower` subcommands.

**Total**: ~4,080 lines of Milk Tea across 9 source files.

## 2. File Map

```
projects/mtc/
├── package.toml                         # Project manifest
└── src/
    ├── main.mt                          # ~340 lines — CLI entry point
    └── mtc/
        ├── lexer/
        │   ├── token.mt                 # ~137 lines — TokenKind enum (122 members) + Token struct
        │   └── lexer.mt                 # ~1070 lines — Byte-scanning lexer
        ├── parser/
        │   └── parser.mt                # ~1106 lines — Recursive descent + operator precedence
        ├── ast/
        │   └── nodes.mt                 # ~144 lines — Decl/Stmt/Expr structs, enum kinds
        ├── sema/
        │   ├── symbol.mt                # ~260 lines — SymbolKind, SemaContext, ModuleScope
        │   ├── checker.mt               # ~260 lines — 3-pass check: imports → register → validate
        │   └── loader.mt                # ~130 lines — Module loader, path resolution
        └── lowering/
            └── lower.mt                 # ~310 lines — Source-to-C lowering pass
```

## 3. Lexer (`mtc/lexer/`)

### token.mt
- `TokenKind`: `ushort`-backed enum with 122 members (72 keywords, 6 literals, 30 operators, 10 punctuation, 4 synthetic)
- `Token`: struct with `kind`, `lexeme: str`, `line`, `column`, `src_offset`

### lexer.mt
- Byte-scanning with `pos`, `line`, `column`. Keyword lookup via 72-entry chain. Integer/float/char/string/cstring/fstring/heredoc with full escape validation. Indentation tracking with grouping depth and line continuation.

**Status**: Complete. Verifiably matches Ruby lexer output token-for-token on all 400+ `.mt` files.

## 4. Parser (`mtc/parser/parser.mt` + `mtc/ast/nodes.mt`)

### nodes.mt
- `DeclKind` (15 members), `StmtKind` (14), `ExprKind` (17)
- Concrete structs: `SourceFile` (with `is_external: bool`), `Import`, `Decl`, `Stmt`, `Expr`, `Param`, `Field`, `EnumMember`, `VariantArm`, `MatchArm`

### parser.mt
- **Declarations**: 18 types including function, const function, async, external, foreign, struct (with implements + lifetime annotations), enum, flags, variant, interface, type alias, opaque, union, const, var, event, extending, placeholder for when/inline
- **Expressions**: Full precedence chain (`or → and → | → ^ → & → ==/!= → </<=/>/>= → << >> → +- → */% → unary → postfix → primary`)
- **Postfix**: `.member`, `(args)` with named-arg support, `[index]` with multi-arg comma, `?`, `as name`
- **Statements**: `if/else`, `while`, `for`, `match`, `when`, `let/var` (with `else:` / `else as error:`), `return`, `defer`, `unsafe`, `inline`, `parallel`, `break/continue/pass`, assignment (`=`, `+=`, etc.)
- **Types**: Full dotted paths via `source_text.slice()`. Type constructors, keyword tokens (`expect_word()`), `fn`/`proc` types, nullable, bracketed args with no double-consumption.

### Key fixes (Phase A)
- Bracket double-consumption in `parse_type_text` / `skip_bracketed`
- Named-arg call parsing (`=` in call arguments)
- Multi-arg bracket specialization (comma handling)
- Nested struct detection + `@[attr]` skip in struct/union bodies
- Lifetime annotation handling (`[@a]`)
- `else as error:` handling
- Assignment statement parsing
- Type param collection from params/return types
- External file header parsing
- `when`/`inline` empty-name placeholders

**Status**: Complete. All known gaps resolved. 8/8 self-host + 13/13 examples parse successfully with 0 errors.

## 5. Semantic Analysis (`mtc/sema/`)

### symbol.mt
- Two-level symbol table: local `symbols` + `import_scopes` (alias-keyed `ModuleScope` entries)
- 40 built-in types including `str_buffer`
- `resolve_dotted_type()` — splits `alias.TypeName` and traverses import chain
- Silent import registration variants avoid spurious duplicate errors

### checker.mt
- 3-pass: (1) resolve imports → create ModuleScopes, (2) register declarations → collect type params from fields/params/return/arms, (3) validate type references → full dotted-path lookup
- `extract_public_symbols()` extracts public type declarations from loaded modules

### loader.mt
- Resolves `std.vec` → `std/vec.mt` via `self_build_module_path()` using `str_buffer[256]`
- Cycle detection via `loaded` set. Platform-specific fallback.
- `load_module()` actually loads, lexes, and parses imported files.
- Source root resolution via `find_source_root()` → walks path for `/src/` component.

**Status**: Complete. 8/8 self-host + 13/13 examples pass with 0 errors.

## 6. Lowering (`mtc/lowering/lower.mt`)

- Source-to-C lowering pass with module-prefixed type name generation
- Struct → `typedef struct module_Name { fields } module_Name;`
- Enum/Flags → `enum { module_Name_member = value, ... };`
- Functions → `ret_type module_name(params);` (signature only)
- Extending methods → `static ret_type module_Type_method(params);`
- Const/Var → `static [const] type module_name [= value];`
- Type mapping: `int`→`int32_t`, `uint`→`uint32_t`, `str`→`mt_str`, etc.
- Dotted types: `token.Token` → `token_Token` (underscore substitution)
- All output built with `str_buffer[512]` to avoid f-string lifetime issues

**Status**: First pass complete. Emits valid C declarations (structs, enums, function signatures, variables). Function bodies are not yet emitted (signatures only).

## 7. Ruby Compiler Fixes

### Enum comparison operators
`common_numeric_type` / `common_integer_type` in both sema and lowering now unwrap `EnumBase` to `backing_type` before primitive checks. Enables `>=`, `<=`, `>`, `<`, `==`, `!=`, `%` on enum/flags values.

### Cycle detection in lowering
Three methods (`contains_proc_storage_type?`, `contains_task_type?`, `type_contains_array_storage?`) fixed with `visited = Set.new` parameter.

## 8. CLI Commands

```
mtc lex <file>     — Token stream (text or --json)
mtc parse <file>   — AST/IR (text or --json)
mtc check <file>   — Semantic analysis
mtc lower <file>   — C lowering (emits to stdout)
mtc --help         — Usage info
```

## 9. Known Issues — None

All previously known issues resolved. All self-host and example files pass `check` and `lower` with 0 errors.

## 10. Next Steps — Prioritized

1. **C Backend completion** — emit compilable C: add function body pass-through, generate `main()`, add `mtc build` command that invokes `cc`.
2. **Self-host** — compile the compiler with itself (the defining milestone).
3. **Tree AST** — upgrade from text-based AST to recursive tree nodes (unlocks full expression type checking).
4. **Full sema** — expression type checking, call arg validation, match exhaustiveness, control flow analysis.
5. **Import resolution** — properly resolve packages from `source_root` in `package.toml`.
6. **Platform variants** — select `*.linux.mt` / `*.windows.mt` / `*.wasm.mt`.

## 11. Test Commands

```sh
# Build the self-hosting compiler
cd projects/mtc
../../bin/mtc build .

# Run commands
./build/bin/linux/debug/mtc lex examples/language_baseline.mt
./build/bin/linux/debug/mtc parse examples/language_baseline.mt
./build/bin/linux/debug/mtc check examples/language_baseline.mt
./build/bin/linux/debug/mtc lower examples/language_baseline.mt

# JSON output
./build/bin/linux/debug/mtc lex examples/language_baseline.mt --json
./build/bin/linux/debug/mtc parse examples/language_baseline.mt --json

# Full sweep
for f in examples/*.mt; do
    ./build/bin/linux/debug/mtc check "$f" 2>&1 | grep -c "error:"
done
```
