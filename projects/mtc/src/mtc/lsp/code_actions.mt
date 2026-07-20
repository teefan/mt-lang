## Code actions — quick fixes derived from the diagnostics the client sends
## with the request context.  Every auto-fixable lint rule (the same set as
## `mtc lint --fix`, via the linter's fix engine) gets a quickfix, plus:
##   unused-local / unused-param → prefix the binding with `_`

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.linter.fix_engine as fix_engine
import mtc.lsp.cursor as cursor
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.utils as utils
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

    let source = content.as_str()

    var only_kinds = extract_only_kinds(params)
    var want_quickfix = only_kinds.len == 0
    var want_fixall = only_kinds.len > 0
    if only_kinds.len > 0:
        var ki: ptr_uint = 0
        while ki < only_kinds.len:
            let kp = only_kinds.get(ki) else:
                break
            let k = unsafe: read(kp)
            if k.starts_with("quickfix") or k.starts_with("quickFix"):
                want_quickfix = true
            if k.starts_with("source"):
                want_fixall = true
            ki += 1

    # source.fixAll: apply all lint auto-fixes at once.
    if want_fixall:
        var empty_sel = vec.Vec[str].create()
        defer empty_sel.release()
        var empty_ign = vec.Vec[str].create()
        defer empty_ign.release()
        var empty_own = zero[span[str]]
        var fixed = fix_engine.fix_source(source, file_path.as_str(), empty_own, ref_of(empty_sel), ref_of(empty_ign))
        defer fixed.release()
        if not fixed.as_str().equal(source):
            let lines = ptr_uint<-(line_count(source))
            var result = string.String.create()
            result.append("[{\"title\":\"Fix all issues\",\"kind\":\"source.fixAll\",\"edit\":{\"changes\":{\"")
            proto.append_escaped(ref_of(result), uri)
            result.append("\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":")
            result.append_format(f"#{lines}")
            result.append(",\"character\":0}},\"newText\":\"")
            proto.append_escaped(ref_of(result), fixed.as_str())
            result.append("\"}]}}}]")
            proto.write_response_raw(id, result.as_str())
            result.release()
            return

    if not want_quickfix:
        proto.write_response_raw(id, "[]")
        return

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
            else if info.code.equal("dead-assignment"):
                append_dead_assignment_fix(json_text, emitted, uri, source, info)
            else if info.code.equal("shadow"):
                append_underscore_fix(json_text, emitted, uri, source, info)
            else if fix_engine.is_fixable(info.code):
                append_engine_fix(json_text, emitted, uri, source, info)
            else:
                match extract_diagnostic_message(diag):
                    Option.some as msg:
                        if msg.value.equal("pointer cast requires unsafe") or msg.value.equal("ref to pointer cast requires unsafe"):
                            append_unsafe_wrap_fix(json_text, emitted, uri, source, info)
                        else if msg.value.starts_with("match on "):
                            append_match_arms_fix(json_text, emitted, uri, source, info, msg.value)
                    Option.none:
                        pass


## Wrap a statement in `unsafe:` / `unsafe:\n    ...` block.
function append_unsafe_wrap_fix(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    uri: str,
    source: str,
    info: DiagnosticInfo,
) -> void:
    let line_text = cursor.source_line(source, info.line + 1)
    if line_text.len == 0:
        return
    # Skip lines that are already `unsafe:` blocks.
    if line_text.trim_ascii_whitespace().starts_with("unsafe:"):
        return
    let indent = utils.indent_of(line_text)
    var new_text = string.String.create()
    defer new_text.release()
    var qi: ptr_uint = 0
    while qi < indent:
        new_text.push_byte(' ')
        qi += 1
    new_text.append("unsafe: ")
    let body = line_text.trim_ascii_whitespace()
    new_text.append(body)
    new_text.append("\n")

    if unsafe: read(emitted) > 0:
        json_text.append(",")
    unsafe:
        read(emitted) = read(emitted) + 1

    json_text.append("{\"title\":\"Wrap in unsafe block\",\"kind\":\"quickfix\",")
    json_text.append("\"edit\":{\"changes\":{\"")
    proto.append_escaped(json_text, uri)
    json_text.append("\":[{\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{info.line}")
    json_text.append(",\"character\":0},\"end\":{\"line\":")
    json_text.append_format(f"#{info.line + 1}")
    json_text.append(",\"character\":0}},\"newText\":\"")
    proto.append_escaped(json_text, new_text.as_str())
    json_text.append("\"}]}}}")


## Add missing match arm stubs for each case named in the message.
## Message format: "match on <type> is missing cases: A, B, C"
function append_match_arms_fix(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    uri: str,
    source: str,
    info: DiagnosticInfo,
    msg: str,
) -> void:
    let cases_start = msg.find_substring("missing cases: ") else:
        return
    let cases_str = msg.slice(cases_start + 15, msg.len - cases_start - 15)
    if cases_str.len == 0:
        return

    let line_text = cursor.source_line(source, info.line + 1)
    if line_text.len == 0:
        return
    let indent_len = utils.indent_of(line_text)
    let arm_indent = indent_len + 4
    let body_indent = arm_indent + 4

    var new_text = string.String.create()
    defer new_text.release()

    # Build the new arm text.
    var si: ptr_uint = 0
    var seg_start: ptr_uint = 0
    while si <= cases_str.len:
        if si == cases_str.len or cases_str.byte_at(si) == ',':
            let arm_name = cases_str.slice(seg_start, si - seg_start).trim_ascii_whitespace()
            if arm_name.len > 0:
                var ti: ptr_uint = 0
                while ti < arm_indent:
                    new_text.push_byte(' ')
                    ti += 1
                new_text.append(arm_name)
                new_text.append(":\n")
                ti = 0
                while ti < body_indent:
                    new_text.push_byte(' ')
                    ti += 1
                new_text.append("return\n")
            seg_start = si + 1
        si += 1

    if new_text.len() == 0:
        return

    var title = string.String.create()
    title.append("Add missing match arms")
    if unsafe: read(emitted) > 0:
        json_text.append(",")
    unsafe:
        read(emitted) = read(emitted) + 1

    json_text.append("{\"title\":\"")
    proto.append_escaped(json_text, title.as_str())
    title.release()
    json_text.append("\",\"kind\":\"quickfix\",")
    json_text.append("\"edit\":{\"changes\":{\"")
    proto.append_escaped(json_text, uri)
    json_text.append("\":[{\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{info.line}")
    json_text.append(",\"character\":0},\"end\":{\"line\":")
    json_text.append_format(f"#{info.line}")
    json_text.append(",\"character\":0}},\"newText\":\"")
    proto.append_escaped(json_text, new_text.as_str())
    json_text.append("\"}]}}}")


## Extract the message string from a diagnostic JSON object.
function extract_diagnostic_message(diag: json.Value) -> Option[str]:
    unsafe:
        let diag_obj = diag.as_object()
        if diag_obj == null:
            return Option[str].none
        let msg_ptr = read(diag_obj).get("message")
        if msg_ptr == null:
            return Option[str].none
        let msg = read(msg_ptr).as_string() else:
            return Option[str].none
        return Option[str].some(value = msg)


## Remove the entire line of a dead assignment.
function append_dead_assignment_fix(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    uri: str,
    source: str,
    info: DiagnosticInfo,
) -> void:
    if unsafe: read(emitted) > 0:
        json_text.append(",")
    unsafe:
        read(emitted) = read(emitted) + 1

    var title = string.String.create()
    title.append("Remove dead assignment")
    json_text.append("{\"title\":\"")
    proto.append_escaped(json_text, title.as_str())
    title.release()
    json_text.append("\",\"kind\":\"quickfix\",\"edit\":{\"changes\":{\"")
    proto.append_escaped(json_text, uri)
    json_text.append("\":[{\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{info.line}")
    json_text.append(",\"character\":0},\"end\":{\"line\":")
    json_text.append_format(f"#{info.line + 1}")
    json_text.append(",\"character\":0}},\"newText\":\"\"}]}}}")


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


## Extract the context.only array from the code action params.  Returns an
## empty Vec when absent or empty, meaning all kinds are requested.
function extract_only_kinds(params: json.Value) -> vec.Vec[str]:
    var result = vec.Vec[str].create()
    unsafe:
        let obj = params.as_object()
        if obj == null:
            return result
        let ctx_ptr = read(obj).get("context")
        if ctx_ptr == null:
            return result
        let ctx_obj = read(ctx_ptr).as_object()
        if ctx_obj == null:
            return result
        let only_ptr = read(ctx_obj).get("only")
        if only_ptr == null:
            return result
        let only_arr = read(only_ptr).as_array()
        if only_arr == null:
            return result
        var i: ptr_uint = 0
        while i < read(only_arr).len():
            let item_ptr = read(only_arr).get(i) else:
                break
            let ks = read(item_ptr).as_string() else:
                i += 1
                continue
            result.push(ks)
            i += 1
    return result


function line_count(source: str) -> ptr_uint:
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == 10:
            count += 1
        i += 1
    if source.len > 0 and source.byte_at(source.len - 1) != 10:
        count += 1
    return count
