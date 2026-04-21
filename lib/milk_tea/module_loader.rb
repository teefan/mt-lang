# frozen_string_literal: true

module MilkTea
  class ModuleLoadError < StandardError
    attr_reader :path

    def initialize(message, path:)
      @path = path
      super("#{message}: #{path}")
    end
  end

  class ModuleLoader
    def self.load_file(path)
      expanded_path = File.expand_path(path)
      source = File.read(expanded_path)
      Parser.parse(source, path: expanded_path)
    rescue Errno::ENOENT
      raise ModuleLoadError.new("source file not found", path: expanded_path)
    rescue Errno::EISDIR
      raise ModuleLoadError.new("expected a source file, got a directory", path: expanded_path)
    end
  end
end
