# frozen_string_literal: true

module MilkTea
  class Codegen
    def self.generate_c(program)
      ir_program = program.is_a?(IR::Program) ? program : Lowering.lower(program)
      CBackend.emit(ir_program)
    end
  end
end
