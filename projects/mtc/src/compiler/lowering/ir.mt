## IR — flat C-oriented intermediate representation.

public struct IrParam:
    name: str
    type_c: str


public struct IrFunction:
    name: str
    params: span[IrParam]
    return_c: str
    body: span[IrStmt]
    is_editable: bool


public struct IrField:
    name: str
    type_c: str


public struct IrStruct:
    name: str
    fields: span[IrField]


public struct IrMatchArm:
    values: span[IrExpr]
    body: span[IrStmt]


public struct IrEnumMember:
    name: str
    value: int


public struct IrEnum:
    name: str
    members: span[IrEnumMember]


public struct IrAggregateField:
    name: str
    value: IrExpr


public struct IrProgram:
    structs: span[IrStruct]
    enums: span[IrEnum]
    functions: span[IrFunction]


public variant IrStmt:
    return_stmt(value: IrExpr)
    return_void
    expr_stmt(expr: IrExpr)
    decl(name: str, type_c: str, init: IrExpr)
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
