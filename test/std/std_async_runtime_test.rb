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
      "    aio.run(run_once())",
      "    return 3",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 3, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_wait_with_direct_function_root
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
      "    return aio.wait(app)",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_wait_with_direct_task_expression_and_captured_values
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_direct_task_root",
      "",
      "import std.async as aio",
      "",
      "async function child(bonus: int) -> int:",
      "    return await aio.sleep(1) + bonus",
      "",
      "function main() -> int:",
      "    let bonus = 42",
      "    return aio.wait(child(bonus))",
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
      "",
      "struct Pair:",
      "    left: int",
      "    right: int",
      "",
      "function make_pair() -> Pair:",
      "    return Pair(left = 18, right = 24)",
      "",
      "function run_with_runtime(runtime: aio.Runtime) -> int:",
      "    let task = aio.work_on(runtime, make_pair)",
      "    while not aio.completed(task):",
      "        aio.pump(runtime)",
      "",
      "    let pair = aio.result(task)",
      "    return pair.left + pair.right",
      "",
      "function main() -> int:",
      "    return aio.with_runtime(run_with_runtime)",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_defer_cleanup_in_async_functions
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_defer",
      "",
      "import std.async as aio",
      "",
      "async function main() -> int:",
      "    var total = 0",
      "    if true:",
      "        defer:",
      "            total += 2",
      "        await aio.sleep(1)",
      "        total += 40",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_await_in_async_defer_cleanup
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_defer_await",
      "",
      "import std.async as aio",
      "",
      "async function main() -> int:",
      "    var total = 0",
      "    if true:",
      "        defer:",
      "            total += await aio.sleep(1)",
      "            total += 2",
      "        total += 40",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_let_else_in_async_functions
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_let_else",
      "",
      "import std.async as aio",
      "",
      "async function maybe_value(flag: bool, handle: ptr[int]?) -> ptr[int]?:",
      "    await aio.sleep(1)",
      "    if flag:",
      "        return handle",
      "    return null[ptr[int]]",
      "",
      "async function main() -> int:",
      "    var value = 42",
      "    let handle = unsafe: ptr_of(value)",
      "    let first = await maybe_value(false, handle) else:",
      "        let second = await maybe_value(true, handle) else:",
      "            return 1",
      "        unsafe:",
      "            return read(second)",
      "    unsafe:",
      "        return read(first)",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_awaited_compound_assignment_in_async_for_body
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_for_body_await",
      "",
      "import std.async as aio",
      "",
      "async function tick() -> int:",
      "    return 1",
      "",
      "async function main() -> int:",
      "    let items = array[int, 3](10, 20, 30)",
      "    var total = 0",
      "    for item in items:",
      "        total += await tick()",
      "        total += item",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 63, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_suspending_async_collection_for_body
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_for_body_suspend",
      "",
      "import std.async as aio",
      "",
      "async function main() -> int:",
      "    let items = array[int, 3](10, 20, 30)",
      "    var total = 0",
      "    for item in items:",
      "        total += await aio.sleep(1)",
      "        total += item",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 60, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_suspending_async_parallel_collection_for_body
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_parallel_for_body_suspend",
      "",
      "import std.async as aio",
      "",
      "async function main() -> int:",
      "    let lefts = array[int, 3](10, 20, 30)",
      "    let rights = array[int, 3](1, 2, 3)",
      "    var total = 0",
      "    for left, right in lefts, rights:",
      "        total += await aio.sleep(1)",
      "        total += left + right",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 66, result.exit_status
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
