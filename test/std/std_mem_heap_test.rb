# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMemHeapTest < Minitest::Test
  def test_host_runtime_executes_heap_allocation_wrappers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.mem.heap as heap

function main() -> int:
    let bytes = heap.alloc[ubyte](16)
    let grown = heap.resize(bytes, 32)
    let zeroed = heap.alloc_zeroed[bool](4)
    let raw = heap.alloc_bytes(8)
    let raw_grown = heap.resize_bytes(raw, 16)
    heap.release(grown)
    heap.release(zeroed)
    heap.release_bytes(raw_grown)
    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_heap_contract_edges
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.mem.heap as heap

@[align(16)]
struct Mat4:
    data: array[float, 16]

function main() -> int:
    if heap.alloc_bytes(0) != null:
        return 1
    if heap.alloc_zeroed_bytes(0, 4) != null:
        return 2

    let raw = heap.alloc_bytes(8)
    if raw == null:
        return 3
    let released = heap.resize_bytes(raw, 0)
    if released != null:
        return 4

    let aligned = heap.alloc_bytes_aligned(1, 16)
    if aligned == null:
        return 5
    heap.release_bytes(aligned)

    let matrix = heap.alloc_aligned[Mat4](1)
    if matrix == null:
        return 6
    heap.release(matrix)

    if heap.alloc[Mat4](1) != null:
        return 7

    var source = array[ubyte, 3](ubyte<-10, ubyte<-20, ubyte<-30)
    let copied = heap.must_alloc[ubyte](3)
    heap.copy_bytes(copied, ptr_of(source[0]), 3)
    unsafe:
        if read(copied + 0) != ubyte<-10 or read(copied + 1) != ubyte<-20 or read(copied + 2) != ubyte<-30:
            return 8
    heap.release(copied)

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_rejects_heap_generic_must_alloc_zero_count
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    assert_contract_failure(<<~MT, /heap\.must_alloc requires count > 0/, compiler:)

      import std.mem.heap as heap

      function main() -> int:
          let _ = heap.must_alloc[int](0)
          return 0

    MT
  end

  def test_host_runtime_rejects_heap_generic_must_alloc_aligned_zero_count
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    assert_contract_failure(<<~MT, /heap\.must_alloc_aligned requires count > 0/, compiler:)

      import std.mem.heap as heap

      function main() -> int:
          let _ = heap.must_alloc_aligned[int](0)
          return 0

    MT
  end

  def test_host_runtime_rejects_heap_generic_must_alloc_zeroed_zero_count
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    assert_contract_failure(<<~MT, /heap\.must_alloc_zeroed requires count > 0/, compiler:)

      import std.mem.heap as heap

      function main() -> int:
          let _ = heap.must_alloc_zeroed[int](0)
          return 0

    MT
  end

  def test_host_runtime_rejects_heap_generic_must_resize_zero_count
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    assert_contract_failure(<<~MT, /heap\.must_resize requires count > 0/, compiler:)

      import std.mem.heap as heap

      function main() -> int:
          let bytes = heap.must_alloc[int](1)
          defer heap.release(bytes)
          let _ = heap.must_resize(bytes, 0)
          return 0

    MT
  end

  def test_host_runtime_rejects_heap_generic_must_alloc_size_overflow
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    assert_contract_failure(<<~MT, /heap\.must_alloc size overflow/, compiler:)

      import std.mem.heap as heap

      function main() -> int:
          let _ = heap.must_alloc[long](heap.ptr_uint_max)
          return 0

    MT
  end

  private

  def assert_contract_failure(source, stderr_pattern, compiler:)
    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal 134, result.exit_status
    assert_match(stderr_pattern, result.stderr)
    assert_equal [], result.link_flags
  end

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-mem-heap") do |dir|
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
