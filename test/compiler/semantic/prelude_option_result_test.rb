# frozen_string_literal: true

require "tmpdir"
require_relative "../../test_helper"

class PreludeOptionResultTest < Minitest::Test
  def test_option_definition_compiles_and_works
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
function main() -> int:
    let opt: Option[int] = Option[int].some(value= 42)
    match opt:
        Option.some as s:
            return s.value
        Option.none:
            return -1
    return -1
    MT

    result = run_program(source, compiler:)
    assert_equal 42, result.exit_status
  end

  def test_result_construction_and_match
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
function main() -> int:
    let ok_val: Result[int, int] = Result[int, int].success(value= 7)
    match ok_val:
        Result.success as s:
            return s.value
        Result.failure as f:
            return f.error
    return -1
    MT

    result = run_program(source, compiler:)
    assert_equal 7, result.exit_status
  end

  def test_let_else_option
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
function main() -> int:
    let some_val: Option[int] = Option[int].some(value= 99)
    let value = some_val else:
        return -1
    return value
    MT

    result = run_program(source, compiler:)
    assert_equal 99, result.exit_status
  end

  def test_let_else_result_with_error_binding
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
function main() -> int:
    let ok_val: Result[int, int] = Result[int, int].success(value= 55)
    let value = ok_val else as error:
        return error
    return value
    MT

    result = run_program(source, compiler:)
    assert_equal 55, result.exit_status
  end

  def test_question_mark_propagation_option
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
function inner(flag: bool) -> Option[int]:
    if flag:
        return Option[int].some(value= 88)
    return Option[int].none

function compute(flag: bool) -> Option[int]:
    let value = inner(flag)?
    return Option[int].some(value= value)

function main() -> int:
    let result = compute(true) else:
        return -1
    return result
    MT

    result = run_program(source, compiler:)
    assert_equal 88, result.exit_status
  end

  def test_question_mark_propagation_result
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
function parse() -> Result[int, int]:
    return Result[int, int].success(value= 33)

function compute() -> Result[int, int]:
    let value = parse()?
    return Result[int, int].success(value= value)

function main() -> int:
    let result = compute() else as error:
        return error
    return result
    MT

    result = run_program(source, compiler:)
    assert_equal 33, result.exit_status
  end

  def test_option_none_let_else_returns_early
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
function main() -> int:
    let empty: Option[int] = Option[int].none
    let value = empty else:
        return 77
    return value
    MT

    result = run_program(source, compiler:)
    assert_equal 77, result.exit_status
  end

  def test_option_extending_methods
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
function main() -> int:
    let opt: Option[int] = Option[int].some(value= 42)
    if not opt.is_some():
        return -1
    if opt.is_none():
        return -2
    if opt.unwrap() != 42:
        return -3
    if opt.unwrap_or(99) != 42:
        return -4
    let empty: Option[int] = Option[int].none
    if empty.is_some():
        return -5
    if not empty.is_none():
        return -6
    if empty.unwrap_or(77) != 77:
        return -7
    return 0
    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_result_extending_methods
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
function main() -> int:
    let ok_val: Result[int, int] = Result[int, int].success(value= 7)
    if not ok_val.is_success():
        return -1
    if ok_val.is_failure():
        return -2
    if ok_val.unwrap() != 7:
        return -3
    if ok_val.unwrap_or(99) != 7:
        return -4
    let err_val: Result[int, int] = Result[int, int].failure(error= 13)
    if err_val.is_success():
        return -5
    if not err_val.is_failure():
        return -6
    if err_val.unwrap_error() != 13:
        return -7
    if err_val.unwrap_or(77) != 77:
        return -8
    return 0
    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_result_failure_let_else_as_error
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
function main() -> int:
    let err_val: Result[int, int] = Result[int, int].failure(error= 99)
    let value = err_val else as error:
        return error
    return value
    MT

    result = run_program(source, compiler:)
    assert_equal 99, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-prelude-option") do |dir|
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
