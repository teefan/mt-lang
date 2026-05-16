# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdPathTest < Minitest::Test
  def test_host_runtime_executes_deterministic_path_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.maybe as maybe",
      "import std.path as path",
      "import std.str as text",
      "",
      "function main() -> int:",
      "    if not path.is_absolute(\"/tmp/project\"):",
      "        return 1",
      "    if not path.is_absolute(\"C:/tmp/project\"):",
      "        return 2",
      "    if path.is_absolute(\"tmp/project\"):",
      "        return 3",
      "",
      "    var joined = path.join(\"tmp\", \"milk/program.mt\")",
      "    defer joined.release()",
      "    if not joined.as_str().equal(\"tmp/milk/program.mt\"):",
      "        return 4",
      "",
      "    var absolute_join = path.join(\"tmp\", \"/etc/passwd\")",
      "    defer absolute_join.release()",
      "    if not absolute_join.as_str().equal(\"/etc/passwd\"):",
      "        return 5",
      "",
      "    var normalized = path.normalize_separators(\"C:\\\\milk\\\\tea\\\\main.mt\")",
      "    defer normalized.release()",
      "    if not normalized.as_str().equal(\"C:/milk/tea/main.mt\"):",
      "        return 6",
      "",
      "    if not path.basename(\"src/main.mt\").equal(\"main.mt\"):",
      "        return 7",
      "    if not path.basename(\"C:/milk/tea/\").equal(\"tea\"):",
      "        return 8",
      "",
      "    if not path.dirname(\"src/main.mt\").equal(\"src\"):",
      "        return 9",
      "    if not path.dirname(\"main.mt\").equal(\".\"):",
      "        return 10",
      "    if not path.dirname(\"/main.mt\").equal(\"/\"):",
      "        return 11",
      "    if not path.dirname(\"C:/milk/tea/main.mt\").equal(\"C:/milk/tea\"):",
      "        return 12",
      "",
      "    match path.extension(\"archive.tar.gz\"):",
      "        maybe.Maybe.some as payload:",
      "            if not payload.value.equal(\".gz\"):",
      "                return 13",
      "        maybe.Maybe.none:",
      "            return 14",
      "",
      "    if not maybe.is_none(path.extension(\".gitignore\")):",
      "        return 15",
      "",
      "    if not path.stem(\"archive.tar.gz\").equal(\"archive.tar\"):",
      "        return 16",
      "    if not path.stem(\".gitignore\").equal(\".gitignore\"):",
      "        return 17",
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
    Dir.mktmpdir("milk-tea-std-path") do |dir|
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
