# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module MilkTea
  class ArchiveToolError < StandardError; end

  class ArchiveTool
    def self.archive_directory(source_root:, archive_path:, archive_root_name:, include_hidden:, cc: ENV.fetch("CC", "cc"))
      new(cc:).archive_directory(
        source_root:,
        archive_path:,
        archive_root_name:,
        include_hidden:,
      )
    end

    def self.extract_archive(archive_path:, destination_root:, cc: ENV.fetch("CC", "cc"))
      new(cc:).extract_archive(archive_path:, destination_root:)
    end

    def self.source_path
      File.expand_path("archive_tool.mt", __dir__)
    end

    def self.binary_path_for(cc)
      @cache_mutex ||= Mutex.new
      @cache_mutex.synchronize do
        entry = @binary_cache&.fetch(cc, nil)
        return entry.fetch(:path) if entry && File.exist?(entry.fetch(:path))

        ensure_build_loaded!
        root = Dir.mktmpdir("milk-tea-archive-tool")
        path = File.join(root, "milk-tea-archive-tool")
        Build.build(source_path, output_path: path, cc: cc)
        @binary_cache ||= {}
        @binary_cache[cc] = { path:, root: }
        register_cleanup!
        path
      rescue BuildError => e
        raise ArchiveToolError, e.message
      rescue SystemCallError => e
        raise ArchiveToolError, "failed to prepare archive helper: #{e.message}"
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

    def archive_directory(source_root:, archive_path:, archive_root_name:, include_hidden:)
      run!("archive", source_root, archive_path, archive_root_name, include_hidden ? "1" : "0")
      archive_path
    end

    def extract_archive(archive_path:, destination_root:)
      run!("extract", archive_path, destination_root)
      destination_root
    end

    private

    def run!(*args)
      stdout, stderr, status = Open3.capture3(self.class.binary_path_for(@cc), *args)
      return if status.success?

      details = [stdout, stderr].reject(&:empty?).join
      raise ArchiveToolError, details.empty? ? "archive helper failed" : details
    rescue Errno::ENOENT => e
      raise ArchiveToolError, "archive helper execution failed: #{e.message}"
    end
  end
end
