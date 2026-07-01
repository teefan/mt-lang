# frozen_string_literal: true

module MilkTea
  class CBackend
    module CBackendExpressions
      private


          def emit_expression(expression)
            case expression
            when IR::Name
              expression.name
            when IR::Member
              operator = pointer_member_receiver?(expression.receiver) ? "->" : "."
              member = "#{wrap_member_receiver(expression.receiver)}#{operator}#{sanitize_c_identifier(expression.member)}"
              expression.type.is_a?(Types::Primitive) && expression.type.void? ? "((void)(#{member}))" : member
            when IR::Index
              "#{wrap_index_receiver(expression.receiver)}[#{emit_expression(expression.index)}]"
            when IR::CheckedIndex
              if (alias_name = checked_index_alias(expression))
                "(*#{alias_name})"
              else
                "(*#{checked_array_index_helper_name(expression.receiver_type)}(#{emit_address_of_operand(expression.receiver)}, #{emit_expression(expression.index)}))"
              end
            when IR::CheckedSpanIndex
              if (alias_name = checked_index_alias(expression))
                "(*#{alias_name})"
              else
                "(*#{checked_span_index_helper_name(expression.receiver_type)}(#{emit_expression(expression.receiver)}, #{emit_expression(expression.index)}))"
              end
            when IR::NullableIndex
              "#{nullable_array_index_helper_name(expression.receiver_type)}(#{emit_address_of_operand(expression.receiver)}, #{emit_expression(expression.index)})"
            when IR::NullableSpanIndex
              "#{nullable_span_index_helper_name(expression.receiver_type)}(#{emit_expression(expression.receiver)}, #{emit_expression(expression.index)})"
            when IR::Call
              raise CBackendError, "array-return call must be materialized before C emission" if array_type?(expression.type)

              emit_call_expression(expression)
            when IR::Unary
              if expression.operator == "not"
                "!#{wrap_expression(expression.operand)}"
              else
                "#{expression.operator}#{wrap_expression(expression.operand)}"
              end
            when IR::Binary
              return emit_str_equality_expression(expression) if str_equality_expression?(expression)
              return emit_variant_equality_expression(expression) if variant_equality_expression?(expression)
              return emit_nullable_null_comparison(expression) if nullable_null_comparison?(expression)

              emit_binary_expression(expression)
            when IR::Conditional
              emit_conditional_expression(expression)
            when IR::ReinterpretExpr
              if no_op_reinterpret?(expression.target_type, expression.source_type)
                emit_expression(expression.expression)
              else
                "#{reinterpret_helper_name(expression.target_type, expression.source_type)}(#{emit_expression(expression.expression)})"
              end
            when IR::SizeofExpr
              "sizeof(#{layout_type_expression(expression.target_type)})"
            when IR::AlignofExpr
              "_Alignof(#{layout_type_expression(expression.target_type)})"
            when IR::OffsetofExpr
              "offsetof(#{layout_type_expression(expression.target_type)}, #{expression.field})"
            when IR::IntegerLiteral
              expression.value.to_s
            when IR::FloatLiteral
              emit_float_literal(expression)
            when IR::StringLiteral
              expression.type.is_a?(Types::StringView) ? emit_str_literal(expression) : expression.value.inspect
            when IR::BooleanLiteral
              expression.value ? "true" : "false"
            when IR::NullLiteral
              nullable_value_type?(expression.type) ? emit_zero_expression(expression.type) : "NULL"
            when IR::ZeroInit
              emit_zero_expression(expression.type)
            when IR::AddressOf
              case expression.expression
              when IR::CheckedIndex
                alias_name = checked_index_alias(expression.expression)
                alias_name || "#{checked_array_index_helper_name(expression.expression.receiver_type)}(#{emit_address_of_operand(expression.expression.receiver)}, #{emit_expression(expression.expression.index)})"
              when IR::CheckedSpanIndex
                alias_name = checked_index_alias(expression.expression)
                alias_name || "#{checked_span_index_helper_name(expression.expression.receiver_type)}(#{emit_expression(expression.expression.receiver)}, #{emit_expression(expression.expression.index)})"
              else
                emit_address_of_operand(expression.expression)
              end
            when IR::Cast
              if no_op_cast?(expression)
                emit_expression(expression.expression)
              else
                "(#{c_type(expression.target_type)}) #{emit_cast_operand(expression.expression)}"
              end
            when IR::AggregateLiteral
              emit_aggregate_literal(expression)
            when IR::ArrayLiteral
              emit_array_compound_literal(expression)
            when IR::VariantLiteral
              emit_variant_literal(expression)
            else
              raise CBackendError, "unsupported IR expression #{expression.class.name}"
            end
          end

          def str_equality_expression?(expression)
            EQUALITY_OPERATORS.include?(expression.operator) && expression.left.type.is_a?(Types::StringView) && expression.right.type.is_a?(Types::StringView)
          end

          def emit_binary_expression(expression)
            parent_precedence = binary_precedence(expression.operator)
            left = emit_binary_operand(expression.left, parent_precedence, side: :left)
            right = emit_binary_operand(expression.right, parent_precedence, side: :right)
            "#{left} #{c_operator(expression.operator)} #{right}"
          end

          def emit_binary_operand(expression, parent_precedence, side:)
            text = emit_expression(expression)

            case expression
            when IR::Conditional
              "(#{text})"
            when IR::Binary
              child_precedence = binary_precedence(expression.operator)
              if child_precedence < parent_precedence || (side == :right && child_precedence == parent_precedence)
                "(#{text})"
              else
                text
              end
            else
              text
            end
          end

          def emit_conditional_expression(expression)
            condition = emit_conditional_condition(expression.condition)
            then_expression = emit_expression(expression.then_expression)
            else_expression = emit_expression(expression.else_expression)
            "#{condition} ? #{then_expression} : #{else_expression}"
          end

          def emit_conditional_condition(expression)
            text = emit_expression(expression)
            expression.is_a?(IR::Conditional) ? "(#{text})" : text
          end

          def binary_precedence(operator)
            case operator
            when "or" then 1
            when "and" then 2
            when "|" then 3
            when "^" then 4
            when "&" then 5
            when "==", "!=" then 6
            when "<", "<=", ">", ">=" then 7
            when "<<", ">>" then 8
            when "+", "-" then 9
            when "*", "/", "%" then 10
            else
              raise CBackendError, "unsupported binary operator #{operator}"
            end
          end

          def emit_str_equality_expression(expression)
            call = "mt_str_equal(#{emit_expression(expression.left)}, #{emit_expression(expression.right)})"
            expression.operator == "!=" ? "!#{call}" : call
          end

          def variant_equality_expression?(expression)
            EQUALITY_OPERATORS.include?(expression.operator) &&
              (expression.left.type.is_a?(Types::Variant) || expression.left.type.is_a?(Types::VariantArmPayload))
          end

          def emit_variant_equality_expression(expression)
            helper_name = variant_equality_helper_name(expression.left.type)
            call = "#{helper_name}(#{emit_expression(expression.left)}, #{emit_expression(expression.right)})"
            expression.operator == "!=" ? "!#{call}" : call
          end

          def variant_equality_helper_name(type)
            variant = type.is_a?(Types::VariantArmPayload) ? type.variant_type : type
            "mt_variant_eq_#{named_type_c_name(variant)}"
          end

          def nullable_value_type?(type)
            type.is_a?(Types::Nullable) && !c_backend_pointer_like_type?(type.base)
          end

          def nullable_null_comparison?(expression)
            return false unless EQUALITY_OPERATORS.include?(expression.operator)

            (nullable_value_type?(expression.left.type) && expression.right.is_a?(IR::NullLiteral)) ||
              (nullable_value_type?(expression.right.type) && expression.left.is_a?(IR::NullLiteral))
          end

          def emit_nullable_null_comparison(expression)
            operand = expression.left.is_a?(IR::NullLiteral) ? expression.right : expression.left
            access = "#{wrap_member_receiver(operand)}.has_value"
            expression.operator == "==" ? "!#{access}" : access
          end

          def emit_initializer(expression)
            case expression
            when IR::ArrayLiteral
              emit_array_initializer(expression)
            when IR::AggregateLiteral
              emit_aggregate_initializer(expression)
            when IR::VariantLiteral
              emit_variant_initializer(expression)
            when IR::StringLiteral
              expression.type.is_a?(Types::StringView) ? emit_str_initializer(expression) : emit_expression(expression)
            when IR::ZeroInit
              emit_zero_initializer(expression.type)
            else
              emit_expression(expression)
            end
          end

          def emit_aggregate_initializer(expression)
            return emit_zero_initializer(expression.type) if expression.fields.empty?

            fields = expression.fields.map do |field|
              ".#{field.name} = #{emit_aggregate_field_initializer(expression.type, field)}"
            end.join(", ")
            "{ #{fields} }"
          end

          def emit_variant_initializer(expression)
            outer_c = named_type_c_name(expression.type)
            kind_constant = "#{outer_c}_kind_#{expression.arm_name}"
            if expression.fields.empty?
              "{ .kind = #{kind_constant} }"
            else
              payload_fields = expression.fields.map { |field| ".#{field.name} = #{emit_variant_field_initializer(expression.type, expression.arm_name, field)}" }.join(", ")
              "{ .kind = #{kind_constant}, .data.#{sanitize_c_identifier(expression.arm_name)} = { #{payload_fields} } }"
            end
          end

          def emit_str_initializer(expression)
            if @str_literal_map && @str_literal_map[expression.value]
              @str_literal_map[expression.value]
            else
              "{ .data = #{expression.value.inspect}, .len = #{expression.value.bytesize} }"
            end
          end

          def emit_aggregate_literal(expression)
            return emit_zero_expression(expression.type) if expression.fields.empty?

            fields = expression.fields.map do |field|
              ".#{field.name} = #{emit_aggregate_field_initializer(expression.type, field)}"
            end.join(", ")
            "(#{c_type(expression.type)}){ #{fields} }"
          end

          def emit_variant_literal(expression)
            outer_c = named_type_c_name(expression.type)
            kind_constant = "#{outer_c}_kind_#{expression.arm_name}"
            if expression.fields.empty?
              "(#{outer_c}){ .kind = #{kind_constant} }"
            else
              arm_c = "#{outer_c}_#{expression.arm_name}"
              payload_fields = expression.fields.map { |field| ".#{field.name} = #{emit_variant_field_initializer(expression.type, expression.arm_name, field)}" }.join(", ")
              "(#{outer_c}){ .kind = #{kind_constant}, .data.#{sanitize_c_identifier(expression.arm_name)} = (struct #{arm_c}){ #{payload_fields} } }"
            end
          end

          def emit_call_expression(expression, array_out_argument: nil)
            callee = expression.callee.is_a?(String) ? expression.callee : emit_call_callee(expression.callee)
            omit_receiver = omitted_method_receiver_call?(expression)
            arguments = []
            arguments << array_out_argument if array_out_argument
            arguments.concat(expression.arguments.drop(omit_receiver ? 1 : 0).map { |argument| emit_expression(argument) })
            call = "#{callee}(#{arguments.join(', ')})"
            return call unless omit_receiver && expression.arguments.any?
            return call if side_effect_free_expression?(expression.arguments.first)

            "(#{discarded_expression(expression.arguments.first)}, #{call})"
          end

          def emit_array_call_statement(expression, out_argument, indent)
            "#{indent}#{emit_call_expression(expression, array_out_argument: out_argument)};"
          end

          def emit_array_copy_statement(destination, source, indent)
            "#{indent}memcpy(#{destination}, #{emit_expression(source)}, sizeof(#{destination}));"
          end

          def emit_array_return(expression, indent)
            if expression.is_a?(IR::Call) && array_type?(expression.type)
              return [emit_array_call_statement(expression, ARRAY_OUT_PARAM_NAME, indent), "#{indent}return;"]
            end

            [
              emit_array_copy_statement("*#{ARRAY_OUT_PARAM_NAME}", expression, indent),
              "#{indent}return;",
            ]
          end

          def emitted_function_params(function)
            omitted_method_receiver_function?(function) ? function.params.drop(1) : function.params
          end

          def omitted_method_receiver_call?(expression)
            expression.callee.is_a?(String) && omitted_method_receiver_function_names.key?(expression.callee)
          end

          def omitted_method_receiver_function_names
            @omitted_method_receiver_function_names ||= emitted_functions.each_with_object({}) do |function, omitted|
              omitted[function.linkage_name] = true if omitted_method_receiver_function?(function)
            end
          end

          def omitted_method_receiver_function?(function)
            function.method_receiver_param &&
              function.params.first &&
              name_reference_count_in_statements(function.body, function.params.first.linkage_name).zero?
          end

          def discarded_expression(expression)
            "(void)#{wrap_expression(expression)}"
          end

          def emit_address_of_operand(expression)
            return emit_expression(expression.operand) if expression.is_a?(IR::Unary) && expression.operator == "*"

            "&#{wrap_expression(expression)}"
          end

          def emit_cast_operand(expression)
            case expression
            when IR::Name, IR::IntegerLiteral, IR::FloatLiteral, IR::StringLiteral, IR::BooleanLiteral, IR::NullLiteral, IR::ZeroInit, IR::Member, IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex, IR::Call, IR::AggregateLiteral, IR::ArrayLiteral, IR::ReinterpretExpr, IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr, IR::AddressOf, IR::Cast, IR::Unary
              emit_expression(expression)
            else
              "(#{emit_expression(expression)})"
            end
          end

          def emit_call_callee(expression)
            case expression
            when IR::Name, IR::Member, IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex, IR::NullableIndex, IR::NullableSpanIndex, IR::Call
              emit_expression(expression)
            else
              wrap_expression(expression)
            end
          end

          def emit_array_out_argument(destination)
            "&#{destination}"
          end

          def emit_array_initializer(expression)
            return "{ 0 }" if expression.elements.empty?

            elements = expression.elements.map { |element| emit_initializer(element) }.join(", ")
            "{ #{elements} }"
          end

          def emit_array_compound_literal(expression)
            "(#{c_declaration(expression.type, '')}) #{emit_array_initializer(expression)}"
          end

          def emit_zero_initializer(type)
            return "{ 0 }" if type.is_a?(Types::StringView)
            return "{ 0 }" if array_type?(type)
            return "NULL" if type.is_a?(Types::Nullable) && c_backend_pointer_like_type?(type.base)
            return "{ 0 }" if type.is_a?(Types::Nullable)
            return "NULL" if raw_pointer_type?(type) || ref_type?(type)
            return "NULL" if type.is_a?(Types::Opaque) && !type.external
            return "false" if type.is_a?(Types::Primitive) && type.boolean?
            return "0.0" if type.is_a?(Types::Primitive) && type.float?
            return "0" if type.is_a?(Types::Primitive) && !type.void?
            return "(#{c_type(type)}) 0" if type.is_a?(Types::EnumBase)

            "{ 0 }"
          end

          def emit_zero_expression(type)
            return "(#{c_type(type)}) #{emit_zero_initializer(type)}" if type.is_a?(Types::StringView)
            return "NULL" if type.is_a?(Types::Nullable) && c_backend_pointer_like_type?(type.base)
            return "(#{c_type(type)}){ 0 }" if type.is_a?(Types::Nullable)
            return emit_zero_initializer(type) if type.is_a?(Types::Primitive)
            return emit_zero_initializer(type) if type.is_a?(Types::EnumBase)

            "(#{c_declaration(type, '')}) #{emit_zero_initializer(type)}"
          end

          def aggregate_field_type(type, field_name)
            return proc_field_types(type).fetch(field_name) if type.is_a?(Types::Proc)
            if type.is_a?(Types::Nullable)
              return Types::Registry.primitive("bool") if field_name == "has_value"
              return type.base if field_name == "value"
            end
            return type.field(field_name) if type.respond_to?(:field)

            raise CBackendError, "unsupported aggregate field lookup for #{type}"
          end

          def emit_aggregate_field_initializer(type, field)
            field_type = aggregate_field_type(type, field.name)
            if field_type.is_a?(Types::Nullable) && !field.value.type.is_a?(Types::Nullable) && !c_backend_pointer_like_type?(field_type.base)
              emit_nullable_some_initializer(field_type, field.value)
            elsif void_storage_field?(field_type)
              emit_void_field_initializer(field.value)
            else
              emit_initializer(field.value)
            end
          end

          def emit_nullable_some_initializer(nullable_type, value)
            "(#{c_type(nullable_type)}){ .has_value = true, .value = #{emit_initializer(value)} }"
          end

          def emit_variant_field_initializer(type, arm_name, field)
            field_type = type.arm(arm_name).fetch(field.name)
            if field_type.is_a?(Types::Nullable) && !field.value.type.is_a?(Types::Nullable) && !c_backend_pointer_like_type?(field_type.base)
              emit_nullable_some_initializer(field_type, field.value)
            elsif field.value.is_a?(IR::AddressOf) && !field_type.is_a?(Types::Nullable)
              c_type_name = named_type_c_name(field_type)
              inner = field.value.expression
              "((#{c_type_name}*)memcpy(malloc(sizeof(#{c_type_name})), &(#{emit_expression(inner)}), sizeof(#{c_type_name})))"
            elsif void_storage_field?(field_type)
              emit_void_field_initializer(field.value)
            else
              emit_initializer(field.value)
            end
          end

          def emit_void_field_initializer(expression)
            "(#{emit_expression(expression)}, 0)"
          end

          def void_storage_field?(type)
            type.is_a?(Types::Primitive) && type.void?
          end

          def emit_str_literal(expression)
            if @str_literal_map && @str_literal_map[expression.value]
              @str_literal_map[expression.value]
            else
              "(mt_str){ .data = #{expression.value.inspect}, .len = #{expression.value.bytesize} }"
            end
          end

          def emit_float_literal(expression)
            value = expression.value
            literal = if value.finite? && value == value.to_i
                        format("%.1f", value)
                      else
                        value.to_s
                      end
            expression.type.name == "float" ? "#{literal}f" : literal
          end

          def wrap_expression(expression)
            case expression
            when IR::Name, IR::IntegerLiteral, IR::FloatLiteral, IR::StringLiteral, IR::BooleanLiteral, IR::NullLiteral, IR::ZeroInit, IR::Member, IR::Index, IR::Call, IR::AggregateLiteral, IR::ArrayLiteral, IR::ReinterpretExpr, IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
              emit_expression(expression)
            else
              "(#{emit_expression(expression)})"
            end
          end

          def layout_type_expression(type)
            c_declaration(type, "")
          end
    end
  end
end
