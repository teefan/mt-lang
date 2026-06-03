# frozen_string_literal: true

module MilkTea
  # Pure type-compatibility predicates shared by sema and lowering.
  module TypeCompatibilityPredicates
    private

    def string_literal_cstr_compatibility?(expression, expected_type)
      expression.is_a?(AST::StringLiteral) && !expression.cstring && expected_type == @types.fetch("cstr")
    end

    def task_root_proc_type?(type)
      proc_type?(type) && type.params.empty? && type.return_type.is_a?(Types::Task)
    end

    def function_type_matches_proc_type?(function_type, proc_type)
      return false if function_type.receiver_type || function_type.variadic
      return false unless function_type.params.length == proc_type.params.length
      return false unless function_type.return_type == proc_type.return_type

      function_type.params.zip(proc_type.params).all? do |function_param, proc_param|
        next false unless function_param.mutable == proc_param.mutable

        function_param.type == proc_param.type ||
          same_external_opaque_handle_pointer_compatibility?(function_param.type, proc_param.type)
      end
    end

    def null_assignable_to?(actual_type, expected_type)
      return false unless actual_type.is_a?(Types::Null)
      return false unless expected_type.is_a?(Types::Nullable)
      return true unless actual_type.target_type

      actual_type.target_type == expected_type.base
    end

    def external_typed_null_pointer_compatibility?(actual_type, expected_type)
      return false unless actual_type.is_a?(Types::Null)
      return false unless actual_type.target_type
      return false if expected_type.is_a?(Types::Nullable)
      return true if expected_type == @types.fetch("cstr") && char_pointer_type?(actual_type.target_type)
      return false unless pointer_type?(expected_type)

      actual_type.target_type == expected_type
    end

    def numeric_constant_fits_type?(value, expected_type)
      if expected_type.integer?
        integer_constant_fits_type?(value, expected_type)
      else
        float_constant_fits_type?(value, expected_type)
      end
    end

    def integer_constant_fits_type?(value, expected_type)
      integer_value = exact_integer_constant_value(value)
      return false if integer_value.nil?

      value_fits_integer_type?(integer_value, expected_type)
    end

    def float_constant_fits_type?(value, expected_type)
      return false unless value.is_a?(Numeric)

      float_value = value.to_f
      return false unless float_value.finite?
      return true if expected_type.name == "double"

      exactly_representable_float32?(float_value)
    end

    def exact_integer_constant_value(value)
      return value if value.is_a?(Integer)
      return nil unless value.is_a?(Float) && value.finite?

      integer_value = value.to_i
      integer_value.to_f == value ? integer_value : nil
    end

    def value_fits_integer_type?(value, expected_type)
      return false unless expected_type.is_a?(Types::Primitive) && expected_type.integer?

      width = expected_type.integer_width
      return false if width.nil?

      min_value, max_value = if expected_type.signed_integer?
                               [-(1 << (width - 1)), (1 << (width - 1)) - 1]
                             else
                               [0, (1 << width) - 1]
                             end

      value >= min_value && value <= max_value
    end

    def exactly_representable_float32?(value)
      [value].pack("f").unpack1("f") == value
    end

    def integer_to_char_compatibility?(actual_type, expected_type)
      char_type?(expected_type) && integer_like_char_source_type?(actual_type)
    end

    def integer_like_char_source_type?(type)
      return true if type.is_a?(Types::Primitive) && type.integer?
      return true if type.is_a?(Types::EnumBase) && type.backing_type.is_a?(Types::Primitive) && type.backing_type.integer?

      false
    end

    def char_type?(type)
      type.is_a?(Types::Primitive) && type.name == "char"
    end

    def external_numeric_compatibility?(actual_type, expected_type)
      return false unless actual_type.is_a?(Types::Primitive) && expected_type.is_a?(Types::Primitive)
      return false unless actual_type.numeric? && expected_type.numeric?

      return lossless_external_integer_compatibility?(actual_type, expected_type) if actual_type.integer? && expected_type.integer?
      return expected_type.float_width >= actual_type.float_width if actual_type.float? && expected_type.float?

      false
    end

    def lossless_external_integer_compatibility?(actual_type, expected_type)
      return false unless actual_type.fixed_width_integer? && expected_type.fixed_width_integer?

      if actual_type.signed_integer? == expected_type.signed_integer?
        return expected_type.integer_width >= actual_type.integer_width
      end

      return false if actual_type.signed_integer?

      expected_type.signed_integer? && expected_type.integer_width > actual_type.integer_width
    end

    def contextual_int_to_float_compatibility?(actual_type, expected_type)
      actual_type.is_a?(Types::Primitive) && actual_type.integer? &&
        expected_type.is_a?(Types::Primitive) && expected_type.float?
    end

    def contextual_int_to_float_target?(type)
      type.is_a?(Types::Primitive) && type.float?
    end

    def mutable_to_const_pointer_compatibility?(actual_type, expected_type)
      return mutable_to_const_pointer_compatibility?(actual_type, expected_type.base) if expected_type.is_a?(Types::Nullable)
      return false if actual_type.is_a?(Types::Nullable)
      return false unless mutable_pointer_type?(actual_type) && const_pointer_type?(expected_type)

      pointee_type(actual_type) == pointee_type(expected_type)
    end

    def foreign_span_boundary_compatible?(public_type, boundary_type)
      return false unless public_type.is_a?(Types::Span) && boundary_type.is_a?(Types::Span)

      foreign_boundary_element_compatible?(public_type.element_type, boundary_type.element_type)
    end

    def foreign_char_pointer_buffer_boundary_compatible?(public_type, boundary_type)
      return false unless char_pointer_type?(boundary_type)

      return true if public_type.is_a?(Types::Span) && public_type.element_type == @types.fetch("char")
      return true if char_array_text_type?(public_type)
      return true if str_buffer_type?(public_type)

      false
    end

    def foreign_boundary_element_compatible?(public_type, boundary_type)
      return true if public_type == boundary_type
      return true if public_type == @types.fetch("str") && boundary_type == @types.fetch("cstr")
      return true if public_type == @types.fetch("str") && char_pointer_type?(boundary_type)

      foreign_identity_projection_compatible?(public_type, boundary_type)
    end

    def foreign_identity_projection_compatible?(actual_type, expected_type)
      foreign_identity_projection_cast_compatible?(actual_type, expected_type) ||
        foreign_identity_projection_reinterpret_compatible?(actual_type, expected_type)
    end

    def foreign_identity_projection_cast_compatible?(actual_type, expected_type)
      return true if actual_type == expected_type
      return true if mutable_to_const_pointer_compatibility?(actual_type, expected_type)
      return true if same_external_opaque_c_name?(actual_type, expected_type)
      return true if foreign_function_type_projection_compatible?(actual_type, expected_type)

      if actual_type.is_a?(Types::Nullable) && expected_type.is_a?(Types::Nullable)
        return foreign_identity_projection_cast_compatible?(actual_type.base, expected_type.base)
      end

      return foreign_identity_projection_cast_compatible?(actual_type, expected_type.base) if expected_type.is_a?(Types::Nullable)
      return false if actual_type.is_a?(Types::Nullable)

      return true if same_external_opaque_handle_pointer_compatibility?(actual_type, expected_type)

      if pointer_type?(actual_type) && pointer_type?(expected_type)
        return false if const_pointer_type?(actual_type) && mutable_pointer_type?(expected_type)
        return true if void_pointer_type?(actual_type) || void_pointer_type?(expected_type)

        return true if foreign_identity_projection_cast_compatible?(actual_type.arguments.first, expected_type.arguments.first)

        return foreign_external_layout_compatible?(actual_type.arguments.first, expected_type.arguments.first)
      end

      return true if void_pointer_type?(actual_type) && opaque_type?(expected_type)
      return true if opaque_type?(actual_type) && void_pointer_type?(expected_type)
      return true if char_pointer_type?(actual_type) && expected_type == @types.fetch("cstr")
      return true if actual_type == @types.fetch("cstr") && char_pointer_type?(expected_type)

      false
    end

    def same_external_opaque_handle_pointer_compatibility?(actual_type, expected_type)
      if actual_type.is_a?(Types::Opaque) && pointer_type?(expected_type)
        return same_external_opaque_c_name?(actual_type, expected_type.arguments.first)
      end

      if pointer_type?(actual_type) && expected_type.is_a?(Types::Opaque)
        return same_external_opaque_c_name?(actual_type.arguments.first, expected_type)
      end

      false
    end

    def foreign_function_type_projection_compatible?(actual_type, expected_type)
      return false unless actual_type.is_a?(Types::Function) && expected_type.is_a?(Types::Function)
      return false unless actual_type.receiver_type == expected_type.receiver_type
      return false unless actual_type.variadic == expected_type.variadic
      return false unless actual_type.params.length == expected_type.params.length
      return false unless foreign_identity_projection_compatible?(actual_type.return_type, expected_type.return_type)

      actual_type.params.zip(expected_type.params).all? do |actual_param, expected_param|
        actual_param.mutable == expected_param.mutable &&
          actual_param.passing_mode == expected_param.passing_mode &&
          actual_param.boundary_type == expected_param.boundary_type &&
          foreign_identity_projection_compatible?(actual_param.type, expected_param.type)
      end
    end

    def same_external_opaque_c_name?(actual_type, expected_type)
      return false unless actual_type.is_a?(Types::Opaque) && expected_type.is_a?(Types::Opaque)
      return false unless actual_type.external || actual_type.c_name
      return false unless expected_type.external || expected_type.c_name

      foreign_opaque_c_name(actual_type) == foreign_opaque_c_name(expected_type)
    end

    def foreign_opaque_c_name(type)
      type.c_name || type.name
    end

    def foreign_identity_projection_reinterpret_compatible?(actual_type, expected_type)
      if actual_type.is_a?(Types::Nullable) && expected_type.is_a?(Types::Nullable)
        return foreign_identity_projection_reinterpret_compatible?(actual_type.base, expected_type.base)
      end

      return foreign_identity_projection_reinterpret_compatible?(actual_type, expected_type.base) if expected_type.is_a?(Types::Nullable)
      return false if actual_type.is_a?(Types::Nullable)

      foreign_external_layout_compatible?(actual_type, expected_type)
    end

    def foreign_external_layout_compatible?(actual_type, expected_type, seen = {})
      return false unless actual_type.is_a?(Types::Struct) && expected_type.is_a?(Types::Struct)
      return false if actual_type.is_a?(Types::Union) != expected_type.is_a?(Types::Union)
      return false unless actual_type.external && expected_type.external
      return false unless actual_type.name == expected_type.name
      return false unless actual_type.packed == expected_type.packed
      return false unless actual_type.alignment == expected_type.alignment

      key = [actual_type.object_id, expected_type.object_id]
      return true if seen[key]

      seen[key] = true
      actual_fields = actual_type.fields
      expected_fields = expected_type.fields
      return false unless actual_fields.keys == expected_fields.keys

      actual_fields.all? do |field_name, field_type|
        foreign_external_layout_field_compatible?(field_type, expected_fields.fetch(field_name), seen)
      end
    end

    def foreign_external_layout_field_compatible?(actual_type, expected_type, seen)
      return true if actual_type == expected_type

      if actual_type.is_a?(Types::Nullable) && expected_type.is_a?(Types::Nullable)
        return foreign_external_layout_field_compatible?(actual_type.base, expected_type.base, seen)
      end

      if pointer_type?(actual_type) && pointer_type?(expected_type)
        return foreign_external_layout_field_compatible?(actual_type.arguments.first, expected_type.arguments.first, seen)
      end

      if array_type?(actual_type) && array_type?(expected_type)
        return false unless array_length(actual_type) == array_length(expected_type)

        return foreign_external_layout_field_compatible?(array_element_type(actual_type), array_element_type(expected_type), seen)
      end

      foreign_external_layout_compatible?(actual_type, expected_type, seen)
    end

    def void_pointer_type?(type)
      pointer_type?(type) && type.arguments.first == @types.fetch("void")
    end

    def char_pointer_type?(type)
      pointer_type?(type) && type.arguments.first == @types.fetch("char")
    end

    def opaque_type?(type)
      type.is_a?(Types::Opaque)
    end

    def pointer_type?(type)
      mutable_pointer_type?(type) || const_pointer_type?(type)
    end

    def mutable_pointer_type?(type)
      type.is_a?(Types::GenericInstance) && type.name == "ptr" && type.arguments.length == 1
    end

    def const_pointer_type?(type)
      type.is_a?(Types::GenericInstance) && type.name == "const_ptr" && type.arguments.length == 1
    end

    def ref_type?(type)
      type.is_a?(Types::GenericInstance) && type.name == "ref" && type.arguments.length == 1
    end

    def task_type?(type)
      type.is_a?(Types::Task)
    end

    def proc_type?(type)
      type.is_a?(Types::Proc)
    end

    def range_expr?(expression)
      expression.is_a?(AST::RangeExpr)
    end

    def pointee_type(type)
      return unless pointer_type?(type)

      type.arguments.first
    end

    def referenced_type(type)
      return unless ref_type?(type)

      type.arguments.first
    end

    def const_pointer_to(type)
      Types::GenericInstance.new("const_ptr", [type])
    end

    def call_arity_matches?(function_type, actual_count)
      return actual_count >= function_type.params.length if function_type.is_a?(Types::Function) && function_type.variadic

      actual_count == function_type.params.length
    end

    def arity_error_message(function_type, name, actual_count)
      if function_type.is_a?(Types::Function) && function_type.variadic
        "function #{name} expects at least #{function_type.params.length} arguments, got #{actual_count}"
      else
        "function #{name} expects #{function_type.params.length} arguments, got #{actual_count}"
      end
    end

    def string_builder_type?(type)
      type.respond_to?(:name) && type.respond_to?(:module_name) && type.name == "String" && type.module_name == "std.string"
    end

    def string_builder_ref_type?(type)
      ref_type?(type) && string_builder_type?(referenced_type(type))
    end

    def callable_param_ref_supported?(type)
      case type
      when Types::Proc
        type.params.all? { |param| ref_type?(param.type) || !contains_ref_type?(param.type) } &&
          !contains_ref_type?(type.return_type)
      when Types::Function
        type.params.all? { |param| ref_type?(param.type) || !contains_ref_type?(param.type) } &&
          !contains_ref_type?(type.return_type) &&
          (type.receiver_type.nil? || !contains_ref_type?(type.receiver_type))
      else
        false
      end
    end

    def contains_ref_type?(type, visited = {})
      return false unless type

      visit_key = [type.class, type.object_id]
      return false if visited[visit_key]

      visited[visit_key] = true
      case type
      when Types::Nullable
        contains_ref_type?(type.base, visited)
      when Types::GenericInstance
        return true if ref_type?(type)

        type.arguments.any? { |argument| !argument.is_a?(Types::LiteralTypeArg) && contains_ref_type?(argument, visited) }
      when Types::Span
        contains_ref_type?(type.element_type, visited)
      when Types::Task
        contains_ref_type?(type.result_type, visited)
      when Types::Struct, Types::Union
        type.fields.each_value.any? { |field_type| contains_ref_type?(field_type, visited) }
      when Types::StructInstance
        type.arguments.any? { |argument| contains_ref_type?(argument, visited) }
      when Types::Variant
        type.arm_names.any? { |arm_name| type.arm(arm_name).each_value.any? { |field_type| contains_ref_type?(field_type, visited) } }
      when Types::VariantInstance
        type.arguments.any? { |argument| contains_ref_type?(argument, visited) }
      when Types::Proc
        type.params.any? { |param| contains_ref_type?(param.type, visited) } || contains_ref_type?(type.return_type, visited)
      when Types::Function
        type.params.any? { |param| contains_ref_type?(param.type, visited) } ||
          contains_ref_type?(type.return_type, visited) ||
          (type.receiver_type && contains_ref_type?(type.receiver_type, visited))
      else
        false
      end
    end
  end
end
