## AST — Milk Tea abstract syntax tree variant types.
##
## All nodes are arena-allocated and referenced via ptr[...].
## Child lists use span[...] pointing into arena memory.
##
## Variant hierarchy:
##   Decl   — top-level declarations (function, struct, enum, etc.)
##   Stmt   — statements (if, while, for, return, let, etc.)
##   Expr   — expressions (identifier, binary_op, call, literal, etc.)
##   Type   — type references (named, ptr, span, array, fn, etc.)
##   Pattern — match arm patterns (wildcard, int_lit, char_lit, variant_arm)

import compiler.lexer.token_kind as tk
import compiler.parser.operators as ops_mod
import std.vec

## ── common types ────────────────────────────────────────────────────

public type IdentId = ptr_uint


public struct Span:
    start: ptr_uint
    len: ptr_uint
    line: ptr_uint
    col: ptr_uint


## ── Expression variant ──────────────────────────────────────────────

public variant Expr:
    identifier(name: IdentId, loc: Span)
    integer_literal(value: int, loc: Span)
    float_literal(value: double, loc: Span)
    char_literal(value: ubyte, loc: Span)
    string_literal(text: str, is_cstr: bool, loc: Span)
    bool_literal(value: bool, loc: Span)
    null_literal(loc: Span)
    binary_op(operator: ops_mod.BinaryOp, left: ptr[Expr], right: ptr[Expr], loc: Span)
    unary_op(operator: ops_mod.UnaryOp, operand: ptr[Expr], loc: Span)
    call(callee: ptr[Expr], args: span[ptr[Expr]], loc: Span)
    aggregate(type_name: IdentId, fields: span[TupleField], loc: Span)
    member_access(receiver: ptr[Expr], member: IdentId, loc: Span)
    index_access(receiver: ptr[Expr], index: ptr[Expr], loc: Span)
    specialization(callee: ptr[Expr], args: span[ptr[Type]], loc: Span)
    cast_expr(target_type: ptr[Type], expr: ptr[Expr], loc: Span)
    if_expr(condition: ptr[Expr], then_branch: ptr[Expr], else_branch: ptr[Expr], loc: Span)
    match_expr(scrutinee: ptr[Expr], arms: span[MatchExprArm], loc: Span)
    proc_expr(params: span[Param], return_type: ptr[Type], body: ptr[Stmt], loc: Span)
    tuple_literal(fields: span[TupleField], loc: Span)
    range_expr(start: ptr[Expr], end: ptr[Expr], loc: Span)
    sizeof_expr(type_ref: ptr[Type], loc: Span)
    alignof_expr(type_ref: ptr[Type], loc: Span)
    offsetof_expr(type_ref: ptr[Type], field: IdentId, loc: Span)
    reinterpret_expr(target_type: ptr[Type], expr: ptr[Expr], loc: Span)
    ref_of_expr(expr: ptr[Expr], loc: Span)
    ptr_of_expr(expr: ptr[Expr], loc: Span)
    const_ptr_of_expr(expr: ptr[Expr], loc: Span)
    read_expr(expr: ptr[Expr], loc: Span)
    await_expr(expr: ptr[Expr], loc: Span)
    unsafe_expr(expr: ptr[Expr], loc: Span)
    error_expr(loc: Span)


## ── Statement variant ───────────────────────────────────────────────

public variant Stmt:
    expression(expr: ptr[Expr], loc: Span)
    local_decl(
        kind: DeclKind,
        name: IdentId,
        type_ref: ptr[Type],
        value: ptr[Expr],
        else_binding: IdentId,
        else_body: ptr[Stmt],
        loc: Span,
    )
    assignment(target: ptr[Expr], op: tk.TokenKind, value: ptr[Expr], loc: Span)
    if_stmt(branches: span[IfBranch], else_body: ptr[Stmt], loc: Span)
    while_stmt(condition: ptr[Expr], body: ptr[Stmt], loc: Span)
    for_stmt(bindings: span[ForBinding], iterables: span[ptr[Expr]], body: ptr[Stmt], loc: Span)
    match_stmt(scrutinee: ptr[Expr], arms: span[MatchArm], loc: Span)
    return_stmt(value: ptr[Expr], loc: Span)
    break_stmt(loc: Span)
    continue_stmt(loc: Span)
    pass_stmt(loc: Span)
    defer_stmt(expr: ptr[Expr], body: ptr[Stmt], loc: Span)
    unsafe_block(body: ptr[Stmt], loc: Span)
    block(stmts: span[ptr[Stmt]], loc: Span)
    error_stmt(loc: Span)


## ── Declaration variant ─────────────────────────────────────────────

public variant Decl:
    function_def(
        name: IdentId,
        type_params: span[TypeParam],
        params: span[Param],
        return_type: ptr[Type],
        body: ptr[Stmt],
        visibility: Visibility,
        is_async: bool,
        is_const: bool,
        loc: Span,
    )
    const_decl(
        name: IdentId,
        type_ref: ptr[Type],
        value: ptr[Expr],
        visibility: Visibility,
        loc: Span,
    )
    var_decl(name: IdentId, type_ref: ptr[Type], value: ptr[Expr], visibility: Visibility, loc: Span)
    type_alias(name: IdentId, target: ptr[Type], visibility: Visibility, loc: Span)
    struct_decl(name: IdentId, fields: span[Field], visibility: Visibility, loc: Span)
    enum_decl(name: IdentId, backing: ptr[Type], members: span[EnumMember], visibility: Visibility, loc: Span)
    variant_decl(name: IdentId, arms: span[VariantArmDecl], visibility: Visibility, loc: Span)
    extending_decl(type_name: IdentId, methods: span[ExtendingMethod], loc: Span)
    import_decl(path: span[IdentId], alias: IdentId, loc: Span)
    error_decl(loc: Span)


## ── Type variant ────────────────────────────────────────────────────

public variant Type:
    named_type(name: IdentId, loc: Span)
    pointer_type(pointee: ptr[Type], is_const: bool, loc: Span)
    ref_type(pointee: ptr[Type], loc: Span)
    span_type(element: ptr[Type], loc: Span)
    array_type(element: ptr[Type], size: ptr_uint, loc: Span)
    fn_type(params: span[Param], return_type: ptr[Type], loc: Span)
    proc_type(params: span[Param], return_type: ptr[Type], loc: Span)
    nullable_type(inner: ptr[Type], loc: Span)
    tuple_type(elements: span[ptr[Type]], loc: Span)
    generic_type(name: IdentId, args: span[ptr[Type]], loc: Span)
    error_type(loc: Span)


## ── Pattern variant ─────────────────────────────────────────────────

public variant Pattern:
    wildcard(loc: Span)
    int_literal(value: int, loc: Span)
    char_literal(value: ubyte, loc: Span)
    variant_arm(type_name: IdentId, arm_name: IdentId, binding: IdentId, fields: span[PatternField], loc: Span)


## ── Helper structs ──────────────────────────────────────────────────

public enum Visibility: int
    priv = 0
    pub = 1


public enum DeclKind: int
    dk_let = 0
    dk_var = 1


public enum MethodKind: int
    mk_plain = 0
    mk_editable = 1
    mk_static = 2


public struct ExtendingMethod:
    name: IdentId
    params: span[Param]
    return_type: ptr[Type]
    body: ptr[Stmt]
    method_kind: MethodKind
    loc: Span


public struct Param:
    name: IdentId
    type_ref: ptr[Type]
    loc: Span


public struct Field:
    name: IdentId
    type_ref: ptr[Type]
    loc: Span


public struct EnumMember:
    name: IdentId
    value: ptr[Expr]
    loc: Span


public struct VariantArmDecl:
    name: IdentId
    fields: span[Field]
    loc: Span


public struct IfBranch:
    condition: ptr[Expr]
    body: ptr[Stmt]
    loc: Span


public struct ForBinding:
    name: IdentId
    loc: Span


public struct MatchArm:
    pattern: ptr[Pattern]
    binding: IdentId
    body: ptr[Stmt]
    loc: Span


public struct MatchExprArm:
    pattern: ptr[Pattern]
    binding: IdentId
    value: ptr[Expr]
    loc: Span


public struct TupleField:
    name: IdentId
    value: ptr[Expr]
    loc: Span


public struct TypeParam:
    name: IdentId
    constraint: IdentId
    loc: Span


public struct PatternField:
    name: IdentId
    value: ptr[Expr]
    is_guard: bool
    loc: Span


public struct SourceFile:
    name: str
    imports: vec.Vec[ptr[Decl]]
    decls: vec.Vec[ptr[Decl]]
