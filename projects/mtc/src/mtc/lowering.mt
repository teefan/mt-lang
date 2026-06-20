# AST-to-IR lowering for the self-hosting compiler.
# Consumes a SourceFile + ModuleContext, produces an IrUnit.

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
        return Lowerer(ir = ir.IrUnit.create(module_name), ctx = ctx, file = file)

    public editable function lower() -> ir.IrUnit:
        this.lower_declarations()
        this.lower_functions()
        return this.ir

    # ── Declaration lowering ──

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

    editable function lower_struct(name: str, fs: ast.NodeId, fl: ast.NodeId) -> void:
        var fields = vec.Vec[ir.IrField].create()
        var j: ptr_uint = 0
        while j < fl:
            let f = this.file.fields.at(fs + j) else:
                break
            fields.push(ir.IrField(name = f.name, field_type = this.resolve_field_type(f.type_expr_id)))
            j += 1
        let st = this.ir.store_fields(fields)
        this.ir.push_decl(ir.IrDecl.struct_decl(name = name, linkage_name = name, fields_start = st, fields_len = fields.len, packed = false, alignment = 0))

    editable function lower_variant(name: str, as_start: ast.NodeId, as_len: ast.NodeId) -> void:
        var arms = vec.Vec[ir.IrVariantArm].create()
        var p: ptr_uint = 0
        while p < as_len:
            let arm = this.file.variant_arms.at(as_start + p) else:
                break
            var arm_fields = vec.Vec[ir.IrField].create()
            var j: ptr_uint = 0
            while j < arm.fields.len:
                let af = arm.fields.at(j) else:
                    break
                arm_fields.push(ir.IrField(name = af.name, field_type = this.resolve_type_ref_type(af.field_type)))
                j += 1
            let afs = this.ir.store_fields(arm_fields)
            arms.push(ir.IrVariantArm(name = arm.name, linkage_name = arm.name, fields_start = afs, fields_len = arm_fields.len))
            p += 1
        let s = this.ir.store_arms(arms)
        this.ir.push_decl(ir.IrDecl.variant_decl(name = name, linkage_name = name, arms_start = s, arms_len = arms.len))

    editable function lower_enum(name: str, ms: ast.NodeId, ml: ast.NodeId) -> void:
        var members = vec.Vec[ir.IrEnumMember].create()
        var j: ptr_uint = 0
        while j < ml:
            let em = this.file.enum_members.at(ms + j) else:
                break
            members.push(ir.IrEnumMember(name = em.name, linkage_name = em.name, value = int<-(j)))
            j += 1
        let st = this.ir.store_enum_members(members)
        this.ir.push_decl(ir.IrDecl.enum_decl(name = name, linkage_name = name, backing_type = this.ctx.arena.primitive_int(), members_start = st, members_len = members.len))

    editable function lower_opaque(name: str, c_name: str) -> void:
        this.ir.push_decl(ir.IrDecl.opaque_decl(name = name, linkage_name = name))

    editable function lower_union(name: str, fs: ast.NodeId, fl: ast.NodeId) -> void:
        var fields = vec.Vec[ir.IrField].create()
        var j: ptr_uint = 0
        while j < fl:
            let f = this.file.fields.at(fs + j) else:
                break
            fields.push(ir.IrField(name = f.name, field_type = this.resolve_field_type(f.type_expr_id)))
            j += 1
        let st = this.ir.store_fields(fields)
        this.ir.push_decl(ir.IrDecl.union_decl(name = name, linkage_name = name, fields_start = st, fields_len = fields.len))

    editable function lower_const(name: str, type_id: ast.NodeId) -> void:
        this.ir.push_decl(ir.IrDecl.constant(name = name, linkage_name = name, type_id = type_id, value = 0z))

    editable function lower_global(name: str, type_id: ast.NodeId) -> void:
        this.ir.push_decl(ir.IrDecl.global(name = name, linkage_name = name, type_id = type_id, value = 0z))

    # ── Function lowering ──

    editable function lower_functions() -> void:
        var i: ptr_uint = 1
        while i < this.file.declarations.len:
            let decl = this.file.declarations.at(i) else:
                break
            match decl:
                ast.Decl.func_def as fd:
                    this.lower_func(fd.name, fd.params_start, fd.params_len, fd.return_type, fd.body, fd.body_len)
                _:
                    pass
            i += 1

    editable function lower_func(
        name: str, ps: ast.NodeId, pl: ast.NodeId,
        rt: ast.NodeId, body: ast.NodeId, bl: ast.NodeId,
    ) -> void:
        var params = vec.Vec[ir.IrParam].create()
        var j: ptr_uint = 0
        while j < pl:
            let param = this.file.params.at(ps + j) else:
                break
            params.push(ir.IrParam(name = param.name, linkage_name = param.name, param_type = this.resolve_field_type(param.type_expr_id), pointer = false))
            j += 1
        let pst = this.ir.store_params(params)

        var return_type: types.TypeId = this.ctx.arena.primitive_void()
        if rt != 0z:
            return_type = this.resolve_field_type(rt)

        var bstart: ir.NodeId = 0z
        var blen: ir.NodeId = 0z
        if body != 0z and bl > 0z:
            bstart = this.ir.statements.len
            this.lower_stmts(body, bl)
            blen = this.ir.statements.len - bstart

        this.ir.push_decl(ir.IrDecl.function_decl(name = name, linkage_name = name, params_start = pst, params_len = params.len, return_type = return_type, body_start = bstart, body_len = blen))

    # ── Bounded block statement lowering ──

    editable function lower_stmts(first_stmt: ast.NodeId, count: ast.NodeId) -> void:
        var remaining = count
        var i = first_stmt
        while remaining > 0z:
            let stmt = this.file.stmts.at(i) else:
                break
            var consumed: ast.NodeId = 1z
            match stmt:
                ast.Stmt.expression_stmt(expr_id, _):
                    this.ir_push_stmt(ir.IrStmt.expression_stmt(expr = this.lower_expr(expr_id)))
                ast.Stmt.local_decl(kind, name, type_id, value_id, else_body, _, _):
                    this.lower_local(name, type_id, value_id, kind)
                ast.Stmt.assignment(target, operator, value, _, _):
                    this.lower_assign(target, operator, value)
                ast.Stmt.return_stmt(value_id, _, _):
                    this.lower_ret(value_id)
                ast.Stmt.if_stmt(condition, body, body_len, else_body, else_body_len, _, _, _):
                    this.lower_if(condition, body, body_len, else_body, else_body_len)
                    consumed = 1z + body_len + else_body_len
                ast.Stmt.while_stmt(condition, body, body_len, _, _, _):
                    this.lower_while(condition, body, body_len)
                    consumed = 1z + body_len
                ast.Stmt.for_stmt(_, _, _, _, body, body_len, _, _, _, _):
                    this.lower_for(body, body_len)
                    consumed = 1z + body_len
                ast.Stmt.break_stmt:
                    this.ir_push_stmt(ir.IrStmt.break_stmt)
                ast.Stmt.continue_stmt:
                    this.ir_push_stmt(ir.IrStmt.continue_stmt)
                ast.Stmt.pass_stmt:
                    pass
                _:
                    pass
            i += 1
            remaining -= consumed

    editable function lower_local(name: str, tid: ast.NodeId, vid: ast.NodeId, _kind: str) -> void:
        var value: ir.NodeId = 0z
        var storage_type: types.TypeId = this.ctx.arena.primitive_void()
        if vid != 0z:
            value = this.lower_expr(vid)
            storage_type = this.ctx.arena.primitive_int()
        if tid != 0z:
            storage_type = this.resolve_field_type(tid)
        this.ir_push_stmt(ir.IrStmt.local_decl(name = name, linkage_name = name, type_id = storage_type, value = value))

    editable function lower_assign(target: ast.NodeId, operator: str, value: ast.NodeId) -> void:
        this.ir_push_stmt(ir.IrStmt.assignment(target = this.lower_expr(target), operator = operator, value = this.lower_expr(value)))

    editable function lower_ret(value_id: ast.NodeId) -> void:
        var ir_value: ir.NodeId = 0z
        if value_id != 0z:
            ir_value = this.lower_expr(value_id)
        this.ir_push_stmt(ir.IrStmt.return_stmt(value = ir_value))

    editable function lower_if(
        cond_id: ast.NodeId,
        body: ast.NodeId, body_len: ast.NodeId,
        eb: ast.NodeId, ebl: ast.NodeId,
    ) -> void:
        let condition = this.lower_expr(cond_id)
        var ts: ir.NodeId = 0z
        var tl: ir.NodeId = 0z
        var es: ir.NodeId = 0z
        var el: ir.NodeId = 0z
        if body != 0z and body_len > 0z:
            ts = this.ir.statements.len
            this.lower_stmts(body, body_len)
            tl = this.ir.statements.len - ts
        if eb != 0z and ebl > 0z:
            es = this.ir.statements.len
            this.lower_stmts(eb, ebl)
            el = this.ir.statements.len - es
        this.ir_push_stmt(ir.IrStmt.if_stmt(condition = condition, then_body_start = ts, then_body_len = tl, else_body_start = es, else_body_len = el))

    editable function lower_while(cond_id: ast.NodeId, body: ast.NodeId, body_len: ast.NodeId) -> void:
        let cond = this.lower_expr(cond_id)
        var bs: ir.NodeId = 0z
        var bl: ir.NodeId = 0z
        if body != 0z and body_len > 0z:
            bs = this.ir.statements.len
            this.lower_stmts(body, body_len)
            bl = this.ir.statements.len - bs
        this.ir_push_stmt(ir.IrStmt.while_stmt(condition = cond, body_start = bs, body_len = bl))

    editable function lower_for(body: ast.NodeId, body_len: ast.NodeId) -> void:
        var bs: ir.NodeId = 0z
        var bl: ir.NodeId = 0z
        if body != 0z and body_len > 0z:
            bs = this.ir.statements.len
            this.lower_stmts(body, body_len)
            bl = this.ir.statements.len - bs
        this.ir_push_stmt(ir.IrStmt.for_stmt(init = 0z, condition = 0z, post = 0z, body_start = bs, body_len = bl))

    # ── Expression lowering ──

    editable function lower_expr(expr_id: ast.NodeId) -> ir.NodeId:
        if expr_id == 0z:
            return 0z
        let expr = this.file.exprs.at(expr_id) else:
            return 0z
        match expr:
            ast.Expr.identifier(name, _, _):
                return this.ir_alloc(ir.IrExpr.name(name = name, type_id = this.ctx.arena.primitive_int(), pointer = false))
            ast.Expr.member_access(receiver, member, _, _):
                return this.ir_alloc(ir.IrExpr.member(receiver = this.lower_expr(receiver), member_name = member, type_id = this.ctx.arena.primitive_int()))
            ast.Expr.index_access(receiver, index, _, _):
                return this.ir_alloc(ir.IrExpr.index(receiver = this.lower_expr(receiver), index_expr = this.lower_expr(index), type_id = this.ctx.arena.primitive_int()))
            ast.Expr.call(callee, args_start, args_len, _, _):
                return this.lower_call(callee, args_start, args_len)
            ast.Expr.integer_literal(value):
                return this.ir_alloc(ir.IrExpr.integer_literal(value = value, type_id = this.ctx.arena.primitive_int()))
            ast.Expr.string_literal as sl:
                return this.ir_alloc(ir.IrExpr.string_literal(value = sl.value, type_id = this.ctx.arena.primitive_str(), cstring = false))
            ast.Expr.cstring_literal as cl:
                return this.ir_alloc(ir.IrExpr.string_literal(value = cl.value, type_id = this.ctx.arena.primitive_cstr(), cstring = true))
            ast.Expr.boolean_literal as bl:
                return this.ir_alloc(ir.IrExpr.boolean_literal(value = bl.value, type_id = this.ctx.arena.primitive_bool()))
            ast.Expr.float_literal as fl:
                return this.ir_alloc(ir.IrExpr.float_literal(value = fl.value, type_id = this.ctx.arena.primitive_double()))
            ast.Expr.char_literal as ch:
                return this.ir_alloc(ir.IrExpr.integer_literal(value = int<-(ch.value), type_id = this.ctx.arena.primitive_char()))
            ast.Expr.null_literal(type_id):
                return this.ir_alloc(ir.IrExpr.null_literal(type_id = this.ctx.arena.primitive_int()))
            ast.Expr.binary_op(operator, left, right):
                let l = this.lower_expr(left)
                let r = this.lower_expr(right)
                var rt: types.TypeId = this.ctx.arena.primitive_int()
                if operator == "==" or operator == "!=" or operator == "<" or operator == "<=" or operator == ">" or operator == ">=":
                    rt = this.ctx.arena.primitive_bool()
                else if operator == "and" or operator == "or":
                    rt = this.ctx.arena.primitive_bool()
                return this.ir_alloc(ir.IrExpr.binary(operator = operator, left = l, right = r, type_id = rt))
            ast.Expr.unary_op(operator, operand):
                return this.ir_alloc(ir.IrExpr.unary(operator = operator, operand = this.lower_expr(operand), type_id = this.ctx.arena.primitive_int()))
            ast.Expr.prefix_cast(target_type, expression):
                return this.ir_alloc(ir.IrExpr.cast(target_type = this.resolve_field_type(target_type), expression = this.lower_expr(expression), type_id = this.ctx.arena.primitive_int()))
            ast.Expr.format_string(_, _):
                return this.ir_alloc(ir.IrExpr.string_literal(value = "", type_id = this.ctx.arena.primitive_str(), cstring = false))
            ast.Expr.if_expr(condition, then_expr, else_expr):
                return this.ir_alloc(ir.IrExpr.conditional(condition = this.lower_expr(condition), then_expr = this.lower_expr(then_expr), else_expr = this.lower_expr(else_expr), type_id = this.ctx.arena.primitive_int()))
            _:
                return 0z

    editable function lower_call(callee_id: ast.NodeId, args_start: ast.NodeId, args_len: ast.NodeId) -> ir.NodeId:
        let c = this.lower_expr(callee_id)
        var ias: ir.NodeId = 0z
        var ial: ir.NodeId = 0z
        if args_len > 0z:
            ias = this.ir.expressions.len
            var j: ptr_uint = 0
            while j < args_len:
                let _ = this.lower_expr(args_start + j)
                j += 1
            ial = args_len
        return this.ir_alloc(ir.IrExpr.call(callee = c, args_start = ias, args_len = ial, type_id = this.ctx.arena.primitive_int()))

    # ── IR helpers ──

    editable function ir_alloc(expr: ir.IrExpr) -> ir.NodeId:
        return this.ir.alloc_expr(expr)

    editable function ir_push_stmt(stmt: ir.IrStmt) -> void:
        let _ = this.ir.alloc_stmt(stmt)

    # ── Type resolution ──

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
