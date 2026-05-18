# frozen_string_literal: true

require "json"
require "open3"
require "rubygems/package"
require "tmpdir"
require "zlib"
require_relative "../test_helper"
require_relative "../../lib/milk_tea/bindings"

class MilkTeaBuildTest < Minitest::Test
  def test_build_generates_output_and_kept_c_with_link_flags
    Dir.mktmpdir("milk-tea-build") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      output_path = File.join(dir, "language-fixture")
      c_path = File.join(dir, "language-fixture.c")

      result = MilkTea::Build.build(language_fixture_path, output_path:, cc: compiler_path, keep_c_path: c_path)

      assert_equal File.expand_path(output_path), result.output_path
      assert_equal File.expand_path(c_path), result.c_path
      assert_equal File.expand_path(compiler_path), result.compiler
      assert_equal [], result.link_flags
      assert File.exist?(output_path)
      assert File.exist?(c_path)
      refute_match(/^#line\s+/m, File.read(c_path))

      invocation = File.read(compiler_log).lines(chomp: true)
      assert_includes invocation, "-std=c11"
      refute_includes invocation, File.expand_path(c_path)
      assert_includes invocation, File.expand_path(output_path)
      refute_includes invocation, "-lm"
    end
  end

  def test_build_without_kept_c_emits_backend_once_for_debug_build
    Dir.mktmpdir("milk-tea-build-emit-count") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      source_path = File.join(dir, "emit-count.mt")
      output_path = File.join(dir, "emit-count")

      File.write(source_path, [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))

      original_emit = MilkTea::CBackend.method(:emit)
      emit_calls = []

      with_singleton_method_override(MilkTea::CBackend, :emit, lambda do |*args, **kwargs|
        emit_calls << kwargs.fetch(:emit_line_directives)
        original_emit.call(*args, **kwargs)
      end) do
        result = MilkTea::Build.build(source_path, output_path:, cc: compiler_path)

        assert_equal File.expand_path(output_path), result.output_path
        assert_nil result.c_path
        assert File.exist?(output_path)
      end

      assert_equal [true], emit_calls
    end
  end

  def test_build_variant_match_payload_binding_evaluates_scrutinee_once
    Dir.mktmpdir("milk-tea-build-match-bind") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      source_path = File.join(dir, "match-bind.mt")
      output_path = File.join(dir, "match-bind")
      c_path = File.join(dir, "match-bind.c")

      File.write(source_path, <<~MT)
        
        import std.str as text

        function match_scrutinee_once() -> Option[str]:
            return Option[str].some(value= "milk")

        function main() -> int:
            match match_scrutinee_once():
                Option.some as payload:
                    if not payload.value.equal("milk"):
                        return 1
                Option.none:
                    return 2
            return 0
      MT

      result = MilkTea::Build.build(source_path, output_path:, cc: compiler_path, keep_c_path: c_path)

      assert_equal File.expand_path(output_path), result.output_path
      assert_equal File.expand_path(c_path), result.c_path
      generated = File.read(c_path)
      assert_equal 1, generated.scan(/\b\w*match_scrutinee_once\(\)/).length
      refute_match(/^#line\s+/m, generated)
    end
  end

  def test_build_break_inside_match_exits_enclosing_loop
    Dir.mktmpdir("milk-tea-build-match-break") do |dir|
      compiler_path = ENV.fetch("CC", "cc")
      skip "C compiler not available" unless compiler_available?(compiler_path)
      source_path = File.join(dir, "match-break.mt")
      output_path = File.join(dir, "match-break")

      File.write(source_path, <<~MT)
        enum Step: ubyte
            keep = 1
            stop = 2

        function main() -> int:
            var count = 0
            while true:
                count += 1
                let step = Step.stop
                match step:
                    Step.stop:
                        break
                    Step.keep:
                        return 3
                if count > 1:
                    return 2
            return if count == 1: 0 else: 1
      MT

      result = MilkTea::Build.build(source_path, output_path:, cc: compiler_path)
      _stdout, _stderr, status = Open3.capture3(output_path)

      assert_equal File.expand_path(output_path), result.output_path
      assert File.exist?(output_path)
      assert_equal 0, status.exitstatus
    end
  end

  def test_build_reports_missing_compiler
    error = assert_raises(MilkTea::BuildError) do
      MilkTea::Build.build(language_fixture_path, cc: "/definitely/missing/cc")
    end

    assert_match(/C compiler not found/, error.message)
  end

  def test_build_wasm_normalizes_output_to_html_and_passes_shell_file
    Dir.mktmpdir("milk-tea-build-wasm") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      source_path = File.join(dir, "web-smoke.mt")
      output_path = File.join(dir, "web-smoke")

      File.write(source_path, [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Build.build(source_path, output_path:, cc: compiler_path, platform: :wasm)
      expected_output = File.expand_path("#{output_path}.html")

      assert_equal expected_output, result.output_path
      assert_equal :wasm, result.platform
      assert File.exist?(expected_output)

      invocation = File.read(compiler_log).lines(chomp: true)
      assert_includes invocation, "--shell-file"
      assert_includes invocation, "-sINCOMING_MODULE_JS_API=canvas,print,printErr"
      assert_includes invocation, expected_output
    end
  end

  def test_build_uses_platform_specific_package_entry_variant_when_present
    Dir.mktmpdir("milk-tea-build-platform-entry") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      package_root = File.join(dir, "platform-demo")
      src_dir = File.join(package_root, "src")
      shared_entry_path = File.join(src_dir, "main.mt")
      windows_entry_path = File.join(src_dir, "main.windows.mt")
      captured_paths = []
      real_new = MilkTea::ModuleLoader.method(:new)

      FileUtils.mkdir_p(src_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "platform_demo"

        [platform]
        default = "windows"

        [build]
        entry = "src/main.mt"
      TOML

      File.write(shared_entry_path, <<~MT)
        function main() -> int:
            return 1
      MT

      File.write(windows_entry_path, <<~MT)
        function main() -> int:
            return 2
      MT

      with_singleton_method_override(MilkTea::ModuleLoader, :new, lambda do |**kwargs|
        loader = real_new.call(**kwargs)

        Object.new.tap do |wrapper|
          wrapper.define_singleton_method(:check_program) do |path|
            captured_paths << path
            loader.check_program(path)
          end
        end
      end) do
        MilkTea::Build.build(package_root, cc: compiler_path)
      end

      assert_equal [File.expand_path(windows_entry_path)], captured_paths
    end
  end

  def test_build_rejects_conflicting_platform_for_platform_specific_source_path
    Dir.mktmpdir("milk-tea-build-platform-mismatch") do |dir|
      source_path = File.join(dir, "main.windows.mt")

      File.write(source_path, <<~MT)
        function main() -> int:
            return 0
      MT

      error = assert_raises(MilkTea::BuildError) do
        MilkTea::Build.build(source_path, platform: :linux)
      end

      assert_match(/targets platform windows; active platform is linux/, error.message)
    end
  end

  def test_default_wasm_shell_template_contains_required_placeholders
    assert_includes MilkTea::Build::WASM_SHELL_TEMPLATE, MilkTea::Build::WASM_SHELL_CANVAS_PLACEHOLDER
    assert_includes MilkTea::Build::WASM_SHELL_TEMPLATE, MilkTea::Build::WASM_SHELL_OUTPUT_PLACEHOLDER
    assert_includes MilkTea::Build::WASM_SHELL_TEMPLATE, MilkTea::Build::WASM_SHELL_BOOTSTRAP_PLACEHOLDER
    assert_includes MilkTea::Build::WASM_SHELL_TEMPLATE, MilkTea::Build::WASM_SHELL_SCRIPT_PLACEHOLDER
  end

  def test_wasm_shell_bootstrap_escapes_output_newlines_for_inline_javascript
    assert_includes MilkTea::Build::WASM_SHELL_BOOTSTRAP_TEMPLATE, 'textContent += text + "\\n";'
    assert_includes MilkTea::Build::WASM_SHELL_BOOTSTRAP_TEMPLATE, 'textContent += "[err] " + text + "\\n";'
  end

  def test_build_wasm_package_renders_custom_html_template_from_manifest
    Dir.mktmpdir("milk-tea-build-wasm-template") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      rendered_shell = File.join(dir, "rendered-shell.html")
      compiler_path = write_fake_compiler(dir, compiler_log, shell_copy_path: rendered_shell)
      package_root = File.join(dir, "web-demo")
      src_dir = File.join(package_root, "src")
      web_dir = File.join(package_root, "web")
      FileUtils.mkdir_p(src_dir)
      FileUtils.mkdir_p(web_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "web_demo"

        [platform]
        default = "wasm"

        [build]
        entry = "src/main.mt"
        html_template = "web/shell.html"
      TOML

      File.write(File.join(src_dir, "main.mt"), [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))

      File.write(File.join(web_dir, "shell.html"), <<~HTML)
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <title>Custom Shell</title>
          </head>
          <body>
            <main class="shell-frame">
              <section class="shell-stage">{{{ MILK_TEA_CANVAS }}}</section>
              <aside class="shell-log">{{{ MILK_TEA_OUTPUT }}}</aside>
            </main>
            {{{ MILK_TEA_BOOTSTRAP }}}
            {{{ SCRIPT }}}
          </body>
        </html>
      HTML

      MilkTea::Build.build(package_root, cc: compiler_path)

      rendered = File.read(rendered_shell)
      assert_includes rendered, "<title>Custom Shell</title>"
      assert_includes rendered, "shell-frame"
      assert_includes rendered, "<canvas id=\"canvas\""
      assert_includes rendered, "<pre id=\"output\">"
      assert_includes rendered, "var Module = {"
      assert_includes rendered, MilkTea::Build::WASM_SHELL_SCRIPT_PLACEHOLDER
      refute_includes rendered, MilkTea::Build::WASM_SHELL_CANVAS_PLACEHOLDER
      refute_includes rendered, MilkTea::Build::WASM_SHELL_OUTPUT_PLACEHOLDER
      refute_includes rendered, MilkTea::Build::WASM_SHELL_BOOTSTRAP_PLACEHOLDER
    end
  end

  def test_build_wasm_package_rejects_html_template_missing_required_placeholder
    Dir.mktmpdir("milk-tea-build-wasm-template-error") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      package_root = File.join(dir, "web-demo")
      src_dir = File.join(package_root, "src")
      web_dir = File.join(package_root, "web")
      FileUtils.mkdir_p(src_dir)
      FileUtils.mkdir_p(web_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "web_demo"

        [platform]
        default = "wasm"

        [build]
        entry = "src/main.mt"
        html_template = "web/shell.html"
      TOML

      File.write(File.join(src_dir, "main.mt"), [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))

      File.write(File.join(web_dir, "shell.html"), <<~HTML)
        <!doctype html>
        <html>
          <body>
            {{{ MILK_TEA_CANVAS }}}
            {{{ MILK_TEA_OUTPUT }}}
            {{{ SCRIPT }}}
          </body>
        </html>
      HTML

      error = assert_raises(MilkTea::BuildError) do
        MilkTea::Build.build(package_root, cc: compiler_path)
      end

      assert_match(/Milk Tea \{\{\{ MILK_TEA_BOOTSTRAP \}\}\}/, error.message)
      refute File.exist?(compiler_log)
    end
  end

  def test_build_wasm_package_passes_assets_from_manifest_via_preload_file
    Dir.mktmpdir("milk-tea-build-wasm-assets") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      package_root = File.join(dir, "web-demo")
      src_dir = File.join(package_root, "src")
      assets_dir = File.join(package_root, "assets")
      FileUtils.mkdir_p(src_dir)
      FileUtils.mkdir_p(assets_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "web_demo"

        [platform]
        default = "wasm"

        [build]
        entry = "src/main.mt"
        assets = "assets"
      TOML

      File.write(File.join(src_dir, "main.mt"), [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))
      File.write(File.join(assets_dir, "note.txt"), "hello")

      MilkTea::Build.build(package_root, cc: compiler_path)

      invocation = File.read(compiler_log).lines(chomp: true)
      assets_index = invocation.index("--preload-file")
      refute_nil assets_index
      assert_equal "#{File.join(package_root, "assets")}@/assets", invocation.fetch(assets_index + 1)
    end
  end

  def test_build_wasm_package_passes_multiple_assets_from_manifest_via_preload_file
    Dir.mktmpdir("milk-tea-build-wasm-assets-multi") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      package_root = File.join(dir, "web-demo")
      src_dir = File.join(package_root, "src")
      assets_dir = File.join(package_root, "assets")
      FileUtils.mkdir_p(src_dir)
      FileUtils.mkdir_p(assets_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "web_demo"

        [platform]
        default = "wasm"

        [build]
        entry = "src/main.mt"
        assets = ["assets", "credits.txt"]
      TOML

      File.write(File.join(src_dir, "main.mt"), [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))
      File.write(File.join(assets_dir, "note.txt"), "hello")
      File.write(File.join(package_root, "credits.txt"), "credits")

      MilkTea::Build.build(package_root, cc: compiler_path)

      invocation = File.read(compiler_log).lines(chomp: true)
      preload_pairs = invocation.each_cons(2).select { |flag, _value| flag == "--preload-file" }

      assert_equal 2, preload_pairs.length
      assert_includes preload_pairs, ["--preload-file", "#{File.join(package_root, "assets")}@/assets"]
      assert_includes preload_pairs, ["--preload-file", "#{File.join(package_root, "credits.txt")}@/credits.txt"]
    end
  end

  def test_build_native_package_stages_assets_directory_next_to_output_binary
    Dir.mktmpdir("milk-tea-build-native-assets") do |dir|
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

      File.write(File.join(src_dir, "main.mt"), [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))
      File.write(File.join(assets_dir, "note.txt"), "hello")

      result = MilkTea::Build.build(package_root, cc: compiler_path)
      staged_assets_dir = File.join(File.dirname(result.output_path), "assets")

      assert_equal :linux, result.platform
      assert File.exist?(result.output_path)
      assert File.directory?(staged_assets_dir)
      assert_equal "hello", File.read(File.join(staged_assets_dir, "note.txt"))

      invocation = File.read(compiler_log).lines(chomp: true)
      refute_includes invocation, "--preload-file"
    end
  end

  def test_clean_explicit_native_package_output_removes_staged_assets_directory
    Dir.mktmpdir("milk-tea-build-native-clean-assets") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      package_root = File.join(dir, "desktop-demo")
      src_dir = File.join(package_root, "src")
      assets_dir = File.join(package_root, "assets")
      custom_output = File.join(dir, "dist", "desktop-demo")
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

      File.write(File.join(src_dir, "main.mt"), [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))
      File.write(File.join(assets_dir, "note.txt"), "hello")

      MilkTea::Build.build(package_root, output_path: custom_output, cc: compiler_path)

      staged_assets_dir = File.join(File.dirname(custom_output), "assets")
      assert File.exist?(custom_output)
      assert File.directory?(staged_assets_dir)

      MilkTea::Build.clean(package_root, output_path: custom_output)

      refute File.exist?(custom_output)
      refute File.exist?(staged_assets_dir)
    end
  end

  def test_clean_explicit_native_package_output_removes_multiple_staged_assets
    Dir.mktmpdir("milk-tea-build-native-clean-multi-assets") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      package_root = File.join(dir, "desktop-demo")
      src_dir = File.join(package_root, "src")
      assets_dir = File.join(package_root, "assets")
      custom_output = File.join(dir, "dist", "desktop-demo")
      FileUtils.mkdir_p(src_dir)
      FileUtils.mkdir_p(assets_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "desktop_demo"

        [platform]
        default = "linux"

        [build]
        entry = "src/main.mt"
        assets = ["assets", "credits.txt"]
      TOML

      File.write(File.join(src_dir, "main.mt"), [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))
      File.write(File.join(assets_dir, "note.txt"), "hello")
      File.write(File.join(package_root, "credits.txt"), "credits")

      MilkTea::Build.build(package_root, output_path: custom_output, cc: compiler_path)

      staged_assets_dir = File.join(File.dirname(custom_output), "assets")
      staged_credits = File.join(File.dirname(custom_output), "credits.txt")
      assert File.exist?(custom_output)
      assert File.directory?(staged_assets_dir)
      assert File.file?(staged_credits)

      MilkTea::Build.clean(package_root, output_path: custom_output)

      refute File.exist?(custom_output)
      refute File.exist?(staged_assets_dir)
      refute File.exist?(staged_credits)
    end
  end

  def test_build_native_package_bundle_outputs_executable_and_assets_in_dist_directory
    Dir.mktmpdir("milk-tea-build-native-bundle") do |dir|
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

      File.write(File.join(src_dir, "main.mt"), [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))
      File.write(File.join(assets_dir, "note.txt"), "hello")

      result = MilkTea::Build.build(package_root, cc: compiler_path, bundle: true)
      expected_bundle_root = File.join(package_root, "build", "dist", "linux", "debug", "desktop_demo")
      pack_path = File.join(expected_bundle_root, "assets.mtpack")
      pack = parse_asset_pack(pack_path)

      assert_equal File.join(expected_bundle_root, "desktop_demo"), result.output_path
      assert File.exist?(result.output_path)
      assert File.exist?(pack_path)
      refute File.exist?(File.join(expected_bundle_root, "assets"))
      assert_equal ["assets/note.txt"], pack.fetch(:entries).map { |entry| entry.fetch(:path) }
      assert_equal "hello", pack.fetch(:entries)[0].fetch(:data)
    end
  end

  def test_build_native_package_archive_stages_multiple_assets_and_archives_them
    Dir.mktmpdir("milk-tea-build-native-archive-multi-assets") do |dir|
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
        assets = ["assets", "credits.txt"]
      TOML

      File.write(File.join(src_dir, "main.mt"), [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))
      File.write(File.join(assets_dir, "note.txt"), "hello")
      File.write(File.join(package_root, "credits.txt"), "credits")

      result = MilkTea::Build.build(package_root, cc: compiler_path, archive: true)
      expected_bundle_root = File.join(package_root, "build", "dist", "linux", "debug", "desktop_demo")
      expected_archive = "#{expected_bundle_root}.tar.gz"
      pack_path = File.join(expected_bundle_root, "assets.mtpack")
      pack = parse_asset_pack(pack_path)

      assert_equal File.join(expected_bundle_root, "desktop_demo"), result.output_path
      assert_equal expected_archive, result.archive_path
      assert File.exist?(pack_path)
      refute File.exist?(File.join(expected_bundle_root, "assets"))
      refute File.exist?(File.join(expected_bundle_root, "credits.txt"))
      assert_equal ["assets/note.txt", "credits.txt"], pack.fetch(:entries).map { |entry| entry.fetch(:path) }
      assert_equal "hello", pack.fetch(:entries)[0].fetch(:data)
      assert_equal "credits", pack.fetch(:entries)[1].fetch(:data)

      entries = []
      Zlib::GzipReader.open(expected_archive) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each { |entry| entries << entry.full_name }
        end
      end

      assert_includes entries, "desktop_demo/assets.mtpack"
      refute_includes entries, "desktop_demo/assets"
      refute_includes entries, "desktop_demo/assets/note.txt"
      refute_includes entries, "desktop_demo/credits.txt"
    end
  end

  def test_clean_native_package_bundle_removes_dist_root_only
    Dir.mktmpdir("milk-tea-build-native-bundle-clean") do |dir|
      package_root = File.join(dir, "desktop-demo")
      src_dir = File.join(package_root, "src")
      dist_dir = File.join(package_root, "build", "dist", "linux", "debug", "desktop_demo")
      bin_dir = File.join(package_root, "build", "bin", "linux", "debug")
      FileUtils.mkdir_p(src_dir)
      FileUtils.mkdir_p(dist_dir)
      FileUtils.mkdir_p(bin_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "desktop_demo"

        [platform]
        default = "linux"

        [build]
        entry = "src/main.mt"
      TOML

      File.write(File.join(src_dir, "main.mt"), [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))
      File.write(File.join(dist_dir, "desktop_demo"), "stale")
      marker_path = File.join(bin_dir, "keep")
      File.write(marker_path, "keep")

      cleaned = MilkTea::Build.clean(package_root, bundle: true)

      assert_equal File.join(package_root, "build", "dist"), cleaned
      refute File.exist?(dist_dir)
      assert File.exist?(marker_path)
    end
  end

  def test_build_bundle_rejects_direct_source_builds
    error = assert_raises(MilkTea::BuildError) do
      MilkTea::Build.build(language_fixture_path, bundle: true)
    end

    assert_match(/bundle mode requires a package build/, error.message)
  end

  def test_build_bundle_rejects_wasm_package_builds
    Dir.mktmpdir("milk-tea-build-wasm-bundle") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      package_root = File.join(dir, "web-demo")
      src_dir = File.join(package_root, "src")
      FileUtils.mkdir_p(src_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "web_demo"

        [platform]
        default = "wasm"

        [build]
        entry = "src/main.mt"
      TOML

      File.write(File.join(src_dir, "main.mt"), [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))

      error = assert_raises(MilkTea::BuildError) do
        MilkTea::Build.build(package_root, cc: compiler_path, bundle: true)
      end

      assert_match(/bundle mode is supported only for native package builds/, error.message)
    end
  end

  def test_build_archive_writes_tarball_for_native_bundle
    Dir.mktmpdir("milk-tea-build-native-archive") do |dir|
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

      File.write(File.join(src_dir, "main.mt"), [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))
      File.write(File.join(assets_dir, "note.txt"), "hello")

      result = MilkTea::Build.build(package_root, cc: compiler_path, archive: true)
      expected_bundle_root = File.join(package_root, "build", "dist", "linux", "debug", "desktop_demo")
      expected_archive = "#{expected_bundle_root}.tar.gz"

      assert_equal File.join(expected_bundle_root, "desktop_demo"), result.output_path
      assert_equal expected_archive, result.archive_path
      assert File.exist?(expected_archive)

      entries = []
      Zlib::GzipReader.open(expected_archive) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each { |entry| entries << entry.full_name }
        end
      end

      assert_includes entries, "desktop_demo"
      assert_includes entries, "desktop_demo/desktop_demo"
      assert_includes entries, "desktop_demo/assets.mtpack"
      refute_includes entries, "desktop_demo/assets"
      refute_includes entries, "desktop_demo/assets/note.txt"
    end
  end

  def test_clean_native_package_archive_removes_bundle_and_archive
    Dir.mktmpdir("milk-tea-build-native-archive-clean") do |dir|
      package_root = File.join(dir, "desktop-demo")
      src_dir = File.join(package_root, "src")
      bundle_root = File.join(package_root, "build", "dist", "linux", "debug", "desktop_demo")
      archive_path = "#{bundle_root}.tar.gz"
      FileUtils.mkdir_p(src_dir)
      FileUtils.mkdir_p(bundle_root)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "desktop_demo"

        [platform]
        default = "linux"

        [build]
        entry = "src/main.mt"
      TOML

      File.write(File.join(src_dir, "main.mt"), [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))
      File.write(File.join(bundle_root, "desktop_demo"), "stale")
      File.write(archive_path, "archive")

      cleaned = MilkTea::Build.clean(package_root, archive: true)

      assert_equal File.join(package_root, "build", "dist"), cleaned
      refute File.exist?(bundle_root)
      refute File.exist?(archive_path)
    end
  end

  def test_build_emits_debug_map_sidecar_for_user_functions
    Dir.mktmpdir("milk-tea-build-debug-map") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      source_path = File.join(dir, "debug-map.mt")
      output_path = File.join(dir, "debug-map")

      File.write(source_path, [
        "function add(a: int, b: int) -> int:",
        "    let total = a + b",
        "    return total",
        "",
        "function main() -> int:",
        "    return add(1, 2)",
        "",
      ].join("\n"))

      MilkTea::Build.build(source_path, output_path:, cc: compiler_path)

      debug_map_path = MilkTea::DebugMap.sidecar_path_for(output_path)
      assert File.exist?(debug_map_path)

      payload = JSON.parse(File.read(debug_map_path))
      assert_equal "debug-map", payload["binaryPath"]
      assert_equal "debug-map.mt", payload["programSourcePath"]

      add_function = payload.fetch("functions").find { |function| function["cName"] == "debug_map_add" }
      refute_nil add_function
      assert_equal "add", add_function["name"]
      assert_equal "debug-map.mt", add_function["sourcePath"]
      assert_equal %w[a b], add_function.fetch("params").map { |param| param["name"] }
      assert_equal %w[a b], add_function.fetch("params").map { |param| param["cName"] }
      assert_equal ["total"], add_function.fetch("locals").map { |entry| entry["name"] }
      assert_equal ["total"], add_function.fetch("locals").map { |entry| entry["cName"] }

      loaded = MilkTea::DebugMap.load(debug_map_path)
      assert_equal File.expand_path(output_path), loaded.binary_path
      assert_equal File.expand_path(source_path), loaded.program_source_path
      assert_equal File.expand_path(source_path), loaded.function_for_c_name("debug_map_add").source_path
    end
  end

  def test_build_with_host_compiler_produces_runnable_binary
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-build-real") do |dir|
      source_path = File.join(dir, "smoke.mt")
      output_path = File.join(dir, "smoke")

      File.write(source_path, [
        "const base: int = 40",
        "",
        "function main() -> int:",
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

  def test_build_with_host_compiler_supports_safe_span_str_main_args
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-build-main-span-args") do |dir|
      source_path = File.join(dir, "main-span-args.mt")
      output_path = File.join(dir, "main-span-args")

      File.write(source_path, [
        "function main(args: span[str]) -> int:",
        "    if args.len != 2:",
        "        return 9",
        "    return int<-args[0].len + int<-args[1].len",
        "",
      ].join("\n"))

      result = MilkTea::Build.build(source_path, output_path:, cc: compiler)

      assert_equal File.expand_path(output_path), result.output_path
      assert File.exist?(output_path)
      assert File.executable?(output_path)

      stdout, stderr, status = Open3.capture3(output_path, "alpha", "beta")
      assert_equal "", stdout
      assert_equal "", stderr
      assert_equal 9, status.exitstatus
    end
  end

  def test_build_with_host_compiler_supports_async_safe_span_str_main_args
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-build-async-main-span-args") do |dir|
      source_path = File.join(dir, "async-main-span-args.mt")
      output_path = File.join(dir, "async-main-span-args")

      File.write(source_path, [
        "async function main(args: span[str]) -> int:",
        "    if args.len != 2:",
        "        return 9",
        "    return int<-args[0].len + int<-args[1].len",
        "",
      ].join("\n"))

      result = MilkTea::Build.build(source_path, output_path:, cc: compiler)

      assert_equal File.expand_path(output_path), result.output_path
      assert File.exist?(output_path)
      assert File.executable?(output_path)

      stdout, stderr, status = Open3.capture3(output_path, "alpha", "beta")
      assert_equal "", stdout
      assert_equal "", stderr
      assert_equal 9, status.exitstatus
    end
  end

  def test_build_rejects_invalid_root_main_signature_before_compiling
    Dir.mktmpdir("milk-tea-build-invalid-main-signature") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      source_path = File.join(dir, "invalid-main.mt")

      File.write(source_path, [
        "function main(args: array[str, 2]) -> int:",
        "    return 0",
        "",
      ].join("\n"))

      error = assert_raises(MilkTea::BuildError) do
        MilkTea::Build.build(source_path, cc: compiler_path)
      end

      assert_match(/root main is not a valid executable entrypoint/, error.message)
      refute File.exist?(compiler_log)
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
        "external",
        "include \"stdio.h\"",
        "",
        "external function printf(format: cstr, ...) -> int",
        "",
      ].join("\n"))

      source_path = File.join(workspace_dir, "demo", "main.mt")
      output_path = File.join(workspace_dir, "demo", "main")

      File.write(source_path, [
        "import #{unique_root}.std.c.stdio as c",
        "",
        "function main() -> int:",
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
        "import std.c.time as ctime",
        "",
        "const time_format: cstr = c\"%H:%M:%S\"",
        "",
        "function main() -> int:",
        "    var now: ctime.time_t = 0",
        "    now = ctime.time(ptr_of(now))",
        "    let tm_info = ctime.localtime(ptr_of(now))",
        "    var time_buffer = zero[array[char, 9]]",
        "    if tm_info == null:",
        "        return 1",
        "    unsafe:",
        "        ctime.strftime(ptr_of(time_buffer[0]), 9, time_format, ptr[ctime.tm]<-tm_info)",
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

  def test_build_source_file_inside_package_uses_nearest_package_manifest
    Dir.mktmpdir("milk-tea-build-package-entry") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      package_root = File.join(dir, "snake-duel")
      src_dir = File.join(package_root, "src")
      FileUtils.mkdir_p(src_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"

        [profile]
        default = "debug"

        [platform]
        default = "linux"
      TOML

      File.write(File.join(src_dir, "game_types.mt"), [
        "public function value() -> int:",
        "    return 41",
        "",
      ].join("\n"))

      source_path = File.join(src_dir, "main.mt")
      File.write(source_path, [
        "",
        "import game_types as gt",
        "",
        "function main() -> int:",
        "    return gt.value() + 1",
        "",
      ].join("\n"))

      result = MilkTea::Build.build(source_path, cc: compiler_path)
      expected_output = File.join(package_root, "build", "bin", "linux", "debug", "snake_duel")

      assert_equal File.expand_path(expected_output), result.output_path
      assert_equal :debug, result.profile
      assert_equal :linux, result.platform
      assert File.exist?(expected_output)

      invocation = File.read(compiler_log).lines(chomp: true)
      assert_includes invocation, File.expand_path(expected_output)
    end
  end

  def test_build_source_file_inside_package_resolves_path_dependency_source_roots
    Dir.mktmpdir("milk-tea-build-package-dependency") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")
      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [build]
        entry = "src/snake_duel/main.mt"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        kind = "library"
        source_root = "src"
      TOML

      source_path = File.join(app_src_dir, "main.mt")
      File.write(source_path, [
        "import teefan.ui.layout as layout",
        "",
        "function main() -> int:",
        "    return layout.default_width() - 10",
        "",
      ].join("\n"))

      File.write(File.join(ui_src_dir, "layout.mt"), [
        "public function default_width() -> int:",
        "    return 10",
        "",
      ].join("\n"))

      result = MilkTea::Build.build(source_path, cc: compiler_path)
      expected_output = File.join(app_root, "build", "bin", "linux", "debug", "snake_duel")

      assert_equal File.expand_path(expected_output), result.output_path
      assert File.exist?(expected_output)

      invocation = File.read(compiler_log).lines(chomp: true)
      assert_includes invocation, File.expand_path(expected_output)
    end
  end

  def test_build_source_file_inside_package_uses_wasm_manifest_defaults
    Dir.mktmpdir("milk-tea-build-package-wasm") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      package_root = File.join(dir, "web-demo")
      src_dir = File.join(package_root, "src")
      FileUtils.mkdir_p(src_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "web_demo"

        [build]
        entry = "src/main.mt"

        [platform]
        default = "wasm"
      TOML

      File.write(File.join(src_dir, "main.mt"), [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))

      result = MilkTea::Build.build(package_root, cc: compiler_path)
      expected_output = File.join(package_root, "build", "bin", "wasm", "debug", "web_demo.html")

      assert_equal File.expand_path(expected_output), result.output_path
      assert_equal :wasm, result.platform
      assert File.exist?(expected_output)
    end
  end

  def test_build_source_file_inside_package_surfaces_invalid_manifest
    Dir.mktmpdir("milk-tea-build-invalid-package-manifest") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      package_root = File.join(dir, "snake-duel")
      src_dir = File.join(package_root, "src")
      FileUtils.mkdir_p(src_dir)

      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"

        [build]
        entry =
      TOML

      source_path = File.join(src_dir, "main.mt")
      File.write(source_path, [
        "function main() -> int:",
        "    return 0",
        "",
      ].join("\n"))

      error = assert_raises(MilkTea::BuildError) do
        MilkTea::Build.build(source_path, cc: compiler_path)
      end

      assert_match(/invalid package\.toml/, error.message)
      refute File.exist?(compiler_log)
    end
  end

  def test_clean_removes_wasm_bundle_artifacts_for_explicit_output
    Dir.mktmpdir("milk-tea-build-clean-wasm") do |dir|
      output_path = File.join(dir, "bundle.html")
      File.write(output_path, "html")
      File.write(File.join(dir, "bundle.js"), "js")
      File.write(File.join(dir, "bundle.wasm"), "wasm")
      File.write(File.join(dir, "bundle.data"), "data")
      File.write(MilkTea::DebugMap.sidecar_path_for(output_path), "debug-map")

      cleaned = MilkTea::Build.clean(language_fixture_path, output_path:, platform: :wasm)

      assert_equal File.expand_path(output_path), cleaned
      refute File.exist?(output_path)
      refute File.exist?(File.join(dir, "bundle.js"))
      refute File.exist?(File.join(dir, "bundle.wasm"))
      refute File.exist?(File.join(dir, "bundle.data"))
      refute File.exist?(MilkTea::DebugMap.sidecar_path_for(output_path))
    end
  end

  def test_build_with_host_compiler_uses_distinct_loop_labels_across_sibling_nested_blocks
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-build-loop-labels") do |dir|
      source_path = File.join(dir, "loop-labels.mt")
      output_path = File.join(dir, "loop-labels")

      File.write(source_path, [
        "function main() -> int:",
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

  def test_build_includes_raw_binding_compiler_flags_for_imported_raw_modules
    Dir.mktmpdir("milk-tea-build-raw-binding-flags") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      output_path = File.join(dir, "raylib-smoke")
      source_path = write_raylib_smoke_source(dir)
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

      MilkTea::Build.build(source_path, output_path:, cc: compiler_path, raw_bindings:)

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

  def test_build_runs_raw_binding_prepare_hook_for_imported_raw_modules
    Dir.mktmpdir("milk-tea-build-raw-binding-prepare") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      output_path = File.join(dir, "raylib-smoke")
      source_path = write_raylib_smoke_source(dir)
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

      MilkTea::Build.build(source_path, output_path:, cc: compiler_path, raw_bindings:)

      assert_equal [File.expand_path(compiler_path)], prepared
    end
  end

  def test_build_raylib_wasm_uses_web_raylib_archive_and_flags
    Dir.mktmpdir("milk-tea-build-raylib-wasm") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = File.join(dir, "fake-emcc")
      source_path = write_raylib_smoke_source(dir)
      output_path = File.join(dir, "raylib-web")
      raw_bindings = MilkTea::RawBindings.default_registry(root: MilkTea.root)

      File.write(compiler_path, <<~SH)
        #!/bin/sh
        {
          printf '%s\n' '---'
          printf '%s\n' "$@"
        } >> #{compiler_log.inspect}
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
      File.chmod(0o755, compiler_path)

      result = MilkTea::Build.build(source_path, output_path:, cc: compiler_path, raw_bindings:, platform: :wasm)

      assert_equal File.expand_path("#{output_path}.html"), result.output_path

      log = File.read(compiler_log)
      assert_includes log, "-DPLATFORM_WEB"
      assert_includes log, "-DGRAPHICS_API_OPENGL_ES2"
      assert_includes log, "-DMA_ENABLE_AUDIO_WORKLETS"
      assert_includes log, "-sUSE_GLFW=3"
      assert_includes log, "-sAUDIO_WORKLET=1"
      assert_includes log, "-sWASM_WORKERS=1"
      assert_includes log, "-sASYNCIFY"
      assert_match(/---\n.*\n-c\n.*\n-sAUDIO_WORKLET=1\n.*\n-sWASM_WORKERS=1\n/m, log)
      assert_includes log, "tmp/vendored-raylib-web"
      refute_includes log, "-DGRAPHICS_API_OPENGL_43"
      refute_includes log, "tmp/vendored-raylib-opengl43"
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
        "import std.c.raygui as gui",
        "",
        "function main() -> int:",
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
      refute_match(/^#line\s+/m, File.read(c_path))

      invocation = File.read(compiler_log).lines(chomp: true)
      assert_includes invocation, "-lraylib"
      assert_includes invocation, "-lm"
      assert_includes invocation, "-DRAYGUI_IMPLEMENTATION"
      assert_includes invocation, "-I#{File.expand_path('../../third_party/raylib-upstream/examples/shapes', __dir__)}"
    end
  end

  def test_build_uses_raymath_static_inline_binding_flags_when_imported
    Dir.mktmpdir("milk-tea-build-raymath") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)
      source_path = File.join(dir, "raymath.mt")
      output_path = File.join(dir, "raymath-demo")
      c_path = File.join(dir, "raymath-demo.c")

      File.write(source_path, [
        "import std.raymath as rm",
        "import std.raylib as rl",
        "",
        "function main() -> int:",
        "    let unit = rl.Vector2.one().clamp_value(1.0, 1.0)",
        "    return unit.equals(rl.Vector2.one()) + rm.float_equals(rm.clamp(2.0, 0.0, 1.0), 1.0)",
        "",
      ].join("\n"))

      result = MilkTea::Build.build(source_path, output_path:, cc: compiler_path, keep_c_path: c_path)

      assert_equal File.expand_path(output_path), result.output_path
      assert_equal File.expand_path(c_path), result.c_path
      assert_equal File.expand_path(compiler_path), result.compiler
      assert_includes result.link_flags, "-lraylib"
      assert_includes result.link_flags, "-lm"
      assert_match(/#include "raylib\.h"/, File.read(c_path))
      assert_match(/#include "raymath\.h"/, File.read(c_path))
      refute_match(/^#line\s+/m, File.read(c_path))

      invocation = File.read(compiler_log).lines(chomp: true)
      assert_includes invocation, "-lraylib"
      assert_includes invocation, "-lm"
      assert_includes invocation, "-DRAYMATH_STATIC_INLINE"
    end
  end

  private

  def parse_asset_pack(path)
    bytes = File.binread(path)
    magic, version, header_flags, entry_count, index_size, data_offset = bytes.byteslice(0, MilkTea::AssetPack::HEADER_SIZE).unpack(MilkTea::AssetPack::HEADER_FORMAT)

    offset = MilkTea::AssetPack::HEADER_SIZE
    entries = []
    entry_count.times do
      path_length, flags, entry_data_offset, stored_size, unpacked_size = bytes.byteslice(offset, MilkTea::AssetPack::ENTRY_PREFIX_SIZE).unpack(MilkTea::AssetPack::ENTRY_PREFIX_FORMAT)
      offset += MilkTea::AssetPack::ENTRY_PREFIX_SIZE

      path_bytes = bytes.byteslice(offset, path_length)
      offset += path_length

      entries << {
        path: path_bytes.force_encoding(Encoding::UTF_8),
        flags:,
        data_offset: entry_data_offset,
        stored_size:,
        unpacked_size:,
        data: bytes.byteslice(entry_data_offset, stored_size),
      }
    end

    {
      magic:,
      version:,
      header_flags:,
      entry_count:,
      index_size:,
      data_offset:,
      entries:,
    }
  end

  def language_fixture_path
    File.expand_path("../fixtures/language_fixture.mt", __dir__)
  end

  def write_raylib_smoke_source(dir)
    path = File.join(dir, "raylib_smoke.mt")
    File.write(path, [
      "import std.raylib as rl",
      "",
      "function main() -> int:",
      "    let tint = rl.RED.alpha(0.5)",
      "    var image = rl.Image.text(\"hi\", 16, tint)",
      "    image.mipmaps()",
      "    return 0",
      "",
    ].join("\n"))
    path
  end

  def write_fake_compiler(dir, log_path, shell_copy_path: nil)
    path = File.join(dir, "fake-cc")
    File.write(path, <<~SH)
      #!/bin/sh
      printf '%s\n' "$@" > #{log_path.inspect}
      shell_copy_target=#{(shell_copy_path || "").inspect}
      output=''
      shell_file=''
      previous=''
      for argument in "$@"; do
        if [ "$previous" = '-o' ]; then
          output="$argument"
        fi
        if [ "$previous" = '--shell-file' ]; then
          shell_file="$argument"
        fi
        previous="$argument"
      done
      if [ -n "$shell_file" ] && [ -n "$shell_copy_target" ]; then
        cp "$shell_file" "$shell_copy_target"
      fi
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

  def with_singleton_method_override(object, method_name, implementation)
    singleton_class = class << object; self; end
    original_name = "__build_test_original_#{method_name}__"
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
