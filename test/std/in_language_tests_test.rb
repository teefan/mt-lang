# frozen_string_literal: true

require "stringio"
require_relative "../test_helper"

# Bridges the in-language Milk Tea tests under test/mt/ into the Ruby test suite:
# builds and runs them with `mtc test` and asserts the suite passes.
class InLanguageStdTest < Minitest::Test
  def test_in_language_std_tests_pass_under_mtc_test
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    dir = File.join(MilkTea.root.to_s, "test", "mt")
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["test", dir], out:, err:)

    assert_equal 0, status, "mtc test #{dir} failed:\n#{out.string}\n#{err.string}"
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
