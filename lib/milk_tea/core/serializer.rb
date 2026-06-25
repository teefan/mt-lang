# frozen_string_literal: true

require "json"

module MilkTea
  module Serializer
    SYM_KEY = "$sym"
    DATA_KEY = "$mt_type"
    TREF_KEY = "$type_ref"

    module_function

    def token_to_hash(token)
      result = {
        "type" => token.type.to_s, "lexeme" => token.lexeme,
        "literal" => serialize_literal(token.literal),
        "line" => token.line, "column" => token.column,
        "start_offset" => token.start_offset, "end_offset" => token.end_offset,
      }
      unless token.leading_trivia.empty?
        result["leading_trivia"] = token.leading_trivia.map { |t| trivia_to_hash(t) }
      end
      unless token.trailing_trivia.empty?
        result["trailing_trivia"] = token.trailing_trivia.map { |t| trivia_to_hash(t) }
      end
      result
    end

    def tokens_to_json(tokens)
      JSON.generate(tokens.map { |t| token_to_hash(t) })
    end

    def tokens_from_json(json_string)
      JSON.parse(json_string).map { |h| hash_to_token(h) }
    end

    def hash_to_token(h)
      Token.new(type: h["type"].to_sym, lexeme: h["lexeme"],
        literal: deserialize_literal(h["literal"]), line: h["line"], column: h["column"],
        start_offset: h["start_offset"], end_offset: h["end_offset"],
        leading_trivia: (h["leading_trivia"] || []).map { |t| hash_to_trivia(t) },
        trailing_trivia: (h["trailing_trivia"] || []).map { |t| hash_to_trivia(t) })
    end

    def trivia_to_hash(t)
      { "kind" => t.kind.to_s, "text" => t.text, "line" => t.line,
        "column" => t.column, "start_offset" => t.start_offset, "end_offset" => t.end_offset }
    end

    def hash_to_trivia(h)
      TriviaToken.new(kind: h["kind"].to_sym, text: h["text"], line: h["line"],
        column: h["column"], start_offset: h["start_offset"], end_offset: h["end_offset"])
    end

    def serialize_literal(value)
      case value
      when nil, Integer, Float, String, TrueClass, FalseClass then value
      when Array then value.map { |v| v.is_a?(Hash) ? v : v }
      else value
      end
    end

    def deserialize_literal(value)
      case value
      when nil, Integer, Float, String, TrueClass, FalseClass then value
      when Array then value.map { |v| deserialize_format_part(v) }
      else value
      end
    end

    def deserialize_format_part(v)
      case v
      when Hash
        h = v.transform_keys(&:to_sym)
        h[:kind] = h[:kind].to_sym if h.key?(:kind) && h[:kind].is_a?(String)
        h
      when Array then v.map { |e| deserialize_format_part(e) }
      else v
      end
    end

    # ── Core serialization ──────────────────────────────

    def serialize_ast(node)
      return nil if node.nil?
      case node
      when Types::Base, Types::Parameter, Types::LiteralTypeArg
        visited = (Thread.current[:mt_ser_visited] ||= {})
        vid = node.__id__
        if visited[vid]
          return serialize_type_id_ref(node)
        end
        visited[vid] = true
        result = serialize_type_ref(node)
        visited.delete(vid)
        result
      when Data then serialize_data_node(node)
      when Array then node.map { |e| serialize_ast(e) }
      when Hash
        result = {}
        node.each { |k, v| result[k.to_s] = serialize_ast(v) }
        result
      when Symbol then { SYM_KEY => node.to_s }
      when String, Integer, Float, TrueClass, FalseClass then node
      when NilClass then nil
      else node.to_s
      end
    end

    def serialize_data_node(node)
      kind = node.class.name.sub(/\AMilkTea::(AST|IR)::/, "")
      result = { DATA_KEY => kind }
      node.class.members.each do |member|
        next if member == :node_ids
        result[member.to_s] = serialize_ast(node.send(member))
      end
      result
    end

    def deserialize_ast(value)
      case value
      when nil then nil
      when Array then value.map { |e| deserialize_ast(e) }
      when Hash
        if value.key?(SYM_KEY) then value[SYM_KEY].to_sym
        elsif value.key?(TREF_KEY)
          if value["_id_ref"] then resolve_cached_type(value)
          else
            type = deserialize_type_ref(value)
            cache_full_type(value, type)
            type
          end
        elsif value.key?(DATA_KEY) then deserialize_data_node(value)
        else
          result = {}
          value.each { |k, v| result[k] = deserialize_ast(v) }
          result
        end
      when String, Integer, Float, TrueClass, FalseClass then value
      else value
      end
    end

    def deserialize_data_node(hash)
      kind = hash[DATA_KEY]
      klass = data_class_for(kind) || raise("unknown Data node kind: #{kind}")
      kwargs = {}
      klass.members.each do |member|
        key = member.to_s
        kwargs[member] = hash.key?(key) ? deserialize_ast(hash[key]) : nil
      end
      klass.new(**kwargs)
    rescue ArgumentError => e
      raise "failed to construct #{kind}: #{e.message}"
    end

    def self.data_class_registry
      @data_class_registry ||= begin
        registry = {}
        [MilkTea::AST, MilkTea::IR].each do |mod|
          next unless defined?(mod)
          mod.constants.each do |const|
            klass = mod.const_get(const)
            next unless klass.is_a?(Class) && klass < Data
            name = klass.name.sub(/\AMilkTea::(AST|IR)::/, "")
            registry[name] = klass
          end
        end
        registry
      end
    end

    def self.data_class_for(name) = data_class_registry[name]

    def self.with_type_identity_only
      prev = Thread.current[:mt_ser_id_only_types]
      Thread.current[:mt_ser_id_only_types] = true
      yield
    ensure
      Thread.current[:mt_ser_id_only_types] = prev
    end

    def serialize_type_id_ref(type)
      result = { TREF_KEY => ref_type_name(type), "_id_ref" => true }
      result["name"] = type.name if type.respond_to?(:name)
      result["module_name"] = type.module_name if type.respond_to?(:module_name) && type.module_name
      result
    end

    def serialize_type_ref(type)
      result = { TREF_KEY => ref_type_name(type) }
      send(:"serialize_tref_#{ref_method_name(type)}", type, result)
      result
    end

    def deserialize_type_ref(hash)
      send(:"deserialize_tref_#{ref_method_name_from(hash[TREF_KEY])}", hash)
    end

    def ref_type_name(type)        = type.class.name.sub(/\AMilkTea::Types::/, "")
    def ref_method_name(type)      = _ref_name(type.class.name.sub(/\AMilkTea::Types::/, ""))
    def ref_method_name_from(name) = _ref_name(name)
    def _ref_name(s) = s.gsub("::", "_").gsub(/([A-Z]+)/) { "_#{$1.downcase}" }.delete_prefix("_").squeeze("_")

    def normalize_field_keys(hash)
      return {} if hash.nil? || hash.empty?
      result = {}
      hash.each { |k, v| result[k.to_s] = v }
      result
    end

    def cache_full_type(hash, type)
      cache = (Thread.current[:mt_deser_type_cache] ||= {})
      key = [hash[TREF_KEY], hash["name"], hash["module_name"]]
      cache[key] ||= type
    end

    def resolve_cached_type(hash)
      cache = Thread.current[:mt_deser_type_cache] || {}
      key = [hash[TREF_KEY], hash["name"], hash["module_name"]]
      cache[key] || deserialize_tref_id_ref(hash)
    end

    def deserialize_tref_id_ref(hash)
      tn, nm, mod = hash[TREF_KEY], hash["name"] || "", hash["module_name"]
      case tn
      when "Primitive" then Types::Registry.primitive(nm)
      when "Struct", "StructInstance", "Union", "VariantArmPayload" then Types::Struct.new(nm, module_name: mod)
      when "Variant", "VariantInstance" then Types::Variant.new(nm, module_name: mod)
      when "Enum" then Types::Enum.new(nm, module_name: mod)
      when "Flags" then Types::Flags.new(nm, module_name: mod)
      when "Opaque" then Types::Opaque.new(nm, module_name: mod)
      when "Span" then Types::Span.new(Types::Primitive.new("void"))
      when "StringView" then Types::Registry.string_view
      else Types::Error.new
      end
    end

    # ── All type serializers ────────────────────────────
    include MilkTea::SerializerAddons

    module_function

    SerializerAddons.instance_methods.each do |m|
      module_function(m)
    end

    # ── Convenience ─────────────────────────────────────

    def ir_to_json(ir_program)
      Thread.current[:mt_ser_visited] = nil
      JSON.generate(serialize_ast(ir_program))
    ensure
      Thread.current[:mt_ser_visited] = nil
    end

    def ir_from_json(json_string)
      Thread.current[:mt_deser_type_cache] = nil
      deserialize_ast(JSON.parse(json_string))
    ensure
      Thread.current[:mt_deser_type_cache] = nil
    end

    def ast_to_json(node)
      Thread.current[:mt_ser_visited] = nil
      JSON.generate(serialize_ast(node))
    ensure
      Thread.current[:mt_ser_visited] = nil
    end

    def ast_from_json(json_string)
      Thread.current[:mt_deser_type_cache] = nil
      deserialize_ast(JSON.parse(json_string))
    ensure
      Thread.current[:mt_deser_type_cache] = nil
    end

    # Identity-only mode: for expression types, skip fields/arms/events/nested_types
    def self.ast_from_json_with_ids(json_string)
      ast = ast_from_json(json_string)
      AST.assign_node_ids(ast) if ast
      ast
    end
  end
end
