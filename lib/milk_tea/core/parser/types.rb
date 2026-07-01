# frozen_string_literal: true

module MilkTea
  module Parse
    module Types
      private

      def parse_params(allow_variadic: false)
        parse_parameter_list(allow_variadic:) { parse_param }
      end

      def parse_signature_params
        parse_parameter_list { parse_param }
      end

      def parse_foreign_params(allow_variadic: false)
        parse_parameter_list(allow_variadic:) { parse_foreign_param }
      end

      def parse_parameter_list(allow_variadic: false)
        consume(:lparen, "expected '('")
        params = []
        variadic = false

        unless check(:rparen)
          loop do
            if allow_variadic && match(:ellipsis)
              variadic = true
              break
            end

            params << yield
            break unless match(:comma)
            break if check(:rparen)
          end
        end

        consume(:rparen, "expected ')' after parameters")
        return [params, variadic] if allow_variadic

        params
      end

      def parse_param
        name_token = consume_name("expected parameter name")
        raise error(name_token, "expected ':' and parameter type") unless match(:colon)

        param_type = parse_type_ref

        AST::Param.new(name: name_token.lexeme, type: param_type, line: name_token.line, column: name_token.column)
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        param_name = name_token&.lexeme || "error"
        error_type = recovery_error_expr(e)
        AST::Param.new(name: param_name, type: error_type, line: name_token&.line || 1, column: name_token&.column || 1)
      end

      def parse_foreign_param
        mode = if foreign_param_qualifier_mode?
                 advance.type
               else
                 :plain
               end
        name_token = consume_name("expected parameter name")
        raise error(name_token, "expected ':' and parameter type") unless match(:colon)

        param_type = parse_type_ref
        boundary_type = match(:as) ? parse_type_ref : nil

        AST::ForeignParam.new(name: name_token.lexeme, type: param_type, mode:, boundary_type:)
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        param_name = name_token&.lexeme || "error"
        error_type = recovery_error_expr(e)
        AST::ForeignParam.new(name: param_name, type: error_type, mode: mode || :plain, boundary_type: nil)
      end

      def parse_type_ref
        return parse_function_type_ref if match(:fn)
        return parse_proc_type_ref if match(:proc)
        return parse_dyn_type_ref if match(:dyn)
        return parse_tuple_type_ref if check(:lparen)

        first_token = peek
        if match(:at)
          lt_token = consume_name("expected lifetime name after @")
          return AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["@#{lt_token.lexeme}"]), arguments: [], nullable: false, lifetime: nil, line: first_token.line, column: first_token.column, length: lt_token.lexeme.length + 1)
        end
        name = parse_qualified_name
        arguments = []
        lifetime = nil
        if match(:lbracket)
          if check(:at) && name.to_s == "ref"
            match(:at)
            lt_token = consume_name("expected lifetime name after @")
            lifetime = "@#{lt_token.lexeme}"
            consume(:comma, "expected ',' after lifetime in type arguments")
          end
          arguments = parse_comma_separated_until(:rbracket) do
            AST::TypeArgument.new(value: parse_type_argument)
          end
          consume(:rbracket, "expected ']' after type arguments")
        end

        nullable = match(:question)
        type_name = name.to_s
        length = type_name.length + (nullable ? 1 : 0)
        AST::TypeRef.new(name:, arguments:, nullable:, lifetime:, line: first_token.line, column: first_token.column, length:)
      end

      def parse_function_type_ref
        parse_callable_type_ref(keyword: "fn", param_context: "function type parameters") do |params, return_type|
          AST::FunctionType.new(params:, return_type:)
        end
      end

      def parse_proc_type_ref
        parse_callable_type_ref(keyword: "proc", param_context: "proc type parameters") do |params, return_type|
          AST::ProcType.new(params:, return_type:)
        end
      end

      def parse_dyn_type_ref
        first_token = previous
        consume(:lbracket, "expected '[' after dyn")
        interface = parse_qualified_name_with_type_arguments
        consume(:rbracket, "expected ']' after interface name")
        nullable = match(:question)
        AST::DynType.new(interface:, nullable:, line: first_token.line, column: first_token.column, length: 3)
      end

      def parse_tuple_type_ref
        match(:lparen)
        first_type = parse_type_ref
        if match(:comma)
          element_types = [first_type]
          loop do
            element_types << parse_type_ref
            break unless match(:comma)
          end
          consume(:rparen, "expected ')' after tuple type elements")
          nullable = match(:question)
          AST::TupleType.new(element_types:, nullable:)
        else
          consume(:rparen, "expected ')' after type")
          first_type
        end
      end

      def parse_callable_type_ref(keyword:, param_context:)
        consume(:lparen, "expected '(' after #{keyword}")
        params = parse_comma_separated_until(:rparen) { parse_function_type_param }

        consume(:rparen, "expected ')' after #{param_context}")
        consume(:arrow, "expected '->' after #{param_context}")
        return_type = parse_type_ref
        yield params, return_type
      end

      def parse_function_type_param
        name_token = consume_name("expected function type parameter name")
        name = name_token.lexeme
        consume(:colon, "expected ':' after function type parameter name")
        type = parse_type_ref
        AST::Param.new(name:, type:, line: name_token.line, column: name_token.column)
      end

      def parse_type_argument
        if match(:integer)
          token = previous
          AST::IntegerLiteral.new(lexeme: token.lexeme, value: token.literal)
        elsif match(:float)
          token = previous
          AST::FloatLiteral.new(lexeme: token.lexeme, value: token.literal)
        else
          parse_type_ref
        end
      end

      def parse_declaration_type_params
        return [] unless match(:lbracket)

        params = parse_comma_separated_until(:rbracket) do
          name_token = consume_name("expected type parameter name")
          name = name_token.lexeme
          if match(:colon)
            value_type = parse_type_ref
            AST::ValueTypeParam.new(
              name:,
              type: value_type,
              line: name_token.line,
              column: name_token.column,
              length: name.length,
            )
          else
            constraints = parse_type_param_constraints
            AST::TypeParam.new(
              name:,
              constraints:,
              line: name_token.line,
              column: name_token.column,
              length: name.length,
            )
          end
        end

        consume(:rbracket, "expected ']' after type parameters")
        params
      end

      def parse_type_param_constraints
        constraints = []
        interface_constraint_mode = false

        constraint, interface_constraint_mode = parse_type_param_constraint(interface_constraint_mode)
        return constraints unless constraint

        constraints << constraint

        while match(:and)
          constraint, interface_constraint_mode = parse_type_param_constraint(interface_constraint_mode)
          raise error(peek, "expected constraint after 'and'") unless constraint

          constraints << constraint
        end

        constraints
      end

      def parse_type_param_constraint(interface_constraint_mode)
        if match(:implements)
          return [AST::TypeParamConstraint.new(kind: :interface, interface_ref: parse_qualified_name_with_type_arguments), true]
        end

        return [AST::TypeParamConstraint.new(kind: :interface, interface_ref: parse_qualified_name_with_type_arguments), true] if interface_constraint_mode

        [nil, interface_constraint_mode]
      end

      def parse_implements_clause
        return [] unless match(:implements)

        implements = [parse_qualified_name_with_type_arguments]
        implements << parse_qualified_name_with_type_arguments while match(:comma)
        implements
      end

      def parse_qualified_name_with_type_arguments
        first_token = consume_path_component("expected identifier")
        parts = [first_token.lexeme]
        while match(:dot)
          parts << consume_path_component("expected identifier after '.'").lexeme
        end
        type_arguments = if match(:lbracket)
                           args = parse_comma_separated_until(:rbracket) do
                             parse_type_ref
                           end
                           consume(:rbracket, "expected ']' after type arguments")
                           args
                         else
                           []
                         end
        AST::QualifiedName.new(parts:, type_arguments:, line: first_token.line, column: first_token.column)
      end
    end
  end
end
