# frozen_string_literal: true

module MilkTea
  # Serializes lexer tokens and parser AST nodes to industry-standard
  # S-expressions. Uses keyword-prefixed field names for AST nodes to
  # produce an unambiguous, diff-friendly structural dump.
  module SexprDumper
    module_function

    # ── public entry points ──────────────────────────────────────────

    def dump_tokens(tokens)
      tokens.map { |t| token_sexpr(t) }.join("\n") + "\n"
    end

    def dump_ast(ast)
      buf = +""
      emit_ast_node(ast, indent: 0, buf:)
      buf
    end

    # ── token serialisation ──────────────────────────────────────────
    # Format: (type "lexeme" literal line column start_offset end_offset)

    def token_sexpr(token)
      type_str = token.type.to_s.tr("_", "-")
      lexeme = escape_string(token.lexeme)
      literal = format_literal(token.literal)
      "(#{type_str} #{lexeme} #{literal} #{token.line} #{token.column} #{token.start_offset} #{token.end_offset})"
    end

    # ── AST serialisation ────────────────────────────────────────────

    INLINE_LEAF_TYPES = %w[
      QualifiedName TypeRef Identifier MemberAccess
      IntegerLiteral FloatLiteral StringLiteral CharLiteral
      BooleanLiteral NullLiteral FormatTextPart
      Field EnumMember Param VariantArm ForBinding
      TypeArgument Argument AttributeApplication
    ].freeze

    SKIP_FIELDS = %i[node_ids node_path_ids].freeze
    SP = "  "

    # ── node emitter ─────────────────────────────────────────────────

    def emit_ast_node(node, indent:, buf:, inline: false)
      return buf << "nil" if node.nil?

      type_name = node.class.name.sub(/\AMilkTea::AST::/, "")

      unless node.is_a?(::Data)
        buf << format_atom(node)
        return
      end

      members = node.class.members - SKIP_FIELDS

      # Leaf types and inline nodes: single-line
      leaf = INLINE_LEAF_TYPES.include?(type_name)
      if leaf || inline || members.empty?
        emit_inline_node(type_name, node, members, indent:, buf:)
      else
        emit_multiline_node(type_name, node, members, indent:, buf:)
      end
    end

    def emit_inline_node(type_name, node, members, indent:, buf:)
      pad = SP * indent
      buf << pad << "(" << type_name
      members.each do |field_name|
        value = node.public_send(field_name)
        next if skip_value?(field_name, value)

        buf << " :#{field_name} "
        emit_value(value, indent:, inline: true, buf:)
      end
      buf << ")"
    end

    def emit_multiline_node(type_name, node, members, indent:, buf:)
      pad = SP * indent
      inner_pad = SP * (indent + 1)

      buf << pad << "(" << type_name

      members.each do |field_name|
        value = node.public_send(field_name)
        next if skip_value?(field_name, value)

        buf << "\n" << inner_pad << ":#{field_name} "
        emit_value(value, indent: indent + 1, inline: false, buf:)
      end

      buf << ")"
    end

    def skip_value?(field_name, value)
      return true if SKIP_FIELDS.include?(field_name)
      return true if value.nil? && field_name != :body
      false
    end

    def emit_value(value, indent:, inline:, buf:)
      case value
      when ::Data
        emit_ast_node(value, indent:, buf:, inline:)
      when Array
        emit_array(value, indent:, inline:, buf:)
      when nil
        buf << "nil"
      else
        buf << format_atom(value)
      end
    end

    def emit_array(values, indent:, inline:, buf:)
      if values.empty?
        buf << "()"
        return
      end

      all_atomic = values.none? { |v| v.is_a?(::Data) }

      if inline || all_atomic
        buf << "("
        values.each_with_index do |v, i|
          buf << " " if i > 0
          emit_value(v, indent:, inline: true, buf:)
        end
        buf << ")"
      else
        inner_pad = SP * (indent + 1)
        buf << "("
        values.each do |v|
          buf << "\n"
          if v.is_a?(::Data)
            emit_ast_node(v, indent: indent + 1, buf:, inline: false)
          else
            buf << inner_pad; emit_value(v, indent: indent + 1, inline: true, buf:)
          end
        end
        buf << ")"
      end
    end

    # ── value helpers ────────────────────────────────────────────────

    def format_atom(value)
      case value
      when nil       then "nil"
      when true      then "true"
      when false     then "false"
      when Integer   then value.to_s
      when Float     then value.to_s
      when String    then escape_string(value)
      when Symbol    then value.to_s.tr("_", "-")
      when AST::QualifiedName
        parts = value.parts.map { |p| escape_string(p) }.join(" ")
        "(QualifiedName #{parts})"
      else
        escape_string(value.to_s)
      end
    end

    def format_literal(value)
      case value
      when nil       then "nil"
      when true      then "true"
      when false     then "false"
      when Integer   then value.to_s
      when Float     then value.to_s
      when String    then escape_string(value)
      else escape_string(value.inspect)
      end
    end

    def escape_string(str)
      return '""' if str.nil? || str.empty?

      escaped = str.gsub('\\', '\\\\').gsub('"', '\"').gsub("\n", '\\n').gsub("\t", '\\t').gsub("\r", '\\r')
      "\"#{escaped}\""
    end
  end
end
