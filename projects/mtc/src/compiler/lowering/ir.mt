## IR — flat C-oriented intermediate representation.
##
## Types are represented as reg.TypeId (canonical integer IDs from
## the type registry). The C backend resolves TypeId → C name at
## emission time, enabling type-based decisions (zero-init, switch
## vs if/else, . vs ->).

import compiler.sema.type_registry as reg

type TypeId = reg.TypeId

public struct IrParam:
    name: str
    type_id: TypeId


public struct IrFunction:
    name: str
    params: span[IrParam]
    return_type: TypeId
    body: span[IrStmt]
    is_editable: bool


public struct IrField:
    name: str
    type_id: TypeId


public struct IrStruct:
    name: str
    type_id: TypeId
    fields: span[IrField]


public struct IrMatchArm:
    values: span[IrExpr]
    body: span[IrStmt]


public struct IrEnumMember:
    name: str
    value: int


public struct IrEnum:
    name: str
    type_id: TypeId
    members: span[IrEnumMember]


public struct IrAggregateField:
    name: str
    value: IrExpr


public struct IrVariantArm:
    name: str
    fields: span[IrField]


public struct IrVariant:
    name: str
    type_id: TypeId
    arms: span[IrVariantArm]


public struct IrProgram:
    structs: span[IrStruct]
    enums: span[IrEnum]
    variants: span[IrVariant]
    functions: span[IrFunction]


public variant IrStmt:
    return_stmt(value: IrExpr)
    return_void
    expr_stmt(expr: IrExpr)
    decl(name: str, type_id: TypeId, init: IrExpr)
    assign(target: str, op_kind: str, value: IrExpr)
    assign_expr(target: IrExpr, op_kind: str, value: IrExpr)
    if_stmt(condition: IrExpr, then_body: span[IrStmt], else_body: span[IrStmt])
    while_stmt(condition: IrExpr, body: span[IrStmt])
    for_stmt(binding: str, iterable: IrExpr, body: span[IrStmt])
    for_range(binding: str, start: IrExpr, end: IrExpr, body: span[IrStmt])
    break_stmt
    continue_stmt
    match_stmt(scrutinee: IrExpr, arms: span[IrMatchArm])
    block(stmts: span[IrStmt])


public variant IrExpr:
    integer(value: int)
    name(name: str)
    null_value
    unary(op: str, operand: ptr[IrExpr])
    binary(op: str, left: ptr[IrExpr], right: ptr[IrExpr])
    call(name: str, args: span[IrExpr])
    access(receiver: ptr[IrExpr], member: str)
    ptr_access(receiver: ptr[IrExpr], member: str)
    deref(operand: ptr[IrExpr])
    address(operand: ptr[IrExpr])
    aggregate(name: str, fields: span[IrAggregateField])
    cast_expr(type_c: str, operand: ptr[IrExpr])
