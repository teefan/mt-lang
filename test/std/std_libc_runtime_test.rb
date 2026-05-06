# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdLibcRuntimeTest < Minitest::Test
  def test_host_runtime_executes_generated_temp_and_realpath_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-libc") do |dir|
      source_path = File.join(dir, "std_libc.mt")

      File.write(source_path, [
        "module demo.std_libc_runtime",
        "",
        "import std.libc as libc",
        "import std.str as text",
        "",
        "def main() -> int:",
        "    var file_template: str_builder[64]",
        "    file_template.assign(\"mt-libc-file-XXXXXX\")",
        "    let file = libc.mkstemp(file_template)",
        "    if file < 0:",
        "        return 1",
        "    let file_view = file_template.as_str()",
        "    if text.equal(file_view, \"mt-libc-file-XXXXXX\"):",
        "        return 2",
        "",
        "    var suffix_template: str_builder[64]",
        "    suffix_template.assign(\"mt-libc-suffix-XXXXXX.log\")",
        "    let suffix_file = libc.mkstemps(suffix_template, 4)",
        "    if suffix_file < 0:",
        "        return 3",
        "    let suffix_view = suffix_template.as_str()",
        "    if text.equal(suffix_view, \"mt-libc-suffix-XXXXXX.log\"):",
        "        return 4",
        "    if not text.ends_with(suffix_view, \".log\"):",
        "        return 5",
        "",
        "    var dir_template: str_builder[64]",
        "    dir_template.assign(\"mt-libc-dir-XXXXXX\")",
        "    let dir_result = libc.mkdtemp(dir_template)",
        "    if dir_result == null:",
        "        return 6",
        "    let dir_view = dir_template.as_str()",
        "    if text.equal(dir_view, \"mt-libc-dir-XXXXXX\"):",
        "        return 7",
        "",
        "    var resolved: str_builder[512]",
        "    let resolved_result = libc.realpath(dir_view, resolved)",
        "    if resolved_result == null:",
        "        return 8",
        "    let resolved_view = resolved.as_str()",
        "    if resolved_view.len <= dir_view.len:",
        "        return 9",
        "    if not text.starts_with(resolved_view, \"/\"):",
        "        return 10",
        "    if not text.ends_with(resolved_view, dir_view):",
        "        return 11",
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
