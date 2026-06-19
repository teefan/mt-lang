# frozen_string_literal: true

module MilkTea
  class Codegen
    def self.generate_c(ir_program, emit_line_directives: true)
      CBackend.emit(ir_program, emit_line_directives:)
    end
  end
end
