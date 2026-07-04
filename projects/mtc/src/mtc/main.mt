## Self-hosted Milk Tea compiler CLI.
##
## Commands:
##   mtc lex <file>       Print the lexer token stream
##   mtc help             Print help

import std.fs as fs
import std.vec as vec
import std.stdio as stdio

import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod
import mtc.lexer.lexer as lexer
import mtc.parser.parser as parser
import mtc.pretty_printer.ast_formatter as ast_formatter
import mtc.semantic.analyzer as analyzer


function main(args: span[str]) -> int:
    if args.len < 1:
        print_help()
        return 1

    let cmd = args[0]

    if cmd == "lex":
        var machine = false
        var file_index: ptr_uint = 1
        if args.len >= 2 and args[1] == "--machine":
            machine = true
            file_index = 2
        if args.len <= file_index:
            print_help()
            return 1
        return lex_command(args[file_index], machine)

    if cmd == "parse":
        if args.len < 2:
            print_help()
            return 1
        return parse_command(args[1])

    if cmd == "check":
        if args.len < 2:
            print_help()
            return 1
        return check_command(args[1])

    if cmd == "help":
        print_help()
        return 0

    print_unknown(cmd)
    return 1


function print_help() -> void:
    stdio.print_line("mtc — self-hosted Milk Tea compiler")
    stdio.print_line("")
    stdio.print_line("usage: mtc <command> [args...]")
    stdio.print_line("")
    stdio.print_line("commands:")
    stdio.print_line("  lex   <file>  print the lexer token stream")
    stdio.print_line("  parse <file>  parse source and print AST")
    stdio.print_line("  check <file>  parse and semantically analyze source")
    stdio.print_line("  help          print this help")


function print_unknown(cmd: str) -> void:
    stdio.print_format(c"mtc: unknown command '%.*s'\n", int<-(cmd.len), cmd.data)


function parse_command(file_path: str) -> int:
    match fs.read_text(file_path):
        Result.failure:
            stdio.print_format(c"error: cannot read '%.*s'\n", int<-(file_path.len), file_path.data)
            return 1
        Result.success as payload:
            var content = payload.value
            defer content.release()

            let source = content.as_str()
            var diags = vec.Vec[parser.ParseDiagnostic].create()
            defer diags.release()
            let file = parser.parse_source(source, ref_of(diags))

            if diags.len() > 0:
                var di: ptr_uint = 0
                while di < diags.len():
                    let d = diags.get(di) else:
                        break
                    unsafe:
                        let rd = read(d)
                        stdio.print_format(
                            c"parse error: L%d:%d lexeme='%.*s' kind=%.*s: %s\n",
                            int<-(rd.line),
                            int<-(rd.column),
                            int<-(rd.lexeme.len), rd.lexeme.data,
                            int<-(rd.kind.len), rd.kind.data,
                            rd.message,
                        )
                    di += 1
                return 1

            var rendered = ast_formatter.format_source_file(file)
            defer rendered.release()
            let text = rendered.as_str()
            stdio.print_format(c"%.*s", int<-(text.len), text.data)
            return 0


function check_command(file_path: str) -> int:
    match fs.read_text(file_path):
        Result.failure:
            stdio.print_format(c"error: cannot read '%.*s'\n", int<-(file_path.len), file_path.data)
            return 1
        Result.success as payload:
            var content = payload.value
            defer content.release()

            let source = content.as_str()
            var parse_diags = vec.Vec[parser.ParseDiagnostic].create()
            defer parse_diags.release()
            let file = parser.parse_source(source, ref_of(parse_diags))

            if parse_diags.len() > 0:
                var di: ptr_uint = 0
                while di < parse_diags.len():
                    let d = parse_diags.get(di) else:
                        break
                    unsafe:
                        let rd = read(d)
                        stdio.print_format(
                            c"parse error: L%d:%d lexeme='%.*s' kind=%.*s: %s\n",
                            int<-(rd.line),
                            int<-(rd.column),
                            int<-(rd.lexeme.len), rd.lexeme.data,
                            int<-(rd.kind.len), rd.kind.data,
                            rd.message,
                        )
                    di += 1
                report_check_summary(parse_diags.len())
                return 1

            var analysis = analyzer.check_source_file(file)
            defer analysis.diagnostics.release()

            if analysis.diagnostics.len() == 0:
                stdio.print_format(c"checked %.*s as good\n", int<-(file_path.len), file_path.data)
                return 0

            var i: ptr_uint = 0
            while i < analysis.diagnostics.len():
                let d = analysis.diagnostics.get(i) else:
                    break
                unsafe:
                    let rd = read(d)
                    stdio.print_format(
                        c"error[sema/error]: %.*s\n  --> %.*s:%d:%d\n",
                        int<-(rd.message.len), rd.message.data,
                        int<-(file_path.len), file_path.data,
                        int<-(rd.line), int<-(rd.column),
                    )
                i += 1
            report_check_summary(analysis.diagnostics.len())
            return 1


function report_check_summary(count: ptr_uint) -> void:
    stdio.print_line("")
    if count == 1:
        stdio.print_line("error: could not check due to 1 error")
    else:
        stdio.print_format(c"error: could not check due to %d errors\n", int<-(count))


function lex_command(file_path: str, machine: bool) -> int:
    match fs.read_text(file_path):
        Result.failure:
            stdio.print_format(c"error: cannot read '%.*s'\n", int<-(file_path.len), file_path.data)
            return 1
        Result.success as payload:
            var content = payload.value
            defer content.release()

            let source = content.as_str()
            var diags = vec.Vec[token_mod.LexDiagnostic].create()
            var tokens = lexer.lex_reporting(source, ref_of(diags))

            if diags.len() > 0:
                var di: ptr_uint = 0
                while di < diags.len():
                    let d = diags.get(di) else:
                        break
                    unsafe:
                        let rd = read(d)
                        stdio.print_format(
                            c"%.*s:%d:%d: lex error: %s\n",
                            int<-(file_path.len), file_path.data,
                            int<-(rd.line),
                            int<-(rd.column),
                            rd.message,
                        )
                    di += 1

            stdio.print_format(c"── Tokens  %d  ──\n", int<-(tokens.len()))

            if machine:
                # Machine-readable: kind line col start end
                var j: ptr_uint = 0
                while j < tokens.len():
                    let tok = tokens.get(j) else:
                        break
                    unsafe:
                        let t = read(tok)
                        let kn = token_mod.kind_name(t.kind)
                        stdio.print_format(
                            c"%s %d %d %d %d\n",
                            kn,
                            int<-(t.line),
                            int<-(t.column),
                            int<-(t.start_offset),
                            int<-(t.end_offset),
                        )
                    j += 1
            else:
                # Human-readable
                var k: ptr_uint = 0
                while k < tokens.len():
                    let tok = tokens.get(k) else:
                        break
                    unsafe:
                        let t = read(tok)
                        let lexeme = token_mod.token_lexeme(t, source)
                        let kn = token_mod.kind_name(t.kind)
                        let end_col = if t.kind == tk.TokenKind.eof: t.column else: t.column + lexeme.len - 1z
                        stdio.print_format(
                            c"  %3d:%d-%-3d  %-24.*s %s\n",
                            int<-(t.line),
                            int<-(t.column),
                            int<-(end_col),
                            int<-(lexeme.len), lexeme.data,
                            kn,
                        )
                    k += 1

            diags.release()
            return 0
