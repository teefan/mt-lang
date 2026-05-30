# frozen_string_literal: true

require_relative "../../test_helper"

class LSPWorkspaceTest < Minitest::Test
  def teardown
    ObjectSpace.each_object(MilkTea::LSP::Workspace) do |workspace|
      workspace.shutdown
    rescue StandardError
      nil
    end

    super
  end

  def test_shutdown_stops_definition_warmup_thread
    workspace = MilkTea::LSP::Workspace.new

    workspace.send(:enqueue_definition_warmup, "file:///tmp/lsp_workspace_shutdown.mt")
    thread = workspace.instance_variable_get(:@definition_warmup_thread)

    refute_nil thread

    workspace.shutdown

    assert_equal false, thread.alive?
  end

  def test_open_document_reports_eager_facts_stats_for_small_documents
    workspace = MilkTea::LSP::Workspace.new
    uri = "file:///tmp/lsp_workspace_open_stats.mt"

    stats = workspace.open_document(uri, <<~MT)
      function main() -> int:
          return 0
    MT

    assert_equal true, stats[:eager_facts]
    assert_equal :memory, stats[:facts_mode]
    assert_nil stats[:skip_reason]
    assert_kind_of Numeric, stats[:facts_ms]
    assert_operator stats[:facts_ms], :>=, 0
    assert_operator stats[:lines], :>=, 3
  end

  def test_open_document_eagerly_analyzes_large_documents
    workspace = MilkTea::LSP::Workspace.new
    uri = "file:///tmp/lsp_workspace_large_open.mt"
    content = "module main\n" + ("# filler\n" * 1201)

    stats = workspace.open_document(uri, content)

    assert_equal true, stats[:eager_facts]
    assert_equal :memory, stats[:facts_mode]
    assert_nil stats[:skip_reason]
    assert_kind_of Numeric, stats[:facts_ms]
  end

  def test_open_document_eagerly_analyzes_std_paths
    Dir.mktmpdir("lsp_workspace_std_open") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)
      path = File.join(std_dir, "sample_text.mt")
      content = <<~MT

        import std.string as string

        public function parse() -> int:
            return 0
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      stats = workspace.open_document(path_to_uri(path), content)

      assert_equal true, stats[:eager_facts]
      assert_equal :module_loader, stats[:facts_mode]
      assert_nil stats[:skip_reason]
      assert_equal 1, stats[:import_count]
      assert_kind_of Numeric, stats[:facts_ms]
    end
  end

  def test_open_document_eagerly_analyzes_import_heavy_files
    Dir.mktmpdir("lsp_workspace_import_heavy_open") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      path = File.join(dir, "main.mt")
      body = (1..55).map { |i| "# filler #{i}" }.join("\n")
      content = <<~MT
        import mathx as mx
        import mathy as my

        function main() -> int:
            return 0

        #{body}
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      stats = workspace.open_document(path_to_uri(path), content)

      assert_equal true, stats[:eager_facts]
      assert_equal :module_loader, stats[:facts_mode]
      assert_nil stats[:skip_reason]
      assert_equal 2, stats[:import_count]
      assert_kind_of Numeric, stats[:facts_ms]
    end
  end

  def test_open_document_eagerly_analyzes_small_files_with_many_imports
    Dir.mktmpdir("lsp_workspace_many_imports_open") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      path = File.join(dir, "main.mt")
      content = <<~MT
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

      assert_equal true, stats[:eager_facts]
      assert_equal :module_loader, stats[:facts_mode]
      assert_nil stats[:skip_reason]
      assert_equal 4, stats[:import_count]
      assert_kind_of Numeric, stats[:facts_ms]
    end
  end

  def test_open_document_eagerly_analyzes_single_large_imported_file
    Dir.mktmpdir("lsp_workspace_single_import_large_open") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      path = File.join(dir, "main.mt")
      body = (1..155).map { |i| "# filler #{i}" }.join("\n")
      content = <<~MT
        import mathx as mx

        function main() -> int:
            return 0

        #{body}
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      stats = workspace.open_document(path_to_uri(path), content)

      assert_equal true, stats[:eager_facts]
      assert_equal :module_loader, stats[:facts_mode]
      assert_nil stats[:skip_reason]
      assert_equal 1, stats[:import_count]
      assert_kind_of Numeric, stats[:facts_ms]
    end
  end

  def test_open_document_skips_eager_facts_for_background_documents
    workspace = MilkTea::LSP::Workspace.new
    uri = "file:///tmp/lsp_workspace_background.mt"
    workspace.set_document_source(uri, "background-document")

    stats = workspace.open_document(uri, <<~MT)
      function main() -> int:
          return 0
    MT

    assert_equal false, stats[:eager_facts]
    assert_nil stats[:facts_mode]
    assert_equal :background_document, stats[:skip_reason]
    assert_equal 0, stats[:import_count]
    assert_nil stats[:facts_ms]
  ensure
    workspace&.shutdown
  end

  def test_update_document_eagerly_analyzes_import_heavy_files
    Dir.mktmpdir("lsp_workspace_import_heavy_update") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      path = File.join(dir, "main.mt")
      body = (1..55).map { |i| "# filler #{i}" }.join("\n")
      content = <<~MT
        import mathx as mx
        import mathy as my

        function main() -> int:
            return 0

        #{body}
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      stats = workspace.update_document(path_to_uri(path), content)

      assert_equal true, stats[:eager_facts]
      assert_equal :module_loader, stats[:facts_mode]
      assert_nil stats[:skip_reason]
      assert_equal 2, stats[:import_count]
      assert_kind_of Numeric, stats[:facts_ms]
    ensure
      workspace&.shutdown
    end
  end

  def test_open_document_populates_facts_cache_for_std_paths
    Dir.mktmpdir("lsp_workspace_facts_warmup") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)
      path = File.join(std_dir, "demo.mt")
      content = <<~MT
        public function answer() -> int:
            return 42
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      stats = workspace.open_document(uri, content)

      assert_equal true, stats[:eager_facts]
      assert_equal :module_loader, stats[:facts_mode]
      assert_nil stats[:skip_reason]

      refute_nil workspace.instance_variable_get(:@tooling_snapshot_cache)[uri]
      refute_nil workspace.instance_variable_get(:@last_good_tooling_snapshot_cache)[uri]
      refute_nil workspace.instance_variable_get(:@facts_cache)[uri]
      refute_nil workspace.instance_variable_get(:@last_good_facts_cache)[uri]
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
        import teefan.ui.layout as layout
        import teefan.overlay.panel as panel

        function main() -> int:
            return layout.default_width() + panel.overlay_width()
      MT
      overlay_source = <<~MT
        import teefan.ui.layout as layout

        public function overlay_width() -> int:
            return layout.overlay_width()
      MT

      File.write(root_path, root_source)
      File.write(overlay_path, overlay_source)

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

      workspace = MilkTea::LSP::Workspace.new
      workspace.dependency_resolution_mode = :live

      root_uri = path_to_uri(root_path)
      overlay_uri = path_to_uri(overlay_path)
      workspace.open_document(root_uri, root_source)
      workspace.open_document(overlay_uri, overlay_source)

      root_analysis = workspace.get_facts(root_uri)
      overlay_analysis = workspace.get_facts(overlay_uri)

      assert_equal %w[default_width], root_analysis.imports.fetch("layout").functions.keys.sort
      assert_equal %w[default_width overlay_width], overlay_analysis.imports.fetch("layout").functions.keys.sort
      assert_equal [], workspace.collect_diagnostics(root_uri)
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_populates_facts_cache_for_open_documents
    Dir.mktmpdir("lsp_workspace_diagnostics_cache") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)
      path = File.join(std_dir, "demo.mt")
      content = <<~MT
        public function answer() -> int:
            return 42
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      assert_equal [], workspace.collect_diagnostics(uri)
      refute_nil workspace.instance_variable_get(:@tooling_snapshot_cache)[uri]
      refute_nil workspace.instance_variable_get(:@last_good_tooling_snapshot_cache)[uri]
      refute_nil workspace.instance_variable_get(:@facts_cache)[uri]
      refute_nil workspace.instance_variable_get(:@last_good_facts_cache)[uri]
    ensure
      workspace&.shutdown
    end
  end

  def test_get_facts_cache_hit_does_not_wait_for_facts_state_mutex
    Dir.mktmpdir("lsp_workspace_facts_cache_hit") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)
      path = File.join(std_dir, "demo.mt")
      content = <<~MT
        public function answer() -> int:
            return 42
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      state_mutex = workspace.instance_variable_get(:@facts_state_mutex)
      state_lock_held = Queue.new
      release_state_lock = Queue.new
      holder = Thread.new do
        state_mutex.synchronize do
          state_lock_held << true
          release_state_lock.pop
        end
      end
      state_lock_held.pop

      result = Queue.new
      reader = Thread.new do
        result << workspace.get_facts(uri)
      end

      assert reader.join(0.2), "expected cached facts to bypass the facts-state mutex"
      refute_nil result.pop
    ensure
      release_state_lock << true if release_state_lock
      stop_thread(holder)
      stop_thread(reader)
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_reuses_cached_tooling_snapshot
    Dir.mktmpdir("lsp_workspace_tooling_snapshot") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)
      path = File.join(std_dir, "demo.mt")
      content = <<~MT
        public function answer() -> int:
            return 42
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      facts = workspace.get_facts(uri)
      snapshot = workspace.get_tooling_snapshot(uri)
      diagnostics = workspace.collect_diagnostics(uri)

      assert_equal [], diagnostics
      assert_same snapshot, workspace.instance_variable_get(:@tooling_snapshot_cache)[uri]
      assert_same facts, workspace.get_tooling_snapshot(uri).facts
    ensure
      workspace&.shutdown
    end
  end

  def test_get_facts_cache_hit_survives_dependency_refresh_without_waiting
    Dir.mktmpdir("lsp_workspace_dependency_refresh_cache_hit") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      dependency_path = File.join(dir, "dep.mt")
      main_path = File.join(dir, "main.mt")
      dependency_source = <<~MT
        public function answer() -> int:
            return 42
      MT
      main_source = <<~MT
        import dep as dep

        function main() -> int:
            return dep.answer()
      MT
      File.write(dependency_path, dependency_source)
      File.write(main_path, main_source)

      workspace = MilkTea::LSP::Workspace.new
      dependency_uri = path_to_uri(dependency_path)
      main_uri = path_to_uri(main_path)
      workspace.open_document(dependency_uri, dependency_source)
      workspace.open_document(main_uri, main_source)
      refute_nil workspace.get_facts(main_uri)

      assert_equal [main_uri], workspace.send(:refresh_import_dependent_caches, changed_uri: dependency_uri)

      state_mutex = workspace.instance_variable_get(:@facts_state_mutex)
      state_lock_held = Queue.new
      release_state_lock = Queue.new
      holder = Thread.new do
        state_mutex.synchronize do
          state_lock_held << true
          release_state_lock.pop
        end
      end
      state_lock_held.pop

      result = Queue.new
      reader = Thread.new do
        result << workspace.get_facts(main_uri)
      end

      assert reader.join(0.2), "expected preserved open-document facts to bypass facts-state lock during dependency refresh"
      refute_nil result.pop
    ensure
      release_state_lock << true if release_state_lock
      stop_thread(holder)
      stop_thread(reader)
      workspace&.shutdown
    end
  end

  def test_get_facts_uses_last_good_fallback_after_dependency_refresh_from_closed_document
    Dir.mktmpdir("lsp_workspace_closed_dependency_refresh") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      dependency_path = File.join(dir, "dep.mt")
      main_path = File.join(dir, "main.mt")
      dependency_source = <<~MT
        public function answer() -> int:
            return 42
      MT
      main_source = <<~MT
        import dep as dep

        function main() -> int:
            return dep.answer()
      MT
      File.write(dependency_path, dependency_source)
      File.write(main_path, main_source)

      workspace = MilkTea::LSP::Workspace.new
      dependency_uri = path_to_uri(dependency_path)
      main_uri = path_to_uri(main_path)
      workspace.open_document(dependency_uri, dependency_source)
      workspace.open_document(main_uri, main_source)
      refute_nil workspace.get_facts(main_uri)

      workspace.close_document(dependency_uri)

      assert_equal [main_uri], workspace.send(:refresh_import_dependent_caches, changed_uri: dependency_uri)
      assert_nil workspace.instance_variable_get(:@tooling_snapshot_cache)[main_uri]
      refute_nil workspace.instance_variable_get(:@last_good_tooling_snapshot_cache)[main_uri]
      assert_nil workspace.instance_variable_get(:@facts_cache)[main_uri]
      refute_nil workspace.instance_variable_get(:@last_good_facts_cache)[main_uri]

      state_mutex = workspace.instance_variable_get(:@facts_state_mutex)
      state_lock_held = Queue.new
      release_state_lock = Queue.new
      holder = Thread.new do
        state_mutex.synchronize do
          state_lock_held << true
          release_state_lock.pop
        end
      end
      state_lock_held.pop

      result = Queue.new
      reader = Thread.new do
        result << workspace.get_facts(main_uri)
      end

      assert reader.join(0.2), "expected last-good facts to bypass facts-state lock after closed-document dependency refresh"
      refute_nil result.pop
    ensure
      release_state_lock << true if release_state_lock
      stop_thread(holder)
      stop_thread(reader)
      workspace&.shutdown
    end
  end

  def test_refresh_import_dependent_caches_only_returns_actual_open_dependents
    Dir.mktmpdir("lsp_workspace_reverse_import_dependents") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      dependency_path = File.join(dir, "dep.mt")
      main_path = File.join(dir, "main.mt")
      unrelated_path = File.join(dir, "other.mt")

      File.write(dependency_path, <<~MT)
        public function answer() -> int:
            return 42
      MT
      main_source = <<~MT
        import dep as dep

        function main() -> int:
            return dep.answer()
      MT
      unrelated_source = <<~MT
        function other() -> int:
            return 7
      MT
      File.write(main_path, main_source)
      File.write(unrelated_path, unrelated_source)

      workspace = MilkTea::LSP::Workspace.new
      dependency_uri = path_to_uri(dependency_path)
      main_uri = path_to_uri(main_path)
      unrelated_uri = path_to_uri(unrelated_path)
      workspace.open_document(dependency_uri, File.read(dependency_path))
      workspace.open_document(main_uri, main_source)
      workspace.open_document(unrelated_uri, unrelated_source)

      refute_nil workspace.get_facts(main_uri)
      refute_nil workspace.get_facts(unrelated_uri)

      assert_equal [main_uri], workspace.send(:refresh_import_dependent_caches, changed_uri: dependency_uri)
    ensure
      workspace&.shutdown
    end
  end

  def test_refresh_import_dependent_caches_tracks_semantically_invalid_importers
    Dir.mktmpdir("lsp_workspace_invalid_importer_dependents") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      dependency_path = File.join(dir, "dep.mt")
      main_path = File.join(dir, "main.mt")

      File.write(dependency_path, "")
      main_source = <<~MT
        import dep as dep

        public type Reply = dep.Answer
      MT
      File.write(main_path, main_source)

      workspace = MilkTea::LSP::Workspace.new
      dependency_uri = path_to_uri(dependency_path)
      main_uri = path_to_uri(main_path)
      workspace.open_document(dependency_uri, "")
      workspace.open_document(main_uri, main_source)

      assert_nil workspace.get_facts(main_uri)
      assert_equal [main_uri], workspace.send(:refresh_import_dependent_caches, changed_uri: dependency_uri)
    ensure
      workspace&.shutdown
    end
  end

  def test_apply_watched_file_change_created_module_refreshes_open_importers
    Dir.mktmpdir("lsp_workspace_created_dependency_refresh") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      dependency_path = File.join(dir, "dep.mt")
      main_path = File.join(dir, "main.mt")

      main_source = <<~MT
        import dep as dep

        function main() -> int:
            return dep.answer()
      MT
      File.write(main_path, main_source)

      workspace = MilkTea::LSP::Workspace.new
      dependency_uri = path_to_uri(dependency_path)
      main_uri = path_to_uri(main_path)
      workspace.open_document(main_uri, main_source)

      refute_nil workspace.collect_diagnostics(main_uri)

      File.write(dependency_path, <<~MT)
        public function answer() -> int:
            return 42
      MT

      assert_equal [main_uri], workspace.apply_watched_file_change(dependency_uri, 1)
    ensure
      workspace&.shutdown
    end
  end

  def test_apply_watched_file_change_deleted_module_refreshes_open_importers_without_cached_dependency_entry
    Dir.mktmpdir("lsp_workspace_deleted_dependency_refresh") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      dependency_path = File.join(dir, "dep.mt")
      main_path = File.join(dir, "main.mt")

      File.write(dependency_path, <<~MT)
        public function answer() -> int:
            return 42
      MT
      main_source = <<~MT
        import dep as dep

        function main() -> int:
            return dep.answer()
      MT
      File.write(main_path, main_source)

      workspace = MilkTea::LSP::Workspace.new
      dependency_uri = path_to_uri(dependency_path)
      main_uri = path_to_uri(main_path)
      workspace.open_document(main_uri, main_source)

      refute_nil workspace.get_facts(main_uri)

      File.delete(dependency_path)

      assert_equal [main_uri], workspace.apply_watched_file_change(dependency_uri, 3)
    ensure
      workspace&.shutdown
    end
  end

  def test_open_background_document_does_not_wait_for_facts_state_mutex
    workspace = MilkTea::LSP::Workspace.new
    uri = "file:///tmp/lsp_workspace_background_lock.mt"
    workspace.set_document_source(uri, "background-document")

    state_mutex = workspace.instance_variable_get(:@facts_state_mutex)
    state_lock_held = Queue.new
    release_state_lock = Queue.new
    holder = Thread.new do
      state_mutex.synchronize do
        state_lock_held << true
        release_state_lock.pop
      end
    end
    state_lock_held.pop

    result = Queue.new
    opener = Thread.new do
      result << workspace.open_document(uri, <<~MT)
        function main() -> int:
            return 0
      MT
    end

    assert opener.join(0.2), "expected background-document open to avoid waiting on facts-state lock during cache invalidation"
    stats = result.pop
    assert_equal false, stats[:eager_facts]
    assert_equal :background_document, stats[:skip_reason]
  ensure
    release_state_lock << true if release_state_lock
    stop_thread(holder)
    stop_thread(opener)
    workspace&.shutdown
  end

  def test_get_facts_keeps_open_shared_file_as_root_while_imports_follow_platform_override
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
        import support

        function main() -> int:
            return support.value()
      MT

      File.write(main_windows_path, <<~MT)
        function main() -> int:
            return missing_symbol
      MT

      File.write(support_path, <<~MT)
        public function value() -> int:
            return 1
      MT

      File.write(support_windows_path, <<~MT)
        public function value() -> int:
            return 2
      MT

      workspace = MilkTea::LSP::Workspace.new
      workspace.platform_override = :windows
      main_uri = path_to_uri(main_path)
      workspace.open_document(main_uri, File.read(main_path))

      facts = workspace.get_facts(main_uri)

      refute_nil facts
      assert_equal "main", facts.module_name
      assert_equal %w[value], facts.imports.fetch("support").functions.keys.sort
      assert_equal [], workspace.collect_diagnostics(main_uri)
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_anchors_missing_import_to_import_path
    Dir.mktmpdir("lsp_workspace_missing_import_anchor") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
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
      assert_equal 0, missing_import.dig(:range, :start, :line)
      assert_equal 7, missing_import.dig(:range, :start, :character)
      assert_equal 23, missing_import.dig(:range, :end, :character)
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_reports_entry_module_namespace_trap_for_missing_sibling_import
    Dir.mktmpdir("lsp_workspace_entry_namespace_trap") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        import main.platform_info as platform_info

        function main() -> int:
            return 0
      MT
      File.write(path, content)
      File.write(File.join(dir, "platform_info.mt"), <<~MT)
        public function label() -> str:
            return "Build: Shared"
      MT

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      missing_import = diagnostics.find { |diagnostic| diagnostic[:message] == "module not found: main.platform_info" }

      refute_nil missing_import
      assert_equal 0, missing_import.dig(:range, :start, :line)
      assert_equal 7, missing_import.dig(:range, :start, :character)
      assert_equal 25, missing_import.dig(:range, :end, :character)
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_anchor_reserved_type_parameter_sema_and_lint_to_type_param_name
    Dir.mktmpdir("lsp_workspace_reserved_type_param_anchor") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        function identity[span](value: span) -> span:
            return value
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      expected_start = content.lines.first.index("span")
      expected_end = expected_start + "span".length

      sema = diagnostics.find { |diagnostic| diagnostic.dig(:data, :stage) == "sema" }
      lint = diagnostics.find { |diagnostic| diagnostic[:code] == "reserved-primitive-name" }

      refute_nil sema
      refute_nil lint
      assert_equal 0, sema.dig(:range, :start, :line)
      assert_equal expected_start, sema.dig(:range, :start, :character)
      assert_equal expected_end, sema.dig(:range, :end, :character)
      assert_equal expected_start, lint.dig(:range, :start, :character)
      assert_equal expected_end, lint.dig(:range, :end, :character)
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_anchor_platform_api_drift_to_export_name
    Dir.mktmpdir("lsp_workspace_platform_api_drift_anchor") do |dir|
      path = File.join(dir, "service.mt")
      content = <<~MT
        public function read() -> int:
            return 1
      MT
      File.write(path, content)
      File.write(File.join(dir, "service.windows.mt"), <<~MT)
        public function read() -> int:
            return 1

        public function write() -> int:
            return 2
      MT

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      drift = diagnostics.find { |diagnostic| diagnostic[:code] == "platform-api-drift" }
      expected_start = content.lines.first.index("read")
      expected_end = expected_start + "read".length

      refute_nil drift
      assert_equal "lint", drift.dig(:data, :stage)
      assert_equal 0, drift.dig(:range, :start, :line)
      assert_equal expected_start, drift.dig(:range, :start, :character)
      assert_equal expected_end, drift.dig(:range, :end, :character)
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_keeps_resolved_imports_and_skips_unused_warning_for_missing_imports
    Dir.mktmpdir("lsp_workspace_partial_import_resolution") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT

        import test # fake import for diagnostics coverage

        function main() -> int:
            let value = Option[int].some(7)
            return value.value
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }

      assert_includes messages, "module not found: test"
      refute_includes messages, "unknown type Option"
      refute_includes messages, "unknown import test"
      refute_includes messages, "unused import 'test'"
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_and_facts_recover_after_invalid_top_level_declaration
    Dir.mktmpdir("lsp_workspace_top_level_parse_recovery") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        const board_width: int = 10
        const board_height: int = 20a
        const board_cells: int = 200

        function main() -> int:
            return board_cells
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }
      facts = workspace.get_facts(uri)

      assert_includes messages, "expected end of statement at #{uri}:2:29"
      refute_nil facts
      assert_equal %w[board_cells board_height board_width], facts.values.keys.sort
      assert_equal "int", facts.values.fetch("board_height").type.to_s
      assert_includes facts.functions.keys, "main"
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_and_facts_recover_after_invalid_statement_in_block
    Dir.mktmpdir("lsp_workspace_block_parse_recovery") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        function main() -> int:
            let width = 10
            let height = 20a
            return width
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }
      facts = workspace.get_facts(uri)

      assert_includes messages, "expected end of statement at #{uri}:3:20"
      refute_nil facts
      assert_includes facts.functions.keys, "main"
      assert_operator facts.local_completion_frames.length, :>, 0
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_and_facts_preserve_typed_local_declaration_with_invalid_initializer
    Dir.mktmpdir("lsp_workspace_typed_local_recovery") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        function main() -> int:
            let height: int = 20a
            return height
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }
      facts = workspace.get_facts(uri)
      binding_names = facts.local_completion_frames.flat_map do |frame|
        frame.snapshots.flat_map { |snapshot| snapshot.bindings.keys }
      end

      assert_includes messages, "expected end of statement at #{uri}:2:25"
      refute_nil facts
      assert_includes facts.functions.keys, "main"
      assert_includes binding_names, "height"
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_and_facts_preserve_untyped_local_declaration_with_invalid_initializer
    Dir.mktmpdir("lsp_workspace_untyped_local_recovery") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        function main() -> int:
            let value = 20a
            return value
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }
      facts = workspace.get_facts(uri)
      binding_types = facts.local_completion_frames.flat_map do |frame|
        frame.snapshots.filter_map { |snapshot| snapshot.bindings["value"]&.type&.to_s }
      end

      assert_includes messages, "expected end of statement at #{uri}:2:19"
      refute_nil facts
      assert_includes facts.functions.keys, "main"
      assert_includes binding_types, "<error>"
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_reports_keyword_local_name_clearly
    Dir.mktmpdir("lsp_workspace_keyword_local_name") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        function main() -> int:
            let if = 1
            return 0
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }

      assert messages.any? { |message| message.include?("keyword 'if' cannot be used as local variable name") },
             "expected clearer keyword-local-name diagnostic, got: #{messages.inspect}"
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_and_facts_preserve_recovered_let_else_declaration
    Dir.mktmpdir("lsp_workspace_let_else_recovery") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        function main(handle: ptr[int]?) -> int:
            let value = handle else as error
                return 1
            unsafe:
                return read(value)
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }
      facts = workspace.get_facts(uri)
      binding_types = facts.local_completion_frames.flat_map do |frame|
        frame.snapshots.filter_map { |snapshot| snapshot.bindings["value"]&.type&.to_s }
      end

      assert messages.any? { |message| message.include?("expected ':' before block") }
      refute_nil facts
      assert_includes facts.functions.keys, "main"
      assert_includes binding_types, "ptr[int]"
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_and_facts_keep_completion_frame_on_invalid_last_statement
    Dir.mktmpdir("lsp_workspace_error_stmt_frame") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        struct Point:
            x: int
            y: int

        function main() -> int:
            let p = Point(x = 1, y = 2)
            return p.
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }
      facts = workspace.get_facts(uri)
      main_frame = facts.local_completion_frames.find { |frame| frame.function_name == "main" }

      assert messages.any? { |message| message.include?("expected member name after '.'") }
      refute_nil facts
      refute_nil main_frame
      assert_equal content.lines.length, main_frame.end_line
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_and_facts_preserve_bindings_inside_invalid_block_header_body
    Dir.mktmpdir("lsp_workspace_error_block_body") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        function main() -> int:
            let value = 1
            unsafe
                let inner = value
                return inner
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }
      facts = workspace.get_facts(uri)
      binding_names = facts.local_completion_frames.flat_map do |frame|
        frame.snapshots.flat_map { |snapshot| snapshot.bindings.keys }
      end

      assert messages.any? { |message| message.include?("expected ':' after unsafe") }
      refute_nil facts
      assert_includes facts.functions.keys, "main"
      assert_includes binding_names, "inner"
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_and_facts_treat_invalid_unsafe_block_body_as_unsafe
    Dir.mktmpdir("lsp_workspace_invalid_unsafe_semantics") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        struct Counter:
            value: int

        function main() -> int:
            var counter = Counter(value = 3)
            let counter_ptr = ptr_of(counter)
            unsafe
                return read(counter_ptr).value
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }
      facts = workspace.get_facts(uri)

      assert messages.any? { |message| message.include?("expected ':' after unsafe") }
      refute messages.any? { |message| message.include?("raw pointer dereference requires unsafe") }
      refute_nil facts
      assert_includes facts.required_unsafe_lines, 7
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_and_facts_refine_nullable_binding_inside_invalid_if_block
    Dir.mktmpdir("lsp_workspace_invalid_if_flow") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        struct Point:
            x: int

        function main() -> int:
            var p: Point? = null
            if p != null
                return p.x
            return 0
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }
      facts = workspace.get_facts(uri)
      return_line = content.lines.index { |line| line.include?("return p.x") } + 1
      binding_types = facts.local_completion_frames.flat_map do |frame|
        frame.snapshots.filter_map do |snapshot|
          next unless snapshot.line == return_line

          snapshot.bindings["p"]&.type&.to_s
        end
      end

      assert messages.any? { |message| message.include?("expected ':' before block") }
      refute_nil facts
      assert_includes facts.functions.keys, "main"
      assert_includes binding_types, "main.Point"
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_and_facts_treat_continue_inside_invalid_while_block_as_loop_control
    Dir.mktmpdir("lsp_workspace_invalid_while_loop") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        struct Point:
            x: int

        function main() -> int:
            var p: Point? = Point(x = 1)
            while p != null
                continue
            return 0
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }
      facts = workspace.get_facts(uri)

      assert messages.any? { |message| message.include?("expected ':' before block") }
      refute messages.any? { |message| message.include?("continue must be inside a loop") }
      refute_nil facts
      assert_includes facts.functions.keys, "main"
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_and_facts_recover_for_binding_inside_invalid_for_block
    Dir.mktmpdir("lsp_workspace_invalid_for_loop") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        struct Point:
            x: int

        function main() -> int:
            let items = array[Point, 1](Point(x = 1))
            for item in items
                continue
                return item.x
            return 0
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }
      facts = workspace.get_facts(uri)
      binding_types = facts.local_completion_frames.flat_map do |frame|
        frame.snapshots.filter_map { |snapshot| snapshot.bindings["item"]&.type&.to_s }
      end

      assert messages.any? { |message| message.include?("expected ':' before block") }
      refute messages.any? { |message| message.include?("continue must be inside a loop") }
      refute_nil facts
      assert_includes facts.functions.keys, "main"
      assert_includes binding_types, "ref[main.Point]"
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_and_facts_treat_continue_inside_headerless_while_block_as_loop_control
    Dir.mktmpdir("lsp_workspace_headerless_while_loop") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        function main() -> int:
            while:
                continue
            return 0
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }
      facts = workspace.get_facts(uri)

      assert messages.any? { |message| message.include?("expected expression") }
      refute messages.any? { |message| message.include?("continue must be inside a loop") }
      refute_nil facts
      assert_includes facts.functions.keys, "main"
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_and_facts_treat_continue_inside_headerless_for_block_as_loop_control
    Dir.mktmpdir("lsp_workspace_headerless_for_loop") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        function main() -> int:
            for:
                continue
            return 0
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }
      facts = workspace.get_facts(uri)

      assert messages.any? { |message| message.include?("expected loop variable name") }
      refute messages.any? { |message| message.include?("continue must be inside a loop") }
      refute_nil facts
      assert_includes facts.functions.keys, "main"
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_and_facts_recover_match_binding_inside_invalid_match_arm
    Dir.mktmpdir("lsp_workspace_invalid_match_arm") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        struct Point:
            x: int

        variant MaybePoint:
            some(value: Point)
            none

        function main(value: MaybePoint) -> int:
            match value:
                MaybePoint.some as payload
                    return payload.value.x
                MaybePoint.none:
                    return 0
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }
      facts = workspace.get_facts(uri)
      target_line = content.lines.index { |line| line.include?("return payload.value.x") } + 1
      binding_names = facts.local_completion_frames.flat_map do |frame|
        frame.snapshots.filter_map do |snapshot|
          next unless snapshot.line == target_line

          snapshot.bindings.key?("payload") ? "payload" : nil
        end
      end

      assert messages.any? { |message| message.include?("expected ':' before block") }
      refute_nil facts
      assert_includes facts.functions.keys, "main"
      assert_includes binding_names, "payload"
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_and_facts_bind_missing_match_scrutinee_payload_as_error
    Dir.mktmpdir("lsp_workspace_invalid_match_scrutinee") do |dir|
      path = File.join(dir, "main.mt")
      content = <<~MT
        struct Point:
            x: int

        variant MaybePoint:
            some(value: Point)
            none

        function main() -> int:
            match:
                MaybePoint.some as payload:
                    return payload
                MaybePoint.none:
                    return 0
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      workspace.open_document(uri, content)

      diagnostics = workspace.collect_diagnostics(uri)
      messages = diagnostics.map { |diagnostic| diagnostic[:message] }
      facts = workspace.get_facts(uri)
      target_line = content.lines.index { |line| line.include?("return payload") } + 1
      binding_types = facts.local_completion_frames.flat_map do |frame|
        frame.snapshots.filter_map do |snapshot|
          next unless snapshot.line == target_line

          snapshot.bindings["payload"]&.type&.to_s
        end
      end

      assert messages.any? { |message| message.include?("expected expression") }
      refute_nil facts
      assert_includes facts.functions.keys, "main"
      assert_includes binding_types, "<error>"
    ensure
      workspace&.shutdown
    end
  end

  def test_collect_diagnostics_does_not_report_method_only_import_as_unused
    Dir.mktmpdir("lsp_workspace_method_only_import") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      File.write(File.join(std_dir, "string.mt"), <<~MT)
        public struct String:
            value: str

        extending String:
            public function as_str() -> str:
                return this.value
      MT

      File.write(File.join(dir, "util.mt"), <<~MT)
        import std.string as string

        public function make() -> string.String:
            return string.String(value = "hi")
      MT

      path = File.join(dir, "main.mt")
      content = <<~MT
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
