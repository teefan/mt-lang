# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaRunTest < Minitest::Test
  def test_run_executes_built_program_and_preserves_requested_artifacts
    Dir.mktmpdir("milk-tea-run") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_script_compiler(dir, compiler_log, stdout: "hello\n", stderr: "warn\n", exit_status: 5)
      output_path = File.join(dir, "demo-run")
      c_path = File.join(dir, "demo-run.c")

      result = MilkTea::Run.run(demo_path, output_path:, cc: compiler_path, keep_c_path: c_path)

      assert_equal "hello\n", result.stdout
      assert_equal "warn\n", result.stderr
      assert_equal 5, result.exit_status
      assert_equal File.expand_path(output_path), result.output_path
      assert_equal File.expand_path(c_path), result.c_path
      assert_equal File.expand_path(compiler_path), result.compiler
      assert_includes result.link_flags, "-lraylib"
      assert File.exist?(output_path)
      assert File.exist?(c_path)
      assert_includes File.read(compiler_log).lines(chomp: true), "-lraylib"
    end
  end

  def test_run_executes_binary_from_source_directory_for_relative_assets
    Dir.mktmpdir("milk-tea-run-cwd") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = File.join(dir, "fake-run-cwd-cc")
      File.write(compiler_path, <<~SH)
        #!/bin/sh
        printf '%s\n' "$@" > #{compiler_log.inspect}
        output=''
        previous=''
        for argument in "$@"; do
          if [ "$previous" = '-o' ]; then
            output="$argument"
          fi
          previous="$argument"
        done
        cat > "$output" <<'SCRIPT'
        #!/bin/sh
        pwd
        SCRIPT
        chmod +x "$output"
      SH
      File.chmod(0o755, compiler_path)

      source_path = File.join(dir, "cwd.mt")
      File.write(source_path, [
        "module demo.cwd",
        "",
        "def main() -> i32:",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler_path)

      assert_equal "#{dir}\n", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler_path, result.compiler
      assert_equal [], result.link_flags
      assert_includes File.read(compiler_log).lines(chomp: true), "-o"
    end
  end

  def test_run_with_host_compiler_executes_real_binary
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-real") do |dir|
      source_path = File.join(dir, "smoke.mt")

      File.write(source_path, [
        "module demo.smoke",
        "",
        "def main() -> i32:",
        "    return 42",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 42, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_importing_std_math
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-std-math") do |dir|
      source_path = File.join(dir, "math-smoke.mt")

      File.write(source_path, [
        "module demo.math_smoke",
        "",
        "import std.math as math",
        "",
        "def main() -> i32:",
        "    let clamped = math.clamp(42, 0, 40)",
        "    if clamped == 40:",
        "        return math.max(6, 7)",
        "    return 1",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_mixed_numeric_binary_operations
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-numeric") do |dir|
      source_path = File.join(dir, "numeric.mt")

      File.write(source_path, [
        "module demo.numeric",
        "",
        "def main() -> i32:",
        "    let sum = 1 + 2.5",
        "    if 3 < 3.5 and sum > 3.0:",
        "        return 7",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_address_of_and_dereference
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-pointers") do |dir|
      source_path = File.join(dir, "pointers.mt")

      File.write(source_path, [
        "module demo.pointers",
        "",
        "struct Counter:",
        "    value: i32",
        "",
        "def main() -> i32:",
        "    var counter = Counter(value = 3)",
        "    let counter_ptr = raw(addr(counter))",
        "    var value = 0",
        "    unsafe:",
        "        value(counter_ptr).value = 7",
        "        value = value(counter_ptr).value",
        "    return value",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_safe_refs
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-refs") do |dir|
      source_path = File.join(dir, "refs.mt")

      File.write(source_path, [
        "module demo.refs_runtime",
        "",
        "struct Counter:",
        "    value: i32",
        "",
        "methods Counter:",
        "    edit def add(delta: i32):",
        "        this.value += delta",
        "",
        "def increment(counter: ref[Counter], amount: i32) -> void:",
        "    value(counter).add(amount)",
        "    value(counter).value += 1",
        "",
        "def main() -> i32:",
        "    var counter = Counter(value = 3)",
        "    let handle = addr(counter)",
        "    increment(handle, 4)",
        "    let value_ref = addr(value(handle).value)",
        "    value(value_ref) += 2",
        "    unsafe:",
        "        let raw_counter = raw(handle)",
        "        value(raw_counter).value += 1",
        "    return value(handle).value",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 11, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_explicit_value_for_by_value_parameters
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-explicit-value") do |dir|
      source_path = File.join(dir, "explicit-value.mt")

      File.write(source_path, [
        "module demo.explicit_value_args",
        "",
        "struct Counter:",
        "    value: i32",
        "",
        "def read(counter: Counter) -> i32:",
        "    return counter.value",
        "",
        "def main() -> i32:",
        "    var counter = Counter(value = 9)",
        "    let handle = addr(counter)",
        "    counter.value = 12",
        "    return read(value(handle))",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 12, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_spans
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-spans") do |dir|
      source_path = File.join(dir, "spans.mt")

      File.write(source_path, [
        "module demo.spans",
        "",
        "def read(items: span[i32]) -> i32:",
        "    if items.len == 0:",
        "        return 0",
        "    unsafe:",
        "        return value(items.data)",
        "",
        "def main() -> i32:",
        "    var value = 7",
        "    let items = span[i32](data = raw(addr(value)), len = 1)",
        "    return read(items)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_safe_span_indexing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-span-index") do |dir|
      source_path = File.join(dir, "span_index.mt")

      File.write(source_path, [
        "module demo.span_index_runtime",
        "",
        "def bump(mut items: span[i32]) -> i32:",
        "    let first = items[0]",
        "    items[0] = first + 2",
        "    return items[0]",
        "",
        "def main() -> i32:",
        "    var value = 7",
        "    let items = span[i32](data = raw(addr(value)), len = 1)",
        "    return bump(items)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 9, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_generic_structs
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-generics") do |dir|
      source_path = File.join(dir, "generics.mt")

      File.write(source_path, [
        "module demo.generics",
        "",
        "struct Slice[T]:",
        "    data: ptr[T]",
        "    len: usize",
        "",
        "struct Holder:",
        "    items: Slice[i32]",
        "",
        "def read(items: Slice[i32]) -> i32:",
        "    if items.len == 0:",
        "        return 0",
        "    unsafe:",
        "        return value(items.data)",
        "",
        "def main() -> i32:",
        "    var value = 7",
        "    let holder = Holder(items = Slice[i32](data = raw(addr(value)), len = 1))",
        "    return read(holder.items)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_generic_functions
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-generic-functions") do |dir|
      source_path = File.join(dir, "generic-functions.mt")

      File.write(source_path, [
        "module demo.generic_functions",
        "",
        "struct Slice[T]:",
        "    data: ptr[T]",
        "    len: usize",
        "",
        "def head[T](items: Slice[T]) -> ptr[T]:",
        "    return items.data",
        "",
        "def min[T](a: T, b: T) -> T:",
        "    if a < b:",
        "        return a",
        "    return b",
        "",
        "def main() -> i32:",
        "    var value = 7",
        "    let items = Slice[i32](data = raw(addr(value)), len = 1)",
        "    let smallest = min(9, 4)",
        "    unsafe:",
        "        return value(head(items)) + smallest",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 11, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_ref_arguments_for_by_value_parameters
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-ref-value-args") do |dir|
      source_path = File.join(dir, "ref-value-args.mt")

      File.write(source_path, [
        "module demo.ref_value_args",
        "",
        "struct Counter:",
        "    value: i32",
        "",
        "def read(counter: Counter) -> i32:",
        "    return counter.value",
        "",
        "def main() -> i32:",
        "    var counter = Counter(value = 9)",
        "    let handle = addr(counter)",
        "    counter.value = 12",
        "    return read(value(handle))",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 12, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_result_construction
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-result") do |dir|
      source_path = File.join(dir, "result.mt")

      File.write(source_path, [
        "module demo.result_runtime",
        "",
        "enum LoadError: u8",
        "    invalid_format = 1",
        "",
        "def load(available: bool) -> Result[i32, LoadError]:",
        "    if available:",
        "        return ok(7)",
        "    return err(LoadError.invalid_format)",
        "",
        "def main() -> i32:",
        "    let success = load(true)",
        "    let failure = load(false)",
        "    if success.is_ok and failure.error == LoadError.invalid_format:",
        "        return success.value + 1",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 8, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_builtin_panic
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-panic") do |dir|
      source_path = File.join(dir, "panic.mt")

      File.write(source_path, [
        "module demo.panic_runtime",
        "",
        "def main() -> i32:",
        "    panic(\"bad state\")",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_includes result.stderr, "bad state"
      assert_equal 134, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_enum_match
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-match") do |dir|
      source_path = File.join(dir, "match.mt")

      File.write(source_path, [
        "module demo.match_runtime",
        "",
        "enum EventKind: u8",
        "    quit = 1",
        "    resize = 2",
        "",
        "def dispatch(kind: EventKind) -> i32:",
        "    match kind:",
        "        EventKind.quit:",
        "            return 4",
        "        EventKind.resize:",
        "            return 7",
        "",
        "def main() -> i32:",
        "    return dispatch(EventKind.resize)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_for_loops
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-for") do |dir|
      source_path = File.join(dir, "for.mt")

      File.write(source_path, [
        "module demo.for_runtime",
        "",
        "def sum(items: array[i32, 4]) -> i32:",
        "    var total = 0",
        "    for item in items:",
        "        total += item",
        "    for i in range(0, 4):",
        "        total += i",
        "    return total",
        "",
        "def main() -> i32:",
        "    return sum(array[i32, 4](1, 2, 3, 4))",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 16, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_loop_control_in_match
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-loop-control") do |dir|
      source_path = File.join(dir, "loop_control.mt")

      File.write(source_path, [
        "module demo.loop_control_runtime",
        "",
        "enum Step: u8",
        "    skip = 1",
        "    keep = 2",
        "    stop = 3",
        "",
        "def add(target: ptr[i32], amount: i32) -> void:",
        "    unsafe:",
        "        value(target) += amount",
        "",
        "def main() -> i32:",
        "    var total = 0",
        "    for step in array[Step, 4](Step.keep, Step.skip, Step.keep, Step.stop):",
        "        defer add(raw(addr(total)), 1)",
        "        match step:",
        "            Step.skip:",
        "                continue",
        "            Step.keep:",
        "                total += 10",
        "            Step.stop:",
        "                break",
        "    return total",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 24, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_layout_queries_and_static_assert
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-layout") do |dir|
      source_path = File.join(dir, "layout.mt")

      File.write(source_path, [
        "module demo.layout_runtime",
        "",
        "struct Header:",
        "    magic: array[u8, 4]",
        "    version: u16",
        "",
        "static_assert(sizeof(Header) == 6, \"Header size should stay stable\")",
        "static_assert(offsetof(Header, version) == 4, \"Header.version offset drifted\")",
        "",
        "def main() -> i32:",
        "    return cast[i32](sizeof(Header) + alignof(Header) + offsetof(Header, version))",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 12, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_packed_and_aligned_structs
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-layout-modifiers") do |dir|
      source_path = File.join(dir, "layout_modifiers.mt")

      File.write(source_path, [
        "module demo.layout_modifiers_runtime",
        "",
        "packed struct Header:",
        "    tag: u8",
        "    value: u32",
        "",
        "align(16) struct Mat4:",
        "    data: array[f32, 16]",
        "",
        "static_assert(sizeof(Header) == 5, \"Header should stay packed\")",
        "static_assert(offsetof(Header, value) == 1, \"Header.value offset drifted\")",
        "static_assert(alignof(Mat4) == 16, \"Mat4 alignment drifted\")",
        "",
        "def main() -> i32:",
        "    return cast[i32](sizeof(Header) + offsetof(Header, value) + alignof(Mat4))",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 22, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_passing_real_str_values
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-str") do |dir|
      source_path = File.join(dir, "str_value.mt")

      File.write(source_path, [
        "module demo.str_runtime",
        "",
        "const greeting: str = \"hello\"",
        "",
        "def score(message: str) -> i32:",
        "    return 7",
        "",
        "def main() -> i32:",
        "    return score(greeting)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_unsafe_reinterpret
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-reinterpret") do |dir|
      source_path = File.join(dir, "reinterpret.mt")

      File.write(source_path, [
        "module demo.reinterpret_runtime",
        "",
        "def main() -> i32:",
        "    let value: f32 = 1.0",
        "    let expected: u32 = 1065353216",
        "    unsafe:",
        "        let bits = reinterpret[u32](value)",
        "        if bits != expected:",
        "            return 1",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_fixed_arrays
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-arrays") do |dir|
      source_path = File.join(dir, "arrays.mt")

      File.write(source_path, [
        "module demo.arrays",
        "",
        "struct Palette:",
        "    colors: array[u32, 4]",
        "",
        "def main() -> i32:",
        "    var palette = array[u32, 4](1, 2, 3, 4)",
        "    var holder = Palette(colors = array[u32, 4](5, 6, 7, 8))",
        "    unsafe:",
        "        if value(raw(addr(palette[0]))) != 1:",
        "            return 1",
        "        if value(raw(addr(holder.colors[0]))) != 5:",
        "            return 2",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_array_indexing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-array-indexing") do |dir|
      source_path = File.join(dir, "array-indexing.mt")

      File.write(source_path, [
        "module demo.array_indexing",
        "",
        "struct Palette:",
        "    colors: array[u32, 4]",
        "",
        "def main() -> i32:",
        "    var palette = array[u32, 4](1, 2, 3, 4)",
        "    var holder = Palette(colors = array[u32, 4](5, 6, 7, 8))",
        "    palette[1] = 9",
        "    holder.colors[2] = 10",
        "    if palette[0] != 1:",
        "        return 1",
        "    if palette[1] != 9:",
        "        return 2",
        "    if holder.colors[2] != 10:",
        "        return 3",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_traps_out_of_bounds_safe_array_indexing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-array-bounds") do |dir|
      source_path = File.join(dir, "array-bounds.mt")

      File.write(source_path, [
        "module demo.array_bounds",
        "",
        "def main() -> i32:",
        "    let palette = array[i32, 4](1, 2, 3, 4)",
        "    return palette[4]",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_includes result.stderr, "array index out of bounds"
      assert_equal 134, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_array_assignment_and_by_value_params
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-array-copy") do |dir|
      source_path = File.join(dir, "array-copy.mt")

      File.write(source_path, [
        "module demo.array_copy",
        "",
        "def mutate(mut values: array[i32, 4]) -> i32:",
        "    unsafe:",
        "        values[1] = 9",
        "        return values[1]",
        "",
        "def main() -> i32:",
        "    var lhs = array[i32, 4](1, 2, 3, 4)",
        "    let rhs = array[i32, 4](5, 6, 7, 8)",
        "    lhs = rhs",
        "    let changed = mutate(lhs)",
        "    if changed != 9:",
        "        return 1",
        "    unsafe:",
        "        if lhs[1] != 6:",
        "            return 2",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_zero_initialization
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-zero") do |dir|
      source_path = File.join(dir, "zero.mt")

      File.write(source_path, [
        "module demo.zero",
        "",
        "struct Palette:",
        "    colors: array[u32, 4]",
        "",
        "def main() -> i32:",
        "    let palette = zero[array[u32, 4]]()",
        "    let holder = zero[Palette]()",
        "    if palette[0] != 0:",
        "        return 1",
        "    if holder.colors[3] != 0:",
        "        return 2",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_local_array_returns
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-array-returns") do |dir|
      source_path = File.join(dir, "array-returns.mt")

      File.write(source_path, [
        "module demo.array_returns",
        "",
        "def make() -> array[i32, 4]:",
        "    return array[i32, 4](1, 2, 3, 4)",
        "",
        "def clone(values: array[i32, 4]) -> array[i32, 4]:",
        "    return values",
        "",
        "def read(values: array[i32, 4]) -> i32:",
        "    unsafe:",
        "        return values[1]",
        "",
        "def main() -> i32:",
        "    return read(clone(make()))",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 2, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  private

  def demo_path
    File.expand_path("../examples/milk-tea-demo.mt", __dir__)
  end

  def write_fake_script_compiler(dir, log_path, stdout:, stderr:, exit_status:)
    path = File.join(dir, "fake-run-cc")
    File.write(path, <<~SH)
      #!/bin/sh
      printf '%s\n' "$@" > #{log_path.inspect}
      output=''
      previous=''
      for argument in "$@"; do
        if [ "$previous" = '-o' ]; then
          output="$argument"
        fi
        previous="$argument"
      done
      cat > "$output" <<'SCRIPT'
      #!/bin/sh
      printf '%b' #{stdout.inspect}
      printf '%b' #{stderr.inspect} >&2
      exit #{exit_status}
      SCRIPT
      chmod +x "$output"
    SH
    File.chmod(0o755, path)
    path
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
