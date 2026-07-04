## AST pretty printer — reconstructs canonical Milk Tea source from an
## `ast.SourceFile`.  Mirrors the Ruby PrettyPrinter::ASTFormatter
## (lib/milk_tea/core/pretty_printer/ast_formatter.rb) so that
## `mtc parse <file>` output is byte-identical between the Ruby and
## self-hosted compilers.
##
## `mtc parse` emits no comments (trivia is only interleaved by the formatter
## command), so this printer omits comment reattachment and focuses on
## declaration/statement/expression rendering with precedence-aware
## parenthesization and `is`-expression re-sugaring.
##
## Milk Tea variant-arm payloads are not nameable parameter types, so the
## per-arm rendering logic is inlined directly into the dispatch `match`
## blocks (emit_declaration / emit_statement / render_expression); only
## struct-typed helpers (render_param, render_interface_method, emit_method,
## ...) are factored out.
##
## The formatter (`f: ref[Formatter]`) is threaded through the expression
## renderers so multi-line constructs (match expressions, multi-line procs)
## compute absolute indentation from `f.indent`, exactly as the Ruby
## formatter uses its `@indent` instance state.
##
## Output strings are built with std.string.String and returned as `str`
## views; backing buffers are intentionally leaked (arena-style) since one
## file is formatted per process.

import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast


const IF_EXPRESSION_PRECEDENCE: int = 5
const POSTFIX_PRECEDENCE: int = 90
const UNARY_PRECEDENCE: int = 80
const IS_PRECEDENCE: int = 25


struct Formatter:
    buffer: string.String
    indent: ptr_uint
    module_kind: ast.ModuleKind
    any_output: bool
    last_blank: bool


public function format_source_file(file: ast.SourceFile) -> string.String:
    var f = Formatter(
        buffer = string.String.create(),
        indent = 0,
        module_kind = file.module_kind,
        any_output = false,
        last_blank = false,
    )
    emit_source_file(ref_of(f), file)
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


function join_strs(items: span[str], sep: str) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < items.len:
        if i > 0:
            buf.append(sep)
        unsafe:
            buf.append(read(items.data + i))
        i += 1
    return buf.as_str()


function indent_str(levels: ptr_uint) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < levels:
        buf.append("    ")
        i += 1
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


# =============================================================================
#  Types (single-line)
# =============================================================================

function qname_to_str(q: ast.QualifiedName) -> str:
    return join_strs(q.parts, ".")


function render_type_ptr(t: ptr[ast.TypeRef]?) -> str:
    let tp = t else:
        return ""
    unsafe:
        return render_type(read(tp))


function render_type(t: ast.TypeRef) -> str:
    if t.is_fn or t.is_proc:
        let kw = if t.is_proc: "proc" else: "fn"
        var params_buf = string.String.create()
        var i: ptr_uint = 0
        while i < t.fn_params.len:
            if i > 0:
                params_buf.append(", ")
            unsafe:
                params_buf.append(render_param(read(t.fn_params.data + i)))
            i += 1
        return j5(kw, "(", params_buf.as_str(), ") -> ", render_type_ptr(t.fn_return))

    if t.is_dyn:
        var inner = qname_to_str(t.dyn_interface)
        if t.dyn_interface.type_arguments.len > 0:
            inner = j4(inner, "[", render_type_seq(t.dyn_interface.type_arguments), "]")
        return j3("dyn[", inner, "]")

    if t.is_tuple:
        let base = j3("(", render_type_seq(t.arguments), ")")
        if t.nullable:
            return j2(base, "?")
        return base

    var text = qname_to_str(t.name)
    var args = vec.Vec[str].create()
    match t.lifetime:
        Option.some as lt:
            args.push(j2("@", lt.value))
        Option.none:
            pass
    var ai: ptr_uint = 0
    while ai < t.arguments.len:
        unsafe:
            args.push(render_type(read(t.arguments.data + ai)))
        ai += 1
    if args.len() > 0:
        text = j4(text, "[", join_strs(args.as_span(), ", "), "]")
    if t.nullable:
        return j2(text, "?")
    return text


function render_type_seq(args: span[ast.TypeRef]) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < args.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            buf.append(render_type(read(args.data + i)))
        i += 1
    return buf.as_str()


function render_param(p: ast.Param) -> str:
    return j3(p.name, ": ", render_type(p.param_type))


function render_foreign_param(p: ast.ForeignParam) -> str:
    var prefix = ""
    match p.param_mode:
        ast.ForeignParamMode.fmode_out:
            prefix = "out "
        ast.ForeignParamMode.fmode_in:
            prefix = "in "
        ast.ForeignParamMode.fmode_inout:
            prefix = "inout "
        ast.ForeignParamMode.fmode_consuming:
            prefix = "consuming "
        ast.ForeignParamMode.fmode_plain:
            prefix = ""
    var text = j4(prefix, p.name, ": ", render_type(p.param_type))
    match p.boundary_type:
        Option.some as bt:
            text = j3(text, " as ", render_type(bt.value))
        Option.none:
            pass
    return text


function render_param_list(params: span[ast.Param]) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < params.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            buf.append(render_param(read(params.data + i)))
        i += 1
    return buf.as_str()


function render_foreign_param_list(params: span[ast.ForeignParam], variadic: bool) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < params.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            buf.append(render_foreign_param(read(params.data + i)))
        i += 1
    if variadic:
        if params.len > 0:
            buf.append(", ")
        buf.append("...")
    return buf.as_str()


# =============================================================================
#  Type parameters
# =============================================================================

function render_type_params(type_params: span[ast.TypeParam]) -> str:
    if type_params.len == 0:
        return ""
    var parts = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < type_params.len:
        var tp: ast.TypeParam
        unsafe:
            tp = read(type_params.data + i)
        parts.push(render_one_type_param(tp))
        i += 1
    return j3("[", join_strs(parts.as_span(), ", "), "]")


function render_one_type_param(tp: ast.TypeParam) -> str:
    if tp.is_lifetime:
        return tp.name
    if tp.is_value:
        return j3(tp.name, ": ", render_type_ptr(tp.value_type))
    if tp.constraints.len == 0:
        return tp.name
    return j3(tp.name, " ", render_constraints(tp.constraints))


function render_constraints(constraints: span[ast.TypeParamConstraint]) -> str:
    var names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < constraints.len:
        unsafe:
            names.push(qname_to_str(read(constraints.data + i).interface_ref))
        i += 1
    return j2("implements ", join_strs(names.as_span(), " and "))


function render_implements_clause(impls: span[ast.QualifiedName]) -> str:
    if impls.len == 0:
        return ""
    var names = vec.Vec[str].create()
    var i: ptr_uint = 0
    while i < impls.len:
        unsafe:
            names.push(qname_to_str(read(impls.data + i)))
        i += 1
    return j2(" implements ", join_strs(names.as_span(), ", "))


# =============================================================================
#  Attributes
# =============================================================================

function emit_attribute_applications(f: ref[Formatter], attrs: span[ast.AttributeApplication]) -> void:
    var i: ptr_uint = 0
    while i < attrs.len:
        var a: ast.AttributeApplication
        unsafe:
            a = read(attrs.data + i)
        emit_line(f, render_attribute_application(f, a))
        i += 1


function render_attribute_application(f: ref[Formatter], a: ast.AttributeApplication) -> str:
    var text = j2("@[", qname_to_str(a.name))
    if a.arguments.len > 0:
        text = j4(text, "(", render_argument_list(f, a.arguments), ")")
    return j2(text, "]")


function render_argument_list(f: ref[Formatter], args: span[ast.Argument]) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < args.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            buf.append(render_argument(f, read(args.data + i)))
        i += 1
    return buf.as_str()


function render_argument(f: ref[Formatter], a: ast.Argument) -> str:
    match a.arg_name:
        Option.some as n:
            return j3(n.value, " = ", rx(f, a.arg_value, 0))
        Option.none:
            return rx(f, a.arg_value, 0)


# =============================================================================
#  Visibility
# =============================================================================

function visibility_prefix(f: ref[Formatter], visibility: bool) -> str:
    if f.module_kind == ast.ModuleKind.module_raw:
        return ""
    if visibility:
        return "public "
    return ""


# =============================================================================
#  Source file
# =============================================================================

function emit_source_file(f: ref[Formatter], file: ast.SourceFile) -> void:
    if file.module_kind == ast.ModuleKind.module_raw:
        emit_line(f, "external")
        if file.imports.len > 0 or file.directives.len > 0 or file.declarations.len > 0:
            blank_line(f)

    var wrote_section = false

    if file.imports.len > 0:
        var i: ptr_uint = 0
        while i < file.imports.len:
            unsafe:
                emit_line(f, render_import_decl(read(file.imports.data + i)))
            i += 1
        wrote_section = true

    if file.directives.len > 0:
        if wrote_section:
            blank_line(f)
        var i: ptr_uint = 0
        while i < file.directives.len:
            unsafe:
                emit_declaration(f, read(file.directives.data + i))
            i += 1
        wrote_section = true

    if file.declarations.len == 0:
        return

    if wrote_section:
        blank_line(f)

    var i: ptr_uint = 0
    while i < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + i)
        emit_declaration(f, decl)
        if i + 1 < file.declarations.len:
            var next_decl: ast.Decl
            unsafe:
                next_decl = read(file.declarations.data + i + 1)
            if declaration_separator_required(f, decl, next_decl):
                blank_line(f)
        i += 1


function render_import_decl(d: ast.Decl) -> str:
    match d:
        ast.Decl.decl_import as imp:
            var text = j2("import ", qname_to_str(imp.path))
            match imp.alias_name:
                Option.some as a:
                    text = j3(text, " as ", a.value)
                Option.none:
                    pass
            return text
        _:
            return ""


function declaration_separator_required(f: ref[Formatter], d: ast.Decl, next_decl: ast.Decl) -> bool:
    if f.module_kind == ast.ModuleKind.module_raw:
        if raw_block_decl(d) or raw_block_decl(next_decl):
            return true
        return raw_group(d) != raw_group(next_decl)
    return block_declaration(d) or block_declaration(next_decl)


function block_declaration(d: ast.Decl) -> bool:
    match d:
        ast.Decl.decl_function:
            return true
        ast.Decl.decl_foreign_function:
            return true
        ast.Decl.decl_interface:
            return true
        ast.Decl.decl_extending_block:
            return true
        ast.Decl.decl_struct:
            return true
        ast.Decl.decl_union:
            return true
        ast.Decl.decl_enum:
            return true
        ast.Decl.decl_flags:
            return true
        ast.Decl.decl_variant:
            return true
        _:
            return false


function raw_block_decl(d: ast.Decl) -> bool:
    match d:
        ast.Decl.decl_struct:
            return true
        ast.Decl.decl_union:
            return true
        ast.Decl.decl_enum:
            return true
        ast.Decl.decl_flags:
            return true
        _:
            return false


function raw_group(d: ast.Decl) -> int:
    match d:
        ast.Decl.decl_opaque:
            return 1
        ast.Decl.decl_type_alias:
            return 1
        ast.Decl.decl_const:
            return 2
        ast.Decl.decl_extern_function:
            return 3
        _:
            return 0


# =============================================================================
#  Declarations
# =============================================================================

function emit_declaration(f: ref[Formatter], d: ast.Decl) -> void:
    match d:
        ast.Decl.decl_const as c:
            emit_attribute_applications(f, c.attributes)
            var header = j3(visibility_prefix(f, c.visibility), "const ", c.name)
            let block = c.block_body
            if block != null:
                emit_line(f, j4(header, " -> ", render_type_ptr(c.const_type), ":"))
                f.indent += 1
                emit_stmt_body(f, block)
                f.indent -= 1
            else:
                header = j3(header, ": ", render_type_ptr(c.const_type))
                emit_line(f, j3(header, " = ", rx_opt(f, c.value)))
        ast.Decl.decl_var as v:
            var header = j3(visibility_prefix(f, v.visibility), "var ", v.name)
            let vt = v.var_type
            if vt != null:
                header = j3(header, ": ", render_type_ptr(vt))
            let val = v.value
            if val != null:
                emit_line(f, j3(header, " = ", rx(f, val, 0)))
            else:
                emit_line(f, header)
        ast.Decl.decl_function as fun:
            emit_attribute_applications(f, fun.attributes)
            var async_prefix = if fun.is_async: "async " else: ""
            var sig = j5(visibility_prefix(f, fun.visibility), async_prefix, "function ", fun.name, render_type_params(fun.type_params))
            sig = j4(sig, "(", render_param_list(fun.method_params), ")")
            let frt = fun.return_type
            if frt != null:
                sig = j3(sig, " -> ", render_type_ptr(frt))
            emit_line(f, j2(sig, ":"))
            f.indent += 1
            emit_stmt_body(f, fun.body)
            f.indent -= 1
        ast.Decl.decl_struct as st:
            emit_attribute_applications(f, st.struct_attrs)
            var header = j4(visibility_prefix(f, st.visibility), "struct ", st.name, render_type_params(st.type_params))
            header = j2(header, render_implements_clause(st.impl_list))
            match st.c_name:
                Option.some as cn:
                    header = j4(header, " = c\"", cn.value, "\"")
                Option.none:
                    pass
            emit_line(f, j2(header, ":"))
            f.indent += 1
            var fi: ptr_uint = 0
            while fi < st.struct_fields.len:
                var field: ast.Field
                unsafe:
                    field = read(st.struct_fields.data + fi)
                emit_attribute_applications(f, field.attributes)
                emit_line(f, j3(field.name, ": ", render_type(field.field_type)))
                fi += 1
            var ni: ptr_uint = 0
            while ni < st.nested_types.len:
                unsafe:
                    emit_declaration(f, read(st.nested_types.data + ni))
                ni += 1
            var ei: ptr_uint = 0
            while ei < st.struct_events.len:
                unsafe:
                    emit_declaration(f, read(st.struct_events.data + ei))
                ei += 1
            f.indent -= 1
        ast.Decl.decl_union as u:
            emit_attribute_applications(f, u.union_attrs)
            var header = j3(visibility_prefix(f, u.visibility), "union ", u.name)
            match u.c_name:
                Option.some as cn:
                    header = j4(header, " = c\"", cn.value, "\"")
                Option.none:
                    pass
            emit_line(f, j2(header, ":"))
            f.indent += 1
            var fi: ptr_uint = 0
            while fi < u.union_fields.len:
                var field: ast.Field
                unsafe:
                    field = read(u.union_fields.data + fi)
                emit_line(f, j3(field.name, ": ", render_type(field.field_type)))
                fi += 1
            f.indent -= 1
        ast.Decl.decl_enum as e:
            emit_attribute_applications(f, e.enum_attrs)
            emit_enum_like(f, "enum", e.name, e.backing_type, e.enum_members, e.visibility)
        ast.Decl.decl_flags as fl:
            emit_attribute_applications(f, fl.flags_attrs)
            emit_enum_like(f, "flags", fl.name, fl.backing_type, fl.flags_members, fl.visibility)
        ast.Decl.decl_variant as vr:
            emit_attribute_applications(f, vr.variant_attrs)
            var header = j4(visibility_prefix(f, vr.visibility), "variant ", vr.name, render_type_params(vr.type_params))
            emit_line(f, j2(header, ":"))
            f.indent += 1
            var vi: ptr_uint = 0
            while vi < vr.variant_arms.len:
                var arm: ast.VariantArm
                unsafe:
                    arm = read(vr.variant_arms.data + vi)
                var text = arm.name
                if arm.arm_fields.len > 0:
                    var fields = vec.Vec[str].create()
                    var afi: ptr_uint = 0
                    while afi < arm.arm_fields.len:
                        var field: ast.Field
                        unsafe:
                            field = read(arm.arm_fields.data + afi)
                        fields.push(j3(field.name, ": ", render_type(field.field_type)))
                        afi += 1
                    text = j4(text, "(", join_strs(fields.as_span(), ", "), ")")
                emit_line(f, text)
                vi += 1
            f.indent -= 1
        ast.Decl.decl_opaque as op:
            var text = j3(visibility_prefix(f, op.visibility), "opaque ", op.name)
            text = j2(text, render_implements_clause(op.opaque_implements))
            match op.c_name:
                Option.some as cn:
                    text = j4(text, " = c\"", cn.value, "\"")
                Option.none:
                    pass
            emit_line(f, text)
        ast.Decl.decl_type_alias as ta:
            emit_line(f, j5(visibility_prefix(f, ta.visibility), "type ", ta.name, " = ", render_type_ptr(ta.target)))
        ast.Decl.decl_interface as it:
            var header = j4(visibility_prefix(f, it.visibility), "interface ", it.name, render_type_params(it.type_params))
            emit_line(f, j2(header, ":"))
            f.indent += 1
            var mi: ptr_uint = 0
            while mi < it.interface_methods.len:
                var m: ast.InterfaceMethod
                unsafe:
                    m = read(it.interface_methods.data + mi)
                emit_attribute_applications(f, m.attributes)
                emit_line(f, render_interface_method(m))
                mi += 1
            f.indent -= 1
        ast.Decl.decl_extending_block as ex:
            emit_line(f, j3("extending ", render_type_ptr(ex.type_name), ":"))
            f.indent += 1
            var xi: ptr_uint = 0
            while xi < ex.methods.len:
                var m: ast.Method
                unsafe:
                    m = read(ex.methods.data + xi)
                emit_method(f, m)
                if xi + 1 < ex.methods.len:
                    blank_line(f)
                xi += 1
            f.indent -= 1
        ast.Decl.decl_extern_function as ef:
            emit_attribute_applications(f, ef.attrs)
            var text = j4("external function ", ef.name, render_type_params(ef.type_params), "(")
            text = j3(text, render_foreign_param_list(ef.extern_params, ef.variadic), ")")
            let ert = ef.return_type
            if ert != null:
                text = j3(text, " -> ", render_type_ptr(ert))
            let emap = ef.mapping
            if emap != null:
                text = j3(text, " = ", rx(f, emap, 0))
            emit_line(f, text)
        ast.Decl.decl_foreign_function as ff:
            emit_attribute_applications(f, ff.attrs)
            var text = j4(visibility_prefix(f, ff.visibility), "foreign function ", ff.name, render_type_params(ff.type_params))
            text = j4(text, "(", render_foreign_param_list(ff.foreign_params, ff.variadic), ")")
            text = j3(text, " -> ", render_type_ptr(ff.return_type))
            text = j3(text, " = ", rx(f, ff.mapping, 0))
            emit_line(f, text)
        ast.Decl.decl_event as ev:
            emit_attribute_applications(f, ev.attrs)
            var text = j6(visibility_prefix(f, ev.visibility), "event ", ev.name, "[", int_to_str(ev.capacity), "]")
            let pt = ev.payload_type
            if pt != null:
                text = j4(text, "(", render_type_ptr(pt), ")")
            emit_line(f, text)
        ast.Decl.decl_static_assert as sa:
            emit_line(f, j5("static_assert(", rx(f, sa.condition, 0), ", ", rx_opt(f, sa.message), ")"))
        ast.Decl.decl_attribute as at:
            var text = j5(visibility_prefix(f, at.visibility), "attribute[", join_strs(at.targets, ", "), "] ", at.name)
            if at.attr_params.len > 0:
                text = j4(text, "(", render_param_list(at.attr_params), ")")
            emit_line(f, text)
        ast.Decl.decl_when as wh:
            emit_line(f, j3("when ", rx(f, wh.discriminant, 0), ":"))
            f.indent += 1
            var wi: ptr_uint = 0
            while wi < wh.branches.len:
                var br: ast.WhenDeclBranch
                unsafe:
                    br = read(wh.branches.data + wi)
                var bheader = rx(f, br.pattern, 0)
                match br.binding_name:
                    Option.some as bn:
                        bheader = j3(bheader, " as ", bn.value)
                    Option.none:
                        pass
                emit_line(f, j2(bheader, ":"))
                f.indent += 1
                emit_decl_span(f, br.body)
                f.indent -= 1
                wi += 1
            if wh.has_else:
                emit_line(f, "else:")
                f.indent += 1
                emit_decl_span(f, wh.else_body)
                f.indent -= 1
            f.indent -= 1
        ast.Decl.decl_import:
            emit_line(f, render_import_decl(d))
        ast.Decl.decl_link as lk:
            emit_line(f, j3("link \"", lk.value, "\""))
        ast.Decl.decl_include as inc:
            emit_line(f, j3("include \"", inc.value, "\""))
        ast.Decl.decl_compiler_flag as cf:
            emit_line(f, j3("compiler_flag \"", cf.value, "\""))


function emit_enum_like(f: ref[Formatter], kind: str, name: str, backing: ptr[ast.TypeRef]?, members: span[ast.EnumMember], visibility: bool) -> void:
    var header = j4(visibility_prefix(f, visibility), kind, " ", name)
    if backing != null:
        header = j3(header, ": ", render_type_ptr(backing))
    emit_line(f, header)
    f.indent += 1
    var i: ptr_uint = 0
    while i < members.len:
        var m: ast.EnumMember
        unsafe:
            m = read(members.data + i)
        var text = m.name
        let mv = m.value
        if mv != null:
            text = j3(text, " = ", rx(f, mv, 0))
        emit_line(f, text)
        i += 1
    f.indent -= 1


function render_interface_method(m: ast.InterfaceMethod) -> str:
    var prefix = ""
    if m.is_async:
        prefix = "async "
    if m.method_kind == ast.MethodKind.mk_editable:
        prefix = j2(prefix, "editable function ")
    else:
        prefix = j2(prefix, "function ")
    var text = j4(prefix, m.name, "(", j2(render_param_list(m.method_params), ")"))
    let rt = m.return_type
    if rt != null:
        text = j3(text, " -> ", render_type_ptr(rt))
    return text


function emit_method(f: ref[Formatter], m: ast.Method) -> void:
    emit_attribute_applications(f, m.attributes)
    emit_line(f, j2(render_method_signature(f, m), ":"))
    f.indent += 1
    emit_stmt_body(f, m.body)
    f.indent -= 1


function render_method_signature(f: ref[Formatter], m: ast.Method) -> str:
    var kind_prefix = "function "
    if m.method_kind == ast.MethodKind.mk_editable:
        kind_prefix = "editable function "
    else if m.method_kind == ast.MethodKind.mk_static:
        kind_prefix = "static function "
    var async_prefix = ""
    if m.is_async:
        async_prefix = "async "
    var text = j5(visibility_prefix(f, m.visibility), async_prefix, kind_prefix, m.name, render_type_params(m.type_params))
    text = j4(text, "(", render_param_list(m.method_params), ")")
    let rt = m.return_type
    if rt != null:
        text = j3(text, " -> ", render_type_ptr(rt))
    return text


function emit_decl_span(f: ref[Formatter], decls: span[ast.Decl]) -> void:
    var i: ptr_uint = 0
    while i < decls.len:
        unsafe:
            emit_declaration(f, read(decls.data + i))
        i += 1


# =============================================================================
#  Statements
# =============================================================================

function emit_stmt_body(f: ref[Formatter], body: ptr[ast.Stmt]?) -> void:
    let b = body else:
        return
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                emit_stmt_span(f, blk.statements)
            _:
                emit_statement(f, read(b))


function emit_stmt_span(f: ref[Formatter], stmts: span[ast.Stmt]) -> void:
    var i: ptr_uint = 0
    while i < stmts.len:
        var st: ast.Stmt
        unsafe:
            st = read(stmts.data + i)
        emit_statement(f, st)
        i += 1


function emit_statement(f: ref[Formatter], st: ast.Stmt) -> void:
    match st:
        ast.Stmt.stmt_block as b:
            emit_stmt_span(f, b.statements)
        ast.Stmt.stmt_local as l:
            let kind = if l.is_let: "let" else: "var"
            var text = ""
            match l.destructure_bindings:
                Option.some as db:
                    text = j3(kind, " ", render_destructure_target(db.value, l.destructure_type_name))
                Option.none:
                    text = j3(kind, " ", l.name)
                    let lt = l.stmt_type
                    if lt != null:
                        text = j3(text, ": ", render_type_ptr(lt))
            let lval = l.value
            if lval != null:
                text = j3(text, " = ", rx(f, lval, 0))
            let leb = l.else_body
            if leb != null:
                var else_header = "else:"
                match l.else_binding:
                    Option.some as eb2:
                        else_header = j3("else as ", eb2.value, ":")
                    Option.none:
                        pass
                emit_line(f, j3(text, " ", else_header))
                f.indent += 1
                emit_stmt_body(f, leb)
                f.indent -= 1
            else:
                emit_line(f, text)
        ast.Stmt.stmt_assignment as a:
            emit_line(f, j5(rx(f, a.target, 0), " ", a.operator, " ", rx(f, a.value, 0)))
        ast.Stmt.stmt_if as i:
            let iprefix = if i.is_inline: "inline if " else: "if "
            var first = true
            var bi: ptr_uint = 0
            while bi < i.branches.len:
                var br: ast.IfBranch
                unsafe:
                    br = read(i.branches.data + bi)
                if first:
                    emit_line(f, j3(iprefix, rx(f, br.condition, 0), ":"))
                    first = false
                else:
                    emit_line(f, j3("else if ", rx(f, br.condition, 0), ":"))
                f.indent += 1
                emit_stmt_body(f, br.body)
                f.indent -= 1
                bi += 1
            let ieb = i.else_body
            if ieb != null:
                emit_line(f, "else:")
                f.indent += 1
                emit_stmt_body(f, ieb)
                f.indent -= 1
        ast.Stmt.stmt_while as w:
            let prefix = if w.is_inline: "inline while " else: "while "
            emit_line(f, j3(prefix, rx(f, w.condition, 0), ":"))
            f.indent += 1
            emit_stmt_body(f, w.body)
            f.indent -= 1
        ast.Stmt.stmt_for as fr:
            var fprefix = ""
            if fr.threaded:
                fprefix = "parallel "
            if fr.is_inline:
                fprefix = j2(fprefix, "inline ")
            var names = vec.Vec[str].create()
            var fbi: ptr_uint = 0
            while fbi < fr.bindings.len:
                unsafe:
                    names.push(read(fr.bindings.data + fbi).name)
                fbi += 1
            let fheader = j6(fprefix, "for ", join_strs(names.as_span(), ", "), " in ", render_expr_span(f, fr.iterables, ", "), ":")
            emit_line(f, fheader)
            f.indent += 1
            emit_stmt_body(f, fr.body)
            f.indent -= 1
        ast.Stmt.stmt_match as m:
            let mprefix = if m.is_inline: "inline match " else: "match "
            emit_line(f, j3(mprefix, rx(f, m.scrutinee, 0), ":"))
            f.indent += 1
            var mi: ptr_uint = 0
            while mi < m.arms.len:
                var arm: ast.MatchArm
                unsafe:
                    arm = read(m.arms.data + mi)
                var mheader = render_pattern(f, arm.pattern)
                match arm.binding_name:
                    Option.some as bn:
                        mheader = j3(mheader, " as ", bn.value)
                    Option.none:
                        pass
                emit_line(f, j2(mheader, ":"))
                f.indent += 1
                emit_stmt_body(f, arm.body)
                f.indent -= 1
                mi += 1
            f.indent -= 1
        ast.Stmt.stmt_ret as r:
            let rv = r.value
            if rv != null:
                emit_line(f, j2("return ", rx(f, rv, 0)))
            else:
                emit_line(f, "return")
        ast.Stmt.stmt_break:
            emit_line(f, "break")
        ast.Stmt.stmt_continue:
            emit_line(f, "continue")
        ast.Stmt.stmt_pass:
            emit_line(f, "pass")
        ast.Stmt.stmt_defer as d:
            let dexpr = d.expression
            if dexpr != null:
                emit_line(f, j2("defer ", rx(f, dexpr, 0)))
            else:
                emit_line(f, "defer:")
                f.indent += 1
                emit_stmt_body(f, d.body)
                f.indent -= 1
        ast.Stmt.stmt_unsafe as u:
            match unsafe_inline(f, u.body):
                Option.some as inl:
                    emit_line(f, j2("unsafe: ", inl.value))
                Option.none:
                    emit_line(f, "unsafe:")
                    f.indent += 1
                    emit_stmt_body(f, u.body)
                    f.indent -= 1
        ast.Stmt.stmt_expression as e:
            emit_line(f, rx(f, e.expression, 0))
        ast.Stmt.stmt_static_assert as sa:
            emit_line(f, j5("static_assert(", rx(f, sa.condition, 0), ", ", rx_opt(f, sa.message), ")"))
        ast.Stmt.stmt_emit as em:
            emit_emit(f, em.declaration)
        ast.Stmt.stmt_when as wn:
            emit_when_stmt(f, wn.discriminant, wn.branches, wn.else_body)
        ast.Stmt.stmt_parallel_block as pb:
            emit_line(f, "parallel:")
            f.indent += 1
            emit_stmt_span(f, pb.bodies)
            f.indent -= 1
        ast.Stmt.stmt_gather as g:
            emit_line(f, j2("gather ", render_expr_span(f, g.handles, ", ")))
        _:
            pass


function render_destructure_target(bindings: span[str], type_name: Option[str]) -> str:
    let names = join_strs(bindings, ", ")
    match type_name:
        Option.some as tn:
            return j4(tn.value, "(", names, ")")
        Option.none:
            return j3("(", names, ")")


function render_pattern(f: ref[Formatter], pattern: ptr[ast.Expr]?) -> str:
    let p = pattern else:
        return "_"
    return rx(f, p, 0)


## If `body` is a block wrapping exactly one inline-renderable statement (or is
## itself such a statement), return its single-line rendering; otherwise none.
## Used to collapse single-statement `unsafe:` blocks to `unsafe: <stmt>`.
function unsafe_inline(f: ref[Formatter], body: ptr[ast.Stmt]?) -> Option[str]:
    let b = body else:
        return Option[str].none
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                if blk.statements.len == 1:
                    return render_inline_stmt(f, read(blk.statements.data + 0))
                return Option[str].none
            _:
                return render_inline_stmt(f, read(b))


function render_inline_stmt(f: ref[Formatter], st: ast.Stmt) -> Option[str]:
    match st:
        ast.Stmt.stmt_assignment as a:
            return Option[str].some(value = j5(rx(f, a.target, 0), " ", a.operator, " ", rx(f, a.value, 0)))
        ast.Stmt.stmt_expression as e:
            return Option[str].some(value = rx(f, e.expression, 0))
        ast.Stmt.stmt_ret as r:
            let rv = r.value
            if rv != null:
                return Option[str].some(value = j2("return ", rx(f, rv, 0)))
            return Option[str].some(value = "return")
        ast.Stmt.stmt_pass:
            return Option[str].some(value = "pass")
        ast.Stmt.stmt_break:
            return Option[str].some(value = "break")
        ast.Stmt.stmt_continue:
            return Option[str].some(value = "continue")
        ast.Stmt.stmt_static_assert as sa:
            return Option[str].some(value = j5("static_assert(", rx(f, sa.condition, 0), ", ", rx_opt(f, sa.message), ")"))
        ast.Stmt.stmt_defer as d:
            let de = d.expression
            if de != null:
                return Option[str].some(value = j2("defer ", rx(f, de, 0)))
            return Option[str].none
        _:
            return Option[str].none


function emit_emit(f: ref[Formatter], declaration: ptr[ast.Decl]?) -> void:
    let decl = declaration else:
        return
    let before = f.buffer.len()
    unsafe:
        emit_declaration(f, read(decl))
    splice_emit_prefix(f, before)


## Insert "emit " immediately after the indentation of the first line written
## since `start_offset`.
function splice_emit_prefix(f: ref[Formatter], start_offset: ptr_uint) -> void:
    let full = f.buffer.as_str()
    if start_offset >= full.len:
        return
    var pos = start_offset
    while pos < full.len and full.byte_at(pos) == 32:
        pos += 1
    var rebuilt = string.String.create()
    rebuilt.append(full.slice(0, pos))
    rebuilt.append("emit ")
    rebuilt.append(full.slice(pos, full.len - pos))
    f.buffer = rebuilt


function emit_when_stmt(f: ref[Formatter], discriminant: ptr[ast.Expr], branches: span[ast.WhenBranch], else_body: ptr[ast.Stmt]?) -> void:
    emit_line(f, j3("when ", rx(f, discriminant, 0), ":"))
    f.indent += 1
    var i: ptr_uint = 0
    while i < branches.len:
        var br: ast.WhenBranch
        unsafe:
            br = read(branches.data + i)
        var header = rx(f, br.pattern, 0)
        match br.binding_name:
            Option.some as bn:
                header = j3(header, " as ", bn.value)
            Option.none:
                pass
        emit_line(f, j2(header, ":"))
        f.indent += 1
        emit_stmt_span(f, br.body)
        f.indent -= 1
        i += 1
    let eb = else_body
    if eb != null:
        var is_empty = false
        unsafe:
            match read(eb):
                ast.Stmt.stmt_block as blk:
                    if blk.statements.len == 0:
                        is_empty = true
                _:
                    pass
        if not is_empty:
            emit_line(f, "else:")
            f.indent += 1
            emit_stmt_body(f, eb)
            f.indent -= 1
    f.indent -= 1


# =============================================================================
#  Expressions
# =============================================================================

function rx(f: ref[Formatter], ep: ptr[ast.Expr], parent: int) -> str:
    unsafe:
        return render_expression(f, read(ep), parent)


function rx_opt(f: ref[Formatter], ep: ptr[ast.Expr]?) -> str:
    let p = ep else:
        return ""
    return rx(f, p, 0)


function render_expr_span(f: ref[Formatter], exprs: span[ast.Expr], sep: str) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < exprs.len:
        if i > 0:
            buf.append(sep)
        unsafe:
            buf.append(render_expression(f, read(exprs.data + i), 0))
        i += 1
    return buf.as_str()


function render_expression(f: ref[Formatter], e: ast.Expr, parent: int) -> str:
    match e:
        ast.Expr.expr_identifier as x:
            return x.name
        ast.Expr.expr_integer_literal as x:
            return x.lexeme
        ast.Expr.expr_float_literal as x:
            return x.lexeme
        ast.Expr.expr_string_literal as x:
            return x.lexeme
        ast.Expr.expr_char_literal as x:
            return x.lexeme
        ast.Expr.expr_bool_literal as x:
            return if x.value: "true" else: "false"
        ast.Expr.expr_null_literal as x:
            let tt = x.target_type
            if tt != null:
                return j3("null[", render_type_ptr(tt), "]")
            return "null"
        ast.Expr.expr_binary_op as x:
            let cur = precedence(x.operator)
            let left = rx(f, x.left, cur)
            let right = rx(f, x.right, cur + 1)
            return wrap(j5(left, " ", x.operator, " ", right), parent, cur)
        ast.Expr.expr_unary_op as x:
            if x.operator == "?":
                return wrap(j2(render_postfix(f, x.operand), "?"), parent, POSTFIX_PRECEDENCE)
            let operand = rx(f, x.operand, UNARY_PRECEDENCE)
            var utext = ""
            if x.operator == "not" or x.operator == "out" or x.operator == "in" or x.operator == "inout":
                utext = j3(x.operator, " ", operand)
            else:
                utext = j2(x.operator, operand)
            return wrap(utext, parent, UNARY_PRECEDENCE)
        ast.Expr.expr_member_access as x:
            return wrap(j3(render_postfix(f, x.receiver), ".", x.member_name), parent, POSTFIX_PRECEDENCE)
        ast.Expr.expr_index_access as x:
            return wrap(j4(render_postfix(f, x.receiver), "[", rx(f, x.index, 0), "]"), parent, POSTFIX_PRECEDENCE)
        ast.Expr.expr_specialization as x:
            return wrap(j4(render_postfix(f, x.callee), "[", render_type_argument_list(x.arguments), "]"), parent, POSTFIX_PRECEDENCE)
        ast.Expr.expr_call as x:
            return wrap(j4(render_postfix(f, x.callee), "(", render_argument_list(f, x.args), ")"), parent, POSTFIX_PRECEDENCE)
        ast.Expr.expr_prefix_cast as x:
            return wrap(j3(render_type_ptr(x.target_type), "<-", rx(f, x.expression, UNARY_PRECEDENCE)), parent, UNARY_PRECEDENCE)
        ast.Expr.expr_range as x:
            return j3(rx(f, x.start_expr, 0), "..", rx(f, x.end_expr, 0))
        ast.Expr.expr_expression_list as x:
            return j3("(", render_expr_span(f, x.elements, ", "), ")")
        ast.Expr.expr_named as x:
            return j3(x.name, " = ", rx(f, x.value, 0))
        ast.Expr.expr_if as x:
            let c = rx(f, x.condition, IF_EXPRESSION_PRECEDENCE)
            let t = rx(f, x.then_expr, IF_EXPRESSION_PRECEDENCE)
            let el = rx(f, x.else_expr, IF_EXPRESSION_PRECEDENCE)
            return wrap(j6("if ", c, ": ", t, " else: ", el), parent, IF_EXPRESSION_PRECEDENCE)
        ast.Expr.expr_match as x:
            return render_match_expr(f, x.scrutinee, x.arms, parent)
        ast.Expr.expr_unsafe as x:
            return wrap(j2("unsafe: ", rx(f, x.expression, IF_EXPRESSION_PRECEDENCE)), parent, IF_EXPRESSION_PRECEDENCE)
        ast.Expr.expr_proc as x:
            let params = render_param_list(x.method_params)
            let ret = render_type_ptr(x.return_type)
            let single = proc_single_return_value(x.body)
            if single != null:
                return wrap(j6("proc(", params, ") -> ", ret, ": ", rx(f, single, IF_EXPRESSION_PRECEDENCE)), parent, IF_EXPRESSION_PRECEDENCE)
            let body_lines = render_block_lines(f, x.body, f.indent + 1)
            return j6("proc(", params, ") -> ", ret, ":\n", body_lines)
        ast.Expr.expr_await as x:
            return wrap(j2("await ", rx(f, x.expression, UNARY_PRECEDENCE)), parent, UNARY_PRECEDENCE)
        ast.Expr.expr_detach as x:
            return wrap(j2("detach ", rx(f, x.expression, UNARY_PRECEDENCE)), parent, UNARY_PRECEDENCE)
        ast.Expr.expr_sizeof as x:
            return j3("size_of(", render_type_ptr(x.target_type), ")")
        ast.Expr.expr_alignof as x:
            return j3("align_of(", render_type_ptr(x.target_type), ")")
        ast.Expr.expr_offsetof as x:
            return j5("offset_of(", render_type_ptr(x.target_type), ", ", x.field, ")")
        _:
            return ""


function render_postfix(f: ref[Formatter], ep: ptr[ast.Expr]) -> str:
    unsafe:
        if postfix_expression(read(ep)):
            return render_expression(f, read(ep), POSTFIX_PRECEDENCE)
        return j3("(", render_expression(f, read(ep), 0), ")")


function postfix_expression(e: ast.Expr) -> bool:
    match e:
        ast.Expr.expr_identifier:
            return true
        ast.Expr.expr_member_access:
            return true
        ast.Expr.expr_index_access:
            return true
        ast.Expr.expr_specialization:
            return true
        ast.Expr.expr_call:
            return true
        ast.Expr.expr_unary_op as u:
            return u.operator == "?"
        _:
            return false


function render_type_argument_list(args: span[ast.TypeArgument]) -> str:
    var buf = string.String.create()
    var i: ptr_uint = 0
    while i < args.len:
        if i > 0:
            buf.append(", ")
        unsafe:
            buf.append(render_type_ptr(read(args.data + i).value))
        i += 1
    return buf.as_str()


function render_match_expr(f: ref[Formatter], scrutinee: ptr[ast.Expr], arms: span[ast.MatchExprArm], parent: int) -> str:
    let sugared = render_is_expression(f, scrutinee, arms, parent)
    if sugared.len > 0:
        return sugared
    let scrutinee_text = rx(f, scrutinee, IF_EXPRESSION_PRECEDENCE)
    let arm_indent = indent_str(f.indent + 1)
    var buf = string.String.create()
    buf.append("match ")
    buf.append(scrutinee_text)
    buf.append(":")
    var i: ptr_uint = 0
    while i < arms.len:
        var arm: ast.MatchExprArm
        unsafe:
            arm = read(arms.data + i)
        buf.append("\n")
        buf.append(arm_indent)
        buf.append(render_pattern(f, arm.pattern))
        match arm.binding_name:
            Option.some as bn:
                buf.append(" as ")
                buf.append(bn.value)
            Option.none:
                pass
        buf.append(": ")
        buf.append(rx(f, arm.value, IF_EXPRESSION_PRECEDENCE))
        i += 1
    return buf.as_str()


function render_block_lines(f: ref[Formatter], body: ptr[ast.Stmt], indent: ptr_uint) -> str:
    var sub = Formatter(
        buffer = string.String.create(),
        indent = indent,
        module_kind = f.module_kind,
        any_output = false,
        last_blank = false,
    )
    emit_stmt_body(ref_of(sub), body)
    let raw = sub.buffer.as_str()
    if raw.len > 0 and raw.byte_at(raw.len - 1) == 10:
        return raw.slice(0, raw.len - 1)
    return raw


function proc_single_return_value(body: ptr[ast.Stmt]) -> ptr[ast.Expr]?:
    unsafe:
        match read(body):
            ast.Stmt.stmt_ret as r:
                return r.value
            ast.Stmt.stmt_block as b:
                if b.statements.len == 1:
                    match read(b.statements.data + 0):
                        ast.Stmt.stmt_ret as r2:
                            return r2.value
                        _:
                            return null
                return null
            _:
                return null


# =============================================================================
#  `is` re-sugaring
# =============================================================================

function render_is_expression(f: ref[Formatter], scrutinee: ptr[ast.Expr], arms: span[ast.MatchExprArm], parent: int) -> str:
    if arms.len != 2:
        return ""
    var first: ast.MatchExprArm
    var second: ast.MatchExprArm
    unsafe:
        first = read(arms.data + 0)
        second = read(arms.data + 1)
    match first.binding_name:
        Option.some:
            return ""
        Option.none:
            pass
    match second.binding_name:
        Option.some:
            return ""
        Option.none:
            pass
    if not is_bool_literal(first.value, true):
        return ""
    if not is_bool_literal(second.value, false):
        return ""
    if not is_wildcard_pattern(second.pattern):
        return ""
    let first_pat = first.pattern else:
        return ""
    let scrutinee_text = rx(f, scrutinee, IS_PRECEDENCE)
    let arm = rx(f, first_pat, IS_PRECEDENCE)
    return wrap(j3(scrutinee_text, " is ", arm), parent, IS_PRECEDENCE)


function is_bool_literal(ep: ptr[ast.Expr], want: bool) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_bool_literal as b:
                return b.value == want
            _:
                return false


function is_wildcard_pattern(pattern: ptr[ast.Expr]?) -> bool:
    let p = pattern else:
        return true
    unsafe:
        match read(p):
            ast.Expr.expr_identifier as id:
                return id.name == "_"
            _:
                return false


# =============================================================================
#  Integer to string
# =============================================================================

function int_to_str(value: int) -> str:
    if value == 0:
        return "0"
    var negative = value < 0
    var n = value
    if negative:
        n = -n
    var digits = string.String.create()
    while n > 0:
        digits.append(digit_str(n % 10))
        n = n / 10
    var rev = string.String.create()
    let raw = digits.as_str()
    var i = raw.len
    while i > 0:
        i -= 1
        rev.append(raw.slice(i, 1))
    if negative:
        return j2("-", rev.as_str())
    return rev.as_str()


function digit_str(d: int) -> str:
    if d == 1:
        return "1"
    if d == 2:
        return "2"
    if d == 3:
        return "3"
    if d == 4:
        return "4"
    if d == 5:
        return "5"
    if d == 6:
        return "6"
    if d == 7:
        return "7"
    if d == 8:
        return "8"
    if d == 9:
        return "9"
    return "0"
