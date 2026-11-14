## Reference search — the host's `handle_references` pipeline
## (`lib/milk_tea/lsp/server/references.rb`) and the helpers it delegates to.
##
## The host answers in this order: the identifier under the cursor; a *static*
## method reached through a type receiver (`Vec[int].create()`,
## `rl.Color.hex_digit(...)`) or through its own declaration; a scoped local
## binding; a module-level name of this document (an AST scan of this file plus
## the identifier tokens of the files that import it); and finally the
## workspace's identifier index, whose contents are the documents the server has
## tokenized so far — which is what makes a reference list grow as a session
## proceeds.  The self-host keeps the same order so the answers match request
## for request.

import std.json as json
import std.str
import std.string as string_mod
import std.vec as vec

import mtc.loader.path_resolver as resolver
import mtc.parser.ast as ast
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.semantic.analyzer as analyzer
import mtc.semantic.types as types
import mtc.lsp.cursor as cursor
import mtc.lsp.navigation as navigation
import mtc.lsp.protocol as proto
import mtc.lsp.reference_index as refidx
import mtc.lsp.scope as scope_mod
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace
import mtc.lsp.workspace_index as idx


## Handle textDocument/references.  `include_declaration` is the request's
## `context.includeDeclaration`, which the host defaults to true.
public function handle_references(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
    include_declaration: bool,
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

    # The host's `find_token_at(uri, …)` tokenizes the document it answers for,
    # so this document joins the identifier index before the answer is built.
    ws.note_document_tokens(file_path.as_str())

    let target = cursor.identifier_at(source, line, character) else:
        proto.write_response_raw(id, "[]")
        return

    # The loader-backed analysis carries the document's imports and is shared
    # with the other requests; a single-file parse is only needed when the
    # document does not load.  (The eager parse this replaces ran — and was
    # discarded — on every request.)
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var file_ast: ast.SourceFile
    var analysis: analyzer.Analysis
    match workspace.analysis_entry_for(ws, file_path.as_str()):
        Option.some as entry_payload:
            var entry = unsafe: read(entry_payload.value)
            file_ast = entry.analysis.source_file
            analysis = entry.analysis
        Option.none:
            let parsed_file = parser.parse_source(source, ref_of(parse_diags))
            file_ast = parsed_file
            analysis = analyzer.check_source_file(parsed_file)

    var entries = vec.Vec[refidx.ReferenceEntry].create()
    defer: entries.release()

    # A static method reached through a type receiver, or a static method's own
    # declaration (the host's `resolve_static_type_reference_target`).
    match resolve_static_reference_target(ws, file_path.as_str(), source, file_ast, ref_of(analysis), target):
        Option.some as static_target:
            collect_static_method_references(ws, static_target.value, include_declaration, ref_of(entries))
            write_reference_entries(ref_of(entries), target.text, no_skip_location(), id)
            return
        Option.none:
            pass

    # A scoped local binding: the same-file, scope-aware occurrence list.
    var bindings = scope_mod.collect_bindings(source, file_ast)
    defer: bindings.release()
    match scope_mod.local_binding_line(ref_of(bindings), target.text, target.line):
        Option.some as binding_line:
            collect_scoped_entries(source, file_ast, ref_of(bindings), target.text, binding_line.value, include_declaration, file_path.as_str(), ref_of(entries))
            write_reference_entries(ref_of(entries), target.text, no_skip_location(), id)
            return
        Option.none:
            pass

    # A name this document declares at module level.
    if module_level_name(ref_of(analysis), target.text):
        collect_module_level_references(ws, file_path.as_str(), source, file_ast, ref_of(analysis), ref_of(bindings), target.text, include_declaration, ref_of(entries))
        write_reference_entries(ref_of(entries), target.text, no_skip_location(), id)
        return

    # Everything else: the workspace identifier index (the host's
    # `find_all_references`), with the definition token dropped when the client
    # asked for no declaration.
    collect_global_entries(ws, target.text, ref_of(entries))
    var skip = SkipLocation(active = false, path = string_mod.String.create(), line = 0, column = 0)
    if not include_declaration:
        match navigation.find_definition_global(ws, target.text, uri, line + 1, character + 1):
            Option.some as payload:
                var found = payload.value
                skip.active = true
                skip.path.append(found.path.as_str())
                skip.line = found.line
                skip.column = found.column
                found.path.release()
            Option.none:
                pass
    write_reference_entries(ref_of(entries), target.text, skip, id)
    skip.path.release()


## The request's `context.includeDeclaration`, which the host only treats as
## false when the client says so explicitly.
public function include_declaration_param(params: json.Value) -> bool:
    let obj_ptr = params.as_object() else:
        return true
    unsafe:
        let context_ptr = read(obj_ptr).get("context")
        if context_ptr == null:
            return true
        let context_obj_ptr = read(context_ptr).as_object()
        if context_obj_ptr == null:
            return true
        let flag_ptr = read(context_obj_ptr).get("includeDeclaration")
        if flag_ptr == null:
            return true
        match read(flag_ptr).as_boolean():
            Option.some as payload:
                return payload.value
            Option.none:
                return true


## The reference count a code lens reports: the host's
## `module_level_reference_locations(..., include_declaration: true).length`.
public function count_declaration_references(
    ws: ref[workspace.Workspace],
    name: str,
    file_path: str,
    line: ptr_uint,
) -> ptr_uint:
    if name.len == 0 or file_path.len == 0:
        return 0

    var content = ws.document_source(file_path) else:
        return 0
    defer: content.release()
    let source = content.as_str()

    let doc = workspace.document_analysis_for(ws, file_path) else:
        return 0
    var file_ast = doc.ast_file
    var analysis = doc.analysis

    if not module_level_name(ref_of(analysis), name):
        return 0

    var entries = vec.Vec[refidx.ReferenceEntry].create()
    defer: entries.release()
    var bindings = scope_mod.collect_bindings(source, file_ast)
    defer: bindings.release()
    collect_module_level_references(ws, file_path, source, file_ast, ref_of(analysis), ref_of(bindings), name, true, ref_of(entries))
    return entries.len()


# =============================================================================
#  Output
# =============================================================================

## A location the writer must leave out — the host's `includeDeclaration: false`
## filter on the fallback arm, which rejects the definition token's own entry.
struct SkipLocation:
    active: bool
    path: string_mod.String
    line: ptr_uint
    column: ptr_uint


## Write the entries as a JSON array of Location objects, deduplicated by
## (uri, line, character) in first-seen order — the host's
## `results.uniq { |r| [r[:uri], r.dig(:range, :start, :line), …] }`.
function write_reference_entries(
    entries: ref[vec.Vec[refidx.ReferenceEntry]],
    name: str,
    skip: SkipLocation,
    id: json.Value,
) -> void:
    var text = string_mod.String.create()
    text.append("[")
    var seen = vec.Vec[string_mod.String].create()
    defer: release_seen_entries(ref_of(seen))

    var first = true
    var ei: ptr_uint = 0
    while ei < entries.len():
        let ep = entries.get(ei) else:
            break
        ei += 1
        let entry = unsafe: read(ep)
        if skip.active and entry.path.equal(skip.path.as_str()) and entry.line == skip.line and entry.column == skip.column:
            continue
        if reference_seen(ref_of(seen), entry):
            continue
        if not first:
            text.append(",")
        first = false
        append_reference_json(ref_of(text), entry, name)

    text.append("]")
    proto.write_response_raw(id, text.as_str())
    text.release()


## A writer filter that drops nothing (the arms that honor `includeDeclaration`
## while collecting).
function no_skip_location() -> SkipLocation:
    return SkipLocation(active = false, path = string_mod.String.create(), line = 0, column = 0)


## Release the dedup keys and the list itself.
function release_seen_entries(seen: ref[vec.Vec[string_mod.String]]) -> void:
    var si: ptr_uint = 0
    while si < seen.len():
        let sp = seen.get(si) else:
            break
        unsafe: read(sp).release()
        si += 1
    seen.release()


## True when an identical (path, line, column) entry was already emitted.
function reference_seen(seen: ref[vec.Vec[string_mod.String]], entry: refidx.ReferenceEntry) -> bool:
    var key = string_mod.String.create()
    defer: key.release()
    key.append(entry.path)
    key.append_format(f":#{entry.line}:#{entry.column}")

    var si: ptr_uint = 0
    while si < seen.len():
        let sp = seen.get(si) else:
            break
        if unsafe: read(sp).as_str().equal(key.as_str()):
            return true
        si += 1
    var stored = string_mod.String.create()
    stored.append(key.as_str())
    seen.push(stored)
    return false


## Append one Location object: 0-based start/end from the token's 1-based lexer
## position, spanning the searched name (the host's `name.length` end).
function append_reference_json(text: ref[string_mod.String], entry: refidx.ReferenceEntry, name: str) -> void:
    let lz = if entry.line > 0: entry.line - 1 else: 0z
    let col = if entry.column > 0: entry.column - 1 else: 0z

    var uri = string_mod.String.create()
    uri.append("file://")
    uri.append(entry.path)

    text.append("{\"uri\":\"")
    proto.append_escaped(text, uri.as_str())
    uri.release()
    text.append("\",\"range\":{\"start\":{\"line\":")
    text.append_format(f"#{lz}")
    text.append(",\"character\":")
    text.append_format(f"#{col}")
    text.append("},\"end\":{\"line\":")
    text.append_format(f"#{lz}")
    text.append(",\"character\":")
    text.append_format(f"#{col + name.len}")
    text.append("}}}")


# =============================================================================
#  Module-level names: the AST scan plus the importing files
# =============================================================================

## The names the host's `module_level_name?` answers for: a function, a type
## (the builtin type table included — the host registers those in its facts), a
## module-level value, an `extending` method, or an interface method.
function module_level_name(analysis: ref[analyzer.Analysis], name: str) -> bool:
    if unsafe: read(analysis).functions.contains(name):
        return true
    if unsafe: read(analysis).types.contains(name):
        return true
    if unsafe: read(analysis).type_names.contains(name):
        return true
    if unsafe: read(analysis).value_types.contains(name):
        return true
    if method_map_has_name(analysis, name):
        return true
    if interface_map_has_name(analysis, name):
        return true
    return registered_builtin_type_name(name)


## The builtin names the host's `facts.types` registers
## (`INSTALLABLE_BUILTIN_TYPE_NAMES`): the primitives and the handle types.  The
## *generic* constructors (`ptr`, `array`, `own`, `ref`, `span`, `const_ptr`)
## are not registered, so a search on one of those falls through to the
## workspace identifier index — the host's `module_level_name?` answers false
## for them, and its fallback token scan finds type-position occurrences the
## AST scan never would.
const REGISTERED_BUILTIN_TYPE_NAMES: array[str, 34] = array[str, 34](
    "bool", "byte", "ubyte", "char", "short", "ushort", "int", "uint", "long", "ulong",
    "ptr_int", "ptr_uint", "float", "double", "void", "str", "cstr",
    "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "mat3", "mat4", "quat",
    "Subscription", "EventError", "struct_handle", "field_handle", "callable_handle",
    "attribute_handle", "member_handle", "type"
)


function registered_builtin_type_name(name: str) -> bool:
    var i: ptr_uint = 0
    while i < 34:
        if REGISTERED_BUILTIN_TYPE_NAMES[i].equal(name):
            return true
        i += 1
    return false


## True when a `"<Type>.<method>"` key names `name`.
function method_map_has_name(analysis: ref[analyzer.Analysis], name: str) -> bool:
    var entries = unsafe: read(analysis).method_sigs.entries()
    while entries.next():
        let entry = entries.current()
        let key = unsafe: read(entry.key)
        if key.ends_with(name) and key.len > name.len and key.byte_at(key.len - name.len - 1) == '.':
            return true
    return false


## True when any interface declares a method named `name`.
function interface_map_has_name(analysis: ref[analyzer.Analysis], name: str) -> bool:
    var entries = unsafe: read(analysis).interfaces.entries()
    while entries.next():
        let entry = entries.current()
        let methods = unsafe: read(entry.value)
        var mi: ptr_uint = 0
        while mi < methods.len:
            if unsafe: read(methods.data + mi).name.equal(name):
                return true
            mi += 1
    return false


## This document's occurrences of `name` plus the identifier tokens of every
## file that imports the declaring module — the host's
## `module_level_reference_locations`.
function collect_module_level_references(
    ws: ref[workspace.Workspace],
    file_path: str,
    source: str,
    file_ast: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    bindings: ref[vec.Vec[scope_mod.Binding]],
    name: str,
    include_declaration: bool,
    results: ref[vec.Vec[refidx.ReferenceEntry]],
) -> void:
    collect_ast_entries(source, file_path, file_ast, bindings, name, include_declaration, results)

    var candidates = vec.Vec[string_mod.String].create()
    defer: release_paths(ref_of(candidates))
    dependent_documents(ws, analysis.module_name, file_path, ref_of(candidates))
    collect_candidate_entries(ws, name, ref_of(candidates), results)


# =============================================================================
#  The same-file AST scan
# =============================================================================

## The host's `module_level_reference_locations` same-file half: identifier
## expressions (skipping the ones a local binding owns), member accesses whose
## member is `name`, and the declaration name of a module-level declaration.
struct ReferenceScan:
    name: str
    path: str
    include_declaration: bool
    ## The document's text, so a declaration's column is read off its line (the
    ## AST stores a statement's line, not its name's column).
    source: str
    ## True for the scoped local arm: only identifier expressions and the
    ## binding's own declaration count, and the same-line-scope filter applies.
    scoped: bool
    scope_line: ptr_uint


function collect_ast_entries(
    source: str,
    file_path: str,
    file_ast: ast.SourceFile,
    bindings: ref[vec.Vec[scope_mod.Binding]],
    name: str,
    include_declaration: bool,
    results: ref[vec.Vec[refidx.ReferenceEntry]],
) -> void:
    var scan = ReferenceScan(
        name = name,
        path = file_path,
        include_declaration = include_declaration,
        source = source,
        scoped = false,
        scope_line = 0,
    )
    walk_reference_declarations(ref_of(scan), bindings, results, file_ast.declarations)


## An identifier expression.  On the module-level path it is skipped when a
## local binding of the same name owns the line (the host's `local_bid_set`
## filter); on the scoped path it must belong to the target binding's scope.
function emit_identifier_reference(w: ref[ReferenceScan], bindings: ref[vec.Vec[scope_mod.Binding]], results: ref[vec.Vec[refidx.ReferenceEntry]], name: str, line: ptr_uint, column: ptr_uint) -> void:
    if not name.equal(w.name):
        return
    if line == 0 or column == 0:
        return
    if w.scoped:
        if not scope_mod.is_in_same_scope(bindings, name, w.scope_line, line):
            return
    else:
        match scope_mod.local_binding_line(bindings, name, line):
            Option.some:
                return
            Option.none:
                pass
    push_reference(results, w.path, line, column, name.len)


## A local binding's own declaration — the host's declaration arm on the scoped
## path (a parameter, a `let`/`var`, a `for` or match binding).  The AST records
## the statement's line, so the name's column is read off that line.
function emit_scoped_decl(w: ref[ReferenceScan], bindings: ref[vec.Vec[scope_mod.Binding]], results: ref[vec.Vec[refidx.ReferenceEntry]], name: str, line: ptr_uint) -> void:
    if not w.scoped or not w.include_declaration:
        return
    if not name.equal(w.name):
        return
    if line == 0:
        return
    if not scope_mod.is_in_same_scope(bindings, name, w.scope_line, line):
        return
    let line_text = cursor.source_line(w.source, line)
    match cursor.token_start_in_line(line_text, name):
        Option.some as column:
            push_reference(results, w.path, line, column.value + 1, name.len)
        Option.none:
            pass


## A member access's member name — the host's MemberAccess arm.
function emit_member_reference(w: ref[ReferenceScan], bindings: ref[vec.Vec[scope_mod.Binding]], results: ref[vec.Vec[refidx.ReferenceEntry]], member: str, line: ptr_uint, column: ptr_uint) -> void:
    if w.scoped:
        return
    if not member.equal(w.name):
        return
    if line == 0 or column == 0:
        return
    push_reference(results, w.path, line, column, member.len)


## A module-level declaration's name — the host's declaration arm.
function emit_declaration_reference(w: ref[ReferenceScan], bindings: ref[vec.Vec[scope_mod.Binding]], results: ref[vec.Vec[refidx.ReferenceEntry]], name: str, line: ptr_uint, column: ptr_uint) -> void:
    if w.scoped or not w.include_declaration:
        return
    if not name.equal(w.name):
        return
    if line == 0 or column == 0:
        return
    push_reference(results, w.path, line, column, name.len)


function push_reference(results: ref[vec.Vec[refidx.ReferenceEntry]], path: str, line: ptr_uint, column: ptr_uint, length: ptr_uint) -> void:
    results.push(refidx.ReferenceEntry(path = path, line = line, column = column, length = length))


function walk_reference_declarations(w: ref[ReferenceScan], bindings: ref[vec.Vec[scope_mod.Binding]], results: ref[vec.Vec[refidx.ReferenceEntry]], decls: span[ast.Decl]) -> void:
    var di: ptr_uint = 0
    while di < decls.len:
        unsafe:
            walk_reference_decl(w, bindings, results, decls.data + di)
        di += 1


function walk_reference_decl(w: ref[ReferenceScan], bindings: ref[vec.Vec[scope_mod.Binding]], results: ref[vec.Vec[refidx.ReferenceEntry]], dp: ptr[ast.Decl]) -> void:
    unsafe:
        match read(dp):
            ast.Decl.decl_function as fun:
                emit_declaration_reference(w, bindings, results, fun.name, fun.line, fun.column)
                walk_reference_param_defaults(w, bindings, results, fun.method_params)
                walk_reference_stmt(w, bindings, results, fun.body)
            ast.Decl.decl_const as c:
                emit_declaration_reference(w, bindings, results, c.name, c.line, c.column)
                walk_reference_expr_opt(w, bindings, results, c.value)
                walk_reference_stmt(w, bindings, results, c.block_body)
            ast.Decl.decl_var as v:
                emit_declaration_reference(w, bindings, results, v.name, v.line, v.column)
                walk_reference_expr_opt(w, bindings, results, v.value)
            ast.Decl.decl_struct as s:
                emit_declaration_reference(w, bindings, results, s.name, s.line, s.column)
                walk_reference_declarations(w, bindings, results, s.struct_events)
                walk_reference_declarations(w, bindings, results, s.nested_types)
            ast.Decl.decl_union as u:
                emit_declaration_reference(w, bindings, results, u.name, u.line, u.column)
            ast.Decl.decl_enum as e:
                # An enum's or flags' member values are not walked: the host's
                # reflection walk reads `node.members`, which those two
                # declaration kinds shadow with their own member list, so no
                # descendant of theirs is ever visited.
                emit_declaration_reference(w, bindings, results, e.name, e.line, e.column)
            ast.Decl.decl_flags as fl:
                emit_declaration_reference(w, bindings, results, fl.name, fl.line, fl.column)
            ast.Decl.decl_variant as vr:
                emit_declaration_reference(w, bindings, results, vr.name, vr.line, vr.column)
            ast.Decl.decl_opaque as op:
                emit_declaration_reference(w, bindings, results, op.name, op.line, op.column)
            ast.Decl.decl_type_alias as ta:
                emit_declaration_reference(w, bindings, results, ta.name, ta.line, ta.column)
            ast.Decl.decl_interface as iface:
                emit_declaration_reference(w, bindings, results, iface.name, iface.line, iface.column)
                var mi: ptr_uint = 0
                while mi < iface.interface_methods.len:
                    let method = read(iface.interface_methods.data + mi)
                    emit_declaration_reference(w, bindings, results, method.name, method.line, method.column)
                    mi += 1
            ast.Decl.decl_extending_block as ext:
                var xi: ptr_uint = 0
                while xi < ext.methods.len:
                    let method = read(ext.methods.data + xi)
                    emit_declaration_reference(w, bindings, results, method.name, method.line, method.column)
                    walk_reference_param_defaults(w, bindings, results, method.method_params)
                    walk_reference_stmt(w, bindings, results, method.body)
                    xi += 1
            ast.Decl.decl_extern_function as ef:
                emit_declaration_reference(w, bindings, results, ef.name, ef.line, 0z)
                walk_reference_expr_opt(w, bindings, results, ef.mapping)
            ast.Decl.decl_foreign_function as ff:
                emit_declaration_reference(w, bindings, results, ff.name, ff.line, 0z)
                walk_reference_expr(w, bindings, results, ff.mapping)
            ast.Decl.decl_event as ev:
                emit_declaration_reference(w, bindings, results, ev.name, ev.line, ev.column)
            ast.Decl.decl_static_assert as sa:
                walk_reference_expr(w, bindings, results, sa.condition)
                walk_reference_expr_opt(w, bindings, results, sa.message)
            ast.Decl.decl_when as wh:
                walk_reference_expr(w, bindings, results, wh.discriminant)
                var wi: ptr_uint = 0
                while wi < wh.branches.len:
                    let branch = read(wh.branches.data + wi)
                    walk_reference_expr(w, bindings, results, branch.pattern)
                    walk_reference_declarations(w, bindings, results, branch.body)
                    wi += 1
                walk_reference_declarations(w, bindings, results, wh.else_body)
            _:
                pass


function walk_reference_param_defaults(w: ref[ReferenceScan], bindings: ref[vec.Vec[scope_mod.Binding]], results: ref[vec.Vec[refidx.ReferenceEntry]], params: span[ast.Param]) -> void:
    var pi: ptr_uint = 0
    while pi < params.len:
        let param = unsafe: read(params.data + pi)
        emit_scoped_decl(w, bindings, results, param.name, param.line)
        walk_reference_expr_opt(w, bindings, results, param.default_value)
        pi += 1


function walk_reference_stmt(w: ref[ReferenceScan], bindings: ref[vec.Vec[scope_mod.Binding]], results: ref[vec.Vec[refidx.ReferenceEntry]], sp: ptr[ast.Stmt]?) -> void:
    let node = sp else:
        return
    unsafe:
        match read(node):
            ast.Stmt.stmt_block as blk:
                walk_reference_stmts(w, bindings, results, blk.statements)
            ast.Stmt.stmt_local as loc:
                emit_scoped_decl(w, bindings, results, loc.name, loc.line)
                walk_reference_expr_opt(w, bindings, results, loc.value)
                walk_reference_stmt(w, bindings, results, loc.else_body)
            ast.Stmt.stmt_assignment as asn:
                walk_reference_expr(w, bindings, results, asn.target)
                walk_reference_expr(w, bindings, results, asn.value)
            ast.Stmt.stmt_if as iff:
                var bi: ptr_uint = 0
                while bi < iff.branches.len:
                    let branch = read(iff.branches.data + bi)
                    walk_reference_expr(w, bindings, results, branch.condition)
                    walk_reference_stmt(w, bindings, results, branch.body)
                    bi += 1
                walk_reference_stmt(w, bindings, results, iff.else_body)
            ast.Stmt.stmt_while as wh:
                walk_reference_expr(w, bindings, results, wh.condition)
                walk_reference_stmt(w, bindings, results, wh.body)
            ast.Stmt.stmt_for as fr:
                var fi: ptr_uint = 0
                while fi < fr.iterables.len:
                    walk_reference_expr(w, bindings, results, fr.iterables.data + fi)
                    fi += 1
                var fbi: ptr_uint = 0
                while fbi < fr.bindings.len:
                    let binding = read(fr.bindings.data + fbi)
                    emit_scoped_decl(w, bindings, results, binding.name, binding.line)
                    fbi += 1
                walk_reference_stmt(w, bindings, results, fr.body)
            ast.Stmt.stmt_match as mt:
                walk_reference_expr(w, bindings, results, mt.scrutinee)
                var mi: ptr_uint = 0
                while mi < mt.arms.len:
                    let arm = read(mt.arms.data + mi)
                    walk_reference_expr_opt(w, bindings, results, arm.pattern)
                    match arm.binding_name:
                        Option.some as binding_name:
                            emit_scoped_decl(w, bindings, results, binding_name.value, arm.binding_line)
                        Option.none:
                            pass
                    walk_reference_stmt(w, bindings, results, arm.body)
                    mi += 1
            ast.Stmt.stmt_ret as ret:
                walk_reference_expr_opt(w, bindings, results, ret.value)
            ast.Stmt.stmt_defer as dfr:
                walk_reference_expr_opt(w, bindings, results, dfr.expression)
                walk_reference_stmt(w, bindings, results, dfr.body)
            ast.Stmt.stmt_unsafe as uns:
                walk_reference_stmt(w, bindings, results, uns.body)
            ast.Stmt.stmt_expression as ex:
                walk_reference_expr(w, bindings, results, ex.expression)
            ast.Stmt.stmt_static_assert as sa:
                walk_reference_expr(w, bindings, results, sa.condition)
                walk_reference_expr_opt(w, bindings, results, sa.message)
            ast.Stmt.stmt_emit as em:
                let decl = em.declaration else:
                    return
                walk_reference_decl(w, bindings, results, decl)
            ast.Stmt.stmt_when as wh:
                walk_reference_expr(w, bindings, results, wh.discriminant)
                var wi: ptr_uint = 0
                while wi < wh.branches.len:
                    let branch = read(wh.branches.data + wi)
                    walk_reference_expr(w, bindings, results, branch.pattern)
                    walk_reference_stmts(w, bindings, results, branch.body)
                    wi += 1
                walk_reference_stmt(w, bindings, results, wh.else_body)
            ast.Stmt.stmt_parallel_block as pb:
                walk_reference_stmts(w, bindings, results, pb.bodies)
            ast.Stmt.stmt_gather as ga:
                var gi: ptr_uint = 0
                while gi < ga.handles.len:
                    walk_reference_expr(w, bindings, results, ga.handles.data + gi)
                    gi += 1
            ast.Stmt.stmt_error_block as eb:
                walk_reference_stmt(w, bindings, results, eb.body)
            _:
                pass


function walk_reference_stmts(w: ref[ReferenceScan], bindings: ref[vec.Vec[scope_mod.Binding]], results: ref[vec.Vec[refidx.ReferenceEntry]], stmts: span[ast.Stmt]) -> void:
    var si: ptr_uint = 0
    while si < stmts.len:
        unsafe:
            walk_reference_stmt(w, bindings, results, stmts.data + si)
        si += 1


function walk_reference_expr(w: ref[ReferenceScan], bindings: ref[vec.Vec[scope_mod.Binding]], results: ref[vec.Vec[refidx.ReferenceEntry]], ep: ptr[ast.Expr]) -> void:
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier as id:
                emit_identifier_reference(w, bindings, results, id.name, id.line, id.column)
            ast.Expr.expr_member_access as ma:
                emit_member_reference(w, bindings, results, ma.member_name, ma.line, ma.column)
                walk_reference_expr(w, bindings, results, ma.receiver)
            ast.Expr.expr_call as call:
                # A call's callee is not an occurrence of a local binding: the
                # host's binding resolution never binds `p` in `p(x)` to the
                # `p` parameter, so the scoped arm leaves it out.
                if not (w.scoped and is_identifier_expr(call.callee)):
                    walk_reference_expr(w, bindings, results, call.callee)
                var ai: ptr_uint = 0
                while ai < call.args.len:
                    walk_reference_expr(w, bindings, results, read(call.args.data + ai).arg_value)
                    ai += 1
            ast.Expr.expr_index_access as ix:
                walk_reference_expr(w, bindings, results, ix.receiver)
                walk_reference_expr(w, bindings, results, ix.index)
            ast.Expr.expr_specialization as sp:
                walk_reference_expr(w, bindings, results, sp.callee)
            ast.Expr.expr_binary_op as bin:
                walk_reference_expr(w, bindings, results, bin.left)
                walk_reference_expr(w, bindings, results, bin.right)
            ast.Expr.expr_unary_op as un:
                walk_reference_expr(w, bindings, results, un.operand)
            ast.Expr.expr_if as ie:
                walk_reference_expr(w, bindings, results, ie.condition)
                walk_reference_expr(w, bindings, results, ie.then_expr)
                walk_reference_expr(w, bindings, results, ie.else_expr)
            ast.Expr.expr_match as me:
                walk_reference_expr(w, bindings, results, me.scrutinee)
                var mi: ptr_uint = 0
                while mi < me.arms.len:
                    let arm = read(me.arms.data + mi)
                    walk_reference_expr_opt(w, bindings, results, arm.pattern)
                    match arm.binding_name:
                        Option.some as binding_name:
                            emit_scoped_decl(w, bindings, results, binding_name.value, arm.binding_line)
                        Option.none:
                            pass
                    walk_reference_expr(w, bindings, results, arm.value)
                    mi += 1
            ast.Expr.expr_proc as pr:
                walk_reference_param_defaults(w, bindings, results, pr.method_params)
                walk_reference_stmt(w, bindings, results, pr.body)
            ast.Expr.expr_await as aw:
                walk_reference_expr(w, bindings, results, aw.expression)
            ast.Expr.expr_detach as dt:
                walk_reference_expr(w, bindings, results, dt.expression)
            ast.Expr.expr_expression_list as el:
                var ei: ptr_uint = 0
                while ei < el.elements.len:
                    walk_reference_expr(w, bindings, results, el.elements.data + ei)
                    ei += 1
            ast.Expr.expr_named as nm:
                walk_reference_expr(w, bindings, results, nm.value)
            ast.Expr.expr_range as rg:
                walk_reference_expr(w, bindings, results, rg.start_expr)
                walk_reference_expr(w, bindings, results, rg.end_expr)
            ast.Expr.expr_prefix_cast as cast:
                walk_reference_expr(w, bindings, results, cast.expression)
            ast.Expr.expr_unsafe as uns:
                walk_reference_expr(w, bindings, results, uns.expression)
            ast.Expr.expr_format_string as fs:
                var pi: ptr_uint = 0
                while pi < fs.parts.len:
                    match read(fs.parts.data + pi):
                        ast.FormatStringPart.fmt_expr as part:
                            walk_reference_expr(w, bindings, results, part.expression)
                        _:
                            pass
                    pi += 1
            _:
                pass


## True when the expression is a plain identifier (`p` in `p(x)`).
function is_identifier_expr(ep: ptr[ast.Expr]) -> bool:
    unsafe:
        match read(ep):
            ast.Expr.expr_identifier:
                return true
            _:
                return false


function walk_reference_expr_opt(w: ref[ReferenceScan], bindings: ref[vec.Vec[scope_mod.Binding]], results: ref[vec.Vec[refidx.ReferenceEntry]], ep: ptr[ast.Expr]?) -> void:
    let node = ep else:
        return
    walk_reference_expr(w, bindings, results, node)


# =============================================================================
#  Cross-file occurrences
# =============================================================================

## The documents that import `module_name` — the host's
## `reverse_import_dependents_for`, which is built over the documents the
## server knows: its open ones, the ones whose content or tokens a request has
## touched (the reference index, which records each noted document's imports),
## and every `.mt` file under the workspace root (the workspace index, whose
## walked files carry their resolved import edges), plus — because `initialized`
## starts a background thread that indexes the workspace root — every `.mt` file
## under the root.
function dependent_documents(
    ws: ref[workspace.Workspace],
    module_name: str,
    target_path: str,
    results: ref[vec.Vec[string_mod.String]],
) -> void:
    ws.build_index_if_needed()
    var candidates = vec.Vec[string_mod.String].create()
    defer: release_paths(ref_of(candidates))

    refidx.documents_importing(ref_of(ws.reference_index), module_name, ref_of(candidates))

    var dependents = idx.dependents_of(ref_of(ws.index), target_path)
    defer: dependents.release()
    var di: ptr_uint = 0
    while di < dependents.len():
        let dp = dependents.get(di) else:
            break
        candidates.push(string_mod.String.from_str(unsafe: read(dp).as_str()))
        di += 1

    var ci: ptr_uint = 0
    while ci < candidates.len():
        let cp = candidates.get(ci) else:
            break
        let path = unsafe: read(cp).as_str()
        if document_known_to_host(ws, path):
            results.push(string_mod.String.from_str(path))
        ci += 1


## The inferred module name of a source file (`…/std/vec.mt` -> `std.vec`), the
## name importers write and the host's `facts.module_name` carries.
function module_name_for_source_path(ws: ref[workspace.Workspace], path: str) -> string_mod.String:
    var roots = ws.effective_module_roots_for(path)
    defer: roots.release()
    return resolver.infer_module_name(path, roots.as_span())


## True when the host would count `path` among its known documents: open, or
## content-/token-touched by a request, or under the workspace root (the
## `initialized` handler starts a background thread that indexes every `.mt`
## file there).
function document_known_to_host(ws: ref[workspace.Workspace], path: str) -> bool:
    if ws.is_open_path(path):
        return true
    if refidx.is_indexed(ref_of(ws.reference_index), path):
        return true
    let root = ws.root_path.as_str()
    if root.len == 0 or path.len <= root.len:
        return false
    return path.starts_with(root) and path.byte_at(root.len) == 47


## Append the identifier tokens of `name` from every candidate document — the
## host's `find_all_references_in`: the already-indexed documents answer in
## index order, and a candidate the index has not seen is tokenized on the spot,
## in the caller's candidate order.
function collect_candidate_entries(
    ws: ref[workspace.Workspace],
    name: str,
    candidates: ref[vec.Vec[string_mod.String]],
    results: ref[vec.Vec[refidx.ReferenceEntry]],
) -> void:
    var paths = vec.Vec[str].create()
    defer: paths.release()
    var ci: ptr_uint = 0
    while ci < candidates.len():
        let cp = candidates.get(ci) else:
            break
        ci += 1
        let path = unsafe: read(cp).as_str()
        if not refidx.is_indexed(ref_of(ws.reference_index), path):
            ws.note_document_tokens(path)
        paths.push(path)
    if paths.len() == 0:
        return
    refidx.entries_named_in(ref_of(ws.reference_index), name, paths.as_span(), results)


## Append the global identifier index's occurrences of `name`, first tokenizing
## the open documents the index has not seen (the host's `find_all_references`
## over `all_documents`).
function collect_global_entries(
    ws: ref[workspace.Workspace],
    name: str,
    results: ref[vec.Vec[refidx.ReferenceEntry]],
) -> void:
    let open_paths = ws.open_paths_in_order()
    var oi: ptr_uint = 0
    while oi < open_paths.len:
        let path = unsafe: read(open_paths.data + oi).as_str()
        if not refidx.is_indexed(ref_of(ws.reference_index), path):
            ws.note_document_tokens(path)
        oi += 1
    refidx.entries_named(ref_of(ws.reference_index), name, results)


# =============================================================================
#  Scoped local occurrences
# =============================================================================

## The occurrences that share the local binding's scope — the host's
## `scoped_binding_occurrence_ranges`: the AST's identifier expressions bound to
## that binding plus its declaration node, in walk order.  A named-argument
## label, a member name and a destructuring binding are not identifier nodes, so
## the host never reports them (a token scan would).
function collect_scoped_entries(
    source: str,
    file_ast: ast.SourceFile,
    bindings: ref[vec.Vec[scope_mod.Binding]],
    name: str,
    binding_line: ptr_uint,
    include_declaration: bool,
    file_path: str,
    results: ref[vec.Vec[refidx.ReferenceEntry]],
) -> void:
    var scan = ReferenceScan(
        name = name,
        path = file_path,
        include_declaration = include_declaration,
        source = source,
        scoped = true,
        scope_line = binding_line,
    )
    walk_reference_declarations(ref_of(scan), bindings, results, file_ast.declarations)


# =============================================================================
#  Static methods reached through a type receiver
# =============================================================================

## A static-method target: the location the host's
## `module_member_binding_location` builds.  Its file is the *module's* and its
## position is the method name's in the file that declares it — the two differ
## when an `extending` block for an imported type lives in the importing module
## (`rl.Color.hex_digit` → `std/raylib.mt` with the position of the method in
## the file that declares it).
struct StaticMethodTarget:
    name: str
    location_path: string_mod.String
    line: ptr_uint
    column: ptr_uint


## A method found in an `extending` block.
struct MethodDecl:
    line: ptr_uint
    column: ptr_uint
    kind: ast.MethodKind


function resolve_static_reference_target(
    ws: ref[workspace.Workspace],
    file_path: str,
    source: str,
    file_ast: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    target: cursor.CursorToken,
) -> Option[StaticMethodTarget]:
    let token_end = target.column - 1 + target.length
    match cursor.type_receiver_at(source, target.line - 1, token_end):
        Option.some as receiver:
            match resolve_static_receiver_method(ws, file_path, file_ast, analysis, receiver.value, target.text):
                Option.some as resolved:
                    return Option[StaticMethodTarget].some(value = resolved.value)
                Option.none:
                    pass
        Option.none:
            pass

    match extending_method_at_position(file_ast, target.text, target.line, target.column):
        Option.some as declared:
            if declared.value.kind != ast.MethodKind.mk_static:
                return Option[StaticMethodTarget].none
            return Option[StaticMethodTarget].some(value = StaticMethodTarget(
                name = target.text,
                location_path = string_mod.String.from_str(file_path),
                line = declared.value.line,
                column = declared.value.column,
            ))
        Option.none:
            return Option[StaticMethodTarget].none


## Resolve `receiver.method` — the host's `resolve_static_type_receiver_method`:
## the receiver's owner module comes from the alias (`alias.Type`) or the type
## itself, and the method is looked for in this document's `extending` blocks
## first, then in the owner module.
function resolve_static_receiver_method(
    ws: ref[workspace.Workspace],
    file_path: str,
    file_ast: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    receiver: cursor.TypeReceiver,
    method_name: str,
) -> Option[StaticMethodTarget]:
    var owner: str = ""
    var owner_module_known = false

    if receiver.module_alias.len > 0:
        let module_ptr = unsafe: read(analysis).imports.get(receiver.module_alias) else:
            return Option[StaticMethodTarget].none
        owner = unsafe: read(module_ptr)
        owner_module_known = true
    else:
        let type_ptr = unsafe: read(analysis).types.get(receiver.name)
        if type_ptr != null:
            unsafe:
                owner = types.nominal_module(read(type_ptr))
                owner_module_known = true

    match extending_method_decl(file_ast, analysis, receiver.name, method_name):
        Option.some as declared:
            if declared.value.kind != ast.MethodKind.mk_static:
                return Option[StaticMethodTarget].none
            let location_path = static_target_location_path(ws, file_path, analysis, owner, owner_module_known)
            match location_path:
                Option.some as path:
                    return Option[StaticMethodTarget].some(value = StaticMethodTarget(
                        name = method_name,
                        location_path = path.value,
                        line = declared.value.line,
                        column = declared.value.column,
                    ))
                Option.none:
                    return Option[StaticMethodTarget].none
        Option.none:
            pass

    # The method is declared in the owner module's own file.
    if not owner_module_known or owner.len == 0:
        return Option[StaticMethodTarget].none
    var owner_path = navigation.resolve_module_source_path(ws, owner) else:
        return Option[StaticMethodTarget].none
    defer: owner_path.release()
    let owner_doc = workspace.document_analysis_for(ws, owner_path.as_str()) else:
        return Option[StaticMethodTarget].none
    var owner_ast = owner_doc.ast_file
    var owner_analysis = owner_doc.analysis

    match extending_method_decl(owner_ast, ref_of(owner_analysis), receiver.name, method_name):
        Option.some as declared:
            if declared.value.kind != ast.MethodKind.mk_static:
                return Option[StaticMethodTarget].none
            return Option[StaticMethodTarget].some(value = StaticMethodTarget(
                name = method_name,
                location_path = string_mod.String.from_str(owner_path.as_str()),
                line = declared.value.line,
                column = declared.value.column,
            ))
        Option.none:
            return Option[StaticMethodTarget].none


## The file a static target's location points at: the current file when the
## receiver's module is this one (the host's `module_path_for_name`), else the
## owner module's file — `none` when that cannot be resolved (the host produces
## no location then, and its handler answers `[]`).
function static_target_location_path(
    ws: ref[workspace.Workspace],
    file_path: str,
    analysis: ref[analyzer.Analysis],
    owner: str,
    owner_module_known: bool,
) -> Option[string_mod.String]:
    if not owner_module_known or owner.len == 0 or owner.equal(unsafe: read(analysis).module_name):
        return Option[string_mod.String].some(value = string_mod.String.from_str(file_path))
    return navigation.resolve_module_source_path(ws, owner)


## The method `method_name` declared in one of `file`'s `extending` blocks for
## the receiver type `type_name`.
function extending_method_decl(
    file: ast.SourceFile,
    analysis: ref[analyzer.Analysis],
    type_name: str,
    method_name: str,
) -> Option[MethodDecl]:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_extending_block as ext:
                if extending_target_matches(analysis, qualified_name_text(unsafe: read(ext.type_name).name), type_name):
                    match method_in_block(ext.methods, method_name):
                        Option.some as method:
                            return Option[MethodDecl].some(value = method.value)
                        Option.none:
                            pass
            _:
                pass
        di += 1
    return Option[MethodDecl].none


## The method named `method_name` whose declaration name sits on
## (`line`, `column`) — the host's `method_binding_at_token`.
function extending_method_at_position(
    file: ast.SourceFile,
    method_name: str,
    line: ptr_uint,
    column: ptr_uint,
) -> Option[MethodDecl]:
    var di: ptr_uint = 0
    while di < file.declarations.len:
        var decl: ast.Decl
        unsafe:
            decl = read(file.declarations.data + di)
        match decl:
            ast.Decl.decl_extending_block as ext:
                var mi: ptr_uint = 0
                while mi < ext.methods.len:
                    var method: ast.Method
                    unsafe:
                        method = read(ext.methods.data + mi)
                    if method.name.equal(method_name) and method.line == line and method.column == column:
                        return Option[MethodDecl].some(value = MethodDecl(
                            line = method.line,
                            column = method.column,
                            kind = method.method_kind,
                        ))
                    mi += 1
            _:
                pass
        di += 1
    return Option[MethodDecl].none


function method_in_block(methods: span[ast.Method], method_name: str) -> Option[MethodDecl]:
    var mi: ptr_uint = 0
    while mi < methods.len:
        var method: ast.Method
        unsafe:
            method = read(methods.data + mi)
        if method.name.equal(method_name):
            return Option[MethodDecl].some(value = MethodDecl(
                line = method.line,
                column = method.column,
                kind = method.method_kind,
            ))
        mi += 1
    return Option[MethodDecl].none


## A `Type.Sub` qualified name as its dotted text.
function qualified_name_text(name: ast.QualifiedName) -> str:
    if name.parts.len == 0:
        return ""
    if name.parts.len == 1:
        return unsafe: read(name.parts.data)
    var text = string_mod.String.create()
    var pi: ptr_uint = 0
    while pi < name.parts.len:
        if pi > 0:
            text.append(".")
        text.append(unsafe: read(name.parts.data + pi))
        pi += 1
    let result = text.as_str()
    return result


## True when an `extending` block's target type is the receiver's: the block
## names it literally (`Vec[T]`, `rl.Color`) or resolves through its alias
## (`rl.Color` → `Color`).
function extending_target_matches(analysis: ref[analyzer.Analysis], block_name: str, receiver_name: str) -> bool:
    if last_name_part(block_name).equal(receiver_name):
        return true
    let canonical_ptr = unsafe: read(analysis).extending_canonical_names.get(block_name)
    if canonical_ptr == null:
        return false
    return unsafe: read(canonical_ptr).equal(receiver_name)


function last_name_part(name: str) -> str:
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i < name.len:
        if name.byte_at(i) == '.':
            start = i + 1
        i += 1
    if start == 0:
        return name
    return name.slice(start, name.len - start)


## The host's `static_type_method_references`: the identifier tokens of the name
## in the declaring module's import dependents, kept when each one resolves to
## the *same* static method the target does (or is the declaration itself).
function collect_static_method_references(
    ws: ref[workspace.Workspace],
    target: StaticMethodTarget,
    include_declaration: bool,
    results: ref[vec.Vec[refidx.ReferenceEntry]],
) -> void:
    var candidates = vec.Vec[string_mod.String].create()
    defer: release_paths(ref_of(candidates))
    var target_module = module_name_for_source_path(ws, target.location_path.as_str())
    defer: target_module.release()
    dependent_documents(ws, target_module.as_str(), target.location_path.as_str(), ref_of(candidates))
    candidates.push(string_mod.String.from_str(target.location_path.as_str()))

    var entries = vec.Vec[refidx.ReferenceEntry].create()
    defer: entries.release()
    collect_candidate_entries(ws, target.name, ref_of(candidates), ref_of(entries))

    var ei: ptr_uint = 0
    while ei < entries.len():
        let ep = entries.get(ei) else:
            break
        ei += 1
        let entry = unsafe: read(ep)
        if same_reference_location(entry, target):
            if include_declaration:
                results.push(entry)
            continue
        if static_reference_matches(ws, entry, target):
            results.push(entry)


function same_reference_location(entry: refidx.ReferenceEntry, target: StaticMethodTarget) -> bool:
    return entry.path.equal(target.location_path.as_str()) and entry.line == target.line and entry.column == target.column


## True when two resolved static targets land on the same location — the host's
## `same_location?` over `module_member_binding_location` results.
function same_target_location(candidate: StaticMethodTarget, target: StaticMethodTarget) -> bool:
    return candidate.location_path.as_str().equal(target.location_path.as_str()) and candidate.line == target.line and candidate.column == target.column


## The host's `static_type_method_reference?`: resolve the candidate's own
## receiver and method, and compare the location it lands on with the target's.
function static_reference_matches(
    ws: ref[workspace.Workspace],
    entry: refidx.ReferenceEntry,
    target: StaticMethodTarget,
) -> bool:
    var content = ws.document_source(entry.path) else:
        return false
    defer: content.release()
    let source = content.as_str()

    let token = cursor.identifier_at(source, entry.line - 1, entry.column - 1) else:
        return false

    let doc = workspace.document_analysis_for(ws, entry.path) else:
        return false
    var file_ast = doc.ast_file
    var analysis = doc.analysis

    let token_end = entry.column - 1 + entry.length
    match cursor.type_receiver_at(source, entry.line - 1, token_end):
        Option.some as receiver:
            match resolve_static_receiver_method(ws, entry.path, file_ast, ref_of(analysis), receiver.value, token.text):
                Option.some as candidate:
                    return same_target_location(candidate.value, target)
                Option.none:
                    return false
        Option.none:
            return false


function release_paths(paths: ref[vec.Vec[string_mod.String]]) -> void:
    var pi: ptr_uint = 0
    while pi < paths.len():
        let pp = paths.get(pi) else:
            break
        unsafe: read(pp).release()
        pi += 1
    paths.release()
