## Self-hosted Milk Tea lexer.
##
## Reads .mt source and outputs token JSON matching the Ruby mtc lexer format,
## consumable by `mtc parse --from-tokens-json`.

import std.string as string_mod
import std.fmt as fmt
import std.vec as vec_mod
import std.str as str_util
import std.mem.heap as heap_mod

import lexer.keywords as kw

# ── character classification ──────────────────────────────────────────────

function is_alpha_ch(ch: ubyte) -> bool:
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_'

function is_digit_ch(ch: ubyte) -> bool:
    return ch >= '0' and ch <= '9'

function is_alnum_ch(ch: ubyte) -> bool:
    return is_alpha_ch(ch) or is_digit_ch(ch)

function is_hex_digit_ch(ch: ubyte) -> bool:
    return is_digit_ch(ch) or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F')

function is_bin_digit_ch(ch: ubyte) -> bool:
    return ch == '0' or ch == '1'

# ── line-continuation operator kinds ──────────────────────────────────────

function is_cont_op(kind: str) -> bool:
    return match kind:
        "dot_dot":         true
        "plus":            true
        "minus":           true
        "star":            true
        "slash":           true
        "percent":         true
        "pipe":            true
        "amp":             true
        "caret":           true
        "or":              true
        "and":             true
        "equal_equal":     true
        "bang_equal":      true
        "less":            true
        "less_equal":      true
        "greater":         true
        "greater_equal":   true
        "shift_left":      true
        "shift_right":     true
        _:                 false

# ── integer suffix stripping ──────────────────────────────────────────────

function strip_int_suffix(lex: str) -> str:
    if lex.ends_with("ub"):  return lex.slice(0, lex.len - 2)
    if lex.ends_with("us"):  return lex.slice(0, lex.len - 2)
    if lex.ends_with("ul"):  return lex.slice(0, lex.len - 2)
    if lex.ends_with("iz"):  return lex.slice(0, lex.len - 2)
    if lex.ends_with("b"):   return lex.slice(0, lex.len - 1)
    if lex.ends_with("s"):   return lex.slice(0, lex.len - 1)
    if lex.ends_with("i"):   return lex.slice(0, lex.len - 1)
    if lex.ends_with("u"):   return lex.slice(0, lex.len - 1)
    if lex.ends_with("l"):   return lex.slice(0, lex.len - 1)
    if lex.ends_with("z"):   return lex.slice(0, lex.len - 1)
    return lex

# ── integer parsing ───────────────────────────────────────────────────────

function parse_int_body(text: str, base_val: ulong) -> ulong:
    var result: ulong = 0
    var i: ptr_uint = 0
    while i < text.len:
        let ch = text.byte_at(i)
        if ch == '_':
            i += 1
            continue
        var dv: ulong
        if ch >= '0' and ch <= '9':
            dv = ulong<-(int<-ch - 48)
        else if ch >= 'a' and ch <= 'f':
            dv = ulong<-(int<-ch - 87)
        else if ch >= 'A' and ch <= 'F':
            dv = ulong<-(int<-ch - 55)
        else:
            dv = 0
        result = result * base_val + dv
        i += 1
    return result

public function parse_int(lex: str) -> ulong:
    let body = strip_int_suffix(lex)
    if body.starts_with("0x") or body.starts_with("0X"):
        return parse_int_body(body.slice(2, body.len - 2), 16ul)
    else if body.starts_with("0b") or body.starts_with("0B"):
        return parse_int_body(body.slice(2, body.len - 2), 2ul)
    return parse_int_body(body, 10ul)

# ── float literal to JSON number ──────────────────────────────────────────

public function float_lit_json(lex: str) -> string_mod.String:
    var result = string_mod.String.create()
    var i: ptr_uint = 0
    while i < lex.len:
        let ch = lex.byte_at(i)
        if ch == '_':
            pass
        else if ch == 'f' or ch == 'd':
            pass
        else if ch == 'E':
            result.push_byte('e')
        else:
            result.push_byte(ch)
        i += 1
    return result

# ── JSON string escaping ──────────────────────────────────────────────────

public function json_escaped(src: str) -> string_mod.String:
    var buf = string_mod.String.create()
    buf.push_byte('"')
    var i: ptr_uint = 0
    while i < src.len:
        let ch = src.byte_at(i)
        if ch == '"':
            buf.append("\\\"")
        else if ch == '\\':
            buf.append("\\\\")
        else if ch == '\n':
            buf.append("\\n")
        else if ch == '\r':
            buf.append("\\r")
        else if ch == '\t':
            buf.append("\\t")
        else if ch < 32:
            buf.append("\\u00")
            let hi = ch / 16
            let lo = ch % 16
            if hi < 10:
                buf.push_byte(ubyte<-(48 + int<-hi))
            else:
                buf.push_byte(ubyte<-(87 + int<-hi))
            if lo < 10:
                buf.push_byte(ubyte<-(48 + int<-lo))
            else:
                buf.push_byte(ubyte<-(87 + int<-lo))
        else:
            buf.push_byte(ch)
        i += 1
    buf.push_byte('"')
    return buf

# ── lexer state ───────────────────────────────────────────────────────────

public struct Token:
    kind: str
    lexeme: str
    lit_json: str
    line: ptr_uint
    column: ptr_uint

struct LexState:
    src: str
    pos: ptr_uint
    buf: string_mod.String
    first_tok: bool
    indent_stack: vec_mod.Vec[ptr_uint]
    group_depth: ptr_uint
    cont_pending: bool
    line_done: bool
    line_off: ptr_uint
    line_num: ptr_uint
    output_tokens: vec_mod.Vec[Token]

# ── token emission ────────────────────────────────────────────────────────

function emit_tok(
    state: ref[LexState],
    kind: str,
    lexeme: str,
    lit_json: str,
    line: ptr_uint,
    column: ptr_uint,
    start_off: ptr_uint,
    end_off: ptr_uint,
) -> void:
    if not state.first_tok:
        state.buf.push_byte(',')

    state.buf.append("{\"type\":")
    var et = json_escaped(kind)
    state.buf.append(et.as_str())
    et.release()

    state.buf.append(",\"lexeme\":")
    var el = json_escaped(lexeme)
    state.buf.append(el.as_str())
    el.release()

    state.buf.append(",\"literal\":")
    state.buf.append(lit_json)

    state.buf.append(",\"line\":")
    fmt.append_ptr_uint(ref_of(state.buf), line)

    state.buf.append(",\"column\":")
    fmt.append_ptr_uint(ref_of(state.buf), column)

    state.buf.append(",\"start_offset\":")
    fmt.append_ptr_uint(ref_of(state.buf), start_off)

    state.buf.append(",\"end_offset\":")
    fmt.append_ptr_uint(ref_of(state.buf), end_off)

    state.buf.push_byte('}')
    state.first_tok = false

    var tok = Token(
        kind = kind,
        lexeme = lexeme,
        lit_json = lit_json,
        line = line,
        column = column,
    )
    state.output_tokens.push(tok)

# ── indentation ───────────────────────────────────────────────────────────

function handle_indent(state: ref[LexState], indent_spaces: ptr_uint, line_start: ptr_uint) -> void:
    if state.cont_pending:
        state.cont_pending = false
        return

    if state.group_depth > 0:
        return

    let top_opt = state.indent_stack.last() else:
        fatal(c"lexer: indent stack empty")
    var cur = unsafe: read(top_opt)

    if indent_spaces > cur:
        if indent_spaces != cur + 4:
            fatal(c"lexer: indent must increase by exactly 4 spaces")
        emit_tok(state, "indent", "", "null", state.line_num, 1, line_start, line_start)
        state.indent_stack.push(indent_spaces)
        return

    while indent_spaces < cur:
        if state.indent_stack.len <= 1:
            break
        emit_tok(state, "dedent", "", "null", state.line_num, 1, line_start, line_start)
        state.indent_stack.pop()
        let new_top = state.indent_stack.last() else:
            break
        cur = unsafe: read(new_top)

# ── number lexing ─────────────────────────────────────────────────────────
# advances state.pos past the token

function lex_number(state: ref[LexState], offset: ptr_uint, column: ptr_uint) -> void:
    let s = state.src
    var i = offset
    var is_float = false

    if i < s.len and s.byte_at(i) == '0':
        let after = i + 1
        if after < s.len:
            let c2 = s.byte_at(after)
            if c2 == 'x' or c2 == 'X':
                i += 2
                while i < s.len and (is_hex_digit_ch(s.byte_at(i)) or s.byte_at(i) == '_'):
                    i += 1
                while i < s.len and (
                    s.byte_at(i) == 'u' or s.byte_at(i) == 'b'
                    or s.byte_at(i) == 's' or s.byte_at(i) == 'i'
                    or s.byte_at(i) == 'l' or s.byte_at(i) == 'z'
                ):
                    i += 1
                let end_off = i
                let lm = s.slice(offset, end_off - offset)
                let lit = parse_int(lm)
                var ls = string_mod.String.create()
                fmt.append_ulong(ref_of(ls), lit)
                emit_tok(state, "integer", lm, ls.as_str(), state.line_num, column, offset, end_off)
                ls.release()
                state.pos = end_off
                return

            else if c2 == 'b' or c2 == 'B':
                i += 2
                while i < s.len and (is_bin_digit_ch(s.byte_at(i)) or s.byte_at(i) == '_'):
                    i += 1
                while i < s.len and (
                    s.byte_at(i) == 'u' or s.byte_at(i) == 'b'
                    or s.byte_at(i) == 's' or s.byte_at(i) == 'i'
                    or s.byte_at(i) == 'l' or s.byte_at(i) == 'z'
                ):
                    i += 1
                let end_off = i
                let lm = s.slice(offset, end_off - offset)
                let lit = parse_int(lm)
                var ls = string_mod.String.create()
                fmt.append_ulong(ref_of(ls), lit)
                emit_tok(state, "integer", lm, ls.as_str(), state.line_num, column, offset, end_off)
                ls.release()
                state.pos = end_off
                return

    while i < s.len:
        let ch = s.byte_at(i)
        if ch == '_':
            i += 1
            continue
        if ch == '.':
            let ni = i + 1
            if ni < s.len and is_digit_ch(s.byte_at(ni)):
                is_float = true
                i += 1
                continue
            break
        if ch == 'e' or ch == 'E':
            is_float = true
            i += 1
            if i < s.len and (s.byte_at(i) == '+' or s.byte_at(i) == '-'):
                i += 1
            while i < s.len and is_digit_ch(s.byte_at(i)):
                i += 1
            break
        if not is_digit_ch(ch):
            break
        i += 1

    if is_float:
        if i < s.len and (s.byte_at(i) == 'f' or s.byte_at(i) == 'd'):
            i += 1
        let end_off = i
        let lm = s.slice(offset, end_off - offset)
        var lit_str = float_lit_json(lm)
        emit_tok(state, "float", lm, lit_str.as_str(), state.line_num, column, offset, end_off)
        lit_str.release()
        state.pos = end_off
        return

    while i < s.len and (
        s.byte_at(i) == 'u' or s.byte_at(i) == 'b'
        or s.byte_at(i) == 's' or s.byte_at(i) == 'i'
        or s.byte_at(i) == 'l' or s.byte_at(i) == 'z'
    ):
        i += 1

    let end_off = i
    let lm = s.slice(offset, end_off - offset)
    let lit = parse_int(lm)
    var ls = string_mod.String.create()
    fmt.append_ulong(ref_of(ls), lit)
    emit_tok(state, "integer", lm, ls.as_str(), state.line_num, column, offset, end_off)
    ls.release()
    state.pos = end_off

# ── string literal lexing ─────────────────────────────────────────────────
# advances state.pos

function lex_strlit(state: ref[LexState], offset: ptr_uint, column: ptr_uint, prefix: str) -> void:
    let s = state.src
    var i = offset
    var content = string_mod.String.create()

    let has_prefix = not prefix.equal("")
    if has_prefix:
        i += 1
    i += 1

    var consumed_lines: ptr_uint = 1
    var last_line_start: ptr_uint = state.line_off
    var line_indent: ptr_uint = 0
    var li_scan = state.line_off
    while li_scan < s.len and s.byte_at(li_scan) == ' ':
        line_indent += 1
        li_scan += 1

    while true:
        while i < s.len:
            let ch = s.byte_at(i)
            if ch == '"':
                i += 1
                break
            else if ch == '\\':
                i += 1
                if i >= s.len:
                    fatal(c"lexer: eof in string escape")
                let esc = s.byte_at(i)
                i += 1
                if esc == 'n':
                    content.push_byte('\n')
                else if esc == 'r':
                    content.push_byte('\r')
                else if esc == 't':
                    content.push_byte('\t')
                else if esc == '0':
                    content.push_byte(0)
                else if esc == '"':
                    content.push_byte('"')
                else if esc == '\'':
                    content.push_byte('\'')
                else if esc == '\\':
                    content.push_byte('\\')
                else:
                    content.push_byte(esc)
            else if ch == '\n':
                fatal(c"lexer: newline in string literal")
            else:
                content.push_byte(ch)
                i += 1

        if i >= s.len:
            break

        if prefix.equal(""):
            var peek = i
            if peek < s.len and s.byte_at(peek) == '\n':
                peek += 1
                let line_start_after_nl = peek
                var indent_cnt: ptr_uint = 0
                while peek < s.len and s.byte_at(peek) == ' ':
                    indent_cnt += 1
                    peek += 1
                if indent_cnt > line_indent and peek < s.len and s.byte_at(peek) == '"':
                    last_line_start = line_start_after_nl
                    i = peek + 1
                    consumed_lines += 1
                    continue

        break

    let end_off = i
    let lm = s.slice(offset, end_off - offset)
    let kind = if prefix.equal("c"): "cstring" else: "string"
    var lit = json_escaped(content.as_str())
    emit_tok(state, kind, lm, lit.as_str(), state.line_num, column, offset, end_off)
    lit.release()
    content.release()

    if consumed_lines > 1:
        state.line_num = state.line_num + consumed_lines - 1
        state.line_off = last_line_start
        state.pos = end_off
    else:
        state.pos = end_off

# ── character literal lexing ──────────────────────────────────────────────
# advances state.pos

function lex_charlit(state: ref[LexState], offset: ptr_uint, column: ptr_uint) -> void:
    let s = state.src
    var i = offset + 1
    var val: int

    if i >= s.len:
        fatal(c"lexer: eof in char literal")

    let first = s.byte_at(i)
    if first == '\'':
        fatal(c"lexer: empty char literal")

    if first == '\\':
        i += 1
        if i >= s.len:
            fatal(c"lexer: eof in char escape")
        let esc = s.byte_at(i)
        if esc == 'n':
            val = 10
        else if esc == 'r':
            val = 13
        else if esc == 't':
            val = 9
        else if esc == '0':
            val = 0
        else if esc == '\\':
            val = 92
        else if esc == '\'':
            val = 39
        else if esc == '"':
            val = 34
        else if esc == 'x':
            i += 1
            var hv: int = 0
            var hc: int = 0
            while i < s.len and hc < 2 and is_hex_digit_ch(s.byte_at(i)):
                let dc = s.byte_at(i)
                var dv: int
                if dc >= '0' and dc <= '9':
                    dv = int<-dc - 48
                else if dc >= 'a' and dc <= 'f':
                    dv = int<-dc - 87
                else if dc >= 'A' and dc <= 'F':
                    dv = int<-dc - 55
                else:
                    dv = 0
                hv = hv * 16 + dv
                hc += 1
                i += 1
            if hc == 0:
                fatal(c"lexer: expected hex digit after \\x")
            val = hv
            if i >= s.len or s.byte_at(i) != '\'':
                fatal(c"lexer: expected ' after char literal")
            i += 1
            let end_off = i
            let lm = s.slice(offset, end_off - offset)
            var ls = string_mod.String.create()
            fmt.append_int(ref_of(ls), val)
            emit_tok(state, "char_literal", lm, ls.as_str(), state.line_num, column, offset, end_off)
            ls.release()
            state.pos = end_off
            return
        else:
            val = int<-esc
        i += 1
    else:
        val = int<-first
        i += 1

    if i >= s.len or s.byte_at(i) != '\'':
        fatal(c"lexer: expected closing ' in char literal")

    i += 1
    let end_off = i
    let lm = s.slice(offset, end_off - offset)
    var ls = string_mod.String.create()
    fmt.append_int(ref_of(ls), val)
    emit_tok(state, "char_literal", lm, ls.as_str(), state.line_num, column, offset, end_off)
    ls.release()
    state.pos = end_off

# ── identifier / keyword lexing ───────────────────────────────────────────
# returns the token kind; advances state.pos

function lex_ident(state: ref[LexState], offset: ptr_uint, column: ptr_uint) -> str:
    let s = state.src
    var i = offset
    while i < s.len:
        let ch = s.byte_at(i)
        if not is_alnum_ch(ch):
            break
        i += 1

    let end_off = i
    let ident = s.slice(offset, end_off - offset)
    let kind = kw.kw_type(ident)

    var lit: str
    if kind == "true":
        lit = "true"
    else if kind == "false":
        lit = "false"
    else if kind == "null":
        lit = "null"
    else:
        lit = "null"

    emit_tok(state, kind, ident, lit, state.line_num, column, offset, end_off)
    state.pos = end_off
    return kind

# ── 3-char symbols ────────────────────────────────────────────────────────
# returns true if matched; advances state.pos

function try_3char(state: ref[LexState], offset: ptr_uint, column: ptr_uint) -> bool:
    let s = state.src
    if offset + 3 > s.len:
        return false

    let c0 = s.byte_at(offset)
    let c1 = s.byte_at(offset + 1)
    let c2 = s.byte_at(offset + 2)

    if c0 == '.' and c1 == '.' and c2 == '.':
        emit_tok(state, "ellipsis", "...", "null", state.line_num, column, offset, offset + 3)
        state.pos = offset + 3
        return true
    if c0 == '<' and c1 == '<' and c2 == '=':
        emit_tok(state, "shift_left_equal", "<<=", "null", state.line_num, column, offset, offset + 3)
        state.pos = offset + 3
        return true
    if c0 == '>' and c1 == '>' and c2 == '=':
        emit_tok(state, "shift_right_equal", ">>=", "null", state.line_num, column, offset, offset + 3)
        state.pos = offset + 3
        return true

    return false

# ── 2-char symbols ────────────────────────────────────────────────────────
# returns true if matched; advances state.pos

function try_2char(state: ref[LexState], offset: ptr_uint, column: ptr_uint) -> bool:
    let s = state.src
    if offset + 2 > s.len:
        return false

    let c0 = s.byte_at(offset)
    let c1 = s.byte_at(offset + 1)

    var kind: str
    if c0 == '-' and c1 == '>':
        kind = "arrow"
    else if c0 == '.' and c1 == '.':
        kind = "dot_dot"
    else if c0 == '<' and c1 == '<':
        # Could be <<= (handled by 3-char), or << (shift_left), or heredoc (handled elsewhere)
        kind = "shift_left"
    else if c0 == '>' and c1 == '>':
        kind = "shift_right"
    else if c0 == '+' and c1 == '=':
        kind = "plus_equal"
    else if c0 == '-' and c1 == '=':
        kind = "minus_equal"
    else if c0 == '*' and c1 == '=':
        kind = "star_equal"
    else if c0 == '/' and c1 == '=':
        kind = "slash_equal"
    else if c0 == '%' and c1 == '=':
        kind = "percent_equal"
    else if c0 == '&' and c1 == '=':
        kind = "amp_equal"
    else if c0 == '|' and c1 == '=':
        kind = "pipe_equal"
    else if c0 == '^' and c1 == '=':
        kind = "caret_equal"
    else if c0 == '=' and c1 == '=':
        kind = "equal_equal"
    else if c0 == '!' and c1 == '=':
        kind = "bang_equal"
    else if c0 == '<' and c1 == '=':
        kind = "less_equal"
    else if c0 == '>' and c1 == '=':
        kind = "greater_equal"
    else:
        return false

    let lm = s.slice(offset, 2)
    emit_tok(state, kind, lm, "null", state.line_num, column, offset, offset + 2)
    state.pos = offset + 2
    return true

# ── 1-char symbols ────────────────────────────────────────────────────────
# returns true if matched; advances state.pos

function try_1char(state: ref[LexState], offset: ptr_uint, column: ptr_uint) -> bool:
    let s = state.src
    if offset >= s.len:
        return false

    let ch = s.byte_at(offset)
    var kind: str

    if ch == '(':
        kind = "lparen"
        state.group_depth += 1
    else if ch == ')':
        kind = "rparen"
        if state.group_depth > 0:
            state.group_depth -= 1
    else if ch == '[':
        kind = "lbracket"
        state.group_depth += 1
    else if ch == ']':
        kind = "rbracket"
        if state.group_depth > 0:
            state.group_depth -= 1
    else if ch == ',':
        kind = "comma"
    else if ch == ':':
        kind = "colon"
    else if ch == '.':
        kind = "dot"
    else if ch == '@':
        kind = "at"
    else if ch == '~':
        kind = "tilde"
    else if ch == '?':
        kind = "question"
    else if ch == '=':
        kind = "equal"
    else if ch == '+':
        kind = "plus"
    else if ch == '-':
        kind = "minus"
    else if ch == '*':
        kind = "star"
    else if ch == '/':
        kind = "slash"
    else if ch == '%':
        kind = "percent"
    else if ch == '<':
        kind = "less"
    else if ch == '>':
        kind = "greater"
    else if ch == '&':
        kind = "amp"
    else if ch == '|':
        kind = "pipe"
    else if ch == '^':
        kind = "caret"
    else:
        return false

    let lm = s.slice(offset, 1)
    emit_tok(state, kind, lm, "null", state.line_num, column, offset, offset + 1)
    state.pos = offset + 1
    return true

# ── format string lexing (f"...") ─────────────────────────────────────────
# advances state.pos

function lex_fstring(state: ref[LexState], offset: ptr_uint, column: ptr_uint) -> void:
    let s = state.src
    var i = offset + 2
    var parts = string_mod.String.create()
    parts.push_byte('[')
    var first_part = true

    var text = string_mod.String.create()

    while i < s.len:
        let ch = s.byte_at(i)

        if ch == '"':
            i += 1
            break

        if ch == '#' and i + 1 < s.len and s.byte_at(i + 1) == '{':
            if text.len > 0:
                if not first_part:
                    parts.push_byte(',')
                parts.append("{\"kind\":\"text\",\"value\":")
                var te = json_escaped(text.as_str())
                parts.append(te.as_str())
                te.release()
                parts.push_byte('}')
                text.clear()
                first_part = false

            i += 2
            let expr_col_start = ptr_uint<-(i - state.line_off + 1)
            var expr = string_mod.String.create()
            var inner: ptr_uint = 1
            var fmt_spec = string_mod.String.create()

            while i < s.len and inner > 0:
                let ec = s.byte_at(i)
                if ec == '{':
                    inner += 1
                    expr.push_byte(ec)
                    i += 1
                else if ec == '}':
                    inner -= 1
                    if inner > 0:
                        expr.push_byte(ec)
                    i += 1
                else if ec == ':' and inner == 1:
                    i += 1
                    while i < s.len and s.byte_at(i) != '}':
                        let fc = s.byte_at(i)
                        if fc == '{':
                            inner += 1
                        else if fc == '}':
                            inner -= 1
                            if inner == 0:
                                break
                        if inner > 0:
                            fmt_spec.push_byte(fc)
                        i += 1
                else:
                    expr.push_byte(ec)
                    i += 1

            if not first_part:
                parts.push_byte(',')
            parts.append("{\"kind\":\"expr\",\"source\":")
            var se = json_escaped(expr.as_str())
            parts.append(se.as_str())
            se.release()

            let expr_line = state.line_num
            let expr_col = expr_col_start
            parts.append(",\"line\":")
            fmt.append_ptr_uint(ref_of(parts), expr_line)
            parts.append(",\"column\":")
            fmt.append_ptr_uint(ref_of(parts), expr_col)

            if fmt_spec.len > 0:
                parts.append(",\"format_spec\":")
                var fe = json_escaped(fmt_spec.as_str())
                parts.append(fe.as_str())
                fe.release()
            else:
                parts.append(",\"format_spec\":null")

            parts.push_byte('}')
            expr.release()
            fmt_spec.release()
            first_part = false
            continue

        if ch == '\\':
            i += 1
            if i >= s.len:
                fatal(c"lexer: eof in fstring escape")
            let esc = s.byte_at(i)
            i += 1
            if esc == 'n':
                text.push_byte('\n')
            else if esc == 'r':
                text.push_byte('\r')
            else if esc == 't':
                text.push_byte('\t')
            else if esc == '0':
                text.push_byte(0)
            else if esc == '"':
                text.push_byte('"')
            else if esc == '\'':
                text.push_byte('\'')
            else if esc == '\\':
                text.push_byte('\\')
            else:
                text.push_byte(esc)
            continue

        text.push_byte(ch)
        i += 1

    if text.len > 0 or first_part:
        if not first_part:
            parts.push_byte(',')
        parts.append("{\"kind\":\"text\",\"value\":")
        var te = json_escaped(text.as_str())
        parts.append(te.as_str())
        te.release()
        parts.push_byte('}')

    parts.push_byte(']')

    let end_off = i
    let lm = s.slice(offset, end_off - offset)
    emit_tok(state, "fstring", lm, parts.as_str(), state.line_num, column, offset, end_off)
    parts.release()
    text.release()
    state.pos = end_off

# ── heredoc f-string interpolation ────────────────────────────────────────
# Parses #{...} parts from a dedented heredoc content buffer.

function heredoc_fstring_parts(content: str, start_line: ptr_uint, base_col: ptr_uint) -> string_mod.String:
    var parts = string_mod.String.create()
    parts.push_byte('[')
    var first_part = true
    var text = string_mod.String.create()

    var line = start_line
    var col = base_col

    var i: ptr_uint = 0
    while i < content.len:
        let ch = content.byte_at(i)

        if ch == '#' and i + 1 < content.len and content.byte_at(i + 1) == '{':
            if text.len > 0:
                if not first_part:
                    parts.push_byte(',')
                parts.append("{\"kind\":\"text\",\"value\":")
                var te = json_escaped(text.as_str())
                parts.append(te.as_str())
                te.release()
                parts.push_byte('}')
                text.clear()
                first_part = false

            let expr_line = line
            let expr_col = col + 2
            i += 2
            col += 2

            var expr = string_mod.String.create()
            var fmt_spec = string_mod.String.create()
            var inner: ptr_uint = 1
            var in_spec = false

            while i < content.len and inner > 0:
                let ec = content.byte_at(i)
                if ec == '\n':
                    if in_spec:
                        fmt_spec.push_byte(ec)
                    else:
                        expr.push_byte(ec)
                    line += 1
                    col = base_col
                    i += 1
                else if ec == '{':
                    inner += 1
                    if in_spec:
                        fmt_spec.push_byte(ec)
                    else:
                        expr.push_byte(ec)
                    col += 1
                    i += 1
                else if ec == '}':
                    inner -= 1
                    if inner > 0:
                        if in_spec:
                            fmt_spec.push_byte(ec)
                        else:
                            expr.push_byte(ec)
                    col += 1
                    i += 1
                else if ec == ':' and inner == 1 and not in_spec:
                    in_spec = true
                    col += 1
                    i += 1
                else:
                    if in_spec:
                        fmt_spec.push_byte(ec)
                    else:
                        expr.push_byte(ec)
                    col += 1
                    i += 1

            if not first_part:
                parts.push_byte(',')
            parts.append("{\"kind\":\"expr\",\"source\":")
            var se = json_escaped(expr.as_str())
            parts.append(se.as_str())
            se.release()
            parts.append(",\"line\":")
            fmt.append_ptr_uint(ref_of(parts), expr_line)
            parts.append(",\"column\":")
            fmt.append_ptr_uint(ref_of(parts), expr_col)
            if fmt_spec.len > 0:
                parts.append(",\"format_spec\":")
                var fe = json_escaped(fmt_spec.as_str())
                parts.append(fe.as_str())
                fe.release()
            else:
                parts.append(",\"format_spec\":null")
            parts.push_byte('}')

            expr.release()
            fmt_spec.release()
            first_part = false
            continue

        if ch == '\n':
            line += 1
            col = base_col
        else:
            col += 1
        text.push_byte(ch)
        i += 1

    if text.len > 0 or first_part:
        if not first_part:
            parts.push_byte(',')
        parts.append("{\"kind\":\"text\",\"value\":")
        var te = json_escaped(text.as_str())
        parts.append(te.as_str())
        te.release()
        parts.push_byte('}')

    parts.push_byte(']')
    text.release()
    return parts

# ── heredoc lexing ────────────────────────────────────────────────────────
# advances state.pos, line_num, line_off

function lex_heredoc(state: ref[LexState], offset: ptr_uint, column: ptr_uint, is_c: bool, is_f: bool) -> void:
    let s = state.src
    let skip: ptr_uint = if is_c or is_f: 4 else: 3
    var i = offset + skip

    while i < s.len and s.byte_at(i) == ' ':
        i += 1

    let tag_start = i
    while i < s.len and s.byte_at(i) != '\n':
        i += 1
    let tag = s.slice(tag_start, i - tag_start)

    if i < s.len:
        i += 1

    var cur_line = state.line_num + 1
    var content_lines = vec_mod.Vec[str].create()
    var term_end: ptr_uint = i
    var term_line_start: ptr_uint = i
    var term_line_no: ptr_uint = cur_line
    var term_has_nl = false
    while i < s.len:
        let ls = i
        while i < s.len and s.byte_at(i) != '\n':
            i += 1
        let raw = s.slice(ls, i - ls)
        let raw_has_nl = i < s.len
        let trimmed = raw.trim_ascii_whitespace()
        if trimmed.equal(tag):
            term_end = i
            term_line_start = ls
            term_line_no = cur_line
            term_has_nl = raw_has_nl
            if raw_has_nl:
                i += 1
            break
        content_lines.push(raw)
        if raw_has_nl:
            i += 1
        cur_line += 1

    var margin: ptr_uint = heap_mod.ptr_uint_max
    var ci: ptr_uint = 0
    while ci < content_lines.len:
        let item = content_lines.at(ci) else:
            break
        let trimmed_line = item.trim_ascii_whitespace()
        if trimmed_line.len == 0:
            ci += 1
            continue
        var sc: ptr_uint = 0
        var sj: ptr_uint = 0
        while sj < item.len and item.byte_at(sj) == ' ':
            sc += 1
            sj += 1
        if sc < margin:
            margin = sc
        ci += 1
    if margin == heap_mod.ptr_uint_max:
        margin = 0

    var content = string_mod.String.create()
    ci = 0
    while ci < content_lines.len:
        let item2 = content_lines.at(ci) else:
            break
        let trimmed2 = item2.trim_ascii_whitespace()
        if trimmed2.len == 0:
            content.push_byte('\n')
        else:
            content.append(item2.slice(margin, item2.len - margin))
            content.push_byte('\n')
        ci += 1

    let lm = s.slice(offset, term_end - offset)

    if is_f:
        var fparts = heredoc_fstring_parts(content.as_str(), state.line_num + 1, margin + 1)
        emit_tok(state, "fstring", lm, fparts.as_str(), state.line_num, column, offset, term_end)
        fparts.release()
    else:
        let kind = if is_c: "cstring" else: "string"
        var lit = json_escaped(content.as_str())
        emit_tok(state, kind, lm, lit.as_str(), state.line_num, column, offset, term_end)
        lit.release()

    if state.group_depth == 0:
        let nl_end = if term_has_nl: term_end + 1 else: term_end
        let nl_col = ptr_uint<-(term_end - term_line_start + 1)
        emit_tok(state, "newline", "\n", "null", term_line_no, nl_col, term_end, nl_end)

    content_lines.release()
    content.release()

    state.pos = i
    state.line_num = term_line_no + 1
    state.line_off = i
    state.cont_pending = false
    state.line_done = true

# ── line-level tokenization ───────────────────────────────────────────────

function lex_line_tokens(state: ref[LexState], content_start: ptr_uint) -> void:
    var last_kind: str = ""

    while state.pos < state.src.len:
        let ch = state.src.byte_at(state.pos)

        if ch == '\n':
            break

        let abs_start = state.pos
        let col = ptr_uint<-(abs_start - state.line_off + 1)

        if ch == ' ':
            state.pos += 1
            continue

        if ch == '#':
            while state.pos < state.src.len and state.src.byte_at(state.pos) != '\n':
                state.pos += 1
            break

        if ch == '\t':
            fatal(c"lexer: tabs are not allowed in source")

        if ch == '\'':
            lex_charlit(state, abs_start, col)
            last_kind = "char_literal"
            continue

        if ch == 'c' or ch == 'f':
            let has_nxt = state.pos + 1 < state.src.len
            if has_nxt and state.src.byte_at(state.pos + 1) == '<':
                let nxt2 = state.pos + 2 < state.src.len and state.src.byte_at(state.pos + 2) == '<'
                let nxt3 = state.pos + 3 < state.src.len and state.src.byte_at(state.pos + 3) == '-'
                if nxt2 and nxt3:
                    let is_c_hd = ch == 'c'
                    let is_f_hd = ch == 'f'
                    lex_heredoc(state, abs_start, col, is_c_hd, is_f_hd)
                    return

            if has_nxt and state.src.byte_at(state.pos + 1) == '"':
                if ch == 'c':
                    lex_strlit(state, abs_start, col, "c")
                    last_kind = "cstring"
                else:
                    lex_fstring(state, abs_start, col)
                    last_kind = "fstring"
                continue

        if ch == '"':
            lex_strlit(state, abs_start, col, "")
            last_kind = "string"
            continue

        if ch == '<' and state.pos + 1 < state.src.len and state.src.byte_at(state.pos + 1) == '<':
            if state.pos + 2 < state.src.len and state.src.byte_at(state.pos + 2) == '-':
                lex_heredoc(state, abs_start, col, false, false)
                return

        if is_digit_ch(ch):
            lex_number(state, abs_start, col)
            last_kind = "integer"
            continue

        if is_alpha_ch(ch):
            last_kind = lex_ident(state, abs_start, col)
            continue

        if try_3char(state, abs_start, col):
            let lt = state.output_tokens.last() else:
                fatal(c"lexer: no last token")
            last_kind = unsafe: read(lt).kind
            continue

        if try_2char(state, abs_start, col):
            let lt = state.output_tokens.last() else:
                fatal(c"lexer: no last token")
            last_kind = unsafe: read(lt).kind
            continue

        if try_1char(state, abs_start, col):
            let lt = state.output_tokens.last() else:
                fatal(c"lexer: no last token")
            last_kind = unsafe: read(lt).kind
            continue

        state.pos += 1

    state.cont_pending = is_cont_op(last_kind)

# ── main lex loop ─────────────────────────────────────────────────────────

function lex_all(state: ref[LexState]) -> void:
    let s = state.src
    state.pos = 0

    while state.pos < s.len:
        let line_start = state.pos
        var line_end = state.pos
        while line_end < s.len and s.byte_at(line_end) != '\n':
            line_end += 1

        let nl_pos = line_end
        let has_nl = nl_pos < s.len
        let content = s.slice(line_start, nl_pos - line_start)

        var indent_sp: ptr_uint = 0
        var ci: ptr_uint = 0
        while ci < content.len and content.byte_at(ci) == ' ':
            indent_sp += 1
            ci += 1

        if ci < content.len and content.byte_at(ci) == '\t':
            fatal(c"lexer: tabs are not allowed in source")

        let has_cont = ci < content.len

        if not has_cont:
            state.pos = nl_pos
            if has_nl:
                state.pos += 1
            state.line_num += 1
            state.line_off = state.pos
            continue

        if content.byte_at(ci) == '#':
            state.pos = nl_pos
            if has_nl:
                state.pos += 1
            state.line_num += 1
            state.line_off = state.pos
            continue

        if not state.cont_pending:
            if indent_sp % 4 != 0:
                fatal(c"lexer: indentation must be a multiple of 4 spaces")
            handle_indent(state, indent_sp, line_start)

        state.pos = line_start + ci
        lex_line_tokens(state, line_start + ci)

        if state.line_done:
            state.line_done = false
            continue

        let real_nl = state.pos
        let real_has_nl = real_nl < s.len and s.byte_at(real_nl) == '\n'
        let emit_nl = not state.cont_pending and state.group_depth == 0
        let nl_end = if real_has_nl: real_nl + 1 else: real_nl
        let nl_col = ptr_uint<-(real_nl - state.line_off + 1)

        if emit_nl:
            emit_tok(state, "newline", "\n", "null", state.line_num, nl_col, real_nl, nl_end)

        state.pos = nl_end
        state.line_num += 1
        state.line_off = state.pos

    let dedent_line = state.line_num - 1
    while state.indent_stack.len > 1:
        emit_tok(state, "dedent", "", "null", dedent_line, 1, state.pos, state.pos)
        state.indent_stack.pop()

    emit_tok(state, "eof", "", "null", state.line_num, 1, state.pos, state.pos)

# ── public entry point ────────────────────────────────────────────────────

public function lex_to_json(source: str) -> string_mod.String:
    var state = LexState(
        src = source,
        pos = 0,
        buf = string_mod.String.create(),
        first_tok = true,
        indent_stack = vec_mod.Vec[ptr_uint].create(),
        group_depth = 0,
        cont_pending = false,
        line_done = false,
        line_off = 0,
        line_num = 1,
        output_tokens = vec_mod.Vec[Token].create(),
    )
    state.indent_stack.push(0)

    state.buf.push_byte('[')
    lex_all(ref_of(state))
    state.buf.push_byte(']')

    state.indent_stack.release()
    state.output_tokens.release()
    return state.buf

public function lex_to_tokens(source: str) -> vec_mod.Vec[Token]:
    var state = LexState(
        src = source,
        pos = 0,
        buf = string_mod.String.create(),
        first_tok = true,
        indent_stack = vec_mod.Vec[ptr_uint].create(),
        group_depth = 0,
        cont_pending = false,
        line_done = false,
        line_off = 0,
        line_num = 1,
        output_tokens = vec_mod.Vec[Token].create(),
    )
    state.indent_stack.push(0)

    state.buf.push_byte('[')
    lex_all(ref_of(state))
    state.buf.push_byte(']')

    state.indent_stack.release()
    state.buf.release()
    return state.output_tokens
