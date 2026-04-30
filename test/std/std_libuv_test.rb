# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdLibuvTest < Minitest::Test
  def test_host_runtime_exposes_libuv_version
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-libuv") do |dir|
      source_path = File.join(dir, "program.mt")
      output_path = File.join(dir, "program")
      File.write(source_path, [
        "module demo.std_libuv",
        "",
        "import std.libuv as uv",
        "",
        "def main(argc: i32, argv: ptr[cstr]) -> i32:",
        "    if uv.version() == cast[u32](0):",
        "        return 1",
        "    return 0",
        "",
      ].join("\n"))

      build = MilkTea::Build.build(source_path, output_path:, cc: compiler)
      stdout, stderr, status = Open3.capture3(build.output_path)

      assert_equal "", stdout
      assert_equal "", stderr
      assert_equal 0, status.exitstatus
      assert_includes build.link_flags, "-luv"
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
