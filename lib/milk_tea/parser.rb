# frozen_string_literal: true

module MilkTea
  class ParseError < StandardError
    attr_reader :token, :path

    def initialize(message, token:, path: nil)
      @token = token
      @path = path

      location = [path, "#{token.line}:#{token.column}"].compact.join(":")
      super(location.empty? ? message : "#{message} at #{location}")
    end
  end

  class Parser
    def self.parse(source = nil, path: nil, tokens: nil)
      token_stream = tokens || Lexer.lex(source, path: path)
      new(token_stream, path: path).parse
    end

    def initialize(tokens, path: nil)
      @tokens = tokens
      @path = path
      @current = 0
    end

    def parse
      skip_newlines

      module_name = match(:module) ? parse_module_name : nil

      imports = []
      skip_newlines
      while match(:import)
        imports << parse_import
        skip_newlines
      end

      declarations = []
      until eof?
        declarations << parse_declaration
        skip_newlines
      end

      AST::SourceFile.new(module_name:, imports:, declarations:)
    end

    private

    def parse_module_name
      name = parse_qualified_name
      consume_end_of_statement
      name
    end

    def parse_import
      path = parse_qualified_name
      alias_name = match(:as) ? consume(:identifier, "expected import alias").lexeme : nil
      consume_end_of_statement
      AST::Import.new(path:, alias_name:)
    end

    def parse_declaration
      if match(:const)
        parse_const_decl
      elsif match(:struct)
        parse_struct_decl
      elsif match(:impl)
        parse_impl_block
      elsif match(:def)
        parse_function_def
      else
        raise error(peek, "expected declaration")
      end
    end

    def parse_const_decl
      name = consume(:identifier, "expected constant name").lexeme
      consume(:colon, "expected ':' after constant name")
      type = parse_type_ref
      consume(:equal, "expected '=' after constant type")
      value = parse_expression
      consume_end_of_statement
      AST::ConstDecl.new(name:, type:, value:)
    end

    def parse_struct_decl
      name = consume(:identifier, "expected struct name").lexeme
      fields = parse_named_block do
        field_name = consume(:identifier, "expected field name").lexeme
        consume(:colon, "expected ':' after field name")
        field_type = parse_type_ref
        consume_end_of_statement
        AST::Field.new(name: field_name, type: field_type)
      end
      AST::StructDecl.new(name:, fields:)
    end

    def parse_impl_block
      type_name = parse_qualified_name
      methods = parse_named_block do
        consume(:def, "expected method declaration")
        parse_function_def
      end
      AST::ImplBlock.new(type_name:, methods:)
    end

    def parse_function_def
      name = consume(:identifier, "expected function name").lexeme
      params = parse_params
      return_type = match(:arrow) ? parse_type_ref : nil
      body = parse_block
      AST::FunctionDef.new(name:, params:, return_type:, body:)
    end

    def parse_params
      consume(:lparen, "expected '('")
      params = []

      unless check(:rparen)
        loop do
          params << parse_param
          break unless match(:comma)
        end
      end

      consume(:rparen, "expected ')' after parameters")
      params
    end

    def parse_param
      mutable = match(:mut)
      name_token = consume(:identifier, "expected parameter name")
      param_type = nil
      if match(:colon)
        param_type = parse_type_ref
      elsif name_token.lexeme != "self"
        raise error(name_token, "expected ':' and parameter type")
      end

      AST::Param.new(name: name_token.lexeme, type: param_type, mutable:)
    end

    def parse_type_ref
      name = parse_qualified_name
      arguments = []
      if match(:lbracket)
        unless check(:rbracket)
          loop do
            arguments << AST::TypeArgument.new(value: parse_type_argument)
            break unless match(:comma)
          end
        end
        consume(:rbracket, "expected ']' after type arguments")
      end

      nullable = match(:question)
      AST::TypeRef.new(name:, arguments:, nullable:)
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

    def parse_block
      consume(:colon, "expected ':' before block")
      consume(:newline, "expected newline before block")
      consume(:indent, "expected indented block")

      statements = []
      skip_newlines
      until check(:dedent) || eof?
        statements << parse_statement
        skip_newlines
      end

      consume(:dedent, "expected end of block")
      statements
    end

    def parse_named_block(&block)
      consume(:colon, "expected ':' before block")
      consume(:newline, "expected newline before block")
      consume(:indent, "expected indented block")

      items = []
      skip_newlines
      until check(:dedent) || eof?
        items << block.call
        skip_newlines
      end

      consume(:dedent, "expected end of block")
      items
    end

    def parse_statement
      if match(:let)
        parse_local_decl(:let)
      elsif match(:var)
        parse_local_decl(:var)
      elsif match(:if)
        parse_if_stmt
      elsif match(:while)
        parse_while_stmt
      elsif match(:return)
        parse_return_stmt
      elsif match(:defer)
        parse_defer_stmt
      else
        parse_assignment_or_expression_stmt
      end
    end

    def parse_local_decl(kind)
      name = consume(:identifier, "expected local variable name").lexeme
      var_type = match(:colon) ? parse_type_ref : nil
      consume(:equal, "expected '=' in local declaration")
      value = parse_expression
      consume_end_of_statement
      AST::LocalDecl.new(kind:, name:, type: var_type, value:)
    end

    def parse_if_stmt
      branches = []
      branches << AST::IfBranch.new(condition: parse_expression, body: parse_block)

      while match(:elif)
        branches << AST::IfBranch.new(condition: parse_expression, body: parse_block)
      end

      else_body = match(:else) ? parse_block : nil
      AST::IfStmt.new(branches:, else_body:)
    end

    def parse_while_stmt
      condition = parse_expression
      body = parse_block
      AST::WhileStmt.new(condition:, body:)
    end

    def parse_return_stmt
      value = check(:newline) ? nil : parse_expression
      consume_end_of_statement
      AST::ReturnStmt.new(value:)
    end

    def parse_defer_stmt
      expression = parse_expression
      consume_end_of_statement
      AST::DeferStmt.new(expression:)
    end

    def parse_assignment_or_expression_stmt
      expression = parse_expression
      if match(*Token::ASSIGNMENT_TYPES)
        operator = previous.lexeme
        value = parse_expression
        consume_end_of_statement
        AST::Assignment.new(target: expression, operator:, value:)
      else
        consume_end_of_statement
        AST::ExpressionStmt.new(expression:)
      end
    end

    def parse_expression
      parse_or
    end

    def parse_or
      parse_left_associative(:parse_and, :or)
    end

    def parse_and
      parse_left_associative(:parse_comparison, :and)
    end

    def parse_comparison
      parse_left_associative(:parse_additive, :equal_equal, :bang_equal, :less, :less_equal, :greater, :greater_equal)
    end

    def parse_additive
      parse_left_associative(:parse_multiplicative, :plus, :minus)
    end

    def parse_multiplicative
      parse_left_associative(:parse_unary, :star, :slash, :percent)
    end

    def parse_unary
      if match(:not, :minus, :plus)
        operator = previous.lexeme
        operand = parse_unary
        AST::UnaryOp.new(operator:, operand:)
      else
        parse_postfix
      end
    end

    def parse_postfix
      expression = parse_primary

      loop do
        if match(:dot)
          member = consume(:identifier, "expected member name after '.'").lexeme
          expression = AST::MemberAccess.new(receiver: expression, member:)
        elsif match(:lbracket)
          arguments = []
          unless check(:rbracket)
            loop do
              arguments << AST::TypeArgument.new(value: parse_type_argument)
              break unless match(:comma)
            end
          end
          consume(:rbracket, "expected ']' after specialization arguments")
          expression = AST::Specialization.new(callee: expression, arguments:)
        elsif match(:lparen)
          expression = AST::Call.new(callee: expression, arguments: parse_call_arguments)
        else
          break
        end
      end

      expression
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
      if check(:identifier) && check_next(:equal)
        name = advance.lexeme
        consume(:equal, "expected '=' after named argument name")
        AST::Argument.new(name:, value: parse_expression)
      else
        AST::Argument.new(name: nil, value: parse_expression)
      end
    end

    def parse_primary
      if match(:identifier)
        AST::Identifier.new(name: previous.lexeme)
      elsif match(:integer)
        AST::IntegerLiteral.new(lexeme: previous.lexeme, value: previous.literal)
      elsif match(:float)
        AST::FloatLiteral.new(lexeme: previous.lexeme, value: previous.literal)
      elsif match(:string)
        AST::StringLiteral.new(lexeme: previous.lexeme, value: previous.literal, cstring: false)
      elsif match(:cstring)
        AST::StringLiteral.new(lexeme: previous.lexeme, value: previous.literal, cstring: true)
      elsif match(:true)
        AST::BooleanLiteral.new(value: true)
      elsif match(:false)
        AST::BooleanLiteral.new(value: false)
      elsif match(:null)
        AST::NullLiteral.new
      elsif match(:lparen)
        expression = parse_expression
        consume(:rparen, "expected ')' after expression")
        expression
      else
        raise error(peek, "expected expression")
      end
    end

    def parse_qualified_name
      parts = [consume(:identifier, "expected identifier").lexeme]
      while match(:dot)
        parts << consume(:identifier, "expected identifier after '.'").lexeme
      end
      AST::QualifiedName.new(parts:)
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

    def consume_end_of_statement
      consume(:newline, "expected end of statement")
    end

    def skip_newlines
      advance while check(:newline)
    end

    def match(*types)
      return false unless types.any? { |type| check(type) }

      advance
      true
    end

    def consume(type, message)
      return advance if check(type)

      raise error(peek, message)
    end

    def check(type)
      return false if eof?

      peek.type == type
    end

    def check_next(type)
      return false if (@current + 1) >= @tokens.length

      @tokens[@current + 1].type == type
    end

    def advance
      @current += 1 unless eof?
      previous
    end

    def eof?
      peek.type == :eof
    end

    def peek
      @tokens[@current]
    end

    def previous
      @tokens[@current - 1]
    end

    def error(token, message)
      ParseError.new(message, token:, path: @path)
    end
  end
end
