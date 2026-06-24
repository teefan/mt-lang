# frozen_string_literal: true

require_relative "ir_json/serializer"
require_relative "ir_json/deserializer"
require_relative "ir_json/type_resolver"

module MilkTea
  module IRJson
    def self.serialize_to_json(value)
      Serializer.to_json(value)
    end

    def self.deserialize_from_json(string)
      Deserializer.from_json(string)
    end

    def self.round_trip(ir_program)
      json = serialize_to_json(ir_program)
      deserialized = deserialize_from_json(json)
      TypeResolver.resolve_program_types(deserialized)
    end
  end
end
