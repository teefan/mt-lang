## IR — flat C-oriented intermediate representation.

public struct IrParam:
    name: str
    type_c: str


public struct IrFunction:
    name: str
    params: span[IrParam]
    return_c: str
    body: span[IrStmt]


public struct IrProgram:
    functions: span[IrFunction]


public variant IrStmt:
    return_stmt(value: IrExpr)
    expr_stmt(expr: IrExpr)
    decl(name: str, type_c: str, init: IrExpr)


public variant IrExpr:
    integer(value: int)
    name(name: str)
    binary(op: str, left: ptr[IrExpr], right: ptr[IrExpr])
    call(name: str, args: span[IrExpr])
