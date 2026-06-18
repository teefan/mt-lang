# frozen_string_literal: true

module MilkTea
  class AsyncRuntimeInstaller
    def initialize(resolve_module_path:, check_block:, bind_block:)
      @resolve_module_path = resolve_module_path
      @check_block = check_block
      @bind_block = bind_block
    end

    def install_async_runtime_dependency!(ast, modules, importer_path: nil, collecting_errors: false)
      return if modules.key?("std.async")
      return unless async_main_declared?(ast)

      import_path = @resolve_module_path.call("std.async", importer_path:)
      import_analysis = @check_block.call(import_path, collecting_errors)
      modules["std.async"] = @bind_block.call(import_analysis)
    end

    private

    def async_main_declared?(ast)
      ast.declarations.any? do |decl|
        decl.is_a?(AST::FunctionDef) && decl.name == "main" && decl.async
      end
    end
  end
end
