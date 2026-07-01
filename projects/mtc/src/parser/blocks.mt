import parser.token_stream as ts
import lexer.token as token

public function parse_block(stream: ref[ts.TokenStream]) -> bool:
    if not ts.match_symbol(stream, ":"):
        return false
    if not ts.match_kind(stream, token.TokenKind.newline):
        return false
    if not ts.match_kind(stream, token.TokenKind.indent):
        return false

    return true


public function consume_dedent(stream: ref[ts.TokenStream]) -> bool:
    return ts.match_kind(stream, token.TokenKind.dedent)


public function skip_to_dedent(stream: ref[ts.TokenStream]) -> void:
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


public function parse_group_content(stream: ref[ts.TokenStream], open: str, close: str) -> void:
    var depth: ptr_uint = 1
    while not ts.eof(stream) and depth > 0:
        let tok = ts.peek(stream)
        if tok.kind == token.TokenKind.symbol:
            if tok.lexeme == open or tok.lexeme == "[" or tok.lexeme == "(":
                depth += 1
            else if tok.lexeme == close or tok.lexeme == "]" or tok.lexeme == ")":
                depth -= 1
                if depth == 0:
                    ts.advance(stream)
                    return

        ts.advance(stream)


public function synchronize_to_next_decl(stream: ref[ts.TokenStream]) -> void:
    var indent_depth: ptr_uint = 0
    while not ts.eof(stream):
        let tok = ts.peek(stream)
        if tok.kind == token.TokenKind.indent:
            indent_depth += 1
        else if tok.kind == token.TokenKind.dedent:
            if indent_depth == 0:
                ts.advance(stream)
                break
            indent_depth -= 1
        else if tok.kind == token.TokenKind.newline and indent_depth == 0:
            ts.advance(stream)
            ts.skip_newlines(stream)
            let next = ts.peek(stream)
            if next.kind == token.TokenKind.keyword:
                break
        else:
            ts.advance(stream)
