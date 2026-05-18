# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module MilkTea
  class SourceIndexToolError < StandardError; end

  class SourceIndexTool
    def self.list_milk_tea_files(root_path:, cc: ENV.fetch("CC", "cc"))
      new(cc:).list_milk_tea_files(root_path:)
    end

    def self.source_path
      File.expand_path("source_index_tool.mt", __dir__)
    end

    def self.binary_path_for(cc)
      @cache_mutex ||= Mutex.new
      @cache_mutex.synchronize do
        entry = @binary_cache&.fetch(cc, nil)
        return entry.fetch(:path) if entry && File.exist?(entry.fetch(:path))

        ensure_build_loaded!
        root = Dir.mktmpdir("milk-tea-source-index-tool")
        path = File.join(root, "milk-tea-source-index-tool")
        Build.build(source_path, output_path: path, cc: cc)
        @binary_cache ||= {}
        @binary_cache[cc] = { path:, root: }
        register_cleanup!
        path
      rescue BuildError => e
        raise SourceIndexToolError, e.message
      rescue SystemCallError => e
        raise SourceIndexToolError, "failed to prepare source index helper: #{e.message}"
      end
    end

    def self.ensure_build_loaded!
      return if defined?(Build)

      require_relative "build"
    end

    def self.register_cleanup!
      return if @cleanup_registered

      at_exit do
        @binary_cache&.each_value do |entry|
          root = entry.fetch(:root, nil)
          FileUtils.rm_rf(root) if root
        end
      end

      @cleanup_registered = true
    end

    def initialize(cc: ENV.fetch("CC", "cc"))
      @cc = cc
    end

    def list_milk_tea_files(root_path:)
      stdout, stderr, status = Open3.capture3(self.class.binary_path_for(@cc), root_path)
      unless status.success?
        details = [stdout, stderr].reject(&:empty?).join
        raise SourceIndexToolError, details.empty? ? "source index helper failed" : details
      end

      stdout.lines(chomp: true).reject(&:empty?)
    rescue Errno::ENOENT => e
      raise SourceIndexToolError, "source index helper execution failed: #{e.message}"
    end
  end
end
