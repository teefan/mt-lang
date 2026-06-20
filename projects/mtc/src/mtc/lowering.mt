# AST-to-IR lowering for the self-hosting compiler.
# Mirrors lib/milk_tea/core/lowering.rb, lowering/block.rb, lowering/expressions.rb.
#
# Produces an IrUnit from a SourceFile + ModuleContext.

import std.vec
import mtc.types
import mtc.ast
import mtc.ir
import mtc.sema.context

public struct Lowerer:
    ir: ir.IrUnit
    ctx: context.ModuleContext
    file: ast.SourceFile

extending Lowerer:
    public static function create(
        ctx: context.ModuleContext, file: ast.SourceFile, module_name: str,
    ) -> Lowerer:
        return Lowerer(
            ir = ir.IrUnit.create(module_name),
            ctx = ctx,
            file = file,
        )

    public editable function lower() -> ir.IrUnit:
        this.lower_declarations()
        this.lower_functions()
        return this.ir

    # ═══════════════════════════════════════════════════════════════════════
    # Declaration lowering
    # ═══════════════════════════════════════════════════════════════════════

    editable function lower_declarations() -> void:
        var i: ptr_uint = 1
        while i < this.file.declarations.len:
            let decl = this.file.declarations.at(i) else:
                break
            match decl:
                ast.Decl.struct_decl as sd:
                    this.lower_struct(sd.name, sd.fields_start, sd.fields_len)
                ast.Decl.variant_decl as vd:
                    this.lower_variant(vd.name, vd.arms_start, vd.arms_len)
                ast.Decl.enum_decl as ed:
                    this.lower_enum(ed.name, ed.members_start, ed.members_len)
                ast.Decl.flags_decl as fd:
                    this.lower_enum(fd.name, fd.members_start, fd.members_len)
                ast.Decl.opaque_decl as od:
                    this.lower_opaque(od.name, od.c_name)
                ast.Decl.union_decl as ud:
                    this.lower_union(ud.name, ud.fields_start, ud.fields_len)
                ast.Decl.const_decl as cd:
                    this.lower_const(cd.name, cd.type_id)
                ast.Decl.var_decl as vd:
                    this.lower_global(vd.name, vd.type_id)
                _:
                    pass
            i += 1

    editable function lower_struct(
        name: str, fields_start: ast.NodeId, fields_len: ast.NodeId,
    ) -> void:
        var fields = vec.Vec[ir.IrField].create()
        var j: ptr_uint = 0
        while j < fields_len:
            let f = this.file.fields.at(fields_start + j) else:
                break
            let ft = this.resolve_field_type(f.type_expr_id)
            fields.push(ir.IrField(name = f.name, field_type = ft))
            j += 1
        let fs = this.ir.store_fields(fields)
        this.ir.push_decl(ir.IrDecl.struct_decl(
            name = name, linkage_name = name,
            fields_start = fs, fields_len = fields.len,
            packed = false, alignment = 0,
        ))

    editable function lower_variant(
        name: str, arms_start: ast.NodeId, arms_len: ast.NodeId,
    ) -> void:
        var arms = vec.Vec[ir.IrVariantArm].create()
        var p: ptr_uint = 0
        while p < arms_len:
            let arm = this.file.variant_arms.at(arms_start + p) else:
                break
            var arm_fields = vec.Vec[ir.IrField].create()
            var j: ptr_uint = 0
            while j < arm.fields.len:
                let af = arm.fields.at(j) else:
                    break
                let ft = this.resolve_type_ref_type(af.field_type)
                arm_fields.push(ir.IrField(name = af.name, field_type = ft))
                j += 1
            let afs = this.ir.store_fields(arm_fields)
            arms.push(ir.IrVariantArm(
                name = arm.name, linkage_name = arm.name,
                fields_start = afs, fields_len = arm_fields.len,
            ))
            p += 1
        let as_start = this.ir.store_arms(arms)
        this.ir.push_decl(ir.IrDecl.variant_decl(
            name = name, linkage_name = name,
            arms_start = as_start, arms_len = arms.len,
        ))

    editable function lower_enum(
        name: str, members_start: ast.NodeId, members_len: ast.NodeId,
    ) -> void:
        var members = vec.Vec[ir.IrEnumMember].create()
        var j: ptr_uint = 0
        while j < members_len:
            let em = this.file.enum_members.at(members_start + j) else:
                break
            members.push(ir.IrEnumMember(
                name = em.name, linkage_name = em.name, value = int<-(j),
            ))
            j += 1
        let mem_start = this.ir.store_enum_members(members)
        this.ir.push_decl(ir.IrDecl.enum_decl(
            name = name, linkage_name = name,
            backing_type = this.ctx.arena.primitive_int(),
            members_start = mem_start, members_len = members.len,
        ))

    editable function lower_opaque(name: str, c_name: str) -> void:
        this.ir.push_decl(ir.IrDecl.opaque_decl(
            name = name, linkage_name = name,
        ))

    editable function lower_union(
        name: str, fields_start: ast.NodeId, fields_len: ast.NodeId,
    ) -> void:
        var fields = vec.Vec[ir.IrField].create()
        var j: ptr_uint = 0
        while j < fields_len:
            let f = this.file.fields.at(fields_start + j) else:
                break
            let ft = this.resolve_field_type(f.type_expr_id)
            fields.push(ir.IrField(name = f.name, field_type = ft))
            j += 1
        let fs = this.ir.store_fields(fields)
        this.ir.push_decl(ir.IrDecl.union_decl(
            name = name, linkage_name = name,
            fields_start = fs, fields_len = fields.len,
        ))

    editable function lower_const(name: str, type_id: ast.NodeId) -> void:
        this.ir.push_decl(ir.IrDecl.constant(
            name = name, linkage_name = name,
            type_id = type_id, value = 0z,
        ))

    editable function lower_global(name: str, type_id: ast.NodeId) -> void:
        this.ir.push_decl(ir.IrDecl.global(
            name = name, linkage_name = name,
            type_id = type_id, value = 0z,
        ))

    # ═══════════════════════════════════════════════════════════════════════
    # Function lowering
    # ═══════════════════════════════════════════════════════════════════════

    editable function lower_functions() -> void:
        var i: ptr_uint = 1
        while i < this.file.declarations.len:
            let decl = this.file.declarations.at(i) else:
                break
            match decl:
                ast.Decl.func_def(name, params_start, params_len, return_type, body, _, is_async, is_const):
                    this.lower_function(
                        name, params_start, params_len, return_type, body, is_async, is_const,
                    )
                _:
                    pass
            i += 1

    editable function lower_function(
        name: str, params_start: ast.NodeId, params_len: ast.NodeId,
        return_type: ast.NodeId, body: ast.NodeId,
        _is_async: bool, _is_const: bool,
    ) -> void:
        var params = vec.Vec[ir.IrParam].create()
        var j: ptr_uint = 0
        while j < params_len:
            let param = this.file.params.at(params_start + j) else:
                break
            let pt = this.resolve_field_type(param.type_expr_id)
            params.push(ir.IrParam(
                name = param.name, linkage_name = param.name,
                param_type = pt, pointer = false,
            ))
            j += 1
        let ps = this.ir.store_params(params)

        var return_id: types.TypeId = this.ctx.arena.primitive_void()
        if return_type != 0z:
            return_id = this.resolve_field_type(return_type)

        var body_start: ir.NodeId = 0z
        var body_len: ir.NodeId = 0z
        if body != 0z:
            body_start = this.ir.statements.len
            this.lower_block_stmts(body)
            body_len = this.ir.statements.len - body_start

        this.ir.push_decl(ir.IrDecl.function_decl(
            name = name, linkage_name = name,
            params_start = ps, params_len = params.len,
            return_type = return_id,
            body_start = body_start, body_len = body_len,
        ))

    # ═══════════════════════════════════════════════════════════════════════
    # Block statement lowering
    # ═══════════════════════════════════════════════════════════════════════

    editable function lower_block_stmts(first_stmt: ast.NodeId) -> void:
        var i = first_stmt
        while i < this.file.stmts.len:
            let stmt = this.file.stmts.at(i) else:
                break
            match stmt:
                ast.Stmt.expression_stmt(expr_id, _):
                    let ir_expr = this.lower_expr(expr_id)
                    this.ir_push_stmt(ir.IrStmt.expression_stmt(expr = ir_expr))
                ast.Stmt.local_decl(kind, name, type_id, value_id, else_body, _, _):
                    this.lower_local_decl(name, type_id, value_id, kind)
                ast.Stmt.assignment(target, operator, value, _, _):
                    this.lower_assignment(target, operator, value)
                ast.Stmt.return_stmt(value_id, _, _):
                    this.lower_return(value_id)
                    break
                ast.Stmt.if_stmt(branches_start, branches_len, else_body, _, _, _):
                    this.lower_if_stmt(branches_start, branches_len, else_body)
                ast.Stmt.while_stmt(condition, body, _, _, _):
                    this.lower_while_stmt(condition, body)
                ast.Stmt.for_stmt(bindings_start, _, iterables_start, _, body, _, _, _, _):
                    this.lower_for_stmt(body)
                ast.Stmt.break_stmt:
                    this.ir_push_stmt(ir.IrStmt.break_stmt)
                ast.Stmt.continue_stmt:
                    this.ir_push_stmt(ir.IrStmt.continue_stmt)
                ast.Stmt.pass_stmt:
                    pass
                _:
                    pass
            i += 1

    editable function lower_local_decl(
        name: str, type_id_param: ast.NodeId, value_id: ast.NodeId, _kind: str,
    ) -> void:
        var value: ir.NodeId = 0z
        var storage_type: types.TypeId = this.ctx.arena.primitive_void()
        if value_id != 0z:
            value = this.lower_expr(value_id)
            storage_type = this.ctx.arena.primitive_int()
        if type_id_param != 0z:
            storage_type = this.resolve_field_type(type_id_param)
        this.ir_push_stmt(ir.IrStmt.local_decl(
            name = name, linkage_name = name,
            type_id = storage_type, value = value,
        ))

    editable function lower_assignment(
        target: ast.NodeId, operator: str, value: ast.NodeId,
    ) -> void:
        let ir_target = this.lower_expr(target)
        let ir_value = this.lower_expr(value)
        this.ir_push_stmt(ir.IrStmt.assignment(
            target = ir_target, operator = operator, value = ir_value,
        ))

    editable function lower_return(value_id: ast.NodeId) -> void:
        var ir_value: ir.NodeId = 0z
        if value_id != 0z:
            ir_value = this.lower_expr(value_id)
        this.ir_push_stmt(ir.IrStmt.return_stmt(value = ir_value))

    editable function lower_if_stmt(
        branches_start: ast.NodeId, branches_len: ast.NodeId,
        else_body: ast.NodeId,
    ) -> void:
        var condition: ir.NodeId = 0z
        var then_start: ir.NodeId = 0z
        var then_len: ir.NodeId = 0z
        var else_start: ir.NodeId = 0z
        var else_len: ir.NodeId = 0z
        if branches_start != 0z and branches_len > 0z:
            let branch = this.file.if_branches.at(branches_start) else:
                return
            condition = this.lower_expr(branch.condition)
            if branch.body != 0z:
                then_start = this.ir.statements.len
                this.lower_block_stmts(branch.body)
                then_len = this.ir.statements.len - then_start
        if else_body != 0z:
            else_start = this.ir.statements.len
            this.lower_block_stmts(else_body)
            else_len = this.ir.statements.len - else_start
        this.ir_push_stmt(ir.IrStmt.if_stmt(
            condition = condition,
            then_body_start = then_start,
            then_body_len = then_len,
            else_body_start = else_start,
            else_body_len = else_len,
        ))

    editable function lower_while_stmt(
        condition: ast.NodeId, body: ast.NodeId,
    ) -> void:
        let cond = this.lower_expr(condition)
        var body_start: ir.NodeId = 0z
        var body_len: ir.NodeId = 0z
        if body != 0z:
            body_start = this.ir.statements.len
            this.lower_block_stmts(body)
            body_len = this.ir.statements.len - body_start
        this.ir_push_stmt(ir.IrStmt.while_stmt(
            condition = cond, body_start = body_start, body_len = body_len,
        ))

    editable function lower_for_stmt(body: ast.NodeId) -> void:
        var init: ir.NodeId = 0z
        var condition: ir.NodeId = 0z
        var post: ir.NodeId = 0z
        var body_start: ir.NodeId = 0z
        var body_len: ir.NodeId = 0z
        if body != 0z:
            body_start = this.ir.statements.len
            this.lower_block_stmts(body)
            body_len = this.ir.statements.len - body_start
        this.ir_push_stmt(ir.IrStmt.for_stmt(
            init = init, condition = condition, post = post,
            body_start = body_start, body_len = body_len,
        ))

    # ═══════════════════════════════════════════════════════════════════════
    # Expression lowering
    # ═══════════════════════════════════════════════════════════════════════

    editable function lower_expr(expr_id: ast.NodeId) -> ir.NodeId:
        if expr_id == 0z:
            return 0z
        let expr = this.file.exprs.at(expr_id) else:
            return 0z
        match expr:
            ast.Expr.identifier(name, _, _):
                return this.ir_alloc_expr(ir.IrExpr.name(
                    name = name,
                    type_id = this.ctx.arena.primitive_int(),
                    pointer = false,
                ))
            ast.Expr.member_access(receiver, member, _, _):
                let r = this.lower_expr(receiver)
                return this.ir_alloc_expr(ir.IrExpr.member(
                    receiver = r, member_name = member,
                    type_id = this.ctx.arena.primitive_int(),
                ))
            ast.Expr.index_access(receiver, index, _, _):
                let r = this.lower_expr(receiver)
                let idx = this.lower_expr(index)
                return this.ir_alloc_expr(ir.IrExpr.index(
                    receiver = r, index_expr = idx,
                    type_id = this.ctx.arena.primitive_int(),
                ))
            ast.Expr.call(callee, args_start, args_len, _, _):
                return this.lower_call(callee, args_start, args_len)
            ast.Expr.integer_literal(value):
                return this.ir_alloc_expr(ir.IrExpr.integer_literal(
                    value = value,
                    type_id = this.ctx.arena.primitive_int(),
                ))
            ast.Expr.string_literal as sl:
                return this.ir_alloc_expr(ir.IrExpr.string_literal(
                    value = sl.value,
                    type_id = this.ctx.arena.primitive_str(),
                    cstring = false,
                ))
            ast.Expr.cstring_literal as cl:
                return this.ir_alloc_expr(ir.IrExpr.string_literal(
                    value = cl.value,
                    type_id = this.ctx.arena.primitive_cstr(),
                    cstring = true,
                ))
            ast.Expr.boolean_literal as bl:
                return this.ir_alloc_expr(ir.IrExpr.boolean_literal(
                    value = bl.value, type_id = this.ctx.arena.primitive_bool(),
                ))
            ast.Expr.float_literal as fl:
                return this.ir_alloc_expr(ir.IrExpr.float_literal(
                    value = fl.value,
                    type_id = this.ctx.arena.primitive_double(),
                ))
            ast.Expr.char_literal as ch:
                return this.ir_alloc_expr(ir.IrExpr.integer_literal(
                    value = int<-(ch.value),
                    type_id = this.ctx.arena.primitive_char(),
                ))
            ast.Expr.null_literal(type_id):
                return this.ir_alloc_expr(ir.IrExpr.null_literal(
                    type_id = this.ctx.arena.primitive_int(),
                ))
            ast.Expr.binary_op(operator, left, right):
                let l = this.lower_expr(left)
                let r = this.lower_expr(right)
                var result_type: types.TypeId = this.ctx.arena.primitive_int()
                if operator == "==" or operator == "!=" or operator == "<" or operator == "<=" or operator == ">" or operator == ">=":
                    result_type = this.ctx.arena.primitive_bool()
                else if operator == "and" or operator == "or":
                    result_type = this.ctx.arena.primitive_bool()
                return this.ir_alloc_expr(ir.IrExpr.binary(
                    operator = operator, left = l, right = r,
                    type_id = result_type,
                ))
            ast.Expr.unary_op(operator, operand):
                let op = this.lower_expr(operand)
                return this.ir_alloc_expr(ir.IrExpr.unary(
                    operator = operator, operand = op,
                    type_id = this.ctx.arena.primitive_int(),
                ))
            ast.Expr.prefix_cast(target_type, expression):
                let te = this.lower_expr(expression)
                let tt = this.resolve_field_type(target_type)
                return this.ir_alloc_expr(ir.IrExpr.cast(
                    target_type = tt, expression = te,
                    type_id = tt,
                ))
            ast.Expr.format_string(_, _):
                return this.ir_alloc_expr(ir.IrExpr.string_literal(
                    value = "", type_id = this.ctx.arena.primitive_str(),
                    cstring = false,
                ))
            ast.Expr.if_expr(condition, then_expr, else_expr):
                let cond = this.lower_expr(condition)
                let te = this.lower_expr(then_expr)
                let ee = this.lower_expr(else_expr)
                return this.ir_alloc_expr(ir.IrExpr.conditional(
                    condition = cond, then_expr = te, else_expr = ee,
                    type_id = this.ctx.arena.primitive_int(),
                ))
            ast.Expr.expression_list(elements_start, elements_len):
                return 0z
            ast.Expr.error_expr(_, _, _):
                return 0z
            _:
                return 0z

    editable function lower_call(
        callee_id: ast.NodeId, args_start: ast.NodeId, args_len: ast.NodeId,
    ) -> ir.NodeId:
        let callee_ir = this.lower_expr(callee_id)
        var ir_args_start: ir.NodeId = this.ir.expressions.len
        var ir_args_len: ir.NodeId = 0z
        if args_len > 0z:
            var j: ptr_uint = 0
            while j < args_len:
                let _arg = this.lower_expr(args_start + j)
                j += 1
            ir_args_len = args_len
        return this.ir_alloc_expr(ir.IrExpr.call(
            callee = callee_ir, args_start = ir_args_start, args_len = ir_args_len,
            type_id = this.ctx.arena.primitive_int(),
        ))

    # ═══════════════════════════════════════════════════════════════════════
    # IR allocation helpers
    # ═══════════════════════════════════════════════════════════════════════

    editable function ir_alloc_expr(expr: ir.IrExpr) -> ir.NodeId:
        return this.ir.alloc_expr(expr)

    editable function ir_push_stmt(stmt: ir.IrStmt) -> void:
        let _sid = this.ir.alloc_stmt(stmt)

    # ═══════════════════════════════════════════════════════════════════════
    # Type resolution helpers
    # ═══════════════════════════════════════════════════════════════════════

    editable function resolve_field_type(expr_id: ast.NodeId) -> types.TypeId:
        if expr_id == 0z:
            return this.ctx.arena.primitive_void()
        let expr = this.file.exprs.at(expr_id) else:
            return this.ctx.error_type_id
        match expr:
            ast.Expr.identifier(name, _, _):
                return this.resolve_type_name(name)
            ast.Expr.member_access(receiver, member, _, _):
                return this.resolve_type_name(member)
            _:
                pass
        return this.ctx.error_type_id

    editable function resolve_type_ref_type(ref: ast.TypeRef) -> types.TypeId:
        if ref.name.parts.len == 0z:
            return this.ctx.arena.primitive_void()
        let name = ref.name.parts.at(0) else:
            return this.ctx.error_type_id
        return this.resolve_type_name(name)

    editable function resolve_type_name(name: str) -> types.TypeId:
        let tp = this.ctx.types.get(name) else:
            return this.ctx.arena.ensure_primitive(name)
        return unsafe: read(tp)
