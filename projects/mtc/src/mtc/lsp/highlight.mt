## Document highlight — same-file occurrences of the identifier under the
## cursor, returned as DocumentHighlight objects (kind 1 = Text).

import std.fmt
import std.json as json
import std.str
import std.string as string

import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Handle textDocument/documentHighlight.
public function handle_document_highlight(
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

    var occurrences = cursor.identifier_occurrences(source, target.text)
    defer occurrences.release()

    var json_text = string.String.create()
    defer json_text.release()
    json_text.append("[")
    var oi: ptr_uint = 0
    while oi < occurrences.len():
        let op = occurrences.get(oi) else:
            break
        let occ = unsafe: read(op)
        if oi > 0:
            json_text.append(",")
        let lz = if occ.line > 0: occ.line - 1 else: 0z
        let col = if occ.column > 0: occ.column - 1 else: 0z
        json_text.append("{\"range\":{\"start\":{\"line\":")
        json_text.append_format(f"#{lz}")
        json_text.append(",\"character\":")
        json_text.append_format(f"#{col}")
        json_text.append("},\"end\":{\"line\":")
        json_text.append_format(f"#{lz}")
        json_text.append(",\"character\":")
        json_text.append_format(f"#{col + occ.length}")
        json_text.append("}},\"kind\":1}")
        oi += 1
    json_text.append("]")
    proto.write_response_raw(id, json_text.as_str())
