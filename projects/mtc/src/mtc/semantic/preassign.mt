## Binding-ID preassignment pass, extracted from semantic/analyzer.mt.

import mtc.parser.ast as ast
import mtc.semantic.analyzer as analyzer


## The host's `preassign_local_binding_ids`: give every local declaration,
## match-arm binding and for binding in `body` its binding id, in the host's
## walk order, before the body is checked.
public function preassign_body_binding_ids(ctx: ref[analyzer.Context], body: ptr[ast.Stmt]?) -> void:
    ctx.preassigned_ids.clear()
    let b = body else:
        return
    preassign_stmt_binding_ids(ctx, unsafe: read(b))


function preassign_binding_id_at(ctx: ref[analyzer.Context], key: ptr_uint) -> void:
    if ctx.preassigned_ids.contains(key):
        return
    ctx.preassigned_ids.set(key, analyzer.allocate_binding_id(ctx))


function preassign_stmt_span_binding_ids(ctx: ref[analyzer.Context], statements: span[ast.Stmt]) -> void:
    var i: ptr_uint = 0
    while i < statements.len:
        preassign_stmt_binding_ids(ctx, unsafe: read(statements.data + i))
        i += 1


function preassign_stmt_binding_ids(ctx: ref[analyzer.Context], s: ast.Stmt) -> void:
    match s:
        ast.Stmt.stmt_block as blk:
            preassign_stmt_span_binding_ids(ctx, blk.statements)
        ast.Stmt.stmt_local as l:
            preassign_binding_id_at(ctx, analyzer.binding_key(l.line, l.column))
            let lv = l.value
            if lv != null:
                preassign_expr_binding_ids(ctx, unsafe: read(lv))
            let leb = l.else_body
            match l.else_binding:
                Option.some:
                    if leb != null:
                        preassign_binding_id_at(ctx, analyzer.binding_key(l.else_binding_line, l.else_binding_column))
                Option.none:
                    pass
            if leb != null:
                preassign_stmt_binding_ids(ctx, unsafe: read(leb))
        ast.Stmt.stmt_assignment as a:
            preassign_expr_binding_ids(ctx, unsafe: read(a.target))
            preassign_expr_binding_ids(ctx, unsafe: read(a.value))
        ast.Stmt.stmt_if as i:
            var bi: ptr_uint = 0
            while bi < i.branches.len:
                var br: ast.IfBranch = unsafe: read(i.branches.data + bi)
                preassign_expr_binding_ids(ctx, unsafe: read(br.condition))
                preassign_stmt_binding_ids(ctx, unsafe: read(br.body))
                bi += 1
            let ieb = i.else_body
            if ieb != null:
                preassign_stmt_binding_ids(ctx, unsafe: read(ieb))
        ast.Stmt.stmt_while as w:
            preassign_expr_binding_ids(ctx, unsafe: read(w.condition))
            let wb = w.body
            if wb != null:
                preassign_stmt_binding_ids(ctx, unsafe: read(wb))
        ast.Stmt.stmt_for as fr:
            var fi: ptr_uint = 0
            while fi < fr.bindings.len:
                var binding: ast.ForBinding = unsafe: read(fr.bindings.data + fi)
                preassign_binding_id_at(ctx, analyzer.binding_key(binding.line, binding.column))
                fi += 1
            var ii: ptr_uint = 0
            while ii < fr.iterables.len:
                preassign_expr_binding_ids(ctx, unsafe: read(fr.iterables.data + ii))
                ii += 1
            let fb = fr.body
            if fb != null:
                preassign_stmt_binding_ids(ctx, unsafe: read(fb))
        ast.Stmt.stmt_match as m:
            preassign_expr_binding_ids(ctx, unsafe: read(m.scrutinee))
            preassign_match_arm_span_binding_ids(ctx, m.arms)
        ast.Stmt.stmt_ret as r:
            let rv = r.value
            if rv != null:
                preassign_expr_binding_ids(ctx, unsafe: read(rv))
        ast.Stmt.stmt_defer as d:
            let de = d.expression
            if de != null:
                preassign_expr_binding_ids(ctx, unsafe: read(de))
            let db = d.body
            if db != null:
                preassign_stmt_binding_ids(ctx, unsafe: read(db))
        ast.Stmt.stmt_unsafe as u:
            let ub = u.body
            if ub != null:
                preassign_stmt_binding_ids(ctx, unsafe: read(ub))
        ast.Stmt.stmt_expression as e:
            preassign_expr_binding_ids(ctx, unsafe: read(e.expression))
        ast.Stmt.stmt_static_assert as sa:
            preassign_expr_binding_ids(ctx, unsafe: read(sa.condition))
            let sm = sa.message
            if sm != null:
                preassign_expr_binding_ids(ctx, unsafe: read(sm))
        ast.Stmt.stmt_error_block as eb:
            preassign_stmt_binding_ids(ctx, unsafe: read(eb.body))
        _:
            pass


function preassign_match_arm_span_binding_ids(ctx: ref[analyzer.Context], arms: span[ast.MatchArm]) -> void:
    var ai: ptr_uint = 0
    while ai < arms.len:
        var arm: ast.MatchArm = unsafe: read(arms.data + ai)
        let ap = arm.pattern
        if ap != null:
            preassign_expr_binding_ids(ctx, unsafe: read(ap))
        match arm.binding_name:
            Option.some:
                preassign_binding_id_at(ctx, analyzer.binding_key(arm.binding_line, arm.binding_column))
            Option.none:
                pass
        preassign_pattern_argument_binding_ids(ctx, arm.pattern)
        let ab = arm.body
        if ab != null:
            preassign_stmt_binding_ids(ctx, unsafe: read(ab))
        ai += 1


function preassign_match_expr_arm_span_binding_ids(ctx: ref[analyzer.Context], arms: span[ast.MatchExprArm]) -> void:
    var ai: ptr_uint = 0
    while ai < arms.len:
        var arm: ast.MatchExprArm = unsafe: read(arms.data + ai)
        let ap = arm.pattern
        if ap != null:
            preassign_expr_binding_ids(ctx, unsafe: read(ap))
        match arm.binding_name:
            Option.some:
                preassign_binding_id_at(ctx, analyzer.binding_key(arm.binding_line, arm.binding_column))
            Option.none:
                pass
        preassign_pattern_argument_binding_ids(ctx, arm.pattern)
        preassign_expr_binding_ids(ctx, unsafe: read(arm.value))
        ai += 1


## A struct-pattern call's positional identifier arguments bind
## (`Point(x, y)`): the host's preassign allocates an id for each unnamed
## identifier argument.
function preassign_pattern_argument_binding_ids(ctx: ref[analyzer.Context], pattern: ptr[ast.Expr]?) -> void:
    let p = pattern else:
        return
    unsafe:
        match read(p):
            ast.Expr.expr_call as cl:
                var i: ptr_uint = 0
                while i < cl.args.len:
                    var arg: ast.Argument = read(cl.args.data + i)
                    var unnamed = false
                    match arg.arg_name:
                        Option.none:
                            unnamed = true
                        Option.some:
                            pass
                    if unnamed:
                        match read(arg.arg_value):
                            ast.Expr.expr_identifier as id:
                                preassign_binding_id_at(ctx, analyzer.binding_key(id.line, id.column))
                            _:
                                pass
                    i += 1
            _:
                pass


function preassign_expr_binding_ids(ctx: ref[analyzer.Context], e: ast.Expr) -> void:
    unsafe:
        match e:
            ast.Expr.expr_member_access as ma:
                preassign_expr_binding_ids(ctx, read(ma.receiver))
            ast.Expr.expr_index_access as ix:
                preassign_expr_binding_ids(ctx, read(ix.receiver))
                preassign_expr_binding_ids(ctx, read(ix.index))
            ast.Expr.expr_specialization as sp:
                preassign_expr_binding_ids(ctx, read(sp.callee))
            ast.Expr.expr_call as cl:
                preassign_expr_binding_ids(ctx, read(cl.callee))
                var i: ptr_uint = 0
                while i < cl.args.len:
                    var arg: ast.Argument = read(cl.args.data + i)
                    preassign_expr_binding_ids(ctx, read(arg.arg_value))
                    i += 1
            ast.Expr.expr_unary_op as u:
                preassign_expr_binding_ids(ctx, read(u.operand))
            ast.Expr.expr_binary_op as b:
                preassign_expr_binding_ids(ctx, read(b.left))
                preassign_expr_binding_ids(ctx, read(b.right))
            ast.Expr.expr_range as r:
                preassign_expr_binding_ids(ctx, read(r.start_expr))
                preassign_expr_binding_ids(ctx, read(r.end_expr))
            ast.Expr.expr_if as ife:
                preassign_expr_binding_ids(ctx, read(ife.condition))
                preassign_expr_binding_ids(ctx, read(ife.then_expr))
                preassign_expr_binding_ids(ctx, read(ife.else_expr))
            ast.Expr.expr_match as me:
                preassign_expr_binding_ids(ctx, read(me.scrutinee))
                preassign_match_expr_arm_span_binding_ids(ctx, me.arms)
            ast.Expr.expr_unsafe as u:
                preassign_expr_binding_ids(ctx, read(u.expression))
            ast.Expr.expr_prefix_cast as c:
                preassign_expr_binding_ids(ctx, read(c.expression))
            ast.Expr.expr_await as aw:
                preassign_expr_binding_ids(ctx, read(aw.expression))
            ast.Expr.expr_format_string as fs:
                var pi: ptr_uint = 0
                while pi < fs.parts.len:
                    var part: ast.FormatStringPart = read(fs.parts.data + pi)
                    match part:
                        ast.FormatStringPart.fmt_expr as fe:
                            preassign_expr_binding_ids(ctx, read(fe.expression))
                        ast.FormatStringPart.fmt_text:
                            pass
                    pi += 1
            ast.Expr.expr_proc as pr:
                preassign_stmt_binding_ids(ctx, read(pr.body))
            ast.Expr.expr_named as n:
                preassign_expr_binding_ids(ctx, read(n.value))
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    preassign_expr_binding_ids(ctx, read(el.elements.data + ei))
                    ei += 1
            ast.Expr.expr_detach as dt:
                preassign_expr_binding_ids(ctx, read(dt.expression))
            _:
                pass
