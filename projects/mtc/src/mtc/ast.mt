import std.vec as vec

# =============================================================================
# Source file & imports
# =============================================================================

public enum ModuleKind: int
    kind_module = 0
    kind_raw_module = 1


public struct QualifiedName:
    parts: vec.Vec[str]
    type_arguments: vec.Vec[TypeArgument]
    line: int
    column: int


public struct Import:
    path: QualifiedName
    alias_name: Option[str]
    line: int
    column: int
    length: int


public struct LinkDirective:
    value: str


public struct IncludeDirective:
    value: str


public struct CompilerFlagDirective:
    value: str


# =============================================================================
# Type system
# =============================================================================

public enum TypeParamConstraintKind: int
    kind_implements = 0


public struct TypeParamConstraint:
    constraint_kind: TypeParamConstraintKind
    interface_ref: QualifiedName


public struct TypeParam:
    name: str
    constraints: vec.Vec[TypeParamConstraint]
    line: int
    column: int
    length: int


public struct ValueTypeParam:
    name: str
    value_type: str
    line: int
    column: int
    length: int


public struct TypeArgument:
    value: str


public struct TypeRef:
    name: QualifiedName
    arguments: vec.Vec[TypeArgument]
    nullable: bool
    lifetime: Option[str]
    line: int
    column: int
    length: int


public struct FunctionType:
    params: vec.Vec[Param]
    return_type: TypeRef


public struct ProcType:
    params: vec.Vec[Param]
    return_type: TypeRef


public struct TupleType:
    element_types: vec.Vec[TypeRef]
    nullable: bool


public struct DynType:
    interface_ref: QualifiedName
    nullable: bool
    line: int
    column: int
    length: int


# =============================================================================
# Expressions
# =============================================================================

public struct IntegerLiteral:
    lexeme: str
    value: int


public struct FloatLiteral:
    lexeme: str
    value: float


public struct StringLiteral:
    lexeme: str
    value: str
    is_cstring: bool


public struct CharLiteral:
    lexeme: str
    value: ubyte
    line: int
    column: int


public struct BooleanLiteral:
    value: bool


public struct NullLiteral:
    null_type: str
    line: int
    column: int


public struct ExpressionList:
    elements: vec.Vec[Expr]
    line: int
    column: int


public variant FormatStringPart:
    text(value: str)
    expression(exprs: vec.Vec[Expr], format_spec: str)


public struct FormatString:
    parts: vec.Vec[FormatStringPart]


public struct Argument:
    name: Option[str]
    value: vec.Vec[Expr]


public struct MatchExprArm:
    pattern: vec.Vec[Expr]
    binding_name: Option[str]
    binding_line: int
    binding_column: int
    value: vec.Vec[Expr]


public struct MatchArm:
    pattern: vec.Vec[Expr]
    binding_name: Option[str]
    binding_line: int
    binding_column: int
    body: vec.Vec[Stmt]


public struct IfBranch:
    condition: vec.Vec[Expr]
    body: vec.Vec[Stmt]
    line: int
    column: int
    length: int


public struct ForBinding:
    name: str
    line: int
    column: int


public struct ScopeExpr:
    label: str
    body: vec.Vec[Stmt]
    line: int
    column: int


public struct SleepExpr:
    duration: vec.Vec[Expr]
    line: int
    column: int


public struct GetResultExpr:
    handle: vec.Vec[Expr]
    error_type: TypeRef?
    line: int
    column: int
    length: int


public struct ConstBlockValueExpr:
    block_body: vec.Vec[Stmt]
    line: int
    column: int
    length: int


public struct LambdaGroupExpr:
    body: vec.Vec[Expr]
    line: int
    column: int
    length: int


public variant Expr:
    identifier(name: str, line: int, column: int)
    integer_literal(node: IntegerLiteral)
    float_literal(node: FloatLiteral)
    string_literal(node: StringLiteral)
    char_literal(node: CharLiteral)
    boolean_literal(node: BooleanLiteral)
    null_literal(node: NullLiteral)
    format_string(node: FormatString)
    member_access(receiver: vec.Vec[Expr], member: str, line: int, column: int)
    index_access(receiver: vec.Vec[Expr], index: vec.Vec[Expr])
    call(callee: vec.Vec[Expr], arguments: vec.Vec[Argument])
    specialization(callee: vec.Vec[Expr], arguments: vec.Vec[TypeArgument])
    binary_op(operator: str, left: vec.Vec[Expr], right: vec.Vec[Expr])
    unary_op(operator: str, operand: vec.Vec[Expr])
    prefix_cast(target_type: TypeRef, expression_exprs: vec.Vec[Expr], line: int, column: int, length: int)
    range_expr(start_exprs: vec.Vec[Expr], end_exprs: vec.Vec[Expr], line: int, column: int)
    expression_list(node: ExpressionList)
    if_expr(condition: vec.Vec[Expr], then_expr: vec.Vec[Expr], else_expr: vec.Vec[Expr])
    match_expr(expression: vec.Vec[Expr], arms: vec.Vec[MatchExprArm], line: int, column: int, length: int)
    proc_expr(params: vec.Vec[Param], return_type: Option[TypeRef], body: vec.Vec[Expr])
    unsafe_expr(expression: vec.Vec[Expr], line: int, column: int, length: int)
    await_expr(expression: vec.Vec[Expr])
    sizeof_expr(target_type: TypeRef)
    alignof_expr(target_type: TypeRef)
    offsetof_expr(target_type: TypeRef, field: str)
    detach_expr(body_exprs: vec.Vec[Expr], line: int, column: int)
    scope_expr(node: ScopeExpr)
    sleep_expr(node: SleepExpr)
    get_result_expr(node: GetResultExpr)
    const_block_value_expr(node: ConstBlockValueExpr)
    lambda_group_expr(node: LambdaGroupExpr)
    error_expr(line: int, column: int, length: int, message: Option[str])


# =============================================================================
# Statements
# =============================================================================

public struct LocalDecl:
    decl_kind: str
    name: str
    decl_type: Option[TypeRef]
    value: vec.Vec[Expr]
    else_binding: Option[str]
    else_body: Option[vec.Vec[Stmt]]
    line: int
    column: int
    recovered_else: bool
    destructure_bindings: Option[vec.Vec[ForBinding]]
    destructure_type_name: Option[QualifiedName]


public struct Assignment:
    target: vec.Vec[Expr]
    assign_op: str
    value: vec.Vec[Expr]
    line: int
    column: int


public struct IfStmt:
    branches: vec.Vec[IfBranch]
    else_body: Option[vec.Vec[Stmt]]
    is_inline: bool
    line: int
    else_line: int
    else_column: int


public struct MatchStmt:
    expression: vec.Vec[Expr]
    arms: vec.Vec[MatchArm]
    is_inline: bool
    line: int
    column: int
    length: int


public struct WhileStmt:
    condition: vec.Vec[Expr]
    body: vec.Vec[Stmt]
    is_inline: bool
    line: int
    column: int
    length: int


public struct ForStmt:
    bindings: vec.Vec[ForBinding]
    iterables: vec.Vec[Expr]
    body: vec.Vec[Stmt]
    is_inline: bool
    threaded: bool
    line: int
    column: int


public struct UnsafeStmt:
    body: vec.Vec[Stmt]
    line: int
    column: int
    length: int


public struct ReturnStmt:
    value: vec.Vec[Expr]
    line: int
    column: int
    length: int


public struct DeferStmt:
    expression: vec.Vec[Expr]
    body: Option[vec.Vec[Stmt]]
    line: int
    column: int
    length: int


public struct BreakStmt:
    line: int
    column: int
    length: int


public struct ContinueStmt:
    line: int
    column: int
    length: int


public struct PassStmt:
    line: int
    column: int
    length: int


public struct EmitStmt:
    declaration: Decl
    line: int
    column: int


public struct StaticAssert:
    condition: vec.Vec[Expr]
    message: Option[str]
    line: int


public struct ParallelBlockStmt:
    bodies: vec.Vec[vec.Vec[Stmt]]
    line: int
    column: int


public struct GatherStmt:
    handles: vec.Vec[Expr]
    line: int
    column: int


public struct ErrorStmt:
    line: int
    column: int
    length: int
    message: Option[str]


public struct ErrorBlockStmt:
    body: vec.Vec[Stmt]
    line: int
    column: int
    length: int
    message: Option[str]
    header_type: Option[str]
    header_expression: vec.Vec[Expr]
    header_bindings: Option[vec.Vec[ForBinding]]
    header_iterables: Option[vec.Vec[Expr]]


public struct WhenBranch:
    pattern: vec.Vec[Expr]
    binding_name: Option[str]
    binding_line: int
    binding_column: int
    body: vec.Vec[Stmt]


public struct WhenStmt:
    discriminant: vec.Vec[Expr]
    branches: vec.Vec[WhenBranch]
    else_body: Option[vec.Vec[Stmt]]
    line: int
    column: int
    length: int


public struct ExpressionStmt:
    expression: vec.Vec[Expr]
    line: int


public variant Stmt:
    local_decl(node: LocalDecl)
    assignment(node: Assignment)
    if_stmt(node: IfStmt)
    match_stmt(node: MatchStmt)
    while_stmt(node: WhileStmt)
    for_stmt(node: ForStmt)
    unsafe_stmt(node: UnsafeStmt)
    return_stmt(node: ReturnStmt)
    defer_stmt(node: DeferStmt)
    break_stmt(node: BreakStmt)
    continue_stmt(node: ContinueStmt)
    pass_stmt(node: PassStmt)
    emit_stmt(node: EmitStmt)
    static_assert_decl(node: StaticAssert)
    parallel_block(node: ParallelBlockStmt)
    gather_stmt(node: GatherStmt)
    error_stmt(node: ErrorStmt)
    error_block_stmt(node: ErrorBlockStmt)
    when_stmt(node: WhenStmt)
    expression_stmt(node: ExpressionStmt)


# =============================================================================
# Parameters
# =============================================================================

public struct Param:
    name: str
    param_type: TypeRef
    line: int
    column: int


public struct ForeignParam:
    name: str
    foreign_type: TypeRef
    mode: Option[str]
    boundary_type: Option[str]


# =============================================================================
# Declarations
# =============================================================================

public struct ConstDecl:
    name: str
    const_type: TypeRef
    value: vec.Vec[Expr]
    block_body: Option[vec.Vec[Stmt]]
    is_public: bool
    attributes: vec.Vec[AttributeApplication]
    line: int
    column: int


public struct VarDecl:
    name: str
    var_type: Option[TypeRef]
    value: vec.Vec[Expr]
    is_public: bool
    line: int
    column: int


public struct EventDecl:
    name: str
    capacity: int
    payload_type: Option[TypeRef]
    is_public: bool
    attributes: vec.Vec[AttributeApplication]
    line: int
    column: int


public struct TypeAliasDecl:
    name: str
    target: TypeRef
    is_public: bool
    line: int
    column: int


public struct AttributeDecl:
    name: str
    targets: vec.Vec[str]
    params: vec.Vec[Param]
    is_public: bool
    line: int
    column: int


public struct AttributeApplication:
    name: str
    arguments: vec.Vec[str]
    line: int
    column: int


public struct Field:
    name: str
    field_type: TypeRef
    attributes: vec.Vec[AttributeApplication]
    line: int
    column: int


public struct EnumMember:
    name: str
    value: vec.Vec[Expr]
    line: int
    column: int


public struct VariantArm:
    name: str
    fields: vec.Vec[Field]


public struct StructDecl:
    name: str
    type_params: vec.Vec[TypeParam]
    impl_list: vec.Vec[QualifiedName]
    c_name: Option[str]
    fields: vec.Vec[Field]
    events: vec.Vec[EventDecl]
    nested_types: vec.Vec[Decl]
    attributes: vec.Vec[AttributeApplication]
    packed: bool
    alignment: Option[int]
    is_public: bool
    lifetime_params: vec.Vec[str]
    line: int
    column: int


public struct UnionDecl:
    name: str
    c_name: Option[str]
    fields: vec.Vec[Field]
    is_public: bool
    attributes: vec.Vec[AttributeApplication]
    line: int
    column: int


public struct EnumDecl:
    name: str
    backing_type: TypeRef
    members: vec.Vec[EnumMember]
    is_public: bool
    attributes: vec.Vec[AttributeApplication]
    line: int
    column: int


public struct FlagsDecl:
    name: str
    backing_type: TypeRef
    members: vec.Vec[EnumMember]
    is_public: bool
    attributes: vec.Vec[AttributeApplication]
    line: int
    column: int


public struct OpaqueDecl:
    name: str
    impl_list: vec.Vec[QualifiedName]
    c_name: Option[str]
    is_public: bool
    line: int
    column: int


public struct InterfaceDecl:
    name: str
    type_params: vec.Vec[TypeParam]
    methods: vec.Vec[InterfaceMethodDecl]
    is_public: bool
    line: int
    column: int


public struct ExtendingBlock:
    type_name: TypeRef
    methods: vec.Vec[MethodDef]
    line: int
    column: int


public struct InterfaceMethodDecl:
    name: str
    params: vec.Vec[Param]
    return_type: TypeRef
    method_kind: str
    is_async: bool
    attributes: vec.Vec[AttributeApplication]
    line: int
    column: int


public struct FunctionDef:
    name: str
    type_params: vec.Vec[TypeParam]
    params: vec.Vec[Param]
    return_type: Option[TypeRef]
    body: Option[vec.Vec[Stmt]]
    is_public: bool
    is_async: bool
    is_const: bool
    attributes: vec.Vec[AttributeApplication]
    line: int
    column: int


public struct MethodDef:
    name: str
    type_params: vec.Vec[TypeParam]
    params: vec.Vec[Param]
    return_type: Option[TypeRef]
    body: Option[vec.Vec[Stmt]]
    method_kind: str
    is_public: bool
    is_async: bool
    attributes: vec.Vec[AttributeApplication]
    line: int
    column: int


public struct ExternFunctionDecl:
    name: str
    type_params: vec.Vec[TypeParam]
    params: vec.Vec[ForeignParam]
    return_type: TypeRef
    variadic: bool
    attributes: vec.Vec[AttributeApplication]
    line: int
    mapping: vec.Vec[Expr]


public struct ForeignFunctionDecl:
    name: str
    type_params: vec.Vec[TypeParam]
    params: vec.Vec[ForeignParam]
    return_type: TypeRef
    variadic: bool
    mapping: vec.Vec[Expr]
    is_public: bool
    attributes: vec.Vec[AttributeApplication]
    line: int


public struct VariantDecl:
    name: str
    type_params: vec.Vec[TypeParam]
    arms: vec.Vec[VariantArm]
    is_public: bool
    attributes: vec.Vec[AttributeApplication]
    line: int
    column: int


public variant Decl:
    import_decl(node: Import)
    link_directive(node: LinkDirective)
    include_directive(node: IncludeDirective)
    compiler_flag_directive(node: CompilerFlagDirective)
    const_decl(node: ConstDecl)
    var_decl(node: VarDecl)
    event_decl(node: EventDecl)
    type_alias_decl(node: TypeAliasDecl)
    attribute_decl(node: AttributeDecl)
    struct_decl(node: StructDecl)
    union_decl(node: UnionDecl)
    enum_decl(node: EnumDecl)
    flags_decl(node: FlagsDecl)
    opaque_decl(node: OpaqueDecl)
    interface_decl(node: InterfaceDecl)
    extending_block(node: ExtendingBlock)
    function_def(node: FunctionDef)
    extern_function_decl(node: ExternFunctionDecl)
    foreign_function_decl(node: ForeignFunctionDecl)
    variant_decl(node: VariantDecl)
    static_assert_decl(node: StaticAssert)
    when_stmt(node: WhenStmt)
    error_decl(line: int, column: int, message: str)


# =============================================================================
# Source file
# =============================================================================

public struct SourceFile:
    module_name: Option[str]
    module_kind: ModuleKind
    imports: vec.Vec[Import]
    directives: vec.Vec[Decl]
    declarations: vec.Vec[Decl]
    line: int
    node_ids: vec.Vec[int]
    node_path_ids: vec.Vec[str]
