# frozen_string_literal: true

require_relative "../../test_helper"

class LSPWorkspaceTest < Minitest::Test
  def test_open_document_reports_eager_analysis_stats_for_small_documents
    workspace = MilkTea::LSP::Workspace.new
    uri = "file:///tmp/lsp_workspace_open_stats.mt"

    stats = workspace.open_document(uri, <<~MT)
      module main

      def main() -> int:
          return 0
    MT

    assert_equal true, stats[:eager_analysis]
    assert_equal :memory, stats[:analysis_mode]
    assert_nil stats[:skip_reason]
    assert_kind_of Numeric, stats[:analysis_ms]
    assert_operator stats[:analysis_ms], :>=, 0
    assert_operator stats[:lines], :>=, 4
  end

  def test_open_document_reports_skip_reason_for_large_documents
    workspace = MilkTea::LSP::Workspace.new
    uri = "file:///tmp/lsp_workspace_large_open.mt"
    content = "module main\n" + ("# filler\n" * 1201)

    stats = workspace.open_document(uri, content)

    assert_equal false, stats[:eager_analysis]
    assert_equal 'large-lines', stats[:skip_reason]
    assert_nil stats[:analysis_ms]
  end

  def test_open_document_skips_eager_analysis_for_std_paths
    Dir.mktmpdir("lsp_workspace_std_open") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)
      path = File.join(std_dir, "jsonc.mt")
      content = <<~MT
        module std.jsonc

        import std.option as option
        import std.string as string

        pub def parse() -> int:
            return 0
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      stats = workspace.open_document(path_to_uri(path), content)

      assert_equal false, stats[:eager_analysis]
      assert_equal 'std-path', stats[:skip_reason]
      assert_equal 2, stats[:import_count]
      assert_nil stats[:analysis_ms]
    end
  end

  def test_open_document_skips_eager_analysis_for_import_heavy_files
    Dir.mktmpdir("lsp_workspace_import_heavy_open") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      path = File.join(dir, "main.mt")
      body = (1..130).map { |i| "# filler #{i}" }.join("\n")
      content = <<~MT
        module main

        import mathx as mx
        import mathy as my

        def main() -> int:
            return 0

        #{body}
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      stats = workspace.open_document(path_to_uri(path), content)

      assert_equal false, stats[:eager_analysis]
      assert_equal 'import-heavy', stats[:skip_reason]
      assert_equal 2, stats[:import_count]
      assert_nil stats[:analysis_ms]
    end
  end

  def test_update_document_uses_skip_heuristic_for_import_heavy_files
    Dir.mktmpdir("lsp_workspace_import_heavy_update") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      path = File.join(dir, "main.mt")
      body = (1..130).map { |i| "# filler #{i}" }.join("\n")
      content = <<~MT
        module main

        import mathx as mx
        import mathy as my

        def main() -> int:
            return 0

        #{body}
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      stats = workspace.update_document(path_to_uri(path), content)

      assert_equal false, stats[:eager_analysis]
      assert_equal 'import-heavy', stats[:skip_reason]
      assert_equal 2, stats[:import_count]
      assert_nil stats[:analysis_ms]
    ensure
      workspace&.shutdown
    end
  end

  def test_skipped_open_document_warms_analysis_in_background
    Dir.mktmpdir("lsp_workspace_analysis_warmup") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)
      path = File.join(std_dir, "demo.mt")
      content = <<~MT
        module std.demo

        pub def answer() -> int:
            return 42
      MT
      File.write(path, content)

      workspace = MilkTea::LSP::Workspace.new
      uri = path_to_uri(path)
      stats = workspace.open_document(uri, content)

      assert_equal false, stats[:eager_analysis]
      assert_equal 'std-path', stats[:skip_reason]

      wait_until do
        analysis_cache = workspace.instance_variable_get(:@analysis_cache)
        analysis_cache.key?(uri) && !analysis_cache[uri].nil?
      end

      refute_nil workspace.instance_variable_get(:@last_good_analysis_cache)[uri]
    ensure
      workspace&.shutdown
    end
  end

  private

  def wait_until(timeout: 1.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    until yield
      flunk "timed out waiting for background work" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end

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
