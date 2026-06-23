import compiler.codegen.c_backend as cg
import compiler.context as ctx_mod
import compiler.lexer.lexer as lexer_mod
import compiler.lowering.lowerer as lowerer_mod
import compiler.parser.parser as parser_mod
import compiler.sema.checker as checker_mod
import compiler.source as source_mod

external function printf(format: cstr, ...) -> int

function main() -> int:
    let source_str = "struct Counter:\n    value: int\n\nfunction main() -> int:\n    var c: Counter = Counter(value = 42)\n    return c.value\n"
    let source = source_mod.from_str(source_str, "<input>")
    var ctx = ctx_mod.create(source)

    let source_span = unsafe: span[ubyte](data = ptr[ubyte]<-source_str.data, len = source_str.len)

    var tokens = lexer_mod.lex(source_span, ref_of(ctx.interner))
    let tokens_span = tokens.as_span()

    let ast = parser_mod.parse(source_span, tokens_span)

    var checker = checker_mod.create(ctx.registry, ref_of(ctx.interner))
    let ok = checker.check(ast)

    if not ok:
        return 1

    let ir = lowerer_mod.lower(ast, ptr_of(ctx.interner))
    let c_source = cg.write_program(ir)
    printf(c"%s\n", c_source)

    return 0
