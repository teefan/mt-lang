## C slice/str helper collection and emission, extracted from c_backend/c_backend.mt.

import std.map as map_mod
import std.string as string
import std.vec as vec

import mtc.c_naming as naming
import mtc.ir as ir
import mtc.semantic.types as types
import mtc.strings
import mtc.c_backend.c_backend as c_backend


## True when any emitted function calls `mt_str_slice`; also collects the span
## result types whose `mt_span_slice_<T>` helpers must be emitted.
public function collect_slice_helpers(
    funcs: span[ir.Function],
    has_str: ref[bool],
    has_str_index: ref[bool],
    has_str_concat: ref[bool],
    span_types: ref[vec.Vec[types.Type]]
) -> void:
    var seen = map_mod.Map[str, bool].create()
    var i: ptr_uint = 0
    while i < funcs.len:
        unsafe:
            collect_slice_from_stmts(
                read(funcs.data + i).body,
                has_str,
                has_str_index,
                has_str_concat,
                span_types,
                ref_of(seen)
            )
        i += 1


function collect_slice_from_stmts(
    body: span[ir.Stmt],
    has_str: ref[bool],
    has_str_index: ref[bool],
    has_str_concat: ref[bool],
    span_types: ref[vec.Vec[types.Type]],
    seen: ref[map_mod.Map[str, bool]]
) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            collect_slice_from_stmt(body.data + i, has_str, has_str_index, has_str_concat, span_types, seen)
        i += 1


function collect_slice_from_stmt(
    sp: ptr[ir.Stmt],
    has_str: ref[bool],
    has_str_index: ref[bool],
    has_str_concat: ref[bool],
    span_types: ref[vec.Vec[types.Type]],
    seen: ref[map_mod.Map[str, bool]]
) -> void:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_local as loc:
                collect_slice_from_expr(loc.value, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Stmt.stmt_assignment as asg:
                collect_slice_from_expr(asg.target, has_str, has_str_index, has_str_concat, span_types, seen)
                collect_slice_from_expr(asg.value, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Stmt.stmt_expression as ex:
                collect_slice_from_expr(ex.expression, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Stmt.stmt_return as r:
                let rv = r.value
                if rv != null:
                    collect_slice_from_expr(rv, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Stmt.stmt_block as blk:
                collect_slice_from_stmts(blk.body, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Stmt.stmt_if as iff:
                collect_slice_from_expr(iff.condition, has_str, has_str_index, has_str_concat, span_types, seen)
                collect_slice_from_stmts(iff.then_body, has_str, has_str_index, has_str_concat, span_types, seen)
                collect_slice_from_stmts(
                    c_backend.else_stmts_or_empty(iff.else_body),
                    has_str,
                    has_str_index,
                    has_str_concat,
                    span_types,
                    seen
                )
            ir.Stmt.stmt_while as w:
                collect_slice_from_expr(w.condition, has_str, has_str_index, has_str_concat, span_types, seen)
                collect_slice_from_stmts(w.body, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Stmt.stmt_for as f:
                collect_slice_from_stmt(f.init, has_str, has_str_index, has_str_concat, span_types, seen)
                collect_slice_from_expr(f.condition, has_str, has_str_index, has_str_concat, span_types, seen)
                collect_slice_from_stmts(f.body, has_str, has_str_index, has_str_concat, span_types, seen)
                collect_slice_from_stmt(f.post, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Stmt.stmt_switch as sw:
                collect_slice_from_expr(sw.expression, has_str, has_str_index, has_str_concat, span_types, seen)
                var ci: ptr_uint = 0
                while ci < sw.cases.len:
                    collect_slice_from_stmts(
                        read(sw.cases.data + ci).body,
                        has_str,
                        has_str_index,
                        has_str_concat,
                        span_types,
                        seen
                    )
                    ci += 1
            _:
                pass


function collect_slice_from_expr(
    ep: ptr[ir.Expr],
    has_str: ref[bool],
    has_str_index: ref[bool],
    has_str_concat: ref[bool],
    span_types: ref[vec.Vec[types.Type]],
    seen: ref[map_mod.Map[str, bool]]
) -> void:
    unsafe:
        match read(ep):
            ir.Expr.expr_call as call:
                if call.callee == "mt_str_slice":
                    read(has_str) = true
                else if call.callee == "mt_str_index":
                    read(has_str_index) = true
                else if call.callee == "mt_str_concat":
                    read(has_str_concat) = true
                else if call.callee.starts_with("mt_span_slice_"):
                    let ty = call.ty
                    if c_backend.is_span_type(ty):
                        let name = c_backend.span_type_name(c_backend.array_element_type(ty))
                        if not seen.contains(name):
                            seen.set(name, true)
                            span_types.push(ty)
                var ai: ptr_uint = 0
                while ai < call.arguments.len:
                    collect_slice_from_expr(
                        call.arguments.data + ai,
                        has_str,
                        has_str_index,
                        has_str_concat,
                        span_types,
                        seen
                    )
                    ai += 1
            ir.Expr.expr_call_indirect as call:
                collect_slice_from_expr(call.callee, has_str, has_str_index, has_str_concat, span_types, seen)
                var bi: ptr_uint = 0
                while bi < call.arguments.len:
                    collect_slice_from_expr(
                        call.arguments.data + bi,
                        has_str,
                        has_str_index,
                        has_str_concat,
                        span_types,
                        seen
                    )
                    bi += 1
            ir.Expr.expr_unary as un:
                collect_slice_from_expr(un.operand, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Expr.expr_binary as bin:
                collect_slice_from_expr(bin.left, has_str, has_str_index, has_str_concat, span_types, seen)
                collect_slice_from_expr(bin.right, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Expr.expr_conditional as cond:
                collect_slice_from_expr(cond.condition, has_str, has_str_index, has_str_concat, span_types, seen)
                collect_slice_from_expr(cond.then_expression, has_str, has_str_index, has_str_concat, span_types, seen)
                collect_slice_from_expr(cond.else_expression, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Expr.expr_member as m:
                collect_slice_from_expr(m.receiver, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Expr.expr_index as ix:
                collect_slice_from_expr(ix.receiver, has_str, has_str_index, has_str_concat, span_types, seen)
                collect_slice_from_expr(ix.index, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Expr.expr_checked_index as ix:
                collect_slice_from_expr(ix.receiver, has_str, has_str_index, has_str_concat, span_types, seen)
                collect_slice_from_expr(ix.index, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Expr.expr_checked_span_index as ix:
                collect_slice_from_expr(ix.receiver, has_str, has_str_index, has_str_concat, span_types, seen)
                collect_slice_from_expr(ix.index, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Expr.expr_cast as cast:
                collect_slice_from_expr(cast.expression, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Expr.expr_address_of as addr:
                collect_slice_from_expr(addr.expression, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Expr.expr_reinterpret as rin:
                collect_slice_from_expr(
                    unsafe: read(rin.payload).expression,
                    has_str,
                    has_str_index,
                    has_str_concat,
                    span_types,
                    seen
                )
            ir.Expr.expr_aggregate_literal as agg:
                var fi: ptr_uint = 0
                while fi < agg.fields.len:
                    collect_slice_from_expr(
                        read(agg.fields.data + fi).value,
                        has_str,
                        has_str_index,
                        has_str_concat,
                        span_types,
                        seen
                    )
                    fi += 1
            ir.Expr.expr_variant_literal as vl:
                var vi: ptr_uint = 0
                while vi < vl.fields.len:
                    collect_slice_from_expr(
                        read(vl.fields.data + vi).value,
                        has_str,
                        has_str_index,
                        has_str_concat,
                        span_types,
                        seen
                    )
                    vi += 1
            ir.Expr.expr_array_literal as arr:
                var ei: ptr_uint = 0
                while ei < arr.elements.len:
                    collect_slice_from_expr(
                        arr.elements.data + ei,
                        has_str,
                        has_str_index,
                        has_str_concat,
                        span_types,
                        seen
                    )
                    ei += 1
            ir.Expr.expr_stmt_expr as se:
                collect_slice_from_stmts(se.setup, has_str, has_str_index, has_str_concat, span_types, seen)
                collect_slice_from_expr(se.result, has_str, has_str_index, has_str_concat, span_types, seen)
            ir.Expr.expr_assignment as asg:
                collect_slice_from_expr(asg.target, has_str, has_str_index, has_str_concat, span_types, seen)
                collect_slice_from_expr(asg.value, has_str, has_str_index, has_str_concat, span_types, seen)
            _:
                pass


public function emit_slice_helpers(
    e: ref[c_backend.Emitter],
    has_str: bool,
    has_str_index: bool,
    has_str_concat: bool,
    span_types: vec.Vec[types.Type]
) -> void:
    if has_str:
        emit_str_slice_helper(e)
    if has_str_index:
        c_backend.emit_str_index_helper(e)
    if has_str_concat:
        c_backend.emit_str_concat_helper(e)
    var i: ptr_uint = 0
    while i < span_types.len():
        let ty_ptr = span_types.get(i) else:
            break
        emit_span_slice_helper(e, unsafe: read(ty_ptr))
        i += 1


function emit_str_slice_helper(e: ref[c_backend.Emitter]) -> void:
    c_backend.emit_line(e, "static bool mt_str_utf8_boundary(mt_str text, uintptr_t index) {")
    c_backend.emit_line(e, "  if (index == 0 || index == text.len) return true;")
    c_backend.emit_line(e, "  return ((uint8_t)text.data[index] & 0xC0) != 0x80;")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
    c_backend.emit_line(e, "static mt_str mt_str_slice(mt_str text, uintptr_t start, uintptr_t stop) {")
    c_backend.emit_line(e, "  if (start > stop || stop > text.len) mt_fatal(\"str slice out of bounds\");")
    c_backend.emit_line(
        e,
        "  if (!mt_str_utf8_boundary(text, start) || !mt_str_utf8_boundary(text, stop)) mt_fatal(\"str slice bounds must be UTF-8 code-unit boundaries\");"
    )
    c_backend.emit_line(e, "  return (mt_str){ .data = text.data + start, .len = stop - start };")
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")


function emit_span_slice_helper(e: ref[c_backend.Emitter], span_ty: types.Type) -> void:
    let span_name = c_backend.span_type_name(c_backend.array_element_type(span_ty))
    let helper = strings.join_two("mt_span_slice_", naming.type_c_key(c_backend.array_element_type(span_ty)))
    c_backend.emit_line(
        e,
        strings.join_five(
            "static inline ",
            span_name,
            " ",
            helper,
            strings.join_three("(", span_name, " span, uintptr_t start, uintptr_t stop) {")
        )
    )
    c_backend.emit_line(e, "  if (start > stop || stop > span.len) mt_fatal(\"span slice out of bounds\");")
    c_backend.emit_line(
        e,
        strings.join_five("  return (", span_name, "){ .data = span.data + start, .len = stop - start };", "", "")
    )
    c_backend.emit_line(e, "}")
    c_backend.emit_line(e, "")
