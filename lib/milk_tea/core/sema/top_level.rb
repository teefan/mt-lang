# frozen_string_literal: true

module MilkTea
  class Sema
    class Checker
      private

      def check_top_level_values
        expanded_declarations.each do |decl|
          with_error_node(decl) do
            case decl
            when AST::ConstDecl
              begin
                if decl.block_body
                  check_block_body_const(decl)
                else
                  check_expr_const(decl)
                end
              rescue SemaError => e
                collect_structural_error(e)
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
        when AST::ProcExpr
          # Proc expressions are static-storage-safe when their body only
          # references module-level constants, functions, types, and imports.
          # The lowering handles capture detection; if a proc truly captures
          # a local from an enclosing scope (impossible at module level),
          # the sema validation above already rejects it via the
          # "cannot reference mutable value" check on the proc body.
          return
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
            when "array", "span", "zero", "reinterpret"
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

            value = resolve_current_module_const_value(identifier_expression.name)
            return value if value

            @types[identifier_expression.name]
          end,
          resolve_member_access: lambda do |member_access_expression|
            if member_access_expression.receiver.is_a?(AST::Identifier) && scopes
              binding = lookup_value(member_access_expression.receiver.name, scopes)
              if binding && binding.const_value
                receiver_value = binding.const_value
                case receiver_value
                when Types::FieldHandle
                  case member_access_expression.member
                  when "name" then next receiver_value.field_name
                  when "type" then next resolve_type_ref(receiver_value.field_declaration.type)
                  end
                when Types::MemberHandle
                  case member_access_expression.member
                  when "name" then next receiver_value.name
                  when "value" then next receiver_value.value
                  end
                when Types::AttributeHandle
                  case member_access_expression.member
                  when "name" then next receiver_value.name
                  end
                end
              end
            end

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
            evaluate_attributes_of_call(expression.arguments, scopes: scopes || [])
          else
            func = @top_level_functions[expression.callee.name]
            if func&.ast&.respond_to?(:const) && func.ast.const
              evaluate_const_function_body(func, expression.arguments, scopes:)
            else
              evaluate_type_returning_call(expression, scopes:)
            end
          end
        when AST::Specialization
          if expression.callee.callee.is_a?(AST::Identifier) && expression.callee.callee.name == "attribute_arg"
            evaluate_attribute_arg_call(expression.arguments, scopes: scopes || [])
          else
            callee_name = expression.callee.callee.is_a?(AST::Identifier) ? expression.callee.callee.name : nil
            if callee_name
              func = @top_level_functions[callee_name]
              if func&.ast&.respond_to?(:const) && func.ast.const
                evaluate_const_function_body(func, expression.arguments, scopes:)
              else
                evaluate_type_returning_call(expression, scopes:)
              end
            else
              evaluate_type_returning_call(expression, scopes:)
            end
          end
        else
          nil
        end
      end

      def evaluate_type_returning_call(expression, scopes:)
        callee_name, type_args = extract_type_callee_info(expression)
        return nil unless callee_name

        CompileTime::Reflection.core_evaluate_type_returning(
          callee_name, type_args,
          evaluate_value: ->(v) { evaluate_compile_time_const_value(v, scopes:) },
          resolve_type_ref: ->(tr) { resolve_type_ref(tr) },
          pointer_to: ->(t) { pointer_to(t) },
          const_pointer_to: ->(t) { const_pointer_to(t) },
          top_level_functions: ->(name) { @top_level_functions[name] },
          evaluate_type_returning_function_body: ->(func, targs) { evaluate_type_returning_function_body(func, targs) },
        )
      end

      def extract_type_callee_info(expression)
        if expression.is_a?(AST::Call) && expression.callee.is_a?(AST::Identifier)
          [expression.callee.name, nil]
        elsif expression.is_a?(AST::Specialization)
          if expression.callee.is_a?(AST::Identifier)
            [expression.callee.name, expression.arguments]
          elsif expression.callee.is_a?(AST::Specialization) && expression.callee.callee.is_a?(AST::Identifier)
            [expression.callee.callee.name, expression.callee.arguments]
          end
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

      def evaluate_const_function_body(func, arguments, scopes:)
        return nil unless func.ast.params.length == arguments.length

        initial_vars = {}
        func.ast.params.each_with_index do |param, idx|
          arg_expr = arguments[idx].value
          arg_value = if scopes
                        evaluate_compile_time_const_value(arg_expr, scopes:)
                      else
                        CompileTime.evaluate(
                          arg_expr,
                          resolve_identifier: lambda { |id| resolve_current_module_const_value(id.name) },
                          resolve_member_access: nil,
                          resolve_type_ref: lambda { |tr| resolve_type_ref(tr) },
                          resolve_call: nil,
                        )
                      end
          return nil unless arg_value

          initial_vars[param.name] = arg_value
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

        CompileTime::Reflection.core_field_handles(handle)
      end

      def evaluate_members_of_call(arguments)
        raise_sema_error("members_of expects 1 argument") unless arguments.length == 1

        type = resolve_type_expression(arguments.first.value)
        raise_sema_error("members_of requires a type argument") unless type

        unless type.is_a?(Types::Enum) || type.is_a?(Types::Flags)
          raise_sema_error("members_of requires an enum or flags type, got #{type}")
        end

        CompileTime::Reflection.core_member_handles(type)
      end

      def evaluate_attributes_of_call(arguments, scopes:)
        raise_sema_error("attributes_of expects 1 or 2 arguments") unless (1..2).include?(arguments.length)

        target = evaluate_reflection_target_argument(arguments.first.value, scopes:)

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
        expanded_declarations.grep(AST::StaticAssert).each do |statement|
          check_static_assert(statement, scopes: [])
        end
      end

    end
  end
end
