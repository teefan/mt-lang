# frozen_string_literal: true

require "tomlrb"

module MilkTea
  class PackageManifestError < StandardError; end

  class PackageManifest
    DependencyView = Data.define(:name, :version, :version_req, :git, :git_rev, :git_subdir, :path) do
      def path_dependency?
        !path.nil?
      end

      def git_dependency?
        !git.nil?
      end

      def registry?
        !version_req.nil? && !path_dependency? && !git_dependency?
      end

      def exact_registry_version?
        registry? && !version.nil?
      end
    end
    DataView = Data.define(:root_dir, :manifest_path, :package_name, :package_version, :package_kind, :source_root, :source_path, :profile, :platform, :output_path, :preload_path, :html_template_path, :dependencies)

    def self.load(path)
      new(path).load
    end

    def initialize(path)
      @path = File.expand_path(path)
    end

    def load
      manifest_path, root_dir = resolve_manifest_path(@path)
      raise PackageManifestError, "package manifest not found for #{@path}" unless manifest_path

      config = parse_manifest(manifest_path)
      package = config.fetch("package", {})
      build = config.fetch("build", {})
      profile_config = config.fetch("profile", {})
      platform_config = config.fetch("platform", {})

      package_name = package["name"]
      if package_name.nil? || package_name.empty?
        package_name = File.basename(root_dir).tr("-", "_")
      end
      package_version = package["version"]
      package_version = package_version.to_s unless package_version.nil?
      package_version = nil if package_version == ""

      package_kind = normalize_package_kind(package["kind"] || build["type"] || default_package_kind(build))
      source_root_value = package["source_root"] || default_source_root(root_dir)
      source_root = File.expand_path(source_root_value.to_s, root_dir)
      unless File.directory?(source_root)
        raise PackageManifestError, "package.source_root not found: #{source_root_value} (resolved to #{source_root})"
      end

      profile_name = normalize_profile_name(build["profile"] || profile_config["default"])
      platform_name = normalize_platform_name(build["platform"] || platform_config["default"])

      source_path = resolve_source_path(root_dir, build, package_kind)

      output_path = build["output"]
      output_path = File.expand_path(output_path.to_s, root_dir) if output_path

      preload_path = build["preload"]
      if preload_path
        preload_path = File.expand_path(preload_path.to_s, root_dir)
        unless File.exist?(preload_path)
          raise PackageManifestError, "build.preload not found: #{build["preload"]} (resolved to #{preload_path})"
        end
      end

      html_template_path = build["html_template"]
      if html_template_path
        html_template_path = File.expand_path(html_template_path.to_s, root_dir)
        unless File.file?(html_template_path)
          raise PackageManifestError, "build.html_template not found: #{build["html_template"]} (resolved to #{html_template_path})"
        end
      end

      dependencies = parse_dependencies(config.fetch("dependencies", {}), root_dir:, manifest_path:)

      DataView.new(
        root_dir:,
        manifest_path:,
        package_name:,
        package_version:,
        package_kind:,
        source_root:,
        source_path:,
        profile: profile_name,
        platform: platform_name,
        output_path:,
        preload_path:,
        html_template_path:,
        dependencies:,
      )
    end

    private

    def resolve_manifest_path(path)
      if File.directory?(path)
        manifest_path = File.join(path, "package.toml")
        raise PackageManifestError, "package manifest not found: #{manifest_path}" unless File.file?(manifest_path)

        return [manifest_path, path]
      end

      if File.basename(path) == "package.toml"
        raise PackageManifestError, "package manifest not found: #{path}" unless File.file?(path)

        return [path, File.dirname(path)]
      end

      current = File.dirname(path)
      loop do
        manifest_path = File.join(current, "package.toml")
        return [manifest_path, current] if File.file?(manifest_path)

        parent = File.dirname(current)
        break if parent == current

        current = parent
      end

      [nil, nil]
    end

    def parse_manifest(path)
      data = Tomlrb.load_file(path)
      raise PackageManifestError, "package.toml root must be a table: #{path}" unless data.is_a?(Hash)

      data
    rescue StandardError => e
      raise PackageManifestError, "invalid package.toml at #{path}: #{e.message}"
    end

    def default_package_kind(build)
      "application"
    end

    def default_source_root(root_dir)
      "."
    end

    def resolve_source_path(root_dir, build, package_kind)
      return nil if package_kind == :library

      if build["entry"]
        entry = build["entry"].to_s
        source_path = File.expand_path(entry, root_dir)
        unless File.file?(source_path)
          raise PackageManifestError, "build.entry not found: #{entry} (resolved to #{source_path})"
        end

        return source_path
      end

      default_source_path = File.expand_path("src/main.mt", root_dir)
      return default_source_path if File.file?(default_source_path)

      requested_path = File.expand_path(@path)
      return requested_path if File.file?(requested_path) && path_within_root?(requested_path, root_dir)

      nil
    end

    def path_within_root?(path, root_dir)
      normalized_root = File.expand_path(root_dir)
      path == normalized_root || path.start_with?(normalized_root + File::SEPARATOR)
    end

    def parse_dependencies(raw_dependencies, root_dir:, manifest_path:)
      return [] if raw_dependencies.nil?
      unless raw_dependencies.is_a?(Hash)
        raise PackageManifestError, "dependencies must be a table in #{manifest_path}"
      end

      raw_dependencies.map do |name, spec|
        parse_dependency(name, spec, root_dir:, manifest_path:)
      end
    end

    def parse_dependency(name, spec, root_dir:, manifest_path:)
      case spec
      when String
        return registry_dependency(name, spec, manifest_path:)
      when Hash
        version = normalize_optional_dependency_value(spec["version"])
        git = normalize_optional_dependency_value(spec["git"])
        git_rev = normalize_optional_dependency_value(spec["rev"])
        git_subdir = normalize_optional_dependency_value(spec["subdir"])
        path_value = normalize_optional_dependency_value(spec["path"])

        if git_rev && !git
          raise PackageManifestError, "dependency #{name} in #{manifest_path} declares rev without git"
        end

        if git_subdir && !git
          raise PackageManifestError, "dependency #{name} in #{manifest_path} declares subdir without git"
        end

        if version && git
          raise PackageManifestError,
                "dependency #{name} in #{manifest_path} cannot combine version with git resolution"
        end

        declared_sources = []
        declared_sources << "git" if git
        declared_sources << "path" if path_value
        declared_sources << "version" if version && !path_value && !git

        if declared_sources.empty?
          raise PackageManifestError, "dependency #{name} in #{manifest_path} must declare version, git, or path"
        end

        if declared_sources.length > 1
          raise PackageManifestError,
                "dependency #{name} in #{manifest_path} must choose exactly one of version, git, or path"
        end

        if path_value
          path = File.expand_path(path_value, root_dir)
          unless File.directory?(path)
            raise PackageManifestError, "dependency #{name} path not found: #{spec["path"]} (resolved to #{path})"
          end

          version_req = version ? normalize_registry_dependency_requirement(version, name:, manifest_path:) : nil
          exact_version = version_req&.exact_version&.to_s
          return DependencyView.new(name.to_s, exact_version, version_req, nil, nil, nil, path)
        end

        if git
          unless git_rev
            raise PackageManifestError,
                  "dependency #{name} in #{manifest_path} uses git resolution but is missing rev"
          end

          return DependencyView.new(name.to_s, nil, nil, git, git_rev, git_subdir, nil)
        end

        registry_dependency(name, version, manifest_path:)
      else
        raise PackageManifestError, "dependency #{name} in #{manifest_path} has unsupported type #{spec.class}"
      end
    end

    def registry_dependency(name, raw_requirement, manifest_path:)
      version_req = normalize_registry_dependency_requirement(raw_requirement, name:, manifest_path:)
      exact_version = version_req.exact_version&.to_s

      DependencyView.new(name.to_s, exact_version, version_req, nil, nil, nil, nil)
    end

    def normalize_optional_dependency_value(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def normalize_registry_dependency_requirement(value, name:, manifest_path:)
      text = normalize_optional_dependency_value(value)
      if text.nil?
        raise PackageManifestError, "dependency #{name} in #{manifest_path} must declare a version"
      end

      PackageVersionReq.parse(text, label: "dependency #{name} in #{manifest_path} version requirement")
    rescue PackageVersionError => e
      raise PackageManifestError, e.message
    end

    def normalize_package_kind(value)
      case value.to_s
      when "", "application", "app", "executable"
        :application
      when "library", "lib"
        :library
      else
        raise PackageManifestError, "unknown package kind #{value}; expected application|library"
      end
    end

    def normalize_profile_name(value)
      case value.to_s
      when "", "debug", "dev"
        :debug
      when "release", "rel"
        :release
      else
        raise PackageManifestError, "unknown profile #{value}; expected debug|release"
      end
    end

    def normalize_platform_name(value)
      case value.to_s
      when "", "linux"
        :linux
      when "windows", "win", "win32"
        :windows
      when "wasm", "web", "html5", "browser"
        :wasm
      else
        raise PackageManifestError, "unknown platform #{value}; expected linux|windows|wasm"
      end
    end
  end
end
