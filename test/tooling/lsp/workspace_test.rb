# frozen_string_literal: true

require_relative "../../test_helper"

class LSPWorkspaceTest < Minitest::Test
  def test_open_document_reports_eager_analysis_stats_for_small_documents
    workspace = MilkTea::LSP::Workspace.new
    uri = "file:///tmp/lsp_workspace_open_stats.mt"

    stats = workspace.open_document(uri, <<~MT)
      module main

      function main() -> int:
          return 0
    MT

    assert_equal true, stats[:eager_analysis]
    assert_equal :memory, stats[:analysis_mode]
    assert_nil stats[:skip_reason]
    assert_kind_of Numeric, stats[:analysis_ms]
    assert_operator stats[:analysis_ms], :>=, 0
    assert_operator stats[:lines], :>=, 4
  end

  def test_open_document_eagerly_analyzes_large_documents
    workspace = MilkTea::LSP::Workspace.new
    uri = "file:///tmp/lsp_workspace_large_open.mt"
    content = "module main\n" + ("# filler\n" * 1201)

    stats = workspace.open_document(uri, content)

    assert_equal true, stats[:eager_analysis]
    assert_equal :memory, stats[:analysis_mode]
    assert_nil stats[:skip_reason]
    assert_kind_of Numeric, stats[:analysis_ms]
  end

  def test_open_document_eagerly_analyzes_std_paths
    Dir.mktmpdir("lsp_workspace_std_open") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)
      path = File.join(std_dir, "sample_text.mt")
      content = <<~MT
        module std.sample_text

        import std.maybe as maybe
        import std.string as string

        public function parse() -> int:
            return 0
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      stats = workspace.open_document(path_to_uri(path), content)

      assert_equal true, stats[:eager_analysis]
      assert_equal :module_loader, stats[:analysis_mode]
      assert_nil stats[:skip_reason]
      assert_equal 2, stats[:import_count]
      assert_kind_of Numeric, stats[:analysis_ms]
    end
  end

  def test_open_document_eagerly_analyzes_import_heavy_files
    Dir.mktmpdir("lsp_workspace_import_heavy_open") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      path = File.join(dir, "main.mt")
      body = (1..55).map { |i| "# filler #{i}" }.join("\n")
      content = <<~MT
        module main

        import mathx as mx
        import mathy as my

        function main() -> int:
            return 0

        #{body}
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      stats = workspace.open_document(path_to_uri(path), content)

      assert_equal true, stats[:eager_analysis]
      assert_equal :module_loader, stats[:analysis_mode]
      assert_nil stats[:skip_reason]
      assert_equal 2, stats[:import_count]
      assert_kind_of Numeric, stats[:analysis_ms]
    end
  end

  def test_open_document_eagerly_analyzes_small_files_with_many_imports
    Dir.mktmpdir("lsp_workspace_many_imports_open") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      path = File.join(dir, "main.mt")
      content = <<~MT
        module main

        import alpha as a
        import beta as b
        import gamma as g
        import delta as d

        function main() -> int:
            return 0
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      stats = workspace.open_document(path_to_uri(path), content)

      assert_equal true, stats[:eager_analysis]
      assert_equal :module_loader, stats[:analysis_mode]
      assert_nil stats[:skip_reason]
      assert_equal 4, stats[:import_count]
      assert_kind_of Numeric, stats[:analysis_ms]
    end
  end

  def test_open_document_eagerly_analyzes_single_large_imported_file
    Dir.mktmpdir("lsp_workspace_single_import_large_open") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      path = File.join(dir, "main.mt")
      body = (1..155).map { |i| "# filler #{i}" }.join("\n")
      content = <<~MT
        module main

        import mathx as mx

        function main() -> int:
            return 0

        #{body}
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      stats = workspace.open_document(path_to_uri(path), content)

      assert_equal true, stats[:eager_analysis]
      assert_equal :module_loader, stats[:analysis_mode]
      assert_nil stats[:skip_reason]
      assert_equal 1, stats[:import_count]
      assert_kind_of Numeric, stats[:analysis_ms]
    end
  end

  def test_open_document_eagerly_analyzes_background_documents
    workspace = MilkTea::LSP::Workspace.new
    uri = "file:///tmp/lsp_workspace_background.mt"
    workspace.set_document_source(uri, "background-document")

    stats = workspace.open_document(uri, <<~MT)
      module main

      function main() -> int:
          return 0
    MT

    assert_equal true, stats[:eager_analysis]
    assert_equal :memory, stats[:analysis_mode]
    assert_nil stats[:skip_reason]
    assert_equal 0, stats[:import_count]
    assert_kind_of Numeric, stats[:analysis_ms]
  ensure
    workspace&.shutdown
  end

  def test_update_document_eagerly_analyzes_import_heavy_files
    Dir.mktmpdir("lsp_workspace_import_heavy_update") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      path = File.join(dir, "main.mt")
      body = (1..55).map { |i| "# filler #{i}" }.join("\n")
      content = <<~MT
        module main

        import mathx as mx
        import mathy as my

        function main() -> int:
            return 0

        #{body}
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      stats = workspace.update_document(path_to_uri(path), content)

      assert_equal true, stats[:eager_analysis]
      assert_equal :module_loader, stats[:analysis_mode]
      assert_nil stats[:skip_reason]
      assert_equal 2, stats[:import_count]
      assert_kind_of Numeric, stats[:analysis_ms]
    ensure
      workspace&.shutdown
    end
  end

  def test_open_document_populates_analysis_cache_for_std_paths
    Dir.mktmpdir("lsp_workspace_analysis_warmup") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)
      path = File.join(std_dir, "demo.mt")
      content = <<~MT
        module std.demo

        public function answer() -> int:
            return 42
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      stats = workspace.open_document(uri, content)

      assert_equal true, stats[:eager_analysis]
      assert_equal :module_loader, stats[:analysis_mode]
      assert_nil stats[:skip_reason]

      refute_nil workspace.instance_variable_get(:@analysis_cache)[uri]
      refute_nil workspace.instance_variable_get(:@last_good_analysis_cache)[uri]
    ensure
      workspace&.shutdown
    end
  end

  def test_open_document_live_resolves_transitive_duplicate_path_package_names
    Dir.mktmpdir("lsp_workspace_live_package_instances") do |dir|
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

      root_path = File.join(app_src_dir, "main.mt")
      overlay_path = File.join(overlay_src_dir, "panel.mt")
      root_source = <<~MT
        module snake_duel.main

        import teefan.ui.layout as layout
        import teefan.overlay.panel as panel

        function main() -> int:
            return layout.default_width() + panel.overlay_width()
      MT
      overlay_source = <<~MT
        module teefan.overlay.panel

        import teefan.ui.layout as layout

        public function overlay_width() -> int:
            return layout.overlay_width()
      MT

      File.write(root_path, root_source)
      File.write(overlay_path, overlay_source)

      File.write(File.join(ui_v1_src_dir, "layout.mt"), <<~MT)
        module teefan.ui.layout

        public function default_width() -> int:
            return 10
      MT

      File.write(File.join(ui_v2_src_dir, "layout.mt"), <<~MT)
        module teefan.ui.layout

        public function default_width() -> int:
            return 20

        public function overlay_width() -> int:
            return 7
      MT

      workspace = MilkTea::LSP::Workspace.new
      workspace.dependency_resolution_mode = :live

      root_uri = path_to_uri(root_path)
      overlay_uri = path_to_uri(overlay_path)
      workspace.open_document(root_uri, root_source)
      workspace.open_document(overlay_uri, overlay_source)

      root_analysis = workspace.get_analysis(root_uri)
      overlay_analysis = workspace.get_analysis(overlay_uri)

      assert_equal %w[default_width], root_analysis.imports.fetch("layout").functions.keys.sort
      assert_equal %w[default_width overlay_width], overlay_analysis.imports.fetch("layout").functions.keys.sort
      assert_equal [], workspace.collect_diagnostics(root_uri)
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_populates_analysis_cache_for_open_documents
    Dir.mktmpdir("lsp_workspace_diagnostics_cache") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)
      path = File.join(std_dir, "demo.mt")
      content = <<~MT
        module std.demo

        public function answer() -> int:
            return 42
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      assert_equal [], workspace.collect_diagnostics(uri)
      refute_nil workspace.instance_variable_get(:@analysis_cache)[uri]
      refute_nil workspace.instance_variable_get(:@last_good_analysis_cache)[uri]
    ensure
      workspace&.shutdown
    end
  end

  def test_get_analysis_keeps_open_shared_file_as_root_while_imports_follow_platform_override
    Dir.mktmpdir("lsp_workspace_platform_override") do |dir|
      main_path = File.join(dir, "main.mt")
      main_windows_path = File.join(dir, "main.windows.mt")
      support_path = File.join(dir, "support.mt")
      support_windows_path = File.join(dir, "support.windows.mt")

      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "demo"
      TOML

      File.write(main_path, <<~MT)
        module demo.main

        import support

        function main() -> int:
            return support.value()
      MT

      File.write(main_windows_path, <<~MT)
        module demo.main

        function main() -> int:
            return missing_symbol
      MT

      File.write(support_path, <<~MT)
        module support

        public function value() -> int:
            return 1
      MT

      File.write(support_windows_path, <<~MT)
        module support

        public function value() -> int:
            return 2
      MT

      workspace = MilkTea::LSP::Workspace.new
      workspace.platform_override = :windows
      main_uri = path_to_uri(main_path)
      workspace.open_document(main_uri, File.read(main_path))

      analysis = workspace.get_analysis(main_uri)

      refute_nil analysis
      assert_equal "demo.main", analysis.module_name
      assert_equal %w[value], analysis.imports.fetch("support").functions.keys.sort
      assert_equal [], workspace.collect_diagnostics(main_uri)
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_anchors_missing_import_to_import_path
    Dir.mktmpdir("lsp_workspace_missing_import_anchor") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        module demo.main

        import demo.missing.lib as missing

        function main() -> int:
            return 0
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      missing_import = diagnostics.find { |diagnostic| diagnostic[:message] == "module not found: demo.missing.lib" }

      refute_nil missing_import
      assert_equal 2, missing_import.dig(:range, :start, :line)
      assert_equal 7, missing_import.dig(:range, :start, :character)
      assert_equal 23, missing_import.dig(:range, :end, :character)
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_does_not_report_method_only_import_as_unused
    Dir.mktmpdir("lsp_workspace_method_only_import") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      File.write(File.join(std_dir, "string.mt"), <<~MT)
        module std.string

        public struct String:
            value: str

        methods String:
            public function as_str() -> str:
                return this.value
      MT

      File.write(File.join(dir, "util.mt"), <<~MT)
        module util

        import std.string as string

        public function make() -> string.String:
            return string.String(value = "hi")
      MT

      path = File.join(dir, "main.mt")
      content = <<~MT
        module demo.main

        import util
        import std.string as string

        function main() -> str:
            let value = util.make()
            return value.as_str()
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      refute diagnostics.any? { |diagnostic| diagnostic[:code] == "unused-import" && diagnostic[:message].include?("string") }
      assert_equal [], diagnostics
    ensure
      workspace&.shutdown
    end
  end

  def test_index_workspace_does_not_start_definition_warmup_for_every_file
    Dir.mktmpdir("lsp_workspace_index") do |dir|
      path = File.join(dir, "main.mt")
      File.write(path, "module main\n")

      workspace = MilkTea::LSP::Workspace.new
      workspace.index_workspace(path_to_uri(dir))

      assert_nil workspace.instance_variable_get(:@definition_warmup_thread)
      assert_equal "module main\n", workspace.get_content(path_to_uri(path))
    ensure
      workspace&.shutdown
    end
  end

  private

  def path_to_uri(path)
    "file://#{path}"
  end

  def test_apply_incremental_change_uses_utf16_character_positions_for_surrogate_pairs
    workspace = MilkTea::LSP::Workspace.new
    uri = "file:///tmp/lsp_workspace_utf16_replace.mt"
    workspace.open_document(uri, "let s = \"😀\"\n")

    # Replace only the emoji. In UTF-16 offsets, emoji spans [9, 11).
    workspace.apply_incremental_change(uri, {
      "range" => {
        "start" => { "line" => 0, "character" => 9 },
        "end" => { "line" => 0, "character" => 11 }
      },
      "text" => "X"
    })

    assert_equal "let s = \"X\"\n", workspace.get_content(uri)
  end

  def test_apply_incremental_change_can_insert_after_surrogate_pair
    workspace = MilkTea::LSP::Workspace.new
    uri = "file:///tmp/lsp_workspace_utf16_insert.mt"
    workspace.open_document(uri, "let s = \"😀\"\n")

    # Insert right after the emoji. In UTF-16, that position is char 11.
    workspace.apply_incremental_change(uri, {
      "range" => {
        "start" => { "line" => 0, "character" => 11 },
        "end" => { "line" => 0, "character" => 11 }
      },
      "text" => "!"
    })

    assert_equal "let s = \"😀!\"\n", workspace.get_content(uri)
  end
end
