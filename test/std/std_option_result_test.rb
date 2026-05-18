# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaBuiltinOptionResultTest < Minitest::Test
  def test_host_runtime_executes_builtin_option_and_result_variants
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "function option_score(value: Option[int]) -> int:",
      "    match value:",
      "        Option.none:",
      "            return 1",
      "        Option.some as payload:",
      "            return payload.value",
      "    return 1",
      "",
      "function result_score(value: Result[int, int]) -> int:",
      "    match value:",
      "        Result.failure as payload:",
      "            return payload.error",
      "        Result.success as payload:",
      "            return payload.value",
      "    return 0",
      "",
      "function unwrap_option(value: Option[int]) -> int:",
      "    let unwrapped = value else:",
      "        return 7",
      "    return unwrapped",
      "",
      "function unwrap_result(value: Result[int, int]) -> int:",
      "    let unwrapped = value else as error:",
      "        return error",
      "    return unwrapped",
      "",
      "function main() -> int:",
      "    let empty: Option[int] = Option[int].none",
      "    let seeded: Option[int] = Option[int].some(value= 40)",
      "    let ok_value: Result[int, int] = Result[int, int].success(value= 2)",
      "    let err_value: Result[int, int] = Result[int, int].failure(error= 3)",
      "    if unwrap_option(empty) != 7:",
      "        return 100",
      "    if unwrap_option(seeded) != 40:",
      "        return 101",
      "    if option_score(empty) != 1:",
      "        return 102",
      "    if option_score(seeded) != 40:",
      "        return 103",
      "    if unwrap_result(ok_value) != 2:",
      "        return 104",
      "    if unwrap_result(err_value) != 3:",
      "        return 105",
      "    match seeded:",
      "        Option.none:",
      "            return 106",
      "        Option.some as payload:",
      "            return payload.value + result_score(ok_value) + result_score(err_value)",
      "    return 106",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 45, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-builtin-option-result") do |dir|
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
