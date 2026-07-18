## Navigation handlers — go-to-definition, hover, find-references.
##
## Parses the source file at the cursor position, resolves the identifier,
## and returns the definition location, type information, or reference list
## by walking the AST and querying the semantic Analysis structures.

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Handle textDocument/definition: find the definition of the symbol at the
## given cursor position and return its location.
public function handle_definition(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
    id: json.Value,
) -> void:
    var result = resolve_cursor(ws, uri, line, character)
    match result:
        Option.some as res:
            var payload = res.value
            let lz = if payload.line > 0: ptr_uint<-(int<-(payload.line) - 1) else: 0z
            var json_text = string.String.create()
            defer json_text.release()
            json_text.append("[{\"uri\":\"")
            proto.append_escaped(ref_of(json_text), uri)
            json_text.append("\",\"range\":{\"start\":{\"line\":")
            json_text.append_format(f"#{lz}")
            json_text.append(",\"character\":")
            json_text.append_format(f"#{payload.column}")
            json_text.append("},\"end\":{\"line\":")
            json_text.append_format(f"#{lz}")
            json_text.append(",\"character\":")
            json_text.append_format(f"#{payload.column + payload.name_len}")
            json_text.append("}}}]")
            proto.write_response_raw(id, json_text.as_str())
            payload.hover_text.release()
            payload.docs.release()
        Option.none:
            proto.write_response(id, json.null_value())


public function handle_hover(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
    id: json.Value,
) -> void:
    var result = resolve_cursor(ws, uri, line, character)
    match result:
        Option.some as res:
            var payload = res.value
            if payload.hover_text.len() > 0:
                var value_text = string.String.create()
                defer value_text.release()
                value_text.append("```milk-tea\n")
                value_text.append(payload.hover_text.as_str())
                value_text.append("\n```")
                if payload.docs.len() > 0:
                    value_text.append("\n")
                    value_text.append(payload.docs.as_str())

                var json_text = string.String.create()
                defer json_text.release()
                json_text.append("{\"contents\":{\"kind\":\"markdown\",\"value\":\"")
                proto.append_escaped(ref_of(json_text), value_text.as_str())
                json_text.append("\"}}")
                proto.write_response_raw(id, json_text.as_str())
            else:
                proto.write_response(id, json.null_value())
            payload.hover_text.release()
            payload.docs.release()
        Option.none:
            proto.write_response(id, json.null_value())


## Handle textDocument/references: find all references to the symbol at the
## cursor position within the same file.
public function handle_references(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
    id: json.Value,
) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_error(id, -32602, "invalid uri")
        return
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer content.release()

    let source = content.as_str()
    let target = cursor.identifier_at(source, line, character) else:
        proto.write_response(id, json.null_value())
        return

    var refs_json = build_references_json(source, target.text, uri)
    proto.write_response_raw(id, refs_json.as_str())
    refs_json.release()


## Build a JSON array of Location objects for all references to `name` in
## `source`.  Occurrences are identifier tokens, so text inside string
## literals and comments never matches.
function build_references_json(source: str, name: str, uri: str) -> string.String:
    var result = string.String.create()
    result.append("[")

    var occurrences = cursor.identifier_occurrences(source, name)
    defer occurrences.release()

    var oi: ptr_uint = 0
    while oi < occurrences.len():
        let op = occurrences.get(oi) else:
            break
        let occ = unsafe: read(op)
        if oi > 0:
            result.append(",")
        let lz = if occ.line > 0: occ.line - 1 else: 0z
        let col = if occ.column > 0: occ.column - 1 else: 0z
        result.append("{\"uri\":\"")
        append_ref_escaped(ref_of(result), uri)
        result.append("\",\"range\":{\"start\":{\"line\":")
        result.append_format(f"#{lz}")
        result.append(",\"character\":")
        result.append_format(f"#{col}")
        result.append("},\"end\":{\"line\":")
        result.append_format(f"#{lz}")
        result.append(",\"character\":")
        result.append_format(f"#{col + occ.length}")
        result.append("}}}")
        oi += 1
    result.append("]")
    return result


function append_ref_escaped(output: ref[string.String], text: str) -> void:
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b == 34: output.append("\\\"") else if b == 92: output.append("\\\\") else: output.push_byte(b)
        i += 1


## Cursor resolution result — the definition position (1-based line, 0-based
## name column), the signature rendered for hover, and any attached `##`
## documentation lines.
struct CursorResult:
    line: ptr_uint
    column: ptr_uint
    name_len: ptr_uint
    hover_text: string.String
    docs: string.String


## Resolve the symbol at the given cursor position.  Parses the file, runs
## semantic analysis, finds the identifier under the cursor, and looks up its
## definition or type in the analysis maps.
function resolve_cursor(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
) -> Option[CursorResult]:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        return Option[CursorResult].none
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        return Option[CursorResult].none
    defer content.release()

    let source = content.as_str()
    if source.len == 0:
        return Option[CursorResult].none

    let target = cursor.identifier_at(source, line, character) else:
        return Option[CursorResult].none

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    if parse_diags.len() > 0:
        return Option[CursorResult].none

    var analysis = analyzer.check_source_file(ast_file)

    return resolve_name_in_analysis(ast_file, ref_of(analysis), target.text, source)


## Resolve `name` against the semantic analysis maps.  Returns the definition
## location, rendered signature, and attached docs, or none if unresolvable.
function resolve_name_in_analysis(
    file: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    name: str,
    source: str,
) -> Option[CursorResult]:
    unsafe:
        # Function: render the full signature.
        let sig_ptr = read(analysis).functions.get(name)
        if sig_ptr != null:
            let decl_line = find_declaration_line(file, name, "function")
            if decl_line > 0:
                return Option[CursorResult].some(value = make_result(
                    decl_line,
                    name,
                    source,
                    format_fn_signature(read(sig_ptr), name)
                ))

        # Module-level const or var: render name and type.
        let value_ptr = read(analysis).value_types.get(name)
        if value_ptr != null:
            let decl_line = find_declaration_line(file, name, "value")
            if decl_line > 0:
                var hover = string.String.create()
                hover.append(value_decl_keyword(file, name))
                hover.append(" ")
                hover.append(name)
                hover.append(": ")
                hover.append(types.type_to_string(read(value_ptr)))
                return Option[CursorResult].some(value = make_result(decl_line, name, source, hover))

        # Struct: render the field list.
        let fields_ptr = read(analysis).structs.get(name)
        if fields_ptr != null:
            let decl_line = find_declaration_line(file, name, "struct")
            if decl_line > 0:
                var hover = string.String.create()
                hover.append("struct ")
                hover.append(name)
                hover.append(":")
                let fields = read(fields_ptr)
                var fi: ptr_uint = 0
                while fi < fields.len:
                    let fe = read(fields.data + fi)
                    hover.append("\n    ")
                    hover.append(fe.name)
                    hover.append(": ")
                    hover.append(types.type_to_string(fe.ty))
                    fi += 1
                return Option[CursorResult].some(value = make_result(decl_line, name, source, hover))

        # Enum, flags, or variant: render the member list.
        if read(analysis).static_member_types.contains(name):
            let decl_line = find_declaration_line(file, name, "struct")
            if decl_line > 0:
                var hover = string.String.create()
                hover.append(static_type_keyword(file, name))
                hover.append(" ")
                hover.append(name)
                let members_ptr = read(analysis).match_case_names.get(name)
                if members_ptr != null:
                    hover.append(":")
                    let members = read(members_ptr)
                    var mi: ptr_uint = 0
                    while mi < members.len:
                        hover.append("\n    ")
                        hover.append(read(members.data + mi))
                        mi += 1
                return Option[CursorResult].some(value = make_result(decl_line, name, source, hover))

    return Option[CursorResult].none


## Assemble a CursorResult: locate the name on its declaration line and
## attach any contiguous `##` doc lines directly above it.
function make_result(decl_line: ptr_uint, name: str, source: str, hover: string.String) -> CursorResult:
    var column: ptr_uint = 0
    let line_text = cursor.source_line(source, decl_line)
    match cursor.token_start_in_line(line_text, name):
        Option.some as pos:
            column = pos.value
        Option.none:
            pass
    return CursorResult(
        line = decl_line,
        column = column,
        name_len = name.len,
        hover_text = hover,
        docs = doc_lines_above(source, decl_line)
    )


## Render a function signature from its FnSig:
## `async function name(a: int, b: str) -> int`.
function format_fn_signature(sig: analyzer.FnSig, name: str) -> string.String:
    var sig_text = string.String.create()
    if sig.is_async:
        sig_text.append("async ")
    sig_text.append("function ")
    sig_text.append(name)
    sig_text.append("(")
    var pi: ptr_uint = 0
    while pi < sig.params.len:
        let param = unsafe: read(sig.params.data + pi)
        if pi > 0:
            sig_text.append(", ")
        sig_text.append(param.name)
        sig_text.append(": ")
        sig_text.append(types.type_to_string(param.ty))
        pi += 1
    if sig.is_variadic:
        if sig.params.len > 0:
            sig_text.append(", ")
        sig_text.append("...")
    sig_text.append(")")
    if sig.has_return_type:
        sig_text.append(" -> ")
        sig_text.append(types.type_to_string(sig.return_type))
    return sig_text


## The declaration keyword for a module-level value: "const" or "var".
function value_decl_keyword(file: ast.SourceFile, name: str) -> str:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_const as c:
                if c.name == name:
                    return "const"
            ast.Decl.decl_var as v:
                if v.name == name:
                    return "var"
            _:
                pass
        di += 1
    return "const"


## The declaration keyword for an enum-like type: "enum", "flags", or "variant".
function static_type_keyword(file: ast.SourceFile, name: str) -> str:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_enum as e:
                if e.name == name:
                    return "enum"
            ast.Decl.decl_flags as fl:
                if fl.name == name:
                    return "flags"
            ast.Decl.decl_variant as vr:
                if vr.name == name:
                    return "variant"
            _:
                pass
        di += 1
    return "enum"


## Contiguous `##` documentation lines directly above 1-based `decl_line`,
## with the comment markers stripped, joined by newlines.
function doc_lines_above(source: str, decl_line: ptr_uint) -> string.String:
    var docs = string.String.create()
    if decl_line <= 1:
        return docs

    # Find the first line of the contiguous ## block above the declaration.
    var first_doc_line = decl_line
    var probe = decl_line - 1
    while probe >= 1:
        let text = cursor.source_line(source, probe).trim_ascii_whitespace()
        if text.len >= 2 and text.byte_at(0) == 35 and text.byte_at(1) == 35:
            first_doc_line = probe
            if probe == 1:
                break
            probe -= 1
        else:
            break

    var i = first_doc_line
    while i < decl_line:
        let text = cursor.source_line(source, i).trim_ascii_whitespace()
        if text.len < 2:
            break
        var body = text.slice(2, text.len - 2)
        if body.len > 0 and body.byte_at(0) == 32:
            body = body.slice(1, body.len - 1)
        if not docs.is_empty():
            docs.append("\n")
        docs.append(body)
        i += 1
    return docs


## Find the declaration line of a named symbol in the source file's AST.
function find_declaration_line(file: ast.SourceFile, name: str, kind: str) -> ptr_uint:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        if kind == "function":
            match decl:
                ast.Decl.decl_function as fun:
                    if fun.name == name:
                        return fun.line
                _:
                    pass
        else if kind == "value":
            match decl:
                ast.Decl.decl_const as c:
                    if c.name == name:
                        return c.line
                ast.Decl.decl_var as v:
                    if v.name == name:
                        return v.line
                _:
                    pass
        else if kind == "struct":
            match decl:
                ast.Decl.decl_struct as s:
                    if s.name == name:
                        return s.line
                ast.Decl.decl_union as u:
                    if u.name == name:
                        return u.line
                ast.Decl.decl_opaque as op:
                    if op.name == name:
                        return op.line
                ast.Decl.decl_variant as vr:
                    if vr.name == name:
                        return vr.line
                ast.Decl.decl_enum as e:
                    if e.name == name:
                        return e.line
                ast.Decl.decl_flags as fl:
                    if fl.name == name:
                        return fl.line
                ast.Decl.decl_interface as iface:
                    if iface.name == name:
                        return iface.line
                _:
                    pass
        di += 1
    return 0
