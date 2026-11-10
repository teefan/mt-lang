## Intermediate representation (IR) — the decoupling contract between the
## Lowering stage (Analysis -> IR) and the C backend (IR -> C source).
##
## Mirrors the Ruby compiler's IR (lib/milk_tea/core/ir.rb) node-for-node.
## Program-level declarations are value structs held in typed spans; recursive
## statements and expressions are variants reached through ptr[Stmt] / ptr[Expr].
##
## This module is intentionally pure data: no lowering or emission logic lives
## here, so both stages depend only on this frozen shape and never on each
## other's internals.

import mtc.semantic.types as types


# =============================================================================
#  Leaf value types
# =============================================================================

public struct Include:
    header: str


public struct Field:
    name: str
    ty: types.Type


public struct Param:
    name: str
    linkage_name: str
    ty: types.Type
    # The host's `IR::Param#pointer`: `nil` when the constructor omitted it
    # (a plain function's params — the async ctor params in particular),
    # `some(true)` for a pointer-lowered parameter (an editable receiver).
    pointer: Option[bool]


public struct EnumMember:
    name: str
    linkage_name: str
    value: ptr[Expr]


public struct AggregateField:
    name: str
    value: ptr[Expr]


public struct VariantArm:
    name: str
    linkage_name: str
    fields: span[Field]


## One arm of a lowered switch.  `is_default` selects the C `default:` case, in
## which `value` is null; ordinary cases carry a literal `value`.
public struct SwitchCase:
    is_default: bool
    value: ptr[Expr]?
    body: span[Stmt]


# =============================================================================
#  Expressions (recursive — heap-allocated via ptr[Expr])
# =============================================================================

public variant Expr:
    expr_name(name: str, ty: types.Type, pointer: Option[bool])
    expr_member(receiver: ptr[Expr], member: str, ty: types.Type)
    expr_index(receiver: ptr[Expr], index: ptr[Expr], ty: types.Type)
    expr_checked_index(receiver: ptr[Expr], index: ptr[Expr], receiver_type: types.Type, ty: types.Type)
    expr_checked_span_index(receiver: ptr[Expr], index: ptr[Expr], receiver_type: types.Type, ty: types.Type)
    expr_nullable_index(receiver: ptr[Expr], index: ptr[Expr], receiver_type: types.Type, ty: types.Type)
    expr_nullable_span_index(receiver: ptr[Expr], index: ptr[Expr], receiver_type: types.Type, ty: types.Type)
    expr_call(callee: str, arguments: span[Expr], ty: types.Type)
    expr_call_indirect(callee: ptr[Expr], arguments: span[Expr], ty: types.Type)
    expr_unary(operator: str, operand: ptr[Expr], ty: types.Type)
    expr_binary(operator: str, left: ptr[Expr], right: ptr[Expr], ty: types.Type)
    expr_conditional(condition: ptr[Expr], then_expression: ptr[Expr], else_expression: ptr[Expr], ty: types.Type)
    expr_reinterpret(target_type: types.Type, source_type: types.Type, expression: ptr[Expr], ty: types.Type)
    expr_sizeof(target_type: types.Type, ty: types.Type)
    expr_alignof(target_type: types.Type, ty: types.Type)
    expr_offsetof(target_type: types.Type, field: str, ty: types.Type)
    expr_integer_literal(value: long, ty: types.Type)
    ## An integer literal whose source lexeme does not fit a signed `long`
    ## (`18446744073709551615`, `0xFFFFFFFFFFFFFFFF`).  The host keeps Ruby's
    ## unbounded value, so it stays positive and renders in the unsigned domain;
    ## a signed `long` can only hold the same bit pattern, hence the separate
    ## node.  A *computed* value keeps `expr_integer_literal` — the host folds
    ## `~0` to `-1` and prints `-1` for the same `ptr_uint` type — so the
    ## distinction is provenance, not type or value.
    expr_unsigned_integer_literal(value: ptr_uint, ty: types.Type)
    expr_float_literal(value: double, ty: types.Type)
    expr_string_literal(value: str, ty: types.Type, cstring: bool)
    expr_boolean_literal(value: bool, ty: types.Type)
    expr_null_literal(ty: types.Type)
    expr_zero_init(ty: types.Type)
    expr_address_of(expression: ptr[Expr], ty: types.Type)
    expr_cast(target_type: types.Type, expression: ptr[Expr], ty: types.Type)
    expr_aggregate_literal(ty: types.Type, fields: span[AggregateField])
    expr_variant_literal(ty: types.Type, arm_name: str, fields: span[AggregateField])
    expr_array_literal(ty: types.Type, elements: span[Expr])
    ## GCC/Clang statement-expression `({ setup...; result; })`.  Used to lower a
    ## dynamic format string in expression position without a separate hoist pass.
    expr_stmt_expr(setup: span[Stmt], result: ptr[Expr], ty: types.Type)
    ## An assignment in *expression* position — the host's `IR::Assignment`
    ## wrapped by an `IR::ExpressionStmt` (its `build_async_cancel_function`
    ## stores `cancelled`/`ready` this way).  The self models statements and
    ## expressions as separate variants, so the expression-position form is its
    ## own variant.
    expr_assignment(target: ptr[Expr], operator: str, value: ptr[Expr])
    ## `simd[E, N].with(lane, value)` — the host's `IR::SimdLaneWith`: a copy of
    ## `src` with one lane replaced (emitted as a statement expression).
    expr_simd_lane_with(src: ptr[Expr], index: ptr[Expr], value: ptr[Expr], ty: types.Type)


# =============================================================================
#  Statements (recursive — heap-allocated via ptr[Stmt])
# =============================================================================

public variant Stmt:
    stmt_local(name: str, linkage_name: str, ty: types.Type, value: ptr[Expr], line: ptr_uint, source_path: str)
    stmt_assignment(target: ptr[Expr], operator: str, value: ptr[Expr])
    stmt_block(body: span[Stmt])
    stmt_if(condition: ptr[Expr], then_body: span[Stmt], else_body: Option[span[Stmt]])
    stmt_switch(expression: ptr[Expr], cases: span[SwitchCase], exhaustive: bool)
    stmt_while(condition: ptr[Expr], body: span[Stmt])
    stmt_for(init: ptr[Stmt], condition: ptr[Expr], post: ptr[Stmt], body: span[Stmt])
    stmt_break
    stmt_continue
    stmt_goto(label: str)
    stmt_label(name: str)
    stmt_static_assert(condition: ptr[Expr], message: ptr[Expr])
    stmt_return(value: ptr[Expr]?, line: ptr_uint, source_path: str)
    stmt_expression(expression: ptr[Expr], line: ptr_uint, source_path: str)


# =============================================================================
#  Program-level declarations
# =============================================================================

public struct Constant:
    name: str
    linkage_name: str
    ty: types.Type
    value: ptr[Expr]
    # Source location (const declaration line + module path), surfaced by the
    # `--sexpr` IR dump.
    line: ptr_uint
    path: str


public struct Global:
    name: str
    linkage_name: str
    ty: types.Type
    value: ptr[Expr]


public struct OpaqueDecl:
    name: str
    linkage_name: str
    forward_declarable: bool
    source_module: Option[str]


public struct StructDecl:
    name: str
    linkage_name: str
    fields: span[Field]
    packed: bool
    alignment: int
    source_module: Option[str]


public struct UnionDecl:
    name: str
    linkage_name: str
    fields: span[Field]
    source_module: Option[str]


public struct EnumDecl:
    name: str
    linkage_name: str
    backing_type: types.Type
    members: span[EnumMember]
    is_flags: bool


public struct VariantDecl:
    name: str
    linkage_name: str
    arms: span[VariantArm]
    source_module: Option[str]


public struct StaticAssert:
    condition: ptr[Expr]
    message: ptr[Expr]


public struct Function:
    name: str
    linkage_name: str
    params: span[Param]
    return_type: types.Type
    body: span[Stmt]
    entry_point: bool
    ## True for a `public` top-level function.  The C backend keeps that
    ## linkage internal for executables (the host's shape) and exports it when
    ## building a library (`build --kind static|shared`).
    public_export: bool
    method_receiver_param: bool


# =============================================================================
#  Program root
# =============================================================================

public struct Program:
    module_name: str
    includes: span[Include]
    constants: span[Constant]
    globals: span[Global]
    opaques: span[OpaqueDecl]
    structs: span[StructDecl]
    unions: span[UnionDecl]
    enums: span[EnumDecl]
    variants: span[VariantDecl]
    static_asserts: span[StaticAssert]
    functions: span[Function]
    type_aliases: span[TypeAlias]
    source_path: str
    # Concrete generic struct instances.  The host does not carry these in the
    # IR's declaration sections; its C backend collects them from the types in
    # use.  This compiler keeps the resolved fields here for the C backend,
    # which merges them into the declaration list it sorts and emits.
    monomorphized_structs: span[StructDecl]
    # Concrete Option/Result instances, likewise resolved by lowering but kept
    # outside the IR's `:variants` section (host parity).
    monomorphized_variants: span[VariantDecl]
    # Field layouts of external (raw-module ABI) structs that participate in
    # aggregate equality (`joint != b2.b2_nullJointId`).  Raw modules emit only
    # includes, so their structs have no IR declarations; the host reads the
    # fields from its type objects, and this compiler carries them here for the
    # C backend's `mt_struct_eq_*` helper synthesis.  Not a declaration
    # section: the dumper ignores it and no C declaration is emitted for it.
    external_structs: span[ExternalStructLayout]
    ## The synthetic `str_buffer[N]` structs the lowering registers: the host
    ## collects them from the type universe and the C backend emits them, so
    ## they ride here rather than in `:structs`.  The dumper ignores the field.
    str_buffer_structs: span[StructDecl]


## One external struct's field layout, keyed by `naming.type_c_key` so the C
## backend can find it from the type in an equality comparison.
public struct ExternalStructLayout:
    key: str
    fields: span[Field]


public struct TypeAlias:
    name: str
    qualified_name: str
    target_type: types.Type
    backing_c_name: Option[str]
## result and a convenient base for incremental assembly.
public function empty_program(module_name: str, source_path: str) -> Program:
    return Program(
        module_name = module_name,
        includes = span[Include](),
        constants = span[Constant](),
        globals = span[Global](),
        opaques = span[OpaqueDecl](),
        structs = span[StructDecl](),
        unions = span[UnionDecl](),
        enums = span[EnumDecl](),
        variants = span[VariantDecl](),
        static_asserts = span[StaticAssert](),
        functions = span[Function](),
        source_path = source_path,
        monomorphized_structs = span[StructDecl](),
        monomorphized_variants = span[VariantDecl](),
        external_structs = span[ExternalStructLayout](),
        str_buffer_structs = span[StructDecl](),
    )


## True when the program declares a C entrypoint (a lowered root `main` with a
## supported executable signature).  Mirrors Ruby's
## `ir_program.functions.any?(&:entry_point)`, which Build uses to decide whether
## a target is an executable.
public function has_entrypoint(program: Program) -> bool:
    var i: ptr_uint = 0
    while i < program.functions.len:
        unsafe:
            if read(program.functions.data + i).entry_point:
                return true
        i += 1
    return false
