# frozen_string_literal: true

module MilkTea
  class Codegen
    def self.generate_c(program, emit_line_directives: true)
      ir_program = program.is_a?(IR::Program) ? program : Lowering.lower(program)
      CBackend.emit(ir_program, emit_line_directives:)
    end
  end
end
