# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaMtimeToolTest < Minitest::Test
  def test_mtime_returns_a_stamp_with_subsecond_precision
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-mtime-tool") do |dir|
      path = File.join(dir, "stamp.txt")
      File.write(path, "alpha\n")

      first_time = Time.at(Time.now.to_i, 100_000_000, :nsec)
      second_time = Time.at(first_time.to_i, 700_000_000, :nsec)
      File.utime(first_time, first_time, path)
      first_stamp = MilkTea::MtimeTool.mtime(path:, cc: compiler)

      File.write(path, "beta\n")
      File.utime(second_time, second_time, path)
      second_stamp = MilkTea::MtimeTool.mtime(path:, cc: compiler)

      assert_equal first_time.to_i, first_stamp.seconds
      assert_equal second_time.to_i, second_stamp.seconds
      refute_equal first_stamp.cache_key, second_stamp.cache_key
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
