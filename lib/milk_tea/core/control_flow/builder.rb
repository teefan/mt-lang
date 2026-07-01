# frozen_string_literal: true

module MilkTea
  module ControlFlow
    class Builder
      def initialize(ignore_name: nil, binding_resolution: nil, strict_binding_ids: false, local_decl_without_initializer_writes: false)
        @ignore_name = ignore_name || ->(_name) { false }
        @binding_resolution = binding_resolution
        @strict_binding_ids = strict_binding_ids
        @local_decl_without_initializer_writes = local_decl_without_initializer_writes
      end

      def build(stmts)
        @graph = Graph.new
        @graph.exit_id = @graph.add_node(kind: :exit)
        @graph.entry_id = build_block(stmts || [], @graph.exit_id, break_target: nil, continue_target: nil)
        @graph
      ensure
        @graph = nil
      end

      def build_loop_body(stmts)
        @graph = Graph.new
        @graph.exit_id  = @graph.add_node(kind: :exit)         # fall-through (back-edge)
        break_exit_id   = @graph.add_node(kind: :break_exit)   # break target
        @graph.entry_id = build_block(stmts || [], @graph.exit_id, break_target: break_exit_id, continue_target: @graph.exit_id)
        @graph
      ensure
        @graph = nil
      end

      def build_loop_branch(stmts)
        @graph = Graph.new
        @graph.exit_id       = @graph.add_node(kind: :exit)
        break_exit_id        = @graph.add_node(kind: :break_exit)
        continue_exit_id     = @graph.add_node(kind: :continue_exit)
        @graph.entry_id      = build_block(
          stmts || [],
          @graph.exit_id,
          break_target:   break_exit_id,
          continue_target: continue_exit_id,
        )
        @graph
      ensure
        @graph = nil
      end

      private

      def build_block(stmts, next_id, break_target:, continue_target:)
        current_next = next_id
        stmts.reverse_each do |stmt|
          current_next = build_statement(stmt, current_next, break_target:, continue_target:)
        end
        current_next
      end

      def build_statement(stmt, next_id, break_target:, continue_target:)
        case stmt
        when AST::LocalDecl
          if stmt.else_body
            reads, reads_info = read_identifiers_with_sites(stmt.value)
            writes = Set.new
            writes_info = []
            declaration_key = declaration_binding_key(stmt, stmt.name)
            if declaration_key && (stmt.value || @local_decl_without_initializer_writes)
              writes << declaration_key
              writes_info << { name: stmt.name, binding_key: declaration_key, line: stmt.line, column: stmt.column, origin: :declaration }
            end

            success_id = add_linear_node(:local_decl, stmt, next_id, writes:, writes_info:)
            null_entry = build_block(stmt.else_body, next_id, break_target:, continue_target:)
            condition_id = @graph.add_node(
              kind: :local_decl_condition,
              statement: stmt,
              line: stmt.line,
              reads:,
              reads_info:,
            )
            @graph.add_edge(condition_id, success_id, label: :non_null)
            @graph.add_edge(condition_id, null_entry, label: :null)
            return condition_id
          end

          reads, reads_info = read_identifiers_with_sites(stmt.value)
          writes = Set.new
          writes_info = []
          declaration_key = declaration_binding_key(stmt, stmt.name)
          if declaration_key && (stmt.value || @local_decl_without_initializer_writes)
            writes << declaration_key
            writes_info << { name: stmt.name, binding_key: declaration_key, line: stmt.line, column: stmt.column, origin: :declaration }
          end
          add_linear_node(:local_decl, stmt, next_id, reads:, reads_info:, writes:, writes_info:)
        when AST::Assignment
          reads, reads_info = read_identifiers_with_sites(stmt.value)
          merge_read_info!(reads, reads_info, *assignment_target_reads(stmt.target, stmt.operator))
          merge_read_info!(reads, reads_info, *assignment_target_side_effect_reads(stmt.target))

          writes = Set.new
          writes_info = []
          if stmt.target.is_a?(AST::Identifier)
            target_key = identifier_binding_key(stmt.target)
            if target_key
              writes << target_key
              writes_info << { name: stmt.target.name, binding_key: target_key, line: stmt.line, column: stmt.target.column, origin: :assignment }
            end
          end
          add_linear_node(:assignment, stmt, next_id, reads:, reads_info:, writes:, writes_info:)
        when AST::IfStmt
          fallback_entry = stmt.else_body ? build_block(stmt.else_body, next_id, break_target:, continue_target:) : next_id
          stmt.branches.reverse_each do |branch|
            then_entry = build_block(branch.body, next_id, break_target:, continue_target:)
            branch_reads, branch_reads_info = read_identifiers_with_sites(branch.condition)
            cond_id = @graph.add_node(
              kind: :if_condition,
              statement: branch,
              line: branch.respond_to?(:line) ? branch.line : stmt.line,
              reads: branch_reads,
              reads_info: branch_reads_info,
            )
            @graph.add_edge(cond_id, then_entry, label: :true_branch)
            @graph.add_edge(cond_id, fallback_entry, label: :false_branch)
            emit_null_test_refinements(cond_id, then_entry, fallback_entry, branch.condition)
            fallback_entry = cond_id
          end
          fallback_entry
        when AST::MatchStmt
          match_reads, match_reads_info = read_identifiers_with_sites(stmt.expression)
          match_id = @graph.add_node(
            kind: :match_condition,
            statement: stmt,
            line: stmt.line,
            reads: match_reads,
            reads_info: match_reads_info,
          )
          if stmt.arms.empty?
            @graph.add_edge(match_id, next_id)
          else
            stmt.arms.each do |arm|
              arm_entry = build_block(arm.body, next_id, break_target:, continue_target:)
              if arm.binding_name
                binding_key = declaration_binding_key(arm, arm.binding_name)
                if binding_key
                  bind_id = @graph.add_node(
                    kind: :match_binding,
                    statement: arm,
                    line: arm.binding_line || stmt.line,
                    writes: Set[binding_key],
                    writes_info: [{
                      name: arm.binding_name,
                      binding_key:,
                      line: arm.binding_line || stmt.line,
                      column: arm.binding_column,
                      origin: :match_binding,
                    }],
                  )
                  @graph.add_edge(bind_id, arm_entry)
                  arm_entry = bind_id
                end
              end
              @graph.add_edge(match_id, arm_entry)
            end
          end
          match_id
        when AST::WhileStmt
          condition_reads, condition_reads_info = read_identifiers_with_sites(stmt.condition)
          cond_id = @graph.add_node(
            kind: :while_condition,
            statement: stmt,
            line: stmt.line,
            reads: condition_reads,
            reads_info: condition_reads_info,
          )
          body_entry = build_block(stmt.body, cond_id, break_target: next_id, continue_target: cond_id)
          @graph.add_edge(cond_id, body_entry, label: :true_branch)
          @graph.add_edge(cond_id, next_id, label: :false_branch)
          emit_null_test_refinements(cond_id, body_entry, next_id, stmt.condition)
          cond_id
        when AST::ForStmt
          writes = Set.new
          writes_info = []
          if stmt.name
            loop_key = declaration_binding_key(stmt, stmt.name)
            if loop_key
              writes << loop_key
              writes_info << {
                name: stmt.name,
                binding_key: loop_key,
                line: stmt.line,
                column: stmt.column,
                origin: :for_binding,
              }
            end
          end
          iterable_reads, iterable_reads_info = read_identifiers_with_sites(stmt.iterable)
          header_id = @graph.add_node(
            kind: :for_header,
            statement: stmt,
            line: stmt.line,
            reads: iterable_reads,
            reads_info: iterable_reads_info,
            writes:,
            writes_info:
          )
          body_entry = build_block(stmt.body, header_id, break_target: next_id, continue_target: header_id)
          @graph.add_edge(header_id, body_entry)
          @graph.add_edge(header_id, next_id)
          header_id
        when AST::UnsafeStmt
          build_block(stmt.body, next_id, break_target:, continue_target:)
        when AST::DeferStmt
          body_entry = stmt.body ? build_block(stmt.body, next_id, break_target:, continue_target:) : next_id
          expression_reads, expression_reads_info = stmt.expression ? read_identifiers_with_sites(stmt.expression) : [Set.new, []]
          defer_id = @graph.add_node(
            kind: :defer,
            statement: stmt,
            line: stmt.line,
            reads: expression_reads,
            reads_info: expression_reads_info,
          )
          @graph.add_edge(defer_id, body_entry)
          defer_id
        when AST::ReturnStmt
          return_reads, return_reads_info = read_identifiers_with_sites(stmt.value)
          @graph.add_node(
            kind: :return,
            statement: stmt,
            line: stmt.line,
            reads: return_reads,
            reads_info: return_reads_info,
          )
        when AST::ExpressionStmt
          reads, reads_info = read_identifiers_with_sites(stmt.expression)
          writes, writes_info = write_targets_from_expression(stmt.expression, line: stmt.line)
          if fatal_expression?(stmt.expression)
            @graph.add_node(
              kind: :fatal,
              statement: stmt,
              line: stmt.line,
              reads:,
              reads_info:,
              writes:,
              writes_info:
            )
          else
            add_linear_node(:expression, stmt, next_id, reads:, reads_info:, writes:, writes_info:)
          end
        when AST::StaticAssert
          reads, reads_info = read_identifiers_with_sites(stmt.condition)
          add_linear_node(:static_assert, stmt, next_id, reads:, reads_info:)
        when AST::PassStmt
          add_linear_node(:pass, stmt, next_id)
        when AST::BreakStmt
          target = break_target || next_id
          add_linear_node(:break, stmt, target)
        when AST::ContinueStmt
          target = continue_target || next_id
          add_linear_node(:continue, stmt, target)
        else
          add_linear_node(:other, stmt, next_id)
        end
      end

      def add_linear_node(kind, stmt, next_id, reads: Set.new, reads_info: [], writes: Set.new, writes_info: [])
        node_id = @graph.add_node(kind:, statement: stmt, line: stmt.respond_to?(:line) ? stmt.line : nil, reads:, reads_info:, writes:, writes_info:)
        @graph.add_edge(node_id, next_id)
        node_id
      end

      def fatal_expression?(expression)
        expression.is_a?(AST::Call) && expression.callee.is_a?(AST::Identifier) && expression.callee.name == "fatal"
      end

      def assignment_target_reads(target, operator)
        return [Set.new, []] if operator == "="
        return identifier_read_info(target) if target.is_a?(AST::Identifier)

        assignment_target_side_effect_reads(target)
      end

      def assignment_target_side_effect_reads(target)
        case target
        when AST::Identifier
          [Set.new, []]
        when AST::MemberAccess
          read_identifiers_with_sites(target.receiver)
        when AST::IndexAccess
          receiver_reads, receiver_info = read_identifiers_with_sites(target.receiver)
          merge_read_info!(receiver_reads, receiver_info, *read_identifiers_with_sites(target.index))
          [receiver_reads, receiver_info]
        else
          read_identifiers_with_sites(target)
        end
      end

      def merge_read_info!(reads, reads_info, extra_reads, extra_reads_info)
        reads.merge(extra_reads)
        reads_info.concat(extra_reads_info)
      end

      def identifier_read_info(identifier)
        key = identifier_binding_key(identifier)
        return [Set.new, []] unless key

        [Set[key], [ReadSite.new(binding_key: key, line: identifier.line, column: identifier.column, length: identifier.name.to_s.length)]]
      end

      def read_identifiers_with_sites(expression)
        reads = Set.new
        reads_info = []
        read_identifiers(expression, reads, reads_info)
        [reads, reads_info]
      end

      def read_identifiers(expression, names = Set.new, reads_info = [])
        case expression
        when nil
          nil
        when AST::Identifier
          key = identifier_binding_key(expression)
          if key
            names << key
            reads_info << ReadSite.new(binding_key: key, line: expression.line, column: expression.column, length: expression.name.to_s.length)
          end
        when AST::MemberAccess
          read_identifiers(expression.receiver, names, reads_info)
        when AST::IndexAccess
          read_identifiers(expression.receiver, names, reads_info)
          read_identifiers(expression.index, names, reads_info)
        when AST::Specialization
          read_identifiers(expression.callee, names, reads_info)
        when AST::Call
          read_identifiers(expression.callee, names, reads_info)
          expression.arguments.each { |argument| read_identifiers(argument.value, names, reads_info) }
        when AST::UnaryOp
          read_identifiers(expression.operand, names, reads_info)
        when AST::BinaryOp
          read_identifiers(expression.left, names, reads_info)
          read_identifiers(expression.right, names, reads_info)
        when AST::RangeExpr
          read_identifiers(expression.start_expr, names, reads_info)
          read_identifiers(expression.end_expr, names, reads_info)
        when AST::ExpressionList
          expression.elements.each { |element| read_identifiers(element, names, reads_info) }
        when AST::IfExpr
          read_identifiers(expression.condition, names, reads_info)
          read_identifiers(expression.then_expression, names, reads_info)
          read_identifiers(expression.else_expression, names, reads_info)
        when AST::MatchExpr
          read_identifiers(expression.expression, names, reads_info)
          expression.arms.each do |arm|
            read_identifiers(arm.pattern, names, reads_info)
            read_identifiers(arm.value, names, reads_info)
          end
        when AST::UnsafeExpr
          read_identifiers(expression.expression, names, reads_info)
        when AST::FormatString
          expression.parts.each do |part|
            read_identifiers(part.expression, names, reads_info) if part.is_a?(AST::FormatExprPart)
          end
        when AST::ProcExpr
          nil
        when AST::AwaitExpr
          read_identifiers(expression.expression, names, reads_info)
        when AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral,
             AST::BooleanLiteral, AST::NullLiteral,
             AST::SizeofExpr, AST::AlignofExpr, AST::OffsetofExpr
          nil
        else
          nil
        end
        names
      end

      def write_targets_from_expression(expression, line: nil, writes: Set.new, writes_info: [])
        case expression
        when nil
          nil
        when AST::MemberAccess
          write_targets_from_expression(expression.receiver, line:, writes:, writes_info:)
        when AST::IndexAccess
          write_targets_from_expression(expression.receiver, line:, writes:, writes_info:)
          write_targets_from_expression(expression.index, line:, writes:, writes_info:)
        when AST::Specialization
          write_targets_from_expression(expression.callee, line:, writes:, writes_info:)
        when AST::Call
          write_targets_from_expression(expression.callee, line:, writes:, writes_info:)
          expression.arguments.each do |argument|
            value = argument.value
            target_identifier = nil
            if value.is_a?(AST::UnaryOp) && %w[out inout].include?(value.operator) && value.operand.is_a?(AST::Identifier)
              target_identifier = value.operand
            elsif value.is_a?(AST::Identifier) && mutating_argument_identifier?(value)
              target_identifier = value
            else
              target_identifier = call_argument_mutation_target(value)
            end

            if target_identifier
              key = identifier_binding_key(target_identifier)
              if key
                writes << key
                writes_info << {
                  name: target_identifier.name,
                  binding_key: key,
                  line: line,
                  column: nil,
                  origin: :call_argument,
                }
              end
            end
            write_targets_from_expression(value, line:, writes:, writes_info:)
          end
        when AST::UnaryOp
          write_targets_from_expression(expression.operand, line:, writes:, writes_info:)
        when AST::BinaryOp
          write_targets_from_expression(expression.left, line:, writes:, writes_info:)
          write_targets_from_expression(expression.right, line:, writes:, writes_info:)
        when AST::RangeExpr
          write_targets_from_expression(expression.start_expr, line:, writes:, writes_info:)
          write_targets_from_expression(expression.end_expr, line:, writes:, writes_info:)
        when AST::ExpressionList
          expression.elements.each do |element|
            write_targets_from_expression(element, line:, writes:, writes_info:)
          end
        when AST::IfExpr
          write_targets_from_expression(expression.condition, line:, writes:, writes_info:)
          write_targets_from_expression(expression.then_expression, line:, writes:, writes_info:)
          write_targets_from_expression(expression.else_expression, line:, writes:, writes_info:)
        when AST::MatchExpr
          write_targets_from_expression(expression.expression, line:, writes:, writes_info:)
          expression.arms.each do |arm|
            write_targets_from_expression(arm.pattern, line:, writes:, writes_info:)
            write_targets_from_expression(arm.value, line:, writes:, writes_info:)
          end
        when AST::UnsafeExpr
          write_targets_from_expression(expression.expression, line:, writes:, writes_info:)
        when AST::FormatString
          expression.parts.each do |part|
            write_targets_from_expression(part.expression, line:, writes:, writes_info:) if part.is_a?(AST::FormatExprPart)
          end
        when AST::AwaitExpr
          write_targets_from_expression(expression.expression, line:, writes:, writes_info:)
        when AST::ProcExpr,
             AST::Identifier,
             AST::IntegerLiteral,
             AST::FloatLiteral,
             AST::StringLiteral,
             AST::BooleanLiteral,
             AST::NullLiteral,
             AST::SizeofExpr,
             AST::AlignofExpr,
             AST::OffsetofExpr
          nil
        else
          nil
        end

        [writes, writes_info]
      end

      def mutating_argument_identifier?(expression)
        return false unless expression.is_a?(AST::Identifier)

        @binding_resolution&.mutating_argument_identifier_ids&.key?(expression.object_id)
      end

      def call_argument_mutation_target(expression)
        return nil unless expression.is_a?(AST::Call)
        return nil unless expression.callee.is_a?(AST::Identifier)

        callee_name = expression.callee.name
        return nil unless expression.arguments.length == 1

        argument_value = expression.arguments.first.value

        if callee_name == "ref_of"
          return argument_value if argument_value.is_a?(AST::Identifier)
          return nil
        end

        if callee_name == "ptr_of"
          return argument_value if argument_value.is_a?(AST::Identifier)
          return call_argument_mutation_target(argument_value)
        end

        if callee_name == "const_ptr_of"
          return call_argument_mutation_target(argument_value)
        end

        nil
      end

      def identifier_binding_key(identifier_expression)
        return nil unless identifier_expression.is_a?(AST::Identifier)
        return nil if @ignore_name.call(identifier_expression.name)

        if @binding_resolution && (id = @binding_resolution.identifier_binding_ids[identifier_expression.object_id])
          return id
        end

        return nil if @strict_binding_ids

        identifier_expression.name
      end

      def declaration_binding_key(node, name)
        return nil if @ignore_name.call(name)

        if @binding_resolution && (id = @binding_resolution.declaration_binding_ids[node.object_id])
          return id
        end

        return nil if @strict_binding_ids

        name
      end

      def emit_null_test_refinements(cond_id, true_succ, false_succ, condition)
        pairs = null_check_pairs(condition, positive: true)
        return if pairs.empty?

        true_refs  = {}
        false_refs = {}
        pairs.each do |key, direction|
          if direction == :non_null_if_true
            true_refs[key]  = :non_null
            false_refs[key] = :null
          else # :null_if_true
            true_refs[key]  = :null
            false_refs[key] = :non_null
          end
        end
        @graph.set_edge_refinement(cond_id, true_succ, true_refs)  unless true_refs.empty?
        @graph.set_edge_refinement(cond_id, false_succ, false_refs) unless false_refs.empty?
      end

      def null_check_pairs(expr, positive:)
        case expr
        when AST::UnaryOp
          return null_check_pairs(expr.operand, positive: !positive) if expr.operator == "not"
        when AST::BinaryOp
          case expr.operator
          when "and"
            return merge_null_pairs(null_check_pairs(expr.left, positive:), null_check_pairs(expr.right, positive:)) if positive
          when "or"
            return merge_null_pairs(null_check_pairs(expr.left, positive:), null_check_pairs(expr.right, positive:)) unless positive
          when "=="
            return single_null_pair(expr, positive:, null_on_true: true)
          when "!="
            return single_null_pair(expr, positive:, null_on_true: false)
          end
        end
        {}
      end

      def single_null_pair(binary_expr, positive:, null_on_true:)
        identifier =
          if binary_expr.left.is_a?(AST::Identifier) && binary_expr.right.is_a?(AST::NullLiteral)
            binary_expr.left
          elsif binary_expr.left.is_a?(AST::NullLiteral) && binary_expr.right.is_a?(AST::Identifier)
            binary_expr.right
          end
        return {} unless identifier

        key = identifier_binding_key(identifier)
        return {} unless key

        direction = null_on_true == positive ? :null_if_true : :non_null_if_true
        { key => direction }
      end

      def merge_null_pairs(left, right)
        left.merge(right) do |_key, left_dir, right_dir|
          left_dir == right_dir ? left_dir : nil
        end.compact
      end
    end
  end
end
