import lexer.token as token_mod
import std.str
import std.vec


public function leading_space_count(line: str) -> ptr_uint:
    var count: ptr_uint = 0
    while count < line.len and line.byte_at(count) == ' ':
        count += 1
    return count


public function has_tab(line: str) -> bool:
    var idx: ptr_uint = 0
    while idx < line.len:
        if line.byte_at(idx) == '\t':
            return true
        idx += 1
    return false


public function is_blank_line(line: str) -> bool:
    var idx: ptr_uint = 0
    while idx < line.len:
        let ch = line.byte_at(idx)
        if ch != ' ' and ch != '\r':
            return false
        idx += 1
    return false


public function lex_indentation(
    tokens: ref[vec.Vec[token_mod.Token]],
    indent_stack: ref[vec.Vec[ptr_uint]],
    indent: ptr_uint,
    line: ptr_uint,
    line_offset: ptr_uint,
) -> void:
    if indent % 4 != 0:
        fatal(c"indentation must use multiples of 4 spaces")

    let last_indent_ptr = indent_stack.last() else:
        return

    let current_indent = unsafe: read(last_indent_ptr)
    if indent == current_indent:
        return

    if indent > current_indent:
        if indent != current_indent + 4:
            fatal(c"indentation may only increase by 4 spaces at a time")

        indent_stack.push(indent)
        token_mod.push_token(tokens, token_mod.TokenKind.indent, "", line, 1, line_offset, line_offset)
        return

    while true:
        let top_ptr = indent_stack.last() else:
            break

        let top = unsafe: read(top_ptr)
        if top <= indent:
            break

        indent_stack.pop()
        token_mod.push_token(tokens, token_mod.TokenKind.dedent, "", line, 1, line_offset, line_offset)

    let final_ptr = indent_stack.last() else:
        return

    let final = unsafe: read(final_ptr)
    if final != indent:
        fatal(c"indentation does not match any open block")
