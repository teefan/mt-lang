import mtop.dashboard as dashboard
import std.cli as cli
import std.libc as libc
import std.str as text
import std.terminal as terminal
import std.vec as vec


function write_stdout_text(value: str) -> int:
    match terminal.write_stdout(value):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success:
            return 0


function write_stderr_text(value: str) -> int:
    match terminal.write_stderr(value):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success:
            return 0


function print_help(app: cli.AppSpec, command_name: Option[str]) -> int:
    match command_name:
        Option.some as payload:
            match cli.render_command_help(app, payload.value):
                Result.failure as error_payload:
                    var error = error_payload.error
                    defer error.release()
                    return write_stderr_text(error.message.as_str())
                Result.success as help_payload:
                    var help = help_payload.value
                    defer help.release()
                    return write_stdout_text(help.as_str())
        Option.none:
            var help = cli.render_help(app)
            defer help.release()
            return write_stdout_text(help.as_str())


function parse_interval_ms(parsed: cli.Match) -> int:
    match parsed.value("interval-ms"):
        Option.some as payload:
            let parsed_value = libc.parse_int(payload.value)
            if parsed_value > 0:
                return parsed_value
        Option.none:
            pass

    return 900


function parse_config(parsed: cli.Match) -> dashboard.Config:
    return dashboard.Config(
        interval_ms = parse_interval_ms(parsed),
        mouse_enabled = not parsed.flag("no-mouse"),
    )


function app_definition(options: span[cli.OptionSpec], commands: span[cli.CommandSpec]) -> cli.AppSpec:
    return cli.app_spec(
        "mtop",
        "Interactive CLI/TUI dashboard demo for Milk Tea",
        options,
        commands,
        Option[str].none,
    )


function main(args: span[str]) -> int:
    var options = vec.Vec[cli.OptionSpec].create()
    defer options.release()
    options.push(cli.value_option(
        "interval-ms",
        Option[str].some(value= "i"),
        "MS",
        "Dashboard refresh interval in milliseconds",
        false,
        Option[str].some(value= "900"),
    ))
    options.push(cli.flag_option("no-mouse", Option[str].none, "Disable mouse reporting in dashboard mode"))

    var commands = vec.Vec[cli.CommandSpec].create()
    defer commands.release()
    commands.push(cli.command_spec(
        "dashboard",
        "Run the interactive terminal dashboard",
        "Run the interactive terminal dashboard",
        zero[span[cli.OptionSpec]],
        Option[str].none,
    ))
    commands.push(cli.command_spec(
        "once",
        "Print a single snapshot and exit",
        "Print a single snapshot and exit",
        zero[span[cli.OptionSpec]],
        Option[str].none,
    ))

    let app = app_definition(options.as_span(), commands.as_span())
    match cli.parse(app, args):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return write_stderr_text(error.message.as_str())
        Result.success as payload:
            var parsed = payload.value
            defer parsed.release()

            if parsed.help_requested():
                return print_help(app, parsed.command())

            match parsed.command():
                Option.some as command_payload:
                    if command_payload.value.equal("once"):
                        return dashboard.print_once()

                    if command_payload.value.equal("dashboard"):
                        return dashboard.run(parse_config(parsed))

                    return write_stderr_text("unknown command\n")
                Option.none:
                    return dashboard.run(parse_config(parsed))
