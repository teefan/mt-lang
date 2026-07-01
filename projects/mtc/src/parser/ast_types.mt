import std.vec

public struct Import:
    path: str
    alias: str

public struct Param:
    name: str
    param_type: str

public type ExprIdx = ptr_uint
public const EXPR_NULL: ExprIdx = 0

public type TypeExprIdx = ptr_uint
public const TYPE_EXPR_NULL: TypeExprIdx = 0

public variant Expr:
    error_node
    literal_int(value: str, start_off: ptr_uint, end_off: ptr_uint)
    literal_float(value: str, start_off: ptr_uint, end_off: ptr_uint)
    literal_string(value: str, start_off: ptr_uint, end_off: ptr_uint)
    literal_cstring(value: str, start_off: ptr_uint, end_off: ptr_uint)
    literal_fstring(value: str, start_off: ptr_uint, end_off: ptr_uint)
    literal_char(value: str, start_off: ptr_uint, end_off: ptr_uint)
    literal_bool(value: bool, start_off: ptr_uint, end_off: ptr_uint)
    literal_null(start_off: ptr_uint, end_off: ptr_uint)
    identifier(name: str, start_off: ptr_uint, end_off: ptr_uint)
    binary(op: str, left: ExprIdx, right: ExprIdx, start_off: ptr_uint, end_off: ptr_uint)
    unary(op: str, operand: ExprIdx, start_off: ptr_uint, end_off: ptr_uint)
    prefix_cast(cast_type: str, operand: ExprIdx, start_off: ptr_uint, end_off: ptr_uint)
    postfix_access(member: str, start_off: ptr_uint, end_off: ptr_uint)
    postfix_call(start_off: ptr_uint, end_off: ptr_uint)
    postfix_index(start_off: ptr_uint, end_off: ptr_uint)
    postfix_propagate(start_off: ptr_uint, end_off: ptr_uint)
    if_expr(cond: ExprIdx, then_branch: ExprIdx, else_branch: ExprIdx, start_off: ptr_uint, end_off: ptr_uint)
    match_expr(scrutinee: ExprIdx, start_off: ptr_uint, end_off: ptr_uint)
    proc_expr(start_off: ptr_uint, end_off: ptr_uint)
    unsafe_expr(body: ExprIdx, start_off: ptr_uint, end_off: ptr_uint)
    await_expr(operand: ExprIdx, start_off: ptr_uint, end_off: ptr_uint)
    detach_expr(operand: ExprIdx, start_off: ptr_uint, end_off: ptr_uint)
    builtin_call(name: str, start_off: ptr_uint, end_off: ptr_uint)
    offset_of_call(type_name: str, field_name: str, start_off: ptr_uint, end_off: ptr_uint)
    group(inner: ExprIdx, start_off: ptr_uint, end_off: ptr_uint)
    range_op(left: ExprIdx, right: ExprIdx, start_off: ptr_uint, end_off: ptr_uint)
    as_expr(scrutinee: ExprIdx, variant_arm: str, start_off: ptr_uint, end_off: ptr_uint)

public variant TypeExpr:
    error_type
    named(qualified_name: str, start_off: ptr_uint, end_off: ptr_uint)
    pointer(target: str, is_const: bool, start_off: ptr_uint, end_off: ptr_uint)
    ref_type(annot: str, target: str, start_off: ptr_uint, end_off: ptr_uint)
    array_type(element: str, size: str, start_off: ptr_uint, end_off: ptr_uint)
    span_type(element: str, start_off: ptr_uint, end_off: ptr_uint)
    nullable(target: str, start_off: ptr_uint, end_off: ptr_uint)
    func_type(params: str, return_type: str, start_off: ptr_uint, end_off: ptr_uint)
    proc_type(params: str, return_type: str, start_off: ptr_uint, end_off: ptr_uint)
    dyn_type(interface_name: str, start_off: ptr_uint, end_off: ptr_uint)
    tuple_type(element_types: str, start_off: ptr_uint, end_off: ptr_uint)
    lifetime(ref_text: str, start_off: ptr_uint, end_off: ptr_uint)

public struct ExprBuilder:
    arena: vec.Vec[Expr]

public struct TypeBuilder:
    arena: vec.Vec[TypeExpr]

extending ExprBuilder:
    public static function create() -> ExprBuilder:
        return ExprBuilder(arena = vec.Vec[Expr].create())

    public function len() -> ptr_uint:
        return this.arena.len()

    public editable function push(expr: Expr) -> ExprIdx:
        this.arena.push(expr)
        return this.arena.len()

    public editable function release() -> void:
        this.arena.release()

extending TypeBuilder:
    public static function create() -> TypeBuilder:
        return TypeBuilder(arena = vec.Vec[TypeExpr].create())

    public function len() -> ptr_uint:
        return this.arena.len()

    public editable function push(texpr: TypeExpr) -> TypeExprIdx:
        this.arena.push(texpr)
        return this.arena.len()

    public editable function release() -> void:
        this.arena.release()

public variant Decl:
    import_decl(path: str, alias: str, head_start: ptr_uint, head_end: ptr_uint)
    attribute_decl(name: str, head_start: ptr_uint, head_end: ptr_uint)
    const_decl(name: str, const_type: str, has_block_body: bool, is_const_fn: bool, head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    var_decl(name: str, var_type: str, head_start: ptr_uint, head_end: ptr_uint)
    type_alias(name: str, target: str, head_start: ptr_uint, head_end: ptr_uint)
    struct_decl(name: str, type_params: str, body_members: vec.Vec[str], head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    union_decl(name: str, body_members: vec.Vec[str], head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    enum_decl(name: str, backing: str, body_members: vec.Vec[str], head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    flags_decl(name: str, backing: str, body_members: vec.Vec[str], head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    variant_decl(name: str, type_params: str, body_members: vec.Vec[str], head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    opaque_decl(name: str, head_start: ptr_uint, head_end: ptr_uint)
    interface_decl(name: str, type_params: str, body_members: vec.Vec[str], head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    extending_block(target: str, body_members: vec.Vec[str], head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    function_decl(name: str, type_params: str, params: str, return_type: str, is_async: bool, is_foreign: bool, is_const: bool, body_members: vec.Vec[str], head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    extern_function(name: str, params: str, return_type: str, head_start: ptr_uint, head_end: ptr_uint)
    static_assert_decl(condition: str, message: str, head_start: ptr_uint, head_end: ptr_uint)
    when_block(discriminant_text: str, body_members: vec.Vec[str], head_start: ptr_uint, head_end: ptr_uint, body_start: ptr_uint, body_end: ptr_uint)
    event_decl(name: str, payload: str, head_start: ptr_uint, head_end: ptr_uint)
    empty

public variant Stmt:
    expression(expr_idx: ExprIdx)
    return_stmt(value_idx: ExprIdx)
    let_decl(name: str, type_text: str, value_idx: ExprIdx)
    var_decl(name: str, type_text: str, value_idx: ExprIdx)
    if_stmt(cond_idx: ExprIdx)
    while_stmt(cond_idx: ExprIdx)
    for_stmt(iterable_text: str)
    match_stmt(scrutinee_text: str)
    assign_stmt(target: str, value_idx: ExprIdx)
    compound_assign(target: str, op: str, value_idx: ExprIdx)
    other(text: str)
