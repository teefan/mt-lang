# frozen_string_literal: true

module MilkTea
  module Lowering
    module Assertions
      ASSERT_CALL_NAMES = %w[assert expect expect_eq expect_ne].freeze

      # Lowers an `assert`/`expect`/`expect_eq`/`expect_ne` expression statement
      # into an `IR::IfStmt` whose then-branch aborts via `fatal`. The message is
      # only evaluated on the failing path so unused messages cost nothing.
      # Returns `nil` when the statement is not one of the assertion calls so the
      # caller can fall through to ordinary expression-statement lowering.
      def lower_assert_like_statement(statement, env:)
        kind = assert_like_call_kind(statement.expression)
        return nil unless kind

        arguments = statement.expression.arguments
        line = statement.expression.line
        column = statement.expression.column
        default_message = default_assert_message(kind, statement.line)

        condition_ast = nil
        message = nil
        case kind
        when "assert", "expect"
          condition_ast = unary_expression("not", arguments.fetch(0).value, line:, column:)
          message = arguments.length > 1 ? arguments.fetch(1).value : string_literal(default_message, line:, column:)
        when "expect_eq"
          condition_ast = binary_expression("!=", arguments.fetch(0).value, arguments.fetch(1).value, line:, column:)
          message = arguments.length > 2 ? arguments.fetch(2).value : string_literal(default_message, line:, column:)
        when "expect_ne"
          condition_ast = binary_expression("==", arguments.fetch(0).value, arguments.fetch(1).value, line:, column:)
          message = arguments.length > 2 ? arguments.fetch(2).value : string_literal(default_message, line:, column:)
        end

        # Hoist inline-proc/foreign-temporary setup out of the condition so the
        # failure check itself stays a plain `if (!cond)` in C.
        setup, prepared_condition, cleanups = prepare_expression_with_cleanups(
          condition_ast,
          env:,
          expected_type: @ctx.types.fetch("bool"),
        )

        [
          *setup,
          IR::IfStmt.new(
            condition: lower_expression(prepared_condition, env:, expected_type: @ctx.types.fetch("bool")),
            then_body: [lower_fatal_expression_statement(message, line:, column:, env:)],
            else_body: [],
          ),
          *cleanups.flat_map(&:itself),
        ]
      end

      def assert_like_call_kind(expression)
        return nil unless expression.is_a?(AST::Call)
        return nil unless expression.callee.is_a?(AST::Identifier)
        return nil unless ASSERT_CALL_NAMES.include?(expression.callee.name)

        expression.callee.name
      end

      def default_assert_message(kind, line)
        path = @ctx.current_analysis_path.to_s
        case kind
        when "assert" then "assertion failed at #{path}:#{line}"
        when "expect" then "expectation failed at #{path}:#{line}"
        when "expect_eq" then "expect_eq failed: values are not equal at #{path}:#{line}"
        when "expect_ne" then "expect_ne failed: values are equal at #{path}:#{line}"
        end
      end

      def lower_fatal_expression_statement(message, line:, column:, env:)
        fatal_call = AST::Call.new(
          callee: AST::Identifier.new(name: "fatal", line:, column:),
          arguments: [AST::Argument.new(name: nil, value: message, line:, column:)],
          line:,
          column:,
        )
        IR::ExpressionStmt.new(
          expression: lower_expression(fatal_call, env:, expected_type: @ctx.types.fetch("void")),
          line:,
          path: @ctx.current_analysis_path,
        )
      end

      def unary_expression(operator, operand, line:, column:)
        AST::UnaryOp.new(operator:, operand:, line:, column:)
      end

      def binary_expression(operator, left, right, line:, column:)
        AST::BinaryOp.new(operator:, left:, right:, line:, column:)
      end

      def string_literal(value, line:, column:)
        AST::StringLiteral.new(lexeme: value.inspect, value:, cstring: false, line:, column:)
      end
    end
  end
end
