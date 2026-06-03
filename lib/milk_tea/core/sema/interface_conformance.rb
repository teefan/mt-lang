# frozen_string_literal: true

module MilkTea
  class Sema
    class Checker
      private

      def check_interface_conformances
        @ast.declarations.each do |decl|
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

      def check_functions
        @top_level_functions.each_value do |binding|
          check_function(binding)
        end

        @methods.each_value do |method_map|
          method_map.each_value do |binding|
            check_function(binding)
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

          expected_mutable = interface_method.kind == :mutable
          actual_mutable = method.type.receiver_mutable
          if actual_mutable != expected_mutable
            raise_sema_error("type #{receiver_type} method #{method.name} does not satisfy interface #{interface.name}: receiver mutability does not match")
          end
        end

        method_params = method.type.params.map(&:type)
        interface_params = interface_method.params.map(&:type)
        unless method_params == interface_params && method.type.return_type == interface_method.return_type && method.async == interface_method.async
          raise_sema_error("type #{receiver_type} method #{method.name} does not satisfy interface #{interface.name}: signature does not match")
        end
      end

      # Per-function error collection used by check_collecting_errors.
      # Continues past individual function failures, accumulating SemaErrors.
      def check_functions_collecting(errors)
        @top_level_functions.each_value do |binding|
          next if @checked_function_bindings[binding.object_id]

          begin
            check_function(binding)
          rescue SemaError => e
            errors << e
          end
        end

        @methods.each_value do |method_map|
          method_map.each_value do |binding|
            next if @checked_function_bindings[binding.object_id]

            begin
              check_function(binding)
            rescue SemaError => e
              errors << e
            end
          end
        end
      end

      def check_function(binding)
        @local_completion_frames = @local_completion_frames.dup if @local_completion_frames.frozen?

        previous_type_substitutions = @current_type_substitutions
        previous_specialization_owner = @current_specialization_owner
        started_check = false
        return if binding.external || binding.type_params.any?
        return if @checked_function_bindings[binding.object_id]
        return if @checking_function_bindings[binding.object_id]

        @checking_function_bindings[binding.object_id] = true
        started_check = true
        @current_type_substitutions = binding.type_substitutions
        @current_specialization_owner = binding.specialization_owner
        with_scope(binding.body_params) do |scopes|
          start_local_completion_frame(binding, scopes)
          if binding.ast.is_a?(AST::ForeignFunctionDecl)
            record_callable_value_expression_site(binding.ast.mapping) unless binding.ast.mapping.is_a?(AST::Call)
            expression = foreign_mapping_expression(binding.ast)
            actual_type = with_foreign_mapping_context do
              infer_expression(expression, scopes:, expected_type: binding.type.return_type)
            end
            unless types_compatible?(actual_type, binding.type.return_type, expression:) || foreign_identity_projection_compatible?(actual_type, binding.type.return_type)
              raise_sema_error("foreign mapping #{binding.name} expects #{binding.type.return_type}, got #{actual_type}")
            end
          else
            validate_async_function_body!(binding.ast.body) if binding.async
            preassign_local_binding_ids(binding.ast.body)
            run_nullability_pre_pass(binding, scopes)
            if binding.async
              with_async_function do
                check_block(binding.ast.body, scopes:, return_type: binding.body_return_type)
              end
            else
              check_block(binding.ast.body, scopes:, return_type: binding.type.return_type)
            end
            check_definite_assignment(binding)
          end
        end
        @checked_function_bindings[binding.object_id] = true
      ensure
        return unless started_check

        finish_local_completion_frame(binding)
        @preassigned_local_binding_ids = {}
        @nullability_flow_result = nil
        @current_type_substitutions = previous_type_substitutions
        @current_specialization_owner = previous_specialization_owner
        @checking_function_bindings.delete(binding.object_id)
      end

    end
  end
end
