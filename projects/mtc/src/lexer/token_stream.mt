import std.vec as vec
import lexer.token as tok

public struct TokenStream:
    tokens: vec.Vec[tok.Token]
    current: ptr_uint

extending TokenStream:
    public static function create(tokens: vec.Vec[tok.Token]) -> TokenStream:
        return TokenStream(tokens = tokens, current = 0)

    public function peek() -> tok.Token:
        let entry = this.tokens.get(this.current) else:
            return tok.Token(
                kind = tok.TokenKind.eof,
                file_id = 0,
                offset = 0,
                lexeme = "",
                keyword_subkind = 0
            )
        unsafe:
            return read(entry)

    public editable function advance() -> tok.Token:
        let prev = this.peek()
        this.current += 1
        return prev

    public function check(kind: tok.TokenKind) -> bool:
        return this.peek().kind == kind

    public function check_keyword(kind: tok.KeywordKind) -> bool:
        let tk = this.peek()
        return tk.kind == tok.TokenKind.keyword and tk.keyword_subkind == uint<-(kind)

    public editable function try_match(kind: tok.TokenKind) -> bool:
        if this.check(kind):
            let _ = this.advance()
            return true
        return false

    public editable function try_match_keyword(kind: tok.KeywordKind) -> bool:
        if this.check_keyword(kind):
            let _ = this.advance()
            return true
        return false

    public function is_eof() -> bool:
        return this.peek().kind == tok.TokenKind.eof

    public function previous() -> tok.Token:
        if this.current == 0:
            return tok.Token(
                kind = tok.TokenKind.error,
                file_id = 0,
                offset = 0,
                lexeme = "",
                keyword_subkind = 0
            )
        let entry = this.tokens.get(this.current - 1) else:
            fatal(c"token_stream.previous missing token")
        unsafe:
            return read(entry)
