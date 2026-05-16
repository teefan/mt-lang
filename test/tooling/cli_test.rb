# frozen_string_literal: true

require "digest"
require "open3"
require "stringio"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaCliTest < Minitest::Test
  def test_lex_command_reports_tokens
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["lex", language_fixture_path], out:, err:)

    assert_equal 0, status
    assert_equal "", err.string
    assert_match(/MilkTea::Token/, out.string)
    assert_match(/type=:import/, out.string)
  end

  def test_semantic_tokens_command_reports_imported_module_function_reference_as_function
    Dir.mktmpdir("milk-tea-cli-semantic-tokens") do |dir|
      c_dir = File.join(dir, "std", "c")
      FileUtils.mkdir_p(c_dir)

      File.write(File.join(c_dir, "sdl3.mt"), <<~MT)
        external

        external function SDL_SetWindowFillDocument(window: ptr[void], fill: bool) -> bool
      MT

      source_path = File.join(dir, "std", "sdl3.mt")
      FileUtils.mkdir_p(File.dirname(source_path))
      source = <<~MT
        import std.c.sdl3 as c

        public foreign function set_window_fill_document(window: ptr[void], fill: bool) -> bool = c.SDL_SetWindowFillDocument
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

  def test_semantic_tokens_command_emits_versioned_contract_fields
    out = StringIO.new
    err = StringIO.new

    Dir.chdir(File.expand_path("../..", __dir__)) do
      status = MilkTea::CLI.start(["semantic-tokens", language_fixture_path], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string

      payload = JSON.parse(out.string)

      assert_equal 1, payload.fetch("version")
      assert_equal "semanticTokens", payload.fetch("contract")
      assert_equal "utf-8", payload.fetch("positionEncoding")
      assert_equal "test/fixtures/language_fixture.mt", payload.fetch("path")

      first_entry = payload.fetch("entries").first
      assert first_entry.key?("startByte")
      assert first_entry.key?("endByte")
      assert first_entry.key?("lengthBytes")
    end
  end

  def test_parse_command_reports_ast
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["parse", language_fixture_path], out:, err:)

    assert_equal 0, status
    assert_equal "", err.string
    assert_includes out.string, "import std.maybe as maybe"
    assert_includes out.string, "methods AppState:"
    assert_includes out.string, "function main() -> ExitCode:"
  end

  def test_format_command_prints_formatted_source
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["format", language_fixture_path], out:, err:)

    assert_equal 0, status
    assert_equal "", err.string
    assert_includes out.string, "import std.maybe as maybe"
    assert_includes out.string, "function main() -> ExitCode:"
  end

  def test_format_command_check_mode_reports_changes
    Dir.mktmpdir("milk-tea-cli-fmt-check") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, "function main()->int:\n    return 0\n")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["format", path, "--check"], out:, err:)

      assert_equal 1, status
      assert_equal "", err.string
      assert_match(/needs formatting/, out.string)
    end
  end

  def test_format_command_write_mode_rewrites_file
    Dir.mktmpdir("milk-tea-cli-fmt-write") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, "function main()->int:\n    return 0\n")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["format", path, "--write"], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/formatted/, out.string)
      assert_equal "function main() -> int:\n    return 0\n", File.read(path)
    end
  end

  def test_format_command_preserve_mode_keeps_comments
    Dir.mktmpdir("milk-tea-cli-fmt-preserve") do |dir|
      path = File.join(dir, "sample.mt")
      source = "# header\n"
      File.write(path, source)
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["format", path, "--preserve"], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_equal source, out.string
    end
  end

  def test_format_command_canonical_preserves_comments
    Dir.mktmpdir("milk-tea-cli-fmt-canonical") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, "# header\nfunction  main()->int:\n    return 0\n")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["format", path, "--canonical"], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_includes out.string, "# header"
      assert_includes out.string, "function main() -> int:"
    end
  end

  def test_format_command_safe_default_formats_with_comments
    Dir.mktmpdir("milk-tea-cli-fmt-safe") do |dir|
      path = File.join(dir, "sample.mt")
      source = "# head\nfunction  main()->int:\n    return 0\n"
      File.write(path, source)
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["format", path], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_includes out.string, "# head"
      assert_includes out.string, "function main() -> int:"
    end
  end

  def test_lint_command_reports_unused_local
    Dir.mktmpdir("milk-tea-cli-lint-unused") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        function main() -> int:
            let unused = 1
            return 0
      MT
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["lint", path], out:, err:)

      assert_equal 1, status
      assert_equal "", err.string
      assert_match(/sample\.mt:2: unused-local: unused local 'unused'/, out.string)
    end
  end

  def test_lint_command_reports_clean_source
    Dir.mktmpdir("milk-tea-cli-lint-clean") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        function main() -> int:
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

  def test_lint_command_locked_and_frozen_follow_package_lock
    Dir.mktmpdir("milk-tea-cli-lint-locked") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.3.0"
        kind = "library"
        source_root = "src"
      TOML

      source_path = File.join(app_src_dir, "main.mt")
      File.write(source_path, <<~MT)
        import teefan.ui.layout as layout

        function main() -> int:
            let value = layout.default_width()
            unsafe:
                let copy = value + 1
            return value
      MT

      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      lock_out = StringIO.new
      lock_err = StringIO.new
      lock_status = MilkTea::CLI.start(["deps", "lock", app_root], out: lock_out, err: lock_err)

      assert_equal 0, lock_status
      assert_equal "", lock_err.string

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["lint", source_path, "--ignore", "unused-local"], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/clean .*main\.mt/, out.string)
      refute_match(/redundant-unsafe/, out.string)

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["lint", source_path, "--ignore", "unused-local", "--locked"], out:, err:)

      assert_equal 1, status
      assert_equal "", err.string
      assert_match(/redundant-unsafe/, out.string)

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["lint", source_path, "--ignore", "unused-local", "--frozen"], out:, err:)

      assert_equal 1, status
      assert_equal "", out.string
      assert_match(/package\.lock is out of date/, err.string)
    end
  end

  def test_check_command_reports_success
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["check", language_fixture_path], out:, err:)

    assert_equal 0, status
    assert_match(/checked .*language_fixture\.mt as fixtures\.language_fixture/, out.string)
    assert_equal "", err.string
  end

  def test_diagnostics_command_emits_versioned_json_contract
    Dir.mktmpdir("milk-tea-cli-diagnostics") do |dir|
      path = File.join(dir, "broken.mt")
      File.write(path, "function main() -> int:\n    return nope\n")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["diagnostics", path], out:, err:)

      assert_equal 1, status
      assert_equal "", err.string

      payload = JSON.parse(out.string)

      assert_equal 1, payload.fetch("version")
      assert_equal "diagnostics", payload.fetch("contract")
      assert_equal "utf-8", payload.fetch("positionEncoding")
      assert_equal File.expand_path(path).tr("\\", "/"), payload.fetch("path")
      assert_equal 1, payload.dig("summary", "errorCount")

      diagnostic = payload.fetch("diagnostics").first
      assert_equal "sema/error", diagnostic.fetch("code")
      assert_equal "sema", diagnostic.fetch("stage")
      assert_equal "error", diagnostic.fetch("severity")
      assert diagnostic.dig("range", "start").key?("byte")
      assert diagnostic.dig("range", "end").key?("byte")
    end
  end

  def test_lower_command_reports_ir
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["lower", language_fixture_path], out:, err:)

    assert_equal 0, status
    assert_equal "", err.string
    assert_includes out.string, "program fixtures.language_fixture"
    assert_includes out.string, "const default_step as fixtures_language_fixture_default_step: int = 3"
  end

  def test_emit_c_command_reports_generated_c
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["emit-c", language_fixture_path], out:, err:)

    assert_equal 0, status
    assert_equal "", err.string
    assert_match(/#include <stdio\.h>/, out.string)
    assert_match(/fixtures_language_fixture_AppState_touch\(&state, fixtures_language_fixture_default_step\);/, out.string)
    refute_match(/^#line\s+/m, out.string)
  end

  def test_emit_c_command_reports_unsupported_roots
    out = StringIO.new
    err = StringIO.new
    raylib_path = File.expand_path("../../std/c/raylib.mt", __dir__)

    status = MilkTea::CLI.start(["emit-c", raylib_path], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/cannot emit C for external file std\.c\.raylib/, err.string)
  end

  def test_build_command_compiles_with_fake_compiler
    Dir.mktmpdir("milk-tea-cli-build") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      output_path = File.join(dir, "language-fixture")
      c_path = File.join(dir, "language-fixture.c")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["build", language_fixture_path, "--cc", compiler_path, "-o", output_path, "--keep-c", c_path], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/built .*language_fixture\.mt -> .*language-fixture/, out.string)
      assert_match(/saved C to .*language-fixture\.c/, out.string)
      assert File.exist?(output_path)
      assert File.exist?(c_path)
      refute_match(/^#line\s+/m, File.read(c_path))
      invocation = File.read(compiler_log).lines(chomp: true)
      refute_includes invocation, "-lm"
    end
  end

  def test_build_command_json_emits_versioned_result_contract
    Dir.mktmpdir("milk-tea-cli-build-json") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      output_path = File.join(dir, "language-fixture")
      c_path = File.join(dir, "language-fixture.c")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["build", language_fixture_path, "--cc", compiler_path, "-o", output_path, "--keep-c", c_path, "--json"], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string

      payload = JSON.parse(out.string)

      assert_equal 1, payload.fetch("version")
      assert_equal "buildResult", payload.fetch("contract")
      assert_equal true, payload.fetch("success")
      assert_equal "test/fixtures/language_fixture.mt", payload.fetch("inputPath")
      assert_equal File.expand_path(output_path).tr("\\", "/"), payload.fetch("outputPath")
      assert_equal File.expand_path(c_path).tr("\\", "/"), payload.fetch("cPath")
      assert_equal File.expand_path(compiler_path).tr("\\", "/"), payload.fetch("compiler")
      assert_equal "linux", payload.fetch("platform")
      assert File.exist?(output_path)
      assert File.exist?(c_path)
    end
  end

  def test_build_command_frozen_requires_current_lockfile
    Dir.mktmpdir("milk-tea-cli-build-frozen") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      app_root = File.join(dir, "app")
      src_dir = File.join(app_root, "src", "demo")
      output_path = File.join(dir, "demo-app")

      FileUtils.mkdir_p(src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "demo-app"
        version = "0.1.0"
        source_root = "src"

        [build]
        entry = "src/demo/main.mt"
      TOML

      File.write(File.join(src_dir, "main.mt"), <<~MT)
        function main() -> int:
            return 0
      MT

      lock_out = StringIO.new
      lock_err = StringIO.new
      lock_status = MilkTea::CLI.start(["deps", "lock", app_root], out: lock_out, err: lock_err)

      assert_equal 0, lock_status
      assert_equal "", lock_err.string

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["build", app_root, "--cc", compiler_path, "--frozen", "-o", output_path], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/built .*\/app -> .*demo-app/, out.string)
      assert File.exist?(output_path)
      first_invocation = File.read(compiler_log)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "demo-app"
        version = "0.2.0"
        source_root = "src"

        [build]
        entry = "src/demo/main.mt"
      TOML

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["build", app_root, "--cc", compiler_path, "--frozen", "-o", output_path], out:, err:)

      assert_equal 1, status
      assert_equal "", out.string
      assert_match(/package\.lock is out of date/, err.string)
      assert_equal first_invocation, File.read(compiler_log)
    end
  end

  def test_build_command_compiles_wasm_with_fake_compiler
    Dir.mktmpdir("milk-tea-cli-build-wasm") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      output_path = File.join(dir, "language-fixture")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["build", language_fixture_path, "--cc", compiler_path, "--platform", "wasm", "-o", output_path], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/built .*language_fixture\.mt -> .*language-fixture\.html/, out.string)
      assert File.exist?("#{output_path}.html")

      invocation = File.read(compiler_log).lines(chomp: true)
      assert_includes invocation, "--shell-file"
      assert_includes invocation, File.expand_path("#{output_path}.html")
    end
  end

  def test_build_command_requires_option_values
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["build", language_fixture_path, "--cc"], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/missing value for --cc/, err.string)
  end

  def test_build_command_clean_removes_package_build_root
    Dir.mktmpdir("milk-tea-cli-build-clean") do |dir|
      source_dir = File.join(dir, "src")
      build_dir = File.join(dir, "build")
      FileUtils.mkdir_p(source_dir)
      FileUtils.mkdir_p(File.join(build_dir, "bin", "linux", "debug"))
      File.write(File.join(source_dir, "main.mt"), <<~MT)
        function main() -> int:
            return 0
      MT
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "demo-clean"

        [build]
        entry = "src/main.mt"
      TOML
      marker_path = File.join(build_dir, "bin", "linux", "debug", "stale")
      File.write(marker_path, "stale")

      out = StringIO.new
      err = StringIO.new

      status = Dir.chdir(dir) { MilkTea::CLI.start(["build", "--clean"], out:, err:) }

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/cleaned .*\/build/, out.string)
      refute File.exist?(marker_path)
      refute File.directory?(build_dir)
    end
  end

  def test_build_command_clean_removes_explicit_output
    Dir.mktmpdir("milk-tea-cli-build-clean-output") do |dir|
      output_path = File.join(dir, "custom-bin")
      File.write(output_path, "stale")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["build", language_fixture_path, "--clean", "-o", output_path], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/cleaned .*custom-bin/, out.string)
      refute File.exist?(output_path)
    end
  end

  def test_build_command_clean_removes_wasm_bundle_outputs
    Dir.mktmpdir("milk-tea-cli-build-clean-wasm") do |dir|
      output_path = File.join(dir, "custom-web.html")
      File.write(output_path, "html")
      File.write(File.join(dir, "custom-web.js"), "js")
      File.write(File.join(dir, "custom-web.wasm"), "wasm")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["build", language_fixture_path, "--clean", "--platform", "wasm", "-o", output_path], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/cleaned .*custom-web\.html/, out.string)
      refute File.exist?(output_path)
      refute File.exist?(File.join(dir, "custom-web.js"))
      refute File.exist?(File.join(dir, "custom-web.wasm"))
    end
  end

  def test_build_command_bundle_outputs_native_bundle_directory
    Dir.mktmpdir("milk-tea-cli-build-bundle") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      package_root = File.join(dir, "desktop-demo")
      src_dir = File.join(package_root, "src")
      assets_dir = File.join(package_root, "assets")
      FileUtils.mkdir_p(src_dir)
      FileUtils.mkdir_p(assets_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "desktop_demo"

        [platform]
        default = "linux"

        [build]
        entry = "src/main.mt"
        assets = "assets"
      TOML

      File.write(File.join(src_dir, "main.mt"), <<~MT)
        function main() -> int:
            return 0
      MT
      File.write(File.join(assets_dir, "note.txt"), "hello")

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["build", package_root, "--cc", compiler_path, "--bundle"], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/built .*desktop-demo -> .*build\/dist\/linux\/debug\/desktop_demo/, out.string)
      assert_match(/entry executable .*build\/dist\/linux\/debug\/desktop_demo\/desktop_demo/, out.string)
      assert File.exist?(File.join(package_root, "build", "dist", "linux", "debug", "desktop_demo", "desktop_demo"))
      assert File.exist?(File.join(package_root, "build", "dist", "linux", "debug", "desktop_demo", "assets.mtpack"))
      refute File.exist?(File.join(package_root, "build", "dist", "linux", "debug", "desktop_demo", "assets", "note.txt"))
    end
  end

  def test_build_command_help_mentions_bundle_option
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["build", "--help"], out:, err:)

    assert_equal 0, status
    assert_equal "", err.string
    assert_match(/--bundle\s+Package a native package build into a distributable directory\./, out.string)
    assert_match(/--archive\s+Also write a \.tar\.gz archive for the native bundle \(implies --bundle\)\./, out.string)
  end

  def test_build_command_archive_outputs_tarball_for_native_bundle
    Dir.mktmpdir("milk-tea-cli-build-archive") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      package_root = File.join(dir, "desktop-demo")
      src_dir = File.join(package_root, "src")
      assets_dir = File.join(package_root, "assets")
      FileUtils.mkdir_p(src_dir)
      FileUtils.mkdir_p(assets_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "desktop_demo"

        [platform]
        default = "linux"

        [build]
        entry = "src/main.mt"
        assets = "assets"
      TOML

      File.write(File.join(src_dir, "main.mt"), <<~MT)
        function main() -> int:
            return 0
      MT
      File.write(File.join(assets_dir, "note.txt"), "hello")

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["build", package_root, "--cc", compiler_path, "--archive"], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/built .*desktop-demo -> .*build\/dist\/linux\/debug\/desktop_demo/, out.string)
      assert_match(/entry executable .*build\/dist\/linux\/debug\/desktop_demo\/desktop_demo/, out.string)
      assert_match(/archive .*build\/dist\/linux\/debug\/desktop_demo\.tar\.gz/, out.string)
      assert File.exist?(File.join(package_root, "build", "dist", "linux", "debug", "desktop_demo.tar.gz"))
      assert File.exist?(File.join(package_root, "build", "dist", "linux", "debug", "desktop_demo", "assets.mtpack"))
      refute File.exist?(File.join(package_root, "build", "dist", "linux", "debug", "desktop_demo", "assets", "note.txt"))
    end
  end

  def test_run_command_executes_built_program_and_returns_its_status
    Dir.mktmpdir("milk-tea-cli-run") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_script_compiler(dir, compiler_log, stdout: "run-ok\n", stderr: "run-err\n", exit_status: 7)
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["run", language_fixture_path, "--cc", compiler_path], out:, err:)

      assert_equal 7, status
      assert_equal "run-ok\n", out.string
      assert_equal "run-err\n", err.string
      invocation = File.read(compiler_log).lines(chomp: true)
      refute_includes invocation, "-lm"
    end
  end

  def test_run_command_json_emits_versioned_result_contract
    Dir.mktmpdir("milk-tea-cli-run-json") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_script_compiler(dir, compiler_log, stdout: "run-ok\n", stderr: "run-err\n", exit_status: 7)
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["run", language_fixture_path, "--cc", compiler_path, "--json"], out:, err:)

      assert_equal 7, status
      assert_equal "", err.string

      payload = JSON.parse(out.string)

      assert_equal 1, payload.fetch("version")
      assert_equal "runResult", payload.fetch("contract")
      assert_equal true, payload.fetch("success")
      assert_equal "test/fixtures/language_fixture.mt", payload.fetch("inputPath")
      assert_equal "run-ok\n", payload.fetch("stdout")
      assert_equal "run-err\n", payload.fetch("stderr")
      assert_equal 7, payload.fetch("exitStatus")
      assert_equal File.expand_path(compiler_path).tr("\\", "/"), payload.fetch("compiler")
      assert_equal "linux", payload.fetch("platform")
    end
  end

  def test_run_command_archive_executes_packaged_program
    Dir.mktmpdir("milk-tea-cli-run-archive") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_script_compiler(dir, compiler_log, stdout: "run-archive\n", stderr: "run-archive-err\n", exit_status: 11)
      package_root = File.join(dir, "desktop-demo")
      src_dir = File.join(package_root, "src")
      assets_dir = File.join(package_root, "assets")
      output_root = File.join(dir, "bundle-out")
      out = StringIO.new
      err = StringIO.new
      FileUtils.mkdir_p(src_dir)
      FileUtils.mkdir_p(assets_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "desktop_demo"

        [platform]
        default = "linux"

        [build]
        entry = "src/main.mt"
        assets = "assets"
      TOML

      File.write(File.join(src_dir, "main.mt"), <<~MT)
        function main() -> int:
            return 0
      MT
      File.write(File.join(assets_dir, "note.txt"), "hello")

      status = MilkTea::CLI.start(["run", package_root, "--cc", compiler_path, "--archive", "-o", output_root], out:, err:)

      assert_equal 11, status
      assert_equal "run-archive\n", out.string
      assert_equal "run-archive-err\n", err.string
      assert File.exist?(File.join(output_root, "desktop_demo"))
      assert File.exist?(File.join(output_root, "assets.mtpack"))
      assert File.exist?("#{output_root}.tar.gz")
      refute File.exist?(File.join(output_root, "assets", "note.txt"))
    end
  end

  def test_run_command_reports_how_to_stop_wasm_preview
    out = StringIO.new
    err = StringIO.new

    fake_result = MilkTea::Run::Result.new(
      stdout: "serving http://127.0.0.1:43123/web.html (press Ctrl-C to stop)\n",
      stderr: "",
      exit_status: 0,
      output_path: "/tmp/web.html",
      c_path: nil,
      compiler: "/tmp/fake-emcc",
      link_flags: [],
      platform: :wasm,
      bundle_root: nil,
      archive_path: nil,
    )

    runner = lambda do |_path, **kwargs|
      kwargs.fetch(:preview_started).call(fake_result.stdout)
      fake_result
    end

    status = with_singleton_method_override(MilkTea::Run, :run, runner) do
      MilkTea::CLI.start(["run", language_fixture_path, "--platform", "wasm"], out:, err:)
    end

    assert_equal 0, status
    assert_equal "", err.string
    assert_equal fake_result.stdout, out.string
    refute_match(/stop-preview/, out.string)
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
      assert_match(/\A# generated by mtc bindgen from .*\nexternal\n/, File.read(output_path))
    end
  end

  def test_bindgen_command_writes_nullable_report_file
    clang = ENV.fetch("CLANG", "clang")
    skip "clang not available: #{clang}" unless executable_available?(clang)

    Dir.mktmpdir("milk-tea-cli-bindgen-report") do |dir|
      header_path = File.join(dir, "sample.h")
      output_path = File.join(dir, "sample.mt")
      report_path = File.join(dir, "sample.nullable.json")
      out = StringIO.new
      err = StringIO.new

      File.write(header_path, <<~C)
        void * _Nullable returns_nullable(void);
        void * returns_manual(void);
      C

      status = MilkTea::CLI.start([
        "bindgen",
        "std.c.sample",
        header_path,
        "--nullable-report",
        report_path,
        "-o",
        output_path,
      ], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/generated .*sample\.h -> .*sample\.mt/, out.string)
      assert_match(/nullable report .*sample\.h -> .*sample\.nullable\.json/, out.string)
      assert File.exist?(report_path)
      report = JSON.parse(File.read(report_path))
      assert_equal 0, report.dig("summary", "total")
    end
  end

  def test_toolchain_bootstrap_command_reports_results
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

    status = MilkTea::CLI.start(["toolchain", "bootstrap"], out:, err:)

    assert_equal 0, status
    assert_equal "", err.string
    assert_match(/kept raylib -> \/tmp\/raylib-upstream/, out.string)
  ensure
    if original
      upstream_sources_singleton.send(:remove_method, :bootstrap_all!)
      upstream_sources_singleton.send(:define_method, :bootstrap_all!, original)
    end
  end

  def test_deps_command_without_subcommand_prints_deps_help
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["deps"], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/missing deps subcommand/, err.string)
    assert_match(/Usage: mtc deps SUBCOMMAND/, err.string)
    refute_match(/Usage: mtc lex PATH/, err.string)
    refute_match(/mtc toolchain bootstrap/, err.string)
  end

  def test_toolchain_command_without_subcommand_prints_toolchain_help
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["toolchain"], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/missing toolchain subcommand/, err.string)
    assert_match(/Usage: mtc toolchain SUBCOMMAND/, err.string)
    refute_match(/Usage: mtc lex PATH/, err.string)
    refute_match(/mtc deps add/, err.string)
  end

  def test_deps_tree_command_prints_local_path_dependency_graph
    Dir.mktmpdir("milk-tea-cli-deps-tree") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      math_root = File.join(dir, "libs", "math")

      FileUtils.mkdir_p(app_root)
      FileUtils.mkdir_p(ui_root)
      FileUtils.mkdir_p(math_root)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        kind = "library"

        [dependencies]
        "teefan.math" = { path = "../math" }
      TOML

      File.write(File.join(math_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.math"
        kind = "library"
      TOML

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["deps", "tree", app_root], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_equal ["snake_duel", "  teefan.ui", "    teefan.math"], out.string.lines(chomp: true)
    end
  end

  def test_deps_tree_command_reports_missing_registry_package_for_exact_version_dependencies
    Dir.mktmpdir("milk-tea-cli-deps-tree-version") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      registry_root = File.join(dir, "registry")
      FileUtils.mkdir_p(File.join(app_root, "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"

        [dependencies]
        "teefan.ui" = "0.3.0"
      TOML

      out = StringIO.new
      err = StringIO.new

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root) do
        status = MilkTea::CLI.start(["deps", "tree", app_root], out:, err:)

        assert_equal 1, status
        assert_equal "", out.string
        assert_match(/registry package teefan\.ui version 0\.3\.0 not found/i, err.string)
      end
    end
  end

  def test_deps_tree_command_solves_non_exact_registry_requirements_to_highest_matching_version
    Dir.mktmpdir("milk-tea-cli-deps-tree-range") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_v1_root = File.join(dir, "ui-v1")
      ui_v2_root = File.join(dir, "ui-v2")
      registry_root = File.join(dir, "registry")
      cache_home = File.join(dir, "cache-home")
      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v1_root, "src", "teefan", "ui"))
      FileUtils.mkdir_p(File.join(ui_v2_root, "src", "teefan", "ui"))

      File.write(File.join(ui_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(ui_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.4.0"
        kind = "library"
        source_root = "src"
      TOML

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root) do
        MilkTea::PackageRegistryStore.new.publish(ui_v1_root)
        MilkTea::PackageRegistryStore.new.publish(ui_v2_root)
      end

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"

        [dependencies]
        "teefan.ui" = "^1.2.3"
      TOML

      out = StringIO.new
      err = StringIO.new

      identity = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.4.0")

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root, "XDG_CACHE_HOME" => cache_home) do
        status = MilkTea::CLI.start(["deps", "tree", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_equal ["snake_duel", "  teefan.ui"], out.string.lines(chomp: true)
        cache = MilkTea::PackageSourceCache.new(root: File.join(cache_home, "milk_tea", "package_sources"))
        assert File.file?(cache.manifest_path_for(identity))
      end
    end
  end

  def test_deps_lock_allows_duplicate_ranged_registry_versions_across_dependency_instances
    Dir.mktmpdir("milk-tea-cli-deps-lock-range") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_v1_root = File.join(dir, "ui-v1")
      ui_v2_root = File.join(dir, "ui-v2")
      theme_v1_root = File.join(dir, "theme-v1")
      theme_v2_root = File.join(dir, "theme-v2")
      registry_root = File.join(dir, "registry")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(File.join(app_root, "src"))
      [ui_v1_root, ui_v2_root, theme_v1_root, theme_v2_root].each do |root|
        FileUtils.mkdir_p(File.join(root, "src"))
      end

      File.write(File.join(theme_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.theme"
        version = "1.0.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(theme_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.theme"
        version = "1.1.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(ui_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.0.0"
        kind = "library"
        source_root = "src"

        [dependencies]
        "teefan.theme" = ">=1.0.0, <1.1.0"
      TOML

      File.write(File.join(ui_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.1.0"
        kind = "library"
        source_root = "src"

        [dependencies]
        "teefan.theme" = ">=1.1.0, <2.0.0"
      TOML

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root) do
        store = MilkTea::PackageRegistryStore.new
        store.publish(theme_v1_root)
        store.publish(theme_v2_root)
        store.publish(ui_v1_root)
        store.publish(ui_v2_root)
      end

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = "^1.0.0"
        "teefan.theme" = "1.0.0"
      TOML

      out = StringIO.new
      err = StringIO.new

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root, "XDG_CACHE_HOME" => cache_home) do
        status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        lock_contents = File.read(File.join(app_root, "package.lock"))
        assert_match(/name = "teefan\.ui"\nkind = "library"\nversion = "1\.1\.0"/m, lock_contents)
        assert_match(/name = "teefan\.theme"\nkind = "library"\nversion = "1\.0\.0"/m, lock_contents)
        assert_match(/name = "teefan\.theme"\nkind = "library"\nversion = "1\.1\.0"/m, lock_contents)
      end
    end
  end

  def test_deps_add_command_updates_manifest_and_lockfile_for_registry_requirement
    Dir.mktmpdir("milk-tea-cli-deps-add") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_v1_root = File.join(dir, "ui-v1")
      ui_v2_root = File.join(dir, "ui-v2")
      registry_root = File.join(dir, "registry")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v1_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v2_root, "src"))

      File.write(File.join(ui_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(ui_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.4.0"
        kind = "library"
        source_root = "src"
      TOML

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root) do
        store = MilkTea::PackageRegistryStore.new
        store.publish(ui_v1_root)
        store.publish(ui_v2_root)
      end

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      out = StringIO.new
      err = StringIO.new

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root, "XDG_CACHE_HOME" => cache_home) do
        status = MilkTea::CLI.start(["deps", "add", app_root, "teefan.ui@^1.2.3"], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        manifest_source = File.read(File.join(app_root, "package.toml"))
        assert_match(/"teefan\.ui" = "\^1\.2\.3"/, manifest_source)
        lock_contents = File.read(File.join(app_root, "package.lock"))
        assert_match(/name = "teefan\.ui"\nkind = "library"\nversion = "1\.4\.0"/m, lock_contents)
      end
    end
  end

  def test_deps_remove_command_updates_manifest_and_lockfile
    Dir.mktmpdir("milk-tea-cli-deps-remove") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")

      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(ui_root, "src"))

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.1.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["deps", "remove", app_root, "teefan.ui"], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      manifest_source = File.read(File.join(app_root, "package.toml"))
      refute_match(/teefan\.ui/, manifest_source)
      lock_contents = File.read(File.join(app_root, "package.lock"))
      assert_match(/dependencies = \[\]/, lock_contents)
    end
  end

  def test_deps_update_command_refreshes_lockfile_to_newest_matching_registry_version
    Dir.mktmpdir("milk-tea-cli-deps-update") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_v1_root = File.join(dir, "ui-v1")
      ui_v2_root = File.join(dir, "ui-v2")
      registry_root = File.join(dir, "registry")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v1_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v2_root, "src"))

      File.write(File.join(ui_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(ui_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.4.0"
        kind = "library"
        source_root = "src"
      TOML

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root) do
        store = MilkTea::PackageRegistryStore.new
        store.publish(ui_v1_root)
      end

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = "^1.2.3"
      TOML

      out = StringIO.new
      err = StringIO.new

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root, "XDG_CACHE_HOME" => cache_home) do
        status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)
        assert_equal 0, status

        lock_contents = File.read(File.join(app_root, "package.lock"))
        assert_match(/version = "1\.2\.3"/, lock_contents)

        MilkTea::PackageRegistryStore.new.publish(ui_v2_root)

        out = StringIO.new
        err = StringIO.new
        status = MilkTea::CLI.start(["deps", "update", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        lock_contents = File.read(File.join(app_root, "package.lock"))
        assert_match(/version = "1\.4\.0"/, lock_contents)
      end
    end
  end

  def test_deps_update_command_can_adopt_newer_registry_version_from_upstream_mirror
    Dir.mktmpdir("milk-tea-cli-deps-update-upstream") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_v1_root = File.join(dir, "ui-v1")
      ui_v2_root = File.join(dir, "ui-v2")
      registry_root = File.join(dir, "registry")
      upstream_registry_root = File.join(dir, "upstream-registry")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v1_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v2_root, "src"))

      File.write(File.join(ui_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(ui_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.4.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = "^1.2.3"
      TOML

      local_registry = MilkTea::PackageRegistryStore.new(root: registry_root, upstream_root: upstream_registry_root)
      new_identity = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.4.0")

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root, "XDG_CACHE_HOME" => cache_home) do
        store = MilkTea::PackageRegistryStore.new
        store.publish(ui_v1_root)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        lock_contents = File.read(File.join(app_root, "package.lock"))
        assert_match(/version = "1\.2\.3"/, lock_contents)
      end

      with_env(
        "MILK_TEA_PACKAGE_REGISTRY" => registry_root,
        "MILK_TEA_PACKAGE_REGISTRY_UPSTREAM" => upstream_registry_root,
        "XDG_CACHE_HOME" => cache_home,
      ) do
        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "publish", ui_v2_root, "--upstream"], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        refute local_registry.published?(new_identity)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "update", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert local_registry.published?(new_identity)

        lock_contents = File.read(File.join(app_root, "package.lock"))
        assert_match(/name = "teefan\.ui"\nkind = "library"\nversion = "1\.4\.0"/m, lock_contents)
      end
    end
  end

  def test_deps_update_command_can_adopt_newer_registry_version_from_http_upstream_mirror
    Dir.mktmpdir("milk-tea-cli-deps-update-http-upstream") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_v1_root = File.join(dir, "ui-v1")
      ui_v2_root = File.join(dir, "ui-v2")
      registry_root = File.join(dir, "registry")
      upstream_registry_root = File.join(dir, "upstream-registry")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v1_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v2_root, "src"))

      File.write(File.join(ui_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(ui_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.4.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = "^1.2.3"
      TOML

      local_registry = MilkTea::PackageRegistryStore.new(root: registry_root, upstream_root: upstream_registry_root)
      new_identity = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.4.0")

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root, "XDG_CACHE_HOME" => cache_home) do
        store = MilkTea::PackageRegistryStore.new
        store.publish(ui_v1_root)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        lock_contents = File.read(File.join(app_root, "package.lock"))
        assert_match(/version = "1\.2\.3"/, lock_contents)
      end

      local_registry.publish(ui_v2_root, target: :upstream)

      with_static_http_server(upstream_registry_root) do |base_url|
        with_env(
          "MILK_TEA_PACKAGE_REGISTRY" => registry_root,
          "MILK_TEA_PACKAGE_REGISTRY_UPSTREAM" => base_url,
          "XDG_CACHE_HOME" => cache_home,
        ) do
          out = StringIO.new
          err = StringIO.new

          status = MilkTea::CLI.start(["deps", "update", app_root], out:, err:)

          assert_equal 0, status
          assert_equal "", err.string
          assert local_registry.published?(new_identity)

          lock_contents = File.read(File.join(app_root, "package.lock"))
          assert_match(/name = "teefan\.ui"\nkind = "library"\nversion = "1\.4\.0"/m, lock_contents)
        end
      end
    end
  end

  def test_deps_update_command_with_package_names_requires_current_lockfile
    Dir.mktmpdir("milk-tea-cli-deps-update-selective-lock") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")

      FileUtils.mkdir_p(File.join(app_root, "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = "^1.2.3"
      TOML

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["deps", "update", app_root, "teefan.ui"], out:, err:)

      assert_equal 1, status
      assert_equal "", out.string
      assert_match(/selective deps update requires a current package\.lock/, err.string)
      assert_match(/mtc deps lock #{Regexp.escape(app_root)}/, err.string)
      assert_match(/mtc deps update #{Regexp.escape(app_root)}/, err.string)
    end
  end

  def test_deps_update_command_with_package_names_rejects_lock_that_no_longer_matches_manifest
    Dir.mktmpdir("milk-tea-cli-deps-update-selective-stale-lock") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_v1_root = File.join(dir, "ui-v1")
      ui_v2_root = File.join(dir, "ui-v2")
      registry_root = File.join(dir, "registry")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v1_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v2_root, "src"))

      File.write(File.join(ui_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(ui_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "2.1.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = "^1.2.3"
      TOML

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root, "XDG_CACHE_HOME" => cache_home) do
        store = MilkTea::PackageRegistryStore.new
        store.publish(ui_v1_root)
        store.publish(ui_v2_root)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string

        File.write(File.join(app_root, "package.toml"), <<~TOML)
          [package]
          name = "snake_duel"
          version = "0.1.0"
          source_root = "src"

          [dependencies]
          "teefan.ui" = "^2.0.0"
        TOML

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "update", app_root, "teefan.ui"], out:, err:)

        assert_equal 1, status
        assert_equal "", out.string
        assert_match(/selective deps update requires a current package\.lock that matches the current manifest/, err.string)
        assert_match(/mtc deps lock #{Regexp.escape(app_root)}/, err.string)
        assert_match(/does not satisfy|no registry version/, err.string)
      end
    end
  end

  def test_deps_update_command_selectively_refreshes_requested_dependency_and_locked_transitive_closure
    Dir.mktmpdir("milk-tea-cli-deps-update-selective") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_v1_root = File.join(dir, "ui-v1")
      ui_v2_root = File.join(dir, "ui-v2")
      theme_v1_root = File.join(dir, "theme-v1")
      theme_v2_root = File.join(dir, "theme-v2")
      palette_v1_root = File.join(dir, "palette-v1")
      palette_v2_root = File.join(dir, "palette-v2")
      registry_root = File.join(dir, "registry")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v1_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v2_root, "src"))
      FileUtils.mkdir_p(File.join(theme_v1_root, "src"))
      FileUtils.mkdir_p(File.join(theme_v2_root, "src"))
      FileUtils.mkdir_p(File.join(palette_v1_root, "src"))
      FileUtils.mkdir_p(File.join(palette_v2_root, "src"))

      File.write(File.join(palette_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.palette"
        version = "1.0.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(palette_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.palette"
        version = "1.1.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(theme_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.theme"
        version = "1.0.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(theme_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.theme"
        version = "1.1.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(ui_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.0.0"
        kind = "library"
        source_root = "src"

        [dependencies]
        "teefan.palette" = "^1.0.0"
      TOML

      File.write(File.join(ui_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.1.0"
        kind = "library"
        source_root = "src"

        [dependencies]
        "teefan.palette" = "^1.1.0"
      TOML

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = "^1.0.0"
        "teefan.theme" = "^1.0.0"
      TOML

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root, "XDG_CACHE_HOME" => cache_home) do
        store = MilkTea::PackageRegistryStore.new
        store.publish(palette_v1_root)
        store.publish(theme_v1_root)
        store.publish(ui_v1_root)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        lock_contents = File.read(File.join(app_root, "package.lock"))
        assert_match(/name = "teefan\.ui"\nkind = "library"\nversion = "1\.0\.0"/m, lock_contents)
        assert_match(/name = "teefan\.theme"\nkind = "library"\nversion = "1\.0\.0"/m, lock_contents)
        assert_match(/name = "teefan\.palette"\nkind = "library"\nversion = "1\.0\.0"/m, lock_contents)

        store.publish(palette_v2_root)
        store.publish(theme_v2_root)
        store.publish(ui_v2_root)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "update", app_root, "teefan.ui"], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        lock_contents = File.read(File.join(app_root, "package.lock"))
        assert_match(/name = "teefan\.ui"\nkind = "library"\nversion = "1\.1\.0"/m, lock_contents)
        assert_match(/name = "teefan\.palette"\nkind = "library"\nversion = "1\.1\.0"/m, lock_contents)
        assert_match(/name = "teefan\.theme"\nkind = "library"\nversion = "1\.0\.0"/m, lock_contents)
        refute_match(/name = "teefan\.theme"\nkind = "library"\nversion = "1\.1\.0"/m, lock_contents)
      end
    end
  end

  def test_deps_update_command_keeps_unrelated_duplicate_registry_instances_pinned
    Dir.mktmpdir("milk-tea-cli-deps-update-duplicate-instances") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_v1_root = File.join(dir, "ui-v1")
      ui_v2_root = File.join(dir, "ui-v2")
      shell_root = File.join(dir, "shell")
      palette_v1_root = File.join(dir, "palette-v1")
      palette_v1_1_root = File.join(dir, "palette-v1-1")
      palette_v2_root = File.join(dir, "palette-v2")
      palette_v2_1_root = File.join(dir, "palette-v2-1")
      registry_root = File.join(dir, "registry")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v1_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v2_root, "src"))
      FileUtils.mkdir_p(File.join(shell_root, "src"))
      FileUtils.mkdir_p(File.join(palette_v1_root, "src"))
      FileUtils.mkdir_p(File.join(palette_v1_1_root, "src"))
      FileUtils.mkdir_p(File.join(palette_v2_root, "src"))
      FileUtils.mkdir_p(File.join(palette_v2_1_root, "src"))

      File.write(File.join(palette_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.palette"
        version = "1.0.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(palette_v1_1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.palette"
        version = "1.1.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(palette_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.palette"
        version = "2.0.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(palette_v2_1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.palette"
        version = "2.1.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(ui_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.0.0"
        kind = "library"
        source_root = "src"

        [dependencies]
        "teefan.palette" = "^1.0.0"
      TOML

      File.write(File.join(ui_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.1.0"
        kind = "library"
        source_root = "src"

        [dependencies]
        "teefan.palette" = "^1.1.0"
      TOML

      File.write(File.join(shell_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.shell"
        version = "0.1.0"
        kind = "library"
        source_root = "src"

        [dependencies]
        "teefan.palette" = "^2.0.0"
      TOML

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.shell" = { path = "../../shell" }
        "teefan.ui" = "^1.0.0"
      TOML

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root, "XDG_CACHE_HOME" => cache_home) do
        store = MilkTea::PackageRegistryStore.new
        store.publish(palette_v1_root)
        store.publish(palette_v2_root)
        store.publish(ui_v1_root)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        lock_contents = File.read(File.join(app_root, "package.lock"))
        assert_match(/name = "teefan\.ui"\nkind = "library"\nversion = "1\.0\.0"/m, lock_contents)
        assert_match(/name = "teefan\.palette"\nkind = "library"\nversion = "1\.0\.0"/m, lock_contents)
        assert_match(/name = "teefan\.palette"\nkind = "library"\nversion = "2\.0\.0"/m, lock_contents)

        store.publish(palette_v1_1_root)
        store.publish(palette_v2_1_root)
        store.publish(ui_v2_root)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "update", app_root, "teefan.ui"], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        lock_contents = File.read(File.join(app_root, "package.lock"))
        assert_match(/name = "teefan\.ui"\nkind = "library"\nversion = "1\.1\.0"/m, lock_contents)
        assert_match(/name = "teefan\.palette"\nkind = "library"\nversion = "1\.1\.0"/m, lock_contents)
        assert_match(/name = "teefan\.palette"\nkind = "library"\nversion = "2\.0\.0"/m, lock_contents)
        refute_match(/name = "teefan\.palette"\nkind = "library"\nversion = "2\.1\.0"/m, lock_contents)
      end
    end
  end

  def test_deps_tree_command_materializes_pinned_git_dependencies
    git = ENV.fetch("GIT", "git")
    skip "git not available: #{git}" unless executable_available?(git)

    Dir.mktmpdir("milk-tea-cli-deps-tree-git") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      origin_root = File.join(dir, "origin-ui")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(origin_root)

      run_git!(git:, dir: origin_root, args: ["init", "--initial-branch=main"])
      FileUtils.mkdir_p(File.join(origin_root, "packages", "ui"))
      File.write(File.join(origin_root, "packages", "ui", "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        kind = "library"
      TOML
      run_git!(git:, dir: origin_root, args: ["add", "."])
      run_git!(git:, dir: origin_root, args: ["commit", "-m", "initial"])

      revision = capture_git(git:, dir: origin_root, args: ["rev-parse", "HEAD"])
      identity = MilkTea::PackageSourceResolver::GitIdentity.new(url: origin_root, revision:, subdir: "packages/ui")
      cache = MilkTea::PackageSourceCache.new(root: File.join(cache_home, "milk_tea", "package_sources"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"

        [dependencies]
        "teefan.ui" = { git = #{origin_root.inspect}, rev = #{revision.inspect}, subdir = "packages/ui" }
      TOML

      out = StringIO.new
      err = StringIO.new

      with_env("XDG_CACHE_HOME" => cache_home) do
        status = MilkTea::CLI.start(["deps", "tree", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_equal ["snake_duel", "  teefan.ui"], out.string.lines(chomp: true)
        assert File.file?(cache.manifest_path_for(identity))
      end
    end
  end

  def test_deps_lock_command_writes_deterministic_local_path_lockfile
    Dir.mktmpdir("milk-tea-cli-deps-lock") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      math_root = File.join(dir, "libs", "math")
      app_src_dir = File.join(app_root, "src")
      ui_src_dir = File.join(ui_root, "src")
      math_src_dir = File.join(math_root, "src")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)
      FileUtils.mkdir_p(math_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.3.0"
        kind = "library"
        source_root = "src"

        [dependencies]
        "teefan.math" = { path = "../math" }
      TOML

      File.write(File.join(math_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.math"
        version = "0.2.0"
        kind = "library"
        source_root = "src"
      TOML

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)

      lock_path = File.join(app_root, "package.lock")
      root_instance_id = Digest::SHA256.hexdigest(["snake_duel", "path", "source_path", app_root].join("\0"))
      math_instance_id = Digest::SHA256.hexdigest(["teefan.math", "path", "source_path", math_root].join("\0"))
      ui_instance_id = Digest::SHA256.hexdigest(["teefan.ui", "path", "source_path", ui_root].join("\0"))

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/wrote .*package\.lock/, out.string)
      assert_equal <<~LOCK, File.read(lock_path)
        schema_version = 2
        root_package = "snake_duel"
        root_package_id = #{root_instance_id.inspect}

        [[package]]
        name = "snake_duel"
        kind = "application"
        version = "0.1.0"
        instance_id = #{root_instance_id.inspect}
        source_kind = "path"
        source_path = #{app_root.inspect}
        manifest_path = #{File.join(app_root, "package.toml").inspect}
        source_root = #{app_src_dir.inspect}
        dependencies = ["teefan.ui"]
        dependency_ids = [#{ui_instance_id.inspect}]

        [[package]]
        name = "teefan.math"
        kind = "library"
        version = "0.2.0"
        instance_id = #{math_instance_id.inspect}
        source_kind = "path"
        source_path = #{math_root.inspect}
        manifest_path = #{File.join(math_root, "package.toml").inspect}
        source_root = #{math_src_dir.inspect}
        dependencies = []
        dependency_ids = []

        [[package]]
        name = "teefan.ui"
        kind = "library"
        version = "0.3.0"
        instance_id = #{ui_instance_id.inspect}
        source_kind = "path"
        source_path = #{ui_root.inspect}
        manifest_path = #{File.join(ui_root, "package.toml").inspect}
        source_root = #{ui_src_dir.inspect}
        dependencies = ["teefan.math"]
        dependency_ids = [#{math_instance_id.inspect}]
      LOCK
    end
  end

  def test_deps_lock_command_supports_transitive_duplicate_path_package_names
    Dir.mktmpdir("milk-tea-cli-deps-lock-duplicate-paths") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      overlay_root = File.join(dir, "libs", "overlay")
      ui_v1_root = File.join(dir, "libs", "ui-v1")
      ui_v2_root = File.join(dir, "libs", "ui-v2")

      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(overlay_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v1_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v2_root, "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.overlay" = { path = "../../libs/overlay" }
        "teefan.ui" = { path = "../../libs/ui-v1" }
      TOML

      File.write(File.join(overlay_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.overlay"
        version = "0.1.0"
        kind = "library"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../ui-v2" }
      TOML

      File.write(File.join(ui_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.0.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(ui_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "2.0.0"
        kind = "library"
        source_root = "src"
      TOML

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string

      lock_contents = File.read(File.join(app_root, "package.lock"))
      assert_match(/schema_version = 2/, lock_contents)
      assert_match(/root_package_id = "/, lock_contents)
      assert_equal 2, lock_contents.scan(/^name = "teefan\.ui"$/).length
      assert_match(/name = "teefan\.ui"\nkind = "library"\nversion = "1\.0\.0"/m, lock_contents)
      assert_match(/name = "teefan\.ui"\nkind = "library"\nversion = "2\.0\.0"/m, lock_contents)
    end
  end

  def test_deps_lock_check_command_reports_missing_current_and_stale_lockfile_states
    Dir.mktmpdir("milk-tea-cli-deps-lock-check") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src")
      ui_src_dir = File.join(ui_root, "src")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.3.0"
        kind = "library"
        source_root = "src"
      TOML

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["deps", "lock", app_root, "--check"], out:, err:)

      assert_equal 1, status
      assert_equal "", err.string
      assert_match(/missing .*package\.lock/, out.string)

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["deps", "lock", app_root, "--check"], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/up to date .*package\.lock/, out.string)

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.4.0"
        kind = "library"
        source_root = "src"
      TOML

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["deps", "lock", app_root, "--check"], out:, err:)

      assert_equal 1, status
      assert_equal "", err.string
      assert_match(/out of date .*package\.lock/, out.string)
    end
  end

  def test_deps_fetch_command_materializes_locked_git_sources_and_enables_locked_check
    git = ENV.fetch("GIT", "git")
    skip "git not available: #{git}" unless executable_available?(git)

    Dir.mktmpdir("milk-tea-cli-deps-fetch") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      origin_root = File.join(dir, "origin-ui")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(origin_root)

      run_git!(git:, dir: origin_root, args: ["init", "--initial-branch=main"])
      FileUtils.mkdir_p(File.join(origin_root, "src", "teefan", "ui"))
      File.write(File.join(origin_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(origin_root, "src", "teefan", "ui", "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT
      run_git!(git:, dir: origin_root, args: ["add", "."])
      run_git!(git:, dir: origin_root, args: ["commit", "-m", "initial"])

      revision = capture_git(git:, dir: origin_root, args: ["rev-parse", "HEAD"])
      identity = MilkTea::PackageSourceResolver::GitIdentity.new(url: origin_root, revision:)
      cache = MilkTea::PackageSourceCache.new(root: File.join(cache_home, "milk_tea", "package_sources"))
      manifest_path = cache.manifest_path_for(identity)
      source_root = File.join(File.dirname(manifest_path), "src")

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      source_path = File.join(app_src_dir, "main.mt")
      File.write(source_path, <<~MT)
        import teefan.ui.layout as layout

        function main() -> int:
            return layout.default_width()
      MT

      File.write(File.join(app_root, "package.lock"), <<~LOCK)
        schema_version = 1
        root_package = "snake_duel"

        [[package]]
        name = "snake_duel"
        kind = "application"
        version = "0.1.0"
        source_kind = "path"
        source_path = #{app_root.inspect}
        manifest_path = #{File.join(app_root, "package.toml").inspect}
        source_root = #{File.join(app_root, "src").inspect}
        dependencies = ["teefan.ui"]

        [[package]]
        name = "teefan.ui"
        kind = "library"
        version = "1.2.3"
        source_kind = "git"
        git_url = #{origin_root.inspect}
        git_rev = #{revision.inspect}
        manifest_path = #{manifest_path.inspect}
        source_root = #{source_root.inspect}
        dependencies = []
      LOCK

      out = StringIO.new
      err = StringIO.new

      with_env("XDG_CACHE_HOME" => cache_home) do
        status = MilkTea::CLI.start(["check", source_path, "--locked"], out:, err:)

        assert_equal 1, status
        assert_equal "", out.string
        assert_match(/not materialized in the source cache/, err.string)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "fetch", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_match(/materialized teefan\.ui -> /, out.string)
        assert File.file?(manifest_path)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["check", source_path, "--locked"], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_match(/checked .* as snake_duel\.main/, out.string)
      end
    end
  end

  def test_deps_lock_supports_pinned_git_dependencies_but_live_check_stays_fetch_free
    git = ENV.fetch("GIT", "git")
    skip "git not available: #{git}" unless executable_available?(git)

    Dir.mktmpdir("milk-tea-cli-deps-lock-git") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      app_src_dir = File.join(app_root, "src")
      origin_root = File.join(dir, "origin-ui")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(origin_root)

      run_git!(git:, dir: origin_root, args: ["init", "--initial-branch=main"])
      FileUtils.mkdir_p(File.join(origin_root, "src", "teefan", "ui"))
      File.write(File.join(origin_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(origin_root, "src", "teefan", "ui", "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT
      run_git!(git:, dir: origin_root, args: ["add", "."])
      run_git!(git:, dir: origin_root, args: ["commit", "-m", "initial"])

      revision = capture_git(git:, dir: origin_root, args: ["rev-parse", "HEAD"])
      identity = MilkTea::PackageSourceResolver::GitIdentity.new(url: origin_root, revision:)
      cache = MilkTea::PackageSourceCache.new(root: File.join(cache_home, "milk_tea", "package_sources"))
      lock_manifest_path = cache.manifest_path_for(identity)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [build]
        entry = "src/main.mt"

        [dependencies]
        "teefan.ui" = { git = #{origin_root.inspect}, rev = #{revision.inspect} }
      TOML

      source_path = File.join(app_src_dir, "main.mt")
      File.write(source_path, <<~MT)
        import teefan.ui.layout as layout

        function main() -> int:
            return layout.default_width()
      MT

      with_env("XDG_CACHE_HOME" => cache_home) do
        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["check", source_path], out:, err:)

        assert_equal 1, status
        assert_equal "", out.string
        assert_match(/uses git resolution/, err.string)
        assert_match(/mtc deps lock/, err.string)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_match(/wrote .*package\.lock/, out.string)
        assert File.file?(lock_manifest_path)

        lock_contents = File.read(File.join(app_root, "package.lock"))
        assert_match(/source_kind = "git"/, lock_contents)
        assert_match(/git_url = #{Regexp.escape(origin_root.inspect)}/, lock_contents)
        assert_match(/git_rev = #{Regexp.escape(revision.inspect)}/, lock_contents)

        FileUtils.rm_rf(File.join(cache_home, "milk_tea"))

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["check", source_path, "--locked"], out:, err:)

        assert_equal 1, status
        assert_equal "", out.string
        assert_match(/not materialized in the source cache/, err.string)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "fetch", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_match(/materialized teefan\.ui -> /, out.string)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["check", source_path, "--locked"], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["check", source_path, "--frozen"], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
      end
    end
  end

  def test_deps_publish_lock_fetch_support_registry_dependencies_while_live_check_stays_fetch_free
    Dir.mktmpdir("milk-tea-cli-registry-deps") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      app_src_dir = File.join(app_root, "src")
      ui_root = File.join(dir, "libs", "ui")
      registry_root = File.join(dir, "registry")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(File.join(ui_root, "src", "teefan", "ui"))

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(ui_root, "src", "teefan", "ui", "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [build]
        entry = "src/main.mt"

        [dependencies]
        "teefan.ui" = "1.2.3"
      TOML

      source_path = File.join(app_src_dir, "main.mt")
      File.write(source_path, <<~MT)
        import teefan.ui.layout as layout

        function main() -> int:
            return layout.default_width()
      MT

      identity = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.2.3")
      cache = MilkTea::PackageSourceCache.new(root: File.join(cache_home, "milk_tea", "package_sources"))

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root, "XDG_CACHE_HOME" => cache_home) do
        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["check", source_path], out:, err:)

        assert_equal 1, status
        assert_equal "", out.string
        assert_match(/uses registry resolution/, err.string)
        assert_match(/mtc deps lock/, err.string)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "publish", ui_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_match(/published teefan\.ui@1\.2\.3 -> /, out.string)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_match(/wrote .*package\.lock/, out.string)

        lock_contents = File.read(File.join(app_root, "package.lock"))
        assert_match(/source_kind = "registry"/, lock_contents)
        assert_match(/registry_package = "teefan\.ui"/, lock_contents)
        assert_match(/registry_version = "1\.2\.3"/, lock_contents)

        FileUtils.rm_rf(File.join(cache_home, "milk_tea"))

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["check", source_path, "--locked"], out:, err:)

        assert_equal 1, status
        assert_equal "", out.string
        assert_match(/not materialized in the source cache/, err.string)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "fetch", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_match(/materialized teefan\.ui -> /, out.string)
        assert File.file?(cache.manifest_path_for(identity))

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["check", source_path, "--locked"], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["check", source_path, "--frozen"], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
      end
    end
  end

  def test_deps_lock_and_fetch_support_transitive_duplicate_exact_registry_versions
    Dir.mktmpdir("milk-tea-cli-registry-duplicate-exact") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      overlay_root = File.join(dir, "libs", "overlay")
      overlay_src_dir = File.join(overlay_root, "src", "teefan", "overlay")
      ui_v1_root = File.join(dir, "libs", "ui-v1")
      ui_v1_src_dir = File.join(ui_v1_root, "src", "teefan", "ui")
      ui_v2_root = File.join(dir, "libs", "ui-v2")
      ui_v2_src_dir = File.join(ui_v2_root, "src", "teefan", "ui")
      registry_root = File.join(dir, "registry")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(overlay_src_dir)
      FileUtils.mkdir_p(ui_v1_src_dir)
      FileUtils.mkdir_p(ui_v2_src_dir)

      File.write(File.join(ui_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.0.0"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(ui_v1_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      File.write(File.join(ui_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "2.0.0"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(ui_v2_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 20

        public function overlay_width() -> int:
            return 7
      MT

      File.write(File.join(overlay_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.overlay"
        version = "0.1.0"
        kind = "library"
        source_root = "src"

        [dependencies]
        "teefan.ui" = "2.0.0"
      TOML
      File.write(File.join(overlay_src_dir, "panel.mt"), <<~MT)
        import teefan.ui.layout as layout

        public function overlay_width() -> int:
            return layout.overlay_width()
      MT

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [build]
        entry = "src/snake_duel/main.mt"

        [dependencies]
        "teefan.overlay" = { path = "../../libs/overlay" }
        "teefan.ui" = "1.0.0"
      TOML

      source_path = File.join(app_src_dir, "main.mt")
      File.write(source_path, <<~MT)
        import teefan.ui.layout as layout
        import teefan.overlay.panel as panel

        function main() -> int:
            return layout.default_width() + panel.overlay_width()
      MT

      identity_v1 = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.0.0")
      identity_v2 = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "2.0.0")
      cache = MilkTea::PackageSourceCache.new(root: File.join(cache_home, "milk_tea", "package_sources"))

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root, "XDG_CACHE_HOME" => cache_home) do
        store = MilkTea::PackageRegistryStore.new
        store.publish(ui_v1_root)
        store.publish(ui_v2_root)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["check", source_path], out:, err:)

        assert_equal 1, status
        assert_equal "", out.string
        assert_match(/uses registry resolution/, err.string)
        assert_match(/mtc deps lock/, err.string)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_match(/wrote .*package\.lock/, out.string)

        lock_contents = File.read(File.join(app_root, "package.lock"))
        assert_equal 2, lock_contents.scan(/^name = "teefan\.ui"$/).length
        assert_match(/name = "teefan\.ui"\nkind = "library"\nversion = "1\.0\.0"/m, lock_contents)
        assert_match(/name = "teefan\.ui"\nkind = "library"\nversion = "2\.0\.0"/m, lock_contents)

        FileUtils.rm_rf(File.join(cache_home, "milk_tea"))

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["check", source_path, "--locked"], out:, err:)

        assert_equal 1, status
        assert_equal "", out.string
        assert_match(/not materialized in the source cache/, err.string)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "fetch", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_equal 2, out.string.scan(/materialized teefan\.ui -> /).length
        assert File.file?(cache.manifest_path_for(identity_v1))
        assert File.file?(cache.manifest_path_for(identity_v2))

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["check", source_path, "--locked"], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
      end
    end
  end

  def test_deps_lock_and_fetch_support_transitive_duplicate_ranged_registry_versions
    Dir.mktmpdir("milk-tea-cli-registry-duplicate-ranged") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      overlay_root = File.join(dir, "libs", "overlay")
      overlay_src_dir = File.join(overlay_root, "src", "teefan", "overlay")
      ui_v1_root = File.join(dir, "libs", "ui-v1")
      ui_v1_src_dir = File.join(ui_v1_root, "src", "teefan", "ui")
      ui_v2_root = File.join(dir, "libs", "ui-v2")
      ui_v2_src_dir = File.join(ui_v2_root, "src", "teefan", "ui")
      registry_root = File.join(dir, "registry")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(overlay_src_dir)
      FileUtils.mkdir_p(ui_v1_src_dir)
      FileUtils.mkdir_p(ui_v2_src_dir)

      File.write(File.join(ui_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.0"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(ui_v1_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      File.write(File.join(ui_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "2.1.0"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(ui_v2_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 20

        public function overlay_width() -> int:
            return 7
      MT

      File.write(File.join(overlay_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.overlay"
        version = "0.1.0"
        kind = "library"
        source_root = "src"

        [dependencies]
        "teefan.ui" = "^2.0.0"
      TOML
      File.write(File.join(overlay_src_dir, "panel.mt"), <<~MT)
        import teefan.ui.layout as layout

        public function overlay_width() -> int:
            return layout.overlay_width()
      MT

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [build]
        entry = "src/snake_duel/main.mt"

        [dependencies]
        "teefan.overlay" = { path = "../../libs/overlay" }
        "teefan.ui" = "^1.0.0"
      TOML

      source_path = File.join(app_src_dir, "main.mt")
      File.write(source_path, <<~MT)
        import teefan.ui.layout as layout
        import teefan.overlay.panel as panel

        function main() -> int:
            return layout.default_width() + panel.overlay_width()
      MT

      identity_v1 = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.2.0")
      identity_v2 = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "2.1.0")
      cache = MilkTea::PackageSourceCache.new(root: File.join(cache_home, "milk_tea", "package_sources"))

      with_env("MILK_TEA_PACKAGE_REGISTRY" => registry_root, "XDG_CACHE_HOME" => cache_home) do
        store = MilkTea::PackageRegistryStore.new
        store.publish(ui_v1_root)
        store.publish(ui_v2_root)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_match(/wrote .*package\.lock/, out.string)

        lock_contents = File.read(File.join(app_root, "package.lock"))
        assert_equal 2, lock_contents.scan(/^name = "teefan\.ui"$/).length
        assert_match(/name = "teefan\.ui"\nkind = "library"\nversion = "1\.2\.0"/m, lock_contents)
        assert_match(/name = "teefan\.ui"\nkind = "library"\nversion = "2\.1\.0"/m, lock_contents)

        FileUtils.rm_rf(File.join(cache_home, "milk_tea"))

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "fetch", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_equal 2, out.string.scan(/materialized teefan\.ui -> /).length
        assert File.file?(cache.manifest_path_for(identity_v1))
        assert File.file?(cache.manifest_path_for(identity_v2))

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["check", source_path, "--locked"], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
      end
    end
  end

  def test_deps_publish_upstream_and_lock_fetch_sync_registry_dependency_from_upstream
    Dir.mktmpdir("milk-tea-cli-upstream-registry-deps") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      app_src_dir = File.join(app_root, "src")
      ui_root = File.join(dir, "libs", "ui")
      registry_root = File.join(dir, "registry")
      upstream_registry_root = File.join(dir, "upstream-registry")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(File.join(ui_root, "src", "teefan", "ui"))

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(ui_root, "src", "teefan", "ui", "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [build]
        entry = "src/main.mt"

        [dependencies]
        "teefan.ui" = "1.2.3"
      TOML

      source_path = File.join(app_src_dir, "main.mt")
      File.write(source_path, <<~MT)
        import teefan.ui.layout as layout

        function main() -> int:
            return layout.default_width()
      MT

      identity = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.2.3")
      cache = MilkTea::PackageSourceCache.new(root: File.join(cache_home, "milk_tea", "package_sources"))
      local_registry = MilkTea::PackageRegistryStore.new(root: registry_root, upstream_root: upstream_registry_root)

      with_env(
        "MILK_TEA_PACKAGE_REGISTRY" => registry_root,
        "MILK_TEA_PACKAGE_REGISTRY_UPSTREAM" => upstream_registry_root,
        "XDG_CACHE_HOME" => cache_home,
      ) do
        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "publish", ui_root, "--upstream"], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_match(/published teefan\.ui@1\.2\.3 -> /, out.string)
        refute local_registry.published?(identity)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_match(/wrote .*package\.lock/, out.string)
        assert local_registry.published?(identity)

        FileUtils.rm_rf(File.join(cache_home, "milk_tea"))
        FileUtils.rm_rf(local_registry.package_root_for(identity))

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["check", source_path, "--locked"], out:, err:)

        assert_equal 1, status
        assert_equal "", out.string
        assert_match(/not materialized in the source cache/, err.string)

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["deps", "fetch", app_root], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
        assert_match(/materialized teefan\.ui -> /, out.string)
        assert local_registry.published?(identity)
        assert File.file?(cache.manifest_path_for(identity))

        out = StringIO.new
        err = StringIO.new

        status = MilkTea::CLI.start(["check", source_path, "--locked"], out:, err:)

        assert_equal 0, status
        assert_equal "", err.string
      end
    end
  end

  def test_deps_lock_and_fetch_sync_registry_dependency_from_http_upstream
    Dir.mktmpdir("milk-tea-cli-http-upstream-registry-deps") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      app_src_dir = File.join(app_root, "src")
      ui_root = File.join(dir, "libs", "ui")
      registry_root = File.join(dir, "registry")
      upstream_registry_root = File.join(dir, "upstream-registry")
      cache_home = File.join(dir, "cache-home")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(File.join(ui_root, "src", "teefan", "ui"))

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(ui_root, "src", "teefan", "ui", "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [build]
        entry = "src/main.mt"

        [dependencies]
        "teefan.ui" = "1.2.3"
      TOML

      source_path = File.join(app_src_dir, "main.mt")
      File.write(source_path, <<~MT)
        import teefan.ui.layout as layout

        function main() -> int:
            return layout.default_width()
      MT

      identity = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.2.3")
      cache = MilkTea::PackageSourceCache.new(root: File.join(cache_home, "milk_tea", "package_sources"))
      local_registry = MilkTea::PackageRegistryStore.new(root: registry_root, upstream_root: upstream_registry_root)
      local_registry.publish(ui_root, target: :upstream)

      with_static_http_server(upstream_registry_root) do |base_url|
        with_env(
          "MILK_TEA_PACKAGE_REGISTRY" => registry_root,
          "MILK_TEA_PACKAGE_REGISTRY_UPSTREAM" => base_url,
          "XDG_CACHE_HOME" => cache_home,
        ) do
          out = StringIO.new
          err = StringIO.new

          status = MilkTea::CLI.start(["deps", "lock", app_root], out:, err:)

          assert_equal 0, status
          assert_equal "", err.string
          assert_match(/wrote .*package\.lock/, out.string)
          assert local_registry.published?(identity)

          FileUtils.rm_rf(File.join(cache_home, "milk_tea"))
          FileUtils.rm_rf(local_registry.package_root_for(identity))

          out = StringIO.new
          err = StringIO.new

          status = MilkTea::CLI.start(["check", source_path, "--locked"], out:, err:)

          assert_equal 1, status
          assert_equal "", out.string
          assert_match(/not materialized in the source cache/, err.string)

          out = StringIO.new
          err = StringIO.new

          status = MilkTea::CLI.start(["deps", "fetch", app_root], out:, err:)

          assert_equal 0, status
          assert_equal "", err.string
          assert_match(/materialized teefan\.ui -> /, out.string)
          assert local_registry.published?(identity)
          assert File.file?(cache.manifest_path_for(identity))

          out = StringIO.new
          err = StringIO.new

          status = MilkTea::CLI.start(["check", source_path, "--locked"], out:, err:)

          assert_equal 0, status
          assert_equal "", err.string
        end
      end
    end
  end

  def test_check_command_locked_uses_package_lock_when_manifest_dependencies_drift
    Dir.mktmpdir("milk-tea-cli-check-locked") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [build]
        entry = "src/snake_duel/main.mt"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.3.0"
        kind = "library"
        source_root = "src"
      TOML

      source_path = File.join(app_src_dir, "main.mt")
      File.write(source_path, <<~MT)
        import teefan.ui.layout as layout

        function main() -> int:
            return layout.default_width()
      MT

      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      lock_out = StringIO.new
      lock_err = StringIO.new
      lock_status = MilkTea::CLI.start(["deps", "lock", app_root], out: lock_out, err: lock_err)

      assert_equal 0, lock_status
      assert_equal "", lock_err.string

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [build]
        entry = "src/snake_duel/main.mt"
      TOML

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["check", source_path], out:, err:)

      assert_equal 1, status
      assert_equal "", out.string
      assert_match(/module not found|package dependency not declared/, err.string)

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["check", source_path, "--locked"], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/checked .* as snake_duel\.main/, out.string)
    end
  end

  def test_check_command_reports_entry_module_namespace_trap_for_missing_sibling_import
    Dir.mktmpdir("milk-tea-cli-check-entry-namespace-trap") do |dir|
      app_root = File.join(dir, "apps", "tetris")
      src_dir = File.join(app_root, "src")
      source_path = File.join(src_dir, "main.mt")

      FileUtils.mkdir_p(src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "tetris"
        version = "0.1.0"
        source_root = "src"

        [build]
        entry = "src/main.mt"
      TOML

      File.write(source_path, <<~MT)
        import main.platform_info as platform_info

        function main() -> int:
            return 0
      MT

      File.write(File.join(src_dir, "platform_info.mt"), <<~MT)
        public function label() -> str:
            return "Build: Shared"
      MT

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["check", source_path], out:, err:)

      assert_equal 1, status
      assert_equal "", out.string
      assert_match(/entry module 'main' does not create an import namespace for sibling files/, err.string)
      assert_match(/Import 'platform_info' instead/, err.string)
    end
  end

  def test_check_command_live_resolves_transitive_duplicate_path_package_names
    Dir.mktmpdir("milk-tea-cli-check-live-package-instances") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      overlay_root = File.join(dir, "libs", "overlay")
      ui_v1_root = File.join(dir, "libs", "ui-v1")
      ui_v2_root = File.join(dir, "libs", "ui-v2")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      overlay_src_dir = File.join(overlay_root, "src", "teefan", "overlay")
      ui_v1_src_dir = File.join(ui_v1_root, "src", "teefan", "ui")
      ui_v2_src_dir = File.join(ui_v2_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(overlay_src_dir)
      FileUtils.mkdir_p(ui_v1_src_dir)
      FileUtils.mkdir_p(ui_v2_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [build]
        entry = "src/snake_duel/main.mt"

        [dependencies]
        "teefan.overlay" = { path = "../../libs/overlay" }
        "teefan.ui" = { path = "../../libs/ui-v1" }
      TOML

      File.write(File.join(overlay_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.overlay"
        version = "0.1.0"
        kind = "library"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../ui-v2" }
      TOML

      File.write(File.join(ui_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.0.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(ui_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "2.0.0"
        kind = "library"
        source_root = "src"
      TOML

      source_path = File.join(app_src_dir, "main.mt")
      File.write(source_path, <<~MT)
        import teefan.ui.layout as layout
        import teefan.overlay.panel as panel

        function main() -> int:
            return layout.default_width() + panel.overlay_width()
      MT

      File.write(File.join(overlay_src_dir, "panel.mt"), <<~MT)
        import teefan.ui.layout as layout

        public function overlay_width() -> int:
            return layout.overlay_width()
      MT

      File.write(File.join(ui_v1_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      File.write(File.join(ui_v2_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 20

        public function overlay_width() -> int:
            return 7
      MT

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["check", source_path], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/checked .* as snake_duel\.main/, out.string)
    end
  end

  def test_check_command_frozen_requires_current_lockfile
    Dir.mktmpdir("milk-tea-cli-check-frozen") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [build]
        entry = "src/snake_duel/main.mt"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.3.0"
        kind = "library"
        source_root = "src"
      TOML

      source_path = File.join(app_src_dir, "main.mt")
      File.write(source_path, <<~MT)
        import teefan.ui.layout as layout

        function main() -> int:
            return layout.default_width()
      MT

      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      lock_out = StringIO.new
      lock_err = StringIO.new
      lock_status = MilkTea::CLI.start(["deps", "lock", app_root], out: lock_out, err: lock_err)

      assert_equal 0, lock_status
      assert_equal "", lock_err.string

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["check", source_path, "--frozen"], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/checked .* as snake_duel\.main/, out.string)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [build]
        entry = "src/snake_duel/main.mt"
      TOML

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["check", source_path, "--frozen"], out:, err:)

      assert_equal 1, status
      assert_equal "", out.string
      assert_match(/package\.lock is out of date/, err.string)
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
    assert_match(/mtc format PATH\|DIR \[--check\|--write\] \[--safe\|--canonical\|--preserve\]/, err.string)
  end

  def test_invalid_commands_print_usage
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["unknown"], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/Usage: mtc lex PATH/, err.string)
    assert_match(/mtc semantic-tokens PATH \[--locked\] \[--frozen\] \[-I PATH\]/, err.string)
    assert_match(/mtc parse PATH \[--locked\] \[--frozen\] \[-I PATH\]/, err.string)
    assert_match(/mtc format PATH\|DIR \[--check\|--write\] \[--safe\|--canonical\|--preserve\]/, err.string)
    assert_match(/mtc lint PATH\|DIR .*\[-I PATH\]/, err.string)
    assert_match(/mtc check PATH \[--locked\] \[--frozen\] \[-I PATH\]/, err.string)
    assert_match(/mtc lower PATH \[--locked\] \[--frozen\] \[-I PATH\]/, err.string)
    assert_match(/mtc emit-c PATH \[--locked\] \[--frozen\] \[-I PATH\]/, err.string)
    assert_match(/mtc build \[PATH_OR_PACKAGE\]/, err.string)
    assert_match(/mtc new NAME/, err.string)
    assert_match(/mtc run \[PATH_OR_PACKAGE\]/, err.string)
    refute_match(/mtc stop-preview \[PATH_OR_PACKAGE\]/, err.string)
    assert_match(/mtc toolchain bootstrap/, err.string)
    assert_match(/mtc toolchain doctor/, err.string)
    refute_match(/mtc deps bootstrap/, err.string)
    assert_match(/mtc deps update \[PATH_OR_PACKAGE\] \[NAME \.\.\.\]/, err.string)
    assert_match(/mtc deps tree \[PATH_OR_PACKAGE\]/, err.string)
    assert_match(/mtc deps lock \[PATH_OR_PACKAGE\]/, err.string)
    assert_match(/mtc deps publish \[PATH_OR_PACKAGE\] \[--upstream\]/, err.string)
    assert_match(/mtc deps fetch \[PATH_OR_PACKAGE\]/, err.string)
    assert_match(/mtc bindgen MODULE HEADER .*--nullable-report PATH/, err.string)
    assert_match(/mtc dap/, err.string)
  end

  def test_new_command_creates_project_scaffold_and_generated_entry_checks
    Dir.mktmpdir("milk-tea-cli-new") do |dir|
      project_root = File.join(dir, "hello-world")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["new", project_root], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/created #{Regexp.escape(project_root)}/, out.string)
      assert_equal <<~TOML, File.read(File.join(project_root, "package.toml"))
        [package]
        name = "hello_world"
        version = "0.1.0"
        source_root = "src"

        [build]
        entry = "src/main.mt"
      TOML
      assert_equal <<~MT, File.read(File.join(project_root, "src", "main.mt"))
        function main() -> int:
            return 0
      MT

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["check", File.join(project_root, "src", "main.mt")], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/checked .*src\/main\.mt as main/, out.string)
    end
  end

  def test_new_command_normalizes_camel_case_project_name_for_package_and_module
    Dir.mktmpdir("milk-tea-cli-new-camel-case") do |dir|
      project_root = File.join(dir, "MyProject")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["new", project_root], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/created #{Regexp.escape(project_root)}/, out.string)
      assert_match(/name = "my_project"/, File.read(File.join(project_root, "package.toml")))
      assert_match(/function main\(\) -> int:/, File.read(File.join(project_root, "src", "main.mt")))
    end
  end

  def test_new_command_without_name_prints_usage
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["new"], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/missing project name/, err.string)
    assert_match(/mtc new NAME/, err.string)
  end

  def test_new_command_rejects_existing_non_empty_directory
    Dir.mktmpdir("milk-tea-cli-new-existing") do |dir|
      project_root = File.join(dir, "hello-world")
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["new", project_root], out:, err:)

      assert_equal 0, status

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["new", project_root], out:, err:)

      assert_equal 1, status
      assert_equal "", out.string
      assert_match(/project directory already exists and is not empty/, err.string)
    end
  end

  def test_new_command_help_prints_command_help
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["new", "--help"], out:, err:)

    assert_equal 0, status
    assert_equal "", err.string
    assert_match(/Usage: mtc new NAME/, out.string)
    assert_match(/Create a new application package scaffold/, out.string)
    assert_match(/normalized to\s+snake_case/, out.string)
  end

  def test_bindgen_command_without_args_prints_bindgen_help
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["bindgen"], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/missing module name or header path/, err.string)
    assert_match(/Usage: mtc bindgen MODULE HEADER \[OPTIONS\]/, err.string)
    assert_match(/--nullable-report PATH/, err.string)
    refute_match(/Usage: mtc lex PATH/, err.string)
  end

  def test_toolchain_command_rejects_leading_include_path_flag
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["-I", __dir__, "toolchain", "doctor"], out:, err:)

    assert_equal 1, status
    assert_equal "", out.string
    assert_match(/unknown option -I for toolchain/, err.string)
    assert_match(/Usage: mtc lex PATH/, err.string)
  end

  def test_lint_help_explains_locked_and_frozen_semantic_resolution
    out = StringIO.new
    err = StringIO.new

    status = MilkTea::CLI.start(["lint", "--help"], out:, err:)

    assert_equal 0, status
    assert_equal "", err.string
    assert_match(/semantic\/import-aware/, out.string)
    assert_match(/Use package\.lock for semantic dependency resolution/, out.string)
    assert_match(/Require a current package\.lock before semantic dependency resolution/, out.string)
    assert_match(/-I, --include-path PATH\s+Add an extra module root for semantic resolution/, out.string)
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
        function compute(x: int) -> int:
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
        function compute(x: int) -> int:
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
        function compute() -> int:
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
        function main() -> int:
            let unused_a = 1
            return 0
      MT
      File.write(File.join(dir, "b.mt"), <<~MT)
        function main() -> int:
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
        function main() -> int:
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
        function main() -> int:
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

  def test_lint_command_fix_applies_to_multiple_expanded_paths_with_trailing_fix_flag
    Dir.mktmpdir("milk-tea-cli-lint-multi-fix") do |dir|
      first_path = File.join(dir, "a.mt")
      second_path = File.join(dir, "b.mt")
      File.write(first_path, <<~MT)
        function main() -> int:
            var first = 1
            return first
      MT
      File.write(second_path, <<~MT)
        function helper() -> int:
            var second = 2
            return second
      MT
      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["lint", first_path, second_path, "--fix"], out:, err:)

      assert_equal 0, status
      assert_equal "", err.string
      assert_match(/fixed .*a\.mt/, out.string)
      assert_match(/fixed .*b\.mt/, out.string)
      assert_includes File.read(first_path), "let first = 1"
      assert_includes File.read(second_path), "let second = 2"
    end
  end

  def test_lint_command_output_format_json
    Dir.mktmpdir("milk-tea-cli-lint-json") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        function main() -> int:
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
        function main() -> int:
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
        function main() -> int:
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

  def test_format_command_directory_check_mode
    Dir.mktmpdir("milk-tea-cli-fmt-dir") do |dir|
      unformatted = File.join(dir, "a.mt")
      already_ok  = File.join(dir, "b.mt")

      File.write(unformatted, "function  main()->int:\n    return 0\n")
      File.write(already_ok,  "function main() -> int:\n    return 0\n")

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["format", dir, "--check"], out:, err:)

      assert_equal 1, status
      assert_match(/needs formatting/, out.string)
    end
  end

  def test_format_command_directory_write_mode
    Dir.mktmpdir("milk-tea-cli-fmt-dir-write") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, "function  main()->int:\n    return 0\n")

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["format", dir, "--write"], out:, err:)

      assert_equal 0, status
      assert_match(/formatted \d+ of \d+ file/, out.string)
    end
  end

  def test_format_command_directory_no_flag_errors
    Dir.mktmpdir("milk-tea-cli-fmt-dir-noflag") do |dir|
      File.write(File.join(dir, "a.mt"), "function main() -> int:\n    return 0\n")

      out = StringIO.new
      err = StringIO.new

      status = MilkTea::CLI.start(["format", dir], out:, err:)

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

  def language_fixture_path
    File.expand_path("../fixtures/language_fixture.mt", __dir__)
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

  def with_env(overrides)
    previous = {}
    overrides.each_key do |key|
      previous[key] = ENV.key?(key) ? ENV[key] : :__missing__
    end
    overrides.each do |key, value|
      ENV[key] = value
    end
    yield
  ensure
    previous.each do |key, value|
      if value == :__missing__
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  def capture_git(git:, dir:, args:)
    stdout, stderr, status = Open3.capture3(git_env, git, "-C", dir, *args)
    assert status.success?, stderr

    stdout.strip
  end

  def run_git!(git:, dir:, args:)
    stdout, stderr, status = Open3.capture3(git_env, git, "-C", dir, *args)
    assert status.success?, [stdout, stderr].reject(&:empty?).join
  end

  def git_env
    {
      "GIT_AUTHOR_NAME" => "Milk Tea Tests",
      "GIT_AUTHOR_EMAIL" => "tests@example.com",
      "GIT_COMMITTER_NAME" => "Milk Tea Tests",
      "GIT_COMMITTER_EMAIL" => "tests@example.com",
    }
  end

  def with_singleton_method_override(object, method_name, implementation)
    singleton_class = class << object; self; end
    original_name = "__cli_test_original_#{method_name}__"
    original_defined = singleton_class.method_defined?(method_name) || singleton_class.private_method_defined?(method_name)
    singleton_class.alias_method(original_name, method_name) if original_defined
    singleton_class.define_method(method_name) do |*args, **kwargs, &block|
      implementation.call(*args, **kwargs, &block)
    end
    yield
  ensure
    singleton_class.remove_method(method_name) if singleton_class.method_defined?(method_name)
    if original_defined
      singleton_class.alias_method(method_name, original_name)
      singleton_class.remove_method(original_name)
    end
  end
end
