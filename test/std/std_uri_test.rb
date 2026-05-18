# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdUriTest < Minitest::Test
  def test_host_runtime_executes_file_uri_encode_decode_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "",
      "import std.str as text",
      "import std.uri as uri",
      "",
      "function main() -> int:",
      "    var posix_uri = uri.file_uri_from_path(\"/tmp/milk tea/main.mt\")",
      "    defer posix_uri.release()",
      "    if not posix_uri.as_str().equal(\"file:///tmp/milk%20tea/main.mt\"):",
      "        return 1",
      "",
      "    var windows_uri = uri.file_uri_from_path(\"C:\\\\milk tea\\\\main.mt\")",
      "    defer windows_uri.release()",
      "    if not windows_uri.as_str().equal(\"file://C%3A/milk%20tea/main.mt\"):",
      "        return 2",
      "",
      "    match uri.path_from_file_uri(\"file:///tmp/milk%20tea/main.mt\"):",
      "        Option.none:",
      "            return 3",
      "        Option.some as payload:",
      "            var decoded = payload.value",
      "            defer decoded.release()",
      "            if not decoded.as_str().equal(\"/tmp/milk tea/main.mt\"):",
      "                return 4",
      "",
      "    match uri.path_from_file_uri(\"file://C%3A/milk%20tea/main.mt\"):",
      "        Option.none:",
      "            return 5",
      "        Option.some as payload:",
      "            var decoded = payload.value",
      "            defer decoded.release()",
      "            if not decoded.as_str().equal(\"C:/milk tea/main.mt\"):",
      "                return 6",
      "",
      "    match uri.path_from_file_uri(\"file:///C:/milk%20tea/main.mt\"):",
      "        Option.none:",
      "            return 7",
      "        Option.some as payload:",
      "            var decoded = payload.value",
      "            defer decoded.release()",
      "            if not decoded.as_str().equal(\"C:/milk tea/main.mt\"):",
      "                return 8",
      "",
      "    match uri.path_from_file_uri(\"https://example.invalid/tmp/main.mt\"):",
      "        Option.none:",
      "            pass",
      "        Option.some as ignored_payload:",
      "            return 9",
      "    match uri.path_from_file_uri(\"file:///tmp/%ZZ\"):",
      "        Option.none:",
      "            pass",
      "        Option.some as ignored_payload:",
      "            return 10",
      "    match uri.path_from_file_uri(\"file:///tmp/%F0%28%8C%28\"):",
      "        Option.none:",
      "            pass",
      "        Option.some as ignored_payload:",
      "            return 11",
      "",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-uri") do |dir|
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
