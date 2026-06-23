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
        token_kind.mt             TokenKind enum
        token.mt                  Token struct (kind, span, line, col)
        lexer.mt                  Lexer: source bytes → Vec[Token]
      parser/
        ast.mt                    AST variant types (Expr, Decl, Stmt, Type, Pattern)
        parser.mt                 Recursive descent parser
        precedence.mt             Binary operator precedence table
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
        c_formatter.mt            C type/expression formatting helpers
```

### Design Principles

1. **String interning** — identifiers become `ptr_uint` after lexing; zero str comparisons in parser/sema/lowering
2. **TypeId interning** — type objects get canonical integer IDs from registry; zero struct `==` in type checking
3. **Arena allocation** — one arena per file; all AST/type objects live in it, freed once after C emission
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
let arena = arena_mod.create(256 * 1024)     # 256 KiB per file
let node = arena.alloc_bytes(size_of(Node))?  # returns ptr[ubyte]?
```

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

### Phase 2: Lexer 🔜

| Status | Module | Description |
|--------|--------|-------------|
| ⬜ | `compiler.lexer.token` | Token struct (kind: TokenKind, span, line, column, ident: IdentId) |
| ⬜ | `compiler.lexer.lexer` | Lexer: char-by-char, produces Vec[Token] + trivia |

### Phase 3: Parser 🔜

| Status | Module | Description |
|--------|--------|-------------|
| ⬜ | `compiler.parser.ast` | Variant types: Expr, Decl, Stmt, Type, Pattern |
| ⬜ | `compiler.parser.precedence` | Binary operator precedence table |
| ⬜ | `compiler.parser.parser` | Recursive descent parser with error recovery |

### Phase 4: Semantic Analysis 🔜

| Status | Module | Description |
|--------|--------|-------------|
| ⬜ | `compiler.sema.types` | Type variant hierarchy |
| ⬜ | `compiler.sema.type_registry` | Global TypeId interning registry |
| ⬜ | `compiler.sema.scope` | Lexical scope with parent chain, bindings Map |
| ⬜ | `compiler.sema.binder` | Name resolution pass |
| ⬜ | `compiler.sema.checker` | Type checker for expressions and statements |
| ⬜ | `compiler.sema.generics` | Generic type parameter substitution and monomorphization |
| ⬜ | `compiler.sema.interfaces` | Interface conformance checking |
| ⬜ | `compiler.sema.const_eval` | Compile-time expression evaluator |

### Phase 5: Lowering 🔜

| Status | Module | Description |
|--------|--------|-------------|
| ⬜ | `compiler.lowering.ir` | IR Program/Function/Expr/Stmt types |
| ⬜ | `compiler.lowering.lowerer` | AST → IR transformation |
| ⬜ | `compiler.lowering.async` | Async normalization (await hoisting) |

### Phase 6: Code Generation 🔜

| Status | Module | Description |
|--------|--------|-------------|
| ⬜ | `compiler.codegen.c_formatter` | CWriter: string builder for C output, identifier sanitization |
| ⬜ | `compiler.codegen.c_backend` | C source emission from IR |

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

### Next Session (Phase 2: Lexer)
1. Define Token struct with interning support (ident: ptr_uint field)
2. Implement char-by-byte lexer producing Vec[Token]
3. Test with sample .mt source files
