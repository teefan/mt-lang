## Navigation handlers — go-to-definition, hover, find-references.
##
## Parses the source file at the cursor position, resolves the identifier,
## and returns the definition location, type information, or reference list
## by walking the AST and querying the semantic Analysis structures.

import std.fmt
import std.fs as fs_mod
import std.map as map_mod
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import std.log as log

import mtc.lexer.lexer as lexer_mod
import mtc.lexer.token as token_mod
import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.loader.path_resolver as resolver
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.scope as scope_mod
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace
import mtc.lsp.workspace_index as ws_idx
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
    # Try module-level resolution first, then fall back to local variables.
    var result = resolve_cursor(ws, uri, line, character)
    if result.is_none():
        result = resolve_local_hover(ws, uri, line, character)
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
    match resolve_non_decl_hover(ws, uri, line, character):
        Option.some as kw_result:
            write_hover_result(id, kw_result.value)
            return
        Option.none:
            pass

    match resolve_local_hover(ws, uri, line, character):
        Option.some as loc_result:
            write_hover_result(id, loc_result.value)
            return
        Option.none:
            pass

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
                if payload.line > 0:
                    value_text.append("\n\n*Defined at line ")
                    value_text.append_format(f"#{payload.line}")
                    value_text.append("*")

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

    ws.build_index_if_needed()
    var refs_json = build_references_json_cross_file(ws, target.text, uri)
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
## `source` that are in the same scope as the declaration at `target_line`.
## Occurrences are identifier tokens, so text inside string literals and
## comments never matches.  Scope-aware via lsp.scope.
## Cross-file reference search using the workspace index.
function build_references_json_cross_file(ws: ref[workspace.Workspace], name: str, uri: str) -> string.String:
    var result = string.String.create()
    result.append("[")
    var first = true
    var seen = map_mod.Map[str, bool].create()
    defer seen.release()

    # Always include the current file first (open editor buffer).
    match include_refs_from_file(ws, uri, name, ref_of(result), ref_of(first)):
        Option.some as u:
            seen.set(u.value.as_str(), true)
        Option.none:
            pass

    # Search the workspace index for all matching entries.
    var max_results = ws.index.entries.len()
    var results = ws_idx.query_index(ref_of(ws.index), name, max_results)
    defer results.release()

    var ri: ptr_uint = 0
    while ri < results.len():
        let rp = results.get(ri) else:
            break
        let ei = unsafe: read(rp)
        let ep = ws.index.entries.get(ei) else:
            break
        let entry = unsafe: read(ep)
        if entry.name.as_str().equal(name):
            let path = entry.path.as_str()
            if not seen.contains(path):
                match include_refs_from_file(ws, path, name, ref_of(result), ref_of(first)):
                    Option.some as u2:
                        seen.set(u2.value.as_str(), true)
                    Option.none:
                        pass
        ri += 1

    result.append("]")
    return result


## Scan a single file for identifier occurrences of `name` and append
## location JSON to `output`. Returns the file path for dedup tracking.
function include_refs_from_file(
    ws: ref[workspace.Workspace],
    file_ref: str,
    name: str,
    output: ref[string.String],
    first_ref: ref[bool],
) -> Option[string.String]:
    var cw = ws.document_source(file_ref) else:
        return Option[string.String].none
    defer cw.release()
    let source = cw.as_str()
    if source.len == 0:
        return Option[string.String].none

    var occurrences = cursor.identifier_occurrences(source, name)
    defer occurrences.release()

    var file_uri = string.String.create()
    file_uri.append("file://")
    file_uri.append(file_ref)

    var oi: ptr_uint = 0
    while oi < occurrences.len():
        let op = occurrences.get(oi) else:
            break
        let occ = unsafe: read(op)
        if not unsafe: read(first_ref):
            output.append(",")
        unsafe: read(first_ref) = false
        let lz = if occ.line > 0: occ.line - 1 else: 0z
        let col = if occ.column > 0: occ.column - 1 else: 0z
        output.append("{\"uri\":\"")
        proto.append_escaped(output, file_uri.as_str())
        output.append("\",\"range\":{\"start\":{\"line\":")
        output.append_format(f"#{lz}")
        output.append(",\"character\":")
        output.append_format(f"#{col}")
        output.append("},\"end\":{\"line\":")
        output.append_format(f"#{lz}")
        output.append(",\"character\":")
        output.append_format(f"#{col + occ.length}")
        output.append("}}")
        oi += 1

    file_uri.release()
    return Option[string.String].some(value = string.String.from_str(file_ref))


function build_references_json(source: str, name: str, target_line: ptr_uint, uri: str) -> string.String:
    var result = string.String.create()
    result.append("[")

    var all_occurrences = cursor.identifier_occurrences(source, name)
    defer all_occurrences.release()

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var bindings = scope_mod.collect_bindings(source, ast_file)
    defer bindings.release()

    var oi: ptr_uint = 0
    while oi < all_occurrences.len():
        let op = all_occurrences.get(oi) else:
            break
        let occ = unsafe: read(op)
        if not scope_mod.is_in_same_scope(ref_of(bindings), name, target_line, occ.line):
            oi += 1
            continue
        if oi > 0:
            result.append(",")
        let lz = if occ.line > 0: occ.line - 1 else: 0z
        let col = if occ.column > 0: occ.column - 1 else: 0z
        result.append("{\"uri\":\"")
        proto.append_escaped(ref_of(result), uri)
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
    proto.append_escaped(output, text)


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


## Quick hover result — no declaration source line, no docs.
function quick_hover(text: str) -> CursorResult:
    return CursorResult(
        line = 1,
        column = 0,
        name_len = 0,
        hover_text = string.String.from_str(text),
        docs = string.String.create(),
        target_uri = string.String.create()
    )


## Resolve hover for builtin keywords, builtin callables, and field
## declarations — cases that do not involve named declarations.
## Returns `none` to fall through to `resolve_cursor`.
function resolve_non_decl_hover(
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

    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer tokens.release()

    var ti: ptr_uint = 0
    let target_line = line + 1
    while ti < tokens.len:
        let tp = tokens.get(ti) else:
            break
        let t = unsafe: read(tp)
        if t.line > target_line:
            break
        if t.line == target_line and t.column - 1 <= character and t.column - 1 + t.end_offset - t.start_offset > character:
            let lexeme = unsafe: token_mod.token_lexeme(t, source)

            match keyword_hover_text(lexeme):
                Option.some as kw:
                    return Option[CursorResult].some(value = quick_hover(kw.value))
                Option.none:
                    pass

            match builtin_hover_text(lexeme):
                Option.some as bu:
                    return Option[CursorResult].some(value = quick_hover(bu.value))
                Option.none:
                    pass

            match builtin_specialization_hover(tokens, ti, lexeme):
                Option.some as bs:
                    return Option[CursorResult].some(value = quick_hover(bs.value))
                Option.none:
                    pass

            break
        ti += 1

    match field_declaration_hover(source, line, character):
        Option.some as fd:
            return Option[CursorResult].some(value = fd.value)
        Option.none:
            pass

    return Option[CursorResult].none


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
            # `EnumType.member`: render the enum member.
            if analysis.static_member_types.contains(recv.value):
                return resolve_enum_member(recv.value, target.text, source, ref_of(analysis))
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


## Render hover for an enum type member access like `Color.red` or
## `State.running`.  Receives the enum type name and the member identifier.
function resolve_enum_member(type_name: str, member: str, source: str, analysis: ref[analyzer.Analysis]) -> Option[CursorResult]:
    let matches_ptr = unsafe: read(analysis).match_case_names.get(type_name)
    if matches_ptr == null:
        return Option[CursorResult].none
    let members = unsafe: read(matches_ptr)
    var mi: ptr_uint = 0
    var found = false
    while mi < members.len:
        if unsafe: read(members.data + mi) == member:
            found = true
            break
        mi += 1
    if not found:
        return Option[CursorResult].none

    var hover = string.String.create()
    hover.append(type_name)
    hover.append(".")
    hover.append(member)
    return Option[CursorResult].some(value = CursorResult(
        line = 1,
        column = 0,
        name_len = member.len,
        hover_text = hover,
        docs = string.String.create(),
        target_uri = string.String.create()
    ))


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

        # Extending-block or interface method: search method_keys for "*.name".
        var method_entries = read(analysis).method_keys.entries()
        var m_next = method_entries.next()
        while m_next:
            let m_entry = method_entries.current()
            let method_key = unsafe: read(m_entry.key)
            if method_key.ends_with(name) and method_key.len > name.len:
                let sig_p = read(analysis).method_sigs.get(method_key)
                if sig_p != null:
                    let mline = find_method_line(file, name)
                    if mline > 0:
                        var m_sig = read(sig_p)
                        var full = string.String.create()
                        match classify_method(file, name):
                            Option.some as prefix:
                                full.append(prefix.value)
                            Option.none:
                                full.append("function")
                        full.append(" ")
                        full.append(name)
                        full.append("(")
                        var pi: ptr_uint = 0
                        while pi < m_sig.params.len:
                            let p = unsafe: read(m_sig.params.data + pi)
                            if pi > 0:
                                full.append(", ")
                            full.append(p.name)
                            full.append(": ")
                            full.append(types.type_to_string(p.ty))
                            pi += 1
                        full.append(")")
                        if m_sig.has_return_type:
                            full.append(" -> ")
                            full.append(types.type_to_string(m_sig.return_type))
                        return Option[CursorResult].some(value = make_result(mline, name, source, full))
            m_next = method_entries.next()

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

        # Type alias: render the type and its target.
        if read(analysis).types.contains(name):
            let decl_line = find_declaration_line(file, name, "alias")
            if decl_line > 0:
                var hover = string.String.create()
                hover.append("type ")
                hover.append(name)
                let aliased_ptr = read(analysis).type_alias_types.get(name)
                if aliased_ptr != null:
                    hover.append(" = ")
                    hover.append(types.type_to_string(read(aliased_ptr)))
                return Option[CursorResult].some(value = make_result(decl_line, name, source, hover))

        # Interface: render member signatures.
        if read(analysis).interfaces.contains(name):
            let decl_line = find_declaration_line(file, name, "struct")
            if decl_line > 0:
                var hover = string.String.create()
                hover.append("interface ")
                hover.append(name)
                let methods_ptr = read(analysis).interfaces.get(name)
                if methods_ptr != null:
                    hover.append(":")
                    let methods = read(methods_ptr)
                    var mi: ptr_uint = 0
                    while mi < methods.len:
                        var m = unsafe: read(methods.data + mi)
                        hover.append("\n    ")
                        hover.append(m.name)
                        hover.append("(")
                        var pi: ptr_uint = 0
                        while pi < m.method_params.len:
                            var p = unsafe: read(m.method_params.data + pi)
                            if pi > 0:
                                hover.append(", ")
                            hover.append(p.name)
                            hover.append(": ")
                            if p.param_type.name.parts.len > 0:
                                hover.append(unsafe: read(p.param_type.name.parts.data))
                            pi += 1
                        hover.append(")")
                        if m.return_type != null:
                            let rt = unsafe: read(ptr[ast.TypeRef]<-m.return_type)
                            hover.append(" -> ")
                            if rt.name.parts.len > 0:
                                hover.append(unsafe: read(rt.name.parts.data))
                        mi += 1
                return Option[CursorResult].some(value = make_result(decl_line, name, source, hover))

        # Union type.
        let decl_line_u = find_declaration_line(file, name, "union")
        if decl_line_u > 0:
            var hover_u = string.String.create()
            hover_u.append("union ")
            hover_u.append(name)
            return Option[CursorResult].some(value = make_result(decl_line_u, name, source, hover_u))

        # Event declaration.
        let decl_line_ev = find_declaration_line(file, name, "event")
        if decl_line_ev > 0:
            var hover_ev = string.String.create()
            hover_ev.append("event ")
            hover_ev.append(name)
            return Option[CursorResult].some(value = make_result(decl_line_ev, name, source, hover_ev))

        # Opaque type.
        let decl_line_o = find_declaration_line(file, name, "opaque")
        if decl_line_o > 0:
            var hover = string.String.create()
            hover.append("opaque ")
            hover.append(name)
            return Option[CursorResult].some(value = make_result(decl_line_o, name, source, hover))

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


## Find the line number of a method named `name` inside any `extending` block.
function find_method_line(file: ast.SourceFile, name: str) -> ptr_uint:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_extending_block as ext:
                var mi: ptr_uint = 0
                while mi < ext.methods.len:
                    var mfn: ast.Method
                    unsafe:
                        mfn = read(ext.methods.data + mi)
                    if mfn.name == name:
                        return mfn.line
                    mi += 1
            _:
                pass
        di += 1
    return 0


## The classification prefix for a method: "static function", "editable function",
## or "function".
function classify_method(file: ast.SourceFile, name: str) -> Option[str]:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_extending_block as ext:
                var mi: ptr_uint = 0
                while mi < ext.methods.len:
                    var mfn: ast.Method
                    unsafe:
                        mfn = read(ext.methods.data + mi)
                    if mfn.name == name:
                        match mfn.method_kind:
                            ast.MethodKind.mk_static:
                                return Option[str].some(value = "static function")
                            ast.MethodKind.mk_editable:
                                return Option[str].some(value = "editable function")
                            ast.MethodKind.mk_plain:
                                return Option[str].some(value = "function")
                            _:
                                return Option[str].some(value = "function")
                    mi += 1
            _:
                pass
        di += 1
    return Option[str].none


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
        if text.len >= 2 and text.byte_at(0) == '#' and text.byte_at(1) == '#':
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
        if body.len > 0 and body.byte_at(0) == ' ':
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
        let result = find_decl_line_in(decl, name, kind)
        if result > 0:
            return result
        di += 1
    return 0


## Search a single declaration and its nested children for a named entity
## of the given kind.  Returns the line number (1-based) or 0 if not found.
function find_decl_line_in(decl: ast.Decl, name: str, kind: str) -> ptr_uint:
    unsafe:
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
                    else:
                        # Search nested declarations inside structs
                        var ni: ptr_uint = 0
                        while ni < s.nested_types.len:
                            let nested = find_decl_line_in(read(s.nested_types.data + ni), name, kind)
                            if nested > 0:
                                return nested
                            ni += 1
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
                ast.Decl.decl_flags as f:
                    if f.name == name:
                        return f.line
                ast.Decl.decl_interface as iface:
                    if iface.name == name:
                        return iface.line
                _:
                    pass
        else if kind == "union":
            match decl:
                ast.Decl.decl_union as u:
                    if u.name == name:
                        return u.line
                _:
                    pass
        else if kind == "event":
            match decl:
                ast.Decl.decl_event as ev:
                    if ev.name == name:
                        return ev.line
                _:
                    pass
    return 0



## Return the string text of the identifier or keyword token at the given
## 0-based cursor position, or none if no token covers the position.
function find_token_str(source: str, line: ptr_uint, character: ptr_uint) -> Option[string.String]:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer tokens.release()

    let target_line = line + 1
    var ti: ptr_uint = 0
    while ti < tokens.len:
        let tp = tokens.get(ti) else:
            break
        let t = unsafe: read(tp)
        if t.line > target_line:
            break
        if t.line == target_line and t.column - 1 <= character and t.column - 1 + (t.end_offset - t.start_offset) > character:
            let lexeme = unsafe: token_mod.token_lexeme(t, source)
            return Option[string.String].some(value = string.String.from_str(lexeme))
        ti += 1
    return Option[string.String].none


# =============================================================================
#  Builtin and keyword hover tables
# =============================================================================

function keyword_hover_text(lexeme: str) -> Option[str]:
    if lexeme.equal("return"):
        return Option[str].some(value = "keyword return — exits a function with an optional value")
    if lexeme.equal("if"):
        return Option[str].some(value = "keyword if / else — conditional control flow")
    if lexeme.equal("else"):
        return Option[str].some(value = "keyword else — fallback branch in if / match")
    if lexeme.equal("while"):
        return Option[str].some(value = "keyword while — conditional loop")
    if lexeme.equal("for"):
        return Option[str].some(value = "keyword for — iteration over ranges, arrays, spans, or structural iterables")
    if lexeme.equal("match"):
        return Option[str].some(value = "keyword match — exhaustive pattern matching on enums, variants, integers, or strings")
    if lexeme.equal("let"):
        return Option[str].some(value = "keyword let — immutable local binding, supports else: guard over T? / Option / Result")
    if lexeme.equal("var"):
        return Option[str].some(value = "keyword var — mutable local binding, supports else: guard")
    if lexeme.equal("const"):
        return Option[str].some(value = "keyword const — compile-time constant value")
    if lexeme.equal("type"):
        return Option[str].some(value = "keyword type — type alias definition")
    if lexeme.equal("struct"):
        return Option[str].some(value = "keyword struct — plain data record with named fields")
    if lexeme.equal("enum"):
        return Option[str].some(value = "keyword enum — fixed set of named integer values with an explicit backing type")
    if lexeme.equal("interface"):
        return Option[str].some(value = "keyword interface — compile-time method-set contract for static polymorphism")
    if lexeme.equal("variant"):
        return Option[str].some(value = "keyword variant — tagged union with optional payload fields")
    if lexeme.equal("flags"):
        return Option[str].some(value = "keyword flags — named bitmask values with a fixed integer backing type")
    if lexeme.equal("union"):
        return Option[str].some(value = "keyword union — untagged C-ABI union for FFI / low-level storage")
    if lexeme.equal("opaque"):
        return Option[str].some(value = "keyword opaque — C handle type with hidden layout")
    if lexeme.equal("extending"):
        return Option[str].some(value = "keyword extending — method declarations on an existing type")
    if lexeme.equal("function"):
        return Option[str].some(value = "keyword function — named callable entity")
    if lexeme.equal("const function"):
        return Option[str].some(value = "keyword const function — compile-time-evaluable callable")
    if lexeme.equal("async"):
        return Option[str].some(value = "keyword async — cooperative multitasking via task model")
    if lexeme.equal("external"):
        return Option[str].some(value = "keyword external — raw C ABI binding file marker")
    if lexeme.equal("public"):
        return Option[str].some(value = "keyword public — exported declaration visibility")
    if lexeme.equal("import"):
        return Option[str].some(value = "keyword import — module dependency declaration")
    if lexeme.equal("defer"):
        return Option[str].some(value = "keyword defer — scope-exit cleanup registration")
    if lexeme.equal("unsafe"):
        return Option[str].some(value = "keyword unsafe — explicitly-allowed raw pointer operations")
    if lexeme.equal("break"):
        return Option[str].some(value = "keyword break — exit the innermost enclosing loop")
    if lexeme.equal("continue"):
        return Option[str].some(value = "keyword continue — skip to the next iteration of the innermost loop")
    if lexeme.equal("in"):
        return Option[str].some(value = "keyword in — used in for-in iterable clauses and foreign param modes")
    if lexeme.equal("size_of"):
        return Option[str].some(value = "builtin size_of(T) -> ptr_uint")
    if lexeme.equal("align_of"):
        return Option[str].some(value = "builtin align_of(T) -> ptr_uint")
    if lexeme.equal("offset_of"):
        return Option[str].some(value = "builtin offset_of(T, field) -> ptr_uint")
    return Option[str].none


function builtin_hover_text(lexeme: str) -> Option[str]:
    if lexeme.equal("fatal"):
        return Option[str].some(value = "builtin fatal(message: cstr) -> void")
    if lexeme.equal("ref_of"):
        return Option[str].some(value = "builtin ref_of(x: T) -> ref[T]")
    if lexeme.equal("const_ptr_of"):
        return Option[str].some(value = "builtin const_ptr_of(x: T) -> const_ptr[T]")
    if lexeme.equal("ptr_of"):
        return Option[str].some(value = "builtin ptr_of(x: T) -> ptr[T]")
    if lexeme.equal("read"):
        return Option[str].some(value = "builtin read(r: ref[T]) -> T\n\nProjects the referent value from a ref[T] or ptr[T].")
    if lexeme.equal("adapt"):
        return Option[str].some(value = "builtin adapt[I](value: ref[T]) -> dyn[I]\n\nConstructs a runtime interface value.")
    if lexeme.equal("get"):
        return Option[str].some(value = "builtin get(coll, index) -> ptr[T]?\n\nBounds-checked collection access returning a nullable pointer.")
    if lexeme.equal("field_of"):
        return Option[str].some(value = "builtin field_of(T, name) -> field_handle\n\nCompile-time reflection for struct fields.")
    if lexeme.equal("callable_of"):
        return Option[str].some(value = "builtin callable_of(T, name) -> callable_handle\n\nCompile-time reflection for callables.")
    if lexeme.equal("has_attribute"):
        return Option[str].some(value = "builtin has_attribute(T, name) -> bool\n\nTrue if T has the named attribute applied.")
    if lexeme.equal("attribute_of"):
        return Option[str].some(value = "builtin attribute_of(T, name) -> attribute_handle\n\nCompile-time reflection for attributes.")
    if lexeme.equal("attribute_arg"):
        return Option[str].some(value = "builtin attribute_arg[T](h, name) -> T\n\nReturns the T-typed argument of a resolved attribute handle.")
    if lexeme.equal("members_of"):
        return Option[str].some(value = "builtin members_of(E) -> array[member_handle, N]\n\nCompile-time enumeration of an enum or variant.")
    if lexeme.equal("fields_of"):
        return Option[str].some(value = "builtin fields_of(T) -> array[field_handle, N]\n\nCompile-time enumeration of struct fields.")
    if lexeme.equal("attributes_of"):
        return Option[str].some(value = "builtin attributes_of(T) -> array[attribute_handle, N]\n\nCompile-time enumeration of attributes.")
    return Option[str].none


function builtin_specialization_hover(tokens: vec.Vec[token_mod.Token], ti: ptr_uint, lexeme: str) -> Option[str]:
    var is_spec = false
    if lexeme.equal("zero") or lexeme.equal("default") or lexeme.equal("reinterpret") or lexeme.equal("array") or lexeme.equal("span"):
        is_spec = true
    if not is_spec:
        return Option[str].none

    # Look ahead for a `[` specialization token after this identifier.
    var next_idx = ti + 1
    if next_idx < tokens.len:
        let np = tokens.get(next_idx) else:
            return Option[str].none
        let nt = unsafe: read(np)
        if int<-(nt.kind) == 19:
            return Option[str].some(value = f"builtin {lexeme}[...]")
        return Option[str].some(value = f"builtin {lexeme}[...]")
    return Option[str].none


function field_declaration_hover(source: str, line: ptr_uint, character: ptr_uint) -> Option[CursorResult]:
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    if parse_diags.len() > 0:
        return Option[CursorResult].none

    let target_line = line + 1
    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        match decl:
            ast.Decl.decl_struct as s:
                var fi: ptr_uint = 0
                while fi < s.struct_fields.len:
                    var f = unsafe: read(s.struct_fields.data + fi)
                    if f.line == target_line and f.column <= character and f.column + f.name.len > character:
                        var hover = string.String.create()
                        hover.append("field ")
                        hover.append(f.name)
                        hover.append(": ")
                        if true:
                            let ty = f.field_type
                            if ty.name.parts.len > 0:
                                hover.append(unsafe: read(ty.name.parts.data))
                            if ty.nullable:
                                hover.append("?")
                        return Option[CursorResult].some(value = make_result(target_line, f.name, source, hover))
                    fi += 1
            _:
                pass
        di += 1

    return Option[CursorResult].none

function resolve_local_hover(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
) -> Option[CursorResult]:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        return Option[CursorResult].none
    defer file_path.release()
    var cw = ws.document_source(file_path.as_str()) else:
        return Option[CursorResult].none
    defer cw.release()
    let source = cw.as_str()
    if source.len == 0:
        return Option[CursorResult].none

    var name_opt = find_token_str(source, line, character)
    var name = name_opt else:
        return Option[CursorResult].none
    defer name.release()
    let target_line = line + 1

    # 1. Token-level: for-loop binding ("for item in ...")
    match for_binding_hover(source, line, character, name.as_str()):
        Option.some as fb:
            return Option[CursorResult].some(value = fb.value)
        Option.none:
            pass

    # 2. Token-level: match-arm "as name" binding
    match as_binding_hover(source, line, character, name.as_str()):
        Option.some as ab:
            return Option[CursorResult].some(value = ab.value)
        Option.none:
            pass

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))

    # 3. AST walk: let/var declarations in enclosing function body.
    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                if fun.line <= target_line and fun.body != null:
                    var body_loc = find_local_in_block(unsafe: read(ptr[ast.Stmt]<-fun.body), name.as_str())
                    match body_loc:
                        Option.some as loc:
                            return Option[CursorResult].some(value = loc.value)
                        Option.none:
                            pass
            _:
                pass
        di += 1

    # 4. Lexical fallback: search source text for any "let/var/const name"
    #    declaration (including module-level) appearing before the cursor.
    match lexical_local_hover(source, target_line, character, name.as_str()):
        Option.some as lh:
            return Option[CursorResult].some(value = lh.value)
        Option.none:
            pass

    return Option[CursorResult].none


## Token-level heuristic: is this identifier a for-loop binding?
## Walks backward from the cursor line to find a `for` keyword at the
## start of the same line, indicating an iteration variable.
function for_binding_hover(source: str, line: ptr_uint, character: ptr_uint, name: str) -> Option[CursorResult]:
    let cursor_line_text = cursor.source_line(source, line + 1)
    if cursor_line_text.len == 0:
        return Option[CursorResult].none

    # Look for "for " then the name then " in" on the same line.
    let ft = cursor_line_text.find_substring("for ")
    let fo = ft else:
        return Option[CursorResult].none
    let after_for = fo + 4
    if after_for + name.len > cursor_line_text.len:
        return Option[CursorResult].none
    if not cursor_line_text.slice(after_for, name.len).equal(name):
        return Option[CursorResult].none
    var hover = string.String.create()
    hover.append("for binding ")
    hover.append(name)
    return Option[CursorResult].some(value = quick_hover(hover.as_str()))


## Token-level heuristic: is this identifier a match-arm "as" binding?
## Checks whether the identifier is preceded by `as ` on the same line.
function as_binding_hover(source: str, line: ptr_uint, character: ptr_uint, name: str) -> Option[CursorResult]:
    let cursor_line_text = cursor.source_line(source, line + 1)
    if cursor_line_text.len == 0:
        return Option[CursorResult].none
    if name.len + 4 > cursor_line_text.len:
        return Option[CursorResult].none

    # Check if preceded by "as " on the same line.
    let lt = cursor_line_text.slice(0, character)
    if lt.len < 3:
        return Option[CursorResult].none
    let end = lt.len
    if lt.byte_at(end - 1) == ' ':
        # Walk back past whitespace before the name
        var p = end - 1
        while p > 0 and lt.byte_at(p - 1) == ' ':
            p -= 1
        if p >= 2 and lt.byte_at(p - 2) == 'a' and lt.byte_at(p - 1) == 's':
            var hover = string.String.create()
            hover.append("import alias ")
            hover.append(name)
            return Option[CursorResult].some(value = quick_hover(hover.as_str()))
    return Option[CursorResult].none


## Lexical fallback: search source text for any `let`/`var`/`const`
## declaration matching `name` before the cursor line.
function lexical_local_hover(source: str, target_line: ptr_uint, character: ptr_uint, name: str) -> Option[CursorResult]:
    var current_line: ptr_uint = target_line
    while current_line >= 1:
        let lt = cursor.source_line(source, current_line)
        let trimmed = lt.trim_ascii_whitespace()
        var prefix: str = ""
        if trimmed.starts_with("let "):
            prefix = "let "
        else if trimmed.starts_with("var "):
            prefix = "var "
        else if trimmed.starts_with("const "):
            prefix = "const "
        else:
            if current_line == 1:
                break
            current_line -= 1
            continue
        let after_prefix = prefix.len
        if after_prefix + name.len <= trimmed.len and trimmed.slice(after_prefix, name.len).equal(name):
            var hover = string.String.create()
            hover.append(prefix)
            hover.append(name)
            hover.append(" (lexical)")
            hover.release()
        if current_line == 1:
            break
        current_line -= 1
    return Option[CursorResult].none


## Walk the top-level statements in a stmt_block body looking for a
## local declaration of `name`.
function find_local_in_block(
    block_stmt: ast.Stmt,
    name: str,
) -> Option[CursorResult]:
    match block_stmt:
        ast.Stmt.stmt_block as blk:
            var si: ptr_uint = 0
            while si < blk.statements.len:
                var s = unsafe: read(blk.statements.data + si)
                match s:
                    ast.Stmt.stmt_local as loc:
                        if loc.name == name:
                            var hover = string.String.create()
                            if loc.is_let:
                                hover.append("let ")
                            else:
                                hover.append("var ")
                            hover.append(name)
                            if loc.stmt_type != null:
                                hover.append(": ")
                                let ty = unsafe: read(ptr[ast.TypeRef]<-loc.stmt_type)
                                if ty.name.parts.len > 0:
                                    hover.append(unsafe: read(ty.name.parts.data))
                            return Option[CursorResult].some(value = make_result(loc.line, name, "", hover))
                    _:
                        pass
                si += 1
        _:
            pass
    return Option[CursorResult].none



## Write a CursorResult as a hover JSON-RPC response.
function write_hover_result(id: json.Value, res: CursorResult) -> void:
    var payload = res
    if payload.hover_text.len() > 0:
        var value_text = string.String.create()
        defer value_text.release()
        value_text.append("```milk-tea\n")
        value_text.append(payload.hover_text.as_str())
        value_text.append("\n```")
        if payload.docs.len() > 0:
            value_text.append("\n")
            value_text.append(payload.docs.as_str())
        if payload.line > 0:
            value_text.append("\n\n*Defined at line ")
            value_text.append_format(f"#{payload.line}")
            value_text.append("*")
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
