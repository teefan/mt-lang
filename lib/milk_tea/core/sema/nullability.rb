# frozen_string_literal: true

module MilkTea
  class Sema
    class Checker
      private

      def check_block(statements, scopes:, return_type:, allow_return: true)
        with_return_context(return_type, allow_return:) do
          with_nested_scope(scopes) do |nested_scopes|
            statements.each_with_index do |statement, idx|
              begin
                record_local_completion_snapshot(
                  statement.respond_to?(:line) ? statement.line : nil,
                  statement.respond_to?(:column) ? statement.column : 0,
                  nested_scopes,
                )
                refinements = check_statement(statement, scopes: nested_scopes, return_type:, allow_return:)
                apply_continuation_refinements!(nested_scopes, refinements)
                # Apply CFG-derived nullability refinements before the next statement.
                if @nullability_flow_result && idx + 1 < statements.length
                  apply_nullability_continuation_refinements!(nested_scopes, statements[idx + 1])
                end
                record_local_completion_snapshot(statement_end_line(statement), 1_000_000, nested_scopes)
              rescue SemaError => e
                if @collecting_errors
                  @structural_errors << e
                  next
                end

                raise e unless e.line.nil?

                stmt_line = statement.respond_to?(:line) ? statement.line : nil
                raise e if stmt_line.nil?

                raise_sema_error(e.message, statement)
              end
            end
          end
        end
      end

      def check_definite_assignment(binding)
        return unless binding.ast.respond_to?(:body)

        resolution = binding_resolution_snapshot
        graph = CFG::Builder.new(
          binding_resolution: CFG::BindingResolution.new(
            identifier_binding_ids: resolution.identifier_binding_ids,
            declaration_binding_ids: resolution.declaration_binding_ids,
            mutating_argument_identifier_ids: resolution.mutating_argument_identifier_ids,
          ),
          strict_binding_ids: true,
          local_decl_without_initializer_writes: true,
        ).build(binding.ast.body)

        local_declared_ids = Set.new
        graph.each_node do |node|
          node.writes_info.each do |write|
            origin = write[:origin]
            next unless %i[declaration for_binding match_binding].include?(origin)

            local_declared_ids << write[:binding_key]
          end
        end

        initially_assigned = binding.body_params.each_with_object(Set.new) do |param, set|
          set << param.id if param.id
        end
        # Any binding read but never defined in this function body is treated as
        # preassigned (for example module-level const/var bindings).
        initially_assigned.merge(graph.read_bindings - local_declared_ids)

        result = CFG::DefiniteAssignment.solve(graph, initially_assigned:)
        first_issue = result.read_before_assignment.min_by do |issue|
          [issue.line || Float::INFINITY, issue.column || Float::INFINITY, issue.node_id]
        end
        return unless first_issue

        name = @binding_name_by_id[first_issue.binding_key] || first_issue.binding_key
        raise SemaError.new(
          "read of '#{name}' before definite assignment",
          line: first_issue.line,
          column: first_issue.column,
          length: first_issue.length || name.to_s.length,
          path: @path,
        )
      end

      # Runs a strict binding-ID nullability pass before statement checks.
      # Resolution is computed with a lexical pre-check walk so shadowed names
      # are disambiguated without relying on name fallback.
      def run_nullability_pre_pass(binding, scopes)
        return unless binding.ast.respond_to?(:body)

        @nullability_flow_result = nil
        resolution = precheck_binding_resolution(binding.ast.body, scopes)
        graph = CFG::Builder.new(
          binding_resolution: CFG::BindingResolution.new(
            identifier_binding_ids: resolution.identifier_binding_ids,
            declaration_binding_ids: resolution.declaration_binding_ids,
            mutating_argument_identifier_ids: resolution.mutating_argument_identifier_ids,
          ),
          strict_binding_ids: true,
        ).build(binding.ast.body)
        @nullability_flow_result = CFG::NullabilityFlow.solve(graph)
      end

      # After processing a statement, apply CFG-derived non-null refinements to
      # the scopes so the *next* statement benefits from cross-branch narrowing.
      def apply_nullability_continuation_refinements!(scopes, next_stmt)
        return unless @nullability_flow_result

        nonnull_binding_ids = @nullability_flow_result.nonnull_before(next_stmt)
        return if nonnull_binding_ids.empty?

        refinements = {}
        nonnull_binding_ids.each do |binding_id|
          next unless binding_id.is_a?(Integer)

          name = @binding_name_by_id[binding_id]
          next unless name

          binding = lookup_value(name, scopes)
          next unless binding&.id == binding_id
          next unless binding&.storage_type.is_a?(Types::Nullable)

          refinements[name] = binding.storage_type.base
        end
        apply_continuation_refinements!(scopes, refinements) unless refinements.empty?
      end

      def preassign_local_binding_ids(statements)
        @preassigned_local_binding_ids = {}
        preassign_local_binding_ids_in_statements(statements || [])
      end

      def preassign_local_binding_ids_in_statements(statements)
        statements.each do |statement|
          case statement
          when AST::ErrorBlockStmt
            preassign_local_binding_ids_in_expression(statement.header_expression) if statement.header_expression
            Array(statement.header_iterables).each { |iterable| preassign_local_binding_ids_in_expression(iterable) }
            Array(statement.header_bindings).each do |binding|
              @preassigned_local_binding_ids[binding.object_id] ||= allocate_binding_id
            end if statement.header_type == :for
            preassign_local_binding_ids_in_statements(statement.body || [])
          when AST::LocalDecl
            @preassigned_local_binding_ids[statement.object_id] ||= allocate_binding_id
            preassign_local_binding_ids_in_expression(statement.value) if statement.value
            if statement.else_binding && (statement.else_body || statement.recovered_else)
              @preassigned_local_binding_ids[statement.else_binding.object_id] ||= allocate_binding_id
            end
            preassign_local_binding_ids_in_statements(statement.else_body || [])
          when AST::Assignment
            preassign_local_binding_ids_in_expression(statement.target)
            preassign_local_binding_ids_in_expression(statement.value)
          when AST::IfStmt
            statement.branches.each do |branch|
              preassign_local_binding_ids_in_expression(branch.condition)
              preassign_local_binding_ids_in_statements(branch.body || [])
            end
            preassign_local_binding_ids_in_statements(statement.else_body || [])
          when AST::MatchStmt
            preassign_local_binding_ids_in_expression(statement.expression)
            statement.arms.each do |arm|
              preassign_local_binding_ids_in_expression(arm.pattern)
              @preassigned_local_binding_ids[arm.object_id] ||= allocate_binding_id if arm.binding_name
              preassign_local_binding_ids_in_statements(arm.body || [])
            end
          when AST::UnsafeStmt
            preassign_local_binding_ids_in_statements(statement.body || [])
          when AST::WhileStmt
            preassign_local_binding_ids_in_expression(statement.condition)
            preassign_local_binding_ids_in_statements(statement.body || [])
          when AST::ForStmt
            statement.bindings.each do |binding|
              @preassigned_local_binding_ids[binding.object_id] ||= allocate_binding_id
            end
            statement.iterables.each { |iterable| preassign_local_binding_ids_in_expression(iterable) }
            preassign_local_binding_ids_in_statements(statement.body || [])
          when AST::DeferStmt
            preassign_local_binding_ids_in_expression(statement.expression) if statement.expression
            preassign_local_binding_ids_in_statements(statement.body || []) if statement.body
          when AST::ReturnStmt
            preassign_local_binding_ids_in_expression(statement.value) if statement.value
          when AST::StaticAssert
            preassign_local_binding_ids_in_expression(statement.condition)
            preassign_local_binding_ids_in_expression(statement.message)
          when AST::ExpressionStmt
            preassign_local_binding_ids_in_expression(statement.expression)
          end
        end
      end

      def preassign_local_binding_ids_in_expression(expression)
        case expression
        when nil, AST::Identifier, AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral,
             AST::BooleanLiteral, AST::NullLiteral, AST::SizeofExpr, AST::AlignofExpr,
             AST::OffsetofExpr, AST::ErrorExpr
          nil
        when AST::MemberAccess
          preassign_local_binding_ids_in_expression(expression.receiver)
        when AST::IndexAccess
          preassign_local_binding_ids_in_expression(expression.receiver)
          preassign_local_binding_ids_in_expression(expression.index)
        when AST::Specialization, AST::Call
          preassign_local_binding_ids_in_expression(expression.callee)
          expression.arguments.each { |argument| preassign_local_binding_ids_in_expression(argument.value) }
        when AST::UnaryOp
          preassign_local_binding_ids_in_expression(expression.operand)
        when AST::BinaryOp
          preassign_local_binding_ids_in_expression(expression.left)
          preassign_local_binding_ids_in_expression(expression.right)
        when AST::RangeExpr
          preassign_local_binding_ids_in_expression(expression.start_expr)
          preassign_local_binding_ids_in_expression(expression.end_expr)
        when AST::IfExpr
          preassign_local_binding_ids_in_expression(expression.condition)
          preassign_local_binding_ids_in_expression(expression.then_expression)
          preassign_local_binding_ids_in_expression(expression.else_expression)
        when AST::MatchExpr
          preassign_local_binding_ids_in_expression(expression.expression)
          expression.arms.each do |arm|
            preassign_local_binding_ids_in_expression(arm.pattern)
            @preassigned_local_binding_ids[arm.object_id] ||= allocate_binding_id if arm.binding_name
            preassign_local_binding_ids_in_expression(arm.value)
          end
        when AST::UnsafeExpr
          preassign_local_binding_ids_in_expression(expression.expression)
        when AST::AwaitExpr
          preassign_local_binding_ids_in_expression(expression.expression)
        when AST::FormatString
          expression.parts.each do |part|
            preassign_local_binding_ids_in_expression(part.expression) if part.is_a?(AST::FormatExprPart)
          end
        when AST::ProcExpr
          preassign_local_binding_ids_in_statements(expression.body)
        end
      end

      def precheck_binding_resolution(statements, scopes)
        declaration_binding_ids = {}
        identifier_binding_ids = {}

        initial_scope = {}
        scopes.each do |scope|
          scope.each do |name, binding|
            initial_scope[name] = binding.id if binding.respond_to?(:id) && binding.id
          end
        end

        walk_statements_for_precheck_resolution(
          statements || [],
          [initial_scope],
          declaration_binding_ids,
          identifier_binding_ids,
        )

        BindingResolution.new(
          identifier_binding_ids: identifier_binding_ids,
          declaration_binding_ids: declaration_binding_ids,
          mutating_argument_identifier_ids: {},
          editable_receiver_expression_ids: {},
          mutable_lvalue_argument_identifier_ids: {},
          binding_types: {},
        )
      end

      def walk_statements_for_precheck_resolution(statements, scopes, declaration_ids, identifier_ids)
        block_scopes = scopes + [{}]
        statements.each do |statement|
          case statement
          when AST::ErrorBlockStmt
            if statement.header_type == :for
              Array(statement.header_iterables).each do |iterable|
                walk_expression_for_precheck_resolution(iterable, block_scopes, identifier_ids, declaration_ids)
              end
              for_scopes = block_scopes + [{}]
              Array(statement.header_bindings).each do |binding|
                binding_id = @preassigned_local_binding_ids.fetch(binding.object_id)
                for_scopes.last[binding.name] = binding_id
                declaration_ids[binding.object_id] = binding_id
              end
              walk_statements_for_precheck_resolution(statement.body || [], for_scopes, declaration_ids, identifier_ids)
            else
              walk_expression_for_precheck_resolution(statement.header_expression, block_scopes, identifier_ids, declaration_ids) if statement.header_expression
              walk_statements_for_precheck_resolution(statement.body || [], block_scopes, declaration_ids, identifier_ids)
            end
          when AST::LocalDecl
            walk_expression_for_precheck_resolution(statement.value, block_scopes, identifier_ids, declaration_ids) if statement.value
            if statement.else_binding && (statement.else_body || statement.recovered_else)
              else_scopes = block_scopes + [{}]
              binding_id = @preassigned_local_binding_ids.fetch(statement.else_binding.object_id)
              else_scopes.last[statement.else_binding.name] = binding_id
              declaration_ids[statement.else_binding.object_id] = binding_id
              walk_statements_for_precheck_resolution(statement.else_body || [], else_scopes, declaration_ids, identifier_ids)
            else
              walk_statements_for_precheck_resolution(statement.else_body || [], block_scopes, declaration_ids, identifier_ids)
            end
            binding_id = @preassigned_local_binding_ids.fetch(statement.object_id)
            unless let_else_discard_binding_syntax?(statement)
              block_scopes.last[statement.name] = binding_id
              declaration_ids[statement.object_id] = binding_id
            end
          when AST::Assignment
            walk_expression_for_precheck_resolution(statement.value, block_scopes, identifier_ids, declaration_ids)
            walk_assignment_target_reads_for_precheck_resolution(statement.target, statement.operator, block_scopes, identifier_ids, declaration_ids)
            if statement.target.is_a?(AST::Identifier)
              if (binding_id = resolve_name_in_precheck_scopes(statement.target.name, block_scopes))
                identifier_ids[statement.target.object_id] = binding_id
              end
            end
          when AST::IfStmt
            statement.branches.each do |branch|
              walk_expression_for_precheck_resolution(branch.condition, block_scopes, identifier_ids, declaration_ids)
              walk_statements_for_precheck_resolution(branch.body || [], block_scopes, declaration_ids, identifier_ids)
            end
            walk_statements_for_precheck_resolution(statement.else_body || [], block_scopes, declaration_ids, identifier_ids)
          when AST::MatchStmt
            walk_expression_for_precheck_resolution(statement.expression, block_scopes, identifier_ids, declaration_ids)
            statement.arms.each do |arm|
              arm_scopes = block_scopes + [{}]
              if arm.binding_name
                binding_id = @preassigned_local_binding_ids.fetch(arm.object_id)
                arm_scopes.last[arm.binding_name] = binding_id
                declaration_ids[arm.object_id] = binding_id
              end
              walk_statements_for_precheck_resolution(arm.body || [], arm_scopes, declaration_ids, identifier_ids)
            end
          when AST::UnsafeStmt, AST::WhileStmt
            walk_expression_for_precheck_resolution(statement.condition, block_scopes, identifier_ids, declaration_ids) if statement.is_a?(AST::WhileStmt)
            walk_statements_for_precheck_resolution(statement.body || [], block_scopes, declaration_ids, identifier_ids)
          when AST::ForStmt
            statement.iterables.each do |iterable|
              walk_expression_for_precheck_resolution(iterable, block_scopes, identifier_ids, declaration_ids)
            end
            for_scopes = block_scopes + [{}]
            statement.bindings.each do |binding|
              binding_id = @preassigned_local_binding_ids.fetch(binding.object_id)
              for_scopes.last[binding.name] = binding_id
              declaration_ids[binding.object_id] = binding_id
            end
            walk_statements_for_precheck_resolution(statement.body || [], for_scopes, declaration_ids, identifier_ids)
          when AST::DeferStmt
            walk_expression_for_precheck_resolution(statement.expression, block_scopes, identifier_ids, declaration_ids) if statement.expression
            walk_statements_for_precheck_resolution(statement.body || [], block_scopes, declaration_ids, identifier_ids) if statement.body
          when AST::ExpressionStmt
            walk_expression_for_precheck_resolution(statement.expression, block_scopes, identifier_ids, declaration_ids)
          when AST::ReturnStmt
            walk_expression_for_precheck_resolution(statement.value, block_scopes, identifier_ids, declaration_ids) if statement.value
          when AST::StaticAssert
            walk_expression_for_precheck_resolution(statement.condition, block_scopes, identifier_ids, declaration_ids)
          end
        end
      end

      def walk_expression_for_precheck_resolution(expression, scopes, identifier_ids, declaration_ids = nil)
        case expression
        when nil
          nil
        when AST::Identifier
          if (binding_id = resolve_name_in_precheck_scopes(expression.name, scopes))
            identifier_ids[expression.object_id] = binding_id
          end
        when AST::MemberAccess
          walk_expression_for_precheck_resolution(expression.receiver, scopes, identifier_ids, declaration_ids)
        when AST::IndexAccess
          walk_expression_for_precheck_resolution(expression.receiver, scopes, identifier_ids, declaration_ids)
          walk_expression_for_precheck_resolution(expression.index, scopes, identifier_ids, declaration_ids)
        when AST::Specialization
          walk_expression_for_precheck_resolution(expression.callee, scopes, identifier_ids, declaration_ids)
        when AST::Call
          walk_expression_for_precheck_resolution(expression.callee, scopes, identifier_ids, declaration_ids)
          expression.arguments.each { |argument| walk_expression_for_precheck_resolution(argument.value, scopes, identifier_ids, declaration_ids) }
        when AST::UnaryOp
          walk_expression_for_precheck_resolution(expression.operand, scopes, identifier_ids, declaration_ids)
        when AST::BinaryOp
          walk_expression_for_precheck_resolution(expression.left, scopes, identifier_ids, declaration_ids)
          walk_expression_for_precheck_resolution(expression.right, scopes, identifier_ids, declaration_ids)
        when AST::RangeExpr
          walk_expression_for_precheck_resolution(expression.start_expr, scopes, identifier_ids, declaration_ids)
          walk_expression_for_precheck_resolution(expression.end_expr, scopes, identifier_ids, declaration_ids)
        when AST::IfExpr
          walk_expression_for_precheck_resolution(expression.condition, scopes, identifier_ids, declaration_ids)
          walk_expression_for_precheck_resolution(expression.then_expression, scopes, identifier_ids, declaration_ids)
          walk_expression_for_precheck_resolution(expression.else_expression, scopes, identifier_ids, declaration_ids)
        when AST::MatchExpr
          walk_expression_for_precheck_resolution(expression.expression, scopes, identifier_ids, declaration_ids)
          expression.arms.each do |arm|
            walk_expression_for_precheck_resolution(arm.pattern, scopes, identifier_ids, declaration_ids)
            arm_scopes = scopes
            if arm.binding_name
              binding_id = @preassigned_local_binding_ids.fetch(arm.object_id)
              arm_scopes = scopes + [{ arm.binding_name => binding_id }]
              declaration_ids[arm.object_id] = binding_id if declaration_ids
            end
            walk_expression_for_precheck_resolution(arm.value, arm_scopes, identifier_ids, declaration_ids)
          end
        when AST::UnsafeExpr
          walk_expression_for_precheck_resolution(expression.expression, scopes, identifier_ids, declaration_ids)
        when AST::AwaitExpr
          walk_expression_for_precheck_resolution(expression.expression, scopes, identifier_ids, declaration_ids)
        when AST::FormatString
          expression.parts.each do |part|
            next unless part.is_a?(AST::FormatExprPart)

            walk_expression_for_precheck_resolution(part.expression, scopes, identifier_ids, declaration_ids)
          end
        end
      end

      def walk_assignment_target_reads_for_precheck_resolution(target, operator, scopes, identifier_ids, declaration_ids = nil)
        if operator != "=" && target.is_a?(AST::Identifier)
          if (binding_id = resolve_name_in_precheck_scopes(target.name, scopes))
            identifier_ids[target.object_id] = binding_id
          end
        end

        case target
        when AST::Identifier
          nil
        when AST::MemberAccess
          walk_expression_for_precheck_resolution(target.receiver, scopes, identifier_ids, declaration_ids)
        when AST::IndexAccess
          walk_expression_for_precheck_resolution(target.receiver, scopes, identifier_ids, declaration_ids)
          walk_expression_for_precheck_resolution(target.index, scopes, identifier_ids, declaration_ids)
        else
          walk_expression_for_precheck_resolution(target, scopes, identifier_ids, declaration_ids)
        end
      end

      def resolve_name_in_precheck_scopes(name, scopes)
        scopes.reverse_each do |scope|
          return scope[name] if scope.key?(name)
        end

        nil
      end

    end
  end
end
