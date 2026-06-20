# Milk Tea Compiler CLI entry point.
# Exercises: lexer → parser → sema checker on embedded source.

import mtc.lexer
import mtc.parser
import mtc.ast
import mtc.sema
import std.stdio as io

const SRC: str = <<-MT
import std.vec

public variant Kind:
    a
    b

public struct Pair:
    first: int
    second: int

function main() -> int:
    let x = 1
    return 0
MT

function main() -> int:
    io.print_line("=== mtc selfhost pipeline test ===")

    io.print_line("[1] lexing...")
    var lx = lexer.Lexer.from_source(SRC)
    lx.tokenize()
    let tokens = lx.finish()
    io.print_line(f"  tokens: #{tokens.len}")

    io.print_line("[2] parsing...")
    var p = parser.Parser.create(tokens)
    let file = p.parse()
    io.print_line(f"  imports:      #{file.imports.len}")
    io.print_line(f"  declarations: #{file.declarations.len}")

    io.print_line("[3] sema check...")
    var checker = sema.Checker.create(file)
    let ctx = checker.check()
    io.print_line(f"  type errors: #{ctx.errors.len}")

    io.print_line("[4] type registry:")
    var j: ptr_uint = 0
    while j < file.declarations.len:
        let decl = file.declarations.at(j) else:
            break
        match decl:
            ast.Decl.struct_decl as sd:
                let _ = ctx.types.get(sd.name) else:
                    j += 1
                    continue
                io.print_line(f"  struct #{sd.name} OK (fields: #{sd.fields_len})")
            ast.Decl.variant_decl as vd:
                let _ = ctx.types.get(vd.name) else:
                    j += 1
                    continue
                io.print_line(f"  variant #{vd.name} OK (arms: #{vd.arms_len})")
            ast.Decl.func_def as fd:
                let _ = ctx.functions.get(fd.name) else:
                    j += 1
                    continue
                io.print_line(f"  function #{fd.name} OK (params: #{fd.params_len})")
            _:
                pass
        j += 1

    io.print_line("  done.")
    return 0
