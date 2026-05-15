# frozen_string_literal: true

require "fileutils"

module MilkTea
  class ProjectScaffoldError < StandardError; end

  class ProjectScaffold
    Result = Data.define(:root_path, :manifest_path, :entry_path, :package_name)

    def self.create(path)
      new(path).create
    end

    def initialize(path)
      @path = File.expand_path(path)
    end

    def create
      validate_target!

      FileUtils.mkdir_p(entry_dir)
      File.write(manifest_path, render_manifest)
      File.write(entry_path, render_entry_source)

      Result.new(
        root_path: @path,
        manifest_path: manifest_path,
        entry_path: entry_path,
        package_name: PackageManifest.default_package_name_for_root(@path),
      )
    end

    private

    def validate_target!
      if File.exist?(@path) && !File.directory?(@path)
        raise ProjectScaffoldError, "project path is not a directory: #{@path}"
      end

      return unless File.directory?(@path)
      return if Dir.children(@path).empty?

      raise ProjectScaffoldError, "project directory already exists and is not empty: #{@path}"
    end

    def manifest_path
      File.join(@path, "package.toml")
    end

    def entry_dir
      File.join(@path, "src")
    end

    def entry_path
      File.join(entry_dir, "main.mt")
    end

    def package_name
      PackageManifest.default_package_name_for_root(@path)
    end

    def render_manifest
      <<~TOML
        [package]
        name = "#{package_name}"
        version = "0.1.0"
        source_root = "src"

        [build]
        entry = "src/main.mt"
      TOML
    end

    def render_entry_source
      <<~MT
        function main() -> int:
            return 0
      MT
    end
  end
end
