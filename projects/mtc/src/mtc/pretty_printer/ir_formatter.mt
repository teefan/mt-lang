## IR pretty printer — renders an `ir.Program` as indented text, mirroring the
## Ruby PrettyPrinter::IRFormatter (lib/milk_tea/core/pretty_printer/ir_formatter.rb
## plus base_formatter.rb) so that `mtc lower` output matches the Ruby compiler.
##
## Every emitter appends straight into the output buffer: there are no
## intermediate line or expression strings, so rendering a program costs its
## output size rather than a per-node string tree.
##
## `write_program` is the streaming entry point — it flushes the buffer to
## stdout at a bounded chunk size, so a dump never has to fit in memory.
## `format_program` accumulates the whole text for callers that compare it
## (the in-language tests).

import std.str
import std.stdio as stdio
import std.string as string
import std.fmt as fmt

import mtc.float_text as float_text
import mtc.ir as ir
import mtc.semantic.types as types

const IF_EXPRESSION_PRECEDENCE: int = 5
const POSTFIX_PRECEDENCE: int = 90
const UNARY_PRECEDENCE: int = 80

## Chunk size for `write_program`: the dump is flushed to stdout whenever the
## buffer reaches this many bytes, so the peak stays bounded by one chunk.
const STREAM_CHUNK_BYTES: ptr_uint = 1 << 16

struct Formatter:
    buffer: string.String
    indent: ptr_uint
    any_output: bool
    last_blank: bool
    ## True for `write_program`: the buffer is a flush-on-full window instead of
    ## an accumulator, so it is cleared rather than grown without bound.
    streaming: bool


public function format_program(program: ir.Program) -> string.String:
    var f = Formatter(
        buffer = string.String.create(),
        indent = 0,
        any_output = false,
        last_blank = false,
        streaming = false,
    )
    emit_program(ref_of(f), program)
    return f.buffer


## Render `program` to stdout without holding the whole dump in memory.  The
## buffer is flushed whenever it reaches `STREAM_CHUNK_BYTES`, so the live cost
## is one bounded chunk.
public function write_program(program: ir.Program) -> void:
    var f = Formatter(
        buffer = string.String.with_capacity(STREAM_CHUNK_BYTES),
        indent = 0,
        any_output = false,
        last_blank = false,
        streaming = true,
    )
    emit_program(ref_of(f), program)
    flush_chunk(ref_of(f))
    f.buffer.release()


## Write the buffered bytes to stdout and clear the buffer.  `print_format`
## takes a `str`, and `as_str` validates UTF-8 — a chunk boundary may split a
## multi-byte sequence, so the buffer is only ever flushed at a line boundary,
## which the emit helpers guarantee.
function flush_chunk(f: ref[Formatter]) -> void:
    if f.buffer.len() == 0:
        return
    let text = f.buffer.as_str()
    stdio.print_format(c"%.*s", int<-(text.len), text.data)
    f.buffer.clear()


## Flush after a line when the buffer has reached the chunk size.
function maybe_flush(f: ref[Formatter]) -> void:
    if f.streaming and f.buffer.len() >= STREAM_CHUNK_BYTES:
        flush_chunk(f)

# =============================================================================
#  String helpers
# =============================================================================

const INDENT_UNIT: str = "    "


function append_inspect(f: ref[Formatter], value: str) -> void:
    f.buffer.append("\"")
    var i: ptr_uint = 0
    while i < value.len:
        let b = value.byte_at(i)
        if b == 34:
            f.buffer.append("\\\"")
        else if b == 92:
            f.buffer.append("\\\\")
        else if b == 10:
            f.buffer.append("\\n")
        else if b == 9:
            f.buffer.append("\\t")
        else if b == 13:
            f.buffer.append("\\r")
        else:
            f.buffer.push_byte(b)
        i += 1
    f.buffer.append("\"")

# =============================================================================
#  Line buffer
# =============================================================================

## Begin a line at the current indent; `end_line` terminates it.
function begin_line(f: ref[Formatter]) -> void:
    var i: ptr_uint = 0
    while i < f.indent:
        f.buffer.append(INDENT_UNIT)
        i += 1


function end_line(f: ref[Formatter]) -> void:
    f.buffer.append("\n")
    f.any_output = true
    f.last_blank = false
    maybe_flush(f)


function blank_line(f: ref[Formatter]) -> void:
    if not f.any_output:
        return
    if f.last_blank:
        return
    f.buffer.append("\n")
    f.last_blank = true
    maybe_flush(f)


function section_open(f: ref[Formatter], title: str) -> void:
    blank_line(f)
    begin_line(f)
    f.buffer.append(title)
    f.buffer.append(":")
    end_line(f)
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


## Open a parenthesised group when the nested expression binds looser than the
## enclosing one.  Callers pair this with `close_group`.
function open_group(f: ref[Formatter], parent_precedence: int, current_precedence: int) -> bool:
    if current_precedence >= parent_precedence:
        return false
    f.buffer.append("(")
    return true


function close_group(f: ref[Formatter], opened: bool) -> void:
    if opened:
        f.buffer.append(")")


function append_binding_name(f: ref[Formatter], name: str, linkage_name: str) -> void:
    if name.len == 0 or name == linkage_name:
        f.buffer.append(linkage_name)
        return
    f.buffer.append(name)
    f.buffer.append(" as ")
    f.buffer.append(linkage_name)


function render_type(f: ref[Formatter], t: types.Type) -> void:
    # The host's IR formatter interpolates its type objects, whose `to_s`
    # carries the defining module (`examples.sdl3.demo.woodeneye.Player`), not
    # the LSP/display form.
    types.append_qualified_type(ref_of(f.buffer), t)


function is_ptr_type(t: types.Type) -> bool:
    match t:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return g_bp.name == "ptr" and g_bp.args.len == 1
        _:
            return false

# =============================================================================
#  Program
# =============================================================================

function emit_program(f: ref[Formatter], program: ir.Program) -> void:
    begin_line(f)
    f.buffer.append("program ")
    if program.module_name.len == 0:
        f.buffer.append("(anonymous)")
    else:
        f.buffer.append(program.module_name)
    end_line(f)

    if program.includes.len > 0:
        section_open(f, "includes")
        var i: ptr_uint = 0
        while i < program.includes.len:
            begin_line(f)
            f.buffer.append("include ")
            unsafe:
                f.buffer.append(read(program.includes.data + i).header)
            end_line(f)
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
    begin_line(f)
    f.buffer.append("const ")
    append_binding_name(f, c.name, c.linkage_name)
    f.buffer.append(": ")
    render_type(f, c.ty)
    f.buffer.append(" = ")
    render_expr(f, c.value, 0)
    end_line(f)


function emit_global(f: ref[Formatter], g: ir.Global) -> void:
    begin_line(f)
    f.buffer.append("var ")
    append_binding_name(f, g.name, g.linkage_name)
    f.buffer.append(": ")
    render_type(f, g.ty)
    f.buffer.append(" = ")
    render_expr(f, g.value, 0)
    end_line(f)


function emit_opaque(f: ref[Formatter], o: ir.OpaqueDecl) -> void:
    begin_line(f)
    f.buffer.append("opaque ")
    append_binding_name(f, o.name, o.linkage_name)
    end_line(f)


function emit_variant(f: ref[Formatter], v: ir.VariantDecl) -> void:
    begin_line(f)
    f.buffer.append("variant ")
    append_binding_name(f, v.name, v.linkage_name)
    f.buffer.append(":")
    end_line(f)
    f.indent += 1
    var i: ptr_uint = 0
    while i < v.arms.len:
        unsafe:
            let arm = read(v.arms.data + i)
            begin_line(f)
            append_binding_name(f, arm.name, arm.linkage_name)
            if arm.fields.len > 0:
                f.buffer.append("(")
                append_field_list(f, arm.fields)
                f.buffer.append(")")
            end_line(f)
        i += 1
    f.indent -= 1


function append_field_list(f: ref[Formatter], fields: span[ir.Field]) -> void:
    var i: ptr_uint = 0
    while i < fields.len:
        if i > 0:
            f.buffer.append(", ")
        unsafe:
            let fld = read(fields.data + i)
            f.buffer.append(fld.name)
            f.buffer.append(": ")
            render_type(f, fld.ty)
        i += 1


function emit_struct(f: ref[Formatter], s: ir.StructDecl) -> void:
    begin_line(f)
    f.buffer.append("struct ")
    append_binding_name(f, s.name, s.linkage_name)
    var any_mod = false
    if s.packed or s.alignment != 0:
        f.buffer.append(" [")
        if s.packed:
            f.buffer.append("packed")
            any_mod = true
        if s.alignment != 0:
            if any_mod:
                f.buffer.append(", ")
            f.buffer.append("align(")
            fmt.append_long(ref_of(f.buffer), long<-(s.alignment))
            f.buffer.append(")")
        f.buffer.append("]")
    f.buffer.append(":")
    end_line(f)
    f.indent += 1
    var i: ptr_uint = 0
    while i < s.fields.len:
        unsafe:
            let fld = read(s.fields.data + i)
            begin_line(f)
            f.buffer.append(fld.name)
            f.buffer.append(": ")
            render_type(f, fld.ty)
            end_line(f)
        i += 1
    f.indent -= 1


function emit_union(f: ref[Formatter], u: ir.UnionDecl) -> void:
    begin_line(f)
    f.buffer.append("union ")
    append_binding_name(f, u.name, u.linkage_name)
    f.buffer.append(":")
    end_line(f)
    f.indent += 1
    var i: ptr_uint = 0
    while i < u.fields.len:
        unsafe:
            let fld = read(u.fields.data + i)
            begin_line(f)
            f.buffer.append(fld.name)
            f.buffer.append(": ")
            render_type(f, fld.ty)
            end_line(f)
        i += 1
    f.indent -= 1


function emit_enum(f: ref[Formatter], e: ir.EnumDecl) -> void:
    begin_line(f)
    if e.is_flags:
        f.buffer.append("flags")
    else:
        f.buffer.append("enum")
    f.buffer.append(" ")
    append_binding_name(f, e.name, e.linkage_name)
    f.buffer.append(": ")
    render_type(f, e.backing_type)
    end_line(f)
    f.indent += 1
    var i: ptr_uint = 0
    while i < e.members.len:
        unsafe:
            let m = read(e.members.data + i)
            begin_line(f)
            append_binding_name(f, m.name, m.linkage_name)
            f.buffer.append(" = ")
            render_expr(f, m.value, 0)
            end_line(f)
        i += 1
    f.indent -= 1


function emit_static_assert(f: ref[Formatter], condition: ptr[ir.Expr], message: ptr[ir.Expr]) -> void:
    begin_line(f)
    f.buffer.append("static_assert(")
    render_expr(f, condition, 0)
    f.buffer.append(", ")
    render_expr(f, message, 0)
    f.buffer.append(")")
    end_line(f)


function emit_function(f: ref[Formatter], func: ir.Function) -> void:
    begin_line(f)
    f.buffer.append("fn ")
    if func.name.len == 0:
        append_binding_name(f, func.linkage_name, func.linkage_name)
    else:
        append_binding_name(f, func.name, func.linkage_name)
    f.buffer.append("(")
    append_param_list(f, func.params)
    f.buffer.append(") -> ")
    render_type(f, func.return_type)
    if func.entry_point:
        f.buffer.append(" [entry]")
    f.buffer.append(":")
    end_line(f)
    f.indent += 1
    emit_stmt_body(f, func.body)
    f.indent -= 1


function append_param_list(f: ref[Formatter], params: span[ir.Param]) -> void:
    var i: ptr_uint = 0
    while i < params.len:
        if i > 0:
            f.buffer.append(", ")
        unsafe:
            append_param(f, read(params.data + i))
        i += 1


function append_param(f: ref[Formatter], p: ir.Param) -> void:
    append_binding_name(f, p.name, p.linkage_name)
    f.buffer.append(": ")
    if p.pointer.unwrap_or(false):
        f.buffer.append("ptr[")
        render_type(f, p.ty)
        f.buffer.append("]")
        return
    render_type(f, p.ty)

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
                begin_line(f)
                f.buffer.append("let ")
                append_binding_name(f, s.name, s.linkage_name)
                f.buffer.append(": ")
                render_type(f, s.ty)
                f.buffer.append(" = ")
                render_expr(f, s.value, 0)
                end_line(f)
            ir.Stmt.stmt_assignment as s:
                begin_line(f)
                render_expr(f, s.target, 0)
                f.buffer.append(" ")
                f.buffer.append(s.operator)
                f.buffer.append(" ")
                render_expr(f, s.value, 0)
                end_line(f)
            ir.Stmt.stmt_block as s:
                begin_line(f)
                f.buffer.append("block:")
                end_line(f)
                f.indent += 1
                emit_stmt_body(f, s.body)
                f.indent -= 1
            ir.Stmt.stmt_if as s:
                begin_line(f)
                f.buffer.append("if ")
                render_expr(f, s.condition, 0)
                f.buffer.append(":")
                end_line(f)
                f.indent += 1
                emit_stmt_body(f, s.then_body)
                f.indent -= 1
                match s.else_body:
                    Option.some as eb:
                        if eb.value.len > 0:
                            begin_line(f)
                            f.buffer.append("else:")
                            end_line(f)
                            f.indent += 1
                            emit_stmt_body(f, eb.value)
                            f.indent -= 1
                    Option.none:
                        pass
            ir.Stmt.stmt_switch as s:
                begin_line(f)
                f.buffer.append("switch ")
                render_expr(f, s.expression, 0)
                f.buffer.append(":")
                end_line(f)
                f.indent += 1
                var ci: ptr_uint = 0
                while ci < s.cases.len:
                    let sc = read(s.cases.data + ci)
                    begin_line(f)
                    if sc.is_default:
                        f.buffer.append("default:")
                    else:
                        let value = sc.value else:
                            fatal(c"ir_formatter: non-default switch case missing value")
                        f.buffer.append("case ")
                        render_expr(f, value, 0)
                        f.buffer.append(":")
                    end_line(f)
                    f.indent += 1
                    emit_stmt_body(f, sc.body)
                    f.indent -= 1
                    ci += 1
                f.indent -= 1
            ir.Stmt.stmt_while as s:
                begin_line(f)
                f.buffer.append("while ")
                render_expr(f, s.condition, 0)
                f.buffer.append(":")
                end_line(f)
                f.indent += 1
                emit_stmt_body(f, s.body)
                f.indent -= 1
            ir.Stmt.stmt_for as s:
                begin_line(f)
                f.buffer.append("for ")
                render_for_clause(f, s.init)
                f.buffer.append("; ")
                render_expr(f, s.condition, 0)
                f.buffer.append("; ")
                render_for_clause(f, s.post)
                f.buffer.append(":")
                end_line(f)
                f.indent += 1
                emit_stmt_body(f, s.body)
                f.indent -= 1
            ir.Stmt.stmt_break:
                begin_line(f)
                f.buffer.append("break")
                end_line(f)
            ir.Stmt.stmt_continue:
                begin_line(f)
                f.buffer.append("continue")
                end_line(f)
            ir.Stmt.stmt_goto as s:
                begin_line(f)
                f.buffer.append("goto ")
                f.buffer.append(s.label)
                end_line(f)
            ir.Stmt.stmt_label as s:
                begin_line(f)
                f.buffer.append("label ")
                f.buffer.append(s.name)
                end_line(f)
            ir.Stmt.stmt_static_assert as s:
                emit_static_assert(f, s.condition, s.message)
            ir.Stmt.stmt_return as s:
                begin_line(f)
                f.buffer.append("return")
                let value = s.value else:
                    end_line(f)
                    return
                f.buffer.append(" ")
                render_expr(f, value, 0)
                end_line(f)
            ir.Stmt.stmt_expression as s:
                begin_line(f)
                render_expr(f, s.expression, 0)
                end_line(f)


function render_for_clause(f: ref[Formatter], sp: ptr[ir.Stmt]) -> void:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_local as s:
                f.buffer.append(s.linkage_name)
                f.buffer.append(": ")
                render_type(f, s.ty)
                f.buffer.append(" = ")
                render_expr(f, s.value, 0)
            ir.Stmt.stmt_assignment as s:
                render_expr(f, s.target, 0)
                f.buffer.append(" ")
                f.buffer.append(s.operator)
                f.buffer.append(" ")
                render_expr(f, s.value, 0)
            ir.Stmt.stmt_expression as s:
                render_expr(f, s.expression, 0)
            _:
                pass

# =============================================================================
#  Expressions
# =============================================================================

function render_args(f: ref[Formatter], items: span[ir.Expr]) -> void:
    var i: ptr_uint = 0
    while i < items.len:
        if i > 0:
            f.buffer.append(", ")
        unsafe:
            render_expr(f, items.data + i, 0)
        i += 1


function render_agg_fields(f: ref[Formatter], fields: span[ir.AggregateField]) -> void:
    var i: ptr_uint = 0
    while i < fields.len:
        if i > 0:
            f.buffer.append(", ")
        unsafe:
            let fld = read(fields.data + i)
            f.buffer.append(fld.name)
            f.buffer.append(" = ")
            render_expr(f, fld.value, 0)
        i += 1


function postfix_expr(ep: ptr[ir.Expr]) -> bool:
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


function render_postfix(f: ref[Formatter], ep: ptr[ir.Expr]) -> void:
    if postfix_expr(ep):
        render_expr(f, ep, POSTFIX_PRECEDENCE)
        return
    f.buffer.append("(")
    render_expr(f, ep, 0)
    f.buffer.append(")")


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
                return unsafe: read(e.payload).ty
            ir.Expr.expr_sizeof as e:
                return e.ty
            ir.Expr.expr_alignof as e:
                return e.ty
            ir.Expr.expr_offsetof as e:
                return e.ty
            ir.Expr.expr_integer_literal as e:
                return e.ty
            ir.Expr.expr_unsigned_integer_literal as e:
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
            ir.Expr.expr_stmt_expr as e:
                return e.ty
            ir.Expr.expr_simd_lane_with as e:
                return e.ty
            ir.Expr.expr_assignment as e:
                return expr_type(e.value)


function pointer_receiver(ep: ptr[ir.Expr]) -> bool:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as n:
                if n.pointer.unwrap_or(false):
                    return true
                return is_ptr_type(n.ty)
            _:
                return is_ptr_type(expr_type(ep))


## Append `ep` to the output, parenthesised when it binds looser than
## `parent_precedence`.  Every arm writes its pieces in rendering order, so the
## text is identical to building the line as one string.
function render_expr(f: ref[Formatter], ep: ptr[ir.Expr], parent_precedence: int) -> void:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as e:
                f.buffer.append(e.name)
            ir.Expr.expr_member as e:
                let opened = open_group(f, parent_precedence, POSTFIX_PRECEDENCE)
                render_postfix(f, e.receiver)
                if pointer_receiver(e.receiver):
                    f.buffer.append("->")
                else:
                    f.buffer.append(".")
                f.buffer.append(e.member)
                close_group(f, opened)
            ir.Expr.expr_index as e:
                let opened = open_group(f, parent_precedence, POSTFIX_PRECEDENCE)
                render_postfix(f, e.receiver)
                f.buffer.append("[")
                render_expr(f, e.index, 0)
                f.buffer.append("]")
                close_group(f, opened)
            ir.Expr.expr_checked_index as e:
                f.buffer.append("checked_index<")
                render_type(f, e.receiver_type)
                f.buffer.append(">(")
                render_expr(f, e.receiver, 0)
                f.buffer.append(", ")
                render_expr(f, e.index, 0)
                f.buffer.append(")")
            ir.Expr.expr_checked_span_index as e:
                f.buffer.append("checked_span_index<")
                render_type(f, e.receiver_type)
                f.buffer.append(">(")
                render_expr(f, e.receiver, 0)
                f.buffer.append(", ")
                render_expr(f, e.index, 0)
                f.buffer.append(")")
            ir.Expr.expr_nullable_index as e:
                f.buffer.append("nullable_index<")
                render_type(f, e.receiver_type)
                f.buffer.append(">(")
                render_expr(f, e.receiver, 0)
                f.buffer.append(", ")
                render_expr(f, e.index, 0)
                f.buffer.append(")")
            ir.Expr.expr_nullable_span_index as e:
                f.buffer.append("nullable_span_index<")
                render_type(f, e.receiver_type)
                f.buffer.append(">(")
                render_expr(f, e.receiver, 0)
                f.buffer.append(", ")
                render_expr(f, e.index, 0)
                f.buffer.append(")")
            ir.Expr.expr_call as e:
                let opened = open_group(f, parent_precedence, POSTFIX_PRECEDENCE)
                f.buffer.append(e.callee)
                f.buffer.append("(")
                render_args(f, e.arguments)
                f.buffer.append(")")
                close_group(f, opened)
            ir.Expr.expr_call_indirect as e:
                let opened = open_group(f, parent_precedence, POSTFIX_PRECEDENCE)
                f.buffer.append("indirect(")
                render_expr(f, e.callee, 0)
                f.buffer.append(", ")
                render_args(f, e.arguments)
                f.buffer.append(")")
                close_group(f, opened)
            ir.Expr.expr_unary as e:
                let opened = open_group(f, parent_precedence, UNARY_PRECEDENCE)
                if e.operator == "not":
                    f.buffer.append("not ")
                else:
                    f.buffer.append(e.operator)
                render_expr(f, e.operand, UNARY_PRECEDENCE)
                close_group(f, opened)
            ir.Expr.expr_binary as e:
                let current = precedence(e.operator)
                let opened = open_group(f, parent_precedence, current)
                render_expr(f, e.left, current)
                f.buffer.append(" ")
                f.buffer.append(e.operator)
                f.buffer.append(" ")
                render_expr(f, e.right, current + 1)
                close_group(f, opened)
            ir.Expr.expr_conditional as e:
                let opened = open_group(f, parent_precedence, IF_EXPRESSION_PRECEDENCE)
                f.buffer.append("if ")
                render_expr(f, e.condition, IF_EXPRESSION_PRECEDENCE)
                f.buffer.append(": ")
                render_expr(f, e.then_expression, IF_EXPRESSION_PRECEDENCE)
                f.buffer.append(" else: ")
                render_expr(f, e.else_expression, IF_EXPRESSION_PRECEDENCE)
                close_group(f, opened)
            ir.Expr.expr_reinterpret as e:
                let rp = unsafe: read(e.payload)
                f.buffer.append("reinterpret[")
                render_type(f, rp.target_type)
                f.buffer.append(" <- ")
                render_type(f, rp.source_type)
                f.buffer.append("](")
                render_expr(f, rp.expression, 0)
                f.buffer.append(")")
            ir.Expr.expr_sizeof as e:
                f.buffer.append("size_of(")
                render_type(f, e.target_type)
                f.buffer.append(")")
            ir.Expr.expr_alignof as e:
                f.buffer.append("align_of(")
                render_type(f, e.target_type)
                f.buffer.append(")")
            ir.Expr.expr_offsetof as e:
                f.buffer.append("offset_of(")
                render_type(f, e.target_type)
                f.buffer.append(", ")
                f.buffer.append(e.field)
                f.buffer.append(")")
            ir.Expr.expr_integer_literal as e:
                fmt.append_long(ref_of(f.buffer), e.value)
            ir.Expr.expr_unsigned_integer_literal as e:
                # A lexeme-derived value too large for a signed `long` renders in
                # the unsigned domain, as the host does (`18446744073709551615`,
                # not `-1`).
                fmt.append_ptr_uint(ref_of(f.buffer), e.value)
            ir.Expr.expr_float_literal as e:
                # Ruby's `Float#to_s`: the shortest decimal that round-trips,
                # not `sprintf("%g")`'s six significant digits.
                f.buffer.append(float_text.double_to_str(e.value))
            ir.Expr.expr_string_literal as e:
                if e.cstring:
                    f.buffer.append("c")
                append_inspect(f, e.value)
            ir.Expr.expr_boolean_literal as e:
                if e.value:
                    f.buffer.append("true")
                else:
                    f.buffer.append("false")
            ir.Expr.expr_null_literal:
                f.buffer.append("null")
            ir.Expr.expr_zero_init as e:
                f.buffer.append("zero[")
                render_type(f, e.ty)
                f.buffer.append("]")
            ir.Expr.expr_address_of as e:
                let opened = open_group(f, parent_precedence, UNARY_PRECEDENCE)
                f.buffer.append("&")
                render_expr(f, e.expression, UNARY_PRECEDENCE)
                close_group(f, opened)
            ir.Expr.expr_cast as e:
                render_type(f, e.target_type)
                f.buffer.append("<-")
                render_expr(f, e.expression, 0)
            ir.Expr.expr_aggregate_literal as e:
                render_type(f, e.ty)
                f.buffer.append("(")
                render_agg_fields(f, e.fields)
                f.buffer.append(")")
            ir.Expr.expr_variant_literal as e:
                render_type(f, e.ty)
                f.buffer.append(".")
                f.buffer.append(e.arm_name)
                if e.fields.len > 0:
                    f.buffer.append("(")
                    render_agg_fields(f, e.fields)
                    f.buffer.append(")")
            ir.Expr.expr_array_literal as e:
                render_type(f, e.ty)
                f.buffer.append("(")
                render_args(f, e.elements)
                f.buffer.append(")")
            ir.Expr.expr_stmt_expr as e:
                f.buffer.append("stmt_expr(")
                render_expr(f, e.result, 0)
                f.buffer.append(")")
            ir.Expr.expr_simd_lane_with as e:
                render_expr(f, e.src, 0)
                f.buffer.append(".with(")
                render_expr(f, e.index, 0)
                f.buffer.append(", ")
                render_expr(f, e.value, 0)
                f.buffer.append(")")
            ir.Expr.expr_assignment as e:
                render_expr(f, e.target, 0)
                f.buffer.append(" ")
                f.buffer.append(e.operator)
                f.buffer.append(" ")
                render_expr(f, e.value, 0)
