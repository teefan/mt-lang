# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdAsyncBlockingRuntimeTest < Minitest::Test
  def test_blocking_runtime_executes_async_await_without_extra_link_flags
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_blocking_runtime",
      "",
      "import std.async.blocking_runtime as aio",
      "",
      "function compute_value() -> int:",
      "    return 7",
      "",
      "async function child() -> int:",
      "    return await aio.sleep(1) + await aio.work(compute_value) + 30",
      "",
      "function main() -> int:",
      "    return aio.block_on(child)",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 37, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_blocking_runtime_supports_explicit_runtime_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_blocking_runtime_helpers",
      "",
      "import std.async.blocking_runtime as aio",
      "import std.status as status",
      "",
      "struct Pair:",
      "    left: int",
      "    right: int",
      "",
      "function make_pair() -> Pair:",
      "    return Pair(left = 18, right = 24)",
      "",
      "function main() -> int:",
      "    let runtime_result = aio.create_runtime()",
      "    if status.is_err(runtime_result):",
      "        return 1",
      "    match runtime_result:",
      "        status.Status.err:",
      "            return 1",
      "        status.Status.ok as payload:",
      "            var runtime = payload.value",
      "",
      "            let task = aio.work_on(runtime, make_pair)",
      "            while not aio.ready(task):",
      "                aio.pump(runtime)",
      "",
      "            let pair = aio.finish(task)",
      "            if aio.release_runtime(ref_of(runtime)) != 0:",
      "                return 2",
      "            return pair.left + pair.right",
      "    return 3",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-async-blocking-runtime") do |dir|
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
