# frozen_string_literal: true

module MilkTea
  class Sema
    class Checker
      private

      def call_argument_compatible?(actual_type, expected_type, scopes:, external:, expression: nil)
        return true if array_to_span_call_argument_compatible?(actual_type, expected_type, expression:, scopes:)
        return true if argument_types_compatible?(actual_type, expected_type, external:, expression:, scopes:, contextual_int_to_float: !external)
        return true if implicit_ref_argument_compatible?(actual_type, expected_type, expression, scopes)
        return true if direct_task_to_proc_argument_compatible?(actual_type, expected_type)
        return true if direct_function_to_proc_argument_compatible?(actual_type, expected_type, expression, scopes)

        false
      end

      def implicit_ref_argument_compatible?(actual_type, expected_type, expression, scopes)
        return false unless expression && scopes
        return false unless ref_type?(expected_type)
        return false unless actual_type == referenced_type(expected_type)
        return false unless safe_reference_source_expression?(expression, scopes:)

        infer_lvalue(expression, scopes:)
        true
      rescue SemaError
        false
      end

      def types_compatible?(actual_type, expected_type, expression: nil, scopes: nil, external_numeric: false, external_pointer_null: false, contextual_int_to_float: false)
        return true if error_type?(actual_type) || error_type?(expected_type)
        return true if actual_type == expected_type
        return true if ref_types_compatible?(actual_type, expected_type)
        return true if null_assignable_to?(actual_type, expected_type)
        return true if external_pointer_null && external_typed_null_pointer_compatibility?(actual_type, expected_type)
        return true if expected_type.is_a?(Types::Nullable) && actual_type == expected_type.base
        return true if mutable_to_const_pointer_compatibility?(actual_type, expected_type)
        return true if string_literal_cstr_compatibility?(expression, expected_type)
        return true if exact_compile_time_numeric_compatibility?(actual_type, expression, expected_type, scopes:)
        return true if integer_to_char_compatibility?(actual_type, expected_type) &&
                       (!expression || !scopes || integer_constant_fits_in_char?(expression, scopes))
        return true if external_numeric && external_numeric_compatibility?(actual_type, expected_type)
        return true if contextual_int_to_float && contextual_int_to_float_compatibility?(actual_type, expected_type) &&
                       (!expression || !scopes || contextual_int_to_float_fits?(expression, expected_type, scopes))
        return true if same_external_opaque_handle_pointer_compatibility?(actual_type, expected_type)
        return true if actual_type.is_a?(Types::Function) && expected_type.is_a?(Types::Function) &&
                       !actual_type.receiver_type && !actual_type.variadic &&
                       function_type_matches_proc_type?(actual_type, expected_type)
        return true if quat_vec4_compatible?(actual_type, expected_type)

        false
      end

      def ref_types_compatible?(actual_type, expected_type)
        return false unless ref_type?(actual_type) && ref_type?(expected_type)

        referenced_type(actual_type) == referenced_type(expected_type)
      end

      def quat_vec4_compatible?(a, b)
        (a.is_a?(Types::Quaternion) && b.is_a?(Types::Vector) && b.width == 4 && b.element_type.name == "float") ||
          (b.is_a?(Types::Quaternion) && a.is_a?(Types::Vector) && a.width == 4 && a.element_type.name == "float")
      end

      def argument_types_compatible?(actual_type, expected_type, external:, expression: nil, scopes: nil, contextual_int_to_float: false)
        return true if types_compatible?(actual_type, expected_type, expression:, scopes:, external_numeric: external, contextual_int_to_float:)
        return true if external && external_void_pointer_argument_compatibility?(actual_type, expected_type)
        return true if external && extern_enum_integer_argument_compatibility?(actual_type, expected_type)
        if external && foreign_mapping_context? && foreign_identity_projection_compatible?(actual_type, expected_type)
          return false if actual_type == @ctx.types.fetch("cstr") && char_pointer_type?(expected_type)

          return true
        end

        false
      end

      def direct_function_to_proc_argument_compatible?(actual_type, expected_type, expression, scopes)
        return false unless expression
        return false unless actual_type.is_a?(Types::Function) && proc_type?(expected_type)
        return false unless direct_function_identity_expression?(expression, scopes)

        function_type_matches_proc_type?(actual_type, expected_type)
      end

      def direct_task_to_proc_argument_compatible?(actual_type, expected_type)
        return false unless actual_type.is_a?(Types::Task)
        return false unless task_root_proc_type?(expected_type)

        actual_type == expected_type.return_type
      end

      def direct_function_identity_expression?(expression, scopes)
        case expression
        when AST::Identifier
          return false if lookup_value(expression.name, scopes)
          return false unless @ctx.top_level_functions.key?(expression.name)

          binding = @ctx.top_level_functions.fetch(expression.name)
          !binding.type_params.any? && !foreign_function_binding?(binding)
        when AST::MemberAccess
          return false unless expression.receiver.is_a?(AST::Identifier) && @ctx.imports.key?(expression.receiver.name)

          imported_module = @ctx.imports.fetch(expression.receiver.name)
          return false unless imported_module.functions.key?(expression.member)

          binding = imported_module.functions.fetch(expression.member)
          !binding.type_params.any? && !foreign_function_binding?(binding)
        when AST::Specialization
          binding = resolve_specialized_function_binding(expression)
          binding && !foreign_function_binding?(binding)
        else
          false
        end
      end

      def external_void_pointer_argument_compatibility?(actual_type, expected_type)
        if actual_type.is_a?(Types::Nullable) && expected_type.is_a?(Types::Nullable)
          return external_void_pointer_argument_compatibility?(actual_type.base, expected_type.base)
        end

        return external_void_pointer_argument_compatibility?(actual_type, expected_type.base) if expected_type.is_a?(Types::Nullable)
        return false if actual_type.is_a?(Types::Nullable)
        return false unless pointer_type?(actual_type) && pointer_type?(expected_type)
        return false if const_pointer_type?(actual_type) && mutable_pointer_type?(expected_type)

        actual_pointee = pointee_type(actual_type)
        expected_pointee = pointee_type(expected_type)

        actual_pointee == @ctx.types.fetch("void") || expected_pointee == @ctx.types.fetch("void")
      end

      def exact_compile_time_numeric_compatibility?(actual_type, expression, expected_type, scopes: nil)
        return false unless expected_type.is_a?(Types::Primitive) && expected_type.numeric?
        return false if actual_type.is_a?(Types::EnumBase)

        value = evaluate_compile_time_const_value(expression, scopes:)
        return false unless value.is_a?(Numeric)

        numeric_constant_fits_type?(value, expected_type)
      end

      def integer_constant_fits_in_char?(expression, scopes)
        value = evaluate_compile_time_const_value(expression, scopes:)
        return true unless value.is_a?(Integer)

        value >= 0 && value <= 255
      end

      def contextual_int_to_float_fits?(expression, expected_type, scopes)
        value = evaluate_compile_time_const_value(expression, scopes:)
        return true unless value.is_a?(Numeric)

        float_constant_fits_type?(value, expected_type)
      end

      def extern_enum_integer_argument_compatibility?(actual_type, expected_type)
        return unless actual_type.is_a?(Types::EnumBase)
        return unless expected_type.is_a?(Types::Primitive) && expected_type.integer? && expected_type.fixed_width_integer?

        backing_type = actual_type.backing_type
        return unless backing_type.is_a?(Types::Primitive) && backing_type.integer? && backing_type.fixed_width_integer?

        backing_type.integer_width == expected_type.integer_width
      end

      def common_numeric_type(left_type, right_type)
        left_type = left_type.backing_type if left_type.is_a?(Types::EnumBase)
        right_type = right_type.backing_type if right_type.is_a?(Types::EnumBase)
        return unless left_type.is_a?(Types::Primitive) && right_type.is_a?(Types::Primitive)
        return unless left_type.numeric? && right_type.numeric?
        return left_type if left_type == right_type

        return common_integer_type(left_type, right_type) if left_type.integer? && right_type.integer?
        return wider_float_type(left_type, right_type) if left_type.float? && right_type.float?

        float_type, integer_type = left_type.float? ? [left_type, right_type] : [right_type, left_type]
        return unless integer_type.integer? && integer_type.fixed_width_integer?

        float_type
      end

      def common_integer_type(left_type, right_type)
        left_type = left_type.backing_type if left_type.is_a?(Types::EnumBase)
        right_type = right_type.backing_type if right_type.is_a?(Types::EnumBase)
        return unless left_type.is_a?(Types::Primitive) && right_type.is_a?(Types::Primitive)
        return unless left_type.integer? && right_type.integer?
        return left_type if left_type == right_type
        return unless left_type.fixed_width_integer? && right_type.fixed_width_integer?
        return unless left_type.signed_integer? == right_type.signed_integer?

        left_type.integer_width >= right_type.integer_width ? left_type : right_type
      end

      def wider_float_type(left_type, right_type)
        left_type.float_width >= right_type.float_width ? left_type : right_type
      end

      def pointer_arithmetic_result(operator, left_type, right_type)
        if pointer_type?(left_type) && integer_type?(right_type)
          require_unsafe!("pointer arithmetic requires unsafe")

          return left_type if operator == "+" || operator == "-"
        end

        if operator == "+" && integer_type?(left_type) && pointer_type?(right_type)
          require_unsafe!("pointer arithmetic requires unsafe")

          return right_type
        end

        nil
      end

      def vector_arithmetic_result(operator, left_type, right_type)
        return vector_op_result(operator, left_type, right_type) if vector_type?(left_type) || vector_type?(right_type)
        return matrix_op_result(operator, left_type, right_type) if matrix_type?(left_type) || matrix_type?(right_type)
        return quaternion_op_result(operator, left_type, right_type) if quaternion_type?(left_type) || quaternion_type?(right_type)

        nil
      end

    private

      def vector_op_result(operator, left_type, right_type)
        if vector_type?(left_type) && vector_type?(right_type) && left_type.element_type == right_type.element_type
          return left_type if operator == "+" || operator == "-"
          return left_type if operator == "*"
        end

        if vector_type?(left_type) && right_type.numeric?
          return left_type if operator == "*" || operator == "/"
        end

        if left_type.numeric? && vector_type?(right_type) && operator == "*"
          return right_type
        end

        nil
      end

      def matrix_op_result(operator, left_type, right_type)
        if matrix_type?(left_type) && matrix_type?(right_type) && left_type.dim == right_type.dim
          return left_type if operator == "+" || operator == "-"
          return left_type if operator == "*"
        end

        if matrix_type?(left_type) && vector_type?(right_type) && left_type.dim == right_type.width && right_type.element_type == Types::BUILTIN_VECTOR_ELEMENT
          return Types::Vector.new(right_type.name, element_type: right_type.element_type, width: right_type.width) if operator == "*"
        end

        if matrix_type?(left_type) && right_type.numeric?
          return left_type if operator == "*" || operator == "/"
        end

        nil
      end

      def quaternion_op_result(operator, left_type, right_type)
        if quaternion_type?(left_type) && quaternion_type?(right_type)
          return left_type if operator == "+" || operator == "-"
          return left_type if operator == "*"
        end

        if quaternion_type?(left_type) && vector_type?(right_type) && right_type.width == 3 && right_type.element_type == Types::BUILTIN_VECTOR_ELEMENT
          return right_type if operator == "*"
        end

        nil
      end

      def pointer_cast?(source_type, target_type)
        pointer_cast_type?(source_type) && pointer_cast_type?(target_type)
      end

      def ref_to_pointer_cast?(source_type, target_type)
        ref_type?(source_type) && pointer_cast_type?(target_type)
      end

      def pointer_cast_type?(type)
        return typed_null_target_type?(type.target_type) if type.is_a?(Types::Null)
        return true if type == @ctx.types.fetch("cstr")
        if type.is_a?(Types::Nullable)
          return true if function_pointer_type?(type.base)

          return pointer_type?(type.base)
        end

        return true if function_pointer_type?(type)

        pointer_type?(type)
      end

      def typed_null_target_type?(type)
        type == @ctx.types.fetch("cstr") || pointer_type?(type) || function_pointer_type?(type)
      end

      def function_pointer_type?(type)
        type.is_a?(Types::Function)
      end


    end
  end
end
