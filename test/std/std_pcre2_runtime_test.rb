# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdPcre2RuntimeTest < Minitest::Test
  def test_host_runtime_imports_pcre2_runtime_convenience_module
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.pcre2.runtime as pcre2_runtime",
      "",
      "function main() -> int:",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-lpcre2-8"
  end

  def test_host_runtime_compiles_and_matches_using_pcre2_runtime_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.pcre2 as re",
      "import std.pcre2.runtime as runtime",
      "import std.mem.heap as heap",
      "",
      "function pcre2_alloc(size: ptr_uint, user_data: ptr[void]) -> ptr[void]:",
      "    return heap.must_alloc_bytes(size)",
      "",
      "function pcre2_free(memory: ptr[void], user_data: ptr[void]) -> void:",
      "    heap.release_bytes(memory)",
      "",
      "function main() -> int:",
      "    let user_data = heap.must_alloc_bytes(1)",
      "    defer heap.release_bytes(user_data)",
      "",
      "    let general = re.general_context_create_8(pcre2_alloc, pcre2_free, user_data)",
      "    defer re.general_context_free_8(general)",
      "",
      "    let compile_context = re.compile_context_create_8(general)",
      "    defer re.compile_context_free_8(compile_context)",
      "",
      "    let match_context = re.match_context_create_8(general)",
      "    defer re.match_context_free_8(match_context)",
      "",
      "    let compiled = runtime.compile_str(\"cat\", 0, compile_context)",
      "    let code = compiled.code else:",
      "        return 1",
      "    defer re.code_free_8(code)",
      "",
      "    let match_data = re.match_data_create_from_pattern_8(code, general)",
      "    defer re.match_data_free_8(match_data)",
      "",
      "    let rc = runtime.match_str(code, \"a cat nap\", 0, 0, match_data, match_context)",
      "    if rc <= 0:",
      "        return 2",
      "",
      "    let ovector = re.get_ovector_pointer_8(match_data)",
      "    unsafe:",
      "        if read(ovector + 0) != ptr_uint<-2:",
      "            return 3",
      "        if read(ovector + 1) != ptr_uint<-5:",
      "            return 4",
      "",
      "    let broken = runtime.compile_str(\"(\", 0, compile_context)",
      "    if broken.code != null:",
      "        return 5",
      "",
      "    var message_buffer: array[ubyte, 128]",
      "    let message = runtime.error_message_as_str(broken.error_code, unsafe: span[ubyte](data = ptr_of(message_buffer[0]), len = ptr_uint<-128))",
      "    match message:",
      "        Option.none:",
      "            return 6",
      "        Option.some as payload:",
      "            if payload.value.len == 0:",
      "                return 7",
      "",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-lpcre2-8"
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-pcre2-runtime") do |dir|
      source_path = File.join(dir, "program.mt")
      File.write(source_path, source)
      return MilkTea::Run.run(source_path, cc: compiler)
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
