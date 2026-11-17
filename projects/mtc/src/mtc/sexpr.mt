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
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.c_naming as naming
import mtc.strings


## Two-string concatenation helper.
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
    ## An unsigned integer atom.  The host renders a Ruby Integer, which for
    ## values >= 2^63 (e.g. `18446744073709551615`) is a positive number that
    ## does not fit a signed `long`.
    sv_uint(value: ptr_uint)
    sv_float(value: double)
    sv_str(value: str)
    sv_sym(value: str)
    sv_list(items: span[SexprValue])
    sv_node(name: str, fields: span[SexprField])
    ## Renders as nothing (host Hash/Set values are elided by the dumper).
    sv_void


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
        SexprValue.sv_uint as u:
            fmt.append_ulong(buf, ulong<-u.value)
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
        SexprValue.sv_void:
            pass
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
            return SexprValue.sv_uint(value = lparse.parse_int_literal_unsigned(lexeme))
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
        tk.TokenKind.fstring:
            return fstring_literal_value(lexeme)
        _:
            return SexprValue.sv_nil


## The host lexer stores an fstring token's literal as an array of part Hashes,
## which the dumper elides (printing only the separators).  Reproduce the
## observable shape by counting parts the same way the host splits them:
## non-empty text runs plus one entry per interpolation.
function fstring_literal_value(lexeme: str) -> SexprValue:
    let count = format_part_count(lexeme)
    var items = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < count:
        items.push(SexprValue.sv_void)
        i += 1
    return list_value(items.as_span())


function format_part_count(lexeme: str) -> ptr_uint:
    var content: str = ""
    if lexeme.len >= 4 and lexeme.byte_at(0) == 'f' and lexeme.byte_at(1) == '<' and lexeme.byte_at(2) == '<' and lexeme.byte_at(3) == '-':
        content = lparse.normalize_format_heredoc(lexeme)
    else if lexeme.len >= 3 and lexeme.byte_at(0) == 'f' and lexeme.byte_at(1) == '"':
        content = lexeme.slice(2, lexeme.len - 3)
    else:
        return 0

    var count: ptr_uint = 0
    var text_len: ptr_uint = 0
    var i: ptr_uint = 0
    while i < content.len:
        let b = content.byte_at(i)
        if b == '#' and i + 1 < content.len and content.byte_at(i + 1) == '{':
            if text_len > 0:
                count += 1
                text_len = 0
            var depth: int = 1
            var j = i + 2
            while j < content.len and depth > 0:
                let c = content.byte_at(j)
                if c == '"':
                    j += 1
                    while j < content.len and content.byte_at(j) != '"':
                        if content.byte_at(j) == '\\':
                            j += 1
                        j += 1
                    j += 1
                else if c == '{':
                    depth += 1
                    j += 1
                else if c == '}':
                    depth -= 1
                    j += 1
                else:
                    j += 1
            count += 1
            i = j
        else if b == '\\' and i + 1 < content.len:
            text_len += 1
            i += 2
        else:
            text_len += 1
            i += 1
    if text_len > 0:
        count += 1
    return count


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
    let literal = token_literal_value(token, lexeme)
    match literal:
        SexprValue.sv_sym as raw:
            buf.append(raw.value)
        _:
            render_value(buf, literal)
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
## the declared type names (so named types classify as Struct/Union/Enum/Flags/
## Variant like the host's type classes).  `type_kinds` additionally maps a
## *module-qualified* declared name (`raw.Color`) to its class, which the
## per-module analyses supply — an imported type whose declaration is not in the
## IR (a raw module's enum/flags/union/variant/opaque) still classifies right.
public struct SexprContext:
    module_name: str
    struct_names: map_mod.Map[str, bool]
    union_names: map_mod.Map[str, bool]
    enum_names: map_mod.Map[str, bool]
    flags_names: map_mod.Map[str, bool]
    variant_names: map_mod.Map[str, bool]
    type_kinds: map_mod.Map[str, str]


public function create_sexpr_context(module_name: str) -> SexprContext:
    return SexprContext(
        module_name = module_name,
        struct_names = map_mod.Map[str, bool].create(),
        union_names = map_mod.Map[str, bool].create(),
        enum_names = map_mod.Map[str, bool].create(),
        flags_names = map_mod.Map[str, bool].create(),
        variant_names = map_mod.Map[str, bool].create(),
        type_kinds = map_mod.Map[str, str].create(),
    )


function field_str(name: str, value: str) -> SexprField:
    return SexprField(name = name, value = SexprValue.sv_str(value = value))


function field_sym(name: str, value: str) -> SexprField:
    return SexprField(name = name, value = SexprValue.sv_sym(value = value))


function field_int(name: str, value: long) -> SexprField:
    return SexprField(name = name, value = SexprValue.sv_int(value = value))


function field_uint(name: str, value: ptr_uint) -> SexprField:
    return SexprField(name = name, value = SexprValue.sv_uint(value = value))


function field_bool(name: str, value: bool) -> SexprField:
    return SexprField(name = name, value = SexprValue.sv_bool(value = value))


## Optional bool: the host renders `nil` when the value was never set (an
## `IR::Param` without an explicit `pointer:`).
function field_optional_bool(name: str, value: Option[bool]) -> SexprField:
    match value:
        Option.some as b:
            return field_bool(name, b.value)
        Option.none:
            return field_nil(name)


function field_nil(name: str) -> SexprField:
    return SexprField(name = name, value = SexprValue.sv_nil)


function field_value(name: str, value: SexprValue) -> SexprField:
    return SexprField(name = name, value = value)


function node(name: str, fields: span[SexprField]) -> SexprValue:
    return SexprValue.sv_node(name = name, fields = fields)


function list_value(items: span[SexprValue]) -> SexprValue:
    return SexprValue.sv_list(items = items)


## A module name: the host's types carry `nil` for a synthetic (module-less)
## type (`<mod>__frame`, `mt_proc_*`, `mt_tuple_*`, …) where the self models the
## absent module as an empty string.
function field_module_name(name: str, value: str) -> SexprField:
    if value.len == 0:
        return field_nil(name)
    return field_str(name, value)


## Optional string: host nil when absent.
function field_opt_str(name: str, value: Option[str]) -> SexprField:
    match value:
        Option.some as v:
            return field_str(name, v.value)
        Option.none:
            return field_nil(name)


## Optional expression: host nil when absent.
function field_opt_expr(ctx: ref[SexprContext], name: str, value: ptr[ir.Expr]?) -> SexprField:
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
function named_type_class(ctx: ref[SexprContext], name: str) -> str:
    if ctx.variant_names.contains(name):
        return "Variant"
    if ctx.flags_names.contains(name):
        return "Flags"
    if ctx.enum_names.contains(name):
        return "Enum"
    if ctx.union_names.contains(name):
        return "Union"
    return "Struct"


## The host's class for an imported nominal type: the module-qualified kind the
## loaded modules' analyses registered (`raw.Color` → `Enum`), else the bare
## declared-name sets, else `Struct`.  The qualified lookup is what makes a raw
## (`external`) module's enum/flags/opaque render their own class — the IR holds
## no declaration for them (session 43, item 3g).
function imported_type_class(ctx: ref[SexprContext], module_name: str, name: str) -> str:
    let kind = ctx.type_kinds.get(strings.join_two(module_name, strings.join_two(".", name)))
    if kind != null:
        return unsafe: read(kind)
    return named_type_class(ctx, name)


## Render a function/proc parameter list as the host's `Types::Parameter` nodes
## (`:name`, `:type`); `names` may be shorter than `params` for synthetic types.
function param_list_value(ctx: ref[SexprContext], params: span[types.Type], names: span[str]) -> SexprValue:
    var items = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < params.len:
        var name = ""
        if i < names.len:
            name = unsafe: read(names.data + i)
        var pf = vec.Vec[SexprField].create()
        pf.push(field_str("name", name))
        pf.push(field_value("type", types_value(ctx, unsafe: read(params.data + i))))
        pf.push(field_bool("mutable", false))
        pf.push(field_value("passing_mode", SexprValue.sv_sym(value = "plain")))
        pf.push(field_nil("boundary_type"))
        items.push(node("Types::Parameter", pf.as_span()))
        i += 1
    return list_value(items.as_span())


function types_list_value(ctx: ref[SexprContext], items: span[types.Type]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        items_out.push(types_value(ctx, unsafe: read(items.data + i)))
        i += 1
    return list_value(items_out.as_span())


## The host stores an SoA count / simd lane count as a plain Integer, not a
## `Types::LiteralTypeArg`; the dump emits a bare number, falling back to the
## regular type rendering for a non-literal (a bound parameter mid-analysis).
function int_arg_field(ctx: ref[SexprContext], name: str, t: types.Type) -> SexprField:
    match t:
        types.Type.ty_literal_int as lit:
            return field_int(name, lit.value)
        _:
            return field_value(name, types_value(ctx, t))


function types_value(ctx: ref[SexprContext], t: types.Type) -> SexprValue:
    match t:
        types.Type.ty_primitive as p:
            # The host installs the builtin vector/matrix/quaternion names as
            # their own type classes (`Types::Vector`/`Matrix`/`Quaternion`,
            # `type_declaration.rb:54-71`); the self keeps them as primitives
            # (arithmetic, fields and the C backend special-case the names), so
            # the dump classifies them here.  Each renders only `:name`.
            if p.name == "vec2" or p.name == "vec3" or p.name == "vec4" or p.name == "ivec2" or p.name == "ivec3" or p.name == "ivec4":
                return node("Types::Vector", fields1(field_str("name", p.name)))
            if p.name == "mat3" or p.name == "mat4":
                return node("Types::Matrix", fields1(field_str("name", p.name)))
            if p.name == "quat":
                return node("Types::Quaternion", fields1(field_str("name", p.name)))
            return node("Types::Primitive", fields1(field_str("name", p.name)))
        types.Type.ty_str:
            return node("Types::StringView", span[SexprField]())
        types.Type.ty_error:
            return node("Types::Error", span[SexprField]())
        types.Type.ty_nil:
            return SexprValue.sv_nil
        types.Type.ty_type_meta:
            return node("Types::TypeType", span[SexprField]())
        types.Type.ty_handle:
            return node("Types::Handle", span[SexprField]())
        types.Type.ty_nullable as nl:
            var nl_fields = vec.Vec[SexprField].create()
            nl_fields.push(field_value("base", types_value(ctx, unsafe: read(nl.base))))
            return node("Types::Nullable", nl_fields.as_span())
        types.Type.ty_null as nt:
            var nt_fields = vec.Vec[SexprField].create()
            let target = nt.target
            if target == null:
                nt_fields.push(field_nil("target_type"))
            else:
                nt_fields.push(field_value("target_type", types_value(ctx, unsafe: read(target))))
            return node("Types::Null", nt_fields.as_span())
        types.Type.ty_event as ev:
            var ev_fields = vec.Vec[SexprField].create()
            ev_fields.push(field_str("name", ev.name))
            ev_fields.push(field_int("capacity", long<-ev.capacity))
            let ev_payload = ev.payload_type
            if ev_payload == null:
                ev_fields.push(field_nil("payload_type"))
            else:
                ev_fields.push(field_value("payload_type", types_value(ctx, unsafe: read(ev_payload))))
            return node("Types::Event", ev_fields.as_span())
        types.Type.ty_named as n:
            # The host's built-in event support types are their own classes: the
            # `Subscription` handle renders as `(Types::Subscription)` and
            # `EventError` as the builtin enum (`type_declaration.rb:38,79`).
            if n.module_name.len == 0 and n.name == "Subscription":
                return node("Types::Subscription", span[SexprField]())
            var nf = vec.Vec[SexprField].create()
            nf.push(field_str("name", n.name))
            nf.push(field_module_name("module_name", n.module_name))
            if n.module_name.len == 0 and n.name == "EventError":
                return node("Types::Enum", nf.as_span())
            # A module-qualified named type classifies through the qualified
            # kind map like an imported one (`std.c.box2d.b2HexColor` is the raw
            # module's enum, and no IR declaration carries it).
            if n.module_name.len > 0:
                return node(strings.join_two("Types::", imported_type_class(ctx, n.module_name, n.name)), nf.as_span())
            return node(strings.join_two("Types::", named_type_class(ctx, n.name)), nf.as_span())
        types.Type.ty_variant_arm_payload as ap:
            # The host tags the payload distinctly but renders its fields through
            # the `Types::Struct` branch (`:name`, `:module_name`).
            var apf = vec.Vec[SexprField].create()
            apf.push(field_str("name", ap.name))
            apf.push(field_module_name("module_name", ap.module_name))
            return node("Types::VariantArmPayload", apf.as_span())
        types.Type.ty_imported as im:
            var imf = vec.Vec[SexprField].create()
            imf.push(field_str("name", im.name))
            imf.push(field_str("module_name", im.module_name))
            # The host dumper matches `Types::Struct`/`Types::Variant` before the
            # instance subclasses, so instance arguments are never printed.
            if im.args.len > 0:
                # The host's instance subclass follows the declaration kind: a
                # generic variant (Option/Result or a user variant such as
                # engine.types.Outcome) is a VariantInstance, a generic struct a
                # StructInstance.
                let kind = imported_type_class(ctx, im.module_name, im.name)
                let cls = if kind == "Variant" or im.name == "Option" or im.name == "Result": "VariantInstance" else: "StructInstance"
                return node(strings.join_two("Types::", cls), imf.as_span())
            return node(strings.join_two("Types::", imported_type_class(ctx, im.module_name, im.name)), imf.as_span())
        types.Type.ty_generic as g:
            if g.name == "Option" or g.name == "Result":
                var vf = vec.Vec[SexprField].create()
                vf.push(field_str("name", g.name))
                vf.push(field_str("module_name", if g.name == "Option": "std.option" else: "std.result"))
                # Instance arguments are not printed (see the ty_imported case).
                return node("Types::VariantInstance", vf.as_span())
            if g.name == "span" and g.args.len == 1:
                var spf = vec.Vec[SexprField].create()
                spf.push(field_value("element_type", types_value(ctx, unsafe: read(g.args.data + 0))))
                return node("Types::Span", spf.as_span())
            if g.name == "Task" and g.args.len == 1:
                var tkf = vec.Vec[SexprField].create()
                tkf.push(field_value("result_type", types_value(ctx, unsafe: read(g.args.data + 0))))
                return node("Types::Task", tkf.as_span())
            if g.name == "SoA" and g.args.len == 2:
                var soaf = vec.Vec[SexprField].create()
                soaf.push(field_value("element_type", types_value(ctx, unsafe: read(g.args.data + 0))))
                soaf.push(int_arg_field(ctx, "count", unsafe: read(g.args.data + 1)))
                return node("Types::SoA", soaf.as_span())
            if g.name == "simd" and g.args.len == 2:
                var simdf = vec.Vec[SexprField].create()
                simdf.push(field_value("element_type", types_value(ctx, unsafe: read(g.args.data + 0))))
                simdf.push(int_arg_field(ctx, "lane_count", unsafe: read(g.args.data + 1)))
                return node("Types::Simd", simdf.as_span())
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
                pf.push(field_value("params", param_list_value(ctx, fnt.params, fnt.param_names)))
                pf.push(field_value("return_type", types_value(ctx, unsafe: read(fnt.return_type))))
                return node("Types::Proc", pf.as_span())
            var ff = vec.Vec[SexprField].create()
            ff.push(field_str("name", fnt.name))
            ff.push(field_value("params", param_list_value(ctx, fnt.params, fnt.param_names)))
            ff.push(field_value("return_type", types_value(ctx, unsafe: read(fnt.return_type))))
            ff.push(field_nil("receiver_type"))
            ff.push(field_bool("receiver_editable", false))
            ff.push(field_bool("variadic", fnt.variadic))
            ff.push(field_bool("external", false))
            return node("Types::Function", ff.as_span())
        types.Type.ty_tuple as tup:
            var tf = vec.Vec[SexprField].create()
            tf.push(field_value("element_types", types_list_value(ctx, tup.elements)))
            var nv = vec.Vec[SexprValue].create()
            match tup.field_names:
                Option.some as names:
                    var ni: ptr_uint = 0
                    while ni < names.value.len:
                        nv.push(SexprValue.sv_str(value = unsafe: read(names.value.data + ni)))
                        ni += 1
                Option.none:
                    # The host's `Types::Tuple#field_names` always carries the
                    # default positional names (`_0`, `_1`, …); the self's
                    # internal model omits them for an anonymous tuple.
                    var di: ptr_uint = 0
                    while di < tup.elements.len:
                        var dname = string.String.create()
                        dname.append("_")
                        fmt.append_ptr_uint(ref_of(dname), di)
                        nv.push(SexprValue.sv_str(value = dname.as_str()))
                        di += 1
            tf.push(field_value("field_names", list_value(nv.as_span())))
            return node("Types::Tuple", tf.as_span())
        types.Type.ty_literal_int as lit:
            return node("Types::LiteralTypeArg", fields1(field_int("value", lit.value)))
        types.Type.ty_var as v:
            return node("Types::TypeVar", fields1(field_str("name", v.name)))
        types.Type.ty_lifetime as lt:
            # The host stores the raw lifetime name as a generic argument and
            # renders it as a bare quoted string, not a tagged node.
            return SexprValue.sv_str(value = lt.name)
        types.Type.ty_opaque as op:
            var of = vec.Vec[SexprField].create()
            of.push(field_str("name", op.name))
            of.push(field_str("module_name", op.module_name))
            return node("Types::Opaque", of.as_span())
        types.Type.ty_dyn as d:
            var df = vec.Vec[SexprField].create()
            df.push(field_str("interface_name", d.iface))
            df.push(field_value("type_arguments", types_list_value(ctx, d.args)))
            return node("Types::Dyn", df.as_span())
        types.Type.ty_dyn_vtable as dv:
            var dvf = vec.Vec[SexprField].create()
            dvf.push(field_str("interface_name", dv.interface_name))
            dvf.push(field_str("linkage_name", dv.linkage_name))
            return node("Types::DynVtable", dvf.as_span())
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

function ir_exprs_value(ctx: ref[SexprContext], items: span[ir.Expr]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        items_out.push(ir_expr_value(ctx, unsafe: items.data + i))
        i += 1
    return list_value(items_out.as_span())


function ir_aggregate_fields_value(ctx: ref[SexprContext], items: span[ir.AggregateField]) -> SexprValue:
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


function ir_expr_value(ctx: ref[SexprContext], ep: ptr[ir.Expr]) -> SexprValue:
    unsafe:
        match read(ep):
            ir.Expr.expr_name as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_str("name", x.name))
                f.push(field_value("type", types_value(ctx, x.ty)))
                f.push(field_optional_bool("pointer", x.pointer))
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
            ir.Expr.expr_unsigned_integer_literal as x:
                # A lexeme-derived value too large for a signed `long` renders in
                # the unsigned domain: the host keeps `18446744073709551615` as a
                # positive value and dumps the same `IR::IntegerLiteral` node.
                var uf = vec.Vec[SexprField].create()
                uf.push(field_uint("value", x.value))
                uf.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::IntegerLiteral", uf.as_span())
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
            ir.Expr.expr_simd_lane_with as x:
                var f = vec.Vec[SexprField].create()
                f.push(field_value("src", ir_expr_value(ctx, x.src)))
                f.push(field_value("index", ir_expr_value(ctx, x.index)))
                f.push(field_value("value", ir_expr_value(ctx, x.value)))
                f.push(field_value("type", types_value(ctx, x.ty)))
                return node("IR::SimdLaneWith", f.as_span())
            ir.Expr.expr_assignment as x:
                # The host's `IR::Assignment` in expression position (wrapped by
                # an `IR::ExpressionStmt`), rendered exactly like the statement.
                var f = vec.Vec[SexprField].create()
                f.push(field_value("target", ir_expr_value(ctx, x.target)))
                f.push(field_str("operator", x.operator))
                f.push(field_value("value", ir_expr_value(ctx, x.value)))
                return node("IR::Assignment", f.as_span())
    return node("IR::ErrorExpr", span[SexprField]())


# =============================================================================
#  IR statements
# =============================================================================

function ir_stmts_value(ctx: ref[SexprContext], body: span[ir.Stmt]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < body.len:
        items_out.push(ir_stmt_value(ctx, unsafe: body.data + i))
        i += 1
    return list_value(items_out.as_span())


function ir_stmt_value(ctx: ref[SexprContext], sp: ptr[ir.Stmt]) -> SexprValue:
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
                match x.else_body:
                    Option.some as eb:
                        f.push(field_value("else_body", ir_stmts_value(ctx, eb.value)))
                    Option.none:
                        f.push(field_nil("else_body"))
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

function ir_fields_value(ctx: ref[SexprContext], fields: span[ir.Field]) -> SexprValue:
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


function ir_params_value(ctx: ref[SexprContext], params: span[ir.Param]) -> SexprValue:
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
        pf.push(field_optional_bool("pointer", p.pointer))
        items_out.push(node("IR::Param", pf.as_span()))
        i += 1
    return list_value(items_out.as_span())


## Register one module's declared types into the context's qualified kind map:
## `<module>.<name>` → the host's class.  A raw (`external`) module carries no
## IR declarations, so this is the only source that can classify its enums,
## flags, unions, variants and opaques (session 43, item 3g).
function register_decl_kinds(ctx: ref[SexprContext], a: analyzer.Analysis) -> void:
    var di: ptr_uint = 0
    while di < a.source_file.declarations.len:
        var d: ast.Decl
        unsafe:
            d = read(a.source_file.declarations.data + di)
        var name = ""
        var kind = ""
        match d:
            ast.Decl.decl_struct as s:
                name = s.name
                kind = "Struct"
            ast.Decl.decl_union as u:
                name = u.name
                kind = "Union"
            ast.Decl.decl_enum as e:
                name = e.name
                kind = "Enum"
            ast.Decl.decl_flags as fl:
                name = fl.name
                kind = "Flags"
            ast.Decl.decl_variant as vr:
                name = vr.name
                kind = "Variant"
            ast.Decl.decl_opaque as op:
                name = op.name
                kind = "Opaque"
            _:
                pass
        if name.len > 0:
            let _prev = ctx.type_kinds.set(strings.join_two(strings.join_two(a.module_name, "."), name), kind)
        di += 1


public function dump_ir(program: ir.Program) -> string.String:
    return dump_ir_with_analyses(program, span[analyzer.Analysis]())


## Dump the IR, consulting the loaded modules' analyses for the *declaration
## kinds* of imported types.  The IR carries no declaration for a raw
## (`external`) module's enum/flags/union/variant/opaque, so without the
## analyses a raw enum renders `Types::Struct` where the host renders
## `Types::Enum`/`Types::Flags`/`Types::Opaque` (session 43, item 3g).
public function dump_ir_with_analyses(program: ir.Program, analyses: span[analyzer.Analysis]) -> string.String:
    var ctx = create_sexpr_context(program.module_name)
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
        # A flags declaration is an IR enum decl with `is_flags`: classify it
        # `Types::Flags` (the host's class), not `Types::Enum`.
        let en = unsafe: read(program.enums.data + ei)
        if en.is_flags:
            ctx.flags_names.set(en.name, true)
        else:
            ctx.enum_names.set(en.name, true)
        ei += 1
    var vi: ptr_uint = 0
    while vi < program.variants.len:
        ctx.variant_names.set(unsafe: read(program.variants.data + vi).name, true)
        vi += 1
    var ai: ptr_uint = 0
    while ai < analyses.len:
        var a: analyzer.Analysis
        unsafe:
            a = read(analyses.data + ai)
        register_decl_kinds(ref_of(ctx), a)
        ai += 1

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


# =============================================================================
#  AST serialisation (host AST::* classes)
# =============================================================================

function fields2(a: SexprField, b: SexprField) -> span[SexprField]:
    var f = vec.Vec[SexprField].create()
    f.push(a)
    f.push(b)
    return f.as_span()


function fields3(a: SexprField, b: SexprField, c: SexprField) -> span[SexprField]:
    var f = vec.Vec[SexprField].create()
    f.push(a)
    f.push(b)
    f.push(c)
    return f.as_span()


function fields4(a: SexprField, b: SexprField, c: SexprField, d: SexprField) -> span[SexprField]:
    var f = vec.Vec[SexprField].create()
    f.push(a)
    f.push(b)
    f.push(c)
    f.push(d)
    return f.as_span()


function fields5(a: SexprField, b: SexprField, c: SexprField, d: SexprField, e: SexprField) -> span[SexprField]:
    var f = vec.Vec[SexprField].create()
    f.push(a)
    f.push(b)
    f.push(c)
    f.push(d)
    f.push(e)
    return f.as_span()


function fields6(a: SexprField, b: SexprField, c: SexprField, d: SexprField, e: SexprField, g: SexprField) -> span[SexprField]:
    var f = vec.Vec[SexprField].create()
    f.push(a)
    f.push(b)
    f.push(c)
    f.push(d)
    f.push(e)
    f.push(g)
    return f.as_span()


function fields7(a: SexprField, b: SexprField, c: SexprField, d: SexprField, e: SexprField, g: SexprField, h: SexprField) -> span[SexprField]:
    var f = vec.Vec[SexprField].create()
    f.push(a)
    f.push(b)
    f.push(c)
    f.push(d)
    f.push(e)
    f.push(g)
    f.push(h)
    return f.as_span()


function fields8(a: SexprField, b: SexprField, c: SexprField, d: SexprField, e: SexprField, g: SexprField, h: SexprField, i: SexprField) -> span[SexprField]:
    var f = vec.Vec[SexprField].create()
    f.push(a)
    f.push(b)
    f.push(c)
    f.push(d)
    f.push(e)
    f.push(g)
    f.push(h)
    f.push(i)
    return f.as_span()


function fields9(a: SexprField, b: SexprField, c: SexprField, d: SexprField, e: SexprField, g: SexprField, h: SexprField, i: SexprField, j: SexprField) -> span[SexprField]:
    var f = vec.Vec[SexprField].create()
    f.push(a)
    f.push(b)
    f.push(c)
    f.push(d)
    f.push(e)
    f.push(g)
    f.push(h)
    f.push(i)
    f.push(j)
    return f.as_span()


function fields10(a: SexprField, b: SexprField, c: SexprField, d: SexprField, e: SexprField, g: SexprField, h: SexprField, i: SexprField, j: SexprField, k: SexprField) -> span[SexprField]:
    var f = vec.Vec[SexprField].create()
    f.push(a)
    f.push(b)
    f.push(c)
    f.push(d)
    f.push(e)
    f.push(g)
    f.push(h)
    f.push(i)
    f.push(j)
    f.push(k)
    return f.as_span()


function fields11(a: SexprField, b: SexprField, c: SexprField, d: SexprField, e: SexprField, g: SexprField, h: SexprField, i: SexprField, j: SexprField, k: SexprField, m: SexprField) -> span[SexprField]:
    var f = vec.Vec[SexprField].create()
    f.push(a)
    f.push(b)
    f.push(c)
    f.push(d)
    f.push(e)
    f.push(g)
    f.push(h)
    f.push(i)
    f.push(j)
    f.push(k)
    f.push(m)
    return f.as_span()


function fields12(a: SexprField, b: SexprField, c: SexprField, d: SexprField, e: SexprField, g: SexprField, h: SexprField, i: SexprField, j: SexprField, k: SexprField, m: SexprField, n: SexprField) -> span[SexprField]:
    var f = vec.Vec[SexprField].create()
    f.push(a)
    f.push(b)
    f.push(c)
    f.push(d)
    f.push(e)
    f.push(g)
    f.push(h)
    f.push(i)
    f.push(j)
    f.push(k)
    f.push(m)
    f.push(n)
    return f.as_span()


function fields13(a: SexprField, b: SexprField, c: SexprField, d: SexprField, e: SexprField, g: SexprField, h: SexprField, i: SexprField, j: SexprField, k: SexprField, m: SexprField, n: SexprField, o: SexprField) -> span[SexprField]:
    var f = vec.Vec[SexprField].create()
    f.push(a)
    f.push(b)
    f.push(c)
    f.push(d)
    f.push(e)
    f.push(g)
    f.push(h)
    f.push(i)
    f.push(j)
    f.push(k)
    f.push(m)
    f.push(n)
    f.push(o)
    return f.as_span()


function fields14(a: SexprField, b: SexprField, c: SexprField, d: SexprField, e: SexprField, g: SexprField, h: SexprField, i: SexprField, j: SexprField, k: SexprField, m: SexprField, n: SexprField, o: SexprField, q: SexprField) -> span[SexprField]:
    var f = vec.Vec[SexprField].create()
    f.push(a)
    f.push(b)
    f.push(c)
    f.push(d)
    f.push(e)
    f.push(g)
    f.push(h)
    f.push(i)
    f.push(j)
    f.push(k)
    f.push(m)
    f.push(n)
    f.push(o)
    f.push(q)
    return f.as_span()


function len_field(name: str, length: ptr_uint) -> SexprField:
    if length == 0:
        return field_nil(name)
    return field_uint(name, length)


function opt_type_ref_field(ctx: ref[SexprContext], name: str, value: ptr[ast.TypeRef]?) -> SexprField:
    if value == null:
        return field_nil(name)
    return field_value(name, type_ref_value(ctx, unsafe: read(ptr[ast.TypeRef]<-value)))


function visibility_symbol(visibility: bool) -> str:
    if visibility:
        return "public"
    return "private"


function ast_kind_symbol(is_let: bool) -> str:
    if is_let:
        return "let"
    return "var"


function method_kind_symbol(kind: ast.MethodKind) -> str:
    match kind:
        ast.MethodKind.mk_editable:
            return "editable"
        ast.MethodKind.mk_static:
            return "static"
        _:
            return "plain"
    return "plain"


function foreign_mode_symbol(mode: ast.ForeignParamMode) -> str:
    match mode:
        ast.ForeignParamMode.fmode_out:
            return "out"
        ast.ForeignParamMode.fmode_in:
            return "in"
        ast.ForeignParamMode.fmode_inout:
            return "inout"
        ast.ForeignParamMode.fmode_consuming:
            return "consuming"
        _:
            return "plain"
    return "plain"


## QualifiedName as the host builds it for `parse_qualified_name` (parts only).
function qname_bare_value(parts: span[str]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < parts.len:
        items_out.push(SexprValue.sv_str(value = unsafe: read(parts.data + i)))
        i += 1
    return node("AST::QualifiedName", fields4(
        field_value("parts", list_value(items_out.as_span())),
        field_value("type_arguments", list_value(span[SexprValue]())),
        field_nil("line"),
        field_nil("column"),
    ))


## QualifiedName as built by `parse_qualified_name_with_type_arguments`.
function qname_full_value(ctx: ref[SexprContext], qn: ast.QualifiedName) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < qn.parts.len:
        items_out.push(SexprValue.sv_str(value = unsafe: read(qn.parts.data + i)))
        i += 1
    var targs = vec.Vec[SexprValue].create()
    var ti: ptr_uint = 0
    while ti < qn.type_arguments.len:
        targs.push(type_ref_value(ctx, unsafe: read(qn.type_arguments.data + ti)))
        ti += 1
    return node("AST::QualifiedName", fields4(
        field_value("parts", list_value(items_out.as_span())),
        field_value("type_arguments", list_value(targs.as_span())),
        field_line(qn.line),
        len_field("column", qn.column),
    ))


function parse_uint_lexeme(text: str) -> long:
    var v: long = 0
    var i: ptr_uint = 0
    while i < text.len:
        let c = text.byte_at(i)
        if c < 48 or c > 57:
            break
        v = v * 10 + long<-(c - 48)
        i += 1
    return v


function lexeme_is_integer(text: str) -> bool:
    if text.len == 0:
        return false
    var i: ptr_uint = 0
    while i < text.len:
        let c = text.byte_at(i)
        if c < 48 or c > 57:
            return false
        i += 1
    return true


function lexeme_is_float(text: str) -> bool:
    if text.len == 0:
        return false
    var seen_dot = false
    var i: ptr_uint = 0
    while i < text.len:
        let c = text.byte_at(i)
        if c == 46:
            seen_dot = true
        else if c < 48 or c > 57:
            return false
        i += 1
    return seen_dot


function parse_float_lexeme(text: str) -> double:
    var int_part: long = 0
    var frac: long = 0
    var scale: long = 1
    var seen_dot = false
    var i: ptr_uint = 0
    while i < text.len:
        let c = text.byte_at(i)
        if c == 46:
            seen_dot = true
        else if c >= 48 and c <= 57:
            if seen_dot:
                frac = frac * 10 + long<-(c - 48)
                scale = scale * 10
            else:
                int_part = int_part * 10 + long<-(c - 48)
        i += 1
    return double<-int_part + double<-frac / double<-scale


## A type argument's value: numeric literals are synthetic single-part
## TypeRefs in the self-hosted AST; the host stores them as literal nodes.
function type_argument_value_of(ctx: ref[SexprContext], tr: ast.TypeRef) -> SexprValue:
    if tr.line == 0 and tr.column == 0 and tr.name.parts.len == 1 and tr.arguments.len == 0 and not tr.nullable and not tr.is_fn and not tr.is_proc and not tr.is_dyn and not tr.is_tuple:
        let lexeme = unsafe: read(tr.name.parts.data + 0)
        if lexeme_is_integer(lexeme):
            return node("AST::IntegerLiteral", fields4(
                field_str("lexeme", lexeme),
                field_int("value", parse_uint_lexeme(lexeme)),
                field_nil("line"),
                field_nil("column"),
            ))
        if lexeme_is_float(lexeme):
            return node("AST::FloatLiteral", fields4(
                field_str("lexeme", lexeme),
                field_value("value", SexprValue.sv_float(value = parse_float_lexeme(lexeme))),
                field_nil("line"),
                field_nil("column"),
            ))
    return type_ref_value(ctx, tr)


function type_argument_value(ctx: ref[SexprContext], ta: ast.TypeArgument) -> SexprValue:
    let tr = unsafe: read(ta.value)
    return node("AST::TypeArgument", fields3(
        field_value("value", type_argument_value_of(ctx, tr)),
        field_nil("line"),
        field_nil("column"),
    ))


function type_ref_value(ctx: ref[SexprContext], tr: ast.TypeRef) -> SexprValue:
    if tr.is_fn or tr.is_proc:
        let class_name = if tr.is_proc: "AST::ProcType" else: "AST::FunctionType"
        return node(class_name, fields4(
            field_value("params", params_value(ctx, tr.fn_params)),
            opt_type_ref_field(ctx, "return_type", tr.fn_return),
            field_nil("line"),
            field_nil("column"),
        ))
    if tr.is_dyn:
        return node("AST::DynType", fields5(
            field_value("interface", qname_full_value(ctx, tr.dyn_interface)),
            field_bool("nullable", tr.nullable),
            field_line(tr.line),
            len_field("column", tr.column),
            field_uint("length", 3),
        ))
    if tr.is_tuple:
        return node("AST::TupleType", fields4(
            field_value("element_types", type_refs_value(ctx, tr.arguments)),
            field_bool("nullable", tr.nullable),
            field_nil("line"),
            field_nil("column"),
        ))
    var first_part = ""
    if tr.name.parts.len > 0:
        first_part = unsafe: read(tr.name.parts.data + 0)
    var lifetime_name = ""
    var has_lifetime = false
    match tr.lifetime:
        Option.some as lt:
            lifetime_name = lt.value
            has_lifetime = true
        Option.none:
            pass
    if has_lifetime and tr.name.parts.len == 0:
        # Bare `@a` type (host: a TypeRef named `@a` with no lifetime field).
        var lt_parts = vec.Vec[str].create()
        lt_parts.push("@" + lifetime_name)
        return node("AST::TypeRef", fields7(
            field_value("name", qname_bare_value(lt_parts.as_span())),
            field_value("arguments", list_value(span[SexprValue]())),
            field_bool("nullable", tr.nullable),
            field_nil("lifetime"),
            field_line(tr.line),
            len_field("column", tr.column),
            len_field("length", tr.length),
        ))
    var lifetime_field = field_nil("lifetime")
    if has_lifetime:
        lifetime_field = field_str("lifetime", "@" + lifetime_name)
    var arguments_field = field_value("arguments", type_refs_as_arguments_value(ctx, tr.arguments))
    if has_lifetime and first_part != "ref":
        # `Foo[@a, ...]`: the host parses `@a` as the first type argument.
        var lt_parts = vec.Vec[str].create()
        lt_parts.push("@" + lifetime_name)
        var args_out = vec.Vec[SexprValue].create()
        args_out.push(node("AST::TypeArgument", fields3(
            field_value("value", node("AST::TypeRef", fields7(
                field_value("name", qname_bare_value(lt_parts.as_span())),
                field_value("arguments", list_value(span[SexprValue]())),
                field_bool("nullable", false),
                field_nil("lifetime"),
                field_line(tr.lifetime_line),
                len_field("column", tr.lifetime_column),
                field_uint("length", lifetime_name.len + 1),
            ))),
            field_nil("line"),
            field_nil("column"),
        )))
        var ai: ptr_uint = 0
        while ai < tr.arguments.len:
            let inner = unsafe: read(tr.arguments.data + ai)
            args_out.push(node("AST::TypeArgument", fields3(
                field_value("value", type_argument_value_of(ctx, inner)),
                field_nil("line"),
                field_nil("column"),
            )))
            ai += 1
        arguments_field = field_value("arguments", list_value(args_out.as_span()))
        lifetime_field = field_nil("lifetime")
    return node("AST::TypeRef", fields7(
        field_value("name", qname_bare_value(tr.name.parts)),
        arguments_field,
        field_bool("nullable", tr.nullable),
        lifetime_field,
        field_line(tr.line),
        len_field("column", tr.column),
        len_field("length", tr.length),
    ))


## TypeRef arguments as the host stores them: each wrapped in `AST::TypeArgument`.
function type_refs_as_arguments_value(ctx: ref[SexprContext], items: span[ast.TypeRef]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        items_out.push(node("AST::TypeArgument", fields3(
            field_value("value", type_argument_value_of(ctx, unsafe: read(items.data + i))),
            field_nil("line"),
            field_nil("column"),
        )))
        i += 1
    return list_value(items_out.as_span())


function type_refs_value(ctx: ref[SexprContext], items: span[ast.TypeRef]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        items_out.push(type_ref_value(ctx, unsafe: read(items.data + i)))
        i += 1
    return list_value(items_out.as_span())


function params_value(ctx: ref[SexprContext], params: span[ast.Param]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < params.len:
        items_out.push(param_value(ctx, unsafe: read(params.data + i)))
        i += 1
    return list_value(items_out.as_span())


function param_default_field(ctx: ref[SexprContext], p: ast.Param) -> SexprField:
    if p.default_value == null:
        return field_nil("default_value")
    return field_value("default_value", expr_value(ctx, unsafe: ptr[ast.Expr]<-p.default_value))


function param_value(ctx: ref[SexprContext], p: ast.Param) -> SexprValue:
    return node("AST::Param", fields5(
        field_str("name", p.name),
        field_value("type", type_ref_value(ctx, p.param_type)),
        field_line(p.line),
        len_field("column", p.column),
        param_default_field(ctx, p),
    ))


function attributes_value(ctx: ref[SexprContext], attrs: span[ast.AttributeApplication]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < attrs.len:
        let a = unsafe: read(attrs.data + i)
        items_out.push(node("AST::AttributeApplication", fields4(
            field_value("name", qname_bare_value(a.name.parts)),
            field_value("arguments", arguments_value(ctx, a.arguments)),
            field_line(a.line),
            len_field("column", a.column),
        )))
        i += 1
    return list_value(items_out.as_span())


function arguments_value(ctx: ref[SexprContext], args: span[ast.Argument]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < args.len:
        let a = unsafe: read(args.data + i)
        items_out.push(node("AST::Argument", fields4(
            field_opt_str("name", a.arg_name),
            field_value("value", expr_value(ctx, a.arg_value)),
            field_nil("line"),
            field_nil("column"),
        )))
        i += 1
    return list_value(items_out.as_span())


function fields_value(ctx: ref[SexprContext], items: span[ast.Field]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        let fd = unsafe: read(items.data + i)
        items_out.push(node("AST::Field", fields5(
            field_str("name", fd.name),
            field_value("type", type_ref_value(ctx, fd.field_type)),
            field_value("attributes", attributes_value(ctx, fd.attributes)),
            field_line(fd.line),
            len_field("column", fd.column),
        )))
        i += 1
    return list_value(items_out.as_span())


function enum_members_value(ctx: ref[SexprContext], items: span[ast.EnumMember]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        let m = unsafe: read(items.data + i)
        var value_field = field_nil("value")
        if m.value != null and m.value_explicit:
            value_field = field_value("value", expr_value(ctx, unsafe: ptr[ast.Expr]<-m.value))
        items_out.push(node("AST::EnumMember", fields4(
            field_str("name", m.name),
            value_field,
            field_line(m.line),
            len_field("column", m.column),
        )))
        i += 1
    return list_value(items_out.as_span())


function variant_fields_value(ctx: ref[SexprContext], items: span[ast.Field]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        let fd = unsafe: read(items.data + i)
        items_out.push(node("AST::Field", fields5(
            field_str("name", fd.name),
            field_value("type", type_ref_value(ctx, fd.field_type)),
            field_value("attributes", attributes_value(ctx, fd.attributes)),
            field_nil("line"),
            field_nil("column"),
        )))
        i += 1
    return list_value(items_out.as_span())


function union_fields_value(ctx: ref[SexprContext], items: span[ast.Field]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        let fd = unsafe: read(items.data + i)
        items_out.push(node("AST::Field", fields5(
            field_str("name", fd.name),
            field_value("type", type_ref_value(ctx, fd.field_type)),
            field_value("attributes", attributes_value(ctx, fd.attributes)),
            field_nil("line"),
            field_nil("column"),
        )))
        i += 1
    return list_value(items_out.as_span())


function sym_list_value(items: span[str]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        items_out.push(SexprValue.sv_sym(value = unsafe: read(items.data + i)))
        i += 1
    return list_value(items_out.as_span())


function variant_arms_value(ctx: ref[SexprContext], items: span[ast.VariantArm]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        let arm = unsafe: read(items.data + i)
        items_out.push(node("AST::VariantArm", fields4(
            field_str("name", arm.name),
            field_value("fields", variant_fields_value(ctx, arm.arm_fields)),
            field_nil("line"),
            field_nil("column"),
        )))
        i += 1
    return list_value(items_out.as_span())


function foreign_params_value(ctx: ref[SexprContext], items: span[ast.ForeignParam]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        let p = unsafe: read(items.data + i)
        var boundary = field_nil("boundary_type")
        match p.boundary_type:
            Option.some as bt:
                boundary = field_value("boundary_type", type_ref_value(ctx, bt.value))
            Option.none:
                pass
        items_out.push(node("AST::ForeignParam", fields6(
            field_str("name", p.name),
            field_value("type", type_ref_value(ctx, p.param_type)),
            field_sym("mode", foreign_mode_symbol(p.param_mode)),
            boundary,
            field_nil("line"),
            field_nil("column"),
        )))
        i += 1
    return list_value(items_out.as_span())


function for_bindings_value(ctx: ref[SexprContext], items: span[ast.ForBinding]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        let b = unsafe: read(items.data + i)
        items_out.push(node("AST::ForBinding", fields3(
            field_str("name", b.name),
            field_line(b.line),
            len_field("column", b.column),
        )))
        i += 1
    return list_value(items_out.as_span())


function constraints_value(ctx: ref[SexprContext], items: span[ast.TypeParamConstraint]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        let c = unsafe: read(items.data + i)
        items_out.push(node("AST::TypeParamConstraint", fields4(
            field_sym("kind", "interface"),
            field_value("interface_ref", qname_full_value(ctx, c.interface_ref)),
            field_nil("line"),
            field_nil("column"),
        )))
        i += 1
    return list_value(items_out.as_span())


function type_params_value(ctx: ref[SexprContext], items: span[ast.TypeParam]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        let p = unsafe: read(items.data + i)
        if p.is_value:
            items_out.push(node("AST::ValueTypeParam", fields5(
                field_str("name", p.name),
                field_value("type", type_ref_value(ctx, unsafe: read(ptr[ast.TypeRef]<-p.value_type))),
                field_line(p.line),
                len_field("column", p.column),
                field_uint("length", p.name.len),
            )))
        else:
            items_out.push(node("AST::TypeParam", fields5(
                field_str("name", p.name),
                field_value("constraints", constraints_value(ctx, p.constraints)),
                field_line(p.line),
                len_field("column", p.column),
                field_uint("length", p.name.len),
            )))
        i += 1
    return list_value(items_out.as_span())


function interface_methods_value(ctx: ref[SexprContext], items: span[ast.InterfaceMethod]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        let m = unsafe: read(items.data + i)
        items_out.push(node("AST::InterfaceMethodDecl", fields8(
            field_str("name", m.name),
            field_value("params", params_value(ctx, m.method_params)),
            opt_type_ref_field(ctx, "return_type", m.return_type),
            field_sym("kind", method_kind_symbol(m.method_kind)),
            field_bool("async", m.is_async),
            field_value("attributes", attributes_value(ctx, m.attributes)),
            field_line(m.line),
            len_field("column", m.column),
        )))
        i += 1
    return list_value(items_out.as_span())


function method_value(ctx: ref[SexprContext], m: ast.Method) -> SexprValue:
    let body_field = field_value("body", stmts_of_ptr(ctx, m.body))
    return node("AST::MethodDef", fields12(
        field_str("name", m.name),
        field_value("type_params", type_params_value(ctx, m.type_params)),
        field_value("params", params_value(ctx, m.method_params)),
        opt_type_ref_field(ctx, "return_type", m.return_type),
        body_field,
        field_sym("kind", method_kind_symbol(m.method_kind)),
        field_sym("visibility", visibility_symbol(m.visibility)),
        field_bool("async", m.is_async),
        field_bool("const", m.is_const),
        field_value("attributes", attributes_value(ctx, m.attributes)),
        field_line(m.line),
        len_field("column", m.column),
    ))


function methods_value(ctx: ref[SexprContext], items: span[ast.Method]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        items_out.push(method_value(ctx, unsafe: read(items.data + i)))
        i += 1
    return list_value(items_out.as_span())


function match_expr_arms_value(ctx: ref[SexprContext], items: span[ast.MatchExprArm]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        let a = unsafe: read(items.data + i)
        var pattern_field = field_nil("pattern")
        var pos = AstPos(line = 0, column = 0)
        if a.pattern != null:
            let pat = unsafe: ptr[ast.Expr]<-a.pattern
            pattern_field = field_value("pattern", expr_value(ctx, pat))
            pos = expr_position(pat)
        else if a.wildcard_line != 0 or a.wildcard_column != 0:
            pattern_field = field_value("pattern", node("AST::Identifier", fields3(
                field_str("name", "_"),
                field_line(a.wildcard_line),
                len_field("column", a.wildcard_column),
            )))
            pos = AstPos(line = a.wildcard_line, column = a.wildcard_column)
        else if a.wildcard_line != 0 or a.wildcard_column != 0:
            pattern_field = field_value("pattern", node("AST::Identifier", fields3(
                field_str("name", "_"),
                field_line(a.wildcard_line),
                len_field("column", a.wildcard_column),
            )))
            pos = AstPos(line = a.wildcard_line, column = a.wildcard_column)
        items_out.push(node("AST::MatchExprArm", fields7(
            pattern_field,
            field_opt_str("binding_name", a.binding_name),
            len_field("binding_line", a.binding_line),
            len_field("binding_column", a.binding_column),
            field_value("value", expr_value(ctx, a.value)),
            field_line(pos.line),
            len_field("column", pos.column),
        )))
        i += 1
    return list_value(items_out.as_span())


function match_arms_value(ctx: ref[SexprContext], items: span[ast.MatchArm]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        let a = unsafe: read(items.data + i)
        var pattern_field = field_nil("pattern")
        var pos = AstPos(line = 0, column = 0)
        if a.pattern != null:
            let pat = unsafe: ptr[ast.Expr]<-a.pattern
            pattern_field = field_value("pattern", expr_value(ctx, pat))
            pos = expr_position(pat)
        else if a.wildcard_line != 0 or a.wildcard_column != 0:
            pattern_field = field_value("pattern", node("AST::Identifier", fields3(
                field_str("name", "_"),
                field_line(a.wildcard_line),
                len_field("column", a.wildcard_column),
            )))
            pos = AstPos(line = a.wildcard_line, column = a.wildcard_column)
        else if a.wildcard_line != 0 or a.wildcard_column != 0:
            pattern_field = field_value("pattern", node("AST::Identifier", fields3(
                field_str("name", "_"),
                field_line(a.wildcard_line),
                len_field("column", a.wildcard_column),
            )))
            pos = AstPos(line = a.wildcard_line, column = a.wildcard_column)
        var body_field = field_nil("body")
        if a.body != null:
            body_field = field_value("body", stmts_of_ptr(ctx, a.body))
        items_out.push(node("AST::MatchArm", fields7(
            pattern_field,
            field_opt_str("binding_name", a.binding_name),
            len_field("binding_line", a.binding_line),
            len_field("binding_column", a.binding_column),
            body_field,
            field_line(pos.line),
            len_field("column", pos.column),
        )))
        i += 1
    return list_value(items_out.as_span())


function when_branches_value(ctx: ref[SexprContext], items: span[ast.WhenBranch]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        let a = unsafe: read(items.data + i)
        let pat = a.pattern
        let pos = expr_position(pat)
        items_out.push(node("AST::MatchArm", fields7(
            field_value("pattern", expr_value(ctx, pat)),
            field_opt_str("binding_name", a.binding_name),
            len_field("binding_line", a.binding_line),
            len_field("binding_column", a.binding_column),
            field_value("body", ast_stmts_list(ctx, a.body)),
            field_line(pos.line),
            len_field("column", pos.column),
        )))
        i += 1
    return list_value(items_out.as_span())


function when_decl_branches_value(ctx: ref[SexprContext], items: span[ast.WhenDeclBranch]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        let a = unsafe: read(items.data + i)
        let pat = a.pattern
        let pos = expr_position(pat)
        items_out.push(node("AST::WhenBranch", fields7(
            field_value("pattern", expr_value(ctx, pat)),
            field_opt_str("binding_name", a.binding_name),
            len_field("binding_line", a.binding_line),
            len_field("binding_column", a.binding_column),
            field_value("body", decls_value(ctx, a.body, false)),
            field_line(pos.line),
            len_field("column", pos.column),
        )))
        i += 1
    return list_value(items_out.as_span())


function if_branches_value(ctx: ref[SexprContext], items: span[ast.IfBranch]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        let b = unsafe: read(items.data + i)
        items_out.push(node("AST::IfBranch", fields5(
            field_value("condition", expr_value(ctx, b.condition)),
            field_value("body", stmts_of_ptr(ctx, b.body)),
            field_line(b.line),
            len_field("column", b.column),
            len_field("length", b.length),
        )))
        i += 1
    return list_value(items_out.as_span())


public struct AstPos:
    line: ptr_uint
    column: ptr_uint


function expr_position(ep: ptr[ast.Expr]) -> AstPos:
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as x:
                return AstPos(line = x.line, column = x.column)
            ast.Expr.expr_char_literal as x:
                return AstPos(line = x.line, column = x.column)
            ast.Expr.expr_null_literal as x:
                return AstPos(line = x.line, column = x.column)
            ast.Expr.expr_member_access as x:
                return AstPos(line = x.line, column = x.column)
            ast.Expr.expr_match as x:
                return AstPos(line = x.line, column = x.column)
            ast.Expr.expr_detach as x:
                return AstPos(line = x.line, column = x.column)
            ast.Expr.expr_expression_list as x:
                return AstPos(line = x.line, column = x.column)
            ast.Expr.expr_range as x:
                return AstPos(line = x.line, column = x.column)
            ast.Expr.expr_prefix_cast as x:
                return AstPos(line = x.line, column = x.column)
            ast.Expr.expr_unsafe as x:
                return AstPos(line = x.line, column = x.column)
            ast.Expr.expr_error as x:
                return AstPos(line = x.line, column = x.column)
            _:
                pass
    return AstPos(line = 0, column = 0)


function format_parts_value(ctx: ref[SexprContext], parts: span[ast.FormatStringPart]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < parts.len:
        var p: ast.FormatStringPart
        unsafe:
            p = read(parts.data + i)
        match p:
            ast.FormatStringPart.fmt_text as t:
                items_out.push(node("AST::FormatTextPart", fields3(
                    field_str("value", t.value),
                    field_nil("line"),
                    field_nil("column"),
                )))
            ast.FormatStringPart.fmt_expr as x:
                if x.format_spec == null:
                    items_out.push(node("AST::FormatExprPart", fields4(
                        field_value("expression", expr_value(ctx, x.expression)),
                        field_nil("format_spec"),
                        field_nil("line"),
                        field_nil("column"),
                    )))
                else:
                    items_out.push(node("AST::FormatExprPart", fields3(
                        field_value("expression", expr_value(ctx, x.expression)),
                        field_nil("line"),
                        field_nil("column"),
                    )))
        i += 1
    return list_value(items_out.as_span())


function expr_value(ctx: ref[SexprContext], ep: ptr[ast.Expr]) -> SexprValue:
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as x:
                return node("AST::Identifier", fields3(
                    field_str("name", x.name),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Expr.expr_integer_literal as x:
                return node("AST::IntegerLiteral", fields4(
                    field_str("lexeme", x.lexeme),
                    field_uint("value", lparse.parse_int_literal_unsigned(x.lexeme)),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_float_literal as x:
                return node("AST::FloatLiteral", fields4(
                    field_str("lexeme", x.lexeme),
                    field_value("value", SexprValue.sv_float(value = x.value)),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_string_literal as x:
                return node("AST::StringLiteral", fields5(
                    field_str("lexeme", x.lexeme),
                    field_str("value", x.value),
                    field_bool("cstring", x.is_cstring),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_char_literal as x:
                return node("AST::CharLiteral", fields4(
                    field_str("lexeme", x.lexeme),
                    field_uint("value", ptr_uint<-x.value),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Expr.expr_bool_literal as x:
                return node("AST::BooleanLiteral", fields3(
                    field_bool("value", x.value),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_null_literal as x:
                return node("AST::NullLiteral", fields3(
                    opt_type_ref_field(ctx, "type", x.target_type),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Expr.expr_format_string as x:
                return node("AST::FormatString", fields3(
                    field_value("parts", format_parts_value(ctx, x.parts)),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_binary_op as x:
                return node("AST::BinaryOp", fields5(
                    field_str("operator", x.operator),
                    field_value("left", expr_value(ctx, x.left)),
                    field_value("right", expr_value(ctx, x.right)),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_unary_op as x:
                return node("AST::UnaryOp", fields4(
                    field_str("operator", x.operator),
                    field_value("operand", expr_value(ctx, x.operand)),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_member_access as x:
                return node("AST::MemberAccess", fields4(
                    field_value("receiver", expr_value(ctx, x.receiver)),
                    field_str("member", x.member_name),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Expr.expr_call as x:
                return node("AST::Call", fields4(
                    field_value("callee", expr_value(ctx, x.callee)),
                    field_value("arguments", arguments_value(ctx, x.args)),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_index_access as x:
                return node("AST::IndexAccess", fields4(
                    field_value("receiver", expr_value(ctx, x.receiver)),
                    field_value("index", expr_value(ctx, x.index)),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_specialization as x:
                return node("AST::Specialization", fields4(
                    field_value("callee", expr_value(ctx, x.callee)),
                    field_value("arguments", type_arguments_value(ctx, x.arguments)),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_if as x:
                return expr_if_value(ctx, x.condition, x.then_expr, x.else_expr)
            ast.Expr.expr_match as x:
                return expr_match_value(ctx, x.scrutinee, x.arms, x.line, x.column, x.length, x.desugared_from_is)
            ast.Expr.expr_proc as x:
                return node("AST::ProcExpr", fields5(
                    field_value("params", params_value(ctx, x.method_params)),
                    opt_type_ref_field(ctx, "return_type", x.return_type),
                    field_value("body", stmts_of_ptr(ctx, x.body)),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_await as x:
                return node("AST::AwaitExpr", fields3(
                    field_value("expression", expr_value(ctx, x.expression)),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_detach as x:
                var stmt_items = vec.Vec[SexprValue].create()
                stmt_items.push(node("AST::ExpressionStmt", fields3(
                    field_value("expression", expr_value(ctx, x.expression)),
                    field_nil("line"),
                    field_nil("column"),
                )))
                return node("AST::DetachExpr", fields3(
                    field_value("body", list_value(stmt_items.as_span())),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Expr.expr_expression_list as x:
                return node("AST::ExpressionList", fields3(
                    field_value("elements", expr_list_value(ctx, x.elements)),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Expr.expr_named as x:
                return node("AST::Argument", fields4(
                    field_str("name", x.name),
                    field_value("value", expr_value(ctx, x.value)),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_range as x:
                return node("AST::RangeExpr", fields4(
                    field_value("start_expr", expr_value(ctx, x.start_expr)),
                    field_value("end_expr", expr_value(ctx, x.end_expr)),
                    field_line(x.line),
                    field_uint("column", x.column),
                ))
            ast.Expr.expr_prefix_cast as x:
                return node("AST::PrefixCast", fields5(
                    field_value("target_type", type_ref_value(ctx, unsafe: read(x.target_type))),
                    field_value("expression", expr_value(ctx, x.expression)),
                    field_line(x.line),
                    len_field("column", x.column),
                    field_nil("length"),
                ))
            ast.Expr.expr_unsafe as x:
                return node("AST::UnsafeExpr", fields4(
                    field_value("expression", expr_value(ctx, x.expression)),
                    field_line(x.line),
                    len_field("column", x.column),
                    field_uint("length", 6),
                ))
            ast.Expr.expr_sizeof as x:
                return node("AST::SizeofExpr", fields3(
                    field_value("type", type_ref_value(ctx, unsafe: read(x.target_type))),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_alignof as x:
                return node("AST::AlignofExpr", fields3(
                    field_value("type", type_ref_value(ctx, unsafe: read(x.target_type))),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_offsetof as x:
                return node("AST::OffsetofExpr", fields4(
                    field_value("type", type_ref_value(ctx, unsafe: read(x.target_type))),
                    field_str("field", x.field),
                    field_nil("line"),
                    field_nil("column"),
                ))
            ast.Expr.expr_error as x:
                return node("AST::ErrorExpr", fields4(
                    field_line(x.line),
                    len_field("column", x.column),
                    field_nil("length"),
                    field_str("message", x.message),
                ))
    return node("AST::ErrorExpr", fields4(field_nil("line"), field_nil("column"), field_nil("length"), field_str("message", "")))


## `if` expression node.
function expr_if_value(
    ctx: ref[SexprContext], condition: ptr[ast.Expr], then_expr: ptr[ast.Expr], else_expr: ptr[ast.Expr],
) -> SexprValue:
    return node("AST::IfExpr", fields5(
        field_value("condition", expr_value(ctx, condition)),
        field_value("then_expression", expr_value(ctx, then_expr)),
        field_value("else_expression", expr_value(ctx, else_expr)),
        field_nil("line"),
        field_nil("column"),
    ))


## `match` expression node.
function expr_match_value(
    ctx: ref[SexprContext], scrutinee: ptr[ast.Expr], arms: span[ast.MatchExprArm],
    line: ptr_uint, column: ptr_uint, length: ptr_uint, desugared: bool,
) -> SexprValue:
    return node("AST::MatchExpr", fields6(
        field_value("expression", expr_value(ctx, scrutinee)),
        field_value("arms", match_expr_arms_value(ctx, arms)),
        field_line(line),
        len_field("column", column),
        len_field("length", length),
        field_bool("desugared_from_is", desugared),
    ))


function type_arguments_value(ctx: ref[SexprContext], items: span[ast.TypeArgument]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        items_out.push(type_argument_value(ctx, unsafe: read(items.data + i)))
        i += 1
    return list_value(items_out.as_span())


function expr_list_value(ctx: ref[SexprContext], items: span[ast.Expr]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        items_out.push(expr_value(ctx, unsafe: items.data + i))
        i += 1
    return list_value(items_out.as_span())


function ast_stmts_list(ctx: ref[SexprContext], body: span[ast.Stmt]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < body.len:
        var st: ast.Stmt
        unsafe:
            st = read(body.data + i)
        match st:
            ast.Stmt.stmt_block as blk:
                var j: ptr_uint = 0
                while j < blk.statements.len:
                    items_out.push(stmt_value(ctx, unsafe: blk.statements.data + j))
                    j += 1
            _:
                items_out.push(stmt_value(ctx, unsafe: body.data + i))
        i += 1
    return list_value(items_out.as_span())


function stmts_of_ptr(ctx: ref[SexprContext], body: ptr[ast.Stmt]?) -> SexprValue:
    if body == null:
        return list_value(span[SexprValue]())
    var items_out = vec.Vec[SexprValue].create()
    unsafe:
        var st = read(ptr[ast.Stmt]<-body)
        match st:
            ast.Stmt.stmt_block as blk:
                var j: ptr_uint = 0
                while j < blk.statements.len:
                    items_out.push(stmt_value(ctx, unsafe: blk.statements.data + j))
                    j += 1
            _:
                items_out.push(stmt_value(ctx, ptr[ast.Stmt]<-body))
    return list_value(items_out.as_span())


function body_field_or_nil(ctx: ref[SexprContext], name: str, body: ptr[ast.Stmt]?) -> SexprField:
    if body == null:
        return field_nil(name)
    return field_value(name, stmts_of_ptr(ctx, body))


## `else as x` binding: the host stores an `AST::Identifier` node.
function else_binding_field(ctx: ref[SexprContext], value: Option[str], line: ptr_uint, column: ptr_uint) -> SexprField:
    match value:
        Option.some as v:
            return field_value("else_binding", node("AST::Identifier", fields3(
                field_str("name", v.value),
                field_line(line),
                len_field("column", column),
            )))
        Option.none:
            return field_nil("else_binding")
    return field_nil("else_binding")


function destructure_bindings_field(name: str, value: Option[span[str]]) -> SexprField:
    match value:
        Option.some as names:
            var items_out = vec.Vec[SexprValue].create()
            var i: ptr_uint = 0
            while i < names.value.len:
                items_out.push(SexprValue.sv_str(value = unsafe: read(names.value.data + i)))
                i += 1
            return field_value(name, list_value(items_out.as_span()))
        Option.none:
            return field_nil(name)
    return field_nil(name)


## `destructure_type_name` holds the joined dotted name; the host's AST keeps the
## part list, so a qualified name renders as a list of its parts
## (`("types" "Transform")`) while a bare name stays a plain string, matching the
## reference dump byte for byte.
function destructure_type_name_field(value: Option[str]) -> SexprField:
    match value:
        Option.some as name:
            if name.value.find_byte('.').is_none():
                return field_str("destructure_type_name", name.value)
            var items_out = vec.Vec[SexprValue].create()
            var rest = name.value
            while true:
                match rest.find_byte('.'):
                    Option.some as dot:
                        items_out.push(SexprValue.sv_str(value = rest.slice(0, dot.value)))
                        rest = rest.slice(dot.value + 1, rest.len - dot.value - 1)
                    Option.none:
                        items_out.push(SexprValue.sv_str(value = rest))
                        break
            return field_value("destructure_type_name", list_value(items_out.as_span()))
        Option.none:
            return field_nil("destructure_type_name")
    return field_nil("destructure_type_name")


function stmt_value(ctx: ref[SexprContext], sp: ptr[ast.Stmt]) -> SexprValue:
    unsafe:
        match read(sp):
            ast.Stmt.stmt_local as x:
                var name_field = field_str("name", x.name)
                match x.destructure_bindings:
                    Option.some:
                        name_field = field_nil("name")
                    Option.none:
                        pass
                return node("AST::LocalDecl", fields11(
                    field_sym("kind", ast_kind_symbol(x.is_let)),
                    name_field,
                    opt_type_ref_field(ctx, "type", x.stmt_type),
                    opt_expr_field(ctx, "value", x.value),
                    else_binding_field(ctx, x.else_binding, x.else_binding_line, x.else_binding_column),
                    body_field_or_nil(ctx, "else_body", x.else_body),
                    field_line(x.line),
                    len_field("column", x.column),
                    field_bool("recovered_else", false),
                    destructure_bindings_field("destructure_bindings", x.destructure_bindings),
                    destructure_type_name_field(x.destructure_type_name),
                ))
            ast.Stmt.stmt_assignment as x:
                return node("AST::Assignment", fields5(
                    field_value("target", expr_value(ctx, x.target)),
                    field_str("operator", x.operator),
                    field_value("value", expr_value(ctx, x.value)),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Stmt.stmt_if as x:
                var else_body_field = field_nil("else_body")
                if x.else_body != null:
                    else_body_field = field_value("else_body", stmts_of_ptr(ctx, x.else_body))
                return node("AST::IfStmt", fields7(
                    field_value("branches", if_branches_value(ctx, x.branches)),
                    else_body_field,
                    field_bool("inline", x.is_inline),
                    field_line(x.line),
                    field_nil("column"),
                    len_field("else_line", x.else_line),
                    len_field("else_column", x.else_column),
                ))
            ast.Stmt.stmt_while as x:
                return node("AST::WhileStmt", fields6(
                    field_value("condition", expr_value(ctx, x.condition)),
                    body_field_or_nil(ctx, "body", x.body),
                    field_bool("inline", x.is_inline),
                    field_line(x.line),
                    len_field("column", x.column),
                    len_field("length", x.length),
                ))
            ast.Stmt.stmt_for as x:
                return node("AST::ForStmt", fields7(
                    field_value("bindings", for_bindings_value(ctx, x.bindings)),
                    field_value("iterables", expr_list_value(ctx, x.iterables)),
                    body_field_or_nil(ctx, "body", x.body),
                    field_bool("inline", x.is_inline),
                    field_bool("threaded", x.threaded),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Stmt.stmt_match as x:
                return node("AST::MatchStmt", fields6(
                    field_value("expression", expr_value(ctx, x.scrutinee)),
                    field_value("arms", match_arms_value(ctx, x.arms)),
                    field_bool("inline", x.is_inline),
                    field_line(x.line),
                    len_field("column", x.column),
                    field_uint("length", 5),
                ))
            ast.Stmt.stmt_ret as x:
                return node("AST::ReturnStmt", fields4(
                    opt_expr_field(ctx, "value", x.value),
                    field_line(x.line),
                    len_field("column", x.column),
                    len_field("length", x.length),
                ))
            ast.Stmt.stmt_break as x:
                return node("AST::BreakStmt", fields3(
                    field_line(x.line),
                    len_field("column", x.column),
                    field_uint("length", 5),
                ))
            ast.Stmt.stmt_continue as x:
                return node("AST::ContinueStmt", fields3(
                    field_line(x.line),
                    len_field("column", x.column),
                    field_uint("length", 8),
                ))
            ast.Stmt.stmt_pass as x:
                return node("AST::PassStmt", fields3(
                    field_line(x.line),
                    len_field("column", x.column),
                    field_uint("length", 4),
                ))
            ast.Stmt.stmt_defer as x:
                var defer_body = field_nil("body")
                if x.body != null:
                    defer_body = field_value("body", stmts_of_ptr(ctx, x.body))
                else if x.expression != null:
                    var stmt_items = vec.Vec[SexprValue].create()
                    stmt_items.push(node("AST::ExpressionStmt", fields3(
                        field_value("expression", expr_value(ctx, unsafe: ptr[ast.Expr]<-x.expression)),
                        field_nil("line"),
                        field_nil("column"),
                    )))
                    defer_body = field_value("body", list_value(stmt_items.as_span()))
                return node("AST::DeferStmt", fields4(
                    defer_body,
                    field_line(x.line),
                    len_field("column", x.column),
                    field_uint("length", 5),
                ))
            ast.Stmt.stmt_unsafe as x:
                return node("AST::UnsafeStmt", fields4(
                    body_field_or_nil(ctx, "body", x.body),
                    field_line(x.line),
                    len_field("column", x.column),
                    field_uint("length", 6),
                ))
            ast.Stmt.stmt_expression as x:
                return node("AST::ExpressionStmt", fields3(
                    field_value("expression", expr_value(ctx, x.expression)),
                    field_line(x.line),
                    field_nil("column"),
                ))
            ast.Stmt.stmt_static_assert as x:
                return node("AST::StaticAssert", fields4(
                    field_value("condition", expr_value(ctx, x.condition)),
                    opt_expr_field(ctx, "message", x.message),
                    field_line(x.line),
                    field_nil("column"),
                ))
            ast.Stmt.stmt_emit as x:
                var decl_field = field_nil("declaration")
                if x.declaration != null:
                    decl_field = field_value("declaration", decl_value(ctx, unsafe: ptr[ast.Decl]<-x.declaration, false))
                return node("AST::EmitStmt", fields3(
                    decl_field,
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Stmt.stmt_when as x:
                var when_else = field_nil("else_body")
                if x.else_body != null:
                    when_else = field_value("else_body", stmts_of_ptr(ctx, x.else_body))
                return node("AST::WhenStmt", fields6(
                    field_value("discriminant", expr_value(ctx, x.discriminant)),
                    field_value("branches", when_branches_value(ctx, x.branches)),
                    when_else,
                    field_line(x.line),
                    len_field("column", x.column),
                    field_uint("length", 4),
                ))
            ast.Stmt.stmt_parallel_block as x:
                var bodies_out = vec.Vec[SexprValue].create()
                var bi: ptr_uint = 0
                while bi < x.bodies.len:
                    var single = vec.Vec[SexprValue].create()
                    single.push(stmt_value(ctx, unsafe: x.bodies.data + bi))
                    bodies_out.push(list_value(single.as_span()))
                    bi += 1
                return node("AST::ParallelBlockStmt", fields3(
                    field_value("bodies", list_value(bodies_out.as_span())),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Stmt.stmt_gather as x:
                return node("AST::GatherStmt", fields3(
                    field_value("handles", expr_list_value(ctx, x.handles)),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Stmt.stmt_error as x:
                return node("AST::ErrorStmt", fields4(
                    field_line(x.line),
                    len_field("column", x.column),
                    field_nil("length"),
                    field_str("message", x.message),
                ))
            ast.Stmt.stmt_error_block as x:
                return node("AST::ErrorBlockStmt", fields9(
                    field_value("body", stmts_of_ptr(ctx, x.body)),
                    field_line(x.line),
                    len_field("column", x.column),
                    field_nil("length"),
                    field_str("message", x.message),
                    field_nil("header_type"),
                    field_nil("header_expression"),
                    field_nil("header_bindings"),
                    field_nil("header_iterables"),
                ))
            ast.Stmt.stmt_block as x:
                return ast_stmts_list(ctx, x.statements)
    return node("AST::ErrorStmt", fields4(field_nil("line"), field_nil("column"), field_nil("length"), field_str("message", "")))


function opt_expr_field(ctx: ref[SexprContext], name: str, value: ptr[ast.Expr]?) -> SexprField:
    if value == null:
        return field_nil(name)
    return field_value(name, expr_value(ctx, unsafe: ptr[ast.Expr]<-value))


function qname_list_value(ctx: ref[SexprContext], items: span[ast.QualifiedName]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        items_out.push(qname_full_value(ctx, unsafe: read(items.data + i)))
        i += 1
    return list_value(items_out.as_span())


function str_list_value(items: span[str]) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        items_out.push(SexprValue.sv_str(value = unsafe: read(items.data + i)))
        i += 1
    return list_value(items_out.as_span())


function decls_value(ctx: ref[SexprContext], items: span[ast.Decl], raw: bool) -> SexprValue:
    var items_out = vec.Vec[SexprValue].create()
    var i: ptr_uint = 0
    while i < items.len:
        items_out.push(decl_value(ctx, unsafe: items.data + i, raw))
        i += 1
    return list_value(items_out.as_span())


## Render a declaration's visibility.  External-file declarations are implicitly
## exported, so the host stores (and renders) `nil`; nested/ordinary
## declarations carry an explicit `:private`/`:public`.
function visibility_field(raw: bool, visibility: bool) -> SexprField:
    if raw:
        return field_nil("visibility")
    return field_sym("visibility", visibility_symbol(visibility))


function decl_value(ctx: ref[SexprContext], dp: ptr[ast.Decl], raw: bool) -> SexprValue:
    unsafe:
        match read(dp):
            ast.Decl.decl_const:
                return decl_value_const(ctx, dp, raw)
            ast.Decl.decl_var as x:
                return node("AST::VarDecl", fields6(
                    field_str("name", x.name),
                    opt_type_ref_field(ctx, "type", x.var_type),
                    opt_expr_field(ctx, "value", x.value),
                    visibility_field(raw, x.visibility),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Decl.decl_function:
                return decl_value_function(ctx, dp, raw)
            ast.Decl.decl_struct:
                return decl_value_struct(ctx, dp, raw)
            ast.Decl.decl_union as x:
                return node("AST::UnionDecl", fields7(
                    field_str("name", x.name),
                    field_opt_str("c_name", x.c_name),
                    field_value("fields", union_fields_value(ctx, x.union_fields)),
                    visibility_field(raw, x.visibility),
                    field_value("attributes", attributes_value(ctx, x.union_attrs)),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Decl.decl_enum as x:
                return node("AST::EnumDecl", fields7(
                    field_str("name", x.name),
                    opt_type_ref_field(ctx, "backing_type", x.backing_type),
                    field_value("members", enum_members_value(ctx, x.enum_members)),
                    visibility_field(raw, x.visibility),
                    field_value("attributes", attributes_value(ctx, x.enum_attrs)),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Decl.decl_flags as x:
                return node("AST::FlagsDecl", fields7(
                    field_str("name", x.name),
                    opt_type_ref_field(ctx, "backing_type", x.backing_type),
                    field_value("members", enum_members_value(ctx, x.flags_members)),
                    visibility_field(raw, x.visibility),
                    field_value("attributes", attributes_value(ctx, x.flags_attrs)),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Decl.decl_variant as x:
                return node("AST::VariantDecl", fields7(
                    field_str("name", x.name),
                    field_value("type_params", type_params_value(ctx, x.type_params)),
                    field_value("arms", variant_arms_value(ctx, x.variant_arms)),
                    visibility_field(raw, x.visibility),
                    field_value("attributes", attributes_value(ctx, x.variant_attrs)),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Decl.decl_opaque as x:
                return node("AST::OpaqueDecl", fields6(
                    field_str("name", x.name),
                    field_value("implements", qname_list_value(ctx, x.opaque_implements)),
                    field_opt_str("c_name", x.c_name),
                    visibility_field(raw, x.visibility),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Decl.decl_type_alias as x:
                return node("AST::TypeAliasDecl", fields5(
                    field_str("name", x.name),
                    field_value("target", type_ref_value(ctx, read(x.target))),
                    visibility_field(raw, x.visibility),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Decl.decl_interface as x:
                return node("AST::InterfaceDecl", fields6(
                    field_str("name", x.name),
                    field_value("type_params", type_params_value(ctx, x.type_params)),
                    field_value("methods", interface_methods_value(ctx, x.interface_methods)),
                    visibility_field(raw, x.visibility),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Decl.decl_extending_block as x:
                return node("AST::ExtendingBlock", fields5(
                    field_value("type_name", type_ref_value(ctx, read(x.type_name))),
                    field_value("methods", methods_value(ctx, x.methods)),
                    field_line(x.line),
                    len_field("column", x.column),
                    field_bool("inline", x.is_inline),
                ))
            ast.Decl.decl_extern_function as x:
                return node("AST::ExternFunctionDecl", fields9(
                    field_str("name", x.name),
                    field_value("type_params", type_params_value(ctx, x.type_params)),
                    field_value("params", foreign_params_value(ctx, x.extern_params)),
                    opt_type_ref_field(ctx, "return_type", x.return_type),
                    field_bool("variadic", x.variadic),
                    field_value("attributes", attributes_value(ctx, x.attrs)),
                    field_line(x.line),
                    field_nil("column"),
                    opt_expr_field(ctx, "mapping", x.mapping),
                ))
            ast.Decl.decl_foreign_function as x:
                return node("AST::ForeignFunctionDecl", fields10(
                    field_str("name", x.name),
                    field_value("type_params", type_params_value(ctx, x.type_params)),
                    field_value("params", foreign_params_value(ctx, x.foreign_params)),
                    opt_type_ref_field(ctx, "return_type", x.return_type),
                    field_bool("variadic", x.variadic),
                    opt_expr_field(ctx, "mapping", x.mapping),
                    visibility_field(raw, x.visibility),
                    field_value("attributes", attributes_value(ctx, x.attrs)),
                    field_line(x.line),
                    field_nil("column"),
                ))
            ast.Decl.decl_event as x:
                return node("AST::EventDecl", fields7(
                    field_str("name", x.name),
                    field_int("capacity", long<-x.capacity),
                    opt_type_ref_field(ctx, "payload_type", x.payload_type),
                    visibility_field(raw, x.visibility),
                    field_value("attributes", attributes_value(ctx, x.attrs)),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Decl.decl_static_assert as x:
                return node("AST::StaticAssert", fields4(
                    field_value("condition", expr_value(ctx, x.condition)),
                    opt_expr_field(ctx, "message", x.message),
                    field_line(x.line),
                    field_nil("column"),
                ))
            ast.Decl.decl_when as x:
                var when_else = field_nil("else_body")
                if x.has_else:
                    when_else = field_value("else_body", decls_value(ctx, x.else_body, false))
                return node("AST::WhenStmt", fields6(
                    field_value("discriminant", expr_value(ctx, x.discriminant)),
                    field_value("branches", when_decl_branches_value(ctx, x.branches)),
                    when_else,
                    field_line(x.line),
                    len_field("column", x.column),
                    field_uint("length", 4),
                ))
            ast.Decl.decl_attribute as x:
                return node("AST::AttributeDecl", fields6(
                    field_str("name", x.name),
                    field_value("targets", sym_list_value(x.targets)),
                    field_value("params", params_value(ctx, x.attr_params)),
                    visibility_field(raw, x.visibility),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Decl.decl_import as x:
                return node("AST::Import", fields5(
                    field_value("path", qname_bare_value(x.path.parts)),
                    field_opt_str("alias_name", x.alias_name),
                    field_line(x.line),
                    len_field("column", x.column),
                    len_field("length", x.length),
                ))
            ast.Decl.decl_link as x:
                return node("AST::LinkDirective", fields3(
                    field_str("value", x.value),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Decl.decl_include as x:
                return node("AST::IncludeDirective", fields3(
                    field_str("value", x.value),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            ast.Decl.decl_compiler_flag as x:
                return node("AST::CompilerFlagDirective", fields3(
                    field_str("value", x.value),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
    return node("AST::VarDecl", fields6(field_str("name", ""), field_nil("type"), field_nil("value"), field_sym("visibility", "private"), field_nil("line"), field_nil("column")))


## Fallback node for an unexpected declaration kind.
function decl_value_fallback() -> SexprValue:
    return node("AST::VarDecl", fields6(field_str("name", ""), field_nil("type"), field_nil("value"), field_sym("visibility", "private"), field_nil("line"), field_nil("column")))


## `const` declaration node.
function decl_value_const(ctx: ref[SexprContext], dp: ptr[ast.Decl], raw: bool) -> SexprValue:
    unsafe:
        match read(dp):
            ast.Decl.decl_const as x:
                var block_field = field_nil("block_body")
                if x.block_body != null:
                    block_field = field_value("block_body", stmts_of_ptr(ctx, x.block_body))
                return node("AST::ConstDecl", fields8(
                    field_str("name", x.name),
                    field_value("type", type_ref_value(ctx, read(x.const_type))),
                    opt_expr_field(ctx, "value", x.value),
                    block_field,
                    visibility_field(raw, x.visibility),
                    field_value("attributes", attributes_value(ctx, x.attributes)),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            _:
                return decl_value_fallback()


## Function declaration node.
function decl_value_function(ctx: ref[SexprContext], dp: ptr[ast.Decl], raw: bool) -> SexprValue:
    unsafe:
        match read(dp):
            ast.Decl.decl_function as x:
                var body_field = field_nil("body")
                if x.body != null:
                    body_field = field_value("body", stmts_of_ptr(ctx, x.body))
                return node("AST::FunctionDef", fields11(
                    field_str("name", x.name),
                    field_value("type_params", type_params_value(ctx, x.type_params)),
                    field_value("params", params_value(ctx, x.method_params)),
                    opt_type_ref_field(ctx, "return_type", x.return_type),
                    body_field,
                    visibility_field(raw, x.visibility),
                    field_bool("async", x.is_async),
                    field_bool("const", x.is_const),
                    field_value("attributes", attributes_value(ctx, x.attributes)),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            _:
                return decl_value_fallback()


## Struct declaration node.
function decl_value_struct(ctx: ref[SexprContext], dp: ptr[ast.Decl], raw: bool) -> SexprValue:
    unsafe:
        match read(dp):
            ast.Decl.decl_struct as x:
                return node("AST::StructDecl", fields14(
                    field_str("name", x.name),
                    field_value("type_params", type_params_value(ctx, x.type_params)),
                    field_value("implements", qname_list_value(ctx, x.impl_list)),
                    field_opt_str("c_name", x.c_name),
                    field_value("fields", fields_value(ctx, x.struct_fields)),
                    field_value("events", decls_value(ctx, x.struct_events, false)),
                    field_value("nested_types", decls_value(ctx, x.nested_types, false)),
                    field_value("attributes", attributes_value(ctx, x.struct_attrs)),
                    field_bool("packed", x.packed),
                    field_zero_nil_int("alignment", x.alignment),
                    visibility_field(raw, x.visibility),
                    field_value("lifetime_params", str_list_value(x.lifetime_params)),
                    field_line(x.line),
                    len_field("column", x.column),
                ))
            _:
                return decl_value_fallback()


public function dump_ast(file: ast.SourceFile, module_name: str) -> string.String:
    var ctx = create_sexpr_context(module_name)
    var buf = string.String.create()
    var module_field = field_nil("module_name")
    if module_name.len > 0:
        var parts = vec.Vec[str].create()
        var part_start: ptr_uint = 0
        var pi: ptr_uint = 0
        while pi <= module_name.len:
            if pi == module_name.len or module_name.byte_at(pi) == 46:
                if pi > part_start:
                    parts.push(module_name.slice(part_start, pi - part_start))
                part_start = pi + 1
            pi += 1
        module_field = field_value("module_name", qname_bare_value(parts.as_span()))
    var kind_sym = "module"
    var is_raw = file.module_kind == ast.ModuleKind.module_raw
    if is_raw:
        kind_sym = "raw_module"
    # External files record the `external` keyword's line; ordinary files have
    # no module line (host `module_line = nil`).
    var line_field = field_nil("line")
    if is_raw:
        line_field = field_line(file.line)
    var value = node("AST::SourceFile", fields7(
        module_field,
        field_sym("module_kind", kind_sym),
        field_value("imports", decls_value(ref_of(ctx), file.imports, false)),
        field_value("directives", decls_value(ref_of(ctx), file.directives, false)),
        field_value("declarations", decls_value(ref_of(ctx), file.declarations, is_raw)),
        line_field,
        field_nil("column"),
    ))
    render_value(ref_of(buf), value)
    return buf
