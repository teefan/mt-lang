## Proc-symbol renumbering — the host allocates `__proc_<N>__*` symbols with a
## per-compile counter in *lowering* order, which for functions is also their
## final emission order.  The self lowers generic specializations eagerly at
## their first call site, so their numbers can be assigned in a different order
## even when the emitted function order is reconstructed correctly.
##
## This pass recomputes the ids from the assembled program: it walks the
## constants, globals and functions in emission order (the host's allocation
## order), collects the existing ids in first-occurrence order, and rewrites
## every proc-symbol occurrence in the IR.  A program whose ids are already in
## emission order maps to itself.

import std.vec as vec
import std.map as map_mod
import std.str
import std.string as string
import std.fmt as fmt

import mtc.ir as ir
import mtc.semantic.types as types
import mtc.lowering.utils as utils


## First-occurrence-ordered proc ids (the host's counter order).  A hash map
## would not preserve insertion order, which is exactly what this pass needs.
struct ProcOrder:
    ids: vec.Vec[str]
    seen: map_mod.Map[str, bool]


## The numeric id in a `__proc_<N>__` occurrence, when `s` contains one.
function proc_number(s: str) -> Option[str]:
    var i: ptr_uint = 0
    while i + 9 <= s.len:
        if (
            s.byte_at(i) == 95 and s.byte_at(i + 1) == 95
            and s.byte_at(i + 2) == 112 and s.byte_at(i + 3) == 114
            and s.byte_at(i + 4) == 111 and s.byte_at(i + 5) == 99
            and s.byte_at(i + 6) == 95
        ):
            var j = i + 7
            let start = j
            while j < s.len and s.byte_at(j) >= 48 and s.byte_at(j) <= 57:
                j += 1
            if j > start and j + 1 < s.len and s.byte_at(j) == 95 and s.byte_at(j + 1) == 95:
                return Option[str].some(value = s.slice(start, j - start))
            i = j
        else:
            i += 1
    return Option[str].none


## True when the `__proc_` marker starts at `i`.
function proc_marker_at(s: str, i: ptr_uint) -> bool:
    return (
        i + 7 <= s.len
        and s.byte_at(i) == 95 and s.byte_at(i + 1) == 95
        and s.byte_at(i + 2) == 112 and s.byte_at(i + 3) == 114
        and s.byte_at(i + 4) == 111 and s.byte_at(i + 5) == 99
        and s.byte_at(i + 6) == 95
    )


## Replace every `__proc_<old>__` id in `s` according to `mapping`.
function rename_proc_str(s: str, mapping: ref[map_mod.Map[str, str]]) -> str:
    var i: ptr_uint = 0
    var found = false
    while i < s.len and not found:
        if proc_marker_at(s, i):
            found = true
        else:
            i += 1
    if not found:
        return s
    var buf = string.String.create()
    var pos: ptr_uint = 0
    var cursor = i
    while cursor < s.len:
        if not proc_marker_at(s, cursor):
            buf.push_byte(s.byte_at(cursor))
            cursor += 1
            continue
        if cursor > pos:
            buf.append(s.slice(pos, cursor - pos))
        buf.append("__proc_")
        var j = cursor + 7
        let start = j
        while j < s.len and s.byte_at(j) >= 48 and s.byte_at(j) <= 57:
            j += 1
        let digits = s.slice(start, j - start)
        var written = false
        let mapped = mapping.get(digits)
        if mapped != null:
            buf.append(unsafe: read(mapped))
            written = true
        if not written:
            buf.append(digits)
        if j + 1 < s.len and s.byte_at(j) == 95 and s.byte_at(j + 1) == 95:
            buf.append("__")
            cursor = j + 2
        else:
            cursor = j
        pos = cursor
    return buf.as_str()


## The numeric proc id encoded in a helper function's name, if it has one.
function proc_helper_id(name: str) -> Option[ptr_uint]:
    match proc_number(name):
        Option.some as digits:
            var n: ptr_uint = 0
            var i: ptr_uint = 0
            while i < digits.value.len:
                n = n * 10 + ptr_uint<-(digits.value.byte_at(i) - 48)
                i += 1
            return Option[ptr_uint].some(value = n)
        Option.none:
            return Option[ptr_uint].none


## Reorder the proc invoke/release/retain helpers by their (new) ids.  The host
## appends each group when the literal is lowered, so the tail is in numeric
## order; the self's eager specialization lowering can create the groups in a
## different order.  Non-proc synthetic functions keep their positions.
function reorder_proc_helpers(functions: vec.Vec[ir.Function]) -> vec.Vec[ir.Function]:
    var helpers = vec.Vec[ir.Function].create()
    var i: ptr_uint = 0
    while i < functions.len():
        let fp = functions.get(i) else:
            break
        let f = unsafe: read(fp)
        if proc_helper_id(f.name).is_some():
            helpers.push(f)
        i += 1
    if helpers.len() < 2:
        return functions
    var swapped = true
    while swapped:
        swapped = false
        var k: ptr_uint = 0
        while k + 1 < helpers.len():
            let lp = helpers.get(k) else:
                break
            let rp = helpers.get(k + 1) else:
                break
            let left = unsafe: read(lp)
            let right = unsafe: read(rp)
            let left_id = proc_helper_id(left.name)
            let right_id = proc_helper_id(right.name)
            var out_of_order = false
            match left_id:
                Option.some as li:
                    match right_id:
                        Option.some as ri:
                            if li.value > ri.value:
                                out_of_order = true
                        Option.none:
                            pass
                Option.none:
                    pass
            if out_of_order:
                helpers.swap(k, k + 1)
                swapped = true
            k += 1
    var ordered = vec.Vec[ir.Function].create()
    var hi: ptr_uint = 0
    i = 0
    while i < functions.len():
        let fp = functions.get(i) else:
            break
        let f = unsafe: read(fp)
        if proc_helper_id(f.name).is_some():
            let hp = helpers.get(hi) else:
                break
            ordered.push(unsafe: read(hp))
            hi += 1
        else:
            ordered.push(f)
        i += 1
    return ordered


function rename_opt_str(value: Option[str], mapping: ref[map_mod.Map[str, str]]) -> Option[str]:
    match value:
        Option.some as s:
            return Option[str].some(value = rename_proc_str(s.value, mapping))
        Option.none:
            return Option[str].none


# =============================================================================
#  Collection (first-occurrence order in the final IR)
# =============================================================================

function collect_expr_proc(e: ir.Expr, order: ref[ProcOrder]) -> void:
    match e:
        ir.Expr.expr_name as nm:
            match proc_number(nm.name):
                Option.some as digits:
                    if not order.seen.contains(digits.value):
                        order.seen.set(digits.value, true)
                        order.ids.push(digits.value)
                Option.none:
                    pass
        ir.Expr.expr_member as m:
            collect_expr_proc(unsafe: read(m.receiver), order)
        ir.Expr.expr_index as x:
            collect_expr_proc(unsafe: read(x.receiver), order)
            collect_expr_proc(unsafe: read(x.index), order)
        ir.Expr.expr_checked_index as x:
            collect_expr_proc(unsafe: read(x.receiver), order)
            collect_expr_proc(unsafe: read(x.index), order)
        ir.Expr.expr_checked_span_index as x:
            collect_expr_proc(unsafe: read(x.receiver), order)
            collect_expr_proc(unsafe: read(x.index), order)
        ir.Expr.expr_nullable_index as x:
            collect_expr_proc(unsafe: read(x.receiver), order)
            collect_expr_proc(unsafe: read(x.index), order)
        ir.Expr.expr_nullable_span_index as x:
            collect_expr_proc(unsafe: read(x.receiver), order)
            collect_expr_proc(unsafe: read(x.index), order)
        ir.Expr.expr_call as call:
            collect_exprs_proc(call.arguments, order)
        ir.Expr.expr_call_indirect as call:
            collect_expr_proc(unsafe: read(call.callee), order)
            collect_exprs_proc(call.arguments, order)
        ir.Expr.expr_unary as u:
            collect_expr_proc(unsafe: read(u.operand), order)
        ir.Expr.expr_binary as b:
            collect_expr_proc(unsafe: read(b.left), order)
            collect_expr_proc(unsafe: read(b.right), order)
        ir.Expr.expr_conditional as c:
            collect_expr_proc(unsafe: read(c.condition), order)
            collect_expr_proc(unsafe: read(c.then_expression), order)
            collect_expr_proc(unsafe: read(c.else_expression), order)
        ir.Expr.expr_reinterpret as r:
            let rp = unsafe: read(r.payload)
            collect_expr_proc(unsafe: read(rp.expression), order)
        ir.Expr.expr_address_of as a:
            collect_expr_proc(unsafe: read(a.expression), order)
        ir.Expr.expr_cast as c:
            collect_expr_proc(unsafe: read(c.expression), order)
        ir.Expr.expr_aggregate_literal as agg:
            collect_fields_proc(agg.fields, order)
        ir.Expr.expr_variant_literal as vl:
            collect_fields_proc(vl.fields, order)
        ir.Expr.expr_array_literal as arr:
            collect_exprs_proc(arr.elements, order)
        ir.Expr.expr_stmt_expr as se:
            collect_stmts_proc(se.setup, order)
            collect_expr_proc(unsafe: read(se.result), order)
        ir.Expr.expr_assignment as asg:
            collect_expr_proc(unsafe: read(asg.target), order)
            collect_expr_proc(unsafe: read(asg.value), order)
        ir.Expr.expr_simd_lane_with as sw:
            collect_expr_proc(unsafe: read(sw.src), order)
            collect_expr_proc(unsafe: read(sw.index), order)
            collect_expr_proc(unsafe: read(sw.value), order)
        _:
            pass


function collect_exprs_proc(items: span[ir.Expr], order: ref[ProcOrder]) -> void:
    var i: ptr_uint = 0
    while i < items.len:
        collect_expr_proc(unsafe: read(items.data + i), order)
        i += 1


function collect_fields_proc(fields: span[ir.AggregateField], order: ref[ProcOrder]) -> void:
    var i: ptr_uint = 0
    while i < fields.len:
        let f = unsafe: read(fields.data + i)
        collect_expr_proc(unsafe: read(f.value), order)
        i += 1


function collect_stmts_proc(stmts: span[ir.Stmt], order: ref[ProcOrder]) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        collect_stmt_proc(unsafe: read(stmts.data + i), order)
        i += 1


function collect_stmt_proc(s: ir.Stmt, order: ref[ProcOrder]) -> void:
    match s:
        ir.Stmt.stmt_local as loc:
            collect_expr_proc(unsafe: read(loc.value), order)
        ir.Stmt.stmt_assignment as asg:
            collect_expr_proc(unsafe: read(asg.target), order)
            collect_expr_proc(unsafe: read(asg.value), order)
        ir.Stmt.stmt_expression as ex:
            collect_expr_proc(unsafe: read(ex.expression), order)
        ir.Stmt.stmt_return as ret:
            let value = ret.value
            if value != null:
                collect_expr_proc(unsafe: read(unsafe: ptr[ir.Expr]<-value), order)
        ir.Stmt.stmt_if as iff:
            collect_expr_proc(unsafe: read(iff.condition), order)
            collect_stmts_proc(iff.then_body, order)
            match iff.else_body:
                Option.some as eb:
                    collect_stmts_proc(eb.value, order)
                Option.none:
                    pass
        ir.Stmt.stmt_while as w:
            collect_expr_proc(unsafe: read(w.condition), order)
            collect_stmts_proc(w.body, order)
        ir.Stmt.stmt_for as f:
            collect_stmt_proc(unsafe: read(f.init), order)
            collect_expr_proc(unsafe: read(f.condition), order)
            collect_stmt_proc(unsafe: read(f.post), order)
            collect_stmts_proc(f.body, order)
        ir.Stmt.stmt_block as blk:
            collect_stmts_proc(blk.body, order)
        ir.Stmt.stmt_switch as sw:
            collect_expr_proc(unsafe: read(sw.expression), order)
            var ci: ptr_uint = 0
            while ci < sw.cases.len:
                let c = unsafe: read(sw.cases.data + ci)
                collect_stmts_proc(c.body, order)
                ci += 1
        ir.Stmt.stmt_static_assert as sa:
            collect_expr_proc(unsafe: read(sa.condition), order)
            collect_expr_proc(unsafe: read(sa.message), order)
        _:
            pass


# =============================================================================
#  Rewriting
# =============================================================================

function rename_type(t: types.Type, mapping: ref[map_mod.Map[str, str]]) -> types.Type:
    match t:
        types.Type.ty_primitive as p:
            return types.Type.ty_primitive(name = rename_proc_str(p.name, mapping))
        types.Type.ty_nullable as nl:
            return types.Type.ty_nullable(base = types.alloc_type(rename_type(unsafe: read(nl.base), mapping)))
        types.Type.ty_null as nt:
            let target = nt.target
            if target == null:
                return types.Type.ty_null(target = null)
            return types.Type.ty_null(target = types.alloc_type(rename_type(unsafe: read(target), mapping)))
        types.Type.ty_event as ev:
            let ev_bp = unsafe: read(ev.payload)
            var payload: ptr[types.Type]? = null
            let pp = ev_bp.payload_type
            if pp != null:
                payload = types.alloc_type(rename_type(unsafe: read(pp), mapping))
            return types.event_type(name = rename_proc_str(ev_bp.name, mapping), capacity = ev_bp.capacity, payload_type = payload, linkage_name = rename_proc_str(ev_bp.linkage_name, mapping))
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return types.named_type(name = rename_proc_str(n_np.name, mapping), module_name = n_np.module_name, linkage_name = rename_opt_str(n_np.linkage_name, mapping))
        types.Type.ty_variant_arm_payload as ap:
            let payload = unsafe: read(ap.payload)
            return types.variant_arm_payload_raw(
                variant_name = payload.variant_name,
                name = rename_proc_str(payload.name, mapping),
                module_name = payload.module_name,
                c_name = rename_proc_str(payload.c_name, mapping),
                display_name = payload.display_name,
                fields = rename_payload_fields(payload.fields, mapping),
            )
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return types.imported_type(module_name = im_bp.module_name, name = rename_proc_str(im_bp.name, mapping), args = rename_types(im_bp.args, mapping))
        types.Type.ty_dyn as d:
            let d_bp = unsafe: read(d.payload)
            return types.dyn_type(iface = rename_proc_str(d_bp.iface, mapping), args = rename_types(d_bp.args, mapping))
        types.Type.ty_dyn_vtable as dv:
            let dv_bp = unsafe: read(dv.payload)
            return types.dyn_vtable_type(interface_name = dv_bp.interface_name, linkage_name = rename_proc_str(dv_bp.linkage_name, mapping))
        types.Type.ty_opaque as op:
            let op_bp = unsafe: read(op.payload)
            return types.opaque_type(module_name = op_bp.module_name, name = op_bp.name)
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return types.generic_type(name = rename_proc_str(g_bp.name, mapping), args = rename_types(g_bp.args, mapping))
        types.Type.ty_function as fnt:
            let fnt_ft = unsafe: read(fnt.payload)
            return types.function_type(name = rename_proc_str(fnt_ft.name, mapping), params = rename_types(fnt_ft.params, mapping), return_type = types.alloc_type(rename_type(unsafe: read(fnt_ft.return_type), mapping)), variadic = fnt_ft.variadic, is_proc = fnt_ft.is_proc, param_names = fnt_ft.param_names)
        types.Type.ty_tuple as tup:
            let tup_bp = unsafe: read(tup.payload)
            return types.tuple_type(elements = rename_types(tup_bp.elements, mapping), field_names = tup_bp.field_names)
        _:
            return t


function rename_types(items: span[types.Type], mapping: ref[map_mod.Map[str, str]]) -> span[types.Type]:
    var renamed = vec.Vec[types.Type].create()
    var i: ptr_uint = 0
    while i < items.len:
        renamed.push(rename_type(unsafe: read(items.data + i), mapping))
        i += 1
    return renamed.as_span()


function rename_payload_fields(fields: span[types.PayloadField], mapping: ref[map_mod.Map[str, str]]) -> span[types.PayloadField]:
    var renamed = vec.Vec[types.PayloadField].create()
    var i: ptr_uint = 0
    while i < fields.len:
        let f = unsafe: read(fields.data + i)
        renamed.push(types.PayloadField(name = f.name, ty = rename_type(f.ty, mapping)))
        i += 1
    return renamed.as_span()


function rename_expr(ep: ptr[ir.Expr], mapping: ref[map_mod.Map[str, str]]) -> ptr[ir.Expr]:
    let e = unsafe: read(ep)
    match e:
        ir.Expr.expr_name as nm:
            return utils.alloc_expr(ir.Expr.expr_name(
                name = rename_proc_str(nm.name, mapping),
                ty = rename_type(nm.ty, mapping),
                pointer = nm.pointer,
            ))
        ir.Expr.expr_member as m:
            return utils.alloc_expr(ir.Expr.expr_member(
                receiver = rename_expr(m.receiver, mapping),
                member = m.member,
                ty = rename_type(m.ty, mapping),
            ))
        ir.Expr.expr_index as x:
            return utils.alloc_expr(ir.Expr.expr_index(
                receiver = rename_expr(x.receiver, mapping),
                index = rename_expr(x.index, mapping),
                ty = rename_type(x.ty, mapping),
            ))
        ir.Expr.expr_checked_index as x:
            return utils.alloc_expr(ir.Expr.expr_checked_index(
                receiver = rename_expr(x.receiver, mapping),
                index = rename_expr(x.index, mapping),
                receiver_type = rename_type(x.receiver_type, mapping),
                ty = rename_type(x.ty, mapping),
            ))
        ir.Expr.expr_checked_span_index as x:
            return utils.alloc_expr(ir.Expr.expr_checked_span_index(
                receiver = rename_expr(x.receiver, mapping),
                index = rename_expr(x.index, mapping),
                receiver_type = rename_type(x.receiver_type, mapping),
                ty = rename_type(x.ty, mapping),
            ))
        ir.Expr.expr_nullable_index as x:
            return utils.alloc_expr(ir.Expr.expr_nullable_index(
                receiver = rename_expr(x.receiver, mapping),
                index = rename_expr(x.index, mapping),
                receiver_type = rename_type(x.receiver_type, mapping),
                ty = rename_type(x.ty, mapping),
            ))
        ir.Expr.expr_nullable_span_index as x:
            return utils.alloc_expr(ir.Expr.expr_nullable_span_index(
                receiver = rename_expr(x.receiver, mapping),
                index = rename_expr(x.index, mapping),
                receiver_type = rename_type(x.receiver_type, mapping),
                ty = rename_type(x.ty, mapping),
            ))
        ir.Expr.expr_call as call:
            return utils.alloc_expr(ir.Expr.expr_call(
                callee = rename_proc_str(call.callee, mapping),
                arguments = rename_exprs(call.arguments, mapping),
                ty = rename_type(call.ty, mapping),
            ))
        ir.Expr.expr_call_indirect as call:
            return utils.alloc_expr(ir.Expr.expr_call_indirect(
                callee = rename_expr(call.callee, mapping),
                arguments = rename_exprs(call.arguments, mapping),
                ty = rename_type(call.ty, mapping),
            ))
        ir.Expr.expr_unary as u:
            return utils.alloc_expr(ir.Expr.expr_unary(
                operator = u.operator,
                operand = rename_expr(u.operand, mapping),
                ty = rename_type(u.ty, mapping),
            ))
        ir.Expr.expr_binary as b:
            return utils.alloc_expr(ir.Expr.expr_binary(
                operator = b.operator,
                left = rename_expr(b.left, mapping),
                right = rename_expr(b.right, mapping),
                ty = rename_type(b.ty, mapping),
            ))
        ir.Expr.expr_conditional as c:
            return utils.alloc_expr(ir.Expr.expr_conditional(
                condition = rename_expr(c.condition, mapping),
                then_expression = rename_expr(c.then_expression, mapping),
                else_expression = rename_expr(c.else_expression, mapping),
                ty = rename_type(c.ty, mapping),
            ))
        ir.Expr.expr_reinterpret as r:
            let rp = unsafe: read(r.payload)
            return utils.alloc_expr(ir.Expr.expr_reinterpret(
                payload = utils.alloc_reinterpret_expr(
                    target_type = rename_type(rp.target_type, mapping),
                    source_type = rename_type(rp.source_type, mapping),
                    expression = rename_expr(rp.expression, mapping),
                    ty = rename_type(rp.ty, mapping),
                )
            ))
        ir.Expr.expr_sizeof as z:
            return utils.alloc_expr(ir.Expr.expr_sizeof(target_type = rename_type(z.target_type, mapping), ty = rename_type(z.ty, mapping)))
        ir.Expr.expr_alignof as z:
            return utils.alloc_expr(ir.Expr.expr_alignof(target_type = rename_type(z.target_type, mapping), ty = rename_type(z.ty, mapping)))
        ir.Expr.expr_offsetof as z:
            return utils.alloc_expr(ir.Expr.expr_offsetof(target_type = rename_type(z.target_type, mapping), field = z.field, ty = rename_type(z.ty, mapping)))
        ir.Expr.expr_address_of as a:
            return utils.alloc_expr(ir.Expr.expr_address_of(expression = rename_expr(a.expression, mapping), ty = rename_type(a.ty, mapping)))
        ir.Expr.expr_cast as c:
            return utils.alloc_expr(ir.Expr.expr_cast(
                target_type = rename_type(c.target_type, mapping),
                expression = rename_expr(c.expression, mapping),
                ty = rename_type(c.ty, mapping),
            ))
        ir.Expr.expr_aggregate_literal as agg:
            return utils.alloc_expr(ir.Expr.expr_aggregate_literal(
                ty = rename_type(agg.ty, mapping),
                fields = rename_aggregate_fields(agg.fields, mapping),
            ))
        ir.Expr.expr_variant_literal as vl:
            return utils.alloc_expr(ir.Expr.expr_variant_literal(
                ty = rename_type(vl.ty, mapping),
                arm_name = vl.arm_name,
                fields = rename_aggregate_fields(vl.fields, mapping),
            ))
        ir.Expr.expr_array_literal as arr:
            return utils.alloc_expr(ir.Expr.expr_array_literal(ty = rename_type(arr.ty, mapping), elements = rename_exprs(arr.elements, mapping)))
        ir.Expr.expr_stmt_expr as se:
            return utils.alloc_expr(ir.Expr.expr_stmt_expr(
                setup = rename_stmt_span(se.setup, mapping),
                result = rename_expr(se.result, mapping),
                ty = rename_type(se.ty, mapping),
            ))
        ir.Expr.expr_assignment as asg:
            return utils.alloc_expr(ir.Expr.expr_assignment(
                target = rename_expr(asg.target, mapping),
                operator = asg.operator,
                value = rename_expr(asg.value, mapping),
            ))
        ir.Expr.expr_simd_lane_with as sw:
            return utils.alloc_expr(ir.Expr.expr_simd_lane_with(
                src = rename_expr(sw.src, mapping),
                index = rename_expr(sw.index, mapping),
                value = rename_expr(sw.value, mapping),
                ty = rename_type(sw.ty, mapping),
            ))
        _:
            return ep


function rename_exprs(items: span[ir.Expr], mapping: ref[map_mod.Map[str, str]]) -> span[ir.Expr]:
    var renamed = vec.Vec[ir.Expr].create()
    var i: ptr_uint = 0
    while i < items.len:
        let ep = unsafe: rename_expr(items.data + i, mapping)
        unsafe:
            renamed.push(read(ep))
        i += 1
    return renamed.as_span()


function rename_aggregate_fields(fields: span[ir.AggregateField], mapping: ref[map_mod.Map[str, str]]) -> span[ir.AggregateField]:
    var renamed = vec.Vec[ir.AggregateField].create()
    var i: ptr_uint = 0
    while i < fields.len:
        let f = unsafe: read(fields.data + i)
        renamed.push(ir.AggregateField(name = f.name, value = rename_expr(f.value, mapping)))
        i += 1
    return renamed.as_span()


function rename_stmt(s: ir.Stmt, mapping: ref[map_mod.Map[str, str]]) -> ir.Stmt:
    match s:
        ir.Stmt.stmt_local as loc:
            return ir.Stmt.stmt_local(
                name = rename_proc_str(loc.name, mapping),
                linkage_name = rename_proc_str(loc.linkage_name, mapping),
                ty = rename_type(loc.ty, mapping),
                value = rename_expr(loc.value, mapping),
                line = loc.line,
                source_path = loc.source_path,
            )
        ir.Stmt.stmt_assignment as asg:
            return ir.Stmt.stmt_assignment(
                target = rename_expr(asg.target, mapping),
                operator = asg.operator,
                value = rename_expr(asg.value, mapping),
            )
        ir.Stmt.stmt_expression as ex:
            return ir.Stmt.stmt_expression(expression = rename_expr(ex.expression, mapping), line = ex.line, source_path = ex.source_path)
        ir.Stmt.stmt_return as ret:
            let value = ret.value
            if value == null:
                return ir.Stmt.stmt_return(value = null, line = ret.line, source_path = ret.source_path)
            return ir.Stmt.stmt_return(
                value = rename_expr(unsafe: ptr[ir.Expr]<-value, mapping),
                line = ret.line, source_path = ret.source_path,
            )
        ir.Stmt.stmt_if as iff:
            var else_body = Option[span[ir.Stmt]].none
            match iff.else_body:
                Option.some as eb:
                    else_body = Option[span[ir.Stmt]].some(value = rename_stmt_span(eb.value, mapping))
                Option.none:
                    pass
            return ir.Stmt.stmt_if(
                condition = rename_expr(iff.condition, mapping),
                then_body = rename_stmt_span(iff.then_body, mapping),
                else_body = else_body,
            )
        ir.Stmt.stmt_while as w:
            return ir.Stmt.stmt_while(condition = rename_expr(w.condition, mapping), body = rename_stmt_span(w.body, mapping))
        ir.Stmt.stmt_for as f:
            return ir.Stmt.stmt_for(
                init = utils.alloc_stmt(rename_stmt(unsafe: read(f.init), mapping)),
                condition = rename_expr(f.condition, mapping),
                post = utils.alloc_stmt(rename_stmt(unsafe: read(f.post), mapping)),
                body = rename_stmt_span(f.body, mapping),
            )
        ir.Stmt.stmt_block as blk:
            return ir.Stmt.stmt_block(body = rename_stmt_span(blk.body, mapping))
        ir.Stmt.stmt_switch as sw:
            var cases = vec.Vec[ir.SwitchCase].create()
            var ci: ptr_uint = 0
            while ci < sw.cases.len:
                let c = unsafe: read(sw.cases.data + ci)
                var case_value: ptr[ir.Expr]? = null
                let cv = c.value
                if cv != null:
                    case_value = rename_expr(unsafe: ptr[ir.Expr]<-cv, mapping)
                cases.push(ir.SwitchCase(is_default = c.is_default, value = case_value, body = rename_stmt_span(c.body, mapping)))
                ci += 1
            return ir.Stmt.stmt_switch(expression = rename_expr(sw.expression, mapping), cases = cases.as_span(), exhaustive = sw.exhaustive)
        ir.Stmt.stmt_static_assert as sa:
            return ir.Stmt.stmt_static_assert(condition = rename_expr(sa.condition, mapping), message = rename_expr(sa.message, mapping))
        _:
            return s


function rename_stmt_span(items: span[ir.Stmt], mapping: ref[map_mod.Map[str, str]]) -> span[ir.Stmt]:
    var renamed = vec.Vec[ir.Stmt].create()
    var i: ptr_uint = 0
    while i < items.len:
        renamed.push(rename_stmt(unsafe: read(items.data + i), mapping))
        i += 1
    return renamed.as_span()


function rename_function(f: ir.Function, mapping: ref[map_mod.Map[str, str]]) -> ir.Function:
    return ir.Function(
        name = rename_proc_str(f.name, mapping),
        linkage_name = rename_proc_str(f.linkage_name, mapping),
        params = rename_params(f.params, mapping),
        return_type = rename_type(f.return_type, mapping),
        body = rename_stmt_span(f.body, mapping),
        entry_point = f.entry_point,
        public_export = f.public_export,
        method_receiver_param = f.method_receiver_param,
    )


function rename_params(params: span[ir.Param], mapping: ref[map_mod.Map[str, str]]) -> span[ir.Param]:
    var renamed = vec.Vec[ir.Param].create()
    var i: ptr_uint = 0
    while i < params.len:
        let p = unsafe: read(params.data + i)
        renamed.push(ir.Param(
            name = rename_proc_str(p.name, mapping),
            linkage_name = rename_proc_str(p.linkage_name, mapping),
            ty = rename_type(p.ty, mapping),
            pointer = p.pointer,
        ))
        i += 1
    return renamed.as_span()


function rename_struct_decl(s: ir.StructDecl, mapping: ref[map_mod.Map[str, str]]) -> ir.StructDecl:
    var fields = vec.Vec[ir.Field].create()
    var i: ptr_uint = 0
    while i < s.fields.len:
        let f = unsafe: read(s.fields.data + i)
        fields.push(ir.Field(name = rename_proc_str(f.name, mapping), ty = rename_type(f.ty, mapping)))
        i += 1
    return ir.StructDecl(
        name = rename_proc_str(s.name, mapping),
        linkage_name = rename_proc_str(s.linkage_name, mapping),
        fields = fields.as_span(),
        packed = s.packed,
        alignment = s.alignment,
        source_module = s.source_module,
    )


function rename_constant(c: ir.Constant, mapping: ref[map_mod.Map[str, str]]) -> ir.Constant:
    return ir.Constant(
        name = rename_proc_str(c.name, mapping),
        linkage_name = rename_proc_str(c.linkage_name, mapping),
        ty = rename_type(c.ty, mapping),
        value = rename_expr(c.value, mapping),
        line = c.line,
        path = c.path,
    )


function rename_global(g: ir.Global, mapping: ref[map_mod.Map[str, str]]) -> ir.Global:
    return ir.Global(
        name = rename_proc_str(g.name, mapping),
        linkage_name = rename_proc_str(g.linkage_name, mapping),
        ty = rename_type(g.ty, mapping),
        value = rename_expr(g.value, mapping),
    )


## Recompute proc ids in the host's allocation order and rewrite the program.
## `module_fn_count` is the number of module functions before the synthetic
## tail.  A proc literal lowered inside a synthetic (async) function gets its id
## in body-lowering order, but only appears in the tail's final order, so the
## pass is skipped entirely when any helper id is not accounted for by a literal
## in the setup values or the module-function prefix.
public function renumber_program_procs(program: ir.Program, module_fn_count: ptr_uint) -> ir.Program:
    var order = ProcOrder(ids = vec.Vec[str].create(), seen = map_mod.Map[str, bool].create())
    var i: ptr_uint = 0
    while i < program.constants.len:
        let c = unsafe: read(program.constants.data + i)
        collect_expr_proc(unsafe: read(c.value), ref_of(order))
        i += 1
    i = 0
    while i < program.globals.len:
        let g = unsafe: read(program.globals.data + i)
        collect_expr_proc(unsafe: read(g.value), ref_of(order))
        i += 1
    var module_count = module_fn_count
    if module_count > program.functions.len:
        module_count = program.functions.len
    i = 0
    while i < module_count:
        let f = unsafe: read(program.functions.data + i)
        collect_stmts_proc(f.body, ref_of(order))
        i += 1
    # Every proc helper in the synthetic tail must correspond to a literal we
    # collected above; otherwise its creation site is a synthetic body and the
    # emission order cannot recover the host's allocation order.
    i = module_count
    while i < program.functions.len:
        let f = unsafe: read(program.functions.data + i)
        match proc_number(f.name):
            Option.some as digits:
                if not order.seen.contains(digits.value):
                    return program
            Option.none:
                pass
        i += 1
    # Captured env structs are named after their proc too; an unaccounted one
    # means the same thing as an unaccounted helper.
    i = 0
    while i < program.structs.len:
        let s = unsafe: read(program.structs.data + i)
        match proc_number(s.name):
            Option.some as digits:
                if not order.seen.contains(digits.value):
                    return program
            Option.none:
                pass
        i += 1

    var mapping = map_mod.Map[str, str].create()
    var changed = false
    var next_id: ptr_uint = 1
    var ki: ptr_uint = 0
    while ki < order.ids.len():
        let id_ptr = order.ids.get(ki) else:
            break
        let old_id = unsafe: read(id_ptr)
        var buf = string.String.create()
        fmt.append_ptr_uint(ref_of(buf), next_id)
        let new_id = buf.as_str()
        mapping.set(old_id, new_id)
        if old_id != new_id:
            changed = true
        next_id += 1
        ki += 1
    if not changed:
        return program

    var constants = vec.Vec[ir.Constant].create()
    i = 0
    while i < program.constants.len:
        let c = unsafe: read(program.constants.data + i)
        constants.push(rename_constant(c, ref_of(mapping)))
        i += 1
    var globals = vec.Vec[ir.Global].create()
    i = 0
    while i < program.globals.len:
        let g = unsafe: read(program.globals.data + i)
        globals.push(rename_global(g, ref_of(mapping)))
        i += 1
    var functions = vec.Vec[ir.Function].create()
    i = 0
    while i < program.functions.len:
        let f = unsafe: read(program.functions.data + i)
        functions.push(rename_function(f, ref_of(mapping)))
        i += 1
    let reordered_fns = reorder_proc_helpers(functions)
    var structs = vec.Vec[ir.StructDecl].create()
    i = 0
    while i < program.structs.len:
        let s = unsafe: read(program.structs.data + i)
        structs.push(rename_struct_decl(s, ref_of(mapping)))
        i += 1
    return ir.Program(
        module_name = program.module_name,
        includes = program.includes,
        constants = constants.as_span(),
        globals = globals.as_span(),
        opaques = program.opaques,
        structs = structs.as_span(),
        unions = program.unions,
        enums = program.enums,
        variants = program.variants,
        static_asserts = program.static_asserts,
        functions = reordered_fns.as_span(),
        type_aliases = program.type_aliases,
        source_path = program.source_path,
        monomorphized_structs = program.monomorphized_structs,
        monomorphized_variants = program.monomorphized_variants,
        external_structs = program.external_structs,
        str_buffer_structs = program.str_buffer_structs,
        arena = program.arena,
    )
