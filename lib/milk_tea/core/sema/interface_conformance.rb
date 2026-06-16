# frozen_string_literal: true

module MilkTea
  class Sema
    class Checker
      private

      def check_interface_conformances
        expanded_declarations.each do |decl|
          with_error_node(decl) do
            next unless decl.is_a?(AST::StructDecl) || decl.is_a?(AST::OpaqueDecl)
            next if decl.implements.empty?

            receiver_type = @types.fetch(decl.name)
            resolved_interfaces = []
            seen = {}

            decl.implements.each do |interface_ref|
              interface = resolve_interface_ref(interface_ref)
              raise_sema_error("duplicate interface #{decl.name} implements #{interface.name}") if seen.key?(interface)

              seen[interface] = true
              resolved_interfaces << interface
              validate_interface_conformance!(receiver_type, interface)
            end

            @implemented_interfaces[interface_implementation_key(receiver_type)] = resolved_interfaces.freeze
          end
        end
      end

      def validate_interface_conformance!(receiver_type, interface)
        interface.methods.each_value do |interface_method|
          method = lookup_local_method_for_interface(receiver_type, interface_method.name)
          raise_sema_error("type #{receiver_type} implements interface #{interface.name} but is missing method #{interface_method.name}") unless method

          validate_interface_method_match!(receiver_type, interface, interface_method, method)
        end
      end

      def lookup_local_method_for_interface(receiver_type, name)
        dispatch_receiver_type = method_dispatch_receiver_type(receiver_type)

        method = @methods.fetch(receiver_type, {})[name]
        method ||= @methods.fetch(dispatch_receiver_type, {})[name] unless dispatch_receiver_type == receiver_type
        static_name = "static:#{name}"
        method ||= @methods.fetch(receiver_type, {})[static_name]
        method ||= @methods.fetch(dispatch_receiver_type, {})[static_name] unless dispatch_receiver_type == receiver_type
        method
      end

      def validate_interface_method_match!(receiver_type, interface, interface_method, method)
        if method.ast.is_a?(AST::MethodDef) && method.ast.type_params.any?
          raise_sema_error("type #{receiver_type} method #{method.name} does not satisfy interface #{interface.name}: interface methods cannot be implemented by generic methods")
        end

        if interface_method.kind == :static
          raise_sema_error("type #{receiver_type} method #{method.name} does not satisfy interface #{interface.name}: method kind does not match") unless method.type.receiver_type.nil?
        else
          raise_sema_error("type #{receiver_type} method #{method.name} does not satisfy interface #{interface.name}: method kind does not match") if method.type.receiver_type.nil?

          expected_editable = interface_method.kind == :editable
          actual_editable = method.type.receiver_editable
          if actual_editable != expected_editable
            raise_sema_error("type #{receiver_type} method #{method.name} does not satisfy interface #{interface.name}: receiver editability does not match")
          end
        end

        method_params = method.type.params.map(&:type)
        interface_params = interface_method.params.map(&:type)
        unless method_params == interface_params && method.type.return_type == interface_method.return_type && method.async == interface_method.async
          raise_sema_error("type #{receiver_type} method #{method.name} does not satisfy interface #{interface.name}: signature does not match")
        end
      end

    end
  end
end
