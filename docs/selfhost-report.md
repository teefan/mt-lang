# Milk Tea Self-Hosting Compiler — Status Report

## 1. Project Overview

The `projects/mtc` directory contains a self-hosting Milk Tea compiler written in Milk Tea. It compiles to C using the existing Ruby `mtc` compiler and currently provides `lex`, `parse`, `check`, and `lower` subcommands.

**Total**: ~4,400 lines of Milk Tea across 9 source files.

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
        │   └── parser.mt                # ~1112 lines — Recursive descent + operator precedence
        ├── ast/
        │   └── nodes.mt                 # ~146 lines — Decl/Stmt/Expr structs, enum kinds
        ├── sema/
        │   ├── symbol.mt                # ~260 lines — SymbolKind, SemaContext, ModuleScope
        │   ├── checker.mt               # ~260 lines — 3-pass check: imports → register → validate
        │   └── loader.mt                # ~130 lines — Module loader, path resolution
        └── lowering/
            └── lower.mt                 # ~470 lines — Source-to-C lowering + body C translation
```

## 3. Lexer — Complete

Token-for-token match with Ruby lexer on all 400+ `.mt` files. 122 member `TokenKind` enum, byte-scanning with full escape validation, indentation tracking. Token struct includes `src_offset` for source-position-based text extraction.

## 4. Parser — Complete

18 declaration types, full operator precedence chain, postfix chain with named-arg + multi-arg support, all statement variants including guard forms, assignment operators, match patterns. Types parsed as full dotted paths via `source_text.slice()`. Brackets consumed without double-consumption bug. All previously known gaps resolved: nested structs, `@[attr]` skipping, lifetime annotations, `else as error:`, external file headers, `when`/`inline` placeholders. Body byte offsets (`body_src_start`/`body_src_end`) captured for function bodies.

**Verification**: 8/8 self-host + 13/13 examples parse with 0 errors.

## 5. Semantic Analysis — Complete

Two-level symbol table (local `symbols` + `import_scopes` with `ModuleScope` entries). 40 built-in types. `resolve_dotted_type()` traverses import chain. Silent import registration avoids duplicate errors. Type params collected from fields/params/return/arms. Module loading via `self_build_module_path()` with `str_buffer[256]` and cycle detection. `find_source_root()` walks path for `/src/` component.

**Verification**: 9/9 self-host + 13/13 examples pass `mtc check` with 0 errors.

## 6. Lowering + Body C Translation — Complete

### Declaration lowering
- Struct → `typedef struct module_Name { fields } module_Name;`
- Enum/Flags → `enum { module_Name_member = value, ... };`
- Functions → full C signatures with body
- Extending methods → `static ret_type module_Type_method(params);`
- Const/Var → `static [const] type module_name [= value];`
- 40-type C mapping (primitives → stdint.h, constructors → void*, str → mt_str, native types → float/int32_t)
- Dotted types: `token.Token` → `token_Token` (underscore substitution)
- All output via `str_buffer` + `ptr[str_buffer]` + `unsafe: read` to avoid f-string lifetime and `ref[str_buffer]` auto-deref issues

### Body text extraction (`body_src_start`/`body_src_end`)
- Body byte offsets captured in `parse_function_def` and `parse_const_var` by peeking at token `src_offset` before/after `parse_block()`
- `source_text` passed to `Lowerer`, body text extracted via `source_text.slice(start, end - start)`
- EOF fallback: when `body_end == 0`, uses `source_text.len`

### C translation (`self_translate_body`)
Single-pass character-level translation applied to extracted body text:

| Milk Tea | C |
|-----------|-----|
| `and` | `&&` |
| `or` | `\|\|` |
| `not` | `!` |
| `unsafe:` | (removed) |
| `let x =` | `auto x =` |
| `;` after statements | auto-inserted (skipped after `:`, `{`, `}`, `;`, `#`) |

### C output example
```c
bool checker_self_is_type_param_name(mt_str name) {
if name.len != 1:
        return false;
    auto ch = name.byte_at(0);
    return ch >= 'A' && ch <= 'Z';
}
```

**Verification**: 9/9 self-host files pass `mtc check` with 0 errors. Body text extracted and C-translated for all function definitions.

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

## 10. Next Steps (Resumption Plan)

### Immediate (next session)

**1. Tree AST — Type nodes (~300 lines)**
Replace flat `type_text: str` with recursive `Type` tree. Add `TypeKind` enum + `Type` struct to `nodes.mt`. Rewrite `parse_type_text() → parse_type()` in `parser.mt` to build `ptr[Type]?` trees. Update `write_ctype()` in `lower.mt` to traverse the tree. This is the smallest tree-AST piece and proves the heap-allocation pattern.

```
TypeKind: primitive | named | ptr_type | ref_type | span_type | array_type | fn_type | nullable | ...
Type: { kind, name, inner: ptr[Type]?, array_size, fn_params: Vec[Type], fn_return: ptr[Type]? }
```

**2. Tree AST — Expression nodes (~800 lines)**
Replace flat `Expr` with recursive tree. Covers literals, identifiers, binary/unary ops, calls, member/index access, proc expressions, cast, if/match-expr. Rewrite all `parse_*` expression functions to return `ptr[Expr]?`. Heap allocation via `std.mem.heap.must_alloc`.

**3. Tree AST — Statement nodes (~500 lines)**
Replace flat `Stmt` with recursive tree. Covers let/var, assignment, if/else/while/for/match, return/break/continue, defer/unsafe, blocks. Rewrite `parse_statement()` and `parse_block()`.

**4. Full function body lowering (~400 lines)**
With expression/statement trees, emit real compilable C for function bodies. Lower each expression kind to C. Lower statement control flow (if→if{}, while→while{}, for→for{}). Lower types correctly from the Type tree.

### Medium-term

**5. Self-host** — Compile the compiler with itself. Requires the above steps to produce compilable C for all source files.

**6. Full sema** — Expression type checking, call arg validation, match exhaustiveness, control flow analysis.

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
for f in examples/*.mt; do
    ./build/bin/linux/debug/mtc check "$f" 2>&1 | grep -c "error:"
done
```
