## Self-hosted parser AST — variant-based, mirroring Ruby compiler's AST.
##
## Uses `ptr[Expr]` / `ptr[Stmt]` for recursive references (heap-allocated).
## Non-recursive types (TypeRef, Param, etc.) stay as value-type structs.
## Arm names prefixed to avoid MT keyword collisions (ret_=/if_=/etc.).

import std.vec as vec
import std.str

# =============================================================================
#  Non-recursive types (value-type structs)
# =============================================================================

public struct QualifiedName:
    parts: span[str]

public struct TypeRef:
    name: QualifiedName
    arguments: span[TypeRef]
    nullable: bool

public struct Param:
    name: str
    param_type: TypeRef

public struct ForeignParam:
    name: str
    param_type: TypeRef
    param_mode: ForeignParamMode

public enum ForeignParamMode: ubyte
    plain = 0
    in_out = 1
    fmode_out = 2
    fmode_in = 3
    fmode_consuming = 4

public struct Argument:
    arg_name: Option[str]
    arg_value: ptr[Expr]

public struct MatchArm:
    pattern: ptr[Expr]
    binding_name: Option[str]
    body: ptr[Stmt]

# =============================================================================
#  Expressions (recursive, heap-allocated via ptr[Expr])
# =============================================================================

public variant Expr:
    # Literals
    expr_identifier(name: str, line: ptr_uint, column: ptr_uint)
    expr_integer_literal(value: int)
    expr_float_literal(value: double)
    expr_string_literal(value: str, is_cstring: bool)
    expr_char_literal(value: ubyte)
    expr_bool_literal(value: bool)
    expr_null_literal
    # Operators
    expr_binary_op(operator: str, left: ptr[Expr], right: ptr[Expr])
    expr_unary_op(operator: str, operand: ptr[Expr])
    # Access
    expr_member_access(receiver: ptr[Expr], member_name: str)
    expr_call(callee: ptr[Expr], args: span[Argument])
    expr_index_access(receiver: ptr[Expr], index: ptr[Expr])
    # Control flow
    expr_if(condition: ptr[Expr], then_expr: ptr[Expr], else_expr: ptr[Expr])
    expr_match(scrutinee: ptr[Expr], arms: span[MatchArm])
    expr_proc(params: span[Param], return_type: ptr[TypeRef], body: ptr[Stmt])
    # Misc
    expr_list(elements: span[Expr])
    expr_range(start: ptr[Expr], end: ptr[Expr])
    expr_prefix_cast(target_type: ptr[TypeRef], expression: ptr[Expr])
    expr_unsafe(expression: ptr[Expr])
    expr_await(expression: ptr[Expr])
    expr_detach(body: ptr[Expr])
    expr_sizeof(target_type: ptr[TypeRef])
    expr_alignof(target_type: ptr[TypeRef])
    expr_offsetof(target_type: ptr[TypeRef], field: str)

# =============================================================================
#  Statements (recursive, heap-allocated via ptr[Stmt])
# =============================================================================

public variant Stmt:
    stmt_block(statements: span[Stmt])
    stmt_local(is_let: bool, name: str, stmt_type: ptr[TypeRef], value: ptr[Expr])
    stmt_assignment(target: ptr[Expr], operator: str, value: ptr[Expr])
    stmt_if(condition: ptr[Expr], then_body: ptr[Stmt], else_body: ptr[Stmt])
    stmt_while(condition: ptr[Expr], body: ptr[Stmt])
    stmt_for(bindings: span[str], iterables: span[Expr], body: ptr[Stmt])
    stmt_match(scrutinee: ptr[Expr], arms: span[MatchArm])
    stmt_ret(value: ptr[Expr])
    stmt_break
    stmt_continue
    stmt_pass
    stmt_defer(body: ptr[Stmt])
    stmt_unsafe(body: ptr[Stmt])
    stmt_expression(expression: ptr[Expr])
    stmt_static_assert(condition: ptr[Expr], message: str)

# =============================================================================
#  Source file (top-level)
# =============================================================================

public struct SourceFile:
    imports: span[Import]
    declarations: span[Decl]

public struct Import:
    path: QualifiedName
    alias_name: Option[str]
    line: ptr_uint
    column: ptr_uint

public struct Decl:
    decl_kind: DeclKind
    # fields vary by kind; full structure TBD as we implement producers
    line: ptr_uint
    column: ptr_uint

public enum DeclKind: ubyte
    const_decl = 0
    var_decl = 1
    function_def = 2
    struct_decl = 3
    enum_decl = 4
    variant_decl = 5
    type_alias = 6
    extending_block = 7
    interface_decl = 8
    opaque_decl = 9
    foreign_function = 10
    extern_function = 11
    event_decl = 12
    dk_static_assert = 13
    when_stmt = 14
    attribute_decl = 15
