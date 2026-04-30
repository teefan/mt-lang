# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdLibuvAsyncTest < Minitest::Test
  def test_host_runtime_executes_async_await_with_timer_and_work_tasks
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_libuv_async",
      "",
      "import std.async as async",
      "",
      "def compute_value() -> i32:",
      "    return 7",
      "",
      "async def child() -> i32:",
      "    return await async.sleep(1) + await async.work(compute_value) + 30",
      "",
      "async def main() -> i32:",
      "    return await child() + await async.work(compute_value)",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 44, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_host_runtime_executes_async_main_with_void_result
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_async_main_void",
      "",
      "import std.async as async",
      "",
      "async def main() -> void:",
      "    await async.sleep(1)",
      "    await async.sleep(1)",
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
      "module demo.std_libuv_async_void",
      "",
      "import std.async as async",
      "",
      "async def run_once() -> void:",
      "    await async.sleep(1)",
      "    await async.sleep(1)",
      "    return",
      "",
      "def main() -> i32:",
      "    async.run(run_once)",
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
      "import std.async as async",
      "",
      "async def app() -> i32:",
      "    return await async.sleep(1) + 42",
      "",
      "def main() -> i32:",
      "    return async.block_on(app)",
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
      "import std.async as async",
      "",
      "async def child(bonus: i32) -> i32:",
      "    return await async.sleep(1) + bonus",
      "",
      "def main() -> i32:",
      "    let bonus = 42",
      "    let root = proc() -> Task[i32]:",
      "        return child(bonus)",
      "    return async.block_on(root)",
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
      "module demo.std_libuv_async_generic_work",
      "",
      "import std.async as async",
      "import std.libuv.runtime as rt",
      "",
      "struct Pair:",
      "    left: i32",
      "    right: i32",
      "",
      "def make_pair() -> Pair:",
      "    return Pair(left = 18, right = 24)",
      "",
      "def main() -> i32:",
      "    let loop_result = rt.create_loop()",
      "    if not loop_result.is_ok:",
      "        return 1",
      "    var loop = loop_result.value",
      "",
      "    let task = async.work_on(loop, make_pair)",
      "    while not async.ready(task):",
      "        async.pump(loop)",
      "",
      "    let pair = async.finish(task)",
      "    if rt.loop_release(addr(loop)) != 0:",
      "        return 2",
      "    return pair.left + pair.right",
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
    Dir.mktmpdir("milk-tea-std-libuv-async") do |dir|
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
