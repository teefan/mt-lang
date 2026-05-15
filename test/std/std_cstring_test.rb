# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdCStringRuntimeTest < Minitest::Test
  def test_host_runtime_executes_cstring_and_memory_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-cstring") do |dir|
      source_path = File.join(dir, "std_cstring.mt")

      File.write(source_path, [
        "import std.cstring as cstring",
        "",
        "function main() -> int:",
        "    if cstring.length(\"milk\") != 4:",
        "        return 1",
        "    if cstring.compare(\"milk\", \"milk\") != 0:",
        "        return 2",
        "    if cstring.compare_prefix(\"milk-tea\", \"milk\", 4) != 0:",
        "        return 3",
        "    if cstring.find_char(\"milk\", 108) == null:",
        "        return 4",
        "    if cstring.find_last_char(\"level\", 108) == null:",
        "        return 5",
        "    if cstring.find_substring(\"milk tea\", \"tea\") == null:",
        "        return 6",
        "",
        "    var source = array[ubyte, 4](65, 66, 67, 68)",
        "    var target = zero[array[ubyte, 4]]",
        "    cstring.copy_bytes(unsafe: ptr[void]<-ptr_of(target[0]), unsafe: const_ptr[void]<-ptr_of(source[0]), 4)",
        "    if cstring.compare_bytes(unsafe: const_ptr[void]<-ptr_of(source[0]), unsafe: const_ptr[void]<-ptr_of(target[0]), 4) != 0:",
        "        return 7",
        "",
        "    cstring.set_bytes(unsafe: ptr[void]<-ptr_of(target[0]), 90, 2)",
        "    if target[0] != ubyte<-90 or target[1] != ubyte<-90:",
        "        return 8",
        "",
        "    var moved = array[ubyte, 6](1, 2, 3, 4, 5, 0)",
        "    cstring.move_bytes(unsafe: ptr[void]<-ptr_of(moved[1]), unsafe: const_ptr[void]<-ptr_of(moved[0]), 4)",
        "    if moved[1] != ubyte<-1 or moved[4] != ubyte<-4:",
        "        return 9",
        "    if cstring.find_byte(unsafe: const_ptr[void]<-ptr_of(target[0]), 67, 4) == null:",
        "        return 10",
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
