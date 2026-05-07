# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdProcessTest < Minitest::Test
  def test_host_runtime_executes_arg_and_env_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-process") do |dir|
      source_path = File.join(dir, "program.mt")
      output_path = File.join(dir, "program")
      File.write(source_path, [
        "module demo.std_process",
        "",
        "import std.option as option",
        "import std.process as process",
        "import std.str as text",
        "",
        "def main(argc: int, argv: ptr[cstr]) -> int:",
        "    let first = process.arg(argc, argv, 1)",
        "    let second = process.arg(argc, argv, 2)",
        "    let env_value = process.env(\"MT_PROCESS_TEST\")",
        "    if first.is_none() or second.is_none() or env_value.is_none():",
        "        return 1",
        "    if not text.equal(first.unwrap(), \"alpha\"):",
        "        return 2",
        "    if not text.equal(second.unwrap(), \"beta\"):",
        "        return 3",
        "    if not text.equal(env_value.unwrap(), \"present\"):",
        "        return 4",
        "    return int<-process.arg_count(argc) + int<-first.unwrap().len + int<-second.unwrap().len",
        "",
      ].join("\n"))

      build = MilkTea::Build.build(source_path, output_path:, cc: compiler)
      stdout, stderr, status = Open3.capture3({ "MT_PROCESS_TEST" => "present" }, build.output_path, "alpha", "beta")

      assert_equal "", stdout
      assert_equal "", stderr
      assert_equal 12, status.exitstatus
      assert_equal [], build.link_flags
    end
  end

  private

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
