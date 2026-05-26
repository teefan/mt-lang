# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdCliTest < Minitest::Test
  def test_host_runtime_parses_flags_values_defaults_commands_and_help
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.cli as cli
import std.str as text


function expect_value(match_result: cli.Match, name: str, expected: str, failure_code: int) -> int:
    match match_result.value(name):
        Option.some as payload:
            if not payload.value.equal(expected):
                return failure_code
            return 0
        Option.none:
            return failure_code + 1


function main() -> int:
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
            defer error.release()
            return 1
        Result.success as payload:
            var parsed = payload.value
            defer parsed.release()
            if parsed.help_requested():
                return 2
            match parsed.command():
                Option.some as command_payload:
                    if not command_payload.value.equal("inspect"):
                        return 3
                Option.none:
                    return 4
            if not parsed.flag("verbose"):
                return 5
            let config_status = expect_value(parsed, "config", "custom.toml", 6)
            if config_status != 0:
                return config_status
            let interval_status = expect_value(parsed, "interval", "250", 8)
            if interval_status != 0:
                return interval_status
            if parsed.positionals_len() != ptr_uint<-1:
                return 10
            match parsed.positional(0):
                Option.some as positional_payload:
                    if not positional_payload.value.equal("cpu"):
                        return 11
                Option.none:
                    return 12

    var default_args = array[str, 1]("inspect")
    match cli.parse(app, default_args):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 13
        Result.success as payload:
            var parsed = payload.value
            defer parsed.release()
            if parsed.flag("verbose"):
                return 14
            let config_status = expect_value(parsed, "config", "mtop.toml", 15)
            if config_status != 0:
                return config_status
            let interval_status = expect_value(parsed, "interval", "500", 17)
            if interval_status != 0:
                return interval_status

    var help_args = array[str, 2]("inspect", "--help")
    match cli.parse(app, help_args):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 19
        Result.success as payload:
            var parsed = payload.value
            defer parsed.release()
            if not parsed.help_requested():
                return 20

    var app_help = cli.render_help(app)
    defer app_help.release()
    if not app_help.as_str().equal("mtop - Monitor system state\\nUsage: mtop [options] <command>\\n\\nMonitor system state\\n\\nCommands:\\n  inspect - Inspect metrics\\n\\nOptions:\\n  -h, --help - Show this help\\n  -v, --verbose - Verbose output\\n  -c, --config FILE - Config file (default: mtop.toml)\\n"):
        return 21

    match cli.render_command_help(app, "inspect"):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 22
        Result.success as payload:
            var help_text = payload.value
            defer help_text.release()
            if not help_text.as_str().equal("mtop inspect - Inspect host metrics\\nUsage: mtop inspect [options] VIEW...\\n\\nInspect host metrics\\n\\nOptions:\\n  -h, --help - Show this help\\n  -v, --verbose - Verbose output\\n  -c, --config FILE - Config file (default: mtop.toml)\\n  -i, --interval MS - Refresh interval (default: 500)\\n"):
                return 23

    var bad_args = array[str, 1]("--wat")
    match cli.parse(app, bad_args):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            if not error.message.as_str().equal("unknown option --wat"):
                return 24
        Result.success as payload:
            var parsed = payload.value
            defer parsed.release()
            return 25

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-cli") do |dir|
      source_path = File.join(dir, "program.mt")
      File.write(source_path, source)
      return MilkTea::Run.run(source_path, cc: compiler)
    end
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
