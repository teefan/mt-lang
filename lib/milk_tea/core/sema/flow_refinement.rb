# frozen_string_literal: true

module MilkTea
  class Sema
    class Checker
      private

      def current_actual_scope(scopes)
        scopes.reverse_each do |scope|
          return scope unless scope.is_a?(FlowScope)
        end

        raise_sema_error("missing lexical scope")
      end

      def apply_continuation_refinements!(scopes, refinements)
        return if refinements.nil? || refinements.empty?

        scopes.replace(scopes_with_refinements(scopes, refinements))
      end

      def scopes_with_refinements(scopes, refinements)
        return scopes if refinements.nil? || refinements.empty?

        base_scopes = scopes.last.is_a?(FlowScope) ? scopes[0...-1] : scopes
        merged_refinements = if scopes.last.is_a?(FlowScope)
                               scopes.last.each_with_object({}) do |(name, binding), result|
                                 result[name] = if name.is_a?(String) && binding.respond_to?(:type)
                                                  binding.type
                                                else
                                                  binding
                                                end
                               end
                             else
                               {}
                             end
        merged_refinements = merge_refinements(merged_refinements, refinements)
        flow_scope = FlowScope.new

        merged_refinements.each do |name, refined_type|
          unless name.is_a?(String)
            flow_scope[name] = refined_type
            next
          end

          binding = lookup_value(name, base_scopes)
          next unless binding

          flow_scope[name] = binding.with_flow_type(refined_type)
        end

        return base_scopes if flow_scope.empty?

        base_scopes + [flow_scope]
      end

      def merge_refinements(existing, incoming)
        merged = existing.dup
        incoming.each do |name, refined_type|
          if merged.key?(name) && merged[name] != refined_type
            merged.delete(name)
          else
            merged[name] = refined_type
          end
        end

        merged
      end

      def flow_refinements(expression, truthy:, scopes:)
        case expression
        when AST::Call
          if truthy && has_attribute_refinement_call?(expression)
            key = attribute_presence_key_from_call(expression, scopes:)
            return key ? { key => true } : {}
          end
        when AST::UnaryOp
          return flow_refinements(expression.operand, truthy: !truthy, scopes:) if expression.operator == "not"
        when AST::BinaryOp
          case expression.operator
          when "and"
            if truthy
              left_truthy = flow_refinements(expression.left, truthy: true, scopes:)
              right_scopes = scopes_with_refinements(scopes, left_truthy)
              right_truthy = flow_refinements(expression.right, truthy: true, scopes: right_scopes)
              return merge_refinements(left_truthy, right_truthy)
            end
          when "or"
            unless truthy
              left_falsy = flow_refinements(expression.left, truthy: false, scopes:)
              right_scopes = scopes_with_refinements(scopes, left_falsy)
              right_falsy = flow_refinements(expression.right, truthy: false, scopes: right_scopes)
              return merge_refinements(left_falsy, right_falsy)
            end
          when "==", "!="
            return null_test_refinements(expression, truthy:, scopes:)
          end
        end

        {}
      end

      def start_local_completion_frame(binding, scopes)
        frame = {
          function_name: binding.name,
          receiver_type: binding.type.receiver_type,
          snapshots: [],
        }
        @active_local_completion_stack << frame
        record_local_completion_snapshot(binding.ast.respond_to?(:line) ? binding.ast.line : nil, 0, scopes)
      end

      def finish_local_completion_frame(binding)
        return if @active_local_completion_stack.empty?

        frame = @active_local_completion_stack.pop
        snapshots = frame[:snapshots]
        if snapshots.empty?
          return
        end

        start_line = [binding.ast.respond_to?(:line) ? binding.ast.line : nil, snapshots.first.line].compact.min
        end_line = snapshots.last.line

        @local_completion_frames << LocalCompletionFrame.new(
          start_line:,
          end_line:,
          function_name: frame[:function_name],
          receiver_type: frame[:receiver_type],
          snapshots: snapshots.freeze,
        )
      end

      def record_local_completion_snapshot(line, column, scopes)
        return if @active_local_completion_stack.empty?
        return if line.nil?

        snapshot = LocalCompletionSnapshot.new(
          line:,
          column: (column || 0),
          bindings: merged_scope_bindings(scopes).freeze,
        )

        snapshots = @active_local_completion_stack.last[:snapshots]
        prev = snapshots.last
        if prev && prev.line == snapshot.line && prev.column == snapshot.column
          snapshots[-1] = snapshot
        else
          snapshots << snapshot
        end
      end

      def merged_scope_bindings(scopes)
        scopes.each_with_object({}) do |scope, bindings|
          scope.each do |name, binding|
            next unless name.is_a?(String)

            bindings[name] = binding
          end
        end
      end

      def has_attribute_refinement_call?(expression)
        expression.callee.is_a?(AST::Identifier) && expression.callee.name == "has_attribute" && expression.arguments.length == 2 && expression.arguments.none?(&:name)
      end

      def attribute_presence_key_from_call(expression, scopes:)
        target = resolve_reflection_target_argument(expression.arguments.first.value, scopes:)
        binding = resolve_attribute_name_argument(expression.arguments[1].value)
        validate_attribute_target_compatibility!(target, binding)
        attribute_presence_refinement_key(target, binding)
      rescue SemaError
        nil
      end

      def statement_end_line(statement)
        return nil unless statement

        lines = [statement.respond_to?(:line) ? statement.line : nil]

        case statement
        when AST::ErrorBlockStmt
          lines.concat(statement_list_lines(statement.body))
        when AST::LocalDecl
          lines << expression_end_line(statement.value) if statement.value
          lines.concat(statement_list_lines(statement.else_body)) if statement.else_body
        when AST::IfStmt
          statement.branches.each do |branch|
            lines << expression_end_line(branch.condition)
            lines.concat(statement_list_lines(branch.body))
          end
          lines.concat(statement_list_lines(statement.else_body)) if statement.else_body
        when AST::UnsafeStmt, AST::ForStmt, AST::WhileStmt
          lines.concat(statement_list_lines(statement.body))
        when AST::MatchStmt
          statement.arms.each do |arm|
            lines.concat(statement_list_lines(arm.body))
          end
        when AST::DeferStmt
          lines.concat(statement_list_lines(statement.body)) if statement.body
        when AST::Assignment
          lines << expression_end_line(statement.value)
        when AST::ReturnStmt
          lines << expression_end_line(statement.value)
        when AST::ExpressionStmt
          lines << expression_end_line(statement.expression)
        when AST::StaticAssert
          lines << expression_end_line(statement.condition)
        end

        lines.compact.max
      end

      def statement_list_lines(statements)
        return [] unless statements

        statements.each_with_object([]) do |stmt, lines|
          end_line = statement_end_line(stmt)
          lines << end_line if end_line
        end
      end

      def expression_end_line(node)
        return nil unless node

        lines = [node.respond_to?(:line) ? node.line : nil]

        case node
        when AST::MemberAccess
          lines << expression_end_line(node.receiver)
        when AST::IndexAccess
          lines << expression_end_line(node.receiver)
          lines << expression_end_line(node.index)
        when AST::Specialization
          lines << expression_end_line(node.callee)
        when AST::Call
          lines << expression_end_line(node.callee)
          node.arguments.each { |argument| lines << expression_end_line(argument.value) }
        when AST::Argument
          lines << expression_end_line(node.value)
        when AST::UnaryOp
          lines << expression_end_line(node.operand)
        when AST::BinaryOp
          lines << expression_end_line(node.left)
          lines << expression_end_line(node.right)
        when AST::IfExpr
          lines << expression_end_line(node.condition)
          lines << expression_end_line(node.then_expression)
          lines << expression_end_line(node.else_expression)
        when AST::MatchExpr
          lines << expression_end_line(node.expression)
          node.arms.each do |arm|
            lines << expression_end_line(arm.pattern)
            lines << expression_end_line(arm.value)
          end
        when AST::AwaitExpr
          lines << expression_end_line(node.expression)
        when AST::FormatExprPart
          lines << expression_end_line(node.expression)
        when AST::PrefixCast
          lines << expression_end_line(node.expression)
        end

        lines.compact.max
      end

      def recovered_for_statement(statement)
        AST::ForStmt.new(
          bindings: Array(statement.header_bindings),
          iterables: Array(statement.header_iterables),
          body: statement.body,
          line: statement.line,
          column: statement.column,
        )
      end

      def null_test_refinements(expression, truthy:, scopes:)
        identifier_expression = nil
        if expression.left.is_a?(AST::Identifier) && expression.right.is_a?(AST::NullLiteral)
          identifier_expression = expression.left
        elsif expression.left.is_a?(AST::NullLiteral) && expression.right.is_a?(AST::Identifier)
          identifier_expression = expression.right
        else
          return {}
        end

        binding = lookup_value(identifier_expression.name, scopes)
        return {} unless binding&.storage_type.is_a?(Types::Nullable)

        null_result = expression.operator == "==" ? truthy : !truthy
        refined_type = null_result ? @null_type : binding.storage_type.base
        { identifier_expression.name => refined_type }
      end

      def conditional_common_type(then_type, else_type, then_expression:, else_expression:)
        return then_type if then_type == else_type

        numeric_type = common_numeric_type(then_type, else_type)
        return numeric_type if numeric_type

        if (nullable_type = conditional_null_common_type(then_type, else_type))
          return nullable_type
        end

        if (nullable_type = conditional_null_common_type(else_type, then_type))
          return nullable_type
        end

        return then_type if types_compatible?(else_type, then_type, expression: else_expression)
        return else_type if types_compatible?(then_type, else_type, expression: then_expression)

        nil
      end

      def nullable_candidate?(type)
        return false if ref_type?(type)

        sized_layout_type?(type) || pointer_type?(type) || type.is_a?(Types::Nullable)
      end

      def conditional_null_common_type(null_type, other_type)
        return unless null_type.is_a?(Types::Null)

        if other_type.is_a?(Types::Nullable)
          return other_type if null_type.target_type.nil? || null_type.target_type == other_type.base

          return nil
        end

        return unless nullable_candidate?(other_type)
        return if null_type.target_type && null_type.target_type != other_type

        Types::Registry.nullable(other_type)
      end

      def describe_expression(expression)
        case expression
        when AST::Identifier
          expression.name
        when AST::MemberAccess
          "#{describe_expression(expression.receiver)}.#{expression.member}"
        when AST::IndexAccess
          "#{describe_expression(expression.receiver)}[...]"
        when AST::Specialization
          "#{describe_expression(expression.callee)}[...]"
        when AST::FormatString
          'f"..."'
        else
          expression.class.name.split("::").last
        end
      end

    end
  end
end
