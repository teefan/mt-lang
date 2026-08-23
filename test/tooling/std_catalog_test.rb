# frozen_string_literal: true

require "json"
require "stringio"
require_relative "../test_helper"

module MilkTea
  class StdCatalogTest < Minitest::Test
    def test_entries_exclude_generated_modules_and_std_c
      names = StdCatalog.entries.map(&:name)

      %w[raylib zstd c.cjson c.libc].each do |generated|
        refute_includes(names, generated, "generated module #{generated} must not be listed")
      end
    end

    def test_entries_collapse_platform_variants
      names = StdCatalog.entries.map(&:name)

      assert_includes(names, "fs")
      refute_includes(names, "fs.linux")
      refute_includes(names, "fs.windows")

      fs = StdCatalog.entries.find { |entry| entry.name == "fs" }
      assert(File.file?(fs.path))
    end

    def test_entries_cover_namespaces_and_leaves
      names = StdCatalog.entries.map(&:name)

      %w[async net http].each do |top_level|
        assert_includes(names, top_level)
      end
      %w[mem.arena net.stun http.server raylib.runtime pcre2.runtime sdl3.runtime curl.runtime].each do |name|
        assert_includes(names, name)
      end
    end

    def test_registry_covers_every_discovered_module
      missing = StdCatalog.entries.filter_map do |entry|
        entry.name unless StdCatalog::REGISTRY.key?(entry.name)
      end

      assert_empty(missing, "add std catalog registry descriptions for: #{missing.join(', ')}")
    end

    def test_registry_has_no_stale_entries
      discovered = StdCatalog.entries.map(&:name)
      stale = StdCatalog::REGISTRY.keys - discovered

      assert_empty(stale, "remove stale std catalog registry entries: #{stale.join(', ')}")
    end

    def test_every_entry_has_description_category_and_path
      StdCatalog.entries.each do |entry|
        assert(entry.description && !entry.description.empty?, "#{entry.name} lacks a description")
        assert(StdCatalog::CATEGORY_ORDER.include?(entry.category), "#{entry.name} has unknown category #{entry.category}")
        assert(File.file?(entry.path), "#{entry.name} path does not exist: #{entry.path}")
      end
    end

    def test_resolve_accepts_dotted_and_slashed_names
      expected = File.join(StdCatalog.std_root, "mem", "arena.mt")

      assert_equal(expected, StdCatalog.resolve("mem.arena"))
      assert_equal(expected, StdCatalog.resolve("mem/arena"))
    end

    def test_resolve_prefers_active_platform_variant
      host = MilkTea.host_platform.to_s
      expected = File.join(StdCatalog.std_root, "fs.#{host}.mt")

      assert_equal(expected, StdCatalog.resolve("fs"))
    end

    def test_resolve_allows_generated_modules_and_rejects_bad_names
      assert(File.file?(StdCatalog.resolve("c.cjson")))
      assert(File.file?(StdCatalog.resolve("raylib")))

      assert_nil(StdCatalog.resolve(""))
      assert_nil(StdCatalog.resolve("../lib/milk_tea"))
      assert_nil(StdCatalog.resolve("does.not.exist"))
    end
  end
end
