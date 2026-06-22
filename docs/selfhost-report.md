# Milk Tea Self-Hosting Compiler — Status Report

## 1. Project Overview

The `projects/mtc` directory contains a self-hosting Milk Tea compiler written in Milk Tea. It compiles to C using the existing Ruby `mtc` compiler and provides `lex`, `parse`, `check`, `lower`, and `combine` subcommands.

**Total**: ~5,863 lines across 9 source files. lower.mt: 1727 → 2250 (+523).

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
        │   └── parser.mt                # 1225 lines — Recursive descent + tree AST (+4)
        ├── ast/
        │   └── nodes.mt                 # 163 lines — AST structs + enum kinds
        ├── sema/
        │   ├── symbol.mt                # 254 lines — SymbolKind, SemaContext
        │   ├── checker.mt               # 271 lines — 3-pass check
        │   └── loader.mt                # 97 lines — Module loader
        └── lowering/
            └── lower.mt                 # 2250 lines — Tree-based C lowering (+523)
```

## 3. Lexer — Complete

Token-for-token match with Ruby lexer. 122 member `TokenKind` enum, byte-scanning with full escape validation, indentation tracking.

## 4. Parser — Complete (Tree AST)

Recursive-descent with tree AST. Heap-allocated nodes.

**Key finding**: The parser creates `ExprKind.await_expr` for `unsafe: expr` in expression position (line 987 of parser.mt). This is critical for type inference — `self_infer_expr_type` must delegate through `await_expr` to reach the inner call expression.

### Bugs discovered and fixed

| Bug | Lines | Impact |
|---|---|---|
| `parse_unary` lexeme after match | `parser.mt:837` | `tok_lexeme()` called after `match_kind()` advanced, reading next token's lexeme. `not expr` stored `"this"` instead of `"not"`. |
| `unsafe: expr` body dropped | `parser.mt:1140` | `parse_expression()` parsed but result dropped. `body = null` → lowerer emitted `/* defer/unsafe */`. Fixed: stored in `expr` field. |
| `else if` inner IF dropped | `parser.mt:1062` | `this.parse_statement()` parsed but result dropped. ALL `else if` chains broken — `build_type_maps` had only 18 lines instead of 851. Fixed: captures result in a Block. |
| Match arm body dropped | `parser.mt:1196` | `this.parse_block()` parsed but result dropped. Match arm bodies empty. Fixed: stores block in `body` field. |

## 5. Semantic Analysis — Complete

Two-level symbol table. 40 built-in types. Module loading with cycle detection.

**Verification**: 9/9 self-host files build via Ruby compiler. Self-host checker has limits on lower.mt field count.

## 6. Lowering — Tree-Based with Lowerer-Local Type Tracking

**Design decision**: Type tracking lives in the lowerer, not in sema. All declaration information is available from the parsed AST.

### 6.1 Architecture

| Component | Purpose |
|---|---|
| `type_pool` (32 KB buffer) | Stable storage for type strings. Fixes dangling-str bug |
| `build_type_maps` | Pre-pass scans declarations, builds func/method/struct lookup tables. Now also populates global cross-module maps and Vec element types. |
| `scope_enter/leave/bind/lookup` | Stack of local variable name→C-type mappings. Now includes Vec element types (`scope_bind_vec`, `scope_lookup_vec_elem`). |
| `self_infer_expr_type` | Bottom-up type inference for literals, identifiers, calls, member_access. Now handles static method returns and Vec.get() element types. |
| `self_expr_is_mt_str` | mt_str detection for `==`/`!=` operators. Delegates through await_expr nodes. |
| `self_infer_receiver_type` | Resolves receiver types for member access chains |
| `struct_field_lookup` | Looks up struct field C types |
| `self_is_str_vec_field` | Hardcoded list of known `vec.Vec[str]` fields. Extended to cover global_type_names, global_vec_*, etc. |
| `self_vec_elem_type` | Standalone function combining hardcoded str-vec check with global cross-module Vec element type lookup via scope. |
| `global_vec_elem_lookup` | Searches cross-module Vec element type arrays (populated by pre-scan) |
| `copy_global_maps_from` | Merges type maps from another lowerer instance. **Fixed**: uses `pool_type` for ALL arrays to prevent dangling str pointers. |
| `global_type_names/mods` | Cross-module type→module mapping for identifier prefixing |
| `str_buffer lowering` | `this.out_buf.append(x)` → `mt_strbuf_append_impl(x, buf.data, sizeof(buf.data)-1, &buf.len, &buf.dirty)` — capacity via `sizeof` |
| `str lowering` | `str.byte_at(pos)` → `(receiver).data[pos]` |
| `heap alloc lowering` | `heap.alloc[T](n)` → `((T*)malloc(sizeof(T) * n))` |
| Method call for locals | `temp_lr.method(args)` → `lower_Lowerer_method(&temp_lr, args)` |

### 6.2 Phases Applied

| Phase | Changes |
|---|---|
| **Phase 1** | Forward declarations for methods/functions, callee name mangling |
| **Phase 2** | `mt_vec` helpers, builtins, struct ctor detection, Vec type mapping |
| **Phase 3** | `MT_STR` macro, `mt_str_eq` helper, scope tracking, `build_type_maps`, type inference |
| **Phase 3b** | `await_expr` delegation, `read()` bug fix, Vec.get() str typing |
| **Phase 4** | Pre-scan, global type maps, Vec element tracking, heap lowering, 8 parser/lowerer bugs, strbuf lowering, str lowering, method call for locals |

### 6.3 Lowering bugs discovered and fixed

| Bug | Lines | Impact |
|---|---|---|
| `self_write_var` missing type inference | `lower.mt:768` | `var x = ""` produced untyped `auto` — no scope binding, no mt_str detection. **-118 errors**. |
| Struct ctor over-broad detection | `lower.mt:2156` | `lower.Lowerer.create()` treated as struct ctor. Fixed: outermost name must also be uppercase. |
| Vec method over-broad detection | `lower.mt:1197` | `Type.create()` intercepted as `Vec.create()` → `((mt_vec){0})`. Fixed: check if receiver chain starts with uppercase. |
| String pool dangling pointers | `lower.mt:1941` | `copy_global_maps_from` pushed raw str pointers without `pool_type`. Strings from freed temp_lr became dangling. Fixed: `pool_type` for all array pushes. |

## 7. Ruby Compiler Fixes

Enum comparison operators, cycle detection in lowering. (No changes.)

## 8. CLI Commands

```
mtc lex <file>        — Token stream (--json)
mtc parse <file>      — AST (--json)
mtc check <file>      — Semantic analysis
mtc lower <file>      — C lowering
mtc combine <files..> — Combined C lowering (TWO-PASS: pre-scan → lower)
```

## 9. Verification

| Category | Count | Errors |
|----------|-------|--------|
| Build (via Ruby mtc) | 9 | 0 — all build successfully |
| Self-host checker | 9 | 7 pass (lower.mt field count, nodes.mt module resolution) |

## 10. Error Reduction Progress

| Stage | Errors | Key Change |
|---|---|---|
| **Original (5a)** | **795** | `auto` everywhere, no type tracking |
| Phase 1: Fwd decls + name mangling | 711 | Method fwd decls, callee mangling |
| Phase 2: Builtins + Vec + struct ctors | 589 | `mt_vec`, builtins, struct ctor detection |
| Phase 3: Strings + scope + lookup tables | 448 | `MT_STR`, `mt_str_eq`, scope, type maps |
| Phase 3b: Bug fixes | 455 | await_expr, read() bug, Vec.get() str typing |
| **Phase 4a (committed)** | **329** | Pre-scan, vec elem, heap, var inference |
| **Phase 4b (current)** | **301** | 8 parser fixes, strbuf, str, pool_type, method call, else-if |

**Total reduction: 795 → 301 (-62.1%)**

### 10.1 What's Working (Verified in Generated C)

Str_buffer method calls:
```c
// Before:
/* defer/unsafe */

// After:
mt_strbuf_append_impl(search_root, buf.data, sizeof(buf.data)-1, &buf.len, &buf.dirty);
MT_STRBUF_AS(path_buf)                                       // as_str()
```

Vec.get() with proper element types:
```c
// Before:
auto t = mt_vec_get_impl(&(this->tokens), pos, sizeof(void*));

// After:
token_Token* t = (token_Token*)mt_vec_get_impl(&(this->tokens), pos, sizeof(token_Token));
```

Heap allocation:
```c
// Before:
auto tp = heap.must_alloc[nodes_Type](1);

// After:
auto tp = ((nodes_Type*)malloc(sizeof(nodes_Type) * 1));
```

Method calls on typed local variables:
```c
// Before:
temp_lr_build_type_maps(ast);       // undeclared function

// After:
lower_Lowerer_build_type_maps(&temp_lr, ast);  // correct mangling
```

### 10.2 Remaining Error Categories (~301)

| Count | Category | Root Cause |
|---|---|---|
| 24 | `char*` init from int | Type mismatch in initialization (auto pollution) |
| 11 | `void value not ignored` | Vec.get() on local vars from unknown sources |
| 8 | `SymbolKind` undeclared | Identifier handler fallback not triggering (str comparison issue) |
| 8 | too few args to `*_create` | Static method calls missing `this`/`&var` first arg |
| ~250 | Cascade failures | `auto` cascading from initial type gaps |

## 11. Resumption Plan — Updated

### Completed

- [x] Step 1: Re-add Full Vec Element Type Tracking
- [x] Step 2: Extend await_expr Coverage
- [x] Step 3: Heap Allocation Lowering
- [x] Step 4: Combine Pre-scan for Global Type Maps
- [x] Step 5: Extend Vec Element Tracking to Local Variables
- [x] Plus: 8 parser bugs fixed (parse_unary, unsafe, else-if, match arm)
- [x] Plus: 4 lowerer bugs fixed (var inference, struct ctor, vec method, pool_type)
- [x] Plus: str_buffer lowering (mt_strbuf_*_impl)
- [x] Plus: str method lowering (byte_at → data[pos])
- [x] Plus: Method call mangling for typed local variables

### Next Steps

#### Step 6: Fix Static Method Calling Convention

`lexer.Lexer.create(source)` produces `lexer_Lexer_create(source)` but function expects `lexer_Lexer_create(&result, source)`. Static method calls need `&varName` as first argument when used as initializer. See `self_write_method_call` fix already partially applied — needs refinement for the `create` return pattern.

#### Step 7: Fix SymbolKind (and cross-module enums)

Hardcoded fallback is in `lower.mt:925-927`:
```mt
if tpname == "SymbolKind" and this.module_name != "symbol":
    unsafe: this.out_buf.append("symbol_")
```
The fallback code is correctly generated in the lowerer's C output but the str comparison `tpname == "SymbolKind"` may fail at runtime. Investigate whether `mt_str_eq` works correctly in the selfhost binary. Estimated: -8 errors.

#### Step 8: True Self-Host

After steps 6-7, errors should be ~250-280. Test `gcc -o mtc_selfhost /tmp/mtc.c`.

## 12. Test Commands

```sh
# Build
cd projects/mtc && ../../bin/mtc build . --no-cache

# Native combine + GCC
./build/bin/linux/debug/mtc combine \
  src/mtc/ast/nodes.mt src/mtc/lexer/token.mt src/mtc/lexer/lexer.mt \
  src/mtc/parser/parser.mt src/mtc/sema/symbol.mt src/mtc/sema/loader.mt \
  src/mtc/sema/checker.mt src/mtc/lowering/lower.mt src/main.mt \
  > /tmp/mtc.c && gcc -fsyntax-only -x c /tmp/mtc.c 2>&1 | grep -c "error:"
```
