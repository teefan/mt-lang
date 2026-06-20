# IR (Intermediate Representation) node definitions for the self-hosting compiler.
# Mirrors lib/milk_tea/core/ir.rb.
#
# Design: arena-based, same pattern as AST (NodeId = ptr_uint index into vecs).
# IR nodes are lower-level than AST — they have explicit variables, labels, gotos.

import std.vec
import mtc.types

public type NodeId = ptr_uint

# ═══════════════════════════════════════════════════════════════════════════
# IR Expressions (produce values)
# ═══════════════════════════════════════════════════════════════════════════

public variant IrExpr:
    integer_literal(value: int, type_id: types.TypeId)
    float_literal(value: float, type_id: types.TypeId)
    string_literal(value: str, type_id: types.TypeId, cstring: bool)
    boolean_literal(value: bool, type_id: types.TypeId)
    null_literal(type_id: types.TypeId)
    zero_init(type_id: types.TypeId)
    name(name: str, type_id: types.TypeId, pointer: bool)
    member(receiver: NodeId, member_name: str, type_id: types.TypeId)
    index(receiver: NodeId, index_expr: NodeId, type_id: types.TypeId)
    checked_index(receiver: NodeId, index_expr: NodeId, receiver_type: types.TypeId, type_id: types.TypeId)
    call(callee: NodeId, args_start: NodeId, args_len: NodeId, type_id: types.TypeId)
    fn_call(fn_linkage_name: str, args_start: NodeId, args_len: NodeId, type_id: types.TypeId)
    binary(operator: str, left: NodeId, right: NodeId, type_id: types.TypeId)
    unary(operator: str, operand: NodeId, type_id: types.TypeId)
    conditional(condition: NodeId, then_expr: NodeId, else_expr: NodeId, type_id: types.TypeId)
    cast(target_type: types.TypeId, expression: NodeId, type_id: types.TypeId)
    address_of(expression: NodeId, type_id: types.TypeId)
    sizeof_expr(target_type: types.TypeId, type_id: types.TypeId)
    alignof_expr(target_type: types.TypeId, type_id: types.TypeId)
    offsetof_expr(target_type: types.TypeId, field: str, type_id: types.TypeId)
    reinterpret_expr(target_type: types.TypeId, source_type: types.TypeId, expression: NodeId, type_id: types.TypeId)
    aggregate_literal(type_id: types.TypeId, fields_start: NodeId, fields_len: NodeId)
    array_literal(type_id: types.TypeId, elements_start: NodeId, elements_len: NodeId)
    variant_literal(type_id: types.TypeId, arm_name: str, fields_start: NodeId, fields_len: NodeId)

# ═══════════════════════════════════════════════════════════════════════════
# IR Statements (in function bodies)
# ═══════════════════════════════════════════════════════════════════════════

public variant IrStmt:
    local_decl(name: str, linkage_name: str, type_id: types.TypeId, value: NodeId)
    assignment(target: NodeId, operator: str, value: NodeId)
    block(body_start: NodeId, body_len: NodeId)
    if_stmt(condition: NodeId, then_body_start: NodeId, then_body_len: NodeId, else_body_start: NodeId, else_body_len: NodeId)
    while_stmt(condition: NodeId, body_start: NodeId, body_len: NodeId)
    for_stmt(init: NodeId, condition: NodeId, post: NodeId, body_start: NodeId, body_len: NodeId)
    switch_stmt(expression: NodeId, cases_start: NodeId, cases_len: NodeId, default_body_start: NodeId, default_body_len: NodeId, exhaustive: bool)
    return_stmt(value: NodeId)
    break_stmt
    continue_stmt
    goto_stmt(label: str)
    label_stmt(name: str)
    expression_stmt(expr: NodeId)
    static_assert_stmt(condition: NodeId, message: str)

# ═══════════════════════════════════════════════════════════════════════════
# IR Declarations (module-level)
# ═══════════════════════════════════════════════════════════════════════════

public struct IrField:
    name: str
    field_type: types.TypeId

public struct IrEnumMember:
    name: str
    linkage_name: str
    value: int

public struct IrParam:
    name: str
    linkage_name: str
    param_type: types.TypeId
    pointer: bool

public struct IrVariantArm:
    name: str
    linkage_name: str
    fields_start: NodeId
    fields_len: NodeId

public struct IrAggregateField:
    name: str
    value: NodeId

public struct IrSwitchCase:
    value: int
    body_start: NodeId
    body_len: NodeId

public variant IrDecl:
    constant(name: str, linkage_name: str, type_id: types.TypeId, value: NodeId)
    global(name: str, linkage_name: str, type_id: types.TypeId, value: NodeId)
    struct_decl(name: str, linkage_name: str, fields_start: NodeId, fields_len: NodeId, packed: bool, alignment: int)
    union_decl(name: str, linkage_name: str, fields_start: NodeId, fields_len: NodeId)
    enum_decl(name: str, linkage_name: str, backing_type: types.TypeId, members_start: NodeId, members_len: NodeId)
    variant_decl(name: str, linkage_name: str, arms_start: NodeId, arms_len: NodeId)
    opaque_decl(name: str, linkage_name: str)
    function_decl(name: str, linkage_name: str, params_start: NodeId, params_len: NodeId, return_type: types.TypeId, body_start: NodeId, body_len: NodeId)

# ═══════════════════════════════════════════════════════════════════════════
# IR Program (top-level compilation unit)
# ═══════════════════════════════════════════════════════════════════════════

public struct IrUnit:
    module_name: str
    expressions: vec.Vec[IrExpr]
    statements: vec.Vec[IrStmt]
    declarations: vec.Vec[IrDecl]
    fields: vec.Vec[IrField]
    enum_members: vec.Vec[IrEnumMember]
    params: vec.Vec[IrParam]
    variant_arms: vec.Vec[IrVariantArm]
    aggregate_fields: vec.Vec[IrAggregateField]
    switch_cases: vec.Vec[IrSwitchCase]

extending IrUnit:
    public static function create(module_name: str) -> IrUnit:
        var unit = IrUnit(
            module_name = module_name,
            expressions = vec.Vec[IrExpr].create(),
            statements = vec.Vec[IrStmt].create(),
            declarations = vec.Vec[IrDecl].create(),
            fields = vec.Vec[IrField].create(),
            enum_members = vec.Vec[IrEnumMember].create(),
            params = vec.Vec[IrParam].create(),
            variant_arms = vec.Vec[IrVariantArm].create(),
            aggregate_fields = vec.Vec[IrAggregateField].create(),
            switch_cases = vec.Vec[IrSwitchCase].create(),
        )
        unit.expressions.push(IrExpr.integer_literal(value = 0, type_id = 0z))
        unit.statements.push(IrStmt.expression_stmt(expr = 0z))
        unit.declarations.push(IrDecl.constant(name = "", linkage_name = "", type_id = 0z, value = 0z))
        unit.fields.push(IrField(name = "", field_type = 0z))
        unit.enum_members.push(IrEnumMember(name = "", linkage_name = "", value = 0))
        unit.params.push(IrParam(name = "", linkage_name = "", param_type = 0z, pointer = false))
        unit.variant_arms.push(IrVariantArm(name = "", linkage_name = "", fields_start = 0z, fields_len = 0z))
        unit.aggregate_fields.push(IrAggregateField(name = "", value = 0z))
        unit.switch_cases.push(IrSwitchCase(value = 0, body_start = 0z, body_len = 0z))
        return unit

    public editable function alloc_expr(expr: IrExpr) -> NodeId:
        this.expressions.push(expr)
        return this.expressions.len - 1

    public editable function alloc_stmt(stmt: IrStmt) -> NodeId:
        this.statements.push(stmt)
        return this.statements.len - 1

    public editable function push_decl(decl: IrDecl) -> void:
        this.declarations.push(decl)

    public editable function store_fields(field_vec: vec.Vec[IrField]) -> NodeId:
        let start = this.fields.len
        var i: ptr_uint = 0
        while i < field_vec.len:
            let f = field_vec.at(i) else:
                break
            this.fields.push(f)
            i += 1
        return start

    public editable function store_enum_members(member_vec: vec.Vec[IrEnumMember]) -> NodeId:
        let start = this.enum_members.len
        var i: ptr_uint = 0
        while i < member_vec.len:
            let m = member_vec.at(i) else:
                break
            this.enum_members.push(m)
            i += 1
        return start

    public editable function store_params(param_vec: vec.Vec[IrParam]) -> NodeId:
        let start = this.params.len
        var i: ptr_uint = 0
        while i < param_vec.len:
            let p = param_vec.at(i) else:
                break
            this.params.push(p)
            i += 1
        return start

    public editable function store_arms(arm_vec: vec.Vec[IrVariantArm]) -> NodeId:
        let start = this.variant_arms.len
        var i: ptr_uint = 0
        while i < arm_vec.len:
            let a = arm_vec.at(i) else:
                break
            this.variant_arms.push(a)
            i += 1
        return start

    public editable function store_aggregate_fields(field_vec: vec.Vec[IrAggregateField]) -> NodeId:
        let start = this.aggregate_fields.len
        var i: ptr_uint = 0
        while i < field_vec.len:
            let f = field_vec.at(i) else:
                break
            this.aggregate_fields.push(f)
            i += 1
        return start

    public editable function store_switch_cases(case_vec: vec.Vec[IrSwitchCase]) -> NodeId:
        let start = this.switch_cases.len
        var i: ptr_uint = 0
        while i < case_vec.len:
            let c = case_vec.at(i) else:
                break
            this.switch_cases.push(c)
            i += 1
        return start
