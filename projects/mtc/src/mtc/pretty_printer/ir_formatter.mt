## IR pretty printer — renders an `ir.Program` as indented text, mirroring the
## Ruby PrettyPrinter::IRFormatter (lib/milk_tea/core/pretty_printer/ir_formatter.rb
## plus base_formatter.rb) so that `mtc lower` output matches the Ruby compiler.
##
## Expressions render to single-line strings (IR has no multi-line expression
## forms — procs are lowered to functions), so `render_expression` is a pure
## string builder.  Only statement/declaration emitters touch the line buffer.
##
## Output strings are built with std.string.String and returned as `str` views;
## backing buffers are intentionally leaked (arena-style) since one program is
## rendered per process, matching ast_formatter.mt.

import std.str
import std.string as string
import std.fmt as fmt

import mtc.ir as ir
import mtc.semantic.types as types


const IF_EXPRESSION_PRECEDENCE: int = 5
const POSTFIX_PRECEDENCE: int = 90
const UNARY_PRECEDENCE: int = 80


struct Formatter:
    buffer: string.String
    indent: ptr_uint
    any_output: bool
    last_blank: bool


public function format_program(program: ir.Program) -> string.String:
    var f = Formatter(
        buffer = string.String.create(),
        indent = 0,
        any_output = false,
        last_blank = false,
    )
    emit_program(ref_of(f), program)
    return f.buffer


# =============================================================================
#  String helpers
# =============================================================================

function j2(a: str, b: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    return buf.as_str()

function j3(a: str, b: str, c: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    return buf.as_str()

function j4(a: str, b: str, c: str, d: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    return buf.as_str()

function j5(a: str, b: str, c: str, d: str, e: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    buf.append(e)
    return buf.as_str()

function j6(a: str, b: str, c: str, d: str, e: str, g: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    buf.append(e)
    buf.append(g)
    return buf.as_str()


function indent_str(levels: ptr_uint) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < levels:
        buf.append("    ")
        i += 1
    return buf.as_str()


function long_to_str(value: long) -> str:
    var buf = string.String.create()
    fmt.append_long(ref_of(buf), value)
    return buf.as_str()


function double_to_str(value: double) -> str:
    var buf = string.String.create()
    fmt.append_double(ref_of(buf), value)
    return buf.as_str()


function inspect_str(value: str) -> str:
    var buf = string.String.create()
    buf.append("\"")
    var i: ptr_uint = 0
    while i < value.len:
        let b = value.byte_at(i)
        if b == 34:
            buf.append("\\\"")
        else if b == 92:
            buf.append("\\\\")
        else if b == 10:
            buf.append("\\n")
        else if b == 9:
            buf.append("\\t")
        else if b == 13:
            buf.append("\\r")
        else:
            buf.push_byte(b)
        i += 1
    buf.append("\"")
    return buf.as_str()


# =============================================================================
#  Line buffer
# =============================================================================

function emit_line(f: ref[Formatter], text: str) -> void:
    if text.len == 0:
        f.buffer.append("\n")
        f.any_output = true
        f.last_blank = false
        return
    f.buffer.append(indent_str(f.indent))
    f.buffer.append(text)
    f.buffer.append("\n")
    f.any_output = true
    f.last_blank = false


function blank_line(f: ref[Formatter]) -> void:
    if not f.any_output:
        return
    if f.last_blank:
        return
    f.buffer.append("\n")
    f.last_blank = true


function section_open(f: ref[Formatter], title: str) -> void:
    blank_line(f)
    emit_line(f, j2(title, ":"))
    f.indent += 1


function section_close(f: ref[Formatter]) -> void:
    f.indent -= 1


# =============================================================================
#  Precedence / wrapping
# =============================================================================

function precedence(op: str) -> int:
    if op == "or":
        return 10
    if op == "and":
        return 20
    if op == "|":
        return 30
    if op == "^":
        return 35
    if op == "&":
        return 40
    if op == "==" or op == "!=":
        return 50
    if op == "<" or op == "<=" or op == ">" or op == ">=":
        return 55
    if op == "<<" or op == ">>":
        return 60
    if op == "+" or op == "-":
        return 65
    if op == "*" or op == "/" or op == "%":
        return 70
    return 0


function wrap(text: str, parent_precedence: int, current_precedence: int) -> str:
    if current_precedence >= parent_precedence:
        return text
    return j3("(", text, ")")


function binding_name(name: str, linkage_name: str) -> str:
    if name.len == 0 or name == linkage_name:
        return linkage_name
    return j3(name, " as ", linkage_name)


function render_type(t: types.Type) -> str:
    return types.type_to_string(t)


function is_ptr_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            return g.name == "ptr" and g.args.len == 1
        _:
            return false


# =============================================================================
#  Program
# =============================================================================

function emit_program(f: ref[Formatter], program: ir.Program) -> void:
    let module_name = if program.module_name.len == 0: "(anonymous)" else: program.module_name
    emit_line(f, j2("program ", module_name))

    if program.includes.len > 0:
        section_open(f, "includes")
        var i: ptr_uint = 0
        while i < program.includes.len:
            unsafe:
                emit_line(f, j2("include ", read(program.includes.data + i).header))
            if i < program.includes.len - 1:
                blank_line(f)
            i += 1
        section_close(f)

    if program.constants.len > 0:
        section_open(f, "constants")
        var i: ptr_uint = 0
        while i < program.constants.len:
            unsafe:
                emit_constant(f, read(program.constants.data + i))
            if i < program.constants.len - 1:
                blank_line(f)
            i += 1
        section_close(f)

    if program.globals.len > 0:
        section_open(f, "globals")
        var i: ptr_uint = 0
        while i < program.globals.len:
            unsafe:
                emit_global(f, read(program.globals.data + i))
            if i < program.globals.len - 1:
                blank_line(f)
            i += 1
        section_close(f)

    if program.opaques.len > 0:
        section_open(f, "opaques")
        var i: ptr_uint = 0
        while i < program.opaques.len:
            unsafe:
                emit_opaque(f, read(program.opaques.data + i))
            if i < program.opaques.len - 1:
                blank_line(f)
            i += 1
        section_close(f)

    if program.structs.len > 0:
        section_open(f, "structs")
        var i: ptr_uint = 0
        while i < program.structs.len:
            unsafe:
                emit_struct(f, read(program.structs.data + i))
            if i < program.structs.len - 1:
                blank_line(f)
            i += 1
        section_close(f)

    if program.unions.len > 0:
        section_open(f, "unions")
        var i: ptr_uint = 0
        while i < program.unions.len:
            unsafe:
                emit_union(f, read(program.unions.data + i))
            if i < program.unions.len - 1:
                blank_line(f)
            i += 1
        section_close(f)

    if program.enums.len > 0:
        section_open(f, "enums")
        var i: ptr_uint = 0
        while i < program.enums.len:
            unsafe:
                emit_enum(f, read(program.enums.data + i))
            if i < program.enums.len - 1:
                blank_line(f)
            i += 1
        section_close(f)

    if program.variants.len > 0:
        section_open(f, "variants")
        var i: ptr_uint = 0
        while i < program.variants.len:
            unsafe:
                emit_variant(f, read(program.variants.data + i))
            if i < program.variants.len - 1:
                blank_line(f)
            i += 1
        section_close(f)

    if program.static_asserts.len > 0:
        section_open(f, "static_asserts")
        var i: ptr_uint = 0
        while i < program.static_asserts.len:
            unsafe:
                let sa = read(program.static_asserts.data + i)
                emit_static_assert(f, sa.condition, sa.message)
            if i < program.static_asserts.len - 1:
                blank_line(f)
            i += 1
        section_close(f)

    if program.functions.len > 0:
        section_open(f, "functions")
        var i: ptr_uint = 0
        while i < program.functions.len:
            unsafe:
                emit_function(f, read(program.functions.data + i))
            if i < program.functions.len - 1:
                blank_line(f)
            i += 1
        section_close(f)


# =============================================================================
#  Declaration emitters
# =============================================================================

function emit_constant(f: ref[Formatter], c: ir.Constant) -> void:
    emit_line(f, j6("const ", binding_name(c.name, c.linkage_name), ": ", render_type(c.ty), " = ", render_expression(c.value, 0)))


function emit_global(f: ref[Formatter], g: ir.Global) -> void:
    emit_line(f, j6("var ", binding_name(g.name, g.linkage_name), ": ", render_type(g.ty), " = ", render_expression(g.value, 0)))


function emit_opaque(f: ref[Formatter], o: ir.OpaqueDecl) -> void:
    emit_line(f, j2("opaque ", binding_name(o.name, o.linkage_name)))


function emit_variant(f: ref[Formatter], v: ir.VariantDecl) -> void:
    emit_line(f, j3("variant ", binding_name(v.name, v.linkage_name), ":"))
    f.indent += 1
    var i: ptr_uint = 0
    while i < v.arms.len:
        unsafe:
            let arm = read(v.arms.data + i)
            var text = binding_name(arm.name, arm.linkage_name)
            if arm.fields.len > 0:
                text = j4(text, "(", render_field_list(arm.fields), ")")
            emit_line(f, text)
        i += 1
    f.indent -= 1


function render_field_list(fields: span[ir.Field]) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < fields.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            let fld = read(fields.data + i)
            buf.append(fld.name)
            buf.append(": ")
            buf.append(render_type(fld.ty))
        i += 1
    return buf.as_str()


function emit_struct(f: ref[Formatter], s: ir.StructDecl) -> void:
    var header = j2("struct ", binding_name(s.name, s.linkage_name))
    var modifiers = string.String.create()
    var any_mod = false
    if s.packed:
        modifiers.append("packed")
        any_mod = true
    if s.alignment != 0:
        if any_mod:
            modifiers.append(", ")
        modifiers.append(j3("align(", long_to_str(long<-(s.alignment)), ")"))
        any_mod = true
    if any_mod:
        header = j4(header, " [", modifiers.as_str(), "]")
    header = j2(header, ":")
    emit_line(f, header)
    f.indent += 1
    var i: ptr_uint = 0
    while i < s.fields.len:
        unsafe:
            let fld = read(s.fields.data + i)
            emit_line(f, j3(fld.name, ": ", render_type(fld.ty)))
        i += 1
    f.indent -= 1


function emit_union(f: ref[Formatter], u: ir.UnionDecl) -> void:
    emit_line(f, j3("union ", binding_name(u.name, u.linkage_name), ":"))
    f.indent += 1
    var i: ptr_uint = 0
    while i < u.fields.len:
        unsafe:
            let fld = read(u.fields.data + i)
            emit_line(f, j3(fld.name, ": ", render_type(fld.ty)))
        i += 1
    f.indent -= 1


function emit_enum(f: ref[Formatter], e: ir.EnumDecl) -> void:
    let kind = if e.is_flags: "flags" else: "enum"
    emit_line(f, j6(kind, " ", binding_name(e.name, e.linkage_name), ": ", render_type(e.backing_type), ""))
    f.indent += 1
    var i: ptr_uint = 0
    while i < e.members.len:
        unsafe:
            let m = read(e.members.data + i)
            emit_line(f, j3(binding_name(m.name, m.linkage_name), " = ", render_expression(m.value, 0)))
        i += 1
    f.indent -= 1


function emit_static_assert(f: ref[Formatter], condition: ptr[ir.Expr], message: ptr[ir.Expr]) -> void:
    emit_line(f, j5("static_assert(", render_expression(condition, 0), ", ", render_expression(message, 0), ")"))


function emit_function(f: ref[Formatter], func: ir.Function) -> void:
    let display = if func.name.len == 0: func.linkage_name else: func.name
    var header = j6("fn ", binding_name(display, func.linkage_name), "(", render_param_list(func.params), ") -> ", render_type(func.return_type))
    if func.entry_point:
        header = j2(header, " [entry]")
    header = j2(header, ":")
    emit_line(f, header)
    f.indent += 1
    emit_stmt_body(f, func.body)
    f.indent -= 1


function render_param_list(params: span[ir.Param]) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < params.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            buf.append(render_param(read(params.data + i)))
        i += 1
    return buf.as_str()


function render_param(p: ir.Param) -> str:
    var ty = render_type(p.ty)
    if p.pointer:
        ty = j3("ptr[", ty, "]")
    return j3(binding_name(p.name, p.linkage_name), ": ", ty)


# =============================================================================
#  Statements
# =============================================================================

function emit_stmt_body(f: ref[Formatter], body: span[ir.Stmt]) -> void:
    var i: ptr_uint = 0
    while i < body.len:
        unsafe:
            emit_statement(f, body.data + i)
        i += 1


function emit_statement(f: ref[Formatter], sp: ptr[ir.Stmt]) -> void:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_local as s:
                emit_line(f, j6("let ", binding_name(s.name, s.linkage_name), ": ", render_type(s.ty), " = ", render_expression(s.value, 0)))
            ir.Stmt.stmt_assignment as s:
                emit_line(f, j5(render_expression(s.target, 0), " ", s.operator, " ", render_expression(s.value, 0)))
            ir.Stmt.stmt_block as s:
                emit_line(f, "block:")
                f.indent += 1
                emit_stmt_body(f, s.body)
                f.indent -= 1
            ir.Stmt.stmt_if as s:
                emit_line(f, j3("if ", render_expression(s.condition, 0), ":"))
                f.indent += 1
                emit_stmt_body(f, s.then_body)
                f.indent -= 1
                if s.else_body.len > 0:
                    emit_line(f, "else:")
                    f.indent += 1
                    emit_stmt_body(f, s.else_body)
                    f.indent -= 1
            ir.Stmt.stmt_switch as s:
                emit_line(f, j3("switch ", render_expression(s.expression, 0), ":"))
                f.indent += 1
                var ci: ptr_uint = 0
                while ci < s.cases.len:
                    let sc = read(s.cases.data + ci)
                    if sc.is_default:
                        emit_line(f, "default:")
                    else:
                        let value = sc.value else:
                            fatal(c"ir_formatter: non-default switch case missing value")
                        emit_line(f, j3("case ", render_expression(value, 0), ":"))
                    f.indent += 1
                    emit_stmt_body(f, sc.body)
                    f.indent -= 1
                    ci += 1
                f.indent -= 1
            ir.Stmt.stmt_while as s:
                emit_line(f, j3("while ", render_expression(s.condition, 0), ":"))
                f.indent += 1
                emit_stmt_body(f, s.body)
                f.indent -= 1
            ir.Stmt.stmt_for as s:
                let init = render_for_clause(s.init)
                let post = render_for_clause(s.post)
                emit_line(f, j6("for ", init, "; ", render_expression(s.condition, 0), j3("; ", post, ":"), ""))
                f.indent += 1
                emit_stmt_body(f, s.body)
                f.indent -= 1
            ir.Stmt.stmt_break:
                emit_line(f, "break")
            ir.Stmt.stmt_continue:
                emit_line(f, "continue")
            ir.Stmt.stmt_goto as s:
                emit_line(f, j2("goto ", s.label))
            ir.Stmt.stmt_label as s:
                emit_line(f, j2("label ", s.name))
            ir.Stmt.stmt_static_assert as s:
                emit_static_assert(f, s.condition, s.message)
            ir.Stmt.stmt_return as s:
                let value = s.value else:
                    emit_line(f, "return")
                    return
                emit_line(f, j2("return ", render_expression(value, 0)))
            ir.Stmt.stmt_expression as s:
                emit_line(f, render_expression(s.expression, 0))


function render_for_clause(sp: ptr[ir.Stmt]) -> str:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_local as s:
                return j5(s.linkage_name, ": ", render_type(s.ty), " = ", render_expression(s.value, 0))
            ir.Stmt.stmt_assignment as s:
                return j5(render_expression(s.target, 0), " ", s.operator, " ", render_expression(s.value, 0))
            ir.Stmt.stmt_expression as s:
                return render_expression(s.expression, 0)
            _:
                return ""


# =============================================================================
#  Expressions
# =============================================================================

function render_args(items: span[ir.Expr]) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < items.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            buf.append(render_expression(items.data + i, 0))
        i += 1
    return buf.as_str()


function render_agg_fields(fields: span[ir.AggregateField]) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < fields.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            let fld = read(fields.data + i)
            buf.append(fld.name)
            buf.append(" = ")
            buf.append(render_expression(fld.value, 0))
        i += 1
    return buf.as_str()


function postfix_expression(ep: ptr[ir.Expr]) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_name:
                return true
            ir.Expr.expr_member:
                return true
            ir.Expr.expr_index:
                return true
            ir.Expr.expr_call:
                return true
            ir.Expr.expr_call_indirect:
                return true
            _:
                return false


function render_postfix(ep: ptr[ir.Expr]) -> str:
    if postfix_expression(ep):
        return render_expression(ep, POSTFIX_PRECEDENCE)
    return j3("(", render_expression(ep, 0), ")")


function expr_type(ep: ptr[ir.Expr]) -> types.Type:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as e:
                return e.ty
            ir.Expr.expr_member as e:
                return e.ty
            ir.Expr.expr_index as e:
                return e.ty
            ir.Expr.expr_checked_index as e:
                return e.ty
            ir.Expr.expr_checked_span_index as e:
                return e.ty
            ir.Expr.expr_nullable_index as e:
                return e.ty
            ir.Expr.expr_nullable_span_index as e:
                return e.ty
            ir.Expr.expr_call as e:
                return e.ty
            ir.Expr.expr_call_indirect as e:
                return e.ty
            ir.Expr.expr_unary as e:
                return e.ty
            ir.Expr.expr_binary as e:
                return e.ty
            ir.Expr.expr_conditional as e:
                return e.ty
            ir.Expr.expr_reinterpret as e:
                return e.ty
            ir.Expr.expr_sizeof as e:
                return e.ty
            ir.Expr.expr_alignof as e:
                return e.ty
            ir.Expr.expr_offsetof as e:
                return e.ty
            ir.Expr.expr_integer_literal as e:
                return e.ty
            ir.Expr.expr_float_literal as e:
                return e.ty
            ir.Expr.expr_string_literal as e:
                return e.ty
            ir.Expr.expr_boolean_literal as e:
                return e.ty
            ir.Expr.expr_null_literal as e:
                return e.ty
            ir.Expr.expr_zero_init as e:
                return e.ty
            ir.Expr.expr_address_of as e:
                return e.ty
            ir.Expr.expr_cast as e:
                return e.ty
            ir.Expr.expr_aggregate_literal as e:
                return e.ty
            ir.Expr.expr_variant_literal as e:
                return e.ty
            ir.Expr.expr_array_literal as e:
                return e.ty


function pointer_receiver(ep: ptr[ir.Expr]) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as n:
                if n.pointer:
                    return true
                return is_ptr_type(n.ty)
            _:
                return is_ptr_type(expr_type(ep))


function render_expression(ep: ptr[ir.Expr], parent_precedence: int) -> str:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as e:
                return e.name
            ir.Expr.expr_member as e:
                let operator = if pointer_receiver(e.receiver): "->" else: "."
                return wrap(j3(render_postfix(e.receiver), operator, e.member), parent_precedence, POSTFIX_PRECEDENCE)
            ir.Expr.expr_index as e:
                return wrap(j4(render_postfix(e.receiver), "[", render_expression(e.index, 0), "]"), parent_precedence, POSTFIX_PRECEDENCE)
            ir.Expr.expr_checked_index as e:
                return j6("checked_index<", render_type(e.receiver_type), ">(", render_expression(e.receiver, 0), j3(", ", render_expression(e.index, 0), ")"), "")
            ir.Expr.expr_checked_span_index as e:
                return j6("checked_span_index<", render_type(e.receiver_type), ">(", render_expression(e.receiver, 0), j3(", ", render_expression(e.index, 0), ")"), "")
            ir.Expr.expr_nullable_index as e:
                return j6("nullable_index<", render_type(e.receiver_type), ">(", render_expression(e.receiver, 0), j3(", ", render_expression(e.index, 0), ")"), "")
            ir.Expr.expr_nullable_span_index as e:
                return j6("nullable_span_index<", render_type(e.receiver_type), ">(", render_expression(e.receiver, 0), j3(", ", render_expression(e.index, 0), ")"), "")
            ir.Expr.expr_call as e:
                return wrap(j4(e.callee, "(", render_args(e.arguments), ")"), parent_precedence, POSTFIX_PRECEDENCE)
            ir.Expr.expr_call_indirect as e:
                return wrap(j4("indirect(", render_expression(e.callee, 0), j2(", ", render_args(e.arguments)), ")"), parent_precedence, POSTFIX_PRECEDENCE)
            ir.Expr.expr_unary as e:
                let operand = render_expression(e.operand, UNARY_PRECEDENCE)
                let text = if e.operator == "not": j2("not ", operand) else: j2(e.operator, operand)
                return wrap(text, parent_precedence, UNARY_PRECEDENCE)
            ir.Expr.expr_binary as e:
                let current = precedence(e.operator)
                let left = render_expression(e.left, current)
                let right = render_expression(e.right, current + 1)
                return wrap(j5(left, " ", e.operator, " ", right), parent_precedence, current)
            ir.Expr.expr_conditional as e:
                let condition = render_expression(e.condition, IF_EXPRESSION_PRECEDENCE)
                let then_expr = render_expression(e.then_expression, IF_EXPRESSION_PRECEDENCE)
                let else_expr = render_expression(e.else_expression, IF_EXPRESSION_PRECEDENCE)
                return wrap(j6("if ", condition, ": ", then_expr, j2(" else: ", else_expr), ""), parent_precedence, IF_EXPRESSION_PRECEDENCE)
            ir.Expr.expr_reinterpret as e:
                return j6("reinterpret[", render_type(e.target_type), " <- ", render_type(e.source_type), j3("](", render_expression(e.expression, 0), ")"), "")
            ir.Expr.expr_sizeof as e:
                return j3("size_of(", render_type(e.target_type), ")")
            ir.Expr.expr_alignof as e:
                return j3("align_of(", render_type(e.target_type), ")")
            ir.Expr.expr_offsetof as e:
                return j5("offset_of(", render_type(e.target_type), ", ", e.field, ")")
            ir.Expr.expr_integer_literal as e:
                return long_to_str(e.value)
            ir.Expr.expr_float_literal as e:
                return double_to_str(e.value)
            ir.Expr.expr_string_literal as e:
                if e.cstring:
                    return j2("c", inspect_str(e.value))
                return inspect_str(e.value)
            ir.Expr.expr_boolean_literal as e:
                return if e.value: "true" else: "false"
            ir.Expr.expr_null_literal:
                return "null"
            ir.Expr.expr_zero_init as e:
                return j3("zero[", render_type(e.ty), "]")
            ir.Expr.expr_address_of as e:
                return wrap(j2("&", render_expression(e.expression, UNARY_PRECEDENCE)), parent_precedence, UNARY_PRECEDENCE)
            ir.Expr.expr_cast as e:
                return j3(render_type(e.target_type), "<-", render_expression(e.expression, 0))
            ir.Expr.expr_aggregate_literal as e:
                return j4(render_type(e.ty), "(", render_agg_fields(e.fields), ")")
            ir.Expr.expr_variant_literal as e:
                if e.fields.len == 0:
                    return j3(render_type(e.ty), ".", e.arm_name)
                return j6(render_type(e.ty), ".", e.arm_name, "(", render_agg_fields(e.fields), ")")
            ir.Expr.expr_array_literal as e:
                return j4(render_type(e.ty), "(", render_args(e.elements), ")")
