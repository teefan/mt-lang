# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaReadLinesToolTest < Minitest::Test
  def test_read_lines_returns_chomped_lines_and_preserves_empty_rows
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-read-lines-tool") do |dir|
      path = File.join(dir, "lines.txt")
      File.write(path, "alpha\r\nbeta\n\ngamma")

      assert_equal ["alpha", "beta", "", "gamma"], MilkTea::ReadLinesTool.read_lines(path:, cc: compiler)
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
