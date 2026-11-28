## C expression rendering, extracted from c_backend/c_backend.mt.

import std.string as string
import std.vec as vec

import mtc.ir as ir
import mtc.semantic.types as types
import mtc.strings
import mtc.c_backend.c_backend as c_backend


public function render_expr(e: ref[c_backend.Emitter], ep: ptr[ir.Expr]) -> str:
    # An array-returning call hoisted into a temp (materialized before the
    # enclosing statement) renders as the temp name instead of re-emitting the
    # call (which C cannot use in value position).
    let ac_key = unsafe: reinterpret[ptr_uint](ep)
    let ac_ptr = e.array_call_temps.get(ac_key)
    if ac_ptr != null:
        return unsafe: read(ac_ptr)
    unsafe:
        match read(ep):
            ir.Expr.expr_name as n:
                return n.name
            ir.Expr.expr_integer_literal as lit:
                return c_backend.long_to_str(lit.value)
            ir.Expr.expr_unsigned_integer_literal as lit:
                # A lexeme-derived value too large for a signed `long` renders in
                # the unsigned domain, as the host does (`18446744073709551615`,
                # not `-1`).
                return c_backend.ptr_uint_to_str(lit.value)
            ir.Expr.expr_float_literal as lit:
                var is_float32 = false
                match lit.ty:
                    types.Type.ty_primitive as p:
                        if p.name == "float":
                            is_float32 = true
                    _:
                        pass
                return c_backend.c_float_literal(lit.value, is_float32)
            ir.Expr.expr_boolean_literal as b:
                return if b.value: "true" else: "false"
            ir.Expr.expr_string_literal as s:
                return c_backend.render_string_literal(e, s.value, s.cstring)
            ir.Expr.expr_unary as un:
                if un.operator == "not":
                    return strings.join_two("!", c_backend.wrap_expr(e, un.operand))
                return strings.join_two(un.operator, c_backend.wrap_expr(e, un.operand))
            ir.Expr.expr_binary as bin:
                if c_backend.is_str_equality(bin.operator, bin.left, bin.right):
                    let call = strings.join_five(
                        "mt_str_equal(",
                        render_expr(e, bin.left),
                        ", ",
                        render_expr(e, bin.right),
                        ")"
                    )
                    if bin.operator == "!=":
                        return strings.join_two("!", call)
                    return call
                if c_backend.is_variant_equality(bin.operator, bin.left, bin.right, e):
                    return c_backend.render_variant_equality(e, bin.operator, bin.left, bin.right)
                if c_backend.is_struct_equality(bin.operator, bin.left, bin.right, e):
                    return c_backend.render_struct_equality(e, bin.operator, bin.left, bin.right)
                if c_backend.is_nullable_null_comparison(bin.operator, bin.left, bin.right):
                    return c_backend.render_nullable_null_comparison(e, bin.operator, bin.left, bin.right)
                return c_backend.render_binary(e, bin.operator, bin.left, bin.right)
            ir.Expr.expr_call as call:
                return c_backend.render_call(e, call.callee, call.arguments)
            ir.Expr.expr_call_indirect as call:
                return c_backend.render_indirect_call(e, call.callee, call.arguments)
            ir.Expr.expr_member as member:
                # Enum/flags member access on a type name (lowered as
                # `expr_name(Module.Type, ty=ty_type_meta)` with subsequent
                # `.MemberValue` access).  In C, enum values are bare constants
                # (e.g. `UV_TIMER`); emit just the member name.
                unsafe:
                    match read(member.receiver):
                        ir.Expr.expr_name as n:
                            match n.ty:
                                types.Type.ty_type_meta:
                                    return member.member
                                _:
                                    pass
                        _:
                            pass
                let operator = if c_backend.pointer_member_receiver(member.receiver): "->" else: "."
                return strings.join_three(
                    c_backend.wrap_member_receiver(e, member.receiver),
                    operator,
                    c_backend.c_safe_field_name(member.member)
                )
            ir.Expr.expr_aggregate_literal as agg:
                return c_backend.render_aggregate_literal(e, agg.ty, agg.fields)
            ir.Expr.expr_variant_literal as vl:
                return strings.join_four(
                    "(",
                    c_backend.c_type(vl.ty),
                    ")",
                    c_backend.render_variant_initializer(e, vl.ty, vl.arm_name, vl.fields, true)
                )
            ir.Expr.expr_zero_init as z:
                return c_backend.render_zero_expr(z.ty)
            ir.Expr.expr_null_literal as nl:
                if c_backend.is_value_nullable(nl.ty):
                    return strings.join_three("(", c_backend.c_type(nl.ty), "){0}")
                return "NULL"
            ir.Expr.expr_cast as cast:
                # A cast whose target C type equals its operand's C type is a
                # no-op: emit the bare operand (mirrors Ruby's no_op_cast?).
                if c_backend.no_op_cast(cast.expression, cast.target_type):
                    return render_expr(e, cast.expression)
                var cast_buf = string.String.create()
                cast_buf.append("(")
                cast_buf.append(c_backend.c_type(cast.target_type))
                cast_buf.append(") ")
                cast_buf.append(c_backend.emit_cast_operand(e, cast.expression))
                return cast_buf.as_str()
            ir.Expr.expr_checked_index as ci:
                return strings.join_five(
                    "(*",
                    c_backend.checked_array_index_helper_name(ci.receiver_type),
                    "(",
                    c_backend.wrap_member_receiver(e, ci.receiver),
                    strings.join_three(", ", render_expr(e, ci.index), "))")
                )
            ir.Expr.expr_checked_span_index as cs:
                return strings.join_five(
                    "(*",
                    c_backend.checked_span_index_helper_name(cs.receiver_type),
                    "(",
                    render_expr(e, cs.receiver),
                    strings.join_three(", ", render_expr(e, cs.index), "))")
                )
            ir.Expr.expr_nullable_index as ni:
                return strings.join_five(
                    c_backend.nullable_array_index_helper_name(ni.receiver_type),
                    "(",
                    c_backend.wrap_member_receiver(e, ni.receiver),
                    ", ",
                    strings.join_two(render_expr(e, ni.index), ")")
                )
            ir.Expr.expr_nullable_span_index as ns:
                return strings.join_five(
                    c_backend.nullable_span_index_helper_name(ns.receiver_type),
                    "(",
                    render_expr(e, ns.receiver),
                    ", ",
                    strings.join_two(render_expr(e, ns.index), ")")
                )
            ir.Expr.expr_index as ix:
                return strings.join_four(c_backend.wrap_member_receiver(e, ix.receiver), "[", render_expr(e, ix.index), "]")
            ir.Expr.expr_address_of as addr:
                return c_backend.render_address_of(e, addr.expression)
            ir.Expr.expr_sizeof as sz:
                var buf = string.String.create()
                buf.append("sizeof(")
                buf.append(c_backend.c_type(sz.target_type))
                buf.append(")")
                return buf.as_str()
            ir.Expr.expr_alignof as al:
                var buf = string.String.create()
                buf.append("_Alignof(")
                buf.append(c_backend.c_type(al.target_type))
                buf.append(")")
                return buf.as_str()
            ir.Expr.expr_offsetof as off:
                return strings.join_five("offsetof(", c_backend.c_type(off.target_type), ", ", off.field, ")")
            ir.Expr.expr_reinterpret as rin:
                # Bit reinterpret (not a numeric cast): a union compound literal
                # copies the source bits into the target representation, so
                # `reinterpret[uint](f)` yields the IEEE bits rather than `(uint)f`.
                let rp = unsafe: read(rin.payload)
                var rbuf = string.String.create()
                rbuf.append("((union { ")
                rbuf.append(c_backend.c_type(rp.source_type))
                rbuf.append(" __s; ")
                rbuf.append(c_backend.c_type(rp.ty))
                rbuf.append(" __t; }){ .__s = (")
                rbuf.append(render_expr(e, rp.expression))
                rbuf.append(") }).__t")
                return rbuf.as_str()
            ir.Expr.expr_array_literal as arr:
                return c_backend.render_array_literal_expr(e, arr.ty, arr.elements)
            ir.Expr.expr_conditional as cond:
                return strings.join_five(
                    c_backend.emit_conditional_condition(e, cond.condition),
                    " ? ",
                    render_expr(e, cond.then_expression),
                    " : ",
                    render_expr(e, cond.else_expression)
                )
            ir.Expr.expr_stmt_expr as se:
                return c_backend.render_stmt_expr(e, se.setup, se.result)
            ir.Expr.expr_simd_lane_with as lw:
                # The host's `emit_simd_lane_with`: a GCC statement expression
                # with its fixed `_mt_with` temp.
                var lbuf = string.String.create()
                lbuf.append("({ ")
                lbuf.append(c_backend.c_type(lw.ty))
                lbuf.append(" _mt_with = ")
                lbuf.append(c_backend.wrap_expr(e, lw.src))
                lbuf.append("; ((")
                lbuf.append(c_backend.c_type(types.simd_element_type(lw.ty)))
                lbuf.append("*)&_mt_with)[")
                lbuf.append(render_expr(e, lw.index))
                lbuf.append("] = ")
                lbuf.append(c_backend.wrap_expr(e, lw.value))
                lbuf.append("; _mt_with; })")
                return lbuf.as_str()
            ir.Expr.expr_assignment as asg:
                return strings.join_five(render_expr(e, asg.target), " ", asg.operator, " ", render_expr(e, asg.value))
            _:
                fatal(c"c_backend: unsupported expression")
