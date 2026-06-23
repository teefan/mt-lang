import compiler.codegen.c_backend as cg
import compiler.context as ctx_mod
import compiler.lexer.lexer as lexer_mod
import compiler.lowering.lowerer as lowerer_mod
import compiler.parser.parser as parser_mod
import compiler.sema.checker as checker_mod
import compiler.source as source_mod
import std.fs
import std.str
import std.stdio


function build_file(path: str) -> int:
    let file_result = fs.read_bytes(path)
    let file_bytes_obj = file_result else:
        stdio.print_line("error: cannot read file")
        return 1
    let file_bytes = file_bytes_obj.as_span()

    if file_bytes.len == ptr_uint<-0:
        stdio.print_line("error: empty file")
        return 1

    let source = source_mod.from_str("", "<input>")
    var ctx = ctx_mod.create(source)

    var tokens = lexer_mod.lex(file_bytes, ref_of(ctx.interner))
    let tokens_span = tokens.as_span()

    let ast = parser_mod.parse(file_bytes, tokens_span, ptr_of(ctx.interner))

    var checker = checker_mod.create(ctx.registry, ref_of(ctx.interner))
    let ok = checker.check(ast)
    if not ok:
        return 1

    let ir = lowerer_mod.lower(ast, ptr_of(ctx.interner), ctx.registry)
    let c_source = cg.write_program(ir, ctx.registry)
    stdio.print_line(c_source)
    return 0


function main(args: span[str]) -> int:
    ## args[0] = subcommand, args[1] = file path (program name stripped)
    if args.len < ptr_uint<-2:
        stdio.print_line("usage: mtc <build|check|lex|parse> <file.mt>")
        return 1

    unsafe:
        let cmd = read(args.data + 0)
        let path = read(args.data + 1)

        if cmd.equal("check"):
            let file_result = fs.read_bytes(path)
            let fb = file_result else:
                stdio.print_line("error: cannot read file")
                return 1
            let fbytes = fb.as_span()
            if fbytes.len == ptr_uint<-0:
                stdio.print_line("error: empty file")
                return 1

            let source = source_mod.from_str("", "<input>")
            var ctx = ctx_mod.create(source)
            var toks = lexer_mod.lex(fbytes, ref_of(ctx.interner))
            let toks_span = toks.as_span()
            let ast = parser_mod.parse(fbytes, toks_span, ptr_of(ctx.interner))
            var chk = checker_mod.create(ctx.registry, ref_of(ctx.interner))
            let ok = chk.check(ast)
            if ok:
                stdio.print_line("check ok")
                return 0
            stdio.print_line("check failed")
            return 1

        return build_file(path)
