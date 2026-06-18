# frozen_string_literal: true

module MilkTea
  class Sema
    class ModuleContext
      attr_accessor :ast, :module_name, :module_kind
      attr_accessor :imported_modules, :global_import_index
      attr_accessor :const_declarations
      attr_accessor :types, :interfaces, :attributes
      attr_accessor :top_level_values, :top_level_functions
      attr_accessor :imports, :methods, :implemented_interfaces
      attr_accessor :resolved_attribute_applications, :validated_attribute_arguments, :attribute_application_bindings

      def initialize(ast:, module_name:, module_kind:, imported_modules:, global_import_index:, const_declarations:)
        @ast = ast
        @module_name = module_name
        @module_kind = module_kind
        @imported_modules = imported_modules
        @global_import_index = global_import_index
        @const_declarations = const_declarations
        @types = {}
        @interfaces = {}
        @attributes = {}
        @top_level_values = {}
        @top_level_functions = {}
        @imports = {}
        @methods = Hash.new { |hash, key| hash[key] = {} }
        @implemented_interfaces = Hash.new { |hash, key| hash[key] = [] }
        @resolved_attribute_applications = {}
        @validated_attribute_arguments = {}
        @attribute_application_bindings = {}
      end
    end
  end
end
