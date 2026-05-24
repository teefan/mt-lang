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
