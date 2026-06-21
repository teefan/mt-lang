# Milk Tea Self-Hosting Compiler — Status Report

## 1. Project Overview

The `projects/mtc` directory contains a self-hosting Milk Tea compiler written in Milk Tea. It compiles to C using the existing Ruby `mtc` compiler and provides `lex`, `parse`, `check`, `lower`, and `combine` subcommands.

**Total**: ~4,500 lines of Milk Tea across 9 source files.

## 2. File Map

```
projects/mtc/
├── package.toml
└── src/
    ├── main.mt                          # ~374 lines — CLI entry point
    └── mtc/
        ├── lexer/
        │   ├── token.mt                 # ~137 lines — TokenKind enum (122 members)
        │   └── lexer.mt                 # ~1068 lines — Byte-scanning lexer
        ├── parser/
        │   └── parser.mt                # ~1220 lines — Recursive descent + tree AST
        ├── ast/
        │   └── nodes.mt                 # ~163 lines — AST structs + enum kinds
        ├── sema/
        │   ├── symbol.mt                # ~254 lines — SymbolKind, SemaContext
        │   ├── checker.mt               # ~271 lines — 3-pass check
        │   └── loader.mt                # ~97 lines — Module loader
        └── lowering/
            └── lower.mt                 # ~931 lines — Tree-based C lowering
```

## 3. Lexer — Complete

Token-for-token match with Ruby lexer. 122 member `TokenKind` enum, byte-scanning with full escape validation, indentation tracking.

## 4. Parser — Complete (Tree AST)

Recursive-descent with tree AST. Heap-allocated nodes. Types (`Type`), expressions (`Expr` with `left`/`right`/`args`), statements (`Stmt` with `expr`/`value`/`body`/`else_body`), blocks (`Block`).

## 5. Semantic Analysis — Complete

Two-level symbol table. 40 built-in types. Module loading with cycle detection.

**Verification**: 9/9 self-host + 13/13 examples pass `mtc check`.

## 6. Lowering — Tree-Based

**Declarations**: Struct, enum, function signatures with tree-based body lowering. Three-pass output ordering (fwd decls → types → functions). `write_ctype_node` handles ptr/ref→`T*`, local types→`module_Type`, constructed→`void*`.

**Body lowering**: Control flow (`if`/`while`), declarations (`let`/`var`), return, break/continue, expression statements, assignment. **Call forms**: method-first classification (method→member, struct ctor→designated init, func→plain). **Member access**: 4-level heuristic (`->` for `this`, `.` for struct fields, `_` for namespace chains).

**Methods**: Extending block methods captured with `body_block`; `write_extending` emits typed `this` param + full tree-lowered bodies.

## 7. Ruby Compiler Fixes

Enum comparison operators, cycle detection in lowering.

## 8. CLI Commands

```
mtc lex <file>        — Token stream (--json)
mtc parse <file>      — AST (--json)
mtc check <file>      — Semantic analysis
mtc lower <file>      — C lowering
mtc combine <files..> — Combined C lowering
```

## 9. Verification

| Category | Count | Errors |
|----------|-------|--------|
| Self-host source files | 9 | 0 |
| Example files | 13 | 0 |

## 10. Progress Summary & Next Steps

### Completed

| Step | Description | Status |
|------|-------------|--------|
| 1 | Tree AST — Type nodes | ✅ |
| 2 | Tree AST — Expression nodes | ✅ |
| 3 | Tree AST — Statement nodes | ✅ |
| 4 | Full function body lowering | ✅ |
| 4b | Expression capture (call args, assignment RHS) | ✅ |
| 4c | Method body + struct ctor + unsafe lowering | ✅ |
| 5a | Combine subcommand + GCC validation | 🟡 ~795 err |

### Step 5a Status

Native `mtc combine` lowers all files to combined C. **Errors reduced from 1000+ to ~795** through:
- Combined output (single translation unit)
- Method/ctor classification reorder
- Typed `this` param + member access heuristic (`->`/`.`/`_`)
- Numeric/bool/char literal type inference

**Error floor analysis:** Most remaining errors are from function call return types being unknown (e.g., `let d = read(ptr)` → `auto d = read(ptr)` → `auto` infers `void*` → member access fails). The ~795 floor requires expression type tracking in sema.

### Planned Next Steps (resume order)

**5b — Expression type tracking in sema** *(target: break ~795 floor)*
Add an expression type annotation pass. Minimum:
1. Track `let`/`var` local variable types (use `type_node` or infer from initializer)
2. Track `extending` receiver type for `this` in method bodies
3. Propagate types through expression trees (identifier→lookup, literal→primitive, call→declared return)
4. Lowerer reads annotated types for correct C variable declarations and member access

**6 — True self-host** — Compile the compiler with itself via `mtc combine` + GCC.

### Longer-term

**7. Import resolution** — `source_root` in `package.toml`. **8. Platform variants**. **9. CFG**.

## 11. Test Commands

```sh
# Build
cd projects/mtc && ../../bin/mtc build .

# Native combine + GCC
./build/bin/linux/debug/mtc combine \
  src/mtc/ast/nodes.mt src/mtc/lexer/token.mt src/mtc/lexer/lexer.mt \
  src/mtc/parser/parser.mt src/mtc/sema/symbol.mt src/mtc/sema/loader.mt \
  src/mtc/sema/checker.mt src/mtc/lowering/lower.mt src/main.mt \
  > /tmp/mtc.c && gcc -fsyntax-only -x c /tmp/mtc.c 2>&1 | grep -c "error:"

# Full check sweep
for f in examples/*.mt src/mtc/**/*.mt src/main.mt; do
    ./build/bin/linux/debug/mtc check "$f" 2>&1 | tail -1
done
```
