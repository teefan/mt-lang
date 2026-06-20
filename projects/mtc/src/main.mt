# Milk Tea Compiler CLI entry point.
# Exercises the lexer → parser pipeline on embedded source snippets.

import mtc.lexer
import mtc.token_stream
import mtc.parser
import std.stdio as io

const SRC: str = "import std.vec\n\npublic variant Kind:\n    a\n    b\n\npublic struct Pair:\n    first: int\n    second: int\n\nfunction main() -> int:\n    let x = 1\n    return 0\n"

function main() -> int:
    io.print_line("mtc pipeline test")
    io.print_line("lexing...")
    var lx = lexer.Lexer.from_source(SRC)
    lx.tokenize()
    let tokens = lx.finish()
    io.print_line(f"  #{tokens.len} tokens")
    io.print_line("parsing...")
    var p = parser.Parser.create(tokens)
    let f = p.parse()
    io.print_line(f"  #{f.imports.len} imports, #{f.declarations.len} declarations")
    return 0
