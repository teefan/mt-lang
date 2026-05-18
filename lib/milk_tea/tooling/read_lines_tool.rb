# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module MilkTea
  class ReadLinesToolError < StandardError; end

  class ReadLinesTool
    def self.read_lines(path:, cc: ENV.fetch("CC", "cc"))
      new(cc:).read_lines(path:)
    end

    def self.source_path
      File.expand_path("read_lines_tool.mt", __dir__)
    end

    def self.binary_path_for(cc)
      @cache_mutex ||= Mutex.new
      @cache_mutex.synchronize do
        entry = @binary_cache&.fetch(cc, nil)
        return entry.fetch(:path) if entry && File.exist?(entry.fetch(:path))

        ensure_build_loaded!
        root = Dir.mktmpdir("milk-tea-read-lines-tool")
        path = File.join(root, "milk-tea-read-lines-tool")
        Build.build(source_path, output_path: path, cc: cc)
        @binary_cache ||= {}
        @binary_cache[cc] = { path:, root: }
        register_cleanup!
        path
      rescue BuildError => e
        raise ReadLinesToolError, e.message
      rescue SystemCallError => e
        raise ReadLinesToolError, "failed to prepare read-lines helper: #{e.message}"
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

    def read_lines(path:)
      stdout, stderr, status = Open3.capture3(self.class.binary_path_for(@cc), path)
      unless status.success?
        details = [stdout, stderr].reject(&:empty?).join
        raise ReadLinesToolError, details.empty? ? "read-lines helper failed" : details
      end

      stdout.lines(chomp: true)
    rescue Errno::ENOENT => e
      raise ReadLinesToolError, "read-lines helper execution failed: #{e.message}"
    end
  end
end
