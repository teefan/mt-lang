## Rename — find all occurrences of an identifier and return a WorkspaceEdit.
##
## Both the rename target and its occurrences are resolved token-accurately
## via lsp.cursor, so identifiers inside string literals and comments are
## never rewritten.

import std.fmt
import std.json as json
import std.str
import std.string as string

import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


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
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer content.release()

    let source = content.as_str()
    let target = cursor.identifier_at(source, line, character) else:
        proto.write_response(id, json.null_value())
        return

    var edits_json = build_rename_edits_json(source, target.text, uri, new_name)
    proto.write_response_raw(id, edits_json.as_str())
    edits_json.release()


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
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer content.release()

    let target = cursor.identifier_at(content.as_str(), line, character) else:
        proto.write_response(id, json.null_value())
        return

    let lz = if target.line > 0: target.line - 1 else: 0z
    let col = if target.column > 0: target.column - 1 else: 0z
    var json_text = string.String.create()
    defer json_text.release()
    json_text.append("{\"start\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{col}")
    json_text.append("},\"end\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{col + target.length}")
    json_text.append("}}")
    proto.write_response_raw(id, json_text.as_str())


## Build a WorkspaceEdit JSON with a TextEdit for every identifier-token
## occurrence of `old_name`.
function build_rename_edits_json(source: str, old_name: str, uri: str, new_name: str) -> string.String:
    var result = string.String.create()
    result.append("{\"changes\":{\"")
    append_escaped(ref_of(result), uri)
    result.append("\":[")

    var occurrences = cursor.identifier_occurrences(source, old_name)
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
        result.append("{\"range\":{\"start\":{\"line\":")
        result.append_format(f"#{lz}")
        result.append(",\"character\":")
        result.append_format(f"#{col}")
        result.append("},\"end\":{\"line\":")
        result.append_format(f"#{lz}")
        result.append(",\"character\":")
        result.append_format(f"#{col + occ.length}")
        result.append("}},\"newText\":\"")
        append_escaped(ref_of(result), new_name)
        result.append("\"}")
        oi += 1

    result.append("]}}")
    return result


function append_escaped(output: ref[string.String], text: str) -> void:
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b == 34: output.append("\\\"") else if b == 92: output.append("\\\\") else: output.push_byte(b)
        i += 1

