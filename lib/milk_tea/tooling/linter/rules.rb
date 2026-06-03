# frozen_string_literal: true

module MilkTea
  class Linter
    module LinterRules
      private

      # ── missing-return ───────────────────────────────────────────────────
  
      def check_missing_return(function)
        return unless function.return_type           # implicit void — no check
        return if void_return_type?(function.return_type)
        return if always_returns?(function.body)
  
        @warnings << Warning.new(
          path: @path,
          line: function.line,
          column: function.respond_to?(:column) ? function.column : nil,
          length: function.name.length,
          code: "missing-return",
          message: "function '#{function.name}' does not always return a value",
          severity: :error,
          symbol_name: function.name
        )
      end
  
      def emit_redundant_return_warnings(function)
        return unless function.return_type
        return unless void_return_type?(function.return_type)
  
        final_statement = function.body&.last
        return unless final_statement.is_a?(AST::ReturnStmt)
        return unless final_statement.value.nil?
  
        @warnings << Warning.new(
          path: @path,
          line: final_statement.line,
          column: final_statement.column,
          length: final_statement.length || "return".length,
          code: "redundant-return",
          message: "final bare return in void function is redundant",
          severity: :hint,
        )
      end
  
      def void_return_type?(return_type)
        case return_type
        when AST::TypeRef
          name = return_type.name
          name.is_a?(AST::QualifiedName) && name.parts == ["void"]
        when Types::Primitive
          return_type.name == "void"
        else
          false
        end
      end
  
      # Returns true if every execution path through `stmts` ends with a
      # guaranteed return.  Conservative: only IfStmt with else + MatchStmt
      # with arms are considered exhaustive.
      def always_returns?(stmts)
        stmts.any? do |stmt|
          case stmt
          when AST::ReturnStmt
            true
          when AST::ExpressionStmt
            terminating_expression?(stmt.expression)
          when AST::IfStmt
            # Only exhaustive if there is an else branch AND every branch returns
            stmt.else_body && !stmt.else_body.empty? &&
              stmt.branches.all? { |b| always_returns?(b.body) } &&
              always_returns?(stmt.else_body)
          when AST::WhileStmt
            infinite_while_without_break?(stmt)
          when AST::MatchStmt
            stmt.arms.any? && stmt.arms.all? { |arm| always_returns?(arm.body) }
          when AST::UnsafeStmt
            always_returns?(stmt.body)
          else
            false
          end
        end
      end
  
      def infinite_while_without_break?(stmt)
        stmt.condition.is_a?(AST::BooleanLiteral) &&
          stmt.condition.value == true &&
          !loop_body_can_break?(stmt.body)
      end
  
      def loop_body_can_break?(body)
        return false if body.nil? || body.empty?
  
        graph = CFG::Builder.new.build_loop_body(body)
        reachability = CFG::Reachability.solve(graph)
        graph.each_node.any? do |node|
          node.kind == :break_exit && reachability.reachable_ids.include?(node.id)
        end
      end
  
      def terminating_expression?(expression)
        case expression
        when AST::Call
          terminating_callee?(expression.callee)
        when AST::Specialization
          terminating_callee?(expression.callee)
        else
          false
        end
      end
  
      def terminating_callee?(callee)
        case callee
        when AST::Identifier
          callee.name == "fatal"
        when AST::Specialization
          terminating_callee?(callee.callee)
        else
          false
        end
      end
      # ── redundant-else ───────────────────────────────────────────────────
      # Fire when every explicit if/else if branch always returns, making the else
      # block an unnecessary level of indentation.
      def check_redundant_else(stmt)
        return unless stmt.else_body && !stmt.else_body.empty?
        return unless stmt.branches.all? { |b| always_returns?(b.body) }
  
        # Use the line of the first else-body statement as the diagnostic anchor.
        else_line = stmt.else_body.first.respond_to?(:line) ? stmt.else_body.first.line : stmt.line
        @warnings << Warning.new(
          path: @path,
          line: stmt.else_line || else_line,
          column: stmt.else_column,
          length: 4,
          code: "redundant-else",
          message: "else block is redundant because all preceding branches return"
        )
      end
      # ── useless-expression ───────────────────────────────────────────────────
  
      PURE_EXPRESSION_TYPES = [
        AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral, AST::FormatString,
        AST::BooleanLiteral, AST::NullLiteral,
        AST::BinaryOp, AST::UnaryOp,
        AST::Identifier, AST::UnsafeExpr,
      ].freeze
  
      def check_useless_expression(stmt)
        expr = stmt.expression
        return unless PURE_EXPRESSION_TYPES.any? { |t| expr.is_a?(t) }
  
        line = expression_line(expr) || (stmt.respond_to?(:line) ? stmt.line : nil)
        column = expression_column(expr)
        length = expression_length(expr)
        if line && (!column || !length || !expr.respond_to?(:column) || expr.is_a?(AST::UnsafeExpr))
          fallback_span = source_statement_span(line)
          column ||= fallback_span&.first
          length = fallback_span&.last if !length || !expr.respond_to?(:column) || expr.is_a?(AST::UnsafeExpr)
        end
  
        @warnings << Warning.new(
          path: @path,
          line:,
          column:,
          length:,
          code: "useless-expression",
          message: "expression result is unused and has no side effects",
          severity: :warning
        )
      end
      # ── self-assignment ────────────────────────────────────────────────────
  
      def check_self_assignment(stmt)
        return unless stmt.operator == "="
        return unless stmt.target.is_a?(AST::Identifier) && stmt.value.is_a?(AST::Identifier)
        return unless stmt.target.name == stmt.value.name
  
        @warnings << Warning.new(
          path: @path,
          line: expression_line(stmt.target) || stmt.line,
          column: expression_column(stmt.target),
          length: expression_length(stmt.target),
          code: "self-assignment",
          message: "'#{stmt.target.name}' is assigned to itself",
          severity: :warning,
          symbol_name: stmt.target.name
        )
      end
  
      # ── self-comparison ────────────────────────────────────────────────────
  
      def check_self_comparison(expr)
        return unless %w[== !=].include?(expr.operator)
        return unless expr.left.is_a?(AST::Identifier) && expr.right.is_a?(AST::Identifier)
        return unless expr.left.name == expr.right.name
  
        line = expression_line(expr) || expr.left.line
        always = expr.operator == "==" ? "always true" : "always false"
        @warnings << Warning.new(
          path: @path,
          line:,
          column: expression_column(expr),
          length: expression_length(expr),
          code: "self-comparison",
          message: "'#{expr.left.name}' is compared to itself — #{always}",
          severity: :warning,
          symbol_name: expr.left.name
        )
      end
  
      def check_redundant_bool_compare(expr)
        return unless %w[== !=].include?(expr.operator)
  
        left_bool = expr.left.is_a?(AST::BooleanLiteral)
        right_bool = expr.right.is_a?(AST::BooleanLiteral)
        return unless left_bool ^ right_bool
  
        literal = left_bool ? expr.left : expr.right
        compared = left_bool ? expr.right : expr.left
        return if compared.is_a?(AST::BooleanLiteral)
  
        suggestion = if expr.operator == "=="
                       literal.value ? "use the expression directly" : "invert the expression with 'not'"
                     else
                       literal.value ? "invert the expression with 'not'" : "use the expression directly"
                     end
  
        @warnings << Warning.new(
          path: @path,
          line: expression_line(expr),
          column: expression_column(expr),
          length: redundant_bool_compare_length(expr),
          code: "redundant-bool-compare",
          message: "boolean comparison against literal is redundant; #{suggestion}",
          severity: :hint,
        )
      end
  
      def redundant_bool_compare_length(expr)
        length = expression_length(expr)
        return length if length
  
        line = expression_line(expr)
        column = expression_column(expr)
        return nil unless line && column
  
        text = source_code_line(line)
        return nil unless text
  
        snippet = text[(column - 1)..]
        return nil unless snippet
  
        right_literal = snippet.match(/\A\s*(.+?)\s*(==|!=)\s*(true|false)\b/)
        return right_literal[0].rstrip.length if right_literal
  
        left_literal = snippet.match(/\A\s*(true|false)\s*(==|!=)\s*(.+?)(?=\s*(?::|\)|,|and\b|or\b|$))/)
        return left_literal[0].rstrip.length if left_literal
  
        nil
      end
  
      def check_duplicate_if_conditions(statement)
        return unless statement.is_a?(AST::IfStmt)
  
        seen_signatures = {}
        statement.branches.each do |branch|
          signature = expression_signature(branch.condition)
          next unless signature
  
          existing = seen_signatures[signature]
          if existing
            @warnings << Warning.new(
              path: @path,
              line: expression_line(branch.condition) || branch.line,
              column: expression_column(branch.condition),
              length: expression_length(branch.condition),
              code: "duplicate-if-condition",
              message: "duplicate condition matches an earlier if/else-if branch and is unreachable",
              severity: :warning,
            )
            next
          end
  
          seen_signatures[signature] = branch
        end
      end
  
      def expression_signature(expression)
        case expression
        when AST::Identifier
          "id:#{expression.name}"
        when AST::BooleanLiteral
          "bool:#{expression.value}"
        when AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral
          "lit:#{expression.lexeme}"
        when AST::NullLiteral
          "null"
        when AST::MemberAccess
          receiver = expression_signature(expression.receiver)
          receiver ? "member:(#{receiver}).#{expression.member}" : nil
        when AST::UnaryOp
          operand = expression_signature(expression.operand)
          operand ? "unary:#{expression.operator}(#{operand})" : nil
        when AST::BinaryOp
          left = expression_signature(expression.left)
          right = expression_signature(expression.right)
          return nil unless left && right
  
          "binary:(#{left})#{expression.operator}(#{right})"
        else
          nil
        end
      end
  
      def check_noop_compound_assignment(statement)
        return unless statement.is_a?(AST::Assignment)
        return unless %w[+= -= *= /= |= ^= <<= >>=].include?(statement.operator)
  
        identity = noop_compound_identity_value(statement.operator, statement.value)
        return unless identity
  
        @warnings << Warning.new(
          path: @path,
          line: statement.line,
          column: expression_column(statement.target),
          length: statement.target.respond_to?(:name) ? statement.target.name.length : expression_length(statement.target),
          code: "noop-compound-assignment",
          message: "compound assignment with identity value has no effect",
          severity: :hint,
        )
      end
  
      def noop_compound_identity_value(operator, value)
        case operator
        when "+=", "-=", "|=", "^=", "<<=", ">>="
          integer_literal_zero?(value)
        when "*=", "/="
          numeric_literal_one?(value)
        else
          false
        end
      end
  
      def integer_literal_zero?(value)
        value.is_a?(AST::IntegerLiteral) && value.lexeme.gsub("_", "") == "0"
      end
  
      def numeric_literal_one?(value)
        return true if value.is_a?(AST::IntegerLiteral) && value.lexeme.gsub("_", "") == "1"
        return true if value.is_a?(AST::FloatLiteral) && %w[1.0 1.].include?(value.lexeme.gsub("_", ""))
  
        false
      end
      # ── prefer-let-else / prefer-var-else ──────────────────────────────
  
      def emit_prefer_let_else_warnings(stmts)
        emit_prefer_else_warnings(stmts, expected_kind: :let, code: "prefer-let-else")
      end
  
      def emit_prefer_var_else_warnings(stmts)
        emit_prefer_else_warnings(stmts, expected_kind: :var, code: "prefer-var-else")
      end
  
      def emit_prefer_else_warnings(stmts, expected_kind:, code:)
        return if stmts.nil? || stmts.empty?
  
        walk_statement_lists(stmts) do |statement_list|
          statement_list.each_with_index do |_statement, index|
            candidate = prefer_else_candidate(statement_list, index, expected_kind:)
            next unless candidate
  
            branch = candidate[:branch]
            line, column, length = condition_span(branch.condition, line: candidate[:if_stmt].line, keyword_pattern: "if")
  
            @warnings << Warning.new(
              path: @path,
              line:,
              column:,
              length:,
              code:,
              message: "nullable guard for '#{candidate[:declaration].name}' can use #{expected_kind} ... else",
              severity: :hint,
              symbol_name: candidate[:declaration].name
            )
          end
        end
      end
  
      def prefer_else_candidate(stmts, index, expected_kind:)
        declaration = stmts[index]
        if_stmt = stmts[index + 1]
        return unless declaration.is_a?(AST::LocalDecl)
        return unless declaration.kind == expected_kind
        return if declaration.type || declaration.else_binding || declaration.else_body || declaration.recovered_else
        return unless declaration.value && declaration.name
        return if ignored_binding_name?(declaration.name)
        return unless if_stmt.is_a?(AST::IfStmt)
        return unless if_stmt.else_body.nil? && if_stmt.branches.length == 1
  
        branch = if_stmt.branches.first
        identifier = null_equality_identifier(branch.condition)
        return unless identifier&.name == declaration.name
        return unless nullable_binding_declaration?(declaration)
        return if expected_kind == :var && !prefer_var_else_binding_mutated?(declaration)
        return unless CFG::Termination.block_always_terminates?(branch.body, ignore_name: method(:ignored_binding_name?), binding_resolution: cfg_binding_resolution)
  
        { declaration:, if_stmt:, branch: }
      end
  
      def prefer_var_else_binding_mutated?(declaration)
        binding = @scopes.last[declaration.name]
        binding&.mutated == true
      end
  
      def null_equality_identifier(cond)
        return nil unless cond.is_a?(AST::BinaryOp) && cond.operator == "=="
  
        if cond.left.is_a?(AST::Identifier) && cond.right.is_a?(AST::NullLiteral)
          cond.left
        elsif cond.left.is_a?(AST::NullLiteral) && cond.right.is_a?(AST::Identifier)
          cond.right
        end
      end
  
      def nullable_binding_declaration?(statement)
        binding_type = binding_type_for_declaration(statement)
        return binding_type.is_a?(Types::Nullable) if binding_type
  
        nullable_initializer_without_binding_type?(statement.value)
      end
  
      def nullable_initializer_without_binding_type?(expression)
        case expression
        when AST::Identifier, AST::MemberAccess, AST::IndexAccess, AST::Call, AST::IfExpr, AST::MatchExpr
          true
        when AST::AwaitExpr, AST::UnsafeExpr
          nullable_initializer_without_binding_type?(expression.expression)
        else
          false
        end
      end
  
      def binding_type_for_declaration(statement)
        binding_resolution = @sema_facts&.binding_resolution
        return nil unless binding_resolution&.binding_types
  
        binding_id = binding_resolution.declaration_binding_ids[statement.object_id]
        return nil unless binding_id
  
        binding_resolution.binding_types[binding_id]
      end
      def pointer_like_cast_expression(expression)
        return unless expression.is_a?(AST::Call)
  
        callee = expression.callee
        return unless callee.is_a?(AST::Specialization)
        return unless callee.callee.is_a?(AST::Identifier) && callee.callee.name == "cast"
        return unless callee.arguments.length == 1 && expression.arguments.length == 1
  
        target_type = callee.arguments.first.value
        return unless target_type.is_a?(AST::TypeRef)
        return unless pointer_like_type_ref?(target_type)
  
        { target_type:, source: expression.arguments.first.value }
      end
  
      def pointer_like_type_ref?(type_ref)
        return false if type_ref.nullable
  
        %w[ptr const_ptr ref].include?(type_ref.name.to_s)
      end
      # ── directional-ffi-arg ──────────────────────────────────────────────
  
      def check_directional_ffi_call(expression)
        call = resolve_directional_ffi_call(expression.callee)
        return unless call
  
        call[:params].zip(expression.arguments).each do |parameter, argument|
          next unless parameter && argument
  
          passing_mode = parameter_passing_mode(parameter)
          next unless %i[in out inout].include?(passing_mode)
          next unless legacy_directional_argument_expression?(argument.value)
  
          @warnings << Warning.new(
            path: @path,
            line: expression_line(argument.value),
            column: expression_column(argument.value),
            length: expression_length(argument.value),
            code: "directional-ffi-arg",
            message: "pass the lvalue directly to '#{call[:name]}'; parameter '#{parameter_name(parameter)}' already declares #{passing_mode} passing",
            severity: :hint,
            symbol_name: parameter_name(parameter)
          )
        end
      end
  
      def resolve_directional_ffi_call(callee)
        case callee
        when AST::Specialization
          resolve_directional_ffi_call(callee.callee)
        when AST::Identifier
          if @sema_facts && (binding = @sema_facts.functions[callee.name]) && directional_ffi_binding?(binding)
            return { name: binding.name, params: binding.type.params }
          end
  
          if (declaration = @declared_directional_functions[callee.name])
            return { name: declaration.name, params: declaration.params }
          end
  
          nil
        when AST::MemberAccess
          return nil unless callee.receiver.is_a?(AST::Identifier)
          return nil unless @sema_facts
  
          imported_module = @sema_facts.imports[callee.receiver.name]
          return nil unless imported_module
  
          binding = imported_module.functions[callee.member]
          return nil unless directional_ffi_binding?(binding)
  
          { name: binding.name, params: binding.type.params }
        else
          nil
        end
      end
  
      def directional_ffi_binding?(binding)
        return false unless binding
        return false unless binding.respond_to?(:ast) && (binding.ast.is_a?(AST::ExternFunctionDecl) || binding.ast.is_a?(AST::ForeignFunctionDecl))
  
        binding.type.params.any? { |parameter| %i[in out inout].include?(parameter.passing_mode) }
      end
  
      def parameter_passing_mode(parameter)
        parameter.respond_to?(:passing_mode) ? parameter.passing_mode : parameter.mode
      end
  
      def parameter_name(parameter)
        parameter.respond_to?(:name) ? parameter.name : "argument"
      end
  
      def legacy_directional_argument_expression?(expression)
        return true if expression.is_a?(AST::UnaryOp) && %w[in out inout].include?(expression.operator)
  
        if expression.is_a?(AST::Call) && expression.callee.is_a?(AST::Identifier) && %w[ptr_of ref_of].include?(expression.callee.name)
          return expression.arguments.length == 1
        end
  
        cast = pointer_like_cast_expression(expression)
        return false unless cast
  
        lvalue_expression?(cast[:source]) || legacy_directional_argument_expression?(cast[:source])
      end
  
      def lvalue_expression?(expression)
        expression.is_a?(AST::Identifier) || expression.is_a?(AST::MemberAccess) || expression.is_a?(AST::IndexAccess)
      end
    end
  end
end
