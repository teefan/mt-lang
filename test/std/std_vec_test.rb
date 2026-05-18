# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdVecTest < Minitest::Test
  def test_host_runtime_executes_vec_storage_methods
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "",
      "import std.vec as vec",
      "",
      "function sum(values: span[int]) -> int:",
      "    var total = 0",
      "    var index: ptr_uint = 0",
      "    while index < values.len:",
      "        unsafe:",
      "            total += read(values.data + index)",
      "        index += 1",
      "    return total",
      "",
      "function main() -> int:",
      "    var values = vec.Vec[int].with_capacity(1)",
      "    defer values.release()",
      "    if values.capacity() < 1:",
      "        return 1",
      "    if not values.is_empty():",
      "        return 2",
      "    if values.as_span().len != 0:",
      "        return 3",
      "",
      "    values.push(7)",
      "    values.push(8)",
      "    values.push(9)",
      "    if values.len() != 3:",
      "        return 4",
      "    if values.capacity() < 3:",
      "        return 5",
      "    if sum(values.as_span()) != 24:",
      "        return 6",
      "",
      "    let popped = values.pop()",
      "    match popped:",
      "        Option.none:",
      "            return 7",
      "        Option.some as payload:",
      "            if payload.value != 9:",
      "                return 8",
      "",
      "    if values.len() != 2:",
      "        return 9",
      "    values.clear()",
      "    if not values.is_empty():",
      "        return 10",
      "    if values.capacity() < 3:",
      "        return 11",
      "",
      "    let empty = values.pop()",
      "    match empty:",
      "        Option.none:",
      "            return 0",
      "        Option.some as ignored_payload:",
      "            return 12",
      "    return 13",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_vec_with_plain_struct_elements
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "",
      "import std.vec as vec",
      "",
      "struct Pair:",
      "    left: int",
      "    right: int",
      "",
      "function main() -> int:",
      "    var pairs = vec.Vec[Pair].create()",
      "    defer pairs.release()",
      "    pairs.reserve(2)",
      "    pairs.push(Pair(left = 3, right = 4))",
      "    pairs.push(Pair(left = 5, right = 6))",
      "    let current = pairs.as_span()",
      "    if current.len != 2:",
      "        return 1",
      "",
      "    let removed = pairs.pop()",
      "    match removed:",
      "        Option.none:",
      "            return 2",
      "        Option.some as payload:",
      "            if payload.value.left != 5 or payload.value.right != 6:",
      "                return 3",
      "",
      "    let remaining = pairs.as_span()",
      "    if remaining.len != 1:",
      "        return 4",
      "    unsafe:",
      "        let first = read(remaining.data)",
      "        return first.left + first.right",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 7, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_vec_append_span_and_self_append_on_growth
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.vec as vec",
      "",
      "function main() -> int:",
      "    var values = vec.Vec[int].with_capacity(2)",
      "    defer values.release()",
      "    var seed = array[int, 2](3, 4)",
      "    values.append_span(span[int](data = ptr_of(seed[0]), len = 2))",
      "    if values.len() != 2:",
      "        return 1",
      "",
      "    let existing = values.as_span()",
      "    values.append_span(existing)",
      "    if values.len() != 4:",
      "        return 2",
      "    if values.capacity() < 4:",
      "        return 3",
      "",
      "    let all = values.as_span()",
      "    unsafe:",
      "        if read(all.data + 0) != 3 or read(all.data + 1) != 4 or read(all.data + 2) != 3 or read(all.data + 3) != 4:",
      "            return 4",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_vec_append_array_wrapper
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.vec as vec",
      "",
      "function main() -> int:",
      "    var values = vec.Vec[int].create()",
      "    defer values.release()",
      "    values.append_array(array[int, 3](10, 20, 30))",
      "    let view = values.as_span()",
      "    if view.len != 3:",
      "        return 1",
      "    unsafe:",
      "        if read(view.data + 0) != 10 or read(view.data + 1) != 20 or read(view.data + 2) != 30:",
      "            return 2",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_vec_pointer_accessors
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.vec as vec",
      "",
      "function main() -> int:",
      "    var values = vec.Vec[int].create()",
      "    defer values.release()",
      "    values.push(10)",
      "    values.push(20)",
      "    values.push(30)",
      "",
      "    let first = values.first()",
      "    let middle = values.get(1)",
      "    let last = values.last()",
      "    if first == null or middle == null or last == null:",
      "        return 1",
      "",
      "    unsafe:",
      "        if read(ptr[int]<-first) != 10:",
      "            return 2",
      "        if read(ptr[int]<-last) != 30:",
      "            return 3",
      "        read(ptr[int]<-middle) = 25",
      "",
      "    let view = values.as_span()",
      "    unsafe:",
      "        if read(view.data + 1) != 25:",
      "            return 4",
      "",
      "    if values.get(9) != null:",
      "        return 5",
      "    if values.first() == null:",
      "        return 6",
      "    if values.last() == null:",
      "        return 7",
      "",
      "    values.clear()",
      "    if values.first() != null or values.last() != null:",
      "        return 8",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_vec_search_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.vec as vec",
      "",
      "function main() -> int:",
      "    var values = vec.Vec[int].create()",
      "    defer values.release()",
      "    values.push(10)",
      "    values.push(20)",
      "    values.push(30)",
      "    values.push(40)",
      "",
      "    let equals_thirty = proc(value: ptr[int]) -> bool:",
      "        unsafe:",
      "            return read(value) == 30",
      "    let found = values.find(equals_thirty)",
      "    if found == null:",
      "        return 1",
      "    unsafe:",
      "        if read(ptr[int]<-found) != 30:",
      "            return 2",
      "",
      "    if values.find(proc(value: ptr[int]) -> bool: unsafe: read(value) == 99) != null:",
      "        return 3",
      "",
      "    match values.find_index(proc(value: ptr[int]) -> bool: unsafe: read(value) == 20):",
      "        Option.none:",
      "            return 4",
      "        Option.some as payload:",
      "            if payload.value != ptr_uint<-1:",
      "                return 5",
      "",
      "    match values.find_index(proc(value: ptr[int]) -> bool: unsafe: read(value) == 99):",
      "        Option.none:",
      "            pass",
      "        Option.some as ignored_payload:",
      "            return 6",
      "",
      "    let threshold = 25",
      "    var any_iter = values.iter()",
      "    if not any_iter.any(proc(value: ptr[int]) -> bool: unsafe: read(value) > threshold):",
      "        return 7",
      "",
      "    var all_iter = values.iter()",
      "    if not all_iter.all(proc(value: ptr[int]) -> bool: unsafe: read(value) % 10 == 0):",
      "        return 8",
      "",
      "    var count_iter = values.iter()",
      "    if count_iter.count(proc(value: ptr[int]) -> bool: unsafe: read(value) >= 20) != ptr_uint<-3:",
      "        return 9",
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

  def test_host_runtime_executes_vec_insert_and_remove
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "",
      "import std.vec as vec",
      "",
      "function main() -> int:",
      "    var values = vec.Vec[int].create()",
      "    defer values.release()",
      "",
      "    if values.insert(1, 50):",
      "        return 1",
      "    if not values.insert(0, 10):",
      "        return 2",
      "    if not values.insert(1, 30):",
      "        return 3",
      "    if not values.insert(1, 20):",
      "        return 4",
      "    if not values.insert(3, 40):",
      "        return 5",
      "",
      "    let initial = values.as_span()",
      "    if initial.len != 4:",
      "        return 6",
      "    unsafe:",
      "        if read(initial.data + 0) != 10 or read(initial.data + 1) != 20 or read(initial.data + 2) != 30 or read(initial.data + 3) != 40:",
      "            return 7",
      "",
      "    let removed = values.remove(1)",
      "    match removed:",
      "        Option.none:",
      "            return 8",
      "        Option.some as payload:",
      "            if payload.value != 20:",
      "                return 9",
      "",
      "    let shifted = values.as_span()",
      "    if shifted.len != 3:",
      "        return 10",
      "    unsafe:",
      "        if read(shifted.data + 0) != 10 or read(shifted.data + 1) != 30 or read(shifted.data + 2) != 40:",
      "            return 11",
      "",
      "    let tail = values.remove(2)",
      "    match tail:",
      "        Option.none:",
      "            return 12",
      "        Option.some as payload:",
      "            if payload.value != 40:",
      "                return 13",
      "",
      "    let missing = values.remove(5)",
      "    match missing:",
      "        Option.none:",
      "            return 0",
      "        Option.some as ignored_payload:",
      "            return 14",
      "    return 15",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_vec_swap_remove
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "",
      "import std.vec as vec",
      "",
      "function main() -> int:",
      "    var values = vec.Vec[int].create()",
      "    defer values.release()",
      "    values.push(10)",
      "    values.push(20)",
      "    values.push(30)",
      "",
      "    let removed = values.swap_remove(1)",
      "    match removed:",
      "        Option.none:",
      "            return 1",
      "        Option.some as payload:",
      "            if payload.value != 20:",
      "                return 2",
      "",
      "    let view = values.as_span()",
      "    if view.len != 2:",
      "        return 3",
      "    unsafe:",
      "        if read(view.data + 0) != 10 or read(view.data + 1) != 30:",
      "            return 4",
      "",
      "    let missing = values.swap_remove(5)",
      "    match missing:",
      "        Option.none:",
      "            return 0",
      "        Option.some as ignored_payload:",
      "            return 5",
      "    return 6",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_vec_iter_surface
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.vec as vec",
      "",
      "function main() -> int:",
      "    var values = vec.Vec[int].create()",
      "    defer values.release()",
      "    values.push(10)",
      "    values.push(20)",
      "    values.push(30)",
      "",
      "    var iter = values.iter()",
      "    let first = iter.next()",
      "    let second = iter.next()",
      "    let third = iter.next()",
      "    if first == null or second == null or third == null:",
      "        return 1",
      "    unsafe:",
      "        read(ptr[int]<-second) = 25",
      "",
      "    var total = 0",
      "    for value in values:",
      "        unsafe:",
      "            total += read(value)",
      "",
      "    if total != 65:",
      "        return 2",
      "    if iter.next() != null:",
      "        return 3",
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
    Dir.mktmpdir("milk-tea-std-vec") do |dir|
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
