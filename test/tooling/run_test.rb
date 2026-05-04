# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

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
        "    let counter_ptr = ptr_of(counter)",
        "    var value = 0",
        "    unsafe:",
        "        counter_ptr.value = 7",
        "        value = counter_ptr.value",
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

  def test_run_with_host_compiler_executes_program_using_integer_to_char_buffer_writes
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-char-buffer") do |dir|
      source_path = File.join(dir, "char-buffer.mt")

      File.write(source_path, [
        "module demo.char_buffer_runtime",
        "",
        "def main() -> i32:",
        "    let first = 65",
        "    var buffer = zero[array[char, 4]]",
        "    unsafe:",
        "        var raw_buffer = ptr_of(buffer[0])",
        "        raw_buffer[0] = first",
        "        raw_buffer[1] = char<-66",
        "    return i32<-buffer[0] + i32<-buffer[1] - 131",
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
        "    def read() -> i32:",
        "        return this.value",
        "",
        "def increment(counter: ref[Counter], amount: i32) -> void:",
        "    counter.add(amount)",
        "    counter.value += 1",
        "",
        "def main() -> i32:",
        "    var counter = Counter(value = 3)",
        "    let handle = ref_of(counter)",
        "    increment(handle, 4)",
        "    let value_ref = ref_of(handle.value)",
        "    read(value_ref) += 2",
        "    unsafe:",
        "        let raw_counter = ptr_of(handle)",
        "        raw_counter.value += 1",
        "    return handle.read()",
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

  def test_run_with_host_compiler_executes_program_using_raw_pointer_methods
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-pointer-methods") do |dir|
      source_path = File.join(dir, "pointer-methods.mt")

      File.write(source_path, [
        "module demo.pointer_methods_runtime",
        "",
        "struct Counter:",
        "    value: i32",
        "",
        "methods Counter:",
        "    edit def add(delta: i32):",
        "        this.value += delta",
        "",
        "    def read() -> i32:",
        "        return this.value",
        "",
        "def main() -> i32:",
        "    var counter = Counter(value = 3)",
        "    let counter_ptr = ptr_of(counter)",
        "    unsafe:",
        "        counter_ptr.add(4)",
        "        return counter_ptr.read()",
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
        "def project(counter: Counter) -> i32:",
        "    return counter.value",
        "",
        "def main() -> i32:",
        "    var counter = Counter(value = 9)",
        "    let handle = ref_of(counter)",
        "    counter.value = 12",
        "    return project(read(handle))",
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
        "def first(items: span[i32]) -> i32:",
        "    if items.len == 0:",
        "        return 0",
        "    unsafe:",
        "        return read(items.data)",
        "",
        "def main() -> i32:",
        "    var value = 7",
        "    let items = span[i32](data = ptr_of(value), len = 1)",
        "    return first(items)",
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
        "def bump(items: span[i32]) -> i32:",
        "    let first = items[0]",
        "    items[0] = first + 2",
        "    return items[0]",
        "",
        "def main() -> i32:",
        "    var value = 7",
        "    let items = span[i32](data = ptr_of(value), len = 1)",
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
        "def first(items: Slice[i32]) -> i32:",
        "    if items.len == 0:",
        "        return 0",
        "    unsafe:",
        "        return read(items.data)",
        "",
        "def main() -> i32:",
        "    var value = 7",
        "    let holder = Holder(items = Slice[i32](data = ptr_of(value), len = 1))",
        "    return first(holder.items)",
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
        "    let items = Slice[i32](data = ptr_of(value), len = 1)",
        "    let smallest = min(9, 4)",
        "    unsafe:",
        "        return read(head(items)) + smallest",
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
        "def project(counter: Counter) -> i32:",
        "    return counter.value",
        "",
        "def main() -> i32:",
        "    var counter = Counter(value = 9)",
        "    let handle = ref_of(counter)",
        "    counter.value = 12",
        "    return project(read(handle))",
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
        "    for i in 0..4:",
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

  def test_run_with_host_compiler_executes_program_using_result_values
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-result") do |dir|
      source_path = File.join(dir, "result.mt")

      File.write(source_path, [
        "module demo.result_runtime",
        "",
        "enum ParseError: u8",
        "    empty = 1",
        "    invalid = 2",
        "",
        "def parse(flag: i32) -> Result[i32, ParseError]:",
        "    if flag == 0:",
        "        return err(ParseError.empty)",
        "    elif flag < 0:",
        "        return err(ParseError.invalid)",
        "    return ok(flag + 10)",
        "",
        "def value_or_code(result: Result[i32, ParseError]) -> i32:",
        "    if result.is_ok:",
        "        return result.value",
        "    match result.error:",
        "        ParseError.empty:",
        "            return 2",
        "        ParseError.invalid:",
        "            return 3",
        "",
        "def main() -> i32:",
        "    let parsed = parse(4)",
        "    let failed = parse(0)",
        "    return value_or_code(parsed) + value_or_code(failed)",
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

  def test_run_with_host_compiler_executes_program_using_callable_values
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-callable") do |dir|
      source_path = File.join(dir, "callable.mt")

      File.write(source_path, [
        "module demo.callable_runtime",
        "",
        "struct Entry:",
        "    callback: fn(value: i32) -> i32",
        "",
        "def add_two(value: i32) -> i32:",
        "    return value + 2",
        "",
        "def triple(value: i32) -> i32:",
        "    return value * 3",
        "",
        "def main() -> i32:",
        "    let callbacks = array[fn(value: i32) -> i32, 2](add_two, triple)",
        "    let entry = Entry(callback = callbacks[1])",
        "    return callbacks[0](5) + entry.callback(4)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 19, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_proc_closures
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-proc") do |dir|
      source_path = File.join(dir, "proc_closure.mt")

      File.write(source_path, [
        "module demo.proc_closure_runtime",
        "",
        "def apply(callback: proc(value: i32) -> i32, value: i32) -> i32:",
        "    return callback(value)",
        "",
        "def main() -> i32:",
        "    let offset = 4",
        "    let callback = proc(value: i32) -> i32:",
        "        return value * 2 + offset",
        "    return apply(callback, 3)",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 10, result.exit_status
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
        "        read(target) += amount",
        "",
        "def main() -> i32:",
        "    var total = 0",
        "    for step in array[Step, 4](Step.keep, Step.skip, Step.keep, Step.stop):",
        "        defer add(ptr_of(total), 1)",
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
        "    return i32<-(sizeof(Header) + alignof(Header) + offsetof(Header, version))",
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
        "    return i32<-(sizeof(Header) + offsetof(Header, value) + alignof(Mat4))",
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

  def test_run_with_host_compiler_executes_program_using_str_slice_and_cstr_conversion
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-str-ops") do |dir|
      source_path = File.join(dir, "str_ops.mt")

      File.write(source_path, [
        "module demo.str_ops_runtime",
        "",
        "import std.str",
        "import std.mem.arena as arena",
        "import std.c.libc as libc",
        "",
        "def main() -> i32:",
        "    var scratch = arena.create(64)",
        "    defer scratch.release()",
        "    let text = \"12345!\"",
        "    let part = text.slice(0, 5)",
        "    let copied = part.to_cstr(ref_of(scratch))",
        "    if text.len == usize<-6 and libc.atoi(copied) == 12345:",
        "        return i32<-part.len",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 5, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_defer_block_cleanup_order
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-defer-block") do |dir|
      source_path = File.join(dir, "defer_block.mt")

      File.write(source_path, [
        "module demo.defer_block_runtime",
        "",
        "import std.io as io",
        "",
        "def main() -> i32:",
        "    defer io.print(\"3\")",
        "    defer:",
        "        io.print(\"1\")",
        "        io.print(\"2\")",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "123", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_utf_8_str_slice_on_codepoint_boundary
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-str-utf8-slice") do |dir|
      source_path = File.join(dir, "str_utf8_slice.mt")

      File.write(source_path, [
        "module demo.str_utf8_slice_runtime",
        "",
        "import std.str",
        "",
        "def main() -> i32:",
        "    let text = \"éx\"",
        "    let part = text.slice(0, 2)",
        "    if text.len == usize<-3 and part.len == usize<-2:",
        "        return i32<-part.len",
        "    return 0",
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

  def test_run_with_host_compiler_rejects_str_slice_with_non_utf_8_start_boundary
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-str-bad-start-boundary") do |dir|
      source_path = File.join(dir, "str_bad_start_boundary.mt")

      File.write(source_path, [
        "module demo.str_bad_start_boundary_runtime",
        "",
        "import std.str",
        "",
        "def main() -> i32:",
        "    let text = \"éx\"",
        "    let part = text.slice(1, 2)",
        "    return i32<-part.len",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_includes result.stderr, "str slice start must be a UTF-8 boundary"
      assert_equal 134, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_rejects_str_slice_with_non_utf_8_end_boundary
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-str-bad-end-boundary") do |dir|
      source_path = File.join(dir, "str_bad_end_boundary.mt")

      File.write(source_path, [
        "module demo.str_bad_end_boundary_runtime",
        "",
        "import std.str",
        "",
        "def main() -> i32:",
        "    let text = \"éx\"",
        "    let part = text.slice(0, 1)",
        "    return i32<-part.len",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_includes result.stderr, "str slice end must be a UTF-8 boundary"
      assert_equal 134, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_rejects_array_char_as_str_method
    Dir.mktmpdir("milk-tea-run-array-char-bad-str") do |dir|
      source_path = File.join(dir, "array_char_bad_str.mt")

      File.write(source_path, [
        "module demo.array_char_bad_str_runtime",
        "",
        "def main() -> i32:",
        "    var buffer: array[char, 2]",
        "    let view = buffer.as_str()",
        "    return i32<-view.len",
        "",
      ].join("\n"))

      error = assert_raises(MilkTea::SemaError) do
        MilkTea::Run.run(source_path)
      end

      assert_match(/array\[char, 2\]\.as_str is not available; array\[char, N\] is raw storage/, error.message)
    end
  end

  def test_run_rejects_array_char_as_cstr_method
    Dir.mktmpdir("milk-tea-run-array-char-bad-cstr") do |dir|
      source_path = File.join(dir, "array_char_bad_cstr.mt")

      File.write(source_path, [
        "module demo.array_char_bad_cstr_runtime",
        "",
        "def main() -> i32:",
        "    var buffer: array[char, 2]",
        "    let label = buffer.as_cstr()",
        "    return 0",
        "",
      ].join("\n"))

      error = assert_raises(MilkTea::SemaError) do
        MilkTea::Run.run(source_path)
      end

      assert_match(/array\[char, 2\]\.as_cstr is not available; array\[char, N\] is raw storage/, error.message)
    end
  end

  def test_run_with_host_compiler_executes_program_using_str_builder_methods
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-str-builder") do |dir|
      source_path = File.join(dir, "str_builder.mt")

      File.write(source_path, [
        "module demo.str_builder_runtime",
        "",
        "def write_raw(items: span[char]) -> void:",
        "    unsafe:",
        "        items.data[0] = char<-65",
        "        items.data[1] = 0",
        "",
        "def view(items: span[char]) -> usize:",
        "    return items.len",
        "",
        "def main() -> i32:",
        "    var buffer: str_builder[8]",
        "    buffer.assign(\"ab\")",
        "    buffer.append(\"cd\")",
        "    if view(buffer) != usize<-9:",
        "        return 1",
        "    if buffer.len() != usize<-4:",
        "        return 2",
        "    write_raw(buffer)",
        "    let text = buffer.as_str()",
        "    if text.len != usize<-1:",
        "        return 3",
        "    if buffer.len() != usize<-1:",
        "        return 4",
        "    buffer.clear()",
        "    if buffer.len() != usize<-0:",
        "        return 5",
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

  def test_run_with_host_compiler_rejects_str_builder_as_str_after_invalid_raw_write
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-str-builder-bad-str") do |dir|
      source_path = File.join(dir, "str_builder_bad_str.mt")

      File.write(source_path, [
        "module demo.str_builder_bad_str_runtime",
        "",
        "def corrupt(items: span[char]) -> void:",
        "    unsafe:",
        "        items.data[0] = char<-0x80",
        "        items.data[1] = 0",
        "",
        "def main() -> i32:",
        "    var buffer: str_builder[4]",
        "    corrupt(buffer)",
        "    let text = buffer.as_str()",
        "    return i32<-text.len",
        "",
      ].join("\n"))

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_includes result.stderr, "str_builder text must be valid UTF-8"
      assert_equal 134, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal [], result.link_flags
    end
  end

  def test_run_with_host_compiler_executes_program_using_span_str_foreign_list_marshalling
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    dir_name = "run_span_str_#{Process.pid}_#{Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)}"
    dir = File.join(MilkTea.root, "tmp", dir_name)
    source_path = File.join(dir, "main.mt")
    sample_path = File.join(dir, "sample.mt")

    Dir.mkdir(dir)

    begin
      module_prefix = "tmp.#{dir_name}"

      File.write(sample_path, [
        "module #{module_prefix}.sample",
        "",
        "import std.c.libc as libc",
        "",
        "pub foreign def first(labels: span[str] as span[ptr[char]]) -> i32 = libc.atoi(labels[0])",
        "pub foreign def second(labels: span[str] as span[ptr[char]]) -> i32 = libc.atoi(labels[1])",
        "",
      ].join("\n"))

      File.write(source_path, [
        "module #{module_prefix}.main",
        "",
        "import #{module_prefix}.sample as sample",
        "",
        "def main() -> i32:",
        "    var labels = array[str, 2](\"12\", \"34\")",
        "    let first = sample.first(labels)",
        "    let second = sample.second(labels)",
        "    if first != 12:",
        "        return 1",
        "    if second != 34:",
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
    ensure
      File.delete(sample_path) if File.exist?(sample_path)
      File.delete(source_path) if File.exist?(source_path)
      Dir.rmdir(dir) if Dir.exist?(dir)
    end
  end

  def test_run_with_host_compiler_executes_program_using_nested_imported_foreign_calls
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    dir_name = "run_nested_foreign_#{Process.pid}_#{Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)}"
    dir = File.join(MilkTea.root, "tmp", dir_name)
    source_path = File.join(dir, "main.mt")
    sample_path = File.join(dir, "sample.mt")

    Dir.mkdir(dir)

    begin
      module_prefix = "tmp.#{dir_name}"

      File.write(sample_path, [
        "module #{module_prefix}.sample",
        "",
        "import std.c.libc as libc",
        "",
        "pub foreign def first(labels: span[str] as span[ptr[char]]) -> i32 = libc.atoi(labels[0])",
        "pub foreign def second(labels: span[str] as span[ptr[char]]) -> i32 = libc.atoi(labels[1])",
        "pub foreign def same_div(value: i32) -> libc.div_t = libc.div(value, value)",
        "",
      ].join("\n"))

      File.write(source_path, [
        "module #{module_prefix}.main",
        "",
        "import #{module_prefix}.sample as sample",
        "",
        "def keep(value: i32) -> i32:",
        "    return value",
        "",
        "def main() -> i32:",
        "    var labels = array[str, 2](\"12\", \"34\")",
        "    var short_labels = array[str, 1](\"12\")",
        "    let nested_sum = keep(sample.first(labels) + sample.second(labels))",
        "    if nested_sum != 46:",
        "        return 1",
        "    let duplicated = sample.same_div(1 + 2).quot",
        "    if duplicated != 1:",
        "        return 2",
        "    let chosen = if true: keep(sample.first(labels)) else: keep(sample.second(short_labels))",
        "    if chosen != 12:",
        "        return 3",
        "    if false and sample.second(short_labels) != 0:",
        "        return 4",
        "    let always_true = if true or sample.second(short_labels) != 0: 1 else: 0",
        "    if always_true != 1:",
        "        return 5",
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
    ensure
      File.delete(sample_path) if File.exist?(sample_path)
      File.delete(source_path) if File.exist?(source_path)
      Dir.rmdir(dir) if Dir.exist?(dir)
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
        "        if read(ptr_of(palette[0])) != 1:",
        "            return 1",
        "        if read(ptr_of(holder.colors[0])) != 5:",
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

  def test_run_with_host_compiler_executes_program_using_addr_of_fixed_array_element_through_pointer_deref
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-ptr-array-addr") do |dir|
      source_path = File.join(dir, "ptr-array-addr.mt")

      File.write(source_path, [
        "module demo.ptr_arrays",
        "",
        "struct Palette:",
        "    colors: array[u32, 4]",
        "",
        "def main() -> i32:",
        "    var holder = Palette(colors = array[u32, 4](5, 6, 7, 8))",
        "    unsafe:",
        "        let base = ptr_of(holder)",
        "        let first = ptr_of(base.colors[0])",
        "        read(first) = 9",
        "    if holder.colors[0] != 9:",
        "        return 1",
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
        "def mutate(values: array[i32, 4]) -> i32:",
        "    var local = values",
        "    unsafe:",
        "        local[1] = 9",
        "        return local[1]",
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
        "    let palette = zero[array[u32, 4]]",
        "    let holder = zero[Palette]",
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

  def test_run_with_host_compiler_executes_program_using_partial_aggregate_and_array_initialization
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-run-partial-init") do |dir|
      source_path = File.join(dir, "partial-init.mt")

      File.write(source_path, [
        "module demo.partial_init",
        "",
        "struct Point:",
        "    x: i32",
        "    y: i32",
        "",
        "struct Holder:",
        "    point: Point",
        "    colors: array[u32, 4]",
        "",
        "def main() -> i32:",
        "    let origin = Point()",
        "    let point = Point(x = 5)",
        "    let colors = array[u32, 4](1, 2)",
        "    let holder = Holder(point = point)",
        "    if origin.x != 0 or origin.y != 0:",
        "        return 1",
        "    if point.x != 5 or point.y != 0:",
        "        return 2",
        "    if colors[0] != 1 or colors[1] != 2 or colors[2] != 0 or colors[3] != 0:",
        "        return 3",
        "    if holder.point.x != 5 or holder.point.y != 0:",
        "        return 4",
        "    if holder.colors[0] != 0 or holder.colors[3] != 0:",
        "        return 5",
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
    File.expand_path("../../examples/milk-tea-demo.mt", __dir__)
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
