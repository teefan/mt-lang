## C expression rendering, extracted from c_backend/c_backend.mt.

import std.string as string
import std.vec as vec

import mtc.float_text as float_text
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
                return c_float_literal(lit.value, is_float32)
            ir.Expr.expr_boolean_literal as b:
                return if b.value: "true" else: "false"
            ir.Expr.expr_string_literal as s:
                return render_string_literal(e, s.value, s.cstring)
            ir.Expr.expr_unary as un:
                if un.operator == "not":
                    return strings.join_two("!", wrap_expr(e, un.operand))
                return strings.join_two(un.operator, wrap_expr(e, un.operand))
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
                    return render_variant_equality(e, bin.operator, bin.left, bin.right)
                if c_backend.is_struct_equality(bin.operator, bin.left, bin.right, e):
                    return render_struct_equality(e, bin.operator, bin.left, bin.right)
                if c_backend.is_nullable_null_comparison(bin.operator, bin.left, bin.right):
                    return render_nullable_null_comparison(e, bin.operator, bin.left, bin.right)
                return render_binary(e, bin.operator, bin.left, bin.right)
            ir.Expr.expr_call as call:
                return render_call(e, call.callee, call.arguments)
            ir.Expr.expr_call_indirect as call:
                return render_indirect_call(e, call.callee, call.arguments)
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
                let operator = if pointer_member_receiver(member.receiver): "->" else: "."
                return strings.join_three(
                    c_backend.wrap_member_receiver(e, member.receiver),
                    operator,
                    c_backend.c_safe_field_name(member.member)
                )
            ir.Expr.expr_aggregate_literal as agg:
                return render_aggregate_literal(e, agg.ty, agg.fields)
            ir.Expr.expr_variant_literal as vl:
                return strings.join_four(
                    "(",
                    c_backend.c_type(vl.ty),
                    ")",
                    c_backend.render_variant_initializer(e, vl.ty, vl.arm_name, vl.fields, true)
                )
            ir.Expr.expr_zero_init as z:
                return render_zero_expr(z.ty)
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
                return render_address_of(e, addr.expression)
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
                return render_array_literal_expr(e, arr.ty, arr.elements)
            ir.Expr.expr_conditional as cond:
                return strings.join_five(
                    c_backend.emit_conditional_condition(e, cond.condition),
                    " ? ",
                    render_expr(e, cond.then_expression),
                    " : ",
                    render_expr(e, cond.else_expression)
                )
            ir.Expr.expr_stmt_expr as se:
                return render_stmt_expr(e, se.setup, se.result)
            ir.Expr.expr_simd_lane_with as lw:
                # The host's `emit_simd_lane_with`: a GCC statement expression
                # with its fixed `_mt_with` temp.
                var lbuf = string.String.create()
                lbuf.append("({ ")
                lbuf.append(c_backend.c_type(lw.ty))
                lbuf.append(" _mt_with = ")
                lbuf.append(wrap_expr(e, lw.src))
                lbuf.append("; ((")
                lbuf.append(c_backend.c_type(types.simd_element_type(lw.ty)))
                lbuf.append("*)&_mt_with)[")
                lbuf.append(render_expr(e, lw.index))
                lbuf.append("] = ")
                lbuf.append(wrap_expr(e, lw.value))
                lbuf.append("; _mt_with; })")
                return lbuf.as_str()
            ir.Expr.expr_assignment as asg:
                return strings.join_five(render_expr(e, asg.target), " ", asg.operator, " ", render_expr(e, asg.value))
            _:
                fatal(c"c_backend: unsupported expression")

public function render_binary(e: ref[c_backend.Emitter], operator: str, left: ptr[ir.Expr], right: ptr[ir.Expr]) -> str:
    let parent = c_backend.binary_precedence(operator)
    let left_text = c_backend.render_binary_operand(e, left, parent, false)
    let right_text = c_backend.render_binary_operand(e, right, parent, true)
    return strings.join_five(left_text, " ", c_backend.c_operator(operator), " ", right_text)


public function render_call(e: ref[c_backend.Emitter], callee: str, arguments: span[ir.Expr]) -> str:
    var buf = string.String.create()
    buf.append(callee)
    buf.append("(")
    var i: ptr_uint = 0
    while i < arguments.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            buf.append(c_backend.render_expr(e, arguments.data + i))
        i += 1
    buf.append(")")
    return buf.as_str()


## Render a call through a function-pointer expression: `(*callee)(args)`.
public function render_indirect_call(e: ref[c_backend.Emitter], callee: ptr[ir.Expr], arguments: span[ir.Expr]) -> str:
    let callee_text = unsafe: c_backend.render_expr(e, callee)
    let needs_wrap = not unsafe: c_backend.is_postfix_expr(callee)
    var buf = string.String.create()
    if needs_wrap:
        buf.append("(")
    buf.append(callee_text)
    if needs_wrap:
        buf.append(")")
    buf.append("(")
    var i: ptr_uint = 0
    while i < arguments.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            buf.append(c_backend.render_expr(e, arguments.data + i))
        i += 1
    buf.append(")")
    return buf.as_str()


public function render_aggregate_literal(e: ref[c_backend.Emitter], ty: types.Type, fields: span[ir.AggregateField]) -> str:
    return strings.join_four("(", c_backend.c_type(ty), ")", c_backend.render_aggregate_initializer(e, fields))


## Render an array literal in initializer position: `{ e0, e1, ... }`.  An empty
## array literal degenerates to `{ 0 }`.  Mirrors the aggregate initializer form.
## An array literal in expression position needs a C compound literal:
## `(int32_t [3]) { 10, 20, 30 }`.  A bare braced list is only valid as an
## initializer, e.g. in a local declaration.
public function render_array_literal_expr(e: ref[c_backend.Emitter], ty: types.Type, elements: span[ir.Expr]) -> str:
    var length = c_backend.array_length(ty)
    if length == 0:
        length = int<-elements.len
    var buf = string.String.create()
    buf.append("(")
    buf.append(c_backend.array_literal_cast_type(ty, length))
    buf.append(") ")
    buf.append(c_backend.render_array_literal_initializer(e, elements))
    return buf.as_str()


public function render_string_literal(e: ref[c_backend.Emitter], value: str, cstring: bool) -> str:
    if cstring:
        return c_backend.c_string_literal(value)
    let name_ptr = e.str_lit_map.get(value)
    if name_ptr != null:
        unsafe:
            return read(name_ptr)
    return strings.join_five(
        "(mt_str){ .data = ",
        c_backend.c_string_literal(value),
        ", .len = ",
        c_backend.ptr_uint_to_str(value.len),
        " }"
    )


## The zero value of a type in expression position.
public function render_zero_expr(t: types.Type) -> str:
    match t:
        types.Type.ty_opaque as op:
            let op_bp = unsafe: read(op.payload)
            if op_bp.module_name.starts_with("std.c."):
                return strings.join_four("(", c_backend.c_decl(t, ""), ") ", c_backend.render_zero_initializer(t))
            return "NULL"
        types.Type.ty_primitive as p:
            # vec2/vec3/vec4/mat*/quat are struct-like aggregates: a bare
            # `{ 0 }` is only valid as an initializer, so expression position
            # needs a compound literal.
            if c_backend.is_vec_math_name(p.name):
                return strings.join_four("(", c_backend.c_type(t), ")", " { 0 }")
            return c_backend.render_zero_initializer(t)
        types.Type.ty_str:
            return strings.join_four("(", c_backend.c_type(t), ")", " { 0 }")
        _:
            return strings.join_four("(", c_backend.c_decl(t, ""), ") ", c_backend.render_zero_initializer(t))


public function render_stmt_expr(e: ref[c_backend.Emitter], setup: span[ir.Stmt], result: ptr[ir.Expr]) -> str:
    var buf = string.String.create()
    buf.append("({ ")
    var i: ptr_uint = 0
    while i < setup.len:
        buf.append(c_backend.render_stmt_expr_stmt(e, unsafe: setup.data + i))
        buf.append(" ")
        i += 1
    buf.append(c_backend.render_expr(e, result))
    buf.append("; })")
    return buf.as_str()


## The address of an operand for a `&`-style position.  A checked array index is
## the pointer the helper already returns (no extra `*`/`&`); other operands are
## `&expr`.
public function render_address_of(e: ref[c_backend.Emitter], ep: ptr[ir.Expr]) -> str:
    unsafe:
        match read(ep):
            ir.Expr.expr_checked_index as ci:
                return strings.join_four(
                    c_backend.checked_array_index_helper_name(ci.receiver_type),
                    "(",
                    c_backend.wrap_member_receiver(e, ci.receiver),
                    strings.join_three(", ", c_backend.render_expr(e, ci.index), ")")
                )
            _:
                return c_backend.render_address_of_operand(e, ep)


## Render a nullable-value `== null` or `!= null` comparison as a `.has_value` check.
public function render_nullable_null_comparison(
    e: ref[c_backend.Emitter],
    operator: str,
    left: ptr[ir.Expr],
    right: ptr[ir.Expr]
) -> str:
    unsafe:
        let operand = if c_backend.is_null_literal_expr(left): right else: left
        let access = strings.join_three(c_backend.render_expr(e, operand), ".has_value", "")
        if operator == "==":
            return strings.join_two("!", access)
        return access


## Render a struct equality expression as a call to the generated helper
## (`mt_struct_eq_<c_name>(left, right)`); `!=` is negated by the caller.
public function render_struct_equality(e: ref[c_backend.Emitter], operator: str, left: ptr[ir.Expr], right: ptr[ir.Expr]) -> str:
    let cname = c_backend.c_type(c_backend.expr_result_type(left))
    let fn_name = c_backend.struct_equality_helper_name(cname)
    let call = strings.join_five(strings.join_two(fn_name, "("), c_backend.render_expr(e, left), ", ", c_backend.render_expr(e, right), ")")
    if operator == "!=":
        return strings.join_two("!", call)
    return call


## Render a variant equality expression as a call to the generated helper
## (`mt_variant_eq_<variant_c_name>(left, right)`).  The leading `!` for `!=`
## is inserted by the caller.
public function render_variant_equality(e: ref[c_backend.Emitter], operator: str, left: ptr[ir.Expr], right: ptr[ir.Expr]) -> str:
    let variant_name = c_backend.variant_c_name_for_type(c_backend.expr_result_type(left))
    let fn_name = c_backend.variant_equality_helper_name(variant_name)
    let call = strings.join_five(strings.join_two(fn_name, "("), c_backend.render_expr(e, left), ", ", c_backend.render_expr(e, right), ")")
    if operator == "!=":
        return strings.join_two("!", call)
    return call


public function wrap_expr(e: ref[c_backend.Emitter], ep: ptr[ir.Expr]) -> str:
    let text = c_backend.render_expr(e, ep)
    unsafe:
        match read(ep):
            ir.Expr.expr_name:
                return text
            ir.Expr.expr_integer_literal:
                return text
            ir.Expr.expr_unsigned_integer_literal:
                return text
            ir.Expr.expr_float_literal:
                return text
            ir.Expr.expr_boolean_literal:
                return text
            ir.Expr.expr_string_literal:
                return text
            ir.Expr.expr_null_literal:
                return text
            ir.Expr.expr_zero_init:
                return text
            ir.Expr.expr_member:
                return text
            ir.Expr.expr_index:
                return text
            ir.Expr.expr_call:
                return text
            ir.Expr.expr_aggregate_literal:
                return text
            ir.Expr.expr_array_literal:
                return text
            ir.Expr.expr_reinterpret:
                return text
            ir.Expr.expr_sizeof:
                return text
            ir.Expr.expr_alignof:
                return text
            ir.Expr.expr_offsetof:
                return text
            _:
                return strings.join_three("(", text, ")")


public function pointer_member_receiver(ep: ptr[ir.Expr]) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as n:
                if n.pointer.unwrap_or(false):
                    return true
                return c_backend.is_ptr_type(n.ty)
            _:
                return c_backend.is_ptr_type(c_backend.expr_result_type(ep))


## Render a float/double literal as a C *floating-point* literal.  A whole-number
## double like `1.0` formats as `"1"` in `%g` terms, which C parses as an `int` —
## so a `.0` is appended when the text has no decimal point or exponent (matches
## Ruby, which emits `1.0`).  A `float`-typed literal carries C's `f` suffix, as
## the host emits (`0.2f`).
public function c_float_literal(value: double, is_float32: bool) -> str:
    let s = float_text.double_to_str(value)
    var text = if c_backend.float_literal_needs_decimal(s): strings.join_two(s, ".0") else: s
    if is_float32:
        return strings.join_two(text, "f")
    return text
