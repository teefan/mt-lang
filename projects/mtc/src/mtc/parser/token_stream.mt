## Token stream wrapper — provides peek/advance/match/consume operations
## over a lexed token list, matching the Ruby SyntaxTokenStream API.
##
## Public API:
##   create(tokens: Vec[Token]) -> TokenStream
##   peek(s: ref[TokenStream]) -> ptr[Token]?
##   advance(s: ref[TokenStream])
##   previous(s: ref[TokenStream]) -> ptr[Token]?
##   check(s: ref[TokenStream], kind: TokenKind) -> bool
##   match(s: ref[TokenStream], kind: TokenKind) -> bool
##   consume(s: ref[TokenStream], kind: TokenKind, msg: cstr)
##   eof(s: ref[TokenStream]) -> bool
##   skip_newlines(s: ref[TokenStream])
##   token_kind_name(t: Token) -> str

import std.str
import std.vec as vec
import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod


public struct TokenStream:
    tokens: vec.Vec[token_mod.Token]
    current: ptr_uint


public function create(tokens: vec.Vec[token_mod.Token]) -> TokenStream:
    return TokenStream(tokens = tokens, current = 0)


public function peek(s: ref[TokenStream]) -> ptr[token_mod.Token]?:
    return s.tokens.get(s.current)


public function advance(s: ref[TokenStream]) -> void:
    if not eof(s):
        s.current += 1


public function previous(s: ref[TokenStream]) -> ptr[token_mod.Token]?:
    if s.current == 0:
        return null
    return s.tokens.get(s.current - 1)


public function token_count(s: ref[TokenStream]) -> ptr_uint:
    return s.tokens.len()


public function check(s: ref[TokenStream], kind: tk.TokenKind) -> bool:
    if eof(s):
        return false
    let tok = peek(s) else:
        return false
    unsafe:
        return read(tok).kind == kind


public function match_kind(s: ref[TokenStream], kind: tk.TokenKind) -> bool:
    if not check(s, kind):
        return false
    advance(s)
    return true


public function consume(s: ref[TokenStream], kind: tk.TokenKind, msg: cstr) -> void:
    if check(s, kind):
        advance(s)
        return

    let tok = if eof(s): previous(s) else: peek(s)
    let _t = tok
    fatal(msg)


public function eof(s: ref[TokenStream]) -> bool:
    let tok = peek(s) else:
        return true
    unsafe:
        return read(tok).kind == tk.TokenKind.eof


public function skip_newlines(s: ref[TokenStream]) -> void:
    while check(s, tk.TokenKind.newline):
        advance(s)


public function check_next(s: ref[TokenStream], kind: tk.TokenKind) -> bool:
    # Peek at the token after the current one.
    if s.current + 1 >= s.tokens.len():
        return false
    let tok = s.tokens.get(s.current + 1) else:
        return false
    unsafe:
        return read(tok).kind == kind
