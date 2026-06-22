# Milk Tea Self-Hosting Compiler — Status Report

## 1. Project Overview

The `projects/mtc` directory contains a self-hosting Milk Tea compiler written in Milk Tea. It compiles to C using the existing Ruby `mtc` compiler and provides `lex`, `parse`, `check`, `lower`, and `combine` subcommands.

**Total**: ~6,200 lines of Milk Tea across 9 source files (lower.mt grew from 931 → 1692 lines during type tracking work).

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
            └── lower.mt                 # ~1692 lines — Tree-based C lowering
```

## 3. Lexer — Complete

Token-for-token match with Ruby lexer. 122 member `TokenKind` enum, byte-scanning with full escape validation, indentation tracking.

## 4. Parser — Complete (Tree AST)

Recursive-descent with tree AST. Heap-allocated nodes. Types (`Type`), expressions (`Expr` with `left`/`right`/`args`), statements (`Stmt` with `expr`/`value`/`body`/`else_body`), blocks (`Block`).

## 5. Semantic Analysis — Complete

Two-level symbol table. 40 built-in types. Module loading with cycle detection.

**Verification**: 9/9 self-host + 13/13 examples pass `mtc check`.

## 6. Lowering — Tree-Based with Lowerer-Local Type Tracking

**Design decision**: Instead of expression type tracking in sema (as originally planned in step 5b), types are tracked directly in the lowerer. This is more pragmatic — it directly addresses C output quality without threading type information through a separate pass, and all declaration information is already available from the parsed AST.

### 6.1 Type Tracking Architecture

| Component | Lines | Purpose |
|---|---|---|
| `type_pool` (4 KB buffer) | +10 | Stable storage for all type name strings. Fixes critical dangling-str bug where `scope_bind` stored `str` values pointing to freed stack-local `str_buffer` buffers |
| `build_type_maps` | +50 | Pre-pass scans all source declarations, builds lookup tables using `pool_type` for stable storage |
| `scope_enter/leave/bind/lookup` | +50 | Maintains a stack of local variable name→C-type mappings during function body lowering. Parameters and `let`/`var` locals are tracked |
| `self_infer_expr_type` | +60 | Bottom-up type inference: literal→primitive, identifier→scope, call→func/method table, member_access→struct field table + heuristic fallback |
| `self_expr_is_mt_str` | +60 | Specialized mt_str detection for binary `==`/`!=` operators, checking scope, func/method tables, struct fields, string literals |
| `self_infer_receiver_type` | +20 | Resolves receiver types for member access chains |
| `struct_field_lookup` | +20 | Looks up struct field C types from `build_type_maps` |
| `current_return_type` tracking | +15 | Stores enclosing function's C return type; used by `read()` builtin for typed pointer dereference |
| `pool_type` helper | +10 | Appends a type string to `type_pool` and returns a stable str slice |

### 6.2 Lookup Tables (built by `build_type_maps`)

| Table | Vectors | Key | Value |
|---|---|---|---|
| Function return types | `func_lookup_names` + `func_lookup_rets` | Milk Tea function name | C return type |
| Method return types | `method_lookup_receivers` + `method_lookup_names` + `method_lookup_rets` | (receiver type, method name) | C return type |
| Struct field types | `field_struct_names` + `field_names` + `field_types` | (C struct name, field name) | C field type |

### 6.3 Phase 1: Forward Declarations + Callee Name Mangling

- Forward declarations emitted for all extending block methods and module-level functions (not just structs/enums)
- `this.method()` callee names replaced with `module_ReceiverType_method` via depth-aware check
- Module-level function calls prefixed with `module_` (e.g., `is_alpha` → `lexer_is_alpha`)
- `self_is_builtin_call` whitelist prevents prefixing of `fatal`, `read`, `ref_of`, `ptr_of`, `const_ptr_of`

### 6.4 Phase 2: Builtins + Standard Library Lowering

- **Vec operations**: `mt_vec` struct in header, `mt_vec_push_impl` / `mt_vec_get_impl` helpers
  - `.create()` → `((mt_vec){0})`
  - `.push(v)` → `do { __typeof__(v) _mtval = v; mt_vec_push_impl(&vec, &_mtval, sizeof(_mtval)); } while(0)`
  - `.get(i)` → `mt_vec_get_impl(&vec, i, sizeof(void*))`
  - `.len()` → `vec.len` field access
- **Builtins recognized**: `fatal` (fwrite+abort), `read` (typed deref), `ref_of` (`&`), `ptr_of` (`(void*)&`), `const_ptr_of` (`(const void*)&`)
- **Struct ctor detection** with uppercase callee check (`self_callee_looks_like_type`)
- **Vec type mapping**: `write_ctype_node` emits `mt_vec` (not `void*`) for `Vec[T]` constructed types, matching the push/get helpers

### 6.5 Phase 3: String Types + Scope Tracking + Expression Type Inference

- **String literals**: `MT_STR("...")` compound-literal macro, producing `mt_str` instead of `char*`
- **`mt_str_eq` helper**: `==` / `!=` on `mt_str` operands lowered to `mt_str_eq()` / `!mt_str_eq()`
- **Binary op detection**: checks `self_infer_expr_type` then `self_expr_is_mt_str` on both operands to decide mt_str_eq path
- **Scope tracking**: parameters bound in `write_function`/`write_extending`, `let`/`var` locals bound in `self_write_let`/`self_write_var`, all via `pool_type` stable storage
- **Member access field type lookup**: within-module via `struct_field_lookup`, cross-module via string-name heuristic (`self_is_string_field_name`)
- **`read()` typed deref**: uses `current_return_type` for return-statement reads, scope type for tracked locals

### 6.6 Line Count Growth

| File | Before | After | Delta |
|---|---|---|---|
| `lower.mt` | 931 | 1692 | +761 |

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

## 10. Progress Summary & Error Reduction

| Stage | Errors | Implicit Decl | Key Changes |
|---|---|---|---|
| **Original (5a)** | **795** | 262 | Three-pass output, `auto` everywhere, no type tracking |
| Phase 1: Fwd decls + name mangling | 711 | 129 | Method forward decls, `this`→receiver_type callee names, module func prefixes |
| Phase 2: Builtins + Vec + struct ctors | 589 | 55 | `mt_vec` helpers, `fatal`/`read`/`ref_of` builtins, Vec `.create`/`.push`/`.get`/`.len`, uppercase struct ctor detection |
| Phase 3a-c: Strings + scope | 448 | 64 | `MT_STR` macro, `mt_str_eq` in binary ops, scope tracking, `self_infer_expr_type` |
| Phase 3d-e: Lookup tables + pool_type | 472 | ~70 | `build_type_maps` func/method/struct field tables, `type_pool` stable storage, `current_return_type` for read() |
| **Current (Phase 3 final)** | **449** | ~70 | Member access field lookup (struct table + heuristic), `self_expr_is_mt_str` extended |

**Total reduction: 795 → 449 (-43.5%)**

### Remaining Error Breakdown

| Count | Category | Root Cause |
|---|---|---|
| 32 | `void value not ignored` | `read()` on `void*` from Vec `.get()` in non-return context. Needs Vec element type tracking or typed get helpers |
| 27 | `mt_str == mt_str` not caught | Method return type lookup fails for some `this.method()` calls (debugging pending) |
| 14 | `request for member 'name' in non-struct` | `auto`-typed struct pointer → member access on void* |
| 13 | `incompatible type for argument 2 of pline` | Some string expressions not detected as `mt_str` |
| 11 | expected `?` token | Edge case in generated C |
| 8 | `SymbolKind` undeclared | Enum type not forward-declared for cross-module use |
| 8 | `pool_type` type mismatch | Argument type issue in scope_bind calls |
| ~336 | Other (type mismatches, void declarations, etc.) | Various edge cases |

## 11. Next Steps (Reasoned)

### Architectural Gaps

The key remaining issue is **cross-module type information**. Each file's lowerer operates independently with its own lookup tables. When `parser.mt` accesses `Decl.name` (where `Decl` is defined in `nodes.mt`), the struct field lookup fails because `nodes_Decl` is not in the parser's field table. The string-name heuristic (`self_is_string_field_name`) covers common field names but is fragile.

Three approaches to cross-module types:

**A. Combine-flow pre-scan (target: ~50 errors):** Before the combine lowering loop in `main.mt`, parse all files and accumulate type maps from all modules into a shared registry. Pass this registry to each file's Lowerer before lowering. Directly fixes struct field lookup across modules. Also fixes `SymbolKind` undeclared (needs enum forward decl from another module's output).

**B. Method return type lookup debugging (target: ~27 errors):** Investigate why `self_infer_expr_type` for `this.method()` calls returns "" for some methods. May be a comparison bug, a `type_pool` overflow issue, or a `current_receiver_type` lifetime problem. Could be diagnosed by checking `method_lookup_receivers` size after `build_type_maps`.

**C. Vec element type tracking (target: ~32 errors):** When a `Vec[T]` is created, record the element type `T` alongside the Vec variable in scope. Then `.get(i)` can emit a typed dereference instead of returning `void*`. This would also let `read()` generate properly-typed code in non-return contexts.

### Recommended Implementation Order

1. **Fix method return type lookup** (smallest effort, ~27 errors): Debug `self_infer_expr_type` for `this.method()` calls. Add a manual check: if the lookup fails but `current_receiver_type` is set, force a second scan with looser matching.

2. **Cross-module type pre-scan** (medium, ~50-80 errors): Modify `main.mt` combine flow to do a pre-pass that accumulates all struct/enum declarations across files into a shared type registry. Pass the registry to each file's lowerer. This fixes struct field lookup, `SymbolKind`, and other cross-module type references.

3. **Vec element type tracking** (medium, ~32 errors): Store element type alongside Vec creation in scope. Extend `.get()` lowering to use the typed element info instead of `sizeof(void*)`.

4. **Return type cascade** (small): Ensure `current_return_type` is set for all function paths, including `const_decl` with bodies and `var_decl` initializers.

5. **True self-host** (remaining ~300 errors): After steps 1-4, the error count should be in the ~200-300 range. The remaining errors are mostly type cascade failures from `auto` pollution — fixing the first few type annotations correctly allows the rest to propagate. At this point, `gcc -o mtc_selfhost /tmp/mtc.c` should succeed.

## 12. Test Commands

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
