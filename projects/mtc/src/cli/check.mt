import std.stdio as stdio

import context.source_manager
import lexer
import parser
import resolver
import type_check

import cli.options
import cli.io

public function run_check(opts: ref[options.CliOptions]) -> int:
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

    if tokens.len() == 0:
        stdio.print_format("error: no tokens from %s\n", o.source_path)
        return 1

    var parser_inst = parser.Parser.create(tokens, uint<-(file_id))
    var ast_mod = parser_inst.parse_file()

    var resolver_inst = resolver.Resolver.create(uint<-(file_id))
    var resolved = resolver_inst.resolve(ast_mod)

    var checker = type_check.Checker.create()
    let ok = checker.check_module(resolved)
    let _ok = ok

    stdio.print_format("checked %s\n", o.source_path)
    return 0
