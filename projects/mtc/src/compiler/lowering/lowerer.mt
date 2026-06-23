## Lowerer — AST → IR transformation.

import compiler.lexer.token_kind as tk
import compiler.parser.ast as ast
import compiler.parser.operators as ops_mod
import compiler.lowering.ir as ir
import std.intern
import std.mem.arena
import std.str
import std.vec

type B = ops_mod.BinaryOp


struct Lowerer:
    arena: arena.Arena
    interner: ptr[intern.Interner]
    in_editable: bool


public function lower(
    file: ptr[ast.SourceFile],
    interner: ptr[intern.Interner],
) -> ir.IrProgram:
    var l = Lowerer(
        arena = arena.create(64 * 1024),
        interner = interner,
        in_editable = false,
    )
    return l.lower_impl(file)


extending Lowerer:
    editable function lower_impl(file: ptr[ast.SourceFile]) -> ir.IrProgram:
        var functions = vec.Vec[ir.IrFunction].create()
        var structs = vec.Vec[ir.IrStruct].create()
        var enums = vec.Vec[ir.IrEnum].create()
        let decls_span = unsafe: file.decls.as_span()
        var i: ptr_uint = 0
        while i < decls_span.len:
            let decl = unsafe: read(decls_span.data + i)
            unsafe:
                match read(decl):
                    ast.Decl.function_def(name, _, params, return_type, body, _, _, _, _):
                        let f = this.lower_function(name, params, return_type, body)
                        functions.push(f)
                    ast.Decl.struct_decl(name, fields, _, _):
                        let s = this.lower_struct(name, fields)
                        structs.push(s)
                    ast.Decl.enum_decl(name, _, members, _, _):
                        let e = this.lower_enum(name, members)
                        enums.push(e)
                    ast.Decl.extending_decl(type_name, methods, _):
                        this.lower_extending(type_name, methods, ref_of(functions))
                    _:
                        pass
            i += 1
        return ir.IrProgram(
            structs = this.copy_structs(ref_of(structs)),
            enums = this.copy_enums(ref_of(enums)),
            functions = this.copy_funcs(ref_of(functions)),
        )


    editable function lower_struct(name: ast.IdentId, fields: span[ast.Field]) -> ir.IrStruct:
        let cname = this.name_str(name)
        var ir_fields = vec.Vec[ir.IrField].create()
        var i: ptr_uint = 0
        while i < fields.len:
            let field = unsafe: read(fields.data + i)
            ir_fields.push(ir.IrField(
                name = this.name_str(field.name),
                type_c = this.type_c_name(field.type_ref),
            ))
            i += 1
        return ir.IrStruct(
            name = cname,
            fields = this.copy_fields(ref_of(ir_fields)),
        )


    editable function lower_enum(name: ast.IdentId, members: span[ast.EnumMember]) -> ir.IrEnum:
        let cname = this.name_str(name)
        var ir_members = vec.Vec[ir.IrEnumMember].create()
        var autoval: int = 0
        var i: ptr_uint = 0
        while i < members.len:
            let m = unsafe: read(members.data + i)
            var val: int = autoval
            if m.value != zero[ptr[ast.Expr]]:
                val = this.eval_enum_value(m.value)
                autoval = val
            ir_members.push(ir.IrEnumMember(
                name = this.name_str(m.name),
                value = val,
            ))
            autoval += 1
            i += 1
        return ir.IrEnum(
            name = cname,
            members = this.copy_enum_members(ref_of(ir_members)),
        )


    function eval_enum_value(expr: ptr[ast.Expr]) -> int:
        unsafe:
            match read(expr):
                ast.Expr.integer_literal(value, _):
                    return value
                _:
                    return 0


    editable function lower_extending(
        type_name: ast.IdentId,
        methods: span[ast.ExtendingMethod],
        functions: ref[vec.Vec[ir.IrFunction]],
    ) -> void:
        let tname = this.name_str(type_name)
        var mi: ptr_uint = 0
        while mi < methods.len:
            let method = unsafe: read(methods.data + mi)
            let f = this.lower_method(tname, method)
            functions.push(f)
            mi += 1


    editable function lower_method(type_name: str, method: ast.ExtendingMethod) -> ir.IrFunction:
        let cname = this.name_str(method.name)
        var ir_params = vec.Vec[ir.IrParam].create()

        if method.method_kind == ast.MethodKind.mk_editable:
            ir_params.push(ir.IrParam(name = "this", type_c = type_name))
        else if method.method_kind == ast.MethodKind.mk_plain:
            ir_params.push(ir.IrParam(name = "this", type_c = type_name))

        var pi: ptr_uint = 0
        while pi < method.params.len:
            let param = unsafe: read(method.params.data + pi)
            ir_params.push(ir.IrParam(
                name = this.name_str(param.name),
                type_c = this.type_c_name(param.type_ref),
            ))
            pi += 1

        var save_editable = this.in_editable
        this.in_editable = method.method_kind == ast.MethodKind.mk_editable
        var ir_body = this.lower_block(method.body)
        this.in_editable = save_editable

        return ir.IrFunction(
            name = cname,
            params = this.copy_params(ref_of(ir_params)),
            return_c = this.type_c_name(method.return_type),
            body = this.copy_stmts(ref_of(ir_body)),
            is_editable = method.method_kind == ast.MethodKind.mk_editable,
        )


    editable function lower_function(
        name_id: ast.IdentId,
        params: span[ast.Param],
        return_type: ptr[ast.Type],
        body: ptr[ast.Stmt],
    ) -> ir.IrFunction:
        let name = this.name_str(name_id)
        var ir_params = vec.Vec[ir.IrParam].create()
        var i: ptr_uint = 0
        while i < params.len:
            let param = unsafe: read(params.data + i)
            ir_params.push(ir.IrParam(
                name = this.name_str(param.name),
                type_c = this.type_c_name(param.type_ref),
            ))
            i += 1

        var ir_body = this.lower_block(body)

        return ir.IrFunction(
            name = name,
            params = this.copy_params(ref_of(ir_params)),
            return_c = this.type_c_name(return_type),
            body = this.copy_stmts(ref_of(ir_body)),
        )


    ## ── type → C name ──────────────────────────────────────────────

    function type_c_name(type_ref: ptr[ast.Type]) -> str:
        if type_ref == zero[ptr[ast.Type]]:
            return "void"
        unsafe:
            match read(type_ref):
                ast.Type.named_type(name, _):
                    let s = this.name_str(name)
                    return this.map_type_c(s)
                _:
                    return "int"


    function map_type_c(mt_name: str) -> str:
        if mt_name.equal("int"):
            return "int"
        if mt_name.equal("float"):
            return "float"
        if mt_name.equal("double"):
            return "double"
        if mt_name.equal("bool"):
            return "bool"
        if mt_name.equal("void"):
            return "void"
        if mt_name.equal("str"):
            return "char*"
        if mt_name.equal("cstr"):
            return "char*"
        if mt_name.equal("byte"):
            return "int8_t"
        if mt_name.equal("ubyte"):
            return "uint8_t"
        if mt_name.equal("short"):
            return "int16_t"
        if mt_name.equal("ushort"):
            return "uint16_t"
        if mt_name.equal("uint"):
            return "uint32_t"
        if mt_name.equal("long"):
            return "int64_t"
        if mt_name.equal("ulong"):
            return "uint64_t"
        if mt_name.equal("char"):
            return "char"
        return mt_name


    ## ── statements ─────────────────────────────────────────────────

    editable function lower_block(stmt: ptr[ast.Stmt]) -> vec.Vec[ir.IrStmt]:
        var result = vec.Vec[ir.IrStmt].create()
        unsafe:
            match read(stmt):
                ast.Stmt.block(stmts, _):
                    var i: ptr_uint = 0
                    while i < stmts.len:
                        let s = read(stmts.data + i)
                        this.lower_stmt(s, ref_of(result))
                        i += 1
                _:
                    pass
        return result


    editable function lower_stmt(stmt: ptr[ast.Stmt], output: ref[vec.Vec[ir.IrStmt]]) -> void:
        unsafe:
            match read(stmt):
                ast.Stmt.return_stmt(value, _):
                    if value == zero[ptr[ast.Expr]]:
                        output.push(ir.IrStmt.return_void)
                    else:
                        let v = this.lower_expr(value)
                        output.push(ir.IrStmt.return_stmt(value = v))
                ast.Stmt.expression(expr, _):
                    let v = this.lower_expr(expr)
                    output.push(ir.IrStmt.expr_stmt(expr = v))
                ast.Stmt.if_stmt(branches, else_body, _):
                    this.lower_if(branches, else_body, output)
                ast.Stmt.while_stmt(condition, body, _):
                    this.lower_while(condition, body, output)
                ast.Stmt.unsafe_block(body, _):
                    this.lower_block_into(body, output)
                ast.Stmt.block(stmts, _):
                    this.lower_block_stmts(stmts, output)
                ast.Stmt.local_decl(_, name, type_ref, value, _, _, _):
                    let n = this.name_str(name)
                    let tc = this.type_c_name(type_ref)
                    var init = ir.IrExpr.integer(value = 0)
                    if value != zero[ptr[ast.Expr]]:
                        init = this.lower_expr(value)
                    output.push(ir.IrStmt.decl(name = n, type_c = tc, init = init))
                ast.Stmt.assignment(target, op, value, _):
                    let tname = this.target_name(target)
                    let v = this.lower_expr(value)
                    let op_str = this.assign_op_c(op)
                    if this.has_member_target(target):
                        let texpr = this.lower_expr(target)
                        let tp = this.new_ir_expr(texpr)
                        output.push(ir.IrStmt.assign_expr(target = texpr, op_kind = op_str, value = v))
                    else:
                        output.push(ir.IrStmt.assign(target = tname, op_kind = op_str, value = v))
                ast.Stmt.match_stmt(scrutinee, arms, _):
                    this.lower_match(scrutinee, arms, output)
                ast.Stmt.for_stmt(bindings, iterables, body, _):
                    this.lower_for(bindings, iterables, body, output)
                ast.Stmt.break_stmt(_):
                    output.push(ir.IrStmt.break_stmt)
                ast.Stmt.continue_stmt(_):
                    output.push(ir.IrStmt.continue_stmt)
                _:
                    pass


    editable function lower_if(
        branches: span[ast.IfBranch],
        else_body: ptr[ast.Stmt],
        output: ref[vec.Vec[ir.IrStmt]],
    ) -> void:
        if branches.len == 0:
            return
        let first = unsafe: read(branches.data + 0)
        let cond = this.lower_expr(first.condition)
        var then_body = vec.Vec[ir.IrStmt].create()
        this.lower_block_into(first.body, ref_of(then_body))

        var else_ir = vec.Vec[ir.IrStmt].create()
        if branches.len > 1:
            var tail = span[ast.IfBranch](
                data = unsafe: branches.data + 1,
                len = branches.len - 1,
            )
            this.lower_if(tail, else_body, ref_of(else_ir))
        else if else_body != zero[ptr[ast.Stmt]]:
            this.lower_block_into(else_body, ref_of(else_ir))

        output.push(ir.IrStmt.if_stmt(
            condition = cond,
            then_body = this.copy_stmts(ref_of(then_body)),
            else_body = this.copy_stmts(ref_of(else_ir)),
        ))


    editable function lower_while(
        condition: ptr[ast.Expr],
        body: ptr[ast.Stmt],
        output: ref[vec.Vec[ir.IrStmt]],
    ) -> void:
        let cond = this.lower_expr(condition)
        var body_ir = vec.Vec[ir.IrStmt].create()
        this.lower_block_into(body, ref_of(body_ir))
        output.push(ir.IrStmt.while_stmt(
            condition = cond,
            body = this.copy_stmts(ref_of(body_ir)),
        ))


    editable function lower_for(
        bindings: span[ast.ForBinding],
        iterables: span[ptr[ast.Expr]],
        body: ptr[ast.Stmt],
        output: ref[vec.Vec[ir.IrStmt]],
    ) -> void:
        if bindings.len == 0 or iterables.len == 0:
            return
        let iterable = unsafe: read(iterables.data + 0)
        let binding = unsafe: read(bindings.data + 0)
        let bname = this.name_str(binding.name)
        var body_ir = vec.Vec[ir.IrStmt].create()
        this.lower_block_into(body, ref_of(body_ir))
        let body_span = this.copy_stmts(ref_of(body_ir))

        unsafe:
            match read(iterable):
                ast.Expr.range_expr(start, end, _):
                    let s = this.lower_expr(start)
                    let e = this.lower_expr(end)
                    output.push(ir.IrStmt.for_range(
                        binding = bname,
                        start = s,
                        end = e,
                        body = body_span,
                    ))
                    return
                _:
                    pass

        let iter = this.lower_expr(iterable)
        output.push(ir.IrStmt.for_stmt(
            binding = bname,
            iterable = iter,
            body = body_span,
        ))


    editable function lower_match(
        scrutinee: ptr[ast.Expr],
        arms: span[ast.MatchArm],
        output: ref[vec.Vec[ir.IrStmt]],
    ) -> void:
        let scrut_ir = this.lower_expr(scrutinee)
        var ir_arms = vec.Vec[ir.IrMatchArm].create()
        if arms.len == 0:
            return
        var i: ptr_uint = 0
        while i < arms.len:
            let arm = unsafe: read(arms.data + i)
            var values = vec.Vec[ir.IrExpr].create()
            this.lower_match_pattern(arm.pattern, ref_of(values))
            while i + 1 < arms.len and this.same_body(arm.body, unsafe: read(arms.data + i + 1).body):
                i += 1
                let next = unsafe: read(arms.data + i)
                this.lower_match_pattern(next.pattern, ref_of(values))
            var body_ir = vec.Vec[ir.IrStmt].create()
            this.lower_block_into(arm.body, ref_of(body_ir))
            ir_arms.push(ir.IrMatchArm(
                values = this.copy_ir_exprs(ref_of(values)),
                body = this.copy_stmts(ref_of(body_ir)),
            ))
            i += 1
        output.push(ir.IrStmt.match_stmt(
            scrutinee = scrut_ir,
            arms = this.copy_match_arms(ref_of(ir_arms)),
        ))


    function same_body(a: ptr[ast.Stmt], b: ptr[ast.Stmt]) -> bool:
        return a == b


    editable function lower_match_pattern(pattern: ptr[ast.Pattern], values: ref[vec.Vec[ir.IrExpr]]) -> void:
        unsafe:
            match read(pattern):
                ast.Pattern.wildcard(_):
                    pass
                ast.Pattern.int_literal(value, _):
                    values.push(ir.IrExpr.integer(value = value))
                ast.Pattern.char_literal(value, _):
                    values.push(ir.IrExpr.integer(value = int<-value))
                ast.Pattern.variant_arm(type_name, arm_name, _, _, _):
                    values.push(ir.IrExpr.name(name = this.name_str(arm_name)))
                _:
                    pass


    editable function lower_block_into(stmt: ptr[ast.Stmt], output: ref[vec.Vec[ir.IrStmt]]) -> void:
        unsafe:
            match read(stmt):
                ast.Stmt.block(stmts, _):
                    this.lower_block_stmts(stmts, output)
                _:
                    this.lower_stmt(stmt, output)


    editable function lower_block_stmts(stmts: span[ptr[ast.Stmt]], output: ref[vec.Vec[ir.IrStmt]]) -> void:
        var i: ptr_uint = 0
        while i < stmts.len:
            let s = unsafe: read(stmts.data + i)
            this.lower_stmt(s, output)
            i += 1


    ## ── expressions ────────────────────────────────────────────────

    editable function lower_expr(expr: ptr[ast.Expr]) -> ir.IrExpr:
        unsafe:
            match read(expr):
                ast.Expr.integer_literal(value, _):
                    return ir.IrExpr.integer(value = value)
                ast.Expr.identifier(name, _):
                    return ir.IrExpr.name(name = this.name_str(name))
                ast.Expr.binary_op(operator, left, right, _):
                    let l = this.lower_expr(left)
                    let r = this.lower_expr(right)
                    let op = this.binary_op_c(operator)
                    let lp = this.new_ir_expr(l)
                    let rp = this.new_ir_expr(r)
                    return ir.IrExpr.binary(op = op, left = lp, right = rp)
                ast.Expr.unary_op(operator, operand, _):
                    let o = this.lower_expr(operand)
                    let op = this.unary_op_c(operator)
                    let op_ptr = this.new_ir_expr(o)
                    return ir.IrExpr.unary(op = op, operand = op_ptr)
                ast.Expr.call(callee, args, _):
                    let cname = this.callee_name(callee)
                    let m = cname
                    if m.equal("fatal"):
                        var a = this.lower_args(args)
                        return ir.IrExpr.call(name = cname, args = this.copy_ir_exprs(ref_of(a)))
                    if m.equal("read"):
                        var a = this.lower_args(args)
                        if args.len > 0:
                            let val_opt = a.at(0)
                            let op = val_opt else:
                                return ir.IrExpr.integer(value = 0)
                            let op_ptr = this.new_ir_expr(op)
                            return ir.IrExpr.deref(operand = op_ptr)
                        return ir.IrExpr.integer(value = 0)
                    if m.equal("ptr_of"):
                        var a2 = this.lower_args(args)
                        if args.len > 0:
                            let val_opt2 = a2.at(0)
                            let op2 = val_opt2 else:
                                return ir.IrExpr.integer(value = 0)
                            let op_ptr2 = this.new_ir_expr(op2)
                            return ir.IrExpr.address(operand = op_ptr2)
                        return ir.IrExpr.integer(value = 0)
                    var a = this.lower_args(args)
                    return ir.IrExpr.call(name = cname, args = this.copy_ir_exprs(ref_of(a)))
                ast.Expr.member_access(receiver, member, _):
                    let rec = this.lower_expr(receiver)
                    let rp = this.new_ir_expr(rec)
                    if this.in_editable:
                        return ir.IrExpr.ptr_access(receiver = rp, member = this.name_str(member))
                    return ir.IrExpr.access(receiver = rp, member = this.name_str(member))
                ast.Expr.null_literal(_):
                    return ir.IrExpr.null_value
                ast.Expr.aggregate(type_name, fields, _):
                    return this.lower_aggregate(type_name, fields)
                ast.Expr.specialization(callee, _, _):
                    let cname = this.callee_name(callee)
                    if cname.equal("zero"):
                        return ir.IrExpr.null_value
                    return ir.IrExpr.integer(value = 0)
                _:
                    return ir.IrExpr.integer(value = 0)


    editable function callee_name(expr: ptr[ast.Expr]) -> str:
        unsafe:
            match read(expr):
                ast.Expr.identifier(name, _):
                    return this.name_str(name)
                ast.Expr.member_access(_, member, _):
                    return this.name_str(member)
                _:
                    return ""


    editable function lower_args(args: span[ptr[ast.Expr]]) -> vec.Vec[ir.IrExpr]:
        var result = vec.Vec[ir.IrExpr].create()
        var i: ptr_uint = 0
        while i < args.len:
            let arg = unsafe: read(args.data + i)
            result.push(this.lower_expr(arg))
            i += 1
        return result


    ## ── aggregate ────────────────────────────────────────────────────

    editable function lower_aggregate(type_name: ast.IdentId, fields: span[ast.TupleField]) -> ir.IrExpr:
        let cname = this.name_str(type_name)
        var ir_fields = vec.Vec[ir.IrAggregateField].create()
        var i: ptr_uint = 0
        while i < fields.len:
            let fld = unsafe: read(fields.data + i)
            let val = this.lower_expr(fld.value)
            ir_fields.push(ir.IrAggregateField(
                name = this.name_str(fld.name),
                value = val,
            ))
            i += 1
        return ir.IrExpr.aggregate(name = cname, fields = this.copy_agg_fields(ref_of(ir_fields)))


    ## ── assignment helpers ────────────────────────────────────────────

    function target_name(expr: ptr[ast.Expr]) -> str:
        unsafe:
            match read(expr):
                ast.Expr.identifier(name, _):
                    return this.name_str(name)
                ast.Expr.member_access(receiver, member, _):
                    return this.name_str(member)
                _:
                    return "?"

    function has_member_target(expr: ptr[ast.Expr]) -> bool:
        unsafe:
            match read(expr):
                ast.Expr.member_access(_, _, _):
                    return true
                _:
                    return false

    function assign_op_c(kind: tk.TokenKind) -> str:
        if kind == tk.TokenKind.tk_equal:
            return "="
        if kind == tk.TokenKind.tk_plus_equal:
            return "+="
        if kind == tk.TokenKind.tk_minus_equal:
            return "-="
        if kind == tk.TokenKind.tk_star_equal:
            return "*="
        if kind == tk.TokenKind.tk_slash_equal:
            return "/="
        if kind == tk.TokenKind.tk_percent_equal:
            return "%="
        if kind == tk.TokenKind.tk_amp_equal:
            return "&="
        if kind == tk.TokenKind.tk_pipe_equal:
            return "|="
        if kind == tk.TokenKind.tk_caret_equal:
            return "^="
        if kind == tk.TokenKind.tk_shift_left_equal:
            return "<<="
        if kind == tk.TokenKind.tk_shift_right_equal:
            return ">>="
        return "="


    ## ── operators ──────────────────────────────────────────────────

    function unary_op_c(op: ops_mod.UnaryOp) -> str:
        if op == ops_mod.UnaryOp.uop_negate:
            return "-"
        if op == ops_mod.UnaryOp.uop_bit_not:
            return "~"
        if op == ops_mod.UnaryOp.uop_logic_not:
            return "!"
        return "-"

    function binary_op_c(op: ops_mod.BinaryOp) -> str:
        if op == B.op_add:
            return "+"
        if op == B.op_sub:
            return "-"
        if op == B.op_mul:
            return "*"
        if op == B.op_div:
            return "/"
        if op == B.op_mod:
            return "%"
        if op == B.op_eq:
            return "=="
        if op == B.op_ne:
            return "!="
        if op == B.op_lt:
            return "<"
        if op == B.op_le:
            return "<="
        if op == B.op_gt:
            return ">"
        if op == B.op_ge:
            return ">="
        if op == B.op_logic_and:
            return "&&"
        if op == B.op_logic_or:
            return "||"
        if op == B.op_bit_and:
            return "&"
        if op == B.op_bit_or:
            return "|"
        if op == B.op_bit_xor:
            return "^"
        if op == B.op_shift_left:
            return "<<"
        if op == B.op_shift_right:
            return ">>"
        return "??"


    ## ── interner ───────────────────────────────────────────────────

    function name_str(id: ast.IdentId) -> str:
        unsafe:
            let result = this.interner.lookup(id) else:
                return "?"
            return result


    ## ── arena helpers ──────────────────────────────────────────────

    editable function new_ir_expr(value: ir.IrExpr) -> ptr[ir.IrExpr]:
        let p = this.arena.alloc[ir.IrExpr](1) else:
            fatal(c"lowerer: arena exhausted")
        unsafe: read(p) = value
        return p

    editable function copy_fields(src: ref[vec.Vec[ir.IrField]]) -> span[ir.IrField]:
        if src.len == 0:
            return span[ir.IrField](data = zero[ptr[ir.IrField]], len = 0)
        let storage = this.arena.alloc[ir.IrField](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrField](data = storage, len = src.len)

    editable function copy_structs(src: ref[vec.Vec[ir.IrStruct]]) -> span[ir.IrStruct]:
        if src.len == 0:
            return span[ir.IrStruct](data = zero[ptr[ir.IrStruct]], len = 0)
        let storage = this.arena.alloc[ir.IrStruct](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrStruct](data = storage, len = src.len)

    editable function copy_params(src: ref[vec.Vec[ir.IrParam]]) -> span[ir.IrParam]:
        if src.len == 0:
            return span[ir.IrParam](data = zero[ptr[ir.IrParam]], len = 0)
        let storage = this.arena.alloc[ir.IrParam](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrParam](data = storage, len = src.len)

    editable function copy_agg_fields(src: ref[vec.Vec[ir.IrAggregateField]]) -> span[ir.IrAggregateField]:
        if src.len == 0:
            return span[ir.IrAggregateField](data = zero[ptr[ir.IrAggregateField]], len = 0)
        let storage = this.arena.alloc[ir.IrAggregateField](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrAggregateField](data = storage, len = src.len)

    editable function copy_stmts(src: ref[vec.Vec[ir.IrStmt]]) -> span[ir.IrStmt]:
        if src.len == 0:
            return span[ir.IrStmt](data = zero[ptr[ir.IrStmt]], len = 0)
        let storage = this.arena.alloc[ir.IrStmt](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrStmt](data = storage, len = src.len)

    editable function copy_ir_exprs(src: ref[vec.Vec[ir.IrExpr]]) -> span[ir.IrExpr]:
        if src.len == 0:
            return span[ir.IrExpr](data = zero[ptr[ir.IrExpr]], len = 0)
        let storage = this.arena.alloc[ir.IrExpr](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrExpr](data = storage, len = src.len)

    editable function copy_match_arms(src: ref[vec.Vec[ir.IrMatchArm]]) -> span[ir.IrMatchArm]:
        if src.len == 0:
            return span[ir.IrMatchArm](data = zero[ptr[ir.IrMatchArm]], len = 0)
        let storage = this.arena.alloc[ir.IrMatchArm](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrMatchArm](data = storage, len = src.len)

    editable function copy_enums(src: ref[vec.Vec[ir.IrEnum]]) -> span[ir.IrEnum]:
        if src.len == 0:
            return span[ir.IrEnum](data = zero[ptr[ir.IrEnum]], len = 0)
        let storage = this.arena.alloc[ir.IrEnum](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrEnum](data = storage, len = src.len)

    editable function copy_enum_members(src: ref[vec.Vec[ir.IrEnumMember]]) -> span[ir.IrEnumMember]:
        if src.len == 0:
            return span[ir.IrEnumMember](data = zero[ptr[ir.IrEnumMember]], len = 0)
        let storage = this.arena.alloc[ir.IrEnumMember](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrEnumMember](data = storage, len = src.len)

    editable function copy_funcs(src: ref[vec.Vec[ir.IrFunction]]) -> span[ir.IrFunction]:
        if src.len == 0:
            return span[ir.IrFunction](data = zero[ptr[ir.IrFunction]], len = 0)
        let storage = this.arena.alloc[ir.IrFunction](src.len) else:
            fatal(c"lowerer: arena exhausted")
        var i: ptr_uint = 0
        while i < src.len:
            let val = src.at(i) else:
                fatal(c"lowerer: vec access out of bounds")
            unsafe: read(storage + i) = val
            i += 1
        return span[ir.IrFunction](data = storage, len = src.len)
