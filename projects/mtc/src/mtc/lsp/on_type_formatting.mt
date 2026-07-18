## On-type formatting — indent assist after newline.  When the previous
## non-blank line opens a block (`... :`), the new line is indented one level
## deeper; otherwise it aligns with the previous line, dropping back to the
## following line's indent when that line dedents.  Port of the Ruby LSP's
## on_type_formatting.rb.

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.lsp.folding as folding
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


## Handle textDocument/onTypeFormatting.  Only the "\n" trigger produces
## edits.
public function handle_on_type_formatting(
    ws: ref[workspace.Workspace],
    uri: str,
    line: ptr_uint,
    trigger: str,
    id: json.Value,
) -> void:
    if not trigger.equal("\n"):
        proto.write_response_raw(id, "[]")
        return

    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response_raw(id, "[]")
        return
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response_raw(id, "[]")
        return
    defer content.release()

    var lines = folding.split_lines(content.as_str())
    defer lines.release()

    if line == 0 or line >= lines.len():
        proto.write_response_raw(id, "[]")
        return

    # The previous non-blank line drives the indent.
    var prev_index = line - 1
    while prev_index > 0 and is_blank(line_at(ref_of(lines), prev_index)):
        prev_index -= 1
    let prev_line = line_at(ref_of(lines), prev_index)
    if is_blank(prev_line):
        proto.write_response_raw(id, "[]")
        return

    let prev_indent = indent_of(prev_line)
    var indent = prev_indent
    let prev_stripped = strip_indent(prev_line)
    if prev_stripped.ends_with(":") and opens_block(prev_stripped):
        indent = prev_indent + 4

    # When the next non-blank line dedents below the target, follow it.
    var below_index = line + 1
    while below_index < lines.len() and is_blank(line_at(ref_of(lines), below_index)):
        below_index += 1
    if below_index < lines.len():
        let below_line = line_at(ref_of(lines), below_index)
        let below_indent = indent_of(below_line)
        if below_indent < indent and not strip_indent(below_line).ends_with(":"):
            indent = below_indent

    let current_line = line_at(ref_of(lines), line)
    let current_indent = indent_of(current_line)
    if indent == current_indent:
        proto.write_response_raw(id, "[]")
        return

    var json_text = string.String.create()
    defer json_text.release()
    json_text.append("[{\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{line}")
    json_text.append(",\"character\":0},\"end\":{\"line\":")
    json_text.append_format(f"#{line}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{current_indent}")
    json_text.append("}},\"newText\":\"")
    var si: ptr_uint = 0
    while si < indent:
        json_text.append(" ")
        si += 1
    json_text.append("\"}]")
    proto.write_response_raw(id, json_text.as_str())


## True when the line's first word is a block-introducing keyword.
function opens_block(stripped: str) -> bool:
    var word_end: ptr_uint = 0
    while word_end < stripped.len and is_word_byte(stripped.byte_at(word_end)):
        word_end += 1
    if word_end == 0:
        return false
    let first_word = stripped.slice(0, word_end)
    return first_word.equal("function") or first_word.equal("async") or first_word.equal("editable") or
        first_word.equal("const") or first_word.equal("public") or first_word.equal("struct") or
        first_word.equal("enum") or first_word.equal("flags") or first_word.equal("variant") or
        first_word.equal("union") or first_word.equal("interface") or first_word.equal("if") or
        first_word.equal("else") or first_word.equal("while") or first_word.equal("for") or
        first_word.equal("match") or first_word.equal("unsafe") or first_word.equal("extending") or
        first_word.equal("defer") or first_word.equal("when")


function line_at(lines: ref[vec.Vec[str]], index: ptr_uint) -> str:
    let lp = lines.get(index) else:
        return ""
    return unsafe: read(lp)


function indent_of(line_text: str) -> ptr_uint:
    var count: ptr_uint = 0
    while count < line_text.len and line_text.byte_at(count) == 32:
        count += 1
    return count


function strip_indent(line_text: str) -> str:
    let indent = indent_of(line_text)
    return line_text.slice(indent, line_text.len - indent)


function is_blank(line_text: str) -> bool:
    return line_text.trim_ascii_whitespace().len == 0


function is_word_byte(ch: ubyte) -> bool:
    return (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122) or ch == 95
