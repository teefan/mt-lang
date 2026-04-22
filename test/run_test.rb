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
        "    let counter_ptr = &counter",
        "    (*counter_ptr).value = 7",
        "    let value = (*counter_ptr).value",
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
        "        return *items.data",
        "",
        "def main() -> i32:",
        "    var value = 7",
        "    let items = span[i32](data = &value, len = 1)",
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
        "        return *items.data",
        "",
        "def main() -> i32:",
        "    var value = 7",
        "    let holder = Holder(items = Slice[i32](data = &value, len = 1))",
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
        "    let items = Slice[i32](data = &value, len = 1)",
        "    let smallest = min(9, 4)",
        "    unsafe:",
        "        return *head(items) + smallest",
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
        "        if *cast[ptr[u32]](&palette) != 1:",
        "            return 1",
        "        if *cast[ptr[u32]](&holder.colors) != 5:",
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
        "    unsafe:",
        "        palette[1] = 9",
        "        holder.colors[2] = 10",
        "        if palette[0] != 1:",
        "            return 1",
        "        if palette[1] != 9:",
        "            return 2",
        "        if holder.colors[2] != 10:",
        "            return 3",
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
