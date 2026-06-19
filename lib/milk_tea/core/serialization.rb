# frozen_string_literal: true

require "json"
require_relative "../core"

require_relative "serialization/token_ir"
require_relative "serialization/ast_ir"
require_relative "serialization/types_ir"
require_relative "serialization/analysis_ir"
require_relative "serialization/program_ir"

module MilkTea
  module Serialization
    module_function

    def serialize_tokens(tokens)
      JSON.generate(TokenIR.serialize(tokens))
    end

    def deserialize_tokens(json)
      TokenIR.deserialize(JSON.parse(json))
    end

    def serialize_ast(source_file)
      JSON.generate(ASTIR.serialize(source_file))
    end

    def deserialize_ast(json)
      ASTIR.deserialize(JSON.parse(json))
    end

    def serialize_analysis(analysis)
      JSON.generate(AnalysisIR.serialize(analysis))
    end

    def deserialize_analysis(json)
      AnalysisIR.deserialize(JSON.parse(json))
    end

    def serialize_program(ir_program)
      JSON.generate(ProgramIR.serialize(ir_program))
    end

    def deserialize_program(json)
      ProgramIR.deserialize(JSON.parse(json))
    end

    def deep_freeze(obj)
      case obj
      when Hash then obj.each_value { |v| deep_freeze(v) }.freeze
      when Array then obj.each { |v| deep_freeze(v) }.freeze
      when Set then obj.each { |v| deep_freeze(v) }.freeze
      end
      obj
    end
  end
end
