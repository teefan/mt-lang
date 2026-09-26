## Document symbols — the host's DocumentSymbol tree: declaration symbols in
## source order with the host's kinds, name-token ranges, `detail` text and
## children (fields, enum members, variant arms, methods and function locals).

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.pretty_printer.ast_formatter as ast_formatter
import mtc.semantic.analyzer as analyzer
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.type_render as type_render
import mtc.lsp.uri as uri_ops
import mtc.lsp.utils as utils
import mtc.lsp.workspace as workspace


## LSP SymbolKind values, matching the host's numbering.
const SYMBOLKIND_FUNCTION:    int = 12
const SYMBOLKIND_STRUCT:      int = 23
const SYMBOLKIND_ENUM:        int = 10
const SYMBOLKIND_VARIABLE:    int = 13
const SYMBOLKIND_CONST:       int = 14
const SYMBOLKIND_INTERFACE:   int = 11
const SYMBOLKIND_EVENT:       int = 24
const SYMBOLKIND_METHOD:      int = 6
const SYMBOLKIND_FIELD:       int = 8
const SYMBOLKIND_ENUM_MEMBER: int = 22
const SYMBOLKIND_CLASS:       int = 5


public function handle_document_symbols(ws: ref[workspace.Workspace], uri: str, id: json.Value) -> void:
    var owned_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_error(id, -32602, "invalid uri")
        return
    defer: owned_path.release()

    var content = ws.document_source(owned_path.as_str()) else:
        proto.write_error(id, -32800, "symbol request failed: could not read file")
        return
    defer: content.release()

    let source = content.as_str()
    if source.len == 0:
        proto.write_error(id, -32800, "symbol request failed: empty file")
        return

    # A file that is mid-edit usually has parse errors; the host still reports
    # the symbols it could parse, so the outline stays usable while typing.
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))

    # The loader-backed analysis binds imported modules, so a local's inferred
    # type resolves through them (`Vec[int]`); the single-file analysis is the
    # fallback when the document cannot be loaded.
    var maybe_analysis = workspace.analysis_for(ws, owned_path.as_str())
    var analysis = if maybe_analysis.is_some(): maybe_analysis.unwrap() else: analyzer.check_source_file(ast_file)
    # The loader parses its own AST and `resolved_expr_types` is keyed by
    # expression pointer, so the walk must use the tree the analysis was built
    # from when the loader path succeeded.
    if maybe_analysis.is_some():
        ast_file = analysis.source_file

    var json_text = string.String.create()
    defer: json_text.release()
    json_text.append("[")
    var first = true
    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        emit_declaration_symbol(ref_of(json_text), ref_of(analysis), source, decl, ref_of(first))
        di += 1
    json_text.append("]")
    proto.write_response_raw(id, json_text.as_str())


## Emit one declaration symbol, with its children where the host has them.
function emit_declaration_symbol(
    json_out: ref[string.String],
    analysis: ref[analyzer.Analysis],
    source: str,
    decl: ast.Decl,
    first: ref[bool],
) -> void:
    match decl:
        ast.Decl.decl_function as fun:
            var children = collect_body_locals(analysis, fun.body)
            var detail = string.String.create()
            append_callable_detail(ref_of(detail), fun.is_const, fun.is_async, fun.return_type)
            emit_symbol(json_out, fun.name, SYMBOLKIND_FUNCTION, fun.line, fun.column, detail.as_str(), ref_of(children), first)
            detail.release()
        ast.Decl.decl_const as c:
            var children = vec.Vec[string.String].create()
            if c.block_body != null:
                children = collect_body_locals(analysis, c.block_body)
            var detail = string.String.create()
            append_ast_type(ref_of(detail), c.const_type, "")
            emit_symbol(json_out, c.name, SYMBOLKIND_CONST, c.line, c.column, detail.as_str(), ref_of(children), first)
            detail.release()
        ast.Decl.decl_var as v:
            var detail = string.String.create()
            append_ast_type(ref_of(detail), v.var_type, "")
            var no_children = vec.Vec[string.String].create()
            emit_symbol(json_out, v.name, SYMBOLKIND_VARIABLE, v.line, v.column, detail.as_str(), ref_of(no_children), first)
            detail.release()
        ast.Decl.decl_struct as s:
            var children = collect_type_member_children(analysis, s.struct_fields, s.struct_events, s.nested_types)
            var detail = string.String.create()
            append_type_decl_detail(ref_of(detail), s.impl_list, null, s.type_params)
            emit_symbol(json_out, s.name, SYMBOLKIND_STRUCT, s.line, s.column, detail.as_str(), ref_of(children), first)
            detail.release()
        ast.Decl.decl_union as u:
            var children = collect_field_children(analysis, u.union_fields)
            var detail = string.String.create()
            var no_impls = span[ast.QualifiedName]()
            var no_params = span[ast.TypeParam]()
            append_type_decl_detail(ref_of(detail), no_impls, null, no_params)
            emit_symbol(json_out, u.name, SYMBOLKIND_STRUCT, u.line, u.column, detail.as_str(), ref_of(children), first)
            detail.release()
        ast.Decl.decl_enum as e:
            var children = collect_enum_children(e.enum_members)
            var detail = string.String.create()
            append_type_decl_detail(ref_of(detail), span[ast.QualifiedName](), e.backing_type, span[ast.TypeParam]())
            emit_symbol(json_out, e.name, SYMBOLKIND_ENUM, e.line, e.column, detail.as_str(), ref_of(children), first)
            detail.release()
        ast.Decl.decl_flags as fl:
            var children = collect_enum_children(fl.flags_members)
            var detail = string.String.create()
            append_type_decl_detail(ref_of(detail), span[ast.QualifiedName](), fl.backing_type, span[ast.TypeParam]())
            emit_symbol(json_out, fl.name, SYMBOLKIND_ENUM, fl.line, fl.column, detail.as_str(), ref_of(children), first)
            detail.release()
        ast.Decl.decl_variant as vr:
            var children = collect_variant_children(vr.variant_arms, vr.line)
            var detail = string.String.create()
            append_type_decl_detail(ref_of(detail), span[ast.QualifiedName](), null, vr.type_params)
            emit_symbol(json_out, vr.name, SYMBOLKIND_STRUCT, vr.line, vr.column, detail.as_str(), ref_of(children), first)
            detail.release()
        ast.Decl.decl_interface as iface:
            var children = collect_interface_children(iface.interface_methods)
            var detail = string.String.create()
            emit_symbol(json_out, iface.name, SYMBOLKIND_INTERFACE, iface.line, iface.column, detail.as_str(), ref_of(children), first)
            detail.release()
        ast.Decl.decl_extending_block as ext:
            var children = collect_extending_children(analysis, ext.methods)
            var no_detail = string.String.create()
            let type_name = last_name_part(ext.type_name)
            var column: ptr_uint = 0
            match cursor.token_start_in_line(utils.source_line(source, ext.line), type_name):
                Option.some as pos:
                    column = pos.value + 1
                Option.none:
                    pass
            emit_symbol(json_out, type_name, SYMBOLKIND_STRUCT, ext.line, column, "implementation", ref_of(children), first)
            no_detail.release()
        ast.Decl.decl_type_alias as ta:
            var detail = string.String.create()
            detail.append("= ")
            append_ast_type(ref_of(detail), ta.target, "")
            var no_children = vec.Vec[string.String].create()
            emit_symbol(json_out, ta.name, SYMBOLKIND_CLASS, ta.line, ta.column, detail.as_str(), ref_of(no_children), first)
            detail.release()
        ast.Decl.decl_opaque as op:
            var no_children = vec.Vec[string.String].create()
            emit_symbol(json_out, op.name, SYMBOLKIND_STRUCT, op.line, op.column, "", ref_of(no_children), first)
        ast.Decl.decl_event as ev:
            var detail = string.String.create()
            detail.append_format(f"event[#{ev.capacity}]")
            if ev.payload_type != null:
                detail.append("(")
                append_ast_type(ref_of(detail), ev.payload_type, "")
                detail.append(")")
            var no_children = vec.Vec[string.String].create()
            emit_symbol(json_out, ev.name, SYMBOLKIND_EVENT, ev.line, ev.column, detail.as_str(), ref_of(no_children), first)
            detail.release()
        ast.Decl.decl_extern_function as ef:
            var detail = string.String.create()
            append_callable_detail(ref_of(detail), false, false, null)
            var no_children = vec.Vec[string.String].create()
            let column = token_column(source, ef.line, ef.name)
            emit_symbol(json_out, ef.name, SYMBOLKIND_FUNCTION, ef.line, column, detail.as_str(), ref_of(no_children), first)
            detail.release()
        ast.Decl.decl_foreign_function as ff:
            var detail = string.String.create()
            detail.append("-> ")
            append_ast_type(ref_of(detail), ff.return_type, "void")
            var no_children = vec.Vec[string.String].create()
            let column = token_column(source, ff.line, ff.name)
            emit_symbol(json_out, ff.name, SYMBOLKIND_FUNCTION, ff.line, column, detail.as_str(), ref_of(no_children), first)
            detail.release()
        _:
            pass


## Emit one symbol whose range and selectionRange are the name-token span,
## followed by its children (which it releases).
function emit_symbol(
    json_out: ref[string.String],
    name: str,
    kind: int,
    line: ptr_uint,
    column: ptr_uint,
    detail: str,
    children: ref[vec.Vec[string.String]],
    first: ref[bool],
) -> void:
    if not unsafe: read(first):
        json_out.append(",")
    unsafe: read(first) = false
    let lz = if line > 0: line - 1 else: 0z
    let cz = if column > 0: column - 1 else: 0z
    json_out.append("{\"name\":\"")
    proto.append_escaped(json_out, name)
    json_out.append("\",\"kind\":")
    json_out.append_format(f"#{kind}")
    json_out.append(",\"range\":")
    append_span(json_out, lz, cz, cz + name.len)
    json_out.append(",\"selectionRange\":")
    append_span(json_out, lz, cz, cz + name.len)
    if detail.len > 0:
        json_out.append(",\"detail\":\"")
        proto.append_escaped(json_out, detail)
        json_out.append("\"")
    if children.len() > 0:
        json_out.append(",\"children\":[")
        var ci: ptr_uint = 0
        while ci < children.len():
            let cp = children.get(ci) else:
                break
            if ci > 0:
                json_out.append(",")
            json_out.append(unsafe: read(cp).as_str())
            ci += 1
        json_out.append("]")
    json_out.append("}")
    release_symbol_strings(children)


## Emit one child symbol spanning its declaration line (`{line-1,0}-{line,0}`)
## with the name-token selectionRange.
function render_block_symbol(
    name: str,
    kind: int,
    line: ptr_uint,
    column: ptr_uint,
    detail: str,
) -> string.String:
    var result = string.String.create()
    let lz = if line > 0: line - 1 else: 0z
    let cz = if column > 0: column - 1 else: 0z
    result.append("{\"name\":\"")
    proto.append_escaped(ref_of(result), name)
    result.append("\",\"kind\":")
    result.append_format(f"#{kind}")
    result.append(",\"range\":{\"start\":{\"line\":")
    result.append_format(f"#{lz}")
    result.append(",\"character\":0},\"end\":{\"line\":")
    result.append_format(f"#{line}")
    result.append(",\"character\":0}}")
    result.append(",\"selectionRange\":")
    append_span(ref_of(result), lz, cz, cz + name.len)
    if detail.len > 0:
        result.append(",\"detail\":\"")
        proto.append_escaped(ref_of(result), detail)
        result.append("\"")
    result.append("}")
    return result


## Emit one symbol whose range and selectionRange are both the name-token
## span (top-level declarations and locals).
function render_name_span_symbol(
    name: str,
    kind: int,
    line: ptr_uint,
    column: ptr_uint,
    detail: str,
) -> string.String:
    var result = string.String.create()
    let lz = if line > 0: line - 1 else: 0z
    let cz = if column > 0: column - 1 else: 0z
    result.append("{\"name\":\"")
    proto.append_escaped(ref_of(result), name)
    result.append("\",\"kind\":")
    result.append_format(f"#{kind}")
    result.append(",\"range\":")
    append_span(ref_of(result), lz, cz, cz + name.len)
    result.append(",\"selectionRange\":")
    append_span(ref_of(result), lz, cz, cz + name.len)
    if detail.len > 0:
        result.append(",\"detail\":\"")
        proto.append_escaped(ref_of(result), detail)
        result.append("\"")
    result.append("}")
    return result


## Emit one variant-arm symbol: the host reports it on the variant's line.
function render_arm_symbol(name: str, variant_line: ptr_uint, detail: str) -> string.String:
    var result = string.String.create()
    let lz = if variant_line > 0: variant_line - 1 else: 0z
    result.append("{\"name\":\"")
    proto.append_escaped(ref_of(result), name)
    result.append("\",\"kind\":")
    result.append_format(f"#{SYMBOLKIND_ENUM_MEMBER}")
    result.append(",\"range\":{\"start\":{\"line\":")
    result.append_format(f"#{lz}")
    result.append(",\"character\":0},\"end\":{\"line\":")
    result.append_format(f"#{variant_line}")
    result.append(",\"character\":0}}")
    result.append(",\"selectionRange\":")
    append_span(ref_of(result), lz, 0, name.len)
    if detail.len > 0:
        result.append(",\"detail\":\"")
        proto.append_escaped(ref_of(result), detail)
        result.append("\"")
    result.append("}")
    return result


function append_span(json_out: ref[string.String], line: ptr_uint, start_char: ptr_uint, end_char: ptr_uint) -> void:
    json_out.append("{\"start\":{\"line\":")
    json_out.append_format(f"#{line}")
    json_out.append(",\"character\":")
    json_out.append_format(f"#{start_char}")
    json_out.append("},\"end\":{\"line\":")
    json_out.append_format(f"#{line}")
    json_out.append(",\"character\":")
    json_out.append_format(f"#{end_char}")
    json_out.append("}}")


function release_symbol_strings(symbols: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < symbols.len():
        let sp = symbols.get(i) else:
            break
        unsafe:
            read(sp).release()
        i += 1
    symbols.release()


## `(impls)` and `: backing` and `[generics]`, joined — the host's type-decl
## detail parts.
function append_type_decl_detail(
    target: ref[string.String],
    impl_list: span[ast.QualifiedName],
    backing_type: ptr[ast.TypeRef]?,
    type_params: span[ast.TypeParam],
) -> void:
    if impl_list.len > 0:
        target.append("(")
        var ii: ptr_uint = 0
        while ii < impl_list.len:
            if ii > 0:
                target.append(", ")
            let iface = unsafe: read(impl_list.data + ii)
            var part = string.String.create()
            var pi: ptr_uint = 0
            while pi < iface.parts.len:
                if pi > 0:
                    part.append(".")
                unsafe:
                    part.append(read(iface.parts.data + pi))
                pi += 1
            target.append(part.as_str())
            part.release()
            ii += 1
        target.append(")")
    if backing_type != null:
        target.append(": ")
        append_ast_type(target, backing_type, "")
    if type_params.len > 0:
        target.append("[")
        var ti: ptr_uint = 0
        while ti < type_params.len:
            if ti > 0:
                target.append(", ")
            target.append(unsafe: read(type_params.data + ti).name)
            ti += 1
        target.append("]")


## `const`/`async` prefixes plus `-> ret`, the host's callable detail.
function append_callable_detail(
    target: ref[string.String],
    is_const: bool,
    is_async: bool,
    return_type: ptr[ast.TypeRef]?,
) -> void:
    if is_const:
        target.append("const ")
    if is_async:
        target.append("async ")
    target.append("-> ")
    append_ast_type(target, return_type, "void")


## Append a rendered TypeRef, or `fallback` when absent.
function append_ast_type(target: ref[string.String], type_ref: ptr[ast.TypeRef]?, fallback: str) -> void:
    let tp = type_ref else:
        target.append(fallback)
        return
    target.append(ast_formatter.render_type(unsafe: read(tp)))


## The last part of a possibly-qualified type name (`extending a.B:` → `B`).
function last_name_part(type_name: ptr[ast.TypeRef]?) -> str:
    let tp = type_name else:
        return ""
    let t = unsafe: read(tp)
    if t.name.parts.len == 0:
        return ""
    return unsafe: read(t.name.parts.data + t.name.parts.len - 1)


## The 1-based column of `name` on `line`, or 0 — extern/foreign declarations
## carry no column in the AST, so it is recovered from the token as the host does.
function token_column(source: str, line: ptr_uint, name: str) -> ptr_uint:
    match cursor.token_start_in_line(utils.source_line(source, line), name):
        Option.some as col:
            return col.value + 1
        Option.none:
            return 0


## Field children (kind 8) for a struct or union.
function collect_field_children(analysis: ref[analyzer.Analysis], fields: span[ast.Field]) -> vec.Vec[string.String]:
    var children = vec.Vec[string.String].create()
    var fi: ptr_uint = 0
    while fi < fields.len:
        let field = unsafe: read(fields.data + fi)
        var detail = string.String.create()
        detail.append(ast_formatter.render_type(field.field_type))
        children.push(render_block_symbol(field.name, SYMBOLKIND_FIELD, field.line, field.column, detail.as_str()))
        detail.release()
        fi += 1
    return children


## The members of a struct: fields, nested types and events, in the host's
## child order (fields first).
function collect_type_member_children(
    analysis: ref[analyzer.Analysis],
    fields: span[ast.Field],
    events: span[ast.Decl],
    nested: span[ast.Decl],
) -> vec.Vec[string.String]:
    var children = collect_field_children(analysis, fields)
    var ei: ptr_uint = 0
    while ei < events.len:
        var ev: ast.Decl
        unsafe:
            ev = read(events.data + ei)
        match ev:
            ast.Decl.decl_event as e:
                var detail = string.String.create()
                detail.append_format(f"event[#{e.capacity}]")
                if e.payload_type != null:
                    detail.append("(")
                    append_ast_type(ref_of(detail), e.payload_type, "")
                    detail.append(")")
                children.push(render_block_symbol(e.name, SYMBOLKIND_EVENT, e.line, e.column, detail.as_str()))
                detail.release()
            _:
                pass
        ei += 1
    var ni: ptr_uint = 0
    while ni < nested.len:
        var nd: ast.Decl
        unsafe:
            nd = read(nested.data + ni)
        match nd:
            ast.Decl.decl_struct as s:
                var no_detail = string.String.create()
                children.push(render_block_symbol(s.name, SYMBOLKIND_STRUCT, s.line, s.column, no_detail.as_str()))
                no_detail.release()
            _:
                pass
        ni += 1
    return children


## Enum/flags member children (kind 22, no detail).
function collect_enum_children(members: span[ast.EnumMember]) -> vec.Vec[string.String]:
    var children = vec.Vec[string.String].create()
    var mi: ptr_uint = 0
    while mi < members.len:
        let member = unsafe: read(members.data + mi)
        children.push(render_block_symbol(member.name, SYMBOLKIND_ENUM_MEMBER, member.line, member.column, ""))
        mi += 1
    return children


## Variant-arm children, reported on the variant's line with a `(name: T)`
## payload detail.
function collect_variant_children(arms: span[ast.VariantArm], variant_line: ptr_uint) -> vec.Vec[string.String]:
    var children = vec.Vec[string.String].create()
    var ai: ptr_uint = 0
    while ai < arms.len:
        let arm = unsafe: read(arms.data + ai)
        var detail = string.String.create()
        if arm.arm_fields.len > 0:
            detail.append("(")
            var fi: ptr_uint = 0
            while fi < arm.arm_fields.len:
                if fi > 0:
                    detail.append(", ")
                let f = unsafe: read(arm.arm_fields.data + fi)
                detail.append(f.name)
                detail.append(": ")
                detail.append(ast_formatter.render_type(f.field_type))
                fi += 1
            detail.append(")")
        children.push(render_arm_symbol(arm.name, variant_line, detail.as_str()))
        detail.release()
        ai += 1
    return children


## Interface-method children (kind 6), with the host's method detail.
function collect_interface_children(methods: span[ast.InterfaceMethod]) -> vec.Vec[string.String]:
    var children = vec.Vec[string.String].create()
    var mi: ptr_uint = 0
    while mi < methods.len:
        let m = unsafe: read(methods.data + mi)
        var detail = string.String.create()
        append_method_detail(ref_of(detail), m.method_kind, m.is_async, m.return_type)
        children.push(render_block_symbol(m.name, SYMBOLKIND_METHOD, m.line, m.column, detail.as_str()))
        detail.release()
        mi += 1
    return children


## Extending-block method children (kind 6), each carrying its own locals.
function collect_extending_children(analysis: ref[analyzer.Analysis], methods: span[ast.Method]) -> vec.Vec[string.String]:
    var children = vec.Vec[string.String].create()
    var mi: ptr_uint = 0
    while mi < methods.len:
        let m = unsafe: read(methods.data + mi)
        var detail = string.String.create()
        append_method_detail(ref_of(detail), m.method_kind, m.is_async, m.return_type)
        var method_symbol = string.String.create()
        method_symbol.append("{\"name\":\"")
        proto.append_escaped(ref_of(method_symbol), m.name)
        method_symbol.append("\",\"kind\":")
        method_symbol.append_format(f"#{SYMBOLKIND_METHOD}")
        let lz = if m.line > 0: m.line - 1 else: 0z
        let cz = if m.column > 0: m.column - 1 else: 0z
        method_symbol.append(",\"range\":{\"start\":{\"line\":")
        method_symbol.append_format(f"#{lz}")
        method_symbol.append(",\"character\":0},\"end\":{\"line\":")
        method_symbol.append_format(f"#{m.line}")
        method_symbol.append(",\"character\":0}}")
        method_symbol.append(",\"selectionRange\":")
        append_span(ref_of(method_symbol), lz, cz, cz + m.name.len)
        if detail.len > 0:
            method_symbol.append(",\"detail\":\"")
            proto.append_escaped(ref_of(method_symbol), detail.as_str())
            method_symbol.append("\"")
        var locals = collect_body_locals(analysis, m.body)
        if locals.len() > 0:
            method_symbol.append(",\"children\":[")
            var li: ptr_uint = 0
            while li < locals.len():
                let lp = locals.get(li) else:
                    break
                if li > 0:
                    method_symbol.append(",")
                method_symbol.append(unsafe: read(lp).as_str())
                li += 1
            method_symbol.append("]")
        method_symbol.append("}")
        release_symbol_strings(ref_of(locals))
        children.push(method_symbol)
        detail.release()
        mi += 1
    return children


## `mut`/`static`/`async` prefixes plus `-> ret` for a method child.
function append_method_detail(
    target: ref[string.String],
    method_kind: ast.MethodKind,
    is_async: bool,
    return_type: ptr[ast.TypeRef]?,
) -> void:
    if method_kind == ast.MethodKind.mk_editable:
        target.append("mut ")
    else if method_kind == ast.MethodKind.mk_static:
        target.append("static ")
    if is_async:
        target.append("async ")
    target.append("-> ")
    append_ast_type(target, return_type, "void")


## The locals declared in a function/method body (kind 13, name-token range).
function collect_body_locals(analysis: ref[analyzer.Analysis], body: ptr[ast.Stmt]?) -> vec.Vec[string.String]:
    var children = vec.Vec[string.String].create()
    let b = body else:
        return children
    collect_stmt_locals(analysis, unsafe: read(b), ref_of(children))
    return children


function collect_stmt_locals(analysis: ref[analyzer.Analysis], stmt: ast.Stmt, children: ref[vec.Vec[string.String]]) -> void:
    match stmt:
        ast.Stmt.stmt_block as blk:
            var si: ptr_uint = 0
            while si < blk.statements.len:
                collect_stmt_locals(analysis, unsafe: read(blk.statements.data + si), children)
                si += 1
        ast.Stmt.stmt_local as loc:
            if loc.name.len > 0 and loc.name != "_":
                var detail = string.String.create()
                append_local_type(ref_of(detail), analysis, loc.stmt_type, loc.value)
                children.push(render_name_span_symbol(loc.name, SYMBOLKIND_VARIABLE, loc.line, loc.column, detail.as_str()))
                detail.release()
        ast.Stmt.stmt_if as iff:
            var ib: ptr_uint = 0
            while ib < iff.branches.len:
                let branch = unsafe: read(iff.branches.data + ib)
                collect_stmt_locals(analysis, unsafe: read(branch.body), children)
                ib += 1
            if iff.else_body != null:
                collect_stmt_locals(analysis, unsafe: read(ptr[ast.Stmt]<-iff.else_body), children)
        ast.Stmt.stmt_while as w:
            if w.body != null:
                collect_stmt_locals(analysis, unsafe: read(ptr[ast.Stmt]<-w.body), children)
        ast.Stmt.stmt_for as f:
            if f.body != null:
                collect_stmt_locals(analysis, unsafe: read(ptr[ast.Stmt]<-f.body), children)
        ast.Stmt.stmt_match as m:
            var ai: ptr_uint = 0
            while ai < m.arms.len:
                let arm = unsafe: read(m.arms.data + ai)
                if arm.body != null:
                    collect_stmt_locals(analysis, unsafe: read(ptr[ast.Stmt]<-arm.body), children)
                ai += 1
        _:
            pass


## A local's type text: the annotated type, else the analyzer's short form.
function append_local_type(
    target: ref[string.String],
    analysis: ref[analyzer.Analysis],
    stmt_type: ptr[ast.TypeRef]?,
    value: ptr[ast.Expr]?,
) -> void:
    if stmt_type != null:
        append_ast_type(target, stmt_type, "")
        return
    match type_render.initializer_type(analysis, value):
        Option.some as ty:
            var short_text = type_render.short_name(ty.value)
            target.append(short_text.as_str())
            short_text.release()
        Option.none:
            pass
