# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "uri"

require_relative "read_lines_tool"

module MilkTea
  class HttpFetchToolError < StandardError; end

  class HttpFetchTool
    Response = Data.define(:status_code, :reason, :location) do
      def success?
        (200..299).cover?(status_code)
      end

      def not_found?
        status_code == 404
      end

      def redirection?
        (300..399).cover?(status_code)
      end
    end

    def self.fetch_to_file(url:, body_path:, cc: ENV.fetch("CC", "cc"), redirects_remaining: 5)
      new(cc:).fetch_to_file(url:, body_path:, redirects_remaining:)
    end

    def self.source_path
      File.expand_path("http_fetch_tool.mt", __dir__)
    end

    def self.binary_path_for(cc)
      @cache_mutex ||= Mutex.new
      @cache_mutex.synchronize do
        entry = @binary_cache&.fetch(cc, nil)
        return entry.fetch(:path) if entry && File.exist?(entry.fetch(:path))

        ensure_build_loaded!
        root = Dir.mktmpdir("milk-tea-http-fetch-tool")
        path = File.join(root, "milk-tea-http-fetch-tool")
        Build.build(source_path, output_path: path, cc: cc)
        @binary_cache ||= {}
        @binary_cache[cc] = { path:, root: }
        register_cleanup!
        path
      rescue BuildError => e
        raise HttpFetchToolError, e.message
      rescue SystemCallError => e
        raise HttpFetchToolError, "failed to prepare HTTP fetch helper: #{e.message}"
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

    def fetch_to_file(url:, body_path:, redirects_remaining: 5)
      URI.parse(url)

      meta_path = "#{body_path}.meta"
      stdout, stderr, status = Open3.capture3(self.class.binary_path_for(@cc), url, body_path, meta_path)
      unless status.success?
        details = [stdout, stderr].reject(&:empty?).join
        raise HttpFetchToolError, details.empty? ? "http fetch helper failed" : details
      end

      response = parse_metadata(meta_path)
      if response.redirection?
        raise HttpFetchToolError, "too many HTTP redirects while fetching #{url}" if redirects_remaining <= 0

        location = response.location.to_s.strip
        raise HttpFetchToolError, "missing redirect location while fetching #{url}" if location.empty?

        return fetch_to_file(url: URI.join(url, location).to_s, body_path:, redirects_remaining: redirects_remaining - 1)
      end

      response
    rescue URI::InvalidURIError => e
      raise HttpFetchToolError, "invalid upstream registry URL #{url.inspect}: #{e.message}"
    rescue SystemCallError => e
      raise HttpFetchToolError, "failed to fetch #{url}: #{e.message}"
    end

    private

    def parse_metadata(meta_path)
      fields = {}
      ReadLinesTool.read_lines(path: meta_path, cc: @cc).each do |line|
        key, value = line.split("=", 2)
        raise HttpFetchToolError, "http fetch helper returned malformed metadata" if key.nil? || value.nil?

        fields[key] = value
      end

      status_code = Integer(fields.fetch("status_code"))
      Response.new(
        status_code:,
        reason: fields.fetch("reason"),
        location: fields.fetch("location", ""),
      )
    rescue KeyError, ArgumentError => e
      raise HttpFetchToolError, "http fetch helper returned invalid metadata: #{e.message}"
    end
  end
end
