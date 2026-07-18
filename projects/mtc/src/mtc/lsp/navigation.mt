## Navigation handlers — go-to-definition, hover, find-references.
##
## Parses the source file at the cursor position, resolves the identifier,
## and returns the definition location, type information, or reference list
## by walking the AST and querying the semantic Analysis structures.

import std.fmt
import std.fs as fs_mod
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.loader.path_resolver as resolver
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace
import mtc.pretty_printer.ast_formatter as ast_formatter


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
            let target_uri = if payload.target_uri.len() > 0: payload.target_uri.as_str() else: uri
            let lz = if payload.line > 0: ptr_uint<-(int<-(payload.line) - 1) else: 0z
            var json_text = string.String.create()
            defer json_text.release()
            json_text.append("[{\"uri\":\"")
            proto.append_escaped(ref_of(json_text), target_uri)
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
            payload.target_uri.release()
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
            payload.target_uri.release()
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


## Handle textDocument/typeDefinition: for a type name, its own declaration;
## for a module-level value, the declaration of its type — including types
## re-exported from imported modules.
public function handle_type_definition(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
    id: json.Value,
) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
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

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)

    # The identifier is itself a type name: its own declaration.
    let is_type_name = analysis.structs.contains(target.text) or
        analysis.static_member_types.contains(target.text) or
        analysis.interfaces.contains(target.text)
    if is_type_name:
        let decl_line = find_declaration_line(ast_file, target.text, "struct")
        if decl_line > 0:
            respond_single_location(id, uri, source, decl_line, target.text)
            return
        proto.write_response(id, json.null_value())
        return

    # A module-level value: jump to its declared type's definition.  The
    # declared TypeRef is read straight from the AST, so `alias.Type`
    # annotations resolve through the import map without needing bindings.
    let tref = type_ref_of_value(ast_file, target.text)
    if tref != null:
        let t = unsafe: read(tref)
        if not t.is_fn and not t.is_proc and not t.is_tuple:
            if t.name.parts.len == 1:
                let type_name = unsafe: read(t.name.parts.data + 0)
                let decl_line = find_declaration_line(ast_file, type_name, "struct")
                if decl_line > 0:
                    respond_single_location(id, uri, source, decl_line, type_name)
                    return
            else if t.name.parts.len == 2:
                let alias_name = unsafe: read(t.name.parts.data + 0)
                let type_name = unsafe: read(t.name.parts.data + 1)
                unsafe:
                    let module_ptr = analysis.imports.get(alias_name)
                    if module_ptr != null:
                        if respond_imported_type_location(ws, id, read(module_ptr), type_name):
                            return

    proto.write_response(id, json.null_value())


## The declared TypeRef of a module-level const or var, or null.
function type_ref_of_value(file: ast.SourceFile, name: str) -> ptr[ast.TypeRef]?:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_const as c:
                if c.name == name:
                    return c.const_type
            ast.Decl.decl_var as v:
                if v.name == name:
                    return v.var_type
            _:
                pass
        di += 1
    return null


## Locate `type_name`'s declaration inside `module_name`'s source file and
## respond with a cross-file location.
function respond_imported_type_location(
    ws: ref[workspace.Workspace],
    id: json.Value,
    module_name: str,
    type_name: str,
) -> bool:
    var roots = ws.effective_module_roots_for("")
    defer roots.release()
    match resolver.resolve_module_path(module_name, roots.as_span(), resolver.Platform.linux):
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
            return false
        Result.success as path_payload:
            var module_path = path_payload.value
            defer module_path.release()

            var module_source = ws.document_source(module_path.as_str()) else:
                return false
            defer module_source.release()

            var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer parse_diags.release()
            var module_file = parser.parse_source(module_source.as_str(), ref_of(parse_diags))
            let decl_line = find_declaration_line(module_file, type_name, "struct")
            if decl_line == 0:
                return false

            var absolute_path = string.String.from_str(module_path.as_str())
            match fs_mod.canonicalize(module_path.as_str()):
                Result.success as canonical:
                    absolute_path.release()
                    absolute_path = canonical.value
                Result.failure as canon_failure:
                    var canon_err = canon_failure.error
                    canon_err.release()
            defer absolute_path.release()

            var target_uri = string.String.from_str("file://")
            defer target_uri.release()
            target_uri.append(absolute_path.as_str())
            respond_single_location(id, target_uri.as_str(), module_source.as_str(), decl_line, type_name)
            return true


## Respond with a one-element Location array pointing at `name` on its
## declaration line.
function respond_single_location(id: json.Value, uri: str, source: str, decl_line: ptr_uint, name: str) -> void:
    let lz = if decl_line > 0: decl_line - 1 else: 0z
    var column: ptr_uint = 0
    match cursor.token_start_in_line(cursor.source_line(source, decl_line), name):
        Option.some as pos:
            column = pos.value
        Option.none:
            pass

    var json_text = string.String.create()
    defer json_text.release()
    json_text.append("[{\"uri\":\"")
    proto.append_escaped(ref_of(json_text), uri)
    json_text.append("\",\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{column}")
    json_text.append("},\"end\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{column + name.len}")
    json_text.append("}}}]")
    proto.write_response_raw(id, json_text.as_str())


## Handle textDocument/implementation: for an interface name, the
## declarations of every type in this file that implements it.
public function handle_implementation(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
    id: json.Value,
) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer content.release()

    let source = content.as_str()
    let target = cursor.identifier_at(source, line, character) else:
        proto.write_response_raw(id, "[]")
        return

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)

    if not analysis.interfaces.contains(target.text):
        proto.write_response_raw(id, "[]")
        return

    var json_text = string.String.create()
    defer json_text.release()
    json_text.append("[")
    var emitted: ptr_uint = 0

    unsafe:
        var impl_entries = analysis.implemented_interfaces.entries()
        while impl_entries.next():
            let entry = impl_entries.current()
            let interfaces = read(entry.value)
            var qi: ptr_uint = 0
            while qi < interfaces.len:
                let qn = read(interfaces.data + qi)
                if qualified_name_matches(qn, target.text):
                    let struct_name = read(entry.key)
                    let decl_line = find_declaration_line(ast_file, struct_name, "struct")
                    if decl_line > 0:
                        if emitted > 0:
                            json_text.append(",")
                        emitted += 1
                        append_location(ref_of(json_text), uri, source, decl_line, struct_name)
                    break
                qi += 1

    json_text.append("]")
    proto.write_response_raw(id, json_text.as_str())


## True when the qualified name's last part equals `name` (`Damageable` and
## `lib.Damageable` both match "Damageable").
function qualified_name_matches(qn: ast.QualifiedName, name: str) -> bool:
    if qn.parts.len == 0:
        return false
    let last = unsafe: read(qn.parts.data + qn.parts.len - 1)
    return last.equal(name)


## Append one Location object pointing at `name` on `decl_line`.
function append_location(json_text: ref[string.String], uri: str, source: str, decl_line: ptr_uint, name: str) -> void:
    let lz = if decl_line > 0: decl_line - 1 else: 0z
    var column: ptr_uint = 0
    match cursor.token_start_in_line(cursor.source_line(source, decl_line), name):
        Option.some as pos:
            column = pos.value
        Option.none:
            pass
    json_text.append("{\"uri\":\"")
    proto.append_escaped(json_text, uri)
    json_text.append("\",\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{column}")
    json_text.append("},\"end\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{column + name.len}")
    json_text.append("}}}")


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
## documentation lines.  `target_uri` carries a cross-file definition target;
## empty means the request's own document.
struct CursorResult:
    line: ptr_uint
    column: ptr_uint
    name_len: ptr_uint
    hover_text: string.String
    docs: string.String
    target_uri: string.String


## Resolve the symbol at the given cursor position.  Parses the file, runs
## semantic analysis, finds the identifier under the cursor, and looks up its
## definition or type in the analysis maps.  `alias.member` accesses and
## import aliases resolve cross-file into the imported module.
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

    # `alias.member`: resolve the member inside the imported module's file.
    match cursor.dot_receiver_at(source, line, character):
        Option.some as recv:
            unsafe:
                let module_ptr = analysis.imports.get(recv.value)
                if module_ptr != null:
                    return resolve_module_member(ws, read(module_ptr), target.text)
        Option.none:
            pass

    # The identifier is an import alias: the module file itself.
    unsafe:
        let alias_module_ptr = analysis.imports.get(target.text)
        if alias_module_ptr != null:
            return resolve_module_reference(ws, read(alias_module_ptr))

    return resolve_name_in_analysis(ast_file, ref_of(analysis), target.text, source)


## Resolve `member` inside imported module `module_name`: parse and check the
## module's file, reuse the same-file resolver there, and stamp the result
## with the module file's URI.
function resolve_module_member(ws: ref[workspace.Workspace], module_name: str, member: str) -> Option[CursorResult]:
    var module_path = resolve_module_source_path(ws, module_name) else:
        return Option[CursorResult].none
    defer module_path.release()

    var module_source = ws.document_source(module_path.as_str()) else:
        return Option[CursorResult].none
    defer module_source.release()

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var module_file = parser.parse_source(module_source.as_str(), ref_of(parse_diags))
    var module_analysis = analyzer.check_source_file(module_file)

    match resolve_name_in_analysis(module_file, ref_of(module_analysis), member, module_source.as_str()):
        Option.some as res:
            var stamped = res.value
            stamped.target_uri.release()
            stamped.target_uri = file_uri_for_path(module_path.as_str())
            return Option[CursorResult].some(value = stamped)
        Option.none:
            return Option[CursorResult].none


## Resolve an import alias to its module file (top of file, hover shows the
## module name).
function resolve_module_reference(ws: ref[workspace.Workspace], module_name: str) -> Option[CursorResult]:
    var module_path = resolve_module_source_path(ws, module_name) else:
        return Option[CursorResult].none
    defer module_path.release()

    var hover = string.String.create()
    hover.append("module ")
    hover.append(module_name)
    return Option[CursorResult].some(value = CursorResult(
        line = 1,
        column = 0,
        name_len = 0,
        hover_text = hover,
        docs = string.String.create(),
        target_uri = file_uri_for_path(module_path.as_str())
    ))


## The resolved source path of `module_name` against the workspace roots.
function resolve_module_source_path(ws: ref[workspace.Workspace], module_name: str) -> Option[string.String]:
    var roots = ws.effective_module_roots_for("")
    defer roots.release()
    match resolver.resolve_module_path(module_name, roots.as_span(), resolver.Platform.linux):
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
            return Option[string.String].none
        Result.success as path_payload:
            return Option[string.String].some(value = path_payload.value)


## An absolute file:// URI for a workspace-relative or absolute path.
function file_uri_for_path(path: str) -> string.String:
    var absolute_path = string.String.from_str(path)
    match fs_mod.canonicalize(path):
        Result.success as canonical:
            absolute_path.release()
            absolute_path = canonical.value
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()

    var result = string.String.from_str("file://")
    result.append(absolute_path.as_str())
    absolute_path.release()
    return result


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
                if not append_struct_fields_from_ast(ref_of(hover), file, name):
                    # Fallback to resolved field types when the AST decl is
                    # not found (should not happen for same-file structs).
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
        docs = doc_lines_above(source, decl_line),
        target_uri = string.String.create()
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


## Append `[T, ...]` type params, `:`, and per-field lines rendered from the
## struct's AST declaration (accurate for generic field types, which resolve
## permissively in the analysis).  False when the declaration is not found.
function append_struct_fields_from_ast(hover: ref[string.String], file: ast.SourceFile, name: str) -> bool:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_struct as s:
                if s.name == name:
                    if s.type_params.len > 0:
                        hover.append("[")
                        var ti: ptr_uint = 0
                        while ti < s.type_params.len:
                            if ti > 0:
                                hover.append(", ")
                            unsafe:
                                hover.append(read(s.type_params.data + ti).name)
                            ti += 1
                        hover.append("]")
                    hover.append(":")
                    var fi: ptr_uint = 0
                    while fi < s.struct_fields.len:
                        var field: ast.Field
                        unsafe:
                            field = read(s.struct_fields.data + fi)
                        hover.append("\n    ")
                        hover.append(field.name)
                        hover.append(": ")
                        hover.append(ast_formatter.render_type(field.field_type))
                        fi += 1
                    return true
            _:
                pass
        di += 1
    return false


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
