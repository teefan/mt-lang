# frozen_string_literal: true

module MilkTea
  class Sema
    class Checker
      private

      def infer_lvalue(expression, scopes:)
        case expression
        when AST::Identifier
          binding = lookup_value(expression.name, scopes)
          unless binding
            scoped_names = scopes.flat_map { |s| s.is_a?(Hash) ? s.keys : [] }.map(&:to_s)
            suggestion = suggest_name(expression.name, scoped_names)
            raise_sema_error("unknown name #{expression.name}", expression, suggestion: suggestion ? "did you mean '#{suggestion}'?" : nil)
          end
          record_identifier_binding(expression, binding)
          raise_sema_error("cannot assign to immutable #{expression.name}") unless binding.mutable

          binding.storage_type
        when AST::MemberAccess
          receiver_type = infer_lvalue_receiver(expression.receiver, scopes:, allow_ref_identifier: true, allow_pointer_identifier: true, allow_span_param_identifier: true)
          receiver_type = project_field_receiver_type(receiver_type, require_mutable_pointer: true)
          unless aggregate_type?(receiver_type)
            raise_sema_error("cannot assign to member #{expression.member} of #{receiver_type}")
          end

          field_type = receiver_type.field(expression.member)
          raise_sema_error("unknown field #{receiver_type}.#{expression.member}") unless field_type

          field_type
        when AST::IndexAccess
          receiver_type = infer_lvalue_receiver(
            expression.receiver,
            scopes:,
            allow_pointer_identifier: true,
            require_mutable_pointer: true,
            allow_span_param_identifier: true,
          )

          index_type = infer_expression(expression.index, scopes:)
          infer_index_result_type(receiver_type, index_type)
        when AST::Call
          if read_call?(expression)
            validate_read_call_arguments!(expression.arguments)
            return infer_reference_value_type(expression.arguments.first.value, scopes:)
          end

          raise_sema_error("invalid assignment target")
        when AST::BinaryOp
          raise_sema_error("invalid assignment target")
        else
          raise_sema_error("invalid assignment target")
        end
      end

      def infer_lvalue_receiver(expression, scopes:, allow_ref_identifier: false, allow_pointer_identifier: false, require_mutable_pointer: false, allow_span_param_identifier: false)
        case expression
        when AST::Identifier
          binding = lookup_value(expression.name, scopes)
          raise_sema_error("unknown name #{expression.name}") unless binding
          record_identifier_binding(expression, binding)

          return referenced_type(binding.type) if allow_ref_identifier && ref_type?(binding.type)
          if allow_pointer_identifier && pointer_type?(binding.type)
            require_unsafe!("raw pointer dereference requires unsafe")
            raise_sema_error("cannot assign through read-only raw pointer #{binding.type}") if require_mutable_pointer && const_pointer_type?(binding.type)

            return binding.type
          end
          if allow_span_param_identifier && binding.kind == :param && span_type?(binding.type)
            return binding.type
          end

          raise_sema_error("cannot assign through immutable #{expression.name}") unless binding.mutable

          binding.type
        when AST::MemberAccess
          receiver_type = infer_lvalue_receiver(
            expression.receiver,
            scopes:,
            allow_ref_identifier:,
            allow_pointer_identifier:,
            require_mutable_pointer:,
            allow_span_param_identifier:,
          )
          receiver_type = project_field_receiver_type(receiver_type, require_mutable_pointer:)
          unless aggregate_type?(receiver_type)
            raise_sema_error("cannot access member #{expression.member} of #{receiver_type}")
          end

          field_type = receiver_type.field(expression.member)
          raise_sema_error("unknown field #{receiver_type}.#{expression.member}") unless field_type

          field_type
        when AST::IndexAccess
          receiver_type = infer_lvalue_receiver(
            expression.receiver,
            scopes:,
            allow_ref_identifier:,
            allow_pointer_identifier:,
            require_mutable_pointer:,
            allow_span_param_identifier:,
          )
          index_type = infer_expression(expression.index, scopes:)
          infer_index_result_type(receiver_type, index_type)
        when AST::Call
          if read_call?(expression)
            validate_read_call_arguments!(expression.arguments)
            return infer_reference_value_type(expression.arguments.first.value, scopes:)
          end

          raise_sema_error("invalid assignment target")
        when AST::BinaryOp
          require_unsafe!("raw pointer arithmetic as lvalue receiver requires unsafe")
          type = infer_expression(expression, scopes:)
          raise_sema_error("binary op lvalue receiver must be a pointer") unless pointer_type?(type)
          raise_sema_error("cannot assign through read-only raw pointer #{type}") if require_mutable_pointer && const_pointer_type?(type)

          type
        else
          raise_sema_error("invalid assignment target")
        end
      end

      def external_numeric_assignment_target?(expression, scopes:)
        case expression
        when AST::MemberAccess
          receiver_type = infer_field_receiver_type(expression.receiver, scopes:, require_mutable_pointer: true)
          receiver_type.respond_to?(:external) && receiver_type.external
        else
          false
        end
      end

      def infer_expression(expression, scopes:, expected_type: nil)
        with_error_node(expression) do
          case expression
          when AST::ErrorExpr
            expected_type || @error_type
          when AST::IntegerLiteral
            infer_integer_literal(expected_type)
          when AST::FloatLiteral
            infer_float_literal(expression, expected_type)
          when AST::SizeofExpr
            unless check_layout_type_via_ct(expression.type, context: "size_of", scopes:)
              infer_layout_query_type(expression.type, context: "size_of")
            end
            @ctx.types.fetch("ptr_uint")
          when AST::AlignofExpr
            unless check_layout_type_via_ct(expression.type, context: "align_of", scopes:)
              infer_layout_query_type(expression.type, context: "align_of")
            end
            @ctx.types.fetch("ptr_uint")
          when AST::OffsetofExpr
            infer_offsetof_type(expression.type, expression.field, scopes:)
            @ctx.types.fetch("ptr_uint")
          when AST::StringLiteral
            @ctx.types.fetch(expression.cstring ? "cstr" : "str")
          when AST::FormatString
            check_format_string_literal(expression, scopes:)
            @ctx.types.fetch("str")
          when AST::BooleanLiteral
            @ctx.types.fetch("bool")
          when AST::NullLiteral
            infer_null_literal(expression)
          when AST::Identifier
            infer_identifier(expression, scopes:, expected_type:)
          when AST::MemberAccess
            infer_member_access(expression, scopes:, expected_type:)
          when AST::IndexAccess
            infer_index_access(expression, scopes:)
          when AST::UnaryOp
            infer_unary(expression, scopes:, expected_type:)
          when AST::BinaryOp
            infer_binary(expression, scopes:, expected_type:)
          when AST::IfExpr
            infer_if_expression(expression, scopes:, expected_type:)
          when AST::MatchExpr
            infer_match_expression(expression, scopes:, expected_type:)
          when AST::UnsafeExpr
            infer_unsafe_expression(expression, scopes:, expected_type:)
          when AST::ProcExpr
            infer_proc_expression(expression, scopes:, expected_type:)
          when AST::AwaitExpr
            infer_await_expression(expression, scopes:)
          when AST::DetachExpr
            @uses_parallel_for = true
            check_block(expression.body, scopes:, return_type: @ctx.types.fetch("void"), allow_return: false)
            Types::Handle.new
          when AST::Call
            infer_call(expression, scopes:, expected_type:)
          when AST::PrefixCast
            target_type = resolve_type_ref(expression.target_type)
            check_cast_call(target_type, [AST::Argument.new(name: nil, value: expression.expression)], scopes:)
            target_type
          when AST::Specialization
            if expression.callee.is_a?(AST::Identifier)
              if expression.callee.name == "zero"
                callable_kind, callable, = resolve_callable(expression, scopes:)
                return check_zero_call(callable, [], expected_type:) if callable_kind == :zero
              end

              if expression.callee.name == "default"
                resolution = resolve_default_specialization(expression)
                return resolution.target_type
              end
            end

            if (callable_resolution = resolve_specialized_callable_binding(expression, scopes:))
              callable_kind, function_binding, = callable_resolution
              raise_sema_error("specialized method #{describe_expression(expression)} must be called") if callable_kind == :method

              return function_binding.type
            end

            raise_sema_error("specialized name #{describe_expression(expression)} must be called")
          when AST::RangeExpr
            raise_sema_error("range expression can only be used as a for-loop iterable or range index target")
          when AST::ExpressionList
            if expected_type && expected_type.is_a?(Types::GenericInstance) && expected_type.name == "array"
              element_type = expected_type.arguments.first
              expression.elements.each do |element|
                value = element.is_a?(AST::Argument) ? element.value : element
                actual = infer_expression(value, scopes:, expected_type: element_type)
                ensure_assignable!(actual, element_type, "array element type mismatch: expected #{element_type}, got #{actual}", expression: value)
              end
              expected_type
            else
              names = []
              element_types = []
              expression.elements.each do |element|
                if element.is_a?(AST::Argument)
                  names << element.name
                  element_types << infer_expression(element.value, scopes:)
                else
                  names << nil
                  element_types << infer_expression(element, scopes:)
                end
              end
              has_named = names.any?
              Types::Tuple.new(element_types, field_names: has_named ? names : nil)
            end
          else
            raise_sema_error("unsupported expression #{expression.class.name}")
          end
        end
      end

      def infer_unsafe_expression(expression, scopes:, expected_type: nil)
        @unsafe_statement_lines << expression.line
        begin
          with_unsafe do
            infer_expression(expression.expression, scopes:, expected_type:)
          end
        ensure
          @unsafe_statement_lines.pop
        end
      end

      def infer_integer_literal(expected_type)
        if expected_type.is_a?(Types::Primitive) && expected_type.integer?
          expected_type
        else
          @ctx.types.fetch("int")
        end
      end

      def infer_float_literal(expression, expected_type)
        if expression.lexeme.end_with?("float")
          @ctx.types.fetch("float")
        elsif expression.lexeme.end_with?("double")
          @ctx.types.fetch("double")
        elsif expected_type.is_a?(Types::Primitive) && expected_type.float?
          expected_type
        else
          @ctx.types.fetch("double")
        end
      end

      def infer_identifier(expression, scopes:, expected_type: nil)
        binding = lookup_value(expression.name, scopes)
        if binding
          record_identifier_binding(expression, binding)
          return binding.type
        end

        if @ctx.top_level_functions.key?(expression.name)
          raise_sema_error("generic function #{expression.name} must be called") if @ctx.top_level_functions.fetch(expression.name).type_params.any?

          function_type = function_type_for_name(expression.name)
          if expected_type
            record_callable_value_identifier_site(expression)
            return function_type
          end

          raise_sema_error("function #{expression.name} must be called")
        end

        raise_sema_error("module #{expression.name} cannot be used as a value") if @ctx.imports.key?(expression.name)
        if @ctx.types.key?(expression.name)
          return Types::BUILTIN_TYPE_META_TYPE if expected_type.is_a?(Types::TypeType)
          return @ctx.types.fetch(expression.name)
        end

        if @ctx.top_level_functions && @ctx.types && scopes
          func_names = @ctx.top_level_functions.keys.map(&:to_s)
          type_names = @ctx.types.keys.map(&:to_s)
          scoped_names = scopes.flat_map { |s| s.is_a?(Hash) ? s.keys : [] }.map(&:to_s)
          suggestion = suggest_name(expression.name, func_names + type_names + scoped_names)
        end
        raise_sema_error("unknown name #{expression.name}", expression, suggestion: suggestion ? "did you mean '#{suggestion}'?" : nil)
      end

      def infer_member_access(expression, scopes:, expected_type: nil)
        type = resolve_type_expression(expression.receiver)
        if type
          return @error_type if error_type?(type)

          member_type = resolve_type_member(type, expression.member)
          return member_type if member_type

          if type.is_a?(Types::Variant) && type.arm_names.include?(expression.member)
            raise_sema_error("variant arm #{type}.#{expression.member} has payload; construct it with #{type}.#{expression.member}(field: value, ...)")
          end

          if (method = lookup_method(type, expression.member))
            raise_sema_error("associated function #{type}.#{expression.member} must be called") unless method.type.receiver_type.nil?
            raise_sema_error("method #{type}.#{expression.member} must be called")
          end

          raise_sema_error("unknown member #{type}.#{expression.member}")
        end

        if expression.receiver.is_a?(AST::Identifier) && @ctx.imports.key?(expression.receiver.name)
          imported_module = @ctx.imports.fetch(expression.receiver.name)
          value = imported_module.values[expression.member]
          return value.type if value

          if imported_module.functions.key?(expression.member)
            function = imported_module.functions.fetch(expression.member)
            raise_sema_error("generic function #{expression.receiver.name}.#{expression.member} must be called") if function.type_params.any?
            if expected_type
              record_callable_value_member_access_site(expression)
              return function.type
            end

            raise_sema_error("function #{expression.receiver.name}.#{expression.member} must be called")
          end

          if imported_module.types.key?(expression.member)
            raise_sema_error("type #{expression.receiver.name}.#{expression.member} cannot be used as a value")
          end

          if imported_module.private_value?(expression.member) || imported_module.private_function?(expression.member) || imported_module.private_type?(expression.member)
            raise_sema_error("#{expression.receiver.name}.#{expression.member} is private to module #{imported_module.name}")
          end

          raise_sema_error("unknown member #{expression.receiver.name}.#{expression.member}")
        end

        field_receiver_type = infer_field_receiver_type(expression.receiver, scopes:)
        method_receiver_type = infer_method_receiver_type(expression.receiver, scopes:, member_name: expression.member)
        return @error_type if error_type?(field_receiver_type) || error_type?(method_receiver_type)

        if array_type?(field_receiver_type) && expression.member == "as_span"
          element_type = array_element_type(field_receiver_type)
          return Types::Span.new(element_type)
        end
        if char_array_removed_text_method?(method_receiver_type, expression.member)
          raise_sema_error("#{method_receiver_type}.#{expression.member} is not available; array[char, N] is raw storage, use str_buffer[N] or an explicit helper")
        end
        if str_buffer_type?(method_receiver_type) && str_buffer_method_kind(method_receiver_type, expression.member)
          raise_sema_error("method #{method_receiver_type}.#{expression.member} must be called")
        end
        if event_type?(method_receiver_type) && event_method_kind(method_receiver_type, expression.member)
          raise_sema_error("method #{method_receiver_type}.#{expression.member} must be called")
        end

        unless aggregate_type?(field_receiver_type)
          if field_receiver_type == builtin_field_handle_type
            return infer_field_handle_member(expression, scopes:)
          end
          if field_receiver_type == builtin_member_handle_type
            return infer_member_handle_member(expression)
          end
          raise_sema_error("cannot access member #{expression.member} of #{field_receiver_type}")
        end

        field_type = field_receiver_type.field(expression.member)
        return field_type if field_type

        if (event_type = event_member_type(field_receiver_type, expression.member))
          unless event_visible_from_current_module?(event_type)
            raise_sema_error("event #{field_receiver_type}.#{expression.member} is private to module #{event_type.module_name}")
          end

          return event_type
        end

        if lookup_method(method_receiver_type, expression.member)
          raise_sema_error("method #{method_receiver_type.name}.#{expression.member} must be called")
        end

        if (imported_module = imported_module_with_private_method(method_receiver_type, expression.member))
          raise_sema_error("#{method_receiver_type}.#{expression.member} is private to module #{imported_module.name}")
        end

        raise_sema_error("unknown field #{field_receiver_type}.#{expression.member}")
      end

      def infer_index_access(expression, scopes:)
        receiver_type = infer_expression(expression.receiver, scopes:)
        index_type = infer_expression(expression.index, scopes:)

        if soa_type?(receiver_type)
          return receiver_type.element_type
        end

        if array_type?(receiver_type) && !unsafe_context? && !addressable_storage_expression?(expression.receiver, scopes:)
          raise_sema_error("safe array indexing requires an addressable array value; bind it to a local first")
        end

        infer_index_result_type(receiver_type, index_type)
      end

      def infer_unary(expression, scopes:, expected_type: nil)
        return infer_propagate_expression(expression.operand, scopes:) if expression.operator == "?"

        operand_type = infer_expression(expression.operand, scopes:, expected_type:)

        case expression.operator
        when "not"
          ensure_assignable!(operand_type, @ctx.types.fetch("bool"), "operator not requires bool, got #{operand_type}")
          @ctx.types.fetch("bool")
        when "+", "-"
          raise_sema_error("operator #{expression.operator} requires a numeric operand, got #{operand_type}") unless operand_type.numeric?

          operand_type
        when "~"
          raise_sema_error("operator ~ requires an integer or flags operand, got #{operand_type}") unless bitwise_type?(operand_type)

          operand_type
        when "out", "in", "inout"
          raise_sema_error("#{expression.operator} is only allowed for foreign call arguments")
        else
          raise_sema_error("unsupported unary operator #{expression.operator}")
        end
      end

      def infer_propagate_expression(operand, scopes:, allow_void_success: false)
        source_type = infer_expression(operand, scopes:)
        if result_let_else_type?(source_type)
          infer_result_propagation(source_type, allow_void_success:)
        elsif option_let_else_type?(source_type)
          infer_option_propagation(source_type, allow_void_success:)
        else
          raise_sema_error("propagation expects Result[T, E] or Option[T], got #{source_type}")
        end
      end

      def infer_result_propagation(source_type, allow_void_success:)
        success_type = let_else_success_type(source_type)
        error_type = let_else_error_type(source_type)
        raise_sema_error("propagation requires a non-void Result success type") if success_type == @ctx.types.fetch("void") && !allow_void_success

        context = current_return_context
        raise_sema_error("propagation is only allowed inside function and proc bodies") unless context
        raise_sema_error("propagation is not allowed inside defer blocks") unless context[:allow_return]

        return_type = context[:return_type]
        unless result_let_else_type?(return_type)
          raise_sema_error("propagation requires enclosing function/proc to return Result[_, #{error_type}], got #{return_type}")
        end

        return_error_type = let_else_error_type(return_type)
        unless return_error_type == error_type
          raise_sema_error("propagation error type #{error_type} must match enclosing Result error type #{return_error_type}")
        end

        success_type
      end

      def infer_option_propagation(source_type, allow_void_success:)
        success_type = let_else_success_type(source_type)
        raise_sema_error("propagation requires a non-void Option success type") if success_type == @ctx.types.fetch("void") && !allow_void_success

        context = current_return_context
        raise_sema_error("propagation is only allowed inside function and proc bodies") unless context
        raise_sema_error("propagation is not allowed inside defer blocks") unless context[:allow_return]

        return_type = context[:return_type]
        unless option_let_else_type?(return_type)
          raise_sema_error("propagation requires enclosing function/proc to return Option[_], got #{return_type}")
        end

        success_type
      end


      def infer_binary(expression, scopes:, expected_type: nil)
        propagated_type = propagating_expected_type(expression.operator, expected_type)
        left_type = infer_expression(expression.left, scopes:, expected_type: propagated_type)

        right_scopes = case expression.operator
                       when "and"
                         scopes_with_refinements(scopes, flow_refinements(expression.left, truthy: true, scopes:))
                       when "or"
                         scopes_with_refinements(scopes, flow_refinements(expression.left, truthy: false, scopes:))
                       else
                         scopes
                       end

        right_expected_type = case expression.operator
                              when "<<", ">>"
                                propagated_type || left_type
                              when "+", "-", "*", "/", "%"
                                propagated_type || left_type
                              when "|", "&", "^"
                                left_type
                              else
                                left_type
                              end

        right_type = infer_expression(expression.right, scopes: right_scopes, expected_type: right_expected_type)
        left_type, right_type = harmonize_binary_float_literal_types(
          expression.left,
          expression.right,
          left_type,
          right_type,
          scopes: right_scopes,
        )

        left_type, right_type = harmonize_binary_integer_literal_types(
          expression.left,
          expression.right,
          left_type,
          right_type,
          scopes: right_scopes,
        )

        case expression.operator
        when "and", "or"
          ensure_assignable!(left_type, @ctx.types.fetch("bool"), "operator #{expression.operator} requires bool operands")
          ensure_assignable!(right_type, @ctx.types.fetch("bool"), "operator #{expression.operator} requires bool operands")
          @ctx.types.fetch("bool")
        when "|", "&", "^"
          # For Flags/Enum types, the operands must match and be bitwise-capable.
          unless left_type == right_type && (bitwise_type?(left_type) || left_type.is_a?(Types::Flags))
            raise_sema_error("operator #{expression.operator} requires matching integer or flags types, got #{left_type} and #{right_type}")
          end

          left_type
        when "+", "-", "*", "/"
          if expression.operator == "+" && (string_like_type?(left_type) || string_like_type?(right_type))
            raise_sema_error("operator + does not support str/cstr concatenation; use continued string literals for static text or string.String/str_buffer for dynamic text")
          end

          pointer_result = pointer_arithmetic_result(expression.operator, left_type, right_type)
          return pointer_result if pointer_result

          vector_result = vector_arithmetic_result(expression.operator, left_type, right_type)
          return vector_result if vector_result

          result_type = common_numeric_type(left_type, right_type)
          unless result_type
            raise_sema_error("operator #{expression.operator} requires compatible numeric types, got #{left_type} and #{right_type}")
          end

          result_type
        when "%"
          result_type = common_integer_type(left_type, right_type)
          unless result_type
            raise_sema_error("operator % requires compatible integer types, got #{left_type} and #{right_type}")
          end

          result_type
        when "<<", ">>"
          unless left_type.is_a?(Types::Primitive) && left_type.integer? && right_type.is_a?(Types::Primitive) && right_type.integer?
            raise_sema_error("operator #{expression.operator} requires integer operands, got #{left_type} and #{right_type}")
          end

          left_type
        when "<", "<=", ">", ">="
          unless common_numeric_type(left_type, right_type)
            raise_sema_error("operator #{expression.operator} requires compatible numeric types, got #{left_type} and #{right_type}")
          end

          @ctx.types.fetch("bool")
        when "==", "!="
          unless c_natively_equality_comparable_type?(left_type) && c_natively_equality_comparable_type?(right_type)
            bad_type = c_natively_equality_comparable_type?(right_type) ? left_type : right_type
            if struct_instance_type?(bad_type)
              raise_sema_error("operator #{expression.operator} is not supported for struct type #{bad_type}; use equal[#{bad_type}](...) instead")
            else
              raise_sema_error("operator #{expression.operator} is not supported for type #{bad_type}")
            end
          end
          unless common_numeric_type(left_type, right_type) || types_compatible?(left_type, right_type) || types_compatible?(right_type, left_type)
            raise_sema_error("operator #{expression.operator} requires comparable types, got #{left_type} and #{right_type}")
          end

          @ctx.types.fetch("bool")
        else
          raise_sema_error("unsupported binary operator #{expression.operator}")
        end
      end

      def infer_if_expression(expression, scopes:, expected_type: nil)
        condition_type = infer_expression(expression.condition, scopes:, expected_type: @ctx.types.fetch("bool"))
        ensure_assignable!(condition_type, @ctx.types.fetch("bool"), "if expression condition must be bool, got #{condition_type}")

        then_scopes = scopes_with_refinements(scopes, flow_refinements(expression.condition, truthy: true, scopes:))
        else_scopes = scopes_with_refinements(scopes, flow_refinements(expression.condition, truthy: false, scopes:))
        then_type = infer_expression(expression.then_expression, scopes: then_scopes, expected_type:)
        else_type = infer_expression(expression.else_expression, scopes: else_scopes, expected_type:)

        return expected_type if expected_type &&
          types_compatible?(then_type, expected_type, expression: expression.then_expression) &&
          types_compatible?(else_type, expected_type, expression: expression.else_expression)

        common_type = conditional_common_type(
          then_type,
          else_type,
          then_expression: expression.then_expression,
          else_expression: expression.else_expression,
        )
        return common_type if common_type

        raise_sema_error("if expression branches require compatible types, got #{then_type} and #{else_type}")
      end

      def infer_match_expression(expression, scopes:, expected_type: nil)
        validate_consuming_foreign_expression!(expression.expression, scopes:, root_allowed: false)
        validate_hoistable_foreign_expression!(expression.expression, scopes:, root_hoistable: false)
        scrutinee_type = infer_expression(expression.expression, scopes:)

        if error_type?(scrutinee_type)
          infer_recovered_match_expression(expression, scopes:, expected_type:)
        elsif scrutinee_type.is_a?(Types::Enum)
          infer_enum_match_expression(expression, scrutinee_type, scopes:, expected_type:)
        elsif scrutinee_type.is_a?(Types::Variant)
          infer_variant_match_expression(expression, scrutinee_type, scopes:, expected_type:)
        elsif integer_type?(scrutinee_type)
          infer_integer_match_expression(expression, scrutinee_type, scopes:, expected_type:)
        else
          raise_sema_error("match requires an enum, variant, or integer scrutinee, got #{scrutinee_type}")
        end
      end

      def infer_recovered_match_expression(expression, scopes:, expected_type:)
        arm_entries = expression.arms.map do |arm|
          arm_scopes = scopes
          if arm.binding_name
            ensure_non_reserved_primitive_name!(arm.binding_name, kind_label: "match binding", line: arm.binding_line, column: arm.binding_column)
            binding = value_binding(
              name: arm.binding_name,
              type: @error_type,
              mutable: false,
              kind: :local,
              id: @preassigned_local_binding_ids.fetch(arm.object_id),
            )
            arm_scopes = scopes + [{ arm.binding_name => binding }]
            record_declaration_binding(arm, binding)
          end
          [infer_match_expression_arm_value(arm, scopes: arm_scopes, expected_type:), arm.value]
        end

        match_expression_common_type(arm_entries, expected_type)
      end

      def infer_enum_match_expression(expression, scrutinee_type, scopes:, expected_type:)
        arm_entries = []
        each_enum_match_arm(expression, scrutinee_type, scopes:) do |arm, arm_scopes|
          arm_entries << [infer_match_expression_arm_value(arm, scopes: arm_scopes, expected_type:), arm.value]
        end
        match_expression_common_type(arm_entries, expected_type)
      end

      def infer_integer_match_expression(expression, scrutinee_type, scopes:, expected_type:)
        has_wildcard = expression.arms.any? { |arm| wildcard_pattern?(arm.pattern) }
        raise_sema_error("match on integer type #{scrutinee_type} requires a wildcard arm (_:)") unless has_wildcard

        covered_values = {}
        wildcard_seen = false
        arm_entries = []

        expression.arms.each do |arm|
          if arm.pattern.is_a?(AST::ErrorExpr)
            arm_entries << [infer_match_expression_arm_value(arm, scopes:, expected_type:), arm.value]
            next
          end

          if wildcard_pattern?(arm.pattern)
            raise_sema_error("duplicate wildcard arm in match") if wildcard_seen

            wildcard_seen = true
            arm_entries << [infer_match_expression_arm_value(arm, scopes:, expected_type:), arm.value]
            next
          end

          unless arm.pattern.is_a?(AST::IntegerLiteral)
            raise_sema_error("match arm for integer scrutinee must be an integer literal or _, got #{arm.pattern.class.name}")
          end

          value = arm.pattern.value
          raise_sema_error("duplicate match arm value #{value}") if covered_values.key?(value)

          covered_values[value] = true
          arm_entries << [infer_match_expression_arm_value(arm, scopes:, expected_type:), arm.value]
        end

        match_expression_common_type(arm_entries, expected_type)
      end

      def infer_variant_match_expression(expression, scrutinee_type, scopes:, expected_type:)
        arm_entries = []
        each_variant_match_arm(expression, scrutinee_type, scopes:) do |arm, arm_scopes|
          arm_entries << [infer_match_expression_arm_value(arm, scopes: arm_scopes, expected_type:), arm.value]
        end
        match_expression_common_type(arm_entries, expected_type)
      end

      def infer_match_expression_arm_value(arm, scopes:, expected_type:)
        validate_consuming_foreign_expression!(arm.value, scopes:, root_allowed: false)
        validate_hoistable_foreign_expression!(arm.value, scopes:, root_hoistable: false)
        infer_expression(arm.value, scopes:, expected_type:)
      end

      def match_expression_common_type(arm_entries, expected_type)
        return expected_type || @error_type if arm_entries.empty?

        if expected_type && arm_entries.all? { |type, expr| types_compatible?(type, expected_type, expression: expr) }
          return expected_type
        end

        common_type, common_expression = arm_entries.first
        arm_entries.drop(1).each do |type, expr|
          next if type == common_type

          merged_type = conditional_common_type(
            common_type,
            type,
            then_expression: common_expression,
            else_expression: expr,
          )
          raise_sema_error("match expression arms require compatible types, got #{common_type} and #{type}") unless merged_type

          common_type = merged_type
          common_expression = expr
        end

        common_type
      end

      def infer_proc_expression(expression, scopes:, expected_type: nil)
        proc_type = resolve_type_ref(AST::ProcType.new(params: expression.params, return_type: expression.return_type))
        if expected_type && !proc_type_compatible?(proc_type, expected_type)
          raise_sema_error("proc expression expects #{proc_type}, got #{expected_type}")
        end

        proc_scopes = scopes.map { |scope| freeze_scope_bindings(scope) }
        proc_scope = {}
        expression.params.each do |param|
          ensure_non_reserved_primitive_name!(param.name, kind_label: "parameter", line: param.respond_to?(:line) ? param.line : nil, column: param.respond_to?(:column) ? param.column : nil)
          param_type = resolve_type_ref(param.type)
          validate_parameter_ref_type!(param_type, function_name: "proc", parameter_name: param.name, external: false)
          validate_parameter_proc_type!(param_type, function_name: "proc", parameter_name: param.name, external: false, foreign: false)
          proc_scope[param.name] = value_binding(name: param.name, type: param_type, mutable: false, kind: :param)
        end

        check_block(expression.body, scopes: proc_scopes + [proc_scope], return_type: proc_type.return_type, allow_return: true)
        proc_type
      end

      def infer_await_expression(expression, scopes:)
        raise_sema_error("await is only allowed inside async functions") unless inside_async_function?

        task_type = infer_expression(expression.expression, scopes:)
        raise_sema_error("await expects Task[T], got #{task_type}") unless task_type.is_a?(Types::Task)

        task_type.result_type
      end

      def harmonize_binary_float_literal_types(left_expression, right_expression, left_type, right_type, scopes:)
        if float_literal_expression?(left_expression) && right_type.is_a?(Types::Primitive) && right_type.float?
          left_type = infer_expression(left_expression, scopes:, expected_type: right_type)
        end

        if float_literal_expression?(right_expression) && left_type.is_a?(Types::Primitive) && left_type.float?
          right_type = infer_expression(right_expression, scopes:, expected_type: left_type)
        end

        [left_type, right_type]
      end

      def float_literal_expression?(expression)
        expression.is_a?(AST::FloatLiteral) ||
          (expression.is_a?(AST::UnaryOp) && ["+", "-"].include?(expression.operator) && float_literal_expression?(expression.operand))
      end

      def harmonize_binary_integer_literal_types(left_expression, right_expression, left_type, right_type, scopes:)
        if integer_literal_expression?(left_expression) && right_type.is_a?(Types::Primitive) && right_type.integer?
          if exact_compile_time_numeric_compatibility?(left_type, left_expression, right_type, scopes:)
            left_type = infer_expression(left_expression, scopes:, expected_type: right_type)
          end
        end

        if integer_literal_expression?(right_expression) && left_type.is_a?(Types::Primitive) && left_type.integer?
          if exact_compile_time_numeric_compatibility?(right_type, right_expression, left_type, scopes:)
            right_type = infer_expression(right_expression, scopes:, expected_type: left_type)
          end
        end

        [left_type, right_type]
      end

      def integer_literal_expression?(expression)
        expression.is_a?(AST::IntegerLiteral)
      end

      def propagating_expected_type(operator, expected_type)
        case operator
        when "+", "-", "*", "/", "%", "<<", ">>"
          return expected_type if expected_type.is_a?(Types::Primitive) && expected_type.numeric?
        when "|", "&", "^"
          return expected_type if expected_type.is_a?(Types::Primitive) && expected_type.integer?
          return expected_type if expected_type.is_a?(Types::Flags)
        end

        nil
      end

      def infer_call(expression, scopes:, expected_type: nil)
        callable_kind, callable, receiver = resolve_callable(expression.callee, scopes:)

        case callable_kind
        when :function
          callable = specialize_function_binding(
            callable,
            expression.arguments,
            scopes:,
            receiver_type: callable_receiver_type_for_specialization(expression.callee, scopes:),
          )

          check_function_call(callable, expression.arguments, scopes:)
          callable.owner.send(:check_function, callable) unless callable.type_arguments.empty?
          callable.type.return_type
        when :method
          callable = specialize_function_binding(
            callable,
            expression.arguments,
            scopes:,
            receiver_type: infer_method_receiver_type(receiver, scopes:, member_name: expression.callee.member),
          ) if callable.type_params.any?
          record_editable_receiver_expression(receiver) if callable.type.receiver_editable
          raise_sema_error("cannot call editable method #{callable.name} on an immutable receiver") if callable.type.receiver_editable && !assignable_receiver?(receiver, scopes)

          check_function_call(callable, expression.arguments, scopes:)
          callable.owner.send(:check_function, callable) unless callable.type_arguments.empty?
          callable.type.return_type
        when :callable_value
          check_callable_value_call(callable, expression.arguments, scopes:, callee_expression: expression.callee)
          callable.return_type
        when :str_buffer_clear, :str_buffer_assign, :str_buffer_append, :str_buffer_assign_format, :str_buffer_append_format,
          :str_buffer_len, :str_buffer_capacity, :str_buffer_as_str, :str_buffer_as_cstr
          check_str_buffer_method_call(callable_kind, receiver, expression.arguments, scopes:)
        when :array_as_span
          raise_sema_error("as_span does not support named arguments") if expression.arguments.any?(&:name)
          raise_sema_error("as_span expects 0 arguments, got #{expression.arguments.length}") unless expression.arguments.empty?
          Types::Span.new(array_element_type(callable))
        when :event_subscribe, :event_subscribe_once, :event_unsubscribe, :event_emit, :event_wait
          check_event_method_call(callable_kind, receiver, expression.arguments, scopes:)
        when :atomic_load, :atomic_store, :atomic_add, :atomic_sub, :atomic_exchange, :atomic_compare_exchange
          check_atomic_method_call(callable_kind, callable, receiver, expression.arguments, scopes:)
        when :struct
          check_aggregate_construction(callable, expression.arguments, scopes:)
        when :struct_with
          check_struct_with_call(callable, receiver, expression.arguments, scopes:)
        when :variant_arm_ctor
          check_variant_arm_construction(callable, expression.arguments, scopes:)
        when :array
          check_array_construction(callable, expression.arguments, scopes:)
        when :reinterpret
          check_reinterpret_call(callable, expression.arguments, scopes:)
        when :hash
          check_hash_call(callable, expression.arguments, scopes:)
        when :equal
          check_equal_call(callable, expression.arguments, scopes:)
        when :order
          check_order_call(callable, expression.arguments, scopes:)
        when :fatal
          check_fatal_call(expression.arguments, scopes:)
        when :ref_of
          check_ref_of_call(expression.arguments, scopes:)
        when :const_ptr_of
          check_const_ptr_of_call(expression.arguments, scopes:)
        when :read
          check_read_call(expression.arguments, scopes:)
        when :ptr_of
          check_ptr_of_call(expression.arguments, scopes:)
        when :field_of
          check_field_of_call(expression.arguments, scopes:)
        when :callable_of
          check_callable_of_call(expression.arguments, scopes:)
        when :attribute_of
          check_attribute_of_call(expression.arguments, scopes:)
        when :has_attribute
          check_has_attribute_call(expression.arguments, scopes:)
        when :get
          check_get_call(expression.arguments, scopes:)
        when :attribute_arg
          check_attribute_arg_call(callable, expression.arguments, scopes:)
        when :dyn_method
          check_dyn_method_call(callable, receiver, expression.arguments, scopes:)
          callable.return_type
        when :adapt
          check_adapt_call(callable, expression.arguments, scopes:)
        else
          raise_sema_error("#{describe_expression(expression.callee)} is not callable")
        end
      end

      def validate_consuming_foreign_expression!(expression, scopes:, root_allowed: false)
        return unless expression
        return if expression.is_a?(AST::ErrorExpr)

        if (foreign_call = resolve_foreign_call_expression(expression, scopes:)) && foreign_call_consumes_binding?(foreign_call[:binding])
          raise_sema_error("consuming foreign calls must be top-level expression statements") unless root_allowed
        end

        case expression
        when AST::Call, AST::Specialization
          validate_consuming_foreign_expression!(expression.callee, scopes:, root_allowed: false)
          expression.arguments.each do |argument|
            validate_consuming_foreign_expression!(argument.value, scopes:, root_allowed: false)
          end
        when AST::UnaryOp
          validate_consuming_foreign_expression!(expression.operand, scopes:, root_allowed: false)
        when AST::BinaryOp
          validate_consuming_foreign_expression!(expression.left, scopes:, root_allowed: false)
          validate_consuming_foreign_expression!(expression.right, scopes:, root_allowed: false)
        when AST::IfExpr
          validate_consuming_foreign_expression!(expression.condition, scopes:, root_allowed: false)
          validate_consuming_foreign_expression!(expression.then_expression, scopes:, root_allowed: false)
          validate_consuming_foreign_expression!(expression.else_expression, scopes:, root_allowed: false)
        when AST::MatchExpr
          validate_consuming_foreign_expression!(expression.expression, scopes:, root_allowed: false)
          expression.arms.each do |arm|
            validate_consuming_foreign_expression!(arm.pattern, scopes:, root_allowed: false)
            arm_scopes = arm.binding_name ? scopes + [{ arm.binding_name => value_binding(name: arm.binding_name, type: @error_type, mutable: false, kind: :local, id: @preassigned_local_binding_ids.fetch(arm.object_id)) }] : scopes
            validate_consuming_foreign_expression!(arm.value, scopes: arm_scopes, root_allowed: false)
          end
        when AST::UnsafeExpr
          validate_consuming_foreign_expression!(expression.expression, scopes:, root_allowed: false)
        when AST::FormatString
          expression.parts.each do |part|
            next unless part.is_a?(AST::FormatExprPart)

            validate_consuming_foreign_expression!(part.expression, scopes:, root_allowed: false)
          end
        when AST::MemberAccess
          validate_consuming_foreign_expression!(expression.receiver, scopes:, root_allowed: false)
        when AST::IndexAccess
          validate_consuming_foreign_expression!(expression.receiver, scopes:, root_allowed: false)
          validate_consuming_foreign_expression!(expression.index, scopes:, root_allowed: false)
        when AST::RangeExpr
          validate_consuming_foreign_expression!(expression.start_expr, scopes:, root_allowed: false)
          validate_consuming_foreign_expression!(expression.end_expr, scopes:, root_allowed: false)
        when AST::PrefixCast
          validate_consuming_foreign_expression!(expression.expression, scopes:, root_allowed: false)
        end
      end

      def validate_hoistable_foreign_expression!(expression, scopes:, root_hoistable: false)
        return unless expression
        return if expression.is_a?(AST::ErrorExpr)

        if (foreign_call = resolve_foreign_call_expression(expression, scopes:)) && (message = inline_foreign_call_requires_hoisting_message(foreign_call, scopes:))
          raise_sema_error(message) unless root_hoistable
        end

        case expression
        when AST::Call, AST::Specialization
          validate_hoistable_foreign_expression!(expression.callee, scopes:, root_hoistable: false)
          expression.arguments.each do |argument|
            validate_hoistable_foreign_expression!(argument.value, scopes:, root_hoistable: false)
          end
        when AST::UnaryOp
          validate_hoistable_foreign_expression!(expression.operand, scopes:, root_hoistable: false)
        when AST::BinaryOp
          validate_hoistable_foreign_expression!(expression.left, scopes:, root_hoistable: false)
          validate_hoistable_foreign_expression!(expression.right, scopes:, root_hoistable: false)
        when AST::IfExpr
          validate_hoistable_foreign_expression!(expression.condition, scopes:, root_hoistable: false)
          validate_hoistable_foreign_expression!(expression.then_expression, scopes:, root_hoistable: false)
          validate_hoistable_foreign_expression!(expression.else_expression, scopes:, root_hoistable: false)
        when AST::MatchExpr
          validate_hoistable_foreign_expression!(expression.expression, scopes:, root_hoistable: false)
          expression.arms.each do |arm|
            validate_hoistable_foreign_expression!(arm.pattern, scopes:, root_hoistable: false)
            arm_scopes = arm.binding_name ? scopes + [{ arm.binding_name => value_binding(name: arm.binding_name, type: @error_type, mutable: false, kind: :local, id: @preassigned_local_binding_ids.fetch(arm.object_id)) }] : scopes
            validate_hoistable_foreign_expression!(arm.value, scopes: arm_scopes, root_hoistable: false)
          end
        when AST::UnsafeExpr
          validate_hoistable_foreign_expression!(expression.expression, scopes:, root_hoistable: false)
        when AST::FormatString
          expression.parts.each do |part|
            next unless part.is_a?(AST::FormatExprPart)

            validate_hoistable_foreign_expression!(part.expression, scopes:, root_hoistable: false)
          end
        when AST::MemberAccess
          validate_hoistable_foreign_expression!(expression.receiver, scopes:, root_hoistable: false)
        when AST::IndexAccess
          validate_hoistable_foreign_expression!(expression.receiver, scopes:, root_hoistable: false)
          validate_hoistable_foreign_expression!(expression.index, scopes:, root_hoistable: false)
        when AST::RangeExpr
          validate_hoistable_foreign_expression!(expression.start_expr, scopes:, root_hoistable: false)
          validate_hoistable_foreign_expression!(expression.end_expr, scopes:, root_hoistable: false)
        when AST::PrefixCast
          validate_hoistable_foreign_expression!(expression.expression, scopes:, root_hoistable: false)
        end
      end

      def inline_foreign_call_requires_hoisting_message(foreign_call, scopes:)
        binding = foreign_call[:binding]
        call = foreign_call[:call]
        reference_counts = foreign_mapping_reference_counts(foreign_mapping_expression(binding.ast))

        binding.ast.params.each_with_index do |param_ast, index|
          public_alias = param_ast.boundary_type ? foreign_mapping_public_alias_name(param_ast.name) : nil
          total_references = reference_counts.fetch(param_ast.name, 0)
          total_references += reference_counts.fetch(public_alias, 0) if public_alias
          next if total_references <= 1 || simple_foreign_argument_expression?(call.arguments.fetch(index).value)

          return inline_foreign_hoisting_message(binding.name, param_ast.name, reason: "is referenced multiple times in its mapping")
        end

        binding.ast.params.each_with_index do |param_ast, index|
          parameter = binding.type.params.fetch(index)
          argument_expression = call.arguments.fetch(index).value
          next unless automatic_foreign_cstr_temp_needed?(parameter, argument_expression, scopes:) || automatic_foreign_cstr_list_temp_needed?(parameter)

          return inline_foreign_hoisting_message(binding.name, param_ast.name, reason: "needs temporary foreign text storage")
        end

        nil
      end

      def inline_foreign_hoisting_message(binding_name, parameter_name, reason:)
        "foreign call #{binding_name} cannot be used inline because #{parameter_name} #{reason}; use it as a statement, local initializer, assignment, or return expression"
      end

      def resolve_foreign_call_expression(expression, scopes:)
        call = expression
        return unless call.is_a?(AST::Call)

        callable_kind, callable, _receiver = resolve_callable(call.callee, scopes:)
        return unless callable_kind == :function

        callable = specialize_function_binding(
          callable,
          call.arguments,
          scopes:,
          receiver_type: callable_receiver_type_for_specialization(call.callee, scopes:),
        ) if callable.type_params.any?
        return unless foreign_function_binding?(callable)

        { call:, binding: callable }
      rescue SemaError
        nil
      end

      def foreign_call_consumes_binding?(binding)
        binding.type.params.any? { |parameter| parameter.passing_mode == :consuming }
      end

      def foreign_mapping_reference_counts(expression, counts = Hash.new(0))
        case expression
        when AST::Identifier
          counts[expression.name] += 1
        when AST::MemberAccess
          foreign_mapping_reference_counts(expression.receiver, counts)
        when AST::IndexAccess
          foreign_mapping_reference_counts(expression.receiver, counts)
          foreign_mapping_reference_counts(expression.index, counts)
        when AST::Specialization, AST::Call
          foreign_mapping_reference_counts(expression.callee, counts)
          expression.arguments.each { |argument| foreign_mapping_reference_counts(argument.value, counts) }
        when AST::UnaryOp
          foreign_mapping_reference_counts(expression.operand, counts)
        when AST::BinaryOp
          foreign_mapping_reference_counts(expression.left, counts)
          foreign_mapping_reference_counts(expression.right, counts)
        when AST::IfExpr
          foreign_mapping_reference_counts(expression.condition, counts)
          foreign_mapping_reference_counts(expression.then_expression, counts)
          foreign_mapping_reference_counts(expression.else_expression, counts)
        when AST::UnsafeExpr
          foreign_mapping_reference_counts(expression.expression, counts)
        when AST::PrefixCast
          foreign_mapping_reference_counts(expression.expression, counts)
        end

        counts
      end

      def simple_foreign_argument_expression?(expression)
        case expression
        when AST::Identifier, AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral, AST::BooleanLiteral, AST::NullLiteral
          true
        when AST::MemberAccess
          simple_foreign_argument_expression?(expression.receiver)
        else
          false
        end
      end

      def automatic_foreign_cstr_list_temp_needed?(parameter)
        return false unless parameter.type.is_a?(Types::Span) && parameter.type.element_type == @ctx.types.fetch("str")
        return false unless parameter.boundary_type.is_a?(Types::Span)

        boundary_element_type = parameter.boundary_type.element_type
        boundary_element_type == @ctx.types.fetch("cstr") || char_pointer_type?(boundary_element_type)
      end

      def automatic_foreign_cstr_temp_needed?(parameter, expression, scopes:)
        return false unless parameter.boundary_type == @ctx.types.fetch("cstr") && parameter.type == @ctx.types.fetch("str")
        return false if expression.is_a?(AST::StringLiteral) && !expression.cstring

        infer_expression(expression, scopes:) != @ctx.types.fetch("cstr")
      end

      def consuming_foreign_call_refinements(expression, scopes:)
        foreign_call = resolve_foreign_call_expression(expression, scopes:)
        return {} unless foreign_call

        binding = foreign_call[:binding]
        return {} unless foreign_call_consumes_binding?(binding)

        binding.type.params.each_with_index.each_with_object({}) do |(parameter, index), refinements|
          next unless parameter.passing_mode == :consuming

          argument = foreign_call[:call].arguments.fetch(index)
          argument_binding = foreign_consuming_argument_binding(parameter, argument, scopes:, function_name: binding.name)
          refinements[argument.value.name] = @null_type if argument_binding.storage_type.is_a?(Types::Nullable)
        end
      end

      def resolve_callable(callee, scopes:)
        case callee
        when AST::Identifier
          if (binding = lookup_value(callee.name, scopes))
            return [:callable_value, binding.type, nil] if callable_type?(binding.type)

            raise_sema_error("#{callee.name} is not callable")
          end

          return [:function, @ctx.top_level_functions.fetch(callee.name), nil] if @ctx.top_level_functions.key?(callee.name)
          return [:fatal, nil, nil] if callee.name == "fatal"
          return [:ref_of, nil, nil] if callee.name == "ref_of"
          return [:const_ptr_of, nil, nil] if callee.name == "const_ptr_of"
          return [:read, nil, nil] if callee.name == "read"
          return [:ptr_of, nil, nil] if callee.name == "ptr_of"
          return [:field_of, nil, nil] if callee.name == "field_of"
          return [:callable_of, nil, nil] if callee.name == "callable_of"
          return [:attribute_of, nil, nil] if callee.name == "attribute_of"
          return [:has_attribute, nil, nil] if callee.name == "has_attribute"
          return [:get, nil, nil] if callee.name == "get"

          type = @ctx.types[callee.name]
          return [:struct, type, nil] if type.is_a?(Types::Struct) || type.is_a?(Types::StringView) || task_type?(type) || type.is_a?(Types::Vector) || type.is_a?(Types::Matrix) || type.is_a?(Types::Quaternion)
          if type.is_a?(Types::GenericStructDefinition) || type.is_a?(Types::GenericVariantDefinition)
            raise_sema_error("generic type #{callee.name} requires type arguments")
          end

          raise_sema_error("unknown callable #{callee.name}")
        when AST::MemberAccess
          if callee.receiver.is_a?(AST::Identifier) && @ctx.imports.key?(callee.receiver.name)
            imported_module = @ctx.imports.fetch(callee.receiver.name)
            return [:function, imported_module.functions.fetch(callee.member), nil] if imported_module.functions.key?(callee.member)
            imported_type = imported_module.types[callee.member]
            if imported_type.is_a?(Types::Struct) || imported_type.is_a?(Types::GenericStructDefinition) || imported_type.is_a?(Types::StringView) || task_type?(imported_type) || imported_type.is_a?(Types::Vector) || imported_type.is_a?(Types::Matrix) || imported_type.is_a?(Types::Quaternion)
              return [:struct, imported_module.types.fetch(callee.member), nil]
            end

            if imported_type.is_a?(Types::Variant)
              arm_name = callee.member
              unless imported_type.arm_names.include?(arm_name)
                raise_sema_error("unknown arm #{arm_name} for variant #{imported_type}")
              end

              return [:variant_arm_ctor, [imported_type, arm_name], nil]
            end

            if imported_module.private_function?(callee.member) || imported_module.private_type?(callee.member) || imported_module.private_value?(callee.member)
              raise_sema_error("#{callee.receiver.name}.#{callee.member} is private to module #{imported_module.name}")
            end

            raise_sema_error("unknown callable #{callee.receiver.name}.#{callee.member}") unless @ctx.types.key?(callee.receiver.name)
          end

          if (type_expr = resolve_type_expression(callee.receiver))
            if type_expr.is_a?(Types::Variant)
              arm_name = callee.member
              unless type_expr.arm_names.include?(arm_name)
                raise_sema_error("unknown arm #{arm_name} for variant #{type_expr}")
              end

              return [:variant_arm_ctor, [type_expr, arm_name], nil]
            end

            if type_expr.respond_to?(:nested_types) && type_expr.nested_types.key?(callee.member)
              return [:struct, type_expr.nested_types[callee.member], nil]
            end

            method = lookup_method(type_expr, callee.member)
            method ||= lookup_static_method(type_expr, callee.member)
            return [:function, method, nil] if method && method.type.receiver_type.nil?

            raise_sema_error("unknown associated function #{type_expr}.#{callee.member}")
          end

          method_receiver_type = infer_method_receiver_type(callee.receiver, scopes:, member_name: callee.member)

          if dyn_type?(method_receiver_type)
            interface = method_receiver_type.interface_binding
            method_binding = interface.methods[callee.member]
            raise_sema_error("no method '#{callee.member}' on interface #{interface.name}") unless method_binding
            raise_sema_error("cannot call static method '#{callee.member}' on dyn value") if method_binding.kind == :static
            return [:dyn_method, method_binding, callee.receiver]
          end

          method = lookup_method(method_receiver_type, callee.member)
          return [:method, method, callee.receiver] if method

          if callee.member == "with" && struct_with_target_type?(method_receiver_type)
            return [:struct_with, method_receiver_type, callee.receiver]
          end

          if char_array_removed_text_method?(method_receiver_type, callee.member)
            raise_sema_error("#{method_receiver_type}.#{callee.member} is not available; array[char, N] is raw storage, use str_buffer[N] or an explicit helper")
          end

          if (str_buffer_method = str_buffer_method_kind(method_receiver_type, callee.member))
            return [str_buffer_method, method_receiver_type, callee.receiver]
          end

          if (event_method = event_method_kind(method_receiver_type, callee.member))
            return [event_method, method_receiver_type, callee.receiver]
          end

          if (atomic_method = atomic_method_kind(method_receiver_type, callee.member))
            return [atomic_method, method_receiver_type, callee.receiver]
          end

          field_receiver_type = infer_field_receiver_type(callee.receiver, scopes:)
          if array_type?(field_receiver_type) && callee.member == "as_span"
            return [:array_as_span, field_receiver_type, callee.receiver]
          end

          return [:callable_value, field_receiver_type.field(callee.member), nil] if aggregate_type?(field_receiver_type) && callable_type?(field_receiver_type.field(callee.member))
          return [:callable_value, field_receiver_type.field(callee.member), nil] if aggregate_type?(field_receiver_type) && callable_type?(field_receiver_type.field(callee.member))

          if (imported_module = imported_module_with_private_method(method_receiver_type, callee.member))
            raise_sema_error("#{method_receiver_type}.#{callee.member} is private to module #{imported_module.name}")
          end

          raise_sema_error("unknown method #{method_receiver_type}.#{callee.member}")
        when AST::Specialization
          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "reinterpret"
            raise_sema_error("reinterpret requires exactly one type argument") unless callee.arguments.length == 1

            type_arg = callee.arguments.first.value
            raise_sema_error("reinterpret type argument must be a type") unless type_arg.is_a?(AST::TypeRef)

            return [:reinterpret, resolve_type_ref(type_arg), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "array"
            raise_sema_error("array requires exactly two type arguments") unless callee.arguments.length == 2

            array_type = resolve_type_ref(AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["array"]), arguments: callee.arguments, nullable: false))
            raise_sema_error("array specialization must be array[T, N]") unless array_type?(array_type)

            return [:array, array_type, nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "span"
            raise_sema_error("span requires exactly one type argument") unless callee.arguments.length == 1

            span_type = resolve_type_ref(AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["span"]), arguments: callee.arguments, nullable: false))
            raise_sema_error("span specialization must be span[T]") unless span_type?(span_type)

            return [:struct, span_type, nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "zero"
            raise_sema_error("zero requires exactly one type argument") unless callee.arguments.length == 1

            type_arg = callee.arguments.first.value
            raise_sema_error("zero type argument must be a type") unless type_arg.is_a?(AST::TypeRef)

            return [:zero, resolve_type_ref(type_arg), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "default"
            return [:default, resolve_default_specialization(callee), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "hash"
            return [:hash, resolve_hash_specialization(callee), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "equal"
            return [:equal, resolve_equal_specialization(callee), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "order"
            return [:order, resolve_order_specialization(callee), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "attribute_arg"
            raise_sema_error("attribute_arg requires exactly one type argument") unless callee.arguments.length == 1

            type_arg = callee.arguments.first.value
            raise_sema_error("attribute_arg type argument must be a type") unless type_arg.is_a?(AST::TypeRef)

            return [:attribute_arg, resolve_type_ref(type_arg), nil]
          end

          if callee.callee.is_a?(AST::Identifier) && callee.callee.name == "adapt"
            raise_sema_error("adapt requires exactly one type argument") unless callee.arguments.length == 1

            type_arg = callee.arguments.first.value
            raise_sema_error("adapt type argument must be a type") unless type_arg.is_a?(AST::TypeRef)

            interface = resolve_adapt_interface(type_arg)
            return [:adapt, interface, nil]
          end

          if (callable_resolution = resolve_specialized_callable_binding(callee, scopes:))
            return callable_resolution
          end

          if (type_ref = type_ref_from_specialization(callee))
            specialized_type = resolve_type_ref(type_ref)
            return [:struct, specialized_type, nil] if specialized_type.is_a?(Types::Struct) || task_type?(specialized_type) || specialized_type.is_a?(Types::Vector) || specialized_type.is_a?(Types::Matrix) || specialized_type.is_a?(Types::Quaternion)
          end

          raise_sema_error("unsupported callable specialization #{describe_expression(callee)}")
        else
          callee_type = infer_expression(callee, scopes:)
          return [:callable_value, callee_type, nil] if callable_type?(callee_type)

          raise_sema_error("unsupported callee #{describe_expression(callee)}")
        end
      end


      def record_editable_receiver_expression(receiver)
        return unless receiver

        @editable_receiver_expression_ids[receiver.object_id] = true
      end

      def record_mutable_lvalue_argument_identifier(expression)
        return unless expression.is_a?(AST::Identifier)

        @mutable_lvalue_argument_identifier_ids[expression.object_id] = true
      end

      def check_format_string_literal(format_string, scopes:)
        format_string.parts.each do |part|
          next unless part.is_a?(AST::FormatExprPart)

          value_type = infer_expression(part.expression, scopes:)

          if part.format_spec
            case part.format_spec[:kind]
            when :precision
              unless value_type.is_a?(Types::Primitive) && value_type.float?
                raise_sema_error("format spec ':.N' is only valid for float and double, got #{value_type}")
              end
            when :hex
              unless format_string_integer_base_spec_supported?(value_type)
                raise_sema_error("format spec ':x' and ':X' are only valid for integer primitives and integer-backed enums/flags, got #{value_type}")
              end
            when :oct
              unless format_string_integer_base_spec_supported?(value_type)
                raise_sema_error("format spec ':o' and ':O' are only valid for integer primitives and integer-backed enums/flags, got #{value_type}")
              end
            when :bin
              unless format_string_integer_base_spec_supported?(value_type)
                raise_sema_error("format spec ':b' and ':B' are only valid for integer primitives and integer-backed enums/flags, got #{value_type}")
              end
            else
              raise_sema_error("unsupported format spec #{part.format_spec.inspect}")
            end
          else
            next if format_string_interpolation_supported?(value_type, context: "formatted string interpolation of #{value_type}")
            raise_sema_error("formatted string interpolation supports str, cstr, bool, numeric primitives, integer-backed enums/flags, and types implementing format_len()/append_format(output: ref[std.string.String]), got #{value_type}")
          end
        end
      end

      def format_string_integer_base_spec_supported?(type)
        resolved = type.is_a?(Types::EnumBase) ? type.backing_type : type
        resolved.is_a?(Types::Primitive) && resolved.integer?
      end

      def format_string_interpolation_supported?(type, context:)
        return true if type == @ctx.types.fetch("str")
        return true if type == @ctx.types.fetch("cstr")
        return true if type == @ctx.types.fetch("bool")
        return true if type.is_a?(Types::Primitive) && type.integer?
        return true if type.is_a?(Types::Primitive) && type.float?
        return true if type.is_a?(Types::EnumBase) && type.backing_type.is_a?(Types::Primitive) && type.backing_type.integer?
        return true if resolve_explicit_format_binding(type, context:)

        false
      end








      def evaluate_field_of_call(arguments, scopes:)
        raise_sema_error("field_of does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("field_of expects 2 arguments, got #{arguments.length}") unless arguments.length == 2

        struct_handle = resolve_struct_handle_argument(arguments.first.value, scopes:)
        field_name = reflection_identifier_name(arguments[1].value, context: "field_of")
        field_handle = CompileTime::Reflection.core_field_handle(struct_handle, field_name)
        raise_sema_error("unknown field #{struct_handle.struct_type}.#{field_name}") unless field_handle

        field_handle
      end


      def evaluate_callable_of_call(arguments, scopes:)
        raise_sema_error("callable_of does not support named arguments") if arguments.any?(&:name)
        raise_sema_error("callable_of expects 1 argument, got #{arguments.length}") unless arguments.length == 1

        resolve_callable_handle_argument(arguments.first.value, scopes:)
      end




      def resolve_struct_handle_argument(expression, scopes:)
        if (type_expr = resolve_type_expression(expression))
          handle = struct_handle_for_type(type_expr)
          return handle if handle
        end

        raise_sema_error("field_of expects a struct type expression")
      end

      def resolve_reflection_target_argument(expression, scopes:)
        if (type_expr = resolve_type_expression(expression))
          handle = struct_handle_for_type(type_expr)
          return handle if handle
        end

        handle = evaluate_compile_time_const_value(expression, scopes:)
        return handle if handle.is_a?(Types::FieldHandle) || handle.is_a?(Types::CallableHandle)

        raise_sema_error("attribute reflection expects a struct type, field handle, or callable handle")
      end

      def resolve_callable_handle_argument(expression, scopes:)
        callable_kind, callable, _receiver = resolve_callable(expression, scopes:)
        raise_sema_error("callable_of expects a callable declaration name") unless callable_kind == :function

        Types::CallableHandle.new(describe_expression(expression), callable.ast)
      end

      def resolve_attribute_name_argument(expression)
        case expression
        when AST::Identifier
          resolve_attribute_binding(AST::QualifiedName.new(parts: [expression.name]))
        when AST::MemberAccess
          raise_sema_error("attribute name must use a module qualifier") unless expression.receiver.is_a?(AST::Identifier)

          resolve_attribute_binding(AST::QualifiedName.new(parts: [expression.receiver.name, expression.member]))
        else
          raise_sema_error("attribute name must be an identifier or module-qualified attribute name")
        end
      end

      def reflection_identifier_name(expression, context:)
        raise_sema_error("#{context} expects an identifier argument") unless expression.is_a?(AST::Identifier)

        expression.name
      end

      def struct_handle_for_type(type)
        base_type = type.is_a?(Types::StructInstance) ? type.definition : type
        return nil unless base_type.is_a?(Types::Struct) || base_type.is_a?(Types::GenericStructDefinition)

        declaration = struct_declaration_for_type(base_type)
        return nil unless declaration

        Types::StructHandle.new(base_type, declaration)
      end

      def struct_declaration_for_type(type)
        return type.ast_declaration if type.respond_to?(:ast_declaration) && type.ast_declaration

        return nil unless type.respond_to?(:module_name)
        if type.module_name == @ctx.module_name
          return @ctx.ast.declarations.find do |decl|
            decl.is_a?(AST::StructDecl) && decl.name == type.name
          end
        end

        imported_module = imported_module_binding_for_name(type.module_name)
        return nil unless imported_module

        declaration = imported_module.type_declarations[type.name]
        declaration if declaration.is_a?(AST::StructDecl)
      end

      def imported_module_binding_for_name(module_name)
        @ctx.imports.each_value.find { |binding| binding.name == module_name }
      end

      def validate_attribute_target_compatibility!(target, binding)
        target_kind = attribute_target_kind(target)
        raise_sema_error("attribute #{qualified_attribute_name(binding)} cannot target #{target_kind}") unless binding.targets.include?(target_kind)
      end

      def attribute_target_kind(target)
        case target
        when Types::StructHandle then :struct
        when Types::FieldHandle then :field
        when Types::CallableHandle then :callable
        else
          raise_sema_error("unsupported attribute reflection target #{target}")
        end
      end

      def infer_field_handle_member(expression, scopes:)
        case expression.member
        when "name"
          @ctx.types.fetch("str")
        when "type"
          handle = evaluate_compile_time_const_value(expression.receiver, scopes:)
          return @error_type unless handle.is_a?(Types::FieldHandle)

          resolve_type_ref(handle.field_declaration.type)
        else
          raise_sema_error("unknown member #{expression.member} of field_handle")
        end
      end

      def infer_member_handle_member(expression)
        case expression.member
        when "name"
          @ctx.types.fetch("str")
        when "value"
          @ctx.types.fetch("int")
        else
          raise_sema_error("unknown member #{expression.member} of member_handle")
        end
      end
    end
  end
end
