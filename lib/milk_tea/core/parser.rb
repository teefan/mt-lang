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
    ParseRecoveryResult = Data.define(:ast, :errors) do
      def initialize(ast:, errors: []) = super
    end

    BUILTIN_TYPE_NAMES = Types::BUILTIN_TYPE_NAMES

    def self.parse(source = nil, path: nil, tokens: nil)
      token_stream = tokens || Lexer.lex(source, path: path)
      new(token_stream, path: path).parse
    end

    def self.parse_collecting_errors(source = nil, path: nil, tokens: nil)
      if tokens
        return new(tokens, path: path).parse_collecting_errors
      end

      lex_errors = []
      token_stream = Lexer.lex(source, path: path, recovery_errors: lex_errors)
      parse_result = new(token_stream, path: path).parse_collecting_errors
      ParseRecoveryResult.new(ast: parse_result.ast, errors: lex_errors + parse_result.errors)
    end

    def initialize(tokens, path: nil)
      @tokens = tokens.is_a?(SyntaxTokenStream) ? tokens : SyntaxTokenStream.new(tokens)
      @path = path
      @current = 0
      @known_type_names = {}
      @known_import_aliases = {}
      @known_generic_callable_names = {}
      @current_type_param_names = []
      seed_known_names
    end

    def parse
      parse_source_file
    end

    def parse_collecting_errors
      errors = []
      previous_recovery_errors = @recovery_errors
      @recovery_errors = errors
      ast = parse_source_file(errors:)
      ParseRecoveryResult.new(ast:, errors:)
    rescue ParseError => e
      errors ||= []
      errors << e
      ParseRecoveryResult.new(ast: nil, errors:)
    ensure
      @recovery_errors = previous_recovery_errors
    end

    private

    TOP_LEVEL_RECOVERY_START_TYPES = %i[
      module import at public attribute const var type struct union enum flags variant interface
      opaque extending foreign async function event external static_assert link include compiler_flag
    ].freeze

    BUILTIN_ATTRIBUTE_NAME_LEXEMES = %w[packed align].freeze

    def parse_source_file(errors: nil)
      skip_newlines

      module_name = nil
      module_kind = :module
      module_line = nil
      imports = []
      directives = []
      declarations = []

      if external_file_header?
        advance
        module_line = previous.line
        module_kind = :raw_module
        consume(:newline, "expected newline after external") unless eof?
        skip_newlines
        imports, directives, declarations = parse_raw_module_body(errors:)
        skip_newlines
        raise error(peek, "expected end of file after external declarations") unless eof?

        return AST::SourceFile.new(module_name:, module_kind:, imports:, directives:, declarations:, line: module_line)
      end

      while match(:import)
        if errors
          begin
            imports << parse_import
          rescue ParseError => e
            errors << e
            synchronize_to_top_level_boundary
          end
        else
          imports << parse_import
        end
        skip_newlines
      end

      until eof?
        if errors
          begin
            declarations << parse_declaration
          rescue ParseError => e
            errors << e
            synchronize_to_top_level_boundary
          end
        else
          declarations << parse_declaration
        end
        skip_newlines
      end

      AST::SourceFile.new(module_name:, module_kind:, imports:, directives:, declarations:, line: module_line)
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
      attributes = parse_attribute_applications
      visibility, visibility_token = parse_visibility

      if legacy_layout_modifier_start?(peek)
        raise error(peek, "layout modifiers must use attributes like @[packed] or @[align(...)]")
      elsif match(:attribute)
        reject_attributes!(attributes)
        parse_attribute_decl(visibility:)
      elsif match(:const)
        reject_attributes!(attributes)
        if match(:function)
          parse_function_def(visibility:, const: true, attributes:)
        else
          parse_const_decl(visibility:)
        end
      elsif match(:var)
        reject_attributes!(attributes)
        parse_var_decl(visibility:)
      elsif match(:event)
        reject_attributes!(attributes)
        parse_event_decl(visibility:)
      elsif match(:type)
        reject_attributes!(attributes)
        parse_type_alias_decl(visibility:)
      elsif match(:struct)
        parse_struct_decl(visibility:, attributes:)
      elsif match(:union)
        reject_attributes!(attributes)
        parse_union_decl(visibility:)
      elsif match(:enum)
        reject_attributes!(attributes)
        parse_enum_decl(AST::EnumDecl, visibility:)
      elsif match(:flags)
        reject_attributes!(attributes)
        parse_enum_decl(AST::FlagsDecl, visibility:)
      elsif match(:variant)
        reject_attributes!(attributes)
        parse_variant_decl(visibility:)
      elsif match(:interface)
        reject_attributes!(attributes)
        parse_interface_decl(visibility:)
      elsif match(:opaque)
        reject_attributes!(attributes)
        parse_opaque_decl(visibility:)
      elsif match(:extending)
        reject_attributes!(attributes)
        raise error(visibility_token, "public is not allowed on extending blocks") if visibility == :public

        parse_extending_block
      elsif check(:editable) || check(:static)
        reject_attributes!(attributes)
        raise error(peek, "#{peek.lexeme} function is only allowed inside extending blocks")
      elsif match(:foreign)
        parse_foreign_decl(visibility:, attributes:)
      elsif match(:async)
        consume(:function, "expected function after async")
        parse_function_def(visibility:, async: true, attributes:)
      elsif match(:function)
        parse_function_def(visibility:, attributes:)
      elsif match(:external)
        raise error(visibility_token, "public is not allowed on external declarations") if visibility == :public

        parse_extern_decl(attributes:)
      elsif match(:static_assert)
        reject_attributes!(attributes)
        raise error(visibility_token, "public is not allowed on static_assert") if visibility == :public

        parse_static_assert
      elsif check_when_start?
        reject_attributes!(attributes)
        raise error(visibility_token, "public is not allowed on when") if visibility == :public

        advance
        parse_when_stmt
      else
        message = visibility == :public ? "expected exportable declaration after public" : "expected declaration"
        raise error(peek, message)
      end
    end

    def parse_raw_module_body(errors: nil)
      imports = []
      directives = []
      declarations = []

      while match(:import)
        if errors
          begin
            imports << parse_import
          rescue ParseError => e
            errors << e
            synchronize_to_top_level_boundary
          end
        else
          imports << parse_import
        end
        skip_newlines
      end

      while raw_module_directive_start?
        if errors
          begin
            directives << parse_raw_module_directive
          rescue ParseError => e
            errors << e
            synchronize_to_top_level_boundary
          end
        else
          directives << parse_raw_module_directive
        end
        skip_newlines
      end

      until eof?
        if errors
          begin
            declarations << parse_raw_module_declaration
          rescue ParseError => e
            errors << e
            synchronize_to_top_level_boundary
          end
        else
          declarations << parse_raw_module_declaration
        end
        skip_newlines
      end

      [imports, directives, declarations]
    end

    def raw_module_directive_start?
      check(:link) || check(:include) || check(:compiler_flag)
    end

    def parse_raw_module_directive
      if match(:link)
        parse_link_directive
      elsif match(:include)
        parse_include_directive
      elsif match(:compiler_flag)
        parse_compiler_flag_directive
      else
        raise error(peek, "expected external directive")
      end
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

    def parse_compiler_flag_directive
      value = consume(:string, "expected string literal after compiler_flag").literal
      consume_end_of_statement
      AST::CompilerFlagDirective.new(value:)
    end

    def parse_raw_module_declaration
      attributes = parse_attribute_applications

      if match(:public)
        reject_attributes!(attributes)
        raise error(previous, "public is not allowed in external files")
      elsif legacy_layout_modifier_start?(peek)
        raise error(peek, "layout modifiers must use attributes like @[packed] or @[align(...)]")
      elsif match(:attribute)
        reject_attributes!(attributes)
        raise error(previous, "attribute is not allowed in external files")
      elsif match(:const)
        reject_attributes!(attributes)
        if match(:function)
          parse_function_def(visibility:, const: true, attributes:)
        else
          parse_const_decl(visibility: nil)
        end
      elsif match(:event)
        reject_attributes!(attributes)
        raise error(previous, "event is not allowed in external files")
      elsif match(:type)
        reject_attributes!(attributes)
        parse_type_alias_decl(visibility: nil)
      elsif match(:struct)
        parse_struct_decl(visibility: nil, attributes:)
      elsif match(:union)
        reject_attributes!(attributes)
        parse_union_decl(visibility: nil)
      elsif match(:enum)
        reject_attributes!(attributes)
        parse_enum_decl(AST::EnumDecl, visibility: nil)
      elsif match(:flags)
        reject_attributes!(attributes)
        parse_enum_decl(AST::FlagsDecl, visibility: nil)
      elsif match(:opaque)
        reject_attributes!(attributes)
        parse_opaque_decl(visibility: nil)
      elsif match(:external)
        reject_attributes!(attributes)
        parse_extern_decl(attributes:)
      elsif check_when_start?
        reject_attributes!(attributes)
        advance
        parse_when_stmt
      else
        raise error(peek, raw_module_declaration_error_message(peek))
      end
    end

    def raw_module_declaration_error_message(token)
      case token.type
      when :import
        "imports must appear before external directives and declarations"
      when :link, :include, :compiler_flag
        "#{token.lexeme} directives must appear before external declarations"
      when :attribute, :event, :var, :variant, :interface, :extending, :foreign, :function, :static_assert
        "#{token.lexeme} is not allowed in external files"
      when :async
        "async function is not allowed in external files"
      when :module
        "module headers are not allowed in external files"
      else
        "expected external declaration"
      end
    end

    def parse_const_decl(visibility: :private)
      line = previous.line
      name = nil
      type = nil
      name = consume_name("expected constant name").lexeme
      if match(:arrow)
        type = parse_type_ref
        body = parse_block
        return AST::ConstDecl.new(name:, type:, value: nil, block_body: body, visibility:, line:)
      end

      consume(:colon, "expected ':' after constant name")
      type = parse_type_ref
      consume(:equal, "expected '=' after constant type")
      value = parse_expression
      consume_end_of_statement
      AST::ConstDecl.new(name:, type:, value:, visibility:, line:)
    rescue ParseError => e
      raise unless @recovery_errors && name

      @recovery_errors << e
      synchronize_to_statement_boundary
      AST::ConstDecl.new(name:, type: type || recovery_error_expr(e), value: recovery_error_expr(e), visibility:, line:)
    end

    def parse_var_decl(visibility: :private)
      line = previous.line
      name = nil
      var_type = nil
      name_token = consume_name("expected variable name")
      name = name_token.lexeme
      var_type = match(:colon) ? parse_type_ref : nil
      value = if match(:equal)
                parse_expression
              else
                raise error(name_token, "module variable without initializer requires a type") unless var_type

                nil
              end
      consume_end_of_statement
      AST::VarDecl.new(name:, type: var_type, value:, visibility:, line:)
    rescue ParseError => e
      raise unless @recovery_errors && name

      @recovery_errors << e
      synchronize_to_statement_boundary
      AST::VarDecl.new(name:, type: var_type || recovery_error_expr(e), value: recovery_error_expr(e), visibility:, line:)
    end

    def parse_event_decl(visibility: :private)
      line = previous.line
      name_token = consume_name("expected event name")
      consume(:lbracket, "expected '[' after event name")
      capacity = consume(:integer, "expected positive integer capacity").literal
      consume(:rbracket, "expected ']' after event capacity")
      payload_type = nil
      if match(:lparen)
        payload_type = parse_type_ref
        consume(:rparen, "expected ')' after event payload type")
      end
      consume_end_of_statement
      AST::EventDecl.new(name: name_token.lexeme, capacity:, payload_type:, visibility:, line:, column: name_token.column)
    end

    def parse_type_alias_decl(visibility: :private)
      line = previous.line
      name = consume_name("expected type alias name").lexeme
      consume(:equal, "expected '=' after type alias name")
      target = parse_type_ref
      consume_end_of_statement
      AST::TypeAliasDecl.new(name:, target:, visibility:, line:)
    end

    def parse_attribute_decl(visibility: :private)
      line = previous.line
      consume(:lbracket, "expected '[' after attribute")
      targets = parse_comma_separated_until(:rbracket) do
        target_token = consume_path_component("expected attribute target")
        case target_token.lexeme
        when "struct"
          :struct
        when "field"
          :field
        when "callable"
          :callable
        else
          raise error(target_token, "unknown attribute target #{target_token.lexeme}")
        end
      end
      consume(:rbracket, "expected ']' after attribute targets")
      name_token = consume_name_allowing_keywords("expected attribute name")
      params = check(:lparen) ? parse_signature_params : []
      consume_end_of_statement
      AST::AttributeDecl.new(name: name_token.lexeme, targets:, params:, visibility:, line:, column: name_token.column)
    end

    def parse_struct_decl(packed: false, alignment: nil, visibility: :private, attributes: [])
      line = previous.line
      name = consume_name("expected struct name").lexeme
      lifetime_params, type_params = parse_struct_decl_params
      implements = parse_implements_clause
      c_name = parse_optional_explicit_c_name
      packed, alignment = parse_struct_layout_attributes(attributes) if attributes.any?
      members = parse_named_block do
        parse_struct_member
      end
      fields = members.filter_map { |kind, member| member if kind == :field }
      events = members.filter_map { |kind, member| member if kind == :event }
      AST::StructDecl.new(name:, type_params:, implements:, c_name:, fields:, events:, attributes:, packed:, alignment:, visibility:, lifetime_params:, line:)
    end

    def parse_struct_decl_params
      return [[], []] unless match(:lbracket)

      lifetime_params = []
      type_params = []

      loop do
        break if check(:rbracket)

        if match(:at)
          name_token = consume_name("expected lifetime name after @")
          lifetime_params << "@#{name_token.lexeme}"
        else
          name_token = consume_name("expected type parameter name")
          if match(:colon)
            value_type = parse_type_ref
            type_params << AST::ValueTypeParam.new(
              name: name_token.lexeme,
              type: value_type,
              line: name_token.line,
              column: name_token.column,
              length: name_token.lexeme.length,
            )
          else
            constraints = parse_type_param_constraints
            type_params << AST::TypeParam.new(
              name: name_token.lexeme,
              constraints:,
              line: name_token.line,
              column: name_token.column,
              length: name_token.lexeme.length,
            )
          end
        end

        break unless match(:comma)
        next if check(:rbracket)
      end

      consume(:rbracket, "expected ']' after struct parameters")
      [lifetime_params, type_params]
    end

    def parse_struct_member
      field_attributes = parse_attribute_applications
      visibility, visibility_token = parse_visibility

      if match(:event)
        reject_attributes!(field_attributes)
        return [:event, parse_event_decl(visibility:)]
      end

      raise error(visibility_token, "public is only allowed on struct events") if visibility == :public

      field_token = consume_name("expected field name")
      field_name = field_token.lexeme
      consume(:colon, "expected ':' after field name")
      field_type = parse_type_ref
      consume_end_of_statement
      [:field, AST::Field.new(name: field_name, type: field_type, attributes: field_attributes, line: field_token.line, column: field_token.column)]
    rescue ParseError => e
      raise unless @recovery_errors

      @recovery_errors << e
      synchronize_to_statement_boundary
      field_name_error = (field_name if defined?(field_name)) || "error"
      [:field, AST::Field.new(name: field_name_error, type: recovery_error_expr(e), attributes: field_attributes, line: e.token&.line || 1, column: e.token&.column || 1)]
    end

    def parse_union_decl(visibility: :private)
      line = previous.line
      name = consume_name("expected union name").lexeme
      c_name = parse_optional_explicit_c_name
      fields = parse_named_block do
        field_name = consume_name("expected field name").lexeme
        consume(:colon, "expected ':' after field name")
        field_type = parse_type_ref
        consume_end_of_statement
        AST::Field.new(name: field_name, type: field_type)
      end
      AST::UnionDecl.new(name:, c_name:, fields:, visibility:, line:)
    end

    def parse_optional_explicit_c_name
      return nil unless match(:equal)

      consume(:cstring, "expected C string literal after '='").literal
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
                   parsed = parse_comma_separated_until(:rparen) do
                     field_name = consume_name("expected field name").lexeme
                     consume(:colon, "expected ':' after field name")
                     field_type = parse_type_ref
                     AST::Field.new(name: field_name, type: field_type)
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
      implements = parse_implements_clause
      c_name = nil
      if match(:equal)
        c_name = consume(:cstring, "expected C string literal after '='").literal
      end
      consume_end_of_statement
      AST::OpaqueDecl.new(name:, implements:, c_name:, visibility:, line:)
    end

    def parse_interface_decl(visibility: :private)
      line = previous.line
      name = consume_name("expected interface name").lexeme
      type_params = parse_declaration_type_params
      methods = parse_named_block do
        method_attributes = parse_attribute_applications
        parse_interface_method_decl(attributes: method_attributes)
      end
      AST::InterfaceDecl.new(name:, type_params:, methods:, visibility:, line:)
    end

    def parse_extending_block
      line = previous.line
      type_name = parse_type_ref
      receiver_type_param_names = extending_target_type_param_names(type_name)
      methods = with_type_param_names(receiver_type_param_names) do
        parse_named_block do
          method_attributes = parse_attribute_applications
          parse_method_def(attributes: method_attributes)
        end
      end
      AST::ExtendingBlock.new(type_name:, methods:, line:)
    end

    def extending_target_type_param_names(type_name)
      type_name.arguments.flat_map do |argument|
        extending_target_type_param_names_from_argument(argument.value)
      end.uniq
    end

    def extending_target_type_param_names_from_argument(value)
      case value
      when AST::TypeRef
        nested_names = value.arguments.flat_map do |argument|
          extending_target_type_param_names_from_argument(argument.value)
        end
        if value.name.parts.length == 1 && value.arguments.empty? && !value.nullable
          name = value.name.parts.first
          nested_names << name unless known_type_like_name?(name)
        end
        nested_names
      when AST::FunctionType, AST::ProcType
        value.params.flat_map { |param| extending_target_type_param_names_from_argument(param.type) } +
          extending_target_type_param_names_from_argument(value.return_type)
      else
        []
      end
    end

    def parse_function_def(visibility: :private, async: false, const: false, attributes: [])
      line = previous.line
      name_token = consume_name("expected function name")
      name = name_token.lexeme
      type_params, params, return_type, body = parse_callable_signature
      AST::FunctionDef.new(name:, type_params:, params:, return_type:, body:, visibility:, async:, const:, attributes:, line:, column: name_token.column)
    end

    def parse_method_def(attributes: [])
      visibility, _visibility_token, async, kind, line, name_token = parse_method_like_decl_head
      name = name_token.lexeme
      type_params, params, return_type, body = parse_callable_signature
      AST::MethodDef.new(name:, type_params:, params:, return_type:, body:, kind:, visibility:, async:, attributes:, line:, column: name_token.column)
    end

    def parse_interface_method_decl(attributes: [])
      visibility, visibility_token, async, kind, line, name_token = parse_method_like_decl_head
      raise error(visibility_token, "public is not allowed on interface methods") if visibility == :public

      name = name_token.lexeme
      _type_params, params, return_type, _body = parse_callable_signature(
        allow_type_params: false,
        generic_error_token: name_token,
        generic_error_message: "interface method #{name} cannot be generic",
        allow_body: false
      )
      AST::InterfaceMethodDecl.new(name:, params:, return_type:, kind:, async:, attributes:, line:, column: name_token.column)
    end

    def parse_method_like_decl_head
      visibility, visibility_token = parse_visibility
      async = match(:async)
      kind = parse_method_kind
      consume(:function, "expected function declaration")
      line = previous.line
      name_token = consume_name("expected function name")
      [visibility, visibility_token, async, kind, line, name_token]
    end

    def parse_method_kind
      return :editable if match(:editable)
      return :static if match(:static)

      :plain
    end

    def parse_callable_signature(allow_type_params: true, generic_error_token: nil, generic_error_message: nil, allow_body: true)
      type_params = parse_declaration_type_params
      if !allow_type_params && type_params.any?
        raise error(generic_error_token || previous, generic_error_message || "generic callable declarations are not allowed here")
      end

      params = nil
      return_type = nil
      body = nil

      with_type_param_names(type_params.map(&:name)) do
        params = parse_params
        return_type = match(:arrow) ? parse_type_ref : nil
        if allow_body
          body = parse_block
        else
          consume_end_of_statement
        end
      end

      [type_params, params, return_type, body]
    end

    def parse_visibility
      return [:public, previous] if match(:public)

      [:private, nil]
    end

    def parse_extern_decl(attributes: [])
      consume(:function, "expected function after external")
      parse_extern_function_decl(attributes:)
    end

    def parse_foreign_decl(visibility: :private, attributes: [])
      consume(:function, "expected function after foreign")
      parse_foreign_function_decl(visibility:, attributes:)
    end

    def parse_extern_function_decl(attributes: [])
      line = previous.line
      name = consume_name("expected function name").lexeme
      type_params = parse_declaration_type_params
      params = nil
      variadic = false
      return_type = nil
      mapping = nil
      with_type_param_names(type_params.map(&:name)) do
        params, variadic = parse_foreign_params(allow_variadic: true)
        consume(:arrow, "expected '->' before external function return type")
        return_type = parse_type_ref
        if match(:equal)
          mapping = parse_expression
        end
      end
      consume_end_of_statement
      AST::ExternFunctionDecl.new(name:, type_params:, params:, return_type:, variadic:, attributes:, line:, mapping:)
    end

    def parse_foreign_function_decl(visibility: :private, attributes: [])
      line = previous.line
      name = consume_name("expected function name").lexeme
      type_params = parse_declaration_type_params
      params = nil
      variadic = false
      return_type = nil
      mapping = nil
      with_type_param_names(type_params.map(&:name)) do
        params, variadic = parse_foreign_params(allow_variadic: true)
        consume(:arrow, "expected '->' before foreign function return type")
        return_type = parse_type_ref
        consume(:equal, "expected '=' before foreign function mapping")
        mapping = parse_expression
      end
      consume_end_of_statement
      AST::ForeignFunctionDecl.new(name:, type_params:, params:, return_type:, variadic:, mapping:, visibility:, attributes:, line:)
    end

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

    def parse_attribute_applications
      attributes = []

      while match(:at)
        consume(:lbracket, "expected '[' after '@'")
        raise error(peek, "expected attribute in attribute list") if check(:rbracket)

        attributes.concat(parse_comma_separated_until(:rbracket) { parse_attribute_application })
        consume(:rbracket, "expected ']' after attributes")
        skip_newlines
      end

      attributes
    end

    def parse_attribute_application
      start_token = peek
      name = parse_attribute_name
      arguments = match(:lparen) ? parse_call_arguments : []
      AST::AttributeApplication.new(name:, arguments:, line: start_token.line, column: start_token.column)
    end

    def parse_attribute_name
      parts = [consume_attribute_name_component("expected attribute name").lexeme]
      while match(:dot)
        parts << consume_attribute_name_component("expected attribute name after '.'").lexeme
      end
      AST::QualifiedName.new(parts:)
    end

    def consume_attribute_name_component(message)
      consume_name_allowing_keywords(message)
    end

    def parse_struct_layout_attributes(attributes)
      packed = false
      alignment = nil

      attributes.each do |attribute|
        next unless attribute.name.parts.length == 1

        case attribute.name.parts.first
        when "packed"
          packed = true
        when "align"
          first_argument = attribute.arguments.first
          next unless first_argument && first_argument.name.nil? && first_argument.value.is_a?(AST::IntegerLiteral)

          alignment = first_argument.value.value
        end
      end

      [packed, alignment]
    end

    def reject_attributes!(attributes)
      return if attributes.empty?

      raise error(peek, "attributes are only allowed on structs, struct fields, and callable declarations")
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

      first_token = peek
      name = parse_qualified_name
      arguments = []
      lifetime = nil
      if match(:lbracket)
        if match(:at)
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

    def parse_block
      consume(:colon, "expected ':' before block")
      consume(:newline, "expected newline before block")
      consume(:indent, "expected indented block")

      statements = parse_statement_block_body

      consume(:dedent, "expected end of block")
      statements
    end

    def parse_statement_block_body
      statements = []
      skip_newlines
      until check(:dedent) || eof?
        if @recovery_errors
          begin
            raise error(unexpected_statement_block_indent_token, "unexpected indentation in statement block") if check(:indent)

            statements << parse_statement
          rescue ParseError => e
            @recovery_errors << e
            header_type = recovery_statement_header_type(e)
            recovered_body = synchronize_to_statement_boundary
            statements << if recovered_body
                            recovery_error_block_stmt(e, recovered_body, header_type:)
                          else
                            recovery_error_stmt(e)
                          end
          end
        else
          raise error(unexpected_statement_block_indent_token, "unexpected indentation in statement block") if check(:indent)

          statements << parse_statement
        end
        skip_newlines
      end
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
      elsif match(:emit)
        parse_emit_stmt
      elsif match(:for)
        parse_for_stmt
      elsif match(:while)
        parse_while_stmt
      elsif match(:pass)
        parse_pass_stmt
      elsif match(:break)
        parse_break_stmt
      elsif match(:continue)
        parse_continue_stmt
      elsif match(:return)
        parse_return_stmt
      elsif match(:defer)
        parse_defer_stmt
      elsif check_inline_stmt_start?
        advance
        parse_inline_stmt
      elsif check_when_start?
        advance
        parse_when_stmt
      else
        parse_assignment_or_expression_stmt
      end
    end

    def parse_local_decl(kind)
      line = previous.line
      name_token = nil
      name = nil
      var_type = nil
      name_token = consume_name("expected local variable name")
      name = name_token.lexeme
      var_type = match(:colon) ? parse_type_ref : nil
      value = nil
      else_binding = nil
      else_body = nil
      else_started = false

      if match(:equal)
        value = parse_expression
        if match(:else)
          else_started = true

          if match(:as)
            binding_token = consume_name("expected error binding name after 'as'")
            else_binding = AST::Identifier.new(name: binding_token.lexeme, line: binding_token.line, column: binding_token.column)
          end

          else_body = parse_block
        else
          consume_end_of_statement unless block_expression?(value)
        end
      else
        raise error(name_token, "local declaration without initializer requires a type") unless var_type

        consume_end_of_statement
      end

      AST::LocalDecl.new(kind:, name:, type: var_type, value:, else_binding:, else_body:, line:, column: name_token.column)
    rescue ParseError => e
      raise unless @recovery_errors && name

      @recovery_errors << e
      synchronize_to_statement_boundary

      if else_started
        return AST::LocalDecl.new(
          kind:,
          name:,
          type: var_type,
          value: value,
          else_binding:,
          else_body: nil,
          line:,
          column: name_token.column,
          recovered_else: true,
        )
      end

      AST::LocalDecl.new(
        kind:,
        name:,
        type: var_type,
        value: recovery_error_expr(e),
        else_binding: nil,
        else_body: nil,
        line:,
        column: name_token.column,
      )
    end

    def parse_if_stmt
      line = previous.line
      branches = [parse_if_branch(previous)]

      while check(:else) && check_next(:if)
        advance
        advance
        branches << parse_if_branch(previous)
      end

      else_line = nil
      else_column = nil
      else_body = if match(:else)
                    else_line = previous.line
                    else_column = previous.column
                    parse_else_branch_body
                  end
      AST::IfStmt.new(branches:, else_body:, line:, else_line:, else_column:)
    end

    def parse_if_branch(token)
      condition = nil
      condition = parse_expression
      body = parse_block
      AST::IfBranch.new(
        condition:,
        body:,
        line: token.line,
        column: token.column,
        length: token.lexeme.length,
      )
    rescue ParseError => e
      raise unless @recovery_errors

      @recovery_errors << e
      recovered_body = synchronize_to_statement_boundary
      raise unless recovered_body

      AST::IfBranch.new(
        condition: condition || recovery_error_expr(e),
        body: recovered_body,
        line: token.line,
        column: token.column,
        length: token.lexeme.length,
      )
    end

    def parse_else_branch_body
      parse_block
    rescue ParseError => e
      raise unless @recovery_errors

      @recovery_errors << e
      recovered_body = synchronize_to_statement_boundary
      raise unless recovered_body

      recovered_body
    end

    def parse_match_stmt
      token = previous
      line = token.line
      expression = nil
      arms = []
      expression = parse_expression
      arms = parse_match_arms(arms)
      AST::MatchStmt.new(expression:, arms:, line:, column: token.column, length: token.lexeme.length)
    rescue ParseError => e
      raise unless @recovery_errors

      @recovery_errors << e
      recovered_arms = synchronize_to_match_arm_boundary
      return AST::MatchStmt.new(expression: expression || recovery_error_expr(e), arms: arms + recovered_arms, line:, column: token.column, length: token.lexeme.length) if recovered_arms

      recovery_error_stmt(e)
    end

    def parse_match_arms(arms = [])
      consume(:colon, "expected ':' before block")
      consume(:newline, "expected newline before block")
      consume(:indent, "expected indented block")

      parse_match_arm_body(arms)

      consume(:dedent, "expected end of block")
      arms
    end

    def parse_match_arm_body(arms = [])
      skip_newlines
      until check(:dedent) || eof?
        arms << parse_match_arm
        skip_newlines
      end

      arms
    end

    def parse_match_arm
      pattern = nil
      binding_token = nil
      binding_name = nil

      pattern = parse_expression
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
    rescue ParseError => e
      raise unless @recovery_errors

      @recovery_errors << e
      recovered_body = synchronize_to_statement_boundary
      return AST::MatchArm.new(
        pattern: pattern || recovery_error_expr(e),
        binding_name:,
        binding_line: binding_token&.line,
        binding_column: binding_token&.column,
        body: recovered_body,
      ) if recovered_body

      raise
    end

    def parse_unsafe_stmt
      token = previous
      consume(:colon, "expected ':' after unsafe")
      body = if match(:newline)
               consume(:indent, "expected indented block")

               statements = parse_statement_block_body
               consume(:dedent, "expected end of block")
               statements
             else
               statement = parse_statement
               raise ParseError.new("inline unsafe local declarations must use expression form", token:) if statement.is_a?(AST::LocalDecl)

               [statement]
             end
      AST::UnsafeStmt.new(body:, line: token.line, column: token.column, length: token.lexeme.length)
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

    def parse_emit_stmt
      line = previous.line
      column = previous.column
      decl = parse_declaration
      AST::EmitStmt.new(declaration: decl, line:, column:)
    rescue ParseError => e
      raise unless @recovery_errors

      @recovery_errors << e
      synchronize_to_statement_boundary
      AST::EmitStmt.new(declaration: AST::ErrorExpr.new(message: e.message), line:, column:)
    end

    def parse_for_stmt
      line = previous.line
      bindings = []
      iterables = nil
      loop do
        name_token = consume_name("expected loop variable name")
        bindings << AST::ForBinding.new(name: name_token.lexeme, line: name_token.line, column: name_token.column)
        break unless match(:comma)
      end
      consume(:in, "expected 'in' in for loop")
      iterables = [parse_expression]
      iterables << parse_expression while match(:comma)
      body = parse_block
      AST::ForStmt.new(bindings:, iterables:, body:, line:, column: bindings.first.column)
    rescue ParseError => e
      raise unless @recovery_errors

      @recovery_errors << e
      recovered_body = synchronize_to_statement_boundary
      return recovery_error_block_stmt(
        e,
        recovered_body,
        header_type: :for,
        header_bindings: bindings.empty? ? nil : bindings,
        header_iterables: iterables&.any? ? iterables : nil,
      ) if recovered_body

      recovery_error_stmt(e)
    end

    def parse_while_stmt
      token = previous
      line = token.line
      condition = parse_expression
      body = parse_block
      AST::WhileStmt.new(condition:, body:, line:, column: token.column, length: token.lexeme.length)
    rescue ParseError => e
      raise unless @recovery_errors

      @recovery_errors << e
      recovered_body = synchronize_to_statement_boundary
      return AST::WhileStmt.new(
        condition: condition || recovery_error_expr(e),
        body: recovered_body,
        line:,
        column: token.column,
        length: token.lexeme.length,
      ) if recovered_body

      recovery_error_stmt(e)
    end

    def parse_pass_stmt
      token = previous
      line = token.line
      consume_end_of_statement
      AST::PassStmt.new(line:, column: token.column, length: token.lexeme.length)
    end

    def parse_break_stmt
      token = previous
      line = token.line
      consume_end_of_statement
      AST::BreakStmt.new(line:, column: token.column, length: token.lexeme.length)
    end

    def parse_continue_stmt
      token = previous
      line = token.line
      consume_end_of_statement
      AST::ContinueStmt.new(line:, column: token.column, length: token.lexeme.length)
    end

    def parse_return_stmt
      token = previous
      line = token.line
      value = check(:newline) ? nil : parse_expression
      consume_end_of_statement unless block_expression?(value)
      AST::ReturnStmt.new(value:, line:, column: token.column, length: token.lexeme.length)
    end

    def parse_defer_stmt
      token = previous
      line = token.line
      if check(:colon)
        body = parse_block
        AST::DeferStmt.new(expression: nil, body:, line:, column: token.column, length: token.lexeme.length)
      else
        expression = parse_expression
        consume_end_of_statement unless block_expression?(expression)
        AST::DeferStmt.new(expression:, body: nil, line:, column: token.column, length: token.lexeme.length)
      end
    end

    def parse_when_stmt
      token = previous
      line = token.line
      discriminant = parse_expression
      branches = parse_match_arms([])
      else_body = if check(:else)
        if check_next(:newline) || check_next(:indent)
          parse_else_branch_body
        end
      end
      AST::WhenStmt.new(discriminant:, branches:, else_body:, line:, column: token.column, length: token.lexeme.length)
    rescue ParseError => e
      raise unless @recovery_errors

      @recovery_errors << e
      recovered_body = synchronize_to_statement_boundary
      return recovery_error_block_stmt(e, recovered_body, header_type: :when) if recovered_body

      recovery_error_stmt(e)
    end

    def parse_inline_stmt
      token = previous
      if match(:for)
        parse_inline_for_stmt(token)
      elsif match(:while)
        parse_inline_while_stmt(token)
      elsif match(:match)
        parse_inline_match_stmt(token)
      elsif match(:if)
        parse_inline_if_stmt(token)
      else
        raise error(peek, "expected for, while, match, or if after inline")
      end
    end

    def parse_inline_for_stmt(_inline_token)
      line = previous.line
      bindings = []
      iterables = nil
      loop do
        name_token = consume_name("expected loop variable name")
        bindings << AST::ForBinding.new(name: name_token.lexeme, line: name_token.line, column: name_token.column)
        break unless match(:comma)
      end
      consume(:in, "expected 'in' in for loop")
      iterables = [parse_expression]
      iterables << parse_expression while match(:comma)
      body = parse_block
      AST::ForStmt.new(bindings:, iterables:, body:, inline: true, line:, column: bindings.first.column)
    rescue ParseError => e
      raise unless @recovery_errors

      @recovery_errors << e
      recovered_body = synchronize_to_statement_boundary
      return recovery_error_block_stmt(e, recovered_body, header_type: :for) if recovered_body

      recovery_error_stmt(e)
    end

    def parse_inline_while_stmt(inline_token)
      line = inline_token.line
      condition = parse_expression
      body = parse_block
      AST::WhileStmt.new(condition:, body:, inline: true, line:, column: inline_token.column, length: inline_token.lexeme.length)
    rescue ParseError => e
      raise unless @recovery_errors

      @recovery_errors << e
      recovered_body = synchronize_to_statement_boundary
      return AST::WhileStmt.new(
        condition: condition || recovery_error_expr(e),
        body: recovered_body,
        line:,
        column: inline_token.column,
        length: inline_token.lexeme.length,
      ) if recovered_body

      recovery_error_stmt(e)
    end

    def parse_inline_match_stmt(inline_token)
      token = previous
      line = token.line
      arms = []
      expression = parse_expression
      arms = parse_match_arms(arms)
      AST::MatchStmt.new(expression:, arms:, inline: true, line:, column: token.column, length: token.lexeme.length)
    rescue ParseError => e
      raise unless @recovery_errors

      @recovery_errors << e
      recovered_arms = synchronize_to_match_arm_boundary
      return AST::MatchStmt.new(expression: expression || recovery_error_expr(e), arms: arms + recovered_arms, inline: true, line:, column: token.column, length: token.lexeme.length) if recovered_arms

      recovery_error_stmt(e)
    end

    def parse_inline_if_stmt(inline_token)
      token = previous
      line = token.line
      branches = [parse_if_branch(token)]

      while check(:else) && check_next(:if)
        advance
        advance
        branches << parse_if_branch(previous)
      end

      else_body = match(:else) ? parse_else_branch_body : nil
      AST::IfStmt.new(branches:, else_body:, inline: true, line:)
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
        arms << parse_match_expression_arm
        skip_newlines
      end

      consume(:dedent, "expected end of match expression arms")
      arms
    end

    def parse_match_expression_arm
      pattern = parse_expression
      binding_token = nil
      binding_name = if match(:as)
                       binding_token = consume_name("expected binding name after 'as'")
                       binding_token.lexeme
                     end
      consume(:colon, "expected ':' after match expression arm pattern")
      value = parse_expression
      consume_end_of_statement unless block_expression?(value)
      AST::MatchExprArm.new(
        pattern:,
        binding_name:,
        binding_line: binding_token&.line,
        binding_column: binding_token&.column,
        value:,
      )
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

    def foreign_param_qualifier_mode?
      return false unless %i[out in inout consuming].include?(peek.type)

      @tokens[@current + 1]&.type == :identifier
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
      elsif match(:unsafe)
        parse_unsafe_expression
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
      target_head = peek
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
          callee: AST::Identifier.new(name: "cast", line: target_head.line, column: target_head.column),
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
      elsif match(:proc)
        parse_proc_expr
      elsif match_name
        AST::Identifier.new(name: previous.lexeme, line: previous.line, column: previous.column)
      elsif match(:integer)
        AST::IntegerLiteral.new(lexeme: previous.lexeme, value: previous.literal)
      elsif match(:float)
        AST::FloatLiteral.new(lexeme: previous.lexeme, value: previous.literal)
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
        type = nil
        if match(:lbracket)
          type = parse_type_ref
          consume(:rbracket, "expected ']' after typed null literal")
        end
        AST::NullLiteral.new(type:)
      elsif match(:lparen)
        line = previous.line
        column = previous.column
        first = parse_expression
        if match(:comma)
          elements = [first]
          loop do
            elements << parse_expression
            break unless match(:comma)
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

    def parse_comma_separated_until(closing_type)
      items = []

      unless check(closing_type)
        loop do
          items << yield
          break unless match(:comma)
          break if check(closing_type)
        end
      end

      items
    end

    def block_expression?(expression)
      expression.is_a?(AST::ProcExpr) || expression.is_a?(AST::MatchExpr)
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

    def parse_qualified_name
      parts = [consume_path_component("expected identifier").lexeme]
      while match(:dot)
        parts << consume_path_component("expected identifier after '.'").lexeme
      end
      AST::QualifiedName.new(parts:)
    end

    def parse_qualified_name_with_type_arguments
      parts = [consume_path_component("expected identifier").lexeme]
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
      AST::QualifiedName.new(parts:, type_arguments:)
    end

    def consume_path_component(message)
      # Module path components accept any word token (identifier or keyword),
      # since they reference declared module paths, not introduce new name bindings.
      return advance if !eof? && (peek.type == :identifier || Token::KEYWORDS.value?(peek.type))

      raise error(peek, message)
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

    def consume_end_of_statement
      consume(:newline, "expected end of statement")
    end

    def synchronize_to_top_level_boundary
      seen_newline = false

      until eof?
        token = peek

        if token.type == :newline
          seen_newline = true
          advance
          next
        end

        if [:indent, :dedent].include?(token.type)
          advance
          next
        end

        break if seen_newline && top_level_recovery_start?(token)

        advance
      end
    end

    def synchronize_to_statement_boundary
      until eof?
        return recover_statement_block_body if check(:indent)
        return nil if check(:dedent)

        if check(:newline)
          advance
          return recover_statement_block_body if check(:indent)
          return nil
        end

        advance
      end

      nil
    end

    def unexpected_statement_block_indent_token
      token = peek
      return token unless token&.type == :indent

      candidate = @tokens[@current + 1]
      return token unless candidate
      return token if %i[newline dedent eof].include?(candidate.type)

      candidate
    end

    def synchronize_to_match_arm_boundary
      until eof?
        return nil if check(:dedent)

        if check(:newline)
          advance
          return recover_match_arm_block if check(:indent)
          return nil
        end

        advance
      end

      nil
    end

    def recover_statement_block_body
      advance if check(:indent)

      statements = parse_statement_block_body
      advance if check(:dedent)
      statements
    end

    def recover_match_arm_block
      advance if check(:indent)

      arms = parse_match_arm_body([])
      advance if check(:dedent)
      arms
    end

    def recovery_error_expr(error)
      token = error.token
      AST::ErrorExpr.new(
        line: token&.line,
        column: token&.column,
        length: token&.lexeme&.length,
        message: error.message,
      )
    end

    def recovery_error_stmt(error)
      token = error.token
      AST::ErrorStmt.new(
        line: token&.line,
        column: token&.column,
        length: token&.lexeme&.length,
        message: error.message,
      )
    end

    def recovery_error_block_stmt(error, body, header_type: nil, header_expression: nil, header_bindings: nil, header_iterables: nil)
      token = error.token
      AST::ErrorBlockStmt.new(
        body:,
        line: token&.line,
        column: token&.column,
        length: token&.lexeme&.length,
        message: error.message,
        header_type:,
        header_expression:,
        header_bindings:,
        header_iterables:,
      )
    end

    def recovery_statement_header_type(error)
      return :unsafe if previous&.type == :unsafe && error.message.include?("after unsafe")

      nil
    end

    def top_level_recovery_start?(token)
      token.column.to_i <= 1 && (TOP_LEVEL_RECOVERY_START_TYPES.include?(token.type) || legacy_layout_modifier_start?(token))
    end

    def legacy_layout_modifier_start?(token)
      token&.type == :identifier && BUILTIN_ATTRIBUTE_NAME_LEXEMES.include?(token.lexeme)
    end

    def skip_newlines
      advance while check(:newline)
    end

    def external_file_header?
      return false unless check(:external)

      next_token = @tokens[@current + 1]
      next_token.nil? || %i[newline eof].include?(next_token.type)
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
      if keyword_token?(peek)
        name_role = message.sub(/\A(?:expected|required)\s+/, "")
        clearer_message = if name_role == message
                            message
                          else
                            "keyword '#{peek.lexeme}' cannot be used as #{name_role}"
                          end
        raise error(peek, clearer_message)
      end

      consume(:identifier, message)
    end

    def consume_name_allowing_keywords(message)
      if check(:identifier)
        advance
      elsif keyword_token?(peek)
        advance
      else
        raise error(peek, message)
      end
    end

    def keyword_token?(token)
      token && Token::KEYWORDS.key?(token.lexeme)
    end

    def check_inline_stmt_start?
      return false unless check(:inline)

      next_idx = @current + 1
      return false if next_idx >= @tokens.length

      next_token = @tokens[next_idx]
      %i[for while match if].include?(next_token.type)
    end

    def check_when_start?
      check(:identifier) && peek.lexeme == "when"
    end

    def check(type)
      return false if eof?

      peek.type == type
    end

    def check_name
      !eof? && peek.type == :identifier
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
      expression.is_a?(AST::Identifier) && %w[array reinterpret span zero ptr const_ptr ref].include?(expression.name)
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
      if expression.is_a?(AST::Identifier) && %w[cast default zero].include?(expression.name) &&
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

    def known_type_like_name?(name)
      @known_type_names.key?(name) || @known_import_aliases.key?(name) || @current_type_param_names.include?(name)
    end

    def with_type_param_names(names)
      saved_names = @current_type_param_names
      @current_type_param_names = @current_type_param_names + names
      yield
    ensure
      @current_type_param_names = saved_names
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
        when :function
          if depth.zero?
            name_token = @tokens[index + 1]
            type_param_token = @tokens[index + 2]
            if type_name_token?(name_token) && type_param_token&.type == :lbracket
              @known_generic_callable_names[name_token.lexeme] = true
            end
          end
        when :async
          if depth.zero? && @tokens[index + 1]&.type == :function
            name_token = @tokens[index + 2]
            type_param_token = @tokens[index + 3]
            if type_name_token?(name_token) && type_param_token&.type == :lbracket
              @known_generic_callable_names[name_token.lexeme] = true
            end
          end
        when :foreign
          if depth.zero? && @tokens[index + 1]&.type == :function
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
      token&.type == :identifier
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
