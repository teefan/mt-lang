# frozen_string_literal: true

module MilkTea
  module IRJson
    module Deserializer
      module_function

      def deserialize(value, program: nil)
        case value
        when Hash
          if value.key?("$type")
            deserialize_data(value["$type"], value)
          else
            value.transform_values { |v| deserialize(v, program:) }
          end
        when Array
          value.map { |v| deserialize(v, program:) }
        else
          value
        end
      end

      def from_json(string, program: nil)
        deserialize(JSON.parse(string), program:)
      end

      def deserialize_data(type_name, hash)
        klass = lookup_ir_class(type_name)
        kwargs = {}
        klass.members.each do |member|
          member_str = member.to_s
          val = hash[member_str]
          kwargs[member] = if val.nil?
                             nil
                           else
                             deserialize(val, program: nil)
                           end
        end
        klass.new(**kwargs)
      rescue StandardError => e
        raise ArgumentError, "failed to deserialize #{type_name}: #{e.message}"
      end

      IR_CLASS_CACHE = begin
        cache = {}
        [MilkTea::AST, MilkTea::IR].each do |mod|
          mod.constants.each do |c|
            cls = mod.const_get(c)
            cache[c.to_s] = cls if cls.is_a?(Class) && cls < ::Data
          end
        end
        cache["Token"] = MilkTea::Token if defined?(MilkTea::Token)
        cache
      end

      def lookup_ir_class(type_name)
        IR_CLASS_CACHE[type_name] || raise(ArgumentError, "unknown IR type: #{type_name}")
      end
    end
  end
end
