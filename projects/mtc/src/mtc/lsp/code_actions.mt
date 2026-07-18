## Code actions — quick fixes derived from the diagnostics the client sends
## with the request context.  Every auto-fixable lint rule (the same set as
## `mtc lint --fix`, via the linter's fix engine) gets a quickfix, plus:
##   unused-local / unused-param → prefix the binding with `_`

import std.fmt
import std.json as json
import std.str
import std.string as string

import mtc.linter.fix_engine as fix_engine
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Handle textDocument/codeAction.
public function handle_code_actions(ws: ref[workspace.Workspace], uri: str, params: json.Value, id: json.Value) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response_raw(id, "[]")
        return
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response_raw(id, "[]")
        return
    defer content.release()

    var json_text = string.String.create()
    defer json_text.release()
    json_text.append("[")
    var emitted: ptr_uint = 0

    unsafe:
        let params_obj = params.as_object()
        if params_obj == null:
            proto.write_response_raw(id, "[]")
            return
        let context_ptr = read(params_obj).get("context")
        if context_ptr == null:
            proto.write_response_raw(id, "[]")
            return
        let context_obj = read(context_ptr).as_object()
        if context_obj == null:
            proto.write_response_raw(id, "[]")
            return
        let diags_ptr = read(context_obj).get("diagnostics")
        if diags_ptr == null:
            proto.write_response_raw(id, "[]")
            return
        let diags_array = read(diags_ptr).as_array()
        if diags_array == null:
            proto.write_response_raw(id, "[]")
            return

        var di: ptr_uint = 0
        while di < read(diags_array).len():
            let diag_ptr = read(diags_array).get(di) else:
                break
            append_fix_for_diagnostic(ref_of(json_text), ref_of(emitted), uri, content.as_str(), read(diag_ptr))
            di += 1

    json_text.append("]")
    proto.write_response_raw(id, json_text.as_str())


struct DiagnosticInfo:
    code: str
    line: ptr_uint
    start_char: ptr_uint
    end_char: ptr_uint


## Emit a CodeAction for one diagnostic when a fix is known for its code.
function append_fix_for_diagnostic(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    uri: str,
    source: str,
    diag: json.Value,
) -> void:
    match extract_diagnostic_info(diag):
        Option.none:
            return
        Option.some as info_payload:
            let info = info_payload.value
            if info.code.equal("unused-local") or info.code.equal("unused-param"):
                append_underscore_fix(json_text, emitted, uri, source, info)
            else if fix_engine.is_fixable(info.code):
                append_engine_fix(json_text, emitted, uri, source, info)


## `unused-*` fix: insert `_` before the binding name.
function append_underscore_fix(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    uri: str,
    source: str,
    info: DiagnosticInfo,
) -> void:
    let line_text = cursor.source_line(source, info.line + 1)
    if info.start_char >= line_text.len or info.end_char > line_text.len or info.end_char <= info.start_char:
        return
    let name = line_text.slice(info.start_char, info.end_char - info.start_char)
    if name.len == 0 or name.starts_with("_"):
        return

    var title = string.String.create()
    defer title.release()
    title.append("Prefix '")
    title.append(name)
    title.append("' with underscore")
    append_action(json_text, emitted, title.as_str(), uri, info.line, info.start_char, info.start_char, "_")


## Any fixable lint rule: compute the fix edit through the linter's fix
## engine against the current buffer, exactly as `mtc lint --fix` would.
function append_engine_fix(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    uri: str,
    source: str,
    info: DiagnosticInfo,
) -> void:
    match fix_engine.lsp_edit_for_warning(source, info.code, info.line + 1, info.start_char + 1):
        Option.none:
            return
        Option.some as edit_payload:
            var edit = edit_payload.value

            var title = string.String.create()
            defer title.release()
            title.append("Fix ")
            title.append(info.code)

            if unsafe: read(emitted) > 0:
                json_text.append(",")
            unsafe:
                read(emitted) = read(emitted) + 1

            json_text.append("{\"title\":\"")
            proto.append_escaped(json_text, title.as_str())
            json_text.append("\",\"kind\":\"quickfix\",\"edit\":{\"changes\":{\"")
            proto.append_escaped(json_text, uri)
            json_text.append("\":[{\"range\":{\"start\":{\"line\":")
            json_text.append_format(f"#{edit.start_line}")
            json_text.append(",\"character\":")
            json_text.append_format(f"#{edit.start_char}")
            json_text.append("},\"end\":{\"line\":")
            json_text.append_format(f"#{edit.end_line}")
            json_text.append(",\"character\":")
            json_text.append_format(f"#{edit.end_char}")
            json_text.append("}},\"newText\":\"")
            proto.append_escaped(json_text, edit.new_text.as_str())
            json_text.append("\"}]}}}")
            edit.new_text.release()


## Emit one quickfix CodeAction with a single-file TextEdit.
function append_action(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    title: str,
    uri: str,
    line: ptr_uint,
    start_char: ptr_uint,
    end_char: ptr_uint,
    new_text: str,
) -> void:
    if unsafe: read(emitted) > 0:
        json_text.append(",")
    unsafe:
        read(emitted) = read(emitted) + 1

    json_text.append("{\"title\":\"")
    proto.append_escaped(json_text, title)
    json_text.append("\",\"kind\":\"quickfix\",\"edit\":{\"changes\":{\"")
    proto.append_escaped(json_text, uri)
    json_text.append("\":[{\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{line}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{start_char}")
    json_text.append("},\"end\":{\"line\":")
    json_text.append_format(f"#{line}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{end_char}")
    json_text.append("}},\"newText\":\"")
    proto.append_escaped(json_text, new_text)
    json_text.append("\"}]}}}")


## Pull code and range fields out of one Diagnostic JSON object.
function extract_diagnostic_info(diag: json.Value) -> Option[DiagnosticInfo]:
    unsafe:
        let diag_obj = diag.as_object()
        if diag_obj == null:
            return Option[DiagnosticInfo].none

        var code: str = ""
        let code_ptr = read(diag_obj).get("code")
        if code_ptr != null:
            let code_str = read(code_ptr).as_string() else:
                return Option[DiagnosticInfo].none
            code = code_str

        let range_ptr = read(diag_obj).get("range")
        if range_ptr == null:
            return Option[DiagnosticInfo].none
        let range_obj = read(range_ptr).as_object()
        if range_obj == null:
            return Option[DiagnosticInfo].none

        let start_ptr = read(range_obj).get("start")
        if start_ptr == null:
            return Option[DiagnosticInfo].none
        let start_obj = read(start_ptr).as_object()
        if start_obj == null:
            return Option[DiagnosticInfo].none

        let end_ptr = read(range_obj).get("end")
        if end_ptr == null:
            return Option[DiagnosticInfo].none
        let end_obj = read(end_ptr).as_object()
        if end_obj == null:
            return Option[DiagnosticInfo].none

        return Option[DiagnosticInfo].some(value = DiagnosticInfo(
            code = code,
            line = number_of(start_obj, "line"),
            start_char = number_of(start_obj, "character"),
            end_char = number_of(end_obj, "character")
        ))


function number_of(obj: ptr[json.Object], name: str) -> ptr_uint:
    unsafe:
        let field_ptr = read(obj).get(name)
        if field_ptr == null:
            return 0
        let value = read(field_ptr).as_number() else:
            return 0
        if value < 0.0:
            return 0
        return ptr_uint<-int<-value
