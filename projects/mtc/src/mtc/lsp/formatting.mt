## Formatting handlers — the mode dispatch the client configuration selects.
##
## Ports the host's handlers (lib/milk_tea/lsp/server/formatting.rb:646-693):
## the mode comes from the client configuration (default `:tidy`), a full
## format always answers one edit whose range ends at `line_count + 1`, and
## range formatting formats the requested byte segment rather than slicing a
## whole-document result.

import std.json as json
import std.str
import std.string as string

import mtc.formatter.tidy as tidy
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Handle textDocument/formatting: format the entire document and return a
## single TextEdit replacement.
public function handle_formatting(ws: ref[workspace.Workspace], params: json.Value, id: json.Value) -> void:
    let uri = proto.extract_text_doc_uri(params)
    if uri.len == 0:
        proto.write_error(id, -32602, "invalid params: missing textDocument.uri")
        return

    var owned_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_error(id, -32602, "invalid uri")
        return
    defer: owned_path.release()

    var source_text = ws.document_source(owned_path.as_str()) else:
        proto.write_error(id, -32800, "format request failed: could not read file")
        return
    defer: source_text.release()

    let source = source_text.as_str()
    var formatted = format_with_mode(ws, source, owned_path.as_str()) else:
        # The host rescues formatter failures into an empty edit list.
        proto.write_response_raw(id, "[]")
        return
    defer: formatted.release()

    let line_count = newline_count(source)
    emit_text_edit(id, 0, 0, line_count + 1, 0, formatted.as_str())


## Handle textDocument/rangeFormatting: format only the requested byte
## segment of the document and replace the requested range with the result.
public function handle_range_formatting(ws: ref[workspace.Workspace], params: json.Value, id: json.Value) -> void:
    let uri = proto.extract_text_doc_uri(params)
    if uri.len == 0:
        proto.write_error(id, -32602, "invalid params: missing textDocument.uri")
        return

    var owned_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_error(id, -32602, "invalid uri")
        return
    defer: owned_path.release()

    var source_text = ws.document_source(owned_path.as_str()) else:
        proto.write_error(id, -32800, "format request failed: could not read file")
        return
    defer: source_text.release()

    let source = source_text.as_str()
    let range = extract_range(params)

    let start_offset = line_offset(source, range.start_line, range.start_char)
    let end_offset = line_offset(source, range.end_line, range.end_char)
    if start_offset > end_offset or end_offset > source.len:
        proto.write_response_raw(id, "[]")
        return

    let segment = source.slice(start_offset, end_offset - start_offset)
    var formatted = format_with_mode(ws, segment, owned_path.as_str()) else:
        proto.write_response_raw(id, "[]")
        return
    defer: formatted.release()

    emit_text_edit(id, range.start_line, range.start_char, range.end_line, range.end_char, formatted.as_str())


## Handle textDocument/willSaveWaitUntil: answer with the full-document edit the
## client applies on save, or `null` when nothing changes (host
## `lsp/server/text_documents.rb:109-135`).  The host also caps the work at
## 0.5 s and answers `null` on timeout; this port has no timeout here.
public function handle_will_save_wait_until(ws: ref[workspace.Workspace], params: json.Value, id: json.Value) -> void:
    let uri = proto.extract_text_doc_uri(params)
    if uri.len == 0:
        proto.write_response(id, json.null_value())
        return

    var owned_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer: owned_path.release()

    var source_text = ws.document_source(owned_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer: source_text.release()

    let source = source_text.as_str()
    if source.len == 0:
        proto.write_response(id, json.null_value())
        return

    var formatted = format_with_mode(ws, source, owned_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer: formatted.release()

    if formatted.as_str().equal(source):
        proto.write_response(id, json.null_value())
        return

    let line_count = newline_count(source)
    emit_text_edit(id, 0, 0, line_count + 1, 0, formatted.as_str())


## Format with the configured mode.  An empty configuration, an unknown mode
## name or a formatter failure all leave the document alone (empty edit list).
function format_with_mode(ws: ref[workspace.Workspace], source: str, path: str) -> Option[string.String]:
    return tidy.format_source(source, path, current_format_mode(ws), 0)


## The host initializes `@format_mode` to `:tidy` and only replaces it with one
## of `Formatter::MODES` (lib/milk_tea/lsp/server/configuration.rb:46-59).
function current_format_mode(ws: ref[workspace.Workspace]) -> tidy.FormatMode:
    let configured = ws.format_mode.as_str()
    if configured.len == 0:
        return tidy.FormatMode.tidy
    let parsed = tidy.parse_format_mode(configured) else:
        return tidy.FormatMode.tidy
    return parsed


## Answer with a one-element TextEdit array.
function emit_text_edit(
    id: json.Value,
    start_line: ptr_uint,
    start_char: ptr_uint,
    end_line: ptr_uint,
    end_char: ptr_uint,
    new_text: str,
) -> void:
    var result = json.create_array_value()
    var result_ptr = result.as_array()
    if result_ptr == null:
        json.release_value(result)
        proto.write_error(id, -32603, "internal error")
        return

    var text_edit = json.create_object_value()
    var text_edit_ptr = text_edit.as_object()
    if text_edit_ptr == null:
        json.release_value(text_edit)
        json.release_value(result)
        proto.write_error(id, -32603, "internal error")
        return

    var edit_start = json.create_object_value()
    var edit_end = json.create_object_value()
    var edit_range = json.create_object_value()

    let sd = edit_start.as_object() else:
        json.release_value(edit_start)
        json.release_value(edit_end)
        json.release_value(edit_range)
        json.release_value(text_edit)
        json.release_value(result)
        proto.write_error(id, -32603, "internal error")
        return
    let ed = edit_end.as_object() else:
        json.release_value(edit_start)
        json.release_value(edit_end)
        json.release_value(edit_range)
        json.release_value(text_edit)
        json.release_value(result)
        proto.write_error(id, -32603, "internal error")
        return
    let rd = edit_range.as_object() else:
        json.release_value(edit_start)
        json.release_value(edit_end)
        json.release_value(edit_range)
        json.release_value(text_edit)
        json.release_value(result)
        proto.write_error(id, -32603, "internal error")
        return

    unsafe:
        read(sd).set("line", json.number_value(double<-start_line))
        read(sd).set("character", json.number_value(double<-start_char))
        read(ed).set("line", json.number_value(double<-end_line))
        read(ed).set("character", json.number_value(double<-end_char))
        read(rd).set("start", edit_start)
        read(rd).set("end", edit_end)
        read(text_edit_ptr).set("range", edit_range)
        read(text_edit_ptr).set("newText", json.string_from_str(new_text))
        read(result_ptr).push(text_edit)

    proto.write_response(id, result)


## Number of newlines in `source` (Ruby's `String#count("\n")`).
function newline_count(source: str) -> ptr_uint:
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == '\n':
            count += 1
        i += 1
    return count


## Extract the range from a rangeFormatting request params.
struct FormatRange:
    start_line: ptr_uint
    start_char: ptr_uint
    end_line: ptr_uint
    end_char: ptr_uint


function extract_range(params: json.Value) -> FormatRange:
    var result = FormatRange(start_line = 0, start_char = 0, end_line = 0, end_char = 0)
    let obj_ptr = params.as_object()
    if obj_ptr == null:
        return result
    unsafe:
        let range_ptr = read(obj_ptr).get("range")
        if range_ptr == null:
            return result
        let range_obj = read(range_ptr).as_object()
        if range_obj == null:
            return result
        let start_ptr = read(range_obj).get("start")
        if start_ptr != null:
            let start_obj = read(start_ptr).as_object()
            if start_obj != null:
                result.start_line = number_field(start_obj, "line")
                result.start_char = number_field(start_obj, "character")
        let end_ptr = read(range_obj).get("end")
        if end_ptr != null:
            let end_obj = read(end_ptr).as_object()
            if end_obj != null:
                result.end_line = number_field(end_obj, "line")
                result.end_char = number_field(end_obj, "character")
    return result


## Find the byte offset of `(line, character)` in source text.
## Both line and character are 0-based LSP coordinates.
function line_offset(source: str, line: ptr_uint, character: ptr_uint) -> ptr_uint:
    var current_line: ptr_uint = 0
    var i: ptr_uint = 0
    while i < source.len and current_line < line:
        if source.byte_at(i) == '\n':
            current_line += 1
        i += 1
    return i + character


## A non-negative numeric field of a JSON object, or 0 when absent.
function number_field(obj: ptr[json.Object], name: str) -> ptr_uint:
    unsafe:
        let field_ptr = read(obj).get(name)
        if field_ptr == null:
            return 0
        let value = read(field_ptr).as_number() else:
            return 0
        if value < 0.0:
            return 0
        return ptr_uint<-int<-value
