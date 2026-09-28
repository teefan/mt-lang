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
import mtc.lexer.token_kinds as tk
import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.loader.path_resolver as resolver
import mtc.lsp.cursor as cursor
import mtc.lsp.definition_index as defidx
import mtc.lsp.hover_docs as hover_docs
import mtc.lsp.protocol as proto
import mtc.lsp.scope as scope_mod
import mtc.lsp.type_render as type_render
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace
import mtc.lsp.workspace_index as ws_idx
import mtc.pretty_printer.ast_formatter as ast_formatter


## Handle textDocument/definition (and `declaration`, which the host answers
## with the same pipeline): resolve the symbol at the cursor, then — when that
## yields no source location, as it does for a parameter — fall back to the
## workspace-wide definition index, exactly as the host's last resort does.
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

    var target_uri = string.String.create()
    defer: target_uri.release()
    var target_line: ptr_uint = 0
    var target_column: ptr_uint = 0
    var target_len: ptr_uint = 0
    var located = false

    match result:
        Option.some as res:
            var payload = res.value
            if payload.line > 0:
                located = true
                target_uri.release()
                if payload.target_uri.len() > 0:
                    target_uri = string.String.from_str(payload.target_uri.as_str())
                else:
                    target_uri = string.String.from_str(uri)
                target_line = payload.line
                target_column = payload.column
                target_len = payload.name_len
            payload.hover_text.release()
            payload.docs.release()
            payload.target_uri.release()
            payload.from_modules.release()
        Option.none:
            pass

    # `alias.Member` where the member is not a declaration of that module: the
    # host's definition pipeline answers the module file itself (the same
    # position's hover stays null, so this is the definition path only).
    if not located:
        match alias_member_module_path(ws, uri, line, character):
            Option.some as member_module_path:
                var member_module_uri = file_uri_for_path(member_module_path.value.as_str())
                respond_module_location(id, member_module_uri.as_str())
                member_module_uri.release()
                member_module_path.value.release()
                return
            Option.none:
                pass

    if not located:
        match uri_ops.file_uri_to_path(uri):
            Option.some as file_path:
                var content_opt = ws.document_source(file_path.value.as_str())
                if content_opt.is_some():
                    var content = content_opt.unwrap()
                    match cursor.identifier_at(content.as_str(), line, character):
                        Option.some as name:
                            match find_definition_global(ws, name.value.text, uri, line + 1, character + 1):
                                Option.some as found:
                                    located = true
                                    target_uri.release()
                                    target_uri = file_uri_for_path(found.value.path.as_str())
                                    found.value.path.release()
                                    target_line = found.value.line
                                    target_column = if found.value.column > 0: found.value.column - 1 else: 0z
                                    target_len = found.value.length
                                Option.none:
                                    pass
                        Option.none:
                            pass
                    content.release()
            Option.none:
                pass

    if not located:
        proto.write_response(id, json.null_value())
        return

    let lz = if target_line > 0: ptr_uint<-(int<-(target_line) - 1) else: 0z
    var json_text = string.String.create()
    defer: json_text.release()
    # A single definition is a bare `Location` object, as the host emits.
    json_text.append("{\"uri\":\"")
    proto.append_escaped(ref_of(json_text), target_uri.as_str())
    json_text.append("\",\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{target_column}")
    json_text.append("},\"end\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{target_column + target_len}")
    json_text.append("}}}")
    proto.write_response_raw(id, json_text.as_str())


public function handle_hover(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
    id: json.Value,
) -> void:
    var hover_token_range = hover_range_json(ws, uri, line, character)
    # An `import` line's path or alias resolves to the module file, ahead of the
    # keyword/builtin tables: `str` in `import std.str` is the module, not the
    # builtin type.
    match resolve_import_cursor(ws, uri, line, character):
        Option.some as import_result:
            write_hover_result(ws, id, import_result.value, uri, hover_token_range)
            return
        Option.none:
            pass
    match resolve_non_decl_hover(ws, uri, line, character):
        Option.some as kw_result:
            var kw_payload = kw_result.value
            # A keyword or builtin carries no source location of its own; the
            # host fills one in from its token index when the name is declared
            # somewhere in the workspace.
            if kw_payload.line == 0:
                apply_hover_index_location(ws, uri, line, character, ref_of(kw_payload))
            write_hover_result(ws, id, kw_payload, uri, hover_token_range)
            return
        Option.none:
            pass

    match resolve_local_hover(ws, uri, line, character):
        Option.some as loc_result:
            var loc_payload = loc_result.value
            # The host prints a binding's hover location from its token index —
            # the last declaration of the name before the cursor, else the first
            # — not from the binding: a `for` or `match` binding, or a local the
            # index does not know, ends up with no `Defined at` line.
            apply_hover_index_location(ws, uri, line, character, ref_of(loc_payload))
            write_hover_result(ws, id, loc_payload, uri, hover_token_range)
            return
        Option.none:
            pass

    var result = resolve_cursor(ws, uri, line, character)
    match result:
        Option.some as res:
            write_hover_result(ws, id, res.value, uri, hover_token_range)
            return
        Option.none:
            pass
    hover_token_range.release()
    proto.write_response(id, json.null_value())


## Point `payload` at the workspace token index's declaration for the name under
## the cursor — the host's hover location for everything that carries no
## facts-based source location (bindings, keywords, builtins).  With nothing
## indexed the payload loses its location, so the hover prints no `Defined at`
## line, exactly as the host's does.
function apply_hover_index_location(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
    payload: ref[CursorResult],
) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        payload.line = 0
        payload.column = 0
        return
    defer: file_path.release()
    var content = ws.document_source(file_path.as_str()) else:
        payload.line = 0
        payload.column = 0
        return
    defer: content.release()
    match cursor.identifier_at(content.as_str(), line, character):
        Option.some as name:
            match find_definition_global(ws, name.value.text, uri, line + 1, character + 1):
                Option.some as found:
                    payload.line = found.value.line
                    payload.column = if found.value.column > 0: found.value.column - 1 else: 0z
                    payload.name_len = found.value.length
                    payload.target_uri.release()
                    payload.target_uri = file_uri_for_path(found.value.path.as_str())
                    found.value.path.release()
                    return
                Option.none:
                    pass
        Option.none:
            pass
    payload.line = 0
    payload.column = 0


## The `"range":{...}` fragment for the identifier under the cursor (the host
## includes it so the client can highlight the hovered symbol), or an empty
## string when no identifier is there.
function hover_range_json(ws: ref[workspace.Workspace], uri: str, line: ptr_uint, character: ptr_uint) -> string.String:
    var empty = string.String.create()
    var file_path = uri_ops.file_uri_to_path(uri) else:
        return empty
    defer: file_path.release()
    var content = ws.document_source(file_path.as_str()) else:
        return empty
    defer: content.release()
    match cursor.identifier_at(content.as_str(), line, character):
        Option.some as tok:
            var frag = hover_range_fragment(tok.value)
            empty.release()
            return frag
        Option.none:
            pass
    # Keywords, builtins and operators: the host ranges the token itself.
    match cursor.token_at(content.as_str(), line, character):
        Option.some as tok:
            var frag = hover_range_fragment(tok.value)
            empty.release()
            return frag
        Option.none:
            return empty


## Render the `"range":{...}` fragment for a resolved cursor token.
function hover_range_fragment(tok: cursor.CursorToken) -> string.String:
    let lz = if tok.line > 0: tok.line - 1 else: 0z
    let col = if tok.column > 0: tok.column - 1 else: 0z
    var frag = string.String.create()
    frag.append("\"range\":{\"start\":{\"line\":")
    frag.append_format(f"#{lz}")
    frag.append(",\"character\":")
    frag.append_format(f"#{col}")
    frag.append("},\"end\":{\"line\":")
    frag.append_format(f"#{lz}")
    frag.append(",\"character\":")
    frag.append_format(f"#{col + tok.length}")
    frag.append("}}")
    return frag


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
        proto.write_response_raw(id, "[]")
        return
    defer: file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response_raw(id, "[]")
        return
    defer: content.release()

    let source = content.as_str()
    let target = cursor.identifier_at(source, line, character) else:
        proto.write_response_raw(id, "[]")
        return

    # A bare type name resolves to the type's *methods* in the host (empty for a
    # builtin primitive, which has none); scanning for same-named occurrences
    # would report unrelated uses of `int`/`str`.
    if hover_docs.builtin_type(target.text).is_some():
        proto.write_response_raw(id, "[]")
        return

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var bindings = scope_mod.collect_bindings(source, ast_file)
    defer: bindings.release()

    # A local binding resolves within its scope in this file; every other
    # name is resolved through the workspace index.
    match scope_mod.local_binding_line(ref_of(bindings), target.text, target.line):
        Option.some as binding_line:
            var local_json = build_references_json(source, target.text, binding_line.value, uri)
            proto.write_response_raw(id, local_json.as_str())
            local_json.release()
        Option.none:
            ws.build_index_if_needed()
            var refs_json = build_references_json_cross_file(ws, target.text, file_path.as_str())
            proto.write_response_raw(id, refs_json.as_str())
            refs_json.release()


## Handle textDocument/typeDefinition — the host's
## `resolve_type_definition_location`.  A type or interface the document itself
## declares answers its own declaration; a type reached through a module alias
## answers that member's declaration, or the module file when the member is not a
## declaration there; everything else answers exactly as `definition` does (the
## host delegates to its definition pipeline).
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
    defer: file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer: content.release()

    let source = content.as_str()
    let target = cursor.identifier_at(source, line, character) else:
        proto.write_response(id, json.null_value())
        return

    # An `import` path segment names the module file itself.
    match resolve_import_cursor(ws, uri, line, character):
        Option.some as import_result:
            var import_payload = import_result.value
            respond_module_location(id, import_payload.target_uri.as_str())
            import_payload.hover_text.release()
            import_payload.docs.release()
            import_payload.target_uri.release()
            import_payload.from_modules.release()
            return
        Option.none:
            pass

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var parsed_file = parser.parse_source(source, ref_of(parse_diags))
    var ast_file = ast_for_document(ws, file_path.as_str(), parsed_file)
    var analysis = analysis_for_document(ws, file_path.as_str(), parsed_file)

    # A type or interface this document declares: its own declaration.
    if analysis.types.contains(target.text) or analysis.interfaces.contains(target.text):
        let decl_line = type_declaration_line(ast_file, target.text)
        if decl_line > 0:
            respond_single_location(id, uri, source, decl_line, target.text)
            return

    # `alias.Member`: the member's declaration inside the aliased module, or the
    # module file itself when the member is not a declaration there.
    match cursor.dot_receiver_at(source, line, character):
        Option.some as recv:
            unsafe:
                let module_ptr = analysis.imports.get(recv.value)
                if module_ptr != null:
                    let module_name = read(module_ptr)
                    if respond_imported_type_location(ws, id, module_name, target.text):
                        return
                    match resolve_module_source_path(ws, module_name):
                        Option.some as module_path:
                            var module_uri = file_uri_for_path(module_path.value.as_str())
                            respond_module_location(id, module_uri.as_str())
                            module_uri.release()
                            module_path.value.release()
                            return
                        Option.none:
                            pass
        Option.none:
            pass

    handle_definition(ws, uri, line, character, id)


## The analysis to answer type questions with: the loader-backed one when the
## document loads (imports bound, so `var n = node.Node.create(...)` types as
## `node.Node`), else the single-file check.  `ast_file` is re-pointed at the
## tree the analysis was built from, since `resolved_expr_types` is keyed by
## expression pointer.
function analysis_for_document(
    ws: ref[workspace.Workspace],
    file_path: str,
    parsed_file: ast.SourceFile,
) -> analyzer.Analysis:
    let entry = workspace.analysis_entry_for(ws, file_path) else:
        return analyzer.check_source_file(parsed_file)
    return unsafe: read(entry).analysis


## The AST the analysis above was built from.
function ast_for_document(
    ws: ref[workspace.Workspace],
    file_path: str,
    parsed_file: ast.SourceFile,
) -> ast.SourceFile:
    let entry = workspace.analysis_entry_for(ws, file_path) else:
        return parsed_file
    return unsafe: read(entry).analysis.source_file


## The type of the value named `name` at `target_line`: its inferred type for a
## local or parameter, its recorded type for a module-level value.  The binding
## comes from the scope walk, so the innermost enclosing declaration answers — a
## same-named local in another function cannot (the host resolves a member
## receiver from its scope snapshot the same way).
function type_of_value(
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    name: str,
    target_line: ptr_uint,
    source_text: str,
) -> Option[types.Type]:
    unsafe:
        let global_ptr = read(analysis).value_types.get(name)
        if global_ptr != null:
            return Option[types.Type].some(value = read(global_ptr))

    var bindings = scope_mod.collect_bindings(source_text, ast_file)
    defer: bindings.release()
    let decl_line = scope_mod.local_binding_line(ref_of(bindings), name, target_line) else:
        return Option[types.Type].none

    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                if fun.body != null:
                    match local_type_at_line(unsafe: read(ptr[ast.Stmt]<-fun.body), name, decl_line, analysis):
                        Option.some as local_ty:
                            return Option[types.Type].some(value = local_ty.value)
                        Option.none:
                            pass
                match resolved_param_type(fun.method_params, read(analysis).functions.get(fun.name), name, decl_line):
                    Option.some as param_ty:
                        return Option[types.Type].some(value = param_ty.value)
                    Option.none:
                        pass
            ast.Decl.decl_extending_block as ext:
                var mi: ptr_uint = 0
                while mi < ext.methods.len:
                    let method = unsafe: read(ext.methods.data + mi)
                    match local_type_at_line(unsafe: read(method.body), name, decl_line, analysis):
                        Option.some as method_ty:
                            return Option[types.Type].some(value = method_ty.value)
                        Option.none:
                            pass
                    match resolved_param_type(method.method_params,
                        method_signature_for(analysis, method.name, method.method_params), name, decl_line):
                        Option.some as method_param_ty:
                            return Option[types.Type].some(value = method_param_ty.value)
                        Option.none:
                            pass
                    mi += 1
            _:
                pass
        di += 1

    return Option[types.Type].none


## The type of the local named `name` declared on `want_line`: the inferred type
## of its initializer (an annotated local has no inferred type here).
function local_type_at_line(stmt: ast.Stmt, name: str, want_line: ptr_uint, analysis: ref[analyzer.Analysis]) -> Option[types.Type]:
    match find_local_decl_at_line(stmt, name, want_line):
        Option.some as found:
            match found.value:
                ast.Stmt.stmt_local as loc:
                    if loc.stmt_type != null:
                        return Option[types.Type].none
                    return type_render.initializer_type(analysis, loc.value)
                _:
                    return Option[types.Type].none
        Option.none:
            return Option[types.Type].none


## The resolved type of the parameter declared on `want_line` in `ast_params`.
## None when no such parameter (or no resolved signature) exists.
function resolved_param_type(ast_params: span[ast.Param], sig: ptr[analyzer.FnSig]?, name: str, want_line: ptr_uint) -> Option[types.Type]:
    var pi: ptr_uint = 0
    while pi < ast_params.len:
        let ast_param = unsafe: read(ast_params.data + pi)
        if ast_param.name.equal(name) and ast_param.line == want_line:
            if sig != null:
                let resolved = unsafe: read(ptr[analyzer.FnSig]<-sig)
                if pi < resolved.params.len:
                    return Option[types.Type].some(value = unsafe: read(resolved.params.data + pi).ty)
            return Option[types.Type].none
        pi += 1
    return Option[types.Type].none


## Locate `type_name`'s declaration inside `module_name`'s source file and
## respond with a cross-file location.
function respond_imported_type_location(
    ws: ref[workspace.Workspace],
    id: json.Value,
    module_name: str,
    type_name: str,
) -> bool:
    var roots = ws.effective_module_roots_for("")
    defer: roots.release()
    match resolver.resolve_module_path(module_name, roots.as_span(), resolver.Platform.linux):
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
            return false
        Result.success as path_payload:
            var module_path = path_payload.value
            defer: module_path.release()

            var module_source = ws.document_source(module_path.as_str()) else:
                return false
            defer: module_source.release()

            # The host's `module_member_definition_location` reads the module's
            # own declaration-token index, so a function, a const or a type all
            # resolve — not only type declarations.
            let token = defidx.document_declaration_token(
                ref_of(ws.definition_index), module_path.as_str(), module_source.as_str(), type_name) else:
                return false

            var absolute_path = string.String.from_str(module_path.as_str())
            match fs_mod.canonicalize(module_path.as_str()):
                Result.success as canonical:
                    absolute_path.release()
                    absolute_path = canonical.value
                Result.failure as canon_failure:
                    var canon_err = canon_failure.error
                    canon_err.release()
            defer: absolute_path.release()

            var target_uri = string.String.from_str("file://")
            defer: target_uri.release()
            target_uri.append(absolute_path.as_str())
            respond_token_location(id, target_uri.as_str(), token)
            return true


## Respond with the host's module Location: the module file's start (0:0-0:0),
## which is how an import path, an alias or a module declaration navigates.
function respond_module_location(id: json.Value, target_uri: str) -> void:
    var json_text = string.String.create()
    defer: json_text.release()
    json_text.append("{\"uri\":\"")
    proto.append_escaped(ref_of(json_text), target_uri)
    json_text.append("\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}}}")
    proto.write_response_raw(id, json_text.as_str())


## Respond with a `Location` pointing at a definition token (1-based
## line/column — the host's `token_to_range`, emitted as a bare Location object
## like `respond_single_location`).
function respond_token_location(id: json.Value, target_uri: str, token: defidx.DefinitionToken) -> void:
    let lz = if token.line > 0: token.line - 1 else: 0z
    let col = if token.column > 0: token.column - 1 else: 0z
    var json_text = string.String.create()
    defer: json_text.release()
    json_text.append("{\"uri\":\"")
    proto.append_escaped(ref_of(json_text), target_uri)
    json_text.append("\",\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{col}")
    json_text.append("},\"end\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{col + token.length}")
    json_text.append("}}}")
    proto.write_response_raw(id, json_text.as_str())


## Respond with a `Location` pointing at `name` on its declaration line.
function respond_single_location(id: json.Value, uri: str, source: str, decl_line: ptr_uint, name: str) -> void:
    let lz = if decl_line > 0: decl_line - 1 else: 0z
    var column: ptr_uint = 0
    match cursor.token_start_in_line(cursor.source_line(source, decl_line), name):
        Option.some as pos:
            column = pos.value
        Option.none:
            pass

    var json_text = string.String.create()
    defer: json_text.release()
    # A single location is a bare `Location` object, as the host emits (an array
    # is only used when the response can carry several locations).
    json_text.append("{\"uri\":\"")
    proto.append_escaped(ref_of(json_text), uri)
    json_text.append("\",\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{column}")
    json_text.append("},\"end\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{column + name.len}")
    json_text.append("}}}")
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
    defer: file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer: content.release()

    let source = content.as_str()
    let target = cursor.identifier_at(source, line, character) else:
        proto.write_response_raw(id, "[]")
        return

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var analysis = analyzer.check_source_file(ast_file)

    if not analysis.interfaces.contains(target.text):
        proto.write_response_raw(id, "[]")
        return

    var json_text = string.String.create()
    defer: json_text.release()
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
    defer: seen.release()

    # Always include the current file first (open editor buffer).
    match include_refs_from_file(ws, uri, name, ref_of(result), ref_of(first)):
        Option.some as u:
            seen.set(u.value.as_str(), true)
        Option.none:
            pass

    # Cross-file references come from the declaration's import dependents: the
    # host scopes them with `reverse_import_dependents_for`, so a file that
    # merely declares the same name elsewhere in the workspace is not a
    # reference site, while a file that imports the declaration's module is.
    var dependents = ws_idx.dependents_of(ref_of(ws.index), uri)
    defer: dependents.release()

    var di: ptr_uint = 0
    while di < dependents.len():
        let dp = dependents.get(di) else:
            break
        let path = unsafe: read(dp).as_str()
        if not seen.contains(path):
            match include_refs_from_file(ws, path, name, ref_of(result), ref_of(first)):
                Option.some as u2:
                    seen.set(u2.value.as_str(), true)
                Option.none:
                    pass
        di += 1

    result.append("]")
    return result


## The reference count the host reports for the symbol declared at `line`:
## `module_level_reference_locations(..., include_declaration: true).length` —
## the same-file, scope-aware occurrences of the declared name.  (The host also
## adds occurrences from files that import the declaration's module; the
## self-host does not track reverse import dependents yet — §0k.)
public function count_declaration_references(ws: ref[workspace.Workspace], name: str, file_path: str, line: ptr_uint) -> ptr_uint:
    if name.len == 0 or file_path.len == 0:
        return 0

    var maybe_content = ws.document_source(file_path)
    if maybe_content.is_none():
        return 0
    var content = maybe_content.unwrap()
    defer: content.release()

    return count_same_scope_occurrences(content.as_str(), name, line)


## Count the same-file, scope-aware occurrences (`build_references_json`'s rule).
function count_same_scope_occurrences(source: str, name: str, target_line: ptr_uint) -> ptr_uint:
    var occurrences = cursor.identifier_occurrences(source, name)
    defer: occurrences.release()

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var bindings = scope_mod.collect_bindings(source, ast_file)
    defer: bindings.release()

    var total: ptr_uint = 0
    var oi: ptr_uint = 0
    while oi < occurrences.len():
        let op = occurrences.get(oi) else:
            break
        let occ = unsafe: read(op)
        if scope_mod.is_in_same_scope(ref_of(bindings), name, target_line, occ.line):
            total += 1
        oi += 1
    return total


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
    defer: cw.release()
    let source = cw.as_str()
    if source.len == 0:
        return Option[string.String].none

    var occurrences = cursor.identifier_occurrences(source, name)
    defer: occurrences.release()

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
        output.append("}}}")
        oi += 1

    file_uri.release()
    return Option[string.String].some(value = string.String.from_str(file_ref))


function build_references_json(source: str, name: str, target_line: ptr_uint, uri: str) -> string.String:
    var result = string.String.create()
    result.append("[")

    var all_occurrences = cursor.identifier_occurrences(source, name)
    defer: all_occurrences.release()

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var bindings = scope_mod.collect_bindings(source, ast_file)
    defer: bindings.release()

    var oi: ptr_uint = 0
    # The separator follows what was *emitted*, not the occurrence index: an
    # out-of-scope occurrence is skipped, so `oi > 0` would emit a leading comma
    # after a skipped first occurrence (malformed JSON the client rejects).
    var first_emitted = true
    while oi < all_occurrences.len():
        let op = all_occurrences.get(oi) else:
            break
        let occ = unsafe: read(op)
        if not scope_mod.is_in_same_scope(ref_of(bindings), name, target_line, occ.line):
            oi += 1
            continue
        if not first_emitted:
            result.append(",")
        first_emitted = false
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
    ## Module names stripped from the hovered signature, ", "-joined; rendered
    ## as the host's `*From <modules>*` line.  Empty when nothing was stripped.
    from_modules: string.String


## The module an `alias.Member` reference names, when the cursor is on the
## member: the aliased module's source path.  None when the receiver is not an
## import alias.
function alias_member_module_path(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
) -> Option[string.String]:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        return Option[string.String].none
    defer: file_path.release()
    var content = ws.document_source(file_path.as_str()) else:
        return Option[string.String].none
    defer: content.release()
    let source = content.as_str()

    match cursor.dot_receiver_at(source, line, character):
        Option.some as recv:
            var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
            defer: parse_diags.release()
            var parsed_file = parser.parse_source(source, ref_of(parse_diags))
            var analysis = analysis_for_document(ws, file_path.as_str(), parsed_file)
            unsafe:
                let module_ptr = analysis.imports.get(recv.value)
                if module_ptr != null:
                    return resolve_module_source_path(ws, read(module_ptr))
        Option.none:
            pass
    return Option[string.String].none


## The host's last-resort global definition lookup (`find_definition_token_global`):
## the requesting document first with the cursor as the position filter, then
## every other open document in didOpen order, first declaration wins.  Only
## identifiers a declaration keyword introduces are indexed, so an ordinary
## reference or a parameter answers none, as the host's does.
function find_definition_global(
    ws: ref[workspace.Workspace],
    name: str,
    preferred_uri: str,
    before_line: ptr_uint,
    before_char: ptr_uint,
) -> Option[defidx.DefinitionEntry]:
    var preferred_path = uri_ops.file_uri_to_path(preferred_uri) else:
        return Option[defidx.DefinitionEntry].none
    defer: preferred_path.release()

    var owned_sources = vec.Vec[string.String].create()
    defer: release_owned_sources(ref_of(owned_sources))
    var candidates = vec.Vec[defidx.CandidateDocument].create()
    defer: candidates.release()

    add_definition_candidate(ws, ref_of(owned_sources), ref_of(candidates), preferred_path.as_str())
    var i: ptr_uint = 0
    while i < ws.open_doc_order.len():
        let path_ptr = ws.open_doc_order.get(i) else:
            break
        add_definition_candidate(ws, ref_of(owned_sources), ref_of(candidates), unsafe: read(path_ptr).as_str())
        i += 1

    return defidx.lookup(ref_of(ws.definition_index), name, preferred_path.as_str(), before_line, before_char, candidates.as_span())


## Append `path`'s text (kept alive by `owned_sources`) to the candidate list,
## once, when the document can be read.
function add_definition_candidate(
    ws: ref[workspace.Workspace],
    owned_sources: ref[vec.Vec[string.String]],
    candidates: ref[vec.Vec[defidx.CandidateDocument]],
    path: str,
) -> void:
    if path.len == 0:
        return
    var i: ptr_uint = 0
    while i < candidates.len():
        let existing = candidates.get(i) else:
            break
        if unsafe: read(existing).uri.equal(path):
            return
        i += 1
    let source = ws.document_source(path) else:
        return
    owned_sources.push(source)
    let stored = owned_sources.last() else:
        return
    candidates.push(defidx.CandidateDocument(uri = path, source = unsafe: read(stored).as_str()))


function release_owned_sources(sources: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < sources.len():
        let entry = sources.get(i) else:
            break
        unsafe: read(entry).release()
        i += 1
    sources.release()


## Quick hover result — no declaration source line, no docs.
function quick_hover(text: str) -> CursorResult:
    return CursorResult(
        line = 0,
        column = 0,
        name_len = 0,
        hover_text = string.String.from_str(text),
        docs = string.String.create(),
        target_uri = string.String.create(),
        from_modules = string.String.create()
    )


## Quick hover result carrying the host's long-form docs — signature in the
## fence, docs below it, and no `Defined at` line (the host renders none for
## keywords and builtins).
function quick_hover_doc(doc: hover_docs.HoverDoc) -> CursorResult:
    return CursorResult(
        line = 0,
        column = 0,
        name_len = 0,
        hover_text = string.String.from_str(doc.signature),
        docs = string.String.from_str(doc.docs),
        target_uri = string.String.create(),
        from_modules = string.String.create()
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
    defer: file_path.release()
    var content = ws.document_source(file_path.as_str()) else:
        return Option[CursorResult].none
    defer: content.release()
    let source = content.as_str()
    if source.len == 0:
        return Option[CursorResult].none

    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()

    var ti: ptr_uint = 0
    var matched_index: ptr_uint = 0
    var matched = false
    let target_line = line + 1
    while ti < tokens.len:
        let tp = tokens.get(ti) else:
            break
        let t = unsafe: read(tp)
        if t.line > target_line:
            break
        if t.line == target_line and t.column - 1 <= character and t.column - 1 + t.end_offset - t.start_offset > character:
            matched_index = ti
            matched = true
            let lexeme = unsafe: token_mod.token_lexeme(t, source)

            match hover_docs.language_keyword(lexeme):
                Option.some as kw:
                    return Option[CursorResult].some(value = quick_hover_doc(kw.value))
                Option.none:
                    pass

            # A builtin type name (`int`, `str`, `ptr`, …) renders the host's
            # `type <name>` signature with its documentation table.
            match hover_docs.builtin_type(lexeme):
                Option.some as bt:
                    return Option[CursorResult].some(value = quick_hover_doc(bt.value))
                Option.none:
                    pass

            match builtin_specialization_hover(tokens, ti, lexeme):
                Option.some as bs:
                    return Option[CursorResult].some(value = quick_hover(bs.value))
                Option.none:
                    pass

            match hover_docs.builtin_call(lexeme):
                Option.some as bu:
                    return Option[CursorResult].some(value = quick_hover_doc(bu.value))
                Option.none:
                    pass

            break
        ti += 1

    match field_declaration_hover(source, line, character):
        Option.some as fd:
            return Option[CursorResult].some(value = fd.value)
        Option.none:
            pass

    if matched:
        match named_argument_label_hover(ws, source, file_path.as_str(), ref_of(tokens), matched_index):
            Option.some as label_hover:
                return Option[CursorResult].some(value = label_hover.value)
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
    defer: file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        return Option[CursorResult].none
    defer: content.release()

    let source = content.as_str()
    if source.len == 0:
        return Option[CursorResult].none

    let target = cursor.identifier_at(source, line, character) else:
        return Option[CursorResult].none

    # A segment of an `import a.b.c` path resolves to that module's file, as the
    # alias itself does (the host's `import_path_info_at`).
    match import_module_name_at(source, line, character):
        Option.some as import_name:
            defer: import_name.value.release()
            return resolve_module_reference(ws, import_name.value.as_str())
        Option.none:
            pass

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var parsed_file = parser.parse_source(source, ref_of(parse_diags))
    if parse_diags.len() > 0:
        return Option[CursorResult].none

    # The facts come from the loader-backed analysis, as the host's do: a
    # standalone check carries no import bindings, so every `alias.Type` and
    # `alias.member` reference would resolve to `<error>`.
    var ast_file = ast_for_document(ws, file_path.as_str(), parsed_file)
    var analysis = analysis_for_document(ws, file_path.as_str(), parsed_file)
    var module_roots = ws.effective_module_roots_for(file_path.as_str())
    defer: module_roots.release()
    var current_module = resolver.infer_module_name(file_path.as_str(), module_roots.as_span())
    defer: current_module.release()

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

    match resolve_name_in_analysis(ast_file, ref_of(analysis), target.text, source, current_module.as_str()):
        Option.some as named:
            return Option[CursorResult].some(value = named.value)
        Option.none:
            pass

    # `value.method(...)`: the method's resolved signature from its defining
    # module (this one, or the module that declares the receiver's type).
    match cursor.dot_receiver_at(source, line, character):
        Option.some as recv:
            match resolve_member_method_hover(
                ws, ast_file, ref_of(analysis), source, file_path.as_str(), recv.value, target.text,
                line + 1, current_module.as_str()):
                Option.some as member_result:
                    return Option[CursorResult].some(value = member_result.value)
                Option.none:
                    pass
        Option.none:
            pass

    # `Type.method(...)` / `Type[T].method(...)` / `alias.Type.method(...)`: a
    # *type* receiver, whose method lives in the type's own module.
    match cursor.type_receiver_at(source, line, character):
        Option.some as type_recv:
            return resolve_type_method_hover(
                ws, ast_file, ref_of(analysis), source, type_recv.value, target.text,
                current_module.as_str())
        Option.none:
            return Option[CursorResult].none


## Hover for the method of a *type* receiver (`Vec[int].create()`): the static
## method's declaration signature from the module that declares the type — the
## aliased module for `alias.Type`, else the module the type's name resolves to.
## None when the receiver is not a type of the program or declares no such
## method, so a value receiver keeps its own path.
function resolve_type_method_hover(
    ws: ref[workspace.Workspace],
    ast_file: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    source: str,
    receiver: cursor.TypeReceiver,
    method_name: str,
    current_module: str,
) -> Option[CursorResult]:
    var decl_file = ast_file
    var decl_source = source
    var target_uri = string.String.create()
    var decl_signature = method_sig_for_type(analysis, receiver.name, method_name)
    var owner: str = ""

    if receiver.module_alias.len > 0:
        let module_ptr = unsafe: read(analysis).imports.get(receiver.module_alias) else:
            target_uri.release()
            return Option[CursorResult].none
        owner = unsafe: read(module_ptr)
    else if unsafe: read(analysis).types.contains(receiver.name):
        let type_ptr = unsafe: read(analysis).types.get(receiver.name) else:
            target_uri.release()
            return Option[CursorResult].none
        owner = types.nominal_module(unsafe: read(ptr[types.Type]<-type_ptr))
    else:
        target_uri.release()
        return Option[CursorResult].none

    if decl_signature.is_none() and owner.len > 0 and not owner.equal(current_module):
        var owner_path = resolve_module_source_path(ws, owner) else:
            target_uri.release()
            return Option[CursorResult].none
        defer: owner_path.release()
        let owner_source = ws.document_source(owner_path.as_str()) else:
            target_uri.release()
            return Option[CursorResult].none
        var owner_diags = vec.Vec[pstate.ParseDiagnostic].create()
        defer: owner_diags.release()
        var owner_parsed = parser.parse_source(owner_source.as_str(), ref_of(owner_diags))
        decl_file = ast_for_document(ws, owner_path.as_str(), owner_parsed)
        var owner_analysis = analysis_for_document(ws, owner_path.as_str(), owner_parsed)
        decl_signature = method_sig_for_type(ref_of(owner_analysis), receiver.name, method_name)
        decl_source = owner_source.as_str()
        target_uri.release()
        target_uri = file_uri_for_path(owner_path.as_str())

    let signature = decl_signature else:
        target_uri.release()
        return Option[CursorResult].none
    let decl_line = find_method_line(decl_file, method_name)
    if decl_line == 0:
        target_uri.release()
        return Option[CursorResult].none

    var hover = method_signature_text(signature, method_name, owner_or(current_module, owner))
    let result = make_shortened_result(decl_line, method_name, decl_source, hover.as_str())
    hover.release()
    var stamped = result
    stamped.target_uri.release()
    stamped.target_uri = target_uri
    return Option[CursorResult].some(value = stamped)


## The bare type name a method receiver resolves to (`Vec`, `Color`), "" for a
## type that is not nominal.
function receiver_type_name(ty: types.Type) -> str:
    match ty:
        types.Type.ty_imported as im:
            return im.name
        types.Type.ty_named as n:
            return n.name
        types.Type.ty_generic as g:
            return g.name
        types.Type.ty_nullable as nl:
            return receiver_type_name(unsafe: read(nl.base))
        _:
            return ""


## True when a `method_sigs` key's type part names `type_name`: the keys carry
## the type as written in its `extending` block (`Vec[T]`) or its canonical
## name, and a call site sees `Vec`.
function method_key_names_type(key_prefix: str, type_name: str) -> bool:
    if key_prefix.equal(type_name):
        return true
    match key_prefix.find_byte('['):
        Option.some as bracket:
            return key_prefix.slice(0, bracket.value).equal(type_name)
        Option.none:
            return false


## The signature of `type_name`'s method `method_name` in `analysis`.
function method_sig_for_type(analysis: ref[analyzer.Analysis], type_name: str, method_name: str) -> Option[analyzer.FnSig]:
    var entries = unsafe: read(analysis).method_sigs.entries()
    while entries.next():
        let entry = entries.current()
        let key = unsafe: read(entry.key)
        if key.len <= method_name.len + 1 or not key.ends_with(method_name):
            continue
        let split = key.len - method_name.len - 1
        if key.byte_at(split) != '.':
            continue
        if method_key_names_type(key.slice(0, split), type_name):
            return Option[analyzer.FnSig].some(value = unsafe: read(entry.value))
    return Option[analyzer.FnSig].none


## The host's `method_signature`: `[async ]<keyword> function name(params) -> ret`
## with the method-kind keyword and the return type always rendered.
function method_signature_text(sig: analyzer.FnSig, name: str, current_module: str) -> string.String:
    var text = string.String.create()
    if sig.is_async:
        text.append("async ")
    match sig.method_kind:
        ast.MethodKind.mk_editable:
            text.append("editable function ")
        ast.MethodKind.mk_static:
            text.append("static function ")
        _:
            text.append("function ")
    text.append(name)
    text.append("(")
    var pi: ptr_uint = 0
    while pi < sig.params.len:
        let param = unsafe: read(sig.params.data + pi)
        if pi > 0:
            text.append(", ")
        text.append(param.name)
        text.append(": ")
        var param_text = type_render.qualified_name(param.ty, current_module)
        text.append(param_text.as_str())
        param_text.release()
        pi += 1
    text.append(") -> ")
    var return_text = type_render.qualified_name(sig.return_type, current_module)
    text.append(return_text.as_str())
    return_text.release()
    return text


## The module a receiver's types render against: the declaring module when the
## receiver type carries one, else the file's own module.
function owner_or(current_module: str, owner: str) -> str:
    if owner.len > 0:
        return owner
    return current_module


## The hover for a field of the receiver's type: `field <name>: <resolved type>`
## with the field's declaration in the module that declares the struct (this
## file when the type is declared here).  None when the type has no such field,
## so the caller's method lookup still applies.
function field_hover_result(
    ws: ref[workspace.Workspace],
    file_path: str,
    owner: str,
    type_name: str,
    field_name: str,
    current_module: str,
) -> Option[CursorResult]:
    var decl_path = file_path
    var owner_path_owner: Option[string.String] = Option[string.String].none
    if owner.len > 0 and not owner.equal(current_module):
        var resolved_path = resolve_module_source_path(ws, owner) else:
            return Option[CursorResult].none
        owner_path_owner = Option[string.String].some(value = resolved_path)
        decl_path = resolved_path.as_str()
    defer:
        match owner_path_owner:
            Option.some as owned_path:
                owned_path.value.release()
            Option.none:
                pass

    var decl_source = ws.document_source(decl_path) else:
        return Option[CursorResult].none
    defer: decl_source.release()

    var decl_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: decl_diags.release()
    var decl_parsed = parser.parse_source(decl_source.as_str(), ref_of(decl_diags))
    var decl_file = ast_for_document(ws, decl_path, decl_parsed)
    var decl_analysis = analysis_for_document(ws, decl_path, decl_parsed)

    var field_line: ptr_uint = 0
    var field_column: ptr_uint = 0
    var field_type = types.Type.ty_error
    var found = false
    var di: ptr_uint = 0
    while di < decl_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(decl_file.declarations.data + di)
        match decl:
            ast.Decl.decl_struct as st:
                if st.name.equal(type_name):
                    var fi: ptr_uint = 0
                    while fi < st.struct_fields.len:
                        let field = unsafe: read(st.struct_fields.data + fi)
                        if field.name.equal(field_name):
                            field_line = field.line
                            field_column = field.column
                            found = true
                        fi += 1
            _:
                pass
        di += 1
    if not found or field_line == 0:
        return Option[CursorResult].none

    let entries_ptr = decl_analysis.structs.get(type_name)
    if entries_ptr != null:
        let entries = unsafe: read(entries_ptr)
        var fi: ptr_uint = 0
        while fi < entries.len:
            let entry = unsafe: read(entries.data + fi)
            if entry.name.equal(field_name):
                field_type = entry.ty
            fi += 1

    var hover = string.String.create()
    hover.append("field ")
    hover.append(field_name)
    hover.append(": ")
    var rendered = type_render.qualified_name(field_type, current_module)
    hover.append(rendered.as_str())
    rendered.release()
    var shortened = type_render.shorten_signature(hover.as_str())
    hover.release()

    var target_uri = string.String.create()
    if not decl_path.equal(file_path):
        target_uri = file_uri_for_path(decl_path)

    let column_zero = if field_column > 0: field_column - 1 else: 0z
    return Option[CursorResult].some(value = CursorResult(
        line = field_line,
        column = column_zero,
        name_len = field_name.len,
        hover_text = shortened.text,
        docs = string.String.create(),
        target_uri = target_uri,
        from_modules = shortened.modules
    ))


## Hover for the method name of a member call (`v.push(1)`, `d.push_back(x)`):
## the method's declaration signature, the module that declares it, and — through
## the shortened signature — that module's `*From <module>*` line.  The receiver
## type comes from the analysis (a local, parameter or module-level value); the
## method is looked up in this module's `extending` blocks and then in the module
## that declares the receiver's type.  None when the receiver is not a value or
## no such method is declared, so `EnumType.member` and `alias.member` keep their
## own paths.
function resolve_member_method_hover(
    ws: ref[workspace.Workspace],
    ast_file: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    source: str,
    file_path: str,
    receiver_name: str,
    method_name: str,
    target_line: ptr_uint,
    current_module: str,
) -> Option[CursorResult]:
    let receiver_ty = type_of_value(analysis, ast_file, receiver_name, target_line, source) else:
        return Option[CursorResult].none
    let type_name = receiver_type_name(receiver_ty)
    if type_name.len == 0:
        return Option[CursorResult].none

    let owner = types.nominal_module(receiver_ty)

    # A field of the receiver's type comes first (the host checks a member's
    # field before its methods): `p.radius` → `field radius: float`.
    match field_hover_result(ws, file_path, owner, type_name, method_name, current_module):
        Option.some as field_result:
            return Option[CursorResult].some(value = field_result.value)
        Option.none:
            pass

    var decl_file = ast_file
    var decl_source = source
    var decl_signature = method_sig_for_type(analysis, type_name, method_name)
    var target_uri = string.String.create()

    if decl_signature.is_none() and owner.len > 0 and not owner.equal(current_module):
        var owner_path = resolve_module_source_path(ws, owner) else:
            target_uri.release()
            return Option[CursorResult].none
        defer: owner_path.release()
        let owner_source = ws.document_source(owner_path.as_str()) else:
            target_uri.release()
            return Option[CursorResult].none
        var owner_diags = vec.Vec[pstate.ParseDiagnostic].create()
        defer: owner_diags.release()
        var owner_parsed = parser.parse_source(owner_source.as_str(), ref_of(owner_diags))
        decl_file = ast_for_document(ws, owner_path.as_str(), owner_parsed)
        var owner_analysis = analysis_for_document(ws, owner_path.as_str(), owner_parsed)
        decl_signature = method_sig_for_type(ref_of(owner_analysis), type_name, method_name)
        decl_source = owner_source.as_str()
        target_uri.release()
        target_uri = file_uri_for_path(owner_path.as_str())

    let signature = decl_signature else:
        target_uri.release()
        return Option[CursorResult].none
    let decl_line = find_method_line(decl_file, method_name)
    if decl_line == 0:
        target_uri.release()
        return Option[CursorResult].none

    var hover = method_signature_text(signature, method_name, owner_or(current_module, owner))
    let result = make_shortened_result(decl_line, method_name, decl_source, hover.as_str())
    hover.release()
    var stamped = result
    stamped.target_uri.release()
    stamped.target_uri = target_uri
    return Option[CursorResult].some(value = stamped)


## Resolve `member` inside imported module `module_name`: check the module's
## file with its own imports bound, reuse the same-file resolver there, and
## stamp the result with the module file's URI.
function resolve_module_member(ws: ref[workspace.Workspace], module_name: str, member: str) -> Option[CursorResult]:
    var module_path = resolve_module_source_path(ws, module_name) else:
        return Option[CursorResult].none
    defer: module_path.release()

    var module_source = ws.document_source(module_path.as_str()) else:
        return Option[CursorResult].none
    defer: module_source.release()

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var parsed_module = parser.parse_source(module_source.as_str(), ref_of(parse_diags))
    var module_file = ast_for_document(ws, module_path.as_str(), parsed_module)
    var module_analysis = analysis_for_document(ws, module_path.as_str(), parsed_module)

    # A type the module exports: the host's `module_binding.types` arm renders
    # `type <name>` (with no `=` target, unlike a file-local type hover) and
    # points at the declaration inside the module.
    if module_analysis.types.contains(member):
        let decl_line = type_declaration_line(module_file, member)
        if decl_line > 0:
            var hover = string.String.create()
            hover.append("type ")
            hover.append(member)
            var type_result = make_result(decl_line, member, module_source.as_str(), hover)
            type_result.target_uri.release()
            type_result.target_uri = file_uri_for_path(module_path.as_str())
            return Option[CursorResult].some(value = type_result)

    match resolve_name_in_analysis(module_file, ref_of(module_analysis), member, module_source.as_str(), module_name):
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
    defer: module_path.release()

    var hover = string.String.create()
    hover.append("module ")
    hover.append(module_name)
    return Option[CursorResult].some(value = CursorResult(
        line = 1,
        column = 0,
        name_len = 0,
        hover_text = hover,
        docs = string.String.create(),
        target_uri = file_uri_for_path(module_path.as_str()),
        from_modules = string.String.create()
    ))


## The resolved source path of `module_name` against the workspace roots.
function resolve_module_source_path(ws: ref[workspace.Workspace], module_name: str) -> Option[string.String]:
    var roots = ws.effective_module_roots_for("")
    defer: roots.release()
    match resolver.resolve_module_path(module_name, roots.as_span(), resolver.Platform.linux):
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
            return Option[string.String].none
        Result.success as path_payload:
            return Option[string.String].some(value = path_payload.value)


## True for the structural tokens that never belong to a logical line.
function is_structural_token_kind(kind: tk.TokenKind) -> bool:
    return kind == tk.TokenKind.newline or kind == tk.TokenKind.indent or kind == tk.TokenKind.dedent or kind == tk.TokenKind.eof


## The module an `import` statement names when the cursor sits on one of its
## module-path segments or on its `as` alias (the host's `import_path_info_at`):
## `import std.vec as vec` names `std.vec` for a cursor on `std`, on the path's
## `vec`, and on the alias.  Any other line or token returns none, so the
## keyword/builtin tables never answer for a path segment.
function import_module_name_at(source: str, line: ptr_uint, character: ptr_uint) -> Option[string.String]:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()

    let target_line = line + 1
    let target_col = character + 1

    var line_tokens = vec.Vec[token_mod.Token].create()
    defer: line_tokens.release()
    var ti: ptr_uint = 0
    while ti < tokens.len():
        let tp = tokens.get(ti) else:
            break
        let tok = unsafe: read(tp)
        if tok.line == target_line and not is_structural_token_kind(tok.kind):
            line_tokens.push(tok)
        ti += 1
    if line_tokens.len() < 2:
        return Option[string.String].none
    let head_ptr = line_tokens.get(0) else:
        return Option[string.String].none
    let head = unsafe: read(head_ptr)
    if head.kind != tk.TokenKind.tk_import:
        return Option[string.String].none

    var module_name = string.String.create()
    var on_target = false
    var past_alias = false
    var ci: ptr_uint = 1
    while ci < line_tokens.len():
        let tp = line_tokens.get(ci) else:
            break
        let tok = unsafe: read(tp)
        let len = tok.end_offset - tok.start_offset
        let hit = target_col >= tok.column and target_col < tok.column + len
        match tok.kind:
            tk.TokenKind.tk_as:
                past_alias = true
            tk.TokenKind.identifier:
                if not past_alias:
                    if module_name.len() > 0:
                        module_name.append(".")
                    module_name.append(cursor.token_text(source, tok))
                if hit:
                    on_target = true
            _:
                pass
        ci += 1
    if not on_target or module_name.len() == 0:
        module_name.release()
        return Option[string.String].none
    return Option[string.String].some(value = module_name)


## The module-file navigation result for a cursor on an `import` line's path or
## alias, or none when the cursor is anywhere else.
function resolve_import_cursor(ws: ref[workspace.Workspace], uri: str, line: ptr_uint, character: ptr_uint) -> Option[CursorResult]:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        return Option[CursorResult].none
    defer: file_path.release()
    var content = ws.document_source(file_path.as_str()) else:
        return Option[CursorResult].none
    defer: content.release()
    match import_module_name_at(content.as_str(), line, character):
        Option.some as module_name:
            defer: module_name.value.release()
            return resolve_module_reference(ws, module_name.value.as_str())
        Option.none:
            return Option[CursorResult].none


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
        target_uri = string.String.create(),
        from_modules = string.String.create()
    ))


## Resolve `name` against the semantic analysis maps.  Returns the definition
## location, rendered signature, and attached docs, or none if unresolvable.
## `current_module` names the file being resolved, so a type the analysis
## recorded without an owning module still renders its qualifier and reports
## the host's `*From <module>*` line.
function resolve_name_in_analysis(
    file: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    name: str,
    source: str,
    current_module: str,
) -> Option[CursorResult]:
    unsafe:
        # Function: render the full signature.
        let sig_ptr = read(analysis).functions.get(name)
        if sig_ptr != null:
            let decl_line = find_declaration_line(file, name, "function")
            if decl_line > 0:
                var fn_text = format_fn_signature(read(sig_ptr), name, current_module)
                let fn_result = make_shortened_result(decl_line, name, source, fn_text.as_str())
                fn_text.release()
                return Option[CursorResult].some(value = fn_result)

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
                            var param_text = type_render.qualified_name(p.ty, current_module)
                            full.append(param_text.as_str())
                            param_text.release()
                            pi += 1
                        full.append(")")
                        if m_sig.has_return_type:
                            full.append(" -> ")
                            var return_text = type_render.qualified_name(m_sig.return_type, current_module)
                            full.append(return_text.as_str())
                            return_text.release()
                        let method_result = make_shortened_result(mline, name, source, full.as_str())
                        full.release()
                        return Option[CursorResult].some(value = method_result)
            m_next = method_entries.next()

        # Module-level const or var: the host's `value_hover_signature`.
        let value_ptr = read(analysis).value_types.get(name)
        if value_ptr != null:
            let decl_line = find_declaration_line(file, name, "value")
            if decl_line > 0:
                let keyword = value_decl_keyword(file, name)
                let mutability = if keyword.equal("var"): " (mutable)" else: " (immutable)"
                var hover = string.String.create()
                hover.append(keyword)
                hover.append(" ")
                hover.append(name)
                hover.append(": ")
                var value_text = type_render.qualified_name(read(value_ptr), current_module)
                hover.append(value_text.as_str())
                value_text.release()
                hover.append(mutability)
                let value_result = make_shortened_result(decl_line, name, source, hover.as_str())
                hover.release()
                return Option[CursorResult].some(value = value_result)

        # Interface: the host's `interface_signature` — `interface <name>`, then
        # one `    [async ][editable ]function <name>(<params>) -> <ret>` line per
        # method (no colon, and the return type is always rendered).
        if read(analysis).interfaces.contains(name):
            let decl_line = find_declaration_line(file, name, "struct")
            if decl_line > 0:
                var hover = string.String.create()
                hover.append("interface ")
                hover.append(name)
                let methods_ptr = read(analysis).interfaces.get(name)
                if methods_ptr != null:
                    let methods = read(methods_ptr)
                    var mi: ptr_uint = 0
                    while mi < methods.len:
                        let m = unsafe: read(methods.data + mi)
                        hover.append("\n    ")
                        if m.is_async:
                            hover.append("async ")
                        if m.method_kind == ast.MethodKind.mk_editable:
                            hover.append("editable ")
                        hover.append("function ")
                        hover.append(m.name)
                        hover.append("(")
                        var pi: ptr_uint = 0
                        while pi < m.method_params.len:
                            let p = unsafe: read(m.method_params.data + pi)
                            if pi > 0:
                                hover.append(", ")
                            hover.append(p.name)
                            hover.append(": ")
                            hover.append(ast_formatter.render_type(p.param_type))
                            pi += 1
                        hover.append(") -> ")
                        if m.return_type != null:
                            hover.append(ast_formatter.render_type(unsafe: read(ptr[ast.TypeRef]<-m.return_type)))
                        else:
                            hover.append("void")
                        mi += 1
                return Option[CursorResult].some(value = make_result(decl_line, name, source, hover))

        # Every other type — struct, union, opaque, enum, flags, variant, or a
        # `type` alias — through the host's `type_hover_signature`: `type Name`,
        # or `type Name = <module-qualified target>` when the type carries an
        # owning module.  A struct hover is *not* its field list.
        if read(analysis).types.contains(name):
            let decl_line = type_declaration_line(file, name)
            if decl_line > 0:
                var ty = types.Type.ty_error
                let ty_ptr = read(analysis).types.get(name)
                if ty_ptr != null:
                    ty = read(ptr[types.Type]<-ty_ptr)
                var hover = type_hover_signature(name, ty, current_module)
                let result = make_shortened_result(decl_line, name, source, hover.as_str())
                hover.release()
                return Option[CursorResult].some(value = result)

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
        target_uri = string.String.create(),
        from_modules = string.String.create()
    )


## `make_result` for a signature that carries module-qualified type names: the
## signature is shortened (the host's `shorten_qualified_types`) and the stripped
## modules ride along for the hover's `*From <module>*` line.
function make_shortened_result(decl_line: ptr_uint, name: str, source: str, signature: str) -> CursorResult:
    var shortened = type_render.shorten_signature(signature)
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
        hover_text = shortened.text,
        docs = doc_lines_above(source, decl_line),
        target_uri = string.String.create(),
        from_modules = shortened.modules
    )


## Render a function signature from its FnSig:
## `async function name(a: int, b: str) -> int`.
function format_fn_signature(sig: analyzer.FnSig, name: str, current_module: str) -> string.String:
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
        var param_text = type_render.qualified_name(param.ty, current_module)
        sig_text.append(param_text.as_str())
        param_text.release()
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


## The host's `type_hover_signature`: `type <name>` for a type that renders as
## its own bare name (a built-in or a primitive), else
## `type <name> = <module-qualified type>` — the caller shortens it, so a type
## with an owning module also reports the host's `*From <module>*` line.
function type_hover_signature(name: str, ty: types.Type, current_module: str) -> string.String:
    var hover = string.String.create()
    hover.append("type ")
    hover.append(name)
    if types.nominal_module(ty).len > 0:
        var rendered = type_render.qualified_name(ty, current_module)
        hover.append(" = ")
        hover.append(rendered.as_str())
        rendered.release()
    return hover


## The declaration line of a type named `name`: the aggregate and interface
## wording through `find_declaration_line`'s "struct" kind, a `type X = …`
## alias through the "alias" kind.
function type_declaration_line(file: ast.SourceFile, name: str) -> ptr_uint:
    let aggregate = find_declaration_line(file, name, "struct")
    if aggregate > 0:
        return aggregate
    return find_declaration_line(file, name, "alias")


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
                ast.Decl.decl_foreign_function as ff:
                    # A raw/binding module (`std.stdio`) declares its API as
                    # foreign functions: without this arm a module member's
                    # definition/hover/references resolved to nothing.
                    if ff.name == name:
                        return ff.line
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
        else if kind == "alias":
            match decl:
                ast.Decl.decl_type_alias as ta:
                    if ta.name == name:
                        return ta.line
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
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()

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


## Specialization-form hover for `zero`/`default`/`reinterpret` and the
## container constructors: only when the identifier is followed by `[`, as the
## host's specialization paths require.
function builtin_specialization_hover(tokens: vec.Vec[token_mod.Token], ti: ptr_uint, lexeme: str) -> Option[str]:
    var is_spec = false
    if lexeme.equal("zero") or lexeme.equal("default") or lexeme.equal("reinterpret") or lexeme.equal("array") or lexeme.equal("span"):
        is_spec = true
    if not is_spec:
        return Option[str].none

    var next_idx = ti + 1
    if next_idx >= tokens.len:
        return Option[str].none
    let np = tokens.get(next_idx) else:
        return Option[str].none
    let nt = unsafe: read(np)
    if nt.kind == tk.TokenKind.lbracket:
        return Option[str].some(value = f"builtin {lexeme}[...]")
    return Option[str].none


function field_declaration_hover(source: str, line: ptr_uint, character: ptr_uint) -> Option[CursorResult]:
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
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
                    # `Field.column` is 1-based; the request's character is 0-based.
                    let field_column = if f.column > 0: f.column - 1 else: 0z
                    if f.line == target_line and field_column <= character and field_column + f.name.len > character:
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


## Hover for a named-argument label inside a struct aggregate literal
## (`Sample(x = 1, …)` or `rl.Color(r = 1, …)`, hovering `r`): the field's
## declaration and its resolved type, rendered as the host's `field r: ubyte`.
## The receiver is the identifier before the literal's `(` — optionally
## `alias.`-qualified — resolved the way the host resolves a type receiver:
## through the aliased module's own type table, and then through a re-exported
## alias (`std.raylib`'s `type Color = c.Color`) to the module that declares the
## struct.  A label of an ordinary call (whose head is not a type) stays
## unresolved.
function named_argument_label_hover(
    ws: ref[workspace.Workspace],
    source: str,
    file_path: str,
    tokens: ref[vec.Vec[token_mod.Token]],
    ti: ptr_uint,
) -> Option[CursorResult]:
    if ti == 0 or ti + 1 >= tokens.len():
        return Option[CursorResult].none
    let label_ptr = tokens.get(ti) else:
        return Option[CursorResult].none
    let label_tok = unsafe: read(label_ptr)
    if label_tok.kind != tk.TokenKind.identifier:
        return Option[CursorResult].none
    let eq_ptr = tokens.get(ti + 1) else:
        return Option[CursorResult].none
    if unsafe: read(eq_ptr).kind != tk.TokenKind.equal:
        return Option[CursorResult].none

    # The head of the enclosing call: the identifier before its `(`.
    var opener: int = -1
    var depth: int = 0
    var k: int = int<-(ti - 1)
    while k >= 0:
        let kp = tokens.get(ptr_uint<-k) else:
            break
        let kind = unsafe: read(kp).kind
        if kind == tk.TokenKind.rparen or kind == tk.TokenKind.rbracket:
            depth += 1
        else if kind == tk.TokenKind.lparen or kind == tk.TokenKind.lbracket:
            if depth == 0:
                opener = k
                break
            depth -= 1
        k -= 1
    if opener < 1:
        return Option[CursorResult].none
    let head_ptr = tokens.get(ptr_uint<-(opener - 1)) else:
        return Option[CursorResult].none
    let head = unsafe: read(head_ptr)
    if head.kind != tk.TokenKind.identifier:
        return Option[CursorResult].none
    var type_name = cursor.token_text(source, head)
    let field_name = cursor.token_text(source, label_tok)

    # An `alias.Type(...)` literal names its type through a module alias.
    var module_alias: str = ""
    if opener >= 3:
        let dot_ptr = tokens.get(ptr_uint<-(opener - 2)) else:
            return Option[CursorResult].none
        if unsafe: read(dot_ptr).kind == tk.TokenKind.dot:
            let alias_ptr = tokens.get(ptr_uint<-(opener - 3)) else:
                return Option[CursorResult].none
            let alias_tok = unsafe: read(alias_ptr)
            if alias_tok.kind == tk.TokenKind.identifier:
                module_alias = cursor.token_text(source, alias_tok)

    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var parsed_file = parser.parse_source(source, ref_of(parse_diags))
    var ast_file = ast_for_document(ws, file_path, parsed_file)
    var analysis = analysis_for_document(ws, file_path, parsed_file)

    var module_roots = ws.effective_module_roots_for(file_path)
    defer: module_roots.release()
    var current_module = resolver.infer_module_name(file_path, module_roots.as_span())
    defer: current_module.release()

    # Which module's type table the head is looked up in: this file, or the
    # module the alias names.
    var lookup_module: str = current_module.as_str()
    if module_alias.len > 0:
        let module_name_ptr = unsafe: analysis.imports.get(module_alias) else:
            return Option[CursorResult].none
        lookup_module = unsafe: read(module_name_ptr)

    var lookup_path = resolve_module_source_path(ws, lookup_module) else:
        return Option[CursorResult].none
    defer: lookup_path.release()
    var lookup_source = ws.document_source(lookup_path.as_str()) else:
        return Option[CursorResult].none
    defer: lookup_source.release()
    var lookup_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: lookup_diags.release()
    var lookup_parsed = parser.parse_source(lookup_source.as_str(), ref_of(lookup_diags))
    var lookup_analysis = analysis_for_document(ws, lookup_path.as_str(), lookup_parsed)

    # The head must name a type; a re-exported alias (`type Color = c.Color`)
    # moves the lookup to the module that declares the type.
    let head_type_ptr = lookup_analysis.types.get(type_name) else:
        return Option[CursorResult].none
    let head_type = unsafe: read(ptr[types.Type]<-head_type_ptr)
    var declaring_module: str = lookup_module
    let owner = types.nominal_module(head_type)
    if owner.len > 0 and not owner.equal(lookup_module):
        declaring_module = owner
        type_name = types.nominal_name(head_type)

    # The declaring module's file: this document, or the module's own file.
    var decl_file = ast_file
    var decl_analysis = analysis
    var target_uri = string.String.create()
    if not declaring_module.equal(current_module.as_str()):
        var decl_path = resolve_module_source_path(ws, declaring_module) else:
            target_uri.release()
            return Option[CursorResult].none
        defer: decl_path.release()
        var decl_source = ws.document_source(decl_path.as_str()) else:
            target_uri.release()
            return Option[CursorResult].none
        var decl_diags = vec.Vec[pstate.ParseDiagnostic].create()
        defer: decl_diags.release()
        var decl_parsed = parser.parse_source(decl_source.as_str(), ref_of(decl_diags))
        decl_file = ast_for_document(ws, decl_path.as_str(), decl_parsed)
        decl_analysis = analysis_for_document(ws, decl_path.as_str(), decl_parsed)
        target_uri = file_uri_for_path(decl_path.as_str())

    var field_line: ptr_uint = 0
    var field_column: ptr_uint = 0
    var found = false
    var type_text = string.String.create()
    defer: type_text.release()

    var di: ptr_uint = 0
    while di < decl_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(decl_file.declarations.data + di)
        match decl:
            ast.Decl.decl_struct as s:
                if s.name.equal(type_name):
                    var fi: ptr_uint = 0
                    while fi < s.struct_fields.len:
                        let field = unsafe: read(s.struct_fields.data + fi)
                        if field.name.equal(field_name):
                            field_line = field.line
                            field_column = field.column
                            found = true
                            if field.field_type.name.parts.len > 0:
                                type_text.append(unsafe: read(field.field_type.name.parts.data))
                                if field.field_type.nullable:
                                    type_text.append("?")
                        fi += 1
            _:
                pass
        di += 1

    if not found:
        target_uri.release()
        return Option[CursorResult].none

    # The host renders the field's semantic type, module-qualified and then
    # shortened, so a user-defined field type reports a `*From <module>*` line.
    let entry_fields_ptr = decl_analysis.structs.get(type_name)
    if entry_fields_ptr != null:
        let entry_fields = unsafe: read(entry_fields_ptr)
        var fi: ptr_uint = 0
        while fi < entry_fields.len:
            let entry = unsafe: read(entry_fields.data + fi)
            if entry.name.equal(field_name):
                type_text.release()
                type_text = type_render.qualified_name(entry.ty, declaring_module)
            fi += 1

    var signature = string.String.create()
    signature.append("field ")
    signature.append(field_name)
    signature.append(": ")
    signature.append(type_text.as_str())
    var shortened = type_render.shorten_signature(signature.as_str())
    signature.release()

    let column_zero = if field_column > 0: field_column - 1 else: 0z
    return Option[CursorResult].some(value = CursorResult(
        line = field_line,
        column = column_zero,
        name_len = field_name.len,
        hover_text = shortened.text,
        docs = string.String.create(),
        target_uri = target_uri,
        from_modules = shortened.modules
    ))


function resolve_local_hover(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
) -> Option[CursorResult]:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        return Option[CursorResult].none
    defer: file_path.release()
    var cw = ws.document_source(file_path.as_str()) else:
        return Option[CursorResult].none
    defer: cw.release()
    let source = cw.as_str()
    if source.len == 0:
        return Option[CursorResult].none

    var name_opt = find_token_str(source, line, character)
    var name = name_opt else:
        return Option[CursorResult].none
    defer: name.release()
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
    defer: parse_diags.release()
    var parsed_file = parser.parse_source(source, ref_of(parse_diags))
    var ast_file = ast_for_document(ws, file_path.as_str(), parsed_file)
    var analysis = analysis_for_document(ws, file_path.as_str(), parsed_file)

    # The file's own module name, so a type declared here renders qualified
    # (`main.Sample`) and the renderer can report `*From main*`, as the host
    # does from its semantic facts.
    var module_roots = ws.effective_module_roots_for(file_path.as_str())
    defer: module_roots.release()
    var current_module = resolver.infer_module_name(file_path.as_str(), module_roots.as_span())
    defer: current_module.release()

    # 3. The innermost binding that encloses the cursor — the host's scope-aware
    # binding resolution.  Its declaration line comes from the scope bindings, so
    # a same-named local in another function (or an unrelated block) cannot win,
    # and a parameter resolves as `parameter <name>: <type>`.
    var bindings = scope_mod.collect_bindings(source, ast_file)
    defer: bindings.release()
    match scope_mod.local_binding_line(ref_of(bindings), name.as_str(), target_line):
        Option.some as want:
            var si: ptr_uint = 0
            while si < ast_file.declarations.len:
                var sdecl: ast.Decl
                unsafe:
                    sdecl = read(ast_file.declarations.data + si)
                match sdecl:
                    ast.Decl.decl_function as sfun:
                        if sfun.body != null:
                            match find_local_decl_in_body(sfun.body, name.as_str(), want.value):
                                Option.some as found_decl:
                                    match found_decl.value:
                                        ast.Stmt.stmt_local as fl:
                                            return Option[CursorResult].some(value = local_hover_result(
                                                fl.is_let, name.as_str(), fl.line, fl.stmt_type, fl.value,
                                                source, ref_of(analysis), current_module.as_str()))
                                        _:
                                            pass
                                Option.none:
                                    pass
                        match parameter_hover_in_decl(
                            name.as_str(), sfun.method_params, analysis.functions.get(sfun.name),
                            want.value, current_module.as_str()):
                            Option.some as param_result:
                                return Option[CursorResult].some(value = param_result.value)
                            Option.none:
                                pass
                    ast.Decl.decl_extending_block as sext:
                        var mei: ptr_uint = 0
                        while mei < sext.methods.len:
                            let method = unsafe: read(sext.methods.data + mei)
                            match find_local_decl_in_body(method.body, name.as_str(), want.value):
                                Option.some as found_method_decl:
                                    match found_method_decl.value:
                                        ast.Stmt.stmt_local as flm:
                                            return Option[CursorResult].some(value = local_hover_result(
                                                flm.is_let, name.as_str(), flm.line, flm.stmt_type, flm.value,
                                                source, ref_of(analysis), current_module.as_str()))
                                        _:
                                            pass
                                Option.none:
                                    pass
                            match parameter_hover_in_decl(
                                name.as_str(), method.method_params,
                                method_signature_for(ref_of(analysis), method.name, method.method_params),
                                want.value, current_module.as_str()):
                                Option.some as method_param_result:
                                    return Option[CursorResult].some(value = method_param_result.value)
                                Option.none:
                                    pass
                            mei += 1
                    _:
                        pass
                si += 1
        Option.none:
            pass

    # 4. Fallback for the declarations the scope walk does not model (the flat
    # per-function scan): any enclosing function's top-level local.
    var di: ptr_uint = 0
    while di < ast_file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(ast_file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                if fun.line <= target_line and fun.body != null:
                    var body_loc = find_local_in_block(unsafe: read(ptr[ast.Stmt]<-fun.body), name.as_str(), source, ref_of(analysis), current_module.as_str())
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
## local declaration of `name`, and render it the way the host's
## `value_hover_signature` does: `let name: <type> (immutable)`, with the
## declared type when the binding is annotated and the analyzer's inferred type
## otherwise.  The signature is built with the declaring module and shortened,
## so a user type reports the host's `*From <module>*` line.
function find_local_in_block(
    block_stmt: ast.Stmt,
    name: str,
    source: str,
    analysis: ref[analyzer.Analysis],
    current_module: str,
) -> Option[CursorResult]:
    match block_stmt:
        ast.Stmt.stmt_block as blk:
            var si: ptr_uint = 0
            while si < blk.statements.len:
                var s = unsafe: read(blk.statements.data + si)
                match s:
                    ast.Stmt.stmt_local as loc:
                        if loc.name == name:
                            return Option[CursorResult].some(value = local_hover_result(
                                loc.is_let, name, loc.line, loc.stmt_type, loc.value, source, analysis, current_module))
                    _:
                        pass
                si += 1
        _:
            pass
    return Option[CursorResult].none


## The declaration line of the innermost `let`/`var` local named `name` that
## encloses `cursor_line` (1-based).  None when the cursor is not on a local:
## module-level names and parameters both yield none (matching the host's
## `typeDefinition`, which resolves a local's own binding but not a parameter).
function enclosing_local_decl_line(source: str, ast_file: ast.SourceFile, name: str, cursor_line: ptr_uint) -> Option[ptr_uint]:
    var bindings = scope_mod.collect_bindings(source, ast_file)
    defer: bindings.release()
    match scope_mod.local_binding_line(ref_of(bindings), name, cursor_line):
        Option.some as want:
            var di: ptr_uint = 0
            while di < ast_file.declarations.len:
                var decl: ast.Decl
                unsafe:
                    decl = read(ast_file.declarations.data + di)
                match decl:
                    ast.Decl.decl_function as fun:
                        if fun.body != null:
                            match find_local_decl_in_body(fun.body, name, want.value):
                                Option.some:
                                    return Option[ptr_uint].some(value = want.value)
                                Option.none:
                                    pass
                    ast.Decl.decl_extending_block as ext:
                        var mi: ptr_uint = 0
                        while mi < ext.methods.len:
                            let method = unsafe: read(ext.methods.data + mi)
                            match find_local_decl_in_body(method.body, name, want.value):
                                Option.some:
                                    return Option[ptr_uint].some(value = want.value)
                                Option.none:
                                    pass
                            mi += 1
                    _:
                        pass
                di += 1
        Option.none:
            pass
    return Option[ptr_uint].none


## The declaration line of a `stmt_local` (a destructuring `let (a, b) = …`
## declares its names on the statement's own line).
function local_stmt_decl_line(loc: ast.Stmt) -> ptr_uint:
    match loc:
        ast.Stmt.stmt_local as l:
            return l.line
        _:
            return 0
    return 0


## True when a `stmt_local` declares `name`, directly or through a destructuring
## binding list (`let (a, b) = …`).
function local_stmt_declares(loc: ast.Stmt, name: str) -> bool:
    match loc:
        ast.Stmt.stmt_local as l:
            if l.name == name:
                return true
            match l.destructure_bindings:
                Option.some as binds:
                    var bi: ptr_uint = 0
                    while bi < binds.value.len:
                        if unsafe: read(binds.value.data + bi) == name:
                            return true
                        bi += 1
                Option.none:
                    pass
        _:
            pass
    return false


## The `stmt_local` that declares `name` on line `want_line` (1-based), searching
## nested blocks so a local declared inside an `if`/`while`/`for`/`match` body
## resolves like the host's scope-aware binding lookup.
function find_local_decl_at_line(stmt: ast.Stmt, name: str, want_line: ptr_uint) -> Option[ast.Stmt]:
    unsafe:
        if local_stmt_declares(stmt, name) and local_stmt_decl_line(stmt) == want_line:
            return Option[ast.Stmt].some(value = stmt)
        match stmt:
            ast.Stmt.stmt_block as blk:
                return find_local_decl_in_stmts(blk.statements, name, want_line)
            ast.Stmt.stmt_if as iff:
                var ib: ptr_uint = 0
                while ib < iff.branches.len:
                    let branch = read(iff.branches.data + ib)
                    match find_local_decl_in_body(branch.body, name, want_line):
                        Option.some as found:
                            return Option[ast.Stmt].some(value = found.value)
                        Option.none:
                            pass
                    ib += 1
                if iff.else_body != null:
                    return find_local_decl_in_body(iff.else_body, name, want_line)
            ast.Stmt.stmt_while as w:
                return find_local_decl_in_body(w.body, name, want_line)
            ast.Stmt.stmt_for as f:
                return find_local_decl_in_body(f.body, name, want_line)
            ast.Stmt.stmt_match as m:
                var mi: ptr_uint = 0
                while mi < m.arms.len:
                    let arm = read(m.arms.data + mi)
                    match find_local_decl_in_body(arm.body, name, want_line):
                        Option.some as found:
                            return Option[ast.Stmt].some(value = found.value)
                        Option.none:
                            pass
                    mi += 1
            _:
                pass
    return Option[ast.Stmt].none


## `find_local_decl_at_line` for a maybe-absent body pointer.
function find_local_decl_in_body(body_node: ptr[ast.Stmt]?, name: str, want_line: ptr_uint) -> Option[ast.Stmt]:
    let b = body_node else:
        return Option[ast.Stmt].none
    return find_local_decl_at_line(unsafe: read(b), name, want_line)


## `find_local_decl_at_line` over a statement list.
function find_local_decl_in_stmts(stmts: span[ast.Stmt], name: str, want_line: ptr_uint) -> Option[ast.Stmt]:
    var si: ptr_uint = 0
    while si < stmts.len:
        match find_local_decl_at_line(unsafe: read(stmts.data + si), name, want_line):
            Option.some as found:
                return Option[ast.Stmt].some(value = found.value)
            Option.none:
                pass
        si += 1
    return Option[ast.Stmt].none


## The hover result for one parameter: `parameter <name>: <type> (immutable)`,
## the shape the host renders from its binding facts.  The host attaches no
## source location to a parameter hover, so `line` stays 0 (which also keeps
## go-to-definition on a parameter a null result, as the host answers).  The type
## is the *resolved* signature type, so an imported one renders its short name
## plus the host's `*From <module>*` line.
function parameter_hover_result(name: str, param_type: types.Type, current_module: str) -> CursorResult:
    var signature = string.String.create()
    signature.append("parameter ")
    signature.append(name)
    signature.append(": ")
    var type_text = type_render.qualified_name(param_type, current_module)
    signature.append(type_text.as_str())
    type_text.release()
    signature.append(" (immutable)")

    var shortened = type_render.shorten_signature(signature.as_str())
    signature.release()

    return CursorResult(
        line = 0,
        column = 0,
        name_len = name.len,
        hover_text = shortened.text,
        docs = string.String.create(),
        target_uri = string.String.create(),
        from_modules = shortened.modules
    )


## The hover for a parameter of an enclosing function or method declared on
## `want_line`.  `sig` is the enclosing callable's resolved signature: the
## parameter's type comes from it rather than from the written TypeRef, whose
## first name part (`rl` for `rl.Color`) is not a type.
function parameter_hover_in_decl(
    name: str,
    ast_params: span[ast.Param],
    sig: ptr[analyzer.FnSig]?,
    want_line: ptr_uint,
    current_module: str,
) -> Option[CursorResult]:
    var pi: ptr_uint = 0
    while pi < ast_params.len:
        let ast_param = unsafe: read(ast_params.data + pi)
        if ast_param.name.equal(name) and ast_param.line == want_line:
            var param_type = types.Type.ty_error
            if sig != null:
                let resolved = unsafe: read(ptr[analyzer.FnSig]<-sig)
                if pi < resolved.params.len:
                    param_type = unsafe: read(resolved.params.data + pi).ty
            return Option[CursorResult].some(value = parameter_hover_result(name, param_type, current_module))
        pi += 1
    return Option[CursorResult].none


## The resolved signature of the method named `name` whose parameters match
## `ast_params`.  Extending-block methods are keyed `<Type>.<name>` in
## `method_sigs` and the same name can be extended on several types, so the
## parameter list identifies the declaration.
function method_signature_for(analysis: ref[analyzer.Analysis], name: str, ast_params: span[ast.Param]) -> ptr[analyzer.FnSig]?:
    var entries = unsafe: read(analysis).method_sigs.entries()
    while entries.next():
        let entry = entries.current()
        let key = unsafe: read(entry.key)
        if key.len <= name.len or not key.ends_with(name):
            continue
        let sig = unsafe: read(entry.value)
        if sig.params.len < ast_params.len:
            continue
        var matches = true
        var pi: ptr_uint = 0
        while pi < ast_params.len:
            let ast_param = unsafe: read(ast_params.data + pi)
            let resolved = unsafe: read(sig.params.data + pi)
            if not ast_param.name.equal(resolved.name):
                matches = false
                break
            pi += 1
        if matches:
            return entry.value
    return null


## The hover result for one local declaration.
function local_hover_result(
    is_let: bool,
    name: str,
    decl_line: ptr_uint,
    stmt_type: ptr[ast.TypeRef]?,
    value: ptr[ast.Expr]?,
    source: str,
    analysis: ref[analyzer.Analysis],
    current_module: str,
) -> CursorResult:
    var type_text = string.String.create()

    if stmt_type != null:
        let ty = unsafe: read(ptr[ast.TypeRef]<-stmt_type)
        if ty.name.parts.len > 0:
            type_text.append(unsafe: read(ty.name.parts.data))
            if ty.nullable:
                type_text.append("?")
    else:
        match type_render.initializer_type(analysis, value):
            Option.some as init_ty:
                type_text.release()
                type_text = type_render.qualified_name(init_ty.value, current_module)
            Option.none:
                pass

    var signature = string.String.create()
    if is_let:
        signature.append("let ")
    else:
        signature.append("var ")
    signature.append(name)
    if type_text.len() > 0:
        signature.append(": ")
        signature.append(type_text.as_str())
        if is_let:
            signature.append(" (immutable)")
        else:
            signature.append(" (mutable)")
    type_text.release()

    var shortened = type_render.shorten_signature(signature.as_str())
    signature.release()

    # The 0-based column of the name on its declaration line, so a go-to-
    # definition request lands on the name itself (the host's token range).
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
        hover_text = shortened.text,
        docs = string.String.create(),
        target_uri = string.String.create(),
        from_modules = shortened.modules
    )



## Render a hover response in the host's markdown shape: the signature in a
## ```milk-tea fence, the docs, then the source location as
## `Defined at: [<path>:<line>](<uri>#L<line>)` (`target_uri` wins over the
## request's own uri for cross-file definitions).  The label's path is the
## host's: relative to the workspace root, or absolute when the file is outside
## it (a std-library declaration in a project workspace).
function write_hover_result(ws: ref[workspace.Workspace], id: json.Value, res: CursorResult, request_uri: str, token_range_param: string.String) -> void:
    var payload = res
    var token_range = token_range_param
    if payload.hover_text.len() > 0:
        var value_text = string.String.create()
        defer: value_text.release()
        value_text.append("```milk-tea\n")
        value_text.append(payload.hover_text.as_str())
        value_text.append("\n```")
        if payload.from_modules.len() > 0:
            value_text.append("\n*From ")
            value_text.append(payload.from_modules.as_str())
            value_text.append("*")
        if payload.docs.len() > 0:
            value_text.append("\n\n")
            value_text.append(payload.docs.as_str())
        append_defined_at(ws, ref_of(value_text), payload, request_uri)
        var json_text = string.String.create()
        defer: json_text.release()
        json_text.append("{\"contents\":{\"kind\":\"markdown\",\"value\":\"")
        proto.append_escaped(ref_of(json_text), value_text.as_str())
        json_text.append("\"}")
        if token_range.len() > 0:
            json_text.append(",")
            json_text.append(token_range.as_str())
        json_text.append("}")
        proto.write_response_raw(id, json_text.as_str())
    else:
        proto.write_response(id, json.null_value())
    payload.hover_text.release()
    payload.docs.release()
    payload.target_uri.release()
    payload.from_modules.release()
    token_range.release()


## Append the source-location line for a hover payload, when it has one.
function append_defined_at(ws: ref[workspace.Workspace], text: ref[string.String], payload: CursorResult, request_uri: str) -> void:
    if payload.line == 0:
        return
    var source_uri: str = request_uri
    if payload.target_uri.len() > 0:
        source_uri = payload.target_uri.as_str()
    text.append("\n\nDefined at: [")
    match uri_ops.file_uri_to_path(source_uri):
        Option.some as source_path:
            var label = hover_path_label(ws, source_path.value.as_str())
            defer: label.release()
            text.append(label.as_str())
            source_path.value.release()
        Option.none:
            var fallback_label = hover_path_label(ws, source_uri)
            defer: fallback_label.release()
            text.append(fallback_label.as_str())
    text.append_format(f":#{payload.line}](")
    text.append(source_uri)
    text.append_format(f"#L#{payload.line})")


## The path a hover link labels its target with, as the host renders it
## (`hover_source_label`): relative to the workspace root when the file is
## inside it, the absolute path otherwise.
function hover_path_label(ws: ref[workspace.Workspace], path: str) -> string.String:
    let root = ws.root_path.as_str()
    if root.len > 0 and path.len > root.len and path.starts_with(root):
        var start = root.len
        if unsafe: path.byte_at(start) == '/':
            start += 1
        return string.String.from_str(path.slice(start, path.len - start))
    return string.String.from_str(path)
