# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdRandomTest < Minitest::Test
  def test_deterministic_output_from_seed
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.random as rng

function main() -> int:
    var a = rng.from_seed(42)
    var b = rng.from_seed(42)

    var i: ptr_uint = 0
    while i < ptr_uint<-10:
        if a.next_u32() != b.next_u32():
            return 1
        i += 1
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_different_seeds_produce_different_output
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.random as rng

function main() -> int:
    var a = rng.from_seed(1)
    var b = rng.from_seed(999)

    var diff: bool = false
    var i: ptr_uint = 0
    while i < ptr_uint<-10:
        if a.next_u32() != b.next_u32():
            diff = true
            break
        i += 1
    if not diff:
        return 1
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_fork_produces_independent_streams
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.random as rng

function main() -> int:
    var parent = rng.from_seed(12345)
    var child = parent.fork()

    var all_different: bool = true
    var i: ptr_uint = 0
    while i < ptr_uint<-10:
        if parent.next_u32() == child.next_u32():
            all_different = false
            break
        i += 1
    if all_different:
        return 0
    return 1

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_next_f64_in_range
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.random as rng

function main() -> int:
    var r = rng.from_seed(7)
    var i: ptr_uint = 0
    while i < ptr_uint<-100:
        let val = r.next_f64()
        if val < 0.0 or val >= 1.0:
            return 1
        i += 1
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_next_bool_produces_both_values
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.random as rng

function main() -> int:
    var r = rng.from_seed(100)
    var found_true: bool = false
    var found_false: bool = false
    var i: ptr_uint = 0
    while i < ptr_uint<-50:
        if r.next_bool():
            found_true = true
        else:
            found_false = true
        i += 1
    if found_true and found_false:
        return 0
    return 1

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_next_uint_range_in_bounds
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.random as rng

function main() -> int:
    var r = rng.from_seed(99)
    var i: ptr_uint = 0
    while i < ptr_uint<-200:
        let val = r.next_uint_range(10, 20)
        if val < 10 or val >= 20:
            return 1
        i += 1
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_next_int_range_in_bounds
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.random as rng

function main() -> int:
    var r = rng.from_seed(77)
    var i: ptr_uint = 0
    while i < ptr_uint<-200:
        let val = r.next_int_range(-5, 5)
        if val < -5 or val >= 5:
            return 1
        i += 1
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_from_seed_str_is_deterministic
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.random as rng

function main() -> int:
    var a = rng.from_seed_str("hello")
    var b = rng.from_seed_str("hello")
    var i: ptr_uint = 0
    while i < ptr_uint<-5:
        if a.next_u32() != b.next_u32():
            return 1
        i += 1
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_shuffle_preserves_all_elements
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.random as rng
import std.vec as vec

function main() -> int:
    var r = rng.from_seed(55)
    var list = vec.Vec[uint].create()
    var k: uint = 0
    while k < 10:
        list.push(k)
        k += 1

    r.shuffle(ref_of(list))

    var counts = zero[array[uint, 10]]
    var i: ptr_uint = 0
    while i < list.len():
        let ptr = list.get(i) else:
            return 1
        let val = unsafe: read(ptr)
        if val >= 10:
            return 2
        counts[val] += 1
        i += 1

    var j: ptr_uint = 0
    while j < ptr_uint<-10:
        if counts[j] != 1:
            return 3
        j += 1
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_skip_changes_output
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.random as rng

function main() -> int:
    var a = rng.from_seed(42)
    a.skip(3)
    var b = rng.from_seed(42)
    var i: ptr_uint = 0
    while i < ptr_uint<-3:
        b.next_u32()
        i += 1
    if a.next_u32() == b.next_u32():
        return 0
    return 1

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_chance_always_true_with_one
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.random as rng

function main() -> int:
    var r = rng.from_seed(42)
    var i: ptr_uint = 0
    while i < ptr_uint<-10:
        if not r.chance(1.0):
            return 1
        i += 1
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_pick_returns_element_from_vec
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.random as rng
import std.vec as vec

function main() -> int:
    var r = rng.from_seed(99)
    var list = vec.Vec[uint].create()
    var k: uint = 0
    while k < 5:
        list.push(k + 10)
        k += 1

    let result = r.pick(ref_of(list))
    match result:
        Option.none:
            return 1
        Option.some as sp:
            let val = sp.value
            if val < 10 or val > 14:
                return 2
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-random") do |dir|
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
