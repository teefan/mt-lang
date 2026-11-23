## Text document sync handlers — didOpen, didChange, didClose, didSave.

import std.json as json
import std.string as string
import std.str
import std.log as log

import mtc.lsp.diagnostics as diag
import mtc.lsp.protocol as proto
import mtc.lsp.refresh as refresh
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Handle textDocument/didOpen: store content, clear old diagnostics.
public function handle_did_open(ws: ref[workspace.Workspace], params: json.Value) -> void:
    let uri = text_doc_uri(params)
    if uri.len == 0:
        return
    let text = text_doc_text(params)
    ws.open(uri, text)
    var file_path = uri_ops.file_uri_to_path(uri) else:
        diag.publish_empty_for_uri(ws, uri)
        return
    defer: file_path.release()
    ws.set_document_version(file_path.as_str(), text_doc_version(params))
    diag.publish_empty_for_uri(ws, uri)
    publish_after_change(ws, uri, file_path.as_str())


## Handle textDocument/didChange (full-sync or incremental mode): apply the
## edits, then re-check and publish — the host schedules diagnostics on every
## change, so a client that shows pushed diagnostics sees broken code clear as
## soon as it is fixed (publishing only on save left the old errors on screen).
public function handle_did_change(ws: ref[workspace.Workspace], params: json.Value) -> void:
    let uri = text_doc_uri(params)
    if uri.len == 0:
        return
    var file_path = uri_ops.file_uri_to_path(uri) else:
        return
    defer: file_path.release()
    match ws.document_source(file_path.as_str()):
        Option.some as src:
            var buf_len = src.value.len()
            var debug_msg = string.String.create()
            debug_msg.append_format(f"lsp: didChange buflen=#{buf_len}")
            log.debug(debug_msg.as_str())
            debug_msg.release()
            var updated = apply_content_changes(ws, src.value.as_str(), params)
            ws.change(uri, updated.as_str())
            ws.set_document_version(file_path.as_str(), text_doc_version(params))
            updated.release()
            src.value.release()
        Option.none:
            var updated = apply_content_changes(ws, "", params)
            ws.change(uri, updated.as_str())
            ws.set_document_version(file_path.as_str(), text_doc_version(params))
            updated.release()

    publish_after_change(ws, uri, file_path.as_str())
    refresh.request_after_change(ws)


## Re-check the document's new content and publish its diagnostics.  The
## diagnostic cache is content-keyed, so a document whose diagnostics were
## already computed for this exact text (a pull that raced the change) republishes
## without re-running the loader.
public function publish_after_change(ws: ref[workspace.Workspace], uri: str, file_path: str) -> void:
    var source = ws.document_source(file_path) else:
        return
    defer: source.release()
    diag.publish_for_uri(ws, uri, file_path, source.as_str())


## Apply contentChanges from a didChange notification to a document string.
## Returns the updated document as an owned String.
function apply_content_changes(ws: ref[workspace.Workspace], current: str, params: json.Value) -> string.String:
    let obj_ptr = params.as_object()
    if obj_ptr == null:
        return string.String.from_str(current)
    var result = string.String.from_str(current)
    unsafe:
        let changes_ptr = read(obj_ptr).get("contentChanges")
        if changes_ptr == null:
            return string.String.from_str(current)
        let changes_arr_ptr = read(changes_ptr).as_array()
        if changes_arr_ptr == null:
            return string.String.from_str(current)
        var index: ptr_uint = 0
        while true:
            let change_ptr = read(changes_arr_ptr).get(index)
            if change_ptr == null:
                break
            let change_obj_ptr = read(change_ptr).as_object()
            if change_obj_ptr == null:
                break
            let text_val_ptr = read(change_obj_ptr).get("text")
            if text_val_ptr == null:
                index += 1
                continue
            let new_text = read(text_val_ptr).as_string() else:
                index += 1
                continue
            # Check for range field → incremental edit
            let range_ptr = read(change_obj_ptr).get("range")
            if range_ptr == null:
                # Full sync: replace entire document
                result.clear()
                result.append(new_text)
                index += 1
                continue
            # Incremental edit
            let range_obj_ptr = read(range_ptr).as_object()
            if range_obj_ptr == null:
                index += 1
                continue
            let start_ptr = read(range_obj_ptr).get("start")
            if start_ptr == null:
                index += 1
                continue
            let start_obj_ptr = read(start_ptr).as_object()
            if start_obj_ptr == null:
                index += 1
                continue
            let end_ptr = read(range_obj_ptr).get("end")
            if end_ptr == null:
                index += 1
                continue
            let end_obj_ptr = read(end_ptr).as_object()
            if end_obj_ptr == null:
                index += 1
                continue
            let start_line = read_num(read(start_obj_ptr).get("line"))
            let start_char = read_num(read(start_obj_ptr).get("character"))
            let end_line = read_num(read(end_obj_ptr).get("line"))
            let end_char = read_num(read(end_obj_ptr).get("character"))
            var updated = apply_range_edit(ws, result.as_str(), start_line, start_char, end_line, end_char, new_text)
            result.clear()
            result.append(updated.as_str())
            updated.release()
            index += 1
    return result


function apply_range_edit(
    ws: ref[workspace.Workspace],
    source: str, start_line: ptr_uint, start_char: ptr_uint,
    end_line: ptr_uint, end_char: ptr_uint, new_text: str,
) -> string.String:
    let start_byte = ws.position_byte_offset_in(source, start_line, start_char)
    let end_byte = ws.position_byte_offset_in(source, end_line, end_char)
    var diag_msg = string.String.create()
    diag_msg.append_format(f"lsp: range_edit src=#{source.len} L#{start_line}:#{start_char}->b#{start_byte} L#{end_line}:#{end_char}->b#{end_byte}")
    log.debug(diag_msg.as_str())
    diag_msg.release()
    var result = string.String.with_capacity(source.len + new_text.len)
    if start_byte > 0:
        if start_byte > source.len:
            var err = string.String.create()
            err.append_format(f"lsp: slice prefix OOB src=#{source.len} sb=#{start_byte}")
            log.error(err.as_str())
            err.release()
        else:
            result.append(source.slice(0, start_byte))
    result.append(new_text)
    if end_byte < source.len:
        result.append(source.slice(end_byte, source.len - end_byte))
    else:
        if end_byte > source.len:
            var err2 = string.String.create()
            err2.append_format(f"lsp: slice suffix OOB src=#{source.len} eb=#{end_byte}")
            log.error(err2.as_str())
            err2.release()
    return result


function read_num(p: ptr[json.Value]?) -> ptr_uint:
    if p == null:
        return 0
    unsafe:
        return ptr_uint<-(read(p).as_number().unwrap_or(0.0))


## The client's `textDocument.version`, or 0 when the message omits it.
function text_doc_version(params: json.Value) -> ptr_int:
    let obj_ptr = params.as_object() else:
        return 0
    unsafe:
        let td_ptr = read(obj_ptr).get("textDocument")
        if td_ptr == null:
            return 0
        let td_obj = read(td_ptr).as_object() else:
            return 0
        let version_ptr = read(td_obj).get("version")
        if version_ptr == null:
            return 0
        let version = read(version_ptr).as_number() else:
            return 0
        return ptr_int<-int<-version


## Handle textDocument/didClose: remove from workspace, clear diagnostics.
public function handle_did_close(ws: ref[workspace.Workspace], params: json.Value) -> void:
    let uri = text_doc_uri(params)
    if uri.len == 0:
        return
    ws.close(uri)
    match uri_ops.file_uri_to_path(uri):
        Option.some as file_path:
            ws.forget_document_version(file_path.value.as_str())
            file_path.value.release()
        Option.none:
            pass
    diag.publish_empty_for_uri(ws, uri)


## Handle textDocument/didSave: re-check and publish diagnostics.
public function handle_did_save(ws: ref[workspace.Workspace], params: json.Value) -> void:
    let uri = text_doc_uri(params)
    if uri.len == 0:
        return
    var owned_path = uri_ops.file_uri_to_path(uri) else:
        return
    defer: owned_path.release()
    var source = ws.document_source(owned_path.as_str()) else:
        return
    defer: source.release()
    diag.publish_for_uri(ws, uri, owned_path.as_str(), source.as_str())


## Extract the textDocument.uri from a didOpen / didChange / didClose / didSave
## notification params.
function text_doc_uri(params: json.Value) -> str:
    return proto.extract_text_doc_uri(params)


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
