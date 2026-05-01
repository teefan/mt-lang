# frozen_string_literal: true

module MilkTea
  class CSTFormatter
    def self.format(cst)
      cst.reconstruct
    end
  end
end
