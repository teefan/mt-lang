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

**Design decision**: Instead of expression type tracking in sema (as originally planned in step 5b), types are tracked directly in the lowerer. This directly addresses C output quality and avoids threading type information through a separate pass. All declaration information is available from the parsed AST.

### 6.1 Type Tracking Architecture

| Component | Purpose |
|---|---|
| `type_pool` (4 KB buffer) | Stable storage for all type name strings. Fixes critical dangling-str bug |
| `build_type_maps` | Pre-pass scans all source declarations, builds lookup tables using `pool_type` |
| `scope_enter/leave/bind/lookup` | Maintains a stack of local variable name→C-type mappings |
| `self_infer_expr_type` | Bottom-up type inference: literals, identifiers (scope), calls (func/method table), member_access (struct field table + heuristic) |
| `self_expr_is_mt_str` | Specialized mt_str detection for binary `==`/`!=` operators |
| `self_infer_receiver_type` | Resolves receiver types for member access chains |
| `struct_field_lookup` | Looks up struct field C types from `build_type_maps` |
| `current_return_type` / `current_receiver_type` | Context for method dispatch and `read()` type casting |
| `pool_type` helper | Appends a type string to `type_pool` and returns a stable str slice |

### 6.2 Lookup Tables (built by `build_type_maps`)

| Table | Key | Value |
|---|---|---|
| Function return types | Milk Tea function name | C return type |
| Method return types | (receiver type, method name) | C return type |
| Struct field types | (C struct name, field name) | C field type |

### 6.3 Phase 1: Forward Declarations + Callee Name Mangling

- Forward declarations emitted for all extending block methods and module-level functions
- `this.method()` callee names replaced with `module_ReceiverType_method` via depth-aware check
- Module-level function calls prefixed with module name
- `self_is_builtin_call` prevents prefixing of `fatal`, `read`, `ref_of`, `ptr_of`, `const_ptr_of`

### 6.4 Phase 2: Builtins + Standard Library Lowering

- **Vec operations**: `mt_vec` struct + `mt_vec_push_impl`/`mt_vec_get_impl` helpers
  - `.create()` → `((mt_vec){0})`
  - `.push(v)` → `do { __typeof__(v) _mtval = v; mt_vec_push_impl(&vec, &_mtval, sizeof(_mtval)); } while(0)`
  - `.get(i)` → `mt_vec_get_impl(&vec, i, sizeof(void*))`
  - `.len()` → `vec.len` field access
- **Builtins**: `fatal` (fwrite+abort), `read` (typed deref), `ref_of` (`&`), `ptr_of` (`(void*)&`), `const_ptr_of` (`(const void*)&`)
- **Struct ctor detection** with uppercase callee check
- **Vec type mapping**: `write_ctype_node` emits `mt_vec` for `Vec[T]` types

### 6.5 Phase 3: Strings + Scope + Expression Type Inference

- **String literals**: `MT_STR("...")` macro → `mt_str` instead of `char*`
- **`mt_str_eq` helper**: `==`/`!=` on `mt_str` → `mt_str_eq()`/`!mt_str_eq()`
- **Binary op detection**: checks `self_infer_expr_type` → `self_expr_is_mt_str` on both operands
- **Scope tracking**: parameters + `let`/`var` locals → `pool_type` stable storage
- **Member access field lookup**: `struct_field_lookup` (within-module) + `self_is_string_field_name` heuristic (cross-module)
- **`read()` typed deref**: uses `current_return_type` for return statements, scope type for tracked locals

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
| Phase 1: Fwd decls + name mangling | 711 | 129 | Method fwd decls, callee name mangling, `this`→receiver_type |
| Phase 2: Builtins + Vec + struct ctors | 589 | 55 | `mt_vec` helpers, `fatal`/`read`/`ref_of` builtins, struct ctor detection |
| Phase 3: Strings + scope + lookup tables | 448 | 64 | `MT_STR` macro, `mt_str_eq`, scope tracking, `build_type_maps`, `self_infer_expr_type` |
| **Current (committed)** | **449** | ~70 | Struct field lookup, `current_return_type` for read(), `self_expr_is_mt_str` |

**Total reduction: 795 → 449 (-43.5%)**

### Current Error Breakdown (~449)

| Count | Category | Root Cause |
|---|---|---|
| ~32 | `void value not ignored` | `read()` on `void*` from Vec `.get()`. Vec.get returns `void*` with `sizeof(void*)` — wrong for value-type elements |
| ~27 | `mt_str == mt_str` not caught | Method return type lookup returns "" for some `this.method()` calls |
| ~14 | `request for member 'X' in non-struct` | `auto`-typed struct pointer → member access on void* |
| ~13 | `incompatible type for argument 2 of pline` | String expressions not all detected as `mt_str` |
| ~11 | expected `?` token | Edge case in generated C |
| ~8 | `SymbolKind` undeclared | Enum type not forward-declared for cross-module use |
| ~344 | Other (type mismatches, void declarations) | Cascade failures from `auto` pollution |

## 11. Research Findings & Proven Breakthrough

### 11.1 Vec Element Type Tracking (PROVEN — highest impact)

**Experiment**: Record Vec element types from struct field declarations (`vec.Vec[T]` → extract T's C type). Use recorded element type in `.get()` lowering and type inference.

**Result**: 469 → 363 (-106 errors, -22.6%). The `.get()` on known Vec fields now emits `(elem_type*)mt_vec_get_impl(... , sizeof(elem_type))` with correct cast + size. Void errors dropped from 43 → 18, member access errors mostly eliminated.

**Status**: Lost in git revert. Needs re-implementation (~80 lines).

### 11.2 Cross-Module Type Maps (DISPROVEN — minimal impact)

**Experiment**: Pre-scan all files in combine flow, build global type maps, reference via pointer fallback in lookup functions.

**Result**: Error count unchanged. The global maps are populated correctly but the bottleneck is the method return type lookup itself, not cross-module field access.

### 11.3 Method Return Type Lookup (DEBUG NEEDED)

**Experiment**: Forced `self_infer_expr_type` to return "mt_str" for ALL this.method() calls. Error count barely changed (449 → few). The issue: most `this.method()` return types resolve correctly from the local lookup tables — only a few specific methods (like `tok_lexeme`) fail. The failure is likely a `str` comparison mismatch in `method_lookup_ret`.

### 11.4 read() Call Type Inference (PROPOSED — simpler approach)

**Experiment**: Bypass the complex `self_infer_read_pointee_type` (which accesses `e.args.get(0)`) and instead directly check the first argument of a read() call via a simpler `self_infer_read_direct` method.

**Status**: Was about to test when file corruption occurred. Needs re-implementation.

## 12. Next Steps (Re-ordered by Impact)

### Step 1: Re-add Vec Element Type Tracking (~80 lines, target: ~100 errors)

Exact changes needed in `lower.mt`:

```
A. Add vec_elem_structs/fields/types vectors to Lowerer struct
B. Extend build_type_maps: for struct fields with type type_constructed name="Vec",
   extract inner element type via write_ctype_node, pool_type, store in vec_elem_*
C. Add vec_elem_lookup(struct_cname, field_name) -> element_C_type
D. Add self_vec_elem_type(recv_expr) helper — resolves member access to struct+field
E. Update self_write_vec_method for ".get()": use self_vec_elem_type for cast + sizeof
F. Update self_infer_expr_type for ".get()": return elem_type* via pool_type
```

### Step 2: Add self_infer_read_direct (~20 lines, target: ~30 errors)

Simpler read() type inference that directly checks the argument's scope type without going through the full args-Vec extraction chain.

### Step 3: Debug method return type lookup (~10 lines, target: ~27 errors)

The `method_lookup_ret` function's `str == str` comparisons produce `mt_str == mt_str` in generated C. With vec_elem tracking, the Vec accesses in the lookup function become correctly typed, which should allow the str comparisons to be detected. If not, add a targeted fix.

### Step 4: True self-host (~200 errors)

After steps 1-3, error count should be ~150-250. The remaining errors are type cascade failures. At this point, test `gcc -o mtc_selfhost /tmp/mtc.c`.

## 13. Test Commands

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
