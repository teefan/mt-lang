# Milk Tea Self-Hosting Compiler Plan

## Overview

This document describes the architecture, data structures, and implementation plan for a self-hosting Milk Tea compiler written in Milk Tea, targeting the existing Ruby reference compiler (`lib/milk_tea/core/`) as the bootstrap host.

**Goal**: produce `projects/mtc/build/bin/<platform>/<profile>/mtc` — a native binary compiled from Milk Tea source that passes the full compiler test suite.

**Core simplification**: Milk Tea targets C, eliminating the entire backend stack (SSA, register allocation, machine code generation). The compiler's job is to validate Milk Tea source and emit well-structured C.

---

## Architecture

### Pipeline

```
Source .mt files  ──>  Lexer  ──>  Parser  ──>  Name Resolver
                                                    │
                    ┌───────────────────────────────┘
                    ▼
             Semantic Analysis  ──>  Lowering (two-pass)  ──>  C Codegen
             (type-check, const                               (feature detect,
              eval, mono, CFG)                                 DCE, emit C)
```

### Pass Order

The compiler loads modules eagerly in topological order (leaves to root, resolved from `package.lock`). Passes 1–4 are per-module. Passes 5–9 operate across the full module set.

1. **Load source files** — resolve module graph from `package.lock`; resolve platform-specific variants (prefer `name.<platform>.mt`, fall back to `name.mt`); read all `.mt` files into the `SourceManager`.

2. **Lex** — produce token streams with indentation tokens (INDENT, DEDENT, NEWLINE) per module. Handle line continuation after binary operators. Reject tabs, enforce 4-space multiple indentation.

3. **Parse** — produce per-module ASTs (arena-allocated `variant` nodes). Recursive-descent parser with best-effort error recovery (synchronize to next top-level keyword or DEDENT). Desugar `is`→`match`, `elif`→nested `if`.

4. **Resolve names** — build per-module `Scope` trees (module → function → block); resolve all identifiers to declarations; verify `public`/`private` visibility; resolve cross-module references through the global symbol table index.

5. **Semantic Analysis** — the largest phase. Const evaluation, type checking, CFG analysis, and monomorphization are interleaved (const eval is a capability of the type checker, not a separate phase). Sub-phases:

   a. **Install built-in types** — register all primitives, type constructors (`ptr`, `span`, `array`, `str_buffer`, `Task`, `SoA`, `dyn`, `atomic`), and built-in attributes (`@[packed]`, `@[align]`, `@[deprecated]`).
   b. **Install prelude** — auto-import `Option[T]`, `Result[T, E]`.
   c. **Declare named types** — forward-declare all struct/union/variant/enum/flags/opaque names with type parameters.
   d. **Resolve type aliases and constraints** — resolve `type Foo = Bar` aliases; validate `T implements I` constraints on generic declarations.
   e. **Resolve aggregate fields** — resolve field types of structs/unions; compute layouts (`size_of`, `align_of`, `offset_of`) for concrete types.
   f. **Resolve enum/flags members** — compute member values (auto-increment or explicit).
   g. **Resolve variant arms** — resolve arm payload types.
   h. **Collect emit declarations** — walk const function bodies, collect `emit` stmt declarations into the global declaration set.
   i. **Declare top-level values** — register const/var/event with types.
   j. **Check attribute applications** — validate `@[attr]` on declarations.
   k. **Evaluate top-level const initializers** — const-eval `const X = expr` and `const X -> T: ... block`; resolve const dependency chains; detect cycles.
   l. **Evaluate static_assert** — evaluate `static_assert(cond, msg)` conditions.
   m. **Check function bodies and monomorphize** — for each function, type-check body statements/expressions. During body checking, const-eval `const function` calls, `when` branches, `inline for/while/if/match`, and `emit` directives. For generic functions, discover instantiation sites, monomorphize, and iterate to a fixed point. Perform CFG analyses (definite assignment, reachability, termination) on each function body. Detect nullability flow for nullable-local narrowing.

   After this phase, all types are resolved, all const values are known, all generic instantiations are discovered, and all semantic errors are reported.

6. **Lower to CIR (Pass 1 — types and globals)** — lower all type declarations (struct, union, enum, flags, variant, opaque) to CIR type definitions. Lower constants and globals. Compute per-module CIR fragments for types.

7. **Lower to CIR (Pass 2 — function bodies)** — lower all function bodies. For generic functions, lower each instantiation. This pass iterates to a fixed point: lowering a function body may discover new generic instantiations or `emit`-generated declarations that need their own lowering. Desugar constructs: `match`→switch/if-chain, `defer`→cleanup labels, `unsafe`→strip marker, `proc`→env struct + function, `variant` constructor→discriminant+payload, `f"..."`→append calls, `expr?`→early return, bounds checks→`fatal()`, etc.

8. **Assemble modules** — merge all per-module CIR fragments into a single `CIR::Program`. Generate cross-module synthetics (event init functions, async runtime integration). Resolve type references across module boundaries.

9. **Emit C** — three sub-phases:
   a. **Feature detection** — walk the assembled CIR to determine which runtime helpers, includes, and compiler flags are needed.
   b. **Dead code elimination** — reachability analysis from entry points; prune unreferenced types and functions.
   c. **Code generation** — emit C source text: includes, feature macros, runtime helpers, type definitions (topological order), forward declarations, constants, static asserts, function definitions. Invoke the external C compiler.

### Pipeline Diagram

```
┌─────────────┐   ┌───────────┐   ┌───────────┐   ┌─────────────┐
│ Source .mt  │──>│  Lexer    │──>│  Parser   │──>│  Resolver   │
│ files       │   │ TokenStrm │   │ AST       │   │ SymbolTable │
└─────────────┘   └───────────┘   └───────────┘   └─────────────┘
                                                            │
       ┌────────────────────────────────────────────────────┘
       ▼
┌──────────────────────────────────────────────────────────────┐
│                   Semantic Analysis                          │
│  install builtins → declare types → resolve fields/arms      │
│  → declare values → check attributes → eval const/assert     │
│  → check functions → const-eval inline/when/emit             │
│  → monomorphize (fixed-point) + CFG analyses                 │
└──────────────────────────────────────────────────────────────┘
       │
       ▼
┌──────────────────┐   ┌───────────────────┐   ┌─────────────────┐
│  Lowering        │   │  Assemble         │   │  C Codegen      │
│  Pass 1: types   │   │  merge CIR frags  │   │  feature detect │
│  Pass 2: bodies  │──>│  cross-module     │──>│  DCE            │──> .c files
│  (fixed-point)   │   │  synthetics       │   │  emit C         │
└──────────────────┘   └───────────────────┘   └─────────────────┘
```

---

## Key Design Decisions

### 1. Arena Allocation Everywhere

All compiler data structures (AST nodes, types, symbols, IR nodes) live in `std.mem.arena.Arena`. Each module gets its own arena for AST/resolve/type data. The CIR and code-generation phases get their own arena. When a phase completes for a given module, the arena is freed (or reset to a mark). No malloc/free churn, no lifetime annotations needed on compiler-internal types, no GC pressure.

The Ruby compiler follows this pattern implicitly via Ruby's GC. The self-host port makes it explicit.

### 2. Interned Types

A `Type` is a handle (index) into a global type arena — the `TypeRegistry`. Type equality is handle comparison (`handle_a == handle_b`). This eliminates redundant type allocations and makes type-checking fast. The type arena is populated during the declaration-collection pass (step 5) and extended during monomorphization.

The Ruby compiler already interns types through `core/types/registry.rb`.

### 3. Module-at-a-Time, Cross-Module Symbol Tables

Modules are loaded topologically. For each module, after all its dependency modules have had their symbols collected, the compiler:
- Parses the module (step 3)
- Resolves names (step 4)
- Registers its public symbols for downstream modules
- Then moves to type-checking (step 6) once all modules' symbols are known

Cross-module references go through the global `SymbolTable` indexed by `(package_instance_id, module_name, symbol_name)`. This is Go's model and it works.

### 4. CIR Is Deliberately Thin

The C Intermediate Representation looks almost like the final C output. No SSA, no basic blocks, no virtual registers. Just struct definitions, function declarations, statements, and expressions. Annotations for things like scope exit labels (for `defer`) are metadata on CIR nodes, not separate control flow constructs.

This makes `--keep-c` trivially useful for debugging and keeps the lowering pass straightforward.

### 5. No Query System or Demand-Driven Compilation

The compiler is a batch pipeline. Every pass processes its full input before the next pass begins. No on-demand re-computation, no lazy evaluation, no incremental compilation. The cost of re-parsing all source for a clean build is negligible compared to the complexity of an incremental query system.

### 6. No CST Phase

The Ruby compiler has a two-stage CST → AST pipeline because the CST preserves source fidelity for the formatter and LSP. For v1 of the self-host, the parser produces AST directly. Source locations on AST nodes provide enough fidelity for error diagnostics. A CST pass can be added later when the formatter is ported.

---

## Data Structures

### SourceManager

Central authority for all source text. Maps `SourceLocation` (file_id, byte_offset) to line:column. Provides the error-reporting substrate.

```mt
struct SourceLocation:
    file_id: uint
    offset: ptr_uint

struct SourceFile:
    path: str
    content: str
    module_name: str

struct SourceManager:
    files: vec.Vec[SourceFile]       # indexed by file_id
    line_starts: ...                 # per-file line offset table
```

### Token

```mt
enum TokenKind: ubyte
    identifier       = 1
    integer_literal  = 2
    float_literal    = 3
    string_literal   = 4
    char_literal     = 5
    cstring_literal  = 6
    colon            = 7
    arrow            = 8      # ->
    comma            = 9
    dot              = 10
    question         = 11
    ellipsis         = 12     # ...
    attr_open        = 13     # @[
    attr_close       = 14     # ]
    paren_open       = 15     # (
    paren_close      = 16     # )
    bracket_open     = 17     # [
    bracket_close    = 18     # ]
    indent           = 19
    dedent           = 20
    newline          = 21
    op_assign        = 22     # = += -= etc.
    op_add           = 23     # +
    op_sub           = 24     # -
    op_mul           = 25     # *
    op_div           = 26     # /
    op_mod           = 27     # %
    op_eq            = 28     # ==
    op_ne            = 29     # !=
    op_lt            = 30     # <
    op_le            = 31     # <=
    op_gt            = 32     # >
    op_ge            = 33     # >=
    op_and           = 34     # and
    op_or            = 35     # or
    op_not           = 36     # not
    op_bit_and       = 37     # &
    op_bit_or        = 38     # |
    op_bit_xor       = 39     # ^
    op_bit_not       = 40     # ~
    op_shl           = 41     # <<
    op_shr           = 42     # >>
    keyword          = 43     # function/struct/if/while etc.
    eof              = 44
    error            = 45

struct Token:
    kind: TokenKind
    location: SourceLocation
    lexeme: str                # the raw source text of this token
    keyword_subkind: uint      # for kind=keyword: encoded keyword enum
```

### AST (Abstract Syntax Tree)

All nodes are variants allocated in the module arena. Nodes carry source locations. The AST preserves only structural information — syntactic sugar like `elif` is desugared to nested `if`/`else`.

```mt
variant AstNode:
    # Declarations
    module_decl(imports: ..., declarations: ...)
    import_decl(module_path: ..., alias: ...)
    const_decl(name: ..., type: ..., init: ..., is_public: bool, docs: ...)
    const_block_decl(name: ..., return_type: ..., body: ..., is_public: bool, docs: ...)
    var_decl(name: ..., type: ..., init: ..., is_public: bool)
    type_alias(name: ..., type: ..., is_public: bool)
    struct_decl(name: ..., fields: ..., nested_structs: ..., attributes: ..., implements: ..., type_params: ..., is_public: bool)
    union_decl(name: ..., fields: ..., attributes: ..., is_public: bool)
    variant_decl(name: ..., arms: ..., type_params: ..., attributes: ..., is_public: bool)
    enum_decl(name: ..., backing_type: ..., members: ..., attributes: ..., is_public: bool)
    flags_decl(name: ..., backing_type: ..., members: ..., attributes: ..., is_public: bool)
    opaque_decl(name: ..., implements: ..., attributes: ..., is_public: bool)
    interface_decl(name: ..., methods: ..., type_params: ..., is_public: bool)
    function_decl(name: ..., params: ..., return_type: ..., body: ..., type_params: ..., is_async: bool, is_const: bool, is_public: bool, docs: ...)
    external_function_decl(name: ..., params: ..., return_type: ..., is_variadic: bool)
    extending_block(target_type: ..., methods: ...)
    event_decl(name: ..., payload_type: ..., capacity: ..., is_public: bool)
    attribute_decl(name: ..., targets: ..., params: ...)
    static_assert(condition: ..., message: ...)

    # Statements
    let_stmt(name: ..., type: ..., init: ..., else_block: ..., else_error_binding: ...)
    var_stmt(name: ..., type: ..., init: ..., else_block: ..., else_error_binding: ...)
    assign_stmt(target: ..., value: ...)
    if_stmt(condition: ..., then_body: ..., else_ifs: ..., else_body: ...)
    while_stmt(condition: ..., body: ...)
    for_stmt(bindings: ..., iterable: ..., body: ..., is_parallel: bool)
    match_stmt(scrutinee: ..., arms: ...)
    when_stmt(discriminant: ..., branches: ..., else_branch: ...)
    inline_for_stmt(binding: ..., iterable: ..., body: ...)
    inline_while_stmt(condition: ..., body: ...)
    inline_match_stmt(scrutinee: ..., arms: ...)
    inline_if_stmt(condition: ..., then_body: ..., else_body: ...)
    return_stmt(value: ...)
    break_stmt
    continue_stmt
    pass_stmt
    defer_stmt(body: ...)
    unsafe_block(body: ...)
    parallel_block(statements: ...)
    emit_stmt(code: ...)
    expr_stmt(expr: ...)

    # Expressions
    identifier_expr(name: ...)
    literal_expr(kind: ..., value_str: str)
    binary_expr(op: ..., left: ..., right: ...)
    unary_expr(op: ..., operand: ...)
    call_expr(callee: ..., args: ...)
    member_expr(object: ..., member_name: ...)
    index_expr(object: ..., index: ...)
    if_expr(condition: ..., then_val: ..., else_val: ...)
    match_expr(scrutinee: ..., arms: ...)
    tuple_expr(elements: ...)
    struct_literal(struct_type: ..., fields: ...)
    variant_literal(variant_type: ..., arm: ..., fields: ...)
    cast_expr(target_type: ..., value: ...)
    reinterpret_expr(target_type: ..., value: ...)
    propagation_expr(expr: ...)
    is_expr(expr: ..., variant_arm: ...)
    with_expr(struct_value: ..., updates: ...)
    proc_expr(params: ..., return_type: ..., body: ...)
    format_string_expr(segments: ...)

    # Types (used in both AST positions and type expressions)
    named_type(name: ..., type_args: ...)
    ptr_type(pointee: ...)
    const_ptr_type(pointee: ...)
    ref_type(pointee: ..., lifetime: ...)
    span_type(element: ...)
    array_type(element: ..., size: ...)
    nullable_type(inner: ...)
    fn_type(params: ..., return_type: ...)
    proc_type(params: ..., return_type: ...)
    tuple_type(elements: ...)
    dyn_type(interface: ...)
    soa_type(struct_type: ..., count: ...)
    str_buffer_type(capacity: ...)
    task_type(result: ...)
    atomic_type(inner: ...)
    void_type
```

### TypeRegistry

A global, append-only table of unique types. Types are identified by index handle. The registry supports lookups by structure (e.g., `ptr[int]` always maps to the same handle). Structural dedup uses hash keys like `("ptr", pointee_handle)`, `("nullable", inner_handle)`, etc.

```mt
struct TypeRegistry:
    types: vec.Vec[TypeEntry]
    primitives: map.Map[str, TypeHandle]             # "int" → handle
    structural_cache: map.Map[TypeKey, TypeHandle]   # dedup by structure

variant TypeKey:
    ptr_key(pointee: TypeHandle)
    const_ptr_key(pointee: TypeHandle)
    ref_key(pointee: TypeHandle, lifetime: ...)
    span_key(element: TypeHandle)
    array_key(element: TypeHandle, size: ptr_uint)
    nullable_key(inner: TypeHandle)
    fn_key(params: vec.Vec[TypeHandle], return_type: TypeHandle)
    proc_key(params: vec.Vec[TypeHandle], return_type: TypeHandle)
    tuple_key(elements: vec.Vec[TypeHandle])
    dyn_key(interface: SymbolHandle)
    soa_key(struct_type: TypeHandle, count: ptr_uint)
    str_buffer_key(capacity: ptr_uint)
    task_key(result: TypeHandle)
    atomic_key(inner: TypeHandle)
    type_var_key(name: str)                          # generic type parameter
    lifetime_var_key(name: str)                      # lifetime parameter (@a)

variant TypeEntry:
    primitive(kind: PrimitiveKind)
    pointer(pointee: TypeHandle)
    const_pointer(pointee: TypeHandle)
    reference(pointee: TypeHandle, lifetime: LifetimeHandle)
    span(element: TypeHandle)
    array(element: TypeHandle, size: ptr_uint)
    nullable(inner: TypeHandle)
    function_ptr(params: vec.Vec[TypeHandle], return_type: TypeHandle)
    proc(params: vec.Vec[TypeHandle], return_type: TypeHandle)
    tuple(elements: vec.Vec[TypeHandle])
    dyn(interface_handle: SymbolHandle)
    soa(struct_type: TypeHandle, count: ptr_uint)
    str_buffer(capacity: ptr_uint)
    task(result: TypeHandle)
    atomic(inner: TypeHandle)
    named(name: str, type_args: vec.Vec[TypeArg])   # unresolved named type
    struct(module_id: uint, name: str, type_params: vec.Vec[TypeParamHandle], fields: ..., is_packed: bool, alignment: ptr_uint, is_external: bool, linkage_name: str)
    generic_struct_def(module_id: uint, name: str, type_params: vec.Vec[TypeParamHandle])  # template
    struct_instance(def: TypeHandle, type_args: vec.Vec[TypeHandle])                       # instantiated
    union(module_id: uint, name: str, fields: ..., is_external: bool, linkage_name: str)
    variant(module_id: uint, name: str, type_params: vec.Vec[TypeParamHandle], arms: ...)
    generic_variant_def(module_id: uint, name: str, type_params: vec.Vec[TypeParamHandle])
    variant_instance(def: TypeHandle, type_args: vec.Vec[TypeHandle])
    variant_arm_payload(variant: TypeHandle, arm_index: uint)    # synthetic struct for `as name`
    enum(module_id: uint, name: str, backing_type: TypeHandle, members: ..., is_external: bool, linkage_name: str)
    flags(module_id: uint, name: str, backing_type: TypeHandle, members: ..., is_external: bool, linkage_name: str)
    opaque(module_id: uint, name: str, is_external: bool, linkage_name: str)
    interface(module_id: uint, name: str, type_params: vec.Vec[TypeParamHandle], methods: ...)
    type_var(name: str, constraints: vec.Vec[TypeHandle])       # generic type parameter T
    value_type_param(name: str)                                   # generic value param N: int
    error_sentinel                                               # marker for type-check failures
    null_literal(target: TypeHandle?)                            # null literal type for inference
    void
```

Layout information (size, alignment) is stored in a side table `map.Map[TypeHandle, TypeLayout]` computed during declaration resolution. Concrete types (primitives, struct instances, arrays) have known layouts. Type variables and generic definitions have no layout until instantiation.

### SymbolTable

Per-module symbol tables, plus a global index for cross-module resolution.

```mt
struct Symbol:
    name: str
    kind: SymbolKind
    visibility: Visibility        # public / private
    module_id: uint
    declaration: ...              # handle to the resolved declaration

enum SymbolKind: ubyte
    function
    struct
    variant
    enum
    flags
    union
    opaque
    interface
    type_alias
    const
    var
    event
    attribute
    module
    extending_method
    type_param
    local_variable

struct Scope:
    parent: ref[Scope]?
    symbols: std.map.Map[str, Symbol]
    owner: ...                    # the function/struct/module this scope belongs to
```

### TypedAST

The AST after type-checking. Every expression node carries a resolved `TypeHandle`. Every identifier is resolved to its `Symbol`. Generic declarations have their constraint information available.

The TypedAST reuses the same node variants as the raw AST, but with additional resolved data attached via side tables (node_id → type, node_id → symbol) to avoid changing the AST structure.

```mt
struct TypedAST:
    root: AstNode                # the module root, same structure
    node_types: map.Map[NodeId, TypeHandle]
    node_symbols: map.Map[NodeId, SymbolHandle]
    resolved_types: vec.Vec[ResolvedType]   # concrete types for generic instantiations
```

### MonomorphizedAST

A flat set of monomorphized functions, structs, and variants. All generic parameters have been substituted with concrete arguments. Compile-time evaluation has been performed — `const` values are concrete, `when` branches are pruned, `inline for`/`while` bodies are unrolled, `emit` directives have been expanded.

```mt
struct MonomorphizedAST:
    functions: vec.Vec[MonomorphizedFunction]
    structs: vec.Vec[MonomorphizedStruct]
    variants: vec.Vec[MonomorphizedVariant]
    constants: vec.Vec[ConstantValue]

struct MonomorphizedFunction:
    name: str
    module_id: uint
    params: vec.Vec[ParamInfo]
    return_type: TypeHandle
    body: AstNode                # with all inlines expanded, whens pruned
    is_async: bool
    is_external: bool
```

### CIR (C Intermediate Representation)

A thin, C-like IR. No SSA, no basic blocks. Annotations for scope exit labels (defer), cleanup flags.

```mt
variant CIRNode:
    # Top-level
    cir_module(declarations: ...)

    # Declarations
    cir_struct(name: ..., fields: ..., is_packed: bool, alignment: ...)
    cir_union(name: ..., fields: ...)
    cir_enum(name: ..., backing_type: ..., members: ...)
    cir_function(name: ..., return_type: ..., params: ..., body: ...)
    cir_variable(name: ..., type: ..., init: ...)

    # Statements
    cir_block(stmts: ...)
    cir_if(condition: ..., then_block: ..., else_block: ...)
    cir_while(condition: ..., body: ...)
    cir_for(init: ..., condition: ..., increment: ..., body: ...)
    cir_switch(value: ..., cases: ..., default_case: ...)
    cir_assign(target: ..., value: ...)
    cir_return(value: ...)
    cir_break
    cir_continue
    cir_goto(label: ...)
    cir_label(name: ...)
    cir_call(name: ..., args: ...)
    cir_expr_stmt(expr: ...)
    cir_defer_cleanup(label: ...)   # marks scope exit point for deferred cleanup
    cir_fatal(message: ...)         # abort with message

    # Expressions
    cir_identifier(name: ...)
    cir_literal(kind: ..., value: ...)
    cir_binary(op: ..., left: ..., right: ...)
    cir_unary(op: ..., operand: ...)
    cir_member(object: ..., field: ...)
    cir_index(object: ..., index: ...)
    cir_cast(target_type: ..., value: ...)
    cir_ternary(condition: ..., then_val: ..., else_val: ...)
    cir_sizeof(type: ...)
    cir_alignof(type: ...)
    cir_offsetof(type: ..., field: ...)
```

### Diagnostics Engine

```mt
enum DiagLevel: ubyte
    error
    warning
    note

struct Diag:
    level: DiagLevel
    location: SourceLocation
    message: str

struct DiagEngine:
    diagnostics: vec.Vec[Diag]
    error_count: uint
    warning_count: uint
```

---

## Phase Details

### Phase 1: Source Loading

- Read `package.toml`, resolve dependency graph via `package.lock`
- For each package in topological order, for each source file: resolve platform-specific variant (e.g., `main.linux.mt` over `main.mt`), read file content
- Populate `SourceManager` with all source files

### Phase 2: Lexer

- Indentation-aware: track indent stack, emit INDENT/DEDENT tokens
- Reject tabs, enforce 4-space multiples, single-indent-at-a-time
- Handle line continuation after binary operators
- Handle `#` comments, `##` doc comments
- Recognize keywords via trie/map lookup
- Produce `vec.Vec[Token]` per module

**Key challenge**: The lexer must produce NEWLINE tokens at statement boundaries but suppress them inside `()` and `[]`, and after line-ending binary operators. The Ruby lexer (`core/lexer.rb`) implements this with an indent stack and a continuation-tracking flag.

### Phase 3: Parser

- Recursive descent, consuming from the `TokenStream`
- Python-style block parsing: after `:` at end of line, expect INDENT, parse statements until DEDENT
- Handle inline single-statement form: `if cond: stmt`
- Handle inline `else if` / `else:` on same line
- Desugar `elif` style to nested `if`/`else`
- Desugar `is` expressions to `match` during parsing
- Handle format strings: parse `f"..."` into segment list (literal text + `#{expr}` interpolations)
- Handle heredocs: `<<-TAG ... TAG`
- Parse generic type arguments `[T, U]` and integer arguments `[N]`
- Parse `when`, `inline`, `unsafe`, `defer`, `parallel for`, `parallel:`, `detach`/`gather`
- Best-effort error recovery: skip to next statement boundary on parse errors

**Porting note**: The Ruby parser is split across `core/parser.rb` and the `parser/` subdirectory (expressions, statements, declarations, blocks, attributes, type_parsing, recovery). The recursion-descent shape ports cleanly to Milk Tea — each parse function returns an AstNode or `Option[AstNode]`.

### Phase 4: Name Resolution

- Build per-module `Scope` trees (module scope → function scope → block scope)
- Register all top-level declarations in the module's scope
- For imports: resolve `a.b.c` to `(package_instance_id, module_name)`; register alias
- Walk the AST, resolving each identifier — check local scopes first, then module scope, then imported modules
- Verify visibility — references to private declarations from other modules are errors
- Resolve type annotations: `str`, `int`, `ptr[T]`, `array[T, N]`, etc.
- Handle forward references: function body can reference a later function in the same module

**Porting note**: The Ruby compiler does this in `core/module_binder.rb` and `core/module_loader.rb`. The self-host will combine these into a simpler pass since it processes all modules eagerly.

### Phase 5: Declaration Collection

- Walk all module ASTs, collect all top-level type declarations (struct, variant, enum, flags, union, opaque, interface, type alias)
- Register them in the global `TypeRegistry` with forward-reference placeholders (cyclic references between types must be resolved)
- Compute type sizes and layouts (`size_of`, `align_of`, `offset_of`) for concrete types
- For generic types: register the generic template but defer layout computation until instantiation

**Porting note**: The Ruby compiler handles this in `core/types/registry.rb` and `core/types/layout.rb`. The lookup-by-structure pattern (finding or creating a type by its structural components) must be implemented in the self-host's `TypeRegistry`.

### Phase 6: Type Checking

- Check each declaration in each module
- Statement checking: verify conditions are `bool`, loop variables are valid, `match` exhaustiveness, `return` type compatibility
- Expression checking: infer types for `let`, coercions at expected type positions, binary operator type compatibility, call argument compatibility
- Interface conformance checking: for each `implements` clause, verify all required methods exist with matching signatures on the implementing type
- Generic constraint checking: verify generic bodies satisfy their `implements` constraints (e.g., `T implements Damageable` → `target.is_alive()` is valid)
- Nullability checking: track null state through control flow (nullable local becomes non-null after `if x != null`)
- Definite assignment analysis: verify all locals are assigned before use
- Record resolved types and symbols on each AST node via side tables (the `TypedAST` structure above)

**Porting note**: The Ruby compiler splits this across `core/semantic_analyzer.rb` and the `semantic/` subdirectory. The self-host can use a single `TypeChecker` module with sub-passes for statements, expressions, and declarations.

### Phase 6: Lowering to CIR — Pass 1 (Types and Globals)

Lower all type declarations and top-level values to CIR. No function bodies yet — this ensures all types exist before body lowering.

- Lower struct/union/enum/flags/variant/opaque declarations to CIR type definitions
- Compute concrete layouts for monomorphized types
- Lower constants and global variables with their evaluated initializers
- Lower static_assert conditions (already evaluated in sema)
- Produce per-module CIR fragments containing type definitions

### Phase 7: Lowering to CIR — Pass 2 (Function Bodies)

Lower all function bodies to CIR. This pass iterates to a fixed point because lowering a function body may discover new generic instantiations or `emit`-generated declarations that need lowering.

For each function (including monomorphized generic instances):
- Lower the body statements and expressions
- Desugar constructs per the table below
- For `emit` directives: the emitted declaration was already collected in sema (phase 5h) and added to the global declaration set; lower it here

Fixed-point loop:
1. For each unlowered function, lower its body
2. If lowering discovers new generic instantiations, add them to the queue
3. If lowering expands `emit` declarations that need lowering, add them to the queue
4. Repeat until queue is empty (bounded at ~1000 iterations to detect bugs)

**Desugaring table:**

| Source construct | CIR lowering |
|---|---|
| `if`/`else` | `cir_if` (if/else chain) |
| `while` loop | `cir_while` |
| `for x in 0..N` | `cir_for` with counter variable |
| `for x in array/span` | `cir_for` over index + bounds-checked access |
| `for x in iterable` | iterator protocol: `iter()` → `next()` loop |
| `match` on enum | `cir_switch` with enum member cases |
| `match` on variant | `cir_switch` on discriminant tag + payload struct field access |
| `match` on integer | `cir_switch` with integer literal cases |
| `match` on str | `cir_if` chain with `str.equal()` comparisons |
| `defer` statement | scope-exit label + cleanup code at all exit points (return, break, continue) |
| `unsafe` block | strip unsafe marker — contents lowered normally |
| `parallel for` | libuv work dispatch + barrier |
| `parallel:` block | libuv fork-join |
| `detach`/`gather` | libuv thread spawn + join |
| `async function` | state machine struct + step function (see async lowering below) |
| `await` | state machine suspension point (state transition + return) |
| `proc` closure | environment struct holding captured locals + function pointer pair |
| `extending` method call | plain namespaced function call (`Module_Type_method(args)`) |
| `variant` arm constructor | tag assignment + payload field initialization |
| `str_buffer[N]` | fixed array `char buf[N+1]` + length field |
| `array` bounds check | inject `fatal()` on out-of-bounds for safe indexing |
| `span` bounds check | inject `fatal()` on out-of-bounds |
| `f"..."` | expand to `fmt.append_int`/`append_str`/`append_bool` etc. calls |
| `expr?` propagation | generate `if (is_error) return error;` early return |
| `v.with(x = 10)` | copy struct + field assignment |
| `is` variant test | discriminant tag comparison |
| `read(r)` | `(*ptr)` C dereference |
| `ptr_of(x)` / `ref_of(x)` | `&x` address-of |
| `null` | `NULL` or `{0}` depending on context |
| `Event.subscribe` | event slot management calls |
| `Event.emit` | active slot iteration + callback dispatch |
| `static_assert` | `_Static_assert(cond, msg)` in C11 |

**Async lowering**:
Each `async function` becomes:
1. A state machine struct holding all locals that live across `await` points (identified by liveness analysis)
2. A state enum with one variant per `await` point (plus entry/exit)
3. A `step` function implementing a `switch(state)` dispatch — each `await` becomes a case label that returns to the scheduler
4. A compiler-generated entry function that allocates the state machine and pushes it to the async runtime

**Proc closure lowering**:
1. Walk the proc body, collect all referenced locals from enclosing scopes (capture analysis)
2. Create an environment struct with fields for each captured local
3. Rewrite captured local references in the proc body to `env->field`
4. Generate a C function with the env struct as first parameter
5. At the call site (capture point): allocate env struct, copy captured values, pass as first arg
6. For captured `proc` values: reference-count (retain on capture, release on env free)

### Phase 8: Assemble Modules

Merge all per-module CIR fragments into a single `CIR::Program`.

- Merge type definitions (deduplicate by linkage name)
- Merge function definitions
- Generate cross-module synthetics:
  - Event initialization functions (one per event declaration)
  - Cross-module event dispatch routing
  - Async runtime bootstrap integration
- Resolve type references across module boundaries (convert module-qualified references to flat C names)
- The assembled `CIR::Program` is the complete input to code generation

### Phase 9: C Code Generation

Three sub-phases executed sequentially on the assembled CIR:

**9a. Feature Detection**

Walk the CIR program once to determine what to emit. Collect flags:

| Feature flag | Triggers |
|---|---|
| `uses_string_view` | Any `str` value in expressions → emit `mt_str` type, string helpers |
| `uses_fatal_helper` | Any `fatal()` call or bounds check → emit `mt_fatal()` |
| `uses_format_string` | Any `f"..."` or format builder call → emit `mt_format_*` helpers |
| `uses_async_function` | Any `async function` → emit task struct, async memory helpers |
| `uses_parallel_for` | Any `parallel for` → link libuv, emit work dispatch helper |
| `uses_parallel_block` | Any `parallel:` → link libuv, emit spawn-all helper |
| `uses_detach` | Any `detach` → link libuv, emit detach helpers |
| `uses_variant` | Any variant type → emit variant equality helpers per type |
| `uses_proc` | Any proc expression → emit proc env alloc/free helpers |
| `uses_event` | Any event declaration → emit event slot table + emit helpers |
| `uses_text_buffer` | Any `str_buffer[N]` → emit text buffer helpers |
| `uses_checked_index` | Any safe array/span indexing → emit bounds-check helpers |
| `uses_vector_math` | Any vec/mat/quat → emit vector math type definitions |
| `uses_entrypoint_argv` | `main()` with params → emit argv processing helpers |
| `uses_mtpack` | Asset pack usage → link mtpack reader |

**9b. Dead Code Elimination**

Reachability analysis from entry points:
- Entry points: `main()`, `async main()`, event init functions
- Worklist algorithm: start from entry functions, mark reachable, follow type references
- For each reachable function: mark its return type, parameter types, local types, called functions, referenced struct/union/enum/variant types
- For each reachable type: mark all field types, recursively
- Only emit types and functions marked as reachable

**9c. Code Generation**

Emit C source text in order:
1. Feature macros (`#define _GNU_SOURCE`, `#define _DEFAULT_SOURCE`, etc.)
2. `#include` directives (deduplicated, auto-added for detected features)
3. String type definition (`mt_str`) if string views are used
4. Vector/matrix/quaternion math type definitions if used
5. Runtime helpers (fatal, format engines, string equality, bounds checks, text buffer, async memory, parallel for, spawn-all, detach, entrypoint argv, variant equality)
6. Forward declarations of all aggregate types (opaque struct, then struct, union, variant)
7. Enum definitions
8. Span type definitions (generated per element type)
9. SoA type definitions (generated per element type)
10. Aggregate type definitions (struct, union, variant) in topological order — a struct's fields must be defined before the struct itself
11. Function forward declarations
12. Constants and global variables
13. `_Static_assert` declarations
14. String literal constants (deduplicated)
15. Function definitions

After emission, invoke the external C compiler (`cc` for native, `emcc` for wasm) with platform-appropriate flags.

**Porting note**: The Ruby C backend is in `core/c_backend.rb` and `c_backend/`. Feature detection maps to `feature_detection.rb`. Dead code elimination maps to `dead_code_elimination.rb`. Runtime helpers map to `runtime_helpers.rb`. The emission order and type sorting map to `c_backend.rb` and `aggregate_sort.rb`.

---

## File Layout

All self-host compiler source lives under `projects/mtc/`, following the standard Milk Tea package convention.
Main module files sit at `src/<name>.mt`, with supporting submodules inside `src/<name>/<sub>.mt`.
Sub-modules that haven't been split out yet are marked with `*`.

```
projects/mtc/
  package.toml
  src/
    main.mt                             # CLI entrypoint (parse args, dispatch)
    # ---------------------------------------------------------------------------
    # Infrastructure
    # ---------------------------------------------------------------------------
    context/
      source_manager.mt                 # SourceManager, SourceLocation, SourceFile
      diagnostic.mt                     # Diag, DiagEngine, source context formatting
      arena.mt                          # Compiler arena wrapper (re-exports std.mem.arena)
      interner.mt                       # StringInterner for symbol names
      node_id.mt                        # NodeId generation for TypedAST side tables
    # ---------------------------------------------------------------------------
    # Lexer
    # ---------------------------------------------------------------------------
    lexer.mt                            # Indentation-aware lexer
    lexer/
      token.mt                          # TokenKind, Token, keyword lookup table
      token_stream.mt                   # TokenStream (peek/advance/check/match interface)
    # ---------------------------------------------------------------------------
    # Parser
    # ---------------------------------------------------------------------------
    parser.mt                           # Top-level recursive-descent parser *
    parser/
      ast.mt                            # All AST node variants (every node has SourceLocation)
      blocks.mt                         # Indentation block protocol
      expressions.mt *                  # Expression parsing
      statements.mt *                   # Statement parsing
      declarations.mt *                 # Declaration parsing (struct, enum, function, etc.)
      type_parsing.mt *                 # Type expression parsing
      attributes.mt *                   # @[attr(args)] parsing
      recovery.mt *                     # Error recovery (synchronize to boundaries)
    # ---------------------------------------------------------------------------
    # Name Resolution
    # ---------------------------------------------------------------------------
    resolver.mt                         # Name resolution pass (two-pass)
    resolver/
      symbol.mt                         # SymbolTable, Scope, Symbol, SymbolKind
      scope.mt *                        # ScopeTree (merged into symbol.mt)
    # ---------------------------------------------------------------------------
    # Semantic Analysis (phases 5a–5m; const eval + mono are interleaved here)
    # ---------------------------------------------------------------------------
    typeck.mt                           # Main semantic analysis driver *
    typeck/
      types.mt                          # TypeEntry, TypeRegistry, TypeHandle, TypeLayout
      compat.mt                         # Type compatibility and coercions
      primitives.mt *                   # PrimitiveKind enum, built-in type definitions
      builtins.mt *                     # Install built-in types + attributes
      prelude.mt *                      # Auto-import Option[T], Result[T, E]
      const_eval.mt *                   # Const evaluator (tree-walking interpreter)
      mono.mt *                         # Generic instantiation discovery + fixed-point loop
      decls.mt *                        # Declaration type-checking + forward-declare pass
      exprs.mt *                        # Expression type-checking + type inference
      stmts.mt *                        # Statement type-checking
      generics.mt *                     # Constraint checking (T implements I)
      interface_check.mt *              # Interface conformance verification
      flow.mt *                         # Nullability flow refinement for locals
      def_assign.mt *                   # Definite assignment analysis (CFG-based)
      cf_analysis.mt *                  # Reachability, termination, conditional return analysis
    # ---------------------------------------------------------------------------
    # Lowering to CIR (phases 6–8)
    # ---------------------------------------------------------------------------
    lower.mt                            # Lowering orchestrator (AST → CIR) *
    lower/
      cir.mt                            # CIR node types (non-recursive, flat)
      type_resolver.mt *                # Re-resolve TypeRef → TypeHandle during lowering
      assemble.mt *                     # Cross-module assembly + synthetic generation
      declarations.mt *                 # Type/const/global lowering (Pass 1)
      functions.mt *                    # Function body lowering (Pass 2)
      statements.mt *                   # Statement desugaring
      expressions.mt *                  # Expression lowering
      match.mt *                        # Match → switch/if-chain
      defer_cleanup.mt *                # Defer → scope-exit labels
      async.mt *                        # Async function → state machine
      events.mt *                       # Event declaration → slot table lowering
      proc_closures.mt *                # Proc → env struct + function pointer
      bounds.mt *                       # Array/span bounds check injection
      fmt_strings.mt *                  # Format string → append calls expansion
      str_buffer.mt *                   # str_buffer[N] → fixed array + length field
      foreign.mt *                      # Foreign function boundary lowering
      variant_constr.mt *               # Variant constructor → discriminant + payload
    # ---------------------------------------------------------------------------
    # C Code Generation (phase 9)
    # ---------------------------------------------------------------------------
    codegen/
      emit.mt                           # C codegen driver (CIR → C text) *
      feature_detect.mt *               # Pre-scan CIR for used features
      dce.mt *                          # Dead code elimination
      types.mt *                        # Type definition emission
      forward_decls.mt *                # Forward declaration emission (topological sort)
      functions.mt *                    # Function definition emission
      statements.mt *                   # Statement → C emission
      expressions.mt *                  # Expression → C emission
      runtime.mt *                      # Runtime helpers
      async_runtime.mt *                # Async runtime bootstrap
      events_runtime.mt *               # Event runtime (slot arrays, emit dispatch)
      variant_equality.mt *             # Variant equality helper generation
      aggregate_sort.mt *               # Topological sort of aggregate types
    # ---------------------------------------------------------------------------
    # Module Graph and Dependency Management
    # ---------------------------------------------------------------------------
    module/
      graph.mt *                        # Dependency graph, topological ordering, cycle detection
      loader.mt *                       # File path resolution, platform variants, package roots
    # ---------------------------------------------------------------------------
    # CLI
    # ---------------------------------------------------------------------------
    cli/
      build.mt                          # build command (load → lex → parse → lower → emit)
      check.mt                          # check command (load → lex → parse → resolve → typeck)
      options.mt                        # Shared CLI option parsing
      io.mt                             # File I/O helpers (read_file, write_file)
      run.mt *                          # run command (build + execute)
      lint.mt *                         # lint command
      deps.mt *                         # deps subcommands
```

---

## Bootstrap Strategy

The Ruby reference compiler (`bin/mtc`) is the bootstrap host. It compiles `projects/mtc/src/` into C, then into a native binary. The pipeline:

```
Phase 1: Ruby mtc → compiles projects/mtc/ → self-host mtc binary (v0.1)
Phase 2: self-host mtc → compiles projects/mtc/ → self-host mtc binary (v0.2 — self-hosting)
Phase 3: self-host mtc passes the full compiler test suite
```

### Milestones

| Milestone | Scope | Verification |
|-----------|-------|-------------|
| M1: Lexer | Tokenize all `.mt` files | Pass existing lexer tests |
| M2: Parser | Parse all `.mt` files to AST | Pass existing parser tests |
| M3: Resolve + TypeCheck (subset) | Name resolution + type checking for structs, functions, basic control flow | Compile `examples/language_baseline.mt` without errors |
| M4: Lowering (subset) | Desugar structs, functions, control flow to C | Generate valid C for M3's subset |
| M5: Full language | All declaration types, all statements, all expressions, generics, interfaces, variants | Pass all `test/compiler/` tests |
| M6: Const-eval | `const`, `const function`, `inline`, `when`, `emit`, reflection builtins | Pass compile-time evaluation tests |
| M7: Self-hosting | The self-host binary compiles `projects/mtc/` again, producing a working binary | The re-compiled binary passes M5+M6 |
| M8: Full parity | Async, events, parallel constructs, format strings, proc closures | Pass all compiler, tooling, and std tests |

### Porting Approach

For each Ruby compiler module, port the logic (not the Ruby-isms) to Milk Tea:

- **Lexer** (`core/lexer.rb`, `core/token.rb`, `core/token_stream.rb`): Port the indentation algorithm and token recognition. The Ruby lexer's indent stack and continuation tracking are well-tested; follow them directly.

- **Parser** (`core/parser.rb`, `parser/*.rb`): Port the recursive-descent structure. Each Ruby `parse_*` method becomes a Milk Tea function returning `AstNode`. Use Milk Tea's `variant` for AST nodes (natural mapping from Ruby classes).

- **Type system** (`core/types/*.rb`): Port the type registry with structural dedup. The Ruby approach of keying types by their structural components maps naturally to a Milk Tea hash map from type descriptor strings to handles.

- **Sema** (`core/semantic_analyzer.rb`, `semantic/*.rb`): Port the per-declaration/per-statement checking. The separation between expression checking and statement checking is worth preserving.

- **Const-eval** (`core/compile_time/*.rb`): Port the stack-based interpreter. The Ruby const evaluator operates on IR nodes; consider evaluating directly on TypedAST to avoid an extra lowering step.

- **Lowering** (`core/lowering.rb`, `lowering/*.rb`): Port the desugaring rules. Each lowering function maps one AST variant to one or more IR nodes.

- **C backend** (`core/c_backend.rb`, `c_backend/*.rb`): Port the C text emission. The CIR in the self-host replaces the Ruby compiler's IR (`core/ir.rb`), so the codegen walks CIR nodes instead.

---

## What NOT To Build (v1 Exclusion List)

- No incremental compilation — rebuild from source each time
- No multi-threaded compilation — single-threaded is sufficient
- No query system or demand-driven architecture
- No CST (Concrete Syntax Tree) phase — AST with source locations is enough
- No formatter port (the Ruby formatter stays in `bin/mtc fmt` until v2)
- No LSP integration in the self-host binary (delegated to the Ruby LSP in v1)
- No SSA or optimization passes — the C compiler handles this
- No cross-compilation host detection beyond what the Ruby CLI already supports
- No self-hosted bindgen (retain Ruby bindgen for v1)
- No `--bundle` or `--archive` packaging (these are Ruby CLI features, not compiler features)
- No `std.fmt.format_value[T]` specialization for all types (port primitives first, extend incrementally)
- No full `--keep-c` path management beyond a single output directory

---

## Implementation Order

Modules are listed in dependency order. Each number is a module that can be implemented and tested once its dependencies exist. The goal at each step is a compilable, testable increment.

### Stage 1: Skeleton — compile a trivial `.mt` file to C

| # | Module | Dependencies | Tests |
|---|--------|-------------|-------|
| 1 | `context/arena.mt` | `std.mem.arena` | None (thin wrapper) |
| 2 | `context/source_manager.mt` | arena | Can load and store source files |
| 3 | `context/diagnostic.mt` | source_manager | Can format errors with source context |
| 4 | `context/interner.mt` | `std.str`, `std.map` | String dedup works |
| 5 | `lexer/token.mt` | interner | TokenKind + keyword lookup correct |
| 6 | `lexer/lexer.mt` | token, diagnostic | INDENT/DEDENT/NEWLINE generation |
| 7 | `lexer/token_stream.mt` | token | peek/advance/check/match |
| 8 | `parser/ast.mt` | token | All AST variants defined |
| 9 | `parser/parser/blocks.mt` | token_stream, ast | Block protocol (colon+indent) |
| 10 | `parser/parser/expressions.mt` (minimal) | ast, token_stream, blocks | Literals, identifiers, basic operators |
| 11 | `parser/parser/statements.mt` (minimal) | ast, token_stream | `if`, `while`, `return`, `let`/`var` |
| 12 | `parser/parser/declarations.mt` (minimal) | ast, token_stream | `function`, `struct`, `const`, `var` |
| 13 | `parser/parser/type_parsing.mt` (minimal) | ast, token_stream | Named types, `ptr[T]` |
| 14 | `parser/parser.mt` | all parser/* | Top-level parse_file → AST |
| 15 | `parser/parser/recovery.mt` | parser | Error recovery (synchronize to boundaries) |
| 16 | `typeck/types.mt` | `std.map` | TypeRegistry, TypeHandle, primitive layout |
| 17 | `typeck/primitives.mt` | types | PrimitiveKind enum, type definitions |
| 18 | `typeck/builtins.mt` | types, primitives | Install ptr, span, array, str_buffer, etc. |
| 19 | `typeck/prelude.mt` | builtins | Auto-import Option, Result |
| 20 | `resolve/scope.mt` | `std.map`, interner | Scope, ScopeTree |
| 21 | `resolve/symbol.mt` | scope | Symbol, SymbolKind, global SymbolTable |
| 22 | `resolve/resolver.mt` | symbol, ast | Name resolution (AST → identifiers bound to Symbols) |
| 23 | `typeck/typeck/compat.mt` | types | Type compatibility, coercion rules |
| 24 | `typeck/const_eval.mt` | types, symbol | Const evaluator (literals, identifiers, arithmetic) |
| 25 | `typeck/typeck/decls.mt` | types, symbol, compat | Forward-declare types, resolve fields |
| 26 | `typeck/typeck/stmts.mt` | types, symbol, compat | Statement type-checking |
| 27 | `typeck/typeck/exprs.mt` | types, symbol, compat, const_eval | Expression type-checking + inference |
| 28 | `typeck/typeck/generics.mt` | types, symbol, compat | Constraint T implements I checking |
| 29 | `typeck/typeck/def_assign.mt` | types | Definite assignment analysis |
| 30 | `typeck/typeck/cf_analysis.mt` | types | Reachability, termination |
| 31 | `typeck/typeck.mt` | all typeck/* | Semantic analysis orchestrator |
| 32 | `lower/cir.mt` | types | All CIR node variants |
| 33 | `lower/type_resolver.mt` | types | TypeRef → TypeHandle (for lowerer) |
| 34 | `lower/lower/declarations.mt` | cir, type_resolver | Struct/const/global → CIR |
| 35 | `lower/lower/statements.mt` | cir, type_resolver | Statement desugaring |
| 36 | `lower/lower/expressions.mt` | cir, type_resolver | Expression → CIR |
| 37 | `lower/lower/functions.mt` | cir, type_resolver, statements, expressions | Function body lowering |
| 38 | `lower/lower.mt` | all lower/* | Lowering orchestrator (two-pass) |
| 39 | `codegen/feature_detect.mt` | cir | Feature flag detection |
| 40 | `codegen/dce.mt` | cir | Dead code elimination |
| 41 | `codegen/emit/runtime.mt` | cir | Runtime helpers (fatal, string eq, bounds check) |
| 42 | `codegen/emit/aggregate_sort.mt` | cir | Topological sort of types |
| 43 | `codegen/emit/forward_decls.mt` | cir | Forward declaration emission |
| 44 | `codegen/emit/types.mt` | cir | Type definition emission |
| 45 | `codegen/emit/statements.mt` | cir | Statement → C text |
| 46 | `codegen/emit/expressions.mt` | cir | Expression → C text |
| 47 | `codegen/emit/functions.mt` | cir, statements, expressions | Function → C text |
| 48 | `codegen/emit.mt` | all codegen/* | C codegen driver |
| 49 | `module/loader.mt` | `std.fs` | File resolution, platform variants |
| 50 | `module/graph.mt` | loader | Dependency graph, topo-sort |
| 51 | `cli/options.mt` | std | CLI option parsing |
| 52 | `cli/build.mt` | all compiler modules, options | Build command |
| 53 | `cli/run.mt` | build, options | Run command |
| 54 | `cli/check.mt` | lexer, parser, typeck, options | Check command (no C output) |
| 55 | `main.mt` | cli/* | CLI entry point |

At this point, the compiler can compile and run simple programs (structs, functions, basic control flow).

### Stage 2: Full declaration and statement surface

| # | Module | Adds |
|---|--------|------|
| 56 | `parser/parser/declarations.mt` (full) | enum, flags, union, variant, opaque, interface, extending, event, attribute, foreign, external, static_assert, emit, when, const function, async |
| 57 | `parser/parser/statements.mt` (full) | match, when, inline for/while/if/match, parallel for, parallel:, detach/gather, defer, unsafe, break/continue, pass |
| 58 | `parser/parser/expressions.mt` (full) | match-expr, if-expr, proc, tuple, variant literal, cast, reinterpret, ?, is, with, format string, specialization |
| 59 | `parser/parser/type_parsing.mt` (full) | fn/proc types, tuple types, dyn[T], SoA[T,N], atomic[T], nullable, const_ptr, ref, span |
| 60 | `parser/parser/attributes.mt` | @[attr(args)] parsing on declarations |
| 61 | `typeck/typeck/interface_check.mt` | Interface conformance verification |
| 62 | `typeck/typeck/flow.mt` | Nullability flow refinement |
| 63 | `typeck/mono.mt` | Generic instantiation discovery + expansion loop |
| 64 | `lower/lower/match.mt` | Match → switch/if-chain |
| 65 | `lower/lower/defer_cleanup.mt` | Defer → scope-exit labels |
| 66 | `lower/lower/events.mt` | Event declaration → slot table |
| 67 | `lower/lower/proc_closures.mt` | Proc → env struct + function |
| 68 | `lower/lower/bounds.mt` | Bounds check injection |
| 69 | `lower/lower/fmt_strings.mt` | Format string → append calls |
| 70 | `lower/lower/str_buffer.mt` | str_buffer → array + length |
| 71 | `lower/lower/foreign.mt` | Foreign function boundary lowering |
| 72 | `lower/lower/variant_constr.mt` | Variant constructor lowering |
| 73 | `lower/assemble.mt` | Cross-module assembly + synthetics |
| 74 | `codegen/emit/variant_equality.mt` | Variant equality helpers per type |

### Stage 3: Advanced features

| # | Module | Adds |
|---|--------|------|
| 75 | `lower/lower/async.mt` | Async function → state machine (with liveness analysis + normalization) |
| 76 | `codegen/emit/async_runtime.mt` | Async runtime: state machine allocation, scheduler |
| 77 | `codegen/emit/events_runtime.mt` | Event runtime: slot tables, emit dispatch |
| 78 | `cli/lint.mt` | Lint command |
| 79 | `cli/deps.mt` | Deps subcommands |

### Stage 4: Self-hosting

Compile `projects/mtc/` with the self-host binary. Fix any bugs exposed by the full language surface being compiled through itself. Iterate until the self-compiled binary passes all tests.

---

## Risk Areas

### Generic Instantiation Fixed-Point Loop

Monomorphization discovers instantiations transitively: calling `foo[int]` inside the body of `bar[T]` when `T = str` discovers `foo[str]`. The loop must detect completion correctly and must not loop infinitely.

**Mitigation**: Cap iterations (1000). Track a `changed` flag per iteration. Log which instantiations are discovered per round during debug builds. The Ruby compiler uses `@lowered_linkages` cache and a simple worklist.

### Const Dependency Cycles

`const A: int = B + 1; const B: int = A - 1` must be detected and rejected.

**Mitigation**: Maintain an `@evaluating_const_values` set (by symbol name). Before evaluating a const, check membership — if present, report a cycle error. The Ruby compiler uses a Set of names plus a Set of `object_id`s.

### Arena Lifetime Management

Cross-module references (one module's Symbol pointing to another module's type) must not become dangling when module arenas are freed.

**Mitigation**: The global `SymbolTable` and `TypeRegistry` live in their own arenas (not per-module). Module arenas hold only per-module data (AST nodes, local scopes). Cross-module references go through the global tables by handle (integer index), not by pointer.

### String Interning

Symbol names (function names, field names, type names) appear repeatedly. Without interning, string allocation and comparison dominates compile time.

**Mitigation**: A `StringInterner` — a hash set mapping `str` → interned pointer. All symbols store interned strings. The interner and symbol table share the same long-lived arena. The Ruby compiler gets this "for free" from Ruby's string intern pool.

### Error Recovery During Parsing

Without synchronization, one parse error cascades into hundreds of bogus errors.

**Mitigation**: On parse error, report the error, then skip tokens until a synchronizing token: top-level keyword at indent 0 for top-level recovery, statement keyword at current indent for statement recovery, or DEDENT/EOF. This is ~100 lines of code and dramatically improves error quality.

### Proc Closure Capture Analysis

Analyzing which locals are captured by a `proc` expression, creating the environment struct, and rewriting references is subtle. Nested procs and captured proc values add complexity.

**Mitigation**: Port the Ruby algorithm directly from `lowering/proc.rb`:
1. Walk proc body, collect all referenced locals from enclosing scopes
2. Create env struct with fields for each captured local
3. Rewrite captured references to `env->field`
4. At the capture point, populate env struct
5. For captured proc values: reference-count (retain/release)
6. Write focused unit tests for each edge case (scalar capture, array capture, proc capture, nested proc)

### Type Layout Computation

Computing `size_of`, `align_of`, `offset_of` for structs with nested types, packed attributes, and alignment overrides requires careful implementation. Self-referential types (via pointers) and variant layout (tagged union) add complexity.

**Mitigation**: Port `core/types/layout.rb` directly. The algorithm is well-defined: iterate fields in declaration order, align each field, sum sizes, pad to max alignment. Variant layout: tag (int, 4 bytes) + union of arm payloads (max arm size). Recursive types: pointer fields store `ptr[T]` which has fixed pointer size, not the struct size — no infinite recursion.

### Async Liveness Analysis

Determining which local variables are live across `await` points requires a dataflow analysis over the function body.

**Mitigation**: Port `lowering/async_analysis.rb`. The analysis marks each local as "live across await" if it is written before and read after any await point. The state machine struct only needs to save live-across-await locals; other locals stay on the C stack.

### Cross-Module Type Visibility

When module A's struct references module B's type in a field, and module B's struct references module A's type, there's a circular dependency that requires forward declarations in C.

**Mitigation**: The `aggregate_sort.mt` module handles this by emitting opaque struct forward declarations first, then full definitions in topological order. Self-referential structs (via pointers) are always possible since pointer size is known. For value-type cycles, emit an error during sema (circular type dependency).

---

## Reference: Ruby Compiler Module Map

For porting reference, the key Ruby compiler modules and their paths:

| Ruby file | Purpose | Maps to self-host module |
|-----------|---------|--------------------------|
| `core/keywords.rb` | Keyword lookup | `lexer/token.mt` |
| `core/token.rb` | Token data classes | `lexer/token.mt` |
| `core/token_stream.rb` | Token stream with peek | `lexer/token_stream.mt` |
| `core/lexer.rb` | Indentation-aware lexer | `lexer/lexer.mt` |
| `core/cst.rb`, `core/cst_builder.rb` | CST phase | N/A (skipped in v1) |
| `core/ast.rb` | AST node definitions | `parser/ast.mt` |
| `core/parser.rb` + `parser/*.rb` | Recursive-descent parser | `parser/parser.mt` + `parser/*.mt` |
| `core/module_binder.rb` | Name resolution | `resolve/resolver.mt` |
| `core/module_loader.rb` + `module_loader/*.rb` | Module graph + loading | `module/loader.mt`, `module/graph.mt` |
| `core/types/types.rb` | Type system core | `typeck/types.mt` |
| `core/types/registry.rb` | Type interning/registry | `typeck/types.mt` |
| `core/types/layout.rb` | Type size/alignment/offset | `typeck/types.mt` |
| `core/types/predicates.rb` | Type kind predicates | `typeck/types.mt` |
| `core/semantic_analyzer.rb` | Type checker driver | `typeck/typeck.mt` |
| `semantic/*.rb` | Statement/expression/decl checking | `typeck/typeck/*.mt` |
| `core/cfg.rb` + `cfg/*.rb` | Control flow graph analyses | `typeck/typeck/def_assign.mt`, `typeck/typeck/cf_analysis.mt` |
| `core/compile_time.rb` + `compile_time/*.rb` | Const evaluation | `typeck/const_eval.mt` |
| `core/lowering.rb` + `lowering/*.rb` | AST→IR lowering | `lower/lower.mt` + `lower/*.mt` |
| `core/ir.rb` | IR node definitions | `lower/cir.mt` |
| `core/c_backend.rb` + `c_backend/*.rb` | C code generation | `codegen/emit.mt` + `codegen/emit/*.mt` |
| (various) | Feature detection | `codegen/feature_detect.mt` |
| (various) | Dead code elimination | `codegen/dce.mt` |
| (various) | Runtime helpers | `codegen/emit/runtime.mt` + `async_runtime.mt` + `events_runtime.mt` |
| (various) | Type emission order | `codegen/emit/aggregate_sort.mt` |
| (various) | String interning | `context/interner.mt` |
| `core/prelude_installer.rb` | Prelude installation | `typeck/prelude.mt` |
| `core/binding_types.rb` | Foreign function boundary types | `lower/lower/foreign.mt` |

---

## Testing Strategy

The self-host compiler must pass the same test suite as the Ruby compiler. Test categories:

| Category | Path | What it tests |
|----------|------|---------------|
| Lexer | `test/compiler/lexer_test.rb`* | Tokenization correctness |
| Parser | `test/compiler/parser_test.rb`* | AST structure correctness |
| CST | `test/compiler/cst_test.rb`* | N/A for v1 |
| CFG | `test/compiler/cfg_test.rb`* | Definite assignment, reachability |
| Lowering | `test/compiler/lowering_test.rb`* | Correct desugaring |
| Semantic | `test/compiler/semantic/*` | Type checking, inference, interface checks |
| C Backend | `test/compiler/c_backend_test.rb`* | C output correctness |
| Stdlib | `test/std/` | Runtime behavior of all std modules |
| Examples | `test/examples/` | End-to-end compilation and execution of examples |

*The self-host test runner should accept the same test input formats (`.mt` snippets with expected errors/outputs) but will need its own test harness written in Milk Tea. The Ruby compiler's test infrastructure (`test/compiler/` test cases) should be translatable to a format the self-host test runner can consume.

For each milestone, the verification column above describes which tests must pass. Final acceptance is: the self-host binary, when pointed at `projects/mtc/`, produces a binary that itself passes the full test suite.
