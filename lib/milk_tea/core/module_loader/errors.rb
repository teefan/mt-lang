# frozen_string_literal: true

module MilkTea
  class ModuleLoadError < StandardError
    attr_reader :path, :line, :column

    def initialize(message, path:, line: nil, column: nil)
      @path = path
      @line = line
      @column = column
      super("#{message}: #{path}")
    end

    def code
      "module/error"
    end
  end

  class ModuleLoader
    ImportResolution = Data.define(:modules, :errors)
    ImportResolutionError = Data.define(:import, :error)
  end
end
