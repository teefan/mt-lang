# frozen_string_literal: true

module MilkTea
  module Parse
    module Statements
      private

      def check_inline_stmt_start?
        return false unless check(:inline)

        next_idx = @current + 1
        return false if next_idx >= @tokens.length

        next_token = @tokens[next_idx]
        %i[for while match if].include?(next_token.type)
      end

      def check_parallel_for_start?
        return false unless check(:parallel)

        next_idx = @current + 1
        return false if next_idx >= @tokens.length

        @tokens[next_idx].type == :for
      end

      def check_parallel_block_start?
        return false unless check(:parallel)

        next_idx = @current + 1
        return false if next_idx >= @tokens.length

        @tokens[next_idx].type == :colon
      end

      def check_when_start?
        check(:when)
      end

      def parse_statement
        if match(:let)
          parse_local_decl(:let)
        elsif match(:var)
          parse_local_decl(:var)
        elsif match(:if)
          parse_if_stmt
        elsif match(:match)
          parse_match_stmt
        elsif match(:unsafe)
          parse_unsafe_stmt
        elsif match(:static_assert)
          parse_static_assert
        elsif match(:emit)
          parse_emit_stmt
        elsif match(:for)
          parse_for_stmt
        elsif check_parallel_for_start?
          advance
          parse_parallel_for_stmt
        elsif check_parallel_block_start?
          advance
          parse_parallel_block_stmt
        elsif match(:gather)
          parse_gather_stmt
        elsif match(:while)
          parse_while_stmt
        elsif match(:pass)
          parse_pass_stmt
        elsif match(:break)
          parse_break_stmt
        elsif match(:continue)
          parse_continue_stmt
        elsif match(:return)
          parse_return_stmt
        elsif match(:defer)
          parse_defer_stmt
        elsif check_inline_stmt_start?
          advance
          parse_inline_stmt
        elsif check_when_start?
          advance
          parse_when_stmt
        else
          parse_assignment_or_expression_stmt
        end
      end

      def parse_local_decl(kind)
        line = previous.line
        name_token = nil
        name = nil
        var_type = nil

        destructure_bindings = nil
        destructure_type_name = nil
        if check(:lparen)
          destructure_bindings = parse_destructure_pattern
        elsif check_name && check_next(:lparen)
          destructure_type_name = advance.lexeme
          destructure_bindings = parse_destructure_pattern
        elsif check_name && check_next(:dot)
          parts = [advance.lexeme]
          while check(:dot)
            advance
            parts << consume_name("expected type name after '.' in destructure pattern").lexeme
          end
          if match(:lparen)
            destructure_type_name = parts.length == 1 ? parts[0].dup : parts
            destructure_bindings = parse_destructure_pattern
          else
            raise error(@tokens[@current], "expected '(' after type name in destructure pattern")
          end
        else
          name_token = consume_name("expected local variable name")
          name = name_token.lexeme
        end

        var_type = match(:colon) ? parse_type_ref : nil
        value = nil
        else_binding = nil
        else_body = nil
        else_started = false

        if destructure_bindings
          consume(:equal, "expected '=' after destructure pattern")
          value = parse_expression
          consume_end_of_statement
        elsif match(:equal)
          value = parse_expression
          if match(:else)
            else_started = true

            if match(:as)
              binding_token = consume_name("expected error binding name after 'as'")
              else_binding = AST::Identifier.new(name: binding_token.lexeme, line: binding_token.line, column: binding_token.column)
            end

            else_body = parse_block
          else
            consume_end_of_statement unless block_expression?(value)
          end
        else
          raise error(name_token, "local declaration without initializer requires a type") unless var_type

          consume_end_of_statement
        end

        AST::LocalDecl.new(kind:, name:, type: var_type, value:, else_binding:, else_body:, line:, column: name_token&.column || line, destructure_bindings:, destructure_type_name:)
      rescue ParseError => e
        raise unless @recovery_errors && name

        @recovery_errors << e
        synchronize_to_statement_boundary

        if else_started
          return AST::LocalDecl.new(
            kind:,
            name:,
            type: var_type,
            value:,
            else_binding:,
            else_body: nil,
            line:,
            column: name_token.column,
            recovered_else: true,
          )
        end

        AST::LocalDecl.new(
          kind:,
          name:,
          type: var_type,
          value: recovery_error_expr(e),
          else_binding: nil,
          else_body: nil,
          line:,
          column: name_token.column,
        )
      end

      def parse_destructure_pattern
        match(:lparen)
        bindings = []
        loop do
          token = consume_name("expected binding name in destructure pattern")
          bindings << token.lexeme
          break unless match(:comma)
        end
        consume(:rparen, "expected ')' after destructure pattern")
        bindings
      end

      def parse_if_stmt
        line = previous.line
        branches = [parse_if_branch(previous)]

        while check(:else) && check_next(:if)
          advance
          advance
          branches << parse_if_branch(previous)
        end

        else_line = nil
        else_column = nil
        else_body = if match(:else)
                      else_line = previous.line
                      else_column = previous.column
                      parse_else_branch_body
                    end
        AST::IfStmt.new(branches:, else_body:, line:, else_line:, else_column:)
      end

      def parse_if_branch(token)
        condition = nil
        condition = parse_expression
        body = if inline_block_body?
                 consume(:colon, "expected ':' after if condition")
                 @in_inline_block_body = true
                 result = [parse_statement]
                 @in_inline_block_body = false
                 result
               else
                 parse_block
               end
        AST::IfBranch.new(
          condition:,
          body:,
          line: token.line,
          column: token.column,
          length: token.lexeme.length,
        )
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        recovered_body = synchronize_to_statement_boundary
        raise unless recovered_body

        AST::IfBranch.new(
          condition: condition || recovery_error_expr(e),
          body: recovered_body,
          line: token.line,
          column: token.column,
          length: token.lexeme.length,
        )
      end

      def parse_else_branch_body
        if inline_block_body?
          consume(:colon, "expected ':' before else body")
          @in_inline_block_body = true
          result = [parse_statement]
          @in_inline_block_body = false
          result
        else
          parse_block
        end
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        recovered_body = synchronize_to_statement_boundary
        raise unless recovered_body

        recovered_body
      end

      def inline_block_body?
        check(:colon) && @current + 1 < @tokens.length && @tokens[@current + 1].type != :newline
      end

      def parse_match_stmt
        token = previous
        line = token.line
        expression = nil
        arms = []
        expression = parse_expression
        arms = parse_match_arms(arms)
        if arms.first&.is_a?(AST::MatchExprArm)
          expr = AST::MatchExpr.new(expression:, arms:, line:, column: token.column, length: token.lexeme.length)
          AST::ExpressionStmt.new(expression: expr, line:)
        else
          AST::MatchStmt.new(expression:, arms:, line:, column: token.column, length: token.lexeme.length)
        end
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        recovered_arms = synchronize_to_match_arm_boundary
        target_line = line
        if recovered_arms
          stmt =
            if recovered_arms.first&.is_a?(AST::MatchExprArm)
              expr = AST::MatchExpr.new(expression: expression || recovery_error_expr(e), arms: arms + recovered_arms, line: target_line, column: token.column, length: token.lexeme.length)
              AST::ExpressionStmt.new(expression: expr, line: target_line)
            else
              AST::MatchStmt.new(expression: expression || recovery_error_expr(e), arms: arms + recovered_arms, line: target_line, column: token.column, length: token.lexeme.length)
            end
          return stmt
        end

        recovery_error_stmt(e)
      end

      def parse_match_arms(arms = [])
        consume(:colon, "expected ':' before block")
        consume(:newline, "expected newline before block")
        consume(:indent, "expected indented block")

        parse_match_arm_body(arms)

        consume(:dedent, "expected end of block")
        arms
      end

      def parse_match_arm_body(arms = [])
        skip_newlines
        until check(:dedent) || eof?
          arms.concat(parse_match_arm)
          skip_newlines
        end

        arms
      end

      def parse_match_arm
        patterns = []
        binding_token = nil
        binding_name = nil

        if match(:else)
          patterns << AST::Identifier.new(name: "_", line: previous.line, column: previous.column)
        else
          patterns << parse_bitwise_xor
          while match(:pipe)
            patterns << parse_bitwise_xor
          end
        end
        binding_name = if match(:as)
                         binding_token = consume_name("expected binding name after 'as'")
                         binding_token.lexeme
                       end

        if match_arm_expr_form?
          consume(:colon, "expected ':' after match expression arm pattern")
          value = parse_expression
          consume_end_of_statement unless block_expression?(value)
          patterns.map do |pattern|
            AST::MatchExprArm.new(
              pattern:,
              binding_name:,
              binding_line: binding_token&.line,
              binding_column: binding_token&.column,
              value:,
            )
          end
        else
          body = parse_block
          patterns.map do |pattern|
            AST::MatchArm.new(
              pattern:,
              binding_name:,
              binding_line: binding_token&.line,
              binding_column: binding_token&.column,
              body:,
            )
          end
        end
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        recovered_body = synchronize_to_statement_boundary
        return [AST::MatchArm.new(
          pattern: patterns.first || recovery_error_expr(e),
          binding_name:,
          binding_line: binding_token&.line,
          binding_column: binding_token&.column,
          body: recovered_body,
        )] if recovered_body

        raise
      end

      def match_arm_expr_form?
        check(:colon) && @current + 1 < @tokens.length && @tokens[@current + 1].type != :newline
      end

      def parse_unsafe_stmt
        token = previous
        consume(:colon, "expected ':' after unsafe")
        body = if match(:newline)
                 consume(:indent, "expected indented block")

                 statements = parse_statement_block_body
                 consume(:dedent, "expected end of block")
                 statements
               else
                 statement = parse_statement
                 raise ParseError.new("inline unsafe local declarations must use expression form", token:, path: @path) if statement.is_a?(AST::LocalDecl)

                 [statement]
               end
        AST::UnsafeStmt.new(body:, line: token.line, column: token.column, length: token.lexeme.length)
      end

      def parse_static_assert
        line = previous.line
        consume(:lparen, "expected '(' after static_assert")
        condition = parse_expression
        consume(:comma, "expected ',' after static_assert condition")
        message = parse_expression
        consume(:rparen, "expected ')' after static_assert message")
        consume_end_of_statement
        AST::StaticAssert.new(condition:, message:, line:)
      end

      def parse_emit_stmt
        line = previous.line
        column = previous.column
        decl = parse_declaration
        AST::EmitStmt.new(declaration: decl, line:, column:)
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        synchronize_to_statement_boundary
        AST::EmitStmt.new(declaration: AST::ErrorExpr.new(message: e.message), line:, column:)
      end

      def parse_for_stmt
        line = previous.line
        bindings = []
        iterables = nil
        loop do
          name_token = consume_name("expected loop variable name")
          bindings << AST::ForBinding.new(name: name_token.lexeme, line: name_token.line, column: name_token.column)
          break unless match(:comma)
        end
        consume(:in, "expected 'in' in for loop")
        iterables = [parse_expression]
        iterables << parse_expression while match(:comma)
        body = parse_block
        AST::ForStmt.new(bindings:, iterables:, body:, line:, column: bindings.first.column)
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        recovered_body = synchronize_to_statement_boundary
        return recovery_error_block_stmt(
          e,
          recovered_body,
          header_type: :for,
          header_bindings: bindings.empty? ? nil : bindings,
          header_iterables: iterables&.any? ? iterables : nil,
        ) if recovered_body

        recovery_error_stmt(e)
      end

      def parse_parallel_for_stmt
        consume(:for, "expected 'for' after 'parallel'")
        line = previous.line
        name_token = consume_name("expected loop variable name")
        bindings = [AST::ForBinding.new(name: name_token.lexeme, line: name_token.line, column: name_token.column)]
        consume(:in, "expected 'in' in parallel for loop")
        iterables = [parse_expression]
        body = parse_block
        AST::ForStmt.new(bindings:, iterables:, body:, threaded: true, line:, column: bindings.first.column)
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        recovered_body = synchronize_to_statement_boundary
        return recovery_error_block_stmt(e, recovered_body, header_type: :for) if recovered_body

        recovery_error_stmt(e)
      end

      def parse_parallel_block_stmt
        line = previous.line
        column = previous.column
        consume(:colon, "expected ':' after 'parallel'")
        consume(:newline, "expected newline after 'parallel:'")
        consume(:indent, "expected indented block after 'parallel:'")
        statements = parse_statement_block_body
        consume(:dedent, "expected end of parallel block")
        bodies = statements.map { |stmt| [stmt] }
        AST::ParallelBlockStmt.new(bodies:, line:, column:)
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        recovered_body = synchronize_to_statement_boundary
        return recovery_error_block_stmt(e, recovered_body, header_type: :parallel) if recovered_body

        recovery_error_stmt(e)
      end

      def parse_gather_stmt
        line = previous.line
        column = previous.column
        handles = []
        handle = parse_expression
        handles << handle
        while match(:comma)
          handle = parse_expression
          handles << handle
        end
        AST::GatherStmt.new(handles:, line:, column:)
      end

      def parse_while_stmt
        token = previous
        line = token.line
        condition = parse_expression
        body = parse_block
        AST::WhileStmt.new(condition:, body:, line:, column: token.column, length: token.lexeme.length)
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        recovered_body = synchronize_to_statement_boundary
        return AST::WhileStmt.new(
          condition: condition || recovery_error_expr(e),
          body: recovered_body,
          line:,
          column: token.column,
          length: token.lexeme.length,
        ) if recovered_body

        recovery_error_stmt(e)
      end

      def parse_pass_stmt
        token = previous
        line = token.line
        consume_end_of_statement
        AST::PassStmt.new(line:, column: token.column, length: token.lexeme.length)
      end

      def parse_break_stmt
        token = previous
        line = token.line
        consume_end_of_statement
        AST::BreakStmt.new(line:, column: token.column, length: token.lexeme.length)
      end

      def parse_continue_stmt
        token = previous
        line = token.line
        consume_end_of_statement
        AST::ContinueStmt.new(line:, column: token.column, length: token.lexeme.length)
      end

      def parse_return_stmt
        token = previous
        line = token.line
        value = check(:newline) ? nil : parse_expression
        consume_end_of_statement unless block_expression?(value)
        AST::ReturnStmt.new(value:, line:, column: token.column, length: token.lexeme.length)
      end

      def parse_defer_stmt
        token = previous
        line = token.line
        if check(:colon)
          body = parse_block
          AST::DeferStmt.new(expression: nil, body:, line:, column: token.column, length: token.lexeme.length)
        else
          expression = parse_expression
          consume_end_of_statement unless block_expression?(expression)
          AST::DeferStmt.new(expression:, body: nil, line:, column: token.column, length: token.lexeme.length)
        end
      end

      def parse_when_decl
        token = previous
        line = token.line
        discriminant = parse_expression
        branches = parse_decl_when_arms
        else_body = if check(:else)
          if check_next(:newline) || check_next(:indent)
            parse_declaration_block
          end
        end
        AST::WhenStmt.new(discriminant:, branches:, else_body:, line:, column: token.column, length: token.lexeme.length)
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        recovered_body = synchronize_to_statement_boundary
        return recovery_error_block_stmt(e, recovered_body, header_type: :when) if recovered_body

        recovery_error_stmt(e)
      end

      def parse_decl_when_arms
        consume(:colon, "expected ':' before block")
        consume(:newline, "expected newline before block")
        consume(:indent, "expected indented block")

        arms = []
        skip_newlines
        until check(:dedent) || eof?
          pattern = parse_expression
          binding_name = if match(:as)
                            binding_token = consume_name("expected binding name after 'as'")
                            binding_token.lexeme
                          end
          body = parse_declaration_block
          binding_token ||= previous
          arms << AST::WhenBranch.new(
            pattern:,
            binding_name:,
            binding_line: binding_token.line,
            binding_column: binding_token.column,
            body:,
          )
          skip_newlines
        end

        consume(:dedent, "expected end of block")
        arms
      end

      def parse_when_stmt
        token = previous
        line = token.line
        discriminant = parse_expression
        branches = parse_match_arms([])
        else_body = if check(:else)
          if check_next(:newline) || check_next(:indent)
            parse_else_branch_body
          end
        end
        AST::WhenStmt.new(discriminant:, branches:, else_body:, line:, column: token.column, length: token.lexeme.length)
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        recovered_body = synchronize_to_statement_boundary
        return recovery_error_block_stmt(e, recovered_body, header_type: :when) if recovered_body

        recovery_error_stmt(e)
      end

      def parse_inline_stmt
        token = previous
        if match(:for)
          parse_inline_for_stmt(token)
        elsif match(:while)
          parse_inline_while_stmt(token)
        elsif match(:match)
          parse_inline_match_stmt(token)
        elsif match(:if)
          parse_inline_if_stmt(token)
        else
          raise error(peek, "expected for, while, match, or if after inline")
        end
      end

      def parse_inline_for_stmt(_inline_token)
        line = previous.line
        bindings = []
        iterables = nil
        loop do
          name_token = consume_name("expected loop variable name")
          bindings << AST::ForBinding.new(name: name_token.lexeme, line: name_token.line, column: name_token.column)
          break unless match(:comma)
        end
        consume(:in, "expected 'in' in for loop")
        iterables = [parse_expression]
        iterables << parse_expression while match(:comma)
        body = parse_block
        AST::ForStmt.new(bindings:, iterables:, body:, inline: true, line:, column: bindings.first.column)
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        recovered_body = synchronize_to_statement_boundary
        return recovery_error_block_stmt(e, recovered_body, header_type: :for) if recovered_body

        recovery_error_stmt(e)
      end

      def parse_inline_while_stmt(inline_token)
        line = inline_token.line
        condition = parse_expression
        body = parse_block
        AST::WhileStmt.new(condition:, body:, inline: true, line:, column: inline_token.column, length: inline_token.lexeme.length)
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        recovered_body = synchronize_to_statement_boundary
        return AST::WhileStmt.new(
          condition: condition || recovery_error_expr(e),
          body: recovered_body,
          line:,
          column: inline_token.column,
          length: inline_token.lexeme.length,
        ) if recovered_body

        recovery_error_stmt(e)
      end

      def parse_inline_match_stmt(inline_token)
        token = previous
        line = token.line
        arms = []
        expression = parse_expression
        arms = parse_match_arms(arms)
        AST::MatchStmt.new(expression:, arms:, inline: true, line:, column: token.column, length: token.lexeme.length)
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        recovered_arms = synchronize_to_match_arm_boundary
        return AST::MatchStmt.new(expression: expression || recovery_error_expr(e), arms: arms + recovered_arms, inline: true, line:, column: token.column, length: token.lexeme.length) if recovered_arms

        recovery_error_stmt(e)
      end

      def parse_inline_if_stmt(inline_token)
        token = previous
        line = token.line
        branches = [parse_if_branch(token)]

        while check(:else) && check_next(:if)
          advance
          advance
          branches << parse_if_branch(previous)
        end

        else_body = match(:else) ? parse_else_branch_body : nil
        AST::IfStmt.new(branches:, else_body:, inline: true, line:)
      end

      def parse_assignment_or_expression_stmt
        line = peek.line
        expression = parse_expression
        if match(*Token::ASSIGNMENT_TYPES)
          operator = previous.lexeme
          column = previous.column
          value = parse_expression
          consume_end_of_statement unless block_expression?(value)
          AST::Assignment.new(target: expression, operator:, value:, line:, column:)
        else
          consume_end_of_statement unless block_expression?(expression)
          AST::ExpressionStmt.new(expression:, line:)
        end
      end
    end
  end
end
