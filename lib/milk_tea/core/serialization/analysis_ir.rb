# frozen_string_literal: true

module MilkTea
  module Serialization
    module AnalysisIR
      module_function

      def serialize(analysis)
        {
          _t: "Analysis",
          ast: ASTIR.serialize(analysis.ast),
          module_name: analysis.module_name,
          module_kind: analysis.module_kind.to_s,
          directives: serialize_directives(analysis.directives),
          imports: serialize_hash(analysis.imports),
          types: serialize_hash(analysis.types),
          interfaces: serialize_hash(analysis.interfaces),
          attributes: serialize_hash(analysis.attributes),
          attribute_applications: serialize_hash(analysis.attribute_applications),
          values: serialize_hash(analysis.values),
          functions: serialize_hash(analysis.functions),
          methods: serialize_methods(analysis.methods),
          implemented_interfaces: serialize_hash(analysis.implemented_interfaces),
          resolved_expr_types: serialize_resolved_types(analysis.resolved_expr_types),
          uses_parallel_for: analysis.uses_parallel_for,
        }.compact
      end

      def deserialize(h)
        Sema::Analysis.new(
          ast: ASTIR.deserialize(h["ast"]),
          module_name: h["module_name"],
          module_kind: h["module_kind"].to_sym,
          directives: h["directives"] || [],
          imports: deserialize_hash(h["imports"] || {}),
          types: deserialize_hash_types(h["types"] || {}),
          interfaces: deserialize_hash(h["interfaces"] || {}),
          attributes: deserialize_hash(h["attributes"] || {}),
          attribute_applications: deserialize_hash(h["attribute_applications"] || {}),
          values: deserialize_hash(h["values"] || {}),
          functions: deserialize_hash(h["functions"] || {}),
          methods: deserialize_methods(h["methods"] || {}),
          implemented_interfaces: deserialize_hash(h["implemented_interfaces"] || {}),
          local_completion_frames: [],
          binding_resolution: BindingResolution.new(value_resolution: {}, recheck_dependencies: Set.new),
          callable_value_identifier_sites: {},
          callable_value_member_access_sites: {},
          required_unsafe_lines: [],
          uses_parallel_for: h["uses_parallel_for"] || false,
          resolved_expr_types: deserialize_resolved_types(h["resolved_expr_types"] || {}),
        )
      end

      def serialize_hash(hash)
        return {} if hash.nil? || hash.empty?

        hash.transform_keys(&:to_s).transform_values { |v| serialize_value(v) }
      end

      def deserialize_hash(hash)
        return {} if hash.nil? || hash.empty?

        hash.transform_values { |v| deserialize_value(v) }
      end

      def deserialize_hash_types(hash)
        return {} if hash.nil? || hash.empty?

        hash.transform_values { |v| deserialize_type(v) }
      end

      def serialize_methods(methods)
        return {} if methods.nil? || methods.empty?

        result = {}
        methods.each do |type, name_map|
          type_key = type.is_a?(Types::Base) ? TypesIR.serialize(type) : type.to_s
          result[JSON.generate(type_key)] = serialize_hash(name_map)
        end
        result
      end

      def deserialize_methods(hash)
        return {} if hash.nil? || hash.empty?

        result = {}
        hash.each do |type_json, name_map|
          type = deserialize_type(JSON.parse(type_json))
          result[type] = deserialize_hash(name_map)
        end
        result
      end

      def serialize_resolved_types(map)
        return {} if map.nil? || map.empty?

        result = {}
        map.each do |node_id, type|
          result[node_id.to_s] = TypesIR.serialize(type)
        end
        result
      end

      def deserialize_resolved_types(map)
        return {} if map.nil? || map.empty?

        result = {}
        map.each do |node_id_str, type_data|
          result[node_id_str.to_i] = TypesIR.deserialize(type_data)
        end
        result
      end

      def serialize_directives(directives)
        return [] unless directives

        directives.map { |d| ASTIR.serialize(d) }
      end

      def serialize_value(value)
        return nil if value.nil?

        if value.is_a?(Types::Base)
          TypesIR.serialize(value)
        elsif value.is_a?(::Data)
          ASTIR.serialize(value)
        elsif value.is_a?(Hash)
          serialize_hash(value)
        elsif value.is_a?(Set)
          value.to_a.map { |v| serialize_value(v) }
        elsif value.is_a?(Array)
          value.map { |v| serialize_value(v) }
        elsif value.is_a?(TrueClass) || value.is_a?(FalseClass)
          { _t: "bool", v: value }
        elsif value.is_a?(String)
          value
        elsif value.is_a?(Symbol)
          { _t: "sym", v: value.to_s }
        elsif value.is_a?(Numeric)
          value
        else
          value.respond_to?(:to_s) ? value.to_s : value.inspect
        end
      end

      def deserialize_value(value)
        return nil if value.nil?

        case value
        when Hash
          if value["_t"]&.start_with?("AST::")
            ASTIR.deserialize(value)
          elsif value["_t"] == "bool"
            value["v"]
          elsif value["_t"] == "sym"
            value["v"].to_sym
          else
            TypesIR.deserialize(value)
          end
        when Array
          value.map { |v| deserialize_value(v) }
        else
          value
        end
      end

      def deserialize_type(value)
        return nil if value.nil?

        if value.is_a?(Hash)
          TypesIR.deserialize(value)
        else
          value
        end
      end
    end
  end
end
