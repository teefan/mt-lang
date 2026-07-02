import mtc.lexer as lexer
import mtc.parser as parser
import std.cli as cli
import std.string as string
import std.terminal as terminal
import std.fs as fs


function write_stdout(value: str) -> void:
    let _ = terminal.write_stdout(value)


function write_stderr(value: str) -> void:
    let _ = terminal.write_stderr(value)


function run_lex(path: str) -> int:
    var source = fs.read_text(path) else as error:
        write_stderr(f"error reading '#{path}': #{error.message.as_str()}\n")
        return 1

    defer source.release()
    let tokens = lexer.lex(source.as_str())
    var count: ptr_uint = 0
    while count < tokens.len():
        let token_ptr = tokens.get(count) else:
            fatal(c"run_lex missing token")
        unsafe:
            let token = read(token_ptr)
            write_stdout(f"#{token.line}:#{token.column} #{lexer.kind_name(token.kind)} #{token.lexeme.as_str()}\n")
        count += 1
    return 0


function run_parse(path: str) -> int:
    var source = fs.read_text(path) else as error:
        write_stderr(f"error reading '#{path}': #{error.message.as_str()}\n")
        return 1

    defer source.release()
    let tokens = lexer.lex(source.as_str())

    let result = parser.parse(tokens)
    if result.error_count > 0:
        let label = if result.error_count == 1: "error" else: "errors"
        write_stdout(f"Lexed #{tokens.len()} tokens, #{result.error_count} #{label}:\n")
        var i: ptr_uint = 0
        while i < result.errors.len():
            let err_ptr = result.errors.get(i) else:
                fatal(c"run_parse missing error")
            unsafe:
                let e = read(err_ptr)
                write_stdout(f"  #{e.line}:#{e.column}: #{e.message.as_str()}\n")
            i += 1
        return 1

    write_stdout(f"Lexed #{tokens.len()} tokens, parsed #{result.source_file.declarations.len()} declarations\n")
    return 0


function run_check(_path: str) -> int:
    write_stderr("check: not yet implemented\n")
    return 1


function run_build(_path: str) -> int:
    write_stderr("build: not yet implemented\n")
    return 1


function run_run(_path: str) -> int:
    write_stderr("run: not yet implemented\n")
    return 1


function print_help(app: cli.AppSpec, command_name: Option[str]) -> int:
    match command_name:
        Option.some as payload:
            match cli.render_command_help(app, payload.value):
                Result.failure as error_payload:
                    var error = error_payload.error
                    defer error.release()
                    write_stderr(f"#{error.message.as_str()}\n")
                    return 1
                Result.success as help_payload:
                    var help = help_payload.value
                    defer help.release()
                    write_stdout(help.as_str())
                    return 0
        Option.none:
            var help = cli.render_help(app)
            defer help.release()
            write_stdout(help.as_str())
            return 0


function app_definition() -> cli.AppSpec:
    let options = zero[span[cli.OptionSpec]]
    var commands = array[cli.CommandSpec, 5](
        cli.command_spec(
            "lex",
            "Print the lexer token stream for a source file",
            "Print the lexer token stream for a source file",
            zero[span[cli.OptionSpec]],
            Option[str].some(value = "FILE"),
        ),
        cli.command_spec(
            "parse",
            "Parse a source file and print the AST",
            "Parse a source file and print the AST",
            zero[span[cli.OptionSpec]],
            Option[str].some(value = "FILE"),
        ),
        cli.command_spec(
            "check",
            "Type-check a source file",
            "Type-check a source file",
            zero[span[cli.OptionSpec]],
            Option[str].some(value = "FILE"),
        ),
        cli.command_spec(
            "build",
            "Compile a source file",
            "Compile a source file",
            zero[span[cli.OptionSpec]],
            Option[str].some(value = "FILE"),
        ),
        cli.command_spec(
            "run",
            "Build and execute a source file",
            "Build and execute a source file",
            zero[span[cli.OptionSpec]],
            Option[str].some(value = "FILE"),
        ),
    )

    return cli.app_spec(
        "mtc",
        "Milk Tea self-hosted compiler",
        options,
        commands,
        Option[str].some(value = "COMMAND"),
    )


function main(args: span[str]) -> int:
    let app = app_definition()
    match cli.parse(app, args):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            write_stderr(f"#{error.message.as_str()}\n")
            return 1
        Result.success as payload:
            var parsed = payload.value
            defer parsed.release()

            if parsed.help_requested():
                return print_help(app, parsed.command())

            let input = parsed.positional(0) else:
                return print_help(app, parsed.command())

            match parsed.command():
                Option.some as cmd:
                    if cmd.value == "lex":
                        return run_lex(input)
                    if cmd.value == "parse":
                        return run_parse(input)
                    if cmd.value == "check":
                        return run_check(input)
                    if cmd.value == "build":
                        return run_build(input)
                    if cmd.value == "run":
                        return run_run(input)

                    write_stderr(f"unknown command '#{cmd.value}'\n")
                    return 1
                Option.none:
                    write_stderr("no command specified\n")
                    return 1
