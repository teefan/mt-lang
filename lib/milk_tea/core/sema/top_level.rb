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
              if decl.block_body
                check_block_body_const(decl)
              else
                check_expr_const(decl)
              end
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

      def check_expr_const(decl)
        binding = @top_level_values.fetch(decl.name)
        validate_consuming_foreign_expression!(decl.value, scopes: [], root_allowed: false)
        validate_hoistable_foreign_expression!(decl.value, scopes: [], root_hoistable: false)

        if binding.type == builtin_type_meta_type
          evaluate_compile_time_const_value(decl.value)
          return
        end

        actual_type = infer_expression(decl.value, scopes: [], expected_type: binding.type)
        ensure_assignable!(
          actual_type,
          binding.type,
          "cannot assign #{actual_type} to constant #{decl.name}: expected #{binding.type}",
          expression: decl.value,
          line: decl.line,
        )
      end

      def check_block_body_const(decl)
        return unless decl.block_body

        last_stmt = decl.block_body.last
        unless last_stmt.is_a?(AST::ReturnStmt) && last_stmt.value
          raise_sema_error("block-bodied const must end with a return statement")
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
        when AST::ExpressionList
          expression.elements.each { |element| validate_static_storage_initializer!(element, scopes:) }
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
        if decl.block_body
          return evaluate_block_body_const(decl, name)
        end

        if decl.value.is_a?(AST::ErrorExpr)
          @evaluated_const_values[name] = true
          return nil
        end

        @evaluating_const_values << name
        value = evaluate_compile_time_const_value(decl.value)
        @evaluating_const_values.pop

        set_const_value(name, value)
        value
      end

      def evaluate_block_body_const(decl, name)
        @evaluating_const_values << name
        value = evaluate_compile_time_block(decl.block_body)
        @evaluating_const_values.pop
        set_const_value(name, value)
        value
      end

      def set_const_value(name, value)
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
      end

      def evaluate_compile_time_block(statements, scopes: nil)
        ctx = CompileTime::BlockContext.new(self)
        result = ctx.evaluate_block(statements, scopes:)
        result
      rescue CompileTime::ReturnValue => e
        e.value
      rescue CompileTime::Error => e
        raise_sema_error(e.message)
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
          when "fields_of"
            evaluate_fields_of_call(expression.arguments)
          when "callable_of"
            evaluate_callable_of_call(expression.arguments, scopes: scopes || [])
          when "has_attribute"
            evaluate_has_attribute_call(expression.arguments, scopes: scopes || [])
          when "attribute_of"
            evaluate_attribute_of_call(expression.arguments, scopes: scopes || [])
          when "members_of"
            evaluate_members_of_call(expression.arguments)
          when "attributes_of"
            evaluate_attributes_of_call(expression.arguments)
          else
            evaluate_type_returning_call(expression, scopes:)
          end
        when AST::Specialization
          if expression.callee.callee.is_a?(AST::Identifier) && expression.callee.callee.name == "attribute_arg"
            evaluate_attribute_arg_call(expression.arguments, scopes: scopes || [])
          else
            evaluate_type_returning_call(expression, scopes:)
          end
        else
          nil
        end
      end

      def evaluate_type_returning_call(expression, scopes:)
        callee_name = nil
        type_args = nil

        if expression.is_a?(AST::Call)
          if expression.callee.is_a?(AST::Identifier)
            callee_name = expression.callee.name
          end
        elsif expression.is_a?(AST::Specialization)
          if expression.callee.is_a?(AST::Identifier)
            callee_name = expression.callee.name
            type_args = expression.arguments
          elsif expression.callee.is_a?(AST::Specialization) && expression.callee.callee.is_a?(AST::Identifier)
            callee_name = expression.callee.callee.name
            type_args = expression.callee.arguments
          end
        end

        return nil unless callee_name

        case callee_name
        when "ptr", "const_ptr", "ref", "span", "array", "str_buffer", "Task"
          evaluated_args = (type_args || []).map do |arg|
            value = arg.value
            if value.is_a?(AST::Identifier)
              evaluate_compile_time_const_value(value, scopes:)
            elsif value.is_a?(AST::TypeRef)
              resolve_type_ref(value)
            elsif value.is_a?(AST::IntegerLiteral)
              Types::LiteralTypeArg.new(value.value)
            else
              nil
            end
          end
          return nil if evaluated_args.any?(&:nil?)

          case callee_name
          when "ptr"
            pointer_to(evaluated_args.first)
          when "const_ptr"
            const_pointer_to(evaluated_args.first)
          when "ref"
            reference_to(evaluated_args.first)
          when "span"
            Types::Span.new(evaluated_args.first)
          when "array"
            Types::GenericInstance.new("array", evaluated_args)
          when "str_buffer"
            Types::GenericInstance.new("str_buffer", evaluated_args)
          when "Task"
            Types::Task.new(evaluated_args.first)
          end
        else
          func = @top_level_functions[callee_name]
          return nil unless func
          return nil unless func.body_return_type == builtin_type_meta_type

          if type_args && func.ast
            value = evaluate_type_returning_function_body(func, type_args)
            return value if value
          end

          builtin_type_meta_type
        end
      end

      def evaluate_type_returning_function_body(func, type_args)
        value_params = func.ast.type_params.select { |p| p.is_a?(AST::ValueTypeParam) }
        return nil if value_params.empty?

        initial_vars = {}
        value_params.zip(type_args).each do |param, arg|
          arg_value = arg.value
          case arg_value
          when AST::IntegerLiteral
            initial_vars[param.name] = arg_value.value
          when AST::TypeRef
            initial_vars[param.name] = resolve_type_ref(arg_value)
          else
            return nil
          end
        end

        ctx = CompileTime::BlockContext.new(self, initial_variables: initial_vars)
        ctx.evaluate_block(func.ast.body, scopes: nil)
      rescue CompileTime::ReturnValue => e
        e.value
      rescue CompileTime::Error => e
        raise_sema_error(e.message)
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

      def evaluate_fields_of_call(arguments)
        raise_sema_error("fields_of expects 1 argument") unless arguments.length == 1

        type = resolve_type_expression(arguments.first.value)
        raise_sema_error("fields_of requires a type argument") unless type

        handle = struct_handle_for_type(type)
        raise_sema_error("fields_of requires a struct type, got #{type}") unless handle

        handle.declaration.fields.map do |field|
          Types::FieldHandle.new(handle, field.name, field)
        end
      end

      def evaluate_members_of_call(arguments)
        raise_sema_error("members_of expects 1 argument") unless arguments.length == 1

        type = resolve_type_expression(arguments.first.value)
        raise_sema_error("members_of requires a type argument") unless type

        unless type.is_a?(Types::Enum) || type.is_a?(Types::Flags)
          raise_sema_error("members_of requires an enum or flags type, got #{type}")
        end

        type.members.map do |member_name, member_value|
          Types::MemberHandle.new(nil, member_name, member_value)
        end
      end

      def evaluate_attributes_of_call(arguments)
        raise_sema_error("attributes_of expects 1 or 2 arguments") unless (1..2).include?(arguments.length)

        target = evaluate_reflection_target_argument(arguments.first.value, [])

        if arguments.length == 2
          attribute_binding = resolve_attribute_name_argument(arguments[1].value)
          application = find_attribute_application(target, attribute_binding)
          return [] unless application

          [Types::AttributeHandle.new(
            attribute_binding.name,
            attribute_binding.module_name,
            target,
            attribute_binding.params,
            application.argument_values,
          )]
        else
          resolved_attribute_applications_for_target(target).map do |application|
            Types::AttributeHandle.new(
              application.binding.name,
              application.binding.module_name,
              target,
              application.binding.params,
              application.argument_values,
            )
          end
        end
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
