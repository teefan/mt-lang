# frozen_string_literal: true

module MilkTea
  class CSTFormatter
    def self.format(cst)
      cst.reconstruct
    end

    def self.format_normalized(cst)
      cst.reconstruct_normalized
    end
  end
end
