# frozen_string_literal: true

module MilkTea
  class Lowerer
    class ModuleContext
      attr_accessor :analysis, :current_analysis_path
      attr_accessor :ast, :module_name, :module_prefix, :module_kind, :directives
      attr_accessor :imports, :types, :values, :functions, :interfaces
      attr_accessor :methods, :attributes, :attribute_applications, :implemented_interfaces
      attr_accessor :struct_types, :union_types, :opaque_types
      attr_accessor :current_type_substitutions

      def initialize
        @imports = {}
        @types = {}
        @values = {}
        @functions = {}
        @interfaces = {}
        @struct_types = {}
        @union_types = {}
        @opaque_types = {}
        @methods = {}
        @attributes = {}
        @attribute_applications = {}
        @implemented_interfaces = {}
        @current_type_substitutions = nil
      end

      def install(analysis, module_roots: nil)
        @analysis = analysis
        @ast = analysis.ast
        @module_name = analysis.module_name
        @module_kind = analysis.module_kind
        @imports = analysis.imports
        @types = analysis.types
        @values = analysis.values
        @functions = analysis.functions
        @interfaces = analysis.interfaces
        @methods = analysis.methods
        @attributes = analysis.attributes
        @attribute_applications = analysis.attribute_applications
        @implemented_interfaces = analysis.implemented_interfaces
        @directives = analysis.directives
        @struct_types = {}
        @union_types = {}
        @opaque_types = {}
      end

      def save
        {
          analysis: @analysis, current_analysis_path: @current_analysis_path,
          ast: @ast, module_name: @module_name, module_prefix: @module_prefix,
          module_kind: @module_kind, directives: @directives,
          imports: @imports, types: @types, values: @values, functions: @functions,
          interfaces: @interfaces, methods: @methods, attributes: @attributes,
          attribute_applications: @attribute_applications,
          implemented_interfaces: @implemented_interfaces,
          struct_types: @struct_types, union_types: @union_types,
          opaque_types: @opaque_types, current_type_substitutions: @current_type_substitutions,
        }
      end

      def restore(saved)
        saved.each { |k, v| send(:"#{k}=", v) }
      end
    end
  end
end
