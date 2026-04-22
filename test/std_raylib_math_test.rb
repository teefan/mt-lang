# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaStdRaylibMathTest < Minitest::Test
  def test_std_raylib_math_helpers_check_and_lower
    Dir.mktmpdir("milk-tea-std-raylib-math") do |dir|
      source_path = File.join(dir, "program.mt")
      File.write(source_path, test_source)

      program = MilkTea::ModuleLoader.check_program(source_path)

      assert_equal true, program.analyses_by_module_name.key?("demo.std_raylib_math")
      assert_equal true, program.analyses_by_module_name.key?("std.raylib.math")
    end
  end

  def test_std_raylib_math_helpers_build_with_fake_compiler
    Dir.mktmpdir("milk-tea-std-raylib-math") do |dir|
      source_path = File.join(dir, "program.mt")
      File.write(source_path, test_source)

      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      output_path = File.join(dir, "program")
      c_path = File.join(dir, "program.c")

      result = MilkTea::Build.build(source_path, output_path:, cc: compiler_path, keep_c_path: c_path)

      assert_equal File.expand_path(output_path), result.output_path
      assert_equal File.expand_path(c_path), result.c_path
      assert_equal File.expand_path(compiler_path), result.compiler
      assert_includes result.link_flags, "-lraylib"
      assert File.exist?(output_path)
      assert File.exist?(c_path)
      assert_match(/#include "raylib\.h"/, File.read(c_path))
      assert_includes File.read(compiler_log).lines(chomp: true), "-lraylib"
    end
  end

  def test_host_runtime_executes_std_raylib_math_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)
    skip "raylib linker input not available for: #{compiler}" unless raylib_link_available?(compiler)

    Dir.mktmpdir("milk-tea-std-raylib-math") do |dir|
      source_path = File.join(dir, "program.mt")
      File.write(source_path, test_source)

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_equal compiler, result.compiler
      assert_includes result.link_flags, "-lraylib"
    end
  end

  private

  def test_source
    [
      "module demo.std_raylib_math",
      "",
      "import std.c.raylib as rl",
      "import std.math as math",
      "import std.raylib.math as rm",
      "",
      "def approx_eq(a: f32, b: f32) -> bool:",
      "    return math.abs(a - b) < 0.0001",
      "",
      "def main() -> i32:",
      "    let scalar = rm.lerp(rm.clamp(1.5, 0.0, 1.0), 5.0, 0.25)",
      "    let v2a = rm.vector2_add(rm.vector2_one(), rl.Vector2(x = 2.0, y = -1.0))",
      "    let v2b = rm.vector2_subtract(v2a, rm.vector2_zero())",
      "    let v2c = rm.vector2_scale(v2b, scalar)",
      "    let v2d = rm.vector2_multiply(v2c, rl.Vector2(x = 0.5, y = 2.0))",
      "    let v2e = rm.vector2_clamp(v2d, rl.Vector2(x = 0.0, y = -10.0), rl.Vector2(x = 10.0, y = 10.0))",
      "",
      "    let v3a = rm.vector3_add(rm.vector3_one(), rl.Vector3(x = 1.0, y = 2.0, z = 3.0))",
      "    let v3b = rm.vector3_subtract(v3a, rl.Vector3(x = 1.0, y = 1.0, z = 1.0))",
      "    let v3c = rm.vector3_scale(v3b, 2.0)",
      "    let dot = rm.vector3_dot_product(v3c, rl.Vector3(x = 1.0, y = 0.0, z = 1.0))",
      "    let cross = rm.vector3_cross_product(v3c, rl.Vector3(x = 0.0, y = 1.0, z = 0.0))",
      "    let neg = rm.vector3_negate(cross)",
      "    let mix = rm.vector3_lerp(v3c, neg, 0.25)",
      "",
      "    let translate = rm.matrix_translate(v2e.x, v2e.y, dot)",
      "    let identity = rm.matrix_identity()",
      "    let scaled = rm.matrix_scale(1.0, 2.0, 3.0)",
      "    let combined = rm.matrix_multiply(identity, translate)",
      "    let transformed = rm.vector3_transform(mix, combined)",
      "",
      "    if not approx_eq(rm.rad2deg * rm.deg2rad, 1.0):",
      "        return 1",
      "    if not approx_eq(v2e.x, 3.0) or not approx_eq(v2e.y, 0.0):",
      "        return 2",
      "    if not approx_eq(dot, 8.0):",
      "        return 3",
      "    if not approx_eq(neg.x, 6.0) or not approx_eq(neg.y, 0.0) or not approx_eq(neg.z, -2.0):",
      "        return 4",
      "    if not approx_eq(scaled.m0, 1.0) or not approx_eq(scaled.m5, 2.0) or not approx_eq(scaled.m10, 3.0):",
      "        return 5",
      "    if not approx_eq(transformed.x, 6.0) or not approx_eq(transformed.y, 3.0) or not approx_eq(transformed.z, 12.0):",
      "        return 6",
      "    return 0",
      "",
    ].join("\n")
  end

  def write_fake_compiler(dir, log_path)
    path = File.join(dir, "fake-cc")
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
      : > "$output"
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

  def raylib_link_available?(compiler)
    Dir.mktmpdir("milk-tea-raylib-link") do |dir|
      source_path = File.join(dir, "probe.c")
      output_path = File.join(dir, "probe")
      File.write(source_path, "int main(void) { return 0; }\n")

      return system(compiler, source_path, "-lraylib", "-o", output_path, out: File::NULL, err: File::NULL)
    end
  end
end
