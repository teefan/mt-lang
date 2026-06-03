# frozen_string_literal: true

module MilkTea
  class ModuleLoader
    module Binding
      private

      def module_binding(analysis)
        types = {}
        type_declarations = {}
        interfaces = {}
        attributes = {}
        private_types = {}
        private_interfaces = {}
        private_attributes = {}
        values = {}
        private_values = {}
        functions = {}
        private_functions = {}

        analysis.ast.declarations.each do |declaration|
          case declaration
          when AST::StructDecl, AST::UnionDecl, AST::VariantDecl, AST::EnumDecl, AST::FlagsDecl, AST::OpaqueDecl, AST::TypeAliasDecl
            type_declarations[declaration.name] = declaration
            target = exported_declaration?(analysis, declaration) ? types : private_types
            target[declaration.name] = analysis.types.fetch(declaration.name)
          when AST::InterfaceDecl
            target = exported_declaration?(analysis, declaration) ? interfaces : private_interfaces
            target[declaration.name] = analysis.interfaces.fetch(declaration.name)
          when AST::AttributeDecl
            target = exported_declaration?(analysis, declaration) ? attributes : private_attributes
            target[declaration.name] = analysis.attributes.fetch(declaration.name)
          when AST::ConstDecl, AST::VarDecl, AST::EventDecl
            target = exported_declaration?(analysis, declaration) ? values : private_values
            target[declaration.name] = analysis.values.fetch(declaration.name)
          when AST::FunctionDef, AST::ExternFunctionDecl, AST::ForeignFunctionDecl
            target = exported_declaration?(analysis, declaration) ? functions : private_functions
            target[declaration.name] = analysis.functions.fetch(declaration.name)
          end
        end

        methods, private_methods = exported_methods(analysis, types)
        implemented_interfaces, private_implemented_interfaces = exported_interface_implementations(analysis, types, interfaces)

        Sema::ModuleBinding.new(
          name: analysis.module_name,
          types:,
          type_declarations:,
          interfaces:,
          attributes:,
          attribute_applications: analysis.attribute_applications,
          values:,
          functions:,
          methods:,
          implemented_interfaces:,
          imports: analysis.imports,
          private_types:,
          private_interfaces:,
          private_attributes:,
          private_values:,
          private_functions:,
          private_methods:,
          private_implemented_interfaces:,
        )
      end

      def exported_declaration?(analysis, declaration)
        return true if analysis.module_kind == :raw_module
        return false unless declaration.respond_to?(:visibility)

        declaration.visibility == :public
      end

      def exported_methods(analysis, exported_types)
        methods = {}
        private_methods = {}

        analysis.methods.each do |receiver_type, bindings|
          public_bindings = {}
          hidden_bindings = {}

          bindings.each do |name, binding|
            visible = binding.ast.respond_to?(:visibility) &&
              binding.ast.visibility == :public &&
              exported_method_receiver?(receiver_type, analysis, exported_types)

            if visible
              public_bindings[name] = binding
            else
              hidden_bindings[name] = binding
            end
          end

          methods[receiver_type] = public_bindings unless public_bindings.empty?
          private_methods[receiver_type] = hidden_bindings unless hidden_bindings.empty?
        end

        [methods, private_methods]
      end

      def exported_interface_implementations(analysis, exported_types, exported_interfaces)
        implemented_interfaces = {}
        private_implemented_interfaces = {}

        analysis.implemented_interfaces.each do |receiver_type, interfaces|
          public_interfaces = []
          hidden_interfaces = []

          interfaces.each do |interface|
            visible = exported_method_receiver?(receiver_type, analysis, exported_types) &&
              exported_interface_binding?(interface, analysis, exported_interfaces) &&
              exported_interface_methods?(receiver_type, interface, analysis, exported_types)
            if visible
              public_interfaces << interface
            else
              hidden_interfaces << interface
            end
          end

          implemented_interfaces[receiver_type] = public_interfaces.freeze unless public_interfaces.empty?
          private_implemented_interfaces[receiver_type] = hidden_interfaces.freeze unless hidden_interfaces.empty?
        end

        [implemented_interfaces.freeze, private_implemented_interfaces.freeze]
      end

      def exported_interface_methods?(receiver_type, interface, analysis, exported_types)
        return false unless exported_method_receiver?(receiver_type, analysis, exported_types)

        interface.methods.each_key.all? do |method_name|
          binding = analysis.methods.fetch(receiver_type, {})[method_name]
          binding && binding.ast.respond_to?(:visibility) && binding.ast.visibility == :public
        end
      end

      def exported_interface_binding?(interface, analysis, exported_interfaces)
        return true if exported_interfaces.value?(interface)

        imported_interface_binding?(interface, analysis.imports)
      end

      def exported_method_receiver?(receiver_type, analysis, exported_types)
        return true if receiver_type.is_a?(Types::StringView)
        return true if exported_types.value?(receiver_type)
        return true if imported_receiver_type?(receiver_type, analysis.imports)
        return exported_method_receiver?(receiver_type.base, analysis, exported_types) if receiver_type.is_a?(Types::Nullable)
        return receiver_type.arguments.all? { |argument| exported_method_receiver_argument?(argument, analysis, exported_types) } if receiver_type.is_a?(Types::GenericInstance)

        receiver_type.is_a?(Types::StructInstance) &&
          (exported_types.value?(receiver_type.definition) || imported_receiver_type?(receiver_type.definition, analysis.imports))
      end

      def exported_method_receiver_argument?(argument, analysis, exported_types)
        return true if argument.is_a?(Types::LiteralTypeArg)
        return true if argument.is_a?(Types::TypeVar)

        exported_method_receiver?(argument, analysis, exported_types)
      end

      def imported_receiver_type?(receiver_type, imports)
        imports.each_value do |module_binding|
          return true if module_binding.types.value?(receiver_type)
        end

        false
      end

      def imported_interface_binding?(interface, imports)
        imports.each_value do |module_binding|
          return true if module_binding.interfaces.value?(interface)
        end

        false
      end
    end
  end
end
