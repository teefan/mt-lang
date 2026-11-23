## Milk Tea document context extension — tracks whether a document is a
## foreground or background source file for diagnostic prioritization.

import std.json as json
import std.str

import mtc.lsp.protocol as proto
import mtc.lsp.workspace as workspace


## Handle milkTea/documentContext.  Stores the source type per-URI in the
## workspace so diagnostics and other features can prioritize foreground
## documents.  The host answers a *request* form with `null`, so a caller that
## sends an id gets a reply (`request_id == 0` means a notification).
public function handle_document_context(ws: ref[workspace.Workspace], params: json.Value, id: json.Value, request_id: ptr_uint) -> void:
    let uri = proto.extract_text_doc_uri(params)
    if uri.len == 0:
        if request_id > 0:
            proto.write_response(id, json.null_value())
        return

    let context = extract_context(params)
    ws.set_document_context(uri, context)
    if request_id > 0:
        proto.write_response(id, json.null_value())


## Extract the "type" field from documentContext params.
function extract_context(params: json.Value) -> str:
    let obj_ptr = params.as_object()
    if obj_ptr == null:
        return ""
    unsafe:
        let type_ptr = read(obj_ptr).get("type")
        if type_ptr == null:
            return ""
        let type_str = read(type_ptr).as_string() else:
            return ""
        return type_str
