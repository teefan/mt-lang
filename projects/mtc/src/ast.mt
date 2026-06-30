import std.vec as vec


public struct QualifiedName:
    parts: vec.Vec[str]


public struct Import:
    path: QualifiedName
    alias_name: str
    line: int
    column: int


# ── types ───────────────────────────────────────────────────────────

public struct TypeRef:
    name_parts: vec.Vec[str]
    type_args: vec.Vec[TypeRef]
    nullable: bool
    is_function_type: bool


public struct Param:
    name: str
    param_type: TypeRef


# ── statements ──────────────────────────────────────────────────────

public variant Statement:
    empty
    function_decl(name: str, ret: TypeRef, params: vec.Vec[Param], body: vec.Vec[Statement])
    struct_decl(name: str, fields: vec.Vec[Statement])
    struct_field(name: str, ftype: TypeRef)
    const_decl(name: str, ctype: TypeRef, value_idx: ptr_uint)
    let_decl(name: str, ltype: TypeRef, value_idx: ptr_uint)
    return_stmt(value_idx: ptr_uint)
    if_stmt(cond_idx: ptr_uint, body: vec.Vec[Statement], else_body: vec.Vec[Statement])
    while_stmt(cond_idx: ptr_uint, body: vec.Vec[Statement])
    for_stmt(binding: str, body: vec.Vec[Statement])
    assign_stmt(target_idx: ptr_uint, op_kind: int, value_idx: ptr_uint)
    expr_stmt(value_idx: ptr_uint)
    defer_stmt(body: vec.Vec[Statement])
    enum_decl(name: str, backing: TypeRef, members: vec.Vec[Statement])
    variant_decl(name: str)
    opaque_decl(name: str)
    interface_decl(name: str)
    type_alias_decl(name: str, target: TypeRef)
    var_decl(name: str, vtype: TypeRef, value_idx: ptr_uint)
    union_decl(name: str, fields: vec.Vec[Statement])
    extending_block(name: str, methods: vec.Vec[Statement])
    static_assert_stmt(cond_idx: ptr_uint, message: str)
    attribute_decl(name: str, params: vec.Vec[Statement])
    event_decl(name: str, capacity: ptr_uint)
    when_stmt(name: str, body: vec.Vec[Statement])
    extern_function_decl(name: str, ret: TypeRef)


# ── expressions ─────────────────────────────────────────────────────

public const EXPR_INTEGER: int = 0
public const EXPR_FLOAT: int = 1
public const EXPR_STRING: int = 2
public const EXPR_BOOLEAN: int = 3
public const EXPR_NULL: int = 4
public const EXPR_IDENTIFIER: int = 5
public const EXPR_BINARY: int = 6
public const EXPR_CALL: int = 7
public const EXPR_UNARY: int = 8
public const EXPR_MEMBER: int = 9
public const EXPR_IF: int = 10
public const EXPR_ERROR: int = 11


public struct Expression:
    kind: int
    int_value: int
    float_value: float
    str_value: str
    bool_value: bool
    ident: str
    op_kind: int
    lhs_idx: ptr_uint
    rhs_idx: ptr_uint
    callee_idx: ptr_uint
    args: vec.Vec[ptr_uint]
    line: int
    column: int


public struct ExpressionPool:
    exprs: vec.Vec[Expression]


public struct SourceFile:
    module_name: str
    imports: vec.Vec[Import]
    declarations: vec.Vec[Statement]
    exprs: ExpressionPool