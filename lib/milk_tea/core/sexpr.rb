# frozen_string_literal: true

module MilkTea
  module SExpr
    SYM_TAG  = ":$"
    HASH_TAG = ":{}"
    SYM_KEY  = "$sym"
    DATA_KEY = "$mt_type"
    TREF_KEY = "$type_ref"

    module_function

    def camel_to_snake(s)
      s.gsub(/([A-Z]+)([A-Z][a-z])/) { "#{$1}_#{$2}" }
       .gsub(/([a-z\d])([A-Z])/) { "#{$1}_#{$2}" }
       .downcase
    end

    def snake_to_camel(s)
      s.split("_").map(&:capitalize).join
    end

    def mt_type_to_tag(mt_type)
      return nil unless mt_type
      ns, name = if mt_type.include?(":")
                   mt_type.split(":", 2)
                 else
                   [nil, mt_type]
                 end
      prefix = case ns
               when "AST" then "a"
               when "IR"  then "i"
               else "d"
               end
      "#{prefix}:#{camel_to_snake(name)}"
    end

    def tag_to_mt_ns_name(tag)
      prefix, snake = tag.split(":", 2)
      return [nil, tag] unless snake
      ns = case prefix
           when "a" then "AST"
           when "i" then "IR"
           when "d" then nil
           else return [nil, tag]
           end
      [ns, snake_to_camel(snake)]
    end

    def tref_to_tag(ref_name)
      "t:#{camel_to_snake(ref_name)}"
    end

    def data_members(ns, name)
      mod = case ns
            when "AST" then MilkTea::AST rescue nil
            when "IR"  then MilkTea::IR rescue nil
            else MilkTea
            end
      return nil unless mod
      klass = mod.const_get(name) rescue nil
      return nil unless klass.is_a?(Class) && klass < Data
      klass.members.reject { |m| %i[node_ids node_path_ids].include?(m) }.map(&:to_s)
    end

    # ── serialization ─────────────────────────────────────────

    def to_sexpr(value)
      buf = +""
      emit(value, buf)
      buf
    end

    def emit(value, buf)
      case value
      when nil              then buf << "nil"
      when true             then buf << "true"
      when false            then buf << "false"
      when Integer          then buf << value.to_s
      when Float
        if value.nan?       then buf << "nan"
        elsif value.infinite? then buf << (value.positive? ? "+inf" : "-inf")
        else buf << value.to_s
        end
      when String           then emit_string(value, buf)
      when Array            then emit_array(value, buf)
      when Hash
        if value.key?(SYM_KEY)
          buf << SYM_TAG << value[SYM_KEY]
        elsif value.key?(TREF_KEY)
          emit_type_ref(value, buf)
        elsif value.key?(DATA_KEY)
          emit_data_node(value, buf)
        else
          emit_hash_map(value, buf)
        end
      when Symbol
        buf << ":$" << value.to_s
      else
        buf << "\"" << value.to_s << "\""
      end
    end

    def emit_string(s, buf)
      buf << '"'
      s.each_char do |ch|
        case ch
        when "\n" then buf << "\\n"
        when "\r" then buf << "\\r"
        when "\t" then buf << "\\t"
        when "\\" then buf << "\\\\"
        when '"'  then buf << "\\\""
        else buf << ch
        end
      end
      buf << '"'
    end

    NEEDS_QUOTED_KEY = /[\[\]()" :]/

    def emit_key(key, buf)
      if key.match?(NEEDS_QUOTED_KEY)
        emit_string(key, buf)
      else
        buf << ":" << key
      end
    end

    def emit_data_node(hash, buf)
      tag = mt_type_to_tag(hash[DATA_KEY]) || hash[DATA_KEY]
      buf << "(" << tag
      hash.each do |k, v|
        next if k == DATA_KEY
        buf << " "
        emit(v, buf)
      end
      buf << ")"
    end

    def emit_type_ref(hash, buf)
      tag = tref_to_tag(hash[TREF_KEY])
      buf << "(" << tag
      hash.each do |k, v|
        next if k == TREF_KEY
        buf << " "
        emit_key(k.to_s, buf)
        buf << " "
        emit(v, buf)
      end
      buf << ")"
    end

    def emit_hash_map(hash, buf)
      buf << "(" << HASH_TAG
      hash.each do |k, v|
        buf << " "
        emit_key(k.to_s, buf)
        buf << " "
        emit(v, buf)
      end
      buf << ")"
    end

    def emit_array(arr, buf)
      buf << "["
      arr.each_with_index do |item, i|
        buf << " " if i > 0
        emit(item, buf)
      end
      buf << "]"
    end

    # ── deserialization ───────────────────────────────────────

    def from_sexpr(text)
      @p = 0
      @s = text
      @n = text.length
      v = _parse_value
      _skip_ws
      raise "trailing content at #{@p}" unless _eof?
      v
    end

    def _parse_value
      _skip_ws
      return nil if _eof?
      case _peek
      when "(" then _parse_paren
      when "[" then _parse_array
      when '"' then _parse_string
      when ":" then _parse_sym_or_tag
      else _parse_atom
      end
    end

    def _peek  = @s[@p]
    def _advance = (@p += 1; @s[@p - 1])
    def _eof?   = @p >= @n

    def _skip_ws
      @p += 1 while @p < @n && " \n\r\t".include?(@s[@p])
    end

    def _stop_char?(ch)
      " ()[]\"\n\r\t".include?(ch)
    end

    def _parse_atom
      start = @p
      @p += 1 while @p < @n && !_stop_char?(@s[@p])
      word = @s[start...@p]
      case word
      when "nil"   then nil
      when "true"  then true
      when "false" then false
      when "nan"   then Float::NAN
      when "+inf"  then Float::INFINITY
      when "-inf"  then -Float::INFINITY
      else
        if word.include?(":") then word
        elsif word.match?(/\A-?\d/) then word.include?(".") || word.include?("e") || word.include?("E") ? word.to_f : word.to_i
        else word
        end
      end
    end

    def _parse_string
      _advance
      buf = +""
      while @p < @n
        ch = _advance
        break if ch == '"'
        if ch == "\\"
          ec = _advance
          case ec
          when "n" then buf << "\n"
          when "r" then buf << "\r"
          when "t" then buf << "\t"
          when "\\" then buf << "\\"
          when '"' then buf << '"'
          else buf << ec
          end
        else
          buf << ch
        end
      end
      buf
    end

    # Returns Hash for :$name, String (":tag") for other tags.
    def _parse_sym_or_tag
      _advance
      if _peek == "$"
        _advance
        name = _parse_bare_word
        { SYM_KEY => name }
      else
        tag = _parse_bare_word
        ":#{tag}"
      end
    end

    def _parse_bare_word
      start = @p
      @p += 1 while @p < @n && !_stop_char?(@s[@p])
      @s[start...@p]
    end

    def _parse_paren
      _advance
      _skip_ws
      first = _parse_value
      if first.is_a?(String) && first.include?(":")
        _parse_tagged_content(first)
      else
        items = [first]
        while @p < @n && _peek != ")"
          _skip_ws
          break if _peek == ")"
          items << _parse_value
        end
        raise "unterminated list" unless _peek == ")"
        _advance
        items
      end
    end

    def _parse_tagged_content(tag)
      if tag == SYM_TAG
        _skip_ws
        name = _parse_bare_word
        _skip_ws
        raise "unterminated symbol" unless _peek == ")"
        _advance
        { SYM_KEY => name }
      elsif tag == HASH_TAG || tag.start_with?("t:")
        result = _parse_kv_pairs
        if tag.start_with?("t:")
          ref_name = tag.delete_prefix("t:")
          tref_name = snake_to_camel(ref_name)
          full = { TREF_KEY => tref_name }
          full.merge!(result)
          full
        else
          result
        end
      elsif tag.start_with?("a:") || tag.start_with?("i:") || tag.start_with?("d:")
        children = []
        while @p < @n && _peek != ")"
          _skip_ws
          break if _peek == ")"
          children << _parse_value
        end
        raise "unterminated tagged list: #{tag}" unless _peek == ")"
        _advance
        ns, name = tag_to_mt_ns_name(tag)
        mt_type = ns ? "#{ns}:#{name}" : name
        members = data_members(ns, name)
        raise "unknown Data node: #{mt_type}" unless members
        raise "member count mismatch for #{mt_type}: expected #{members.length}, got #{children.length}" unless children.length == members.length
        result = { DATA_KEY => mt_type }
        members.zip(children).each { |m, v| result[m] = v }
        result
      else
        children = []
        while @p < @n && _peek != ")"
          _skip_ws
          break if _peek == ")"
          children << _parse_value
        end
        raise "unterminated tagged list: #{tag}" unless _peek == ")"
        _advance
        [tag] + children
      end
    end

    def _parse_kv_pairs
      result = {}
      _skip_ws
      while @p < @n && _peek != ")"
        if _peek == ":"
          _advance
          key = _parse_bare_word
        elsif _peek == '"'
          key = _parse_string
        else
          raise "expected :key or \"key\" in hash map at #{@p}, got #{_peek.inspect}"
        end
        _skip_ws
        val = _parse_value
        result[key] = val
        _skip_ws
      end
      raise "unterminated hash map" unless _peek == ")"
      _advance
      result
    end

    def _parse_array
      _advance
      items = []
      _skip_ws
      while @p < @n && _peek != "]"
        items << _parse_value
        _skip_ws
      end
      raise "unterminated array" unless _peek == "]"
      _advance
      items
    end
  end
end
