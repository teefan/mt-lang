# frozen_string_literal: true

module MilkTea
  class ModulePathResolver
    def initialize(module_roots:, platform:, package_graph: nil, source_overrides: nil, package_manifest_cache: nil)
      @module_roots = module_roots.map { |root| File.expand_path(root.to_s) }
      @platform = platform
      @package_graph = package_graph
      @source_overrides = source_overrides || {}
      @package_manifest_cache = package_manifest_cache || {}
    end

    def resolve_module_path(module_name, importer_path: nil, importer_module_name: nil)
      package_candidate = resolve_package_module_path(module_name, importer_path:)
      return package_candidate if package_candidate

      relative_path = File.join(*module_name.split(".")) + ".mt"
      blocked = false
      candidate = @module_roots.lazy.map { |root| ModuleLoader.resolve_source_path(File.join(root, relative_path), platform: @platform) }.find do |path|
        next false unless source_path_available?(path)

        allowed = import_allowed?(module_name, importer_path, path)
        blocked ||= !allowed
        allowed
      end
      raise ModuleLoadError.new("package dependency not declared", path: module_name) if blocked
      unless candidate
        message = namespace_hint_for_missing_module(module_name, importer_path:, importer_module_name:) || "module not found"
        raise ModuleLoadError.new(message, path: module_name)
      end

      File.expand_path(candidate)
    end

    def source_path_available?(path)
      resolved_path = File.expand_path(path.to_s)
      @source_overrides.key?(resolved_path) || File.file?(resolved_path)
    end

    private

    def resolve_package_module_path(module_name, importer_path: nil)
      return nil unless @package_graph && importer_path

      importer_package = @package_graph.package_for_path(importer_path)
      return nil unless importer_package

      relative_path = File.join(*module_name.split(".")) + ".mt"
      candidates = []
      if package_namespace_match?(module_name, importer_package.manifest.package_name)
        candidates << [
          importer_package.manifest.package_name,
          File.join(importer_package.manifest.source_root, relative_path),
        ]
      end

      importer_package.edges.each do |edge|
        next unless edge.node && package_namespace_match?(module_name, edge.dependency.name)

        candidates << [
          edge.dependency.name,
          File.join(edge.node.manifest.source_root, relative_path),
        ]
      end

      return nil if candidates.empty?

      best_namespace_length = candidates.map { |namespace, _path| namespace.length }.max
      matching_candidates = candidates.select { |namespace, _path| namespace.length == best_namespace_length }
      if matching_candidates.length > 1
        raise ModuleLoadError.new("ambiguous package dependency import", path: module_name)
      end

      resolved_path = ModuleLoader.resolve_source_path(matching_candidates.first.last, platform: @platform)
      raise ModuleLoadError.new("module not found", path: module_name) unless source_path_available?(resolved_path)

      File.expand_path(resolved_path)
    end

    def import_allowed?(module_name, importer_path, candidate_path)
      if @package_graph
        return import_allowed_by_graph?(module_name, importer_path, candidate_path)
      end

      importer_manifest = package_manifest_for_path(importer_path)
      return true unless importer_manifest

      candidate_manifest = package_manifest_for_path(candidate_path)
      return true unless candidate_manifest
      return true if candidate_manifest.manifest_path == importer_manifest.manifest_path

      dependency = importer_manifest.dependencies.find { |entry| entry.name == candidate_manifest.package_name }
      return false unless dependency

      package_namespace_match?(module_name, dependency.name)
    end

    def import_allowed_by_graph?(module_name, importer_path, candidate_path)
      importer_package = @package_graph.package_for_path(importer_path)
      return true unless importer_package

      candidate_package = @package_graph.package_for_path(candidate_path)
      return true unless candidate_package
      return true if candidate_package.manifest.manifest_path == importer_package.manifest.manifest_path

      dependency = importer_package.edges.find do |edge|
        edge.node && edge.node.manifest.package_name == candidate_package.manifest.package_name
      end
      return false unless dependency

      package_namespace_match?(module_name, dependency.dependency.name)
    end

    def package_manifest_for_path(path)
      return nil unless path

      package_root = ModuleRoots.package_root_for_path(path)
      return nil unless package_root

      manifest_path = File.join(package_root, "package.toml")
      return @package_manifest_cache[manifest_path] if @package_manifest_cache.key?(manifest_path)

      @package_manifest_cache[manifest_path] = PackageManifest.load(path)
    rescue PackageManifestError
      @package_manifest_cache[manifest_path] = nil if manifest_path
      nil
    end

    def package_namespace_match?(module_name, package_name)
      module_name == package_name || module_name.start_with?("#{package_name}.")
    end

    def namespace_hint_for_missing_module(module_name, importer_path:, importer_module_name:)
      return nil unless importer_path && importer_module_name
      return nil unless entry_module_namespace_like?(importer_path, importer_module_name)
      return nil unless module_name.start_with?("#{importer_module_name}.")

      sibling_import = module_name.delete_prefix("#{importer_module_name}.")
      sibling_path = File.join(File.dirname(importer_path), *sibling_import.split(".")) + ".mt"
      resolved_sibling_path = ModuleLoader.resolve_source_path(sibling_path, platform: @platform)
      return nil unless source_path_available?(resolved_sibling_path)

      namespaced_path = File.join(File.dirname(importer_path), importer_module_name, *sibling_import.split(".")) + ".mt"
      "module not found; entry module '#{importer_module_name}' does not create an import namespace for sibling files. Import '#{sibling_import}' instead, or move the module to #{namespaced_path}"
    end

    def entry_module_namespace_like?(importer_path, importer_module_name)
      return false if importer_module_name.include?(".")

      File.basename(importer_path).match?(/\Amain(?:\.(linux|windows|wasm))?\.mt\z/)
    end
  end
end
