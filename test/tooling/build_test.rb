# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../test_helper"
require_relative "../../lib/milk_tea/bindings"

class MilkTeaBuildTest < Minitest::Test
  def test_build_generates_output_and_kept_c_with_link_flags
    Dir.mktmpdir("milk-tea-build") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      output_path = File.join(dir, "milk-tea-demo")
      c_path = File.join(dir, "milk-tea-demo.c")

      result = MilkTea::Build.build(demo_path, output_path:, cc: compiler_path, keep_c_path: c_path)

      assert_equal File.expand_path(output_path), result.output_path
      assert_equal File.expand_path(c_path), result.c_path
      assert_equal File.expand_path(compiler_path), result.compiler
      assert_includes result.link_flags, "-lraylib"
      assert File.exist?(output_path)
      assert File.exist?(c_path)
      assert_match(/#include "raylib\.h"/, File.read(c_path))

      invocation = File.read(compiler_log).lines(chomp: true)
      assert_includes invocation, "-std=c11"
      assert_includes invocation, File.expand_path(c_path)
      assert_includes invocation, File.expand_path(output_path)
      assert_includes invocation, "-lraylib"
    end
  end

  def test_build_reports_missing_compiler
    error = assert_raises(MilkTea::BuildError) do
      MilkTea::Build.build(demo_path, cc: "/definitely/missing/cc")
    end

    assert_match(/C compiler not found/, error.message)
  end

  def test_build_with_host_compiler_produces_runnable_binary
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-build-real") do |dir|
      source_path = File.join(dir, "smoke.mt")
      output_path = File.join(dir, "smoke")

      File.write(source_path, [
        "module demo.smoke",
        "",
        "const base: i32 = 40",
        "",
        "def main() -> i32:",
        "    let value = base + 2",
        "    return value",
        "",
      ].join("\n"))

      result = MilkTea::Build.build(source_path, output_path:, cc: compiler)

      assert_equal File.expand_path(output_path), result.output_path
      assert_nil result.c_path
      assert_equal [], result.link_flags
      assert File.exist?(output_path)
      assert File.executable?(output_path)

      stdout, stderr, status = Open3.capture3(output_path)
      assert_equal "", stdout
      assert_equal "", stderr
      assert_equal 42, status.exitstatus
    end
  end

  def test_build_with_host_compiler_supports_variadic_extern_calls
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    unique_root = "mtvarargs#{Process.pid}#{rand(1_000_000)}"
    workspace_dir = File.join(MilkTea.root, unique_root)

    begin
      FileUtils.mkdir_p(File.join(workspace_dir, "std", "c"))
      FileUtils.mkdir_p(File.join(workspace_dir, "demo"))

      File.write(File.join(workspace_dir, "std", "c", "stdio.mt"), [
        "extern module #{unique_root}.std.c.stdio:",
        "    include \"stdio.h\"",
        "",
        "    extern def printf(format: cstr, ...) -> i32",
        "",
      ].join("\n"))

      source_path = File.join(workspace_dir, "demo", "main.mt")
      output_path = File.join(workspace_dir, "demo", "main")

      File.write(source_path, [
        "module #{unique_root}.demo.main",
        "",
        "import #{unique_root}.std.c.stdio as c",
        "",
        "def main() -> i32:",
        "    c.printf(c\"%d %s\\n\", 42, c\"ok\")",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Build.build(source_path, output_path:, cc: compiler)

      assert_equal File.expand_path(output_path), result.output_path
      assert File.exist?(output_path)

      stdout, stderr, status = Open3.capture3(output_path)
      assert_equal "42 ok\n", stdout
      assert_equal "", stderr
      assert_equal 0, status.exitstatus
    ensure
      FileUtils.remove_entry(workspace_dir) if File.exist?(workspace_dir)
    end
  end

  def test_build_with_host_compiler_supports_external_opaque_pointer_ffi
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-build-external-opaque") do |dir|
      source_path = File.join(dir, "time-smoke.mt")
      output_path = File.join(dir, "time-smoke")

      File.write(source_path, [
        "module demo.time_smoke",
        "",
        "import std.c.time as ctime",
        "",
        "const time_format: cstr = c\"%H:%M:%S\"",
        "",
        "def main() -> i32:",
        "    var now: ctime.time_t = 0",
        "    now = ctime.time(ptr_of(now))",
        "    let tm_info = ctime.localtime(ptr_of(now))",
        "    var time_buffer = zero[array[char, 9]]()",
        "    unsafe:",
        "        ctime.strftime(ptr_of(time_buffer[0]), 9, time_format, tm_info)",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Build.build(source_path, output_path:, cc: compiler)

      assert_equal File.expand_path(output_path), result.output_path
      assert File.exist?(output_path)
      assert File.executable?(output_path)

      stdout, stderr, status = Open3.capture3(output_path)
      assert_equal "", stdout
      assert_equal "", stderr
      assert_equal 0, status.exitstatus
    end
  end

  def test_build_with_host_compiler_uses_distinct_loop_labels_across_sibling_nested_blocks
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-build-loop-labels") do |dir|
      source_path = File.join(dir, "loop-labels.mt")
      output_path = File.join(dir, "loop-labels")

      File.write(source_path, [
        "module demo.loop_labels",
        "",
        "def main() -> i32:",
        "    var outer = 0",
        "    while outer < 2:",
        "        if outer == 0:",
        "            var left = 0",
        "            while left < 1:",
        "                left += 1",
        "        else:",
        "            var right = 0",
        "            while right < 1:",
        "                right += 1",
        "        outer += 1",
        "    return outer",
        "",
      ].join("\n"))

      result = MilkTea::Build.build(source_path, output_path:, cc: compiler)

      assert_equal File.expand_path(output_path), result.output_path
      assert File.exist?(output_path)

      stdout, stderr, status = Open3.capture3(output_path)
      assert_equal "", stdout
      assert_equal "", stderr
      assert_equal 2, status.exitstatus
    end
  end

  def test_build_includes_raw_binding_compiler_flags_for_imported_extern_modules
    Dir.mktmpdir("milk-tea-build-raw-binding-flags") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      output_path = File.join(dir, "milk-tea-demo")
      header_path = File.join(dir, "raylib.h")
      File.write(header_path, "")

      raw_bindings = MilkTea::RawBindings::Registry.new([
        MilkTea::RawBindings::Binding.new(
          name: "raylib",
          module_name: "std.c.raylib",
          binding_path: File.join(dir, "raylib.mt"),
          header_candidates: [header_path],
          include_directives: ["raylib.h"],
          link_libraries: ["raylib"],
          link_flags: ["-L#{dir}", "-lglfw"],
          implementation_defines: ["MT_TEST_IMPLEMENTATION"],
          compiler_flags: ["-DMT_TEST_TOOLING=1"],
        ),
      ])

      MilkTea::Build.build(demo_path, output_path:, cc: compiler_path, raw_bindings:)

      invocation = File.read(compiler_log).lines(chomp: true)
      assert_includes invocation, "-I#{dir}"
      assert_includes invocation, "-DMT_TEST_IMPLEMENTATION"
      assert_includes invocation, "-DMT_TEST_TOOLING=1"
      assert_includes invocation, "-L#{dir}"
      assert_includes invocation, "-lglfw"
      assert_includes invocation, "-lraylib"
      assert_operator invocation.index("-L#{dir}"), :<, invocation.index("-lraylib")
      assert_operator invocation.index("-lraylib"), :<, invocation.index("-lglfw")
    end
  end

  def test_build_runs_raw_binding_prepare_hook_for_imported_extern_modules
    Dir.mktmpdir("milk-tea-build-raw-binding-prepare") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      output_path = File.join(dir, "milk-tea-demo")
      header_path = File.join(dir, "raylib.h")
      File.write(header_path, "")

      prepared = []
      raw_bindings = MilkTea::RawBindings::Registry.new([
        MilkTea::RawBindings::Binding.new(
          name: "raylib",
          module_name: "std.c.raylib",
          binding_path: File.join(dir, "raylib.mt"),
          header_candidates: [header_path],
          include_directives: ["raylib.h"],
          link_libraries: ["raylib"],
          prepare: ->(_binding, env:, cc:) { prepared << cc },
        ),
      ])

      MilkTea::Build.build(demo_path, output_path:, cc: compiler_path, raw_bindings:)

      assert_equal [File.expand_path(compiler_path)], prepared
    end
  end

  def test_build_uses_default_raygui_binding_compiler_flags_when_imported
    Dir.mktmpdir("milk-tea-build-raygui") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      source_path = File.join(dir, "raygui.mt")
      output_path = File.join(dir, "raygui-demo")
      c_path = File.join(dir, "raygui-demo.c")

      File.write(source_path, [
        "module demo.raygui_smoke",
        "",
        "import std.c.raygui as gui",
        "",
        "def main() -> i32:",
        "    gui.GuiEnable()",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Build.build(source_path, output_path:, cc: compiler_path, keep_c_path: c_path)

      assert_equal File.expand_path(output_path), result.output_path
      assert_equal File.expand_path(c_path), result.c_path
      assert_equal File.expand_path(compiler_path), result.compiler
      assert_includes result.link_flags, "-lraylib"
      assert_includes result.link_flags, "-lm"
      assert_match(/#include "raygui\.h"/, File.read(c_path))

      invocation = File.read(compiler_log).lines(chomp: true)
      assert_includes invocation, "-lraylib"
      assert_includes invocation, "-lm"
      assert_includes invocation, "-DRAYGUI_IMPLEMENTATION"
      assert_includes invocation, "-I#{File.expand_path('../../third_party/raylib-upstream/examples/shapes', __dir__)}"
    end
  end

  def test_build_uses_default_rlights_binding_compiler_flags_when_imported
    Dir.mktmpdir("milk-tea-build-rlights") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      source_path = File.join(dir, "rlights.mt")
      output_path = File.join(dir, "rlights-demo")
      c_path = File.join(dir, "rlights-demo.c")

      File.write(source_path, [
        "module demo.rlights_smoke",
        "",
        "import std.c.raylib as rl",
        "import std.c.rlights as lights",
        "",
        "def main() -> i32:",
        "    let shader = zero[rl.Shader]()",
        "    let light = lights.CreateLight(i32<-lights.LightType.LIGHT_POINT, rl.Vector3(x = 1.0, y = 2.0, z = 3.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.WHITE, shader)",
        "    if light.enabled:",
        "        rl.DrawSphereEx(light.position, 0.2, 8, 8, light.color)",
        "    lights.UpdateLightValues(shader, light)",
        "    return lights.MAX_LIGHTS",
        "",
      ].join("\n"))

      result = MilkTea::Build.build(source_path, output_path:, cc: compiler_path, keep_c_path: c_path)

      assert_equal File.expand_path(output_path), result.output_path
      assert_equal File.expand_path(c_path), result.c_path
      assert_equal File.expand_path(compiler_path), result.compiler
      assert_includes result.link_flags, "-lraylib"
      assert_match(/#include "rlights\.h"/, File.read(c_path))

      invocation = File.read(compiler_log).lines(chomp: true)
      assert_includes invocation, "-lraylib"
      assert_includes invocation, "-DRLIGHTS_IMPLEMENTATION"
      assert_includes invocation, "-I#{File.expand_path('../../third_party/raylib-upstream/examples/shaders', __dir__)}"
    end
  end

  private

  def demo_path
    File.expand_path("../../examples/milk-tea-demo.mt", __dir__)
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
end
