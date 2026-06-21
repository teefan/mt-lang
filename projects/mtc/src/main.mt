import std.str
import std.stdio
import std.fs as fs
import std.vec as vec

import mtc.lexer.token
import mtc.lexer.lexer


function print_tokens_text(tokens: ref[vec.Vec[token.Token]]) -> void:
    var i: ptr_uint = 0
    while i < tokens.len():
        let t = tokens.get(i) else:
            break
        unsafe:
            let tok = read(t)
            stdio.print_line(f"#{tok.kind} #{tok.lexeme} #{tok.line}:#{tok.column}")
        i += 1


function print_tokens_json(tokens: ref[vec.Vec[token.Token]]) -> void:
    stdio.print_line("[")
    var i: ptr_uint = 0
    var count = tokens.len()
    while i < count:
        let t = tokens.get(i) else:
            break
        unsafe:
            let tok = read(t)
            var comma = if i + 1 < count: "," else: ""
            stdio.print_line(
                f"  {\"kind\":#{tok.kind},\"lexeme\":\"#{tok.lexeme}\",\"line\":#{tok.line},\"column\":#{tok.column}}#{comma}"
            )
        i += 1
    stdio.print_line("]")


function lex_file(file_path: str, use_json: bool) -> int:
    match fs.read_text(file_path):
        Result.failure as err:
            stdio.print_line(f"error: cannot read '#{file_path}': #{err.error.message.as_str()}")
            return 1
        Result.success as ok:
            var source = ok.value
            var lex = lexer.Lexer.create(source.as_str())
            var tokens = lex.lex()

            if use_json:
                print_tokens_json(ref_of(tokens))
            else:
                print_tokens_text(ref_of(tokens))

            source.release()
            tokens.release()
            return 0


function print_usage() -> void:
    stdio.print_line("Milk Tea Compiler (self-hosting)")
    stdio.print_line("")
    stdio.print_line("Usage: mtc <command> [options]")
    stdio.print_line("")
    stdio.print_line("Commands:")
    stdio.print_line("  lex <file>          Lex a source file and print the token stream")
    stdio.print_line("")
    stdio.print_line("Options:")
    stdio.print_line("  --json, -j          Output token stream as JSON (for lex command)")
    stdio.print_line("  --help, -h          Show this help")


function arg_value(args: span[str], prefix: str) -> Option[str]:
    var i: ptr_uint = 0
    while i < args.len:
        let arg = unsafe: read(args.data + i)
        if arg == prefix:
            return Option[str].some(value = arg)
        i += 1
    return Option[str].none


function has_flag(args: span[str], flag: str) -> bool:
    var i: ptr_uint = 0
    while i < args.len:
        let arg = unsafe: read(args.data + i)
        if arg == flag:
            return true
        i += 1
    return false


function positional_after_command(args: span[str]) -> Option[str]:
    var i: ptr_uint = 1
    while i < args.len:
        let arg = unsafe: read(args.data + i)
        if not arg.starts_with("-"):
            return Option[str].some(value = arg)
        i += 1
    return Option[str].none


function main(args: span[str]) -> int:
    if args.len == 0 or has_flag(args, "--help") or has_flag(args, "-h"):
        print_usage()
        return 0

    let cmd = unsafe: read(args.data)

    if cmd == "lex":
        let file_arg = positional_after_command(args)
        match file_arg:
            Option.some as file_path:
                let use_json = has_flag(args, "--json") or has_flag(args, "-j")
                return lex_file(file_path.value, use_json)
            Option.none:
                stdio.print_line("error: no file specified. Usage: mtc lex <file>")
                return 1

    stdio.print_line(f"error: unknown command '#{cmd}'")
    return 1
