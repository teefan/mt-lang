# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdRaylibOpenGLRuntimeTest < Minitest::Test
  def test_host_runtime_creates_raylib_context_and_loads_gl_symbols
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)
    skip "xvfb-run not available" unless command_available?("xvfb-run")
    skip "Xvfb not available" unless command_available?("Xvfb")

    source = <<~MT

import std.gl as gl
import std.raylib as rl

function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_WINDOW_HIDDEN)
    rl.init_window(64, 64, "raylib-opengl-smoke")
    defer:
        rl.close_window()

    gl.use_raylib_loader()

    gl.viewport(0, 0, 64, 64)
    gl.clear_color(0.1, 0.2, 0.3, 1.0)
    gl.clear(gl.COLOR_BUFFER_BIT)
    return 0

    MT

    build_result, stdout, stderr, status = run_program_under_xvfb(source, compiler:)

    assert status.success?, <<~MSG
      runtime smoke failed with #{status.inspect}
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MSG
    assert_includes build_result.link_flags.join(" "), "raylib"
  end

  private

  def run_program_under_xvfb(source, compiler:)
    Dir.mktmpdir("milk-tea-std-raylib-opengl-runtime") do |dir|
      source_path = File.join(dir, "program.mt")
      output_path = File.join(dir, "program")
      File.write(source_path, source)

      build_result = MilkTea::Build.build(source_path, output_path:, cc: compiler)
      stdout, stderr, status = Open3.capture3(
        { "LIBGL_ALWAYS_SOFTWARE" => "1" },
        "xvfb-run",
        "-a",
        "-s",
        "-screen 0 1280x720x24 +extension GLX +render -noreset",
        build_result.output_path,
        chdir: dir,
      )

      return [build_result, stdout, stderr, status]
    end
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end

  def command_available?(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, name)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
