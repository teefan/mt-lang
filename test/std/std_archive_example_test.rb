# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdArchiveExampleTest < Minitest::Test
  def test_archive_example_runs_and_kept_c_rebuilds_cleanly
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-archive-example") do |dir|
      source_path = File.join(dir, "std_archive_example.mt")
      keep_c_path = File.join(dir, "std_archive_example.c")
      strict_output = File.join(dir, "std_archive_example_strict")

      FileUtils.cp(example_source_path, source_path)

      result = MilkTea::Run.run(source_path, cc: compiler, keep_c_path: keep_c_path)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_equal keep_c_path, result.c_path
      assert File.exist?(keep_c_path)
      assert_includes result.link_flags, "-lz"

      stdout, stderr, status = Open3.capture3(
        compiler,
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-I#{File.join(MilkTea.root, 'std', 'c')}",
        keep_c_path,
        "-o",
        strict_output,
        *result.link_flags,
      )

      assert status.success?, [stdout, stderr].reject(&:empty?).join
      assert_equal "", stdout
      assert_equal "", stderr

      rerun_stdout, rerun_stderr, rerun_status = Open3.capture3(strict_output, chdir: dir)

      assert rerun_status.success?, [rerun_stdout, rerun_stderr].reject(&:empty?).join
      assert_equal "", rerun_stdout
      assert_equal "", rerun_stderr
    end
  end

  private

  def example_source_path
    File.expand_path("../../tmp/std_archive_example.mt", __dir__)
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
