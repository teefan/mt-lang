## Debug info handler — returns a formatted dump of the server workspace
## state for editor debugging.  Serializes open documents, module roots, and
## index statistics into a plain-text response.

import std.fmt
import std.json as json
import std.string as string

import mtc.lsp.protocol as proto
import mtc.lsp.workspace as workspace


## Build a plain-text string summarizing workspace state.  Returns an
## owned string.String that the caller must release.
function build_debug_text(ws: ref[workspace.Workspace]) -> string.String:
    var text = string.String.create()

    text.append("# LSP Debug Info\n\n")
    text.append("Root path: ")
    append_str(ref_of(text), ws.root_path.as_str())
    text.append("\n")
    text.append("Module roots: ")
    append_ptr_uint(ref_of(text), ws.module_roots.len())
    text.append("\n")
    text.append("Open documents: ")
    append_ptr_uint(ref_of(text), ws.open_document_count())
    text.append("\n")
    text.append("Index built: ")
    if ws.index_built:
        text.append("yes")
    else:
        text.append("no")
    text.append("\nIndex entries: ")
    append_ptr_uint(ref_of(text), ws.index_entries())
    text.append("\n")

    # Emit open document URIs directly from the workspace to avoid
    # creating temporary owned copies of all keys.
    text.append("\n## Open documents\n\n")
    var ws_keys = ws.open_docs.keys()
    while true:
        let kp = ws_keys.next() else:
            break
        unsafe:
            text.append("- ")
            text.append(read(kp).as_str())
            text.append("\n")

    return text


public function handle_debug_info(ws: ref[workspace.Workspace], id: json.Value) -> void:
    var debug_text = build_debug_text(ws)
    defer debug_text.release()

    var result_json = string.String.create()
    defer result_json.release()

    result_json.append("{\"formatted\":true,\"content\":\"")
    proto.append_escaped(ref_of(result_json), debug_text.as_str())
    result_json.append("\"}")

    proto.write_response_raw(id, result_json.as_str())


function append_str(output: ref[string.String], value: str) -> void:
    unsafe:
        read(output).append(value)


function append_ptr_uint(output: ref[string.String], value: ptr_uint) -> void:
    unsafe:
        read(output).append_format(f"#{value}")
