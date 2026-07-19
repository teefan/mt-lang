## Text document sync handlers — didOpen, didChange, didClose, didSave.

import std.json as json
import std.string as string
import std.str

import mtc.lsp.diagnostics as diag
import mtc.lsp.protocol as proto
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


## Handle textDocument/didChange (full-sync or incremental mode): replace content.
## Does NOT re-check — that happens on didSave.
public function handle_did_change(ws: ref[workspace.Workspace], params: json.Value) -> void:
    let uri = text_doc_uri(params)
    if uri.len == 0:
        return
    match ws.document_source(uri):
        Option.some as src:
            var updated = apply_content_changes(src.value.as_str(), params)
            ws.change(uri, updated)
        Option.none:
            var updated = apply_content_changes("", params)
            ws.change(uri, updated)


## Apply contentChanges from a didChange notification to a document string.
## Handles both full-sync (change:1, full text replacement) and incremental
## (change:2, range-based edits).
function apply_content_changes(current: str, params: json.Value) -> str:
    let obj_ptr = params.as_object()
    if obj_ptr == null:
        return current
    var result = string.String.from_str(current)
    defer result.release()
    unsafe:
        let changes_ptr = read(obj_ptr).get("contentChanges")
        if changes_ptr == null:
            return current
        let changes_arr_ptr = read(changes_ptr).as_array()
        if changes_arr_ptr == null:
            return current
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
            var updated = apply_utf8_range_edit(result.as_str(), start_line, start_char, end_line, end_char, new_text)
            result.clear()
            result.append(updated.as_str())
            updated.release()
            index += 1
    return result.as_str()


function apply_utf8_range_edit(
    source: str, start_line: ptr_uint, start_char: ptr_uint,
    end_line: ptr_uint, end_char: ptr_uint, new_text: str,
) -> string.String:
    let start_byte = line_char_to_byte(source, start_line, start_char)
    let end_byte = line_char_to_byte(source, end_line, end_char)
    var result = string.String.with_capacity(source.len + new_text.len)
    if start_byte > 0 and start_byte <= source.len:
        result.append(source.slice(0, start_byte))
    result.append(new_text)
    if end_byte < source.len:
        result.append(source.slice(end_byte, source.len - end_byte))
    return result


function is_cont_byte(b: ubyte) -> bool:
    return (b & ubyte<-(0xC0)) == ubyte<-(0x80)


function line_char_to_byte(source: str, line: ptr_uint, char_offset: ptr_uint) -> ptr_uint:
    var current_line: ptr_uint = 0
    var byte_pos: ptr_uint = 0
    while byte_pos < source.len:
        if current_line == line:
            # Within target line: count chars up to char_offset
            var char_count: ptr_uint = 0
            var pos: ptr_uint = byte_pos
            while pos < source.len and source.byte_at(pos) != 10:
                if char_count >= char_offset:
                    return pos
                if not is_cont_byte(source.byte_at(pos)):
                    char_count += 1
                pos += 1
            return pos
        # Advance to next line
        while byte_pos < source.len and source.byte_at(byte_pos) != 10:
            byte_pos += 1
        if byte_pos < source.len:
            byte_pos += 1
        current_line += 1
    return source.len


function read_num(p: ptr[json.Value]?) -> ptr_uint:
    if p == null:
        return 0
    unsafe:
        return ptr_uint<-(read(p).as_number().unwrap_or(0.0))


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
