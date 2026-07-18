## Formatting handler — format a document via the existing source formatter.
##
## Parses the source text, runs the AST formatter, and returns the formatted
## text as a TextEdit replacement for the entire document.

import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.pretty_printer.ast_formatter as ast_formatter
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Handle textDocument/formatting: format the entire document and return
## a list of TextEdit replacements (a single full-document edit).
public function handle_formatting(ws: ref[workspace.Workspace], params: json.Value, id: json.Value) -> void:
    let uri = text_doc_uri_from_params(params)
    if uri.len == 0:
        proto.write_error(id, -32602, "invalid params: missing textDocument.uri")
        return

    var owned_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_error(id, -32602, "invalid uri")
        return
    defer owned_path.release()

    # Read source text from the open document if available, otherwise from disk.
    var source_text = ws.document_source(owned_path.as_str()) else:
        proto.write_error(id, -32800, "format request failed: could not read file")
        return
    defer source_text.release()

    let source = source_text.as_str()
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    if parse_diags.len() > 0:
        proto.write_error(id, -32800, "format request failed: parse error")
        return

    var formatted = ast_formatter.format_source_file(ast_file)
    defer formatted.release()

    if formatted.as_str() == source or formatted.len() == 0:
        # No changes needed — return empty edit list.
        var result = json.create_array_value()
        proto.write_response(id, result)
        return

    var text_edit = json.create_object_value()
    var text_edit_ptr = text_edit.as_object()
    if text_edit_ptr == null:
        json.release_value(text_edit)
        proto.write_error(id, -32603, "internal error")
        return

    # Count lines in the source for the end position.
    var line_count: ptr_uint = 1
    var last_line_start: ptr_uint = 0
    var bi: ptr_uint = 0
    while bi < source.len:
        if source.byte_at(bi) == '\n':
            line_count += 1
            last_line_start = bi + 1
        bi += 1
    let last_line_length = source.len - last_line_start

    var edit_start = json.create_object_value()
    var edit_end = json.create_object_value()
    var edit_range = json.create_object_value()

    var s_ptr = edit_start.as_object()
    var e_ptr = edit_end.as_object()
    var r_ptr = edit_range.as_object()

    if s_ptr == null or e_ptr == null or r_ptr == null:
        json.release_value(edit_start)
        json.release_value(edit_end)
        json.release_value(edit_range)
        json.release_value(text_edit)
        proto.write_error(id, -32603, "internal error")
        return

    unsafe:
        read(s_ptr).set("line", json.number_value(0.0))
        read(s_ptr).set("character", json.number_value(0.0))
        read(e_ptr).set("line", json.number_value(double<-(line_count - 1)))
        read(e_ptr).set("character", json.number_value(double<-last_line_length))
        read(r_ptr).set("start", edit_start)
        read(r_ptr).set("end", edit_end)
        read(text_edit_ptr).set("range", edit_range)
        read(text_edit_ptr).set("newText", json.string_from_str(formatted.as_str()))

    var result = json.create_array_value()
    var result_ptr = result.as_array()
    if result_ptr == null:
        json.release_value(text_edit)
        json.release_value(result)
        proto.write_error(id, -32603, "internal error")
        return
    unsafe:
        read(result_ptr).push(text_edit)

    proto.write_response(id, result)


## Handle textDocument/rangeFormatting: format only the portion of the
## document within the given range.  Returns a TextEdit array replacing the
## request range with the formatted text.
public function handle_range_formatting(ws: ref[workspace.Workspace], params: json.Value, id: json.Value) -> void:
    let uri = proto.extract_text_doc_uri(params)
    if uri.len == 0:
        proto.write_error(id, -32602, "invalid params: missing textDocument.uri")
        return

    var owned_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_error(id, -32602, "invalid uri")
        return
    defer owned_path.release()

    var source_text = ws.document_source(owned_path.as_str()) else:
        proto.write_error(id, -32800, "format request failed: could not read file")
        return
    defer source_text.release()

    let source = source_text.as_str()

    # Extract the range from params.
    var range = extract_range(params)
    if range.start_line > range.end_line:
        proto.write_response_raw(id, "[]")
        return

    # Convert line positions to byte offsets.
    let start_offset = line_offset(source, range.start_line, range.start_char)
    let end_offset = line_offset(source, range.end_line, range.end_char)
    if end_offset > source.len:
        proto.write_response_raw(id, "[]")
        return
    if start_offset >= end_offset:
        proto.write_response_raw(id, "[]")
        return

    # Format the full file, then extract the diff for the requested range.
    # We format the full file because the Milk Tea formatter needs AST context.
    var parse_diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer parse_diags.release()
    var ast_file = parser.parse_source(source, ref_of(parse_diags))
    if parse_diags.len() > 0:
        proto.write_response_raw(id, "[]")
        return

    var formatted = ast_formatter.format_source_file(ast_file)
    defer formatted.release()

    # Extract the original and formatted text in the requested byte range.
    let original_slice = source.slice(start_offset, end_offset - start_offset)
    let formatted_slice = formatted.as_str().slice(start_offset, end_offset - start_offset)
    if original_slice.equal(formatted_slice):
        proto.write_response_raw(id, "[]")
        return

    # Build a single TextEdit replacing the range.
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
        read(sd).set("line", json.number_value(double<-range.start_line))
        read(sd).set("character", json.number_value(double<-range.start_char))
        read(ed).set("line", json.number_value(double<-range.end_line))
        read(ed).set("character", json.number_value(double<-range.end_char))
        read(rd).set("start", edit_start)
        read(rd).set("end", edit_end)
        read(text_edit_ptr).set("range", edit_range)
        read(text_edit_ptr).set("newText", json.string_from_str(formatted_slice))
        read(result_ptr).push(text_edit)

    proto.write_response(id, result)


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


## Extract the textDocument.uri from a formatting notification params object.
function text_doc_uri_from_params(params: json.Value) -> str:
    return proto.extract_text_doc_uri(params)
