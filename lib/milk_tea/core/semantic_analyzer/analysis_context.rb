# frozen_string_literal: true

module MilkTea
  class SemanticAnalyzer
    class Checker
      private

      def with_unsafe
        @unsafe_depth += 1
        yield
      ensure
        @unsafe_depth -= 1
      end

      def mark_current_unsafe_required!
        current_line = @unsafe_statement_lines.last
        return unless current_line

        @required_unsafe_lines << current_line
      end

      def require_unsafe!(message, line: nil, column: nil)
        if unsafe_context?
          mark_current_unsafe_required!
          return
        end

        suggestion = "wrap in an unsafe block: `unsafe: <expression>`"
        if line || column
          raise SemanticError.new(message, line:, column:, path: @path, suggestion:)
        end

        raise_sema_error(message, suggestion:)
      end

      def with_foreign_mapping_context
        @foreign_mapping_depth += 1
        yield
      ensure
        @foreign_mapping_depth -= 1
      end

      def with_async_function
        @async_function_depth += 1
        yield
      ensure
        @async_function_depth -= 1
      end

      def with_loop
        @loop_depth += 1
        yield
      ensure
        @loop_depth -= 1
      end

      def with_compile_time
        @compile_time_depth += 1
        yield
      ensure
        @compile_time_depth -= 1
      end

      # Tracks the innermost value scopes during body checking so that
      # `resolve_type_ref` can resolve a compile-time reflection type expression
      # (e.g. `field.type` inside an `inline for`) by evaluating it against the
      # local bindings in scope. Nil outside body checking.
      def with_type_resolution_scopes(scopes)
        saved = @type_resolution_scopes
        @type_resolution_scopes = scopes
        yield
      ensure
        @type_resolution_scopes = saved
      end

      def with_loop_barrier
        previous_loop_depth = @loop_depth
        @loop_depth = 0
        yield
      ensure
        @loop_depth = previous_loop_depth
      end

      def unsafe_context?
        @unsafe_depth.positive?
      end

      def inside_async_function?
        @async_function_depth.positive?
      end

      def inside_loop?
        @loop_depth.positive?
      end

      def foreign_mapping_context?
        @foreign_mapping_depth.positive?
      end

      def with_return_context(return_type, allow_return:)
        @return_context_stack << { return_type:, allow_return: }
        yield
      ensure
        @return_context_stack.pop
      end

      def current_return_context
        @return_context_stack.last
      end

      def with_scope(bindings)
        scope = {}
        bindings.each do |binding|
          raise_sema_error("duplicate local #{binding.name}") if scope.key?(binding.name)

          scope[binding.name] = binding
        end

        yield([scope])
      end

      def with_nested_scope(scopes)
        nested_scopes = scopes + [{}]
        yield(nested_scopes)
      end

      def validate_async_function_body!(statements)
        statements.each { |statement| validate_async_statement!(statement) }
      end

      def validate_async_statement!(statement)
        case statement
        when AST::ErrorBlockStmt
          if statement.header_expression
            context = case statement.header_type
                      when :if then "if conditions"
                      when :while then "while conditions"
                      end
            validate_async_expression_support!(statement.header_expression, context:) if context
          end
          if statement.header_type == :for
            Array(statement.header_iterables).each do |iterable|
              validate_async_expression_support!(iterable, context: "for iterables")
            end
          end
          statement.body.each { |s| validate_async_statement!(s) }
        when AST::ErrorStmt
          nil
        when AST::LocalDecl
          validate_async_expression_support!(statement.value, context: "local initializer") if statement.value
          statement.else_body&.each { |s| validate_async_statement!(s) }
        when AST::Assignment
          validate_async_expression_support!(statement.target, context: "assignment target")
          validate_async_expression_support!(statement.value, context: "assignment")
        when AST::ExpressionStmt
          validate_async_expression_support!(statement.expression, context: "expression statement")
        when AST::ReturnStmt
          return unless statement.value

          validate_async_expression_support!(statement.value, context: "return statement")
        when AST::IfStmt
          statement.branches.each do |branch|
            validate_async_expression_support!(branch.condition, context: "if conditions")

            branch.body.each { |s| validate_async_statement!(s) }
          end
          statement.else_body&.each { |s| validate_async_statement!(s) }
        when AST::WhileStmt
          validate_async_expression_support!(statement.condition, context: "while conditions")

          statement.body.each { |s| validate_async_statement!(s) }
        when AST::ForStmt
          statement.iterables.each do |iterable|
            validate_async_expression_support!(iterable, context: "for iterables")
          end

          statement.body.each { |s| validate_async_statement!(s) }
        when AST::MatchStmt
          validate_async_expression_support!(statement.expression, context: "match discriminants")

          statement.arms.each { |arm| arm.body.each { |s| validate_async_statement!(s) } }
        when AST::UnsafeStmt
          statement.body.each { |s| validate_async_statement!(s) }
        when AST::DeferStmt
          validate_async_expression_support!(statement.expression, context: "defer cleanup") if statement.expression
          statement.body&.each { |s| validate_async_statement!(s) }
        when AST::WhenStmt
          statement.branches.each { |branch| branch.body.each { |s| validate_async_statement!(s) } }
          statement.else_body&.each { |s| validate_async_statement!(s) }
        when AST::BreakStmt, AST::ContinueStmt, AST::StaticAssert, AST::PassStmt
          nil
        else
          raise_sema_error("async functions currently only support straight-line local declarations, assignments, expression statements, and return statements")
        end
      end

      def validate_async_expression_support!(expression, context:)
        unsupported_context = unsupported_async_await_context(expression)
        return unless unsupported_context

        raise_sema_error("await in async functions is not supported inside #{unsupported_context} yet")
      end

      def unsupported_async_await_context(expression)
        nil
      end

      def statement_contains_await?(statement)
        case statement
        when AST::ErrorBlockStmt
          (statement.header_expression && expression_contains_await?(statement.header_expression)) ||
            Array(statement.header_iterables).any? { |iterable| expression_contains_await?(iterable) } ||
            statements_contain_await?(statement.body)
        when AST::LocalDecl
          (statement.value && expression_contains_await?(statement.value)) ||
            (statement.else_body && statements_contain_await?(statement.else_body))
        when AST::Assignment
          expression_contains_await?(statement.target) || expression_contains_await?(statement.value)
        when AST::IfStmt
          statement.branches.any? { |branch| expression_contains_await?(branch.condition) || statements_contain_await?(branch.body) } ||
            (statement.else_body && statements_contain_await?(statement.else_body))
        when AST::MatchStmt
          expression_contains_await?(statement.expression) || statement.arms.any? { |arm| expression_contains_await?(arm.pattern) || statements_contain_await?(arm.body) }
        when AST::UnsafeStmt
          statements_contain_await?(statement.body)
        when AST::StaticAssert
          expression_contains_await?(statement.condition) || expression_contains_await?(statement.message)
        when AST::ForStmt
          statement.iterables.any? { |iterable| expression_contains_await?(iterable) } || statements_contain_await?(statement.body)
        when AST::WhileStmt
          expression_contains_await?(statement.condition) || statements_contain_await?(statement.body)
        when AST::ReturnStmt
          statement.value && expression_contains_await?(statement.value)
        when AST::DeferStmt
          (statement.expression && expression_contains_await?(statement.expression)) || (statement.body && statements_contain_await?(statement.body))
        when AST::ExpressionStmt
          expression_contains_await?(statement.expression)
        else
          false
        end
      end

      def statements_contain_await?(statements)
        statements.any? { |statement| statement_contains_await?(statement) }
      end

      def expression_contains_await?(expression)
        case expression
        when AST::AwaitExpr
          true
        when AST::Call, AST::Specialization
          expression_contains_await?(expression.callee) || expression.arguments.any? { |argument| expression_contains_await?(argument.value) }
        when AST::UnaryOp
          expression_contains_await?(expression.operand)
        when AST::BinaryOp
          expression_contains_await?(expression.left) || expression_contains_await?(expression.right)
        when AST::IfExpr
          expression_contains_await?(expression.condition) || expression_contains_await?(expression.then_expression) || expression_contains_await?(expression.else_expression)
        when AST::MatchExpr
          expression_contains_await?(expression.expression) || expression.arms.any? { |arm| expression_contains_await?(arm.pattern) || expression_contains_await?(arm.value) }
        when AST::UnsafeExpr
          expression_contains_await?(expression.expression)
        when AST::PrefixCast
          expression_contains_await?(expression.expression)
        when AST::MemberAccess
          expression_contains_await?(expression.receiver)
        when AST::IndexAccess
          expression_contains_await?(expression.receiver) || expression_contains_await?(expression.index)
        when AST::FormatString
          expression.parts.any? { |part| part.is_a?(AST::FormatExprPart) && expression_contains_await?(part.expression) }
        else
          false
        end
      end

      def suggest_name(wrong, candidates, max_distance: 2)
        return nil if wrong.nil? || wrong.to_s.empty? || candidates.nil? || candidates.empty?

        wrong_str = wrong.to_s
        closest = nil
        closest_dist = max_distance + 1
        candidates.each do |candidate|
          next if candidate.nil?
          cand_str = candidate.to_s
          next if cand_str.empty? || cand_str == wrong_str
          dist = levenshtein(wrong_str, cand_str)
          if dist < closest_dist
            closest_dist = dist
            closest = cand_str
          end
        end
        closest_dist <= max_distance ? closest : nil
      end

      def levenshtein(s, t)
        m = s.length
        n = t.length
        return m if n.zero?
        return n if m.zero?
        d = Array.new(m + 1) { Array.new(n + 1, 0) }
        (0..m).each { |i| d[i][0] = i }
        (0..n).each { |j| d[0][j] = j }
        (1..m).each do |i|
          (1..n).each do |j|
            cost = s[i - 1] == t[j - 1] ? 0 : 1
            d[i][j] = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost].min
          end
        end
        d[m][n]
      end

    end
  end
end
