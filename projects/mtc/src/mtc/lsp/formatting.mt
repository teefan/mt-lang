## Formatting handler — format a document via the existing source formatter.
##
## Parses the source text, runs the AST formatter, and returns the formatted
## text as a TextEdit replacement for the entire document.

import std.fs as fs_mod
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
    var source_text = string.String.create()
    defer source_text.release()
    let persisted = ws.open_docs.get(owned_path)
    if persisted != null:
        unsafe:
            source_text.assign(read(persisted).as_str())
    else:
        var read_result = fs_mod.read_text(owned_path.as_str())
        match read_result:
            Result.success as content:
                source_text.assign(content.value.as_str())
            Result.failure:
                proto.write_error(id, -32800, "format request failed: could not read file")
                return

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
        if source.byte_at(bi) == 10:
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


## Extract the textDocument.uri from a formatting notification params object.
function text_doc_uri_from_params(params: json.Value) -> str:
    return proto.extract_text_doc_uri(params)
