## Document highlight — same-file occurrences of the identifier under the
## cursor, returned as DocumentHighlight objects (kind 1 = Text).

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.scope as scope_mod
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace
import mtc.parser.parser as parser
import mtc.parser.state as pstate


## Handle textDocument/documentHighlight.
public function handle_document_highlight(
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

    var occurrences = cursor.identifier_occurrences(source, target.text)
    defer: occurrences.release()

    # A local's occurrences are scoped like the host's binding resolution: the
    # highlight must not light up a same-named local in an unrelated function
    # (`var v` in two demos).  Every other name keeps the whole-file rule.
    var scoped_line = Option[ptr_uint].none
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    var bindings = scope_mod.collect_bindings(source, ast_file)
    defer: bindings.release()
    scoped_line = scope_mod.local_binding_line(ref_of(bindings), target.text, line + 1)

    var json_text = string.String.create()
    defer: json_text.release()
    json_text.append("[")
    var emitted: ptr_uint = 0
    var oi: ptr_uint = 0
    while oi < occurrences.len():
        let op = occurrences.get(oi) else:
            break
        let occ = unsafe: read(op)
        match scoped_line:
            Option.some as binding_line:
                if not scope_mod.is_in_same_scope(ref_of(bindings), target.text, binding_line.value, occ.line):
                    oi += 1
                    continue
            Option.none:
                pass
        if emitted > 0:
            json_text.append(",")
        emitted += 1
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
