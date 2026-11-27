## Structural AST comparison helpers for the linter, extracted from linter/linter.mt.

import mtc.parser.ast as ast


public function stmts_structural_equal(a: ptr[ast.Stmt]?, b: ptr[ast.Stmt]?) -> bool:
    if a == null and b == null:
        return true
    if a == null or b == null:
        return false
    unsafe:
        match read(a):
            ast.Stmt.stmt_ret as ra:
                match read(b):
                    ast.Stmt.stmt_ret as rb:
                        return option_expr_equal(ra.value, rb.value)
                    _:
                        return false
            ast.Stmt.stmt_expression as ea:
                match read(b):
                    ast.Stmt.stmt_expression as eb:
                        return exprs_structural_equal(ea.expression, eb.expression)
                    _:
                        return false
            ast.Stmt.stmt_assignment as aa:
                match read(b):
                    ast.Stmt.stmt_assignment as ab:
                        return aa.operator.equal(ab.operator) and exprs_structural_equal(
                            aa.target,
                            ab.target
                        ) and exprs_structural_equal(aa.value, ab.value)
                    _:
                        return false
            ast.Stmt.stmt_break:
                match read(b):
                    ast.Stmt.stmt_break:
                        return true
                    _:
                        return false
            ast.Stmt.stmt_continue:
                match read(b):
                    ast.Stmt.stmt_continue:
                        return true
                    _:
                        return false
            ast.Stmt.stmt_pass:
                match read(b):
                    ast.Stmt.stmt_pass:
                        return true
                    _:
                        return false
            ast.Stmt.stmt_local as la:
                match read(b):
                    ast.Stmt.stmt_local as lb:
                        if la.is_let != lb.is_let or not la.name.equal(lb.name):
                            return false
                        if not option_type_ref_equal(la.stmt_type, lb.stmt_type):
                            return false
                        if not option_expr_equal(la.value, lb.value):
                            return false
                        if not option_str_equal(la.else_binding, lb.else_binding):
                            return false
                        if not stmts_structural_equal(la.else_body, lb.else_body):
                            return false
                        if not option_span_str_equal(la.destructure_bindings, lb.destructure_bindings):
                            return false
                        return option_str_equal(la.destructure_type_name, lb.destructure_type_name)
                    _:
                        return false
            ast.Stmt.stmt_if:
                return stmt_if_equal(read(a), read(b))
            ast.Stmt.stmt_while as wa:
                match read(b):
                    ast.Stmt.stmt_while as wb:
                        return wa.is_inline == wb.is_inline and exprs_structural_equal(
                            wa.condition,
                            wb.condition
                        ) and stmts_structural_equal(wa.body, wb.body)
                    _:
                        return false
            ast.Stmt.stmt_for:
                return stmt_for_equal(read(a), read(b))
            ast.Stmt.stmt_match as ma:
                match read(b):
                    ast.Stmt.stmt_match as mb:
                        if ma.is_inline != mb.is_inline or ma.arms.len != mb.arms.len:
                            return false
                        if not exprs_structural_equal(ma.scrutinee, mb.scrutinee):
                            return false
                        var i: ptr_uint = 0
                        while i < ma.arms.len:
                            let aa = read(ma.arms.data + i)
                            let ab = read(mb.arms.data + i)
                            if not option_expr_equal(aa.pattern, ab.pattern):
                                return false
                            if not option_str_equal(aa.binding_name, ab.binding_name):
                                return false
                            if not stmts_structural_equal(aa.body, ab.body):
                                return false
                            i += 1
                        return true
                    _:
                        return false
            ast.Stmt.stmt_defer as da:
                match read(b):
                    ast.Stmt.stmt_defer as db:
                        return option_expr_equal(
                            da.expression,
                            db.expression
                        ) and stmts_structural_equal(da.body, db.body)
                    _:
                        return false
            ast.Stmt.stmt_unsafe as ua:
                match read(b):
                    ast.Stmt.stmt_unsafe as ub:
                        return stmts_structural_equal(ua.body, ub.body)
                    _:
                        return false
            ast.Stmt.stmt_static_assert as sa:
                match read(b):
                    ast.Stmt.stmt_static_assert as sb:
                        return exprs_structural_equal(
                            sa.condition,
                            sb.condition
                        ) and option_expr_equal(sa.message, sb.message)
                    _:
                        return false
            ast.Stmt.stmt_when as wa:
                match read(b):
                    ast.Stmt.stmt_when as wb:
                        if wa.branches.len != wb.branches.len:
                            return false
                        if not exprs_structural_equal(wa.discriminant, wb.discriminant):
                            return false
                        var i: ptr_uint = 0
                        while i < wa.branches.len:
                            let ba = read(wa.branches.data + i)
                            let bb = read(wb.branches.data + i)
                            if not exprs_structural_equal(ba.pattern, bb.pattern):
                                return false
                            if not option_str_equal(ba.binding_name, bb.binding_name):
                                return false
                            if not stmt_spans_equal(ba.body, bb.body):
                                return false
                            i += 1
                        return stmts_structural_equal(wa.else_body, wb.else_body)
                    _:
                        return false
            ast.Stmt.stmt_parallel_block as pa:
                match read(b):
                    ast.Stmt.stmt_parallel_block as pb:
                        return stmt_spans_equal(pa.bodies, pb.bodies)
                    _:
                        return false
            ast.Stmt.stmt_gather as ga:
                match read(b):
                    ast.Stmt.stmt_gather as gb:
                        return expr_spans_equal(ga.handles, gb.handles)
                    _:
                        return false
            ast.Stmt.stmt_error_block as ea:
                match read(b):
                    ast.Stmt.stmt_error_block as eb:
                        return ea.message.equal(eb.message) and stmts_structural_equal(ea.body, eb.body)
                    _:
                        return false
            ast.Stmt.stmt_error as ea:
                match read(b):
                    ast.Stmt.stmt_error as eb:
                        return ea.message.equal(eb.message)
                    _:
                        return false
            ast.Stmt.stmt_block as blka:
                match read(b):
                    ast.Stmt.stmt_block as blkb:
                        return stmt_spans_equal(blka.statements, blkb.statements)
                    _:
                        return false
            ast.Stmt.stmt_emit as ea:
                # An emitted declaration is rare in a match arm; compare by
                # identity rather than reimplementing the declaration fingerprint.
                match read(b):
                    ast.Stmt.stmt_emit as eb:
                        return ea.declaration == eb.declaration
                    _:
                        return false
            _:
                return false


public function stmt_if_equal(a: ast.Stmt, b: ast.Stmt) -> bool:
    match a:
        ast.Stmt.stmt_if as ia:
            match b:
                ast.Stmt.stmt_if as ib:
                    if ia.is_inline != ib.is_inline or ia.branches.len != ib.branches.len:
                        return false
                    unsafe:
                        var i: ptr_uint = 0
                        while i < ia.branches.len:
                            let ba = read(ia.branches.data + i)
                            let bb = read(ib.branches.data + i)
                            if not exprs_structural_equal(ba.condition, bb.condition):
                                return false
                            if not stmts_structural_equal(ba.body, bb.body):
                                return false
                            i += 1
                    return stmts_structural_equal(ia.else_body, ib.else_body)
                _:
                    return false
        _:
            return false


public function stmt_for_equal(a: ast.Stmt, b: ast.Stmt) -> bool:
    match a:
        ast.Stmt.stmt_for as fa:
            match b:
                ast.Stmt.stmt_for as fb:
                    if fa.is_inline != fb.is_inline or fa.threaded != fb.threaded:
                        return false
                    if fa.bindings.len != fb.bindings.len or fa.iterables.len != fb.iterables.len:
                        return false
                    unsafe:
                        var i: ptr_uint = 0
                        while i < fa.bindings.len:
                            if not read(fa.bindings.data + i).name.equal(read(fb.bindings.data + i).name):
                                return false
                            i += 1
                        i = 0
                        while i < fa.iterables.len:
                            if not exprs_structural_equal(fa.iterables.data + i, fb.iterables.data + i):
                                return false
                            i += 1
                    return stmts_structural_equal(fa.body, fb.body)
                _:
                    return false
        _:
            return false


public function stmt_spans_equal(a: span[ast.Stmt], b: span[ast.Stmt]) -> bool:
    if a.len != b.len:
        return false
    var i: ptr_uint = 0
    unsafe:
        while i < a.len:
            if not stmts_structural_equal(a.data + i, b.data + i):
                return false
            i += 1
    return true


public function expr_spans_equal(a: span[ast.Expr], b: span[ast.Expr]) -> bool:
    if a.len != b.len:
        return false
    var i: ptr_uint = 0
    unsafe:
        while i < a.len:
            if not exprs_structural_equal(a.data + i, b.data + i):
                return false
            i += 1
    return true


public function option_expr_equal(a: ptr[ast.Expr]?, b: ptr[ast.Expr]?) -> bool:
    if a == null and b == null:
        return true
    if a == null or b == null:
        return false
    return exprs_structural_equal(a, b)


public function option_str_equal(a: Option[str], b: Option[str]) -> bool:
    match a:
        Option.some as av:
            match b:
                Option.some as bv:
                    return av.value.equal(bv.value)
                Option.none:
                    return false
        Option.none:
            match b:
                Option.none:
                    return true
                Option.some:
                    return false


public function option_span_str_equal(a: Option[span[str]], b: Option[span[str]]) -> bool:
    match a:
        Option.some as av:
            match b:
                Option.some as bv:
                    if av.value.len != bv.value.len:
                        return false
                    var i: ptr_uint = 0
                    while i < av.value.len:
                        if not unsafe: read(av.value.data + i).equal(unsafe: read(bv.value.data + i)):
                            return false
                        i += 1
                    return true
                Option.none:
                    return false
        Option.none:
            match b:
                Option.none:
                    return true
                Option.some:
                    return false


public function option_type_ref_equal(a: ptr[ast.TypeRef]?, b: ptr[ast.TypeRef]?) -> bool:
    if a == null and b == null:
        return true
    if a == null or b == null:
        return false
    return type_refs_structural_equal(a, b)


public function qualified_names_structural_equal(a: ast.QualifiedName, b: ast.QualifiedName) -> bool:
    if a.parts.len != b.parts.len or a.type_arguments.len != b.type_arguments.len:
        return false
    var i: ptr_uint = 0
    unsafe:
        while i < a.parts.len:
            if not read(a.parts.data + i).equal(read(b.parts.data + i)):
                return false
            i += 1
        i = 0
        while i < a.type_arguments.len:
            if not type_refs_structural_equal(a.type_arguments.data + i, b.type_arguments.data + i):
                return false
            i += 1
    return true


public function type_refs_structural_equal(a: ptr[ast.TypeRef], b: ptr[ast.TypeRef]) -> bool:
    unsafe:
        let ta = read(a)
        let tb = read(b)
        if ta.nullable != tb.nullable:
            return false
        if ta.is_proc != tb.is_proc or ta.is_fn != tb.is_fn or ta.is_dyn != tb.is_dyn or ta.is_tuple != tb.is_tuple:
            return false
        if not option_str_equal(ta.lifetime, tb.lifetime):
            return false
        if not qualified_names_structural_equal(ta.name, tb.name):
            return false
        if ta.arguments.len != tb.arguments.len:
            return false
        var i: ptr_uint = 0
        while i < ta.arguments.len:
            if not type_refs_structural_equal(ta.arguments.data + i, tb.arguments.data + i):
                return false
            i += 1
        if ta.fn_params.len != tb.fn_params.len:
            return false
        i = 0
        while i < ta.fn_params.len:
            var pa = read(ta.fn_params.data + i)
            var pb = read(tb.fn_params.data + i)
            if not pa.name.equal(pb.name):
                return false
            if not type_refs_structural_equal(ptr_of(pa.param_type), ptr_of(pb.param_type)):
                return false
            if not option_expr_equal(pa.default_value, pb.default_value):
                return false
            i += 1
        if not option_type_ref_equal(ta.fn_return, tb.fn_return):
            return false
        return qualified_names_structural_equal(ta.dyn_interface, tb.dyn_interface)


public function exprs_structural_equal(a: ptr[ast.Expr], b: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(a):
            ast.Expr.expr_identifier as ida:
                match read(b):
                    ast.Expr.expr_identifier as idb:
                        return ida.name.equal(idb.name)
                    _:
                        return false
            ast.Expr.expr_member_access as ma:
                match read(b):
                    ast.Expr.expr_member_access as mb:
                        return ma.member_name.equal(mb.member_name) and exprs_structural_equal(ma.receiver, mb.receiver)
                    _:
                        return false
            ast.Expr.expr_integer_literal as ia:
                match read(b):
                    ast.Expr.expr_integer_literal as ib:
                        return ia.lexeme.equal(ib.lexeme) and ia.value == ib.value
                    _:
                        return false
            ast.Expr.expr_float_literal as ia:
                match read(b):
                    ast.Expr.expr_float_literal as ib:
                        return ia.lexeme.equal(ib.lexeme) and ia.value == ib.value
                    _:
                        return false
            ast.Expr.expr_char_literal as ca:
                match read(b):
                    ast.Expr.expr_char_literal as cb:
                        return ca.lexeme.equal(cb.lexeme) and ca.value == cb.value
                    _:
                        return false
            ast.Expr.expr_bool_literal as ba:
                match read(b):
                    ast.Expr.expr_bool_literal as bb:
                        return ba.value == bb.value
                    _:
                        return false
            ast.Expr.expr_string_literal as sa:
                match read(b):
                    ast.Expr.expr_string_literal as sb:
                        return sa.lexeme.equal(sb.lexeme) and sa.value.equal(sb.value) and sa.is_cstring == sb.is_cstring
                    _:
                        return false
            ast.Expr.expr_null_literal as na:
                match read(b):
                    ast.Expr.expr_null_literal as nb:
                        return option_type_ref_equal(na.target_type, nb.target_type)
                    _:
                        return false
            ast.Expr.expr_format_string as fa:
                match read(b):
                    ast.Expr.expr_format_string as fb:
                        return format_parts_equal(fa.parts, fb.parts)
                    _:
                        return false
            ast.Expr.expr_call as ca:
                match read(b):
                    ast.Expr.expr_call as cb:
                        return call_exprs_equal(ca.callee, ca.args, cb.callee, cb.args)
                    _:
                        return false
            ast.Expr.expr_index_access as xa:
                match read(b):
                    ast.Expr.expr_index_access as xb:
                        return exprs_structural_equal(
                            xa.receiver,
                            xb.receiver
                        ) and exprs_structural_equal(xa.index, xb.index)
                    _:
                        return false
            ast.Expr.expr_specialization as spa:
                match read(b):
                    ast.Expr.expr_specialization as spb:
                        if not exprs_structural_equal(spa.callee, spb.callee):
                            return false
                        if spa.arguments.len != spb.arguments.len:
                            return false
                        var i: ptr_uint = 0
                        while i < spa.arguments.len:
                            if not type_refs_structural_equal(
                                read(spa.arguments.data + i).value,
                                read(spb.arguments.data + i).value
                            ):
                                return false
                            i += 1
                        return true
                    _:
                        return false
            ast.Expr.expr_if as ifa:
                match read(b):
                    ast.Expr.expr_if as ifb:
                        return exprs_structural_equal(
                            ifa.condition,
                            ifb.condition
                        ) and exprs_structural_equal(
                            ifa.then_expr,
                            ifb.then_expr
                        ) and exprs_structural_equal(ifa.else_expr, ifb.else_expr)
                    _:
                        return false
            ast.Expr.expr_match as mma:
                match read(b):
                    ast.Expr.expr_match as mmb:
                        return match_exprs_equal(
                            mma.scrutinee, mma.arms, mma.desugared_from_is,
                            mmb.scrutinee, mmb.arms, mmb.desugared_from_is
                        )
                    _:
                        return false
            ast.Expr.expr_proc as pa:
                match read(b):
                    ast.Expr.expr_proc as pb:
                        return proc_exprs_equal(
                            pa.method_params,
                            pa.return_type,
                            pa.body,
                            pb.method_params,
                            pb.return_type,
                            pb.body
                        )
                    _:
                        return false
            ast.Expr.expr_await as awa:
                match read(b):
                    ast.Expr.expr_await as awb:
                        return exprs_structural_equal(awa.expression, awb.expression)
                    _:
                        return false
            ast.Expr.expr_detach as dta:
                match read(b):
                    ast.Expr.expr_detach as dtb:
                        return exprs_structural_equal(dta.expression, dtb.expression)
                    _:
                        return false
            ast.Expr.expr_expression_list as ela:
                match read(b):
                    ast.Expr.expr_expression_list as elb:
                        return expr_spans_equal(ela.elements, elb.elements)
                    _:
                        return false
            ast.Expr.expr_named as na:
                match read(b):
                    ast.Expr.expr_named as nb:
                        return na.name.equal(nb.name) and exprs_structural_equal(na.value, nb.value)
                    _:
                        return false
            ast.Expr.expr_range as rga:
                match read(b):
                    ast.Expr.expr_range as rgb:
                        return exprs_structural_equal(
                            rga.start_expr,
                            rgb.start_expr
                        ) and exprs_structural_equal(rga.end_expr, rgb.end_expr)
                    _:
                        return false
            ast.Expr.expr_prefix_cast as pca:
                match read(b):
                    ast.Expr.expr_prefix_cast as pcb:
                        return type_refs_structural_equal(
                            pca.target_type,
                            pcb.target_type
                        ) and exprs_structural_equal(pca.expression, pcb.expression)
                    _:
                        return false
            ast.Expr.expr_unsafe as usa:
                match read(b):
                    ast.Expr.expr_unsafe as usb:
                        return exprs_structural_equal(usa.expression, usb.expression)
                    _:
                        return false
            ast.Expr.expr_sizeof as sza:
                match read(b):
                    ast.Expr.expr_sizeof as szb:
                        return type_refs_structural_equal(sza.target_type, szb.target_type)
                    _:
                        return false
            ast.Expr.expr_alignof as ala:
                match read(b):
                    ast.Expr.expr_alignof as alb:
                        return type_refs_structural_equal(ala.target_type, alb.target_type)
                    _:
                        return false
            ast.Expr.expr_offsetof as ofa:
                match read(b):
                    ast.Expr.expr_offsetof as ofb:
                        return ofa.field.equal(ofb.field) and type_refs_structural_equal(
                            ofa.target_type,
                            ofb.target_type
                        )
                    _:
                        return false
            ast.Expr.expr_error as era:
                match read(b):
                    ast.Expr.expr_error as erb:
                        return era.message.equal(erb.message)
                    _:
                        return false
            ast.Expr.expr_unary_op as ua:
                match read(b):
                    ast.Expr.expr_unary_op as ub:
                        return ua.operator.equal(ub.operator) and exprs_structural_equal(ua.operand, ub.operand)
                    _:
                        return false
            ast.Expr.expr_binary_op as ba2:
                match read(b):
                    ast.Expr.expr_binary_op as bb2:
                        return ba2.operator.equal(bb2.operator) and exprs_structural_equal(
                            ba2.left,
                            bb2.left
                        ) and exprs_structural_equal(
                            ba2.right,
                            bb2.right
                        )
                    _:
                        return false
            _:
                return false


public function format_parts_equal(a: span[ast.FormatStringPart], b: span[ast.FormatStringPart]) -> bool:
    if a.len != b.len:
        return false
    unsafe:
        var i: ptr_uint = 0
        while i < a.len:
            match read(a.data + i):
                ast.FormatStringPart.fmt_text as ta:
                    match read(b.data + i):
                        ast.FormatStringPart.fmt_text as tb:
                            if not ta.value.equal(tb.value):
                                return false
                        _:
                            return false
                ast.FormatStringPart.fmt_expr as ea:
                    match read(b.data + i):
                        ast.FormatStringPart.fmt_expr as eb:
                            if not exprs_structural_equal(ea.expression, eb.expression):
                                return false
                            if not format_specs_equal(ea.format_spec, eb.format_spec):
                                return false
                        _:
                            return false
            i += 1
    return true


public function call_exprs_equal(
    callee_a: ptr[ast.Expr], args_a: span[ast.Argument],
    callee_b: ptr[ast.Expr], args_b: span[ast.Argument],
) -> bool:
    if not exprs_structural_equal(callee_a, callee_b):
        return false
    if args_a.len != args_b.len:
        return false
    unsafe:
        var i: ptr_uint = 0
        while i < args_a.len:
            let aa = read(args_a.data + i)
            let ab = read(args_b.data + i)
            if not option_str_equal(aa.arg_name, ab.arg_name):
                return false
            if not exprs_structural_equal(aa.arg_value, ab.arg_value):
                return false
            i += 1
    return true


public function match_exprs_equal(
    scrutinee_a: ptr[ast.Expr], arms_a: span[ast.MatchExprArm], desugared_a: bool,
    scrutinee_b: ptr[ast.Expr], arms_b: span[ast.MatchExprArm], desugared_b: bool,
) -> bool:
    if arms_a.len != arms_b.len or desugared_a != desugared_b:
        return false
    if not exprs_structural_equal(scrutinee_a, scrutinee_b):
        return false
    unsafe:
        var i: ptr_uint = 0
        while i < arms_a.len:
            let aa = read(arms_a.data + i)
            let ab = read(arms_b.data + i)
            if not option_expr_equal(aa.pattern, ab.pattern):
                return false
            if not option_str_equal(aa.binding_name, ab.binding_name):
                return false
            if not exprs_structural_equal(aa.value, ab.value):
                return false
            i += 1
    return true


public function proc_exprs_equal(
    params_a: span[ast.Param], return_a: ptr[ast.TypeRef]?, body_a: ptr[ast.Stmt],
    params_b: span[ast.Param], return_b: ptr[ast.TypeRef]?, body_b: ptr[ast.Stmt],
) -> bool:
    if params_a.len != params_b.len:
        return false
    unsafe:
        var i: ptr_uint = 0
        while i < params_a.len:
            var ra = read(params_a.data + i)
            var rb = read(params_b.data + i)
            if not ra.name.equal(rb.name):
                return false
            if not type_refs_structural_equal(ptr_of(ra.param_type), ptr_of(rb.param_type)):
                return false
            if not option_expr_equal(ra.default_value, rb.default_value):
                return false
            i += 1
    if not option_type_ref_equal(return_a, return_b):
        return false
    return stmts_structural_equal(body_a, body_b)


public function format_specs_equal(a: ptr[ast.FormatSpec]?, b: ptr[ast.FormatSpec]?) -> bool:
    if a == null and b == null:
        return true
    if a == null or b == null:
        return false
    unsafe:
        let sa = read(a)
        let sb = read(b)
        return sa.spec_kind == sb.spec_kind and sa.value == sb.value and sa.uppercase == sb.uppercase
