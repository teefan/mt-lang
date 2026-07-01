import parser.token_stream as ts
import lexer.token as token
import parser.type_parsing as type_parsing
import std.log as log
import std.string
import std.fmt as fmt

public function format_error(stream: ref[ts.TokenStream], message: str) -> str:
    let tok = ts.peek(stream)
    let kind_name = token.token_kind_name(tok.kind)
    var msg = fmt.format(f"#{stream.path}:#{tok.line}:#{tok.column}: error: #{message} (got #{tok.lexeme} / kind=#{kind_name})")
    defer msg.release()
    return message


# ---- Entry point ----

public function parse_expression(stream: ref[ts.TokenStream]) -> bool:
    return parse_range(stream)


# ---- Range ----

function parse_range(stream: ref[ts.TokenStream]) -> bool:
    if not parse_or(stream):
        return false

    if ts.check_symbol(stream, ".."):
        ts.advance(stream)
        return parse_or(stream)

    return true


# ---- Binary operator chain (low to high precedence) ----

function parse_or(stream: ref[ts.TokenStream]) -> bool:
    if not parse_and(stream):
        return false
    while ts.check_keyword(stream, "or"):
        ts.advance(stream)
        if not parse_and(stream):
            return false
    return true


function parse_and(stream: ref[ts.TokenStream]) -> bool:
    if not parse_not(stream):
        return false
    while ts.check_keyword(stream, "and"):
        ts.advance(stream)
        if not parse_not(stream):
            return false
    return true


function parse_not(stream: ref[ts.TokenStream]) -> bool:
    if ts.check_keyword(stream, "not"):
        ts.advance(stream)
        return parse_not(stream)
    return parse_is(stream)


function parse_is(stream: ref[ts.TokenStream]) -> bool:
    if not parse_bitwise_or(stream):
        return false
    if ts.check_keyword(stream, "is"):
        ts.advance(stream)
        parse_is_rhs(stream)
    return true


function parse_is_rhs(stream: ref[ts.TokenStream]) -> void:
    let _ = parse_bitwise_or(stream)


function parse_bitwise_or(stream: ref[ts.TokenStream]) -> bool:
    if not parse_bitwise_xor(stream):
        return false
    while ts.check_symbol(stream, "|"):
        ts.advance(stream)
        if not parse_bitwise_xor(stream):
            return false
    return true


function parse_bitwise_xor(stream: ref[ts.TokenStream]) -> bool:
    if not parse_bitwise_and(stream):
        return false
    while ts.check_symbol(stream, "^"):
        ts.advance(stream)
        if not parse_bitwise_and(stream):
            return false
    return true


function parse_bitwise_and(stream: ref[ts.TokenStream]) -> bool:
    if not parse_equality(stream):
        return false
    while ts.check_symbol(stream, "&"):
        ts.advance(stream)
        if not parse_equality(stream):
            return false
    return true


function parse_equality(stream: ref[ts.TokenStream]) -> bool:
    if not parse_comparison(stream):
        return false
    while ts.check_symbol(stream, "==") or ts.check_symbol(stream, "!="):
        ts.advance(stream)
        if not parse_comparison(stream):
            return false
    return true


function parse_comparison(stream: ref[ts.TokenStream]) -> bool:
    if not parse_shift(stream):
        return false
    let tok = ts.peek(stream)
    if tok.kind == token.TokenKind.symbol and (
        tok.lexeme == "<" or tok.lexeme == "<=" or tok.lexeme == ">" or tok.lexeme == ">="
    ):
        ts.advance(stream)
        if not parse_shift(stream):
            return false
    return true


function parse_shift(stream: ref[ts.TokenStream]) -> bool:
    if not parse_additive(stream):
        return false
    let tok = ts.peek(stream)
    if tok.kind == token.TokenKind.symbol and (tok.lexeme == "<<" or tok.lexeme == ">>"):
        ts.advance(stream)
        if not parse_additive(stream):
            return false
    return true


function parse_additive(stream: ref[ts.TokenStream]) -> bool:
    if not parse_multiplicative(stream):
        return false
    let tok = ts.peek(stream)
    if tok.kind == token.TokenKind.symbol and (tok.lexeme == "+" or tok.lexeme == "-"):
        ts.advance(stream)
        if not parse_multiplicative(stream):
            return false
    return true


function parse_multiplicative(stream: ref[ts.TokenStream]) -> bool:
    if not parse_unary(stream):
        return false
    let tok = ts.peek(stream)
    if tok.kind == token.TokenKind.symbol and (tok.lexeme == "*" or tok.lexeme == "/" or tok.lexeme == "%"):
        ts.advance(stream)
        if not parse_unary(stream):
            return false
    return true


# ---- Prefix/Unary ----

function parse_unary(stream: ref[ts.TokenStream]) -> bool:
    if try_parse_prefix_cast(stream):
        return true

    if ts.check_keyword(stream, "unsafe"):
        ts.advance(stream)
        if not ts.match_symbol(stream, ":"):
            log.error(format_error(stream, "expected ':' after unsafe in expression"))
            return false
        return parse_expression(stream)

    if ts.check_keyword(stream, "await"):
        ts.advance(stream)
        return parse_unary(stream)

    if ts.check_keyword(stream, "detach"):
        ts.advance(stream)
        return parse_unary(stream)

    let tok = ts.peek(stream)
    if tok.kind == token.TokenKind.symbol:
        if tok.lexeme == "-" or tok.lexeme == "+" or tok.lexeme == "~":
            ts.advance(stream)
            return parse_unary(stream)

    return parse_postfix(stream)


function try_parse_prefix_cast(stream: ref[ts.TokenStream]) -> bool:
    let saved = ts.save_position(stream)
    let tok = ts.peek(stream)

    if tok.kind != token.TokenKind.identifier and tok.kind != token.TokenKind.keyword:
        return false

    if not type_parsing.parse_type_ref(stream):
        ts.restore_position(stream, saved)
        return false

    if not ts.check_symbol(stream, "<"):
        ts.restore_position(stream, saved)
        return false

    let next_tok = ts.peek_next(stream, 1)
    if next_tok.kind != token.TokenKind.symbol or next_tok.lexeme != "-":
        ts.restore_position(stream, saved)
        return false

    ts.advance(stream)
    ts.advance(stream)

    return parse_unary(stream)


# ---- Postfix ----

function parse_postfix(stream: ref[ts.TokenStream]) -> bool:
    if not parse_primary(stream):
        return false

    while not ts.eof(stream):
        let tok = ts.peek(stream)

        if tok.kind == token.TokenKind.symbol:
            if tok.lexeme == ".":
                ts.advance(stream)
                let k = ts.peek_kind(stream)
                if k == token.TokenKind.identifier or k == token.TokenKind.keyword:
                    ts.advance(stream)
            else if tok.lexeme == "(":
                ts.advance(stream)
                parse_group_content(stream, "(", ")")
            else if tok.lexeme == "[":
                ts.advance(stream)
                parse_group_content(stream, "[", "]")
            else if tok.lexeme == "?":
                ts.advance(stream)
            else:
                break
        else:
            break

    return true


function parse_group_content(stream: ref[ts.TokenStream], open_sym: str, close_sym: str) -> void:
    var depth: ptr_uint = 1
    while not ts.eof(stream) and depth > 0:
        let tok = ts.peek(stream)
        if tok.kind == token.TokenKind.symbol:
            if tok.lexeme == open_sym or tok.lexeme == "[" or tok.lexeme == "(":
                depth += 1
            else if tok.lexeme == close_sym or tok.lexeme == "]" or tok.lexeme == ")":
                depth -= 1
                if depth == 0:
                    ts.advance(stream)
                    return

        ts.advance(stream)


# ---- Primary expressions ----

function parse_primary(stream: ref[ts.TokenStream]) -> bool:
    if ts.check_keyword(stream, "proc"):
        ts.advance(stream)
        return parse_proc_expr(stream)

    if ts.check_keyword(stream, "if"):
        return parse_if_expr(stream)

    if ts.check_keyword(stream, "match"):
        return parse_match_expr(stream)

    if ts.check_keyword(stream, "unsafe"):
        ts.advance(stream)
        if not ts.match_symbol(stream, ":"):
            log.error(format_error(stream, "expected ':' after unsafe in expression"))
            return false
        return parse_expression(stream)

    if ts.check_keyword(stream, "size_of"):
        return parse_builtin_call(stream)
    if ts.check_keyword(stream, "align_of"):
        return parse_builtin_call(stream)
    if ts.check_keyword(stream, "offset_of"):
        ts.advance(stream)
        ts.match_symbol(stream, "(")
        let _ = type_parsing.parse_type_ref(stream)
        ts.match_symbol(stream, ",")
        if ts.peek_kind(stream) == token.TokenKind.identifier:
            ts.advance(stream)
        ts.match_symbol(stream, ")")
        return true

    if ts.check_keyword(stream, "true") or ts.check_keyword(stream, "false"):
        ts.advance(stream)
        return true

    if ts.check_keyword(stream, "null"):
        ts.advance(stream)
        if ts.match_symbol(stream, "["):
            let _ = type_parsing.parse_type_ref(stream)
            let _ = ts.match_symbol(stream, "]")
        return true

    let tok = ts.peek(stream)

    if tok.kind == token.TokenKind.symbol and tok.lexeme == "(":
        ts.advance(stream)

        if ts.check_symbol(stream, ")"):
            ts.advance(stream)
            return true

        let _ = parse_expression(stream)

        while ts.match_symbol(stream, ","):
            if ts.check_symbol(stream, ")"):
                break
            let _ = parse_expression(stream)

        let _ = ts.match_symbol(stream, ")")
        return true

    if (
        tok.kind == token.TokenKind.integer_literal
        or tok.kind == token.TokenKind.float_literal
        or tok.kind == token.TokenKind.char_literal
        or tok.kind == token.TokenKind.string_literal
        or tok.kind == token.TokenKind.cstring_literal
        or tok.kind == token.TokenKind.fstring_literal
    ):
        ts.advance(stream)
        return true

    if tok.kind == token.TokenKind.identifier:
        ts.advance(stream)
        return true

    if tok.kind == token.TokenKind.keyword:
        ts.advance(stream)
        return true

    log.error(format_error(stream, "expected expression"))
    return false


function parse_builtin_call(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)
    if not ts.match_symbol(stream, "("):
        return false
    let _ = type_parsing.parse_type_ref(stream)
    let _ = ts.match_symbol(stream, ")")
    return true


# ---- Proc expression ----

function parse_proc_expr(stream: ref[ts.TokenStream]) -> bool:
    if not ts.match_symbol(stream, "("):
        return false

    parse_group_content(stream, "(", ")")

    if ts.check_symbol(stream, "->"):
        ts.advance(stream)
        let _ = type_parsing.parse_type_ref(stream)

    if not ts.match_symbol(stream, ":"):
        return false

    return parse_body_or_expr(stream)


# ---- If expression ----

function parse_if_expr(stream: ref[ts.TokenStream]) -> bool:
    let _ = parse_expression(stream)

    if not ts.match_symbol(stream, ":"):
        log.error(format_error(stream, "expected ':' after condition in if expression"))
        return false

    let _ = parse_expression(stream)

    if ts.check_keyword(stream, "else"):
        ts.advance(stream)
        if not ts.match_symbol(stream, ":"):
            log.error(format_error(stream, "expected ':' after 'else' in if expression"))
            return false
        return parse_expression(stream)

    return true


# ---- Match expression ----

function parse_match_expr(stream: ref[ts.TokenStream]) -> bool:
    let _ = parse_expression(stream)

    if not ts.match_symbol(stream, ":"):
        return false
    if not ts.match_kind(stream, token.TokenKind.newline):
        return false
    if not ts.match_kind(stream, token.TokenKind.indent):
        return false

    skip_to_dedent(stream)
    return true


# ---- Block body / expression disambiguation ----

function parse_body_or_expr(stream: ref[ts.TokenStream]) -> bool:
    if ts.check_kind(stream, token.TokenKind.newline):
        ts.advance(stream)
        if ts.check_kind(stream, token.TokenKind.indent):
            ts.advance(stream)
            skip_to_dedent(stream)
            return true
        return parse_expression(stream)

    return parse_expression(stream)


# ---- Dedent tracking ----

function skip_to_dedent(stream: ref[ts.TokenStream]) -> void:
    var depth: ptr_uint = 1
    while not ts.eof(stream) and depth > 0:
        let kind = ts.peek_kind(stream)
        if kind == token.TokenKind.indent:
            depth += 1
        else if kind == token.TokenKind.dedent:
            depth -= 1
            if depth == 0:
                ts.advance(stream)
                return
        else if kind == token.TokenKind.eof:
            return

        ts.advance(stream)


# ---- Utility ----

function parse_comma_separated_until(stream: ref[ts.TokenStream], end_sym: str) -> void:
    while not ts.check_symbol(stream, end_sym) and not ts.eof(stream):
        let _ = parse_expression(stream)
        if not ts.match_symbol(stream, ","):
            break
