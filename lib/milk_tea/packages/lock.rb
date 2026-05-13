# frozen_string_literal: true

require "tomlrb"

module MilkTea
  class PackageLockError < StandardError; end

  class PackageLock
    Result = Data.define(:lock_path, :content)
    LockedPackage = Data.define(:package_name, :identity, :manifest_path)
    CheckResult = Data.define(:lock_path, :expected_content, :actual_content, :status) do
      def current?
        status == :current
      end

      def missing?
        status == :missing
      end

      def stale?
        status == :stale
      end
    end

    def self.load(path, source_resolver: PackageSourceResolver.new)
      new(path, source_resolver:).load
    end

    def self.check(path, source_resolver: PackageSourceResolver.new)
      new(path, source_resolver:).check
    end

    def self.locked_packages(path, source_resolver: PackageSourceResolver.new)
      new(path, source_resolver:).locked_packages
    end

    def self.write(path, source_resolver: PackageSourceResolver.new)
      new(path, source_resolver:).write
    end

    def initialize(path, source_resolver: PackageSourceResolver.new)
      @path = File.expand_path(path)
      @source_resolver = source_resolver
    end

    def load
      _root_manifest, lock_path, root_package_name, packages = lockfile_context

      records_by_name = packages.each_with_object({}) do |entry, records|
        manifest, source, dependency_names = build_locked_manifest(entry, lock_path)
        if records.key?(manifest.package_name)
          raise PackageLockError, "duplicate package #{manifest.package_name} in #{lock_path}"
        end

        records[manifest.package_name] = { manifest:, source:, dependency_names: }
      end

      raise PackageLockError, "package.lock missing root package #{root_package_name}" unless records_by_name.key?(root_package_name)

      build_locked_node(root_package_name, records_by_name, {}, [])
    end

    def locked_packages
      _root_manifest, lock_path, root_package_name, packages = lockfile_context

      locked_packages = packages.map do |entry|
        build_locked_package(entry, lock_path)
      end

      names = locked_packages.each_with_object({}) do |package, counts|
        counts[package.package_name] = counts.fetch(package.package_name, 0) + 1
      end
      duplicate_name = names.find { |_name, count| count > 1 }&.first
      raise PackageLockError, "duplicate package #{duplicate_name} in #{lock_path}" if duplicate_name

      unless names.key?(root_package_name)
        raise PackageLockError, "package.lock missing root package #{root_package_name}"
      end

      locked_packages
    end

    def check
      lock_path, expected_content = rendered_lockfile
      return CheckResult.new(lock_path:, expected_content:, actual_content: nil, status: :missing) unless File.file?(lock_path)

      actual_content = File.read(lock_path)
      status = actual_content == expected_content ? :current : :stale
      CheckResult.new(lock_path:, expected_content:, actual_content:, status:)
    rescue SystemCallError => e
      raise PackageLockError, "failed to read #{lock_path || File.join(@path, 'package.lock')}: #{e.message}"
    end

    def write
      lock_path, content = rendered_lockfile

      File.write(lock_path, content)

      Result.new(lock_path:, content:)
    rescue SystemCallError => e
      raise PackageLockError, "failed to write #{lock_path || File.join(@path, 'package.lock')}: #{e.message}"
    end

    private

    def lockfile_context
      root_manifest = PackageManifest.load(@path)
      lock_path = File.join(root_manifest.root_dir, "package.lock")
      raise PackageLockError, "package lock not found: #{lock_path}" unless File.file?(lock_path)

      config = parse_lockfile(lock_path)
      schema_version = config["schema_version"]
      raise PackageLockError, "unsupported package.lock schema version #{schema_version.inspect}; expected 1" unless schema_version == 1

      root_package_name = config["root_package"].to_s
      if root_package_name.empty?
        raise PackageLockError, "package.lock missing root_package: #{lock_path}"
      end

      if root_package_name != root_manifest.package_name
        raise PackageLockError, "package.lock root package #{root_package_name} does not match package manifest #{root_manifest.package_name}"
      end

      packages = config["package"]
      unless packages.is_a?(Array) && !packages.empty?
        raise PackageLockError, "package.lock missing [[package]] entries: #{lock_path}"
      end

      [root_manifest, lock_path, root_package_name, packages]
    end

    def rendered_lockfile
      root = PackageGraph.load(@path, source_resolver: @source_resolver)
      lock_path = File.join(root.manifest.root_dir, "package.lock")
      [lock_path, render(root)]
    end

    def parse_lockfile(path)
      data = Tomlrb.load_file(path)
      raise PackageLockError, "package.lock root must be a table: #{path}" unless data.is_a?(Hash)

      data
    rescue StandardError => e
      raise PackageLockError, "invalid package.lock at #{path}: #{e.message}"
    end

    def build_locked_manifest(entry, lock_path)
      unless entry.is_a?(Hash)
        raise PackageLockError, "invalid [[package]] entry in #{lock_path}"
      end

      package_name = required_string(entry, "name", lock_path)
      source = @source_resolver.source_from_lock(entry, lock_path)
      manifest = PackageManifest.load(source.local_root)
      if manifest.package_name != package_name
        raise PackageLockError,
              "package.lock entry #{package_name} resolved materialized package #{manifest.package_name} at #{manifest.manifest_path}"
      end

      if source.kind == :registry
        expected_version = source.identity.version
        if manifest.package_version != expected_version
          raise PackageLockError,
                "package.lock registry entry #{package_name} resolved version #{manifest.package_version.inspect} at #{manifest.manifest_path}; expected #{expected_version.inspect}"
        end
      end

      dependency_names = normalize_dependency_names(entry["dependencies"], lock_path)

      dependencies = dependency_names.map do |dependency_name|
        PackageManifest::DependencyView.new(dependency_name, nil, nil, nil, nil, nil, nil)
      end

      manifest = PackageManifest::DataView.new(
        root_dir: manifest.root_dir,
        manifest_path: manifest.manifest_path,
        package_name: manifest.package_name,
        package_version: manifest.package_version,
        package_kind: manifest.package_kind,
        source_root: manifest.source_root,
        source_path: nil,
        profile: nil,
        platform: nil,
        output_path: nil,
        preload_path: nil,
        html_template_path: nil,
        dependencies:,
      )

      [manifest, source, dependency_names]
    rescue PackageManifestError, PackageSourceResolverError => e
      raise PackageLockError, e.message
    end

    def build_locked_package(entry, lock_path)
      unless entry.is_a?(Hash)
        raise PackageLockError, "invalid [[package]] entry in #{lock_path}"
      end

      package_name = required_string(entry, "name", lock_path)
      identity = @source_resolver.identity_from_lock(entry, lock_path)
      manifest_path = File.expand_path(required_string(entry, "manifest_path", lock_path))

      LockedPackage.new(package_name:, identity:, manifest_path:)
    rescue PackageSourceResolverError => e
      raise PackageLockError, e.message
    end

    def build_locked_node(package_name, records_by_name, nodes_by_name, build_stack)
      existing = nodes_by_name[package_name]
      return existing if existing

      if build_stack.include?(package_name)
        cycle = build_stack + [package_name]
        raise PackageLockError, "package dependency cycle detected in package.lock: #{cycle.join(' -> ')}"
      end

      record = records_by_name[package_name]
      raise PackageLockError, "package.lock missing package #{package_name}" unless record

      build_stack << package_name
      edges = record[:dependency_names].map do |dependency_name|
        dependency_record = records_by_name[dependency_name]
        raise PackageLockError, "package.lock missing dependency #{dependency_name} referenced by #{package_name}" unless dependency_record

        dependency = PackageManifest::DependencyView.new(dependency_name, nil, nil, nil, nil, nil, nil)
        node = build_locked_node(dependency_name, records_by_name, nodes_by_name, build_stack)
        PackageGraph::Edge.new(dependency:, node:)
      end

      node = PackageGraph::Node.new(manifest: record[:manifest], source: record[:source], edges:)
      nodes_by_name[package_name] = node
      node
    ensure
      build_stack.pop if build_stack.last == package_name
    end

    def required_string(entry, key, lock_path)
      value = entry[key]
      text = value.to_s
      raise PackageLockError, "package.lock missing #{key} in #{lock_path}" if text.empty?

      text
    end

    def optional_string(value)
      return nil if value.nil?

      text = value.to_s
      text.empty? ? nil : text
    end

    def normalize_dependency_names(value, lock_path)
      case value
      when nil
        []
      when Array
        value.map do |item|
          item_text = item.to_s
          raise PackageLockError, "package.lock dependency names must be strings in #{lock_path}" if item_text.empty?

          item_text
        end
      else
        raise PackageLockError, "package.lock dependencies must be an array in #{lock_path}"
      end
    end

    def normalize_package_kind(value, lock_path)
      case value
      when "application", "app", "executable"
        :application
      when "library", "lib"
        :library
      else
        raise PackageLockError, "unknown package kind #{value.inspect} in #{lock_path}"
      end
    end

    def render(root)
      lines = [
        "schema_version = 1",
        "root_package = #{toml_string(root.manifest.package_name)}",
        "",
      ]

      packages = root.packages.sort_by { |node| node.manifest.package_name }
      packages.each_with_index do |node, index|
        manifest = node.manifest
        source = node.source
        lines << "[[package]]"
        lines << "name = #{toml_string(manifest.package_name)}"
        lines << "kind = #{toml_string(manifest.package_kind.to_s)}"
        lines << "version = #{toml_string(manifest.package_version)}" if manifest.package_version
        lines << "source_kind = #{toml_string(source.kind.to_s)}"
        source.lock_attributes.sort.each do |key, value|
          lines << "#{key} = #{toml_string(value)}"
        end
        lines << "manifest_path = #{toml_string(manifest.manifest_path)}"
        lines << "source_root = #{toml_string(manifest.source_root)}"
        lines << "dependencies = #{toml_array(node.edges.map { |edge| edge.dependency.name }.sort)}"
        lines << "" unless index == packages.length - 1
      end

      lines.join("\n") + "\n"
    end

    def toml_array(values)
      "[#{values.map { |value| toml_string(value) }.join(', ')}]"
    end

    def toml_string(value)
      escaped = value.to_s
        .gsub('\\', '\\\\')
        .gsub('"', '\\"')
        .gsub("\n", '\\n')
        .gsub("\r", '\\r')
        .gsub("\t", '\\t')

      %Q("#{escaped}")
    end
  end
end
