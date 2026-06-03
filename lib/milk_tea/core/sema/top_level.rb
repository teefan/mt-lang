# frozen_string_literal: true

module MilkTea
  class Sema
    class Checker
      private

      def check_top_level_values
        @ast.declarations.each do |decl|
          with_error_node(decl) do
            case decl
            when AST::ConstDecl
              binding = @top_level_values.fetch(decl.name)
              validate_consuming_foreign_expression!(decl.value, scopes: [], root_allowed: false)
              validate_hoistable_foreign_expression!(decl.value, scopes: [], root_hoistable: false)
              actual_type = infer_expression(decl.value, scopes: [], expected_type: binding.type)
              ensure_assignable!(
                actual_type,
                binding.type,
                "cannot assign #{actual_type} to constant #{decl.name}: expected #{binding.type}",
                expression: decl.value,
                line: decl.line,
              )
            when AST::VarDecl
              binding = @top_level_values.fetch(decl.name)
              if decl.value
                validate_consuming_foreign_expression!(decl.value, scopes: [], root_allowed: false)
                validate_hoistable_foreign_expression!(decl.value, scopes: [], root_hoistable: false)
                actual_type = infer_expression(decl.value, scopes: [], expected_type: binding.type)
                ensure_assignable!(
                  actual_type,
                  binding.type,
                  "cannot assign #{actual_type} to module variable #{decl.name}: expected #{binding.type}",
                  expression: decl.value,
                  line: decl.line,
                )
                validate_static_storage_initializer!(decl.value, scopes: [])
              else
                zero_initializable_type?(binding.type)
              end
            end
          end
        end
      end

      def validate_static_storage_initializer!(expression, scopes:)
        case expression
        when AST::ErrorExpr
          return
        when AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral, AST::BooleanLiteral, AST::NullLiteral,
             AST::SizeofExpr, AST::AlignofExpr, AST::OffsetofExpr
          return
        when AST::Identifier
          if (binding = lookup_value(expression.name, scopes))
            return if binding.kind == :const

            raise_sema_error("module variable initializer cannot reference mutable value #{expression.name}")
          end

          function = @top_level_functions[expression.name]
          return if function && static_storage_function_value?(function)

          raise_sema_error("module variable initializer must be static-storage-safe")
        when AST::MemberAccess
          return if static_storage_member_initializer?(expression, scopes:)

          raise_sema_error("module variable initializer must be static-storage-safe")
        when AST::UnaryOp
          validate_static_storage_initializer!(expression.operand, scopes:)
        when AST::BinaryOp
          validate_static_storage_initializer!(expression.left, scopes:)
          validate_static_storage_initializer!(expression.right, scopes:)
        when AST::IfExpr
          validate_static_storage_initializer!(expression.condition, scopes:)
          validate_static_storage_initializer!(expression.then_expression, scopes:)
          validate_static_storage_initializer!(expression.else_expression, scopes:)
        when AST::UnsafeExpr
          validate_static_storage_initializer!(expression.expression, scopes:)
        when AST::Specialization
          if expression.callee.is_a?(AST::Identifier)
            return if expression.callee.name == "zero"
          end

          raise_sema_error("module variable initializer must be static-storage-safe")
        when AST::Call
          validate_static_storage_call_initializer!(expression, scopes:)
        else
          raise_sema_error("module variable initializer must be static-storage-safe")
        end
      end

      def static_storage_member_initializer?(expression, scopes:)
        if (type_expr = resolve_type_expression(expression.receiver))
          return true if resolve_type_member(type_expr, expression.member)
        end

        return false unless expression.receiver.is_a?(AST::Identifier)
        return false unless @imports.key?(expression.receiver.name)

        imported_module = @imports.fetch(expression.receiver.name)
        if imported_module.private_value?(expression.member) || imported_module.private_function?(expression.member) || imported_module.private_type?(expression.member)
          raise_sema_error("#{expression.receiver.name}.#{expression.member} is private to module #{imported_module.name}")
        end

        if (binding = imported_module.values[expression.member])
          return true if binding.kind == :const

          raise_sema_error("module variable initializer cannot reference mutable value #{expression.receiver.name}.#{expression.member}")
        end

        function = imported_module.functions[expression.member]
        function && static_storage_function_value?(function)
      end

      def validate_static_storage_call_initializer!(expression, scopes:)
        expression.arguments.each do |argument|
          validate_static_storage_initializer!(argument.value, scopes:)
        end

        callee = expression.callee
        if callee.is_a?(AST::Identifier)
          if (type_expr = resolve_type_expression(callee))
            return if type_expr.is_a?(Types::Struct) || type_expr.is_a?(Types::StringView)
          end
        end

        if callee.is_a?(AST::MemberAccess)
          if (type_expr = resolve_type_expression(callee))
            return if type_expr.is_a?(Types::Struct) || type_expr.is_a?(Types::StringView)
          end
        end

        if callee.is_a?(AST::Specialization)
          if callee.callee.is_a?(AST::Identifier)
            case callee.callee.name
            when "array", "span", "zero", "cast", "reinterpret"
              return
            end
          end

          if (type_ref = type_ref_from_specialization(callee))
            specialized_type = resolve_type_ref(type_ref)
            return if specialized_type.is_a?(Types::Struct) || result_type?(specialized_type)
          end
        end

        raise_sema_error("module variable initializer must be static-storage-safe")
      end

      def static_storage_function_value?(binding)
        !binding.external && binding.type_params.empty?
      end

      def finalize_top_level_const_values
        @const_declarations.each_key { |name| evaluate_top_level_const_value(name) }
      end

      def evaluate_top_level_const_value(name)
        return @top_level_values.fetch(name).const_value if @evaluated_const_values.key?(name)

        raise_sema_error("cyclic constant value dependency involving #{name}") if @evaluating_const_values.include?(name)

        decl = @const_declarations.fetch(name)
        if decl.value.is_a?(AST::ErrorExpr)
          @evaluated_const_values[name] = true
          return nil
        end

        @evaluating_const_values << name
        value = evaluate_compile_time_const_value(decl.value)
        @evaluating_const_values.pop

        binding = @top_level_values.fetch(name)
        @top_level_values[name] = ValueBinding.new(
          id: binding.id,
          name: binding.name,
          storage_type: binding.storage_type,
          flow_type: binding.flow_type,
          mutable: binding.mutable,
          kind: binding.kind,
          const_value: value,
        )
        @evaluated_const_values[name] = true
        value
      end

      def evaluate_compile_time_const_value(expression, scopes: nil)
        CompileTime.evaluate(
          expression,
          resolve_identifier: lambda do |identifier_expression|
            if scopes
              binding = lookup_value(identifier_expression.name, scopes)
              return binding.const_value unless binding&.const_value.nil?
            end

            resolve_current_module_const_value(identifier_expression.name)
          end,
          resolve_member_access: lambda do |member_access_expression|
            if (receiver_type = resolve_type_expression(member_access_expression.receiver))
              next resolve_enum_member_const_value(receiver_type, member_access_expression.member)
            end

            next unless member_access_expression.receiver.is_a?(AST::Identifier)

            resolve_imported_module_const_value(member_access_expression.receiver.name, member_access_expression.member)
          end,
          resolve_type_ref: lambda do |type_ref|
            resolve_type_ref(type_ref)
          end,
          resolve_call: lambda do |call_expression|
            evaluate_compile_time_call(call_expression, scopes:)
          end,
        )
      end

      def evaluate_compile_time_call(expression, scopes: nil)
        case expression.callee
        when AST::Identifier
          case expression.callee.name
          when "field_of"
            evaluate_field_of_call(expression.arguments, scopes: scopes || [])
          when "callable_of"
            evaluate_callable_of_call(expression.arguments, scopes: scopes || [])
          when "has_attribute"
            evaluate_has_attribute_call(expression.arguments, scopes: scopes || [])
          when "attribute_of"
            evaluate_attribute_of_call(expression.arguments, scopes: scopes || [])
          else
            nil
          end
        when AST::Specialization
          if expression.callee.callee.is_a?(AST::Identifier) && expression.callee.callee.name == "attribute_arg"
            evaluate_attribute_arg_call(expression.arguments, scopes: scopes || [])
          end
        else
          nil
        end
      end

      def evaluate_has_attribute_call(arguments, scopes:)
        target = evaluate_reflection_target_argument(arguments.first.value, scopes:)
        binding = resolve_attribute_name_argument(arguments[1].value)
        validate_attribute_target_compatibility!(target, binding)
        !find_attribute_application(target, binding).nil?
      end

      def evaluate_attribute_of_call(arguments, scopes:)
        target = evaluate_reflection_target_argument(arguments.first.value, scopes:)
        binding = resolve_attribute_name_argument(arguments[1].value)
        validate_attribute_target_compatibility!(target, binding)

        application = find_attribute_application(target, binding)
        return nil unless application

        Types::AttributeHandle.new(
          binding.name,
          binding.module_name,
          target,
          binding.params,
          application.argument_values,
        )
      end

      def evaluate_attribute_arg_call(arguments, scopes:)
        attribute_handle = evaluate_compile_time_const_value(arguments.first.value, scopes:)
        return nil unless attribute_handle.is_a?(Types::AttributeHandle)

        param_name = reflection_identifier_name(arguments[1].value, context: "attribute_arg")
        return nil unless attribute_handle.argument_values

        attribute_handle.argument_values[param_name]
      end

      def evaluate_reflection_target_argument(expression, scopes:)
        if (type_expr = resolve_type_expression(expression))
          handle = struct_handle_for_type(type_expr)
          return handle if handle
        end

        value = evaluate_compile_time_const_value(expression, scopes:)
        return value if value.is_a?(Types::FieldHandle) || value.is_a?(Types::CallableHandle)

        nil
      end

      def evaluate_enum_member_const_value(expression, enum_type:, member_values:)
        CompileTime.evaluate(
          expression,
          resolve_identifier: lambda do |identifier_expression|
            resolve_current_module_const_value(identifier_expression.name)
          end,
          resolve_member_access: lambda do |member_access_expression|
            if (receiver_type = resolve_type_expression(member_access_expression.receiver))
              next resolve_enum_member_const_value(
                receiver_type,
                member_access_expression.member,
                local_enum_type: enum_type,
                local_member_values: member_values,
              )
            end

            next unless member_access_expression.receiver.is_a?(AST::Identifier)

            resolve_imported_module_const_value(member_access_expression.receiver.name, member_access_expression.member)
          end,
          resolve_type_ref: lambda do |type_ref|
            resolve_type_ref(type_ref)
          end,
        )
      end

      def check_top_level_static_asserts
        @ast.declarations.grep(AST::StaticAssert).each do |statement|
          check_static_assert(statement, scopes: [])
        end
      end

    end
  end
end
