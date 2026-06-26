## Token stream — cursor-based token navigation for the parser.

import std.vec as vec_mod
import std.string as string_mod

import lexer.lexer as lexer_mod

public struct TokenStream:
    tokens: vec_mod.Vec[lexer_mod.Token]
    pos: ptr_uint

extending TokenStream:
    public function peek() -> ptr[lexer_mod.Token]?:
        if this.pos >= this.tokens.len:
            return null

        return this.tokens.get(this.pos)

    public function peek_kind() -> str:
        let tok = this.peek() else:
            return "eof"

        return unsafe: read(tok).kind

    public function is_eof() -> bool:
        if this.pos >= this.tokens.len:
            return true

        let tok_opt = this.tokens.get(this.pos) else:
            return true

        let tok = unsafe: read(tok_opt)
        return tok.kind == "eof"

    public editable function advance() -> void:
        if not this.is_eof():
            this.pos += 1

    public editable function check(kind: str) -> bool:
        return this.peek_kind() == kind

    public editable function skip_newlines() -> void:
        while this.check("newline"):
            this.advance()

    public editable function match_kind(kind: str) -> bool:
        if this.check(kind):
            this.advance()
            return true

        return false

    public editable function consume(kind: str, message: str) -> bool:
        if this.check(kind):
            this.advance()
            return true

        var msg = string_mod.String.create()
        msg.append(message)
        msg.append(": expected ")
        msg.append(kind)
        msg.append(" but got ")
        msg.append(this.peek_kind())
        fatal(msg.as_str())

    public static function from_source(source: str) -> TokenStream:
        var tokens = lexer_mod.lex_to_tokens(source)
        return TokenStream(tokens = tokens, pos = 0)
