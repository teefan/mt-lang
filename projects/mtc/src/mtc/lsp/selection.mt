## Selection ranges — expand-selection hierarchy per cursor position:
## word → line → statement (same-indent run) → enclosing indent block.
## Indentation-based like the Ruby LSP's selection_range.rb (with its
## token-range line bug corrected: ranges stay on the request line).

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.lsp.folding as folding
import mtc.lsp.utils as utils
import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


struct LineRange:
    start_line: ptr_uint
    end_line: ptr_uint
    end_character: ptr_uint


## Handle textDocument/selectionRange.  `positions` carries the request's
## (line, character) pairs flattened in order.
public function handle_selection_range(
    ws: ref[workspace.Workspace],
    uri: str,
    positions: span[ptr_uint],
    id: json.Value,
) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer content.release()

    var lines = utils.split_lines(content.as_str())
    defer lines.release()

    var json_text = string.String.create()
    defer json_text.release()
    json_text.append("[")
    var pi: ptr_uint = 0
    while pi + 1 < positions.len:
        let line = unsafe: read(positions.data + pi)
        let character = unsafe: read(positions.data + pi + 1)
        if pi > 0:
            json_text.append(",")
        append_selection_range(ref_of(json_text), ref_of(lines), line, character)
        pi += 2
    json_text.append("]")
    proto.write_response_raw(id, json_text.as_str())


function append_selection_range(
    json_text: ref[string.String],
    lines: ref[vec.Vec[str]],
    line: ptr_uint,
    character: ptr_uint,
) -> void:
    let line_text = utils.line_at(lines, line)
    if line_text.len == 0:
        json_text.append("null")
        return

    var depth: ptr_uint = 0

    # Innermost: the word under the cursor when there is one.
    match word_bounds(line_text, character):
        Option.some as bounds:
            append_range_open(json_text, line, bounds.value.start_char, line, bounds.value.end_char)
            depth += 1
        Option.none:
            pass

    # The full line.
    append_range_open(json_text, line, 0, line, line_text.len)
    depth += 1

    # The same-indent statement run and the enclosing indent block.
    match statement_range(lines, line):
        Option.some as stmt:
            append_range_open(json_text, stmt.value.start_line, 0, stmt.value.end_line, stmt.value.end_character)
            depth += 1
            match enclosing_block_range(lines, line):
                Option.some as block:
                    append_range_open(
                        json_text,
                        block.value.start_line,
                        0,
                        block.value.end_line,
                        block.value.end_character
                    )
                    depth += 1
                Option.none:
                    pass
        Option.none:
            pass

    # Close the nested {"range":..,"parent": chain.
    var di: ptr_uint = 0
    while di < depth:
        json_text.append("}")
        di += 1


## Emit `{"range":{...}` and leave the object open; nested parents follow as
## `,"parent":{"range":{...}` fragments.
function append_range_open(
    json_text: ref[string.String],
    start_line: ptr_uint,
    start_char: ptr_uint,
    end_line: ptr_uint,
    end_char: ptr_uint,
) -> void:
    if not json_text.ends_with("[") and not json_text.ends_with(","):
        json_text.append(",\"parent\":")
    json_text.append("{\"range\":{\"start\":{\"line\":")
    json_text.append_format(f"#{start_line}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{start_char}")
    json_text.append("},\"end\":{\"line\":")
    json_text.append_format(f"#{end_line}")
    json_text.append(",\"character\":")
    json_text.append_format(f"#{end_char}")
    json_text.append("}}")


struct WordBounds:
    start_char: ptr_uint
    end_char: ptr_uint


## Identifier-character bounds around `character` on the line.
function word_bounds(line_text: str, character: ptr_uint) -> Option[WordBounds]:
    if line_text.len == 0:
        return Option[WordBounds].none
    var col = character
    if col >= line_text.len:
        col = line_text.len - 1
    if not utils.is_word_byte(line_text.byte_at(col)):
        return Option[WordBounds].none
    var left = col
    while left > 0 and utils.is_word_byte(line_text.byte_at(left - 1)):
        left -= 1
    var right = col
    while right + 1 < line_text.len and utils.is_word_byte(line_text.byte_at(right + 1)):
        right += 1
    return Option[WordBounds].some(value = WordBounds(start_char = left, end_char = right + 1))


## The run of lines at >= the cursor line's indent that forms one statement
## group.
function statement_range(lines: ref[vec.Vec[str]], line: ptr_uint) -> Option[LineRange]:
    let indent = utils.indent_of(utils.line_at(lines, line))

    var start_line = line
    while start_line > 0:
        let prev = utils.line_at(lines, start_line - 1)
        if utils.is_blank(prev):
            break
        if utils.indent_of(prev) < indent:
            break
        start_line -= 1

    var end_line = line
    while end_line + 1 < lines.len():
        let next = utils.line_at(lines, end_line + 1)
        if not utils.is_blank(next) and utils.indent_of(next) <= indent:
            break
        end_line += 1

    if start_line == end_line and utils.is_blank(utils.line_at(lines, start_line)):
        return Option[LineRange].none
    return Option[LineRange].some(value = LineRange(
        start_line = start_line,
        end_line = end_line,
        end_character = utils.line_at(lines, end_line).len
    ))


## The enclosing indentation block: every contiguous line indented at least
## as deep as the cursor line, plus its header line.
function enclosing_block_range(lines: ref[vec.Vec[str]], line: ptr_uint) -> Option[LineRange]:
    let indent = utils.indent_of(utils.line_at(lines, line))
    if indent == 0:
        return Option[LineRange].none

    var start_line = line
    while start_line > 0:
        let prev = utils.line_at(lines, start_line - 1)
        if not utils.is_blank(prev) and utils.indent_of(prev) < indent:
            start_line -= 1
            break
        start_line -= 1

    var end_line = line
    while end_line + 1 < lines.len():
        let next = utils.line_at(lines, end_line + 1)
        if not utils.is_blank(next) and utils.indent_of(next) < indent:
            break
        end_line += 1

    if start_line == end_line:
        return Option[LineRange].none
    return Option[LineRange].some(value = LineRange(
        start_line = start_line,
        end_line = end_line,
        end_character = utils.line_at(lines, end_line).len
    ))





