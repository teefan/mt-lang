## Rename — find all occurrences of an identifier and return a WorkspaceEdit.
##
## Token-accurate cursor resolution ensures identifiers inside string literals
## and comments are never rewritten.  A local binding keeps the scope-aware
## same-file rename via lsp.scope; every other name follows the host's
## `workspace_symbol_identity_rename_changes`: resolve the cursor's definition
## and rename each occurrence whose own definition resolves to the same
## declaration, across every open document.  A name with no resolvable
## definition falls back to the host's lexical same-file scan.

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.lsp.cursor as cursor
import mtc.lsp.navigation as navigation
import mtc.lsp.protocol as proto
import mtc.lsp.scope as scope_mod
import mtc.lsp.uri as uri_ops
import mtc.lsp.utils as utils
import mtc.lsp.workspace as workspace


## The declaration a rename targets: the declaring document path and the
## definition pipeline's 1-based line / 0-based column.
struct RenameIdentity:
    path: string.String
    line: ptr_uint
    column: ptr_uint


## Handle textDocument/rename.
public function handle_rename(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
    new_name: str,
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

    let doc = workspace.document_analysis_for(ws, file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    var ast_file = doc.ast_file
    var bindings = scope_mod.collect_bindings(source, ast_file)
    defer: bindings.release()

    # A local binding at the cursor: the same-file, scope-filtered rename (the
    # host's `scoped_rename_changes`).
    if scope_mod.local_binding_line(ref_of(bindings), target.text, target.line).is_some():
        var filtered = filter_occurrences(source, target.text, target.line, ref_of(bindings))
        defer: filtered.release()
        var local_json = build_rename_edits_json(
            source,
            target.text,
            uri,
            new_name,
            ref_of(filtered),
            ws.position_encoding_utf16
        )
        proto.write_response_raw(id, local_json.as_str())
        local_json.release()
        return

    # Everything else: the definition-identity rename across the open
    # documents, then the lexical same-file fallback.
    match resolve_rename_identity(ws, uri, line, character):
        Option.some as identity:
            var identity_json = build_identity_edits_json(
                ws,
                file_path.as_str(),
                uri,
                target.text,
                new_name,
                identity.value
            )
            if identity_json.len() > 0:
                proto.write_response_raw(id, identity_json.as_str())
                identity_json.release()
                identity.value.path.release()
                return
            identity_json.release()
            identity.value.path.release()
        Option.none:
            pass

    var filtered = filter_occurrences(source, target.text, target.line, ref_of(bindings))
    defer: filtered.release()
    var edits_json = build_rename_edits_json(
        source,
        target.text,
        uri,
        new_name,
        ref_of(filtered),
        ws.position_encoding_utf16
    )
    proto.write_response_raw(id, edits_json.as_str())
    edits_json.release()


## The cursor's definition, as the identity each candidate must match.  None
## when the definition pipeline answers nothing (the host then falls through to
## its lexical rename).
function resolve_rename_identity(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    character: ptr_uint,
) -> Option[RenameIdentity]:
    var payload = navigation.resolve_cursor_at(ws, uri, line, character, false) else:
        return Option[RenameIdentity].none
    payload.hover_text.release()
    payload.docs.release()
    payload.from_modules.release()
    if payload.line == 0:
        payload.target_uri.release()
        return Option[RenameIdentity].none
    var path = string.String.create()
    if payload.target_uri.len() > 0:
        match uri_ops.file_uri_to_path(payload.target_uri.as_str()):
            Option.some as resolved_path:
                path.append(resolved_path.value.as_str())
                resolved_path.value.release()
            Option.none:
                path.append(payload.target_uri.as_str())
    else:
        match uri_ops.file_uri_to_path(uri):
            Option.some as resolved_path:
                path.append(resolved_path.value.as_str())
                resolved_path.value.release()
            Option.none:
                path.append(uri)
    payload.target_uri.release()
    return Option[RenameIdentity].some(value = RenameIdentity(
        path = path,
        line = payload.line,
        column = payload.column
    ))


## The `{"changes":{…}}` edit set: every occurrence of `name` in the seed
## document and in each open document whose own definition resolves to
## `identity`.  Empty when no occurrence matches, so the caller can fall back.
function build_identity_edits_json(
    ws: ref[workspace.Workspace],
    seed_path: str,
    seed_uri: str,
    name: str,
    new_name: str,
    identity: RenameIdentity,
) -> string.String:
    var result = string.String.create()
    result.append("{\"changes\":{")
    var first_doc = true

    var seed_json = identity_document_edits(ws, seed_path, seed_uri, name, new_name, identity)
    if seed_json.len() > 0:
        append_document_changes(ref_of(result), seed_uri, ref_of(seed_json), ref_of(first_doc))
        seed_json.release()
    else:
        seed_json.release()

    let open_paths = ws.open_paths_in_order()
    var pi: ptr_uint = 0
    while pi < open_paths.len:
        let path = unsafe: read(open_paths.data + pi).as_str()
        if not path.equal(seed_path):
            var doc_uri = navigation.file_uri_for_path(path)
            var doc_json = identity_document_edits(ws, path, doc_uri.as_str(), name, new_name, identity)
            if doc_json.len() > 0:
                append_document_changes(ref_of(result), doc_uri.as_str(), ref_of(doc_json), ref_of(first_doc))
                doc_json.release()
            else:
                doc_json.release()
            doc_uri.release()
        pi += 1

    if first_doc:
        # No occurrence resolved to the target: let the caller fall back.
        result.release()
        return string.String.create()

    result.append("}}")
    return result


## One document's edit array for the identity rename, or an empty string when
## none of its occurrences resolves to `identity`.
function identity_document_edits(
    ws: ref[workspace.Workspace],
    path: str,
    doc_uri: str,
    name: str,
    new_name: str,
    identity: RenameIdentity,
) -> string.String:
    var edits = string.String.create()
    var content_opt = ws.document_source(path)
    if content_opt.is_some():
        var content = content_opt.unwrap()
        var lines = utils.split_lines(content.as_str())
        var occurrences = cursor.identifier_occurrences(content.as_str(), name)
        var oi: ptr_uint = 0
        while oi < occurrences.len():
            let op = occurrences.get(oi) else:
                break
            let occ = unsafe: read(op)
            if occurrence_matches_identity(ws, path, doc_uri, content.as_str(), occ, identity):
                if edits.len() > 0:
                    edits.append(",")
                append_edit_span(ref_of(edits), occ, new_name, ref_of(lines), ws.position_encoding_utf16)
            oi += 1
        occurrences.release()
        lines.release()
        content.release()
    return edits


## Whether the occurrence's own definition resolves to `identity`.
function occurrence_matches_identity(
    ws: ref[workspace.Workspace],
    path: str,
    doc_uri: str,
    source: str,
    occ: cursor.CursorToken,
    identity: RenameIdentity,
) -> bool:
    var payload = navigation.resolve_cursor(ws, doc_uri, source, occ.line - 1, occ.column - 1, false) else:
        return false
    payload.hover_text.release()
    payload.docs.release()
    payload.from_modules.release()
    var matches = false
    if payload.line == identity.line and payload.column == identity.column:
        if payload.target_uri.len() > 0:
            match uri_ops.file_uri_to_path(payload.target_uri.as_str()):
                Option.some as candidate_path:
                    matches = candidate_path.value.as_str().equal(identity.path.as_str())
                    candidate_path.value.release()
                Option.none:
                    pass
        else:
            matches = path.equal(identity.path.as_str())
    payload.target_uri.release()
    return matches


## Append `"<uri>":[<edits>]` to the changes object, comma-separated.
function append_document_changes(
    result: ref[string.String],
    doc_uri: str,
    edits: ref[string.String],
    first_doc: ref[bool],
) -> void:
    if not unsafe: read(first_doc):
        result.append(",")
    unsafe: read(first_doc) = false
    result.append("\"")
    proto.append_escaped(result, doc_uri)
    result.append("\":[")
    result.append(edits.as_str())
    result.append("]")


## Handle textDocument/prepareRename: the range of the identifier under the
## cursor when there is one, else null (rename not possible here).
public function handle_prepare_rename(
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

    let target = cursor.identifier_at(content.as_str(), line, character) else:
        proto.write_response(id, json.null_value())
        return

    let lz = if target.line > 0: target.line - 1 else: 0z
    var col = if target.column > 0: target.column - 1 else: 0z
    var end_col = col + target.length
    if ws.position_encoding_utf16:
        let line_text = utils.source_line(content.as_str(), target.line)
        end_col = utils.byte_to_utf16_column(line_text, end_col)
        col = utils.byte_to_utf16_column(line_text, col)
    var json_text = string.String.create()
    defer: json_text.release()
    json_text.append("{\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{col}")
    json_text.append("},\"end\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{end_col}")
    json_text.append("}},\"placeholder\":\"")
    proto.append_escaped(ref_of(json_text), target.text)
    json_text.append("\"}")
    proto.write_response_raw(id, json_text.as_str())


## Filter cursor occurrences to only those in scope.
function filter_occurrences(
    source: str,
    name: str,
    target_line: ptr_uint,
    bindings: ref[vec.Vec[scope_mod.Binding]]
) -> vec.Vec[cursor.CursorToken]:
    var all = cursor.identifier_occurrences(source, name)
    var filtered = vec.Vec[cursor.CursorToken].create()

    var oi: ptr_uint = 0
    while oi < all.len():
        let op = all.get(oi) else:
            break
        let occ = unsafe: read(op)
        if scope_mod.is_in_same_scope(bindings, name, target_line, occ.line):
            filtered.push(cursor.CursorToken(
                text = occ.text,
                line = occ.line,
                column = occ.column,
                length = occ.length
            ))
        oi += 1

    all.release()
    return filtered


## Build a WorkspaceEdit JSON with a TextEdit for each occurrence.
function build_rename_edits_json(
    source: str,
    old_name: str,
    uri: str,
    new_name: str,
    occurrences: ref[vec.Vec[cursor.CursorToken]],
    utf16: bool
) -> string.String:
    var result = string.String.create()
    result.append("{\"changes\":{\"")
    append_escaped(ref_of(result), uri)
    result.append("\":[")

    var lines = utils.split_lines(source)
    var oi: ptr_uint = 0
    while oi < occurrences.len():
        let op = occurrences.get(oi) else:
            break
        let occ = unsafe: read(op)
        if oi > 0:
            result.append(",")
        append_edit_span(ref_of(result), occ, new_name, ref_of(lines), utf16)
        oi += 1
    lines.release()

    result.append("]}}")
    return result


## One `TextEdit` object for an occurrence.  `utf16` is always true when the
## caller is an LSP request; the parameter keeps the same-file and identity
## paths on one conversion boundary.
function append_edit_span(
    result: ref[string.String],
    occ: cursor.CursorToken,
    new_name: str,
    lines: ref[vec.Vec[str]],
    utf16: bool
) -> void:
    let lz = if occ.line > 0: occ.line - 1 else: 0z
    var col = if occ.column > 0: occ.column - 1 else: 0z
    var end_col = col + occ.length
    if utf16:
        let line_text = utils.line_at(lines, lz)
        end_col = utils.byte_to_utf16_column(line_text, end_col)
        col = utils.byte_to_utf16_column(line_text, col)
    result.append("{\"range\":{\"start\":{\"line\":")
    result.append_format(f"#{lz}")
    result.append(",\"character\":")
    result.append_format(f"#{col}")
    result.append("},\"end\":{\"line\":")
    result.append_format(f"#{lz}")
    result.append(",\"character\":")
    result.append_format(f"#{end_col}")
    result.append("}},\"newText\":\"")
    proto.append_escaped(result, new_name)
    result.append("\"}")


function append_escaped(output: ref[string.String], text: str) -> void:
    proto.append_escaped(output, text)
