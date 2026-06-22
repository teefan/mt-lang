# Milk Tea Self-Hosting Compiler — Status Report

## 1. Project Overview

The `projects/mtc` directory contains a self-hosting Milk Tea compiler written in Milk Tea. It compiles to C using the existing Ruby `mtc` compiler and provides `lex`, `parse`, `check`, `lower`, and `combine` subcommands.

**Total**: ~6,300 lines across 9 source files. lower.mt grew from 931 → 1727 (+796) during type tracking work.

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
            └── lower.mt                 # ~1727 lines — Tree-based C lowering
```

## 3. Lexer — Complete

Token-for-token match with Ruby lexer. 122 member `TokenKind` enum, byte-scanning with full escape validation, indentation tracking.

## 4. Parser — Complete (Tree AST)

Recursive-descent with tree AST. Heap-allocated nodes.

**Key finding**: The parser creates `ExprKind.await_expr` for `unsafe: expr` in expression position (line 987 of parser.mt). This is critical for type inference — `self_infer_expr_type` must delegate through `await_expr` to reach the inner call expression.

## 5. Semantic Analysis — Complete

Two-level symbol table. 40 built-in types. Module loading with cycle detection.

**Verification**: 9/9 self-host + 13/13 examples pass `mtc check`.

## 6. Lowering — Tree-Based with Lowerer-Local Type Tracking

**Design decision**: Type tracking lives in the lowerer, not in sema. All declaration information is available from the parsed AST.

### 6.1 Architecture

| Component | Purpose |
|---|---|
| `type_pool` (4 KB buffer) | Stable storage for type strings. Fixes dangling-str bug |
| `build_type_maps` | Pre-pass scans declarations, builds func/method/struct lookup tables |
| `scope_enter/leave/bind/lookup` | Stack of local variable name→C-type mappings |
| `self_infer_expr_type` | Bottom-up type inference: literals, identifiers, calls, member_access |
| `self_expr_is_mt_str` | mt_str detection for `==`/`!=` operators |
| `self_infer_receiver_type` | Resolves receiver types for member access chains |
| `struct_field_lookup` | Looks up struct field C types |
| `self_is_string_field_name` | Heuristic for common string-type field names |
| `self_is_str_vec_field` | Detects known `vec.Vec[str]` fields on `this` |
| `self_is_builtin_call` | Whitelist prevents module prefix on builtin names |

### 6.2 Phases Applied

| Phase | Changes |
|---|---|
| **Phase 1** | Forward declarations for methods/functions, callee name mangling (`this.method` → `module_Type_method`) |
| **Phase 2** | `mt_vec` helpers, builtins (`fatal`, `read`, `ref_of`, `ptr_of`, `const_ptr_of`), struct ctor detection with uppercase check, Vec type mapping (`mt_vec` not `void*`) |
| **Phase 3** | `MT_STR` macro, `mt_str_eq` helper, scope tracking, `build_type_maps`, `self_infer_expr_type`, member access field lookup, `read()` typed deref via `current_return_type` |
| **Phase 3b** | `await_expr` delegation in type inference, `read()` bug fix (removed `or cast_type == ""` fallback), Vec.get() detection restructured outside `this`-block, `self_is_str_vec_field` + str Vec element typing (`sizeof(mt_str)`, `(mt_str*)` cast) |

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

## 10. Error Reduction Progress

| Stage | Errors | Key Change |
|---|---|---|
| **Original (5a)** | **795** | `auto` everywhere, no type tracking |
| Phase 1: Fwd decls + name mangling | 711 | Method fwd decls, callee name mangling |
| Phase 2: Builtins + Vec + struct ctors | 589 | `mt_vec` helpers, builtins, struct ctor detection |
| Phase 3: Strings + scope + lookup tables | 448 | `MT_STR`, `mt_str_eq`, scope tracking, `build_type_maps` |
| **Current (committed)** | **455** | await_expr fix, read() bug fix, Vec.get() str typing, method_lookup_ret fixed |

**Total reduction: 795 → 455 (-42.8%)**

### What's Working (Verified in Generated C)

`method_lookup_ret` now generates correct C:
```c
mt_str* rp = (mt_str*)mt_vec_get_impl(&(this->method_lookup_receivers), i, sizeof(mt_str));
mt_str r = (*(mt_str*)rp);
if (mt_str_eq(r, receiver_type)) {    // ← was: (r == receiver_type)
```

The lookup functions (`method_lookup_ret`, `func_lookup_ret`, `scope_lookup`, `struct_field_lookup`) now use `sizeof(mt_str)` for str-typed Vec elements and `mt_str_eq` for internal str comparisons.

### Remaining Error Categories (~455)

| Count | Category | Root Cause |
|---|---|---|
| ~36 | `mt_str == mt_str` | `this.method()` calls in parser/checker still unresolved (method lookup for those specific methods returns "") |
| ~43 | `void value not ignored` | Vec.get() on non-str Vecs uses `sizeof(void*)` with no cast — wrong for value-type elements |
| ~21 | `char*` init from int | Type mismatch in initialization |
| ~13 | pline type mismatch | String types not detected for some expressions |
| ~11 | expected `?` token | Edge case in generated C |
| ~8 | `SymbolKind` undeclared | Cross-module enum not forward-declared |
| ~323 | Other cascade failures | `auto` pollution from initial type inference gaps |

## 11. Proven & Disproven Approaches

### 11.1 Vec.get() Type Inference for str Fields (PROVEN — applied)

`self_is_str_vec_field` + `mt_str*` return + `sizeof(mt_str)` + `(mt_str*)` cast. Fixed `method_lookup_ret` to generate correct C. **But**: only covers known str-typed Vec fields on `this` — does not generalize.

### 11.2 await_expr Delegation (PROVEN — applied)

Parser creates `ExprKind.await_expr` for `unsafe: expr`. Without delegation in `self_infer_expr_type` and `self_expr_is_mt_str`, ALL read() type inference fails. Fix: `self_infer_expr_type(e.left)` for `await_expr` kind.

### 11.3 read() Builtin Wrong Cast (PROVEN — fixed)

`self_write_builtin_read` used `current_return_type` (function's return type, e.g., `"mt_str"`) as cast for ALL pointers. This caused `*(mt_str*)expr_ptr` instead of `*(nodes_Expr*)expr_ptr`, garbling all data in type inference functions. Fix: removed `or cast_type == ""` from fallback condition.

### 11.4 Vec.get() Detection Inside `this`-Block (PROVEN — fixed)

Vec.get() type inference was inside `if receiver_expr.name == "this"` block, unreachable for `this.field.get(i)` (receiver is `member_access`, not `identifier`). Fix: moved check outside the block.

### 11.5 Vec Element Type Tracking (PROVEN — 469→363, needs re-implementation)

Full vec_elem_lookup infrastructure with cross-module pre-scan achieved -22.6% error reduction. Lost in git revert. The `self_is_str_vec_field` approach is a limited subset for str Vecs only.

### 11.6 Cross-Module Global Type Maps (MIXED — needed for full coverage)

Pre-scan + `set_global_type_maps` merges type tables from all modules. Without it, cross-module Vec fields (e.g., `nodes_Expr.args`) cannot be typed. The approach is correct but needs re-implementation alongside vec_elem_lookup.

## 12. Resumption Plan (ordered by impact)

### Step 1: Re-add Full Vec Element Type Tracking (~80 lines in lower.mt)

Extend `self_is_str_vec_field` to the generic `vec_elem_lookup` approach:
```
A. Add vec_elem_structs/fields/types vectors to Lowerer struct
B. Extend build_type_maps: for struct fields with Vec type, extract inner element type
C. Add vec_elem_lookup(struct_cname, field_name)
D. Add self_vec_elem_type(recv_expr) helper
E. Update self_write_vec_method ".get()": use elem type for cast + sizeof
F. Update self_infer_expr_type ".get()": return elem_type* via pool_type
```

### Step 2: Extend await_expr Coverage (~10 lines)

Add `await_expr` delegation to `self_expr_is_mt_str` (currently only in `self_infer_expr_type`). This catches mt_str comparisons for `unsafe: expr` patterns in the binary op detection fallback path.

### Step 3: Heap Allocation Lowering (~15 lines)

Add `heap.must_alloc[T]` and `heap.alloc[T]` lowering in `self_try_write_builtin`:
```c
(T*)malloc(sizeof(T) * n)     // alloc
(T*)malloc(sizeof(T) * n) with null→fatal check  // must_alloc
```

### Step 4: Combine Pre-scan (~30 lines in main.mt + lower.mt)

Re-add the pre-scan flow that builds global type maps from all files before any lowering. Required for cross-module Vec element type lookup.

### Step 5: True Self-Host

After steps 1-4, errors should be ~200-250. Test `gcc -o mtc_selfhost /tmp/mtc.c`.

## 13. Other Items

### Std Library Review

All 9 reviewed modules (`vec.mt`, `map.mt`, `deque.mt`, `option.mt`, `result.mt`, `string.mt`, `str.mt`, `mem/heap.mt`, `mem/arena.mt`) are substantially complete and correct. One bug fixed: `std/vec.mt:353` — `order[T](read(ptr), ...)` changed to `order[T](ptr, ...)` to match spec (rvalue → pointer).

### Git State

Commit `f21d8847` has all 5 Phase 3b fixes. Commit `957f84ac` is the earlier checkpoint. The file `lower.mt` is at 1727 lines.

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
for f in examples/*.mt src/mtc/**/*.mt src/main.mt; do
    ./build/bin/linux/debug/mtc check "$f" 2>&1 | tail -1
done
```
