# frozen_string_literal: true

module MilkTea
  module Serialization
    module ProgramIR
      module_function

      IR_TYPE_REGISTRY = begin
        mod = ::MilkTea::IR
        h = {}
        mod.constants.each do |name|
          const = mod.const_get(name)
          h[name.to_s] = const if const.is_a?(Class) && const < ::Data
        end
        h
      end.freeze

      IR_TYPE_PREFIX = "IR::"

      def serialize(program)
        serialize_node(program)
      end

      def deserialize(h)
        deserialize_node(h)
      end

      def serialize_node(node)
        return nil if node.nil?

        unless node.is_a?(::Data)
          raise ArgumentError, "cannot serialize non-IR node: #{node.inspect}"
        end

        fields = {}
        fields["_t"] = ir_type_name(node)

        node.class.members.each do |field_name|
          value = node.public_send(field_name)
          fields[field_name.to_s] = serialize_value(value)
        end

        fields
      end

      def deserialize_node(h)
        return nil if h.nil?
        return h unless h.is_a?(Hash) && h["_t"]

        type_name = h["_t"]
        klass = IR_TYPE_REGISTRY[type_name]
        raise ArgumentError, "unknown IR type: #{type_name}" unless klass

        kwargs = {}
        klass.members.each do |field_name|
          key = field_name.to_s
          next unless h.key?(key)

          kwargs[field_name] = deserialize_value(h[key])
        end

        klass.new(**kwargs)
      end

      def serialize_value(value)
        return nil if value.nil?

        case value
        when ::Data
          if value.class.name&.start_with?("MilkTea::IR::")
            serialize_node(value)
          elsif value.class.name&.start_with?("MilkTea::AST::")
            Serialization::ASTIR.serialize(value)
          else
            serialize_node(value)
          end
        when Array
          value.map { |v| serialize_value(v) }
        when Hash
          value.transform_keys(&:to_s).transform_values { |v| serialize_value(v) }
        when Set
          value.to_a.map { |v| serialize_value(v) }
        when Float
          if value.nan?
            { _t: "nan" }
          elsif value.infinite?
            { _t: value.positive? ? "inf" : "-inf" }
          else
            value
          end
        else
          if value.class.name&.start_with?("MilkTea::Types")
            Serialization::TypesIR.serialize(value)
          else
            value
          end
        end
      end

      def deserialize_value(value)
        case value
        when nil then nil
        when Hash
          t = value["_t"]
          if t.nil?
            value.transform_values { |v| deserialize_value(v) }
          elsif %w[nan inf -inf].include?(t)
            case t
            when "nan" then Float::NAN
            when "inf" then Float::INFINITY
            when "-inf" then -Float::INFINITY
            end
          elsif IR_TYPE_REGISTRY.key?(t)
            deserialize_node(value)
          elsif t.start_with?("AST::")
            Serialization::ASTIR.deserialize(value)
          else
            Serialization::TypesIR.deserialize(value)
          end
        when Array
          value.map { |v| deserialize_value(v) }
        else
          value
        end
      end

      def ir_type_name(node)
        klass = node.class
        name = klass.name
        return name.sub("MilkTea::IR::", "") if name

        klass.ancestors.each do |anc|
          next unless anc.is_a?(Class) && anc < ::Data
          n = anc.name
          return n.sub("MilkTea::IR::", "") if n&.start_with?("MilkTea::IR::")
        end

        raise ArgumentError, "cannot determine IR type name for #{klass}"
      end
    end
  end
end
