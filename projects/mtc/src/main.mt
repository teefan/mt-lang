# Milk Tea Compiler CLI entry point.

import std.stdio as io
import mtc.lexer

function main() -> int:
    io.print_line("Milk Tea self-hosted compiler (mtc)")
    var lexer_val = lexer.Lexer.from_source("if true:\n    pass\n")
    lexer_val.tokenize()
    let tokens = lexer_val.finish()
    io.print_line(f"Produced #{tokens.len} tokens")
    return 0
