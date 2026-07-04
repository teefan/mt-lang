## Self-hosted parser AST — variant-based, mirroring the Ruby compiler's AST
## (lib/milk_tea/core/ast.rb) type for type.
##
## Recursive references use ptr[Expr]/ptr[Stmt]/ptr[Decl] (heap-allocated).
## Non-recursive value types remain plain structs passed by value.
## Variant-arm names are prefixed to avoid MT keyword collisions
## (ret_=/if_=/etc.) and use snake_case matching the Ruby field names.

import std.str

# =============================================================================
#  Name / type-level nodes (value types)
# =============================================================================

public struct QualifiedName:
    parts: span[str]
    type_arguments: span[TypeRef]
    line: ptr_uint
    column: ptr_uint


public struct TypeParamConstraint:
    kind: TypeParamConstraintKind
    interface_ref: QualifiedName


public enum TypeParamConstraintKind: ubyte
    implement = 0


public struct TypeParam:
    name: str
    constraints: span[TypeParamConstraint]
    is_value: bool
    value_type: ptr[TypeRef]?
    is_lifetime: bool
    line: ptr_uint
    column: ptr_uint


public struct ValueTypeParam:
    name: str
    value_type: TypeRef
    line: ptr_uint
    column: ptr_uint


public struct TypeArgument:
    value: ptr[TypeRef]


public struct TypeRef:
    name: QualifiedName
    arguments: span[TypeRef]
    nullable: bool
    lifetime: Option[str]
    line: ptr_uint
    column: ptr_uint
    fn_params: span[Param]
    fn_return: ptr[TypeRef]?
    is_proc: bool
    is_fn: bool
    dyn_interface: QualifiedName
    is_dyn: bool
    is_tuple: bool


public struct FunctionType:
    params: span[Param]
    return_type: TypeRef


public struct ProcType:
    params: span[Param]
    return_type: TypeRef


public struct TupleType:
    element_types: span[TypeRef]
    nullable: bool


public struct DynType:
    interface_name: QualifiedName
    nullable: bool
    line: ptr_uint
    column: ptr_uint


# =============================================================================
#  Parameter types (value types)
# =============================================================================

public struct Param:
    name: str
    param_type: TypeRef
    line: ptr_uint
    column: ptr_uint


public struct ForeignParam:
    name: str
    param_type: TypeRef
    param_mode: ForeignParamMode
    boundary_type: Option[TypeRef]


public enum ForeignParamMode: ubyte
    fmode_plain     = 0
    fmode_out       = 1
    fmode_in        = 2
    fmode_inout     = 3
    fmode_consuming = 4


# =============================================================================
#  Field and member types (value types)
# =============================================================================

public struct Field:
    name: str
    field_type: TypeRef
    attributes: span[AttributeApplication]
    line: ptr_uint
    column: ptr_uint


public struct EnumMember:
    name: str
    value: ptr[Expr]?
    line: ptr_uint
    column: ptr_uint


public struct VariantArm:
    name: str
    arm_fields: span[Field]


public struct InterfaceMethod:
    name: str
    method_params: span[Param]
    return_type: ptr[TypeRef]?
    method_kind: MethodKind
    is_async: bool
    attributes: span[AttributeApplication]
    line: ptr_uint
    column: ptr_uint


public struct Method:
    name: str
    type_params: span[TypeParam]
    method_params: span[Param]
    return_type: ptr[TypeRef]?
    body: ptr[Stmt]
    method_kind: MethodKind
    visibility: bool
    is_async: bool
    attributes: span[AttributeApplication]
    line: ptr_uint
    column: ptr_uint


public enum MethodKind: ubyte
    mk_plain    = 0
    mk_editable = 1
    mk_static   = 2


# =============================================================================
#  Attribute types (value types)
# =============================================================================

public struct AttributeApplication:
    name: QualifiedName
    arguments: span[Argument]
    line: ptr_uint
    column: ptr_uint


# =============================================================================
#  Match / pattern types (value types)
# =============================================================================

public struct MatchArm:
    pattern: ptr[Expr]?
    binding_name: Option[str]
    binding_line: ptr_uint
    binding_column: ptr_uint
    body: ptr[Stmt]?


public struct MatchExprArm:
    pattern: ptr[Expr]?
    binding_name: Option[str]
    binding_line: ptr_uint
    binding_column: ptr_uint
    value: ptr[Expr]


public struct WhenBranch:
    pattern: ptr[Expr]
    binding_name: Option[str]
    binding_line: ptr_uint
    binding_column: ptr_uint
    body: span[Stmt]


## Declaration-bodied `when` branch (module-level `when`); its body holds
## declarations rather than statements.
public struct WhenDeclBranch:
    pattern: ptr[Expr]
    binding_name: Option[str]
    binding_line: ptr_uint
    binding_column: ptr_uint
    body: span[Decl]


# =============================================================================
#  For loop binding
# =============================================================================

public struct ForBinding:
    name: str
    line: ptr_uint
    column: ptr_uint


# =============================================================================
#  If branch
# =============================================================================

public struct IfBranch:
    condition: ptr[Expr]
    body: ptr[Stmt]
    line: ptr_uint
    column: ptr_uint


# =============================================================================
#  Call argument
# =============================================================================

public struct Argument:
    arg_name: Option[str]
    arg_value: ptr[Expr]


# =============================================================================
#  Format string parts
# =============================================================================

public variant FormatStringPart:
    fmt_text(value: str)
    fmt_expr(expression: ptr[Expr], format_spec: ptr[FormatSpec])


public struct FormatSpec:
    spec_kind: FormatSpecKind
    value: int
    uppercase: bool


public enum FormatSpecKind: ubyte
    precision = 0
    hex       = 1
    octal     = 2
    binary    = 3


# =============================================================================
#  Expressions (recursive — heap-allocated via ptr[Expr])
# =============================================================================

public variant Expr:
    # Literals
    expr_identifier(name: str, line: ptr_uint, column: ptr_uint)
    expr_integer_literal(lexeme: str, value: int)
    expr_float_literal(lexeme: str, value: double)
    expr_string_literal(lexeme: str, value: str, is_cstring: bool)
    expr_char_literal(lexeme: str, value: ubyte, line: ptr_uint, column: ptr_uint)
    expr_bool_literal(value: bool)
    expr_null_literal(target_type: ptr[TypeRef]?, line: ptr_uint, column: ptr_uint)

    # Format string
    expr_format_string(parts: span[FormatStringPart])

    # Operators
    expr_binary_op(operator: str, left: ptr[Expr], right: ptr[Expr])
    expr_unary_op(operator: str, operand: ptr[Expr])

    # Access
    expr_member_access(receiver: ptr[Expr], member_name: str, line: ptr_uint, column: ptr_uint)
    expr_call(callee: ptr[Expr], args: span[Argument])
    expr_index_access(receiver: ptr[Expr], index: ptr[Expr])
    expr_specialization(callee: ptr[Expr], arguments: span[TypeArgument])

    # Control flow
    expr_if(condition: ptr[Expr], then_expr: ptr[Expr], else_expr: ptr[Expr])
    expr_match(scrutinee: ptr[Expr], arms: span[MatchExprArm], line: ptr_uint,
               column: ptr_uint)
    expr_proc(method_params: span[Param], return_type: ptr[TypeRef]?, body: ptr[Stmt])

    # Async / concurrency
    expr_await(expression: ptr[Expr])
    expr_detach(expression: ptr[Expr], line: ptr_uint, column: ptr_uint)

    # Misc
    expr_expression_list(elements: span[Expr], line: ptr_uint, column: ptr_uint)
    expr_named(name: str, value: ptr[Expr])
    expr_range(start_expr: ptr[Expr], end_expr: ptr[Expr], line: ptr_uint,
               column: ptr_uint)
    expr_prefix_cast(target_type: ptr[TypeRef], expression: ptr[Expr], line: ptr_uint,
                     column: ptr_uint)
    expr_unsafe(expression: ptr[Expr], line: ptr_uint, column: ptr_uint)
    expr_sizeof(target_type: ptr[TypeRef])
    expr_alignof(target_type: ptr[TypeRef])
    expr_offsetof(target_type: ptr[TypeRef], field: str)

    # Error recovery
    expr_error(line: ptr_uint, column: ptr_uint, message: str)


# =============================================================================
#  Statements (recursive — heap-allocated via ptr[Stmt])
# =============================================================================

public variant Stmt:
    stmt_block(statements: span[Stmt])
    stmt_local(is_let: bool, name: str, stmt_type: ptr[TypeRef]?, value: ptr[Expr]?,
               else_binding: Option[str], else_body: ptr[Stmt]?,
               destructure_bindings: Option[span[str]],
               destructure_type_name: Option[str], line: ptr_uint, column: ptr_uint)
    stmt_assignment(target: ptr[Expr], operator: str, value: ptr[Expr], line: ptr_uint,
                    column: ptr_uint)
    stmt_if(branches: span[IfBranch], else_body: ptr[Stmt]?, is_inline: bool, line: ptr_uint,
            else_line: ptr_uint, else_column: ptr_uint)
    stmt_while(condition: ptr[Expr], body: ptr[Stmt]?, is_inline: bool, line: ptr_uint,
               column: ptr_uint)
    stmt_for(bindings: span[ForBinding], iterables: span[Expr], body: ptr[Stmt]?,
             is_inline: bool, threaded: bool, line: ptr_uint, column: ptr_uint)
    stmt_match(scrutinee: ptr[Expr], arms: span[MatchArm], is_inline: bool, line: ptr_uint,
               column: ptr_uint)
    stmt_ret(value: ptr[Expr]?, line: ptr_uint, column: ptr_uint)
    stmt_break(line: ptr_uint, column: ptr_uint)
    stmt_continue(line: ptr_uint, column: ptr_uint)
    stmt_pass(line: ptr_uint, column: ptr_uint)
    stmt_defer(expression: ptr[Expr]?, body: ptr[Stmt]?, line: ptr_uint, column: ptr_uint)
    stmt_unsafe(body: ptr[Stmt]?, line: ptr_uint, column: ptr_uint)
    stmt_expression(expression: ptr[Expr], line: ptr_uint)
    stmt_static_assert(condition: ptr[Expr], message: ptr[Expr]?, line: ptr_uint)
    stmt_emit(declaration: ptr[Decl]?, line: ptr_uint, column: ptr_uint)
    stmt_when(discriminant: ptr[Expr], branches: span[WhenBranch], else_body: ptr[Stmt]?,
              line: ptr_uint, column: ptr_uint)
    stmt_parallel_block(bodies: span[Stmt], line: ptr_uint, column: ptr_uint)
    stmt_gather(handles: span[Expr], line: ptr_uint, column: ptr_uint)
    stmt_error(line: ptr_uint, column: ptr_uint, message: str)
    stmt_error_block(body: ptr[Stmt], line: ptr_uint, column: ptr_uint, message: str)


# =============================================================================
#  Declarations (recursive — heap-allocated via ptr[Decl])
# =============================================================================

public variant Decl:
    decl_const(name: str, const_type: ptr[TypeRef], value: ptr[Expr]?,
               block_body: ptr[Stmt]?, visibility: bool,
               attributes: span[AttributeApplication], line: ptr_uint,
               column: ptr_uint)
    decl_var(name: str, var_type: ptr[TypeRef]?, value: ptr[Expr]?,
             visibility: bool, line: ptr_uint, column: ptr_uint)
    decl_function(name: str, type_params: span[TypeParam], method_params: span[Param],
                  return_type: ptr[TypeRef]?, body: ptr[Stmt]?, visibility: bool,
                  is_async: bool, is_const: bool,
                  attributes: span[AttributeApplication], line: ptr_uint,
                  column: ptr_uint)
    decl_struct(name: str, type_params: span[TypeParam], impl_list: span[QualifiedName],
                c_name: Option[str], struct_fields: span[Field],
                struct_events: span[Decl], nested_types: span[Decl],
                struct_attrs: span[AttributeApplication], packed: bool, alignment: int,
                visibility: bool, lifetime_params: span[TypeParam], line: ptr_uint,
                column: ptr_uint)
    decl_union(name: str, c_name: Option[str], union_fields: span[Field], visibility: bool,
               union_attrs: span[AttributeApplication], line: ptr_uint, column: ptr_uint)
    decl_enum(name: str, backing_type: ptr[TypeRef]?, enum_members: span[EnumMember],
              visibility: bool, enum_attrs: span[AttributeApplication], line: ptr_uint,
              column: ptr_uint)
    decl_flags(name: str, backing_type: ptr[TypeRef]?, flags_members: span[EnumMember],
               visibility: bool, flags_attrs: span[AttributeApplication], line: ptr_uint,
               column: ptr_uint)
    decl_variant(name: str, type_params: span[TypeParam], variant_arms: span[VariantArm],
                 visibility: bool, variant_attrs: span[AttributeApplication], line: ptr_uint,
                 column: ptr_uint)
    decl_opaque(name: str, opaque_implements: span[QualifiedName], c_name: Option[str],
                visibility: bool, line: ptr_uint, column: ptr_uint)
    decl_type_alias(name: str, target: ptr[TypeRef], visibility: bool, line: ptr_uint,
                    column: ptr_uint)
    decl_interface(name: str, type_params: span[TypeParam],
                   interface_methods: span[InterfaceMethod], visibility: bool,
                   line: ptr_uint, column: ptr_uint)
    decl_extending_block(type_name: ptr[TypeRef], methods: span[Method], line: ptr_uint,
                         column: ptr_uint)
    decl_extern_function(name: str, type_params: span[TypeParam],
                         extern_params: span[ForeignParam], return_type: ptr[TypeRef]?,
                         variadic: bool, attrs: span[AttributeApplication],
                         line: ptr_uint, mapping: ptr[Expr]?)
    decl_foreign_function(name: str, type_params: span[TypeParam],
                          foreign_params: span[ForeignParam],
                          return_type: ptr[TypeRef], variadic: bool, mapping: ptr[Expr],
                          visibility: bool, attrs: span[AttributeApplication],
                          line: ptr_uint)
    decl_event(name: str, capacity: int, payload_type: ptr[TypeRef]?, visibility: bool,
               attrs: span[AttributeApplication], line: ptr_uint, column: ptr_uint)
    decl_static_assert(condition: ptr[Expr], message: ptr[Expr]?, line: ptr_uint)
    decl_when(discriminant: ptr[Expr], branches: span[WhenDeclBranch],
              else_body: span[Decl], has_else: bool, line: ptr_uint, column: ptr_uint)
    decl_attribute(name: str, targets: span[str], attr_params: span[Param],
                   visibility: bool, line: ptr_uint, column: ptr_uint)
    decl_import(path: QualifiedName, alias_name: Option[str], line: ptr_uint,
                column: ptr_uint)
    decl_link(value: str, line: ptr_uint, column: ptr_uint)
    decl_include(value: str, line: ptr_uint, column: ptr_uint)
    decl_compiler_flag(value: str, line: ptr_uint, column: ptr_uint)


# =============================================================================
#  Source file root
# =============================================================================

public enum ModuleKind: ubyte
    module_ordinary = 0
    module_raw      = 1


## Root AST node produced by the parser.  Mirrors Ruby AST::SourceFile:
## imports and directives are held separately from ordinary declarations so
## the pretty printer can emit them in the canonical order (imports, then
## directives, then declarations) with the correct blank-line separation.
public struct SourceFile:
    module_kind: ModuleKind
    imports: span[Decl]
    directives: span[Decl]
    declarations: span[Decl]
    line: ptr_uint
