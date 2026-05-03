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
    BUILTIN_TYPE_NAMES = %w[
      bool byte char i8 i16 i32 i64 u8 u16 u32 u64 isize usize f32 f64 void str cstr
      ptr const_ptr ref span array str_builder Result Task
    ].freeze

    def self.parse(source = nil, path: nil, tokens: nil)
      token_stream = tokens || Lexer.lex(source, path: path)
      new(token_stream, path: path).parse
    end

    def initialize(tokens, path: nil)
      @tokens = tokens.is_a?(SyntaxTokenStream) ? tokens : SyntaxTokenStream.new(tokens)
      @path = path
      @current = 0
      @known_type_names = {}
      @known_import_aliases = {}
      @known_generic_callable_names = {}
      seed_known_names
    end

    def parse
      skip_newlines

      module_name = nil
      module_kind = nil
      imports = []
      directives = []
      declarations = []

      if match(:module)
        module_kind = :module
        module_line = previous.line
        module_name = parse_module_name

        skip_newlines
        while match(:import)
          imports << parse_import
          skip_newlines
        end
      elsif match(:extern)
        module_line = previous.line
        consume(:module, "expected module after extern")
        module_kind = :extern_module
        module_name = parse_qualified_name
        imports, directives, declarations = parse_extern_module_body
        skip_newlines
        raise error(peek, "expected end of file after extern module") unless eof?

        return AST::SourceFile.new(module_name:, module_kind:, imports:, directives:, declarations:, line: module_line)
      end

      until eof?
        declarations << parse_declaration
        skip_newlines
      end

      AST::SourceFile.new(module_name:, module_kind:, imports:, directives:, declarations:, line: module_line)
    end

    private

    def parse_module_name
      name = parse_qualified_name
      consume_end_of_statement
      name
    end

    def parse_import
      line = previous.line
      path = parse_qualified_name
      local_name = path.parts.last
      local_column = previous.column
      alias_name = if match(:as)
                     alias_token = consume_name("expected import alias")
                     local_name = alias_token.lexeme
                     local_column = alias_token.column
                     alias_token.lexeme
                   end
      consume_end_of_statement
      AST::Import.new(path:, alias_name:, line:, column: local_column, length: local_name.length)
    end

    def parse_declaration
      visibility, visibility_token = parse_visibility

      if check(:packed) || check(:align)
        parse_struct_decl_with_layout(visibility:)
      elsif match(:const)
        parse_const_decl(visibility:)
      elsif match(:var)
        parse_var_decl(visibility:)
      elsif match(:type)
        parse_type_alias_decl(visibility:)
      elsif match(:struct)
        parse_struct_decl(visibility:)
      elsif match(:union)
        parse_union_decl(visibility:)
      elsif match(:enum)
        parse_enum_decl(AST::EnumDecl, visibility:)
      elsif match(:flags)
        parse_enum_decl(AST::FlagsDecl, visibility:)
      elsif match(:variant)
        parse_variant_decl(visibility:)
      elsif match(:opaque)
        parse_opaque_decl(visibility:)
      elsif match(:methods)
        raise error(visibility_token, "pub is not allowed on methods blocks") if visibility == :public

        parse_methods_block
      elsif check(:edit) || check(:static)
        raise error(peek, "#{peek.lexeme} def is only allowed inside methods blocks")
      elsif match(:foreign)
        parse_foreign_decl(visibility:)
      elsif match(:async)
        consume(:def, "expected def after async")
        parse_function_def(visibility:, async: true)
      elsif match(:def)
        parse_function_def(visibility:)
      elsif match(:extern)
        raise error(visibility_token, "pub is not allowed on extern declarations yet") if visibility == :public

        parse_extern_decl
      elsif match(:static_assert)
        raise error(visibility_token, "pub is not allowed on static_assert") if visibility == :public

        parse_static_assert
      else
        message = visibility == :public ? "expected exportable declaration after pub" : "expected declaration"
        raise error(peek, message)
      end
    end

    def parse_extern_module_body
      consume(:colon, "expected ':' before extern module body")
      consume(:newline, "expected newline before extern module body")
      consume(:indent, "expected indented extern module body")

      imports = []
      directives = []
      declarations = []
      skip_newlines
      while match(:import)
        imports << parse_import
        skip_newlines
      end

      until check(:dedent) || eof?
        if match(:link)
          directives << parse_link_directive
        elsif match(:include)
          directives << parse_include_directive
        else
          declarations << parse_extern_module_declaration
        end
        skip_newlines
      end

      consume(:dedent, "expected end of extern module body")
      [imports, directives, declarations]
    end

    def parse_link_directive
      value = consume(:string, "expected string literal after link").literal
      consume_end_of_statement
      AST::LinkDirective.new(value:)
    end

    def parse_include_directive
      value = consume(:string, "expected string literal after include").literal
      consume_end_of_statement
      AST::IncludeDirective.new(value:)
    end

    def parse_extern_module_declaration
      if match(:pub)
        raise error(previous, "pub is not allowed inside extern modules")
      elsif check(:packed) || check(:align)
        parse_struct_decl_with_layout(visibility: :public)
      elsif match(:const)
        parse_const_decl(visibility: :public)
      elsif match(:type)
        parse_type_alias_decl(visibility: :public)
      elsif match(:struct)
        parse_struct_decl(visibility: :public)
      elsif match(:union)
        parse_union_decl(visibility: :public)
      elsif match(:enum)
        parse_enum_decl(AST::EnumDecl, visibility: :public)
      elsif match(:flags)
        parse_enum_decl(AST::FlagsDecl, visibility: :public)
      elsif match(:opaque)
        parse_opaque_decl(visibility: :public)
      elsif match(:extern)
        parse_extern_decl
      else
        raise error(peek, "expected extern module declaration")
      end
    end

    def parse_const_decl(visibility: :private)
      line = previous.line
      name = consume_name("expected constant name").lexeme
      consume(:colon, "expected ':' after constant name")
      type = parse_type_ref
      consume(:equal, "expected '=' after constant type")
      value = parse_expression
      consume_end_of_statement
      AST::ConstDecl.new(name:, type:, value:, visibility:, line:)
    end

    def parse_var_decl(visibility: :private)
      line = previous.line
      name = consume_name("expected variable name").lexeme
      var_type = match(:colon) ? parse_type_ref : nil
      value = if match(:equal)
                parse_expression
              else
                raise ParseError, "module variable without initializer requires a type" unless var_type

                nil
              end
      consume_end_of_statement
      AST::VarDecl.new(name:, type: var_type, value:, visibility:, line:)
    end

    def parse_type_alias_decl(visibility: :private)
      line = previous.line
      name = consume_name("expected type alias name").lexeme
      consume(:equal, "expected '=' after type alias name")
      target = parse_type_ref
      consume_end_of_statement
      AST::TypeAliasDecl.new(name:, target:, visibility:, line:)
    end

    def parse_struct_decl(packed: false, alignment: nil, visibility: :private)
      line = previous.line
      name = consume_name("expected struct name").lexeme
      type_params = parse_declaration_type_params
      fields = parse_named_block do
        field_name = consume_name("expected field name").lexeme
        consume(:colon, "expected ':' after field name")
        field_type = parse_type_ref
        consume_end_of_statement
        AST::Field.new(name: field_name, type: field_type)
      end
      AST::StructDecl.new(name:, type_params:, fields:, packed:, alignment:, visibility:, line:)
    end

    def parse_struct_decl_with_layout(visibility: :private)
      packed = false
      alignment = nil

      loop do
        if match(:packed)
          raise error(previous, "duplicate packed modifier") if packed

          packed = true
        elsif match(:align)
          raise error(previous, "duplicate align modifier") if alignment

          consume(:lparen, "expected '(' after align")
          alignment = consume(:integer, "expected integer alignment value").literal
          consume(:rparen, "expected ')' after alignment value")
        else
          break
        end
      end

      consume(:struct, "expected struct after layout modifiers")
      parse_struct_decl(packed:, alignment:, visibility:)
    end

    def parse_union_decl(visibility: :private)
      line = previous.line
      name = consume_name("expected union name").lexeme
      fields = parse_named_block do
        field_name = consume_name("expected field name").lexeme
        consume(:colon, "expected ':' after field name")
        field_type = parse_type_ref
        consume_end_of_statement
        AST::Field.new(name: field_name, type: field_type)
      end
      AST::UnionDecl.new(name:, fields:, visibility:, line:)
    end

    def parse_enum_decl(node_class, visibility: :private)
      line = previous.line
      name = consume_name("expected declaration name").lexeme
      consume(:colon, "expected ':' after declaration name")
      backing_type = parse_type_ref
      consume(:newline, "expected newline before declaration body")
      consume(:indent, "expected indented declaration body")

      members = []
      skip_newlines
      until check(:dedent) || eof?
        member_name = consume_name("expected member name").lexeme
        consume(:equal, "expected '=' after member name")
        value = parse_expression
        consume_end_of_statement
        members << AST::EnumMember.new(name: member_name, value:)
        skip_newlines
      end

      consume(:dedent, "expected end of declaration body")
      node_class.new(name:, backing_type:, members:, visibility:, line:)
    end

    def parse_variant_decl(visibility: :private)
      line = previous.line
      name = consume_name("expected variant name").lexeme
      type_params = parse_declaration_type_params
      arms = parse_named_block do
        arm_name = consume_name("expected variant arm name").lexeme
        fields = if match(:lparen)
                   parsed = []
                   unless check(:rparen)
                     loop do
                       field_name = consume_name("expected field name").lexeme
                       consume(:colon, "expected ':' after field name")
                       field_type = parse_type_ref
                       parsed << AST::Field.new(name: field_name, type: field_type)
                       break unless match(:comma)
                     end
                   end
                   consume(:rparen, "expected ')' after variant arm fields")
                   parsed
                 else
                   []
                 end
        consume_end_of_statement
        AST::VariantArm.new(name: arm_name, fields:)
      end
      AST::VariantDecl.new(name:, type_params:, arms:, visibility:, line:)
    end

    def parse_opaque_decl(visibility: :private)
      line = previous.line
      name = consume_name("expected opaque type name").lexeme
      c_name = nil
      if match(:equal)
        c_name = consume(:cstring, "expected C string literal after '='").literal
      end
      consume_end_of_statement
      AST::OpaqueDecl.new(name:, c_name:, visibility:, line:)
    end

    def parse_methods_block
      line = previous.line
      type_name = parse_qualified_name
      methods = parse_named_block do
        parse_method_def
      end
      AST::MethodsBlock.new(type_name:, methods:, line:)
    end

    def parse_function_def(visibility: :private, async: false)
      line = previous.line
      name_token = consume_name("expected function name")
      name = name_token.lexeme
      type_params = parse_declaration_type_params
      params = parse_params
      return_type = match(:arrow) ? parse_type_ref : nil
      body = parse_block
      AST::FunctionDef.new(name:, type_params:, params:, return_type:, body:, visibility:, async:, line:, column: name_token.column)
    end

    def parse_method_def
      visibility, _visibility_token = parse_visibility
      async = match(:async)

      kind = if match(:edit)
               :edit
             elsif match(:static)
               :static
             else
               :plain
             end
      consume(:def, "expected method declaration")
      line = previous.line

      name_token = consume_name("expected function name")
      name = name_token.lexeme
      type_params = parse_declaration_type_params
      params = parse_params
      return_type = match(:arrow) ? parse_type_ref : nil
      body = parse_block
      AST::MethodDef.new(name:, type_params:, params:, return_type:, body:, kind:, visibility:, async:, line:, column: name_token.column)
    end

    def parse_visibility
      return [:public, previous] if match(:pub)

      [:private, nil]
    end

    def parse_extern_decl
      consume(:def, "expected def after extern")
      parse_extern_function_decl
    end

    def parse_foreign_decl(visibility: :private)
      consume(:def, "expected def after foreign")
      parse_foreign_function_decl(visibility:)
    end

    def parse_extern_function_decl
      line = previous.line
      name = consume_name("expected function name").lexeme
      type_params = parse_declaration_type_params
      params, variadic = parse_params(allow_variadic: true)
      consume(:arrow, "expected '->' before extern function return type")
      return_type = parse_type_ref
      consume_end_of_statement
      AST::ExternFunctionDecl.new(name:, type_params:, params:, return_type:, variadic:, line:)
    end

    def parse_foreign_function_decl(visibility: :private)
      line = previous.line
      name = consume_name("expected function name").lexeme
      type_params = parse_declaration_type_params
      params = parse_foreign_params
      consume(:arrow, "expected '->' before foreign function return type")
      return_type = parse_type_ref
      consume(:equal, "expected '=' before foreign function mapping")
      mapping = parse_expression
      consume_end_of_statement
      AST::ForeignFunctionDecl.new(name:, type_params:, params:, return_type:, mapping:, visibility:, line:)
    end

    def parse_params(allow_variadic: false)
      consume(:lparen, "expected '('")
      params = []
      variadic = false

      unless check(:rparen)
        loop do
          if allow_variadic && match(:ellipsis)
            variadic = true
            break
          end

          params << parse_param
          break unless match(:comma)
        end
      end

      consume(:rparen, "expected ')' after parameters")
      return [params, variadic] if allow_variadic

      params
    end

    def parse_foreign_params
      consume(:lparen, "expected '('")
      params = []

      unless check(:rparen)
        loop do
          params << parse_foreign_param
          break unless match(:comma)
        end
      end

      consume(:rparen, "expected ')' after parameters")
      params
    end

    def parse_param
      name_token = consume_name("expected parameter name")
      raise error(name_token, "expected ':' and parameter type") unless match(:colon)

      param_type = parse_type_ref

      AST::Param.new(name: name_token.lexeme, type: param_type, line: name_token.line, column: name_token.column)
    end

    def parse_foreign_param
      mode = if match(:out)
               :out
             elsif match(:in)
               :in
             elsif match(:consuming)
               :consuming
             elsif match(:inout)
               :inout
             else
               :plain
             end
      name_token = consume_name("expected parameter name")
      raise error(name_token, "expected ':' and parameter type") unless match(:colon)

      param_type = parse_type_ref
      boundary_type = match(:as) ? parse_type_ref : nil

      AST::ForeignParam.new(name: name_token.lexeme, type: param_type, mode:, boundary_type:)
    end

    def parse_type_ref
      return parse_function_type_ref if match(:fn)
      return parse_proc_type_ref if match(:proc)

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

    def parse_function_type_ref
      consume(:lparen, "expected '(' after fn")
      params = []

      unless check(:rparen)
        loop do
          params << parse_function_type_param
          break unless match(:comma)
        end
      end

      consume(:rparen, "expected ')' after function type parameters")
      consume(:arrow, "expected '->' after function type parameters")
      return_type = parse_type_ref
      AST::FunctionType.new(params:, return_type:)
    end

    def parse_proc_type_ref
      consume(:lparen, "expected '(' after proc")
      params = []

      unless check(:rparen)
        loop do
          params << parse_function_type_param
          break unless match(:comma)
        end
      end

      consume(:rparen, "expected ')' after proc type parameters")
      consume(:arrow, "expected '->' after proc type parameters")
      return_type = parse_type_ref
      AST::ProcType.new(params:, return_type:)
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

      params = []
      unless check(:rbracket)
        loop do
          params << AST::TypeParam.new(name: consume_name("expected type parameter name").lexeme)
          break unless match(:comma)
        end
      end

      consume(:rbracket, "expected ']' after type parameters")
      params
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
      elsif match(:match)
        parse_match_stmt
      elsif match(:unsafe)
        parse_unsafe_stmt
      elsif match(:static_assert)
        parse_static_assert
      elsif match(:for)
        parse_for_stmt
      elsif match(:while)
        parse_while_stmt
      elsif match(:break)
        parse_break_stmt
      elsif match(:continue)
        parse_continue_stmt
      elsif match(:return)
        parse_return_stmt
      elsif match(:defer)
        parse_defer_stmt
      else
        parse_assignment_or_expression_stmt
      end
    end

    def parse_local_decl(kind)
      line = previous.line
      name_token = consume_name("expected local variable name")
      name = name_token.lexeme
      var_type = match(:colon) ? parse_type_ref : nil
      value = if match(:equal)
                parse_expression
              else
                raise ParseError, "local declaration without initializer requires a type" unless var_type

                nil
              end
      consume_end_of_statement unless block_expression?(value)
                  AST::LocalDecl.new(kind:, name:, type: var_type, value:, line:, column: name_token.column)
    end

    def parse_if_stmt
      line = previous.line
      branches = []
      branch_token = previous
      branches << AST::IfBranch.new(
        condition: parse_expression,
        body: parse_block,
        line: branch_token.line,
        column: branch_token.column,
        length: branch_token.lexeme.length,
      )

      while match(:elif)
        branch_token = previous
        branches << AST::IfBranch.new(
          condition: parse_expression,
          body: parse_block,
          line: branch_token.line,
          column: branch_token.column,
          length: branch_token.lexeme.length,
        )
      end

      else_line = nil
      else_column = nil
      else_body = if match(:else)
                    else_line = previous.line
                    else_column = previous.column
                    parse_block
                  end
      AST::IfStmt.new(branches:, else_body:, line:, else_line:, else_column:)
    end

    def parse_match_stmt
      line = previous.line
      expression = parse_expression
      arms = parse_named_block do
        pattern = parse_expression
        binding_token = nil
        binding_name = if match(:as)
                         binding_token = consume_name("expected binding name after 'as'")
                         binding_token.lexeme
                       end
        body = parse_block
        AST::MatchArm.new(
          pattern:,
          binding_name:,
          binding_line: binding_token&.line,
          binding_column: binding_token&.column,
          body:,
        )
      end
      AST::MatchStmt.new(expression:, arms:, line:)
    end

    def parse_unsafe_stmt
      AST::UnsafeStmt.new(body: parse_block, line: previous.line)
    end

    def parse_static_assert
      line = previous.line
      consume(:lparen, "expected '(' after static_assert")
      condition = parse_expression
      consume(:comma, "expected ',' after static_assert condition")
      message = parse_expression
      consume(:rparen, "expected ')' after static_assert message")
      consume_end_of_statement
      AST::StaticAssert.new(condition:, message:, line:)
    end

    def parse_for_stmt
      line = previous.line
      name_token = consume_name("expected loop variable name")
      name = name_token.lexeme
      consume(:in, "expected 'in' in for loop")
      iterable = parse_expression
      body = parse_block
      AST::ForStmt.new(name:, iterable:, body:, line:, column: name_token.column)
    end

    def parse_while_stmt
      line = previous.line
      condition = parse_expression
      body = parse_block
      AST::WhileStmt.new(condition:, body:, line:)
    end

    def parse_break_stmt
      line = previous.line
      consume_end_of_statement
      AST::BreakStmt.new(line:)
    end

    def parse_continue_stmt
      line = previous.line
      consume_end_of_statement
      AST::ContinueStmt.new(line:)
    end

    def parse_return_stmt
      line = previous.line
      value = check(:newline) ? nil : parse_expression
      consume_end_of_statement unless block_expression?(value)
      AST::ReturnStmt.new(value:, line:)
    end

    def parse_defer_stmt
      line = previous.line
      if check(:colon)
        body = parse_block
        AST::DeferStmt.new(expression: nil, body:, line:)
      else
        expression = parse_expression
        consume_end_of_statement unless block_expression?(expression)
        AST::DeferStmt.new(expression:, body: nil, line:)
      end
    end

    def parse_assignment_or_expression_stmt
      line = peek.line
      expression = parse_expression
      if match(*Token::ASSIGNMENT_TYPES)
        operator = previous.lexeme
        value = parse_expression
        consume_end_of_statement unless block_expression?(value)
        AST::Assignment.new(target: expression, operator:, value:, line:)
      else
        consume_end_of_statement unless block_expression?(expression)
        AST::ExpressionStmt.new(expression:, line:)
      end
    end

    def parse_expression
      return parse_if_expression if match(:if)

      parse_or
    end

    def parse_if_expression
      condition = parse_or
      consume(:then, "expected 'then' in if expression")
      then_expression = parse_expression
      consume(:else, "expected 'else' in if expression")
      else_expression = parse_expression
      AST::IfExpr.new(condition:, then_expression:, else_expression:)
    end

    def parse_or
      parse_left_associative(:parse_and, :or)
    end

    def parse_and
      parse_left_associative(:parse_bitwise_or, :and)
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
      elsif match(:await)
        AST::AwaitExpr.new(expression: parse_unary)
      elsif match(:not, :minus, :plus, :tilde, :out, :in, :inout)
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
      AST::Call.new(
        callee: AST::Specialization.new(
          callee: AST::Identifier.new(name: "cast"),
          arguments: [AST::TypeArgument.new(value: target_type)],
        ),
        arguments: [AST::Argument.new(name: nil, value: expression)],
      )
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
          member = consume_name("expected member name after '.'").lexeme
          expression = AST::MemberAccess.new(receiver: expression, member:)
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
      arguments = []
      unless check(:rbracket)
        loop do
          arguments << AST::TypeArgument.new(value: parse_type_argument)
          break unless match(:comma)
        end
      end
      consume(:rbracket, "expected ']' after specialization arguments")

      if removed_cast_call_form?(expression)
        raise error(previous, "cast[T](value) is no longer supported; use T<-value")
      end

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
      if match(:sizeof)
        parse_sizeof_expr
      elsif match(:alignof)
        parse_alignof_expr
      elsif match(:offsetof)
        parse_offsetof_expr
      elsif match(:proc)
        parse_proc_expr
      elsif match_name
        AST::Identifier.new(name: previous.lexeme, line: previous.line, column: previous.column)
      elsif match(:integer)
        AST::IntegerLiteral.new(lexeme: previous.lexeme, value: previous.literal)
      elsif match(:float)
        AST::FloatLiteral.new(lexeme: previous.lexeme, value: previous.literal)
      elsif match(:string)
        AST::StringLiteral.new(lexeme: previous.lexeme, value: previous.literal, cstring: false)
      elsif match(:cstring)
        AST::StringLiteral.new(lexeme: previous.lexeme, value: previous.literal, cstring: true)
      elsif match(:fstring)
        parse_format_string_literal(previous.literal)
      elsif match(:true)
        AST::BooleanLiteral.new(value: true)
      elsif match(:false)
        AST::BooleanLiteral.new(value: false)
      elsif match(:null)
        type = nil
        if match(:lbracket)
          type = parse_type_ref
          consume(:rbracket, "expected ']' after typed null literal")
        end
        AST::NullLiteral.new(type:)
      elsif match(:lparen)
        expression = parse_expression
        consume(:rparen, "expected ')' after expression")
        expression
      else
        raise error(peek, "expected expression")
      end
    end

    def parse_proc_expr
      consume(:lparen, "expected '(' after proc")
      params = []

      unless check(:rparen)
        loop do
          params << parse_function_type_param
          break unless match(:comma)
        end
      end

      consume(:rparen, "expected ')' after proc parameters")
      consume(:arrow, "expected '->' after proc parameters")
      return_type = parse_type_ref
      body = parse_block
      AST::ProcExpr.new(params:, return_type:, body:)
    end

    def block_expression?(expression)
      expression.is_a?(AST::ProcExpr)
    end

    def parse_sizeof_expr
      consume(:lparen, "expected '(' after sizeof")
      type = parse_type_ref
      consume(:rparen, "expected ')' after sizeof type")
      AST::SizeofExpr.new(type:)
    end

    def parse_alignof_expr
      consume(:lparen, "expected '(' after alignof")
      type = parse_type_ref
      consume(:rparen, "expected ')' after alignof type")
      AST::AlignofExpr.new(type:)
    end

    def parse_offsetof_expr
      consume(:lparen, "expected '(' after offsetof")
      type = parse_type_ref
      consume(:comma, "expected ',' after offsetof type")
      field = consume_name("expected field name in offsetof").lexeme
      consume(:rparen, "expected ')' after offsetof field")
      AST::OffsetofExpr.new(type:, field:)
    end

    def parse_qualified_name
      parts = [consume_name("expected identifier").lexeme]
      while match(:dot)
        parts << consume_name("expected identifier after '.'").lexeme
      end
      AST::QualifiedName.new(parts:)
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

      if (m = spec_str.strip.match(/\A\.(\d+)\z/))
        { kind: :precision, value: m[1].to_i }
      else
        raise error(peek, "unsupported format spec '#{spec_str.strip}': expected .N for float precision (e.g. :.2)")
      end
    end

    def parse_embedded_expression(source, line:, column:)
      tokens = Lexer.lex(source, path: @path).map do |token|
        Token.new(
          type: token.type,
          lexeme: token.lexeme,
          literal: token.literal,
          line: token.line + line - 1,
          column: token.column + column - 1,
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

    def consume_name(message)
      return advance if check_name

      raise error(peek, message)
    end

    def check(type)
      return false if eof?

      peek.type == type
    end

    def check_name
      return false if eof?

      type = peek.type
      type == :identifier || (Token::KEYWORDS.value?(type) && !%i[true false null].include?(type))
    end

    def check_next(type)
      return false if (@current + 1) >= @tokens.length

      @tokens[@current + 1].type == type
    end

    def postfix_bracket_starts_specialization?(expression)
      specialization_target?(expression) && matching_rbracket_index(@current)
    end

    def specialization_target?(expression)
      builtin_specialization_target?(expression) || aggregate_specialization_target?(expression)
    end

    def builtin_specialization_target?(expression)
      expression.is_a?(AST::Identifier) && %w[array reinterpret span zero].include?(expression.name)
    end

    def removed_cast_call_form?(expression)
      expression.is_a?(AST::Identifier) && expression.name == "cast"
    end

    def parse_diagnostic_hint?(error)
      error.message.include?("did you mean T<-expr?") || error.message.include?("cast[T](value) is no longer supported")
    end

    def aggregate_specialization_target?(expression)
      case expression
      when AST::Identifier
        true
      when AST::MemberAccess
        expression.receiver.is_a?(AST::Identifier)
      else
        false
      end
    end

    def specialization_call_target?(expression, arguments, call_arguments)
      return true if builtin_specialization_target?(expression)
      return true if aggregate_specialization_target?(expression) && call_arguments.all?(&:name)
      return true if generic_callable_specialization_target?(expression) && arguments.all? { |argument| explicit_specialization_argument?(argument.value) }
      return true if imported_member_specialization_target?(expression) && arguments.all? { |argument| explicit_specialization_argument?(argument.value) }

      aggregate_specialization_target?(expression) && arguments.all? { |argument| definite_type_argument?(argument.value) }
    end

    def specialization_value_target?(expression, arguments)
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

    def known_type_like_name?(name)
      @known_type_names.key?(name) || @known_import_aliases.key?(name)
    end

    def seed_known_names
      BUILTIN_TYPE_NAMES.each { |name| @known_type_names[name] = true }

      depth = 0
      index = 0
      while index < @tokens.length
        token = @tokens[index]
        case token.type
        when :indent
          depth += 1
        when :dedent
          depth -= 1 if depth.positive?
        when :import
          index = seed_import_alias(index + 1) if depth.zero?
        when :def
          if depth.zero?
            name_token = @tokens[index + 1]
            type_param_token = @tokens[index + 2]
            if type_name_token?(name_token) && type_param_token&.type == :lbracket
              @known_generic_callable_names[name_token.lexeme] = true
            end
          end
        when :async
          if depth.zero? && @tokens[index + 1]&.type == :def
            name_token = @tokens[index + 2]
            type_param_token = @tokens[index + 3]
            if type_name_token?(name_token) && type_param_token&.type == :lbracket
              @known_generic_callable_names[name_token.lexeme] = true
            end
          end
        when :foreign
          if depth.zero? && @tokens[index + 1]&.type == :def
            name_token = @tokens[index + 2]
            type_param_token = @tokens[index + 3]
            if type_name_token?(name_token) && type_param_token&.type == :lbracket
              @known_generic_callable_names[name_token.lexeme] = true
            end
          end
        when :struct, :union, :enum, :flags, :opaque, :type, :variant
          if depth.zero?
            name_token = @tokens[index + 1]
            @known_type_names[name_token.lexeme] = true if type_name_token?(name_token)
          end
        end

        index += 1
      end
    end

    def seed_import_alias(start_index)
      cursor = start_index
      last_part = nil

      while cursor < @tokens.length && @tokens[cursor].type != :newline
        token = @tokens[cursor]
        if token.type == :as
          alias_token = @tokens[cursor + 1]
          @known_import_aliases[alias_token.lexeme] = true if type_name_token?(alias_token)
          return cursor
        end

        last_part = token.lexeme if type_name_token?(token)
        cursor += 1
      end

      @known_import_aliases[last_part] = true if last_part
      cursor
    end

    def type_name_token?(token)
      return false unless token

      token.type == :identifier || (Token::KEYWORDS.value?(token.type) && !%i[true false null].include?(token.type))
    end

    def matching_rbracket_index(start_index)
      depth = 0
      index = start_index

      while index < @tokens.length
        case @tokens[index].type
        when :lbracket
          depth += 1
        when :rbracket
          depth -= 1
          return index if depth.zero?
        end
        index += 1
      end

      nil
    end

    def match_name
      return false unless check_name

      advance
      true
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
