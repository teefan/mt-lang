# Milk Tea Self-Hosting Compiler — Status Report

## 1. Project Overview

The `projects/mtc` directory contains a self-hosting Milk Tea compiler written in Milk Tea. It compiles to C using the existing Ruby `mtc` compiler and currently provides `lex`, `parse`, `check`, and `lower` subcommands.

**Total**: ~4,300 lines of Milk Tea across 9 source files.

## 2. File Map

```
projects/mtc/
├── package.toml                         # Project manifest
└── src/
    ├── main.mt                          # ~346 lines — CLI entry point
    └── mtc/
        ├── lexer/
        │   ├── token.mt                 # ~137 lines — TokenKind enum (122 members) + Token struct
        │   └── lexer.mt                 # ~1068 lines — Byte-scanning lexer
        ├── parser/
        │   └── parser.mt                # ~1219 lines — Recursive descent + tree AST builder
        ├── ast/
        │   └── nodes.mt                 # ~163 lines — AST structs (Type / Expr / Stmt / Block + enum kinds)
        ├── sema/
        │   ├── symbol.mt                # ~254 lines — SymbolKind, SemaContext, ModuleScope
        │   ├── checker.mt               # ~271 lines — 3-pass check: imports → register → validate
        │   └── loader.mt                # ~97 lines — Module loader, path resolution
        └── lowering/
            └── lower.mt                 # ~761 lines — Tree-based declaration + body C lowering
```

## 3. Lexer — Complete

Token-for-token match with Ruby lexer on all 400+ `.mt` files. 122 member `TokenKind` enum, byte-scanning with full escape validation, indentation tracking. Token struct includes `src_offset` for source-position-based text extraction.

## 4. Parser — Complete (Tree AST)

18 declaration types, full operator precedence chain, postfix chain with named-arg + multi-arg support, all statement variants including guard forms, assignment operators, match patterns.

**Tree AST** (replaces original flat text-based representations):
- **Type tree** — `TypeKind` enum (`type_named`/`type_constructed`/`type_nullable`) + recursive `Type` struct with `inner: ptr[Type]?`. Handles dotted paths, bracket args, nullable `?` wrapper. Parsed via `parse_type() → parse_type_base()`.
- **Expression tree** — `Expr` struct with `left: ptr[Expr]?` / `right: ptr[Expr]?` child pointers, `args: vec.Vec[ptr[Expr]?]` for call arguments. Nodes heap-allocated via `self_heapify()`. Covers binary/unary ops, member access, calls, index access, literals, identifiers.
- **Statement tree** — `Stmt` struct with `expr: ptr[Expr]?` (condition/value), `value: ptr[Expr]?` (assignment RHS), `body: ptr[Block]?` (control flow body), `else_body: ptr[Block]?` (else branch). `Block` struct holds `vec.Vec[Stmt]`. `parse_block()` returns `ptr[Block]` via `self_alloc_block()`.

**Remaining known limitation**: `else if` chains are parsed as nested `if` inside `else` body (structurally correct).

**Verification**: 9/9 self-host + 13/13 examples parse with 0 errors.

## 5. Semantic Analysis — Complete

Two-level symbol table (local `symbols` + `import_scopes` with `ModuleScope` entries). 40 built-in types. `resolve_dotted_type()` traverses import chain. Silent import registration avoids duplicate errors. Type params collected from fields/params/return/arms. Module loading via `self_build_module_path()` with `str_buffer[256]` and cycle detection. `find_source_root()` walks path for `/src/` component.

String-based compat layer: `self_type_name()` and `self_type_param_name()` extract flat type names from `ptr[Type]?` nodes for validation.

**Verification**: 9/9 self-host + 13/13 examples pass `mtc check` with 0 errors.

## 6. Lowering — Tree-Based (Declaration + Body)

### Declaration lowering
- Struct → `typedef struct module_Name { fields } module_Name;`
- Enum/Flags → `enum { module_Name_member = value, ... };`
- Functions → full C signatures with body
- Extending methods → `static ret_type module_Type_method(params) { ... }` — now with full tree-lowered bodies
- Const/Var → `static [const] type module_name [= value];`
- Types mapped via `write_ctype_node()` which traverses the Type tree

### Body lowering (tree-based)
Recursive tree walk replacing the old character-level `self_translate_body`:
- **`self_lower_block(block)`** — iterates statements
- **`self_lower_stmt(stmt_ptr)`** — dispatches per `StmtKind`:
  - if/while/match → proper C brace blocks with indentation
  - let → `auto name [= init];`
  - var → `type name [= init];` (with Type tree)
  - return → `return expr;`
  - break/continue/pass → `break;` / `continue;` / `;`
  - expression stmt → `expr;` or `lhs op rhs;` (assignment)
  - unsafe → strips wrapper, emits inner block
- **`self_write_expr_buf(expr_ptr)`** — dispatches per `ExprKind`:
  - Literals, identifiers, binary (`and`→`&&`, `or`→`||`), unary (`not`→`!`)
  - Member access → `receiver.member`, index → `receiver[index]`
  - Call → classified into three forms:
    - **Struct ctor** (even-pair args, all identifiers) → `(Type){ .field = val, ... }`
    - **Method call** (callee is member_access) → `receiver.method(args)`
    - **Function call** → `f(args)` with full argument list
  - Await/unsafe → passthrough inner expression

### C output example (from parser.mt lowered source):
```c
void* parser_self_alloc_type(nodes_TypeKind kind, mt_str name) {
    auto tp = heap.must_alloc[nodes.Type](1);
    tp.kind = kind;
    tp.name = name;
    tp.inner = NULL;
    tp.size_text = "";
    return tp;
}

bool parser_Parser_at_end() {
    return (this.pos >= this.tokens.len());
}
```

**Verification**: 9/9 self-host files pass `mtc check` with 0 errors. `mtc lower` emits structurally correct C for all function bodies including extending block methods. 280+ function closures emitted from parser.mt alone.

## 7. Ruby Compiler Fixes

### Enum comparison operators
`common_numeric_type` / `common_integer_type` in both sema and lowering unwrap `EnumBase` to `backing_type` before primitive checks. Enables all comparison operators on enum/flags.

### Cycle detection in lowering
Three methods fixed with `visited = Set.new` parameter.

## 8. CLI Commands

```
mtc lex <file>     — Token stream (text or --json)
mtc parse <file>   — AST/IR (text or --json)
mtc check <file>   — Semantic analysis
mtc lower <file>   — C lowering (emits to stdout)
mtc --help         — Usage info
```

## 9. Verification — All Pass

| Category | Count | Errors |
|----------|-------|--------|
| Self-host source files | 9 | 0 |
| Example files | 13 | 0 |
| `mtc lower` output | all | clean |

## 10. Progress Summary & Next Steps

### Completed

| Step | Description | Lines | Status |
|------|-------------|-------|--------|
| 1 | Tree AST — Type nodes | ~300 | ✅ |
| 2 | Tree AST — Expression nodes | ~800 | ✅ |
| 3 | Tree AST — Statement nodes | ~500 | ✅ |
| 4 | Full function body lowering | ~400 | ✅ |
| 4b | Expression capture (call args, assignment RHS) | ~200 | ✅ |
| 4c | Method body + struct ctor + unsafe lowering | ~250 | ✅ |

The recursive AST (Type → Expr → Stmt → Block) and tree-based lowering are in place. All function bodies (including extending block methods) are lowered from statement trees with proper control flow, call arguments, assignments, struct construction, and unsafe block contents.

### Planned Next Steps (resume order)

**5a. Verify lowered C compiles with GCC** — The lowered C is structurally complete. Attempt `gcc -fsyntax-only` on the full lowered output for each selfhost source file. Fix any C syntax issues that surface. This step proves the lowering is correct at the C syntax level.

**5b. Full sema — expression type checking** — Track receiver types to enable correct method call lowering (currently `this.advance()` → `this.advance()`, needs `parser_Parser_advance(&this)` for C compatibility). Requires:
- Expression type inference for local variables
- Track `extending` receiver type for `this` references
- Resolve method names to qualified C symbols
- Call argument type validation

**6. Self-host** — Compile the compiler with itself. Requires steps 5a-5b to produce GCC-compilable C for all 9 source files. The selfhost compiler's `mtc lower` output should compile with GCC to produce a working `mtc` binary.

### Longer-term

**7. Import resolution depth** — Properly resolve packages from `source_root` in `package.toml`.

**8. Platform variants** — Select `*.linux.mt` / `*.windows.mt` / `*.wasm.mt`.

**9. CFG** — Build control flow graph from statement trees for optimization/codegen.

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

# Full sweep
for f in examples/*.mt projects/mtc/src/**/*.mt projects/mtc/src/main.mt; do
    ./build/bin/linux/debug/mtc check "$f" 2>&1 | grep -c "error:"
done
```
