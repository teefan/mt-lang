# frozen_string_literal: true

module MilkTea
  class ModuleLoadError < StandardError
    attr_reader :path

    def initialize(message, path:)
      @path = path
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
