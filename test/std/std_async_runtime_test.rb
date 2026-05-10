# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdAsyncRuntimeTest < Minitest::Test
  def test_host_runtime_executes_async_await_with_timer_and_work_tasks
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_runtime",
      "",
      "import std.async as aio",
      "",
      "function compute_value() -> int:",
      "    return 7",
      "",
      "async function child() -> int:",
      "    return await aio.sleep(1) + await aio.work(compute_value) + 30",
      "",
      "async function main() -> int:",
      "    return await child() + await aio.work(compute_value)",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 44, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_async_main_without_explicit_runtime_import
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_main_no_import",
      "",
      "async function main() -> int:",
      "    return 42",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_async_main_with_void_result
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_main_void",
      "",
      "import std.async as aio",
      "",
      "async function main() -> void:",
      "    await aio.sleep(1)",
      "    await aio.sleep(1)",
      "    return",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_async_run_for_void_tasks
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_runtime_void",
      "",
      "import std.async as aio",
      "",
      "async function run_once() -> void:",
      "    await aio.sleep(1)",
      "    await aio.sleep(1)",
      "    return",
      "",
      "function main() -> int:",
      "    aio.run(run_once)",
      "    return 3",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 3, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_block_on_with_direct_function_root
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_direct_root",
      "",
      "import std.async as aio",
      "",
      "async function app() -> int:",
      "    return await aio.sleep(1) + 42",
      "",
      "function main() -> int:",
      "    return aio.block_on(app)",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_block_on_with_captured_root_closure
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_proc_root",
      "",
      "import std.async as aio",
      "",
      "async function child(bonus: int) -> int:",
      "    return await aio.sleep(1) + bonus",
      "",
      "function main() -> int:",
      "    let bonus = 42",
      "    let root = proc() -> Task[int]:",
      "        return child(bonus)",
      "    return aio.block_on(root)",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_generic_async_work_with_polling_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_runtime_generic_work",
      "",
      "import std.async as aio",
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
    assert_includes result.link_flags, "-luv"
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-async-runtime") do |dir|
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
