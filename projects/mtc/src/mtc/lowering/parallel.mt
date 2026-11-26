## Parallel / detach / gather lowering — parallel for, parallel blocks,
## detach workers, gather joins, and the per-module parallel counter.
## Extracted from lowering/lowering.mt.  The shared `find_local` and `pw1_str`
## helpers stay in lowering.

import std.vec as vec
import std.map as map_mod
import std.string as string
import std.fmt as fmt
import std.str

import mtc.ir as ir
import mtc.parser.ast as ast
import mtc.semantic.types as types
import mtc.c_naming as naming

import mtc.lowering.control_flow as control_flow
import mtc.lowering.lowering as lowering
import mtc.lowering.type_helpers as type_helpers
import mtc.lowering.utils as utils
import mtc.strings

## Host parity for the parallel constructs (`loops.rb`):
## `@parallel_for_counter` is a single per-module counter shared by
## `parallel for` (`_pfor_`), `parallel:` (`_spawn_`) and `detach`
## (`_detach_`), incremented once per construct (not per worker).  The
## generated identifiers are `<module_prefix>_<kind>_<N>` with the construct
## prefix in front (`mt_pfor_cap_`, `mt_pfor_work_`, ...).
##
## `lower` resets this per compilation, exactly as it resets `proc_counter` and
## `async_binding_cnt`: the counter is process state, so without the reset a
## second compilation in the same process numbers its constructs from where the
## first left off, and `emit-c a.mt a.mt` would disagree with `emit-c a.mt`.
var parallel_cnt: ptr_uint = 0


public function reset_parallel_counter() -> void:
    parallel_cnt = 0


function parallel_uid(ctx: ref[lowering.LoweringContext], kind: str) -> str:
    var buf = string.String.create()
    buf.append(naming.module_c_prefix(ctx.module_name))
    buf.append("_")
    buf.append(kind)
    buf.append("_")
    fmt.append_ptr_uint(ref_of(buf), parallel_cnt)
    return buf.as_str()


function pfor_element_type(t: types.Type) -> types.Type:
    match t:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            if g_bp.args.len > 0:
                return unsafe: read(g_bp.args.data + 0)
            return types.Type.ty_error
        _:
            return types.Type.ty_error


function pfor_ptr_type(t: types.Type) -> types.Type:
    return types.generic_type(name = "ptr", args = lowering.sp_type(t))


function pfor_capture_name(c: ir.Expr) -> str:
    match c:
        ir.Expr.expr_name as nm:
            return nm.name
        _:
            return ""


## First-occurrence-ordered collected names: the capture order is observable
## (struct fields and aggregate literals), and a hash map does not preserve it.
struct PforNames:
    names: vec.Vec[ir.Expr]
    seen: map_mod.Map[str, bool]


## The host's `collect_pfor_ir_names_expr` (`loops.rb:1055`): names reachable
## from a lowered expression, first occurrence winning.
function collect_pfor_ir_names_expr(ep: ir.Expr, result: ref[PforNames]) -> void:
    match ep:
        ir.Expr.expr_name as nm:
            if not result.seen.contains(nm.name):
                result.seen.set(nm.name, true)
                result.names.push(ep)
        ir.Expr.expr_member as m:
            collect_pfor_ir_names_expr(unsafe: read(m.receiver), result)
        ir.Expr.expr_index as ix:
            collect_pfor_ir_names_expr(unsafe: read(ix.receiver), result)
            collect_pfor_ir_names_expr(unsafe: read(ix.index), result)
        ir.Expr.expr_checked_index as ix:
            collect_pfor_ir_names_expr(unsafe: read(ix.receiver), result)
            collect_pfor_ir_names_expr(unsafe: read(ix.index), result)
        ir.Expr.expr_checked_span_index as ix:
            collect_pfor_ir_names_expr(unsafe: read(ix.receiver), result)
            collect_pfor_ir_names_expr(unsafe: read(ix.index), result)
        ir.Expr.expr_nullable_index as ix:
            collect_pfor_ir_names_expr(unsafe: read(ix.receiver), result)
            collect_pfor_ir_names_expr(unsafe: read(ix.index), result)
        ir.Expr.expr_nullable_span_index as ix:
            collect_pfor_ir_names_expr(unsafe: read(ix.receiver), result)
            collect_pfor_ir_names_expr(unsafe: read(ix.index), result)
        ir.Expr.expr_call as call:
            var ai: ptr_uint = 0
            while ai < call.arguments.len:
                collect_pfor_ir_names_expr(unsafe: read(call.arguments.data + ai), result)
                ai += 1
        ir.Expr.expr_call_indirect as call:
            collect_pfor_ir_names_expr(unsafe: read(call.callee), result)
            var cai: ptr_uint = 0
            while cai < call.arguments.len:
                collect_pfor_ir_names_expr(unsafe: read(call.arguments.data + cai), result)
                cai += 1
        ir.Expr.expr_binary as b:
            collect_pfor_ir_names_expr(unsafe: read(b.left), result)
            collect_pfor_ir_names_expr(unsafe: read(b.right), result)
        ir.Expr.expr_unary as u:
            collect_pfor_ir_names_expr(unsafe: read(u.operand), result)
        ir.Expr.expr_cast as c:
            collect_pfor_ir_names_expr(unsafe: read(c.expression), result)
        ir.Expr.expr_address_of as ao:
            collect_pfor_ir_names_expr(unsafe: read(ao.expression), result)
        ir.Expr.expr_conditional as cond:
            collect_pfor_ir_names_expr(unsafe: read(cond.condition), result)
            collect_pfor_ir_names_expr(unsafe: read(cond.then_expression), result)
            collect_pfor_ir_names_expr(unsafe: read(cond.else_expression), result)
        ir.Expr.expr_aggregate_literal as al:
            var al_i: ptr_uint = 0
            while al_i < al.fields.len:
                collect_pfor_ir_names_expr(unsafe: read(unsafe: read(al.fields.data + al_i).value), result)
                al_i += 1
        ir.Expr.expr_array_literal as al:
            var ali: ptr_uint = 0
            while ali < al.elements.len:
                collect_pfor_ir_names_expr(unsafe: read(al.elements.data + ali), result)
                ali += 1
        ir.Expr.expr_reinterpret as r:
            let rp = unsafe: read(r.payload)
            collect_pfor_ir_names_expr(unsafe: read(rp.expression), result)
        _:
            pass


function collect_pfor_ir_names_span(stmts: span[ir.Stmt], result: ref[PforNames]) -> void:
    var si: ptr_uint = 0
    while si < stmts.len:
        collect_pfor_ir_names_stmt(unsafe: read(stmts.data + si), result)
        si += 1


function collect_pfor_ir_names_stmt(s: ir.Stmt, result: ref[PforNames]) -> void:
    match s:
        ir.Stmt.stmt_local as loc:
            collect_pfor_ir_names_expr(unsafe: read(loc.value), result)
        ir.Stmt.stmt_assignment as asg:
            collect_pfor_ir_names_expr(unsafe: read(asg.target), result)
            collect_pfor_ir_names_expr(unsafe: read(asg.value), result)
        ir.Stmt.stmt_expression as ex:
            collect_pfor_ir_names_expr(unsafe: read(ex.expression), result)
        ir.Stmt.stmt_return as ret:
            let value = ret.value
            if value != null:
                collect_pfor_ir_names_expr(unsafe: read(unsafe: ptr[ir.Expr]<-value), result)
        ir.Stmt.stmt_if as iff:
            collect_pfor_ir_names_expr(unsafe: read(iff.condition), result)
            collect_pfor_ir_names_span(iff.then_body, result)
            match iff.else_body:
                Option.some as eb:
                    collect_pfor_ir_names_span(eb.value, result)
                Option.none:
                    pass
        ir.Stmt.stmt_while as w:
            collect_pfor_ir_names_expr(unsafe: read(w.condition), result)
            collect_pfor_ir_names_span(w.body, result)
        ir.Stmt.stmt_for as f:
            collect_pfor_ir_names_stmt(unsafe: read(f.init), result)
            collect_pfor_ir_names_expr(unsafe: read(f.condition), result)
            unsafe:
                match read(f.post):
                    ir.Stmt.stmt_assignment:
                        collect_pfor_ir_names_stmt(unsafe: read(f.post), result)
                    ir.Stmt.stmt_expression:
                        collect_pfor_ir_names_stmt(unsafe: read(f.post), result)
                    _:
                        pass
            collect_pfor_ir_names_span(f.body, result)
        ir.Stmt.stmt_block as blk:
            collect_pfor_ir_names_span(blk.body, result)
        ir.Stmt.stmt_switch as sw:
            collect_pfor_ir_names_expr(unsafe: read(sw.expression), result)
            var ci: ptr_uint = 0
            while ci < sw.cases.len:
                let c = unsafe: read(sw.cases.data + ci)
                collect_pfor_ir_names_span(c.body, result)
                ci += 1
        _:
            pass


## The host's `collect_pfor_local_decls` (`loops.rb:1089`): linkage names of
## every local declaration in the body, which are never captures.
function collect_pfor_local_decls(stmt: ir.Stmt, decls: ref[map_mod.Map[str, bool]]) -> void:
    match stmt:
        ir.Stmt.stmt_local as loc:
            decls.set(loc.linkage_name, true)
        ir.Stmt.stmt_for as f:
            unsafe:
                match read(f.init):
                    ir.Stmt.stmt_local as init:
                        decls.set(init.linkage_name, true)
                    _:
                        pass
            collect_pfor_local_decls_span(f.body, decls)
        ir.Stmt.stmt_block as blk:
            collect_pfor_local_decls_span(blk.body, decls)
        ir.Stmt.stmt_if as iff:
            collect_pfor_local_decls_span(iff.then_body, decls)
            match iff.else_body:
                Option.some as eb:
                    collect_pfor_local_decls_span(eb.value, decls)
                Option.none:
                    pass
        ir.Stmt.stmt_while as w:
            collect_pfor_local_decls_span(w.body, decls)
        ir.Stmt.stmt_switch as sw:
            var ci: ptr_uint = 0
            while ci < sw.cases.len:
                let c = unsafe: read(sw.cases.data + ci)
                collect_pfor_local_decls_span(c.body, decls)
                ci += 1
        _:
            pass


function collect_pfor_local_decls_span(stmts: span[ir.Stmt], decls: ref[map_mod.Map[str, bool]]) -> void:
    var si: ptr_uint = 0
    while si < stmts.len:
        collect_pfor_local_decls(unsafe: read(stmts.data + si), decls)
        si += 1


## The base name of an assignment target, for the parallel-block write set
## (the host's `pfor_assignment_base_name`, `loops.rb:901`).
function pfor_assignment_base_name(expr: ir.Expr) -> str:
    match expr:
        ir.Expr.expr_name as nm:
            return nm.name
        ir.Expr.expr_member as m:
            return pfor_assignment_base_name(unsafe: read(m.receiver))
        ir.Expr.expr_index as ix:
            return pfor_assignment_base_name(unsafe: read(ix.receiver))
        ir.Expr.expr_checked_index as ix:
            return pfor_assignment_base_name(unsafe: read(ix.receiver))
        ir.Expr.expr_checked_span_index as ix:
            return pfor_assignment_base_name(unsafe: read(ix.receiver))
        ir.Expr.expr_nullable_index as ix:
            return pfor_assignment_base_name(unsafe: read(ix.receiver))
        ir.Expr.expr_nullable_span_index as ix:
            return pfor_assignment_base_name(unsafe: read(ix.receiver))
        ir.Expr.expr_address_of as ao:
            return pfor_assignment_base_name(unsafe: read(ao.expression))
        _:
            return ""


function collect_pfor_written_names(
    stmts: span[ir.Stmt],
    capture_names: ref[map_mod.Map[str, bool]],
    written: ref[map_mod.Map[str, bool]]
) -> void:
    var si: ptr_uint = 0
    while si < stmts.len:
        collect_pfor_written_stmt(unsafe: read(stmts.data + si), capture_names, written)
        si += 1


function collect_pfor_written_stmt(
    stmt: ir.Stmt,
    capture_names: ref[map_mod.Map[str, bool]],
    written: ref[map_mod.Map[str, bool]]
) -> void:
    match stmt:
        ir.Stmt.stmt_assignment as asg:
            let base = pfor_assignment_base_name(unsafe: read(asg.target))
            if base.len > 0 and capture_names.contains(base):
                written.set(base, true)
        ir.Stmt.stmt_if as iff:
            collect_pfor_written_names(iff.then_body, capture_names, written)
            match iff.else_body:
                Option.some as eb:
                    collect_pfor_written_names(eb.value, capture_names, written)
                Option.none:
                    pass
        ir.Stmt.stmt_while as w:
            collect_pfor_written_names(w.body, capture_names, written)
        ir.Stmt.stmt_for as f:
            collect_pfor_written_names(f.body, capture_names, written)
        ir.Stmt.stmt_block as blk:
            collect_pfor_written_names(blk.body, capture_names, written)
        ir.Stmt.stmt_switch as sw:
            var ci: ptr_uint = 0
            while ci < sw.cases.len:
                let c = unsafe: read(sw.cases.data + ci)
                collect_pfor_written_names(c.body, capture_names, written)
                ci += 1
        _:
            pass


## Rewrite the array captures of a parallel body to their pointer fields (the
## host's `rewrite_pfor_array_captures`, `loops.rb:916`).  An array value is
## not safe to copy into a capture struct, so the struct holds `ptr[E]` and a
## checked index through the array becomes a plain pointer index.
function rewrite_pfor_array_captures(stmts: span[ir.Stmt], array_names: ref[map_mod.Map[str, bool]]) -> span[ir.Stmt]:
    var rewritten = vec.Vec[ir.Stmt].create()
    var si: ptr_uint = 0
    while si < stmts.len:
        rewritten.push(rewrite_pfor_stmt(unsafe: read(stmts.data + si), array_names))
        si += 1
    return rewritten.as_span()


function rewrite_pfor_stmt(stmt: ir.Stmt, array_names: ref[map_mod.Map[str, bool]]) -> ir.Stmt:
    match stmt:
        ir.Stmt.stmt_assignment as asg:
            return ir.Stmt.stmt_assignment(
                target = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(asg.target), array_names)),
                operator = asg.operator,
                value = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(asg.value), array_names)),
            )
        ir.Stmt.stmt_local as loc:
            return ir.Stmt.stmt_local(
                name = loc.name, linkage_name = loc.linkage_name, ty = loc.ty,
                value = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(loc.value), array_names)),
                line = loc.line, source_path = loc.source_path,
            )
        ir.Stmt.stmt_expression as ex:
            return ir.Stmt.stmt_expression(
                expression = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(ex.expression), array_names)),
                line = ex.line, source_path = ex.source_path,
            )
        ir.Stmt.stmt_if as iff:
            var else_body = Option[span[ir.Stmt]].none
            match iff.else_body:
                Option.some as eb:
                    else_body = Option[span[ir.Stmt]].some(value = rewrite_pfor_array_captures(eb.value, array_names))
                Option.none:
                    pass
            return ir.Stmt.stmt_if(
                condition = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(iff.condition), array_names)),
                then_body = rewrite_pfor_array_captures(iff.then_body, array_names),
                else_body = else_body,
            )
        ir.Stmt.stmt_for as f:
            return ir.Stmt.stmt_for(
                init = lowering.alloc_stmt(rewrite_pfor_stmt(unsafe: read(f.init), array_names)),
                condition = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(f.condition), array_names)),
                post = lowering.alloc_stmt(rewrite_pfor_stmt(unsafe: read(f.post), array_names)),
                body = rewrite_pfor_array_captures(f.body, array_names),
            )
        ir.Stmt.stmt_while as w:
            return ir.Stmt.stmt_while(
                condition = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(w.condition), array_names)),
                body = rewrite_pfor_array_captures(w.body, array_names),
            )
        ir.Stmt.stmt_block as blk:
            return ir.Stmt.stmt_block(body = rewrite_pfor_array_captures(blk.body, array_names))
        ir.Stmt.stmt_switch as sw:
            var cases = vec.Vec[ir.SwitchCase].create()
            var ci: ptr_uint = 0
            while ci < sw.cases.len:
                let c = unsafe: read(sw.cases.data + ci)
                cases.push(ir.SwitchCase(
                    is_default = c.is_default,
                    value = c.value,
                    body = rewrite_pfor_array_captures(c.body, array_names)
                ))
                ci += 1
            return ir.Stmt.stmt_switch(
                expression = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(sw.expression), array_names)),
                cases = cases.as_span(), exhaustive = sw.exhaustive,
            )
        ir.Stmt.stmt_return as ret:
            let value = ret.value
            if value == null:
                return stmt
            return ir.Stmt.stmt_return(
                value = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(unsafe: ptr[ir.Expr]<-value), array_names)),
                line = ret.line, source_path = ret.source_path,
            )
        _:
            return stmt


function rewrite_pfor_expr(expr: ir.Expr, array_names: ref[map_mod.Map[str, bool]]) -> ir.Expr:
    match expr:
        ir.Expr.expr_checked_index as ci:
            match unsafe: read(ci.receiver):
                ir.Expr.expr_address_of as ao:
                    match unsafe: read(ao.expression):
                        ir.Expr.expr_name as nm:
                            if array_names.contains(nm.name):
                                var ptr_ty = nm.ty
                                if lowering.is_array_type(nm.ty):
                                    ptr_ty = pfor_ptr_type(pfor_element_type(nm.ty))
                                return ir.Expr.expr_index(
                                    receiver = lowering.alloc_expr(ir.Expr.expr_name(
                                        name = nm.name,
                                        ty = ptr_ty,
                                        pointer = Option[bool].some(value = false)
                                    )),
                                    index = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(ci.index), array_names)),
                                    ty = ci.ty,
                                )
                        _:
                            pass
                ir.Expr.expr_name as nm:
                    if array_names.contains(nm.name):
                        var ptr_ty = ci.receiver_type
                        if lowering.is_array_type(ci.receiver_type):
                            ptr_ty = pfor_ptr_type(pfor_element_type(ci.receiver_type))
                        return ir.Expr.expr_index(
                            receiver = lowering.alloc_expr(ir.Expr.expr_name(
                                name = nm.name,
                                ty = ptr_ty,
                                pointer = Option[bool].some(value = false)
                            )),
                            index = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(ci.index), array_names)),
                            ty = ci.ty,
                        )
                _:
                    pass
            return expr
        ir.Expr.expr_binary as b:
            return ir.Expr.expr_binary(
                operator = b.operator,
                left = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(b.left), array_names)),
                right = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(b.right), array_names)),
                ty = b.ty,
            )
        ir.Expr.expr_unary as u:
            return ir.Expr.expr_unary(
                operator = u.operator,
                operand = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(u.operand), array_names)),
                ty = u.ty,
            )
        ir.Expr.expr_cast as c:
            return ir.Expr.expr_cast(
                target_type = c.target_type,
                expression = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(c.expression), array_names)),
                ty = c.ty,
            )
        ir.Expr.expr_call as call:
            var args = vec.Vec[ir.Expr].create()
            var ai: ptr_uint = 0
            while ai < call.arguments.len:
                args.push(rewrite_pfor_expr(unsafe: read(call.arguments.data + ai), array_names))
                ai += 1
            return ir.Expr.expr_call(callee = call.callee, arguments = args.as_span(), ty = call.ty)
        ir.Expr.expr_call_indirect as call:
            var args = vec.Vec[ir.Expr].create()
            var cai: ptr_uint = 0
            while cai < call.arguments.len:
                args.push(rewrite_pfor_expr(unsafe: read(call.arguments.data + cai), array_names))
                cai += 1
            return ir.Expr.expr_call_indirect(
                callee = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(call.callee), array_names)),
                arguments = args.as_span(), ty = call.ty,
            )
        ir.Expr.expr_address_of as ao:
            return ir.Expr.expr_address_of(
                expression = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(ao.expression), array_names)),
                ty = ao.ty,
            )
        ir.Expr.expr_conditional as cond:
            return ir.Expr.expr_conditional(
                condition = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(cond.condition), array_names)),
                then_expression = lowering.alloc_expr(rewrite_pfor_expr(
                    unsafe: read(cond.then_expression),
                    array_names
                )),
                else_expression = lowering.alloc_expr(rewrite_pfor_expr(
                    unsafe: read(cond.else_expression),
                    array_names
                )),
                ty = cond.ty,
            )
        ir.Expr.expr_member as m:
            return ir.Expr.expr_member(
                receiver = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(m.receiver), array_names)),
                member = m.member, ty = m.ty,
            )
        ir.Expr.expr_index as ix:
            return ir.Expr.expr_index(
                receiver = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(ix.receiver), array_names)),
                index = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(ix.index), array_names)),
                ty = ix.ty,
            )
        ir.Expr.expr_aggregate_literal as al:
            var fields = vec.Vec[ir.AggregateField].create()
            var fi: ptr_uint = 0
            while fi < al.fields.len:
                let f = unsafe: read(al.fields.data + fi)
                fields.push(ir.AggregateField(
                    name = f.name,
                    value = lowering.alloc_expr(rewrite_pfor_expr(unsafe: read(f.value), array_names))
                ))
                fi += 1
            return ir.Expr.expr_aggregate_literal(ty = al.ty, fields = fields.as_span())
        _:
            return expr


function validate_pfor_no_ref_captures(captures: span[ir.Expr]) -> void:
    var ci: ptr_uint = 0
    while ci < captures.len:
        match unsafe: read(captures.data + ci):
            ir.Expr.expr_name as nm:
                if types.is_ref_type(nm.ty):
                    fatal(strings.join_three("cannot capture '", nm.name, "' of type ref across thread boundary — ref values are not safe to share across threads"))
            _:
                pass
        ci += 1


## Lower `parallel for i in 0..N: body` (the host's `lower_threaded_for_stmt`,
## `loops.rb:445`): a worker receives `(data, start, end)`, unpacks the capture
## struct, and runs the induction loop.
public function lower_parallel_for(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    bindings: span[ast.ForBinding],
    iterables: span[ast.Expr],
    body: ptr[ast.Stmt]?
) -> void:
    if bindings.len == 0 or iterables.len == 0:
        return
    var start_ptr: ptr[ast.Expr]
    var end_ptr: ptr[ast.Expr]
    unsafe:
        match read(iterables.data + 0):
            ast.Expr.expr_range as rng:
                start_ptr = rng.start_expr
                end_ptr = rng.end_expr
            _:
                fatal(c"lowering parallel for: only range iteration is supported")
    let bd = body else:
        return
    var index_name: str
    unsafe:
        index_name = read(bindings.data + 0).name
    let index_c = utils.c_local_name(index_name)
    # The host's `infer_range_loop_type`: an integer-literal bound takes the
    # other bound's type.
    var loop_type = type_helpers.expr_type(ctx, start_ptr)
    var stop_ty = type_helpers.expr_type(ctx, end_ptr)
    if not types.type_equals(loop_type, stop_ty):
        if control_flow.ast_is_integer_literal(start_ptr) and types.is_integer_type(stop_ty):
            loop_type = stop_ty
        else if control_flow.ast_is_integer_literal(end_ptr) and types.is_integer_type(loop_type):
            stop_ty = loop_type
    if types.is_error(loop_type):
        loop_type = types.primitive("int")
    let long_ty = types.primitive("long")

    # Both bounds are prepared before the stop value is lowered
    # (`prepare_expression_for_inline_lowering` on start, then stop).
    let start_saved = lowering.begin_stmt_setup(ctx, ctx.hoist_mode)
    let _start_value = lowering.lower_expr(ctx, start_ptr)
    let start_collected = lowering.collect_stmt_setup(ctx, start_saved)
    let stop_saved = lowering.begin_stmt_setup(ctx, ctx.hoist_mode)
    let lowered_stop = lowering.int_literal_to_context_type(end_ptr, loop_type, lowering.lower_expr(ctx, end_ptr))
    let stop_collected = lowering.collect_stmt_setup(ctx, stop_saved)

    let saved_locals_len = ctx.locals.len()
    ctx.locals.push(lowering.LocalBinding(
        name = index_name,
        c_name = index_c,
        ty = loop_type,
        pointer = Option[bool].some(value = false)
    ))
    let body_span = lowering.lower_block(ctx, bd)
    while ctx.locals.len() > saved_locals_len:
        let _popped = ctx.locals.pop()
    var body_ir = vec.Vec[ir.Stmt].create()
    lowering.append_span_stmts(ref_of(body_ir), body_span)

    # Captures: every name in the body minus the body's own locals and the
    # induction variable.
    var all_names = PforNames(names = vec.Vec[ir.Expr].create(), seen = map_mod.Map[str, bool].create())
    collect_pfor_ir_names_span(body_ir.as_span(), ref_of(all_names))
    var local_decls = map_mod.Map[str, bool].create()
    collect_pfor_local_decls_span(body_ir.as_span(), ref_of(local_decls))
    local_decls.set(index_c, true)
    var captures = vec.Vec[ir.Expr].create()
    var ni: ptr_uint = 0
    while ni < all_names.names.len():
        let np = all_names.names.get(ni) else:
            break
        let c = unsafe: read(np)
        if not local_decls.contains(pfor_capture_name(c)):
            captures.push(c)
        ni += 1
    validate_pfor_no_ref_captures(captures.as_span())

    parallel_cnt += 1
    let uid = parallel_uid(ctx, "pfor")
    let cap_name = strings.join_two("mt_pfor_cap_", uid)
    let worker_name = strings.join_two("mt_pfor_work_", uid)

    var array_capture_names = map_mod.Map[str, bool].create()
    var cap_fields = vec.Vec[ir.Field].create()
    var ci: ptr_uint = 0
    while ci < captures.len():
        let cp = captures.get(ci) else:
            break
        match unsafe: read(cp):
            ir.Expr.expr_name as nm:
                if lowering.is_array_type(nm.ty):
                    array_capture_names.set(nm.name, true)
                    cap_fields.push(ir.Field(name = nm.name, ty = pfor_ptr_type(pfor_element_type(nm.ty))))
                else:
                    cap_fields.push(ir.Field(name = nm.name, ty = nm.ty))
            _:
                pass
        ci += 1
    ctx.pending_synthetic_structs.push(ir.StructDecl(
        name = cap_name,
        linkage_name = cap_name,
        fields = cap_fields.as_span(),
        packed = false,
        alignment = 0,
        source_module = Option[str].none
    ))

    let cap_ty = types.named_type(name = cap_name, module_name = "", linkage_name = Option[str].none)
    let cap_ptr_ty = pfor_ptr_type(cap_ty)
    let void_ptr = void_ptr_ty()
    var worker_body = vec.Vec[ir.Stmt].create()
    worker_body.push(ir.Stmt.stmt_local(
        name = "mt_cap", linkage_name = "mt_cap", ty = cap_ptr_ty,
        value = lowering.alloc_expr(ir.Expr.expr_cast(
            target_type = cap_ptr_ty,
            expression = lowering.alloc_expr(ir.Expr.expr_name(
                name = "mt_pfor_data",
                ty = void_ptr,
                pointer = Option[bool].some(value = false)
            )),
            ty = cap_ptr_ty,
        )),
        line = 0, source_path = "",
    ))
    let cap_ref = lowering.alloc_expr(ir.Expr.expr_name(
        name = "mt_cap",
        ty = cap_ptr_ty,
        pointer = Option[bool].some(value = true)
    ))
    ci = 0
    while ci < captures.len():
        let cp = captures.get(ci) else:
            break
        match unsafe: read(cp):
            ir.Expr.expr_name as nm:
                var alias_ty = nm.ty
                if lowering.is_array_type(nm.ty):
                    alias_ty = pfor_ptr_type(pfor_element_type(nm.ty))
                worker_body.push(ir.Stmt.stmt_local(
                    name = nm.name, linkage_name = nm.name, ty = alias_ty,
                    value = lowering.alloc_expr(ir.Expr.expr_member(
                        receiver = cap_ref,
                        member = nm.name,
                        ty = alias_ty
                    )),
                    line = 0, source_path = "",
                ))
            _:
                pass
        ci += 1
    var rewritten_body = body_ir.as_span()
    if array_capture_names.len() > 0:
        rewritten_body = rewrite_pfor_array_captures(body_ir.as_span(), ref_of(array_capture_names))
    let index_ref = lowering.alloc_expr(ir.Expr.expr_name(
        name = index_c,
        ty = loop_type,
        pointer = Option[bool].some(value = false)
    ))
    let start_ref = lowering.alloc_expr(ir.Expr.expr_name(
        name = "mt_pfor_start",
        ty = long_ty,
        pointer = Option[bool].some(value = false)
    ))
    let end_ref = lowering.alloc_expr(ir.Expr.expr_name(
        name = "mt_pfor_end",
        ty = long_ty,
        pointer = Option[bool].some(value = false)
    ))
    let condition = lowering.alloc_expr(ir.Expr.expr_binary(
        operator = "<",
        left = index_ref,
        right = end_ref,
        ty = ctx.bool_ty
    ))
    let post = lowering.alloc_stmt(ir.Stmt.stmt_assignment(
        target = lowering.alloc_expr(ir.Expr.expr_name(
            name = index_c,
            ty = loop_type,
            pointer = Option[bool].some(value = false)
        )),
        operator = "+=",
        value = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 1, ty = loop_type)),
    ))
    let init = lowering.alloc_stmt(ir.Stmt.stmt_local(
        name = index_c,
        linkage_name = index_c,
        ty = loop_type,
        value = start_ref,
        line = 0,
        source_path = ""
    ))
    worker_body.push(ir.Stmt.stmt_for(init = init, condition = condition, post = post, body = rewritten_body))

    var worker_params = vec.Vec[ir.Param].create()
    worker_params.push(ir.Param(
        name = "mt_pfor_data",
        linkage_name = "mt_pfor_data",
        ty = void_ptr,
        pointer = Option[bool].some(value = false)
    ))
    worker_params.push(ir.Param(
        name = "mt_pfor_start",
        linkage_name = "mt_pfor_start",
        ty = long_ty,
        pointer = Option[bool].some(value = false)
    ))
    worker_params.push(ir.Param(
        name = "mt_pfor_end",
        linkage_name = "mt_pfor_end",
        ty = long_ty,
        pointer = Option[bool].some(value = false)
    ))
    let worker = ir.Function(
        name = worker_name, linkage_name = worker_name,
        params = worker_params.as_span(), return_type = ctx.void_ty,
        body = worker_body.as_span(), entry_point = false, public_export = false, method_receiver_param = false,
    )
    ctx.pending_synthetic_functions.push(worker)

    var call_site = vec.Vec[ir.Stmt].create()
    lowering.append_span_stmts(ref_of(call_site), start_collected.stmts.as_span())
    lowering.append_span_stmts(ref_of(call_site), stop_collected.stmts.as_span())
    var cap_fields_out = vec.Vec[ir.AggregateField].create()
    ci = 0
    while ci < captures.len():
        let cp = captures.get(ci) else:
            break
        match unsafe: read(cp):
            ir.Expr.expr_name as nm:
                if array_capture_names.contains(nm.name):
                    cap_fields_out.push(ir.AggregateField(
                        name = nm.name,
                        value = lowering.alloc_expr(ir.Expr.expr_name(
                            name = nm.name,
                            ty = pfor_ptr_type(pfor_element_type(nm.ty)),
                            pointer = Option[bool].some(value = false)
                        )),
                    ))
                else:
                    cap_fields_out.push(ir.AggregateField(name = nm.name, value = unsafe: cp))
            _:
                pass
        ci += 1
    let cap_init = lowering.alloc_expr(ir.Expr.expr_aggregate_literal(ty = cap_ty, fields = cap_fields_out.as_span()))
    call_site.push(ir.Stmt.stmt_local(
        name = "mt_pfor_cap",
        linkage_name = "mt_pfor_cap",
        ty = cap_ty,
        value = cap_init,
        line = 0,
        source_path = ""
    ))
    let fn_ty = types.function_type(
        name = "",
        params = span[types.Type](),
        return_type = types.alloc_type(ctx.void_ty),
        variadic = false,
        is_proc = false,
        param_names = span[str]()
    )
    var call_args = vec.Vec[ir.Expr].create()
    unsafe: call_args.push(read(lowering.alloc_expr(ir.Expr.expr_name(
        name = worker_name,
        ty = fn_ty,
        pointer = Option[bool].some(value = false)
    ))))
    unsafe: call_args.push(read(lowering.alloc_expr(ir.Expr.expr_address_of(
        expression = lowering.alloc_expr(ir.Expr.expr_name(
            name = "mt_pfor_cap",
            ty = cap_ty,
            pointer = Option[bool].some(value = false)
        )),
        ty = void_ptr,
    ))))
    unsafe: call_args.push(read(lowered_stop))
    call_site.push(ir.Stmt.stmt_expression(
        expression = lowering.alloc_expr(ir.Expr.expr_call(
            callee = "mt_parallel_for",
            arguments = call_args.as_span(),
            ty = ctx.void_ty
        )),
        line = 0, source_path = "",
    ))
    output.push(ir.Stmt.stmt_block(body = call_site.as_span()))

struct SpawnBlockInfo:
    worker_name: str
    cap_local_name: str
    cap_ty: types.Type
    cap_init: ptr[ir.Expr]
    capture_names: vec.Vec[str]
    written_names: vec.Vec[str]
    written_scalars: vec.Vec[ir.Expr]
    captureless: bool


## Lower `parallel: stmt1; stmt2; ...` (the host's
## `lower_parallel_block_stmt`, `loops.rb:603`): one worker and one capture
## struct per body, dispatched through an `mt_spawn_item` array.
public function lower_parallel_block(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    bodies: span[ast.Stmt]
) -> void:
    if bodies.len < 2:
        fatal(c"internal: parallel block with fewer than two statements reached lowering")
    if bodies.len > ast.MAX_PARALLEL_ARMS:
        fatal(c"internal: parallel block exceeds the 64-arm runtime limit")
    let void_ty = ctx.void_ty
    let void_ptr = void_ptr_ty()
    parallel_cnt += 1
    let uid_base = parallel_uid(ctx, "spawn")

    var infos = vec.Vec[SpawnBlockInfo].create()
    build_parallel_workers(ctx, bodies, ref_of(infos), uid_base, void_ty, void_ptr)

    # Write-conflict validation: a name written by one body and captured by
    # another is a data race.
    var idx: ptr_uint = 0
    while idx < infos.len():
        let ip = infos.get(idx) else:
            break
        let info = unsafe: read(ip)
        var wi: ptr_uint = 0
        while wi < info.written_names.len():
            let wp = info.written_names.get(wi) else:
                break
            let name = unsafe: read(wp)
            var oi: ptr_uint = 0
            while oi < infos.len():
                if oi != idx:
                    let op = infos.get(oi) else:
                        break
                    let other = unsafe: read(op)
                    var ci2: ptr_uint = 0
                    while ci2 < other.capture_names.len():
                        let cp = other.capture_names.get(ci2) else:
                            break
                        if unsafe: read(cp) == name:
                            var msg = string.String.create()
                            msg.append("write conflict in parallel block: '")
                            msg.append(name)
                            msg.append("' is written in spawn block ")
                            fmt.append_ptr_uint(ref_of(msg), idx + 1)
                            msg.append(" and accessed in spawn block ")
                            fmt.append_ptr_uint(ref_of(msg), oi + 1)
                            fatal(msg.as_str())
                        ci2 += 1
                oi += 1
            wi += 1
        idx += 1

    let fn_ty = types.function_type(
        name = "",
        params = span[types.Type](),
        return_type = types.alloc_type(void_ty),
        variadic = false,
        is_proc = false,
        param_names = span[str]()
    )
    let spawn_item_ty = types.named_type(name = "mt_spawn_item", module_name = "", linkage_name = Option[str].none)
    var call_site = vec.Vec[ir.Stmt].create()
    idx = 0
    while idx < infos.len():
        let ip = infos.get(idx) else:
            break
        let info = unsafe: read(ip)
        if not info.captureless:
            call_site.push(ir.Stmt.stmt_local(
                name = info.cap_local_name,
                linkage_name = info.cap_local_name,
                ty = info.cap_ty,
                value = info.cap_init,
                line = 0,
                source_path = ""
            ))
        idx += 1
    let tasks_arr_ty = types.generic_type(
        name = "array",
        args = lowering.sp_type2(spawn_item_ty, types.literal_int(long<-bodies.len))
    )
    var elements = vec.Vec[ir.Expr].create()
    idx = 0
    while idx < infos.len():
        let ip = infos.get(idx) else:
            break
        let info = unsafe: read(ip)
        var data_expr = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr))
        if not info.captureless:
            data_expr = lowering.alloc_expr(ir.Expr.expr_address_of(
                expression = lowering.alloc_expr(ir.Expr.expr_name(
                    name = info.cap_local_name,
                    ty = info.cap_ty,
                    pointer = Option[bool].some(value = false)
                )),
                ty = void_ptr,
            ))
        var fields = vec.Vec[ir.AggregateField].create()
        fields.push(ir.AggregateField(
            name = "work",
            value = lowering.alloc_expr(ir.Expr.expr_name(
                name = info.worker_name,
                ty = fn_ty,
                pointer = Option[bool].some(value = false)
            ))
        ))
        fields.push(ir.AggregateField(name = "data", value = data_expr))
        unsafe: elements.push(read(lowering.alloc_expr(ir.Expr.expr_aggregate_literal(
            ty = spawn_item_ty,
            fields = fields.as_span()
        ))))
        idx += 1
    call_site.push(ir.Stmt.stmt_local(
        name = "mt_spawn_tasks", linkage_name = "mt_spawn_tasks", ty = tasks_arr_ty,
        value = lowering.alloc_expr(ir.Expr.expr_array_literal(ty = tasks_arr_ty, elements = elements.as_span())),
        line = 0, source_path = "",
    ))
    var spawn_args = vec.Vec[ir.Expr].create()
    unsafe: spawn_args.push(read(lowering.alloc_expr(ir.Expr.expr_name(
        name = "mt_spawn_tasks",
        ty = tasks_arr_ty,
        pointer = Option[bool].some(value = false)
    ))))
    unsafe: spawn_args.push(read(lowering.alloc_expr(ir.Expr.expr_integer_literal(
        value = long<-bodies.len,
        ty = types.primitive("int")
    ))))
    call_site.push(ir.Stmt.stmt_expression(
        expression = lowering.alloc_expr(ir.Expr.expr_call(
            callee = "mt_spawn_all",
            arguments = spawn_args.as_span(),
            ty = void_ty
        )),
        line = 0, source_path = "",
    ))
    # Written scalar captures flow back after the join.
    idx = 0
    while idx < infos.len():
        let ip = infos.get(idx) else:
            break
        let info = unsafe: read(ip)
        var wi: ptr_uint = 0
        while wi < info.written_scalars.len():
            let wp = info.written_scalars.get(wi) else:
                break
            match unsafe: read(wp):
                ir.Expr.expr_name as nm:
                    call_site.push(ir.Stmt.stmt_assignment(
                        target = lowering.alloc_expr(ir.Expr.expr_name(
                            name = nm.name,
                            ty = nm.ty,
                            pointer = Option[bool].some(value = false)
                        )),
                        operator = "=",
                        value = lowering.alloc_expr(ir.Expr.expr_member(
                            receiver = lowering.alloc_expr(ir.Expr.expr_name(
                                name = info.cap_local_name,
                                ty = info.cap_ty,
                                pointer = Option[bool].some(value = false)
                            )),
                            member = nm.name, ty = nm.ty,
                        )),
                    ))
                _:
                    pass
            wi += 1
        idx += 1
    output.push(ir.Stmt.stmt_block(body = call_site.as_span()))


function build_parallel_workers(
    ctx: ref[lowering.LoweringContext],
    bodies: span[ast.Stmt],
    infos: ref[vec.Vec[SpawnBlockInfo]],
    uid_base: str,
    void_ty: types.Type,
    void_ptr: types.Type
) -> void:
    var bi: ptr_uint = 0
    while bi < bodies.len:
        let body_ir = lowering.lower_block(ctx, unsafe: ptr[ast.Stmt]<-(bodies.data + bi))
        var all_names = PforNames(names = vec.Vec[ir.Expr].create(), seen = map_mod.Map[str, bool].create())
        collect_pfor_ir_names_span(body_ir, ref_of(all_names))
        var local_decls = map_mod.Map[str, bool].create()
        collect_pfor_local_decls_span(body_ir, ref_of(local_decls))
        var captures = vec.Vec[ir.Expr].create()
        var ni: ptr_uint = 0
        while ni < all_names.names.len():
            let np = all_names.names.get(ni) else:
                break
            let c = unsafe: read(np)
            if not local_decls.contains(pfor_capture_name(c)):
                captures.push(c)
            ni += 1
        validate_pfor_no_ref_captures(captures.as_span())
        var capture_names_map = map_mod.Map[str, bool].create()
        var capture_names = vec.Vec[str].create()
        var ci: ptr_uint = 0
        while ci < captures.len():
            let cp = captures.get(ci) else:
                break
            let nm = pfor_capture_name(unsafe: read(cp))
            capture_names.push(nm)
            capture_names_map.set(nm, true)
            ci += 1
        var written_map = map_mod.Map[str, bool].create()
        collect_pfor_written_names(body_ir, ref_of(capture_names_map), ref_of(written_map))
        var written_names = vec.Vec[str].create()
        var written_scalars = vec.Vec[ir.Expr].create()
        ci = 0
        while ci < captures.len():
            let cp = captures.get(ci) else:
                break
            let c = unsafe: read(cp)
            let nm = pfor_capture_name(c)
            if written_map.contains(nm):
                written_names.push(nm)
                match c:
                    ir.Expr.expr_name as cn:
                        if not lowering.is_array_type(cn.ty):
                            written_scalars.push(c)
                    _:
                        pass
            ci += 1
        let captureless = captures.len() == 0
        let cap_name = strings.join_three("mt_spawn_cap_", uid_base, strings.join_two("_", lowering.pw1_str(bi)))
        let worker_name = strings.join_three("mt_spawn_work_", uid_base, strings.join_two("_", lowering.pw1_str(bi)))
        var cap_ty = void_ptr
        var cap_init = lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr))
        var worker_body = vec.Vec[ir.Stmt].create()
        if captureless:
            lowering.append_span_stmts(ref_of(worker_body), body_ir)
        else:
            var array_capture_names = map_mod.Map[str, bool].create()
            var cap_fields = vec.Vec[ir.Field].create()
            ci = 0
            while ci < captures.len():
                let cp = captures.get(ci) else:
                    break
                match unsafe: read(cp):
                    ir.Expr.expr_name as nm:
                        if lowering.is_array_type(nm.ty):
                            array_capture_names.set(nm.name, true)
                            cap_fields.push(ir.Field(name = nm.name, ty = pfor_ptr_type(pfor_element_type(nm.ty))))
                        else:
                            cap_fields.push(ir.Field(name = nm.name, ty = nm.ty))
                    _:
                        pass
                ci += 1
            ctx.pending_synthetic_structs.push(ir.StructDecl(
                name = cap_name,
                linkage_name = cap_name,
                fields = cap_fields.as_span(),
                packed = false,
                alignment = 0,
                source_module = Option[str].none
            ))
            cap_ty = types.named_type(name = cap_name, module_name = "", linkage_name = Option[str].none)
            let cap_ptr_ty = pfor_ptr_type(cap_ty)
            worker_body.push(ir.Stmt.stmt_local(
                name = "mt_cap", linkage_name = "mt_cap", ty = cap_ptr_ty,
                value = lowering.alloc_expr(ir.Expr.expr_cast(
                    target_type = cap_ptr_ty,
                    expression = lowering.alloc_expr(ir.Expr.expr_name(
                        name = "mt_pfor_data",
                        ty = void_ptr,
                        pointer = Option[bool].some(value = false)
                    )),
                    ty = cap_ptr_ty,
                )),
                line = 0, source_path = "",
            ))
            let cap_ref = lowering.alloc_expr(ir.Expr.expr_name(
                name = "mt_cap",
                ty = cap_ptr_ty,
                pointer = Option[bool].some(value = true)
            ))
            ci = 0
            while ci < captures.len():
                let cp = captures.get(ci) else:
                    break
                match unsafe: read(cp):
                    ir.Expr.expr_name as nm:
                        var alias_ty = nm.ty
                        if lowering.is_array_type(nm.ty):
                            alias_ty = pfor_ptr_type(pfor_element_type(nm.ty))
                        worker_body.push(ir.Stmt.stmt_local(
                            name = nm.name, linkage_name = nm.name, ty = alias_ty,
                            value = lowering.alloc_expr(ir.Expr.expr_member(
                                receiver = cap_ref,
                                member = nm.name,
                                ty = alias_ty
                            )),
                            line = 0, source_path = "",
                        ))
                    _:
                        pass
                ci += 1
            if array_capture_names.len() > 0:
                lowering.append_span_stmts(
                    ref_of(worker_body),
                    rewrite_pfor_array_captures(body_ir, ref_of(array_capture_names))
                )
            else:
                lowering.append_span_stmts(ref_of(worker_body), body_ir)
            # Write-back assignments for written scalar captures.
            var wsi: ptr_uint = 0
            while wsi < written_scalars.len():
                let wp = written_scalars.get(wsi) else:
                    break
                match unsafe: read(wp):
                    ir.Expr.expr_name as nm:
                        worker_body.push(ir.Stmt.stmt_assignment(
                            target = lowering.alloc_expr(ir.Expr.expr_member(
                                receiver = cap_ref,
                                member = nm.name,
                                ty = nm.ty
                            )),
                            operator = "=",
                            value = lowering.alloc_expr(ir.Expr.expr_name(
                                name = nm.name,
                                ty = nm.ty,
                                pointer = Option[bool].some(value = false)
                            )),
                        ))
                    _:
                        pass
                wsi += 1
            var cap_fields_out = vec.Vec[ir.AggregateField].create()
            ci = 0
            while ci < captures.len():
                let cp = captures.get(ci) else:
                    break
                match unsafe: read(cp):
                    ir.Expr.expr_name as nm:
                        if array_capture_names.contains(nm.name):
                            cap_fields_out.push(ir.AggregateField(
                                name = nm.name,
                                value = lowering.alloc_expr(ir.Expr.expr_name(
                                    name = nm.name,
                                    ty = pfor_ptr_type(pfor_element_type(nm.ty)),
                                    pointer = Option[bool].some(value = false)
                                )),
                            ))
                        else:
                            cap_fields_out.push(ir.AggregateField(name = nm.name, value = unsafe: cp))
                    _:
                        pass
                ci += 1
            cap_init = lowering.alloc_expr(ir.Expr.expr_aggregate_literal(
                ty = cap_ty,
                fields = cap_fields_out.as_span()
            ))
        var worker_params = vec.Vec[ir.Param].create()
        worker_params.push(ir.Param(
            name = "mt_pfor_data",
            linkage_name = "mt_pfor_data",
            ty = void_ptr,
            pointer = Option[bool].some(value = false)
        ))
        let worker = ir.Function(
            name = worker_name, linkage_name = worker_name,
            params = worker_params.as_span(), return_type = void_ty,
            body = worker_body.as_span(), entry_point = false, public_export = false, method_receiver_param = false,
        )
        ctx.pending_synthetic_functions.push(worker)
        infos.push(SpawnBlockInfo(
            worker_name = worker_name,
            cap_local_name = strings.join_two("mt_spawn_cap_", lowering.pw1_str(bi)),
            cap_ty = cap_ty,
            cap_init = cap_init,
            capture_names = capture_names,
            written_names = written_names,
            written_scalars = written_scalars,
            captureless = captureless,
        ))
        bi += 1


function void_ptr_ty() -> types.Type:
    return types.generic_type(name = "ptr", args = lowering.sp_type(types.primitive("void")))


## Lower `gather h1, h2, ...`.  Each handle is joined via mt_detach_join; the
## host wraps the joins in one block.
public function lower_gather_stmt(
    ctx: ref[lowering.LoweringContext],
    output: ref[vec.Vec[ir.Stmt]],
    handles: span[ast.Expr]
) -> void:
    let void_ty = ctx.void_ty
    var joins = vec.Vec[ir.Stmt].create()
    var i: ptr_uint = 0
    while i < handles.len:
        let h = unsafe: lowering.lower_expr(ctx, handles.data + i)
        var join_args = vec.Vec[ir.Expr].create()
        unsafe:
            join_args.push(read(h))
        joins.push(ir.Stmt.stmt_expression(
            expression = lowering.alloc_expr(ir.Expr.expr_call(
                callee = "mt_detach_join",
                arguments = join_args.as_span(),
                ty = void_ty
            )),
            line = 0, source_path = "",
        ))
        i += 1
    output.push(ir.Stmt.stmt_block(body = joins.as_span()))


## Lower `detach <call>` (the host's `lower_detach_expr`, `loops.rb:810`).
## The call runs in a worker function; the expression yields an opaque Handle.
public function lower_detach_expr(
    ctx: ref[lowering.LoweringContext],
    expression: ptr[ast.Expr],
    ep: ptr[ast.Expr]
) -> ptr[ir.Expr]:
    # The call runs in a worker, so its setup must not hoist into the enclosing
    # statement's window.
    let hoist_saved = lowering.suspend_stmt_setup(ctx)
    let void_ty = ctx.void_ty
    let void_ptr = void_ptr_ty()
    parallel_cnt += 1
    let uid = parallel_uid(ctx, "detach")
    let worker_name = strings.join_two("mt_detach_work_", uid)
    let lowered_call = lowering.lower_expr(ctx, expression)
    var wb = vec.Vec[ir.Stmt].create()
    wb.push(ir.Stmt.stmt_expression(expression = lowered_call, line = 0, source_path = ctx.analysis.source_path))
    var all_names = PforNames(names = vec.Vec[ir.Expr].create(), seen = map_mod.Map[str, bool].create())
    collect_pfor_ir_names_span(wb.as_span(), ref_of(all_names))
    var local_decls = map_mod.Map[str, bool].create()
    collect_pfor_local_decls_span(wb.as_span(), ref_of(local_decls))
    var captures = vec.Vec[ir.Expr].create()
    var ni: ptr_uint = 0
    while ni < all_names.names.len():
        let np = all_names.names.get(ni) else:
            break
        let c = unsafe: read(np)
        if not local_decls.contains(pfor_capture_name(c)):
            captures.push(c)
        ni += 1
    validate_pfor_no_ref_captures(captures.as_span())
    if captures.len() > 0:
        fatal(c"detach with captured variables is not yet supported; use a global function call or module-level variables")
    var worker_params = vec.Vec[ir.Param].create()
    worker_params.push(ir.Param(
        name = "mt_pfor_data",
        linkage_name = "mt_pfor_data",
        ty = void_ptr,
        pointer = Option[bool].some(value = false)
    ))
    let worker = ir.Function(
        name = worker_name, linkage_name = worker_name,
        params = worker_params.as_span(), return_type = void_ty,
        body = wb.as_span(), entry_point = false, public_export = false, method_receiver_param = false,
    )
    ctx.pending_synthetic_functions.push(worker)
    lowering.resume_stmt_setup(ctx, hoist_saved)
    let fn_ty = types.function_type(
        name = "",
        params = span[types.Type](),
        return_type = types.alloc_type(void_ty),
        variadic = false,
        is_proc = false,
        param_names = span[str]()
    )
    var da = vec.Vec[ir.Expr].create()
    unsafe: da.push(read(lowering.alloc_expr(ir.Expr.expr_name(
        name = worker_name,
        ty = fn_ty,
        pointer = Option[bool].some(value = false)
    ))))
    unsafe: da.push(read(lowering.alloc_expr(ir.Expr.expr_integer_literal(value = 0, ty = void_ptr))))
    return lowering.alloc_expr(ir.Expr.expr_call(callee = "mt_detach_run", arguments = da.as_span(), ty = void_ptr))
