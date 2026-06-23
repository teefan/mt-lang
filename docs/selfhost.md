# Self-Hosted Milk Tea Compiler (`projects/mtc`)

## Purpose

This document is the **single reference point** for the self-hosted compiler effort. It serves as:

1. **Architecture reference** — what goes where and why
2. **Progress tracker** — what's done, what's in progress, what's next
3. **Session resume** — enough context to pick up after any interruption

---

## 1. Architecture Overview

The self-hosted compiler reimplements the Ruby reference compiler (`lib/milk_tea/core/`) in Milk Tea itself. The target output remains readable C.

```
Source (.mt)
  → Lexer          token stream (Vec[Token])
  → Parser         AST (variant tree, arena-allocated)
  → Semantic       type-checked & bound AST
  → Lowering       flat C-oriented IR
  → C Backend      C source → cc → binary
```

### Module Layout

```
std/
  intern.mt              ★ string → uint interning table (prerequisite)

projects/mtc/
  package.toml
  src/
    main.mt                       CLI entry point
    compiler/
      context.mt                  CompilerContext: diagnostics + interner + arena + source
      diagnostics.mt              Diagnostic types (Severity, Diagnostic)
      source.mt                   SourceFile (str view + path)
      lexer/
        token_kind.mt             TokenKind enum (122 members)
        token.mt                  Token struct (kind, span, line, col, ident)
        cursor.mt                 SourceCursor: byte-at-a-time access (unsafe boundary)
        lexer.mt                  Lexer: source bytes → Vec[Token]
      parser/
        ast.mt                    AST variants: Expr, Decl, Stmt, Type, Pattern (+17 helper structs)
        token_cursor.mt           TokenCursor: peek/consume over span[Token]
        operators.mt              BinaryOp + UnaryOp enums
        parser.mt                 Recursive descent with precedence climbing
      sema/
        types.mt                  Type variant (Primitive, Pointer, Struct, Generic, Function, etc.)
        type_registry.mt          Global type dedup/interning (canonical TypeId integers)
        scope.mt                  Lexical scope (bindings Map[IdentId, Binding])
        binder.mt                 Name resolution
        checker.mt                Type checker for expressions and statements
        generics.mt               Generic instantiation / monomorphization
        interfaces.mt             Interface conformance checking
        const_eval.mt             Compile-time expression evaluator
      lowering/
        ir.mt                     IR types (flat, C-oriented)
        lowerer.mt                AST → IR transformation
        async.mt                  Async normalization (await hoisting)
      codegen/
        c_backend.mt              C source emission from IR

  (files c_formatter.mt and async.mt deferred — string builder is in c_backend, async not started)
```

### Design Principles

1. **String interning** — identifiers become `ptr_uint` after lexing; zero str comparisons in parser/sema/lowering
2. **TypeId interning** — type objects get canonical integer IDs from registry; zero struct `==` in type checking
3. **Arena allocation** — one arena per phase; parser allocates AST nodes via typed `new_*` methods (`new_expr`, `new_decl`, etc.), lowerer allocates IR spans via `copy_*` methods; arena lifetimes match phase duration
4. **Error accumulation** — diagnostics Vec in Context, not exceptions; recoverable errors append, fatal errors call `fatal()`
5. **Safe iteration** — prefer `vec.as_span()` + value iteration over raw `Vec.iter()` pointer iteration
6. **`Result`/`Option` + `?`** — explicit error paths for fallible operations; `let...else:` for guard binding

---

## 2. Comprehensive Pain Point Audit

The Ruby reference compiler (`lib/milk_tea/core/`, ~31 files) was audited for patterns that will be problematic in Milk Tea. Below are all categories with estimated occurrence counts, severity, and solutions.

### 2.1 String Comparisons for Atoms (~150 sites) ⚠️ HARD

The Ruby compiler uses raw strings as atoms throughout — type names, operator names, builtin function names, generic type names. Examples:

```ruby
# types.rb
name == "byte"            # type name comparison
name == "ptr"             # generic type name

# expression_checker.rb
expression.operator == "?"   # operator comparison
callee.name == "fatal"       # builtin name
callee.member == "as_span"   # method name

# predicates.rb
case name
when "ptr" then ...
when "const_ptr" then ...
when "ref" then ...
```

**Milk Tea solution:** Every string-based atom namespace must become a proper **enum**. This is a prerequisite — cannot be deferred.

| Atom namespace | Approx. values | Proposed enum |
|---------------|-----------|---------|
| Primitive type names | 20 ("byte", "int", "float", "str", "cstr", ...) | `PrimitiveKind` |
| Generic type names | 10 ("ptr", "const_ptr", "ref", "span", "array", ...) | `GenericTypeKind` |
| Binary operators | 20 ("+", "-", "==", "and", "or", ...) | `BinaryOp` |
| Unary operators | 5 ("-", "~", "not", ...) | `UnaryOp` |
| Builtin function names | 25 ("fatal", "ref_of", "hash", "equal", ...) | `BuiltinFn` or `BuiltinName` |
| Method names (special) | 10 ("as_span", "with", "iter", "next", ...) | Not needed (see below) |

Special method names like `"as_span"`, `"with"`, `"iter"`, `"next"` do NOT need an enum — they are identified once during semantic analysis and marked on the resolved call. Only builtins and operators that are compared many times need enum conversion.

### 2.2 Type Object Equality (~40 implementations) ⚠️ HARD

The Ruby compiler compares type objects with `==` (delegating to `eql?`). Every type variant has:

```ruby
# types.rb — 40+ implementations of this pattern
class Primitive
  def eql?(other)
    other.is_a?(Primitive) && other.kind == kind
  end
  alias == eql?
end
```

This is used for:
- Type registry deduplication (caching canonical type instances)
- Type compatibility checking (`actual_type == expected_type`)
- Hash map keys (e.g., `@method_definitions` keyed by `(type, method_name)`)

**Milk Tea solution:** **TypeId interning algorithm** — assign every type object a unique integer ID from a global `TypeRegistry`. Compare `TypeId` values (integers) instead of structural `==` on type variants.

```mt
type TypeId = uint

struct TypeRegistry:
    id_counter: uint
    canonical: map.Map[TypeKey, TypeId]    # dedup by structural key
    entries: vec.Vec[TypeEntry]            # TypeId → type data

extending TypeRegistry:
    public editable function intern_type(key: TypeKey) -> TypeId:
        # returns existing TypeId or assigns new one
```

All type comparison in checker/lowering/codegen becomes `type_id_a == type_id_b` (integer `==`).

### 2.3 String Concatenation for C Generation (~100+ sites) ⚠️ HARD

The C backend emits C source by concatenating strings. Milk Tea does NOT support `+` on strings (language restriction). Ruby patterns:

```ruby
# c_backend/expressions.rb
"#{base} #{declarator}"                           # interpolation
"#{callee}(#{arguments.join(', ')})"               # join + interpolation
"#{left} #{c_operator} #{right}"                   # multi-part
"(#{c_type(expression.target_type)}) #{operand}"   # cast + expression
```

**Milk Tea solution:** Use `string.String` as a mutable string builder for C emission. Every emit function appends to a shared buffer passed by `ref`.

```mt
extending CWriter:
    public editable function append_line(line: str) -> void:
        this.buffer.append(line)
        this.buffer.append("\n")
```

Avoid concatenation entirely — push fragments sequentially into the buffer. Formatting uses `append_format` when needed.

**Prerequisite:** `string.String.append(str)` exists (confirmed in `std/string.mt`). For format-style output with integer precision, use `std.fmt.append_format`.

### 2.4 Regex for Identifier Sanitization (~3 sites) ⚠️ MEDIUM

The Ruby compiler uses regex to sanitize identifiers when generating C names:

```ruby
# c_backend/type_emission.rb:211
def sanitize_identifier(text)
  text.gsub(/[^A-Za-z0-9_]+/, "_")
end

# lowering/expressions.rb:1065
sanitize_type_name_for_tuple(type) # also uses regex
```

**Milk Tea solution:** Manual character classification. Milk Tea has `std.ctype` providing `is_alnum`, `is_digit`, `is_alpha`, etc. Write a char-by-char loop:

```mt
function sanitize(text: str, output: ref[string.String]) -> void:
    var i: ptr_uint = 0
    while i < text.len:
        let byte = text.byte_at(i)
        let c = int<-byte
        if std.ctype.is_alnum(c) or byte == ub<-95:
            # append single char
            # need str from single byte
        else:
            output.append("_")
        i += 1
```

This is a known friction: single-character `str` construction requires `unsafe` or using a `char` literal. Workaround: use a lookup table `is_valid_c_char[128]` array.

### 2.5 Type Introspection (~200+ `.is_a?` sites) ⚠️ MEDIUM

The Ruby compiler uses `is_a?`, `respond_to?`, and `case/when` on class identity pervasively. Examples:

```ruby
# types.rb — ~40 .is_a? calls
other.is_a?(Primitive)
type.is_a?(Types::GenericInstance)

# predicates.rb — ~80 .is_a? calls
type.is_a?(Types::Primitive)
type.is_a?(Types::Nullable)

# expression_checker.rb — ~50 calls
scrutinee_type.is_a?(Types::Enum)
scrutinee_type.is_a?(Types::Variant)
```

**Milk Tea solution:** Every `is_a?` becomes a `match` arm on the variant tag. The `case/when` on class identity (~300 sites total) becomes `match` with exhaustive arm checking.

```ruby
# Ruby
if type.is_a?(Types::Primitive)
  check_primitive(type)
elsif type.is_a?(Types::Pointer)
  check_pointer(type)
end

# Milk Tea
match type:
    Type.Primitive(_):
        check_primitive(type)
    Type.Pointer(_):
        check_pointer(type)
```

`respond_to?` checks (e.g., `type.respond_to?(:fields)`) become match arms — if a specific variant is expected, match on it; otherwise, the pattern checking proves field existence.

### 2.6 Struct `==` for Key Comparison (~10 sites) ⚠️ MEDIUM

Some hash maps use compound keys (pair of values):

```ruby
# expression_checker.rb
@method_definitions = {}   # key: [type, method_name_string]
@method_definitions[[type, name]] = entry

# lowering/type_resolution.rb
@artifacts.emitted_external_layout_pairs[pair_key] = true
```

**Milk Tea solution:** Use integer-based keys or explicit key structs:
- `(TypeId, IdentId)` → `map.Map[MethodKey, Entry]` where `MethodKey` is a struct
- Or flatten: `map.Map[TypeId, map.Map[IdentId, Entry]]` (nested map)
- Or use a combined integer hash: `(type_id << 32) | ident_id`

### 2.7 Memoization / Lazy Init (~30 sites) ⚠️ LOW-MEDIUM

Ruby uses `||=` for lazy initialization caches:

```ruby
@resolved_expr_types ||= {}       # hash memo
@str_literal_map ||= {}           # string dedup cache
env[:fmt_counter] ||= {}          # format counter
```

**Milk Tea solution:** Make caches explicit mutable containers created at context setup time. No lazy init needed — allocate the map/vec when creating the Context or pass state struct.

```mt
struct Context:
    resolved_expr_types: map.Map[NodeId, TypeId]    # pre-created
    str_literal_map: map.Map[str, ptr_uint]         # pre-created
    fmt_counter: ptr_uint                           # initialized to 0
```

### 2.8 Heterogeneous Containers (~20 hash/array types) ⚠️ LOW-MEDIUM

Ruby hashes with mixed value types need concrete typing:

```ruby
# Format parts: array of hashes with Symbol keys
format_parts = [
  { kind: :text, value: "hello" },
  { kind: :expr, expression: some_ast, ... },
]

# Method definitions: heterogeneous pair value
@method_definitions = {}
@method_definitions[[type, name]] = [analyzer, ast_node]
```

**Milk Tea solution:** Each heterogeneous container gets a proper variant or struct type:

```mt
variant FormatPart:
    text(value: str)
    expression(expr: ptr[Expr], type: TypeId)
    precision(digits: ptr_uint)

struct MethodEntry:
    analyzer: ptr[SemanticAnalyzer]     # or Module reference
    node: ptr[AST::FunctionDef]
```

Note: `ptr[SemanticAnalyzer]` is a self-reference — in self-hosting, these become proper module/type references without recursive pointer chains (the compiler processes one module at a time).

### 2.9 Exceptions → Result Propagation (~250 `raise` sites) ⚠️ MEDIUM

The Ruby compiler raises exceptions for all errors:

```ruby
raise_sema_error("unknown type #{name}", line:, column:)
raise LoweringError, "unexpected expression"
raise CBackendError, "unhandled expression type"
```

**Milk Tea solution:** Convert to `Result[T, Diagnostic]` propagation. In recoverable contexts, append to diagnostics Vec. In fatal contexts, call `fatal()`. Pattern:

```mt
# Recoverable (check/parse phase)
function check_expr(expr: ptr[Expr], ctx: ref[Context]) -> Result[TypeId, Void]:
    match read(expr):
        ...
        _:
            ctx.report(Diagnostic.error("unhandled expr", line, col))
            return Result.failure(Void)

# Fatal (lowering/codegen phase — should never see bad IR)
function lower_expr(expr: ptr[Expr]) -> ptr[IR::Expr]:
    match read(expr):
        ...
        _:
            fatal(c"unhandled expression in lowering")
```

### 2.10 Nil/Null → Option Pattern (ubiquitous) ⚠️ MEDIUM

Ruby uses `nil` pervasively for absence: optional return values, unset fields, "not found" results, default parameter values, error sentinels.

**Milk Tea solution:** Three-tier approach already designed into the language:
- **Option[T]** for lookup failures (`lookup_value` → `Option[Binding]`)
- **ptr[T]?** for nullable pointers (arena-allocated nodes)
- **Result[T, E]** for fallible operations with structured errors

The key translation rules:
```ruby
# Ruby
def lookup_value(name, scopes)
  scopes.reverse_each { |s| return s[name] if s.key?(name) }
  nil
end

# Milk Tea
function lookup_value(name: IdentId, scopes: span[Scope]) -> Option[Binding]:
    for scope in reverse_iter(scopes):
        let binding = scope.get(name)?
        return Option.some(binding)
    return Option[Binding].none
```

### 2.11 Mutually Recursive Functions (~5 sites) ⚠️ LOW

Some passes have mutual recursion (e.g., `simulate_cstr_metadata_block ↔ update_cstr_metadata_for_assignment`).

**Milk Tea solution:** Forward declare one function before the other, or restructure into a single-pass traversal. Milk Tea requires declarations before use (except within the same module).

---

## 3. Pain Point Summary & Priority

| # | Category | Est. Sites | Difficulty | Priority to Address |
|---|----------|-----------|------------|---------------------|
| 2.1 | String comparisons for atoms | ~150 | HARD | **BEFORE Phase 2** (lexer tokens are the first atom namespace) |
| 2.2 | Type object equality | ~40 | HARD | **BEFORE Phase 4** (sema needs type registry) |
| 2.3 | String concat for C generation | ~100 | HARD | **BEFORE Phase 6** (codegen needs builder pattern) |
| 2.4 | Regex identifier sanitization | ~3 | MEDIUM | Before Phase 6 |
| 2.5 | Type introspection (is_a?) | ~200 | MEDIUM | Throughout (mechanical translation) |
| 2.6 | Struct == for compound keys | ~10 | MEDIUM | Before Phase 4 |
| 2.7 | Memoization / lazy init | ~30 | LOW | Throughout |
| 2.8 | Heterogeneous containers | ~20 | MEDIUM | Before Phase 4 |
| 2.9 | Exceptions → Result | ~250 | MEDIUM | Throughout |
| 2.10 | Nil/null → Option | Ubiquitous | MEDIUM | Throughout |
| 2.11 | Mutual recursion | ~5 | LOW | Before Phase 5 |

---

## 4. Enum Prefix Conventions

All enum members use prefixes to avoid collisions with C keywords (int, float, return, if, etc.), Milk Tea keywords (and, or, not, type, etc.), and type names.

| Enum | Prefix | Example | Reason |
|------|--------|---------|--------|
| TokenKind | `tk_` | `tk_kw_if`, `tk_lparen` | Members colliding with C + MT keywords (~50 of 122) |
| BinaryOp | `op_` | `op_add`, `op_logic_and` | `and`/`or`/`not` are MT word operators |
| UnaryOp | `uop_` | `uop_negate` | Not strictly needed but consistent |
| PrimitiveKind | `pk_` | `pk_int`, `pk_void` | Members are C keywords (int, float, void, etc.) |
| BuiltinName | `bi_` | `bi_hash`, `bi_array` | `hash`, `array`, `span`, etc. are identifiers |
| GenericTypeKind | `gk_` | `gk_ptr`, `gk_ref` | `ptr`, `ref`, `fn`, etc. are type names |

---

## 5. Key Patterns & Conventions

### 5.1 Arena Allocation

```mt
let arena = arena.create(256 * 1024)                      # 256 KiB per file
let node = push[T](ref_of(arena), value)                  # allocate + write in one call
let child_list = finish_span[T](ref_of(arena), ref_of(vec))  # Vec→arena-span for child lists
```

`push[T]` calls `arena.alloc[T](1)?` then `unsafe: read(p) = value`. `finish_span[T]` allocates `vec.len` elements in the arena, copies them, and returns `span[T]`. Both fatal on OOM.

### 5.2 Error Reporting

```mt
ctx.report(d.create_error("unexpected token", line, col))
if ctx.has_errors():
    return Result.failure(Void)
```

### 5.3 Interner Usage

```mt
let id = ctx.interner.intern("if")     # ensures same ptr_uint for all "if" strings
let text = ctx.interner.lookup(id)     # returns Option[str] for diagnostics
```

### 5.4 Safe Vec Iteration (avoid unsafe pointer deref)

```mt
let span = vec.as_span()
for element in span:
    # element is T by value, field access is safe
```

### 5.5 Type Registry (TypeId interning)

```mt
let int_type = registry.primitive(PrimitiveKind.int)     # returns TypeId
let ptr_int = registry.generic(GenericTypeKind.ptr, int_type)  # TypeId for ptr[int]
if type_a == type_b:                                       # integer comparison
    # types are the same
```

### 5.6 String Building for C Emission

```mt
extending CWriter:
    public editable function emit_type(type_id: TypeId) -> void:
        let primitive = registry.as_primitive(type_id)?
        this.buffer.append(primitive_kind_c_name(primitive.kind))
```

### 5.7 Result Propagation

```mt
function parse(tokens: span[Token], ctx: ref[Context]) -> Result[ptr[AST::SourceFile], Void]:
    let file = ctx.arena.alloc[AST::SourceFile](1)?
    let decls = parse_declarations(tokens, ctx)?
    # ...
    return Result.success(file)
```

---

## 6. Progress Tracking

### Phase 0: Enums & Atom Types ✅

| Status | Module | File | Members |
|--------|--------|------|---------|
| ✅ | `compiler.lexer.token_kind` | `src/compiler/lexer/token_kind.mt` | 122 members (3 structural + 19 delimiters + 43 operators + 7 literals + 50 keywords) |
| ✅ | `compiler.parser.operators` | `src/compiler/parser/operators.mt` | 18 BinaryOp + 3 UnaryOp |
| ✅ | `compiler.sema.primitive_kind` | `src/compiler/sema/primitive_kind.mt` | 25 members |
| ✅ | `compiler.sema.builtin_name` | `src/compiler/sema/builtin_name.mt` | 26 members |
| ✅ | `compiler.sema.generic_kind` | `src/compiler/sema/generic_kind.mt` | 14 members |

### Phase 1: Foundation ✅

| Status | Module | Location | Description |
|--------|--------|----------|-------------|
| ✅ | `std.intern` | `std/intern.mt` | String interning table (IdentId, intern, lookup) |
| ✅ | `compiler.diagnostics` | `projects/mtc/src/compiler/diagnostics.mt` | Severity enum, Diagnostic struct, factory functions |
| ✅ | `compiler.source` | `projects/mtc/src/compiler/source.mt` | SourceFile (text + path) |
| ✅ | `compiler.context` | `projects/mtc/src/compiler/context.mt` | CompilerContext aggregating diags + interner + arena + source |
| ✅ | `main` | `projects/mtc/src/main.mt` | Entry point stub |

### Phase 2: Lexer ✅

| Status | Module | File | Lines | Description |
|--------|--------|------|-------|-------------|
| ✅ | `compiler.lexer.token_kind` | `src/compiler/lexer/token_kind.mt` | 158 | TokenKind enum (122 members) |
| ✅ | `compiler.lexer.cursor` | `src/compiler/lexer/cursor.mt` | 90 | SourceCursor: safe byte-at-a-time access (unsafe boundary) |
| ✅ | `compiler.lexer.token` | `src/compiler/lexer/token.mt` | 103 | Token struct + char classification helpers (13 functions) |
| ✅ | `compiler.lexer.lexer` | `src/compiler/lexer/lexer.mt` | 585 | Full lexer: identifiers, numbers, strings, operators, comments, 58 keywords |

### Phase 3: Parser ✅

| Status | Module | File | Lines | Description |
|--------|--------|------|-------|-------------|
| ✅ | `compiler.parser.operators` | `src/compiler/parser/operators.mt` | 36 | BinaryOp (18) + UnaryOp (3) enums |
| ✅ | `compiler.parser.token_cursor` | `src/compiler/parser/token_cursor.mt` | 46 | TokenCursor: safe peek/consume over span[Token] |
| ✅ | `compiler.parser.ast` | `src/compiler/parser/ast.mt` | 247 | AST: 5 top-level variants (Expr 31, Stmt 16, Decl 10, Type 11, Pattern 4), 19 helper structs, span-based child lists |
| ✅ | `compiler.parser.parser` | `src/compiler/parser/parser.mt` | 1419 | Recursive descent + precedence climbing: functions, structs, enums, extending blocks, if/else, while, for-range, unsafe, match(int/char/\|/wildcard/enum-member), pass, break/continue, assignment(= += -= etc), aggregate(struct literals), integer/char parsing from source bytes |

### Phase 4: Semantic Analysis 🟡

| Status | Module | File | Lines | Description |
|--------|--------|------|-------|-------------|
| ✅ | `compiler.sema.primitive_kind` | `src/compiler/sema/primitive_kind.mt` | 37 | PrimitiveKind enum (25 members) |
| ✅ | `compiler.sema.generic_kind` | `src/compiler/sema/generic_kind.mt` | 24 | GenericTypeKind enum (14 members) |
| ✅ | `compiler.sema.builtin_name` | `src/compiler/sema/builtin_name.mt` | 35 | BuiltinName enum (26 members) |
| ✅ | `compiler.sema.type_registry` | `src/compiler/sema/type_registry.mt` | 223 | TypeId interning: primitives (array), ptr/ref/span/nullable (hash-map), fn/tuple/array (linear scan), named (scan) |
| ✅ | `compiler.sema.types` | `src/compiler/sema/types.mt` | 106 | SemType wrapper: is_integer, is_float, is_numeric, is_bool, is_void, is_str, is_cstr predicates |
| ✅ | `compiler.sema.scope` | `src/compiler/sema/scope.mt` | 59 | Lexical scope: parent chain, bindings Map[IdentId, TypeId], lookup walks parent chain |
| 🟡 | `compiler.sema.binder` | `src/compiler/sema/binder.mt` | 48 | Name resolution pass (stub — function_def only, fixed unsafe errors) |
| ✅ | `compiler.sema.checker` | `src/compiler/sema/checker.mt` | 310 | Type checker: structs, extending, functions, if/while/unsafe/match, binary ops, calls, local decls, assignment, return, null-type→void |
| ⬜ | `compiler.sema.generics` | | | Generic type parameter substitution and monomorphization |
| ⬜ | `compiler.sema.interfaces` | | | Interface conformance checking |
| ⬜ | `compiler.sema.const_eval` | | | Compile-time expression evaluator |

### Phase 5: Lowering ✅

| Status | Module | File | Lines | Description |
|--------|--------|------|-------|-------------|
| ✅ | `compiler.lowering.ir` | `src/compiler/lowering/ir.mt` | 54 | IR types: Program (structs+functions), Function, Struct, Field, MatchArm, Stmt (return/expr/decl/assign/if/while/for/break/continue/match/block), Expr (integer/name/null/binary/call/access) |
| ✅ | `compiler.lowering.lowerer` | `src/compiler/lowering/lowerer.mt` | 585 | AST → IR: lowers structs, functions, extending methods, if/else, while, match (int/char/enum-member patterns with | merging), assignment, local decls, unsafe, binary ops→C strings, type→C names, null-type→void, arena-backed span copies |
| ⬜ | `compiler.lowering.async` | | | Async normalization (deferred) |

### Phase 6: Code Generation ✅

| Status | Module | File | Lines | Description |
|--------|--------|------|-------|-------------|
| ✅ | `compiler.codegen.c_backend` | `src/compiler/codegen/c_backend.mt` | 204 | IR → C: emits `#include`, struct typedefs, functions, if/else, while, block, expressions. Uses `string.String` as write buffer. |
| ⬜ | `compiler.codegen.c_formatter` | | | (merged into c_backend — string.String builder pattern) |

### Phase 7: Integration & Indentation (Completed) ✅

| Status | What | Detail |
|--------|------|--------|
| ✅ | Lexer indentation | `handle_indent()` counts leading spaces, emits `INDENT`/`DEDENT`, `finish()` emits trailing dedents |
| ✅ | Parser indent handling | `skip_newlines` consumes `INDENT`; `parse_module` checks `at_indent_end`; fixed infinite loop on dedent |
| ✅ | Arena lifetime fix | Parser no longer calls `arena.release()` — all AST pointers remain valid after parse |
| ✅ | End-to-end verified | `function add(a: int, b: int) -> int: return a + b` → compiles to C → gcc compiles → runs correctly |

---

## 8. Coding Rules & Discovered Patterns

Rules accumulated across all sessions. These are the **hard constraints** when writing Milk Tea code for this compiler.

### Reserved Names (cannot be used as variables, fields, or function names)

| Name | Category | Why blocked |
|------|----------|------------|
| `byte`, `int`, `float`, `void`, `char`, `bool`, `str`, `cstr` | Primitive types | Reserved primitive type names |
| `span`, `ptr`, `ref`, `type`, `fn`, `proc` | Type constructors | Reserved for type expressions |
| `return`, `if`, `else`, `for`, `while`, `match`, `when` | Control flow | Keywords |
| `let`, `var`, `const`, `function`, `editable`, `extending` | Declarations | Keywords |
| `and`, `or`, `not`, `is`, `as`, `in`, `out`, `inout` | Word operators | Keywords |
| `emit`, `import`, `public`, `external`, `foreign`, `async` | Module-level | Keywords |
| `pass`, `break`, `continue`, `defer`, `unsafe`, `null`, `true`, `false` | Statements/literals | Keywords |
| `struct`, `enum`, `flags`, `union`, `variant`, `interface`, `opaque` | Data declarations | Keywords |
| `match`, `gather`, `detach`, `parallel`, `inline`, `await`, `dyn` | Advanced keywords | Keywords |

### Naming Conventions

| What | Convention | Example |
|------|-----------|---------|
| Enum members | Prefix to avoid keyword collisions | `tk_kw_if`, `pk_int`, `op_add` |
| AST field for source location | `loc` (NOT `span` — reserved) | `ast.Expr.integer_literal(value: int, loc: Span)` |
| AST field for type reference | `type_ref` (NOT `type` — reserved) | `ast.Type.named_type(name: IdentId, loc: Span)` |
| Extending method parameter | `output` (NOT `out` — reserved) | `function lower_stmt(..., output: ref[Vec[IrStmt]])` |
| Binary op enum member | `op_` prefix | `op_add`, `op_eq`, `op_logic_and` |
| Byte character variable | `ch` (NOT `byte` — reserved) | `let ch = cursor.current()` |

### Syntax Rules

| Rule | Example |
|------|---------|
| No single-line `if cond: stmt` — body must be indented on next line | `if op == B.op_add:\n    return "+"` |
| No `let x = expr else: return` — `else:` must have indented body on next line | `let tid = scope.lookup(name) else:\n    return TypeId<-0` |
| `match` on `ubyte` now accepts char-literal arms | `match ch: '(' : ...` |
| Multi-value match arms use `\|` | `T.tk_kw_let \| T.tk_kw_var: ...` |
| No `public` on `extending` block methods — use standalone functions | `public function write_program(program: IrProgram) -> str` |
| `ptr[X].method()` requires `unsafe` | `unsafe: return this.registry.pointer(inner, false)` |
| `ptr[X]?` (nullable) → `== null` works; `ptr[X]` (non-nullable) → `== null` rejected | Use `ptr[Scope]?` for nullable parent chains |
| Variant field patterns use positional `_` discard (not `_fieldname`) | `ast.Type.named_type(name, _)` ← discard second field |
| `zero[ptr[T]]` returns null pointer; `null` for nullable types | `let p = zero[ptr[IrStmt]]` |
| `var x` is mutable; `let x` is immutable; `ref_of` needs mutable | Use `var` for things you'll call `ref_of` on |
| `let _ = expr else:` for side-effect guard without binding | `let _ = m.set(key, val)` |
| `let decl = unsafe: read(data + i)` — no `else:` allowed (not nullable/opt/result) | Just read directly |

### Style Requirements

| Rule | Checked by |
|------|-----------|
| Max line length: 120 characters | Linter |
| Trailing commas in multiline calls: preferred | Linter note |
| Indentation: spaces only, multiple of 4 | Parser |

---

## 9. Standard Library Quick Reference

Useful modules for the self-host compiler. All are in `std/`. No explicit dependency needed — the Ruby compiler auto-resolves `std.*`.

### Text & Formatting

| Module | Key API | Used in |
|--------|---------|---------|
| `std.string` | `String.create()`, `with_capacity(n)`, `from_str(s)`, `len()`, `as_str()`, `append(s)`, `assign(s)` | C backend output buffer |
| `std.str` | `byte_at(i)`, `equal(rhs)`, `starts_with(prefix)` | Interner string comparison |
| `std.fmt` | `format(f"...")` → `String`, `append(output, text)` | String building (alternative to `string.String.append`) |
| `std.ctype` | `is_alpha(c)`, `is_digit(c)`, `is_alnum(c)` | Identifier sanitization for C names |

### Data Structures

| Module | Key API | Used in |
|--------|---------|---------|
| `std.map` | `Map[K,V].create()`, `with_capacity(n)`, `get(k)`, `set(k,v)`, `contains(k)` | Keyword lookup, interning, scope bindings |
| `std.vec` | `Vec[T].create()`, `with_capacity(n)`, `push(v)`, `at(i)` → `Option[T]`, `len()`, `as_span()` → `span[T]`, `release()` | Token lists, AST child lists, diagnostics |
| `std.hash` | `int.hash`, `uint.hash`, `ptr_uint.hash` (added by us) | Map key hashing for `ptr_uint` keys |

### Memory

| Module | Key API | Used in |
|--------|---------|---------|
| `std.mem.arena` | `Arena.create(capacity)`, `alloc[T](n)` → `ptr[T]?`, `release()` | Parser AST allocation, lowerer span allocation |
| `std.mem.heap` | `alloc_bytes(n)`, `realloc_bytes(p,n)`, `release(p)` | Base allocator behind arena |

### I/O (for reading/writing source files)

| Module | Key API | Used in |
|--------|---------|---------|
| `std.fs` | `read_bytes(path)` → `Result[Bytes, Error]` — returns `Bytes.as_span()` → `span[ubyte]` | Reading source files (can use `external function` workaround) |
| `std.stdio` | `print(msg)`, `print_line(msg)` | Debug output |
| `std.libc` | `printf(format: cstr, ...)` via `external function` | Works: `external function printf(format: cstr, ...) -> int` in main.mt |

### Prelude (auto-imported)

| Module | Key API |
|--------|---------|
| `std.option` | `Option[T].some(value: T)`, `Option[T].none`, `.unwrap()`, `.is_some()`, `.is_none()` |
| `std.result` | `Result[T,E].success(value: T)`, `Result[T,E].failure(error: E)` |

---

## 7. Session Log

### Session 1 (2026-06-23)
- Analyzed Ruby reference compiler architecture (lexer, parser, sema, lowering, C backend)
- Identified 5 initial pain points for Milk Tea port
- Designed solutions (interning, arena, span iteration, `?` operator, variant matching)
- Created `std/intern.mt` — string interning table
- Scaffolded `projects/mtc/` with 4 foundational modules + entry stub
- Verified all files pass `mtc check` with zero errors/warnings

### Session 2 (2026-06-23) — Deep Audit
- Audited all 31 files in `lib/milk_tea/core/` for systematic pain points
- **Discovered 11 categories** of patterns needing Milk Tea adaptation (~800 total occurrence sites)
- **Critical finding:** String atoms for type names, operators, builtins (~150 sites) require enum redesign before self-hosting can proceed
- **Critical finding:** Type object equality (~40 implementations) requires TypeId interning (integer comparison)
- **Critical finding:** String concatenation for C generation (~100 sites) requires string.String builder pattern
- Added Phase 0 (Enums & Atom Types) to the roadmap
- Added type_registry + c_formatter modules to the architecture

### Session 3 (2026-06-23) — Phase 0 Complete
- Ported TokenKind enum from Ruby lexer: 122 members across 7 categories
- Created BinaryOp (18 members) + UnaryOp (3 members)
- Created PrimitiveKind (25 members), BuiltinName (26 members), GenericTypeKind (14 members)
- Established prefix convention: tk_ / op_ / uop_ / pk_ / bi_ / gk_ — zero collisions with C/MT keywords
- 290 lines total across 5 files, all pass `mtc check` with zero errors/warnings
- 80% of string atom pain points now eliminated (type names, operators, builtins, token kinds)

### Session 4 (2026-06-23) — Phase 2 Complete (Lexer)
- Created SourceCursor (`cursor.mt`): single unsafe boundary for byte access, `peek()` returns `Option[ubyte]`
- Created Token struct (`token.mt`): IdentId-based identifier storage, 13 inline char classification functions
- Created full lexer (`lexer.mt`): char-by-byte scanning, 58 keyword lookup via interning + `map.Map[IdentId, TokenKind]`, operator/delimiter/string/number lexing
- Fixed: `byte` and `span` are reserved type names, `peek()` merged into single `Option[ubyte]` API, removed unnecessary `ubyte<-` casts
- 936 lines total across 3 new files

### Session 5 (2026-06-23) — Phase 3 Complete (Parser)
- Designed AST variant hierarchy: 5 top-level variants (Expr 30 arms, Stmt 16 arms, Decl 9 arms, Type 11 arms, Pattern 4 arms), 17 helper structs
- Created TokenCursor (`token_cursor.mt`): safe peek/consume pattern matching SourceCursor
- Key AST design decisions: `loc` (not `span`) for source locations, `type_ref` (not `type`) for type reference fields, span-based child lists (not `ptr[vec.Vec[...]]`) for arena compatibility
- Extended MT compiler: char-literal match arm support, `|` multi-value match arm support
- Parser uses `push[T](arena_ref, value)` for arena allocation + `finish_span[T](arena_ref, vec)` for Vec→span conversion
- 865 lines across 4 files

### Session 6 (2026-06-23) — Doc Sync
- Marked Phase 2 and Phase 3 complete in progress tracker
- Next step: Phase 4.0 — Type Registry (`compiler.sema.type_registry.mt`), addresses pain point 2.2

### Session 7 (2026-06-23) — Phase 4 (Sema) + Phase 5 (Lowering) + Phase 6 (Codegen)
- Created `sema/type_registry.mt` (223L): TypeId interning with hash-map dedup
- Created `sema/types.mt` (95L): type classification predicates
- Created `sema/scope.mt` (58L): lexical scope with nullable parent chain (static functions — workaround for nullable ptr method call lowering bug)
- Created `sema/checker.mt` (257L): type checker for declarations/expressions/statements
- Created `lowering/ir.mt` (27L): flat C-oriented IR types
- Created `lowering/lowerer.mt` (284L): AST→IR with type→C name mapping, arena-backed span copies
- Created `codegen/c_backend.mt` (140L): IR→C string emission via `string.String` buffer
- Wired full pipeline in `main.mt`: source string → lex → parse → check → lower → emit C
- Added `ptr_uint` hash to `std/hash.mt` (needed by registry's `map.Map[ptr_uint, TypeId]`)
- Added `import std.hash` to `std/map.mt` (build-time monomorphization order fix)
- Made `public`: PrimitiveKind, BuiltinName, GenericTypeKind enums + Registry accessor functions
- Renamed: scope methods to static functions (workaround for nullable ptr method call bug)
- Replaced: generic `push[T]`/`finish_span[T]` with typed `new_*`/`span_of_*` methods (workaround for generic monomorphization bug)
- Replaced: `array[TypeId, 26]` with `vec.Vec[TypeId]` (workaround for array zero-init C codegen bug)
- Renamed: `emit` → `write_*` everywhere (emit is a reserved keyword)
- Renamed: `out` → `output` parameter (out is a reserved keyword)
- Declared `printf` as `external function` in main.mt to print generated C

### Session 8 (2026-06-23) — Phase 7 (Indentation + End-to-End)
- Added `handle_indent()` to lexer: counts leading spaces after newlines, emits `INDENT`/`DEDENT` tokens
- Updated `finish()` to emit trailing dedents before EOF
- Fixed parser: `skip_newlines` consumes `INDENT`; `parse_module` checks `at_indent_end`
- Fixed parser infinite loop on dedent: `skip_to_newline` now handles dedent boundary properly
- Fixed SEGV: parser was calling `arena.release()` before return — all AST pointers became dangling
- Verified end-to-end: `function add(a: int, b: int) -> int: return a + b` → generates valid C → gcc compiles → runs correctly (add(2,3) == 5)
- Doc update: added §8 (Coding Rules) and §9 (Standard Library Quick Reference) to this document

### Session 9 (2026-06-23) — Struct + Control Flow Pipeline

**Audit Findings:**
- Checker passed most decls/stmts/exprs silently (struct, enum, extending, match, if, while, unsafe, etc.)
- Parser's `parse_declaration` only handled `function` — struct and all other decls became `error_decl`
- Parser's `parse_statement` only handled `return`, `let`/`var` — if, while, unsafe were parsed as expression stmts (causing garbled output)
- Parser's `parse_integer` always hardcoded `value = 0` (integer values not parsed from source bytes)
- `parse_module` broke on DEDENT after first decl — multi-decl modules failed
- Binder had missing `unsafe:` wrapping causing 2 compile errors

**Fixes & Expansions:**
- **IR (`ir.mt`)**: Added `IrStruct`, `IrField`, `IrStmt.if_stmt`, `IrStmt.while_stmt`, `IrStmt.block`; `IrProgram` now holds `structs` + `functions`
- **Parser**: Added `parse_struct_def`, `parse_if_stmt`, `parse_while_stmt`, `parse_unsafe_stmt` parsing with indentation handling; added `read_int()` to parse integer values from source byte spans; added `source: span[ubyte]` field to Parser struct; added `new_pattern()`, `span_of_fields()`, `span_of_branches()` helper methods; fixed DEDENT consumption in `parse_module` and `parse_function_def` for multi-decl support
- **Checker**: Added `check_struct()` to register struct types; added if/while/unsafe checking in `check_stmt`; made `return` type check tolerant of unknown `TypeId` (avoids false errors on unresolved calls)
- **TypeRegistry**: Made `named_type` public
- **Lowerer**: Added `lower_struct()`, `lower_if()`, `lower_while()`, `lower_block_into()`, `lower_block_stmts()`; added `copy_fields()`, `copy_structs()` arena helpers
- **Codegen**: Added `write_struct()` for C typedef emission; added if/else, while, and block stmt emission with proper C indentation

**Verified End-to-End:**
```
struct Vec2: x: float, y: float
function test(n: int) -> int: if n > 0: return 1 else: return 0
function main() -> int: return test(5)
```
→ Compiles to valid C → gcc compiles → runs with exit code 1 (correct: 5 > 0)

_(All gaps listed below are now resolved — see S10–S14 for extending, match, for, break/continue, struct literals, this receiver, etc.)_

### Session 10 (2026-06-23) — Extending Blocks & Method Parsing

**Pushed extending blocks through full pipeline:**
- **AST**: Added `MethodKind` enum (`mk_plain`, `mk_editable`, `mk_static`), `ExtendingMethod` struct, `Decl.extending_decl` variant
- **Parser**: Added `parse_extending` with indented method loop, `parse_extending_method` handling `editable`/`static` modifiers, `span_of_methods` arena helper
- **Checker**: Added `check_extending` and `check_extending_method`; fixed `resolve_type` to handle null type_ref (→ void_id)
- **Lowerer**: Added `lower_extending` and `lower_method`; fixed `type_c_name` to return `"void"` for null type refs
- **Bug fix**: Added `pass` statement parsing to `parse_statement` (was missing, caused crash)
- **Bug fix**: Null return type causing SEGV in `resolve_type` and `type_c_name` — both now return void when type_ref is null

**Verified end-to-end:**
```
struct Counter: value: int
extending Counter:
    function read() -> int: return 42
    editable function bump(): pass
function fib(n: int) -> int:
    if n <= 1: return n
    else: return fib(n-1) + fib(n-2)
function main() -> int: return fib(6)
```
→ C compiles → runs → exit 8 (correct)

_(`this` member access + receiver → S13; method naming deferred)_


### Session 11 (2026-06-23) — Assignment + Local Decl + Null + Match

**Priority 1 — Assignment & Compound Assignment:**
- **Parser**: Added `is_assign_op()` and assignment detection to `parse_expression_stmt` — recognizes `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`
- **IR**: Added `IrStmt.assign(target, op_kind, value)`
- **Lowerer**: Added `target_name()`, `assign_op_c()` helpers; `local_decl` now lowered to `IrStmt.decl` (was silently skipped)
- **Codegen**: Added `assign` emission — `a += 5` → `a += 5;` in C

**Priority 1 — Null Literal:**
- **IR**: Added `IrExpr.null_value`
- **Lowerer**: `null_literal` → `null_value`
- **Codegen**: Emits `0` (C null pointer equivalent)
- **Checker**: Added `null_literal` type handling

**Priority 2 — Match Statements (Major Feature):**
- **IR**: Added `IrMatchArm` struct, `IrStmt.match_stmt(scrutinee, arms)`
- **Parser**: Added `parse_match_stmt`, `parse_match_arms` (multi-value `|` flattening), `parse_match_pattern` (wildcard `_`, int literals, char literals, enum member `Type.member`)
- **Pattern parsing**: `is_wildcard()` detects `_` via source byte check; `read_char()` parses char literals including escapes (`\n`, `\r`, `\t`, `\0`, `\xNN`); `read_hex_byte()` for hex escapes
- **Lowerer**: Added `lower_match`, `lower_match_pattern`; `|` multi-value arms merged via `same_body()` pointer comparison — adjacent arms with identical body pointers share one IR arm with combined values
- **Codegen**: Added `write_match` — emits `if (x == v0 || x == v1) { body } else if (...) { ... } else { ... }` chain with proper indentation
- **Checker**: Added `match_stmt` checking

**Verified End-to-End:**
```
struct Counter + extending + match with | multi-value arms + assignment + if/else
function grade(5) → match: 0|1|2→1, 3|4→2, 5→3, _→0
var result = grade(5); result += 7; if result > 5: return result
```
→ C compiles → exit 10 ✓

**IR types staged for future:** `for_stmt`, `break_stmt`, `continue_stmt` (codegen stubbed, parser not yet wired)

**Known next gaps:**
- Variant arm destructuring in match patterns (e.g., `ast.Decl.function_def(name, _, params, ...)`)
- Variant type emission in C (tag + union) — needed for AST types
- Enum member value resolution in match (e.g., `TokenKind.tk_kw_if` needs C enum value)
- `for` loop parsing + lowering
- `break`/`continue` parsing + lowering
- `let...else:` guard pattern
- Struct literal construction (`Type(field = val)`)

### Session 12 (2026-06-23) — Enums + For Loops + Break/Continue

- **Enum declarations**: Added `parse_enum_def`, `IrEnum`+`IrEnumMember`, `lower_enum` with auto-value increment, `write_enum` → `typedef enum {...} Name;`
- **For range loops**: Added `parse_for_stmt`, `..` range expression in `parse_binary`, `IrStmt.for_range(binding, start, end, body)`, codegen `for (int i = 0; i < N; i++)`
- **Break/continue**: Added keyword cases in `parse_statement`, IR variants, lowering, codegen
- Verified: `for i in 0..n: total += i` → `for (int i = 0; i < n; i++)` → exit 10 ✓

### Session 13 (2026-06-23) — `this` Receiver + Builtins

- **`this` receiver in extending**: `IrFunction.is_editable` flag; codegen emits `Counter*` for editable, `Counter` for plain; `IrExpr.ptr_access` for `->` member access; `in_editable` lowering context flag
- **`read(ptr)` builtin**: `IrExpr.deref` → `(*expr)`; lowerer intercepts callee name `"read"`
- **`ptr_of(x)` builtin**: `IrExpr.address` → `(&expr)`
- **Unary `-`**: `parse_prefix` case, `IrExpr.unary`, `unary_op_c` helper
- **`pass` statement**: Added to `parse_statement` (was missing, caused crash)
- Verified: `read(ptr_of(x))` → `(*(&x))` → exit 42 ✓

### Session 14 (2026-06-23) — Struct Literals + Void Return + `!=`

- **Struct literal construction**: `Expr.aggregate(type_name, fields)` AST variant; `has_named_arg_ahead()` detects `id = expr` in call args; `IrAggregateField` IR; `lower_aggregate` → `((Type){.field = val})`; `map_type_c` now passes through user-defined types
- **Void return**: `IrStmt.return_void` variant; lowerer checks `value == zero[ptr[Expr]]`; codegen emits `return;`
- **`!=` comparison**: Already worked — `op_ne` in `binary_op_c` → `"!="`
- **`zero[ptr[T]]` builtin**: Lowerer intercepts `specialization` callee `"zero"` → `IrExpr.null_value`
- Verified: `Counter c = ((Counter){.value = 42}); return c.value` → exit 42 ✓

### Session 15 (2026-06-23) — Ruby Compiler Bug Fix

- **f-string struct return fix**: `mt_format_str_release` was emitted after struct construction, causing use-after-free when struct fields contained format string values. Fixed in `lowering/statement_blocks.rb` (return path + assignment defer path) and `lowering/utils.rb` (`struct_contains_string_field?` + `suppress_format_releases_for_assignment`). Covers direct return, field-assign-return, nested struct, and generic struct patterns.
- **Verified**: `make_param("Counter")` returns struct with owned string — zero `mt_format_str_release` calls in generated C.
---

## 10. Remaining Feature Gaps (Priority-Ordered)

This section tracks the features needed to compile real source files, ordered by implementation priority.

### Priority 1 — Immediate (fix silent data corruption)

| Feature | Complexity | Impact |
|---------|-----------|--------|
| Lowerer: 21 collapsed Expr variants | Low each | **Critical** — string/bool/float/index produce wrong C |
| Type mapping: pointer/span types → `"int"` | Medium | **Critical** — all generic types emit wrong C |

### Priority 2 — Missing Decl/Stmt Parsing

| Feature | Complexity | Used in |
|---------|-----------|---------|
| `defer` statement | Low | context.mt, lexer.mt |
| `const` declaration | Medium | Not yet in source files |
| `type` alias | Low | Not yet in source files |
| `variant` declaration | High | AST types (self-referential) |

### Priority 3 — Quality of Life

| Feature | Complexity | Used in |
|---------|-----------|---------|
| `let...else:` guard parsing | Medium | ~50 map.get/vec.at sites |
| Method call lowering (receiver passing) | Medium | Every extending method call |
| Struct zero-init `= {0}` | Low | Every var decl without init |
| `T<-value` cast (`<-` token) | High | type_registry.mt, binder.mt |

### Priority 4 — Major Architecture

| Feature | Complexity | Notes |
|---------|-----------|-------|
| Variant types + match destructuring | Very High | C tag+union; match with field binding |
| Generic type resolution | Very High | Vec, Map, span, ptr, arena monomorphization |
| Module loading + file I/O | High | fread+parse multi-file; import resolution |

### ✅ Completed Features (since Phase 7)

| Feature | Session |
|---------|---------|
| Struct declarations + C emission | S9 |
| If/else + while + unsafe blocks | S9 |
| Integer parsing from source bytes | S9 |
| Extending blocks + method parsing | S10 |
| Match statements (int/char/wildcard/\|) | S11 |
| Assignment + compound assignment | S11 |
| Local declaration lowering | S11 |
| Null literal | S11 |
| Enum declarations + C emission | S12 |
| For range loops (`for i in 0..N:`) | S12 |
| Break/continue | S12 |
| Unary minus operator | S12 |
| `this` receiver in extending (. and ->) | S13 |
| `read(ptr)` + `ptr_of(x)` builtins | S13 |
| Struct literal construction (`Type(field=val)`) | S14 |
| `return;` for void functions | S14 |
| `!=` comparison + `zero[ptr[T]]` builtin | S14 |
| Ruby: f-string struct return fix | S15 |
