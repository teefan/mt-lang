## S-expression dumper for `--sexpr` diagnostic output.  Mirrors Ruby's
## SexprDumper (lib/milk_tea/tooling/sexpr_dumper.rb): a dynamic value model
## rendered with the same atoms, escaping, float formatting, and node/field
## layout, plus explicit serializers for tokens, the AST, and the IR.

import std.fmt as fmt
import std.map as map_mod
import std.str
import std.string as string
import std.vec as vec

import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk
import mtc.parser.ast as ast
import mtc.parser.literal_parsing as lparse
import mtc.ir as ir
import mtc.semantic.types as types
import mtc.c_naming as naming


## Two-string concatenation helper.
function j2(a: str, b: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    return buf.as_str()


## A field of an `sv_node` (`:name value`).
public struct SexprField:
    name: str
    value: SexprValue


## A dynamic S-expression value so serializers can build a tree and one
## renderer formats it exactly like the Ruby dumper.
public variant SexprValue:
    sv_nil
    sv_bool(value: bool)
    sv_int(value: long)
    sv_float(value: double)
    sv_str(value: str)
    sv_sym(value: str)
    sv_list(items: span[SexprValue])
    sv_node(name: str, fields: span[SexprField])


# =============================================================================
#  Atom helpers
# =============================================================================

## Append a quoted, escaped string (Ruby `emit_string`).  Note: Ruby's
## `gsub("\\", "\\\\")` is a no-op (the replacement `\\` is interpreted as an
## escaped backslash), so backslashes are left untouched — only quotes and
## control characters are escaped.
public function append_quoted(buf: ref[string.String], value: str) -> void:
    buf.push_byte('"')
    var i: ptr_uint = 0
    while i < value.len:
        let b = value.byte_at(i)
        if b == 34:
            buf.append("\\\"")
        else if b == 10:
            buf.append("\\n")
        else if b == 9:
            buf.append("\\t")
        else if b == 13:
            buf.append("\\r")
        else:
            buf.push_byte(b)
        i += 1
    buf.push_byte('"')


## Append a `%g` float with Ruby's `format_float` fallback (`.0` when the
## rendering has no `.` or `e`).
public function append_float_atom(buf: ref[string.String], value: double) -> void:
    var tmp = string.String.create()
    defer: tmp.release()
    fmt.append_double(ref_of(tmp), value)
    let text = tmp.as_str()
    buf.append(text)
    if not text.contains_substring(".") and not text.contains_substring("e"):
        buf.append(".0")


## Append a symbol atom: `:name` with underscores rendered as dashes.
public function append_symbol_atom(buf: ref[string.String], name: str) -> void:
    buf.push_byte(':')
    var i: ptr_uint = 0
    while i < name.len:
        let b = name.byte_at(i)
        if b == 95:
            buf.push_byte('-')
        else:
            buf.push_byte(b)
        i += 1


## Render a value tree (Ruby `emit_value`).
public function render_value(buf: ref[string.String], value: SexprValue) -> void:
    match value:
        SexprValue.sv_nil:
            buf.append("nil")
        SexprValue.sv_bool as b:
            if b.value:
                buf.append("true")
            else:
                buf.append("false")
        SexprValue.sv_int as i:
            fmt.append_long(buf, i.value)
        SexprValue.sv_float as f:
            append_float_atom(buf, f.value)
        SexprValue.sv_str as s:
            append_quoted(buf, s.value)
        SexprValue.sv_sym as sym:
            append_symbol_atom(buf, sym.value)
        SexprValue.sv_list as list:
            buf.push_byte('(')
            var li: ptr_uint = 0
            while li < list.items.len:
                if li > 0:
                    buf.push_byte(' ')
                render_value(buf, unsafe: read(list.items.data + li))
                li += 1
            buf.push_byte(')')
        SexprValue.sv_node as node:
            buf.push_byte('(')
            buf.append(node.name)
            var fi: ptr_uint = 0
            while fi < node.fields.len:
                var f: SexprField
                unsafe:
                    f = read(node.fields.data + fi)
                buf.push_byte(' ')
                buf.push_byte(':')
                buf.append(f.name)
                buf.push_byte(' ')
                render_value(buf, f.value)
                fi += 1
            buf.push_byte(')')


## A single-element span of values.
public function sexpr_list1(a: SexprValue) -> span[SexprValue]:
    var v = vec.Vec[SexprValue].create()
    v.push(a)
    return v.as_span()


## A single-element span of fields.
function fields1(f: SexprField) -> span[SexprField]:
    var v = vec.Vec[SexprField].create()
    v.push(f)
    return v.as_span()


# =============================================================================
#  Tokens
# =============================================================================

## The host lexer's token type symbol for a self-hosted token kind
## (`float_literal` -> `float`, keywords drop the `tk_` prefix).  Rendered with
## underscores converted to dashes by the symbol atom.
function token_kind_symbol(kind: tk.TokenKind) -> str:
    return token_mod.kind_name(kind)


## The `:literal` value of a token: integers/strings/chars decode, floats emit
## the raw lexeme (Ruby special-cases float), true/false are bools, everything
## else is nil.
function token_literal_value(token: token_mod.Token, lexeme: str) -> SexprValue:
    match token.kind:
        tk.TokenKind.integer:
            return SexprValue.sv_int(value = lparse.parse_int_literal(lexeme))
        tk.TokenKind.float_literal:
            # Ruby appends the lexeme raw for floats; represent it as a symbol
            # so the renderer emits it unquoted.
            return SexprValue.sv_sym(value = lexeme)
        tk.TokenKind.string:
            return SexprValue.sv_str(value = lparse.parse_string_content(lexeme, false))
        tk.TokenKind.cstring:
            return SexprValue.sv_str(value = lparse.parse_string_content(lexeme, true))
        tk.TokenKind.char_literal:
            return SexprValue.sv_int(value = long<-lparse.parse_char_value(lexeme))
        tk.TokenKind.tk_true:
            return SexprValue.sv_bool(value = true)
        tk.TokenKind.tk_false:
            return SexprValue.sv_bool(value = false)
        _:
            return SexprValue.sv_nil


## `(token :type :<type> :lexeme "<text>" :literal <value> :line N :column N
##  :start_offset N :end_offset N)`.
function render_token(buf: ref[string.String], token: token_mod.Token, source: str) -> void:
    let lexeme = token_mod.token_lexeme(token, source)
    buf.append("(token :type ")
    append_symbol_atom(buf, token_kind_symbol(token.kind))
    buf.append(" :lexeme ")
    append_quoted(buf, lexeme)
    buf.append(" :literal ")
    # Floats render their raw lexeme; other literals go through the value
    # renderer.
    match token_literal_value(token, lexeme):
        SexprValue.sv_sym as raw:
            buf.append(raw.value)
        SexprValue.sv_nil:
            buf.append("nil")
        SexprValue.sv_bool as b:
            if b.value:
                buf.append("true")
            else:
                buf.append("false")
        SexprValue.sv_int as i:
            fmt.append_long(buf, i.value)
        SexprValue.sv_str as s:
            append_quoted(buf, s.value)
        _:
            buf.append("nil")
    buf.append(" :line ")
    fmt.append_ptr_uint(buf, token.line)
    buf.append(" :column ")
    fmt.append_ptr_uint(buf, token.column)
    buf.append(" :start_offset ")
    fmt.append_ptr_uint(buf, token.start_offset)
    buf.append(" :end_offset ")
    fmt.append_ptr_uint(buf, token.end_offset)
    buf.push_byte(')')


## Dump a token stream as `(token ... token ...)` (Ruby `dump_tokens`).
public function dump_tokens(tokens: span[token_mod.Token], source: str) -> string.String:
    var buf = string.String.create()
    buf.push_byte('(')
    var i: ptr_uint = 0
    while i < tokens.len:
        if i > 0:
            buf.push_byte(' ')
        render_token(ref_of(buf), unsafe: read(tokens.data + i), source)
        i += 1
    buf.push_byte(')')
    return buf


# =============================================================================
#  IR
# =============================================================================

## Serialization context: the root module name (for generic-type fallback) and
## the declared type names (so named types classify as Struct/Union/Enum/Variant
## like the host's type classes).
public struct SexprCtx:
    module_name: str
    struct_names: map_mod.Map[str, bool]
    union_names: map_mod.Map[str, bool]
    enum_names: map_mod.Map[str, bool]
    variant_names: map_mod.Map[str, bool]


public function new_sexpr_ctx(module_name: str) -> SexprCtx:
    return SexprCtx(
        module_name = module_name,
        struct_names = map_mod.Map[str, bool].create(),
        union_names = map_mod.Map[str, bool].create(),
        enum_names = map_mod.Map[str, bool].create(),
        variant_names = map_mod.Map[str, bool].create(),
    )


function field_str(name: str, value: str) -> SexprField:
    return SexprField(name = name, value = SexprValue.sv_str(value = value))


function field_sym(name: str, value: str) -> SexprField:
    return SexprField(name = name, value = SexprValue.sv_sym(value = value))


function field_int(name: str, value: long) -> SexprField:
    return SexprField(name = name, value = SexprValue.sv_int(value = value))


function field_uint(name: str, value: ptr_uint) -> SexprField:
    return SexprField(name = name, value = SexprValue.sv_int(value = long<-value))


function field_bool(name: str, value: bool) -> SexprField:
    return SexprField(name = name, value = SexprValue.sv_bool(value = value))


function field_nil(name: str) -> SexprField:
    return SexprField(name = name, value = SexprValue.sv_nil)


function field_value(name: str, value: SexprValue) -> SexprField:
    return SexprField(name = name, value = value)


function node(name: str, fields: span[SexprField]) -> SexprValue:
    return SexprValue.sv_node(name = name, fields = fields)


function list_value(items: span[SexprValue]) -> SexprValue:
    return SexprValue.sv_list(items = items)


## Optional string: host nil when absent.
function field_opt_str(name: str, value: Option[str]) -> SexprField:
    match value:
        Option.some as v:
            return field_str(name, v.value)
        Option.none:
            return field_nil(name)


## Optional expression: host nil when absent.
function field_opt_expr(ctx: ref[SexprCtx], name: str, value: ptr[ir.Expr]?) -> SexprField:
    if value == null:
        return field_nil(name)
    return field_value(name, ir_expr_value(ctx, ptr[ir.Expr]<-value))


## Optional int with 0 meaning "none" (struct alignment).
function field_zero_nil_int(name: str, value: int) -> SexprField:
    if value == 0:
        return field_nil(name)
    return field_int(name, long<-value)


## Source line/path: host nil when the node is synthetic (line 0, empty path).
function field_line(line: ptr_uint) -> SexprField:
    if line == 0:
        return field_nil("line")
    return field_uint("line", line)


function field_path(path: str) -> SexprField:
    if path.len == 0:
        return field_nil("path")
    return field_str("path", path)


# =============================================================================
#  Types
# =============================================================================

## Host Types class for a named/imported type, classified by the IR program's
## declarations (Struct/Union/Enum/Variant), defaulting to Struct.
function named_type_class(ctx: ref[SexprCtx], name: str) -> str:
    if ctx.variant_names.contains(name):
        return "Variant"
    if ctx.enum_names.contains(name):
        return "Enum"
    if ctx.union_names.contains(name):
        return "Union"
    return "Struct"


function types_list_value(ctx: ref[SexprCtx], items: span[types.Type]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        items_out.push(types_value(ctx, unsafe: read(items.data + i)))
        i += 1
    return list_value(items_out.as_span())


function types_value(ctx: ref[SexprCtx], t: types.Type) -> SexprValue:
    match t:
        types.Type.ty_primitive as p:
            return node("Types::Primitive", fields1(field_str("name", p.name)))
        types.Type.ty_str:
            return node("Types::StringView", span[SexprField]())
        types.Type.ty_error:
            return node("Types::Error", span[SexprField]())
        types.Type.ty_type_meta:
            return node("Types::TypeType", span[SexprField]())
        types.Type.ty_nullable as nl:
            var nl_fields = vec.Vec[SexprField].create()
            nl_fields.push(field_value("base", types_value(ctx, unsafe: read(nl.base))))
            return node("Types::Nullable", nl_fields.as_span())
        types.Type.ty_named as n:
            var nf = vec.Vec[SexprField].create()
            nf.push(field_str("name", n.name))
            nf.push(field_str("module_name", n.module_name))
            return node(j2("Types::", named_type_class(ctx, n.name)), nf.as_span())
        types.Type.ty_imported as im:
            var imf = vec.Vec[SexprField].create()
            imf.push(field_str("name", im.name))
            imf.push(field_str("module_name", im.module_name))
            if im.args.len > 0:
                imf.push(field_value("arguments", types_list_value(ctx, im.args)))
                let cls = if im.name == "Option" or im.name == "Result": "VariantInstance" else: "StructInstance"
                return node(j2("Types::", cls), imf.as_span())
            return node(j2("Types::", named_type_class(ctx, im.name)), imf.as_span())
        types.Type.ty_generic as g:
            if g.name == "Option" or g.name == "Result":
                var vf = vec.Vec[SexprField].create()
                vf.push(field_str("name", g.name))
                vf.push(field_str("module_name", if g.name == "Option": "std.option" else: "std.result"))
                vf.push(field_value("arguments", types_list_value(ctx, g.args)))
                return node("Types::VariantInstance", vf.as_span())
            if is_builtin_generic_name(g.name):
                var gf = vec.Vec[SexprField].create()
                gf.push(field_str("name", g.name))
                gf.push(field_value("arguments", types_list_value(ctx, g.args)))
                return node("Types::Generic", gf.as_span())
            var sf = vec.Vec[SexprField].create()
            sf.push(field_str("name", g.name))
            sf.push(field_str("module_name", ctx.module_name))
            sf.push(field_value("arguments", types_list_value(ctx, g.args)))
            return node("Types::StructInstance", sf.as_span())
        types.Type.ty_function as fnt:
            if fnt.is_proc:
                var pf = vec.Vec[SexprField].create()
                pf.push(field_value("params", types_list_value(ctx, fnt.params)))
                pf.push(field_value("return_type", types_value(ctx, unsafe: read(fnt.return_type))))
                return node("Types::Proc", pf.as_span())
            var ff = vec.Vec[SexprField].create()
            ff.push(field_nil("name"))
            ff.push(field_value("params", types_list_value(ctx, fnt.params)))
            ff.push(field_value("return_type", types_value(ctx, unsafe: read(fnt.return_type))))
            ff.push(field_nil("receiver_type"))
            ff.push(field_nil("receiver_editable"))
            ff.push(field_bool("variadic", fnt.variadic))
            ff.push(field_bool("external", false))
            return node("Types::Function", ff.as_span())
        types.Type.ty_tuple as tup:
            var tf = vec.Vec[SexprField].create()
            tf.push(field_value("element_types", types_list_value(ctx, tup.elements)))
            match tup.field_names:
                Option.some as names:
                    var nv = vec.Vec[SexprValue].create()
                    var ni: ptr_uint = 0
                    while ni < names.value.len:
                        nv.push(SexprValue.sv_str(value = unsafe: read(names.value.data + ni)))
                        ni += 1
                    tf.push(field_value("field_names", list_value(nv.as_span())))
                Option.none:
                    tf.push(field_nil("field_names"))
            return node("Types::Tuple", tf.as_span())
        types.Type.ty_literal_int as lit:
            return node("Types::LiteralTypeArg", fields1(field_int("value", lit.value)))
        types.Type.ty_var as v:
            return node("Types::TypeVar", fields1(field_str("name", v.name)))
        types.Type.ty_opaque as op:
            var of = vec.Vec[SexprField].create()
            of.push(field_str("name", op.name))
            of.push(field_str("module_name", op.module_name))
            return node("Types::Opaque", of.as_span())
        types.Type.ty_dyn as d:
            var df = vec.Vec[SexprField].create()
            df.push(field_str("interface_name", d.iface))
            df.push(field_value("type_arguments", list_value(span[SexprValue]())))
            return node("Types::Dyn", df.as_span())
        _:
            return node("Types::Error", span[SexprField]())
    return node("Types::Error", span[SexprField]())


## Builtin generic constructors rendered as `Types::Generic`.
function is_builtin_generic_name(name: str) -> bool:
    return (
        name == "ptr" or name == "const_ptr" or name == "own" or name == "ref"
        or name == "span" or name == "array" or name == "str_buffer"
        or name == "atomic" or name == "Task" or name == "SoA" or name == "simd"
    )


# =============================================================================
#  IR expressions
# =============================================================================

function ir_exprs_value(ctx: ref[SexprCtx], items: span[ir.Expr]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        items_out.push(ir_expr_value(ctx, unsafe: items.data + i))
        i += 1
    return list_value(items_out.as_span())


function ir_aggregate_fields_value(ctx: ref[SexprCtx], items: span[ir.AggregateField]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        var f: ir.AggregateField
        unsafe:
            f = read(items.data + i)
        var ff = vec.Vec[SexprField].create()
        ff.push(field_str("name", f.name))
        ff.push(field_value("value", ir_expr_value(ctx, f.value)))
        items_out.push(node("IR::AggregateField", ff.as_span()))
        i += 1
    return list_value(items_out.as_span())


function ir_expr_value(ctx: ref[SexprCtx], ep: ptr[ir.Expr]) -> SexprValue:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_str("name", x.name))
                f.push(field_value("type", types_value(ctx, x.ty)))
                f.push(field_bool("pointer", x.pointer))
                return node("IR::Name", f.as_span())
            ir.Expr.expr_member as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("receiver", ir_expr_value(ctx, x.receiver)))
                f.push(field_str("member", x.member))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::Member", f.as_span())
            ir.Expr.expr_index as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("receiver", ir_expr_value(ctx, x.receiver)))
                f.push(field_value("index", ir_expr_value(ctx, x.index)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::Index", f.as_span())
            ir.Expr.expr_checked_index as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("receiver", ir_expr_value(ctx, x.receiver)))
                f.push(field_value("index", ir_expr_value(ctx, x.index)))
                f.push(field_value("receiver_type", types_value(ctx, x.receiver_type)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::CheckedIndex", f.as_span())
            ir.Expr.expr_checked_span_index as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("receiver", ir_expr_value(ctx, x.receiver)))
                f.push(field_value("index", ir_expr_value(ctx, x.index)))
                f.push(field_value("receiver_type", types_value(ctx, x.receiver_type)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::CheckedSpanIndex", f.as_span())
            ir.Expr.expr_nullable_index as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("receiver", ir_expr_value(ctx, x.receiver)))
                f.push(field_value("index", ir_expr_value(ctx, x.index)))
                f.push(field_value("receiver_type", types_value(ctx, x.receiver_type)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::NullableIndex", f.as_span())
            ir.Expr.expr_nullable_span_index as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("receiver", ir_expr_value(ctx, x.receiver)))
                f.push(field_value("index", ir_expr_value(ctx, x.index)))
                f.push(field_value("receiver_type", types_value(ctx, x.receiver_type)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::NullableSpanIndex", f.as_span())
            ir.Expr.expr_call as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_str("callee", x.callee))
                f.push(field_value("arguments", ir_exprs_value(ctx, x.arguments)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::Call", f.as_span())
            ir.Expr.expr_call_indirect as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("callee", ir_expr_value(ctx, x.callee)))
                f.push(field_value("arguments", ir_exprs_value(ctx, x.arguments)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::Call", f.as_span())
            ir.Expr.expr_unary as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_str("operator", x.operator))
                f.push(field_value("operand", ir_expr_value(ctx, x.operand)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::Unary", f.as_span())
            ir.Expr.expr_binary as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_str("operator", x.operator))
                f.push(field_value("left", ir_expr_value(ctx, x.left)))
                f.push(field_value("right", ir_expr_value(ctx, x.right)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::Binary", f.as_span())
            ir.Expr.expr_conditional as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("condition", ir_expr_value(ctx, x.condition)))
                f.push(field_value("then_expression", ir_expr_value(ctx, x.then_expression)))
                f.push(field_value("else_expression", ir_expr_value(ctx, x.else_expression)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::Conditional", f.as_span())
            ir.Expr.expr_reinterpret as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("target_type", types_value(ctx, x.target_type)))
                f.push(field_value("source_type", types_value(ctx, x.source_type)))
                f.push(field_value("expression", ir_expr_value(ctx, x.expression)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::ReinterpretExpr", f.as_span())
            ir.Expr.expr_sizeof as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("target_type", types_value(ctx, x.target_type)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::SizeofExpr", f.as_span())
            ir.Expr.expr_alignof as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("target_type", types_value(ctx, x.target_type)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::AlignofExpr", f.as_span())
            ir.Expr.expr_offsetof as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("target_type", types_value(ctx, x.target_type)))
                f.push(field_str("field", x.field))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::OffsetofExpr", f.as_span())
            ir.Expr.expr_integer_literal as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_int("value", x.value))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::IntegerLiteral", f.as_span())
            ir.Expr.expr_float_literal as x:
                var f = vec.Vec[SexprField].create()
                f.push(SexprField(name = "value", value = SexprValue.sv_float(value = x.value)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::FloatLiteral", f.as_span())
            ir.Expr.expr_string_literal as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_str("value", x.value))
                f.push(field_value("type", types_value(ctx, x.ty)))
                f.push(field_bool("cstring", x.cstring))
                return node("IR::StringLiteral", f.as_span())
            ir.Expr.expr_boolean_literal as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_bool("value", x.value))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::BooleanLiteral", f.as_span())
            ir.Expr.expr_null_literal as x:
                return node("IR::NullLiteral", fields1(field_value("type", types_value(ctx, x.ty))))
            ir.Expr.expr_zero_init as x:
                return node("IR::ZeroInit", fields1(field_value("type", types_value(ctx, x.ty))))
            ir.Expr.expr_address_of as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("expression", ir_expr_value(ctx, x.expression)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::AddressOf", f.as_span())
            ir.Expr.expr_cast as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("target_type", types_value(ctx, x.target_type)))
                f.push(field_value("expression", ir_expr_value(ctx, x.expression)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::Cast", f.as_span())
            ir.Expr.expr_aggregate_literal as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("type", types_value(ctx, x.ty)))
                f.push(field_value("fields", ir_aggregate_fields_value(ctx, x.fields)))
                return node("IR::AggregateLiteral", f.as_span())
            ir.Expr.expr_variant_literal as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("type", types_value(ctx, x.ty)))
                f.push(field_str("arm_name", x.arm_name))
                f.push(field_value("fields", ir_aggregate_fields_value(ctx, x.fields)))
                return node("IR::VariantLiteral", f.as_span())
            ir.Expr.expr_array_literal as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("type", types_value(ctx, x.ty)))
                f.push(field_value("elements", ir_exprs_value(ctx, x.elements)))
                return node("IR::ArrayLiteral", f.as_span())
            ir.Expr.expr_stmt_expr as x:
                # No host counterpart (the host lowers this differently); emit a
                # best-effort node so the dump stays well-formed.
                var f = vec.Vec[SexprField].create()
                f.push(field_value("setup", ir_stmts_value(ctx, x.setup)))
                f.push(field_value("result", ir_expr_value(ctx, x.result)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::StmtExpr", f.as_span())
    return node("IR::ErrorExpr", span[SexprField]())


# =============================================================================
#  IR statements
# =============================================================================

function ir_stmts_value(ctx: ref[SexprCtx], body: span[ir.Stmt]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < body.len:
        items_out.push(ir_stmt_value(ctx, unsafe: body.data + i))
        i += 1
    return list_value(items_out.as_span())


function ir_stmt_value(ctx: ref[SexprCtx], sp: ptr[ir.Stmt]) -> SexprValue:
    unsafe:
        match read(sp):
            ir.Stmt.stmt_local as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_str("name", x.name))
                f.push(field_str("linkage_name", x.linkage_name))
                f.push(field_value("type", types_value(ctx, x.ty)))
                f.push(field_value("value", ir_expr_value(ctx, x.value)))
                f.push(field_line(x.line))
                f.push(field_path(x.source_path))
                return node("IR::LocalDecl", f.as_span())
            ir.Stmt.stmt_assignment as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("target", ir_expr_value(ctx, x.target)))
                f.push(field_str("operator", x.operator))
                f.push(field_value("value", ir_expr_value(ctx, x.value)))
                return node("IR::Assignment", f.as_span())
            ir.Stmt.stmt_block as x:
                return node("IR::BlockStmt", fields1(field_value("body", ir_stmts_value(ctx, x.body))))
            ir.Stmt.stmt_if as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("condition", ir_expr_value(ctx, x.condition)))
                f.push(field_value("then_body", ir_stmts_value(ctx, x.then_body)))
                f.push(field_value("else_body", ir_stmts_value(ctx, x.else_body)))
                return node("IR::IfStmt", f.as_span())
            ir.Stmt.stmt_switch as x:
                var cases = vec.Vec[SexprValue].create()
                var ci: ptr_uint = 0
                while ci < x.cases.len:
                    var sc: ir.SwitchCase
                    sc = read(x.cases.data + ci)
                    if sc.is_default:
                        cases.push(node("IR::SwitchDefaultCase", fields1(field_value("body", ir_stmts_value(ctx, sc.body)))))
                    else:
                        var cf = vec.Vec[SexprField].create()
                        cf.push(field_opt_expr(ctx, "value", sc.value))
                        cf.push(field_value("body", ir_stmts_value(ctx, sc.body)))
                        cases.push(node("IR::SwitchCase", cf.as_span()))
                    ci += 1
                var f = vec.Vec[SexprField].create()
                f.push(field_value("expression", ir_expr_value(ctx, x.expression)))
                f.push(field_value("cases", list_value(cases.as_span())))
                f.push(field_bool("exhaustive", x.exhaustive))
                return node("IR::SwitchStmt", f.as_span())
            ir.Stmt.stmt_while as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("condition", ir_expr_value(ctx, x.condition)))
                f.push(field_value("body", ir_stmts_value(ctx, x.body)))
                return node("IR::WhileStmt", f.as_span())
            ir.Stmt.stmt_for as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("init", ir_stmt_value(ctx, x.init)))
                f.push(field_value("condition", ir_expr_value(ctx, x.condition)))
                f.push(field_value("post", ir_stmt_value(ctx, x.post)))
                f.push(field_value("body", ir_stmts_value(ctx, x.body)))
                return node("IR::ForStmt", f.as_span())
            ir.Stmt.stmt_break:
                return node("IR::BreakStmt", span[SexprField]())
            ir.Stmt.stmt_continue:
                return node("IR::ContinueStmt", span[SexprField]())
            ir.Stmt.stmt_goto as x:
                return node("IR::GotoStmt", fields1(field_str("label", x.label)))
            ir.Stmt.stmt_label as x:
                return node("IR::LabelStmt", fields1(field_str("name", x.name)))
            ir.Stmt.stmt_static_assert as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("condition", ir_expr_value(ctx, x.condition)))
                f.push(field_value("message", ir_expr_value(ctx, x.message)))
                return node("IR::StaticAssert", f.as_span())
            ir.Stmt.stmt_return as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_opt_expr(ctx, "value", x.value))
                f.push(field_line(x.line))
                f.push(field_path(x.source_path))
                return node("IR::ReturnStmt", f.as_span())
            ir.Stmt.stmt_expression as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("expression", ir_expr_value(ctx, x.expression)))
                f.push(field_line(x.line))
                f.push(field_path(x.source_path))
                return node("IR::ExpressionStmt", f.as_span())
    return node("IR::BreakStmt", span[SexprField]())


# =============================================================================
#  IR declarations + program
# =============================================================================

function ir_fields_value(ctx: ref[SexprCtx], fields: span[ir.Field]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < fields.len:
        var f: ir.Field
        unsafe:
            f = read(fields.data + i)
        var ff = vec.Vec[SexprField].create()
        ff.push(field_str("name", f.name))
        ff.push(field_value("type", types_value(ctx, f.ty)))
        items_out.push(node("IR::Field", ff.as_span()))
        i += 1
    return list_value(items_out.as_span())


function ir_params_value(ctx: ref[SexprCtx], params: span[ir.Param]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < params.len:
        var p: ir.Param
        unsafe:
            p = read(params.data + i)
        var pf = vec.Vec[SexprField].create()
        pf.push(field_str("name", p.name))
        pf.push(field_str("linkage_name", p.linkage_name))
        pf.push(field_value("type", types_value(ctx, p.ty)))
        pf.push(field_bool("pointer", p.pointer))
        items_out.push(node("IR::Param", pf.as_span()))
        i += 1
    return list_value(items_out.as_span())


public function dump_ir(program: ir.Program) -> string.String:
    var ctx = new_sexpr_ctx(program.module_name)
    var si: ptr_uint = 0
    while si < program.structs.len:
        ctx.struct_names.set(unsafe: read(program.structs.data + si).name, true)
        si += 1
    var ui: ptr_uint = 0
    while ui < program.unions.len:
        ctx.union_names.set(unsafe: read(program.unions.data + ui).name, true)
        ui += 1
    var ei: ptr_uint = 0
    while ei < program.enums.len:
        ctx.enum_names.set(unsafe: read(program.enums.data + ei).name, true)
        ei += 1
    var vi: ptr_uint = 0
    while vi < program.variants.len:
        ctx.variant_names.set(unsafe: read(program.variants.data + vi).name, true)
        vi += 1

    var fields = vec.Vec[SexprField].create()
    fields.push(field_str("module_name", program.module_name))

    var includes = vec.Vec[SexprValue].create()
    var ii: ptr_uint = 0
    while ii < program.includes.len:
        includes.push(node("IR::Include", fields1(field_str("header", unsafe: read(program.includes.data + ii).header))))
        ii += 1
    fields.push(field_value("includes", list_value(includes.as_span())))

    var constants = vec.Vec[SexprValue].create()
    var ci: ptr_uint = 0
    while ci < program.constants.len:
        var c: ir.Constant
        unsafe:
            c = read(program.constants.data + ci)
        var cf = vec.Vec[SexprField].create()
        cf.push(field_str("name", c.name))
        cf.push(field_str("linkage_name", c.linkage_name))
        cf.push(field_value("type", types_value(ref_of(ctx), c.ty)))
        cf.push(field_value("value", ir_expr_value(ref_of(ctx), c.value)))
        cf.push(field_line(c.line))
        cf.push(field_path(c.path))
        constants.push(node("IR::Constant", cf.as_span()))
        ci += 1
    fields.push(field_value("constants", list_value(constants.as_span())))

    var globals = vec.Vec[SexprValue].create()
    var gi: ptr_uint = 0
    while gi < program.globals.len:
        var g: ir.Global
        unsafe:
            g = read(program.globals.data + gi)
        var gf = vec.Vec[SexprField].create()
        gf.push(field_str("name", g.name))
        gf.push(field_str("linkage_name", g.linkage_name))
        gf.push(field_value("type", types_value(ref_of(ctx), g.ty)))
        gf.push(field_value("value", ir_expr_value(ref_of(ctx), g.value)))
        globals.push(node("IR::Global", gf.as_span()))
        gi += 1
    fields.push(field_value("globals", list_value(globals.as_span())))

    var opaques = vec.Vec[SexprValue].create()
    var oi: ptr_uint = 0
    while oi < program.opaques.len:
        var o: ir.OpaqueDecl
        unsafe:
            o = read(program.opaques.data + oi)
        var of = vec.Vec[SexprField].create()
        of.push(field_str("name", o.name))
        of.push(field_str("linkage_name", o.linkage_name))
        of.push(field_bool("forward_declarable", o.forward_declarable))
        of.push(field_opt_str("source_module", o.source_module))
        opaques.push(node("IR::OpaqueDecl", of.as_span()))
        oi += 1
    fields.push(field_value("opaques", list_value(opaques.as_span())))

    var structs = vec.Vec[SexprValue].create()
    var sti: ptr_uint = 0
    while sti < program.structs.len:
        var s: ir.StructDecl
        unsafe:
            s = read(program.structs.data + sti)
        var sf = vec.Vec[SexprField].create()
        sf.push(field_str("name", s.name))
        sf.push(field_str("linkage_name", s.linkage_name))
        sf.push(field_value("fields", ir_fields_value(ref_of(ctx), s.fields)))
        sf.push(field_bool("packed", s.packed))
        sf.push(field_zero_nil_int("alignment", s.alignment))
        sf.push(field_opt_str("source_module", s.source_module))
        structs.push(node("IR::StructDecl", sf.as_span()))
        sti += 1
    fields.push(field_value("structs", list_value(structs.as_span())))

    var unions = vec.Vec[SexprValue].create()
    var uni: ptr_uint = 0
    while uni < program.unions.len:
        var u: ir.UnionDecl
        unsafe:
            u = read(program.unions.data + uni)
        var uf = vec.Vec[SexprField].create()
        uf.push(field_str("name", u.name))
        uf.push(field_str("linkage_name", u.linkage_name))
        uf.push(field_value("fields", ir_fields_value(ref_of(ctx), u.fields)))
        uf.push(field_opt_str("source_module", u.source_module))
        unions.push(node("IR::UnionDecl", uf.as_span()))
        uni += 1
    fields.push(field_value("unions", list_value(unions.as_span())))

    var enums = vec.Vec[SexprValue].create()
    var eni: ptr_uint = 0
    while eni < program.enums.len:
        var en: ir.EnumDecl
        unsafe:
            en = read(program.enums.data + eni)
        var members = vec.Vec[SexprValue].create()
        var mi: ptr_uint = 0
        while mi < en.members.len:
            var m: ir.EnumMember
            unsafe:
                m = read(en.members.data + mi)
            var mf = vec.Vec[SexprField].create()
            mf.push(field_str("name", m.name))
            mf.push(field_str("linkage_name", m.linkage_name))
            mf.push(field_value("value", ir_expr_value(ref_of(ctx), m.value)))
            members.push(node("IR::EnumMember", mf.as_span()))
            mi += 1
        var ef = vec.Vec[SexprField].create()
        ef.push(field_str("name", en.name))
        ef.push(field_str("linkage_name", en.linkage_name))
        ef.push(field_value("backing_type", types_value(ref_of(ctx), en.backing_type)))
        ef.push(field_value("members", list_value(members.as_span())))
        ef.push(field_bool("flags", en.is_flags))
        enums.push(node("IR::EnumDecl", ef.as_span()))
        eni += 1
    fields.push(field_value("enums", list_value(enums.as_span())))

    var variants = vec.Vec[SexprValue].create()
    var vai: ptr_uint = 0
    while vai < program.variants.len:
        var vd: ir.VariantDecl
        unsafe:
            vd = read(program.variants.data + vai)
        var arms = vec.Vec[SexprValue].create()
        var ai: ptr_uint = 0
        while ai < vd.arms.len:
            var a: ir.VariantArm
            unsafe:
                a = read(vd.arms.data + ai)
            var af = vec.Vec[SexprField].create()
            af.push(field_str("name", a.name))
            af.push(field_str("linkage_name", a.linkage_name))
            af.push(field_value("fields", ir_fields_value(ref_of(ctx), a.fields)))
            arms.push(node("IR::VariantArm", af.as_span()))
            ai += 1
        var vf = vec.Vec[SexprField].create()
        vf.push(field_str("name", vd.name))
        vf.push(field_str("linkage_name", vd.linkage_name))
        vf.push(field_value("arms", list_value(arms.as_span())))
        vf.push(field_opt_str("source_module", vd.source_module))
        variants.push(node("IR::VariantDecl", vf.as_span()))
        vai += 1
    fields.push(field_value("variants", list_value(variants.as_span())))

    var asserts = vec.Vec[SexprValue].create()
    var sai: ptr_uint = 0
    while sai < program.static_asserts.len:
        var sa: ir.StaticAssert
        unsafe:
            sa = read(program.static_asserts.data + sai)
        var saf = vec.Vec[SexprField].create()
        saf.push(field_value("condition", ir_expr_value(ref_of(ctx), sa.condition)))
        saf.push(field_value("message", ir_expr_value(ref_of(ctx), sa.message)))
        asserts.push(node("IR::StaticAssert", saf.as_span()))
        sai += 1
    fields.push(field_value("static_asserts", list_value(asserts.as_span())))

    var functions = vec.Vec[SexprValue].create()
    var fi: ptr_uint = 0
    while fi < program.functions.len:
        var func: ir.Function
        unsafe:
            func = read(program.functions.data + fi)
        var fnf = vec.Vec[SexprField].create()
        fnf.push(field_str("name", func.name))
        fnf.push(field_str("linkage_name", func.linkage_name))
        fnf.push(field_value("params", ir_params_value(ref_of(ctx), func.params)))
        fnf.push(field_value("return_type", types_value(ref_of(ctx), func.return_type)))
        fnf.push(field_value("body", ir_stmts_value(ref_of(ctx), func.body)))
        fnf.push(field_bool("entry_point", func.entry_point))
        fnf.push(field_bool("method_receiver_param", func.method_receiver_param))
        functions.push(node("IR::Function", fnf.as_span()))
        fi += 1
    fields.push(field_value("functions", list_value(functions.as_span())))

    fields.push(field_str("path", program.source_path))

    var buf = string.String.create()
    render_value(ref_of(buf), node("IR::Program", fields.as_span()))
    return buf
