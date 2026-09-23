## Core lexer — transforms Milk Tea source text into a list of Token values.
##
## Public API:
##   lex(source: str) -> Vec[Token]
##   lex_reporting(source: str, diagnostics: ref[Vec[LexDiagnostic]]) -> Vec[Token]
##
## Parity with the Ruby lexer (lib/milk_tea/core/lexer.rb).  Every production
## rule, the indent dedent strategy, the line-continuation protocol, the suffix
## set, and edge-case handling (CRLF, tabs, unclosed grouping) mirror the Ruby
## implementation so that the token stream is byte-identical.
##
## `lex_reporting` collects recoverable errors in `diagnostics` instead of
## calling `fatal`.  This allows the CLI to report all lex errors at once.

import std.vec as vec

import mtc.lexer.token_kinds as tk
import mtc.lexer.token as tok
import mtc.lexer.keywords as keywords

const SPACE_BYTE: ubyte = ' '
const TAB_BYTE: ubyte = '\t'
const NEWLINE_BYTE: ubyte = '\n'
const CARRIAGE_RETURN: ubyte = '\r'
const HASH_BYTE: ubyte = '#'
const DOUBLE_QUOTE: ubyte = '"'
const SINGLE_QUOTE: ubyte = '\''
const BACKSLASH: ubyte = '\\'
const PERIOD: ubyte = '.'
const ZERO_BYTE: ubyte = '0'
const LOWER_E: ubyte = 'e'
const UPPER_E: ubyte = 'E'
const LOWER_X: ubyte = 'x'
const UPPER_X: ubyte = 'X'
const LOWER_B: ubyte = 'b'
const UPPER_B: ubyte = 'B'
const LOWER_F: ubyte = 'f'
const LOWER_D: ubyte = 'd'
const PLUS_BYTE: ubyte = '+'
const MINUS_BYTE: ubyte = '-'

const INDENT_SIZE: ptr_uint = 4
const PLAIN_HEREDOC_PREFIX_LEN: ptr_uint = 3   # <<-
const CHEAD_FHEREDOC_PREFIX_LEN: ptr_uint = 4  # c<<- / f<<-

# Exact match of Ruby Lexer::LINE_CONTINUATION_OPERATORS (19 entries).
#
const LINE_CONTINUATION_KINDS: array[tk.TokenKind, 19] = array[tk.TokenKind, 19](
    tk.TokenKind.dot_dot,
    tk.TokenKind.plus,
    tk.TokenKind.minus,
    tk.TokenKind.star,
    tk.TokenKind.slash,
    tk.TokenKind.percent,
    tk.TokenKind.pipe,
    tk.TokenKind.amp,
    tk.TokenKind.caret,
    tk.TokenKind.tk_or,
    tk.TokenKind.tk_and,
    tk.TokenKind.equal_equal,
    tk.TokenKind.bang_equal,
    tk.TokenKind.less,
    tk.TokenKind.less_equal,
    tk.TokenKind.greater,
    tk.TokenKind.greater_equal,
    tk.TokenKind.shift_left,
    tk.TokenKind.shift_right,
)


## Mutable lexer session.  Internal functions mutate this state directly.
struct LexSession:
    tokens: vec.Vec[tok.Token]
    indent_stack: vec.Vec[ptr_uint]
    diags: ptr[vec.Vec[tok.LexDiagnostic]]?
    continuation_pending: bool
    grouping_depth: int
    source: str
    src_len: ptr_uint


# =============================================================================
#  Public API
# =============================================================================

public function lex(source: str) -> vec.Vec[tok.Token]:
    var session = LexSession(
        tokens = vec.Vec[tok.Token].create(),
        indent_stack = vec.Vec[ptr_uint].create(),
        diags = null,
        continuation_pending = false,
        grouping_depth = 0,
        source = source,
        src_len = source.len,
    )
    session.indent_stack.push(0)
    lex_lines(ref_of(session))
    return emit_eof(ref_of(session))


public function lex_reporting(source: str, diagnostics: ref[vec.Vec[tok.LexDiagnostic]]) -> vec.Vec[tok.Token]:
    var session = LexSession(
        tokens = vec.Vec[tok.Token].create(),
        indent_stack = vec.Vec[ptr_uint].create(),
        diags = ptr_of(diagnostics),
        continuation_pending = false,
        grouping_depth = 0,
        source = source,
        src_len = source.len,
    )
    session.indent_stack.push(0)
    lex_lines(ref_of(session))
    return emit_eof(ref_of(session))


# =============================================================================
#  Character classification
# =============================================================================

function is_identifier_start_byte(b: ubyte) -> bool:
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or b == '_'

function is_identifier_part_byte(b: ubyte) -> bool:
    return is_identifier_start_byte(b) or (b >= '0' and b <= '9')

function is_digit_byte(b: ubyte) -> bool:
    return b >= '0' and b <= '9'

function is_hex_digit_byte(b: ubyte) -> bool:
    return is_digit_byte(b) or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F')

function is_bin_digit_byte(b: ubyte) -> bool:
    return b == '0' or b == '1'

function is_numeric_part_byte(b: ubyte) -> bool:
    return is_digit_byte(b) or b == '_'


# =============================================================================
#  Error handling — either fatal or collect
# =============================================================================

function session_fatal(session: ref[LexSession], msg: cstr, line: ptr_uint, col: ptr_uint) -> void:
    unsafe:
        let diag_ptr = read(session).diags
        if diag_ptr == null:
            return
        var diags = read(diag_ptr)
        let diag = tok.LexDiagnostic(message = msg, line = line, column = col)
        diags.push(diag)
        read(diag_ptr) = diags


# =============================================================================
#  Line utilities
# =============================================================================

function find_line_bounds(source: str, start: ptr_uint) -> (ptr_uint, ptr_uint, bool):
    var end = start
    let src_len = source.len

    while end < src_len:
        let b = unsafe: ubyte<-read(source.data + end)
        if b == NEWLINE_BYTE:
            return (start, end + 1, true)
        end += 1

    return (start, end, false)


function trim_trailing_cr(source: str, line_start: ptr_uint, line_len: ptr_uint) -> ptr_uint:
    if line_len > 0:
        let last = unsafe: ubyte<-read(source.data + line_start + line_len - 1)
        if last == CARRIAGE_RETURN:
            return line_len - 1
    return line_len


function check_tabs(session: ref[LexSession], line_start: ptr_uint, line_len: ptr_uint, line_number: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < line_len:
        let b = unsafe: ubyte<-read(session.source.data + line_start + i)
        if b == TAB_BYTE:
            session_fatal(session, c"tabs are not allowed; use 4 spaces for indentation", line_number, i + 1)
        i += 1


function count_indent(source: str, line_start: ptr_uint, line_len: ptr_uint) -> ptr_uint:
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i < line_len:
        let b = unsafe: ubyte<-read(source.data + line_start + i)
        if b != SPACE_BYTE:
            break
        count += 1
        i += 1
    return count


function line_is_blank(source: str, line_start: ptr_uint, line_len: ptr_uint) -> bool:
    var i: ptr_uint = 0
    while i < line_len:
        let b = unsafe: ubyte<-read(source.data + line_start + i)
        if b != SPACE_BYTE and b != TAB_BYTE and b != CARRIAGE_RETURN:
            return false
        i += 1
    return true


function line_is_comment(source: str, line_start: ptr_uint, line_len: ptr_uint) -> bool:
    var i: ptr_uint = 0
    while i < line_len:
        let b = unsafe: ubyte<-read(source.data + line_start + i)
        if b == SPACE_BYTE:
            i += 1
            continue
        return b == HASH_BYTE
    return false


function source_slice(source: str, start: ptr_uint, length: ptr_uint) -> str:
    return unsafe: str(data = source.data + start, len = length)


function line_remainder_is_blank(source: str, start: ptr_uint, stop: ptr_uint) -> bool:
    var i: ptr_uint = start
    while i < stop:
        let b = unsafe: ubyte<-read(source.data + i)
        if b != SPACE_BYTE and b != TAB_BYTE and b != CARRIAGE_RETURN:
            return false
        i += 1
    return true


# =============================================================================
#  Main lex loop
# =============================================================================

function lex_lines(session: ref[LexSession]) -> void:
    let source = session.source
    var offset: ptr_uint = 0
    var line_number: ptr_uint = 1

    while offset < session.src_len:
        let (line_start, line_end, has_newline) = find_line_bounds(source, offset)
        var consumed_lines: ptr_uint = 1

        var line_content_len = line_end - line_start
        if has_newline:
            line_content_len -= 1

        line_content_len = trim_trailing_cr(source, line_start, line_content_len)

        check_tabs(session, line_start, line_content_len, line_number)

        let is_blank = line_is_blank(source, line_start, line_content_len)
        let is_comment = line_is_comment(source, line_start, line_content_len)

        if is_blank or is_comment:
            offset = line_end
            line_number += consumed_lines
            continue

        let indent = count_indent(source, line_start, line_content_len)

        if session.grouping_depth == 0 and not session.continuation_pending:
            emit_indentation(session, indent, line_number, line_start)
        session.continuation_pending = false

        var pos = line_start
        let line_stop = line_start + line_content_len

        while pos < line_stop:
            let b = unsafe: ubyte<-read(source.data + pos)

            if b == SPACE_BYTE:
                pos += 1
                continue

            if b == HASH_BYTE:
                break

            if b == DOUBLE_QUOTE:
                let s_result = scan_string_adjacent(session, line_end, pos, line_number, line_start, line_content_len, indent, false)
                pos = s_result.next_pos
                consumed_lines = s_result.lines_consumed
                continue

            if b == SINGLE_QUOTE:
                pos = scan_char_literal(session, pos, line_number, line_start)
                continue

            if b == 'c' and pos + 1 < line_stop:
                let n1 = unsafe: ubyte<-read(source.data + pos + 1)
                if n1 == DOUBLE_QUOTE:
                    let s_result = scan_string_adjacent(session, line_end, pos, line_number, line_start, line_content_len, indent, true)
                    pos = s_result.next_pos
                    consumed_lines = s_result.lines_consumed
                    continue
                if n1 == '<' and pos + 3 < line_stop:
                    let n2 = unsafe: ubyte<-read(source.data + pos + 2)
                    let n3 = unsafe: ubyte<-read(source.data + pos + 3)
                    if n2 == '<' and n3 == MINUS_BYTE and pos + 4 < line_stop:
                        let n4 = unsafe: ubyte<-read(source.data + pos + 4)
                        if is_identifier_start_byte(n4):
                            let h_result = scan_heredoc(session, pos, line_end, line_number, true, false)
                            pos = h_result.next_pos
                            consumed_lines = h_result.lines_consumed
                            continue
                    pass

            if b == 'f' and pos + 1 < line_stop:
                let n1 = unsafe: ubyte<-read(source.data + pos + 1)
                if n1 == DOUBLE_QUOTE:
                    pos = scan_format_string(session, pos, line_stop, line_number, line_start)
                    continue
                if n1 == '<' and pos + 3 < line_stop:
                    let n2 = unsafe: ubyte<-read(source.data + pos + 2)
                    let n3 = unsafe: ubyte<-read(source.data + pos + 3)
                    if n2 == '<' and n3 == MINUS_BYTE and pos + 4 < line_stop:
                        let n4 = unsafe: ubyte<-read(source.data + pos + 4)
                        if is_identifier_start_byte(n4):
                            let h_result = scan_heredoc(session, pos, line_end, line_number, false, true)
                            pos = h_result.next_pos
                            consumed_lines = h_result.lines_consumed
                            continue
                    pass

            if b == '<' and pos + 2 < line_stop:
                let n1 = unsafe: ubyte<-read(source.data + pos + 1)
                let n2 = unsafe: ubyte<-read(source.data + pos + 2)
                if n1 == '<' and n2 == MINUS_BYTE and pos + 3 < line_stop:
                    let n3 = unsafe: ubyte<-read(source.data + pos + 3)
                    if is_identifier_start_byte(n3):
                        let h_result = scan_heredoc(session, pos, line_end, line_number, false, false)
                        pos = h_result.next_pos
                        consumed_lines = h_result.lines_consumed
                        continue

            if is_identifier_start_byte(b):
                pos = scan_identifier(session, pos, line_stop, line_number, line_start)
                continue

            if is_digit_byte(b):
                pos = scan_number(session, pos, line_stop, line_number, line_start)
                continue

            pos = scan_symbol(session, pos, line_number, line_start)

        # Compute the actual end after consuming N lines (for multi-line tokens)
        var actual_end = line_end
        var rem = consumed_lines - 1
        while rem > 0:
            let (_, next_end, _) = find_line_bounds(source, actual_end)
            actual_end = next_end
            rem -= 1

        # The last line consumed
        let last_nl_start = if consumed_lines > 1: line_start_cached(source, actual_end - 1) else: line_start
        let last_nl_content_len = actual_end - last_nl_start - 1

        let newline_offset = last_nl_start + last_nl_content_len
        let newline_end_offset = actual_end

        if session.grouping_depth == 0:
            if is_line_continuation(session):
                session.continuation_pending = true
            else:
                let nl = tok.Token(
                    kind = tk.TokenKind.newline,
                    start_offset = newline_offset,
                    end_offset = newline_end_offset,
                    line = line_number + consumed_lines - 1,
                    column = ptr_uint<-(last_nl_content_len) + 1,
                )
                session.tokens.push(nl)

        offset = actual_end
        line_number += consumed_lines


function emit_eof(session: ref[LexSession]) -> vec.Vec[tok.Token]:
    if session.grouping_depth > 0:
        session_fatal(session, c"unclosed grouping delimiter", 0, 0)

    # Ruby uses @line_count (total source lines) for dedent, @line_count+1 for eof.
    var total_lines: ptr_uint = 1
    if session.tokens.len() > 0:
        let last_ptr = session.tokens.last()
        unsafe:
            if last_ptr != null:
                total_lines = read(last_ptr).line

    while session.indent_stack.len > 1:
        session.indent_stack.pop()
        let tok = tok.Token(
            kind = tk.TokenKind.dedent,
            start_offset = session.src_len,
            end_offset = session.src_len,
            line = total_lines,
            column = 1,
        )
        session.tokens.push(tok)

    let eof_tok = tok.Token(
        kind = tk.TokenKind.eof,
        start_offset = session.src_len,
        end_offset = session.src_len,
        line = total_lines + 1,
        column = 1,
    )
    session.tokens.push(eof_tok)

    return session.tokens


# =============================================================================
#  Indentation
# =============================================================================

function emit_indentation(session: ref[LexSession], indent: ptr_uint, line_number: ptr_uint, line_offset: ptr_uint) -> void:
    if indent % INDENT_SIZE != 0:
        session_fatal(session, c"indentation must use multiples of 4 spaces", line_number, 1)
        return

    let current_ptr = session.indent_stack.last() else:
        session_fatal(session, c"indent stack is empty", line_number, 1)
        return

    let current = unsafe: read(current_ptr)

    if indent == current:
        return

    if indent > current:
        if indent != current + INDENT_SIZE:
            session_fatal(session, c"indentation may only increase by 4 spaces at a time", line_number, 1)
            return

        session.indent_stack.push(indent)
        let tok = tok.Token(
            kind = tk.TokenKind.indent,
            start_offset = line_offset,
            end_offset = line_offset,
            line = line_number,
            column = 1,
        )
        session.tokens.push(tok)
        return

    while session.indent_stack.len > 0:
        let top = session.indent_stack.last() else:
            break

        let top_level = unsafe: read(top)
        if top_level <= indent:
            break

        session.indent_stack.pop()
        let tok = tok.Token(
            kind = tk.TokenKind.dedent,
            start_offset = line_offset,
            end_offset = line_offset,
            line = line_number,
            column = 1,
        )
        session.tokens.push(tok)

    let final_top = session.indent_stack.last() else:
        session_fatal(session, c"indent stack underflow", line_number, 1)
        return

    if unsafe: read(final_top) != indent:
        session_fatal(session, c"indentation does not match any open block", line_number, 1)


# =============================================================================
#  Line continuation
# =============================================================================

function is_line_continuation(session: ref[LexSession]) -> bool:
    if session.tokens.len() == 0:
        return false

    let last = session.tokens.last() else:
        return false

    let last_kind = unsafe: read(last).kind
    let kinds = LINE_CONTINUATION_KINDS.as_span()
    var i: ptr_uint = 0
    while i < kinds.len:
        if last_kind == kinds[i]:
            return true
        i += 1
    return false


# =============================================================================
#  Identifier / keyword
# =============================================================================

function scan_identifier(
    session: ref[LexSession],
    start: ptr_uint,
    line_stop: ptr_uint,
    line_number: ptr_uint,
    line_start: ptr_uint,
) -> ptr_uint:
    let source = session.source
    var pos = start + 1
    while pos < line_stop:
        let b = unsafe: ubyte<-read(source.data + pos)
        if not is_identifier_part_byte(b):
            break
        pos += 1

    let lexeme = source_slice(source, start, pos - start)
    let kind = keywords.keyword_kind(lexeme)

    let tok = tok.Token(
        kind = kind,
        start_offset = start,
        end_offset = pos,
        line = line_number,
        column = start - line_start + 1,
    )
    session.tokens.push(tok)
    return pos


# =============================================================================
#  Numbers
# =============================================================================

function scan_number(
    session: ref[LexSession],
    start: ptr_uint,
    line_stop: ptr_uint,
    line_number: ptr_uint,
    line_start: ptr_uint,
) -> ptr_uint:
    let source = session.source
    var pos = start
    var is_float = false
    var is_hex = false
    var is_bin = false

    let first = unsafe: ubyte<-read(source.data + start)
    if first == ZERO_BYTE and start + 1 < line_stop:
        let second = unsafe: ubyte<-read(source.data + start + 1)
        if second == LOWER_X or second == UPPER_X:
            is_hex = true
            pos += 2
        else if second == LOWER_B or second == UPPER_B:
            is_bin = true
            pos += 2

    while pos < line_stop:
        let b = unsafe: ubyte<-read(source.data + pos)
        if is_hex and is_hex_digit_byte(b):
            pos += 1
        else if is_bin and is_bin_digit_byte(b):
            pos += 1
        else if not is_hex and not is_bin and is_numeric_part_byte(b):
            pos += 1
        else:
            break

    if not is_hex and not is_bin and pos < line_stop:
        let b = unsafe: ubyte<-read(source.data + pos)
        if b == PERIOD and pos + 1 < line_stop:
            let next_b = unsafe: ubyte<-read(source.data + pos + 1)
            if is_digit_byte(next_b):
                is_float = true
                pos += 1
                while pos < line_stop:
                    let b2 = unsafe: ubyte<-read(source.data + pos)
                    if not is_numeric_part_byte(b2):
                        break
                    pos += 1

    if not is_hex and not is_bin and pos < line_stop:
        let b = unsafe: ubyte<-read(source.data + pos)
        if b == LOWER_E or b == UPPER_E:
            var next_pos = pos + 1
            if next_pos < line_stop:
                let sign_b = unsafe: ubyte<-read(source.data + next_pos)
                if sign_b == PLUS_BYTE or sign_b == MINUS_BYTE:
                    next_pos += 1
                if next_pos < line_stop:
                    let digit_b = unsafe: ubyte<-read(source.data + next_pos)
                    if is_digit_byte(digit_b):
                        is_float = true
                        pos = next_pos
                        while pos < line_stop:
                            let b2 = unsafe: ubyte<-read(source.data + pos)
                            if not is_numeric_part_byte(b2):
                                break
                            pos += 1

    if is_float and pos < line_stop:
        let b = unsafe: ubyte<-read(source.data + pos)
        if (b == LOWER_F or b == LOWER_D) and not is_identifier_part_near(source, pos + 1, line_stop):
            pos += 1

    if not is_float:
        pos = scan_int_suffix(source, pos, line_stop)

    let kind = if is_float: tk.TokenKind.float_literal else: tk.TokenKind.integer

    let tok = tok.Token(
        kind = kind,
        start_offset = start,
        end_offset = pos,
        line = line_number,
        column = start - line_start + 1,
    )
    session.tokens.push(tok)
    return pos


function scan_int_suffix(source: str, start: ptr_uint, line_stop: ptr_uint) -> ptr_uint:
    if start >= line_stop:
        return start

    let b0 = unsafe: ubyte<-read(source.data + start)

    if start + 1 < line_stop:
        let b1 = unsafe: ubyte<-read(source.data + start + 1)
        if b0 == 'u' and b1 == 'b' and not is_identifier_part_near(source, start + 2, line_stop):
            return start + 2
        if b0 == 'u' and b1 == 's' and not is_identifier_part_near(source, start + 2, line_stop):
            return start + 2
        if b0 == 'u' and b1 == 'l' and not is_identifier_part_near(source, start + 2, line_stop):
            return start + 2
        if b0 == 'i' and b1 == 'z' and not is_identifier_part_near(source, start + 2, line_stop):
            return start + 2

    if b0 == 'u' and not is_identifier_part_near(source, start + 1, line_stop):
        return start + 1
    if b0 == 'l' and not is_identifier_part_near(source, start + 1, line_stop):
        return start + 1
    if b0 == 'z' and not is_identifier_part_near(source, start + 1, line_stop):
        return start + 1
    if b0 == 'b' and not is_identifier_part_near(source, start + 1, line_stop):
        return start + 1
    if b0 == 's' and not is_identifier_part_near(source, start + 1, line_stop):
        return start + 1
    if b0 == 'i' and not is_identifier_part_near(source, start + 1, line_stop):
        return start + 1

    return start


function is_identifier_part_near(source: str, pos: ptr_uint, line_stop: ptr_uint) -> bool:
    if pos >= line_stop:
        return false
    let b = unsafe: ubyte<-read(source.data + pos)
    return is_identifier_part_byte(b)


# =============================================================================
#  String scan result
# =============================================================================

struct StringScanResult:
    next_pos: ptr_uint
    lines_consumed: ptr_uint


# =============================================================================
#  Strings (with adjacent continuation)
# =============================================================================

function scan_string_adjacent(
    session: ref[LexSession],
    line_end: ptr_uint,
    start: ptr_uint,
    line_number: ptr_uint,
    line_start: ptr_uint,
    line_content_len: ptr_uint,
    line_indent: ptr_uint,
    is_cstring: bool,
) -> StringScanResult:
    let source = session.source
    var consumed_lines: ptr_uint = 1

    let first_end = scan_string_segment(session, start, line_start + line_content_len, is_cstring)
    var segment_end = first_end

    let remainder_blank = line_remainder_is_blank(source, segment_end, line_start + line_content_len)

    if remainder_blank:
        var next_offset = line_end
        var next_line_number = line_number + 1

        while next_offset < session.src_len:
            let (nl_start, nl_end, nl_has_newline) = find_line_bounds(source, next_offset)

            var nl_len = nl_end - nl_start
            if nl_has_newline:
                nl_len -= 1
            nl_len = trim_trailing_cr(source, nl_start, nl_len)

            if nl_len == 0:
                break

            let nl_indent = count_indent(source, nl_start, nl_len)

            if not (nl_indent > line_indent):
                break

            var i = nl_indent
            while i < nl_len:
                let byte_at = unsafe: ubyte<-read(source.data + nl_start + i)
                if byte_at != SPACE_BYTE:
                    break
                i += 1
            if i < nl_len:
                let first_char = unsafe: ubyte<-read(source.data + nl_start + i)
                if first_char == HASH_BYTE:
                    break

            if is_cstring:
                if i + 1 >= nl_len:
                    break
                let ch0 = unsafe: ubyte<-read(source.data + nl_start + i)
                let ch1 = unsafe: ubyte<-read(source.data + nl_start + i + 1)
                if not (ch0 == 'c' and ch1 == DOUBLE_QUOTE):
                    break
            else:
                if i >= nl_len:
                    break
                let ch0 = unsafe: ubyte<-read(source.data + nl_start + i)
                if not (ch0 == DOUBLE_QUOTE):
                    break

            let seg_end = scan_string_segment(session, nl_start + i, nl_start + nl_len, is_cstring)

            if not line_remainder_is_blank(source, seg_end, nl_start + nl_len):
                break

            consumed_lines += 1
            segment_end = seg_end

            next_offset = nl_end
            next_line_number += 1

    let kind = if is_cstring: tk.TokenKind.cstring else: tk.TokenKind.string
    let tok = tok.Token(
        kind = kind,
        start_offset = start,
        end_offset = segment_end,
        line = line_number,
        column = start - line_start + 1,
    )
    session.tokens.push(tok)

    return StringScanResult(next_pos = segment_end, lines_consumed = consumed_lines)


function scan_string_segment(session: ref[LexSession], start: ptr_uint, line_stop: ptr_uint, is_cstring: bool) -> ptr_uint:
    let source = session.source
    var pos = start
    if is_cstring:
        pos += 2
    else:
        pos += 1

    while pos < session.src_len:
        let b = unsafe: ubyte<-read(source.data + pos)

        if b == DOUBLE_QUOTE:
            return pos + 1

        if b == BACKSLASH:
            if pos + 1 >= session.src_len:
                session_fatal(session, c"unterminated string literal", 0, 0)
                return pos
            pos += 2
            continue

        pos += 1

    session_fatal(session, c"unterminated string literal", 0, 0)
    return pos


# =============================================================================
#  Character literals
# =============================================================================

function scan_char_literal(
    session: ref[LexSession],
    start: ptr_uint,
    line_number: ptr_uint,
    line_start: ptr_uint,
) -> ptr_uint:
    let source = session.source
    var pos = start + 1

    if pos >= session.src_len:
        session_fatal(session, c"unterminated character literal", line_number, start - line_start + 1)
        return pos

    let b = unsafe: ubyte<-read(source.data + pos)

    if b == BACKSLASH:
        pos += 1
        if pos >= session.src_len:
            session_fatal(session, c"unterminated escape in character literal", line_number, start - line_start + 1)
            return pos

        let escape_b = unsafe: ubyte<-read(source.data + pos)
        if escape_b == LOWER_X:
            if pos + 2 >= session.src_len:
                session_fatal(session, c"invalid hex escape in character literal", line_number, start - line_start + 1)
                return pos
            pos += 3
        else:
            pos += 1
    else:
        pos += 1

    if pos >= session.src_len:
        session_fatal(session, c"unterminated character literal", line_number, start - line_start + 1)
        return pos

    let close_b = unsafe: ubyte<-read(source.data + pos)
    if close_b != SINGLE_QUOTE:
        session_fatal(session, c"expected closing ' in character literal", line_number, start - line_start + 1)
        return pos

    pos += 1

    let tok = tok.Token(
        kind = tk.TokenKind.char_literal,
        start_offset = start,
        end_offset = pos,
        line = line_number,
        column = start - line_start + 1,
    )
    session.tokens.push(tok)
    return pos


# =============================================================================
#  Symbols / operators
# =============================================================================

function scan_symbol(
    session: ref[LexSession],
    pos: ptr_uint,
    line_number: ptr_uint,
    line_start: ptr_uint,
) -> ptr_uint:
    let source = session.source

    if pos >= session.src_len:
        return pos

    let ch = char<-(unsafe: ubyte<-read(source.data + pos))

    if pos + 2 < session.src_len:
        let ch1 = char<-(unsafe: read(source.data + pos + 1))
        let ch2 = char<-(unsafe: read(source.data + pos + 2))
        let three_kind = three_char_token(ch, ch1, ch2)
        if three_kind != tk.TokenKind.eof:
            emit_symbol(session, three_kind, pos, pos + 3, line_number, line_start)
            return pos + 3

    if pos + 1 < session.src_len:
        let ch1 = char<-(unsafe: read(source.data + pos + 1))
        let two_kind = two_char_token(ch, ch1)
        if two_kind != tk.TokenKind.eof:
            emit_symbol(session, two_kind, pos, pos + 2, line_number, line_start)
            return pos + 2

    let one_kind = one_char_token(ch)
    if one_kind != tk.TokenKind.eof:
        emit_symbol(session, one_kind, pos, pos + 1, line_number, line_start)
        return pos + 1

    session_fatal(session, c"unexpected character", line_number, pos - line_start + 1)
    return pos + 1


function emit_symbol(
    session: ref[LexSession],
    kind: tk.TokenKind,
    start: ptr_uint,
    end_offset: ptr_uint,
    line_number: ptr_uint,
    line_start: ptr_uint,
) -> void:
    if kind == tk.TokenKind.lparen or kind == tk.TokenKind.lbracket:
        session.grouping_depth += 1
    else if kind == tk.TokenKind.rparen or kind == tk.TokenKind.rbracket:
        if session.grouping_depth > 0:
            session.grouping_depth -= 1

    let tok = tok.Token(
        kind = kind,
        start_offset = start,
        end_offset = end_offset,
        line = line_number,
        column = start - line_start + 1,
    )
    session.tokens.push(tok)


# =============================================================================
#  Heredocs
# =============================================================================

function scan_heredoc(
    session: ref[LexSession],
    start: ptr_uint,
    line_end: ptr_uint,
    line_number: ptr_uint,
    is_cstring: bool,
    is_format: bool,
) -> StringScanResult:
    let source = session.source

    var tag_start = start
    if is_cstring or is_format:
        tag_start += CHEAD_FHEREDOC_PREFIX_LEN
    else:
        tag_start += PLAIN_HEREDOC_PREFIX_LEN

    var tag_end = tag_start
    while tag_end < session.src_len:
        let b = unsafe: ubyte<-read(source.data + tag_end)
        if not is_identifier_part_byte(b):
            break
        tag_end += 1

    let rest_stop = line_end - 1z
    if tag_end < rest_stop:
        if not line_remainder_is_blank(source, tag_end, rest_stop):
            session_fatal(session, c"unexpected characters after heredoc tag", line_number, start - line_start_cached(source, start) + 1)
            return StringScanResult(next_pos = start, lines_consumed = 1)

    var content_line_starts = vec.Vec[ptr_uint].create()
    var content_line_lengths = vec.Vec[ptr_uint].create()
    var terminator_after = line_end
    var found_terminator = false
    var consumed: ptr_uint = 1

    var scan_offset = line_end

    while scan_offset < session.src_len:
        let (nl_start, nl_end, nl_has_newline) = find_line_bounds(source, scan_offset)

        var nl_len = nl_end - nl_start
        if nl_has_newline:
            nl_len -= 1
        nl_len = trim_trailing_cr(source, nl_start, nl_len)

        if heredoc_terminator_match(source, nl_start, nl_len, tag_start, tag_end - tag_start):
            found_terminator = true
            # Ruby: end_offset points to the END of the terminator line content
            # (before its newline), NOT past the newline.
            terminator_after = nl_start + nl_len
            consumed += 1
            break

        content_line_starts.push(nl_start)
        content_line_lengths.push(nl_len)
        consumed += 1

        scan_offset = nl_end

    if not found_terminator:
        session_fatal(session, c"unterminated heredoc literal", line_number, start - line_start_cached(source, start) + 1)
        content_line_starts.release()
        content_line_lengths.release()
        return StringScanResult(next_pos = start, lines_consumed = 1)

    # Compute minimum indentation of non-empty content lines
    var min_indent: ptr_uint = 0
    var min_set = false
    var i: ptr_uint = 0
    while i < content_line_starts.len():
        let cl_start = content_line_starts.get(i) else:
            break
        let cl_len = content_line_lengths.get(i) else:
            break
        if not line_is_blank(source, unsafe: read(cl_start), unsafe: read(cl_len)):
            let ci = count_indent(source, unsafe: read(cl_start), unsafe: read(cl_len))
            if not min_set or ci < min_indent:
                min_indent = ci
                min_set = true
        i += 1

    let kind = (if is_format: tk.TokenKind.fstring else: (if is_cstring: tk.TokenKind.cstring else: tk.TokenKind.string))
    let lsc = line_start_cached(source, start)
    let col = start - lsc + 1
    let tok = tok.Token(
        kind = kind,
        start_offset = start,
        end_offset = terminator_after,
        line = line_number,
        column = col,
    )
    session.tokens.push(tok)

    content_line_starts.release()
    content_line_lengths.release()

    return StringScanResult(next_pos = terminator_after, lines_consumed = consumed)


function heredoc_terminator_match(
    source: str,
    line_start: ptr_uint,
    line_len: ptr_uint,
    tag_start: ptr_uint,
    tag_len: ptr_uint,
) -> bool:
    var pos = line_start
    while pos < line_start + line_len:
        let b = unsafe: ubyte<-read(source.data + pos)
        if b != SPACE_BYTE:
            break
        pos += 1

    if ptr_uint<-(line_start + line_len) - pos < tag_len:
        return false

    var t: ptr_uint = 0
    while t < tag_len:
        let src_byte = unsafe: ubyte<-read(source.data + pos + t)
        let tag_byte = unsafe: ubyte<-read(source.data + tag_start + t)
        if src_byte != tag_byte:
            return false
        t += 1

    pos += tag_len

    while pos < line_start + line_len:
        let b = unsafe: ubyte<-read(source.data + pos)
        if b != SPACE_BYTE:
            return false
        pos += 1

    return true


function line_start_cached(source: str, pos: ptr_uint) -> ptr_uint:
    var result = pos
    while result > 0:
        result -= 1
        let b = unsafe: ubyte<-read(source.data + result)
        if b == NEWLINE_BYTE:
            return result + 1
    return 0


# =============================================================================
#  Format strings
# =============================================================================

function scan_format_string(
    session: ref[LexSession],
    start: ptr_uint,
    line_stop: ptr_uint,
    line_number: ptr_uint,
    line_start: ptr_uint,
) -> ptr_uint:
    let source = session.source
    var pos = start + 2
    var depth: int = 0

    while pos < session.src_len:
        let b = unsafe: ubyte<-read(source.data + pos)

        if b == DOUBLE_QUOTE and depth == 0:
            pos += 1
            let tok = tok.Token(
                kind = tk.TokenKind.fstring,
                start_offset = start,
                end_offset = pos,
                line = line_number,
                column = start - line_start + 1,
            )
            session.tokens.push(tok)
            return pos

        if b == '{':
            depth += 1
            pos += 1
            continue

        if b == '}':
            if depth > 0:
                depth -= 1
            pos += 1
            continue

        if b == DOUBLE_QUOTE and depth > 0:
            pos += 1
            while pos < session.src_len:
                let inner_b = unsafe: ubyte<-read(source.data + pos)
                if inner_b == DOUBLE_QUOTE:
                    pos += 1
                    break
                if inner_b == BACKSLASH and pos + 1 < session.src_len:
                    pos += 2
                else:
                    pos += 1
            continue

        if b == BACKSLASH:
            if pos + 1 >= session.src_len:
                session_fatal(session, c"unterminated format string literal", line_number, start - line_start + 1)
                return pos
            pos += 2
            continue

        pos += 1

    session_fatal(session, c"unterminated format string literal", line_number, start - line_start + 1)
    return pos


# =============================================================================
#  Operator token lookup tables
# =============================================================================

function three_char_token(ch0: char, ch1: char, ch2: char) -> tk.TokenKind:
    let t = (ch0, ch1, ch2)
    return match t:
        ('.', '.', '.'): tk.TokenKind.ellipsis
        ('<', '<', '='): tk.TokenKind.shift_left_equal
        ('>', '>', '='): tk.TokenKind.shift_right_equal
        _:               tk.TokenKind.eof


function two_char_token(ch0: char, ch1: char) -> tk.TokenKind:
    let t = (ch0, ch1)
    return match t:
        ('-', '>'): tk.TokenKind.arrow
        ('.', '.'): tk.TokenKind.dot_dot
        ('<', '<'): tk.TokenKind.shift_left
        ('>', '>'): tk.TokenKind.shift_right
        ('+', '='): tk.TokenKind.plus_equal
        ('-', '='): tk.TokenKind.minus_equal
        ('*', '='): tk.TokenKind.star_equal
        ('/', '='): tk.TokenKind.slash_equal
        ('%', '='): tk.TokenKind.percent_equal
        ('&', '='): tk.TokenKind.amp_equal
        ('|', '='): tk.TokenKind.pipe_equal
        ('^', '='): tk.TokenKind.caret_equal
        ('=', '='): tk.TokenKind.equal_equal
        ('!', '='): tk.TokenKind.bang_equal
        ('<', '='): tk.TokenKind.less_equal
        ('>', '='): tk.TokenKind.greater_equal
        _:          tk.TokenKind.eof


function one_char_token(ch: char) -> tk.TokenKind:
    if ch == '&':
        return tk.TokenKind.amp
    if ch == '@':
        return tk.TokenKind.at
    if ch == ':':
        return tk.TokenKind.colon
    if ch == ',':
        return tk.TokenKind.comma
    if ch == '^':
        return tk.TokenKind.caret
    if ch == '.':
        return tk.TokenKind.dot
    if ch == '(':
        return tk.TokenKind.lparen
    if ch == ')':
        return tk.TokenKind.rparen
    if ch == '|':
        return tk.TokenKind.pipe
    if ch == '[':
        return tk.TokenKind.lbracket
    if ch == ']':
        return tk.TokenKind.rbracket
    if ch == '?':
        return tk.TokenKind.question
    if ch == '=':
        return tk.TokenKind.equal
    if ch == '+':
        return tk.TokenKind.plus
    if ch == '-':
        return tk.TokenKind.minus
    if ch == '*':
        return tk.TokenKind.star
    if ch == '/':
        return tk.TokenKind.slash
    if ch == '%':
        return tk.TokenKind.percent
    if ch == '<':
        return tk.TokenKind.less
    if ch == '>':
        return tk.TokenKind.greater
    if ch == '~':
        return tk.TokenKind.tilde
    return tk.TokenKind.eof
