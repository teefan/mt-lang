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
              Type Checker  ──>  Monomorphizer + Const Eval
                                       │
                                       ▼
                                   Lowering  ──>  CIR  ──>  C Codegen
```

### Pass Order (Module-at-a-Time)

The compiler loads modules eagerly in topological order (leaves to root, resolved from `package.lock`). Each pass completes fully across all modules before the next begins.

1. **Load source files** — resolve module graph, platform-specific variants, open and read all `.mt` files
2. **Lex** — produce token streams with indentation tokens (INDENT, DEDENT, NEWLINE)
3. **Parse** — produce per-module ASTs (arena-allocated `variant` nodes)
4. **Resolve names** — build per-module symbol tables; resolve all identifiers to declarations; verify visibility (`public`/private); produce ResolvedAST
5. **Collect declarations** — register all top-level type, function, and constant declarations across modules
6. **Type-check** — check all declarations eagerly; infer `let`/`var` types; verify interface conformance; check generic bodies against constraints (no instantiation yet); produce TypedAST
7. **Monomorphize and const-eval** — from the entry point, discover all reachable generic instantiations; evaluate `const` bodies, `const function`, `inline for`/`while`/`if`/`match`, `when` branches, and `emit` directives; discovered instantiations feed back into monomorphization; produce MonomorphizedAST
8. **Lower to CIR** — desugar all high-level constructs into a C-like IR; evaluate CFG analyses (definite assignment, reachability, termination); produce CIR
9. **Emit C** — pretty-print CIR to `.c` files; run the external C compiler (`cc`, `emcc`, etc.)

Module-at-a-time ordering means: after the initial symbol-table gathering pass (step 4), each module's type-checking (step 6) and lowering (step 8) can proceed independently. Monomorphization and const-eval (step 7) is naturally cross-module since generic instantiations cross module boundaries.

### Pipeline Diagram

```
┌─────────────┐     ┌───────────┐     ┌───────────┐     ┌─────────────┐
│ Source .mt  │────>│ Lexer     │────>│ Parser    │────>│ Resolver    │
│ files       │     │ TokenStrm │     │ AST       │     │ SymbolTable │
└─────────────┘     └───────────┘     └───────────┘     └─────────────┘
                                                                │
        ┌───────────────────────────────────────────────────────┘
        ▼
┌──────────────────┐     ┌───────────────────┐     ┌─────────────────┐
│  Type Checker    │────>│  Monomorphizer    │────>│  Lowering       │
│  TypedAST        │     │  + ConstEval      │     │  (desugar)      │
│  TypeRegistry    │     │  MonomorphizedAST │     │  CFG analyses   │
└──────────────────┘     └───────────────────┘     └─────────────────┘
                                                           │
                                                           ▼
                                                   ┌─────────────────┐
                                                   │  C Codegen      │──> .c files
                                                   │  emit C source  │
                                                   └─────────────────┘
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

A global, append-only table of unique types. Types are identified by index handle. The registry supports lookups by structure (e.g., `ptr[int]` always maps to the same handle).

```mt
struct TypeRegistry:
    types: vec.Vec[TypeEntry]
    # hash maps for structural dedup: ptr_map, array_map, etc.

variant TypeEntry:
    primitive(kind: PrimitiveKind)
    pointer(pointee: TypeHandle)
    const_pointer(pointee: TypeHandle)
    reference(pointee: TypeHandle, lifetime: ...)
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
    named(name: str, type_params: vec.Vec[...], resolved: TypeHandle)  # after resolution
    opaque(name: str)
    void
```

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

### Phase 7: Monomorphization and Compile-Time Evaluation

This is the most complex phase. The monomorphizer and const evaluator are intertwined.

**Monomorphization:**
- Start from the program entry point (`main` or `async main`)
- For each call to a generic function with concrete type arguments, create a monomorphized copy
- For each use of a generic struct/variant with concrete type arguments, create a monomorphized copy
- Each new instantiation may discover more generic calls (recursive discovery)
- Compute concrete layouts (`size_of`, `align_of`, `offset_of`) for instantiated types

**Const evaluation:**
- An interpreter running on the TypedAST. It evaluates:
  - `const` block bodies (`const X -> T: ...`)
  - `const function` bodies called from const contexts
  - `inline for` / `inline while` / `inline match` / `inline if` — unroll/expand based on compile-time-known values
  - `when` discriminants and branch selection
  - `emit` directives — the emitted code is parsed and inserted into the output module
  - Built-in reflection calls: `size_of`, `align_of`, `offset_of`, `fields_of`, `members_of`, `attributes_of`, `has_attribute`, `attribute_of`, `attribute_arg[T]`, `field_of`, `callable_of`
  - `static_assert` evaluation

**Const evaluator design:**
- A stack-based bytecode interpreter or a recursive AST walker
- Must handle: arithmetic, comparisons, control flow (if/else, while, for), local `var` and `let`, function calls (including recursion within `const function`), array indexing, struct field access
- Must track a maximum iteration bound for `while` and `inline while` to prevent infinite loops at compile time

**Ordering:** The monomorphizer + const-eval loop runs:
1. Evaluate module-level `const` declarations (these may reference each other within a module)
2. Evaluate `when` blocks at module level — determine which branch is active
3. Discover entry-point reachable generic instantiations
4. For each instantiation: const-eval any `inline` constructs in the body, potentially discovering more instantiations
5. Repeat until no new instantiations are discovered

**Porting note**: The Ruby compiler implements this in `core/compile_time.rb` and `core/compile_time/const_eval.rb`. The const evaluator in particular is a self-contained interpreter that walks the IR (not AST) — the self-host may want to adopt a similar approach, evaluating on a simplified IR to reduce complexity.

### Phase 8: Lowering to CIR

Structural desugaring — no type analysis, just AST → CIR transformation:

| Source construct | CIR lowering |
|---|---|
| `if`/`else` | `cir_if` (if/else chain) |
| `while` loop | `cir_while` |
| `for x in 0..N` | `cir_for` with counter variable |
| `for x in array` | `cir_for` over index + bound check |
| `for x in span` | `cir_for` over index + bound check |
| `match` on enum | `cir_switch` with enum member cases |
| `match` on variant | `cir_switch` on discriminant + payload casts |
| `match` on integer | `cir_switch` with integer cases |
| `match` on str | `cir_if` chain with `str.equal()` |
| `defer` (single stmt) | inline at scope exit point + `cir_defer_cleanup` label |
| `defer` (block) | same, with block expansion |
| `unsafe` block | strip marker — contents lowered normally |
| `parallel for` | call into libuv thread dispatch + barrier |
| `parallel:` block | libuv fork-join |
| `detach`/`gather` | libuv thread spawn + join |
| `async function` | state machine struct + step function (see below) |
| `await` | state machine suspension point |
| `proc` closure | environment struct + function pointer pair |
| `extending` method call | plain namespaced function call |
| `variant` arm constructor | discriminant assignment + payload field init |
| `str_buffer[N]` | fixed array + length field |
| `array` bounds check | inject `fatal()` on out-of-bounds |
| `span` bounds check | inject `fatal()` on out-of-bounds |
| `f"..."` | expand to `std.fmt.append_int`/`append_str`/etc. calls |
| `expr?` | generate `if` check + early return |
| `v.with(x = 10)` | copy + field assignment |
| `is` variant test | discriminant comparison |
| `read(r)` | `(*ptr)` dereference |
| `ptr_of(x)` | `&x` |
| `null` | `NULL` or `{0}` |
| `Event.subscribe` | event slot management calls |
| `Event.emit` | slot iteration + callback dispatch |

**CFG analyses during lowering:**
- Definite assignment: verify all variables assigned before use
- Reachability: detect unreachable code (warnings)
- Termination analysis for `let ... else:` and `return` coverage
- These cross-reference the CFG to ensure control-flow validity before C emission

**Async lowering:**
Each `async function` becomes:
1. A state machine struct holding all locals that live across `await` points
2. A `step` function implementing the state machine — each `await` becomes a state transition + return
3. The compiler-generated `mt_async_*` entry function that creates the state machine and pushes it to the runtime

**Porting note**: The Ruby compiler's lowering is in `core/lowering.rb` and the `lowering/` subdirectory. The async lowering in particular (`lowering/async_normalization.rb`, `lowering/async_lowering.rb`, `lowering/async_analysis.rb`) is well-structured and should be ported closely. The CIR phase is shared between the lowering and the C backend in the Ruby compiler (`lowering/` handles AST→IR, `c_backend/` handles IR→C text). The self-host splits this into Lowering (AST→CIR) and Codegen (CIR→C text).

### Phase 9: C Code Generation

- Walk the CIR, emit C text to `.c` files
- Emit: includes, forward declarations, type definitions (struct/enum/union), function implementations
- Aggregate types sorted topologically (dependencies first)
- Generate `__attribute__((packed))` and `__attribute__((aligned(N)))` for layout-annotated types
- Generate async state machine structs and step functions
- Generate event tables and emit/slot management functions
- Generate `static_assert` as `_Static_assert` in C11
- Invoke external C compiler: `cc` (native) or `emcc` (wasm) with platform-appropriate flags

**Porting note**: The Ruby C backend is in `core/c_backend.rb` and `c_backend/`. The self-host C codegen mirrors this but operates on CIR nodes rather than the Ruby compiler's IR (`core/ir.rb`).

---

## File Layout

All self-host compiler source lives under `projects/mtc/`, following the standard Milk Tea package convention:

```
projects/mtc/
  package.toml                          # package.name = "mtc", kind = "application"
  src/
    main.mt                             # CLI entrypoint (parse args, dispatch to build/check/run/lint/deps)
    # ---------------------------------------------------------------------------
    # Infrastructure
    # ---------------------------------------------------------------------------
    context/
      source_manager.mt                 # SourceManager, SourceLocation, SourceFile
      diagnostic.mt                     # Diag, DiagEngine, formatting with source context
      arena.mt                          # Compiler arena wrapper (just uses std.mem.arena)
    # ---------------------------------------------------------------------------
    # Lexer
    # ---------------------------------------------------------------------------
    lexer/
      token.mt                          # TokenKind, Token, keyword lookup
      lexer.mt                          # Indentation-aware lexer
      token_stream.mt                   # TokenStream with peek/advance/rewind
    # ---------------------------------------------------------------------------
    # Parser
    # ---------------------------------------------------------------------------
    parser/
      ast.mt                            # AST node variants (AstNode, supporting structs)
      parser.mt                         # Top-level parser, file-level declarations
      parser/
        expressions.mt                  # Expression parsing
        statements.mt                   # Statement parsing
        declarations.mt                 # Declaration parsing (struct, enum, function, etc.)
        type_parsing.mt                 # Type expression parsing (ptr[T], array[T,N], fn(...)->R, etc.)
        blocks.mt                       # Indentation block handling
        attributes.mt                   # @[attr(args)] parsing
    # ---------------------------------------------------------------------------
    # Name Resolution
    # ---------------------------------------------------------------------------
    resolve/
      scope.mt                          # Scope, Symbol, SymbolTable
      resolver.mt                       # Name resolution pass (AST → ResolvedAST)
    # ---------------------------------------------------------------------------
    # Type System
    # ---------------------------------------------------------------------------
    typeck/
      types.mt                          # TypeEntry, TypeRegistry, TypeHandle, primitive kinds
      typeck.mt                         # Main type checker driver
      typeck/
        exprs.mt                        # Expression type checking
        stmts.mt                        # Statement type checking
        decls.mt                        # Declaration type checking
        generics.mt                     # Generic constraint checking
        compat.mt                       # Type compatibility, coercions
        interface_check.mt              # Interface conformance verification
        flow.mt                         # Nullability flow refinement
        def_assign.mt                   # Definite assignment analysis
    # ---------------------------------------------------------------------------
    # Monomorphization and Compile-Time Evaluation
    # ---------------------------------------------------------------------------
    mono/
      monomorphize.mt                   # Generic instantiation discovery + expansion
    eval/
      interp.mt                         # Const evaluator interpreter
    # ---------------------------------------------------------------------------
    # Lowering to CIR
    # ---------------------------------------------------------------------------
    lower/
      cir.mt                            # CIR node variants
      lower.mt                          # Main lowering pass (TypedAST → CIR)
      lower/
        functions.mt                    # Function lowering
        statements.mt                   # Statement desugaring
        expressions.mt                  # Expression lowering
        declarations.mt                 # Type declaration lowering
        async.mt                        # Async function state machine lowering
        events.mt                       # Event slot management lowering
        proc_closures.mt                # Proc capture and closure lowering
        bounds.mt                       # Bounds check injection
        fmt_strings.mt                  # Format string expansion
        str_buffer.mt                   # str_buffer[N] lowering
        cf_analysis.mt                  # CFG-based analyses (def assign, reach, term)
    # ---------------------------------------------------------------------------
    # C Code Generation
    # ---------------------------------------------------------------------------
    codegen/
      emit.mt                           # CIR → C text emission
      emit/
        types.mt                        # Type definition emission (struct, enum, union)
        functions.mt                    # Function emission
        statements.mt                   # Statement emission
        expressions.mt                  # Expression emission
        async_runtime.mt                # Async runtime integration (state machine, bootstrapping)
        events_runtime.mt               # Event runtime (slot tables, emit/dispatch)
        runtime.mt                      # Runtime helpers (fatal, bounds-check abort, nullptr guards)
    # ---------------------------------------------------------------------------
    # Module Graph and Dependency Management
    # ---------------------------------------------------------------------------
    module/
      graph.mt                          # Dependency graph, topological ordering
      loader.mt                         # File/path resolution, platform variants, root resolution
    # ---------------------------------------------------------------------------
    # CLI
    # ---------------------------------------------------------------------------
    cli/
      build.mt                          # build command
      run.mt                            # run command
      check.mt                          # check command (lex+parse+typeck only, no C output)
      lint.mt                           # lint command
      deps.mt                           # deps subcommands (tree, lock, add, remove, update, fetch, publish)
      options.mt                        # Shared CLI option parsing
    # ---------------------------------------------------------------------------
    # Utils (project-local helpers shared across phases)
    # ---------------------------------------------------------------------------
    utils/
      interner.mt                       # String interner (shared across phases for symbol names)
      node_id.mt                        # NodeId generation for TypedAST side tables
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
| `core/cfg.rb` + `cfg/*.rb` | Control flow graph analyses | `lower/cf_analysis.mt` |
| `core/compile_time.rb` + `compile_time/*.rb` | Const evaluation | `eval/interp.mt` |
| `core/lowering.rb` + `lowering/*.rb` | AST→IR lowering | `lower/lower.mt` + `lower/*.mt` |
| `core/ir.rb` | IR node definitions | `lower/cir.mt` |
| `core/c_backend.rb` + `c_backend/*.rb` | C code generation | `codegen/emit.mt` + `codegen/emit/*.mt` |

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
