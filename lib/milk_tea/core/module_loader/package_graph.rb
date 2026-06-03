# frozen_string_literal: true

module MilkTea
  class ModuleLoader
    module PackageGraph
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

        resolved_path = self.class.resolve_source_path(matching_candidates.first.last, platform: @platform)
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
    end
  end
end
