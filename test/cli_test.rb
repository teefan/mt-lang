# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "json"
require_relative "test_helper"

class MilkTeaCliTest < Minitest::Test
  def test_lex_command_reports_tokens
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["lex", demo_path], out:, err:)

    assert_equal 0, status
    assert_equal "", err.string
    assert_match(/MilkTea::Token/, out.string)
    assert_match(/type=:module/, out.string)
  end

  def test_parse_command_reports_ast
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["parse", demo_path], out:, err:)

    assert_equal 0, status
    assert_equal "", err.string
    assert_includes out.string, "module demo.bouncing_ball"
    assert_includes out.string, "methods Ball:"
    assert_includes out.string, "def main() -> i32:"
  end

  def test_check_command_reports_success
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["check", demo_path], out:, err:)

    assert_equal 0, status
    assert_match(/checked .*milk-tea-demo\.mt as demo\.bouncing_ball/, out.string)
    assert_equal "", err.string
  end

  def test_lower_command_reports_ir
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["lower", demo_path], out:, err:)

    assert_equal 0, status
    assert_equal "", err.string
    assert_includes out.string, "program demo.bouncing_ball"
    assert_includes out.string, "include \"raylib.h\""
    assert_includes out.string, "fn main() -> i32 [entry]:"
  end

  def test_emit_c_command_reports_generated_c
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["emit-c", demo_path], out:, err:)

    assert_equal 0, status
    assert_equal "", err.string
    assert_match(/#include "raylib\.h"/, out.string)
    assert_match(/demo_bouncing_ball_Ball_update\(&ball, dt\);/, out.string)
    assert_equal 1, out.string.scan("CloseWindow();").length
  end

  def test_emit_c_command_reports_unsupported_roots
    out = StringIO.new
    err = StringIO.new
    raylib_path = File.expand_path("../std/c/raylib.mt", __dir__)

    status = MilkTea::CLI.start(["emit-c", raylib_path], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/cannot emit C for extern module std\.c\.raylib/, err.string)
  end

  def test_build_command_compiles_with_fake_compiler
    Dir.mktmpdir("milk-tea-cli-build") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      output_path = File.join(dir, "milk-tea-demo")
      c_path = File.join(dir, "milk-tea-demo.c")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["build", demo_path, "--cc", compiler_path, "-o", output_path, "--keep-c", c_path], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/built .*milk-tea-demo\.mt -> .*milk-tea-demo/, out.string)
      assert_match(/saved C to .*milk-tea-demo\.c/, out.string)
      assert File.exist?(output_path)
      assert File.exist?(c_path)
      assert_includes File.read(compiler_log).lines(chomp: true), "-lraylib"
    end
  end

  def test_build_command_requires_option_values
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["build", demo_path, "--cc"], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/missing value for --cc/, err.string)
  end

  def test_run_command_executes_built_program_and_returns_its_status
    Dir.mktmpdir("milk-tea-cli-run") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_script_compiler(dir, compiler_log, stdout: "run-ok\n", stderr: "run-err\n", exit_status: 7)
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["run", demo_path, "--cc", compiler_path], out:, err:)

      assert_equal 7, status
      assert_equal "run-ok\n", out.string
      assert_equal "run-err\n", err.string
      assert_includes File.read(compiler_log).lines(chomp: true), "-lraylib"
    end
  end

  def test_bindgen_command_writes_output_file
    clang = ENV.fetch("CLANG", "clang")
    skip "clang not available: #{clang}" unless executable_available?(clang)

    Dir.mktmpdir("milk-tea-cli-bindgen") do |dir|
      header_path = File.join(dir, "sample.h")
      output_path = File.join(dir, "sample.mt")
      out = StringIO.new
      err = StringIO.new

      File.write(header_path, <<~C)
        typedef struct Vec2 {
          float x;
          float y;
        } Vec2;

        int add(int a, int b);
      C

      status = MilkTea::CLI.start(["bindgen", "std.c.sample", header_path, "--link", "sample", "-o", output_path], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/generated .*sample\.h -> .*sample\.mt/, out.string)
      assert File.exist?(output_path)
      assert_match(/extern module std\.c\.sample:/, File.read(output_path))
    end
  end

  def test_raylib_manifest_command_writes_output_file
    Dir.mktmpdir("milk-tea-cli-raylib-manifest") do |dir|
      examples_root = write_raylib_examples_fixture(dir)
      output_path = File.join(dir, "manifest.json")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["raylib-manifest", examples_root, "-o", output_path], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/generated .*examples -> .*manifest\.json/, out.string)

      manifest = JSON.parse(File.read(output_path))
      assert_equal 2, manifest.fetch("total_examples")
      assert_equal 1, manifest.fetch("category_counts").fetch("core")
      assert_equal 1, manifest.fetch("category_counts").fetch("shaders")
    end
  end

  def test_parse_command_requires_a_path
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["parse"], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/missing source file path/, err.string)
    assert_match(/Usage: mtc lex PATH/, err.string)
    assert_match(/mtc parse PATH/, err.string)
  end

  def test_invalid_commands_print_usage
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["unknown"], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/Usage: mtc lex PATH/, err.string)
    assert_match(/mtc parse PATH/, err.string)
    assert_match(/mtc check PATH/, err.string)
    assert_match(/mtc lower PATH/, err.string)
    assert_match(/mtc emit-c PATH/, err.string)
    assert_match(/mtc build PATH/, err.string)
    assert_match(/mtc run PATH/, err.string)
    assert_match(/mtc bindgen MODULE HEADER/, err.string)
    assert_match(/mtc raylib-manifest EXAMPLES_ROOT/, err.string)
  end

  def test_parse_command_reports_loader_errors
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["parse", __dir__], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/expected a source file, got a directory/, err.string)
  end

  private

  def demo_path
    File.expand_path("../examples/milk-tea-demo.mt", __dir__)
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

  def write_raylib_examples_fixture(dir)
    examples_root = File.join(dir, "examples")
    FileUtils.mkdir_p(File.join(examples_root, "core"))
    FileUtils.mkdir_p(File.join(examples_root, "shaders"))

    File.write(File.join(examples_root, "examples_list.txt"), <<~TXT)
      core;core_basic_window;★☆☆☆;1.0;1.0;2013;2025;"Ramon Santamaria";@raysan5
      shaders;shaders_texture_waves;★★☆☆;2.5;3.7;2019;2025;"Anata";@anatagawa
    TXT

    File.write(File.join(examples_root, "core", "core_basic_window.c"), <<~C)
      #include "raylib.h"

      int main(void)
      {
          InitWindow(800, 450, "raylib [core] example - basic window");
          return 0;
      }
    C

    File.write(File.join(examples_root, "shaders", "shaders_texture_waves.c"), <<~C)
      #include "raylib.h"
      #include "raymath.h"
      #include "rlights.h"

      int main(void)
      {
          Texture2D texture = LoadTexture("resources/space.png");
          Shader shader = LoadShader(0, TextFormat("resources/shaders/glsl%i/wave.fs", GLSL_VERSION));
          SetAudioStreamCallback(stream, callback);
          return 0;
      }
    C

    examples_root
  end

  def executable_available?(program)
    return File.executable?(program) if program.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, program)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
