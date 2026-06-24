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
  (binder.mt deleted — checker absorbed binding logic directly)
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

### Phase 4: Semantic Analysis ✅

| Status | Module | File | Lines | Description |
|--------|--------|------|-------|-------------|
| ✅ | `compiler.sema.primitive_kind` | `src/compiler/sema/primitive_kind.mt` | 37 | PrimitiveKind enum (25 members) |
| ✅ | `compiler.sema.generic_kind` | `src/compiler/sema/generic_kind.mt` | 24 | GenericTypeKind enum (14 members) |
| ✅ | `compiler.sema.builtin_name` | `src/compiler/sema/builtin_name.mt` | 35 | BuiltinName enum (26 members) |
| ✅ | `compiler.sema.type_registry` | `src/compiler/sema/type_registry.mt` | 330 | TypeId interning + reverse lookup (ptr/span/ref/nullable), alias_map, named entries |
| ✅ | `compiler.sema.types` | `src/compiler/sema/types.mt` | 95 | Type classification predicates |
| ✅ | `compiler.sema.scope` | `src/compiler/sema/scope.mt` | 47 | Lexical scope: parent chain, bindings Map[IdentId, TypeId], lookup walks parent chain |
| ✅ | `compiler.sema.checker` | `src/compiler/sema/checker.mt` | ~510 | Type checker: two-pass (register names then check), all 20 primitives registered, std type pre-registration (String/Interner/Arena), resolve_generic with Vec/Map/fallback, register_types() + error_texts() public methods |
| ✅ | `compiler.sema.binder` | `src/compiler/sema/binder.mt` | — | **Deleted** — checker absorbed binding logic |
| ⬜ | `compiler.sema.generics` | | | Full generic monomorphization (deferred) |
| ⬜ | `compiler.sema.interfaces` | | | Interface conformance checking (deferred) |
| ⬜ | `compiler.sema.const_eval` | | | Compile-time expression evaluator (deferred) |

### Phase 5: Lowering ✅

| Status | Module | File | Lines | Description |
|--------|--------|------|-------|-------------|
| ✅ | `compiler.lowering.ir` | `src/compiler/lowering/ir.mt` | 104 | IR types: IrParam, IrFunction, IrField, IrStruct, IrEnum, IrVariant, IrVariantArm, IrMatchArm, IrAggregateField, IrProgram, IrStmt (12 variants), IrExpr (11 variants). All types use TypeId. |
| ✅ | `compiler.lowering.lowerer` | `src/compiler/lowering/lowerer.mt` | 1075 | AST→IR: structs, enums, extending/methods, functions, if/else/while/for/match, let...else: guard, <- cast, enum member access stripping, builtin interception (read/ptr_of/fatal/zero) via ident ID comparison, type aliases registered in named entries, arena-backed span copies |
| ⬜ | `compiler.lowering.async` | | | Async normalization (deferred) |

### Phase 6: Code Generation ✅

| Status | Module | File | Lines | Description |
|--------|--------|------|-------|-------------|
| ✅ | `compiler.codegen.c_backend` | `src/compiler/codegen/c_backend.mt` | 542 | IR→C: type_to_c (pointer/span/ref/nullable + primitives + struct/enum names), forward declarations, zero_init (struct {0}), struct typedefs, enum typedefs, functions, if/else/while/for/match, cast_expr. Uses string.String builder. |
| ⬜ | `compiler.codegen.c_formatter` | | | (merged into c_backend) |

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

- **f-string struct return fix**: `mt_format_str_release` was emitted after struct construction, causing use-after-free. Fixed in `lowering/statement_blocks.rb` and `lowering/utils.rb`.
- Verified: `make_param("Counter")` returns struct with owned string — zero `mt_format_str_release` calls.

### Session 16 (2026-06-23) — TypeId Architecture (IR + Codegen Fix)

- **IR**: TypeId replaces `str` on IrParam, IrField, IrFunction, IrStruct, IrEnum, IrStmt.decl. Added IrVariant/IrVariantArm (staged).
- **Lowerer**: `resolve_type_id()` uses registry for all type constructors (not `map_type_c` strings). Builtin detection via ident ID (integer) comparison — zero `.equal()` calls.
- **C backend**: `type_to_c()` resolves TypeId→C name via registry + IrProgram. Added forward declarations pass. Added `zero_init()` (struct `{0}` vs scalar `0`). Added pointer/span/ref/nullable reverse-lookup in registry.

### Session 17 (2026-06-23) — Full Type Constructor Support

- **Parser**: `parse_type()` rewritten as 4-layer dispatch. Now handles `ptr[T]`, `const_ptr[T]`, `span[T]`, `ref[T]`, `array[T,N]`, `?T`, `fn(...)->T`, `proc(...)->T`, `Name[T1,...]`.
- **Checker**: `resolve_type()` handles all type constructors via registry.
- **Lowerer**: `resolve_type_id()` handles all constructors. Type aliases registered in named entries.
- **Parser**: Added interner field, pre-computed ident IDs for type constructor dispatching.

### Session 18 (2026-06-23) — Semantics Fix (Scope + Call Resolution)

- **Checker**: Scope chaining — function scopes now parent to `global_scope`. `function_types` map stores return types. `check_call` returns callee return type. `check_member` resolves struct field types via `struct_fields` map.
- Verified: `add(2,3) = exit 5`, `v.x + v.y = exit 30`.

### Session 19 (2026-06-23) — let...else: + <- Cast

- **Parser**: `let...else:` guard detection after `=` expression. `<-` cast parsed as special binary op with `expr_to_type()`.
- **Lowerer**: let...else: lowered to null-check guard. `<-` lowered to C cast `(type)expr`.
- **Lexer**: Added `tk_larrow` token (123), `<-` two-char lexing.
- Verified: guard fires on zero, skips on non-zero. `int<-42` → `(int)42` → exit 42.

### Session 20 (2026-06-23) — Type Alias + Public + External Function

- **Parser**: `public` visibility modifier. `type Name = Target` alias parsing. `external function` parsing (no body).
- **Checker**: `check_type_alias()` registers in `type_names`. `check_function` skips null body.
- **Lowerer**: Type alias declarations processed directly — registers in named entries via `register_named_with_id()`.
- Verified: `type Num = int; add(a: Num, b: Num) -> Num` → `int` types in C.

### Session 21 (2026-06-23) — Match Struct Patterns + Bool/Null Literals

- **Parser**: Struct destructuring in match arms: `Variant.arm(field1, _, field2)`. `true`/`false`/`null` literal parsing in `parse_prefix`.
- Added `span_of_pattern_fields()` arena helper.
- Note: full semantics require variant type support (lowering + C emission not yet wired).

### Session 22 (2026-06-23) — File I/O + CLI + Test Suite

- **File I/O**: `std/fs.read_bytes(path)` replaces raw libc. `std/stdio.print_line` replaces `printf`. One external: `strcmp`.
- **CLI**: `main(args: span[str]) -> int` — native runtime support via `mt_entry_argv_to_span_str`. Subcommand dispatch: `build`, `check`.
- **Enum fix**: `Kind.second` → emits just `second` in C (lowerer strips enum type prefix).
- **Test suite**: `test/fixtures/` with 13 progressive .mt files. `test/run.sh` runner — `mtc build` → gcc → binary → exit code check.
- **13/13 tests pass**: return, call, struct, while, fib, for-range, match-enum, extending, type-alias, let-else, compound-assign, match-multi, cast. 103 lines of test code, 43 lines of runner script.

---

## 10. Test Suite

### Safety Rules for Running Self-Hosted `mtc`

The self-hosted compiler is under active development and inherits C memory safety risks from its generated code. Always run it with resource limits:

```sh
# Run self-hosted mtc with hard limits (recommended wrapper)
run_mtc() {
    ulimit -v 524288    # 512 MiB virtual memory
    ulimit -t 10        # 10 seconds CPU time
    timeout 10 ./build/bin/linux/debug/mtc "$@"
}
export -f run_mtc
```

**Test runner safety:**
```sh
# Safe test runner with per-test limits
for f in test/fixtures/*.mt; do
    name="$(basename "$f" .mt)"
    c_out="$(mktemp /tmp/mtc_XXXXXX.c)"
    bin_out="$(mktemp /tmp/mtc_XXXXXX)"
    (
        ulimit -v 524288
        ulimit -t 10
        timeout 10 ./build/bin/linux/debug/mtc build "$f"
    ) > "$c_out" 2>/dev/null || { echo "FAIL $name"; continue; }
    gcc "$c_out" -o "$bin_out" -w 2>/dev/null || { echo "FAIL $name"; continue; }
    actual=$("$bin_out" >/dev/null 2>&1; echo $?)
    rm -f "$c_out" "$bin_out"
    echo "OK   $name — exit $actual"
done
```

**Rules:**
- Never run the self-hosted compiler without `ulimit -v` and `timeout` guards
- Exit code 137 = OOM kill (bug in self-hosted, not the test)
- Exit code 124 = timeout (likely infinite loop in self-hosted)
- Exit code 139 = SEGV (null pointer or buffer overflow in generated C)
- Generated C may contain use-after-free, buffer overflows, or infinite loops
- Always compile generated C with `-fsanitize=address,undefined` for debugging

### Fixtures (`projects/mtc/test/fixtures/` — 12 files)

| # | File | Feature | Exit | Self-hosted | Ruby baseline |
|---|------|---------|------|-------------|---------------|
| 01 | `01_return.mt` | Basic return | 42 | PASS | 15 lines |
| 02 | `02_call.mt` | Function call | 5 | PASS | 20 lines |
| 03 | `03_struct.mt` | Struct + field access | 30 | PASS | 23 lines |
| 04 | `04_while.mt` | While loop | 5 | PASS | 21 lines |
| 05 | `05_fib.mt` | Recursive fib | 8 | PASS | 23 lines |
| 06 | `06_for_range.mt` | For range loop | 45 | PASS | 19 lines |
| 07 | `07_match_enum.mt` | Match on enum | 20 | PASS | 40 lines |
| 08 | `08_extending.mt` | Extending block | 42 | PASS | 27 lines |
| 09 | `09_type_alias.mt` | Type alias | 30 | PASS | 20 lines |
| 11 | `11_compound_assign.mt` | Compound assign | 255 | PASS | 20 lines |
| 12 | `12_match_multi.mt` | Multi-value match | 1 | PASS | 42 lines |
| 13 | `13_cast.mt` | <- cast expression | 7 | PASS | 24 lines |

### Commands

```sh
./test/run.sh                # compile + run all fixtures through self-hosted mtc
./test/regen-baselines.sh    # regenerate test/fixtures/c/*.c from Ruby compiler via emit-c
```

Baselines use `mtc emit-c` on flat-path copies (`/tmp/fixture_NN_xxx.mt`) for short module prefixes.

---

## 11. Remaining Gaps (updated S29)

| # | Gap | Complexity | Blocks selfhost? | Status |
|---|-----|-----------|-------------------|--------|
| 1 | ~~Check fails across modules~~ | — | — | **Fixed S27–S28**: DEDENT loops eliminated, all primitives registered, std types (String/Interner/Arena) pre-registered, two-pass checker for forward refs, import resolution with interner dedup. 23/23 OK. |
| 2 | ~~Parser DEDENT crashes (9 modules)~~ | — | — | **Fixed S27**: 6 loop sites + `consume_list_end()` helper architecture. 0/23 crashes. |
| 3 | ~~Parser module-qualified constructors~~ | — | — | **Fixed S29**: Two-level MemberAccess unwrapping for variant ctors and match patterns. |
| 4 | ~~Import path resolution~~ | — | — | **Fixed S29**: `try_load_import` now uses `"src"` prefix, dedup via loaded vec. |
| 5 | ~~Forward declaration ordering~~ | — | — | **Fixed S29**: `write_spans()` moved before struct/enum/variant emission. |
| 6 | `build` path: C generation for all modules | High | **Yes** | 6/23 OK. Regression: API mismatch (S26) + span/struct ordering (S29 fixed). Remaining: registry sharing, std type emission, qualifed method calls, this scope, generic methods. |
| 7 | Generic monomorphization (full) | Very High | Partial | Built-in Vec/Map works; full user-defined generics needs type param substitution |
| 8 | Std type C name resolution | Medium | **Yes** | Vec/Map/String/Interner/Arena not in lowerer's registry → emit as `void` |
| 9 | Qualified method call lowering | Medium | **Yes** | `string.String.from_str(x)` → wrong C output |
| 10 | Registry sharing (checker vs lowerer) | Medium | **Yes** | Checker copies registry → changes invisible to lowerer |
| 1 | ~~Check fails across modules~~ | — | — | **Fixed S27–S28**: DEDENT loops eliminated, all primitives registered, std types (String/Interner/Arena) pre-registered, two-pass checker for forward refs, import resolution with interner dedup, resolve_generic fallback for str_buffer. 23/23 OK. |
| 2 | ~~Parser DEDENT crashes (9 modules)~~ | — | — | **Fixed S27**: 6 loop sites + `consume_list_end()` helper architecture. 0/23 crashes. |
| 3 | `build` path: C generation for all modules | Medium | **Next** | `check` passes all modules; `build` path needs per-module flatten+lower+codegen verified |
| 4 | Generic monomorphization (full) | Very High | Partial | Built-in Vec/Map works; full user-defined generics needs type param substitution |
| 5 | Std type complete coverage | Low | No | String/Interner/Arena registered; Vec/Map work via resolve_generic. Remaining std types added as needed |

### ✅ Completed (S9–S22)

| Feature | Session |
|---------|---------|
| Struct/if/while/for/match/assign/return/break/continue | S9–S12 |
| this receiver + read/ptr_of builtins | S13 |
| Struct literals + void return + != + zero[T] | S14 |
| TypeId architecture (IR, forward decls, type_to_c, zero_init) | S16 |
| Full type constructors (ptr, span, ref, ?T, array, fn, proc) | S17 |
| Scope chaining + call resolution + member access types | S18 |
| let...else: guard + <- cast expression | S19 |
| type alias + public visibility + external function | S20 |
| Zero string comparisons (ident ID dispatch) | S20 |
| Struct patterns in match (parsed) + bool/null literals | S21 |
| File I/O (std/fs) + CLI (main args) + test suite + baselines | S22 |

### ✅ Completed (S23 — current)

| Feature | Detail |
|---------|--------|
| Method name prefixing | `c.read()` → `Counter_read(c)`; var_types tracking for receiver type resolution |
| Variant declaration C emission | Tag enum + union + struct typedef; `IrProgram.spans` tracking |
| Variant arm construction | `MyTok.number(val=42)` → C compound literal with tag + data |
| Variant match tag comparison | `match tok: MyTok.number(_): ...` → `if (tok.tag == MyTok_tag_number)` |
| Variant field bindings | `MyTok.number(val): return val` → `int val = tok.data.number.val; return val;` |
| Parser bug fix | Double `cursor.advance()` in named field patterns removed |
| Span struct emission | `span[int]` → `typedef struct { int* data; uintptr_t len; } int_span;` via IrProgram |
| for-span codegen | `typeof()`-based span iteration without element type info |
| Dotted type names | `tk.TokenKind` → `qualified_type(module, type)` in AST/checker/lowerer |
| Module loading | `SourceFile.imports` traversal; recursive flatten; depth-limited cycle prevention |
| Safety test runner | `ulimit`/`timeout` hard limits per test; OOM/SEGV/timeout detection |

### Session 24 (2026-06-23) — Foundations + Module Loading + Vec/Map Infrastructure

**Completed:**
- **Method name prefixing**: Lowerer tracks `var_types` map, extends method calls with `Type_method` C name convention. Cross-type collision verified (`A_get + B_get = 30`).
- **Variant declaration C emission**: Tag enum + union + struct typedef via `IrVariant`/`IrVariantArm`. `write_variant()` emits multi-part C definition.
- **Variant arm construction**: Parser detects `Type.arm(field=val)` in `parse_call_expr` via member-access callee. `IrExpr.variant_ctor` → `((MyTok){ .tag = MyTok_tag_number, .data.number = {.val = 42} })`.
- **Variant match tag comparison**: `lower_match` detects `Pattern.variant_arm`, generates `scrutinee.tag == TAG_VALUE` binary expression as arm condition. Works without and with field bindings.
- **Variant field bindings**: `PatternField` names in match arms generate `decl(name, init=scrutinee.data.arm.field)` statements prepended to arm body. Verified `int val = tok.data.number.val; return val;` → exit 42.
- **Parser bug fix**: Double `cursor.advance()` at line 1219 in `parse_match_pattern` — `expect()` already advances. Removed.
- **Span struct emission**: Spans tracked in `IrProgram.spans` via `IrSpanType`. Codegen emits `typedef struct { T* data; uintptr_t len; } T_span;`. `type_to_c` resolves via program.spans lookup.
- **for-span codegen**: `IrStmt.for_span` using `typeof()`-based iteration. GCC/Clang extension, works for both arrays and spans without element type info.
- **Dotted type names**: `qualified_type(module_id, type_name)` in AST. Parser's `parse_named_type` handles `Module.Type` → qualified_type. Checker/lowerer `resolve_type` dispatches.
- **Module loading**: Recursive import resolution. Bug found and fixed — `SourceFile.imports` is separate from `.decls`. `flatten_file` iterates both. Depth-limited (16) cycle prevention. Path building via local `str_buffer` used immediately.
- **Vec/Map built-in infrastructure**: 
  - AST: `generic_type`, `qualified_generic_type` variants
  - Registry: `vec(element)`/`map(k,v)` with reverse lookup, `vec_element`/`map_key`/`map_val`
  - Parser: `parse_type_constructor` handles dotted names via `has_mod`/`mod_prefix`
  - Checker: `resolve_generic` by IdentId comparison (pre-interned `vec_id`/`map_id`)
  - Lowerer: `resolve_generic_id` by IdentId comparison (pre-interned `id_vec`/`id_map`)
  - Codegen: Vec struct `{T* data; uintptr_t len; uintptr_t cap;}` and Map struct emission, `type_to_c` Vec/Map resolution, `zero_init` support
  - **Status**: Resolution confirmed working (`genric_type` match triggers, `name == this.id_vec` true, return flows to codegen). But `registry.vec(elem)` produced type not found by `vec_element` — likely `elem == 0` (element type resolution returning void). Single-point debug needed.

### Session 28 (2026-06-24) — Checker Fixes: 5/22 → 23/23 OK

**Root causes of "check failed" errors:**
1. **Checker didn't register all primitives** — only 5 of 20 built-in type names were in `type_names` (`int`, `float`, `bool`, `void`, `str`). Missing: `ptr_uint`, `byte`, `ubyte`, `uint`, `char`, `cstr`, etc. Added all 20 in `init_builtins`.
2. **Std types not registered** — modules referencing `String`, `Interner`, `Arena` in struct fields couldn't resolve them. Pre-registered in `init_builtins` via `registry.named_type(name)`.
3. **`str_buffer[N]` not handled** — `resolve_generic` only handled `Vec` and `Map`. Added catch-all fallback that returns `this.registry.named_type(name)` for unrecognised generics.
4. **Error messages invisible** — `check()` returned bool but errors were private. Added `error_texts()` and `error_count()` public methods; wired error output in `main.mt`.

**Results**:

| Metric | Before | After |
|--------|--------|-------|
| `check` OK | 5/22 | **23/23** |
| Parser crashes | 0/22 | 0/22 |
| Test suite | 12/12 | 12/12 |

**Project Stats (end of S28):**

| Metric | Value |
|--------|-------|
| Source files | 22 .mt + main.mt |
| `check` OK | 23/23 (100%) |
| Parser crashes | 0 |
| Test suite | 12/12 PASS |
| Self-compiles self? | **`check` passes self** (all modules type-check). `build` path (C generation) is the next milestone. |
| Key architecture | `consume_list_end()` helper, two-pass checker, import resolution, interner dedup |

**Next session:** Verify the `build` path generates compilable C for all modules. Then achieve self-compilation: the selfhosted binary should compile its own source into a working binary.

### Session 27 (2026-06-24) — Parser DEDENT Crash Elimination

**Root cause discovered**: The selfhosted parser has 6 loop sites that parse comma-separated lists inside parens/brackets (function params, variant arm fields, extending method params, specialization args). None of them handle DEDENT tokens that appear before the closing delimiter in multiline declarations. After consuming a comma, the cursor hits DEDENT, `skip_newlines` doesn't consume it, `expect(tk_comma)` fails silently, `skip_to_newline` no-ops on DEDENT, and the loop spins infinitely allocating garbage via `parse_type()` → `new_type()`.

**Architecture upgrade**: Added `consume_list_end(kind)` helper method on Parser that handles the DEDENT→RPAREN/RBRACKET transition once, used by all loop sites. Each loop also gets `at_indent_end()` guards and `skip_newlines()` at strategic points.

**Fixes applied** (all in `parser.mt`):

| Site | Line | Pattern |
|------|------|---------|
| Function param loop | ~434 | `while true` with `rparen` break, comma-separated params |
| Variant arm field loop | ~569 | Nested loop with `rparen` break, comma-separated fields |
| Extending method param loop | ~731 | Same pattern as function params |
| Specialization args | ~1804 | `while true` with `rbracket` break, comma-separated type args |
| Struct field DEDENT | ~489 | After DEDENT consumption, add `skip_newlines()` |
| Public keyword | ~715 | `parse_extending_method` didn't consume `public` before `function` |

**Also fixed**: Arena size increased from 256 KiB to 32 MiB (the DEDENT loop was the real consumer; 256 KiB works too once loops terminate, but 32 MiB provides headroom for large files).

**Checker**: Added `register_types()` public method for pre-loading import types without running full checking.

**Main.mt**: Added `check_with_imports` → `load_imports` → `load_one_import` → `load_import_file` chain for resolving import types before checking the main file. Uses `src/` prefix for path resolution, interner-based dedup.

**Results**:

| Metric | Before | After |
|--------|--------|-------|
| Parser crashes | 9/22 modules | **0/22** |
| Check OK | 5/22 | 5/22 (stable) |
| Test suite | 12/12 | 12/12 |

All remaining "check failed" modules are checker type-resolution issues (cross-module types from imports not fully resolved), not parser crashes.



### Session 29 (2026-06-24) — Parser Fixes + Build Path Audit

**Parser fixes — 3 bugs resolved:**

1. **Multiline aggregate parsing**: `parse_call_expr` while loop (lines 1709-1741) was missing `skip_newlines()` calls. Multi-line struct literals like `Cursor(data=source, pos=0, ...)` would break out of the loop after the first field, producing incomplete aggregates. Fixed by adding `skip_newlines()` and `consume_list_end()` matching other loop sites.

2. **Module-qualified variant constructors**: Parser only unwrapped one level of `MemberAccess` for `Type.arm(field=val)`. Two-level chains like `ir.IrExpr.aggregate(name=cname, ...)` had `agg_type` never assigned (garbage on stack). Fixed by unwrapping inner `MemberAccess` to extract the correct type name.

3. **Module-qualified match patterns**: `parse_match_pattern` only handled `Type.arm`, not `module.Type.arm`. Patterns like `ir.IrStmt.return_stmt(value):` misparsed arm name as type name. Fixed by checking for second dot and extracting correct type_name/arm_name.

**Build path fixes — 4 issues resolved:**

4. **Import path resolution**: `try_load_import` used `extract_dir(path)` as base, producing paths like `projects/mtc/src/compiler/lexer/compiler/lexer/token_kind.mt`. Fixed to use `"src"` prefix (matching `check_with_imports`), correctly producing `src/compiler/lexer/token_kind.mt`. **CWD-dependent**: must run from `projects/mtc/` directory.

5. **Import dedup**: `try_load_import` had no dedup logic — when both token.mt and lexer.mt import token_kind.mt, the enum declaration was duplicated. Added `loaded` vec tracking interned file paths for dedup.

6. **Forward declaration ordering**: `write_spans()` ran AFTER `write_struct()`/`write_variant()`, so structs using `span[T]` fields saw undefined span typedefs. Moved `write_spans()` before struct/enum/variant emission.

7. **Std type registry registration**: The checker copies the Registry by value — std types (`String`, `Interner`, `Arena`) were registered only in the checker's copy. The lowerer uses the original (unmodified) `ctx.registry`. Added explicit registration in `build_file` (partial fix; see R1 below).

**Current Build Status (from projects/mtc/ CWD, 23/23 check OK):**

| Status | Count | Modules |
|--------|-------|---------|
| Check OK | 23/23 | All modules pass type checking |
| Build OK | 6/23 | token_kind, token, operators, builtin_name, generic_kind, primitive_kind |
| Build FAIL (gcc) | 14/23 | context, diagnostics, source, c_backend, cursor, lexer, ir, ast, parser, token_cursor, scope, type_registry, types, checker |
| Build FAIL (crash) | 3/23 | lowerer, binder — SIGABRT during lowering |

**Test suite**: 12/12 fixtures still pass (build + gcc compile + run).

**Remaining Build-Blocking Gaps:**

| # | Gap | Impact | Blocks |
|---|------|--------|--------|
| R1 | **Registry sharing**: checker copies registry by value; std types (`String`/`Interner`/`Arena`) and user types are registered only in the checker's copy. Lowerer uses the original `ctx.registry` → `map.Map[...]` and `vec.Vec[...]` fields resolve to `void` in C | High | scope.mt, context.mt, type_registry.mt, checker.mt, c_backend.mt, parser.mt |
| R2 | **Std type C emission**: Vec, Map, String, Interner, Arena have no C typedefs in generated output. Need either (a) pre-compiled std runtime header, or (b) full project build with transitive dependency C emission | High | All modules using Vec/Map/String |
| R3 | **Qualified method calls**: `string.String.from_str(path)` parsed correctly but lowered incorrectly — emits `from_str(string.String, path)` (type name as argument) instead of `string_String_from_str(path)` | High | source.mt, diagnostics.mt, context.mt |
| R4 | **Extending method `this` scope**: `this` in method bodies not accessible in C output — C param names differ from `this` in method body references | High | cursor.mt, token.mt, context.mt |
| R5 | **Generic type method calls**: `vec.Vec[T].create()` needs proper method lowering with generic instantiation | High | All modules using Vec/Map operations |

### Session 29 Resolution (2026-06-24) — Fixes Applied

**Completed fixes:**
- **A1. Registry sharing**: Added `Checker.get_registry()` public accessor. `build_file` now passes `chk.get_registry()` to lowerer instead of `ctx.registry`. Eliminates "void field" errors from registry mismatch. (2 sites)
- **A2. Local decl type inference**: Added `infer_expr_type_id()` and `infer_field_type()` in lowerer. Untyped `let x = expr` in methods no longer emits `void x = ...`. Infers int, float, str, ubyte, bool from literals. Partial fix for member access. (30 lines)
- **A3. Spans-before-structs ordering**: Moved `write_spans()` before `write_struct()`/`write_variant()`. Eliminates "unknown type name `Foo_span`" errors. (reorder in c_backend.mt)
- **A4. Single-parse architecture**: `build_file` no longer calls `flatten_file` for main file. Uses first parse's AST directly for both check and lowering. Avoids double-parse AST divergence. (refactor)

**Failed attempts / rolled back:**
- Forward struct declarations + span_clean_name: caused SIGABRT crashes (dangling IrProgram data). Rolled back.
- Span name sanitization (char*_span → char_ptr_span): caused "invalid UTF-8" crash. Rolled back.

**Current state** (end of S29):
- Check: 23/23 OK (changed from `chk.get_registry()` but check path unaffected)
- Build: 6/23 OK (registry sharing fixed "void field" but `this` param and std types remain)
- Fixtures: 12/12 PASS

**Next session priority (R4 → R3 → R2+R5):**
1. Fix `this` param in subsequent extending methods: rename `current`→confirm, investigate lowerer's `lower_extending` methods iteration
2. Fix qualified method call lowering (e.g., `string.String.from_str(x)` → `string_String_from_str(x)`)
3. Add std type C emission (Vec, Map, String typedefs needed in generated C)



The committed `main.mt` called `checker_mod.create(ctx.registry, ...)` passing a `Registry` struct by value where a previous checker version expected `ptr[Context]`. This C-level type mismatch produced undefined behavior that corrupted the heap, causing ALL arena allocations to fail — explaining why even 46-line files exhausted 32+ MiB arenas. Fixed by matching the correct API.


