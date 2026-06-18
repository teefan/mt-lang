# frozen_string_literal: true

module MilkTea
  module LowererForeignCstr
    private


      def lower_foreign_cstr_list_argument_value(parameter, argument_value, env:, lowered:, cleanup:)
        if (direct_value = lower_direct_foreign_cstr_list_argument_value(parameter, argument_value, env:, lowered:))
          return direct_value
        end

        public_type = parameter.type
        boundary_type = parameter.boundary_type
        items_type = pointer_to(pointer_to(@ctx.types.fetch("char")))
        data_type = pointer_to(@ctx.types.fetch("char"))
        len_type = @ctx.types.fetch("ptr_uint")
        lowered_value = lower_contextual_expression(argument_value, env:, expected_type: public_type)
        items_name = fresh_c_temp_name(env, "foreign_cstr_items")
        data_name = fresh_c_temp_name(env, "foreign_cstr_data")
        len_name = fresh_c_temp_name(env, "foreign_cstr_len")

        lowered << IR::LocalDecl.new(
          name: items_name,
          c_name: items_name,
          type: items_type,
          value: IR::NullLiteral.new(type: items_type),
        )
        lowered << IR::LocalDecl.new(
          name: data_name,
          c_name: data_name,
          type: data_type,
          value: IR::NullLiteral.new(type: data_type),
        )
        lowered << IR::LocalDecl.new(
          name: len_name,
          c_name: len_name,
          type: len_type,
          value: IR::IntegerLiteral.new(value: 0, type: len_type),
        )
        lowered << IR::ExpressionStmt.new(
          expression: IR::Call.new(
            callee: "mt_foreign_strs_to_cstrs_temp",
            arguments: [
              lowered_value,
              IR::AddressOf.new(expression: IR::Name.new(name: items_name, type: items_type, pointer: false), type: pointer_to(items_type)),
              IR::AddressOf.new(expression: IR::Name.new(name: data_name, type: data_type, pointer: false), type: pointer_to(data_type)),
              IR::AddressOf.new(expression: IR::Name.new(name: len_name, type: len_type, pointer: false), type: pointer_to(len_type)),
            ],
            type: @ctx.types.fetch("void"),
          ),
        )
        cleanup << IR::ExpressionStmt.new(
          expression: IR::Call.new(
            callee: "mt_free_foreign_cstrs_temp",
            arguments: [
              IR::Name.new(name: items_name, type: items_type, pointer: false),
              IR::Name.new(name: data_name, type: data_type, pointer: false),
            ],
            type: @ctx.types.fetch("void"),
          ),
        )

        converted_data = foreign_identity_projection_expression(
          IR::Name.new(name: items_name, type: items_type, pointer: false),
          pointer_to(boundary_type.element_type),
        )
        raise LoweringError, "unsupported foreign boundary mapping #{public_type} as #{boundary_type}" unless converted_data

        IR::AggregateLiteral.new(
          type: boundary_type,
          fields: [
            IR::AggregateField.new(name: "data", value: converted_data),
            IR::AggregateField.new(name: "len", value: IR::Name.new(name: len_name, type: len_type, pointer: false)),
          ],
        )
      end

      def lower_direct_foreign_cstr_list_argument_value(parameter, argument_value, env:, lowered:)
        actual_type = infer_expression_type(argument_value, env:)
        return unless array_type?(actual_type)
        return unless cstr_list_backed_expression?(argument_value, env)

        boundary_type = parameter.boundary_type
        boundary_element_type = boundary_type.element_type
        len = array_length(actual_type)
        len_type = @ctx.types.fetch("ptr_uint")

        if len.zero?
          return IR::AggregateLiteral.new(
            type: boundary_type,
            fields: [
              IR::AggregateField.new(name: "data", value: IR::NullLiteral.new(type: pointer_to(boundary_element_type))),
              IR::AggregateField.new(name: "len", value: IR::IntegerLiteral.new(value: 0, type: len_type)),
            ],
          )
        end

        source = lower_expression(argument_value, env:, expected_type: actual_type)
        item_type = array_element_type(actual_type)
        items_array_type = Types::GenericInstance.new("array", [boundary_element_type, Types::LiteralTypeArg.new(len)])
        items_name = fresh_c_temp_name(env, "foreign_cstr_items")
        items = (0...len).map do |index|
          item = IR::Index.new(
            receiver: source,
            index: IR::IntegerLiteral.new(value: index, type: len_type),
            type: item_type,
          )
          item = IR::Member.new(receiver: item, member: "data", type: pointer_to(@ctx.types.fetch("char"))) if item_type == @ctx.types.fetch("str")

          converted = foreign_identity_projection_expression(item, boundary_element_type)
          raise LoweringError, "unsupported foreign boundary mapping #{parameter.type} as #{boundary_type}" unless converted

          converted
        end

        lowered << IR::LocalDecl.new(
          name: items_name,
          c_name: items_name,
          type: items_array_type,
          value: IR::ArrayLiteral.new(type: items_array_type, elements: items),
        )

        items_ref = IR::Name.new(name: items_name, type: items_array_type, pointer: false)
        IR::AggregateLiteral.new(
          type: boundary_type,
          fields: [
            IR::AggregateField.new(
              name: "data",
              value: IR::AddressOf.new(
                expression: IR::Index.new(
                  receiver: items_ref,
                  index: IR::IntegerLiteral.new(value: 0, type: len_type),
                  type: boundary_element_type,
                ),
                type: pointer_to(boundary_element_type),
              ),
            ),
            IR::AggregateField.new(name: "len", value: IR::IntegerLiteral.new(value: len, type: len_type)),
          ],
        )
      end

      def inlineable_foreign_argument_expression?(expression)
        case expression
        when IR::Name, IR::IntegerLiteral, IR::FloatLiteral, IR::StringLiteral, IR::BooleanLiteral, IR::NullLiteral, IR::ZeroInit, IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
          true
        when IR::Call
          return false if temporary_foreign_cstr_expression?(expression)

          callee_inlineable = expression.callee.is_a?(String) || inlineable_foreign_argument_expression?(expression.callee)
          callee_inlineable && expression.arguments.all? { |argument| inlineable_foreign_argument_expression?(argument) }
        when IR::Member
          inlineable_foreign_argument_expression?(expression.receiver)
        when IR::Index
          inlineable_foreign_argument_expression?(expression.receiver) && inlineable_foreign_argument_expression?(expression.index)
        when IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex
          inlineable_foreign_argument_expression?(expression.receiver) && inlineable_foreign_argument_expression?(expression.index)
        when IR::Unary
          inlineable_foreign_argument_expression?(expression.operand)
        when IR::Binary
          inlineable_foreign_argument_expression?(expression.left) && inlineable_foreign_argument_expression?(expression.right)
        when IR::Conditional
          inlineable_foreign_argument_expression?(expression.condition) &&
            inlineable_foreign_argument_expression?(expression.then_expression) &&
            inlineable_foreign_argument_expression?(expression.else_expression)
        when IR::ReinterpretExpr, IR::Cast
          inlineable_foreign_argument_expression?(expression.expression)
        when IR::AddressOf
          inlineable_foreign_argument_expression?(expression.expression)
        when IR::AggregateLiteral
          expression.fields.all? { |field| inlineable_foreign_argument_expression?(field.value) }
        else
          false
        end
      end

      def lower_contextual_expression(expression, env:, expected_type:, external_numeric: false, contextual_int_to_float: false)
        if string_literal_cstr_compatibility?(expression, expected_type)
          return IR::StringLiteral.new(value: expression.value, type: expected_type, cstring: true)
        end

        lowered = lower_expression(expression, env:, expected_type: expected_type)
        return lowered unless expected_type
        if (materialized = materialize_pointer_backed_value(lowered, expected_type))
          return materialized
        end
        return lowered if lowered.type == expected_type
        return lower_direct_function_to_proc_expression(expression, lowered, env:, expected_type:) if direct_function_to_proc_contextual_compatibility?(expression, lowered.type, env:, expected_type:)
        return lower_str_buffer_to_span_expression(lowered, expected_type) if str_buffer_to_span_compatible?(lowered.type, expected_type)
        return lower_array_to_span_expression(lowered, expected_type) if array_to_span_compatible?(lowered.type, expected_type)
        return cast_expression(lowered, expected_type) if contextual_numeric_compatibility?(expression, lowered.type, expected_type, env:, external_numeric:, contextual_int_to_float:)

        lowered
      end

      def materialize_pointer_backed_value(lowered, expected_type)
        return nil unless lowered.is_a?(IR::Name) && lowered.pointer
        return nil unless lowered.type == expected_type
        return nil if ref_type?(expected_type)
        return nil if pointer_type?(expected_type)

        IR::Unary.new(operator: "*", operand: lowered, type: lowered.type)
      end
  end
end
