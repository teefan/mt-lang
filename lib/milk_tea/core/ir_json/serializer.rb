# frozen_string_literal: true

require "json"

module MilkTea
  module IRJson
    module Serializer
      module_function

      def serialize(value)
        case value
        when ::Data
          serialize_data(value)
        when Types::Base
          serialize_type(value)
        when Array
          value.map { |v| serialize(v) }
        when Hash
          value.transform_values { |v| serialize(v) }
        when Symbol
          value.to_s
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        else
          raise ArgumentError, "cannot serialize #{value.class}"
        end
      end

      def serialize_data(data)
        short_name = data.class.name.split("::").last
        hash = { "$type" => short_name }
        data.class.members.each do |member|
          hash[member.to_s] = serialize(data.public_send(member))
        end
        hash
      end

      def serialize_type(type)
        case type
        when Types::Primitive
          type.name
        when Types::Nullable
          v = serialize_type(type.base)
          v.is_a?(String) ? "#{v}?" : "Nullable(#{v})"
        when Types::Span
          "span[#{serialize_type(type.element_type)}]"
        when Types::Task
          "Task[#{serialize_type(type.result_type)}]"
        when Types::StringView
          "str"
        when Types::Null
          "null"
        when Types::Struct, Types::Union
          if type.module_name
            "#{type.module_name}.#{type.name}"
          else
            type.name.to_s
          end
        when Types::Enum, Types::Flags, Types::Opaque
          type.name.to_s
        when Types::Function
          params = type.params.map { |p| serialize_type(p.type) }.join(", ")
          "fn(#{params}) -> #{serialize_type(type.return_type)}"
        when Types::Proc
          params = type.params.map { |p| serialize_type(p.type) }.join(", ")
          "fn(#{params}) -> #{serialize_type(type.return_type)}"
        when Types::Tuple
          elems = type.element_types.map { |t| serialize_type(t) }.join(", ")
          "(#{elems})"
        when Types::Dyn
          "dyn[#{type.interface.name}]"
        when Types::GenericInstance
          args = type.arguments.map { |a| serialize_type(a) }.join(", ")
          "#{type.name}[#{args}]"
        else
          raise ArgumentError, "cannot serialize type #{type.class}"
        end
      end

      def to_json(value, pretty: false)
        hash = serialize(value)
        pretty ? JSON.pretty_generate(hash) : JSON.generate(hash)
      end
    end
  end
end
