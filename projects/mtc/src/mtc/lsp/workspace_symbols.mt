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
    defer: results.release()

    var json_text = string.String.create()
    defer: json_text.release()
    json_text.append("[")
    var first = true

    var ri: ptr_uint = 0
    while ri < results.len():
        let rp = results.get(ri) else:
            break
        let ei = unsafe: read(rp)
        let ep = ws.index.entries.get(ei) else:
            break
        let entry = unsafe: read(ep)
        # The host's symbol index covers the client root only; the module
        # roots also carry the project/std ancestor used for imports.
        if not under_root(entry.path.as_str(), ws.root_path.as_str()):
            ri += 1
            continue
        if not first:
            json_text.append(",")
        first = false
        emit_symbol_json(ref_of(json_text), ep)
        ri += 1

    json_text.append("]")
    proto.write_response_raw(id, json_text.as_str())


function emit_symbol_json(json_text: ref[string.String], entry: ptr[idx.Entry]) -> void:
    let e = unsafe: read(entry)
    let lz = if e.line > 0: e.line - 1 else: 0z
    let colz = if e.column > 0: e.column - 1 else: 0z

    json_text.append("{\"name\":\"")
    proto.append_escaped(json_text, e.name.as_str())
    json_text.append("\",\"kind\":")
    json_text.append_format(f"#{e.kind}")
    json_text.append(",\"location\":{\"uri\":\"file://")
    proto.append_escaped(json_text, e.path.as_str())
    json_text.append("\",\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{colz}")
    json_text.append("},\"end\":{\"line\":")
    json_text.append_format(f"#{lz}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{colz + e.name.len()}")
    json_text.append("}}}}")


## True when `path` lies inside the workspace root directory.
function under_root(path: str, root: str) -> bool:
    if root.len == 0:
        return true
    if not path.starts_with(root):
        return false
    if path.len == root.len:
        return true
    return path.byte_at(root.len) == '/'
