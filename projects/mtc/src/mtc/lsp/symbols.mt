## Document symbols — the host's DocumentSymbol tree: declaration symbols in
## source order with the host's kinds, name-token ranges, `detail` text and
## children (fields, enum members, variant arms, methods and function locals).

import std.fmt
import std.json as json
import std.path as path_ops
import std.str
import std.string as string
import std.vec as vec

import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.lexer.token_kinds as tk
import mtc.loader.package_manifest as package_manifest
import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.pretty_printer.ast_formatter as ast_formatter
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
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
const SYMBOLKIND_TYPE_PARAMETER: int = 26


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
    var symbols_text = string.String.create()
    defer: symbols_text.release()
    symbols_text.append("[")
    var first = true
    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        emit_declaration_symbol(ref_of(symbols_text), ref_of(analysis), source, decl, ref_of(first))
        di += 1
    append_missing_token_anchors(ref_of(symbols_text), source, ast_file, ref_of(first))
    symbols_text.append("]")

    # The host wraps the outline in its module hierarchy for a file that lives
    # under a package root (or the std tree) and whose module name has more than
    # one segment (`docs/data_structures.mt` -> `docs` -> `data_structures`).
    match outline_module_name(owned_path.as_str()):
        Option.some as module_name:
            append_module_wrapper(ref_of(json_text), module_name.value.as_str(), source, symbols_text.as_str())
        Option.none:
            json_text.append(symbols_text.as_str())
    proto.write_response_raw(id, json_text.as_str())


## The host's `resolve_outline_module_name`: the document's module name when it
## has more than one segment and the file lives under a package root (or the
## `std` tree).  Owned; the caller releases.
function outline_module_name(path: str) -> Option[string.String]:
    var relative: Option[string.String] = Option[string.String].none
    match package_manifest.package_source_root_for_path(path):
        Option.some as source_root:
            let root = source_root.value.as_str()
            if path_starts_with_dir(path, root):
                relative = Option[string.String].some(value = string.String.from_str(path.slice(root.len + 1, path.len - root.len - 1)))
            else:
                let package_dir = path_ops.dirname(root)
                if path_starts_with_dir(path, package_dir):
                    relative = Option[string.String].some(value = string.String.from_str(path.slice(package_dir.len + 1, path.len - package_dir.len - 1)))
        Option.none:
            pass
    match relative:
        Option.some as rel:
            var owned_rel = rel.value
            if not path_ends_with_mt(owned_rel.as_str()):
                owned_rel.release()
                return Option[string.String].none
            var name = module_name_from_relative(owned_rel.as_str())
            owned_rel.release()
            if module_name_segments(name.as_str()) > 1:
                return Option[string.String].some(value = name)
            name.release()
            return Option[string.String].none
        Option.none:
            pass
    return std_module_name(path)


## The module name of a file in the `std/` tree: relative to the `std` directory's
## parent, so `…/std/vec.mt` is `std.vec`.
function std_module_name(path: str) -> Option[string.String]:
    var i: ptr_uint = 0
    while i < path.len:
        if path.byte_at(i) == '/' and i + 5 <= path.len and path.slice(i + 1, 4).equal("std/") and i + 5 < path.len:
            var name = module_name_from_relative(path.slice(i + 1, path.len - i - 1))
            if module_name_segments(name.as_str()) > 1:
                return Option[string.String].some(value = name)
            name.release()
            return Option[string.String].none
        i += 1
    return Option[string.String].none


function path_starts_with_dir(path: str, dir: str) -> bool:
    if dir.len == 0 or path.len <= dir.len + 1:
        return false
    if not path.slice(0, dir.len).equal(dir):
        return false
    return path.byte_at(dir.len) == '/'


function path_ends_with_mt(path: str) -> bool:
    return path.len > 3 and path.slice(path.len - 3, 3).equal(".mt")


## A relative source path as a dotted module name (`docs/data.mt` -> `docs.data`).
function module_name_from_relative(relative: str) -> string.String:
    var name = string.String.create()
    var i: ptr_uint = 0
    while i < relative.len:
        let b = relative.byte_at(i)
        if b == '/':
            name.push_byte(46)
        else if b == '.' and i + 3 == relative.len and relative.slice(i, 3).equal(".mt"):
            break
        else:
            name.push_byte(b)
        i += 1
    return name


function module_name_segments(name: str) -> ptr_uint:
    var count: ptr_uint = 1
    var i: ptr_uint = 0
    while i < name.len:
        if name.byte_at(i) == '.':
            count += 1
        i += 1
    return count


## Wrap the outline in the module hierarchy: one `{name, kind: 2, range,
## selectionRange, children}` object per module segment, the innermost holding
## the symbols (the host's `wrap_in_module_hierarchy`; the range is the whole
## file, its end line the newline count).
function append_module_wrapper(json_out: ref[string.String], module_name: str, source: str, symbols_text: str) -> void:
    var segments = vec.Vec[str].create()
    defer: segments.release()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i <= module_name.len:
        if i == module_name.len or module_name.byte_at(i) == '.':
            segments.push(module_name.slice(start, i - start))
            start = i + 1
        i += 1

    var total_lines: ptr_uint = 0
    var li: ptr_uint = 0
    while li < source.len:
        if source.byte_at(li) == '\n':
            total_lines += 1
        li += 1

    json_out.append("[")
    var si: ptr_uint = 0
    while si < segments.len():
        let segment = segments.get(si) else:
            break
        json_out.append("{\"name\":\"")
        proto.append_escaped(json_out, unsafe: read(segment))
        json_out.append("\",\"kind\":2,\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":")
        json_out.append_format(f"#{total_lines}")
        json_out.append(",\"character\":0}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":")
        json_out.append_format(f"#{total_lines}")
        json_out.append(",\"character\":0}},\"children\":[")
        si += 1
    json_out.append(symbols_text.slice(1, symbols_text.len - 2))
    si = 0
    while si < segments.len():
        json_out.append("]}")
        si += 1
    json_out.append("]")


## The host's outline is anchored on `keyword identifier` token pairs, so a
## declaration the parser dropped (a file mid-edit, an unterminated source) still
## gets a symbol — without children or detail, because the host's enrichment has
## no AST declaration to attach.  Emit a bare symbol for every top-level anchor
## the AST walk above did not already produce; nested anchors are excluded (the
## host removes them from its token base via the AST's local/member sets).
function append_missing_token_anchors(
    json_out: ref[string.String],
    source: str,
    file: ast.SourceFile,
    first: ref[bool],
) -> void:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()
    var ti: ptr_uint = 0
    while ti + 1 < tokens.len:
        let kwp = tokens.get(ti) else:
            break
        let idp = tokens.get(ti + 1) else:
            break
        var kw: token_mod.Token
        var idt: token_mod.Token
        unsafe:
            kw = read(kwp)
            idt = read(idp)
        let kind = anchor_keyword_kind(kw.kind)
        if kind >= 0 and kw.column == 1 and idt.kind == tk.TokenKind.identifier:
            let name = token_mod.token_lexeme(idt, source)
            if name.len > 0 and not anchor_covered(file, name, idt.line):
                var no_detail = string.String.create()
                var no_children = vec.Vec[string.String].create()
                emit_symbol(json_out, name, kind, idt.line, idt.column, no_detail.as_str(), ref_of(no_children), false, first)
                no_detail.release()
        ti += 1


## The LSP SymbolKind for a host definition keyword, or -1 when the token is not
## one (host `DEFINITION_KEYWORDS`).
function anchor_keyword_kind(kind: tk.TokenKind) -> int:
    if kind == tk.TokenKind.tk_function:
        return SYMBOLKIND_FUNCTION
    if (
        kind == tk.TokenKind.tk_struct or kind == tk.TokenKind.tk_union
        or kind == tk.TokenKind.tk_variant or kind == tk.TokenKind.tk_opaque
        or kind == tk.TokenKind.tk_extending
    ):
        return SYMBOLKIND_STRUCT
    if kind == tk.TokenKind.tk_enum or kind == tk.TokenKind.tk_flags:
        return SYMBOLKIND_ENUM
    if kind == tk.TokenKind.tk_interface:
        return SYMBOLKIND_INTERFACE
    if kind == tk.TokenKind.tk_type:
        return SYMBOLKIND_CLASS
    if kind == tk.TokenKind.tk_const:
        return SYMBOLKIND_CONST
    if kind == tk.TokenKind.tk_var or kind == tk.TokenKind.tk_let:
        return SYMBOLKIND_VARIABLE
    if kind == tk.TokenKind.tk_event:
        return SYMBOLKIND_EVENT
    return -1


## True when a top-level declaration in `file` matches the token anchor `name` on
## `line` (the host's enrichment matches symbols by name and line).
function anchor_covered(file: ast.SourceFile, name: str, line: ptr_uint) -> bool:
    var i: ptr_uint = 0
    while i < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + i)
        match decl:
            ast.Decl.decl_function as d:
                if d.name == name and d.line == line:
                    return true
            ast.Decl.decl_const as d:
                if d.name == name and d.line == line:
                    return true
            ast.Decl.decl_var as d:
                if d.name == name and d.line == line:
                    return true
            ast.Decl.decl_struct as d:
                if d.name == name and d.line == line:
                    return true
            ast.Decl.decl_union as d:
                if d.name == name and d.line == line:
                    return true
            ast.Decl.decl_enum as d:
                if d.name == name and d.line == line:
                    return true
            ast.Decl.decl_flags as d:
                if d.name == name and d.line == line:
                    return true
            ast.Decl.decl_variant as d:
                if d.name == name and d.line == line:
                    return true
            ast.Decl.decl_interface as d:
                if d.name == name and d.line == line:
                    return true
            ast.Decl.decl_opaque as d:
                if d.name == name and d.line == line:
                    return true
            ast.Decl.decl_type_alias as d:
                if d.name == name and d.line == line:
                    return true
            ast.Decl.decl_event as d:
                if d.name == name and d.line == line:
                    return true
            ast.Decl.decl_extern_function as d:
                if d.name == name and d.line == line:
                    return true
            ast.Decl.decl_foreign_function as d:
                if d.name == name and d.line == line:
                    return true
            ast.Decl.decl_extending_block as d:
                if last_name_part(d.type_name) == name and d.line == line:
                    return true
            _:
                pass
        i += 1
    return false


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
            var detail = string.String.create()
            append_callable_detail(ref_of(detail), fun.is_const, fun.is_async, fun.return_type)
            var body_locals = collect_body_locals(analysis, fun.body)
            emit_symbol(json_out, fun.name, SYMBOLKIND_FUNCTION, fun.line, fun.column, detail.as_str(), ref_of(body_locals.symbols), body_locals.has_declarations, first)
            detail.release()
        ast.Decl.decl_const as c:
            var body_locals = BodyLocals(symbols = vec.Vec[string.String].create(), has_declarations = false)
            if c.block_body != null:
                body_locals = collect_body_locals(analysis, c.block_body)
            var detail = string.String.create()
            append_ast_type(ref_of(detail), c.const_type, "")
            emit_symbol(json_out, c.name, SYMBOLKIND_CONST, c.line, c.column, detail.as_str(), ref_of(body_locals.symbols), body_locals.has_declarations, first)
            detail.release()
        ast.Decl.decl_var as v:
            var detail = string.String.create()
            append_ast_type(ref_of(detail), v.var_type, "")
            var no_children = vec.Vec[string.String].create()
            emit_symbol(json_out, v.name, SYMBOLKIND_VARIABLE, v.line, v.column, detail.as_str(), ref_of(no_children), false, first)
            detail.release()
        ast.Decl.decl_struct as s:
            var children = collect_type_member_children_with_params(analysis, s.name, s.struct_fields, s.struct_events, s.nested_types, s.type_params)
            var detail = string.String.create()
            append_type_decl_detail(ref_of(detail), s.impl_list, null, s.type_params)
            emit_symbol(json_out, s.name, SYMBOLKIND_STRUCT, s.line, s.column, detail.as_str(), ref_of(children), false, first)
            detail.release()
        ast.Decl.decl_union as u:
            var children = collect_field_children(analysis, u.union_fields)
            var detail = string.String.create()
            var no_impls = span[ast.QualifiedName]()
            var no_params = span[ast.TypeParam]()
            append_type_decl_detail(ref_of(detail), no_impls, null, no_params)
            emit_symbol(json_out, u.name, SYMBOLKIND_STRUCT, u.line, u.column, detail.as_str(), ref_of(children), false, first)
            detail.release()
        ast.Decl.decl_enum as e:
            var children = collect_enum_children(e.enum_members)
            var detail = string.String.create()
            append_type_decl_detail(ref_of(detail), span[ast.QualifiedName](), e.backing_type, span[ast.TypeParam]())
            emit_symbol(json_out, e.name, SYMBOLKIND_ENUM, e.line, e.column, detail.as_str(), ref_of(children), false, first)
            detail.release()
        ast.Decl.decl_flags as fl:
            var children = collect_enum_children(fl.flags_members)
            var detail = string.String.create()
            append_type_decl_detail(ref_of(detail), span[ast.QualifiedName](), fl.backing_type, span[ast.TypeParam]())
            emit_symbol(json_out, fl.name, SYMBOLKIND_ENUM, fl.line, fl.column, detail.as_str(), ref_of(children), false, first)
            detail.release()
        ast.Decl.decl_variant as vr:
            var children = collect_variant_children(vr.variant_arms, vr.line)
            prepend_type_parameters(ref_of(children), vr.type_params)
            var detail = string.String.create()
            append_type_decl_detail(ref_of(detail), span[ast.QualifiedName](), null, vr.type_params)
            emit_symbol(json_out, vr.name, SYMBOLKIND_STRUCT, vr.line, vr.column, detail.as_str(), ref_of(children), false, first)
            detail.release()
        ast.Decl.decl_interface as iface:
            var children = collect_interface_children(iface.interface_methods)
            var detail = string.String.create()
            emit_symbol(json_out, iface.name, SYMBOLKIND_INTERFACE, iface.line, iface.column, detail.as_str(), ref_of(children), false, first)
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
            emit_symbol(json_out, type_name, SYMBOLKIND_STRUCT, ext.line, column, "implementation", ref_of(children), false, first)
            no_detail.release()
        ast.Decl.decl_type_alias as ta:
            var detail = string.String.create()
            detail.append("= ")
            append_ast_type(ref_of(detail), ta.target, "")
            var no_children = vec.Vec[string.String].create()
            emit_symbol(json_out, ta.name, SYMBOLKIND_CLASS, ta.line, ta.column, detail.as_str(), ref_of(no_children), false, first)
            detail.release()
        ast.Decl.decl_opaque as op:
            var no_children = vec.Vec[string.String].create()
            emit_symbol(json_out, op.name, SYMBOLKIND_STRUCT, op.line, op.column, "", ref_of(no_children), false, first)
        ast.Decl.decl_event as ev:
            var detail = string.String.create()
            detail.append_format(f"event[#{ev.capacity}]")
            if ev.payload_type != null:
                detail.append("(")
                append_ast_type(ref_of(detail), ev.payload_type, "")
                detail.append(")")
            var no_children = vec.Vec[string.String].create()
            emit_symbol(json_out, ev.name, SYMBOLKIND_EVENT, ev.line, ev.column, detail.as_str(), ref_of(no_children), false, first)
            detail.release()
        ast.Decl.decl_extern_function as ef:
            var detail = string.String.create()
            append_callable_detail(ref_of(detail), false, false, null)
            var no_children = vec.Vec[string.String].create()
            let column = token_column(source, ef.line, ef.name)
            emit_symbol(json_out, ef.name, SYMBOLKIND_FUNCTION, ef.line, column, detail.as_str(), ref_of(no_children), false, first)
            detail.release()
        ast.Decl.decl_foreign_function as ff:
            var detail = string.String.create()
            detail.append("-> ")
            append_ast_type(ref_of(detail), ff.return_type, "void")
            var no_children = vec.Vec[string.String].create()
            let column = token_column(source, ff.line, ff.name)
            emit_symbol(json_out, ff.name, SYMBOLKIND_FUNCTION, ff.line, column, detail.as_str(), ref_of(no_children), false, first)
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
    ## Emit an empty `children` array even with no child symbol: the host creates
    ## the key whenever the body declares a local, a discarded `let _` or a
    ## destructure included.
    force_children: bool,
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
    if children.len() > 0 or force_children:
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
## with the name-token selectionRange and the detail *before* the range, as the
## host's field/event child builders order their keys.
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
    if detail.len > 0:
        result.append(",\"detail\":\"")
        proto.append_escaped(ref_of(result), detail)
        result.append("\"")
    result.append(",\"range\":{\"start\":{\"line\":")
    result.append_format(f"#{lz}")
    result.append(",\"character\":0},\"end\":{\"line\":")
    result.append_format(f"#{line}")
    result.append(",\"character\":0}}")
    result.append(",\"selectionRange\":")
    append_span(ref_of(result), lz, cz, cz + name.len)
    result.append("}")
    return result


## Emit one method child (kind 6): the host's `child_method_symbol` keys its
## detail *after* the selection range, and its locals follow.
function render_method_symbol(
    name: str,
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
    result.append_format(f"#{SYMBOLKIND_METHOD}")
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


## Emit one local declaration (kind 13): the host's `local_decl_symbol` puts the
## detail before the range and the name-token span in both ranges.
function render_local_symbol(
    name: str,
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
    result.append_format(f"#{SYMBOLKIND_VARIABLE}")
    if detail.len > 0:
        result.append(",\"detail\":\"")
        proto.append_escaped(ref_of(result), detail)
        result.append("\"")
    result.append(",\"range\":")
    append_span(ref_of(result), lz, cz, cz + name.len)
    result.append(",\"selectionRange\":")
    append_span(ref_of(result), lz, cz, cz + name.len)
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
    if detail.len > 0:
        result.append(",\"detail\":\"")
        proto.append_escaped(ref_of(result), detail)
        result.append("\"")
    result.append(",\"selectionRange\":")
    append_span(ref_of(result), lz, 0, name.len)
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
    return collect_field_children_of(analysis, "", fields)


## The fields of a struct/union.  `owner_name` names the declaration so the
## field's *resolved* type can be used when the analyzer has one: the host
## renders fields from its facts, so `cb: fn(value: int) -> bool` comes out as
## `fn(int) -> bool` there.  The source text is the fallback.
function collect_field_children_of(
    analysis: ref[analyzer.Analysis],
    owner_name: str,
    fields: span[ast.Field],
) -> vec.Vec[string.String]:
    var children = vec.Vec[string.String].create()
    var fi: ptr_uint = 0
    while fi < fields.len:
        let field = unsafe: read(fields.data + fi)
        var detail_owner = field_detail_type(analysis, owner_name, field)
        children.push(render_block_symbol(field.name, SYMBOLKIND_FIELD, field.line, field.column, detail_owner.as_str()))
        detail_owner.release()
        fi += 1
    return children


## A field's rendered type: the resolved type when the analyzer has one, else the
## source text.
function field_detail_type(analysis: ref[analyzer.Analysis], owner_name: str, field: ast.Field) -> string.String:
    if owner_name.len > 0:
        let entries_ptr = unsafe: read(analysis).structs.get(owner_name)
        if entries_ptr != null:
            let entries = unsafe: read(entries_ptr)
            var i: ptr_uint = 0
            while i < entries.len:
                let entry = unsafe: read(entries.data + i)
                if entry.name.len > 0 and entry.name.compare(field.name) == 0:
                    if not contains_error_type(entry.ty):
                        return type_render.short_name(entry.ty)
                    break
                i += 1
    return string.String.from_str(ast_formatter.render_type(field.field_type))


## The members of a struct: fields, nested types and events, in the host's
## child order (fields first).
function collect_type_member_children(
    analysis: ref[analyzer.Analysis],
    fields: span[ast.Field],
    events: span[ast.Decl],
    nested: span[ast.Decl],
) -> vec.Vec[string.String]:
    return collect_type_member_children_with_params(analysis, "", fields, events, nested, span[ast.TypeParam]())


## Put a declaration's type parameters ahead of its other children (the host
## lists them first, each on its own token).
function prepend_type_parameters(children: ref[vec.Vec[string.String]], type_params: span[ast.TypeParam]) -> void:
    if type_params.len == 0:
        return
    var params = vec.Vec[string.String].create()
    var tp: ptr_uint = 0
    while tp < type_params.len:
        var param: ast.TypeParam
        unsafe:
            param = read(type_params.data + tp)
        if param.name.len > 0 and not param.is_lifetime and not param.is_value:
            var no_detail = string.String.create()
            params.push(render_name_span_symbol(param.name, SYMBOLKIND_TYPE_PARAMETER, param.line, param.column, no_detail.as_str()))
            no_detail.release()
        tp += 1
    var i: ptr_uint = 0
    while i < children.len():
        let existing = children.get(i) else:
            break
        params.push(unsafe: read(existing))
        i += 1
    children.clear()
    var j: ptr_uint = 0
    while j < params.len():
        let p = params.get(j) else:
            break
        children.push(unsafe: read(p))
        j += 1
    params.release()


## The same, preceded by the declaration's type parameters: the host lists each
## one as a `TypeParameter` (kind 26) child on the parameter's own token, with no
## detail (`Pair :: "[A, B]"` then `A :: nil`, `B :: nil`, then the fields).
function collect_type_member_children_with_params(
    analysis: ref[analyzer.Analysis],
    owner_name: str,
    fields: span[ast.Field],
    events: span[ast.Decl],
    nested: span[ast.Decl],
    type_params: span[ast.TypeParam],
) -> vec.Vec[string.String]:
    var children = vec.Vec[string.String].create()
    var tp: ptr_uint = 0
    while tp < type_params.len:
        var param: ast.TypeParam
        unsafe:
            param = read(type_params.data + tp)
        if param.name.len > 0 and not param.is_lifetime and not param.is_value:
            var no_detail = string.String.create()
            children.push(render_name_span_symbol(param.name, SYMBOLKIND_TYPE_PARAMETER, param.line, param.column, no_detail.as_str()))
            no_detail.release()
        tp += 1
    var field_children = collect_field_children_of(analysis, owner_name, fields)
    var fc: ptr_uint = 0
    while fc < field_children.len():
        let c = field_children.get(fc) else:
            break
        children.push(unsafe: read(c))
        fc += 1
    field_children.release()
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
        children.push(render_method_symbol(m.name, m.line, m.column, detail.as_str()))
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
        if locals.symbols.len() > 0 or locals.has_declarations:
            method_symbol.append(",\"children\":[")
            var li: ptr_uint = 0
            while li < locals.symbols.len():
                let lp = locals.symbols.get(li) else:
                    break
                if li > 0:
                    method_symbol.append(",")
                method_symbol.append(unsafe: read(lp).as_str())
                li += 1
            method_symbol.append("]")
        method_symbol.append("}")
        release_symbol_strings(ref_of(locals.symbols))
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
    # The host renders neither `static` nor `editable`; only `async` is shown
    # (`fetch :: "async -> int"`).
    if is_async:
        target.append("async ")
    target.append("-> ")
    append_ast_type(target, return_type, "void")


## A body's local declarations: the child symbols and whether the body declared
## any local at all (the host creates the `children` key for the latter, even a
## discarded `let _` or a destructure that produces no symbol).
struct BodyLocals:
    symbols: vec.Vec[string.String]
    has_declarations: bool


## The locals declared in a function/method body (kind 13, name-token range).
function collect_body_locals(analysis: ref[analyzer.Analysis], body: ptr[ast.Stmt]?) -> BodyLocals:
    var children = vec.Vec[string.String].create()
    var declared = false
    let b = body else:
        return BodyLocals(symbols = children, has_declarations = false)
    collect_stmt_locals(analysis, unsafe: read(b), ref_of(children), ref_of(declared))
    return BodyLocals(symbols = children, has_declarations = declared)


function collect_stmt_locals(analysis: ref[analyzer.Analysis], stmt: ast.Stmt, children: ref[vec.Vec[string.String]], declared: ref[bool]) -> void:
    match stmt:
        ast.Stmt.stmt_block as blk:
            var si: ptr_uint = 0
            while si < blk.statements.len:
                collect_stmt_locals(analysis, unsafe: read(blk.statements.data + si), children, declared)
                si += 1
        ast.Stmt.stmt_local as loc:
            unsafe: read(declared) = true
            if loc.name.len > 0 and loc.name != "_":
                var detail = string.String.create()
                append_local_type(ref_of(detail), analysis, loc.stmt_type, loc.value)
                children.push(render_local_symbol(loc.name, loc.line, loc.column, detail.as_str()))
                detail.release()
        ast.Stmt.stmt_if as iff:
            var ib: ptr_uint = 0
            while ib < iff.branches.len:
                let branch = unsafe: read(iff.branches.data + ib)
                collect_stmt_locals(analysis, unsafe: read(branch.body), children, declared)
                ib += 1
            if iff.else_body != null:
                collect_stmt_locals(analysis, unsafe: read(ptr[ast.Stmt]<-iff.else_body), children, declared)
        ast.Stmt.stmt_while as w:
            if w.body != null:
                collect_stmt_locals(analysis, unsafe: read(ptr[ast.Stmt]<-w.body), children, declared)
        ast.Stmt.stmt_for as f:
            if f.body != null:
                collect_stmt_locals(analysis, unsafe: read(ptr[ast.Stmt]<-f.body), children, declared)
        ast.Stmt.stmt_match as m:
            var ai: ptr_uint = 0
            while ai < m.arms.len:
                let arm = unsafe: read(m.arms.data + ai)
                if arm.body != null:
                    collect_stmt_locals(analysis, unsafe: read(ptr[ast.Stmt]<-arm.body), children, declared)
                ai += 1
        ast.Stmt.stmt_unsafe as uns:
            if uns.body != null:
                collect_stmt_locals(analysis, unsafe: read(ptr[ast.Stmt]<-uns.body), children, declared)
        ast.Stmt.stmt_defer as dfr:
            if dfr.body != null:
                collect_stmt_locals(analysis, unsafe: read(ptr[ast.Stmt]<-dfr.body), children, declared)
        ast.Stmt.stmt_when as whn:
            var wi: ptr_uint = 0
            while wi < whn.branches.len:
                collect_stmt_span_locals(analysis, unsafe: read(whn.branches.data + wi).body, children, declared)
                wi += 1
            if whn.else_body != null:
                collect_stmt_locals(analysis, unsafe: read(ptr[ast.Stmt]<-whn.else_body), children, declared)
        ast.Stmt.stmt_parallel_block as pb:
            collect_stmt_span_locals(analysis, pb.bodies, children, declared)
        ast.Stmt.stmt_error_block as eb:
            collect_stmt_locals(analysis, unsafe: read(eb.body), children, declared)
        _:
            pass


function collect_stmt_span_locals(analysis: ref[analyzer.Analysis], stmts: span[ast.Stmt], children: ref[vec.Vec[string.String]], declared: ref[bool]) -> void:
    var si: ptr_uint = 0
    while si < stmts.len:
        collect_stmt_locals(analysis, unsafe: read(stmts.data + si), children, declared)
        si += 1


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
            # A type the analyzer could not resolve renders as no detail at all:
            # the host omits `detail` (it never shows `<error>`), and a
            # `<error>` in the outline is what this looked like to the user.
            if contains_error_type(ty.value):
                return
            var short_text = type_render.short_name(ty.value)
            target.append(short_text.as_str())
            short_text.release()
        Option.none:
            pass


## True when the type (recursively) contains the analyzer's error type, i.e. it
## is not a resolved type worth showing.
function contains_error_type(ty: types.Type) -> bool:
    match ty:
        types.Type.ty_error:
            return true
        types.Type.ty_imported as imported:
            return type_args_contain_error(imported.args)
        types.Type.ty_generic as generic:
            return type_args_contain_error(generic.args)
        types.Type.ty_nullable as nullable:
            return contains_error_type(unsafe: read(nullable.base))
        types.Type.ty_function as fn_type:
            if contains_error_type(unsafe: read(fn_type.return_type)):
                return true
            return type_args_contain_error(fn_type.params)
        _:
            return false


function type_args_contain_error(args: span[types.Type]) -> bool:
    var i: ptr_uint = 0
    while i < args.len:
        if contains_error_type(unsafe: read(args.data + i)):
            return true
        i += 1
    return false
