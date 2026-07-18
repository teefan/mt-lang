## Folding ranges — indentation-based block folds plus import and block
## comment runs.  A direct port of the Ruby LSP's folding_range.rb: pure
## line/indent arithmetic, no parser involvement, so folds stay available
## while the document has syntax errors.

import std.fmt
import std.json as json
import std.str
import std.string as string
import std.vec as vec

import mtc.lsp.protocol as proto
import mtc.lsp.uri as uri_ops
import mtc.lsp.workspace as workspace


struct FoldRange:
    start_line: ptr_uint
    end_line: ptr_uint
    kind: str


struct BlockStart:
    line: ptr_uint
    indent: ptr_uint


## Handle textDocument/foldingRange.
public function handle_folding_range(ws: ref[workspace.Workspace], uri: str, id: json.Value) -> void:
    var file_path = uri_ops.file_uri_to_path(uri) else:
        proto.write_response(id, json.null_value())
        return
    defer file_path.release()

    var content = ws.document_source(file_path.as_str()) else:
        proto.write_response(id, json.null_value())
        return
    defer content.release()

    var lines = split_lines(content.as_str())
    defer lines.release()

    var folds = vec.Vec[FoldRange].create()
    defer folds.release()

    compute_block_folds(ref_of(lines), ref_of(folds))
    compute_import_folds(ref_of(lines), ref_of(folds))
    compute_comment_folds(ref_of(lines), ref_of(folds))
    trim_trailing_blank_lines(ref_of(folds), ref_of(lines))

    var json_text = string.String.create()
    defer json_text.release()
    json_text.append("[")
    var fi: ptr_uint = 0
    while fi < folds.len():
        let fp = folds.get(fi) else:
            break
        let fold = unsafe: read(fp)
        if fi > 0:
            json_text.append(",")
        json_text.append("{\"startLine\":")
        json_text.append_format(f"#{fold.start_line}")
        json_text.append(",\"endLine\":")
        json_text.append_format(f"#{fold.end_line}")
        if fold.kind.len > 0:
            json_text.append(",\"kind\":\"")
            json_text.append(fold.kind)
            json_text.append("\"")
        json_text.append("}")
        fi += 1
    json_text.append("]")
    proto.write_response_raw(id, json_text.as_str())


## Indentation-block folds: a block-opening line folds until the next line
## at the same or lower indent.  `else`/`when` arms close and reopen at the
## same indent instead of nesting.
function compute_block_folds(lines: ref[vec.Vec[str]], folds: ref[vec.Vec[FoldRange]]) -> void:
    var stack = vec.Vec[BlockStart].create()
    defer stack.release()
    var last_indent: ptr_uint = 0

    var line_num: ptr_uint = 0
    while line_num < lines.len():
        let lp = lines.get(line_num) else:
            break
        let line = unsafe: read(lp)
        let stripped = lstrip(line)
        if stripped.len == 0:
            line_num += 1
            continue

        let indent = line.len - stripped.len
        let code = strip_comment(stripped)

        if indent < last_indent:
            while stack.len() > 0:
                let top = stack.last() else:
                    break
                if unsafe: read(top).indent < indent:
                    break
                let popped = stack.pop()
                match popped:
                    Option.some as p:
                        if line_num - 1 > p.value.line:
                            folds.push(FoldRange(start_line = p.value.line, end_line = line_num - 1, kind = ""))
                    Option.none:
                        break

        if continuation_start(code):
            let top = stack.last()
            if top != null:
                if unsafe: read(top).indent == indent:
                    let popped = stack.pop()
                    match popped:
                        Option.some as p:
                            if line_num - 1 > p.value.line:
                                folds.push(FoldRange(start_line = p.value.line, end_line = line_num - 1, kind = ""))
                        Option.none:
                            pass
            stack.push(BlockStart(line = line_num, indent = indent))
        else if block_start(code):
            stack.push(BlockStart(line = line_num, indent = indent))

        last_indent = indent
        line_num += 1

    if lines.len() == 0:
        return
    let last_line = lines.len() - 1
    while stack.len() > 0:
        let popped = stack.pop()
        match popped:
            Option.some as p:
                if last_line > p.value.line:
                    folds.push(FoldRange(start_line = p.value.line, end_line = last_line, kind = ""))
            Option.none:
                break


## Consecutive `import` lines fold as one imports region.
function compute_import_folds(lines: ref[vec.Vec[str]], folds: ref[vec.Vec[FoldRange]]) -> void:
    var have_start = false
    var import_start: ptr_uint = 0

    var line_num: ptr_uint = 0
    while line_num < lines.len():
        let lp = lines.get(line_num) else:
            break
        let stripped = lstrip(unsafe: read(lp))
        if stripped.starts_with("import "):
            if not have_start:
                have_start = true
                import_start = line_num
        else:
            if have_start and line_num - 1 > import_start:
                folds.push(FoldRange(start_line = import_start, end_line = line_num - 1, kind = "imports"))
            have_start = false
        line_num += 1

    if have_start and lines.len() > 0:
        let last_line = lines.len() - 1
        if last_line > import_start:
            folds.push(FoldRange(start_line = import_start, end_line = last_line, kind = "imports"))


## `#>` ... `<#` block comment runs fold as comment regions.
function compute_comment_folds(lines: ref[vec.Vec[str]], folds: ref[vec.Vec[FoldRange]]) -> void:
    var have_start = false
    var comment_start: ptr_uint = 0

    var line_num: ptr_uint = 0
    while line_num < lines.len():
        let lp = lines.get(line_num) else:
            break
        let stripped = lstrip(unsafe: read(lp))
        if stripped.starts_with("#>") and not have_start:
            have_start = true
            comment_start = line_num
        else if have_start and stripped.contains_substring("<#"):
            folds.push(FoldRange(start_line = comment_start, end_line = line_num, kind = "comment"))
            have_start = false
        line_num += 1


function trim_trailing_blank_lines(folds: ref[vec.Vec[FoldRange]], lines: ref[vec.Vec[str]]) -> void:
    var fi: ptr_uint = 0
    while fi < folds.len():
        let fp = folds.get(fi) else:
            break
        unsafe:
            var end_line = read(fp).end_line
            while end_line > read(fp).start_line:
                let lp = lines.get(end_line) else:
                    break
                if lstrip(read(lp)).trim_ascii_whitespace().len == 0:
                    end_line -= 1
                else:
                    break
            read(fp).end_line = end_line
        fi += 1


## True when the comment-stripped line opens a foldable block
## (`function foo():`, `if x:`, `extending T:` ...).
function block_start(code: str) -> bool:
    if not code.ends_with(":"):
        return false
    if continuation_start(code):
        return false

    var rest = code
    rest = skip_keyword(rest, "public")
    rest = skip_keyword(rest, "async")
    rest = skip_keyword(rest, "editable")
    return starts_with_keyword(rest, "function") or starts_with_keyword(rest, "struct") or
        starts_with_keyword(rest, "enum") or starts_with_keyword(rest, "flags") or
        starts_with_keyword(rest, "variant") or starts_with_keyword(rest, "union") or
        starts_with_keyword(rest, "interface") or starts_with_keyword(rest, "if") or
        starts_with_keyword(rest, "while") or starts_with_keyword(rest, "for") or
        starts_with_keyword(rest, "match") or starts_with_keyword(rest, "unsafe") or
        starts_with_keyword(rest, "extending") or starts_with_keyword(rest, "defer")


## True when the line is a continuation arm that closes the previous block
## at the same indent (`else:`, `else if x:`, `when x:`).
function continuation_start(code: str) -> bool:
    if not code.ends_with(":"):
        return false
    return starts_with_keyword(code, "else") or starts_with_keyword(code, "when")


## `text` starts with keyword `kw` at a word boundary.
function starts_with_keyword(text: str, kw: str) -> bool:
    if not text.starts_with(kw):
        return false
    if text.len == kw.len:
        return true
    let next_byte = text.byte_at(kw.len)
    return not ((next_byte >= 65 and next_byte <= 90) or (next_byte >= 97 and next_byte <= 122) or
        next_byte == 95 or (next_byte >= 48 and next_byte <= 57))


## Strip a leading `kw ` prefix when present.
function skip_keyword(text: str, kw: str) -> str:
    if starts_with_keyword(text, kw) and text.len > kw.len and text.byte_at(kw.len) == 32:
        var rest = text.slice(kw.len + 1, text.len - kw.len - 1)
        while rest.len > 0 and rest.byte_at(0) == 32:
            rest = rest.slice(1, rest.len - 1)
        return rest
    return text


## The line with everything from the first ` #` comment marker removed.
function strip_comment(line: str) -> str:
    match line.find_substring(" #"):
        Option.some as pos:
            return line.slice(0, pos.value)
        Option.none:
            return line


## Left-strip ASCII spaces and tabs.
function lstrip(line: str) -> str:
    var start: ptr_uint = 0
    while start < line.len and (line.byte_at(start) == 32 or line.byte_at(start) == 9):
        start += 1
    return line.slice(start, line.len - start)


## Split source into line views (no newline characters included).
public function split_lines(source: str) -> vec.Vec[str]:
    var result = vec.Vec[str].create()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == 10:
            result.push(source.slice(start, i - start))
            start = i + 1
        i += 1
    result.push(source.slice(start, source.len - start))
    return result
