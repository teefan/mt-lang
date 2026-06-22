# frozen_string_literal: true

module MilkTea
  module Parse
    module Recovery
      TOP_LEVEL_RECOVERY_START_TYPES = %i[
        module import at public attribute const var type struct union enum flags variant interface
        opaque extending foreign async function event external static_assert link include compiler_flag
      ].freeze

      private

      def synchronize_to_top_level_boundary
        seen_newline = false

        until eof?
          token = peek

          if token.type == :newline
            seen_newline = true
            advance
            next
          end

          if %i[indent dedent].include?(token.type)
            advance
            next
          end

          break if seen_newline && top_level_recovery_start?(token)

          advance
        end
      end

      def synchronize_to_statement_boundary
        until eof?
          return recover_statement_block_body if check(:indent)
          return nil if check(:dedent)

          if check(:newline)
            advance
            return recover_statement_block_body if check(:indent)
            return nil
          end

          advance
        end

        nil
      end

      def synchronize_to_match_arm_boundary
        until eof?
          return nil if check(:dedent)

          if check(:newline)
            advance
            return recover_match_arm_block if check(:indent)
            return nil
          end

          advance
        end

        nil
      end

      def recover_statement_block_body
        advance if check(:indent)

        statements = parse_statement_block_body
        advance if check(:dedent)
        statements
      end

      def recover_match_arm_block
        advance if check(:indent)

        arms = parse_match_arm_body([])
        advance if check(:dedent)
        arms
      end

      def recovery_error_expr(error)
        token = error.token
        AST::ErrorExpr.new(
          line: token&.line,
          column: token&.column,
          length: token&.lexeme&.length,
          message: error.message,
        )
      end

      def recovery_error_stmt(error)
        token = error.token
        AST::ErrorStmt.new(
          line: token&.line,
          column: token&.column,
          length: token&.lexeme&.length,
          message: error.message,
        )
      end

      def recovery_error_block_stmt(error, body, header_type: nil, header_expression: nil, header_bindings: nil, header_iterables: nil)
        token = error.token
        AST::ErrorBlockStmt.new(
          body:,
          line: token&.line,
          column: token&.column,
          length: token&.lexeme&.length,
          message: error.message,
          header_type:,
          header_expression:,
          header_bindings:,
          header_iterables:,
        )
      end

      def recovery_statement_header_type(error)
        return :unsafe if previous&.type == :unsafe && error.message.include?("after unsafe")

        nil
      end

      def top_level_recovery_start?(token)
        token.column.to_i <= 1 && (TOP_LEVEL_RECOVERY_START_TYPES.include?(token.type) || legacy_layout_modifier_start?(token))
      end
    end
  end
end
