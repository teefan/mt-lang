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
        "import std.maybe as maybe",
        "import std.process as process",
        "import std.str as text",
        "",
        "def main(argc: int, argv: ptr[cstr]) -> int:",
        "    let first = process.arg(argc, argv, 1)",
        "    let second = process.arg(argc, argv, 2)",
        "    let env_value = process.env(\"MT_PROCESS_TEST\")",
        "    if maybe.is_none(first) or maybe.is_none(second) or maybe.is_none(env_value):",
        "        return 1",
        "    match first:",
        "        maybe.Maybe.none:",
        "            return 1",
        "        maybe.Maybe.some as first_payload:",
        "            if not text.equal(first_payload.value, \"alpha\"):",
        "                return 2",
        "            match second:",
        "                maybe.Maybe.none:",
        "                    return 1",
        "                maybe.Maybe.some as second_payload:",
        "                    if not text.equal(second_payload.value, \"beta\"):",
        "                        return 3",
        "                    match env_value:",
        "                        maybe.Maybe.none:",
        "                            return 1",
        "                        maybe.Maybe.some as env_payload:",
        "                            if not text.equal(env_payload.value, \"present\"):",
        "                                return 4",
        "                            return int<-process.arg_count(argc) + int<-first_payload.value.len + int<-second_payload.value.len",
        "    return 1",
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
