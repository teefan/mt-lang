# frozen_string_literal: true

module MilkTea
  module SexprParser
    module_function

    # ── public API ────────────────────────────────────────────────────

    def parse_ir(sexpr)
      tokens = tokenize(sexpr)
      _parse_value(tokens)
    end

    def parse_ast(sexpr)
      tokens = tokenize(sexpr)
      _parse_value(tokens)
    end

    def parse_tokens(sexpr)
      tokens = tokenize(sexpr)
      _parse_value(tokens)
    end

    # ── tokenizer ─────────────────────────────────────────────────────

    Token = Data.define(:kind, :text, :line, :column)

    def tokenize(source)
      tokens = []
      i = 0
      len = source.length
      line = 1
      col = 1
      while i < len
        ch = source[i]
        case ch
        when "(", ")"
          tokens << Token.new(kind: ch, text: ch, line:, column: col)
          i += 1
          col += 1
        when '"'
          j = i + 1
          chars = +""
          while j < len
            if source[j] == "\\" && j + 1 < len
              case source[j + 1]
              when "n"  then chars << "\n"
              when "t"  then chars << "\t"
              when "r"  then chars << "\r"
              when '"'  then chars << '"'
              when "\\" then chars << "\\"
              else chars << source[j + 1]
              end
              j += 2
            elsif source[j] == '"'
              j += 1
              break
            else
              chars << source[j]
              j += 1
            end
          end
          tokens << Token.new(kind: "string", text: chars, line:, column: col)
          col += j - i
          i = j
        when ":", "-", "0".."9"
          # keyword, negative number, or number
          j = i
          j += 1 while j < len && source[j] != " " && source[j] != "\n" && source[j] != "(" && source[j] != ")" && source[j] != '"'
          text = source[i...j]
          if text.start_with?(":")
            tokens << Token.new(kind: "keyword", text: text[1..], line:, column: col)
          elsif text.match?(/\A-?[0-9]+\.[0-9]+([eE][+-]?[0-9]+)?\z/) || text.match?(/\A-?[0-9]+\.[0-9]*([eE][+-]?[0-9]+)?\z/)
            tokens << Token.new(kind: "float", text:, line:, column: col)
          elsif text.match?(/\A-?[0-9]+\z/)
            tokens << Token.new(kind: "integer", text:, line:, column: col)
          else
            tokens << Token.new(kind: "atom", text:, line:, column: col)
          end
          col += j - i
          i = j
        when /\s/
          if ch == "\n"
            line += 1
            col = 0
          end
          i += 1
          col += 1
        else
          # atom (identifier, true, false, nil)
          j = i
          j += 1 while j < len && source[j] != " " && source[j] != "\n" && source[j] != "(" && source[j] != ")" && source[j] != '"'
          text = source[i...j]
          tokens << Token.new(kind: "atom", text:, line:, column: col)
          col += j - i
          i = j
        end
      end
      tokens
    end

    # ── parser ────────────────────────────────────────────────────────

    def _parse_value(tokens, index = [0])
      token = tokens[index[0]]
      return nil unless token

      case token.kind
      when "("
        _parse_list(tokens, index)
      when "string"
        index[0] += 1
        token.text
      when "integer"
        index[0] += 1
        Integer(token.text)
      when "float"
        index[0] += 1
        Float(token.text)
      when "keyword"
        index[0] += 1
        token.text.gsub("-", "_").to_sym
      when "atom"
        index[0] += 1
        case token.text
        when "nil"  then nil
        when "true" then true
        when "false" then false
        else token.text
        end
      else
        raise "unexpected token: #{token.inspect}"
      end
    end

    def _parse_list(tokens, index)
      index[0] += 1 # skip "("
      if tokens[index[0]]&.kind == ")"
        index[0] += 1 # skip ")"
        return []
      end

      first = _parse_value(tokens, index)

      if first.is_a?(String) && first.match?(/\A[A-Z]/)
        _parse_typed_node(tokens, index, first, first)
      else
        # plain array — first element was the first value
        result = [first]
        while tokens[index[0]]&.kind != ")"
          result << _parse_value(tokens, index)
        end
        index[0] += 1 # skip ")"
        result
      end
    end

    def _parse_typed_node(tokens, index, first_token, first_str)
      type_name = _resolve_type_name(first_str)

      # Collect keyword-value pairs
      fields = {}
      while tokens[index[0]]&.kind == "keyword"
        kw = tokens[index[0]].text.gsub("-", "_").to_sym
        index[0] += 1 # skip keyword
        val = _parse_value(tokens, index)
        fields[kw] = val
      end

      index[0] += 1 # skip ")"

      if type_name.start_with?("Types::")
        _construct_types_object(type_name, fields)
      elsif type_name.start_with?("IR::")
        _construct_ir_object(type_name, fields)
      elsif type_name.start_with?("AST::")
        _construct_ast_object(type_name, fields)
      else
        _construct_generic(type_name, fields)
      end
    end

    # ── type name resolution ──────────────────────────────────────────

    def _resolve_type_name(str)
      # Already fully qualified ("Types::Primitive", "IR::Program")
      return str if str.include?("::")

      # Try common prefixes
      [
        "MilkTea::IR::#{str}",
        "MilkTea::AST::#{str}",
        "MilkTea::Types::#{str}",
      ].each do |candidate|
        begin
          return candidate if Object.const_get(candidate)
        rescue NameError
          nil
        end
      end
      str
    end

    # ── object constructors ───────────────────────────────────────────

    def _construct_ir_object(type_name, fields)
      name = type_name.split("::").last
      klass = MilkTea::IR.const_get(name)
      sym_fields = fields.transform_keys(&:to_sym)
      klass.new(**sym_fields)
    rescue NameError
      _construct_generic(type_name, fields)
    end

    def _construct_ast_object(type_name, fields)
      name = type_name.split("::").last
      klass = MilkTea::AST.const_get(name)
      sym_fields = fields.transform_keys(&:to_sym)
      klass.new(**sym_fields)
    rescue NameError
      _construct_generic(type_name, fields)
    end

    def _construct_types_object(type_name, fields)
      short = type_name.sub(/\ATypes::/, "")
      case short
      when "Primitive"
        Types::Registry.primitive(fields[:name])
      when "Null"
        Types::Null.new(fields[:target_type])
      when "Nullable"
        Types::Registry.nullable(fields[:base])
      when "Generic"
        Types::Registry.generic_instance(fields[:name], fields[:arguments])
      when "Span"
        Types::Registry.span(fields[:element_type])
      when "Task"
        rt = fields[:result_type] || Types::Registry.primitive("void")
        Types::Registry.task(rt)
      when "Function"
        Types::Registry.function(
          fields[:name],
          params: fields[:params] || [],
          return_type: fields[:return_type],
          receiver_type: fields[:receiver_type],
          receiver_editable: fields[:receiver_editable] || false,
          variadic: fields[:variadic] || false,
          external: fields[:external] || false,
        )
      when "Proc"
        Types::Registry.proc(params: fields[:params] || [], return_type: fields[:return_type])
      when "Tuple"
        Types::Registry.tuple(
          fields.fetch(:element_types, []),
          field_names: fields[:field_names],
        )
      when "Vector"
        Types::Registry.generic_instance(fields[:name], [Types::LiteralTypeArg.new(fields[:name].delete_prefix("vec").to_i)])
      when "Matrix"
        Types::Registry.generic_instance(fields[:name], [Types::LiteralTypeArg.new(fields[:name].delete_prefix("mat").to_i)])
      when "Quaternion"
        Types::Registry.generic_instance("quat", [])
      when "SoA"
        Types::Registry.soa(fields[:element_type], count: fields[:count])
      when "Simd"
        Types::Registry.simd(fields[:element_type], lane_count: fields[:lane_count])
      when "StringView"
        Types::Registry.string_view
      when "Parameter"
        Types::Registry.parameter(
          fields[:name],
          fields[:type],
          mutable: fields[:mutable] || false,
          passing_mode: fields[:passing_mode]&.to_sym || :plain,
          boundary_type: fields[:boundary_type],
        )
      when "LiteralTypeArg"
        Types::LiteralTypeArg.new(fields[:value])
      when "TypeVar"
        Types::TypeVar.new(fields[:name])
      when "LifetimeRef"
        Types::LifetimeRef.new(fields[:name])
      when "Dyn"
        interface_binding = MilkTea::SemanticAnalyzer::InterfaceBinding.new(
          name: fields[:interface_name],
          methods: [],
          ast: nil,
          module_name: nil,
        )
        Types::Registry.dyn(interface_binding, fields.fetch(:type_arguments, []))
      when "Struct", "StructInstance", "Union", "Variant", "VariantInstance",
           "VariantArmPayload", "Enum", "Flags", "Opaque", "Event", "Subscription", "Handle",
           "TypeType", "Error", "DynVtable", "ReflectionHandleType", "StructHandle",
           "FieldHandle", "CallableHandle", "AttributeHandle", "MemberHandle",
           "GenericStructDefinition", "GenericVariantDefinition"
        _construct_standalone_type(short, fields)
      else
        _construct_standalone_type(short, fields)
      end
    end

    def _construct_standalone_type(short, fields)
      case short
      when "TypeType"
        Types::TypeType.new
      when "Error"
        Types::Error.new
      when "Subscription"
        Types::Subscription.new
      when "Handle"
        Types::Handle.new
      when "Struct"
        Types::Struct.new(
          fields[:name],
          module_name: fields[:module_name],
          external: false,
          packed: false,
          alignment: nil,
          linkage_name: nil,
          lifetime_params: [],
        )
      when "Variant"
        Types::Variant.new(fields[:name], module_name: fields[:module_name])
      when "Union"
        Types::Union.new(
          fields[:name],
          module_name: fields[:module_name],
          external: false,
          packed: false,
          alignment: nil,
          linkage_name: nil,
          lifetime_params: [],
        )
      when "Opaque"
        Types::Opaque.new(fields[:name], module_name: fields[:module_name], external: false, linkage_name: nil)
      when "Enum"
        Types::Enum.new(fields[:name], module_name: fields[:module_name], external: false)
      when "Flags"
        Types::Flags.new(fields[:name], module_name: fields[:module_name], external: false)
      when "Event"
        Types::Event.new(
          fields[:name],
          capacity: fields[:capacity],
          payload_type: fields[:payload_type],
          module_name: nil,
          visibility: :private,
          owner_type_name: nil,
        )
      when "StringView"
        Types::Registry.string_view
      else
        _construct_types_fallback(short, fields)
      end
    end

    def _construct_types_fallback(short, fields)
      klass = begin
        Types.const_get(short)
      rescue NameError
        return fields
      end

      begin
        sym_fields = fields.transform_keys(&:to_sym)
        klass.new(**sym_fields)
      rescue StandardError
        begin
          args = fields.values
          klass.new(*args)
        rescue StandardError
          begin
            obj = klass.allocate
            fields.each do |k, v|
              ivar = "@#{k}"
              obj.instance_variable_set(ivar, v) if obj.instance_variable_defined?(ivar) || obj.respond_to?(:"#{k}=")
            rescue StandardError
              nil
            end
            begin
              obj.instance_variable_set(:@hash, obj.object_id.hash)
            rescue StandardError
              nil
            end
            obj
          rescue StandardError
            fields
          end
        end
      end
    end

    def _construct_generic(type_name, fields)
      klass = begin
        name_parts = type_name.split("::")
        if name_parts.length > 1
          top = Object.const_get(name_parts.first)
          rest = name_parts[1..].join("::")
          top.const_get(rest)
        else
          Object.const_get(type_name)
        end
      rescue NameError
        nil
      end

      if klass && klass.respond_to?(:members)
        sym_fields = fields.transform_keys(&:to_sym)
        klass.new(**sym_fields)
      else
        fields
      end
    end

    # ── helpers ───────────────────────────────────────────────────────

    def _unescape(str)
      str.gsub("\\n", "\n").gsub("\\t", "\t").gsub("\\r", "\r").gsub('\\"', '"').gsub("\\\\", "\\")
    end
  end
end
