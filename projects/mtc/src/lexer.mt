import lexer.token as token_mod
import lexer.indent as indent_mod
import lexer.numbers as number_mod
import lexer.scanner as scanner_mod
import lexer.strings as string_mod
import lexer.error as lex_error
import std.fmt as fmt
import std.str
import std.string
import std.vec


const CONT_OP_COUNT: ptr_uint = 19

const continuation_operators: array[str, CONT_OP_COUNT] = array[str, CONT_OP_COUNT](
    "..", "+", "-", "*", "/", "%", "|", "&", "^",
    "or", "and", "==", "!=", "<", "<=", ">", ">=", "<<", ">>"
)


function is_continuation_operator(lexeme: str) -> bool:
    var idx: ptr_uint = 0
    while idx < CONT_OP_COUNT:
        if lexeme == continuation_operators[idx]:
            return true
        idx += 1
    return false


function adjust_grouping_depth(depth: ref[ptr_uint], lexeme: str, path: str, line: ptr_uint, column: ptr_uint) -> void:
    if lexeme == "(" or lexeme == "[":
        read(depth) += 1
    else if lexeme == ")" or lexeme == "]":
        if unsafe: read(depth) == 0:
            lex_error.fatal_at(path, line, column, "unexpected closing delimiter")
        read(depth) -= 1


function symbol_kind(ch: ubyte) -> bool:
    return (
        ch == '&' or ch == '@' or ch == ':' or ch == ',' or ch == '^'
        or ch == '.' or ch == '(' or ch == ')' or ch == '|'
        or ch == '[' or ch == ']' or ch == '?' or ch == '='
        or ch == '+' or ch == '-' or ch == '*' or ch == '/'
        or ch == '%' or ch == '<' or ch == '>' or ch == '~'
    )


function scan_identifier(
    tokens: ref[vec.Vec[token_mod.Token]],
    line: str,
    start: ptr_uint,
    line_num: ptr_uint,
    line_offset: ptr_uint,
) -> ptr_uint:
    var idx = start + 1
    while idx < line.len and scanner_mod.is_identifier_continuation(line.byte_at(idx)):
        idx += 1

    let ident = line.slice(start, idx - start)
    let kind = if token_mod.is_keyword(ident): token_mod.TokenKind.keyword else: token_mod.TokenKind.identifier
    token_mod.push_token(tokens, kind, ident, line_num, start + 1, line_offset + start, line_offset + idx)
    return idx


function try_scan_two_char(
    tokens: ref[vec.Vec[token_mod.Token]],
    line: str,
    start: ptr_uint,
    line_num: ptr_uint,
    line_offset: ptr_uint,
) -> bool:
    if start + 2 > line.len:
        return false

    let two = line.slice(start, 2)
    if (
        two == "->" or two == ".." or two == "<<" or two == ">>"
        or two == "+=" or two == "-=" or two == "*=" or two == "/="
        or two == "%=" or two == "&=" or two == "|=" or two == "^="
        or two == "==" or two == "!=" or two == "<=" or two == ">="
    ):
        token_mod.push_token(tokens, token_mod.TokenKind.symbol, two, line_num, start + 1, line_offset + start, line_offset + start + 2)
        return true

    return false


function scan_symbol(
    tokens: ref[vec.Vec[token_mod.Token]],
    grouping_depth: ref[ptr_uint],
    path: str,
    line: str,
    start: ptr_uint,
    line_num: ptr_uint,
    line_offset: ptr_uint,
) -> ptr_uint:
    if start + 3 <= line.len:
        let three = line.slice(start, 3)
        if three == "...":
            token_mod.push_token(tokens, token_mod.TokenKind.ellipsis, three, line_num, start + 1, line_offset + start, line_offset + start + 3)
            return start + 3
        if three == "<<=" or three == ">>=":
            token_mod.push_token(tokens, token_mod.TokenKind.symbol, three, line_num, start + 1, line_offset + start, line_offset + start + 3)
            adjust_grouping_depth(grouping_depth, three, path, line_num, start + 1)
            return start + 3

    if try_scan_two_char(tokens, line, start, line_num, line_offset):
        let two = line.slice(start, 2)
        adjust_grouping_depth(grouping_depth, two, path, line_num, start + 1)
        return start + 2

    let one = line.slice(start, 1)
    let ch = line.byte_at(start)
    if not symbol_kind(ch):
        lex_error.fatal_at_token(path, line_num, start + 1, one, token_mod.TokenKind.symbol, "unexpected character")

    token_mod.push_token(tokens, token_mod.TokenKind.symbol, one, line_num, start + 1, line_offset + start, line_offset + start + 1)
    adjust_grouping_depth(grouping_depth, one, path, line_num, start + 1)
    return start + 1


function scan_line(
    tokens: ref[vec.Vec[token_mod.Token]],
    grouping_depth: ref[ptr_uint],
    path: str,
    source: str,
    line_start: ptr_uint,
    line_end: ptr_uint,
    line_num: ptr_uint,
) -> token_mod.ScanResult:
    let line = source.slice(line_start, line_end - line_start)
    var idx: ptr_uint = 0

    while idx < line.len:
        let ch = line.byte_at(idx)

        if ch == ' ':
            idx += 1
            continue

        if ch == '#':
            return token_mod.ScanResult(lines_consumed = 1, next_offset = line_end + 1)

        if ch == '"':
            idx = string_mod.scan_string(tokens, line, idx, line_num, line_start)
            continue

        if ch == '\'':
            idx = string_mod.scan_char(tokens, line, idx, line_num, line_start)
            continue

        if ch == 'c' and idx + 1 < line.len and line.byte_at(idx + 1) == '"':
            idx = string_mod.scan_cstring(tokens, line, idx, line_num, line_start)
            continue

        if ch == 'f' and idx + 1 < line.len and line.byte_at(idx + 1) == '"':
            idx = string_mod.scan_fstring(tokens, line, idx, line_num, line_start)
            continue

        if ch == '<' and idx + 2 < line.len and line.byte_at(idx + 1) == '<' and line.byte_at(idx + 2) == '-':
            return string_mod.scan_heredoc(
                tokens, source,
                line_start + idx, idx + 1, line_end,
                line_start + idx + 3, line_num,
                false, false,
            )

        if ch == 'c' and idx + 3 < line.len and line.byte_at(idx + 1) == '<' and line.byte_at(idx + 2) == '<' and line.byte_at(idx + 3) == '-':
            return string_mod.scan_heredoc(
                tokens, source,
                line_start + idx, idx + 1, line_end,
                line_start + idx + 4, line_num,
                true, false,
            )

        if ch == 'f' and idx + 3 < line.len and line.byte_at(idx + 1) == '<' and line.byte_at(idx + 2) == '<' and line.byte_at(idx + 3) == '-':
            return string_mod.scan_heredoc(
                tokens, source,
                line_start + idx, idx + 1, line_end,
                line_start + idx + 4, line_num,
                false, true,
            )

        if scanner_mod.is_alpha(ch) or ch == '_':
            idx = scan_identifier(tokens, line, idx, line_num, line_start)
            continue

        if scanner_mod.is_digit(ch):
            idx = number_mod.scan_number(tokens, line, idx, line_num, line_start)
            continue

        idx = scan_symbol(tokens, grouping_depth, path, line, idx, line_num, line_start)

    return token_mod.ScanResult(lines_consumed = 1, next_offset = line_end + 1)


public function lex(source: str, path: str) -> vec.Vec[token_mod.Token]:
    var tokens = vec.Vec[token_mod.Token].create()
    var indent_stack = vec.Vec[ptr_uint].create()
    defer indent_stack.release()
    indent_stack.push(0)

    var grouping_depth: ptr_uint = 0
    var continuation_pending: bool = false
    var offset: ptr_uint = 0
    var line_num: ptr_uint = 1

    while offset < source.len:
        var line_end = offset
        while line_end < source.len and source.byte_at(line_end) != '\n':
            line_end += 1

        let line_len = line_end - offset
        let line_text = source.slice(offset, line_len)
        let has_newline = line_end < source.len
        var nl_width: ptr_uint = if has_newline: 1 else: 0

        if indent_mod.has_tab(line_text):
            lex_error.fatal_at(path, line_num, 1, "tabs are not allowed; use 4 spaces for indentation")

        if indent_mod.is_blank_line(line_text):
            offset = line_end + nl_width
            line_num += 1
            continue

        let stripped = line_text.slice(indent_mod.leading_space_count(line_text), line_text.len - indent_mod.leading_space_count(line_text))
        if stripped.len > 0 and stripped.byte_at(0) == '#':
            offset = line_end + nl_width
            line_num += 1
            continue

        if grouping_depth == 0:
            if not continuation_pending:
                let indent = indent_mod.leading_space_count(line_text)
                indent_mod.lex_indentation(ref_of(tokens), ref_of(indent_stack), indent, line_num, offset, path)

        if grouping_depth == 0:
            continuation_pending = false

        let scan_result = scan_line(
            ref_of(tokens),
            ref_of(grouping_depth),
            path,
            source,
            offset,
            line_end,
            line_num,
        )

        var effective_consumed = scan_result.lines_consumed
        if scan_result.lines_consumed == 1 and has_newline and grouping_depth == 0 and not continuation_pending:
            let concat_result = string_mod.try_concat_string_line(
                ref_of(tokens),
                source,
                line_end,
                indent_mod.leading_space_count(line_text),
                line_num,
            )
            effective_consumed = concat_result.lines_consumed

        if grouping_depth == 0 and scan_result.lines_consumed == 1 and effective_consumed == 1:
            let last_tok_ptr = tokens.last()
            let suppress = last_tok_ptr != null and is_continuation_operator(unsafe: read(ptr[token_mod.Token]<-last_tok_ptr).lexeme)
            if not suppress:
                token_mod.push_token(
                    ref_of(tokens),
                    token_mod.TokenKind.newline,
                    "\n",
                    line_num,
                    line_len + 1,
                    offset + line_len,
                    offset + line_len + nl_width,
                )
            else:
                continuation_pending = true

        if scan_result.lines_consumed > 1:
            offset = scan_result.next_offset
            line_num += scan_result.lines_consumed
        else:
            var total = effective_consumed
            var skip_nl: ptr_uint = 0
            var adv = line_end
            while skip_nl < total and adv < source.len:
                adv += 1
                if adv <= source.len and source.byte_at(adv - 1) == '\n':
                    skip_nl += 1
            offset = adv
            line_num += skip_nl

    if grouping_depth > 0:
        lex_error.fatal_at(path, line_num, 1, "unclosed grouping delimiter")

    if line_num > 0:
        line_num = line_num - 1

    while indent_stack.len() > 1:
        indent_stack.pop()
        token_mod.push_token(ref_of(tokens), token_mod.TokenKind.dedent, "", line_num, 1, source.len, source.len)

    token_mod.push_token(ref_of(tokens), token_mod.TokenKind.eof, "", line_num + 1, 1, source.len, source.len)
    return tokens


public function token_kind_name(kind: token_mod.TokenKind) -> str:
    return token_mod.token_kind_name(kind)


public function write_token_line(tokens: ref[vec.Vec[token_mod.Token]], index: ptr_uint, output: ref[string.String]) -> void:
    let tok_ptr = tokens.get(index) else:
        fatal(c"write_token_line missing token at index")

    unsafe:
        let tok = read(tok_ptr)
        output.assign("")
        output.append(token_mod.token_kind_name(tok.kind))
        output.push_byte(32)
        fmt.append_ptr_uint(output, tok.line)
        output.push_byte(32)
        fmt.append_ptr_uint(output, tok.column)
        output.push_byte(32)
        fmt.append_ptr_uint(output, tok.start_offset)
        output.push_byte(32)
        fmt.append_ptr_uint(output, tok.end_offset)
        output.push_byte(32)
        output.append(tok.lexeme)
