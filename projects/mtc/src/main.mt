## Self-hosted Milk Tea compiler — CLI entry point.
##
## Stage 1: Lexer — reads source, outputs token JSON consumable by
## Ruby mtc's `parse --from-tokens-json`.

import std.stdio as stdio
import std.string as string_mod
import std.mem.heap as heap
import std.str as str_util

import lexer.lexer as lexer_mod
import parser.parser as parser_mod
import test.all_tests as test_runner

function read_whole_file(path: str) -> string_mod.String:
    let file = stdio.file_open(path, "rb") else:
        fatal(c"cannot open input file")

    defer stdio.file_close(file)

    stdio.file_seek(file, 0, stdio.SEEK_END)
    let file_size = stdio.file_get_pos(file)
    stdio.file_rewind(file)

    let byte_count = ptr_uint<-file_size
    if byte_count == 0:
        return string_mod.String.create()

    let data = heap.must_alloc[char](byte_count)
    let bytes_read = stdio.file_read_bytes(unsafe: ptr[void]<-data, 1, byte_count, file)
    if bytes_read != byte_count:
        heap.release(data)
        fatal(c"failed to read entire file")

    var content = string_mod.String.with_capacity(byte_count)
    unsafe:
        content.append(str(data = data, len = byte_count))
    heap.release(data)
    return content

function lex_cmd(file_path: str) -> int:
    var source = read_whole_file(file_path)
    let source_str = source.as_str()

    var json = lexer_mod.lex_to_json(source_str)
    stdio.print_line(json.as_str())

    json.release()
    source.release()
    return 0

function parse_cmd(file_path: str) -> int:
    var source = read_whole_file(file_path)
    let source_str = source.as_str()

    var json = parser_mod.parse_to_ast_json(source_str, file_path)
    stdio.print_line(json.as_str())

    json.release()
    source.release()
    return 0

function print_usage() -> void:
    stdio.print_line(c"usage: mtc <subcommand> [args]")
    stdio.print_line(c"")
    stdio.print_line(c"subcommands:")
    stdio.print_line(c"  lex <file>    tokenize source, print token JSON to stdout")
    stdio.print_line(c"  parse <file>  parse source, print AST JSON to stdout")
    stdio.print_line(c"  test          run lexer regression tests")

function test_cmd() -> int:
    return test_runner.run_all()

function main(args: span[str]) -> int:
    if args.len < 1:
        print_usage()
        return 1

    let cmd = args[0]

    if cmd == "lex":
        if args.len < 2:
            print_usage()
            return 1
        return lex_cmd(args[1])

    if cmd == "parse":
        if args.len < 2:
            print_usage()
            return 1
        return parse_cmd(args[1])

    if cmd == "test":
        return test_cmd()

    if cmd == "--help" or cmd == "-h":
        print_usage()
        return 0

    print_usage()
    return 1
