# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdProcessTest < Minitest::Test
  def test_capture_with_env_and_cwd
    skip "requires /bin/sh" unless File.executable?("/bin/sh")

    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-process-capture") do |dir|
      source = <<~MT


import std.process as process

import std.str as text
import std.vec as vec

function main() -> int:
    var command = vec.Vec[str].create()
    defer command.release()
    command.push(\"/bin/sh\")
    command.push(\"-c\")
    command.push(\"printf '%s\\n' \\\"$PWD\\\"; printf '%s' \\\"$MILK_TEA_PROCESS_TEST\\\" >&2; exit 7\")

    var environment = vec.Vec[process.EnvironmentEntry].create()
    defer environment.release()
    environment.push(process.EnvironmentEntry(name = \"MILK_TEA_PROCESS_TEST\", value = \"from-env\"))

    match process.capture_with_env(command.as_span(), Option[str].some(value= \"#{dir}\"), environment.as_span()):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success as payload:
            var result = payload.value
            defer result.release()
            if result.status.normalized_code() != 7:
                return 2
            match result.stdout_text():
                Option.some as stdout_payload:
                    if not stdout_payload.value.equal(\"#{dir}\\n\"):
                        return 3
                Option.none:
                    return 4
            match result.stderr_text():
                Option.some as stderr_payload:
                    if not stderr_payload.value.equal(\"from-env\"):
                        return 5
                Option.none:
                    return 6
            return 0
      MT

      result = run_program(source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
    end
  end

  def test_spawn_detached_in_runs_command_in_background
    skip "requires /bin/sh" unless File.executable?("/bin/sh")

    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-process-detached") do |dir|
      output_path = File.join(dir, "detached.out")
      source = <<~MT


import std.process as process

import std.vec as vec

function main() -> int:
    var command = vec.Vec[str].create()
    defer command.release()
    command.push(\"/bin/sh\")
    command.push(\"-c\")
    command.push(\"printf detached > detached.out\")

    match process.spawn_detached_in(command.as_span(), \"#{dir}\"):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success as payload:
            if payload.value <= 0:
                return 2
            return 0
      MT

      result = run_program(source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status

      deadline = Time.now + 2
      until File.exist?(output_path) || Time.now >= deadline
        sleep 0.05
      end

      assert File.exist?(output_path), "detached process did not create #{output_path}"
      assert_equal "detached", File.read(output_path)
    end
  end

  def test_spawn_supports_interactive_stdio
    skip "requires /bin/sh" unless File.executable?("/bin/sh")

    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT


import std.process as process

import std.str as text
import std.vec as vec

function main() -> int:
    var command = vec.Vec[str].create()
    defer command.release()
    command.push("/bin/sh")
    command.push("-c")
    command.push("cat; printf 'err:done' >&2")

    match process.spawn(command.as_span()):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success as payload:
            var child = payload.value
            defer child.release()

            match child.write_stdin("milk-tea\\n"):
                Result.failure as write_payload:
                    var error = write_payload.error
                    defer error.release()
                    return 2
                Result.success as _:
                    pass

            match child.close_stdin():
                Result.failure as close_payload:
                    var error = close_payload.error
                    defer error.release()
                    return 3
                Result.success as _:
                    pass

            match child.wait():
                Result.failure as wait_payload:
                    var error = wait_payload.error
                    defer error.release()
                    return 4
                Result.success as wait_payload:
                    if not wait_payload.value.success():
                        return 5

            match child.read_stdout(1000):
                Result.failure as stdout_payload:
                    var error = stdout_payload.error
                    defer error.release()
                    return 6
                Result.success as stdout_payload:
                    var stdout_chunk = stdout_payload.value
                    defer stdout_chunk.release()
                    if not stdout_chunk.ready:
                        return 7
                    match stdout_chunk.text():
                        Option.some as text_payload:
                            if not text_payload.value.equal("milk-tea\\n"):
                                return 8
                        Option.none:
                            return 9

            match child.read_stderr(1000):
                Result.failure as stderr_payload:
                    var error = stderr_payload.error
                    defer error.release()
                    return 10
                Result.success as stderr_payload:
                    var stderr_chunk = stderr_payload.value
                    defer stderr_chunk.release()
                    if not stderr_chunk.ready:
                        return 11
                    match stderr_chunk.text():
                        Option.some as text_payload:
                            if not text_payload.value.equal("err:done"):
                                return 12
                        Option.none:
                            return 13

            return 0
      MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_spawn_pty_supports_resize_and_terminal_io
    skip "requires /bin/sh" unless File.executable?("/bin/sh")

    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT


import std.process as process

import std.str as text
import std.string as string
import std.vec as vec

function main() -> int:
    var command = vec.Vec[str].create()
    defer command.release()
    command.push("/bin/sh")
    command.push("-c")
    command.push("read ignored; stty size; printf 'pty:ready\\n'")

    match process.spawn_pty(command.as_span(), 80, 24):
        Result.failure as payload:
            var error = payload.error
            defer error.release()
            return 1
        Result.success as payload:
            var child = payload.value
            defer child.release()

            match child.resize(100, 40):
                Result.failure as resize_payload:
                    var error = resize_payload.error
                    defer error.release()
                    return 2
                Result.success as _:
                    pass

            match child.write("milk-tea\\n"):
                Result.failure as write_payload:
                    var error = write_payload.error
                    defer error.release()
                    return 3
                Result.success as _:
                    pass

            match child.wait():
                Result.failure as wait_payload:
                    var error = wait_payload.error
                    defer error.release()
                    return 4
                Result.success as wait_payload:
                    if not wait_payload.value.success():
                        return 5

            var output = string.String.create()
            defer output.release()

            var attempts = 0
            while attempts < 6:
                match child.read(1000):
                    Result.failure as read_payload:
                        var error = read_payload.error
                        defer error.release()
                        return 6
                    Result.success as read_payload:
                        var chunk = read_payload.value
                        defer chunk.release()
                        match chunk.text():
                            Option.some as text_payload:
                                output.append(text_payload.value)
                            Option.none:
                                pass
                        if chunk.closed:
                            break
                attempts += 1

            if not output.as_str().equal("milk-tea\\r\\n40 100\\r\\npty:ready\\r\\n"):
                return 7

            return 0
      MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-process") do |dir|
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
