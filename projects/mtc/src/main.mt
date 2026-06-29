import std.stdio as stdio

import context.diagnostic
import context.source_manager
import lexer
import lexer.token

function main() -> int:
    var mgr = source_manager.SourceManager.create()
    defer mgr.release()

    var diag = diagnostic.DiagEngine.create()
    defer diag.release()

    let file_id = mgr.add_file("test.mt", "function main() -> int:\n    return 0\n", "test")

    var lexer_state = lexer.Lexer.create(mgr.file(file_id).content, uint<-(file_id))
    var tokens = lexer_state.lex()

    if tokens.len() > 0:
        stdio.print_format("lexed %d tokens\n", tokens.len())
        let first = tokens.get(0) else:
            fatal(c"missing first token")
        unsafe:
            let tk = read(first)
            if tk.kind != token.TokenKind.keyword:
                stdio.print_format("expected keyword token\n")
                return 1

    tokens.release()
    var _lexer = lexer_state
    return 0
