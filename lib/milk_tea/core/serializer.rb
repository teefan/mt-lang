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
      kind = node.class.name.sub(/\AMilkTea::/, "") unless kind.length < node.class.name.length
      full = node.class.name
      ns = if full.include?("::AST::") then "AST"
            elsif full.include?("::IR::") then "IR"
            else ""
            end
      kind = "#{ns}:#{kind}" unless ns.empty?
      result = { DATA_KEY => kind }
      node.class.members.each do |member|
        next if %i[node_ids node_path_ids].include?(member)
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
      ns_prefix, kind = if kind.include?(":")
                          kind.split(":", 2)
                        else
                          [nil, kind]
                        end
      klass = data_class_for(kind, ns_prefix) || raise("unknown Data node kind: #{hash[DATA_KEY]}")
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
        [
          ["AST", MilkTea::AST],
          ["IR", MilkTea::IR],
          [nil, MilkTea],
        ].each do |ns_prefix, mod|
          next unless defined?(mod)
          mod.constants.each do |const|
            klass = mod.const_get(const)
            next unless klass.is_a?(Class) && klass < Data
            name = klass.name.sub(/\AMilkTea::(AST|IR)::/, "")
            name = klass.name.sub(/\AMilkTea::/, "") unless name.length < klass.name.length
            key = ns_prefix ? "#{ns_prefix}:#{name}" : name
            registry[key] = klass
          end
        end
        registry
      end
    end

    def self.data_class_for(name, ns_prefix = nil)
      if ns_prefix
        data_class_registry["#{ns_prefix}:#{name}"]
      else
        data_class_registry[name] || data_class_registry["AST:#{name}"] || data_class_registry["IR:#{name}"]
      end
    end

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

    # ── Analysis ─────────────────────────────────────────

    A_KEY = "$mt_analysis"

    def analysis_to_json(analysis)
      Thread.current[:mt_ser_visited] = nil
      ast = analysis.ast
      path_ids = ast.node_path_ids || {}
      rev = {}
      path_ids.each { |path, id| rev[id] = path }

      result = {
        A_KEY => true,
        "ast" => serialize_ast(ast),
        "module_name" => analysis.module_name,
        "module_kind" => analysis.module_kind.to_s,
        "directives" => serialize_ast(analysis.directives),
        "imports" => analysis.imports.transform_values { |m| m.name },
        "types" => serialize_ast(analysis.types),
        "interfaces" => (analysis.interfaces || {}).transform_values { |ib| interface_binding_to_hash(ib) },
        "attributes" => serialize_ast(analysis.attributes),
        "attribute_applications" => serialize_attr_apps(analysis.attribute_applications, path_ids),
        "values" => serialize_ast(analysis.values),
        "functions" => serialize_functions(analysis.functions, analysis.ast),
        "methods" => serialize_methods(analysis.methods),
        "implemented_interfaces" => serialize_ast(analysis.implemented_interfaces),
        "r_expr_types" => serialize_path_keyed_map(analysis.resolved_expr_types, rev),
        "r_call_kinds" => serialize_path_keyed_map(analysis.resolved_call_kinds, rev),
        "r_const_values" => serialize_path_keyed_map(analysis.const_values, rev),
        "uses_parallel_for" => analysis.uses_parallel_for,
      }
      JSON.generate(result)
    ensure
      Thread.current[:mt_ser_visited] = nil
    end

    def analysis_from_json(json_string)
      Thread.current[:mt_deser_type_cache] = nil
      raw = JSON.parse(json_string)
      ast = deserialize_ast(raw["ast"])
      ast = AST.assign_node_ids(ast)
      path_ids = ast.node_path_ids || {}

      types = deserialize_ast(raw["types"]) || {}
      imports = (raw["imports"] || {}).transform_values { |n| ModuleBindingStub.new(n) }
      interfaces = (raw["interfaces"] || {}).transform_values { |ib| unstub_interface_binding(ib) }
      attributes = deserialize_ast(raw["attributes"]) || {}
      attr_apps = deserialize_attr_apps(raw["attribute_applications"] || {}, path_ids, attributes)
      values = deserialize_ast(raw["values"]) || {}
      functions = deserialize_functions(raw["functions"] || {}, ast)
      methods = deserialize_methods(raw["methods"] || {})

      SemanticAnalyzer::Analysis.new(
        ast:,
        module_name: raw["module_name"],
        module_kind: raw["module_kind"].to_sym,
        directives: deserialize_ast(raw["directives"]) || [],
        imports:,
        types:,
        interfaces:,
        attributes:,
        attribute_applications: attr_apps,
        values:,
        functions:,
        methods:,
        implemented_interfaces: deserialize_ast(raw["implemented_interfaces"]) || {},
        local_completion_frames: [],
        binding_resolution: SemanticAnalyzer::BindingResolution.new({}, {}, {}, {}, {}, {}),
        callable_value_identifier_sites: {},
        callable_value_member_access_sites: {},
        required_unsafe_lines: [],
        uses_parallel_for: raw["uses_parallel_for"] || false,
        resolved_expr_types: deserialize_path_keyed_map(raw["r_expr_types"] || {}, path_ids),
        resolved_call_kinds: deserialize_path_keyed_map(raw["r_call_kinds"] || {}, path_ids).transform_values(&:to_sym),
        const_values: deserialize_path_keyed_map(raw["r_const_values"] || {}, path_ids),
      )
    ensure
      Thread.current[:mt_deser_type_cache] = nil
    end

    def serialize_path_keyed_map(map, id_to_path)
      result = {}
      map.each { |id, val| result[id_to_path[id] || id.to_s] = serialize_ast(val) }
      result
    end

    def deserialize_path_keyed_map(raw_map, path_ids)
      result = {}
      path_to_id = {}
      path_ids.each { |path, id| path_to_id[path] = id }
      raw_map.each do |path, val|
        id = path_to_id[path] || path.to_i
        result[id] = deserialize_ast(val)
      end
      result
    end

    def serialize_attr_apps(attr_apps, path_ids)
      return {} if attr_apps.nil?
      result = {}
      rev = {}
      path_ids.each { |path, id| rev[id] = path }
      attr_apps.each do |obj_id, apps|
        path = rev[obj_id] || obj_id.to_s
        result[path] = apps.map { |app| { "binding" => serialize_ast(app.binding), "argument_values" => app.argument_values } }
      end
      result
    end

    def deserialize_attr_apps(raw, path_ids, attributes)
      return {} if raw.nil?
      result = {}
      path_to_id = {}
      path_ids.each { |path, id| path_to_id[path] = id }
      raw.each do |path, apps|
        id = path_to_id[path] || path.to_i
        result[id] = apps.map do |app_data|
          binding = deserialize_ast(app_data["binding"])
          binding ||= attributes[app_data["binding"]["name"]] if app_data["binding"].is_a?(Hash)
          SemanticAnalyzer::ResolvedAttributeApplication.new(binding:, argument_values: app_data["argument_values"] || {})
        end
      end
      result
    end

    def strip_function_binding(fb)
      FunctionBinding.new(
        name: fb.name, type: fb.type, body_params: fb.body_params,
        body_return_type: fb.body_return_type, ast: fb.ast,
        external: fb.external, async: fb.async, type_params: fb.type_params,
        type_param_constraints: fb.type_param_constraints,
        instances: fb.instances, type_arguments: fb.type_arguments,
        owner: nil, specialization_owner: nil, type_substitutions: fb.type_substitutions,
        declared_receiver_type: fb.declared_receiver_type,
      )
    end

    def unstub_function_binding(fb)
      return fb unless fb.is_a?(Hash)
      FunctionBinding.new(
        name: fb["name"], type: deserialize_ast(fb["type"]),
        body_params: (fb["body_params"] || []).map { |p| deserialize_ast(p) },
        body_return_type: deserialize_ast(fb["body_return_type"]),
        ast: deserialize_ast(fb["ast"]),
        external: fb["external"], async: fb["async"],
        type_params: (fb["type_params"] || []).map { |p| deserialize_ast(p) || p },
        type_param_constraints: fb["type_param_constraints"] || {},
        instances: fb["instances"] || {},
        type_arguments: fb["type_arguments"] || [],
        owner: nil, specialization_owner: nil,
        type_substitutions: fb["type_substitutions"] || {},
        declared_receiver_type: deserialize_ast(fb["declared_receiver_type"]),
      )
    end

    def interface_binding_to_hash(ib)
      {
        "name" => ib.name,
        "methods" => ib.methods.transform_values { |m|
          { "name" => m.name, "params" => serialize_ast(m.params),
            "return_type" => serialize_ast(m.return_type), "kind" => m.kind.to_s,
            "async" => m.async }
        },
        "module_name" => ib.module_name,
        "type_arguments" => ib.respond_to?(:type_arguments) ? ib.type_arguments&.map { |a| serialize_ast(a) } : nil,
      }
    end

    def unstub_interface_binding(hash)
      methods = (hash["methods"] || {}).transform_values do |m|
        SemanticAnalyzer::InterfaceMethodBinding.new(
          name: m["name"], params: (m["params"] || []).map { |p| deserialize_ast(p) },
          return_type: deserialize_ast(m["return_type"]), kind: m["kind"].to_sym,
          async: m["async"], ast: nil,
        )
      end
      SemanticAnalyzer::InterfaceBinding.new(
        name: hash["name"], methods:, ast: nil, module_name: hash["module_name"],
        type_arguments: hash["type_arguments"] ? hash["type_arguments"].map { |a| deserialize_ast(a) || a } : nil,
      )
    end

    def serialize_functions(funcs, ast)
      result = {}
      funcs.each do |name, fb|
        ast_path = find_ast_path_for(fb.ast, ast)
        result[name] = {
          "name" => fb.name, "type" => serialize_ast(fb.type),
          "body_params" => serialize_ast(fb.body_params),
          "body_return_type" => serialize_ast(fb.body_return_type),
          "ast" => serialize_ast(fb.ast),
          "external" => fb.external, "async" => fb.async,
          "type_params" => serialize_ast(fb.type_params),
          "type_param_constraints" => fb.type_param_constraints,
          "instances" => fb.instances,
          "type_arguments" => serialize_ast(fb.type_arguments),
          "type_substitutions" => fb.type_substitutions,
          "declared_receiver_type" => serialize_ast(fb.declared_receiver_type),
          "ast_path" => ast_path,
        }
      end
      result
    end

    def find_ast_path_for(node, root, path = "SourceFile")
      return nil unless node.is_a?(::Data) && root.is_a?(::Data)
      return path if node.equal?(root)

      root.class.members.each do |field_name|
        next if %i[module_name module_kind node_ids node_path_ids].include?(field_name)
        value = root.public_send(field_name)
        next unless value

        child_path = "#{path}.#{field_name}"
        case value
        when ::Data
          result = find_ast_path_for(node, value, child_path)
          return result if result
        when Array
          value.each_with_index do |v, i|
            next unless v.is_a?(::Data)
            result = find_ast_path_for(node, v, "#{child_path}[#{i}]")
            return result if result
          end
        end
      end
      nil
    end

    def serialize_methods(methods)
      result = {}
      methods.each do |receiver_type, method_map|
        key = type_to_string_key(receiver_type)
        result[key] = serialize_ast(method_map.transform_values { |fb| strip_function_binding(fb) })
      end
      result
    end

    def deserialize_functions(raw, ast)
      result = {}
      raw.each do |name, fb_data|
        fb_ast = if fb_data["ast_path"] && !fb_data["ast_path"].empty?
                    resolve_ast_node_by_path(fb_data["ast_path"], ast)
                  else
                    deserialize_ast(fb_data["ast"])
                  end
        result[name] = FunctionBinding.new(
          name: fb_data["name"] || name,
          type: deserialize_ast(fb_data["type"]),
          body_params: deserialize_ast(fb_data["body_params"]) || [],
          body_return_type: deserialize_ast(fb_data["body_return_type"]),
          ast: fb_ast,
          external: fb_data["external"] || false,
          async: fb_data["async"] || false,
          type_params: deserialize_ast(fb_data["type_params"]) || [],
          type_param_constraints: fb_data["type_param_constraints"] || {},
          instances: fb_data["instances"] || {},
          type_arguments: deserialize_ast(fb_data["type_arguments"]) || [],
          owner: nil, specialization_owner: nil,
          type_substitutions: fb_data["type_substitutions"] || {},
          declared_receiver_type: deserialize_ast(fb_data["declared_receiver_type"]),
        )
      end
      result
    end

    def resolve_ast_node_by_path(path, root)
      return root if path.nil? || path.empty?
      parts = path.split(".")
      current = root
      parts.each do |part|
        next if part == "SourceFile"
        field_name, index_str = if part.include?("[")
                                   part.split("[", 2)
                                 else
                                   [part, nil]
                                 end
        index = index_str&.delete("]")&.to_i
        field_name = field_name.to_sym
        return nil unless current.respond_to?(field_name)
        child = current.public_send(field_name)
        return nil unless child
        child = child[index] if index && child.is_a?(Array)
        return nil unless child
        current = child
      end
      current
    end

    def deserialize_methods(raw)
      result = {}
      raw.each do |key, method_map|
        receiver_type = type_from_string_key(key)
        result[receiver_type] = (deserialize_ast(method_map) || {}).transform_values { |fb| unstub_function_binding(fb) }
      end
      result
    end

    def type_to_string_key(type)
      Serializer.ref_type_name(type) + ":" + (type.respond_to?(:name) ? type.name.to_s : "")
    end

    def type_from_string_key(key)
      tname, name = key.split(":", 2)
      case tname
      when "Primitive" then Types::Registry.primitive(name)
      when "Struct", "StructInstance" then Types::Struct.new(name)
      when "Nullable" then Types::Registry.nullable(Types::Primitive.new("void"))
      else Types::Error.new
      end
    end

    ModuleBindingStub = Data.define(:name) do
      def types = {}
      def type_declarations = {}
      def interfaces = {}
      def attributes = {}
      def attribute_applications = {}
      def values = {}
      def functions = {}
      def methods = {}
      def implemented_interfaces = {}
      def imports = {}
      def private_types = {}
      def private_interfaces = {}
      def private_attributes = {}
      def private_values = {}
      def private_functions = {}
      def private_methods = {}
      def private_implemented_interfaces = {}
      def private_type?(n) = false
      def private_interface?(n) = false
      def private_attribute?(n) = false
      def private_value?(n) = false
      def private_function?(n) = false
      def private_method?(t, n) = false
    end

    end
  end
