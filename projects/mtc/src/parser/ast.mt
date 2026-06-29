import std.vec as vec

public const NO_NODE_ID: uint = 0xFFFFFFFF

public variant TypeRef:
    named(name: str, type_args: vec.Vec[TypeRef])
    ptr_type(pointee: TypeRef)
    const_ptr_type(pointee: TypeRef)
    ref_type(pointee: TypeRef, lifetime: str)
    span_type(element: TypeRef)
    array_type(element: TypeRef, size: uint)
    nullable_type(inner: TypeRef)
    fn_type(params: vec.Vec[FnParam], return_type: TypeRef)
    proc_type(params: vec.Vec[FnParam], return_type: TypeRef)
    dyn_type(interface_name: str, type_args: vec.Vec[TypeRef])
    soa_type(struct_name: str, count: uint)
    str_buffer_type(capacity: uint)
    task_type(result: TypeRef)
    atomic_type(inner: TypeRef)
    void_type

public struct FnParam:
    name: str
    type_ref: TypeRef

public struct CallArg:
    name: str
    value: AstExpr

public struct NamedField:
    name: str
    value: AstExpr

public struct Param:
    name: str
    type_ref: TypeRef

public enum IfaceMethodKind: ubyte
    iface_fn     = 1
    iface_edit   = 2
    iface_static = 3

public enum TypeParamKind: ubyte
    tp_type = 1
    tp_value = 2

public enum ForeignParamMode: ubyte
    fp_plain     = 1
    fp_in        = 2
    fp_out       = 3
    fp_inout     = 4
    fp_consuming = 5

public variant AstExpr:
    identifier(name: str)
    integer_literal(value_str: str)
    float_literal(value_str: str)
    string_literal(value_str: str)
    char_literal(value_str: str)
    cstring_literal(value_str: str)
    bool_literal(value: bool)
    null_literal
    typed_null_literal(target_type: TypeRef)
    binary(op: str, left: AstExpr, right: AstExpr)
    unary(op: str, operand: AstExpr)
    call(callee: AstExpr, args: vec.Vec[CallArg])
    member(object: AstExpr, member_name: str)
    index(object: AstExpr, index: AstExpr)
    range_index(object: AstExpr, start: ptr_uint, end: ptr_uint)
    if_expr(condition: AstExpr, then_val: AstExpr, else_val: AstExpr)
    match_expr(scrutinee: AstExpr, arms: vec.Vec[MatchArmExpr])
    tuple(elements: vec.Vec[AstExpr])
    named_tuple(fields: vec.Vec[NamedField])
    struct_literal(name: str, fields: vec.Vec[NamedField], type_args: vec.Vec[TypeRef])
    variant_literal(name: str, arm: str, fields: vec.Vec[NamedField], type_args: vec.Vec[TypeRef])
    cast(target_type: TypeRef, value: AstExpr)
    reinterpret(target_type: TypeRef, value: AstExpr)
    propagation(expr: AstExpr)
    is_expr(expr: AstExpr, variant_name: str, arm_name: str)
    with_expr(expr: AstExpr, updates: vec.Vec[NamedField])
    proc_expr(params: vec.Vec[Param], return_type: TypeRef, body: vec.Vec[AstStmt])
    proc_expr_single(params: vec.Vec[Param], return_type: TypeRef, expr: AstExpr)
    format_string(segments: vec.Vec[FormatSegment])
    sizeof_type(target: TypeRef)
    sizeof_expr(target: AstExpr)
    sizeof_field(target: TypeRef, field: str)
    range(start: AstExpr, end: AstExpr)
    detach_expr(expr: AstExpr)
    array_literal(element_type: TypeRef, size: uint, elements: vec.Vec[AstExpr])

public struct MatchArmExpr:
    patterns: vec.Vec[MatchPattern]
    value: AstExpr

public struct MatchPattern:
    kind: MatchPatternKind

public variant MatchPatternKind:
    integer_literal(value: str)
    string_literal(value: str)
    char_literal(value: str)
    wildcard
    enum_member(enum_name: str, member_name: str)
    variant_arm(variant_name: str, arm_name: str, payload_bind: str, struct_fields: vec.Vec[StructPatternField])

public struct StructPatternField:
    kind: StructPatternFieldKind

public variant StructPatternFieldKind:
    bind(name: str)
    discard
    guard(name: str, op: str, expr: AstExpr)
    equality(name: str, expr: AstExpr)

public struct FormatSegment:
    kind: FormatSegmentKind

public variant FormatSegmentKind:
    text(value: str)
    interpolation(expr: AstExpr, format_spec: str)

public variant AstStmt:
    let_stmt(name: str, type_ref: TypeRef, init: AstExpr, else_block: vec.Vec[AstStmt], else_error_binding: str)
    var_stmt(name: str, type_ref: TypeRef, init: AstExpr, else_block: vec.Vec[AstStmt], else_error_binding: str)
    let_discard(init: AstExpr, else_block: vec.Vec[AstStmt])
    assign(target: AstExpr, value: AstExpr)
    if_stmt(condition: AstExpr, then_body: vec.Vec[AstStmt], elifs: vec.Vec[ElifBranch], else_body: vec.Vec[AstStmt])
    if_inline(condition: AstExpr, then_stmt: AstStmt, else_stmt: AstStmt)
    while_stmt(condition: AstExpr, body: vec.Vec[AstStmt])
    for_stmt(bindings: vec.Vec[AstExpr], iterable: AstExpr, body: vec.Vec[AstStmt])
    for_range(binding: AstExpr, range_expr: AstExpr, body: vec.Vec[AstStmt])
    for_range_literal(binding: str, start: AstExpr, end: AstExpr, body: vec.Vec[AstStmt])
    for_parallel(bindings: vec.Vec[AstExpr], iterables: vec.Vec[AstExpr], body: vec.Vec[AstStmt])
    match_stmt(scrutinee: AstExpr, arms: vec.Vec[MatchArm])
    when_stmt(discriminant: AstExpr, branches: vec.Vec[WhenBranch], else_branch: vec.Vec[AstStmt])
    parallel_for(binding: str, start: AstExpr, end: AstExpr, body: vec.Vec[AstStmt])
    parallel_block(stmts: vec.Vec[AstStmt])
    inline_for(binding: str, iterable: AstExpr, body: vec.Vec[AstStmt])
    inline_while(condition: AstExpr, body: vec.Vec[AstStmt])
    inline_match(scrutinee: AstExpr, arms: vec.Vec[MatchArm])
    inline_if(condition: AstExpr, then_body: vec.Vec[AstStmt], else_body: vec.Vec[AstStmt])
    return_stmt(value: AstExpr)
    break_stmt
    continue_stmt
    pass_stmt
    defer_stmt(stmts: vec.Vec[AstStmt])
    defer_expr(expr: AstExpr)
    unsafe_block(body: vec.Vec[AstStmt])
    unsafe_expr(expr: AstExpr)
    emit_stmt(body: vec.Vec[AstDecl])
    gather_stmt(handles: vec.Vec[AstExpr])
    expr_stmt(expr: AstExpr)

public struct ElifBranch:
    condition: AstExpr
    body: vec.Vec[AstStmt]

public struct MatchArm:
    patterns: vec.Vec[MatchArmPatternKind]
    body: vec.Vec[AstStmt]

public variant MatchArmPatternKind:
    integer_literal_p(value: str)
    string_literal_p(value: str)
    char_literal_p(value: str)
    wildcard_p
    enum_member_p(enum_name: str, member_name: str)
    variant_arm_p(variant_name: str, arm_name: str, payload_bind: str, struct_fields: vec.Vec[StructPatternField])

public struct WhenBranch:
    values: vec.Vec[AstExpr]
    body: vec.Vec[AstStmt]

public variant AstDecl:
    import_decl(module_path: vec.Vec[str], alias: str)
    const_decl(name: str, type_ref: TypeRef, init: AstExpr, is_public: bool, docs: vec.Vec[str])
    const_block(name: str, return_type: TypeRef, body: vec.Vec[AstStmt], is_public: bool, docs: vec.Vec[str])
    var_decl(name: str, type_ref: TypeRef, init: AstExpr, is_public: bool)
    type_alias(name: str, type_ref: TypeRef, is_public: bool)
    struct_decl(name: str, fields: vec.Vec[StructField], type_params: vec.Vec[TypeParam], impls: vec.Vec[TypeRef], attrs: vec.Vec[AttrApp], is_public: bool, docs: vec.Vec[str])
    union_decl(name: str, fields: vec.Vec[StructField], attrs: vec.Vec[AttrApp], is_public: bool)
    variant_decl(name: str, arms: vec.Vec[VariantArm], type_params: vec.Vec[TypeParam], attrs: vec.Vec[AttrApp], is_public: bool)
    enum_decl(name: str, backing_type: TypeRef, members: vec.Vec[EnumMember], attrs: vec.Vec[AttrApp], is_public: bool)
    flags_decl(name: str, backing_type: TypeRef, members: vec.Vec[FlagsMember], attrs: vec.Vec[AttrApp], is_public: bool)
    opaque_decl(name: str, impls: vec.Vec[TypeRef], attrs: vec.Vec[AttrApp], is_public: bool)
    interface_decl(name: str, methods: vec.Vec[IfaceMethod], type_params: vec.Vec[TypeParam], is_public: bool)
    function_decl(name: str, params: vec.Vec[Param], return_type: TypeRef, body: vec.Vec[AstStmt], type_params: vec.Vec[TypeParam], is_async: bool, is_const: bool, is_public: bool, docs: vec.Vec[str])
    external_function_decl(name: str, params: vec.Vec[Param], return_type: TypeRef, is_variadic: bool)
    foreign_function_decl(name: str, params: vec.Vec[ForeignParam], return_type: TypeRef, linkage: vec.Vec[str])
    extending_block(target_type: TypeRef, methods: vec.Vec[AstDecl])
    event_decl(name: str, payload_type: TypeRef, capacity: uint, is_public: bool)
    attribute_decl(name: str, targets: vec.Vec[str], params: vec.Vec[Param])
    static_assert_decl(condition: AstExpr, message: str)

public struct StructField:
    name: str
    type_ref: TypeRef
    nested_structs: vec.Vec[AstDecl]
    attrs: vec.Vec[AttrApp]

public struct VariantArm:
    name: str
    fields: vec.Vec[StructField]

public struct EnumMember:
    name: str
    value: AstExpr

public struct FlagsMember:
    name: str
    value: AstExpr

public struct IfaceMethod:
    kind: IfaceMethodKind
    name: str
    params: vec.Vec[Param]
    return_type: TypeRef

public struct TypeParam:
    name: str
    kind: TypeParamKind
    constraints: vec.Vec[TypeRef]

public struct AttrApp:
    name: str
    args: vec.Vec[AstExpr]

public struct ForeignParam:
    name: str
    type_ref: TypeRef
    mode: ForeignParamMode
    projection_type: TypeRef

public struct Module:
    imports: vec.Vec[AstDecl]
    declarations: vec.Vec[AstDecl]
    is_external: bool
    includes: vec.Vec[str]
    links: vec.Vec[str]
