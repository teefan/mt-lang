## C statement emission, extracted from c_backend/c_backend.mt.

import std.string as string
import std.vec as vec

import mtc.ir as ir
import mtc.semantic.types as types
import mtc.strings
import mtc.c_backend.c_backend as c_backend


public function emit_statement(e: ref[c_backend.Emitter], sp: ptr[ir.Stmt], level: ptr_uint) -> void:
    let indent = c_backend.indent_c(level)
    # Materialize any array-returning call nested in argument position into a
    # temp array local before this statement (C cannot use an array-returning
    # call as a value/argument).  Records substitutions consumed by
    # render_expr.
    c_backend.materialize_stmt_array_calls(e, sp, level)
    # Debug profile: map the statement back to its source location so gdb
    # reports the .mt line rather than the generated C line.
    if e.emit_line_directives:
        unsafe:
            match read(sp):
                ir.Stmt.stmt_local as loc:
                    c_backend.emit_stmt_line_directive(e, loc.line, loc.source_path)
                ir.Stmt.stmt_return as r:
                    c_backend.emit_stmt_line_directive(e, r.line, r.source_path)
                ir.Stmt.stmt_expression as ex:
                    c_backend.emit_stmt_line_directive(e, ex.line, ex.source_path)
                _:
                    pass
    unsafe:
        match read(sp):
            ir.Stmt.stmt_static_assert as sa:
                c_backend.emit_indented(e, indent, c_backend.render_static_assert(e, sa.condition, sa.message))
                return
            _:
                pass
    unsafe:
        match read(sp):
            ir.Stmt.stmt_return as r:
                let value = r.value else:
                    c_backend.emit_indented(e, indent, "return;")
                    return
                # Array-returning function: write into `*__mt_out` (either by
                # calling the array-returning callee with `__mt_out`, or by
                # memcpy'ing the array value) then `return;`.
                if c_backend.is_array_type(e.current_fn_return_type):
                    if c_backend.expr_is_array_call(e, value):
                        c_backend.emit_line(e, strings.join_three(indent, c_backend.emit_array_call(e, value, "__mt_out"), ";"))
                        c_backend.emit_indented(e, indent, "return;")
                    else if c_backend.array_direct_initializer(value):
                        # `return {a, b, ...}`: an array literal can't be memcpy'd
                        # from a bare initializer list, so bind it to a temp array
                        # first, then copy into the out-param.
                        c_backend.emit_indented(e, indent, "{")
                        let inner = c_backend.indent_c(level + 1)
                        c_backend.emit_line(
                            e,
                            strings.join_five(
                                inner,
                                c_backend.c_decl(e.current_fn_return_type, "__mt_ret"),
                                " = ",
                                c_backend.render_initializer(e, value),
                                ";"
                            )
                        )
                        c_backend.emit_indented(e, inner, "memcpy(*__mt_out, __mt_ret, sizeof(*__mt_out));")
                        c_backend.emit_indented(e, inner, "return;")
                        c_backend.emit_indented(e, indent, "}")
                    else:
                        c_backend.emit_line(
                            e,
                            strings.join_six(
                                indent,
                                "memcpy(*__mt_out, ",
                                c_backend.render_expr(e, value),
                                ", sizeof(*__mt_out)",
                                ");",
                                ""
                            )
                        )
                        c_backend.emit_indented(e, indent, "return;")
                    return
                c_backend.emit_line(e, strings.join_four(indent, "return ", c_backend.render_expr(e, value), ";"))
            ir.Stmt.stmt_local as loc:
                if c_backend.is_array_type(loc.ty) and c_backend.expr_is_array_call(e, loc.value):
                    # `let a = <array-returning call>` — declare the array, then
                    # call the callee with `&a` as its out-param.
                    c_backend.emit_line(e, strings.join_three(indent, c_backend.c_decl(loc.ty, loc.linkage_name), ";"))
                    c_backend.emit_line(
                        e,
                        strings.join_three(
                            indent,
                            c_backend.emit_array_call(e, loc.value, strings.join_two("&", loc.linkage_name)),
                            ";"
                        )
                    )
                else if c_backend.aggregate_has_array_call_field(e, loc.value):
                    # `let s = S(arr = <array-returning call>, ...)` — build the
                    # struct with the array-call field omitted, then fill it via
                    # the callee's out-param `f(&s.arr, ...)`.
                    unsafe:
                        match read(loc.value):
                            ir.Expr.expr_aggregate_literal as agg:
                                c_backend.emit_aggregate_with_array_call_fields(
                                    e,
                                    indent,
                                    c_backend.c_decl(loc.ty, loc.linkage_name),
                                    loc.linkage_name,
                                    agg.fields
                                )
                            _:
                                pass
                else if c_backend.is_array_type(loc.ty) and not c_backend.array_direct_initializer(loc.value):
                    c_backend.emit_line(e, strings.join_three(indent, c_backend.c_decl(loc.ty, loc.linkage_name), ";"))
                    c_backend.emit_line(
                        e,
                        strings.join_six(
                            indent,
                            "memcpy(",
                            loc.linkage_name,
                            ", ",
                            c_backend.render_expr(e, loc.value),
                            strings.join_three(", sizeof(", loc.linkage_name, "));")
                        )
                    )
                else:
                    c_backend.emit_line(
                        e,
                        strings.join_five(
                            indent,
                            c_backend.c_decl(loc.ty, loc.linkage_name),
                            " = ",
                            c_backend.render_initializer(e, loc.value),
                            ";"
                        )
                    )
            ir.Stmt.stmt_assignment as asg:
                # `arr = <array-returning call>` — call the callee with `&arr`.
                if asg.operator == "=" and c_backend.is_array_type(c_backend.expr_result_type(asg.target)) and c_backend.expr_is_array_call(
                    e,
                    asg.value
                ):
                    let target_c = c_backend.render_expr(e, asg.target)
                    c_backend.emit_line(
                        e,
                        strings.join_three(
                            indent,
                            c_backend.emit_array_call(e, asg.value, strings.join_three("&(", target_c, ")")),
                            ";"
                        )
                    )
                    return
                # `arr = {a, b, ...}` — C forbids assigning an initializer list to
                # an array; bind it to a temp array and memcpy into the target.
                if (
                    asg.operator == "="
                    and c_backend.is_array_type(c_backend.expr_result_type(asg.target))
                    and c_backend.array_direct_initializer(asg.value)
                ):
                    let target_c = c_backend.render_expr(e, asg.target)
                    let arr_ty = c_backend.expr_result_type(asg.target)
                    c_backend.emit_indented(e, indent, "{")
                    let inner = c_backend.indent_c(level + 1)
                    c_backend.emit_line(
                        e,
                        strings.join_five(
                            inner,
                            c_backend.c_decl(arr_ty, "__mt_arr_tmp"),
                            " = ",
                            c_backend.render_initializer(e, asg.value),
                            ";"
                        )
                    )
                    c_backend.emit_line(
                        e,
                        strings.join_six(inner, "memcpy(", target_c, ", __mt_arr_tmp, sizeof(__mt_arr_tmp)", ");", "")
                    )
                    c_backend.emit_indented(e, indent, "}")
                    return
                # `arr = other_arr` — C forbids assigning one array to another;
                # emit a memcpy of the whole array instead.
                if asg.operator == "=" and c_backend.is_array_type(c_backend.expr_result_type(asg.target)):
                    let target_c = c_backend.render_expr(e, asg.target)
                    c_backend.emit_line(
                        e,
                        strings.join_six(
                            indent,
                            "memcpy(",
                            target_c,
                            ", ",
                            c_backend.render_expr(e, asg.value),
                            strings.join_three(", sizeof(", target_c, "));")
                        )
                    )
                    return
                c_backend.emit_line(
                    e,
                    strings.join_six(
                        indent,
                        c_backend.render_expr(e, asg.target),
                        " ",
                        asg.operator,
                        " ",
                        strings.join_two(c_backend.render_expr(e, asg.value), ";")
                    )
                )
            ir.Stmt.stmt_expression as ex:
                c_backend.emit_line(e, strings.join_three(indent, c_backend.render_expr(e, ex.expression), ";"))
            ir.Stmt.stmt_block as blk:
                if c_backend.block_requires_scope(blk.body):
                    c_backend.emit_indented(e, indent, "{")
                    emit_stmts(e, blk.body, level + 1)
                    c_backend.emit_indented(e, indent, "}")
                else:
                    emit_stmts(e, blk.body, level)
            ir.Stmt.stmt_if as iff:
                emit_if(e, iff.condition, iff.then_body, c_backend.else_stmts_or_empty(iff.else_body), level)
            ir.Stmt.stmt_while as w:
                c_backend.emit_line(e, strings.join_four(indent, "while (", c_backend.render_expr(e, w.condition), ") {"))
                if e.debug_guards:
                    c_backend.emit_loop_guard(e, c_backend.loop_guard_name(e, sp), level + 1)
                emit_stmts(e, w.body, level + 1)
                c_backend.emit_indented(e, indent, "}")
            ir.Stmt.stmt_for as f:
                var header = string.String.create()
                header.append(indent)
                header.append("for (")
                header.append(c_backend.render_for_clause(e, f.init))
                header.append("; ")
                header.append(c_backend.render_expr(e, f.condition))
                header.append("; ")
                header.append(c_backend.render_for_clause(e, f.post))
                header.append(") {")
                c_backend.emit_line(e, header.as_str())
                if e.debug_guards:
                    c_backend.emit_loop_guard(e, c_backend.loop_guard_name(e, sp), level + 1)
                emit_stmts(e, f.body, level + 1)
                c_backend.emit_indented(e, indent, "}")
            ir.Stmt.stmt_switch as sw:
                emit_switch(e, sw.expression, sw.cases, sw.exhaustive, level)
            ir.Stmt.stmt_goto as g:
                c_backend.emit_line(e, strings.join_four(indent, "goto ", g.label, ";"))
            ir.Stmt.stmt_label as lbl:
                if e.used_labels.contains(lbl.name):
                    c_backend.emit_line(e, strings.join_three(indent, lbl.name, ":;"))
            ir.Stmt.stmt_break:
                c_backend.emit_indented(e, indent, "break;")
            ir.Stmt.stmt_continue:
                c_backend.emit_indented(e, indent, "continue;")
            _:
                fatal(c"c_backend: unsupported statement")

public function emit_stmts(e: ref[c_backend.Emitter], body: span[ir.Stmt], level: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            emit_statement(e, body.data + i, level)
        i += 1


## Emit an `if` and its else chain, re-flattening a single-`if` else body back
## into `else if` (mirrors control_flow_emission.rb emit_if_statement).
function emit_if(
    e: ref[c_backend.Emitter],
    condition: ptr[ir.Expr],
    then_body: span[ir.Stmt],
    else_body: span[ir.Stmt],
    level: ptr_uint
) -> void:
    let indent = c_backend.indent_c(level)
    c_backend.emit_line(e, strings.join_four(indent, "if (", c_backend.render_expr(e, condition), ") {"))
    emit_stmts(e, then_body, level + 1)
    emit_else(e, else_body, level)


## Emit a `switch`.  Non-default cases are `case VALUE: { body [break;] }`; a `_`
## arm is `default: { body [break;] }`; and an exhaustive switch with no explicit
## default gets `default: __builtin_unreachable();`.  Mirrors the switch path in
## c_backend/statements.rb.
function emit_switch(
    e: ref[c_backend.Emitter],
    expression: ptr[ir.Expr],
    cases: span[ir.SwitchCase],
    exhaustive: bool,
    level: ptr_uint
) -> void:
    let indent = c_backend.indent_c(level)
    let case_indent = c_backend.indent_c(level + 1)
    c_backend.emit_line(e, strings.join_four(indent, "switch (", c_backend.render_expr(e, expression), ") {"))
    var has_default = false
    var i: ptr_uint = 0
    while i < cases.len:
        unsafe:
            let sc = read(cases.data + i)
            if sc.is_default:
                has_default = true
                c_backend.emit_indented(e, case_indent, "default: {")
            else:
                let value = sc.value else:
                    fatal(c"c_backend: non-default switch case missing value")
                c_backend.emit_line(e, strings.join_four(case_indent, "case ", c_backend.render_expr(e, value), ": {"))
            emit_stmts(e, sc.body, level + 2)
            if not c_backend.body_terminates(sc.body):
                c_backend.emit_line(e, strings.join_two(c_backend.indent_c(level + 2), "break;"))
            c_backend.emit_indented(e, case_indent, "}")
        i += 1
    if exhaustive and not has_default:
        c_backend.emit_indented(e, case_indent, "default: __builtin_unreachable();")
    c_backend.emit_indented(e, indent, "}")


function emit_else(e: ref[c_backend.Emitter], else_body: span[ir.Stmt], level: ptr_uint) -> void:
    let indent = c_backend.indent_c(level)
    if else_body.len == 1:
        unsafe:
            match read(else_body.data + 0):
                ir.Stmt.stmt_if as nested:
                    c_backend.emit_line(e, strings.join_four(indent, "} else if (", c_backend.render_expr(e, nested.condition), ") {"))
                    emit_stmts(e, nested.then_body, level + 1)
                    emit_else(e, c_backend.else_stmts_or_empty(nested.else_body), level)
                    return
                _:
                    pass
    if else_body.len > 0:
        c_backend.emit_indented(e, indent, "} else {")
        emit_stmts(e, else_body, level + 1)
        c_backend.emit_indented(e, indent, "}")
    else:
        c_backend.emit_indented(e, indent, "}")
