# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdCtypeRuntimeTest < Minitest::Test
  def test_host_runtime_executes_ctype_classification_and_case_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-ctype") do |dir|
      source_path = File.join(dir, "std_ctype.mt")

      File.write(source_path, <<~MT

import std.ctype as ctype

function main() -> int:
    if not ctype.is_alpha(65):
        return 1
    if ctype.is_alpha(49):
        return 2
    if not ctype.is_digit(53):
        return 3
    if not ctype.is_space(32):
        return 4
    if not ctype.is_punct(33):
        return 5
    if not ctype.is_xdigit(70):
        return 6
    if ctype.is_xdigit(71):
        return 7
    if ctype.to_lower(81) != 113:
        return 8
    if ctype.to_upper(109) != 77:
        return 9
    return 0

      MT

      )
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
