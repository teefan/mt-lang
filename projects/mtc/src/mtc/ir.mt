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
    pointer: bool


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
    expr_name(name: str, ty: types.Type, pointer: bool)
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


# =============================================================================
#  Statements (recursive — heap-allocated via ptr[Stmt])
# =============================================================================

public variant Stmt:
    stmt_local(name: str, linkage_name: str, ty: types.Type, value: ptr[Expr], line: ptr_uint, source_path: str)
    stmt_assignment(target: ptr[Expr], operator: str, value: ptr[Expr])
    stmt_block(body: span[Stmt])
    stmt_if(condition: ptr[Expr], then_body: span[Stmt], else_body: span[Stmt])
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
    )
