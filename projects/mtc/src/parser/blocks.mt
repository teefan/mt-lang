import parser.token_stream as ts
import lexer.token as token
import std.log as log

public function parse_block(stream: ref[ts.TokenStream]) -> bool:
    if not ts.match_symbol(stream, ":"):
        log.error("expected ':' before block")
        return false

    if not ts.match_kind(stream, token.TokenKind.newline):
        log.error("expected newline before block")
        return false

    if not ts.match_kind(stream, token.TokenKind.indent):
        log.error("expected indented block")
        return false

    return true


public function skip_to_dedent(stream: ref[ts.TokenStream]) -> void:
    var depth: ptr_uint = 1
    while not ts.eof(stream) and depth > 0:
        let kind = ts.peek_kind(stream)
        if kind == token.TokenKind.indent:
            depth += 1
        else if kind == token.TokenKind.dedent:
            depth -= 1
        else if kind == token.TokenKind.eof:
            return

        ts.advance(stream)


public function skip_current_block_body(stream: ref[ts.TokenStream]) -> void:
    if not ts.check_kind(stream, token.TokenKind.indent):
        return

    skip_to_dedent(stream)
