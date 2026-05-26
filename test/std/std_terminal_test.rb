# frozen_string_literal: true

require "pty"
require "timeout"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdTerminalTest < Minitest::Test
  def test_output_helpers_emit_expected_ansi_sequences
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT


import std.terminal as terminal

function main() -> int:
    match terminal.enter_alternate_screen():
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success as _:
            pass

    match terminal.hide_cursor():
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 2
        Result.success as _:
            pass

    match terminal.move_cursor(3, 5):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 3
        Result.success as _:
            pass

    match terminal.set_foreground(terminal.Color.bright_green):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 4
        Result.success as _:
            pass

    match terminal.write_stdout("OK"):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 5
        Result.success as _:
            pass

    match terminal.reset_style():
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 6
        Result.success as _:
            pass

    match terminal.show_cursor():
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 7
        Result.success as _:
            pass

    match terminal.leave_alternate_screen():
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 8
        Result.success as _:
            pass

    match terminal.flush_stdout():
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 9
        Result.success as _:
            return 0
    MT

    result = run_program(source, compiler:)

    assert_equal "\e[?1049h\e[?25l\e[3;5H\e[92mOK\e[0m\e[?25h\e[?1049l", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_terminal_reads_arrow_keys_over_pty_and_restores_terminal_state
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT


import std.terminal as terminal

function main() -> int:
    if not terminal.stdin_is_tty():
        return 1
    if not terminal.stdout_is_tty():
        return 2

    var tty = terminal.Terminal.create()
    defer tty.release()

    match tty.refresh_size():
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 3
        Result.success as _:
            pass

    match tty.enter_alternate_screen():
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 4
        Result.success as _:
            pass

    match tty.hide_cursor():
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 5
        Result.success as _:
            pass

    match tty.enable_mouse():
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 6
        Result.success as _:
            pass

    match tty.enter_raw_mode():
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 7
        Result.success as _:
            pass

    match tty.write("READY\\n"):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 8
        Result.success as _:
            pass

    match tty.flush():
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 9
        Result.success as _:
            pass

    match tty.poll_event(1500):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 10
        Result.success as payload:
            match payload.value:
                Option.none:
                    return 11
                Option.some as event_payload:
                    let event = event_payload.value
                    if event.kind != terminal.EventKind.key:
                        return 12
                    if event.key.code != terminal.KeyCode.up:
                        return 13
                    return 0
    MT

    with_built_program(source, compiler:) do |output_path|
      output = +""
      status = nil

      PTY.spawn(output_path) do |reader, writer, pid|
        begin
          Timeout.timeout(5) do
            until output.include?("READY\n")
              output << reader.readpartial(1024)
            end
          end

          writer.write("\e[A")
          writer.flush

          _waited_pid, status = Process.wait2(pid)

          begin
            loop do
              output << reader.readpartial(1024)
            end
          rescue EOFError, Errno::EIO
          end
        ensure
          reader.close unless reader.closed?
          writer.close unless writer.closed?
        end
      end

      refute_nil status
      assert status.success?, "pty child failed with #{status.inspect} and output #{output.inspect}"
      assert_includes output, "\e[?1049h"
      assert_includes output, "\e[?25l"
      assert_includes output, "\e[?1006h"
      assert_includes output, "\e[?1006l"
      assert_includes output, "\e[?25h"
      assert_includes output, "\e[?1049l"
    end
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-terminal-run") do |dir|
      source_path = File.join(dir, "program.mt")
      File.write(source_path, source)
      return MilkTea::Run.run(source_path, cc: compiler)
    end
  end

  def with_built_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-terminal-build") do |dir|
      source_path = File.join(dir, "program.mt")
      output_path = File.join(dir, "program")
      File.write(source_path, source)
      result = MilkTea::Build.build(source_path, output_path:, cc: compiler)
      yield result.output_path
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