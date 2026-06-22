# frozen_string_literal: true

require_relative "../types/layout"

module MilkTea
  module ConstEval
    module_function

    def evaluate(expression, resolve_identifier:, resolve_member_access:, resolve_type_ref: nil, resolve_call: nil)
      Evaluator.new(
        resolve_identifier:,
        resolve_member_access:,
        resolve_type_ref:,
        resolve_call:,
      ).evaluate(expression)
    end

    def equality_result(left, right)
      return left == right if left.is_a?(Numeric) && right.is_a?(Numeric)
      return left == right if left.is_a?(String) && right.is_a?(String)
      return left == right if boolean_value?(left) && boolean_value?(right)
      return left == right if left.is_a?(Types::Base) && right.is_a?(Types::Base)

      nil
    end

    def boolean_value?(value)
      value == true || value == false
    end

    class Evaluator
      include Layout

      def initialize(resolve_identifier:, resolve_member_access:, resolve_type_ref: nil, resolve_call: nil)
        @resolve_identifier = resolve_identifier
        @resolve_member_access = resolve_member_access
        @resolve_type_ref = resolve_type_ref
        @resolve_call = resolve_call
      end

      def evaluate(expression)
        case expression
        when AST::ErrorExpr
          nil
        when AST::ExpressionList
          expression.elements.filter_map { |element| evaluate(element) }
        when AST::IntegerLiteral, AST::FloatLiteral, AST::BooleanLiteral
          expression.value
        when AST::StringLiteral
          expression.value
        when AST::Identifier
          @resolve_identifier&.call(expression)
        when AST::MemberAccess
          @resolve_member_access&.call(expression)
        when AST::Call
          @resolve_call&.call(expression)
        when AST::Specialization
          @resolve_call&.call(expression)
        when AST::SizeofExpr
          type = resolve_layout_type(expression.type)
          type && size_of(type)
        when AST::AlignofExpr
          type = resolve_layout_type(expression.type)
          type && alignment_of(type)
        when AST::OffsetofExpr
          type = resolve_layout_type(expression.type)
          if type
            result = offset_of(type, expression.field)
            return result if result

            id_expr = AST::Identifier.new(name: expression.field)
            value = @resolve_identifier&.call(id_expr)
            if value.is_a?(Types::FieldHandle)
              return offset_of(type, value.field_name)
            end
          end
          nil
        when AST::UnaryOp
          evaluate_unary(expression)
        when AST::BinaryOp
          evaluate_binary(expression)
        when AST::IfExpr
          condition = evaluate(expression.condition)
          return unless ConstEval.boolean_value?(condition)

          evaluate(condition ? expression.then_expression : expression.else_expression)
        else
          nil
        end
      end

      private

      def resolve_layout_type(type_ref)
        return unless @resolve_type_ref

        @resolve_type_ref.call(type_ref)
      end

      def evaluate_unary(expression)
        operand = evaluate(expression.operand)

        case expression.operator
        when "+"
          operand.is_a?(Numeric) ? operand : nil
        when "-"
          operand.is_a?(Numeric) ? -operand : nil
        when "~"
          operand.is_a?(Integer) ? ~operand : nil
        when "not"
          ConstEval.boolean_value?(operand) ? !operand : nil
        end
      end

      def evaluate_binary(expression)
        left = evaluate(expression.left)

        case expression.operator
        when "and"
          return unless ConstEval.boolean_value?(left)
          return false if left == false

          right = evaluate(expression.right)
          return right if ConstEval.boolean_value?(right)

          return nil
        when "or"
          return unless ConstEval.boolean_value?(left)
          return true if left == true

          right = evaluate(expression.right)
          return right if ConstEval.boolean_value?(right)

          return nil
        end

        right = evaluate(expression.right)

        case expression.operator
        when "=="
          ConstEval.equality_result(left, right)
        when "!="
          result = ConstEval.equality_result(left, right)
          result.nil? ? nil : !result
        when "+"
          left.is_a?(Numeric) && right.is_a?(Numeric) ? left + right : nil
        when "-"
          left.is_a?(Numeric) && right.is_a?(Numeric) ? left - right : nil
        when "*"
          left.is_a?(Numeric) && right.is_a?(Numeric) ? left * right : nil
        when "/"
          return unless left.is_a?(Numeric) && right.is_a?(Numeric)
          return if zero_numeric?(right)

          left / right
        when "%"
          return unless left.is_a?(Integer) && right.is_a?(Integer)
          return if right.zero?

          left % right
        when "<<"
          left.is_a?(Integer) && right.is_a?(Integer) ? left << right : nil
        when ">>"
          left.is_a?(Integer) && right.is_a?(Integer) ? left >> right : nil
        when "&"
          left.is_a?(Integer) && right.is_a?(Integer) ? left & right : nil
        when "|"
          left.is_a?(Integer) && right.is_a?(Integer) ? left | right : nil
        when "^"
          left.is_a?(Integer) && right.is_a?(Integer) ? left ^ right : nil
        when "<"
          left.is_a?(Numeric) && right.is_a?(Numeric) ? left < right : nil
        when "<="
          left.is_a?(Numeric) && right.is_a?(Numeric) ? left <= right : nil
        when ">"
          left.is_a?(Numeric) && right.is_a?(Numeric) ? left > right : nil
        when ">="
          left.is_a?(Numeric) && right.is_a?(Numeric) ? left >= right : nil
        end
      end

      def zero_numeric?(value)
        (value.is_a?(Integer) && value.zero?) || (value.is_a?(Float) && value.zero?)
      end
    end
  end
end
