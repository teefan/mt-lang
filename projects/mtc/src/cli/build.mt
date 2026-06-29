import std.stdio as stdio

import context.source_manager
import lexer
import parser
import lower
import lower.cir
import codegen.emit

import cli.options
import cli.io

public function run_build(opts: ref[options.CliOptions]) -> int:
    var o = opts
    if o.source_path == "":
        stdio.print_format("error: missing source file path\n")
        return 1

    let source = io.read_file(o.source_path)
    if source.len == 0:
        stdio.print_format("error: cannot read file: %s\n", o.source_path)
        return 1

    var mgr = source_manager.SourceManager.create()
    let file_id = mgr.add_file(o.source_path, source, o.source_path)

    var lexer_state = lexer.Lexer.create(mgr.file(file_id).content, uint<-(file_id))
    var tokens = lexer_state.lex()

    var parser_inst = parser.Parser.create(tokens, uint<-(file_id))
    var ast_mod = parser_inst.parse_file()

    var program = cir.CirProgram.create()
    var lowerer = lower.Lowerer.create()
    lowerer.lower_module(ast_mod, ref_of(program))

    var emitter = emit.Emitter.create()
    let c_output = emitter.emit_c(ref_of(program))
    program.release()

    let out_path = o.output_path
    if out_path == "":
        stdio.print_format("%s", c_output)
    else:
        let ok_write = io.write_file(out_path, c_output)
        let _okw = ok_write

    return 0
