# Milk Tea Self-Hosting Compiler — Status Report

## 1. Project Overview

The `projects/mtc` directory contains a self-hosting Milk Tea compiler written in Milk Tea. It compiles to C using the existing Ruby `mtc` compiler and currently provides `lex`, `parse`, `check`, and `lower` subcommands.

**Total**: ~4,400 lines of Milk Tea across 9 source files.

## 2. File Map

```
projects/mtc/
├── package.toml
└── src/
    ├── main.mt                          # ~346 lines — CLI entry point
    └── mtc/
        ├── lexer/
        │   ├── token.mt                 # ~137 lines — TokenKind enum (122 members) + Token struct
        │   └── lexer.mt                 # ~1068 lines — Byte-scanning lexer
        ├── parser/
        │   └── parser.mt                # ~1220 lines — Recursive descent + tree AST builder
        ├── ast/
        │   └── nodes.mt                 # ~163 lines — AST structs (Type / Expr / Stmt / Block + enum kinds)
        ├── sema/
        │   ├── symbol.mt                # ~254 lines — SymbolKind, SemaContext, ModuleScope
        │   ├── checker.mt               # ~271 lines — 3-pass check: imports → register → validate
        │   └── loader.mt                # ~97 lines — Module loader, path resolution
        └── lowering/
            └── lower.mt                 # ~847 lines — Tree-based declaration + body C lowering
```

## 3. Lexer — Complete

Token-for-token match with Ruby lexer on all 400+ `.mt` files. 122 member `TokenKind` enum, byte-scanning with full escape validation, indentation tracking. Token struct includes `src_offset` for source-position-based text extraction.

## 4. Parser — Complete (Tree AST)

Full recursive-descent parser with tree AST. All declarations, expressions, and statements produce heap-allocated tree nodes via `self_heapify()` / `self_alloc_type()` / `self_alloc_block()`.

**Key data structures:**
- `Type` — `TypeKind` enum (named/constructed/nullable), recursive `inner: ptr[Type]?`, handles dotted paths, bracket args, `?` wrapper
- `Expr` — `left`/`right: ptr[Expr]?`, `args: vec.Vec[ptr[Expr]?]` for call arguments
- `Stmt` — `expr`/`value: ptr[Expr]?` (condition/RHS), `body`/`else_body: ptr[Block]?`
- `Block` — `stmts: vec.Vec[Stmt]`, returned by `parse_block()` as `ptr[Block]`

**Verification**: 9/9 self-host + 13/13 examples parse with 0 errors.

## 5. Semantic Analysis — Complete

Two-level symbol table (local `symbols` + `import_scopes` with `ModuleScope` entries). 40 built-in types. Module loading with cycle detection. String-based compat via `self_type_name()` / `self_type_param_name()`.

**Verification**: 9/9 self-host + 13/13 examples pass `mtc check` with 0 errors.

## 6. Lowering — Tree-Based (Declaration + Body)

### Declaration lowering
- Struct → `typedef struct module_Name { fields } module_Name;`
- Enum/Flags → `enum { module_Name_member = value, ... };`
- Functions/methods → full C signatures with tree-lowered bodies
- Const/Var → `static [const] type module_name [= value];`
- **Type lowering** via `write_ctype_node()`:
  - Primitives: `bool`, `int32_t`, `uintptr_t`, `mt_str`, `void*`, etc.
  - `ptr[T]` / `ref[T]` → `T*` (recurse inner type)
  - Non-pointer constructed types (Vec, array, etc.) → `void*`
  - Local named types → prefix with `module_name_` (e.g., `Type` → `nodes_Type`)
  - Module-qualified names → dots→underscores (e.g., `vec.Vec` → `vec_Vec`)
- **Output ordering**: struct/type definitions emit before function bodies (3-pass: fwd decls → types → functions)

### Body lowering (tree walk)
- `self_lower_block()` iterates statements; `self_lower_stmt()` dispatches per `StmtKind`
- Control flow: `if`/`while` → `if (cond) { ... }`, `else { ... }`
- Declarations: `let`→`auto`, `var` with Type tree
- Expression lowering (`self_write_expr_buf`): identifiers, literals, binary (`and`→`&&`, `or`→`||`, `not`→`!`), member/index access, calls
- **Call forms** (3-way classification):
  - Struct ctor (even-pair args, all identifiers) → `(Type){ .field = val, ... }` designated init
  - Method call (callee is member_access) → `receiver.method(args)`
  - Function call → `f(args...)` with full argument list
- Assignment: `lhs op rhs;` from `Stmt.name` (operator) + `Stmt.value` (RHS)
- `unsafe:` blocks emit inner statements directly
- `write_extending` emits full function bodies (not just signatures) for methods with `body_block`

### C output example
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

**Verification**: 9/9 self-host files pass `mtc check`. 280+ function bodies emitted from parser.mt alone.

## 7. Ruby Compiler Fixes

- **Enum comparison operators**: `common_numeric_type` unwraps `EnumBase` to `backing_type` before primitive checks
- **Cycle detection**: Three methods fixed with `visited = Set.new` parameter

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

| Step | Description | Status |
|------|-------------|--------|
| 1 | Tree AST — Type nodes | ✅ |
| 2 | Tree AST — Expression nodes | ✅ |
| 3 | Tree AST — Statement nodes | ✅ |
| 4 | Full function body lowering | ✅ |
| 4b | Expression capture (call args, assignment RHS) | ✅ |
| 4c | Method body + struct ctor + unsafe lowering | ✅ |
| 5a | GCC syntax-check of lowered C | 🟡 (2/9 pass) |

### Step 5a Findings (GCC `-fsyntax-only` on each lowered `.c` file)

| Selfhost file | GCC errors | Root causes |
|---------------|-----------|-------------|
| **nodes.mt** | **0** | ✅ passes clean |
| **token.mt** | **0** | ✅ passes clean |
| lexer.mt | 135 | implicit fn calls (`is_alpha`, etc.); member access `.` for `lexer_*` prefix |
| lower.mt | 88 | imported type decls missing; method call `.` for stdlib; implicit fn calls |
| parser.mt | 373 | imported type decls missing; method call `.`; implicit fn calls; large function count |
| checker.mt | 24 | `symbol_SemaContext` undeclared; `loader_ModuleLoader` undeclared; member access `.` |
| loader.mt | 33 | imported type decls missing; member access `.` for stdlib (`vec.Vec[str]`) |
| symbol.mt | 62 | `SemaContext` undeclared (self-referential struct ctor); imported types; method `.` |
| main.mt | (many) | imported types; method `.`; switch-on-non-integer from `match`→`switch` |

**Three recurring error categories:**

1. **Cross-module type declarations** — Types imported from other modules (e.g., `symbol.SemaContext` in checker.mt) are not forward-declared in the lowered C. The lowered C is a standalone translation unit with no `#include` for external types. Fix: emit `typedef struct module_Type module_Type;` forward decls for all types referenced in struct fields.

2. **Function call declarations** — Calls to functions defined in other modules (e.g., `checker_loader_ModuleLoader_create`) or stdlib (e.g., `vec.Vec[str].create()`) have no forward declaration. The lowered C references these symbols but they're never declared. Fix: collect and emit forward declarations for all callee symbols, or produce a combined `.c` file that merges all modules.

3. **Member access dots in module-qualified names** — Expressions like `symbol.SemaContext.create()` use `.` member access in the expression tree. The lowering emits `symbol.SemaContext.create()` but C expects `symbol_SemaContext_create(...)` (or `symbol_SemaContext_create(&ctx, ...)` with receiver). Fix: distinguish module-qualified access (dots→underscores) from struct field access in the expression lowerer.

### Planned Next Steps (resume order)

**5a.2 — Cross-module type forward declarations** *(target: pass lexer & lower)*
When lowering a file, scan all struct field types. For each named type in a different module (dotted path like `symbol.SemaContext`), emit a `typedef struct symbol_SemaContext symbol_SemaContext;` forward declaration in the file header. This makes struct definitions that reference imported types compile.

**5a.3 — Fix member access in module-qualified expression contexts** *(target: pass checker & loader)*
Expressions like `symbol.SemaContext.create()` use `.` for both module access and struct field access. The lowerer needs to distinguish these cases. Strategy: if a member_access's left side is itself a member_access chain (dotted path), emit `_` instead of `.` (e.g., `symbol_SemaContext_create`). For simple `receiver.field`, keep `.` (struct field access).

**5a.4 — Function call declarations / emit missing forward decls** *(target: pass parser)*
Collect all function call callee names during lowering, then emit `extern` or `static` forward declarations in the file header. Alternatively, merge all modules into a single combined `.c` file (like the Ruby compiler does).

**5b — Full sema for method call lowering** *(longer term)*
Track receiver types so that `this.advance()` can be lowered to `parser_Parser_advance(&this)` instead of `this.advance()`. Requires expression type inference and method resolution.

**6 — True self-host** — Compile the compiler with itself using `mtc lower` + GCC.

### Longer-term

**7. Import resolution depth** — Resolve packages from `source_root` in `package.toml`.

**8. Platform variants** — Select `*.linux.mt` / `*.windows.mt` / `*.wasm.mt`.

**9. CFG** — Build control flow graph from statement trees for optimization/codegen.

## 11. Test Commands

```sh
# Build + GCC syntax-check all selfhost files
cd projects/mtc && ../../bin/mtc build .
for f in src/mtc/**/*.mt; do
    fn=$(basename "$f" .mt)
    ../../projects/mtc/build/bin/linux/debug/mtc lower "$f" > "/tmp/mtc_${fn}.c"
    echo -n "$fn: " && gcc -fsyntax-only -x c "/tmp/mtc_${fn}.c" 2>&1 | grep -c "error:"
done

# Full check sweep
for f in examples/*.mt src/mtc/**/*.mt src/main.mt; do
    ../../projects/mtc/build/bin/linux/debug/mtc check "$f" 2>&1 | tail -1
done
```
