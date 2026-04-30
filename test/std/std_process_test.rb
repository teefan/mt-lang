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
        "import std.mem.arena as arena",
        "import std.option as option",
        "import std.process as process",
        "import std.str as text",
        "",
        "def main(argc: i32, argv: ptr[cstr]) -> i32:",
        "    var scratch = arena.create(128)",
        "    defer scratch.release()",
        "",
        "    let first = process.arg(argc, argv, 1)",
        "    let second = process.arg(argc, argv, 2)",
        "    let env_value = process.env(\"MT_PROCESS_TEST\", addr(scratch))",
        "    if option.is_none[str](first) or option.is_none[str](second) or option.is_none[str](env_value):",
        "        return 1",
        "    if not text.equal(option.unwrap[str](first), \"alpha\"):",
        "        return 2",
        "    if not text.equal(option.unwrap[str](second), \"beta\"):",
        "        return 3",
        "    if not text.equal(option.unwrap[str](env_value), \"present\"):",
        "        return 4",
        "    return i32<-process.arg_count(argc) + i32<-option.unwrap[str](first).len + i32<-option.unwrap[str](second).len",
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
