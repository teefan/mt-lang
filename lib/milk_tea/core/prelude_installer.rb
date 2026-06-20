# frozen_string_literal: true

module MilkTea
  class PreludeInstaller
    PRELUDE_MODULE_PATHS = %w[std.option std.result].freeze

    def initialize(resolve_module_path:, check_block:, bind_block:)
      @resolve_module_path = resolve_module_path
      @check_block = check_block
      @bind_block = bind_block
    end

    def install_prelude_modules!(ast, modules, importer_path: nil, collecting_errors: false)
      current_module_name = ast.module_name&.to_s
      return if PRELUDE_MODULE_PATHS.include?(current_module_name)

      PRELUDE_MODULE_PATHS.each do |module_path|
        next if modules.key?(module_path)

        begin
          import_path = @resolve_module_path.call(module_path, importer_path:)
          import_analysis = @check_block.call(import_path, collecting_errors)
          modules[module_path] = @bind_block.call(import_analysis)
        rescue ModuleLoadError
        end
      end
    end
  end
end
