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

public const STMT_FUNCTION: int = 1
public const STMT_STRUCT: int = 2
public const STMT_CONST: int = 3
public const STMT_LET: int = 4
public const STMT_RETURN: int = 5
public const STMT_EXPR: int = 6
public const STMT_IF: int = 7
public const STMT_WHILE: int = 8
public const STMT_FOR: int = 9
public const STMT_ASSIGN: int = 10
public const STMT_DEFER: int = 11
public const STMT_ENUM: int = 12
public const STMT_VARIANT: int = 13
public const STMT_FLAGS: int = 14
public const STMT_OPAQUE: int = 15
public const STMT_INTERFACE: int = 16
public const STMT_TYPE_ALIAS: int = 17
public const STMT_VAR: int = 18
public const STMT_EMPTY: int = 0


public struct Statement:
    kind: int
    name: str
    stmt_type: TypeRef
    expr: int
    expr2: int
    op_kind: int
    is_inline: bool
    children: vec.Vec[Statement]
    else_body: vec.Vec[Statement]
    bindings: vec.Vec[str]
    line: int
    column: int


# ── expressions ─────────────────────────────────────────────────────

# Pool-based expression tree — expressions are stored in a flat vec,
# children referenced by integer index to avoid recursive inline types.
# Expression 0 is the sentinel / empty expression.

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


public function expr_pool_create() -> ExpressionPool:
    var pool = ExpressionPool(exprs = vec.Vec[Expression].create())
    pool.exprs.push(Expression(kind = EXPR_ERROR, int_value = 0,
        float_value = 0.0, str_value = "", bool_value = false, ident = "",
        op_kind = 0, lhs_idx = 0, rhs_idx = 0, callee_idx = 0,
        args = vec.Vec[ptr_uint].create(), line = 0, column = 0))
    return pool


public function expr_pool_alloc(pool: ref[ExpressionPool], expr: Expression) -> ptr_uint:
    let idx = pool.exprs.len()
    pool.exprs.push(expr)
    return idx


public struct SourceFile:
    module_name: str
    imports: vec.Vec[Import]
    declarations: vec.Vec[Statement]
    exprs: ExpressionPool