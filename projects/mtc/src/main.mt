import std.cli as cli
import std.fmt
import std.stdio
import std.string as string
import std.terminal as terminal


struct FileReadError:
    message: string.String


extending FileReadError:
    public editable function release() -> void:
        this.message.release()


function write_stdout(value: str) -> void:
    match terminal.write_stdout(value):
        Result.failure:
            pass
        Result.success:
            pass


function write_stderr(value: str) -> void:
    match terminal.write_stderr(value):
        Result.failure:
            pass
        Result.success:
            pass


function print_help(app: cli.AppSpec, command_name: Option[str]) -> int:
    match command_name:
        Option.some as payload:
            match cli.render_command_help(app, payload.value):
                Result.failure as error_payload:
                    var error = error_payload.error
                    defer error.release()
                    write_stderr(error.message.as_str())
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


function read_file_into_string(path: str) -> Result[string.String, FileReadError]:
    let file = stdio.file_open(path, "rb")
    if file == null:
        var message = string.String.create()
        message.append_format(f"cannot open file: #{path}")
        return Result[string.String, FileReadError].failure(
            error= FileReadError(message= message)
        )

    var content = string.String.create()

    while true:
        let ch = stdio.file_read_char(file)
        if ch == -1:
            break

        content.push_byte(ubyte<-ch)

    stdio.file_close(file)
    return Result[string.String, FileReadError].success(value= content)


function read_source_file(path: str) -> Option[string.String]:
    match read_file_into_string(path):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            write_stderr(error.message.as_str())
            return Option[string.String].none
        Result.success as payload:
            return Option[string.String].some(value= payload.value)


function lex_command(parsed: cli.Match, app: cli.AppSpec) -> int:
    if parsed.positionals_len() == 0:
        return print_help(app, Option[str].some(value= "lex"))

    match parsed.positional(0):
        Option.some as payload:
            match read_source_file(payload.value):
                Option.some as content_value:
                    var content = content_value.value
                    defer content.release()
                    var msg = string.String.create()
                    msg.append_format(f"lex: #{payload.value} (#{content.len} bytes) [not yet implemented]\n")
                    write_stdout(msg.as_str())
                    msg.release()
                    return 0
                Option.none:
                    return 1
        Option.none:
            return print_help(app, Option[str].some(value= "lex"))


function parse_command(parsed: cli.Match, app: cli.AppSpec) -> int:
    if parsed.positionals_len() == 0:
        return print_help(app, Option[str].some(value= "parse"))

    match parsed.positional(0):
        Option.some as payload:
            match read_source_file(payload.value):
                Option.some as content_value:
                    var content = content_value.value
                    defer content.release()
                    var msg = string.String.create()
                    msg.append_format(f"parse: #{payload.value} (#{content.len} bytes) [not yet implemented]\n")
                    write_stdout(msg.as_str())
                    msg.release()
                    return 0
                Option.none:
                    return 1
        Option.none:
            return print_help(app, Option[str].some(value= "parse"))


function check_command(parsed: cli.Match, app: cli.AppSpec) -> int:
    if parsed.positionals_len() == 0:
        return print_help(app, Option[str].some(value= "check"))

    match parsed.positional(0):
        Option.some as payload:
            match read_source_file(payload.value):
                Option.some as content_value:
                    var content = content_value.value
                    defer content.release()
                    var msg = string.String.create()
                    msg.append_format(f"check: #{payload.value} (#{content.len} bytes) [not yet implemented]\n")
                    write_stdout(msg.as_str())
                    msg.release()
                    return 0
                Option.none:
                    return 1
        Option.none:
            return print_help(app, Option[str].some(value= "check"))


function lower_command(parsed: cli.Match, app: cli.AppSpec) -> int:
    if parsed.positionals_len() == 0:
        return print_help(app, Option[str].some(value= "lower"))

    match parsed.positional(0):
        Option.some as payload:
            match read_source_file(payload.value):
                Option.some as content_value:
                    var content = content_value.value
                    defer content.release()
                    var msg = string.String.create()
                    msg.append_format(f"lower: #{payload.value} (#{content.len} bytes) [not yet implemented]\n")
                    write_stdout(msg.as_str())
                    msg.release()
                    return 0
                Option.none:
                    return 1
        Option.none:
            return print_help(app, Option[str].some(value= "lower"))


function emit_c_command(parsed: cli.Match, app: cli.AppSpec) -> int:
    if parsed.positionals_len() == 0:
        return print_help(app, Option[str].some(value= "emit-c"))

    match parsed.positional(0):
        Option.some as payload:
            match read_source_file(payload.value):
                Option.some as content_value:
                    var content = content_value.value
                    defer content.release()
                    var msg = string.String.create()
                    msg.append_format(f"emit-c: #{payload.value} (#{content.len} bytes) [not yet implemented]\n")
                    write_stdout(msg.as_str())
                    msg.release()
                    return 0
                Option.none:
                    return 1
        Option.none:
            return print_help(app, Option[str].some(value= "emit-c"))


function build_command(parsed: cli.Match, app: cli.AppSpec) -> int:
    if parsed.positionals_len() == 0:
        return print_help(app, Option[str].some(value= "build"))

    match parsed.positional(0):
        Option.some as payload:
            match read_source_file(payload.value):
                Option.some as content_value:
                    var content = content_value.value
                    defer content.release()
                    var msg = string.String.create()
                    msg.append_format(f"build: #{payload.value} (#{content.len} bytes) [not yet implemented]\n")
                    write_stdout(msg.as_str())
                    msg.release()
                    return 0
                Option.none:
                    return 1
        Option.none:
            return print_help(app, Option[str].some(value= "build"))


function run_command(parsed: cli.Match, app: cli.AppSpec) -> int:
    if parsed.positionals_len() == 0:
        return print_help(app, Option[str].some(value= "run"))

    match parsed.positional(0):
        Option.some as payload:
            match read_source_file(payload.value):
                Option.some as content_value:
                    var content = content_value.value
                    defer content.release()
                    var msg = string.String.create()
                    msg.append_format(f"run: #{payload.value} (#{content.len} bytes) [not yet implemented]\n")
                    write_stdout(msg.as_str())
                    msg.release()
                    return 0
                Option.none:
                    return 1
        Option.none:
            return print_help(app, Option[str].some(value= "run"))


function dispatch_command(parsed: cli.Match, app: cli.AppSpec) -> int:
    match parsed.command():
        Option.some as command_payload:
            let name = command_payload.value
            if name == "lex":
                return lex_command(parsed, app)
            if name == "parse":
                return parse_command(parsed, app)
            if name == "check":
                return check_command(parsed, app)
            if name == "lower":
                return lower_command(parsed, app)
            if name == "emit-c":
                return emit_c_command(parsed, app)
            if name == "build":
                return build_command(parsed, app)
            if name == "run":
                return run_command(parsed, app)

            write_stderr("unknown command\n")
            return print_help(app, Option[str].none)
        Option.none:
            return print_help(app, Option[str].none)


function main(args: span[str]) -> int:
    var options = zero[span[cli.OptionSpec]]

    var commands: array[cli.CommandSpec, 7]
    commands[0] = cli.command_spec(
        "lex", "Tokenize a source file",
        "Lex the source file and output tokens.", options, Option[str].some(value= "FILE")
    )
    commands[1] = cli.command_spec(
        "parse", "Parse a source file and print the AST",
        "Parse the source file and print the abstract syntax tree.", options, Option[str].some(value= "FILE")
    )
    commands[2] = cli.command_spec(
        "check", "Check a source file with semantic analysis",
        "Run full semantic analysis on the source file.", options, Option[str].some(value= "FILE")
    )
    commands[3] = cli.command_spec(
        "lower", "Lower to IR and print",
        "Lower the checked source file to IR and print the result.", options, Option[str].some(value= "FILE")
    )
    commands[4] = cli.command_spec(
        "emit-c", "Compile to C and print",
        "Compile the source file to C source code and print it.", options, Option[str].some(value= "FILE")
    )
    commands[5] = cli.command_spec(
        "build", "Compile to a native binary",
        "Build the source file into a native executable.", options, Option[str].some(value= "FILE")
    )
    commands[6] = cli.command_spec(
        "run", "Build and run a native binary",
        "Build and execute the source file as a native binary.", options, Option[str].some(value= "FILE")
    )

    let app = cli.app_spec(
        "mtc",
        "Milk Tea Compiler",
        options,
        commands,
        Option[str].none,
    )
    match cli.parse(app, args):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            write_stderr(error.message.as_str())
            return 1
        Result.success as payload:
            var parsed = payload.value
            defer parsed.release()

            if parsed.help_requested():
                let cmd = parsed.command()
                return print_help(app, cmd)

            return dispatch_command(parsed, app)
