import parser.token_stream as ts
import lexer.token as token
import parser.expression as expr_parser
import parser.type_parsing as type_parsing
import std.log as log

# ---- Main dispatch ----

public function parse_statement(stream: ref[ts.TokenStream]) -> bool:
    if ts.check_keyword(stream, "let"):
        return parse_local_decl(stream)
    if ts.check_keyword(stream, "var"):
        return parse_local_decl(stream)

    if ts.check_keyword(stream, "if"):
        return parse_if_stmt(stream)
    if ts.check_keyword(stream, "match"):
        return parse_match_stmt(stream)
    if ts.check_keyword(stream, "unsafe"):
        return parse_unsafe_stmt(stream)
    if ts.check_keyword(stream, "static_assert"):
        return parse_static_assert_stmt(stream)
    if ts.check_keyword(stream, "emit"):
        return parse_emit_stmt(stream)

    if ts.check_keyword(stream, "for"):
        return parse_for_stmt(stream)
    if check_parallel_start(stream):
        return parse_parallel_stmt(stream)
    if ts.check_keyword(stream, "gather"):
        return parse_gather_stmt(stream)

    if ts.check_keyword(stream, "while"):
        return parse_while_stmt(stream)
    if ts.check_keyword(stream, "pass"):
        return parse_pass_stmt(stream)
    if ts.check_keyword(stream, "break"):
        return parse_break_stmt(stream)
    if ts.check_keyword(stream, "continue"):
        return parse_continue_stmt(stream)
    if ts.check_keyword(stream, "return"):
        return parse_return_stmt(stream)
    if ts.check_keyword(stream, "defer"):
        return parse_defer_stmt(stream)

    if check_inline_start(stream):
        ts.advance(stream)
        return parse_inline_stmt(stream)
    if ts.check_keyword(stream, "when"):
        ts.advance(stream)
        return parse_when_stmt(stream)

    return parse_assign_or_expr(stream)


# ---- Helpers ----

function check_parallel_start(stream: ref[ts.TokenStream]) -> bool:
    if not ts.check_keyword(stream, "parallel"):
        return false
    let next = ts.peek_next(stream, 1)
    if next.kind == token.TokenKind.keyword and next.lexeme == "for":
        return true
    if next.kind == token.TokenKind.symbol and next.lexeme == ":":
        return true
    return false


function check_inline_start(stream: ref[ts.TokenStream]) -> bool:
    if not ts.check_keyword(stream, "inline"):
        return false
    let next = ts.peek_next(stream, 1)
    if next.kind == token.TokenKind.keyword:
        let lexeme = next.lexeme
        return lexeme == "for" or lexeme == "while" or lexeme == "match" or lexeme == "if"
    return false


function next_is_newline_or_indent(stream: ref[ts.TokenStream], offset: ptr_uint) -> bool:
    let tok = ts.peek_next(stream, offset)
    return tok.kind == token.TokenKind.newline or tok.kind == token.TokenKind.indent


function is_inline_body(stream: ref[ts.TokenStream]) -> bool:
    if not ts.check_symbol(stream, ":"):
        return false
    let next = ts.peek_next(stream, 1)
    return next.kind != token.TokenKind.newline


function parse_block_opt(stream: ref[ts.TokenStream]) -> bool:
    if is_inline_body(stream):
        ts.advance(stream)
        return parse_statement(stream)

    return parse_block(stream)


function parse_block(stream: ref[ts.TokenStream]) -> bool:
    if not ts.match_symbol(stream, ":"):
        log.error(expr_parser.format_error(stream, "expected ':' before block"))
        return false
    if not ts.match_kind(stream, token.TokenKind.newline):
        log.error(expr_parser.format_error(stream, "expected newline before block"))
        return false
    if not ts.match_kind(stream, token.TokenKind.indent):
        log.error(expr_parser.format_error(stream, "expected indented block"))
        return false

    parse_statement_block_body(stream)

    if not ts.match_kind(stream, token.TokenKind.dedent):
        log.error(expr_parser.format_error(stream, "expected dedent at end of block"))
        return false

    return true


function parse_statement_block_body(stream: ref[ts.TokenStream]) -> void:
    while not ts.eof(stream):
        let kind = ts.peek_kind(stream)
        if kind == token.TokenKind.dedent or kind == token.TokenKind.eof:
            return

        let _ = parse_statement(stream)

        ts.skip_newlines(stream)


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


# ---- Local declaration (let / var) ----

function parse_local_decl(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)

    if ts.check_symbol(stream, "("):
        return parse_destructure_decl(stream)

    if ts.peek_kind(stream) == token.TokenKind.identifier:
        ts.advance(stream)
    else if ts.peek_kind(stream) == token.TokenKind.keyword:
        ts.advance(stream)
    else:
        return false

    if ts.match_symbol(stream, ":"):
        let _ = type_parsing.parse_type_ref(stream)

    if ts.match_symbol(stream, "="):
        let _ = expr_parser.parse_expression(stream)

    if ts.check_keyword(stream, "else"):
        ts.advance(stream)
        if ts.check_keyword(stream, "as"):
            ts.advance(stream)
            if ts.peek_kind(stream) == token.TokenKind.identifier:
                ts.advance(stream)
        return parse_block(stream)

    if not is_inline_body(stream):
        if not ts.check_kind(stream, token.TokenKind.newline) and not ts.check_kind(stream, token.TokenKind.dedent) and not ts.eof(stream):
            let _ = expr_parser.parse_expression(stream)

    ts.skip_newlines(stream)

    return true


function parse_destructure_decl(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)

    while not ts.check_symbol(stream, ")") and not ts.eof(stream):
        if ts.peek_kind(stream) == token.TokenKind.identifier:
            ts.advance(stream)
        if ts.match_symbol(stream, ","):
            continue
        break

    ts.match_symbol(stream, ")")

    if ts.match_symbol(stream, ":"):
        let _ = type_parsing.parse_type_ref(stream)

    if ts.match_symbol(stream, "="):
        let _ = expr_parser.parse_expression(stream)

    ts.skip_newlines(stream)

    return true


# ---- If statement ----

function parse_if_stmt(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)

    let _ = expr_parser.parse_expression(stream)

    if not parse_block_opt(stream):
        return false

    while ts.check_keyword(stream, "else") and ts.peek_next(stream, 1).kind == token.TokenKind.keyword and ts.peek_next(stream, 1).lexeme == "if":
        ts.advance(stream)
        ts.advance(stream)
        let _ = expr_parser.parse_expression(stream)
        if not parse_block_opt(stream):
            return false

    if ts.check_keyword(stream, "else"):
        ts.advance(stream)
        return parse_block_opt(stream)

    return true


# ---- Match statement ----

function parse_match_stmt(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)
    let _ = expr_parser.parse_expression(stream)
    return parse_match_arms(stream)


function parse_match_arms(stream: ref[ts.TokenStream]) -> bool:
    if not ts.match_symbol(stream, ":"):
        return false
    if not ts.match_kind(stream, token.TokenKind.newline):
        return false
    if not ts.match_kind(stream, token.TokenKind.indent):
        return false

    var depth: ptr_uint = 1
    while not ts.eof(stream) and depth > 0:
        let kind = ts.peek_kind(stream)
        if kind == token.TokenKind.indent:
            depth += 1
        else if kind == token.TokenKind.dedent:
            depth -= 1
            if depth == 0:
                ts.advance(stream)
                return true
        else if kind == token.TokenKind.eof:
            return false

        ts.advance(stream)

    return true


# ---- Unsafe statement ----

function parse_unsafe_stmt(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)
    if not ts.match_symbol(stream, ":"):
        return false

    if ts.check_kind(stream, token.TokenKind.newline):
        ts.advance(stream)
        if ts.match_kind(stream, token.TokenKind.indent):
            parse_statement_block_body(stream)
            ts.match_kind(stream, token.TokenKind.dedent)
            return true

    return parse_statement(stream)


# ---- Loop statements ----

function parse_for_stmt(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)
    parse_for_bindings(stream)
    if not ts.check_keyword(stream, "in"):
        return false
    ts.advance(stream)
    parse_for_iterables(stream)
    return parse_block(stream)


function parse_for_bindings(stream: ref[ts.TokenStream]) -> void:
    while true:
        let kind = ts.peek_kind(stream)
        if kind == token.TokenKind.identifier or kind == token.TokenKind.keyword:
            ts.advance(stream)
        if not ts.match_symbol(stream, ","):
            break


function parse_for_iterables(stream: ref[ts.TokenStream]) -> void:
    var first = true
    while first or ts.match_symbol(stream, ","):
        first = false
        let _ = expr_parser.parse_expression(stream)


function parse_parallel_stmt(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)
    let next = ts.peek(stream)

    if next.kind == token.TokenKind.keyword and next.lexeme == "for":
        ts.advance(stream)
        parse_for_bindings(stream)
        if ts.check_keyword(stream, "in"):
            ts.advance(stream)
        parse_for_iterables(stream)
        return parse_block(stream)

    if not ts.match_symbol(stream, ":"):
        return false
    if not ts.match_kind(stream, token.TokenKind.newline):
        return false
    if not ts.match_kind(stream, token.TokenKind.indent):
        return false

    parse_statement_block_body(stream)
    ts.match_kind(stream, token.TokenKind.dedent)
    return true


function parse_gather_stmt(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)
    let _ = expr_parser.parse_expression(stream)
    while ts.match_symbol(stream, ","):
        let _ = expr_parser.parse_expression(stream)
    skip_to_newline(stream)
    return true


function parse_while_stmt(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)
    let _ = expr_parser.parse_expression(stream)
    return parse_block(stream)


# ---- Simple statements ----

function parse_pass_stmt(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)
    skip_to_newline(stream)
    return true


function parse_break_stmt(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)
    skip_to_newline(stream)
    return true


function parse_continue_stmt(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)
    skip_to_newline(stream)
    return true


function parse_return_stmt(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)
    if ts.check_kind(stream, token.TokenKind.newline) or ts.check_kind(stream, token.TokenKind.dedent) or ts.eof(stream):
        skip_to_newline(stream)
        return true
    let _ = expr_parser.parse_expression(stream)
    skip_to_newline(stream)
    return true


function parse_defer_stmt(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)

    if ts.check_symbol(stream, ":"):
        return parse_block(stream)

    let _ = expr_parser.parse_expression(stream)
    skip_to_newline(stream)
    return true


# ---- Static assert / emit ----

function parse_static_assert_stmt(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)
    if not ts.match_symbol(stream, "("):
        return false
    let _ = expr_parser.parse_expression(stream)
    ts.match_symbol(stream, ",")
    let _ = expr_parser.parse_expression(stream)
    ts.match_symbol(stream, ")")
    skip_to_newline(stream)
    return true


function parse_emit_stmt(stream: ref[ts.TokenStream]) -> bool:
    ts.advance(stream)
    skip_to_newline(stream)
    return true


# ---- Assignment / expression ----

function parse_assign_or_expr(stream: ref[ts.TokenStream]) -> bool:
    let _ = expr_parser.parse_expression(stream)

    if ts.check_symbol(stream, "=") or ts.check_symbol(stream, "+=") or ts.check_symbol(stream, "-="):
        let tok = ts.peek(stream)
        if is_assign_op(tok):
            ts.advance(stream)
            let _ = expr_parser.parse_expression(stream)

    if is_inline_body(stream):
        return false

    skip_to_newline(stream)
    return true


function is_assign_op(tok: token.Token) -> bool:
    if tok.kind != token.TokenKind.symbol:
        return false
    return (
        tok.lexeme == "="
        or tok.lexeme == "+=" or tok.lexeme == "-=" or tok.lexeme == "*=" or tok.lexeme == "/="
        or tok.lexeme == "%=" or tok.lexeme == "&=" or tok.lexeme == "|=" or tok.lexeme == "^="
        or tok.lexeme == "<<=" or tok.lexeme == ">>="
    )


# ---- Inline statements ----

function parse_inline_stmt(stream: ref[ts.TokenStream]) -> bool:
    let next = ts.peek(stream)

    if next.kind == token.TokenKind.keyword:
        if next.lexeme == "for":
            ts.advance(stream)
            parse_for_bindings(stream)
            ts.advance(stream)
            parse_for_iterables(stream)
            return parse_block(stream)
        else if next.lexeme == "while":
            ts.advance(stream)
            let _ = expr_parser.parse_expression(stream)
            return parse_block(stream)
        else if next.lexeme == "match":
            ts.advance(stream)
            let _ = expr_parser.parse_expression(stream)
            return parse_match_arms(stream)
        else if next.lexeme == "if":
            ts.advance(stream)
            return parse_if_stmt(stream)

    return false


# ---- When ----

function parse_when_stmt(stream: ref[ts.TokenStream]) -> bool:
    let _ = expr_parser.parse_expression(stream)
    return parse_match_arms(stream)


# ---- Newline skip ----

function skip_to_newline(stream: ref[ts.TokenStream]) -> void:
    ts.skip_newlines(stream)
    if ts.check_kind(stream, token.TokenKind.newline):
        ts.advance(stream)
