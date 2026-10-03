## Code actions — quick fixes derived from the diagnostics the client sends
## with the request context.  Mirrors the host's per-diagnostic branches
## (`lsp/server/code_actions.rb:29-297`): the cast action, the fix-engine
## rules, `line-too-long`, the shadow annotation, `unused-param`, the dead
## assignment, the unsafe wrap, the match arms and the import suggestion.
## Every action echoes the request's diagnostic object and carries the host's
## title (`tooling/linter.rb`'s `STATIC_QUICK_FIX_TITLES`), and `source.fixAll`
## applies the whole fix engine like `mtc lint --fix`.

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.formatter.tidy as tidy
import mtc.linter.fix_engine as fix_engine
import mtc.linter.linter as linter_mod
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
    defer: file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response_raw(id, "[]")
        return
    defer: content.release()

    let source = content.as_str()

    var only_kinds = extract_only_kinds(params)
    var want_quickfix = only_kinds.len == 0
    var want_fixall = false
    if only_kinds.len > 0:
        var ki: ptr_uint = 0
        while ki < only_kinds.len:
            let kp = only_kinds.get(ki) else:
                break
            let k = unsafe: read(kp)
            # The spec spelling is `quickfix`; the host checks the camelCase
            # `quickFix`, so both are accepted here.
            if k.starts_with("quickfix") or k.starts_with("quickFix"):
                want_quickfix = true
            if k.starts_with("source"):
                want_fixall = true
            ki += 1

    # source.fixAll: apply all lint auto-fixes at once.
    if want_fixall:
        # Lint and fix with the same options the diagnostics use, so a fix can
        # never rewrite a binding whose `var` an editable method call requires,
        # and `.mt-lint.yml` filters apply as they do everywhere else.
        var options = linter_mod.default_lint_options()
        var maybe_entry = workspace.analysis_entry_for(ws, file_path.as_str())
        if maybe_entry.is_some():
            let entry_ptr = maybe_entry.unwrap()
            unsafe:
                options.owning_type_names = read(entry_ptr).program.owning_type_span()
                var unresolved_owner = vec.Vec[str].create()
                defer: unresolved_owner.release()
                var ui: ptr_uint = 0
                while ui < read(entry_ptr).program.unresolved_import_paths.len():
                    let up = read(entry_ptr).program.unresolved_import_paths.get(ui) else:
                        break
                    unresolved_owner.push(read(up).as_str())
                    ui += 1
                options.unresolved_import_paths = unresolved_owner.as_span()
                options.editable_sites = read(entry_ptr).analysis.editable_receiver_sites.as_span()
                options.analysis = ptr_of(read(entry_ptr).analysis)

        var fixed = fix_engine.fix_source(source, file_path.as_str(), options)
        defer: fixed.release()
        if not fixed.as_str().equal(source):
            let lines = ptr_uint<-(line_count(source))
            var result = string.String.create()
            result.append("[{\"title\":\"Apply all auto-fixes\",\"kind\":\"source.fixAll\",\"edit\":{\"changes\":{\"")
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
    defer: json_text.release()
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


## The host's `STATIC_QUICK_FIX_TITLES` (`tooling/linter.rb:91-105`).  An
## unknown code has no title — the host's lookup returns nil and the action is
## emitted with a JSON null title (`unused-import`).
function quick_fix_title(code: str) -> str:
    if code.equal("line-too-long"):
        return "Wrap long line"
    if code.equal("prefer-let"):
        return "Replace 'var' with 'let'"
    if code.equal("redundant-ignored-match-binding"):
        return "Remove redundant as _"
    if code.equal("redundant-bool-compare"):
        return "Simplify boolean comparison"
    if code.equal("redundant-cast"):
        return "Remove redundant cast"
    if code.equal("redundant-else"):
        return "Remove redundant else"
    if code.equal("redundant-return"):
        return "Remove redundant return"
    if code.equal("redundant-type-annotation"):
        return "Remove redundant type annotation"
    if code.equal("redundant-unsafe"):
        return "Remove redundant unsafe"
    if code.equal("prefer-let-else"):
        return "Rewrite as let-else"
    if code.equal("prefer-var-else"):
        return "Rewrite as var-else"
    if code.equal("prefer-inline-methods"):
        return "Inline methods into struct"
    if code.equal("trailing-list-comma"):
        return "Remove trailing list comma"
    return ""


## True for the codes the host routes through its fix engine
## (`code_actions.rb:99-101`); the fix engine has more generators than the
## code-action dispatch offers.
function is_engine_quickfix_code(code: str) -> bool:
    if code.equal("prefer-let") or code.equal("redundant-ignored-match-binding"):
        return true
    if code.equal("prefer-let-else") or code.equal("prefer-var-else"):
        return true
    if code.equal("redundant-bool-compare") or code.equal("redundant-else"):
        return true
    if code.equal("redundant-return") or code.equal("unused-import"):
        return true
    return code.equal("trailing-list-comma")


## Emit the CodeActions for one diagnostic, in the host's order
## (`lsp/server/code_actions.rb:29-297`): the cast action first (any
## `cannot assign … expected …` message), then the per-code branch, then the
## message-driven unsafe-wrap, match-arm and import actions.
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
            var message: str = ""
            match extract_diagnostic_message(diag):
                Option.some as m:
                    message = m.value
                Option.none:
                    pass

            append_cast_expression_fix(json_text, emitted, uri, source, diag, info, message)

            if info.code.equal("reserved-primitive-name") or is_engine_quickfix_code(info.code):
                append_engine_fix(json_text, emitted, uri, source, diag, info, message)
            else if info.code.equal("line-too-long"):
                append_line_wrap_fix(json_text, emitted, uri, source, diag, info)
            else if info.code.equal("shadow"):
                append_shadow_annotate_action(json_text, emitted, diag)
            else if info.code.equal("unused-param"):
                append_rename_param_fix(json_text, emitted, uri, source, diag, info)
            else if info.code.equal("dead-assignment"):
                append_dead_assignment_fix(json_text, emitted, uri, diag, info)
            else:
                append_message_driven_fix(json_text, emitted, uri, source, diag, info, message)


## The host's `else` branch (`code_actions.rb:201-297`): the unsafe wrap, the
## match arms and the import suggestion, each gated on the message text.
function append_message_driven_fix(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    uri: str,
    source: str,
    diag: json.Value,
    info: DiagnosticInfo,
    message: str,
) -> void:
    if message.equal("pointer cast requires unsafe") or message.equal("ref to pointer cast requires unsafe"):
        append_unsafe_wrap_fix(json_text, emitted, uri, source, diag, info)
        return
    if message.starts_with("match on "):
        append_match_arms_fix(json_text, emitted, uri, source, diag, info, message)
        return
    if is_unknown_name_message(message):
        append_import_fix(json_text, emitted, uri, diag)


## The host's `\Aunknown (?:type|callable) (\S+)\z`: the message names exactly
## one unknown symbol.
function is_unknown_name_message(message: str) -> bool:
    var rest: str = ""
    if message.starts_with("unknown type "):
        rest = message.slice(13, message.len - 13)
    else if message.starts_with("unknown callable "):
        rest = message.slice(17, message.len - 17)
    else:
        return false
    if rest.len == 0:
        return false
    var i: ptr_uint = 0
    while i < rest.len:
        let b = rest.byte_at(i)
        if b == ' ' or b == '\t' or b == '\n':
            return false
        i += 1
    return true


## Emit one quickfix CodeAction: the title (JSON null when `has_title` is
## false), the diagnostic echoed back the way a client sent it, and — unless
## this is the shadow annotation — one text edit.
function emit_quickfix_action(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    diag: json.Value,
    has_title: bool,
    title: str,
    has_edit: bool,
    uri: str,
    start_line: ptr_uint,
    start_char: ptr_uint,
    end_line: ptr_uint,
    end_char: ptr_uint,
    new_text: str,
) -> void:
    if unsafe: read(emitted) > 0:
        json_text.append(",")
    unsafe:
        read(emitted) = read(emitted) + 1

    json_text.append("{\"title\":")
    if has_title:
        json_text.append("\"")
        proto.append_escaped(json_text, title)
        json_text.append("\"")
    else:
        json_text.append("null")
    json_text.append(",\"kind\":\"quickFix\"")
    append_diag_echo(json_text, diag)
    if has_edit:
        json_text.append(",\"edit\":{\"changes\":{\"")
        proto.append_escaped(json_text, uri)
        json_text.append("\":[{\"range\":{\"start\":{\"line\":")
        json_text.append_format(f"#{start_line}")
        json_text.append(",\"character\":")
        json_text.append_format(f"#{start_char}")
        json_text.append("},\"end\":{\"line\":")
        json_text.append_format(f"#{end_line}")
        json_text.append(",\"character\":")
        json_text.append_format(f"#{end_char}")
        json_text.append("}},\"newText\":\"")
        proto.append_escaped(json_text, new_text)
        json_text.append("\"}]}}")
    json_text.append("}")


## Echo the request's diagnostic object on the action, as the host's
## `diagnostics: [diag]` does.
function append_diag_echo(json_text: ref[string.String], diag: json.Value) -> void:
    json_text.append(",\"diagnostics\":[")
    match json.render(diag):
        Result.failure as failure_payload:
            var err = failure_payload.error
            err.release()
            json_text.append("null")
        Result.success as payload:
            var rendered = payload.value
            defer: rendered.release()
            json_text.append(rendered.as_str())
    json_text.append("]")


## `Cast expression to T` for a `cannot assign … expected T` diagnostic — the
## host's cast quickfix (`code_actions.rb:38-67`): the line's first `=` splits
## the assignment, a simple operand is cast bare and anything else is
## parenthesized.  The host prefixes the line's indent to the already indented
## left-hand side (the output keeps both), so the self does too.
function append_cast_expression_fix(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    uri: str,
    source: str,
    diag: json.Value,
    info: DiagnosticInfo,
    message: str,
) -> void:
    if not message.starts_with("cannot assign "):
        return
    let expected = text_after_last(message, "expected ")
    if expected.len == 0:
        return
    let line = cursor.source_line(source, info.line + 1)
    if line.len == 0:
        return
    let equation = line.find_byte('=') else:
        return
    let rhs = line.slice(equation + 1, line.len - equation - 1).trim_ascii_whitespace()
    if rhs.len == 0:
        return
    var cast_prefix = string.String.create()
    defer: cast_prefix.release()
    cast_prefix.append(expected)
    cast_prefix.append("<-")
    if rhs.starts_with(cast_prefix.as_str()):
        return

    let indent_len = utils.indent_of(line)
    let indent = line.slice(0, indent_len)
    let lhs = line.slice(0, equation + 1)

    var new_line = string.String.create()
    defer: new_line.release()
    new_line.append(indent)
    new_line.append(lhs)
    new_line.append(" ")
    if is_simple_cast_value(rhs):
        new_line.append(cast_prefix.as_str())
        new_line.append(rhs)
    else:
        new_line.append(cast_prefix.as_str())
        new_line.append("(")
        new_line.append(rhs)
        new_line.append(")")
    new_line.append("\n")

    var title = string.String.create()
    defer: title.release()
    title.append("Cast expression to ")
    title.append(expected)
    emit_quickfix_action(json_text, emitted, diag, true, title.as_str(), true,
        uri, info.line, 0, info.line + 1, 0, new_line.as_str())


## The substring after the last occurrence of `needle`, or "" when absent.
function text_after_last(text: str, needle: str) -> str:
    var found: ptr_uint = 0
    var have = false
    var search: ptr_uint = 0
    while search < text.len:
        let rel = text.slice(search, text.len - search).find_substring(needle) else:
            break
        found = search + rel
        have = true
        search = found + needle.len
    if not have:
        return ""
    let start = found + needle.len
    return text.slice(start, text.len - start).trim_ascii_whitespace()


## True for the host's "simple value" cast operand: a dotted identifier or a
## numeric literal (`code_actions.rb:46`).
function is_simple_cast_value(text: str) -> bool:
    if text.len == 0:
        return false
    let first = text.byte_at(0)
    if (first >= '0' and first <= '9') or first == '.':
        return is_simple_number(text)
    return is_dotted_identifier(text)


function is_dotted_identifier(text: str) -> bool:
    var expect_start = true
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if expect_start:
            if not is_name_start(b):
                return false
            expect_start = false
        else if b == '.':
            expect_start = true
        else if not is_name_continue(b):
            return false
        i += 1
    return not expect_start


function is_simple_number(text: str) -> bool:
    let first = text.byte_at(0)
    if text.len > 2 and first == '0':
        let second = text.byte_at(1)
        if second == 'x' or second == 'b' or second == 'o':
            var i: ptr_uint = 2
            while i < text.len:
                let b = text.byte_at(i)
                if not is_hex_digit(b) and b != '_':
                    return false
                i += 1
            return text.len > 2
    var digits = false
    var dots = 0
    var i: ptr_uint = 0
    while i < text.len:
        let b = text.byte_at(i)
        if b >= '0' and b <= '9':
            digits = true
        else if b == '_':
            pass
        else if b == '.':
            dots += 1
            if dots > 1:
                return false
        else:
            return false
        i += 1
    return digits


function is_name_start(b: ubyte) -> bool:
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or b == '_'


function is_name_continue(b: ubyte) -> bool:
    return is_name_start(b) or (b >= '0' and b <= '9')


function is_hex_digit(b: ubyte) -> bool:
    return (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F')


## The shadow warning's annotation-only action — the host offers the rename as
## a client-side refactor and attaches no edit (`code_actions.rb:144-151`).
function append_shadow_annotate_action(json_text: ref[string.String], emitted: ref[ptr_uint], diag: json.Value) -> void:
    emit_quickfix_action(json_text, emitted, diag, true, "Add '_' prefix to suppress shadow warning",
        false, "", 0, 0, 0, 0, "")


## `unused-param` → replace the parameter's token with its `_`-prefixed name
## (`code_actions.rb:153-177`).
function append_rename_param_fix(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    uri: str,
    source: str,
    diag: json.Value,
    info: DiagnosticInfo,
) -> void:
    let line = cursor.source_line(source, info.line + 1)
    if line.len == 0:
        return
    if info.end_char > line.len or info.end_char <= info.start_char:
        return
    let token = line.slice(info.start_char, info.end_char - info.start_char).trim_ascii_whitespace()
    if token.len == 0 or token.starts_with("_"):
        return

    var replacement = string.String.create()
    defer: replacement.release()
    replacement.append("_")
    var ti: ptr_uint = 0
    while ti < token.len and token.byte_at(ti) == '_':
        ti += 1
    replacement.append(token.slice(ti, token.len - ti))

    var title = string.String.create()
    defer: title.release()
    title.append("Rename parameter '")
    title.append(token)
    title.append("' to '")
    title.append(replacement.as_str())
    title.append("'")
    emit_quickfix_action(json_text, emitted, diag, true, title.as_str(), true,
        uri, info.line, info.start_char, info.line, info.end_char, replacement.as_str())


## `Import <path>` for an `unknown type`/`unknown callable` diagnostic whose
## data carries a "did you mean '<path>'?" suggestion (`code_actions.rb:265-294`).
function append_import_fix(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    uri: str,
    diag: json.Value,
) -> void:
    let suggestion = extract_diagnostic_suggestion(diag)
    if suggestion.len == 0:
        return
    let quote = suggestion.find_substring("did you mean ") else:
        return
    let rest = suggestion.slice(quote + 13, suggestion.len - quote - 13)
    if rest.len < 3:
        return
    let opener = rest.byte_at(0)
    if opener != '\'' and opener != '"':
        return
    let tail = rest.slice(1, rest.len - 1)
    let close = tail.find_byte(opener) else:
        return
    let full_path = rest.slice(1, close)
    if full_path.len == 0:
        return
    var last_dot = full_path.len + 1
    var count: ptr_uint = 1
    var i: ptr_uint = 0
    while i < full_path.len:
        if full_path.byte_at(i) == '.':
            last_dot = i
            count += 1
        i += 1
    if count < 2:
        return
    var import_module = full_path.slice(0, last_dot)

    var new_text = string.String.create()
    defer: new_text.release()
    new_text.append("import ")
    new_text.append(import_module)
    new_text.append("\n")

    var title = string.String.create()
    defer: title.release()
    title.append("Import ")
    title.append(full_path)
    emit_quickfix_action(json_text, emitted, diag, true, title.as_str(), true, uri, 0, 0, 0, 0, new_text.as_str())


## Add missing match arm stubs for each case named in the message.
## Message format: "match on <type> is missing cases: A, B, C"
function append_match_arms_fix(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    uri: str,
    source: str,
    diag: json.Value,
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
    defer: new_text.release()

    # Build the new arm text and the title's case list.
    var arm_list = string.String.create()
    defer: arm_list.release()
    var arm_count: ptr_uint = 0
    var si: ptr_uint = 0
    var seg_start: ptr_uint = 0
    while si <= cases_str.len:
        if si == cases_str.len or cases_str.byte_at(si) == ',':
            let arm_name = cases_str.slice(seg_start, si - seg_start).trim_ascii_whitespace()
            if arm_name.len > 0:
                if arm_count > 0:
                    arm_list.append(", ")
                arm_list.append(arm_name)
                arm_count += 1
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

    # Insert after the match statement's last line — the host's
    # `find_match_end_line` — falling back to the diagnostic's line.
    let insert_line = match_end_line(source, info.line)

    var title = string.String.create()
    defer: title.release()
    title.append("Add missing match ")
    if arm_count == 1:
        title.append("arm")
    else:
        title.append("arms")
    title.append(": ")
    title.append(arm_list.as_str())
    emit_quickfix_action(json_text, emitted, diag, true, title.as_str(), true,
        uri, insert_line, 0, insert_line, 0, new_text.as_str())


## The first line after `match_line` whose indentation is at or below the match
## statement's, skipping blank lines; `match_line` when the file ends first —
## the host's `find_match_end_line`.
function match_end_line(source: str, match_line: ptr_uint) -> ptr_uint:
    let match_indent = utils.indent_of(cursor.source_line(source, match_line + 1))
    let total = line_count(source)
    var line = match_line + 1
    while line < total:
        let text = cursor.source_line(source, line + 1)
        if text.trim_ascii_whitespace().len == 0:
            line += 1
            continue
        if utils.indent_of(text) <= match_indent:
            return line
        line += 1
    return match_line


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


## The diagnostic's `data.suggestion` string ("" when absent).
function extract_diagnostic_suggestion(diag: json.Value) -> str:
    unsafe:
        let diag_obj = diag.as_object()
        if diag_obj == null:
            return ""
        let data_ptr = read(diag_obj).get("data")
        if data_ptr == null:
            return ""
        let data_obj = read(data_ptr).as_object()
        if data_obj == null:
            return ""
        let suggestion_ptr = read(data_obj).get("suggestion")
        if suggestion_ptr == null:
            return ""
        let suggestion = read(suggestion_ptr).as_string() else:
            return ""
        return suggestion


## Remove the entire line of a dead assignment.
function append_dead_assignment_fix(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    uri: str,
    diag: json.Value,
    info: DiagnosticInfo,
) -> void:
    emit_quickfix_action(json_text, emitted, diag, true, "Remove dead assignment", true,
        uri, info.line, 0, info.line + 1, 0, "")


## Wrap a statement in an `unsafe:` block — the host wraps the body on its own
## line indented one level (`code_actions.rb:204-229`).
function append_unsafe_wrap_fix(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    uri: str,
    source: str,
    diag: json.Value,
    info: DiagnosticInfo,
) -> void:
    let line_text = cursor.source_line(source, info.line + 1)
    if line_text.trim_ascii_whitespace().equal("unsafe:"):
        return
    let indent_len = utils.indent_of(line_text)
    let indent = line_text.slice(0, indent_len)
    let body = line_text.trim_ascii_whitespace()
    if body.len == 0:
        return

    var new_text = string.String.create()
    defer: new_text.release()
    new_text.append(indent)
    new_text.append("unsafe:\n")
    new_text.append(indent)
    new_text.append("    ")
    new_text.append(body)
    new_text.append("\n")
    emit_quickfix_action(json_text, emitted, diag, true, "Wrap statement in unsafe block", true,
        uri, info.line, 0, info.line + 1, 0, new_text.as_str())


## `line-too-long` fix: replace the line with the formatter's wrapped version
## (host `lsp/server/code_actions.rb:118-142`).
function append_line_wrap_fix(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    uri: str,
    source: str,
    diag: json.Value,
    info: DiagnosticInfo,
) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        return
    defer: file_path.release()
    let max_line_length = tidy.resolve_max_line_length(file_path.as_str(), 0)
    let maybe_fix = tidy.build_long_line_wrap_fix(source, info.line, max_line_length, file_path.as_str(), true)
    if maybe_fix.is_none():
        return
    var fix = maybe_fix.unwrap()
    defer: fix.new_text.release()

    emit_quickfix_action(json_text, emitted, diag, true, quick_fix_title(info.code), true,
        uri, info.line, 0, info.line + 1, 0, fix.new_text.as_str())


## The linter's fix-engine quickfix: the host routes the codes in
## `is_engine_quickfix_code` (plus `reserved-primitive-name`) through its fix
## engine and titles the action from `STATIC_QUICK_FIX_TITLES` — which has no
## entry for `unused-import`, so that action carries a null title.
function append_engine_fix(
    json_text: ref[string.String],
    emitted: ref[ptr_uint],
    uri: str,
    source: str,
    diag: json.Value,
    info: DiagnosticInfo,
    message: str,
) -> void:
    match fix_engine.lsp_edit_for_warning(source, info.code, info.line + 1, info.start_char + 1, message):
        Option.none:
            return
        Option.some as edit_payload:
            var edit = edit_payload.value
            defer: edit.new_text.release()
            let title = quick_fix_title(info.code)
            emit_quickfix_action(json_text, emitted, diag, title.len > 0, title, true,
                uri, edit.start_line, edit.start_char, edit.end_line, edit.end_char, edit.new_text.as_str())


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
