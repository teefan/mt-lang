# frozen_string_literal: true

module MilkTea
  class CBackend
    module CBackendReinterpret
      private


          def collect_reinterpret_helpers
            helpers = []
            seen = {}

            emitted_functions.each do |function|
              collect_reinterpret_helpers_from_statements(function.body, helpers, seen)
            end

            helpers
          end

          def collect_reinterpret_helpers_from_statements(statements, helpers, seen)
            statements.each do |statement|
              case statement
              when IR::LocalDecl
                collect_reinterpret_helpers_from_expression(statement.value, helpers, seen)
              when IR::Assignment
                collect_reinterpret_helpers_from_expression(statement.target, helpers, seen)
                collect_reinterpret_helpers_from_expression(statement.value, helpers, seen)
              when IR::BlockStmt
                collect_reinterpret_helpers_from_statements(statement.body, helpers, seen)
              when IR::WhileStmt
                collect_reinterpret_helpers_from_expression(statement.condition, helpers, seen)
                collect_reinterpret_helpers_from_statements(statement.body, helpers, seen)
              when IR::ForStmt
                collect_reinterpret_helpers_from_statements([statement.init], helpers, seen)
                collect_reinterpret_helpers_from_expression(statement.condition, helpers, seen)
                collect_reinterpret_helpers_from_statements(statement.body, helpers, seen)
                collect_reinterpret_helpers_from_statements([statement.post], helpers, seen)
              when IR::IfStmt
                collect_reinterpret_helpers_from_expression(statement.condition, helpers, seen)
                collect_reinterpret_helpers_from_statements(statement.then_body, helpers, seen)
                collect_reinterpret_helpers_from_statements(statement.else_body, helpers, seen) if statement.else_body
              when IR::SwitchStmt
                collect_reinterpret_helpers_from_expression(statement.expression, helpers, seen)
                statement.cases.each do |switch_case|
                  collect_reinterpret_helpers_from_statements(switch_case.body, helpers, seen)
                end
              when IR::StaticAssert
                collect_reinterpret_helpers_from_expression(statement.condition, helpers, seen)
                collect_reinterpret_helpers_from_expression(statement.message, helpers, seen)
              when IR::ReturnStmt
                collect_reinterpret_helpers_from_expression(statement.value, helpers, seen) if statement.value
              when IR::ExpressionStmt
                collect_reinterpret_helpers_from_expression(statement.expression, helpers, seen)
              end
            end
          end

          def collect_reinterpret_helpers_from_expression(expression, helpers, seen)
            case expression
            when IR::Member
              collect_reinterpret_helpers_from_expression(expression.receiver, helpers, seen)
            when IR::Index, IR::CheckedIndex, IR::CheckedSpanIndex
              collect_reinterpret_helpers_from_expression(expression.receiver, helpers, seen)
              collect_reinterpret_helpers_from_expression(expression.index, helpers, seen)
            when IR::Call
              collect_reinterpret_helpers_from_expression(expression.callee, helpers, seen) unless expression.callee.is_a?(String)
              expression.arguments.each { |argument| collect_reinterpret_helpers_from_expression(argument, helpers, seen) }
            when IR::Unary
              collect_reinterpret_helpers_from_expression(expression.operand, helpers, seen)
            when IR::Binary
              collect_reinterpret_helpers_from_expression(expression.left, helpers, seen)
              collect_reinterpret_helpers_from_expression(expression.right, helpers, seen)
            when IR::Conditional
              collect_reinterpret_helpers_from_expression(expression.condition, helpers, seen)
              collect_reinterpret_helpers_from_expression(expression.then_expression, helpers, seen)
              collect_reinterpret_helpers_from_expression(expression.else_expression, helpers, seen)
            when IR::ReinterpretExpr
              return if no_op_reinterpret?(expression.target_type, expression.source_type)

              key = [expression.target_type, expression.source_type]
              unless seen[key]
                helpers << expression
                seen[key] = true
              end
              collect_reinterpret_helpers_from_expression(expression.expression, helpers, seen)
            when IR::AddressOf
              collect_reinterpret_helpers_from_expression(expression.expression, helpers, seen)
            when IR::Cast
              collect_reinterpret_helpers_from_expression(expression.expression, helpers, seen)
            when IR::AggregateLiteral
              expression.fields.each { |field| collect_reinterpret_helpers_from_expression(field.value, helpers, seen) }
            when IR::ArrayLiteral
              expression.elements.each { |element| collect_reinterpret_helpers_from_expression(element, helpers, seen) }
            when IR::VariantLiteral
              expression.fields.each { |field| collect_reinterpret_helpers_from_expression(field.value, helpers, seen) }
            when IR::ZeroInit, IR::IntegerLiteral, IR::FloatLiteral, IR::StringLiteral, IR::BooleanLiteral, IR::NullLiteral, IR::Name, IR::SizeofExpr, IR::AlignofExpr, IR::OffsetofExpr
              nil
            end
          end

          def emit_reinterpret_helper(expression)
            helper_name = reinterpret_helper_name(expression.target_type, expression.source_type)
            params = c_declaration(expression.source_type, 'value')
            [
              "static inline #{c_function_declaration(expression.target_type, helper_name, params)} {",
              "#{INDENT}_Static_assert(sizeof(#{layout_type_expression(expression.target_type)}) == sizeof(#{layout_type_expression(expression.source_type)}), \"reinterpret requires equal sizes\");",
              "#{INDENT}#{c_declaration(expression.target_type, 'result')};",
              "#{INDENT}memcpy(&result, &value, sizeof(result));",
              "#{INDENT}return result;",
              "}",
            ]
          end

          def reinterpret_helper_name(target_type, source_type)
            "mt_reinterpret_#{sanitize_identifier(target_type.to_s)}_from_#{sanitize_identifier(source_type.to_s)}"
          end

          def no_op_cast?(expression)
            return false if expression.expression.type.is_a?(Types::Null)

            c_type(expression.target_type) == c_type(expression.expression.type)
          rescue StandardError
            false
          end

          def no_op_reinterpret?(target_type, source_type)
            c_type(target_type) == c_type(source_type)
          end

          def checked_array_index_helper_name(type)
            return "mt_checked_index_array_#{sanitize_identifier(c_declaration(array_element_type(type), 'value'))}_#{array_length(type)}" if array_type?(type) && callable_container_element_type?(array_element_type(type))

            "mt_checked_index_#{sanitize_identifier(type.to_s)}"
          end

          def checked_span_index_helper_name(type)
            return "mt_checked_span_index_#{sanitize_identifier(c_declaration(type.element_type, 'value'))}" if callable_container_element_type?(type.element_type)

            "mt_checked_span_index_#{sanitize_identifier(type.to_s)}"
          end

          def callable_container_element_type?(type)
            type.is_a?(Types::Function) || type.is_a?(Types::Proc)
          end

          def wrap_member_receiver(expression)
            case expression
            when IR::Unary
              if expression.operator == "*"
                wrap_pointer_member_receiver(expression.operand)
              else
                "(#{emit_expression(expression)})"
              end
            when IR::CheckedIndex, IR::CheckedSpanIndex
              checked_index_alias(expression) || emit_expression(expression)
            when IR::Name, IR::Member, IR::Index
              emit_expression(expression)
            else
              "(#{emit_expression(expression)})"
            end
          end

          def pointer_member_receiver?(expression)
            return true if checked_index_alias(expression)
            return true if expression.is_a?(IR::Unary) && expression.operator == "*"

            (expression.is_a?(IR::Name) && expression.pointer) ||
              (expression.respond_to?(:type) && (raw_pointer_type?(expression.type) || ref_type?(expression.type)))
          end

          def wrap_pointer_member_receiver(expression)
            case expression
            when IR::CheckedIndex, IR::CheckedSpanIndex
              checked_index_alias(expression) || emit_expression(expression)
            when IR::Name, IR::Member, IR::Index, IR::Call
              emit_expression(expression)
            else
              "(#{emit_expression(expression)})"
            end
          end

          def wrap_index_receiver(expression)
            case expression
            when IR::CheckedIndex, IR::CheckedSpanIndex
              if (alias_name = checked_index_alias(expression))
                "(*#{alias_name})"
              else
                emit_expression(expression)
              end
            when IR::Name, IR::Member, IR::Index, IR::Call
              emit_expression(expression)
            else
              "(#{emit_expression(expression)})"
            end
          end

          def c_operator(operator)
            operator == "and" ? "&&" : operator == "or" ? "||" : operator
          end

          def void_type
            @void_type ||= Types::Primitive.new("void")
          end
    end
  end
end
