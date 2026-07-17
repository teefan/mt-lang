## Text document sync handlers — didOpen, didChange, didClose, didSave.

import std.json as json
import std.vec as vec

import mtc.lsp.diagnostics as diag
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Handle textDocument/didOpen: store content, clear old diagnostics.
public function handle_did_open(ws: ref[workspace.Workspace], params: json.Value) -> void:
    let uri = text_doc_uri(params)
    if uri.len == 0:
        return
    let text = text_doc_text(params)
    ws.open(uri, text)
    diag.publish_empty_for_uri(uri)


## Handle textDocument/didChange (full-sync mode): replace content.
## Does NOT re-check — that happens on didSave.
public function handle_did_change(ws: ref[workspace.Workspace], params: json.Value) -> void:
    let uri = text_doc_uri(params)
    if uri.len == 0:
        return
    let text = text_doc_change_text(params)
    ws.change(uri, text)


## Handle textDocument/didClose: remove from workspace, clear diagnostics.
public function handle_did_close(ws: ref[workspace.Workspace], params: json.Value) -> void:
    let uri = text_doc_uri(params)
    if uri.len == 0:
        return
    ws.close(uri)
    diag.publish_empty_for_uri(uri)


## Handle textDocument/didSave: re-check and publish diagnostics.
public function handle_did_save(ws: ref[workspace.Workspace], params: json.Value) -> void:
    let uri = text_doc_uri(params)
    if uri.len == 0:
        return
    var owned_path = uri_ops.file_uri_to_path(uri) else:
        return
    defer owned_path.release()
    var roots = ws.effective_module_roots_for(owned_path.as_str())
    defer roots.release()
    diag.publish_for_uri(uri, owned_path.as_str(), roots.as_span())


## Extract the textDocument.uri from a didOpen / didChange / didClose / didSave
## notification params.
function text_doc_uri(params: json.Value) -> str:
    let obj_ptr = params.as_object()
    if obj_ptr == null:
        return ""
    unsafe:
        let text_doc_ptr = read(obj_ptr).get("textDocument")
        if text_doc_ptr == null:
            return ""
        let td_obj_ptr = read(text_doc_ptr).as_object()
        if td_obj_ptr == null:
            return ""
        let uri_val_ptr = read(td_obj_ptr).get("uri")
        if uri_val_ptr == null:
            return ""
        let uri_str = read(uri_val_ptr).as_string() else:
            return ""
        return uri_str

## Extract the full text content from a didOpen / didChange notification.
function text_doc_text(params: json.Value) -> str:
    let obj_ptr = params.as_object()
    if obj_ptr == null:
        return ""
    unsafe:
        let text_doc_ptr = read(obj_ptr).get("textDocument")
        if text_doc_ptr == null:
            return ""
        let td_obj_ptr = read(text_doc_ptr).as_object()
        if td_obj_ptr == null:
            return ""
        let text_val_ptr = read(td_obj_ptr).get("text")
        if text_val_ptr == null:
            return ""
        let text_str = read(text_val_ptr).as_string() else:
            return ""
        return text_str


## Extract text from a textDocument/didChange notification (full-sync mode:
## contentChanges[0].text).
function text_doc_change_text(params: json.Value) -> str:
    let obj_ptr = params.as_object()
    if obj_ptr == null:
        return ""
    unsafe:
        let changes_ptr = read(obj_ptr).get("contentChanges")
        if changes_ptr == null:
            return ""
        let changes_arr_ptr = read(changes_ptr).as_array()
        if changes_arr_ptr == null:
            return ""
        let change_ptr = read(changes_arr_ptr).get(0)
        if change_ptr == null:
            return ""
        let change_obj_ptr = read(change_ptr).as_object()
        if change_obj_ptr == null:
            return ""
        let text_val_ptr = read(change_obj_ptr).get("text")
        if text_val_ptr == null:
            return ""
        let text_str = read(text_val_ptr).as_string() else:
            return ""
        return text_str
