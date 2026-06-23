## TokenCursor — safe peek/consume over a span[Token].
##
## Wraps the token Vec output from the lexer. Provides current(),
## peek(), and advance() so the parser never touches raw pointers.

import compiler.lexer.token as token_mod

public struct Cursor:
    tokens: span[token_mod.Token]
    pos: ptr_uint


public function create(tokens: span[token_mod.Token]) -> Cursor:
    return Cursor(tokens = tokens, pos = 0)


extending Cursor:
    public function at_end() -> bool:
        return this.pos >= this.tokens.len


    public function current() -> token_mod.Token:
        let raw = this.tokens.data
        unsafe:
            return read(raw + this.pos)


    public function peek(offset: ptr_uint) -> Option[token_mod.Token]:
        let target = this.pos + offset
        if target >= this.tokens.len:
            return Option[token_mod.Token].none

        let raw = this.tokens.data
        unsafe:
            return Option[token_mod.Token].some(value = read(raw + target))


    public editable function advance() -> void:
        if not this.at_end():
            this.pos += 1


    public function remaining() -> ptr_uint:
        if this.pos >= this.tokens.len:
            return 0
        return this.tokens.len - this.pos
