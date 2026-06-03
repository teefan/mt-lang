# frozen_string_literal: true

module MilkTea
  class ModuleLoader
    module Resolution
      ImportResolution = Data.define(:modules, :errors)

      private

      def resolve_module_path(module_name, importer_path: nil, importer_module_name: nil)
        package_candidate = resolve_package_module_path(module_name, importer_path:)
        return package_candidate if package_candidate

        relative_path = File.join(*module_name.split(".")) + ".mt"
        blocked = false
        candidate = @module_roots.lazy.map { |root| self.class.resolve_source_path(File.join(root, relative_path), platform: @platform) }.find do |path|
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

      def namespace_hint_for_missing_module(module_name, importer_path:, importer_module_name:)
        return nil unless importer_path && importer_module_name
        return nil unless entry_module_namespace_like?(importer_path, importer_module_name)
        return nil unless module_name.start_with?("#{importer_module_name}.")

        sibling_import = module_name.delete_prefix("#{importer_module_name}.")
        sibling_path = File.join(File.dirname(importer_path), *sibling_import.split(".")) + ".mt"
        resolved_sibling_path = self.class.resolve_source_path(sibling_path, platform: @platform)
        return nil unless source_path_available?(resolved_sibling_path)

        namespaced_path = File.join(File.dirname(importer_path), importer_module_name, *sibling_import.split(".")) + ".mt"
        "module not found; entry module '#{importer_module_name}' does not create an import namespace for sibling files. Import '#{sibling_import}' instead, or move the module to #{namespaced_path}"
      end

      def entry_module_namespace_like?(importer_path, importer_module_name)
        return false if importer_module_name.include?(".")

        File.basename(importer_path).match?(/\Amain(?:\.(linux|windows|wasm))?\.mt\z/)
      end

      def source_path_available?(path)
        resolved_path = File.expand_path(path.to_s)
        @source_overrides.key?(resolved_path) || File.file?(resolved_path)
      end
    end
  end
end
