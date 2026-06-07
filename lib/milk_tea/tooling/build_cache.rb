# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"

module MilkTea
  class BuildCache
    CachedProgram = Data.define(:c_source, :frontend_modules) do
      def self.load(dir)
        raw = JSON.parse(File.read(File.join(dir, "modules.json")), symbolize_names: true)
        c_source = File.read(File.join(dir, "source.c"))
        modules = raw.fetch(:modules).map do |mod|
          Build::FrontendModule.new(
            name: mod.fetch(:name),
            kind: mod.fetch(:kind).to_sym,
            link_libraries: mod.fetch(:link_libraries),
            compiler_flags: mod.fetch(:compiler_flags),
          )
        end
        new(c_source:, frontend_modules: modules)
      end

      def store(dir)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "source.c"), c_source)
        modules_json = {
          modules: frontend_modules.map do |mod|
            {
              name: mod.name,
              kind: mod.kind.to_s,
              link_libraries: mod.link_libraries,
              compiler_flags: mod.compiler_flags,
            }
          end,
        }
        File.write(File.join(dir, "modules.json"), JSON.generate(modules_json))
      end
    end

    BACKEND_SOURCES = %w[
      lib/milk_tea/core/lowering.rb
      lib/milk_tea/core/lowering/utils.rb
      lib/milk_tea/core/lowering/async.rb
      lib/milk_tea/core/c_backend.rb
      lib/milk_tea/core/c_backend/statements.rb
    ].freeze

    def initialize(root:)
      @root = File.expand_path(root.to_s)
      @cache_root = File.join(MilkTea.data_root.to_s, "tmp", "mtc-cache")
    end

    attr_reader :root

    def fetch_program(key)
      dir = program_dir(key)
      return unless File.exist?(File.join(dir, "modules.json"))
      return unless File.exist?(File.join(dir, "source.c"))

      CachedProgram.load(dir)
    end

    def store_program(key, c_source:, frontend_modules:)
      CachedProgram.new(c_source:, frontend_modules:).store(program_dir(key))
    end

    def fetch_binary(key)
      path = binary_path(key)
      return path if File.exist?(path)

      nil
    end

    def store_binary(key, binary_path)
      dest = binary_path(key)
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(binary_path, dest)
    end

    def program_key(source_files:)
      hasher = Digest::SHA256.new
      hasher << backend_version << "\0"
      source_files.sort_by { |path, _content| path }.each do |path, content|
        hasher << path << "\0" << content << "\0"
      end
      hasher.hexdigest
    end

    def binary_key(c_source:, cc:, compiler_flags:, link_flags:)
      hasher = Digest::SHA256.new
      hasher << c_source << "\0"
      hasher << cc << "\0"
      hasher << compiler_identity(cc) << "\0"
      compiler_flags.sort.each { |f| hasher << f << "\0" }
      link_flags.sort.each { |f| hasher << f << "\0" }
      hasher.hexdigest
    end

    def shared_analysis_cache
      @shared_analysis_cache ||= {}
    end

    private

    def program_dir(key)
      File.join(@cache_root, "programs", key[0, 2], key)
    end

    def binary_path(key)
      File.join(@cache_root, "binaries", key[0, 2], key, "binary")
    end

    def backend_version
      @backend_version ||= compute_backend_version
    end

    def compute_backend_version
      hasher = Digest::SHA256.new
      BACKEND_SOURCES.each do |relative_path|
        path = File.join(@root, relative_path)
        next unless File.exist?(path)

        hasher << relative_path << "\0"
        hasher << File.read(path, mode: "rb") << "\0"
      end
      hasher.hexdigest
    end

    def compiler_identity(cc)
      @compiler_identities ||= {}
      @compiler_identities[cc] ||= compute_compiler_identity(cc)
    end

    def compute_compiler_identity(cc)
      stdout, _stderr, status = Open3.capture3(cc, "--version")
      return cc unless status.success?

      Digest::SHA256.hexdigest(stdout)
    rescue Errno::ENOENT
      cc
    end
  end
end
