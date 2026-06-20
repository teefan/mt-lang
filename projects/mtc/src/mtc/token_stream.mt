# Token stream wrapper for the parser.
# Mirrors lib/milk_tea/core/token_stream.rb.

import std.vec
import mtc.token

public struct SyntaxTokenStream:
    tokens: vec.Vec[token.Token]

extending SyntaxTokenStream:
    public static function from_tokens(tokens: vec.Vec[token.Token]) -> SyntaxTokenStream:
        return SyntaxTokenStream(tokens = tokens)

    public function len() -> ptr_uint:
        return this.tokens.len

    public function get(index: ptr_uint) -> ptr[token.Token]?:
        return this.tokens.get(index)
