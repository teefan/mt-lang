# In-language tests for std.cli (migrated from
# test/std/std_cli_test.rb, run by `mtc test`).

import std.testing as t
import std.cli as cli
import std.str as str


function expect_value(match_result: cli.Match, name: str, expected: str) -> t.Check:
    match match_result.value(name):
        Option.some as payload:
            return t.expect_true(payload.value.equal(expected))
        Option.none:
            return t.fail("missing cli value")


@[test]
function test_cli_parsing_and_help() -> t.Check:
    var global_options = array[cli.OptionSpec, 2](
        cli.flag_option("verbose", Option[str].some(value= "v"), "Verbose output"),
        cli.value_option("config", Option[str].some(value= "c"), "FILE", "Config file", false, Option[str].some(value= "mtop.toml")),
    )
    var inspect_options = array[cli.OptionSpec, 1](
        cli.value_option("interval", Option[str].some(value= "i"), "MS", "Refresh interval", false, Option[str].some(value= "500")),
    )
    var commands = array[cli.CommandSpec, 1](
        cli.command_spec("inspect", "Inspect metrics", "Inspect host metrics", inspect_options, Option[str].some(value= "VIEW...")),
    )
    let app = cli.app_spec("mtop", "Monitor system state", global_options, commands, Option[str].none)

    var args = array[str, 7]("inspect", "--verbose", "--config", "custom.toml", "-i", "250", "cpu")
    match cli.parse(app, args):
        Result.failure as payload:
            var error = payload.error
            error.release()
            return t.fail("parse with args failed")
        Result.success as payload:
            var parsed = payload.value
            defer parsed.release()
            t.expect_false(parsed.help_requested())?
            match parsed.command():
                Option.some as command_payload:
                    t.expect_true(command_payload.value.equal("inspect"))?
                Option.none:
                    return t.fail("command missing")
            t.expect_true(parsed.flag("verbose"))?
            expect_value(parsed, "config", "custom.toml")?
            expect_value(parsed, "interval", "250")?
            t.expect(parsed.positionals_len() == 1z, "one positional")?
            match parsed.positional(0):
                Option.some as positional_payload:
                    t.expect_true(positional_payload.value.equal("cpu"))?
                Option.none:
                    return t.fail("positional missing")

    var default_args = array[str, 1]("inspect")
    match cli.parse(app, default_args):
        Result.failure as payload:
            var error = payload.error
            error.release()
            return t.fail("parse defaults failed")
        Result.success as payload:
            var parsed = payload.value
            defer parsed.release()
            t.expect_false(parsed.flag("verbose"))?
            expect_value(parsed, "config", "mtop.toml")?
            expect_value(parsed, "interval", "500")?

    var help_args = array[str, 2]("inspect", "--help")
    match cli.parse(app, help_args):
        Result.failure as payload:
            var error = payload.error
            error.release()
            return t.fail("parse help failed")
        Result.success as payload:
            var parsed = payload.value
            defer parsed.release()
            t.expect_true(parsed.help_requested())?

    var app_help = cli.render_help(app)
    defer app_help.release()
    t.expect_true(app_help.as_str().equal("mtop - Monitor system state\nUsage: mtop [options] <command>\n\nMonitor system state\n\nCommands:\n  inspect - Inspect metrics\n\nOptions:\n  -h, --help - Show this help\n  -v, --verbose - Verbose output\n  -c, --config FILE - Config file (default: mtop.toml)\n"))?

    match cli.render_command_help(app, "inspect"):
        Result.failure as payload:
            var error = payload.error
            error.release()
            return t.fail("render_command_help failed")
        Result.success as payload:
            var help_text = payload.value
            defer help_text.release()
            t.expect_true(help_text.as_str().equal("mtop inspect - Inspect host metrics\nUsage: mtop inspect [options] VIEW...\n\nInspect host metrics\n\nOptions:\n  -h, --help - Show this help\n  -v, --verbose - Verbose output\n  -c, --config FILE - Config file (default: mtop.toml)\n  -i, --interval MS - Refresh interval (default: 500)\n"))?

    var bad_args = array[str, 1]("--wat")
    match cli.parse(app, bad_args):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            t.expect_true(error.message.as_str().equal("unknown option --wat"))?
        Result.success as payload:
            var parsed = payload.value
            parsed.release()
            return t.fail("bad args should fail to parse")

    return t.ok()
