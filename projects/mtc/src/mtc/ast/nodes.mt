import std.vec as vec

public enum DeclKind: ubyte
    const_decl = 1
    var_decl = 2
    event_decl = 3
    type_alias = 4
    struct_decl = 5
    enum_decl = 6
    flags_decl = 7
    variant_decl = 8
    interface_decl = 9
    function_def = 10
    extern_function = 11
    foreign_function = 12
    extending_block = 13
    opaque_decl = 14
    union_decl = 15

public enum StmtKind: ubyte
    local_let = 1
    local_var = 2
    expression_stmt = 3
    if_stmt = 4
    match_stmt = 5
    while_stmt = 6
    for_stmt = 7
    return_stmt = 8
    break_stmt = 9
    continue_stmt = 10
    pass_stmt = 11
    defer_stmt = 12
    unsafe_stmt = 13
    block = 14

public enum ExprKind: ubyte
    identifier = 1
    integer_literal = 2
    float_literal = 3
    string_literal = 4
    char_literal = 5
    boolean_literal = 6
    null_literal = 7
    binary_op = 8
    unary_op = 9
    call = 10
    member_access = 11
    index_access = 12
    await_expr = 13
    if_expr = 14
    match_expr = 15
    proc_expr = 16
    prefix_cast = 17


public struct SourceFile:
    module_name: str
    imports: vec.Vec[Import]
    decls: vec.Vec[Decl]
    is_external: bool
    line: ptr_uint

public struct Import:
    path: str
    alias: str
    line: ptr_uint
    column: ptr_uint


public struct Decl:
    kind: DeclKind
    name: str
    type_name: str
    value_text: str
    params: vec.Vec[Param]
    return_text: str
    fields: vec.Vec[Field]
    members: vec.Vec[EnumMember]
    arms: vec.Vec[VariantArm]
    methods: vec.Vec[Decl]
    impl_list: vec.Vec[str]
    is_public: bool
    is_async: bool
    is_const_fn: bool
    is_extern: bool
    stmt_count: ptr_uint
    line: ptr_uint
    column: ptr_uint

public struct Param:
    name: str
    type_text: str
    line: ptr_uint
    column: ptr_uint

public struct Field:
    name: str
    type_text: str
    line: ptr_uint
    column: ptr_uint

public struct EnumMember:
    name: str
    value_text: str
    line: ptr_uint
    column: ptr_uint

public struct VariantArm:
    name: str
    fields: vec.Vec[Field]


public struct Stmt:
    kind: StmtKind
    name: str
    type_text: str
    value_text: str
    cond_text: str
    body_text: str
    else_text: str
    line: ptr_uint
    column: ptr_uint

public struct MatchArm:
    pattern_text: str
    bind_name: str
    body_text: str
    value_text: str


public struct Expr:
    kind: ExprKind
    name: str
    lexeme: str
    value_int: int
    value_float: float
    value_bool: bool
    value_str: str
    operator: str
    left_text: str
    right_text: str
    line: ptr_uint
    column: ptr_uint
