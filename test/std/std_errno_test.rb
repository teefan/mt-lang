# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdErrnoRuntimeTest < Minitest::Test
  def test_host_runtime_executes_errno_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-errno") do |dir|
      source_path = File.join(dir, "std_errno.mt")

      File.write(source_path, [
        "import std.errno as errno",
        "",
        "function main() -> int:",
        "    errno.clear()",
        "    if errno.current() != errno.NONE:",
        "        return 1",
        "",
        "    errno.set_current(errno.ENOENT)",
        "    if errno.current() != errno.ENOENT:",
        "        return 2",
        "    if errno.message(errno.ENOENT) == null:",
        "        return 3",
        "    if errno.current_message() == null:",
        "        return 4",
        "",
        "    errno.set_current(errno.EINVAL)",
        "    if errno.current() != errno.EINVAL:",
        "        return 5",
        "    if errno.message(errno.EPERM) == null:",
        "        return 6",
        "",
        "    errno.clear()",
        "    if errno.current() != errno.NONE:",
        "        return 7",
        "",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
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
