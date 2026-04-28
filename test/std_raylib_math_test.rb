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
      assert_includes result.link_flags, "-lm"
      assert File.exist?(output_path)
      assert File.exist?(c_path)
      assert_match(/#include "raylib\.h"/, File.read(c_path))
      assert_match(/#include "math\.h"/, File.read(c_path))
      assert_includes File.read(compiler_log).lines(chomp: true), "-lraylib"
      assert_includes File.read(compiler_log).lines(chomp: true), "-lm"
    end
  end

  def test_host_runtime_executes_std_raylib_math_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)
    skip "raylib math linker input not available for: #{compiler}" unless raylib_math_link_available?(compiler)

    Dir.mktmpdir("milk-tea-std-raylib-math") do |dir|
      source_path = File.join(dir, "program.mt")
      File.write(source_path, test_source)

      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_equal compiler, result.compiler
      assert_includes result.link_flags, "-lraylib"
      assert_includes result.link_flags, "-lm"
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
      "    return math.abs(a - b) < 0.001",
      "",
      "def main() -> i32:",
      "    let scalar = rm.lerp(rm.clamp(1.5, 0.0, 1.0), 5.0, 0.25)",
      "    let rounded = rm.ceil(1.1) + rm.floor(1.9) + rm.trunc(-1.9)",
      "    let v2a = rm.Vector2.one().add(rl.Vector2(x = 2.0, y = -1.0))",
      "    let v2b = v2a.subtract(rm.Vector2.zero())",
      "    let v2c = v2b.scale(scalar)",
      "    let v2d = v2c.multiply(rl.Vector2(x = 0.5, y = 2.0))",
      "    let v2e = v2d.clamp(rl.Vector2(x = 0.0, y = -10.0), rl.Vector2(x = 10.0, y = 10.0))",
      "    let v2len = rl.Vector2(x = 3.0, y = 4.0).length()",
      "    let v2dist = rm.Vector2.zero().distance(rl.Vector2(x = 6.0, y = 8.0))",
      "    let v2norm = rl.Vector2(x = 3.0, y = 4.0).normalize()",
      "    let v2angle = rl.Vector2(x = 1.0, y = 0.0).angle(rl.Vector2(x = 0.0, y = 1.0))",
      "    let v2rot = rl.Vector2(x = 1.0, y = 0.0).rotate(90.0 * rm.deg2rad)",
      "",
      "    let v3a = rm.Vector3.one().add(rl.Vector3(x = 1.0, y = 2.0, z = 3.0))",
      "    let v3b = v3a.subtract(rl.Vector3(x = 1.0, y = 1.0, z = 1.0))",
      "    let v3c = v3b.scale(2.0)",
      "    let dot = v3c.dot(rl.Vector3(x = 1.0, y = 0.0, z = 1.0))",
      "    let cross = v3c.cross(rl.Vector3(x = 0.0, y = 1.0, z = 0.0))",
      "    let neg = cross.negate()",
      "    let mix = v3c.lerp(neg, 0.25)",
      "    let v3len = rl.Vector3(x = 2.0, y = 3.0, z = 6.0).length()",
      "    let v3dist = rm.Vector3.zero().distance(rl.Vector3(x = 2.0, y = 3.0, z = 6.0))",
      "    let v3norm = rl.Vector3(x = 0.0, y = 3.0, z = 4.0).normalize()",
      "    let v3angle = rl.Vector3(x = 1.0, y = 0.0, z = 0.0).angle(rl.Vector3(x = 0.0, y = 1.0, z = 0.0))",
      "    let v3rot = rl.Vector3(x = 1.0, y = 0.0, z = 0.0).rotate_by_axis_angle(rl.Vector3(x = 0.0, y = 0.0, z = 1.0), 90.0 * rm.deg2rad)",
      "",
      "    let translate = rm.Matrix.translate(v2e.x, v2e.y, dot)",
      "    let identity = rm.Matrix.identity()",
      "    let scaled = rm.Matrix.scale(1.0, 2.0, 3.0)",
      "    let combined = identity.multiply(translate)",
      "    let affine = scaled.multiply(translate)",
      "    let affine_inverse = affine.invert()",
      "    let affine_product = affine.multiply(affine_inverse)",
      "    let identity_inverse = identity.invert()",
      "    let transformed = mix.transform(combined)",
      "    let look = rm.Matrix.look_at(rl.Vector3(x = 0.0, y = 0.0, z = 1.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = 1.0, z = 0.0))",
      "    let perspective = rm.Matrix.perspective(90.0 * rm.deg2rad, 1.0, 0.1, 100.0)",
      "    let ortho = rm.Matrix.ortho(-1.0, 1.0, -1.0, 1.0, 0.1, 100.0)",
      "",
      "    let color = rm.Color.from_hsv(0.0, 1.0, 1.0)",
      "",
      "    let q_identity = rm.Quaternion.identity()",
      "    let q_axis = rm.Quaternion.from_axis_angle(rl.Vector3(x = 0.0, y = 0.0, z = 1.0), 90.0 * rm.deg2rad)",
      "    let q_norm = rl.Vector4(x = 0.0, y = 0.0, z = 2.0, w = 0.0).normalize()",
      "    let q_inv = q_axis.invert()",
      "    let q_back = q_axis.multiply(q_inv)",
      "    let q_matrix = q_axis.to_matrix()",
      "    let q_from_matrix = rm.Quaternion.from_matrix(q_matrix)",
      "    let q_roundtrip = q_from_matrix.to_matrix()",
      "    let q_slerp = q_identity.slerp(q_axis, 0.5)",
      "    let q_slerp_matrix = q_slerp.to_matrix()",
      "",
      "    if not approx_eq(rm.rad2deg * rm.deg2rad, 1.0):",
      "        return 1",
      "    if not approx_eq(rounded, 2.0):",
      "        return 28",
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
      "    if not approx_eq(affine_product.m0, 1.0) or not approx_eq(affine_product.m5, 1.0) or not approx_eq(affine_product.m10, 1.0) or not approx_eq(affine_product.m15, 1.0):",
      "        return 25",
      "    if not approx_eq(affine_product.m12, 0.0) or not approx_eq(affine_product.m13, 0.0) or not approx_eq(affine_product.m14, 0.0):",
      "        return 26",
      "    if not approx_eq(identity_inverse.m0, 1.0) or not approx_eq(identity_inverse.m5, 1.0) or not approx_eq(identity_inverse.m10, 1.0) or not approx_eq(identity_inverse.m15, 1.0):",
      "        return 27",
      "    if not approx_eq(v2len, 5.0) or not approx_eq(v2dist, 10.0):",
      "        return 7",
      "    if not approx_eq(v2norm.x, 0.6) or not approx_eq(v2norm.y, 0.8):",
      "        return 8",
      "    if not approx_eq(v2angle, 90.0 * rm.deg2rad):",
      "        return 9",
      "    if not approx_eq(v2rot.x, 0.0) or not approx_eq(v2rot.y, 1.0):",
      "        return 10",
      "    if not approx_eq(v3len, 7.0) or not approx_eq(v3dist, 7.0):",
      "        return 11",
      "    if not approx_eq(v3norm.x, 0.0) or not approx_eq(v3norm.y, 0.6) or not approx_eq(v3norm.z, 0.8):",
      "        return 12",
      "    if not approx_eq(v3angle, 90.0 * rm.deg2rad):",
      "        return 13",
      "    if not approx_eq(v3rot.x, 0.0) or not approx_eq(v3rot.y, 1.0) or not approx_eq(v3rot.z, 0.0):",
      "        return 14",
      "    if color.r != 255 or color.g != 0 or color.b != 0 or color.a != 255:",
      "        return 15",
      "    if not approx_eq(look.m0, 1.0) or not approx_eq(look.m5, 1.0) or not approx_eq(look.m10, 1.0) or not approx_eq(look.m14, -1.0):",
      "        return 16",
      "    if not approx_eq(perspective.m0, 1.0) or not approx_eq(perspective.m5, 1.0) or not approx_eq(perspective.m11, -1.0):",
      "        return 17",
      "    if not approx_eq(ortho.m0, 1.0) or not approx_eq(ortho.m5, 1.0) or not approx_eq(ortho.m15, 1.0):",
      "        return 18",
      "    if not approx_eq(q_identity.w, 1.0):",
      "        return 19",
      "    if not approx_eq(q_norm.z, 1.0) or not approx_eq(q_norm.w, 0.0):",
      "        return 20",
      "    if not approx_eq(q_back.x, 0.0) or not approx_eq(q_back.y, 0.0) or not approx_eq(q_back.z, 0.0) or not approx_eq(q_back.w, 1.0):",
      "        return 21",
      "    if not approx_eq(q_matrix.m0, 0.0) or not approx_eq(q_matrix.m1, 1.0) or not approx_eq(q_matrix.m4, -1.0) or not approx_eq(q_matrix.m5, 0.0):",
      "        return 22",
      "    if not approx_eq(q_roundtrip.m0, q_matrix.m0) or not approx_eq(q_roundtrip.m1, q_matrix.m1) or not approx_eq(q_roundtrip.m4, q_matrix.m4) or not approx_eq(q_roundtrip.m5, q_matrix.m5):",
      "        return 23",
      "    if not approx_eq(q_slerp_matrix.m0, 0.70710677) or not approx_eq(q_slerp_matrix.m1, 0.70710677) or not approx_eq(q_slerp_matrix.m4, -0.70710677) or not approx_eq(q_slerp_matrix.m5, 0.70710677):",
      "        return 24",
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

  def raylib_math_link_available?(compiler)
    Dir.mktmpdir("milk-tea-raylib-link") do |dir|
      source_path = File.join(dir, "probe.c")
      output_path = File.join(dir, "probe")
      File.write(source_path, "int main(void) { return 0; }\n")

      return system(compiler, source_path, "-lraylib", "-lm", "-o", output_path, out: File::NULL, err: File::NULL)
    end
  end
end
