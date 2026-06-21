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
            └── lower.mt                 # ~931 lines — Tree-based declaration + body C lowering
```

## 3. Lexer — Complete

Token-for-token match with Ruby lexer on all 400+ `.mt` files. 122 member `TokenKind` enum, byte-scanning with full escape validation, indentation tracking.

## 4. Parser — Complete (Tree AST)

Full recursive-descent parser with tree AST. Heap-allocated nodes via `self_heapify()` / `self_alloc_type()` / `self_alloc_block()`.

**Data structures:**
- `Type` — named/constructed/nullable, recursive `inner: ptr[Type]?`
- `Expr` — `left`/`right: ptr[Expr]?`, `args: vec.Vec[ptr[Expr]?]` for call arguments
- `Stmt` — `expr`/`value: ptr[Expr]?`, `body`/`else_body: ptr[Block]?`
- `Block` — `stmts: vec.Vec[Stmt]`

**Verification**: 9/9 self-host + 13/13 examples parse with 0 errors.

## 5. Semantic Analysis — Complete

Two-level symbol table. 40 built-in types. Module loading with cycle detection. String-based compat via `self_type_name()` / `self_type_param_name()`.

**Verification**: 9/9 self-host + 13/13 examples pass `mtc check` with 0 errors.

## 6. Lowering — Tree-Based

### Declaration lowering
- Struct → `typedef struct module_Name { fields } module_Name;`
- Enum/Flags → `enum { module_Name_member = value, ... };`
- Functions/methods → full C signatures with tree-lowered bodies
- Output ordering: forward decls → type definitions → function bodies
- **Type lowering** (`write_ctype_node`): ptr/ref→`T*`, local types→`module_Type`, constructed→`void*`

### Body lowering (tree walk)
- Control flow: `if (cond) { ... }`, `else { ... }`, `while (cond) { ... }`
- Declarations: `let`→`auto`, `var` with Type tree
- **Call forms** (method-first classification): method call → `receiver(args)`, struct ctor → `(Type){ .field = val }`, function call → `f(args)`
- **Member access** (4-level heuristic):
  1. Left is `this` → `->` (pointer receiver)
  2. Root is `this` → `.` (deeper struct field chain)
  3. Left is member_access chain → `_` (namespace continuation)
  4. Top-level: uppercase member → `_`, lowercase → `.`
- Assignment: `lhs op rhs;` from `Stmt.name` + `Stmt.value`
- Methods: `body_block` captured in `parse_extending`, lowered in `write_extending`

### C output example (from parser.mt)
```c
void* parser_self_alloc_type(nodes_TypeKind kind, mt_str name) {
    auto tp = heap.must_alloc[nodes.Type](1);
    tp.kind = kind;
    tp.name = name;
    tp.inner = NULL;
    tp.size_text = "";
    return tp;
}

bool parser_Parser_at_end(parser_Parser *this) {
    return (this->pos >= this->source.len);
}
```

## 7. Ruby Compiler Fixes

- **Enum comparison**: `common_numeric_type` unwraps `EnumBase` to `backing_type`
- **Cycle detection**: Three methods fixed with `visited = Set.new`

## 8. CLI Commands

```
mtc lex <file>        — Token stream (text or --json)
mtc parse <file>      — AST/IR (text or --json)
mtc check <file>      — Semantic analysis
mtc lower <file>      — C lowering (emits to stdout)
mtc combine <files..> — Combined C lowering for multiple files
mtc --help            — Usage info
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
| 5a | Combine subcommand + GCC validation | 🟡 ~778 err combined |

### Step 5a Current State

**Native `mtc combine`** — lowers multiple files into one combined C translation unit (matches Ruby compiler approach). Combined output: ~4243 lines.

**GCC error reduction**: 1000+ standalone → 968 combined → 899 method/ctor reorder → 804 typed `this` → **778** (case-based member access heuristic).

**Key fixes from this session:**
- `skip_header` flag in Lowerer + `combine` subcommand in CLI
- Method/ctor detection reorder (method_call before struct_ctor) — eliminated 69 misclassifications
- Typed `this` parameter in method declarations (`module_Type *this`)
- Member access heuristic with `->` for `this`, `.` for struct fields, `_` for namespaces

**Remaining error categories (~778, need expression type info):**

| Category | Count | Root cause |
|----------|-------|-----------|
| `mt_str` vs `char*` comparison | 53 | String literals vs `mt_str` struct type mismatch |
| struct ctor as expression | 50 | `(Type){ }` compound literal in argument context |
| Return type mismatch | 46 | Struct types returned from `auto` functions |
| `vec_Vec` undeclared | 17 | Stdlib type declarations not emitted |
| void* member access | 40 | `ptr[Expr]` lowered as `void*`, breaking `.kind` etc. |

### Planned Next Steps (resume order)

**5b — Full sema: expression type checking** *(target: break through ~778 error floor)*
Add expression type tracking to the semantic analyzer. Minimum needed:
1. Track types of local variables (`let`/`var` declarations)
2. Track `extending` receiver type for `this` (enables correct C type in method declarations)
3. Resolve call callee types to distinguish functions/methods/struct ctors
4. Use type information in the lowerer for correct C output

Specific fixes this enables:
- `mt_str` comparison → emit `mt_str_equal()` for `str == str`
- Struct return → emit proper C struct return
- Method calls → emit `module_Type_method(&receiver, args)` 
- `vec.Vec` declarations → forward-declare with element type

**6 — True self-host** — Compile the compiler with itself using `mtc combine` + GCC.

### Longer-term

**7. Import resolution depth** — Resolve packages from `source_root` in `package.toml`.

**8. Platform variants** — Select `*.linux.mt` / `*.windows.mt` / `*.wasm.mt`.

**9. CFG** — Build control flow graph from statement trees for optimization/codegen.

## 11. Test Commands

```sh
# Build
cd projects/mtc && ../../bin/mtc build .

# Native combine + GCC check
./build/bin/linux/debug/mtc combine \
  src/mtc/ast/nodes.mt src/mtc/lexer/token.mt src/mtc/lexer/lexer.mt \
  src/mtc/parser/parser.mt src/mtc/sema/symbol.mt src/mtc/sema/loader.mt \
  src/mtc/sema/checker.mt src/mtc/lowering/lower.mt src/main.mt \
  > /tmp/mtc_combined.c
gcc -fsyntax-only -x c /tmp/mtc_combined.c 2>&1 | grep -c "error:"

# Full check sweep
for f in examples/*.mt src/mtc/**/*.mt src/main.mt; do
    ./build/bin/linux/debug/mtc check "$f" 2>&1 | tail -1
done
```
