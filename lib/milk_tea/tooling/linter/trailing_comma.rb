# frozen_string_literal: true

module MilkTea
  class Linter
    module LinterTrailingComma
      private

      def emit_trailing_list_comma_warnings(source_file)
        return if @tokens.nil? || @tokens.empty?
  
        warned_sites = Set.new
        each_call_argument_list_candidate(source_file) do |call_expression, symbol_name|
          site = trailing_call_argument_comma_site(call_expression)
          next unless site
          next if warned_sites.include?(site)
  
          warned_sites << site
          @warnings << Warning.new(
            path: @path,
            line: site[0],
            column: site[1],
            length: 1,
            code: "trailing-list-comma",
            message: "trailing comma in call argument list is redundant",
            severity: :hint,
            symbol_name:,
          )
        end
      end
  
      def each_call_argument_list_candidate(source_file, &block)
        source_file.declarations.each do |declaration|
          case declaration
          when AST::ConstDecl, AST::VarDecl
            each_call_in_expression(declaration.value, &block)
          when AST::FunctionDef, AST::MethodDef
            each_call_in_statement_list(declaration.body, &block)
          when AST::ExtendingBlock
            declaration.methods.each { |method| each_call_in_statement_list(method.body, &block) }
          end
        end
      end
  
      def each_call_in_statement_list(stmts, &block)
        walk_statement_lists(stmts) do |statement_list|
          statement_list.each do |statement|
            each_statement_expression(statement) do |expression|
              next unless expression.is_a?(AST::Call)
              next if expression.arguments.nil? || expression.arguments.empty?
  
              block.call(expression, call_symbol_name(expression.callee))
            end
          end
        end
      end
  
      def each_call_in_expression(expression, &block)
        walk_expression_tree(expression) do |node|
          next unless node.is_a?(AST::Call)
          next if node.arguments.nil? || node.arguments.empty?
  
          block.call(node, call_symbol_name(node.callee))
        end
      end
  
      def call_symbol_name(callee)
        case callee
        when AST::Identifier
          callee.name
        when AST::MemberAccess
          callee.member
        when AST::Specialization
          call_symbol_name(callee.callee)
        else
          nil
        end
      end
  
      def trailing_call_argument_comma_site(call_expression)
        return nil unless call_expression.is_a?(AST::Call)
        return nil if call_expression.arguments.nil? || call_expression.arguments.empty?
  
        callee_line = expression_line(call_expression.callee)
        callee_column = expression_column(call_expression.callee)
        return nil unless callee_line && callee_column
  
        callee_token_idx = @token_index_by_location[[callee_line, callee_column]]
        return nil unless callee_token_idx
  
        lparen_idx = nil
        cursor = callee_token_idx
        while cursor < @tokens.length
          token = @tokens[cursor]
          if token.type == :lparen
            lparen_idx = cursor
            break
          end
          break if token.type == :newline && token.line > callee_line
  
          cursor += 1
        end
        return nil unless lparen_idx
  
        paren_depth = 0
        bracket_depth = 0
        comma_token = nil
        cursor = lparen_idx + 1
  
        while cursor < @tokens.length
          token = @tokens[cursor]
          case token.type
          when :lparen
            paren_depth += 1
          when :rparen
            if paren_depth.zero? && bracket_depth.zero?
              return [comma_token.line, comma_token.column] if comma_token
  
              return nil
            end
            paren_depth -= 1 if paren_depth.positive?
          when :lbracket
            bracket_depth += 1
          when :rbracket
            bracket_depth -= 1 if bracket_depth.positive?
          when :comma
            comma_token = token if paren_depth.zero? && bracket_depth.zero?
          else
            if paren_depth.zero? && bracket_depth.zero? && !%i[newline indent dedent eof].include?(token.type)
              comma_token = nil
            end
          end
          cursor += 1
        end
  
        nil
      end
    end
  end
end
