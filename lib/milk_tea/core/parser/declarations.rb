# frozen_string_literal: true

module MilkTea
  module Parse
    module Declarations
      private

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
          reject_attributes!(attributes, "attribute")
          parse_attribute_decl(visibility:)
        elsif match(:const)
          if match(:function)
            parse_function_def(visibility:, const: true, attributes:)
          else
            parse_const_decl(visibility:, attributes:)
          end
        elsif match(:var)
          reject_attributes!(attributes, "var")
          parse_var_decl(visibility:)
        elsif match(:event)
          parse_event_decl(visibility:, attributes:)
        elsif match(:type)
          reject_attributes!(attributes, "type")
          parse_type_alias_decl(visibility:)
        elsif match(:struct)
          parse_struct_decl(visibility:, attributes:)
        elsif match(:union)
          parse_union_decl(visibility:, attributes:)
        elsif match(:enum)
          parse_enum_decl(AST::EnumDecl, visibility:, attributes:)
        elsif match(:flags)
          parse_enum_decl(AST::FlagsDecl, visibility:, attributes:)
        elsif match(:variant)
          parse_variant_decl(visibility:, attributes:)
        elsif match(:interface)
          reject_attributes!(attributes, "interface")
          parse_interface_decl(visibility:)
        elsif match(:opaque)
          reject_attributes!(attributes, "opaque")
          parse_opaque_decl(visibility:)
        elsif match(:extending)
          reject_attributes!(attributes, "extending")
          raise error(visibility_token, "public is not allowed on extending blocks") if visibility == :public

          parse_extending_block
        elsif check(:editable) || check(:static)
          reject_attributes!(attributes, "standalone method")
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
          reject_attributes!(attributes, "static_assert")
          raise error(visibility_token, "public is not allowed on static_assert") if visibility == :public

          parse_static_assert
        elsif check_when_start?
          reject_attributes!(attributes, "when")
          raise error(visibility_token, "public is not allowed on when") if visibility == :public

          advance
          parse_when_decl
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

      def parse_const_decl(visibility: :private, attributes: [])
        line = previous.line
        name = nil
        type = nil
        name_token = consume_name("expected constant name")
        name = name_token.lexeme
        if match(:arrow)
          type = parse_type_ref
          body = parse_block
          return AST::ConstDecl.new(name:, type:, value: nil, block_body: body, visibility:, attributes:, line:, column: name_token.column)
        end

        consume(:colon, "expected ':' after constant name")
        type = parse_type_ref
        consume(:equal, "expected '=' after constant type")
        value = parse_expression
        consume_end_of_statement
        AST::ConstDecl.new(name:, type:, value:, visibility:, attributes:, line:, column: name_token.column)
      rescue ParseError => e
        raise unless @recovery_errors && name

        @recovery_errors << e
        synchronize_to_statement_boundary
        AST::ConstDecl.new(name:, type: type || recovery_error_expr(e), value: recovery_error_expr(e), visibility:, attributes:, line:, column: name_token.column)
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
        AST::VarDecl.new(name:, type: var_type, value:, visibility:, line:, column: name_token.column)
      rescue ParseError => e
        raise unless @recovery_errors && name

        @recovery_errors << e
        synchronize_to_statement_boundary
        AST::VarDecl.new(name:, type: var_type || recovery_error_expr(e), value: recovery_error_expr(e), visibility:, line:, column: name_token.column)
      end

      def parse_event_decl(visibility: :private, attributes: [])
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
        AST::EventDecl.new(name: name_token.lexeme, capacity:, payload_type:, visibility:, attributes:, line:, column: name_token.column)
      end

      def parse_type_alias_decl(visibility: :private)
        line = previous.line
        name_token = consume_name("expected type alias name")
        name = name_token.lexeme
        consume(:equal, "expected '=' after type alias name")
        target = parse_type_ref
        consume_end_of_statement
        AST::TypeAliasDecl.new(name:, target:, visibility:, line:, column: name_token.column)
      end

      def parse_attribute_decl(visibility: :private)
        line = previous.line
        consume(:lbracket, "expected '[' after attribute")
        targets = parse_comma_separated_until(:rbracket) do
          target_token = consume_path_component("expected attribute target")
          case target_token.lexeme
          when "struct"        then :struct
          when "field"         then :field
          when "callable"      then :callable
          when "const"         then :const
          when "event"         then :event
          when "enum"          then :enum
          when "flags"         then :flags
          when "union"         then :union
          when "variant"       then :variant
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
        name_token = consume_name("expected struct name")
        name = name_token.lexeme
        lifetime_params, type_params = parse_struct_decl_params
        implements = parse_implements_clause
        c_name = parse_optional_explicit_c_name
        packed, alignment = parse_struct_layout_attributes(attributes) if attributes.any?
        members = parse_named_block do
          parse_struct_member
        end
        fields = members.filter_map { |kind, member| member if kind == :field }
        events = members.filter_map { |kind, member| member if kind == :event }
        nested_types = members.filter_map { |kind, member| member if kind == :nested_type }
        AST::StructDecl.new(name:, type_params:, implements:, c_name:, fields:, events:, nested_types:, attributes:, packed:, alignment:, visibility:, lifetime_params:, line:, column: name_token.column)
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
          return [:event, parse_event_decl(visibility:, attributes: field_attributes)]
        end

        if match(:struct)
          return [:nested_type, parse_struct_decl(visibility:, attributes: field_attributes)]
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

      def parse_union_decl(visibility: :private, attributes: [])
        line = previous.line
        name_token = consume_name("expected union name")
        name = name_token.lexeme
        c_name = parse_optional_explicit_c_name
        fields = parse_named_block do
          field_name = consume_name("expected field name").lexeme
          consume(:colon, "expected ':' after field name")
          field_type = parse_type_ref
          consume_end_of_statement
          AST::Field.new(name: field_name, type: field_type)
        end
        AST::UnionDecl.new(name:, c_name:, fields:, visibility:, attributes:, line:, column: name_token.column)
      end

      def parse_optional_explicit_c_name
        return nil unless match(:equal)

        consume(:cstring, "expected C string literal after '='").literal
      end

      def parse_enum_decl(node_class, visibility: :private, attributes: [])
        line = previous.line
        name_token = consume_name("expected declaration name")
        name = name_token.lexeme
        consume(:colon, "expected ':' after declaration name")
        backing_type = if check(:newline) || check(:indent)
                         AST::TypeRef.new(name: AST::QualifiedName.new(parts: ["int"], type_arguments: []), arguments: [], nullable: false, lifetime: nil, line: line, column: name.length + 1)
                       else
                         parse_type_ref
                       end
        skip_newlines
        consume(:indent, "expected indented declaration body")

        members = []
        skip_newlines
        auto_value = 0
        until check(:dedent) || eof?
          member_token = consume_name("expected member name")
          member_name = member_token.lexeme
          if match(:equal)
            value = parse_expression
            if value.is_a?(AST::IntegerLiteral)
              auto_value = value.value + 1
            elsif value.is_a?(AST::UnaryOp) && value.operator == "-" && value.operand.is_a?(AST::IntegerLiteral)
              auto_value = -value.operand.value + 1
            end
          else
            value = AST::IntegerLiteral.new(lexeme: auto_value.to_s, value: auto_value)
            auto_value += 1
          end
          consume_end_of_statement
          members << AST::EnumMember.new(name: member_name, value:, line: member_token.line, column: member_token.column)
          skip_newlines
        end

        consume(:dedent, "expected end of declaration body")
        node_class.new(name:, backing_type:, members:, visibility:, attributes:, line:, column: name_token.column)
      end

      def parse_variant_decl(visibility: :private, attributes: [])
        line = previous.line
        name_token = consume_name("expected variant name")
        name = name_token.lexeme
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
        AST::VariantDecl.new(name:, type_params:, arms:, visibility:, attributes:, line:, column: name_token.column)
      end

      def parse_opaque_decl(visibility: :private)
        line = previous.line
        name_token = consume_name("expected opaque type name")
        name = name_token.lexeme
        implements = parse_implements_clause
        c_name = nil
        if match(:equal)
          c_name = consume(:cstring, "expected C string literal after '='").literal
        end
        consume_end_of_statement
        AST::OpaqueDecl.new(name:, implements:, c_name:, visibility:, line:, column: name_token.column)
      end

      def parse_interface_decl(visibility: :private)
        line = previous.line
        name_token = consume_name("expected interface name")
        name = name_token.lexeme
        type_params = parse_declaration_type_params
        methods = parse_named_block do
          method_attributes = parse_attribute_applications
          parse_interface_method_decl(attributes: method_attributes)
        end
        AST::InterfaceDecl.new(name:, type_params:, methods:, visibility:, line:, column: name_token.column)
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
        AST::ExtendingBlock.new(type_name:, methods:, line:, column: type_name.column)
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
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        AST::FunctionDef.new(name:, type_params: [], params: [], return_type: nil, body: nil, visibility:, async:, const:, attributes:, line:, column: name_token.column)
      end

      def parse_method_def(attributes: [])
        visibility, _visibility_token, async, kind, line, name_token = parse_method_like_decl_head
        name = name_token.lexeme
        type_params, params, return_type, body = parse_callable_signature
        AST::MethodDef.new(name:, type_params:, params:, return_type:, body:, kind:, visibility:, async:, attributes:, line:, column: name_token.column)
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        name = name_token&.lexeme || "unknown"
        col = name_token&.column || 1
        advance until eof? || check(:function) || check(:dedent)
        AST::MethodDef.new(name:, type_params: [], params: [], return_type: nil, body: nil, kind: kind || :plain, visibility: visibility || :private, async: async || false, attributes:, line:, column: col)
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
        if check(:function)
          consume(:function, "expected function declaration")
        elsif check(:identifier)
          bad_token = advance
          @recovery_errors << ParseError.new("unknown keyword '#{bad_token.lexeme}'; expected 'function' (did you mean 'editable', 'static', or 'async'?)", token: bad_token, path: @path) if @recovery_errors
        else
          raise error(peek, "expected function declaration")
        end
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
            body = parse_block_body_safe
          else
            consume_end_of_statement
          end
        end

        [type_params, params, return_type, body]
      end

      def parse_block_body_safe
        parse_block
      rescue ParseError => e
        raise unless @recovery_errors

        @recovery_errors << e
        match(:newline)
        if match(:indent)
          begin
            parse_and_dedent_block_body || []
          rescue ParseError => e2
            @recovery_errors << e2
            []
          end
        end
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
    end
  end
end
