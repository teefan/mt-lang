# AST node definitions for the self-hosting Milk Tea compiler.
# Mirrors lib/milk_tea/core/ast.rb.
#
# Nodes use a flat arena design: per-kind data structs stored in per-kind
# vectors owned by SourceFile.  Cross-references use NodeId = ptr_uint indices.
# NodeId = 0 means "none" (no referenced node).

import std.vec

public type NodeId = ptr_uint

# ═══════════════════════════════════════════════════════════════════════════════
# Type-related helpers (no recursion, plain structs)
# ═══════════════════════════════════════════════════════════════════════════════

public struct QualifiedName:
    parts: vec.Vec[str]

public struct TypeArgument:
    value: str

public struct TypeRef:
    name: QualifiedName
    arguments: vec.Vec[TypeArgument]
    nullable: bool

public struct Param:
    name: str
    param_type: TypeRef
    type_expr_id: NodeId
    line: int
    column: int

public struct ForeignParam:
    name: str
    public_type: TypeRef
    mode: str
    boundary_type: TypeRef

public struct Field:
    name: str
    field_type: TypeRef
    type_expr_id: NodeId

public struct VariantArmField:
    name: str
    field_type: TypeRef

public struct VariantArm:
    name: str
    fields: vec.Vec[VariantArmField]

public struct EnumMember:
    name: str
    value: NodeId

public struct Attribute:
    name: str
    arguments: vec.Vec[Argument]

public struct Argument:
    name: str
    value: NodeId

public struct Import:
    path: vec.Vec[str]
    alias_name: str
    line: int
    column: int

public struct IfBranch:
    condition: NodeId
    body: NodeId  # ptr_uint index into stmts vec
    line: int
    column: int

public struct MatchArm:
    pattern: NodeId
    binding_name: str
    body: NodeId

public struct MatchExprArm:
    pattern: NodeId
    binding_name: str
    value: NodeId

public struct WhenBranch:
    pattern: NodeId
    binding_name: str
    body: NodeId

public struct ForBinding:
    name: str

public struct FormatStringPart:
    is_expr: bool
    text: str
    format_spec: str

# ═══════════════════════════════════════════════════════════════════════════════
# Expression node (variant)
# ═══════════════════════════════════════════════════════════════════════════════

public variant Expr:
    identifier(name: str, line: int, column: int)
    member_access(receiver: NodeId, member: str, line: int, column: int)
    index_access(receiver: NodeId, index: NodeId, args_start: NodeId, args_len: NodeId)
    call(callee: NodeId, args_start: NodeId, args_len: NodeId, line: int, column: int)
    specialization(callee: NodeId, args_start: NodeId, args_len: NodeId)
    unary_op(operator: str, operand: NodeId)
    binary_op(operator: str, left: NodeId, right: NodeId)
    range_expr(start_expr: NodeId, end_expr: NodeId, line: int, column: int)
    if_expr(condition: NodeId, then_expr: NodeId, else_expr: NodeId)
    match_expr(scrutinee: NodeId, arms_start: NodeId, arms_len: NodeId, line: int, column: int)
    unsafe_expr(body: NodeId, line: int, column: int)
    proc_expr(params_start: NodeId, params_len: NodeId, return_type: NodeId, body: NodeId)
    await_expr(inner: NodeId)
    sizeof_expr(type_arg: NodeId)
    alignof_expr(type_arg: NodeId)
    offsetof_expr(type_arg: NodeId, field: str)
    integer_literal(value: int)
    float_literal(value: float)
    string_literal(value: str)
    cstring_literal(value: str)
    format_string(parts_start: NodeId, parts_len: NodeId)
    char_literal(value: ubyte)
    boolean_literal(value: bool)
    null_literal(type_id: NodeId)
    prefix_cast(target_type: NodeId, expression: NodeId)
    expression_list(elements_start: NodeId, elements_len: NodeId)
    error_expr(line: int, column: int, message: str)

# ═══════════════════════════════════════════════════════════════════════════════
# Declaration node (variant)
# ═══════════════════════════════════════════════════════════════════════════════

public variant Decl:
    const_decl(name: str, type_id: NodeId, value_id: NodeId, visibility: str)
    var_decl(name: str, type_id: NodeId, value_id: NodeId, visibility: str)
    type_alias_decl(name: str, target_type: NodeId, visibility: str)
    struct_decl(name: str, fields_start: NodeId, fields_len: NodeId, visibility: str)
    union_decl(name: str, fields_start: NodeId, fields_len: NodeId, visibility: str)
    enum_decl(name: str, backing_type: NodeId, members_start: NodeId, members_len: NodeId, visibility: str)
    flags_decl(name: str, backing_type: NodeId, members_start: NodeId, members_len: NodeId, visibility: str)
    variant_decl(name: str, type_params_start: NodeId, type_params_len: NodeId, arms_start: NodeId, arms_len: NodeId, visibility: str)
    opaque_decl(name: str, c_name: str, visibility: str)
    interface_decl(name: str, methods_start: NodeId, methods_len: NodeId, visibility: str)
    func_def(name: str, params_start: NodeId, params_len: NodeId, return_type: NodeId, body: NodeId, visibility: str, is_async: bool, is_const: bool)
    extern_func_decl(name: str, params_start: NodeId, params_len: NodeId, return_type: NodeId, is_variadic: bool, mapping: str)
    foreign_func_decl(name: str, params_start: NodeId, params_len: NodeId, return_type: NodeId, mapping: str, visibility: str)
    extending_block(type_name: QualifiedName, methods_start: NodeId, methods_len: NodeId)
    event_decl(name: str, capacity: int, payload_type: NodeId, visibility: str)
    static_assert_decl(condition: NodeId, message: str, line: int)
    emit_stmt(inner_decl: NodeId, line: int, column: int)
    error_decl(line: int, column: int, message: str)

# ═══════════════════════════════════════════════════════════════════════════════
# Statement node (variant)
# ═══════════════════════════════════════════════════════════════════════════════

public variant Stmt:
    expression_stmt(expr_id: NodeId, line: int)
    if_stmt(branches_start: NodeId, branches_len: NodeId, else_body: NodeId, is_inline: bool, line: int, column: int)
    match_stmt(scrutinee: NodeId, arms_start: NodeId, arms_len: NodeId, is_inline: bool, line: int, column: int)
    for_stmt(bindings_start: NodeId, bindings_len: NodeId, iterables_start: NodeId, iterables_len: NodeId, body: NodeId, is_inline: bool, threaded: bool, line: int, column: int)
    parallel_block(bodies_start: NodeId, bodies_len: NodeId, line: int, column: int)
    while_stmt(condition: NodeId, body: NodeId, is_inline: bool, line: int, column: int)
    when_stmt(discriminant: NodeId, branches_start: NodeId, branches_len: NodeId, else_body: NodeId, line: int, column: int)
    break_stmt(line: int, column: int)
    continue_stmt(line: int, column: int)
    pass_stmt(line: int, column: int)
    return_stmt(value_id: NodeId, line: int, column: int)
    defer_stmt(expr_id: NodeId, body: NodeId, line: int, column: int)
    assignment(target: NodeId, operator: str, value: NodeId, line: int, column: int)
    local_decl(kind: str, name: str, type_id: NodeId, value_id: NodeId, else_body: NodeId, line: int, column: int)
    unsafe_stmt(body: NodeId, line: int, column: int)
    detach_stmt(body: NodeId, line: int, column: int)
    gather_stmt(handles_start: NodeId, handles_len: NodeId, line: int, column: int)
    error_stmt(line: int, column: int, message: str)

# ═══════════════════════════════════════════════════════════════════════════════
# SourceFile — the root node, owns all arena storage
# ═══════════════════════════════════════════════════════════════════════════════

public struct SourceFile:
    module_name: QualifiedName
    module_kind: str
    imports: vec.Vec[Import]
    declarations: vec.Vec[Decl]

    # Arena storage — all nodes of each kind stored flat here
    exprs: vec.Vec[Expr]
    stmts: vec.Vec[Stmt]
    type_nodes: vec.Vec[TypeRef]

    # Per-kind arena storage for sub-node types
    arguments: vec.Vec[Argument]
    if_branches: vec.Vec[IfBranch]
    match_arms: vec.Vec[MatchArm]
    match_expr_arms: vec.Vec[MatchExprArm]
    when_branches: vec.Vec[WhenBranch]
    for_bindings: vec.Vec[ForBinding]
    params: vec.Vec[Param]
    foreign_params: vec.Vec[ForeignParam]
    fields: vec.Vec[Field]
    variant_arms: vec.Vec[VariantArm]
    variant_arm_fields: vec.Vec[VariantArmField]
    enum_members: vec.Vec[EnumMember]
    format_parts: vec.Vec[FormatStringPart]
    attributes: vec.Vec[Attribute]
    type_arguments: vec.Vec[TypeArgument]

    line: int
