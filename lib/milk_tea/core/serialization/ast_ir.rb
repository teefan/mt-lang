# frozen_string_literal: true

module MilkTea
  module Serialization
    module ASTIR
      module_function

      AST_TYPE_PREFIX = "AST::"

      TYPES_BY_NAME = ::MilkTea::AST.constants.each_with_object({}) do |name, h|
        const = ::MilkTea::AST.const_get(name)
        h["#{AST_TYPE_PREFIX}#{name}"] = const if const.is_a?(Class) && const < ::Data
      end.freeze

      SERIALIZE_AS_VALUE = %w[Integer Float String TrueClass FalseClass NilClass Symbol].freeze

      def serialize(node)
        return serialize_primitive(node) unless node.is_a?(::Data)

        fields = node.class.members.each_with_object({}) do |field_name, h|
          value = node.public_send(field_name)
          h[field_name.to_s] = serialize_value(value)
        end

        fields["_t"] = type_name(node.class)
        fields
      end

      def deserialize(h)
        return h unless h.is_a?(Hash) && h["_t"]

        type_name = h["_t"]
        klass = TYPES_BY_NAME[type_name]
        raise ArgumentError, "unknown AST type: #{type_name}" unless klass

        kwargs = {}
        klass.members.each do |field_name|
          key = field_name.to_s
          next unless h.key?(key)

          kwargs[field_name] = deserialize_value(h[key])
        end

        klass.new(**kwargs)
      end

      def serialize_primitive(value)
        return nil if value.nil?

        case value
        when Integer then { _t: "int", v: value }
        when Float
          v = if value.nan? then "nan"
          elsif value.infinite? then value.positive? ? "inf" : "-inf"
          else
            value
          end
          { _t: "float", v: }
        when String then { _t: "str", v: value }
        when TrueClass, FalseClass then { _t: "bool", v: value }
        when Symbol then { _t: "sym", v: value.to_s }
        else value
        end
      end

      def deserialize_primitive(h)
        return nil if h.nil?
        return h unless h.is_a?(Hash) && h["_t"]

        case h["_t"]
        when "int" then h["v"]
        when "float"
          case h["v"]
          when "nan" then Float::NAN
          when "inf" then Float::INFINITY
          when "-inf" then -Float::INFINITY
          else h["v"]
          end
        when "str" then h["v"]
        when "bool" then h["v"]
        when "sym" then h["v"].to_sym
        else h["v"]
        end
      end

      def serialize_value(value)
        case value
        when nil then nil
        when ::Data then serialize(value)
        when Array then value.map { |v| serialize_value(v) }
        when Hash
          value.transform_values { |v| serialize_value(v) }
            .transform_keys(&:to_s)
            .merge("_t" => "Hash")
        when Float
          if value.nan?
            { _t: "float", v: "nan" }
          elsif value.infinite?
            { _t: "float", v: value.positive? ? "inf" : "-inf" }
          else
            value
          end
        else value
        end
      end

      def deserialize_value(value)
        return nil if value.nil?

        case value
        when Hash
          if value["_t"] == "Hash"
            result = {}
            value.each do |k, v|
              next if k == "_t"
              result[k] = deserialize_value(v)
            end
            result
          elsif value["_t"] == "float"
            case value["v"]
            when "nan" then Float::NAN
            when "inf" then Float::INFINITY
            when "-inf" then -Float::INFINITY
            else value["v"]
            end
          elsif value["_t"]&.start_with?(AST_TYPE_PREFIX)
            deserialize(value)
          else
            value.transform_values { |v| deserialize_value(v) } rescue value
          end
        when Array
          value.map { |v| deserialize_value(v) }
        else
          value
        end
      end

      def type_name(klass)
        name = klass.name
        return name.sub("MilkTea::", "") if name

        klass.ancestors.each do |anc|
          next unless anc.is_a?(Class) && anc < ::Data
          n = anc.name
          return n.sub("MilkTea::", "") if n&.start_with?("MilkTea::AST::")
        end

        raise ArgumentError, "cannot determine type name for #{klass}"
      end
    end
  end
end
