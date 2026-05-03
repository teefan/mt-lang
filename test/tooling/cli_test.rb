# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "../test_helper"

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

  def test_semantic_tokens_command_reports_imported_module_function_reference_as_function
    Dir.mktmpdir("milk-tea-cli-semantic-tokens") do |dir|
      c_dir = File.join(dir, "std", "c")
      FileUtils.mkdir_p(c_dir)

      File.write(File.join(c_dir, "sdl3.mt"), <<~MT)
        extern module std.c.sdl3:
            extern def SDL_SetWindowFillDocument(window: ptr[void], fill: bool) -> bool
      MT

      source_path = File.join(dir, "std", "sdl3.mt")
      FileUtils.mkdir_p(File.dirname(source_path))
      source = <<~MT
        module std.sdl3

        import std.c.sdl3 as c

        pub foreign def set_window_fill_document(window: ptr[void], fill: bool) -> bool = c.SDL_SetWindowFillDocument
      MT
      File.write(source_path, source)

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["-I", dir, "semantic-tokens", source_path], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string

      payload = JSON.parse(out.string)
      alias_entry = semantic_entry_for_lexeme(source, payload.fetch("entries"), "c")
      member_entry = semantic_entry_for_lexeme(source, payload.fetch("entries"), "SDL_SetWindowFillDocument")

      assert_equal "namespace", alias_entry.fetch("tokenType")
      assert_equal "function", member_entry.fetch("tokenType")
    end
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

  def test_fmt_command_prints_formatted_source
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["fmt", demo_path], out:, err:)

    assert_equal 0, status
    assert_equal "", err.string
    assert_includes out.string, "module demo.bouncing_ball"
    assert_includes out.string, "def main() -> i32:"
  end

  def test_fmt_command_check_mode_reports_changes
    Dir.mktmpdir("milk-tea-cli-fmt-check") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, "module demo.fmt\n\ndef main()->i32:\n    return 0\n")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["fmt", path, "--check"], out:, err:)

      assert_equal 1, status
      assert_equal "", err.string
      assert_match(/needs formatting/, out.string)
    end
  end

  def test_fmt_command_write_mode_rewrites_file
    Dir.mktmpdir("milk-tea-cli-fmt-write") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, "module demo.fmt\n\ndef main()->i32:\n    return 0\n")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["fmt", path, "--write"], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/formatted/, out.string)
      assert_equal "module demo.fmt\n\ndef main() -> i32:\n    return 0\n", File.read(path)
    end
  end

  def test_fmt_command_preserve_mode_keeps_comments
    Dir.mktmpdir("milk-tea-cli-fmt-preserve") do |dir|
      path = File.join(dir, "sample.mt")
      source = "# header\nmodule demo.fmt\n"
      File.write(path, source)
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["fmt", path, "--preserve"], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_equal source, out.string
    end
  end

  def test_fmt_command_canonical_preserves_comments
    Dir.mktmpdir("milk-tea-cli-fmt-canonical") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, "# header\nmodule demo.fmt\n")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["fmt", path, "--canonical"], out:, err:)

      assert_equal 0, status
      assert_includes out.string, "# header"
      assert_includes out.string, "module demo.fmt"
    end
  end

  def test_fmt_command_safe_default_formats_with_comments
    Dir.mktmpdir("milk-tea-cli-fmt-safe") do |dir|
      path = File.join(dir, "sample.mt")
      source = "# head\nmodule demo.safe\n"
      File.write(path, source)
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["fmt", path], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_includes out.string, "# head"
      assert_includes out.string, "module demo.safe"
    end
  end

  def test_lint_command_reports_unused_local
    Dir.mktmpdir("milk-tea-cli-lint-unused") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        module demo.lint

        def main() -> i32:
            let unused = 1
            return 0
      MT
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["lint", path], out:, err:)

      assert_equal 1, status
      assert_equal "", err.string
      assert_match(/sample\.mt:4: unused-local: unused local 'unused'/, out.string)
    end
  end

  def test_lint_command_reports_clean_source
    Dir.mktmpdir("milk-tea-cli-lint-clean") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        module demo.lint

        def main() -> i32:
            let used = 1
            return used
      MT
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["lint", path], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/clean .*sample\.mt/, out.string)
    end
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
    raylib_path = File.expand_path("../../std/c/raylib.mt", __dir__)

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

  def test_deps_bootstrap_command_reports_results
    require_relative "../../lib/milk_tea/bindings"

    upstream_sources_singleton = class << MilkTea::UpstreamSources
      self
    end

    source = MilkTea::UpstreamSources::Source.new(
      name: "raylib",
      checkout_root: Pathname.new("/tmp/raylib-upstream"),
      repository_url: "https://example.invalid/raylib.git",
      revision: "deadbeef",
      sentinel_paths: ["src/raylib.h"],
    )
    results = [
      MilkTea::UpstreamSources::Result.new(source:, status: :present, path: source.checkout_root.to_s),
    ]
    original = upstream_sources_singleton.instance_method(:bootstrap_all!)
    upstream_sources_singleton.send(:remove_method, :bootstrap_all!)
    upstream_sources_singleton.send(:define_method, :bootstrap_all!) do |**|
      results
    end

    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["deps", "bootstrap"], out:, err:)

    assert_equal 0, status
    assert_equal "", err.string
    assert_match(/kept raylib -> \/tmp\/raylib-upstream/, out.string)
  ensure
    if original
      upstream_sources_singleton.send(:remove_method, :bootstrap_all!)
      upstream_sources_singleton.send(:define_method, :bootstrap_all!, original)
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
    assert_match(/mtc fmt PATH\|DIR \[--check\|--write\] \[--safe\|--canonical\|--preserve\]/, err.string)
  end

  def test_invalid_commands_print_usage
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["unknown"], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/Usage: mtc lex PATH/, err.string)
    assert_match(/mtc parse PATH/, err.string)
    assert_match(/mtc fmt PATH\|DIR \[--check\|--write\] \[--safe\|--canonical\|--preserve\]/, err.string)
    assert_match(/mtc check PATH/, err.string)
    assert_match(/mtc lower PATH/, err.string)
    assert_match(/mtc emit-c PATH/, err.string)
    assert_match(/mtc build PATH/, err.string)
    assert_match(/mtc run PATH/, err.string)
    assert_match(/mtc deps bootstrap/, err.string)
    assert_match(/mtc bindgen MODULE HEADER/, err.string)
    assert_match(/mtc dap/, err.string)
  end

  def test_parse_command_reports_loader_errors
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["parse", __dir__], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/expected a source file, got a directory/, err.string)
  end

  def test_lint_command_select_flag_limits_rules
    Dir.mktmpdir("milk-tea-cli-lint-select") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        module demo.lint

        def compute(x: i32) -> i32:
            let unused = 1
            return 0
      MT
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["lint", path, "--select", "unused-local"], out:, err:)

      # unused-param (for x) would fire without --select, only unused-local expected
      assert_equal 1, status
      assert_match(/unused-local/, out.string)
      refute_match(/unused-param/, out.string)
    end
  end

  def test_lint_command_ignore_flag_excludes_rules
    Dir.mktmpdir("milk-tea-cli-lint-ignore") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        module demo.lint

        def compute(x: i32) -> i32:
            let unused = 1
            return 0
      MT
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["lint", path, "--ignore", "unused-param"], out:, err:)

      assert_equal 1, status
      refute_match(/unused-param/, out.string)
      assert_match(/unused-local/, out.string)
    end
  end

  def test_lint_command_missing_return_reported
    Dir.mktmpdir("milk-tea-cli-lint-missing-return") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        module demo.lint

        def compute() -> i32:
            let _x = 1
      MT
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["lint", path], out:, err:)

      assert_equal 1, status
      assert_match(/missing-return/, out.string)
    end
  end

  def test_lint_command_directory_lints_all_mt_files
    Dir.mktmpdir("milk-tea-cli-lint-dir") do |dir|
      File.write(File.join(dir, "a.mt"), <<~MT)
        module demo.a

        def main() -> i32:
            let unused_a = 1
            return 0
      MT
      File.write(File.join(dir, "b.mt"), <<~MT)
        module demo.b

        def main() -> i32:
            let unused_b = 1
            return 0
      MT
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["lint", dir], out:, err:)

      assert_equal 1, status
      assert_match(/unused_a/, out.string)
      assert_match(/unused_b/, out.string)
    end
  end

  def test_lint_command_directory_clean_exits_zero
    Dir.mktmpdir("milk-tea-cli-lint-dir-clean") do |dir|
      File.write(File.join(dir, "clean.mt"), <<~MT)
        module demo.clean

        def main() -> i32:
            return 0
      MT
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["lint", dir], out:, err:)

      assert_equal 0, status
      assert_match(/clean/, out.string)
    end
  end

  def test_lint_command_fix_applies_prefer_let
    Dir.mktmpdir("milk-tea-cli-lint-fix") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        module demo.lint

        def main() -> i32:
            var x = 1
            return x
      MT
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["lint", path, "--fix"], out:, err:)

      assert_equal 0, status
      assert_match(/fixed/, out.string)
      assert_includes File.read(path), "let x = 1"
    end
  end

  def test_lint_command_output_format_json
    Dir.mktmpdir("milk-tea-cli-lint-json") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        module demo.lint

        def main() -> i32:
            let unused = 1
            return 0
      MT
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["lint", path, "--output-format", "json"], out:, err:)

      assert_equal 1, status
      parsed = JSON.parse(out.string)
      assert_kind_of Array, parsed
      assert_equal 1, parsed.size
      assert_equal "unused-local", parsed.first["code"]
      assert_equal "warning",      parsed.first["severity"].to_s
    end
  end

  def test_lint_command_output_format_json_clean_returns_empty_array
    Dir.mktmpdir("milk-tea-cli-lint-json-clean") do |dir|
      path = File.join(dir, "clean.mt")
      File.write(path, <<~MT)
        module demo.lint

        def main() -> i32:
            return 0
      MT
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["lint", path, "--output-format", "json"], out:, err:)

      assert_equal 0, status
      parsed = JSON.parse(out.string)
      assert_equal [], parsed
    end
  end

  def test_lint_command_summary_line_shown_on_warnings
    Dir.mktmpdir("milk-tea-cli-lint-summary") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        module demo.lint

        def main() -> i32:
            let a = 1
            let b = 2
            return 0
      MT
      out = StringIO.new
      err = StringIO.new

      MilkTea::CLI.start(["lint", path], out:, err:)

      assert_match(/Found 2 warnings in 1 file\./, out.string)
    end
  end

  def test_fmt_command_directory_check_mode
    Dir.mktmpdir("milk-tea-cli-fmt-dir") do |dir|
      unformatted = File.join(dir, "a.mt")
      already_ok  = File.join(dir, "b.mt")

      # Unformatted: missing module header, but valid enough for formatter
      File.write(unformatted, "module demo.fmt\ndef  main()->i32:\n    return 0\n")
      File.write(already_ok,  "module demo.fmt\n")

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["fmt", dir, "--check"], out:, err:)

      # At least one file needs formatting → exit 1
      assert_equal 1, status
      assert_match(/needs formatting/, out.string)
    end
  end

  def test_fmt_command_directory_write_mode
    Dir.mktmpdir("milk-tea-cli-fmt-dir-write") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, "module demo.fmt\ndef  main()->i32:\n    return 0\n")

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["fmt", dir, "--write"], out:, err:)

      assert_equal 0, status
      assert_match(/formatted \d+ of \d+ file/, out.string)
    end
  end

  def test_fmt_command_directory_no_flag_errors
    Dir.mktmpdir("milk-tea-cli-fmt-dir-noflag") do |dir|
      File.write(File.join(dir, "a.mt"), "module demo.fmt\n")

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["fmt", dir], out:, err:)

      assert_equal 1, status
      assert_match(/--check or --write/, err.string)
    end
  end

  private

  def semantic_entry_for_lexeme(source, entries, lexeme)
    lines = source.lines
    entries.find do |entry|
      line_text = lines.fetch(entry.fetch("line"))
      line_text[entry.fetch("startChar"), lexeme.length] == lexeme
    end or flunk("expected semantic token entry for #{lexeme.inspect}")
  end

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

  def executable_available?(program)
    return File.executable?(program) if program.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, program)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
