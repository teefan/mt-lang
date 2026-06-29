import std.vec as vec
import typeck.types as types

public struct CirField:
    name: str
    type_handle: types.TypeHandle

public enum CirDeclKind: ubyte
    struct_decl  = 0
    union_decl   = 1
    enum_decl    = 2
    opaque_decl  = 3

public struct CirDecl:
    kind: CirDeclKind
    name: str
    fields: vec.Vec[CirField]
    backing_type: types.TypeHandle
    is_packed: bool
    alignment: ptr_uint

public enum CirStmtKind: ubyte
    block        = 0
    if_stmt      = 1
    while_stmt   = 2
    for_range    = 3
    return_stmt  = 4
    assign       = 5
    call         = 6
    expr_stmt    = 7
    break_stmt   = 8
    continue_stmt = 9
    label         = 10
    goto_label    = 11
    defer_cleanup = 12
    fatal_call    = 13

public struct CirStmt:
    kind: CirStmtKind
    cond: str
    init: str
    increment: str
    label: str
    value: str
    target: str
    callee: str
    message: str
    children: vec.Vec[ptr_uint]

public enum CirExprKind: ubyte
    identifier  = 0
    int_lit     = 1
    float_lit   = 2
    str_lit     = 3
    bool_lit    = 4
    null_lit    = 5
    binary      = 6
    unary       = 7
    call        = 8
    member      = 9
    index       = 10
    cast_expr   = 11
    sizeof_expr = 12
    struct_lit  = 13

public struct CirExpr:
    kind: CirExprKind
    name: str
    op: str
    str_value: str
    int_value: int
    bool_value: bool
    type_handle: types.TypeHandle
    left: ptr_uint
    right: ptr_uint
    struct_name: str
    field_indices: vec.Vec[ptr_uint]

public struct CirFunction:
    name: str
    params: vec.Vec[CirField]
    return_type: types.TypeHandle
    stmts: vec.Vec[CirStmt]
    exprs: vec.Vec[CirExpr]
    root_stmt: uint

public struct CirProgram:
    decls: vec.Vec[CirDecl]
    functions: vec.Vec[CirFunction]

extending CirProgram:
    public static function create() -> CirProgram:
        return CirProgram(
            decls = vec.Vec[CirDecl].create(),
            functions = vec.Vec[CirFunction].create()
        )

    public editable function add_function(f: CirFunction) -> void:
        this.functions.push(f)

    public editable function release() -> void:
        var i: ptr_uint = 0
        while i < this.decls.len():
            let dp = this.decls.get(i) else:
                fatal(c"cir.release missing decl")
            unsafe:
                read(dp).fields.release()
            i += 1
        this.decls.release()
        i = 0
        while i < this.functions.len():
            let fp = this.functions.get(i) else:
                fatal(c"cir.release missing function")
            unsafe:
                read(fp).params.release()
                var j: ptr_uint = 0
                while j < read(fp).stmts.len():
                    let sp = read(fp).stmts.get(j) else:
                        fatal(c"cir.release missing stmt")
                    unsafe:
                        read(sp).children.release()
                    j += 1
                read(fp).stmts.release()
                j = 0
                while j < read(fp).exprs.len():
                    let ep = read(fp).exprs.get(j) else:
                        fatal(c"cir.release missing expr")
                    unsafe:
                        read(ep).field_indices.release()
                    j += 1
                read(fp).exprs.release()
            i += 1
        this.functions.release()
