# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdPathTest < Minitest::Test
  def test_host_runtime_executes_deterministic_path_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "",
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
      "        Option.some as payload:",
      "            if not payload.value.equal(\".gz\"):",
      "                return 13",
      "        Option.none:",
      "            return 14",
      "",
      "    match path.extension(\".gitignore\"):",
      "        Option.none:",
      "            pass",
      "        Option.some as ignored_payload:",
      "            return 15",
      "",
      "    if not path.stem(\"archive.tar.gz\").equal(\"archive.tar\"):",
      "        return 16",
      "    if not path.stem(\".gitignore\").equal(\".gitignore\"):",
      "        return 17",
      "",
      "    match path.relative_path(\"/tmp/project/src/main.mt\", \"/tmp/project\"):",
      "        Option.some as payload:",
      "            var relative = payload.value",
      "            defer relative.release()",
      "            if not relative.as_str().equal(\"src/main.mt\"):",
      "                return 18",
      "        Option.none:",
      "            return 19",
      "",
      "    match path.relative_path(\"/tmp/project\", \"/tmp/project\"):",
      "        Option.some as payload:",
      "            var relative = payload.value",
      "            defer relative.release()",
      "            if not relative.as_str().equal(\".\"):",
      "                return 20",
      "        Option.none:",
      "            return 21",
      "",
      "    match path.relative_path(\"src/lib/../main.mt\", \"src/docs\"):",
      "        Option.some as payload:",
      "            var relative = payload.value",
      "            defer relative.release()",
      "            if not relative.as_str().equal(\"../main.mt\"):",
      "                return 22",
      "        Option.none:",
      "            return 23",
      "",
      "    match path.relative_path(\"c:/milk/tea/main.mt\", \"C:/milk\"):",
      "        Option.some as payload:",
      "            var relative = payload.value",
      "            defer relative.release()",
      "            if not relative.as_str().equal(\"tea/main.mt\"):",
      "                return 24",
      "        Option.none:",
      "            return 25",
      "",
      "    match path.relative_path(\"D:/milk/tea/main.mt\", \"C:/milk\"):",
      "        Option.none:",
      "            pass",
      "        Option.some as payload:",
      "            var relative = payload.value",
      "            defer relative.release()",
      "            return 26",
      "",
      "    if not path.is_within_root(\"/tmp/project/src/main.mt\", \"/tmp/project\"):",
      "        return 27",
      "    if not path.is_within_root(\"/tmp/project\", \"/tmp/project\"):",
      "        return 28",
      "    if path.is_within_root(\"/tmp/project-other/main.mt\", \"/tmp/project\"):",
      "        return 29",
      "    if not path.is_within_root(\"src/lib/main.mt\", \"src\"):",
      "        return 30",
      "    if path.is_within_root(\"src/../other/main.mt\", \"src\"):",
      "        return 31",
      "    if not path.is_within_root(\"C:/milk/tea/main.mt\", \"c:/milk\"):",
      "        return 32",
      "    if path.is_within_root(\"D:/milk/tea/main.mt\", \"C:/milk\"):",
      "        return 33",
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
