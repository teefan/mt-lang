# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "test_helper"

class MilkTeaBuildTest < Minitest::Test
  def test_build_generates_output_and_kept_c_with_link_flags
    Dir.mktmpdir("milk-tea-build") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      output_path = File.join(dir, "milk-tea-demo")
      c_path = File.join(dir, "milk-tea-demo.c")

      result = MilkTea::Build.build(demo_path, output_path:, cc: compiler_path, keep_c_path: c_path)

      assert_equal File.expand_path(output_path), result.output_path
      assert_equal File.expand_path(c_path), result.c_path
      assert_equal File.expand_path(compiler_path), result.compiler
      assert_includes result.link_flags, "-lraylib"
      assert File.exist?(output_path)
      assert File.exist?(c_path)
      assert_match(/#include "raylib\.h"/, File.read(c_path))

      invocation = File.read(compiler_log).lines(chomp: true)
      assert_includes invocation, "-std=c11"
      assert_includes invocation, File.expand_path(c_path)
      assert_includes invocation, File.expand_path(output_path)
      assert_includes invocation, "-lraylib"
    end
  end

  def test_build_reports_missing_compiler
    error = assert_raises(MilkTea::BuildError) do
      MilkTea::Build.build(demo_path, cc: "/definitely/missing/cc")
    end

    assert_match(/C compiler not found/, error.message)
  end

  def test_build_with_host_compiler_produces_runnable_binary
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-build-real") do |dir|
      source_path = File.join(dir, "smoke.mt")
      output_path = File.join(dir, "smoke")

      File.write(source_path, [
        "module demo.smoke",
        "",
        "const base: i32 = 40",
        "",
        "def main() -> i32:",
        "    let value = base + 2",
        "    return value",
        "",
      ].join("\n"))

      result = MilkTea::Build.build(source_path, output_path:, cc: compiler)

      assert_equal File.expand_path(output_path), result.output_path
      assert_nil result.c_path
      assert_equal [], result.link_flags
      assert File.exist?(output_path)
      assert File.executable?(output_path)

      stdout, stderr, status = Open3.capture3(output_path)
      assert_equal "", stdout
      assert_equal "", stderr
      assert_equal 42, status.exitstatus
    end
  end

  private

  def demo_path
    File.expand_path("../examples/milk-tea-demo.mt", __dir__)
  end

  def write_fake_compiler(dir, log_path)
    path = File.join(dir, "fake-cc")
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
      : > "$output"
    SH
    File.chmod(0o755, path)
    path
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
