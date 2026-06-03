# frozen_string_literal: true

module MilkTea
  class ModuleLoader
    module AsyncRuntime
      private

      def install_async_runtime_dependency!(ast, modules, importer_path: nil, collecting_errors:)
        return if modules.key?("std.async")
        return unless async_main_declared?(ast)

        import_path = resolve_module_path("std.async", importer_path:)
        import_analysis = collecting_errors ? check_path_collecting_errors(import_path) : check_path(import_path)
        modules["std.async"] = module_binding(import_analysis)
      end

      def async_main_declared?(ast)
        ast.declarations.any? do |decl|
          decl.is_a?(AST::FunctionDef) && decl.name == "main" && decl.async
        end
      end
    end
  end
end
