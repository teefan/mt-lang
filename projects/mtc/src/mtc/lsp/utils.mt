## Shared text-scanning and LSP utility primitives, used across multiple
## LSP feature modules to avoid duplication.  Line-oriented helpers mirror
## the pattern already established in lsp.cursor.

import std.str
import std.vec as vec


## Number of leading ASCII spaces on `line_text`.
public function indent_of(line_text: str) -> ptr_uint:
    var count: ptr_uint = 0
    while count < line_text.len and line_text.byte_at(count) == ' ':
        count += 1
    return count


## True when `line_text` consists entirely of whitespace (or is empty).
public function is_blank(line_text: str) -> bool:
    return line_text.trim_ascii_whitespace().len == 0


## True when `ch` is a valid identifier character (ASCII letter, digit, or
## underscore).  Used to determine word boundaries in line-based scanning.
public function is_word_byte(ch: ubyte) -> bool:
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or ch == '_' or (ch >= '0' and ch <= '9')


## Retrieve line `index` from a vector of lines, or "" on bounds miss.
public function line_at(lines: ref[vec.Vec[str]], index: ptr_uint) -> str:
    let lp = lines.get(index) else:
        return ""
    return unsafe: read(lp)


## The identifier prefix the user is currently typing, by walking
## backward on the cursor line from the character position to the start
## of the word (letters, digits, underscore).  Returns "" when there is
## no word immediately at/before the cursor.
public function current_word_prefix(source: str, line: ptr_uint, character: ptr_uint) -> str:
    var line_text = source_line(source, line + 1)
    var pos = character
    if pos > line_text.len:
        pos = line_text.len
    var start = pos
    while start > 0 and is_word_byte(line_text.byte_at(start - 1)):
        start -= 1
    if start >= pos:
        return ""
    return line_text.slice(start, pos - start)


## The text of 1-based line `line_no` in `source`, without the newline.
public function source_line(source: str, line_no: ptr_uint) -> str:
    if line_no == 0:
        return ""
    var current: ptr_uint = 1
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == '\n':
            if current == line_no:
                return source.slice(start, i - start)
            current += 1
            start = i + 1
        i += 1
    if current == line_no:
        return source.slice(start, source.len - start)
    return ""


## Split `source` at LF newlines into a vector of lines (without the
## trailing newline characters).
public function split_lines(source: str) -> vec.Vec[str]:
    var result = vec.Vec[str].create()
    var start: ptr_uint = 0
    var i: ptr_uint = 0
    while i < source.len:
        if source.byte_at(i) == '\n':
            result.push(source.slice(start, i - start))
            start = i + 1
        i += 1
    if start < source.len:
        result.push(source.slice(start, source.len - start))
    return result
