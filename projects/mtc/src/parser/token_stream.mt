import lexer.token as token
import std.str
import std.vec

public struct TokenStream:
    data: ptr[token.Token]?
    count: ptr_uint
    current: ptr_uint
    path: str
    source: str


public function make_stream(tokens: ref[vec.Vec[token.Token]], path: str, source: str) -> TokenStream:
    if tokens.is_empty():
        return TokenStream(data = null, count = 0, current = 0, path = path, source = source)

    let first = tokens.get(0) else:
        return TokenStream(data = null, count = 0, current = 0, path = path, source = source)

    return unsafe: TokenStream(
        data = ptr[token.Token]<-first,
        count = tokens.len(),
        current = 0,
        path = path,
        source = source,
    )


function token_at(ts: ref[TokenStream], index: ptr_uint) -> token.Token:
    let d = ts.data else:
        unsafe:
            return token.Token(
                kind = token.TokenKind.eof,
                lexeme = "",
                line = 0,
                column = 1,
                start_offset = 0,
                end_offset = 0,
            )
    unsafe:
        return read(d + index)


public function peek(ts: ref[TokenStream]) -> token.Token:
    if ts.current >= ts.count:
        unsafe:
            return token.Token(
                kind = token.TokenKind.eof,
                lexeme = "",
                line = ts.count,
                column = 1,
                start_offset = 0,
                end_offset = 0,
            )
    return token_at(ts, ts.current)


public function peek_prev(ts: ref[TokenStream]) -> token.Token:
    if ts.current == 0:
        unsafe:
            return token.Token(
                kind = token.TokenKind.eof,
                lexeme = "",
                line = 0,
                column = 1,
                start_offset = 0,
                end_offset = 0,
            )
    return token_at(ts, ts.current - 1)


public function peek_next(ts: ref[TokenStream], offset: ptr_uint) -> token.Token:
    let target = ts.current + offset
    if target >= ts.count:
        unsafe:
            return token.Token(
                kind = token.TokenKind.eof,
                lexeme = "",
                line = ts.count,
                column = 1,
                start_offset = 0,
                end_offset = 0,
            )
    return token_at(ts, target)


public function peek_kind(ts: ref[TokenStream]) -> token.TokenKind:
    return peek(ts).kind


public function eof(ts: ref[TokenStream]) -> bool:
    if ts.current >= ts.count:
        return true
    let tok = peek(ts)
    return tok.kind == token.TokenKind.eof


public function check_kind(ts: ref[TokenStream], kind: token.TokenKind) -> bool:
    return peek(ts).kind == kind


public function check_keyword(ts: ref[TokenStream], lexeme: str) -> bool:
    let tok = peek(ts)
    return tok.kind == token.TokenKind.keyword and tok.lexeme == lexeme


public function check_symbol(ts: ref[TokenStream], lexeme: str) -> bool:
    let tok = peek(ts)
    return tok.kind == token.TokenKind.symbol and tok.lexeme == lexeme


public function match_kind(ts: ref[TokenStream], kind: token.TokenKind) -> bool:
    if not check_kind(ts, kind):
        return false
    advance(ts)
    return true


public function match_keyword(ts: ref[TokenStream], lexeme: str) -> bool:
    if not check_keyword(ts, lexeme):
        return false
    advance(ts)
    return true


public function match_symbol(ts: ref[TokenStream], lexeme: str) -> bool:
    if not check_symbol(ts, lexeme):
        return false
    advance(ts)
    return true


public function advance(ts: ref[TokenStream]) -> token.Token:
    if ts.current >= ts.count:
        unsafe:
            return token.Token(
                kind = token.TokenKind.eof,
                lexeme = "",
                line = 0,
                column = 1,
                start_offset = 0,
                end_offset = 0,
            )
    ts.current += 1
    if ts.current == 0:
        unsafe:
            return token.Token(
                kind = token.TokenKind.eof,
                lexeme = "",
                line = 0,
                column = 1,
                start_offset = 0,
                end_offset = 0,
            )
    return token_at(ts, ts.current - 1)


public function skip_newlines(ts: ref[TokenStream]) -> void:
    while true:
        let kind = peek(ts).kind
        if kind == token.TokenKind.newline:
            advance(ts)
        else:
            break


public function current_line(ts: ref[TokenStream]) -> ptr_uint:
    return peek(ts).line


public function current_column(ts: ref[TokenStream]) -> ptr_uint:
    return peek(ts).column


public function save_position(ts: ref[TokenStream]) -> ptr_uint:
    return ts.current


public function restore_position(ts: ref[TokenStream], pos: ptr_uint) -> void:
    ts.current = pos


public function source_slice(ts: ref[TokenStream], start_off: ptr_uint, end_off: ptr_uint) -> str:
    if end_off <= start_off or start_off >= ts.source.len:
        return ""
    if end_off > ts.source.len:
        return ts.source.slice(start_off, ts.source.len - start_off)
    return ts.source.slice(start_off, end_off - start_off)
