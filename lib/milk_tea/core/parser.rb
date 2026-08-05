# frozen_string_literal: true

require_relative "parser/blocks"
require_relative "parser/recovery"
require_relative "parser/types"
require_relative "parser/attributes"
require_relative "parser/expressions"
require_relative "parser/declarations"
require_relative "parser/statements"

module MilkTea
  class ParseError < StandardError
    attr_reader :token, :path

    def initialize(message, token:, path: nil)
      @token = token
      @path = path

      location = [path, "#{token.line}:#{token.column}"].compact.join(":")
      super(location.empty? ? message : "#{message} at #{location}")
    end

    def line
      @token.line
    end

    def column
      @token.column
    end

    def code
      "parse/error"
    end
  end

  class SyntaxTokenStream
    def initialize(tokens)
      @tokens = tokens
    end

    def [](index)
      @tokens[index]
    end

    def length
      @tokens.length
    end

    def to_a
      @tokens
    end
  end

  class Parser
    ParseRecoveryResult = Data.define(:ast, :errors) do
      def initialize(ast:, errors: []) = super
    end

    ParseContext = Data.define(:known_type_names, :known_import_aliases, :known_generic_callable_names, :current_type_param_names)

    include Blocks
    include Recovery
    include Types
    include Attributes
    include Expressions
    include Declarations
    include Statements

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
      @in_inline_block_body = false
      seed_known_names
    end

    def parse
      parse_source_file
    end

    def parse_collecting_errors
      errors = @recovery_errors ? @recovery_errors.dup : []
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

    BUILTIN_ATTRIBUTE_NAME_LEXEMES = %w[packed align].freeze

    def parse_source_file(errors: nil)
      skip_newlines

      module_name = nil
      module_kind = :module
      module_line = nil
      imports = []
      directives = []
      declarations = []

      if at_external_file?
        advance
        module_line = previous.line
        module_kind = :raw_module
        consume(:newline, "expected newline after external") unless eof?
        skip_newlines
        imports, directives, declarations = parse_raw_module_body(errors:)
        skip_newlines
        raise error(peek, "expected end of file after external declarations") unless eof?

        return AST.assign_node_ids(AST::SourceFile.new(module_name:, module_kind:, imports:, directives:, declarations:, line: module_line))
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

      AST.assign_node_ids(AST::SourceFile.new(module_name:, module_kind:, imports:, directives:, declarations:, line: module_line))
    end

    def at_external_file?
      return false unless check(:external)

      next_token = @tokens[@current + 1]
      next_token.nil? || %i[newline eof].include?(next_token.type)
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

    def match(*types)
      return false unless types.any? { |type| check(type) }

      advance
      true
    end

    def consume(type, message)
      return advance if check(type)

      raise error(%i[rparen rbracket rbrace].include?(type) ? previous : peek, message)
    end

    def consume_name(message)
      if keyword?(peek)
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
      elsif keyword?(peek)
        advance
      else
        raise error(peek, message)
      end
    end

    def keyword?(token)
      token && Token::KEYWORDS.key?(token.lexeme)
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

    def match_name
      return false unless check_name

      advance
      true
    end

    def error(token, message)
      ParseError.new(message, token:, path: @path)
    end

    def skip_newlines
      advance while check(:newline)
    end

    def consume_end_of_statement
      return if @in_inline_block_body

      consume(:newline, "expected end of statement")
    end

    def finish_expression_statement(value)
      consume_end_of_statement unless block_expression?(value)
    end

    def block_expression?(expression)
      expression.is_a?(AST::ProcExpr) || expression.is_a?(AST::MatchExpr) || expression.is_a?(AST::IfExpr)
    end

    def parse_qualified_name
      parts = [consume_path_component("expected identifier").lexeme]
      while match(:dot)
        parts << consume_path_component("expected identifier after '.'").lexeme
      end
      AST::QualifiedName.new(parts:)
    end

    def consume_path_component(message)
      return advance if !eof? && (peek.type == :identifier || Token::KEYWORDS.value?(peek.type))

      raise error(peek, message)
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

    def foreign_param_mode_start?
      return false unless %i[out in inout consuming].include?(peek.type)

      @tokens[@current + 1]&.type == :identifier
    end

    def builtin_attribute_identifier?(token)
      token&.type == :identifier && BUILTIN_ATTRIBUTE_NAME_LEXEMES.include?(token.lexeme)
    end

    def known_type_context_name?(name)
      @known_type_names.key?(name) || @known_import_aliases.key?(name) || @current_type_param_names.include?(name)
    end

    def with_type_param_names(names)
      saved_names = @current_type_param_names
      @current_type_param_names = @current_type_param_names + names
      yield
    ensure
      @current_type_param_names = saved_names
    end

    # Returns a ParseContext snapshot of the parser state that must propagate
    # to nested parsers (e.g. format string interpolations).  When adding
    # parser state that must be cloned, update both this method,
    # apply_parser_context, and the ParseContext Data class.
    def parser_context
      ParseContext.new(
        known_type_names: @known_type_names.dup,
        known_import_aliases: @known_import_aliases.dup,
        known_generic_callable_names: @known_generic_callable_names.dup,
        current_type_param_names: @current_type_param_names.dup,
      )
    end

    def apply_parser_context(context)
      @known_type_names = context.known_type_names
      @known_import_aliases = context.known_import_aliases
      @known_generic_callable_names = context.known_generic_callable_names
      @current_type_param_names = context.current_type_param_names
    end

    def seed_known_names
      MilkTea::BUILTIN_TYPE_NAMES.each { |name| @known_type_names[name] = true }

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
            if identifier_token?(name_token) && type_param_token&.type == :lbracket
              @known_generic_callable_names[name_token.lexeme] = true
            end
          end
        when :async
          if depth.zero? && @tokens[index + 1]&.type == :function
            name_token = @tokens[index + 2]
            type_param_token = @tokens[index + 3]
            if identifier_token?(name_token) && type_param_token&.type == :lbracket
              @known_generic_callable_names[name_token.lexeme] = true
            end
          end
        when :foreign
          if depth.zero? && @tokens[index + 1]&.type == :function
            name_token = @tokens[index + 2]
            type_param_token = @tokens[index + 3]
            if identifier_token?(name_token) && type_param_token&.type == :lbracket
              @known_generic_callable_names[name_token.lexeme] = true
            end
          end
        when :struct, :union, :enum, :flags, :opaque, :type, :variant
          if depth.zero?
            name_token = @tokens[index + 1]
            @known_type_names[name_token.lexeme] = true if identifier_token?(name_token)
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
          @known_import_aliases[alias_token.lexeme] = true if identifier_token?(alias_token)
          return cursor
        end

        last_part = token.lexeme if identifier_token?(token)
        cursor += 1
      end

      @known_import_aliases[last_part] = true if last_part
      cursor
    end

    def identifier_token?(token)
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
  end
end
