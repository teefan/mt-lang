import lexer.token as token_mod
import lexer.error as lex_error
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
    return true


public function lex_indentation(
    tokens: ref[vec.Vec[token_mod.Token]],
    indent_stack: ref[vec.Vec[ptr_uint]],
    indent: ptr_uint,
    line: ptr_uint,
    line_offset: ptr_uint,
    path: str,
    recover: ptr[vec.Vec[lex_error.LexError]]?,
) -> void:
    var adjusted = indent
    if indent % 4 != 0:
        lex_error.recover_or_fatal_at(recover, path, line, 1, "indentation must use multiples of 4 spaces")
        adjusted = indent - (indent % 4)

    let last_indent_ptr = indent_stack.last() else:
        return

    let current_indent = unsafe: read(last_indent_ptr)
    if adjusted == current_indent:
        return

    if adjusted > current_indent:
        if adjusted > current_indent + 4:
            lex_error.recover_or_fatal_at(recover, path, line, 1, "indentation may only increase by 4 spaces at a time")
            adjusted = current_indent + 4

        indent_stack.push(adjusted)
        token_mod.push_token(tokens, token_mod.TokenKind.indent, "", line, 1, line_offset, line_offset)
        return

    while true:
        let top_ptr = indent_stack.last() else:
            break

        let top = unsafe: read(top_ptr)
        if top <= adjusted:
            break

        indent_stack.pop()
        token_mod.push_token(tokens, token_mod.TokenKind.dedent, "", line, 1, line_offset, line_offset)

    let final_ptr = indent_stack.last() else:
        return

    let final = unsafe: read(final_ptr)
    if final != adjusted:
        lex_error.recover_or_fatal_at(recover, path, line, 1, "indentation does not match any open block")