# frozen_string_literal: true

module MilkTea
  class CBackend
    module FeatureDetection
      def uses_fmt_builder?
        return @uses_fmt_builder if defined?(@uses_fmt_builder)

        @uses_fmt_builder = emitted_functions.any? do |function|
          function_uses_named_call?(function, %w[mt_fmt_begin])
        end
      end

      def uses_string_view?
        return @uses_string_view if defined?(@uses_string_view)
        @uses_string_view = begin
          uses_fatal_helper? || uses_format_helpers? || uses_str_buffer_helpers? ||
            uses_entrypoint_argv_helpers? || uses_str_equality_helper? ||
            uses_foreign_temp_cstr_helpers? ||
            emitted_functions.any? do |function|
              type_contains_string_view?(function.return_type) ||
                function.params.any? { |param| type_contains_string_view?(param.type) }
            end ||
            emitted_aggregate_structs.any? { |s| s.fields.any? { |f| type_contains_string_view?(f.type) } } ||
            emitted_aggregate_unions.any? { |u| u.fields.any? { |f| type_contains_string_view?(f.type) } } ||
            emitted_aggregate_variants.any? { |v| v.arms.any? { |a| a.fields.any? { |f| type_contains_string_view?(f.type) } } } ||
            emitted_constants.any? { |c| type_contains_string_view?(c.type) } ||
            emitted_globals.any? { |g| type_contains_string_view?(g.type) } ||
            !collect_str_literals.empty?
        end
      end

      def type_contains_string_view?(type)
        return false unless type
        return true if type.is_a?(Types::StringView)
        case type
        when Types::Nullable
          type_contains_string_view?(type.base)
        when Types::Span
          type_contains_string_view?(type.element_type)
        when Types::GenericInstance
          type.arguments.any? { |a| type_contains_string_view?(a) }
        else
          false
        end
      end

      def uses_vector_math_types?
        return @uses_vector_math_types if defined?(@uses_vector_math_types)
        @uses_vector_math_types = begin
          emitted_functions.any? do |function|
            type_contains_vector_math?(function.return_type) ||
              function.params.any? { |param| type_contains_vector_math?(param.type) } ||
              function.body.any? { |stmt| statement_uses_vector_math?(stmt) }
          end ||
            emitted_aggregate_structs.any? { |s| s.fields.any? { |f| type_contains_vector_math?(f.type) } } ||
            emitted_aggregate_unions.any? { |u| u.fields.any? { |f| type_contains_vector_math?(f.type) } } ||
            emitted_aggregate_variants.any? { |v| v.arms.any? { |a| a.fields.any? { |f| type_contains_vector_math?(f.type) } } } ||
            emitted_constants.any? { |c| type_contains_vector_math?(c.type) } ||
            emitted_globals.any? { |g| type_contains_vector_math?(g.type) }
        end
        @uses_vector_math_types
      end

      def statement_uses_vector_math?(stmt)
        case stmt
        when IR::LocalDecl
          type_contains_vector_math?(stmt.type)
        when IR::Assignment
          type_contains_vector_math?(stmt.target.type) || expression_uses_vector_math?(stmt.value)
        when IR::ExpressionStmt
          expression_uses_vector_math?(stmt.expression)
        when IR::ReturnStmt
          stmt.value && expression_uses_vector_math?(stmt.value)
        when IR::BlockStmt
          stmt.body.any? { |s| statement_uses_vector_math?(s) }
        when IR::WhileStmt
          stmt.body.any? { |s| statement_uses_vector_math?(s) }
        when IR::ForStmt
          stmt.body.any? { |s| statement_uses_vector_math?(s) }
        when IR::IfStmt
          stmt.then_body.any? { |s| statement_uses_vector_math?(s) } ||
            (stmt.else_body && stmt.else_body.any? { |s| statement_uses_vector_math?(s) })
        when IR::SwitchStmt
          stmt.cases.any? { |c| c.body.any? { |s| statement_uses_vector_math?(s) } }
        else
          false
        end
      end

      def expression_uses_vector_math?(expr)
        return false unless expr
        return true if expr.respond_to?(:type) && type_contains_vector_math?(expr.type)
        case expr
        when IR::Assignment
          expression_uses_vector_math?(expr.target) || expression_uses_vector_math?(expr.value)
        when IR::AggregateLiteral
          expr.fields.any? { |f| expression_uses_vector_math?(f.value) }
        when IR::Binary
          expression_uses_vector_math?(expr.left) || expression_uses_vector_math?(expr.right)
        when IR::Unary
          expression_uses_vector_math?(expr.operand)
        when IR::Call
          expr.arguments.any? { |a| expression_uses_vector_math?(a) }
        when IR::Member
          expression_uses_vector_math?(expr.receiver)
        when IR::Index
          expression_uses_vector_math?(expr.receiver)
        when IR::Conditional
          expression_uses_vector_math?(expr.then_expression) || expression_uses_vector_math?(expr.else_expression)
        else
          false
        end
      end

      def type_contains_vector_math?(type)
        return false unless type
        return true if type.is_a?(Types::Vector) || type.is_a?(Types::Matrix) || type.is_a?(Types::Quaternion)
        case type
        when Types::Nullable
          type_contains_vector_math?(type.base)
        when Types::Span
          type_contains_vector_math?(type.element_type)
        when Types::GenericInstance
          type.arguments.any? { |a| type_contains_vector_math?(a) }
        else
          false
        end
      end

      def uses_fatal_helper?
        uses_mt_fatal_helper? || uses_mt_fatal_str_helper?
      end

      def uses_mt_fatal_helper?
        return true if @debug_guards

        collect_checked_array_index_types.any? || collect_checked_span_index_types.any? ||
          !collect_span_slice_helper_names.empty? ||
          uses_format_helpers? ||
          emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_fatal mt_str_buffer_len mt_str_buffer_as_cstr mt_str_buffer_assign mt_str_buffer_append mt_foreign_str_to_cstr_temp mt_foreign_strs_to_cstrs_temp mt_str_concat mt_str_index mt_str_slice]) }
      end

      def uses_mt_fatal_str_helper?
        emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_fatal_str]) }
      end

      def uses_foreign_temp_cstr_helpers?
        emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_foreign_str_to_cstr_temp mt_free_foreign_cstr_temp mt_foreign_strs_to_cstrs_temp mt_free_foreign_cstrs_temp]) }
      end

      def uses_entrypoint_argv_helpers?
        emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_entry_argv_to_span_str mt_free_entry_argv_strs]) }
      end

      def uses_str_buffer_helpers?
        emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_buffer_len mt_str_buffer_as_cstr mt_str_buffer_clear mt_str_buffer_assign mt_str_buffer_append mt_str_buffer_prepare_write]) }
      end

      def uses_async_memory_helpers?
        emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_async_alloc mt_async_free]) }
      end

      def uses_cyclic_variant_heap_copy?
        all_variants = emitted_aggregate_variants + collect_generic_variant_decls
        all_variants.any? do |v|
          v.arms.any? do |arm|
            arm.fields.any? do |f|
              aggregate_field_creates_cycle?(f.type, v.linkage_name)
            end
          end
        end
      end

      def uses_parallel_for_helper?
        emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_parallel_for]) }
      end

      def uses_spawn_all_helper?
        emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_spawn_all]) }
      end

      def uses_detach_helper?
        emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_detach_run mt_detach_join]) }
      end

      def format_helper_callees
        %w[
          mt_format_str_make
          mt_format_str_release
          mt_format_cstr_len
          mt_format_bool_len
          mt_format_ptr_uint_len
          mt_format_ulong_len
          mt_format_uint_len
          mt_format_long_len
          mt_format_int_len
          mt_format_ulong_hex_len
          mt_format_long_hex_len
          mt_format_float_len
          mt_format_double_len
          mt_format_double_precision_len
          mt_format_ulong_oct_len
          mt_format_long_oct_len
          mt_format_ulong_bin_len
          mt_format_long_bin_len
          mt_format_append_str
          mt_format_append_cstr
          mt_format_append_bool
          mt_format_append_ptr_uint
          mt_format_append_ulong
          mt_format_append_uint
          mt_format_append_long
          mt_format_append_int
          mt_format_append_ulong_hex
          mt_format_append_ulong_hex_upper
          mt_format_append_long_hex
          mt_format_append_long_hex_upper
          mt_format_append_float
          mt_format_append_double
          mt_format_append_double_precision
          mt_format_append_ulong_oct
          mt_format_append_long_oct
          mt_format_append_ulong_bin
          mt_format_append_long_bin
        ]
      end

      def required_format_helper_callees
        @required_format_helper_callees ||= begin
          helpers = {}

          emitted_functions.each do |function|
            format_helper_callees.each do |callee|
              helpers[callee] = true if function_uses_named_call?(function, [callee])
            end
          end

          loop do
            changed = false

            helpers.keys.each do |helper|
              (FORMAT_HELPER_DEPENDENCIES[helper] || []).each do |dependency|
                next if helpers[dependency]

                helpers[dependency] = true
                changed = true
              end
            end

            break unless changed
          end

          helpers
        end
      end

      FORMAT_HELPER_DEPENDENCIES = {
        'mt_format_append_str' => %w[mt_format_append_bytes mt_format_check_capacity],
        'mt_format_append_cstr' => %w[mt_format_append_bytes mt_format_check_capacity mt_format_cstr_len],
        'mt_format_append_bool' => %w[mt_format_append_bytes mt_format_check_capacity],
        'mt_format_append_ptr_uint' => %w[mt_format_check_capacity mt_format_ptr_uint_len],
        'mt_format_append_ulong' => %w[mt_format_check_capacity mt_format_ulong_len],
        'mt_format_append_uint' => %w[mt_format_append_ptr_uint mt_format_check_capacity mt_format_ptr_uint_len],
        'mt_format_append_long' => %w[mt_format_append_bytes mt_format_check_capacity mt_format_append_ulong mt_format_ulong_len],
        'mt_format_append_int' => %w[mt_format_append_bytes mt_format_check_capacity mt_format_append_ptr_uint mt_format_ptr_uint_len],
        'mt_format_append_ulong_hex' => %w[mt_format_check_capacity mt_format_ulong_hex_len],
        'mt_format_append_ulong_hex_upper' => %w[mt_format_check_capacity mt_format_ulong_hex_len],
        'mt_format_append_long_hex' => %w[mt_format_append_bytes mt_format_check_capacity mt_format_append_ulong_hex mt_format_ulong_hex_len],
        'mt_format_append_long_hex_upper' => %w[mt_format_append_bytes mt_format_check_capacity mt_format_append_ulong_hex_upper mt_format_ulong_hex_len],
        'mt_format_append_ulong_oct' => %w[mt_format_check_capacity mt_format_ulong_oct_len],
        'mt_format_append_long_oct' => %w[mt_format_append_bytes mt_format_check_capacity mt_format_append_ulong_oct mt_format_ulong_oct_len],
        'mt_format_append_ulong_bin' => %w[mt_format_check_capacity mt_format_ulong_bin_len],
        'mt_format_append_long_bin' => %w[mt_format_append_bytes mt_format_check_capacity mt_format_append_ulong_bin mt_format_ulong_bin_len],
        'mt_format_append_float' => %w[mt_format_check_capacity mt_format_float_len],
        'mt_format_append_double' => %w[mt_format_check_capacity mt_format_double_len],
        'mt_format_append_double_precision' => %w[mt_format_check_capacity mt_format_double_precision_len],
        'mt_format_int_len' => %w[mt_format_ptr_uint_len],
        'mt_format_long_len' => %w[mt_format_ulong_len],
        'mt_format_long_hex_len' => %w[mt_format_ulong_hex_len],
        'mt_format_long_oct_len' => %w[mt_format_ulong_oct_len],
        'mt_format_long_bin_len' => %w[mt_format_ulong_bin_len],
      }.freeze

      def uses_format_helpers?
        !required_format_helper_callees.empty?
      end

      def uses_str_equality_helper?
        emitted_functions.any? { |function| function_uses_str_equality?(function) }
      end

      def uses_str_concat_helper?
        return @uses_str_concat if defined?(@uses_str_concat)

        @uses_str_concat = emitted_functions.any? do |function|
          function_uses_named_call?(function, %w[mt_str_concat])
        end
      end

      def uses_str_slice_helpers?
        emitted_functions.any? { |function| function_uses_named_call?(function, %w[mt_str_index mt_str_slice]) }
      end

      def uses_variant_equality_helper?
        !variant_equality_types.empty?
      end

      def uses_struct_equality_helper?
        !struct_equality_types.empty?
      end

      # Aggregate types (structs and variants) compared with ==/!= anywhere in
      # the program, transitively closed over value-typed fields so nested
      # aggregates used inside a comparison also get an equality helper.
      def aggregate_equality_types
        @aggregate_equality_types ||= begin
          types = Set.new
          emitted_functions.each do |function|
            function.body.each do |statement|
              statement_matches_expression_predicate?(
                statement,
                expression_pred: ->(expression) { collect_aggregate_equality_from_expression(expression, types) },
              )
            end
          end
          types
        end
      end

      def struct_equality_types
        @struct_equality_types ||= aggregate_equality_types.select { |type| struct_equality_type?(type) || type.is_a?(Types::VariantArmPayload) }
      end

      def variant_equality_types
        @variant_equality_types ||= aggregate_equality_types.select { |type| type.is_a?(Types::Variant) }
      end

      def aggregate_equality_type?(type)
        struct_equality_type?(type) || type.is_a?(Types::Variant) || type.is_a?(Types::VariantArmPayload)
      end

      def collect_aggregate_equality_from_expression(expression, types)
        case expression
        when IR::Binary
          collect_aggregate_equality_from_expression(expression.left, types)
          collect_aggregate_equality_from_expression(expression.right, types)
          if EQUALITY_OPERATORS.include?(expression.operator) && aggregate_equality_type?(expression.left.type)
            collect_aggregate_equality_dependencies(expression.left.type, types)
          end
        when IR::Call
          collect_aggregate_equality_from_expression(expression.callee, types) unless expression.callee.is_a?(String)
          expression.arguments.each { |argument| collect_aggregate_equality_from_expression(argument, types) }
        when IR::Member
          collect_aggregate_equality_from_expression(expression.receiver, types)
        when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
          collect_aggregate_equality_from_expression(expression.receiver, types)
          collect_aggregate_equality_from_expression(expression.index, types)
        when IR::Unary
          collect_aggregate_equality_from_expression(expression.operand, types)
        when IR::Conditional
          collect_aggregate_equality_from_expression(expression.condition, types)
          collect_aggregate_equality_from_expression(expression.then_expression, types)
          collect_aggregate_equality_from_expression(expression.else_expression, types)
        when IR::ReinterpretExpr, IR::Cast, IR::AddressOf
          collect_aggregate_equality_from_expression(expression.expression, types)
        when IR::AggregateLiteral
          expression.fields.each { |field| collect_aggregate_equality_from_expression(field.value, types) }
        when IR::ArrayLiteral
          expression.elements.each { |element| collect_aggregate_equality_from_expression(element, types) }
        when IR::VariantLiteral
          expression.fields.each { |field| collect_aggregate_equality_from_expression(field.value, types) }
        end
        false
      end

      def collect_aggregate_equality_dependencies(type, types)
        return if types.include?(type)

        case type
        when Types::Variant
          types << type
          type.arm_names.each do |arm_name|
            (type.arm(arm_name) || {}).each_value { |field_type| collect_value_field_equality_dependencies(field_type, types) }
          end
        when Types::VariantArmPayload
          types << type
          arm_fields = type.variant_type.arm(type.arm_name) || {}
          arm_fields.each_value { |field_type| collect_value_field_equality_dependencies(field_type, types) }
        when Types::Struct
          return unless struct_equality_type?(type)

          types << type
          type.fields.each_value { |field_type| collect_value_field_equality_dependencies(field_type, types) }
        end
      end

      def collect_value_field_equality_dependencies(type, types)
        case type
        when Types::Nullable
          collect_value_field_equality_dependencies(type.base, types)
        when Types::Struct, Types::Variant
          collect_aggregate_equality_dependencies(type, types)
        when Types::VariantArmPayload
          collect_aggregate_equality_dependencies(type, types)
        when Types::GenericInstance
          collect_value_field_equality_dependencies(array_element_type(type), types) if array_type?(type)
        end
      end

      def aggregate_equality_needs_string_view?
        aggregate_equality_types.any? { |type| aggregate_contains_string_view?(type) }
      end

      def aggregate_contains_string_view?(type, visiting = nil)
        return false unless type
        return false if visiting&.key?(type)

        visiting = (visiting || {}).merge(type => true)
        case type
        when Types::StringView
          true
        when Types::Struct
          type.fields.any? { |_name, field_type| aggregate_contains_string_view?(field_type, visiting) }
        when Types::Variant
          type.arm_names.any? { |arm_name| (type.arm(arm_name) || {}).any? { |_field_name, field_type| aggregate_contains_string_view?(field_type, visiting) } }
        when Types::Nullable
          aggregate_contains_string_view?(type.base, visiting)
        when Types::GenericInstance
          type.arguments.any? { |argument| aggregate_contains_string_view?(argument, visiting) }
        else
          false
        end
      end

      def function_uses_named_call?(function, callees)
        function.body.any? { |statement| statement_uses_named_call?(statement, callees) }
      end

      def function_uses_str_equality?(function)
        function.body.any? { |statement| statement_uses_str_equality?(statement) }
      end

      def statement_matches_expression_predicate?(statement, expression_pred:, **kwargs)
        case statement
        when IR::LocalDecl
          statement.value && expression_pred.call(statement.value, **kwargs)
        when IR::Assignment
          expression_pred.call(statement.target, **kwargs) || expression_pred.call(statement.value, **kwargs)
        when IR::BlockStmt
          statement.body.any? { |inner| statement_matches_expression_predicate?(inner, expression_pred:, **kwargs) }
        when IR::WhileStmt
          expression_pred.call(statement.condition, **kwargs) ||
            statement.body.any? { |inner| statement_matches_expression_predicate?(inner, expression_pred:, **kwargs) }
        when IR::ForStmt
          statement_matches_expression_predicate?(statement.init, expression_pred:, **kwargs) ||
            expression_pred.call(statement.condition, **kwargs) ||
            statement.body.any? { |inner| statement_matches_expression_predicate?(inner, expression_pred:, **kwargs) } ||
            statement_matches_expression_predicate?(statement.post, expression_pred:, **kwargs)
        when IR::IfStmt
          expression_pred.call(statement.condition, **kwargs) ||
            statement.then_body.any? { |inner| statement_matches_expression_predicate?(inner, expression_pred:, **kwargs) } ||
            (statement.else_body && statement.else_body.any? { |inner| statement_matches_expression_predicate?(inner, expression_pred:, **kwargs) })
        when IR::SwitchStmt
          expression_pred.call(statement.expression, **kwargs) ||
            statement.cases.any? { |switch_case| switch_case.body.any? { |inner| statement_matches_expression_predicate?(inner, expression_pred:, **kwargs) } }
        when IR::StaticAssert
          expression_pred.call(statement.condition, **kwargs) || expression_pred.call(statement.message, **kwargs)
        when IR::ReturnStmt
          statement.value && expression_pred.call(statement.value, **kwargs)
        when IR::ExpressionStmt
          expression_pred.call(statement.expression, **kwargs)
        else
          false
        end
      end

      def statement_uses_named_call?(statement, callees)
        statement_matches_expression_predicate?(statement, expression_pred: ->(e) { expression_uses_named_call?(e, callees) })
      end

      def statement_uses_str_equality?(statement)
        statement_matches_expression_predicate?(statement, expression_pred: ->(e) { expression_uses_str_equality?(e) })
      end

      def expression_uses_named_call?(expression, callees)
        case expression
        when IR::Call
          callees.include?(expression.callee) ||
            (!expression.callee.is_a?(String) && expression_uses_named_call?(expression.callee, callees)) ||
            expression.arguments.any? { |argument| expression_uses_named_call?(argument, callees) }
        when IR::Member
          expression_uses_named_call?(expression.receiver, callees)
        when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
          expression_uses_named_call?(expression.receiver, callees) || expression_uses_named_call?(expression.index, callees)
        when IR::Unary
          expression_uses_named_call?(expression.operand, callees)
        when IR::Binary
          expression_uses_named_call?(expression.left, callees) || expression_uses_named_call?(expression.right, callees)
        when IR::Conditional
          expression_uses_named_call?(expression.condition, callees) || expression_uses_named_call?(expression.then_expression, callees) || expression_uses_named_call?(expression.else_expression, callees)
        when IR::ReinterpretExpr, IR::Cast, IR::AddressOf
          expression_uses_named_call?(expression.expression, callees)
        when IR::AggregateLiteral
          expression.fields.any? { |field| expression_uses_named_call?(field.value, callees) }
        when IR::ArrayLiteral
          expression.elements.any? { |element| expression_uses_named_call?(element, callees) }
        when IR::VariantLiteral
          expression.fields.any? { |field| expression_uses_named_call?(field.value, callees) }
        else
          false
        end
      end

      def expression_uses_str_equality?(expression)
        case expression
        when IR::Binary
          string_equality_expression?(expression) || expression_uses_str_equality?(expression.left) || expression_uses_str_equality?(expression.right)
        when IR::Call
          (!expression.callee.is_a?(String) && expression_uses_str_equality?(expression.callee)) || expression.arguments.any? { |argument| expression_uses_str_equality?(argument) }
        when IR::Member
          expression_uses_str_equality?(expression.receiver)
        when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
          expression_uses_str_equality?(expression.receiver) || expression_uses_str_equality?(expression.index)
        when IR::Unary
          expression_uses_str_equality?(expression.operand)
        when IR::Conditional
          expression_uses_str_equality?(expression.condition) || expression_uses_str_equality?(expression.then_expression) || expression_uses_str_equality?(expression.else_expression)
        when IR::ReinterpretExpr, IR::Cast, IR::AddressOf
          expression_uses_str_equality?(expression.expression)
        when IR::AggregateLiteral
          expression.fields.any? { |field| expression_uses_str_equality?(field.value) }
        when IR::ArrayLiteral
          expression.elements.any? { |element| expression_uses_str_equality?(element) }
        when IR::VariantLiteral
          expression.fields.any? { |field| expression_uses_str_equality?(field.value) }
        else
          false
        end
      end
    end
  end
end
