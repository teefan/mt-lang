# Milk Tea Compiler CLI entry point.
# Exercises: lexer -> parser -> sema checker -> lowering -> C emission.

import mtc.lexer
import mtc.parser
import mtc.ast
import mtc.sema
import mtc.lowering
import mtc.emit
import std.stdio as io

const SRC: str = <<-MT
function add(a: int, b: int) -> int:
    return a + b

function main() -> int:
    let x = add(1, 2)
    return x
MT

function main() -> int:
    io.print_line("=== mtc selfhost pipeline ===")

    io.print_line("[1] lexing...")
    var lx = lexer.Lexer.from_source(SRC)
    lx.tokenize()
    let tokens = lx.finish()
    io.print_line(f"  tokens: #{tokens.len}")

    io.print_line("[2] parsing...")
    var p = parser.Parser.create(tokens)
    let file = p.parse()
    io.print_line(f"  declarations: #{file.declarations.len}")

    io.print_line("[3] sema check...")
    var checker = sema.Checker.create(file)
    let ctx = checker.check()
    io.print_line(f"  errors: #{ctx.errors.len}")

    io.print_line("[4] lowering...")
    var lowerer = lowering.Lowerer.create(ctx, file, "main")
    let ir = lowerer.lower()
    io.print_line(f"  ir decls: #{ir.declarations.len}")
    io.print_line(f"  ir stmts: #{ir.statements.len}")

    io.print_line("[5] C emission...")
    var emitter = emit.Emitter.create(ir, ctx.arena)
    let c_code = emitter.emit_c()
    io.print_line(f"  C output: #{c_code.len} bytes")
    io.print_line("---")
    io.print_line(c_code)
    io.print_line("---")

    return 0
