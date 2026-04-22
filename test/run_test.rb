# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaRunTest < Minitest::Test
  def test_run_executes_built_program_and_preserves_requested_artifacts
    Dir.mktmpdir("milk-tea-run") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_script_compiler(dir, compiler_log, stdout: "hello\n", stderr: "warn\n", exit_status: 5)
      output_path = File.join(dir, "demo-run")
      c_path = File.join(dir, "demo-run.c")

      result = MilkTea::Run.run(demo_path, output_path:, cc: compiler_path, keep_c_path: c_path)

      assert_equal "hello\n", result.stdout
      assert_equal "warn\n", result.stderr
      assert_equal 5, result.exit_status
      assert_equal File.expand_path(output_path), result.output_path
      assert_equal File.expand_path(c_path), result.c_path
      assert_equal File.expand_path(compiler_path), result.compiler
      assert_includes result.link_flags, "-lraylib"
      assert File.exist?(output_path)
      assert File.exist?(c_path)
      assert_includes File.read(compiler_log).lines(chomp: true), "-lraylib"
    end
  end

  private

  def demo_path
    File.expand_path("../examples/milk-tea-demo.mt", __dir__)
  end

  def write_fake_script_compiler(dir, log_path, stdout:, stderr:, exit_status:)
    path = File.join(dir, "fake-run-cc")
    File.write(path, <<~SH)
      #!/bin/sh
      printf '%s\n' "$@" > #{log_path.inspect}
      output=''
      previous=''
      for argument in "$@"; do
        if [ "$previous" = '-o' ]; then
          output="$argument"
        fi
        previous="$argument"
      done
      cat > "$output" <<'SCRIPT'
      #!/bin/sh
      printf '%b' #{stdout.inspect}
      printf '%b' #{stderr.inspect} >&2
      exit #{exit_status}
      SCRIPT
      chmod +x "$output"
    SH
    File.chmod(0o755, path)
    path
  end
end
