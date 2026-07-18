## Workspace symbols — builds a persistent index of all top-level
## declarations across every .mt file under the workspace roots on first
## query, then serves queries from the index.  Supports empty-query
## "list all symbols" (up to the result cap).

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.lsp.protocol as proto
import mtc.lsp.workspace as workspace
import mtc.lsp.workspace_index as idx


const MAX_RESULTS: ptr_uint = 200


const KIND_FUNCTION:  int = 12
const KIND_STRUCT:    int = 23
const KIND_ENUM:      int = 10
const KIND_VARIABLE:  int = 13
const KIND_CONSTANT:  int = 14
const KIND_INTERFACE: int = 11
const KIND_CLASS:     int = 5


public function handle_workspace_symbol(ws: ref[workspace.Workspace], query: str, id: json.Value) -> void:
    ws.build_index_if_needed()

    var results = idx.query_index(ref_of(ws.index), query, MAX_RESULTS)
    defer results.release()

    var json_text = string.String.create()
    defer json_text.release()
    json_text.append("[")

    var ri: ptr_uint = 0
    while ri < results.len():
        let rp = results.get(ri) else:
            break
        let ei = unsafe: read(rp)
        let ep = ws.index.entries.get(ei) else:
            break
        if ri > 0:
            json_text.append(",")
        emit_symbol_json(ref_of(json_text), ep)
        ri += 1

    json_text.append("]")
    proto.write_response_raw(id, json_text.as_str())


function emit_symbol_json(json_text: ref[string.String], entry: ptr[idx.Entry]) -> void:
    let e = unsafe: read(entry)
    let lz = if e.line > 0: e.line - 1 else: 0z

    json_text.append("{\"name\":\"")
    proto.append_escaped(json_text, e.name.as_str())
    json_text.append("\",\"kind\":")
    json_text.append_format(f"#{e.kind}")
    json_text.append(",\"location\":{\"uri\":\"file://")
    proto.append_escaped(json_text, e.path.as_str())
    json_text.append("\",\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":0},\"end\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{e.name.len()}")
    json_text.append("}}}}")
