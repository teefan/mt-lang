# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module MilkTea
  class MtimeToolError < StandardError; end

  class MtimeTool
    Stamp = Data.define(:seconds, :nanoseconds) do
      def cache_key
        "#{seconds}:#{nanoseconds}"
      end
    end

    def self.mtime(path:, cc: ENV.fetch("CC", "cc"))
      new(cc:).mtime(path:)
    end

    def self.source_path
      File.expand_path("mtime_tool.mt", __dir__)
    end

    def self.binary_path_for(cc)
      @cache_mutex ||= Mutex.new
      @cache_mutex.synchronize do
        entry = @binary_cache&.fetch(cc, nil)
        return entry.fetch(:path) if entry && File.exist?(entry.fetch(:path))

        ensure_build_loaded!
        root = Dir.mktmpdir("milk-tea-mtime-tool")
        path = File.join(root, "milk-tea-mtime-tool")
        Build.build(source_path, output_path: path, cc: cc)
        @binary_cache ||= {}
        @binary_cache[cc] = { path:, root: }
        register_cleanup!
        path
      rescue BuildError => e
        raise MtimeToolError, e.message
      rescue SystemCallError => e
        raise MtimeToolError, "failed to prepare mtime helper: #{e.message}"
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

    def mtime(path:)
      stdout, stderr, status = Open3.capture3(self.class.binary_path_for(@cc), path)
      unless status.success?
        details = [stdout, stderr].reject(&:empty?).join
        raise MtimeToolError, details.empty? ? "mtime helper failed" : details
      end

      seconds_text, nanoseconds_text = stdout.strip.split(":", 2)
      raise MtimeToolError, "mtime helper returned malformed output" if seconds_text.nil? || nanoseconds_text.nil?

      Stamp.new(seconds: Integer(seconds_text), nanoseconds: Integer(nanoseconds_text))
    rescue Errno::ENOENT => e
      raise MtimeToolError, "mtime helper execution failed: #{e.message}"
    rescue ArgumentError => e
      raise MtimeToolError, "mtime helper returned invalid output: #{e.message}"
    end
  end
end
