# frozen_string_literal: true

module MilkTea
  class Linter
    module LinterSourceHelpers
      private

      def emit_line_too_long_warnings
        return unless @max_line_length.positive?
        return if @source.empty?
  
        @source_lines.each_with_index do |line, index|
          next if line.empty?
          next if external_or_foreign_function_header_line?(line)
          next unless line.length > @max_line_length
          next unless Formatter.wrappable_long_line_candidate_text?(line)
  
          fix = Formatter.build_long_line_wrap_fix(
            @source,
            index,
            max_line_length: @max_line_length,
            path: @path,
            tokens: @tokens,
            tokens_by_line: @tokens_by_line,
            validate: false,
          )
          message = "line exceeds max length of #{@max_line_length} columns (#{line.length})"
          message << "; wrap the expression" if fix
          @warnings << Warning.new(
            path: @path,
            line: index + 1,
            column: @max_line_length + 1,
            length: line.length - @max_line_length,
            code: "line-too-long",
            message:,
            severity: :warning,
          )
        end
      end
      def external_or_foreign_function_header_line?(line)
        line.strip.match?(/\A(?:[A-Za-z_]\w*\s+)*(?:external|foreign)\s+function\b/)
      end
      def emit_event_capacity_warnings(source_file)
        each_event_declaration(source_file) do |event_decl, owner_name|
          next unless event_decl.capacity >= EVENT_STACK_SNAPSHOT_WARNING_THRESHOLD
  
          warn_large_event_capacity(event_decl, owner_name:)
        end
      end
  
      def each_event_declaration(source_file)
        source_file.declarations.each do |declaration|
          case declaration
          when AST::EventDecl
            yield declaration, nil
          when AST::StructDecl
            declaration.events.each { |event_decl| yield event_decl, declaration.name }
            each_nested_struct_event_declaration(declaration, owner_name: declaration.name) { |ev, owner| yield ev, owner }
          end
        end
      end

      def each_nested_struct_event_declaration(struct_decl, owner_name:)
        struct_decl.nested_types.each do |nested|
          next unless nested.is_a?(AST::StructDecl)

          nested_owner = "#{owner_name}.#{nested.name}"
          nested.events.each { |event_decl| yield event_decl, nested_owner }
          each_nested_struct_event_declaration(nested, owner_name: nested_owner) { |ev, owner| yield ev, owner }
        end
      end
      def profile_phase(name)
        return yield unless @profile
  
        @profile.measure(name) { yield }
      end
      def param_line(param, fallback: nil)
        line = param.respond_to?(:line) ? param.line : nil
        line || fallback
      end
  
      def param_column(param)
        param.respond_to?(:column) ? param.column : nil
      end
  
      def declaration_column(declaration)
        declaration.respond_to?(:column) ? declaration.column : nil
      end
      def source_line_text(line)
        return nil unless line && line >= 1 && line <= @source_lines.length
  
        @source_lines[line - 1]
      end
  
      def source_code_line(line)
        text = source_line_text(line)
        return nil unless text
  
        text.rstrip
      end
  
      def source_statement_span(line)
        text = source_code_line(line)
        return nil unless text
  
        start_index = text.index(/\S/)
        return nil unless start_index
  
        [start_index + 1, text.length - start_index]
      end
      def source_condition_span(line, keyword_pattern:)
        text = source_code_line(line)
        return nil unless text
  
        match = text.match(/\A\s*(?:#{keyword_pattern})\s+(.*?)\s*:/)
        return nil unless match
  
        condition = match[1].rstrip
        return nil if condition.empty?
  
        [match.begin(1) + 1, condition.length]
      end
      def expression_line(expr)
        return nil unless expr
  
        return expr.line if expr.respond_to?(:line) && expr.line
  
        case expr
        when AST::BinaryOp
          expression_line(expr.left) || expression_line(expr.right)
        when AST::UnaryOp
          expression_line(expr.operand)
        when AST::Specialization
          expression_line(expr.callee)
        when AST::Call
          expression_line(expr.callee) || expr.arguments.filter_map { |argument| expression_line(argument.value) }.first
        when AST::IndexAccess
          expression_line(expr.receiver) || expression_line(expr.index)
        when AST::MemberAccess
          expression_line(expr.receiver)
        when AST::RangeExpr
          expression_line(expr.start_expr) || expression_line(expr.end_expr)
        when AST::ExpressionList
          expr.elements.filter_map { |element| expression_line(element) }.first
        when AST::IfExpr
          expression_line(expr.condition) || expression_line(expr.then_expression) || expression_line(expr.else_expression)
        when AST::AwaitExpr
          expression_line(expr.expression)
        when AST::UnsafeExpr
          expression_line(expr.expression)
        when AST::FormatString
          expr.parts.filter_map do |part|
            expression_line(part.expression) if part.is_a?(AST::FormatExprPart)
          end.first
        else
          nil
        end
      end
  
      def expression_column(expr)
        return nil unless expr
  
        if expr.respond_to?(:column) && expr.column
          return expr.column
        end
  
        case expr
        when AST::BinaryOp
          expression_column(expr.left) || expression_column(expr.right)
        when AST::UnaryOp
          expression_column(expr.operand)
        when AST::Specialization
          expression_column(expr.callee)
        when AST::Call
          expression_column(expr.callee)
        when AST::IndexAccess
          expression_column(expr.receiver)
        when AST::MemberAccess
          expression_column(expr.receiver)
        when AST::RangeExpr
          expression_column(expr.start_expr) || expression_column(expr.end_expr)
        when AST::ExpressionList
          expr.elements.filter_map { |element| expression_column(element) }.first
        when AST::IfExpr
          expression_column(expr.condition) || expression_column(expr.then_expression) || expression_column(expr.else_expression)
        when AST::AwaitExpr
          expression_column(expr.expression)
        when AST::UnsafeExpr
          expression_column(expr.expression)
        else
          nil
        end
      end
  
      def expression_length(expr)
        return nil unless expr
  
        case expr
        when AST::Identifier
          expr.name.length
        when AST::BooleanLiteral
          expr.value ? 4 : 5
        when AST::NullLiteral
          4
        when AST::IntegerLiteral, AST::FloatLiteral, AST::StringLiteral
          expr.lexeme.length
        when AST::BinaryOp
          left_column = expression_column(expr.left)
          right_column = expression_column(expr.right)
          right_length = expression_length(expr.right)
          if left_column && right_column && right_length
            (right_column + right_length) - left_column
          end
        when AST::UnaryOp
          expression_length(expr.operand)
        when AST::Specialization
          expression_length(expr.callee)
        when AST::Call
          expression_length(expr.callee)
        when AST::AwaitExpr
          expression_length(expr.expression)
        when AST::UnsafeExpr
          expression_length(expr.expression)
        else
          1
        end
      end
  
      def statement_column(statement)
        return nil unless statement
  
        if statement.respond_to?(:column) && statement.column
          return statement.column
        end
  
        case statement
        when AST::IfStmt
          statement.branches.first&.column || statement.else_column
        when AST::WhileStmt
          expression_column(statement.condition)
        when AST::MatchStmt
          expression_column(statement.expression)
        when AST::ReturnStmt
          expression_column(statement.value)
        when AST::DeferStmt
          expression_column(statement.expression)
        when AST::ExpressionStmt
          expression_column(statement.expression) || source_statement_span(statement.line)&.first
        else
          nil
        end
      end
  
      def statement_length(statement)
        return nil unless statement
  
        if statement.respond_to?(:length) && statement.length
          return statement.length
        end
  
        case statement
        when AST::LocalDecl, AST::ForStmt
          statement.name.length
        when AST::IfStmt
          statement.branches.first&.length || (statement.else_column ? 4 : nil)
        when AST::WhileStmt
          expression_length(statement.condition)
        when AST::MatchStmt
          expression_length(statement.expression)
        when AST::ReturnStmt
          expression_length(statement.value)
        when AST::DeferStmt
          expression_length(statement.expression)
        when AST::ExpressionStmt
          expression_length(statement.expression) || source_statement_span(statement.line)&.last
        else
          nil
        end
      end
  
      def condition_span(expr, line:, keyword_pattern:)
        source_span = source_condition_span(line, keyword_pattern:)
        if source_span
          [line, source_span.first, source_span.last]
        else
          [expression_line(expr) || line, expression_column(expr), expression_length(expr)]
        end
      end
  
      def condition_symbol_name(expr)
        case expr
        when AST::Identifier
          expr.name
        when AST::BooleanLiteral
          expr.value ? "true" : "false"
        when AST::BinaryOp
          condition_symbol_name(expr.left) || condition_symbol_name(expr.right)
        when AST::UnaryOp
          condition_symbol_name(expr.operand)
        when AST::Call
          condition_symbol_name(expr.callee)
        when AST::IndexAccess
          condition_symbol_name(expr.receiver)
        when AST::MemberAccess
          condition_symbol_name(expr.receiver)
        when AST::RangeExpr
          condition_symbol_name(expr.start_expr) || condition_symbol_name(expr.end_expr)
        else
          nil
        end
      end
      def each_statement_expression(statement, &block)
        case statement
        when AST::LocalDecl
          walk_expression_tree(statement.value, &block)
        when AST::Assignment
          walk_expression_tree(statement.target, &block)
          walk_expression_tree(statement.value, &block)
        when AST::IfBranch
          walk_expression_tree(statement.condition, &block)
        when AST::IfStmt
          statement.branches.each { |branch| walk_expression_tree(branch.condition, &block) }
        when AST::WhileStmt
          walk_expression_tree(statement.condition, &block)
        when AST::ForStmt
          statement.iterables.each { |iterable| walk_expression_tree(iterable, &block) }
        when AST::MatchStmt
          walk_expression_tree(statement.expression, &block)
        when AST::ReturnStmt
          walk_expression_tree(statement.value, &block)
        when AST::DeferStmt
          walk_expression_tree(statement.expression, &block)
        when AST::ExpressionStmt
          walk_expression_tree(statement.expression, &block)
        when AST::StaticAssert
          walk_expression_tree(statement.condition, &block)
        when AST::WhenStmt
          walk_expression_tree(statement.discriminant, &block)
          statement.branches.each { |branch| branch.body.each { |s| each_statement_expression(s, &block) } }
          statement.else_body&.each { |s| each_statement_expression(s, &block) }
        when AST::UnsafeStmt
          statement.body.each { |s| each_statement_expression(s, &block) }
        when AST::ErrorBlockStmt
          statement.body.each { |s| each_statement_expression(s, &block) }
        end
      end
  
      def walk_expression_tree(expression, &block)
        return unless expression
  
        yield expression
        case expression
        when AST::MemberAccess
          walk_expression_tree(expression.receiver, &block)
        when AST::IndexAccess
          walk_expression_tree(expression.receiver, &block)
          walk_expression_tree(expression.index, &block)
        when AST::Specialization
          walk_expression_tree(expression.callee, &block)
        when AST::Call
          walk_expression_tree(expression.callee, &block)
          expression.arguments.each { |argument| walk_expression_tree(argument.value, &block) }
        when AST::UnaryOp
          walk_expression_tree(expression.operand, &block)
        when AST::BinaryOp
          walk_expression_tree(expression.left, &block)
          walk_expression_tree(expression.right, &block)
        when AST::RangeExpr
          walk_expression_tree(expression.start_expr, &block)
          walk_expression_tree(expression.end_expr, &block)
        when AST::ExpressionList
          expression.elements.each { |element| walk_expression_tree(element, &block) }
        when AST::IfExpr
          walk_expression_tree(expression.condition, &block)
          walk_expression_tree(expression.then_expression, &block)
          walk_expression_tree(expression.else_expression, &block)
        when AST::AwaitExpr
          walk_expression_tree(expression.expression, &block)
        when AST::UnsafeExpr
          walk_expression_tree(expression.expression, &block)
        when AST::FormatString
          expression.parts.each do |part|
            walk_expression_tree(part.expression, &block) if part.is_a?(AST::FormatExprPart)
          end
        end
      end
      def walk_statement_lists(stmts, &block)
        return if stmts.nil? || stmts.empty?
  
        yield stmts
        stmts.each do |statement|
          case statement
          when AST::IfStmt
            statement.branches.each { |branch| walk_statement_lists(branch.body, &block) }
            walk_statement_lists(statement.else_body, &block) if statement.else_body
          when AST::MatchStmt
            statement.arms.each { |arm| walk_statement_lists(arm.body, &block) }
          when AST::UnsafeStmt, AST::ForStmt, AST::WhileStmt
            walk_statement_lists(statement.body, &block)
          when AST::DeferStmt
            walk_statement_lists(statement.body, &block) if statement.body
          end
        end
      end
    end
  end
end
