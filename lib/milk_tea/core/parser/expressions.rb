# frozen_string_literal: true

module MilkTea
  module Parse
    module Expressions
      private

      def parse_expression
        return parse_if_expression if match(:if)
        return parse_match_expression if match(:match)
        return parse_unsafe_expression if match(:unsafe)

        parse_range
      end

      def parse_range
        expr = parse_or
        return expr unless match(:dot_dot)

        line = previous.line
        column = expr.respond_to?(:column) ? expr.column : 0
        end_expr = parse_or
        AST::RangeExpr.new(start_expr: expr, end_expr:, line:, column:)
      end

      def parse_if_expression
        condition = parse_or
        consume(:colon, "expected ':' after condition in if expression")
        then_expression = parse_expression
        consume(:else, "expected 'else' in if expression")
        consume(:colon, "expected ':' after 'else' in if expression")
        else_expression = parse_expression
        AST::IfExpr.new(condition:, then_expression:, else_expression:)
      end

      def parse_match_expression
        token = previous
        expression = parse_expression
        arms = parse_match_expression_arms
        AST::MatchExpr.new(expression:, arms:, line: token.line, column: token.column, length: token.lexeme.length)
      end

      def parse_match_expression_arms
        consume(:colon, "expected ':' before match expression arms")
        consume(:newline, "expected newline before match expression arms")
        consume(:indent, "expected indented match expression arms")

        arms = []
        skip_newlines
        until check(:dedent) || eof?
          arms.concat(parse_match_expression_arm)
          skip_newlines
        end

        consume(:dedent, "expected end of match expression arms")
        arms
      end

      def parse_match_expression_arm
        patterns = []
        if match(:else)
          patterns << AST::Identifier.new(name: "_", line: previous.line, column: previous.column)
        else
          patterns << parse_bitwise_xor
          while match(:pipe)
            patterns << parse_bitwise_xor
          end
        end
        binding_token = nil
        binding_name = if match(:as)
                         binding_token = consume_name("expected binding name after 'as'")
                         binding_token.lexeme
                       end
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
      end

      def parse_unsafe_expression
        token = previous
        consume(:colon, "expected ':' after unsafe in expression")
        expression = parse_expression
        AST::UnsafeExpr.new(expression:, line: token.line, column: token.column, length: token.lexeme.length)
      end

      def parse_or
        parse_left_associative(:parse_and, :or)
      end

      def parse_and
        parse_left_associative(:parse_not, :and)
      end

      def parse_not
        if match(:not)
          operator = previous.lexeme
          operand = parse_not
          return AST::UnaryOp.new(operator:, operand:)
        end

        parse_is
      end

      def parse_is
        expr = parse_bitwise_or
        while match(:is)
          line = previous.line
          column = previous.column
          arm_pattern = parse_bitwise_or
          if arm_pattern.is_a?(AST::Call) && arm_pattern.arguments.any?
            raise error(previous, "`is` does not support struct pattern bindings; use `match` to destructure payload fields")
          end

          expr = AST::MatchExpr.new(
            expression: expr,
            arms: [
              AST::MatchExprArm.new(
                pattern: arm_pattern,
                binding_name: nil,
                binding_line: nil,
                binding_column: nil,
                value: AST::BooleanLiteral.new(value: true),
              ),
              AST::MatchExprArm.new(
                pattern: AST::Identifier.new(name: "_", line:, column:),
                binding_name: nil,
                binding_line: nil,
                binding_column: nil,
                value: AST::BooleanLiteral.new(value: false),
              ),
            ],
            line:,
            column:,
            length: previous.lexeme.length,
            desugared_from_is: true,
          )
        end
        expr
      end

      def parse_bitwise_or
        parse_left_associative(:parse_bitwise_xor, :pipe)
      end

      def parse_bitwise_xor
        parse_left_associative(:parse_bitwise_and, :caret)
      end

      def parse_bitwise_and
        parse_left_associative(:parse_equality, :amp)
      end

      def parse_equality
        parse_left_associative(:parse_comparison, :equal_equal, :bang_equal)
      end

      def parse_comparison
        parse_left_associative(:parse_shift, :less, :less_equal, :greater, :greater_equal)
      end

      def parse_shift
        parse_left_associative(:parse_additive, :shift_left, :shift_right)
      end

      def parse_additive
        parse_left_associative(:parse_multiplicative, :plus, :minus)
      end

      def parse_multiplicative
        parse_left_associative(:parse_unary, :star, :slash, :percent)
      end

      def parse_unary
        if (cast_prefix = try_parse_prefix_cast_expression)
          cast_prefix
        elsif match(:unsafe)
          parse_unsafe_expression
        elsif match(:await)
          AST::AwaitExpr.new(expression: parse_unary)
        elsif match(:detach)
          line = previous.line
          column = previous.column
          AST::DetachExpr.new(body: [AST::ExpressionStmt.new(expression: parse_unary)], line:, column:)
        elsif match(:minus, :plus, :tilde, :out, :in, :inout)
          operator = previous.lexeme
          operand = parse_unary
          AST::UnaryOp.new(operator:, operand:)
        else
          parse_postfix
        end
      end

      def try_parse_prefix_cast_expression
        saved_current = @current
        return nil unless check_name && known_type_like_name?(peek.lexeme)

        start_token = peek
        expression = nil
        target_type = parse_type_ref
        type_tail = @tokens[@current - 1]
        less_token = peek
        return nil unless less_token.type == :less

        minus_token = @tokens[@current + 1]
        return nil unless minus_token&.type == :minus

        unless adjacent_tokens?(type_tail, less_token) && adjacent_tokens?(less_token, minus_token)
          raise error(less_token, "did you mean T<-expr?")
        end

        advance
        advance

        expression = parse_unary
        AST::PrefixCast.new(target_type:, expression:, line: start_token.line, column: start_token.column)
      rescue ParseError => e
        raise e if parse_diagnostic_hint?(e)

        nil
      ensure
        @current = saved_current if expression.nil?
      end

      def adjacent_tokens?(left, right)
        left.line == right.line && right.column == (left.column + left.lexeme.length)
      end

      def parse_postfix
        expression = parse_primary

        loop do
          if match(:dot)
            member_token = consume_name_allowing_keywords("expected member name after '.'")
            expression = AST::MemberAccess.new(
              receiver: expression,
              member: member_token.lexeme,
              line: member_token.line,
              column: member_token.column,
            )
          elsif check(:lbracket)
            if (specialization = try_parse_specialization(expression))
              expression = specialization
            else
              advance
              index = parse_expression
              consume(:rbracket, "expected ']' after index expression")
              expression = AST::IndexAccess.new(receiver: expression, index:)
            end
          elsif match(:lparen)
            expression = AST::Call.new(callee: expression, arguments: parse_call_arguments)
          elsif match(:question)
            expression = AST::UnaryOp.new(operator: "?", operand: expression)
          else
            break
          end
        end

        expression
      end

      def try_parse_specialization(expression)
        return nil unless postfix_bracket_starts_specialization?(expression)

        saved_current = @current
        advance
        arguments = parse_comma_separated_until(:rbracket) do
          AST::TypeArgument.new(value: parse_type_argument)
        end
        consume(:rbracket, "expected ']' after specialization arguments")

        if match(:lparen)
          call_arguments = parse_call_arguments
          unless specialization_call_target?(expression, arguments, call_arguments)
            @current = saved_current
            return nil
          end

          return AST::Call.new(callee: AST::Specialization.new(callee: expression, arguments:), arguments: call_arguments)
        end

        unless specialization_value_target?(expression, arguments)
          @current = saved_current
          return nil
        end

        AST::Specialization.new(callee: expression, arguments:)
      rescue ParseError => e
        raise e if parse_diagnostic_hint?(e)

        @current = saved_current
        nil
      end

      def parse_call_arguments
        arguments = []
        unless check(:rparen)
          loop do
            arguments << parse_call_argument
            break unless match(:comma)
            break if check(:rparen)
          end
        end
        consume(:rparen, "expected ')' after call arguments")
        arguments
      end

      def parse_call_argument
        if check_name && check_next(:equal)
          name = advance.lexeme
          consume(:equal, "expected '=' after named argument name")
          AST::Argument.new(name:, value: parse_expression)
        else
          AST::Argument.new(name: nil, value: parse_expression)
        end
      end

      def parse_primary
        if match(:size_of)
          parse_sizeof_expr
        elsif match(:align_of)
          parse_alignof_expr
        elsif match(:offset_of)
          parse_offsetof_expr
        elsif match(:members_of) || match(:attributes_of) || match(:field_of) || match(:callable_of) || match(:attribute_of) || match(:has_attribute) || match(:attribute_arg) || match(:fields_of)
          AST::Identifier.new(name: previous.lexeme, line: previous.line, column: previous.column)
        elsif match(:proc)
          parse_proc_expr
        elsif match_name
          AST::Identifier.new(name: previous.lexeme, line: previous.line, column: previous.column)
        elsif match(:integer)
          AST::IntegerLiteral.new(lexeme: previous.lexeme, value: previous.literal)
        elsif match(:float)
          AST::FloatLiteral.new(lexeme: previous.lexeme, value: previous.literal)
        elsif match(:char_literal)
          AST::CharLiteral.new(lexeme: previous.lexeme, value: previous.literal, line: previous.line, column: previous.column)
        elsif match(:string)
          parse_adjacent_string_literal(previous, cstring: false)
        elsif match(:cstring)
          parse_adjacent_string_literal(previous, cstring: true)
        elsif match(:fstring)
          parse_format_string_literal(previous.literal)
        elsif match(:true)
          AST::BooleanLiteral.new(value: true)
        elsif match(:false)
          AST::BooleanLiteral.new(value: false)
        elsif match(:null)
          line = previous.line
          column = previous.column
          type = nil
          if match(:lbracket)
            type = parse_type_ref
            consume(:rbracket, "expected ']' after typed null literal")
          end
          AST::NullLiteral.new(type:, line:, column:)
        elsif match(:lparen)
          line = previous.line
          column = previous.column
          first = if check_name && check_next(:equal)
                    name_token = advance
                    consume(:equal, "expected '=' after named tuple field")
                    AST::Argument.new(name: name_token.lexeme, value: parse_expression)
                  else
                    parse_expression
                  end
          if match(:comma)
            elements = [first]
            loop do
              if check_name && check_next(:equal)
                name_token = advance
                consume(:equal, "expected '=' after named tuple field")
                value = parse_expression
                elements << AST::Argument.new(name: name_token.lexeme, value:)
              else
                elements << parse_expression
              end
              break unless match(:comma)
              break if check(:rparen)
            end
            consume(:rparen, "expected ')' after tuple elements")
            AST::ExpressionList.new(elements:, line:, column:)
          else
            consume(:rparen, "expected ')' after expression")
            first
          end
        elsif keyword_token?(peek)
          advance
          AST::Identifier.new(name: previous.lexeme, line: previous.line, column: previous.column)
        else
          raise error(peek, "expected expression")
        end
      end

      def parse_adjacent_string_literal(first_token, cstring:)
        lexeme = +first_token.lexeme
        value = +first_token.literal
        all_cstring = cstring

        while match(:string, :cstring)
          token = previous
          lexeme << token.lexeme
          value << token.literal
          all_cstring &&= token.type == :cstring
        end

        AST::StringLiteral.new(lexeme:, value:, cstring: all_cstring)
      end

      def parse_proc_expr
        consume(:lparen, "expected '(' after proc")
        params = parse_comma_separated_until(:rparen) { parse_function_type_param }

        consume(:rparen, "expected ')' after proc parameters")
        consume(:arrow, "expected '->' after proc parameters")
        return_type = parse_type_ref
        consume(:colon, "expected ':' before proc body")
        body = if match(:newline)
                 consume(:indent, "expected indented block")
                 statements = parse_statement_block_body
                 consume(:dedent, "expected end of block")
                 statements
               else
                 [AST::ReturnStmt.new(value: parse_expression)]
               end
        AST::ProcExpr.new(params:, return_type:, body:)
      end

      def parse_sizeof_expr
        consume(:lparen, "expected '(' after size_of")
        type = parse_type_ref
        consume(:rparen, "expected ')' after size_of type")
        AST::SizeofExpr.new(type:)
      end

      def parse_alignof_expr
        consume(:lparen, "expected '(' after align_of")
        type = parse_type_ref
        consume(:rparen, "expected ')' after align_of type")
        AST::AlignofExpr.new(type:)
      end

      def parse_offsetof_expr
        consume(:lparen, "expected '(' after offset_of")
        type = parse_type_ref
        consume(:comma, "expected ',' after offset_of type")
        field = consume_name("expected field name in offset_of").lexeme
        consume(:rparen, "expected ')' after offset_of field")
        AST::OffsetofExpr.new(type:, field:)
      end

      def parse_format_string_literal(parts)
        AST::FormatString.new(parts: parts.map { |part| parse_format_string_part(part) })
      end

      def parse_format_string_part(part)
        case part.fetch(:kind)
        when :text
          AST::FormatTextPart.new(value: part.fetch(:value))
        when :expr
          format_spec = parse_format_spec(part.fetch(:format_spec))
          AST::FormatExprPart.new(
            expression: parse_embedded_expression(part.fetch(:source), line: part.fetch(:line), column: part.fetch(:column)),
            format_spec:,
          )
        else
          raise error(peek, "unsupported format string part #{part.inspect}")
        end
      end

      def parse_format_spec(spec_str)
        return nil if spec_str.nil? || spec_str.empty?

        trimmed = spec_str.strip
        if (m = trimmed.match(/\A\.(\d+)\z/))
          { kind: :precision, value: m[1].to_i }
        elsif trimmed == "x"
          { kind: :hex, uppercase: false }
        elsif trimmed == "X"
          { kind: :hex, uppercase: true }
        elsif trimmed == "o"
          { kind: :oct, uppercase: false }
        elsif trimmed == "O"
          { kind: :oct, uppercase: true }
        elsif trimmed == "b"
          { kind: :bin, uppercase: false }
        elsif trimmed == "B"
          { kind: :bin, uppercase: true }
        else
          raise error(peek, "unsupported format spec '#{trimmed}': expected .N for float precision (e.g. :.2), :x/:X, :o/:O, or :b/:B")
        end
      end

      def parse_embedded_expression(source, line:, column:)
        # Interpolation source may carry surrounding whitespace (e.g. `#{ x }`);
        # strip it so leading whitespace is not re-lexed as indentation. Shift
        # the column by the stripped leading width to keep error positions exact.
        leading = source.length - source.lstrip.length
        stripped = source.strip
        tokens = Lexer.lex(stripped, path: @path).map do |token|
          Token.new(
            type: token.type,
            lexeme: token.lexeme,
            literal: token.literal,
            line: token.line + line - 1,
            column: token.column + column - 1 + leading,
            start_offset: token.start_offset,
            end_offset: token.end_offset,
            leading_trivia: token.leading_trivia,
            trailing_trivia: token.trailing_trivia,
          )
        end

        parser = self.class.send(:new, tokens, path: @path)
        parser.instance_variable_set(:@known_type_names, @known_type_names.dup)
        parser.instance_variable_set(:@known_import_aliases, @known_import_aliases.dup)
        parser.instance_variable_set(:@known_generic_callable_names, @known_generic_callable_names.dup)
        parser.instance_variable_set(:@current_type_param_names, @current_type_param_names.dup)

        expression = parser.send(:parse_expression)
        parser.send(:skip_newlines)
        raise parser.send(:error, parser.send(:peek), "expected end of interpolation") unless parser.send(:eof?)

        expression
      end

      def parse_left_associative(operand_method, *operator_types)
        expression = send(operand_method)
        while match(*operator_types)
          operator = previous.lexeme
          right = send(operand_method)
          expression = AST::BinaryOp.new(operator:, left: expression, right:)
        end
        expression
      end

      def postfix_bracket_starts_specialization?(expression)
        specialization_target?(expression) && matching_rbracket_index(@current)
      end

      def specialization_target?(expression)
        builtin_specialization_target?(expression) || aggregate_specialization_target?(expression)
      end

      def builtin_specialization_target?(expression)
        expression.is_a?(AST::Identifier) && %w[array reinterpret span zero ptr const_ptr own ref adapt equal hash order].include?(expression.name)
      end

      def parse_diagnostic_hint?(error)
        error.message.include?("did you mean T<-expr?")
      end

      def aggregate_specialization_target?(expression)
        case expression
        when AST::Identifier
          true
        when AST::MemberAccess
          true
        else
          false
        end
      end

      def specialization_call_target?(expression, arguments, call_arguments)
        if expression.is_a?(AST::Identifier) && %w[default zero].include?(expression.name) &&
            !known_type_like_name?(expression.name) && !generic_callable_specialization_target?(expression)
          return false
        end

        return true if builtin_specialization_target?(expression)
        return true if aggregate_specialization_target?(expression) && call_arguments.all?(&:name)
        return true if generic_callable_specialization_target?(expression) && arguments.all? { |argument| explicit_specialization_argument?(argument.value) }
        return true if imported_member_specialization_target?(expression) && arguments.all? { |argument| explicit_specialization_argument?(argument.value) }

        aggregate_specialization_target?(expression) && arguments.all? { |argument| definite_type_argument?(argument.value) }
      end

      def specialization_value_target?(expression, arguments)
        return true if expression.is_a?(AST::Identifier) && expression.name == "zero" && arguments.all? { |argument| explicit_specialization_argument?(argument.value) }
        return true if aggregate_specialization_target?(expression) && arguments.all? { |argument| definite_type_argument?(argument.value) }
        return true if generic_callable_specialization_target?(expression) && arguments.all? { |argument| explicit_specialization_argument?(argument.value) }
        return true if imported_member_specialization_target?(expression) && arguments.all? { |argument| explicit_specialization_argument?(argument.value) }

        false
      end

      def generic_callable_specialization_target?(expression)
        expression.is_a?(AST::Identifier) && @known_generic_callable_names.key?(expression.name)
      end

      def imported_member_specialization_target?(expression)
        expression.is_a?(AST::MemberAccess) && expression.receiver.is_a?(AST::Identifier) && @known_import_aliases.key?(expression.receiver.name)
      end

      def explicit_specialization_argument?(value)
        definite_type_argument?(value) ||
          potential_named_literal_type_argument?(value) ||
          value.is_a?(AST::IntegerLiteral) ||
          value.is_a?(AST::FloatLiteral)
      end

      def potential_named_literal_type_argument?(value)
        value.is_a?(AST::TypeRef) && value.arguments.empty? && !value.nullable
      end

      def definite_type_argument?(value)
        case value
        when AST::FunctionType
          true
        when AST::TypeRef
          known_type_like_name?(value.name.parts.first)
        else
          false
        end
      end
    end
  end
end
