import std.vec as vec

import lexer
import lexer.token as tok
import lexer.token_stream as ts

enum BlockState: ubyte
    new_stmt = 1
    after_newline = 2
    in_stmt = 3

public struct BlockParser:
    stream: ts.TokenStream
    state: BlockState
    indent_depth: ptr_uint

extending BlockParser:
    public static function create(tokens: vec.Vec[tok.Token]) -> BlockParser:
        return BlockParser(
            stream = ts.TokenStream.create(tokens),
            state = BlockState.new_stmt,
            indent_depth = 0
        )

    public function current_token() -> tok.Token:
        return this.stream.peek()

    public editable function advance() -> tok.Token:
        return this.stream.advance()

    public function at_new_stmt() -> bool:
        return this.state == BlockState.new_stmt

    public editable function skip_newlines() -> void:
        while this.stream.check(tok.TokenKind.newline):
            let _ = this.stream.advance()
            this.state = BlockState.new_stmt
        if this.stream.check(tok.TokenKind.dedent) or this.stream.check(tok.TokenKind.eof):
            this.state = BlockState.new_stmt
        else:
            this.state = BlockState.in_stmt

    public editable function expect_newline() -> void:
        if this.stream.check(tok.TokenKind.newline):
            let _ = this.stream.advance()
            this.state = BlockState.new_stmt
        else if this.stream.check(tok.TokenKind.dedent) or this.stream.check(tok.TokenKind.eof):
            this.state = BlockState.new_stmt
        else:
            fatal(c"expected newline or dedent")
            return

    public editable function enter_block() -> void:
        if not this.stream.check(tok.TokenKind.indent):
            fatal(c"expected indent to start block")
            return
        let _ = this.stream.advance()
        this.state = BlockState.new_stmt
        this.indent_depth += 1

    public editable function exit_block() -> void:
        if this.indent_depth == 0:
            return
        if this.stream.check(tok.TokenKind.dedent):
            let _ = this.stream.advance()
            this.indent_depth -= 1
            this.state = BlockState.new_stmt

    public editable function exit_all_blocks() -> void:
        while this.indent_depth > 0:
            if this.stream.check(tok.TokenKind.dedent):
                let _ = this.stream.advance()
                this.indent_depth -= 1
            else:
                return
        this.state = BlockState.new_stmt

    public function is_eof() -> bool:
        return this.stream.peek().kind == tok.TokenKind.eof
