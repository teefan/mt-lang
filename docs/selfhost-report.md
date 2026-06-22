# Milk Tea Self-Hosting Compiler — Status Report

## 1. Project Overview

The `projects/mtc` directory contains a self-hosting Milk Tea compiler written in Milk Tea. It compiles to C using the existing Ruby `mtc` compiler and provides `lex`, `parse`, `check`, `lower`, and `combine` subcommands.

**Total**: ~5,600 lines across 9 source files. lower.mt: 1727 → 1965 (+238 this session).

## 2. File Map

```
projects/mtc/
├── package.toml
└── src/
    ├── main.mt                          # 398 lines — CLI entry point (+24 pre-scan)
    └── mtc/
        ├── lexer/
        │   ├── token.mt                 # 137 lines — TokenKind enum (122 members)
        │   └── lexer.mt                 # 1068 lines — Byte-scanning lexer
        ├── parser/
        │   └── parser.mt                # 1221 lines — Recursive descent + tree AST (+1)
        ├── ast/
        │   └── nodes.mt                 # 163 lines — AST structs + enum kinds
        ├── sema/
        │   ├── symbol.mt                # 254 lines — SymbolKind, SemaContext
        │   ├── checker.mt               # 271 lines — 3-pass check
        │   └── loader.mt                # 97 lines — Module loader
        └── lowering/
            └── lower.mt                 # 1965 lines — Tree-based C lowering (+238)
```

## 3. Lexer — Complete

Token-for-token match with Ruby lexer. 122 member `TokenKind` enum, byte-scanning with full escape validation, indentation tracking.

## 4. Parser — Complete (Tree AST)

Recursive-descent with tree AST. Heap-allocated nodes.

**Key finding**: The parser creates `ExprKind.await_expr` for `unsafe: expr` in expression position (line 987 of parser.mt). This is critical for type inference — `self_infer_expr_type` must delegate through `await_expr` to reach the inner call expression.

**Bug fixed this session**: `parse_unary()` called `tok_lexeme()` after `match_kind()` advanced past the token, reading the NEXT token's lexeme instead of the operator. For `not expr`, this stored `"this"` instead of `"not"`, causing the lowerer to emit `thisparser_Parser_at_end` instead of `!parser_Parser_at_end`. Fix: use `check()` (peek) before `advance()` to save lexeme first.

## 5. Semantic Analysis — Complete

Two-level symbol table. 40 built-in types. Module loading with cycle detection.

**Verification**: 9/9 self-host files parse and build successfully via the Ruby compiler. Self-host checker has unresolved-type errors on lower.mt and some files due to field count or module resolution limits (pre-existing, under investigation).

## 6. Lowering — Tree-Based with Lowerer-Local Type Tracking

**Design decision**: Type tracking lives in the lowerer, not in sema. All declaration information is available from the parsed AST.

### 6.1 Architecture

| Component | Purpose |
|---|---|
| `type_pool` (4 KB buffer) | Stable storage for type strings. Fixes dangling-str bug |
| `build_type_maps` | Pre-pass scans declarations, builds func/method/struct lookup tables. Now also populates global cross-module maps and Vec element types. |
| `scope_enter/leave/bind/lookup` | Stack of local variable name→C-type mappings |
| `self_infer_expr_type` | Bottom-up type inference: literals, identifiers, calls, member_access. Now editable to support ref-based global lookups. |
| `self_expr_is_mt_str` | mt_str detection for `==`/`!=` operators. Now delegates through await_expr nodes. |
| `self_infer_receiver_type` | Resolves receiver types for member access chains |
| `struct_field_lookup` | Looks up struct field C types |
| `self_is_str_vec_field` | Hardcoded list of known `vec.Vec[str]` fields on `this` |
| `self_vec_elem_type` | **NEW** — Standalone function combining hardcoded str-vec check with global cross-module Vec element type lookup |
| `global_vec_elem_lookup` | **NEW** — Searches cross-module Vec element type arrays (populated by pre-scan) |
| `copy_global_maps_from` | **NEW** — Merges type maps (func, method, field, Vec elem) from another lowerer instance |
| `global_vec_structs/names/types` | **NEW** — Cross-module Vec element type storage |
| `global_func_names/rets` | **NEW** — Cross-module function return type storage |
| `global_method_receivers/names/rets` | **NEW** — Cross-module method return type storage |
| `self_is_builtin_call` | Whitelist prevents module prefix on builtin names |
| `self_try_write_builtin` | **EXTENDED** — Now handles `heap.alloc[T](n)` and `heap.must_alloc[T](n)` lowering to `malloc` |
| `self_write_var` | **FIXED** — Now infers type from initializer (was missing, only `self_write_let` had it). Critical: caused `var x = ""` to be untyped, missing mt_str detection. |

### 6.2 Phases Applied

| Phase | Changes |
|---|---|
| **Phase 1** | Forward declarations for methods/functions, callee name mangling (`this.method` → `module_Type_method`) |
| **Phase 2** | `mt_vec` helpers, builtins (`fatal`, `read`, `ref_of`, `ptr_of`, `const_ptr_of`), struct ctor detection with uppercase check, Vec type mapping (`mt_vec` not `void*`) |
| **Phase 3** | `MT_STR` macro, `mt_str_eq` helper, scope tracking, `build_type_maps`, `self_infer_expr_type`, member access field lookup, `read()` typed deref via `current_return_type` |
| **Phase 3b** | `await_expr` delegation in type inference, `read()` bug fix (removed `or cast_type == ""` fallback), Vec.get() detection restructured outside `this`-block, `self_is_str_vec_field` + str Vec element typing (`sizeof(mt_str)`, `(mt_str*)` cast) |
| **Phase 4** | **THIS SESSION** — Cross-module pre-scan, global type maps, Vec element tracking, heap allocation lowering, parser bug fixes, var type inference fix |

## 7. Ruby Compiler Fixes

Enum comparison operators, cycle detection in lowering. (No changes this session.)

## 8. CLI Commands

```
mtc lex <file>        — Token stream (--json)
mtc parse <file>      — AST (--json)
mtc check <file>      — Semantic analysis
mtc lower <file>      — C lowering
mtc combine <files..> — Combined C lowering (TWO-PASS: pre-scan maps, then lower)
```

## 9. Verification

| Category | Count | Errors |
|----------|-------|--------|
| Self-host source files | 9 | 7 pass check (lower.mt + nodes.mt have checker limits) |
| Build (via Ruby mtc) | 9 | 0 — all build successfully |

## 10. Error Reduction Progress

| Stage | Errors | Key Change |
|---|---|---|
| **Original (5a)** | **795** | `auto` everywhere, no type tracking |
| Phase 1: Fwd decls + name mangling | 711 | Method fwd decls, callee name mangling |
| Phase 2: Builtins + Vec + struct ctors | 589 | `mt_vec` helpers, builtins, struct ctor detection |
| Phase 3: Strings + scope + lookup tables | 448 | `MT_STR`, `mt_str_eq`, scope tracking, `build_type_maps` |
| Phase 3b: Bug fixes | 455 | await_expr, read() bug, Vec.get() str typing, method_lookup_ret fixed |
| **Phase 4 (current, uncommitted)** | **329** | See §10.1 below |

**Total reduction: 795 → 329 (-58.6%)**

### 10.1 Phase 4 Changes (This Session)

| Fix | Impact | Category |
|---|---|---|
| Parser `parse_unary` — save lexeme before match | -11 | `thisparser_Parser_*` double-prefix, missing `!` |
| Lowerer `?` identifier → `NULL` | -4 | `expected before '?' token` in generated C |
| `self_write_var` type inference from initializer | **-118** | mt_str `==`/`!=` errors, `auto` cascade — all gone |
| Heap alloc lowering (`heap.alloc[T]` → `malloc`) | -3 | `heap` undeclared in generated C |
| Combine pre-scan (two-pass) | 0 | Infrastructure for cross-module type lookup |
| Vec element tracking (`self_vec_elem_type`, global maps) | 0 | Infrastructure: correct casts generated for known Vec fields |
| Global func/method return type lookup | 0 | Foundation for future cross-module resolution |
| `await_expr` delegation in `self_expr_is_mt_str` | 0 | Preventative |

### 10.2 What's Working (Verified in Generated C)

Vec.get() now produces correct typed casts for known Vec fields:

```c
// Before (all void*):
auto t = mt_vec_get_impl(&(this->tokens), this->pos, sizeof(void*));

// After (properly typed):
token_Token* t = (token_Token*)mt_vec_get_impl(&(this->tokens), this->pos, sizeof(token_Token));
symbol_Symbol* s = (symbol_Symbol*)mt_vec_get_impl(&(this->symbols), i, sizeof(symbol_Symbol));
nodes_Decl* nd = (nodes_Decl*)mt_vec_get_impl(&(this->nested_decls), ni, sizeof(nodes_Decl));
```

Heap allocation now produces correct C:
```c
// Before (invalid C):
auto tp = heap.must_alloc[nodes_Type](1);

// After:
auto tp = ((nodes_Type*)malloc(sizeof(nodes_Type) * 1));
```

Var declarations now infer types (was only working for `let`, now also for `var`):
```c
// Before:
auto x = MT_STR("");  // untyped, no scope binding

// After:
mt_str x = MT_STR("");  // typed, scope-bound, mt_str detection works
```

### 10.3 Remaining Error Categories (~329)

| Count | Category | Root Cause | Fix Approach |
|---|---|---|---|
| ~48 | `void value not ignored` | Vec.get() on local variables (not `this` fields) uses `sizeof(void*)`. Global Vec element tracking only covers struct fields, not local vars. | Extend element type tracking (Step 1 already implemented, needs local-var support) |
| ~21 | `char*` init from int | Type mismatch in compound literal initialization. Caused by `auto` pollution where expression type couldn't be resolved. | Improve `self_infer_expr_type` for edge cases |
| ~13 | pline type mismatch | Expressions passed to `pline()` not detected as `mt_str`. | Enhance mt_str detection for more expression forms |
| ~11 | `_mtval` declared void | Vec.push() with unresolved element type produces `void _mtval`. | From same root cause as "void value not ignored" |
| ~8 | `SymbolKind` undeclared | Cross-module enum member access missing module prefix (`SymbolKind` vs `symbol_SymbolKind`). | Add enum type tracking to global maps |
| ~228 | Cascade failures | `auto` pollution from un-resolved types causing downstream errors. | Fixed by remaining type inference improvements |

## 11. Proven & Disproven Approaches

### 11.1 Vec.get() Type Inference for str Fields (PROVEN — applied)

`self_is_str_vec_field` + `mt_str*` return + `sizeof(mt_str)` + `(mt_str*)` cast. Fixed `method_lookup_ret` to generate correct C. Now extended to generic element types via `self_vec_elem_type` + global maps.

### 11.2 await_expr Delegation (PROVEN — applied)

Parser creates `ExprKind.await_expr` for `unsafe: expr`. Without delegation in `self_infer_expr_type` and `self_expr_is_mt_str`, ALL read() type inference fails. Fix: delegate through `await_expr` to inner expression. **Now also applied to `self_expr_is_mt_str`** (was missing).

### 11.3 read() Builtin Wrong Cast (PROVEN — fixed)

`self_write_builtin_read` used `current_return_type` as cast for ALL pointers. Fix: removed `or cast_type == ""` from fallback condition.

### 11.4 Vec.get() Detection Outside `this`-Block (PROVEN — fixed)

Vec.get() type inference was inside `if receiver_expr.name == "this"` block, unreachable for `this.field.get(i)`. Fix: moved check outside the block.

### 11.5 Vec Element Type Tracking (PROVEN — RE-IMPLEMENTED)

Full `self_vec_elem_type` infrastructure with cross-module pre-scan now re-implemented:
- `global_vec_structs/names/types` arrays in Lowerer
- `build_type_maps` extracts inner type from `Vec[T]` struct fields
- `global_vec_elem_lookup(struct_cname, field_name)` cross-module lookup
- `self_vec_elem_type()` standalone function combining hardcoded str-vec check + global lookup
- `self_infer_expr_type` now returns `elem_type*` for Vec.get()
- `self_write_vec_method` .get() uses `(elem_type*)` cast and `sizeof(elem_type)`
- Two-pass combine: pre-scan phase collects maps, second phase uses them

**Limitation**: Only covers Vec fields on `this` struct fields (requires `current_receiver_type` to be set). Local variables with Vec types are not covered.

### 11.6 Cross-Module Global Type Maps (PROVEN — RE-IMPLEMENTED)

Two-pass combine (pre-scan + lower) now re-implemented:
- `global_func_names/rets` — cross-module function return types
- `global_method_receivers/names/rets` — cross-module method return types
- `copy_global_maps_from(master)` — merges maps from pre-scan collector into each file's lowerer
- `func_lookup_ret` and `method_lookup_ret` now check global maps as fallback

### 11.7 Parser parse_unary Bug (PROVEN — FIXED)

`tok_lexeme()` called after `match_kind()` advanced past the operator token, reading the next token's lexeme. For `not expr`, stored `"this"` instead of `"not"`. Fix: use `check()` + `advance()` to save lexeme before consuming the token.

### 11.8 ? Literal in Generated C (PROVEN — FIXED)

Parser fallback expression created `ExprKind.identifier` with name `"?"`. Lowerer wrote this as literal `?` in C output. Fix: lowerer replaces `"?"` identifier with `"NULL"`.

### 11.9 Var Type Inference Gap (PROVEN — FIXED)

`self_write_var` was missing type inference from initializer (only `self_write_let` had it). This caused `var x = ""` to produce untyped `auto` with no scope binding, preventing mt_str detection for comparisons. **Impact: -118 errors** (largest single fix this session). Added type inference to `self_write_var` matching `self_write_let`.

### 11.10 Heap Allocation Lowering (PROVEN — IMPLEMENTED)

`heap.alloc[T](n)` and `heap.must_alloc[T](n)` now lower to `((T*)malloc(sizeof(T) * n))`. Handler added to `self_try_write_builtin` via index_access callee detection. Fixed 3 "heap undeclared" errors.

## 12. Resumption Plan — Updated

### Completed (this session)

- [x] Step 1: Re-add Full Vec Element Type Tracking
- [x] Step 2: Extend await_expr Coverage
- [x] Step 3: Heap Allocation Lowering
- [x] Step 4: Combine Pre-scan for Global Type Maps
- [x] Plus: Parser parse_unary bug fix
- [x] Plus: ? literal fix
- [x] Plus: Var type inference fix (unexpected high-impact find)

### Next Steps (ordered by impact)

#### Step 5: Extend Vec Element Tracking to Local Variables

Currently `self_vec_elem_type` only works for `this.field.get(i)` patterns (requires `current_receiver_type`). Local variables like `names.get(i)` don't resolve. Solution: track variable types in scope, not just C type strings but also the Milk Tea type structure (Vec[T] info). Estimated: -40 errors.

#### Step 6: Fix SymbolKind (and other cross-module enums)

Enum member access like `SymbolKind.type_symbol` produces `SymbolKind_type_symbol` instead of `symbol_SymbolKind_type_symbol`. The module prefix is missing because the identifier doesn't know which module defines it. Solution: add enum tracking to global maps, prefix enum member access with the defining module name. Estimated: -8 errors.

#### Step 7: Improve mt_str Detection for More Expression Forms

Remaining pline type mismatch errors (13) and char* init errors (21) come from expressions whose type can't be inferred as mt_str. Solution: extend `self_infer_expr_type` and `self_expr_is_mt_str` to handle more expression forms (if-expr, match-expr, member access chains with global lookup). Estimated: -30 errors.

#### Step 8: True Self-Host

After steps 5-7, errors should be ~200-250. Test `gcc -o mtc_selfhost /tmp/mtc.c`.

## 13. Other Items

### Std Library Review

All 9 reviewed modules (`vec.mt`, `map.mt`, `deque.mt`, `option.mt`, `result.mt`, `string.mt`, `str.mt`, `mem/heap.mt`, `mem/arena.mt`) are substantially complete and correct. One bug fixed: `std/vec.mt:353` — `order[T](read(ptr), ...)` changed to `order[T](ptr, ...)` to match spec (rvalue → pointer).

### Git State

Commit `f21d8847` has all 5 Phase 3b fixes. Current working tree has Phase 4 changes (uncommitted):
- `parser.mt`: +1 line (parse_unary fix)
- `lower.mt`: +238 lines (global maps, vec elem, heap, var inference, await_expr)
- `main.mt`: +24 lines (combine two-pass pre-scan)

## 14. Test Commands

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
for f in src/mtc/**/*.mt src/main.mt; do
    ./build/bin/linux/debug/mtc check "$f" 2>&1 | tail -1
done
```
