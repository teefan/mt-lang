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
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.loader.module_loader as loader
import mtc.loader.path_resolver as resolver
import mtc.lsp.cursor as cursor
import mtc.lsp.definition_index as defidx
import mtc.lsp.hover_docs as hover_docs
import mtc.lsp.protocol as proto
import mtc.lsp.scope as scope_mod
import mtc.lsp.type_render as type_render
import mtc.lsp.uri as uri_ops
import mtc.lsp.utils as utils
import mtc.lsp.workspace as workspace
import mtc.pretty_printer.ast_formatter as ast_formatter


## A `let`/`var`/`for` declaration site: the name token's 1-based line/column.
struct LocalDeclSite:
    line: ptr_uint
    column: ptr_uint


## True when the cursor's name resolves through the builtin arms — the host's
## `is_builtin_name?` gate, which is `builtin_hover_info` and runs *before* its
## local-binding arm, so a definition request for a builtin name (`ptr[int]`,
## `zero[T]`, `read(x)`) answers nothing rather than falling through to the
## definition index.
function builtin_name_at(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
) -> bool:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        return false
    defer: file_path.release()
    var content = ws.document_source(file_path.as_str()) else:
        return false
    defer: content.release()
    let source = content.as_str()

    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()
    let ti = token_index_at(tokens.as_span(), line, character) else:
        return false
    let tp = tokens.get(ti) else:
        return false
    let tok = unsafe: read(tp)
    let lexeme = unsafe: token_mod.token_lexeme(tok, source)

    match builtin_specialization_hover(tokens, source, ti, lexeme):
        Option.some:
            return true
        Option.none:
            pass
    match hover_docs.builtin_call(lexeme):
        Option.some:
            return true
        Option.none:
            pass
    return false


## The definition of a name that is bound in the cursor's scope — the host's
## *local* definition rule, which is not the enclosing binding: its completion
## bindings (`Bindings::ValueBinding`) carry no AST node, so
## `find_local_declaration_ast_node` walks the whole file and answers the
## **first** `let`/`var`/`for` declaration of that name *before* the cursor.
## An editor therefore jumps to an unrelated same-named local earlier in the
## file; reproducing that artefact is what parity requires (§0k records it).
## None when the name is not a local binding, or when the file declares no such
## local before the cursor — the caller then falls back to the definition index,
## exactly as the host's pipeline does.
function resolve_local_definition(
    ws: ref[workspace.Workspace],
    file_path: str,
    source: str,
    name: str,
    target_line: ptr_uint,
) -> Option[CursorResult]:
    let doc = workspace.document_analysis_for(ws, file_path) else:
        return Option[CursorResult].none
    var ast_file = doc.ast_file

    # The host resolves a binding only through the cursor's own completion
    # frame; the scope walk's region model is the self's equivalent, and it
    # excludes module-level names, which the host answers from its value tables.
    var bindings = scope_mod.collect_bindings(source, ast_file)
    defer: bindings.release()
    if scope_mod.local_binding_line(ref_of(bindings), name, target_line).is_none():
        return Option[CursorResult].none

    match first_local_decl(ast_file, name, target_line):
        Option.some as site:
            var line_text = cursor.source_line(source, site.value.line)
            var column: ptr_uint = 0
            match cursor.token_start_in_line(line_text, name):
                Option.some as pos:
                    column = pos.value
                Option.none:
                    column = if site.value.column > 0: site.value.column - 1 else: 0z
            return Option[CursorResult].some(value = CursorResult(
                line = site.value.line,
                column = column,
                name_len = name.len,
                hover_text = string.String.create(),
                docs = string.String.create(),
                target_uri = string.String.create(),
                from_modules = string.String.create()
            ))
        Option.none:
            pass
    return Option[CursorResult].none


## The first `let`/`var`/`for` declaration of `name` before `before_line`
## (1-based), anywhere in the file: the host's `find_local_declaration_ast_node`
## walk.  Destructured names and `as` bindings are not a `LocalDecl`'s own name,
## so they never match — as in the host.
function first_local_decl(file: ast.SourceFile, name: str, before_line: ptr_uint) -> Option[LocalDeclSite]:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_function as fun:
                match first_local_in_stmt(fun.body, name, before_line):
                    Option.some as hit:
                        return Option[LocalDeclSite].some(value = hit.value)
                    Option.none:
                        pass
            ast.Decl.decl_const as c:
                match first_local_in_stmt(c.block_body, name, before_line):
                    Option.some as const_hit:
                        return Option[LocalDeclSite].some(value = const_hit.value)
                    Option.none:
                        pass
            ast.Decl.decl_extending_block as ext:
                var mi: ptr_uint = 0
                while mi < ext.methods.len:
                    let method = unsafe: read(ext.methods.data + mi)
                    match first_local_in_stmt(method.body, name, before_line):
                        Option.some as method_hit:
                            return Option[LocalDeclSite].some(value = method_hit.value)
                        Option.none:
                            pass
                    mi += 1
            ast.Decl.decl_struct as st:
                var si: ptr_uint = 0
                while si < st.struct_events.len:
                    let event_decl = unsafe: read(st.struct_events.data + si)
                    match event_decl:
                        ast.Decl.decl_function as ef:
                            match first_local_in_stmt(ef.body, name, before_line):
                                Option.some as event_hit:
                                    return Option[LocalDeclSite].some(value = event_hit.value)
                                Option.none:
                                    pass
                        _:
                            pass
                    si += 1
                var ni: ptr_uint = 0
                while ni < st.nested_types.len:
                    let nested = unsafe: read(st.nested_types.data + ni)
                    match nested:
                        ast.Decl.decl_function as nf:
                            match first_local_in_stmt(nf.body, name, before_line):
                                Option.some as nested_hit:
                                    return Option[LocalDeclSite].some(value = nested_hit.value)
                                Option.none:
                                    pass
                        _:
                            pass
                    ni += 1
            _:
                pass
        di += 1
    return Option[LocalDeclSite].none


## The first matching declaration in one statement body, statements and nested
## bodies in source order.
function first_local_in_stmt(sp: ptr[ast.Stmt]?, name: str, before_line: ptr_uint) -> Option[LocalDeclSite]:
    let b = sp else:
        return Option[LocalDeclSite].none
    unsafe:
        match read(b):
            ast.Stmt.stmt_block as blk:
                return first_local_in_stmts(blk.statements, name, before_line)
            ast.Stmt.stmt_local as loc:
                if loc.name.equal(name) and loc.line > 0 and loc.line < before_line:
                    return Option[LocalDeclSite].some(value = LocalDeclSite(line = loc.line, column = loc.column))
                # `let x = f() else: …` nests a body.
                match first_local_in_stmt(loc.else_body, name, before_line):
                    Option.some as else_hit:
                        return Option[LocalDeclSite].some(value = else_hit.value)
                    Option.none:
                        pass
            ast.Stmt.stmt_if as iff:
                var ib: ptr_uint = 0
                while ib < iff.branches.len:
                    let branch = read(iff.branches.data + ib)
                    match first_local_in_stmt(branch.body, name, before_line):
                        Option.some as branch_hit:
                            return Option[LocalDeclSite].some(value = branch_hit.value)
                        Option.none:
                            pass
                    ib += 1
                match first_local_in_stmt(iff.else_body, name, before_line):
                    Option.some as if_else_hit:
                        return Option[LocalDeclSite].some(value = if_else_hit.value)
                    Option.none:
                        pass
            ast.Stmt.stmt_while as wh:
                return first_local_in_stmt(wh.body, name, before_line)
            ast.Stmt.stmt_for as fr:
                # The bindings are visited before the body, as the host's walk does.
                var bi: ptr_uint = 0
                while bi < fr.bindings.len:
                    let binding = read(fr.bindings.data + bi)
                    if binding.name.equal(name) and binding.line > 0 and binding.line < before_line:
                        return Option[LocalDeclSite].some(value = LocalDeclSite(line = binding.line, column = binding.column))
                    bi += 1
                return first_local_in_stmt(fr.body, name, before_line)
            ast.Stmt.stmt_match as m:
                var mi: ptr_uint = 0
                while mi < m.arms.len:
                    let arm = read(m.arms.data + mi)
                    match first_local_in_stmt(arm.body, name, before_line):
                        Option.some as arm_hit:
                            return Option[LocalDeclSite].some(value = arm_hit.value)
                        Option.none:
                            pass
                    mi += 1
            ast.Stmt.stmt_unsafe as uns:
                return first_local_in_stmt(uns.body, name, before_line)
            ast.Stmt.stmt_defer as dfr:
                return first_local_in_stmt(dfr.body, name, before_line)
            ast.Stmt.stmt_when as whn:
                var wi: ptr_uint = 0
                while wi < whn.branches.len:
                    let branch = read(whn.branches.data + wi)
                    match first_local_in_stmts(branch.body, name, before_line):
                        Option.some as when_hit:
                            return Option[LocalDeclSite].some(value = when_hit.value)
                        Option.none:
                            pass
                    wi += 1
                return first_local_in_stmt(whn.else_body, name, before_line)
            ast.Stmt.stmt_parallel_block as pb:
                return first_local_in_stmts(pb.bodies, name, before_line)
            ast.Stmt.stmt_error_block as eb:
                return first_local_in_stmt(eb.body, name, before_line)
            _:
                pass
    return Option[LocalDeclSite].none


function first_local_in_stmts(stmts: span[ast.Stmt], name: str, before_line: ptr_uint) -> Option[LocalDeclSite]:
    var si: ptr_uint = 0
    while si < stmts.len:
        match first_local_in_stmt(unsafe: stmts.data + si, name, before_line):
            Option.some as hit:
                return Option[LocalDeclSite].some(value = hit.value)
            Option.none:
                pass
        si += 1
    return Option[LocalDeclSite].none


## True for the token kinds the host's definition index pairs with names — its
## `DEFINITION_KEYWORDS` (`const`/`var`/`let`, the type declarations, `function`,
## `extending`, …).
function is_definition_keyword_kind(kind: tk.TokenKind) -> bool:
    if kind == tk.TokenKind.tk_function or kind == tk.TokenKind.tk_struct or kind == tk.TokenKind.tk_union:
        return true
    if kind == tk.TokenKind.tk_enum or kind == tk.TokenKind.tk_flags or kind == tk.TokenKind.tk_variant:
        return true
    if kind == tk.TokenKind.tk_type or kind == tk.TokenKind.tk_const or kind == tk.TokenKind.tk_var:
        return true
    if kind == tk.TokenKind.tk_let or kind == tk.TokenKind.tk_extending or kind == tk.TokenKind.tk_opaque:
        return true
    return kind == tk.TokenKind.tk_interface or kind == tk.TokenKind.tk_event


## The host's `module_member_definition_location` for an *import alias* token:
## the alias's name is first looked up as a declaration inside the module it
## names — the first token a definition keyword introduces with that lexeme
## (`find_definition_token_in_file`: `function hash` in std/hash.mt for the alias
## `hash`, `extending ptr[T]:` in std/mem/ptr.mt for `ptr`) — and only then as the
## module file itself.  Definition-only: the hover's alias arm answers the module,
## as the host's hover does.
function import_alias_member_decl(
    ws: ref[workspace.Workspace],
    module_name: str,
    name: str,
    from_path: str,
) -> Option[CursorResult]:
    var module_path = resolve_module_source_path_for(ws, module_name, from_path) else:
        return Option[CursorResult].none
    defer: module_path.release()
    var module_source = ws.document_source(module_path.as_str()) else:
        return Option[CursorResult].none
    defer: module_source.release()
    let module_text = module_source.as_str()

    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(module_text, ref_of(lex_diags))
    defer: tokens.release()
    var ti: ptr_uint = 1
    while ti < tokens.len():
        let kw_ptr = tokens.get(ti - 1) else:
            break
        let keyword = unsafe: read(kw_ptr)
        let id_ptr = tokens.get(ti) else:
            break
        let id = unsafe: read(id_ptr)
        if is_definition_keyword_kind(keyword.kind) and id.kind == tk.TokenKind.identifier:
            let lexeme = unsafe: token_mod.token_lexeme(id, module_text)
            if lexeme.equal(name):
                return Option[CursorResult].some(value = CursorResult(
                    line = id.line,
                    column = if id.column > 0: id.column - 1 else: 0z,
                    name_len = name.len,
                    hover_text = string.String.create(),
                    docs = string.String.create(),
                    target_uri = file_uri_for_path(module_path.as_str()),
                    from_modules = string.String.create()
                ))
        ti += 1
    return Option[CursorResult].none


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
    # The host's arm order: the module/member arms first (inside
    # `resolve_cursor`), then `alias.Member`'s module fallback, then the builtin
    # gate, then the local rule, then the definition index.
    var result = resolve_cursor_at(ws, uri, line, character, false)

    # `alias.Member` where the member is not a declaration of that module: the
    # host's definition pipeline answers the module file itself (the same
    # position's hover stays null, so this is the definition path only).
    if result.is_none():
        match alias_member_module_path(ws, uri, line, character):
            Option.some as member_module_path:
                var member_module_uri = file_uri_for_path(member_module_path.value.as_str())
                respond_module_location(id, member_module_uri.as_str())
                member_module_uri.release()
                member_module_path.value.release()
                return
            Option.none:
                pass

    # The host answers nothing once a name resolves through its builtin arms
    # (`is_builtin_name?` → `builtin_hover_info`): `ptr[int]`, `zero[T]` and
    # `read(x)` are never definitions, and the answer is null rather than the
    # definition index's `let ptr …` from some other open document.
    if result.is_none() and builtin_name_at(ws, uri, line, character):
        proto.write_response(id, json.null_value())
        return

    # A name bound in the cursor's scope answers the file's first same-named
    # `let`/`var`/`for` declaration, not the enclosing binding (the host's
    # `find_local_declaration_ast_node` artefact).
    if result.is_none():
        match uri_ops.file_uri_to_path(uri):
            Option.some as def_path:
                var def_content = ws.document_source(def_path.value.as_str())
                if def_content.is_some():
                    var def_source = def_content.unwrap()
                    match cursor.identifier_at(def_source.as_str(), line, character):
                        Option.some as def_name:
                            result = resolve_local_definition(
                                ws, def_path.value.as_str(), def_source.as_str(), def_name.value.text, line + 1)
                        Option.none:
                            pass
                    def_source.release()
                def_path.value.release()
            Option.none:
                pass

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
    if ws.position_encoding_utf16:
        match uri_ops.file_uri_to_path(target_uri.as_str()):
            Option.some as target_path:
                let converted_start = ws.output_character(target_path.value.as_str(), lz, target_column)
                let converted_end = ws.output_character(target_path.value.as_str(), lz, target_column + target_len)
                target_column = converted_start
                target_len = converted_end - converted_start
                target_path.value.release()
            Option.none:
                pass
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
    var hover_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer: hover_path.release()
    var hover_text = ws.document_text(hover_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    let hover_source = hover_text.text
    if hover_source.len == 0:
        proto.write_response(id, json.null_value())
        return

    var hover_token_range = hover_range_json(ws, hover_path.as_str(), hover_source, line, character)
    # The host's `find_token_at(uri, …)` tokenizes the hovered document.
    ws.note_document_tokens(hover_path.as_str())
    # An `import` line's path or alias resolves to the module file, ahead of the
    # keyword/builtin tables: `str` in `import std.str` is the module, not the
    # builtin type.
    match resolve_import_cursor(ws, uri, line, character):
        Option.some as import_result:
            write_hover_result(ws, id, import_result.value, uri, hover_token_range)
            return
        Option.none:
            pass
    # The host's dispatch order: field declarations and named-argument labels,
    # then bindings, then names and members, and the keyword/builtin tables last.
    match resolve_field_or_label_hover(ws, hover_path.as_str(), hover_source, line, character):
        Option.some as field_result:
            write_hover_result(ws, id, field_result.value, uri, hover_token_range)
            return
        Option.none:
            pass

    match resolve_local_hover(ws, hover_path.as_str(), hover_source, line, character):
        Option.some as loc_result:
            var loc_payload = loc_result.value
            # The host prints a binding's hover location from its token index —
            # the last declaration of the name before the cursor, else the first
            # — not from the binding: a `for` or `match` binding, or a local the
            # index does not know, ends up with no `Defined at` line.
            apply_hover_index_location(ws, hover_path.as_str(), hover_source, line, character, ref_of(loc_payload))
            note_hover_definition_file(ws, loc_payload)
            write_hover_result(ws, id, loc_payload, uri, hover_token_range)
            return
        Option.none:
            pass

    match resolve_cursor(ws, uri, hover_source, line, character, true):
        Option.some as res:
            note_hover_definition_file(ws, res.value)
            write_hover_result(ws, id, res.value, uri, hover_token_range)
            return
        Option.none:
            pass

    match resolve_keyword_or_builtin_hover(ws, hover_path.as_str(), hover_source, line, character):
        Option.some as kw_result:
            write_hover_result(ws, id, kw_result.value, uri, hover_token_range)
            return
        Option.none:
            pass

    hover_token_range.release()
    proto.write_response(id, json.null_value())


## A hover that resolves a definition through the facts reports a cross-file
## location and the host tokenizes that file while rendering it
## (`hover_definition_entry_from_location` calls `find_token_at` on it) — which
## both enters it into the workspace identifier index and, through the
## `get_content` behind `get_tokens`, admits it to the host's indexed documents
## and so to its cross-file definition index.  The arms the host renders from
## their own `source_uri` — an import line, a field declaration or a
## named-argument label, a keyword or a builtin — resolve no such entry and leave
## both indexes alone, and the self-host's hooks sit on the same arms.
function note_hover_definition_file(ws: ref[workspace.Workspace], payload: CursorResult) -> void:
    if payload.target_uri.len() == 0:
        return
    match uri_ops.file_uri_to_path(payload.target_uri.as_str()):
        Option.some as target_path:
            ws.note_document_tokens(target_path.value.as_str())
            ws.warm_definition_document(target_path.value.as_str())
            target_path.value.release()
        Option.none:
            pass


## Point `payload` at the workspace token index's declaration for the name under
## the cursor — the host's hover location for everything that carries no
## facts-based source location (bindings, keywords, builtins).  With nothing
## indexed the payload loses its location, so the hover prints no `Defined at`
## line, exactly as the host's does.
function apply_hover_index_location(
    ws: ref[workspace.Workspace],
    file_path: str,
    source: str,
    line: ptr_uint,
    character: ptr_uint,
    payload: ref[CursorResult],
) -> void:
    let tokens = ws.document_tokens(file_path, source)
    var name_text: str = ""
    match cursor.identifier_at_in(tokens, source, line, character):
        Option.some as name:
            name_text = name.value.text
        Option.none:
            match cursor.interpolation_identifier_at_in(tokens, source, line, character):
                Option.some as inner:
                    name_text = inner.value.text
                Option.none:
                    pass
    if name_text.len > 0:
        var preferred_uri = file_uri_for_path(file_path)
        defer: preferred_uri.release()
        match find_definition_global(ws, name_text, preferred_uri.as_str(), line + 1, character + 1):
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
    payload.line = 0
    payload.column = 0


## The `"range":{...}` fragment for the identifier under the cursor (the host
## includes it so the client can highlight the hovered symbol), or an empty
## string when no identifier is there.
function hover_range_json(ws: ref[workspace.Workspace], file_path: str, source: str, line: ptr_uint, character: ptr_uint) -> string.String:
    var empty = string.String.create()
    let tokens = ws.document_tokens(file_path, source)
    match cursor.identifier_at_in(tokens, source, line, character):
        Option.some as tok:
            var frag = hover_range_fragment(tok.value, utils.source_line(source, tok.value.line), ws.position_encoding_utf16)
            empty.release()
            return frag
        Option.none:
            pass
    # A format string's interpolation token (`f"v=#{value}"`) ranges its own
    # token, as the host's `token_context_at` does for the re-lexed expression.
    match cursor.interpolation_token_at_in(tokens, source, line, character):
        Option.some as inner:
            let inner_len = inner.value.end_offset - inner.value.start_offset
            let inner_token = cursor.CursorToken(
                text = source.slice(inner.value.start_offset, inner_len),
                line = inner.value.line,
                column = inner.value.column,
                length = inner_len,
            )
            var frag = hover_range_fragment(inner_token, utils.source_line(source, inner_token.line), ws.position_encoding_utf16)
            empty.release()
            return frag
        Option.none:
            pass
    # Keywords, builtins and operators: the host ranges the token itself.
    match cursor.token_at_in(tokens, source, line, character):
        Option.some as tok:
            var frag = hover_range_fragment(tok.value, utils.source_line(source, tok.value.line), ws.position_encoding_utf16)
            empty.release()
            return frag
        Option.none:
            return empty


## Render the `"range":{...}` fragment for a resolved cursor token.
function hover_range_fragment(tok: cursor.CursorToken, line_text: str, utf16: bool) -> string.String:
    let lz = if tok.line > 0: tok.line - 1 else: 0z
    let col = if tok.column > 0: tok.column - 1 else: 0z
    var start_col = col
    var end_col = col + tok.length
    if utf16:
        start_col = utils.byte_to_utf16_column(line_text, col)
        end_col = utils.byte_to_utf16_column(line_text, col + tok.length)
    var frag = string.String.create()
    frag.append("\"range\":{\"start\":{\"line\":")
    frag.append_format(f"#{lz}")
    frag.append(",\"character\":")
    frag.append_format(f"#{start_col}")
    frag.append("},\"end\":{\"line\":")
    frag.append_format(f"#{lz}")
    frag.append(",\"character\":")
    frag.append_format(f"#{end_col}")
    frag.append("}}")
    return frag


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

    let doc = workspace.document_analysis_for(ws, file_path.as_str()) else:
        return
    var ast_file = doc.ast_file
    var analysis = doc.analysis

    # A type or interface this document declares: its own declaration.  The
    # host answers `module_member_definition_location` for the *current* module
    # and stops there, so an imported type with no declaration token here
    # (`quat` in a file that only uses it) answers null rather than the index.
    if analysis.types.contains(target.text) or analysis.interfaces.contains(target.text):
        let decl_line = type_declaration_line(ast_file, target.text)
        if decl_line > 0:
            respond_single_location(ws, id, uri, source, decl_line, target.text)
        else:
            proto.write_response(id, json.null_value())
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
                    match resolve_module_source_path_for(ws, module_name, file_path.as_str()):
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
public function analysis_for_document(
    ws: ref[workspace.Workspace],
    file_path: str,
    parsed_file: ast.SourceFile,
) -> analyzer.Analysis:
    let entry = workspace.analysis_entry_for(ws, file_path) else:
        return analyzer.check_source_file(parsed_file)
    return unsafe: read(entry).analysis


## The AST the analysis above was built from.
public function ast_for_document(
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
## receiver from its scope snapshot the same way).  Callers that resolve several
## names from the same source collect the bindings once and pass them in.
public function type_of_value_with_bindings(
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    name: str,
    target_line: ptr_uint,
    bindings: ref[vec.Vec[scope_mod.Binding]],
) -> Option[types.Type]:
    # The implicit receiver of an instance method is bound like a parameter, so
    # `this.x` resolves the receiver's type exactly as `this`'s own hover does.
    if name.equal("this"):
        return this_receiver_type(analysis, ast_file, target_line)

    unsafe:
        let global_ptr = read(analysis).value_types.get(name)
        if global_ptr != null:
            return Option[types.Type].some(value = read(global_ptr))

    let decl_line = scope_mod.local_binding_line(bindings, name, target_line) else:
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

    # A match-arm `as name` binding has no `stmt_local`; its recorded payload
    # type is the analyzer's arm-binding entry.  Checked after the ordinary
    # local/parameter scan so a common receiver never pays for the arm table.
    match arm_binding_type_at(analysis, name, decl_line):
        Option.some as arm_ty:
            return Option[types.Type].some(value = arm_ty.value)
        Option.none:
            pass

    return Option[types.Type].none


## The type of the local named `name` declared on `want_line`: its binding type
## (the resolved annotation, or the initializer's inferred type with an `else`
## guard's success-type narrowing).
function local_type_at_line(stmt: ast.Stmt, name: str, want_line: ptr_uint, analysis: ref[analyzer.Analysis]) -> Option[types.Type]:
    match find_local_decl_at_line(stmt, name, want_line):
        Option.some as found:
            match found.value:
                ast.Stmt.stmt_local as loc:
                    # A destructuring binding carries its own per-name type
                    # (`let (a, b) = …`), not the initializer's.
                    match destructure_type_at(analysis, name, loc.line):
                        Option.some as destructured:
                            return Option[types.Type].some(value = destructured.value)
                        Option.none:
                            pass
                    return type_render.local_binding_type(analysis, found.value)
                _:
                    return Option[types.Type].none
        Option.none:
            return Option[types.Type].none


## The analyzer's recorded type for the destructuring binding `name` declared
## on `line` (0 = no such binding).
function destructure_type_at(analysis: ref[analyzer.Analysis], name: str, line: ptr_uint) -> Option[types.Type]:
    var i: ptr_uint = 0
    let entries = read(analysis).destructure_types
    while i < entries.len():
        let ep = entries.get(i) else:
            break
        let entry = unsafe: read(ep)
        if entry.line == line and entry.name.equal(name):
            return Option[types.Type].some(value = entry.ty)
        i += 1
    return Option[types.Type].none


## The analyzer's recorded type for the `as name` variant arm binding declared
## on `line` (none when no such binding exists).
function arm_binding_type_at(analysis: ref[analyzer.Analysis], name: str, line: ptr_uint) -> Option[types.Type]:
    var i: ptr_uint = 0
    let entries = read(analysis).arm_binding_types
    while i < entries.len():
        let ep = entries.get(i) else:
            break
        let entry = unsafe: read(ep)
        if entry.line == line and entry.name.equal(name):
            return Option[types.Type].some(value = entry.ty)
        i += 1
    return Option[types.Type].none


## The hover for an `as name` variant arm binding: the host renders it from its
## scope snapshot as `local <name>: <payload type> (mutable)` with no source
## location, so both the declaration site and every use answer the same shape.
function arm_binding_hover_result(analysis: ref[analyzer.Analysis], name: str, line: ptr_uint, current_module: str) -> Option[CursorResult]:
    match arm_binding_type_at(analysis, name, line):
        Option.some as ty:
            var signature = string.String.create()
            signature.append("local ")
            signature.append(name)
            signature.append(": ")
            var type_text = type_render.qualified_name(ty.value, current_module)
            signature.append(type_text.as_str())
            type_text.release()
            signature.append(" (mutable)")
            var shortened = type_render.shorten_signature(signature.as_str())
            signature.release()
            return Option[CursorResult].some(value = CursorResult(
                line = 0,
                column = 0,
                name_len = name.len,
                hover_text = shortened.text,
                docs = string.String.create(),
                target_uri = string.String.create(),
                from_modules = shortened.modules
            ))
        Option.none:
            return Option[CursorResult].none


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
            respond_token_location(ws, id, target_uri.as_str(), token)
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
function respond_token_location(ws: ref[workspace.Workspace], id: json.Value, target_uri: str, token: defidx.DefinitionToken) -> void:
    let lz = if token.line > 0: token.line - 1 else: 0z
    var col = if token.column > 0: token.column - 1 else: 0z
    var end_col = col + token.length
    if ws.position_encoding_utf16:
        match uri_ops.file_uri_to_path(target_uri):
            Option.some as target_path:
                end_col = ws.output_character(target_path.value.as_str(), lz, end_col)
                col = ws.output_character(target_path.value.as_str(), lz, col)
                target_path.value.release()
            Option.none:
                pass
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
    json_text.append_format(f"#{end_col}")
    json_text.append("}}}")
    proto.write_response_raw(id, json_text.as_str())


## Respond with a `Location` pointing at `name` on its declaration line.
function respond_single_location(ws: ref[workspace.Workspace], id: json.Value, uri: str, source: str, decl_line: ptr_uint, name: str) -> void:
    let lz = if decl_line > 0: decl_line - 1 else: 0z
    var column: ptr_uint = 0
    match cursor.token_start_in_line(cursor.source_line(source, decl_line), name):
        Option.some as pos:
            column = pos.value
        Option.none:
            pass
    var end_column = column + name.len
    if ws.position_encoding_utf16:
        let line_text = utils.source_line(source, decl_line)
        end_column = utils.byte_to_utf16_column(line_text, end_column)
        column = utils.byte_to_utf16_column(line_text, column)

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
    json_text.append_format(f"#{end_column}")
    json_text.append("}}}")
    proto.write_response_raw(id, json_text.as_str())


## Handle textDocument/implementation: an interface *method*'s own declaration
## token answers each implementing type's method (the host's
## `interface_method_implementation_locations`); an interface *name* answers the
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

    let doc = workspace.document_analysis_for(ws, file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    var ast_file = doc.ast_file

    var json_text = string.String.create()
    defer: json_text.release()
    json_text.append("[")
    var emitted: ptr_uint = 0

    # The cursor is on an interface method's declaration: every open document's
    # implementing type answers that method's declaration line — the host's
    # `resolve_interface_method_target_at_token` arm.
    if interface_method_declared_at(ast_file, target.text, line + 1, character + 1):
        append_method_implementation_locations(ws, ref_of(json_text), ref_of(emitted), target.text)
        json_text.append("]")
        proto.write_response_raw(id, json_text.as_str())
        return

    var analysis = doc.analysis

    if not analysis.interfaces.contains(target.text):
        proto.write_response_raw(id, "[]")
        return

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
                        append_location(ref_of(json_text), uri, source, decl_line, struct_name, ws.position_encoding_utf16)
                    break
                qi += 1

    json_text.append("]")
    proto.write_response_raw(id, json_text.as_str())


## True when the cursor's identifier token is an interface method's own name in
## this file — the host's `resolve_interface_method_target_at_token`.
function interface_method_declared_at(
    file: ast.SourceFile,
    name: str,
    line: ptr_uint,
    column: ptr_uint,
) -> bool:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_interface as ifc:
                var mi: ptr_uint = 0
                while mi < ifc.interface_methods.len:
                    var mfn: ast.InterfaceMethod
                    unsafe:
                        mfn = read(ifc.interface_methods.data + mi)
                    if mfn.name == name and mfn.line == line and mfn.column == column:
                        return true
                    mi += 1
            _:
                pass
        di += 1
    return false


## Append one Location per *open* document whose implementing type declares
## `method_name` — the host's `interface_method_implementation_locations`, whose
## location is the method binding's declaration in the receiver's module (here:
## the implementing type's `extending` block).
function append_method_implementation_locations(
    ws: ref[workspace.Workspace],
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    method_name: str,
) -> void:
    let open_paths = ws.open_paths_in_order()
    var pi: ptr_uint = 0
    while pi < open_paths.len:
        let path = unsafe: read(open_paths.data + pi).as_str()
        pi += 1
        var content = ws.document_source(path) else:
            continue
        let doc = workspace.document_analysis_for(ws, path) else:
            continue
        let file = doc.ast_file
        var analysis = doc.analysis

        var type_iter = analysis.implemented_interfaces.entries()
        while type_iter.next():
            let entry = type_iter.current()
            let type_name = unsafe: read(entry.key)
            # Only a type that really declares the method answers — the host reads
            # `methods_for_receiver_type(...)[name]`, so a generic constraint
            # (`T implements Damageable`) has no method to report.
            if method_sig_for_type(ref_of(analysis), type_name, method_name).is_none():
                continue
            let decl_line = find_method_line_in_type(file, type_name, method_name)
            if decl_line > 0:
                var target_uri = file_uri_for_path(path)
                if unsafe: read(emitted) > 0:
                    json_text.append(",")
                unsafe: read(emitted) += 1
                append_location(json_text, target_uri.as_str(), content.as_str(), decl_line, method_name, ws.position_encoding_utf16)
                target_uri.release()
        content.release()


## True when the qualified name's last part equals `name` (`Damageable` and
## `lib.Damageable` both match "Damageable").
function qualified_name_matches(qn: ast.QualifiedName, name: str) -> bool:
    if qn.parts.len == 0:
        return false
    let last = unsafe: read(qn.parts.data + qn.parts.len - 1)
    return last.equal(name)


## Append one Location object pointing at `name` on `decl_line`.
function append_location(json_text: ref[string.String], uri: str, source: str, decl_line: ptr_uint, name: str, utf16: bool) -> void:
    let lz = if decl_line > 0: decl_line - 1 else: 0z
    var column: ptr_uint = 0
    match cursor.token_start_in_line(cursor.source_line(source, decl_line), name):
        Option.some as pos:
            column = pos.value
        Option.none:
            pass
    var end_column = column + name.len
    if utf16:
        let line_text = utils.source_line(source, decl_line)
        end_column = utils.byte_to_utf16_column(line_text, end_column)
        column = utils.byte_to_utf16_column(line_text, column)
    json_text.append("{\"uri\":\"")
    proto.append_escaped(json_text, uri)
    json_text.append("\",\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{column}")
    json_text.append("},\"end\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{end_column}")
    json_text.append("}}}")


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

    # The host requires an identifier token under the cursor (its
    # `token.type == :identifier` gate) before this arm runs: an `alias.member`
    # spelled inside a comment or a string defines nothing.
    if cursor.identifier_at(source, line, character).is_none():
        return Option[string.String].none

    match cursor.dot_receiver_at(source, line, character):
        Option.some as recv:
            let doc = workspace.document_analysis_for(ws, file_path.as_str()) else:
                return Option[string.String].none
            var analysis = doc.analysis
            unsafe:
                let module_ptr = analysis.imports.get(recv.value)
                if module_ptr != null:
                    return resolve_module_source_path_for(ws, read(module_ptr), file_path.as_str())
        Option.none:
            pass
    return Option[string.String].none


## The host's last-resort global definition lookup (`find_definition_token_global`):
## the requesting document first with the cursor as the position filter, then
## every document the index knows declares the name, in warm order, first
## declaration wins.  Only identifiers a declaration keyword introduces are
## indexed, so an ordinary reference or a parameter answers none, as the host's
## does.  The host's candidate set is its indexed documents — the workspace tree
## plus every dependency file its loader has read — which is why a `let` in a
## std module answers here.
public function find_definition_global(
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
    let indexed_paths = defidx.candidate_paths_for(ref_of(ws.definition_index), name)
    var i: ptr_uint = 0
    while i < indexed_paths.len:
        let entry = unsafe: read(indexed_paths.data + i)
        add_definition_candidate(ws, ref_of(owned_sources), ref_of(candidates), entry.as_str())
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


## The hover for a field name in its own declaration and for a named-argument
## label — the host's arms that run *ahead* of every name and member lookup.
function resolve_field_or_label_hover(
    ws: ref[workspace.Workspace],
    file_path: str,
    source: str,
    line: ptr_uint,
    character: ptr_uint,
) -> Option[CursorResult]:
    if source.len == 0:
        return Option[CursorResult].none

    match field_declaration_hover(ws, file_path, source, line, character):
        Option.some as fd:
            return Option[CursorResult].some(value = fd.value)
        Option.none:
            pass

    var tokens = ws.document_tokens(file_path, source)
    match token_index_at(tokens, line, character):
        Option.some as matched_index:
            match named_argument_label_hover(ws, source, file_path, tokens, matched_index.value):
                Option.some as label_hover:
                    return Option[CursorResult].some(value = label_hover.value)
                Option.none:
                    pass
        Option.none:
            pass
    return Option[CursorResult].none


## The hover for a language keyword, a builtin type, a builtin specialization or
## a builtin callable — the host's *last* arm, after every name and member
## lookup has declined (`get` resolves to a declared method, not the builtin
## table; an import alias named `ptr` resolves to its module).
function resolve_keyword_or_builtin_hover(
    ws: ref[workspace.Workspace],
    file_path: str,
    source: str,
    line: ptr_uint,
    character: ptr_uint,
) -> Option[CursorResult]:
    if source.len == 0:
        return Option[CursorResult].none

    var tokens = copy_tokens(ws.document_tokens(file_path, source))
    defer: tokens.release()

    let matched_index = token_index_at(tokens.as_span(), line, character) else:
        return Option[CursorResult].none
    let tp = tokens.get(matched_index) else:
        return Option[CursorResult].none
    let t = unsafe: read(tp)
    let lexeme = unsafe: token_mod.token_lexeme(t, source)

    match hover_docs.language_keyword(lexeme):
        Option.some as kw:
            var keyword_result = quick_hover_doc(kw.value)
            # The host prints a keyword's location from its token index when the
            # name is declared somewhere in the workspace; a builtin's arm
            # carries no location at all.
            apply_hover_index_location(ws, file_path, source, line, character, ref_of(keyword_result))
            return Option[CursorResult].some(value = keyword_result)
        Option.none:
            pass

    # A specialization answers before the type table: the host's
    # `builtin_hover_info` runs its value, hook and type-constructor arms for a
    # name followed by `[`, and only a *registered* type (`int`, `str`, …)
    # reaches the `type <name>` shape.  The host's `resolve_hover_info` falls
    # back to the workspace definition index whenever it resolves a signature
    # without an explicit location, so a name the workspace also declares
    # (`let ptr: ptr[int]?`) gains its location line.
    match builtin_specialization_hover(tokens, source, matched_index, lexeme):
        Option.some as bs:
            var specialization_result = quick_hover_doc(bs.value)
            apply_hover_index_location(ws, file_path, source, line, character, ref_of(specialization_result))
            return Option[CursorResult].some(value = specialization_result)
        Option.none:
            pass

    # A builtin type name (`int`, `str`, `ptr`, …) renders the host's
    # `type <name>` signature with its documentation table.
    match hover_docs.builtin_type(lexeme):
        Option.some as bt:
            var builtin_type_result = quick_hover_doc(bt.value)
            apply_hover_index_location(ws, file_path, source, line, character, ref_of(builtin_type_result))
            return Option[CursorResult].some(value = builtin_type_result)
        Option.none:
            pass

    match hover_docs.builtin_call(lexeme):
        Option.some as bu:
            var builtin_call_result = quick_hover_doc(bu.value)
            apply_hover_index_location(ws, file_path, source, line, character, ref_of(builtin_call_result))
            return Option[CursorResult].some(value = builtin_call_result)
        Option.none:
            pass

    # A type parameter (`function f[T](…)`, `[T implements I]`, `[N: int]`): the
    # host's `type_parameter_hover_signature`, whose arm carries no location.
    match type_parameter_signature(tokens.as_span(), source, matched_index):
        Option.some as type_param:
            var type_param_text = type_param.value
            var type_param_result = quick_hover(type_param_text.as_str())
            type_param_text.release()
            return Option[CursorResult].some(value = type_param_result)
        Option.none:
            pass

    # A target in an attribute's declaration (`attribute[field] rename(…)`): the
    # host's `attribute_target_token?` arm.
    if attribute_target_token(tokens.as_span(), matched_index):
        var target_text = string.String.create()
        target_text.append("attribute target ")
        target_text.append(lexeme)
        var target_result = quick_hover(target_text.as_str())
        target_text.release()
        return Option[CursorResult].some(value = target_result)

    return Option[CursorResult].none


## A mutable copy of a cached token span, for the helpers that still take a
## vector (the keyword/builtin arms).
function copy_tokens(tokens: span[token_mod.Token]) -> vec.Vec[token_mod.Token]:
    var copy = vec.Vec[token_mod.Token].create()
    var i: ptr_uint = 0
    while i < tokens.len:
        copy.push(unsafe: read(tokens.data + i))
        i += 1
    return copy


## A mutable copy of the cached scope bindings; the `scope` helpers take a
## vector, and a copy is far cheaper than re-walking the AST.
function copy_bindings(bindings: span[scope_mod.Binding]) -> vec.Vec[scope_mod.Binding]:
    var copy = vec.Vec[scope_mod.Binding].create()
    var i: ptr_uint = 0
    while i < bindings.len:
        copy.push(unsafe: read(bindings.data + i))
        i += 1
    return copy


## The index of the token covering the 0-based position, or none.
function token_index_at(tokens: span[token_mod.Token], line: ptr_uint, character: ptr_uint) -> Option[ptr_uint]:
    let target_line = line + 1
    var ti: ptr_uint = 0
    while ti < tokens.len:
        let t = unsafe: read(tokens.data + ti)
        if t.line > target_line:
            break
        if t.line == target_line and t.column - 1 <= character and t.column - 1 + t.end_offset - t.start_offset > character:
            return Option[ptr_uint].some(value = ti)
        ti += 1
    return Option[ptr_uint].none


## `resolve_cursor` for callers that do not already hold the document text
## (the definition pipeline); the hover path passes its one source copy.
public function resolve_cursor_at(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
    for_hover: bool,
) -> Option[CursorResult]:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        return Option[CursorResult].none
    defer: file_path.release()
    var content = ws.document_text(file_path.as_str()) else:
        return Option[CursorResult].none
    return resolve_cursor(ws, uri, content.text, line, character, for_hover)


## Resolve the symbol at the given cursor position.  Finds the identifier under
## the cursor and looks it up in the analysis maps.  `alias.member` accesses and
## import aliases resolve cross-file into the imported module.
public function resolve_cursor(
    ws: ref[workspace.Workspace],
    uri: str,
    source: str,
    line: ptr_uint,
    character: ptr_uint,
    # A definition/declaration request shares this dispatch but not the host's
    # hover-only arms: a user-declared attribute's name resolves for a hover and
    # answers nothing for a definition, exactly as the host's separate
    # definition pipeline does.
    for_hover: bool,
) -> Option[CursorResult]:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        return Option[CursorResult].none
    defer: file_path.release()

    if source.len == 0:
        return Option[CursorResult].none

    var target: cursor.CursorToken
    let document_tokens = ws.document_tokens(file_path.as_str(), source)
    match cursor.identifier_at_in(document_tokens, source, line, character):
        Option.some as plain:
            target = plain.value
        Option.none:
            # A hover resolves an identifier inside a format string's
            # interpolation; the host's `token_context_at` does this ahead of
            # `find_token_at` (definitions keep the plain token, as the host's
            # definition pipeline does).
            match cursor.interpolation_identifier_at_in(document_tokens, source, line, character):
                Option.some as inner:
                    target = inner.value
                Option.none:
                    return Option[CursorResult].none

    # A segment of an `import a.b.c` path resolves to that module's file, as the
    # alias itself does (the host's `import_path_info_at`).
    match import_module_name_at(document_tokens, source, line, character):
        Option.some as import_name:
            defer: import_name.value.release()
            return resolve_module_reference(ws, import_name.value.as_str(), file_path.as_str())
        Option.none:
            pass

    # The facts come from the loader-backed analysis, as the host's do: a
    # standalone check carries no import bindings, so every `alias.Type` and
    # `alias.member` reference would resolve to `<error>`.
    let doc = workspace.document_analysis_for(ws, file_path.as_str()) else:
        return Option[CursorResult].none
    var ast_file = doc.ast_file
    var analysis = doc.analysis
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
                    return resolve_module_member(ws, read(module_ptr), target.text, file_path.as_str())
            # `EnumType.member`: render the enum or flags member (`running: State
            # = 1`) at its declaration — but a *variant*'s arms are not members
            # with values; they resolve through the arm-name arms below, which
            # render the constructor form (`Kind.ident(name: str)`).
            if not analysis.variant_types.contains(recv.value) and (analysis.static_member_types.contains(recv.value) or analysis.member_names.contains(recv.value)):
                match resolve_enum_member(ws, ast_file, recv.value, target.text, ref_of(analysis), file_path.as_str()):
                    Option.some as member_hit:
                        return Option[CursorResult].some(value = member_hit.value)
                    Option.none:
                        pass
        Option.none:
            pass

    # `alias.Type.arm` / an imported `Type.arm`: a variant arm declared in the
    # type's module (a self-better extension — the host answers only a local
    # `Type.arm`).  The module analysis comes from the current document's loaded
    # program, so this costs no extra parse.
    match cursor.type_receiver_at(source, line, character):
        Option.some as arm_recv:
            match resolve_aliased_enum_member(ws, ast_file, ref_of(analysis), doc.program, arm_recv.value, target.text, file_path.as_str()):
                Option.some as alias_hit:
                    return Option[CursorResult].some(value = alias_hit.value)
                Option.none:
                    pass
            match resolve_imported_variant_arm(ws, ref_of(analysis), arm_recv.value, target.text, file_path.as_str(), doc.program):
                Option.some as arm_hit:
                    return Option[CursorResult].some(value = arm_hit.value)
                Option.none:
                    pass
        Option.none:
            pass

    # The host resolves a *member access* before its name tables
    # (`resolve_member_access_hover_info` runs ahead of the signature lookup),
    # so `d.push_back(…)` and `rl.Color.hex_digit(…)` report their defining
    # module rather than a same-named local declaration.  A receiver that is not
    # a name/field chain (`read(p).get_object`) has no text path; the analyzer's
    # recorded receiver type answers it (a self-better extension: the host
    # requires an identifier immediately before the dot).
    if cursor.member_dot_at(source, line, character):
        var receiver_path: str = ""
        match cursor.dot_receiver_at(source, line, character):
            Option.some as recv:
                receiver_path = recv.value
                match cursor.dot_receiver_path_text_at(source, line, character):
                    Option.some as path_text:
                        receiver_path = path_text.value
                    Option.none:
                        pass
            Option.none:
                pass
        match resolve_member_method_hover(
            ws, ast_file, ref_of(analysis), source, file_path.as_str(), receiver_path, target.text,
            line + 1, character + 1, current_module.as_str()):
            Option.some as member_result:
                return Option[CursorResult].some(value = member_result.value)
            Option.none:
                pass

    # `Type.method(...)` / `Type[T].method(...)` / `alias.Type.method(...)`: a
    # *type* receiver, whose method lives in the type's own module.
    match cursor.type_receiver_at(source, line, character):
        Option.some as type_recv:
            match resolve_type_method_hover(
                ws, ast_file, ref_of(analysis), source, type_recv.value, target.text,
                current_module.as_str(), file_path.as_str()):
                Option.some as type_result:
                    return Option[CursorResult].some(value = type_result.value)
                Option.none:
                    pass
        Option.none:
            pass

    # A builtin primitive type name (`str`, `int`, `vec3`, …) is a *registered*
    # type in the host's facts, so it answers its `type <name>` docs before the
    # import-alias arm — `import std.str` does not shadow `str`.  The generic
    # builtin constructors (`ptr`, `ref`, `span`, …) are not registered types and
    # stay with the keyword/builtin table, which runs last.
    # A bare variant arm name (`Result.success(value = T)`,
    # `Primitive.circle(radius: float)`): the host's
    # `find_variant_arm_in_types` scans the file's declared types in reverse
    # order for the first one with an arm of that name, ahead of every name
    # lookup below.  Hover-only, like the member arm above.
    if for_hover:
        match variant_arm_name_hover(ws, ast_file, target.text):
            Option.some as arm_hover:
                return Option[CursorResult].some(value = arm_hover.value)
            Option.none:
                pass

    # The host resolves a bare name through its facts before the import aliases:
    # a registered type (`str`, `int`, `vec3`) answers its own declaration or its
    # builtin docs even when an `import std.str` alias shares the name.
    match resolve_name_in_analysis(ast_file, ref_of(analysis), target.text, source, current_module.as_str(), line + 1, character + 1):
        Option.some as named:
            return Option[CursorResult].some(value = named.value)
        Option.none:
            pass

    # A bare enum/flags member name (`Kind.a = 0`): the host's
    # `find_member_in_types` runs after every name lookup and renders
    # `Type.member = value` — the member's value *folded* to an integer, so an
    # implicit member reports the auto-incremented value.  Hover-only: the host's
    # *definition* pipeline has no such arm, so a definition request for a name
    # that happens to be a member (`b` in `flags Mask`) keeps resolving through
    # the local rule and the definition index.
    if for_hover:
        match bare_member_hover(ast_file, ref_of(analysis), target.text):
            Option.some as member_hit:
                return Option[CursorResult].some(value = member_hit.value)
            Option.none:
                pass

    # The identifier is an import alias.  A *definition* first looks the alias's
    # name up as a declaration inside the module it names (the host's
    # `module_member_definition_location`: `hash` finds `function hash` in
    # std/hash.mt, `ptr` the `extending ptr[T]:` block) and then answers the
    # module file; a hover answers the module either way.
    unsafe:
        let alias_module_ptr = analysis.imports.get(target.text)
        if alias_module_ptr != null:
            let alias_module = read(alias_module_ptr)
            if not for_hover:
                match import_alias_member_decl(ws, alias_module, target.text, file_path.as_str()):
                    Option.some as member_decl:
                        return Option[CursorResult].some(value = member_decl.value)
                    Option.none:
                        pass
            return resolve_module_reference(ws, alias_module, file_path.as_str())

    # A user-declared attribute (`attribute[callable] traced(tag: str)`): the
    # host's `facts.attributes` arm, which renders the target list and the
    # declared parameters and reports the *module's* location.
    if for_hover:
        return declared_attribute_hover(ast_file, target.text)

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
    from_path: str,
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
        var owner_path = resolve_module_source_path_for(ws, owner, from_path) else:
            target_uri.release()
            return Option[CursorResult].none
        defer: owner_path.release()
        let owner_source = ws.document_source(owner_path.as_str()) else:
            target_uri.release()
            return Option[CursorResult].none
        let owner_doc = workspace.document_analysis_for(ws, owner_path.as_str()) else:
            target_uri.release()
            return Option[CursorResult].none
        decl_file = owner_doc.ast_file
        var owner_analysis = owner_doc.analysis
        decl_signature = method_sig_for_type(ref_of(owner_analysis), receiver.name, method_name)
        decl_source = owner_source.as_str()
        target_uri.release()
        target_uri = file_uri_for_path(owner_path.as_str())

    # The host's `methods_for_receiver_type` merges the enclosing module's
    # methods with every *imported* module's, which is how a builtin receiver's
    # method resolves (`mat4.identity` through `std.linear_algebra`'s
    # `extending mat4:`) even though the type itself has no owning module.
    if decl_signature.is_none():
        match imported_type_method_hover(ws, analysis, receiver.name, method_name, current_module, from_path):
            Option.some as imported_method:
                target_uri.release()
                return Option[CursorResult].some(value = imported_method.value)
            Option.none:
                pass

    let signature = decl_signature else:
        target_uri.release()
        return Option[CursorResult].none
    # The declaration line comes from the *receiver's* type, not the first method
    # of that name in the file: `dg.release()` on a `DenseGraph[str]` points at
    # `extending DenseGraph[T]`'s method, not at `extending Graph[T]`'s.
    let decl_line = find_method_line_in_type(decl_file, receiver.name, method_name)
    if decl_line == 0:
        target_uri.release()
        return Option[CursorResult].none

    # The host pairs the receiver's *module* file with the declaring file's line
    # (`module_member_binding_location` resolves the path from the module name),
    # so a method an `extending` block in this document adds to an imported type
    # reports `std/raylib.mt` with the line here — the same artifact the
    # references static arm reproduces.
    if target_uri.len() == 0 and owner.len > 0 and not owner.equal(current_module):
        match resolve_module_source_path_for(ws, owner, from_path):
            Option.some as owner_path:
                target_uri = file_uri_for_path(owner_path.value.as_str())
                owner_path.value.release()
            Option.none:
                pass

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
            let im_bp = unsafe: read(im.payload)
            return im_bp.name
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return n_np.name
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return g_bp.name
        types.Type.ty_primitive as p:
            # A builtin receiver (`vec3`, `mat4`) names no module, but its
            # methods still live in an `extending` block.
            return p.name
        types.Type.ty_str:
            return "str"
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


## True when the token at `index` is the first non-structural token on its line
## (the host's `first_non_trivia_token_on_line?`).
function first_non_trivia_on_line(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    var target_line: ptr_uint = 0
    unsafe:
        target_line = read(tokens.data + index).line
    var i = index
    while i > 0:
        i -= 1
        var prev: token_mod.Token
        unsafe:
            prev = read(tokens.data + i)
        if prev.kind == tk.TokenKind.newline:
            return true
        if prev.line == target_line and prev.kind != tk.TokenKind.indent and prev.kind != tk.TokenKind.dedent:
            return false
    return true


## The host's `find_field_token_in_body` (`lsp/server/definition.rb`): the token
## declaring `field_name` inside the body whose header keyword is at
## `header_index`, or none.  The scan is indentation-sensitive — it stops at the
## first line-leading token at or left of the header keyword's column — so a
## field indented less than its header's keyword is never reached.
function find_field_token_in_body(
    tokens: span[token_mod.Token],
    source: str,
    header_index: ptr_uint,
    field_name: str,
) -> Option[token_mod.Token]:
    var header: token_mod.Token
    unsafe:
        header = read(tokens.data + header_index)
    var i = header_index + 1
    while i < tokens.len:
        var tok: token_mod.Token
        unsafe:
            tok = read(tokens.data + i)
        if tok.line > header.line and not is_structural_token_kind(tok.kind) and first_non_trivia_on_line(tokens, i) and tok.column <= header.column:
            break
        if tok.kind == tk.TokenKind.identifier and tok.line > header.line and first_non_trivia_on_line(tokens, i) and tok.column > header.column:
            let lexeme = unsafe: token_mod.token_lexeme(tok, source)
            if lexeme.equal(field_name):
                match next_code_index(tokens, i + 1):
                    Option.some as colon_index:
                        if token_kind_at(tokens, colon_index.value, tk.TokenKind.colon):
                            return Option[token_mod.Token].some(value = tok)
                    Option.none:
                        pass
        i += 1
    return Option[token_mod.Token].none


## The host's `find_field_token_in_type`: the token declaring `field_name` inside
## `type_name`'s struct or union, or none.  Because `find_field_token_in_body`
## stops at a line-leading token at or left of the `struct`/`union` keyword's
## column, a field of a `public struct X:` is never found — its declaration sits
## at column 5 while the `struct` keyword sits at column 8 — and the host prints
## no `Defined at` line for it.  The artefact must be reproduced, so a field's
## hover location comes from this scan and never from the AST's field position.
function find_field_token_in_type(source: str, type_name: str, field_name: str) -> Option[token_mod.Token]:
    var lex_diags = vec.Vec[token_mod.LexDiagnostic].create()
    defer: lex_diags.release()
    var tokens = lexer_mod.lex_reporting(source, ref_of(lex_diags))
    defer: tokens.release()
    return find_field_token_in_type_in(tokens.as_span(), source, type_name, field_name)


## `find_field_token_in_type` over an existing token stream.
function find_field_token_in_type_in(tokens: span[token_mod.Token], source: str, type_name: str, field_name: str) -> Option[token_mod.Token]:
    var ti: ptr_uint = 0
    while ti < tokens.len:
        let tok = unsafe: read(tokens.data + ti)
        if tok.kind == tk.TokenKind.tk_struct or tok.kind == tk.TokenKind.tk_union:
            match next_code_index(tokens, ti + 1):
                Option.some as name_index:
                    let name_tok = unsafe: read(tokens.data + name_index.value)
                    if name_tok.kind == tk.TokenKind.identifier:
                        let lexeme = unsafe: token_mod.token_lexeme(name_tok, source)
                        if lexeme.equal(type_name):
                            match find_field_token_in_body(tokens, source, ti, field_name):
                                Option.some as found:
                                    return Option[token_mod.Token].some(value = found.value)
                                Option.none:
                                    pass
                Option.none:
                    pass
        ti += 1
    return Option[token_mod.Token].none


## Hover for a field of a match-arm payload binding (`a` in
## `Kind.alpha as a`, then `a.value`): the arm's synthesized payload fields, with
## no declaration to point at (the host prints no `Defined at` line).
function variant_arm_field_hover(
    fields: span[types.PayloadField],
    field_name: str,
    current_module: str,
) -> Option[CursorResult]:
    var i: ptr_uint = 0
    while i < fields.len:
        let field = unsafe: read(fields.data + i)
        if field.name.equal(field_name):
            var hover = string.String.create()
            hover.append("field ")
            hover.append(field_name)
            hover.append(": ")
            var rendered = type_render.qualified_name(field.ty, current_module)
            hover.append(rendered.as_str())
            rendered.release()
            var shortened = type_render.shorten_signature(hover.as_str())
            hover.release()
            return Option[CursorResult].some(value = CursorResult(
                line = 0,
                column = 0,
                name_len = field_name.len,
                hover_text = shortened.text,
                docs = string.String.create(),
                target_uri = string.String.create(),
                from_modules = shortened.modules
            ))
        i += 1
    return Option[CursorResult].none


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
        var resolved_path = resolve_module_source_path_for(ws, owner, file_path) else:
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

    let decl_doc = workspace.document_analysis_for(ws, decl_path) else:
        return Option[CursorResult].none
    var decl_file = decl_doc.ast_file
    var decl_analysis = decl_doc.analysis

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
                            found = true
                        fi += 1
            _:
                pass
        di += 1
    if not found:
        # A builtin vector/matrix/quaternion field (`v.x`, `m.col0`) has no
        # declaration to point at: the hover is the field's own type, with no
        # location (the host's `Types::Vector#field`).
        match builtin_field_type_name(type_name, field_name):
            Option.some as builtin_field:
                var builtin_text = string.String.create()
                builtin_text.append("field ")
                builtin_text.append(field_name)
                builtin_text.append(": ")
                builtin_text.append(builtin_field.value)
                return Option[CursorResult].some(value = CursorResult(
                    line = 0,
                    column = 0,
                    name_len = field_name.len,
                    hover_text = builtin_text,
                    docs = string.String.create(),
                    target_uri = string.String.create(),
                    from_modules = string.String.create()
                ))
            Option.none:
                pass
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

    # The location is the *token* declaring the field, not the AST field's
    # position: the host's `find_field_token_in_type` scan stops at a line-leading
    # token at or left of the `struct` keyword's column, so a field of a
    # `public struct` has no location to report and the hover prints none.
    var field_line: ptr_uint = 0
    var field_column: ptr_uint = 0
    let decl_tokens = ws.document_tokens(decl_path, decl_source.as_str())
    match find_field_token_in_type_in(decl_tokens, decl_source.as_str(), type_name, field_name):
        Option.some as field_token:
            field_line = field_token.value.line
            field_column = field_token.value.column
        Option.none:
            pass

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


## The type of a receiver chain's last segment: the first segment is a value
## (`ctx`, `this`, a parameter), and each following segment is a field of the
## previous type.  None when the value name does not resolve or a field is
## missing, so the caller keeps its no-answer behaviour.
function receiver_path_type(
    ws: ref[workspace.Workspace],
    file_path: str,
    analysis: ref[analyzer.Analysis],
    ast_file: ast.SourceFile,
    path: str,
    target_line: ptr_uint,
    source_text: str,
) -> Option[types.Type]:
    var first_end: ptr_uint = 0
    while first_end < path.len and path.byte_at(first_end) != '.':
        first_end += 1
    let first = path.slice(0, first_end)
    var bindings = copy_bindings(ws.document_bindings(file_path, source_text, ast_file))
    defer: bindings.release()
    var current_ty = type_of_value_with_bindings(analysis, ast_file, first, target_line, ref_of(bindings)) else:
        return Option[types.Type].none
    var si = first_end
    while si < path.len:
        si += 1
        var seg_end = si
        while seg_end < path.len and path.byte_at(seg_end) != '.':
            seg_end += 1
        let field_name = path.slice(si, seg_end - si)
        match field_of_type(analysis, current_ty, field_name):
            Option.some as field_ty:
                current_ty = field_ty.value
            Option.none:
                return Option[types.Type].none
        si = seg_end
    return Option[types.Type].some(value = current_ty)


## Hover for the method name of a member call (`v.push(1)`, `d.push_back(x)`):
## the method's declaration signature, the module that declares it, and — through
## the shortened signature — that module's `*From <module>*` line.  The receiver
## is a value name or a field chain (`ctx.lookup.set`, `this.cache.set`): the
## first segment resolves through the analysis (a local, parameter or
## module-level value) and each later one through the previous field's type.
## None when a segment does not resolve, so `EnumType.member` and `alias.member`
## keep their own paths.
function resolve_member_method_hover(
    ws: ref[workspace.Workspace],
    ast_file: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    source: str,
    file_path: str,
    receiver_path: str,
    method_name: str,
    target_line: ptr_uint,
    target_character: ptr_uint,
    current_module: str,
) -> Option[CursorResult]:
    var receiver_ty = types.Type.ty_error
    var resolved_receiver = false
    if receiver_path.len > 0:
        match receiver_path_type(ws, file_path, analysis, ast_file, receiver_path, target_line, source):
            Option.some as path_ty:
                receiver_ty = path_ty.value
                resolved_receiver = true
            Option.none:
                pass
    if not resolved_receiver:
        # The receiver is not a name/field chain (`read(p).get_object`,
        # `build().field`, `a[0].b`): the analyzer recorded the expression's
        # inferred type at the member token's position.
        match analyzer.member_receiver_type_at(analysis, target_line, target_character):
            Option.some as recorded_ty:
                receiver_ty = recorded_ty.value
                resolved_receiver = true
            Option.none:
                return Option[CursorResult].none
    # A match-arm payload binding (`a` in `Kind.alpha as a`): its fields are the
    # arm's synthesized payload fields, with no declaring struct to scan.
    match receiver_ty:
        types.Type.ty_variant_arm_payload as arm:
            return variant_arm_field_hover(unsafe: read(arm.payload).fields, method_name, current_module)
        _:
            pass
    # The host projects the receiver through a pointer-like first
    # (`project_field_receiver_type`), so `r.x` on a `ref[vec3]` resolves the
    # vector's own field.
    let projected_ty = analyzer.project_pointer_receiver(receiver_ty)
    let type_name = receiver_type_name(projected_ty)
    if type_name.len == 0:
        return Option[CursorResult].none

    let owner = types.nominal_module(projected_ty)

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
        var owner_path = resolve_module_source_path_for(ws, owner, file_path) else:
            target_uri.release()
            return Option[CursorResult].none
        defer: owner_path.release()
        let owner_source = ws.document_source(owner_path.as_str()) else:
            target_uri.release()
            return Option[CursorResult].none
        let owner_doc = workspace.document_analysis_for(ws, owner_path.as_str()) else:
            target_uri.release()
            return Option[CursorResult].none
        decl_file = owner_doc.ast_file
        var owner_analysis = owner_doc.analysis
        decl_signature = method_sig_for_type(ref_of(owner_analysis), type_name, method_name)
        decl_source = owner_source.as_str()
        target_uri.release()
        target_uri = file_uri_for_path(owner_path.as_str())

    # The host's `methods_for_receiver_type` merges the enclosing module's
    # methods with every *imported* module's, which is how a builtin receiver's
    # method resolves (`vec3.cross` through `std.linear_algebra`'s
    # `extending vec3:`) even though the type itself has no owning module.
    if decl_signature.is_none():
        match imported_type_method_hover(ws, analysis, type_name, method_name, current_module, file_path):
            Option.some as imported_method:
                target_uri.release()
                return Option[CursorResult].some(value = imported_method.value)
            Option.none:
                pass

    let signature = decl_signature else:
        target_uri.release()
        return Option[CursorResult].none
    # The declaration line comes from the *receiver's* type, not the first method
    # of that name in the file: `dg.release()` on a `DenseGraph[str]` points at
    # `extending DenseGraph[T]`'s method, not at `extending Graph[T]`'s.
    let decl_line = find_method_line_in_type(decl_file, type_name, method_name)
    if decl_line == 0:
        target_uri.release()
        return Option[CursorResult].none

    # The host pairs the receiver's *module* file with the declaring file's line
    # (`module_member_binding_location` resolves the path from the module name),
    # so a method an `extending` block in this document adds to an imported type
    # reports `std/raylib.mt` with the line here — the same artifact the
    # references static arm reproduces.
    if target_uri.len() == 0 and owner.len > 0 and not owner.equal(current_module):
        match resolve_module_source_path_for(ws, owner, file_path):
            Option.some as owner_path:
                target_uri = file_uri_for_path(owner_path.value.as_str())
                owner_path.value.release()
            Option.none:
                pass

    var hover = method_signature_text(signature, method_name, owner_or(current_module, owner))
    let result = make_shortened_result(decl_line, method_name, decl_source, hover.as_str())
    hover.release()
    var stamped = result
    stamped.target_uri.release()
    stamped.target_uri = target_uri
    return Option[CursorResult].some(value = stamped)


## The methods every *imported* module adds to `type_name` — the host's
## `methods_for_receiver_type` merges the enclosing module's methods with each
## imported module's, so a builtin receiver's method (`vec3.cross`,
## `mat4.identity`) resolves through its `extending` block wherever it lives
## (`std.linear_algebra`), even though the type itself has no owning module.
## The signature is stamped with the declaring module's URI, the way the host's
## `module_member_binding_location` pairs a module's path with the declaration
## line.
function imported_type_method_hover(
    ws: ref[workspace.Workspace],
    analysis: ref[analyzer.Analysis],
    type_name: str,
    method_name: str,
    current_module: str,
    from_path: str,
) -> Option[CursorResult]:
    var imports = unsafe: read(analysis).imports.entries()
    while imports.next():
        let entry = imports.current()
        var module_name = unsafe: read(entry.value)
        if module_name.len == 0 or module_name.equal(current_module):
            continue
        var module_path = resolve_module_source_path_for(ws, module_name, from_path) else:
            continue
        defer: module_path.release()
        var module_source = ws.document_source(module_path.as_str()) else:
            continue
        defer: module_source.release()
        let module_doc = workspace.document_analysis_for(ws, module_path.as_str()) else:
            continue
        var module_analysis = module_doc.analysis
        let found = method_sig_for_type(ref_of(module_analysis), type_name, method_name)
        match found:
            Option.some as found_sig:
                let decl_file = module_doc.ast_file
                let decl_line = find_method_line_in_type(decl_file, type_name, method_name)
                if decl_line > 0:
                    var hover = method_signature_text(found_sig.value, method_name, module_name)
                    let result = make_shortened_result(decl_line, method_name, module_source.as_str(), hover.as_str())
                    hover.release()
                    var stamped = result
                    stamped.target_uri.release()
                    stamped.target_uri = file_uri_for_path(module_path.as_str())
                    return Option[CursorResult].some(value = stamped)
            Option.none:
                pass
    return Option[CursorResult].none


## Resolve `member` inside imported module `module_name`: check the module's
## file with its own imports bound, reuse the same-file resolver there, and
## stamp the result with the module file's URI.
function resolve_module_member(ws: ref[workspace.Workspace], module_name: str, member: str, from_path: str) -> Option[CursorResult]:
    var module_path = resolve_module_source_path_for(ws, module_name, from_path) else:
        return Option[CursorResult].none
    defer: module_path.release()

    var module_source = ws.document_source(module_path.as_str()) else:
        return Option[CursorResult].none
    defer: module_source.release()

    let module_doc = workspace.document_analysis_for(ws, module_path.as_str()) else:
        return Option[CursorResult].none
    var module_file = module_doc.ast_file
    var module_analysis = module_doc.analysis

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

    match resolve_name_in_analysis(module_file, ref_of(module_analysis), member, module_source.as_str(), module_name, 0, 0):
        Option.some as res:
            var stamped = res.value
            stamped.target_uri.release()
            stamped.target_uri = file_uri_for_path(module_path.as_str())
            return Option[CursorResult].some(value = stamped)
        Option.none:
            return Option[CursorResult].none


## Resolve an import alias to its module file (top of file, hover shows the
## module name).
function resolve_module_reference(ws: ref[workspace.Workspace], module_name: str, from_path: str) -> Option[CursorResult]:
    var module_path = resolve_module_source_path_for(ws, module_name, from_path) else:
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
public function resolve_module_source_path(ws: ref[workspace.Workspace], module_name: str) -> Option[string.String]:
    return resolve_module_source_path_for(ws, module_name, "")


## The module file resolved with `from_path`'s effective roots (its own package
## source root included): a project-local `import node` under `src/` must resolve
## for hover/definition, not only for the loader.  `""` falls back to the
## workspace roots.
public function resolve_module_source_path_for(ws: ref[workspace.Workspace], module_name: str, from_path: str) -> Option[string.String]:
    var roots = ws.effective_module_roots_for("")
    defer: roots.release()
    match resolver.resolve_module_path(module_name, roots.as_span(), resolver.Platform.linux):
        Result.success as path_payload:
            return Option[string.String].some(value = path_payload.value)
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
    if from_path.len == 0:
        return Option[string.String].none
    # The workspace roots miss a module under the requesting file's package
    # `source_root`; only that fallback pays the manifest walk.
    var scoped = ws.effective_module_roots_for(from_path)
    defer: scoped.release()
    match resolver.resolve_module_path(module_name, scoped.as_span(), resolver.Platform.linux):
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
function import_module_name_at(tokens: span[token_mod.Token], source: str, line: ptr_uint, character: ptr_uint) -> Option[string.String]:
    let target_line = line + 1
    let target_col = character + 1

    var line_tokens = vec.Vec[token_mod.Token].create()
    defer: line_tokens.release()
    var ti: ptr_uint = 0
    while ti < tokens.len:
        let tok = unsafe: read(tokens.data + ti)
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
    var content = ws.document_text(file_path.as_str()) else:
        return Option[CursorResult].none
    let import_tokens = ws.document_tokens(file_path.as_str(), content.text)
    match import_module_name_at(import_tokens, content.text, line, character):
        Option.some as module_name:
            defer: module_name.value.release()
            return resolve_module_reference(ws, module_name.value.as_str(), file_path.as_str())
        Option.none:
            return Option[CursorResult].none


## An absolute file:// URI for a workspace-relative or absolute path.
public function file_uri_for_path(path: str) -> string.String:
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


## The hover/definition result for a qualified enum or flags *member* access
## (`State.running`, `Mask.a`) — the host's `resolve_enum_member_hover_info`
## and `enum_member_definition_location`: `member: <type>` plus the member's
## explicit value rendered the formatter's way (`= 1`, `= 1 << 0`; an implicit
## member carries no value — the host's `enum_member_value_text` returns nil for
## it), located at the member's own declaration.  The type is looked up in the
## current file first, then across the imported modules (the host resolves the
## type's declaring module through its import bindings).
function resolve_enum_member(
    ws: ref[workspace.Workspace],
    file: ast.SourceFile,
    type_name: str,
    member_name: str,
    analysis: ref[analyzer.Analysis],
    from_path: str,
) -> Option[CursorResult]:
    match enum_member_result_in_file(file, type_name, member_name):
        Option.some as hit:
            return Option[CursorResult].some(value = hit.value)
        Option.none:
            pass
    return imported_enum_member_result(ws, analysis, type_name, member_name, from_path)


## The enum or flags declaration `type_name` in `file` and its member
## `member_name`, or none when this file declares no such type/member.
function enum_member_result_in_file(file: ast.SourceFile, type_name: str, member_name: str) -> Option[CursorResult]:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_enum as en:
                if en.name.equal(type_name):
                    return member_result_in_members(file, en.name, en.enum_members, member_name)
            ast.Decl.decl_flags as fl:
                if fl.name.equal(type_name):
                    return member_result_in_members(file, fl.name, fl.flags_members, member_name)
            _:
                pass
        di += 1
    return Option[CursorResult].none


## `member: Type[ = value]` for `member_name` among one enum/flags declaration's
## members, located at the member's own declaration.
function member_result_in_members(
    file: ast.SourceFile,
    type_name: str,
    members: span[ast.EnumMember],
    member_name: str,
) -> Option[CursorResult]:
    var mi: ptr_uint = 0
    while mi < members.len:
        let member = unsafe: read(members.data + mi)
        if member.name.equal(member_name):
            var hover = string.String.create()
            hover.append(member.name)
            hover.append(": ")
            hover.append(type_name)
            # Only an explicit value renders: the parser synthesizes implicit
            # values for auto-increment, and the host prints nothing for those.
            if member.value_explicit:
                let value_expr = member.value
                if value_expr != null:
                    hover.append(" = ")
                    hover.append(ast_formatter.render_expression_text(file, unsafe: read(value_expr)))
            return Option[CursorResult].some(value = CursorResult(
                line = member.line,
                column = if member.column > 0: member.column - 1 else: 0z,
                name_len = member.name.len,
                hover_text = hover,
                docs = string.String.create(),
                target_uri = string.String.create(),
                from_modules = string.String.create()
            ))
        mi += 1
    return Option[CursorResult].none


## The imported-type fallback: the first imported module whose own AST declares
## the enum or flags type with that member (the host resolves the type's owning
## module; the LSP's analysis keeps only the imported module names).  The
## module AST comes from the workspace analysis cache, so the scan costs no
## reparse.
##
## The result carries the member text but **no location**: the host's
## `type_name_member_access?` classifier does not fire for an
## `alias.Enum.member` receiver, so its hover has no `Defined at` line and its
## definition answer is the generic fallback — the self matches that (an
## improvement pointing at the imported declaration would be a documented
## difference; see the plan's Track 7 residue).
function imported_enum_member_result(
    ws: ref[workspace.Workspace],
    analysis: ref[analyzer.Analysis],
    type_name: str,
    member_name: str,
    from_path: str,
) -> Option[CursorResult]:
    var names = unsafe: read(ref_of(analysis.imports)).values()
    while true:
        let name_ptr = names.next() else:
            return Option[CursorResult].none
        let module_name = unsafe: read(name_ptr)
        var module_path = resolve_module_source_path_for(ws, module_name, from_path) else:
            continue
        defer: module_path.release()
        let entry = workspace.analysis_entry_for(ws, module_path.as_str()) else:
            continue
        let module_file = unsafe: read(entry).analysis.source_file
        match enum_member_result_in_file(module_file, type_name, member_name):
            Option.some as hit:
                var located = hit.value
                located.line = 0
                located.column = 0
                # The host qualifies the member's type in the signature and
                # shortens it into `*From <module>*`, so the owning module is
                # reported even though the location itself is dropped.
                located.from_modules.release()
                located.from_modules = string.String.from_str(module_name)
                return Option[CursorResult].some(value = located)
            Option.none:
                pass
    return Option[CursorResult].none


## The resolved target of a type-name receiver used as `Type.member`: its
## underlying enum/flags name, the module that declares it ("" for a local
## type), the module that declared the alias ("" when unqualified), and the
## alias module's AST.
struct AliasedEnumTarget:
    type_name: str
    owner_module: str
    alias_module: str
    module_file: ast.SourceFile


## Resolve `receiver.name` through the alias module's analysis to its
## underlying type.  The alias module's analysis comes from the requesting
## document's loaded program when available, so a repeated hover costs no
## re-analysis.
function aliased_enum_target(
    ws: ref[workspace.Workspace],
    file: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    program: Option[loader.Program],
    receiver: cursor.TypeReceiver,
    from_path: str,
) -> Option[AliasedEnumTarget]:
    if receiver.module_alias.len > 0:
        let module_ptr = unsafe: read(analysis).imports.get(receiver.module_alias) else:
            return Option[AliasedEnumTarget].none
        let alias_module = unsafe: read(module_ptr)
        match module_analysis_from_program(program, alias_module):
            Option.some as analysis_ptr:
                let alias_analysis = unsafe: read(analysis_ptr.value)
                return aliased_target_in_analysis(alias_analysis, alias_module, receiver.name)
            Option.none:
                let alias_entry = module_analysis_entry_for_name(ws, alias_module, from_path) else:
                    return Option[AliasedEnumTarget].none
                return aliased_target_in_analysis(unsafe: read(alias_entry).analysis, alias_module, receiver.name)
    let ty_ptr = unsafe: read(analysis).types.get(receiver.name) else:
        return Option[AliasedEnumTarget].none
    return aliased_target_from_type(file, "", unsafe: read(ty_ptr))


function aliased_target_in_analysis(alias_analysis: analyzer.Analysis, alias_module: str, name: str) -> Option[AliasedEnumTarget]:
    let ty_ptr = alias_analysis.types.get(name) else:
        return Option[AliasedEnumTarget].none
    return aliased_target_from_type(alias_analysis.source_file, alias_module, unsafe: read(ty_ptr))


function aliased_target_from_type(file: ast.SourceFile, alias_module: str, ty: types.Type) -> Option[AliasedEnumTarget]:
    let type_name = type_to_key_name(ty)
    if type_name.len == 0:
        return Option[AliasedEnumTarget].none
    return Option[AliasedEnumTarget].some(value = AliasedEnumTarget(
        type_name = type_name,
        owner_module = types.nominal_module(ty),
        alias_module = alias_module,
        module_file = file,
    ))


## `alias.Type.member` where `Type` is a type alias for an enum/flags
## (`type BodyType = c.b3BodyType`): resolve the alias to its underlying type
## and report the member from the declaring module's AST.  This also covers a
## local alias to an imported enum.  The location is dropped for an imported
## declaration, matching the direct `alias.Enum.member` behavior.
function resolve_aliased_enum_member(
    ws: ref[workspace.Workspace],
    file: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    program: Option[loader.Program],
    receiver: cursor.TypeReceiver,
    member_name: str,
    from_path: str,
) -> Option[CursorResult]:
    let target = aliased_enum_target(ws, file, analysis, program, receiver, from_path) else:
        return Option[CursorResult].none
    if target.owner_module.len == 0 or target.owner_module.equal(target.alias_module):
        return enum_member_result_in_file(target.module_file, target.type_name, member_name)
    match module_ast_from_program(program, target.owner_module):
        Option.some as owner_file:
            return owned_enum_member_result(owner_file.value, target.type_name, member_name, target.owner_module)
        Option.none:
            pass
    let owner_entry = module_analysis_entry_for_name(ws, target.owner_module, from_path) else:
        return Option[CursorResult].none
    return owned_enum_member_result(unsafe: read(owner_entry).analysis.source_file, target.type_name, member_name, target.owner_module)


function owned_enum_member_result(
    file: ast.SourceFile,
    type_name: str,
    member_name: str,
    owner_module: str,
) -> Option[CursorResult]:
    match enum_member_result_in_file(file, type_name, member_name):
        Option.some as hit:
            var located = hit.value
            located.line = 0
            located.column = 0
            located.from_modules.release()
            located.from_modules = string.String.from_str(owner_module)
            return Option[CursorResult].some(value = located)
        Option.none:
            return Option[CursorResult].none


## The workspace analysis cache entry for `module_name`, loading the module on
## first use.  The caller releases the resolved path only; the entry is owned by
## the workspace cache.
function module_analysis_entry_for_name(
    ws: ref[workspace.Workspace],
    module_name: str,
    from_path: str,
) -> Option[ptr[workspace.AnalysisCacheEntry]]:
    var module_path = resolve_module_source_path_for(ws, module_name, from_path) else:
        return Option[ptr[workspace.AnalysisCacheEntry]].none
    defer: module_path.release()
    return workspace.analysis_entry_for(ws, module_path.as_str())


## A declaration whose own name token the cursor is on: its 1-based line and the
## `function` prefix its kind renders.
struct MethodDeclarationAt:
    line: ptr_uint
    prefix: str


## The declaration whose name token sits at 1-based (`line`, `column`) — the
## host's `method_binding_at_token`, which matches the binding's AST against the
## cursor: an extending block's method first (`facts.methods`), then an
## interface's (`facts.interfaces`).  None when the cursor is not on a method
## declaration in this file.
function method_declaration_at(
    file: ast.SourceFile,
    name: str,
    line: ptr_uint,
    column: ptr_uint,
) -> Option[MethodDeclarationAt]:
    if line == 0:
        return Option[MethodDeclarationAt].none

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
                    if mfn.name == name and mfn.line == line and mfn.column == column:
                        return Option[MethodDeclarationAt].some(value = MethodDeclarationAt(
                            line = mfn.line,
                            prefix = method_kind_prefix(mfn.method_kind),
                        ))
                    mi += 1
            _:
                pass
        di += 1

    di = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_interface as ifc:
                var mi: ptr_uint = 0
                while mi < ifc.interface_methods.len:
                    var mfn: ast.InterfaceMethod
                    unsafe:
                        mfn = read(ifc.interface_methods.data + mi)
                    if mfn.name == name and mfn.line == line and mfn.column == column:
                        return Option[MethodDeclarationAt].some(value = MethodDeclarationAt(
                            line = mfn.line,
                            prefix = method_kind_prefix(mfn.method_kind),
                        ))
                    mi += 1
            _:
                pass
        di += 1

    return Option[MethodDeclarationAt].none


## The host's `method_signature` keyword for a method kind.
function method_kind_prefix(kind: ast.MethodKind) -> str:
    match kind:
        ast.MethodKind.mk_static:
            return "static function"
        ast.MethodKind.mk_editable:
            return "editable function"
        _:
            return "function"


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
    # The cursor's 1-based position when it is inside this file, else 0: a
    # method's own declaration token answers that declaration's line (the
    # host's `method_binding_at_token` matches the binding's AST against it).
    cursor_line: ptr_uint,
    cursor_column: ptr_uint,
) -> Option[CursorResult]:
    match function_name_hover(file, analysis, name, source, current_module):
        Option.some as found:
            return Option[CursorResult].some(value = found.value)
        Option.none:
            pass
    match method_name_hover(file, analysis, name, source, current_module, cursor_line, cursor_column):
        Option.some as found:
            return Option[CursorResult].some(value = found.value)
        Option.none:
            pass
    match value_name_hover(file, analysis, name, source, current_module):
        Option.some as found:
            return Option[CursorResult].some(value = found.value)
        Option.none:
            pass
    match interface_name_hover(file, analysis, name, source):
        Option.some as found:
            return Option[CursorResult].some(value = found.value)
        Option.none:
            pass
    match type_name_hover(file, analysis, name, source, current_module):
        Option.some as found:
            return Option[CursorResult].some(value = found.value)
        Option.none:
            pass

    unsafe:
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


function function_name_hover(
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
    return Option[CursorResult].none


function method_name_hover(
    file: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    name: str,
    source: str,
    current_module: str,
    cursor_line: ptr_uint,
    cursor_column: ptr_uint,
) -> Option[CursorResult]:
    unsafe:
        # Extending-block or interface method: search method_keys for "*.name".
        var method_entries = read(analysis).method_keys.entries()
        var m_next = method_entries.next()
        while m_next:
            let m_entry = method_entries.current()
            let method_key = unsafe: read(m_entry.key)
            if method_key.ends_with(name) and method_key.len > name.len:
                let sig_p = read(analysis).method_sigs.get(method_key)
                if sig_p != null:
                    # A cursor *on* a method's declaration answers that
                    # declaration: the host's `method_binding_at_token` matches
                    # the binding's AST line/column against the token, so an
                    # interface method's own token reports the interface's line
                    # even when an extending block implements it.
                    var matched_decl = method_declaration_at(file, name, cursor_line, cursor_column)
                    var mline: ptr_uint = 0
                    var prefix_text: str = ""
                    match matched_decl:
                        Option.some as matched:
                            mline = matched.value.line
                            prefix_text = matched.value.prefix
                        Option.none:
                            mline = find_method_line(file, name)
                    if mline > 0:
                        var m_sig = read(sig_p)
                        var full = string.String.create()
                        if prefix_text.len > 0:
                            full.append(prefix_text)
                        else:
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
                        # The host's `method_signature` always prints the return
                        # type, `-> void` for a method whose declaration omits it.
                        full.append(" -> ")
                        var return_text = type_render.qualified_name(m_sig.return_type, current_module)
                        full.append(return_text.as_str())
                        return_text.release()
                        let method_result = make_shortened_result(mline, name, source, full.as_str())
                        full.release()
                        return Option[CursorResult].some(value = method_result)
            m_next = method_entries.next()
    return Option[CursorResult].none


function value_name_hover(
    file: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    name: str,
    source: str,
    current_module: str,
) -> Option[CursorResult]:
    unsafe:
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
    return Option[CursorResult].none


function interface_name_hover(
    file: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    name: str,
    source: str,
) -> Option[CursorResult]:
    unsafe:
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
    return Option[CursorResult].none


function type_name_hover(
    file: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    name: str,
    source: str,
    current_module: str,
) -> Option[CursorResult]:
    unsafe:
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
                # A registered *builtin* (`vec3`) carries its own documentation;
                # the host appends its builtin docs to the signature.
                var with_docs = result
                if with_docs.docs.len() == 0:
                    match hover_docs.builtin_type(name):
                        Option.some as builtin_doc:
                            with_docs.docs = string.String.from_str(builtin_doc.value.docs)
                        Option.none:
                            pass
                return Option[CursorResult].some(value = with_docs)
            # A registered builtin without a declaration in this file (`str`,
            # `int`): its builtin docs, and no location.  A prelude type
            # (`Result`, `Option`) still renders the host's
            # `type Result = Result` plus `*From std.result*`, since the host
            # installs it from std.result / std.option.
            match hover_docs.builtin_type(name):
                Option.some as builtin_type_doc:
                    if type_render.prelude_type_module(name).len > 0:
                        var prelude_ty = types.Type.ty_error
                        let prelude_ty_ptr = unsafe: read(analysis).types.get(name)
                        if prelude_ty_ptr != null:
                            prelude_ty = unsafe: read(ptr[types.Type]<-prelude_ty_ptr)
                        var prelude_hover = type_hover_signature(name, prelude_ty, current_module)
                        let prelude_shortened = type_render.shorten_signature(prelude_hover.as_str())
                        var prelude_result = quick_hover_doc(builtin_type_doc.value)
                        prelude_result.hover_text.release()
                        prelude_result.hover_text = prelude_shortened.text
                        prelude_result.from_modules.release()
                        prelude_result.from_modules = prelude_shortened.modules
                        prelude_hover.release()
                        return Option[CursorResult].some(value = prelude_result)
                    return Option[CursorResult].some(value = quick_hover_doc(builtin_type_doc.value))
                Option.none:
                    pass
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
## `async function name(a: int, b: str) -> int`.  The host's `method_signature`
## prints the declared parameters with no variadic marker and always the return
## type (`-> void` when the declaration omits it).
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
    sig_text.append(")")
    sig_text.append(" -> ")
    var return_text = type_render.qualified_name(sig.return_type, current_module)
    sig_text.append(return_text.as_str())
    return_text.release()
    return sig_text


## The host's `type_hover_signature`: `type <name>` for a type that renders as
## its own bare name (a built-in or a primitive), else
## `type <name> = <module-qualified type>` — the caller shortens it, so a type
## with an owning module also reports the host's `*From <module>*` line.  The
## prelude types are installed from std.option / std.result even though this
## file registers them with no module, so they render `type Result = Result`
## with `*From std.result*`.
function type_hover_signature(name: str, ty: types.Type, current_module: str) -> string.String:
    var hover = string.String.create()
    hover.append("type ")
    hover.append(name)
    if types.nominal_module(ty).len > 0 or type_render.prelude_type_module(name).len > 0:
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
    let alias = find_declaration_line(file, name, "alias")
    if alias > 0:
        return alias
    # A type whose only declaration here is the `extending X:` block that gives
    # it methods (`extending vec3:` for a native vector type) — the host's token
    # index matches any declaration keyword, so it finds that too.
    return find_extending_line(file, name)


## The line of the `extending <name>:` block, 0 when there is none.
function find_extending_line(file: ast.SourceFile, name: str) -> ptr_uint:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_extending_block as ext:
                if unsafe: read(ext.type_name).name.parts.len > 0:
                    let parts = unsafe: read(ext.type_name).name.parts
                    let last = unsafe: read(parts.data + (parts.len - 1))
                    if last.equal(name):
                        return ext.line
            _:
                pass
        di += 1
    return 0


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


## The declaration line of `type_name`'s method `name`: the `extending` blocks
## whose target names the type come first (`mat4.identity` is std.linear_algebra's
## third `identity`), then any block declaring the name.
function find_method_line_in_type(file: ast.SourceFile, type_name: str, name: str) -> ptr_uint:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_extending_block as ext:
                var base: str = ""
                unsafe:
                    base = analyzer.qname_to_str(read(ext.type_name).name)
                if method_key_names_type(base, type_name):
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
    return find_method_line(file, name)


## The `(module, type)` an imported type reference names.  The analyzer produces
## two shapes for one: `ty_imported` for a specialized or imported nominal
## (`node.Node`, `Vec[int]`) and a `ty_named` whose `module_name` is set for a
## plain imported name.
public struct ImportedTypeRef:
    module_name: str
    name: str


public function imported_type_reference(ty: types.Type) -> Option[ImportedTypeRef]:
    match ty:
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            if im_bp.module_name.len > 0:
                return Option[ImportedTypeRef].some(value = ImportedTypeRef(module_name = im_bp.module_name, name = im_bp.name))
            return Option[ImportedTypeRef].none
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            if n_np.module_name.len > 0:
                return Option[ImportedTypeRef].some(value = ImportedTypeRef(module_name = n_np.module_name, name = n_np.name))
            return Option[ImportedTypeRef].none
        _:
            return Option[ImportedTypeRef].none


## The host's `project_receiver_type_for_completion`: a `ref[T]`/`ptr[T]`/
## `const_ptr[T]` receiver projects to `T` (a `ref`'s lifetime argument is
## skipped).
public function project_value_receiver_type(ty: types.Type) -> types.Type:
    match ty:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            if g_bp.name.equal("ref") and g_bp.args.len >= 1:
                return types.pointer_element(ty)
            if (g_bp.name.equal("ptr") or g_bp.name.equal("const_ptr")) and g_bp.args.len == 1:
                return unsafe: read(g_bp.args.data + 0)
            return ty
        _:
            return ty


## Extract the key name from a Type (e.g. Vec[int] → "Vec").
public function type_to_key_name(t: types.Type) -> str:
    match t:
        types.Type.ty_generic as g:
            let g_bp = unsafe: read(g.payload)
            return g_bp.name
        types.Type.ty_named as n:
            let n_np = unsafe: read(n.payload)
            return n_np.name
        types.Type.ty_imported as im:
            let im_bp = unsafe: read(im.payload)
            return im_bp.name
        types.Type.ty_opaque as op:
            let op_bp = unsafe: read(op.payload)
            return op_bp.name
        types.Type.ty_primitive as p:
            return p.name
        types.Type.ty_str:
            return "str"
        _:
            return ""


## The type of `field_name` on `ty` — a struct field (local, nested or
## imported) or a builtin vector/matrix/quaternion field, the host's
## `project_field_receiver_type_for_completion(...).field(name)`.
public function field_of_type(analysis: ref[analyzer.Analysis], ty: types.Type, field_name: str) -> Option[types.Type]:
    # A match-arm payload binding's fields are the arm's synthesized payload
    # fields (`c.name` in `ast.Decl.decl_const as c`), with no struct to scan.
    match ty:
        types.Type.ty_variant_arm_payload as arm:
            let payload_fields = unsafe: read(arm.payload).fields
            var pi: ptr_uint = 0
            while pi < payload_fields.len:
                let pf = unsafe: read(payload_fields.data + pi)
                if pf.name.equal(field_name):
                    return Option[types.Type].some(value = pf.ty)
                pi += 1
            return Option[types.Type].none
        _:
            pass
    let field_ty = project_value_receiver_type(types.unwrap_nullable(ty))
    let type_name = type_to_key_name(field_ty)
    let fields_ptr = unsafe: read(analysis).structs.get(type_name)
    if fields_ptr != null:
        let fields = unsafe: read(fields_ptr)
        var i: ptr_uint = 0
        while i < fields.len:
            let f = unsafe: read(fields.data + i)
            if f.name.equal(field_name):
                return Option[types.Type].some(value = f.ty)
            i += 1
        return Option[types.Type].none
    match imported_type_reference(field_ty):
        Option.some as reference:
            var key = string.String.create()
            defer: key.release()
            key.append(reference.value.module_name)
            key.append(".")
            key.append(reference.value.name)
            let member_ptr = unsafe: read(analysis).imported_type_members.get(key.as_str())
            if member_ptr != null:
                let members = unsafe: read(member_ptr)
                var mi: ptr_uint = 0
                while mi < members.fields.len:
                    let f = unsafe: read(members.fields.data + mi)
                    if f.name.equal(field_name):
                        return Option[types.Type].some(value = f.ty)
                    mi += 1
            return Option[types.Type].none
        Option.none:
            pass
    match builtin_field_type_name(type_name, field_name):
        Option.some as type_text:
            return Option[types.Type].some(value = types.primitive(type_text.value))
        Option.none:
            return Option[types.Type].none


## The declared type of a builtin vector/matrix/quaternion field, as the hover
## renders it: `vec3.x` → `float`, `mat4.col0` → `vec4`, `quat.w` → `float`
## (the host's `Types::Vector`/`Matrix`/`Quaternion` field tables).  Completion's
## field-chain walk reads the same table.
public function builtin_field_type_name(type_name: str, field_name: str) -> Option[str]:
    # The host's `Types::StringView` fields (`str` is a pointer + length view).
    if type_name.equal("str"):
        if field_name.equal("data"):
            return Option[str].some(value = "ptr[char]")
        if field_name.equal("len"):
            return Option[str].some(value = "ptr_uint")
        return Option[str].none
    if type_name.equal("vec2"):
        return builtin_vector_field(field_name, 2, "float")
    if type_name.equal("vec3"):
        return builtin_vector_field(field_name, 3, "float")
    if type_name.equal("vec4"):
        return builtin_vector_field(field_name, 4, "float")
    if type_name.equal("ivec2"):
        return builtin_vector_field(field_name, 2, "int")
    if type_name.equal("ivec3"):
        return builtin_vector_field(field_name, 3, "int")
    if type_name.equal("ivec4"):
        return builtin_vector_field(field_name, 4, "int")
    if type_name.equal("quat"):
        return builtin_vector_field(field_name, 4, "float")
    if type_name.equal("mat3"):
        return builtin_matrix_field(field_name, 3)
    if type_name.equal("mat4"):
        return builtin_matrix_field(field_name, 4)
    return Option[str].none


## `x`/`y`/`z`/`w`, the first `width` of them (the host's
## `Types::Vector::FIELD_NAMES.first(width)`).
function builtin_vector_field(field_name: str, width: long, element_name: str) -> Option[str]:
    if field_name.equal("x") or field_name.equal("y"):
        return Option[str].some(value = element_name)
    if width >= 3 and field_name.equal("z"):
        return Option[str].some(value = element_name)
    if width >= 4 and field_name.equal("w"):
        return Option[str].some(value = element_name)
    return Option[str].none


## `col0`…`col<dim-1>`, each a `vec3`/`vec4` column.
function builtin_matrix_field(field_name: str, dim: long) -> Option[str]:
    let column_type = if dim == 3: "vec3" else: "vec4"
    if field_name.equal("col0") or field_name.equal("col1") or field_name.equal("col2"):
        return Option[str].some(value = column_type)
    if dim >= 4 and field_name.equal("col3"):
        return Option[str].some(value = column_type)
    return Option[str].none


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
function find_token_str(tokens: span[token_mod.Token], source: str, line: ptr_uint, character: ptr_uint) -> Option[string.String]:
    # Inside an f-string interpolation the lexer's token is the whole string;
    # the host's `token_context_at` re-lexes the expression and answers its
    # inner token instead, so an identifier there resolves normally.
    match cursor.interpolation_identifier_at_in(tokens, source, line, character):
        Option.some as inner:
            return Option[string.String].some(value = string.String.from_str(inner.value.text))
        Option.none:
            pass

    let target_line = line + 1
    var ti: ptr_uint = 0
    while ti < tokens.len:
        let t = unsafe: read(tokens.data + ti)
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
## The host's `builtin_hover_info`, in its order: a *value* specialization
## (`zero[T]`, `default[T]`, `reinterpret[T]`), an associated-hook call
## specialization (`hash[T](…)`, `equal[T](…)`, `order[T](…)`), a *type
## constructor* (`ptr[T]`, `array[T, N]`, `Option[T]`, …) and nothing else —
## each arm needs the `[…]` group that follows the name.
function builtin_specialization_hover(tokens: vec.Vec[token_mod.Token], source: str, ti: ptr_uint, lexeme: str) -> Option[hover_docs.HoverDoc]:
    if lexeme.equal("zero") or lexeme.equal("default") or lexeme.equal("reinterpret"):
        return builtin_value_specialization_hover(tokens, source, ti, lexeme)
    if lexeme.equal("hash") or lexeme.equal("equal") or lexeme.equal("order"):
        return builtin_hook_specialization_hover(tokens, source, ti, lexeme)
    return builtin_type_constructor_hover(tokens, source, ti, lexeme)


## `zero[T] -> T` / `default[T] -> T` / `reinterpret[T](value) -> T`.
function builtin_value_specialization_hover(tokens: vec.Vec[token_mod.Token], source: str, ti: ptr_uint, lexeme: str) -> Option[hover_docs.HoverDoc]:
    if is_member_access_token(tokens.as_span(), ti):
        return Option[hover_docs.HoverDoc].none
    let lb = next_code_index(tokens.as_span(), ti + 1) else:
        return Option[hover_docs.HoverDoc].none
    if not token_kind_at(tokens.as_span(), lb, tk.TokenKind.lbracket):
        return Option[hover_docs.HoverDoc].none
    let rb = matching_bracket_index(tokens.as_span(), lb) else:
        return Option[hover_docs.HoverDoc].none
    var target = render_builtin_specialization(tokens.as_span(), source, lb + 1, rb - 1)
    defer: target.release()
    if target.len() == 0:
        return Option[hover_docs.HoverDoc].none

    var signature = string.String.create()
    defer: signature.release()
    signature.append("builtin ")
    var whole = render_builtin_specialization(tokens.as_span(), source, ti, rb)
    defer: whole.release()
    signature.append(whole.as_str())
    if lexeme.equal("reinterpret"):
        signature.append("(value) -> ")
    else:
        signature.append(" -> ")
    signature.append(target.as_str())
    return Option[hover_docs.HoverDoc].some(value = hover_docs.HoverDoc(signature = string.String.from_str(signature.as_str()).as_str(), docs = specialization_docs(lexeme)))


## `hash[T](value) -> uint` / `equal[T](left, right) -> bool` /
## `order[T](left, right) -> int` — the host's associated-hook specializations.
function builtin_hook_specialization_hover(tokens: vec.Vec[token_mod.Token], source: str, ti: ptr_uint, lexeme: str) -> Option[hover_docs.HoverDoc]:
    if is_member_access_token(tokens.as_span(), ti):
        return Option[hover_docs.HoverDoc].none
    let lb = next_code_index(tokens.as_span(), ti + 1) else:
        return Option[hover_docs.HoverDoc].none
    if not token_kind_at(tokens.as_span(), lb, tk.TokenKind.lbracket):
        return Option[hover_docs.HoverDoc].none
    let rb = matching_bracket_index(tokens.as_span(), lb) else:
        return Option[hover_docs.HoverDoc].none
    let after = next_code_index(tokens.as_span(), rb + 1) else:
        return Option[hover_docs.HoverDoc].none
    if not token_kind_at(tokens.as_span(), after, tk.TokenKind.lparen):
        return Option[hover_docs.HoverDoc].none

    var signature = string.String.create()
    defer: signature.release()
    signature.append("builtin ")
    var whole = render_builtin_specialization(tokens.as_span(), source, ti, rb)
    defer: whole.release()
    signature.append(whole.as_str())
    if lexeme.equal("hash"):
        signature.append("(value) -> uint")
    else if lexeme.equal("equal"):
        signature.append("(left, right) -> bool")
    else:
        signature.append("(left, right) -> int")
    return Option[hover_docs.HoverDoc].some(value = hover_docs.HoverDoc(signature = string.String.from_str(signature.as_str()).as_str(), docs = specialization_docs(lexeme)))


## `builtin type ptr[int]` and, at a construction call, the host's per-name
## callable shapes (`builtin ptr[int](...) -> ptr[int]`, `builtin
## Option[int](some: value = ...) / Option[int](none:)`, …).
function builtin_type_constructor_hover(tokens: vec.Vec[token_mod.Token], source: str, ti: ptr_uint, lexeme: str) -> Option[hover_docs.HoverDoc]:
    if not is_builtin_type_constructor_name(lexeme):
        return Option[hover_docs.HoverDoc].none
    let lb = next_code_index(tokens.as_span(), ti + 1) else:
        return Option[hover_docs.HoverDoc].none
    if not token_kind_at(tokens.as_span(), lb, tk.TokenKind.lbracket):
        return Option[hover_docs.HoverDoc].none
    let rb = matching_bracket_index(tokens.as_span(), lb) else:
        return Option[hover_docs.HoverDoc].none
    let after = next_code_index(tokens.as_span(), rb + 1)

    var signature = string.String.create()
    defer: signature.release()
    var whole = render_builtin_specialization(tokens.as_span(), source, ti, rb)
    defer: whole.release()
    var called = false
    match after:
        Option.some as after_index:
            called = token_kind_at(tokens.as_span(), after_index.value, tk.TokenKind.lparen)
        Option.none:
            pass
    if not called:
        signature.append("builtin type ")
        signature.append(whole.as_str())
        return Option[hover_docs.HoverDoc].some(value = hover_docs.HoverDoc(signature = string.String.from_str(signature.as_str()).as_str(), docs = specialization_docs(lexeme)))
    if lexeme.equal("Option"):
        signature.append("builtin ")
        signature.append(whole.as_str())
        signature.append("(some: value = ...) / ")
        signature.append(whole.as_str())
        signature.append("(none:)")
    else if lexeme.equal("Result"):
        signature.append("builtin ")
        signature.append(whole.as_str())
        signature.append("(success: value = ...) / ")
        signature.append(whole.as_str())
        signature.append("(failure: error = ...)")
    else if lexeme.equal("span"):
        signature.append("builtin ")
        signature.append(whole.as_str())
        signature.append("(data = ..., len = ...) -> ")
        signature.append(whole.as_str())
    else:
        signature.append("builtin ")
        signature.append(whole.as_str())
        signature.append("(...) -> ")
        signature.append(whole.as_str())
    return Option[hover_docs.HoverDoc].some(value = hover_docs.HoverDoc(signature = string.String.from_str(signature.as_str()).as_str(), docs = specialization_docs(lexeme)))


## The host's docs for a builtin specialization (`builtin_hover_info`'s
## per-name `docs` cases).
function specialization_docs(name: str) -> str:
    if name.equal("array"):
        return "`array[T, N]` is the built-in fixed-length array type."
    if name.equal("span"):
        return "`span[T]` is the built-in non-owning contiguous view type."
    if name.equal("SoA"):
        return "`SoA[T, N]` is the built-in Struct-of-Arrays type. Each struct field is stored in a separate contiguous array of `N` elements, improving SIMD/cache behavior for parallel field access."
    if name.equal("simd"):
        return "`simd[T, N]` is the built-in SIMD vector type. Fixed-width vector of `N` numeric lanes. Supports component-wise arithmetic, lane access via `[i]`, and explicit aligned/unaligned load/store."
    if name.equal("Option"):
        return "`Option[T]` is the built-in optional value type with `some(value = ...)` and `none` arms."
    if name.equal("Result"):
        return "`Result[T, E]` is the built-in success/failure type with `success(value = ...)` and `failure(error = ...)` arms."
    if name.equal("str_buffer"):
        return "`str_buffer[N]` is a fixed-capacity mutable UTF-8 text buffer. Methods: `assign`, `append`, `assign_format`, `append_format`, `clear`, `len`, `as_str`, `as_cstr`."
    if name.equal("ref"):
        return "`ref[T]` is a non-null borrow reference. Auto-dereferences for member access and method calls. Cannot be stored in module-level variables, constants, or nested containers."
    if name.equal("ptr"):
        return "`ptr[T]` is a raw mutable pointer. Indexing, dereference, and arithmetic require `unsafe`. Nullable via `ptr[T]?`."
    if name.equal("const_ptr"):
        return "`const_ptr[T]` is a read-only pointer. Does not require `unsafe` for dereference."
    if name.equal("own"):
        return "`own[T]` is an owning heap pointer. Auto-dereferences like `ref`. Storable, returnable, and nullable. Allocated via `heap.must_alloc[T](count)`."
    if name.equal("Task"):
        return "`Task[T]` is an async task future. Returned by `async function`. Use `await` to unwrap, or `aio.wait`/`aio.run` to drive."
    if name.equal("atomic"):
        return "`atomic[T]` is an atomic value for lock-free concurrent access. `T` must be a primitive integer or `bool`. Methods: `load`, `store`, `add`, `sub`, `exchange`."
    if name.equal("zero"):
        return "`zero[T]` returns the raw zero-initialized value for `T`. It is a value form, not a callable."
    if name.equal("default"):
        return "`default[T]` returns the semantic default value for `T` and requires an accessible zero-argument associated function `T.default()` that returns `T`. It is a value form, not a callable."
    if name.equal("reinterpret"):
        return "`reinterpret[T](value)` bit-casts a value to `T`; it requires `unsafe` and compatible concrete sized types."
    if name.equal("hash"):
        return "`hash[T](value)` lowers to `T.hash(value: const_ptr[T]) -> uint` after borrowing safe lvalues or forwarding existing refs and pointers."
    if name.equal("equal"):
        return "`equal[T](left, right)` lowers to `T.equal(left: const_ptr[T], right: const_ptr[T]) -> bool` after borrowing safe lvalues or forwarding existing refs and pointers."
    if name.equal("order"):
        return "`order[T](left, right)` lowers to `T.order(left: const_ptr[T], right: const_ptr[T]) -> int` after borrowing safe lvalues or forwarding existing refs and pointers."
    return ""


## The host's `BUILTIN_TYPE_CONSTRUCTOR_NAMES`.
function is_builtin_type_constructor_name(name: str) -> bool:
    if name.equal("array") or name.equal("span") or name.equal("Option") or name.equal("Result"):
        return true
    if name.equal("SoA") or name.equal("str_buffer") or name.equal("ref") or name.equal("ptr"):
        return true
    if name.equal("const_ptr") or name.equal("own") or name.equal("Task") or name.equal("atomic"):
        return true
    return name.equal("simd")


## The host's `render_builtin_specialization`: the lexemes joined, with a comma
## rendered as `, `.
function render_builtin_specialization(tokens: span[token_mod.Token], source: str, from_index: ptr_uint, to_index: ptr_uint) -> string.String:
    var text = string.String.create()
    var i = from_index
    while i <= to_index and i < tokens.len:
        var t: token_mod.Token
        unsafe:
            t = read(tokens.data + i)
        if t.kind == tk.TokenKind.comma:
            text.append(", ")
        else:
            let lexeme = unsafe: token_mod.token_lexeme(t, source)
            text.append(lexeme)
        i += 1
    return text


## The index of the token that closes the `[` at `lb`, counting nesting.
function matching_bracket_index(tokens: span[token_mod.Token], lb: ptr_uint) -> Option[ptr_uint]:
    var depth: int = 0
    var i = lb
    while i < tokens.len:
        var t: token_mod.Token
        unsafe:
            t = read(tokens.data + i)
        if t.kind == tk.TokenKind.lbracket:
            depth += 1
        else if t.kind == tk.TokenKind.rbracket:
            depth -= 1
            if depth == 0:
                return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


## The next token index at or after `from` that is not a structural token.
function next_code_index(tokens: span[token_mod.Token], from: ptr_uint) -> Option[ptr_uint]:
    var i = from
    while i < tokens.len:
        var t: token_mod.Token
        unsafe:
            t = read(tokens.data + i)
        if not is_structural_token_kind(t.kind):
            return Option[ptr_uint].some(value = i)
        i += 1
    return Option[ptr_uint].none


function token_kind_at(tokens: span[token_mod.Token], index: ptr_uint, kind: tk.TokenKind) -> bool:
    if index >= tokens.len:
        return false
    return unsafe: read(tokens.data + index).kind == kind


## True when the token at `index` follows a `.` (the host's
## `builtin_in_member_access_context?`).
function is_member_access_token(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    var i = index
    while i > 0:
        i -= 1
        if i >= tokens.len:
            continue
        var t: token_mod.Token
        unsafe:
            t = read(tokens.data + i)
        if is_structural_token_kind(t.kind):
            continue
        return t.kind == tk.TokenKind.dot
    return false


## The hover for a field name in its own declaration — the host's
## `resolve_field_declaration_hover_info`: `field <name>: <resolved type>`, the
## *semantic* type of the field (module-qualified, then shortened), with the
## location the host's indentation-sensitive field-token scan reports.
function field_declaration_hover(
    ws: ref[workspace.Workspace],
    file_path: str,
    source: str,
    line: ptr_uint,
    character: ptr_uint,
) -> Option[CursorResult]:
    let doc = workspace.document_analysis_for(ws, file_path) else:
        return Option[CursorResult].none
    var ast_file = doc.ast_file

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
                        var analysis = doc.analysis
                        var module_roots = ws.effective_module_roots_for(file_path)
                        defer: module_roots.release()
                        var current_module = resolver.infer_module_name(file_path, module_roots.as_span())
                        defer: current_module.release()

                        var type_text = string.String.create()
                        var type_resolved = false
                        let entries_ptr = analysis.structs.get(s.name)
                        if entries_ptr != null:
                            let entries = unsafe: read(entries_ptr)
                            var ei: ptr_uint = 0
                            while ei < entries.len:
                                let entry = unsafe: read(entries.data + ei)
                                if entry.name.equal(f.name):
                                    var qualified = type_render.qualified_name(entry.ty, current_module.as_str())
                                    type_text.append(qualified.as_str())
                                    qualified.release()
                                    type_resolved = true
                                ei += 1
                        if not type_resolved:
                            let ty = f.field_type
                            if ty.name.parts.len > 0:
                                type_text.append(unsafe: read(ty.name.parts.data))
                            if ty.nullable:
                                type_text.append("?")

                        var signature = string.String.create()
                        signature.append("field ")
                        signature.append(f.name)
                        signature.append(": ")
                        signature.append(type_text.as_str())
                        type_text.release()
                        var shortened = type_render.shorten_signature(signature.as_str())
                        signature.release()

                        # The location is the field's declaration *token*: the
                        # host's scan finds none under a `public struct` header,
                        # so such a field's hover carries no `Defined at` line.
                        var decl_line: ptr_uint = 0
                        match find_field_token_in_type(source, s.name, f.name):
                            Option.some as ft:
                                decl_line = ft.value.line
                            Option.none:
                                pass

                        return Option[CursorResult].some(value = CursorResult(
                            line = decl_line,
                            column = 0,
                            name_len = f.name.len,
                            hover_text = shortened.text,
                            docs = string.String.create(),
                            target_uri = string.String.create(),
                            from_modules = shortened.modules
                        ))
                    fi += 1
            _:
                pass
        di += 1

    return Option[CursorResult].none


## The hover for a bare variant arm name (`Result.success(value = T)`): the
## first declared variant in the file that carries an arm of that name — the
## host's `find_variant_arm_in_types`, which walks the module's types in reverse
## declaration order — and then the prelude variants (`Option`, `Result`),
## whose arms the host installs from std.option / std.result.
function variant_arm_name_hover(ws: ref[workspace.Workspace], file: ast.SourceFile, name: str) -> Option[CursorResult]:
    match variant_arm_name_in_file(file, name):
        Option.some as declared:
            return Option[CursorResult].some(value = declared.value)
        Option.none:
            pass

    match variant_arm_from_module(ws, "std.result", name):
        Option.some as result_arm:
            return Option[CursorResult].some(value = result_arm.value)
        Option.none:
            pass
    return variant_arm_from_module(ws, "std.option", name)


## The arm hover for `name` in one prelude module's declaration, or none.
function variant_arm_from_module(ws: ref[workspace.Workspace], module_name: str, name: str) -> Option[CursorResult]:
    var module_path = resolve_module_source_path(ws, module_name) else:
        return Option[CursorResult].none
    defer: module_path.release()
    let module_doc = workspace.document_analysis_for(ws, module_path.as_str()) else:
        return Option[CursorResult].none
    return variant_arm_name_in_file(module_doc.ast_file, name)


## `Type.arm(field: T, …)` for the first declared variant in `file` with an arm
## of that name, or none.
function variant_arm_name_in_file(file: ast.SourceFile, name: str) -> Option[CursorResult]:
    var di: int = int<-file.declarations.len - 1
    while di >= 0:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + ptr_uint<-di)
        match decl:
            ast.Decl.decl_variant as v:
                var ai: ptr_uint = 0
                while ai < v.variant_arms.len:
                    let arm = unsafe: read(v.variant_arms.data + ai)
                    if arm.name.equal(name):
                        return Option[CursorResult].some(value = variant_arm_name_result(v.name, arm, name))
                    ai += 1
            _:
                pass
        di -= 1
    return Option[CursorResult].none


## The arm `arm_name` of `type_name` in an imported variant module — a
## self-better extension: the host resolves only a local `Type.arm`, while this
## reuses the current document's loaded program (no extra parse) to answer
## `ast.Decl.decl_const`.
function resolve_imported_variant_arm(
    ws: ref[workspace.Workspace],
    analysis: ref[analyzer.Analysis],
    receiver: cursor.TypeReceiver,
    arm_name: str,
    from_path: str,
    program: Option[loader.Program],
) -> Option[CursorResult]:
    var module_name: str = ""
    if receiver.module_alias.len > 0:
        let module_ptr = unsafe: read(analysis).imports.get(receiver.module_alias) else:
            return Option[CursorResult].none
        module_name = unsafe: read(module_ptr)
    else:
        let ty_ptr = unsafe: read(analysis).types.get(receiver.name) else:
            return Option[CursorResult].none
        match unsafe: read(ptr[types.Type]<-ty_ptr):
            types.Type.ty_named as n:
                let n_np = unsafe: read(n.payload)
                module_name = n_np.module_name
            types.Type.ty_imported as im:
                let im_bp = unsafe: read(im.payload)
                module_name = im_bp.module_name
            _:
                # A generic/primitive receiver (`Vec[T].create`, `mat4.identity`)
                # is a static method, not an imported variant arm.
                return Option[CursorResult].none
        if module_name.len == 0 or module_name.equal(unsafe: read(analysis).module_name):
            return Option[CursorResult].none
    match module_ast_from_program(program, module_name):
        Option.some as imported_file:
            return variant_arm_in_type_in_file(imported_file.value, receiver.name, arm_name)
        Option.none:
            pass
    # No loaded program for the requesting document (a single-file fallback):
    # pay one module load rather than dropping the answer.
    var module_path = resolve_module_source_path_for(ws, module_name, from_path) else:
        return Option[CursorResult].none
    defer: module_path.release()
    let module_doc = workspace.document_analysis_for(ws, module_path.as_str()) else:
        return Option[CursorResult].none
    return variant_arm_in_type_in_file(module_doc.ast_file, receiver.name, arm_name)


## The loaded analysis for `module_name` from the requesting document's program,
## or none when the program does not carry it (a single-file fallback).
function module_analysis_from_program(
    program: Option[loader.Program],
    module_name: str,
) -> Option[ptr[analyzer.Analysis]]:
    let loaded = program else:
        return Option[ptr[analyzer.Analysis]].none
    let analyses = loaded.analyses
    var i: ptr_uint = 0
    while i < analyses.len():
        let ap = analyses.get(i) else:
            break
        if unsafe: read(ap).module_name.equal(module_name):
            return Option[ptr[analyzer.Analysis]].some(value = ap)
        i += 1
    return Option[ptr[analyzer.Analysis]].none


## An imported module's AST from the requesting document's loaded program (the
## dependency closure the loader already built), or none when the document has
## no program entry.  The AST is a small value; the module's full analysis is
## not copied per hover.
function module_ast_from_program(
    program: Option[loader.Program],
    module_name: str,
) -> Option[ast.SourceFile]:
    let loaded = program else:
        return Option[ast.SourceFile].none
    let analyses = loaded.analyses
    var i: ptr_uint = 0
    while i < analyses.len():
        let ap = analyses.get(i) else:
            break
        if unsafe: read(ap).module_name.equal(module_name):
            return Option[ast.SourceFile].some(value = unsafe: read(ap).source_file)
        i += 1
    return Option[ast.SourceFile].none


## `Type.arm(field: T, …)` for `type_name`'s arm `arm_name` in `file`.
function variant_arm_in_type_in_file(file: ast.SourceFile, type_name: str, arm_name: str) -> Option[CursorResult]:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_variant as v:
                if v.name.equal(type_name):
                    var ai: ptr_uint = 0
                    while ai < v.variant_arms.len:
                        let arm = unsafe: read(v.variant_arms.data + ai)
                        if arm.name.equal(arm_name):
                            return Option[CursorResult].some(value = variant_arm_name_result(v.name, arm, arm_name))
                        ai += 1
            _:
                pass
        di += 1
    return Option[CursorResult].none


## The hover for a bare enum or flags *member* name — the host's
## `find_member_in_types`, which scans its types in reverse declaration order and
## renders `Type.member = value` for the first type that declares the member.
## The value is the member's declared expression folded to an integer, so an
## implicit member reports the value the parser synthesized for it
## (`Kind.c = 6` after `b = 5`).  No location: the host renders this arm from the
## type's member table, not from a token.
function bare_member_hover(file: ast.SourceFile, analysis: ref[analyzer.Analysis], name: str) -> Option[CursorResult]:
    var di: int = int<-file.declarations.len - 1
    while di >= 0:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + ptr_uint<-di)
        match decl:
            ast.Decl.decl_enum as en:
                match member_hover_in_members(en.name, en.enum_members, analysis, name):
                    Option.some as enum_hit:
                        return Option[CursorResult].some(value = enum_hit.value)
                    Option.none:
                        pass
            ast.Decl.decl_flags as fl:
                match member_hover_in_members(fl.name, fl.flags_members, analysis, name):
                    Option.some as flags_hit:
                        return Option[CursorResult].some(value = flags_hit.value)
                    Option.none:
                        pass
            _:
                pass
        di -= 1
    return Option[CursorResult].none


## `Type.member = value` for `name` among one enum/flags declaration's members.
function member_hover_in_members(
    type_name: str,
    members: span[ast.EnumMember],
    analysis: ref[analyzer.Analysis],
    name: str,
) -> Option[CursorResult]:
    var mi: ptr_uint = 0
    while mi < members.len:
        let member = unsafe: read(members.data + mi)
        if member.name.equal(name):
            var hover = string.String.create()
            hover.append(type_name)
            hover.append(".")
            hover.append(member.name)
            let value_expr = member.value
            if value_expr != null:
                match analyzer.const_eval_int(ref_of(analysis.const_values), unsafe: ptr[ast.Expr]<-value_expr):
                    Option.some as value:
                        var value_text = string.String.create()
                        value_text.append_format(f"#{value.value}")
                        defer: value_text.release()
                        hover.append(" = ")
                        hover.append(value_text.as_str())
                    Option.none:
                        pass
            return Option[CursorResult].some(value = CursorResult(
                line = 0,
                column = 0,
                name_len = member.name.len,
                hover_text = hover,
                docs = string.String.create(),
                target_uri = string.String.create(),
                from_modules = string.String.create()
            ))
        mi += 1
    return Option[CursorResult].none


## The `Type.arm(field: T, …)` hover payload (the host's
## `find_variant_arm_in_types` rendering: the fields in declaration order, no
## location).
function variant_arm_name_result(type_name: str, arm: ast.VariantArm, name: str) -> CursorResult:
    var hover = string.String.create()
    hover.append(type_name)
    hover.append(".")
    hover.append(arm.name)
    if arm.arm_fields.len > 0:
        hover.append("(")
        var fi: ptr_uint = 0
        while fi < arm.arm_fields.len:
            let field = unsafe: read(arm.arm_fields.data + fi)
            if fi > 0:
                hover.append(", ")
            hover.append(field.name)
            hover.append(": ")
            hover.append(ast_formatter.render_type(field.field_type))
            fi += 1
        hover.append(")")
    return CursorResult(
        line = 0,
        column = 0,
        name_len = name.len,
        hover_text = hover,
        docs = string.String.create(),
        target_uri = string.String.create(),
        from_modules = string.String.create()
    )


## The hover for a named argument inside a variant arm constructor
## (`Result.success(value = 7)`, `Primitive.circle(radius = 2.0)`): the arm's
## declared field type, rendered `value: T` with no location (the host's
## `variant_arm_constructor_info` arm of `named_argument_parameter_info`).
function variant_arm_label_hover(
    ws: ref[workspace.Workspace],
    ast_file: ast.SourceFile,
    variant_name: str,
    arm_name: str,
    field_name: str,
) -> Option[CursorResult]:
    # The variant's declaring file: this document for a local variant, the
    # prelude's std module for Option/Result (their arms come from
    # std.option / std.result, the host's prelude-installed types).
    var decl_file = ast_file
    if variant_name.equal("Option") or variant_name.equal("Result"):
        let module_name = if variant_name.equal("Option"): "std.option" else: "std.result"
        var module_path = resolve_module_source_path(ws, module_name) else:
            return Option[CursorResult].none
        defer: module_path.release()
        let module_doc = workspace.document_analysis_for(ws, module_path.as_str()) else:
            return Option[CursorResult].none
        decl_file = module_doc.ast_file

    match variant_arm_field_type_text(decl_file, variant_name, arm_name, field_name):
        Option.some as arm_field:
            var hover = string.String.create()
            hover.append(field_name)
            hover.append(": ")
            hover.append(arm_field.value.as_str())
            arm_field.value.release()
            return Option[CursorResult].some(value = CursorResult(
                line = 0,
                column = 0,
                name_len = field_name.len,
                hover_text = hover,
                docs = string.String.create(),
                target_uri = string.String.create(),
                from_modules = string.String.create()
            ))
        Option.none:
            return Option[CursorResult].none


## The declared type text of `arm_name`'s field `field_name` in `type_name`'s
## `variant` declaration, rendered from the source (`value: T`).
function variant_arm_field_type_text(file: ast.SourceFile, type_name: str, arm_name: str, field_name: str) -> Option[string.String]:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_variant as v:
                if v.name.equal(type_name):
                    var ai: ptr_uint = 0
                    while ai < v.variant_arms.len:
                        let arm = unsafe: read(v.variant_arms.data + ai)
                        if arm.name.equal(arm_name):
                            var fi: ptr_uint = 0
                            while fi < arm.arm_fields.len:
                                let field = unsafe: read(arm.arm_fields.data + fi)
                                if field.name.equal(field_name):
                                    var text = string.String.create()
                                    text.append(ast_formatter.render_type(field.field_type))
                                    return Option[string.String].some(value = text)
                                fi += 1
                        ai += 1
            _:
                pass
        di += 1
    return Option[string.String].none


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
    tokens: span[token_mod.Token],
    ti: ptr_uint,
) -> Option[CursorResult]:
    if ti == 0 or ti + 1 >= tokens.len:
        return Option[CursorResult].none
    let label_tok = unsafe: read(tokens.data + ti)
    if label_tok.kind != tk.TokenKind.identifier:
        return Option[CursorResult].none
    if unsafe: read(tokens.data + ti + 1).kind != tk.TokenKind.equal:
        return Option[CursorResult].none

    # The head of the enclosing call: the identifier before its `(`.
    let head_info = find_aggregate_head(source, tokens, ti) else:
        return Option[CursorResult].none
    let opener = head_info.opener
    var type_name = head_info.type_name
    let field_name = cursor.token_text(source, label_tok)
    var module_alias = head_info.module_alias

    let doc = workspace.document_analysis_for(ws, file_path) else:
        return Option[CursorResult].none
    var ast_file = doc.ast_file
    var analysis = doc.analysis

    var module_roots = ws.effective_module_roots_for(file_path)
    defer: module_roots.release()
    var current_module = resolver.infer_module_name(file_path, module_roots.as_span())
    defer: current_module.release()

    # `Type.arm(field = …)` — a variant arm constructor: the head names the arm
    # and the identifier before the dot the variant, so the label's type is the
    # arm's declared field (the host's `variant_arm_constructor_info`).  A
    # variant is a static-member type (`Primitive`, the prelude `Result`), while
    # an import alias (`vec.Vec(…)`) takes the aggregate path below.
    let variant_of_label = find_variant_arm_name(source, tokens, opener, module_alias) else:
        return Option[CursorResult].none

    if variant_of_label.len > 0 and analysis.static_member_types.contains(variant_of_label):
        return variant_arm_label_hover(ws, ast_file, variant_of_label, type_name, field_name)

    # Which module's type table the head is looked up in: this file, or the
    # module the alias names.
    var lookup_module: str = current_module.as_str()
    if module_alias.len > 0:
        let module_name_ptr = unsafe: analysis.imports.get(module_alias) else:
            return Option[CursorResult].none
        lookup_module = unsafe: read(module_name_ptr)

    var lookup_path = resolve_module_source_path_for(ws, lookup_module, file_path) else:
        return Option[CursorResult].none
    defer: lookup_path.release()
    let lookup_doc = workspace.document_analysis_for(ws, lookup_path.as_str()) else:
        return Option[CursorResult].none
    var lookup_analysis = lookup_doc.analysis

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
    var field_token: Option[token_mod.Token] = Option[token_mod.Token].none
    var target_uri = string.String.create()
    if not declaring_module.equal(current_module.as_str()):
        var decl_path = resolve_module_source_path_for(ws, declaring_module, file_path) else:
            target_uri.release()
            return Option[CursorResult].none
        defer: decl_path.release()
        var decl_source = ws.document_source(decl_path.as_str()) else:
            target_uri.release()
            return Option[CursorResult].none
        defer: decl_source.release()
        let decl_doc = workspace.document_analysis_for(ws, decl_path.as_str()) else:
            target_uri.release()
            return Option[CursorResult].none
        decl_file = decl_doc.ast_file
        decl_analysis = decl_doc.analysis
        field_token = find_field_token_in_type(decl_source.as_str(), type_name, field_name)
        target_uri = file_uri_for_path(decl_path.as_str())
    else:
        field_token = find_field_token_in_type(source, type_name, field_name)

    var field_line: ptr_uint = 0
    var field_column: ptr_uint = 0
    match field_token:
        Option.some as ft:
            field_line = ft.value.line
            field_column = ft.value.column
        Option.none:
            pass
    var field_found = false
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
                            field_found = true
                            if field.field_type.name.parts.len > 0:
                                type_text.append(unsafe: read(field.field_type.name.parts.data))
                                if field.field_type.nullable:
                                    type_text.append("?")
                        fi += 1
            _:
                pass
        di += 1

    if not field_found:
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


## The head of an enclosing aggregate literal: the call's opener, the type name,
## and an optional `alias.` module qualifier.
struct AggregateHead:
    opener: int
    type_name: str
    module_alias: str


## Find the head identifier before the enclosing `(`/`[` of a named-argument
## label.  None when the head is not an identifier.
function find_aggregate_head(
    source: str,
    tokens: span[token_mod.Token],
    ti: ptr_uint,
) -> Option[AggregateHead]:
    var opener: int = -1
    var depth: int = 0
    var k: int = int<-(ti - 1)
    while k >= 0:
        let kind = unsafe: read(tokens.data + ptr_uint<-k).kind
        if kind == tk.TokenKind.rparen or kind == tk.TokenKind.rbracket:
            depth += 1
        else if kind == tk.TokenKind.lparen or kind == tk.TokenKind.lbracket:
            if depth == 0:
                opener = k
                break
            depth -= 1
        k -= 1
    if opener < 1:
        return Option[AggregateHead].none
    let head = unsafe: read(tokens.data + ptr_uint<-(opener - 1))
    if head.kind != tk.TokenKind.identifier:
        return Option[AggregateHead].none
    let type_name = cursor.token_text(source, head)

    # An `alias.Type(...)` literal names its type through a module alias.
    var module_alias: str = ""
    if opener >= 3:
        let dot_tok = unsafe: read(tokens.data + ptr_uint<-(opener - 2))
        if dot_tok.kind == tk.TokenKind.dot:
            let alias_tok = unsafe: read(tokens.data + ptr_uint<-(opener - 3))
            if alias_tok.kind == tk.TokenKind.identifier:
                module_alias = cursor.token_text(source, alias_tok)
    return Option[AggregateHead].some(value = AggregateHead(
        opener = opener,
        type_name = type_name,
        module_alias = module_alias,
    ))


## The variant name of `Variant[args].arm(...)`, or the module alias when the
## head is already qualified.  Generic arm constructors put type arguments
## between the variant and the arm, so walk back over the `[…]` group.
function find_variant_arm_name(
    source: str,
    tokens: span[token_mod.Token],
    opener: int,
    module_alias: str,
) -> Option[str]:
    var variant_of_label: str = module_alias
    if variant_of_label.len == 0 and opener >= 4:
        let close_kind = unsafe: read(tokens.data + ptr_uint<-(opener - 3)).kind
        let dot_kind = unsafe: read(tokens.data + ptr_uint<-(opener - 2)).kind
        if close_kind == tk.TokenKind.rbracket and dot_kind == tk.TokenKind.dot:
            var lk: int = opener - 4
            var bracket_depth: int = 1
            while lk >= 0:
                let inner_kind = unsafe: read(tokens.data + ptr_uint<-lk).kind
                if inner_kind == tk.TokenKind.rbracket:
                    bracket_depth += 1
                else if inner_kind == tk.TokenKind.lbracket:
                    bracket_depth -= 1
                    if bracket_depth == 0:
                        if lk >= 1:
                            let name_tok2 = unsafe: read(tokens.data + ptr_uint<-(lk - 1))
                            if name_tok2.kind == tk.TokenKind.identifier:
                                variant_of_label = cursor.token_text(source, name_tok2)
                        break
                lk -= 1
    return Option[str].some(value = variant_of_label)


function resolve_local_hover(
    ws: ref[workspace.Workspace],
    file_path: str,
    source: str,
    line: ptr_uint,
    character: ptr_uint,
) -> Option[CursorResult]:
    if source.len == 0:
        return Option[CursorResult].none

    # A dotted member (`Mask.a`, `d.push_back(…)`, `State.running`) is never a
    # bare binding: the host resolves member accesses ahead of its name tables,
    # so a same-named local must not answer for the member token.
    if cursor.dot_receiver_at(source, line, character).is_some():
        return Option[CursorResult].none

    var name_opt = find_token_str(ws.document_tokens(file_path, source), source, line, character)
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

    let doc = workspace.document_analysis_for(ws, file_path) else:
        return Option[CursorResult].none
    var ast_file = doc.ast_file
    var analysis = doc.analysis

    # The file's own module name, so a type declared here renders qualified
    # (`main.Sample`) and the renderer can report `*From main*`, as the host
    # does from its semantic facts.
    var module_roots = ws.effective_module_roots_for(file_path)
    defer: module_roots.release()
    var current_module = resolver.infer_module_name(file_path, module_roots.as_span())
    defer: current_module.release()

    # The analyzer's refinement record at the cursor: a local narrowed by a
    # guard or a loop condition answers its refined type, exactly as the host's
    # completion snapshot does.
    var flow_override = analyzer.flow_type_at(ref_of(analysis), name.as_str(), target_line, character)

    # The implicit receiver of an instance method: the analyzer binds `this` in
    # the method's scope, so a hover on it renders the host's `parameter this:
    # <receiver> (immutable)`.
    if name.as_str().equal("this"):
        match this_receiver_hover(ast_file, target_line, ref_of(analysis), current_module.as_str()):
            Option.some as this_result:
                return Option[CursorResult].some(value = this_result.value)
            Option.none:
                pass

    # 3a. Token-level: a match-arm `as name` binding answers the same payload
    # type at its declaration and at every use.
    match as_binding_hover(ref_of(analysis), current_module.as_str(), source, line, character, name.as_str()):
        Option.some as ab:
            return Option[CursorResult].some(value = ab.value)
        Option.none:
            pass

    # 3. The innermost binding that encloses the cursor — the host's scope-aware
    # binding resolution.  Its declaration line comes from the scope bindings, so
    # a same-named local in another function (or an unrelated block) cannot win,
    # and a parameter resolves as `parameter <name>: <type>`.
    var bindings = copy_bindings(ws.document_bindings(file_path, source, ast_file))
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
                                                fl.else_body != null,
                                                source, ref_of(analysis), current_module.as_str(), flow_override))
                                        _:
                                            pass
                                Option.none:
                                    # A match-arm `as name` binding is no
                                    # `stmt_local`; its payload type answers.
                                    match arm_binding_hover_result(ref_of(analysis), name.as_str(), want.value, current_module.as_str()):
                                        Option.some as arm_none:
                                            return Option[CursorResult].some(value = arm_none.value)
                                        Option.none:
                                            pass
                        match parameter_hover_in_decl(
                            name.as_str(), sfun.method_params, analysis.functions.get(sfun.name),
                            want.value, current_module.as_str(), flow_override):
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
                                                flm.else_body != null,
                                                source, ref_of(analysis), current_module.as_str(), flow_override))
                                        _:
                                            pass
                                Option.none:
                                    pass
                            match parameter_hover_in_decl(
                                name.as_str(), method.method_params,
                                method_signature_for(ref_of(analysis), method.name, method.method_params),
                                want.value, current_module.as_str(), flow_override):
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
    # per-function scan) — only inside the declaration that *contains* the
    # cursor.  The file's top-level declarations are ordered and a declaration's
    # region runs to the next one, so the last declaration starting at or before
    # the cursor is the enclosing one; a local of some earlier function must not
    # answer for a position in a later one (the host resolves a binding only
    # through the cursor's own completion frame).
    match enclosing_decl_index(ast_file, target_line):
        Option.some as enclosing_index:
            var edecl: ast.Decl
            unsafe:
                edecl = read(ast_file.declarations.data + enclosing_index.value)
            match edecl:
                ast.Decl.decl_function as fun:
                    if fun.body != null:
                        var body_loc = find_local_in_block(unsafe: read(ptr[ast.Stmt]<-fun.body), name.as_str(), source, ref_of(analysis), current_module.as_str(), flow_override)
                        match body_loc:
                            Option.some as loc:
                                return Option[CursorResult].some(value = loc.value)
                            Option.none:
                                pass
                _:
                    pass
        Option.none:
            pass

    # (The former lexical text scan is gone: it always returned none and
    # walked every line from the cursor back to line 1, an O(file²) cost on
    # every local-hover fallback.)

    return Option[CursorResult].none


## The index of the top-level declaration that contains `target_line` (1-based):
## the declaration whose start line is the greatest one at or before it.  The
## analysis' declaration list carries `emit`-expanded declarations appended out
## of source order, so the *line* decides — not the list position.
function enclosing_decl_index(file: ast.SourceFile, target_line: ptr_uint) -> Option[ptr_uint]:
    var best_line: ptr_uint = 0
    var nearest: ptr_uint = 0
    var found = false
    var di: ptr_uint = 0
    while di < file.declarations.len:
        let line = scope_mod.decl_start_line(unsafe: read(file.declarations.data + di))
        if line > 0 and line <= target_line and line >= best_line:
            best_line = line
            nearest = di
            found = true
        di += 1
    if found:
        return Option[ptr_uint].some(value = nearest)
    return Option[ptr_uint].none


## The index of the token that opens the bracket group enclosing `index` (the
## host's `enclosing_bracket_opener_index`), counting nesting.
function enclosing_bracket_opener_index(tokens: span[token_mod.Token], index: ptr_uint) -> Option[ptr_uint]:
    var depth: int = 0
    var i: int = int<-index
    while i >= 0:
        var tok: token_mod.Token
        unsafe:
            tok = read(tokens.data + ptr_uint<-i)
        if tok.kind == tk.TokenKind.rbracket:
            depth += 1
        else if tok.kind == tk.TokenKind.lbracket:
            if depth == 0:
                return Option[ptr_uint].some(value = ptr_uint<-i)
            depth -= 1
        i -= 1
    return Option[ptr_uint].none


## The previous token index at or before `index - 1` that is not structural
## (newline/indent/dedent), or none.
function previous_code_index(tokens: span[token_mod.Token], index: ptr_uint) -> Option[ptr_uint]:
    var i: int = int<-index - 1
    while i >= 0:
        var tok: token_mod.Token
        unsafe:
            tok = read(tokens.data + ptr_uint<-i)
        if not is_structural_token_kind(tok.kind):
            return Option[ptr_uint].some(value = ptr_uint<-i)
        i -= 1
    return Option[ptr_uint].none


## The hover for an identifier in a type-parameter list — the host's
## `type_parameter_hover_signature`: `[T]`, `[T implements I]` and a generic
## value parameter `[N: int]`.  A `[...]` group the attribute keyword introduces
## (`attribute[field]`) is a target list, not a type-parameter list.
function type_parameter_signature(tokens: span[token_mod.Token], source: str, index: ptr_uint) -> Option[string.String]:
    let opener = enclosing_bracket_opener_index(tokens, index) else:
        return Option[string.String].none
    match previous_code_index(tokens, opener):
        Option.some as before_opener:
            if token_kind_at(tokens, before_opener.value, tk.TokenKind.tk_attribute):
                return Option[string.String].none
        Option.none:
            pass

    var token: token_mod.Token
    unsafe:
        token = read(tokens.data + index)
    let lexeme = unsafe: token_mod.token_lexeme(token, source)
    let next_index = next_code_index(tokens, index + 1)
    let prev_index = previous_code_index(tokens, index)

    match next_index:
        Option.some as nxt:
            if token_kind_at(tokens, nxt.value, tk.TokenKind.colon):
                # Generic value parameter declaration: `[N: int]`.
                var text = string.String.create()
                text.append("generic value parameter ")
                text.append(lexeme)
                match next_code_index(tokens, nxt.value + 1):
                    Option.some as value_type:
                        var value_token: token_mod.Token
                        unsafe:
                            value_token = read(tokens.data + value_type.value)
                        let value_lexeme = unsafe: token_mod.token_lexeme(value_token, source)
                        text.append(": ")
                        text.append(value_lexeme)
                    Option.none:
                        pass
                return Option[string.String].some(value = text)
            if token_kind_at(tokens, nxt.value, tk.TokenKind.tk_implements) and preceded_by_bracket_or_comma(tokens, prev_index):
                # Constrained declaration: `[T implements Damageable]`.
                var constrained = string.String.create()
                constrained.append("type parameter ")
                constrained.append(lexeme)
                return Option[string.String].some(value = constrained)
            if preceded_by_bracket_or_comma(tokens, prev_index) and (token_kind_at(tokens, nxt.value, tk.TokenKind.rbracket) or token_kind_at(tokens, nxt.value, tk.TokenKind.comma)):
                var plain = string.String.create()
                plain.append("type parameter ")
                plain.append(lexeme)
                return Option[string.String].some(value = plain)
        Option.none:
            pass
    return Option[string.String].none


## True when the token before an identifier is its list's `[` or a `,`.
function preceded_by_bracket_or_comma(tokens: span[token_mod.Token], prev_index: Option[ptr_uint]) -> bool:
    match prev_index:
        Option.some as prev:
            return token_kind_at(tokens, prev.value, tk.TokenKind.lbracket) or token_kind_at(tokens, prev.value, tk.TokenKind.comma)
        Option.none:
            return false


## True for an identifier inside the target list of an attribute declaration
## (`attribute[field]`, `attribute[callable]`): the host's
## `attribute_target_token?`.
function attribute_target_token(tokens: span[token_mod.Token], index: ptr_uint) -> bool:
    let opener = enclosing_bracket_opener_index(tokens, index) else:
        return false
    match previous_code_index(tokens, opener):
        Option.some as before_opener:
            if not token_kind_at(tokens, before_opener.value, tk.TokenKind.tk_attribute):
                return false
        Option.none:
            return false
    match next_code_index(tokens, index + 1):
        Option.some as after:
            return token_kind_at(tokens, after.value, tk.TokenKind.rbracket) or token_kind_at(tokens, after.value, tk.TokenKind.comma)
        Option.none:
            return false


## The hover for a user-declared attribute's name: the host's
## `facts.attributes` arm renders `attribute [<targets>] <name>(<params>)` and
## reports the *module's* location (its file, line 1), not the declaration's.
function declared_attribute_hover(file: ast.SourceFile, name: str) -> Option[CursorResult]:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_attribute as attr:
                if attr.name.equal(name):
                    var hover = string.String.create()
                    hover.append("attribute [")
                    var ti: ptr_uint = 0
                    while ti < attr.targets.len:
                        if ti > 0:
                            hover.append(", ")
                        hover.append(unsafe: read(attr.targets.data + ti))
                        ti += 1
                    hover.append("] ")
                    hover.append(name)
                    hover.append("(")
                    var pi: ptr_uint = 0
                    while pi < attr.attr_params.len:
                        if pi > 0:
                            hover.append(", ")
                        let param = unsafe: read(attr.attr_params.data + pi)
                        hover.append(param.name)
                        hover.append(": ")
                        hover.append(ast_formatter.render_type(param.param_type))
                        pi += 1
                    hover.append(")")
                    return Option[CursorResult].some(value = CursorResult(
                        line = 1,
                        column = 0,
                        name_len = name.len,
                        hover_text = hover,
                        docs = string.String.create(),
                        target_uri = string.String.create(),
                        from_modules = string.String.create()
                    ))
            _:
                pass
        di += 1
    return Option[CursorResult].none


## The type name an `extending Type:` method binds as `this` for a position
## inside its body (the method that starts last at or before the cursor), or none
## outside one — including a `static` method, which binds no receiver.
function this_receiver_name(file: ast.SourceFile, target_line: ptr_uint) -> Option[str]:
    let enclosing = enclosing_decl_index(file, target_line) else:
        return Option[str].none
    var decl: ast.Decl
    unsafe:
        decl = read(file.declarations.data + enclosing)
    var receiver_name: str = ""
    match decl:
        ast.Decl.decl_extending_block as ext:
            var mi: ptr_uint = 0
            while mi < ext.methods.len:
                let method = unsafe: read(ext.methods.data + mi)
                if method.line <= target_line and method.method_kind != ast.MethodKind.mk_static:
                    receiver_name = unsafe: read(read(ext.type_name).name.parts.data)
                mi += 1
        _:
            pass
    if receiver_name.len == 0:
        return Option[str].none
    return Option[str].some(value = receiver_name)


## The receiver type of the enclosing `extending Type:` method, for resolving a
## `this` receiver's members.
function this_receiver_type(analysis: ref[analyzer.Analysis], file: ast.SourceFile, target_line: ptr_uint) -> Option[types.Type]:
    let receiver_name = this_receiver_name(file, target_line) else:
        return Option[types.Type].none
    let receiver_type_ptr = analysis.types.get(receiver_name) else:
        return Option[types.Type].none
    return Option[types.Type].some(value = unsafe: read(receiver_type_ptr))


## The hover for the implicit receiver of an instance method: the host binds
## `this` as a parameter of the receiver's type, so a `this` mention renders
## `parameter this: <receiver> (immutable)`.  The binding exists only inside an
## `extending Type:` method — a struct's own methods get no completion frame, so
## the host answers nothing there — and a `static` method has no `this` at all.
function this_receiver_hover(
    file: ast.SourceFile,
    target_line: ptr_uint,
    analysis: ref[analyzer.Analysis],
    current_module: str,
) -> Option[CursorResult]:
    let receiver_name = this_receiver_name(file, target_line) else:
        return Option[CursorResult].none

    var hover = string.String.create()
    hover.append("parameter this: ")
    let receiver_type_ptr = analysis.types.get(receiver_name)
    if receiver_type_ptr != null:
        var type_text = type_render.qualified_name(unsafe: read(receiver_type_ptr), current_module)
        hover.append(type_text.as_str())
        type_text.release()
    else:
        hover.append(receiver_name)
    hover.append(" (immutable)")
    var shortened = type_render.shorten_signature(hover.as_str())
    hover.release()
    return Option[CursorResult].some(value = CursorResult(
        line = 0,
        column = 0,
        name_len = 4,
        hover_text = shortened.text,
        docs = string.String.create(),
        target_uri = string.String.create(),
        from_modules = shortened.modules
    ))


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
    if not cursor_line_text.starts_with_at(after_for, name):
        return Option[CursorResult].none
    var hover = string.String.create()
    hover.append("for binding ")
    hover.append(name)
    return Option[CursorResult].some(value = quick_hover(hover.as_str()))


## Token-level heuristic: is this identifier a match-arm "as" binding?
## Checks whether the identifier is preceded by `as ` on the same line.
function as_binding_hover(analysis: ref[analyzer.Analysis], current_module: str, source: str, line: ptr_uint, character: ptr_uint, name: str) -> Option[CursorResult]:
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
            # An `as name` binding: the analyzer's arm payload type answers
            # `local <name>: <payload> (mutable)`, the host's snapshot shape.
            return arm_binding_hover_result(analysis, name, line + 1, current_module)
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
    flow_override: Option[types.Type],
) -> Option[CursorResult]:
    match block_stmt:
        ast.Stmt.stmt_block as blk:
            var si: ptr_uint = 0
            while si < blk.statements.len:
                var s = unsafe: read(blk.statements.data + si)
                match s:
                    ast.Stmt.stmt_local as loc:
                        # `_` is a discard, not a binding: the host's analyzer
                        # never registers it, so no hover resolves through it.
                        if loc.name == name and loc.name != "_":
                            return Option[CursorResult].some(value = local_hover_result(
                                loc.is_let, name, loc.line, loc.stmt_type, loc.value, loc.else_body != null,
                                source, analysis, current_module, flow_override))
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
            if l.name == name and l.name != "_":
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
            # The block-like statements the scope walk descends into: a binding
            # inside `unsafe:`, `defer:`, `when:` or an error block is a local
            # like any other, and the host's scope snapshot sees it.
            ast.Stmt.stmt_unsafe as uns:
                return find_local_decl_in_body(uns.body, name, want_line)
            ast.Stmt.stmt_defer as dfr:
                return find_local_decl_in_body(dfr.body, name, want_line)
            ast.Stmt.stmt_error_block as eb:
                return find_local_decl_in_body(eb.body, name, want_line)
            ast.Stmt.stmt_when as whn:
                var wi: ptr_uint = 0
                while wi < whn.branches.len:
                    let branch = read(whn.branches.data + wi)
                    match find_local_decl_in_stmts(branch.body, name, want_line):
                        Option.some as found:
                            return Option[ast.Stmt].some(value = found.value)
                        Option.none:
                            pass
                    wi += 1
                return find_local_decl_in_body(whn.else_body, name, want_line)
            ast.Stmt.stmt_parallel_block as pb:
                return find_local_decl_in_stmts(pb.bodies, name, want_line)
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
    flow_override: Option[types.Type],
) -> Option[CursorResult]:
    var pi: ptr_uint = 0
    while pi < ast_params.len:
        let ast_param = unsafe: read(ast_params.data + pi)
        if ast_param.name.equal(name) and ast_param.line == want_line:
            match flow_override:
                Option.some as refined:
                    return Option[CursorResult].some(value = parameter_hover_result(name, refined.value, current_module))
                Option.none:
                    pass
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


## The text for a local's declared type, module-qualified at every level: the
## host renders the *resolved* type's `to_s`, so the annotation's own name *and
## each of its type arguments* carry their declaring module and the caller's
## shortening turns the qualifiers into the `*From <module>*` line
## (`vec.Vec[Point]` → `std.vec.Vec<current>.Point` → `Vec[Point]` plus
## `*From std.vec, <current>*`).  A name the analysis does not register (a
## builtin generic such as `ptr[int]`, or a type parameter) stays unqualified.
function annotated_type_text(tref: ast.TypeRef, analysis: ref[analyzer.Analysis], current_module: str) -> string.String:
    var text = string.String.create()
    if tref.is_fn or tref.is_proc or tref.is_dyn:
        text.append(ast_formatter.render_type(tref))
        return text
    if tref.is_tuple:
        text.append("(")
        var ti: ptr_uint = 0
        while ti < tref.arguments.len:
            if ti > 0:
                text.append(", ")
            unsafe:
                var part = annotated_type_text(read(tref.arguments.data + ti), analysis, current_module)
                text.append(part.as_str())
                part.release()
            ti += 1
        text.append(")")
        if tref.nullable:
            text.append("?")
        return text

    # The annotation's own name: a bare name resolves through the module's type
    # table (a local type spells the file's own module), an `alias.Type` spelling
    # through the import alias's real module.
    if tref.name.parts.len == 1:
        append_nominal_qualifier(ref_of(text), unsafe: read(tref.name.parts.data), analysis, current_module)
        text.append(unsafe: read(tref.name.parts.data))
    else if tref.name.parts.len > 1:
        unsafe:
            let alias = read(tref.name.parts.data + 0)
            let module_ptr = read(analysis).imports.get(alias)
            if module_ptr != null:
                text.append(read(module_ptr))
                text.append(".")
            text.append(read(tref.name.parts.data + (tref.name.parts.len - 1)))

    var args = vec.Vec[string.String].create()
    defer: args.release()
    match tref.lifetime:
        Option.some as lt:
            var lifetime_text = string.String.create()
            lifetime_text.append("@")
            lifetime_text.append(lt.value)
            args.push(lifetime_text)
        Option.none:
            pass
    var ai: ptr_uint = 0
    while ai < tref.arguments.len:
        unsafe:
            args.push(annotated_type_text(read(tref.arguments.data + ai), analysis, current_module))
        ai += 1
    if args.len() > 0:
        text.append("[")
        var gi: ptr_uint = 0
        while gi < args.len():
            if gi > 0:
                text.append(", ")
            let part_ptr = args.get(gi) else:
                break
            unsafe:
                text.append(read(part_ptr).as_str())
                read(part_ptr).release()
            gi += 1
        text.append("]")
    if tref.nullable:
        text.append("?")
    return text


## Append the module qualifier of a bare type name (`Point` → `<module>.`), when
## the analysis registers it as a nominal type.  A type declared in the file
## being hovered carries no recorded module (a single-file check), so
## `current_module` stands in for it — the host's `Types::Struct#to_s` spelling
## the declaring module.
function append_nominal_qualifier(text: ref[string.String], name: str, analysis: ref[analyzer.Analysis], current_module: str) -> void:
    unsafe:
        let type_ptr = read(analysis).types.get(name)
        if type_ptr == null:
            return
        let registered = read(ptr[types.Type]<-type_ptr)
        match registered:
            types.Type.ty_primitive:
                # A builtin primitive (`int`, `vec3`) is registered with no
                # module and renders bare.
                return
            _:
                pass
        var module_name = types.nominal_module(registered)
        if module_name.len == 0:
            module_name = current_module
        if module_name.len == 0:
            return
        text.append(module_name)
        text.append(".")


## The hover result for one local declaration.
function local_hover_result(
    is_let: bool,
    name: str,
    decl_line: ptr_uint,
    stmt_type: ptr[ast.TypeRef]?,
    value: ptr[ast.Expr]?,
    has_guard: bool,
    source: str,
    analysis: ref[analyzer.Analysis],
    current_module: str,
    flow_override: Option[types.Type],
) -> CursorResult:
    var type_text = string.String.create()

    match flow_override:
        Option.some as refined:
            # The flow-refined type at the cursor (the host's snapshot binding).
            type_text.release()
            type_text = type_render.qualified_name(refined.value, current_module)
        Option.none:
            if stmt_type != null:
                type_text.release()
                type_text = annotated_type_text(unsafe: read(ptr[ast.TypeRef]<-stmt_type), analysis, current_module)
            else if destructure_type_at(analysis, name, decl_line).is_some():
                # A destructuring binding (`let (a, b) = …`) renders the
                # per-name type, not the initializer's tuple type.
                match destructure_type_at(analysis, name, decl_line):
                    Option.some as dt:
                        type_text.release()
                        type_text = type_render.qualified_name(dt.value, current_module)
                    Option.none:
                        pass
            else:
                match type_render.initializer_type(analysis, value):
                    Option.some as init_ty:
                        type_text.release()
                        # A guarded binding (`let x = <T?> else: …`) narrows to the
                        # guard's success type, as the analyzer's binding does.
                        let bound = if has_guard: analyzer.unwrap_nullable_type(init_ty.value) else: init_ty.value
                        type_text = type_render.qualified_name(bound, current_module)
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
