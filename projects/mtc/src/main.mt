# Milk Tea Compiler CLI entry point.

import std.stdio as io
import mtc.token
import mtc.lexer

function main() -> int:
    io.print_line("Milk Tea self-hosted compiler (mtc)")
    return 0
