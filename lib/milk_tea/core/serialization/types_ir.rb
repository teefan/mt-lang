# frozen_string_literal: true

module MilkTea
  module Serialization
    module TypesIR
      module_function

      TYPE_PREFIX = "Types::"

      def serialize(type)
        return nil if type.nil?
        return { _t: "bool", v: type } if type.is_a?(TrueClass) || type.is_a?(FalseClass)
        return { _t: "str", v: type } if type.is_a?(String)
        return { _t: "int", v: type } if type.is_a?(Integer)

        unless type.respond_to?(:class) && type.class.name&.start_with?("MilkTea::Types")
          raise ArgumentError, "cannot serialize non-type: #{type.inspect}"
        end

        fields = {}
        fields["_t"] = type.class.name.sub("MilkTea::Types::", "")

        type.instance_variables.each do |ivar|
          key = ivar.to_s.sub("@", "")
          val = type.instance_variable_get(ivar)
          fields[key] = serialize_value(val)
        end

        fields
      end

      def deserialize(h)
        return nil if h.nil?
        return h["v"] if h.is_a?(Hash) && %w[bool str int].include?(h["_t"])

        type_name = h["_t"]
        klass = TYPES_BY_NAME[type_name]
        raise ArgumentError, "unknown type: #{type_name}" unless klass

        params = klass.instance_method(:initialize).parameters

        args = []
        kwargs = {}

        params.each do |type, param_name|
          key = param_name.to_s
          next unless h.key?(key)

          value = deserialize_value(h[key])
          case type
          when :keyreq, :key then kwargs[param_name] = value
          when :req then args << value
          when :opt then kwargs[param_name] = value
          end
        end

        klass.new(*args, **kwargs)
      end

      TYPES_BY_NAME = begin
        types_mod = ::MilkTea::Types
        h = {}
        types_mod.constants.each do |name|
          const = types_mod.const_get(name)
          h[name.to_s] = const if const.is_a?(Class) && const < types_mod::Base
        end
        h
      rescue NameError
        {}
      end.freeze

      def serialize_value(value)
        return nil if value.nil?

        case value
        when Hash
          value.transform_keys(&:to_s).transform_values { |v| serialize_value(v) }
        when Array
          value.map { |v| serialize_value(v) }
        when Set
          value.map { |v| serialize_value(v) }
        else
          if value.class.name&.start_with?("MilkTea::Types")
            serialize(value)
          elsif value.is_a?(::Data)
            ASTIR.serialize(value)
          else
            value
          end
        end
      rescue StandardError
        value.to_s
      end

      def deserialize_value(value)
        return nil if value.nil?

        case value
        when Hash
          if value["_t"]
            if TYPES_BY_NAME.key?(value["_t"])
              deserialize(value)
            else
              ASTIR.deserialize(value)
            end
          else
            value.transform_values { |v| deserialize_value(v) }
          end
        when Array
          value.map { |v| deserialize_value(v) }
        else
          value
        end
      end
    end
  end
end
